//
//  MacDownInk.swift
//  AsterMac
//
//  把助手正文富文本里 **Down 写死的固定墨色**换成 Mac 的明暗两档语义色（2026-10-07）。
//
//  ## 🔴 为什么非做不可：run 上的属性**压过**视图层的 `.foregroundStyle`
//
//  渲染链是 `AIMarkdown`（Down / cmark）→ `NSAttributedString` → `Text(AttributedString)`。
//  Down 的 `StaticColorCollection` **默认值把墨色写进每个 run**（源码 `ColorCollection.swift`：
//  `body: .black`、`quote: .darkGray`、`listItemPrefix: .lightGray`），
//  而 run 上的 `.foregroundColor` 优先级**高于** SwiftUI 视图层那个
//  `.foregroundStyle(MacTheme.bodyColor)`（`AssistantTextChrome` 里就写着它）。
//  ⇒ **视图层改语义色对助手正文毫无作用**，深色模式下就是「黑字写深底」。
//
//  📌 **实测**（`ImageRenderer`，铺 `textBackgroundColor` 底，按像素统计墨色）：
//  | run 上的前景色 | 浅色 | 深色 |
//  |---|---|---|
//  | `NSColor.black`（= 现状，Down 默认） | 黑字 ✅ | **ink=0，一个字都看不见** ❌ |
//  | 动态语义色（本文件的做法） | 黑字 ✅ | 白字 ✅ |
//  | 整段剥掉 run 色、交视图层兜底 | 黑字 ✅ | 白字 ✅（但会**丢掉**引用/序号的分档）
//  ⇒ 选「换色」而不是「剥色」：剥色虽然也能看见，但 Down 刻意给的
//  **引用（深灰）/ 列表序号（浅灰）层次就全没了**，四档文字会糊成一片。
//
//  ## 为什么**不**去改业务层
//  `AIMarkdown` / `AITypography` 是**两端共享**的，而 iOS 侧的助手气泡是**固定浅灰底**
//  ⇒ 那边**必须**配固定深字（改成语义色的话，暗色下白字写浅灰底，同样看不见）。
//  两端从「气泡形态」这一步就分叉了，**分叉点收在视图层**（`MacTheme.swift`）——
//  ⛔ 别把这个改动上提到 `AIMarkdown` 或 `DownStylerConfiguration.colors`。
//
//  ## 🔴 与 `MacLinkify` 的**顺序**是承重的
//  本函数**只处理「不是链接」的那些 run**，链接那一段原样放过 ⇒ **必须先跑本函数、
//  再跑 `MacLinkify`**（后者会给链接区间刷上 `MacTheme.linkTextNSColor`）。
//  反过来的话，链接刚刷上的蓝会被本函数当正文色刷掉 ⇒ 网址不再是蓝的。
//  📌 这个顺序由 `MarkdownRenderer.AssistantTextView.rich(_:)` 那一行固定，
//    `render_mac_ui.sh` 里有契约钉住（⛔ 别把两个调用调换位置）。
//
//  ## 为什么**不动 `.font`**
//  行高量算（iOS 的 `AIMarkdown.contentHeight`、mac 侧同一份富文本）读的是**同一份**富文本，
//  改字体/段落属性会连带改变折行与行高 —— 那就成了一次「顺手改了版式」。
//  ✅ 颜色不在其列：`.foregroundColor` 只是给同一批字形换墨色，`boundingRect` **逐像素不变**。
//  （这条口径与 `AILinkify` 文件头那四条完全一致，两处是同一个道理。）
//

import Foundation
import AppKit
import AICore

enum MacDownInk {

    /// 把 run 上的 Down 固定墨色换成 `MacTheme.downInk` 里的明暗两档色。
    ///
    /// - Returns: 换了色的**新**字符串；本来就一个固定色都没有时**原样返回入参**
    ///   （与 `AILinkify` 同一套早退口径：绝大多数段落不需要改，别每帧白拷一份）。
    static func apply(to attributed: NSAttributedString) -> NSAttributedString {
        guard attributed.length > 0 else { return attributed }

        let full = NSRange(location: 0, length: attributed.length)

        // 链接区间先算出来并**从候选里挖掉** —— Down 给它们的 `.blue` 由 `MacLinkify` 管，
        // 本函数碰了就等于把链接色覆盖掉（见文件头「与 MacLinkify 的顺序」）。
        let linkRanges = MacLinkify.linkRanges(in: attributed)

        // 判据 = 「这个 run 的墨色是不是 Down 默认调色板里的某一档」。
        // ⚠️ 只能**按值比**（Down 不留「我是哪一档」的标记），所以这张表必须与
        //    Down 的 `StaticColorCollection` 默认值**逐项对齐**；Down 改了默认值，
        //    这里就漏一档 ⇒ 那档退回「深色下看不见」。`render_mac_ui.sh` 有契约钉住表项数。
        var matched = false
        let mutable = NSMutableAttributedString(attributedString: attributed)
        mutable.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            // 🔴 `downInk[slot]` 是 `NSColor?`（字典下标）⇒ 必须解包后再传给
            //    `value: Any`。直接传会把 `Optional` 整个装箱进 `Any`
            //    （Xcode 27 起报 "implicitly coerced from 'NSColor?' to 'Any'"），
            //    而 `render_mac_ui.sh` 的契约钉住表项数 ⇒ 槽位一定齐，nil 只可能是未来
            //    新增槽位忘了补表 —— 那种情形**跳过**比装箱一个 nil 进去更安全。
            guard let color = value as? NSColor,
                  let slot = MacDownInk.slot(for: color),
                  let ink = MacTheme.downInk[slot],
                  !Self.overlaps(range, linkRanges) else { return }
            mutable.addAttribute(.foregroundColor, value: ink, range: range)
            matched = true
        }
        return matched ? mutable : attributed
    }

    // MARK: - Down 默认色 → 档位

    /// 这支颜色对应 Down 默认调色板的哪一档？认不出返回 `nil`（**原样保留**）。
    ///
    /// ⚠️ 比对**必须容忍 alpha 与色彩空间差异**：`Down` 写的是 `NSColor.black` 这类
    ///    「颜色库里的具名黑」，而 run 上取回来的可能是它的某个等价物；
    ///    一律先转 `.sRGB` 再逐分量比。
    /// ⚠️ 容差 **0.02**：Down 那三个默认值的间距（0 / 0.333 / 0.667）远大于它，
    ///    而同一支色的不同表述（具名 / 设备灰阶）经 sRGB 转换后的偏差在 0.01 量级。
    ///    ⛔ 别把容差放大到 0.05 以上 —— 那样 `0.667` 会被 `0.62` 认成 `.meta`，
    ///    出现「序号被刷成正文色」这种一眼假的分层错乱。
    static func slot(for color: NSColor) -> MacTheme.DownInkSlot? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
        // Down 的三个默认色都是**无彩色**（R=G=B）⇒ 只比 R 一个分量就够，
        // 顺带把「有色但很暗」的情况挡在外面（那种一律不认、不动）。
        guard abs(r - g) < 0.02, abs(g - b) < 0.02 else { return nil }
        let gray = r
        if abs(gray - 0.000) < 0.02 { return .body }   // colors.body / 各级 heading / 行内 code
        if abs(gray - 0.333) < 0.02 { return .quote }  // colors.quote
        if abs(gray - 0.667) < 0.02 { return .meta }   // colors.listItemPrefix
        return nil
    }

    /// `range` 与 `ranges` 里任意一个是否相交。
    ///
    /// ⚠️ 用 `NSIntersectionRange` 而不是「端点比较」——**相邻**的两个区间端点会相等，
    /// 端点比较会把它们判成相交（链接前那一字正好与链接贴合，是常见布局）。
    private static func overlaps(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSIntersectionRange($0, range).length > 0 }
    }
}
