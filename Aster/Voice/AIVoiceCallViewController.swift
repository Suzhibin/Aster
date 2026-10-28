//
//  AIVoiceCallViewController.swift
//  Aster
//
//  「打电话」页（2026-10-10 用户需求：「在会话页面的导航右上角添加打电话按钮，
//  进入打电话页面，按照图片这个UI搭建」；参考图 IMG_3166.PNG）。
//
//  ## 🔴 「说话」与「AI 回复」都以**文字**进同一个会话（2026-10-11）
//  本页**不持有自己的会话** —— 发送走的是会话页注入的 `onUtterance`
//  （→ `AIModuleViewController.sendInput(text:)`），也就是键盘输入 / 按住说话**同一条管线**。
//  因此：用户说的每一句立刻变成会话页里的一条用户消息；AI 的回复长在**同一个
//  `AIChatManager`** 上，返回会话页看到的就是完整对话。
//  ⛔ 别在这里 new 一个 `AIChatManager`：那会开出第二个会话，两边内容对不上，
//     而且用户在通话页聊完回去会发现「记录不见了」（其实是在另一个会话里）。
//
//  ## 回合机：怎么知道「一句说完了」
//  用**尾静音**判定（`silenceThreshold`）：`onTranscript` 每次回调都刷新时间戳，
//  超过阈值没有新识别结果且文本非空 ⇒ 断句 → 收尾 → 发送 → 等回复 → 回复完自动开麦。
//  ⚠️ 有个已知限制（不是 bug，是 `VoiceInputManager` 的既有行为）：识别器自己在静音
//     约 1s 后会判定 `isFinal` 并结束识别任务，但 `isRecording` 仍为 true。
//     所以**用户在断句阈值内又接着说话，那半句不会被识别到**。
//     要消掉它得让识别层暴露「已 finalize」事件 —— 那是另一件事，先记在这里。
//
//  ## 🔴 一轮完整的话：说 → 发 → 等 → **念** → 再接回听着（2026-10-11 接通朗读）
//  1. **说**：`startListening()` 开麦，识别结果当实时字幕（`.listening`）；
//  2. **发**：尾静音断句 → `finishTurn()` → `onUtterance`（就是会话页的 `sendInput`）；
//  3. **等**：会话页流式长回复，这一页停在 `.thinking`；
//  4. **念**：会话页收尾时调 `sessionDidFinishReply(replyText:)`——**正文也一起送回来**，
//     本页 `startSpeaking()` 用 `AISpeechReader` 念出来（`.speaking`，提示语「点击打断」）；
//  5. **接回**：念完、被点断、或根本没得念 → `startListening()` 开下一轮。
//
//  ☠️ 顺序不能反：录音（`.playAndRecord`）与朗读（`.playback`）**抢同一份 `AVAudioSession`**
//     ⇒ 必须**先停麦**再 `speak()`，否则朗读会被录音会话顶掉 —— 表现是"没声音"，
//     而且**不报任何错**（`AVSpeechSynthesizer` 照样把这条 utterance 走完）。
//
//  ## 🔴 「拍照提问」那颗（2026-10-11 加；2026-10-12 改成**直接开相机**）：第 3 颗不再是摆设
//  原先是照参考图留着的一颗**置灰摄像头钮**（点了只弹「暂不支持视频通话」）。现在走真实链路：
//  点一下 → **停麦** → 交给会话页**直接开系统相机** → 拍到的图**立刻发一条**
//  → 本页切 `.thinking` → 回复回来照旧念出来（后半段与"说话"那条**完全共用**）。
//  🔴 2026-10-12 用户明确「第三个按钮变成直接拍照，不要相册了」⇒ 那一版曾经弹的
//     「拍照 / 从相册选择」选择表**已被否掉**，⛔ 别再挂回来。
//  🔴 取图与发送**都不在本页**：本页只交出一个 `onRequestImage` 出口，
//     落盘（`AIAttachmentStorage`）与发送（`send`）全在会话页 —— 附件不进 `ChatRowView`、
//     视图层不写文件，这是本仓库铁律。
//  ☠️ **停麦必须排在开相机之前**：相机是模态、会盖住本页，麦还开着的话，
//     用户在取景那几秒里说的话会照进 `latestTranscript`（回来时它已经不是空的了）。
//  ⚠️ 取消 / 读图失败 / 被拦下（没网、模型不收图）**都必须回执 `false`**，本页据此接回原状态；
//     漏掉任何一条出口，用户就会停在「麦克风已经关了、提示语却还写着'说话或点击打断'」的死样子上
//     （不报错，只是点了没反应）。
//
//  ## 还有什么没做
//  | 还没有 | 说明 |
//  |---|---|
//  | **视频通话** | 原先那颗置灰的摄像头钮已改作「拍照提问」，真·视频链路仍未做 |
//  | **屏幕共享** | 参考图上那颗的语义（把画面实时喂给 AI 看）用户决定**不做**（原话"没 AI 能接收"）。🔴 2026-10-12：本页原先第 2 颗其实是**静音**，用户据此把它整颗去掉 ⇒ **底部只剩三颗**（麦克风 / 拍照 / 挂断），静音并入麦克风**一颗钮两态** |
//
//  ## 🔴 沉浸式：系统导航栏整条藏掉
//  底纹要铺到状态栏下面（参考图就是这样），系统导航栏那条毛玻璃会把底纹切断。
//  ⇒ `viewWillAppear` 藏、`viewWillDisappear` **只在真的离开这一页时**还回去。
//  ☠️ 还回去的条件必须是 `isMovingFromParent || isBeingDismissed` ——
//    本页上面再 push 一页（比如从 toast 里开网页）也会走 `viewWillDisappear`，
//    不带这个判断就会在那时候把导航栏提前还回去 ⇒ 返回本页时顶着一条空导航栏。
//
//  ## 🔴 深浅色：这一页**钉死深色**
//  底纹是 `StarrySkyEngine` 的深空星空（不跟系统走）⇒ 深色档下若让文字翻黑白字，
//  浅色档下若让文字翻深色，都会撞底。所以整页 `overrideUserInterfaceStyle = .dark`、
//  状态栏 `.lightContent`，前景一律取亮色（口径集中在 `AIVoiceCallPalette`）。
//
//  ## 🔴 页面中央那颗**白球**（2026-10-26 加）
//  100 × 100、纯白、带呼吸动画；**AI 朗读时**随"声音"起伏（`AIVoiceCallBallView`）。
//  - 纵向位置 = 「顶部安全区 → 底部控件簇上沿」这一带的**正中**（见 `layoutSubviewsManually`），
//    ⛔ 不是整页居中、也不是"视高 × 比例"（两条理由都写在那个方法里）；
//  - 档位**只由 `apply(state:)` 驱动**，只有 `.speaking` 是"随声音"那一档；
//  - ⚠️ 它拿不到真实的音频振幅（`AISpeechReader`/`AVSpeechSynthesizer` 都不给电平），
//    用的是**合成包络** —— 详见 `AIVoiceCallBallView` 文件头，⛔ 别对外说成"实时音量"。
//

import UIKit
import SnapKit
import AICore
// 权限状态查询/跳设置（`beginListening` 用）：`StarryPermission` 不随 `AICore` 重导出，
// 必须显式 import —— 缺了它编译期就报 `cannot find 'StarryPermission' in scope`。
import StarryKitCore

/// 通话页的状态（下一步接回合机时，`.thinking` / `.speaking` 由会话事件驱动）
enum AIVoiceCallState {
    /// 还没开始听（首次进入且尚未授权，或用户手动结束）
    case idle
    /// 正在听你说（麦克风开着）
    case listening
    /// 已经发出去了，等 AI 出字
    case thinking
    /// AI 正在朗读
    case speaking
    /// 用户把麦克风静音了
    case muted
}

final class AIVoiceCallViewController: UIViewController {

    // MARK: - 对外接线（由会话页在 push 时注入）

    /// 一句说完了 → 交给会话页发出去。
    /// - Parameter text: 最终识别文本（已去首尾空白，非空）
    /// - Returns: 是否真的发出去了。**必须看这个返回值**：没网 / 正在回复中时
    ///   会返回 false，那种情况下调用方要退回「听着」而不是干等在 `.thinking` 上
    ///   （干等 = 永远等不到回复结束，麦也不会再开 ⇒ 页面上只剩一颗转着的球）。
    ///
    /// ⚠️ 实现是会话页的 `sendInput(text:)` —— **别改成"自己发"**（见文件头那段）。
    var onUtterance: ((String) -> Bool)?

    /// 「拍照提问」那颗钮被按下 → 交给会话页**直接开相机并把拍到的图立刻发出去**。
    ///
    /// - Parameter completion: `true` = 那条带图消息**真的发出去了**（本页据此切 `.thinking`）；
    ///   `false` = 用户取消 / 设备没相机 / 权限被拒 / 读图失败 / 发送被拦下（本页据此接回按之前的状态）。
    ///   ☠️ 会话页**每一条出口都必须调它一次**：不调的话本页就永远停在"麦已停、状态没变"的样子上。
    ///
    /// ⚠️ 本页只交出这个出口，**不开相机、不落盘、不发送**（见文件头那段）：
    ///    `AIAttachmentStorage` 与 `send` 都在会话页那侧，⛔ 别在这里 new 一个 picker ——
    ///    那就成了"通话页自己发消息"，与"说话走 `sendInput`"是两套管线（必然漂）。
    var onRequestImage: ((_ completion: @escaping (Bool) -> Void) -> Void)?

    // MARK: - 状态

    private(set) var state: AIVoiceCallState = .idle

    /// 本轮已识别到的文本（`onTranscript` 每次给的是**截至目前的全量文本**）
    private var latestTranscript = ""

    /// 最后一次收到识别结果的时刻 —— 尾静音判定的唯一依据
    private var lastTranscriptAt: CFTimeInterval = 0

    /// 尾静音阈值（秒）：超过这么久没有新识别结果，就认为这一句说完了。
    /// ⚠️ 别调得太小：正常说话句读之间就有 0.5~1s 停顿，小了会把一句砍成几截、
    ///    变成好几条消息发出去。
    private static let silenceThreshold: TimeInterval = 1.5

    /// 尾静音检测的轮询间隔（比阈值小一个数量级，判定精度够用又不费电）
    private static let silenceTick: TimeInterval = 0.25

    private var vadTimer: Timer?

    /// 🧪 只有"喂假音量"那个验收档（`STARRY_CALL_LEVEL`）会赋值，Release 里恒为 nil。
    /// ⚠️ 之所以**声明在条件编译块之外**：`deinit` 要失效它（RunLoop 会一直持有），
    ///    而 `deinit` 不在任何 `#if` 里 —— 声明在块内的话 Release 直接编译不过。
    private var levelSimulationTimer: Timer?

    /// 回合号：作废「已经停麦、收尾回调还没到」的那一轮。
    ///
    /// 为什么需要它：`stopRecording` 正常收尾要**等识别器吐最终结果（最多 0.8s）**，
    /// 这段时间里用户完全可能点挂断 / 静音 / 离开页面 —— 那几个动作都必须让这半句
    /// **不再发出去**。只看 `state` 判不出来：那 0.8s 里它已经是 `.thinking`，
    /// 和「正在等 AI 回复」长得一模一样，但那半句其实该被丢掉。
    private var turnId = 0

    /// 监听「朗读自然读完」的注册凭据（多播注册，见 `AISpeechReader.addFinishHandler`）。
    /// ⚠️ 必须留 token 才能注销：单例活得比本页久，不注销的话本页销毁后那个闭包会一直挂在表里。
    private var speechFinishToken: AISpeechReader.FinishToken?

    // MARK: - 子视图

    /// ⚠️ `StarrySkyEngine` 继承自 `UIImageView`，但**只定义了 `init(frame:)`**（见该文件第 16 行）
    /// ⇒ Swift 的子类一旦定义 designated init，就**不再继承父类的 `init()`**，
    ///    `StarrySkyEngine()` 会报 `Missing argument for parameter 'frame' in call`。
    ///    这里给 `.zero` 就行 —— 尺寸/位置全部由下面的 SnapKit 约束接管
    ///    （`init(frame:)` 内部只跑 `setup()`，不读 frame 的值）。
    private let backgroundView = StarrySkyEngine(frame: .zero)
    private let controls = AIVoiceCallControlsView()

    /// 页面中央那颗**白球**（2026-10-26 加）：静息时缓慢呼吸，AI 朗读时随"声音"起伏。
    /// ⚠️ 它只做展示（`isUserInteractionEnabled = false`），不参与任何点击 ——
    ///    压在"点空白处打断"那块手势区上，可交互就会把点击吃掉。
    private let ballView = AIVoiceCallBallView()

    // MARK: - 生命周期

    /// 进入页面时**自动开麦**——这才是"打电话"的形态（不用再按键）。
    ///
    /// ⚠️ 这里必须走 `beginListening()` 而不是 `startListening()`：后者不会请求权限，
    ///    未授权时它只会 `apply(.muted)` 蒙过去。**2026-10-26 实机反馈的"无反应"就是这个**：
    ///    bundle id 改名后权限全归零 ⇒ 进页面静默不开麦 ⇒ 提示语却仍写着「说话或点击打断」，
    ///    用户对着手机说半天，页面一点动静都没有（见 `beginListening` 的注释）。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 🔴 `state == .listening` 但引擎其实没在采（去设置里改过权限、或系统把录音掐了再回来），
        //    也必须重新走一遍 —— ⛔ 只看 `state == .idle` 会让这种"界面写着在听、实际没麦"的状态永久卡住。
        if state == .idle || (state == .listening && !VoiceInputManager.shared.isRecording) {
            beginListening()
        }
        #if DEBUG
        // 🧪 验收钩子（见文件末尾）：模拟器上没法真的"说一句话"/"真的出声"、
        //    也没法真的点「拍照提问」/「麦克风」那两颗钮，这里替它做
        simulateUtteranceIfRequested()
        simulateLevelIfRequested()
        simulateSpeakIfRequested()
        simulatePhotoIfRequested()
        simulateMuteIfRequested()
        simulateBallLevelIfRequested()
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 沉浸式：整条藏掉（详见文件头）
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 🔴 录音绝不能跟着页面走：本页被盖住 / 被 pop 时必须立刻停麦
        stopListening()
        // 朗读同理：一旦离开（含被 push 子页盖住）就停，不在后台念 —— 但**不**接回「听着」
        stopSpeakingSilently()
        // ☠️ 只有"真的离开这一页"才把导航栏还回去（见文件头那段）
        if isMovingFromParent || isBeingDismissed {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
    }

    deinit {
        // ⚠️ 这里**不能**调 `clearVoiceCallbacks()`：`deinit` 是 nonisolated 的，
        //    调本类（MainActor 隔离）的方法会被编译器拦下。`VoiceInputManager` 在包里
        //    （非隔离）⇒ 直接就地清它的回调是合法的。
        let voice = VoiceInputManager.shared
        voice.onLevel = nil
        voice.onTranscript = nil
        voice.onError = nil
        voice.onReachMaxDuration = nil
        voice.onInterrupted = nil
        // ⚠️ 尾静音定时器的 block 是 `[weak self]`，所以它不会拽住本页；
        //    但 RunLoop 会一直持有它 ⇒ 这里必须失效，否则这个 timer 永远活着。
        //    （正常路径上 `viewWillDisappear → stopListening` 已经停过一次，这里是兜底。）
        vadTimer?.invalidate()
        // 同上：RunLoop 会一直持有这个 timer，不失效它会永远活着（只有喂假音量的验收档才会建它）
        levelSimulationTimer?.invalidate()
        // 朗读：把「读完」注册还给单例（正常路径 `viewWillDisappear` 已经还过一次，这里是兜底）
        if let token = speechFinishToken {
            AISpeechReader.shared.removeFinishHandler(token)
        }
        backgroundView.invalidate()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // MARK: - 装配

    override func viewDidLoad() {
        super.viewDidLoad()
        // 底纹是深空星空 ⇒ 整页钉深色（见文件头）
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black

        view.addSubview(backgroundView)
        // ⚠️ 顺序即层级：白球压在星空上、在底部控件簇**之下**（`controls` 是整页铺满的，
        //    但它只有底部那一簇有实体内容，盖不到球）
        view.addSubview(ballView)
        view.addSubview(controls)
        layoutSubviewsManually()
        
        backgroundView.createTimer()
        
        bindCallbacks()
        apply(state: .idle)
    }

    private func layoutSubviewsManually() {
        backgroundView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        // 🔴 白球的纵向位置 = 「顶部安全区 → 底部控件簇上沿」这一带的**正中**。
        //    ⛔ 别写成 `view.snp.centerY`：底部那一簇从提示语往上占了约 250pt，
        //    按整页居中会让球明显偏下、和提示语挤在一起。
        //    ⛔ 更别写"视高 × 某个比例"：底部簇的高度是自下而上串出来的，
        //    换机型（安全区 34 / 0）整块会平移，比例口径跟着漂。
        let ballBand = UILayoutGuide()
        view.addLayoutGuide(ballBand)
        ballBand.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.bottom.equalTo(controls.ballBandBottomView.snp.top)
        }
        ballView.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalTo(ballBand.snp.centerY)
            make.width.height.equalTo(AIVoiceCallMetrics.ballDiameter)
        }
        // 底部那一簇自己按「安全区底边」往上串，这里只把它铺满整页
        controls.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func bindCallbacks() {
        controls.onToggleMute = { [weak self] in
            guard let self else { return }
            self.toggleMute()
        }
        controls.onPhotoTapped = { [weak self] in
            guard let self else { return }
            self.photoTapped()
        }
        controls.onHangup = { [weak self] in
            guard let self else { return }
            self.hangUp()
        }
        // 「点击打断」：朗读回复时点页面空白处即可打断（过滤在下面的手势代理里，见那儿）
        let interruptTap = UITapGestureRecognizer(target: self, action: #selector(interruptTapped))
        interruptTap.delegate = self
        view.addGestureRecognizer(interruptTap)
    }

    @objc private func interruptTapped() {
        interruptSpeaking()
    }

    // MARK: - 拾音

    /// 「让页面开始听」的**唯一入口**（进页面 / 用户点麦克风 / 从静音恢复都会走到这里）。
    ///
    /// ## 为什么非要有这一层（2026-10-26 实机"我说了没反应"的根因）
    /// `startListening()` 只管"开麦"，它**不请求权限** —— 未授权时它内部的 `startRecording()`
    /// 会失败并打回 `.muted`。原先进页面的逻辑是「已授权才自动开，未授权就停在 `.idle`，等用户点麦克风」，
    /// 于是形成一条死路：
    /// 1. 页面停在 `.idle`，而 `.idle` 与 `.listening` **共用同一句提示语**「说话或点击打断」——
    ///    用户以为麦开着，其实一个字都没采；
    /// 2. 用户去点麦克风那颗钮，`toggleMute()` 在 `.idle` 上走的是 **else 分支** ⇒
    ///    直接 `apply(.muted)`（变成"已静音"），**依然不问权限**；
    /// 3. 于是"点麦克风"这个唯一看起来能自救的动作，反而把页面推得更远。
    ///
    /// ⇒ 现在：进页面就请求权限（"打电话"本来就该问这一句），被拒绝时提示语说人话、
    ///    点麦克风直接跳系统设置。⛔ 别再退回"未授权就静静等着"那条老路。
    /// - Parameter openSettingsIfBlocked: 权限已被拒时**是否**直接把用户带到系统设置。
    ///   🔴 只有**用户主动点麦克风**时才传 true。⛔ 进页面（`viewDidAppear`）千万别传 ——
    ///      权限被拒的用户一进通话页就被弹到设置 App，等于把"看这一页"也剥夺了；
    ///      那种情况下页面只用提示语说实话（"权限已关闭，点麦克风去设置"）。
    private func beginListening(openSettingsIfBlocked: Bool = false) {
        if VoiceInputManager.isAuthorized {
            startListening()
            return
        }
        // 系统权限框**只会弹一次**。已经被拒（或家长控制）时再 request 只会立刻回调失败，
        // 用户会觉得"点了没反应" ⇒ 主动点麦克风的那条路直接带去设置页，那里能改。
        guard !Self.isPermissionBlocked else {
            apply(state: .idle)   // 先把提示语切成"权限已关闭，点麦克风去设置"
            if openSettingsIfBlocked { StarryPermission.openSettings() }
            return
        }
        apply(state: .idle)       // 提示语切到"点麦克风开启语音"这一档
        VoiceInputManager.requestPermission { [weak self] granted in
            guard let self else { return }
            // 等系统框的这几秒里用户可能已经点了静音/挂断 ⇒ 别抢回控制权
            guard self.state == .idle else { return }
            if granted {
                self.startListening()
            } else {
                self.refreshHint()
                self.showHintToast(L("需要麦克风和语音识别权限才能通话"))
            }
        }
    }

    /// 麦克风或语音识别**已经被用户拒绝/被系统限制**（此时再请求不会再弹系统框）。
    private static var isPermissionBlocked: Bool {
        let blocked: (StarryPermissionStatus) -> Bool = { $0 == .denied || $0 == .restricted }
        return blocked(StarryPermission.status(for: .microphone))
            || blocked(StarryPermission.status(for: .speechRecognition))
    }

    /// 开麦
    private func startListening() {
        let voice = VoiceInputManager.shared
        // 新一轮：清掉上一轮的字，并把回合号往前推（作废任何还在路上的旧收尾回调）
        latestTranscript = ""
        lastTranscriptAt = 0
        turnId += 1

        voice.onLevel = { [weak self] level in
            guard let self = self else { return }
            // 用户的音量只喂给**三个点**。⚠️ 2026-10-26 起中央白球**不吃**这一路：
            //    三点 = "我在听你说"，白球 = "AI 在说"（见 `AIVoiceCallBallView` 文件头末段）。
            //    ⛔ 别顺手也喂给白球 —— 两个指示器同时随用户声音跳，就分不出"现在轮到谁"了。
            self.controls.setLevel(CGFloat(level))
        }
        // 识别结果不丢：留着当**实时字幕**（`.listening` 下直接顶掉提示语），
        // 同时刷新尾静音判定的时间戳 —— 断句就是靠这个时间戳（见文件头「回合机」）。
        voice.onTranscript = { [weak self] text in
            guard let self = self, self.state == .listening else { return }
            self.latestTranscript = text
            self.lastTranscriptAt = CACurrentMediaTime()
            self.refreshHint()
        }
        voice.onError = { [weak self] message in
            guard let self = self else { return }
            self.stopListening()
            self.apply(state: .muted)
            self.showHintToast(message)
        }
        // 到单次时长上限（60s）：当作「这一句说完了」处理，把已经说出来的发出去，
        // ⛔ 别只是弹个提示 —— 那样用户说了一分钟的话会**整段丢掉**。
        voice.onReachMaxDuration = { [weak self] in
            guard let self = self else { return }
            self.finishTurn()
        }
        voice.onInterrupted = { [weak self] in
            guard let self = self else { return }
            self.stopListening()
            self.apply(state: .muted)
            self.showHintToast(L("通话被系统打断"))
        }

        // ⚠️ 启动失败**不能**在这里清回调：`onError` 是异步回调，清了就报不出原因
        //    （与 `AIModuleViewController+Voice.beginVoiceSession` 同一条规矩）。
        guard voice.startRecording() else {
            apply(state: .muted)
            return
        }
        controls.setIndicatorActive(true)
        apply(state: .listening)
        startVAD()
    }

    /// 用户音量反馈的**统一收尾口**（三个点回到静止的等大圆点）。
    ///
    /// ⚠️ 收尾必须**只有这一处**：本页"停麦"有两条路（`stopListening` 与 `finishTurn`），
    ///    分成两处写就一定会有一天只改了一边，表现是"停麦后三点还在高位跳"。
    /// ℹ️ 中央白球**不在**这里收：它的档位由 `apply(state:)` 统一驱动（`.speaking` 才起伏），
    ///    与停麦不是同一件事 —— ⛔ 别把 `ballView.setVoiceActive(false)` 抄到这里来，
    ///    那样念完最后一句的瞬间球会先泄一口，而 `state` 还没离开 `.speaking`。
    private func stopLevelFeedback() {
        controls.setIndicatorActive(false)
    }

    /// 停麦。**每一条离开路径都必须走这里**（页面消失 / 挂断 / 静音 / 出错 / 被打断）
    ///
    /// ⚠️ 这是「不要把这一句发出去」的出口 —— 所以它同时要**作废当前回合**
    ///    （`turnId += 1`，见那个属性的注释），否则已经停麦、还在等识别器吐最终结果的那半句
    ///    会在 0.8s 后照样被发出去。
    private func stopListening() {
        turnId += 1
        stopVAD()
        latestTranscript = ""
        VoiceInputManager.shared.stopRecording(cancel: true)
        clearVoiceCallbacks()
        stopLevelFeedback()
        // ⚠️ 白球的呼吸**不停**：麦关了它还要继续缓慢明灭（它指示的是"这一页还活着"）。
        //    它自己按 `didMoveToWindow` 开关 display link ⇒ 离开页面时不需要谁再通知它。
    }

    // MARK: - 回合机

    /// 起尾静音检测（每 `silenceTick` 看一眼「多久没新识别结果了」）
    private func startVAD() {
        stopVAD()
        let timer = Timer(timeInterval: Self.silenceTick, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.checkSilence()
        }
        // ⚠️ 必须加到 `.common`：默认 mode 在滚动 / 手势跟踪时会被挂起，
        //    那样用户在通话页拖动一下，断句就停了。
        RunLoop.main.add(timer, forMode: .common)
        vadTimer = timer
    }

    private func stopVAD() {
        vadTimer?.invalidate()
        vadTimer = nil
    }

    /// 尾静音判定：**说话已经停够久**且**确实识别到过内容** ⇒ 这一句说完了。
    /// ⚠️ 第二个条件不能省：页面刚进来时用户还没开口，`lastTranscriptAt` 是 0，
    ///    只判「静音够久」会在进页面 1.5s 后立刻空发一轮。
    private func checkSilence() {
        guard state == .listening else { return }
        guard !latestTranscript.isEmpty, lastTranscriptAt > 0 else { return }
        guard CACurrentMediaTime() - lastTranscriptAt >= Self.silenceThreshold else { return }
        finishTurn()
    }

    /// 收尾这一轮：停麦 → 取**最终**识别文本 → 交给会话页发出去 → 等回复。
    ///
    /// 为什么不用 `latestTranscript` 直接发：`onTranscript` 给的是**实时 partial**，
    /// 识别器在停麦瞬间还会补一次最终结果（`stopRecording` 的 completion 就是它）。
    /// 直接发 partial 会丢掉最后几个字。
    private func finishTurn() {
        guard state == .listening else { return }
        let fallback = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallback.isEmpty else { return }

        turnId += 1
        let tid = turnId
        stopVAD()
        // 先把界面切到「等回复」：识别器吐最终结果最多要 0.8s，这期间球不该还在「听」的样子
        apply(state: .thinking)

        VoiceInputManager.shared.stopRecording(cancel: false) { [weak self] finalText in
            guard let self = self, self.turnId == tid else { return }
            // 录音已经停了 ⇒ 回调不会再来了，就地摘干净（下一次开麦会重新装）
            self.clearVoiceCallbacks()
            self.stopLevelFeedback()

            let content = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            // 识别器偶尔会给回一个空串（停得太快 / 兜底超时），这时用 partial 兜底
            let payload = content.isEmpty ? fallback : content
            guard !payload.isEmpty else {
                // 一句话都没听出来：退回听着，别把用户晾在「正在思考…」上
                self.apply(state: .muted)
                self.showHintToast(L("没听清，请再说一次"))
                return
            }
            // 🔴 发送走会话页注入的那条管线（键盘 / 按住说话 / 通话，三处同一个入口）
            let accepted = self.onUtterance?(payload) ?? false
            guard accepted else {
                // 没发出去（没网 / 上一轮还在回复中）：退回「没在听」的状态，
                // ⛔ 别自动重开麦 —— 没网时重开只会让用户说了白说，还刷一屏提示
                self.stopListening()
                self.apply(state: .idle)
                return
            }
        }
    }

    /// 由**会话页**在「这一轮回复结束了」时调用 —— 带着**回复正文**一起。
    ///
    /// 这是「打完一轮还能接着说」的关键：没有它，用户说一句之后页面就永远停在
    /// 「正在思考…」上，得手动点麦克风才能继续 —— 那不是打电话。
    ///
    /// - Parameter replyText: AI 这一轮回复的**可朗读正文**（已脱 Markdown）。
    ///   为 `nil` / 空串 = 没得念（出错收尾、或助手只回了一张图）⇒ 跳过朗读直接接回「听着」。
    ///
    /// ⚠️ 只在 `.thinking` 时响应：用户点了静音（`.muted`）或已经离开本页时不该被强行开麦。
    func sessionDidFinishReply(replyText: String?) {
        guard state == .thinking else { return }
        guard let text = replyText, !text.isEmpty else {
            startListening()
            return
        }
        startSpeaking(text)
    }

    // MARK: - 朗读回复

    /// 念出 AI 的回复；念完（或被点断）自动接回「听着」。
    ///
    /// ☠️ 顺序不能反：`stopListening()` 必须在 `speak()` **之前** —— 录音与朗读抢同一份
    ///    `AVAudioSession`，先 `speak` 再停麦的话，录音会话会把朗读顶掉（没声音，不报错）。
    private func startSpeaking(_ text: String) {
        // 停麦 + 收音量反馈，但**不**动 `state`（`stopListening` 不设状态，下一行才设）
        stopListening()
        apply(state: .speaking)

        removeSpeechFinishHandler()
        speechFinishToken = AISpeechReader.shared.addFinishHandler { [weak self] in
            guard let self else { return }
            self.speechDidFinish()
        }
        AISpeechReader.shared.speak(text)
        // ⚠️ 兜底：音频会话拿不到时 `speak()` 是**静默放弃**的（内部 `activateSession` 返回 false
        //    就直接 return）⇒ 永远不会有「读完」回调，页面会卡在 `.speaking` 上、麦也不开。
        //    判据只能看 `isSpeaking`（它就是在 `activateSession` 成功之后才置 true 的）。
        if !AISpeechReader.shared.isSpeaking {
            speechDidFinish()
        }
    }

    /// 朗读收尾（自然读完 / 被系统打断 / 被用户点断 / 根本没读起来）→ 接回「听着」。
    ///
    /// 🔴 四条路径**共用这一个出口**：⛔ 别在各处各写一份 `startListening()`，
    ///    那样迟早漏掉一条，表现是"莫名其妙不回话了"。
    private func speechDidFinish() {
        removeSpeechFinishHandler()
        guard state == .speaking else { return }
        startListening()
    }

    /// 用户「点击打断」：立刻停止朗读，并接回「听着」。
    ///
    /// ⚠️ 必须走 `stop()` —— `AISpeechReader` 主动停**不会**回调「读完」（那是刻意设计，
    ///    否则切到另一行朗读时内部先停旧的会误报一次结束），所以这里自己收尾。
    ///    ⛔ 别用 `stopForRecording()`：语义不同且同样不回调，会把本页卡在 `.speaking`。
    private func interruptSpeaking() {
        guard state == .speaking else { return }
        AISpeechReader.shared.stop()
        speechDidFinish()
    }

    /// 停朗读但**不**接回「听着」（离开本页 / 挂断时用）
    private func stopSpeakingSilently() {
        removeSpeechFinishHandler()
        AISpeechReader.shared.stop()
    }

    private func removeSpeechFinishHandler() {
        guard let token = speechFinishToken else { return }
        AISpeechReader.shared.removeFinishHandler(token)
        speechFinishToken = nil
    }

    /// 摘掉语音回调（单例是共享的，退出时必须清干净 —— 否则本页的闭包会在别的页面上跑）
    private func clearVoiceCallbacks() {
        let voice = VoiceInputManager.shared
        voice.onLevel = nil
        voice.onTranscript = nil
        voice.onError = nil
        voice.onReachMaxDuration = nil
        voice.onInterrupted = nil
    }

    // MARK: - 交互

    private func toggleMute() {
        // 🔴 `.idle` 与 `.muted` 在这颗钮上语义相同：点一下 = 开始听。
        //    ☠️ 别把 `.idle` 漏到下面的 else（静音）分支去 —— 那正是"未授权时点麦克风反而变成已静音"的
        //    来路，用户从此既听不到、也再没有任何入口能触发权限请求。
        if state == .idle || state == .muted {
            // 用户主动点的 ⇒ 权限被拒时直接带去设置（进页面那条路不会跳，见 `beginListening`）
            beginListening(openSettingsIfBlocked: true)
            return
        }
        // 🔴 静音要**连带**把正在念的回复停掉，且**不**接回听着：
        //    否则麦克风灭了、AI 还在说话 —— 提示语已经写着「已静音」，用户会以为它停了。
        stopListening()
        stopSpeakingSilently()
        apply(state: .muted)
    }

    private func hangUp() {
        stopListening()
        stopSpeakingSilently()
        navigationController?.popViewController(animated: true)
    }

    // MARK: - 拍照提问

    /// 第 3 颗钮：**停麦 → 让会话页直接开相机 → 拍到的图立刻发一条**。
    ///
    /// 🔴 顺序：**先停麦，再开相机**。相机是模态、会盖住本页；麦还开着的话，
    ///    用户在取景那几秒里说的话会照进 `latestTranscript`（回来时它已经不是空的）。
    ///    这也与"朗读前必须先停麦"同一类 —— 抢的是同一份 `AVAudioSession`。
    ///
    /// ⚠️ 三条出口都要有回执（见 `restore(after:)`）：用户取消、读图失败、发送被拦下。
    ///    ⛔ `onRequestImage` 为 nil（会话页没接线）时也必须自己收场 —— 直接 return 会让
    ///    界面停在"麦已经关了、提示语却还写着说话"的样子上，而且**不报任何错**。
    private func photoTapped() {
        guard state != .thinking else {
            showHintToast(L("正在回复中，稍等一下"))
            return
        }
        // 朗读中点「拍照」= 先打断朗读（它会自己接回听着），再去拍
        if state == .speaking { interruptSpeaking() }
        // 记下"点之前是什么样"：取消时要**原样**接回去
        //（⛔ 别一律 `startListening()` —— 用户本来是静音态的，被强行开麦等于替他改了状态）
        let prior = state
        stopListening()

        guard let request = onRequestImage else {
            restore(after: prior)
            return
        }
        request { [weak self] started in
            guard let self = self else { return }
            if started {
                // 图和话走的是同一条发送管线 ⇒ 后半段（等回复 → 念出来 → 自动开麦）完全一样
                self.apply(state: .thinking)
            } else {
                self.restore(after: prior)
            }
        }
    }

    /// 把界面接回「点这件事之前的样子」。
    /// ⛔ 别写成一律 `startListening()`：`.muted` / `.idle` 下强行开麦是**替用户改状态**。
    private func restore(after prior: AIVoiceCallState) {
        switch prior {
        case .listening, .speaking:
            // `.speaking` 那条：朗读已被 `interruptSpeaking` 打断，接回「听着」正是它本来的走向
            startListening()
        case .muted: apply(state: .muted)
        case .idle:  apply(state: .idle)
        case .thinking: break   // 上面已经挡掉，这里只求 switch 写全
        }
    }

    // MARK: - 状态 → 界面

    /// 状态到界面的**唯一出口**（提示语 + 按钮深浅 + 白球档位都只在这里改）
    /// ⛔ 别在事件处理里顺手改 `controls.hintText` / `ballView.setVoiceActive` —— 两处都写必然漂。
    private func apply(state: AIVoiceCallState) {
        self.state = state
        refreshHint()
        controls.setMuted(state == .muted)
        // 🔴 白球只在 `.speaking` 时"随 AI 声音"起伏，其余四态都是**自己的静息呼吸**。
        //    ⛔ 别把它也接到 `.listening` 上：那样"AI 在说"和"我在说"长得一样，
        //    而这两件事恰恰是这一页最需要分清的两态。
        ballView.setVoiceActive(state == .speaking)
    }

    /// 提示语文案的**唯一出处**
    private static func hintText(for state: AIVoiceCallState) -> String {
        switch state {
        case .idle, .listening:
            // ⚠️ 这两个态给**同一句文案**：参考图上就是「说话或点击打断」。
            //    🔴 但它只在**麦真的开着**时才成立 —— `.idle` 的调用方必须先过 `idleHintText`
            //    分一次档（未授权时这句话是骗人的，用户会对着手机白说），
            //    见 `refreshHint` 与 2026-10-26 那条实机反馈。
            return L("说话或点击打断")
        case .thinking: return L("正在思考…")
        case .speaking: return L("点击打断")
        case .muted:    return L("已静音，点麦克风继续")
        }
    }

    /// 刷新提示语。**说话中优先显示识别到的字**（否则用户根本不知道自己说了什么、
    /// 识别对不对），其余情况显示状态文案。
    ///
    /// ⚠️ 「说话中的实时字幕」顶的是**同一个 label**（参考图上那个位置本来就写着
    ///    「说话或点击打断」）—— 所以不引入新的布局，也就不存在"字幕把球挤歪"这种事。
    private func refreshHint() {
        if state == .listening, !latestTranscript.isEmpty {
            controls.hintText = latestTranscript
        } else if state == .idle {
            controls.hintText = idleHintText
        } else {
            controls.hintText = Self.hintText(for: state)
        }
    }

    /// `.idle` 态的提示语 —— 必须按"**现在到底能不能听**"分档。
    ///
    /// ☠️ 别偷懒沿用 `hintText(for: .listening)` 那句「说话或点击打断」：那是"麦已开"才成立的
    ///    陈述句。未授权时它会让用户对着手机说半天、页面毫无反应，也完全想不到要先去点麦克风
    ///    （2026-10-26 实机反馈："我说无反应，好像听不到我说话"）。
    private var idleHintText: String {
        if VoiceInputManager.isAuthorized { return Self.hintText(for: .listening) }
        if Self.isPermissionBlocked { return L("权限已关闭，点麦克风去设置") }
        return L("点麦克风开启语音")
    }

    // MARK: - 提示

    /// 贴在**输入簇上方**。
    ///
    /// ⚠️ 位置读 `AIVoiceCallMetrics.toastBottomInset`（232），**别再用 130**：
    ///    130 会让 toast 压住提示语（2026-10-26 实测字被切掉一半），
    ///    用户"看不清楚"有一半是这个原因。口径推导见那个常量。
    private func showHintToast(_ message: String) {
        AIToast.show(message, in: view, bottomInset: AIVoiceCallMetrics.toastBottomInset)
    }

    // MARK: - 🧪 验收钩子（只在 DEBUG 构建里存在；Release 包里这段根本不存在）
    // ⚠️ 本段注释里刻意**不写**那个条件编译指令的字面串：契约脚本用 awk 数它的嵌套深度来判
    //    「这个函数在不在块里」，注释里出现一次就会把深度数歪 ⇒ 断言变假绿。

    #if DEBUG

    /// 🧪 模拟"说了一句话"：`STARRY_CALL_SAY=<文本>`。
    ///
    /// ## 为什么非要有它
    /// 这一页的全部意义是「说的话 → 进会话页 → AI 回复 → 自动开麦」，
    /// 而这条链路的**前半段（拾音 + 识别）在无人值守下根本触发不了** ——
    /// 模拟器没有可用的语音输入，`simctl` 也没有点按手段。
    /// 没有这个钩子，agent 侧只能验到"这一页画出来了"，验不到"它真能把话送进会话"。
    /// 有了它，**从 `finishTurn` 往后全是真实代码**（真发送 → 真流式 → 真回到会话页）。
    ///
    /// 与 Mac 侧 `STARRY_ROOT_MENU=1` / 本页 `STARRY_CALL_UI=1` 是同一条路子。
    ///
    /// 环境变量（`sim_ios.sh` 会把它们透传成 `SIMCTL_CHILD_*`）：
    /// - `STARRY_CALL_SAY`    —— 要"说"的那句话（不设 = 钩子不生效）
    /// - `STARRY_CALL_SAY_AT` —— 进页面后第几秒"开口"（默认 2）
    /// - `STARRY_CALL_BACK`   —— 开口后第几秒自动返回会话页（默认 0 = 不返回）。
    ///   设了它才能在**会话页**截图，用来证明那句话真的落进了会话。
    /// - `STARRY_CALL_SAY_HOLD` —— "开口"后先**显示**这么多秒再发出去（默认 0 = 立刻发）。
    ///   用途：截到「说话中的实时字幕顶掉了提示语」那个中间态（不设就截不到）。
    private var didSimulateUtterance = false

    private func simulateUtteranceIfRequested() {
        guard !didSimulateUtterance else { return }
        guard let say = ProcessInfo.processInfo.environment["STARRY_CALL_SAY"], !say.isEmpty else { return }
        didSimulateUtterance = true

        let env = ProcessInfo.processInfo.environment
        let at = Double(env["STARRY_CALL_SAY_AT"] ?? "") ?? 2
        // `HOLD`：先把那句话**显示**着、过 N 秒再发出去。
        // 用途：截图验「说话中的实时字幕确实顶掉了提示语」——不设就是立刻发，截不到那个中间态。
        let hold = Double(env["STARRY_CALL_SAY_HOLD"] ?? "") ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
            guard let self = self else { return }
            // 模拟器上常常没授权 ⇒ 不会自动开麦、`state` 停在 `.idle`。
            // 先摆成 `.listening` 让 `finishTurn` 的 guard 放行 —— 走的仍是**真实**收尾路径。
            self.latestTranscript = say
            self.apply(state: .listening)
            if hold <= 0 {
                self.finishTurn()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
                    guard let self else { return }
                    self.finishTurn()
                }
            }
        }
        if let back = Double(env["STARRY_CALL_BACK"] ?? ""), back > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + at + hold + back) { [weak self] in
                guard let self else { return }
                // ⛔ 不带动画：截图抓的是静态帧，动画中途会拍到半透明残影
                self.navigationController?.popViewController(animated: false)
            }
        }
    }

    /// 🧪 `STARRY_CALL_LEVEL=<0~1>`：喂一个**恒定音量**给音量反馈（球的起伏 + 三点的跳动）。
    ///
    /// ## 为什么非要有它
    /// 模拟器没有可用的麦克风输入 ⇒ `VoiceInputManager.onLevel` 永远不来 ⇒ 音量幅度恒为 0
    /// ⇒ 三点永远停在"三个等大圆点"那一帧，而「随音量上下变大变小」**这条根本截不到**。
    /// 有它就能直接截到"其中一个被拉高"的那一帧，跟参考图第 2 张逐点比。
    ///
    /// ## ☠️ 为什么是**持续**喂、而不是喂一次
    /// 这台模拟器里本 App 的麦克风**早就被授过权**（早先测"按住说话"留下的），
    /// 于是进页就真的开了麦：真麦克风以 **25Hz** 不停回调 `onLevel(≈0)`，
    /// 把这里灌进去的恒定值**立刻覆盖**掉 —— 表现是"喂了 =1 却三个点纹丝不动"，
    /// 而**代码里看不出任何毛病**（这一步实测卡了一轮）。
    /// ⇒ 两手一起上：① 先 `stopListening()` 把真麦克风的电平断掉（走的是**真实**停麦路径）；
    ///    ② 再用 20Hz 定时器持续喂，谁最后写谁说了算。
    /// ⚠️ 它**不碰** `VoiceInputManager` 的拾音开关，只借用停麦那条既有出口。
    private func simulateLevelIfRequested() {
        guard levelSimulationTimer == nil else { return }
        guard let raw = ProcessInfo.processInfo.environment["STARRY_CALL_LEVEL"],
              let value = Double(raw) else { return }
        let level = CGFloat(min(max(value, 0), 1))
        // ① 断掉真实麦克风的电平（模拟器上它常常已经是开着且一直在回 0）
        stopListening()
        // ② 模拟器上常常没授权 ⇒ 不会自动开麦、指示器也就没开动画。这里替它开（**只**开动画）
        controls.setIndicatorActive(true)
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.controls.setLevel(level)
        }
        RunLoop.main.add(timer, forMode: .common)
        levelSimulationTimer = timer
    }

    /// 🧪 `STARRY_CALL_BALL=<0~1>`：把中央白球**钉在一个固定振幅**上，用来量"说话时到底变没变大"。
    ///
    /// ## 为什么非要有它
    /// 白球"随 AI 声音"那一段用的是**合成包络**（连续变化，见 `AIVoiceCallBallView`）——
    /// 截图抓的是一帧，抓到的可能是波峰也可能是波谷，**从单张图上分不出"它到底动没动"**。
    /// 有这个口子就能把球钉在 `1` / `0` 各截一张，量外接圆直径逐点比：
    /// 差值应当 ≈ 球直径 × `voiceAmplitude`（16%），而不是"看起来差不多"。
    ///
    /// ## ☠️ 为什么不靠 `STARRY_CALL_SPEAK` 把它带进 `.speaking`
    /// 实测（2026-10-26，iPhone Air 模拟器）：`AVSpeechSynthesizer` 在这台模拟器上
    /// **拿不到音频会话** ⇒ `speak()` 静默放弃 ⇒ `isSpeaking` 为 false ⇒
    /// `startSpeaking` 末尾那条兜底**当场**把状态打回「听着」（提示语仍是"说话或点击打断"）。
    /// 也就是说在模拟器上**根本钉不住 `.speaking`**，靠它验形变必然验不到。
    ///
    /// ⇒ 这里**只驱动球自己**（`setVoiceActive` + `setVoiceLevel` 两个真实出口），
    ///    **不动 `state`、不动提示语**：验的是"球收到'在说话'这个档位后会不会起伏"，
    ///    而不是"页面进不进朗读态"（后者由 `apply(state:)` 那一条契约 grep 钉住）。
    ///    ⛔ 别把它改成 `apply(state: .speaking)` —— 那就是造一个假状态，违反本页的规矩。
    ///
    /// ⚠️ **延后 2s 再设**：`viewDidAppear` 之后还会来一次 `apply(state:)`（自动开麦 /
    ///    别处的回退都会把球翻回静息档），当场设会被那一拍无声覆盖。
    ///    ⇒ 截图请配 `STARRY_SIM_WAIT ≥ 4`（球还要留一点时间过渡到目标档）。
    private func simulateBallLevelIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["STARRY_CALL_BALL"],
              let value = Double(raw) else { return }
        let level = CGFloat(min(max(value, 0), 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.ballView.setVoiceActive(true)
            self.ballView.setVoiceLevel(level)
        }
    }

    /// 🧪 `STARRY_CALL_SPEAK=<文本>`：进页后**直接进入朗读态**（`.speaking`）。
    ///
    /// ## 为什么非要有它
    /// 「AI 回复 → 念出来」这条链路里，**回复什么时候到、要念多久，两段都不可控**：
    /// 实测同一句提示词，回复在 6~20s 之间到，而一段回复的朗读又要十几秒 ——
    /// 想靠"掐着表截图"卡在 `.speaking` 那一帧纯属撞运气（本轮撞空两次，两次截到的都是
    /// **已经念完、回到「说话或点击打断」**的样子，从截图上看跟"压根没念"无法区分）。
    /// 有它就能把页面**确定性地**钉在朗读态，逐点核对提示语 / 三点 / 按钮。
    ///
    /// ⚠️ 它调的就是真实路径的入口 `startSpeaking(_:)`（`sessionDidFinishReply` 后半段**原样复用**），
    ///    ⛔ 不是另写一套"假装在念"的假状态 —— 那样验的就不是真东西了。
    /// - `STARRY_CALL_SPEAK_AT` —— 进页后第几秒开始念（默认 2）
    private var didSimulateSpeak = false

    private func simulateSpeakIfRequested() {
        guard !didSimulateSpeak else { return }
        guard let text = ProcessInfo.processInfo.environment["STARRY_CALL_SPEAK"],
              !text.isEmpty else { return }
        didSimulateSpeak = true
        let at = Double(ProcessInfo.processInfo.environment["STARRY_CALL_SPEAK_AT"] ?? "") ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
            guard let self else { return }
            self.startSpeaking(text)
        }
    }

    /// 🧪 `STARRY_CALL_PHOTO_AT=<秒>`：进页后第几秒**替用户点一下**「拍照提问」那颗钮。
    ///
    /// ## 为什么非要有它
    /// 「拍照」这条链路的前半段（**开系统相机 → 用户按快门**）在无人值守下**走不过去**：
    /// `simctl` 投不出合成触摸，模拟器也没有相机。没有这个钩子，agent 侧只能验到"那颗钮画出来了"，
    /// 验不到"图真的进了会话页"。
    /// ⚠️ 它调的正是真实入口 `photoTapped()`（⛔ 不是绕过去直接发一条假消息）——
    ///    停麦、回执、状态回退这些**全都是真的**；只有"按快门"那一步由
    ///    `AIModuleViewController.presentImageSourceForVoiceCall` 里的钩子用一张自绘图替代。
    ///
    /// ⚠️ 与 `STARRY_CALL_PHOTO=1` 是**成对**的：这边负责"点"，那边负责"替它拍一张"。
    ///    只设这边 = 模拟器上真的会走到「当前设备没有可用的相机」那条提前 return。
    private var didSimulatePhoto = false

    private func simulatePhotoIfRequested() {
        guard !didSimulatePhoto else { return }
        guard ProcessInfo.processInfo.environment["STARRY_CALL_PHOTO"] == "1" else { return }
        didSimulatePhoto = true
        let at = Double(ProcessInfo.processInfo.environment["STARRY_CALL_PHOTO_AT"] ?? "") ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
            guard let self else { return }
            self.photoTapped()
        }
    }

    /// 🧪 `STARRY_CALL_MUTE_AT=<秒>`：进页后第几秒**替用户点一下**「麦克风」那颗钮（切静音）。
    ///
    /// ## 为什么非要有它
    /// `simctl` 投不出合成触摸 ⇒ "点那颗钮"这件**人做不到的事**在无人值守下没有别的入口，
    /// 而 2026-10-12 改的恰恰是"麦克风**一颗钮承载两态**"⇒ 不点一下，就**拍不到静音那一帧**；
    /// 而"两态长得一模一样"正是这次改动**唯一的新风险**，必须看得见才算验过。
    /// ⚠️ 它调的正是真实入口 `toggleMute()`（⛔ 不是直接 `apply(state: .muted)`）——
    ///    停麦、停朗读、刷提示语、换图标与底色**全是真代码**。
    private var didSimulateMute = false

    private func simulateMuteIfRequested() {
        guard !didSimulateMute else { return }
        guard let raw = ProcessInfo.processInfo.environment["STARRY_CALL_MUTE_AT"],
              let at = Double(raw) else { return }
        didSimulateMute = true
        DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
            guard let self else { return }
            self.toggleMute()
        }
    }

    #endif
}

// MARK: - 「点击打断」的手势过滤

extension AIVoiceCallViewController: UIGestureRecognizerDelegate {

    /// 🔴 只让**不在按钮上**的点击进来。
    ///
    /// 这个手势挂在根视图上（要的是"点页面任意空白处"），而 `UITapGestureRecognizer` 一旦识别
    /// 就会**取消**子视图的触摸（`cancelsTouchesInView` 默认 true）⇒ 不加这道过滤，
    /// 挂断 / 静音 / 麦克风那排圆钮会**全部点不动**（不是不灵敏，是彻底没反应）。
    /// 判据用「触摸点所在的整条祖先链里有没有 `UIControl`」——按类型判比按 frame 判稳，
    /// 加按钮 / 挪位置都不会让它失效。
    ///
    /// ⚠️ 顺带把「不在朗读中」也挡在门外：那几态下这个手势本就没意义，
    ///    不放行还能顺手避开与别的手势的竞争。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard state == .speaking else { return false }
        var node: UIView? = touch.view
        while let current = node {
            if current is UIControl { return false }
            node = current.superview
        }
        return true
    }
}
