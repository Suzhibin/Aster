//
//  MathBlockView.swift
//  AsterMac
//
//  块级公式（`$$...$$` / ```math）在 Mac 上的显示单元。
//
//  ## 为什么是 `Image` 而不是 `MTMathUILabel`（NSViewRepresentable）
//  公式的排版与绘制全在业务层（`AIPlatformMath.render` → `AIMathBlockMetrics`），这里只铺图：
//   ① 🔴 离屏渲染台（`render_mac_ui.sh` 的 `ImageRenderer`）**照不到 `NSViewRepresentable`**
//      （只画「黄条 + ⊘」）⇒ 用 NSView 包进来，这一块的自动化验收就全瞎了；
//      `Image` 是纯 SwiftUI，离屏照得出。
//   ② 与 iOS 侧同一套分工（业务层给尺寸、视图层只画），两端不会各算一套。
//
//  ## 墨色
//  `AIMathBlockMetrics.image` 要一个 `NSColor`。这里传 `NSColor.labelColor`（**语义色**），
//  而不是 `MacTheme.bodyColor`（SwiftUI `Color`）：macOS 侧 SwiftMath 用
//  `NSImage(size:flipped:drawingHandler:)` **延迟绘制**，语义色会在真正落笔那一刻按
//  当前 appearance 解析 —— 明暗两档天然正确。
//  ⚠️ `inkKey` 仍按 `colorScheme` 分档：缓存键必须能区分，否则同一张图会在
//     两档外观间被反复覆盖（macOS 上两张内容可能相同，但那属于「缓存多一份」，
//     比「颜色用错一档」便宜得多）。
//

import SwiftUI
import AppKit
import AICore

struct MathBlockView: View {

    /// 公式源码（已去掉 `$$` / 围栏）
    let latex: String
    /// 正文可用宽 —— 超宽公式按它等比缩小
    let maxWidth: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let result = AIMathBlockMetrics.image(
            for: latex,
            width: maxWidth,
            inkKey: colorScheme == .dark ? "dark" : "light",
            color: .labelColor
        ) {
            Image(nsImage: result.image)
                // `resizable` 是必需的：`displaySize` 可能**小于**图的原始尺寸（超宽被缩过）
                .resizable()
                .interpolation(.high)
                .frame(width: result.displaySize.width, height: result.displaySize.height)
                .padding(.vertical, AIMathBlockMetrics.paddingV)
                // 左对齐：公式与正文左边齐，不在整行里居中漂浮
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            fallback
        }
    }

    /// 排不出（LaTeX 语法错 / 只有空白）⇒ 显示**源码**，别让这块凭空消失。
    ///
    /// ⚠️ 颜色由视图层的 `.foregroundStyle` 给（语义色），⛔ 别写进 run 属性 ——
    ///    那正是 `MacDownInk` 记录了整篇的坑（run 属性压过视图层，深色下黑字写深底）。
    private var fallback: some View {
        Text(latex)
            .font(MacTheme.code)
            .foregroundStyle(MacTheme.bodyColor.opacity(0.7))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, AIMathBlockMetrics.paddingV)
    }
}
