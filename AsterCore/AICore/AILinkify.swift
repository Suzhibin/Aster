//
//  AILinkify.swift
//  AICore
//
//  把助手正文里的网址**变成看得见、点得动**的链接（2026-09-30 mac 起、2026-10-02 提到共享层）。
//
//  ## 为什么需要这一步（不补就是「点不动」）
//  用户（2026-09-30，mac）：「豆包这种网页链接是可以点击的，点了在右侧打开一个窗口显示网页」。
//  用户（2026-10-02，iOS）：「会话返回 网页地址 显示蓝色，点击网页地址 push 进入 web 页面」。
//
//  渲染链是：`AIMarkdown`（Down / cmark）→ `NSAttributedString` → 各端的视图。
//  Down 只给 **Markdown 链接语法**（`[文字](https://…)`）生成 `.link` 属性 ——
//  而模型实际最常吐的偏偏是**裸网址**（用户截图里就是一条 `https://www.baidu.com` 独立成行）。
//  cmark 的默认选项**不含** gfm 的 autolink 扩展 ⇒ 这种网址在屏上只是一段普通文字，
//  hover 不出手型、点了没有任何反应，看起来像「App 不支持链接」。
//
//  ⇒ 这里在**送进视图之前**跑一遍 `NSDataDetector`，把裸网址补上 `.link`。
//
//  ## 为什么还要**上色**
//  用户（2026-09-30）：「在会话页面 网址应该显示 蓝色」。
//  mac 侧实测：**SwiftUI 的 `Text` 不会给 `.link` run 换色**（也不加下划线）——
//  它只负责「这段字可点」⇒ 颜色得自己写上去（这正是本函数带 `linkColor` 参数的原因）。
//  iOS 侧 `UITextView` 会按 `linkTextAttributes` 给链接上色，但**两端共用同一份富文本**更省心：
//  颜色一并在富文本里写好，`UITextView` 那层再钉一次 `linkTextAttributes` 兜底。
//
//  ## 🔴 四条口径
//  ① **只加 `.link` 与 `.foregroundColor`，绝不碰 `.font` / `.paragraphStyle`。**
//     行高量算（iOS 的 `AIMarkdown.contentHeight`、mac 侧走同一份富文本）读的是同一份富文本 ——
//     字体或段落属性会连带改变**折行与行高**，那就成了「顺手改了版式」。
//     ✅ **颜色不在其列**：`.foregroundColor` 只是给同一批字形换墨色，不参与文本布局，
//     `boundingRect` 的结果**逐像素不变**（这是本条口径能放行颜色、却仍禁字体的唯一理由）。
//     📌 有机械契约盯着（`render_mac_ui.sh`）：本文件**不许**出现
//     `addAttribute(.font/.paragraphStyle/.backgroundColor)`，也不许加常驻 `.underlineStyle`。
//  ② **放在共享层（AICore），两端各传自己的链接色**（mac `MacTheme.linkTextNSColor`、
//     iOS `UIColor.link`）。此前它是 mac 侧的 `MacLinkify`，注释里写着「iOS 那边没提这个需求」——
//     2026-10-02 iOS 也提了同一个需求，于是把**判定与改写逻辑**上移到这里，
//     `MacLinkify` 退化成一层「绑颜色」的转发壳（⛔ 别把逻辑再抄回任一端的视图层）。
//  ③ 非 http(s) 的（`mailto:` / `tel:` / 自定义 scheme）**不新造链接** —— 那些不该开网页。
//     ⚠️ 但如果**Down 本来就把某段文字做成了链接**（`[写信](mailto:a@b.com)`），
//     我们**照样给它上色**：它确实是个链接，蓝着才一致（我们只是不主动造新的）。
//  ④ **原文没写 scheme 的网址按 https 处理**（`www.xxx.com` 这种）。
//     现实是：`NSDataDetector` 会**自己替你补一个 `http://`**，而 `http` 会被 ATS 拦死
//     （iOS 的 Info.plist 现在还开着 `NSAllowsArbitraryLoads`，但 mac 那侧是硬拦）⇒
//     不升的话这类网址「补了链接却打不开」。
//     ⚠️ 反过来，用户**显式**写了 `http://` 的照原样用：那是他的选择，
//        偷偷升成 https 会让点开的是另一个页面。
//
//  ## ⚠️ 性能：两道早退
//  mac 侧它挂在每次 `body` 求值里、iOS 侧挂在每个 text 段的装配里 ⇒ 端上会反复调。
//  `NSDataDetector` 对一段几百字的文本大约零点几毫秒 —— 单次不算什么，但滚动时
//  每行每帧都跑就成了可感的开销。而绝大多数段落**既没有裸网址、也没有链接**，
//  所以先做两件便宜的事（字符串 contains + 走一遍属性 run），都没有就原样返回。
//  ⚠️ 第二道（找已有 `.link`）**不能省**：`[文字](https://…)` 这种写法里，
//     可见文字是「文字」两个字，`contains("http")` 判不出来 —— 少了它，Down 造的链接就不上色。
//

import Foundation
import AIPlatform

public enum AILinkify {

    /// 补链接 + 上色。没网址也没链接时**原样返回入参**（同一个对象，连拷贝都不做）。
    ///
    /// - Parameter linkColor: 链接墨色。**由各端自己给**（mac `MacTheme.linkTextNSColor`、
    ///   iOS `UIColor.link`）—— 共享层不碰平台颜色成员（见 `AIPlatformText` 的说明）。
    public static func apply(to attributed: NSAttributedString,
                             linkColor: AIPlatformColor) -> NSAttributedString {
        let text = attributed.string
        let full = NSRange(location: 0, length: (text as NSString).length)

        // 早退的两道闸（见文件头「性能」）：
        //   ① 有没有「可能是网址的文字」；② 有没有 Down 已经造好的链接。
        let bareURLText = text.contains("http://") || text.contains("https://") || text.contains("www.")
        let linkedRanges = linkRanges(in: attributed)
        guard bareURLText || !linkedRanges.isEmpty else { return attributed }

        let mutable = NSMutableAttributedString(attributedString: attributed)

        // ① **Down 造出来的链接**（`[文字](url)`）：只上色，`.link` 已经是它的了。
        //    ⚠️ 这一串 range 是**先收集后修改**的：一边 `enumerate` 一边 `addAttribute`
        //       会踩「边遍历边改」的坑（属性一改，枚举的区间划分就变了）。
        for range in linkedRanges {
            mutable.addAttribute(.foregroundColor, value: linkColor, range: range)
        }

        guard bareURLText else { return mutable }

        // ⚠️ `NSDataDetector` 的构造是**可失败**的，且在旧系统上偶尔返回 nil；
        //    拿不到就老老实实不补（宁可点不动，也不要因为一个可选链接把整段正文弄丢）。
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return mutable }

        detector.enumerateMatches(in: text, options: [], range: full) { result, _, _ in
            guard let result, let detected = result.url else { return }

            // ① 只认网页：`mailto:` / `tel:` 一律跳过（见文件头口径 ③）。
            let scheme = detected.scheme?.lowercased()
            if let scheme, scheme != "http", scheme != "https" { return }

            // ② **原文里没写 scheme 的，统一按 https 处理**。
            //
            //    两种情形都会走到这里：
            //    - `NSDataDetector` 对 `www.example.com` 这种给的是 **nil scheme**；
            //    - 更常见的是它**自己替你补了一个 `http://`** —— 而 `http` 会被 ATS 拦死。
            //
            //    所以判据不是「scheme 是不是 nil」，而是**原文那一截里有没有显式写 scheme**：
            //    写了就尊重用户（哪怕写的是 `http://`，那是他的选择，失败也有错误页兜着），
            //    没写就升到 https —— 今天绝大多数站点都支持 https，升上去是净收益。
            //
            //    ⚠️ **别改成「无条件升 https」**：用户明确贴了一条 `http://` 链接时把他
            //       偷偷改成 https，点下去打开的是另一个页面（重定向后的），观感是「点错了」。
            let matched = (text as NSString).substring(with: result.range).lowercased()
            let explicitScheme = matched.hasPrefix("http://") || matched.hasPrefix("https://")
            let url: URL
            if explicitScheme {
                url = detected
            } else {
                var components = URLComponents(url: detected, resolvingAgainstBaseURL: false)
                components?.scheme = "https"
                guard let upgraded = components?.url
                        ?? URL(string: "https://" + detected.absoluteString)
                else { return }
                url = upgraded
            }

            // ③ 已经是链接的区间**不覆盖**：Down 从 `[文字](url)` 解析出来的那一段
            //    自带 `.link`，文字里不含 URL 串（检测不到），但源码里
            //    `[https://…](https://…)` 这种写法就会重叠 —— 以 Down 的为准。
            var alreadyLinked = false
            mutable.enumerateAttribute(AIPlatformText.linkKey, in: result.range) { value, _, stop in
                if value != nil {
                    alreadyLinked = true
                    stop.pointee = true
                }
            }
            guard !alreadyLinked else { return }

            // ⚠️ 值给 `NSURL`（不是 `String`）：转成 `AttributedString` 时
            //    `.link` 那一支要的是 URL 类型，给字符串会**静默丢掉**这个属性
            //    （表现就是「代码看着写了链接、屏上还是普通文字」）。
            //
            //    ⚠️ 键走 `AIPlatformText.linkKey`（⛔ 别在业务层直写 `.link`：那个成员不在
            //    Foundation —— 两平台各实测过一次，见那边的注释）。
            mutable.addAttribute(AIPlatformText.linkKey, value: url as NSURL, range: result.range)
            // 🔴 补完 `.link` **紧接着上色**：`.link` 只让这段字可点，颜色得自己写
            //    （mac 的 `Text` 不给 `.link` run 换色，见文件头）。
            mutable.addAttribute(.foregroundColor, value: linkColor, range: result.range)
        }
        return mutable
    }

    /// 富文本里**带 `.link`** 的区间（Down 解析 Markdown 链接语法的产物 + `apply` 补出来的裸网址）。
    ///
    /// ⚠️ 返回「区间数组」而不是就地改：`apply` 里要**先收齐再动手**（见那边的注释）。
    ///
    /// 🔴 对外也是**唯一**的「哪些区间算链接」判据：mac 的 `MacLinkHit`（鼠标 hover 判定）与
    /// 视图层（给命中的那条加下划线）都从这里取序号 —— 三处各写一遍 `enumerateAttribute` 的话，
    /// 「第 0 条链接」的含义迟早对不上，症状是**鼠标压在 A 上、B 变了下划线**。
    /// ⚠️ 传进来的必须是 **`apply` 之后**的富文本（裸网址的 `.link` 是 `apply` 补的）。
    public static func linkRanges(in attributed: NSAttributedString) -> [NSRange] {
        guard attributed.length > 0 else { return [] }
        var ranges: [NSRange] = []
        attributed.enumerateAttribute(AIPlatformText.linkKey,
                                      in: NSRange(location: 0, length: attributed.length),
                                      options: [.longestEffectiveRangeNotRequired]) { value, range, _ in
            // ☠️ **必须自己判 nil**：`enumerateAttribute` 对「没有这个属性的区间」**也会回调**
            //    （value = nil），不判就会把整段普通文字也算成链接。
            if value != nil { ranges.append(range) }
        }
        return ranges
    }
}
