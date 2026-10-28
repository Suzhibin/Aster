//
//  AIPlatformMathAttachment.swift
//  AIPlatform
//
//  行内公式（`$...$` / `\(...\)`）在富文本里的载体 —— **接缝层唯一需要平台 import 的地方**。
//
//  ## 为什么单独一个文件
//  `AIPlatformMath.swift` 里有一条机械契约：**不许出现 `#if os` / `#if canImport`**
//  （排版那部分靠 `MTColor` / `MTImage` 两个别名已经零分叉，谁加了分支就说明有人想
//  「按平台各画一套」）。但本文件的两件事**天生**需要平台模块：
//    · `NSTextAttachment` 不是 Foundation 的类型（iOS 在 UIKit、macOS 在 AppKit）；
//    · 造一张透明位图，两端 API 完全不同（`UIGraphicsImageRenderer` vs `NSImage(size:flipped:)`）。
//  ⇒ 把它们隔离到单独文件，既有契约不必放宽，也看得清「平台分叉只在这一处」。
//
//  ## 透明占位图为什么必须存在
//  「量高」发生在业务层（`AIMarkdown.contentHeight` 用 `boundingRect` 算），
//  而 `NSTextAttachment` **只有 `bounds` 不带图时完全不参与行高**（实测：
//  纯文本 20pt，挂一个 `bounds` 24pt 高、无图的 attachment 之后仍是 20pt；
//  挂上同尺寸的**透明图**才变成 44pt）。
//
//  ⇒ 业务层先塞一张尺寸正确的透明图，`boundingRect` 就能算出真实高度；
//    视图层再按当前墨色换成真图。**两者长度、bounds 完全一致**，
//    所以「量的」与「画的」是同一份 —— 本工程那条铁律在这里同样成立。
//

import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public extension AIPlatformMath {

    /// **全透明**的占位图（尺寸 = 公式的排版尺寸）。
    static func placeholder(size: CGSize) -> AIPlatformImage {
        let safe = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        return UIGraphicsImageRenderer(size: safe, format: format).image { _ in }
        #else
        return NSImage(size: safe, flipped: false) { _ in true }
        #endif
    }
}

/// 行内公式在富文本里的载体。
///
/// ## 为什么需要子类
/// 业务层把 `$x^2$` 换成 attachment 之后，原字符串就只剩一个 `U+FFFC`（对象替换符）。
/// 视图层要「按当前墨色重新渲染」，就必须能从 attachment 上问出**这是哪条 LaTeX**；
/// 标准的 `NSTextAttachment` 没有这个字段 ⇒ 子类补一个。
/// 顺带存 `displaySize`，视图层换图时不必再量一次。
public final class AIMathAttachment: NSTextAttachment {

    /// 公式源码（已去掉定界符）
    public private(set) var latex: String = ""
    /// 应显示尺寸（= 业务层量高用的那个尺寸）
    public private(set) var displaySize: CGSize = .zero

    /// 造一个 attachment。
    ///
    /// - Parameter baselineOffset: `bounds.origin.y`，决定它在行内的垂直位置
    ///   （0 = 图片底边坐在文字基线上）。口径由业务层给（`AIMathBlockMetrics`）。
    public static func make(
        latex: String,
        image: AIPlatformImage,
        displaySize: CGSize,
        baselineOffset: CGFloat
    ) -> AIMathAttachment {
        let attachment = AIMathAttachment()
        attachment.latex = latex
        attachment.displaySize = displaySize
        attachment.image = image
        attachment.bounds = CGRect(x: 0,
                                   y: baselineOffset,
                                   width: max(displaySize.width, 1),
                                   height: max(displaySize.height, 1))
        return attachment
    }

    /// 包成富文本。
    ///
    /// ⚠️ 必须在这里转一手：`NSAttributedString(attachment:)` 是 **UIKit / AppKit**
    ///    给 `NSAttributedString` 加的构造器，业务层（AICore）直接调就等于要 import 平台模块。
    public var attributed: NSAttributedString {
        NSAttributedString(attachment: self)
    }
}
