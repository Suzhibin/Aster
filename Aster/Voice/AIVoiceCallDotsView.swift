//
//  AIVoiceCallDotsView.swift
//  Aster
//
//  通话页提示语上方那**三个点**（2026-10-11；参考图 `Clipboard_Screenshot*.png`）。
//
//  ## 它替掉的是什么
//  原先这个位置是一块 18pt 的**静态小方块**（照 IMG_3166 还原的）。用户反馈"不符合需求"：
//  真实形态是**三个点**，而且是**音量指示** —— 说话时点会随音量上下长大、变小。
//
//  ## 参考图上量到的口径（两张图是同一台机、同一比例的裁切）
//  | 项 | 参考图实测 | 落成的常量 |
//  |---|---|---|
//  | 单点尺寸（静止） | 21 × 20 px 的正圆 | `indicatorDotDiameter` |
//  | 相邻圆心距 | 28 / 29 px | 直径 + `indicatorDotGap` |
//  | 拉伸后 | 21 × **34** px（高/宽 = 1.62） | `indicatorDotMaxHeight` |
//  | 三个点的**圆心在同一条 y** 上 | 两张图都是 201.5 / 197.5 | 点在承载盒内**恒居中** |
//
//  ⚠️ **幅度已被主动放大**（2026-10-12，用户反馈"说话时变化幅度太小"）：
//     拉伸倍率由参考图的 1.62 倍改成 **2.17 倍**（`19 → 26`），驱动增益 `1.25 → 1.45`。
//     ⇒ 上面那张表里"拉伸后"一行是**参考图口径**，不再是本页当前口径；以
//       `AIVoiceCallMetrics.indicatorDotMaxHeight` 为准（那里有完整来历）。
//     契约脚本为此有一条**数值断言**（`max > 直径 × 2.0`）—— 这是本组唯一"跑图看不出来"
//     的一条：把倍率调回去，静音态（三个等大圆点）照样完全正确，只有说话时才发现它没动。
//
//  🔴 最后一行是最容易做错的：拉伸是**上下对称**的 ——
//     两张图里「点下沿 → 文字上沿」从 44px 变成 37px，正好是长高量的一半（7px）。
//  ⇒ 所以**不是**"往上长"也不是"往下长"，而是**圆心不动、朝两头长**。
//    做成"往上长"就变成了蹦起来的球，跟参考图不是一回事。
//
//  ## 🔴 为什么用 `CADisplayLink`，而不是把高度直接接在音量回调上
//  音量回调只有 **25Hz**，而且**不打字就不来**（安静时压根没有回调）——
//  直接接上去，点会一顿一顿、而且一安静就彻底不动。所以这里分两层：
//  回调只更新**目标音量**，真正的形变由 display link 逐帧（60fps）算。
//
//  ## 🔴 波形：**行波**（同一频率、每个点差 1/3 圈）+ 平方曲线
//  每个点高 = 直径 + (最高−直径) × **音量** × `pulse_i`，`pulse_i` 只跟时间有关。
//  两个参数是被实测挑出来的，⛔ 别凭手感改：
//
//  ☠️ **不能让三个点各用不同频率**（第一版就是这么写的，实拍抓到三条同时趴下）。
//     把两种波形各扫 240 帧，统计"每帧最高那条的高度"与"第二高 / 最高"：
//
//  | 波形 | 最高那条的**最低值** | 第二高/最高 的最坏值 | "三条全趴下"的帧 |
//  |---|---|---|---|
//  | 三点各不同频率（1.35/1.10/1.62） | **0.11** | 0.00 | **26 / 240** |
//  | 行波（差 1/3 圈） | **0.56** | 0.06 | **0 / 240** |
//
//  ⇒ 不同频率会周期性地把三条**一起压到谷底**（≈11% 的时间），那一刻指示器看着像"死了"；
//    行波则保证**永远有一条明显最高**，形态恒定是参考图那种「一条拉满、另外两条趴着」。
//
//  ⚠️ 曲线必须**平方**（不能直接用正弦）：三个点相隔 1/3 圈，正弦下相邻两点只差 120°、
//     高度永远差不多 ⇒ 会变成"两条齐高"。平方把波峰压窄、波谷拉平之后，
//     最高那条与第二高的比值才稳定落在 **≤0.25**（正是参考图里 34px 与 22px 的关系）。
//
//  ## ⛔ 别让它常开
//  不在拾音的时候，三点必须是**静止的等大圆点** —— 那才是参考图里的"待机"面孔。
//  ⛔ 别为了"看着有生气"让它常驻动画：那会让"AI 正在听"这件事失去指示意义。
//  ⇒ 开关是 `setActive(_:)`，由控制器在开麦 / 停麦两处**成对**调用。
//

import UIKit

final class AIVoiceCallDotsView: UIView {

    /// 点数（参考图是三个）。
    /// ⚠️ 改它记得连 `indicatorDotGap` / 提示语宽度一起看 —— 整排会变宽。
    private static let dotCount = 3

    /// 相邻两点之间的**相位差**（圈数）。
    /// 🔴 必须是 1/3：三个点在一个波上**均分一圈** ⇒ 任何时刻都"一条在峰、两条在谷"。
    /// ⚠️ 别改成 0.45、0.5 之类：那样总有两个点的相位挤在一起（差 0.9 圈），
    ///    形态会退化成"两条齐高一条矮"（文件头那张表里有实测对比）。
    private static let phaseStep: Double = 1.0 / 3.0

    /// 一个点走完"趴下 → 拉满 → 趴下"的周期（秒）⇒ 波峰每 `cycle/3`(=0.35s) 挪一个点。
    /// 0.35s 一步 ≈ "说话"的节奏；再快像跑马灯、再慢像心跳。
    private static let cycle: Double = 1.05

    // MARK: - 子视图

    private let dots: [UIView] = (0..<AIVoiceCallDotsView.dotCount).map { _ in UIView() }

    // MARK: - 状态

    /// 目标音量（0~1，`VoiceInputManager.onLevel` 的刻度）
    private var targetLevel: CGFloat = 0
    /// 平滑后的音量（逐帧逼近 `targetLevel`）
    private var level: CGFloat = 0
    /// 每帧算出来的高度，`layoutSubviews` 读它。
    /// ⛔ 故意**不用约束**：60fps 改约束会一直触发约束求解，而这里只要改三个 frame。
    private var heights: [CGFloat]

    private var displayLink: CADisplayLink?
    /// 动画的时间原点（`setActive(true)` 那一刻）
    private var phaseClock: CFTimeInterval = 0
    private var isActive = false

    // MARK: - 初始化

    override init(frame: CGRect) {
        let diameter = AIVoiceCallMetrics.indicatorDotDiameter
        heights = Array(repeating: diameter, count: Self.dotCount)
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        for dot in dots {
            dot.backgroundColor = AIVoiceCallPalette.indicatorFill
            dot.layer.cornerRadius = diameter / 2
            dot.isUserInteractionEnabled = false
            addSubview(dot)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // ☠️ display link 会**强引用** target ⇒ 不失效它就是一个不会随本视图释放的定时器。
        //    （`deinit` 是 nonisolated，但 `CADisplayLink.invalidate()` 本身不是隔离方法，
        //     就地调是合法的 —— 与"deinit 里不能调本类 MainActor 方法"是两件事。）
        displayLink?.invalidate()
    }

    // MARK: - 固有尺寸

    /// 整排宽度 = 3 个点 + 2 个间隙（**点数只有这里和 `dots` 知道**，别在父视图里再算一遍）。
    override var intrinsicContentSize: CGSize {
        let diameter = AIVoiceCallMetrics.indicatorDotDiameter
        let gap = AIVoiceCallMetrics.indicatorDotGap
        let count = CGFloat(Self.dotCount)
        return CGSize(width: count * diameter + (count - 1) * gap,
                      height: AIVoiceCallMetrics.indicatorDotMaxHeight)
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = AIVoiceCallMetrics.indicatorDotDiameter
        let gap = AIVoiceCallMetrics.indicatorDotGap
        var x = (bounds.width - intrinsicContentSize.width) / 2
        for (index, dot) in dots.enumerated() {
            // 🔴 恒以盒子**中线**为基准上下对称地长（见文件头那张表）
            let height = heights[index]
            dot.frame = CGRect(x: x, y: (bounds.height - height) / 2,
                               width: diameter, height: height)
            x += diameter + gap
        }
    }

    // MARK: - 对外

    /// 只在**拾音中**开动画（见文件头末段）。关掉时三点回到等大静止。
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            phaseClock = CACurrentMediaTime()
            startDisplayLink()
        } else {
            stopDisplayLink()
            targetLevel = 0
            level = 0
            heights = Array(repeating: AIVoiceCallMetrics.indicatorDotDiameter, count: Self.dotCount)
            setNeedsLayout()
        }
    }

    /// 音量（0~1，`VoiceInputManager.onLevel` 的刻度）。
    /// ⚠️ 这里只**存**目标值，形变在 display link 里算（见文件头）。
    func setLevel(_ level: CGFloat) {
        targetLevel = min(max(level, 0), 1)
    }

    // MARK: - 逐帧

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // ⚠️ `.common`：默认 mode 在滚动 / 手势跟踪时会被挂起（同 `startVAD` 那条规矩）
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        // 平滑：起得快、落得慢（逐帧跑，比 25Hz 的音量回调细得多，所以系数可以小）
        let k: CGFloat = targetLevel > level ? 0.35 : 0.10
        level += (targetLevel - level) * k

        // 麦克风电平的刻度：`-50dB → 0`、`-10dB → 1`，正常说话就落在 0.5~1。
        // ⇒ 本来就是一个能用的刻度，这里抬一点，让中低音量也吃得到上面的高度。
        // 🔴 2026-10-12 用户反馈幅度太小 ⇒ 增益 `1.25 → 1.45`（≈ 0.69 的音量即满幅，
        //    原来是 0.8）。配合 `indicatorDotMaxHeight` 一起放大，两点缺一不可：
        //    只抬上限的话，中低音量仍停在原来的高度上，用户看到的差别很小。
        // ⛔ 但也别一路加到 2.0 以上：那样稍微出点声就恒顶满格，音量大小就分不出来了
        //    （行波还在动，但"随音量起伏"这层信息会丢掉）。
        let drive = min(1, level * 1.45)

        let now = CACurrentMediaTime() - phaseClock
        let diameter = AIVoiceCallMetrics.indicatorDotDiameter
        let span = AIVoiceCallMetrics.indicatorDotMaxHeight - diameter
        let base = now / Self.cycle
        for index in 0..<Self.dotCount {
            // 行波：同一个基准相位，每个点再各差 1/3 圈（见文件头那张实测对比表）
            let phase = base + Double(index) * Self.phaseStep
            let sine = (sin(phase * 2 * Double.pi) + 1) / 2   // 0~1
            let pulse = CGFloat(sine * sine)                  // 平方 ⇒ 波峰窄、波谷平
            // 🔴 只有 `drive` 是外部音量：它一旦是 0（安静），三个点必然**等大** ——
            //    这正是参考图第 1 张那一帧。⛔ 别给它加"最小起伏"，那会让静止态也动起来。
            heights[index] = diameter + span * drive * pulse
        }
        setNeedsLayout()
    }
}
