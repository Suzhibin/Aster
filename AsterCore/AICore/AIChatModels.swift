import Foundation
import CoreGraphics
import AIPlatform

// MARK: - 聊天数据模型

/// 一条消息块：一轮对话由多个块组成（文本 / 图片 / 视频）
public enum AIBlockKind {
    case text
    case image
    case video
    /// 用户发出的**文件**附件（PDF / txt / zip…）。
    ///
    /// 与 `.image` 分开是有必要的：图片靠 `imageURL` 直接渲染，文件要画「图标 + 文件名 + 大小」
    /// 的卡片，且**不一定发得给模型**（模型只吃图片和文字）—— 两者的行高与渲染路径完全不同。
    case file
    /// 失败提示块：正文即「这一轮为什么没回」的说明（如「⚠️ 账户余额不足（HTTP 402）」）。
    ///
    /// 刻意做成独立 kind 而不是塞进 `text`：因为它只用于向用户交代失败原因，
    /// **不能参与多轮上下文组装**（否则会被当成「助手说过的话」回传给模型）。
    /// 独立 kind 后 `contextMessages()` 只挑 `.text` 的规则天然把它排除，
    /// 且落库后重启也认得出来，无需靠文案前缀猜。
    case error
    /// 模型切换的**系统消息**（2026-10-21）：「—— 模型已从 A 更改为 B ——」。
    ///
    /// 与 `.error` 同一个理由做成独立 kind，且**比 `.error` 更「不是内容」**：
    /// 它连「这一轮的输出」都不是 —— 是系统在用户换模型时记下的一笔流水。
    /// 塞进 `.text` 会被 `contextMessages()` 当助手说过的话回传、被分享文本带出去；
    /// 塞进 `.error` 会顶掉失败提示那套重试菜单与橙色。
    ///
    /// 🔴 **零交互**（用户明确「不用有任何点击事件和交互」）：不挂操作栏
    ///    （`AIChatManager.applyActionBarFlags` 只认 `.text`）、不进长按操作卡
    ///    （`AIRowAction.chatMenu(for:)` 返空集合）、不进右键菜单、不参与上下文与分享。
    /// 结构化数据（从哪切到哪）在 `block.modelSwitch`，落新表 `ai_model_switch`
    /// —— 见 `AIModelSwitch` 文件头。
    case modelSwitch
}

public struct AIBlock: Identifiable {
    /// ⚠️ 必须是**显式赋值的 `let`**（不能写 `= UUID()` 再在 init 里覆盖 —— `let` 带初始值就不可再赋值）。
    /// 它同时是 `Identifiable` 的稳定身份与**落库主键**：`ai_message.mId` 存的就是它，
    /// 因而「搜索结果按 message id 定位」「重新生成删指定行」「用量按 block.id 关联」
    /// 三件事都依赖它从库里原样带回来（见 `AIChatStore.loadConversation`）。
    public let id: UUID
    public var kind: AIBlockKind

    // text
    public var text: String
    /// 是否仍在流式接收中（仅 text 块使用）
    public var isStreaming: Bool

    // image / video
    public var imageURL: URL?
    public var videoURL: URL?
    public var videoCoverURL: URL?

    // 附件
    /// 文件附件的沙盒路径（仅 `.file`；落库时与图片复用 `image_url` 同一列）
    public var fileURL: URL?
    /// 文件字节数（仅 `.file`；**不入库**，载入时从磁盘现算）
    public var fileSize: Int64
    /// 图片的像素尺寸。**只给用户发出的图片**——行高要按真实宽高比算（助手侧固定 16:9，不读它）
    public var mediaSize: CGSize?

    /// 这一轮服务端给出的 token 用量（**只有助手回复会有**）。
    ///
    /// 放在 block 上而不是 `AIChatRow` 上：它描述的是「这条回复消耗了多少」，
    /// 与持久化一一对应（`ai_usage` 表按 block.id 存），也不随视图状态变化。
    /// 服务端没返回（兼容平台没开 `include_usage`、或流中断）时为 `nil`，
    /// 界面就不显示用量 —— **不本地估算**，猜出来的数字拿来计价是误导。
    public var usage: AITokenUsage?

    /// 这条消息**引用**了哪条历史消息（只有用户自己发的消息会有）。
    ///
    /// 与 `usage` 不同，它**不在 `ai_message` 表里** —— 单独一张 `ai_quote` 表（主键 = 本消息 id）。
    /// 这么做是为了零迁移风险：给已有表加列要按「结构探测 + 幂等补列」写脚本，
    /// 而本工程历史上就吃过「补列被跳过 → 读列直接 Fatal」的亏（见 `AIChatStore.runMigrations`）。
    /// 新功能加新表是既有约定（token 用量也是这么落地的）。
    ///
    /// 只在 `send` 建行时挂上；`loadConversation` 会把它读回来。**视图层不生成它**。
    public var quote: AIQuote?

    /// 这条消息**@ 了哪几份项目资料**（只有用户自己发的文本行会有，2026-10-21）。
    ///
    /// 与 `quote` 一样**不在 `ai_message` 表里** —— 单独一张 `ai_mention` 表。
    /// 但两者的存储形态**刻意不同**（成因见 `AIMention` 文件头）：
    /// `quote` 存的是被引消息的**文本快照**，`mention` 存的是**资料指针**
    /// （`projectFileId` + `storageName`），正文在发送那一刻才从磁盘读 ——
    /// 资料是活的（用户可能刚更新了那份文档），塞快照进库只会存一份会过期的事实。
    ///
    /// 🔴 **只在 `send` 建行时挂上**；`loadConversation` 会把它读回来；
    ///    `editAndResend` 要像 `quote` 那样**跟着新文本一起走**（编辑改的是正文，
    ///    「我这轮参考了哪几份资料」没变）；`regenerate` 不用管（它不重建用户行）。
    /// ⚠️ 只挂**文本行**：img/file 行没有正文可「附带资料」，渲染侧也只在用户文本行画待发条。
    /// 条数上限见 `AIMention.maxPerMessage`。
    public var mentions: [AIMention] = []

    /// 这条回复的**思考过程**（只有助手回复会有：推理模型在正文之前先想的那段话）。
    ///
    /// 与 `usage` / `quote` 同样**不在 `ai_message` 表里** —— 单独一张 `ai_reasoning` 表
    /// （主键 = 本消息 id，1:1），见 `AIReasoning` 文件头。
    ///
    /// 🔴 **不进请求上下文**：思考是模型的草稿纸，`contextMessages()` 只取 `block.text`，
    ///    天然把它排除；回传只会烧 token，还容易让模型混淆「哪句是自己说过的」。
    ///
    /// 流式期间由 `AIChatManager.handle(.reasoning)` 逐段拼上来（总闸
    /// `AIGenerationSettings.showsThinkingProcess` 关着时根本不缓冲）；收尾时随正文一起落库。
    public var reasoning: AIReasoning?

    /// 这条**系统消息**记录的「模型从哪切到哪」（只有 `.modelSwitch` 行会有）。
    ///
    /// 与 `reasoning` 同样**不在 `ai_message` 表里** —— 单独一张 `ai_model_switch` 表
    /// （主键 = 本消息 id，1:1），见 `AIModelSwitch` 文件头。
    ///
    /// 🔴 **两条显示规则的数据来源**：`loadConversation` 会把它读回来，没有它
    ///    （老数据 / 表丢了）规则就不成立 —— 那条路按「新插一条」处理，不猜。
    /// ⚠️ **展示文案不读它**：行上的 `text` 才是渲染入口（`modelSwitchText` 会优先现算）。
    public var modelSwitch: AIModelSwitch?

    // MARK: - 展示

    /// 这一行要显示的文案。
    ///
    /// 有结构化数据时**现算**（`AIModelSwitch.noticeText` 走 `L()`）——
    /// 🔴 `L()` 的结果不能被缓存：落库那份 `text` 是写入那一刻的语言，切语言后
    ///    理应跟着变（同 `AIReasoning.collapsedTitle` 那条教训）。
    /// 没有结构化数据时（老数据 / 表丢了）才退回落库的 `text` —— 至少那条流水还在。
    public var modelSwitchText: String {
        if case .modelSwitch = kind, let record = modelSwitch { return record.noticeText }
        return text
    }

    // MARK: 运行时状态（不落库）

    /// 这条回复**没写完**就结束了（服务端 `max_tokens` 截断 / 网关静默掐流 / 用户自己按了停止）。
    ///
    /// 由 `AIChatManager.finalizeStreamingText()` 在收尾时判定写入，只用来决定
    /// **长按操作卡里出不出现「继续生成」**（见 `AIRowAction.chatMenu(for:)`）。
    ///
    /// ⚠️ **内存态、刻意不落库**：它不属于消息内容，重启后从库里恢复的行一律是 `false`
    /// （表现为「重启后那条半截回复不再提供继续生成」）。要持久化就得给 `ai_message` 加列，
    /// 而本工程对「加列」有明确教训（迁移靠「结构探测 + 幂等补列」，漏一次就是读缺失列 Fatal），
    /// 为一个菜单项付这个代价不值得 —— 真要做也应当**加新表**（同 `ai_usage` / `ai_quote`）。
    public var endedTruncated: Bool = false

    // MARK: 构造

    public init(id: UUID = UUID(),
                kind: AIBlockKind,
                text: String = "",
                isStreaming: Bool = false,
                imageURL: URL? = nil,
                videoURL: URL? = nil,
                videoCoverURL: URL? = nil,
                fileURL: URL? = nil,
                fileSize: Int64 = 0,
                mediaSize: CGSize? = nil,
                usage: AITokenUsage? = nil,
                quote: AIQuote? = nil,
                mentions: [AIMention] = [],
                reasoning: AIReasoning? = nil,
                modelSwitch: AIModelSwitch? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.isStreaming = isStreaming
        self.imageURL = imageURL
        self.videoURL = videoURL
        self.videoCoverURL = videoCoverURL
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.mediaSize = mediaSize
        self.usage = usage
        self.quote = quote
        self.mentions = mentions
        self.reasoning = reasoning
        self.modelSwitch = modelSwitch
    }

    public static func text(_ text: String, streaming: Bool = false) -> AIBlock {
        AIBlock(kind: .text, text: text, isStreaming: streaming)
    }

    /// 图片块。用户发出的图片要带 `mediaSize`，否则行高只能退回 16:9 猜
    public static func image(url: URL, mediaSize: CGSize? = nil) -> AIBlock {
        AIBlock(kind: .image, imageURL: url, mediaSize: mediaSize)
    }

    public static func video(url: URL, cover: URL?) -> AIBlock {
        AIBlock(kind: .video, videoURL: url, videoCoverURL: cover)
    }

    /// 文件附件块。文件名放 `text`——与 `.error` 用 text 放提示同理：
    /// 一行一块，总得有个主文案承载「这块是干什么的」。
    public static func file(url: URL, name: String, size: Int64) -> AIBlock {
        AIBlock(kind: .file, text: name, fileURL: url, fileSize: size)
    }

    /// 失败提示块：正文放「为什么没回」的说明
    public static func error(_ message: String) -> AIBlock {
        AIBlock(kind: .error, text: message)
    }

    /// 模型切换系统消息块。正文**由 `noticeText` 现算**（见 `modelSwitchText`）——
    /// 同一个出口保证「落库那份」与「渲染那份」不会漂移。
    public static func modelSwitch(_ record: AIModelSwitch) -> AIBlock {
        var block = AIBlock(kind: .modelSwitch, text: record.noticeText)
        block.modelSwitch = record
        return block
    }
}

/// 一次独立对话：标题 + 该对话的全部行。
/// 标题默认在首条消息发送时取「第一句话」，列表展示时由 AIConversationSummary 补默认文案。
///
/// - Note: `id` 与两个时间戳可由外部传入：从数据库恢复时必须沿用库里的主键与创建时间，
///   不能用默认的新 UUID / 当前时间，否则每次恢复都是「新会话」。
public struct AIConversation: Identifiable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var rows: [AIChatRow]
    /// 所属项目 id（2026-10-21）。**随会话恢复从库里带上**（恒非 nil：新建会话
    /// = 默认项目「任务」，2026-10-25 起「未归类」已消灭）。
    /// 用途：① 项目级指令（`AIChatManager` 生效提示词时读它）；② UI 高亮当前项目分组。
    /// 归类动作走 `AIChatManager.setConversationProject`，**不在这里直接改**。
    public var projectId: UUID?

    /// 展示标题（空标题补「新对话」）。
    /// ⚠️ 口径与 `AIConversationSummary.displayTitle` **必须一致** —— 两处都是
    /// 「给人看的那个标题」（一个在列表行上、一个在分享出去的文本里），改一处就两处一起改。
    public var displayTitle: String { title.isEmpty ? L("新对话") : title }

    public init(id: UUID = UUID(),
                title: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date(),
                rows: [AIChatRow] = [],
                projectId: UUID? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rows = rows
        self.projectId = projectId
    }
}

/// 对话列表项（侧滑菜单用）。
///
/// 只带列表渲染需要的字段：加载列表时不会把历史消息一并读进内存，
/// 点进某项时再由 AIChatStore 按 id 载入该会话的全部行。
public struct AIConversationSummary: Identifiable {
    public let id: UUID
    public var title: String
    public let updatedAt: Date
    public let messageCount: Int
    /// 是否置顶（置顶会话排在列表最前）
    public let isPinned: Bool
    /// 所属项目 id（2026-10-21）。2026-10-25 起「未归类」已消灭 ⇒ 正常路径恒非 nil
    /// （默认项目「任务」兜底）；默认值 nil 只为兼容既有构造点，
    /// **别在新代码里显式传 nil** —— store 读取与投影都有兜底，但那是防线不是通道。
    public let projectId: UUID?

    public init(id: UUID, title: String, updatedAt: Date, messageCount: Int,
                isPinned: Bool = false, projectId: UUID? = nil) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.isPinned = isPinned
        self.projectId = projectId
    }

    /// 列表展示标题（空标题补「新对话」）。
    /// ⚠️ 与 `AIConversation.displayTitle` **同一口径**（那个用在分享出去的文本抬头上）——
    /// 两处都是「给人看的标题」，改一处就两处一起改。
    public var displayTitle: String { title.isEmpty ? L("新对话") : title }
}

/// 项目（会话的「文件夹」容器，2026-10-21 立项）。
///
/// 形态照豆包 / WorkBuddy：**排他归属**（一条会话的 `projectId` 只有一个），
/// 项目可空（会话可以不归任何项目）、置顶与项目**平级**（置顶会话不参与项目分组）。
/// ⛔ 不要做成标签（多对多）—— C 端 AI 产品清一色文件夹，理由见项目笔记。
///
/// - `instruction`：项目级系统提示词（L3）。**空 = 回落全局**（与
///   `AIGenerationSettings.systemPrompt` 的「空 = 不发」语义兼容，见那个属性的注释）。
/// - `sortOrder`：项目间排序（管理页可调）；**会话组内**始终按 `updatedAt DESC`，
///   不提供 per-group 排序偏好 —— 那是配置噪音。
public struct AIChatProject: Identifiable {
    public let id: UUID
    public var name: String
    public var instruction: String
    public let sortOrder: Int
    public let createdAt: Date

    public init(id: UUID = UUID(),
                name: String,
                instruction: String = "",
                sortOrder: Int = 0,
                createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.instruction = instruction
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

/// 项目资料（挂在项目下的文件，2026-10-21）。
///
/// 存储形态与消息文件块**同源**：`storageName` 是 `AIAttachmentStorage` 的存储标识
/// （沙盒路径会随容器变，⛔ 不存绝对路径），显示名单独存一列（磁盘名是一串 UUID）。
public struct AIChatProjectFile: Identifiable {
    public let id: UUID
    public let projectId: UUID
    public var displayName: String
    public let storageName: String
    public let byteSize: Int64
    public let createdAt: Date

    public init(id: UUID = UUID(),
                projectId: UUID,
                displayName: String,
                storageName: String,
                byteSize: Int64,
                createdAt: Date = Date()) {
        self.id = id
        self.projectId = projectId
        self.displayName = displayName
        self.storageName = storageName
        self.byteSize = byteSize
        self.createdAt = createdAt
    }

    /// 沙盒里的真实路径（`storageName` → URL；文件已被删 / 名字是坏的 ⇒ nil）。
    ///
    /// 🔴 与 `AIDocumentItem.fileURL` 不同：那个是**查询时**就解析好的（消息表的 text 列存的是绝对路径），
    /// 这里存的是**存储标识**（相对），所以只能现解析 —— 好处是换容器 / 重装后仍然有效。
    /// ⛔ 别在调用方各自 `AIAttachmentStorage.resolve(...)`：解析口径只有这一处。
    public var fileURL: URL? { AIAttachmentStorage.resolve(storageName) }

    /// 人类可读的大小（1.2 MB / 340 KB），同 `AIDocumentItem.sizeText`
    public var sizeText: String { ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file) }

    /// 扩展名（大写，给行首那枚角标用）；无扩展名给空串
    public var fileExtension: String { (fileURL?.pathExtension ?? "").uppercased() }
}

public enum AIRole {
    case user
    case assistant
}

// MARK: - 扁平行（UITableView 用）

/// 把 turns 摊平成行：每一块占一行，记录所属 turn 的 role 与是否为该 turn 首块
public struct AIChatRow: Identifiable {
    public let id: UUID
    public let role: AIRole
    /// 注意：流式过程中需要原地修改 block.text，因此用 var
    public var block: AIBlock
    public let isFirstBlockOfTurn: Bool
    /// 行高缓存（UI 概念，但挂在行上最稳）。
    /// AIChatRow 是 struct，VC 取 rows[i] 是拷贝、改字段无法回写，
    /// 因此统一经 AIChatManager 的 mutating 方法读写；key 即稳定的 id。
    public var cachedHeight: CGFloat? = nil
    /// 是否在这条气泡下方显示横排操作栏（内容见 `AIRowAction.barActions`）。
    ///
    /// 纯视图状态、不入库**：恢复会话时由 `AIChatManager` 重算：当前只挂「当前会话里
    /// 最后一条已结束的文本回复」，历史消息一律靠长按操作卡 —— 与豆包/ChatGPT 的做法一致
    /// （省空间、降噪）。判定逻辑全在 `AIChatManager.applyActionBarFlags()`。
    public var showsActionBar: Bool = false

    /// 思考块是否展开（无 `block.reasoning` 时无意义）。
    ///
    /// **纯视图状态、不入库**（恢复会话一律 `false` = 折叠）：
    /// - 流式中**自动展开**（`AIChatManager.handle(.reasoning)` 置位）；
    /// - 收尾时折叠成一行（`finalizeStreamingText` 复位）；
    /// - 之后用户点那行切换（经 `AIChatManager.setThinkingExpanded`，行高在那里重算）。
    public var isThinkingExpanded: Bool = false

    /// 这一条消息的创建时间。
    ///
    /// ⚠️ 从库里恢复时**必须沿用落库时间**（`AIChatStore.loadConversation`）：
    /// 时间戳既用于显示，也用于「和上一条隔了多久 → 要不要报时间」的判定。
    /// 恢复时若取当前时间，一整段历史都会挤成同一秒 —— 分隔线全没了。
    public var createdAt: Date = Date()

    /// 气泡上方那行小字的**最终文案**（`nil` = 这一行不显示小字）。
    ///
    /// **只有时间** —— 聊天页不显示 token 用量（2026-09-17 已把操作栏右侧那条累计文案撤掉，
    /// 用量只在设置页「用量与计费」里看）。存**成品字符串**而不是
    /// 「要不要显示」的布尔：文案由「与上一条隔了多久」决定，而这件事只有算的那一方
    /// （`AIChatManager.applyMetaFlags`，它手里有上一条的时间）知道。若这里只存一个 bool，
    /// 模型就得再拼一次文案，两边算法迟早漂移。
    ///
    /// **纯视图状态、不入库**：恢复会话后由 `AIChatManager` 重算。
    public var metaText: String? = nil

    /// 显式 `public` 构造（成员初始化器默认只有 internal 级别，跨 module 用不了）。
    ///
    /// 跨 module 造行的场景：两个 DEBUG 探针都要造行落库才能构造出目标态 ——
    /// iOS `SceneDelegate` 的 missed-round 探针（「5 分钟前的完整助手回复」）与
    /// thinking 探针（「带 reasoning 的助手行」，2026-10-21）。
    /// ⚠️ 与成员初始化器**逐字段对应** —— 加字段时两边一起加，否则探针会静默漏字段。
    public init(id: UUID = UUID(),
                role: AIRole,
                block: AIBlock,
                isFirstBlockOfTurn: Bool,
                cachedHeight: CGFloat? = nil,
                showsActionBar: Bool = false,
                createdAt: Date = Date(),
                metaText: String? = nil,
                isThinkingExpanded: Bool = false) {
        self.id = id
        self.role = role
        self.block = block
        self.isFirstBlockOfTurn = isFirstBlockOfTurn
        self.cachedHeight = cachedHeight
        self.showsActionBar = showsActionBar
        self.createdAt = createdAt
        self.metaText = metaText
        self.isThinkingExpanded = isThinkingExpanded
    }

    // ⚠️ 这里曾经有一个 `barUsageText`（操作栏右侧的「本会话累计」文案），2026-09-17 已删除：
    // 聊天页（iOS）至今不显示任何 token 数字。落库的 `block.usage` 仍然在（它是用量的唯一数据源，
    // 设置页的累计统计就靠它）。
    // 📌 2026-10-25 傍晚 Mac 侧短暂显示过单次用量（`ChatRowActionBar` 栏尾「共消耗 ✦ 1,574」），
    // **当天就被用户要求隐藏** ⇒ 两端现在都不显示。真要恢复只看 `ChatRowActionBar` 文件头，
    // ⛔ 别因此给 iOS 侧加行高（`metaHeight` 只管时间小字，见下）。
}

// MARK: - 行高量算（数据返回时由 AIChatManager 算好存 cachedHeight，heightForRowAt 直接读取）

extension AIChatRow {
    /// 操作栏占用的额外行高。**与 `AIActionBarView` 的显示高度同源**：
    /// 量行高时不加它 → 栏出现后气泡被挤变形/最后一行被裁。
    /// 构成 = 气泡与按钮底之间的留白（`AIActionBarView.topPadding`，5）
    ///      + 按钮底边长（`AIActionBarView.chipSize`，30）。
    /// 改任一项都要保持这个等式，否则末行被裁。
    public static let actionBarHeight: CGFloat = 35

    /// 「时间」小字行的高度（两端都不显示用量，这一行只报时间）。
    ///
    /// ⚠️ **量行高与 cell 布局必须同源**：`AIChatModels.height(in:)` 用 `metaHeightOrZero` 累加，
    /// `AIAssistantTextCell` / `AIUserTextCell` 里 metaLabel 的约束高度取的就是这个值。
    /// 两边写成不同数字 → 不是小字被裁、就是气泡被顶下去留一段空白。
    public static let metaHeight: CGFloat = 20

    /// 系统提示行（`.modelSwitch`）的**上下留白**。
    ///
    /// 🔴 **量行高与两端 cell 布局共用这一份**（iOS `AISystemNoticeCell` 的上下约束、
    ///    Mac `ChatRowView.noticeBlock` 的 `.padding(.vertical)`）—— 写成两个数字
    ///    就是本工程行高错乱的头号来源（「量 A 布局 B」）。
    /// 取 6 而不是气泡那套 12：它**没有气泡**（见下），只是一行居中灰字，
    /// 留白给大了会在两轮对话之间鼓出一块空白。
    public static let noticeRowPaddingV: CGFloat = 6

    /// 小字行实际占的高度（不显示时为 0）。判定口径**只看 `metaText`** ——
    /// cell 也是按「metaText 是不是 nil」决定显隐的，两处同一口径才不会出现
    /// 「高度留了、字没画」或反之。
    public var metaHeightOrZero: CGFloat { metaText == nil ? 0 : Self.metaHeight }

    /// 气泡**内部**上方那条引用条的高度（无引用时为 0）。
    ///
    /// ⚠️ 这类「气泡外/内多出来的一条」是本工程行高错乱的头号来源：
    /// 量高时不加它、cell 布局加了它 → 气泡被裁；反之则底部空一段。
    /// 所以两边都只能取 `quoteHeightOrZero` / `quoteHeight` 这一份定义（同 `metaHeight` 的做法）。
    /// 取值 42 = 引用条内容高（一行名字 14 + 一行摘要 16 + 上下内边距 6+6）。
    public static let quoteHeight: CGFloat = 42

    /// 引用条实际占的高度（判定口径只看 `block.quote`，与 cell 里「quote 为 nil 就整条不画」同源）。
    /// 只有文本行会有引用条（引用是「针对某段文字提问」，图片/文件行没有可引用的正文）。
    public var quoteHeightOrZero: CGFloat {
        (block.kind == .text && block.quote != nil) ? Self.quoteHeight : 0
    }

    /// 思考块实际占的高度（判定口径 = 有 reasoning + 展示总闸开着，与 cell 里「画不画」同源）。
    ///
    /// ⚠️ 只给**助手文本行**：思考挂在助手回复上，用户行 / 图片行 / 视频行都没有。
    /// ⚠️ 尺寸全部走 `AIThinkingBlockMetrics`（量高与显示同源，⛔ 别在这里写数字）——
    ///    总闸 `AIGenerationSettings.showsThinkingProcess` 关着时算 0，cell 那边同样不画。
    public func thinkingHeightOrZero(in textWidth: CGFloat) -> CGFloat {
        guard role == .assistant, block.kind == .text,
              let reasoning = block.reasoning, !reasoning.isEmpty,
              AIGenerationSettings.showsThinkingProcess else { return 0 }
        return AIThinkingBlockMetrics.height(for: reasoning.text,
                                             width: textWidth,
                                             expanded: isThinkingExpanded)
    }

    // MARK: - 助手侧「媒体横滑条」的尺寸（2026-09-28 加，iOS / Mac 共用一份）

    /// 横滑条里一个格子的**高**（竖版 9:16 —— 用户 2026-09-28：「图片数据竖着显示」）。
    ///
    /// 🔴 **这是「一条横滑条多高」的唯一出处**：iOS 的 `height(in:)` 与 `AIAssistantMediaStripCell`
    /// 的约束、Mac 的 `MacTheme.mediaThumbHeight` 全都取它。⛔ 别在任何地方再写一个 192 ——
    /// 「量的时候按 A、布局按 B」是本工程行高错乱的头号来源（与 `userImageDisplaySize` 同一课）。
    public static let mediaStripThumbHeight: CGFloat = 192

    /// 格子宽 = 高 × 9/16（正好 108，整数 ⇒ 不出半像素毛边）。
    public static let mediaStripThumbWidth: CGFloat = mediaStripThumbHeight * 9 / 16

    /// 格子间距（8 与输入栏附件条同档 —— 同一类「小图并排」的观感）。
    public static let mediaStripSpacing: CGFloat = 8

    /// 视频格上那颗播放图标。它只是「这里能播」的提示，**不是命中区**（整格可点）。
    public static let mediaStripPlayIconSize: CGFloat = 26

    /// 一条横滑条占的行高 = 格子高 + 上下留白 12（与图片行原来那笔 `+12` 同一口径）。
    ///
    /// ☠️ 这里给的是**组首那一行**的高度。同组其余行由 `AIChatManager.normalizeMediaGroupHeights()`
    /// **归零** —— 「一行多高」在全工程里第一次取决于**邻居**（`height(in:)` 只看得到自己），
    /// 所以那个归零动作必须由拿到整个 `rows` 的 `AIChatManager` 统一做，⛔ 别试图在行内解决。
    public static var mediaStripRowHeight: CGFloat { mediaStripThumbHeight + 12 }

    /// 行高：文本用 boundingRect（流式态走 `AITypography.body` 纯文本；助手终态按 Markdown
    /// **分段**累加，文本段 + 代码卡片）；图片/视频固定 16:9。口径与 cell 实际布局一致。
    /// ⚠️ 字号**必须**取 `AITypography`：cell 显示与这里量算用的是同一份值，写死数字迟早对不上
    /// （量的时候按 16、显示按 17 → 高度不够，最后一行被裁）。
    /// - Parameter width: 容器宽度（通常为屏宽），由 AIChatManager.contentWidth 传入。
    public func height(in width: CGFloat) -> CGFloat {
        // 气泡自己的上下 inset（6+6）。**内容**的上下留白不在这里，它由
        // `AIMarkdown.contentPaddingV` 承担（cell 那边是 `contentStack` 的上下约束）——
        // 2026-09-18 换成分段渲染时这笔账只是从 `textView.textContainerInset` 搬到 stack 上，
        // 总量没变，所以单段文本的行高与从前完全一致。
        let bubbleInsetV: CGFloat = 12
        // 操作栏是气泡**外面**多出来的一条，必须计入行高（当前只会挂在文本行上，其余分支保留不累加）
        let barH: CGFloat = showsActionBar ? Self.actionBarHeight : 0
        // 「时间」小字行同理：它在气泡**上方**，也是气泡外多出来的一条
        let metaH = metaHeightOrZero
        // 引用条在**气泡内部**上方（用户气泡），同样必须计入行高
        let quoteH = quoteHeightOrZero
        switch block.kind {
        case .text:
            let maxTextW = width * 0.8 - 24   // 气泡宽 0.8×屏宽，减正文左右 inset(12+12)
            let font = AITypography.body
            let contentH: CGFloat
            if !block.isStreaming, role == .assistant {
                // 终态：按**分段**累加（每段文本 + 每个代码卡片），
                // 与 cell 的 `contentStack` 逐项同源（同源点全在 `AIMarkdown.contentHeight` 里）
                contentH = AIMarkdown.contentHeight(from: block.text, width: maxTextW)
            } else {
                // 流式态（纯文本）与用户消息：单段文本
                let textH = (block.text as NSString).boundingRect(
                    with: CGSize(width: maxTextW, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font], context: nil).height
                contentH = ceil(max(textH, font.aiLineHeight)) + AIMarkdown.contentPaddingV * 2
            }
            // 思考块在气泡内部、正文**上方**（助手气泡）：量高不加它 ⇒ 正文被顶出气泡 / 末行被裁。
            // 宽度直接复用本分支的 `maxTextW`（⛔ 别把 `width * 0.8 - 24` 再抄一遍）
            let thinkingH = role == .assistant ? thinkingHeightOrZero(in: maxTextW) : 0
            return contentH + thinkingH + bubbleInsetV + 1 + barH + metaH + quoteH   // +1 容差防裁切
        case .error:
            // 失败提示：cell 用 `AITypography.notice` 纯文本渲染（不走 Markdown），量算口径必须
            // 与之一致；提示里带换行（首行原因 + 次行怎么做），boundingRect 会算进去
            let maxTextW = width * 0.8 - 24
            let font = AITypography.notice
            let noticeH = (block.text as NSString).boundingRect(
                with: CGSize(width: maxTextW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil).height
            return ceil(max(noticeH, font.aiLineHeight)) + AIMarkdown.contentPaddingV * 2 + bubbleInsetV + 1
        case .modelSwitch:
            // 模型切换系统消息（2026-10-21）：**没有气泡**，一行居中灰字。
            // ⇒ 既不加 `bubbleInsetV` 也不加 `contentPaddingV`（那两笔都是气泡的账），
            //   只有 `noticeRowPaddingV` 这一份（与两端 cell 同源）。
            // 文案现取 `modelSwitchText`（`L()` 不能被缓存 ⇒ 切语言后高度跟着重算）。
            // 宽度取满宽减 24 = 两端 cell 的左右约束（12+12），与量算同一口径。
            let maxTextW = width - 24
            let font = AITypography.notice
            let noticeH = (block.modelSwitchText as NSString).boundingRect(
                with: CGSize(width: maxTextW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font], context: nil).height
            return ceil(max(noticeH, font.aiLineHeight)) + Self.noticeRowPaddingV * 2
        case .file:
            // 用户文件卡片：固定内容高 + 上下留白 6+6
            return Self.userFileCardHeight + 12
        case .image:
            // 用户发出的图片按**真实宽高比**算（右侧气泡）
            if role == .user {
                // 🔴 2026-10-09：单张仍是**原尺寸**（`scale` 默认 1），一图一行。
                //    「多张横排 + 缩小」那笔账**不在这里算** —— `height(in:)`只看得到
                //    **自己这一行**，看不到同组还有几张 ⇒ 组首那一行的高度必须由拿得到
                //    整个 `rows` 的 `AIChatManager.normalizeMediaGroupHeights()` 来写
                //    （见 `userImageGroupRowHeight`）。⛔ 别在这里按「猜到的张数」乘系数，
                //    那会让行高与渲染分叉（这里算 A、cell 布局按 B）。
                return ceil(Self.userImageDisplaySize(in: width, mediaSize: block.mediaSize).height) + 12
            }
            // 助手侧：一条**竖版 9:16 的横滑条**（2026-09-28 由「0.66×屏宽 的 16:9」改），
            // 高与宽度无关 ⇒ 窗口/屏幕变宽时格子不变、只是多露出几格。
            // ⚠️ 只有**组首**是这么高，同组其余行会被归零（见 `mediaStripRowHeight` 的注释）。
            return Self.mediaStripRowHeight
        case .video:
            // 助手侧视频与图片同口径（同一组尺寸、同一条横滑条形态）。
            // ⚠️ 用户不会发视频（只有 `.image` / `.file`），所以这里没有 `role` 分支 ——
            // 真出现了也按助手口径渲染，比给个 0 高好。
            return Self.mediaStripRowHeight
        }
    }

    // MARK: - 用户附件的尺寸常量

    /// 用户图片的最大展示宽度（占容器宽比例）
    public static let userMediaWidthRatio: CGFloat = 0.62
    /// 用户图片的最大展示高度（占容器宽比例）——超长图不至于占满一屏
    public static let userMediaHeightRatio: CGFloat = 0.72
    /// 用户文件卡片的内容高度（不含气泡上下留白）
    public static let userFileCardHeight: CGFloat = 68

    /// 用户图片的展示尺寸。
    ///
    /// ⚠️ **这是用户图片尺寸的唯一真值**：`height(in:)` 取它的 height，`AIUserImageCell`
    /// 取它的 width/height。任何一边自己再算一次（比如 cell 里写 `width * 0.62`），
    /// 都会演变成「量的时候按 A、布局按 B」→ 图片被裁或被留白撑开。
    ///
    /// 逻辑：先按最大宽度铺满，超出最大高度就**反向收窄宽度**（等比缩放而不是压扁）。
    /// 无尺寸信息时退回 16:9 —— 总比 0 高强。
    ///
    /// 🔴 `scale` = **整档尺寸的缩放系数**（2026-10-08 加，默认 1 = 两端同大）。
    /// Mac 2026-10-08 明确「只有 Mac 的用户图要小一点」，而本函数是 iOS/Mac 共享的
    /// 唯一真值 ⇒⛔ 别在 Mac 视图层自己乘一遍（那正是上面警告的「量 A 布局 B」）；
    /// 要改就从这里传系数，**同一个值同时喂给渲染与行高**。
    /// ⚠️ 2026-10-09 起 iOS **多图**那一档也会传系数（`userImageStripScale`），
    ///   但 **iOS 单张仍传默认 1** —— 用户明确「单张的图片大小不变」。
    public static func userImageDisplaySize(in width: CGFloat,
                                             mediaSize: CGSize?,
                                             scale: CGFloat = 1.0) -> CGSize {
        let k = max(scale, 0.05)
        let maxW = width * userMediaWidthRatio * k
        let maxH = width * userMediaHeightRatio * k
        guard let size = mediaSize, size.width > 0, size.height > 0 else {
            return CGSize(width: floor(maxW), height: floor(maxW * 9.0 / 16.0))
        }
        let ratio = size.height / size.width
        var w = maxW
        var h = w * ratio
        if h > maxH {
            h = maxH
            w = h / ratio
        }
        return CGSize(width: floor(w), height: floor(h))
    }

    // MARK: - 用户多图横排（2026-10-09，iOS + Mac 共用这组口径）

    /// 「同一次发送里的多张用户图」横排时，每一格的缩放系数。
    ///
    /// 🔴 **只有多张才缩小**（用户原话：「多个图片…要缩小现在的 1/4，单张的图片大小不变」）。
    /// ⇒ 判据在调用点（组内张数 > 1），⛔ 别把这个系数塞进 `userImageDisplaySize` 的默认值 ——
    /// 那会让**单张**也跟着变小，直接违背用户要求。
    ///
    /// ⚠️ 调档史：**0.25 → 0.5**（2026-10-09 用户实机看后「感觉图片有点小了，
    /// 以现在标准增加一倍大小」）。⚠️ 改这里要同步改三处判据，否则**红灯但功能是对的**：
    /// `typecheck_aster.sh` 的 `userImageStripScale: CGFloat = 0\.(25|50)` 契约行、
    /// `probe_user_image_group.sh` 里那条「多图档 ≈ 单张的 1/N」判据（连容差一起改，
    /// 容差 = N−1，`userImageDisplaySize` 内部 `floor`）。
    ///
    /// ⚠️ 与 Mac 的 `MacTheme.userImageScale`（当前 0.25）**不是同一个东西**：
    /// 那一档 Mac 是**无条件**生效（单张也小，用户 10-08 亲手调的），这里只在多张时生效。
    /// 哪天用户要求「Mac 单张也回到原尺寸」，改的应该是 Mac 那个常数，不是这个。
    public static let userImageStripScale: CGFloat = 0.5

    /// 用户多图横排：格与格之间的间距。
    /// 取 8 —— 与助手侧缩略图条、输入栏附件条**同一档**（`mediaStripSpacing`）。
    public static let userImageStripSpacing: CGFloat = mediaStripSpacing

    /// 用户多图横排**占的行高** = 组内最高那一格 + 上下留白 12（与单张那笔 `+12` 同口径）。
    ///
    /// 🔴 这是**组首那一行**的高度，也是这条横排在界面上的唯一高度真值：
    /// iOS 的 `AIUserImageStripCell` 与 Mac 的 `UserImageStrip` 都必须**正好**凑出它
    /// （同 `mediaStripRowHeight` 对 `AIAssistantMediaStripCell` 的关系 ——
    /// 「量的时候按 A、布局按 B」会把下面的消息顶歪或把图裁掉一截）。
    ///
    /// - Parameters:
    ///   - rows: **整组**用户图片行（`userImageGroupRows`，⛔ 不是单行）。
    ///   - width: 容器宽（`AIChatManager.contentWidth`）。
    ///   - scale: 每格的缩放系数。多张传 `userImageStripScale`，单张传 1。
    public static func userImageGroupRowHeight(rows: [AIChatRow],
                                                in width: CGFloat,
                                                scale: CGFloat) -> CGFloat {
        let tallest = rows
            .map { userImageDisplaySize(in: width, mediaSize: $0.block.mediaSize, scale: scale).height }
            .max() ?? 0
        return ceil(tallest) + 12
    }
}
