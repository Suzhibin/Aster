//
//  AIPlatformTypes.swift
//  AIPlatform
//
//  跨平台**值类型**接缝：字体 / 颜色 / 图像 / 段落样式。
//
//  ## 为什么是 typealias，不是协议
//  这些类型必须能**原样**进入 `[NSAttributedString.Key: Any]`：
//  Down 的字体集合、`boundingRect` 的 attributes、段落样式集。
//  一旦包成协议，具体类型就被擦掉了，富文本装配那一层立刻编译不过
//  （`attributes: [.font: someProtocol]` 不是合法的富文本）。
//
//  而实测两个平台的构造点是**同名**的（`systemFont(ofSize:)`、
//  `monospacedSystemFont(ofSize:weight:)`、`Color(white:alpha:)`、`.black`/`.white`…
//  见 `ios-spm-extract-module` 技能里的双平台探针）——
//  所以 typealias 是**零成本且不丢类型信息**的正解，下面大部分 API 连 `#if` 都不需要。
//
//  ## 🔴 唯一的平台分支边界
//  平台**行为**分支（`#if os(...)` 里包逻辑）只允许出现在本 `AIPlatform/` 目录内。
//  业务层只认 `AIPlatformFont` / `AIPlatformColor` / `AIPlatformImage` / `AIPlatformParagraphStyle`。
//  机械检查（必须为空）：
//      grep -rn "#if os(" AsterCore | grep -v "AsterCore/AIPlatform/"
//

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - 值类型别名

#if canImport(UIKit)

/// 平台字体：iOS = `UIFont`，macOS = `NSFont`
public typealias AIPlatformFont = UIFont
/// 平台颜色：iOS = `UIColor`，macOS = `NSColor`
public typealias AIPlatformColor = UIColor
/// 平台图像：iOS = `UIImage`，macOS = `NSImage`
public typealias AIPlatformImage = UIImage

#elseif canImport(AppKit)

public typealias AIPlatformFont = NSFont
public typealias AIPlatformColor = NSColor
public typealias AIPlatformImage = NSImage

#endif

/// 段落样式。
///
/// ⚠️ 单独起个名字是有必要的：`NSParagraphStyle` **两个平台都不在 Foundation**
/// （实测：只 `import Foundation` 时 iOS / macOS 都报 `cannot find type in scope`，
/// 但它也不在同一个模块 —— iOS 在 UIKit、macOS 在 AppKit）。
/// 业务层要声明 `static var paragraphStyle: NSParagraphStyle` 这种返回类型，
/// 换成 `AIPlatformParagraphStyle` 才能不引平台模块。
public typealias AIPlatformParagraphStyle = NSParagraphStyle
/// 可变段落样式（构造用）
public typealias AIPlatformMutableParagraphStyle = NSMutableParagraphStyle

// MARK: - 字体

public extension AIPlatformFont {

    /// 字体行高。
    ///
    /// ⚠️ **`NSFont` 没有 `lineHeight`**（实测：`value of type 'NSFont' has no member 'lineHeight'`），
    /// 而 `UIFont` 有 —— 这是两平台里少数**连成员都不存在**的差异，必须在这里垫平。
    ///
    /// iOS 侧**直接取 `lineHeight`**，不做任何换算 —— 这一条是为了「拆分前后逐位一致」，
    /// 哪怕公式算出来理论上相同也不冒险（UIKit 内部对个别字体会做取整）。
    /// macOS 侧按 `ascender + |descender| + leading` 合成 —— 这正是 `UIFont.lineHeight` 的定义
    /// （实测 iOS system16 = 15.2344 + 3.8594 + 0 = 19.0938）。
    ///
    /// ⛔ 别图省事用 `NSLayoutManager.defaultLineHeight(for:)`：它会**取整**
    /// （实测 system16 给 18，本公式给 18.844）——
    /// 量出来的行高比实际显示矮，表现就是本工程反复栽过的「最后一行被裁」。
    var aiLineHeight: CGFloat {
        #if canImport(UIKit)
        return lineHeight
        #else
        return ascender + abs(descender) + leading
        #endif
    }

    /// 基线**以上**的高度（行内公式的垂直对齐用）。
    ///
    /// 两个平台同名（`ascender`），所以不需要分支；但**必须在这里转一手** ——
    /// 业务层直接用 `.ascender` 就等于要求 import UIKit/AppKit
    /// （工程开了 `MEMBER_IMPORT_VISIBILITY`），平台分支立刻泄漏出去。
    var aiAscent: CGFloat { ascender }

    /// 基线**以下**的高度（**正值**）。
    ///
    /// ⚠️ `descender` 两个平台都是**负数**，这里取绝对值 —— 调用方算
    /// `ascent + descent` 时不必再记「哪个要取反」，少一个符号错误的机会。
    var aiDescent: CGFloat { abs(descender) }

    // 以下构造点**两平台完全同名**，所以不需要 `#if`：
    // 编译期由 `AIPlatformFont` 决定实际调用的是 `UIFont` 还是 `NSFont` 的那一份。

    /// 系统字体。`medium = false` 时等价于原先的 `.systemFont(ofSize:)`。
    static func aiSystem(ofSize size: CGFloat, medium: Bool = false) -> AIPlatformFont {
        medium ? .systemFont(ofSize: size, weight: .medium) : .systemFont(ofSize: size)
    }

    /// 等宽字体（代码用）。取不到具名等宽字体时的兜底也是它。
    static func aiMonospaced(ofSize size: CGFloat) -> AIPlatformFont {
        .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// 等宽**数字**字体（Markdown 有序列表序号用）。
    static func aiMonospacedDigit(ofSize size: CGFloat) -> AIPlatformFont {
        .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    /// 具名字体。名字不存在时返回 nil（让调用方决定兜底）。
    static func aiNamed(_ name: String, size: CGFloat) -> AIPlatformFont? {
        AIPlatformFont(name: name, size: size)
    }
}

// MARK: - 颜色

/// ## 🔴 为什么颜色也要包一层（明明两边同名）
/// 不是因为他们命名不同 —— 是因为工程的 `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`：
/// **用某个成员，就必须 import 声明它的那个模块**。
/// `UIColor.white` / `UIColor(white:alpha:)` 的声明在 UIKit（macOS 在 AppKit），
/// 于是业务层只要写一次 `.white`，就等价于必须 `import UIKit` —— 平台分支立刻泄漏出去。
///
/// 所以规则是：**平台自带的成员一律不直接在业务层碰，全部经过这里转一手**。
/// 这些包装的声明在本模块（AIPlatform），业务层只要能 import AIPlatform 就够了。
public extension AIPlatformColor {

    /// 固定黑
    static var aiBlack: AIPlatformColor { .black }
    /// 固定白
    static var aiWhite: AIPlatformColor { .white }
    /// 灰度色。`white` 0 = 黑、1 = 白。
    static func aiGray(white: CGFloat, alpha: CGFloat = 1) -> AIPlatformColor {
        AIPlatformColor(white: white, alpha: alpha)
    }
}
