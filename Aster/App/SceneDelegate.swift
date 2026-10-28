//
//  SceneDelegate.swift
//  Aster
//
//  Created by Suzhibin on 2026/9/20.
//
//  独立 AI 应用的入口。
//  与 StarryApp 的区别：**没有 TabBar 兜底分支**，首屏恒为 AI 会话页；
//  不依赖 AModule / CModule / DetailsModule / UserModule，也不恢复下载任务。
//
//  依赖组织：**源码内联**（不是 SPM 包引用）。StarryKit + AIModule 的源码直接躺在
//  本 target 里，全部同一个 module，所以 AIModule 侧原来的 `import BaseModule`
//  已全部去掉、改为同 module 直接可见：
//    StarryKit/     —— 从 StarrySPM 的 BaseModule/Sources/StarryKit 整目录搬来
//                      （基础能力：日志 / 网络 / 服务总线）
//    Sources/       —— 从 StarrySPM 的 AIModule/Sources 整目录搬来
//                      （AI 全部实现：会话页 / 菜单 / SSEClient 消费 / 落库）
//    Sources/Setup/ —— 只从 BaseModule 业务层抽出**真正用到**的那几个符号
//                      （AIModuleEntryProtocol / AI 两个 Key 声明）

import UIKit
import SideMenu
import UserNotifications
import StarryKitCore
// 🔴 `AILanguageStore` / `AILanguage` / `L()` 在 `AICore`（见 `AILocalization.swift`）。
import AICore
// 公式探针要数正文里的行内公式附件（类型定义在接缝层，见 `AIPlatformMath.swift`）。
import AIPlatform

class SceneDelegate: UIResponder, UIWindowSceneDelegate, UNUserNotificationCenterDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        self.window = UIWindow(windowScene: windowScene)
        self.window?.frame = UIScreen.main.bounds

        // 🔴 外观偏好（跟随系统 / 浅色 / 深色）必须在 `makeKeyAndVisible()` **之前**套用：
        //    晚了会先按系统外观画一帧、再跳成用户选的那档 ⇒ 视觉上「启动闪一下」。
        //    iOS 的外观挂在 window 上（不像 Mac 有 App 级开关），所以落点就是这里。
        AIAppearanceStore.restoreAtLaunch()

        // 语言偏好（跟随系统 / 简体中文 / English）。⚠️ 它**不需要**「在窗口之前应用」——
        // 语言没有「应用」这一步，`L()` 是查表即时的；这里只是把认不出的残留值清掉。
        AILanguageStore.restoreAtLaunch()

        // 🔴 语言切换要**重建整个界面**（`L()` 是普通函数、不登记观察依赖，
        //    见 `AILocalization.swift` 文件头）—— 而 window 只有这里持有，所以监听落在这儿。
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(languageDidChange),
                                               name: AILanguageStore.didChange,
                                               object: nil)

        //    别顺手加回来 —— 见 `SceneDelegate+Init.swift` 文件头。
        setupNetwork()

        // ⚠️ 顺序有依赖，别调换：registerAIModule() 在这一步把 AIModuleImpl 注册进
        // StarryServiceBus，紧接着的 resolve 才取得到首屏。写在 resolve 之后就白屏。
        // （⛔ 别因为它不叫 setupXxx 就以为它无关紧要 —— 它就是原来那个 setupNavigator()。）
        registerAIModule()

        // 🔴 本地通知的接收端（2026-10-18，「回复生成完」通知，见 `AIReplyNotifier`）。
        //    必须早于任何通知到达 —— 冷启动第一轮生成可能在进入前台之前就结束了。
        //    ⚠️ iOS 上「前台是否展示」由**不实现** `willPresent` 决定（默认不展示），
        //       且我们只在 App 不在前台时才发（notifier 内判断）⇒ 双保险，无骚扰。
        UNUserNotificationCenter.current().delegate = self

        guard let entry = StarryServiceBus.shared.resolve(AIModuleEntryProtocol.self) else {
            assertionFailure("AIModuleEntryProtocol 未注册 —— registerAIModule() 必须在 resolve 之前调用")
            return
        }
        let root = UINavigationController(rootViewController: entry.AIModuleRegisterViewController())
        self.window?.rootViewController = root

        // 左侧抽屉菜单（会话列表 / 新对话 / 文档），挂在全局 SideMenuManager 上，
        // 供会话页通过手势或导航栏按钮唤出
        // ⚠️ 固定入口第 0 组 2026-10-10 由「开启AI + AI创作」改成「开启AI + 文档」——
        //    这一行注释跟着改（原来那句「AI 创作」已作废）。
        //    📌 2026-10-25：第一项文案「开启AI」→「新对话」（用户要求），此处是**历史记录**不改。
        setupAIMenu()

        self.window?.makeKeyAndVisible()
    }

    // MARK: - UIScene 生命周期
    // 本 App 无额外处理，留空实现便于日后按需补

    func sceneDidDisconnect(_ scene: UIScene) {}

    func sceneDidBecomeActive(_ scene: UIScene) {
        // 🔴 通知权限预热（2026-10-19，用户要求「首次启动就请求」）。
        //    落点选这里而不是 `willConnectTo`：授权弹窗只在 App **active** 时弹得出来，
        //    而 `sceneDidBecomeActive` 正是「启动后首次 active」与「每次回前台」的汇点。
        //    ⚠️ 每次回前台都会走到这 —— `warmup()` 内有 `didWarmup` 闩 + 总闸 guard，
        //       重复调用零副作用（只第一次真的请求）。
        //    ⚠️ 顺序无关紧要，但刻意放在 clearAll 之前：清理挂着的旧通知与请求权限
        //       是两件不相干的事，谁先谁后都不影响语义。
        AIReplyNotifier.warmup()

        // 回前台 = 用户能看到所有内容了 ⇒ 通知中心里挂着的「回复已生成」再无意义。
        // ⚠️ 点通知跳转也走这里（didReceive 先拿到会话 id，清通知不影响跳转）。
        AIReplyNotifier.clearAll()

        // 🔴 回前台对账（2026-10-19，通知策略补丁 B）：
        // iOS 挂起后「流结束/报错」事件不会来 ⇒ 上一轮可能在用户不知道的情况下
        // 跑完了 / 断了 / 被杀了。查库补发一条通知（锁屏与通知中心留痕）。
        // ⚠️ 必须放在 clearAll **之后**：反过来的话，这里补发的通知会被上面清掉。
        // ⚠️ isStreamingActive 传本进程的收流真值——VC 是 root，manager 与它同生命周期；
        //    拿不到（极端情况 root 被换）时按「没在跑」处理，对账自身还有
        //    「本进程还在跑就不插手」之外的多层守卫（pending 存在性 / 总闸 / 时间戳）。
        let nav = window?.rootViewController as? UINavigationController
        let isStreaming = (nav?.viewControllers.first as? AIModuleViewController)?
            .manager.isReceiving ?? false
        AIMissedRoundReconciler.reconcileIfNeeded(isStreamingActive: isStreaming)

        // 🧪 对账探针（仅 DEBUG + env 指定档位时跑，见方法头）
        runMissedRoundProbeIfRequested()

        // 🧪 思考展示探针（仅 DEBUG + env 时跑；2026-10-21 崩溃修复的回归守门）
        runThinkingProbeIfRequested()

        // 🧪 块级公式探针（仅 DEBUG + env 时跑；2026-10-27 LaTeX 渲染的守门）
        runMathProbeIfRequested()
    }

    func sceneWillResignActive(_ scene: UIScene) {}

    func sceneWillEnterForeground(_ scene: UIScene) {}

    func sceneDidEnterBackground(_ scene: UIScene) {}

    // MARK: - 本地通知（UNUserNotificationCenterDelegate）

    /// 决定「通知到达时展不展示」。
    ///
    /// 🔴 **必须实现**（2026-10-18）：不实现的默认行为是「前台/inactive 一律不展示」，
    ///    而「用户锁屏等回复」正是本功能的核心场景 —— 那时 `applicationState` 是
    ///    `.inactive`，默认行为会把通知**静默丢掉**，用户回来看不到任何提示。
    /// - App `active`（用户正盯着）⇒ 静默（双保险：notifier 本就不在前台发通知）；
    /// - 其余（锁屏 / 来电横幅 / 控制中心）⇒ 正常展示。
    /// - 与 Mac 侧 `MacNotificationDelegate.willPresent` 逐字同构（`NSApp.isActive` 分流）。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // 🧪 探针档放行（仅 DEBUG + env 在）：对账补发的通知**按设计**发生在 App
        //    刚回前台的那一刻（active）⇒ 会被下面这条「前台不展示」挡掉 ⇒ 探针的
        //    delivered 判据永远查不到。产品路径上「前台不展示」是对的（用户正看着
        //    屏幕，补发通知的价值在锁屏/通知中心留痕），⛔ 别为探针改产品行为 ——
        //    只在本 Debug 探针这一个条件下放行，让 banner 露出来供截图与判据。
        #if DEBUG
        if ProcessInfo.processInfo.environment["STARRY_MISSED_ROUND_PROBE"] != nil {
            completionHandler([.banner, .list, .sound])
            return
        }
        #endif
        if UIApplication.shared.applicationState == .active {
            completionHandler([])
        } else {
            completionHandler([.banner, .list, .sound])
        }
    }

    /// 点了一条「回复已生成 / 生成失败」通知 ⇒ 跳到对应会话。
    ///
    /// ⚠️ 走 `UIApplication.shared.connectedScenes` 而不是 `self.window`：
    ///    语言切换会**换掉** window 的 rootViewController（`rebuildRootInterface`），
    ///    而 `self.window` 那条引用在 nonisolated/延迟执行语境里不可靠；查当前 keyWindow
    ///    拿到的永远是当下那个导航栈。会话页恒为导航栈 root，结构不随语言重建变。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard let id = AIReplyNotifier.conversationId(
            from: response.notification.request.content.userInfo) else {
            completionHandler()
            return
        }
        let nav = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController as? UINavigationController
        (nav?.viewControllers.first as? AIModuleViewController)?.openConversation(id)
        completionHandler()
    }

    // MARK: - 语言切换（重建主界面）

    deinit {
        // selector 形式的观察者不会自动回收（只有 block 形式在 iOS 9+ 会），所以显式退订。
        // ⚠️ 实际上 `SceneDelegate` 活到 App 结束、这条基本不会跑；写着是为了不误导后来者。
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func languageDidChange() {
        rebuildRootInterface()
    }

    // MARK: - 🧪 回前台对账探针（#if DEBUG）

    /// 「回前台对账」的无人值守探针（2026-10-19 随 `AIMissedRoundReconciler` 新增）。
    ///
    /// ## 为什么必须有探针（而不是靠真机手测）
    /// 对账的触发条件是「上一轮的结束事件丢了」——手工复现要么等系统杀进程、
    /// 要么在 Xcode 里 detach 再挂起，每一步都不可重复。探针把三个分支
    /// **直接构造**出来（造一条 5 分钟前的完整助手行落库，再按档位写 pending）：
    /// - `missed`：pending.startedAt = now ⇒ 库里最后助手行是旧的 ⇒ 「生成未完成」；
    /// - `caught`：pending.startedAt = now − 3600 ⇒ 同一行算「本轮新产出」⇒ 「回复已生成」；
    /// - `streaming`：isStreamingActive = true ⇒ 不插手，pending 留着、零通知。
    ///
    /// 判据落 `<容器>/Documents/missed_round_probe.log`（末行 `RESULT: PASS|FAIL`），
    /// 由 `sim_ios.sh` 的 `STARRY_SIM_MISSED_ROUND` 档跑完回显。
    /// ⚠️ 探针造的会话跑完即删（`deleteConversation`），不留脏数据；
    ///     `streaming` 档残留的 pending 也会在判据读完之后清掉。
    #if DEBUG
    private func runMissedRoundProbeIfRequested() {
        // 诊断行（无条件）：证明 sceneDidBecomeActive 确实跑到了这里、写文件通路是活的
        probeLog("sceneDidBecomeActive reached probe hook; envKeys="
            + ProcessInfo.processInfo.environment.keys
                .filter { $0.contains("STARRY") }.sorted().joined(separator: ","))
        // ⚠️ key **不带** `SIMCTL_CHILD_` 前缀：simctl 的约定是传进去时剥掉前缀
        //    （脚本写 SIMCTL_CHILD_STARRY_MISSED_ROUND_PROBE ⇒ App 读到的是
        //    STARRY_MISSED_ROUND_PROBE）。全仓钩子同款，见 I18NTraceProbe /
        //    AIAddModelViewController 的 STARRY_KEY_PASTE_PROBE。
        guard let mode = ProcessInfo.processInfo
            .environment["STARRY_MISSED_ROUND_PROBE"] else {
            probeLog("no probe env ⇒ skip")
            return
        }
        // 等一拍：VC 的 viewDidLoad 会首次碰 AIChatStore（建表），探针要读它
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.missedRoundProbe(mode: mode)
        }
    }

    private func missedRoundProbe(mode: String) {
        // 日志每轮清空重写（文件是 append 的，不清会把上一轮的判据混进来）
        truncateProbeLog()
        let store = AIChatStore.shared
        let expectedTitle: String
        switch mode {
        case "missed":   expectedTitle = L("生成未完成")
        case "caught":   expectedTitle = L("回复已生成")
        case "streaming": expectedTitle = ""
        default:
            probeLog("=== missed round probe · mode=\(mode) ===")
            probeLog("RESULT: FAIL (unknown mode)")
            return
        }
        probeLog("=== missed round probe · mode=\(mode) ===")

        guard store.isReady else {
            probeLog("setup: AIChatStore NOT ready")
            probeLog("RESULT: FAIL")
            return
        }

        // 造一个会话：用户行 + 一条 **5 分钟前**的完整助手回复（时间戳是判据的核心输入）
        let conversationId = UUID()
        let userRow = AIChatRow(id: UUID(), role: .user,
                                block: .text("探针消息"), isFirstBlockOfTurn: true)
        var assistantRow = AIChatRow(id: UUID(), role: .assistant,
                                     block: .text("探针造的历史回复"),
                                     isFirstBlockOfTurn: true)
        assistantRow.createdAt = Date(timeIntervalSinceNow: -300)
        let created = store.appendMessages(
            conversationId: conversationId,
            title: "missed-round-probe",
            rows: [userRow, assistantRow],
            createConversation: AIConversation(id: conversationId,
                                               title: "missed-round-probe"))
        probeLog("setup: store=ready conversation=\(conversationId.uuidString.prefix(8)) "
            + "created=\(created) assistantAge=300s")
        // 授权状态一并记下：`notifyNow` 内部 `status != .authorized` 就直接 return，
        // 模拟器上弹框没人点 ⇒ notDetermined ⇒ 一条都发不出（判据会假红）
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            self.probeLog("authStatus=\(settings.authorizationStatus.rawValue) "
                + "(0=notDetermined 1=provisional 2=denied 3=authorized 4=ephemeral)")
        }
        guard created else {
            probeLog("RESULT: FAIL (setup)")
            return
        }

        // 按档位写 pending 并跑对账（streaming 档走「本进程还在收流」守卫）
        let startedAt: TimeInterval
        switch mode {
        case "missed":   startedAt = Date().timeIntervalSince1970
        case "caught":   startedAt = Date().timeIntervalSince1970 - 3600
        case "streaming": startedAt = Date().timeIntervalSince1970
        default: startedAt = Date().timeIntervalSince1970
        }
        AIMissedRoundReconciler.probeRecordStart(conversationId: conversationId,
                                                 prompt: "探针pending",
                                                 startedAt: startedAt)
        AIMissedRoundReconciler.reconcileIfNeeded(isStreamingActive: mode == "streaming")
        // 判据一（同步）：pending 被清 ⇒ 证明对账走到了「补发 + 清账」最后一步，
        // 而不是早退（守卫挡下会留下 pending）。streaming 档反过来判「留着」。
        let pendingCleared = !AIMissedRoundReconciler.probeHasPending()
        if mode == "streaming" {
            probeLog("pendingCleared=false (expect false — 守卫挡住不清账)")
        } else {
            probeLog("pendingCleared=\(pendingCleared) (expect true)")
        }

        if mode == "streaming" {
            // 判据：没发通知 + pending 还在（守卫挡住 ⇒ 不清账）
            let pendingKept = AIMissedRoundReconciler.probeHasPending()
            AIMissedRoundReconciler.probeEnd()   // 清掉探针残留，别影响后续正常使用
            store.deleteConversation(id: conversationId)
            probeLog("pendingKept=\(pendingKept) (expect true) notifications=0 (expect 0)")
            probeLog(pendingKept ? "RESULT: PASS" : "RESULT: FAIL")
            return
        }

        // missed / caught 档：等通知交付（UN 的 add 是异步的），再查 delivered 对标题
        let identifier = AIReplyNotifier.identifier(for: conversationId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            UNUserNotificationCenter.current().getDeliveredNotifications { notes in
                let match = notes.first { $0.request.identifier == identifier }
                let title = match?.request.content.title ?? "nil"
                self?.probeLog("delivered: count=\(notes.count) title=\(title) (expect \(expectedTitle))")
                let pass = (title == expectedTitle) && pendingCleared
                self?.probeLog(pass ? "RESULT: PASS" : "RESULT: FAIL")
                store.deleteConversation(id: conversationId)
            }
        }
    }

    /// 「思考展示」的无人值守探针（2026-10-21 随 chevron 缺 `addSubview` 的崩溃修复新增）。
    ///
    /// ## 为什么必须有探针（而不是靠 typecheck）
    /// 那个崩溃**编译零症状**：漏 `headerRow.addSubview(chevron)` 时，SnapKit 在
    /// `AIThinkingBlockView.init(frame:)` 里给一个没有 superview 的视图装约束**直接崩**，
    /// 而四段 typecheck 全绿 —— 只有真机/模拟器跑得到。本探针把「带 reasoning 的
    /// 助手行」构造出来走**真实渲染路径**（落库 → `openConversation` → cell 实例化 →
    /// `configure`），崩溃与否当场现形。
    ///
    /// 档位（env `STARRY_THINKING_PROBE`，由 `sim_ios.sh` 的 `STARRY_SIM_THINKING` 透传）：
    /// - `collapsed`（默认）：只验折叠态 —— 落库读回就是它（`isThinkingExpanded` 不入库）；
    /// - `expanded`：再走**真实的** `setThinkingExpanded`（用户点开的同一路径）补展开态。
    ///
    /// 判据落 `<容器>/Documents/thinking_probe.log`（末行 `RESULT: PASS|FAIL`），
    /// 跑完即删会话，不留脏数据。
    private func runThinkingProbeIfRequested() {
        guard let mode = ProcessInfo.processInfo.environment["STARRY_THINKING_PROBE"] else { return }
        // 等一拍：VC 的 viewDidLoad 会首次碰 AIChatStore（建表），探针要读它
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.thinkingProbe(mode: mode)
        }
    }

    private func thinkingProbe(mode: String) {
        truncateThinkingProbeLog()
        thinkingProbeLog("=== thinking probe · mode=\(mode) ===")
        let store = AIChatStore.shared
        guard store.isReady else {
            thinkingProbeLog("setup: AIChatStore NOT ready")
            thinkingProbeLog("RESULT: FAIL")
            return
        }
        // 造一个会话：用户行 + 一条带 reasoning 的助手行。
        // reasoning 走**真实落库**（ai_reasoning 表）⇒ 读回就是产品里的「折叠态」。
        let conversationId = UUID()
        let think = "用户问的是升级会不会丢数据。先在脑子里过一遍落库的那几步：消息走 ai_message，思考走 ai_reasoning，这是两张不同的表，加新表不动旧表。再确认总闸关掉时历史内容还在不在——还在，只是不渲染。"
        var userRow = AIChatRow(id: UUID(), role: .user,
                                block: .text("升级会丢数据吗？"), isFirstBlockOfTurn: true)
        userRow.createdAt = Date(timeIntervalSinceNow: -120)
        var assistantRow = AIChatRow(
            id: UUID(), role: .assistant,
            block: AIBlock(kind: .text,
                           text: "好的，我把结论说在前面：这次更新不会影响已有的对话数据，可以放心升级。",
                           reasoning: AIReasoning(text: think, duration: 8.4)),
            isFirstBlockOfTurn: true)
        assistantRow.createdAt = Date(timeIntervalSinceNow: -60)
        let created = store.appendMessages(
            conversationId: conversationId,
            title: "thinking-probe",
            rows: [userRow, assistantRow],
            createConversation: AIConversation(id: conversationId, title: "thinking-probe"))
        guard created else {
            thinkingProbeLog("setup: appendMessages failed")
            thinkingProbeLog("RESULT: FAIL")
            return
        }
        thinkingProbeLog("setup: store=ready conversation=\(conversationId.uuidString.prefix(8)) reasoningChars=\(think.count)")

        // 导航到探针会话（走真实 openConversation：载入 → enterChat → reloadData → 滚到底）
        let nav = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController as? UINavigationController
        guard let vc = nav?.viewControllers.first as? AIModuleViewController else {
            thinkingProbeLog("RESULT: FAIL (AIModuleViewController not found)")
            store.deleteConversation(id: conversationId)
            return
        }
        vc.openConversation(conversationId)
        // expanded 档：内存补「用户点开」态（isThinkingExpanded 不落库，读回恒 false）
        if mode == "expanded" {
            vc.probeExpandThinking(atRowIndex: 1)
        }
        // 判据等一帧：cell 实例化发生在 openConversation 之后的布局期。
        // 两条判据**分开**（首轮的教训，见 probeReasoningChars 的头注释）：
        //   ① mountedChevrons —— init 没崩 + chevron 在视图树上（崩溃修复的守门）；
        //   ② reasoningChars  —— 落库/读回链路通（思考内容真的读得回来）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            let mounted = vc.probeMountedChevronCount()
            let reasoningChars = vc.probeReasoningChars(atRowIndex: 1)
            self?.thinkingProbeLog("mountedChevrons=\(mounted) (expect 1) reasoningChars=\(reasoningChars) (expect \(think.count))")
            let pass = mounted == 1 && reasoningChars == think.count
            self?.thinkingProbeLog(pass ? "RESULT: PASS" : "RESULT: FAIL")
            store.deleteConversation(id: conversationId)
        }
    }

    /// 「块级公式」探针（2026-10-27 随 LaTeX 渲染新增）。
    ///
    /// ## 为什么必须有（三个编译期查不出的失败点）
    /// ① **字体在 bundle 里**：SwiftMath 的数学字形是 `mathFonts.bundle` 里的 otf，
    ///    SPM 资源没被打进 app / 取不到 ⇒ `asImage()` 返回 nil，界面**静默降级成源码**
    ///    （不崩、不报错，只看着像是「公式没渲染」）；
    /// ② **画出来是空白**：坐标系 / 缩放不对时图是有的、尺寸也对，但内容是空的；
    /// ③ **量高与显示不同源**：`height` 和 `displaySize` 对不上 ⇒ 裁字或底部多一截空白。
    /// 三种都不进类型检查，只能真跑。
    ///
    /// 判据落 `Documents/math_probe.log`（末行 `RESULT: PASS|FAIL`），跑完即删会话。
    /// ⚠️ 日志文件**独立**（`math_probe.log`）：与 thinking / missed-round 共用会把上一轮的
    ///    判据混进来 —— 本工程铁律，见 `VERIFY-PROBES.md` §11.4。
    private func runMathProbeIfRequested() {
        guard ProcessInfo.processInfo.environment["STARRY_MATH_PROBE"] != nil else { return }
        // 等一拍：VC 的 viewDidLoad 会首次碰 AIChatStore（建表），探针要读它
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.mathProbe()
        }
    }

    private func mathProbe() {
        truncateMathProbeLog()
        mathProbeLog("=== math probe ===")
        let latex = "x = \\frac{-b \\pm \\sqrt{b^2-4ac}}{2a}"

        // ① 业务层能不能排出图（字体 bundle / CoreText 绘制链路）
        let rendered = AIMathBlockMetrics.image(for: latex, width: 300, inkKey: "light", color: .black)
        let displaySize = rendered?.displaySize ?? .zero
        mathProbeLog("render: image=\(rendered != nil ? "yes" : "nil") "
                     + "size=\(Int(displaySize.width))x\(Int(displaySize.height))")

        // ② 量高与图片尺寸同源（height = 显示高 + 上下留白）
        let measured = AIMathBlockMetrics.height(for: latex, width: 300)
        let expected = displaySize.height + AIMathBlockMetrics.paddingV * 2
        mathProbeLog("height: got=\(measured) expect=\(expected)")

        // ②′ 格式矩阵：模型实际会写的六种定界符，哪些能切出公式段。
        //     只认 `$$` / ```math 的话，别的写法会原样留在正文里（用户看到的就是「没生效」）。
        let matrix: [(String, String)] = [
            ("dollar-block",   "$$\n\(latex)\n$$"),
            ("dollar-sameline", "$$\(latex)$$"),
            ("bracket",        "\\[\n\(latex)\n\\]"),
            ("paren",          "\\(\(latex)\\)"),
            ("dollar-inline",  "行内 $\(latex)$ 公式"),
            ("fence-math",     "```math\n\(latex)\n```"),
        ]
        for (name, sample) in matrix {
            let segs = AIMarkdown.segments(from: sample)
            var blockCount = 0
            var inlineCount = 0
            for seg in segs {
                switch seg {
                case .math:
                    blockCount += 1
                case .text(let att):
                    att.enumerateAttribute(.attachment,
                                           in: NSRange(location: 0, length: att.length)) { value, _, _ in
                        if value is AIMathAttachment { inlineCount += 1 }
                    }
                case .code:
                    break
                }
            }
            mathProbeLog("fmt \(name): block=\(blockCount) inline=\(inlineCount)")
        }

        let store = AIChatStore.shared
        guard store.isReady else {
            mathProbeLog("setup: AIChatStore NOT ready")
            mathProbeLog("RESULT: FAIL")
            return
        }
        // ③ 走真实落库 → openConversation → cell 实例化（截图就是这一步的产物）
        //
        // 夹具刻意**混着三种写法**（都是模型真实会吐的）：
        //   · `$$ ... $$`  独占行      → 块级
        //   · `\[ ... \]`  独占行      → 块级（2026-10-27 之前完全不认）
        //   · `$...$` / `\(...\)` 行内 → 行内附件（2026-10-27 新增）
        let conversationId = UUID()
        let body = """
        求根公式如下：

        $$
        \(latex)
        $$

        行内也能写了：设 $a=1,\\ b=-3$，代入 \\(x = \\frac{3 \\pm \\sqrt{5}}{2}\\) 即可。

        另一种块级写法：

        \\[
        E = mc^2
        \\]

        把系数代进去即可。
        """
        var userRow = AIChatRow(id: UUID(), role: .user,
                                block: .text("求根公式是什么？"), isFirstBlockOfTurn: true)
        userRow.createdAt = Date(timeIntervalSinceNow: -120)
        var assistantRow = AIChatRow(id: UUID(), role: .assistant,
                                     block: .text(body), isFirstBlockOfTurn: true)
        assistantRow.createdAt = Date(timeIntervalSinceNow: -60)
        let created = store.appendMessages(
            conversationId: conversationId,
            title: "math-probe",
            rows: [userRow, assistantRow],
            createConversation: AIConversation(id: conversationId, title: "math-probe"))
        guard created else {
            mathProbeLog("setup: appendMessages failed")
            mathProbeLog("RESULT: FAIL")
            return
        }
        let nav = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController as? UINavigationController
        guard let vc = nav?.viewControllers.first as? AIModuleViewController else {
            mathProbeLog("RESULT: FAIL (AIModuleViewController not found)")
            store.deleteConversation(id: conversationId)
            return
        }
        vc.openConversation(conversationId)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            // ④ 分段：**块级必须恰好 2 段**（`$$` 一段 + `\[` 一段），行内必须恰好 2 个附件。
            //    `$$` / `\[` 漏切会留在正文里被 Down 吃坏；行内漏切则原样显示 `$a=1$`。
            let segments = AIMarkdown.segments(from: body)
            let mathCount = segments.reduce(0) { count, segment in
                if case .math = segment { return count + 1 }
                return count
            }
            var inlineCount = 0
            for segment in segments {
                guard case .text(let attributed) = segment else { continue }
                attributed.enumerateAttribute(.attachment,
                                              in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                    if value is AIMathAttachment { inlineCount += 1 }
                }
            }
            let textCount = segments.count - mathCount
            self?.mathProbeLog("segments: math=\(mathCount) (expect 2) inline=\(inlineCount) (expect 2) others=\(textCount)")

            let pass = rendered != nil
                && displaySize.height > 10
                && abs(measured - expected) < 0.6
                && mathCount == 2
                && inlineCount == 2
            self?.mathProbeLog(pass ? "RESULT: PASS" : "RESULT: FAIL")
            store.deleteConversation(id: conversationId)
        }
    }

    private func mathProbeLog(_ line: String) {
        print("[MATH] \(line)")
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("math_probe.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let data = (line + "\n").data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    private func truncateMathProbeLog() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("math_probe.log")
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    private func thinkingProbeLog(_ line: String) {
        print("[THINKING] \(line)")
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("thinking_probe.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let data = (line + "\n").data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    /// 每轮探针开始时清空日志（⛔ 不能与 missed-round 共用文件：两个诊断实例共用一个
    /// 日志文件会把上一轮的判据混进来 —— 本工程铁律，见 `VERIFY-PROBES.md` §11.4）。
    private func truncateThinkingProbeLog() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("thinking_probe.log")
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }

    private func probeLog(_ line: String) {
        print("[MISSEDROUND] \(line)")
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("missed_round_probe.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let data = (line + "\n").data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    /// 每轮探针开始时清空日志（文件是 append 的，不清会把上一轮的判据混进来）。
    private func truncateProbeLog() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("missed_round_probe.log")
        try? "".write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    /// 语言变了 ⇒ 把主界面整个重建一遍。
    ///
    /// ## 为什么必须重建（而不是「刷新一下文案」）
    /// 本工程的本地化是 `L("中文原文")` 这种**普通函数**查表（见 `AILocalization.swift` 文件头），
    /// 它**不登记任何观察依赖** —— 与本工程已踩过两次的「`@Observable` 的依赖只在 body 求值期
    /// 登记」是同一条规矩。iOS 这边的文案又是在 `viewDidLoad` 期就赋给 `UILabel` 的，
    /// 所以不重建就**只有当前这个弹窗会变**，底下整片界面停在旧语言。
    /// （Mac 侧同一个问题的解法是给 `RootView` 换 `.id(...)` 内容根身份，见 `RootView`。）
    ///
    /// ## 为什么不重跑 `registerAIModule()`
    /// 模块**早就注册在服务总线里**了（`registerAIModule()` 只在启动时那一次有意义）。
    /// 这里只是重新 `resolve` 一个**新实例**——新实例的 `viewDidLoad` 会按新语言渲染，
    /// 会话数据从 `AIChatStore` 单例重新读，不丢。
    ///
    /// ## ☠️☠️ 抽屉**换不掉**（2026-10-13 查清 —— ⛔ 别再试「重挂菜单」这条路）
    /// 左侧菜单走全局 `SideMenuManager`，它持有的是上一次造的 `AIMenuViewController`。
    /// 下面末尾那句 `setupAIMenu()` 本意是「重挂一份新语言的」—— 但**换不掉**：
    /// SideMenu 6 给那个属性装了闸门，**旧菜单还在呈现时赋值会被静默拒绝**（不报错、
    /// 只在控制台留一条 warning），而切语言恰好发生在**抽屉开着**的时候。
    /// （逐字源码 + 真机实测见 `setupAIMenu()` 的注释与技能 `ios-sidemenu-drawer` §4.5。）
    /// ⇒ 抽屉里文案的刷新**不靠**换实例，靠 `AIMenuViewController` 把文案做成
    ///   **计算属性 / 每次展示重读**（`quickItems` + `applyLocalizedText()`）。
    /// ⚠️ 末尾那句 `setupAIMenu()` **留着**：它现在是「复用实例 + 重套呈现配置」，幂等、无副作用。
    private func rebuildRootInterface() {
        guard let window else { return }
        // 先把 present 出来的东西收掉（账号弹窗 / 设置页 / 抽屉）—— 换 rootViewController
        // 会直接销毁它们，留着可能触发「attempt to present … whose view is not in the
        // window hierarchy」一类警告。⚠️ `dismiss` 不走动画：紧接着就要整屏交叉淡入，
        // 两段动画叠在一起只会看着像卡了一下。
        window.rootViewController?.dismiss(animated: false)

        guard let entry = StarryServiceBus.shared.resolve(AIModuleEntryProtocol.self) else {
            assertionFailure("AIModuleEntryProtocol 未注册 —— 语言重建时 resolve 不到")
            return
        }
        let root = UINavigationController(rootViewController: entry.AIModuleRegisterViewController())
        // 交叉淡入换 root：直接赋值是「啪」一下切成新语言，闪得刺眼。
        UIView.transition(with: window, duration: 0.2, options: .transitionCrossDissolve) {
            window.rootViewController = root
        }
        setupAIMenu()
    }
}
