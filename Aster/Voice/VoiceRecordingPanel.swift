//
//  VoiceRecordingPanel.swift
//  AIModule
//
//  录音浮层（2026-10-03 改版）：**铺满屏幕最底部**的一块蓝色光晕 + 白色刻度波形。
//
//  ## 为什么是「铺到底部」而不是「输入栏上方的小卡片」
//  用户拿豆包语音输入的截图来对标，原话是「按照豆包的**屏幕最底部**语音输入动画，样式/动画/颜色都改」。
//  豆包那套是：一道深蓝光晕从屏幕底边长上来（顶部是弧形边界）、中间一句提示、
//  最下面一排白色刻度波形。**没有卡片边框、没有红点、没有「正在聆听」标题。**
//  ⇒ 本浮层因此：
//  1. 背景**全透明**（光晕自己就是背景，见 `VoiceGlowView`），不再是深色圆角卡片；
//  2. 宽度**铺满**、底边**贴屏幕底**（由 `layoutVoicePanel()` 定位），录的时候会盖住输入栏
//     —— 这正是豆包的样子（手指还按着按钮，浮层不吃触摸，手势照常）；
//  3. 去掉了红点与标题；**计时保留**（挪到波形正下方，小字暗色），
//     **实时识别文字保留**（挪到提示语上方）—— 这两样是功能，不是装饰，不能因为对标就砍掉。
//
//  ## 竖直排布（⛔ 数字全是按参考图像素实测换算的，改之前先看图）
//  以**面板底边**为 0，向上为正（单位 pt，参考机 414×896）：
//
//  | 元素 | 中心距底边 | 说明 |
//  |---|---|---|
//  | 计时 | 38 | 豆包没有这项，放最下方深蓝区（不抢视线、白字可读） |
//  | 波形 | **74** | 实测带子中心 y=1643px ⇒ 距底 74.5pt |
//  | 提示语 | **122** | 实测文字中心 y=1532px ⇒ 距底 130pt，这里略压低一点给识别文字让位 |
//  | 识别文字 | 158 | 豆包没有这一行（它的识别结果显示在输入区），本 App 需要 |
//
//  ⚠️ 位置一律用「显式高度 + bottom 偏移」钉死（`pinToBottom`），⛔ 不要用
//  `centerY.equalToSuperview()` 之类的相对约束 —— 那样位置会被字体度量偷偷带偏。
//
//  ## 动画
//  - 波形：滚动历史 + 帧间平滑（在 `VoiceWaveformView` 内），围绕中轴上下对称生长；
//  - 光晕：**呼吸**（缩放 0.985↔1.015 + 透明度 0.90↔1.0，2.6s 往复）——
//    豆包那块蓝是有轻微脉动的，静止会显得像张静态图。
//
//  ⚠️ `isUserInteractionEnabled = false` 是硬要求：浮层绝不能吃掉触摸，
//  否则「按住说话」的手势会被打断（浮层现在盖住了按钮本身，更不能吃）。
//

import UIKit
import SnapKit
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

final class VoiceRecordingPanel: UIView {

    // MARK: - 尺寸

    /// 面板高度（pt）。光晕的 t=1 落在距底 300pt ⇒ 310 保证顶部边界完全透明、不会切出一条横线。
    static let preferredHeight: CGFloat = 310

    // MARK: - 子视图

    /// 底部蓝光（豆包那道的本体）。⛔ 几何参数全在 `VoiceGlowView` 的默认值里，别在这抄一份。
    private lazy var glowView = VoiceGlowView()

    /// 波形带（白色细刻度）。⛔ 几何同样在视图自己的默认值里，这里**只改颜色**。
    private lazy var waveformView: VoiceWaveformView = {
        let view = VoiceWaveformView()
        view.barColor = Self.barColor
        return view
    }()

    /// 实时识别文字（空时显示占位提示）。豆包没有这一行，是本 App 的功能件。
    private lazy var transcriptLabel: UILabel = {
        let label = UILabel()
        label.text = L("请开始说话…")
        label.textColor = Self.placeholderColor
        label.font = .systemFont(ofSize: 14)
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingHead
        label.textAlignment = .center
        return label
    }()

    /// 操作提示（豆包原文案：松手发送，上移取消）
    private lazy var hintLabel: UILabel = {
        let label = UILabel()
        label.text = Self.hintText
        label.textColor = Self.hintColor
        label.font = .systemFont(ofSize: 15)
        label.textAlignment = .center
        return label
    }()

    /// 录音时长（豆包没有，本 App 保留；放最深蓝那一段，不抢视线）
    private lazy var timerLabel: UILabel = {
        let label = UILabel()
        label.text = "0:00"
        label.textColor = Self.timerColor
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        label.textAlignment = .center
        return label
    }()

    // MARK: - 颜色（单点：取消态要成套换，分散写必漂）

    private static let barColor = UIColor.white
    private static let hintColor = UIColor(white: 1, alpha: 0.78)
    private static let placeholderColor = UIColor(white: 1, alpha: 0.58)
    private static let transcriptColor = UIColor(white: 1, alpha: 0.95)
    private static let timerColor = UIColor(white: 1, alpha: 0.55)
    private static let cancelColor = UIColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 0.95)

    /// 🔴 两条都是**计算属性**（2026-10-13）：`static let` 会把 `L()` 的结果进程级缓存住
    ///    ⇒ 切语言后永远停在旧语言那份（iOS 那边重建 rootViewController 也救不回来）。
    private static var hintText: String { L("松手发送，上移取消") }
    private static var cancelHintText: String { L("松手取消") }

    private var startDate = Date()
    /// 是否处于「上移取消」提示态
    private var isCancelling = false
    /// 光晕呼吸动画是否已挂上（`show` 挂、`dismiss` 摘）
    private var isBreathing = false

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        setupUI()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        addSubview(glowView)
        [waveformView, timerLabel, hintLabel, transcriptLabel].forEach { addSubview($0) }

        glowView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        // 波形铺满整宽（带子在其中自己居中），中心距底 74pt
        pinToBottom(waveformView, centerAboveBottom: 74, height: 60, fullWidth: true)
        pinToBottom(timerLabel, centerAboveBottom: 38, height: 16)
        pinToBottom(hintLabel, centerAboveBottom: 122, height: 20)
        pinToBottom(transcriptLabel, centerAboveBottom: 158, height: 20)
    }

    /// 把视图钉在「竖直中心距面板底边 h pt」处。
    /// 显式给高度 ⇒ 位置精确，⛔ 不依赖字体度量（`centerY.equalToSuperview()` 那种写法会被行高带偏）。
    ///
    /// ⚠️ 非满宽的那几个标签用 `leading/trailing.inset(24)` 而不是「centerX + 两边大于等于」：
    /// 后者在文案超宽时会撞上 UILabel 的压缩阻力（750）⇒ 报约束冲突。整宽 + 居中对齐才是稳的。
    private func pinToBottom(_ item: UIView, centerAboveBottom h: CGFloat, height: CGFloat, fullWidth: Bool = false) {
        item.snp.makeConstraints { make in
            if fullWidth {
                make.leading.trailing.equalToSuperview()
            } else {
                make.leading.trailing.equalToSuperview().inset(24)
            }
            make.height.equalTo(height)
            make.bottom.equalToSuperview().offset(-(h - height / 2))
        }
    }

    // MARK: - 对外

    func show(in parent: UIView) {
        guard superview == nil else { return }
        startDate = Date()
        isCancelling = false
        timerLabel.text = "0:00"
        transcriptLabel.text = L("请开始说话…")
        transcriptLabel.textColor = Self.placeholderColor
        hintLabel.text = Self.hintText
        hintLabel.textColor = Self.hintColor
        waveformView.barColor = Self.barColor
        waveformView.reset()
        alpha = 0

        parent.addSubview(self)
        startBreathing()
        UIView.animate(withDuration: 0.18) { self.alpha = 1 }
    }

    func dismiss() {
        guard superview != nil else { return }
        stopBreathing()
        waveformView.reset()
        UIView.animate(withDuration: 0.15, animations: { self.alpha = 0 }) { _ in
            self.removeFromSuperview()
            self.alpha = 1
        }
    }

    /// 推进一帧音量 + 刷新计时
    func update(level: Float) {
        waveformView.push(level: level)
        let elapsed = Int(Date().timeIntervalSince(startDate))
        timerLabel.text = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
    }

    /// 刷新实时识别文字
    func updateTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            transcriptLabel.text = L("请开始说话…")
            transcriptLabel.textColor = Self.placeholderColor
        } else {
            transcriptLabel.text = trimmed
            transcriptLabel.textColor = Self.transcriptColor
        }
    }

    /// 「上移取消」提示态（手指移出按钮）
    func setCancelling(_ cancelling: Bool) {
        guard cancelling != isCancelling else { return }
        isCancelling = cancelling
        hintLabel.text = cancelling ? Self.cancelHintText : Self.hintText
        hintLabel.textColor = cancelling ? Self.cancelColor : Self.hintColor
        waveformView.barColor = cancelling ? Self.cancelColor : Self.barColor
        // 光晕压暗一档：整块「要撤了」的反馈比只变几根细条清楚得多
        glowView.alpha = cancelling ? 0.78 : 1
    }

    // MARK: - 光晕呼吸

    private func startBreathing() {
        guard !isBreathing else { return }
        isBreathing = true

        let timing = CAMediaTimingFunction(name: .easeInEaseOut)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.985
        scale.toValue = 1.015
        scale.duration = 2.6
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = timing
        glowView.layer.add(scale, forKey: "voiceGlowBreathe")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.90
        fade.toValue = 1.0
        fade.duration = 2.6
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = timing
        glowView.layer.add(fade, forKey: "voiceGlowBreatheFade")
    }

    private func stopBreathing() {
        guard isBreathing else { return }
        isBreathing = false
        glowView.layer.removeAnimation(forKey: "voiceGlowBreathe")
        glowView.layer.removeAnimation(forKey: "voiceGlowBreatheFade")
    }
}
