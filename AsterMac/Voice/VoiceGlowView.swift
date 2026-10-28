//
//  VoiceGlowView.swift
//  AsterMac
//
//  豆包式「窗口底部蓝光」底纹（2026-10-03 加）。
//
//  ⚠️ 与 iOS 的 `Aster/Sources/Voice/VoiceGlowView.swift` 是**同一套几何**。
//     完整推导写在那边的文件头（按像素实测 IMG_3124.PNG + 用两处等亮度点联立解出椭圆），
//     ⛔ 这里不重抄结论 —— 两端要看起来是同一个东西，改一边记得看另一边。
//     一句话版：底纹 = **一个扁椭圆的径向渐变**，圆心落在底边上方一点点，
//     屏幕上只露出它的**上帽** ⇒ 边界是一道平缓的弧（用户口中的「半圆形」）。
//
//  ## 实现为什么要绕「压扁」这一步
//  参考图那道蓝光是个**扁椭圆**（rx : ry ≈ 1.414 : 1）的径向渐变，而 SwiftUI 的
//  `RadialGradient` 只会画**正圆**。所以这里先按 rx 画一个正圆渐变、再用
//  `scaleEffect(y: ry / rx)` 把整块压扁 —— 与 iOS 那边 `context.scaleBy(x:1, y:ry/rx)`
//  是同一个手法。⛔ 别改成「画两次半圆拼」或「用 AngularGradient 凑」：
//  那些都不是径向渐变的等亮度线形状，弧会变形。
//
//  ## 宽度自适应：**只放大 rx**
//  Mac 窗口比手机宽得多（600…1400pt），参考机的 `rx = 392` 在宽窗口上会让椭圆够不到两侧。
//  处理办法是**只把 rx 按宽度放大、ry 保持不变** —— 得到「一条更平缓的弧」，
//  垂直尺度恒定，不会让蓝光爬满大半个窗口。理由与那条常量一起写在 `MacTheme` 上。
//

import SwiftUI

struct VoiceGlowView: View {

    var body: some View {
        GeometryReader { geo in
            let rx = max(MacTheme.voiceGlowRadiusX,
                         geo.size.width / 2 * MacTheme.voiceGlowRadiusXToHalfWidth)
            let ry = MacTheme.voiceGlowRadiusY

            // 圆心：水平居中，落在**底边上方** `voiceGlowCenterAboveBottom` 处
            Rectangle()
                .fill(RadialGradient(stops: MacTheme.voiceGlowStops,
                                     center: .center,
                                     startRadius: 0,
                                     endRadius: rx))
                // 先按 rx 画成正圆渐变，再压成 rx × ry 的椭圆
                .frame(width: rx * 2, height: rx * 2)
                .scaleEffect(x: 1, y: ry / rx, anchor: .center)
                // ⚠️ `.position` 用的是**压扁前**的 frame（`scaleEffect` 是纯渲染变换、
                //    不改布局尺寸）⇒ 椭圆中心恰好落在 (中轴, 底边上方 23pt)，正是要的位置。
                // ⚠️ 这块比浮层宽 / 高（rx 可能上千）—— SwiftUI 默认**不裁剪**，溢出照画；
                //    ⛔ 别在这条链上给父级加 `.clipped()`，那会把弧的两端切掉。
                .position(x: geo.size.width / 2,
                          y: geo.size.height - MacTheme.voiceGlowCenterAboveBottom)
        }
        // 纯装饰：一点触摸都不吃（浮层靠这条放行点击到下面的输入栏）
        .allowsHitTesting(false)
    }
}
