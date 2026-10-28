//
//  AsterMacApp.swift
//  AsterMac
//
//  Mac 端入口。与 iOS 侧（AppDelegate + SceneDelegate）完全不同 ——
//  那边是 UIKit 的重导航栈，这边只有「一个窗口 + 一个设置面板」，不需要任何路由层。
//  （iOS 侧原来那个 URLNavigator 也已摘掉，见 `SceneDelegate+Init.swift: registerAIModule()`。）
//

import SwiftUI
import UserNotifications
// 🔴 用到 `NSScreen`（默认尺寸要按屏幕可见区夹一下）。
//    ⚠️ 本工程开了 `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`：
//    用谁的 API 就得**显式** import 谁 —— 只 `import SwiftUI` 拿不到 `NSScreen`。
//    iOS target 是 15.0 / Mac 是 14.0，这条铁律在本工程比 SPM侧更严。
import AppKit
// 🔴 `AILanguageStore`（语言偏好）在 `AICore`，同样要显式 import。
import AICore

@main
struct AsterMacApp: App {

    /// 整个窗口共用一个模型实例。
    ///
    /// ⚠️ 必须是 `@State`（App 级）而不是在 `RootView` 里建：
    /// `AIChatManager` 持有正在进行的流式连接，视图重建（切主题 / 换尺寸 / 侧栏开合）
    /// 会重建 `View` 结构体，若模型跟着被重建，流就断了。
    @State private var model: ChatModel

    /// 本地通知接收端（「回复生成完」，见 `MacNotificationDelegate` / `AIReplyNotifier`）。
    /// 与 model 同生命周期：delegate 里要点通知跳会话，必须拿到**同一个** ChatModel 实例。
    private let notificationDelegate: MacNotificationDelegate

    /// 启动期基础设施。
    ///
    /// ## 为什么放在 `init()` 而不是 `.task` / `.onAppear`
    /// View 一出现就可能立刻读配置（渲染设置面板 / 发第一条消息），
    /// 所以偏好恢复必须早于任何 View 求值 —— `App.init()` 是唯一有这个保证的位置。
    ///
    /// 🔴 **顺序不能倒**：`@State` 的默认值是在 `init` 体**之前**求值的，所以
    /// `@State private var model = ChatModel()` 那种写法一定跑在下面两个
    /// `restoreAtLaunch()` 前面。因此模型改成**没有默认值**，在 init 体里显式构造。
    ///
    /// - Note: iOS 侧对应 `SceneDelegate+Init.swift` 那一串 setup（那边还挂了网络监听等
    ///   App 级组件）；Mac 端只需要外观 / 语言 / 模型这三步。
    ///   📌 2026-10-17：`StarryMMKV.initializeKV()` 随 `StarryMMKV` 整体删除而退役 ——
    ///   API Key 现在走 `Documents/models.json`，不再有「存储未初始化 ⇒ 静默失效」那一坑。
    init() {
        // 恢复上次在账号菜单里选的外观（浅色 / 深色 / 跟随系统）。
        // 🔴 必须在**任何窗口出现之前**：晚了会先按系统外观画一帧再跳档（启动闪一下）。
        // ⚠️ 它读 `UserDefaults` —— 放在这里纯粹是为了「早于所有视图求值」这个保证。
        MacAppearanceStore.restoreAtLaunch()
        // 语言偏好（跟随系统 / 简体中文 / English）。
        // ⚠️ 与外观不同，它**不需要**「在窗口出现之前应用」—— 语言没有「应用」这一步，
        //    `L()` 是查表即时的；这里只是把认不出的残留值清掉。
        // ⚠️ 但**必须在 `ChatModel()` 之前**：模型的构造会读配置并组装文案，
        //    虽然当前那一批还没接进词表，先把顺序摆正，免得以后加了文案才发现时机不对。
        AILanguageStore.restoreAtLaunch()
        let chatModel = ChatModel()
        _model = State(initialValue: chatModel)
        // 🔴 本地通知接收端（2026-10-18，「回复生成完」通知，见 `MacNotificationDelegate`）。
        //    必须早于任何窗口/通知到达：冷启动期间一轮生成可能就结束了，
        //    delegate 没装上 ⇒ 点击跳转丢失、前台抑制失效。
        //    ⚠️ 与 model 绑**同一个实例**（`@State` 默认值在 init 体之前求值，所以先用
        //       局部变量构造，再分别交给 State 和 delegate）。
        notificationDelegate = MacNotificationDelegate(model: chatModel)
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    /// 窗口**内容区**默认尺寸（不含标题栏，`defaultSize` 就是这个口径）。
    ///
    /// 🔴 宽度按「**三栏同时在场**仍够聊」定的（2026-10-08：1120 → 1340 → **1540**）：
    ///左栏 260（`RootView` 的 `navigationSplitViewColumnWidth`）
    ///   + 右侧面板 **340**（⚠️ 是 `min` 不是 `ideal` 480 —— `.inspector` 打开时只认 `min`、
    ///     `ideal` 从来没生效过，成因见 `MacTheme.webPagePanelWidth` 头注）
    ///   = 600 常驻 ⇒ 聊天区 = `窗口宽 − 600`
    ///
    /// | 窗口宽 | 聊天区 |
    /// |---|---|
    /// | 1120（旧） | 520，长回复/代码块得横着拖 |
    /// | 1340（现） | **940**，代码块和网页面板能并排看 |
    ///
    /// ⚠️ 别再往小调：低于 ~1200 就会让三栏打架。⚠️ 别照 `webPagePanelIdealWidth`(480) 定宽度，
    ///    那个数**不生效**，照它算会以为只剩 380 而误判。
    /// ⚠️ 1540 这个值**超出 14 吋内置屏的可见宽（约 1512）约 28pt** —— 是有意的：
    ///    宁可让窗口边缘略微出屏，也别为了「正好塞进内屏」把聊天区又压回 900。
    ///    真塞不下时 `defaultWindowSize` 会按屏幕收敛（见下）。
    /// ⚠️ 高度 800 是配套的 —— 13/14 吋 MacBook 内置屏可用高度约 850（扣掉菜单栏），
    ///    再高就顶出屏幕、且压到 Dock。
    /// 🔴🔴 **改了这个值却「重跑没变化」—— 先看这里**（2026-10-08 踩过两次）：
    ///
    ///   macOS 对 `WindowGroup` 有**隐式的 frame 自动保存**：窗口开出来的尺寸被系统写进
    ///   `UserDefaults`，下次启动**直接恢复那个 frame**，`defaultSize` 压根不会被读。
    ///   ⇒ 症状和「代码没生效」一模一样，但改多少次都没用。
    ///
    ///   查证（一条就够，第二条是宽度）：
    ///   ```sh
    ///   defaults read com.github.suzhibin.AsterMac | grep "NSWindow Frame"
    ///   #→ "NSWindow Frame SwiftUI.ModifiedContent<AsterMac.RootView, …>-1-AppWindow-1"
    ///   #   = "313 85 1120 760 0 0 1512 944 "   ← 存的是旧值，没跟着改
    ///   ```
    ///
    ///   处置（三步，缺一步就白改 —— 2026-10-08 实测**三层**都得过）：
    ///   ```sh
    ///   pgrep -x AsterMac || echo "必须先完全退出，退出时会写回"
    ///   defaults delete com.github.suzhibin.AsterMac \
    ///     "NSWindow Frame SwiftUI.ModifiedContent<AsterMac.RootView, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<AsterMac.ChatModel>>>-1-AppWindow-1"
    ///   killall -u "$(whoami)" cfprefsd   #🔴 最容易漏的一步，见下
    ///   ```
    ///   ☠️ **`cfprefsd` 才是真凶**：偏好是它读的，`defaults delete` 只改磁盘，
    ///   它**内存里还留着旧值** ⇒ App 照旧拿到旧 frame，退出时又写回磁盘。
    ///   症状是「明明删了、重跑还是老样子，再查磁盘确实没了」——
    ///   只做前两步会得出「代码没生效」的错误结论。
    ///
    ///   还有一条 `NSWindow Frame SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<…>>`
    ///   （`SwiftUI._AppearanceActionModifier` 那个变体）—— 换了外观会命中它，
    ///   删不干净就**换一次外观再换回来**触发它重写。分栏宽度另有
    ///   `NSSplitView Subview Frames …SidebarNavigationSplitView`，一般不用管。
    ///
    /// ⚠️ 查证顺手发现：**Mac 产物叫 `Aster.app` 而不是 `AsterMac.app`**
    ///   （09-27 把 Mac target 的 `PRODUCT_NAME` 改成 `Aster` 的结果，
    ///   bundle id 仍是 `...AsterMac`）。按 target 名在 DerivedData 里找不到它，得看 bundle id。
    ///
    /// ⚠️ ⛔ **别写代码去覆盖这个行为**（比如启动时强行 `setFrame`）：系统记住窗口尺寸是
    ///   macOS 的标准行为，用户拖好的尺寸下次就该还在。抹掉它 = 每次启动都强制回到默认，
    ///   反而变成「我的窗口大小老是被重置」。正确姿势是**留记忆 + 改默认时手动清一次**。
    ///
    /// ⚠️ 只影响**首次启动 / 新开窗口**；已开着的窗口按用户上次拖的尺寸恢复，
    ///    嫌小得自己拖宽一次（或按住 ⌥ 拖 = 只调高度），不是 bug。
    private static let preferredWindowWidth: CGFloat = 1340
    private static let preferredWindowHeight: CGFloat = 800

    /// 实际给的默认尺寸：**按当前屏幕可见区夹一下**。
    ///
    /// ⚠️ `defaultSize` 只给「想要的」，窗口真开出来会按屏幕裁。外接小屏 / 窗口开在
    ///    副屏时 1540 可能超出可见宽，窗口就会被系统压扁（右侧面板和聊天区一起缩水）。
    /// 🔴 上限**故意用 `visible.width + overhangSlack` 而不是 `visible.width − 边距**：
    ///    macOS 窗口本来就可出屏、贴边那侧超出几十 pt 视觉完全正常，而为了「正好塞进
    ///    内屏」去砍宽度是亏本买卖 —— 聊天区直接少一截，正是用户 10-08 要解决的问题。
    ///    ⚠️ 本机实测（14 吋 MacBook，逻辑屏）**可见宽1512**：留边距那版会把 1540 夹成
    ///    1472，等于白加 68；现在上限 1512+40=1552 > 1540 ⇒ **用户要的 1540 能完整拿到**。
    /// 真塞不下（比本机窄的屏）才由min() 收敛；取不到屏幕就回落 preferred。
    private static let overhangSlack: CGFloat = 40
    private static var defaultWindowSize: CGSize {
        guard let screen = NSScreen.main else {
            return CGSize(width: preferredWindowWidth, height: preferredWindowHeight)
        }
        let visible = screen.visibleFrame
        return CGSize(
            width: min(preferredWindowWidth, max(visible.width + overhangSlack, 900)),
            height: min(preferredWindowHeight, max(visible.height - 60, 520))
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // 🔴 通知权限预热（2026-10-19，用户要求「首次启动就请求」）。
                //    落点选 `.onAppear` 而不是 `init()`：授权弹窗只在 App **active** 时
                //    弹得出来，而 `init()` 跑在窗口出现之前（那一刻还不算激活）；
                //    `.onAppear` 是「窗口已显示」的时刻，与 iOS 的 `sceneDidBecomeActive` 对位。
                //    ⚠️ RootView 换 `.id(...)` 重建时 onAppear 会重跑 —— `warmup()`
                //       内有 `didWarmup` 闩 + 总闸 guard，重复调用零副作用。
                // 🔴 回前台对账（2026-10-19，通知策略补丁 B）：与 iOS 同一条逻辑
                //    （`AIMissedRoundReconciler`）。macOS 不会被挂起 ⇒ 正常路径
                //    pending 总会被清，这里只兜「进程 crash」一种，同样值得。
                //    ⚠️ 流式中 RootView 若重建，onAppear 重跑 ⇒ 对账重跑 ——
                //       那时 `isReceiving` 为 true，reconciler 直接跳过，不会误发。
                .onAppear {
                    AIReplyNotifier.warmup()
                    AIMissedRoundReconciler.reconcileIfNeeded(
                        isStreamingActive: model.manager.isReceiving)
                }
        }
        .defaultSize(width: Self.defaultWindowSize.width,
                     height: Self.defaultWindowSize.height)
        .commands {
            // 🔴 实体在 `MacMainMenuCommands.swift` —— 抽出去是为了让 `root` 档的真窗口探针
            //    能挂**同一份**命令（探针那个 App 也要判「菜单栏跟没跟上语言」，
            //    而它读的是 `NSApp.mainMenu`；详见那个文件的文件头）。
            MacMainMenuCommands(model: model)
        }

        // 设置面板走 Mac 惯例：独立窗口 + Cmd+,（而不是塞在聊天页里的一个入口）
        // ⚠️ 这一页**不再需要管理器**（2026-10-14 第三次改动：表单里那张「用量与计费」卡
        //    被用户删掉 ⇒ 不再读库）。改造前这里传 `model.manager` 就是为了那张卡。
        // 📌 2026-10-13 起它从「两页 TabView」变成「一页表单 + 取消/保存」（`MacAddModelView`）。
        // 📌 2026-10-14 它连着往里退**两层**：
        //      ① 先退到「自定义模型」清单页（`MacCustomModelListView`，表单改由清单页以
        //         **sheet** 弹出 —— macOS 的设置窗口没有导航栈，弹出式面板才是这一平台的做法；
        //         iOS 那边是 push，两套形态刻意不同）；
        //      ② 再退到**设置窗本身**（`MacSettingsView`）：左侧分组菜单 + 右侧内容，
        //         用户要求「设置页面左侧是菜单，右侧是不同设置功能」，并把原先挂在
        //         账号菜单里的**语言设置 / 外观设置**都收进来。
        //    ⇒ 现在这一行的落点是**设置窗**，清单页是它「功能 → 模型」那一页的内容。
        //    ⚠️ 层级链在 `MacSettingsView` / `MacCustomModelListView` 的文件头各写了一份，
        //       改层级时两处一起看。
        Settings {
            MacSettingsView()
        }
    }
}
