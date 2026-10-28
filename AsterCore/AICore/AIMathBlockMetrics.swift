//
//  AIMathBlockMetrics.swift
//  AsterCore
//
//  块级公式的**尺寸 / 位图缓存 / 降级** —— 量高与显示的唯一来源。
//
//  ## 分层（与 `AICodeBlockMetrics` 同一套规矩）
//  业务层（`AIMarkdown` 算行高）与两端视图都要知道「这块公式多高、长什么样」，所以口径提到这里：
//    · `height(for:width:)` —— 只算高，供 `AIMarkdown.contentHeight`（iOS）用；
//    · `image(for:width:inkKey:color:)` —— 取（或现渲）位图 + 显示尺寸，供两端视图用。
//  两者都转调 `AIPlatformMath.render`，而它**一次排版同时给尺寸和图**
//  ⇒ 「量出来的高」就是「图上屏后的高」，不存在两套账。
//
//  ## 两个必须一起处理的边界
//  ① **超宽**：`MTMathImage` 没有自动折行 ⇒ 超过可用宽就按比例缩小（`displaySize`）。
//     量高与视图**都走这一个函数**，否则会出现「图缩小了但行高没缩」= 底部一大块空白。
//  ② **排不出**（LaTeX 语法错 / 空公式）：降级成**源码文本**，高度按同一份文本属性算
//     （`fallbackHeight`）。⛔ 不能让这一块凭空消失 —— 用户会以为内容丢了。
//
//  ## 为什么墨色是**参数**而不是在这里取
//  主题语义色属于视图层（Mac 是 `MacTheme`、iOS 是系统 semantic color），而本模块
//  `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` ⇒ 这里连 `.label` 都不能写
//  （那要 import UIKit，平台分支就漏出接缝层了）。所以：
//    · `color` = 真正的墨色，视图层给；
//    · `inkKey` = 它的稳定标签（`"light"` / `"dark"`），只进缓存键。
//  明暗两档必须两张图：不分的后果是深色模式下「黑公式画在深底上」= 看不见。
//

import Foundation
import AIPlatform

public enum AIMathBlockMetrics {

    // MARK: - 尺寸常量

    /// 公式上下留白。
    ///
    /// 块级公式自带一点呼吸感（LaTeX display 的惯例），但不像代码卡片那样厚 ——
    /// 外面再套一圈大内边距会让整段回复显得松散。
    public static let paddingV: CGFloat = 6

    /// 公式左右留白。
    ///
    /// 与 iOS 正文的 `textContainerInset`（12 + 12）**同值** —— 不留这一手，公式会贴着气泡
    /// 左边缘，比上下那段文字更靠左，一眼就看得出没对齐。
    /// ⚠️ 它**不吃** `height(for:width:)`（那只是竖直的），但会吃掉横向可用宽：
    ///    调用方传的 `width` 必须是**已经扣掉左右留白**的正文宽（iOS 传 `fullTextWidth`）。
    ///    Mac 侧正文没有这层 inset（助手行直接画在页面背景上）⇒ 那边不要再加一遍。
    public static let sideInset: CGFloat = 12

    /// 公式字号：跟随正文字号档位。
    ///
    /// ⚠️ 必须是**计算属性**。`AITypography.bodyFontSize` 是「基准 + 用户档位偏移」，
    ///    写成 `static let` 会把字号定死在首次访问那一刻 ⇒ 改档位后公式不变
    ///    （`AIMarkdown.styler` 的头注释记着同一个坑）。
    public static var fontSize: CGFloat { AITypography.bodyFontSize }

    // MARK: - 高度（供 AIMarkdown 量行高）

    /// 公式块高度（只含自身，不含段间 `segmentSpacing`）。
    public static func height(for latex: String, width: CGFloat) -> CGFloat {
        guard !latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        if let natural = measure(latex: latex) {
            return displaySize(natural, maxWidth: max(width, 1)).height + paddingV * 2
        }
        // 排不出 ⇒ 与视图层同一份降级文本口径
        return ceil(fallbackHeight(for: latex, width: max(width, 1))) + paddingV * 2
    }

    // MARK: - 位图（供两端视图）

    /// 取缓存里的公式图；没有就现渲（同步）。
    ///
    /// - Parameters:
    ///   - width: 气泡内可用宽。超过它的公式按比例缩小到正好放下。
    ///   - inkKey: 墨色标签（`"light"` / `"dark"`），只进缓存键。
    ///   - color: 实际墨色，视图层按当前主题给。
    /// - Returns: 图 + **应显示尺寸**（已按 `width` 缩小）；`nil` 表示排不出 ⇒ 视图层降级。
    public static func image(
        for latex: String,
        width: CGFloat,
        inkKey: String,
        color: AIPlatformColor
    ) -> (image: AIPlatformImage, displaySize: CGSize)? {
        let key = bitmapKey(latex: latex, inkKey: inkKey) as NSString
        if let entry = bitmapCache.object(forKey: key) {
            return (entry.image, displaySize(entry.naturalSize, maxWidth: max(width, 1)))
        }
        guard let result = AIPlatformMath.render(latex: latex, fontSize: fontSize, color: color) else {
            return nil
        }
        bitmapCache.setObject(Entry(image: result.image, naturalSize: result.size), forKey: key)
        return (result.image, displaySize(result.size, maxWidth: max(width, 1)))
    }

    // MARK: - 行内公式（富文本 attachment）

    /// 行内的排版模式（`labelMode: .text`）与块级（`.display`）不同 ⇒ **尺寸也不同**
    /// （display 会放大积分/求和/分式并加留白），所以两份缓存必须分开：
    /// 复用同一份会得到「行内公式按块级尺寸排」= 明显偏大、撑破行距。
    public static func inlineAttachment(latex: String) -> AIMathAttachment? {
        guard let size = inlineSize(latex: latex) else { return nil }
        return AIMathAttachment.make(
            latex: latex,
            image: AIPlatformMath.placeholder(size: size),
            displaySize: size,
            baselineOffset: inlineBaselineOffset(for: size)
        )
    }

    /// 按当前墨色取行内公式的**真图**（视图层在显示前替换掉业务层塞的透明占位图）。
    public static func inlineImage(
        latex: String,
        inkKey: String,
        color: AIPlatformColor
    ) -> AIPlatformImage? {
        let key = "inline|\(inkKey)|\(Int((fontSize * 100).rounded()))|\(latex)" as NSString
        if let cached = inlineBitmapCache.object(forKey: key) { return cached }
        guard let result = AIPlatformMath.renderInline(latex: latex, fontSize: fontSize, color: color) else {
            return nil
        }
        inlineBitmapCache.setObject(result.image, forKey: key)
        return result.image
    }

    /// 行内公式的排版尺寸（`text` 模式）。
    private static func inlineSize(latex: String) -> CGSize? {
        let key = "inline|\(Int((fontSize * 100).rounded()))|\(latex)" as NSString
        if let cached = inlineSizeCache.object(forKey: key) { return cached.size }
        // 墨色不影响尺寸 ⇒ 固定黑，别把主题色带进来
        guard let result = AIPlatformMath.renderInline(latex: latex, fontSize: fontSize, color: .aiBlack) else {
            return nil
        }
        inlineSizeCache.setObject(SizeBox(result.size), forKey: key)
        return result.size
    }

    /// 行内公式在**文字行里的垂直位置**（`bounds.origin.y`，0 = 底边坐在基线上）。
    ///
    /// 判据是**居中**：让图片中心对齐文字行的中心（基线以上 `ascent`、以下 `descent`）。
    /// ⛔ 不是「底边贴基线」：行内公式多半带分式/上下标，比正文高一截，
    ///    贴基线会让它整体上浮半行，看上去像上标。
    /// ⚠️ 拿不到公式自己的 ascent/descent（`MTMathImage` 的 `intrinsicContentSize`
    ///    是 internal，`MTTypesetter` 也不公开），所以只能用「整张图居中」这个近似 ——
    ///    对 `\frac` 这类上下对称的式子很准，对 `x^2` 会略偏上一点，肉眼难辨。
    private static func inlineBaselineOffset(for size: CGSize) -> CGFloat {
        let font = AITypography.body
        let lineCenter = (font.aiAscent - font.aiDescent) / 2
        return lineCenter - size.height / 2
    }

    // MARK: - 降级（LaTeX 排不出时显示源码）

    /// 降级文本的属性：等宽字体 + 字符折行（与代码块同一套，源码看起来才像源码）。
    ///
    /// ⚠️ **刻意不含颜色**：颜色必须由视图层加（Mac 的正文色是语义色，写在 run 上
    ///    就会重蹈 `MacDownInk` 那个「深色模式下黑字写深底」的覆辙）。
    public static var fallbackTextAttributes: [NSAttributedString.Key: Any] {
        [.font: AITypography.code,
         .paragraphStyle: AICodeBlockMetrics.paragraphStyle]
    }

    /// 降级文本（不带颜色，视图层补）。
    public static func fallbackText(for latex: String) -> NSAttributedString {
        NSAttributedString(string: latex, attributes: fallbackTextAttributes)
    }

    /// 降级文本的高度 —— 与上面那份属性同源，所以「量的」就是「显示的」。
    private static func fallbackHeight(for latex: String, width: CGFloat) -> CGFloat {
        (latex as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: fallbackTextAttributes, context: nil).height
    }

    // MARK: - 缓存

    /// 缓存条目：图 + **排版原始尺寸**。
    ///
    /// 原始尺寸必须跟图一起存：`displaySize` 依赖宽度，而宽度是每次调用都可能变的
    /// （转屏 / 侧栏开合）⇒ 缓存不能按宽度切，否则同一公式会存出 N 份一模一样的图。
    private final class Entry {
        let image: AIPlatformImage
        let naturalSize: CGSize
        init(image: AIPlatformImage, naturalSize: CGSize) {
            self.image = image
            self.naturalSize = naturalSize
        }
    }

    /// 位图缓存（按墨色分开）。
    ///
    /// ⚠️ 上限不能省：每条回复的公式都会进来，长会话攒下去是实打实的内存。
    /// 120 张对「一屏能看到的公式数」绰绰有余，需要时重排也就几毫秒。
    private static let bitmapCache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 120
        return cache
    }()

    /// 尺寸缓存条目。
    ///
    /// ⚠️ 不用 `NSValue`：`NSValue(cgSize:)` / `cgSizeValue` 是 **UIKit** 给 `NSValue`
    ///    加的扩展，macOS 上两个都不存在（实测 `value of type 'NSValue' has no member
    ///    'cgSizeValue'`）⇒ 换个跨平台的自定义盒子，比在接缝层再包一层便宜。
    private final class SizeBox {
        let size: CGSize
        init(_ size: CGSize) { self.size = size }
    }

    /// 尺寸缓存（**与墨色无关** —— 排版尺寸不随颜色变，所以 key 里不能带 inkKey，
    /// 否则同一公式在明暗两档下要各排版一次）。
    private static let sizeCache: NSCache<NSString, SizeBox> = {
        let cache = NSCache<NSString, SizeBox>()
        cache.countLimit = 240
        return cache
    }()

    /// **行内**公式的图缓存（`labelMode: .text`，与块级那份互不通用）。
    private static let inlineBitmapCache: NSCache<NSString, AIPlatformImage> = {
        let cache = NSCache<NSString, AIPlatformImage>()
        cache.countLimit = 160
        return cache
    }()

    /// **行内**公式的尺寸缓存。
    private static let inlineSizeCache: NSCache<NSString, SizeBox> = {
        let cache = NSCache<NSString, SizeBox>()
        cache.countLimit = 240
        return cache
    }()

    /// 排版尺寸；排不出返回 `nil`。
    ///
    /// ⚠️ 已知代价：这里为了拿尺寸会**白画一张位图**再丢掉（SwiftMath 只暴露
    ///    `asImage()` 这一个排版入口，`MTMathListBuilder` 是 internal）。
    ///    只在「图上屏前先量高」那一次发生，且尺寸有缓存 ⇒ 每条公式最多一次。
    private static func measure(latex: String) -> CGSize? {
        let key = sizeKey(latex: latex) as NSString
        if let cached = sizeCache.object(forKey: key) {
            return cached.size
        }
        // 墨色对尺寸没有影响 ⇒ 用固定黑，别把主题色带进来
        guard let result = AIPlatformMath.render(latex: latex, fontSize: fontSize, color: .aiBlack) else {
            return nil
        }
        sizeCache.setObject(SizeBox(result.size), forKey: key)
        return result.size
    }

    /// 超过可用宽就等比缩小（**只缩不放**）。
    ///
    /// ⚠️ 量高与视图都必须调它。少调一处的表现是「图缩了、行高没缩」= 公式下方一大块空白。
    private static func displaySize(_ natural: CGSize, maxWidth: CGFloat) -> CGSize {
        guard maxWidth > 0, natural.width > maxWidth else { return natural }
        let scale = maxWidth / natural.width
        return CGSize(width: maxWidth, height: ceil(natural.height * scale))
    }

    // MARK: - 缓存键

    /// 位图键：**字号 + 墨色 + 源码**。宽度**不进键**（见 `Entry` 的说明）。
    private static func bitmapKey(latex: String, inkKey: String) -> String {
        "\(inkKey)|\(Int((fontSize * 100).rounded()))|\(latex)"
    }

    /// 尺寸键：**字号 + 源码**（墨色无关）。
    private static func sizeKey(latex: String) -> String {
        "\(Int((fontSize * 100).rounded()))|\(latex)"
    }

    /// 清空两份缓存。
    ///
    /// 🔴 唯一调用方是 `AIMarkdown.invalidateCaches()`（改字号档位时）。三份缓存
    ///    （段 / 高 / 公式）必须一起清：只清前两份的话，行高按新字号算、公式图还是旧的，
    ///    表现是「公式变大了但图没变」—— 与「改字号后文字不变」是同一类假象。
    public static func invalidateCache() {
        bitmapCache.removeAllObjects()
        sizeCache.removeAllObjects()
        // ⚠️ 行内那两份**也要清**：漏了的表现是「块级公式跟着字号变大，行内那几条不变」
        inlineBitmapCache.removeAllObjects()
        inlineSizeCache.removeAllObjects()
    }
}
