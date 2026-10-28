//
//  AITokenUsage.swift
//  AIModule
//
//  一次请求的 token 用量，以及「按单价估算费用」。
//
//  为什么单独一个文件：用量的使用面是**设置页的全库累计统计**（计价）与**落库**
//  （`ai_usage` 表），两者必须共用同一份「怎么算」与「怎么格式化」。
//  ⚠️ 2026-09-17 曾撤掉聊天页操作栏右侧那条「本会话累计」；**2026-10-25 傍晚**做过
//  一版「Mac 助手文本栏、时间之后显示单次用量」（形态从 `入 1.2k · 出 340` 改成
//  「共消耗 ✦ 1,574」），**当晚用户说「算了 这个功能还是隐藏吧」⇒ 界面已隐藏**。
//  所以下面 `totalText` / `breakdownText` / `shortText` 三个「格式化出口」**目前都没有
//  界面消费**，保留的理由是：数据照常落库（`ai_usage` 表、设置页累计统计在用），
//  而格式必须只有一份 —— 要恢复显示只需在 `ChatRowActionBar` 里接线（见那份文件头）。
//  ⛔ 别再去别处写第二份格式化 —— 这几个属性是各自口径的唯一出口。
//  聚合**只有一份实现** —— `AIUsageTotal.add(_:)`。
//

import Foundation

// MARK: - 用量

/// 一次请求的 token 用量。
///
/// 全部字段都来自服务端返回的 `usage`，**不做本地估算**：
/// 本地按字数猜 token 数在中文/代码场景下误差能到 2 倍，拿来计价会误导用户。
/// 服务端没给（老接口、兼容平台没开 `include_usage`）时 `nil`，界面就不显示用量。
public struct AITokenUsage: Equatable {

    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int

    /// 输入侧的缓存命中 / 未命中拆分。
    ///
    /// **DeepSeek 专有**（`prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`），
    /// 其他兼容平台通常不给。命中与未命中的单价差**一个数量级**，
    /// 拿不到拆分时只能按未命中价算 —— 那是**高估**，别反过来按命中价算（会低得离谱）。
    public var cacheHitTokens: Int?
    public var cacheMissTokens: Int?

    public init(promptTokens: Int,
                completionTokens: Int,
                totalTokens: Int,
                cacheHitTokens: Int? = nil,
                cacheMissTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cacheHitTokens = cacheHitTokens
        self.cacheMissTokens = cacheMissTokens
    }

    /// 有没有拿到有效数据（全 0 视为没拿到 —— 没有任何一次真实请求是 0 token）
    public var isEmpty: Bool { totalTokens <= 0 && promptTokens <= 0 && completionTokens <= 0 }

    // MARK: 计价用的拆分

    /// 按**未命中价**计费的输入 token 数
    public var billableMissTokens: Int {
        if let miss = cacheMissTokens { return max(0, miss) }
        if let hit = cacheHitTokens { return max(0, promptTokens - hit) }
        return max(0, promptTokens)
    }

    /// 按**命中价**计费的输入 token 数
    public var billableHitTokens: Int { max(0, cacheHitTokens ?? 0) }

    // MARK: 展示

    /// 单次请求的紧凑用量文案：`入 1.2k · 出 340`（`nil` = 没有可用数据）。
    ///
    /// ⚠️ **界面当前不消费它**：2026-10-25 二版曾把它换成 `totalText`（单值）显示在 Mac
    /// 助手文本栏，当晚整条显示又被用户要求隐藏 ⇒ 现在三个格式化出口都没有界面消费。
    /// 保留作为「入 / 出」口径的唯一紧凑出口（设置页的多行写法是 `detailText`）。
    /// 格式与累计那份共用 `compactText`，所以两处永远不会出现两种写法。
    public var shortText: String? {
        guard !isEmpty else { return nil }
        return Self.compactText(prompt: promptTokens, completion: completionTokens, total: totalTokens)
    }

    /// 单次请求的**单值**用量文案：`1,574`（= 合计 token 数，带千分位；`nil` = 没有可用数据）。
    ///
    /// ⚠️ **目前无界面消费**：2026-10-25 傍晚曾接到 Mac 助手文本栏（画成「共消耗 ✦ 1,574」），
    /// 当天用户要求隐藏 ⇒ 界面已摘除。保留它是因为「单值」这个口径本身要有个唯一出口。
    /// 恢复点 = `ChatRowActionBar` 文件头（那段写清了加哪三行）。
    /// ⚠️ 当初刻意用**精确值 + 千分位**而不是 `1.6k`：1,574 与 1,600 都会缩成 `1.6k`，
    /// 那是「对不上账」的写法。将来恢复显示时别改成缩写。
    public var totalText: String? {
        guard !isEmpty else { return nil }
        return Self.exact(totalTokens)
    }

    /// 悬停提示用的明细：`输入 1,234 · 输出 340 · 合计 1,574`。
    ///
    /// ⚠️ 当初只给 `.help()`（鼠标停一会儿才出现）用 —— 栏上那行必须保持单值（用户
    /// 「入 出 看不懂」）。**现在整条显示都隐藏了**，所以它同样无界面消费。
    /// ⛔ 恢复时也别把它接回正文。
    public var breakdownText: String? {
        guard !isEmpty else { return nil }
        return String(format: L("输入 %@ · 输出 %@ · 合计 %@"),
                      Self.exact(promptTokens), Self.exact(completionTokens), Self.exact(totalTokens))
    }

    /// 设置页里的完整拆解（多行）
    public func detailText(pricing: AIPricing) -> String {
        var lines = [
            "输入：\(Self.exact(promptTokens)) tokens",
            "输出：\(Self.exact(completionTokens)) tokens",
            "合计：\(Self.exact(totalTokens)) tokens",
        ]
        if let hit = cacheHitTokens, let miss = cacheMissTokens {
            lines.insert("  · 缓存命中 \(Self.exact(hit)) / 未命中 \(Self.exact(miss))", at: 1)
        }
        if let cost = pricing.cost(for: self) {
            lines.append("估算费用：\(AIPricing.money(cost))")
        }
        return lines.joined(separator: "\n")
    }

    /// 紧凑数字：1234 → `1.2k`，12345 → `12.3k`，1000000 → `1M`。
    /// 1000 以下给原值 —— 个位数的 token 没必要写成 `0.5k`。
    static func compact(_ value: Int) -> String {
        let n = abs(value)
        if n < 1000 { return "\(value)" }
        if n < 1_000_000 {
            let k = Double(value) / 1000
            return k < 100 ? String(format: "%.1fk", k) : String(format: "%.0fk", k)
        }
        let m = Double(value) / 1_000_000
        return m < 100 ? String(format: "%.2fM", m) : String(format: "%.0fM", m)
    }

    /// **唯一的用量格式化实现**（单次与累计共用，`AITokenUsage.shortText` /
    /// `AIUsageTotal.shortText` 都只是把各自的数字喂进来）。
    ///
    /// 刻意优先显示「入 / 出」而不是总数：多轮对话里**输入是随上下文线性增长的**，
    /// 只看总数会看不出「这一轮为什么贵」。只有拿不到拆分时才退回总数。
    static func compactText(prompt: Int, completion: Int, total: Int) -> String? {
        if prompt > 0 || completion > 0 {
            return "入 \(compact(prompt)) · 出 \(compact(completion))"
        }
        guard total > 0 else { return nil }
        return "\(compact(total)) tokens"
    }

    /// 精确数字带千分位：`1,234`（设置页里要看得出准确值）
    static func exact(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - 计价

/// 模型单价（**人民币 / 每百万 token**）。
///
/// 为什么做成可编辑的三档而不是内置一张模型价目表：
/// ① 官方价格会变（本项目开发期间 DeepSeek 就调过一次价，且分高峰/空闲两档）；
/// ② 命中价与未命中价在部分模型上差一个数量级，只按一个「输入价」算必然算错；
/// ③ 硬编码的价格一旦过期，用户看到的数字是**错的却不知道**—— 比只显示 token 数更糟。
/// 所以：默认值给一份（见 `AIConfig.defaultPricing`，注明了出处与日期），
/// 设置页可随时改；把三项都填 0 = 明确表示「不计价」，界面就不显示钱。
public struct AIPricing: Equatable {

    /// 输入 · 缓存命中（元 / 百万 token）
    public var cacheHitInput: Double
    /// 输入 · 缓存未命中（元 / 百万 token）
    public var cacheMissInput: Double
    /// 输出（元 / 百万 token）
    public var output: Double

    public init(cacheHitInput: Double, cacheMissInput: Double, output: Double) {
        self.cacheHitInput = cacheHitInput
        self.cacheMissInput = cacheMissInput
        self.output = output
    }

    /// 全 0 = 用户没填（或明确不要计价）
    public var isConfigured: Bool { cacheMissInput > 0 || cacheHitInput > 0 || output > 0 }

    /// 本次用量按当前单价估多少钱；未配置单价时返回 `nil`（**不返回 0** ——
    /// 「0 元」和「不知道多少钱」在界面上必须能区分）。
    public func cost(for usage: AITokenUsage) -> Double? {
        guard isConfigured else { return nil }
        let million = 1_000_000.0
        return Double(usage.billableHitTokens) / million * cacheHitInput
            + Double(usage.billableMissTokens) / million * cacheMissInput
            + Double(usage.completionTokens) / million * output
    }

    /// 金额格式化：小额给 4 位小数（一次对话常常只花几厘钱，`¥0.00` 等于没信息）
    public static func money(_ value: Double) -> String {
        if value == 0 { return "¥0" }
        if value < 0.01 { return String(format: "¥%.4f", value) }
        if value < 1 { return String(format: "¥%.3f", value) }
        return String(format: "¥%.2f", value)
    }
}

// MARK: - 累计用量

/// 全库累计用量（设置页展示）。由 `AIChatStore` 把所有 `ai_usage` 行加起来得到。
public struct AIUsageTotal {
    public var requestCount: Int
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public var cacheHitTokens: Int
    public var cacheMissTokens: Int
    /// 拿不到缓存拆分的轮次（这部分输入只能按未命中价高估）
    public var requestsWithoutCacheSplit: Int

    public init(requestCount: Int = 0,
                promptTokens: Int = 0,
                completionTokens: Int = 0,
                totalTokens: Int = 0,
                cacheHitTokens: Int = 0,
                cacheMissTokens: Int = 0,
                requestsWithoutCacheSplit: Int = 0) {
        self.requestCount = requestCount
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cacheHitTokens = cacheHitTokens
        self.cacheMissTokens = cacheMissTokens
        self.requestsWithoutCacheSplit = requestsWithoutCacheSplit
    }

    public var isEmpty: Bool { requestCount == 0 }

    // MARK: 聚合（**唯一实现**）

    /// 累加一次请求的用量。
    ///
    /// ⚠️ 这段「累加规则」以前在 `AIChatStore.usageTotal()` 里单独写过一遍，现在抽出成一份：
    /// 将来若再加「按会话 / 按轮」的聚合（例如消息详情里显示本轮用量），直接走这里 ——
    /// 各写一遍迟早漂移，尤其 `requestsWithoutCacheSplit` 的判定条件，抄漏一次就是「同一批数据两个数」。
    ///
    /// - Note: `cacheHit/MissTokens` 只有 DeepSeek 给；拿不到拆分的轮次记进
    ///   `requestsWithoutCacheSplit`，那部分输入只能按**未命中价高估**（见 `cost(pricing:)`）。
    public mutating func add(_ usage: AITokenUsage) {
        guard !usage.isEmpty else { return }   // 全 0 = 没拿到数据，不该污染 requestCount
        requestCount += 1
        promptTokens += usage.promptTokens
        completionTokens += usage.completionTokens
        totalTokens += usage.totalTokens
        if let hit = usage.cacheHitTokens, let miss = usage.cacheMissTokens {
            cacheHitTokens += hit
            cacheMissTokens += miss
        } else {
            requestsWithoutCacheSplit += 1
        }
    }

    /// 从一组用量聚合。
    /// 目前唯一的调用方是 `AIChatStore.usageTotal()`（把 `ai_usage` 全表读出来喂进来）；
    /// 做成静态方法是为了将来任何「按会话 / 按轮」的聚合都走同一份规则。
    public static func summing(_ usages: [AITokenUsage]) -> AIUsageTotal {
        var total = AIUsageTotal()
        for usage in usages { total.add(usage) }
        return total
    }

    /// 累计用量的**紧凑**文案：`入 1.2k · 出 340`（`nil` = 没有可显示的数据）。
    ///
    /// 与 `AITokenUsage.shortText` 走**同一个** `compactText` —— 数据源从「单次」变成「累计」，
    /// 但格式一模一样（否则同一个界面上会出现两种数字写法）。
    ///
    /// ⚠️ **界面上目前没有消费它**：它当年就是给聊天页操作栏右侧那行文案用的，2026-09-17 已撤掉。
    /// 保留作为「累计」口径的紧凑出口（设置页现在用的是 `summaryText` 那种多行精确写法）。
    /// 刻意**不带任何口径前缀**：口径由调用方补。
    public var shortText: String? {
        guard !isEmpty else { return nil }
        return AITokenUsage.compactText(prompt: promptTokens,
                                        completion: completionTokens,
                                        total: totalTokens)
    }

    /// 累计费用估算。缺缓存拆分的那些轮次，其输入整体按未命中价算（保守高估）。
    public func cost(pricing: AIPricing) -> Double? {
        guard pricing.isConfigured, !isEmpty else { return nil }
        let million = 1_000_000.0
        let missInput = cacheMissTokens + requestsWithoutCacheSplitInputTokens
        return Double(cacheHitTokens) / million * pricing.cacheHitInput
            + Double(missInput) / million * pricing.cacheMissInput
            + Double(completionTokens) / million * pricing.output
    }

    /// 没有缓存拆分的那部分输入 token 数
    public var requestsWithoutCacheSplitInputTokens: Int {
        max(0, promptTokens - cacheHitTokens - cacheMissTokens)
    }

    public func summaryText(pricing: AIPricing) -> String {
        guard !isEmpty else { return "还没有可统计的请求。" }
        var lines = [
            "累计请求：\(AITokenUsage.exact(requestCount)) 轮",
            "输入：\(AITokenUsage.exact(promptTokens)) tokens",
        ]
        if cacheHitTokens > 0 || cacheMissTokens > 0 {
            lines.append("  · 缓存命中 \(AITokenUsage.exact(cacheHitTokens)) / 未命中 \(AITokenUsage.exact(cacheMissTokens))")
        }
        lines.append("输出：\(AITokenUsage.exact(completionTokens)) tokens")
        lines.append("合计：\(AITokenUsage.exact(totalTokens)) tokens")
        if let cost = cost(pricing: pricing) {
            lines.append("估算费用：\(AIPricing.money(cost))")
        } else {
            lines.append("估算费用：未设置单价")
        }
        return lines.joined(separator: "\n")
    }
}
