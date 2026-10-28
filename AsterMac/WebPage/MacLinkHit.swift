//
//  MacLinkHit.swift
//  AsterMac
//
//  助手正文里「鼠标压在哪条链接上」的判定（2026-09-30）。
//
//  ## 为什么需要这个文件
//  用户（2026-09-30）：「会话页面的 网址链接，在鼠标移动到网址上时，网址底部增加横线，
//  表示可点击」。而 SwiftUI 的 `Text` 只把 `.link` 渲染成「这串字可点」，**既不给换色、
//  也不给 hover 态**，更不暴露任何行 / 字形几何 ⇒ 想给「命中的那一条」加下划线，
//  必须自己回答一个问题：**鼠标现在压在哪个字上**。
//  唯一能回答它的东西是 TextKit（`NSLayoutManager.characterIndex(for:)` 就是干这个的）。
//
//  ## 🔴 于是就有了「两套布局」——这是本文件存在的全部风险
//  正文是 SwiftUI `Text` 画的，命中判定是 TextKit 算的。两者必须**同源**，
//  否则鼠标压在网址上时判定说「没压中」（或反过来）。离屏渲染 + 逐像素对拍实测：
//
//    | 量 | SwiftUI Text | TextKit 默认 | TextKit 钉行高后 |
//    |---|---|---|---|
//    | 16pt 正文行高 | **19.0** | 18.0 | **19.0** |
//    | 三行总高 | 57 | 54 | **57** |
//    | 第 1/2/3 行链接的纵向差 | — | 2 / 3 / 4（**逐行累加 1pt**） | **2 / 2 / 2（常数）** |
//    | 链接横向起点差 | — | — | **< 1px** |
//    | 折行点 / 行数 | — | **一致** | **一致** |
//
//  ⇒ 两条口径：
//  ① **误差会按行号累加**：不校准的话第 10 行就偏 11pt（大半个行高），判定彻底失效。
//     所以行高必须换到 SwiftUI 那一档 —— 但**不是**给整段钉一个值（见下面 ②）。
//  ② 🔴 **按行算，不给整段钉一个行高**。原因：`AIMarkdown.flushText()` 把一个围栏之间
//     的**所有文本行整块**交给 Down 渲染 ⇒ 一个 `.text` 段里可能同时有标题（28pt）、
//     正文（16pt）、行内代码（Menlo 13pt）… 而行高是**逐行**由「该行最大的那个字形」
//     决定的（SwiftUI 与 TextKit 都是）。给整段钉死 19 会把标题行压扁 ⇒ 从那一行往后
//     全偏。所以这里逐行取「该行最大字号」→ 查标定表 → 得到该行的 SwiftUI 行高，
//     再把 y **逐行累加**成一条「SwiftUI 行号 → 顶 y」的阶梯。
//  ③ 校准之后仍有一个**常数**纵向偏移（实测 ≈2pt：SwiftUI 把字画在行盒里稍偏下的位置）
//     ⇒ `topOffset`。横向不用管（差 < 1px）。
//
//  ## ⚠️ 行高是**实测标定**的，不是公式推的
//  同一段文本两边各渲染一遍量高度，得到「字号 → SwiftUI 行高」：
//  16→**19**、20→24、24→28、28→33、Menlo 13→**15**。
//  **差值是乱的**（16 差 1、20 差 1、24 差 0、28 差 0）⇒ 别写公式。
//
//  ## 🔴🔴 2026-10-06：表必须**覆盖 Down 能吐出的每一个字号**，否则整段静默失效
//
//  用户报「同一个会话里两条带网址的回复，前一条有横线也有小手，后一条鼠标移上去什么都没」。
//  查下来是**表的覆盖不全**，而且症状的严重程度远超出预期：
//  逐行查表时**任何一行**查不到就 `return nil` ⇒ **整个 `.text` 段**（可能上千字、
//  含好几条网址）一个 hover 层都不挂 —— 但 `MacLinkify` 照旧把网址刷蓝，
//  所以屏上看着完全正常，只有「鼠标移上去没反应」。两条实测（真 Down 输出 + 逐行字号）：
//
//    | 消息 | 触发的那一行 | 旧结果 |
//    |---|---|---|
//    | 带 `---` 分隔线（模型输出的常客） | `ZWSP + LF`，Down **不给它 `.font`**（只挂 `.thematicBreak` / `.paragraphStyle`），TextKit 兜底填 Helvetica **12** | 12 不在表里 ⇒ 整段失效 |
//    | 带 `### 标题` | Down 的标题字体是 `.boldSystemFont`，`###` = **20** | 20 不在表里 ⇒ 整段失效 |
//
//  ⇒ 两条都补上了：
//  ① 表覆盖 Down **能产生的全部字号**（`fonts` 那一刻就定死了：正文 16 · 行内代码 Menlo 13 ·
//     标题粗体 28/24/20 · 列表序号等宽数字 16）。⚠️ **粗体与常规体同尺寸行高完全相同**
//     （2026-10-06 逐像素实测：16→19、20→24、24→28、28→33 两栏一致）—— 所以按字号查表就够，
//     不必再分字重，「标题是粗体所以没量过」这个当年不敢加的理由已经不成立了。
//  ② **整行一个 `.font` 都没有**的行（就是 Down 的分隔线）走**视图字体兜底**：
//     SwiftUI 的 `Text` 落回 `AssistantTextChrome` 给的那个字体（`MacTheme.body` = 16）⇒ 行高 19。
//     ☠️ 判定用的是**原始富文本**有没有 `.font`，**不能**用 TextKit 那个副本：
//     `NSLayoutManager` 排版时会 `fixAttributes` 把 Helvetica 12 补进去，副本里就"有"字体了。
//
//  🔴 判据由 `render_mac_ui.sh` 的 `LINKHOVER` 探针守着：它把带链接色的正文**真渲染一遍**、
//     数出蓝色像素的**真实**位置，再拿它当期望值调 `linkIndex(at:)` ——
//     两套布局一旦不同源，探针立刻红。⛔ 别把那条探针换成「用 TextKit 验 TextKit」。
//
//  ## 性能
//  `init` 要建一套 TextKit 栈（几百字约零点几毫秒），**只在文本或宽度变化时建一次**
//  （视图层用 `.task(id:)` 持有），⛔ 绝不放进 `onContinuousHover` 的每次回调里。
//  没链接的段落会在第一道闸（`linkRanges` 为空）直接返回 nil，连栈都不建。
//

import AppKit
import Foundation
import SwiftUI

/// 一段助手正文的「链接命中层」。
///
/// 建一次（`init?`），之后 `linkIndex(at:)` 是纯查表 —— 每帧鼠标移动都能随便调。
/// `init` 返回 nil 有两种含义：**这段没有链接**，或者**这段的行高没标定过**（见文件头 ③）。
/// 两种情况下视图层都只是「不给下划线」，不会画错。
final class MacLinkHit {

    /// 一条链接落在某一行的可命中矩形（**SwiftUI 坐标**：左上原点，原点 = `Text` 的 frame 左上角）。
    struct Zone {
        let linkIndex: Int
        let rect: NSRect
    }

    /// 所有可命中矩形。判定就是「点是否落在其中」。
    private(set) var zones: [Zone] = []

    /// 布局用的宽度（= 外层给 `Text` 的提议宽度，也就是它折行时用的那个宽度）。
    let width: CGFloat

    var isUsable: Bool { !zones.isEmpty }

    // MARK: - 标定值（全部来自实测，见文件头）

    /// 「字号 → SwiftUI 行高」的实测标定表（全部来自逐像素实测，见文件头）。
    ///
    /// 🔴 这里必须覆盖 **Down 能吐出的每一个字号**（`AIMarkdown` 的 `fonts` 定死了就这几档）：
    /// 16 正文 · 13 行内代码（Menlo）· 20 / 24 / 28 标题（粗体，但与常规同尺寸行高相同）。
    /// ☠️ 漏一档的代价**不是**「那一行没有下划线」，而是**整段没有任何 hover**
    ///    （逐行查不到就 `return nil`）—— 用户 2026-10-06 报的就是这个，见文件头。
    /// ⛔ 别只留 16 那一档：`---` 分隔线与 `###` 标题都会让整段网址失去下划线与小手。
    static let swiftUILineHeight: [CGFloat: CGFloat] = [13: 15, 16: 19, 20: 24, 24: 28, 28: 33]

    /// 校准后残留的常数纵向偏移（实测 ≈2pt）。
    static let topOffset: CGFloat = 2

    /// 命中容差：两套布局的取整误差远小于它（横向 <1px、纵向 <0.5pt），
    /// 留 2pt 只是为了盖住 1x/2x 屏幕与半像素取整。⚠️ 远小于行高（19）⇒ 不会串到邻行。
    static let slack: CGFloat = 2

    // MARK: - 建层

    /// - Parameters:
    ///   - attributed: **`MacLinkify.apply(to:)` 之后**的富文本（裸网址的 `.link` 是它补的）
    ///   - width: 外层提议给 `Text` 的宽度（`ChatRowView.maxBubbleWidth`）—— 也就是渲染时的折行宽度
    init?(attributed: NSAttributedString, width: CGFloat) {
        guard width > 1 else { return nil }

        // ① 一道便宜的闸：没链接就别建 TextKit 栈（绝大多数段落都在这里返回）
        let linkRanges = MacLinkify.linkRanges(in: attributed)
        guard !linkRanges.isEmpty else { return nil }

        self.width = width

        // ② 副本里**去掉段落样式**。
        //    SwiftUI 的 `Text` 会忽略 `paragraphStyle`（`AIMarkdown` 那份 `lineSpacing: 0,
        //    paragraphSpacing: 8` 落不到屏上），而 TextKit 会照做 —— 一个 chunk 里若有
        //    多个 Markdown 段，TextKit 会多出 8pt 段间距、行数与 y 全对不上。
        //    ⚠️ 只去掉段落样式；`.font` / `.link` / `.foregroundColor` 原样保留（折行要靠它们）。
        let copy = NSMutableAttributedString(attributedString: attributed)
        copy.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: copy.length))

        let storage = NSTextStorage(attributedString: copy)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        // ③ 逐行量：自然矩形（用来匹配行号）+ 该行的 SwiftUI 行高 + 累加出来的顶 y
        var naturalRects: [NSRect] = []
        var swiftTops: [CGFloat] = []
        var swiftHeights: [CGFloat] = []
        var y: CGFloat = 0
        var glyphIndex = 0
        while glyphIndex < layout.numberOfGlyphs {
            var lineGlyphRange = NSRange()
            let rect = layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange)
            let charRange = layout.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)

            // 该行行高 = 该行**最大字号**对应的 SwiftUI 行高。
            // ☠️ 取不到标定值就整段放弃：给一行瞎猜一个行高，从它往后每一行都会偏。
            //    ⚠️ 「整行一个 `.font` 都没有」不算瞎猜 —— 那是 Down 的分隔线，
            //    SwiftUI 会给它套视图字体，行高是确定的（见 `swiftUILineHeight(ofCharactersIn:)`）。
            guard let height = Self.swiftUILineHeight(ofCharactersIn: charRange,
                                                      in: storage,
                                                      source: attributed) else {
                return nil
            }
            naturalRects.append(rect)
            swiftTops.append(y)
            swiftHeights.append(height)
            y += height
            glyphIndex = NSMaxRange(lineGlyphRange)
        }
        guard !naturalRects.isEmpty else { return nil }

        // ④ 把每条链接的逐行矩形搬到 SwiftUI 坐标
        var linkIndex = 0
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            // ☠️ 必须自己判 nil：`enumerateAttribute` 对没有该属性的区间**也会回调**
            guard value != nil else { return }
            let thisIndex = linkIndex
            linkIndex += 1

            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs,
                                           withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                // 这个片段落在哪一行（`enumerateEnclosingRects` 逐行给，但行号得自己找回来）
                guard let row = naturalRects.firstIndex(where: { $0.minY <= rect.minY + 0.5 && rect.minY < $0.maxY })
                else { return }
                self.zones.append(Zone(
                    linkIndex: thisIndex,
                    rect: NSRect(x: rect.minX,
                                 y: swiftTops[row] + Self.topOffset,
                                 width: rect.width,
                                 height: swiftHeights[row])))
            }
        }
        // 一条链接的 `.link` 存在、却一个矩形都算不出来 = 这一层的结论不可信 ⇒ 不挂
        guard !zones.isEmpty else { return nil }
    }

    /// 该行**最大字号**对应的 SwiftUI 行高；没标定过就 nil（= 整段不挂 hover）。
    ///
    /// ⚠️ 行内混排（正文 16 + 行内代码 Menlo 13）取 **max** —— 行高就是由最大的那个字形
    ///    决定的，13pt 的 Menlo 比 16pt 的 SF 小，不会影响这一行的行高。
    ///
    /// 🔴 2026-10-06 补：**整行一个 `.font` 都没有** = Down 的**分隔线**（`---`）——
    ///    它只产出「零宽空格 + 换行」，且 `style(thematicBreak:)` **只挂 `.thematicBreak` /
    ///    `.paragraphStyle`，不挂 `.font`**。SwiftUI 的 `Text` 会落回**视图自己的字体**
    ///    （`AssistantTextChrome` 的 `MacTheme.body`）⇒ 行高就是 `body` 那一档。
    ///    ☠️ 判定「有没有字体」必须看**原始富文本**（`source`），**不能**看 `storage`：
    ///    `NSLayoutManager` 排版时会 `fixAttributes` 把 Helvetica **12** 补到那些区间上，
    ///    于是副本里"有"字体、字号 12 又不在表里 ⇒ 旧代码在这里 `return nil` ⇒
    ///    **整段**（含好几条网址）一个 hover 都不挂，而网址照旧是蓝的 —— 这就是
    ///    用户 2026-10-06 报的「前一条有横线小手、后一条鼠标移上去没反应」。
    private static func swiftUILineHeight(ofCharactersIn charRange: NSRange,
                                          in storage: NSTextStorage,
                                          source: NSAttributedString) -> CGFloat? {
        var largest: CGFloat = 0
        storage.enumerateAttribute(.font, in: charRange) { value, _, _ in
            guard let font = value as? NSFont else { return }
            largest = max(largest, font.pointSize)
        }
        // 这一行在**原始**富文本里有没有显式字体？（`storage` 里那个 12 是 TextKit 兜的）
        var hasExplicitFont = false
        source.enumerateAttribute(.font, in: charRange) { value, _, _ in
            if value != nil { hasExplicitFont = true }
        }
        // 没有 ⇒ 视图字体兜底（SwiftUI 就是这么画的）；有 ⇒ 按该行最大字号查表。
        let key = hasExplicitFont ? largest : MacTheme.bodyFontSize
        guard let height = swiftUILineHeight[key] else { return nil }
        return height
    }

    // MARK: - 判定

    /// 鼠标点（**`Text` 的本地坐标**，左上原点）压在第几条链接上；没压中 = nil。
    func linkIndex(at point: CGPoint) -> Int? {
        for zone in zones where zone.rect.insetBy(dx: -Self.slack, dy: -Self.slack).contains(point) {
            return zone.linkIndex
        }
        return nil
    }
}

// MARK: - 给视图层用的两个纯函数

extension MacLinkHit {

    /// 第 `index` 条链接的富文本区间。
    ///
    /// ⚠️ 序号口径与 `MacLinkify.linkRanges(in:)` **同一个**（按出现顺序）——
    ///    判定层、上色层、下划线层三处都从这里取，别各写一遍
    ///    （写歪了的表现是「鼠标压在 A 上、B 变了下划线」）。
    static func linkRange(_ index: Int, in attributed: NSAttributedString) -> NSRange? {
        let ranges = MacLinkify.linkRanges(in: attributed)
        guard index >= 0, index < ranges.count else { return nil }
        return ranges[index]
    }

    /// 交给 SwiftUI `Text` 的富文本；`underlining` 非 nil 时给**那一条**链接加下划线。
    ///
    /// 🔴 下划线用的是 **SwiftUI 自己的 `underlineStyle`**（`Text.LineStyle`），
    /// 不是往 `NSAttributedString` 上补 AppKit 的 `.underlineStyle` ——
    /// `Text` 只认自己那一批属性，AppKit scope 的同类属性会被它静默忽略
    /// （这正是「属性写上了、屏上什么都没有」的老坑，见 `ios-swiftui-headless-render`）。
    ///
    /// ⚠️ 下划线**不参与文本布局**（它就是画在字形下方的一条线），
    /// 与链接色同理 ⇒ 可以安全地随鼠标进出切换，不会让段落高度抖一下。
    ///
    /// 🔴 下划线颜色**显式给**（不靠「跟随前景色」那套默认行为）：一来与链接色同一个来源，
    /// 二来探针要**数蓝色像素**来证明它真画出来了（没给颜色时万一是灰的，那条判据就废了）。
    static func displayString(_ attributed: NSAttributedString, underlining index: Int?) -> AttributedString {
        var string = AttributedString(attributed)
        guard let index,
              let nsRange = linkRange(index, in: attributed),
              let range = Range(nsRange, in: string) else { return string }
        string[range].underlineStyle = Text.LineStyle(pattern: .solid, color: MacTheme.linkText)
        return string
    }
}
