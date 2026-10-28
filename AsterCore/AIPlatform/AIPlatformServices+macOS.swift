//
//  AIPlatformServices+macOS.swift
//  AIPlatform
//
//  macOS 侧实现。整文件被 `#if canImport(AppKit)` 包住 —— 编译 iOS 时本文件**被整个跳过**。
//
//  ## 哪些是「真空缺」，哪些是「换个写法」
//  真空缺（Mac 上压根没这个概念，只能 no-op 或换模型）：
//    - `AVAudioSession` —— 实测 `'AVAudioSession' is unavailable in macOS`（硬错误）。
//      Mac 没有「音频会话」这一层：App 直接拿 audio unit 出声，没有 category/mode/activation 的概念。
//      所以 `activatePlayback` / `activateRecord` / `deactivate` 只能是 no-op。
//      ⚠️ 但**录音权限**不是 no-op —— Mac 有麦克风授权，只是入口在 `AVCaptureDevice` 而不是会话。
//    - `ATTrackingManager` —— iOS 独有，Mac 无广告跟踪授权。
//  换写法：
//    - 后台任务：iOS 是 `UIApplication.beginBackgroundTask`，Mac 用 `ProcessInfo.beginActivity`
//      （作用是阻止 App Nap，语义正好对上「收流时别让进程被降频」）。
//    - 进后台：iOS 有 `didEnterBackground`，Mac 用「失去焦点」近似。
//
//  ## 为什么 `.accessibility(...)` 之类的语义色没被映射
//  不需要：`AITypography` 用的**全是固定色**（刻意避开语义色，因为它要写在固定浅底气泡上）。
//  实测 `NSColor(white:alpha:)` / `.black` / `.white` 在 macOS 上原样可用。
//

#if canImport(AppKit)

import AppKit
import AVFoundation
import ImageIO

// MARK: - 音频会话

final class PlatformAudioSession: AIPlatformAudioSession {

    static let shared = PlatformAudioSession()
    private init() {}

    // MARK: 权限（Mac 上**不是** no-op —— 麦克风授权真实存在，只是入口不同）

    func recordPermission() -> AIRecordPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:            return .granted
        case .denied:                return .denied
        case .restricted:            return .denied
        case .notDetermined:         return .notDetermined
        @unknown default:            return .notDetermined
        }
    }

    func requestRecordPermission(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: 会话（Mac 无此概念，no-op）

    /// Mac 没有音频会话可配，直接算成功 —— 与 iOS 的失败语义区分开
    /// （iOS 失败 = 不出声但继续；Mac 不返回 false，免得调用方白放弃一轮朗读）。
    func activatePlayback() -> Bool { true }

    /// - Returns: 恒 `nil`（无会话可失败）
    func activateRecord() -> String? { nil }

    func deactivate() {}

    // MARK: 中断

    /// Mac 上不会发这条通知。
    /// ⚠️ 仍返回一个**有效**的 `Notification.Name`（而不是空名字）：
    /// `addObserver` 至少要能正常注册，将来若接 `AVAudioEngine` 的配置变更通知可直接换成它。
    var interruptionNotification: Notification.Name {
        Notification.Name("com.starry.platform.audioInterruption")
    }

    func isInterruptionBegan(_ notification: Notification) -> Bool { false }
}

// MARK: - 后台任务

final class PlatformBackgroundRunner: AIPlatformBackgroundRunning {

    static let shared = PlatformBackgroundRunner()
    private init() {}

    /// 句柄 → `ProcessInfo` 活动对象。⚠️ 只从主线程访问（调用点是发送/重新生成，都在主线程）。
    private var activities: [Int: NSObjectProtocol] = [:]
    private var nextToken = 1

    /// `.userInitiated` 的作用是**阻止 App Nap** —— 相当于 iOS 的「后台多活一会儿」。
    /// 刻意**不加** `.idleSystemSleepDisabled`：那会连整机休眠都拦住，一个聊天流不值得。
    ///
    /// - Note: `onExpire` 在 Mac 上**永不触发** —— 活动没有「宽限期到点」这回事，
    ///   收尾一律由调用方 `end(_:)` 主动做。
    func begin(name: String, onExpire: @escaping () -> Void) -> Int {
        let token = nextToken
        nextToken += 1
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: name)
        activities[token] = activity
        return token
    }

    func end(_ token: Int) {
        guard let activity = activities.removeValue(forKey: token) else { return }
        ProcessInfo.processInfo.endActivity(activity)
    }
}

// MARK: - 系统集成

final class PlatformSystemIntegration: AIPlatformSystemIntegration {

    static let shared = PlatformSystemIntegration()
    private init() {}

    /// 打开「系统设置 › 隐私与安全性」。用户拒绝权限后引导过去手动开。
    func openAppSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    /// 打开「系统设置 › 通知与专注模式」—— macOS 的 URL scheme 直达通知面板
    /// （iOS 没有对应 scheme，那边刻意回落到 App 设置页，见 iOS impl 注释）。
    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    // MARK: 广告跟踪（iOS 独有）

    /// Mac 无广告跟踪授权。返回 `.authorized` 语义 = **「无此限制，别拦着」**，
    /// 与 iOS 侧「14 以下无需 IDFA 授权 → `.authorized`」是同一套处理。
    /// （实际上 Mac 端不会走到这条判定。）
    func trackingStatus() -> AIPlatformTrackingStatus { .authorized }

    func requestTracking(_ completion: @escaping (AIPlatformTrackingStatus) -> Void) {
        DispatchQueue.main.async { completion(.authorized) }
    }
}

// MARK: - 图像编解码

final class PlatformImageCodec: AIPlatformImageCodec {

    static let shared = PlatformImageCodec()
    private init() {}

    func makeImage(from cgImage: CGImage) -> AIPlatformImage {
        NSImage(cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// 等比缩到 `maxSide` 以内并编成 JPEG。
    ///
    /// ⚠️ **尺寸取像素而不是 `image.size`**：`NSImage.size` 是**点**（pt），
    /// 一个 144 DPI 的图 `size` 只有像素的一半 —— 照它缩放会得到一张一半分辨率的图。
    /// iOS 侧的对应写法是 `image.size * image.scale`，这里等价地直接读 rep 的 `pixelsWide/High`。
    func compressedJPEG(_ image: AIPlatformImage,
                        maxSide: CGFloat,
                        quality: CGFloat) -> (data: Data, size: CGSize)? {
        let source: CGSize
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            source = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        } else {
            source = image.size
        }
        guard source.width > 0, source.height > 0 else { return nil }

        var target = source
        let longSide = max(source.width, source.height)
        if longSide > maxSide {
            let scale = maxSide / longSide
            target = CGSize(width: floor(source.width * scale), height: floor(source.height * scale))
        }

        // ☠️☠️ 2026-10-06 修（用户报「Mac 我发的图片是黑屏」）：这里**必须**是 4 通道带 alpha。
        //
        //  `NSGraphicsContext(bitmapImageRep:)` **只接受 4 通道（或 1 通道灰度）的位图**；
        //  传「3 通道无 alpha」（原来的写法）时它**返回 nil**，于是下面三行绘制**全部落空**：
        //  `NSGraphicsContext.current = nil` ⇒ `image.draw(in:)` 画不到任何地方 ⇒
        //  位图从头到尾**没被写过** ⇒ 编出来的 JPEG 是**全黑**。
        //
        //  ☠️ 症状之所以极其隐蔽：**尺寸完全正确**（缩放那一段是好的）、
        //  `representation(using: .jpeg)` 也**成功返回数据**、文件大小看着也正常 ——
        //  只有像素是黑的。实测：抽取用户容器里 10 张历史附件，**全部 100% 纯黑**，
        //  最早可追到 2026-09-22（附件功能上线那天）⇒ 从 Mac 发出的每一张图都是黑的。
        //  ⚠️ 而助手侧的图片是远程 URL、**不走这条路**（不重新编码）⇒ 只有「自己发的图」是黑的，
        //  这正是用户措辞的由来。
        //  📌 判据由 `.workbuddy/scripts/probe_black_jpeg.sh` 守着（它编译**本文件**、
        //  真跑一遍编码再回读像素）——⛔ 别只靠「源码里是不是写了 4」这种契约。
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(target.width),
                                         pixelsHigh: Int(target.height),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // 🔴 先铺白底：JPEG **没有** alpha 通道，带透明的图（PNG 截图等）若直接编，
        //    透明区域会被压成黑。铺白之后「alpha=1」处处成立，也顺手避开了
        //    「预乘 alpha 被直接丢掉 ⇒ 整体偏暗」那一类问题。
        NSColor.white.setFill()
        NSRect(origin: .zero, size: target).fill()
        image.draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .jpeg,
                                            properties: [.compressionFactor: quality]) else { return nil }
        return (data, target)
    }
}

// MARK: - 容器宽度

enum PlatformMetrics {
    /// Mac 上**没有一个「屏幕宽度」是合理的默认值**（窗口可任意缩放，还可能是多屏）。
    /// 取 900 只是「首帧之前的临时占位」—— 真正的宽度由 SwiftUI 的 GeometryReader 灌进来。
    /// ⚠️ 不能给 0：0 宽会让 `boundingRect` 把每行都算成超高，首帧会看到一串撑开的空行。
    static var defaultContainerWidth: CGFloat { 900 }
}

// MARK: - 路径

enum PlatformPaths {
    /// `~/Library/Application Support/<bundleID>/`（沙盒下即容器内）。
    ///
    /// ⚠️ 三层注意：
    ///  1. **不用 `.documentDirectory`** —— Mac 沙盒下那是真实的 `~/Documents`，会被 TCC 拒掉，
    ///     数据库会**静默**建不出来（`getDB()` catch 掉后返回 nil，表现是「发完消息重启就没了」）。
    ///  2. `.applicationSupportDirectory` 返回的是 `…/Application Support`，**不含 App 子目录**，
    ///     所以这里拼上 bundleID —— 既符合惯例，也避免和别的 App 混在同一个目录里。
    ///  3. 该子目录**默认不存在**，必须自己 `createDirectory`；失败就退回不拼 bundleID 的父目录
    ///     （有写权限但目录乱一点，总比完全写不了强）。
    static var appDataDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let id = Bundle.main.bundleIdentifier ?? "Aster"
        let dir = base.appendingPathComponent(id, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            debugPrint("[AIPlatform] 创建 Application Support 子目录失败，退回父目录: \(error)")
            return base
        }
    }
}

// MARK: - App 活跃状态

enum PlatformAppActivity {
    /// macOS 没有「进后台」：`NSApp.isActive` 就是「用户此刻在不在用这个 App」的最好近似。
    /// Mac 上「App 没有可见窗口但仍是 active」是可能的（只剩菜单栏）—— 那时用户确实
    /// 在用本 App，不该发通知，所以不另做「有无可见窗口」的判断。
    static var isActive: Bool { NSApp.isActive }
}

// MARK: - 生命周期桥

enum AIPlatformLifecycleBridge {

    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let nc = NotificationCenter.default
        // 内存警告在 macOS 无对应物 —— 不桥接（`AIPlatformNotification.memoryWarning` 永不触发）。
        // 失焦 ≈ iOS 进后台：SQLiteManager 借此释放连接，回到前台时由 getDB() 懒加载重连。
        nc.addObserver(forName: NSApplication.didResignActiveNotification,
                       object: nil, queue: nil) { _ in
            nc.post(name: AIPlatformNotification.didEnterBackground, object: nil)
        }
    }
}

#endif
