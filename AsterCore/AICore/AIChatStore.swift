//
//  AIChatStore.swift
//  AIModule
//
//  AI 会话的持久化仓库（SQLite）。
//
//  职责边界：
//  - 只做「模型 ↔ 行」的映射与 SQL 执行，不含任何 UI / 流式逻辑；
//  - 上层（AIChatManager）只调用下面的语义化方法，不感知表名与列名；
//  - 落库时机由 AIChatManager 控制（首条消息建会话、助手行占位 + 结束时更新文本），
//    本类不主动在流式过程中写入。
//
//  与 BaseModule 的 BrowseHistoryManager 同构：建表 → 按表版本迁移 → 索引 → 增删查改，
//  共用 SQLiteManager.shared 的连接与串行队列（同一 db.sqlite3，靠 `_migrations` 按表记版本）。
//

import Foundation
import SQLite

// 与 SQLiteManager 同理：工程内存在同名的 Expression，需显式指定来自 SQLite
import struct SQLite.Expression
import StarryKitCore

public final class AIChatStore {

    public static let shared = AIChatStore()

    private init() {}

    // MARK: - 常量

    private let conversationTableName = "ai_conversation"
    private let messageTableName = "ai_message"

    /// token 用量表。
    ///
    /// **为什么不给消息表加列**：`getTable` 是 `CREATE TABLE IF NOT EXISTS`，已存在的表
    /// **不会补列**，而版本号又可能与真实结构不一致 —— 这个坑本项目踩过两次
    /// （补列被跳过 → 读列时 Fatal）。加一张新表则是纯新增路径：老库打开就是建表 + 空表，
    /// 零迁移风险。用量与消息是 1:1（主键就是消息 id），拆表也不会带来连接成本。
    private let usageTableName = "ai_usage"

    /// 引用表（主键 = 发出引用的那条**用户消息** id，与该消息 1:1）。
    ///
    /// 与用量表同样的理由：新开一张表，而不是给 `ai_message` 加 `quoted_id` / `quoted_text` 两列。
    /// 老库打开时这就是一次 `CREATE TABLE IF NOT EXISTS` + 空表，**不需要任何补列脚本**。
    /// 被引用的正文以**快照**存（见 `AIQuote` 的注释），因此这条记录不依赖被引用那条消息的存活。
    private let quoteTableName = "ai_quote"

    /// 思考过程表（主键 = **助手消息** id，与该消息 1:1）。
    ///
    /// 与用量表 / 引用表同样的理由：新开一张表，而不是给 `ai_message` 加 `reasoning` 列。
    /// 老库打开时这就是一次 `CREATE TABLE IF NOT EXISTS` + 空表，零迁移风险。
    /// 只有推理模型的回复会有这一行；正文为空被改成失败提示的行不写（见 `finalizeMessage`）。
    private let reasoningTableName = "ai_reasoning"

    /// 项目表（会话的「文件夹」容器，2026-10-21）。
    ///
    /// 纯新增路径：老库打开就是建表 + 空表，零迁移风险（同 `usageTableName` 的理由）。
    /// 项目是**业务数据**（要重命名 / 删除 / 带资料与指令）⇒ ⛔ 不能学置顶存 UserDefaults。
    private let projectTableName = "ai_conversation_project"

    /// 项目资料表（挂在项目下的文件，2026-10-21）。
    ///
    /// 同样是纯新增。存储形态与消息文件块同源（`storage_name` 走 `AIAttachmentStorage`），
    /// 独立成表而不是给消息表加列 —— 项目资料**不属于任何一条消息**（会话可反复引用）。
    private let projectFileTableName = "ai_conversation_project_file"

    /// `@` 进来的项目资料表（一条消息 → N 份资料，2026-10-21）。
    ///
    /// 与 `ai_quote` 的**关键区别**：引用是「一条消息最多一个」（主键 = message_id），
    /// 而 @ 是「一条消息可以有好几个」⇒ 主键不能只放 message_id。
    /// 这里用 `id`（= `messageId#序号`）当主键、`message_id` 单独一列并建索引：
    /// 主键保证幂等覆盖（`or: .replace`），索引保证「载入一个会话」仍是一次查询。
    /// ⚠️ 别改成「复合主键（message_id + idx）」：`getTable` 那套 builder 只认单列主键，
    /// 而多写一个 `primaryKey: true` 不会报错、只会静静地只生效一个。
    private let mentionTableName = "ai_mention"

    /// 模型切换系统消息表（主键 = 那条系统消息自己的 id，1:1，2026-10-21）。
    ///
    /// 纯新增路径：老库打开就是建表 + 空表，零迁移风险（同 `usageTableName` 的理由）。
    /// 存的是「从哪切到哪」的**结构化快照**（含那一刻的显示名）—— 两条显示规则
    /// （切回去 ⇒ 撤销；又切第三个 ⇒ 改写）都要拿它比对，见 `AIModelSwitch` 文件头。
    /// ⚠️ 渲染文案**同时**写在 `ai_message.text`（kind 5）里，表丢了只是「规则失效」，
    ///    那条流水还在（`AIBlock.modelSwitchText` 会现算一份）。
    private let modelSwitchTableName = "ai_model_switch"

    /// 项目资料分块表（RAG 检索索引，2026-10-23）。
    ///
    /// 纯新增路径（同 `usageTableName`）：老库打开就是建表 + 空表，零迁移风险。
    /// 存的是项目资料文件的**检索片段**（chunk）—— 派生物，不是真值：
    /// 磁盘上那份文件才是真值，任何时刻都能整表重建（`rebuildProjectIndex`）。
    /// ⚠️ 与 `ai_mention` 的关键区别：那张表的行跟**消息**走（删消息就没了）；
    ///    本表的行跟**资料**走（资料进了项目才建，资料删了才清）。
    private let chunkTableName = "ai_project_file_chunk"

    /// 当前 schema 目标版本号
    /// - v1: 初始版本（会话 + 消息两表）
    /// - v2: 置顶状态改由 UserDefaults 维护（`pinnedKey`），不再用表字段。
    ///       表结构本身无变化，此版本仅作记录，避免老库反向降级
    /// - v3: 新增 `ai_quote` 表（引用回复）。**纯新增**：建表语句本身就是迁移，
    ///       没有任何补列脚本要跑，所以这里的推进只是把版本号记准
    /// - v4: **数据修复**（非结构变更）：把 `message_count` 曾被写成 TEXT 的脏行修回来。
    ///       成因见 `clampedCount(delta:)` 的坑 1 —— 那一版自引用更新表达式被
    ///       SQLite.swift 当标识符加了双引号，SQLite 又按「双引号兜底为字符串」存成了
    ///       `'MAX(0, message_count + N)'`。读回来时 `row[cMessageCount]` 是 `try!`，
    ///       解不出 Int 直接 Fatal（实测崩在 `fetchSummaries()`）。
    /// - v5: 新增 `ai_reasoning` 表（思考过程展示，2026-10-20）。**纯新增**：建表语句本身就是
    ///       迁移，没有任何补列脚本要跑，所以这里的推进只是把版本号记准
    /// - v6: 项目（文件夹）能力（2026-10-21）：新增 `ai_conversation_project` /
    ///       `ai_conversation_project_file` 两张表（**纯新增**，建表即迁移），
    ///       外加 `ai_conversation` 补 `project_id` 可空列（**唯一要 ALTER 的老表**，
    ///       走「结构探测 + 幂等 ALTER」，见 `runMigrations` 的 v6 段）。
    /// - v7: 新增 `ai_mention` 表（输入框 `@` 项目资料，2026-10-21）。**纯新增**：
    ///       建表语句本身就是迁移，没有任何补列脚本要跑。
    /// - v8: 新增 `ai_model_switch` 表（切换模型的居中系统消息，2026-10-21）。
    ///       **纯新增**：建表语句本身就是迁移，没有任何补列脚本要跑
    ///       （同 v3 / v5 / v7 三条先例，`runMigrations` 里不需要为它写任何分支）。
    /// - v9: 新增 `ai_project_file_chunk` 表（项目资料检索索引，2026-10-23）。
    ///       **纯新增**：建表语句本身就是迁移，`runMigrations` 不需要为它写任何分支
    ///       （同 v3 / v5 / v7 / v8 四条先例）。⚠️ 别给 `ai_conversation_project_file`
    ///       加列记「索引状态」—— 那是本工程踩过两次的老坑，状态一律现算（见
    ///       `projectIndexStatus`）。
    /// - v10: **消灭「未归类」**（2026-10-25）：默认项目容器「任务」上位。
    ///       两部分：① `ensureDefaultProject()` 保证默认项目存在（幂等，固定 id，
    ///       且**每次启动都跑**——见 runMigrations 开头，不是一次性迁移）；
    ///       ② 存量 `project_id IS NULL` 的会话行全部写进默认项目。
    ///       结构零变更（v6 的列继续用），纯粹数据迁移。
    private let schemaVersion = 10

    /// 上次打开的会话 id（存 UserDefaults：轻量、无额外依赖；换存储只改这一处）
    private let lastActiveKey = "ai_chat_last_active_conversation_id"

    /// 置顶会话 id 集合。
    ///
    /// **为什么不存表字段**：置顶是「视图偏好」而非业务数据，量小（几个 id）、读写频繁、
    /// 且不该受表结构迁移影响（曾因 `is_pinned` 列补不上导致功能静默失效）。
    /// 放 UserDefaults 后无需任何列探测/迁移，功能与表结构解耦。
    private let pinnedKey = "ai_chat_pinned_conversation_ids"

    // MARK: - 列定义（会话）

    private let cId = Expression<String>("id")
    private let cTitle = Expression<String>("title")
    private let cCreatedAt = Expression<Double>("created_at")
    private let cUpdatedAt = Expression<Double>("updated_at")
    private let cMessageCount = Expression<Int>("message_count")
    /// 所属项目 id（v6 补列，读时必须用可抛版兜底）。2026-10-25 起「未归类」已消灭：
    /// 列仍可空（老库结构不动），但正常路径恒非 nil —— v10 迁移把存量 NULL 行
    /// 写进了默认项目「任务」，读出的兜底值也是它。
    private let cProjectId = Expression<String?>("project_id")

    // MARK: - 列定义（消息）

    private let mId = Expression<String>("id")
    private let mConversationId = Expression<String>("conversation_id")
    /// 会话内的顺序号（保证恢复到列表时顺序与发送时一致）
    private let mSeq = Expression<Int>("seq")
    private let mRole = Expression<Int>("role")
    private let mKind = Expression<Int>("kind")
    private let mText = Expression<String>("text")
    private let mImageURL = Expression<String?>("image_url")
    private let mVideoURL = Expression<String?>("video_url")
    private let mVideoCoverURL = Expression<String?>("video_cover_url")
    private let mCreatedAt = Expression<Double>("created_at")

    private let conversations = Table("ai_conversation")
    private let messages = Table("ai_message")

    // MARK: - 列定义（用量）

    private let uMessageId = Expression<String>("message_id")
    private let uConversationId = Expression<String>("conversation_id")
    private let uPromptTokens = Expression<Int>("prompt_tokens")
    private let uCompletionTokens = Expression<Int>("completion_tokens")
    private let uTotalTokens = Expression<Int>("total_tokens")
    /// 可空：只有 DeepSeek 会给输入侧的缓存命中 / 未命中拆分
    private let uCacheHitTokens = Expression<Int?>("cache_hit_tokens")
    private let uCacheMissTokens = Expression<Int?>("cache_miss_tokens")
    private let uCreatedAt = Expression<Double>("created_at")

    private let usages = Table("ai_usage")

    // MARK: - 列定义（引用）

    private let qMessageId = Expression<String>("message_id")
    private let qConversationId = Expression<String>("conversation_id")
    private let qQuotedMessageId = Expression<String>("quoted_message_id")
    private let qQuotedRole = Expression<Int>("quoted_role")
    private let qQuotedText = Expression<String>("quoted_text")
    private let qCreatedAt = Expression<Double>("created_at")

    private let quotes = Table("ai_quote")

    // MARK: - 列定义（思考）

    private let gMessageId = Expression<String>("message_id")
    private let gConversationId = Expression<String>("conversation_id")
    private let gText = Expression<String>("text")
    /// 思考耗时（秒）。0 = 未知（重启前被杀 / 老数据）—— 读回来按「没有耗时」处理
    private let gDuration = Expression<Double>("duration")
    private let gCreatedAt = Expression<Double>("created_at")

    private let reasonings = Table("ai_reasoning")

    // MARK: - 列定义（项目）

    private let pId = Expression<String>("id")
    private let pName = Expression<String>("name")
    /// 项目级系统提示词。**空字符串 = 回落全局**（与 `AIGenerationSettings.systemPrompt`
    /// 的「空 = 不发」同一套口径；不用 NULL 是为了读写都不必分两支）
    private let pInstruction = Expression<String>("instruction")
    private let pSortOrder = Expression<Int>("sort_order")
    private let pCreatedAt = Expression<Double>("created_at")

    private let projects = Table("ai_conversation_project")

    // MARK: - 列定义（项目资料）

    private let pfId = Expression<String>("id")
    private let pfProjectId = Expression<String>("project_id")
    private let pfName = Expression<String>("name")
    /// `AIAttachmentStorage` 的存储标识（⛔ 不是绝对路径 —— 沙盒容器路径会变）
    private let pfStorage = Expression<String>("storage_name")
    private let pfSize = Expression<Int64>("byte_size")
    private let pfCreatedAt = Expression<Double>("created_at")

    private let projectFiles = Table("ai_conversation_project_file")

    // MARK: - 列定义（@ 项目资料）

    /// 主键 = `"<messageId>#<序号>"`（见 `mentionTableName` 的说明：一条消息可以有多份）
    private let nId = Expression<String>("id")
    private let nMessageId = Expression<String>("message_id")
    private let nConversationId = Expression<String>("conversation_id")
    /// 同一份消息里的第几份（0 起）。**只用于还原顺序** —— 用户先 @ 哪份、后 @ 哪份，
    /// 注入上下文时也按这个顺序，模型读到的材料顺序才与界面上待发条一致
    private let nIndex = Expression<Int>("idx")
    private let nMentionFileId = Expression<String>("project_file_id")
    private let nMentionName = Expression<String>("display_name")
    private let nMentionStorage = Expression<String>("storage_name")
    private let nMentionSize = Expression<Int64>("byte_size")
    private let nCreatedAt = Expression<Double>("created_at")

    private let mentions = Table("ai_mention")

    // MARK: - 列定义（模型切换系统消息）

    /// 主键 = 那条系统消息自己的 id（与 `ai_message` 1:1，`or: .replace` 覆盖）
    private let sMessageId = Expression<String>("message_id")
    private let sConversationId = Expression<String>("conversation_id")
    /// 切换**前**的模型 id。`let` 语义：两条规则都不改它
    private let sFromId = Expression<String>("from_id")
    /// 切换**后**的模型 id。规则「A→B 又切 C ⇒ 只显示 A→C」会就地改它
    private let sToId = Expression<String>("to_id")
    /// 切换那一刻的显示名**快照**（用户之后改模型名不该污染历史，同 `ai_quote` 存正文快照的理由）
    private let sFromName = Expression<String>("from_name")
    private let sToName = Expression<String>("to_name")
    private let sCreatedAt = Expression<Double>("created_at")

    private let modelSwitches = Table("ai_model_switch")

    // MARK: - 列定义（项目资料检索片段，v9）

    private let chId = Expression<String>("id")
    private let chProjectId = Expression<String>("project_id")
    private let chFileId = Expression<String>("file_id")
    /// 文件内的第几块（0 起）。**不是主键** —— 主键是自造的 UUID，
    /// 因为同一文件的同一序号在建索引失败重跑时会被替换（`replaceFileChunks`）
    private let chIndex = Expression<Int>("chunk_index")
    private let chText = Expression<String>("text")
    private let chCharCount = Expression<Int>("char_count")
    private let chCreatedAt = Expression<Double>("created_at")

    private let chunks = Table("ai_project_file_chunk")

    /// 建表/迁移是否已完成（`ready` 的只读出口）。
    ///
    /// 给 `AIMissedRoundReconciler` 用：它要在回前台时查库对账，而 store 没就绪时
    /// `loadConversation` 与「会话被删」一样返回 nil —— 两者必须能分开
    /// （前者留账下次再对，后者直接清账）。
    public var isReady: Bool { ready }

    // MARK: - 建表 / 迁移 / 索引

    /// 惰性建表（首次访问时创建）+ 迁移 + 索引。
    /// 失败时返回 false，所有读写降级为空操作（不影响 UI 主流程）。
    ///
    /// `_ =` 是为了吞掉 `getTable` 的返回值（它返回 Table，我们只关心**副作用**：
    /// 表不存在就建）。不写会有 3 条 `result of call ... is unused` 警告常年挂在编译输出里，
    /// 把真正需要看见的新警告淹掉。
    private lazy var ready: Bool = {
        do {
            _ = try SQLiteManager.shared.getTable(conversationTableName) { builder in
                builder.column(self.cId, primaryKey: true)
                builder.column(self.cTitle)
                builder.column(self.cCreatedAt)
                builder.column(self.cUpdatedAt)
                builder.column(self.cMessageCount)
            }
            _ = try SQLiteManager.shared.getTable(messageTableName) { builder in
                builder.column(self.mId, primaryKey: true)
                builder.column(self.mConversationId)
                builder.column(self.mSeq)
                builder.column(self.mRole)
                builder.column(self.mKind)
                builder.column(self.mText)
                builder.column(self.mImageURL)
                builder.column(self.mVideoURL)
                builder.column(self.mVideoCoverURL)
                builder.column(self.mCreatedAt)
            }
            // token 用量：一张新表（见 `usageTableName` 的说明），主键就是消息 id
            _ = try SQLiteManager.shared.getTable(usageTableName) { builder in
                builder.column(self.uMessageId, primaryKey: true)
                builder.column(self.uConversationId)
                builder.column(self.uPromptTokens)
                builder.column(self.uCompletionTokens)
                builder.column(self.uTotalTokens)
                builder.column(self.uCacheHitTokens)
                builder.column(self.uCacheMissTokens)
                builder.column(self.uCreatedAt)
            }
            // 引用表：同样是纯新增路径（见 `quoteTableName`）
            _ = try SQLiteManager.shared.getTable(quoteTableName) { builder in
                builder.column(self.qMessageId, primaryKey: true)
                builder.column(self.qConversationId)
                builder.column(self.qQuotedMessageId)
                builder.column(self.qQuotedRole)
                builder.column(self.qQuotedText)
                builder.column(self.qCreatedAt)
            }
            // 思考表：同样是纯新增路径（见 `reasoningTableName`），主键就是助手消息 id
            _ = try SQLiteManager.shared.getTable(reasoningTableName) { builder in
                builder.column(self.gMessageId, primaryKey: true)
                builder.column(self.gConversationId)
                builder.column(self.gText)
                builder.column(self.gDuration)
                builder.column(self.gCreatedAt)
            }
            // 项目表 / 项目资料表：同样是纯新增路径（见 `projectTableName` / `projectFileTableName`）
            _ = try SQLiteManager.shared.getTable(projectTableName) { builder in
                builder.column(self.pId, primaryKey: true)
                builder.column(self.pName)
                builder.column(self.pInstruction)
                builder.column(self.pSortOrder)
                builder.column(self.pCreatedAt)
            }
            _ = try SQLiteManager.shared.getTable(projectFileTableName) { builder in
                builder.column(self.pfId, primaryKey: true)
                builder.column(self.pfProjectId)
                builder.column(self.pfName)
                builder.column(self.pfStorage)
                builder.column(self.pfSize)
                builder.column(self.pfCreatedAt)
            }
            // @ 项目资料表：纯新增路径（见 `mentionTableName`）。
            // ⚠️ 主键是 `id`（`messageId#序号`）而**不是 message_id** —— 一条消息可带多份
            _ = try SQLiteManager.shared.getTable(mentionTableName) { builder in
                builder.column(self.nId, primaryKey: true)
                builder.column(self.nMessageId)
                builder.column(self.nConversationId)
                builder.column(self.nIndex)
                builder.column(self.nMentionFileId)
                builder.column(self.nMentionName)
                builder.column(self.nMentionStorage)
                builder.column(self.nMentionSize)
                builder.column(self.nCreatedAt)
            }
            // 模型切换系统消息表：纯新增路径（见 `modelSwitchTableName`），主键就是消息 id
            _ = try SQLiteManager.shared.getTable(modelSwitchTableName) { builder in
                builder.column(self.sMessageId, primaryKey: true)
                builder.column(self.sConversationId)
                builder.column(self.sFromId)
                builder.column(self.sToId)
                builder.column(self.sFromName)
                builder.column(self.sToName)
                builder.column(self.sCreatedAt)
            }
            // 项目资料检索片段表：纯新增路径（见 `chunkTableName`），主键是自造 UUID
            _ = try SQLiteManager.shared.getTable(chunkTableName) { builder in
                builder.column(self.chId, primaryKey: true)
                builder.column(self.chProjectId)
                builder.column(self.chFileId)
                builder.column(self.chIndex)
                builder.column(self.chText)
                builder.column(self.chCharCount)
                builder.column(self.chCreatedAt)
            }
            runMigrations()
            // 切会话必按 conversation_id 过滤，且消息表增长最快，故无条件建索引（写入量低：每轮几次）
            SQLiteManager.shared.ensureIndexes(
                [IndexSpec(name: "idx_ai_message_conversation", table: messageTableName, column: "conversation_id")],
                policy: .always
            )
            // 用量表同样按会话取（载入会话时一次性读该会话的全部用量）、按消息 id 删
            SQLiteManager.shared.ensureIndexes(
                [IndexSpec(name: "idx_ai_usage_conversation", table: usageTableName, column: "conversation_id")],
                policy: .always
            )
            // 引用表：载入会话时按 conversation_id 一次读全（与用量表同一条路径）
            SQLiteManager.shared.ensureIndexes(
                [IndexSpec(name: "idx_ai_quote_conversation", table: quoteTableName, column: "conversation_id")],
                policy: .always
            )
            // 思考表：同一条路径（载入会话时一次读全该会话的思考）
            SQLiteManager.shared.ensureIndexes(
                [IndexSpec(name: "idx_ai_reasoning_conversation", table: reasoningTableName, column: "conversation_id")],
                policy: .always
            )
            // @ 资料表：载入会话时按 conversation_id 一次读全（与引用表同一条路径）；
            // 另按 message_id 建一个 —— 删消息 / 重新生成要按消息 id 定点清除
            SQLiteManager.shared.ensureIndexes(
                [IndexSpec(name: "idx_ai_mention_conversation", table: mentionTableName, column: "conversation_id"),
                 IndexSpec(name: "idx_ai_mention_message", table: mentionTableName, column: "message_id")],
                policy: .always
            )
            // 项目资料表：按项目 id 取（进项目页一次读全它的资料）、按 id 删
            SQLiteManager.shared.ensureIndexes(
                [IndexSpec(name: "idx_ai_project_file_project", table: projectFileTableName, column: "project_id")],
                policy: .always
            )
            // 模型切换表：同一条路径（载入会话时按 conversation_id 一次读全它的系统消息）
            SQLiteManager.shared.ensureIndexes(
                [IndexSpec(name: "idx_ai_model_switch_conversation", table: modelSwitchTableName, column: "conversation_id")],
                policy: .always
            )
            // 检索片段表：检索时按 project_id 一次读全该项目的片段（发送前检索走这条）；
            // 另按 file_id 建一个 —— 删资料 / 重建单份索引时按文件定点清
            SQLiteManager.shared.ensureIndexes(
                [IndexSpec(name: "idx_ai_chunk_project", table: chunkTableName, column: "project_id"),
                 IndexSpec(name: "idx_ai_chunk_file", table: chunkTableName, column: "file_id")],
                policy: .always
            )
            // 会话表的 project_id：列表分组按它过滤（`project_id = ?` 各组各查一次）
            SQLiteManager.shared.ensureIndexes(
                [IndexSpec(name: "idx_ai_conversation_project", table: conversationTableName, column: "project_id")],
                policy: .always
            )
            return true
        } catch {
            debugPrint("AI 会话建表/迁移失败: \(error)")
            return false
        }
    }()

    /// `message_count` 的**自引用原子更新**表达式：`MAX(0, "message_count" + delta)`。
    ///
    /// 一次 UPDATE 完成「读-改-写」，省掉原先 `SELECT → 内存加 → UPDATE` 的两次往返；
    /// 下界钳在 SQL 里（删消息时不会把计数减成负数）。
    ///
    /// 🔴 两个已经踩过的坑，动手改之前先看完：
    ///
    /// 1. **必须用 `Expression(literal:)`**。
    ///    `Expression<Int>("MAX(0, ...)")` 这个写法命中的是 `init(_ identifier: String)`，
    ///    它把整段字符串当**标识符**加双引号 → `SET "message_count" = "MAX(0, message_count + 2)"`；
    ///    而 SQLite 对「双引号里不是有效列名」的兜底行为是**当字符串字面量**，
    ///    于是这列被存成 TEXT —— 读回来时 `row[cMessageCount]`（`try!`）解不出 Int 直接 Fatal，
    ///    实测崩在对话列表 `fetchSummaries()`（v4 迁移就是来修这批脏行的）。
    ///    `init(_ identifier:)` 只适合传**纯列名** —— `Expression<Int>("message_count")` 正是这么用的。
    /// 2. 双参标量 `MAX(a, b)` SQLite.swift **没有 helper**：`Function` 枚举是 fileprivate 的，
    ///    且 `.max` 只有单参聚合版（`age.max` → `max("age")`）。所以这里手包一层。
    ///    模板由「已转义的纯列名 + Swift 侧整数插值」拼成，**无绑定、无用户输入**，
    ///    既不丢东西，也没有注入面。
    private func clampedCount(delta: Int) -> Expression<Int> {
        Expression<Int>(literal: "MAX(0, \(cMessageCount.template) + \(delta))")
    }

    /// 迁移到当前 schema。
    ///
    /// 版本号按表记录在 `_migrations` 元表（与 BrowseHistoryManager 同构）。
    /// v2/v3 都是「结构已对、只把版本号记准」；**v4 起开始带数据修复脚本**。
    ///
    /// 若未来要改表结构，务必按「结构探测 + 幂等 ALTER」写脚本，不能只靠版本号分支：
    /// `getTable` 是 `CREATE TABLE IF NOT EXISTS`，已存在的表不会自动补列，
    /// 而版本号与真实结构可能不一致（历史上就出现过补列被跳过、读列时直接 Fatal error）。
    private func runMigrations() {
        let db = SQLiteManager.shared
        let current = (try? db.currentVersion(forTable: conversationTableName)) ?? 0
        guard current < schemaVersion else { return }

        // 🔴 默认项目「任务」每次启动都 ensure（幂等：有就跳过）。
        //    为什么不是 v10 的一次性脚本：版本号推进过的老库**不会再进**迁移分支，
        //    但默认项目仍可能被异常路径删掉（UI 层拦了删除，这里是底层双保险）——
        //    没了它，系统就没有「无归属会话的默认去处」。
        //    放在最前面：下面 v10 要把 NULL 行指向它，得先有它。
        //    ⚠️ 这里在 `ready` 的 lazy 闭包内，`ready` 本身还是 false ⇒
        //       `ensureDefaultProject` ⛔ 不能 guard ready（它自带错误处理）。
        ensureDefaultProject()

        if current < 4 {
            // v4：修 `message_count` 的历史脏数据（成因见 `clampedCount(delta:)` 的坑 1）。
            //
            // 幂等 + 自限：只碰 `typeof` 不是 integer 的行。计数**从 `ai_message` 重算**，
            // 而不是一律填 0 —— 那些会话里往往还留着真实消息（实测有一条 58 条的）。
            //
            // ⚠️ `executeRawThrows` 是**事务内原语**（自己不上 `dbQueue` 锁），事务外直接调
            //    就没有串行化保证。所以这里必须用 `transaction { }` 包住。
            do {
                try db.transaction {
                    try db.executeRawThrows("""
                        UPDATE \(conversationTableName)
                           SET message_count = (
                                SELECT COUNT(*) FROM \(messageTableName)
                                 WHERE \(messageTableName).conversation_id = \(conversationTableName).id
                           )
                         WHERE typeof(message_count) <> 'integer'
                        """)
                }
            } catch {
                // 🔴 修不好**就不推进版本号**，下次冷启动重试（语句幂等，重跑无副作用）。
                //    若在这里吞掉错误照样推进，脏行会永远停在 TEXT：列表不崩了，
                //    但那几个会话的计数永远是 0。
                debugPrint("[AIChatStore] v4 修复 message_count 脏数据失败，下次启动重试: \(error)")
                return
            }
        }

        if current < 6 {
            // v6：项目（文件夹）能力。**两部分，风险只有第二部分**：
            //
            // ① 两张新表（`ai_conversation_project` / `ai_conversation_project_file`）：
            //    纯新增，`getTable` 建表即迁移，无需任何脚本（见各自表名的注释）。
            //
            // ② `ai_conversation` 补 `project_id` 可空列 —— 这是本工程历史上
            //    「补列被跳过 → 读列 Fatal」的老坑现场，必须按老教训写：
            //    **先结构探测、再幂等 ALTER**，不能只靠 `current < 6` 这个版本号分支
            //    （版本号与真实结构可能不一致）。
            //    ALTER 语句本身是静态 SQL、无用户输入；失败不推进版本号，下次冷启动重试。
            do {
                let hasColumn = try db.tableHasColumn(table: conversationTableName, column: "project_id")
                if !hasColumn {
                    try db.transaction {
                        try db.executeRawThrows(
                            "ALTER TABLE \(conversationTableName) ADD COLUMN project_id TEXT"
                        )
                    }
                    debugPrint("[AIChatStore] v6 已补列 project_id")
                }
            } catch {
                // 🔴 与 v4 同一条纪律：修不好**就不推进版本号**，下次冷启动重试。
                //    若在这里吞掉错误照样推进，老库永远没有这一列 —— 而读路径有兜底，
                //    症状会是「项目功能静默失效」（会话永远归不了类），比崩溃更难查。
                debugPrint("[AIChatStore] v6 补列 project_id 失败，下次启动重试: \(error)")
                return
            }
        }

        if current < 10 {
            // v10：消灭「未归类」—— 存量 `project_id IS NULL` 的会话行全部写进
            // 默认项目「任务」（2026-10-25）。
            //
            // 背景：此前「先归入项目、后发第一条消息」的路径会把归属丢成 NULL
            // （`buildConversationInsert` 漏写 project_id，2026-10-25 已修），
            // 加上 UI 上「未归类」段整体删除 ⇒ 库里这些行必须有个去处。
            // 「未归类」的真相（内存态）从来没持久化过 ⇒ 统一进默认组是唯一合理归宿。
            //
            // ⚠️ 同 v4 纪律：修不好**就不推进版本号**，下次冷启动重试（语句幂等）。
            //    迁移前 ensureDefaultProject 已在 runMigrations 开头跑过 ⇒ 默认项目必存在。
            do {
                try db.transaction {
                    try db.executeRawThrows("""
                        UPDATE \(conversationTableName)
                           SET project_id = '\(Self.defaultProjectId.uuidString)'
                         WHERE project_id IS NULL
                        """)
                }
                debugPrint("[AIChatStore] v10 未归类会话已全部移入默认项目「任务」")
            } catch {
                debugPrint("[AIChatStore] v10 迁移未归类会话失败，下次启动重试: \(error)")
                return
            }
        }

        try? db.setVersion(schemaVersion, forTable: conversationTableName)
    }

    // MARK: - 置顶

    /// 置顶会话 id 集合（每次访问都从 UserDefaults 取最新值，不做内存缓存以免多处写入不一致）
    private var pinnedIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: pinnedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: pinnedKey) }
    }

    /// 置顶 / 取消置顶
    public func setPinned(id: UUID, isPinned: Bool) {
        var ids = pinnedIds
        if isPinned {
            ids.insert(id.uuidString)
        } else {
            ids.remove(id.uuidString)
        }
        pinnedIds = ids
        debugPrint("[AIChatStore] 置顶变更 id=\(id.uuidString) isPinned=\(isPinned) 置顶总数=\(ids.count)")
    }

    /// 会话是否置顶
    public func isPinned(_ id: UUID) -> Bool {
        pinnedIds.contains(id.uuidString)
    }

    // MARK: - 项目（会话文件夹，2026-10-21）

    /// 全部项目（按 `sort_order` 升序）。视图层拿它画侧栏分组头 / 抽屉 section。
    public func fetchProjects() -> [AIChatProject] {
        guard ready else { return [] }
        do {
            let rows = try SQLiteManager.shared.search(projects, orderBy: pSortOrder.asc,
                                                       limit: nil, offset: nil)
            return rows.compactMap { row -> AIChatProject? in
                guard let id = UUID(uuidString: row[pId]) else { return nil }
                return AIChatProject(
                    id: id,
                    name: row[pName],
                    instruction: row[pInstruction],
                    sortOrder: row[pSortOrder],
                    createdAt: Date(timeIntervalSince1970: row[pCreatedAt])
                )
            }
        } catch {
            debugPrint("[AIChatStore] 查询项目列表失败: \(error)")
            return []
        }
    }

    /// 「任务」—— 系统默认项目容器的**固定 id**（2026-10-25）。
    ///
    /// ## 为什么用固定 UUID 识别，而不是按名字 / 加列
    /// - **名字可以改**（产品决策：默认组允许用户起专属名）⇒ 改名后按名字就认不出它；
    /// - **加 `is_default` 列要走 ALTER 老表** —— v6 补列正是本工程「补列被跳过 →
    ///   读列 Fatal」的老坑现场，⛔ 不重蹈；
    /// - 固定 id 让 ensure **幂等**：万一默认组被异常路径删掉（UI 拦了删除，
    ///   底层双保险），原地重建后 id 不变 ⇒ 所有指向它的会话行 / 资料行都还接得上。
    ///
    /// 用 `uuid_t` 构造而非 `UUID(uuidString:)!` 强解：前者编译期不可能失败。
    public static let defaultProjectId: UUID = {
        var u = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)
        return UUID(uuid: u)
    }()

    /// 确保默认项目「任务」存在；不存在则按固定 id 原地创建。**幂等**。
    ///
    /// - `sortOrder = -1`：默认组排在所有用户项目之前（用户项目从 0 起，
    ///   见 `createProject` 的追加逻辑）。
    /// - 名字取**当前语言**的快照写库（已存在的库不随语言重写 —— 用户可自己改名）。
    /// - ⚠️ 2026-10-25 名字由「任务项目组」改成「任务」时，用户明确拍板
    ///   **不兼容老库旧名** ⇒ 这里刻意**不做**「读到旧名就 UPDATE」的迁移：
    ///   老库里那行继续显示「任务项目组」（用户自己起过名的更要尊重）；
    ///   想统一只有一个办法——删掉默认项目那行，下次启动按固定 id 以新名重建。
    /// - ⚠️ 不 guard `ready`：它要在 `ready` 的 lazy 闭包内（runMigrations 开头）
    ///   就能跑；自身带完整错误处理，表未建好时只是 insert 失败并打印。
    @discardableResult
    public func ensureDefaultProject() -> AIChatProject? {
        do {
            if let row = try SQLiteManager.shared.search(
                projects, filter: pId == Self.defaultProjectId.uuidString, limit: 1, offset: nil
            ).first {
                return AIChatProject(id: Self.defaultProjectId,
                                     name: row[pName],
                                     instruction: row[pInstruction],
                                     sortOrder: row[pSortOrder],
                                     createdAt: Date(timeIntervalSince1970: row[pCreatedAt]))
            }
        } catch {
            debugPrint("[AIChatStore] 读取默认项目失败: \(error)")
            return nil
        }
        let project = AIChatProject(id: Self.defaultProjectId,
                                    name: L("任务"),
                                    sortOrder: -1)
        do {
            try SQLiteManager.shared.insert(projects.insert(
                pId <- project.id.uuidString,
                pName <- project.name,
                pInstruction <- project.instruction,
                pSortOrder <- project.sortOrder,
                pCreatedAt <- project.createdAt.timeIntervalSince1970
            ))
            debugPrint("[AIChatStore] 已创建默认项目「任务」")
            return project
        } catch {
            debugPrint("[AIChatStore] 创建默认项目失败: \(error)")
            return nil
        }
    }

    /// 新建项目。`sortOrder` 自动追加到末尾（当前项目数）—— 新项目出现在列表最后，
    /// 不抢用户眼睛；删除留下的数字空洞无害（排序仍正确）。
    /// - Returns: 成功时回新建的项目（调用方可能要立刻选中它）；名称为空返回 nil。
    @discardableResult
    public func createProject(name: String, instruction: String = "") -> AIChatProject? {
        guard ready else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let project = AIChatProject(name: trimmed, instruction: instruction,
                                    sortOrder: (try? SQLiteManager.shared.scalar(projects)) ?? 0)
        do {
            try SQLiteManager.shared.insert(projects.insert(
                pId <- project.id.uuidString,
                pName <- project.name,
                pInstruction <- project.instruction,
                pSortOrder <- project.sortOrder,
                pCreatedAt <- project.createdAt.timeIntervalSince1970
            ))
            debugPrint("[AIChatStore] 新建项目 name=\(project.name) sortOrder=\(project.sortOrder)")
            return project
        } catch {
            debugPrint("[AIChatStore] 新建项目失败: \(error)")
            return nil
        }
    }

    /// 重命名项目。空名称直接忽略（不静默清空用户的项目名）。
    public func renameProject(id: UUID, name: String) {
        guard ready else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try SQLiteManager.shared.update(projects.filter(pId == id.uuidString).update(pName <- trimmed))
        } catch {
            debugPrint("[AIChatStore] 重命名项目失败: \(error)")
        }
    }

    /// 设置项目级系统提示词（L3）。空 = 回落全局提示词（见 `AIGenerationSettings.systemPrompt`）。
    public func setProjectInstruction(id: UUID, instruction: String) {
        guard ready else { return }
        do {
            try SQLiteManager.shared.update(
                projects.filter(pId == id.uuidString).update(pInstruction <- instruction)
            )
        } catch {
            debugPrint("[AIChatStore] 设置项目指令失败: \(error)")
        }
    }

    /// 读某个项目的指令（L3）。`nil` = 项目不存在。
    ///
    /// ⚠️ 单独开一个单行查询而不是让调用方 `fetchProjects().first{...}`：
    /// 请求注入那条路是**每轮发送都要走**的（`AIChatManager.withSystemPrompt`），
    /// 为读一个字段把全部项目连表捞一遍没必要。
    public func projectInstruction(id: UUID) -> String? {
        guard ready else { return nil }
        do {
            return try SQLiteManager.shared.search(projects,
                                                   filter: pId == id.uuidString,
                                                   limit: 1, offset: nil).first?[pInstruction]
        } catch {
            debugPrint("[AIChatStore] 读项目指令失败: \(error)")
            return nil
        }
    }

    /// 移动会话到某项目（2026-10-25 起「未归类」已消灭：`projectId = nil` 也
    /// **归一成默认项目「任务」**，再也造不出无归属行）。
    ///
    /// ⚠️ 只改会话行的 `project_id`，**不动 updatedAt** —— 归类是整理动作，
    /// 不该把会话在列表里往上跳（与「重命名不改时间」同一条理由）。
    public func setConversationProject(conversationId: UUID, projectId: UUID?) {
        guard ready else { return }
        let target = projectId ?? Self.defaultProjectId
        do {
            try SQLiteManager.shared.update(
                conversations.filter(cId == conversationId.uuidString).update(cProjectId <- target.uuidString)
            )
        } catch {
            debugPrint("[AIChatStore] 移动会话到项目失败: \(error)")
        }
    }

    /// 删除项目。**级联策略（三件事，一个事务）**：
    /// ① 会话移回默认项目「任务」—— ⛔ 绝不连带删会话；
    /// ② 项目资料文件物理删除 + 行删除；
    /// ③ 删项目行。
    ///
    /// 🔴 默认项目（`defaultProjectId`）**不可删**：它是无归属会话的唯一容器，
    ///    删了系统就没有默认去处（UI 层隐藏入口 + 这里双保险）。
    public func deleteProject(id: UUID) {
        guard ready else { return }
        guard id != Self.defaultProjectId else {
            debugPrint("[AIChatStore] 拒绝删除默认项目「任务」")
            return
        }
        do {
            try SQLiteManager.shared.transaction {
                // ① 会话回默认项目（executeUpdate 是事务内原语，自己不加锁）
                let detach = conversations.filter(cProjectId == id.uuidString)
                    .update(cProjectId <- Self.defaultProjectId.uuidString)
                try SQLiteManager.shared.executeUpdate(detach)
                // ② 资料：先删文件再删行（文件在沙盒附件目录，行只是账）
                let fileRows = try SQLiteManager.shared.search(projectFiles,
                                                               filter: pfProjectId == id.uuidString,
                                                               limit: nil, offset: nil)
                for row in fileRows {
                    if let url = AIAttachmentStorage.resolve(row[pfStorage]) {
                        AIAttachmentStorage.remove(at: url)
                    }
                }
                // 🔴 事务内的删除一律走 `executeDelete` 原语（不带锁）—— 2026-10-23 立：
                //    `delete(_:filter:)` 是带锁方法，事务闭包里调它靠 `onQueue` 可重入
                //    就地执行；那条链真崩过（`getSpecific` 从未接线 ⇒ 串行队列自己
                //    sync 自己 ⇒ SIGTRAP，`try` 接不住、崩溃报告只有一行队列名）。
                //    ⚠️ 本方法此前三处全是 `delete` —— 同样会崩，只是「删项目」这条路
                //       自 10-21 上线以来没被真跑过。别因为「一直这么写的」就留着。
                try SQLiteManager.shared.executeDelete(
                    projectFiles.filter(pfProjectId == id.uuidString).delete())
                // ②b 检索片段跟着资料一起走（不删的话，项目删了片段还留在库里，
                //     而 project_id 指向的项目已经不存在 —— 永远检索不出来的僵尸行）
                try SQLiteManager.shared.executeDelete(
                    chunks.filter(chProjectId == id.uuidString).delete())
                // ③ 项目行
                try SQLiteManager.shared.executeDelete(
                    projects.filter(pId == id.uuidString).delete())
            }
            debugPrint("[AIChatStore] 删除项目 id=\(id.uuidString)（会话已全部移回默认项目）")
        } catch {
            debugPrint("[AIChatStore] 删除项目失败: \(error)")
        }
    }

    // MARK: - 项目资料（挂在项目下的文件）

    /// 某项目的全部资料（按上传时间倒序）。
    public func fetchProjectFiles(projectId: UUID) -> [AIChatProjectFile] {
        guard ready else { return [] }
        do {
            let rows = try SQLiteManager.shared.search(projectFiles,
                                                       filter: pfProjectId == projectId.uuidString,
                                                       orderBy: pfCreatedAt.desc,
                                                       limit: nil, offset: nil)
            return rows.compactMap { row -> AIChatProjectFile? in
                guard let id = UUID(uuidString: row[pfId]) else { return nil }
                return AIChatProjectFile(
                    id: id,
                    projectId: projectId,
                    displayName: row[pfName],
                    storageName: row[pfStorage],
                    byteSize: row[pfSize],
                    createdAt: Date(timeIntervalSince1970: row[pfCreatedAt])
                )
            }
        } catch {
            debugPrint("[AIChatStore] 查询项目资料失败: \(error)")
            return []
        }
    }

    /// 把外部文件导入项目资料。落盘走 `AIAttachmentStorage.importFile`
    /// （与消息附件**同一目录、同一套 resolve** ⇒ 项目资料将来也能被文档页统一看到）。
    @discardableResult
    public func addProjectFile(projectId: UUID, sourceURL: URL) -> AIChatProjectFile? {
        guard ready else { return nil }
        guard let attachment = AIAttachmentStorage.importFile(at: sourceURL) else { return nil }
        let file = AIChatProjectFile(
            projectId: projectId,
            displayName: attachment.displayName,
            storageName: AIAttachmentStorage.storedPath(for: attachment.fileURL),
            byteSize: attachment.byteSize
        )
        do {
            try SQLiteManager.shared.insert(projectFiles.insert(
                pfId <- file.id.uuidString,
                pfProjectId <- file.projectId.uuidString,
                pfName <- file.displayName,
                pfStorage <- file.storageName,
                pfSize <- file.byteSize,
                pfCreatedAt <- file.createdAt.timeIntervalSince1970
            ))
            return file
        } catch {
            // 落库失败要把刚复制的文件收走，否则附件目录里会多一个没人引用的孤儿
            AIAttachmentStorage.remove(at: attachment.fileURL)
            debugPrint("[AIChatStore] 新增项目资料失败: \(error)")
            return nil
        }
    }

    /// 删除项目资料（行 + 物理文件 + 它的检索片段）。
    public func deleteProjectFile(id: UUID) {
        guard ready else { return }
        do {
            if let row = try SQLiteManager.shared.search(projectFiles,
                                                         filter: pfId == id.uuidString,
                                                         limit: 1, offset: nil).first,
               let url = AIAttachmentStorage.resolve(row[pfStorage]) {
                AIAttachmentStorage.remove(at: url)
            }
            try SQLiteManager.shared.delete(projectFiles, filter: pfId == id.uuidString)
            // 片段级联删（与文件同一口径：文件没了，它的索引必须跟着没）
            try SQLiteManager.shared.delete(chunks, filter: chFileId == id.uuidString)
        } catch {
            debugPrint("[AIChatStore] 删除项目资料失败: \(error)")
        }
    }

    // MARK: - 项目资料检索索引（RAG，v9，2026-10-23）

    /// 给一份项目资料建（重建）索引：读正文 → 切块 → 整份替换旧片段。
    ///
    /// **失败不抛、不阻断**：导入资料是主流程，索引是派生加速 —— 建不出来最多是
    /// 「这个文件暂时检索不到」，详情页状态里会显示为待索引。⛔ 别让调用方去 catch。
    ///
    /// 读不出的文件（zip/二进制、扫描件 PDF、超过 `AIChunker.maxIndexChars`）⇒ 写入**空片段集**
    /// （等于清掉可能存在的旧索引，状态计入「待索引」，⛔ 不静默截断）。
    public func indexProjectFile(_ file: AIChatProjectFile) {
        guard ready else { return }
        var texts: [String] = []
        if let url = file.fileURL,
           let raw = AIAttachmentStorage.extractedText(at: url, maxChars: AIChunker.maxIndexChars),
           raw.count <= AIChunker.maxIndexChars {
            texts = AIChunker.chunks(raw)
        }
        replaceFileChunks(fileId: file.id, projectId: file.projectId, texts: texts)
    }

    /// 重建一个项目的全部索引（详情页「重建索引」按钮）。
    /// - Returns: 实际建了索引的资料份数（读不出文本的不计）
    @discardableResult
    public func rebuildProjectIndex(projectId: UUID) -> Int {
        guard ready else { return 0 }
        var count = 0
        for file in fetchProjectFiles(projectId: projectId) {
            indexProjectFile(file)
            count += 1
        }
        debugPrint("[AIChatStore] 重建项目索引 id=\(projectId.uuidString) 共 \(count) 份资料")
        return count
    }

    /// 索引状态（详情页那一行「已索引 N/M · K 个片段」）。
    ///
    /// 现算而不落列：状态是**派生值**（片段表一查就有），给 `ai_conversation_project_file`
    /// 加列记状态就是给老表加列 —— 本工程踩过两次的老坑，⛔ 别再踩。
    public func projectIndexStatus(projectId: UUID) -> AIProjectIndexStatus {
        guard ready else { return AIProjectIndexStatus(fileCount: 0, indexedFileCount: 0, chunkCount: 0) }
        let files = fetchProjectFiles(projectId: projectId)
        var perFile: [UUID: Int] = [:]
        do {
            let rows = try SQLiteManager.shared.search(chunks,
                                                       filter: chProjectId == projectId.uuidString,
                                                       limit: nil, offset: nil)
            for row in rows {
                guard let fileId = UUID(uuidString: row[chFileId]) else { continue }
                perFile[fileId, default: 0] += 1
            }
        } catch {
            debugPrint("[AIChatStore] 读索引状态失败: \(error)")
        }
        return AIProjectIndexStatus(fileCount: files.count,
                                    indexedFileCount: perFile.count,
                                    chunkCount: perFile.values.reduce(0, +))
    }

    /// 某项目有没有已建好的片段（发送前检索的**可用性**预检：没有 ⇒ 直接起流，
    /// 连「正在检索」的转圈都不该闪 —— 用户没开项目资料时不能每次发送都闪一下）。
    public func hasIndexedChunks(projectId: UUID) -> Bool {
        guard ready else { return false }
        do {
            let rows = try SQLiteManager.shared.search(chunks,
                                                       filter: chProjectId == projectId.uuidString,
                                                       limit: 1, offset: nil)
            return !rows.isEmpty
        } catch {
            debugPrint("[AIChatStore] 探测索引失败: \(error)")
            return false
        }
    }

    /// 某项目的全部片段（按 文件内序号 升序 —— 注入次序稳定）。
    /// 检索入口（`AIChatManager` 发送前）读这一次，然后交给 `AIProjectRetriever` 打分。
    public func projectChunks(projectId: UUID) -> [AIProjectFileChunk] {
        guard ready else { return [] }
        do {
            let rows = try SQLiteManager.shared.search(chunks,
                                                       filter: chProjectId == projectId.uuidString,
                                                       limit: nil, offset: nil)
            return rows.compactMap { row -> AIProjectFileChunk? in
                guard let id = UUID(uuidString: row[chId]),
                      let fileId = UUID(uuidString: row[chFileId]) else { return nil }
                return AIProjectFileChunk(id: id,
                                          projectId: projectId,
                                          fileId: fileId,
                                          index: row[chIndex],
                                          text: row[chText],
                                          charCount: row[chCharCount],
                                          createdAt: Date(timeIntervalSince1970: row[chCreatedAt]))
            }
            .sorted { $0.index == $1.index ? $0.fileId.uuidString < $1.fileId.uuidString : $0.index < $1.index }
        } catch {
            debugPrint("[AIChatStore] 读项目片段失败: \(error)")
            return []
        }
    }

    /// 整份替换某文件的片段（一个事务：先删后插）。
    ///
    /// ⚠️ 事务内用 `executeInsert`（绑定版）：`insert` 自己会 `onQueue`，而事务内
    ///    虽然可重入，统一走绑定原语是 `appendMessages` 立下的口径（自由文本安全）。
    private func replaceFileChunks(fileId: UUID, projectId: UUID, texts: [String]) {
        guard ready else { return }
        do {
            try SQLiteManager.shared.transaction {
                // 🔴 删除走 executeDelete 原语（不带锁）—— ⛔ 别图省事调 `delete(_:filter:)`：
                //    那是带锁方法，事务内调它依赖 `onQueue` 可重入（就地执行），
                //    而这条链 2026-10-23 真崩过（getSpecific 从未接线 ⇒ 串行队列
                //    自己 sync 自己 ⇒ SIGTRAP，try 接不住）。原语语义也更直白：
                //    「这里已经在事务里了」。
                try SQLiteManager.shared.executeDelete(
                    chunks.filter(chFileId == fileId.uuidString).delete())
                let now = Date().timeIntervalSince1970
                for (offset, text) in texts.enumerated() {
                    let insert = chunks.insert(
                        chId <- UUID().uuidString,
                        chProjectId <- projectId.uuidString,
                        chFileId <- fileId.uuidString,
                        chIndex <- offset,
                        chText <- text,
                        chCharCount <- text.count,
                        chCreatedAt <- now
                    )
                    try SQLiteManager.shared.executeInsert(insert)
                }
            }
        } catch {
            debugPrint("[AIChatStore] 写项目资料索引失败 file=\(fileId.uuidString): \(error)")
        }
    }

    // MARK: - 上次打开的会话

    /// 上次打开的会话 id（冷启动恢复用）。
    /// 若指向的会话不存在（如新建后未发过消息、或已被清理），上层会自然回落到落地页。
    public var lastActiveConversationId: UUID? {
        get { UserDefaults.standard.string(forKey: lastActiveKey).flatMap { UUID(uuidString: $0) } }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: lastActiveKey) }
    }

    // MARK: - 会话：增 / 改 / 查

    /// 新建（或覆盖）会话行。上层在「首条消息发出时」调用，
    /// 因此空会话不会落库 —— 对话列表天然不含「新对话」占位。
    ///
    /// `project_id` 由调用方（`AIChatManager.newConversation` 建的内存态）带上，
    /// 恒为默认项目「任务」或用户显式归属 —— 2026-10-25 起不再有 NULL 新行
    /// （`buildConversationInsert` 漏写它的 bug 见 VERIFY-PROBES.md §34.2）。
    public func createConversation(_ conversation: AIConversation) {
        guard ready else { return }
        do {
            try SQLiteManager.shared.insert(buildConversationInsert(conversation, messageCount: 0))
        } catch {
            debugPrint("创建 AI 会话失败: \(error)")
        }
    }

    /// 更新会话的标题与更新时间（不等于「重命名」：重命名不改 updatedAt，避免列表被重排）
    public func touchConversation(id: UUID, title: String, updatedAt: Date = Date()) {
        guard ready else { return }
        let update = conversations.filter(cId == id.uuidString).update(
            cTitle <- title,
            cUpdatedAt <- updatedAt.timeIntervalSince1970
        )
        do {
            try SQLiteManager.shared.update(update)
        } catch {
            debugPrint("更新 AI 会话失败: \(error)")
        }
    }

    /// 重命名：只改 title，不动 updatedAt（列表顺序保持不变）
    public func renameConversation(id: UUID, title: String) {
        guard ready else { return }
        let update = conversations.filter(cId == id.uuidString).update(cTitle <- title)
        do {
            try SQLiteManager.shared.update(update)
        } catch {
            debugPrint("重命名 AI 会话失败: \(error)")
        }
    }

    /// 对话列表：**置顶优先 → 有项目的按项目分组（组间按项目 sortOrder）→
    /// 默认项目「任务」恒在最前（sortOrder = -1）**。
    ///
    /// 排序分两步：SQL 先按 `updated_at DESC` 取回，再在内存里做一次完整重排。
    /// 置顶不进 SQL，是因为它属于视图偏好、且与表结构解耦（避免受列迁移影响）；
    /// 项目分组也不进 SQL 的 GROUP BY —— 返回的仍是**扁平数组**（同项目相邻），
    /// 由两端 UI 各自画分组头（共享层管顺序、视图管形态，与置顶只排序不分组同一哲学）。
    ///
    /// ⚠️ 置顶会话**不参与项目分组**（置顶段内部按时间排）—— 置顶是全局概念，
    /// 归进某个项目组会让「它到底属于哪」变浑。UI 层把置顶段画在最上方（无分组头）。
    public func fetchSummaries() -> [AIConversationSummary] {
        guard ready else { return [] }
        let pinned = pinnedIds
        do {
            let rows = try SQLiteManager.shared.search(
                conversations, orderBy: cUpdatedAt.desc, limit: nil, offset: nil
            )
            // 项目表一次读全建 map（项目量级 = 个位数，比每行 join 便宜；也避免 N+1）
            var projectOrder: [String: Int] = [:]
            var projectName: [String: String] = [:]
            if let projectRows = try? SQLiteManager.shared.search(projects,
                                                                  orderBy: pSortOrder.asc,
                                                                  limit: nil, offset: nil) {
                for row in projectRows {
                    projectOrder[row[pId]] = row[pSortOrder]
                    projectName[row[pId]] = row[pName]
                }
            }
            let summaries = rows.compactMap { row -> AIConversationSummary? in
                guard let id = UUID(uuidString: row[cId]) else { return nil }
                // ⚠️ 这一列用**可抛版**读：`row[...]` 是 `try!`，一行脏数据就能让
                //    **整个对话列表** Fatal（历史上真发生过，见 `clampedCount(delta:)` 的坑 1）。
                //    正常路径永远走不到兜底值，这里只是「别崩」——脏行由 v4 迁移修回。
                let messageCount = (try? row.get(cMessageCount)) ?? 0
                // project_id 理论上恒非 nil（v10 迁移 + newConversation 默认带）。
                // 可抛版 + 兜底默认项目：极端脏行也不许变出「无归属」
                // —— 那会让会话悄悄掉出所有分组（不报错、无迹象）。
                let projectId = (try? row.get(cProjectId)).flatMap { UUID(uuidString: $0) }
                    ?? Self.defaultProjectId
                return AIConversationSummary(
                    id: id,
                    title: row[cTitle],
                    updatedAt: Date(timeIntervalSince1970: row[cUpdatedAt]),
                    messageCount: messageCount,
                    isPinned: pinned.contains(id.uuidString),
                    projectId: projectId
                )
            }
            // 三档排序（sort 不保证稳定，故每档都有确定性兜底）：
            // ① 置顶 > 非置顶；② 同为非置顶时按项目 sortOrder 排（默认项目 -1 恒最前）；
            // ③ 同档同组内按 updatedAt DESC（即 SQL 原序，这里显式兜底）。
            // `?? Int.max` 是死分支的防线：projectId 已兜底成默认项目、而默认项目
            // 必然在 projectOrder 里（ensure 过）—— 留着防未来有人改了兜底却忘了这里。
            return summaries.sorted { a, b in
                if a.isPinned != b.isPinned { return a.isPinned }
                let orderA = a.projectId.flatMap { projectOrder[$0.uuidString] } ?? Int.max
                let orderB = b.projectId.flatMap { projectOrder[$0.uuidString] } ?? Int.max
                if orderA != orderB { return orderA < orderB }
                return a.updatedAt > b.updatedAt
            }
        } catch {
            debugPrint("查询 AI 会话列表失败: \(error)")
            return []
        }
    }

    // MARK: - 文档（跨会话的文件列表）

    /// 「文档」页的数据源：**所有会话**里出现过的文件附件，**最近的在前**。
    ///
    /// 2026-10-10 用户需求：「所有对话中 用户上传 和 AI 返回的文件、文档 都在这个文档页面
    /// 显示，以列表形式显示，顺序以最近的为第一个。」
    ///
    /// - 口径：**只文件**（`kind = 4`），不含图片 / 视频（用户同日拍板）—— 见 `AIDocumentItem`。
    /// - 排序：`created_at DESC` 交给 SQL，视图层不重排。
    ///   ⚠️ 用**消息的落库时间**而不是会话的 `updated_at`：排序要回答的是
    ///   「这份文件是什么时候发出去的」，同一次对话里连发三个文件必须保持先后顺序。
    ///
    /// ## 两条「宁愿少一行也别多一行」的过滤
    /// ① **文件已不存在**（沙盒被清 / 用户在文件 App 里删过）⇒ 跳过。
    ///    留着它会得到一个「点了打不开」的行 —— 比列表短一点更像样。
    /// ② **路径解析不出来**（`resolve` 给 nil）⇒ 跳过。
    ///
    /// ## 为什么会话标题单独再查一次
    /// 消息表里只有 `conversation_id`，没有标题。会话表本身很小（一行一个会话，撑死几百行），
    /// 一次读全表建 map 比「每行去查一次会话」便宜一个数量级，也避免 N+1。
    public func fetchDocuments() -> [AIDocumentItem] {
        guard ready else { return [] }
        do {
            // 🔴 `kind = 4` 走 `Self.kindValue(.file)` 而不是写字面量 4：
            //    「文件块的编号」只有 `kindValue` / `block(from:)` 那一对说了算，
            //    在这里再写一个 4，将来谁动了映射就会**静默查空**（不报错、列表直接没了）。
            let rows = try SQLiteManager.shared.search(
                messages,
                filter: mKind == Self.kindValue(.file),
                orderBy: mCreatedAt.desc,
                limit: nil,
                offset: nil
            )
            guard !rows.isEmpty else { return [] }

            var titles: [String: String] = [:]
            if let conversationRows = try? SQLiteManager.shared.search(conversations,
                                                                      limit: nil,
                                                                      offset: nil) {
                for row in conversationRows { titles[row[cId]] = row[cTitle] }
            }

            return rows.compactMap { row -> AIDocumentItem? in
                guard let url = AIAttachmentStorage.resolve(row[mImageURL]) else { return nil }
                // 文件没了就别摆上来（见上面 ①）
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                guard let conversationId = UUID(uuidString: row[mConversationId]) else { return nil }
                let storedName = row[mText].trimmingCharacters(in: .whitespacesAndNewlines)
                return AIDocumentItem(
                    id: UUID(uuidString: row[mId]) ?? UUID(),
                    conversationId: conversationId,
                    conversationTitle: titles[row[mConversationId]] ?? "",
                    fileURL: url,
                    // 历史数据里 block.text 可能为空 → 退回磁盘名（一串 UUID），
                    // 总好过列表里一行没有名字
                    displayName: storedName.isEmpty ? url.lastPathComponent : storedName,
                    byteSize: AIAttachmentStorage.byteSize(of: url),
                    createdAt: Date(timeIntervalSince1970: row[mCreatedAt])
                )
            }
        } catch {
            debugPrint("[AIChatStore] 查询文档列表失败: \(error)")
            return []
        }
    }

    // MARK: - 全库搜索

    /// 搜索「会话标题 + 消息正文」（搜索页用）。
    ///
    /// 实现是**一次性读全表 + 内存匹配**，不用 SQL `LIKE`，原因有二：
    /// ① 个人聊天量级（几百~几千条）下内存匹配足够快，而且只有一次查询；
    /// ② `LIKE` 里的 `%` / `_` 需要自己转义，漏转义会搜出毫不相关的结果，
    ///    而 `SQLiteManager.search` 的表达式接口不便于带 `ESCAPE`，索性绕开这个坑。
    ///
    /// 排序：**标题命中的会话排最前**，其余按会话更新时间倒序、同一会话内按发送顺序。
    /// 每个会话最多保留 `perConversationLimit` 条消息命中，避免一个长对话把整页刷满。
    public func search(keyword: String,
                       limit: Int = 80,
                       perConversationLimit: Int = 4) -> [AIChatSearchHit] {
        guard ready else { return [] }
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return [] }

        // 消息表里只有 conversation_id，没有标题 —— 先从会话表把「id → 标题/时间」合过来
        var meta: [String: (title: String, updatedAt: Date)] = [:]
        for summary in fetchSummaries() {
            meta[summary.id.uuidString] = (summary.title, summary.updatedAt)
        }

        var hits: [AIChatSearchHit] = []

        // ① 标题命中
        for (idString, info) in meta {
            let titleRanges = AISearchMatcher.ranges(in: info.title, keyword: kw)
            guard !titleRanges.isEmpty, let id = UUID(uuidString: idString) else { continue }
            hits.append(AIChatSearchHit(conversationId: id,
                                        conversationTitle: info.title,
                                        updatedAt: info.updatedAt,
                                        role: nil,
                                        // 标题命中不属于任何一条消息 → 没有可定位的目标，
                                        // 点进去只会打开会话（见 AIModuleViewController.revealSearchHit）
                                        messageId: nil,
                                        snippet: info.title.isEmpty ? "新对话" : info.title,
                                        snippetRanges: titleRanges,
                                        titleRanges: titleRanges,
                                        isTitleMatch: true))
        }

        // ② 消息正文命中（按 seq 升序取回，同一会话内自然保持发送顺序）
        do {
            let rows = try SQLiteManager.shared.search(messages, orderBy: mSeq.asc, limit: nil, offset: nil)
            var matchedPerConversation: [String: Int] = [:]
            for row in rows {
                // 只搜文本块：图片/视频行没有正文，失败提示（kind 3）不是对话内容
                guard row[mKind] == 0 else { continue }
                let conversationId = row[mConversationId]
                guard let id = UUID(uuidString: conversationId) else { continue }
                guard matchedPerConversation[conversationId, default: 0] < perConversationLimit else { continue }
                guard let (snippet, ranges) = AISearchMatcher.snippet(of: row[mText], keyword: kw) else { continue }
                matchedPerConversation[conversationId, default: 0] += 1
                let info = meta[conversationId]
                hits.append(AIChatSearchHit(
                    conversationId: id,
                    conversationTitle: info?.title ?? "",
                    updatedAt: info?.updatedAt ?? Date(timeIntervalSince1970: row[mCreatedAt]),
                    role: row[mRole] == 0 ? .user : .assistant,
                    // 库里的消息 id 直接抛给上层：打开会话后按它滚动定位（见 AIChatSearchHit.messageId）
                    messageId: UUID(uuidString: row[mId]),
                    snippet: snippet,
                    snippetRanges: ranges,
                    titleRanges: [],
                    isTitleMatch: false
                ))
            }
        } catch {
            debugPrint("搜索 AI 消息失败: \(error)")
        }

        // 稳定排序：标题命中优先 → 会话更新时间倒序 → 保持上面生成的相对顺序。
        // `sort` 不保证稳定（同会话的多条命中会乱序），所以显式拿原始下标兜底。
        let ordered = hits.enumerated().sorted { lhs, rhs in
            if lhs.element.isTitleMatch != rhs.element.isTitleMatch { return lhs.element.isTitleMatch }
            if lhs.element.updatedAt != rhs.element.updatedAt { return lhs.element.updatedAt > rhs.element.updatedAt }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return Array(ordered.prefix(limit))
    }

    /// 从对话列表删除：连同该会话的全部消息一起删（事务保证原子性）。
    /// 若删的是「上次打开的会话」，同步清空记录，避免冷启动恢复到一个不存在的会话。
    public func deleteConversation(id: UUID) {
        guard ready else { return }
        let idString = id.uuidString
        // 先记下这个会话引用到的本地附件路径 —— 删完库就再也查不到了，
        // 那些图片/文件会永远留在沙盒里变成孤儿（附件是几百 KB 级的东西，攒起来不小）
        let attachmentPaths = referencedAttachments(conversationId: idString)
        do {
            // 事务内必须用 executeRawThrows 原语：SQLiteManager 的 delete 会再 dbQueue.sync 一次，嵌套会死锁
            try SQLiteManager.shared.transaction {
                try SQLiteManager.shared.executeRawThrows(
                    "DELETE FROM \(messageTableName) WHERE conversation_id = '\(idString)'"
                )
                try SQLiteManager.shared.executeRawThrows(
                    "DELETE FROM \(usageTableName) WHERE conversation_id = '\(idString)'"
                )
                try SQLiteManager.shared.executeRawThrows(
                    "DELETE FROM \(quoteTableName) WHERE conversation_id = '\(idString)'"
                )
                // @ 资料行跟着会话一起走（它只是「这轮参考了哪份资料」的记录，不是资料本身）
                try SQLiteManager.shared.executeRawThrows(
                    "DELETE FROM \(mentionTableName) WHERE conversation_id = '\(idString)'"
                )
                try SQLiteManager.shared.executeRawThrows(
                    "DELETE FROM \(reasoningTableName) WHERE conversation_id = '\(idString)'"
                )
                // 模型切换系统消息跟着会话一起走（它只是「当时换过模型」的记录）
                try SQLiteManager.shared.executeRawThrows(
                    "DELETE FROM \(modelSwitchTableName) WHERE conversation_id = '\(idString)'"
                )
                try SQLiteManager.shared.executeRawThrows(
                    "DELETE FROM \(conversationTableName) WHERE id = '\(idString)'"
                )
            }
        } catch {
            debugPrint("删除 AI 会话失败: \(error)")
            // 库没删干净就别动文件：界面可能还要继续引用它们
            return
        }
        // 落库成功后才清磁盘（`remove` 对不存在的文件是空操作，
        // 所以助手侧那些远程 URL 混进来也无害）
        attachmentPaths.forEach { AIAttachmentStorage.remove(at: $0) }
        if lastActiveConversationId == id { lastActiveConversationId = nil }
        // 会话没了，置顶记录也要清掉，避免集合里残留无效 id
        if pinnedIds.contains(id.uuidString) {
            var ids = pinnedIds
            ids.remove(id.uuidString)
            pinnedIds = ids
        }
    }

    /// 载入某个会话（含其全部消息，按 seq 升序）
    public func loadConversation(id: UUID) -> AIConversation? {
        guard ready else { return nil }
        do {
            guard let cRow = try SQLiteManager.shared.search(
                conversations, filter: cId == id.uuidString, limit: 1, offset: nil
            ).first else { return nil }

            var conversation = AIConversation(
                id: id,
                title: cRow[cTitle],
                createdAt: Date(timeIntervalSince1970: cRow[cCreatedAt]),
                updatedAt: Date(timeIntervalSince1970: cRow[cUpdatedAt]),
                // project_id 理论上恒非 nil（v10 迁移 + newConversation 默认带），
                // 可抛版兜底默认项目：极端脏行当「任务」（静默降级不崩，
                // 真相由迁移日志暴露）—— 2026-10-25 起不再有「未归类」这个态。
                projectId: (try? cRow.get(cProjectId)).flatMap { UUID(uuidString: $0) }
                    ?? Self.defaultProjectId
            )

            let mRows = try SQLiteManager.shared.search(
                messages, filter: mConversationId == id.uuidString, orderBy: mSeq.asc, limit: nil, offset: nil
            )
            // 用量 / 引用 / 思考都一次性读回该会话的全部（各自按 message_id 索引），避免逐行查库
            let usageMap = self.usageMap(conversationId: id)
            let quoteMap = self.quoteMap(conversationId: id)
            let reasoningMap = self.reasoningMap(conversationId: id)
            // @ 资料：一条消息可能有多份 ⇒ 值是数组（顺序按写入时的 idx，见 `mentionMap`）
            let mentionMap = self.mentionMap(conversationId: id)
            // 模型切换系统消息：1:1（key 直接用 `r[mId]`），规则 ①② 的数据来源
            let modelSwitchMap = self.modelSwitchMap(conversationId: id)
            var lastRole: AIRole?
            for r in mRows {
                let isUser = r[mRole] == 0
                // ⚠️ 必须沿用库里的消息 id（`mId`）：它是「搜索结果定位到某一条」
                // 「重新生成删掉指定行」「用量按 id 关联」三件事的共同锚点。
                // 恢复时另生 UUID 会让老消息永远定位不到、也删不掉。
                let messageId = UUID(uuidString: r[mId]) ?? UUID()
                guard let block = Self.block(from: r,
                                             id: messageId,
                                             isUser: isUser,
                                             kind: mKind, text: mText,
                                             imageURL: mImageURL, videoURL: mVideoURL, coverURL: mVideoCoverURL) else { continue }
                let role: AIRole = isUser ? .user : .assistant
                // isFirstBlockOfTurn 不入库：按「与上一条 role 不同」现场推导，规则与发送时一致
                var row = AIChatRow(id: messageId, role: role, block: block, isFirstBlockOfTurn: lastRole != role)
                // 时间戳同样沿用库里的值：它决定「和上一条隔了多久 → 要不要报时间」，
                // 取当前时间会把整段历史挤成同一秒，时间分隔线全丢
                row.createdAt = Date(timeIntervalSince1970: r[mCreatedAt])
                // 用量挂在块上：聊天页虽然不显示它了，但「这个会话花过多少」是消息自身的
                // 事实（将来要做「本轮用量明细」也靠它）—— 一次读全，别留给上层再查库
                row.block.usage = usageMap[r[mId]]
                // 引用同理：它是这条消息自身的事实，恢复会话时一并带上，别留给上层再查库
                row.block.quote = quoteMap[r[mId]]
                // @ 资料同理。⚠️ 空数组与「没有这个键」同义（老消息都没有这一行），
                // 不必区分 —— 上层只判 `isEmpty`
                row.block.mentions = mentionMap[r[mId]] ?? []
                // 思考同理：**不在这里判展示总闸** —— 关着时历史思考也照常读进模型，
                // 只是渲染时现读开关决定画不画（`AIChatRow.thinkingHeightOrZero`）。
                // 在读取侧过滤的话，用户重新打开开关还得重启才看得到历史思考。
                row.block.reasoning = reasoningMap[r[mId]]
                // 模型切换同理：规则 ①② 重启后要仍然成立，必须把「从哪切到哪」原样带回来
                // （没有这一行时判据退化成「新插一条」，见 `AIChatManager.noteModelSwitch`）
                row.block.modelSwitch = modelSwitchMap[r[mId]]
                conversation.rows.append(row)
                lastRole = role
            }
            return conversation
        } catch {
            debugPrint("载入 AI 会话失败: \(error)")
            return nil
        }
    }

    // MARK: - 消息：增 / 改

    /// 追加一条消息（seq 取当前会话最大 seq + 1，并同步会话的更新时间与消息数）
    ///
    /// 单条版 = `appendMessages` 的 `rows.count == 1` 特例。**批量场景（一次发送连落多条）
    /// 请直接调 `appendMessages`**：本方法每调一次就开一个事务，而每个事务都是一次磁盘提交。
    @discardableResult
    public func appendMessage(conversationId: UUID, row: AIChatRow) -> Bool {
        // title 传 nil = 只更计数与时间，不动标题（单条追加的调用方本就不改标题）
        appendMessages(conversationId: conversationId,
                       title: nil,
                       rows: [row],
                       createConversation: nil)
    }

    /// 批量追加：把这一拍的**全部**落库动作合进**一个事务**
    /// —— 建/更会话 + N 条消息 + 各自的引用 + **各自的思考** + 会话的计数与更新时间。
    ///
    /// **为什么要有它**：原来一条消息就是 3~4 次独立提交（`insert` + `saveQuote` +
    /// `bumpMessageCount` + `touchUpdatedAt`，其中 `bumpMessageCount` 还是 SELECT+UPDATE 的读改写），
    /// 而一次「发送」会追加 2~4 条（附件行 + 文字行 + 助手占位行）→ 一次点击 ≈ 7 次磁盘提交、
    /// 4 次 SELECT，全在主线程。合并后是 **1 次提交、1 次 SELECT**。
    ///
    /// - Parameters:
    ///   - conversationId: 目标会话
    ///   - title: 需要一并回写的会话标题；`nil` 表示「不动标题这一列」
    ///   - rows: 待追加的消息，**数组顺序即 seq 顺序**（与内存里 `conversation.rows` 的追加顺序一致）
    ///   - createConversation: 非 `nil` 时建会话行（首条消息），此时计数直接写进建行语句
    /// - Returns: 是否成功（失败时整批已回滚）
    ///
    /// - Note: 失败语义比过去更严：以前 `insert` 成功、计数失败会留下「消息在、计数少 1」的半成功态；
    ///         现在要么全成、要么全不成。对聊天记录这是更正确的语义。
    @discardableResult
    public func appendMessages(conversationId: UUID,
                               title: String?,
                               rows: [AIChatRow],
                               createConversation conversation: AIConversation?) -> Bool {
        guard ready, !rows.isEmpty else { return false }
        let idString = conversationId.uuidString

        // ⚠️ seq 必须在**事务外**读一次：事务闭包里不能调 `search`（那会再走一次 dbQueue —— 虽然
        // 现在可重入不会死锁了，但读到的仍是本事务未提交的视图）。一次发送追加的行必然是连续的，
        // 所以取一次基线、内存里递增即可 —— 顺带把原来「每行各读一次 seq」的 2N 次读压成 1 次。
        let seqBase = nextSeq(of: conversationId)

        // 事务前的「纯构造」阶段：这些都不碰数据库，只是把 SQLite.swift 的语句对象拼出来，
        // 自由文本（正文 / 标题）由绑定负责转义 —— 全程一行 SQL 都不用自己拼。
        let messageInserts = rows.enumerated().map { offset, row in
            buildMessageInsert(row, conversationId: conversationId, seq: seqBase + offset)
        }
        let quoteInserts = rows.compactMap { buildQuoteInsert($0, conversationId: conversationId) }
        // @ 项目资料：与引用同一个事务（同一次发送产生的「这条消息参考了哪几份资料」）。
        // ⚠️ 用 `flatMap`：一条消息可能带多份，每份一行
        let mentionInserts = rows.flatMap { buildMentionInserts($0, conversationId: conversationId) }
        // 思考过程与引用同款：各有自己的表（⛔ 不给 `ai_message` 加列），与消息同事务写。
        // ☠️ 2026-10-21 补：原先只插了消息与引用、**漏了这一批** ⇒ 走 appendMessages 落库的
        //    带 reasoning 行，重启后思考块整块消失（loadConversation 读回 nil）。
        //    首轮探针当场踩到：图上看不到「思考过程」折叠行，而 mountedChevrons 还绿着
        //    ——「cell 实例化过」与「思考内容读得回来」是两件事，判据必须分开。
        let reasoningInserts = rows.compactMap { row -> Insert? in
            guard row.block.kind == .text,
                  let reasoning = row.block.reasoning, !reasoning.isEmpty else { return nil }
            return buildReasoningInsert(messageId: row.block.id,
                                        conversationId: conversationId,
                                        reasoning: reasoning)
        }
        // 模型切换系统消息：与消息同事务（它俩表达的是同一件事 ——「这一行是什么」）。
        // 分开写会留下「系统消息在、结构化记录丢」的窗口：重启后规则 ①② 静默失效，
        // 而用户看到的那条流水还在（文案在 `ai_message.text` 里）。
        let modelSwitchInserts = rows.compactMap { buildModelSwitchInsert($0, conversationId: conversationId) }

        // 计数走**自引用原子更新**（表达式构造见 `clampedCount(delta:)`，坑也在那儿）：
        // 原来要先 SELECT 出当前值、在 Swift 里加完再回写（读改写），既多一次读，
        // 那个 SELECT 还带了个按主键过滤时毫无意义的 `orderBy`。
        let countExpression = clampedCount(delta: rows.count)
        let now = Date().timeIntervalSince1970

        var conversationInsert: Insert?
        var conversationUpdate: Update?
        if let conversation {
            // 首条消息：计数直接写进建行语句，不必再补一条 UPDATE
            conversationInsert = buildConversationInsert(conversation, messageCount: rows.count)
        } else if let title {
            conversationUpdate = conversations.filter(cId == idString).update(
                cTitle <- title, cMessageCount <- countExpression, cUpdatedAt <- now
            )
        } else {
            conversationUpdate = conversations.filter(cId == idString).update(
                cMessageCount <- countExpression, cUpdatedAt <- now
            )
        }

        do {
            try SQLiteManager.shared.transaction {
                if let insert = conversationInsert {
                    try SQLiteManager.shared.executeInsert(insert)
                }
                for insert in messageInserts {
                    try SQLiteManager.shared.executeInsert(insert)
                }
                for insert in quoteInserts {
                    try SQLiteManager.shared.executeInsert(insert)
                }
                for insert in mentionInserts {
                    try SQLiteManager.shared.executeInsert(insert)
                }
                for insert in reasoningInserts {
                    try SQLiteManager.shared.executeInsert(insert)
                }
                for insert in modelSwitchInserts {
                    try SQLiteManager.shared.executeInsert(insert)
                }
                if let update = conversationUpdate {
                    try SQLiteManager.shared.executeUpdate(update)
                }
            }
            return true
        } catch {
            debugPrint("[AIChatStore] 批量写入 \(rows.count) 条消息失败（整批已回滚）: \(error)")
            return false
        }
    }

    /// 更新某条消息的正文与类型（助手流式行：占位为空文本先入库，流式结束后整体回写一次）。
    ///
    /// 类型必须一起回写：同一行在收尾时可能从「空文本占位」变成「失败提示」（kind 0 → 3），
    /// 只改正文的话重启后仍会按文本渲染。
    public func updateMessage(id: UUID, text: String, kind: AIBlockKind) {
        guard ready else { return }
        let update = messages.filter(mId == id.uuidString)
            .update(mText <- text, mKind <- Self.kindValue(kind))
        do {
            try SQLiteManager.shared.update(update)
        } catch {
            debugPrint("更新 AI 消息正文失败: \(error)")
        }
    }

    /// 收尾回写：**正文 + 类型 + 用量 + 思考 + 会话更新时间，一个事务**。
    ///
    /// 两个调用点写的是同一行，区别只在「带不带用量」：
    /// - `persistFullTextNow`（`finish()` 里）：打字机还要吐几秒，先把全文落库 —— 这几秒里
    ///   App 被切掉也不该只剩半截话。此时用量还没定，传 `nil`；
    /// - `finalizeStreamingText`（打字机吐完）：带上 `usage` 再写一次，**覆盖**上一次，幂等。
    ///
    /// `reasoning` 同理会话事务：思考在正文之前就收完了，`persistFullTextNow` 那次已带上
    /// （`or: .replace`，收尾再覆盖一次同样的内容）。
    ///
    /// 合并前这两个调用点一共产生 5 次独立提交（`updateMessage` ×2 + `saveUsage` + `touchConversation` ×2），
    /// 现在各 1 次。
    ///
    /// - Note: 与 `appendMessages` 同一条规矩 —— 事务闭包里只用原语，语句在闭包外构造好。
    public func finalizeMessage(conversationId: UUID,
                                title: String?,
                                messageId: UUID,
                                text: String,
                                kind: AIBlockKind,
                                usage: AITokenUsage?,
                                reasoning: AIReasoning?) {
        guard ready else { return }
        let messageUpdate = messages.filter(mId == messageId.uuidString)
            .update(mText <- text, mKind <- Self.kindValue(kind))
        var usageInsert: Insert?
        if let usage, !usage.isEmpty {
            usageInsert = buildUsageInsert(messageId: messageId,
                                           conversationId: conversationId,
                                           usage: usage)
        }
        var reasoningInsert: Insert?
        // 与用量同一条规矩：**只给真正有正文的回复**写思考。失败提示、空回复不带
        // （kind 不是 .text 时调用方传的就是 nil，这里再兜一次）
        if kind == .text, let reasoning, !reasoning.isEmpty {
            reasoningInsert = buildReasoningInsert(messageId: messageId,
                                                   conversationId: conversationId,
                                                   reasoning: reasoning)
        }
        let now = Date().timeIntervalSince1970
        let conversationUpdate: Update
        if let title {
            conversationUpdate = conversations.filter(cId == conversationId.uuidString).update(
                cTitle <- title, cUpdatedAt <- now
            )
        } else {
            conversationUpdate = conversations.filter(cId == conversationId.uuidString).update(
                cUpdatedAt <- now
            )
        }
        do {
            try SQLiteManager.shared.transaction {
                try SQLiteManager.shared.executeUpdate(messageUpdate)
                if let usageInsert {
                    try SQLiteManager.shared.executeInsert(usageInsert)
                }
                if let reasoningInsert {
                    try SQLiteManager.shared.executeInsert(reasoningInsert)
                }
                try SQLiteManager.shared.executeUpdate(conversationUpdate)
            }
        } catch {
            debugPrint("[AIChatStore] 回写消息收尾失败（已回滚）: \(error)")
        }
    }

    // MARK: - 用量（token / 计价）

    /// 写入（或覆盖）某条助手消息的用量。以消息 id 为主键，重复写入即覆盖 ——
    /// 重新生成同一轮时会用新 id，不会命中旧行。
    public func saveUsage(messageId: UUID, conversationId: UUID, usage: AITokenUsage) {
        guard ready, !usage.isEmpty else { return }
        do {
            try SQLiteManager.shared.insert(
                buildUsageInsert(messageId: messageId, conversationId: conversationId, usage: usage)
            )
        } catch {
            debugPrint("写入 token 用量失败: \(error)")
        }
    }

    // MARK: - 引用

    /// 写入某条消息的引用（`nil` 时什么都不做；重复写入即覆盖）。
    ///
    /// **不返回成败**：引用是消息的附属信息，写失败时消息本身仍然完整（只是重启后少一条引用条），
    /// 不该因为它把整条发送链路判失败 —— 那会让用户以为「消息没发出去」。
    public func saveQuote(messageId: UUID, conversationId: UUID, quote: AIQuote?) {
        guard ready, let quote else { return }
        let insert = quotes.insert(
            or: .replace,
            qMessageId <- messageId.uuidString,
            qConversationId <- conversationId.uuidString,
            qQuotedMessageId <- quote.messageId.uuidString,
            qQuotedRole <- (quote.role == .user ? 0 : 1),
            qQuotedText <- quote.text,
            qCreatedAt <- Date().timeIntervalSince1970
        )
        do {
            try SQLiteManager.shared.insert(insert)
        } catch {
            debugPrint("写入 AI 引用失败: \(error)")
        }
    }

    /// 某个会话的引用表：`message_id → 引用`（key 用库里的字符串形式，直接用 `r[mId]` 查）
    private func quoteMap(conversationId: UUID) -> [String: AIQuote] {
        guard let rows = try? SQLiteManager.shared.search(
            quotes, filter: qConversationId == conversationId.uuidString, limit: nil, offset: nil
        ) else { return [:] }
        var map: [String: AIQuote] = [:]
        for row in rows {
            // 被引用 id 非法时用一个「不可能存在」的 UUID 兜底：正文快照还在，
            // 引用条照样显示，只是点击跳转会落到 `revealMessage` 的「已不在当前会话里」提示
            let quotedId = UUID(uuidString: row[qQuotedMessageId]) ?? Self.unresolvableMessageId
            map[row[qMessageId]] = AIQuote(messageId: quotedId,
                                           role: row[qQuotedRole] == 0 ? .user : .assistant,
                                           text: row[qQuotedText])
        }
        return map
    }

    /// 兜底用的「定位不到」的消息 id（全零）。真实消息 id 由 `UUID()` 生成，不会命中它。
    private static let unresolvableMessageId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    // MARK: - @ 项目资料

    /// 某个会话的 @ 资料表：`message_id → [资料]`（**顺序按 `idx`**，与用户挑的顺序一致）。
    private func mentionMap(conversationId: UUID) -> [String: [AIMention]] {
        guard let rows = try? SQLiteManager.shared.search(
            mentions,
            filter: nConversationId == conversationId.uuidString,
            orderBy: nIndex.asc,
            limit: nil,
            offset: nil
        ) else { return [:] }
        var map: [String: [AIMention]] = [:]
        for row in rows {
            // 资料 id 坏了不影响展示（名字与存储标识才是渲染与读取要用的）——
            // 与 `quoteMap` 的兜底同理，这里干脆用一个新 UUID：它只用于「点待发条定位」。
            let fileId = UUID(uuidString: row[nMentionFileId]) ?? UUID()
            let mention = AIMention(projectFileId: fileId,
                                    displayName: row[nMentionName],
                                    storageName: row[nMentionStorage],
                                    byteSize: row[nMentionSize])
            map[row[nMessageId], default: []].append(mention)
        }
        return map
    }

    /// 某个会话的思考表：`message_id → 思考`（key 用库里的字符串形式，直接用 `r[mId]` 查）。
    ///
    /// 空正文的行按「没有」处理（`nil`）—— 渲染判据 `isEmpty` 与之一致，
    /// 别把一条空思考挂上行（那会画出一个空壳子）。
    private func reasoningMap(conversationId: UUID) -> [String: AIReasoning] {
        guard let rows = try? SQLiteManager.shared.search(
            reasonings, filter: gConversationId == conversationId.uuidString, limit: nil, offset: nil
        ) else { return [:] }
        var map: [String: AIReasoning] = [:]
        for row in rows {
            let reasoning = AIReasoning(text: row[gText], duration: row[gDuration])
            guard !reasoning.isEmpty else { continue }
            map[row[gMessageId]] = reasoning
        }
        return map
    }

    /// 某个会话的用量表：`message_id → 用量`（key 用库里的字符串形式，直接用 `r[mId]` 查）
    private func usageMap(conversationId: UUID) -> [String: AITokenUsage] {
        guard let rows = try? SQLiteManager.shared.search(
            usages, filter: uConversationId == conversationId.uuidString, limit: nil, offset: nil
        ) else { return [:] }
        var map: [String: AITokenUsage] = [:]
        for row in rows {
            map[row[uMessageId]] = usage(from: row)
        }
        return map
    }

    /// `ai_usage` 一行 → `AITokenUsage`。`usageMap` 与 `usageTotal` 共用这一份映射，
    /// 免得两处对列的理解（尤其可空的缓存拆分两列）出现分歧。
    ///
    /// ⚠️ 必须是**实例方法**：列表达式（`uPromptTokens` 等）是实例属性，`static` 里取不到。
    private func usage(from row: Row) -> AITokenUsage {
        AITokenUsage(
            promptTokens: row[uPromptTokens],
            completionTokens: row[uCompletionTokens],
            totalTokens: row[uTotalTokens],
            cacheHitTokens: row[uCacheHitTokens],
            cacheMissTokens: row[uCacheMissTokens]
        )
    }

    /// 全库累计用量（设置页用）。
    ///
    /// 全表扫一遍：个人使用量级（几千行）下毫秒级，不值得为此加聚合表
    /// （聚合表就得处理「删会话要减、清空要归零」的一致性，得不偿失）。
    ///
    /// ⚠️ **累加规则不在这里** —— 走 `AIUsageTotal.summing(_:)`（含 `requestsWithoutCacheSplit`
    /// 的判定）。抽出来是为了「全库累计」与将来任何按会话 / 按轮的聚合共用一份，不各写一套。
    public func usageTotal() -> AIUsageTotal {
        guard ready,
              let rows = try? SQLiteManager.shared.search(usages, limit: nil, offset: nil) else {
            return AIUsageTotal()
        }
        return AIUsageTotal.summing(rows.map { usage(from: $0) })
    }

    /// 清空累计用量（只删统计，不动消息与会话）
    ///
    /// 清的是**设置页那组数字**（`ai_usage` 全表求和）。消息自身的 `block.usage` 不受影响 ——
    /// 那是「这一轮真实花了多少」的事实，只是聊天页不再显示它（2026-09-17 撤掉了用量展示）。
    /// 「把统计清零」不该等于「改写历史」。
    public func clearUsage() {
        guard ready else { return }
        do {
            // 无条件 DELETE（不带 WHERE 的 Expression 接口没有对应的删法），走原始 SQL 原语
            try SQLiteManager.shared.executeRawThrows("DELETE FROM \(usageTableName)")
        } catch {
            debugPrint("清空 token 用量失败: \(error)")
        }
    }

    // MARK: - 删除指定消息（重新生成 / 重试用）

    /// 删除某会话里的若干条**指定消息**（连同它们的用量行与**沙盒附件文件**），事务保证原子性。
    ///
    /// 三个调用方都汇到这里：多选删除、`regenerate` 撤掉旧回复、`editAndResend` 截断重发。
    /// 后两条会连带删掉**用户自己发的图片 / 文件行**（截断是从目标行一路到末尾），
    /// 所以附件回收必须做在这里 —— 只在 `deleteConversation` 里做是不够的。
    ///
    /// 与 `deleteConversation` 的区别：只删几条，会话本身与 seq 都不动
    /// —— seq 只用于「载入时的排序」，留空洞不影响顺序，补写新消息时又会取 max+1，
    /// 所以不必重排（重排反而要多一次全表 UPDATE，且中断时会留下重复 seq）。
    public func deleteMessages(conversationId: UUID, ids: [UUID]) {
        guard ready, !ids.isEmpty else { return }
        // 先把这批消息引用到的**本地附件**记下来 —— 库删完就再也查不出来了，
        // 那些图片 / 文件会永远留在沙盒里变成孤儿（与 `deleteConversation` 同一个理由）。
        // ⚠️ 必须收在事务**之前**：那时行还在，查得到；进事务后行已删，再查就是空的了。
        let attachmentURLs = referencedAttachments(messageIds: ids)
        let idList = ids.map { "'\($0.uuidString)'" }.joined(separator: ",")
        // 会话计数递减也放进同一事务（原来是事务提交后再来一次 SELECT+UPDATE 的读改写）：
        // 库删了、计数没减的中间态从根上不存在了。自引用更新，不必先读当前值。
        let countExpression = clampedCount(delta: -ids.count)
        let conversationUpdate = conversations.filter(cId == conversationId.uuidString)
            .update(cMessageCount <- countExpression)
        do {
            try SQLiteManager.shared.transaction {
                try SQLiteManager.shared.executeRawThrows(
                    "DELETE FROM \(messageTableName) WHERE id IN (\(idList))"
                )
                try SQLiteManager.shared.executeRawThrows(
                    "DELETE FROM \(usageTableName) WHERE message_id IN (\(idList))"
                )
                // 只删「这些消息自己发出的引用」。**不删别人对它们的引用**：
                // 引用存的是正文快照，被引用那条没了也照样显示得出来（点击跳转会提示已不在）。
                // 反向清理反而会让「重新生成把回复撤掉」顺带抹掉更早那条提问上的引用条。
                try SQLiteManager.shared.executeRawThrows(
                    "DELETE FROM \(quoteTableName) WHERE message_id IN (\(idList))"
                )
                // @ 资料行同理（主键是自造的 `messageId#idx`，所以只能按 message_id 列删）
                try SQLiteManager.shared.executeRawThrows(
                    "DELETE FROM \(mentionTableName) WHERE message_id IN (\(idList))"
                )
                // 思考行同主键 1:1，跟着消息一起走
                try SQLiteManager.shared.executeRawThrows(
                    "DELETE FROM \(reasoningTableName) WHERE message_id IN (\(idList))"
                )
                // 模型切换系统消息同理：撤销那条消息时（规则 ①）它必须一起消失
                try SQLiteManager.shared.executeRawThrows(
                    "DELETE FROM \(modelSwitchTableName) WHERE message_id IN (\(idList))"
                )
                try SQLiteManager.shared.executeUpdate(conversationUpdate)
            }
        } catch {
            debugPrint("删除 AI 消息失败: \(error)")
            // 库没删干净就别动文件：界面可能还要继续引用它们（同 `deleteConversation`）
            return
        }
        // 落库成功后才清磁盘（`remove` 对已经不存在的文件是空操作）
        attachmentURLs.forEach { AIAttachmentStorage.remove(at: $0) }
    }

    // MARK: - 私有辅助

    /// 把一行消息映射为内容块；数据不完整（如图片 URL 缺失）时返回 nil，由调用方跳过
    private static func block(from row: Row,
                              id: UUID,
                              isUser: Bool,
                              kind: Expression<Int>,
                              text: Expression<String>,
                              imageURL: Expression<String?>,
                              videoURL: Expression<String?>,
                              coverURL: Expression<String?>) -> AIBlock? {
        switch row[kind] {
        case 1:
            guard let u = AIAttachmentStorage.resolve(row[imageURL]) else { return nil }
            // 尺寸**只给用户发出的图**：它决定行高（按真实宽高比）；助手侧的图固定 16:9，不必读盘。
            // `pixelSize` 只读图片头信息、不解码像素，载入一整屏历史也不会卡。
            return AIBlock(id: id,
                           kind: .image,
                           imageURL: u,
                           mediaSize: isUser ? AIAttachmentStorage.pixelSize(of: u) : nil)
        case 2:
            guard let u = AIAttachmentStorage.resolve(row[videoURL]) else { return nil }
            return AIBlock(id: id,
                           kind: .video,
                           videoURL: u,
                           videoCoverURL: AIAttachmentStorage.resolve(row[coverURL]))
        case 3:
            let notice = row[text].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !notice.isEmpty else { return nil }
            return AIBlock(id: id, kind: .error, text: notice)
        case 5:
            // 模型切换系统消息（kind 5，2026-10-21）。正文就是渲染好的文案
            // （`AIModelSwitch.noticeText` 写入那一刻的那份）；结构化数据由
            // `loadConversation` 从 `ai_model_switch` 补上 —— 补不上时渲染照常
            // （`AIBlock.modelSwitchText` 优先现算），只是两条显示规则不再成立。
            let notice = row[text].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !notice.isEmpty else { return nil }
            return AIBlock(id: id, kind: .modelSwitch, text: notice)
        case 4:
            // 文件附件：路径在 image_url 列，文件名在 text 列；大小不入库，从磁盘现算
            guard let u = AIAttachmentStorage.resolve(row[imageURL]) else { return nil }
            return AIBlock(id: id,
                           kind: .file,
                           text: row[text],
                           fileURL: u,
                           fileSize: AIAttachmentStorage.byteSize(of: u))
        default:
            // 空正文的文本块没有任何信息量：流式占位行在「一个字都没收到就中断」时会留下空文本，
            // 直接跳过，避免重开对话或重启后又冒出一个空气泡
            let body = row[text].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return AIBlock(id: id, kind: .text, text: row[text])
        }
    }

    // MARK: - INSERT 构造（只造语句，不碰数据库）

    /// 构造一条消息的 INSERT。
    ///
    /// ⚠️ `seq` 由调用方传入，**不在这里读**：批量场景下每行都读一次就成了 N 次查询，
    /// 而且事务闭包里读不到正确的视图（见 `appendMessages`）。
    private func buildMessageInsert(_ row: AIChatRow, conversationId: UUID, seq: Int) -> Insert {
        let id = row.block.id
        let text = row.block.text
        // image_url 这一列同时承载「图片路径」和「文件附件路径」——两者不会出现在同一行，
        // 复用同一列就省掉了一次表结构迁移（见 kindValue 里的说明）。
        // 本地附件经 `storedPath` **只存文件名**，绝对路径会随沙盒容器变化而失效。
        let mediaPath = (row.block.imageURL ?? row.block.fileURL).map(AIAttachmentStorage.storedPath(for:))
        let videoURL = (row.block.videoURL).map(AIAttachmentStorage.storedPath(for:))
        let coverURL = (row.block.videoCoverURL).map(AIAttachmentStorage.storedPath(for:))
        return messages.insert(
            or: .replace,
            mId <- id.uuidString,
            mConversationId <- conversationId.uuidString,
            mSeq <- seq,
            mRole <- (row.role == .user ? 0 : 1),
            mKind <- Self.kindValue(row.block.kind),
            mText <- text,
            mImageURL <- mediaPath,
            mVideoURL <- videoURL,
            mVideoCoverURL <- coverURL,
            // 用行上的时间而不是 `Date()`：两者若有偏差，重启后消息会整体「挪一下」
            // （时间分隔线是按这个值算的，偏差跨过 5 分钟阈值就会出现/消失一条分隔线）
            mCreatedAt <- row.createdAt.timeIntervalSince1970
        )
    }

    /// 构造一条引用的 INSERT；这条消息没有引用时返回 `nil`
    ///
    /// 引用与消息在**同一个事务**里写：它们表达的是同一件事（这条消息引用了谁）。
    /// 分开写会留下「消息在、引用丢」的窗口，重启后那条消息就没了引用条，而用户记得自己引用过。
    private func buildQuoteInsert(_ row: AIChatRow, conversationId: UUID) -> Insert? {
        guard let quote = row.block.quote else { return nil }
        return quotes.insert(
            or: .replace,
            qMessageId <- row.block.id.uuidString,
            qConversationId <- conversationId.uuidString,
            qQuotedMessageId <- quote.messageId.uuidString,
            qQuotedRole <- (quote.role == .user ? 0 : 1),
            qQuotedText <- quote.text,
            qCreatedAt <- Date().timeIntervalSince1970
        )
    }

    /// 构造「这条消息 @ 了哪些资料」的 INSERT 组；没有 @ 时返回空数组。
    ///
    /// 与引用同事务写入（理由同 `buildQuoteInsert`）：它们都是「这条消息自己的一份事实」，
    /// 分开写会留下「消息在、资料丢」的窗口 —— 而用户记得自己 @ 过那几份。
    ///
    /// ⚠️ 主键是**自造的** `"<messageId>#<idx>"`（见 `mentionTableName`）：
    ///    一条消息可带多份，而 `getTable` 那套 builder 只认单列主键。
    ///    序号用数组下标 —— 它同时就是「用户挑选的顺序」，注入上下文时照着这个顺序拼。
    private func buildMentionInserts(_ row: AIChatRow, conversationId: UUID) -> [Insert] {
        // 只有用户文本行才带（与渲染、注入两处的判据同源，见 `AIBlock.mentions` 的说明）
        guard row.role == .user, row.block.kind == .text, !row.block.mentions.isEmpty else { return [] }
        let messageId = row.block.id.uuidString
        let now = Date().timeIntervalSince1970
        return row.block.mentions.enumerated().map { index, mention in
            mentions.insert(
                or: .replace,
                nId <- "\(messageId)#\(index)",
                nMessageId <- messageId,
                nConversationId <- conversationId.uuidString,
                nIndex <- index,
                nMentionFileId <- mention.projectFileId.uuidString,
                nMentionName <- mention.displayName,
                nMentionStorage <- mention.storageName,
                nMentionSize <- mention.byteSize,
                nCreatedAt <- now
            )
        }
    }

    /// 构造一条用量的 INSERT（主键 = 消息 id，重复写入即覆盖）
    private func buildUsageInsert(messageId: UUID, conversationId: UUID, usage: AITokenUsage) -> Insert {
        usages.insert(
            or: .replace,
            uMessageId <- messageId.uuidString,
            uConversationId <- conversationId.uuidString,
            uPromptTokens <- usage.promptTokens,
            uCompletionTokens <- usage.completionTokens,
            uTotalTokens <- usage.totalTokens,
            uCacheHitTokens <- usage.cacheHitTokens,
            uCacheMissTokens <- usage.cacheMissTokens,
            uCreatedAt <- Date().timeIntervalSince1970
        )
    }

    /// 构造一条思考的 INSERT（主键 = 消息 id，重复写入即覆盖）。
    ///
    /// 只在 `finalizeMessage` 里用（与正文同一个事务）—— 流式期间不落库，
    /// 思考在正文之前就收完了，`persistFullTextNow` 那次已带上，收尾再覆盖一次。
    private func buildReasoningInsert(messageId: UUID, conversationId: UUID, reasoning: AIReasoning) -> Insert {
        reasonings.insert(
            or: .replace,
            gMessageId <- messageId.uuidString,
            gConversationId <- conversationId.uuidString,
            gText <- reasoning.text,
            gDuration <- reasoning.duration,
            gCreatedAt <- Date().timeIntervalSince1970
        )
    }

    /// 构造一条「模型切换」的 INSERT（主键 = 消息 id，重复写入即覆盖）。
    ///
    /// 与消息同事务写（理由同 `buildQuoteInsert`）：两者表达的是同一件事。
    /// 只有 `.modelSwitch` 行**且带结构化数据**时才有一行 —— 后者缺失说明是退化数据，
    /// 不必造一行空的（`loadConversation` 读不到就是「规则不成立」）。
    private func buildModelSwitchInsert(_ row: AIChatRow, conversationId: UUID) -> Insert? {
        guard row.block.kind == .modelSwitch, let record = row.block.modelSwitch else { return nil }
        return modelSwitches.insert(
            or: .replace,
            sMessageId <- row.block.id.uuidString,
            sConversationId <- conversationId.uuidString,
            sFromId <- record.fromID,
            sToId <- record.toID,
            sFromName <- record.fromName,
            sToName <- record.toName,
            sCreatedAt <- Date().timeIntervalSince1970
        )
    }

    /// 某个会话的模型切换表：`message_id → 记录`（key 用库里的字符串形式，直接用 `r[mId]` 查）。
    ///
    /// 一次性读全（按 conversation_id 索引）—— 与 `usageMap` / `reasoningMap` 同一条路径，
    /// ⛔ 别改成逐行查库。
    private func modelSwitchMap(conversationId: UUID) -> [String: AIModelSwitch] {
        guard let rows = try? SQLiteManager.shared.search(
            modelSwitches, filter: sConversationId == conversationId.uuidString, limit: nil, offset: nil
        ) else { return [:] }
        var map: [String: AIModelSwitch] = [:]
        for row in rows {
            map[row[sMessageId]] = AIModelSwitch(fromID: row[sFromId],
                                                 toID: row[sToId],
                                                 fromName: row[sFromName],
                                                 toName: row[sToName])
        }
        return map
    }

    /// 规则 ② 的回写：「A→B 之后又切 C ⇒ 只显示 A→C」。
    ///
    /// **改两处、一个事务**：`ai_message.text`（新文案）与 `ai_model_switch.to_id` /
    /// `to_name`（新目的地）。不接受两次独立提交 —— 那会留下「文案已改、记录没改」
    /// （或反过来）的中间态，重启后两条显示规则就照着错的那半边判。
    ///
    /// `from_id` / `fromName` **不动**：这一条要表现的正是「从最初的 A 一路走到 C」。
    /// ⚠️ 刻意**不 touch 会话的 `updatedAt`**：切换模型不是「聊过」，不该把会话顶到列表最前
    ///    （同 `deleteMessages(withIds:)` 里那条理由）。
    /// - Parameters:
    ///   - messageId: 那条系统消息自己的 id
    ///   - text: 新文案（调用方用改完后的 `AIModelSwitch.noticeText` 现算）
    ///   - toID / toName: 新的目的地（那一刻的快照）
    public func rewriteModelSwitch(messageId: UUID, text: String, toID: String, toName: String) {
        guard ready else { return }
        // 语句在闭包外构造好（同 `appendMessages` / `finalizeMessage` 的规矩：
        // 事务闭包里只放原语）
        let messageUpdate = messages.filter(mId == messageId.uuidString)
            .update(mText <- text)
        let switchUpdate = modelSwitches.filter(sMessageId == messageId.uuidString)
            .update(sToId <- toID, sToName <- toName)
        do {
            try SQLiteManager.shared.transaction {
                try SQLiteManager.shared.executeUpdate(messageUpdate)
                try SQLiteManager.shared.executeUpdate(switchUpdate)
            }
        } catch {
            debugPrint("[AIChatStore] 改写模型切换系统消息失败（已回滚）: \(error)")
        }
    }

    /// 构造一条会话的 INSERT（`or: .replace` 语义 = 存在则整行覆盖）
    private func buildConversationInsert(_ conversation: AIConversation, messageCount: Int) -> Insert {
        conversations.insert(
            or: .replace,
            cId <- conversation.id.uuidString,
            cTitle <- conversation.title,
            cCreatedAt <- conversation.createdAt.timeIntervalSince1970,
            cUpdatedAt <- conversation.updatedAt.timeIntervalSince1970,
            cMessageCount <- messageCount,
            // 🔴 `project_id` **必须一起写**（2026-10-25 用户实测 bug 的根因）：
            // 漏了它，「先归入项目、后发第一条消息」这条真实路径会静默丢归属 ——
            // `setConversationProject` 的 UPDATE 打在还没落库的行上是 no-op（只改了内存），
            // 等首条消息触发这里的 `.replace` 建行时，project_id 被写成 NULL ⇒
            // 重启后会话掉出项目组，「+」面板也没有「项目资料」格（不报错、无迹象）。
            // ⚠️ 两个调用点（`createConversation` / `appendMessages` 首条消息）都走这里，
            // 所以只改这一处；`.replace` 语义还会覆盖整行，更不能漏。
            cProjectId <- conversation.projectId?.uuidString
        )
    }

    private static func kindValue(_ kind: AIBlockKind) -> Int {
        switch kind {
        case .text:  return 0
        case .image: return 1
        case .video: return 2
        case .error: return 3
        // 4 = 用户文件附件。**没有新增列**：路径复用 `image_url`，文件名复用 `text`
        // （两者与图片行不会同时出现）。改表结构要写「结构探测 + 幂等 ALTER」，
        // 而迁移正是历史上出过静默故障的地方 —— 能复用就复用。
        case .file:  return 4
        // 5 = 模型切换系统消息。同样**没有新增列**：文案复用 `text`，
        // 「从哪切到哪」走新表 `ai_model_switch`（⛔ 别为了它给 `ai_message` 加列）。
        case .modelSwitch: return 5
        }
    }

    /// 某个会话引用到的本地附件路径。用于删除会话时一并清理沙盒
    /// —— 库里删掉之后这些路径就再也找不回来了。
    private func referencedAttachments(conversationId: String) -> [URL] {
        guard let rows = try? SQLiteManager.shared.search(
            messages, filter: mConversationId == conversationId, limit: nil, offset: nil
        ) else { return [] }
        return localAttachmentURLs(in: rows)
    }

    /// 指定的这批消息引用到的本地附件路径（`deleteMessages` 用）。
    ///
    /// ⚠️ 调用方必须在**事务之前**调它：那时行还在，查得到；事务里也**不能**查
    ///（`search` 会再 `dbQueue.sync` 一次 → 嵌套死锁）。
    private func referencedAttachments(messageIds: [UUID]) -> [URL] {
        guard !messageIds.isEmpty else { return [] }
        // `[String].contains(Expression)` 就是 SQL 的 `IN (...)`（SQLite.swift 的集合重载）
        let ids = messageIds.map(\.uuidString)
        guard let rows = try? SQLiteManager.shared.search(
            messages, filter: ids.contains(mId), limit: nil, offset: nil
        ) else {
            // ⛔ 别写成裸 `try?` 就了事：查失败会**静默退化成「不回收」**，
            // 而这一趟库还是要删的 —— 结果是留一堆谁也不知道的孤儿文件。
            // 至少让它在控制台说话（回收失败不影响删除本身，所以不 throw、不阻断）
            debugPrint("[AIChatStore] 查询待删消息的附件失败，这批消息的附件将不会被回收")
            return []
        }
        return localAttachmentURLs(in: rows)
    }

    /// 从消息行里摘出**本地**附件 URL。
    ///
    /// 只有 kind = 1（图片）/ 4（文件）带附件，且两类的路径都存在 `image_url` 列里
    /// —— 文件**没有新增列**，见 `kindValue` 那段注释。
    ///
    /// 这里显式滤掉非 `fileURL`：助手侧的图片 / 视频是**远程 URL**，`resolve` 对 http(s)
    /// 会照样返回一个 URL 对象（`remove` 靠 `fileExists` 兜得住，但「只删本地文件」这件事
    /// 应该在意图上说清楚，而不是靠下游恰好无害）。
    private func localAttachmentURLs(in rows: [Row]) -> [URL] {
        rows.compactMap { row -> URL? in
            guard row[mKind] == 1 || row[mKind] == 4,
                  let url = AIAttachmentStorage.resolve(row[mImageURL]),
                  url.isFileURL else { return nil }
            return url
        }
    }

    /// 当前会话下一个 seq（空会话返回 0）
    ///
    /// ⚠️ 在**事务外**调用（`appendMessages` 开头读一次）。批量追加的行是连续的，
    /// 所以读一次基线、内存里递增，不必每行各读一次。
    private func nextSeq(of conversationId: UUID) -> Int {
        let rows = try? SQLiteManager.shared.search(
            messages, filter: mConversationId == conversationId.uuidString, orderBy: mSeq.desc, limit: 1, offset: nil
        )
        return (rows?.first?[mSeq] ?? -1) + 1
    }
}
