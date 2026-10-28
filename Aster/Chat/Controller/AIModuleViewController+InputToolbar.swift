import UIKit
import Photos
import SnapKit
import AICore

/// 输入栏配置 + 发送链路 + `InputToolbarDelegate`。
///
/// 三个概念别混：
/// - `configureInputToolbar()`：**一次性**样式与回调装配（`viewDidLoad` 里调一次）；
/// - `sendInput` / `send`：统一下行入口（文本可空、附件可空，两者至少有一个）；
/// - `InputToolbarDelegate`：输入栏**上行**事件（发送 / 「+」面板 / 语音按钮 / 键盘 / 超字数）。
///
/// 待发附件的增删**不在本文件** —— 详见 `+Attachment.swift`（那边才有「删预览要顺手删盘」的知识）。
extension AIModuleViewController {

    // MARK: - 配置

    /// 输入栏配置
    func configureInputToolbar() {
        inputToolbar.updateWithConfig { configure in
            configure.placeholder = L("问点什么…")
            // 与用户气泡、AI 气泡同一字号：打的时候看到的、发出去看到的、AI 回的一样大
            configure.font = AITypography.body
            configure.textViewMinLine = 1
            configure.textViewMaxLine = 4
            configure.textViewHeight = 36
            configure.textViewTopMargin = 2
            configure.textViewBottomMargin = 10
            configure.textColor = .label
            configure.cursorColor = .systemBlue
            configure.placeholderTextColor = .placeholderText
            configure.textMaxCount = 2000
            configure.isShowCameraButton = true
            configure.isShowVoiceButton = true
            configure.isShowMoreButton = true
            configure.horizontalMargin = 12
            configure.buttonSide = 32
            configure.buttonGap = 10
            configure.voiceButtonTitle = L("按住说话")
            // 「+」附件面板里那一行入口的高度。面板**总高**不在这里定 ——
            // 它跟系统键盘等高（`InputToolbar.systemKeyboardHeight`），否则键盘⇄面板切换时输入行会上下跳。
            configure.panelHeight = 100
        }
        // 项目资料检索的放大镜入口 2026-10-23 已删（用户拍板「默认关闭 + 删入口」）⇒
        // 装配时把存量 true 清成 false：UserDefaults 里的旧值不清，就是「按钮没了却每轮
        // 静默检索」（底层链路全保留，恢复指南见 VERIFY-PROBES.md §32.4；
        // 与 Mac 侧 `ChatModel.init` 同一条理由，各清各的沙盒）。
        AIGenerationSettings.resetLegacyProjectSearchEntry()
        // 四颗按钮的统一样式（圆形浅灰底 + 主色图标）。
        // 🔴 2026-10-21：`webSearchButton` **必须在这个循环里** —— 漏掉的那一刻它就没有
        //    灰底与圆角，视觉上比邻钮小一圈（用户当场就指出来了）。加键时记得同步这一步。
        //    （项目资料检索那颗放大镜 2026-10-23 进来过、当晚又随入口一起删了。）
        for btn in [inputToolbar.cameraButton, inputToolbar.modeButton, inputToolbar.moreButton,
                    inputToolbar.webSearchButton] {
            btn.backgroundColor = .secondarySystemFill
            btn.tintColor = .label
            btn.layer.cornerRadius = 16
            btn.layer.masksToBounds = true
        }
        // ⚠️ 循环刚把四颗都刷成灰底/黑图标 ⇒ 联网那颗要**再按偏好刷一遍**，
        //    否则「已开启」的强调色在每次装配时都被抹掉（用户看到开关自己关了）。
        refreshWebSearchEntry()

        // 待发附件条：只保留「删掉某一项」。
        // 🗑 原先这里还挂了个 `attachmentBar.onSend`（附件条右侧那颗蓝色发送按钮），2026-10-08 已删 ——
        //    「只发图不打字」的出口改成**按钮行里那颗「＋」切成发送态**（`InputToolbarDelegate.sendCurrentInputEvent`）。
        inputToolbar.onRemoveAttachment = { [weak self] index in
            guard let self else { return }
            self.removeAttachment(at: index)
        }
        // 🔴 2026-10-08：预览条**末尾那颗「＋」**（与图片 chip 同边长）⇒ 直接进系统相册。
        //    ⚠️ 刻意**不进** `attachmentEvent(_:)` 那个面板 —— 用户原话就是「进入系统相册选择图片」，
        //    已经站在预览条上了，再让他多点一层面板、中间还夹着相机/文件，是白绕。
        inputToolbar.onAddAttachment = { [weak self] in
            guard let self = self else { return }
            self.presentPhotoPicker(remaining: Self.maxAttachmentCount - self.pendingAttachments.count)
        }
        // 上限真身是 `Self.maxAttachmentCount`，预览条据此决定还摆不摆那颗「＋」
        inputToolbar.maxAttachmentCount = Self.maxAttachmentCount
        // `@` 资料 chip 上点 ✕（2026-10-21）：数据在这里，先删 chip 再抹掉正文里那串 `@名字`
        // ⚠️ 顺序反了（先删正文后删 chip）没有区别，但**两件都必须做**：
        //    只删 chip 会让输入框里留着一串「看起来还带着」的名字。
        inputToolbar.onRemoveMention = { [weak self] index in
            guard let self, self.pendingMentions.indices.contains(index) else { return }
            let mention = self.pendingMentions.remove(at: index)
            self.refreshMentionBar()
            self.inputToolbar.removeMentionToken(mention)
        }
        // 状态条上的「取消」：引用 → 清引用；编辑 → 退出编辑态（并清空输入区）
        inputToolbar.onCancelBanner = { [weak self] in
            guard let self = self else { return }
            if self.editingMessageId != nil {
                self.exitEditing(clearInput: true)
            } else {
                self.setPendingQuote(nil)
            }
        }

        // 按钮行里的模型名（与相机 / 语音 / 加号同行）：点它 → 弹底部列表换模型（写**会话槽位**，见下）
        inputToolbar.onTapModel = { [weak self] in
            guard let self else { return }
            self.presentSessionModelPicker()
        }
    }

    // MARK: - 会话窗口的模型（输入框下方按钮行里那枚胶囊）

    /// 刷新那颗胶囊上的文案。
    ///
    /// 🔴 改造前这里有一整套「落地会话槽」（`ensureSessionModel`）的动作，现在**只剩一次
    ///    `ensureCurrent()`** —— 因为「设置里配的」与「会话窗口选的」那**两个槽位已经合成一个**
    ///    （`AIModelStore.currentID`）：清单页只管「有哪些模型」、根本不回答「现在用哪个」，
    ///    于是「进设置改配置会把正在聊的窗口顶掉」这件事从根上不可能发生了，
    ///    也就不再需要「先给本窗口落地一个自己的值」这道工序。
    ///
    /// ⚠️ 仍然要落地一次（`ensureCurrent`）：清单非空而指针为空/悬空（首次启动、
    ///    或用户手改 JSON 把在用的那条删了）时把指针钉到第一条 —— 不钉的话
    ///    `composerLabel()` 会显示「未配置模型」，而实际上清单里明明有东西。
    ///
    /// ⚠️ 这里**不再顺带刷导航标题**（2026-10-02）：标题已与模型解耦（恒为 `defaultTitle`，
    ///    见 `refreshTitle`），在这条「模型状态变化」的路径上刷它就是一行没作用的代码 ——
    ///    留着反而会让人以为标题会跟着模型变。
    func refreshModelState() {
        AIConfig.ensureCurrent()
        // 🔴 那颗胶囊**总是显示**（2026-10-02 改）。
        //    因为它是 iOS 换模型的**唯一入口**（清单页只管清单、不管「用哪个」）——
        //    一旦「没有模型就不显示」，用户就再也切不回去 / 也看不到当前在用哪个了。
        //    文案口径收在共享层 `AIModelCatalog.composerLabel()`（一条都没有时返回「未配置模型」，
        //    **永不返回空串**），与 mac 那颗块读同一个函数。
        inputToolbar.setModelTitle(AIModelCatalog.composerLabel())
    }

    /// 点那枚模型胶囊 → 底部弹出的列表（**配齐的已配置模型**，选中即改「这一会儿用哪条」）。
    ///
    /// 🔴 与「添加模型」表单里那颗模型名下拉**必须分开**，虽然长得一样：
    ///    - 列表内容不同：这里是**配齐的条目**（`AIModelCatalog.readyChoices()` = `models.json`
    ///      里地址 / 模型名 / Key 三项都有的那些，2026-10-14 起收窄）；
    ///      表单那颗是**候选**（服务端 `/models` + 内置，用来决定「这一条叫什么」）。
    ///    - 落点不同：这里写 `AIConfig.currentID`（换**当前使用**）；表单只写那一条配置本身。
    ///    合成一处就等于把「配置」与「这一会儿用谁」又焊回一起 —— 那正是 2026-10-02 拆开的那对。
    ///
    /// ⚠️ 空列表时不会拦：列表页分别给「一条都没配置」（→ 底部那颗「添加模型…」）与
    ///    「有配置但都没配齐」（→ 「管理模型…」，进去补地址/Key）两种空态文案 ——
    ///    拦下来只会让人不知道该去哪儿。
    func presentSessionModelPicker() {
        // 先收键盘再弹：半屏 sheet 从底部升起，键盘这时已经无处可去（iOS 会自动 resign），
        // 但显式收一下能避免「键盘先弹一下再消失」的中间态。
        _ = inputToolbar.resignFirstResponder()

        // ⚠️ `AIConfig.currentID` 取的是**打开那一刻的快照**（本页不现读，见 picker 那边）——
        //    模态期间配置可能被广播刷新，用户看到的勾至少与他打开那一刻一致。
        let picker = AIModelPickerViewController(currentID: AIConfig.currentID ?? "") { [weak self] choice in
            // 🔴 一次动作只改一处：写「当前使用」的指针。改造前这里要改两个槽位
            //    （`currentProvider` + `setSessionModel`），现在一条配置自带地址与模型名，
            //    「换平台」不再是一个动作 —— 选了一条 = 连它背后的地址一起换了。
            //
            // 切换前后那两条要在**写指针之前**取：`noteModelSwitch(from:to:)` 要拿
            // 「从哪切到哪」记一条居中系统消息（2026-10-21），而名字是那一刻的快照
            // （见 `AIModelSwitch` 文件头）。写完之后 `AIModelStore.current` 已经是新的了。
            let previous = AIConfig.current
            AIConfig.currentID = choice.id
            // 同一个模型（点了当前已选中的那一项）时 `noteModelSwitch` 自己会拦住 ——
            // 这里照样调，省得在调用点再判一次「是不是同一个」
            if let previous, let now = AIConfig.current {
                self?.manager.noteModelSwitch(from: previous, to: now)
            }
            // 写完会广播（`notifyChange`）→ `configDidChange` 也会刷一次；这里仍显式刷一遍：
            // 广播那条路是给「别处改的配置」用的，本页自己的动作不该依赖它
            // （少一环就少一处能坏的地方，重复刷是幂等的）。
            //
            // ☠️ 上面那笔是**写全局配置**，与「本页还在不在」无关 ⇒ 解包只能放在**这之后**。
            //    提到最前面会让「用户在 sheet 里点了确定、配置却没落」（sheet 还开着时宿主先走），
            //    用户看到的就是"选了没反应"。这里只有 UI 刷新这一步是必须 self 的。
            guard let self else { return }
            self.refreshModelState()
        }
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .pageSheet
        // 高度口径与设置页那颗一致（直觉高度设在 **nav** 上：被 present 的是它）
        if #available(iOS 15.0, *), let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    // MARK: - 🧪 验收钩子：直接弹上面那个「选择模型」

    /// `STARRY_PICKER_UI=1` 时启动后**自动弹一次**「选择模型」（只弹一次，闩在
    /// `didAutoOpenSessionPicker`）。
    ///
    /// ## 为什么非要有这个钩子
    /// 这一页**只**从会话页输入栏那颗模型胶囊弹出来，而模拟器投不出合成触摸
    /// （`xcrun simctl` 没有 tap）⇒ 没有它，agent 侧一张图都拿不到这一页。
    /// 而 2026-10-14 这一页的全部改动（**只列配齐的条目** + **删掉搜索框**）
    /// 恰恰**都是视觉/数量**上的东西 —— 源码契约只证得了「代码在不在」，
    /// 证不了「列表里剩几条、第一行顶上有没有多出一块空白」。
    ///
    /// ## 三条约束（逐条照抄 `+Menu.openSettingsIfRequested`）
    /// 1. **只在 `#if DEBUG` 下编译进去** —— Release 包里这段根本不存在；
    /// 2. **只触发一次**（闩在 `didAutoOpenSessionPicker`）—— 这一页是 sheet，
    ///    关掉它会再触发一次宿主 `viewDidAppear`，没闩就是「关不掉」；
    /// 3. 走的是**和点胶囊完全相同的那条路**（`presentSessionModelPicker()`，
    ///    ⛔ 别在这里自己 `AIModelPickerViewController(...)` 造一个 —— 那样验的不是用户走的那条）。
    func openSessionPickerIfRequested() {
        #if DEBUG
        guard !didAutoOpenSessionPicker else { return }
        guard ProcessInfo.processInfo.environment["STARRY_PICKER_UI"] == "1" else { return }
        didAutoOpenSessionPicker = true
        // 等这一帧画完再弹（同通话页那条注释：`viewDidAppear` 里直接 present 会叠在半透明残影上）
        DispatchQueue.main.async { [weak self] in
            self?.presentSessionModelPicker()
        }
        #endif
    }

    /// `STARRY_PANEL_UI=1` 时启动后**自动开一次**「+」附件面板（只开一次，闩在
    /// `didAutoOpenAttachmentPanel`）。2026-10-16 画图入口（面板第四项）验收用。
    ///
    /// 三条约束逐条照抄 `openSessionPickerIfRequested`：`#if DEBUG` / 一次性闩 /
    /// 走用户那条路（`inputToolbar.openAttachmentPanelForProbe()` → `showAttachmentPanel`）。
    func openAttachmentPanelIfRequested() {
        #if DEBUG
        guard !didAutoOpenAttachmentPanel else { return }
        guard ProcessInfo.processInfo.environment["STARRY_PANEL_UI"] == "1" else { return }
        didAutoOpenAttachmentPanel = true
        // 等首屏帧画完再开（面板升起带动画，直接同步开会截到半透明中间态）
        DispatchQueue.main.async { [weak self] in
            self?.inputToolbar.openAttachmentPanelForProbe()
        }
        #endif
    }

    /// 🧪 **联网开关决策探针**（`STARRY_WEBSEARCH_PROBE=on|off|tap`，2026-10-21 加）。
    ///
    /// - `on` / `off`：把开关设成对应态（走与点地球键**同一条写入口**），等首屏后
    ///   把 `STARRY_WEBSEARCH_QUERY`（默认「北京天气」）真发出去；
    /// - `tap`：只调**按钮真正触发的那个回调**（`webSearchToggleEvent`），
    ///   打印翻转前后的值，用来证明「点击 → 写偏好 → 图标回写」这一环是通的。
    ///
    /// ## 为什么需要它
    /// 用户报「关掉联网问天津也能拿到天气」⇒ 怀疑开关没执行。而**关掉时模型照样会回答**
    /// （区别只在 system 里有没有资料块），肉眼根本分不出。合成点击又投不进去
    /// （见 `VERIFY-PROBES.md` 的本机硬限制）⇒ 只能用钩子跑真路径，
    /// 再看控制台那几行 `[WebSearch]`（`enabled=` / `hits=` / `digestLen=`）取证。
    ///
    /// 三条约束同 `openSessionPickerIfRequested`：`#if DEBUG` 编译 / 一次性闩 /
    /// 走用户那条路（`AIGenerationSettings` 写入 + `manager.send`）。
    func runWebSearchProbeIfRequested() {
        #if DEBUG
        guard !didAutoRunWebSearchProbe else { return }
        guard let mode = ProcessInfo.processInfo.environment["STARRY_WEBSEARCH_PROBE"] else { return }
        didAutoRunWebSearchProbe = true
        // 🧪 `tap` 档：只验「点击 → 写偏好 → 图标回写」这一环，不发消息。
        //    调的是**按钮真正触发的那个回调**（`webSearchToggleEvent`），
        //    绕开的只有「合成触摸投不进模拟器」这一步（见 VERIFY-PROBES 的本机限制）。
        if mode == "tap" {
            let before = AIGenerationSettings.webSearchEnabled
            webSearchToggleEvent()
            let after = AIGenerationSettings.webSearchEnabled
            NSLog("%@", "[WebSearchProbe] tap before=\(before ? 1 : 0) after=\(after ? 1 : 0)"
                + " flipped=\((before != after) ? 1 : 0)")
            return
        }
        let on = (mode == "on")
        AIGenerationSettings.webSearchEnabled = on
        refreshWebSearchEntry()
        let query = ProcessInfo.processInfo.environment["STARRY_WEBSEARCH_QUERY"] ?? "北京天气"
        NSLog("%@", "[WebSearchProbe] mode=\(mode) enabled=\(on ? 1 : 0) query=\(query)")
        // 等首屏落地再发（同其它钩子：帧没画完就发，截到的是空表）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if !self.manager.send(query) {
                NSLog("%@", "[WebSearchProbe] send 返回 false（配置没配齐 / 输入为空）")
            }
        }
        #endif
    }

    /// 🧪 **`@` 项目资料探针**（`STARRY_MENTION_PROBE=1`，2026-10-21 加）。
    ///
    /// 为什么要它：`@` 的入口是「打 @ → 弹系统模态选择页 → 选一行」，
    /// 而合成触摸在本机**投不进去**（见 `VERIFY-PROBES.md` 的硬限制）⇒ 面板那一路只能人手点。
    /// 这个探针走的是**选完之后**那条真路径：建项目 → 把当前会话归进去 → 导入一份示例资料 →
    /// `appendMention(_:)`（就是 `onSelectFile` 里调的那一个）。于是 chip 条、正文里那串
    /// `@名字`、以及「上限/去重」都能截到图。
    ///
    /// ⚠️ 它**不伪造** `pendingMentions`：真值是 `appendMention` 写进去的，
    ///    这里只是替用户把「选哪一份」这一步给定了（⛔ 别改成直接 `pendingMentions.append`，
    ///    那就绕过了 `refreshMentionBar` 的归属校验，验的就不是同一条路了）。
    func runMentionProbeIfRequested() {
        #if DEBUG
        guard !didAutoRunMentionProbe else { return }
        guard ProcessInfo.processInfo.environment["STARRY_MENTION_PROBE"] != nil else { return }
        didAutoRunMentionProbe = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            guard let project = self.manager.createProject(name: "探针项目") else {
                NSLog("%@", "[MentionProbe] 建项目失败（库没就绪）")
                return
            }
            // 归属：当前会话（落地页也要先有一个会话，`activeConversationId` 恒有值）
            // ⚠️ 用 `activeConversationId` 而不是 `conversation.id`：后者是 `private`，
            //    那个属性只给 manager 自己用（同 `rows` / `activeProjectId` 那几个只读出口的分工）
            let conversationId = self.manager.activeConversationId
            self.manager.setConversationProject(conversationId: conversationId, projectId: project.id)
            // 造一份示例资料：走 addProjectFile（与「＋ → 项目资料」同一条落盘路径）
            let sample = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("季度报告-2026Q3-最终版.md")
            try? "# 季度报告\n探针用的示例资料。\n".write(to: sample, atomically: true, encoding: .utf8)
            guard let file = self.manager.addProjectFile(projectId: project.id, sourceURL: sample) else {
                NSLog("%@", "[MentionProbe] 导入资料失败")
                return
            }
            self.refreshComposerBanner()   // 让「＋」面板第 4 格与 chip 条的归属校验先跑一遍
            self.appendMention(file)
            NSLog("%@", "[MentionProbe] 已 @ \(file.displayName) pending=\(self.pendingMentions.count)"
                + " toolbar=\(self.inputToolbar.pendingMentions.count)")
            // `=send` 档：再往前走一步，**真的发一条** —— 证据是控制台的 `[Mention] inject …` 那行
            // （chip 只说明"挂上了"，进没进请求是另一件事）。
            if ProcessInfo.processInfo.environment["STARRY_MENTION_PROBE"] == "send" {
                self.sendInput(text: "这份资料讲了什么？")
            }
        }
        #endif
    }

    // MARK: - 🧪 验收钩子：默认项目「任务」全链路（2026-10-25 重写）

    /// `STARRY_PANEL_PROBE=1` 时启动后自动演一遍「默认项目容器」全链路。
    ///
    /// ## 为什么要有它（2026-10-24 建，2026-10-25 重写）
    /// 初版盯的是「第 4 格显隐的时序 bug」（先刷 banner 后切会话）。
    /// 2026-10-25「未归类」消灭后，显隐问题不存在了（所有会话必有项目 ⇒ 恒 4 格），
    /// 判据换成**默认项目容器本身的行为**——这些同样编译零症状：
    /// 新会话不归默认组 / 切回来读库丢了归属 / 删项目不回落 / 默认组被删掉。
    /// 读数 = `AIAttachmentPanelView.debugKinds`（DEBUG 只读出口）+ `manager.activeProjectId`。
    func runPanelEntryProbeIfRequested() {
        #if DEBUG
        guard !didAutoRunPanelEntryProbe else { return }
        guard ProcessInfo.processInfo.environment["STARRY_PANEL_PROBE"] != nil else { return }
        didAutoRunPanelEntryProbe = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.runPanelEntryProbe()
        }
        #endif
    }

    /// 本体。全走**用户同款路径**：`startNewChat`（点新建）/ `openConversation`
    /// （抽屉点会话）/ `setConversationProject` + `refreshComposerBanner`
    /// （抽屉里移动归属）/ `manager.deleteProject`（分组头「…」）。
    /// ⛔ 别在这里直接摆 `kinds` 或 `projectId` —— 那就绕过了被测的那条链。
    private func runPanelEntryProbe() {
        let store = AIChatStore.shared
        let defaultId = AIChatStore.defaultProjectId
        func panelHasProjectEntry() -> Bool {
            inputToolbar.attachmentPanel.debugKinds.contains(.project)
        }
        func panelCount() -> Int { inputToolbar.attachmentPanel.debugKinds.count }
        func projectExists(_ id: UUID) -> Bool {
            manager.fetchProjects().contains { $0.id == id }
        }
        // 日志每次先清空（同 PDF 探针口径）—— 不重置的话历史 FAIL 会和新结果混在
        // 同一行里，「看一眼回显」分不清哪条是本次的
        let logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("panel_probe.log")
        try? FileManager.default.removeItem(at: logURL)

        // 夹具：一个用户项目 + 两个**真历史会话**（⛔ 别在内存里凭空造 ——
        // `switchToConversation` 读的是库，没落库的对象切过去 `loadConversation` 直接返回 nil）
        guard let project = manager.createProject(name: "探针面板项目") else {
            NSLog("%@", "[PanelProbe] 建项目失败（库没就绪）⇒ 判据全废，FAIL")
            return
        }
        let convInProject = AIConversation(title: "探针-项目组会话", projectId: project.id)
        let convInDefault = AIConversation(title: "探针-默认组会话", projectId: defaultId)
        store.createConversation(convInProject)
        store.createConversation(convInDefault)
        defer {
            // 清理：探针数据不进对话列表 / 项目列表（后续截图与验证都要干净）
            store.deleteConversation(id: convInProject.id)
            store.deleteConversation(id: convInDefault.id)
            store.deleteProject(id: project.id)   // 用户项目可删；默认组删不掉（⑥ 正是验这个）
            startNewChat()   // 收尾复位：落地页 + 归默认组的新会话
        }

        var log = "[PanelProbe] 起点格数=\(panelCount())"

        // ① 新建会话**默认归「任务」**（内存态；落库时 createConversation 就带上）
        startNewChat()
        let ok1 = manager.activeProjectId == defaultId
        log += " ｜新建归默认组=\(ok1 ? "✓" : "✗")"

        // ② 切到**用户项目**会话 ⇒ 4 格 + 归属读对（读库那条路）
        openConversation(convInProject.id)
        let ok2 = panelHasProjectEntry() && manager.activeProjectId == project.id
        log += " ｜切用户项目→\(panelCount())格(\(ok2 ? "✓" : "✗"))"

        // ③ 切到**默认组**会话（落库的真行）⇒ 4 格 + 归属读回默认组
        //    （回归 v10 迁移 / insert 带 project_id：这条红了 = 归属又丢了）
        openConversation(convInDefault.id)
        let ok3 = panelHasProjectEntry() && manager.activeProjectId == defaultId
        log += " ｜切默认组→\(panelCount())格(\(ok3 ? "✓" : "✗"))"

        // ④ 把当前会话**移入**用户项目 ⇒ 恒 4 格（旧时序 bug 不复发）
        manager.setConversationProject(conversationId: manager.activeConversationId,
                                       projectId: project.id)
        refreshComposerBanner()
        let ok4 = panelHasProjectEntry() && manager.activeProjectId == project.id
        log += " ｜移入项目→\(panelCount())格(\(ok4 ? "✓" : "✗"))"

        // ⑤ 删掉用户项目 ⇒ 当前会话回默认组 + 项目列表只剩默认组
        manager.deleteProject(id: project.id)
        let ok5 = manager.activeProjectId == defaultId
            && !projectExists(project.id) && projectExists(defaultId)
        log += " ｜删项目回落=\(ok5 ? "✓" : "✗")"

        // ⑥ 默认项目**删不掉**：显式删一次，它必须还在（store 层 guard）
        manager.deleteProject(id: defaultId)
        let ok6 = projectExists(defaultId) && panelHasProjectEntry()
        log += " ｜默认组禁删=\(ok6 ? "✓" : "✗")"

        let pass = ok1 && ok2 && ok3 && ok4 && ok5 && ok6
        let line = log + " ｜RESULT: \(pass ? "PASS" : "FAIL")"
        NSLog("%@", line)
        // 落盘一份（与 pdf_probe.log / i18n_trace.log 同目录口径）——
        // `sim_ios.sh` 跑完自动回显，不用人去翻控制台
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("panel_probe.log")
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - 🧪 验收钩子：切换模型的系统消息（append / replace / undo 三态）

    /// `STARRY_MODEL_SWITCH_PROBE=1` 时启动后自动演一遍三条显示规则。
    ///
    /// ## 为什么要有它
    /// 那两条规则（切回去 ⇒ 撤销；又切第三个 ⇒ 改写成 A→C）**全靠运行时的行数组**
    /// 判定，源码契约只证得了「代码在不在」，证不了「末行是不是它、判据有没有认错对象」。
    /// 而模拟器投不出合成触摸 ⇒ 走这颗胶囊点不了，只能给个钩子。
    ///
    /// ## 三条约束（逐条照抄 `openSessionPickerIfRequested`）
    /// 1. **只在 `#if DEBUG` 下编译进去** —— Release 包里这段根本不存在；
    /// 2. **只触发一次**（闩在 `didAutoRunModelSwitchProbe`）；
    /// 3. 走**和用户完全相同的那条路**（`switchModel(to:)`，⛔ 别在这里直接
    ///    `manager.noteModelSwitch` 造第二条 —— 那样验的不是点胶囊那一套）。
    ///
    /// ⚠️ 刻意**不发消息**：三条规则都在内存态就能演完（会话还没建时 notice 只落内存），
    ///    发真消息会把探针会话留在对话列表里污染后续截图。
    func runModelSwitchProbeIfRequested() {
        #if DEBUG
        guard !didAutoRunModelSwitchProbe else { return }
        guard ProcessInfo.processInfo.environment["STARRY_MODEL_SWITCH_PROBE"] != nil else { return }
        didAutoRunModelSwitchProbe = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.runModelSwitchProbe()
        }
        #endif
    }

    /// 依次演 append → replace → undo。证据是控制台三行 `[ModelSwitchProbe]`
    /// （每行带「末行是不是系统消息 + 它的文案 + 总行数」）。
    private func runModelSwitchProbe() {
        // 用 `allModels` 而不是 `readyChoices`：探针只借三个 id 走指针，
        // 与「配齐没配齐」无关（没配齐也照样换得动指针）
        let ids = AIConfig.allModels.map(\.id)
        guard ids.count >= 3 else {
            NSLog("%@", "[ModelSwitchProbe] 跳过：清单不足 3 条（\(ids.count)）")
            return
        }
        let a = ids[0], b = ids[1], c = ids[2]

        // ① append：A → B。此刻末行不是系统消息 ⇒ 新插一条
        switchModel(to: a)
        switchModel(to: b)
        NSLog("%@", "[ModelSwitchProbe] ① append A→B \(modelSwitchProbeDigest())")

        // ② replace：B → C。末行正是「A→B」那条，且它的目的地就是 B ⇒ 改写成「A→C」
        switchModel(to: c)
        NSLog("%@", "[ModelSwitchProbe] ② replace B→C ⇒ A→C \(modelSwitchProbeDigest())")

        // ③ undo：C → A。末行是「A→C」那条，切回去的正是最初的 A ⇒ 整条撤销
        switchModel(to: a)
        NSLog("%@", "[ModelSwitchProbe] ③ undo C→A \(modelSwitchProbeDigest())")
    }

    /// 探针专用：把指定 id 设成「当前使用」**并记一条系统消息**。
    ///
    /// 🔴 与 `presentSessionModelPicker` 的 onPick 里那三行**逐字同序**
    ///    （先取 previous → 写指针 → noteModelSwitch）—— 顺序反了就取不到
    ///    「切换前」那条，而名字快照会整个错。
    func switchModel(to id: String) {
        let previous = AIConfig.current
        AIConfig.currentID = id
        if let previous, let now = AIConfig.current {
            manager.noteModelSwitch(from: previous, to: now)
        }
    }

    /// 末行快照（探针的判据）：是不是系统消息、文案是什么、一共几行。
    private func modelSwitchProbeDigest() -> String {
        let rows = manager.rows
        guard let last = rows.last else { return "rows=0（空）" }
        if case .modelSwitch = last.block.kind {
            return "末行=系统消息「\(last.block.modelSwitchText)」rows=\(rows.count)"
        }
        return "末行不是系统消息（kind=\(last.block.kind)）rows=\(rows.count)"
    }

    /// 根据输入栏当前位置，同步列表内边距 / toast 位置
    func updateBottomOccupancy(_ toolbarMinY: CGFloat) {
        guard view.bounds.height > 0 else { return }
        let occupancy = max(0, view.bounds.height - toolbarMinY)
        guard abs(tableView.contentInset.bottom - occupancy) > 0.5 else { return }

        tableView.contentInset.bottom = occupancy
        tableView.verticalScrollIndicatorInsets.bottom = occupancy
        toastBottomConstraint?.update(offset: -(occupancy + 16))
        if mode == .chat, isPinnedToBottom { scrollToBottom(animated: false) }
    }

    // MARK: - 发送

    /// 发送前的**网络可达性**前置检查。明确离线 → 提示并返回 false。
    ///
    /// 为什么必须前置：SSE 请求的 `timeoutInterval` 是**空闲超时**（120s），断网时不会立刻
    /// 失败 —— 用户按完发送，然后对着「正在回复」等两分钟才等来一句网络错误，那和卡死没区别。
    /// 这里提前查一次，代价只是一次内存读取（监听已在 App 启动时开好）。
    ///
    /// ⚠️ 判据是 `current == .notReachable`，**不是** `!isReachable`：后者在监听尚未确定
    /// （`.unknown`）时同样返回 false，会把「还不知道」当成「没网」—— 冷启动第一句就被挡下，
    /// 比不做检查更糟。保守原则：**不确定就放行**，让请求自己去试。
    ///
    /// ⚠️ 本机 mock 平台（`requiresNetwork == false`）不走网络，断网也能连 → 放行。
    ///
    /// ⚠️ 故意**不写 `private`**：`private` 在本工程是**文件级**作用域，而 `regenerateResponse`
    /// 在 `+RowAction.swift` 里也要用它 —— 写成 private 会直接编译不过（这条踩过）。
    func ensureNetworkAvailable() -> Bool {
        guard StarryNetworkMonitor.shared.current == .notReachable else { return true }
        // ⚠️ 用 `currentRequiresNetwork()`，不要自己 `make()` 取 provider：
        // `AIProvider` 是 AICore 的**包内协议**，App 侧看不见（也不该看见）。
        if !AIProviderFactory.currentRequiresNetwork() { return true }
        showToast(L("当前没有网络连接"))
        return false
    }

    /// 统一发送入口：文本可以空（只发附件），附件也可以空（只发文字）。
    /// 处于编辑态时走的是「编辑重发」（截断这一条之后的所有消息）。
    func sendInput(text: String) {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // ⚠️ 判据要带上 @ 资料：只 @ 了一份资料、一个字没打也是合法的一条（正文由 manager 回填成 `@名字`）
        guard !content.isEmpty || !pendingAttachments.isEmpty || !pendingMentions.isEmpty else { return }
        let attachments = pendingAttachments
        let mentions = pendingMentions
        // **启动成功才清待发区**：配置类错误是同步回调的，那种情况下用户刚选的图
        // 应当留在预览条里，改完设置能直接重发 —— 而不是让人重新去相册里挑一遍
        if send(content, attachments: attachments, mentions: mentions) {
            clearPendingAttachments()
            clearPendingMentions()
            setPendingQuote(nil)
            // 发送成功 → 编辑态结束。这里**不清输入框**（`send` 内部已经清过一次了），
            // 也**不收键盘**：发完接着聊是聊天页的常态，把键盘留着。
            // ⚠️ 两个默认值正好相反 —— `exitEditing` 默认收摊（退出 = 结束），
            // 发送这条是唯一的例外，必须显式传 `dismissKeyboard: false`。
            exitEditing(clearInput: false, dismissKeyboard: false)
        }
    }

    /// - Returns: 是否成功发起。失败时**不清输入框**（配置报错多为同步返回，
    ///   用户改完设置还能直接重发，不用重新打字）。
    @discardableResult
    func send(_ text: String, attachments: [AIAttachment], mentions: [AIMention] = []) -> Bool {
        guard !isStreaming else {
            showToast(L("正在回复中…"))
            return false
        }
        // 明确离线就先拦下：断网时请求不会立刻失败，得等 120s 空闲超时才有回音。
        // ⚠️ 位置在建行 / 落库 / 置 `isStreaming` **之前** —— 返回 false 时调用方会保留
        // 输入区内容（见 `sendInput`），用户连上网就能直接重发，不用重打一遍
        guard ensureNetworkAvailable() else { return false }
        // 发新消息 → 停掉上一条还在朗读的回复（否则朗读声会盖着新回复正在长的文字）
        stopSpeech()
        // 落地页发送 → 进入对话态
        if mode == .landing { enterChat() }

        isPinnedToBottom = true
        // 先置位再发：配置错误会在 send 内**同步**回调 didError（那里会复位 isStreaming），
        // 顺序反了的话会把刚复位的状态又置回 true，界面卡在「正在回复」
        isStreaming = true
        let started: Bool
        if let messageId = editingMessageId {
            // 编辑重发：正文换成用户改过的这份，**这一条之后的消息全部截断**再重问。
            // 行号这里现查：编辑期间列表可能变过（见 `editingMessageId` 的注释）
            if let index = manager.rows.firstIndex(where: { $0.block.id == messageId }) {
                started = manager.editAndResend(fromRowAt: index, newText: text, attachments: attachments)
            } else {
                // 那条消息已经不在了（被重新生成删掉 / 会话被换掉）——
                // 不能默默发成一条新消息（用户以为在改，实际是追加）
                showToast(L("这条消息已不在当前会话里"))
                started = false
            }
        } else {
            // 编辑重发时**不改**这条消息的 @ 资料（`editAndResend` 内部会把它原样带回，
            // 与引用同一套语义：用户改的是正文，参考资料没变）。所以这里只传 mentions 给「新消息」那条路
            started = manager.send(text, attachments: attachments, quote: pendingQuote, mentions: mentions)
        }
        if started {
            inputToolbar.clearText()
        } else {
            // 静默失败的兜底：`editAndResend` 有几条**不回调** `didError` 就直接返回 false 的路径
            // （找不到目标行 / 正文与附件都空）。配置类错误已经复位过一次，这里再置一次是幂等的。
            // 少了这一步，界面会永远卡在「正在回复」上（同 `regenerateResponse` 的兜底）
            isStreaming = false
        }
        return started
    }

    // MARK: - 输入栏上方状态条（待发引用 / 正在编辑）

    /// 设置 / 清除待发引用（nil = 清除）
    func setPendingQuote(_ quote: AIQuote?) {
        pendingQuote = quote
        refreshComposerBanner()
    }

    /// 按当前状态刷新输入栏上方那条状态条。
    ///
    /// **编辑优先于引用**：两者占的是同一个位置（见 `AIComposerBannerView`），
    /// 而「正在改写某条消息」是对本次发送更强的定性 —— 引用只是附加的上下文。
    /// 另外编辑态进入时会顺手把待发引用清掉（见 `enterEditing`），所以这条优先级
    /// 更多是为了防御「先编辑、后又被塞进引用」这种状态组合。
    func refreshComposerBanner() {
        // 项目归属跟着会话走 ⇒ 在这里顺带把「+」面板第 4 格刷一遍。
        // ⚠️ 必须放在**最上面**（下面几条都有 early return）：它是独立的一件事，
        //    不该因为「当前没有引用/编辑态」而漏刷。
        refreshProjectEntry()
        // 联网搜索开关同理：独立于状态条，也得在 early return 之前刷
        refreshWebSearchEntry()
        // （项目资料检索那颗放大镜 2026-10-23 已删：它的显隐跟着会话归属走，
        //  原先在这里顺带刷；入口下线后无须再刷，底层链路见 VERIFY-PROBES.md §32.4）
        // `@` 资料条同理（顺便做一次归属校验，见 `refreshMentionBar`）
        refreshMentionBar()
        if let messageId = editingMessageId,
           let index = manager.rows.firstIndex(where: { $0.block.id == messageId }) {
            let text = manager.rows[index].block.text
            inputToolbar.setBanner(.editing(String(text.prefix(30))))
            return
        }
        if let quote = pendingQuote {
            inputToolbar.setBanner(.quote(quote))
            return
        }
        inputToolbar.setBanner(nil)
    }

    /// 进入「编辑这条消息」态：把正文回填输入栏，这次发送 = 截断其后所有消息并重发。
    ///
    /// **为什么回填到输入栏而不是弹一个编辑框**：这个输入框用户已经熟悉（附件、语音、
    /// 键盘行为全都一致），而编辑完紧接着就要发出去 —— 弹层里改完再回输入栏发送，
    /// 中间多一次「内容搬家」，也多一套要维护的编辑 UI。
    func enterEditing(atRow index: Int) {
        guard manager.rows.indices.contains(index) else { return }
        let row = manager.rows[index]
        guard row.role == .user, case .text = row.block.kind else {
            showToast(L("这条没有可编辑的文字"))
            return
        }
        guard !isStreaming else {
            showToast(L("正在回复中，先停下再试"))
            return
        }
        // 待发引用清掉：这次发送用的是**原消息的引用**（manager 里跟着走），
        // 留着一条显示中却不会被使用的引用条，用户会以为引用没生效
        pendingQuote = nil
        editingMessageId = row.block.id
        inputToolbar.updateWithConfig { $0.text = row.block.text }
        refreshComposerBanner()
        // 编辑完就要发 → 直接把键盘弹起来
        _ = inputToolbar.becomeFirstResponder()
    }

    /// 退出编辑态。
    /// - Parameters:
    ///   - clearInput: 是否顺手清空输入区。用户主动取消 = true；
    ///     发送成功那条路由 `sendInput` 传 false（`send` 内部已经清过输入框了）
    ///   - dismissKeyboard: 是否把输入态一起收掉（键盘 / 「+」面板）。
    ///     默认 **true** —— 「退出编辑」就是这件事结束了，收摊才符合预期；
    ///     只有 `sendInput` 传 false（发完接着聊，键盘留着）。
    func exitEditing(clearInput: Bool, dismissKeyboard: Bool = true) {
        guard editingMessageId != nil else { return }
        editingMessageId = nil
        if clearInput {
            // 先把配置里的文本清掉，再清 textView —— `updateWithConfig` 的刷新逻辑
            // 只在 `configure.text` 非空时写 textView，只调 `clearText()` 的话，
            // 下次任何一次 `updateWithConfig` 都会把这段编辑文本又灌回输入框
            inputToolbar.updateWithConfig { $0.text = "" }
            inputToolbar.clearText()
        }
        refreshComposerBanner()
        if dismissKeyboard {
            // ⚠️ **两条都要走，不能只 resign**：
            // - 键盘开着时 `textView` 是第一响应者 → `resignFirstResponder()` 会触发
            //   `textViewDidEndEditing`（那条负责复位输入栏高度 + 通知 `keyboardState(false)`）；
            // - 「+」面板开着时 `textView` **本来就不是**第一响应者（面板顶替了键盘）→
            //   只 resign 是 **no-op**，用户点了 ✕ 会看到「编辑取消了、面板还留着」。
            //   `dismissAttachmentPanelForBlankTap()` 自带 `guard isAttachmentPanelVisible`，
            //   面板没开时是 no-op，所以无条件调它很安全（点列表空白那条路也调过，幂等）。
            inputToolbar.dismissAttachmentPanelForBlankTap()
            // 返回 Bool（是否真的放弃了第一响应者），这里不需要它的值
            _ = inputToolbar.resignFirstResponder()
        }
    }
}

// MARK: - InputToolbarDelegate

extension AIModuleViewController: InputToolbarDelegate {

    /// 发送文本（输入栏的发送 / 键盘 return 都会走这里）。
    /// 走 `sendInput` 而不是直接 `send`：这样「打了字 + 已经选了附件」时两者会一起发出去。
    func sendEvent(_ text: String) {
        sendInput(text: text)
    }

    /// 按钮行里那颗「＋」切成了**发送**（因为有待发附件）并被点。
    ///
    /// 🔴 2026-10-08：这是「只发图不打字」的**唯一**出口（原先是附件条右侧那颗蓝色按钮，已删）。
    ///    文本从 `inputToolbar.currentText` 取 —— 图文一起发时两者都会带出去；
    ///    ⛔ 别写成 `sendInput(text: "")`，那会把用户已经打的字丢掉。
    ///    `sendInput` 自己会拦「文本与附件都空」（那种情况按钮也不该是发送态）。
    func sendCurrentInputEvent() {
        sendInput(text: inputToolbar.currentText)
    }

    /// 「+」附件面板的入口（相机 / 相册 / 文件）。
    ///
    /// ⚠️ 相册 / 文件**不要**在这里 `view.endEditing(true)`，也不用碰面板：
    /// picker 是「暂离一下马上回来」，面板与输入栏原样留着即可 ——
    /// 它们跟系统键盘没关系（面板是输入栏的子视图，不是 `textView.inputView`），
    /// 系统也就无从把它们收走。
    ///
    /// 相机与它们的区别只在「模态是不是盖满全屏」——收键盘这一步交给
    /// `presentCamera()` 内部统一做（见 `+Attachment.swift`）。
    func attachmentEvent(_ kind: InputAttachmentKind) {
        switch kind {
        case .camera:  presentCamera()
        case .album:   presentPhotoPicker()
        case .file:    presentFilePicker()
        // 项目资料（2026-10-21）：列出当前会话所属项目的资料，选一份带进待发区。
        // ⚠️ 这一格只会在**会话属于某项目**时出现（见 `refreshProjectEntry`）。
        case .project: presentProjectFilePicker()
        }
    }

    /// 「+」面板下半部分那块**最近照片网格**被点了一张。
    ///
    /// 网格那条路与「相册」按钮（`PHPicker`）殊途同归：都是「拿到 `UIImage` →
    /// `AIAttachmentStorage.importImage` 压到长边 1600 落盘 → 进待发区」，
    /// 所以对下游（预览条、发送、历史行高）完全一样，区别只在取图方式。
    func attachmentPhotoPicked(_ asset: PHAsset) {
        importRecentPhoto(asset)
    }

    /// 输入栏左侧那个相机按钮。
    ///
    /// 与「+」面板里的「相机」入口**走同一个实现** —— 对用户是同一件事，
    /// 两份实现就是两份权限处理、两份降级提示，迟早会跑偏。
    func cameraEvent() {
        presentCamera()
    }

    // MARK: 联网搜索开关（输入栏那颗地球，2026-10-21）

    /// 被点 —— 对应 `InputToolbarDelegate.webSearchToggleEvent()`。
    ///
    /// 这里是**唯一**翻转偏好的地方（工具栏只上报，见协议注释）。翻转后立刻回写按钮态：
    /// 不等 `AIGenerationSettings.didChangeNotification` —— 那条广播要等主线程让出去
    /// 才跑，按钮会慢一拍才变色（看着像没点上）。
    ///
    /// ⚠️ 检索本身不在这里发起：真正读开关的地方是 `AIChatManager.beginStreaming`（唯一判据）。
    /// 这里只存偏好，⛔ 别顺手在这儿也搜一次 —— 那会变成「点开关就搜」。
    func webSearchToggleEvent() {
        StarryHaptic.impact(.light)
        AIGenerationSettings.webSearchEnabled = !AIGenerationSettings.webSearchEnabled
        refreshWebSearchEntry()
    }

    /// 把偏好同步到那颗按钮（进页面 / 重启 / 别处改过都靠它对齐）。
    func refreshWebSearchEntry() {
        inputToolbar.setWebSearchEnabled(AIGenerationSettings.webSearchEnabled)
    }

    // MARK: - @ 项目资料（输入框里打 `@`，2026-10-21）

    /// 用户在输入框里打了一个 `@` —— 对应 `InputToolbarDelegate.mentionTriggerEvent()`。
    ///
    /// 🔴 **不在这里判「有没有项目」**：判据只有 `presentProjectMentionPicker()` 内部那一处
    ///    （`manager.activeProjectId`）。这里再判一次就成了两份真值 ——
    ///    改一处忘另一处，症状是「＋面板里有『项目资料』，@ 却说没有项目」。
    func mentionTriggerEvent() {
        // ⚠️ 输入法还在这一个按键上组字时不弹（工具栏那边已判过一次 `markedTextRange`，
        //    这里是第二道：那个判断发生在 `shouldChangeTextIn`，跑到主队列时状态可能又变了）
        presentProjectMentionPicker()
    }

    /// 把一条项目资料加进待发区，并把 `@文件名` 插进输入框。
    ///
    /// 两件事必须**成对**：只加 chip 不插文本 ⇒ 用户看不出自己 @ 了什么；
    /// 只插文本不加 chip ⇒ 这一轮其实不带那份资料（真值在 chip，见 `AIMention` 文件头）。
    func appendMention(_ file: AIChatProjectFile) {
        // 同一份资料不重复加（面板可以反复打开）：重复 @ 只会把同一段正文喂两遍
        guard !pendingMentions.contains(where: { $0.projectFileId == file.id }) else {
            showToast(L("这份资料已经 @ 过了"))
            return
        }
        guard pendingMentions.count < AIMention.maxPerMessage else {
            showToast(L("一次最多 @ 3 份资料"))
            return
        }
        let mention = AIMention(file)
        pendingMentions.append(mention)
        refreshMentionBar()
        inputToolbar.insertMentionToken(mention)
        StarryHaptic.impact(.light)
        // 选择页此刻正在关（它自己 dismiss），关完把焦点还给输入框 ——
        // 不然用户回到输入栏还得再点一下才能接着打字。
        // ⚠️ 延后一拍是必须的：dismiss 动画期间 `becomeFirstResponder` 会被系统吞掉，
        //    而且那一拍选择页还在，抢焦点会让它塌得更快（看着像"点了一下闪了下"）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.presentedViewController == nil else { return }
            _ = self.inputToolbar.becomeFirstResponder()
        }
    }

    /// 清空待发资料（发送成功后 / 换会话时）
    func clearPendingMentions() {
        guard !pendingMentions.isEmpty else { return }
        pendingMentions.removeAll()
        refreshMentionBar()
    }

    /// 把待发资料同步到输入栏那条 chip 条（唯一写入口：⛔ 别在别处直接 `inputToolbar.setMentions`）。
    ///
    /// 🔴 顺带做**归属校验**：会话切到别的项目后，上一个项目里的资料就不再是「这个项目的资料」了
    ///    —— 留着它们会让模型读到别的项目的内容（那比少带资料糟得多）。
    ///    ⚠️ 校验放在这里而不是「切会话时清一次」：`refreshComposerBanner` 是切会话 / 新建 /
    ///    改归属的**共同入口**，只挂一处就不会漏（三处各清一次必然漏一处）。
    func refreshMentionBar() {
        // 2026-10-25 起 activeProjectId 恒非 nil（默认项目「任务」兜底）。
        // `else` 分支留着防 ensure 极端失败：那时候不存在「项目资料」这回事，全清。
        if let projectId = manager.activeProjectId {
            let available = Set(manager.fetchProjectFiles(projectId: projectId).map(\.id))
            pendingMentions.removeAll { !available.contains($0.projectFileId) }
        } else if !pendingMentions.isEmpty {
            // 默认项目都没就绪的极端场景：不存在「项目资料」这回事
            pendingMentions.removeAll()
        }
        inputToolbar.setMentions(pendingMentions)
    }

    /// 联网搜索失败：飘一条提示（**不影响这一轮**，业务层已降级成普通对话）。
    ///
    /// ⚠️ 必须按实例过滤：同一进程里通话页 / 别处可能各持一个 manager，
    /// 不过滤就会拿别人的失败刷自己的界面（而且**不报错**，像「偶尔莫名弹提示」）。
    @objc func webSearchDidFail(_ note: Notification) {
        guard note.object as? AIChatManager === manager else { return }
        let message = note.userInfo?[AIChatManager.webSearchFailureKey] as? String
        showToast(message ?? L("联网搜索没搜到，直接回答"))
    }

    /// 键盘状态
    func keyboardState(state: Bool, text: String) {        if state, isPinnedToBottom { scrollToBottom(animated: true) }
    }

    /// 文本超出上限
    func inputTextMaxCount(count: Int) {
        showToast(String(format: L("最多输入 %d 字"), count))
    }

    // MARK: 停止生成（输入栏右下角那颗按钮）

    /// 「停止生成」被点 —— 对应 `InputToolbarDelegate.stopStreamingEvent()`。
    ///
    /// `manager.stop()` 会**把已经收到的正文补齐并落库**（用户看到的半截回复不会丢），
    /// 然后：① 把没上屏的尾巴补齐 → ② 整体渲染 Markdown → ③ 通知 `chatManagerDidFinalizeRow`。
    ///
    /// ⚠️ 复位 `isStreaming` **必须由这里显式做**：`stop()` 走的是「主动中断」路径，
    /// 它只回调 `didFinalizeRow`，**不会**回调 `chatManagerDidFinish`（那条路是给「服务端说完了」的），
    /// 所以不能指望结束回调替我们复位 —— 漏了这一步，按钮会永远停在「停止」上。
    /// 而复位后输入栏的图标由 `isStreaming` 的 `didSet` 自动同步（见主文件），不必手写第二句。
    func stopStreamingEvent() {
        StarryHaptic.impact(.light)
        manager.stop()
        isStreaming = false
    }

    // MARK: 语音按钮（会话逻辑在 +Voice.swift）

    /// 语音按钮按下：请求权限 → 起录音 + 识别 + 波形
    func voiceRecordDidBegin() {
        beginVoiceSession()
    }

    /// 语音按钮抬起（cancel 表示手指移出按钮范围 / 系统中断）
    func voiceRecordDidEnd(cancel: Bool) {
        // 自动超时收尾后，这次抬起是多余的
        guard isVoiceSessionActive else { return }
        endVoiceSession(cancel: cancel)
    }

    /// 手指移出 / 移回按钮范围 → 浮层切换「松开取消」提示
    func voiceRecordCancelStateChanged(isCancelling: Bool) {
        guard isVoiceSessionActive else { return }
        voicePanel.setCancelling(isCancelling)
    }
}
