//
//  AIMemoryStore.swift
//  AICore
//
//  「长期记忆」的**唯一存取点**（2026-10-25 上线）—— 一份 JSON 数组文件
//  （`Documents/memories.json`），每项一条值得跨会话记住的信息。
//
//  ## 它回答三个问题
//  ① 记住过什么（`all()`）② 写入（`add` / `update` / `delete` / `clearAll`；
//     业务写入方只有 `AIMemoryExtractor` 一个，UI 侧**只删不建**）③ 本轮请求
//     拼不拼记忆块（`digest()`，注入点在 `AIChatManager.withSystemPrompt`）。
//
//  ## 🔴 三件必须记住的事
//  1. **自动抽取（inferred）是唯一写入方**（2026-10-25 决策反转：上线当天是
//     explicit-only——两个手动写点；当天即按「对齐豆包 / WorkBuddy」改成
//     每轮对话后由模型自动提取，**手动写点全部移除**）。信任缓解三条：
//     **逐条可审可删**（管理页）+ **开关可关**（`isAutoExtractEnabled` 默认关）
//     + **模型不许自动删**（op 只有 add / update / none，见 `AIMemoryExtractor`）。
//     记错的风险仍在——所以「待确认区」类设计哪天要做，从那个文件接，⛔ 别在这层加。
//  2. **数据落 Documents JSON，不落 SQLite**：记忆是**非关系型全量加载**数据
//     （发送时整份拼进 system 消息），没有按条件查询的需求 ⇒ `AIChatStore`
//     那套建表 + `schemaVersion` 迁移对它是纯负担。形态照 `AIModelStore`：
//     原子写 + mtime 缓存 + **用户能在「文件」App 里直接手改 / 备份**这份 JSON。
//  3. **注入块格式单点化**：`digest()` 是「记忆块长什么样」的唯一出处
//     （与 `AICodeBlockMetrics` 同一条纪律：格式散两处必不一致）。块文案是
//     **发给模型的内容** ⇒ 固定中文、不进 `L()` 词表（与「【项目资料】」
//     「【刚检索到的网页资料】」同口径，见 `AILocalization` 文件头「范围」）。
//
//  ## 读取策略（为什么不是每次读盘）
//  `digest()` **每轮发送都会走** ⇒ 内存缓存 + mtime 校验（照 `AIModelStore`）：
//  热路径上只多一次 `stat`，而「用户在外面手改文件」下次发送即生效。
//
//  ## ⚠️ 条数软上限在抽取器里，不在这一层（2026-10-25）
//  自动写入一轮能添好几条，无上限增长会推高每轮注入成本 ⇒ `AIMemoryExtractor`
//  在 50 条处收口（满了只许 update）。本层**不设限**：用户手删到多少是多少，
//  静默截断会让「记了却没生效」这种静默错出现，比多花点 token 更糟。
//

import Foundation

// MARK: - 一条记忆

/// 长期记忆的一条。
///
/// ⚠️ **三个字段就是全部**：`id`（本地唯一键，更新/删除按它）`content`（正文）
/// `createdAt`（列表排序 + 显示时间；`update` 会刷新它 ⇒ 改写过的浮动到最前）。
/// ⛔ 别急着加 `source` / `updatedAt` / `hitCount` —— 没有对应的 UI 消费方之前，
/// 加一个字段就是加一份维护面（JSON 手改兼容、迁移、两端显示口径）。
/// 2026-10-25 反转成自动抽取后**仍然不加 `source`**：写入方只剩抽取器一个，
/// 「手动 vs 自动」再无区分需求；真要区分那天，从管理页的消费方倒推。
public struct AIMemoryItem: Codable, Identifiable, Hashable, Equatable {

    public var id: UUID
    public var content: String
    public var createdAt: Date

    public init(id: UUID = UUID(), content: String, createdAt: Date = Date()) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
    }
}

// MARK: - 存取点

public enum AIMemoryStore {

    // MARK: 文件

    /// `Documents/memories.json`。
    ///
    /// ⚠️ 与 `AIModelStore.fileURL` 同一个目录、同一套理由（iOS 落 App 容器 /
    ///     Mac 落沙盒容器，都能在「文件」App / 访达里手改）。⛔ 别为了「记忆更私密」
    ///     挪进 `applicationSupportDirectory` —— 挪了用户就手改不了、也备份不走，
    ///     而这份文件本来就是用户自己的内容（不含 Key，比 `models.json` 还不敏感）。
    public static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return dir.appendingPathComponent("memories.json")
    }

    /// 给 UI 显示用的**短**路径 —— 恒为 `Documents/memories.json`
    /// （照 `AIModelStore.shortDisplayPath`：完整路径会把设置页那行说明撑成两三行）。
    public static var shortDisplayPath: String {
        fileURL.pathComponents.suffix(2).joined(separator: "/")
    }

    // MARK: 内存缓存

    private static var cache: [AIMemoryItem] = []
    /// 上次读盘时文件的修改时间。`nil` = 还没读过。
    private static var cacheStamp: Date?
    /// 上次读盘**失败**的原因（JSON 语法错误 / 根不是数组）。非 nil 时 UI 应提示
    /// 「文件坏了、显示的是内存里的旧值」——⛔ 别静默当成空列表（用户会以为记忆全丢了，
    /// 然后手动重加，覆盖掉他手写的文件）。口径与 `AIModelStore.lastLoadError` 一致。
    public private(set) static var lastLoadError: String?

    // MARK: 读

    /// 全部记忆（**新的在前** —— 列表、注入块都按这个顺序，用户最新记的最先被看到）。
    public static func all() -> [AIMemoryItem] {
        reloadIfChanged()
        return cache
    }

    /// 条数（设置页开关行右侧显示；走 `all()` 同一条缓存路，不会多读盘）。
    public static var count: Int { all().count }

    /// 强制重读（进设置页 / 从后台回来时调 —— 用户可能刚在「文件」App 里手改过）。
    /// - Returns: 内容是否真的变了（变了才值得刷新 UI）。
    @discardableResult
    public static func reload() -> Bool {
        let before = cache
        loadFromDisk()
        let changed = before != cache
        if changed { notifyChange() }
        return changed
    }

    private static func reloadIfChanged() {
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
                let decoded = try JSONDecoder().decode([AIMemoryItem].self, from: data)
                // 丢掉空正文的项（手写时留了空行）—— 留着只会让列表里出现一行
                // 点不动、删不掉的幽灵，注入块里也会多一个空编号
                cache = decoded
                    .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .sorted { $0.createdAt > $1.createdAt }
                lastLoadError = nil
            }
            cacheStamp = modificationDate()
        } catch {
            // ⚠️ **不清空缓存、不动文件**（照 `AIModelStore`）：用户手改坏了 JSON 时，
            //    界面上仍显示他上一次的内容并给出提示；若在这里清空再被某次保存
            //    写回去，他的手写内容就没了。
            lastLoadError = error.localizedDescription
        }
    }

    // MARK: 写

    /// 新增一条（**新的插到最前**，与 `all()` 的排序口径一致）。
    ///
    /// 业务上唯一的调用方是 `AIMemoryExtractor`（手动添加入口 2026-10-25 已移除，
    /// 与豆包对齐成纯自动）；`public` 留给验收探针（`MemoryTraceProbe`）与
    /// 未来的手动入口 —— ⛔ 别在 UI 层直接拿它当「添加记忆」按钮的落地。
    ///
    /// - Parameter content: 正文。首尾空白会被 trim；**纯空白返回 `nil`**
    ///   （⛔ 别存空串 —— 列表里会出一行删不掉的幽灵，注入块里多一个空编号）。
    /// - Returns: 真存下的那条（含落库的 `id` / `createdAt`）；纯空白时 `nil`。
    @discardableResult
    public static func add(content: String) -> AIMemoryItem? {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let item = AIMemoryItem(content: text)
        var items = all()
        items.insert(item, at: 0)
        replaceAll(items)
        return item
    }

    /// 改写一条（按 `id`）：换内容、`createdAt` 刷成现在 ⇒ 浮动到最前
    /// （与 `all()` 的排序口径一致——「新的在前」对改写后的条目同样成立）。
    ///
    /// 抽取器的 `update` op 走这里。⛔ 别在别处拼「读全量 → 改 → 全量写」——
    /// 那等于绕过 `replaceAll` 的原子写与广播。
    /// - Returns: 真改了什么才 `true`（找不到 id / 空白正文 / 内容没变都是
    ///   `false`：不写文件、不发广播）。
    @discardableResult
    public static func update(id: UUID, content: String) -> Bool {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var items = all()
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return false }
        guard items[idx].content != text else { return false }
        items[idx].content = text
        items[idx].createdAt = Date()
        replaceAll(items)
        return true
    }

    /// 删除一条（按 `id`；幂等——删不存在的 id 不动文件、不发广播）。
    public static func delete(id: UUID) {
        var items = all()
        let before = items.count
        items.removeAll { $0.id == id }
        guard items.count != before else { return }
        replaceAll(items)
    }

    /// 全部清空（设置页「清除全部记忆」；二次确认在 UI 层，⛔ 别在这里弹）。
    public static func clearAll() {
        guard !all().isEmpty else { return }
        replaceAll([])
    }

    /// 整份覆盖写 + 广播（原子写：写临时文件再 rename，⛔ 别用普通 `write` ——
    /// 中途崩了会留下半份 JSON，而这份文件正是记忆的唯一来源）。
    private static func replaceAll(_ items: [AIMemoryItem]) {
        cache = items.sorted { $0.createdAt > $1.createdAt }
        persist()
    }

    private static func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(cache)
            try data.write(to: fileURL, options: .atomic)
            cacheStamp = modificationDate()
            lastLoadError = nil
        } catch {
            lastLoadError = error.localizedDescription
        }
        notifyChange()
    }

    // MARK: 注入块（发送前拼进 system 消息）

    /// 本轮要拼进 system 消息的记忆块；**空串 = 不拼**（关 / 一条都没有）。
    ///
    /// 🔴 **格式单点**：注入块长什么样只有这一处说了算（`AIChatManager.withSystemPrompt`
    ///    只负责把它拼到指令之后）。消费方 ⛔ 别自己拼第二份。
    ///
    /// 块结构仿 `AIProjectRetriever.digest`：`【块头】` + 编号条目 + `【使用要求】`护栏。
    /// 固定中文不进词表（发给模型的内容，见 `AILocalization` 文件头）。
    ///
    /// 关时返回空 ⇒ 请求体与没这功能时**逐字节一致**（`withSystemPrompt` 的契约）。
    public static func digest() -> String {
        guard isEnabled else { return "" }
        let items = all()
        guard !items.isEmpty else { return "" }
        var lines: [String] = [
            "【长期记忆】",
            "以下是你在以往对话中被自动记住的信息，是跨会话的长期背景：",
        ]
        for (offset, item) in items.enumerated() {
            lines.append("\(offset + 1). \(item.content)")
        }
        lines.append("")
        lines.append("【使用要求】")
        lines.append("1. 与本轮指令冲突时，以本轮指令为准；不要主动向用户复述以上记忆，除非用户问及。")
        return lines.joined(separator: "\n")
    }

    // MARK: 开关

    /// 「回答时参考」总闸（**注入侧**）。默认 **开**。
    ///
    /// 默认开的理由：注入正是这个功能存在的目的 —— 默认关等于上线一个
    /// 用户永远发现不了的功能。空记忆时 `digest()` 返回空 ⇒ 请求体逐字节一致，
    /// 默认开零成本。
    ///
    /// ⚠️ 它只管**注入**，不管记不记：`isAutoExtractEnabled`（抽取侧）关着时，
    ///    已记住的内容照样在列表里增删（管理页照常工作），只是不拼进请求。
    ///    两个开关各管一件事——「让助手记着、但这轮别参考」是合法状态。
    ///    设置页开关行的说明文案按这个口径写（「关闭后助手不再参考这些记忆」）。
    ///
    /// 🔴 与 `AIGenerationSettings` 那几个开关**分开存**：那个 enum 管「怎么生成」
    ///    （指令/采样/搜索），这个管「记住什么」—— 混在一起的话
    ///    `resetToDefaults()` 会把用户的记忆也清了，而那不是「恢复默认」该干的事。
    public static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set {
            guard newValue != isEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            notifyChange()
        }
    }

    /// 「自动记忆」开关（**抽取侧**）。默认 **关**（2026-10-25 用户拍板）。
    ///
    /// 默认关的理由是**成本**：开着时每轮对话后都会多一次模型调用
    /// （token 是用户自己 Key 的真金白银）。开启路径：设置页 → 长期记忆 →
    /// 「自动记忆」。
    ///
    /// ⚠️ 与 `isEnabled`（注入）分开的两个开关，理由见那边的说明。
    ///    键名带命名空间前缀（`UserDefaults` 与系统及其它版本共用命名空间，
    ///    与 `AINotificationPreferences` / `AIGenerationSettings` 同款理由）；
    ///    两端键名故意相同：同一个偏好，各存在各自容器里。
    public static var isAutoExtractEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoExtractKey) as? Bool ?? false }
        set {
            guard newValue != isAutoExtractEnabled else { return }
            UserDefaults.standard.set(newValue, forKey: autoExtractKey)
            notifyChange()
        }
    }

    /// ⚠️ 带命名空间前缀（`UserDefaults` 与系统及其它版本共用命名空间，
    ///    与 `AINotificationPreferences` / `AIGenerationSettings` 同款理由）。
    ///    两端键名故意相同：同一个偏好，各存在各自容器里。
    private static let enabledKey = "Aster.memory.enabled"

    private static let autoExtractKey = "Aster.memory.autoExtract"

    // MARK: 变更广播

    /// 记忆变了（增 / 删 / 清 / 手动改文件被重读出来）时发一条。
    ///
    /// 🔴 **不复用** `AIConfig.didChangeNotification`（`AIModelStore` 复用它是因为
    ///    观察者本来就是模型相关的）：那条的通知会让输入栏胶囊、会话页标题白刷新，
    ///    与记忆无关。另起一个名字，观察者按需订。
    public static let didChangeNotification = Notification.Name("AIMemoryStore.didChange")

    private static func notifyChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
