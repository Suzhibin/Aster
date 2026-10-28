//
//  AIChatSearchHit.swift
//  AIModule
//
//  搜索页（AIChatSearchViewController）的数据与匹配逻辑。
//
//  职责边界：
//  - `AIChatSearchHit` 只描述「一条结果长什么样」，由 `AIChatStore.search(keyword:)` 产出；
//  - `AISearchMatcher` 是纯函数工具（找位置 / 截片段 / 上色），**不含任何布局与视图**，
//    store 产出结果、cell 渲染结果都走它，保证「算出来的位置」和「画出来的位置」同源。
//

import Foundation

// - Note: 本文件**不需要 UIKit**（原先那行 `import UIKit` 是历史遗留的）。
//   整体只用到 `NSRange` / `NSString` / `NSAttributedString` —— 全在 Foundation，
//   所以它是这次抽包里唯一「删一行就好了」的文件。

/// 一条搜索结果：命中的会话标题，或会话里某条消息的正文片段。
public struct AIChatSearchHit {

    /// 所属会话（点击后打开它）
    public let conversationId: UUID
    /// 会话标题（可能为空字符串，展示时走 `displayTitle` 补默认文案）
    public let conversationTitle: String
    /// 会话更新时间（排序 + 列表右侧展示）
    public let updatedAt: Date

    /// 命中的角色；**标题命中时为 nil**
    public let role: AIRole?

    /// 命中消息在库里的 id（`ai_message.mId`）；**标题命中时为 nil**。
    ///
    /// 有了它，点搜索结果才能**精确滚到那一条**并高亮一下 —— 在此之前只能打开会话，
    /// 用户还得自己在几百条里找（见 `AIModuleViewController.revealSearchHit`）。
    /// 之所以能从库里带出来：`AIChatStore.search` 选中的就是 `mId` 列，
    /// 而 `AIChatBlock.id` 用的正是同一个 UUID（落库时就是它）。
    public let messageId: UUID?

    /// 展示片段：以首个命中为中心截出来的上下文，首尾可能带省略号
    public let snippet: String
    /// 关键词在 `snippet` 中的全部位置（供富文本高亮）
    public let snippetRanges: [NSRange]
    /// 关键词在 `displayTitle` 中的全部位置（标题没命中就是空数组）
    public let titleRanges: [NSRange]

    /// 是否是「标题命中」（标题命中的结果排在消息命中之前）
    public let isTitleMatch: Bool

    public init(conversationId: UUID,
                conversationTitle: String,
                updatedAt: Date,
                role: AIRole?,
                messageId: UUID?,
                snippet: String,
                snippetRanges: [NSRange],
                titleRanges: [NSRange],
                isTitleMatch: Bool) {
        self.conversationId = conversationId
        self.conversationTitle = conversationTitle
        self.updatedAt = updatedAt
        self.role = role
        self.messageId = messageId
        self.snippet = snippet
        self.snippetRanges = snippetRanges
        self.titleRanges = titleRanges
        self.isTitleMatch = isTitleMatch
    }

    /// 列表首行文案（空标题补「新对话」）
    public var displayTitle: String { conversationTitle.isEmpty ? L("新对话") : conversationTitle }

    /// 片段前缀的角色标记
    public var roleText: String {
        if isTitleMatch { return L("标题") }
        return role == .user ? L("我") : "AI"
    }
}

/// 关键词匹配与高亮的纯逻辑。
///
/// 抽出来的原因：`AIChatStore`（产出结果）与 `AIChatSearchCell`（渲染结果）都要算
/// 「关键词在哪儿」，两边各自实现迟早会出现「列表里高亮的位置偏一个字符」这类对不上的问题。
public enum AISearchMatcher {

    /// 关键词在 `text` 中的**全部**出现位置（大小写 / 音调不敏感）。
    /// 空关键词、没命中都返回空数组。
    public static func ranges(in text: String, keyword: String) -> [NSRange] {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty, !text.isEmpty else { return [] }
        let ns = text as NSString
        var result: [NSRange] = []
        var cursor = 0
        // 逐个往后找：`NSString.range(of:)` 只给首个命中，
        // 要一次列出全部（一条消息里可能反复出现关键词）就得自己推进游标
        while cursor < ns.length {
            let searchRange = NSRange(location: cursor, length: ns.length - cursor)
            let found = ns.range(of: kw,
                                 options: [.caseInsensitive, .diacriticInsensitive],
                                 range: searchRange)
            guard found.location != NSNotFound else { break }
            result.append(found)
            cursor = found.location + max(found.length, 1)   // max(,1) 防零长匹配死循环
        }
        return result
    }

    /// 以**首个命中**为中心截出展示片段：前面留 `lead`、后面留 `trail` 个字符，
    /// 被截断的一侧补省略号；同时给出关键词在**新片段**里的位置（直接重算，
    /// 比把老位置平移更不容易错，尤其是开头补了「…」之后）。
    public static func snippet(of text: String,
                        keyword: String,
                        lead: Int = 16,
                        trail: Int = 40) -> (text: String, ranges: [NSRange])? {
        guard let first = ranges(in: text, keyword: keyword).first else { return nil }
        let ns = text as NSString
        let start = max(0, first.location - lead)
        let end = min(ns.length, NSMaxRange(first) + trail)
        var snippet = ns.substring(with: NSRange(location: start, length: end - start))
        if start > 0 { snippet = "…" + snippet }
        if end < ns.length { snippet += "…" }
        // 截断处可能把某次命中切掉一半 —— 重算只会拿到完整的那些，正是想要的
        return (snippet, ranges(in: snippet, keyword: keyword))
    }

    /// 把整串先套上 `baseAttributes`（字号 / 默认颜色由调用方给，本工具不该知道），
    /// 再把 `ranges` 位置的文字换成 `highlightAttributes`。
    public static func highlight(_ text: String,
                          ranges: [NSRange],
                          baseAttributes: [NSAttributedString.Key: Any],
                          highlightAttributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: text, attributes: baseAttributes)
        guard !ranges.isEmpty else { return attributed }
        let length = (text as NSString).length
        for range in ranges {
            // 越界就跳过：宁可少高亮一处，也不能因为 NSRange 不合法抛异常
            guard range.location != NSNotFound, NSMaxRange(range) <= length else { continue }
            attributed.addAttributes(highlightAttributes, range: range)
        }
        return attributed
    }
}
