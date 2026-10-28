//
//  AIGenerationSettings.swift
//  AICore
//
//  「怎么生成」的**用户偏好存取点**（2026-10-20 随设置页新入口新增）——
//  系统提示词（指令）+ 采样参数（温度 / 最大长度）+ 思考过程展示开关 + 联网搜索开关
//  + 项目资料检索开关（RAG，2026-10-23）。
//
//  ## 它管五件事
//  ① **系统提示词**（`systemPrompt`）：每轮请求最前面一条 `role: system` 消息。
//     注入点在 `AIChatManager.withSystemPrompt`（trim 之后，永不被裁）。
//  ② **采样参数**（`temperatureEnabled` / `temperature` / `maxTokensEnabled` / `maxTokens`）：
//     读点在 `OpenAICompatibleProvider.body`。**默认关 = 不发字段、用服务端默认**
//     （o1 类模型只认 temperature=1，乱发会把本来能用的配置打挂 —— 与
//     `stream_options` / `reasoning_effort` 那些扩展字段同一条理由）。
//  ③ **展示思考过程**（`showsThinkingProcess`）：思考内容的渲染与落库总闸，
//     默认开。消费方是聊天行渲染（2026-10-20 同轮实现）。
//  ④ **联网搜索**（`webSearchEnabled`，2026-10-21 加）：是否先检索再回答，**默认关**。
//     消费方是 `AIChatManager.beginStreaming`（唯一判据）；检索见 `AIWebSearch`。
//  ⑤ **项目资料检索**（`projectSearchEnabled`，2026-10-23 加，RAG 第一版）：
//     发送前先在本项目已索引的资料里检索片段，拼进本轮 user 消息。**默认关**。
//     ⚠️ 2026-10-23 当晚用户拍板「默认关闭 + 删掉两端输入栏的放大镜入口」⇒ 现在
//     **没有任何 UI 写点**（底层链路全保留，见该属性的文档与
//     `resetLegacyProjectSearchEntry()`；恢复指南 `VERIFY-PROBES.md` §32.4）。
//     消费方是 `AIChatManager.beginProjectRetrieval`（唯一判据）；检索见 `AIProjectRetriever`。
//
//  ## 为什么存取点在共享层（而不是两端各写一份）
//  与 `AINotificationPreferences` / `AIFontSizeStore` 同款理由：消费方在共享层
//  （provider / chat manager 都在 AICore），两端 UI 只是**读写同一组 key**
//  （UserDefaults 两端本就互相独立，各存各的）。⛔ 别在某一端另写一个 store：
//  默认值会散成两份，改默认值那天必漏一处。
//
//  ## 🔴 非 `@Observable` ⇒ UI 层必须配 `@State` 镜像
//  全部是静态计算属性，写它**不会**让任何界面重算（Mac 铁律：「读它界面不动，
//  编译得过、不报错」）。两端设置页因此都镜像一份（见各自文件头）。
//  聊天行那边（思考展示）不镜像 —— 它靠 `didChangeNotification` 被动刷新，
//  见下面「变更广播」。
//
//  ## 🔴 与 `AIConfig.thinkingEnabled` 是**两件事**，别混
//  那个回答「这次请求发不发思考字段」（请求侧，随模型能力位）；
//  这个回答「思考内容显不显示、存不保存」（展示侧，与模型无关）。
//

import Foundation

// MARK: - 快捷预设

/// 系统提示词的**快捷预设**（两端设置页共用同一份 —— 单一真值，⛔ 别各写一份）。
///
/// 标题走 `L()`（界面文案）；正文是**要发给模型的内容**（与用户输入同性质），
/// 按本工程口径不进词表（见 `AILocalization` 文件头「范围」）。
public enum AIInstructionPreset: CaseIterable {

    case general
    case translate
    case codeReview

    /// 预设标题（界面文案 ⇒ 走 `L()`）。
    public var title: String {
        switch self {
        case .general:    return L("通用助手")
        case .translate:  return L("中译英")
        case .codeReview: return L("代码审查")
        }
    }

    /// 预设正文（写进指令编辑器的那段话）。
    public var body: String {
        switch self {
        case .general:
            return "你是一名严谨的技术顾问。回答先给结论，再给理由；不确定时直说，不要编造。"
        case .translate:
            return "你是一名专业的商务翻译。把用户发来的内容译成自然、地道的英文，保留原有格式与礼貌语气，不要增删信息，不要解释译文。"
        case .codeReview:
            return "你是一名严格的前端代码评审者。按「正确性 → 边界条件 → 性能 → 可读性」的顺序指出问题，每条给出文件位置、原因与改法；没有问题的方面直接说「通过」，不要凑数。"
        }
    }
}

// MARK: - 存取点

/// 「怎么生成」偏好的**唯一存取点**。
public enum AIGenerationSettings {

    // MARK: 键

    /// ⚠️ 带命名空间前缀：`UserDefaults` 是与系统及其它版本共用的命名空间
    ///    （与 `AINotificationPreferences` / `AILanguageStore` 同款理由）。
    ///    两端**键名故意相同**：同一个偏好，各存在各自的容器里。
    private static let promptKey          = "Aster.generation.systemPrompt"
    private static let temperatureEnabledKey = "Aster.generation.temperatureEnabled"
    private static let temperatureKey     = "Aster.generation.temperature"
    private static let maxTokensEnabledKey = "Aster.generation.maxTokensEnabled"
    private static let maxTokensKey       = "Aster.generation.maxTokens"
    private static let showsThinkingKey   = "Aster.generation.showsThinking"
    private static let webSearchKey       = "Aster.generation.webSearchEnabled"
    private static let projectSearchKey   = "Aster.generation.projectSearchEnabled"

    // MARK: ① 系统提示词

    /// 每轮请求最前面的系统提示词。空 = 不发 system 消息（与功能上线前逐字节一致）。
    ///
    /// ⚠️ 写入带「变了才发」守卫：指令编辑器**每次击键**都会走到这个 setter，
    ///    无脑发广播会让订 `didChangeNotification` 的聊天行白刷新一整套。
    public static var systemPrompt: String {
        get { UserDefaults.standard.string(forKey: promptKey) ?? "" }
        set {
            guard newValue != systemPrompt else { return }
            UserDefaults.standard.set(newValue, forKey: promptKey)
            notifyChange()
        }
    }

    // MARK: ①′ 指令字数上限（2026-10-27 收成单一真值）

    /// 指令字数上限（全局指令与项目指令**共用同一个数**）。
    ///
    /// ## 为什么收到共享层
    /// 原来 2000 散在四处：iOS 全局页的 `maxLength`、Mac 设置页那句
    /// `"\(prompt.count) / 2000"`（⛔ 字面量直接写死在插值里）、Mac 项目面板。
    /// 改数是「一处改完另外三处静默不动」的典型形态 —— 而它的表现是**字数行说
    /// 还能写、写进去却被拒**（或反过来），不报任何错。
    ///
    /// ## 量级依据
    /// 2000 字 ≈ 1500 token 以内，相对 32K+ 的上下文窗口是可接受误差；
    /// 再长的「人设」既没人读得完，也在每轮请求里重复计费。
    ///
    /// ⚠️ 上限只管**编辑器入口**（`clampInstruction` 被各编辑器调用），
    ///    `systemPrompt` 的 setter **不**做截断 —— 它是存取点，不是 UI 闸门；
    ///    在存取点里静默截断会让「手改 plist 的旧数据」在下次读取时莫名变短。
    public static let instructionMaxLength = 2000

    /// 把指令文本钳到 `instructionMaxLength` 以内（编辑器侧唯一截断口径）。
    ///
    /// 🔴 各编辑器的 `onChange` 都走它：iOS 那边是 `shouldChangeTextIn` **拒掉整次编辑**
    ///    （粘贴超长时更友好：不会把光标弹到末尾），Mac 这里只能拿到「已经变了」的值
    ///    ⇒ 截断后回写。两者结果同一条：**存进去的永远 ≤ 上限**。
    /// ⚠️ 已经在限内时**原样返回**（同一实例），调用方据此判断「要不要回写」——
    ///    无脑回写会让 `onChange` 多跑一轮（虽不报错，但会与防抖保存耦合出两次写库）。
    public static func clampInstruction(_ text: String) -> String {
        text.count > instructionMaxLength
            ? String(text.prefix(instructionMaxLength))
            : text
    }

    // MARK: ② 采样参数

    /// 温度取值范围（0 = 最确定，2 = 最随机）。UI 的 slider 与取整都照它。
    public static let temperatureRange: ClosedRange<Double> = 0...2
    /// 最大长度取值范围（token）。下限 256：再低的「最大长度」没有实用意义。
    public static let maxTokensRange: ClosedRange<Int> = 256...8192
    /// 推荐值（「重置为推荐值」与 slider 默认落点都用它）。
    public static let defaultTemperature: Double = 0.7
    public static let defaultMaxTokens: Int = 4096

    /// 是否**自定义**温度。关 = 请求不带 `temperature` 字段，用服务端默认。
    ///
    /// 默认关：o1 / 推理类模型只认 temperature=1，无脑发 0.7 会 400 ——
    /// 「默认不发」比「默认发个值」安全得多（与 `body()` 里那些扩展字段同一条理由）。
    public static var temperatureEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: temperatureEnabledKey) }
        set {
            guard newValue != temperatureEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: temperatureEnabledKey)
            notifyChange()
        }
    }

    /// 温度（`temperatureEnabled` 开时才发）。越界值钳回范围 ——
    /// 手改 plist / 将来改范围都不会把请求打挂。
    ///
    /// ⚠️ 没存过时返回 `defaultTemperature`（**不是** `double(forKey:)` 的 0）——
    ///    用户第一次打开开关，slider 就该落在推荐值上，落在 0 会被当成「存过 0」。
    public static var temperature: Double {
        get {
            guard UserDefaults.standard.object(forKey: temperatureKey) != nil else { return defaultTemperature }
            return UserDefaults.standard.double(forKey: temperatureKey).aiClamped(to: temperatureRange)
        }
        set { UserDefaults.standard.set(newValue.aiClamped(to: temperatureRange), forKey: temperatureKey) }
    }

    /// 是否**自定义**最大长度。关 = 不带 `max_tokens`，用服务端默认。
    public static var maxTokensEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: maxTokensEnabledKey) }
        set {
            guard newValue != maxTokensEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: maxTokensEnabledKey)
            notifyChange()
        }
    }

    /// 最大长度（token，`maxTokensEnabled` 开时才发）。越界值钳回范围。
    ///
    /// ⚠️ 与 `temperature` 同款：没存过时返回 `defaultMaxTokens` ——
    ///    `integer(forKey:)` 未设置返回 0，钳一下会变成下限 256，那是个假值。
    public static var maxTokens: Int {
        get {
            guard UserDefaults.standard.object(forKey: maxTokensKey) != nil else { return defaultMaxTokens }
            return UserDefaults.standard.integer(forKey: maxTokensKey).aiClamped(to: maxTokensRange)
        }
        set { UserDefaults.standard.set(newValue.aiClamped(to: maxTokensRange), forKey: maxTokensKey) }
    }

    // MARK: ③ 思考过程展示

    /// 是否展示（并保存）思考过程。默认 **开**。
    ///
    /// 与 `AIConfig.thinkingEnabled`（请求侧）分工见文件头 🔴。
    /// 关掉后：聊天行不渲染思考块、流式增量不落库（已落的历史仍在库里，
    /// 但不渲染 —— 判据是渲染时现读，见消费方注释）。
    public static var showsThinkingProcess: Bool {
        get { UserDefaults.standard.object(forKey: showsThinkingKey) as? Bool ?? true }
        set {
            guard newValue != showsThinkingProcess else { return }
            UserDefaults.standard.set(newValue, forKey: showsThinkingKey)
            notifyChange()
        }
    }

    // MARK: ④ 联网搜索

    /// 本轮是否**先联网检索、把结果当参考资料再回答**。默认 **关**。
    ///
    /// 🔴 为什么默认关（用户 2026-10-21 拍板）：检索发生在**首字之前**（实测 1.4–4.0s），
    ///    开着会让「本来能直接答」的问题白等这几秒；而日常问答多数不需要实时网页。
    ///    代价落在**每一次**发送上，收益只落在少数问题上 ⇒ 默认关、用户手动开、记住选择。
    ///
    /// 🔴 这是**每轮会变**的开关 ⇒ 入口在两端输入栏控制行（本工程铁律：
    ///    控制行只放「每轮会变」的东西），⛔ 别搬进设置页 —— 搬进去等于把它变成
    ///    「一开就永久生效」的全局设置，用户在某个问题前想临时关一下就没地方点了。
    ///
    /// 消费方：`AIChatManager.beginStreaming`（唯一判据）。⛔ 别在 UI 层再判一次 ——
    /// 两处判一个开关，迟早出现「界面亮着但没搜」或反过来。
    public static var webSearchEnabled: Bool {
        get { UserDefaults.standard.object(forKey: webSearchKey) as? Bool ?? false }
        set {
            guard newValue != webSearchEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: webSearchKey)
            notifyChange()
        }
    }

    // MARK: ⑤ 项目资料检索（RAG，2026-10-23）

    /// 本轮是否**先在本项目已索引的资料里检索**，把相关片段当参考资料再回答。默认 **关**。
    ///
    /// 🔴 2026-10-23 当晚：**入口已删**（用户拍板「默认关闭，把两端输入栏的放大镜删掉」）——
    ///    两端输入栏控制行那颗钮、`@Observable` 镜像、通知观察、验收探针全部下线。
    ///    **底层一条没删**：`beginProjectRetrieval` 判据 / `AIProjectRetriever` 打分 /
    ///    `ai_project_file_chunk` 表 / 导入即建索引 / 详情页索引状态行，全都还在 ——
    ///    删的只是「谁能把它打开」。想恢复入口：`VERIFY-PROBES.md` §32.4 有清单。
    ///
    /// ⚠️ 因此这个 setter 现在**没有 UI 写点**，值只会是 false（默认）或**存量 true**
    ///    （10-23 白天的探针点亮过）。两端冷启动各调一次
    ///    `resetLegacyProjectSearchEntry()` 把存量清成 false —— 否则症状是
    ///    「按钮删了，却每轮静默检索」（请求体多一段资料块，无声无息、不报错）。
    ///
    /// 🔴 为什么当初默认关、最终又删入口（保留记录，⛔ 当既成事实接受）：
    ///    检索发生在**首字之前**（本地库是毫秒级，但拼进来的片段会改变这一轮上下文），
    ///    而关键词评分有**假阳性**（中文二字组 + ASCII 词只认字面、不认意）——
    ///    「永远开」等于替用户把不相关片段当参考资料喂给模型。默认关 + 入口下线
    ///    是同一条用户决策（2026-10-21 为联网拍过「默认关」，10-23 为 RAG 拍到「删入口」）。
    ///
    /// ⚠️ 与 `webSearchEnabled` 是**两条独立的路**：联网搜公网、这个翻项目私料，
    ///    可以同时开（资料块都拼在本轮 user 消息头部，见 `withProjectDigest`）。
    public static var projectSearchEnabled: Bool {
        get { UserDefaults.standard.object(forKey: projectSearchKey) as? Bool ?? false }
        set {
            guard newValue != projectSearchEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: projectSearchKey)
            notifyChange()
        }
    }

    /// 把「项目资料检索」偏好清成默认关（2026-10-23 入口下线时加）。
    ///
    /// **为什么需要它**：入口删了，但 `projectSearchKey` 是个 UserDefaults 键 ——
    /// 10-23 白天开发/验收期间它被点亮过（探针 `on` 档与 `tap` 档都会写真值）。
    /// 不清的话那些值会一直躺在库里，症状是「删了按钮却每轮静默检索」。
    /// 两端冷启动各调一次（Mac `ChatModel.init` / iOS `configureInputToolbar()`），
    /// 幂等（setter 的 guard 把着，值没变连通知都不发）。
    public static func resetLegacyProjectSearchEntry() {
        projectSearchEnabled = false
    }

    // MARK: 重置

    /// 全部恢复默认（指令清空、两项采样回到「跟随服务端默认」、思考展示开、联网搜索关、
    /// 项目资料检索关）。「恢复默认」按钮在两端设置页各有一个，走的是这一个方法。
    public static func resetToDefaults() {
        systemPrompt = ""
        temperatureEnabled = false
        temperature = defaultTemperature
        maxTokensEnabled = false
        maxTokens = defaultMaxTokens
        showsThinkingProcess = true
        webSearchEnabled = false
        projectSearchEnabled = false
        // 六个写点各自都会 notifyChange ⇒ 这里不另发（幂等由 guard 把着，
        // 但重复发同一通知会让观察方白刷新几遍，没必要）。
    }

    // MARK: 变更广播

    /// 任一偏好变更时发出（写点统一走 `notifyChange`）。
    ///
    /// **为什么需要它**：系统提示词 / 采样参数的消费方（provider、chat manager）
    /// 都是**现读**，不需要广播；但「展示思考过程」的消费方是**已渲染的聊天行** ——
    /// 用户在设置里关掉它时，屏幕上那些思考块不会自己消失。聊天行视图订这条通知
    /// 即可被动刷新（2026-10-20 同轮接线，见两端聊天行文件头）。
    public static let didChangeNotification = Notification.Name("ai_generation_settings_did_change")

    private static func notifyChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

// MARK: - 取整工具

extension Comparable {
    /// 钳到闭区间（`UserDefaults` 里可能是旧版本 / 手改的越界值）。
    ///
    /// ⚠️ 叫 `aiClamped` 而不是 `clamped(to:)`：后者是新版标准库给 `Comparable`
    ///    加的同名方法，直接写 `clamped` 有撞名风险（本工程 Swift 6 工具链）。
    func aiClamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
