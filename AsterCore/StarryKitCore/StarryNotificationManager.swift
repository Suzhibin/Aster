//
//  File.swift
//  BaseModule
//
//  Created by Suzhibin on 2026/7/21.
//

import Foundation
import UserNotifications
// ⚠️ 这里用 `canImport(AppKit)` 而不是 `#if os(macOS)`：本工程铁律是
//    「`#if os(` 只许出现在 `AIPlatform/` 内」（脚本机械检查），平台**能力**判断
//    一律走 canImport —— 且对本包（只有 iOS / macOS 两个平台）语义逐字等价。
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// 本地通知管理器 — 负责调度、查询、移除本地通知，以及应用图标角标管理。
///
/// 权限请求统一走 StarryPermission，本类只负责通知的增删查和角标设置。
///
/// ```swift
/// // 延迟发送
/// StarryNotificationManager.shared.send(
///     timeInterval: 60,
///     identifier: "download_done",
///     title: "下载完成",
///     body: "视频已保存到本地"
/// )
///
/// // 指定时间发送（若时间已过则忽略）
/// StarryNotificationManager.shared.schedule(
///     at: Date().addingTimeInterval(3600),
///     identifier: "task_reminder",
///     title: "提醒",
///     body: "记得完成待办"
/// )
///
/// // 移除
/// StarryNotificationManager.shared.remove(identifier: "download_done")
///
/// // 查询
/// let exists = await StarryNotificationManager.shared.hasPending(identifier: "download_done")
///
/// // 角标
/// StarryNotificationManager.shared.setBadge(5)
/// StarryNotificationManager.shared.resetBadge()
/// ```
public final class StarryNotificationManager {

    // MARK: - 单例

    public static let shared = StarryNotificationManager()

    private init() {}

    // MARK: - 发送通知（时间间隔）

    /// 延迟指定秒数后发送一条本地通知
    /// - Parameters:
    ///   - timeInterval: 延迟时间（秒），必须 > 0
    ///   - identifier: 通知唯一标识，用于后续移除或去重
    ///   - title: 通知标题
    ///   - body: 通知正文
    ///   - sound: 通知声音，默认为系统默认提示音；传 nil 则静音
    public func send(timeInterval: TimeInterval,
                     identifier: String,
                     title: String,
                     body: String,
                     sound: UNNotificationSound? = .default) {
        guard timeInterval > 0 else { return }

        StarryPermission.request(.notification) { status in
            guard status == .authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if let sound { content.sound = sound }

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval,
                                                            repeats: false)
            let request = UNNotificationRequest(identifier: identifier,
                                                content: content,
                                                trigger: trigger)
            UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - 发送通知（指定时间）

    /// 在指定时间发送一条本地通知
    /// - Parameters:
    ///   - date: 目标触发时间；若为 nil 或已过期则跳过
    ///   - identifier: 通知唯一标识
    ///   - title: 通知标题
    ///   - body: 通知正文
    ///   - sound: 通知声音，默认系统提示音
    ///
    /// 适用于"某任务设置了提醒时间"的场景：
    /// ```swift
    /// StarryNotificationManager.shared.schedule(
    ///     at: task.alertDate,
    ///     identifier: task.uid,
    ///     title: "任务提醒",
    ///     body: task.name
    /// )
    /// ```
    public func schedule(at date: Date?,
                         identifier: String,
                         title: String,
                         body: String,
                         sound: UNNotificationSound? = .default) {
        // ⚠️ `Date - Date` 在 Swift 里**不存在**（只有 `Date - TimeInterval`）——
        //    2026-10-17 全量 typecheck 抓到的搬迁笔误：该文件 mtime（7-28）早于
        //    DerivedData 里的模块产物 ⇒ SPM 增量判定「不需重编」，错误从未暴露。
        //    判据/成因见 `VERIFY-PROBES.md`（增量构建漏编那一节）。
        guard let date, date.timeIntervalSinceNow > 0 else { return }

        let interval = date.timeIntervalSinceNow
        send(timeInterval: interval,
             identifier: identifier,
             title: title,
             body: body,
             sound: sound)
    }

    // MARK: - 移除通知

    /// 移除指定标识符的待触发通知（不影响已送达的通知）
    /// - Parameter identifier: 通知唯一标识
    public func remove(identifier: String) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // MARK: - 立即发送（无延迟、无触发时间）

    /// 立刻投递一条本地通知（`trigger = nil`，不排队、不等时间）。
    ///
    /// 与 `send(timeInterval:)` 的分工：那个是「定时/延迟提醒」场景（timeInterval 必须 > 0）；
    /// 本方法是「某事此刻已经发生了」场景（如下载/生成完毕、失败），**iOS/macOS 两端通用**。
    /// - Parameter userInfo: 附加载荷（如 `["conversationId": "...]`），供点击通知时取回上下文
    public func notifyNow(identifier: String,
                          title: String,
                          body: String,
                          userInfo: [AnyHashable: Any]? = nil,
                          sound: UNNotificationSound? = .default) {
        StarryPermission.request(.notification) { status in
            guard status == .authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = userInfo ?? [:]
            if let sound { content.sound = sound }

            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: identifier,
                                      content: content,
                                      trigger: nil)
            )
        }
    }

    // MARK: - 清理

    /// 清掉**已送达**的通知（通知中心里正挂着的那几条）。
    /// 传空数组 = 清全部（本 App 只有一类通知，全清是安全的）。
    public func clearDelivered() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [])
    }

    /// 已经**送达**的通知列表（通知中心里用户能看到的那几条）。
    /// - 立即投递（`trigger = nil`）的通知只在 delivered 里出现、不进 pending；
    ///   验收探针靠它确认「通知真的到了用户眼前」。
    public func deliveredNotifications() async -> [UNNotification] {
        await UNUserNotificationCenter.current().deliveredNotifications()
    }

    /// 清掉全部**待触发**的通知（含延迟发送还没到点的）。
    public func clearPending() {
        UNUserNotificationCenter.current()
            .removeAllPendingNotificationRequests()
    }

    // MARK: - 查询

    /// 异步检查指定标识符的待触发通知是否存在
    /// - Parameter identifier: 通知唯一标识
    /// - Returns: true 表示存在一条待触发的匹配通知
    public func hasPending(identifier: String) async -> Bool {
        let requests = await UNUserNotificationCenter.current()
            .pendingNotificationRequests()
        return requests.contains { $0.identifier == identifier }
    }

    /// 检查指定标识符 + 目标时间是否已有待触发通知
    ///
    /// 先判断 alertDate 是否为 nil，再异步查询。
    /// 适用于"任务有提醒时间时检查是否已创建通知"的场景：
    /// ```swift
    /// let exists = await StarryNotificationManager.shared
    ///     .hasPending(identifier: task.uid, alertDate: task.alertDate)
    /// ```
    public func hasPending(identifier: String, alertDate: Date?) async -> Bool {
        guard alertDate != nil else { return false }
        return await hasPending(identifier: identifier)
    }

    // MARK: - Badge 角标

    /// 设置应用图标角标数字
    /// - Parameter number: 角标数字，0 表示清除
    ///
    /// 需通知权限已授权，内部自动通过 StarryPermission 请求权限。
    /// ```swift
    /// StarryNotificationManager.shared.setBadge(5)
    /// ```
    public func setBadge(_ number: Int) {
        StarryPermission.request(.notification) { status in
            guard status == .authorized else { return }
            self.applyBadge(number)
        }
    }

    /// 清除应用图标角标
    ///
    /// 直接清除，不检查权限（清除操作无需授权）。
    /// ```swift
    /// StarryNotificationManager.shared.resetBadge()
    /// ```
    public func resetBadge() {
        applyBadge(0)
    }

    /// 平台差异化的角标设置（内部方法）
    private func applyBadge(_ number: Int) {
        // 同文件头：能力判断走 canImport（`#if os(` 只许在 AIPlatform 内）
        #if canImport(AppKit)
        DispatchQueue.runOnMain {
            NSApp.dockTile.badgeLabel = number > 0 ? "\(number)" : nil
        }
        #else
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(number)
        } else {
            DispatchQueue.runOnMain {
                UIApplication.shared.applicationIconBadgeNumber = number
            }
        }
        #endif
    }
}
