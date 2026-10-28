//
//  AIStreamPayloads.swift
//  AIModule
//
//  SSE 事件体的解码模型（`SmartDecodable`）。
//
//  为什么从 `JSONSerialization` + `[String: Any]` 换成 SmartCodable：
//  - 事件体里到处是「可有可无 / 形状可能飘」的字段（各平台的 delta、错误体结构都不一样），
//    手写 `obj["x"] as?` 在形状不符时只会静默返回空数组，排查时没有任何线索；
//  - 一个结构体 = 字段清单 + 类型 + 可选性，比一串下标强转可读得多，也顺手拿到容错能力
//    （null 容错、缺字段不炸、数字/字符串互转）。
//
//  ⚠️ 两条必须守住的约束（对应实现在各 provider 的 `events(from:)` 里，别删）：
//  1. **`[DONE]` 不是 JSON**（OpenAI 兼容链路），必须在 `deserialize` **之前**拦掉，
//     否则白跑一次失败解析；
//  2. **容错解析不会因为「字段一个都没对上」而返回 nil** —— 任意合法 JSON 都能解出一个
//     「字段全 nil」的对象。所以「这帧是不是有效帧」必须靠**业务字段非空**来判。
//     本文件的结构体刻意全部 optional，调用方只从非空字段产出事件，天然满足这条。
//
//  ⚠️ 第三条（2026-09 加用量统计时才踩到）：**不能假设每一帧都有 `choices`**。
//  带 `stream_options.include_usage` 时，整次请求的 `usage` 可能出现在一个
//  **`choices` 为空数组**的独立块上（各家实现不一致：DeepSeek 官方文档说挂在最后一个
//  内容块上，但 OpenAI 及部分兼容服务会额外下发一个空 choices 的块）。
//  所以解析顺序必须是「先取 usage、再取 delta」，**不能**用 `guard let delta = ...` 把整帧挡掉。
//
//  注意：请求体（`makeRequest` 里的 `body(...)`）**不走这里**，仍是字典构造 ——
//  那侧是「我们主动发出的东西」，一眼能看出实际 JSON 更有价值，换 Codable 不划算。
//
//  ☠️ 2026-10-13：原先这里还有一个 `MockStreamPayload`（本机 mock 的私有事件协议
//  `{"t":"txt","c":"…"}`）—— 随 `localMock` 平台与 `mock_sse_server.py` 一起删了（见 `AIProvider.swift`）。
//  留下的教训：**事件解码模型必须与「谁会发这种事件」一一对应**，平台下线时它是最容易被忘掉的那一半。
//

import Foundation
import SmartCodable

// MARK: - OpenAI 兼容（深度求索 / 智谱 / Kimi 三家共用）

/// chat/completions 的流式增量：
/// `{"choices":[{"delta":{"content":"…","reasoning_content":"…"}}]}`
struct OpenAIChatChunk: SmartDecodable {

    var choices: [Choice]?
    /// 本次请求的 token 用量。**注意它可能出现在 `choices` 为空数组的那一帧上**
    /// （见文件头第三条），所以解析顺序必须是「先 usage、后 delta」。
    var usage: Usage?

    init() {}

    /// 用量体：`{"prompt_tokens":…,"completion_tokens":…,"total_tokens":…,
    /// "prompt_cache_hit_tokens":…,"prompt_cache_miss_tokens":…}`
    ///
    /// 后两个**只有 DeepSeek 给**（命中/未命中单价差一个数量级，拿不到就只能按未命中价高估）。
    /// 全 optional：兼容平台给不给这套字段完全不保证，缺了只是这一轮不算缓存价，不该整帧作废。
    struct Usage: SmartDecodable {

        var promptTokens: Int?
        var completionTokens: Int?
        var totalTokens: Int?
        /// 输入侧命中缓存的 token 数（DeepSeek 专有）
        var cacheHitTokens: Int?
        /// 输入侧未命中缓存的 token 数（DeepSeek 专有）
        var cacheMissTokens: Int?

        init() {}

        enum CodingKeys: String, CodingKey {
            case promptTokens, completionTokens, totalTokens
            case cacheHitTokens, cacheMissTokens
        }

        /// 蛇形映射就地写在类型上，不依赖调用方传全局 `fromSnakeCase`
        /// （那种开关一旦漏传，字段会静默变 nil —— 症状是「用量永远是 0」）
        static func mappingForKey() -> [SmartKeyTransformer]? {
            [
                CodingKeys.promptTokens     <--- "prompt_tokens",
                CodingKeys.completionTokens <--- "completion_tokens",
                CodingKeys.totalTokens      <--- "total_tokens",
                CodingKeys.cacheHitTokens   <--- "prompt_cache_hit_tokens",
                CodingKeys.cacheMissTokens  <--- "prompt_cache_miss_tokens",
            ]
        }

        /// 转成业务模型；**全 0 / 全空视为「没拿到」**（没有任何一次真实请求是 0 token）
        var usageModel: AITokenUsage? {
            let prompt = promptTokens ?? 0
            let completion = completionTokens ?? 0
            let total = totalTokens ?? (prompt + completion)
            let usage = AITokenUsage(promptTokens: prompt,
                                     completionTokens: completion,
                                     totalTokens: total,
                                     cacheHitTokens: cacheHitTokens,
                                     cacheMissTokens: cacheMissTokens)
            return usage.isEmpty ? nil : usage
        }
    }

    struct Choice: SmartDecodable {

        var delta: Delta?

        /// 这一帧给出的**结束原因**（OpenAI 兼容：`stop` / `length` / `content_filter` / `tool_calls`）。
        ///
        /// ⚠️ 它与 `delta` **同层**，且出现在**最后一帧**上（那一帧的 `delta` 通常是个空对象）。
        /// 本工程只用它判断「回复写完没有」：`length` = 撞上 `max_tokens`（话停在半句）、
        /// `content_filter` = 被内容审核掐了 —— 两者都是「没写完」。
        /// 没有它，「说完了」与「被截断」在客户端**完全无法区分**：半句话会静默留在对话里，
        /// 用户既不知道发生了什么，也无从接着往下写（见 `AIChatManager.isTruncated`）。
        var finishReason: String?

        init() {}

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason
        }

        /// 蛇形映射就地写在类型上（与 `Delta.reasoningContent` 同一理由：
        /// 不依赖调用方传全局 `fromSnakeCase`，那种开关一旦漏传字段会**静默**变 nil）
        static func mappingForKey() -> [SmartKeyTransformer]? {
            [CodingKeys.finishReason <--- "finish_reason"]
        }
    }

    struct Delta: SmartDecodable {

        /// 正文增量
        var content: String?
        /// 思考增量。JSON 里是蛇形 `reasoning_content`，
        /// 用 `mappingForKey` 就地把映射关系写在类型上，不依赖调用方传全局的 `fromSnakeCase`
        /// （那种开关一旦漏传，字段会静默变 nil，症状正好是「思考/正文都不见了」）。
        var reasoningContent: String?

        init() {}

        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent
        }

        static func mappingForKey() -> [SmartKeyTransformer]? {
            [CodingKeys.reasoningContent <--- "reasoning_content"]
        }
    }
}
