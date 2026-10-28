//
//  VoiceInputManager.swift
//  AIModule
//
//  语音输入核心：AVAudioEngine 采集 + 实时音量（驱动波形）+ SFSpeechRecognizer 流式转文字。
//
//  设计要点：
//  1. 一份音频两用 —— 同一个 tap 里拿到的 buffer 既追加给识别请求，又算 RMS 驱动动画，
//     不像 AVAudioRecorder 那样只能写文件、音量还得轮询。这也是选 AVAudioEngine 的原因。
//  2. 优先端上识别（requiresOnDeviceRecognition）：无云端 1 分钟硬上限、不联网、隐私好；
//     模拟器不支持端上识别，故在模拟器上强制走云端，避免"能启动但永不出字"。
//  3. 停止后等识别器吐最终结果，最多等 0.8s 兜底，避免松手瞬间把已收到的文本丢掉。
//

import Foundation
import AVFoundation
import Speech
import QuartzCore
import AIPlatform
import StarryKitCore

public final class VoiceInputManager: NSObject {

    public static let shared = VoiceInputManager()

    // MARK: - 对外回调（均在主线程）

    /// 实时音量 0~1（已做平滑），约 25Hz
    public var onLevel: ((Float) -> Void)?
    /// 实时识别文本（每次回调是「截至目前的全量文本」，不是增量）
    public var onTranscript: ((String) -> Void)?
    /// 不可用或中途出错（文案已本地化，可直接展示）
    public var onError: ((String) -> Void)?
    /// 达到单次时长上限（不自动停止，由调用方决定收尾方式）
    public var onReachMaxDuration: (() -> Void)?
    /// 被系统中断（来电、其他 App 抢占音频等）
    public var onInterrupted: (() -> Void)?

    // MARK: - 状态

    public private(set) var isRecording = false
    /// 本次已识别到的文本
    public private(set) var transcript = ""
    /// 单次录音上限（秒）。云端识别约 1 分钟硬上限，端上虽无限制也统一收口，避免异常长录音
    public var maxDuration: TimeInterval = 60

    /// 是否已获得「麦克风 + 语音识别」两项授权（同步查询，用于按下前校验）
    public static var isAuthorized: Bool {
        StarryPermission.status(for: .microphone) == .authorized
            && StarryPermission.status(for: .speechRecognition) == .authorized
    }

    /// 依次请求麦克风与语音识别权限。
    /// 必须提前调用（例如「切到语音态」时）—— 系统权限框一出现会强制松开手指，
    /// 在 touchDown 里才请求会导致这一次录音必然失败。
    public static func requestPermission(completion: ((Bool) -> Void)? = nil) {
        StarryPermission.request(.microphone) { micStatus in
            guard micStatus == .authorized else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            StarryPermission.request(.speechRecognition) { speechStatus in
                DispatchQueue.main.async { completion?(speechStatus == .authorized) }
            }
        }
    }

    // MARK: - 私有属性

    private let audioEngine = AVAudioEngine()
    private lazy var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var maxDurationTimer: DispatchSourceTimer?

    /// 音频节点上是否已装 tap（removeTap 在无 tap 时会抛异常，必须自己记账）
    private var hasTap = false
    /// 本次录音的会话号：用于丢弃上一次会话迟到的识别回调
    private var sessionId = 0
    /// 停止后的收尾是否已完成（识别回调与 0.8s 兜底二选一，只生效一次）
    private var didFinishStop = true
    private var stopCompletion: ((String) -> Void)?

    private var smoothedLevel: Float = 0
    private var lastLevelEmit: CFTimeInterval = 0

    /// 首个音频 buffer 到达的时刻（0 = 还没来过）。
    /// 用途：区分「引擎起来了但采集侧没数据」与「采集正常、识别器不出字」—— 这两类故障
    /// 在界面上长得一模一样（都是"说话没反应"），但修法完全不同。见 `scheduleNoBufferWarning`。
    private var firstBufferAt: CFTimeInterval = 0

    /// 端上识别是否已经降级过一次（只降一次：反复重开识别任务会互相抢音频）
    private var didFallbackToCloud = false

    /// 端上识别「首字超时」秒数：这么久还没有任何 partial 就改用云端。
    /// ⚠️ 真机上 `supportsOnDeviceRecognition` 返回 true 只代表**设备支持**，
    ///    不代表**当前语言的端上模型已下载完** —— 那种情况下任务能建起来但**永远不出字**。
    private static let onDeviceFallbackDelay: TimeInterval = 3

    /// 诊断日志（只在 DEBUG 编译进去）。
    /// 🔴 语音链路的失败几乎全是**静默**的（不崩、不报错、只是没反应），
    ///    没有这些行，排查只能靠猜。`[VoiceInput]` 开头，控制台里直接筛。
    private func trace(_ message: @autoclosure () -> String) {
        #if DEBUG
        debugPrint("[VoiceInput] \(message())")
        #endif
    }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleInterruption(_:)),
                                               name: AIPlatform.audio.interruptionNotification,
                                               object: nil)
    }

    // MARK: - 开始录音 + 识别

    /// 开始录音并识别。返回是否成功启动。
    @discardableResult
    public func startRecording() -> Bool {
        if isRecording { return true }
        // 朗读与录音共用一份 AVAudioSession：先把朗读停掉。
        // 否则下面的 `.playAndRecord` 会把正在播的 TTS 顶掉（听感上是朗读卡死，
        // 且 UI 侧收不到回调、图标一直停在「停止」态）。
        AISpeechReader.shared.stopForRecording()
        guard Self.isAuthorized else {
            report("未获得麦克风或语音识别权限")
            return false
        }

        guard let recognizer = speechRecognizer else {
            report("当前语言暂不支持语音识别")
            return false
        }
        // 模拟器上 isAvailable 常年为 false 且不支持端上识别，放行让它自然报错，便于排查
        #if !targetEnvironment(simulator)
        if !recognizer.isAvailable && !recognizer.supportsOnDeviceRecognition {
            report("语音识别服务当前不可用，请稍后再试")
            return false
        }
        #endif

        // 1. 音频会话：playAndRecord + 扬声器，避免把外放切到听筒
        //    （配置细节在 iOS 实现里；macOS 没有会话这一层，恒成功）
        if let failure = AIPlatform.audio.activateRecord() {
            report(failure)
            return false
        }
        // 诊断：会话激活这一步有没有过（⚠️ 这里不能直接读 `AVAudioSession`：本文件是双平台共享的，
        // 会话细节只在 `AIPlatform` 的 iOS 实现里。要更细的会话状态就加接口，别在这儿 #if os）
        trace("音频会话已激活")

        // 3. 音频引擎：先装好 tap 再启动，buffer 同时喂给识别与音量计算
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        trace("inputNode 格式 ch=\(format.channelCount) sr=\(format.sampleRate)")
        guard format.channelCount > 0, format.sampleRate > 0 else {
            teardownAfterFailure()
            report("麦克风不可用，请检查设备")
            return false
        }

        sessionId += 1
        let sid = sessionId
        transcript = ""
        smoothedLevel = 0
        firstBufferAt = 0
        didFallbackToCloud = false
        didFinishStop = false
        stopCompletion = nil
        isRecording = true

        if hasTap {
            input.removeTap(onBus: 0)
            hasTap = false
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isRecording, sid == self.sessionId else { return }
            if self.firstBufferAt == 0 {
                self.firstBufferAt = CACurrentMediaTime()
                self.trace("首个音频 buffer 到达 frames=\(buffer.frameLength) sr=\(buffer.format.sampleRate)")
            }
            self.recognitionRequest?.append(buffer)
            self.emitLevel(from: buffer)
        }
        hasTap = true

        // 2+4. 识别请求 + 任务。端上识别在真机上可能「能建任务但永远不出字」
        //      （`supportsOnDeviceRecognition` 只代表设备支持，不代表模型已下载完），
        //      所以这里记下口径，后面要按它调度降级。
        let onDevice: Bool
        #if targetEnvironment(simulator)
        onDevice = false
        trace("模拟器：强制走云端识别（模拟器不支持端上识别）")
        #else
        onDevice = recognizer.supportsOnDeviceRecognition
        trace("真机：端上中文模型就绪=\(onDevice) available=\(recognizer.isAvailable)"
              + (onDevice ? "" : "（⚠️ 为 false ⇒ 只能走云端；国内云端不可用，大概率起不来识别器）"))
        #endif
        startRecognition(onDevice: onDevice)

        audioEngine.prepare()
        do {
            try audioEngine.start()
            trace("audioEngine.start() OK running=\(audioEngine.isRunning)")
        } catch {
            isRecording = false
            teardownAfterFailure()
            report("录音启动失败：\(error.localizedDescription)")
            return false
        }

        scheduleNoBufferWarning(sid: sid)
        if onDevice { scheduleOnDeviceFallback(sid: sid) }
        startMaxDurationTimer()
        return true
    }

    /// 建一份识别请求 + 任务。**抽出来是为了能原地重开**（端上识别不出字时换云端，见 `scheduleOnDeviceFallback`）。
    ///
    /// ⚠️ 重开时音频引擎和 tap **不动**：tap 往 `self.recognitionRequest` 里 append，
    ///    只换属性就能让后续 buffer 进新请求。⛔ 别把引擎也重启 —— 那会丢半秒音频并触发一次会话重配。
    private func startRecognition(onDevice: Bool) {
        guard let recognizer = speechRecognizer else { return }
        // 旧任务先收干净：同一个 recognizer 上并存两个任务会互相抢音频
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = onDevice
        recognitionRequest = request
        trace("识别请求已建 端上=\(onDevice) available=\(recognizer.isAvailable)")

        let sid = sessionId
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self, sid == self.sessionId else { return }
            // 被替换掉的旧任务的回调：忽略（否则它会把新一轮的收尾/降级判断搅乱）
            guard self.recognitionRequest === request else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                self.transcript = text
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, sid == self.sessionId else { return }
                    self.onTranscript?(text)
                }
                if result.isFinal { self.finishStop(sid: sid) }
            }
            if let error = error {
                // ⚠️ 这里以前把 error **整个吞掉**只做收尾 ⇒ 静默失败时控制台一个字都不给。
                //    收尾阶段识别器会抛 kAFAssistantErrorDomain 的取消/重试错误，那属正常噪声，
                //    所以不弹给用户，但**必须留在日志里**。
                let ns = error as NSError
                self.trace("识别 error \(ns.domain)#\(ns.code) 端上=\(onDevice) "
                           + "已有字=\(!self.transcript.isEmpty) 已降级=\(self.didFallbackToCloud)")
                // 底层原因单独打一行：`kLSRErrorDomain#300` 的**真凶**全在
                // `NSUnderlyingError` 里（例如 `Failed to create recognizer from=…/mini.json`）。
                // ⛔ 只看外层 300 分不出「模拟器资源坏了」和「端上模型没下载完」——
                //    这两件修法完全不同，只有底层那句能区分。
                if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                    self.trace("识别 error 底层 \(under.domain)#\(under.code) \(under.localizedDescription)")
                }
                // 端上报错且**一个字都没出** ⇒ 多半是端上模型没就绪，换云端再来一次
                if onDevice, self.transcript.isEmpty, !self.didFallbackToCloud {
                    self.didFallbackToCloud = true
                    self.trace("端上识别报错且无字 ⇒ 降级云端重开")
                    self.startRecognition(onDevice: false)
                    return
                }
                // 🔴 **运行中**（不是我们主动收尾）就报错、且一个字都没出 = 真故障，必须告诉用户。
                //    ⛔ 以前这里一律静默 `finishStop` ⇒ 宿主拿到空文本后提示「没听清，请再说一次」，
                //    而真实原因是识别服务压根不可用 —— 用户会一直"再说一次"，永远说不出结果。
                let isTeardownNoise = self.didFinishStop || self.stopCompletion != nil || !self.isRecording
                if !isTeardownNoise, self.transcript.isEmpty {
                    self.report(Self.describeRecognitionError(ns, onDevice: onDevice))
                    self.stopRecording(cancel: true)
                    return
                }
                self.finishStop(sid: sid)
            }
        }
    }

    /// 端上识别「首字超时」⇒ 换云端重开一次。
    ///
    /// 真机上 `supportsOnDeviceRecognition == true` 只说明**设备支持**端上识别，
    /// 不代表 `zh-CN` 的端上模型已经下载完成。模型没就绪时任务能建起来、音频也在喂，
    /// 但**永远不出字**，而且在界面上和"麦克风坏了"长得一模一样。
    /// ⇒ 3 秒一个字都没有就换云端（一次会话只降一次，见 `didFallbackToCloud`）。
    private func scheduleOnDeviceFallback(sid: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.onDeviceFallbackDelay) { [weak self] in
            guard let self, sid == self.sessionId, self.isRecording else { return }
            guard self.transcript.isEmpty, !self.didFallbackToCloud else { return }
            guard self.recognitionRequest?.requiresOnDeviceRecognition == true else { return }
            self.didFallbackToCloud = true
            self.trace("端上识别 \(Self.onDeviceFallbackDelay)s 无字 ⇒ 降级云端重开")
            self.startRecognition(onDevice: false)
        }
    }

    /// 起了引擎却一直没 buffer 的话，把话说明白 —— 这也是"说话没反应"的一大类，
    /// 但和"识别器不出字"完全是两个地方要改。
    private func scheduleNoBufferWarning(sid: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, sid == self.sessionId, self.isRecording else { return }
            guard self.firstBufferAt == 0 else { return }
            self.trace("⚠️ 2.5s 内没有任何音频 buffer ⇒ 采集侧没起来（会话/权限/格式），不是识别器的问题")
        }
    }

    // MARK: - 结束录音

    /// 结束录音并取回文本。
    /// - Parameters:
    ///   - cancel: true 表示丢弃本次结果（上滑取消 / 被中断）
    ///   - completion: 主线程回调，返回最终识别文本（cancel 时为空串）
    public func stopRecording(cancel: Bool = false, completion: ((String) -> Void)? = nil) {
        guard isRecording else {
            DispatchQueue.main.async { completion?("") }
            return
        }

        isRecording = false
        maxDurationTimer?.cancel()
        maxDurationTimer = nil

        audioEngine.stop()
        if hasTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        recognitionRequest?.endAudio()

        guard !cancel else {
            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            transcript = ""
            didFinishStop = true
            deactivateSession()
            DispatchQueue.main.async { completion?("") }
            return
        }

        // 正常结束：等识别器吐最终结果，最多 0.8s 兜底
        let sid = sessionId
        didFinishStop = false
        stopCompletion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.finishStop(sid: sid)
        }
    }

    /// 收尾（识别回调与 0.8s 兜底都会调，只会真正执行一次）
    private func finishStop(sid: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, sid == self.sessionId, !self.didFinishStop else { return }
            self.didFinishStop = true
            let text = self.transcript
            self.recognitionTask?.cancel()
            self.recognitionTask = nil
            self.recognitionRequest = nil
            self.deactivateSession()
            let done = self.stopCompletion
            self.stopCompletion = nil
            done?(text)
        }
    }

    // MARK: - 音量

    /// 从 PCM buffer 算音量：RMS → dBFS → 归一化 → 上升快回落慢的平滑
    private func emitLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sum: Float = 0
        for i in 0..<frames {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = sqrtf(sum / Float(frames))
        // dBFS：静音约 -140，正常说话 -30 ~ -10
        let db = 20 * log10f(max(rms, 1e-7))
        // -50dB 记 0，-10dB 记 1
        let normalized = min(max((db + 50) / 40, 0), 1)
        // 不做平滑每帧跳变会让波形抽搐
        smoothedLevel = normalized > smoothedLevel
            ? smoothedLevel * 0.3 + normalized * 0.7
            : smoothedLevel * 0.8 + normalized * 0.2

        let now = CACurrentMediaTime()
        guard now - lastLevelEmit >= 1.0 / 25.0 else { return }
        lastLevelEmit = now
        let level = smoothedLevel
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onLevel?(level)
        }
    }

    // MARK: - 计时 / 中断

    private func startMaxDurationTimer() {
        maxDurationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + maxDuration)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isRecording else { return }
            self.onReachMaxDuration?()
        }
        timer.resume()
        maxDurationTimer = timer
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard AIPlatform.audio.isInterruptionBegan(note), isRecording else { return }
        stopRecording(cancel: true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onInterrupted?()
        }
    }

    // MARK: - 收尾工具

    private func deactivateSession() {
        AIPlatform.audio.deactivate()
    }

    /// 启动失败时的回滚
    private func teardownAfterFailure() {
        audioEngine.stop()
        if hasTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasTap = false
        }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
        didFinishStop = true
        stopCompletion = nil
        deactivateSession()
    }

    private func report(_ message: String) {
        trace(message)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onError?(message)
        }
    }

    /// 把识别器的错误翻成**用户能照着做**的话。
    ///
    /// 🔴 两类错误值得单独说：
    /// - `kAFAssistantErrorDomain` 的 1101 / 1107 / 1110 —— 「识别服务不可用」；
    /// - `kLSRErrorDomain` 的 300 —— `Failed to initialize recognizer`，识别器**根本起不来**。
    ///
    /// ## ☠️ 300 在**模拟器**上几乎必然出现，跟 App 代码和听写设置都无关
    /// 2026-10-26 实测（iOS 27.0 模拟器）：音频会话已激活、`inputNode` 48kHz、
    /// `audioEngine.start()` 成功、首个 buffer 到达 —— 采集全程正常，唯独识别器建不出来。
    /// 同指纹（`UserInfo` 里的 `NSUnderlyingError` = `Failed to create recognizer from=…/`
    /// `com_apple_MobileAsset_UAF_Siri_Understanding/…/mini.json`）在 Apple 开发者论坛
    /// 有同期报告，关键词是「SFSpeechRecognizer is unavailable or fails to initialize on
    /// iOS 26.4 and 26.5 Simulators」，且报告者确认 **26.2 及更早没有**。
    /// ⇒ 这是**模拟器侧的资源损坏**，不是我们能在 App 里修的。
    /// ⛔ 所以模拟器上**不能**给「去设置开听写」这种建议：模拟器的听写继承自 Mac，
    ///    用户照着做只会白忙（真实反馈就是这么来的：用户开了普通话，仍然 300）。
    ///
    /// ## 真机上 300 的含义
    /// 真机 300 基本等于「zh-CN 的**端上**模型没就绪」，而此时云端识别在国内不可用，
    /// 于是两条路都断。文案必须指向「确认普通话已下载完」这个唯一可行动作。
    /// ⛔ 别甩一句原始英文 —— 用户照着做不了任何事。
    private static func describeRecognitionError(_ error: NSError, onDevice: Bool) -> String {
        if error.domain == "kAFAssistantErrorDomain" {
            switch error.code {
            case 1101, 1107, 1110:
                return "语音识别服务暂时不可用，请稍后重试"
            default:
                break
            }
        }
        if error.domain == "kLSRErrorDomain" {
            #if targetEnvironment(simulator)
            return "模拟器无法使用语音识别（iOS 26.4+ 模拟器已知问题），请用真机测试"
            #else
            return "语音识别初始化失败：本机的中文离线识别模型没就绪。"
                + "请到「设置 › 通用 › 键盘 › 听写」确认「普通话」已下载完再回来"
            #endif
        }
        if !onDevice {
            return "语音识别不可用（云端识别连不上，且本机没有离线模型）：\(error.localizedDescription)"
        }
        return "语音识别出错：\(error.localizedDescription)"
    }
}
