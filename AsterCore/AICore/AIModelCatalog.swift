//
//  AIModelCatalog.swift
//  AICore
//
//  **两件事**（改造前混在一个「跨平台可选列表」里，JSON 化之后必须分开）：
//
//  | 谁 | 问什么 | 数据来源 |
//  | --- | --- | --- |
//  | 「添加模型」表单里那颗「模型名称」下拉 | **这家的服务端有哪些模型可选** | `GET /models` + 本工程内置的几条 |
//  | 会话页那颗胶囊（换模型） | **我刚配了哪几条** | `Documents/models.json`（`AIModelStore`） |
//
//  🔴 **两者不是一回事**，2026-10-14 之前它们被 `available(for:)` 与
//  `availableAcrossPlatforms()` 合成了一条链（内置 → 缓存 → 补当前值）——那套的前提是
//  「可选模型 = 代码里认识的那些」，而 JSON 化之后「可选」= **用户自己加的那几条**。
//  硬把两者焊在一起会得到「胶囊里列出一堆我没配过的服务端模型，点了却没 Key」。
//
//  ## 候选列表的三条原则（沿用改造前，有效）
//  - **拉不到不阻断**：任何失败都只是「没有服务端候选」，表单保留手填 —— 不能因为服务端
//    不提供 `/models`（或网络不通）就让用户改不了模型；
//  - **结果按「供应商 + 端点」缓存**（UserDefaults）：进表单先显示上次的列表，再后台刷新；
//  - **不引第三方**：一次普通 GET，用 `URLSession` 就够。
//

import Foundation
import AIPlatform

// MARK: - 错误

public enum AIModelListError: LocalizedError {
    /// 推导不出 `/models`（地址非法 / 非 http(s) / 无 host / 自定义服务没填地址）
    case unsupportedEndpoint
    /// 服务端回了 401 且**请求里根本没带 Key**（草稿空 + 已存的也空）。
    /// 🔴 必须和 `.http(401)` 分开：空 Key 报「无效」会把用户引去查 Key 对不对，
    ///    而真相是输入框里什么都没有（2026-10-16 真实踩到：模拟器粘贴坏了 ⇒
    ///    用户没贴上进空 Key 就测 ⇒ 报「API Key 无效」⇒ 用户拿同一把 Key 去
    ///    WorkBuddy 验证是通过的，白困惑两轮）。
    case missingKey
    case http(Int)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedEndpoint:
            return L("当前地址推导不出模型列表接口")
        case .missingKey:
            return L("API Key 是空的，先把 Key 填上再测")
        case .http(let code):
            switch code {
            case 401: return L("API Key 无效（HTTP 401）")
            case 403: return L("没有查看模型列表的权限（HTTP 403）")
            case 404: return L("该服务没有 /models 接口（HTTP 404）")
            case 500...599: return "服务端异常（HTTP \(code)）"
            default: return "获取模型列表失败（HTTP \(code)）"
            }
        case .badResponse:
            return L("模型列表返回格式无法识别")
        }
    }
}

// MARK: - 目录

public enum AIModelCatalog {

    // MARK: ① 候选（表单用）

    /// 某家的 `/models` 端点。
    ///
    /// - 五家官方：**显式声明**（`AIProviderKind.modelsEndpointURL`）。
    ///   ☠️ 不能从聊天端点反推（2026-10-13 踩到的坑）：DeepSeek 的聊天端点在 `/beta` 下，
    ///   而清单在非 beta 的 `/models` 上 ⇒ 推出来 `…/beta/models` 是 404
    ///   （症状：「测试连接」Key 明明对却报 404，下拉里只剩内置条目）。
    /// - 自定义服务：只能**从用户填的地址推**（我们不知道它长什么样）——
    ///   去掉末尾的 `/chat/completions` 再接 `/models`；不匹配那个形状时**原样接 `/models`**。
    ///   推错了也不致命：那条路只影响「候选下拉」，用户永远能手填模型名。
    public static func modelsEndpoint(for kind: AIProviderKind, url: String? = nil) -> URL? {
        if let fixed = kind.modelsEndpointURL { return fixed }
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              var comps = URLComponents(string: raw),
              let host = comps.host, !host.isEmpty else { return nil }
        var path = comps.path
        let suffix = "/chat/completions"
        if path.hasSuffix(suffix) { path = String(path.dropLast(suffix.count)) }
        comps.path = path + "/models"
        comps.query = nil
        return comps.url
    }

    /// 服务端清单之外、**由本工程内置**的候选条目。
    ///
    /// 为什么需要它 —— `/models` 只是「服务端此刻愿意对外列的清单」，它有两处覆盖不到的缺口：
    /// ① **实验模型**（`-exp` 后缀）常常不列进去，但用完整名字调用是通的；
    /// ② 拉取失败 / 该服务没有 `/models` 时清单整个是空的。
    /// 两种情况落到用户身上是同一句话：「我明知道有这么个模型，列表里就是找不到」，只能去手打名字。
    /// ⚠️ 它现在**只是候选**（不再代表「已配置」）—— 选中它会新建/更新一条配置。
    public struct AIModelEntry {
        /// 模型标识（原样发给服务端的字符串）
        public let id: String
        /// 列表里那一行的补充说明（右侧灰字）。`nil` = 不显示。
        public let note: String?

        public init(id: String, note: String? = nil) {
            self.id = id
            self.note = note
        }
    }

    /// 某家的内置候选。**只列「确定可用、且值得出现在列表里」的**——
    /// 猜错的代价是用户点一下换来一次 400/404，比「列表短一点」糟糕得多。
    ///
    /// ⚠️ 列表**第一项必须是 `defaultModel`**（下拉默认选中它）—— 所以写
    ///    `AIProviderKind.x.defaultModel` 而不是再抄一遍字符串。
    /// ⚠️ `.custom` 返回空：那家连模型名我们都无从猜起，它的候选**全部**来自服务端。
    public static func builtin(for kind: AIProviderKind) -> [AIModelEntry] {
        switch kind {
        case .deepSeek:
            return [
                AIModelEntry(id: AIProviderKind.deepSeek.defaultModel, note: L("默认 · 纯文本")),
                AIModelEntry(id: AIProviderKind.deepSeek.visionModelSuggestion, note: L("支持图片（实验）")),
            ]
        case .zhipu:
            // 🔴 2026-10-17 整代更新：GLM-4 时代（glm-4-plus / glm-4v-plus）→
            //    GLM-4.5/4.6/4.7 时代。glm-4.7 = 当代旗舰（200K）；glm-4.7-flash 免费；
            //    glm-4.6v = 当代视觉。glm-4.5 留作「上一代」备选。
            return [
                AIModelEntry(id: AIProviderKind.zhipu.defaultModel, note: L("默认 · 旗舰")),
                AIModelEntry(id: "glm-4.7-flash", note: L("免费")),
                AIModelEntry(id: "glm-4.5", note: L("上一代")),
                AIModelEntry(id: "glm-4.6v", note: L("支持图片")),
            ]
        case .kimi:
            // 🔴 2026-10-17 整代更新：kimi-k2.5 → K3 / K2.6 / K2.7。kimi-k3 = 当代
            //    旗舰（1M 上下文 + 视觉）；k2.7-code 面向代码；moonshot-v1-128k 是
            //    仍在售的旧系长文本（便宜），保留作备选。
            return [
                AIModelEntry(id: AIProviderKind.kimi.defaultModel, note: L("默认")),
                AIModelEntry(id: "kimi-k2.6", note: L("上一代")),
                AIModelEntry(id: "kimi-k2.7-code", note: L("代码专精")),
                AIModelEntry(id: "moonshot-v1-128k", note: L("长文本 128K")),
            ]
        // 豆包（火山方舟）。⚠️ 版本名都带日期后缀（官方模型广场原样抄）——
        // 服务端 /models 拉到账号有权限的清单后会**追加**在这些后面（见 `candidates`）
        case .doubao:
            return [
                AIModelEntry(id: AIProviderKind.doubao.defaultModel, note: L("默认 · 均衡主力")),
                AIModelEntry(id: "doubao-seed-2-0-lite", note: L("全模态理解")),
                AIModelEntry(id: "doubao-seed-2-0-mini", note: L("低时延低成本")),
            ]
        // MiniMax（2026-10-17 接入）。⚠️ 模型 ID 是 **CamelCase**（官方文档与
        // `/models` 返回的都是这个形状）—— ⛔ 别写成小写。
        // M3 = 当代旗舰（456B MoE · 1M 上下文 · 原生多模态）；M2.5 = 上一代（204K · 纯文本）。
        // 服务端清单拉到后同样会追加在后面。
        case .minimax:
            return [
                AIModelEntry(id: AIProviderKind.minimax.defaultModel, note: L("默认 · 旗舰")),
                AIModelEntry(id: "MiniMax-M2.5", note: L("上一代")),
            ]
        case .custom:
            return []
        }
    }

    /// 「现在有哪些候选模型」= **内置 → 上次拉到的缓存**。
    ///
    /// - Parameter url: 自定义服务填的那个地址（五家官方传 nil / 传了也不看）。
    public static func candidates(for kind: AIProviderKind, url: String? = nil) -> [AIModelEntry] {
        var entries = builtin(for: kind)
        var seen = Set(entries.map(\.id))
        for id in cachedCandidates(for: kind, url: url) where seen.insert(id).inserted {
            entries.append(AIModelEntry(id: id, note: nil))
        }
        return entries
    }

    // MARK: ② 已配置的条目（会话选择器用）

    /// 会话页那颗胶囊里的一项 = **一条已配置的模型**。
    ///
    /// 🔴 键（`id`）就是 `AICustomModel.id` —— 它同时是「发给服务端的模型标识」，
    /// 所以**列表项的 tag 与当前选中的判据天然同源**（两者都是这个 id），
    /// 不会出现改造前那种「用文案当 selection 永远匹配不上」的坑。
    ///
    /// ⚠️ 也**不再需要**「平台 + 模型」那种复合键：一条配置就是一条，
    ///    两个不同平台用了同名模型 = 两条配置、两个不同的 id。
    public struct AIModelChoice: Identifiable, Hashable {
        /// 条目 id（= 模型标识）
        public let id: String
        /// 列表里那一行的主标题（= 条目显示名）
        public let title: String
        /// 副标题（= 供应商名）
        public let note: String
        /// 左侧小图标（供应商预设给的，认不出时是个中性符号）
        public let symbolName: String
        /// 品牌图标的 asset 名（认不出预设时为 nil ⇒ 界面退回 `symbolName`）。
        /// ⚠️ 两者**并存**：asset 取不到时不留白，见 `iconImage(pointSize:)`。
        public let iconAssetName: String?
        /// 这张品牌图**自带颜色**吗（只有 Kimi 是，见 `AIProviderKind.iconKeepsBrandColor`）。
        /// 携带它是因为 `iconImage` 得决定「原色」还是「template」—— 拿错就会把
        /// 黑底方块涂成一块实心色（K 与蓝点消失，且不报错）。
        public let iconKeepsBrandColor: Bool
        /// 这一条**是不是配全了**（地址、模型名、Key 都有）。
        /// ⚠️ 给界面标一句「还没填 Key」用 —— 缺 Key 的配置点了也发不出去，
        ///    而用户此刻在列表里完全看不出来。
        public let isReady: Bool

        public init(id: String,
                    title: String,
                    note: String,
                    symbolName: String,
                    iconAssetName: String? = nil,
                    iconKeepsBrandColor: Bool = false,
                    isReady: Bool) {
            self.id = id
            self.title = title
            self.note = note
            self.symbolName = symbolName
            self.iconAssetName = iconAssetName
            self.iconKeepsBrandColor = iconKeepsBrandColor
            self.isReady = isReady
        }

        /// 直接可用的图标（asset 优先，SF Symbols 兜底）。
        public func iconImage(pointSize: CGFloat) -> AIPlatformImage? {
            AIVendorIcon.image(asset: iconAssetName,
                               symbol: symbolName,
                               pointSize: pointSize,
                               rendering: iconKeepsBrandColor ? .brandColor : .tinted)
        }
    }

    /// 全部已配置的条目（**按 JSON 里的原顺序** —— 用户手改文件即可调整界面顺序）。
    ///
    /// 🔴 刻意**不把当前项排到最前**（改造前按平台分组时是那样）：现在那份顺序是用户的文件里
    ///    写着的，偷偷重排会让他「明明把 X 提到第一行了，界面里还是老样子」。
    ///    识别当前项靠打勾，不靠位置。
    public static func choices() -> [AIModelChoice] {
        AIModelStore.all().map { entry in
            AIModelChoice(id: entry.id,
                          title: entry.displayName,
                          note: entry.vendorDisplayName,
                          symbolName: entry.symbolName,
                          iconAssetName: entry.iconAssetName,
                          iconKeepsBrandColor: entry.vendorKind?.iconKeepsBrandColor ?? false,
                          isReady: isReady(entry))
        }
    }

    /// **会话选择器**（`AIModelPickerViewController`）的列表 = 「配齐了、点了真能发出去」的那几条。
    ///
    /// 🔴 **2026-10-14 用户要求**：「iOS 端 AIModelPickerViewController 内，如果没有在设置页面
    ///    模型内配置，这里不显示」。判据落成 `isReady`（地址 / 模型名 / Key **三项都有**）——
    ///    因为在本工程里「在 models.json 里有这一条」**不等于**「能用」：
    ///    · 表单（`AIAddModelViewController`）的保存门槛只有「模型名非空」，**Key 允许留空**
    ///      （用户想先建条目、稍后再补 Key，这是刻意的）；
    ///    · 迁移（`AIModelStore.seedIfNeeded`）的门槛是「有模型名 **或** 有 Key」——
    ///      老版本在下拉里选过模型名、从没填 Key 的那些会原样迁进来。
    ///    ⇒ 只按「在不在清单里」过滤是**不够的**：清单里本来就躺着一批点不动的条目
    ///      （在会话选择器里的副标题是「… · 还没配齐」），点它只会换来一次 401。
    ///
    /// ⚠️ **清单页（设置 →「自定义模型」）仍然列全部**（含没配齐的）—— 那一页是**配置**的地方，
    ///    用户正需要看见「我这条还缺 Key」才能去补。两页的差别是**刻意**的：
    ///    清单页答「我有哪些」，这里答「这会儿能拿哪一个去发」。
    ///    ⇒ 所以这里是**新加一个口径**，而不是把 `choices()` 本身改窄。
    ///
    /// ⚠️ Mac 侧那颗模型菜单（`ChatModel.modelChoices` / `MacInputBar.modelMenu`）也读这个函数
    ///    （两端同口径：只列「配齐了、点了真能发出去」的那几条）。
    public static func readyChoices() -> [AIModelChoice] {
        // ⚠️ 必须保持 keyPath 简写这个形状 —— `typecheck_aster.sh` 契约 ⑥b
        //    逐字匹配它（`choices().filter(\.isReady)`），改成闭包写法会判「判据分叉」。
        choices().filter(\.isReady)
    }

    /// 这一条能不能直接发消息（三项都非空）。
    public static func isReady(_ entry: AICustomModel) -> Bool {
        !entry.normalizedID.isEmpty
            && !entry.normalizedURL.isEmpty
            && !entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// **输入栏那颗模型胶囊上该显示什么**（两平台**同一口径**）。
    ///
    /// 规则：显示当前条目的名字；一条配置都没有时给一句「未配置模型」。
    ///
    /// 🔴 那颗胶囊**同时是换模型的唯一入口**（「添加模型」列表页只管清单、不管「用哪个」）。
    ///    一旦它因为「没名字」而不显示，用户就**再也切不回去**了 —— 所以**永远不返回空串**。
    ///
    /// ⚠️ 与 `AIModelChoice.id` 一样是**单点口径**：mac（`ChatModel.currentModelLabel`）
    ///    与 iOS（`AIModuleViewController.refreshModelState`）都调它，⛔ 别各写一遍。
    public static func composerLabel() -> String {
        guard let entry = AIConfig.current else { return L("未配置模型") }
        return entry.displayName
    }

    // MARK: 候选缓存（UserDefaults，按「供应商 + 端点」分开）

    /// 一个字典装下所有缓存：`["<kind>|<models 端点>": ["model-a", "model-b"]]`。
    ///
    /// ⚠️ 改造前是「按平台两个键（清单 + 当时用的地址）」，那套的前提是**一家只有一个地址**；
    ///    自定义服务可以有好几条配置、各指不同端点 ⇒ 必须把端点并进键里，
    ///    否则「A 中转站的模型列表」会出现在「B 中转站」的下拉里。
    private static let cacheKey = "ai_chat_model_candidates"

    private static func cacheSlot(_ kind: AIProviderKind, url: String?) -> String? {
        guard let endpoint = modelsEndpoint(for: kind, url: url) else { return nil }
        return "\(kind.rawValue)|\(endpoint.absoluteString)"
    }

    /// 上次成功拉到的候选；端点对不上或从没拉过时返回空
    public static func cachedCandidates(for kind: AIProviderKind, url: String? = nil) -> [String] {
        guard let slot = cacheSlot(kind, url: url) else { return [] }
        let all = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: [String]]
        return all?[slot] ?? []
    }

    /// 写入缓存
    public static func storeCandidates(_ models: [String], for kind: AIProviderKind, url: String? = nil) {
        guard let slot = cacheSlot(kind, url: url) else { return }
        var all = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: [String]] ?? [:]
        all[slot] = models
        UserDefaults.standard.set(all, forKey: cacheKey)
    }

    // MARK: 拉取

    /// 拉取某家的模型候选（GET，Bearer 鉴权）。**回调恒定在主线程**。
    ///
    /// 它同时是「添加模型」表单上那颗**「测试连接」**的落点 ——
    /// 判据不是「发一条最小对话」（那要花 token），而是这一次 GET：
    /// 地址对不对、Key 对不对、能拿到哪些模型，一次全验完。
    ///
    /// - Parameters:
    ///   - url: 自定义服务填的地址（五家官方传 nil）
    ///   - apiKey: **显式指定用哪把 Key**。传 `nil` = 用当前条目的（`AIConfig.currentAPIKey`）。
    ///     🔴 为什么必须留这个口子：表单上「测试连接」时用户刚敲进去的 Key **还没落盘**
    ///     （表单是「保存」才写），拿存着的那把去测等于**测了个旧配置** ——
    ///     表现就是「Key 填错了却提示连接成功」。
    ///
    /// ⚠️ 不带 `Authorization` 也不提前拦：真需要鉴权而没填 Key 时由服务端给 401，
    ///    文案已翻成人话（空 Key ⇒ `AIModelListError.missingKey`，填错了 ⇒ `.http(401)`，
    ///    两者分开说）。别加「没 Key 就不发请求」那道闸 ——
    ///    它会把这个「测试连接」按钮变成「先保存再测试」。
    public static func fetch(for kind: AIProviderKind,
                             url: String? = nil,
                             apiKey explicitKey: String? = nil,
                             completion: @escaping (Result<[String], Error>) -> Void) {
        guard let endpoint = modelsEndpoint(for: kind, url: url) else {
            completion(.failure(AIModelListError.unsupportedEndpoint))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let key = explicitKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? AIConfig.currentAPIKey
        // 🔴 记下来「到底带没带 Key」：401 时要能说清是「没填」还是「填错了」
        //    （文案分开，见 `AIModelListError.missingKey`）。
        let didSendKey: Bool
        if let key, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            didSendKey = true
        } else {
            didSendKey = false
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<[String], Error>
            if let error = error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // 401 + 没带 Key ⇒「空的」，不是「无效的」（请求照发，只是文案说准）
                if http.statusCode == 401, !didSendKey {
                    result = .failure(AIModelListError.missingKey)
                } else {
                    result = .failure(AIModelListError.http(http.statusCode))
                }
            } else if let models = parse(data), !models.isEmpty {
                storeCandidates(models, for: kind, url: url)
                result = .success(models)
            } else {
                result = .failure(AIModelListError.badResponse)
            }
            DispatchQueue.main.async {
                // 候选变了 → 借配置变更那条广播发出去，让正开着这家的表单跟着刷新。
                // ⚠️ 必须在这一跳（主线程）里发：上面的 `store` 是在 URLSession 的回调线程
                //    上跑的，从那儿广播会把所有观察者（含 UIKit 页面）在非主线程叫醒。
                if case .success = result { AIConfig.notifyModelListChanged() }
                completion(result)
            }
        }.resume()
    }

    /// 解析 `{"object":"list","data":[{"id":"…"},…]}`。
    ///
    /// ⚠️ 用 `JSONSerialization` 而不是 `Codable` 结构体：各家的 `data` 元素形状不一
    /// （有的还带 `created` / `owned_by` / `permission`），只要 `id` 是字符串就够，
    /// 多的字段一律无视 —— 手写 Decodable 结构体反而会因为某个字段类型不同整个解不出来。
    /// 同时容忍 `{"data":["a","b"]}` 这种直接给字符串数组的非标准实现。
    private static func parse(_ data: Data?) -> [String]? {
        guard let data = data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let entries = json["data"] as? [[String: Any]] {
            return dedupe(entries.compactMap { $0["id"] as? String })
        }
        if let entries = json["data"] as? [String] {
            return dedupe(entries)
        }
        // 少数网关把模型挂在顶层数组上
        if let entries = json["models"] as? [[String: Any]] {
            return dedupe(entries.compactMap { $0["id"] as? String ?? $0["name"] as? String })
        }
        return nil
    }

    /// 去重 + 去空白，**保留服务端给的原顺序**（有些服务把推荐模型排在前面，重排会打乱意图）
    private static func dedupe(_ models: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in models {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }
}
