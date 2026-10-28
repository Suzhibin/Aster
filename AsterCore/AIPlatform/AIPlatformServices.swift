//
//  AIPlatformServices.swift
//  AIPlatform
//
//  跨平台**行为**接缝：协议定义（本文件**不含任何平台分支**）。
//
//  ## 为什么行为用协议，而值类型用 typealias
//  值类型（字体/颜色/段落样式）要进富文本，包成协议会丢类型信息 —— 那是一条死路。
//  行为不一样，它们不出现在类型签名里，而且两平台**实现差异极大**：
//    - `AVAudioSession` 在 macOS **根本不存在**（实测 `'AVAudioSession' is unavailable in macOS`，
//      是硬错误不是「找不到」）—— mac 侧只能是另一套写法；
//    - 后台任务 iOS 是 `UIApplication.beginBackgroundTask`，macOS 要换 `ProcessInfo.beginActivity`。
//  协议的好处：**漏实现是编译期错误**，而且 iOS 侧能塞假实现做单测。
//
//  ## 注入点
//  每个能力一个 `AIPlatform.*` 静态入口，默认落到当前平台的实现。
//  单测里可换成假实现（见各 impl 文件顶部的说明）。
//

import Foundation
// ⚠️ `CGImage` / `CGSize` / `CGFloat` 要 CoreGraphics —— **两平台都是**（实测：
// 只 import Foundation 时 `CGSize` 类型名能解析，但 `.zero` 这种成员不行）。
import CoreGraphics

// MARK: - 音频会话

/// 录音权限状态（跨平台口径，对应 iOS 的 `AVAudioSession.RecordPermission`）
public enum AIRecordPermission {
    case notDetermined
    case denied
    case granted
}

/// 音频会话能力。
///
/// ⚠️ 一个 App 只有一份音频会话：`AISpeechReader` 朗读要「播放」、
/// `VoiceInputManager` 录音要「录音+播放」，两者必须**错开**（见各自文件顶部的说明）。
/// 这个协议只暴露「意图」，不暴露 `setCategory` 的参数 —— 参数是 iOS 特有的概念，
/// macOS 上根本没有会话可配（实现即 no-op）。
public protocol AIPlatformAudioSession: AnyObject {

    /// 录音权限现状（同步查询）
    func recordPermission() -> AIRecordPermission

    /// 请求录音权限。回调在主线程。
    func requestRecordPermission(_ completion: @escaping (Bool) -> Void)

    /// 切到「播放」并激活（朗读）。
    /// - Returns: 成功与否。失败时**不出声但不崩**，调用方直接放弃这一轮朗读即可。
    @discardableResult
    func activatePlayback() -> Bool

    /// 切到「录音 + 播放」并激活（语音输入）。
    /// - Returns: 失败原因（已本地化，可直接展示）；`nil` 表示成功。
    func activateRecord() -> String?

    /// 关闭音频会话（把音频交还系统）
    func deactivate()

    /// 中断通知名（来电、其他 App 抢占音频）。
    /// - Note: macOS 上恒不触发 —— 但**通知名本身仍要是有效的 `Notification.Name`**，
    ///   否则 `addObserver` 会拿到一个永不匹配的名字，行为上等价，却更难排查。
    var interruptionNotification: Notification.Name { get }

    /// 这条中断通知是不是「中断开始」。
    /// - Note: 解码 `userInfo` 是平台细节（iOS 要读 `AVAudioSessionInterruptionTypeKey`），
    ///   所以判断也收在这里，调用方只拿 Bool。
    func isInterruptionBegan(_ notification: Notification) -> Bool
}

// MARK: - 后台任务

/// 后台任务标识。
///
/// iOS 的 `UIBackgroundTaskIdentifier` 是个 `Int` 包装（`.invalid` = 0），
/// macOS 用 `ProcessInfo.beginActivity` 返回一个不透明对象 —— 统一收敛成 `Int` 句柄。
/// ⛔ 别把 `UIBackgroundTaskIdentifier` 直接写进业务层：它是 iOS 独有的类型。
public enum AIPlatformBackgroundTask {
    /// 无效句柄
    public static let invalid: Int = 0
}

/// 「让进程在后台多活一会儿」的能力。
public protocol AIPlatformBackgroundRunning: AnyObject {

    /// 申请后台任务。
    /// - Parameter onExpire: 宽限期用尽的回调。⚠️ iOS 会在**主线程同步**调用它，
    ///   回调里必须尽快 `end(_:)` 把句柄交还系统，否则 watchdog 直接杀进程。
    /// - Returns: 句柄；拿不到时返回 `AIPlatformBackgroundTask.invalid`。
    func begin(name: String, onExpire: @escaping () -> Void) -> Int

    /// 交还句柄。⚠️ iOS 侧必须**主线程**调用（由调用方保证，见 `AIChatManager` 的说明）。
    func end(_ token: Int)
}

// MARK: - 系统集成

/// 广告跟踪授权状态（iOS 14+ 才有；macOS 恒 `notDetermined`）
public enum AIPlatformTrackingStatus {
    case notDetermined
    case restricted
    case denied
    case authorized
}

/// 与本机系统打交道的能力：跳系统设置、广告跟踪授权。
public protocol AIPlatformSystemIntegration: AnyObject {

    /// 跳到「本 App 的系统设置页」（用户拒绝权限后引导去开）。
    func openAppSettings()

    /// 跳到**系统设置的通知页**（设置页「通知」第一行「系统关时点第一行」的落点）。
    ///
    /// 与 `openAppSettings` 的分工：那个落「本 App 的设置页」（通知只是其中一行），
    /// 这个直接落**通知面板本身**（macOS 的「通知与专注模式」）——
    /// 用户点它时意图就是管通知，少绕一层。
    /// ⚠️ iOS 没有「通知面板」这个 URL scheme ⇒ 两端**刻意不同址**（见各自 impl 的注释）。
    func openNotificationSettings()

    /// 广告跟踪授权现状
    func trackingStatus() -> AIPlatformTrackingStatus

    /// 请求广告跟踪授权（回调在主线程）
    func requestTracking(_ completion: @escaping (AIPlatformTrackingStatus) -> Void)
}

// MARK: - 图像编解码

/// 图像编解码能力。
///
/// 收在这里的两件事都**必须**用平台 API：
///   - JPEG 压缩：iOS 走 `UIGraphicsImageRenderer` + `jpegData`，macOS 走 `NSBitmapImageRep`；
///   - `CGImage` → 平台图像：`UIImage(cgImage:)` / `NSImage(cgImage:size:)`。
/// 其余（降采样读图、读像素尺寸）是纯 ImageIO，**两平台同一份代码**，留在 `AIAttachment`。
public protocol AIPlatformImageCodec: AnyObject {

    /// `CGImage` → 平台图像
    func makeImage(from cgImage: CGImage) -> AIPlatformImage

    /// 等比缩到 `maxSide` 以内并编成 JPEG。
    /// - Returns: (JPEG 数据, 压缩后的像素尺寸)；编不出来返回 nil
    func compressedJPEG(_ image: AIPlatformImage,
                        maxSide: CGFloat,
                        quality: CGFloat) -> (data: Data, size: CGSize)?
}

// MARK: - 统一通知名

/// 平台生命周期事件 —— **统一名字**，让业务层不必知道消息是谁发的。
///
/// 原先 `SQLiteManager` 直接观察 `UIApplication.didReceiveMemoryWarningNotification`，
/// 那等于把 iOS 写死在基础设施里。现在它只认这里的名字，由各平台 impl 负责桥接。
public enum AIPlatformNotification {

    /// 内存警告。macOS **无此概念，永不触发**。
    public static let memoryWarning = Notification.Name("com.starry.platform.memoryWarning")

    /// 进入后台 / 离开活跃。
    /// - iOS: `UIApplication.didEnterBackgroundNotification`
    /// - macOS: `NSApplication.didResignActiveNotification`（应用失焦 ≈ iOS 进后台）
    public static let didEnterBackground = Notification.Name("com.starry.platform.didEnterBackground")

    /// 装平台 → 统一通知名的桥。**幂等**，重复调用只装一次。
    /// - Note: 各平台 impl 在 `init` 里自己调；业务层不必手动调。
    public static func installBridges() {
        AIPlatformLifecycleBridge.install()
    }
}

// MARK: - App 活跃状态

/// App 是否正被用户盯着（前台且可交互）。
///
/// ## 为什么需要这个判断
/// 「回复生成完 ⇒ 发本地通知」的大前提是**用户此刻不在看 App**（切走了才需要通知）。
/// 而这个判断两平台是**硬差异**，所以必须收进接缝层：
///   - iOS：`UIApplication.shared.applicationState == .active`；
///   - macOS：没有「前台/后台」这一对概念，最接近的是 `NSApp.isActive`
///     （App 失焦 ≈ 用户切去了别处）。
///
/// ⚠️ iOS 的 `inactive`（来电横幅 / 控制中心 / 通知中心下拉的那一两秒）**算不在前台**：
///   那一刻用户同样没在看内容，通知发得正当。
public enum AIPlatformApp {
    public static var isActive: Bool { PlatformAppActivity.isActive }
}

// MARK: - 容器宽度

/// 行高量算的默认容器宽度。
///
/// 为什么会在这里：`AIChatManager.contentWidth` 原先的默认值是 `UIScreen.main.bounds.width`，
/// 而 `UIScreen` 在 macOS 上不存在。
///
/// ⚠️ 这只是**首帧之前的临时值** —— 真正的宽度永远由 UI 层在布局时灌进来
/// （iOS: `AIModuleViewController` 的 `viewDidLayoutSubviews`；macOS: SwiftUI 的 GeometryReader）。
/// 但**不能给 0**：0 宽会让 `boundingRect` 把每行都算成超高，首帧会看到一串撑开的空行。
public enum AIPlatformMetrics {

    /// 默认容器宽度。iOS 保持 `UIScreen.main.bounds.width`（与拆分前一致），macOS 给一个窗口档位。
    public static var defaultContainerWidth: CGFloat { PlatformMetrics.defaultContainerWidth }
}

// MARK: - 路径

/// 应用数据目录。
///
/// ## 为什么这也算平台差异（而不是随便取一个）
/// 原先两处都写死了 `.documentDirectory`：
///   - `SQLiteManager.getDB()` → `NSSearchPathForDirectoriesInDomains(.documentDirectory, …)` → `db.sqlite3`
///   - `AIAttachmentStorage.directory` → `Documents/AIAttachments`
/// 在 iOS 上 `.documentDirectory` 就是**沙盒容器里的** `Documents`，怎么写都行。
/// **macOS 不一样**：沙盒 App 去碰真实的 `~/Documents` 会被 TCC 拦下
/// （而 `ENABLE_USER_SELECTED_FILES = readonly` 只放开「用户主动选的文件」，
/// 不含我们自己拼出来的路径）→ 数据库静默建不出来，会话一条都存不下。
///
/// 所以 macOS 侧改用 `.applicationSupportDirectory` —— 它在容器内、无需任何额外权限，
/// 也正是 Apple 建议放「非用户可见的应用数据」的位置（数据库、附件都属于这类）。
///
/// ⚠️ iOS 侧**保持 `.documentDirectory` 不动**：改了会让老用户的既有会话/附件全部「消失」
/// （其实是换了目录）。迁移数据不是这次要做的事。
///
/// ⚠️ macOS 侧返回的目录**可能还不存在**（Application Support 下没有自动建），
/// 实现里已经 `createDirectory` 兜住。
public enum AIPlatformPaths {

    /// 应用数据根目录。子目录（附件等）由调用方自己拼。
    public static var appDataDirectory: URL { PlatformPaths.appDataDirectory }
}

// MARK: - 统一入口

/// 平台能力的入口。
///
/// 每个 `Platform*` 类型在各自的 impl 文件里定义（`#if` 关在那边），
/// 一次性编译只会有**一个**分支存在，所以这里能直接写死类型名。
///
/// `var` 而不是 `let`：给将来「单测里换成假实现」留口子（改 `PlatformAudioSession.shared` 即可）。
/// 目前没有别的写入方 —— 别在业务代码里改它。
public enum AIPlatform {
    /// 音频会话（朗读 / 录音）
    public static var audio: AIPlatformAudioSession { PlatformAudioSession.shared }
    /// 后台任务（收流时让进程多活一会儿）
    public static var background: AIPlatformBackgroundRunning { PlatformBackgroundRunner.shared }
    /// 系统集成（跳系统设置 / 广告跟踪授权）
    public static var system: AIPlatformSystemIntegration { PlatformSystemIntegration.shared }
    /// 图像编解码（JPEG 压缩 / CGImage → 平台图像）
    public static var imageCodec: AIPlatformImageCodec { PlatformImageCodec.shared }
}
