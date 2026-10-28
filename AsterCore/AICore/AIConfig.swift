//
//  AIConfig.swift
//  AIModule
//
//  AI 模块的**配置门面**：设置侧写入，发起请求时读取。
//
//  ## 🔴 2026-10-14 存储换血：一份 JSON 取代了 UserDefaults + MMKV
//  改造前分三处存：平台 / 模型名（UserDefaults）、Key（MMKV）、服务地址（代码常量 + 一次性迁移）。
//  用户 2026-10-14 定案（原话「我的 starryAI 也要像 WorkBuddy 这样 保存到 json 文件中」）后：
//
//      **`Documents/models.json` = 唯一的配置源**（读写全在 `AIModelStore`）
//
//  - **一条配置 = 一个模型条目**（`AICustomModel`）：自带 `url` / `apiKey` / 能力位 / 计价。
//    「一个平台一套配置」那套（平台 → 地址写死 + 模型槽 + Key 槽）整体退役。
//  - `AIProviderKind` **降级成「供应商预设」**：不再是配置主键，只负责
//    ① 给「添加模型」表单预填地址与能力位；② 提供图标 / 文档链接 / 视觉模型名提示。
//  - 🔴 **两个槽位合并成一个**：「设置里配的」与「会话窗口选的」当初是靠两个 UserDefaults 键
//    分开存的（用户 2026-09-22 / 2026-10-02 两次要求「进设置改配置不许顶掉正在聊的窗口」）。
//    现在**设置页根本不配模型了**——它只管「这份清单里有哪些模型」，不回答「现在用哪个」，
//    那个拆分的理由从根上消失。于是只剩一个指针：`AIModelStore.currentID`。
//  - 「当前用哪个」是**运行时状态**，仍存 UserDefaults，**不写进 JSON**（理由见 `AIModelStore` 文件头）。
//
//  ## 什么变、什么没变
//  - ✅ **变了**：配置的存在形式、页面结构（设置入口 → 自定义模型列表页 → 添加模型表单）。
//  - ⛔ **没变**：请求怎么发（OpenAI 兼容）、Markdown 渲染、上下文预算、token 统计、
//    思考模式默认关。这些一行不动。
//
//  ⚠️ Key 现在**明文**躺在那个可见的 JSON 里（`Documents/` 会对「文件」App 开放）。
//     这是照 WorkBuddy 那份抄的取舍，不是疏漏 —— 要收紧只需改
//     `AIModelStore.fileURL` 指向 `.applicationSupportDirectory`，代价是用户再也手改不了。
//

import Foundation

// MARK: - 供应商预设

/// 供应商**预设**（2026-10-14 起语义变了：不再当配置主键用）。
///
/// 五家官方（深度求索 / 智谱 / Kimi / 豆包 / MiniMax）+ 一个「自定义」。它的作用只剩三件：
/// ① 「添加模型」表单里选它 → 自动填地址、能力位、文档入口（`AICustomModel.inferFrom`）；
/// ② 列表行上显示图标与供应商名（`AICustomModel.vendorKind` 反查回来）；
/// ③ 报错文案里说清「是哪一家的哪个模型」（`AIProviderError`）。
///
/// 🔴 **新增一家 = 加一个 case + 补全下面几个属性**：五家都走同一套 OpenAI 兼容协议
///    （`OpenAICompatibleProvider`），接入层一行都不用改。
public enum AIProviderKind: String, CaseIterable {

    /// 深度求索（DeepSeek 官方，OpenAI 兼容）
    case deepSeek = "deepseek"
    /// 智谱开放平台（GLM，OpenAI 兼容）
    case zhipu = "zhipu"
    /// Kimi（月之暗面 Moonshot，OpenAI 兼容）
    case kimi = "kimi"
    /// 豆包（字节跳动 · 火山方舟 Ark，OpenAI 兼容）
    ///
    /// 🔴 2026-10-16 接入（用户要用豆包）。**接入层零改动**：方舟 `/api/v3` 是标准
    ///    OpenAI 兼容协议（chat/completions + Bearer Key），与三家走同一个
    ///    `OpenAICompatibleProvider`。
    /// ⚠️ 两个方舟特有的点（都已按官方文档/实测落实）：
    ///    ① `GET /api/v3/models` **真实存在**（无 Key 探到 401，不是 404）⇒
    ///       「测试连接」沿用现成的清单拉取，无需降级方案；
    ///    ② 模型 ID 是**带日期的版本名**（`doubao-seed-2-1-turbo-260628`）——
    ///       官方模型广场直接抄，⛔ 别凭记忆写旧名（会 404/model not found）。
    case doubao = "doubao"
    /// MiniMax（稀宇科技，OpenAI 兼容，2026-10-17 接入）。
    ///
    /// 🔴 第五家官方平台，**接入层零改动**：`api.minimax.chat/v1` 是标准 OpenAI 兼容
    ///    协议（chat/completions + Bearer Key + /models），与另外四家走同一个
    ///    `OpenAICompatibleProvider`。
    /// ⚠️ 三个 MiniMax 特有的点（接入前已按官方文档核实）：
    ///    ① **域名按 Key 的类型分流**：中国大陆 Key 在 `api.minimax.chat`，Global Key 在
    ///       `api.minimax.io` —— 用错域名的表现是 401/404，与「Key 填错」一模一样。
    ///       这里取 `.chat`（大陆站，对齐本 App 其他四家「国内直连」的取向）；
    ///       Global Key 的用户走「自定义」填 `api.minimax.io`。
    ///    ② 模型 ID 是 **CamelCase**（`MiniMax-M3`）—— 官方文档与 `/models` 返回的都是
    ///       这个形状，⛔ 别凭印象写成小写（`minimax-m3` 那种是博客里的错误抄写）。
    ///    ③ 思考参数是 `thinking: {type: "disabled"|"enabled"|"auto"}`（嵌套对象），
    ///       与豆包同形 ⇒ `supportsThinkingParameter` 刻意**不给**它（照 DeepSeek 那套
    ///       顶层字段发过去大概率 400，见那边注释）。
    case minimax = "minimax"
    /// 自填服务地址的 OpenAI 兼容服务（中转站 / 自建网关 / 本机服务）。
    ///
    /// ⚠️ 它 2026-10-13 曾被删过一次（当时用户要求「只保留三家官方平台」），
    ///    2026-10-14 随 JSON 化**必须加回来**：一条配置自带 `url`，
    ///    若供应商下拉里没有「自定义」，那个 `url` 字段在界面上就**没有任何填写入口**——、
    ///    用户只能去手改 JSON。WorkBuddy 的供应商下拉里同样有 Custom。
    case custom = "custom"

    /// 列表 / 胶囊 / 报错里显示的名字。
    /// ⚠️ 走词表（中文档「深度求索」/ 英文档 "DeepSeek"）—— 它们是**品牌名**，
    ///    中文档里写中文是刻意的（对齐官方中文站），英文档才切回拉丁写法。
    public var displayName: String {
        switch self {
        case .deepSeek: return L("深度求索")
        case .zhipu:    return L("智谱开放平台")
        case .kimi:     return L("Kimi 中国版")
        case .doubao:   return L("豆包")
        case .minimax:  return L("MiniMax")
        case .custom:   return L("自定义")
        }
    }

    /// 下拉 / 列表行左侧的小图标 —— **asset 名**（品牌图形，优先用这个）。
    ///
    /// 🔴 2026-10-20 用户定案接入真实品牌图标（LobeHub 那套单色 24×24 矢量，
    ///    统一笔触），渲染取 **A 方案**：单色 + template，跟随文字色 —— 与原有
    ///    SF Symbols 的图标语言完全一致，除图形本身外不动任何视觉。
    ///    ⚠️ **例外 = Kimi**：它是官方 app-icon 形态（黑底白 K 蓝点），走原色，
    ///    见 `iconKeepsBrandColor`。
    /// ⚠️ 与 `symbolName` **成对存在，不是替代**：asset 缺失（新加的供应商还没出图）
    ///    或没打进 bundle 时，由 `AIVendorIcon.image` 退回 SF Symbols。
    ///    ⛔ 别只删 `symbolName` —— 那样一缺图就是一片空白。
    /// `.custom` 没有品牌资产 ⇒ nil。
    public var iconAssetName: String? {
        switch self {
        case .deepSeek: return "ProviderDeepSeek"
        case .zhipu:    return "ProviderZhipu"
        case .kimi:     return "ProviderKimi"
        case .doubao:   return "ProviderDoubao"
        case .minimax:  return "ProviderMiniMax"
        case .custom:   return nil
        }
    }

    /// 这张品牌图**是不是自带颜色**（当前只有 Kimi）。
    ///
    /// 🔴 2026-10-20 用户定案：Kimi 的标是**官方 app-icon 形态** —— 黑底圆角方块 + 白 K +
    ///    右上角蓝点（`#1683FF`）。它不能走单色 template：方块区域 alpha 恒为 1，
    ///    template 会把它涂成一个**实心色块**，K 和蓝点一起消失，且**不报错、不崩溃** ——
    ///    界面上只表现为「一个纯色圆角方块」，极难联想到这里少了这个开关。
    /// ⚠️ 其余四家仍是单笔触单色矢量记号（template 跟随文字色，深浅色自动反转）——
    ///    它们**不能**跟着变成原色：那样浅色模式下就是一块块黑图。
    public var iconKeepsBrandColor: Bool {
        switch self {
        case .kimi: return true
        case .deepSeek, .zhipu, .doubao, .minimax, .custom: return false
        }
    }

    /// 下拉 / 列表行左侧的小图标 —— **SF Symbols 兜底**。
    ///
    /// 2026-10-13 版本只有这一路（不引入外部品牌资源）；2026-10-20 接入品牌图标后
    /// 它降级为兜底（见 `iconAssetName`）。⚠️ 保留它是刻意的：缺 asset 时不留白。
    public var symbolName: String {
        switch self {
        case .deepSeek: return "sparkles"
        case .zhipu:    return "brain.head.profile"
        case .kimi:     return "moon.stars"
        // 火山引擎 ⇒ 火焰（「火山」的字形联想，SF Symbols 里最贴近的一个）
        case .doubao:   return "flame"
        // MiniMax ⇒ 字母 M（SF Symbols 的 m.circle，最直接的品牌联想）
        case .minimax:  return "m.circle"
        case .custom:   return "square.grid.2x2"
        }
    }

    /// 副标题 / 悬停提示上那行小字（讲清「打到哪儿去」）。
    public var subtitle: String {
        switch self {
        case .deepSeek: return L("api.deepseek.com")
        case .zhipu:    return L("open.bigmodel.cn")
        case .kimi:     return L("api.moonshot.cn")
        case .doubao:   return L("ark.cn-beijing.volces.com")
        case .minimax:  return L("api.minimax.chat")
        case .custom:   return L("自填服务地址")
        }
    }

    /// 「查看文档 ↗」打开的官方文档页。
    /// ⚠️ 取不到时返回 nil（那一行链接就不渲染）—— 而不是给个可能过期的硬编码字符串。
    ///    自定义服务没有「官方文档」，自然没有这一行。
    public var documentationURL: URL? {
        switch self {
        case .deepSeek: return URL(string: "https://api-docs.deepseek.com/")
        case .zhipu:    return URL(string: "https://open.bigmodel.cn/dev/api")
        case .kimi:     return URL(string: "https://platform.moonshot.cn/docs")
        case .doubao:   return URL(string: "https://www.volcengine.com/docs/82379/1298454")
        // MiniMax 开放平台（控制台 + 文档入口都在这一个站上）
        case .minimax:  return URL(string: "https://platform.minimax.chat/")
        case .custom:   return nil
        }
    }

    /// 选中这家时预填的**对话端点**（要写到完整路径，不做自动拼接）。
    ///
    /// ⚠️ DeepSeek 带 `/beta` 是**必须的**，不是笔误：它的「对话前缀续写」只在 beta 端点可用，
    ///   而「继续生成」正靠它才能接着半句往下写（否则服务端会把半截回复当成一段说完了的发言，
    ///   重新生成一条 —— 表现就是「续写内容从头重复一遍」）。beta 端点 = 正式端点 + Beta 功能，
    ///   普通对话请求的行为不变（`supportsPrefixCompletion` 也认地址里的 `/beta`）。
    ///
    /// ⚠️ `.custom` 刻意给**空串**：地址是这一家唯一必须用户自己填的东西。
    ///    给个 `https://` 之类的占位反而更糟 —— 它语法合法但打不通，
    ///    用户会以为「默认值能用」。（表单里那一栏空着 + 有 placeholder，一眼看出要填。）
    public var defaultBaseURL: String {
        switch self {
        case .deepSeek: return "https://api.deepseek.com/beta/chat/completions"
        case .zhipu:    return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
        case .kimi:     return "https://api.moonshot.cn/v1/chat/completions"
        // 方舟 OpenAI 兼容入口（⛔ 不是 /api/plan/v3 —— 那是 Agent Plan 专属，
        // 且它没有 /models 端点；普通对话模型走 /api/v3）
        case .doubao:   return "https://ark.cn-beijing.volces.com/api/v3/chat/completions"
        // 大陆 Key 的域名（Global Key 在 api.minimax.io，见 case 声明处注释 ①）
        case .minimax:  return "https://api.minimax.chat/v1/chat/completions"
        case .custom:   return ""
        }
    }

    /// 该家的**模型清单**端点（`GET`，Bearer 鉴权）。`.custom` 为 nil ——
    /// 它的端点由用户填的那个地址推导（见 `AIModelCatalog.modelsEndpoint(for:url:)`）。
    ///
    /// ☠️ 三家**不能从 `defaultBaseURL` 反推**（2026-10-13 踩到的坑）：
    ///    反推规则是「去掉末尾 `/chat/completions` 再接 `/models`」，对 DeepSeek 会得到
    ///    `https://api.deepseek.com/beta/models` —— 而它的清单在**非 beta** 的 `/models` 上，
    ///    那个 `/beta` 只是「前缀续写」这个 beta 功能的路径前缀，**不是**一条真实资源路径。
    ///    推错的症状很隐蔽：「测试连接」明明 Key 是对的却报 404，而下拉里只剩内置条目。
    public var modelsEndpointURL: URL? {
        switch self {
        case .deepSeek: return URL(string: "https://api.deepseek.com/models")
        case .zhipu:    return URL(string: "https://open.bigmodel.cn/api/paas/v4/models")
        case .kimi:     return URL(string: "https://api.moonshot.cn/v1/models")
        // 实测存在（无 Key 请求得 401 而非 404）⇒ 测试连接能直接拉到账号下有权限的模型
        case .doubao:   return URL(string: "https://ark.cn-beijing.volces.com/api/v3/models")
        // 官方文档明列 `GET /v1/models`（OpenAI 形状的 list）⇒「测试连接」能直接
        // 拉到账号下有权限的模型，与方舟同一套机制
        case .minimax:  return URL(string: "https://api.minimax.chat/v1/models")
        case .custom:   return nil
        }
    }

    /// 选中这家时预填的模型名。
    /// ⚠️ `.custom` 给空串（要用户自己填 —— 自建服务的模型名我们无从猜起）。
    public var defaultModel: String {
        switch self {
        // 2026-09 起官方模型名是 `deepseek-flash`；旧的 `deepseek-v4-flash` 仍可调用，
        // 但对应模型已下线，请求会由 V4.1-Flash 提供并按 Flash 计费。
        case .deepSeek: return "deepseek-flash"
        // 🔴 2026-10-17 更新：GLM-4 时代（glm-4-flash / glm-4-plus）已旧，
        //    当代旗舰是 GLM-4.7（200K 上下文）。免费线仍在 glm-*-flash。
        case .zhipu:    return "glm-4.7"
        // 🔴 2026-10-17 更新：K2.5 已被 K2.6 / K2.7 / K3 取代。官方快速开始
        //    明示「不确定时默认从 kimi-k3 开始」（1M 上下文 + 视觉）。
        case .kimi:     return "kimi-k3"
        // 用户 2026-10-16 选定的主力（官方模型广场原样抄的版本名）
        case .doubao:   return "doubao-seed-2-1-turbo-260628"
        // M3 = 当代旗舰（456B MoE · 1M 上下文 · 原生多模态 · 开源权重）
        case .minimax:  return "MiniMax-M3"
        case .custom:   return ""
        }
    }

    /// 该家**能收图**的模型名特征（**空数组 = 不拦，一律允许**）。
    ///
    /// ⚠️ 2026-10-14 起它**不再是运行时判据** —— 判据搬到了每条配置自己的
    ///    `AICustomModel.supportsImages`（让手改 JSON 能直接覆盖）。
    ///    它现在只在**表单保存时**用（`AICustomModel.inferFrom` 把「这家 + 这个模型名」
    ///    翻成那个布尔），以及报错文案里给「换成哪个」的建议。
    /// 🔴 两家**必须同源**：各处写一份字符串的后果是「报错让你换成 A，列表里只有 B」。
    public var visionModelMarkers: [String] {
        switch self {
        case .deepSeek: return ["vision"]        // deepseek-v4-flash-vision-exp
        // 🔴 2026-10-17 补 4.5v / 4.6v：当代视觉系叫 glm-4.5v / glm-4.6v，
        //    老判据 `-4v` 只覆盖 glm-4v / glm-4v-plus（GLM-4 时代）。
        case .zhipu:    return ["-4v", "vision", "4.5v", "4.6v"]
        // 🔴 2026-10-17 补 k2.5 / k2.6 / k2.7 / k3：K2.5 起全系支持视觉，
        //    但名字里没有 "vision"（老判据只覆盖 moonshot-v1-*-vision-preview）。
        //    ⚠️ 纯文本的 kimi-k2 / moonshot-v1-8k 不含这些串 ⇒ 仍正确不收图。
        case .kimi:     return ["vision", "k2.5", "k2.6", "k2.7", "k3"]
        // doubao-seed 全系（1.6 / 2.0 / 2.1）都是全模态；旧 doubao-pro-* 纯文本
        // 名字里没有 "seed" ⇒ 自动不收图（正确：发过去也是 400）
        case .doubao:   return ["seed"]
        // M3 全模态（图 / 影 / 音 / 文）；MiniMax-VL-01 是更早一代的视觉专精。
        // ⚠️ 刻意**不含** "m2.5"：M2.5 是纯文本（204K），标成能收图会让用户
        //    发图拿到一次 400 —— 而提前拦下本来只要一句话（见 `inferFrom`）。
        case .minimax:  return ["m3", "vl"]
        case .custom:   return []                // 自建服务无从判断 ⇒ 不拦
        }
    }

    /// 报错里建议「换成哪个模型」（`AIProviderError.modelWithoutVision` 读它）。
    /// ⚠️ `.custom` 给空串：我们不知道它家有什么视觉模型，报错文案会退化成一句泛泛的话。
    public var visionModelSuggestion: String {
        switch self {
        case .deepSeek: return "deepseek-v4-flash-vision-exp"
        // 🔴 2026-10-17：glm-4v-plus（GLM-4 时代）→ glm-4.6v（当代视觉）
        case .zhipu:    return "glm-4.6v"
        // 🔴 2026-10-17：moonshot-v1-*-vision-preview → kimi-k2.6（K2.5 起全系视觉）
        case .kimi:     return "kimi-k2.6"
        case .doubao:   return "doubao-seed-2-1-turbo-260628" // seed 全系可收图
        case .minimax:  return "MiniMax-M3"
        case .custom:   return ""
        }
    }

    /// 该家认不认「思考模式」那两个请求字段（`reasoning_effort` / `thinking`）。
    ///
    /// ⚠️ 只有 DeepSeek 认（它默认就开、必须显式关掉，见 `AIConfig.thinkingEnabled`）；
    ///    智谱 / Kimi / 自建服务收到这两个未知字段可能直接 400 —— 而**代价远大于「少一个开关」**：
    ///    多一个不认识的顶层字段会把本来能用的配置打挂。
    /// ⚠️ 豆包（2026-10-16 接入）**刻意不加入**：它的思考参数是另一种形状
    ///    （`thinking: {type: "disabled"|"enabled"|"auto"}`，嵌套对象而非顶层布尔/枚举），
    ///    照 DeepSeek 那套发过去大概率 400。要支持得单独走一层适配，⛔ 别图省事并进来。
    ///    MiniMax（2026-10-17 接入）的 `thinking` 与之**同形**，同理不加入。
    /// ⚠️ 仅用于表单预填（`AICustomModel.inferFrom`）—— 运行时读的是每条自己的
    ///    `supportsReasoning`。
    public var supportsThinkingParameter: Bool { self == .deepSeek }
}

// MARK: - 配置门面

public enum AIConfig {

    // MARK: - 变更广播

    /// 配置发生任何变更（清单 / 当前模型 / 思考模式）时发出。
    ///
    /// **为什么需要它**：配置会有若干处「UI 副本」（输入栏那颗胶囊、会话页的镜像状态、
    /// 设置页列表）。靠视图生命周期去同步是不可靠的 —— 模态呈现时下面的 VC 根本收不到
    /// `viewWillAppear`。与其让每个页面自己猜「什么时候该刷新」，不如由配置的唯一出口广播出去。
    ///
    /// ⚠️ `AIModelStore` 发的也是**这一条**（见那边的 `notifyChange`）：另起一个名字只会让
    ///    「只订了老名字的地方」静默不刷新，症状是「改完模型，输入栏上还是老名字」且不报错。
    public static let didChangeNotification = Notification.Name("ai_config_did_change")

    private static func notifyChange() {
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    /// 供 `AIModelCatalog` 用：**「服务端候选模型列表」变了**（拉取到新清单）也走同一条广播。
    /// ⚠️ 只在**主线程**调用（`AIModelCatalog.fetch` 的成功回调那一跳就是主线程）。
    public static func notifyModelListChanged() { notifyChange() }

    // MARK: - 清单（唯一配置源在 AIModelStore）

    /// 清单里全部条目（按文件里的原顺序 —— 用户手改 JSON 的顺序即界面顺序）
    public static var allModels: [AICustomModel] { AIModelStore.all() }

    /// 现在用的那一条。列表空时为 nil。
    public static var current: AICustomModel? { AIModelStore.current }

    /// 现在用哪一条（条目 id）。**这是全 App 唯一的「换模型」写入口**。
    public static var currentID: String? {
        get { AIModelStore.currentID }
        set { AIModelStore.currentID = newValue }
    }

    /// 清单是不是空的（空 = 还没配过任何模型 ⇒ 会话页要给出「去哪儿配」的引导）
    public static var hasModel: Bool { !allModels.isEmpty }

    /// 把「当前使用」钉住（清单非空而指针为空/悬空时写一次）。语义见 `AIModelStore.ensureCurrent`。
    @discardableResult
    public static func ensureCurrent() -> Bool { AIModelStore.ensureCurrent() }

    /// 强制重读 JSON（进页面 / 从后台回来时调 —— 用户可能在外面刚改过文件）。
    @discardableResult
    public static func reloadModels() -> Bool { AIModelStore.reload() }

    // MARK: - 当前条目的投影（发请求与显示都读这几条）

    /// 当前条目的模型标识（原样发给服务端那串）。没配时为**空串**。
    public static var currentModelID: String { current?.normalizedID ?? "" }

    /// 当前条目的对话端点。没配时为空串（`makeRequest` 会抛 `invalidBaseURL`）。
    public static var currentBaseURL: String { current?.normalizedURL ?? "" }

    /// 当前条目的 API Key（空串归一为 nil）
    public static var currentAPIKey: String? {
        let value = current?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    /// 当前条目的供应商预设（手改 JSON 写了个没见过的供应商名时为 nil）
    public static var currentVendor: AIProviderKind? { current?.vendorKind }

    /// 当前条目在界面上显示的名字
    public static var currentDisplayName: String { current?.displayName ?? "" }

    /// 当前条目的计价（缺省补 `defaultPricing`）
    public static var currentPricing: AIPricing { current?.pricingOrDefault ?? defaultPricing }

    /// 脱敏展示，如 `sk-abcd****wxyz`；未配置返回 nil，过短则整体打码
    public static func masked(_ key: String?) -> String? {
        let value = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        guard value.count > 12 else { return String(repeating: "*", count: value.count) }
        return "\(value.prefix(7))****\(value.suffix(4))"
    }

    // MARK: - 思考模式

    private static let thinkingKey = "ai_chat_thinking_enabled"

    /// 是否开启思考模式（认这个字段的模型才生效）。
    ///
    /// **默认关**：DeepSeek 的思考模式默认是开的（effort=high），开着的表现是
    /// 先连着输出十几秒 `reasoning_content`、正文一个字都没有，看起来像卡住。
    /// 当前 UI 没有「思考过程」展示位，所以先按关闭接入。
    ///
    /// ⚠️ 这是**全局开关**，与每条配置的 `supportsReasoning` 分工不同：
    ///    那个回答「这模型认不认这两个字段」，这个回答「这次发不发」。
    ///    两个都满足才发（见 `OpenAICompatibleProvider.body`）。
    public static var thinkingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: thinkingKey) }
        set {
            guard newValue != thinkingEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: thinkingKey)
            notifyChange()
        }
    }

    // MARK: - 计价默认值

    /// 默认单价（**可以改的默认值，不是真理**）—— 每条配置没写 `pricing` 时用它。
    ///
    /// 取值出处：DeepSeek 2026-09-10 12:00 生效的 **V4-Flash 空闲时段**价 ——
    /// 缓存命中 0.02 元 / 未命中 1 元 / 输出 4 元（每百万 token），高峰时段（工作日
    /// 9:00–12:00、14:00–18:00）是空闲价的 **2 倍**。
    ///
    /// 之所以在代码里放一份而不是留空：留空 = 开箱看不到任何金额，用户不知道该填什么。
    /// 但**它随时可能过期**（官方调价、换 V4-Pro、换成别的平台都会变），
    /// 而错误的价格比不显示价格更糟 —— 所以「添加模型」表单把它做成可编辑，并在旁边标明出处。
    public static let defaultPricing = AIPricing(cacheHitInput: 0.02,
                                                 cacheMissInput: 1,
                                                 output: 4)
}
