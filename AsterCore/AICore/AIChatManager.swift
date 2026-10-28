import Foundation
import AIPlatform
import StarryKitCore

// MARK: - 流式管理器 Delegate

public protocol AIChatManagerDelegate: AnyObject {
    /// 插入了若干行（index 为当前对话 rows 的下标）
    func chatManagerDidInsertRows(_ manager: AIChatManager, at indexes: [Int])
    /// 流式文本刷新（只刷末 cell，不 reload 整表）
    func chatManagerDidUpdateStreamingText(_ manager: AIChatManager, rowIndex: Int, text: String)
    /// 流式**思考过程**刷新（正文开始前，思考块自动展开着长）—— 只刷末行的思考子块。
    ///
    /// 与 `chatManagerDidUpdateStreamingText` 分开而不是复用那个：思考到达时正文还是空的，
    /// 复用会让「文本刷新」背上「配置思考块」的隐性职责，两边迟早漂移。
    func chatManagerDidUpdateStreamingReasoning(_ manager: AIChatManager, rowIndex: Int)
    /// 某文本块流式结束，需要整体渲染 markdown
    func chatManagerDidFinalizeRow(_ manager: AIChatManager, rowIndex: Int)
    /// 若干行的「附加结构」变了（如操作栏出现/收起）——需要 reload 这些行让布局跟上
    /// （行高已由 manager 重算，这里只负责让 cell 重新配置自己）
    func chatManagerDidUpdateRowLayout(_ manager: AIChatManager, atRowIndexes indexes: [Int])
    /// **整表内容被替换了**（删除若干行 + 新增占位行），增量刷新对不上，需要 `reloadData`。
    ///
    /// 目前只有「重新生成 / 重试」会走到：它先把该轮的旧回复整段撤掉再重新发，
    /// 一次删多行 + 加一行，`insertRows`/`deleteRows` 的组合既啰嗦又容易算错下标。
    func chatManagerDidReplaceRows(_ manager: AIChatManager)
    /// 整体结束
    func chatManagerDidFinish(_ manager: AIChatManager)
    /// 出错
    func chatManager(_ manager: AIChatManager, didError error: Error)
    /// 这一轮因为**上下文超预算**丢掉了最早的若干条消息（见 `AIContextBudget`）。
    ///
    /// 只提示、不阻止：裁多裁少都是**估算**（本工程没有 tokenizer），拿估算去拦请求
    /// 会把本来发得出去的内容挡在门外，那比让服务端自己报错更糟。
    ///
    /// - Parameters:
    ///   - droppedCount: 丢掉的条数
    ///   - isOverBudget: 裁到只剩「首条 + 当前提问」**仍然**超窗口 —— 这一轮可能被服务端拒掉
    func chatManager(_ manager: AIChatManager, didTrimContext droppedCount: Int, isOverBudget: Bool)
}

// MARK: - 流式管理器

/// 负责：持有「当前活跃会话」、复用 SSEClient 收流、消费 `AIProvider` 解析出的 UI 事件，
/// 并驱动 UI（打字机节奏）与落库。
///
/// 平台差异（请求怎么构 / 流怎么解析）全在 `AIProvider`；本类只认「事件」，
/// 因此换平台（本地 mock ↔ DeepSeek）不需要改这里。
///
/// **到达与上屏解耦**（流式的关键）：网络怎么给数据完全不受控——本地 mock 是一字一帧、
/// 慢慢 sleep 着发；真实平台可能一帧带好几个字、也可能攒到最后一次性发完。
/// 所以本类不把「收到的文本」直接丢上屏，而是先堆进 `receivedChars`，
/// 由 0.03s 一帧的打字机按节奏往外吐（`tickReveal`）——观感恒定是「从左往右逐字」。
///
/// 会话的持久化由 `AIChatStore` 承担，本类只决定「什么时候写」：
/// - 会话行在**首条消息发出时**才落库（因此对话列表里不会出现没内容的空会话）；
/// - 助手流式行先以空文本占位入库，**上屏结束后整条回写一次**（不跟着每一帧上屏写库）；
/// - 任何中断（切会话 / 新对话 / 页面消失）都会 `stop()`，把已收到的文本存下来。
///
/// - Note: 内存里只保留当前会话；历史会话按需从库里载入，避免全量常驻。
public final class AIChatManager {

    public weak var delegate: AIChatManagerDelegate?

    // MARK: - 会话状态

    private let store = AIChatStore.shared

    /// 当前活跃会话（始终存在；空会话表示「还没发过消息」）
    private var conversation = AIConversation()

    /// 当前会话是否已落库（首条消息发出后置 true）
    private var isPersisted = false

    /// **攒批模式**：非 `nil` 时 `appendRow` 只落内存、把行攒进这里，
    /// 由发起方在最后调一次 `store.appendMessages` 一次性写库。
    ///
    /// **为什么要有它**：一次「发送」会追加 2~4 行（附件行 + 文字行 + 助手占位行），
    /// 每行各写一次库 = 每行各一次磁盘提交。攒起来一次写完，一次点击从 ~7 次提交降到 1 次。
    ///
    /// ⚠️ 发起方必须保证「开了就一定会收」（用 `defer` 置回 `nil`）：
    /// 漏收会让**后续所有** `appendRow` 都只攒不写 —— 消息静默不入库，且不报任何错。
    /// ⚠️ 收的时机还有一个坑：必须**在 `startStreaming` 之前**收。配置类错误是同步回调的，
    /// 那条路会再 `appendRow` 一条失败提示行；攒批没收就会把它吞掉（气泡在、库里没有）。
    private var pendingAppends: [AIChatRow]?

    /// 当前会话 id
    public var activeConversationId: UUID { conversation.id }

    /// 当前会话标题（列表高亮 / 重命名后同步用）
    public var activeTitle: String { conversation.title }

    /// 当前会话所属项目（2026-10-25 起恒非 nil：默认项目「任务」兜底，
    /// 「未归类」已消灭；`nil` 只可能是 ensure 都没跑成的极端场景）。
    ///
    /// 两个消费方：① **项目级指令**（`effectiveSystemPrompt` 用它决定要不要覆盖全局提示词）；
    /// ② Mac 侧栏 / iOS 抽屉高亮「当前会话在哪一组」。
    public var activeProjectId: UUID? { conversation.projectId }

    /// **本轮**用户发送的文本（通知的「描述」用它，见 `AIReplyNotifier`）。
    ///
    /// ## 为什么不用 `activeTitle`
    /// 会话标题是**首条消息的第一句话**（见 `send` 里那段）⇒ 多轮对话后它一直是
    /// 「用户第一次问了什么」。通知要告诉用户的是「**你这一轮**问的什么有回复了」，
    /// 拿标题会文不对题（2026-10-19 用户实测反馈）。
    ///
    /// ## 记录点与语义
    /// - `send` / `editAndResend` 成功发起时记录（纯附件消息记占位文案，见
    ///   `attachmentTitlePlaceholder` —— 通知里显示「[图片]」也比空着好）；
    /// - `regenerate`（重新生成）**不覆盖**：那是对上一条提问的重跑，通知显示的
    ///   当然还是原来那条提问；
    /// - 切会话 / 新建不清零（`stop()` 会先中断在途的流，不会有人拿旧值发新通知）；
    /// - 配置校验失败的路径也记了（那一刻用户确实发了这段文本，失败通知同样适用）。
    public private(set) var latestUserPrompt: String = ""

    /// 当前会话的行
    public var rows: [AIChatRow] { conversation.rows }

    public var hasActiveConversation: Bool { !conversation.rows.isEmpty || isPersisted }

    /// 流式接口地址由 `AIConfig` 按当前平台提供（见 `AIProviderFactory`），
    /// 不再由外部注入——避免出现「设置页改了地址、实际请求还走旧值」的双份真相。

    /// 行高量算使用的宽度（默认取平台兜底值；布局后由 UI 层更新为真实容器宽度）
    ///
    /// - iOS: `AIModuleViewController` 在 `viewDidLayoutSubviews` 里灌 `size.width`（旋转时同步更新）
    /// - macOS: SwiftUI 侧由 `GeometryReader` 灌
    ///
    /// ⚠️ 默认值**不能是 0** —— 0 宽会让 `boundingRect` 把每行都算成超高，首帧会看到一串撑开的空行。
    /// 拆分前这里写的是 `UIScreen.main.bounds.width`，现在收进 `AIPlatformMetrics`（iOS 侧取值不变）。
    public var contentWidth: CGFloat = AIPlatformMetrics.defaultContainerWidth

    private var connection: SSEConnection?
    private var streamingRowIndex: Int?

    /// 网络侧已收到的完整正文，按 `Character` 拆好存着（避免上屏时把 emoji / 组合字符切开）。
    ///
    /// 这是**权威副本**：UI 上显示的永远只是它的一个前缀，收尾时整条落库。
    private var receivedChars: [Character] = []

    /// 已上屏到第几个字符（上屏内容恒等于 `receivedChars[0..<revealedCount]`）
    private var revealedCount = 0

    /// 文本块已结束（收到 mock 的 `end` 或整轮的 `done`），但**还不能收尾**——
    /// 要等打字机把尾巴补完。真实平台常常在流结束前才把整段一次性发过来，
    /// 「结束时立刻全量渲染」就等于没有流式效果。
    private var pendingFinalize = false

    /// 打字机节奏定时器（把「到达」与「上屏」解耦，见 `tickReveal`）
    private var revealTimer: Timer?

    /// 本轮流式收到的 token 用量（服务端在流末尾给）。
    ///
    /// 先攒在这里、收尾时才挂到那一行上：行在这一刻还可能被「空回复兜底」改成失败提示，
    /// 而一个失败提示不该带 token 数字（会让人以为「报错也扣了这么多」）。
    /// 每一轮开始（`startStreaming`）与收尾（`finalizeStreamingText`）都必须清掉 ±
    /// 漏清一次就会把上一轮的用量挂到下一轮的回复上。
    private var pendingUsage: AITokenUsage?

    /// 本轮思考开始的时刻（收到第一段 `reasoning_content` 时置位）。
    ///
    /// 只用来算「思考花了多久」：正文第一字流出（思考结束的信号）那一刻封住耗时，
    /// 写进行上的 `block.reasoning.duration`。每一轮开始（`startStreaming`）必须清掉 ±
    /// 漏清一次就会把上一轮的起点带到这一轮，耗时是个离谱的大数。
    ///
    /// 注意它**不是**「思考内容的缓冲」—— 内容直接逐段拼在进行中那行的
    /// `block.reasoning.text` 上（流式要实时显示，没处攒）。
    private var reasoningStartTime: Date?

    /// 是否正处于「一次已发起的流式接收」中。
    ///
    /// 收尾的三个入口（done 事件 / 连接关闭 / 报错）彼此重叠：Alamofire 在流失败时会先给一个
    /// `.failure` 事件、随后 `.complete` 里再带同一个 error，也就是**报两次错**。没有这个门禁
    /// 就会重复收尾（现在表现为多追加一条失败提示）。`stop()` 的空跑也因此变成零代价。
    ///
    /// ⚠️ **后台任务挂在它的 `didSet` 上**（见 `streamingBackgroundTask`）：置位即申请、
    /// 复位即交还。四个收尾点（done 事件 / `finish` / `handleError` / `stop`）各自把
    /// `isReceiving` 置 false，谁也不必记得去结束后台任务 —— 漏一处的表现是「那个任务
    /// 一直挂在系统手里」，静默且极难发现。这里多一个赋同样的值也不会重复申请（有 `!=` 门禁）。
    ///
    /// ☠️ **对账也挂在这个 didSet 上**（2026-10-19，`AIMissedRoundReconciler`）：
    /// 置位记 pending、复位清账。理由同上——四个收尾点经这一处全覆盖，比在
    /// `finish` / `handleError` / `stop` 各写一次漏不了。
    /// `public private(set)`：对账入口（两端 UI 层）要读「本进程还在不在收流」。
    public private(set) var isReceiving = false {
        didSet {
            guard isReceiving != oldValue else { return }
            if isReceiving {
                beginStreamingBackgroundTask()
                // 记账：这一轮若在 iOS 挂起中结束（完成事件丢失），回前台靠它补通知
                AIMissedRoundReconciler.recordStart(conversationId: conversation.id,
                                                    prompt: latestUserPrompt)
            } else {
                endStreamingBackgroundTask()
                AIMissedRoundReconciler.recordEnd()
            }
        }
    }

    /// 本轮是否收到过**服务端明确的结束信号**（`[DONE]`，或任一 `finish_reason`）。
    ///
    /// 只服务于结束判定（见 `isTruncated`）：连接关闭时它仍是 `false`，说明这一轮
    /// **不是正常收尾**（网关掐流 / 网络断了）—— 这种断流在界面上与「正常说完」长得一模一样。
    // MARK: - 联网检索状态（A 方案，2026-10-21）

    /// 本轮正在**联网检索**（发生在首字之前的 1.4–4.0 秒）。
    ///
    /// 🔴 为什么单开一位而不是复用 `isReceiving`：那一位的 `didSet` 会**申请后台任务**、
    /// 并且给对账器记一笔「这一轮开始了」—— 而检索阶段请求还没发出去，记下来的是一个
    /// **假的开始时间**（iOS 挂起后回前台，用户会收到一条凭空的「回复完成」通知）。
    ///
    /// 消费方：两端输入栏（显示「正在联网搜索…」）。订阅
    /// `didChangeWebSearchStateNotification`（`object` = 本 manager）。
    public private(set) var isSearchingWeb = false {
        didSet {
            guard isSearchingWeb != oldValue else { return }
            NotificationCenter.default.post(name: Self.didChangeWebSearchStateNotification,
                                            object: self)
        }
    }

    /// 联网检索状态变化。⛔ 别改成 delegate 方法：那要给两端实现 + 两个桩 + 夹具一起加，
    /// 而这件事只是「刷新一颗小转圈」，不值得动四处协议实现。
    public static let didChangeWebSearchStateNotification =
        Notification.Name("ai_chat_manager_web_search_state")

    /// 联网检索失败（**不影响这一轮回答**，只是「这次没搜成」）。
    ///
    /// ⛔ 别改走 `delegate.chatManager(_:didError:)`：那一位的语义是「这一轮失败了」，
    /// 会让占位行提前收尾、并插一条失败提示行 —— 而搜索失败应当**降级成普通对话**。
    /// 两端订它弹一条轻提示（Mac `ChatModel.show` / iOS toast）。
    public static let didFailWebSearchNotification =
        Notification.Name("ai_chat_manager_web_search_failed")

    /// 失败通知的 `userInfo` 键（`String`，人话原因）。
    public static let webSearchFailureKey = "message"

    /// 正在跑的那次检索（`stop()` 要能把它掐掉）。
    private var webSearchTask: Task<Void, Never>?

    // MARK: - 项目资料检索状态（RAG，2026-10-23）

    /// 本轮正在**检索项目资料**（发生在首字之前的几毫秒~几十毫秒）。
    ///
    /// 与 `isSearchingWeb` 同一条理由单开一位（⛔ 别复用 `isReceiving`）：那位
    /// 的 `didSet` 会申请后台任务、给对账器记「这一轮开始了」—— 检索阶段请求还没发。
    /// ⚠️ 2026-10-23 当晚放大镜入口下线后，`didChangeProjectSearchStateNotification`
    ///    **没有观察者了**（两端 UI 的订阅随入口一起删）⇒ 这条通知现在发出去没人听。
    ///    刻意保留：入口恢复（`VERIFY-PROBES.md` §32.4）时观察侧要加回来，
    ///    ⛔ 别顺手把 manager 这套也删了（那才是真正的底层）。
    public private(set) var isSearchingProject = false {
        didSet {
            guard isSearchingProject != oldValue else { return }
            NotificationCenter.default.post(name: Self.didChangeProjectSearchStateNotification,
                                            object: self)
        }
    }

    /// 项目资料检索状态变化（理由同 `didChangeWebSearchStateNotification`：别动 delegate）。
    public static let didChangeProjectSearchStateNotification =
        Notification.Name("ai_chat_manager_project_search_state")

    /// 项目资料检索失败（**不影响这一轮回答** —— 检索不到就普通对话，⛔ 别走 didError）。
    ///
    /// ⚠️ 本地库检索基本不会失败（读库失败在 store 内部就降级成空结果了），
    ///    这条通知主要给「索引重建失败 / 库没就绪」一个能对用户说的出口。
    public static let didFailProjectSearchNotification =
        Notification.Name("ai_chat_manager_project_search_failed")

    /// 失败通知的 `userInfo` 键（`String`，人话原因）。
    public static let projectSearchFailureKey = "message"

    /// 正在跑的那次项目资料检索（`stop()` 要能把它掐掉）。
    private var projectSearchTask: Task<Void, Never>?

    private var sawFinishSignal = false

    /// 服务端给的结束原因（OpenAI 兼容的 `finish_reason`；平台不给就是 `nil`）。
    /// `length` / `content_filter` 表示**明确没写完**。
    private var finishReason: String?

    /// 本轮是**出错**收尾的（由 `handleError` 置位）。
    ///
    /// 出错那行**不标**「被截断」：它已经有失败提示行与「重试」入口，再挂一个「继续生成」
    /// 只会让用户在两个入口之间犹豫 —— 而且网络刚断的那一刻，续写请求同样发不出去。
    private var endedByError = false

    /// 本轮「写完没有」的判定**落在了哪一行上**。
    ///
    /// 为什么需要记住它：`end`（正文结束）与「整轮结束」是**两个时刻** —— 本机 mock 的协议里
    /// 它们中间还夹着 `img` / `vid`（实测 `end` @4.44s、`done` @6.57s，**隔 2.13s**，
    /// 五张图片全落在这段里）。而正文一上屏完 `finalizeStreamingText` 就跑，那时结束信号
    /// 还在路上 ⇒ 判定必须能**在整轮真正结束时对同一行补一次**（见 `applyTruncationVerdict`）。
    /// 新一轮开始（`startStreaming`）会清掉，所以它只指向「当前这一轮」的收尾行。
    private var verdictRowIndex: Int?

    /// 已经就「上下文超预算」提示过的**会话 id**。
    ///
    /// 为什么要提示：上下文被裁掉最早的几轮之后，用户会看到模型「失忆」。
    /// 为什么要门禁：超预算是**持续状态**，之后每一轮都会裁，每轮都提示就成了噪音。
    ///
    /// 为什么记 id 而不是用布尔 + 四处复位：会话切换有四个入口
    /// （新建 / 冷启动恢复 / 切换 / 删除），漏掉一处复位就是「换了会话却再也不提示」；
    /// 挂 id 之后新会话天然不匹配，**不需要任何复位点**。
    private var contextTrimWarnedConversationId: UUID?

    public init() {}

    deinit { stop() }

    // MARK: - 对话管理

    /// 新建会话（中断并保存当前流式），回到「未落库」状态
    @discardableResult
    public func newConversation() -> UUID {
        stop()
        // 2026-10-25 起新会话**默认归入「任务」**（「未归类」已消灭）——
        // 落库时 createConversation 就把 project_id 写成它，不会出现 NULL 新行。
        conversation = AIConversation(projectId: AIChatStore.defaultProjectId)
        isPersisted = false
        // 未落库的新会话不作为冷启动恢复目标（重启后回到落地页）
        store.lastActiveConversationId = nil
        return conversation.id
    }

    /// 冷启动恢复：载入上次打开的会话
    /// - Returns: 成功载入返回 true（调用方据此直接进入对话态）
    @discardableResult
    public func restoreLastConversation() -> Bool {
        guard let id = store.lastActiveConversationId,
              let loaded = store.loadConversation(id: id) else { return false }
        conversation = loaded
        isPersisted = true
        recomputeAllRowHeights()
        return true
    }

    /// 切换到历史会话（中断并保存当前流式）
    /// - Returns: 会话存在并载入成功返回 true
    @discardableResult
    public func switchToConversation(id: UUID) -> Bool {
        stop()
        guard let loaded = store.loadConversation(id: id) else { return false }
        conversation = loaded
        isPersisted = true
        recomputeAllRowHeights()
        store.lastActiveConversationId = id
        return true
    }

    /// 对话列表（按更新时间倒序）；不经过 VC，菜单可直接取
    public func fetchSummaries() -> [AIConversationSummary] {
        store.fetchSummaries()
    }

    /// 搜索历史对话：**标题 + 全部消息正文**命中，标题命中排在前。
    ///
    /// 为什么在这里加一层薄转发（而不是让两端各自去够 `AIChatStore.shared`）：
    /// 与 `fetchSummaries()` / `usageTotal()` 同一套路 —— 两端只认管理器，
    /// 存储怎么查（SQL 长什么样、要不要加缓存）留在一个地方收口。
    /// Mac 侧搜索页走的就是它（`ChatModel.searchHistory(keyword:)`）。
    ///
    /// ⚠️ **同步、且会扫全库消息**（实现见 `AIChatStore.search`）。调用方负责防抖 ——
    ///    见 `MacSearchView` 里那段「为什么必须有抖动窗口」。
    /// - Note: 返回的 `AIChatSearchHit.messageId` 与 `AIChatBlock.id` 是**同一个 UUID**
    ///   （落库时就是它），所以命中消息能精确定位到列表里的某一行。
    public func search(keyword: String) -> [AIChatSearchHit] {
        store.search(keyword: keyword)
    }

    // MARK: - 用量统计（设置页用）

    /// 全库累计 token 用量。
    ///
    /// 口径：**当前库里还留着的助手回复之和** —— 删会话 / 重新生成会把对应记录一并清掉
    /// （见 `AIChatStore.deleteMessages` / `deleteConversation`）。
    /// 想要一份「从现在开始重新计」的账，用设置页的「清零」。
    public func usageTotal() -> AIUsageTotal { store.usageTotal() }

    /// 清空累计用量（只动统计，不影响任何对话内容）
    public func clearUsage() { store.clearUsage() }

    /// 置顶 / 取消置顶（只影响列表排序，不动更新时间）
    public func setConversationPinned(id: UUID, isPinned: Bool) {
        store.setPinned(id: id, isPinned: isPinned)
    }

    // MARK: - 项目（会话文件夹，2026-10-21）
    //
    // 与 `fetchSummaries()` / `search(keyword:)` 同一套路：两端只认管理器，
    // 存储怎么查留在 store 收口。Mac 侧 `ChatModel` 与 iOS 侧抽屉都走这些转发。

    /// 全部项目（按 sortOrder 升序）
    public func fetchProjects() -> [AIChatProject] {
        store.fetchProjects()
    }

    /// 新建项目（sortOrder 自动追加末尾）
    @discardableResult
    public func createProject(name: String, instruction: String = "") -> AIChatProject? {
        store.createProject(name: name, instruction: instruction)
    }

    /// 重命名项目（空名称忽略）
    public func renameProject(id: UUID, name: String) {
        store.renameProject(id: id, name: name)
    }

    /// 设置项目级系统提示词（空 = 回落全局）
    public func setProjectInstruction(id: UUID, instruction: String) {
        store.setProjectInstruction(id: id, instruction: instruction)
    }

    /// 读项目级系统提示词（L3；`nil` = 项目不存在，空串 = 没设 ⇒ 回落全局）
    public func projectInstruction(id: UUID) -> String? {
        store.projectInstruction(id: id)
    }

    /// 删除项目（会话解除归类、资料文件一并删，见 store 里的级联策略）
    public func deleteProject(id: UUID) {
        store.deleteProject(id: id)
        // 删的可能正是当前会话所在的项目 ⇒ 内存里的归属跟着落回默认项目「任务」，
        // 否则项目级指令 / 侧栏高亮会指着一个已经不存在的项目（静默错，不崩）
        if conversation.projectId == id { conversation.projectId = AIChatStore.defaultProjectId }
    }

    /// 移动会话到某项目（`projectId = nil` 归一成默认项目「任务」，
    /// 2026-10-25 起「未归类」已消灭；不动 updatedAt）
    public func setConversationProject(conversationId: UUID, projectId: UUID?) {
        store.setConversationProject(conversationId: conversationId, projectId: projectId)
        // 动的正是当前会话 ⇒ 内存里的 conversation 同步跟上（同样把 nil 归一）。
        // 否则项目级指令 / 侧栏高亮会慢一拍（要等下次切换会话才刷新）。
        if conversationId == conversation.id {
            conversation.projectId = projectId ?? AIChatStore.defaultProjectId
        }
    }

    /// 某项目的资料列表（时间倒序）
    public func fetchProjectFiles(projectId: UUID) -> [AIChatProjectFile] {
        store.fetchProjectFiles(projectId: projectId)
    }

    /// 导入外部文件为项目资料（落盘走 AIAttachmentStorage）。
    ///
    /// 🔴 导入成功**顺手建检索索引**（RAG，2026-10-23）：索引是派生物、建失败不阻断导入，
    ///    所以放在这里而不是让 UI 调第二次 —— 放 UI 那条路，「从别的入口加资料」
    ///    （比如以后的分享菜单导入）就会漏掉索引，而症状是「资料在、检索不到」。
    @discardableResult
    public func addProjectFile(projectId: UUID, sourceURL: URL) -> AIChatProjectFile? {
        guard let file = store.addProjectFile(projectId: projectId, sourceURL: sourceURL) else { return nil }
        store.indexProjectFile(file)
        return file
    }

    /// 删除项目资料（行 + 物理文件 + 检索片段，级联在 store 里）
    public func deleteProjectFile(id: UUID) {
        store.deleteProjectFile(id: id)
    }

    /// 某项目的索引状态（详情页「已索引 N/M · K 个片段」）
    public func projectIndexStatus(projectId: UUID) -> AIProjectIndexStatus {
        store.projectIndexStatus(projectId: projectId)
    }

    /// 重建一个项目的全部索引（详情页「重建索引」按钮；文件被外部改过时用）
    public func rebuildProjectIndex(projectId: UUID) {
        store.rebuildProjectIndex(projectId: projectId)
    }

    /// 从对话列表删除（连同消息）。
    /// - Returns: 删掉的正好是「当前打开的会话」时返回 true，调用方据此回到落地页
    @discardableResult
    public func deleteConversation(id: UUID) -> Bool {
        store.deleteConversation(id: id)
        guard conversation.id == id else { return false }
        stop()
        conversation = AIConversation()
        isPersisted = false
        store.lastActiveConversationId = nil
        return true
    }

    /// 重命名会话（只改标题，不影响列表排序）
    public func renameConversation(id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.renameConversation(id: id, title: trimmed)
        if conversation.id == id { conversation.title = trimmed }
    }

    // MARK: - 导出（分享会话用，2026-09-26 加）

    /// 把一个会话导出成**纯文本**，交给系统分享面板（`NSSharingServicePicker`）。
    ///
    /// 形状：
    /// ```
    /// 会话标题
    ///
    /// 我：……
    /// AI：……
    /// ```
    ///
    /// 几个刻意的地方：
    /// - **只挑 `.text`**（与 `contextMessages()` 同一取舍）：`.error`（「⚠️ 余额不足」这类）是
    ///   给**本人**看的失败交代，分享给别人没有意义；图片 / 文件 / 视频退化成
    ///   `[图片]` / `[文件] 名字` 这样的占位 —— ⛔ **绝不导出本机路径**（那是沙盒里的东西，
    ///   发出去只是一串对别人无意义的字符串）。
    /// - **当前会话优先读内存**（`conversation`）：那边可能有还没落库的最后几句
    ///   （`pendingAppends` 是攒着一批一起写的），直接读库会少一截尾巴；其余会话才 `loadConversation`。
    /// - 角色标签用「我 / AI」而不是「用户 / 助手」：这段文字是给**分享出去的对话**看的，
    ///   收的人不需要知道「助理」这种系统词。
    /// - Returns: 会话不存在、或一条可导出的内容都没有时返回 nil
    ///   （调用方据此给一句提示，别把空字符串丢给分享面板）。
    public func transcript(conversationId: UUID) -> String? {
        let source = conversation.id == conversationId
            ? conversation
            : store.loadConversation(id: conversationId)
        guard let source else { return nil }

        var lines: [String] = []
        for row in source.rows {
            let speaker = row.role == .user ? "我" : "AI"
            switch row.block.kind {
            case .text:
                let text = row.block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                lines.append("\(speaker)：\(text)")
            case .image:
                lines.append("\(speaker)：[图片]")
            case .file:
                let name = row.block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(name.isEmpty ? "\(speaker)：[文件]" : "\(speaker)：[文件] \(name)")
            case .video:
                lines.append("\(speaker)：[视频]")
            case .error:
                continue
            case .modelSwitch:
                // 系统的流水不是对话内容：分享出去的记录里塞一行「模型已从 A 更改为 B」
                // 只会让对面以为这是谁说过的一句话（与 `shareText` 同一口径）
                continue
            }
        }
        guard !lines.isEmpty else { return nil }
        return ([source.displayTitle, ""] + lines).joined(separator: "\n")
    }

    // MARK: - 发送

    /// 发送一条消息。
    /// - Parameters:
    ///   - prompt: 正文（可以为空 —— 只发附件）
    ///   - attachments: 随消息一起发出的图片 / 文件
    ///   - quote: 引用（引用某条历史消息后再提问）；只挂在**文本行**上
    ///   - mentions: 这一轮 `@` 进来的项目资料（2026-10-21）；同样只挂在文本行上。
    ///     超过 `AIMention.maxPerMessage` 的部分**直接丢弃**（防御式，UI 侧到上限就已禁用新增）
    /// - Returns: 是否成功发起。**配置类错误（缺 Key / 模型不收图）会返回 false**，
    ///   且是**同步**回调 `didError` 的 —— 调用方据此决定要不要保留输入区内容
    ///   （用户刚选好的图不该因为一个配置问题就被清掉）。
    @discardableResult
    public func send(_ prompt: String,
                     attachments: [AIAttachment] = [],
                     quote: AIQuote? = nil,
                     mentions: [AIMention] = []) -> Bool {
        stop()

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只 @ 了资料、一个字没打也要发得出去。
        // 正文回落成 `@文件名 @文件名` —— 那是**用户自己看得到的东西**（输入框里本来就有这串），
        // ⛔ 别回落到「[资料]」这类系统文案：对话里会留下一条自己没打过的消息。
        let onlyMentions = trimmed.isEmpty && !mentions.isEmpty
        let body = onlyMentions ? mentions.map { $0.token() }.joined() : trimmed
        guard !body.isEmpty || !attachments.isEmpty else { return false }

        // 先校验配置（缺 Key / 地址非法 / 没填模型 / 模型不收图）：
        // 失败就**不建行、不落库**直接报错，避免对话里留下一个永久空白的气泡
        let provider: AIProvider
        do {
            provider = try validatedProvider(for: attachments)
        } catch {
            delegate?.chatManager(self, didError: error)
            return false
        }

        // 对话标题默认取首条消息的第一句话；纯附件消息退化成占位文案
        if conversation.title.isEmpty {
            let source = body.isEmpty ? Self.attachmentTitlePlaceholder(for: attachments) : body
            conversation.title = Self.title(from: source)
        }
        // 🔴 本轮发送的文本（通知的「描述」读它，见 `latestUserPrompt` 文档）——
        //    与标题**同源不同值**：标题只认首条，这个每轮都更新。
        latestUserPrompt = body.isEmpty ? Self.attachmentTitlePlaceholder(for: attachments) : body
        // 落库时机：**整批留到这一拍的最后一次写**（见 `pendingAppends`）。
        // 建 / 更会话与下面那几行新消息会合进同一个事务，而不是各写各的。
        // 首条消息时把会话对象带下去 —— 计数直接写进建行语句，省掉一次补丁式 UPDATE。
        let creatingConversation: AIConversation?
        if isPersisted {
            creatingConversation = nil
        } else {
            conversation.updatedAt = Date()
            creatingConversation = conversation
            isPersisted = true
        }
        store.lastActiveConversationId = conversation.id

        // ⚠️ 用 `defer` 收尾：本方法后续若新增提前 return，漏收会让之后所有 appendRow 只攒不写
        pendingAppends = []
        defer { pendingAppends = nil }

        // 用户又开始新的提问 → 之前那些「没写完」的行不再提供「继续生成」：
        // 续写必须紧贴半截回复，跨过一个新提问去续写会落在错误的时间线上。
        //（`continueGeneration` 里有一条同样的 guard 兜底；这里清掉是为了不让菜单里
        //  出现一个「点了会被拒」的项）
        for i in conversation.rows.indices { conversation.rows[i].block.endedTruncated = false }

        // 用户消息 = 图片 → 文件 → 文字。
        // **图片排在文字前面**：与发给模型的 content 数组顺序一致（先看图再读要求）。
        for item in attachments where item.isImage {
            appendRow(.image(url: item.fileURL, mediaSize: item.pixelSize), role: .user)
        }
        for item in attachments where !item.isImage {
            appendRow(.file(url: item.fileURL, name: item.displayName, size: item.byteSize), role: .user)
        }
        if !body.isEmpty {
            // 引用 / @ 资料**都只挂在文本行**上：
            // ① 语义上它们是「针对这段文字提问 / 这轮参考这些资料」，图片 / 文件行没有正文；
            // ② 渲染路径只有用户文本 cell 有引用条（`AIChatRow.quoteHeightOrZero` 也只认文本行）。
            // 挂在别的行上会得到一个「高度算了、界面没画」的错位。
            var block = AIBlock.text(body)
            block.quote = quote
            // 条数上限在共享层再兜一次（UI 到达上限就禁用新增，正常路径到不了这里）
            block.mentions = Array(mentions.prefix(AIMention.maxPerMessage))
            appendRow(block, role: .user)
        }

        // 助手：先放一个空的流式文本块（同时占好 seq，结束时回写正文）
        let idx = appendRow(.text("", streaming: true), role: .assistant)
        // 🔴 先把攒批**收掉再写库，最后才发起请求**。顺序不能换：
        // `startStreaming` 里的配置类错误是**同步回调**的，那条路会 `appendRow` 追加一条失败提示行；
        // 若此刻还在攒批模式，那一行会被攒进数组、紧接着被 `defer` 清掉 —— 界面有气泡、库里没有。
        let batch = pendingAppends ?? []
        pendingAppends = nil
        // 这一拍的全部新行 + 会话行，一个事务写完（原来每行各一次提交）
        store.appendMessages(conversationId: conversation.id,
                             title: conversation.title,
                             rows: batch,
                             createConversation: creatingConversation)
        streamingRowIndex = idx
        // 走外层入口：开了联网搜索就先检索（这里是**新提问**，该搜）
        beginStreaming(provider: provider, query: trimmed)
        return true
    }

    // MARK: - 切换模型的系统消息（2026-10-21）

    /// 用户换了模型 ⇒ 在会话里记一条**居中系统消息**：「—— 模型已从 A 更改为 B ——」。
    ///
    /// 两条显示规则（用户原话）：
    /// ① A 切 B 之后**又切回 A** ⇒ **撤销**这条消息（整条删掉）；
    /// ② A 切 B 之后**又切 C** ⇒ **只显示「A 切换 C」**（改写，不是新增）。
    ///
    /// 🔴 两条规则的**唯一前提**是「末行就是这条系统消息」（其后一条消息都没有）。
    ///    中间聊过天 ⇒ 新插一条、老记录保留 —— 那更诚实，也不该把用户已经看过的内容改掉。
    /// ⚠️ 结构化记录丢了（老数据 / `ai_model_switch` 缺行）时同样按「新插一条」处理 ——
    ///    ⛔ 不靠文案前缀去猜「这条是不是同一条链上的」。
    ///
    /// ## 为什么不挂在 `AIModelStore.currentID` 的 setter 上
    /// 那个 setter 有**内部重写**（改名换 id / 删除后回落 / `ensureCurrent` 播种），
    /// 那些都不是「用户换模型」，不该长出系统消息。⇒ 挂载点只在两个**用户动作**处：
    /// Mac `ChatModel.selectChoice`、iOS 选择器的 `onPick`，由它们把切换前后的
    /// 两条配置传进来（名字在那一刻快照，见 `AIModelSwitch`）。
    ///
    /// - Parameters:
    ///   - from: 切换**前**那条（调用方在写指针之前取）
    ///   - to: 切换**后**那条
    public func noteModelSwitch(from: AICustomModel, to: AICustomModel) {
        // 点了当前已经选中的那一项 ⇒ 什么都不做（指针 setter 自己也不发广播，
        // 但那是「不广播」的口径，这里是「不长消息」的口径，两道闸各管一件事）
        guard from.id != to.id else { return }

        // 末行就是一条系统消息 ⇒ 两条规则都可能适用
        if let index = conversation.rows.indices.last,
           conversation.rows[index].block.kind == .modelSwitch,
           let record = conversation.rows[index].block.modelSwitch,
           // 「这条记录的目的地正是本次要离开的那个」= 同一条链上
           record.continuesFrom(from.id) {
            if record.returnsTo(to.id) {
                undoModelSwitchNotice(at: index)            // 规则 ①
            } else {
                rewriteModelSwitchNotice(at: index, to: to)  // 规则 ②
            }
            return
        }
        // 其余情况（没有系统消息 / 末行不是它 / 结构化数据丢了）⇒ 新插一条
        appendRow(.modelSwitch(AIModelSwitch(fromID: from.id,
                                             toID: to.id,
                                             fromName: from.displayName,
                                             toName: to.displayName)),
                  role: .assistant)
    }

    /// 规则 ①：把那条系统消息**整条撤掉**（内存 + 落库）。
    ///
    /// ⚠️ 刻意**不走** `deleteMessages(withIds:)`：那个带着「流式进行中一律拒绝」的闸，
    ///    它服务多选删除（删的行可能在流式行**前面**，会让 `streamingRowIndex` 指错行）。
    ///    而这里删的**必然是末行**（两条规则只在「末行就是它」时成立）——
    ///    删末行不会让任何更早的下标前移，所以流式中也安全。
    ///    （真出现这个组合：用户边等回复边换模型，那条消息会长在流式行后面。）
    private func undoModelSwitchNotice(at index: Int) {
        guard conversation.rows.indices.contains(index) else { return }
        let removed = conversation.rows.remove(at: index)
        if isPersisted {
            // 只删这一行（`store.deleteMessages` 会连它的 model_switch 记录一起清）
            store.deleteMessages(conversationId: conversation.id, ids: [removed.block.id])
        }
        // 行数变了 ⇒ 「操作栏挂在哪一行」「时间小字报在哪一行」的基准全变了，
        // 重排一遍再整表交付（`refreshRowDecorations` 会连受影响行的 cachedHeight 一起重算）
        refreshRowDecorations()
        delegate?.chatManagerDidReplaceRows(self)
    }

    /// 规则 ②：把那条系统消息**改写**成「A → C」（内存 + 一个事务落库）。
    ///
    /// `from` 那一半**不动** —— 这一条要表现的正是「从最初的 A 一路走到 C」。
    private func rewriteModelSwitchNotice(at index: Int, to model: AICustomModel) {
        guard conversation.rows.indices.contains(index),
              var record = conversation.rows[index].block.modelSwitch else { return }
        record.toID = model.id
        record.toName = model.displayName
        let text = record.noticeText
        conversation.rows[index].block.modelSwitch = record
        // 正文与结构化数据同源更新：落库那份 `text` 是「表丢了」时的兜底，
        // 留着旧文案会让两条路径显示不一样的字
        conversation.rows[index].block.text = text
        // 文案长短可能变了（「A→B」与「A→C」不一定一样长）⇒ 行高跟着重算。
        // iOS 的 `heightForRowAt` **只读缓存**，不重算就是「高度按旧的算、字按新的画」
        conversation.rows[index].cachedHeight = conversation.rows[index].height(in: contentWidth)
        if isPersisted {
            store.rewriteModelSwitch(messageId: conversation.rows[index].block.id,
                                     text: text,
                                     toID: model.id,
                                     toName: model.displayName)
        }
        delegate?.chatManagerDidUpdateRowLayout(self, atRowIndexes: [index])
    }

    // MARK: - 发送前校验

    /// 造 provider，并把「这次要发的东西在当前配置下到底发不发得出去」一并校验掉。
    ///
    /// **为什么必须抽成一处**：两个发送入口（`send` / `editAndResend`）都要在建行**之前**
    /// 做同一件事，规则一旦分散就会漂移 —— 而漂移的代价是本工程踩过的那个坑：
    /// 图片能力只判一处时，一个注定发不出去的图会留在对话里，之后**每一轮**
    /// `contextMessages()` 都把它重新带上，于是每次发文字都在复现同一个错误，
    /// 用户看到的是「我明明只打了字，它还在说我发的图片有问题」，换个说法也没用。
    ///
    /// - Parameter attachments: 本次要发的附件（只看有没有图片 —— 模型只吃图片和文字）
    /// - Throws: `AIProviderError`（缺 Key / 地址非法 / 空模型 / 模型不收图）
    private func validatedProvider(for attachments: [AIAttachment]) throws -> AIProvider {
        let provider = try AIProviderFactory.make()
        if attachments.contains(where: { $0.isImage }) {
            try provider.validateImageSupport()
        }
        return provider
    }

    /// 纯附件消息的标题占位（用户一个字都没打）
    private static func attachmentTitlePlaceholder(for attachments: [AIAttachment]) -> String {
        if attachments.contains(where: { $0.isImage }) { return L("[图片]") }
        return attachments.first?.displayName ?? L("[附件]")
    }

    /// 中断当前流式：已收到的文本照常落库，避免切走后丢失。
    /// 主动中断（切会话 / 新建 / 页面消失）不陪打字机走完，把没上屏的直接补齐再落库。
    public func stop() {
        // 联网检索期间也要停得下来：此刻**请求还没发**，`isReceiving` 还是 false ——
        // 漏了这一支，用户在首字之前那 1–4 秒里点「停止」会毫无反应（最难受的就是点不动）。
        // 取消之后**继续走下面既有的收尾**（把空的占位行收掉），与「流式中途停止」同一条路径。
        let wasSearchingWeb = isSearchingWeb
        if wasSearchingWeb {
            webSearchTask?.cancel()
            webSearchTask = nil
            isSearchingWeb = false
        }
        // 项目资料检索（RAG，2026-10-23）：与联网同一条理由 —— 此刻请求还没发，
        // 漏了这一支，用户在检索那几毫秒里点「停止」会没有反应
        let wasSearchingProject = isSearchingProject
        if wasSearchingProject {
            projectSearchTask?.cancel()
            projectSearchTask = nil
            isSearchingProject = false
        }
        // 既没在收流、也没在打字、也没在检索 → 没什么可收尾的
        guard isReceiving || revealTimer != nil || wasSearchingWeb || wasSearchingProject else { return }
        // ① 先关门：`isReceiving = false` 让之后到达的一切（迟到的 `.text`、cancel 触发的
        //    `.complete` → `finish`、连接错误 → `handleError`）统统变成空跑（见 `handle` 的门禁）
        isReceiving = false
        // ② 再断源。cancel 必须**排在收尾之前**：它拦得住「还没读到的字节」，但拦不住
        //    **已经 async 到主队列**的那批事件闭包（那批只能靠 `handle` 里的门禁拦），
        //    提前是为了让新的帧尽早不再产生。
        connection?.cancel()
        connection = nil
        pendingFinalize = false
        revealAllRemaining()
        stopRevealTimer()
        finalizeStreamingText()
        streamingRowIndex = nil
    }

    // MARK: - 重新生成 / 重试

    /// 重新生成：撤掉某一轮的助手回复，**不新增用户消息**，按现有上下文再问一次。
    ///
    /// 「重新生成」与「重试」共用这一份实现 —— 两者对数据做的事完全一样（撤回 + 重问），
    /// 差别只在入口（操作卡 / 失败提示行的操作卡）。分成两份实现迟早行为漂移。
    ///
    /// 为什么是「删掉助手行再重发」而不是「保留旧回复、把新的接在后面」：
    /// 同一轮里出现两条并列回复会让 `contextMessages()` 把它们当成**两次独立的助手发言**
    /// 回传给模型（多一条历史、多一份输入 token），而且用户在界面上也分不清哪条作数。
    ///
    /// - Parameter rowIndex: 目标行（助手回复行 / 失败提示行）
    /// - Returns: 是否成功发起。**配置类错误会在删除任何行之前拦下**，返回 false
    @discardableResult
    public func regenerate(fromRowAt rowIndex: Int) -> Bool {
        stop()
        guard conversation.rows.indices.contains(rowIndex),
              conversation.rows[rowIndex].role == .assistant else { return false }

        // ① 先校验配置：这一轮**一行都还没删**，失败时用户的记录原封不动。
        //    若反过来先删后校验，一个「Key 没填」就会把用户已有的回复弄丢 —— 那是不可恢复的破坏。
        let provider: AIProvider
        do {
            provider = try AIProviderFactory.make()
        } catch {
            delegate?.chatManager(self, didError: error)
            return false
        }

        // ② 找到该助手回复所在的**连续助手行区间**（一轮回复可能由文字 + 图片等多个块组成）
        var first = rowIndex
        while first - 1 >= 0, conversation.rows[first - 1].role == .assistant { first -= 1 }
        var last = rowIndex
        while last + 1 < conversation.rows.count, conversation.rows[last + 1].role == .assistant { last += 1 }

        // ③ 前面必须还有「能发出去的用户内容」，否则重问出去是个空请求。
        //    图片要看当前模型收不收（收不了图的模型带图必失败，那次发送本来就不成立）。
        let hasUserContent = conversation.rows[..<first].contains { row in
            guard row.role == .user else { return false }
            switch row.block.kind {
            case .text:  return !row.block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image: return provider.canSendImages
            case .file:  return true
            case .video, .error: return false
            case .modelSwitch: return false     // 系统流水不算「用户发过的内容」
            }
        }
        guard hasUserContent else {
            delegate?.chatManager(self, didError: Self.cannotRegenerateError())
            return false
        }

        // ④ 撤掉旧回复（先落库再改内存的顺序无所谓，但两者必须都做：
        //    只改内存 → 重启后旧回复又回来了，用户会以为「重新生成没生效」）
        let removedIds = conversation.rows[first...last].map(\.block.id)
        conversation.rows.removeSubrange(first...last)
        // 截断后「谁是媒体组首」可能变 ⇒ 归一一次。紧接着是整表刷（`DidReplaceRows`），
        // 所以这里不必记账返回的下标
        normalizeMediaGroupHeights()
        if isPersisted {
            store.deleteMessages(conversationId: conversation.id, ids: removedIds)
            store.touchConversation(id: conversation.id, title: conversation.title)
        }

        // ⑤ **先整表刷一次**再插占位行：此刻表的行数必须与 `rows.count` 一致，
        //    否则紧接着的 `insertRows` 会因为「行数与数据源对不上」直接抛异常。
        //    两步在同一个 runloop 里，用户看不到中间态。
        delegate?.chatManagerDidReplaceRows(self)

        let idx = appendRow(.text("", streaming: true), role: .assistant)
        streamingRowIndex = idx
        startStreaming(provider: provider)
        return true
    }

    // MARK: - 删除消息（多选删除）

    /// 某一行所在的**一整轮**覆盖的行区间（用户提问 + 它的 AI 回复）。
    ///
    /// 规则（与豆包一致，2026-09-18 产品确认）：
    /// 1. 先取这一行所属的「轮」：连续的**同 role** 行算一轮 —— 一张图 + 一段文字 + 一个文件
    ///    是同一次发送，属于同一轮。判据用行自带的 `isFirstBlockOfTurn`（与发送时的推导同一份规则）；
    /// 2. 再**配对**：这一轮是用户提问就带上紧随其后的助手轮；是助手回复就带上它前面那一轮提问。
    ///
    /// **为什么配对才是默认勾选**：单独删提问会留下一条「谁也没问的 AI 回复」，单独删回复会留下
    /// 一条「没有回答的提问」—— 两者都会被 `contextMessages()` 原样回传给模型，上下文直接错位
    ///（模型看到自己答过一句不存在的问题，接下去的每轮都建立在错的前提上）。
    /// 选择模式下用户当然可以拆开勾（那是他的自由），但**默认**要给一份自洽的。
    ///
    /// - Returns: 闭区间行号；行不存在时 `nil`。**纯查询、不改任何状态** ——
    ///   选择模式用它算「进来时默认勾哪几行」；真正删哪些由用户勾选的**消息 id** 决定
    ///   （见 `deleteMessages(withIds:)`）。
    public func turnRowRange(containingRowAt index: Int) -> ClosedRange<Int>? {
        guard conversation.rows.indices.contains(index) else { return nil }

        // 从任意一行扩到它所属的整轮（往两边吃连续同 role 的行）
        func turn(around i: Int) -> ClosedRange<Int> {
            var first = i
            while first - 1 >= 0, !conversation.rows[first].isFirstBlockOfTurn { first -= 1 }
            var last = i
            while last + 1 < conversation.rows.count, !conversation.rows[last + 1].isFirstBlockOfTurn { last += 1 }
            return first...last
        }

        var range = turn(around: index)
        if conversation.rows[index].role == .user {
            // 用户提问 → 带上紧随其后的助手轮（若它后面不是助手行，就是一条没被回答的提问，只删这一轮）
            let next = range.upperBound + 1
            if next < conversation.rows.count, conversation.rows[next].role == .assistant {
                range = range.lowerBound...turn(around: next).upperBound
            }
        } else {
            // 助手回复 → 带上它对应的那一轮提问
            let prev = range.lowerBound - 1
            if prev >= 0, conversation.rows[prev].role == .user {
                range = turn(around: prev).lowerBound...range.upperBound
            }
        }
        return range
    }

    /// 删除若干条**指定消息**（按**消息 id** 定位，不是行号 / 行区间）。
    ///
    /// 调用方是「多选删除」（长按操作卡「删除」→ 列表进编辑态勾选 → 导航栏「删除(N)」）。
    /// 收 id 而不是行号有两个原因：
    /// ① 用户勾出来的是**任意集合**，本来就无法用行区间表达；
    /// ② 确认弹窗弹出到用户点「删除」之间行号可能漂（本工程老坑 —— 编辑重发之所以存
    ///    消息 id 而不是行号，是同一条理由）。
    ///
    /// ⚠️ **流式进行中一律拒绝**：删行会让它后面所有行的下标前移，而流式正靠
    /// `streamingRowIndex` 定位那一行（`didUpdateStreamingText` 直接按下标写 cell）——
    /// 删掉前面几行之后，回复会写进**别人**的气泡。界面上已经用「流式中不许进选择模式」
    /// 挡了一道，这里是最后一道闸（⛔ 别只留 UI 那一道）。
    ///
    /// - Returns: 是否真的删掉了东西（`false` = 被流式闸拦下 / 这些 id 一条都不在了）
    @discardableResult
    public func deleteMessages(withIds ids: Set<UUID>) -> Bool {
        guard !ids.isEmpty,
              !conversation.rows.contains(where: { $0.block.isStreaming }) else { return false }
        let removed = conversation.rows.filter { ids.contains($0.block.id) }
        guard !removed.isEmpty else { return false }

        conversation.rows.removeAll { ids.contains($0.block.id) }
        if isPersisted {
            // 只删消息行（以及它们的用量行 / 自己发出的引用，见 `store.deleteMessages`）。
            // ⚠️ **不调 `touchConversation`**：删几条消息不该把整个会话顶到列表最前 ——
            // `updatedAt` 的语义是「最近聊过」，不是「最近改过」（重新生成会调它是另一回事：
            // 那一轮马上就会长出新回复）。
            store.deleteMessages(conversationId: conversation.id, ids: removed.map(\.block.id))
        }
        // 行数变了 → 「操作栏挂在哪一行」「时间小字报在哪一行」的基准全变了，重排一遍再交付。
        // `refreshRowDecorations` 会连受影响行的 `cachedHeight` 一起重算，所以不必全表重量。
        refreshRowDecorations()
        delegate?.chatManagerDidReplaceRows(self)
        return true
    }

    // MARK: - 编辑重发

    /// 把用户某条消息**换成新文本**，截断它之后的所有消息，然后按新内容重新提问。
    ///
    /// **为什么从这条开始整段截断**（而不是只撤紧随其后的那条回复）：
    /// 后面的每一轮都是**基于旧问题**产生的回答。留着它们的话，`contextMessages()` 会把
    /// 「你问 A → 我答 B → 你又问 C」整串回传给模型，可 A 已经不是用户现在问的东西了 ——
    /// 模型会接着那个作废的回答往下聊。ChatGPT / 豆包 的编辑也是从这条开始重建。
    ///
    /// ⚠️ **顺序是硬的：先校验配置，再删行**。反过来的话，一次「Key 没填」就会把
    /// 用户这条之后的全部对话弄丢 —— 那是不可恢复的破坏（`regenerate` 同理）。
    ///
    /// ⚠️ 编辑**不改变这条消息的引用**：用户改的是正文，引用是他当初挑中的上下文，
    /// 跟着新文本一起重发才对（见 `AIQuote`）。
    ///
    /// - Parameters:
    ///   - rowIndex: 目标行（必须是**用户发的文本行**）
    ///   - newText: 改完之后的正文
    ///   - attachments: 这次要一并发出的附件（编辑时补的图 / 文件；正文和附件不能同时为空）
    /// - Returns: 是否成功发起。配置类错误会**同步**回调 `didError` 并返回 false，此时一行都没动
    @discardableResult
    public func editAndResend(fromRowAt rowIndex: Int,
                              newText: String,
                              attachments: [AIAttachment] = []) -> Bool {
        stop()

        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty,
              conversation.rows.indices.contains(rowIndex),
              conversation.rows[rowIndex].role == .user,
              conversation.rows[rowIndex].block.kind == .text else { return false }

        // ① 校验配置（此刻**一行都没删**，失败时用户的记录原封不动）
        let provider: AIProvider
        do {
            provider = try validatedProvider(for: attachments)
        } catch {
            delegate?.chatManager(self, didError: error)
            return false
        }

        // ② 引用 / @ 资料跟着走：删行之前先取出来（删完就没了）。
        //    @ 与引用同理：用户改的是正文，「我这轮参考了哪几份资料」没变（见 `AIMention` 文件头）
        let quote = conversation.rows[rowIndex].block.quote
        let mentions = conversation.rows[rowIndex].block.mentions

        // 🔴 同 `send`：记下本轮发送的文本（通知描述用；编辑重发也是「新的一轮」）
        latestUserPrompt = trimmed.isEmpty ? Self.attachmentTitlePlaceholder(for: attachments) : trimmed

        // ③ 截断：从这一行（含）到末尾全删 —— 这条本身也要删，因为要用新文本重建它
        //    （就地改文本也行，但那样得再动一次「时间戳/引用/落库回写」，删掉重建更简单且语义清晰：
        //     它本来就是一条新消息，只是占回了原来的位置）
        let removedIds = conversation.rows[rowIndex...].map(\.block.id)
        conversation.rows.removeSubrange(rowIndex...)
        // 同 `regenerate`：截断后组首可能换行 ⇒ 归一一次（后面紧跟整表刷，不必记账）
        normalizeMediaGroupHeights()
        if isPersisted {
            store.deleteMessages(conversationId: conversation.id, ids: removedIds)
            store.touchConversation(id: conversation.id, title: conversation.title)
        }

        // ④ **先整表刷一次**再插新行：此刻表的行数必须与 `rows.count` 一致，
        //    否则紧接着的 `insertRows` 会因为「行数与数据源对不上」直接抛异常（同 `regenerate`）
        delegate?.chatManagerDidReplaceRows(self)

        // ⑤ 用新文本重建这一轮。附件顺序与 `send` **完全一致**（图片 → 文件 → 文字）：
        //    顺序不一致的话，「编辑时补了一张图」会在界面上跳到文字后面，
        //    而发给模型的多模态数组也是另一个顺序 —— 两处都乱
        // 落库同样攒批：重建出来的一整轮（最多 4 行）一个事务写完
        pendingAppends = []
        defer { pendingAppends = nil }
        for item in attachments where item.isImage {
            appendRow(.image(url: item.fileURL, mediaSize: item.pixelSize), role: .user)
        }
        for item in attachments where !item.isImage {
            appendRow(.file(url: item.fileURL, name: item.displayName, size: item.byteSize), role: .user)
        }
        if !trimmed.isEmpty {
            var block = AIBlock.text(trimmed)
            block.quote = quote
            // 编辑重发时资料原样带回（它的注入位置与 `send` 完全一致，见 `contextMessages`）
            block.mentions = mentions
            appendRow(block, role: .user)
        }
        let idx = appendRow(.text("", streaming: true), role: .assistant)
        // 🔴 同 `send`：先收掉攒批再写库，最后才发起请求（配置类错误是同步回调、
        // 会追加一条失败提示行，攒批没收会让那一行只进内存不进库）
        let batch = pendingAppends ?? []
        pendingAppends = nil
        // 会话行已存在（编辑的是历史消息）→ 只管标题 + 计数 + 时间，不建行
        store.appendMessages(conversationId: conversation.id,
                             title: conversation.title,
                             rows: batch,
                             createConversation: nil)
        streamingRowIndex = idx
        // 走外层入口：开了联网搜索就先检索（这里是**新提问**，该搜）
        beginStreaming(provider: provider, query: trimmed)
        return true
    }

    /// 「重新生成」失败时的提示（前面没有可重问的用户消息）
    static func cannotRegenerateError() -> Error {
        NSError(domain: "AIChatManager",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: L("这一轮没有可重新提问的内容")])
    }

    /// 「继续生成」失败时的提示（这条回复后面已经有更新的用户消息）
    static func cannotContinueError() -> Error {
        NSError(domain: "AIChatManager",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: L("这条回复后面已经有新消息了，直接接着问吧")])
    }

    // MARK: - 继续生成

    /// 这一轮**写完没有**（纯判据，不碰行）。
    /// 结论由 `applyTruncationVerdict` 落到 `block.endedTruncated` 上 —— 那里还管着时机。
    ///
    /// 三条判据（按可靠性排序）：
    /// ① 服务端明说被截断 —— `length`（撞上 `max_tokens`，话停在半句）或
    ///    `content_filter`（被内容审核掐了）→ 一定没写完；
    /// ② 收到过结束信号（`[DONE]` 或任一 `finish_reason`）→ 当作写完。有些中转平台只发
    ///    `[DONE]` 不给 `finish_reason`，把这种情况当截断会让**每一轮**都亮「继续生成」；
    /// ③ 连接关了、但整轮**从没见过**结束信号 → **网关静默掐流**（Nginx / Cloudflare 的空闲
    ///    超时最常见）。这类断流在界面上与「正常说完」毫无差别，正是「继续生成」要救的场景。
    ///    用户自己按「停止」也落在这里 —— 半截话照样能接着写。
    private func isTruncated() -> Bool {
        if let reason = finishReason, reason == "length" || reason == "content_filter" { return true }
        return !sawFinishSignal
    }

    /// 把「这一轮写完没有」的结论**落到行上**。幂等 —— 同一行可以调多次。
    ///
    /// - Returns: 行上的值是否真的变了（调用方据此决定要不要再通知一次 UI）。
    ///
    /// ## 🔴 为什么必须允许调**两次**（2026-09-28 修）
    ///
    /// 判定的两个输入（`sawFinishSignal` / `finishReason`）都在**整轮结束**时才确定，
    /// 而「正文上屏完」可能**早于**它：本机 mock 的协议是
    /// `txt…` → `end`（正文结束）→ `img`×N / `vid` → `done`。
    /// 实测（`.workbuddy/scripts/mock_sse_server.py`，探针量的是每帧到达时刻）：
    ///
    ///     end  @ 4.44s
    ///     img  @ 4.75s … 5.97s   ← 五张图片夹在中间
    ///     vid  @ 6.27s
    ///     done @ 6.57s           ← 比 `end` 晚 2.13s
    ///
    /// 只在 `finalizeStreamingText` 里判一次的话 ⇒ **每一轮**都被判成「没写完」：
    /// 正文刚吐完就弹「回复没写完，可右键『继续生成』」，而那时图片/视频根本还没到
    /// （用户 2026-09-28 报的原话：「怎么先给我提示说回复没写完」）。所以两道闸门：
    /// ① **整轮还没结束（`isReceiving`）时不下结论** —— 结束信号还在路上，此刻判必错；
    /// ② `finish()` 对**已收尾的那一行**（`verdictRowIndex`）补判一次 ——
    ///    真被掐流的照样能提示，只是提示落在正确时刻（整轮结束时，不是正文结束时）。
    private func applyTruncationVerdict(rowIndex: Int) -> Bool {
        guard conversation.rows.indices.contains(rowIndex) else { return false }
        // ① 闸门：这一轮还没结束 → 这次不算数，留给 `finish()` 的补判
        guard !isReceiving else { return false }
        let verdict = conversation.rows[rowIndex].block.kind == .text && !endedByError && isTruncated()
        guard conversation.rows[rowIndex].block.endedTruncated != verdict else { return false }
        conversation.rows[rowIndex].block.endedTruncated = verdict
        return true
    }

    /// 继续生成：**保留已有的半截正文**，让模型接着往下写（不是「重写」——那是 `regenerate`）。
    ///
    /// 请求怎么发的：这一行留在原位，于是它成为上下文里的**最后一条助手消息**，模型按 prefill
    /// 续写（OpenAI 兼容格式里没有 continue 参数，这是唯一不新增消息的做法）。好处是 provider
    /// 零改动、服务端前缀缓存还能吃到；代价是个别网关不接受以 assistant 结尾的请求（会 400），
    /// 那种平台只能退回「追加一条不落库的 user 指令」，本工程没做这一层。
    ///
    /// ⚠️ 与 `regenerate` 的三点不同（别混）：
    /// ① 不删行、不建行 —— **复用同一行**，`streamingRowIndex` 直接指过去；
    /// ② 已有正文作为前缀**一次上屏**（`startStreaming(prefix:)`），不重播一遍打字机；
    /// ③ 这一行之后**不能再有更新的用户消息**（见下）。
    ///
    /// - Parameter rowIndex: 目标行（没写完的那条助手回复）
    /// - Returns: 是否成功发起。**配置类错误在这里返回 false 并同步回调 `didError`**
    ///   （与 `regenerate` 同一条理由：一行都还没动，失败时用户的记录原封不动）
    @discardableResult
    public func continueGeneration(fromRowAt rowIndex: Int) -> Bool {
        stop()
        guard conversation.rows.indices.contains(rowIndex) else { return false }
        let target = conversation.rows[rowIndex]
        guard target.role == .assistant, target.block.kind == .text else { return false }
        let prefix = target.block.text
        guard !prefix.isEmpty else { return false }

        // 这条之后还有用户消息 → 它已经不是「最后一段没写完的回复」了。
        // 「接着上面那段写」必须紧贴半截回复本身，否则模型会把后来的提问也当成
        //「上面那段」的一部分，答得驴唇不对马嘴。
        guard !conversation.rows[(rowIndex + 1)...].contains(where: { $0.role == .user }) else {
            delegate?.chatManager(self, didError: Self.cannotContinueError())
            return false
        }

        // 先校验配置，再动手：与 `regenerate` 同一条理由（失败时一行都没改）
        let provider: AIProvider
        do {
            provider = try AIProviderFactory.make()
        } catch {
            delegate?.chatManager(self, didError: error)
            return false
        }

        // 复用这一行：转回流式态，并清掉上一轮的截断标记（这一行已经"有人管了"）
        streamingRowIndex = rowIndex
        conversation.rows[rowIndex].block.isStreaming = true
        conversation.rows[rowIndex].block.endedTruncated = false
        // 这一行从「已结束的 Markdown」变回「流式中」：操作栏归属与行高都要重算，
        // 并且必须**通知宿主 reload 这一行** —— `begin/endUpdates` 不重跑 `cellForRowAt`，
        // 只有 `reloadRows` 才会按新的 `isStreaming` 重新渲染
        var layoutChanged = refreshRowDecorations()
        if !layoutChanged.contains(rowIndex) { layoutChanged.append(rowIndex) }
        delegate?.chatManagerDidUpdateRowLayout(self, atRowIndexes: layoutChanged.sorted())

        startStreaming(provider: provider, prefix: prefix)
        return true
    }

    // MARK: - 行高缓存（作用于当前会话）

    /// 读取某行缓存高度。行高挂在 AIChatRow 上，但 struct 拷贝陷阱导致 VC 无法直接回写，
    /// 故统一经此处读写，保证缓存与行生命周期一致。
    public func cachedHeight(forRowAt index: Int) -> CGFloat? {
        guard conversation.rows.indices.contains(index) else { return nil }
        return conversation.rows[index].cachedHeight
    }

    /// 写入 / 清除某行缓存高度
    public func setCachedHeight(_ height: CGFloat?, forRowAt index: Int) {
        guard conversation.rows.indices.contains(index) else { return }
        conversation.rows[index].cachedHeight = height
    }

    // MARK: - 思考块展开 / 折叠（2026-10-20）

    /// 展开 / 折叠某行的思考块（用户点折叠那行时调；流式中由 `handle(.reasoning)` 自动展开）。
    ///
    /// 行高在这里**重算并存回模型**，再走 `chatManagerDidUpdateRowLayout` 让宿主 reload
    /// 那一行 —— 两端视图都遵守「量算在 manager、渲染在视图」的分工，⛔ 别在视图里自己估高度。
    /// 没有思考内容 / 总闸关着的行是空操作（点了不长个儿，也不该长）。
    public func setThinkingExpanded(_ expanded: Bool, atRowIndex index: Int) {
        guard conversation.rows.indices.contains(index) else { return }
        guard conversation.rows[index].isThinkingExpanded != expanded else { return }
        guard conversation.rows[index].thinkingHeightOrZero(in: contentWidth * 0.8 - 24) > 0 else { return }
        conversation.rows[index].isThinkingExpanded = expanded
        conversation.rows[index].cachedHeight = conversation.rows[index].height(in: contentWidth)
        delegate?.chatManagerDidUpdateRowLayout(self, atRowIndexes: [index])
    }

    /// 「媒体横滑条」的高度归一：**只有组首那一行占高度，同组其余行归零**。
    ///
    /// ## 现在管**两类**组（2026-09-28助手侧 · 2026-10-09 加用户图侧）
    /// | | 判据 | 组首那一行的高度 | 组内其余行 |
    /// |---|---|---|---|
    /// | 助手侧媒体 | `AIChatMediaGrouping.kind(of:)` | `AIChatRow.mediaStripRowHeight` | 0 |
    /// | **用户多图** | `AIChatMediaGrouping.isUserImage` | `userImageGroupRowHeight(整组)` | 0 |
    ///
    /// 🔴 **两把尺必须分开**（理由见 `AIChatMediaGrouping` 文件头）：用户图组若走
    /// `kind(of:)`，组首会被定成 `mediaStripRowHeight`（192+12）⇒ 用户图被强行拉成
    /// 9:16 竖条那一档，尺寸彻底错。
    ///
    /// ## 为什么必须由这里做（全工程唯一一处「一行多高」取决于**邻居**）
    /// 连续的媒体行在界面上是**一条**横滑条，组首那个 cell 负责把整条画出来
    /// （`AIAssistantMediaStripCell` / `AIUserImageStripCell`）⇒ 组内其余行必须不占高度，
    /// 否则那条图下面会跟着一串空白。而 `AIChatRow.height(in:)` **只看得到自己**（拿不到邻居），
    /// 所以「看邻居」这个动作只能由持有整个 `rows` 的这里统一做。判据本身在共享层
    /// （`AIChatMediaGrouping`，Mac 也用它划组）—— ⛔ 别在这里另写一份 kind 比较。
    ///
    /// ☠️ **凡是写完行高的入口都要过一遍**（`recomputeAllRowHeights` / `refreshRowDecorations`
    /// 已经接好；流式过程中追加图片 / 视频行走的正是 `appendRow → refreshRowDecorations`）。
    /// 漏一次的症状都很隐蔽：要么「同一条下面多一截空白」，要么
    /// **「组首被误归零 ⇒ 整条图完全看不见」**（后者与「图片没加载出来」长得一模一样）。
    ///
    /// ⚠️ 调用顺序有讲究：必须排在「按自己算高」那一趟**之后**，否则 `height(in:)` 会把
    /// 这里的 0 又写成 204。
    ///
    /// 便宜（只读 `role` / `kind`，不做任何文本量算）⇒ 每次 append 都跑也不是热路径。
    /// - Returns: 高度真的变了的行下标（调用方可拿去只 reload 这几行）。
    @discardableResult
    private func normalizeMediaGroupHeights() -> [Int] {
        var changed: [Int] = []
        let rows = conversation.rows
        for i in rows.indices where AIChatMediaGrouping.kind(of: rows[i]) != nil {
            let expected: CGFloat = AIChatMediaGrouping.isGroupHead(rows, at: i)
                ? AIChatRow.mediaStripRowHeight
                : 0
            if conversation.rows[i].cachedHeight != expected {
                conversation.rows[i].cachedHeight = expected
                changed.append(i)
            }
        }
        normalizeUserImageGroupHeights(into: &changed, rows: rows)
        return changed
    }

    /// 「用户多图横排」那一半的归一（2026-10-09）。
    ///
    /// 🔴 **单张必须原样不动**：组内只有 1 张时既不缩小组高、也不归零 ——
    ///    用户原话「单张的图片 大小不变」，且单张在界面上仍是**一图一行**（`AIUserImageCell`）。
    ///    所以判据是「**组内张数 > 1**」，⛔ 别只判「是不是用户图」——
    ///    那会把单张也拉去按 `userImageStripScale`（缩小档，当前 0.5）算高度，
    ///    而 cell 那边若仍按原尺寸渲染，就是最典型的「量的时候按 A、布局按 B」。
    ///
    /// ⚠️ 与助手侧那半**不共用判据、不共用高度常量**，但**归零这件事一样要做** ——
    ///    漏掉的后果与助手侧完全相同：组内第 2..N 张各占一条高度，
    ///    `AIUserImageStripCell` 只在组首画一条 ⇒ 下面跟着一串空白。
    private func normalizeUserImageGroupHeights(into changed: inout [Int], rows: [AIChatRow]) {
        for i in rows.indices where AIChatMediaGrouping.isUserImage(rows[i]) {
            guard let range = AIChatMediaGrouping.userImageGroupRange(rows, at: i) else { continue }
            // ⚠️ **单张成组时整段跳过**：它由`height(in:)` 自己算出来的那笔就是对的
            //    （原尺寸 + 12），这里既不改它、也不把它归零。
            guard range.count > 1 else { continue }
            let expected: CGFloat = range.lowerBound == i
                ? AIChatRow.userImageGroupRowHeight(rows: Array(rows[range]),
                                                    in: contentWidth,
                                                    scale: AIChatRow.userImageStripScale)
                : 0
            if conversation.rows[i].cachedHeight != expected {
                conversation.rows[i].cachedHeight = expected
                changed.append(i)
            }
        }
    }

    /// 按当前 contentWidth 全部重算并写入缓存（旋转 / 屏宽变化 / 载入历史会话时调用）。
    /// heightForRowAt 只读缓存，因此这里必须预先算好，不能留 nil。
    public func recomputeAllRowHeights() {
        // 必须先定「操作栏挂哪一行」「小字行归哪条」再算高度：行高含操作栏与小字行的高度，
        // 顺序反了那两行会各矮 35 / 20pt
        applyActionBarFlags()
        applyMetaFlags()
        for i in conversation.rows.indices {
            conversation.rows[i].cachedHeight = conversation.rows[i].height(in: contentWidth)
        }
        // 🔴 媒体组要按**邻居**再归一一次（组首占高、组内其余归零）——
        //    上面那一趟是「按自己算」的，算不出组内行该是 0（见该方法的注释）
        normalizeMediaGroupHeights()
    }

    // MARK: - 操作栏归属（哪一行挂按钮）

    /// 重新判定「操作栏挂在哪一行」，返回**需要 reload 的行下标**。
    ///
    /// 规则（与豆包/ChatGPT 一致）：只挂**当前会话里最后一条已结束的文本回复**——
    /// - 历史消息不常驻操作栏（改成长按操作卡），省空间也更安静；
    /// - 正在流式的回复不算「已结束」：只要还有 `isStreaming` 的行，整表都不挂栏
    ///   （该位置此刻属于「停止生成」；用行自身的状态判断而不是 `streamingRowIndex`，
    ///   因为 `appendRow` 内刷新时类状态还没更新，见 `send()` 的赋值顺序）；
    /// - 失败提示（`.error`）与空占位行不挂栏。
    ///
    /// 注意消息带图片/视频时（本地 mock 就会追加），栏会落在该轮的文字气泡下、图片上方——
    /// 若以后要「挂到整轮最底部」，改这里的 `target` 即可，但同时要给图片/视频 cell 加操作栏。
    @discardableResult
    private func applyActionBarFlags() -> [Int] {
        let target: Int?
        if conversation.rows.contains(where: { $0.block.isStreaming }) {
            target = nil
        } else {
            target = conversation.rows.indices.last { i in
                let row = conversation.rows[i]
                return row.role == .assistant
                    && row.block.kind == .text
                    && !row.block.text.isEmpty
            }
        }

        var changed: [Int] = []
        for i in conversation.rows.indices where conversation.rows[i].showsActionBar != (i == target) {
            conversation.rows[i].showsActionBar = (i == target)
            changed.append(i)
        }
        return changed
    }

    /// 判定「时间」小字行的**文案**，返回**结构变化需要 reload 的行下标**。
    ///
    /// 规则：
    /// - 与上一条消息间隔 ≥ `AIMessageTime.gapThreshold`（或它是本会话第一条）→ 报一次时间；
    /// - 否则不显示 —— 整行收起、高度归 0，气泡上移，不占位也不留白；
    /// - 只有 `.text` 行会显示：图片/文件/视频行的 cell 没有承载这条小字的位置
    ///   （行高量算与 cell 布局是一套口径，见 `AIChatRow.metaHeight`）。
    ///
    /// ⚠️ 用量**不在这里，也不在聊天页的任何地方**（2026-09-17 撤掉）：这条小字只报时间，
    /// 所以它要么是一个时间、要么整条不存在。想看 token 请到设置页「用量与计费」。
    ///
    /// 时间基准始终是「上一条消息」，与该条自己显不显示无关 —— 否则一条不显示的行
    /// 会把基准吃掉，后面那条再也不会报时间。
    @discardableResult
    private func applyMetaFlags() -> [Int] {
        var changed: [Int] = []
        var previousDate: Date?
        for i in conversation.rows.indices {
            let row = conversation.rows[i]
            // 拼文案这件事只有这里能做：`needsSeparator` 要拿上一条的时间做基准，
            // 模型自己看不到「上一条」（它连自己在数组里的位置都不知道）。
            let metaText: String?
            if row.block.kind == .text,
               AIMessageTime.needsSeparator(since: previousDate, to: row.createdAt) {
                metaText = AIMessageTime.string(from: row.createdAt)
            } else {
                metaText = nil
            }
            if conversation.rows[i].metaText != metaText {
                conversation.rows[i].metaText = metaText
                changed.append(i)
            }
            previousDate = row.createdAt
        }
        return changed
    }

    /// 重排「操作栏归属 + 时间小字行」并**重算受影响行的行高**，返回需要 reload 的行下标。
    ///
    /// 两件装饰性的事合在一个入口里：它们都改行高，各自算一遍会出现
    /// 「高度按新状态算了、但另一件事的标志还是旧的」的中间态。
    /// 返回值**去重后排序** —— 同一个下标被两件事同时命中时，重复下发给
    /// `reloadRows` 会因为「同一个 indexPath 刷两次」直接崩。
    @discardableResult
    private func refreshRowDecorations() -> [Int] {
        var changed = applyActionBarFlags()
        changed.append(contentsOf: applyMetaFlags())
        var unique = Array(Set(changed)).sorted()
        for i in unique {
            conversation.rows[i].cachedHeight = conversation.rows[i].height(in: contentWidth)
        }
        // 🔴 媒体组的归一必须排在**上面那一趟之后**（顺序反了，`height(in:)` 会把组内行的 0
        //    又写成 204）。**流式过程中追加的图片 / 视频行走的正是这个入口**
        //    （`appendRow` → 这里）—— 漏了它，新来的第 2..N 张图会各自占一条 204pt 的空白。
        unique = Array(Set(unique + normalizeMediaGroupHeights())).sorted()
        return unique
    }

    // MARK: - 行管理（当前会话）

    @discardableResult
    private func appendRow(_ block: AIBlock, role: AIRole) -> Int {
        let isFirst = conversation.rows.isEmpty || conversation.rows.last?.role != role
        var row = AIChatRow(id: block.id, role: role, block: block, isFirstBlockOfTurn: isFirst)
        row.cachedHeight = row.height(in: contentWidth)   // 数据返回即算好
        conversation.rows.append(row)
        // 落库：攒批模式下**只落内存**（由发起方最后一次性写库，见 `pendingAppends`）；
        // 否则会话已持久化就即时写一条 —— 那条路留给「流式过程中追加的图片 / 视频行」，
        // 它们不属于任何一批，本来就该单独落库。
        if pendingAppends != nil {
            pendingAppends?.append(row)
        } else if isPersisted {
            store.appendMessage(conversationId: conversation.id, row: row)
        }
        // 新行可能让操作栏换行（如新的助手占位行让上一轮的栏收起），
        // 也可能让「时间」小字改归属 —— 先重排结构，再通知
        let layoutChanged = refreshRowDecorations()
        let newIndex = conversation.rows.count - 1
        delegate?.chatManagerDidInsertRows(self, at: [newIndex])
        let others = layoutChanged.filter { $0 != newIndex }
        if !others.isEmpty {
            delegate?.chatManagerDidUpdateRowLayout(self, atRowIndexes: others)
        }
        return newIndex
    }

    // MARK: - 后台任务保护

    /// 流式期间向系统申请的**后台任务**标识（`.invalid` = 当前没有申请）。
    ///
    /// 为什么需要：切后台 / 锁屏 / 来电会让进程被挂起，正在收的 SSE 连接随之停摆 ——
    /// 回到前台看到的是**半截回复**（而且那半截已经落库了，接不下去）。申请一个后台任务
    /// 能让进程在后台多活约 30s，绝大多数回复都跑得完。
    ///
    /// 为什么挂在 manager 而不是 VC：后台任务的存活期恰好等于「正在收流」，
    /// 而 `isReceiving` 已经是后者的唯一真值 —— 放到 VC 就得再维护一份与之同步的状态，
    /// 而两份状态迟早对不上（对不上的后果见 `handleBackgroundTimeExpired`）。
    private var streamingBackgroundTask: Int = AIPlatformBackgroundTask.invalid

    private func beginStreamingBackgroundTask() {
        // 幂等保护：真出现并存时系统会给出两个 id，而 `endBackgroundTask` 只认最后一个 ——
        // 前一个就永远漏在系统那儿了
        endStreamingBackgroundTask()
        streamingBackgroundTask = AIPlatform.background.begin(name: "ai.chat.stream") { [weak self] in
            guard let self else { return }
            // ⚠️ 宽限期用尽时，这个闭包**在主线程同步调用**，而且必须尽快把任务标识
            // 交还系统，否则 watchdog 会直接终止进程（不是崩溃日志，是「App 莫名其妙没了」）。
            // 所以这里不做任何异步派发，一路同步收尾。
            // （macOS 侧没有「宽限期」这回事，这个闭包永不触发，收尾一律靠下面的 end。）
            self.handleBackgroundTimeExpired()
        }
    }

    private func endStreamingBackgroundTask() {
        guard streamingBackgroundTask != AIPlatformBackgroundTask.invalid else { return }
        let task = streamingBackgroundTask
        // 先清标识再交还：即使下面这一拍抛错 / 重入，也不会拿着同一个 id 交还两次
        streamingBackgroundTask = AIPlatformBackgroundTask.invalid
        // ⚠️ 交还必须发生在主线程。`begin` 的调用点全在 UI 事件里（发送 / 重新生成），
        // 但 `end` 有一条**理论上的旁路**：`deinit { stop() }`（释放线程不保证是主线程）。
        // 派回主线程最多让交还晚一拍；真正要紧的那条路 ——「宽限期已经到点」——
        // 本来就是主线程同步调用的，不受这里影响。
        if Thread.isMainThread {
            AIPlatform.background.end(task)
        } else {
            DispatchQueue.main.async { AIPlatform.background.end(task) }
        }
    }

    /// 后台宽限期用尽 → 主动中断这一轮，并把「为什么断了」写进对话流。
    ///
    /// 不这么做的话：进程被挂起后连接就死在那儿，回到前台界面仍停在「正在回复」，
    /// 直到连接超时（最长 120s）才报错 —— 用户看到的是「卡死了」。
    private func handleBackgroundTimeExpired() {
        // ⚠️ 顺序不能反、也不能省：先把任务标识交还系统，再做收尾（落库是同步 IO）——
        // 反过来的话，这段收尾占用的时间仍然算在那个已经被收回的额度里。
        endStreamingBackgroundTask()
        guard isReceiving else { return }
        // `stop()` 的既有语义正是这里要的：补齐已收到的正文、落库、取消连接
        stop()
        // 明确标「已中断」。用 `.error` 行而不是往正文里塞标记，三个理由：
        // ① 它自带「重试」（见 `AIRowAction.errorMenu`）；
        // ② `contextMessages()` 天然不回传 `.error` 行，不会污染下一轮上下文；
        // ③ 落库，来回切几次还在，不会像 toast 那样一闪而过（何况这一拍 App 还在后台，
        //    弹什么都看不见）。
        appendRow(.error(Self.backgroundInterruptedText), role: .assistant)
        // 🔴 断了的这件事必须**告知用户**（2026-10-19，通知策略补丁 A 方案的缺口）：
        // 用户早就切走了，对话流里那行 `.error` 他此刻根本看不见。
        // 而这一拍（宽限期到点、主线程同步执行中）是**进程还有 CPU 的最后时刻**——
        // 再晚一步（被挂起）连通知都发不出去。这是「断了」唯一能送达的时机。
        // ⚠️ 走 `stop()` 收尾 ⇒ `isReceiving` 已复位 ⇒ pending 已清账，
        //    回前台对账不会重复发（`AIMissedRoundReconciler` 的 isStreamingActive 守卫
        //    也挡得住：那时这一轮早已结束）。
        // ⚠️ App 此刻在后台 ⇒ `post` 的前台守卫天然放行，不需要 force。
        AIReplyNotifier.replyInterrupted(conversationId: conversation.id,
                                         prompt: latestUserPrompt)
    }

    // MARK: - 流式连接

    /// 起流的**外层入口**：开了联网搜索时先检索，拿到资料再起流。
    ///
    /// 只有两个发送入口走这里：`send`（新提问）与 `editAndResend`（改了再发）。
    /// `regenerate` / `continueGeneration` **故意不搜**：
    /// - 「重新生成」的语义是「用同样上下文再答一次」，重搜会让它变成**另一个问题**
    ///   （结果与上一版对不上，用户只会觉得模型飘了）；
    /// - 「继续生成」续的是同一句话，更不该换资料。
    ///
    /// 🔴 为什么在 `startStreaming` **外面**包一层，而不是把检索塞进它：
    /// 那个函数是**同步**的（`makeRequest` 的配置类错误要同步回调 `handleError`），
    /// 而检索是 async。改成 async 会波及四个调用点，还会破坏
    /// 「同步校验失败 ⇒ `send` 返回 false ⇒ 输入区内容不清空」这条既有语义。
    ///
    /// 检索期间 `isSearchingWeb = true`，助手占位行已经在屏幕上（空气泡）；
    /// 用户此时点「停止」由 `stop()` 掐掉这次 Task（见那里的注释）。
    ///
    /// ## 两条检索的接力（2026-10-23 RAG 接入后）
    /// 联网检索（公网、1.4–4s）与项目资料检索（本地库、毫秒级）是**串行两段**：
    /// 本函数跑完联网那段，把结果交给 `beginProjectRetrieval` 跑项目那段，
    /// 最后才 `startStreaming`。串行而不是并行的理由：两段共享同一颗转圈与同一条
    /// 「停止」语义，并行要让两端 UI 同时显示两种检索态（而项目那段通常几毫秒就完了，
    /// 并行的复杂度换不来任何可感知的收益）。
    private func beginStreaming(provider: AIProvider, query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 🧪 2026-10-21 加：把「这一轮到底搜没搜」留一行控制台证据。
        // 存在的理由：**关掉联网时模型照样会回答**（只是没有资料块），肉眼分不出开关有没有生效；
        // 用户正是据此怀疑「开关没执行」。⚠️ 只在 DEBUG 编进去，Release 无此行。
        // 取日志：`xcrun simctl spawn booted log show --last 2m --predicate 'processImagePath CONTAINS "Aster"' | grep WebSearch`
        #if DEBUG
        NSLog("%@", "[WebSearch] begin enabled=\(AIGenerationSettings.webSearchEnabled ? 1 : 0)"
            + " queryLen=\(trimmed.count)")
        #endif
        // 🔴 唯一判据：⛔ 别在 UI 层再判一次这个开关（两处判一个开关，迟早出现
        //    「界面亮着但没搜」或反过来 —— 而且两边都不报错）
        guard AIGenerationSettings.webSearchEnabled, !trimmed.isEmpty else {
            #if DEBUG
            NSLog("%@", "[WebSearch] skip → 普通对话（"
                + (AIGenerationSettings.webSearchEnabled ? "空 query" : "开关是关的") + "）")
            #endif
            // 没开联网 ⇒ 直接进第二段（项目资料检索；也没开就原样起流）
            beginProjectRetrieval(provider: provider, query: trimmed, searchDigest: nil)
            return
        }
        isSearchingWeb = true
        webSearchTask = Task { [weak self] in
            var digest: String?
            var failure: String?
            do {
                let hits = try await AIWebSearch.search(trimmed)
                digest = Self.withCurrentTime(AIWebSearch.digest(hits, query: trimmed))
                #if DEBUG
                NSLog("%@", "[WebSearch] hits=\(hits.count) digestLen=\(digest?.count ?? 0)")
                #endif
            } catch {
                // 失败**不阻断**：没有资料，这一轮就是一次普通对话。
                // 原因留给 UI 弹轻提示（⛔ 别走 didError，那会把这轮判死）
                failure = (error as? AIWebSearchError)?.errorDescription
                    ?? error.localizedDescription
                #if DEBUG
                NSLog("%@", "[WebSearch] failed → \(failure ?? "")")
                #endif
            }
            guard let self else { return }
            self.webSearchTask = nil
            self.isSearchingWeb = false
            // 用户在检索途中点了停止 / 切了会话：这一轮已经不成立，别再起流
            if Task.isCancelled { return }
            if let failure {
                NotificationCenter.default.post(name: Self.didFailWebSearchNotification,
                                                object: self,
                                                userInfo: [Self.webSearchFailureKey: failure])
            }
            // 联网那段收工 ⇒ 接力进项目资料那段（2026-10-23）
            self.beginProjectRetrieval(provider: provider, query: trimmed, searchDigest: digest)
        }
    }

    /// 起流的**第二段**（RAG，2026-10-23）：开了项目资料检索时，先在**本项目已索引的
    /// 资料**里检索片段，拿到资料再起流。
    ///
    /// 三个门（全过才检索，任一不过 ⇒ 原样起流，请求体与没这功能时逐字节一致）：
    /// ① 开关开着（`AIGenerationSettings.projectSearchEnabled`，唯一判据在这里）；
    /// ② 这一轮有提问（`!query.isEmpty` —— 纯附件消息没得可检索）；
    /// ③ 当前会话**属于某个项目**且那个项目**有已建好的片段**
    ///    （`conversation.projectId` + `store.hasIndexedChunks` —— 没有内容的项目
    ///    连转圈都不该闪，⛔ 别让用户每发一句话都看一次「正在检索」）。
    ///
    /// 检索是**本地 SQLite 读 + 内存打分**（毫秒级），所以这里不设「失败重试」：
    /// 读库失败在 store 内部已降级成空结果（`projectChunks` catch 里返回 []），
    /// 走到 `didFailProjectSearchNotification` 的只有「索引状态都读不出来」这种真异常。
    private func beginProjectRetrieval(provider: AIProvider, query: String, searchDigest: String?) {
        guard AIGenerationSettings.projectSearchEnabled, !query.isEmpty else {
            startStreaming(provider: provider, searchDigest: searchDigest)
            return
        }
        guard let projectId = conversation.projectId, store.hasIndexedChunks(projectId: projectId) else {
            #if DEBUG
            NSLog("%@", "[ProjectSearch] skip → 没有可检索的项目资料（"
                + (conversation.projectId == nil ? "会话不属于项目" : "项目没有已索引片段") + "）")
            #endif
            startStreaming(provider: provider, searchDigest: searchDigest)
            return
        }
        isSearchingProject = true
        projectSearchTask = Task { [weak self] in
            guard let self else { return }
            var digest: String?
            var failure: String?
            // 🔴 这里**没有 do/catch**：读库与打分都不抛错（store 内部已把读失败降级成
            //    空结果，见 `projectChunks`）。唯一说得出的失败是「库压根没就绪」
            //    （建表/迁移失败过）—— 那种情况这一轮「想检索但没得检索」，值得告诉用户一声。
            if self.store.isReady {
                let chunks = self.store.projectChunks(projectId: projectId)
                let names = Dictionary(uniqueKeysWithValues:
                    self.store.fetchProjectFiles(projectId: projectId).map { ($0.id, $0.displayName) })
                let found = AIProjectRetriever.hits(query: query, chunks: chunks, fileNames: names)
                digest = AIProjectRetriever.digest(found)
                #if DEBUG
                NSLog("%@", "[ProjectSearch] chunks=\(chunks.count) hits=\(found.count)"
                    + " digestLen=\(digest?.count ?? 0)")
                #endif
                if found.isEmpty {
                    // 一条都没命中：这不是错误（阈值挡掉的），是「这轮与项目资料无关」——
                    // 普通对话答即可，⛔ 别弹提示（那会变成「明明没带资料却每次弹窗」）
                    #if DEBUG
                    NSLog("%@", "[ProjectSearch] 没有片段过阈值（\(AIProjectRetriever.defaultScoreThreshold)）→ 普通对话")
                    #endif
                }
            } else {
                failure = L("项目资料索引还没就绪，这一轮直接回答")
                #if DEBUG
                NSLog("%@", "[ProjectSearch] failed → 库未就绪")
                #endif
            }
            self.projectSearchTask = nil
            self.isSearchingProject = false
            if Task.isCancelled { return }
            if let failure {
                NotificationCenter.default.post(name: Self.didFailProjectSearchNotification,
                                                object: self,
                                                userInfo: [Self.projectSearchFailureKey: failure])
            }
            self.startStreaming(provider: provider, searchDigest: searchDigest, projectDigest: digest)
        }
    }

    /// 在联网资料块**最前面**拼一行「当前时间」。
    ///
    /// 来由（2026-10-22 用户报「Mac 端点击了联网，还是无法获得今天是几号」）：
    /// 排查证明链路全通（`enabled=1`、`hits=5`、`digestLen=817` 且进了请求体），
    /// 卡点在最后一环 —— **模型不优先用 system 末尾的参考资料**。
    /// 而「今天几号」这类时效性问题的正解**不是网页，是设备自己的时钟**：
    /// 网页缓存可能过期、搜索词还会召回一堆黄历站（实测 5 条里 3 条是农历/黄历，
    /// 日期数字混在一起），`Date()` 不会错。
    /// ⇒ 把确定答案放在资料块最前面：模型先看到它，再去对搜索结果。
    ///
    /// ⚠️ 与 digest 同性质：这是**发给模型的内容** ⇒ 固定中文、⛔ 不进词表
    ///    （不跟界面语言切，理由同 `AIWebSearch.digest` 头部注释）。
    /// 成本：system 提示词**每天变一次** ⇒ 每天第一发打掉一次服务端前缀缓存。可接受
    /// （换一整天时效性问题都能答对；真要省，将来可以只在 query 命中日期词时拼）。
    ///
    /// ☠️ `DateFormatter` 非线程安全：这里是 `static let`，全部访问都在 MainActor 上
    ///    （本类默认 MainActor 隔离，`beginStreaming` 的 Task 闭包继承它）⇒ 安全。
    ///    locale 固定 `zh_CN`：这行的读者是模型，不是界面。
    private static func withCurrentTime(_ material: String) -> String {
        "【当前时间】\(currentTimeFormatter.string(from: Date()))\n\n" + material
    }

    private static let currentTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日 EEEE HH:mm"
        return f
    }()

    /// - Parameter prefix: 续写时的**已有正文**（「继续生成」用，见 `continueGeneration`）。
    ///   非空时它成为 `receivedChars` 的初始前缀、并且**一次性全部上屏**（不重播一遍打字机）——
    ///   模型新吐出来的字接在它后面。空串（默认）= 全新的一轮。
    /// - Parameter searchDigest: 本轮联网检索到的资料块（`AIWebSearch.digest`，头部带【当前时间】）。
    ///   `nil` = 没开联网 / 搜索失败 ⇒ 请求体与没这功能时逐字节一致。
    ///   ⚠️ 由 `beginStreaming` 在**异步搜完之后**传进来；`continueGeneration` 不传（续写不重搜）。
    ///   注入位置在 `withSearchDigest`（拼进 user 消息，⛔ 不放 system）。
    /// - Parameter projectDigest: 本轮**项目资料检索**到的片段块（`AIProjectRetriever.digest`，2026-10-23）。
    ///   `nil` = 没开检索 / 会话不在项目里 / 项目没有已索引片段 / 一条都没过阈值
    ///   ⇒ 同样与没这功能时逐字节一致。由 `beginProjectRetrieval` 异步检索后传进来。
    private func startStreaming(provider: AIProvider, prefix: String = "", searchDigest: String? = nil, projectDigest: String? = nil) {
        // 🧪 与 `beginStreaming` 那几行配套：证明「资料块真的进了这一轮请求」
        // （0 = 这一轮是普通对话；>0 的字符数就是拼进 user 消息的资料长度）
        #if DEBUG
        NSLog("%@", "[WebSearch] startStreaming digestLen=\(searchDigest?.count ?? 0)"
            + " projectDigestLen=\(projectDigest?.count ?? 0)")
        #endif
        // 🔴 通知权限预热（2026-10-18）：授权弹窗**只在 App 在前台时弹得出来**，
        //    而「回复生成完」那一刻用户多半已经切走 ⇒ 那个时机请求 = 这次通知静默丢失。
        //    三个发送入口（send / editAndResend / regenerate）都经过这里，是唯一的单点。
        AIReplyNotifier.warmup()
        // 必须最先置位：`makeRequest` 抛错时会**同步**回调 `handleError`，
        // 那里要靠这个门禁才认这次接收（否则错误会被自己的 guard 吞掉）
        isReceiving = true
        receivedChars = Array(prefix)
        revealedCount = prefix.count
        pendingFinalize = false
        // 本轮结束判定的几个输入**每轮必须复位**：漏一次就会把上一轮的 `length` 或错误状态
        // 带到这一轮，于是「明明写完了」也亮起「继续生成」
        sawFinishSignal = false
        finishReason = nil
        endedByError = false
        // 收尾行的指向也要复位：它只对「当前这一轮」有意义（见 `applyTruncationVerdict`）
        verdictRowIndex = nil
        // 思考计时的起点同样每轮复位：漏一次就会把上一轮的起点带到这一轮，耗时是个离谱的大数
        reasoningStartTime = nil
        // 打字机先跑起来：哪怕服务端把整段攒到最后一次发，文字也是匀速往外吐的
        startRevealTimer()

        // 配置已在 send 里校验过，这里只剩「把 messages 拼成请求」这一件事
        let request: URLRequest
        do {
            // 能不能回放历史图片由 provider 的能力位决定（收不了图的模型带上历史图 = 每轮注定失败）
            let messages = contextMessages(canSendImages: provider.canSendImages)
            // 上下文长度管理：**超预算才裁**。不超一律原样发 —— 前缀稳定才能继续吃服务端缓存，
            // 每轮都裁会把缓存全打掉，反而更贵（见 AIContextBudget 头部说明）。
            let context = AIContextBudget.trim(messages, window: provider.contextWindow)
            // 「续写」要按端点能力换成合适的请求形态（两条路二选一，详见 continuationMessages）
            // 组装次序（每层都在 trim 之后，本轮必需内容不能被预算裁掉）：
            // trim → system prompt → 项目资料 → 联网资料 → 续写形态
            // （项目资料排在联网资料之后 = 更贴问题；@ 资料在问题之后，见 contextMessages）
            request = try provider.makeRequest(
                messages: continuationMessages(withSearchDigest(withProjectDigest(withSystemPrompt(context.messages),
                                                                                projectDigest: projectDigest),
                                                               searchDigest: searchDigest),
                                               provider: provider,
                                               isContinuation: !prefix.isEmpty))
            // 提示放在 makeRequest **之后**：配置类错误是同步抛出来的，
            // 那种情况下真正该被看到的是错误提示，不是「上下文被裁了」
            notifyContextTrim(context)
        } catch {
            handleError(error)
            return
        }

        let client = SSEClient()
        connection = client.connectWithStream(request,
            onEvent: { [weak self] event in
                // 解析在后台线程做完，只把 UI 事件丢回主线程
                let events = provider.events(from: event)
                guard !events.isEmpty else { return }
                DispatchQueue.main.async { events.forEach {
                    guard let self else { return }
                    self.handle($0)
                } }
            },
            onError: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.handleError(error)
                }
            },
            onComplete: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.handleComplete()
                }
            })
    }

    /// 上下文被裁（或已经裁无可裁）时提示一次。
    ///
    /// 门禁挂在会话 id 上（见 `contextTrimWarnedConversationId`）：同一会话只提示第一次，
    /// 换个会话自然又能提示一次，不需要任何复位点。
    private func notifyContextTrim(_ result: AIContextTrimResult) {
        // 一条没裁、也没超窗 → 什么都没发生，不提
        guard result.didTrim || result.isOverBudget else { return }
        guard contextTrimWarnedConversationId != conversation.id else { return }
        contextTrimWarnedConversationId = conversation.id
        delegate?.chatManager(self, didTrimContext: result.droppedCount, isOverBudget: result.isOverBudget)
    }

    /// 组装多轮上下文。
    ///
    /// 与旧版的四点不同：
    /// ① **用户图片要带上**（不带就等于每次追问都在让模型盲猜）——**前提是当前模型收得了图**，见 ④；
    /// ② 助手侧图片/视频仍然跳过 —— 服务端要求图片只能出现在 user 消息里，放错位置直接 400；
    /// ③ **同一次发送产生的连续用户行合并成一条 user 消息**。用户发「图片 + 文件 + 文字」
    ///    在 UI 上是三行，拆成三条消息发过去会变成「连问三次」，模型的回答会跑偏；
    /// ④ **当前 provider 收不了图时，历史图片一律不回放**（`canSendImages == false`）。
    ///
    /// - Note: 这里返回的是**未裁剪的全量上下文**（一条不落）。预算裁剪不在这里做，
    ///   而在 `startStreaming` 里由 `AIContextBudget.trim` 统一做 —— 全量组装与「装不下时怎么取舍」
    ///   是两件事，混在一个函数里会让这段本来就很细的规则变得没法读。
    ///
    /// - Parameter canSendImages: 当前模型能不能带图（来自 `AIProvider.canSendImages`，唯一真值）。
    ///   为 false 时跳过历史用户图片：那些图本来也发不出去（`makeRequest` 会直接抛错），
    ///   硬带上只会让**每一轮**都失败 —— 表现为「只发了张图的那次报错，之后每次打字都在复现同一个错」。
    ///   跳过它们之后，文字对话立刻恢复正常；当前这轮本来就发不出图，也就不该让历史图来陪葬。
    private func contextMessages(canSendImages: Bool) -> [AIChatMessage] {
        var messages: [AIChatMessage] = []
        for row in conversation.rows {
            switch row.block.kind {
            case .text:
                let text = row.block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                // 引用要写进**正文**：OpenAI 兼容格式里根本没有 quote 字段，只能把被引用的内容
                // 用一句显式的说明带上去。不拼的话模型看不见「用户在指哪一段」，
                // 「就上面那段，帮我改改」会变成一句没头没尾的话。
                // ⚠️ 只给用户消息拼：助手侧不会有引用，但真拼进去会让模型以为那是自己说的。
                let quoted = row.role == .user ? row.block.quote?.contextText() : nil
                // @ 资料同理，但排在**正文之后**（2026-10-21）：
                // ① 引用是「我在说哪一段」，必须先出现，否则正文没有指代对象；
                // ② 资料是「参考材料」，贴在这一问之后最像人说话的次序（先问，再附材料）；
                // ③ 与联网检索资料的位置**不同**（2026-10-22 起）：那份拼在本轮问题**之前**
                //    （`withSearchDigest`，RAG 标准形态）；@ 资料留在问题**之后** ——
                //    它本来就写在正文里（不是请求时注入的），挪它要动存储与显示，收益不抵风险。
                // ⚠️ 顺序 = 用户 @ 的顺序（`block.mentions` 由 store 按 `idx` 读回），
                //    模型读到的材料次序才与界面上待发条一致。
                let resources = row.role == .user
                    ? row.block.mentions.map { Self.mentionContextText($0) }.joined(separator: "\n\n")
                    : ""
                let content = [quoted, text.isEmpty ? nil : text, resources.isEmpty ? nil : resources]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")
                // 只引用、没有正文的行（被引用的内容本身就是全部上下文）也要发出去
                guard !content.isEmpty else { continue }
                appendOrMerge(AIChatMessage(role: row.role == .user ? .user : .assistant,
                                            content: content),
                              into: &messages)

            case .image:
                guard row.role == .user, let url = row.block.imageURL else { continue }
                // 收不了图的模型：不回放历史图片。**不是静默丢内容** ——
                // 这张图在当前配置下本来就发不出去，带上它只会把这一轮也拖失败。
                guard canSendImages else { continue }
                appendOrMerge(AIChatMessage(role: .user, content: "", imageURLs: [url]),
                              into: &messages)

            case .file:
                guard row.role == .user, let url = row.block.fileURL else { continue }
                appendOrMerge(AIChatMessage(role: .user,
                                            content: Self.fileContextText(name: row.block.text, url: url)),
                              into: &messages)

            case .video, .error, .modelSwitch:
                // 视频发不过去；失败提示不是对话内容（回传给模型会被当成「助手说过的话」）；
                // 模型切换系统消息更是**系统的流水**（见 `AIModelSwitch` 文件头）
                continue
            }
        }
        trimContextImages(&messages)
        return messages
    }

    /// 上下文里最多带几张历史图片。
    ///
    /// 图片是**按 base64 内联**进请求体的：一张 1600px 的 JPEG 约 400~800 KB，
    /// base64 再 ×1.33。多轮带图对话如果无脑全带，几轮就能把请求体顶到服务端的 48 MiB 上限，
    /// 然后整轮报错。保留最近几张既够模型理解上下文，又不会把会话拖重。
    private static let maxContextImages = 6

    /// 只保留最近 `maxContextImages` 张图片（从后往前数，越靠后越接近当前提问）
    private func trimContextImages(_ messages: inout [AIChatMessage]) {
        var budget = Self.maxContextImages
        for index in messages.indices.reversed() {
            let urls = messages[index].imageURLs
            guard !urls.isEmpty else { continue }
            if budget >= urls.count {
                budget -= urls.count
                continue
            }
            let kept = budget > 0 ? Array(urls.suffix(budget)) : []
            messages[index] = AIChatMessage(role: messages[index].role,
                                            content: messages[index].content,
                                            imageURLs: kept)
            budget = 0
        }
        // 裁完不能留下「既没文字又没图」的空消息 —— 服务端对空 content 会直接报错
        messages.removeAll { $0.content.isEmpty && $0.imageURLs.isEmpty }
    }

    /// 相邻的用户行合并成一条消息；助手侧一行就是一条，不做合并。
    private func appendOrMerge(_ message: AIChatMessage, into messages: inout [AIChatMessage]) {
        if message.role == .user, let last = messages.last, last.role == .user {
            let merged = [last.content, message.content]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            messages[messages.count - 1] = AIChatMessage(role: .user,
                                                         content: merged,
                                                         imageURLs: last.imageURLs + message.imageURLs)
            return
        }
        messages.append(message)
    }

    /// 把系统提示词（用户设置的「指令」） prepend 成第一条 `role: system` 消息。
    ///
    /// ## 为什么追加在 `AIContextBudget.trim` **之后**（调用点在 `startStreaming`）
    /// 与 `continuationMessages` 同款理由：system 消息是**每轮必需的**，被当成
    /// 早期历史裁掉的话，「设了指令却时灵时不灵」—— 症状是短会话有效、长会话失效，
    /// 且不报错。代价是它的 token 不计入预算估算（续写指令也不计入，同一口径）——
    /// 2000 字上限的指令 ≈ 1500 token 以内，相对 32K+ 的窗口是可接受误差。
    ///
    /// ## 为什么是 prepend 而不是别的位置
    /// OpenAI 兼容格式里 system 消息必须在最前面（服务端对位置靠后的 system
    /// 消息行为不一，有的直接 400）。用户可见的对话里没有它 —— 不落库、不进 UI。
    ///
    /// 空指令（没设 / 全是空白）时原样返回 ⇒ 请求体与功能上线前逐字节一致。
    ///
    /// ## 项目级指令（L3，2026-10-21）：**叠加在全局之后**，不是替换
    /// 全局指令回答的是「这个 AI 是谁」（人设 / 语气），项目指令回答的是「这件事怎么做」
    /// （这个项目里只谈 A、代码一律给 Swift）。两者是**不同维度**，替换掉全局会让
    /// 用户一进项目就丢掉自己的人设，而且他很难意识到是这件事造成的。
    /// ⇒ 顺序固定「全局在前、项目在后」（后置的更容易被模型当成本轮的强调），空行分隔。
    ///
    /// ⚠️ 代价：项目指令不清空时全局改动会**渗透进所有项目**。这是刻意的
    ///（全局就是「我的偏好」，用户改它时本来就期望处处生效）；要「这个项目就按我说的来」，
    /// 就把全局那句也写进项目指令里 —— 那是用户能自己控制的，不需要我们再给一个开关。
    ///
    /// ⚠️ 读库这一步**每轮发送都会走**，所以只查单行（`projectInstruction(id:)`）。
    ///
    /// 🔴 本函数管**全局指令 + 项目指令 + 长期记忆**三样；联网检索资料**不在这里**
    /// —— 2026-10-22 起改走 `withSearchDigest` 拼进 user 消息，原因见那个函数的文档。
    ///
    /// ## 长期记忆（2026-10-25）：追加在指令之后，⛔ 不放 user 消息
    /// 与 2026-10-22 搬走的是两种内容：检索资料**每轮都变**（模型不优先用 system
    /// 尾部、且打前缀缓存），而记忆是**跨会话稳定的人设/事实**（与全局/项目指令
    /// 同性质）—— 稳定的内容放 system 尾部正是前缀缓存最愿意吃的形态，
    /// 也是「这个 AI 是谁」这类信息唯一该在的位置。块文案由
    /// `AIMemoryStore.digest()` 单点生成（⛔ 别在这里拼第二份）；
    /// 关 / 空 ⇒ `digest()` 返回空串 ⇒ 与没这功能时请求体逐字节一致。
    ///
    /// ⚠️ 记忆条数无上限（刻意，见 `AIMemoryStore` 文件头）：system 消息的 token
    /// 不计入预算估算，条数失控的代价是每轮成本，由用户在列表页自己管。
    private func withSystemPrompt(_ messages: [AIChatMessage]) -> [AIChatMessage] {
        let global = AIGenerationSettings.systemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 项目归属跟着会话走：切了会话就是切了人格，不需要额外的「当前项目」状态
        let project = conversation.projectId
            .flatMap { store.projectInstruction(id: $0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 长期记忆（2026-10-25）：追加在最后 —— 指令回答「AI 是谁、怎么做」，
        // 记忆回答「用户是谁、偏好什么」，同维度的稳定内容，顺序在项目指令之后
        let memory = AIMemoryStore.digest()
        // 🧪 与 [WebSearch] 那行配套：证明「记忆块真的进了这一轮请求」
        // （enabled=0 或 digestLen=0 ⇒ 请求体与没这功能时逐字节一致）
        #if DEBUG
        NSLog("%@", "[Memory] withSystemPrompt enabled=\(AIMemoryStore.isEnabled ? 1 : 0) digestLen=\(memory.count)")
        #endif
        // 次序是口径（全局 → 项目 → 记忆），空段落直接丢掉，不留多余空行
        let prompt = [global, project, memory]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !prompt.isEmpty else { return messages }
        return [AIChatMessage(role: .system, content: prompt)] + messages
    }

    /// 把联网检索资料块 **prepend 到本轮最后一条 user 消息**（资料在前、问题在后）。
    ///
    /// ## 为什么从 system 末尾搬来 user 消息（2026-10-22）
    /// 用户报「Mac 端点了联网，还是无法获得今天是几号」。排查证明链路全通
    /// （`enabled=1`、`hits=5`、digest 真的进了请求体），卡点在最后一环：
    /// **模型不优先用 system 末尾的参考资料**。两个已知成因：
    /// ① 推理类模型（DeepSeek reasoner 等）对长 system 尾部内容利用率差是普遍现象；
    /// ② 中转 / 自定义 provider 对 system role 的处理五花八门（合并、截断、甚至丢掉）。
    /// 而 user 消息是**所有 OpenAI 兼容端点都原生支持**的位置，资料贴在本轮问题前面，
    /// 正是检索增强（RAG）的标准形态 —— 模型当轮必读。
    ///
    /// （曾经放在 system 末尾的两个理由也随之作废：①「变动靠后保前缀缓存」——
    /// 资料每轮都变，放 user 消息里照样不动 system 的前缀；②「紧贴用户这一问」——
    /// 拼进同一条 user 消息比放在 system 里更紧贴。）
    ///
    /// ## 为什么是拼进**同一条** user，而不是新插一条 user 消息
    /// 新插一条会把「资料」和「问题」拆成两轮对话，部分模型会对着资料本身作答；
    /// 拼进同一条，问题永远在末尾 —— 末尾是模型确定「要回答什么」的位置。
    ///
    /// ## 为什么必须在 `AIContextBudget.trim` 之后（调用点在 `startStreaming`）
    /// 资料是本轮必需的，被当成早期历史裁掉的话这一轮白搜；与 `continuationMessages`
    /// 同款理由。它的 token 不计入预算估算（量级几百，由搜索结果本身决定）。
    ///
    /// ⚠️ 取 `lastIndex(where: role == .user)` 而不是 `messages.last`：兜底
    /// 「末条不是 user」的异常形态（真出现时原样返回 —— 宁可这轮没资料，也不能拼错位置）。
    /// 重建消息而不是改 `content`：那个属性是 `let`（`imageURLs` / `isPrefix` 必须原样带走）。
    ///
    /// 搜索失败 / 没开联网时传 nil ⇒ 原样返回，请求体与功能上线前逐字节一致。
    private func withSearchDigest(_ messages: [AIChatMessage],
                                  searchDigest: String?) -> [AIChatMessage] {
        guard let raw = searchDigest?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let index = messages.lastIndex(where: { $0.role == .user }) else {
            return messages
        }
        var out = messages
        let target = out[index]
        out[index] = AIChatMessage(role: .user,
                                   content: raw + "\n\n" + target.content,
                                   imageURLs: target.imageURLs,
                                   isPrefix: target.isPrefix)
        return out
    }

    /// 把项目资料检索片段块 **prepend 到本轮最后一条 user 消息**（资料在前、问题在后）。
    ///
    /// 与 `withSearchDigest` 是**同一个位置、同一条理由**（2026-10-23 RAG 接入时对齐）：
    /// 模型对 system 末尾参考资料的利用率差，而 user 消息头部是所有 OpenAI 兼容端点
    /// 都原生支持的位置 —— 这正是检索增强（RAG）的标准形态。⛔ 别为了「项目资料更私密」
    /// 把它挪进 system：那是把已知的坑再踩一遍。
    ///
    /// 两份资料同时开时的次序（调用点决定的，⛔ 别改）：
    /// **项目资料 → 联网资料 → 问题**。项目资料排在更前面没有特殊含义，
    /// 只是「项目是长期上下文、网页是临时补充」的直觉次序；真正不能动的是
    /// **问题永远在最后**（模型在末尾确定「要回答什么」）。
    ///
    /// 空 / 没检索 ⇒ 原样返回，请求体与功能上线前逐字节一致。
    private func withProjectDigest(_ messages: [AIChatMessage],
                                   projectDigest: String?) -> [AIChatMessage] {
        guard let raw = projectDigest?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let index = messages.lastIndex(where: { $0.role == .user }) else {
            return messages
        }
        var out = messages
        let target = out[index]
        out[index] = AIChatMessage(role: .user,
                                   content: raw + "\n\n" + target.content,
                                   imageURLs: target.imageURLs,
                                   isPrefix: target.isPrefix)
        return out
    }

    /// 把「续写」翻译成请求里的消息形态。**两条路二选一，绝不能都上**：
    ///
    /// - **真前缀续写**（`provider.supportsPrefixCompletion`，即 DeepSeek 官方 beta 端点）：
    ///   给末条 assistant 打 `isPrefix`。服务端做**补全**，吐回来的一定是接在后面的字 ——
    ///   这是官方文档里明确点名「可用于 max_tokens 截断后接着写」的功能。
    /// - **指令法**（其余所有 OpenAI 兼容平台）：补一条**不落库、不显示**的 user 指令。
    ///   这些平台没有 prefill 能力，只能靠指令把「你是在补全上一段」这件事讲清楚。
    ///
    /// ⚠️ 二选一是硬约束，不是风格偏好：前缀续写要求「最后一条消息的 role 必须是 assistant」
    ///（官方文档明写）。若在打了 `prefix` 的同时又补一条 user 指令，前提被破坏 →
    /// 服务端退回「重新生成一条回复」，于是「续写内容从头重复」原样复现。
    ///
    /// ⚠️ 指令追加在 `AIContextBudget.trim` **之后**：它是本轮必需的，不能被当成历史裁掉。
    private func continuationMessages(_ messages: [AIChatMessage],
                                      provider: AIProvider,
                                      isContinuation: Bool) -> [AIChatMessage] {
        guard isContinuation else { return messages }
        if provider.supportsPrefixCompletion {
            var out = messages
            // 末条必须就是那条被截断的 assistant 回复：「继续生成」的闸门保证它后面没有 user 行，
            // 而助手侧的图片/视频/失败提示行都不进上下文 —— 所以这里它一定是末条。
            if let last = out.indices.last, out[last].role == .assistant {
                out[last].isPrefix = true
            }
            return out
        }
        var out = messages
        out.append(AIChatMessage(role: .user, content: Self.continuationInstruction))
        return out
    }

    /// 「指令法」续写用的临时指令（**不落库、不进对话流**，只活在这一次请求里）。
    ///
    /// 为什么措辞要这么直白：OpenAI 兼容的 `/chat/completions` 会把末尾的 assistant 消息当作
    /// **一段说完了的发言**，然后「生成下一条回复」—— 模型很容易从头再讲一遍，
    /// 于是拼接结果里出现肉眼可见的重复。这条指令就是把「你只是在补全上一段的结尾」讲清楚。
    static let continuationInstruction =
        "上面那条回答被中断了。请直接从断点处接着往下写，不要重复已经写过的内容，不要重新开头，也不要加总结。"

    /// 「附件正文」缓存（键见 `FileContextKey`）。
    ///
    /// 为什么必须缓存：这份正文会出现在**每一轮**请求里（上下文要把整段历史带上），
    /// 而一份文本附件最多取 8000 字 —— 每轮都 `Data(contentsOf:)` + UTF-8 解码 + 截断，
    /// 全部发生在「点发送」那一拍的主线程上。内容只取决于磁盘上那份文件，读一次就够。
    private static var fileContextCache: [FileContextKey: String] = [:]
    /// 条数上限：聊天里同时出现的文本附件通常个位数，64 条足够覆盖整个会话的回放
    private static let fileContextCacheLimit = 64
    private static let fileContextLock = NSLock()

    /// 缓存键：**路径 + 大小 + 修改时间**。
    ///
    /// 后两个字段是为了「同名文件内容被换掉」时自动失效 —— 纯路径做键会一直用到旧内容。
    /// 代价是多一次 `stat`（相对读整份文件可以忽略），换来的是「绝不会读到过期正文」。
    private struct FileContextKey: Hashable {
        let path: String
        let size: Int64
        let modified: TimeInterval
        /// 块的**标签**（「附件」/「项目资料」）。
        /// ⚠️ 必须进键：同一份文件被「发了附件」和「@ 成项目资料」两种方式各引用一次时，
        /// 只差标签的两份正文会被缓存成同一份 —— 先读到哪个，另一个就再也拿不到自己的标题，
        /// 而且**不报错**，只是模型看到的那段写着「附件」而界面上写的是「项目资料」。
        let label: String
    }

    /// 文件附件怎么进上下文（**带缓存**）。
    ///
    /// 模型只吃「图片 + 文字」，文件本身发不过去，所以：
    /// - 纯文本类（txt/md/json/csv…）与 **PDF** → 把内容带上（`extractedText` 内部分流，
    ///   PDF 走 PDFKit 抽正文；各自内部有截断）；
    /// - 其余（zip/docx/二进制…）→ 降级成一句说明。**不能默默丢掉**：
    ///   用户明明发了附件却被告知「没看到附件」，比直接说「解析不了」更让人困惑。
    ///
    /// - Parameter label: 块头里的称呼。附件传默认的「附件」；`@` 进来的项目资料传「项目资料」——
    ///   这不只是措辞：模型要能分清「这是用户这次上传的」和「这是项目里的长期资料」。
    private static func fileContextText(name: String, url: URL, label: String = "附件") -> String {
        let shown = name.isEmpty ? url.lastPathComponent : name
        // 先 stat 拿键（也顺手给「非文本降级文案」提供了大小，省掉一次重复 stat）
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = FileContextKey(path: url.path, size: size, modified: modified, label: label)

        fileContextLock.lock()
        let cached = fileContextCache[key]
        fileContextLock.unlock()
        if let cached = cached { return cached }

        let text: String
        if let body = AIAttachmentStorage.extractedText(at: url) {
            text = "【\(label) \(shown)】\n\(body)"
        } else {
            let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            // ⚠️ 降级文案要分标签：项目资料是**长期存在**的，说「用户上传了」会误导
            //    （那不是这一轮传的，可能是上周放进项目的）。
            //    🔴 默认标签必须一字不改地走原句 —— 这是**已在线上跑的 prompt**，
            //    改措辞等于悄悄换掉附件功能的上下文口径（而且没有任何判据会红）。
            text = label == "附件"
                ? "【用户上传了附件 \(shown)（\(sizeText)），当前无法解析其内容】"
                : "【\(label) \(shown)（\(sizeText)），当前无法解析其内容】"
        }

        fileContextLock.lock()
        if fileContextCache.count >= fileContextCacheLimit {
            for stale in Array(fileContextCache.keys.prefix(fileContextCacheLimit / 3)) {
                fileContextCache.removeValue(forKey: stale)
            }
        }
        fileContextCache[key] = text
        fileContextLock.unlock()
        return text
    }

    #if DEBUG
    /// 🧪 探针专用（`STARRY_PDF_PROBE=1`，本体见 `Setup/PDFTraceProbe.swift`）。
    ///
    /// 为什么需要它：2026-10-23 起「文件 → 可注入文本」多了 PDF 一条支路
    /// （`AIAttachmentStorage.extractedText` 分流 → PDFKit 抽正文）。分流器本体由
    /// Mac 渲染台的 `PDFTEXT` 判据覆盖（七种真 PDF），但**调用点就在这个函数里** ——
    /// 而「附件发得过去、PDF 却解析不出」正是那种**编译得过、要等用户真发一次**
    /// 才发现的病。iOS 侧只验 AICore 那一半，等于把最容易分叉的另一半放过了。
    ///
    /// ⚠️ 它只是转发：⛔ 别在这里重写一份读取逻辑（那就绕过了被测的那条路）。
    public static func debugFileContextText(name: String, url: URL, label: String = "附件") -> String {
        fileContextText(name: name, url: url, label: label)
    }
    #endif

    /// 一条 `@` 进来的项目资料怎么进上下文（2026-10-21）。
    ///
    /// 与文件附件共用 `fileContextText`（同一份读取 + 缓存 + 8000 字截断），
    /// 只把块头标签换成「项目资料」—— 模型因此能分清
    /// 「这是用户这一轮上传的」与「这是项目里的长期资料」。
    ///
    /// ⚠️ 资料在发送之后被删掉是**真会发生**的（项目页里删资料不会回改历史消息）：
    /// 那时 `resolve` 出来的路径不存在，这里照实说一句，⛔ 别静默丢 ——
    /// 用户明明是 @ 了东西的，模型却说「没看到任何资料」，比说「那份已被删除」更让人困惑。
    private static func mentionContextText(_ mention: AIMention) -> String {
        guard let url = AIAttachmentStorage.resolve(mention.storageName),
              FileManager.default.fileExists(atPath: url.path) else {
            return "【项目资料 \(mention.displayName) 已不在（已被删除）】"
        }
        let text = fileContextText(name: mention.displayName, url: url, label: "项目资料")
        // 🧪 取证用（`STARRY_MENTION_PROBE` 那套看这一行）：`@` 有没有**真的**进到请求里，
        // 界面上完全看不出来（chip 只说明"挂上了"）。日志里要能读到「哪份、多少字」。
        #if DEBUG
        NSLog("%@", "[Mention] inject name=\(mention.displayName) len=\(text.count)")
        #endif
        return text
    }

    private func handle(_ event: AIStreamEvent) {
        // 🔴 本轮已经收尾（`stop` / `finish` / `handleError` 任一）→ 之后到达的事件**一律丢弃**。
        //
        // 为什么不能只靠 `connection?.cancel()`：事件是在解析线程里**先 `async` 回主队列、
        // 再执行**的（见 `startStreaming` 的 `onEvent`）。cancel 只能阻止「还没读到的字节」，
        // 拦不住**已经排进主队列**的那批闭包 —— 它们会在 `stop()` 返回之后陆续跑起来，
        // 而那时 `streamingRowIndex` 已被收尾置成 `nil`，`.text` 分支见 nil 就**新建一行**接住。
        // 表现就是用户看到的那样：**点「停止生成」后凭空多出一个 AI 气泡**，里面正是最后
        // 几个 chunk 的字；而且这一行永远等不到 `.done` / `.finalizeText`（`pendingFinalize`
        // 已复位），打字机不结束、气泡一直亮着流式态，直到下一次 `stop()` 被顺手「扶正」落库。
        guard isReceiving else { return }

        switch event {
        case .text(let chunk):
            // 上一个文本块已收尾（mock 的 end）之后又来正文：开一行新的接住
            if streamingRowIndex == nil {
                streamingRowIndex = appendRow(.text("", streaming: true), role: .assistant)
                startRevealTimer()   // 收尾时定时器已停，这里重新起
            }
            // 正文第一字流出 = **思考结束**（推理模型「先想后说」）。把耗时封在
            // `block.reasoning.duration` 上，折叠行才有「思考过程 · 8.4 秒」可显示。
            sealReasoningDuration()
            receivedChars.append(contentsOf: chunk)
        case .reasoning(let chunk):
            // 思考过程（2026-10-20 接上「思考展示」）。
            //
            // 🔴 总闸关着 ⇒ **不缓冲、不落库、不显示**（设置页可随时改，见
            //    `AIGenerationSettings.showsThinkingProcess`）。在缓冲这一层就拦掉，
            //    而不是「照常攒、渲染时再判」—— 后者会把用户明确不要的内容写进数据库。
            guard AIGenerationSettings.showsThinkingProcess, !chunk.isEmpty else { break }
            // 思考可能**早于**正文到达（推理模型的正常形态：先想后说）。
            // 占位行在发送时就建好了（`send` / `regenerate` / `editAndResend` 各一处），
            // 但流式中途又来一段新文本块时（mock 的 end 之后）行会被重置 ⇒ 照 `.text` 的办法兜。
            if streamingRowIndex == nil {
                streamingRowIndex = appendRow(.text("", streaming: true), role: .assistant)
                startRevealTimer()   // 收尾时定时器已停，这里重新起
            }
            guard let idx = streamingRowIndex, conversation.rows.indices.contains(idx) else { break }
            if reasoningStartTime == nil { reasoningStartTime = Date() }
            // 流式中思考块**自动展开**（收尾时折叠成一行，见 `finalizeStreamingText`）
            conversation.rows[idx].isThinkingExpanded = true
            if conversation.rows[idx].block.reasoning == nil {
                conversation.rows[idx].block.reasoning = AIReasoning(text: chunk)
            } else {
                conversation.rows[idx].block.reasoning?.text += chunk
            }
            // 行高现算现存（思考在长，气泡跟着长）—— 与 `tickReveal` 同一套路
            conversation.rows[idx].cachedHeight = conversation.rows[idx].height(in: contentWidth)
            delegate?.chatManagerDidUpdateStreamingReasoning(self, rowIndex: idx)
        case .finalizeText:
            // 当前文本块结束（mock 在正文后发 end）：挂上待收尾，等打字机把尾巴补完再落地
            pendingFinalize = true
        case .image(let url):
            appendRow(.image(url: url), role: .assistant)
        case .video(let url, let cover):
            appendRow(.video(url: url, cover: cover), role: .assistant)
        case .usage(let usage):
            // 只记在本轮状态里，等收尾时再挂到那一行上：此刻行还可能被「空回复兜底」改成失败提示，
            // 一个失败提示不该带 token 用量
            pendingUsage = usage
        case .finish(let reason):
            // 结束原因**先于** `[DONE]` 到达。这里只记下来，判定统一放在收尾时做
            //（`isTruncated`）—— 在这里判的话还得再维护一份「结果存在哪」的状态
            finishReason = reason
            sawFinishSignal = true
        case .done:
            // `[DONE]` = 服务端说「这一轮到此为止」。它**不保证**内容写完（撞 `max_tokens`
            // 时同样会发 `[DONE]`），所以 `sawFinishSignal` 只表示「正常收尾」，
            //「写完没有」另由 `isTruncated()` 结合 `finishReason` 判
            sawFinishSignal = true
            finish()
        }
    }

    // MARK: - 思考耗时封口

    /// 把「思考耗时」封到当前流式行的 `block.reasoning.duration` 上。
    ///
    /// 幂等（`reasoningStartTime` 置 nil 即二次调用直接返回）。两个封口点：
    /// - 正文第一字流出（`handle(.text)`）—— 正常「先想后说」的路径；
    /// - `finalizeStreamingText` 兜底 —— 思考之后**没有正文**（纯思考回复、或出错收尾）时，
    ///   不收这一刀耗时就永远是 0，折叠行少一截信息。
    private func sealReasoningDuration() {
        guard let start = reasoningStartTime else { return }
        reasoningStartTime = nil
        guard let idx = streamingRowIndex, conversation.rows.indices.contains(idx),
              conversation.rows[idx].block.reasoning != nil else { return }
        conversation.rows[idx].block.reasoning?.duration = Date().timeIntervalSince(start)
    }

    // MARK: - 打字机节奏（把「到达」与「上屏」解耦）

    /// 上屏节奏：0.03s ≈ 33 帧/秒，每帧至少出 1 个字 —— 「一个字一个字往外蹦」的观感来源。
    /// 想调快/调慢改这一个常量即可。
    private static let revealInterval: TimeInterval = 0.03

    /// 积压追平系数：每帧吐出积压量的 1/8 —— 积压小（≤8 字）时就是每帧 1 个字，
    /// 积压大时自动加速，让「服务端攒了一大批再发」也能快速而平滑地补上，而不是「一坨」糊上去。
    private static let catchUpDivisor: Double = 8

    /// 每帧上屏上限。没有它的话，积压越大吐得越猛，本质上又变回「整块出现」。
    /// 12 字/帧 ≈ 400 字/秒 —— 大积压时是「快速流淌」，仍能看出是从左往右出的。
    private static let maxCharsPerTick = 12

    private func startRevealTimer() {
        guard revealTimer == nil else { return }
        let timer = Timer(timeInterval: Self.revealInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tickReveal()
        }
        // 必须挂到 `.common`：默认 mode 下，手指拖动聊天列表（tracking mode）时定时器会被挂起，
        // 松手后积压的文本一次性糊上来 —— 这也是「不是逐字返回」的一个真实来源。
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    private func stopRevealTimer() {
        revealTimer?.invalidate()
        revealTimer = nil
    }

    /// 每帧推进：把 `receivedChars` 里还没上屏的部分按节奏补上
    private func tickReveal() {
        guard let idx = streamingRowIndex, conversation.rows.indices.contains(idx) else {
            stopRevealTimer()
            return
        }

        let backlog = receivedChars.count - revealedCount
        if backlog > 0 {
            let step = min(Self.maxCharsPerTick, max(1, Int(ceil(Double(backlog) / Self.catchUpDivisor))))
            revealedCount = min(receivedChars.count, revealedCount + step)
            let text = String(receivedChars[0..<revealedCount])
            conversation.rows[idx].block.text = text
            conversation.rows[idx].cachedHeight = conversation.rows[idx].height(in: contentWidth)
            delegate?.chatManagerDidUpdateStreamingText(self, rowIndex: idx, text: text)
        }

        finalizeIfReady()
    }

    /// 条件满足就真正收尾。幂等：`pendingFinalize` 只认第一次（done 事件与随后关闭连接会各触发一次）。
    /// ⚠️ 这里**不**通知「整轮结束」——那个由 `finish()` 在流结束的当下立刻发出，
    /// 否则输入栏要陪着打字机一起等。
    private func finalizeIfReady() {
        guard pendingFinalize, revealedCount >= receivedChars.count else { return }
        pendingFinalize = false
        stopRevealTimer()
        finalizeStreamingText()
    }

    /// 把还没上屏的尾巴一次性补上（主动中断 / 出错时用，不陪打字机走完）
    private func revealAllRemaining() {
        guard let idx = streamingRowIndex, conversation.rows.indices.contains(idx),
              revealedCount < receivedChars.count else { return }
        revealedCount = receivedChars.count
        let text = String(receivedChars)
        conversation.rows[idx].block.text = text
        conversation.rows[idx].cachedHeight = conversation.rows[idx].height(in: contentWidth)
        delegate?.chatManagerDidUpdateStreamingText(self, rowIndex: idx, text: text)
    }

    /// 流式文本收尾：整条回写一次数据库，并复位本轮的流式状态。
    /// 正文只在收尾时落库一次，不跟着每一帧上屏写库。
    private func finalizeStreamingText() {
        guard let idx = streamingRowIndex, conversation.rows.indices.contains(idx) else { return }
        // 「一个字都没收到就结束了」的兜底：不留空白气泡
        // （出错路径已把正文换成失败提示，这里只管剩下的情形）
        if conversation.rows[idx].block.kind == .text, conversation.rows[idx].block.text.isEmpty {
            conversation.rows[idx].block.kind = .error
            conversation.rows[idx].block.text = Self.emptyReplyText
        }
        conversation.rows[idx].block.isStreaming = false
        // 「继续生成」的开关：只有**有正文、不是出错收尾、且没写完**的回复才点亮它。
        // 上面那个「空回复兜底」已把这行的 kind 改成 `.error`，这里再判一次 kind 就把它排除了
        //（一个字的回复没有「接着写」可言）。
        // ⚠️ 但**判定的时机**不在这里 —— 「正文上屏完」≠「整轮结束」，判定统一走
        //    `applyTruncationVerdict`（整轮没结束时它会拒答，留给 `finish()` 补判）。
        //    这里只把行号记下来，好让补判找得到同一行。
        verdictRowIndex = idx
        // 这里只为**副作用**调用（把判定写到 block.endedTruncated）；返回值这一处不用
        // —— 判定时机在 `finish()`（见上面注释）⇒ `_ =` 定点忽略，别给函数加
        //    `@discardableResult`（那会连 `finish()` 那处也一起放松）。
        _ = applyTruncationVerdict(rowIndex: idx)
        // token 用量只挂在**真正有正文的回复**上：失败提示、空回复都不该带一个 token 数字
        // （那会让人以为「报错也扣了这么多」）。`pendingUsage` 无条件清掉，别漏到下一轮。
        if conversation.rows[idx].block.kind == .text, let usage = pendingUsage, !usage.isEmpty {
            conversation.rows[idx].block.usage = usage
        }
        pendingUsage = nil
        // 思考收尾（2026-10-20）：
        // ① 纯思考回复（正文为空）在走到这里时耗时机还没封 —— 兜底封一次；
        // ② 流式中思考块是**自动展开**的，收尾即折叠成一行（用户之后可点开，见 setThinkingExpanded）；
        // ③ 失败提示 / 空回复不落思考（kind 不是 .text ⇒ store 侧同样不写）。
        sealReasoningDuration()
        conversation.rows[idx].isThinkingExpanded = false
        let reasoning = conversation.rows[idx].block.kind == .text
            ? conversation.rows[idx].block.reasoning
            : nil
        conversation.rows[idx].cachedHeight = conversation.rows[idx].height(in: contentWidth)   // 纯文本→Markdown，重算并存入模型
        if isPersisted {
            // 正文 + 类型 + 用量 + 思考 + 会话时间 = 一个事务（原来这里是 3 次独立提交）。
            // 类型必须一起回写：这一行可能在收尾时从「空文本占位」被改成「失败提示」，
            // 只改正文的话重启后仍会按文本渲染。
            // 用量 / 思考那两张表的写入也在同一个事务里 → 「正文在、用量丢」的中间态从根上不存在。
            store.finalizeMessage(conversationId: conversation.id,
                                  title: conversation.title,
                                  messageId: conversation.rows[idx].block.id,
                                  text: conversation.rows[idx].block.text,
                                  kind: conversation.rows[idx].block.kind,
                                  usage: conversation.rows[idx].block.usage,
                                  reasoning: reasoning)
        }
        streamingRowIndex = nil
        receivedChars = []
        revealedCount = 0
        // 收尾后「最后一条已结束的文本回复」可能就是这一行 → 先定操作栏 / 时间行归属并重算行高，
        // 再通知 UI（VC 会用行上的 showsActionBar / showsMeta 决定这一行怎么渲染）
        let layoutChanged = refreshRowDecorations()
        delegate?.chatManagerDidFinalizeRow(self, rowIndex: idx)
        let others = layoutChanged.filter { $0 != idx }
        if !others.isEmpty {
            delegate?.chatManagerDidUpdateRowLayout(self, atRowIndexes: others)
        }
    }

    // MARK: - 结束 / 错误

    private func finish() {
        // 收尾只认第一次：done 事件与随后关闭连接会各触发一次
        guard isReceiving else { return }
        isReceiving = false
        connection?.cancel()
        connection = nil
        // 先把全文落库：接下来打字机还要吐一会儿（大段可能几秒），
        // 这几秒里 App 被切掉也不该只剩半截话。收尾时还会再写一次，两次内容一致。
        persistFullTextNow()
        // **流结束 ≠ 已经上屏完**：真实平台很可能在结束时才把整段正文一次性发过来。
        // 所以「整轮结束」立刻通知（输入栏马上可用，不陪打字机等），
        // 正文继续匀速吐完，吐完才落地（Markdown 渲染）。
        pendingFinalize = true
        delegate?.chatManagerDidFinish(self)
        finalizeIfReady()
        // 🔴 补判一次「写完没有」：`finalizeStreamingText` 可能**早于**这里跑过
        //    （正文先吐完、`done` 后到 2.13s，见 `applyTruncationVerdict`）⇒
        //    那一行上的结论必须在这里纠正过来，否则「正常说完」会一直挂着「继续生成」。
        //    值真变了才通知 UI —— 常规路径（真实平台）这里永远无事可做，不该白重画一次。
        if let idx = verdictRowIndex, applyTruncationVerdict(rowIndex: idx) {
            delegate?.chatManagerDidFinalizeRow(self, rowIndex: idx)
        }

        // 🔴 自动记忆抽取（2026-10-25）：**整轮正常结束**才抽。落在这里而不是
        //    stop()/handleError()——那两条路这一轮是废的（被用户掐了 / 出错了），
        //    拿废轮抽记忆只会记进错误信息。`finish()` 只由 done 信号与「done 后
        //    连接关闭」两条路进来（见 `handleComplete`），天然排除废轮。
        //    惰性提供者：真正发请求排在去抖之后，那时间会话里可能又多了好几轮
        //    （见 `AIMemoryExtractor.trigger` 的说明）。
        AIMemoryExtractor.trigger { [weak self] in
            self?.recentTurnsForMemory() ?? []
        }
    }

    /// 喂给 `AIMemoryExtractor` 的最近几轮（一问一答算一轮）。
    ///
    /// 只取 `.text` 行：附件行 / 媒体行 / 错误行没有事实信息——错误行会把
    /// 「⚠️ 模型没有返回内容」当成用户事实记进去，那是纯噪声。
    /// 每条的截断由抽取器负责（`perMessageCap`），这里只管挑行。
    private func recentTurnsForMemory() -> [AIMemoryExtractor.Turn] {
        var turns: [AIMemoryExtractor.Turn] = []
        var rounds = 0
        for row in conversation.rows.reversed() {
            guard row.block.kind == .text else { continue }
            let text = row.block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            turns.insert(AIMemoryExtractor.Turn(role: row.role == .user ? .user : .assistant,
                                                text: text),
                         at: 0)
            if row.role == .user {
                rounds += 1
                if rounds >= AIMemoryExtractor.recentTurnCount { break }
            }
        }
        return turns
    }

    /// 把「已收到的完整正文」立刻写库（不看当前上屏到哪儿）
    private func persistFullTextNow() {
        guard isPersisted, !receivedChars.isEmpty,
              let idx = streamingRowIndex, conversation.rows.indices.contains(idx) else { return }
        // 同一个事务里回写正文 + 会话时间（原来 2 次独立提交）。
        // 此时用量还没定（要等收尾才算得出来）→ 传 `nil`，收尾那次再补上。
        // 思考则**现在就带**：它在正文之前就收完了（`persistFullTextNow` 只在有正文时跑，
        // 那一刻思考必然已到齐）—— 这几秒里 App 被杀也不该丢掉刚想完的那段。
        store.finalizeMessage(conversationId: conversation.id,
                              title: conversation.title,
                              messageId: conversation.rows[idx].block.id,
                              text: String(receivedChars),
                              kind: conversation.rows[idx].block.kind,
                              usage: nil,
                              reasoning: conversation.rows[idx].block.reasoning)
    }

    private func handleComplete() {
        // 服务端在 done 事件后关闭连接；这里兜底保证收尾（isReceiving 门禁保证重复调用无副作用）
        finish()
    }

    /// 出错收尾：把「为什么没回」写进对话流，而不是留一个空气泡。
    ///
    /// 两种情形都由 `finalizeStreamingText` 负责重算高度 / 回写数据库 / 通知 UI 重渲染：
    /// - **一个字都没收到**（401 / 402 / 429 / 断网，基本都在流开始前就返回）：
    ///   把那条空占位行**就地改成失败提示行**（kind 0 → 3）——不新增行、不删行，
    ///   seq 与消息计数都不动，也就不用引入删除接口。
    /// - **已收到部分正文**：正文照常保留（对用户有价值），失败提示**另起一行**补在后面。
    ///
    /// 出错不陪打字机走完：没上屏的尾巴直接补齐，让用户立刻看到发生了什么。
    private func handleError(_ error: Error) {
        // 同一轮可能被报两次错（流的 .failure 事件 + 连接关闭时带同一个 error），只认第一次
        guard isReceiving else { return }
        isReceiving = false
        pendingFinalize = false
        stopRevealTimer()
        // 出错收尾的这一行**不标**「被截断」：这一轮已经有失败提示行和「重试」入口了，
        // 再挂一个「继续生成」只会让人在两个入口之间犹豫（见 `endedByError` 的注释）
        endedByError = true

        let notice = Self.bubbleText(for: error)
        let placeholderIsEmpty = receivedChars.isEmpty

        if placeholderIsEmpty {
            // 空气泡没有任何信息量，直接把它变成「失败提示」
            if let idx = streamingRowIndex, conversation.rows.indices.contains(idx) {
                conversation.rows[idx].block.kind = .error
                conversation.rows[idx].block.text = notice
            }
        } else {
            revealAllRemaining()
        }
        finalizeStreamingText()

        connection?.cancel()
        connection = nil
        streamingRowIndex = nil

        // 已经有正文 → 提示另起一行，别把模型说过的那半截话覆盖掉
        if !placeholderIsEmpty {
            appendRow(.error(notice), role: .assistant)
        }
        delegate?.chatManager(self, didError: Self.friendly(error))
    }

    // MARK: - 错误文案

    /// 「流正常结束但一个字都没收到」时的提示。
    /// 没有它的话，占位气泡会以空正文留在列表和库里（长按还能弹出复制），和之前 402 那次是同一类问题。
    ///
    /// 🔴 **计算属性、⛔ 不是 `static let`**（2026-10-13 接本地化时踩到）：`static let` 会把
    ///    `L()` 的结果**进程级缓存**住 ⇒ 切语言后这条永远是旧语言那份，视图重建也救不回来。
    ///    同款坑全仓还有十来处，见 `.workbuddy/memory/I18N.md`。
    static var emptyReplyText: String { L("⚠️ 模型没有返回内容\n换个说法再试一次，或检查该模型的名称是否正确") }

    /// 后台宽限期用尽、这一轮被系统中断时写进对话流的提示（见 `handleBackgroundTimeExpired`）。
    /// 与 `emptyReplyText` 同样走 `.error` 行：能重试，且不会被 `contextMessages()` 回传。
    /// 🔴 同上：计算属性。
    static var backgroundInterruptedText: String { L("⚠️ 回复被系统中断\nApp 在后台停留过久，已保留收到的内容；点「重试」继续") }

    /// 写进对话流的失败提示（气泡正文）。
    /// 首行是「出了什么事」，次行是「你可以怎么办」——用户在列表里就能看懂，不必等 toast。
    static func bubbleText(for error: Error) -> String {
        let (brief, hint) = describe(error)
        return hint.isEmpty ? "⚠️ \(brief)" : "⚠️ \(brief)\n\(hint)"
    }

    /// 给 toast 用的单行版本（`AIChatManagerDelegate.didError` 回传的 localizedDescription）
    static func friendly(_ error: Error) -> Error {
        let (brief, _) = describe(error)
        let code = (error as? SSEHTTPStatusError)?.statusCode ?? (error as NSError).code
        return NSError(domain: "AIChatManager", code: code,
                       userInfo: [NSLocalizedDescriptionKey: brief])
    }

    /// 把底层错误翻成人话。
    /// - Returns: brief 一行短句；hint 可操作的下一步（可为空）
    private static func describe(_ error: Error) -> (brief: String, hint: String) {
        if let http = error as? SSEHTTPStatusError {
            switch http.statusCode {
            case 400:       return (L("请求格式有误（HTTP 400）"), L("多半是模型名或参数不对，去设置里检查"))
            case 401:       return (L("API Key 无效或未授权（HTTP 401）"), L("去设置里检查该平台的 API Key"))
            case 402:       return (L("账户余额不足（HTTP 402）"), L("请到该平台充值后再试"))
            case 403:
                // 🔴 2026-10-17（当天第三次同型坑）：403 **也有两种语义**，只有响应体
                //    的 `error.code` 分得清 ——
                //    ① `AccountOverdueError` = 账户欠费（余额被打光）。用户 Mac 端
                //       实测踩中：重新添加豆包后显示「无权访问该模型」，害我白查一轮
                //       权限；真相是账号欠费，与模型权限无关（换任何模型都是这个码）。
                //    ② 其余（模型没授权 / 账号被限）才是「无权访问」。
                //    ⚠️ 方舟把「可申请但未开通」的模型也列在 /models 里 ⇒ 别拿
                //       「在不在清单」当权限判据（那是 404 ModelNotOpen）。
                if http.serverErrorCode == "AccountOverdueError" {
                    return (L("账户欠费（HTTP 403）"), L("去火山方舟控制台充值后再试"))
                }
                return (L("无权访问该模型（HTTP 403）"), L("检查当前账号有没有该模型的权限"))
            case 404:
                // 🔴 2026-10-17：404 **必须按响应体分层** —— 同一个码在不同服务端
                //    语义完全不同，只报「接口地址不存在」会把用户引去改一个
                //    **本来就对的地址**（已两次实测踩中：上午 seedream 的 ID 笔误、
                //    当天下午 Mac 端豆包模型名）。
                //
                //    方舟 / OpenAI 兼容服务的 404 body 是
                //    `{"error":{"code":"InvalidEndpointOrModel.NotFound",
                //      "message":"The model or endpoint XXX does not exist or
                //      you do not have access to it"}}` —— 服务端自己说清了
                //    问题对象是**模型**（名字不对 / 没开通），不是端点。
                //    ⚠️ 且豆包那条的地址由代码强制预设（`defaultBaseURL`），
                //    界面压根没有填写入口 ⇒ 让用户「检查地址」是无解的建议。
                if let serverCode = http.serverErrorCode {
                    if serverCode == "InvalidEndpointOrModel.NotFound" {
                        return (L("模型不存在或没有访问权限（HTTP 404）"),
                                L("核对「模型名」是否填对；或去控制台确认已开通该模型"))
                    }
                    // 别家的 code（OpenAI 的 model_not_found 等）：透出服务端原话
                    return (String(format: L("服务端拒绝（HTTP 404）：%@"),
                                  http.serverMessage ?? serverCode), "")
                }
                // 没有 body 的裸 404 ⇒ 才可能是真·地址问题
                return (L("接口地址不存在（HTTP 404）"), L("地址要填到完整路径，如 /chat/completions"))
            case 429:       return (L("请求太频繁（HTTP 429）"), L("稍等片刻再发一次"))
            case 500...599: return (String(format: L("服务端异常（HTTP %d）"), http.statusCode), L("稍后重试，或换个平台"))
            default:        return (String(format: L("请求失败（HTTP %d）"), http.statusCode), "")
            }
        }
        if let config = error as? AIProviderError {
            // 配置类错误的文案本身就是「去哪儿改什么」，直接透出，不加额外提示
            return (config.errorDescription ?? L("配置有误"), "")
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet: return (L("网络连接不可用"), L("检查网络后重发"))
            case .timedOut:               return (L("请求超时"), L("稍后重试；开了思考模式会等更久"))
            case .cannotConnectToHost, .cannotFindHost:
                return (L("连接不上服务器"), L("确认服务地址；本地 mock 需先启动服务"))
            case .networkConnectionLost:  return (L("网络连接中断"), L("检查网络后重发"))
            default:                      return (String(format: L("网络异常（%d）"), urlError.code.rawValue), "")
            }
        }
        let fallback = error.localizedDescription
        return (fallback.isEmpty ? L("请求失败") : fallback, "")
    }

    // MARK: - 标题

    /// 取 prompt 第一句话作为对话标题（超过 20 字截断加省略号）
    static func title(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let stops: Set<Character> = ["。", "！", "？", "!", "?", "；", ";", "\n"]
        let end = trimmed.firstIndex(where: { stops.contains($0) }) ?? trimmed.endIndex
        var sentence = String(trimmed[..<end]).trimmingCharacters(in: .whitespaces)
        if sentence.isEmpty { sentence = trimmed }
        if sentence.count > 20 { sentence = String(sentence.prefix(20)) + "…" }
        return sentence
    }
}
