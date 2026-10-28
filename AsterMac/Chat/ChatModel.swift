//
//  ChatModel.swift
//  AsterMac
//
//  SwiftUI 与 `AIChatManager` 之间的适配层。
//
//  ## 这一层为什么存在
//  `AIChatManager` 是照着 UITableView 写的：它**不持有视图**，只通过 delegate 推
//  「什么变了」（插了哪几行 / 末行文本变了 / 整表换了），由视图自己维护增量刷新
//  —— 那套 `insertRows` / `reloadRows` 是被 UITableView 逼出来的。
//
//  SwiftUI 的模型正相反：**数据一变就重算 body**，不需要增量信号。
//  所以这里只做一件事：**把 manager 的 rows 抄成 `@Observable` 状态**，
//  delegate 回调只是「该抄了」的触发器。
//
//  ⚠️ 刻意**不做**增量/节流优化。一条会话是几十行量级，整体替换 `rows` 的代价
//  远低于「维护两套增量状态」带来的错位风险（iOS 那边踩过的「量高与实际布局不同源」
//  就是同类问题的另一个面）。
//

import AppKit
import Foundation
import Observation
import AICore

@Observable
final class ChatModel: AIChatManagerDelegate {

    // MARK: - 底层

    /// 业务真值全在这里。本类型不复制它的逻辑，只镜像它。
    let manager = AIChatManager()

    // MARK: - SwiftUI 读取的状态

    private(set) var rows: [AIChatRow] = []
    private(set) var summaries: [AIConversationSummary] = []
    /// 全部项目（按 sortOrder）。左栏分组头 / 「移动到项目…」菜单的数据源（2026-10-21）。
    /// `refreshAll()` 与 `summaries` 一起拉 —— 两者必须同拍，否则会画出「有会话没分组头」。
    private(set) var projects: [AIChatProject] = []

    /// 左栏当前选中项。与 `manager.activeConversationId` 保持同步。
    var selectedConversationId: UUID?

    /// 输入栏草稿
    var draft: String = ""

    /// 已经选好、等着跟这条消息一起发出去的附件（截图 / 图片 / 文件）。
    ///
    /// 🔴 **只在这里存一份**：视图（`MacInputBar` 顶部的附件条）读它、`+` 菜单写它。
    /// 不要另存一份「缩略图数组」之类的镜像 —— 移除一个附件时两处必然错开，
    /// 表现是「卡片上的 × 点了没反应」。
    private(set) var pendingAttachments: [AIAttachment] = []

    /// 一条消息最多挂几个附件。
    ///
    /// 上限的来由不是业务层（那边只限制「带进上下文的图片最多 6 张」），
    /// 而是**输入区那一排小卡不换行也不滚动** —— 不设上限迟早撑出卡片。
    /// 要放开这个数，得先把附件条改成可滚动的容器（见 `MacTheme` 里那段注释）。
    static let maxPendingAttachments = 6

    /// 顶部飘一条提示（出错 / 截断 / 上下文裁剪）。`nil` = 不显示。
    var toast: String?

    /// **正在朗读的那一行**（`nil` = 没在朗读）。
    ///
    /// 只存行 id、不存「哪一段文本」：`AISpeechReader` 自己握着 utterance 队列，
    /// 这边再存一份文本只会在切换目标时对不上。UI 拿它决定「朗读」那颗显示
    /// `speaker.wave.2` 还是 `stop.circle`。
    private(set) var speakingRowId: UUID?

    /// 监听「朗读自然读完」的注册凭据（多播，见 `AISpeechReader.addFinishHandler`）。
    /// ⚠️ 必须留着它才能在 `deinit` 里注销 —— 那个单例活得比本类型久。
    private var speechFinishToken: AISpeechReader.FinishToken?

    private var toastTask: Task<Void, Never>?

    // MARK: - 联网搜索（2026-10-21）

    /// 联网搜索开关的 **`@Observable` 镜像**。
    ///
    /// 真值在 `AIGenerationSettings.webSearchEnabled` —— 那个类型**不是** `@Observable`，
    /// 读计算属性界面不会重算（与 `title` 那条血泪注释同一个坑）⇒ 必须镜像一份。
    /// ⚠️ 写入统一走 `toggleWebSearch()`（一处同时写两边），⛔ 别在视图里直接改这个属性。
    var webSearchEnabled = AIGenerationSettings.webSearchEnabled

    /// 本轮正在联网检索（首字之前那 1–4 秒）。
    ///
    /// 同样必须镜像：来源 `AIChatManager` 不是 `@Observable`，靠通知推进来。
    /// UI 用它决定控制行那颗转圈的 tooltip 是「正在联网搜索…」还是「正在回答…」。
    private(set) var isSearchingWeb = false

    // MARK: - 派生状态（**不另存一份**）
    //
    // ⚠️ **本节有一个刻意例外：`title` 是存储属性**（见它自己的注释）。
    //    这不是疏忽、也**别"顺手改回"计算属性**：它的来源 `AIChatManager` 不是 `@Observable`，
    //    写成计算属性 ⇒ SwiftUI 收不到重算信号 ⇒ 左上角标题永远停在第一拍（2026-10-12 真 bug）。
    //    判据见 `render_mac_ui.sh` 契约段「主区域标题」那一组。

    /// 是否正在收流。
    ///
    /// 从 `rows` 推导而不是自己维护一个 bool：占位行是 `send()` 里**同步**插入的
    /// 且 `isStreaming = true`，所以这个判断在点发送的那一拍立刻为真。
    /// 自己再存一份迟早和真实状态错开（iOS 侧 `isStreaming` 是 VC 自己维护的，
    /// 因为 UITableView 需要它决定「贴底才自动滚」这类即时行为，SwiftUI 不需要）。
    var isStreaming: Bool { rows.contains { $0.block.isStreaming } }

    /// 主区域左上角那个标题（= 窗口标题栏那行字 / `RootView` 的 `.navigationTitle`）。
    ///
    /// 🔴 **必须存储、且由 `refreshTitle()` 单点维护**（2026-10-12 修用户报的 bug）。
    ///
    /// 它**原来是个计算属性**：
    /// ```swift
    /// var title: String { manager.activeTitle.isEmpty ? "新对话" : manager.activeTitle }
    /// ```
    /// 看着更符合本节的规矩（派生值不另存一份），但 **SwiftUI 收不到任何信号**：
    /// `AIChatManager` 是普通 class、**不是** `@Observable` —— 读 `manager.activeTitle`
    /// 不会登记观察依赖，登记上的只有那个**永不改变**的 `manager` 属性本身。
    /// 而 `RootView.body` 恰好**没有**读 `rows` / `selectedConversationId`（它只读
    /// `webPage` / `isDocumentsShown` / `title` / …）⇒ 切会话时 `RootView.body`
    /// **根本不会重算** ⇒ 挂在它上面的 `.navigationTitle` 永远停在窗口创建那一拍。
    ///
    /// 真窗口实测（`STARRY_ROOT_TITLE=1 zsh .workbuddy/scripts/render_mac_ui.sh root`）：
    /// ```
    /// ① 启动（会话页）    模型.title=「渲染夹具会话」  可见窗口标题=「渲染夹具会话」   ← 一致
    /// ② 我的对话→第二个会话 模型.title=「第二个会话」  可见窗口标题=「渲染夹具会话」   ← ☠️ 没跟上
    /// ③ 点「文档」        模型.title=「第二个会话」  可见窗口标题=「渲染夹具会话」   ← ☠️ 两个都不对
    /// ```
    /// ⇒ 修法两条，缺一不可：
    /// ① 变成**存储**属性（`@Observable` 才会真发通知）；
    /// ② 所有会改变它的地方**一律**走 `refreshTitle()`（单一漏斗，⛔ 别在别处直接赋值）。
    private(set) var title: String = ChatModel.newConversationTitle

    /// 还没有标题的会话（刚「新对话」）在标题栏上显示的文案。
    ///
    /// 🔴 **必须是计算属性、⛔ 不能写回 `static let`**（2026-10-13 接本地化时踩到）：
    ///    `static let` 是**进程级缓存**，第一次读到就定死了 —— 切语言之后它永远是旧语言那份，
    ///    **连视图整棵重建也救不回来**（它不在视图里，在类型上）。同款坑还有十来处，见
    ///    `.workbuddy/memory/I18N.md` 的「`static let = L(…)` 一律改成计算属性」那节。
    static var newConversationTitle: String { L("新对话") }

    /// 「文档」页的标题（= 窗口标题栏那一行）。
    ///
    /// 🔴 **与 `SidebarQuickEntries` 里那颗入口的 title 必须同一个字**：
    /// 那是「同一件事的两个显示位」（左侧菜单项 + 左上角标题），
    /// `render_mac_ui.sh` 的契约段有一条断言同时钉两处，改一处必须一起改。
    /// ⚠️ 用户 2026-10-12 原话：「左侧菜单切换 开启AI、文档、我的对话。在会话页面左上角的
    ///    title 没有正确切换」⇒ 切到文档页时标题要跟着变成「文档」，切回会话再变回会话名。
    /// 🔴 同上，**计算属性**（`static let` 会把语言锁死）。
    static var documentsPageTitle: String { L("文档") }

    /// 当前会话是否有内容（决定是画空态还是画列表）
    var isEmpty: Bool { rows.isEmpty }

    // MARK: - 生命周期

    init() {
        manager.delegate = self
        // 朗读**自然读完**（或被系统打断）时复位图标。
        //
        // ⚠️ 主动 `stop()` / `stopForRecording()` **不会**回调「读完」（见 `AISpeechReader`
        //    的成员注释，那是刻意设计：否则「切到另一行朗读」时内部先停旧的会误报一次结束）。
        //    所以两条收尾路径各清各的：这里管「读完」，`toggleSpeech` 管「我按停的」。
        // ⚠️ 回调声明是非隔离的，而本类是 MainActor 隔离 —— 跳到主 actor 再改状态，
        //    不用 `assumeIsolated`（那要求调用方保证在主线程，是个没必要的地雷）。
        // ⚠️ 走**多播**注册：iOS 通话页也监听同一个事件（读完自动开麦），
        //    单槽位属性会让两边互相挤掉，被挤掉的那一边**不报错**、只是静默失灵。
        speechFinishToken = AISpeechReader.shared.addFinishHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.speakingRowId = nil
            }
        }
        if !manager.restoreLastConversation() {
            // 冷启动没有可恢复的会话 → 起一个**未落库**的空会话
            // （`newConversation()` 不写库，所以不会在左栏留下一条空记录）
            _ = manager.newConversation()
        }
        selectedConversationId = manager.activeConversationId
        refreshAll()
        refreshModelState()
        observeConfigChanges()
        observeGenerationSettingsChanges()
        observeWebSearchState()
        // 项目资料检索的放大镜入口 2026-10-23 已删（用户拍板「默认关闭 + 删入口」）⇒
        // 冷启动把存量 true 清成 false：UserDefaults 里的旧值不清，就是「按钮没了却每轮
        // 静默检索」（底层链路全保留，恢复指南见 VERIFY-PROBES.md §32.4）。
        AIGenerationSettings.resetLegacyProjectSearchEntry()
    }

    /// ⚠️ 本类是 MainActor 隔离的，而 `deinit` 是 nonisolated 的 —— 这里**只读**一个
    /// `Sendable` 存储属性（`UUID`）把它还给单例，其余一概不碰。
    /// （与本文件上面「不用 `addObserver(forName:)` 因为要存 token」那条顾虑**不同**：
    ///   那条路要跨隔离去**写状态**，这里只是把一个 UUID 传出去，不触碰任何隔离状态。）
    deinit {
        if let token = speechFinishToken {
            AISpeechReader.shared.removeFinishHandler(token)
        }
    }

    // MARK: - 模型选择（输入栏那颗「模型」块）

    /// 可选模型 = **配齐的**那些条目（`AIModelCatalog.readyChoices()`，读
    /// `Documents/models.json`）—— 与 iOS 会话选择器同口径（见那边文件头 ①）。
    ///
    /// 🔴 为什么要在这里镜像一份，而不是让视图 `body` 里现读 `AIModelCatalog`：
    /// SwiftUI 只在 `@Observable` 状态变化时重算 `body`，而清单躺在 JSON 文件里 ——
    /// 设置窗口（**独立窗口**）改了它，这边不会自动知道。
    /// 所以订阅 `AIConfig.didChangeNotification`（配置的唯一广播出口），收到就重读。
    ///
    /// 🔴 **2026-10-14 起的语义变化**：改造前这里是「跨平台」（三家的模型全列，选一项 =
    ///    换平台 + 换模型）。现在**一条配置自带地址**，「换平台」不再是一个动作 ——
    ///    列表就是用户自己攒的那几条，选一条 = 连它背后的服务一起换。
    ///    于是这里不再需要跨平台拼接，「打勾」也不再需要「平台/模型」复合键。
    private(set) var modelChoices: [AIModelCatalog.AIModelChoice] = []

    /// 本窗口**正在用**的那一条配置的 id（= 发给服务端的模型标识）。空 = 清单里一条都没有。
    private(set) var currentModelID = ""

    /// 选择器的 `selection`。
    ///
    /// 🔴 就是条目 id（`AIModelChoice.id`）—— 它同时是「发给服务端的模型标识」，
    ///    所以列表项的 `tag` 与这里的 `selection` **天然同源**，
    ///    不会出现改造前那种「用文案当 selection 永远匹配不上」的坑（那时不区分模型的平台
    ///    会退回平台名，勾直接消失）。
    private(set) var currentChoiceKey = ""

    /// 输入栏上那颗块显示的文案 = **当前条目的名字**（一条都没有时是「未配置模型」）。
    ///
    /// 🔴 口径**不再写在这里**：`AIModelCatalog.composerLabel()` 是唯一来源
    ///    （iOS 输入栏那颗胶囊读的是同一个函数）—— 两平台各写一遍必然漂，
    ///    而漂在这里的后果是「mac 显示平台名、iOS 显示空」这种最难发现的差异。
    private(set) var currentModelLabel = ""

    /// 当前条目的**供应商**显示名（镜像，给 tooltip 里那句「当前模型：<供应商> · <模型>」用）。
    private(set) var currentProviderLabel = ""

    /// 块上的完整说明（**带供应商前缀**），给 tooltip 用。
    ///
    /// ⚠️ 与 `currentModelLabel` 分开是必须的：块上那行文案要尽量短（控制行右边还挤着
    ///    🎤 与送信圆），只放模型名；而 tooltip 不受宽度限制，该把供应商说全 ——
    ///    用户可能同时配了好几条（同一家的两个模型、或者两个中转站），
    ///    光看模型名不一定知道它走的是哪个服务。
    var currentChoiceLabel: String {
        currentProviderLabel.isEmpty ? currentModelLabel
                                     : "\(currentProviderLabel) · \(currentModelLabel)"
    }

    /// 重读模型相关状态。`init`、配置变更广播、以及本类型的切换动作都走它。
    ///
    /// ⚠️ 放开成 internal（而非 private）是给**渲染台夹具**留的门：配置变更的刷新是**异步**的
    ///    （`notifications(named:)` 那个任务要等主线程让出去才跑），而夹具是在同一拍里改完
    ///    存储就截图 —— 不手动同步一次，图上画的是旧状态，那种「图看着对、
    ///    其实验的是别的东西」最难发现。真 App 里没有别的调用点。
    func refreshModelState() {
        // 🔴 先「落地」当前指针，再读：清单非空而指针为空/悬空（首启、或用户手改 JSON
        //    把在用的那条删了）时钉一下 —— 不钉的话块上会显示「未配置模型」，
        //    而清单里明明有东西。
        //    ⚠️ 改造前后这里有一整套「按平台落地会话槽」（`ensureSessionModel`）的动作，
        //       现在只剩这一次 —— 「设置里配的」与「会话窗口选的」**已经合成一个**了
        //       （清单页只管清单、根本不回答「用哪个」，见 `AIModelStore.currentID`）。
        AIConfig.ensureCurrent()
        currentModelID = AIConfig.currentID ?? ""
        currentChoiceKey = currentModelID
        // 与 iOS 选择器同口径：只列「配齐了、点了真能发出去」的那几条
        modelChoices = AIModelCatalog.readyChoices()
        currentModelLabel = AIModelCatalog.composerLabel()
        currentProviderLabel = AIConfig.current?.vendorDisplayName ?? ""
    }

    /// 选中一项 = **换当前使用的那条配置**，下一轮请求即生效。
    ///
    /// 🔴 改造前这里要写两处（`currentProvider` + `setSessionModel`），因为列表是跨平台的、
    ///    选一项既是换模型也是换平台。现在一条配置自带地址与模型名
    ///    —— 「换平台」不再是一个动作，只剩一个指针要写（`AIConfig.currentID`）。
    ///
    /// - 只写**当前使用**的指针，⛔ 不写清单里的任何配置：清单页那边「我在窗口里选一下，
    ///   设置里配的东西被改了」正是要避免的（2026-10-02 用户明确要求拆开的那对）。
    /// - 生效时机：provider 是**每次请求现造**的（`AIProviderFactory.make()` 现读
    ///   `AIConfig.current`），所以切换对**下一条消息**立刻生效。正在收流的那一轮用的是
    ///   它开始时的配置 —— 不打断，也不需要打断（收流中不禁止切换）。
    /// - 范围：这是**本窗口当前选择**（全 App 一个指针）。会话级要动库结构，当前没做。
    func selectChoice(_ key: String) {
        // 认不出这一项就直接返回：菜单刚关掉那一拍，`modelChoices` 可能已被广播刷成新的一套
        // （比如刚在清单页删掉了一条）—— 此时按旧键找不到是正常情况，不该写任何东西。
        guard modelChoices.contains(where: { $0.id == key }) else { return }

        // 🔴 切换前后那两条要在**写指针之前**取（2026-10-21）：`noteModelSwitch(from:to:)`
        //    要拿「从哪切到哪」在会话里记一条居中系统消息，而名字是那一刻的快照
        //    （见 `AIModelSwitch` 文件头）。写完之后 `AIConfig.current` 已经是新的了。
        let previous = AIConfig.current
        AIConfig.currentID = key
        // 点当前已选中的那一项时 `noteModelSwitch` 自己会拦住（`from.id == to.id`）——
        // 这里照样调，省得在调用点再判一次
        if let previous, let now = AIConfig.current {
            manager.noteModelSwitch(from: previous, to: now)
        }
        // **同步**再刷一次：广播那条路要等主线程让出去才跑（异步序列），而这里我们已经
        // 知道新值 —— 不刷的话块上的名字会慢一拍才变（菜单刚关掉，看着像没生效）。
        // 广播随后还会到一次，重复读一遍无害。
        refreshModelState()
    }

    /// 订阅配置变更。用 `notifications(named:)` 这个 `AsyncSequence`，
    /// **不用** `addObserver(forName:)`：后者要存 token 并在 `deinit` 里摘，
    /// 而本类是 MainActor 隔离的 —— `deinit` 里碰隔离状态在 Swift 并发下是个雷。
    /// 这个写法自己收尾：任务只**弱**引用 self，本对象释放后下一拍 `guard` 失败就退出循环、
    /// 订阅随之解除。
    private func observeConfigChanges() {
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AIConfig.didChangeNotification) {
                guard let self else { return }
                self.refreshModelState()
            }
        }
    }

    /// 订阅「生成参数」变更（2026-10-20）。系统提示词 / 采样参数的消费方是**下一轮请求**
    /// （现读，不需要刷新界面）；要反应的是「展示思考过程」总闸 —— 思考块的渲染现读它
    /// （`ChatRowView.visibleReasoning`），关掉时屏幕上那些思考块不会自己消失。
    ///
    /// 与 `observeConfigChanges` 同一写法（`notifications(named:)` + 弱引用 Task）：
    /// ⛔ 别改成 `addObserver(forName:)` —— 那条路要存 token 并在 `deinit` 里摘，
    /// 而本类是 MainActor 隔离的，`deinit` 里碰隔离状态在 Swift 并发下是个雷。
    private func observeGenerationSettingsChanges() {
        Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: AIGenerationSettings.didChangeNotification
            ) {
                guard let self else { return }
                self.refreshAll()
            }
        }
    }

    /// 订阅**联网检索**的两条通知（2026-10-21）：状态变化 → 刷转圈；失败 → 飘一条提示。
    ///
    /// ⚠️ 通知的 `object` 是 `AIChatManager` 实例 ⇒ 必须按实例过滤：同一进程里
    ///    可能有别的窗口 / 通话页各持一个 manager，不过滤会拿着别人的状态刷自己的界面
    ///    （而且**不报错**，看起来就像「转圈偶尔不停」）。
    private func observeWebSearchState() {
        Task { @MainActor [weak self] in
            for await note in NotificationCenter.default.notifications(
                named: AIChatManager.didChangeWebSearchStateNotification
            ) {
                guard let self, note.object as? AIChatManager === self.manager else { continue }
                self.isSearchingWeb = self.manager.isSearchingWeb
            }
        }
        Task { @MainActor [weak self] in
            for await note in NotificationCenter.default.notifications(
                named: AIChatManager.didFailWebSearchNotification
            ) {
                guard let self, note.object as? AIChatManager === self.manager else { continue }
                // 搜索失败**不影响这一轮**（业务层已降级成普通对话），这里只负责说一声，
                // 否则用户会以为「开了联网但答案里没有来源」是功能坏了
                let message = note.userInfo?[AIChatManager.webSearchFailureKey] as? String
                self.show(message ?? L("联网搜索没搜到，直接回答"))
            }
        }
    }

    // MARK: - 动作

    /// 切「联网搜索」。**同时写两处**：真值（`AIGenerationSettings`）+ 本类镜像。
    /// 不等广播的原因与 `selectChoice` 同款 —— 广播要等主线程让出去才跑，
    /// 那样按钮会慢一拍才变色（看着像没点上）。
    func toggleWebSearch() {
        let next = !webSearchEnabled
        AIGenerationSettings.webSearchEnabled = next
        webSearchEnabled = next
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // 纯附件消息也允许发：业务层的 `send(_:attachments:)` 明确支持正文为空
        // （它会退化成一句占位标题，比如「[图片]」）。
        // ⚠️ 判据要带上 `@` 资料（2026-10-21）：只 @ 了一份资料、一个字没打也是合法的一条。
        guard !text.isEmpty || !pendingAttachments.isEmpty || !pendingMentions.isEmpty else { return }
        // 🔴 返回 false = **配置类错误**（缺 Key / 地址非法 / 模型不收图），
        //    那一拍**不能清输入区**：用户刚挑好的图不该因为一个配置问题就被清掉。
        //    业务层的 `- Returns:` 注释里就是这么约定的，别改成「先清再发」。
        let attachments = pendingAttachments
        // 「引用」挑好的那条引用跟着走。与附件同一条规矩：**发失败就留着**（见上面那段
        // 「返回 false 不能清输入区」），所以这里先取出、成功之后才清。
        let quote = pendingQuote
        let mentions = pendingMentions
        guard manager.send(text, attachments: attachments, quote: quote, mentions: mentions) else { return }
        draft = ""
        pendingAttachments = []
        pendingQuote = nil
        pendingMentions = []
        refreshAll()
    }

    // MARK: - 待发送的 @ 项目资料（2026-10-21）

    /// 已经 `@` 好、等着跟下一条消息一起发出去的**项目资料**。
    ///
    /// 🔴 只在这里存一份（与 `pendingAttachments` / `pendingQuote` 同一条规矩）。
    /// ⚠️ 与附件的**关键区别**：它**不会**变成对话里的一行 —— 只在请求上下文里出现
    ///    （见 `AIChatManager.contextMessages`）。所以「发完就清」不会丢东西，资料还在项目里。
    private(set) var pendingMentions: [AIMention] = []

    /// `@` 了一份项目资料（`@` 选择页选完那一刻调）。
    ///
    /// ⚠️ **不拷贝文件**（与 `attachProjectFile` 相反）：@ 是「引用项目里那一份」，
    ///    拷贝一份会让「项目资料更新了」这件事对这条消息失效 —— 而 @ 的全部意义就是读到最新版。
    func addMention(_ file: AIChatProjectFile) {
        guard !pendingMentions.contains(where: { $0.projectFileId == file.id }) else {
            show(L("这份资料已经 @ 过了"))
            return
        }
        guard pendingMentions.count < AIMention.maxPerMessage else {
            show(L("一次最多 @ 3 份资料"))
            return
        }
        let mention = AIMention(file)
        pendingMentions.append(mention)
        // 正文里补上那串 `@名字 `：chip 才是真值，这串是给人看的（与 iOS 同一口径）。
        // ⚠️ 先把**触发选择页的那个裸 `@`** 顶掉，否则会变成 `@@名字 `（用户看到会以为程序坏了）
        if draft.hasSuffix("@") {
            draft.removeLast()
        } else if !draft.isEmpty, !draft.hasSuffix(" ") {
            draft += " "
        }
        draft += mention.token()
    }

    /// 摘掉一条 @ 资料，并把正文里那串 `@名字` 一起抹掉。
    func removeMention(at index: Int) {
        guard pendingMentions.indices.contains(index) else { return }
        let mention = pendingMentions.remove(at: index)
        if let range = draft.range(of: mention.token()) ?? draft.range(of: "@\(mention.displayName)") {
            draft.removeSubrange(range)
        }
    }

    /// 清空待发资料（发送成功后调用）
    func clearMentions() {
        guard !pendingMentions.isEmpty else { return }
        pendingMentions.removeAll()
    }

    // MARK: - 待发送附件

    /// 把选好的附件加进待发送列表（`+` 菜单的两条路都走这里）。
    func addAttachments(_ items: [AIAttachment]) {
        guard !items.isEmpty else { return }
        let room = Self.maxPendingAttachments - pendingAttachments.count
        guard room > 0 else {
            show(String(format: L("一条消息最多带 %d 个附件"), Self.maxPendingAttachments))
            return
        }
        pendingAttachments.append(contentsOf: items.prefix(room))
        if room < items.count {
            show(String(format: L("一条消息最多带 %d 个附件，多出来的没加上"), Self.maxPendingAttachments))
        }
    }

    /// 摘掉一个附件（附件条上的 ×）。
    ///
    /// ⚠️ 刻意**不删磁盘上的文件**：它可能已经被别的消息引用过（同一张图连发两次时，
    /// 两次用的是同一个 URL），真正的清理属于会话删除那条路。这里只把它从**这一条**消息里摘掉。
    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    // MARK: - 引用（引用，2026-09-29）

    /// 已经挑好、等着跟下一条消息一起发出去的引用。`nil` = 没有引用。
    ///
    /// 🔴 **只在这里存一份**（与 `pendingAttachments` 同一条规矩）：输入卡片上方那条引用条
    /// 读它、消息操作栏的「⋯ → 引用」写它。别在视图里再存一份镜像 —— 两处必然错开，
    /// 表现是「点了引用，输入框上方什么都没有」。
    ///
    /// 📌 名字对不上是**故意的**：业务层的字段叫 `quote`（`AIQuote`）。Mac 侧文案
    /// **2026-09-29 先叫「追问」、当晚改回「引用」** ⇒ 现在两端同词，但**类型与参数名**照旧
    /// 沿用业务层的 `quote`。⛔ 别为了「少一处字面量」把界面文案绑到 `AIRowAction.quote.title`
    /// —— 那样以后想两端分叉又得改回来。
    private(set) var pendingQuote: AIQuote?

    /// 引用**某一条消息**（文字行）：把它的正文挂到输入框上方，等用户接着打字。
    ///
    /// - Returns: 是否挂上了。正文为空 / 是失败提示行时挂不上（会飘一条提示说明为什么）。
    @discardableResult
    func beginQuote(rowId: UUID) -> Bool {
        guard let row = manager.rows.first(where: { $0.id == rowId }) else { return false }
        // 失败提示是系统给的说明，引用它没有意义（真想问「这个报错怎么办」，直接打字问就行）
        guard row.block.kind != .error else {
            show(L("这条是系统提示，不用引用"))
            return false
        }
        let text = row.block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            show(L("这条没有可引用的文字"))
            return false
        }
        pendingQuote = AIQuote(messageId: row.block.id, role: row.role, text: text)
        return true
    }

    /// 展开 / 折叠某一行的思考块（2026-10-20，用户点思考块头部那一行）。
    ///
    /// 行号经 `AIChatManager.setThinkingExpanded` 落地 —— 行高重算、delegate 回调
    /// （→ `refreshAll`）都在那边，这里只负责「按 rowId 找行」。⛔ 别在视图层自己翻行状态：
    /// `AIChatRow` 是 struct，拷贝出去改了写不回去（本工程老坑）。
    func toggleThinking(rowId: UUID) {
        guard let index = manager.rows.firstIndex(where: { $0.id == rowId }) else { return }
        manager.setThinkingExpanded(!manager.rows[index].isThinkingExpanded, atRowIndex: index)
    }

    // ☠️ **「引用一组媒体」（`beginQuote(mediaIds:)`）2026-09-29 已整段删除** ——
    //    用户原话：「先把图片 和 视频的 引用去掉」。
    //
    //    起因不是「坏了」，是**那个功能没有站得住的语义**：文本 / 图片 / 视频虽然由同一次
    //    回复返回，但它们是**三条独立消息**（用户口径）⇒ 引用一张图就该引「那张图」本身。
    //    而上一版只能取「同轮里、与这几张媒体**同角色**的文字」（= AI 那段回复自己的正文，
    //    纯图回复则退成 `[N 张图片]` 占位）—— 那**是另一个对象**，等于指错。
    //    ⚠️ 更早一版取的是「整轮的文字」，会把**用户的提问**写进引用条，那是用户实测报回来的
    //    第一个 bug（「引用 AI 返回消息 图和视频，输入框内显示引用的是发送的消息」）。
    //
    //    🔴 而「引那张图本身」在当前架构里**做不到**，这才是拍板去掉的硬理由：
    //    助手侧的图 / 视频**根本不进请求上下文**（`AIChatManager.contextMessages` 里
    //    `case .image:` 只放行 `row.role == .user`），且 AI 的图是服务端的**远程 URL**、
    //    从没落地到本地 ⇒ 引用条上无论写什么，模型都看不见那张图。
    //
    //    📌 **要加回来必须连能力一起做**，两条路的取舍记在 `MAC-UI-RULES.md`：
    //    ① 引用条上放**缩略图** —— 只解决「你能确认引的是哪张」，模型仍看不见；
    //    ② 再把「下载远程图 → base64 内联进请求」补上 —— 视觉模型才真看得见（工程量大）。
    //    ⛔ 别只把入口接回来（`RowOverflowMenu` 传个 `onQuote` 就完事）——
    //    那会直接退回「引用条上写着 AI 的话」这个被用户否掉的口径。

    /// 撤销引用（输入框上方那条引用条上的 ×）。
    func cancelQuote() {
        pendingQuote = nil
    }

    func stop() {
        manager.stop()
        refreshAll()
    }

    // MARK: - 朗读

    /// 点某一行的「朗读」：**同一条再点一次 = 停**（一个按钮两态，与 iOS 侧一致）。
    ///
    /// - Parameters:
    ///   - rowId: 那一行的 id（只用它做高亮与去重）
    ///   - text: 要读的正文。注意是**这一行自己的**文本 —— 助手行的 Markdown 源码会原样
    ///     交给 `AISpeechReader`（它只按行/句切分，不做 Markdown 语法解析，
    ///     所以 `**加粗**` 这类符号会被念出来；那是业务层朗读器的既有行为，两侧同源）。
    func toggleSpeech(rowId: UUID, text: String) {
        if speakingRowId == rowId {
            AISpeechReader.shared.stop()
            speakingRowId = nil
            return
        }
        // 先认下状态再开口：`speak()` 里若音频会话激活失败是**静默返回**的
        // （Mac 上 `activatePlayback` 是 no-op 恒成功，所以不会走到），
        // 真出现了也只是图标亮着没声音，不会有更糟的后果。
        speakingRowId = rowId
        AISpeechReader.shared.speak(text)
    }

    /// 停止朗读并复位（切换会话、开新会话时调用：正在读的那条已经不在屏幕上了）
    func stopSpeech() {
        guard speakingRowId != nil else { return }
        AISpeechReader.shared.stop()
        speakingRowId = nil
    }

    // MARK: - 打电话窗口（2026-10-12）
    //
    // 通话窗是**独立窗口**（`MacVoiceCallWindow`），但它**不持有会话**：说出去的每一句都从
    // 本模型发（`sendFromVoiceCall`）、AI 的回复也从本模型的原生回调里取 ——
    // 关掉窗口回会话页看到的是完整对话。⛔ 别让它自己 new 一个 `AIChatManager`
    //（那是两份记录，与 iOS 侧「通话页不持有 manager」是同一条铁律）。
    //
    // 🔴 三件事必须在这里做，不能在通话窗里做：
    // ① **发送**：走 `manager.send`，与输入栏 / 录音浮层**同一条管线**；
    // ② **回复结束的转发**：`AIChatManagerDelegate` 是**单槽位**（`manager.delegate = self`
    //    被本类占着）⇒ 窗口拿不到那个回调，只能由本类转一道；
    // ③ **麦克风闸门**：`VoiceInputManager` 是**单例**，会话页的录音与本窗的拾音共用它。
    //    不挡的话两边各自 `startRecording()`，后开的那个会**静默顶掉**前一个
    //    （回调槽位被覆盖、音频 tap 被重装 —— 表现是"会话页的录音面板卡住不动了"）。

    /// 通话窗是否开着。开着时会话页的录音入口让位（见 `beginVoice` 的闸门）。
    var isVoiceCallActive = false

    /// 通话窗注册进来的「这一轮回复说完了」回调，参数是回复正文。
    /// ⚠️ 用完**不清**：通话是多轮的，每一轮都要它（开关由 `isVoiceCallActive` 把）。
    var voiceCallReplyHandler: ((String) -> Void)?

    /// 通话窗发一句话（**不经过输入栏草稿**）。
    ///
    /// - Returns: 是否**真的发出去了**。`false` = 配置类错误（缺 Key / 地址非法），
    ///   业务层已经同步给过提示 ⇒ 通话窗据此回到「听着」而不是干等在「正在思考…」上
    ///   （那是死锁：永远等不到回复结束）。
    @discardableResult
    func sendFromVoiceCall(_ text: String) -> Bool {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return false }
        // ⚠️ 刻意**不带** `pendingAttachments`：那些是输入栏上"用户还没发出去"的东西。
        //    通话里说出来的一句自成一条消息（与录音浮层的 `handleVoiceResult` 不同 ——
        //    那边的定位是"用语音代替键盘"，这边是另一条通道）。
        guard manager.send(content, attachments: [], quote: nil) else { return false }
        refreshAll()
        return true
    }

    /// 最近一条**助手**回复的正文（回复结束时用它喂给通话窗朗读）。
    ///
    /// 🔴 判据是「最后一行 且 `role == .assistant` 且 `kind == .text`」：
    ///    失败提示是**独立 kind**（`.error`），不排除它就会被念成
    ///    「⚠️ 账户余额不足（HTTP 402）」—— 该给用户看，但不该念出来。
    private func lastAssistantReplyText() -> String? {
        guard let row = rows.last,
              row.role == .assistant,
              row.block.kind == .text else { return nil }
        let text = row.block.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 把「这一轮回复的正文」转给通话窗朗读。**两个收尾回调共用**：
    /// `chatManagerDidFinalizeRow`（主入口，正文已全部上屏）与 `didError`（兜底，防卡死）。
    ///
    /// 🔴 **只有在这两处调**。⛔ 尤其别挂在 `chatManagerDidUpdateStreamingText` 上
    ///    （那是 0.03s 一帧，会把整段回复反复从头念）。
    /// ⚠️ 判据用 `isVoiceCallActive` 而不是「handler 非 nil」：handler 是常驻的
    ///    （通话多轮），窗口关掉之后它还在，靠这个开关把住。
    private func forwardReplyToVoiceCall() {
        guard isVoiceCallActive, let handler = voiceCallReplyHandler else { return }
        handler(lastAssistantReplyText() ?? "")
    }

    // MARK: - 语音输入

    // 交互形态：**点击开始 / 点击结束**（2026-09-24 用户定）。
    //
    // ⚠️ 刻意**不是** iOS 那套「按住说话」：Mac 上要用鼠标一直按着，长句会累，而且中途
    //    腾不出手。点按切换也与系统听写（连按两下 Fn 开始、再按结束）同一套语义。
    //    这个差异还顺手消掉了 iOS 那边最麻烦的一条约束 —— 见 `beginVoice` 里的权限注释。
    //
    // 结果去向：**识别出来直接作为一条消息发出**（同样按用户定的，与 iOS 一致），不回填输入区。

    /// 波形竖条数。与 iOS 侧同参（46 条 @25Hz ≈ 1.8 秒的时间窗）。
    ///
    /// 46 这个数是**按参考图像素实测**出来的（豆包那条带子就是 46 根，见
    /// `Aster/Sources/Voice/VoiceWaveformView.swift` 头部的实测表）。它同时决定带子总宽
    /// ——46×3 + 45×2 = 228pt；⛔ 别单独调这一个数字：波形视图那边是按「3pt 条宽 + 2pt 间距」
    /// 排布的，条数一变带子宽度跟着变，得两个平台一起看。
    static let voiceBarCount = 46

    /// 正在录音（面板显隐、🎤 换态、送信按钮换语义都看它）。
    private(set) var isVoiceRecording = false

    /// 已松开、**正在等识别器吐最终文字**（那最多 0.8s，见 `VoiceInputManager.stopRecording`）。
    ///
    /// 为什么要单独一个态：点击结束后面板若立刻消失、消息又要等半秒才冒出来，
    /// 中间那段空白读起来就是「我点了但它没反应」。有这个态就能把提示换成「正在整理文字…」。
    private(set) var isVoiceFinishing = false

    /// 实时识别文本（**全量**，不是增量）
    private(set) var voiceTranscript = ""

    /// 音量滚动历史（队尾最新），驱动波形。长度恒为 `voiceBarCount`。
    private(set) var voiceLevels = [CGFloat](repeating: 0, count: voiceBarCount)

    /// 已录时长（秒）。由音量回调顺带推进 —— 音频 tap 是**连续**回调的（静音时也在回调），
    /// 所以不必再挂一个 `Timer`（iOS 侧同一个手法）。
    private(set) var voiceElapsed: TimeInterval = 0

    private var voiceStartedAt = Date()

    /// 点 🎤：没在录就开始，在录就**结束并发送**。
    func toggleVoice() {
        // 已完成录制、正在等最终文字 —— 这一拍再点没有语义（文字已经在路上），忽略
        guard !isVoiceFinishing else { return }
        if isVoiceRecording { finishVoice() } else { beginVoice() }
    }

    private func beginVoice() {
        guard !isVoiceRecording else { return }
        // 🔴 通话窗开着时**不许**起录音（2026-10-12）：`VoiceInputManager` 是单例，
        //    两边各自 `startRecording()` 会让后开的那个**静默顶掉**前一个
        //    （回调槽位被覆盖、音频 tap 被重装）—— 表现是"通话窗突然没反应了"。
        //    ⛔ 别改成"允许并互踢"：用户看不见发生了什么事，只会觉得坏了一个。
        guard !isVoiceCallActive else {
            show(L("通话窗口正在使用麦克风"))
            return
        }
        // 收流中不许起录音：这一轮的用户消息已经发出去了，对着它说话语义不明；
        // 而且输入栏右侧那颗按钮此刻是「停止」——两件事叠在一颗按钮上会误触（iOS 侧同一判据）。
        guard !isStreaming else {
            show(L("正在回复中…"))
            return
        }
        // 朗读与录音共用同一份音频：先停朗读并复位图标。
        // （`VoiceInputManager.startRecording` 内部也会兜底停一次，但那一步不发回调、管不到 UI。）
        stopSpeech()

        // 🔴 权限：没授权就先请求，**授权成功后自动开始录音**。
        //
        //  这正是点击式交互白拿的一处好处：iOS 那边「按住说话」必须在切态时把权限预热掉，
        //  因为系统权限框一弹出就会强制松开手指 —— 那一次录音必然作废。这里是点按，
        //  点击早已完成，权限框弹多久都不影响这次操作，所以可以「请求 → 拿到 → 直接开录」，
        //  用户少点一次。
        guard VoiceInputManager.isAuthorized else {
            VoiceInputManager.requestPermission { [weak self] granted in
                guard let self = self else { return }
                guard granted else {
                    self.show(L("未获得麦克风或语音识别权限，请在系统设置里开启"))
                    return
                }
                self.beginVoice()
            }
            return
        }

        wireVoiceCallbacks()
        // ⚠️ 启动失败**不能**在这里清回调：`onError` 是异步回调（见 `VoiceInputManager.report`），
        //    清了就把错误提示吞掉了。收尾统一由回调那条路走。
        guard VoiceInputManager.shared.startRecording() else { return }

        isVoiceRecording = true
        voiceTranscript = ""
        voiceLevels = [CGFloat](repeating: 0, count: Self.voiceBarCount)
        voiceElapsed = 0
        voiceStartedAt = Date()
    }

    /// 结束录音 → 识别结果**直接作为一条消息发出**。
    ///
    /// 2026-10-03 起也**直接对外**（录音浮层右侧那颗 ✓ 圆钮走它，`ChatDetailView` 里接线）——
    /// 之前只有 `toggleVoice()` 一个入口（点 🎤 结束）。⚠️ 内部有 `guard isVoiceRecording`
    /// 兜底，所以不在录音时调它是空操作，不会误发。
    func finishVoice() {
        guard isVoiceRecording else { return }
        isVoiceRecording = false
        isVoiceFinishing = true

        let voice = VoiceInputManager.shared
        voice.stopRecording(cancel: false) { [weak self] text in
            guard let self else { return }
            // 收尾完成后再摘回调，避免等待期间丢字（iOS 侧同一条约定）
            self.clearVoiceCallbacks()
            self.handleVoiceResult(text)
        }
    }

    /// 丢掉这次录音（Esc / 面板上的取消 / 被系统打断 / 切会话）。
    ///
    /// - Parameter toast: 给的提示；传 `nil` 表示调用方自己会给更具体的说法，这里静默收尾。
    /// - Parameter completion: **收尾彻底完成**（= 共享单例那组回调槽位已经清干净）之后回调。
    ///   🔴 只有"让位给别人"的调用方需要它 —— 见下面那段"谁在这之后挂回调谁倒霉"。
    func cancelVoice(toast: String? = L("已取消"), completion: (() -> Void)? = nil) {
        let wasActive = isVoiceRecording || isVoiceFinishing
        isVoiceRecording = false
        isVoiceFinishing = false
        // ⚠️ 即便此刻没在录也要走一遍 `stopRecording(cancel:)`：它是**共享单例**，
        //    留一条半开的录音（tap 还装着、会话没释放）比多停一次糟得多。
        //
        // ☠️☠️ 这里**清的是共享单例的槽位**，而且它落在**下一个主队列回合**上
        //    （`stopRecording` 的两条出口都是 `DispatchQueue.main.async`）。
        //    ⇒ 谁在这之后"马上"挂自己的回调，谁的回调就会在下一拍被这一刀**整组抹掉**，
        //      而且**一点声音都没有**（不报错、不提示、连 `onError` 都不来）。
        //    2026-10-12 的真事故：Mac 通话窗 `startCall()` 先让位（调本方法）再 `beginListening()`
        //    （挂回调），两者在**同一个**主队列回合里 ⇒ 通话窗彻底聋掉，
        //    用户只说得出「打开 MacVoiceCall 说话没有反应」。
        //    ⇒ 让位的调用方**必须**用 `completion` 串起来，别靠"应该来得急"。
        VoiceInputManager.shared.stopRecording(cancel: true) { [weak self] _ in
            self?.clearVoiceCallbacks()
            completion?()
        }
        resetVoiceBuffer()
        // 没在录、也没在等结果时**不报**「已取消」：那是调用方在无关时刻顺手调了一次
        //（如切会话时无条件清一遍），弹提示纯属噪音。
        if wasActive, let toast = toast { show(toast) }
    }

    /// 挂上录音回调。单例只有这一组槽位，所以每次开始都重挂一遍。
    private func wireVoiceCallbacks() {
        let voice = VoiceInputManager.shared
        voice.onLevel = { [weak self] level in
            guard let self else { return }
            self.appendVoiceLevel(level)
        }
        voice.onTranscript = { [weak self] text in
            guard let self = self, self.isVoiceRecording else { return }
            self.voiceTranscript = text
        }
        voice.onError = { [weak self] message in
            guard let self else { return }
            // 出错时静默收尾（不提示「已取消」），只报真正的原因
            self.cancelVoice(toast: message)
        }
        voice.onReachMaxDuration = { [weak self] in
            guard let self else { return }
            // 到单次时长上限 = 自动收尾发送（等价于用户点了结束）
            self.finishVoice()
        }
        voice.onInterrupted = { [weak self] in
            guard let self else { return }
            // 系统已经停掉录音了，这里只负责收面板 + 给说法
            self.cancelVoice(toast: L("录音被中断，请重试"))
        }
    }

    /// 摘掉语音回调（单例是共享的，退出时必须清干净）
    private func clearVoiceCallbacks() {
        let voice = VoiceInputManager.shared
        voice.onLevel = nil
        voice.onTranscript = nil
        voice.onError = nil
        voice.onReachMaxDuration = nil
        voice.onInterrupted = nil
    }

    /// 推进一帧音量：左移一位、新的挤到队尾。
    ///
    /// 🔴 **不做逐条帧间平滑**（iOS 侧那版在视图里存了一份 `displayed` 做 IIR）：
    ///    `VoiceInputManager.emitLevel` 已经把音量按「上升快、回落慢」平滑过一遍，
    ///    而这边的历史每帧整体左移 —— 25Hz 下这个位移本身就构成了「流动」的观感。
    ///    再叠一层 IIR 得在模型里多养一个与历史同步位移的数组，收益（更柔的尾巴）
    ///    不值那份状态。
    private func appendVoiceLevel(_ level: Float) {
        guard isVoiceRecording else { return }
        let target = CGFloat(min(max(level, 0), 1))
        var next = voiceLevels
        if !next.isEmpty { next.removeFirst() }
        next.append(target)
        voiceLevels = next
        voiceElapsed = Date().timeIntervalSince(voiceStartedAt)
    }

    private func resetVoiceBuffer() {
        voiceTranscript = ""
        voiceLevels = [CGFloat](repeating: 0, count: Self.voiceBarCount)
        voiceElapsed = 0
    }

    /// 收尾后的识别文本处理：**直接发一条消息**（用户定的行为）。
    private func handleVoiceResult(_ text: String) {
        isVoiceFinishing = false
        resetVoiceBuffer()

        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空文本 = 真的没听清（识别器出错也是以空文本体现，见 `VoiceInputManager` 里那段注释）
        guard !content.isEmpty else {
            show(L("没听清，请再说一次"))
            return
        }

        let attachments = pendingAttachments
        // 🔴 返回 false = **配置类错误**（缺 Key / 地址非法 / 模型不收图），业务层已经同步
        //    回调了 `didError`（提示条会说明原因）。这一拍**把刚识别出来的文字落回输入区**：
        //    那是用户刚说出来的一整句话，凭空消失比「要多按一次发送」糟得多。
        guard manager.send(content, attachments: attachments) else {
            draft = content
            return
        }
        // ⚠️ 刻意**不动 `draft`**：用户可能先打了半句话再改用语音。语音结果自成一条消息，
        //    草稿留着 —— 与 iOS 侧「语音不走输入框」一致。
        pendingAttachments = []
        refreshAll()
    }

    // MARK: - 就地编辑（用户消息，2026-09-24）
    //
    // 「编辑」= 把那条用户消息**就地**变成输入框，改完保存 → **从这条起重新走一遍**
    // （业务层 `AIChatManager.editAndResend` 会截断这条之后的所有行）。
    // 与输入栏那条路（`draft`）刻意**完全分离**：编辑的是历史里的一条消息，
    // 输入栏草稿是另一件事 —— 两者共用一个字段的话，「正在编辑 A」与「草稿里打了 B」
    // 会互相覆盖，而且用户看不出是被谁覆盖的。

    /// 正在就地编辑的那条消息 id。
    ///
    /// 🔴 记 **id 而不是行下标**：提交时 `editAndResend` 会把这一行（含）之后的**所有行**
    ///    截断重建 —— 下标在提交前就已经失效了。`AIChatRow.id` 就是 `AIChatBlock.id`
    ///    （构造处 `AIChatRow(id: block.id, …)`），所以它同时也是搜索定位用的那把钥匙。
    ///    （iOS 侧的 `editingMessageId` 同款处理。）
    private(set) var editingRowId: UUID?

    /// 就地编辑器里的文字。
    ///
    /// ⚠️ 与输入栏的 `draft` **互不相干**，别合并（理由见上面那段）。
    /// 可写：`ChatRowView` 的 `TextField` 直接双向绑定它。
    var editingText: String = ""

    /// 这一条是否正在被就地编辑（视图据此把气泡换成输入框 + 显示「取消 / 保存」）。
    func isEditing(rowId: UUID) -> Bool { editingRowId == rowId }

    /// 进入就地编辑态。
    ///
    /// 两条前置：**流式中**与**录音中**都不许进。前者因为 `editAndResend` 第一步就是 `stop()`，
    /// 用户点「编辑」时并没有期待「顺手把正在收的回复也停了」；后者因为那一拍的输入区是语音面板，
    /// 编辑态与它是两套并行的输入语义（同时活着会让「发送」键指向哪一边变得说不清）。
    func beginEdit(rowId: UUID, text: String) {
        guard !isStreaming else {
            show(L("正在回复中，先停下再试"))
            return
        }
        guard !isVoiceRecording, !isVoiceFinishing else { return }
        // 同时只能编辑一条：点另一条的「编辑」= 换目标（与 iOS 的 `enterEditing` 一致）
        editingRowId = rowId
        editingText = text
    }

    /// 退出就地编辑态并丢弃改动（取消按钮 / Esc / 切会话 / 发送成功后都走这里）。
    func cancelEdit() {
        guard editingRowId != nil else { return }
        editingRowId = nil
        editingText = ""
    }

    /// 提交编辑：从这条起重新生成。
    ///
    /// 🔴 失败时**保留编辑态**（这就是这里没有统一 `defer { cancelEdit() }` 的原因）：
    ///    `editAndResend` 返回 false = 配置类错误（缺 Key / 地址非法 / 模型不收图），
    ///    那一刻业务层**一行都还没动**（它刻意把校验放在删行之前）。此时若顺手退出编辑，
    ///    用户刚改好的整段文字就凭空没了 —— 与 `send()` 失败不清输入区是同一条口径。
    func commitEdit() {
        guard let rowId = editingRowId,
              let index = rows.firstIndex(where: { $0.id == rowId }) else {
            // 找不到目标就没什么可提交的（理论上到不了：编辑期间行不会自己消失）
            cancelEdit()
            return
        }
        let text = editingText
        guard manager.editAndResend(fromRowAt: index, newText: text) else { return }
        // 成功才收编辑态：此刻那一行已经被「删掉 + 用新文本重建」，旧 id 不再对应任何行，
        // 留着它只会让 `isEditing` 恒为假地空转
        cancelEdit()
        refreshAll()
    }

    // MARK: - 网页面板（2026-09-30；2026-10-02 拆出「显示开关」）

    /// 会话页右侧那块网页面板的**内容**（一组标签）。`nil` = 从没开过 / 被彻底关掉。
    ///
    /// ## 🔴 2026-10-02：内容与显示拆成**两个正交真值**
    /// 用户报的现象（原话）：「我在网页页面 有一个页面了，再点加号 新开一个页面，
    /// 在会话页面右上角的按钮，这个页面重新进 只剩下一个页面了。……
    /// 需要改成 只有内容 就是常驻的」。
    /// 根因：那颗按钮当时**就是** `closeWebPage()` —— 把 `webPage` 置 nil ⇒
    /// 用户开的两个标签连同 `WKWebView` 一起被销毁，再打开只能用 `lastWebPageURL`
    /// 重建一个新面板（= 1 个标签）。「我把面板挪开一下」被理解成了「我不要了」。
    /// ⇒ 拆开：
    ///   - `webPage` = **内容**（标签集合、每个标签的 `WKWebView`、滚动位置、前进后退历史）；
    ///   - `isWebPagePanelShown` = **可见性**（收起 / 展开只改它）。
    ///   面板真正的开关 = 「有内容 **且** 显示中」（见 `RootView.webPanelBinding`）。
    ///   收起再展开因此是**原样回来** —— `WKWebView` 由每个 `WebTabModel` 自己持有，
    ///   视图层只是把它挂上去 / 摘下来（摘下来不等于销毁）。
    ///
    /// ⚠️ 它**不落库、也不随换会话重置**：网页面板是「我现在正在看的这一页」，
    ///    与哪个会话无关 —— 用户切会话时并不想把正在读的那篇文档关掉。
    ///    这一点与朗读 / 录音 / 引用**刻意相反**（那几样都挂在某一条消息上，换会话必须丢，
    ///    见 `newConversation()` / `select(_:)` 里那几行）。
    private(set) var webPage: WebPageModel?

    /// 网页面板**显示中**吗（2026-10-02 加）。
    ///
    /// 🔴 它只回答「这块面板露不露出来」，**不回答「有没有内容」**（那是 `webPage`）。
    ///    两者都真，`.inspector` 才展开。
    /// ⛔ 别把它折叠回 `webPage`（那正是 2026-10-02 之前那版的错，见上面那段）；
    ///    也⛔别在视图层再存一份（本工程既有铁律：真值只有一份，在模型里）。
    private(set) var isWebPagePanelShown = false

    /// 导航上那颗「网页」开关要用来「恢复上次那一页」的地址（2026-09-30）。
    ///
    /// ## 🔴 为什么必须单独存一个地址
    /// 面板被 ✕ 收起时 `webPage` 变 `nil`，**地址也跟着没了** —— 但「收起」这件事本身
    /// 不该等于「忘掉我在读什么」。用户 2026-09-30 要求在导航上加一颗开关（先要「会话导航
    /// 最右」、当晚改口要「左侧菜单页导航、红绿灯旁边的那种」），那颗开关「打开时显示
    /// 哪一页」的答案只能从这里来。
    ///
    /// ⚠️ 与 `webPage` 是**同一条口径**：不落库、也不随换会话重置。
    ///    ⛔ 别为了「干净」在 `newConversation()` / `select(_:)` 里把它清掉 ——
    ///    清掉 = 用户切一下会话，那颗开关就灰了，而他刚才读的那页其实还在。
    ///
    /// ☠️ 它记的是「**用户实际停在哪一页**」，不是「当初点进来的那个入口地址」：
    ///    面板里点进二级页之后按 ✕，再按开关要回到二级页（见 `closeWebPage()` 里那一行）。
    private(set) var lastWebPageURL: URL?

    /// **上一个看过的文件叫什么**（2026-10-06 加，与 `lastWebPageURL` 配对）。
    ///
    /// 只有「上次看的是文件标签」时才有值；看的是网页时是 `nil`。
    /// ☠️ 为什么要单独记一个名字：**本地内容的显示名不在 URL 里** ——
    ///    会话附件的磁盘名是 UUID，而用户认得的名字在 `AIBlock.text`；
    ///    目录的名字虽然就是 `lastPathComponent`，但走的是同一条记账路（2026-10-07）。
    ///    少了它，把面板彻底关掉之后再用工具栏那颗开关恢复，标题就退化成一串 UUID。
    /// ⚠️ 与 `lastWebPageURL` 同一条口径：不落库、不随换会话重置、两个一起写。
    private(set) var lastPanelFileDisplayName: String?

    /// 打开网页面板（多标签）。
    ///
    /// - 面板**没开**：建面板 + 首标签 = 这个地址。
    /// - 面板**已开**：**新开一个标签**打开这个地址（与当前激活标签同址则去重，
    ///   不重复开 —— 避免「同一个链接点两次就重载一遍」）。旧标签不受影响、不释放。
    ///
    /// ⚠️ 非 http(s)（`mailto:` / `tel:` / App 自定义 scheme）**交回系统**：
    ///    `RootView` 的 `OpenURLAction` 里已经有一道同样的闸，这里是第二道 ——
    ///    「打开网页」将来可能还有别的入口（工具栏 / 菜单），把口径钉在模型这一层，
    ///    各入口就不会各自解释一遍。
    func openWebPage(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        // 🔴 `file://` = 「在面板里看这个文件」（2026-10-06）。面板自这天起**两用**，
        //    而这条路有两个可能的入口都会递 `file://` 进来：`reopenLastWebPage()`
        //    （那本字典里现在也装文件）与 `RootView` 的 `OpenURLAction`。
        //    ☠️ **必须排在下面那条「非 http(s) 交回系统」之前** —— 否则 `file://` 会被
        //    `NSWorkspace.open` 丢给别的 App 打开，那正好是「我们的面板不用了」的意思。
        //    ⚠️ 名字用记下来的那个：从这条路过来的文件多半是「恢复上次看过的」，
        //    磁盘名是 UUID，不带着名字回来标题就退化了。
        //    🔴 2026-10-07：`file://` 现在**也可能是目录**（用户记着上次浏览的文件夹）——
        //    分档交给 `openLocalInPanel` 内部按 `isDirectory` 判，这里不必也不该自己判。
        if scheme == "file" {
            openLocalInPanel(url, displayName: lastPanelFileDisplayName)
            return
        }
        guard scheme == "http" || scheme == "https" else {
            NSWorkspace.shared.open(url)
            return
        }
        // 🔴 **先记账再开**：记在开之前，是为了覆盖「面板已开、新开标签」那条路 ——
        //    不先记下新地址的话，收起之后工具栏那颗开关恢复的是**上上页**。
        //    （面板已经开着同一个地址时这句是幂等赋值，无副作用。）
        lastWebPageURL = url
        // 现在看的是网页 ⇒ 把「上次那个文件叫什么」清掉（两个账本要一起走）。
        lastPanelFileDisplayName = nil
        if webPage == nil {
            webPage = WebPageModel(url: url)
        } else {
            webPage?.open(url: url)
        }
        // 🔴 点链接的人**就是要看这一页** ⇒ 顺手把面板显示出来
        //    （面板可能是被他先前收起、但内容还常驻着的那种状态）。
        isWebPagePanelShown = true
    }

    /// 在右侧面板里打开一个**本地面上的东西**（文件 / 目录，2026-10-06 起；2026-10-07 扩到目录）。
    ///
    /// 入口：**点会话里的文件消息** · 起始页第②行「打开文件」· 第③行「打开文件夹」·
    /// `openWebPage` 那条 `file://` 恢复路径 · 目录树里点到的文件（走 `WebPageModel` 直连）。
    ///
    /// 🔴 **分档不在这里**：目录 ⇒ 目录树 / 认得的扩展名 ⇒ 代码视图 / 其余 ⇒ QuickLook，
    ///    判据全在 `WebPageModel.makeLocalTab`（那一处是唯一来源）。这里只负责**记账 + 转交**，
    ///    ⛔ 别在这里再写一遍 `isDirectory` / 扩展名判断（写两遍必然漂移）。
    ///
    /// - Parameter displayName：给用户看的名字。传 `nil` 表示「就用磁盘文件名」。
    ///   ⚠️ 从**文件消息**进来时必须传 `row.block.text` —— 附件落盘后磁盘名是 UUID
    ///   （`52EDE56F-….xlsx`），拿它当标题用户认不出来（iOS 那轮实拍踩过）。
    ///
    /// 🔴 与 `openWebPage` 一样**先记账再开**：收起面板之后那颗工具栏开关要能回到
    ///    「上一次看的东西」，而**文件与目录也算看过的东西**。
    func openLocalInPanel(_ url: URL, displayName: String?) {
        // 只认本地。来到这里的 `http(s)` 应该走 `openWebPage`（两条路互为正反闸，
        // 不会来回弹：`openWebPage` 只在 `scheme == "file"` 时才转过来）。
        guard url.isFileURL else {
            openWebPage(url)
            return
        }
        // 名字只在这一处定稿（空串 / nil 都退到磁盘名），下面记的账与开出来的标签用的是同一个。
        let name = (displayName?.isEmpty == false) ? displayName! : url.lastPathComponent
        lastWebPageURL = url
        lastPanelFileDisplayName = name
        // ⚠️ 空面板用 `WebPageModel()`（**不是** `WebPageModel(url:)` —— 那个是「开一个网页标签」）。
        if webPage == nil { webPage = WebPageModel() }
        webPage?.openLocal(url: url, displayName: name)
        isWebPagePanelShown = true
    }

    /// **收起**网页面板 —— 只收显示，**内容原样保留**（2026-10-02 加）。
    ///
    /// 🔴 这是会话页导航最右侧那颗按钮 / `.inspector` 自己收起来时走的**唯一**落点。
    ///    与 `closeWebPage()` 的区别就一条：**碰不碰 `webPage`**。
    ///    ☠️ 别把它写成 `closeWebPage()`（2026-10-02 之前就是那么写的）——
    ///    用户开的标签、每页的滚动位置、前进后退历史会全部丢掉，
    ///    表现就是「收起再打开，只剩一个标签」。
    ///
    /// ⚠️ 顺便把「用户最后停在哪一页」记下来：`lastWebPageURL` 是那颗按钮
    ///    **彻底关掉之后**再打开时的落点（`reopenLastWebPage()`），
    ///    也用来写按钮的悬停提示（「上次看的是 xxx」）。面板还活着的时候问得到
    ///    `currentURL`，所以这一步放在这里最省事（⛔ 别挪到 `webPage = nil` 之后）。
    func hideWebPagePanel() {
        // ☠️ 这一步必须**排在下面改显示状态之前**（见 `rememberPanelLocation()` 头注）。
        rememberPanelLocation()
        isWebPagePanelShown = false
    }

    /// 开一块**空面板 + 一个起始页标签** —— 那颗开关在「**从没看过任何页面**」时的落点。
    ///
    /// ## 🔴 用户要的是什么（2026-10-06，原话）
    /// 「会话页面有上的 打开右侧页面的按钮，现在右侧没有页面 点击无法打开，
    ///  先改成**如果没有页面 打开是起始页**」。
    /// 旧口径（2026-09-30 定的三态之一）是「从没看过任何网页 ⇒ 那颗开关**置灰**」——
    /// 那条已作废：右侧空着时那颗按钮正是**唯一**能凭空开出一页的入口，灰掉等于死结。
    ///
    /// ☠️ **必须补一个 `newTab()`**：`WebPageModel()` 的 `tabs` 是**空数组**，
    ///    光把它挂上去得到的是「**零标签**的面板」—— 内容区一片空白、只剩一条光秃秃的
    ///    导航条 + 1pt 分隔线。那不是「空白页」，那是**看着像坏了**
    ///    （同一个形态在 `closePanelTab(_:)` 那份头注里专门被避免过一次）。
    ///
    /// ⚠️ 账本**一个都不写**：走到这里时 `lastWebPageURL` 本来就是 nil —— 要么从没看过，
    ///    要么刚被 `forgetPanelLocation()` 清过（2026-10-07 起「关掉最后一个标签」也落到这一支）
    ///    —— 而起始页标签自身没有 URL ⇒ `rememberPanelLocation()` 的守卫什么都不记
    ///    ⇒ 收起来再点还是**起始页**，而不是跳去某个空地址。
    ///    这一条由真窗口探针 ⑪（从没看过）与 ⑩ ⇢ ③（刚关干净）两条一起钉着。
    func openStartPagePanel() {
        let page = WebPageModel()
        page.newTab()
        webPage = page
        isWebPagePanelShown = true
    }

    /// **展开**网页面板（那颗按钮「开」的那一半，2026-10-02 加）。
    ///
    /// 🔴 三个分支，按「还剩下什么」从多到少排 —— ⛔ 少任何一支都会变回「点了没反应」：
    /// - 内容还在（`webPage != nil`）⇒ 直接把显示打开 —— **原来的标签一个不少地回来**
    ///   （这是 2026-10-02 那条「内容常驻」需求的落点）；
    /// - 内容没了、但记得看过什么（`lastWebPageURL != nil`）⇒ `reopenLastWebPage()`
    ///   用记下的地址重建一个面板；
    ///   🔴 **2026-10-07 起这一支在产品路径上走不到了**：`webPage` 变 nil 只有
    ///   `closePanelTab(_:)` 关到空这一条路（`closeWebPage()` 不再被生产代码直接调），
    ///   而那条路紧接着就 `forgetPanelLocation()` —— 用户改口：
    ///   「最后一个标签 关闭标签 后 …… 重新打开 就是初始页」。
    ///   ⚠️ **保留**它，理由同 `reopenLastWebPage()` 那份头注（公共底座 · 探针直调 ·
    ///   将来「菜单 / 快捷键打开上次那页」这类入口还会用到）；⛔ 别顺手删。
    /// - **两样都没有**（从没看过任何页面 **或** 刚把标签全关掉）⇒ `openStartPagePanel()`
    ///   开一页起始页（2026-10-06 定「从没看过」那一档，2026-10-07 起也承接「刚关干净」那一档）。
    func showWebPagePanel() {
        if webPage != nil {
            isWebPagePanelShown = true
            return
        }
        if lastWebPageURL != nil {
            reopenLastWebPage()
            return
        }
        openStartPagePanel()
    }

    /// **彻底关掉**网页面板（内容与显示一起放掉）。关掉**最后一个**标签后走这里。
    ///
    /// ⚠️ 它**不是**那颗开关的落点（那是 `hideWebPagePanel()`）：用户把面板挪开一下
    ///    不该丢掉内容。这里只在「连内容都不要了」时用。
    ///
    /// ⚠️ 生产代码里**唯一**的调用点是 `closePanelTab(_:)`（关标签关到空，见那份头注）；
    ///    另有一批**探针**直接调它（`root_main.swift` 的 ⑤′ / ⑨ / ⑪）。
    ///    ⛔ 别在别处再叫一次 —— 契约钉着「`webPage = nil` 恰好出现 1 次」。
    ///
    /// 🔴 2026-10-07 起这里的记账**只对直接调用方有意义**：`closePanelTab` 关到空之后
    ///    会立刻 `forgetPanelLocation()`（用户改口：「如果关闭了 重新打开 就是初始页」）
    ///    ⇒ 产品路径上这一步等于白记。留着它是为了「直接放掉面板」这条底座还成立
    ///    （探针 ⑤′ / ⑨ 就靠它验「记住上一页 → 能恢复同一页」那一套）。
    func closeWebPage() {
        // 🔴 收起**不等于忘掉**：把「现在停在这一页」记下来再放掉面板，
        //    工具栏那颗开关的「开」才有一页可以恢复。
        // ☠️ 必须在 `webPage = nil` **之前**做（之后就问不到 webView 了）。
        rememberPanelLocation()
        webPage = nil
        // 🔴 内容没了，显示自然也不该留着（`.inspector` 的 get 会因此变 false）。
        isWebPagePanelShown = false
    }

    /// 关掉面板里的某一个标签；**关掉的若是最后一个标签 ⇒ 整个右侧页面一起收掉**。
    ///
    /// ## 🔴 用户要的是什么（2026-10-06，原话）
    /// 「如果上面标签 剩一个 关闭标签 就关闭整个右侧页面」。
    ///
    /// ## 🔴 2026-10-07 追加口径（原话）
    /// 「最后一个标签 关闭标签 后，在会话页面右上的按钮，重新打开后 会加载 最后一个标签的内容，
    ///   要求 **如果关闭了 重新打开 就是初始页**」。
    /// ⇒ 关到空时**顺手把两个账本清掉**（`forgetPanelLocation()`）：那颗开关的「开」不再
    ///   去重建刚关掉的那一页，而是落到 `openStartPagePanel()`（起始页）。
    /// ⚠️ 与「收起」那条路**刻意相反**：`hideWebPagePanel()` **不许**清账本 ——
    ///    收起是「挪开一下、内容常驻」（2026-10-02 定的，探针 ③ / ③′ 钉着）。
    ///    两条路的区别就一句：**面板还在不在**。在 = 留着；不在 = 忘掉。
    ///
    /// ## 🔴 为什么必须收整块面板，而不是留一块空的
    /// 标签一个都不剩时，内容区**什么也画不出来**：`WebPageModel.setupRelay()` 的空分支
    /// 把 `webView` / `activeFile` / `isStartPage` / `failure` 全置空 ⇒ 屏幕上只剩一条
    /// 光秃秃的导航条 + 一条 1pt 分隔线。那不是「空白页」，那是**看着像坏了**。
    ///
    /// ## 🔴 为什么判据落在这里（而不是两个调用点各写一遍）
    /// 面板上有**两组 ✕、两条路**，而其中一条**绕过 SwiftUI**：
    ///   - 导航条上那颗 ✕ —— `WebPageContentView.onClose`，走 SwiftUI 闭包；
    ///   - 标签条每颗胶囊上的 ✕ —— AppKit 桥 `WebPageTabsBar.didCloseTab`，
    ///     直落 `WebPageModel`（`ToolbarItem` 内容是一次性快照，桥自己订阅模型重建子视图）。
    /// ⇒ 判据写两遍必然漂移（本工程既有口径：⛔ 别在两个地方各判一半）。
    ///   两处都只调这一个方法。
    ///
    /// - Parameter index: 要关掉的标签下标（标签条每颗胶囊自带，导航条传 `activeTabIndex`）。
    func closePanelTab(_ index: Int) {
        guard let page = webPage else { return }
        // ☠️ 顺序：**先记账、再关**。关掉**非最后一个**标签时这一句是必须的 ——
        //    它把账本拉回「关完之后激活的那个标签」（探针 ⑩ ⇢ ① 故意造「账本 ≠ 激活标签」
        //    的错位来钉这件事）。顺序反了 ⇒ 删空之后 `currentURL` 问不到东西
        //    ⇒ 账本停在被关掉的那个标签上。
        //    ⚠️ 紧接着的 `closeWebPage()` 里还会再记一次，但那时守卫
        //    （`page.currentURL` 为 nil）不成立 ⇒ 不会把这里记的覆盖掉。
        //    🔴 关到空那条路上这一句算是**白记**（下面立刻 `forgetPanelLocation()`）——
        //    留着它不是为了那次赋值，而是让「记账」在两条分支上**形状一致**：
        //    读代码的人不用先判「这次会不会被清」。
        rememberPanelLocation()
        page.closeTab(at: index)
        if page.isEmpty {
            closeWebPage()
            // 🔴🔴 2026-10-07 用户改口（原话见本方法头注）：**关掉最后一个标签 = 忘掉它**。
            //    两个账本一起清 ⇒ `showWebPagePanel()` 落到第三支 `openStartPagePanel()`
            //    ⇒ 那颗开关「再打开」出来的是**初始页**，不再是刚关掉的那一页。
            //    ☠️ 必须排在 `closeWebPage()` **之后**：那个方法会**先记账、再放内容**
            //    （在关到空这条路上守卫不成立、实际什么都没写，但那属于它的实现细节）
            //    ⇒ 清账本放在**最后一次写之后**，才是「无论前面写了什么，账本一定是干净的」。
            //    ⛔ 别把这一句搬进 `closeWebPage()` 自己：那条路还被探针直接调着，
            //    而「直接放掉面板」这条底座的语义就是「记住上一页能恢复」。
            forgetPanelLocation()
        }
    }

    /// 把「用户正停在哪一页」记进**两个账本**（地址 + 文件名）。
    ///
    /// 🔴 抽出来是因为它有**三个**调用点：`hideWebPagePanel()`（收起）·
    ///    `closeWebPage()`（彻底关）· `closePanelTab(_:)`（关标签）。
    ///    三处抄同一段 = 将来加第三个账本必然漏一处。
    /// ⚠️ 最后一个调用点里，关到空那条分支紧接着还会 `forgetPanelLocation()`（2026-10-07 口径）
    ///    —— 「记」与「忘」是一对，改一个别忘了另一个。
    ///
    /// ## 两个账本各是什么
    /// - `lastWebPageURL` = 地址；
    /// - `lastPanelFileDisplayName` = **本地内容的显示名** —— 它**不在 URL 里**
    ///   （会话附件落盘后磁盘名是 UUID，`52EDE56F-….xlsx`）。
    ///   🔴 2026-10-07：**目录与代码也走这本账** ⇒ 取的是 `activeLocal`（不是 `activeFile`）
    ///   —— 用 `activeFile` 的话，收起面板时如果停在目录/代码上，名字会丢（回退成 UUID 式标题）。
    ///
    /// ⚠️ 记的是 `currentURL` 而**不是** `initialURL`：用户完全可能在面板里点进了二级页
    ///    （面板自己有 ← → 与站内导航），开关再打开时该回到他实际停的那一页。
    /// ☠️ 必须在面板**还活着**的时候调（`webPage = nil` 之后就问不到了）。
    /// ⚠️ 起始页标签没有 URL ⇒ 这个守卫会让它**什么都不记**（保持上一次的值，而不是清空）。
    private func rememberPanelLocation() {
        if let page = webPage, let url = page.currentURL {
            lastWebPageURL = url
            lastPanelFileDisplayName = page.activeLocal?.displayName
        }
    }

    /// 把**两个账本一起清空** —— 「关掉最后一个标签，就是把这块面板忘掉」（2026-10-07）。
    ///
    /// ## 🔴 为什么需要它（用户原话）
    /// 「最后一个标签 关闭标签 后，在会话页面右上的按钮，重新打开后 会加载 最后一个标签的内容，
    ///   要求 **如果关闭了 重新打开 就是初始页**」。
    /// 改口径之前，「关掉最后一个标签」是**唯一**还留着账本的产品动作：`closePanelTab(_:)`
    /// 先记账、再关到空 ⇒ 那颗开关「再打开」会**回到刚关掉那一页**（正是用户这次报的行为）。
    /// 现在要的是**初始页** ⇒ 关到空之后账本必须为空（`showWebPagePanel()` 第三支）。
    ///
    /// ⚠️ 与 `rememberPanelLocation()` 是**一对**：将来加第三个账本，两个方法一起改 ——
    ///    ⛔ 只改「记」的那一半，就是「收起记得住、关掉却忘不掉」这类错的标准开法。
    /// ⛔ **只在「关到空」这一处调**：收起（`hideWebPagePanel()`）不许清账本 ——
    ///    那一路要的正是「记得住、再打开原样回来」（2026-10-02 口径，探针 ③ / ③′ 钉着）。
    private func forgetPanelLocation() {
        lastWebPageURL = nil
        lastPanelFileDisplayName = nil
    }

    /// 重新打开**上一次那一页** —— 工具栏那颗「网页」开关「开」的那一半（2026-09-30）。
    ///
    /// ⚠️ 记录为空时**什么都不做**（⛔ **别**在这里硬编一个起始页 —— 那条路是
    ///    `openStartPagePanel()`，由调用方 `showWebPagePanel()` 在**判完账本之后**选）。
    ///    留着这条 guard 现在有两层理由：
    ///    ① 「打开网页」将来还会有别的入口（菜单 / 快捷键），把口径钉在模型这一层，
    ///       各入口就不用各自解释一遍（与 `openWebPage` 里那条非 http(s) 交回系统的闸同理）；
    ///    ② ☠️ 它被**源码契约**钉着（`render_mac_ui.sh`：「记录为空时直接 return」）。
    ///
    /// 🔴 **2026-10-07 起产品路径上走不到它**：唯一会让 `webPage` 变 nil 的
    ///    `closePanelTab(_:)` 关到空之后会 `forgetPanelLocation()`（用户改口：
    ///    关掉最后一个标签 ⇒ 再打开要是初始页）。⇒ 那颗开关现在只会走
    ///    「内容还在 ⇒ 直接显示」与「两样都没有 ⇒ 起始页」两支。
    ///    ⚠️ **保留**：探针 ⑤′ / ⑨ **直接调它**验证「记住上一页 → 恢复同一页」这条底座，
    ///    而底座本身没坏（`closeWebPage()` 照旧记账）；将来若有「菜单：打开上次那一页」
    ///    这类入口，落点也还是它。⛔ 别因为「产品里没人调」就删掉 —— 先读这一段。
    func reopenLastWebPage() {
        guard let url = lastWebPageURL else { return }
        openWebPage(url)
    }

    // MARK: - 搜索

    /// 搜索面板是否**正在弹出**。
    ///
    /// 🔴 2026-09-22 从 `RootView` 的 `@State` 搬到这里，原因是**入口有两个**：
    /// ① 窗口工具栏那颗放大镜（挂在**侧栏那一列**上，与系统那颗侧栏开合按钮同格）；
    /// ② 菜单栏「编辑 → 搜索对话…（⌘F）」。
    /// 前者是 `RootView` 的子视图、可以靠闭包回传；后者挂在 **App 场景**上
    /// （`AsterMacApp.commands`），跟 `RootView` 之间没有视图层级可借 ——
    /// 两条路唯一的交汇处就是模型。
    ///
    /// ⚠️ ⌘F 为什么必须走菜单而不能只挂在按钮的 `.keyboardShortcut` 上：
    /// 侧栏一收起，工具栏上那一格（以及挂在它上面的按钮）可能跟着消失，
    /// 挂在按钮身上的快捷键**跟着失效** —— 而「侧栏收起时还想搜索」正是搜索最该在的场合。
    /// 菜单命令不随侧栏开合。
    var isSearchPresented = false

    // MARK: - 文档页（2026-10-10）

    /// 主区域是否正显示「文档」页。
    ///
    /// 🔴 用户 2026-10-10 拍板：**主区域整页替换**、且要**独立一页**
    /// （原话「不要在对话页面继续开发」）⇒ 它是 `RootView` 的 `detail` 里的一个二选一分支，
    /// **不是** `ChatDetailView` 内部的一段条件视图、也不是 sheet。
    /// ⛔ 改成 sheet 会被侧栏那颗入口的语义（「打开一页」）打回。
    var isDocumentsShown = false

    /// 「文档」页的数据：**跨会话**的文件列表，最近的在前。
    ///
    /// ⚠️ 与 `summaries` 一样是**同步拉取 + 存下来**（`refreshAll()` 的同一档）：
    /// 列表要反复重绘，每次重绘都去查库不值当。进页面时拉一次即可。
    private(set) var documents: [AIDocumentItem] = []

    /// 打开「文档」页（侧栏最上面那颗入口）。
    ///
    /// ⚠️ 每次打开都**重拉一次**：用户可能刚在会话里传完文件，
    /// 不刷新的话新文件要等到重启才出现（那是「点了没反应」的另一种形态）。
    func showDocuments() {
        documents = AIChatStore.shared.fetchDocuments()
        isDocumentsShown = true
        // 🔴 标题跟着页走（用户 2026-10-12：切到「文档」时左上角要变成「文档」）。
        //    ⚠️ 这里**不走 `refreshAll()`** —— 本方法刻意只拉文档列表，不该顺手重抄一遍会话。
        refreshTitle()
    }

    /// 关闭「文档」页，回到对话。
    func hideDocuments() {
        isDocumentsShown = false
        // 标题要跟着变回会话名（`showDocuments()` 的反面，同一处口径）
        refreshTitle()
    }

    /// 点文档列表里的一行：在**右侧面板**里打开它（走 `WebTabKind.file` 那条已验证的路）。
    ///
    /// 🔴 不 `NSWorkspace.open` 交给别的 App：工程既有口径是「App 内看」——
    ///    会话里点文件消息走的也是面板（`openFilePreview` / `openLocalInPanel`），
    ///    同一种东西在两处行为不一致会更让人困惑。
    /// ⚠️ `displayName` 必须带：磁盘名是 UUID，不带的话面板标题就是那串乱码。
    func openDocument(_ item: AIDocumentItem) {
        openLocalInPanel(item.fileURL, displayName: item.displayName)
    }

    /// 搜索历史对话：标题 + 全部消息正文命中（标题命中排在前）。
    ///
    /// **同步**返回 —— 业务层就是同步的（`AIChatStore.search` 一次扫全库），
    /// 这里不假装异步。防抖与「结果过期丢弃」都在调用方（`MacSearchView`），
    /// 因为只有它知道用户的手停下来没有。
    func searchHistory(keyword: String) -> [AIChatSearchHit] {
        manager.search(keyword: keyword)
    }

    /// 打开一条搜索结果：**切会话 + 请右栏把命中的那一条露出来**。
    ///
    /// 为什么要两件事一起：只切会话的话，右栏停下来的是**列表底部**（贴底行为），
    /// 而命中往往在几百条之前的深处 —— 用户得自己一路往上翻，等于搜索没帮他省事。
    /// `hit.messageId` 与 `AIChatBlock.id` 是同一个 UUID（落库时就是它），
    /// 所以「露出来」能做到**精确到那一条**，而不是只到那个会话。
    ///
    /// ⚠️ 标题命中没有 `messageId`（它不是任何一条消息）→ 只切会话，不定位。
    func open(searchHit hit: AIChatSearchHit) {
        select(hit.conversationId)
        guard let messageId = hit.messageId else { return }
        revealToken += 1
        revealTarget = RevealTarget(rowId: messageId, token: revealToken)
    }

    /// 点消息气泡里那条**引用** → 把被引用的原消息露出来（2026-10-21 补，A1 最后一块：
    /// 「点引用条跳转定位」之前只有 iOS 有，Mac 的引用条是只读的）。
    ///
    /// 🔴 与 `open(searchHit:)` **同一套机制**（`RevealTarget` + 自增 token）—— 刻意复用：
    ///    「滚到那一行 + 圈一下 + 取消贴底跟随」三件事搜索定位已经做完（消费方
    ///    `ChatDetailView.reveal(_:proxy:)`），新写一套必然漂移。
    /// ⚠️ `AIQuote.messageId` 存的是 `row.block.id`（见 `beginQuote`），而**所有造行路径
    ///    （发送 / 落库读回 / 对账重建）都是 `AIChatRow(id: block.id, …)`** ⇒ 两者恒等，
    ///    所以它能直接当 `scrollTo` 的锚点用（与搜索定位同精度，精确到条）。
    ///
    /// ⚠️ 原消息可能已经不在了：多选删除删掉它 / 重新生成换了 block id ⇒ 与 iOS
    ///    `revealMessage` **同一条口径**给个交代，⛔ 别静默什么都不做（「点了没反应」
    ///    会被当成 bug，这是本工程定的口径）。
    func revealQuotedMessage(_ quote: AIQuote) {
        guard manager.rows.contains(where: { $0.block.id == quote.messageId }) else {
            show(L("这条消息已不在当前会话里"))
            return
        }
        revealToken += 1
        revealTarget = RevealTarget(rowId: quote.messageId, token: revealToken)
    }

    /// 「请把某一行露出来」的请求。
    ///
    /// 🔴 **带 `token`** 是必须的：`onChange` 比的是值，用户连着点同一条结果两次
    /// （或先点 A 再点 A）时只改 `rowId` 不产生变化，第二次就不会触发滚动。
    /// token 每次自增，保证每一次请求都是「新值」。
    struct RevealTarget: Equatable {
        let rowId: UUID
        let token: Int
    }

    /// 待露出的一行（`ChatDetailView` 消费：滚到它 + 闪一下）。`nil` = 没有请求。
    private(set) var revealTarget: RevealTarget?
    private var revealToken = 0

    func newConversation() {
        stopSpeech()
        // 录到一半就换会话的话，识别结果会落进**新的**那个会话 —— 用户并没这个意思。
        // 与「朗读」同一条处理：换会话 = 上一件事的上下文没了，直接丢弃（没在录时是空操作）。
        cancelVoice()
        // 就地编辑同理：编辑的是**上一个会话里的某一条**，换走之后那一行在界面上已经没了，
        // 留着编辑态会让「保存」指向一条不存在的消息（`commitEdit` 会走 guard 直接收摊）。
        cancelEdit()
        // 引用同理：引用的是**上一个会话里的某一条** —— 带着它发出去，等于把另一个会话的
        // 内容塞进这一轮的上下文（而且引用条上还写着那句）。换会话就丢掉。
        cancelQuote()
        // `@` 资料同理：它是「上一个会话所属项目」里的文件，换到新对话就该重新挑
        clearMentions()
        // 选择模式同理：勾中的那些行只存在于**上一个会话**里（切走之后勾选集合指向一批
        // 在新会话里根本不存在的 id，留着只会让底部栏报出一个删不掉的数）。
        exitSelectionMode()
        _ = manager.newConversation()
        selectedConversationId = manager.activeConversationId
        // 新对话 = 回对话页（此刻若正停在文档页，开新对话却还看着文档是说不通的）
        isDocumentsShown = false
        refreshAll()
    }

    func select(_ id: UUID) {
        // 🔴 这一句必须在 guard **之前**：「从文档页回到对话」最自然的动作就是点回**当前那个会话**，
        //    而它会被下面那条 guard 直接 return 掉 ⇒ 写在 guard 后面 = 点了没反应
        //    （用户明明点在上面了，主区域一动不动）。
        isDocumentsShown = false
        // 🔴 标题也必须在 guard **之前**跟着回来（2026-10-12）：
        //    从文档页点回**当前那个会话**会走那条 guard 直接 return ⇒ 不在这里补一刀的话，
        //    页已经切回会话了、左上角还写着「文档」。（`isDocumentsShown` 那条注释是同一个坑。）
        refreshTitle()
        guard id != manager.activeConversationId else { return }
        stopSpeech()
        cancelVoice()
        cancelEdit()
        cancelQuote()
        // `@` 资料跟着会话的项目走：切到别的项目（含默认项目「任务」）后旧的资料不再适用，
        // ⚠️ 与 `cancelQuote` 一起清 —— 两者都是「这一条消息的上下文」，换会话就该重新挑
        clearMentions()
        exitSelectionMode()
        guard manager.switchToConversation(id: id) else { return }
        selectedConversationId = id
        refreshAll()
    }

    func delete(_ id: UUID) {
        // 删的可能正是正在朗读的那个会话 —— 不停的话声音会一直念一条已经不存在于界面的消息
        stopSpeech()
        // 删掉的可能正是语音要说给的那个会话 ⇒ 同样丢弃（没在录时是空操作）
        cancelVoice()
        // 编辑态同理：那一行马上就没了
        cancelEdit()
        // 引用条上那条引用也在这个会话里 —— 一起丢（与 `deleteRows` 里那条同一个理由）
        cancelQuote()
        // 选择的那些行也在这个会话里 —— 一起退（会话都没了，勾选集合无从谈起）
        exitSelectionMode()
        manager.deleteConversation(id: id)
        // 删的就是当前会话时，manager 会切到空会话；否则沿用当前选中
        selectedConversationId = manager.activeConversationId
        refreshAll()
    }

    func rename(_ id: UUID, to title: String) {
        manager.renameConversation(id: id, to: title)
        refreshAll()
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        manager.setConversationPinned(id: id, isPinned: pinned)
        refreshAll()
    }

    // MARK: - 项目（会话文件夹，2026-10-21）

    /// 当前会话所属项目（2026-10-25 起恒非 nil：默认项目「任务」兜底）。
    /// 侧栏高亮 / 项目级指令都读它。
    var activeProjectId: UUID? { manager.activeProjectId }

    /// 新建项目（空名称由 store 拒绝，返回 nil）。成功后刷新 —— 侧栏要立刻出现分组头。
    @discardableResult
    func createProject(name: String) -> AIChatProject? {
        let project = manager.createProject(name: name)
        if project != nil { refreshAll() }
        return project
    }

    func renameProject(_ id: UUID, to name: String) {
        manager.renameProject(id: id, name: name)
        refreshAll()
    }

    func setProjectInstruction(_ id: UUID, _ text: String) {
        manager.setProjectInstruction(id: id, instruction: text)
        // 指令是下一轮请求才生效 ⇒ 这里刷新只为让管理页上的「已设置」标记跟上，
        // 不需要重发任何消息（`effectiveSystemPrompt` 每轮现读）
        refreshAll()
    }

    /// 读项目指令（管理面板的编辑器初值）
    func projectInstruction(_ id: UUID) -> String {
        manager.projectInstruction(id: id) ?? ""
    }

    /// 删除项目：会话**不会**被删，只是移回默认项目「任务」（级联策略在 store 里）。
    /// ⚠️ 默认项目自己删不掉（store 层拒绝 + 侧栏不给那颗钮）。
    func deleteProject(_ id: UUID) {
        manager.deleteProject(id: id)
        refreshAll()
    }

    /// 移动当前（或任意）会话到某项目；`nil` = 归一成默认项目「任务」
    /// （2026-10-25 起「未归类」已消灭）
    func moveConversation(_ id: UUID, toProject projectId: UUID?) {
        manager.setConversationProject(conversationId: id, projectId: projectId)
        refreshAll()
    }

    // MARK: 项目资料（L2，2026-10-21）

    /// 某项目的资料列表（时间倒序）
    ///
    /// ⚠️ 刻意**不做成 `private(set) var` 缓存**：项目资料是「打开某个项目的面板时看一次」
    /// 的数据，不像 `summaries` 那样常驻在侧栏。加个缓存就要在每个写入点记得失效
    ///（现在有三处：添加 / 删除 / 删项目），漏一处就是「刚加的文件在面板里看不见」。
    func projectFiles(_ projectId: UUID) -> [AIChatProjectFile] {
        manager.fetchProjectFiles(projectId: projectId)
    }

    /// 导入外部文件为项目资料（落盘走 `AIAttachmentStorage`，落库失败会回滚删文件）
    @discardableResult
    func addProjectFile(_ projectId: UUID, from url: URL) -> Bool {
        manager.addProjectFile(projectId: projectId, sourceURL: url) != nil
    }

    /// 某项目的索引状态（项目详情页那行「已索引 N/M · K 个片段」）
    func projectIndexStatus(_ projectId: UUID) -> AIProjectIndexStatus {
        manager.projectIndexStatus(projectId: projectId)
    }

    /// 重建某项目的检索索引（详情页「重建索引」）
    func rebuildProjectIndex(_ projectId: UUID) {
        manager.rebuildProjectIndex(projectId: projectId)
    }

    /// 删除项目资料（行 + 物理文件）
    func deleteProjectFile(_ fileId: UUID) {
        manager.deleteProjectFile(id: fileId)
    }

    /// 把一条项目资料**拷一份**塞进待发送列表（「+ → 项目资料」那条路）。
    ///
    /// 🔴 必须拷贝：待发送区那条 ✕ 会连盘删（`AIAttachmentStorage.remove`），
    ///    直接引用项目里的文件 ⇒ 用户撤销一次就把项目资料删了。
    /// ⚠️ 落地走 `ComposerAttachmentPicker.importURLs`（与「上传文件」逐字同一条：
    ///    图片压缩、文件夹拦截、部分失败提示全都在里面），⛔ 别在这里自己 `importFile`。
    @MainActor
    func attachProjectFile(_ file: AIChatProjectFile) {
        guard let url = file.fileURL else {
            show(L("文件已不存在"))
            return
        }
        ComposerAttachmentPicker.apply(ComposerAttachmentPicker.importURLs([url]), to: self)
    }

    /// 把一个会话导出成纯文本（左栏「分享…」用）。
    ///
    /// ⚠️ 它是个**只读查询，刻意不 refreshAll()** —— 导出不改任何可见状态，
    ///    刷新一遍只会让刚关掉菜单的那一行重画一次（还可能在快速点选时打断选中动画）。
    func transcript(of id: UUID) -> String? { manager.transcript(conversationId: id) }

    /// 重新生成某一行的回复
    func regenerate(rowIndex: Int) {
        // 旧回复马上会被删掉换成流式占位行 —— 继续念一段已经不在屏幕上的文字很怪
        stopSpeech()
        // 被引用的正是这一条 → 引用条一起收（同 `deleteRows` 里那条：别引用一条已经不存在的消息）
        if manager.rows.indices.contains(rowIndex),
           pendingQuote?.messageId == manager.rows[rowIndex].block.id {
            cancelQuote()
        }
        guard manager.regenerate(fromRowAt: rowIndex) else { return }
        refreshAll()
    }

    /// 继续生成（半截回复）
    func continueGeneration(rowIndex: Int) {
        guard manager.continueGeneration(fromRowAt: rowIndex) else { return }
        refreshAll()
    }

    // MARK: - 选择模式（多选删除，2026-09-29）
    //
    // 与 iOS 完全同构（那边是 `AIModuleViewController+Selection.swift`）：点「删除」**不直接删**，
    // 而是让列表进选择模式 —— 每条消息左侧长出勾选圈、**默认勾上这一轮**（提问 + AI 回复），
    // 由用户在底部那条栏里确认要删哪几条。
    //
    // ## 为什么改成这样（Mac 上一版是「弹个确认框就删」）
    // 删除不可恢复（内存里删、库里也删，没有撤销 / 回收站）。确认框只兜得住「按错按钮」，
    // 兜不住「我想删的其实是另一条」—— 后者只能靠「先看见自己勾了哪几条」。
    //
    // ## 三条入口共用这一套（别各写一份）
    // 右键菜单的「删除」· 助手文本栏「⋯ → 删除」· 媒体栏「⋯ → 删除」——
    // 三个入口都只做一件事：`enterSelectionMode(startingAt:)`。删什么、删几条由用户在
    // 选择模式里定（媒体栏也一样：进模式后默认勾的是**整轮**，与 iOS 同口径）。

    /// 是否处于「多选删除」选择模式（视图据此换成勾选圈 + 底部选择栏）。
    private(set) var isSelectionMode = false

    /// 选择模式下**勾中的行 id**。
    ///
    /// 🔴 **勾选集合是唯一真值**：底部栏的报数、每行的圈、最终删哪些行全部读它。
    /// ⛔ 别在视图里再存一份镜像 —— 两份必然错开，那时删的就是错的那些行。
    /// （iOS 那边这份真值在 `UITableView` 的编辑态里，Mac 没有表格，只能自己拿。）
    ///
    /// ⚠️ 存 **id 不存行下标**：确认弹窗弹出到用户点「删除」之间列表可能变
    /// （同 iOS `handleSelectionDelete` 里那条注释，本工程的老坑 —— 编辑重发之所以
    /// 存消息 id 而不是行号也是这个理由）。
    private(set) var selectedRowIds: Set<UUID> = []

    /// 勾中的**消息条数**（底部栏报数用）—— 🔴 **按「条」不按「块」，2026-10-09 改**。
    ///
    /// ## 为什么不是 `selectedRowIds.count`
    ///
    /// 那个 count 数的是**数据行**：一次发 5 张图 → 勾选集合里躺着 5 个行 id
    /// ⇒ 报数写「已选择 **5** 条」，而界面上用户看到的是**一条横排**。
    /// 用户 2026-10-09 原话：「删除数量 现在按照图片个数算的，要改成按照消息个数算」。
    ///
    /// ## 口径 = 「界面上占一条的那一行」
    ///
    /// 判据与换算都在**共享层** `AIChatMediaGrouping.selectedMessageCount(_:rowIndexes:)`
    /// （复用 `occupiesOwnRow`：组内第 2..N 行不占行 ⇒ 一条横排恒算 1 条）。
    /// 📌 与**勾选粒度**天然一致：界面上一条 = 一个勾选圈 ⇒「勾了几个圈就报几条」，
    /// 这是用户唯一能自己验的口径。
    ///
    /// 🔴 **只改报数、不改删除**：`selectedRowIds` 仍存全部行 id、删除仍整组删
    /// （`deleteSelection()` → `deleteRows(with:)` 一个字没动）。
    /// ⚠️ 别把删除也改成「只删组首」—— 那会回到「删一条消息、可图还剩好几张」。
    var selectedCount: Int {
        let rows = manager.rows
        let indexes = selectedRowIds.compactMap { id in
            rows.firstIndex(where: { $0.id == id })
        }
        return AIChatMediaGrouping.selectedMessageCount(rows, rowIndexes: indexes)
    }

    /// 进入选择模式，并**默认勾上** `rowId` 所在的**整轮**（提问 + AI 回复）。
    ///
    /// - Returns: 是否真的进去了。`false` 表示被闸门拦下（提示已经在这里给过了，
    ///   调用方不用再补一句 —— 补了就是两条 toast 叠在一起）。
    @discardableResult
    func enterSelectionMode(startingAt rowId: UUID) -> Bool {
        guard !isSelectionMode, !manager.rows.isEmpty else { return false }
        // 流式中不给进。菜单里已经按 `blockedWhileStreaming` 把这一项置灰了，这里是**兜底**：
        // 将来若有别的入口接进来，不会绕过这道闸（删行会让后面所有行的下标前移，
        // 而流式正靠行下标写那一行）。
        guard !isStreaming else {
            show(L("正在回复中，先停下再删"))
            return false
        }
        guard let index = manager.rows.firstIndex(where: { $0.id == rowId }) else { return false }

        // 进之前收掉两样会跟「点一下 = 勾选」抢拍的东西：
        // - **就地编辑态**：编辑框自己会吃掉内部的点击（而它底下那条用户气泡正是要勾的行）；
        // - **语音输入**：录着音进选择模式，结束那一刻识别结果会凭空发出一条新消息。
        //   （2026-10-03 起录音浮层不再长在输入栏里、而是挂在详情页的浮层上 ⇒ 它**不会**
        //    再随输入栏一起消失，这条更省不得：不收就是「录音照跑、蓝光面板还飘在那儿」。）
        cancelEdit()
        cancelVoice()
        isSelectionMode = true

        // 默认勾整轮。行区间**在这一刻现算**：进来之后列表不会再变（输入栏已让位、流式已停、
        // 编辑态已收），此刻算出来的行号就是稳的。
        // ⚠️ `turnRowRange` 取不到时退回「只勾这一条」—— 进去一个都没勾的样子看起来就像功能坏了。
        let range = manager.turnRowRange(containingRowAt: index) ?? index...index
        selectedRowIds = Set(range.compactMap { manager.rows.indices.contains($0) ? manager.rows[$0].id : nil })
        return true
    }

    /// 点一行 = 勾上 / 取消勾选**这一组**。
    ///
    /// ⚠️ 传的是**一组 id** 而不是一个：Mac 的媒体行是一次显示项投影（`ChatTranscriptItem.group`），
    ///    界面上那一条代表组内所有行 —— 点它却只勾中组首那条的话，用户看到的是
    ///    「删掉一条，可图还剩好几张」（与 iOS `handleSelectionDelete` 里展开媒体组同一个理由）。
    /// ⚠️ 判据是「**整组都已勾上**才取消」：组内部分勾上时再点一下应当补齐，而不是把剩下的也去掉。
    func toggleSelection(rowIds: [UUID]) {
        guard isSelectionMode, !rowIds.isEmpty else { return }
        if rowIds.allSatisfy({ selectedRowIds.contains($0) }) {
            selectedRowIds.subtract(rowIds)
        } else {
            selectedRowIds.formUnion(rowIds)
        }
    }

    /// 退出选择模式。**幂等**（不在选择模式时什么都不做）。
    ///
    /// 五条路径都走这里：底部栏「取消」、Esc、删完、切会话 / 新建 / 删会话（那三处见
    /// `newConversation` / `select` / `delete`）—— 那些地方不退出的话，勾选集合会指向
    /// 一批在新会话里根本不存在的行。
    func exitSelectionMode() {
        guard isSelectionMode else { return }
        isSelectionMode = false
        selectedRowIds = []
    }

    /// 底部栏「删除(N)」二次确认之后真正执行的那一下。
    ///
    /// - Returns: 是否真的删掉了。`false` 的两种成因（弹窗期间刚好开始了流式 / 这些消息
    ///   已经不在了）都**必须出声**：静默 return 的观感与「功能坏了」一模一样
    ///   （同 iOS `confirmDeleteSelection` 里那条）。
    @discardableResult
    func deleteSelection() -> Bool {
        // ☠️ 传下去的是**行 id**，而业务层 `deleteMessages(withIds:)` 只认**消息 id**
        // （它内部判的是 `$0.block.id`）。今天能对上，是因为**真实业务层造行时就拿 block.id 当行 id**
        // （`AIChatManager` 造行处 / `AIChatStore` 恢复处）—— ⛔ 那两处等于契约：
        // 哪天把行 id 换成独立 UUID，这里会**静默**变成「一条都删不掉，只弹一句这些消息已经不在了」。
        // （iOS 侧是在 `selectedMessageIds()` 里**显式**换成 block id 的；Mac 靠的是上面那条前提。
        //   渲染台夹具的行 id 恰好是独立 UUID ⇒ 在那边按 id 比会假红，详见该夹具的注释。）
        let ids = selectedRowIds
        guard !ids.isEmpty else { return false }
        // 先退出选择模式**再**删：删完 `rows` 整批换掉，勾选集合留着只会指向一堆不存在的行
        // （同 iOS：表格还在编辑态时会按旧行数与新数据对不上）。
        exitSelectionMode()
        guard !isStreaming else {
            show(L("正在回复中，先停下再删"))
            return false
        }
        guard deleteRows(with: ids) else {
            show(L("这些消息已经不在了"))
            return false
        }
        return true
    }

    /// 删除的**共同收尾**（别各写一份 —— 漏掉哪一条清理都会留下悬空引用）。
    ///
    /// ⚠️ 名字刻意避开 `deleteMessages`：业务层的 `AIChatManager` 有同名方法
    /// （下面调的就是它），重名会让「我到底在调哪个」变成每次 review 都要查一遍的事。
    /// - Returns: 业务层是否真的删了（它自己会拦「流式中」与「id 不存在」两种情形）。
    @discardableResult
    private func deleteRows(with ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty else { return false }
        // 删掉的正好是正在朗读的那条 → 一起停（别让声音念一条已经不在界面上的消息）
        if let speaking = speakingRowId, ids.contains(speaking) { stopSpeech() }
        // 删掉的正好是正在编辑的那条 → 一起收（否则「保存」会指向一条已经不存在的消息）
        if let editing = editingRowId, ids.contains(editing) { cancelEdit() }
        // 删掉的正好是**被引用的那条** → 引用条也一起收。
        // 不收的话输入框上方会挂着一段「引用了一条已经不在的消息」，发出去就是把一段
        // 界面里根本找不到的文字当上下文 —— 用户完全没法解释它从哪来。
        if let quoted = pendingQuote?.messageId, ids.contains(quoted) { cancelQuote() }
        guard manager.deleteMessages(withIds: ids) else { return false }
        refreshAll()
        return true
    }

    // MARK: - 容器宽度

    /// 把滚动区的真实宽度灌给业务层（`ChatDetailView` 的 GeometryReader 调）。
    ///
    /// 为什么还是要灌：`AIChatManager` 每次插行 / 收尾都会用 `contentWidth` 算一遍行高，
    /// 不灌的话那个值会一直停在 `AIPlatformMetrics.defaultContainerWidth`（Mac 侧 900 的占位），
    /// 算出来的行高与实际无关 —— 虽然 SwiftUI 不读它，但留着一堆错值迟早会坑到下一个读它的人。
    ///
    /// ⚠️ 刻意**不调** `manager.recomputeAllRowHeights()`：那是「按新宽度把全表重算一遍」，
    /// 拖拽窗口时每帧都会跑；而 SwiftUI 自己按内容量高，压根不读 `cachedHeight`。
    func updateContentWidth(_ width: CGFloat) {
        guard width > 0, abs(width - manager.contentWidth) > 0.5 else { return }
        manager.contentWidth = width
    }

    // MARK: - 状态同步

    /// 把 manager 的真值抄进 SwiftUI 状态。
    ///
    /// ⚠️ `contentWidth` 也在这里兜一道默认值：`AIChatManager` 的默认宽度是
    /// `AIPlatformMetrics.defaultContainerWidth`（Mac 侧 900 的占位值），
    /// 真正的宽度由 `ChatDetailView` 的 GeometryReader 灌进来。首帧若还没灌，
    /// 行高按 900 算 —— 比按 0 算（每行都超高）好得多。
    private func refreshAll() {
        rows = manager.rows
        summaries = manager.fetchSummaries()
        projects = manager.fetchProjects()
        // 开关真值在 `AIGenerationSettings`（非 @Observable）⇒ 每次整体刷新顺手对齐一次。
        // 赋值同值不会触发重算（`@Observable` 有变化判等），所以这里不必再写 `if`。
        webSearchEnabled = AIGenerationSettings.webSearchEnabled
        isSearchingWeb = manager.isSearchingWeb
        refreshTitle()
    }

    /// 重算左上角那个标题（`title`）。**唯一**允许给 `title` 赋值的地方。
    ///
    /// 口径（**页感知**）：
    /// - 「文档」页 → `documentsPageTitle`（「文档」）
    /// - 会话页 → 会话标题；还没有标题的新会话 → `newConversationTitle`（「新对话」）
    ///
    /// ⚠️ 只在值**真的变了**才赋值：`@Observable` **不比较相等性**，无脑赋值会让
    /// `RootView.body`（连带整个 `NavigationSplitView`）白重算一次 —— 而切会话那一拍
    /// 本来就在忙（`refreshAll` 一秒钟能被 delegate 调几十次）。
    private func refreshTitle() {
        let next = isDocumentsShown
            ? Self.documentsPageTitle
            : (manager.activeTitle.isEmpty ? Self.newConversationTitle : manager.activeTitle)
        guard title != next else { return }
        title = next
    }

    /// 语言档位变了之后，模型侧要跟着重算的东西（2026-10-13）。
    ///
    /// 🔴 为什么光让视图重建**不够**：`title` 是**存储**属性，它里面存的是上一档语言那份
    ///    `L()` 结果；视图重建只让视图重新读它一次，读到的还是旧值。
    ///    （`documentsPageTitle` / `newConversationTitle` 那两条已经从 `static let` 改成
    ///    计算属性，所以「重算一次」就能拿到新语言那份。）
    /// ⚠️ 由 `RootView` 订阅 `AILanguageStore.didChange` 时调用 —— ⛔ 别让视图层去直接写
    ///    `model.title`（那是 `refreshTitle()` 单漏斗的活）。
    func languageDidChange() {
        refreshTitle()
    }

    // MARK: - 提示

    /// 顶部飘一条提示，3 秒后自动消失。
    ///
    /// ⚠️ 2026-09-22 从 `private` 放开：侧栏的「AI创作」入口功能**还没接**，
    ///    点它必须有明确反馈（静默无反应会被当成 bug），走的也是这条通道。
    ///    文案由调用方给 —— 侧栏才知道自己在说什么。
    func show(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.toast = nil
        }
    }

    // MARK: - AIChatManagerDelegate
    //
    // 八个回调的语义不同（iOS 侧据此做三类增量刷新），但对 SwiftUI 来说
    // **处理方式完全一样**：重读 rows。所以这里没有一一对应的复杂逻辑，
    // 只在「需要给用户一句话」的地方（出错 / 截断 / 上下文裁剪）额外提示。

    func chatManagerDidInsertRows(_ manager: AIChatManager, at indexes: [Int]) {
        refreshAll()
    }

    func chatManagerDidUpdateStreamingText(_ manager: AIChatManager, rowIndex: Int, text: String) {
        refreshAll()
    }

    /// 流式**思考过程**刷新（2026-10-20）：思考先于正文到达。与其它回调同一套处理
    /// （SwiftUI 侧就是重读 rows），没有额外逻辑。
    func chatManagerDidUpdateStreamingReasoning(_ manager: AIChatManager, rowIndex: Int) {
        refreshAll()
    }

    func chatManagerDidFinalizeRow(_ manager: AIChatManager, rowIndex: Int) {
        refreshAll()
        // 「这一轮没写完」必须主动说一声。不说就等于这个功能不可发现 ——
        // 用户看到半句话只会以为「模型就是这么答的」。
        // - Note: `endedTruncated` 是内存态、刻意不落库，所以重启后不再提示（见 `AIBlock`）。
        if manager.rows.indices.contains(rowIndex), manager.rows[rowIndex].block.endedTruncated {
            show(L("回复没写完，可在气泡上右键「继续生成」"))
        }
        // 🔴 通话窗那一轮回复**上屏完了** → 把正文交给它去念（见「打电话窗口」那一节，
        //    以及 `chatManagerDidFinish` 里那段"为什么不能在那儿转发"的说明）。
        //    这是朗读转发的**主入口**：此刻 `block.text` 才是完整正文。
        forwardReplyToVoiceCall()
    }

    func chatManagerDidReplaceRows(_ manager: AIChatManager) {
        refreshAll()
    }

    func chatManagerDidUpdateRowLayout(_ manager: AIChatManager, atRowIndexes indexes: [Int]) {
        refreshAll()
    }

    func chatManagerDidFinish(_ manager: AIChatManager) {
        refreshAll()
        // 这一轮回复生成完毕。用户等长回复时多半切去了别的 App ⇒ 不在前台才发通知
        // （前台判断在 notifier 内部，这里无条件调即可）
        // ⚠️ 描述用**本轮发送的文本**（`latestUserPrompt`），不是会话标题 ——
        //    标题是首条消息，多轮对话后会文不对题（2026-10-19 用户反馈）。
        AIReplyNotifier.replyFinished(conversationId: manager.activeConversationId,
                                      prompt: manager.latestUserPrompt)
        // ☠️☠️ 这里**不许**转发通话窗朗读（2026-10-12 改，真事故）。
        //
        //    本回调是「**流**结束」的当下，但 `AIChatManager.finish()` 里白纸黑字写着
        //    「流结束 ≠ 已经上屏完」：真实平台常常在结束时才把整段正文一次性发过来，
        //    而正文是由**打字机**（`tickReveal`）按 0.03s/帧、每帧最多 12 字
        //    慢慢往 `block.text` 里写的。
        //    ⇒ 此刻取 `lastAssistantReplyText()` 拿到的是**已上屏的那一截**，
        //    差的就是打字机还没吐出来的部分，用户听到的症状正是
        //    「**最后几个字或最后一小段读不出来**」（差多少取决于当时的积压量，
        //    所以时多时少、看起来很不稳定 —— 这正是它长期没被当成 bug 的原因）。
        //
        //    ✅ 转发已挪到 `chatManagerDidFinalizeRow`（正文全部上屏 + 落库之后）。
        //    ⛔ 别再挪回来"为了早点出声"：那不是节省，那是把结尾念丢。
    }

    func chatManager(_ manager: AIChatManager, didError error: Error) {
        refreshAll()
        show(String(format: L("出错了：%@"), error.localizedDescription))
        // 🔴 兜底转发：**发起之前**就失败的那类错误（缺 Key / 地址非法）在 `AIChatManager`
        //    里是几处**同步** `didError`，`handleError` 根本没进 ⇒ 一行都没动、也不会有
        //    `chatManagerDidFinalizeRow`。不在这里补一刀，通话窗会**永远卡在「正在思考…」**
        //    （用户以为还在等，其实早就断了）。
        //    ⚠️ 与 finalize 那条重复时是安全的：通话窗侧 `handleReplyFinished` 有
        //    `guard phase == .thinking`，第二次进来会被挡掉。
        //    ⚠️ 出错时 `lastAssistantReplyText()` 返回 nil（那一行 kind 已是 `.error`）
        //    ⇒ 通话窗收到空串 → 不念、直接接回「听着」，正是我们要的。
        forwardReplyToVoiceCall()
        // 失败也通知（用户切走后更该知道「挂了、原因是什么」）。
        // ⚠️ 同步类错误（刚点发送就缺 Key）那一刻用户必然在前台 ⇒ notifier 内部会挡掉。
        AIReplyNotifier.replyFailed(conversationId: manager.activeConversationId,
                                    prompt: manager.latestUserPrompt,
                                    reason: error.localizedDescription)
    }

    /// 上下文超预算、最早的若干条被丢掉。
    ///
    /// **只提示、不阻止** —— 裁多裁少都是估算（包里没有 tokenizer），
    /// 拿估算去拦请求会把本来发得出去的内容挡在门外，那比让服务端自己报错更糟。
    /// 提示的意义是「模型为什么像失忆了一样」，所以必须把原因说出来。
    func chatManager(_ manager: AIChatManager, didTrimContext droppedCount: Int, isOverBudget: Bool) {
        if isOverBudget {
            show(L("上下文已超出模型上限，这一轮可能失败"))
        } else {
            show(String(format: L("上下文较长，已省略最早 %d 条消息"), droppedCount))
        }
    }
}
