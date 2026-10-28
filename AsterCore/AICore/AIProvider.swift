//
//  AIProvider.swift
//  AIModule
//
//  接入层的「协议适配器」：把不同平台的差异（请求怎么构、流怎么解析）收在这里，
//  `AIChatManager` 只管落库 / 节流 / 驱动 UI，不关心对面是哪家。
//
//  ## 只有一个实现（2026-10-13 起）
//  `OpenAICompatibleProvider` —— 深度求索 / 智谱 / Kimi / 豆包 / MiniMax / 自定义 **六家都走它**：
//  都是 OpenAI 兼容的 POST + Bearer + OpenAI delta 流，差别只剩
//  「地址 / 模型名 / 收不收图 / 认不认思考参数」这四样 ——
//  🔴 **2026-10-14 起这四样都在「那一条配置」自己身上**（`AICustomModel`），
//  不再是 `AIProviderKind` 的属性：配置源换成了 `Documents/models.json`，
//  供应商预设（`AIProviderKind`）退居为「表单预填 + 图标 + 报错里的名字」。
//  所以造 provider 的入口从 `make(for kind:)` 变成了 `make(for entry:)`。
//
//  ☠️ **原先还有一个 `MockStreamProvider`**（本机 mock 服务器，GET + 私有事件协议 txt/end/img/vid/done）——
//  连同 `mock_sse_server.py`（8899 端口）、`MockStreamPayload` 与渲染台里对它的依赖，
//  2026-10-13 用户要求「本地 Mock 数据删除」时一并下线了。
//  ⚠️ 它当初的用途是「断网也能把 UI 调起来」，而那件事现在由**离屏渲染台**承担
//  （`.workbuddy/scripts/render_mac_ui.sh`，直接渲染真实视图、不经过网络）。
//  要加第 5 家平台时：先判断它是不是 OpenAI 兼容 —— 是就只改 `AIProviderKind`，
//  **不要**再新建一个 provider 实现。
//
//  事件体（SSE 的 data）的解码模型统一放在 `AIStreamPayloads.swift`（`SmartDecodable`）；
//  本文件里的 `makeRequest` 仍然是字典构造请求体，两边刻意不走同一套。
//

import Foundation
//import SmartCodable
import StarryKitCore
// MARK: - 消息

/// 发给模型的一条消息（与 UI 无关的最小结构；多轮上下文就是它的数组）
struct AIChatMessage {

    enum Role: String {
        case system
        case user
        case assistant
    }

    let role: Role
    let content: String

    /// 随这条消息一起发出去的**本地图片**（沙盒路径）。
    ///
    /// ⚠️ 只有 `user` 消息能带图：服务端对 system / assistant 消息里的图片直接返回 400。
    /// 多轮上下文里回放历史用户图片是允许的（也是视觉多轮对话的必需），
    /// 但 `contextMessages()` 必须保证不给助手那侧挂图。
    var imageURLs: [URL] = []

    /// 这是一条**待补全的前缀**（DeepSeek「对话前缀续写」Beta 专用标记）。
    ///
    /// 只有「继续生成」在**支持 prefix 的端点**上才会把它置为 true（见
    /// `AIProvider.supportsPrefixCompletion`），并且它**只能是请求的最后一条消息**（官方硬要求）。
    /// 它不落库、不参与 UI，活不过一次请求。
    ///
    /// 为什么非要有它：OpenAI 兼容的 `/chat/completions` 会把末尾那条 assistant 消息当成
    /// **一段已经说完的助手发言**，然后**重新生成**一条新回复 —— 用户看到的就是
    /// 「续写出来的内容从头又讲了一遍」。只有打了 `prefix: true`，服务端才做真正的**补全**。
    var isPrefix: Bool = false
}

// MARK: - 流事件

/// 从 SSE 流里解析出来的、面向 UI 的增量事件
enum AIStreamEvent {
    /// 正文增量
    case text(String)
    /// 思考过程增量（只有开了思考模式的 DeepSeek 会产生，见 `thinkingEnabled`）
    case reasoning(String)
    /// 当前文本块结束，但整轮可能还有后续块
    case finalizeText
    case image(URL)
    case video(url: URL, cover: URL?)
    /// 整轮结束
    case done
    /// 服务端给出的**结束原因**（OpenAI 兼容的 `finish_reason`：`stop` / `length` / `content_filter`…）。
    ///
    /// 为什么不并进 `.done`：`.done` 只说明「流到这儿停了」，而**停的原因**才决定这条回复
    /// 算不算写完。`length`（撞 max_tokens）与 `content_filter`（被审核掐了）都是「没写完」——
    /// 把它们当正常结束，用户就永远不知道自己的回答被截了半句（见 `AIChatManager.isTruncated`）。
    /// ⚠️ 两个事件的先后是 `finish_reason` **先**、`[DONE]` **后**。
    case finish(String)
    /// 这一轮的 token 用量（服务端在流末尾给的；没开 `include_usage` 或中途断了就没有）。
    ///
    /// 单独一个事件而不是挂在 `.done` 上：它出现的时机**早于** `.done`（在最后一个内容块上），
    /// 而且可能出现在一个 `choices` 为空的独立块上 —— 混进 `.done` 会让「整轮结束」
    /// 这个语义被用量数据污染（`handle(.done)` 里还有收尾动作）。
    case usage(AITokenUsage)
}

// MARK: - 错误

enum AIProviderError: LocalizedError {
    /// 清单里一条模型都没有（用户把它们全删了，或手改 JSON 改坏了）。
    ///
    /// 🔴 单独一个 case 而不是复用 `missingAPIKey`：这两种「没配」要去的地方不一样，
    ///    文案必须给出**下一步去哪**（一句「配置有误」等于没说）。
    case noModelConfigured
    /// 参数是**条目显示名**（`AICustomModel.displayName`），不是供应商名 ——
    /// 多条目之后「哪一家的哪个模型」才是有用的指认（同一家可以有好几条）。
    case missingAPIKey(String)
    case invalidBaseURL(String)
    case emptyModel(String)
    /// 当前模型不收图片。第三个参数是「换成哪个」的建议（供应商预设给不出来时是空串）。
    case modelWithoutVision(String, model: String, hint: String)

    var errorDescription: String? {
        switch self {
        case .noModelConfigured:
            return L("还没配置模型：去「设置 → 自定义模型」加一条，填上地址和 API Key")
        case .missingAPIKey(let name):
            return String(format: L("%@ 还没填 API Key，去「自定义模型」里补一下"), name)
        case .invalidBaseURL(let name):
            return String(format: L("%@ 的服务地址无效，检查一下那条配置"), name)
        case .emptyModel(let name):
            return String(format: L("%@ 还没填模型名，去「自定义模型」里补一下"), name)
        case .modelWithoutVision(let name, let model, let hint):
            // 在**发请求之前**就拦下：否则要等一次往返才拿到 400 "This model does not support image"，
            // 用户看到的只是一句看不懂的英文报错
            guard !hint.isEmpty else {
                return String(format: L("%@ 的「%@」不支持图片，换一个支持图片的模型再发"), name, model)
            }
            return String(format: L("%@ 的「%@」不支持图片，把模型名换成 %@ 再发"), name, model, hint)
        }
    }

    /// 从**条目**推「该换成哪个模型」。
    ///
    /// 三家的视觉模型名**各不相同**（见 `AIProviderKind.visionModelMarkers`），
    /// 而报错要给出具体名字 —— 所以只能问这一条配置的供应商预设。
    /// ⚠️ 自定义服务给不出建议（返回空串），文案会退化成泛泛的一句。
    static func visionModelHint(for entry: AICustomModel) -> String {
        entry.vendorKind?.visionModelSuggestion ?? ""
    }
}

// MARK: - 协议

/// 一个平台需要提供两件事：怎么发、怎么解（外加一条「能不能收图」的能力位）。
protocol AIProvider {

    /// 构造本次流式请求（URL / 方法 / 请求头 / body）。
    /// 配置缺失（没 Key、地址不合法）时抛 `AIProviderError`。
    func makeRequest(messages: [AIChatMessage]) throws -> URLRequest

    /// 把一条原始 SSE 事件解析成 0..n 个 UI 事件
    func events(from event: SSEEvent) -> [AIStreamEvent]

    /// 当前平台 / 模型**能不能收图片**。
    ///
    /// ⚠️ 这个能力位有**两处**必须用到，且必须与 `validateImageSupport()` 同源 ——
    /// 只判一处就会得到「发一张图报一次错，之后**每轮发文字都在复现同一个错**」：
    /// ① `AIChatManager.send()` 在**建行之前**校验本次附件：注定发不出去的图，
    ///    不该在对话里留下一条行（留了就是永久地雷，见 ②）；
    /// ② `AIChatManager.contextMessages()` 决定要不要**回放历史用户图片**：
    ///    收不了图的模型带上历史图，等于之后每一轮请求都注定失败。
    var canSendImages: Bool { get }

    /// 发送前的图片能力校验：不能发时抛 `AIProviderError`（文案就是给用户看的解释）。
    func validateImageSupport() throws

    /// 当前模型的**上下文窗口**（token 数）。用于「上下文长度管理」的预算裁剪
    /// （见 `AIContextBudget`）。
    ///
    /// 放在协议上而不是让 manager 自己去查模型名：窗口是**模型 / 平台**的属性，
    /// 与 `canSendImages` 同类 ——「平台差异全在 provider」，manager 不碰平台细节。
    ///
    /// ⚠️ **必须写成协议要求，不能只写在下面的 extension 里**：只存在于 extension 的成员
    /// 对 `AIProvider` 这类存在类型是**静态派发**的，`OpenAICompatibleProvider` 的覆盖
    /// 永远轮不到 —— 表现是「裁剪写好了、编译通过、一次都不生效」，且类型检查**一条错都不报**。
    ///
    /// 返回 `nil` = 该平台**不参与裁剪**。
    var contextWindow: Int? { get }

    /// 这一平台**是否必须联网**。
    ///
    /// 用于发送前的可达性检查（明确离线时立刻提示，不必等 120s 空闲超时）。
    /// 默认 `true`；只有「跑在本机、不经过网络」的平台才该覆盖成 `false` —— 断网时它照样连得上，
    /// 拦下它是误伤。⚠️ 2026-10-13 起三家都是官方云服务（都走公网）⇒ 没有任何实现覆盖它，
    /// 之所以保留这个能力位：它必须**写成协议要求**（见下），删掉协议要求就等于留一个
    /// 「只写在 extension 里 ⇒ 对存在类型静态派发 ⇒ 永远不生效」的陷阱。
    ///
    /// ⚠️ 与 `contextWindow` 同理，**必须写成协议要求**：只写在下面 extension 里的成员
    /// 对 `AIProvider` 这种存在类型是**静态派发**的，实现的覆盖永远轮不到
    /// ——表现是「写好了、编译通过、一次都不生效」，而类型检查一条错都不报。
    var requiresNetwork: Bool { get }

    /// 这个端点**能不能做真正的前缀续写**（DeepSeek「对话前缀续写」Beta）。
    ///
    /// 「继续生成」有两条路，靠这个能力位二选一（见 `AIChatManager.continuationMessages`）：
    /// 能 → 末条 assistant 打 `prefix`，服务端**补全**，吐回来的一定是接在后面的字；
    /// 不能 → 退化成补一条临时 user 指令，靠指令约束模型接着写。
    ///
    /// ⚠️ 与 `contextWindow` / `requiresNetwork` 同理，**必须写成协议要求**：
    /// 只写在 extension 里的成员对 `AIProvider` 这种存在类型是**静态派发**的，
    /// 覆盖永远轮不到 ——「写好了、编译通过、一次都不生效」，且类型检查一条错都不报。
    var supportsPrefixCompletion: Bool { get }
}

extension AIProvider {

    /// 默认收图。**只有 `OpenAICompatibleProvider` 会覆盖它**（读那一条配置自己的
    /// `supportsImages`，见那边）—— 那是唯一能问出「这个模型收不收图」的地方。
    var canSendImages: Bool { true }

    /// 默认无需校验（收图能力不做限制的平台没什么可拦的）
    func validateImageSupport() throws {}

    /// 默认不做上下文裁剪。理由同 `canSendImages` 的默认值 —— 默认取**宽松**：
    /// 裁剪是「少发一点历史」，猜错了会静默丢上下文；不裁最多是维持现状。
    var contextWindow: Int? { nil }

    /// 默认**要联网**（真实平台的请求都要出网）。保守取向：拿不准就当它需要网络，
    /// 大不了在断网时多提示一句；反过来（猜成不需要）则会漏掉「明确离线」那种该立刻提示的情况。
    var requiresNetwork: Bool { true }

    /// 默认**不支持**前缀续写：这是 DeepSeek Beta 的独有功能，另外两家（智谱 / Kimi）
    /// 不认识 `prefix` 字段，对它们只能走「指令法」。
    /// 拿不准时取保守值 —— 猜成支持会让它们收到未知字段（可能直接 400）。
    var supportsPrefixCompletion: Bool { false }
}

// MARK: - OpenAI 兼容（六家共用：五家官方 + 自定义）

/// 一份配置造一个。**所有平台差异的真相都在 `entry` 身上**（地址 / 模型名 / 收不收图 /
/// 认不认思考参数），这个类型本身不含任何平台分支 —— 除了那条「`stream_options` 只给
/// DeepSeek 加」（那是接口实现细节，不是配置项，见 `body`）。
struct OpenAICompatibleProvider: AIProvider {

    /// 这一条配置（`Documents/models.json` 里的一项）
    let entry: AICustomModel
    /// 是否开启思考模式（全局开关，见 `AIConfig.thinkingEnabled`）
    let thinkingEnabled: Bool

    /// 界面上指认这一条用的名字（报错文案读它）
    private var displayName: String { entry.displayName }

    /// 去过空白的模型名（请求体、报错文案、图片能力判断都用它，别各自 trim 一遍）
    private var normalizedModel: String { entry.normalizedID }

    // MARK: 图片能力（协议要求，且是「能不能带图」的唯一真值）

    /// 🔴 **直接读条目自己的布尔**（`AICustomModel.supportsImages`）。
    ///
    /// 改造前这里是「按平台的特征串 + 模型名判」（`AIProviderKind.visionModelMarkers`）——
    /// 那时地址与模型名都是代码里的常量，只能那样认。
    /// 现在一条配置自带能力位 ⇒ 判据就是它，用户手改 JSON 可以直接覆盖。
    /// ⚠️ 从界面加出来的配置，那个布尔是**保存时按预设 + 模型名算好**的
    /// （`AICustomModel.inferFrom`）⇒ 行为与改造前一致。
    var canSendImages: Bool { entry.supportsImages }

    func validateImageSupport() throws {
        guard !canSendImages else { return }
        throw AIProviderError.modelWithoutVision(displayName,
                                                 model: normalizedModel,
                                                 hint: AIProviderError.visionModelHint(for: entry))
    }

    // MARK: 上下文窗口（协议要求）

    /// 条目自己的 `maxInputTokens` 优先，缺省按模型名查表（`AIContextBudget`）。
    ///
    /// **必须给**：真实平台的请求体就是上下文本身，不给窗口 = 会话一长必然撞上限，
    /// 然后**每一轮都失败**。
    var contextWindow: Int? { entry.contextWindow }

    /// 判据落在**地址**上而不是供应商。
    ///
    /// 2026-10-13 起三家地址都是预设常量、用户改不了，所以对它们等价于
    /// 「DeepSeek 那家自带的地址里有 `/beta` ⇒ 只有它支持前缀续写」。
    /// ⚠️ 保留「认地址」这个写法：前缀续写是**端点能力**不是平台能力 ——
    ///    自定义服务若把地址指到某个 beta 端点，它照样能续写；
    ///    哪天 DeepSeek 把 beta 收编进正式端点，改一处预设就自动跟着变。
    var supportsPrefixCompletion: Bool { entry.normalizedURL.contains("/beta") }

    func makeRequest(messages: [AIChatMessage]) throws -> URLRequest {
        let cleanModel = normalizedModel   // 与 `entry.id` 区分开，避免「这份到底 trim 过没有」的误读
        let base = entry.normalizedURL
        guard let url = URL(string: base),
              let scheme = url.scheme, scheme.hasPrefix("http"),
              // ⚠️ host 也要判：`https://` 这种**语法合法但打不通**的串，只判 scheme 会放过去，
              //    然后用户在网络上等一次莫名其妙的失败（自定义服务刚加出来时最容易出现）。
              let host = url.host, !host.isEmpty else {
            throw AIProviderError.invalidBaseURL(displayName)
        }
        // 四家都必填 Key（改造前这里按 `kind.requiresAPIKey` 分支，那是为「自建服务常常无鉴权」
        // 留的口子；JSON 化之后那个能力位没了 —— 要支持无鉴权服务，把这条判断按条目放开）
        if (entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty {
            throw AIProviderError.missingAPIKey(displayName)
        }
        guard !cleanModel.isEmpty else { throw AIProviderError.emptyModel(displayName) }

        // 带图但模型不收图 → 提前拦掉（省一次注定失败的往返，也把英文 400 换成能看懂的话）。
        // `AIChatManager.send()` 已经前置拦过一次（那种情况连行都不会建），这里是兜底：
        // 从别的路径进来、或历史上下文里带着图时，仍然要拦住。
        // 判定复用 `validateImageSupport()`，不另写一份规则 —— 两处规则漂移正是「每轮复现同一个错」的来源。
        if messages.contains(where: { !$0.imageURLs.isEmpty }) {
            try validateImageSupport()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")
        // timeoutInterval 是「空闲超时」（有数据就一直续），思考模式首字节可能等很久，给足
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body(messages, model: cleanModel))
        return request
    }

    private func body(_ messages: [AIChatMessage], model: String) -> [String: Any] {
        var dict: [String: Any] = [
            "model": model,
            "messages": messages.map { messageBody($0) },
            "stream": true,
        ]
        // 要 token 用量。
        //
        // **只给 DeepSeek 加**：`stream_options` 是较新的 OpenAI 兼容扩展，别家不一定认；
        // 多一个不认识的顶层字段可能直接 400 —— 那会把**本来能用的**配置打挂，
        // 代价远大于「少一个用量数字」。
        // ⚠️ 这是**接口实现细节、不是配置项**，所以仍然按供应商预设分支（而不是挪进 JSON）：
        //    它随「对面是哪家服务」变，用户既看不懂也不该操心。
        if entry.vendorKind == .deepSeek {
            dict["stream_options"] = ["include_usage": true]
        }
        // 思考模式的请求字段：**两个条件都满足才发** ——
        // ① 这条配置认这两个字段（`supportsReasoning`，从界面加出来的由预设算好）；
        // ② 全局开关开着（`thinkingEnabled`，默认关）。
        // ⚠️ DeepSeek 的思考模式**默认是开的**（effort=high）：不显式关掉的话，
        //    前面十几秒只吐 reasoning_content，正文一个字都没有，看起来就是「卡住不动」——
        //    所以「关」也要显式发一个 `reasoning_effort: none`，不是「不发就行」。
        if entry.supportsReasoning {
            if thinkingEnabled {
                dict["reasoning_effort"] = entry.reasoning?.defaultEffort ?? "high"
                dict["thinking"] = ["type": "enabled"]
            } else {
                dict["reasoning_effort"] = "none"
            }
        }
        // 采样参数（2026-10-20 随「生成参数」设置页新增）。
        //
        // **默认不发**（`AIGenerationSettings.temperatureEnabled` / `maxTokensEnabled`
        // 默认关）⇒ 请求体与功能上线前逐字节一致，不动的配置不会被打挂。
        // 开了才发：temperature / max_tokens 是 OpenAI 兼容最古老的两个核心字段，
        // 六家都认（与 `stream_options` / `reasoning_effort` 那些扩展字段不同，
        // 那两个要按供应商预设分支、这两个不用）。
        // ⚠️ 但「都认」不等于「认任意值」：o1 / 推理类模型只接受 temperature=1 ——
        //    所以默认必须是「不发、用服务端默认」，让用户自己决定要不要覆盖。
        if AIGenerationSettings.temperatureEnabled {
            dict["temperature"] = AIGenerationSettings.temperature
        }
        if AIGenerationSettings.maxTokensEnabled {
            dict["max_tokens"] = AIGenerationSettings.maxTokens
        }
        return dict
    }

    /// 一条消息的请求体形态。
    ///
    /// **没有图片时 content 仍是字符串**（改造前的老形态）——这点很重要：
    /// 不带附件的请求体与以前逐字节一致，不会因为「多了个没人用的数组」
    /// 把某些只认 `content: String` 的兼容服务打挂。带图时才升级成 OpenAI 的多模态数组。
    private func messageBody(_ item: AIChatMessage) -> [String: Any] {
        var plain: [String: Any] = ["role": item.role.rawValue, "content": item.content]
        // 「对话前缀续写」标记（Beta）。只有 `supportsPrefixCompletion` 的端点才会走到这里，
        // 其余两家永远拿不到这个字段 —— 同 `stream_options` 那条理由：多一个不认识的字段
        // 就可能把**本来能用的**配置打挂。
        if item.isPrefix { plain["prefix"] = true }
        guard !item.imageURLs.isEmpty else { return plain }

        var blocks: [[String: Any]] = []
        let text = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
        // 图片在前、文字在后：先看图再读要求，模型对「针对这张图…」的指代更稳
        for url in item.imageURLs {
            // 编码 + 缓存都在附件层（`AIAttachmentStorage.dataURL`）：它才知道「文件在哪、
            // 存了什么」，provider 只需要「一条能塞进请求体的 data URL」。
            // 缓存让「历史图片每轮重编一遍」这件事只发生一次（见该方法的说明）。
            guard let dataURL = AIAttachmentStorage.dataURL(for: url) else { continue }
            blocks.append(["type": "image_url", "image_url": ["url": dataURL]])
        }
        if !text.isEmpty {
            blocks.append(["type": "text", "text": text])
        }
        // 一张图都没编出来就退回纯文本，别发出 content 为空数组的畸形请求
        guard !blocks.isEmpty else { return plain }
        return ["role": item.role.rawValue, "content": blocks]
    }

    func events(from event: SSEEvent) -> [AIStreamEvent] {
        // ⚠️ 必须最先拦：`[DONE]` 不是 JSON，进解析器就是白跑一次失败解析
        if event.data == "[DONE]" { return [.done] }

        // 全 optional 的结构体**任何**合法 JSON 都能解出来（包括错误体），
        // 所以「有没有效」不看 deserialize 的返回值，看下面这些字段是否非空。
        guard let chunk = OpenAIChatChunk.deserialize(from: event.data) else { return [] }

        var events: [AIStreamEvent] = []

        // ① 先取用量，**再**取正文增量 —— 顺序不能反。
        //    `usage` 那一帧的 `choices` 可能是**空数组**（OpenAI 及部分兼容服务的做法），
        //    如果先 `guard let delta = chunk.choices?.first?.delta else { return [] }`，
        //    整帧会被挡掉，用量永远拿不到。
        if let usage = chunk.usage?.usageModel {
            events.append(.usage(usage))
        }

        // ② 正文 / 思考增量。没有 choices（纯 usage 帧）时这一步自然什么都不加
        if let delta = chunk.choices?.first?.delta {
            if let reasoning = delta.reasoningContent, !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
            if let content = delta.content, !content.isEmpty {
                events.append(.text(content))
            }
        }

        // ③ 结束原因（与 delta 同层）。放在正文之后：这一帧通常没有正文
        if let reason = chunk.choices?.first?.finishReason, !reason.isEmpty {
            events.append(.finish(reason))
        }
        return events
    }
}

// MARK: - 工厂

/// 按某一条配置造 provider。所有平台差异的「出口」就这一个地方。
///
/// ⚠️ 本类型标 public **只为下面那个 `currentRequiresNetwork()`**。
/// `make()` 保持 internal：它返回的 `AIProvider` 是**包内协议**，
/// 公开它等于把「请求怎么构 / 流怎么解析」的全部细节摊给每个 App —— 那是包该收口的东西。
/// App 侧要问「现在这个 provider 吃不吃网络」，就用那个语义化的查询方法。
public enum AIProviderFactory {

    /// 当前配置的 provider 是否需要网络。
    ///
    /// 给 App 侧的「发送前网络预检」用：⚠️ 2026-10-14 起（自定义平台也走公网、本机 mock 已删）
    /// 现在**恒为 true**，但保留这个查询（而不是让 App 直接写 `true`）：
    /// 哪天用户真的填了个本机服务（ollama / llama.cpp，`http://127.0.0.1:11434/...`），
    /// 唯一的改动点就是按地址判 `requiresNetwork`，App 侧一行都不用动。
    /// ⚠️ 取不到配置时返回 `true`（保守当作需要网络）。
    public static func currentRequiresNetwork() -> Bool {
        guard let provider = try? make() else { return true }
        return provider.requiresNetwork
    }

    /// 六家**共用**同一个实现（都是 OpenAI 兼容协议），差异全在 `entry` 身上。
    /// ⛔ 别为「新加一家」再写一个 provider —— 除非它**不是** OpenAI 兼容（那才需要新实现）。
    static func make(for entry: AICustomModel) throws -> AIProvider {
        OpenAICompatibleProvider(entry: entry, thinkingEnabled: AIConfig.thinkingEnabled)
    }

    /// 造「现在这一条」的 provider。
    ///
    /// ⚠️ 每次请求**现造**、现读 `AIModelStore.current` ⇒ 换模型对本条消息立刻生效；
    ///    正在收流的那一轮用的是它开始时的配置（不打断，也不需要打断）。
    /// ⚠️ 清单空时抛 `noModelConfigured` —— 文案直接告诉用户去哪儿加（见 `AIProviderError`）。
    static func make() throws -> AIProvider {
        guard let entry = AIConfig.current else { throw AIProviderError.noModelConfigured }
        return try make(for: entry)
    }
}
