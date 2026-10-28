import Foundation
import Down
import AIPlatform

/// Markdown → NSAttributedString（cmark 实现，支持 iOS 11+）
public enum AIMarkdown {

    // MARK: - 样式

    /// 渲染用的字号集合。
    ///
    /// ⚠️ **必须显式指定正文**：Down 的 `StaticFontCollection` 默认正文是 **17**，
    /// 不覆盖的话「流式 16 → 收尾渲染后 17」，同一段话在流结束的瞬间跳一档字号。
    ///
    /// 标题沿用 Down 的默认层级（28/24/20…）——标题本来就该比正文大，不是漂移；
    /// 代码 / 列表序号取 `AITypography.code`（唯一来源），不再让 Down 自己给默认值。
    private static var fonts: StaticFontCollection {
        StaticFontCollection(
            body: AITypography.body,
            code: AITypography.code,
            listItemPrefix: AIPlatformFont.aiMonospacedDigit(ofSize: AITypography.bodyFontSize)
        )
    }

    /// 段落样式：往「聊天气泡」而不是「排版文档」上调。
    ///
    /// Down 的默认 body 是 `lineSpacing = 8` + `paragraphSpacingBefore = 8`，
    /// 那是给长文阅读准备的：逐行拉开、首段前还空一段，放进气泡里会**比用户气泡明显松散**。
    /// 这里把行距压回 0（单段回答的行高就与用户气泡完全一致），只在**段落之间**留 8。
    ///
    /// - `body`：正文段的节奏。
    /// - `code`：**行内代码**（`一句 `code` 混在正文里`）用。围栏代码块**不走这里** ——
    ///   它已经改成独立的 `AICodeBlockView` 卡片（见 `Segment` 的说明），
    ///   卡片有自己的内边距与行距，与这份段落样式无关。
    private static var paragraphStyles: StaticParagraphStyleCollection {
        var styles = StaticParagraphStyleCollection()
        styles.body = AIPlatformText.paragraphStyle(lineSpacing: 0, spacingBefore: 0, spacing: 8)
        styles.code = AIPlatformText.paragraphStyle(spacingBefore: 2, spacing: 4)
        return styles
    }

    /// 渲染器：字体取自 `AITypography`；正文/标题颜色用 Down 默认（正文黑，与气泡的固定浅底匹配）。
    ///
    /// 🔴🔴 **必须是计算属性，⛔ 不许改成 `static let`**（2026-10-15 用户报「调字体大小，
    ///     会话页只放大间距、字不变」的真因就是它曾经是 `static let`）：
    ///     `AITypography.body` 是**计算属性**（字号 = 16 + 用户档位偏移），而 `static let`
    ///     只在**首次访问那一刻**求值一次 ⇒ Down 的字体集合被**定死在那一刻的字号**上。
    ///     之后用户在设置里改档位，`invalidateCaches()` 把富文本缓存清了、解析也重跑了，
    ///     但新富文本用的还是**旧字号**的 styler ⇒ 屏上文字大小毫无变化。
    ///     （用户当时看到的「间距变了」是气泡/输入框那几处视图层字号生效了，
    ///      而正文的 run 属性压过视图层 —— 同一份富文本里「排版引擎以为的字号」
    ///      与实际字形对不上，观感就是「只拉开了行距」。）
    /// - Note: 构造 `DownStyler` 只是攒几个字体/样式对象（无 IO、无解析），
    ///   相对一次 Down AST 渲染（毫秒级）可以忽略 ⇒ 每次渲染新建没有性能问题。
    /// - Note: 2026-09-18 起**不再需要自定义 `DownStyler` 子类**。上一版为了让代码块有底色，
    ///   写过 `AICodeStyler` 去补 `.backgroundColor` + 打标记 —— 那是「方案 A」，已被
    ///   代码卡片（方案 B）取代：代码块根本不经过 Down 渲染了，那些补丁与标记一并撤掉。
    private static var styler: DownStyler {
        DownStyler(
            configuration: DownStylerConfiguration(fonts: fonts, paragraphStyles: paragraphStyles))
    }

    // MARK: - 渲染

    /// Markdown → 富文本。
    ///
    /// - Note: 走的是 **AST + Styler** 这条路径（`toAttributedString(styler:)`），
    ///   不是无参的 `toAttributedString()`。后者底层是 WebKit
    ///   （`NSAttributedString(htmlString:)` + 一句只写了 font-family 的 CSS）：
    ///   字号既没在 CSS 里声过、也拿不到 `AITypography`，只能落在 WebKit 自己的默认值上
    ///   —— 这正是「AI 的字号和我的对不上」的来源；而且它**只能在主线程调用**、明显更慢。
    ///   AST 路径是纯遍历、可后台、属性完全可控（行高量算用的也是同一份富文本，口径天然一致）。
    ///
    /// - Note: 选项沿用 `.default`（= `CMARK_OPT_DEFAULT`），**没开 `.hardBreaks`**。
    ///   含义：段内单个 `\n` 会被当成 softbreak 渲染成**空格**，只有空行分段 / 硬换行（行尾两个空格）
    ///   才真的换行。所以模型输出的「段内换行」在收尾那一刻会被并回一行（流式时反而是换行的）。
    ///   要保留这些换行，把上面的 options 改成 `[.default, .hardBreaks]` 即可 —— 属于显示口径变更，未擅自打开。
    public static func attributedString(from markdown: String) -> NSAttributedString? {
        do {
            let down = Down(markdownString: markdown)
            return try down.toAttributedString(styler: styler)
        } catch {
            return nil
        }
    }

    // MARK: - 分段（助手气泡的渲染单位）

    /// 助手消息切出来的**一段**。
    ///
    /// 助手气泡不再是「一整段富文本」，而是分段拼接：普通 Markdown 段走 `BubbleTextView`、
    /// 围栏代码段走 `AICodeBlockView`（卡片）。为什么代码块**必须**是一个视图
    /// （圆角 / 内边距 / 常驻复制按钮都要 frame）见 `AICodeBlockView` 的文件头。
    public enum Segment {
        /// 普通 Markdown 段（已渲染成富文本）
        case text(NSAttributedString)
        /// 围栏代码段。`code` 已去掉围栏与首尾换行；`language` 是 info 串（可能为 nil）。
        case code(code: String, language: String?)
        /// **块级公式**（`$$...$$` 或 ```math / ```latex / ```tex 围栏）。
        /// `latex` 已去掉定界符 / 围栏与首尾空白。
        ///
        /// ⚠️ 只有**块级**：行内 `$...$` 仍按普通文本渲染（源码可见）。
        ///    行内要改的是富文本结构（iOS 走 `NSTextAttachment`、Mac 得把富文本切段再拼
        ///    `Text`），两端是两套实现且都在最核心的渲染链路上 ⇒ 单独一期做。
        ///    理由与两端的接法写在 `AIPlatformMath.swift` 文件尾。
        case math(latex: String)
    }

    // MARK: - 解析缓存

    /// 缓存条目上限（两个缓存各自计数）。
    ///
    /// ⚠️ 必须有上限：每次「重新生成 / 编辑重发」都会产生一段新源文，
    /// 不设限的话缓存会随会话历史单调增长，而一条长回复的源文可能几十 KB。
    private static let cacheLimit = 160

    /// 段切分缓存：**源文 → 段**。
    ///
    /// 它与宽度无关，所以切会话、转屏都能继续命中；写一次、量高与渲染两处读。
    private static var segmentCache: [String: [Segment]] = [:]

    /// 高度缓存：**源文 + 宽度 → 内容高**。
    ///
    /// 高度必须带上宽度：文本段按 `boundingRect` 折行、代码卡片也有 width 参数，
    /// 同一个源文在不同宽度下是两个不同的高度。转屏后宽度变了会自然 miss 一次
    /// 并写入新宽度的高度（旧宽度的条目留给容量淘汰）。
    private static var heightCache: [HeightKey: CGFloat] = [:]

    private struct HeightKey: Hashable {
        let markdown: String
        let width: CGFloat
    }

    /// 两个缓存共用一把锁。命中时只有「加锁 + 一次字典查找」，
    /// 相对一次 Markdown 解析（毫秒级）可以忽略，换来的线程安全是值得的
    ///（`segments` 是 public，将来从后台线程调也不该出问题）。
    private static let cacheLock = NSLock()

    /// 存一段切分结果；满了先淘汰约三分之一再写。
    ///
    /// 为什么是「淘汰三分之一」而不是整体清空：整体清空会让「刚翻过去的历史再翻回来」
    /// 重新解析一遍，而那正是缓存要消除的卡顿。淘汰对象取字典的任意前缀，
    /// 不追求严格 LRU —— 命中率主要由容量决定，淘汰顺序的影响很小。
    private static func storeSegment(_ segments: [Segment], for markdown: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if segmentCache.count >= cacheLimit {
            // ⚠️ 先拷成数组再删：`keys` 是原字典的 view，边遍历边改会读到失效的存储
            for key in Array(segmentCache.keys.prefix(cacheLimit / 3)) {
                segmentCache.removeValue(forKey: key)
            }
        }
        segmentCache[markdown] = segments
    }

    /// 存一次量算结果；同样满了先腾位置
    private static func storeHeight(_ height: CGFloat, for key: HeightKey) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if heightCache.count >= cacheLimit {
            for key in Array(heightCache.keys.prefix(cacheLimit / 3)) {
                heightCache.removeValue(forKey: key)
            }
        }
        heightCache[key] = height
    }

    /// 清空**两个**缓存。
    ///
    /// 🔴 唯一的调用方是 `AIFontSizeStore.current` 的 setter（改正文字号档位时）。
    ///    为什么非清不可：两份缓存的键都**只有源文（+ 宽度）**，不带字号 ——
    ///    · `segmentCache` 里躺着**已经带着旧字号**渲染好的富文本；
    ///    · `heightCache` 里躺着**按旧字号量出来**的行高。
    ///    不清的后果不是「下一次 miss 就好」，而是**永远命中旧值**：界面看着还是老字号，
    ///    且行高与显示不符（本工程「量算必须与渲染同源」那条铁律被绕过）。
    /// ⚠️ 别把它挂到视图层（每个页面各调一遍）—— 清理点只此一处，散开就一定会漏。
    public static func invalidateCaches() {
        cacheLock.lock()
        segmentCache.removeAll()
        heightCache.removeAll()
        cacheLock.unlock()
        // 🔴 公式位图是**第三份**缓存（`AIMathBlockMetrics`）。
        //    三份必须一起清：只清前两份的话，行高按新字号算、公式图还是旧的，
        //    表现是「公式变大了但图没变」—— 与「改字号后文字不变」是同一类假象。
        //    ⚠️ 放在锁外调用：`NSCache` 自带线程安全，没必要把两把锁叠在一起。
        AIMathBlockMetrics.invalidateCache()
    }

    // MARK: - 分段

    /// 把 Markdown 源文切成「文本段 / 代码段」交错的一串（**带缓存**）。
    ///
    /// 两个调用方拿的是同一份源文：`contentHeight` 量高一次、cell 的 `applySegments`
    /// 渲染一次。加缓存之前它们各跑一遍完整解析（`components(separatedBy:)` + 逐行扫围栏
    /// + 每个文本段一次 Down 的 AST 渲染），于是「载入历史会话」是 N 次解析、
    /// 「滚动时每个 assistant cell 上屏」又是新的一遍 —— 源文没变就不该重算。
    public static func segments(from markdown: String) -> [Segment] {
        // 🔴 每一次调用都读一次字号版本号 —— **命中缓存也要读**（2026-10-15 用户报
        //    「改字号后会话页数据不跟随、必须重启才生效」的真因之二）：
        //    `AIChatManager.recomputeAllRowHeights()`（载入 / 切会话时跑，**共享层**）
        //    早就把 `segmentCache` 预热过了 ⇒ 视图层渲染时**永远命中**，而命中路径
        //    （下面那个 `if let cached`）根本不碰 `AITypography` ⇒ 视图的 body 里
        //    一次字号依赖都没登记 ⇒ `bump()` 之后**父视图不重算**，传给子视图的富文本
        //    还是旧字号渲染的（run 属性压过视图层 `.font`，字不变、只变间距）。
        //    在这里读一次 ⇒ 凡是在 body 里调 `segments` 的视图都自动登记，零漏网。
        //    （UIKit 侧没有观察事务，这次读是 no-op；`recomputeAllRowHeights` 同理。）
        if #available(iOS 17.0, macOS 14.0, *) { _ = AIFontSizeRevision.shared.value }
        cacheLock.lock()
        let cached = segmentCache[markdown]
        cacheLock.unlock()
        if let cached = cached { return cached }
        let parsed = parseSegments(from: markdown)
        storeSegment(parsed, for: markdown)
        return parsed
    }

    /// 实际的切分逻辑（无缓存）。缓存层只管「查 / 存」，解析保持原样、单独可读。
    ///
    /// ## 为什么是逐行扫源文，而不是走 AST
    /// 我们需要的正是**原样切分**，而 Down 的 `toAttributedString(styler:)` 是整篇一次性
    /// 渲染、不提供分段入口。围栏代码块在 Markdown 里本来就是**行级**结构，
    /// 逐行扫足够可靠，而且比正则安全（不用处理跨行匹配与贪婪）。
    ///
    /// ⛔ **不支持 4 空格缩进式代码块**：它在源文里没有任何显式边界，与「列表 / 引用里的缩进」
    /// 歧义很大，判错会把正常段落整块变成代码卡片。实际模型输出几乎只用围栏；
    /// 缩进式会原样走 Markdown 渲染（= 现状，不会出错）。
    private static func parseSegments(from markdown: String) -> [Segment] {
        var result: [Segment] = []
        var textBuffer: [String] = []

        /// 把攒下的文本行冲成一段。**全空白的块直接丢掉** ——
        /// 围栏前后的空行会攒出一个只剩换行的 chunk，留着会多出一段空白。
        func flushText() {
            let chunk = textBuffer.joined(separator: "\n")
            textBuffer.removeAll()
            guard !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // 🔴 行内公式**必须在 Down 之前**从源码里挖走（`extractInlineMath`）：
            //    Down 是 CommonMark 实现，会把 `\{` `\_` `\$` 这类反斜杠转义吃掉 ——
            //    等渲染完再去找，拿到的已经是错掉的 LaTeX（`$\{x\}$` 变成 `${x}$`）。
            let extracted = extractInlineMath(from: chunk)
            // 渲染失败就退回纯文本段：宁可样式朴素，也不要让一整段内容凭空消失
            let attributed = attributedString(from: extracted.markdown) ?? NSAttributedString(
                string: extracted.markdown,
                attributes: [.font: AITypography.body, .foregroundColor: AITypography.bodyColor])
            result.append(.text(attachInlineMath(extracted.latexes, into: attributed)))
        }

        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            // ① 块级公式 `$$...$$`。放在围栏判断**之前**：两者互斥，但先切走公式
            //    能让下面攒的 `textBuffer` 少一堆反斜杠命令（`\frac` `\sum` 会被
            //    Down 当转义/强调处理，切晚了就已经被吃坏了）。
            if let block = mathBlock(in: lines, from: index) {
                flushText()
                result.append(.math(latex: block.latex))
                index = block.next
                continue
            }
            guard let fence = fenceMarker(in: lines[index]) else {
                textBuffer.append(lines[index])
                index += 1
                continue
            }
            flushText()
            var body: [String] = []
            index += 1
            // 收代码体：直到遇到闭合围栏（同种符号、长度 ≥ 开启那条、行内无别的内容）
            while index < lines.count, !isFenceClosure(lines[index], marker: fence.marker) {
                body.append(lines[index])
                index += 1
            }
            index += 1   // 跳过闭合行；没有闭合行时越界，`while` 条件会兜住
            let content = body.joined(separator: "\n")
            // ② ```math / ```latex / ```tex 围栏也当块级公式 —— 模型经常这么写，
            //    而且比 `$$` 更稳（围栏有显式边界，不怕正文里的美元符号）。
            if isMathFence(fence.language) {
                result.append(.math(latex: content.trimmingCharacters(in: .whitespacesAndNewlines)))
            } else {
                result.append(.code(code: content, language: fence.language))
            }
        }
        flushText()
        return result
    }

    /// 从第 `index` 行起尝试读一个**独占行**的块级公式；不是公式行则 `nil`。
    ///
    /// 认三种定界符（模型这三样都会写，2026-10-27 之前只认第一种）：
    /// - `$$ ... $$`
    /// - `\[ ... \]`  ← OpenAI / Gemini / DeepSeek 的默认写法，之前完全没识别
    /// - 两者都支持「单行闭合」与「跨行」两种形态
    ///
    /// 只认**行首**定界符。行文中间出现的一律交给行内处理（`extractInlineMath`）——
    /// 这个位置上硬猜成块级会把「美元金额」整段吃掉。
    ///
    /// 没有闭合行时**吃到文末也算公式**：流式输出偶尔会被截断，
    /// 宁可把剩余部分按公式排（用户看得出这是公式），也不要让它退回正文被吃坏。
    private static func mathBlock(in lines: [String], from index: Int) -> (latex: String, next: Int)? {
        guard index < lines.count else { return nil }
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("$$") {
            return blockMath(in: lines, from: index, open: "$$", close: "$$")
        }
        if trimmed.hasPrefix("\\[") {
            return blockMath(in: lines, from: index, open: "\\[", close: "\\]")
        }
        return nil
    }

    /// 定界符版本的块级公式读取（`$$` 与 `\[` 共用一份逻辑）。
    private static func blockMath(
        in lines: [String],
        from index: Int,
        open: String,
        close: String
    ) -> (latex: String, next: Int)? {
        guard index < lines.count else { return nil }
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(open) else { return nil }
        let afterOpen = String(trimmed.dropFirst(open.count))

        // ① 同一行里就闭合了
        if let range = afterOpen.range(of: close) {
            let body = String(afterOpen[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : (body, index + 1)
        }

        // ② 多行：一直收到出现闭合符的那一行（该行前面的内容仍属于公式）
        var body: [String] = []
        if !afterOpen.trimmingCharacters(in: .whitespaces).isEmpty { body.append(afterOpen) }
        var cursor = index + 1
        while cursor < lines.count {
            let current = lines[cursor]
            if let range = current.range(of: close) {
                let head = String(current[..<range.lowerBound])
                if !head.trimmingCharacters(in: .whitespaces).isEmpty { body.append(head) }
                cursor += 1
                break
            }
            body.append(current)
            cursor += 1
        }
        let latex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return latex.isEmpty ? nil : (latex, cursor)
    }

    /// 围栏 info 串是否声明了「这里面是数学」。
    ///
    /// `katex` 也认：不少模型会写 ```katex，内容其实还是 LaTeX。
    private static func isMathFence(_ language: String?) -> Bool {
        guard let language = language?.lowercased() else { return false }
        return ["math", "latex", "tex", "katex"].contains(language)
    }

    // MARK: - 行内公式（`$...$` / `\(...\)`）

    /// 行内公式在**源码**里的占位字符。
    ///
    /// 选 Unicode **私有区**（U+E000）：Markdown 渲染器不认识它，会当普通字符原样保留。
    /// ⛔ 别改成 ASCII 里的特殊符号 —— `$` 会再被识别一次、`\` 会被当转义、
    ///    而 `U+FFFC`（对象替换符）在某些排版器里会被当成已存在的附件处理。
    private static let inlineMathMark: Character = "\u{E000}"

    /// 源码里挖走的行内公式：`markdown` 已用占位字符替换，`latexes` 按出现顺序。
    private struct InlineMathExtraction {
        let markdown: String
        let latexes: [String]
    }

    /// 把源码里的行内公式替换成占位字符。
    ///
    /// ## 为什么在**源码**上做，而不是渲染完的富文本上
    /// Down 是 CommonMark 实现，会处理反斜杠转义：`$\{x\}$` 里的 `\{` 会被吃成 `{`。
    /// 等富文本出来再扫，拿到的 LaTeX 已经错了。所以必须在 Down 之前挖走。
    ///
    /// ## 识别的三种写法
    /// - `$x^2$`   —— 最常见，规则见 `inlineDollar`
    /// - `\(x^2\)` —— OpenAI / Gemini 默认的行内写法
    /// - `$$x^2$$` 混在段落中 —— 当**行内**公式处理（独占一行的已被 `mathBlock` 先切走）
    ///
    /// ⚠️ **反引号区间内一律不认**：`` `$HOME` `` 是命令，不是公式。
    private static func extractInlineMath(from source: String) -> InlineMathExtraction {
        var out = ""
        var latexes: [String] = []
        var index = source.startIndex
        var inCode = false

        while index < source.endIndex {
            let character = source[index]

            if character == "`" {
                inCode.toggle()
                out.append(character)
                index = source.index(after: index)
                continue
            }
            if inCode {
                out.append(character)
                index = source.index(after: index)
                continue
            }

            // 反斜杠：可能是 \( ... \) / \[ ... \]，也可能是别的转义（原样保留）
            if character == "\\", let next = source.index(index, offsetBy: 1, limitedBy: source.endIndex) {
                let symbol = source[next]
                if symbol == "(" || symbol == "[" {
                    let close: Character = symbol == "(" ? ")" : "]"
                    let bodyStart = source.index(after: next)
                    if let found = inlineDelimited(source, from: bodyStart, close: close) {
                        out.append(inlineMathMark)
                        latexes.append(found.latex)
                        index = found.next
                        continue
                    }
                }
                out.append(character)
                out.append(symbol)
                index = source.index(after: next)
                continue
            }

            if character == "$", let found = inlineDollar(source, from: index) {
                out.append(inlineMathMark)
                latexes.append(found.latex)
                index = found.next
                continue
            }

            out.append(character)
            index = source.index(after: index)
        }
        return InlineMathExtraction(markdown: out, latexes: latexes)
    }

    /// 读一个 `\( ... \)` / `\[ ... \]`（`start` 指向开定界符**之后**）。
    private static func inlineDelimited(
        _ source: String,
        from start: String.Index,
        close: Character
    ) -> (latex: String, next: String.Index)? {
        var cursor = start
        while cursor < source.endIndex {
            let character = source[cursor]
            // 行内公式不许跨行：跨行的那个是块级（且已被 `mathBlock` 切走）
            if character == "\n" { return nil }
            if character == close {
                // 🔴 闭合符前面那个**反斜杠属于定界符**（`\)` / `\]`），不属于公式内容。
                //    不切掉的话 latex 会以 `\` 结尾 ⇒ SwiftMath 判为非法 ⇒ 整条公式降级成源码
                //    （2026-10-27 首轮实测就是这么错的：探针 inline=1，期望 2）。
                var end = cursor
                if end > start, source[source.index(before: end)] == "\\" {
                    end = source.index(before: end)
                }
                let latex = String(source[start..<end])
                guard !latex.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return (latex, source.index(after: cursor))
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    /// 读一个 `$ ... $`（`open` 指向开头的 `$`）。
    ///
    /// 规则（对齐 pandoc 的口径，避免把金额吃成公式）：
    /// - 开 `$` 后**不能是空白**、不能是 `$`
    /// - 闭 `$` 前**不能是空白**
    /// - 闭 `$` 后**不能紧跟数字** ⇒ `$5 and $6` 不会被当成公式
    /// - 内容里至少要有一个「像公式」的字符（`looksLikeMath`）⇒ `$100.00` 排除
    /// - 不许跨行
    private static func inlineDollar(
        _ source: String,
        from open: String.Index
    ) -> (latex: String, next: String.Index)? {
        let start = source.index(after: open)
        guard start < source.endIndex else { return nil }
        let first = source[start]

        // `$$...$$` 混在段落里：按行内公式处理（独占一行的已经在 `mathBlock` 走了）
        if first == "$" {
            let bodyStart = source.index(after: start)
            guard let closing = source.range(of: "$$", range: bodyStart..<source.endIndex) else { return nil }
            let latex = String(source[bodyStart..<closing.lowerBound])
            guard !latex.contains("\n"),
                  !latex.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (latex, closing.upperBound)
        }

        if first.isWhitespace { return nil }

        var cursor = start
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "\n" { return nil }
            // `\$` 是转义的美元符号，跳过它，别当闭合
            if character == "\\" {
                cursor = source.index(after: cursor)
                if cursor < source.endIndex { cursor = source.index(after: cursor) }
                continue
            }
            if character == "$" {
                let previous = source[source.index(before: cursor)]
                if previous.isWhitespace || previous == "$" { return nil }
                let next = source.index(after: cursor)
                if next < source.endIndex, source[next].isNumber { return nil }
                let latex = String(source[start..<cursor])
                guard looksLikeMath(latex) else { return nil }
                return (latex, next)
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    /// 内容是否「像公式」。
    ///
    /// 唯一目的是挡住 `$100.00` / `$5` 这类**金额**：纯数字 + 小数点/逗号不认。
    /// 只要出现字母（`x`、`\alpha`）或数学符号，就认为是公式。
    private static func looksLikeMath(_ text: String) -> Bool {
        for character in text {
            if character.isLetter { return true }
            if character == "\\" || character == "^" || character == "_"
                || character == "=" || character == "+" || character == "{"
                || character == "<" || character == ">" || character == "/" {
                return true
            }
        }
        return false
    }

    /// 把占位字符换成公式附件（顺序对应 `latexes`）。
    ///
    /// 排不出（LaTeX 语法错）时**还原成源码**（`$latex$`）：留一个空白方块比显示错误源码更糟 ——
    /// 用户无从判断是「公式太复杂」还是「内容丢了」。
    private static func attachInlineMath(
        _ latexes: [String],
        into attributed: NSAttributedString
    ) -> NSAttributedString {
        guard !latexes.isEmpty else { return attributed }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        let ns = mutable.string as NSString
        let mark = inlineMathMark.utf16.first ?? 0

        var positions: [Int] = []
        var cursor = 0
        while cursor < ns.length {
            if ns.character(at: cursor) == mark { positions.append(cursor) }
            cursor += 1
        }
        // 数量对不上（理论上不会）⇒ 宁可整段退回原文，也不要错位替换
        guard positions.count == latexes.count else { return attributed }

        // 🔴 从后往前换：替换会改变字符串长度，正序会让后面所有位置全部错位
        for (order, position) in positions.enumerated().reversed() {
            let latex = latexes[order]
            let replacement: NSAttributedString
            if let attachment = AIMathBlockMetrics.inlineAttachment(latex: latex) {
                replacement = attachment.attributed
            } else {
                replacement = NSAttributedString(
                    string: "$\(latex)$",
                    attributes: [.font: AITypography.body,
                                 .foregroundColor: AITypography.bodyColor])
            }
            mutable.replaceCharacters(in: NSRange(location: position, length: 1), with: replacement)
        }
        return mutable
    }

    /// 行首是否是**开启围栏** → 返回符号（``` / ~~~）与 info 串。不是围栏行则 `nil`。
    private static func fenceMarker(in line: String) -> (marker: String, language: String?)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        for symbol in ["`", "~"] {
            let count = trimmed.prefix { String($0) == symbol }.count
            guard count >= 3 else { continue }
            let info = trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces)
            // Markdown 规定反引号围栏的 info 串里不能再出现反引号，出现即说明这行不是围栏
            if symbol == "`", info.contains("`") { continue }
            return (String(repeating: symbol, count: count), info.isEmpty ? nil : info)
        }
        return nil
    }

    /// 是否是**闭合围栏**：同种符号、长度 **≥** 开启那条、且符号之后只剩空白。
    private static func isFenceClosure(_ line: String, marker: String) -> Bool {
        // ⚠️ 取 `Character` 而不是 `prefix(1)`（那个给的是 `Substring`）——
        // 下面要拿它跟 `rest.first` 比，类型不一致编译直接报错
        guard let symbol = marker.first else { return false }
        var rest = Substring(line)
        while let first = rest.first, (first == " " || first == "\t") {
            rest = rest.dropFirst()
        }
        var fenceCount = 0
        while let first = rest.first, first == symbol {
            fenceCount += 1
            rest = rest.dropFirst()
        }
        guard fenceCount >= marker.count else { return false }
        return rest.allSatisfy { $0 == " " || $0 == "\t" }
    }

    // MARK: - 分段量高（与 cell 布局同源）

    /// `contentStack` 里**段与段之间**的竖直间距。
    ///
    /// ⚠️ cell 的 `contentStack.spacing` 与下面 `contentHeight` 的累加**必须**都用这一个值。
    public static let segmentSpacing: CGFloat = 10

    /// 气泡内容的**上下留白**（`contentStack` 距气泡顶/底各一份）。
    ///
    /// 与旧的「`textView.textContainerInset` 上下各 10」同值 —— 换成 stack 之后，
    /// 这笔留白只是从 textView 内部搬到了 stack 上，总量没变（所以单段文本的行高公式没变）。
    public static let contentPaddingV: CGFloat = 10

    /// 助手文本的**内容高度**（气泡内，不含气泡自身的上下 6+6）。
    ///
    /// ⚠️ 与 `AIAssistantTextCell` 的布局**逐项同源**：
    /// `contentStack`（上下各 `contentPaddingV`、段间 `segmentSpacing`）
    /// + 每个文本段的 `BubbleTextView`（上下 inset 已归 0，高度就是富文本本身）
    /// + 每个代码段的 `AICodeBlockView.height(for:width:)`。
    /// ⛔ 任何一项对不上，表现就是「最后一行被裁」或「底部多一截空白」——
    /// 这是本工程反复栽过的坑，改布局时**必须**回来一起改。
    public static func contentHeight(from markdown: String, width: CGFloat) -> CGFloat {
        let key = HeightKey(markdown: markdown, width: width)
        cacheLock.lock()
        let cached = heightCache[key]
        cacheLock.unlock()
        if let cached = cached { return cached }
        let height = measureContentHeight(from: markdown, width: width)
        storeHeight(height, for: key)
        return height
    }

    /// 实际的量算（无缓存）。
    ///
    /// ⚠️ 缓存键里**必须带 width**：下面每个文本段都按 `width` 折行、代码卡片也吃 width，
    /// 少这一维的话转屏后就会拿到旧宽度的高度（表现是裁行或底部空一截）。
    private static func measureContentHeight(from markdown: String, width: CGFloat) -> CGFloat {
        let segments = segments(from: markdown)
        guard !segments.isEmpty else { return 0 }
        var total = contentPaddingV * 2
        for (index, segment) in segments.enumerated() {
            if index > 0 { total += segmentSpacing }
            switch segment {
            case .text(let attributed):
                let height = attributed.boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
                total += ceil(max(height, AITypography.body.aiLineHeight))
            case .code(let code, _):
                // ⚠️ 走业务层的 `AICodeBlockMetrics`，**不是** App 侧那个视图的静态方法。
                // 视图侧的同名入口（`AICodeBlockView.height`）本身就是转发到这里 ——
                // 量高与显示共用一份口径，是本工程「行高量算必须与 cell 同源」的落点。
                total += AICodeBlockMetrics.height(for: code, width: width)
            case .math(let latex):
                // 同上：`AIMathBlockMetrics.height` 与两端视图取图走的是同一次排版
                // （`AIPlatformMath.size` / `.image` 共用 `makeLabel` + `fittedSize`）
                total += AIMathBlockMetrics.height(for: latex, width: width)
            }
        }
        return total
    }

    // MARK: - 纯文本（语音朗读用）

    /// Markdown → 纯文本，供 `AISpeechReader` 朗读。
    ///
    /// 直接取 AST 渲染结果的 `.string`：`**加粗**` 变「加粗」、`# 标题` 变「标题」、
    /// 链接只留文字、代码块保留内容，**不会把 `*` `#` `|` 这些符号念出来**。
    /// 与屏上渲染同源（同一份 AST），不存在「显示一套、朗读另一套」的漂移。
    ///
    /// - Note: 解析失败时回落到原文，宁可多念几个符号也不要无内容可读。
    public static func plainText(from markdown: String) -> String {
        // 🔴 块级公式**不朗读**：`\frac{-b \pm \sqrt{b^2-4ac}}{2a}` 念出来是一串反斜杠
        //    命令，用户听到的只有「backslash frac」，一丁点信息都没有。
        //    所以先按**屏上的切分**（`parseSegments`）把 `.math` 段整段剔掉，
        //    剩下的每段取富文本的 `.string` —— 与改造前「取 AST 结果」同一口径
        //    （加粗去符号、链接只留文字、代码块保留内容）。
        // ⚠️ 用 `parseSegments` 而不是 `segments`：后者要读 `AIFontSizeRevision`
        //    （`@Observable`，只在主线程安全），而朗读是在后台队列上跑的。
        let raw = parseSegments(from: markdown).compactMap { segment -> String? in
            switch segment {
            case .text(let attributed): return attributed.string
            case .code(let code, _): return code
            case .math: return nil
            }
        }.joined(separator: "\n")
        // 折叠空行：朗读靠分段停顿（`AISpeechReader.chunk`）控制节奏，
        // 这里留一堆空行只会让切分出的片段全是空白
        var lines: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines.joined(separator: "\n")
    }
}
