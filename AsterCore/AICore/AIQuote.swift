//
//  AIQuote.swift
//  AIModule
//
//  「引用」：用户发消息时挑中的、要针对它提问的那条历史消息。
//
//  为什么存**文本快照**而不是只存一个 messageId（显示时去库里 join）：
//  - 被引用那条可能**已经不在**了 —— 重新生成会把它删掉、编辑重发会把后面的轮次整段截断、
//    用户还可能在别的会话里删掉它。只存 id 的话，这些情况下引用条会变成一句「消息不存在」，
//    而用户明明只是想让模型看看「刚才那段话」；
//  - 引用是**发送那一刻的事实**：「我当时引用的是这段内容」，它与那条消息后来有没有被改
//    无关。快照正是这个语义。
//
//  id 仍然要存：**能定位到就跳过去**（点引用条 → 滚到原消息闪一下，见 `revealMessage(id:)`），
//  定位不到就只显示文本 —— 有快照兜底，这个降级是安全的。
//

import Foundation

/// 一条引用（挂在用户消息上）
public struct AIQuote: Equatable {

    /// 被引用消息的 id（点击引用条跳转定位用；那条消息可能已被删除）
    public let messageId: UUID
    /// 被引用消息的角色（决定引用条上写「我」还是「AI」）
    public let role: AIRole
    /// 引用发生时的**正文快照**
    public let text: String

    public init(messageId: UUID, role: AIRole, text: String) {
        self.messageId = messageId
        self.role = role
        self.text = text
    }

    /// 引用条上「引用了谁」
    public var displayName: String { role == .user ? L("我") : "AI" }

    /// 引用条里的单行摘要：把换行压成空格（否则多行正文会把引用条撑成两行，行高就变了）
    public func summary(limit: Int = 40) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    /// 塞进请求上下文时的形态。
    ///
    /// 老模型 API 没有「引用」这个字段（OpenAI 兼容格式里都没有），所以只能**写进正文**：
    /// 明确标出「这是引用、谁说的」，模型才能分清哪句是被引用的旧话、哪句是本次的要求。
    /// 不加这段的话，模型会把被引用的文字也当成当前指令的一部分。
    ///
    /// `limit` 是给上下文的保护：引用一条几千字的长回复会把每一轮的输入 token 都顶上去
    /// （引用在**每一条**带引用的消息里都会重发）。
    public func contextText(limit: Int = 600) -> String {
        let who = role == .user ? "我" : "你"
        var snapshot = text
        if snapshot.count > limit {
            snapshot = String(snapshot.prefix(limit)) + "…"
        }
        return "【引用\(who)之前说的】\n\(snapshot)"
    }
}
