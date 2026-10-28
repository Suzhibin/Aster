//
//  AIMemoryExtractor.swift
//  AICore
//
//  「长期记忆」的**唯一写入方**（2026-10-25）：每轮对话正常结束后，把最近几轮
//  对话 + 已有记忆清单发给当前模型，让它输出「该记什么 / 哪条该改」的 JSON
//  操作集，落到 `AIMemoryStore`。对齐豆包 / WorkBuddy 的自动记忆形态
//  （上线当天的 explicit-only 手动写点当天即被用户拍板反转，见 `AIMemoryStore`
//  文件头第 1 条）。
//
//  ## 五个必须记住的设计约束
//  1. **⛔ 不自动删**：op 只有 `add` / `update` / `none`。用户明说「忘掉 X」
//     也不自动执行——误删的代价（用户的重要背景静默消失）远大于漏删。
//     删除永远走管理页的手动删除。
//  2. **复用现有传输层**：请求走 `AIProvider.makeRequest` + `SSEClient`
//     （与 `AIChatManager.startStreaming` 同一条路），⛔ 不给 `AIProvider`
//     协议加非流式方法——那会牵动三个 provider 实现。
//  3. **全静默失败**：开关关着 / 没配模型 / 断网 / 模型不按格式输出 /
//     JSON 解析失败——一概不提示、不影响主对话，下轮再试。这条链上没有
//     toast 的位置（用户正在忙别的）。
//  4. **落库前回主线程**：`AIMemoryStore` 的写入会 `post` **同步**通知，
//     后台线程投递会让管理页的观察者在后台跑。
//  5. **update 按编号、且先把编号解析成 id**：模型对编号远比对 UUID 靠谱；
//     而 `add` 会插到最前**把编号挤位** ⇒ 必须先把所有 update 的编号解析成
//     id、再动库（先 update 后 add，顺序无所谓，id 已解析完）。
//
//  ## 触发与合并（成本控制）
//  由 `AIChatManager.finish()` 在**整轮正常结束**时调 `trigger(...)`：
//  ⛔ 不挂 stop()/handleError()——那两条路这一轮是废的。触发后**等 20s 才跑**
//  （尾随去抖）：连续说话时只跑最后一次，不会每轮都烧一次调用；跑着时又来
//  触发 ⇒ 标记重跑一次（用最新上下文，⛔ 不排队多个）。
//
//  ## DEBUG 探针后门
//  `debugTransportOverride` 替换掉「网络 + SSE」这一段（消息构建仍走真实
//  路径），供 `MemoryTraceProbe` 在无模型配置的容器里验完整抽取链。
//  ⚠️ 只在 DEBUG 编译；Release 包里没有这个后门。
//
//  ## 访问级别
//  ⚠️ 本类型标 public **只为 DEBUG 后门那几个成员**（照 `AIProviderFactory`
//    的先例）：业务调用方只有 `AIChatManager`（同 module，走 internal 的
//    `trigger`）。⛔ 别因此把 `trigger` 也放开——App 侧没有任何理由自己触发抽取。
//

import Foundation
import StarryKitCore

// MARK: - 抽取器

public enum AIMemoryExtractor {

    // MARK: 配置

    /// 尾随去抖间隔（秒）：最后一次触发后等这么久才跑。
    ///
    /// 连续说话时合并成一次（省调用）；抽取读的是「最近 3 轮」，晚十几秒
    /// 内容不会少。
    /// ⚠️ `public`：DEBUG 探针要把它临时改小（等 20s 的探针没人跑得动）。
    public static var debounceInterval: TimeInterval = 20

    /// 带上文的轮数（一问一答算一轮）。
    static let recentTurnCount = 3

    /// 单条消息进抽取上下文前的截断（字）。超长粘贴（整份财报之类）不进抽取——
    /// 「用户贴了一份财报」这种元信息没有记忆价值，白烧 token。
    static let perMessageCap = 500

    /// 已有清单的软上限（条）。满后只许 `update` 不许 `add`——注入块每轮都带，
    /// 无上限增长等于每轮都变贵。与 `AIMemoryStore` 文件头「上限在抽取器」对应。
    static let softCap = 50

    /// 一次抽取允许的最大 op 数（防模型一次「整理」出十几条）。
    static let maxOps = 3

    // MARK: 类型

    /// 喂给模型的一轮对话。
    ///
    /// ⚠️ `public`（且自带 `Role` 而**不是**复用 `AIChatMessage.Role`）：
    ///    DEBUG 探针在 App target，跨模块够不到 internal 类型（见文件头「访问级别」）。
    public struct Turn {
        public enum Role {
            case user
            case assistant
        }

        public let role: Role
        public let text: String

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    // MARK: 触发（串行 + 尾随去抖 + 合并）

    /// 串行队列：一次只跑一个抽取（SSE 回调本来在 `SSEClient.parseQueue` 上，
    /// 这里再收拢一层，保证「落库顺序 = 触发顺序」）。
    private static let queue = DispatchQueue(label: "com.aster.memory-extract")

    /// 正有一次抽取在跑吗（只在 `queue` 上读写）。
    private static var isRunning = false

    /// 跑着的时候又来了一次触发 ⇒ 置位；本轮跑完立刻用**最新**上下文再跑一次。
    private static var rerunRequested = false

    /// 最近一次触发登记的上下文提供者（只在 `queue` 上读写）。
    private static var recentTurnsProvider: (() -> [Turn])?

    /// 已排程但还没跑的去抖任务（只在 `queue` 上读写；新触发会 cancel 它）。
    private static var pendingWork: DispatchWorkItem?

    /// 在跑的连接（跑完置 nil；留着是为了将来「App 销毁时取消」有抓手）。
    private static var activeConnection: SSEConnection?

    /// 请求一次抽取（⛔ 别在调用处等它——内部全是异步的）。
    ///
    /// - Parameter recentTurns: 最近若干轮的**惰性**提供者。为什么是闭包而不是
    ///   快照：真正发请求排在 20s 去抖之后，那时间会话里可能又多了好几轮，
    ///   传快照等于拿旧上下文抽。
    static func trigger(recentTurns: @escaping () -> [Turn]) {
        queue.async {
            recentTurnsProvider = recentTurns
            // 新触发顶掉还没跑的那次（尾随去抖：只保留最后一次）
            pendingWork?.cancel()
            let work = DispatchWorkItem {
                guard let provider = recentTurnsProvider else { return }
                if isRunning {
                    rerunRequested = true
                } else {
                    startRun(provider)
                }
            }
            pendingWork = work
            queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        }
    }

    /// 开始一次抽取；完成后若有排队的重跑请求就接着跑（回调里已回到 `queue`）。
    private static func startRun(_ turnsProvider: @escaping () -> [Turn]) {
        isRunning = true
        performExtraction(turnsProvider: turnsProvider) { _ in
            queue.async {
                activeConnection = nil
                if rerunRequested {
                    rerunRequested = false
                    if let latest = recentTurnsProvider {
                        startRun(latest)
                    } else {
                        isRunning = false
                    }
                } else {
                    isRunning = false
                }
            }
        }
    }

    // MARK: 跑一次

    /// 完整跑一次抽取。任何一步失败都静默结束（见文件头第 3 条）。
    private static func performExtraction(turnsProvider: @escaping () -> [Turn],
                                          completion: @escaping (Bool) -> Void) {
        // ① 闸门：开关 / 有没有可抽的内容
        guard AIMemoryStore.isAutoExtractEnabled else { completion(false); return }
        let turns = turnsProvider()
        guard !turns.isEmpty else { completion(false); return }
        // 用户一个字都没打（纯附件轮）不抽——没有事实来源
        guard turns.contains(where: { $0.role == .user }) else { completion(false); return }

        // ② 组消息（截断在进模型前做）
        let messages = buildMessages(turns: turns)

        // ③ DEBUG 后门：探针替换掉「网络 + SSE」这一段
        #if DEBUG
        if let override = debugTransportOverride {
            // 给探针的是**两条消息的正文**（[system, user]）—— 据此断言
            // system prompt / 编号清单 / 对话记录都拼对了（走的是真实构建路径）。
            let text = override(messages.map { $0.content })
            DispatchQueue.main.async {
                applyParsed(text)
                completion(true)
            }
            return
        }
        #endif

        // ④ 取当前 provider（没配模型 ⇒ 静默结束）
        guard let aiProvider = try? AIProviderFactory.make() else { completion(false); return }

        // ⑤ 发请求（与 startStreaming 同一条传输层；回调在后台队列）
        guard let request = try? aiProvider.makeRequest(messages: messages) else { completion(false); return }
        // onEvent 与 onComplete 同在 SSEClient.parseQueue（串行）⇒ 直接拼安全
        var buffer = ""
        let client = SSEClient()
        activeConnection = client.connectWithStream(request,
            onEvent: { event in
                for e in aiProvider.events(from: event) {
                    if case .text(let s) = e { buffer += s }
                }
            },
            onError: { _ in
                // 静默：主对话优先，抽取失败不提示
            },
            onComplete: {
                let text = buffer
                DispatchQueue.main.async {
                    applyParsed(text)
                    completion(true)
                }
            })
    }

    // MARK: 消息构建

    /// 系统提示（**固定中文、不进 `L()` 词表**——与 `digest()` 同口径：
    /// 这是发给模型的内容，切界面语言不该改变它）。
    static var systemPrompt: String {
        """
        你是长期记忆提取员。用户在与助手对话，你负责把值得【跨会话】记住的信息提取成记忆条目。

        【记什么】
        - 用户的稳定事实与偏好：身份、职业、持仓及成本、工作习惯、长期项目、明确要求「以后都这样」的规则
        - 用户在对话中确认过的关键数字与结论（成本价、目标价、住址、称呼…）

        【不记什么】
        - 当轮的提问、临时意图、一次性请求（「帮我查下三安」不是记忆）
        - 助手的通用知识回答本身
        - 闲聊、情绪、客套

        【已有记忆】
        用户消息里附有已有记忆的编号清单。与某条重复、或某条已过期说错时，用 update 按编号改写它，不要重复添加。

        【输出】
        只输出 JSON，不要任何解释文字：
        {"ops":[{"op":"add","content":"一条记忆"},{"op":"update","index":2,"content":"改写后的第2条"}]}
        - op 只能是 add / update；没有值得记的就输出 {"ops":[]}
        - 一条只记一件事，每条不超过 60 字，用陈述句
        - 一次最多 \(maxOps) 个 op
        """
    }

    private static func buildMessages(turns: [Turn]) -> [AIChatMessage] {
        var transcript = ""
        for turn in turns {
            let name = turn.role == .user ? "用户" : "助手"
            let text = turn.text.count > perMessageCap
                ? String(turn.text.prefix(perMessageCap)) + "…"
                : turn.text
            transcript += "\(name)：\(text)\n"
        }

        let existing = AIMemoryStore.all()
        let list: String
        if existing.isEmpty {
            list = "（还没有任何记忆）"
        } else {
            list = existing.enumerated()
                .map { "\($0.offset + 1). \($0.element.content)" }
                .joined(separator: "\n")
        }
        var userContent = "【已有记忆】（编号从 1 开始，update 按编号指认）\n\(list)\n\n【最近对话】\n\(transcript)"
        if existing.count >= softCap {
            userContent += "\n\n（记忆已满 \(softCap) 条：本次只许 update，不许 add）"
        }
        return [
            AIChatMessage(role: .system, content: systemPrompt),
            AIChatMessage(role: .user, content: userContent),
        ]
    }

    // MARK: 解析与落库

    /// 模型输出的 JSON 外壳。字段全可选——模型漏字段是常态，按缺什么跳什么。
    private struct ExtractionPayload: Decodable {
        struct Op: Decodable {
            let op: String
            let content: String?
            let index: Int?
        }
        let ops: [Op]?
    }

    /// 解析模型输出并落库。**只在主线程调**（见文件头第 4 条）。
    private static func applyParsed(_ text: String) {
        guard let data = extractJSONData(from: text),
              let payload = try? JSONDecoder().decode(ExtractionPayload.self, from: data),
              let ops = payload.ops, !ops.isEmpty else {
            #if DEBUG
            debugDidApply?()
            #endif
            return
        }

        let existing = AIMemoryStore.all()
        let isFull = existing.count >= softCap

        // 🔴 先把 update 的编号解析成 id（按**原始清单**）再动库：add 会插到最前、
        //    update 会刷新时间重排，边解析边应用必然指错行（见文件头第 5 条）。
        var updates: [(id: UUID, content: String)] = []
        var adds: [String] = []
        for op in ops.prefix(maxOps) {
            switch op.op.lowercased() {
            case "add":
                if let content = op.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !content.isEmpty {
                    adds.append(content)
                }
            case "update":
                guard let index = op.index,
                      let content = op.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !content.isEmpty,
                      existing.indices.contains(index - 1) else { continue }
                updates.append((existing[index - 1].id, content))
            default:
                continue // ⛔ delete 及一切未知 op 一概不执行（见文件头第 1 条）
            }
        }

        var applied = 0
        for u in updates {
            if AIMemoryStore.update(id: u.id, content: u.content) { applied += 1 }
        }
        if !isFull {
            for content in adds {
                if AIMemoryStore.add(content: content) != nil { applied += 1 }
            }
        }
        #if DEBUG
        NSLog("%@", "[MemoryExtract] ops=\(ops.count) applied=\(applied) full=\(isFull)")
        debugDidApply?()
        #endif
    }

    /// 从模型输出里切出 JSON：模型爱在 JSON 外面包 ```json 围栏或一句解释。
    /// 取第一个 `{` 到最后一个 `}`——输出结构固定是单层对象，这个取法够用。
    private static func extractJSONData(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start <= end else { return nil }
        return Data(text[start...end].utf8)
    }

    // MARK: DEBUG 探针后门

    #if DEBUG
    /// DEBUG 探针专用触发入口（内部就是 `trigger`）。
    ///
    /// ⚠️ 为什么不把 `trigger` 直接标 public：业务上 App 侧**没有任何理由**
    ///    自己触发抽取（唯一触发点是 `AIChatManager.finish()` 的整轮收尾）——
    ///    多一个 public 入口就多一条「别处随手触发一次」的路。探针要验这条链，
    ///    走这个 DEBUG 专用包装；Release 包里两者都不公开。
    public static func debugTrigger(recentTurns: @escaping () -> [Turn]) {
        trigger(recentTurns: recentTurns)
    }

    /// 替换「网络 + SSE」这一段：入参是**构建好的两条消息正文**（[system, user]，
    /// 探针据此断言 system prompt / 清单 / 对话都拼对了），返回值是预录的模型输出文本。
    public static var debugTransportOverride: (([String]) -> String)?

    /// 落库走完（无论有没有应用 op）后回一次——探针靠它知道「跑完了」。
    public static var debugDidApply: (() -> Void)?
    #endif
}
