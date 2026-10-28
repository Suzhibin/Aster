import UIKit
import SnapKit
import AICore

/// 「AI 正在返回数据」的三点等待指示 —— 只在**气泡内、首字到达之前**显示。
///
/// 它补的是这一段空窗：发送后 `AIChatManager` 立刻插一个空文本行
/// （`appendRow(.text("", streaming: true))`），而第一个字要等 TTFB（常见 1–3s，思考模式更久）。这段时间里：
/// - `configureStreaming` 的 `text.isEmpty ? "" : text + "▍"` 把光标也去掉了，气泡里什么都没有；
/// - 气泡宽度由 textView 内容撑 → 空文本时只剩左右 inset → 一块约 24×41pt 的**空白胶囊**；
/// - 全屏唯一的反馈是输入栏那颗「+」变成了「停止」，而用户的视线在消息流里。
///
/// ⚠️ **「气泡宽度由正文撑」这条在等待态是失效的**（2026-09-19 修）：空串 `UITextView` 的
/// `intrinsicContentSize.width` 是 `noIntrinsicMetric`（不是 0）→ 气泡**宽度这一维没有来源**，
/// Auto Layout 对欠定维度只能保持当前 frame → 被复用的 cell 会把上一条（通常很长）的宽度
/// **原样带过来**，表现为「等待时气泡反而最宽」。所以三点这一段**必须由持有者把宽度钉住**，
/// 不能指望正文把它撑出来 —— 见 `AIAssistantTextCell.bubbleWidthPin`。
///
/// ## 三条不这么写就坏
/// 1. 🔴 **必须幂等**：`configureStreaming` 在流式期间每个 tick 都被调（`revealInterval 0.03`
///    ≈ 每秒 33 次）。每次都重建动画 → 点点根本不跳（或只闪一下）。`setAnimating(_:)`
///    在状态未变时直接 return。
/// 2. ⛔ **动画要在 `didMoveToWindow` 里重建**：视图离开 window 时 Core Animation 会把动画摘掉，
///    滚出屏幕再滚回来若不重建 = 三个静止的点。
/// 3. ⚠️ **颜色不能用语义色**（`.label` / `.secondaryLabel`）：助手气泡是固定浅底
///    （`UIColor(white: 0.95)`，不跟暗黑模式变），语义色在暗黑模式下变浅 → 点直接看不见。
///    理由与 `AITypography.bodyColor` 完全相同。
///
/// 关于尺寸：本视图**不 override `intrinsicContentSize`** —— 尺寸统一由 `intrinsicSize` 暴露，
/// 由持有者（`AIAssistantTextCell`）显式给宽高约束。这样「三点算多宽」只有一个来源，
/// 气泡最小宽度那份也能直接引用它。
final class AITypingIndicatorView: UIView {

    /// 单颗圆点直径
    private static let dotSize: CGFloat = 6
    /// 圆点间距
    private static let spacing: CGFloat = 4
    /// 单颗点「亮→灭」的半周期（一整个循环 = 0.6 × 2 = 1.2s）
    private static let blinkDuration: CFTimeInterval = 0.6
    /// 相邻两颗点的相位差 —— 三个数字错开就形成「波浪」
    private static let phaseStep: CFTimeInterval = 0.2
    /// 动画 key：**精确移除**用（`removeAllAnimations()` 会连别人的动画一起清掉）
    private static let blinkKey = "ai.typing.blink"

    /// 三点自身的固有尺寸（宽 = 3 颗点 + 2 段间距）。持有者按它给约束。
    static let intrinsicSize = CGSize(width: dotSize * 3 + spacing * 2, height: dotSize)

    private let dots = (0..<3).map { _ in UIView() }
    /// 当前是否处于「跳动中」。⛔ 不能用「layer 上有没有动画」代替 —— 它在滚出屏幕时会被动摘掉。
    private var animating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        // 纯装饰：不参与命中测试（长按/轻点的判定不该被它插一脚）
        isUserInteractionEnabled = false
        for (index, dot) in dots.enumerated() {
            dot.backgroundColor = AITypography.typingDotColor
            dot.layer.cornerRadius = Self.dotSize / 2
            addSubview(dot)
            dot.snp.makeConstraints { make in
                make.centerY.equalToSuperview()
                make.width.height.equalTo(Self.dotSize)
                if index == 0 {
                    make.leading.equalToSuperview()
                } else {
                    make.leading.equalTo(dots[index - 1].snp.trailing).offset(Self.spacing)
                }
            }
        }
        dots.last?.snp.makeConstraints { make in
            make.trailing.equalToSuperview()
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 启停

    /// 开始/停止跳动。**幂等**：状态没变时什么都不做 —— 这个方法每秒会被调几十次。
    func setAnimating(_ on: Bool) {
        guard on != animating else { return }
        animating = on
        if on {
            startBlinking()
        } else {
            stopBlinking()
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // 离开 window 时 CA 会把动画摘掉 → 回到屏上必须重建，
        // 否则「滚出去再滚回来」是一组静止的点（看起来就是卡住了）
        guard animating else { return }
        if window == nil {
            stopBlinking()
        } else {
            startBlinking()
        }
    }

    // MARK: - 私有

    private func startBlinking() {
        // 不在屏上就先不加动画，等 `didMoveToWindow` 补
        guard window != nil else { return }
        for (index, dot) in dots.enumerated() {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1.0
            anim.toValue = 0.25
            anim.duration = Self.blinkDuration
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // ⚠️ 相位差用 `timeOffset` 而不是 `beginTime` 偏移：
            // `beginTime = now + 0.2` 会让那颗点在头 0.2s 内**还没开始动画**（保持全亮），
            // 开局三颗一样亮、看不出波浪。`timeOffset` 是「从循环的这个相位切入」，立刻就错开。
            anim.timeOffset = Double(index) * Self.phaseStep
            dot.layer.add(anim, forKey: Self.blinkKey)
        }
    }

    private func stopBlinking() {
        for dot in dots {
            dot.layer.removeAnimation(forKey: Self.blinkKey)
            // 复位到全亮：动画被移除时属性会回落到 model 值，不复位会留下半透明的点
            dot.layer.opacity = 1
        }
    }
}
