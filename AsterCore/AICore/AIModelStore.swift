//
//  AIModelStore.swift
//  AICore
//
//  **自定义模型的唯一配置源** —— 一份 JSON 文件（`Documents/models.json`）。
//
//  形态照 WorkBuddy（`~/.workbuddy/models.json`）：一个**数组**，每项一条模型，
//  自带 `url` / `apiKey` / 能力位 / 计价。改造前那种「一个平台一套配置」
//  （平台 → 地址写死 + 模型名 + MMKV 里的 Key 槽）在 2026-10-14 用户定案后整体退役
//  —— 用户原话：「我的 starryAI 也要像 WorkBuddy 这样 保存到 json 文件中」。
//
//  ## 🔴 三件必须记住的事
//  1. **文件位置刻意选 `Documents/`**：iOS 侧连带打开「文件」App 共享
//     （`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`），
//     ⇒ 用户能在手机「文件」/ Mac 访达里**直接手改**这份 JSON，改完下次进页面即生效。
//     这是 JSON 方案真正的价值（可手改 / 可备份 / 可迁移），不是「内部格式换成 JSON」。
//     ⚠️ 代价：`apiKey` 是**明文**存在这个可见文件里。这是与 WorkBuddy 一致的取舍
//     （它那份也是明文 + 在 home 下），**不是疏漏**。要收紧只需把 `fileURL()` 改指
//     `.applicationSupportDirectory` —— 一处改动，但代价是用户再也手改不了。
//  2. **`id` 就是发给服务端的模型标识**（与 WorkBuddy 同义），也是本地的唯一键。
//     ⚠️ 因此**同一个模型标识不能存两条**（想用同一个模型配两把 Key 是不支持的）。
//     要支持那种场景得另加一个 `uid` 字段并改唯一性判据，当前刻意不做（对齐 WorkBuddy）。
//  3. **JSON 是「配置」，不是「运行时状态」**：「现在用哪一条」存在 UserDefaults
//     （`currentID`，一个 id 字符串），**不写进文件** —— 否则用户手改文件会顺手把
//     「正在用哪个」也改掉，而那不是他改那份文件的目的。
//
//  ## 读取策略（为什么不是每次读盘）
//  `all()` 被输入栏胶囊、provider 工厂（每轮请求）等**高频**调用 ⇒ 内存缓存 + **mtime 校验**：
//  每次调用先看文件的修改时间有没有变，变了才重读。这样「用户在外面手改文件」也能生效
//  （进一次页面就刷新），而热路径上只是一次 `stat`。
//

import Foundation
import AIPlatform
import StarryKitCore

// MARK: - 一条模型配置（JSON 数组里的一项）

/// 「自定义模型」的一条。
///
/// 字段名与 WorkBuddy 的 `models.json` **逐字一致**（`id` / `name` / `vendor` / `url` /
/// `apiKey` / `supportsToolCall` / `supportsImages` / `supportsReasoning` /
/// `maxInputTokens` / `maxOutputTokens` / `reasoning.{defaultEffort,supportedEfforts}`），
/// 另有 Aster 自己补的 `pricing`（WorkBuddy 那份没有计价，而本工程的「用量与计费」
/// 是按模型算的）。
///
/// ⚠️ **除 `id` 外全部可缺省**：手写一份最小配置（只有 `id` / `url` / `apiKey` 三行）
/// 必须能跑 —— 解码时一律给默认值，⛔ 别改成「缺字段就整个解不出来」。
public struct AICustomModel: Codable, Identifiable, Hashable {

    // MARK: 字段

    /// 模型标识 —— **原样发给服务端的那串**（如 `deepseek-flash`），也是本地的唯一键。
    public var id: String

    /// 列表里显示的友好名（如 `DeepSeek-V4.1-Flash`）。**空 = 回落到 `id`**。
    ///
    /// ⚠️ 表单里没有这一栏（参考图只有 供应商 / API Key / 模型名称 三栏），保存时写的就是
    ///    用户填的模型名；想让它更好看，可以**手改 JSON** 单独给一个 `name`。
    public var name: String

    /// 供应商 —— 存的是 `AIProviderKind.rawValue`（`deepseek` / `zhipu` / `kimi` / `custom`）。
    ///
    /// 🔴 **刻意不存显示名**：那是随语言变的（中文档「深度求索」/ 英文档 "DeepSeek"），
    ///    存进文件会让同一条配置在切换语言后「看起来像变了个人」，也没法反查回预设。
    ///    显示时走 `vendorKind?.displayName`，取不到才拿这个串原样显示。
    public var vendor: String

    /// **完整的**对话端点（要写到 `/chat/completions`，不做自动拼接 —— 与改造前同一口径）。
    public var url: String

    /// API Key。**明文**（见文件头第 1 条）。
    public var apiKey: String

    /// 该模型认不认工具调用。⚠️ **当前本工程没有工具调用能力，这个字段只存不用** ——
    /// 留着是为了与 WorkBuddy 的字段集对齐（将来接工具时直接读它，不用改文件结构）。
    public var supportsToolCall: Bool

    /// 该模型收不收图片。
    ///
    /// 🔴 **显式值，不是推导值**：改造前是「按平台的特征串 + 模型名判」
    ///    （`AIProviderKind.visionModelMarkers`，因为地址与模型名都是代码里的常量）。
    ///    现在一条配置自带能力位 ⇒ 判据就落在这里。
    ///    ⚠️ 表单保存时会**按供应商预设 + 模型名算出**这个值填进来（`AICustomModel.inferFrom`），
    ///    所以从界面加出来的配置行为与改造前一致；手改 JSON 则可以直接覆盖。
    public var supportsImages: Bool

    /// 该模型认不认「思考模式」那两个请求字段（`reasoning_effort` / `thinking`）。
    ///
    /// ⚠️ 与改造前 `AIProviderKind.supportsThinkingParameter` 同义，只是从「按平台」改成「按条目」。
    /// ⚠️ **它只说明「这模型认不认」，不决定「这次发不发」** —— 发不发还看全局
    ///    `AIConfig.thinkingEnabled`（默认关，理由见那边：DeepSeek 默认开着会先吐十几秒
    ///    思考、正文一个字都没有，看起来像卡死）。
    public var supportsReasoning: Bool

    /// 上下文窗口（输入侧 token 上限）。缺省 = 按模型名查内置表
    /// （`AIContextBudget.window(forModel:)`）。
    public var maxInputTokens: Int?

    /// 输出侧 token 上限。⚠️ 当前**只存不发**（不往请求体里塞 `max_tokens`）——
    /// 同 `supportsToolCall` 那条理由：多一个不认识的顶层字段可能把本来能用的配置打挂，
    /// 而本工程目前没有任何地方需要限制输出长度。
    public var maxOutputTokens: Int?

    /// 思考模式的档位。`supportsReasoning` 为 true 且这里非空时才用得上。
    public var reasoning: Reasoning?

    /// 计价（元 / 百万 token）。**本工程自补的字段**，WorkBuddy 那份没有。
    /// 缺省 = `AIConfig.defaultPricing`。
    public var pricing: Pricing?

    // MARK: 嵌套

    /// 思考模式的档位（字段名对齐 WorkBuddy）。
    public struct Reasoning: Codable, Hashable {
        /// 默认档位（开着思考模式时发这个值）
        public var defaultEffort: String
        /// 可选的档位列表（当前 UI 没有切换入口，只存不展示）
        public var supportedEfforts: [String]

        public init(defaultEffort: String = "high", supportedEfforts: [String] = []) {
            self.defaultEffort = defaultEffort
            self.supportedEfforts = supportedEfforts
        }

        enum CodingKeys: String, CodingKey { case defaultEffort, supportedEfforts }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            defaultEffort = (try? c.decode(String.self, forKey: .defaultEffort)) ?? "high"
            supportedEfforts = (try? c.decode([String].self, forKey: .supportedEfforts)) ?? []
        }
    }

    /// 计价（元 / 百万 token）—— 与 `AIPricing` 同一个口径，只是能直接编解码。
    public struct Pricing: Codable, Hashable {
        public var cacheHitInput: Double
        public var cacheMissInput: Double
        public var output: Double

        public init(cacheHitInput: Double, cacheMissInput: Double, output: Double) {
            self.cacheHitInput = cacheHitInput
            self.cacheMissInput = cacheMissInput
            self.output = output
        }

        public init(_ value: AIPricing) {
            self.init(cacheHitInput: value.cacheHitInput,
                      cacheMissInput: value.cacheMissInput,
                      output: value.output)
        }

        /// 转回请求侧用的那个类型（`AIChatManager` 的计价读的是 `AIPricing`）
        public var asPricing: AIPricing {
            AIPricing(cacheHitInput: cacheHitInput, cacheMissInput: cacheMissInput, output: output)
        }

        enum CodingKeys: String, CodingKey { case cacheHitInput, cacheMissInput, output }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cacheHitInput = (try? c.decode(Double.self, forKey: .cacheHitInput)) ?? 0
            cacheMissInput = (try? c.decode(Double.self, forKey: .cacheMissInput)) ?? 0
            output = (try? c.decode(Double.self, forKey: .output)) ?? 0
        }
    }

    // MARK: 构造

    public init(id: String,
                name: String = "",
                vendor: String = "",
                url: String = "",
                apiKey: String = "",
                supportsToolCall: Bool = false,
                supportsImages: Bool = false,
                supportsReasoning: Bool = false,
                maxInputTokens: Int? = nil,
                maxOutputTokens: Int? = nil,
                reasoning: Reasoning? = nil,
                pricing: Pricing? = nil) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.url = url
        self.apiKey = apiKey
        self.supportsToolCall = supportsToolCall
        self.supportsImages = supportsImages
        self.supportsReasoning = supportsReasoning
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.reasoning = reasoning
        self.pricing = pricing
    }

    enum CodingKeys: String, CodingKey {
        case id, name, vendor, url, apiKey
        case supportsToolCall, supportsImages, supportsReasoning
        case maxInputTokens, maxOutputTokens, reasoning, pricing
    }

    /// 🔴 **逐字段容错**（`try?` + 默认值），不是 `decodeIfPresent` 就完事：
    /// 用户手改 JSON 时把 `supportsImages` 写成 `"true"`（字符串）这种事很常见，
    /// 那种情况下**整份文件解不出来** = 列表整个变空，比「这一项回落默认值」糟得多。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        vendor = (try? c.decode(String.self, forKey: .vendor)) ?? ""
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        apiKey = (try? c.decode(String.self, forKey: .apiKey)) ?? ""
        supportsToolCall = (try? c.decode(Bool.self, forKey: .supportsToolCall)) ?? false
        supportsImages = (try? c.decode(Bool.self, forKey: .supportsImages)) ?? false
        supportsReasoning = (try? c.decode(Bool.self, forKey: .supportsReasoning)) ?? false
        maxInputTokens = try? c.decodeIfPresent(Int.self, forKey: .maxInputTokens)
        maxOutputTokens = try? c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        reasoning = try? c.decodeIfPresent(Reasoning.self, forKey: .reasoning)
        pricing = try? c.decodeIfPresent(Pricing.self, forKey: .pricing)
    }

    // MARK: 展示

    /// 列表里那一行的主标题。`name` 没填就回落到 `id`。
    public var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : name
    }

    /// `vendor` 对应的预设（认不出时 nil —— 手改 JSON 写了个没见过的供应商名）。
    ///
    /// 🔴 **两路匹配、都做小写归一**（2026-10-14）：写这份文件的另一条路是「用户直接把
    ///    WorkBuddy 那份 `models.json` 拷过来」，而它写的是 `"vendor": "DeepSeek"`（**显示名**，
    ///    首字母大写）—— 只认 `rawValue` 的话，那条配置会「图标变成一个中性方块、
    ///    文档入口消失」，而这两种退化**都不会报错**，用户只会觉得「怎么跟另一台上不一样」。
    ///    ⚠️ 显示名那一路只在**当前语言**的档下命中（英文档 "DeepSeek" 碰得上，中文档
    ///    "深度求索" 碰不上）—— 所以 `rawValue` 那一路才是主路，显示名那路只是补漏。
    public var vendorKind: AIProviderKind? {
        let key = vendor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return AIProviderKind.allCases.first {
            $0.rawValue == key || $0.displayName.lowercased() == key
        }
    }

    /// 列表里那一行的副标题（供应商名）。
    public var vendorDisplayName: String {
        if let kind = vendorKind { return kind.displayName }
        let trimmed = vendor.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("自定义") : trimmed
    }

    /// 那一行左侧的小图标 —— 认不出预设时用个中性符号，⛔ 别让它变成空白。
    public var symbolName: String { vendorKind?.symbolName ?? "cube" }

    /// 品牌图标的 asset 名（认不出预设 / 该家没有品牌资产时为 nil）。
    /// ⚠️ 与 `symbolName` 成对使用，不是替代 —— 见 `iconImage(pointSize:)`。
    public var iconAssetName: String? { vendorKind?.iconAssetName }

    /// 直接可用的图标（asset 优先，SF Symbols 兜底）。
    ///
    /// 🔴 界面**只用这个**，⛔ 别在各处自己写 `UIImage(named:)`：
    ///    asset 取不到时它静默返回 nil，写成 `iconView.image = UIImage(named:)`
    ///    就是一片空白，而且编译、运行都不报错。
    public func iconImage(pointSize: CGFloat) -> AIPlatformImage? {
        vendorKind?.iconImage(pointSize: pointSize)
            ?? AIVendorIcon.image(asset: nil, symbol: "cube", pointSize: pointSize)
    }

    /// 那一行右侧「查看文档」能跳到哪。⚠️ 与 `vendorKind` 同源：认不出预设就没有文档入口
    /// （给个可能过期的硬编码链接比不给更糟）。
    public var documentationURL: URL? { vendorKind?.documentationURL }

    /// 计价，缺省补默认值。
    public var pricingOrDefault: AIPricing { pricing?.asPricing ?? AIConfig.defaultPricing }

    /// 上下文窗口：显式 `maxInputTokens` 优先，缺省按模型名查内置表。
    public var contextWindow: Int? {
        if let tokens = maxInputTokens, tokens > 0 { return tokens }
        return AIContextBudget.window(forModel: id)
    }

    /// 去空白的 `id`（请求体、报错文案、能力判断都用它 —— 别各自 trim 一遍）
    public var normalizedID: String { id.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 去空白的 `url`
    public var normalizedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: 预设推导

    /// 从「供应商预设 + 模型名」推出能力位（**表单保存时用**）。
    ///
    /// 🔴 把改造前那套「按平台 + 模型名判收不收图」的逻辑搬到这里，是为了让
    ///    **从界面加出来的配置行为与改造前一致** —— 用户从下拉里选 `glm-4v-plus`，
    ///    结果因为新结构默认不收图而发不出图片，那是纯粹的回归。
    ///
    /// ⚠️ `visionModelMarkers` 为空数组 = 该平台所有模型都收图（见那边的说明）。
    public static func inferFrom(kind: AIProviderKind, modelID: String, url: String? = nil) -> AICustomModel {
        let name = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let markers = kind.visionModelMarkers
        let images = markers.isEmpty ? true : markers.contains { name.contains($0) }
        return AICustomModel(id: modelID.trimmingCharacters(in: .whitespacesAndNewlines),
                             name: "",
                             vendor: kind.rawValue,
                             url: url ?? kind.defaultBaseURL,
                             apiKey: "",
                             supportsToolCall: true,
                             supportsImages: images,
                             supportsReasoning: kind.supportsThinkingParameter,
                             maxInputTokens: nil,
                             maxOutputTokens: nil,
                             reasoning: kind.supportsThinkingParameter
                                 ? Reasoning(defaultEffort: "high", supportedEfforts: ["high", "max"])
                                 : nil,
                             pricing: nil)
    }
}

// MARK: - 存储

public enum AIModelStore {

    // MARK: 文件

    /// `Documents/models.json`。
    ///
    /// ⚠️ 两端同一个调用（`.documentDirectory`）—— iOS 落在 App 容器、Mac 落在沙盒容器，
    ///    名字都是 `Documents`。**刻意不为了「Mac 上跟 WorkBuddy 一样放 `~/.workbuddy`」而分叉**：
    ///    Mac target 是**沙盒** App（`ENABLE_APP_SANDBOX = YES`），写用户的 home 需要额外的
    ///    「用户选定文件夹」授权，为对齐一个路径去申请那个权限不值得。
    public static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return dir.appendingPathComponent("models.json")
    }

    /// 给 UI 显示的文件路径（`~` 缩写过，太长会把标签撑开）
    public static var displayPath: String {
        (fileURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// 给 UI 显示用的**短**路径 —— 恒为 `Documents/models.json`。
    ///
    /// 🔴 为什么不用上面那个 `displayPath`：它是完整路径，iOS 上是
    ///    `/var/mobile/Containers/Data/Application/<UUID>/Documents/models.json`、
    ///    Mac 沙盒上是 `~/Library/Containers/<bundle id>/Data/Documents/models.json`
    ///    —— 两者都会把那行说明撑成两三行，而用户真正需要知道的只有
    ///    「它在 Documents 下、叫 models.json」。⛔ 别把这一行换成完整路径。
    public static var shortDisplayPath: String {
        fileURL.pathComponents.suffix(2).joined(separator: "/")
    }

    // MARK: 内存缓存

    private static var cache: [AICustomModel] = []
    /// 上次读盘时文件的修改时间。`nil` = 还没读过。
    private static var cacheStamp: Date?
    /// 上次读盘**失败**的原因（JSON 语法错误 / 根不是数组）。非 nil 时 UI 应当提示
    /// 「文件坏了、当前显示的是内存里的旧值」——⛔ 别静默当成空列表，那会诱导用户
    /// 以为「我的配置丢了」然后在 App 里重新加一遍、覆盖掉他手写的文件。
    public private(set) static var lastLoadError: String?

    // MARK: 读

    /// 全部配置（**按文件里的原顺序** —— 列表与选择器都照这个顺序显示，用户手改顺序即生效）。
    ///
    /// 首次调用会顺带做一次**初始化播种 / 老数据迁移**（见 `seedIfNeeded`）。
    public static func all() -> [AICustomModel] {
        seedIfNeeded()
        // 一次性：清掉老版本迁移留下的、用户从没添加过的预设残留（见那边的「三条安全措施」）。
        // ⚠️ 有闩，热路径上只多一次 `UserDefaults.bool(forKey:)` —— 可以忽略。
        purgeUntouchedPresetsIfNeeded()
        reloadIfChanged()
        return cache
    }

    /// 按 `id` 取一条。
    public static func model(id: String) -> AICustomModel? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return all().first { $0.id == key }
    }

    /// 强制重读（进页面 / 从后台回来时调 —— 用户可能在外面刚改过文件）。
    ///
    /// - Returns: 内容是否真的变了（变了才值得刷新 UI，避免无谓重绘）。
    @discardableResult
    public static func reload() -> Bool {
        let before = cache
        loadFromDisk()
        let changed = before != cache
        if changed { notifyChange() }
        return changed
    }

    private static func reloadIfChanged() {
        seedIfNeeded()
        guard let stamp = cacheStamp else { return loadFromDisk() }
        let mtime = modificationDate()
        guard mtime != stamp else { return }
        loadFromDisk()
    }

    private static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    private static func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            cacheStamp = nil
            lastLoadError = nil
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            if data.isEmpty {
                cache = []
                lastLoadError = nil
            } else {
                let decoded = try JSONDecoder().decode([AICustomModel].self, from: data)
                // 丢掉没有 id 的项（手写时漏了 `id` —— 它没法当键，留着只会让列表里
                // 出现一行点不动、删不掉的幽灵）
                cache = decoded.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                lastLoadError = nil
            }
            cacheStamp = modificationDate()
        } catch {
            // ⚠️ **不清空缓存、不动文件**：用户手改坏了 JSON 时，界面上仍显示他上一次的内容，
            //    并给出提示。若在这里 `cache = []` 再被某次保存写回去，他的手写内容就没了。
            lastLoadError = error.localizedDescription
        }
    }

    // MARK: 写

    /// 整份覆盖写（原子写：写临时文件再 rename，⛔ 别用普通 `write` —— 中途崩了会留下半份 JSON，
    /// 而这份文件正是配置的唯一来源，坏了就等于配置全丢）。
    public static func replaceAll(_ models: [AICustomModel]) {
        cache = models
        persist()
    }

    /// 新增 / 更新一条（按 `id` 匹配）。`id` 被改了的情况见下面的 `save(_:replacing:)`。
    public static func upsert(_ model: AICustomModel) {
        var models = all()
        if let index = models.firstIndex(where: { $0.id == model.id }) {
            models[index] = model
        } else {
            models.append(model)
        }
        replaceAll(models)
    }

    /// 「保存一条」——**表单那一套唯一的落库入口**。
    ///
    /// 与上面 `upsert` 的区别只有一个，但那个区别很要命：**`id` 被改了怎么办**。
    /// `id` 既是本地唯一键，也是发给服务端的模型名 ⇒ 用户在表单里把模型名从
    /// `deepseek-flash` 改成 `deepseek-pro`，语义是**改这一条**，不是「再加一条」。
    /// 若按新键去 `upsert`，结果是「老那条还在 + 多出一条新的」——同一份配置出现两份，
    /// 一条带着旧 Key，用户下次还得手动去删。
    ///
    /// - Parameter originalID: 打开表单时那条的 `id`（`nil` = 新增）。
    /// - 位置：替换时**留在原地**（用户文件里的顺序不该因为改一条就变）。
    /// - 撞名：新键与另一条同名时把**别处那条**摘掉（同一模型标识不能存两条，
    ///   否则「现在用哪条」有歧义 —— 见文件头第 2 条）。
    /// - 🔴 「当前使用」指针：改的如果正是正在用的那条，指针要**跟着换到新键** ——
    ///   不换就会悬空，而悬空会回落到第一条 ⇒ 用户看到的是「刚改完配置，聊天窗口偷偷换了模型」。
    public static func save(_ model: AICustomModel, replacing originalID: String? = nil) {
        let newID = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldID = originalID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var models = all()

        // 替换目标：优先老键（改名的情形），其次新键（没改名 / 新增时的常规匹配）
        let targetIndex = models.firstIndex { $0.id == oldID }
            ?? models.firstIndex { $0.id == newID }
        // 🔴 「老键」与「新键」**两条都要摘掉**，⛔ 只摘新键是错的 —— 这个错很隐蔽：
        //    · 没改名时两者相同 ⇒ 只摘新键恰好等于「摘掉被覆盖的那条」，**看着是对的**；
        //    · **改了名时新键此刻还不存在** ⇒ 只摘新键等于什么都没摘，于是结果是
        //      「老那条原样留着 + 多出一条新的」——正是这个方法存在的理由被整个绕过去了
        //      （`id` 既是本地唯一键、又是发给服务端的模型名，同一份配置出现两份，
        //       其中一份还带着旧 Key）。
        //    ☠️ 2026-10-14 就是这么写的，上线前的渲染台探针 ⑨② 当场抓到
        //       （「条数 5 → 6（必须相等）」）——纯靠读代码很难发现，因为**没改名那条路是对的**。
        var replacedKeys: Set<String> = [newID]
        if let oldID { replacedKeys.insert(oldID) }
        models.removeAll { replacedKeys.contains($0.id) }

        if let targetIndex {
            models.insert(model, at: min(targetIndex, models.count))
        } else {
            models.append(model)
        }

        if let oldID, oldID != newID, currentID == oldID { currentID = newID }
        replaceAll(models)
    }

    /// 删除一条。⚠️ 若删掉的正是「当前在用」的那条，**顺手把当前指针让给第一条**
    /// （否则指针悬空 ⇒ 输入栏胶囊会退化成显示平台名，看起来像坏了）。
    public static func remove(id: String) {
        var models = all()
        let before = models.count
        models.removeAll { $0.id == id }
        guard models.count != before else { return }
        if currentID == id { currentID = models.first?.id }
        replaceAll(models)
    }

    /// 写盘 + 广播（`lastLoadError` 一并清掉：能写就说明文件是我们自己生成的了）
    private static func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            // ☠️ `.withoutEscapingSlashes` **不能省**：不加的话 URL 会写成
            //    `https:\/\/api.deepseek.com\/...`，用户手改时极易改坏，也和 WorkBuddy 那份对不上。
            let data = try encoder.encode(cache)
            try data.write(to: fileURL, options: .atomic)
            cacheStamp = modificationDate()
            lastLoadError = nil
        } catch {
            lastLoadError = error.localizedDescription
        }
        notifyChange()
    }

    // MARK: 「当前使用」

    private static let currentIDKey = "ai_chat_current_model_id"

    /// 现在用哪一条（`id`）。⚠️ 存 UserDefaults、**不写进 JSON**（见文件头第 3 条）。
    public static var currentID: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: currentIDKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? nil : raw
        }
        set {
            let raw = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stored = raw.isEmpty ? nil : raw
            guard stored != currentID else { return }
            if let stored {
                UserDefaults.standard.set(stored, forKey: currentIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: currentIDKey)
            }
            notifyChange()
        }
    }

    /// 现在用的那条配置。
    ///
    /// 兜底顺序：指针指的 → 列表第一条 → `nil`（列表空）。
    /// ⚠️ 指针**悬空**（那条被删了 / 被手改改名了）时**回落到第一条而不是报错**：
    ///    发消息这件事不该因为一个过期的指针就整个不可用。与改造前
    ///    `currentProvider` 回落 `.deepSeek` 是同一个取向（「回落到最接近用户原来看到的样子」）。
    public static var current: AICustomModel? {
        let models = all()
        if let id = currentID, let hit = models.first(where: { $0.id == id }) {
            return hit
        }
        // 兜底顺序：指针指的 → 第一条 → `nil`（列表空）。
        // ⚠️ 指针悬空 / 指着一条已被删的配置时回落到第一条而不是报错：
        //    发消息这件事不该因为一个过期的指针就整个不可用。
        return models.first
    }

    /// 把「当前使用」钉住（列表非空而指针悬空/为空时调一次）。
    ///
    /// 与改造前 `ensureSessionModel` 同款语义：**只在没有值时落地一次**，绝不覆盖用户的选择。
    /// - Returns: 这一次是否真的写入了（留给夹具与日志当判据）。
    @discardableResult
    public static func ensureCurrent() -> Bool {
        let models = all()
        guard !models.isEmpty else { return false }
        if let id = currentID, models.contains(where: { $0.id == id }) {
            return false
        }
        currentID = models.first?.id
        return true
    }

    // MARK: 变更广播

    /// 清单变了（增 / 删 / 改 / 换当前项 / 从盘上重读到新内容）时发一条。
    ///
    /// 直接复用 `AIConfig.didChangeNotification`：观察者（输入栏胶囊、会话页标题、选择器）
    /// 已经在订那一条了，**另起一个名字只会让「只订了老名字的地方」静默不刷新** ——
    /// 那种症状是「改完模型，输入栏上还是老名字」，且不报任何错。
    private static func notifyChange() {
        NotificationCenter.default.post(name: AIConfig.didChangeNotification, object: nil)
    }

    // MARK: 初始化播种 / 迁移

    private static let didSeedKey = "ai_chat_models_json_seeded"

    /// 首次运行：**只把老存储里「用户真配过」的那几条迁过来**，⛔ **不再替他播预设**。
    ///
    /// 🔴 2026-10-14 用户要求：「自定义模型页面的列表数据，**只有在添加模型页面添加过的才显示**」。
    ///    初版是「三家预设各播一条」（为了保住改造前「开箱就有三家可选」的体验），
    ///    但那会让清单里凭空多出用户**从没添加过**的条目 —— 与「这一页只列我攒的」直接冲突。
    ///
    /// ⚠️ **迁移保留，但门槛是「他真配过」**（有自定义模型名 **或** 有 Key）：
    ///    那几条不是预设，是**他的数据** —— 不迁等于让他去服务商后台重新复制 Key
    ///    （很多 Key 只在创建时显示一次）。
    ///    ⇒ 全新用户没有老存储 ⇒ 清单是**空的**（首屏那颗胶囊显示「未配置模型」，
    ///      引导他去「添加模型」加一条）。这是刻意接受的代价，⛔ 别当成 bug 去补回预设。
    ///
    /// ⚠️ 只在**文件不存在**时跑（`didSeedKey` 防重入 —— 名字是沿革，语义现在是「首次已处理」；
    ///    ⛔ 别改这个键名，它已经在老用户的 UserDefaults 里了）。
    ///    文件存在（用户手写过 / 从别的机器拷过来）⇒ 什么都不做，交给 `loadFromDisk`。
    private static func seedIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didSeedKey) else { return }
        defaults.set(true, forKey: didSeedKey)

        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            loadFromDisk()
            return
        }

        let legacy = LegacyConfigSnapshot()
        var migrated: [AICustomModel] = []
        for kind in AIProviderKind.allCases {
            let storedModel = legacy.model(kind)
            // ☠️ 这一句是「只显示添加过的」的落点：**没配过的那家直接跳过**。
            //    没有它就会退回「三家预设各一条」——而那正是用户本轮要求去掉的东西。
            // 📌 2026-10-17：老 Key 的两个来源（MMKV / 钥匙串）都已退役 ——
            //    MMKV 分支随 `StarryMMKV` 删除，钥匙串分支随用户删除
            //    `StarryKeychain.swift`（10-09 盘点原话「一次性迁移用，迁完可删」）。
            //    ⇒ 迁移只剩模型名；Key 留空，用户到设置页补填。
            guard storedModel != nil else { continue }
            let entry = AICustomModel.inferFrom(kind: kind, modelID: storedModel ?? kind.defaultModel)
            migrated.append(entry)
        }
        // 🔴 一条都没迁到 ⇒ **不写文件**：写一个空数组等于把「文件不存在」变成「文件存在且为空」，
        //    从此 `all()` 不再走迁移分支（虽然此刻也没东西可迁，但语义上说不通）。
        guard !migrated.isEmpty else { return }
        cache = migrated

        // 老的「当前平台」→ 新的「当前使用」指针（认不出就留给 `current` 的第一条兜底）
        if let legacyProvider = legacy.provider,
           let hit = migrated.first(where: { $0.vendor == legacyProvider.rawValue }) {
            defaults.set(hit.id, forKey: currentIDKey)
        }
        persist()
    }

    // MARK: 一次性清洗：清掉「从没被碰过的预设残留」

    private static let didPurgePresetsKey = "ai_chat_models_purged_untouched_presets"

    /// 该条目是不是「**从没被用户碰过的预设残留**」。
    ///
    /// 四条**同时**成立才算（⛔ 少一条都不许清）：
    /// 1. 认得出预设（`vendorKind` 非 nil，且不是 `.custom`）—— 认不出的
    ///    （手改 JSON 写了个没见过的 vendor / 自建中转站）**是用户的东西**，一律不动；
    /// 2. `apiKey` 为空 —— 填过 Key 就说明他真走到这一步了；
    /// 3. `name` 为空 —— 自定义显示名只有手改 JSON 才会写；
    /// 4. `id` 与 `url` **双双等于该预设的默认值** —— 他连模型名和地址都没换过一下。
    ///
    /// 🔴 它要挡的是「**老版本迁移**留下的幽灵」：`seedIfNeeded` 的迁移门槛是
    ///    「有老模型名 **或** 有老 Key」，而老版本会把「用户在下拉里划过一下」的模型名
    ///    写进 UserDefaults（`ai_chat_model_zhipu` 之类）⇒ 升级后清单里凭空多出几家
    ///    他**从没添加过**的条目。2026-10-14 用户就是这么撞上的：
    ///    `glm-4-flash` / `kimi-k2.5` 两条，既没 Key、模型名与地址又正好是预设默认。
    ///
    /// ⚠️ 与「他添加了但还没填 Key」的区别：那种条目至少会换掉第 4 条里的一项
    ///    （表单里模型名只能从该家候选里挑，挑完就不是 `defaultModel` 了）⇒ **不会误清**。
    public static func isUntouchedPreset(_ entry: AICustomModel) -> Bool {
        guard let kind = entry.vendorKind, kind != .custom else { return false }
        guard entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return entry.normalizedID == kind.defaultModel
            && entry.normalizedURL == kind.defaultBaseURL
    }

    /// **一次性**清掉预设残留（只跑一次，闩 = `didPurgePresetsKey`）。
    ///
    /// 用户 2026-10-14 的原话：「AICustomModelListViewController 页面，**没有添加过的模型不显示**」。
    /// 问过口径后他选的是「**直接删掉**这些条目」（另两条候选是「只在列表里藏起来」与
    /// 「只显示配齐的」，都没要）⇒ 这里**真的动文件**，⛔ 不是显示层过滤。
    ///
    /// 🔴 三条安全措施（删用户配置必须全做到，⛔ 一条都不许省）：
    /// 1. **先备份**成同目录的 `models.json.bak-<时间戳>`。备份刻意放 `Documents/`
    ///    （与那份 JSON 同目录）⇒ 用户在「文件」App / 访达里看得见、捞得回；
    /// 2. 判据严（见 `isUntouchedPreset`：四条同时成立）；
    /// 3. **一条都没命中就不写文件** —— 避免无谓地把 mtime 改掉（那会让别处的
    ///    `reloadIfChanged` 白白重读一次）。
    ///
    /// ⚠️ 「当前使用」指针指着被清掉的条目时要**让给第一条**（与 `remove(id:)` 同款兜底）：
    ///    不让位会让胶囊悬空、回落到第一条 —— 那时用户看到的是「模型自己换了」，比删掉更费解。
    private static func purgeUntouchedPresetsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didPurgePresetsKey) else { return }
        defaults.set(true, forKey: didPurgePresetsKey)

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        loadFromDisk()
        let victims = cache.filter(isUntouchedPreset)
        guard !victims.isEmpty else { return }

        backupFile()
        cache.removeAll(where: isUntouchedPreset)
        let removedIDs = Set(victims.map(\.id))
        if let current = currentID, removedIDs.contains(current) { currentID = cache.first?.id }
        persist()

        #if DEBUG
        print("🧹 AIModelStore 清掉 \(victims.count) 条没碰过的预设残留："
              + victims.map(\.id).joined(separator: "、"))
        #endif
    }

    /// 把当前文件复制一份成 `models.json.bak-<时间戳>`（同目录）。
    ///
    /// 🔴 清洗是**删用户配置**的动作 ⇒ 必须先留退路：`apiKey` 很多只在服务商后台
    ///    创建时显示一次，删掉就得回去重新生成。
    /// ⚠️ 只会被 `purgeUntouchedPresetsIfNeeded` 调一次（它有闩）⇒ `Documents/` 下
    ///    最多留一个 `.bak-`，不会越攒越多。
    private static func backupFile() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("models.json.bak-\(formatter.string(from: Date()))")
        try? FileManager.default.copyItem(at: fileURL, to: backup)
    }

    /// 改造前那套存储的快照（**只读**，不清理）。
    ///
    /// 🔴 刻意**不删**这些老键：老模型名在 UserDefaults 里 —— 它此刻已经是
    ///    「没人读的死数据」，而删它要再加一次启动期 I/O。
    ///    （老 Key 的两个来源 MMKV / 钥匙串均已退役：前者随 `StarryMMKV` 删除，
    ///     后者随用户删除 `StarryKeychain.swift` —— 磁盘残留都是无害孤儿。）
    ///    留着还有一层保险：万一 JSON 这条路出了大问题，用户的老配置还能被人工捞回来。
    ///    （同改造前 `baseURL` 那条「老设备的死键刻意不清理」的取向。）
    private struct LegacyConfigSnapshot {

        let provider: AIProviderKind?

        init() {
            let raw = UserDefaults.standard.string(forKey: "ai_chat_provider") ?? ""
            provider = AIProviderKind(rawValue: raw)
        }

        func model(_ kind: AIProviderKind) -> String? {
            // 会话槽优先（它才是「用户最近实际在用的」），再回落设置里配的
            for key in ["ai_chat_session_model_\(kind.rawValue)", "ai_chat_model_\(kind.rawValue)"] {
                let value = UserDefaults.standard.string(forKey: key)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !value.isEmpty { return value }
            }
            return nil
        }
    }
}
