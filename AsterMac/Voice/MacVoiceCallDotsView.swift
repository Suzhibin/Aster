//
//  MacVoiceCallDotsView.swift
//  AsterMac
//
//  通话窗里那**三个点**（音量指示，2026-10-12）。
//
//  ## 它是什么
//  参考图（`Clipboard_Screenshot*.png`）里，文字上方那三个点是**音量指示**：
//  说话时其中一个被明显拉高、另外两个趴着，安静时三个**等大的圆点**。
//  ⇒ 与 iOS 通话页的 `AIVoiceCallDotsView` 是**同一个东西**，口径也照它抄
//     （那支的成因、实测对比表都在它的文件头里，这里只记差异）。
//
//  ## 🔴 与 iOS 那支的三处差异
//  ① 驱动方式：iOS 用 `CADisplayLink` 逐帧改 frame（那边是 UIKit，改 frame 最便宜）；
//     这边是 SwiftUI ⇒ `TimelineView(.animation(minimumInterval:paused:))`，
//     每一帧给一个 `date`，按它算相位。
//     ☠️ `paused: !isActive` **不能省**：不拾音时让时间线停住，三点才是**静止**的等大圆点
//        （那是"待机"的面孔，也是参考图第一张那一帧）。让时钟空转还会白烧 CPU。
//     ☠️ **别再叠一层平滑**：`VoiceInputManager.emitLevel` 已经按「上升快、回落慢」平滑过
//        （见它的成员注释），iOS 那支之所以还有一层是因为它拿的是原始 level。
//  ② 形状：iOS 是 `UIView` + `cornerRadius = 直径/2`，这边是 `Capsule`。
//     两者拉长后都是**两端半圆的胶囊** —— 观感必须一致，⛔ 别改成 `RoundedRectangle`。
//  ③ 相位基准：iOS 记的是「`setActive(true)` 那一刻」，这边直接用 `TimelineView` 给的
//     绝对时间 ⇒ 每次开麦时**三点所处的形态是随机的**（而不是每次都从"第一个点最高"开始）。
//     这是刻意接受的：通话是长时间驻留的状态，没人会去对比两次开麦的第一帧。
//
//  ## 🔴 波形算法（与 iOS 逐字同参，改之前先读 `AIVoiceCallDotsView` 的文件头）
//  点高 = `直径 + (上限 − 直径) × drive × pulse`，`drive = min(1, level × 增益)`。
//  · **行波**：三个点相位差 1/3 圈（⛔ 不是三个不同频率 —— 那会周期性地把三条一起压到谷底，
//    实测 240 帧里有 26 帧看着像"指示器死了"）；
//  · **平方曲线**：波峰压窄、波谷拉平，保证"一条拉满、两条趴着"（正弦下会变成两条齐高）。
//
//  ## ⛔ 别让它常开
//  不在拾音的时候三点必须是静止的等大圆点。开关是 `isActive`，由模型在开麦 / 停麦
//  两处**成对**给（与 iOS 那条「音量反馈要成对收」是同一条规矩）。
//
//  ⚠️ 离屏渲染（`render_mac_ui.sh`）里 `TimelineView` 的时钟**不跑** ⇒ 渲出来的是
//     「第 0 帧」。这是好事：那张图正好用来验**静止态**（三个等大圆点）。
//     要验"说话时被拉高"，得把 `level` 喂成 1 再 **真窗口**截图
//     （`MacVoiceCallDotsView` 的 level 由模型给，模型有 `STARRY_CALL_LEVEL` 那类钩子可喂）。
//

import SwiftUI

struct MacVoiceCallDotsView: View {

    /// 目标音量 0~1（与 `VoiceInputManager.onLevel` **同刻度**）
    let level: Double

    /// 是否在拾音中。`false` = 时钟停住、三点回到等大静止（见文件头末段）
    let isActive: Bool

    /// 点数。参考图是三个。
    /// ⚠️ 改它要连 `MacVoiceCallTheme.dotBoxWidth` 一起看（那边按 3 个算的宽度）。
    private static let dotCount = 3

    /// 相邻两点的相位差（圈数）。
    /// 🔴 必须是 1/3：三个点在一个波上均分一圈 ⇒ 任何时刻都"一条在峰、两条在谷"。
    private static let phaseStep: Double = 1.0 / 3.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { timeline in
            let heights = Self.heights(at: timeline.date, level: level)
            HStack(alignment: .center, spacing: MacVoiceCallTheme.dotGap) {
                ForEach(Array(heights.enumerated()), id: \.offset) { item in
                    Capsule(style: .continuous)
                        .fill(MacVoiceCallTheme.dot)
                        .frame(width: MacVoiceCallTheme.dotDiameter, height: item.element)
                }
            }
        }
        // ☠️ 承载盒尺寸**恒定**（不是跟着点走）：点朝上下两头长，文字才不会随音量上下抖。
        //    与 iOS 那边 `make.height.equalTo(indicatorDotMaxHeight)` 是同一条口径。
        .frame(width: MacVoiceCallTheme.dotBoxWidth, height: MacVoiceCallTheme.dotBoxHeight)
        // 纯展示，不吃点击（三个点没有任何可点的语义）
        .allowsHitTesting(false)
    }

    /// 这一帧三个点各自的高度（**上下对称**由布局保证：HStack 居中 + 固定盒子高度）。
    private static func heights(at date: Date, level: Double) -> [CGFloat] {
        let diameter = MacVoiceCallTheme.dotDiameter
        let span = MacVoiceCallTheme.dotMaxHeight - diameter

        // 麦克风电平刻度是 `-50dB → 0`、`-10dB → 1`，正常说话落在 0.5~1。
        // ⇒ 乘一个增益让中低音量也吃得到上面的高度（与上限是**一对**，见主题文件）。
        let drive = min(1, max(0, level) * MacVoiceCallTheme.dotGain)
        let base = date.timeIntervalSinceReferenceDate / MacVoiceCallTheme.dotCycle

        return (0..<dotCount).map { index in
            let phase = base + Double(index) * phaseStep
            let sine = (sin(phase * 2 * Double.pi) + 1) / 2      // 0~1
            let pulse = sine * sine                              // 平方 ⇒ 波峰窄、波谷平
            // 🔴 只有 `drive` 是外部音量：它一旦是 0（安静），三个点必然**等大**。
            //    ⛔ 别给它加"最小起伏" —— 那会让静止态也动起来。
            return diameter + span * CGFloat(drive * pulse)
        }
    }
}
