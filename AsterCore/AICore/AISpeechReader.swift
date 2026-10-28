//
//  AISpeechReader.swift
//  AIModule
//
//  语音朗读（TTS）核心：`AVSpeechSynthesizer` 封装。
//
//  设计要点：
//  1. **音频会话必须是 `.playback` + `.spokenAudio`**。用 `.ambient`/`.soloAmbient` 时
//     用户开着静音开关就**一点声音都没有**——这是「代码没报错但听不见」的头号原因。
//     另加 `.duckOthers`：正在放的音乐压低音量而不是被掐断。
//     🔴 2026-10-11：会话配置改在 `AIPlatform.audio.activatePlayback()` 里**先读实际状态再决定要不要重配**
//     （紧挨着朗读做一次 `setCategory` 会被听成打嗝，社区实测）。
//  2. **与 `VoiceInputManager` 抢同一份 `AVAudioSession`**：它录音用 `.playAndRecord`、
//     这里朗读要 `.playback`，一个 App 只有一份 session，两者必须错开。按下说话前由
//     `VoiceInputManager.startRecording()` 主动调 `stopForRecording()`，反过来宿主在开始朗读前
//     先结束录音（见 `AIModuleViewController.toggleSpeech`）。
//  3. **收尾幂等**：`didFinish` 与 `didCancel` **都会**回调。用 `managed` 集合记账「这条 utterance
//     还算不算本轮」，主动 `stop()` 时先清空集合，迟到的回调就不会重复报结束。
//  4. **必须强引用**：单例持有 synthesizer。写成局部变量会在读完前释放，表现为「只念半句」或完全无声。
//  5. 🔴 **切段口径：能塞一条就绝不切两条**（2026-10-11 整条改掉）。
//     `AVSpeechSynthesizer` 把**每一条 utterance** 当成独立的一次「合成 + 播放」，
//     两条之间是一次真实的音频重启动 —— `tts_trace.log` 实测**每处边界静默 ≈300ms**，
//     且与文本长短无关（就是重启动成本）。老口径按行切，AI 的 Markdown 回复（标题一行、
//     每个列表项一行、代码块每行一行）**一条回复被切成 8~15 条** ⇒ 一次回复里打嗝 8~15 次，
//     用户听到的就是「断断续续、特别频繁」。详见 `speechUnits(from:)`。
//     ☠️ 也别再加 `postUtteranceDelay`：那是在每处边界上人为再加一段静默。
//  6. ☠️☠️ **delegate 上不许实现 `willSpeakRangeOfSpeechString`**（2026-10-11 移除）。
//     这个可选方法**只在真机**上会把词念成静音（时间轴上留出正确长度的空白），模拟器复现不出来；
//     用户听到的就是「读几个字、丢几个字」。它原先只为探针的逐字范围存在，收益为零 ⇒ 已删。
//     详见 `extension AISpeechReader: AVSpeechSynthesizerDelegate` 里 `#if DEBUG` 那段。
//

import Foundation
import AVFoundation
import AIPlatform

/// ⚠️ 本类被 App 侧的 `AIModuleViewController` / `+RowAction` / `AIVoiceCallViewController`
/// 以及 Mac 的 `ChatModel` 直接使用（朗读按钮 + 「读完」回调），所以**类型与那几个成员
/// 必须是 public** —— 它从「与 UI 同模块」搬进 `AICore` 后，internal 就跨不过模块边界了。
public final class AISpeechReader: NSObject {

    public static let shared = AISpeechReader()

    /// 「读完」回调的注册凭据（`addFinishHandler` 的返回值，拿它去注销）
    public typealias FinishToken = UUID

    /// ### 🔴 为什么是**多播**而不是一个 `onFinish: (() -> Void)?`（2026-10-11 改）
    /// 「这一轮自然读完」有**两个互不相干的消费者**：
    /// 1. 会话页（iOS）/ `ChatModel`（Mac）—— 把那一行的朗读图标复位；
    /// 2. **通话页** —— 读完要**自动开麦**接下一轮（打电话的形态）。
    /// 单槽位属性是「谁后写谁生效」，后者会把前者**静默挤掉**（不报错，只是图标不复位）。
    /// ⇒ 改成一张 `token → handler` 的表：各自注册、各自注销，互不干扰。
    private var finishHandlers: [FinishToken: () -> Void] = [:]

    /// 注册一个「这一轮**自然读完**（或被系统打断）」回调，主线程调用。
    /// - Note: 主动 `stop()` / `stopForRecording()` **不会**触发——调用方自己知道是它停的。
    ///   否则「切到另一行朗读」时，内部先停旧的会误报一次结束，把新行刚设好的状态清掉。
    /// - Important: 返回的 token 要留着，不需要时用 `removeFinishHandler` 注销。
    @discardableResult
    public func addFinishHandler(_ handler: @escaping () -> Void) -> FinishToken {
        let token = UUID()
        finishHandlers[token] = handler
        return token
    }

    /// 注销一个「读完」回调（token 不认识时安全，什么都不做）
    public func removeFinishHandler(_ token: FinishToken) {
        finishHandlers[token] = nil
    }

    /// 是否正在朗读
    public private(set) var isSpeaking = false

    /// 语速，范围 0~1（`AVSpeechUtteranceDefaultSpeechRate` = 0.5）。
    /// 给后续「设置页语速滑条」留的出口，暂未接 UI。
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    private let synthesizer = AVSpeechSynthesizer()

    /// 本轮纳入管理的 utterance：主动 stop 时清空，迟到的 didCancel/didFinish 便不会重复收尾
    private var managed = Set<ObjectIdentifier>()

    #if DEBUG
    /// 🧪 节奏探针的状态（见文件末尾那段说明）。Release 包里这些字段**根本不存在**。
    private var traceOrder: [ObjectIdentifier: Int] = [:]
    private var traceStart: CFTimeInterval = 0
    private var traceSpans: [Int: (start: CFTimeInterval, end: CFTimeInterval)] = [:]
    private var traceUnitCount = 0
    #endif

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - 读 / 停

    /// 朗读一段文本。重复调用会先停掉上一段（切换朗读目标走这条）。
    public func speak(_ text: String) {
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return }
        // 先停旧的。⚠️ 这里**只停合成器、不关音频会话** —— 关了紧接着又开，
        //    等于白挨一次会话重配置（那本身就是一次可听的打嗝）。真正的收尾在 `stop()`。
        haltSpeaking()

        guard activateSession() else { return }

        isSpeaking = true
        managed.removeAll()
        // 取一次就够：同一轮的所有 utterance 共用同一个音色对象
        let voice = Self.resolvedVoice
        let units = Self.speechUnits(from: plain)
        #if DEBUG
        // 🔎 复现「读几个字丢几个字」时**先看这一行**：音色档位（`compact`/`enhanced`/`premium`）
        //    + 切了几条 + 字数。三样一起才能排除「是不是某个高音质音色自己的毛病」。
        //    ⚠️ 必须用 `NSLog` 而不是 `print`：真机上只有 NSLog/os_log 会进 Xcode 控制台，
        //    这样用户**不用改一行代码**就能在复现的当下把现场贴出来。
        NSLog("[TTS] speak voice=%@ units=%d chars=%d",
              Self.currentVoiceDescription, units.count, plain.count)
        let tracing = Self.traceEnabled
        if tracing { openTrace(charCount: plain.count, units: units) }
        #endif
        for (index, piece) in units.enumerated() {
            let utterance = AVSpeechUtterance(string: piece)
            utterance.voice = voice
            utterance.rate = rate
            // ☠️ 别写 `postUtteranceDelay`：默认 0 就是对的。
            //    它的作用是**在每处 utterance 边界上再加一段静默**，
            //    而「断断续续」的成因正是边界本身 —— 再加一段等于把病灶调大。
            //    （段落感由块内的换行交给引擎自己处理，不靠这里补。）
            managed.insert(ObjectIdentifier(utterance))
            #if DEBUG
            if tracing { traceOrder[ObjectIdentifier(utterance)] = index }
            #endif
            synthesizer.speak(utterance)
        }
    }

    /// 停止朗读（未在朗读时什么都不做，也不发状态回调）
    ///
    /// ⚠️ `guard isSpeaking` 不能省，而且**必须连音频会话一起不动**：
    ///    `VoiceInputManager.startRecording()` 开头就调 `stopForRecording()`（那时通常没在念），
    ///    若无脑 `deactivateSession()`，录音启动就变成「关会话 → 开会话」白折腾一次 ——
    ///    正是本轮要消掉的那类抖动。（`haltSpeaking()` 内部已有同样的 guard，这里是显式的。）
    public func stop() {
        guard isSpeaking else { return }
        haltSpeaking()
        deactivateSession()
    }

    /// 停掉当前合成，但**不碰音频会话**。
    /// - Note: `speak()` 换朗读目标时用它（免得 deactivate → activate 白折腾一轮）；
    ///   `stop()` / `stopForRecording()` 会在它之后**主动关会话**，把音频交还系统。
    private func haltSpeaking() {
        guard isSpeaking else { return }
        isSpeaking = false
        managed.removeAll()                          // 先清账：随后到达的 didCancel 视为过期
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// 被录音抢占时调用（语义同 `stop()`，命名上标明场景）
    func stopForRecording() {
        stop()
    }

    // MARK: - 收尾（delegate 回调入口）

    /// 一条 utterance 结束：全部结束才算这一轮读完。
    private func finish(_ utterance: AVSpeechUtterance) {
        guard managed.remove(ObjectIdentifier(utterance)) != nil else { return }
        #if DEBUG
        traceEnd(utterance)
        #endif
        guard managed.isEmpty, isSpeaking else { return }
        isSpeaking = false
        deactivateSession()
        // ⚠️ 先快照再遍历：handler 内部很可能顺手注销自己（改的就是这张表），
        //    直接遍历字典属于"边遍历边改"，是雷。
        let handlers = Array(finishHandlers.values)
        handlers.forEach { $0() }
        #if DEBUG
        closeTrace()
        #endif
    }

    // MARK: - 音频会话

    /// 激活会话。失败时返回 false（不出声但不崩），调用方直接放弃这一轮朗读。
    ///
    /// - Note: 会话配置（`.playback` + `.spokenAudio` + `.duckOthers`）搬进了
    ///   `AIPlatform.audio.activatePlayback()` —— macOS **根本没有音频会话这一层**，
    ///   那边是 no-op 直接返回 true。参数留在 iOS 实现里，这里只说「我要播放」。
    @discardableResult
    private func activateSession() -> Bool {
        AIPlatform.audio.activatePlayback()
    }

    private func deactivateSession() {
        AIPlatform.audio.deactivate()
    }

    // MARK: - 文本与音色

    /// 切分朗读单元：**能塞一条就绝不切两条**（本条口径是 2026-10-11 用探针量出来的，见文件头 5）。
    ///
    /// ## 为什么不是「按行切」（老口径）
    /// `AVSpeechSynthesizer` 把**每一条** utterance 当作一次独立的「合成 + 播放」，
    /// 两条之间是一次真实的音频重启动。用 `tts_trace.log`（`STARRY_TTS_TRACE=1`）量到的数字：
    /// 一条 233 字的普通 Markdown 回复按行切出 **10 条**，**9 处边界**，
    /// **每处静默 300ms**（`gapAvg=300ms gapMax=304ms`，九处几乎一模一样 —— 它就是重启动成本，
    /// 与文本长短无关）。整轮 53.9s 里有 **2.7s 是死气**，平均每 5 秒打一次嗝。
    ///
    /// ## 现在怎么切
    /// 1. **按「块」累积**：`softLimit` 之内的行全部并进同一条；换行**保留在块内**
    ///    （引擎自己在换行处给自然停顿 ⇒ 段落感不丢，但**不产生边界**）。
    /// 2. 只有**单行**自己就超限时，才在句末标点处切开 —— 长文才会走到，且数量极少。
    /// 3. `softLimit = 600` ⇒ **一条正常回复恒为 1 条 utterance ⇒ 边界 0 个**。
    ///
    /// ⚠️ 别再为了「减小首字延迟」往回切：实测**首字延迟只有 101ms**（`tts_trace.log` 的
    /// `firstWord`），整篇一条并不慢；而每多切一条就多 300ms 静默，那是净亏。
    private static func speechUnits(from text: String, softLimit: Int = 600) -> [String] {
        var units: [String] = []
        var current: [String] = []
        var currentCount = 0

        func flush() {
            guard !current.isEmpty else { return }
            units.append(current.joined(separator: "\n"))
            current.removeAll()
            currentCount = 0
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // 单行自己就超限（无换行的长段落）：先结算手上这块，再把它单独按句切开
            if trimmed.count > softLimit {
                flush()
                units.append(contentsOf: splitSentences(trimmed, limit: softLimit))
                continue
            }
            // 塞不下了：结算，另起一块
            if currentCount > 0 && currentCount + trimmed.count > softLimit { flush() }
            current.append(trimmed)
            currentCount += trimmed.count
        }
        flush()
        return units
    }

    /// 超长单行按句末标点切（一路没有句末标点就按硬上限兜底切）。
    /// - Note: 只有「单行 > softLimit」的长文才会走到这里，正常回复不走。
    private static func splitSentences(_ line: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for ch in line {
            current.append(ch)
            if "。！？；!?;".contains(ch), current.count >= limit / 2 {
                pieces.append(current)
                current = ""
            } else if current.count >= limit * 2 {
                pieces.append(current)   // 兜底：整篇没有句末标点（极少见）
                current = ""
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: - 音色挑选

    /// 当前生效的音色缓存。
    ///
    /// 规则：**优先中文里质量最好的一档**（premium > enhanced > compact）。
    /// 用户可能在 设置 › 辅助功能 › 朗读内容 › 声音 里下载过增强 / 高级音色，
    /// 有就用（听感和预装的 compact 完全是两回事），没有自然回落到 compact。
    ///
    /// ⚠️ **第三方 App 没有下载音色的 API**——`speechVoices()` 只返回设备上**已经装好的**那几个。
    /// 所以「声音很机械」的根因通常是设备上没人下载过高音质音色（预装的中文只有 compact），
    /// 只能引导用户去系统设置里下，代码这边挑得再好也变不出来。
    ///
    /// 缓存策略：拿到 enhanced/premium 就长期缓存（`speechVoices()` 要问系统要全量列表，
    /// 不该每条 utterance 都调）；拿到的还是 compact 则**每次都重新查**——这样用户在 App 运行期间
    /// 去系统里下了新音色，下一次朗读自动就用上，不必杀掉进程重开。
    private static var cachedVoice: AVSpeechSynthesisVoice?

    static var resolvedVoice: AVSpeechSynthesisVoice? {
        if let cached = cachedVoice, cached.quality != .default { return cached }
        let picked = pickBestVoice()
        cachedVoice = picked
        return picked
    }

    /// 强制重挑一次（设置页「刷新音色」、或从后台回前台时调用）
    @discardableResult
    static func refreshVoice() -> AVSpeechSynthesisVoice? {
        cachedVoice = nil
        return resolvedVoice
    }

    /// 当前音色的「名字 · 档位」。排查「为什么听着机械」时先看这个——
    /// 显示 `compact` 就说明设备上还没有高音质中文音色。
    static var currentVoiceDescription: String {
        guard let voice = resolvedVoice else { return "未找到中文音色" }
        let tier: String
        if #available(iOS 16.0, *), voice.quality == .premium {
            tier = "premium"
        } else if voice.quality == .enhanced {
            tier = "enhanced"
        } else {
            tier = "compact"
        }
        return "\(voice.name) · \(tier)"
    }

    /// 挑音色：先只在 `zh-CN` 里挑（同档位下别选到 zh-HK / zh-TW 的腔调），没有再放宽到所有中文。
    private static func pickBestVoice() -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices()
        let groups = [all.filter { $0.language == "zh-CN" },
                      all.filter { $0.language.hasPrefix("zh") }]
        for group in groups {
            if #available(iOS 16.0, *), let premium = group.first(where: { $0.quality == .premium }) {
                return premium
            }
            if let enhanced = group.first(where: { $0.quality == .enhanced }) {
                return enhanced
            }
        }
        return AVSpeechSynthesisVoice(language: "zh-CN")
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AISpeechReader: AVSpeechSynthesizerDelegate {

    // ⚠️ 类改成 public 之后，这两个协议实现也**必须** public：
    // 它们匹配的是 public 协议 `AVSpeechSynthesizerDelegate` 的要求，
    // 留成 internal 会报 "must be declared public because it matches a requirement"。
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish(utterance)
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish(utterance)
    }

    #if DEBUG
    // ⚠️ `didStart` 是协议的**可选**方法（不是 requirement），所以它**不能**也没必要写 `public`。
    //    写成 public 过不了类型检查。
    //
    // ☠️☠️ **绝对不要在这个共享单例上实现 `willSpeakRangeOfSpeechString`**（2026-10-11 实测后移除）。
    //    Apple 开发者论坛有真机复现帖：**只要实现了这个方法，真机上就会出现「词被静音、
    //    但在时间轴上留出正确长度的空白」** —— 原文 *"the second word is silent ... like there
    //    seems to be the correct space left for it"*，并且 *"No problem in the simulator -
    //    this is a device only problem"*（模拟器复现不出来）。用户听到的就是
    //    「读几个字、丢几个字、还特别频繁」。
    //    🔴 本工程之所以中招：它当初**只是为了探针的「逐字范围」**才实现，而那个问题
    //    （块内换行还有没有停顿）**早已量完**（结论：换行处与别的范围语速无差别）。
    //    ⇒ 留着一个「只在真机放毒、收益为零」的 delegate 方法是纯负债，直接摘掉。
    //    ⚠️ 将来若又想看逐字范围：用一台**单独的** `AVSpeechSynthesizer` 实例去量（探针专用），
    //    ⛔ 千万别把方法挂回这里的 delegate。
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        traceBegin(utterance)
    }
    #endif
}

#if DEBUG
// MARK: - 🧪 朗读节奏探针（仅 DEBUG 编译进去）
//
//  ## 它解决什么问题
//  「读起来断断续续」是**听感**问题：截图看不见、grep 契约也 grep 不出来。
//  但它有一个可量化的等价物 —— **每条 utterance 边界上的静默时长**。
//  `AVSpeechSynthesizer` 把**每一条** utterance 当成独立的一次「合成 + 播放」，
//  两条之间就是一次真实的音频重启动。段数（= 回复被切成几条）越多，
//  用户听到的「断断续续」就越频繁。这个探针把边界静默**量出来**，
//  于是「切段是不是元凶」从争论变成一个数字。
//
//  ## 怎么开
//    STARRY_TTS_TRACE=1          开启；默认夹具 = 一段典型 Markdown 回复（`traceFixture`）
//    App 侧触发口：`AIModuleViewController` 启动钩子 → `runSpeechTraceIfRequested()`（+RowAction.swift）
//
//  ☠️ 曾经还有一档 `STARRY_TTS_TRACE_RANGE=1`（逐字范围），2026-10-11 **整档删除**：
//     它要实现的 `willSpeakRangeOfSpeechString` 会在**真机上**让词变静音（只留正确长度的空白），
//     而它当初要回答的问题（块内换行还有没有停顿）早就量完了。
//     详见 `AVSpeechSynthesizerDelegate` 那一段里 `#if DEBUG` 处的注释。
//
//  ## 产物
//    `<App 容器>/Documents/tts_trace.log`（追加，每轮一段）。取回：
//      xcrun simctl get_app_container <udid> com.github.suzhibin.Aster data
//
//  ⚠️ 必须 `#if DEBUG`：Release 包里不能有「凭空开始一次朗读」的脚手架。
extension AISpeechReader {

    /// 是否开启节奏探针
    static var traceEnabled: Bool {
        ProcessInfo.processInfo.environment["STARRY_TTS_TRACE"] == "1"
    }

    /// 默认夹具：**形状照抄 `mock_sse_server.py` 的 `MARKDOWN`**（标题 + 段落 + 三条列表 + 代码块）。
    /// 不是随便挑的：老口径**按行切段**，「文本里有多少行」直接等于「会切出多少次边界」，
    /// 只有用真实形状量出来的段数才有意义。
    static let traceFixture = """
    # iOS 下载管理模块设计

    这是一个**模块化**的下载管理系统，核心思路如下：

    - 下载核心与 UI 层分离，便于复用
    - BDownloadOperation 只负责下载 / 暂停 / 取消基础动作
    - BDownloadManager 集中编排业务逻辑

    ```swift
    let task = GlobalDownloadRegistry.shared.add(url)
    task.resume()
    ```

    以上即为当前架构要点，后续可接入真实模型。
    """

    /// 触发一次探针（App 侧启动钩子调它；未开 `STARRY_TTS_TRACE=1` 时是空操作）
    ///
    /// ⚠️ 经过 `AIMarkdown.plainText` —— 真实链路（`speechText(atRow:)`）就是先脱 Markdown 再 `speak`。
    ///    不脱的话探针量的是**另一段文本**（`**`/`#`/代码围栏都在），段数结论会失真。
    ///
    /// ⚠️ 必须 `public`：它在 `AICore` 模块里，而调用方 `AIModuleViewController` 在 App 模块 ——
    ///    `internal` 跨不过模块边界（这条是**开 `-D DEBUG` 类型检查后当场抓到的**，
    ///    在此之前整段 `#if DEBUG` 代码从来没被类型检查覆盖过）。
    public func runTraceProbe() {
        guard Self.traceEnabled else { return }
        speak(AIMarkdown.plainText(from: Self.traceFixture))
    }

    // MARK: 记账

    func openTrace(charCount: Int, units: [String]) {
        traceStart = CACurrentMediaTime()
        traceOrder.removeAll()
        traceSpans.removeAll()
        traceUnitCount = units.count
        write("--- TRACE chars=\(charCount) units=\(units.count) lens=\(units.map(\.count))")
    }

    func traceBegin(_ utterance: AVSpeechUtterance) {
        guard Self.traceEnabled, let index = traceOrder[ObjectIdentifier(utterance)] else { return }
        let t = CACurrentMediaTime() - traceStart
        traceSpans[index, default: (0, 0)].start = t
        write("START #\(index) t=\(Self.ms(t))")
    }

    func traceEnd(_ utterance: AVSpeechUtterance) {
        guard Self.traceEnabled, let index = traceOrder[ObjectIdentifier(utterance)] else { return }
        let t = CACurrentMediaTime() - traceStart
        traceSpans[index, default: (0, 0)].end = t
        write("END   #\(index) t=\(Self.ms(t))")
    }

    /// 本轮读完 → 结算：首字延迟 + 每个边界的静默时长
    func closeTrace() {
        guard Self.traceEnabled else { return }
        let indices = traceSpans.keys.sorted()
        guard let first = indices.first, let last = indices.last,
              let firstSpan = traceSpans[first], let lastSpan = traceSpans[last] else { return }
        // 边界静默 = 前一条 `END` 到后一条 `START`（引擎重启动的那段空档）
        var gaps: [Double] = []
        for (a, b) in zip(indices, indices.dropFirst()) {
            guard let spanA = traceSpans[a], let spanB = traceSpans[b] else { continue }
            gaps.append(spanB.start - spanA.end)
        }
        let avg = gaps.isEmpty ? 0 : gaps.reduce(0, +) / Double(gaps.count)
        let maxGap = gaps.max() ?? 0
        write("SUMMARY units=\(traceUnitCount) firstWord=\(Self.ms(firstSpan.start))"
              + " total=\(Self.ms(lastSpan.end)) boundaries=\(gaps.count)"
              + " gapAvg=\(Self.ms(avg)) gapMax=\(Self.ms(maxGap))"
              + " gaps=[\(gaps.map { Self.ms($0) }.joined(separator: ","))]")
        write("")
        NSLog("[TTS-TRACE] units=%d firstWord=%@ gapAvg=%@ gapMax=%@",
              traceUnitCount, Self.ms(firstSpan.start), Self.ms(avg), Self.ms(maxGap))
    }

    // MARK: 落盘

    private func write(_ line: String) {
        let url = AIPlatformPaths.appDataDirectory.appendingPathComponent("tts_trace.log")
        let text = line + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func ms(_ seconds: Double) -> String {
        String(format: "%.0fms", seconds * 1000)
    }
}
#endif
