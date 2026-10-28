//
//  MacVoiceCallWindow.swift
//  AsterMac
//
//  「打电话」**独立窗口**（2026-10-12）。用户口径：「按钮事件打开一个新的 Window」。
//
//  ## 为什么是独立窗口，不是 sheet / 不是右侧面板
//  通话是一件**会持续几分钟、且与聊天并读**的事：一边跟 AI 说话，一边还想翻会话页里
//  它刚才说的原文。sheet 会把主窗锁住（翻不了记录）；`.inspector` 是会话页的一块附属面板，
//  而通话窗**在概念上不属于任何一个会话**（关掉它，会话照旧）——
//  ⇒ 与「图片/视频预览」同一档：独立窗口有系统级身份（⌘` 切换、能最小化、能被「窗口」菜单列出）。
//
//  ## 一个窗口，不是"一个会话一个窗口"
//  通话窗**不绑定会话**：它发出去的每一句都进"当前会话"（走 `ChatModel`），
//  在通话中切会话 ⇒ 后续几句进新的那个。这是刻意的（与输入栏那颗发送键一致），
//  ⛔ 别做成"打开时锁定当时的会话"，那会让"切了会话却还在跟旧会话说话"变得可能。
//
//  ## ☠️ 四条从 `MediaPreviewWindow` 抄来的铁律（那边每条都付过代价，别再踩）
//  ① **`isReleasedWhenClosed = false`**：默认 `true` ⇒ `close()` 会 release 一次
//     而我们表里还持有一份引用 ⇒ 之后访问是野指针、摘表是二次释放。
//  ② **不在 `close()` 里 `contentView = nil`**：实测会让**同进程里其它窗口不再重绘**
//     （窗口在屏上、`isVisible` 为真，截图却只剩空框）。收尾改成"通知模型停麦克风"。
//  ③ **`tabbingMode = .disallowed`**：不然系统会把两个通话窗合并成标签页。
//  ④ **标题栏不显示标题**用 `titleVisibility = .hidden`，⛔ 不是把 `title` 置空串
//     （置空串仍会居中留一块空位）。`window.title` 本身要设 —— 「窗口」菜单与 ⌘` 读它。
//
//  ## 收尾只有一条路：`window.close()`
//  红绿灯 / ⌘W / 那颗红钮**三条路都汇到 `close()`**，由它调 `model.teardown()`。
//  ⛔ 别让"那颗红钮"自己去调 teardown：那样走了 ⌘W 的用户**麦克风会被一直占着**
//     （窗口没了、录音还在跑，而且不报任何错）。
//  ⚠️ 所以 `MacVoiceCallModel` 里**没有** `hangUp()` —— 挂断 = 关窗，别的什么都不用做。
//
//  ## ⌥+E：按住临时开麦（参考图第 2 张那句）
//  用**本地事件监视器**而不是 `keyDown` 响应链：这条链的第一响应者可能是窗内任意子视图
//  （SwiftUI 里尤其说不准），而"按住某组合键"要求**按下与松开都能收到**、且不受焦点影响。
//  ⚠️ 只吞「本窗口恰好是 key window」那一种，别的 ⌥+E **原样放行**（否则会把其它 App
//     或者本 App 别处的 ⌥+E 一起吃掉）。
//  ☠️ **松开可能收不到**（⌥+E 按着时用户切走了 App / 窗口失去焦点）⇒ 另外挂一条
//     `didResignKey` 兜底：那一刻若还在"按住"态，就地收起（否则麦克风一直开着）。
//

import AppKit
import SwiftUI
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

// MARK: - 窗口

/// 通话窗口。继承 `NSWindow` 只为了「关窗那一拍把麦克风收掉」。
final class MacVoiceCallWindow: NSWindow {

    /// 关窗时要收尾的那个状态机（由中心注入）。
    var callModel: MacVoiceCallModel?

    /// 窗口关掉了（中心用它把这一条从表里摘掉）。
    var onClose: (() -> Void)?

    /// 收尾只做一次：`close()` 可能被走多条路进来（红绿灯 / ⌘W / 那颗红钮）。
    private var didTearDown = false

    override func close() {
        if !didTearDown {
            didTearDown = true
            // 🔴 **只停麦克风/朗读，不拆 `contentView`**（见文件头铁律 ②）。
            callModel?.teardown()
        }
        super.close()
        onClose?()
        onClose = nil
    }
}

// MARK: - 窗口中心

/// 通话窗的登记处 + 开窗逻辑（同 `MediaPreviewWindowCenter` 的模式）。
///
/// 🔴 单例是**必须**的：不持有窗口引用的话，`NSWindow` 会在闭包返回后被释放（窗口一闪就没）。
@MainActor
final class MacVoiceCallWindowCenter {

    static let shared = MacVoiceCallWindowCenter()

    /// 当前那个通话窗（同时只允许一个 —— 通话是"跟 AI 打电话"，开两个没有语义）
    private var window: MacVoiceCallWindow?

    /// ⚠️ 2026-10-27 删掉了 `chatWindow` 与 `revealChatWindow()`：它们唯一的消费者是底部
    ///    那颗「消息」钮，而用户要求「底部四个按钮去掉前面俩个」时把它一起删了。
    ///    ⛔ 别把"记下开窗前的 keyWindow"那条留着当备胎 —— 没有消费者的 `weak` 引用
    ///    只会在下一次读它的人手里骗出一个 nil（用户点一下发现"没反应"）。
    ///    ℹ️ 通话窗本身不是 modal、也不是 sheet ⇒ 用户随时可以直接点后面的会话窗，
    ///    这个能力没有丢，只是少了那颗快捷钮。

    /// ⌥+E 的本地事件监视器（返回值必须留着，否则会被回收）
    private var optionEMonitor: Any?
    /// 失焦兜底观察者（见文件头最后一段）
    private var resignObserver: NSObjectProtocol?

    /// 🧪 自动开窗钩子只触发一次（见 `openIfRequested`）
    private var didAutoOpen = false

    private init() {}

    // MARK: 开窗

    /// 打开通话窗（已经开着就把它提到前面）。
    func open(chatModel: ChatModel) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let model = MacVoiceCallModel(chatModel: chatModel)
        let window = MacVoiceCallWindow(
            contentRect: NSRect(origin: .zero, size: MacVoiceCallTheme.contentSize),
            // ⛔ 不含 `.resizable`：这一页的排版是**定尺寸**摆的（球 / 三点 / 两行字 / 两颗钮），
            //    可缩放只会让"中间那块"在很宽的窗口里漂得很难看。参考图上它也是不能拉的。
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = L("语音通话")
        // ⛔ 不是 `window.title = ""`（那仍会在标题栏居中留一块空位）
        window.titleVisibility = .hidden
        // 标题栏与内容区同色。
        // ⚠️ 2026-10-12 起内容区是 `MacStarrySkyView` 的**深空**（不再是浅色卡片）⇒ 标题栏也跟着深，
        //    否则浅色主题下就是「深空内容 + 白标题栏」= 顶着一顶白帽子（真窗口截图一眼可见）。
        window.titlebarAppearsTransparent = true
        // ☠️ 光有上面那一行**不够**：`titlebarAppearsTransparent` 只是让标题栏**透明**，
        //    透出来的是**窗口自己的 `backgroundColor`**（默认 `windowBackgroundColor` = 浅灰），
        //    ⛔ 不是内容视图的底色。不显式设这一行，就是「深内容 + 浅灰标题栏条」= 一道横缝
        //    （离屏图照不到，只有真窗口截图看得见）。
        // 🔴 值**从主题取**（与内容区深空底同一个常量）：两处各写一个必然漂成两色。
        window.backgroundColor = MacVoiceCallTheme.skyDeepestNSColor
        window.isMovableByWindowBackground = true
        window.contentMinSize = MacVoiceCallTheme.minContentSize
        // 铁律 ①③（见文件头）
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        let view = MacVoiceCallView(
            model: model,
            // 挂断 = 关窗（收尾在 `close()` 里，见文件头那段）
            onHangUp: { [weak self] in
                guard let self else { return }
                self.close()
            }
        )
        window.contentView = NSHostingView(rootView: view)
        window.callModel = model

        self.window = window
        window.onClose = { [weak self] in
            guard let self else { return }
            self.window = nil
            // 窗口没了 ⇒ ⌥E 监视器也跟着撤（它只服务于通话窗）
            self.removeOptionEMonitor()
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        installOptionEMonitor()
        installResignObserver()

        // 🔴 **窗口上来之后**才起通话：它内部会弹权限框（首次），
        //    在窗口出现之前弹，用户看到的是一个莫名其妙的系统框盖着空屏。
        model.startCall()
    }

    /// 关窗（红钮走它；红绿灯 / ⌘W 由系统直接走 `close()`）。
    func close() {
        window?.close()
    }

    // MARK: - 🧪 验收钩子：自动开窗

    /// `STARRY_CALL_UI=1` ⇒ 首屏落地后**自动开一次**通话窗。
    ///
    /// ## 为什么非要有它
    /// 这台机器上**没有任何命令行点按手段**（`osascript` 发合成鼠标事件会被沙箱拦，
    /// 见 `VERIFY-PROBES` 里那条"真手势只能人手按"）—— 没有这个钩子，
    /// 「通话窗长什么样」agent 侧就只能靠人手开，**截图取证无从谈起**。
    /// 这与 Mac 侧既有的 `STARRY_ROOT_MENU=1` / `STARRY_FIXTURE_DOC=1` 是同一条路子。
    ///
    /// ## 两个约束
    /// 1. **只在 `#if DEBUG` 里编译**（Release 包里这段根本不存在）；
    /// 2. **只触发一次**（闩在 `didAutoOpen`）—— 不然窗口一关又会被打开，永远关不掉。
    /// ⚠️ 走的是**和点那颗按钮完全相同的那条路**（`open(chatModel:)`），
    ///    ⛔ 别另写一条"直接造窗口"的捷径 —— 那样验的就不是用户真实走的路径了。
    func openIfRequested(chatModel: ChatModel) {
        #if DEBUG
        guard !didAutoOpen else { return }
        guard ProcessInfo.processInfo.environment["STARRY_CALL_UI"] == "1" else { return }
        didAutoOpen = true
        // 等这一帧画完再开：主窗口自己的首屏动画还没跑完就抢 key，会把主窗口的
        // 初始布局截在"半透明残影"那一帧上（与 iOS 侧 `openVoiceCallIfRequested` 同一个理由）。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.open(chatModel: chatModel)
        }
        #endif
    }

    // MARK: ⌥+E

    /// 「按住 ⌥+E 暂时开麦」（参考图上那句）。
    private func installOptionEMonitor() {
        guard optionEMonitor == nil else { return }
        optionEMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            // ☠️ 与 `MediaPreviewWindow.installEscapeMonitor` 同一条：NSEvent 不进
            //    `assumeIsolated` 的 @Sendable 闭包 ⇒ 边界外取值，闭包里只回 Bool。
            //    `swallow = true` 含两种：执行了动作、以及「重复拍」——两者都要吞。
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let isKeyDown = event.type == .keyDown
            let isRepeat = event.isARepeat
            let swallow = MainActor.assumeIsolated { () -> Bool in
                // 只认"通话窗是当前窗口"那一种；别的窗口 / 别的 App 的 ⌥+E 原样放行
                guard let window = NSApp.keyWindow as? MacVoiceCallWindow,
                      let model = window.callModel else { return false }
                // 14 = E（ANSI 键位，与键盘布局无关的那一档）
                guard keyCode == 14,
                      flags.contains(.option) else { return false }

                if isKeyDown {
                    // 按住不放会一直来 `keyDown`，只在第一拍开麦（重复拍：吞，不开麦）
                    guard !isRepeat else { return true }
                    model.beginPushToTalk()
                } else {
                    model.endPushToTalk()
                }
                return true   // 吞掉：别让它变成输入字符（⌥E 在系统里是输入死音符的）
            }
            return swallow ? nil : event
        }
    }

    private func removeOptionEMonitor() {
        if let monitor = optionEMonitor {
            NSEvent.removeMonitor(monitor)
            optionEMonitor = nil
        }
    }

    /// 失焦兜底：⌥+E 按着的时候窗口失去焦点 ⇒ `keyUp` **永远不会来**，
    /// 那麦克风就一直开着（用户看不见，只觉得自己被偷听了）。
    private func installResignObserver() {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? MacVoiceCallWindow,
                      let model = window.callModel else { return }
                model.endPushToTalk()
            }
        }
    }
}
