//
//  MarkdownRenderer.swift
//  AsterMac
//
//  助手回复的渲染：把 `AIMarkdown` 切出来的段，逐段画成 SwiftUI 视图。
//
//  ## 与 iOS 侧的分工
//  切分逻辑（哪一段是文本、哪一段是围栏代码）**完全复用业务层的 `AIMarkdown.segments`** ——
//  那是本工程「量高与显示同源」的落点，不该在 Mac 上再写一份。
//  Mac 这边只负责「怎么画」：文本段转 `Text`，代码段转卡片。
//
//  ## ⚠️ NSAttributedString → SwiftUI Text 的两个未知数
//  ① `AttributedString(nsAttributedString)` 会尽量把 AppKit 的属性（`.font` / `.foregroundColor`）
//     带过来，但 SwiftUI 的 `Text` **只认它自己支持的那一批**；段落样式（行距）一律会被忽略。
//  ② 万一某个属性没被认下来（同一个属性在不同 macOS 版本上行为不一致），
//     正文就会退化成系统默认字号 —— 与 `AITypography` 的正文基准不一致，混排时一眼看得出。
//     （颜色也会退化，但 Mac 侧正文已是语义色，退化结果恰好也是语义色，影响比字号小。）
//
//  所以这里**在视图层再兜一次**字体与颜色：run 上的属性优先级更高（认下来时以它为准），
//  认不下来时由视图层的值顶上。两个属性都不丢，是这一段最要紧的事。
//  行距的差异留在明面上：`AIMarkdown` 里那套 `paragraphStyle` 在 SwiftUI 上不生效，
//  段间节奏由这里 `VStack` 的 `segmentSpacing` 表现（数值仍取业务层常量）。
//

import SwiftUI
import AppKit
import AICore
// 行内公式的附件类型定义在接缝层（`NSTextAttachment` 是平台类型，只能在 `AIPlatform/` 里碰）。
// ⚠️ `import AICore` **不会**顺带把 AIPlatform 的符号带进来 —— 必须显式 import。
import AIPlatform

/// 助手行的正文（没有气泡底，直接画在页面背景上）
struct AssistantTextView: View {
    let text: String
    let isStreaming: Bool
    /// 外层提议给正文的宽度（`ChatRowView.maxBubbleWidth`）。
    ///
    /// 只有一件事用它：**给链接的鼠标命中判定当布局宽度**（`MacLinkHit`）。
    /// ⚠️ 必须传**提议宽度**而不是「文本自然宽度」—— 文本折行用的就是提议宽度，
    ///    自然宽度可能更窄（短文本），拿它去布局会让折行点对不上。
    /// ⚠️ 别在 `AssistantTextView` 内部重算 `max(containerWidth * 0.8, 160)`：
    ///    那个公式的单一来源是 `ChatRowView`，两处各写一遍迟早漂。
    let layoutWidth: CGFloat

    var body: some View {
        if isStreaming {
            // 流式态是**原始 Markdown 源文**（`**` `#` 都还在），与 iOS 侧同样不渲染
            plain
        } else {
            let segments = AIMarkdown.segments(from: text)
            VStack(alignment: .leading, spacing: AIMarkdown.segmentSpacing) {
                ForEach(Array(segments.enumerated()), id: \.offset) { item in
                    switch item.element {
                    case .text(let attributed):
                        rich(attributed)
                    case .code(let code, let language):
                        CodeCardView(code: code, language: language)
                    case .math(let latex):
                        // 宽度用**外层提议给正文的宽度**（`layoutWidth`），与 `ChatRowView`
                        // 那句「max(containerWidth * 0.8, 160)」同源 —— 公式的缩放上限
                        // 不能自己另算一遍。
                        MathBlockView(latex: latex, maxWidth: layoutWidth)
                    }
                }
            }
        }
    }

    private var plain: some View {
        Text(text).modifier(AssistantTextChrome())
    }

    @ViewBuilder
    private func rich(_ attributed: NSAttributedString) -> some View {
        // 🔴🔴 **两道富文本补丁的顺序是承重的，⛔ 别调换**：
        //   ① `MacDownInk` 把 Down 写死在 run 上的固定墨色（`body: .black` 等）
        //      换成明暗两档语义色 —— 不换的话深色模式下是「黑字写深底」，
        //      **且视图层的 `.foregroundStyle` 救不了**（run 属性优先级更高，见 `MacDownInk` 文件头）。
        //   ② `MacLinkify` 给链接区间刷 `MacTheme.linkTextNSColor`。
        // 反过来的话，链接刚刷上的蓝会被 ① 当正文色刷掉 ⇒ 网址不再是蓝的
        //（`MacDownInk` 内部也会主动避开链接区间，但**顺序仍不许反**：
        //  ② 只补 `.link`、真正的上色在 `apply` 内部，语义上就是「先正文后链接」）。
        //
        // 送进 `Text` 之前先补一道「裸网址 → 链接 + 上色」（`MacLinkify`）。
        //    Down 只给 `[文字](url)` 那种 Markdown 链接语法生成 `.link`，
        //    而模型最常吐的是**裸网址**（用户 2026-09-30 给的截图里就是一条
        //    `https://www.baidu.com`）—— 不补的话它在屏上就是普通文字，点不动。
        //    ⚠️ 补完还给所有链接刷上链接色：SwiftUI 的 `Text` **不会**给 `.link` run
        //    换色（它只管「可点」），不刷的话网址与正文同色、看不出是链接
        //    （用户当天第二句要求：「在会话页面 网址应该显示 蓝色」）。
        //    ⚠️ 这一步**只加 `.link` 与 `.foregroundColor`**，不碰字体/段落样式 ⇒ 行高与折行不变。
        //    来由、性能早退与四条口径见 `MacLinkify.swift` 文件头。
        //
        //    2026-09-30 第三句：「网址链接，在鼠标移动到网址上时，网址底部增加横线」——
        //    交给 `LinkHoverText`（hover 判定见 `MacLinkHit.swift`；`Text` 自己不给 hover 态）。
        let inked = MacLinkify.apply(to: MacDownInk.apply(to: attributed))
        // 🔴 含**行内公式**的段走另一条路（2026-10-27）：
        //    `Text` **不认 `NSTextAttachment`** ⇒ 那段里的公式会画成一个空白方块。
        //    只能把富文本按附件切成「文字 / 图 / 文字」再 `Text + Text` 拼起来。
        // ⚠️ 这条路径没有 hover 命中层（`MacLinkHit` 按纯字符串算矩形，图会让位置全错）
        //    ⇒ 含公式的段里**网址仍然可点，但鼠标移上去不会加下划线、也不会变小手**。
        //    这是刻意取舍：宁可少一个装饰，也不要让下划线落在错位置。
        if InlineMathText.containsInlineMath(inked) {
            InlineMathText(attributed: inked)
        } else {
            LinkHoverText(attributed: inked, layoutWidth: layoutWidth)
        }
    }
}

/// 含**行内公式**的正文段：把富文本按附件切成「文字 / 图 / 文字」，再拼成一个 `Text`。
///
/// ## 为什么不能继续用 `Text(AttributedString)`
/// SwiftUI 的 `Text` **不认 `NSTextAttachment`**（只认它自己那批属性）。
/// 而业务层为了让**行高算得准**，必然要把行内公式做成附件 —— 无图的 attachment 完全不参与
/// 行高（实测 24pt 高的无图附件挂上去，行高还是 20pt），只有真实附件才会被 `boundingRect` 计入。
/// 所以这一段必须自己拆成多段 `Text` 再拼。
///
/// ## 代价（明确记下来，⛔ 别以后当成 bug 去修）
/// `MacLinkHit` 是按「纯字符串 + 宽度」重建 TextKit 栈来算链接矩形的，图会让字符位置与
/// 实际字形位置对不上 ⇒ **含公式的段不做 hover 判定**（没有下划线、没有小手）。
/// 但 `.link` 本身仍由 `Text` 处理，网址照样点得动。
struct InlineMathText: View {
    /// 已过 `MacDownInk` + `MacLinkify` 的富文本（顺序见 `AssistantTextView.rich`）
    let attributed: NSAttributedString

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        assembled.modifier(AssistantTextChrome())
    }

    /// 这一段里有没有公式附件（没有就交给原来的 `LinkHoverText`，保住 hover 能力）。
    static func containsInlineMath(_ attributed: NSAttributedString) -> Bool {
        guard attributed.length > 0 else { return false }
        var found = false
        attributed.enumerateAttribute(.attachment,
                                      in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if value is AIMathAttachment {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private var assembled: Text {
        let length = attributed.length
        guard length > 0 else { return Text("") }
        let inkKey = colorScheme == .dark ? "dark" : "light"
        var parts: [Text] = []
        var cursor = 0

        attributed.enumerateAttribute(.attachment,
                                      in: NSRange(location: 0, length: length)) { value, range, _ in
            guard let math = value as? AIMathAttachment else { return }
            // 附件之前的那截文字
            if range.location > cursor {
                let plain = attributed.attributedSubstring(
                    from: NSRange(location: cursor, length: range.location - cursor))
                parts.append(Text(AttributedString(plain)))
            }
            // 公式：按当前明暗档现渲（业务层塞的是透明占位图，见 `AIPlatformMath.placeholder`）
            if let image = AIMathBlockMetrics.inlineImage(latex: math.latex,
                                                          inkKey: inkKey,
                                                          color: .labelColor) {
                // `baselineOffset` 直接沿用业务层给 attachment 算好的 `bounds.origin.y`
                //（`Text(Image)` 默认把图底对齐基线，与 attachment 的语义一致）
                parts.append(Text(Image(nsImage: image)).baselineOffset(math.bounds.origin.y))
            } else {
                // 排不出 ⇒ 还源码，别留一个空白方块
                parts.append(Text(verbatim: "$\(math.latex)$"))
            }
            cursor = range.location + range.length
        }

        if cursor < length {
            let tail = attributed.attributedSubstring(from: NSRange(location: cursor, length: length - cursor))
            parts.append(Text(AttributedString(tail)))
        }
        return parts.reduce(Text("")) { $0 + $1 }
    }
}

/// 一段助手正文 + 「鼠标压到网址上就给它加下划线、并把光标变成小手」。
///
/// ## 为什么不能靠 `Text` 自己
/// SwiftUI 的 `Text` 把 `.link` run 渲染成「这串字可点」，但**没有任何 hover 事件**，
/// 也不暴露行 / 字形几何 ⇒ 想知道「鼠标现在压在哪条链接上」只能另算（`MacLinkHit`）。
///
/// ## 分工
/// - `MacLinkHit` 负责**判定**（纯查表，可以每帧调）；
/// - 这里负责**状态**：`hoveredLink` 一变就换一份「那条链接带下划线」的富文本；
/// - `MacLinkCursor` 负责**光标**（同一个 `hoveredLink` 判据，命中就小手）。
///
/// ⚠️ 下划线的加法在 `MacLinkHit.displayString(_:underlining:)` 里，用的是 **SwiftUI 自己的
///    `underlineStyle`**（不是 AppKit 的）—— 别改成往 `NSAttributedString` 上 `addAttribute`：
///    ① `MacLinkify` 有一条契约禁它之外的东西；② SwiftUI 只认自己那一批属性。
///
/// ## ☠️ 性能：命中层只许建一次
/// `MacLinkHit.init` 要建一套 TextKit 栈。它**绝不能**出现在 `onContinuousHover` 的回调里
/// （那是每帧都在跑的），而是 `onAppear` / 文本变 / 宽度变时建一次。
/// 这也是为什么这里用 `onChange` 而不是 `.task(id:)`：`.task` 的闭包是 `@Sendable`、
/// 不继承 `MainActor`，而 `NSLayoutManager` 那一套只能在主线程序上碰。
private struct LinkHoverText: View {
    let attributed: NSAttributedString
    let layoutWidth: CGFloat

    @State private var hoveredLink: Int?
    @State private var hit: MacLinkHit?

    var body: some View {
        Text(MacLinkHit.displayString(attributed, underlining: hoveredLink))
            .modifier(AssistantTextChrome())
            // 坐标是**本地坐标**（左上原点，原点 = 这个 `Text` 的 frame 左上角），
            // 与 `MacLinkHit` 算出来的矩形同一个坐标系 —— 中间没有任何位移修饰符。
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let found = hit?.linkIndex(at: point)
                    // ⚠️ 值没变就别写状态：`onContinuousHover` 每帧都回调，
                    //    无条件写会让 `body` 每帧重算一遍（还连带重建富文本）。
                    if found != hoveredLink { hoveredLink = found }
                    // 🔴 光标：压在哪条链接上 → 小手（用户 2026-10-02 要求）。
                    //    判据**复用**上面那个 `found`（= `MacLinkHit` 的矩形），
                    //    ⛔ 别为光标另建一套命中判定 —— 两套迟早漂，会出现
                    //    「有下划线但光标是箭头」这种一眼假。
                    //    ☠️ **每次回调都必须调**（2026-10-04 修）—— ⛔ 别加「值没变就跳过」
                    //    的守卫，那正是「移上去没有小手」的成因，见 `MacLinkCursor` 文档。
                    MacLinkCursor.apply(linkIndex: found)
                case .ended:
                    if hoveredLink != nil { hoveredLink = nil }
                    // 离开这个 `Text`：还原箭头。⚠️ 留这一步**不是**因为「set 是粘的」——
                    // set 其实不粘（每次鼠标移动系统都会重设光标）。它只是让「移出后
                    // 立刻表态」，不必等用户再动一次鼠标。
                    MacLinkCursor.apply(linkIndex: nil)
                }
            }
            .onAppear { rebuildHit() }
            // 文本变了（重新生成 / 编辑重发 / 流式收尾）⇒ 命中层作废
            .onChange(of: attributed.string) { _, _ in rebuildHit() }
            // 窗口拉伸 ⇒ 折行点全变 ⇒ 命中层作废
            .onChange(of: layoutWidth) { _, _ in rebuildHit() }
            // 🔴 字号档位变了 ⇒ 折行点与链接矩形**全变** ⇒ 命中层作废（2026-10-15 加）。
            //    ⚠️ 必须显式列出来：只改字号时 `attributed.string` **一模一样**，
            //       上面那条 onChange 根本不触发 ⇒ 下划线与小手会落在错位置。
            //    （顺带把「本视图依赖字号」这件事登记下来 —— 与 `AssistantTextChrome`
            //      那处 `.font` 各管一段：那处让文字重画，这处让命中层重建。）
            .onChange(of: AITypography.bodyFontSize) { _, _ in rebuildHit() }
    }

    private func rebuildHit() {
        hit = MacLinkHit(attributed: attributed, width: layoutWidth)
        if hit == nil { hoveredLink = nil }
    }
}

/// 鼠标压在链接上时的**光标**（用户 2026-10-02：「鼠标在移动到链接上时，鼠标变成小手」）。
///
/// 🔴 判定**复用** `MacLinkHit.linkIndex(at:)` —— 与下划线同一套矩形，⛔ 别为光标另建一套。
///
/// ## ☠️☠️ 2026-10-04 修：**每次回调都要 `set()`，不许「只在状态翻转时 set」**
///
/// 用户报「鼠标移到网址链接上时小手不好用了」。成因就是原先那个「只在翻转时设一次」的优化：
/// ```swift
/// guard flag.isHand != wantHand else { return }   // ☠️ 前提错了
/// ```
/// 它建立在「`NSCursor.set()` 是**粘的**、设过一次就一直保持」这个**反了的**理解上。
/// 实际恰好相反 —— `set()` **不粘**：它只影响当下，
/// **下一次鼠标移动时 AppKit 会按 cursor rect 重新决定光标**：
/// - 我们**没有声明任何 cursor rect** ⇒ 该区域落到默认光标；
/// - 更糟的是正文挂着 `.textSelection(.enabled)` ⇒ 系统在那里摆的是 **I-beam（文本光标）**。
///
/// ⇒ 只设一次的结果 = 小手**立刻被系统按回去**，表现为「移到链接上没有小手」。
/// ✅ 正解 = **每次 `onContinuousHover` 回调都 set**（它本来就每次鼠标移动都回调，
///    正好抵消系统那一次重置；鼠标停下后系统不再改光标，小手就稳住了）。
///
/// ⚠️ 顺带修掉另一个症状：原 `flag` 是引用书签，一旦 `.ended` 没触发
///    （快速移出窗口 / 视图被回收），`isHand` 就卡在 `true` ⇒ **再也不 set**，
///    光标一直粘在小手上。去掉 `flag` 之后「每次移动都重新表态」，不存在卡死态。
///
/// ⚠️ 做成静态函数而不是内联在 hover 回调里，是为了**能验**：本机合成鼠标事件投不出去
///    （`CGEvent.post` 静默无效）⇒ 真光标只能人手按鼠标验；能自动验的只有
///    「命中 → 期望光标」这条映射（`LINKHOVER` 探针顺带守它）+ 源码契约。
///    ☠️ 契约（`render_mac_ui.sh`）按**行首文本**断言下面两个调用点形式，⛔ 别改调用写法。
enum MacLinkCursor {

    /// 命中链接 → 小手；否则箭头。
    static func cursor(linkIndex: Int?) -> NSCursor {
        linkIndex == nil ? .arrow : .pointingHand
    }

    /// 🔴 **每次回调都调**。⛔ 别加「值没变就跳过」的守卫 —— 那正是 2026-10-04 修的 bug。
    static func apply(linkIndex: Int?) {
        cursor(linkIndex: linkIndex).set()
    }

    /// 非链接的**可点元素**（如引用条 `ChatRowView.userQuoteStrip`）→ 小手；离开 → 箭头。
    ///
    /// 2026-10-21 加。为什么另开一个入口而不是让调用方自己 `NSCursor.pointingHand.set()`：
    /// 🔴 **全 App 的手型光标只许这一个文件给** —— `render_mac_ui.sh` 有条契约数
    ///    `.pointingHand` 出现在几个文件里（期望 1）。那不是洁癖：2026-10-02 的教训是
    ///    「每处各写一遍光标逻辑 ⇒ 有的地方小手会被系统按回去、有的地方粘着取不下来」，
    ///    而「每次回调都 set、不许 guard」这条要点也**只该守护在一处**。
    ///    ⇒ 新入口照样收敛到这里，「不粘」的教训自动继承。
    /// ⚠️ 与 `apply(linkIndex:)` 同样**不许加 guard**（原因同上，见那个函数的文档）。
    static func applyInteractive(_ interactive: Bool) {
        (interactive ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
}

/// 助手正文的公共修饰：字体 / 颜色兜底 + 可选中 + **允许竖向自然展开、横向按容器折行**
///
/// 🔴 这里**刻意不写 `.frame(maxWidth: .infinity)`**。
/// 早先写过，后果是：`Text` 被拉满可用宽度 → 外面那层背景跟着变成「整块 80% 宽」→
/// 助手回一句「好的」也画出一个一人宽的空盒子（当时的症状是整块浅灰气泡）。
/// 助手行现在没有气泡底了，但这条约束仍要守 —— 一旦拉满，**行宽就不再由
/// `maxBubbleWidth` 决定**，`Text` 的折行位置也跟着变。
/// 正确的分工是——**这里只管让文本按内容量尺寸**，宽度上限交给 `ChatRowView` 的
/// `.frame(maxWidth: maxBubbleWidth)` 夹（`Text` 会在被夹到的那个宽度上折行）。
private struct AssistantTextChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(MacTheme.body)
            .foregroundStyle(MacTheme.bodyColor)
            .textSelection(.enabled)
            // 水平**不**固定（要能折行），垂直固定（多行不许被压缩）
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 围栏代码卡片
///
/// 尺寸常量取 `AICodeBlockMetrics`（业务层），与 iOS 卡片同一份口径 ——
/// 这样两端的留白、头部高度、折行宽度看起来是一套东西。
/// - Note: SwiftUI 自己量高（`Text` 会按实际布局折行），所以**不需要**用
///   `AICodeBlockMetrics.height(for:width:)` 预先算高；那个函数是给 UITableView 的
///   `heightForRowAt` 用的。这里取常量是为了视觉一致，不是为了布局。
struct CodeCardView: View {
    let code: String
    let language: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.isEmpty == false ? language! : L("代码"))
                    .font(MacTheme.ui(11))
                    .foregroundStyle(MacTheme.codeHeaderText)
                Spacer(minLength: 0)
                Button {
                    copy()
                } label: {
                    Text(copied ? L("已复制") : L("复制"))
                        .font(MacTheme.ui(11))
                        .foregroundStyle(MacTheme.codeHeaderText)
                }
                .buttonStyle(.plain)
                .help(L("复制这段代码"))
            }
            .padding(.horizontal, AICodeBlockMetrics.contentPadding)
            .frame(height: AICodeBlockMetrics.headerHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(MacTheme.codeCardBorder)
                    .frame(height: 1)
            }

            Text(code)
                .font(MacTheme.code)
                .foregroundStyle(MacTheme.codeText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AICodeBlockMetrics.contentPadding)
        }
        .background(
            RoundedRectangle(cornerRadius: 6).fill(MacTheme.codeCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(MacTheme.codeCardBorder, lineWidth: 1)
        )
        // ⚠️ 刻意**不用** `AICodeBlockMetrics.sideInset`。
        // 那个常量的语义是「代码卡片距**气泡边缘**的距离」—— 助手行现在没有气泡底了，
        // 正文直接顶到列表左边距；卡片若还缩进一截，就会比正文左突出一块（实测差 17pt）。
        // 卡片内部的留白仍走 `AICodeBlockMetrics.contentPadding`（那是卡片自己的内边距，语义未变）。
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        // 2 秒后收回「已复制」——不收回的话，第二次点会以为没生效
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}

/// 首字到达前的等待指示（三个点）
///
/// 用 `TimelineView(.periodic)` 驱动，而不是 `Timer` + `@State`：
/// 没有需要维护的定时器、没有 `invalidate` 时机问题，视图消失即自动停。
struct TypingIndicator: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(MacTheme.typingDot)
                        .frame(width: 6, height: 6)
                        .opacity(index == step ? 1 : 0.3)
                }
            }
        }
    }
}
