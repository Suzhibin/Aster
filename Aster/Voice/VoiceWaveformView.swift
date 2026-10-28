//
//  VoiceWaveformView.swift
//  AIModule
//
//  录音波形：一条**细密刻度条带**，条高由实时音量驱动。
//
//  ## 形态来源（2026-10-03 改版；两张参考图都量过）
//  用户拿豆包语音输入的截图来对标 ⇒ 按像素实测了 828×1792 @2x 的图，取下半部那条带子：
//
//  | 量 | 实测（px@2x） | 换算（pt） |
//  |---|---|---|
//  | 条宽 | 6 | **3** |
//  | 条间距 | 4 | **2** |
//  | 条数 | 46 | 46 |
//  | 带子总宽 | 456 | **228**（屏幕 414pt 的 55%，居中） |
//  | 基线条高 | 12 | **6** |
//  | 最高条高 | 56 | **28**（音量拉满封顶） |
//  | 条形状 | 圆头 | 圆角 = 条宽/2（胶囊端） |
//  | 中轴对称 | 46 根中心跨 0.5px | 上下对称生长，⛔ 不是从底部长上来 |
//
//  ⇒ 三条与旧版相反的结论，别再改回去：
//  1. 🔴 **条宽固定 3pt，不再「视图宽度 ÷ 条数」反推**。反推在宽面板上会把每根条拉成药丸
//    （mac 侧早就因此加了封顶，见 `MacTheme.voiceWaveformMaxBarWidth`）；iOS 干脆改成**带子居中、不拉伸**。
//  2. 🔴 **去掉「对称包络（中间高两侧低）」**。豆包那条带子上**没有任何空间包络** ——
//    峰值散落在各处（实测峰值在第 3/7/14/19/23/27/28/33/38/43 根），不是中间拱起来。
//    旧版那个包络是「等比高柱子更像真实波段」的推论，实测不成立。
//  3. 🔴 **基线要可见**（6pt）。旧版 `minBarHeight = 4` 配 6.8pt 宽的条，静音时是一排小方块；
//    现在是「一排小刻度」——这才是那条带子的本体，音量只是让刻度长高。
//
//  ☠️ **别再说「豆包那条带子是平的」**（2026-10-03 修过一次误判）：第一版量的时候把阈值卡在
//  `min(r,g,b)>235`，而那张图整体偏亮、条的边缘像素压在 215~235，结果**只量到中间那 12px 的一横条**
//  ⇒ 误判成「46 根全等高」。换 `>215` 复测，同一张图立刻显出 188/282 的柱状剖面（有高有矮）。
//  教训：**量之前先用「松阈值 + 逐行计数」确认带的上下界**，⛔ 不要一上来就卡紧阈值。
//
//  仍然保留的两条（与旧版一致、也与 mac 侧同口径）：
//  - **滚动历史**：每次推进 `removeFirst + append`，肉眼是波形在流动；
//  - **帧间平滑**：每根条 `displayed += (target - displayed) * 0.55`。
//    🔴 这一条正是「`22 42 22` / `22 40 56 40 22` 那种尖峰带肩」形状的来源
//    （实测豆包高频出现「高点两侧各矮一档」），⛔ 别去掉平滑 —— 去掉就变成一排乱跳的等宽方块。
//

import UIKit

final class VoiceWaveformView: UIView {

    // MARK: - 几何（默认值 = 豆包实测值；⛔ 别在调用处再抄一份，单点在这）

    /// 每根条的宽度（pt）。**固定值**，不随视图宽度变化。
    var barWidth: CGFloat = 3
    /// 条间距（pt）
    var barSpacing: CGFloat = 2
    /// 条数（决定带子总宽：条数 × 条宽 + (条数-1) × 间距）
    var barCount: Int = 46 { didSet { rebuildBars() } }
    /// 基线条高（pt）—— 就是那条「刻度线」的高度，**不能是 0**
    var minBarHeight: CGFloat = 6
    /// 音量拉满时的条高（pt）。实测豆包最高 56px = 28pt。
    var maxBarHeight: CGFloat = 28
    /// 竖条颜色
    var barColor: UIColor = .white { didSet { bars.forEach { $0.backgroundColor = barColor } } }

    private var bars: [UIView] = []
    /// 滚动历史（队尾最新）
    private var history: [CGFloat] = []
    /// 实际绘制高度（已平滑），与 history 一一对应
    private var displayed: [CGFloat] = []

    // 由 layoutSubviews 算出的落点（条宽会被「窄屏兜底」微调，故必须缓存下来给 applyHistory 用）
    private var laidOutBarWidth: CGFloat = 0
    private var laidOutBarSpacing: CGFloat = 0
    private var laidOutOriginX: CGFloat = 0
    private var hasLaidOut = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        history = Array(repeating: 0, count: barCount)
        displayed = Array(repeating: 0, count: barCount)
        rebuildBars()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 对外

    /// 推进一帧音量（0~1）
    func push(level: Float) {
        guard !history.isEmpty else { return }
        let value = CGFloat(min(max(level, 0), 1))
        history.removeFirst()
        history.append(value)
        applyHistory()
    }

    /// 复位到静音（基线高度那排刻度）
    func reset() {
        history = Array(repeating: 0, count: barCount)
        displayed = Array(repeating: 0, count: barCount)
        applyHistory()
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !bars.isEmpty else { return }

        let count = CGFloat(bars.count)
        let natural = barWidth * count + barSpacing * (count - 1)
        // 窄屏兜底：带子比可用宽度还长时整体等比压一压（iPhone 上 228 < 可用宽，永远走不到；
        // 这是给分屏 / 极端窄场景留的安全阀，⛔ 不要因此把 barWidth 改成「反推」）
        let scale = (natural > bounds.width && natural > 0) ? bounds.width / natural : 1
        laidOutBarWidth = max(1.5, barWidth * scale)
        laidOutBarSpacing = max(1, barSpacing * scale)

        let bandWidth = laidOutBarWidth * count + laidOutBarSpacing * (count - 1)
        // 🔴 带子**整组居中**：左右留白对等（旧版是从左边贴边铺满）
        laidOutOriginX = (bounds.width - bandWidth) / 2
        hasLaidOut = true

        applyHistory()
    }

    private func rebuildBars() {
        bars.forEach { $0.removeFromSuperview() }
        bars = (0..<barCount).map { _ in
            let bar = UIView()
            bar.backgroundColor = barColor
            bar.layer.masksToBounds = true
            addSubview(bar)
            return bar
        }
        if history.count != barCount {
            history = Array(repeating: 0, count: barCount)
            displayed = Array(repeating: 0, count: barCount)
        }
        setNeedsLayout()
    }

    /// 按 history 重排所有竖条（围绕水平中轴**上下对称**生长）
    private func applyHistory() {
        guard bars.count == history.count, hasLaidOut, bounds.height > 0 else { return }

        let maxHeight = min(maxBarHeight, bounds.height)
        let minHeight = min(minBarHeight, maxHeight)
        // 圆头：半径恒为条宽的一半 ⇒ 不管长多高都是胶囊端（豆包那排就是这个形状）
        let cornerRadius = laidOutBarWidth / 2

        var x = laidOutOriginX
        for (index, bar) in bars.enumerated() {
            let target = minHeight + (maxHeight - minHeight) * history[index]
            // 帧间平滑：目标变化时跟一部分，避免跳动
            displayed[index] += (target - displayed[index]) * 0.55
            let height = max(minHeight, min(displayed[index], maxHeight))

            bar.layer.cornerRadius = cornerRadius
            bar.frame = CGRect(x: x,
                               y: (bounds.height - height) * 0.5,
                               width: laidOutBarWidth,
                               height: height)
            x += laidOutBarWidth + laidOutBarSpacing
        }
    }
}
