//
//  AINotificationPreferences.swift
//  AICore
//
//  「回复生成完 ⇒ 本地通知」的**用户偏好存取点**（2026-10-18 随通知设置页新增）。
//
//  ## 它管哪两件事（与用户给的参考图逐条对齐）
//  ① **桌面通知总闸**（`isEnabled`）：关掉之后 `AIReplyNotifier` 一条都不发
//     —— 飞书那张参考图里「桌面通知」没有开关（它把权限整个交给系统设置），
//     但我们的通知是 App 内功能，用户要能在 App 里一键闭嘴；系统授权归第一行
//     的「轻点前往系统设置」管（2026-10-19 起：系统关时第一行开关跟着关、
//     点第一行去系统设置；系统开时第一行就是总闸本体）。
//  ② **显示内容预览**（`showsPreview`）：关掉后通知不透露会话标题 / 错误原因
//     （锁屏上旁人一眼看得到内容的场景）。
//  ⚠️ 提示音档位 2026-10-19 删除（用户要求）：通知一律跟随系统默认音，
//     `notifyNow` 不传 sound 即是。自合成音效 `notify_lingdong.caf` 与
//     `AINotificationSound` 枚举一并退役。
//
//  ## 为什么存取点在共享层（而不是两端各写一份）
//  与 `AIFontSizeStore` 同款理由：消费方只有共享层一个（`AIReplyNotifier` 在 AICore），
//  两端 UI 只是**读写同一个 key**（UserDefaults 两端本就互相独立，各存各的）。
//  ⛔ 别在某一端另写一个 store：默认值会散成两份，改默认值那天必漏一处。
//
//  ## 🔴 非 `@Observable` ⇒ UI 层必须配 `@State` 镜像
// 两个偏好都是静态计算属性，写它**不会**让任何界面重算（Mac 铁律：
// 「读它界面不动，编译得过、不报错」）。两端设置页因此都镜像一份（见各自文件头）。
//  ⚠️ 也不需要 didChange 广播：这两个值**只在设置页被改**，而设置页自己会重算；
//     通知发送时（`AIReplyNotifier.post`）现读即可，永远是新值。

import Foundation
// 🔴 `UNUserNotificationCenter` 来自 UserNotifications ——
//    本工程 `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`：用谁的 API 就得显式 import 谁。
import UserNotifications

// MARK: - 系统授权状态

/// 系统通知授权状态（跨平台口径，对应 `UNAuthorizationStatus`）。
///
/// 两端**语义一致**（UN 框架是跨平台的），所以收在共享层；
/// ⛔ 别把 `UNAuthorizationStatus` 直接透出到 UI 层（它是 UN 的类型，且枚举大小写
/// 与界面文案是两件事）。
///
/// 无关联值的枚举 ⇒ `==` 白拿（UI 层直接 `authorization == .authorized` 判「系统开没开」）。
/// 2026-10-19 起不提供 `title` / `hint`：设置页第一行自己按状态出文案
/// （系统关 ⇒「轻点前往系统设置」；系统开 ⇒ 不需要任何提示）。
public enum AINotificationAuthorization {
    /// 还没问过用户（首次发通知时才会弹框）。
    case notDetermined
    /// 用户明确拒绝（只能去系统设置开）。
    case denied
    /// 已允许（含 provisional 临时授权 —— 它同样收得到通知）。
    case authorized
}

// MARK: - 存取点

/// 「通知」偏好的**唯一存取点**（两个偏好 + 授权状态查询）。
public enum AINotificationPreferences {

    // MARK: 键

    /// ⚠️ 带命名空间前缀：`UserDefaults` 是与系统及其它版本共用的命名空间
    ///    （与 `AILanguageStore` / `AIFontSizeStore` 同款理由）。
    ///    两端**键名故意相同**：同一个偏好，各存在各自的容器里。
    private static let enabledKey = "Aster.notifyReply.enabled"
    private static let previewKey = "Aster.notifyReply.preview"

    // MARK: ① 桌面通知总闸

    /// App 不在前台时，回复生成完成 / 失败是否发系统通知。默认 **开**
    /// （与 2026-10-18 功能上线时的行为一致 —— 默认值改动等于改产品行为）。
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // MARK: ② 显示内容预览

    /// 通知里是否显示会话标题 / 错误原因。默认 **开**（不显示内容的通知几乎没用）。
    public static var showsPreview: Bool {
        get { UserDefaults.standard.object(forKey: previewKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: previewKey) }
    }

    // MARK: 系统授权状态

    /// 异步查系统授权状态。回调线程**不保证**（UN 的完成处理器在系统队列上）
    /// ⇒ 调用方（UI 层）自己 `DispatchQueue.main.async` 回来。
    ///
    /// ☠️ **没有 app bundle 的进程必须挡掉**：`UNUserNotificationCenter.current()` 内部要建
    ///    「本进程的 bundle proxy」，裸可执行文件 / 无 bundleIdentifier 的环境下它抛
    ///    `NSInternalInconsistencyException`（bundleProxyForCurrentProcess is nil）——
    ///    **NS 异常在 Swift 里接不住**，直接 abort（134）。渲染台（`render_mac_ui.sh`）
    ///    编出来的就是 /tmp 下的裸可执行文件 ⇒ 曾整台崩在「通知」页的 onAppear 上。
    ///    判据用 `bundleIdentifier`：真 App（iOS / macOS / 扩展）恒有，harness 恒无。
    public static func authorization(_ completion: @escaping (AINotificationAuthorization) -> Void) {
        guard Bundle.main.bundleIdentifier != nil else {
            // harness 里没有真授权状态可查 —— 给「已允许」这个**不误导**的默认值
            // （界面照常渲染得出，只是那一行小字不是真状态）。
            completion(.authorized)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            completion(Self.map(settings.authorizationStatus))
        }
    }

    /// `UNAuthorizationStatus` → 跨平台口径。
    ///
    /// ⚠️ `.provisional`（临时授权，静默送达）**归到 authorized**：它同样收得到通知，
    ///    界面上显示「已允许」是对的（显示「未询问」会误导用户去开权限）。
    ///    `.ephemeral`（App Clip 临时授权）本 App 不会出现，同样归 authorized。
    private static func map(_ status: UNAuthorizationStatus) -> AINotificationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        case .authorized, .provisional, .ephemeral: return .authorized
        @unknown default:    return .notDetermined
        }
    }
}
