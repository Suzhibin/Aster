//
//  AIProviderIcon.swift
//  AICore
//
//  把 `AIPlatform.AIVendorIcon` 接到业务类型上（App 侧只 `import AICore`，
//  看不到 AIPlatform 这个非 product 的 target）。
//
//  ⚠️ 这里只转发、不实现 —— 「asset 优先 / SF Symbols 兜底」的规则**只有一份**，
//  在两个 App 的两套渲染代码里各写一遍必然会漂移（一边改了退路、另一边没改，
//  症状还是那种「只有一台机器上图不对」的低可见度 bug）。
//

import Foundation
import AIPlatform

public extension AIProviderKind {

    /// 供应商图标（asset 优先，SF Symbols 兜底）。
    ///
    /// - Parameter pointSize: **只影响 SF Symbol 的绘制尺寸**；asset 是原始尺寸矢量图，
    ///   显示大小交给容器（详见 `AIVendorIcon.image` 的注释）。
    /// - Note: 着色方式跟着 `iconKeepsBrandColor` 走 —— Kimi 的官方 app-icon 标必须原色，
    ///   其余四家是单色记号（template 跟随文字色）。⛔ 别在这里写死 `.tinted`。
    func iconImage(pointSize: CGFloat) -> AIPlatformImage? {
        AIVendorIcon.image(asset: iconAssetName,
                           symbol: symbolName,
                           pointSize: pointSize,
                           rendering: iconKeepsBrandColor ? .brandColor : .tinted)
    }
}
