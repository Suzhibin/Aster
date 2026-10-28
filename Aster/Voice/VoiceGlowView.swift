//
//  VoiceGlowView.swift
//  AIModule
//
//  豆包式「屏幕底部蓝光」底纹。
//
//  ## 形态（2026-10-03 按像素实测 IMG_3124.PNG 反推，⛔ 别再凭肉眼估）
//  底纹 = **一个扁椭圆的径向渐变**，圆心落在**屏幕底边上方一点点**，
//  屏幕上只露出这个椭圆的**上帽** ⇒ 蓝区的边界是一道平缓的弧
//  —— 这就是用户口中的「半圆形」。☠️ 别把它当成「一个正的半圆」实心形状：
//  那会让顶部边界比实际高一倍，而且颜色是死板的纯色。
//
//  实测（参考图 828×1792 @2x ⇒ 414×896pt）量出来的三个数：
//
//  | 量 | 值（pt） | 怎么来的 |
//  |---|---|---|
//  | 圆心高于面板底边 | **23** | 用「弧在屏幕边缘 vs 弧在正中」两处等亮度点联立解出 |
//  | 横向半径 rx | **392** | 同一次联立解得 rx = 1.414·ry |
//  | 纵向半径 ry | **277** | 让 t=1 落在「蓝彻底看不见」的 h≈300pt 上 |
//
//  用这三个数反推的两条边界，与实测核对：
//  - 弧顶（正中）：模型 244.6pt，实测 **246.5pt**
//  - 弧在屏幕左右边缘：模型 189.5pt，实测 **193pt**
//  ⇒ 误差 < 5pt，够用。
//
//  ## 颜色
//  沿中轴的实测色（下→上）直接当渐变站点（见 `stops`）：
//  底边是深蓝 rgb(53,117,237)，往上逐渐变浅，h≈300pt 处白到透明。
//  ⚠️ 上半段是**透明**的（不是白色）—— 录音时聊天内容要能透出来，这也是豆包的样子。
//

import UIKit

final class VoiceGlowView: UIView {

    // MARK: - 几何（默认值 = 豆包实测值；⛔ 别在调用处再抄一份）

    /// 椭圆圆心高于**面板底边**的距离（pt）
    var glowCenterAboveBottom: CGFloat = 23
    /// 椭圆横向半径（pt）
    var glowRadiusX: CGFloat = 392
    /// 椭圆纵向半径（pt）
    var glowRadiusY: CGFloat = 277

    /// 渐变站点（位置, r, g, b, a）—— 位置是**归一化椭圆距离** t（0=圆心，1=椭圆边界）
    ///
    /// 🔴 **收尾三段（t ≥ 0.71）刻意带 alpha、且逐段降到 0**（2026-10-03 补）。
    ///    参考图是**浅色**界面截的，那一带的「白」其实是「蓝光淡到几乎没有、露出浅色底」的观感；
    ///    照抄成不透明的近白（a=1），**深色模式下会在弧顶糊出一条刺眼的白墙**
    ///    （mac 侧 `voice_panel_dark` 那张验收图上是一眼可见的）。
    ///    带 alpha 之后：浅色底下合成值几乎不变（0.71 处 212 vs 205），深色底下则自然淡入深底。
    ///    ⚠️ 这一组数与 mac 侧 `MacTheme.voiceGlowStops` **逐字相同**，改一边记得改另一边。
    private static let stops: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (0.00,  46, 105, 234, 1.00),
        (0.20,  52, 114, 237, 1.00),
        (0.39,  64, 130, 239, 1.00),
        (0.50,  92, 152, 242, 1.00),
        (0.60, 150, 195, 247, 1.00),
        (0.71, 205, 228, 252, 0.75),
        (0.82, 244, 249, 254, 0.62),
        (0.93, 251, 253, 255, 0.28),
        (1.00, 253, 254, 255, 0.00),
    ]

    private static let gradient: CGGradient? = {
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = stops.map { UIColor(red: $0.1 / 255, green: $0.2 / 255, blue: $0.3 / 255, alpha: $0.4).cgColor }
        let locations = stops.map { $0.0 }
        return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        // 尺寸变了要重画（旋转 / 分屏）；平时只画一次
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let gradient = Self.gradient else { return }
        guard bounds.width > 0, bounds.height > 0, glowRadiusY > 0 else { return }

        // 圆心：水平居中，落在面板底边**上方** glowCenterAboveBottom 处
        let center = CGPoint(x: bounds.midX, y: bounds.maxY - glowCenterAboveBottom)

        context.saveGState()
        // 把坐标系压扁 ⇒ 画出来的「圆」就是那个扁椭圆（⛔ 别改成两次 fill 拼）
        context.translateBy(x: center.x, y: center.y)
        context.scaleBy(x: 1, y: glowRadiusY / glowRadiusX)
        context.drawRadialGradient(gradient,
                                   startCenter: .zero, startRadius: 0,
                                   endCenter: .zero, endRadius: glowRadiusX,
                                   options: [])
        context.restoreGState()
    }
}
