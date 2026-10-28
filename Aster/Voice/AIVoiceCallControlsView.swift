//
//  AIVoiceCallControlsView.swift
//  Aster
//
//  通话页**底部那一簇**（2026-10-10；参考图 IMG_3166.PNG）：三个点 → 提示语 → 一排圆钮 → 免责声明。
//
//  ## 为什么要独立成一个视图
//  这四样东西的**间距是成组的**（彼此以对方为锚，见 `AIVoiceCallMetrics`），
//  而它们整体又只是贴在屏幕底部 —— 塞进控制器里会让控制器的布局代码里混进 4 个 bottom 约束，
//  以后加/减一件东西就得回头改一串。这里收成一个「底部簇」，控制器只负责把它钉到底。
//
//  ## 🔴 「麦克风」是**一颗钮承载两态**（2026-10-12 由原先那两颗合并而来）
//  参考图上最左那颗是白底实心、紧挨着的那颗是半透明 —— 白底 = **当前生效的那一档**；
//  它俩本来就只是同一个开关的两种画法（一颗麦克风、一颗麦克风加斜杠）。
//  ⇒ 用户 2026-10-12 明确「去掉第二个按钮」后**合成一颗**（顺带澄清：第 2 颗是**静音**，
//     不是"屏幕共享"—— 屏幕共享本页从来没做过）：
//     拾音中 = 白底 + `mic.fill`；已静音 = 玻璃底 + `mic.slash.fill`
//     （`setMuted(_:)`；换符号走 `AIVoiceCallRoundButton.setSystemName`）。
//  ⛔ 别拆回两颗 —— 那会多出「亮着两颗白底」/「一颗都不亮」这两种讲不通的状态。
//
//  ## 「拍照提问」那颗（2026-10-11 起；2026-10-12 改成**直接开相机**）
//  参考图（IMG_3166 / IMG_3171）上第 3 颗画的是摄像头 —— 但本页没有视频通话，
//  于是它一直是个**点了只会弹一句"暂不支持视频通话"的摆设**。
//  改造成实体功能后**直接开相机**：点一下 → 宿主开系统相机 → 拍到的图**立刻作为一条消息发出去**
//  （走会话页 `send(_:attachments:)`，正文留空、由 `AIChatManager` 填占位标题；
//   AI 的回复照旧经 `sessionDidFinishReply(replyText:)` 回到本页**念出来**）。
//  ⇒ 三颗钮各管一件事：说话（含静音）/ **拍照** / 挂断 —— 不再有重复项，也不再有摆设。
//  🔴 2026-10-12 用户明确「第三个按钮变成直接拍照，**不要相册了**」⇒ 那一版曾经弹过
//     「拍照 / 从相册选择」的选择表，**已被否掉**：⛔ 别再把它挂回来。
//     相册仍可从输入栏的相册按钮 / 「+」面板进（那条路不受影响）。
//     ⚠️ 取图与发送**都不在本视图**（`AIAttachmentStorage` / `send` 都在会话页那侧，
//     本仓库铁律：附件落地一律走 `AIAttachmentStorage`，视图层不写文件）
//     ⇒ 这里只有 `onPhotoTapped` 一个出口，⛔ 别在这里 new picker。
//
//  ## 🔴 中间那行提示语**兼任实时字幕**（2026-10-11）
//  参考图上那里写的是「说话或点击打断」，但通话中它会被**用户正在说的那句**顶掉
//  （来源是 `VoiceInputManager.onTranscript`，控制器的 `refreshHint()` 决定显示哪个）。
//  由此带来两条硬约束，改这一行之前先看：
//  1. 必须**单行 + 截头**（`numberOfLines = 1` / `.byTruncatingHead`）——
//     识别文本是"截至目前的全量"，越说越长，不截会横着撑出屏幕、把下面那排按钮顶下去；
//  2. 必须**限宽但不用等宽**（`greaterThanOrEqualTo` / `lessThanOrEqualTo`）——
//     短文案的居中位置要跟参考图一模一样，只有长文案才吃到那两条约束。
//  ⛔ 文案本身**不在这里拼**：这里只有一个 `hintText` 入口，显示哪句由控制器说了算
//     （两处都写必然漂，这是本仓库的通用规矩）。
//
//  ## 提示语上方那三个点 = **音量指示**（2026-10-11 换掉原「小方块」）
//  原先是照 IMG_3166 还原的一块 18pt 静态方块；用户给了新参考图
//  （`Clipboard_Screenshot*.png`）指出真实形态：**三个点，说话时随音量上下长大变小**
//  （安静＝三个等大圆点，说话＝其中一个明显被拉高）。详见 `AIVoiceCallDotsView` 的文件头。
//
//  🔴 两个开关都在这里转发，**别绕过去直接摸那个视图**：
//  - `setLevel(_:)`          —— **用户**的音量（麦克风电平），由控制器在
//    `VoiceInputManager.onLevel` 里喂；
//  - `setIndicatorActive(_:)` —— 只在拾音中跑动画（安静时它必须是静止的等大圆点）。
//
//  ⚠️ 2026-10-26 起「与球同刻度」这句不再成立：中央那颗白球**不吃**用户电平，
//     它只随 AI 朗读起伏（见 `AIVoiceCallBallView` 文件头末段）。用户的声音只由这三个点表达。
//
//  ☠️ 承载盒的高度**恒等于 `indicatorDotMaxHeight`**（点在盒内恒居中）——
//     点是从圆心朝上下两头长的，盒子高度不跟着变，提示语才不会跟着音量抖。
//     ⛔ 别把 `height` 改成 `.greaterThanOrEqualTo` 或干脆删掉。
//

import UIKit
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore
import SnapKit

final class AIVoiceCallControlsView: UIView {

    // MARK: - 对外

    /// 麦克风（**一颗钮承载「拾音中 / 已静音」两态**，点击来回切，见文件头）
    var onToggleMute: (() -> Void)?
    /// 「拍照提问」那颗（2026-10-11 由原先那颗**置灰的摄像头摆设**改造而来）。
    /// 宿主负责开相机并把拍到的图**立刻发出去** —— 本视图只管喊一声。
    /// 🔴 2026-10-12 起是**直接开相机**（不再弹「拍照 / 相册」选择表，见文件头）。
    var onPhotoTapped: (() -> Void)?
    /// 挂断
    var onHangup: (() -> Void)?

    /// 提示语当前文案（`AIVoiceCallState` 驱动，见控制器）
    var hintText: String {
        get { hintLabel.text ?? "" }
        set { hintLabel.text = newValue }
    }

    /// 中央白球所在那一带的**下沿视图**（就是音量指示器本身）。
    ///
    /// 🔴 控制器拿它把白球垂直居中在「顶部安全区 → 这一簇的顶」之间 ——
    ///    ⛔ 别在控制器里另写一个"视高 × 某个比例"来定位白球：这一簇的高度是
    ///    **自下而上串出来**的（安全区 34 还是 0 都会整块平移），写死比例必然在别的机型上压到三颗钮。
    ///
    /// ⚠️ 为什么交出**视图本身**、而不是 `NSLayoutYAxisAnchor`：
    ///    SnapKit 的 `equalTo` 只接受 `ConstraintRelatableTarget`，裸的 `NSLayoutYAxisAnchor`
    ///    **编译不过**（2026-10-26 第一次构建就撞在 `argument type 'NSLayoutYAxisAnchor'
    ///    does not conform to expected type 'ConstraintRelatableTarget'`）。
    ///    交视图出去，调用方走 `controls.ballBandBottomView.snp.top` 就对了。
    var ballBandBottomView: UIView { indicator }

    // MARK: - 子视图

    /// 提示语上方那三个点（音量指示，见文件头）
    private let indicator = AIVoiceCallDotsView()

    private let hintLabel = UILabel()

    /// 🔴 2026-10-12 起**一颗钮承载两态**：拾音中 = 白底 + `mic.fill`、
    ///    已静音 = 玻璃底 + `mic.slash.fill`（`setMuted(_:)` 来回切，见文件头）。
    ///    ⛔ 别再拆出第二颗「静音」钮。
    private lazy var micButton = AIVoiceCallRoundButton(
        systemName: "mic.fill", pointSize: AIVoiceCallMetrics.buttonIconPointSize)

    /// 「拍照提问」（原先是 `video.slash.fill` 的置灰摆设，见文件头）
    ///
    /// 🔴 2026-10-12 换图标：`text.below.photo` → **`camera.fill`**。
    ///    原先选 `text.below.photo` 的理由是"这条路既能拍照也能选相册，画成拍照会误导"；
    ///    用户随后明确「第三个按钮变成**直接拍照**，不要相册了」⇒ 那个理由**不成立了**，
    ///    而这颗钮的行为就是开相机 ⇒ 图标照行为选。
    ///    ⛔ 别再改回 `text.below.photo`（那会读成"看一张已有的图"）。
    ///    字号沿用原摄像头那颗的 `-2`（`camera` 这个符号本身横宽，按整号会显大）。
    private lazy var photoButton = AIVoiceCallRoundButton(
        systemName: "camera.fill", pointSize: AIVoiceCallMetrics.buttonIconPointSize - 2)

    /// 挂断那颗：**粗一档**（参考图上那个叉明显比别的图标粗），且是红色
    private lazy var hangupButton: AIVoiceCallRoundButton = {
        let button = AIVoiceCallRoundButton(systemName: "xmark",
                                            pointSize: AIVoiceCallMetrics.buttonIconPointSize + 2,
                                            weight: .bold)
        button.iconColor = AIVoiceCallPalette.hangupRed
        button.accessibilityLabel = L("挂断")
        return button
    }()

    private lazy var buttonRow: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [micButton, photoButton, hangupButton])
        stack.axis = .horizontal
        stack.alignment = .center
        // `.equalSpacing` + 左右各留 `buttonRowInset`：几颗就等分剩下的宽度
        //（参考图 4 颗实测：边距 27/29px、钮间距 46px ⇒ 就是等分出来的）
        // ⚠️ 2026-10-12 只剩 3 颗（删掉了第 2 颗「静音」）⇒ **边距不变、钮间距变宽**；
        //    这是"等分"的必然结果，⛔ 别为了凑回 46pt 去写死间距。
        // ⛔ 别改成 `.fillEqually`：那会把钮撑到不等宽（它们的 intrinsic 尺寸就是 60×60）
        stack.distribution = .equalSpacing
        return stack
    }()

    private let footerLabel = UILabel()

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setUpIndicator()
        setUpHint()
        setUpButtons()
        setUpFooter()
        layoutSubviewsManually()
        setMuted(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 装配

    private func setUpIndicator() {
        // 颜色 / 圆角 / 三个点的排布全在 `AIVoiceCallDotsView` 里，这里只是摆下位置
        addSubview(indicator)
    }

    private func setUpHint() {
        hintLabel.font = .systemFont(ofSize: AIVoiceCallMetrics.hintFontSize)
        hintLabel.textColor = AIVoiceCallPalette.hint
        hintLabel.textAlignment = .center
        // ⚠️ 这一行会被**实时字幕**顶掉（通话中显示用户正在说的那句，见控制器 `refreshHint`）
        // ⇒ 必须单行 + 截断，否则长句会横着撑出屏幕、还会把下面那排按钮顶下去。
        // 🔴 截**头**不截尾：识别文本是「截至目前的全量」，截尾就把**刚说的那几个字**切掉了，
        //    而那正是用户此刻最需要确认的东西。
        hintLabel.numberOfLines = 1
        hintLabel.lineBreakMode = .byTruncatingHead
        addSubview(hintLabel)
    }

    private func setUpButtons() {
        micButton.accessibilityLabel = L("麦克风")
        photoButton.accessibilityLabel = L("拍照提问")
        micButton.addTarget(self, action: #selector(muteTapped), for: .touchUpInside)
        photoButton.addTarget(self, action: #selector(photoTapped), for: .touchUpInside)
        hangupButton.addTarget(self, action: #selector(hangupTapped), for: .touchUpInside)
        for button in [micButton, photoButton, hangupButton] {
            button.snp.makeConstraints { make in
                make.width.height.equalTo(AIVoiceCallMetrics.buttonDiameter)
            }
        }
        addSubview(buttonRow)
    }

    private func setUpFooter() {
        footerLabel.text = L("内容由 AI 生成")
        footerLabel.font = .systemFont(ofSize: AIVoiceCallMetrics.footerFontSize)
        footerLabel.textColor = AIVoiceCallPalette.footer
        footerLabel.textAlignment = .center
        addSubview(footerLabel)
    }

    /// 四段**自下而上**串起来。
    /// 🔴 一律以「下面那件东西」为锚，**不使用绝对 y** ——
    ///    换机型（底部安全区 34pt 还是 0）时这一簇会整块上下平移，彼此间距保持不变。
    private func layoutSubviewsManually() {
        footerLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(safeAreaLayoutGuide.snp.bottom)
                .offset(-AIVoiceCallMetrics.footerToSafeBottom)
        }
        buttonRow.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(AIVoiceCallMetrics.buttonRowInset)
            make.trailing.equalToSuperview().offset(-AIVoiceCallMetrics.buttonRowInset)
            make.bottom.equalTo(footerLabel.snp.top).offset(-AIVoiceCallMetrics.buttonRowToFooter)
        }
        hintLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            // ⚠️ 限宽用 `greaterThanOrEqualTo` / `lessThanOrEqualTo` 而不是 `equalTo`：
            //    这样短文案的居中位置与参考图**完全一致**，只有长文案才会被这两条挤住，
            //    ⛔ 用 `equalTo` 会把短文案也强行撑到整宽（居中看不出来，但 label 的
            //    点击/选中区域和后续想加的东西都会跟参考图对不上）。
            make.leading.greaterThanOrEqualToSuperview().offset(AIVoiceCallMetrics.hintSideInset)
            make.trailing.lessThanOrEqualToSuperview().offset(-AIVoiceCallMetrics.hintSideInset)
            make.bottom.equalTo(buttonRow.snp.top).offset(-AIVoiceCallMetrics.hintToButtonRow)
        }
        indicator.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalTo(hintLabel.snp.top).offset(-AIVoiceCallMetrics.indicatorToHint)
            // ☠️ 高度**恒定**（= 拉到最高时的高度），点在盒内恒居中，上下对称地长。
            //    ⛔ 别改成跟着点走 —— 那会让提示语随音量上下抖（截图里看不出来是"算错了"）。
            make.height.equalTo(AIVoiceCallMetrics.indicatorDotMaxHeight)
            // 宽度由 `AIVoiceCallDotsView.intrinsicContentSize` 自己给（点数只有它知道）
        }
    }

    // MARK: - 状态

    /// 切静音档：**麦克风那一颗**在「拾音中 / 已静音」两态之间换样子
    /// （拾音中 = 白底 + `mic.fill`；已静音 = 玻璃底 + `mic.slash.fill`）。
    /// ⚠️ 图标必须跟着换：只翻底色的话，用户分不出"现在是开着还是关着"。
    /// ⛔ 别在这里顺手改 `hintText` —— 文案由控制器的状态机给，两处都写必然漂。
    func setMuted(_ muted: Bool) {
        micButton.setSystemName(muted ? "mic.slash.fill" : "mic.fill")
        micButton.style = muted ? .translucent : .filled
        micButton.accessibilityLabel = muted ? L("麦克风（已静音）") : L("麦克风")
    }

    /// **用户**的音量（0~1，麦克风电平）→ 三个点的起伏幅度。
    /// ⚠️ 中央白球**不**读这一路（它只随 AI 朗读起伏，见文件头末段）。
    func setLevel(_ level: CGFloat) {
        indicator.setLevel(level)
    }

    /// 只在**拾音中**跑动画；关掉时三点回到静止的等大圆点（⛔ 别常开，见文件头）
    func setIndicatorActive(_ active: Bool) {
        indicator.setActive(active)
    }

    // MARK: - 事件

    @objc private func muteTapped() { onToggleMute?() }
    @objc private func photoTapped() { onPhotoTapped?() }
    @objc private func hangupTapped() { onHangup?() }
}
