import UIKit
import AICore

/// 「按住说话」的录音会话：权限预热 → 起录音 → 波形 / 实时文字 → 收尾。
///
/// 这一块的状态机只有两个态（`isVoiceSessionActive` 真 / 假），但**收尾路径有五条**，
/// 全部收敛到 `endVoiceSession(cancel:toast:)` 一个出口：
/// 松手发送、手指移出取消、到时长上限自动发送、被系统打断、页面离开强停。
/// 新增收尾路径时请也走这个出口，别自己写一套（浮层残留多半是漏了某条路径）。
///
/// ## 与朗读的互斥
/// 录音与朗读**共用同一份 `AVAudioSession`**：录音要 `.playAndRecord`，朗读要 `.playback`，
/// 会互相顶掉。所以两边的入口都先停对方（见 `beginVoiceSession` 与 `toggleSpeech`）。
extension AIModuleViewController {

    // MARK: - 浮层

    /// 录音浮层**贴屏幕最底部**铺满整宽（豆包那套；2026-10-03 改）。
    ///
    /// ⚠️ 它会**盖住输入栏**（这正是豆包的样子）—— 但浮层 `isUserInteractionEnabled = false`，
    /// 所以「按住说话」那根手指的事件照常送到下面的按钮，手势不会断。
    /// 输入栏是 frame 布局且会随键盘移动，故每次布局都重算（现在只依赖 `view` 的尺寸）。
    func layoutVoicePanel() {
        guard voicePanel.superview != nil, view.bounds.width > 0 else { return }
        let height = VoiceRecordingPanel.preferredHeight
        let target = CGRect(x: 0, y: view.bounds.height - height, width: view.bounds.width, height: height)
        if voicePanel.frame != target { voicePanel.frame = target }
    }

    /// 切到语音态时预热权限。
    /// 系统权限框一弹出就会强制松开手指，若等到 touchDown 才请求，这一次录音必然中断。
    func handleInputModeChange(isVoice: Bool) {
        guard isVoice, !VoiceInputManager.isAuthorized else { return }
        VoiceInputManager.requestPermission { [weak self] granted in
            guard let self = self, !granted else { return }
            self.showToast(L("未获得麦克风或语音识别权限，请在设置中开启"))
            self.inputToolbar.showTextMode(focus: false)
        }
    }

    // MARK: - 会话

    /// 开始按住说话
    func beginVoiceSession() {
        guard !isVoiceSessionActive else { return }
        guard !isStreaming else {
            showToast(L("正在回复中…"))
            return
        }
        guard VoiceInputManager.isAuthorized else {
            showToast(L("请先在设置中开启麦克风与语音识别权限"))
            inputToolbar.showTextMode(focus: false)
            return
        }
        // 朗读与录音共用一份音频会话：先停朗读并复位图标。
        // （`VoiceInputManager.startRecording` 内部也会兜底停一次，但那一步不发回调、
        //  管不到 UI，这里负责把 `speakingRowIndex` 一起收干净。）
        stopSpeech()

        let voice = VoiceInputManager.shared
        voice.onLevel = { [weak self] level in
            guard let self else { return }
            self.voicePanel.update(level: level)
        }
        voice.onTranscript = { [weak self] text in
            guard let self else { return }
            self.voicePanel.updateTranscript(text)
        }
        voice.onError = { [weak self] message in
            guard let self else { return }
            // 出错时静默收尾（不提示「已取消」），只报真正的错误原因
            self.endVoiceSession(cancel: true, toast: false)
            self.showToast(message)
        }
        voice.onReachMaxDuration = { [weak self] in
            guard let self else { return }
            // 到时长上限自动收尾（等同于松手发送）
            self.endVoiceSession(cancel: false)
        }
        voice.onInterrupted = { [weak self] in
            guard let self else { return }
            // 系统已停掉录音，这里只负责收浮层 + 提示
            self.endVoiceSession(cancel: true, toast: false)
            self.showToast(L("录音被中断，请重试"))
        }

        // 启动失败：onError 是异步回调，这里不能清回调（否则错误提示发不出来）
        guard voice.startRecording() else { return }
        isVoiceSessionActive = true
        // show 内部负责入视图（层级高于输入栏），之后再定位
        voicePanel.show(in: view)
        layoutVoicePanel()
        // 录音浮层压着输入栏上方那块 —— 「回到底部」按钮先让位，别两个东西叠一起
        updateScrollToBottomButton()
    }

    /// 结束语音会话并把识别结果直接发给 AI（不回填输入框）
    /// - Parameters:
    ///   - cancel: true 表示丢弃（手指移出 / 被中断 / 页面离开）
    ///   - toast: cancel 时是否提示「已取消」（被中断 / 出错时由调用方给更具体的原因）
    func endVoiceSession(cancel: Bool, toast: Bool = true) {
        guard isVoiceSessionActive else {
            // 未在录音也兜底收掉浮层，避免异常路径留下残余
            voicePanel.dismiss()
            VoiceInputManager.shared.stopRecording(cancel: true)
            clearVoiceCallbacks()
            return
        }
        isVoiceSessionActive = false

        let voice = VoiceInputManager.shared
        voice.stopRecording(cancel: cancel) { [weak self] text in
            guard let self else { return }
            // 收尾完成后再摘掉回调，避免等待期间丢字
            self.clearVoiceCallbacks()
            self.voicePanel.dismiss()
            // 浮层收起 → 把「回到底部」按钮还回来（`isVoiceSessionActive` 已在上文置 false）
            self.updateScrollToBottomButton()
            guard !cancel else {
                if toast { self.showToast(L("已取消")) }
                return
            }
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                self.showToast(L("没听清，请再说一次"))
                return
            }
            // 不回填输入框，识别结果直接作为一条消息发出（保持语音态，方便连续说）。
            // 走 sendInput：此时待发区若已选了图，会跟这句话一起发出去（与键盘 return 一致）
            self.sendInput(text: content)
        }
    }

    /// 摘掉语音回调（单例是共享的，退出时必须清干净）
    func clearVoiceCallbacks() {
        let voice = VoiceInputManager.shared
        voice.onLevel = nil
        voice.onTranscript = nil
        voice.onError = nil
        voice.onReachMaxDuration = nil
        voice.onInterrupted = nil
    }

    // MARK: - 🧪 验收钩子：直接进「打电话」页

    /// `STARRY_CALL_UI=1` 启动时**自动**推一次通话页（只推一次，见 `didAutoOpenVoiceCall`）。
    ///
    /// ## 为什么非要有这个钩子
    /// 通话页在导航栈的**第二层**，而模拟器**没有任何命令行点按手段**
    /// （`xcrun simctl` 不提供 tap / touch，`io` 只能截图录屏）——
    /// 没有这个钩子，「这一页长什么样」就只能靠人手在模拟器上点，agent 侧完全验收不了。
    /// 这与 Mac 侧那套 `STARRY_ROOT_MENU=1` / `STARRY_FIXTURE_DOC=1` 是**同一条路子**
    /// （见 `AsterMac/Sidebar/SidebarSettingsBar.swift` 里那段注释）。
    ///
    /// ## 三个约束
    /// 1. **只在 `#if DEBUG` 下编译进去** —— Release 包里这段代码根本不存在；
    /// 2. **只触发一次**（闩在 `didAutoOpenVoiceCall`）—— 否则从通话页返回会又被推进去；
    /// 3. 走的是**和点按钮完全相同的那条路**（`callButtonTapped()`），
    ///    ⛔ 别另写一条"直接 push"的捷径 —— 那样验的就不是用户真实走的路径了。
    func openVoiceCallIfRequested() {
        #if DEBUG
        guard !didAutoOpenVoiceCall else { return }
        guard ProcessInfo.processInfo.environment["STARRY_CALL_UI"] == "1" else { return }
        didAutoOpenVoiceCall = true
        // 等这一帧画完再推：`viewDidAppear` 里直接 push 会在导航动画里叠一层
        //（首屏落地页的动画还没跑完），截出来的图会有半透明残影。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callButtonTapped()
        }
        #endif
    }

    // MARK: - 打电话（2026-10-10）

    /// 导航栏右上角那颗 `phone.fill` → push「打电话」页。
    ///
    /// 形态与搜索页 / 文档页**刻意一致**：push 一整页（不是浮层、不是模态）。
    /// ⚠️ 通话页会**自己藏掉系统导航栏**（沉浸式，见 `AIVoiceCallViewController` 文件头），
    ///    并在真的离开时还回去 ⇒ 这里不用管导航栏。
    ///
    /// 🔴 进页之前必须先**收干净三样东西**，否则三样都会在通话页上留下痕迹：
    /// 1. **键盘** —— 它盖着输入栏，不收的话通话页返回时键盘会闪一下；
    /// 2. **朗读** —— 通话页一开麦就会调 `AISpeechReader.stopForRecording()`，
    ///    那是**内部停**、不回调 `onFinish`（见共享层那段注释）⇒ 会话页那颗朗读图标
    ///    会永远停在"正在读"的面孔上。所以这里必须走**主动停**那条路（`stopSpeech` 自己收尾）；
    /// 3. **按键式录音会话** —— 万一是从"按住说话"的中间态跳过来的，浮层 + 麦克风都得收掉。
    ///    ⚠️ 传 `toast: false`：这时候弹一句「已取消」很突兀（用户没取消任何东西）。
    @objc func callButtonTapped() {
        view.endEditing(true)
        stopSpeech()
        endVoiceSession(cancel: true, toast: false)
        // 🔴 编辑态必须在进通话页之前退出：通话页的发送走的是同一个 `sendInput`，
        //    而 `sendInput` 见到 `editingMessageId` 会走「编辑重发」（改掉那条消息 +
        //    截断它之后的所有消息）。用户在通话页里说的第一句话会因此**改掉一条老消息**，
        //    而且不报任何错。
        exitEditing(clearInput: true, dismissKeyboard: true)

        let call = AIVoiceCallViewController()
        // 🔴 通话页说的每一句都从**本页**发出去 —— 走的是键盘输入 / 按住说话**同一条管线**
        //    （`sendInput`），AI 的回复也就长在同一个 `AIChatManager` 上
        //    ⇒ 返回本页看到的就是完整对话。
        //    ⛔ 别让通话页自己持有 manager（或自己 new 一个）—— 那是两份记录，必然对不上。
        //
        //    返回值 = 「有没有真的发出去」。没网时 `send` 会拦下并返回 false，
        //    通话页据此退回「没在听」而不是干等在「正在思考…」上（那会死锁：永远等不到结束）。
        //    ⚠️ 判据用 `isStreaming`：`sendInput` 是**同步**的，成功发起后它已经是 true。
        call.onUtterance = { [weak self] text -> Bool in
            guard let self = self else { return false }
            self.sendInput(text: text)
            return self.isStreaming
        }
        // 🔴 「拍照提问」那颗钮（2026-10-11 加；2026-10-12 起**直接开相机**）：相机由**本页**开
        //    （复用"有没有相机 + `StarryPermission` + 失败引导"那套实现），拍到的图
        //    **立刻发一条** —— 但不进待发区、不等用户再按发送。
        //    ⛔ 别让通话页自己开相机：那就成了"通话页自己发消息"，与"说话走 sendInput"
        //       是两套管线（两份权限处理 + 两处落盘），必然漂。
        //    ⛔ 也别再把「拍照 / 从相册选择」那张选择表挂回来 —— 用户明确「不要相册了」。
        //    ⚠️ `completion` 一定要往下传到底：通话页靠它决定切「正在思考」还是接回原状态。
        call.onRequestImage = { [weak self] completion in
            guard let self = self else {
                completion(false)
                return
            }
            self.presentImageSourceForVoiceCall(completion: completion)
        }
        voiceCallVC = call

        if let nav = navigationController {
            nav.pushViewController(call, animated: true)
        } else {
            // 宿主没给导航栈（本页被模态呈现）→ 自己套一层，通话页才有侧滑返回
            present(UINavigationController(rootViewController: call), animated: true)
        }
    }
}
