//
//  MacVoiceCallModel.swift
//  AsterMac
//
//  「打电话」窗口的状态机（2026-10-12）。窗口内容视图只读它、只调它。
//
//  ## 一句话流程
//  开窗 → 开麦 → 说话（实时字幕 + 三点随音量跳）→ **尾静音自动断句** → 发一条消息给 AI
//  → 切「正在思考…」→ 回复到了**念出来** → 念完**自动重新开麦**（下一轮）。
//  ⇒ 前半段（听 → 断句 → 发）与后半段（收 → 念 → 再听）是一个闭环，中间只经过
//    `ChatModel`（说的每一句都落进会话页，回会话页能看到完整对话）。
//
//  ## 🔴 它**不持有会话**
//  发送走 `ChatModel.sendFromVoiceCall`，回复从 `ChatModel` 转发的回调里取。
//  ⛔ 别在这里 new 一个 `AIChatManager` —— 那是两份记录，与 iOS 侧「通话页不持有 manager」
//     是同一条铁律（那边的成因写在 `AIModuleViewController+Voice.swift`）。
//
//  ## 🔴 `isMuted` 是**独立开关**，不是状态机的一档
//  第一版把它做成 `Phase.muted`，立刻出问题：AI 回复到达时要切 `.speaking`，
//  那一刀下去"静音"这件事就丢了 —— 念完之后会**擅自把麦打开**。
//  正确模型是：`phase`（我现在在干什么）+ `isMuted`（我的麦关没关）两个正交量。
//
//  ## 🔴 与 iOS 通话页的三处刻意差异
//  ① **交互**：Mac 是 `⌥+E` 按住临时开麦（参考图上那句「按住 ⌥+E 可以暂时打开麦克风」），
//     不是 iOS 那种"点一下切态再点屏打断"。麦克风那颗钮仍是"开关我的麦"。
//  ② **没有"点屏幕打断"**：Mac 上打断朗读 = 点麦克风从静音恢复（那一刻先停朗读，
//     因为录音与朗读抢同一份音频，见下）。
//  ③ **没有拍照那颗**：参考图第一颗是摄像头，功能没做 ⇒ 置灰摆设（与 iOS 那颗**不同**，
//     那边已经改成「拍照提问」了；Mac 这一版不做图，别照抄）。
//
//  ## ☠️ 录音与朗读抢同一份音频
//  `VoiceInputManager.startRecording()` 内部会先 `AISpeechReader.stopForRecording()`
//  （共享层已兜底），但那次停**不发「读完」回调** ⇒ 我们自己的状态机会停在 `.speaking`。
//  ⇒ 凡是"要开麦"的入口，都必须**先自己**把朗读收尾（`interruptSpeech()`），
//    别指望共享层那一刀（它只保证音频不出错，不保证我们的状态对）。
//
//  ## ⚠️ 为什么用 `ObservableObject` 而不是 `@Observable`
//  与 `FolderTreePane` / `WebPageModel` 同一条理由：本工程的验收台（typecheck 脚本、
//  渲染台）**完全不能展开宏**（`swift-plugin-server` 在沙箱里必失败），每加一个
//  `@Observable` 都要去脚本里手工补一致代码。⛔ 别改回 `@Observable`。
//  ⚠️ 代价是"整窗重建"而不是细粒度刷新：`level` 以 25Hz 变 ⇒ `objectWillChange` 也
//     25Hz。这个窗口只有两行字 + 四颗钮，实测无压力；真嫌费就把 `level` 单独拆出去。
//

import AppKit
import Combine
import Foundation
import AICore

@MainActor
final class MacVoiceCallModel: ObservableObject {

    /// 当前在干什么。
    /// ⚠️ **不含"静音"** —— 那是 `isMuted`（见文件头那段）。
    enum Phase: Equatable {
        /// 没在听（刚开窗还没开麦 / 静音中 / 出错后停下）
        case idle
        /// 拾音中（三点在跳、说完整句由尾静音自动收）
        case listening
        /// 已经发出去了、在等回复
        case thinking
        /// 正在朗读回复
        case speaking
    }

    // MARK: - 状态（视图只读）
    //
    // ⚠️ 全部 `@Published`：`ObservableObject` 没有细粒度跟踪，视图靠它的
    //    `objectWillChange` 重算 —— 漏一个就会"界面卡住不动"（而且不报错）。

    @Published private(set) var phase: Phase = .idle

    /// 目标音量 0~1（喂给三点）
    @Published private(set) var level: Double = 0

    /// 实时识别文本（**全量**，不是增量）—— 拾音中顶替状态行显示
    @Published private(set) var transcript: String = ""

    /// 我的麦关着（参考图第 2 张那一态）
    @Published private(set) var isMuted = false

    /// 静音态下按住 ⌥+E 临时开麦中（松手要还回去）
    @Published private(set) var isPushToTalking = false

    /// 状态行下方临时的一句话（比如「没听清，请再说一次」）。`nil` = 不显示。
    @Published private(set) var notice: String?

    /// 🧪 验收钩子给白球钉住的振幅（0~1）。`nil` = 用合成包络。
    /// ⚠️ 只在 DEBUG 钩子里赋值（`STARRY_CALL_BALL`），生产路径恒为 nil。
    private(set) var forcedBallLevel: Double?

    /// 🧪 验收钩子把"AI 在说"这一档**强制**立起来（只影响白球，不改 `phase`、不改文案）。
    private(set) var ballVoiceForced = false

    /// 当前该显示的主状态文案（视图直接用它，别再自己拼一遍）
    var statusText: String {
        if isMuted { return L("已静音") }
        switch phase {
        case .idle:      return L("请开始说话")
        case .listening: return transcript.isEmpty ? L("请开始说话") : transcript
        case .thinking:  return L("正在思考…")
        case .speaking:  return L("正在回答…")
        }
    }

    /// 副行（只有静音态才有 —— 参考图第 2 张那句）
    ///
    /// ⚠️ 文案**照抄参考图**：`⌥+E` 外面是**中文书名号**（不是空格）。
    ///    这是用户给的那张图上的原文，⛔ 别"顺手统一"成半角括号 —— 对不上图就是没照做。
    var hintText: String? {
        guard isMuted else { return nil }
        return L("按住「⌥+E」可以暂时打开麦克风")
    }

    /// 三点要不要跑动画：只在**拾音中**（安静时三点必须是静止的等大圆点）
    var isDotsActive: Bool { phase == .listening }

    /// 中央那颗白球要不要"随 AI 声音"起伏。
    ///
    /// 🔴 只有 **`.speaking`** —— 与三点是**分工**关系，不是同一条线的两档：
    ///    三点 = "我在听你说"（`.listening`），白球 = "AI 在说"（`.speaking`）。
    ///    ⛔ 别顺手也接到 `.listening` 上：那样两个指示器会同时动，用户分不出现在轮到谁
    ///    （与 iOS `AIVoiceCallViewController.apply(state:)` 那条铁律逐字同源）。
    /// ℹ️ 验收钩子 `STARRY_CALL_BALL` 会把它**强制**置真（只驱动球这一层，不动状态机）。
    var isVoiceActive: Bool { ballVoiceForced || phase == .speaking }

    // MARK: - 依赖

    /// 会话模型（发送 + 回复回调都从它走）。窗口与它**共用同一份** ⇒ 对话落在同一个会话里。
    private let chatModel: ChatModel

    // MARK: - 内部

    /// 尾静音阈值（秒）。与 iOS 通话页同值。
    ///
    /// 🔴 太短会把「换气」当成说完（一句话被劈成两段发出去）；太长则每轮都要干等。
    /// 1.5s 是 iOS 那边实测挑出来的，两端保持同值（用户对"反应快慢"的感受是跨端一致的）。
    private static let silenceThreshold: TimeInterval = 1.5

    /// 每 0.25s 看一次（判定本身很便宜，不必挂 25Hz 的音量回调上）
    private static let silenceTick: TimeInterval = 0.25

    /// 临时提示显示多久。
    ///
    /// 🔴 与 iOS 的 `AIToast.duration` **同值**（2026-10-26 用户反馈「报错的吐司看不清楚」
    ///    ⇒ 两端一起由 2.2 提到 4.2）。这里不能读 iOS 的常量（跨端不同 target），
    ///    所以靠这条注释绑定：**改一边就改另一边**。
    private static let noticeDuration: TimeInterval = 4.2

    // ⚠️ 下面这四个**不加 `@Published`**：它们是纯内部记账，变了不需要重画界面
    //    （`@Published` 会让 `objectWillChange` 在 25Hz 的音量回调里再叠一层）。
    private var silenceTimer: Timer?
    private var noticeTask: Task<Void, Never>?
    /// 最后一次「识别文本有更新」的时刻（尾静音判定的唯一依据）
    private var lastTranscriptAt = Date.distantPast
    /// 朗读「自然读完」的注册凭据（多播表，见 `AISpeechReader.addFinishHandler`）
    private var speechFinishToken: AISpeechReader.FinishToken?

    /// 验收钩子喂进来的**恒定音量**（`nil` = 用真麦克风的值）。见 `applyDebugHooks`。
    private var forcedLevel: Double?

    // MARK: - 初始化

    init(chatModel: ChatModel) {
        self.chatModel = chatModel
    }

    // MARK: - 开窗 / 关窗

    /// 窗口出现时调（**幂等**：重复调不会重复开麦）。
    func startCall() {
        guard !chatModel.isVoiceCallActive else { return }
        chatModel.isVoiceCallActive = true
        // 回复结束时把正文交回来（见 `ChatModel.chatManagerDidFinish`）
        chatModel.voiceCallReplyHandler = { [weak self] text in
            guard let self else { return }
            self.handleReplyFinished(text)
        }
        // 🔴 先把会话页那两样收干净，再开自己的麦：
        //    ① **录音浮层**：`VoiceInputManager` 是单例，会话页若正录着，我们一开麦
        //       就成了"两边抢一个 tap"（后开的静默顶掉前一个）；
        //    ② **朗读**：它占着播放通道，且开麦时会被共享层静默停掉 —— 那条路
        //       不发回调 ⇒ 会话页那颗朗读图标会永远停在"正在读"的脸上。
        //    ⚠️ `toast: nil`：用户没取消任何东西，弹「已取消」很突兀。
        //
        // ☠️☠️ **必须等让位收完再挂回调**（2026-10-12 用户报「说话没有反应」的真因）。
        //    `cancelVoice` 内部清的是**共享单例的回调槽位**，而那一步被派到
        //    **下一个主队列回合**（`VoiceInputManager.stopRecording` 两条出口都是 async）。
        //    原来写成"让位 → 紧接着 `beginListening()`（挂回调）"，两者在**同一个回合**里
        //    ⇒ 下一拍那一刀把我们刚挂的 `onLevel` / `onTranscript` / `onError`
        //    **整组抹掉**。症状是**彻底的静默**：窗口照开、文案照显示（「请开始说话」）、
        //    三点照在（`isDotsActive` 为真），但说话**没有任何反应** ——
        //    字幕不出来、音量不跳、连错误提示都没有；而尾静音看门狗因为 `transcript`
        //    永远是空，也永远不会断句发送。⇒ 只能靠 `completion` 把顺序钉死。
        chatModel.cancelVoice(toast: nil) { [weak self] in
            guard let self else { return }
            self.beginListening()
        }
        chatModel.stopSpeech()

        // 朗读读完 → 自动接回听着（与 iOS 通话页同一条回路）
        speechFinishToken = AISpeechReader.shared.addFinishHandler { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.handleSpeechFinished()
            }
        }
        // ⚠️ `beginListening()` 已经交给上面那个 completion 了，⛔ 别在这里再调一次
        //    （重复调虽然被 `guard phase` 挡住，但会让"到底谁负责开麦"变成两处）。
        applyDebugHooks()
    }

    /// 收干净一切。**由窗口的 `close()` 调**（红绿灯 / ⌘W / 那颗红钮三条路都汇到那儿）。
    ///
    /// 🔴 本类**刻意没有 `hangUp()`**：挂断 = 关窗，而"关窗"这件事只有窗口层知道怎么做。
    ///    在这里自己调窗口层 = 两个方向互相依赖，而且迟早有人只写一半
    ///    （症状：走 ⌘W 的麦克风一直开着、不报任何错）。
    /// ⚠️ 必须**幂等**：`close()` 有闩，但中心 / 视图也可能各调一次。
    func teardown() {
        stopSilenceWatch()
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
        VoiceInputManager.shared.stopRecording(cancel: true)
        clearVoiceCallbacks()
        // ⚠️ 朗读**主动停**（不是 `stopForRecording`）：主动停不回调「读完」，
        //    正好 —— 我们此刻不想因为"读完了"而自动开麦。
        AISpeechReader.shared.stop()
        if let token = speechFinishToken {
            AISpeechReader.shared.removeFinishHandler(token)
            speechFinishToken = nil
        }
        chatModel.voiceCallReplyHandler = nil
        chatModel.isVoiceCallActive = false
        level = 0
        transcript = ""
        phase = .idle
        isPushToTalking = false
    }

    // MARK: - 麦克风（那颗钮 / ⌥+E）

    /// 点麦克风那颗钮：**开 / 关我的麦**。
    ///
    /// 🔴 从静音恢复时要**先打断朗读** —— 录音与朗读抢同一份音频
    ///    （`startRecording` 内部会停朗读，但那次停不发回调，会让我们卡在 `.speaking`）。
    /// ⚠️ 反向（拾音中 → 静音）**不打断朗读**：念的是 AI 的话，与"我的麦关没关"无关。
    func toggleMic() {
        if isMuted {
            isMuted = false
            interruptSpeechIfNeeded()
            beginListening()
        } else {
            mute()
        }
    }

    /// ⌥+E 按下：静音态下**临时**开麦（松手还回去）。已在开麦 / 在等回复时无操作。
    func beginPushToTalk() {
        guard isMuted, !isPushToTalking else { return }
        guard phase != .thinking else { return }
        isPushToTalking = true
        isMuted = false
        interruptSpeechIfNeeded()
        beginListening()
    }

    /// ⌥+E 松开：临时麦收起。
    ///
    /// 🔴 松手 = **把这一句发出去**（像按住说话那样），不是丢弃 ——
    ///    用户按住说了半句、松手，期待的是"发出去了"。
    func endPushToTalk() {
        guard isPushToTalking else { return }
        isPushToTalking = false
        if phase == .listening { commitUtterance() }
        // 不管有没有说出内容，都回到静音（松手 = 麦关）
        mute()
    }

    /// 静音：停麦、音量归零。**不动朗读**（见 `toggleMic` 的注释）。
    private func mute() {
        stopSilenceWatch()
        VoiceInputManager.shared.stopRecording(cancel: true)
        clearVoiceCallbacks()
        level = 0
        if phase == .listening { phase = .idle }
        isMuted = true
    }

    // MARK: - 拾音

    /// 开麦。**所有"开始听"的路径都收敛到这里**（开窗 / 松开 ⌥E / 朗读读完 / 上一轮失败回退）。
    private func beginListening() {
        // 🔴 通话已经收尾了 ⇒ 一律不许开麦（2026-10-12 加）。
        //    成因：`startCall()` 里那次开麦是**延后一拍**的（串在让位的 completion 里，见那段注释）
        //    ⇒ 理论上存在「这一拍里窗口被关掉、`teardown()` 已经跑完」的缝。没有这道闸门时，
        //    延后的 `beginListening()` 会**照常把麦克风开起来** —— 表现是
        //    「窗口没了、系统麦克风图标还亮着」，而且**不报任何错**（正是这扇窗最忌讳的形态）。
        //    ⚠️ 判据取 `isVoiceCallActive`：`startCall()` 一进门就立起来、`teardown()` 落下
        //    ⇒ 「此刻有没有一通活着的通话」就是它。
        guard chatModel.isVoiceCallActive else { return }
        guard !isMuted else { return }
        guard phase == .idle || phase == .speaking else { return }
        guard !chatModel.isStreaming else {
            // 会话页那边正在收流（比如用户刚在输入栏发了条消息）⇒ 此刻不该插话
            notice(L("正在回复中，稍等一下"))
            phase = .idle
            return
        }
        // 朗读没停干净就开麦 ⇒ 共享层会把朗读静默掐掉，我们这边状态却还停在 `.speaking`
        interruptSpeechIfNeeded()

        // 🔴 **挂回调放在权限门之前**（2026-10-12 调整，两条理由缺一不可）：
        //  ① **语义**：挂回调只是"声明本窗是这台单例当前的接收方"，与有没有麦克风权限无关。
        //     权限框期间根本没有录音在跑 ⇒ 提前挂不会有任何事件被误收；
        //     而万一收尾了（`teardown` / `mute`）照样会清，没有多留一条半开的录音。
        //  ② **可验证**：验收环境（渲染台 / 无人值守）**拿不到麦克风授权**
        //     （实测 `VoiceInputManager.isAuthorized` 恒 false）⇒ 回调若挂在门后，
        //     探针里连"到底挂上了没有"都问不出来，「回调被异步抹掉」那类故障
        //     （见 `startCall` 里那段真事故）在离线就是**永久盲区**。
        //     ⇒ 挂在门前的直接收益：`CALLPROBE` 能对着 `onTranscript != nil` 判。
        //     ⛔ 别为了"更干净"把它挪回去 —— 那等于把这条判据重新弄瞎。
        wireVoiceCallbacks()

        guard VoiceInputManager.isAuthorized else {
            VoiceInputManager.requestPermission { [weak self] granted in
                guard let self = self else { return }
                guard granted else {
                    self.notice(L("未获得麦克风或语音识别权限，请在系统设置里开启"))
                    self.phase = .idle
                    return
                }
                self.beginListening()
            }
            return
        }

        // ⚠️ 启动失败**不能**在这里清回调：`onError` 是异步回调（见 `VoiceInputManager.report`），
        //    清了就把错误提示吞掉了。收尾统一由回调那条路走。
        guard VoiceInputManager.shared.startRecording() else { return }

        phase = .listening
        transcript = ""
        lastTranscriptAt = Date()
        startSilenceWatch()
    }

    /// 说完了 → **结束拾音并把这一句发出去**。
    private func commitUtterance() {
        guard phase == .listening else { return }
        stopSilenceWatch()
        // 先切态：界面立刻从「字幕」变成「正在思考…」，不必等那 0.8s 的识别收尾
        phase = .thinking

        VoiceInputManager.shared.stopRecording(cancel: false) { [weak self] text in
            guard let self = self else { return }
            // 收尾完成后再摘回调，避免等待期间丢字（iOS 侧同一条约定）
            self.clearVoiceCallbacks()
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                self.notice(L("没听清，请再说一次"))
                self.recoverToListening()
                return
            }
            self.transcript = content
            // 🔴 发失败（缺 Key / 地址非法）必须**退回听着**：干等在「正在思考…」上
            //    永远等不到回复结束 ⇒ 那一轮就死了，用户只能挂断重开。
            guard self.chatModel.sendFromVoiceCall(content) else {
                self.notice(L("没能发出去，检查一下模型配置"))
                self.recoverToListening()
                return
            }
            // 之后等 `handleReplyFinished`（由 `ChatModel.chatManagerDidFinish` 转发）
        }
    }

    /// 出错 / 空文本 / 发失败之后：回到"在听"（静音态就回静音）。
    private func recoverToListening() {
        transcript = ""
        phase = .idle
        guard !isMuted else { return }
        beginListening()
    }

    // MARK: - 回复 → 朗读 → 再听

    private func handleReplyFinished(_ text: String) {
        // ⚠️ 判据用 `.thinking`：只有"我们发出去的那一轮"才该被念。
        //    用户在通话期间回会话页手动发一条，那次结束不该被念出来。
        guard phase == .thinking else { return }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            recoverToListening()
            return
        }
        phase = .speaking
        AISpeechReader.shared.speak(content)
    }

    private func handleSpeechFinished() {
        guard phase == .speaking else { return }
        // 静音态**不擅自开麦**（这正是 `isMuted` 必须独立于 `phase` 的原因，见文件头）
        phase = .idle
        guard !isMuted else { return }
        beginListening()
    }

    /// 朗读没停干净就开麦 ⇒ 共享层会静默掐掉它，我们这边却还停在 `.speaking`（死锁）。
    /// 所以凡是"要开麦"之前，先在这里自己把状态收干净。
    private func interruptSpeechIfNeeded() {
        guard phase == .speaking || AISpeechReader.shared.isSpeaking else { return }
        // ⚠️ 顺序不能反：先复位**我们自己的**状态，再停朗读器。
        //    反过来的话，`stop()` 触发的收尾回调可能在我们改状态之前跑，把 `.speaking`
        //    又写回去（那一轮就再也开不了麦了）。
        if phase == .speaking { phase = .idle }
        AISpeechReader.shared.stop()
    }

    // MARK: - 尾静音回合机

    private func startSilenceWatch() {
        stopSilenceWatch()
        let timer = Timer(timeInterval: Self.silenceTick, repeats: true) { [weak self] _ in
            // ☠️ Task 必须**自己** weak 捕获：沿用外层 Timer 闭包的 `self` 会撞
            //    `#SendableClosureCaptures`（Xcode 27 + GlobalActorIsolatedTypesUsability
            //    下是警告，Swift 6 语言模式是错误）。两边都是弱引用，生命周期语义不变。
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.checkSilence()
            }
        }
        // ⚠️ `.common`：默认 mode 在滚动 / 拖拽时会被挂起（Mac 上就是"用户正在拖窗口"那一拍）
        RunLoop.main.add(timer, forMode: .common)
        silenceTimer = timer
    }

    private func stopSilenceWatch() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    /// 静音够久**且确实听到过内容** ⇒ 这一句说完了。
    ///
    /// ☠️ 两个条件缺一不可：只判静音的话，开麦后一直没人说话也会被"判定说完"，
    ///    结果是每 1.5s 发一条空消息。
    private func checkSilence() {
        guard phase == .listening else { return }
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard Date().timeIntervalSince(lastTranscriptAt) >= Self.silenceThreshold else { return }
        commitUtterance()
    }

    // MARK: - 录音回调

    private func wireVoiceCallbacks() {
        let voice = VoiceInputManager.shared
        voice.onLevel = { [weak self] level in
            guard let self = self else { return }
            // ⚠️ `forcedLevel` 只有验收钩子会给（见 `applyDebugHooks`）——
            //    真麦克风的 25Hz 回调照旧会来，这里把它盖掉。
            self.level = self.forcedLevel ?? Double(level)
        }
        voice.onTranscript = { [weak self] text in
            guard let self = self, self.phase == .listening else { return }
            self.transcript = text
            // 🔴 尾静音判定**只看它**（音量回调在静音时照样来，不能当"还在说话"的依据）
            self.lastTranscriptAt = Date()
        }
        voice.onError = { [weak self] message in
            guard let self = self else { return }
            self.notice(message)
            self.recoverToListening()
        }
        voice.onReachMaxDuration = { [weak self] in
            guard let self else { return }
            // 到单次上限 = 自动收尾发送（等价于"说完了"）
            self.commitUtterance()
        }
        voice.onInterrupted = { [weak self] in
            guard let self = self else { return }
            self.notice(L("麦克风被系统中断，请重试"))
            self.recoverToListening()
        }
    }

    private func clearVoiceCallbacks() {
        let voice = VoiceInputManager.shared
        voice.onLevel = nil
        voice.onTranscript = nil
        voice.onError = nil
        voice.onReachMaxDuration = nil
        voice.onInterrupted = nil
    }

    // MARK: - 临时提示

    private func notice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.noticeDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.notice = nil
        }
    }

    // MARK: - 🧪 验收钩子（只在 DEBUG 里编译）

    /// 三支，都只为"无人值守时能截到特定的一帧"而存在：
    ///
    /// | 变量 | 作用 |
    /// |---|---|
    /// | `STARRY_CALL_MUTED=1` | 开窗即**静音**（截参考图第 2 张那一态：红斜杠麦克风 + 两行字） |
    /// | `STARRY_CALL_LEVEL=<0~1>` | 给三点喂一个**恒定**音量 |
    /// | `STARRY_CALL_BALL=<0~1>` | 把中央白球钉在一个**恒定振幅**上（同时把"AI 在说"这一档强制立起来） |
    ///
    /// ☠️ 为什么非要有 `STARRY_CALL_LEVEL`：无人值守时**没有声音输入** ⇒ `onLevel` 恒为 0
    ///    ⇒ 三点永远是三个等大圆点，"说话时被拉高"那一帧**根本截不到**
    ///    （静图验不出这个特性，这与 iOS 侧那条"跑图看不出来"是同一个坑）。
    ///    ✅ 喂**恒定**值还顺带消掉了动态动画的截图不确定性：每个点稳定停在同一包络上，
    ///    **任意一帧都能截到"一条拉满、两条趴着"**。
    /// ⚠️ 它替换的是**音量**这一层的输入，其余（尾静音断句、发送、朗读）全是真的 ——
    ///    钩子要贴"人做不到的那一步"，不是绕过整条链路（见 `VERIFY-PROBES` 那节）。
    private func applyDebugHooks() {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let raw = env["STARRY_CALL_LEVEL"], let value = Double(raw) {
            forcedLevel = min(max(value, 0), 1)
            // 立刻生效（不等下一次 25Hz 回调）：截图是在开窗后几百毫秒内拍的
            level = forcedLevel ?? 0
        }
        if env["STARRY_CALL_MUTED"] == "1" {
            mute()
        }
        // 🧪 白球：钉住振幅 + 把"AI 在说"这一档**只在球这一层**强制立起来。
        //    ☠️ 为什么不干脆切 `.speaking`：那会把状态行改成「正在回答…」，而这条钩子
        //       验的是"球收到这一档之后会不会起伏"，不是页面状态机（与 iOS
        //       `STARRY_CALL_BALL` 只驱动球、不动 `state` 是同一条规矩）。
        //    ⚠️ 单独设它而振幅为 0 时，球只是"静息呼吸"——那是正常的（振幅就是 0）。
        if let raw = env["STARRY_CALL_BALL"], let value = Double(raw) {
            forcedBallLevel = min(max(value, 0), 1)
            ballVoiceForced = true
        }
        #endif
    }
}
