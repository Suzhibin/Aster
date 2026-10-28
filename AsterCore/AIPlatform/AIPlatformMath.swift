//
//  AIPlatformMath.swift
//  AIPlatform
//
//  LaTeX 数学公式 → **位图**（跨平台接缝）。
//
//  ## 为什么用 `MTMathImage` 而不是 `MTMathUILabel`
//  `MTMathUILabel` 在 iOS 是 `UIView`、macOS 是 `NSView`，两个都是**视图**：
//   ① `AIMarkdown.contentHeight` 是 nonisolated 的纯计算，可能被后台线程调用，
//      而后台建视图是不安全的（SPM 包没有 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
//      编译器不会替我们挡住）；
//   ② Mac 侧助手正文是 SwiftUI，接 NSView 只能走 `NSViewRepresentable`，
//      而**离屏渲染台照不到 NSViewRepresentable**（只画「黄条 + ⊘」）⇒ 自动化验收全瞎。
//
//  `MTMathImage.asImage()` 是纯 CoreText：自己排版、自己画进位图，**整个过程不碰任何视图**
//  ⇒ 后台可调、离屏可画、两端代码完全一致（`MTColor` 就是 `UIColor`/`NSColor`，
//  `MTImage` 就是 `UIImage`/`NSImage`，见 SwiftMath 的 `MTConfig.swift`）。
//  所以本文件**没有任何 `#if`** —— 平台差异在这一层已经不存在了。
//
//  ## ⛔ 这里不做主题色
//  墨色由调用方传（`color`）：主题语义色属于视图层（`MacTheme` / iOS `.label`）。
//  本层只负责「给定颜色，排一次版，画一张图」。
//
//  ## ⚠️ 没有自动折行
//  `MTMathImage` 没有 `preferredMaxLayoutWidth`（那是 `MTMathUILabel` 才有的）。
//  超宽公式的处置放在 `AIMathBlockMetrics`：按比例缩小到可用宽（`displaySize`），
//  保证「整条公式看得全」而不是被裁掉一半。
//

import Foundation
import CoreGraphics
import SwiftMath

public enum AIPlatformMath {

    /// 一次排版，同时给出**尺寸**与**位图**。
    ///
    /// - Note: 两者出自同一次 `asImage()` ⇒ 「量出来的高」就是「图上屏后的高」，
    ///   不会出现「量的时候按一套、画的时候按另一套」。
    /// - Returns: `nil` 表示 LaTeX 非法 / 排不出东西 —— 调用方**降级显示源码**。
    public static func render(
        latex: String,
        fontSize: CGFloat,
        color: AIPlatformColor
    ) -> (size: CGSize, image: AIPlatformImage)? {
        layout(latex: latex, fontSize: fontSize, color: color, mode: .display)
    }

    /// **行内**公式（`$...$` / `\(...\)`）：与 `render` 同一套流程，只有排版模式不同。
    ///
    /// 🔴 `labelMode: .text` 不是可有可无的细节：display 模式会**放大**积分号、求和号、
    ///    分式并加额外的上下留白 —— 那是「独立成行」的排版惯例。塞进一句话中间时，
    ///    它会比周围文字高出半行，把整段行距撑歪。`.text` 才是 LaTeX 对行内公式的正式排版。
    public static func renderInline(
        latex: String,
        fontSize: CGFloat,
        color: AIPlatformColor
    ) -> (size: CGSize, image: AIPlatformImage)? {
        layout(latex: latex, fontSize: fontSize, color: color, mode: .text)
    }

    private static func layout(
        latex: String,
        fontSize: CGFloat,
        color: AIPlatformColor,
        mode: MTMathUILabelMode
    ) -> (size: CGSize, image: AIPlatformImage)? {
        let renderer = MTMathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: color,          // MTColor == AIPlatformColor
            labelMode: mode,
            textAlignment: .left       // 与正文左边对齐，别在气泡里浮动居中
        )
        let (error, image) = renderer.asImage()
        guard error == nil, let image = image else { return nil }
        // 尺寸**从位图本身取**：`MTMathImage.intrinsicContentSize` 的 getter 是默认
        // `internal`（`private(set)` 只放开了 setter）⇒ 跨模块读不到。
        // 而 `asImage()` 正是按那个尺寸建的位图：`UIImage.size` / `NSImage.size`
        // 都是 **point** 尺寸 ⇒ 这里取到的就是排版尺寸，与图同源。
        let size = image.size
        // 排出来了但尺寸为 0（空公式 / 只有空白）⇒ 当作失败，让调用方降级
        guard size.width > 0.5, size.height > 0.5 else { return nil }
        // `ceil`：Core Text 给小数，向下截断会裁掉边缘一像素
        return (CGSize(width: ceil(size.width), height: ceil(size.height)), image)
    }
}
