//
//  AIReasoning.swift
//  AICore
//
//  推理模型的「思考过程」：一轮回复在正文之前先想的那段话。
//
//  ## 数据从哪来
//  请求侧（`AIConfig.thinkingEnabled` + 模型能力位）决定发不发思考字段；
//  服务端在正文之前经 SSE 的 `reasoning_content` 增量下发（解码见
//  `AIStreamPayloads.OpenAIChatChunk.Delta.reasoningContent`），事件形态是
//  `AIStreamEvent.reasoning(String)`。
//
//  ## 落在哪
//  挂在助手文本块的 `AIBlock.reasoning` 上（1:1）。持久化走**新表** `ai_reasoning`
//  （主键 = 消息 id）—— 与 `ai_usage` / `ai_quote` 同一条纪律：⛔ 不给 `ai_message` 加列
//  （`getTable` 是 `CREATE TABLE IF NOT EXISTS`，补列的坑本工程踩过两次）。
//
//  ## 🔴 它不进请求上下文
//  思考内容是模型的「草稿纸」，不是对话内容 —— `contextMessages()` 只取 `block.text`，
//  天然不会把它回传给模型（回传只会烧 token，还容易让模型混淆「哪句是自己说过的」）。
//
//  ## 展示总闸
//  `AIGenerationSettings.showsThinkingProcess`：关着时流式增量不缓冲、不落库；
//  历史内容虽在库里但不渲染（判据在渲染时现读，见 `AIChatRow.thinkingHeightOrZero`）。
//

import Foundation

/// 一条思考过程（挂在助手回复上）
public struct AIReasoning: Equatable {

    /// 思考正文（流式增量拼接而成）
    public var text: String

    /// 思考耗时（秒）。0 = 未知 / 没统计到。
    ///
    /// 由 `AIChatManager` 在「正文第一字流出」那一刻封住（那是思考结束的信号）——
    /// 折叠行上「思考过程 · 8.4 秒」的那个数字。
    /// 服务端没走完整流程（重启前被杀等）时是 0，折叠行就不显示耗时那截。
    public var duration: TimeInterval

    public init(text: String, duration: TimeInterval = 0) {
        self.text = text
        self.duration = duration
    }

    /// 空思考（服务端没发 / 总闸关着没缓冲）—— 渲染与落库都按「没有」处理
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: 展示

    /// 折叠行的标题。
    ///
    /// 🔴 **计算属性、⛔ 不是 `static let`**：`L()` 的结果不能被进程级缓存住，
    ///    否则切语言后这一行永远是旧语言（同 `emptyReplyText` 那条教训）。
    public var collapsedTitle: String { L("思考过程") }

    /// 流式中的标题（思考块自动展开时，头部显示它）。
    /// 同样是计算属性，理由同 `collapsedTitle`。
    public var streamingTitle: String { L("思考中…") }

    /// 耗时文案（`nil` = 没统计到 ⇒ 折叠行不显示「· X 秒」那截）。
    ///
    /// 分档是为了可读性：0.4 秒写成「不到 1 秒」比「0.4 秒」更诚实（计时精度到不了十分位），
    /// 12.3 秒写成「12 秒」比「12.3 秒」更干净（没人在乎那零点几）。
    public var durationText: String? {
        guard duration > 0 else { return nil }
        if duration < 1 { return L("不到 1 秒") }
        if duration < 10 { return String(format: L("%.1f 秒"), duration) }
        return String(format: L("%.0f 秒"), duration)
    }

    /// 折叠那一行的**完整文案**（标题 + 耗时）。耗时未知时就只有标题。
    ///
    /// 做成一个出口而不是让两端视图各拼一遍：iOS cell 与 Mac row 显示的是同一条信息，
    /// 拼法漂移会出现「一边有点、一边没有」。
    public var collapsedText: String {
        guard let durationText else { return collapsedTitle }
        return "\(collapsedTitle) · \(durationText)"
    }
}
