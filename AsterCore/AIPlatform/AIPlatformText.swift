//
//  AIPlatformText.swift
//  AIPlatform
//
//  段落样式工厂 + 富文本属性键 —— 把**来源模块差异**关在这里。
//
//  ⚠️ 又是 `MemberImportVisibility` 的账：`NSMutableParagraphStyle` 两个平台都不在 Foundation
//  （实测），iOS 在 UIKit、macOS 在 AppKit。业务层若自己 `let s = NSMutableParagraphStyle()`
//  再 `s.lineSpacing = 3`，就等于同时引了两个平台模块。
//
//  所以这里提供工厂：业务层只描述「我要什么节奏」，不碰构造与属性赋值。
//

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum AIPlatformText {

    /// 造一个段落样式。
    ///
    /// - Parameters:
    ///   - charWrapping: `true` → `.byCharWrapping`（按**字符**折行），`false` → `.byWordWrapping`。
    ///     ⚠️ 代码块必须传 `true`：代码里没有空格可依，按词折行会让长标识符
    ///     （`someVeryLongFunctionName(...)`）直接溢出卡片。
    ///   - lineSpacing: 行间距
    ///   - spacingBefore: 段前距
    ///   - spacing: 段后距
    public static func paragraphStyle(charWrapping: Bool = false,
                                      lineSpacing: CGFloat = 0,
                                      spacingBefore: CGFloat = 0,
                                      spacing: CGFloat = 0) -> AIPlatformParagraphStyle {
        let style = AIPlatformMutableParagraphStyle()
        style.lineBreakMode = charWrapping ? .byCharWrapping : .byWordWrapping
        style.lineSpacing = lineSpacing
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacing
        return style
    }

    /// 富文本「链接」属性键（`NSAttributedString.Key.link`）—— 业务层的**唯一**取用点。
    ///
    /// ⚠️ 实测（2026-10-02，两平台各一次）：`.link` **不在 Foundation** ——
    ///    只 `import Foundation` 时 iOS / macOS 都报
    ///    `type 'NSAttributedString.Key' has no member 'link'`（iOS 在 UIKit、macOS 在 AppKit）。
    ///    业务层（`AILinkify`）直接写 `.link` 就等于引平台模块 ⇒ 从这里转一手。
    ///
    /// 📌 别拿 `AIMarkdown` 里那句 `[.font: …, .foregroundColor: …]` 当先例：那两个键同样不在
    ///    Foundation，AICore 里能编过是**包 target 没开 `MemberImportVisibility`**（Swift 5 宽松模式）
    ///    + `AIPlatform` 重导出的侥幸 —— 换到 App target（那条设置是 ON）就不成立。
    ///    新代码一律走本处这种显式接缝，别再扩大侥幸面。
    public static var linkKey: NSAttributedString.Key { .link }
}
