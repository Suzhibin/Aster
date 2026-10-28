//
//  MacProviderIcon.swift
//  AsterMac
//
//  供应商品牌图标（SwiftUI 版）：asset 优先，SF Symbols 兜底。
//
//  ## 为什么不直接 `Image("ProviderDeepSeek")`
//  SwiftUI 的 `Image(_:)` 取不到 asset 时**不报错、不警告**，直接渲染空 ——
//  而「取不到」有三条现实路径（见 `AIVendorIcon` 的头注释）。所以必须先问
//  `NSImage(named:)` 一句，再决定走哪条分支。
//
//  ## 为什么不复用 `AIVendorIcon.image`
//  可以复用它返回的 `NSImage`，但 SwiftUI 侧还得再判「这张是 asset 还是符号」
//  才能决定用 `.resizable().frame()` 还是 `.font()` —— 判两次不如在这里判一次。
//  取图规则本身仍只有一份（`iconAssetName` + `symbolName` 都来自 AICore）。
//

import SwiftUI
import AppKit

struct MacProviderIcon: View {

    /// 品牌 asset 名（`AIProviderKind.iconAssetName`）。nil = 该家没有品牌资产。
    let asset: String?
    /// SF Symbols 兜底名（`AIProviderKind.symbolName`）。
    let symbol: String?
    /// 边长（点）。asset 走 `.frame(width:height:)`；符号走同字号的 `.font(…)`。
    var size: CGFloat
    /// 这张图**自带品牌色**吗（`AIProviderKind.iconKeepsBrandColor`，当前只有 Kimi）。
    /// 默认 false = 单色 template 跟随前景色。
    var keepBrandColor: Bool = false

    var body: some View {
        if let asset, NSImage(named: asset) != nil {
            // ⚠️ `.renderingMode(.template)` 不能省：单色记号本身是纯黑 SVG，
            //    不标 template 的话在深色模式下就是一块看不见的黑。
            // 🔴 但 Kimi 是**官方 app-icon 形态**（黑底方块 + 白 K + 蓝点），必须
            //    `.original` —— 方块 alpha 恒为 1，走 template 会被涂成一块实心色，
            //    K 与蓝点一起消失，而且不报错（见 `AIVendorIconRendering.brandColor`）。
            //    ⚠️ 也别改成 `.foregroundColor`（旧 API）—— 与调用处的
            //    `.foregroundStyle` 统一，深浅色由主题自动决定。
            Image(asset)
                .resizable()
                .renderingMode(keepBrandColor ? .original : .template)
                .scaledToFit()
                .frame(width: size, height: size)
        } else if let symbol {
            Image(systemName: symbol)
                .font(MacTheme.ui(size))
        }
    }
}
