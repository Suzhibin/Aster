//
//  MacNotificationDelegate.swift
//  AsterMac
//
//  Mac 侧本地通知的接收端（2026-10-18，「回复生成完」通知，配套 `AIReplyNotifier`）。
//
//  ## 与 iOS 侧的差异（刻意不同，别「统一」）
//  | | iOS（SceneDelegate） | Mac（本类） |
//  |---|---|---|
//  | 前台是否展示 | **不实现** `willPresent` ⇒ 默认不展示 | 实现了但 active 时返回 `[]` 抑制 |
//  | 回前台清通知 | `sceneDidBecomeActive` | 观察 `NSApplication.didBecomeActiveNotification` |
//  | 点击跳转 | `openConversation(id)` | `ChatModel.select(id)` |
//
//  macOS 上「不实现 willPresent」的默认行为是**照样展示横幅**（与 iOS 相反）——
// 所以必须实现并按 `NSApp.isActive` 分流。iOS 侧反之：实现了才会展示。
//
//  ## 安装点
//  `AsterMacApp.init()` 里 `UNUserNotificationCenter.current().delegate = …`。
//  必须早于任何窗口出现：通知可能在冷启动期间就到达。
//

import AppKit
import UserNotifications
// 🔴 `ChatModel`（通知点击后要 `select(id)` 跳会话）在 App module 里。
import AICore

final class MacNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    private weak var model: ChatModel?

    init(model: ChatModel?) {
        self.model = model
        super.init()
        // 用户没点通知、直接切回 App ⇒ 通知中心里挂着的「回复已生成」该消失。
        // （点通知时系统会自动移除那一条，不用我们管；这里兜的是「没点」那条路。）
        // ⚠️ selector 形式不会在 deinit 自动退订 ⇒ 见 deinit。
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appDidBecomeActive),
                                               name: NSApplication.didBecomeActiveNotification,
                                               object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 决定「通知到达时展不展示」。
    ///
    /// 🔴 App 正被用户用着 ⇒ **不展示**（与 iOS 的默认行为对齐；两端都不许在前台弹横幅）。
    ///    顺带清掉已送达的旧通知：回前台这一刻它们就没意义了。
    /// ⚠️ macOS 的默认行为是「前台也展示」，所以这个分支必须存在 —— 删了就是骚扰。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if NSApp.isActive {
            AIReplyNotifier.clearAll()
            completionHandler([])
        } else {
            completionHandler([.banner, .sound])
        }
    }

    /// 点了一条通知 ⇒ 跳到对应会话。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let id = AIReplyNotifier.conversationId(
            from: response.notification.request.content.userInfo) else { return }
        model?.select(id)
    }

    /// ⚠️ `@objc` 方法按语言规则是 **nonisolated** 的 ⇒ 这里只调 nonisolated 的
    ///    `clearAll()`，⛔ 别在这里碰 `model`（MainActor 隔离类）。
    @objc private func appDidBecomeActive() {
        AIReplyNotifier.clearAll()
    }
}
