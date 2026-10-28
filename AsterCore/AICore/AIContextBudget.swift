//
//  AIContextBudget.swift
//  AIModule
//
//  「上下文长度管理」：在把消息数组交给平台之前，按**模型上下文窗口**做一次预算裁剪。
//
//  ## 为什么需要它
//  大模型是**无状态**的，「记住上下文」靠的是每一轮把全部聊天记录重新发一遍
//  （`AIChatManager.contextMessages()` 干的就是这件事）。没有刹车时：
//  ① 请求体随轮次线性增长 → 首字节变慢、历史被反复计费；
//  ② 一旦超过模型的上下文上限，服务端直接 400，而且**之后每一轮都会失败** ——
//     历史只增不减，用户自己点不出来。
//  所以这里缺的从来不是「省钱」，是**刹车**。
//
//  ## 策略：不超不裁，超了才裁，从最旧开始丢
//  1. 先估总量，**没超预算就原样返回**。这一步不是图省事：服务端有前缀缓存
//     （命中价与未命中价可差 50 倍），每轮都裁会让前缀一直变、把缓存全打掉，
//     反而更贵。保持「不超就不动」才能一直吃到缓存。
//  2. 超了才裁，且**只裁出连续的一段后缀**：一旦某条装不下就停手，不在中间掏洞
//     （有洞的上下文会让模型对「哪句在哪句之后」产生错位）。
//  3. **当前提问永远保留** —— 哪怕它自己就超预算。删掉它等于发一个没有问题的请求，
//     留着它才有意义。
//  4. **首条单独保一次**：它常是「背景设定 / 我在做什么项目」，
//     丢掉的代价比其他历史行都大。塞得进剩余预算就留，塞不下就认了。
//
//  ## 只能估，不能数
//  工程里没有 tokenizer（引一份进来要为每个平台配一套词表，收益远小于成本），
//  所以这里是**估算**：表意文字按 0.75 token/字、其余按 0.25 token/字。
//  DeepSeek 官方给的字均比是中文 ≈ 0.6，取 0.75 是刻意的小幅高估 ——
//  宁可早一点裁（丢的是最旧的上下文），也不要估少了撞上限（整轮失败）。
//

import Foundation

// MARK: - 裁剪结果

/// 一次上下文裁剪的结果。
///
/// 把「裁完的数组」和几个**统计量**一起返回，而不是只回数组：调用方要拿这些数字
/// 决定「要不要告诉用户」「这一轮是不是已经无解」。
struct AIContextTrimResult {

    /// 真正要发出去的消息
    let messages: [AIChatMessage]
    /// 被丢掉的条数（0 = 一条没裁）
    let droppedCount: Int
    /// 裁剪后的估算 token 数
    let estimatedTokens: Int
    /// 这次裁剪用的预算（= 窗口 × `budgetRatio`）
    let budgetTokens: Int
    /// 这次裁剪用的窗口；**0 = 该平台不参与裁剪**
    let windowTokens: Int

    /// 是否裁掉了东西
    var didTrim: Bool { droppedCount > 0 }

    /// 裁到只剩当前提问**仍然**超窗口 —— 这一轮大概率会被服务端拒掉。
    ///
    /// ⚠️ 这是**估算**，不拿来拦请求：窗口表猜小了会把本来发得出去的内容挡在门外，
    /// 那是比「让服务端报 400」更糟的失败（前者用户无能为力，后者至少还能重试）。
    /// 只用它把提示说得更准。
    var isOverBudget: Bool { windowTokens > 0 && estimatedTokens > windowTokens }
}

// MARK: - 预算

/// 上下文预算：窗口表 + token 估算 + 裁剪。
///
/// 纯静态、无状态：裁剪不写任何存储，每次都从当前消息数组现算
/// （存「这一轮用了多少 token」只会多一份会过期的副本）。
enum AIContextBudget {

    // MARK: 参数

    /// 预算占窗口的比例。
    ///
    /// 留出的 30% 不是余量而是**必要开销**：输入把窗口占满的话，模型没有空间生成回复，
    /// 表现是回答被截断或直接 400。
    static let budgetRatio = 0.7

    /// 模型名没命中窗口表时的兜底窗口。
    ///
    /// 取小不取大：猜大了 → 不裁 → 撞上限 → 整轮 400；猜小了 → 早裁 → 丢一部分旧上下文
    /// （回答质量下降，但**这一轮仍然答得出来**）。两害相权，后者可接受。
    static let fallbackWindow = 32_768

    /// 一条消息的固定开销（role 字段、角色分隔符等），与正文长度无关
    static let perMessageOverhead = 4

    /// 一张历史图片的估算开销。
    ///
    /// 真实值跟分辨率、切片策略都有关（OpenAI 高清档上限 1105），这里取一个够用的常数 ——
    /// 图片还有另一道**张数**上限兜着（`AIChatManager.maxContextImages`），两边分工不同：
    /// 那边管「别把请求体顶到服务端体积上限」，这边管「别把窗口占满」。
    static let imageTokens = 1_100

    // MARK: 窗口表

    /// 模型名 → 上下文窗口（token）。
    ///
    /// 匹配规则是**子串**，且**顺序敏感**：`gpt-4o` 必须排在 `gpt-4` 前面，
    /// 否则 `gpt-4o` 会被 `gpt-4` 那条抢走（8K 而不是 128K），表现为莫名其妙地疯狂裁剪。
    ///
    /// 只列常见家族：没列到的一律走 `fallbackWindow`。
    /// 这张表**会过期**（模型迭代很快），但它只影响「什么时候开始裁」，
    /// 猜错的后果是裁早了或裁晚了，不会把请求打挂 —— 所以不必追着更新。
    private static let windowTable: [(name: String, window: Int)] = [
        ("gemini",      1_000_000),
        ("claude",        200_000),
        ("gpt-4.1",     1_000_000),
        ("gpt-4o",        128_000),
        ("gpt-4-turbo",   128_000),
        ("gpt-4",           8_192),
        ("gpt-3.5",        16_385),
        ("deepseek",      128_000),
        ("qwen",          128_000),
        ("kimi",          128_000),
        ("moonshot",      128_000),
        ("glm",           128_000),
        // ⚠️ kimi / moonshot / glm 三条**刻意维持 128k**（2026-10-17）：当代旗舰
        //    （kimi-k3 1M / glm-4.7 200K）窗口大得多，但同名前缀下仍有 128K 的旧系
        //    （moonshot-v1-128k / glm-4.5），而 contains 匹配命中同一条 —— 猜大的
        //    后果是旧系直接 400（超窗），猜小只是少带点历史。不对称 ⇒ 取保守值。
        // doubao-seed-2.x 全系 256k（2026-10-16 从 128k 更正；doubao-pro 旧代是 128k，
        // 按 contains 匹配会统一落到 256k —— 猜大的后果只是晚裁一点，不致命）
        ("doubao",        256_000),
        // MiniMax（2026-10-17 接入）：M3 = 1M（当代旗舰）；M2.5 / M2 等旧系 = 204K。
        // 🔴 **M3 必须排在 minimax 前面**（contains 顺序敏感，同 `gpt-4o` 先于 `gpt-4`）：
        //    两条窗口差 5 倍，猜大的后果是旧系超窗 400，猜小只是少带点历史 ⇒ 精确到型号。
        ("minimax-m3", 1_000_000),
        ("minimax",      204_000),
        ("llama",         128_000),
        ("mistral",        32_000),
    ]

    /// 按模型名查上下文窗口；查不到回落 `fallbackWindow`
    static func window(forModel model: String) -> Int {
        let name = model.lowercased()
        guard !name.isEmpty else { return fallbackWindow }
        for entry in windowTable where name.contains(entry.name) { return entry.window }
        return fallbackWindow
    }

    // MARK: 估算

    /// 一条消息的估算开销（正文 + 固定开销 + 图片）
    static func cost(of message: AIChatMessage) -> Int {
        estimateTokens(message.content)
            + perMessageOverhead
            + message.imageURLs.count * imageTokens
    }

    /// 一组消息的估算开销
    static func estimate(_ messages: [AIChatMessage]) -> Int {
        messages.reduce(0) { $0 + cost(of: $1) }
    }

    /// 文本 → 估算 token 数。
    ///
    /// 表意文字按 0.75 token/字，其余（拉丁字母 / 数字 / 空白）按 0.25 token/字
    /// （≈ 4 字符 1 token，英文与代码的经验值）。全整数运算：`(宽 × 3 + 窄 + 3) / 4`，
    /// 末尾的 `+ 3` 是向上取整。
    static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var wide = 0
        var narrow = 0
        for scalar in text.unicodeScalars {
            if isWide(scalar) { wide += 1 } else { narrow += 1 }
        }
        return (wide * 3 + narrow + 3) / 4
    }

    /// 该字符是否按「一个字 ≈ 0.75 token」计价
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,      // 韩文字母
             0x2E80...0x303E,      // 中日部首 / 标点
             0x3041...0x33FF,      // 假名 / 注音 / 兼容符号
             0x3400...0x4DBF,      // 汉字扩展 A
             0x4E00...0x9FFF,      // 汉字基本区
             0xA000...0xA4CF,      // 彝文
             0xAC00...0xD7A3,      // 韩文音节
             0xF900...0xFAFF,      // 兼容汉字
             0xFE30...0xFE4F,      // 兼容标点
             0xFF00...0xFF60,      // 全角字符
             0xFFE0...0xFFE6,
             0x1F000...0x1FAFF,    // emoji（单个 emoji 的真实开销通常高于 1 token，这里已是最保守下限）
             0x20000...0x3FFFF:    // 汉字扩展 B 及以后（罕用字）
            return true
        default:
            return false
        }
    }

    // MARK: 裁剪

    /// 按「窗口 → 预算」裁一次。
    ///
    /// - Parameter window: 模型的上下文窗口（来自 `AIProvider.contextWindow`）。
    ///   传 `nil`（或非正数）= 该平台不参与裁剪，原样返回。
    /// - Returns: 裁完的消息 + 统计量。**没超预算时 `messages` 与入参逐条相同**
    ///   （保持前缀稳定，继续吃服务端缓存）。
    static func trim(_ messages: [AIChatMessage], window: Int?) -> AIContextTrimResult {
        // 平台没给窗口（本地 mock 根本不看消息体）→ 一条都不动：
        // 裁了没有意义，还会让用户收到一句「已省略 N 条」的假提示。
        // 估算照样给出来：`estimatedTokens` 的约定是「结果数组的估算值」，
        // 这里偷懒填 0 会让这个字段在「无窗口」时变成假数据，读的人迟早踩到。
        guard let window, window > 0, let last = messages.last else {
            return AIContextTrimResult(messages: messages, droppedCount: 0,
                                       estimatedTokens: estimate(messages),
                                       budgetTokens: 0, windowTokens: 0)
        }

        let budget = Int(Double(window) * budgetRatio)
        let total = estimate(messages)
        guard total > budget else {
            return AIContextTrimResult(messages: messages, droppedCount: 0,
                                       estimatedTokens: total,
                                       budgetTokens: budget, windowTokens: window)
        }

        // ① 当前提问永远保留：它是这一轮存在的理由
        var kept = [messages.count - 1]
        var used = cost(of: last)

        // ② 从倒数第二条往回收，装不下就停手 —— 必须连续，不在中间掏洞。
        //    循环止于 1：首条留给下面单独判（它的去留有另一套标准）。
        if messages.count >= 2 {
            for index in stride(from: messages.count - 2, through: 1, by: -1) {
                let itemCost = cost(of: messages[index])
                guard used + itemCost <= budget else { break }
                used += itemCost
                kept.insert(index, at: 0)
            }
        }

        // ③ 首条单独保一次：
        //    「能塞就塞」而不是「无条件保」—— 首条本身可能是用户粘进来的一大段文档，
        //    无条件保它会把整个预算吃光，结果只剩「文档 + 当前提问」，比丢掉它更糟。
        if messages.count > 1, kept.first != 0 {
            let headCost = cost(of: messages[0])
            if used + headCost <= budget {
                used += headCost
                kept.insert(0, at: 0)
            }
        }

        return AIContextTrimResult(messages: kept.map { messages[$0] },
                                   droppedCount: messages.count - kept.count,
                                   estimatedTokens: used,
                                   budgetTokens: budget,
                                   windowTokens: window)
    }
}
