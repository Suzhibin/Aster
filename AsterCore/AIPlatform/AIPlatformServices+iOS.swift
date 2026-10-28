//
//  AIPlatformServices+iOS.swift
//  AIPlatform
//
//  iOS 侧实现。整文件被 `#if canImport(UIKit)` 包住 —— 编译 macOS 时本文件**被整个跳过**。
//
//  ⚠️ 这里的行为必须与拆分前**逐位一致**：原先这些调用点散在
//  `StarryPermission` / `AISpeechReader` / `VoiceInputManager` / `AIChatManager` / `AIAttachment` 里，
//  搬过来只是换了个位置，没有改任何参数。
//

#if canImport(UIKit)

import UIKit
import AVFoundation
import AppTrackingTransparency
import ImageIO

// MARK: - 音频会话

final class PlatformAudioSession: AIPlatformAudioSession {

    static let shared = PlatformAudioSession()
    private init() {}

    // MARK: 权限

    func recordPermission() -> AIRecordPermission {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .undetermined: return .notDetermined
        case .denied:       return .denied
        case .granted:      return .granted
        @unknown default:   return .notDetermined
        }
    }

    func requestRecordPermission(_ completion: @escaping (Bool) -> Void) {
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: 激活 / 关闭

    /// ⚠️ 必须是 `.playback` + `.spokenAudio`：用 `.ambient` / `.soloAmbient` 时
    /// 用户开着静音开关就**一点声音都没有** —— 这是「代码没报错但听不见」的头号原因。
    /// 另加 `.duckOthers`：正在放的音乐压低音量而不是被掐断。
    ///
    /// 🔴 只在**真的不一样**时才 `setCategory`（2026-10-11 加）：改 category 是一次音频系统重配置，
    ///    紧挨着朗读做它会被听成一次打嗝 —— 社区那篇「AVSpeechSynthesizer stutter」的结论就是
    ///    「每次朗读前都无脑 setCategory + setActive，去掉了就不卡了」。本类原先正是每读一次配一次。
    ///
    /// ☠️ 判据必须**读真实状态**（`session.category` / `.mode`），**不要**自己缓存一个"上次配了什么"：
    ///    中断、来电、系统抢占都会让缓存失真，而失真方向是「该配的时候不配」
    ///    ⇒ 变成**静默无声**（本工程最忌讳的失败形态）。读实际状态永远是对的。
    /// ⚠️ `setActive(true)` 则每次都调 —— 它幂等、开销极小，且中断结束后必须重新激活。
    func activatePlayback() -> Bool {
        // 与 `activateRecord()` 同一条规矩：`setActive` **不许在主线程调**（iOS 26 起会警告，
        // 真机上还会让紧随其后的音频引擎起不来）。细节见那个方法里那段注释。
        DispatchQueue.global(qos: .userInitiated).sync {
            let session = AVAudioSession.sharedInstance()
            do {
                if session.category != .playback || session.mode != .spokenAudio {
                    try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                }
                try session.setActive(true)
                return true
            } catch {
                debugPrint("[AISpeech] 音频会话启动失败: \(error)")
                return false
            }
        }
    }

    /// `.playAndRecord` + 扬声器：避免把外放切到听筒。
    /// - Note: 与 `activatePlayback()` 同一个道理，同样只在真的不一样时才重配。
    ///
    /// ## 🔴 为什么整段必须**离开主线程**（2026-10-26 实机反馈）
    /// iOS 26 起系统会在控制台警告：
    /// `AVAudioSession_iOS.mm:978 This method can lead to UI unresponsiveness if called
    ///  on the main thread. Consider using the asynchronous activate/deactivate API instead`
    /// 实测在真机上，主线程这一下不只是"慢"——它会让紧随其后的 `AVAudioEngine` 采不到输入，
    /// 表现是**通话页和输入框的语音输入一起没反应**（两条路共用这一个入口）。
    /// ⚠️ 别改成 `Task { await session.activate() }` 那种纯异步：本方法的签名是同步的
    ///    （`startRecording()` 要靠它在装配 tap **之前**就绪），改成异步会让调用方
    ///    「以为开好了、其实还在激活中」⇒ 又是静默失败。这里用 `global().sync`
    ///    **在后台线程执行、主线程等它** —— 语义不变，但调用不再发生在主线程上。
    func activateRecord() -> String? {
        DispatchQueue.global(qos: .userInitiated).sync {
            let session = AVAudioSession.sharedInstance()
            do {
                if session.category != .playAndRecord || session.mode != .default {
                    // `.allowBluetooth` 自 iOS 8 起弃用（官方改名 `.allowBluetoothHFP`，
                    // 同一个 0x4 位、行为完全一致）⇒ Xcode 27 起报弃用警告，直接换新名。
                    try session.setCategory(.playAndRecord, mode: .default,
                                            options: [.defaultToSpeaker, .allowBluetoothHFP])
                }
                try session.setActive(true)
                return nil
            } catch {
                return "音频会话启动失败：\(error.localizedDescription)"
            }
        }
    }

    func deactivate() {
        // 同上：`setActive(false)` 在主线程同样会触发那条警告
        DispatchQueue.global(qos: .userInitiated).sync {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                debugPrint("[AIPlatform] 关闭音频会话失败: \(error)")
            }
        }
    }

    // MARK: 中断

    var interruptionNotification: Notification.Name {
        AVAudioSession.interruptionNotification
    }

    func isInterruptionBegan(_ notification: Notification) -> Bool {
        guard let info = notification.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return false }
        return type == .began
    }
}

// MARK: - 后台任务

final class PlatformBackgroundRunner: AIPlatformBackgroundRunning {

    static let shared = PlatformBackgroundRunner()
    private init() {}

    func begin(name: String, onExpire: @escaping () -> Void) -> Int {
        let token = UIApplication.shared.beginBackgroundTask(withName: name) { onExpire() }
        return Int(token.rawValue)
    }

    func end(_ token: Int) {
        guard token != AIPlatformBackgroundTask.invalid else { return }
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
    }
}

// MARK: - 系统集成

final class PlatformSystemIntegration: AIPlatformSystemIntegration {

    static let shared = PlatformSystemIntegration()
    private init() {}

    func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        DispatchQueue.main.async { UIApplication.shared.open(url) }
    }

    /// iOS 没有「通知面板」的 URL scheme ⇒ 与 `openAppSettings` **同址**
    /// （App 设置页的第一节就是「通知」，再深没有公开 API 可达）。
    func openNotificationSettings() {
        openAppSettings()
    }

    func trackingStatus() -> AIPlatformTrackingStatus {
        guard #available(iOS 14, *) else { return .authorized }  // iOS 14 以下无需 IDFA 授权
        return Self.map(ATTrackingManager.trackingAuthorizationStatus)
    }

    func requestTracking(_ completion: @escaping (AIPlatformTrackingStatus) -> Void) {
        guard #available(iOS 14, *) else {
            DispatchQueue.main.async { completion(.authorized) }
            return
        }
        ATTrackingManager.requestTrackingAuthorization { _ in
            DispatchQueue.main.async { completion(Self.map(ATTrackingManager.trackingAuthorizationStatus)) }
        }
    }

    @available(iOS 14, *)
    private static func map(_ status: ATTrackingManager.AuthorizationStatus) -> AIPlatformTrackingStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted:    return .restricted
        case .denied:        return .denied
        case .authorized:    return .authorized
        @unknown default:    return .notDetermined
        }
    }
}

// MARK: - 图像编解码

final class PlatformImageCodec: AIPlatformImageCodec {

    static let shared = PlatformImageCodec()
    private init() {}

    func makeImage(from cgImage: CGImage) -> AIPlatformImage {
        UIImage(cgImage: cgImage)
    }

    /// 等比缩到 `maxSide` 以内并编成 JPEG。
    ///
    /// ⚠️ 尺寸取 `image.size`（**已按 `imageOrientation` 换算过**），而不是 `cgImage.width/height`。
    /// 后者是「未旋转」的原始像素：竖拍（orientation = .right/.left）时它和实际显示尺寸是**转置**的，
    /// 于是 `draw(in: target)` 会按错误的宽高比拉伸 —— 竖图被压成横的。
    /// 相册那条路一直没暴露这个（`PHPicker` 递过来的图基本已归一化成 `.up`），
    /// **相机拍的图 orientation 常是 `.right`**，走这条链路必现。
    func compressedJPEG(_ image: AIPlatformImage,
                        maxSide: CGFloat,
                        quality: CGFloat) -> (data: Data, size: CGSize)? {
        let source = CGSize(width: image.size.width * image.scale,
                            height: image.size.height * image.scale)
        guard source.width > 0, source.height > 0 else { return nil }

        var target = source
        let longSide = max(source.width, source.height)
        if longSide > maxSide {
            let scale = maxSide / longSide
            target = CGSize(width: floor(source.width * scale), height: floor(source.height * scale))
        }

        // scale = 1 + opaque：产物尺寸 == 目标像素尺寸，且不带 alpha（JPEG 不需要）
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let redrawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = redrawn.jpegData(compressionQuality: quality) else { return nil }
        return (data, target)
    }
}

// MARK: - 容器宽度

enum PlatformMetrics {
    /// 与拆分前完全一致：原先 `AIChatManager.contentWidth` 的默认值就是它。
    static var defaultContainerWidth: CGFloat { UIScreen.main.bounds.width }
}

// MARK: - 路径

enum PlatformPaths {
    /// iOS 的 `.documentDirectory` 就在沙盒容器里，与拆分前取到的是同一条路径。
    static var appDataDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

// MARK: - App 活跃状态

enum PlatformAppActivity {
    /// iOS 的「前台且可交互」。`.inactive`（来电 / 控制中心 / 下拉通知中心）**不算** active
    /// —— 那一刻用户同样没在看内容，「该不该发通知」的答案与进后台相同。
    static var isActive: Bool {
        UIApplication.shared.applicationState == .active
    }
}

// MARK: - 生命周期桥

enum AIPlatformLifecycleBridge {

    private static var installed = false

    /// 幂等安装：把 `UIApplication` 的两条通知桥到统一名字上。
    static func install() {
        guard !installed else { return }
        installed = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                       object: nil, queue: nil) { _ in
            nc.post(name: AIPlatformNotification.memoryWarning, object: nil)
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: nil) { _ in
            nc.post(name: AIPlatformNotification.didEnterBackground, object: nil)
        }
    }
}

#endif
