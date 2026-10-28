//
//  FolderTreePane.swift
//  AsterMac
//
//  右侧面板的**第三种内容**：一个**文件夹**的目录树（2026-10-07 加）。
//
//  用户口径（原话）：「打开文件夹的功能 可以做成图中这样目录树显示吗？
//  文件夹内如果有代码文件点击 增加标签并显示代码？」——
//  所以这里只负责**树**；点文件**新开一个标签**（`WebPageModel.openLocal(...)`），
//  代码那条渲染通道在 `CodePane.swift`。
//
//  ## 🔴 树从**根的孩子**那一层开始画
//  根目录自己不出现在行列表里 —— 它是导航条上的标题（截图里正是这样：
//  内容区的左上角写着「备份工程」，右边的树直接列它的孩子）。
//
//  ## 🔴 懒加载：展开哪一层才去列哪一层
//  `FolderNode.children == nil` 表示**还没列过**。展开时才 `contentsOfDirectory`。
//  ⇒ `node_modules` 那种目录只要不点开就一个文件都不读。
//
//  ## ⚠️ 四个必须守的坑
//  ① ☠️ **软链接一律跳过**：目录软链成环会让递归搜索永远转不完；
//  ② ☠️ **包（`.app` / `.xcodeproj`）当文件**，不进去（与 Finder 同口径）；
//  ③ ☠️ **图标不许在 `body` 里同步取**（`NSWorkspace.icon(forFile:)` 是同步 IO）
//     —— 与本工程 `RowMediaImage` 那条铁律同族；这里干脆用 SF Symbol 按类型给，
//     既不用碰磁盘，也天然跟着深浅色走；
//  ④ ☠️ **读盘与扫描一律 `nonisolated async`**（跑全局执行器）。本 target 是
//     `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不写 `nonisolated` 的话
//     这些函数默认主 actor 隔离 —— `await` 它们等于**在主线程上读盘**。
//
//  ## ⚠️ 为什么用 `ObservableObject` 而不是 `@Observable`
//  与 `WebPageModel` 同一条理由（见 `WebPageView.swift` 文件头）：本工程的验收台
//  **完全不能展开宏**，每加一个 `@Observable` 都要去脚本里手工补一致性代码。⛔ 别改。
//

import SwiftUI
import AppKit
import Combine
import Foundation
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

// MARK: - 值类型

/// 目录树里的一个条目。
///
/// 🔴 刻意用**值类型**：整棵树由 `FolderTreeModel` 一份 `@Published` 持有，
///    节点的变化走「按 url 递归找到它、改完写回」——避免 N 个嵌套 `ObservableObject`
///    各自发通知（那种写法在 SwiftUI 里最容易出现「行不刷新」）。
struct FolderNode: Identifiable, Equatable {

    let url: URL
    let name: String
    let isDirectory: Bool
    /// 展开中（只对目录有意义）。
    var isExpanded = false
    /// `nil` = 这一层**还没列过**（懒加载）。
    var children: [FolderNode]?
    /// 列这一层失败了（权限 / IO）。失败后 `children` 写成 `[]`，不无限重试。
    var loadFailed = false

    var id: URL { url }
}

/// 「列一层目录」的结果。
/// ⚠️ 必须 `Sendable`：它在**全局执行器**上造出来、再跨回主 actor。
struct FolderEntry: Sendable, Equatable {
    let url: URL
    let name: String
    let isDirectory: Bool
}

/// 「列一层目录失败」的唯一形态。
///
/// ☠️ 为什么不能写成 `Result<[FolderEntry], String>`：`Result.Failure` **必须**符合 `Error`，
///    而 `String` 不符合 —— 那是编译错误（`type 'String' does not conform to protocol 'Error'`）。
/// ⚠️ 存在的唯一目的是把 `localizedDescription` 带出去给「读不出来」那行小字用；
///    调用方（`loadChildren`）只用「成功 / 失败」这一个判据。
struct FolderReadError: Error, Sendable {
    let message: String
}

/// 树里的一行 = 一个节点 + 它该缩进几层。
struct FolderRow: Identifiable, Equatable {
    let node: FolderNode
    let depth: Int
    var id: URL { node.url }
}

/// 搜索命中的一项（**扁平**列表，不带层级 —— 见 `FolderTreeModel.scan` 的口径）。
struct FolderSearchHit: Identifiable, Equatable {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// 相对根目录的**所在目录**（给用户看「这是哪儿」）。根的孩子这一层是空串。
    let relativePath: String
    var id: URL { url }
}

// MARK: - 模型

/// 一棵目录树的状态（懒加载 + 搜索 + 展开）。
final class FolderTreeModel: ObservableObject {

    /// 树根（用户选中的那个文件夹）。
    let root: URL
    /// 给用户看的根名字。⚠️ 别用 `url.lastPathComponent` 现算：根目录（`/`）会退化成 "/"。
    let displayName: String

    /// 整棵树。**根节点不出现在行列表里**（它是导航条上的标题）。
    @Published private(set) var tree: FolderNode

    /// 搜索框内容。空串 = 显示树。
    /// ⚠️ `didSet` 里排搜索（不是每敲一个字同步扫盘）——见 `scheduleSearch`。
    @Published var filter = "" {
        didSet {
            guard filter != oldValue else { return }
            scheduleSearch()
        }
    }
    @Published private(set) var searchHits: [FolderSearchHit] = []
    @Published private(set) var isSearching = false

    private var searchTask: Task<Void, Never>?
    private var didStart = false

    // MARK: 构造

    /// 正常路径：只记下根，**什么都不读**（第一次列目录由 `startIfNeeded()` 触发）。
    init(root: URL, displayName: String? = nil) {
        self.root = root
        self.displayName = (displayName?.isEmpty == false) ? displayName! : root.lastPathComponent
        self.tree = FolderNode(url: root, name: self.displayName, isDirectory: true)
    }

    /// 🔴 **验收入口**：直接塞一棵**已经加载好的**树，不碰磁盘、不起异步。
    ///
    /// 为什么必须有它：离屏渲染里**跑不了异步副作用**（`.task` / `Task {}` 都不会跑，
    /// 见 `VERIFY-PROBES` 那条「离屏渲染照不到任何异步结果」）⇒ 不给这么一个同步入口，
    /// 渲染台那几张档位图**永远是空的**（会被误读成「树没画出来」）。
    /// ⚠️ 只在渲染台与探针里用；生产路径永远走 `init(root:)` + `startIfNeeded()`。
    ///
    /// - Parameters:
    ///   - keyword: 非空 ⇒ 直接进**搜索态**（画的是 `searchHits` 那份扁平列表）；
    ///   - hits: 搜索态要显示的结果（`keyword` 为空时忽略）。
    ///     ⚠️ 搜索态**也必须从外面塞**：真搜索走 `scheduleSearch()` 的 `Task`，离屏不跑
    ///     ⇒ 不给参数的话「有结果的搜索结果页」这一档永远造不出来。
    static func seeded(_ node: FolderNode,
                       keyword: String = "",
                       hits: [FolderSearchHit] = []) -> FolderTreeModel {
        let model = FolderTreeModel(root: node.url, displayName: node.name)
        model.tree = node
        model.didStart = true
        if !keyword.isEmpty {
            // ⚠️ 顺序不能反：`filter` 的 `didSet` 会把 `isSearching` 置 true 并起一个 Task，
            //    所以先写 `filter`、再把 `isSearching` 压回 false。
            model.filter = keyword
            model.searchHits = hits
            model.isSearching = false
        }
        return model
    }

    // MARK: 展平（给视图用）

    /// 现在该画哪些行（只有**已展开**的分支）。
    var rows: [FolderRow] {
        var out: [FolderRow] = []
        Self.flatten(tree.children ?? [], depth: 0, into: &out)
        return out
    }

    private static func flatten(_ nodes: [FolderNode], depth: Int, into out: inout [FolderRow]) {
        for node in nodes {
            out.append(FolderRow(node: node, depth: depth))
            if node.isExpanded, let kids = node.children {
                flatten(kids, depth: depth + 1, into: &out)
            }
        }
    }

    /// 正在搜索（此时画面换成**扁平的结果列表**）。
    var isSearchMode: Bool { !filter.isEmpty }
    /// 根目录都没列成功。
    var rootFailed: Bool { tree.loadFailed }

    // MARK: 启动 / 展开

    /// 第一次列根目录（视图 `.onAppear` 调）。
    /// 根节点一开始就展开 —— 树从它的**孩子**那一层开始画。
    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        tree.isExpanded = true
        Task { await loadChildren(of: root) }
    }

    /// 点一行目录 = 展开 / 收起。⚠️ 文件行的落点是**开标签**，在视图层分派。
    func toggle(_ node: FolderNode) {
        guard node.isDirectory else { return }
        let expanding = !node.isExpanded
        mutate(node.url) { $0.isExpanded = expanding }
        // ⚠️ 用传进来的 `node.children`（调用那一刻的快照）判断要不要加载就够：
        //    没加载过 = nil ⇒ 去列一层；列过的再展开不重复读盘。
        if expanding, node.children == nil {
            Task { await loadChildren(of: node.url) }
        }
    }

    /// 列某一层（成功写进树；失败标记 `loadFailed` 并把 `children` 写成空数组，不再重试）。
    @discardableResult
    func loadChildren(of url: URL) async -> Bool {
        let result = await Self.listChildren(of: url)
        switch result {
        case .success(let entries):
            let kids = entries.map { FolderNode(url: $0.url, name: $0.name, isDirectory: $0.isDirectory) }
            mutate(url) { $0.children = kids; $0.loadFailed = false }
            return true
        case .failure:
            mutate(url) { $0.children = []; $0.loadFailed = true }
            return false
        }
    }

    /// 把某个目录在树里**露出来**（搜索结果里点一个目录时用）：清掉搜索、逐层展开到它。
    /// ☠️ 必须**从根往下逐层**走：父节点没加载时子节点在树里根本不存在，按 url 改是空操作。
    func reveal(_ url: URL) {
        filter = ""
        Task {
            var cursor = root
            let rest = url.pathComponents.dropFirst(root.pathComponents.count)
            for component in rest {
                cursor.appendPathComponent(component)
                await ensureLoaded(cursor)
                if cursor == url {
                    mutate(cursor) { if $0.isDirectory { $0.isExpanded = true } }
                } else {
                    mutate(cursor) { $0.isExpanded = true }
                }
            }
        }
    }

    @discardableResult
    private func ensureLoaded(_ url: URL) async -> Bool {
        if let node = Self.find(in: tree, url: url), node.children != nil { return true }
        return await loadChildren(of: url)
    }

    // MARK: 搜索

    /// 搜索是**有上限的后台递归扫描**，不是「过滤已展开的层」。
    ///
    /// ☠️ 为什么不能只过滤已加载层：刚打开时除根以外一层都没加载 ⇒ 用户搜 `NSString`
    ///    会得到空列表，而文件其实就在下面两层 —— 那种「搜不到」比没有搜索框更糟。
    /// ☠️ 上限（深度 + 条数）是硬要求：`node_modules` / `~/` 那种目录不设上限会读几万个文件。
    /// ⚠️ 每次敲字都重排一次扫描，旧的那个 `cancel` 掉（结果过期就丢）。
    private func scheduleSearch() {
        searchTask?.cancel()
        let keyword = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            searchHits = []
            isSearching = false
            searchTask = nil
            return
        }
        isSearching = true
        let rootURL = root
        searchTask = Task {
            let hits = await Self.scan(root: rootURL,
                                       keyword: keyword,
                                       maxDepth: MacTheme.treeSearchMaxDepth,
                                       limit: MacTheme.treeSearchMaxResults)
            guard !Task.isCancelled else { return }
            searchHits = hits
            isSearching = false
        }
    }

    // MARK: 读盘（全部 nonisolated —— 见文件头 ④）

    /// 列一层目录。返回**排好序**的条目（目录在前，然后按名字本地化排序）。
    nonisolated static func listChildren(of url: URL) async -> Result<[FolderEntry], FolderReadError> {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .nameKey, .isPackageKey]
        do {
            let items = try FileManager.default.contentsOfDirectory(at: url,
                                                                   includingPropertiesForKeys: Array(keys),
                                                                   options: [])
            var out: [FolderEntry] = []
            for item in items {
                // ☠️ ① 软链接一律跳过（成环会让递归搜索转不完；也避免同一份内容出现两次）。
                let values = try? item.resourceValues(forKeys: keys)
                if values?.isSymbolicLink == true { continue }
                // 只滤掉 `.DS_Store`（Finder 的目录缓存，纯噪声）。
                // ⚠️ 其余**以点开头的文件照常显示** —— `.gitignore` / `.env` 正是代码工程里
                //    最该看得见的那几个（截图里那个列表也是全显示的）。
                if item.lastPathComponent == ".DS_Store" { continue }
                let isPackage = values?.isPackage == true
                out.append(FolderEntry(url: item,
                                       name: values?.name ?? item.lastPathComponent,
                                       // ☠️ ② 包当文件（与 Finder 同口径）：`.app` 报的是
                                       //    `isDirectory = true`，进去就是一堆看不懂的内部结构。
                                       isDirectory: (values?.isDirectory == true) && !isPackage))
            }
            return .success(out.sorted(by: Self.sortEntries))
        } catch {
            return .failure(FolderReadError(message: error.localizedDescription))
        }
    }

    nonisolated static func sortEntries(_ a: FolderEntry, _ b: FolderEntry) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// 有上限的**广度优先**递归扫描（给搜索框用）。
    nonisolated static func scan(root: URL,
                                 keyword: String,
                                 maxDepth: Int,
                                 limit: Int) async -> [FolderSearchHit] {
        let needle = keyword.lowercased()
        var hits: [FolderSearchHit] = []
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var head = 0
        while head < queue.count, hits.count < limit {
            if Task.isCancelled { break }
            let (dir, depth) = queue[head]
            head += 1
            guard depth < maxDepth else { continue }
            guard case .success(let entries) = await listChildren(of: dir) else { continue }
            for entry in entries {
                if entry.name.lowercased().contains(needle) {
                    hits.append(FolderSearchHit(url: entry.url,
                                                name: entry.name,
                                                isDirectory: entry.isDirectory,
                                                relativePath: relativeDirectory(of: entry.url, from: root)))
                    if hits.count >= limit { break }
                }
                if entry.isDirectory { queue.append((entry.url, depth + 1)) }
            }
        }
        return hits
    }

    /// 相对根目录的**所在目录**（不含文件名本身）。根的孩子这一层返回空串。
    nonisolated static func relativeDirectory(of url: URL, from root: URL) -> String {
        let base = root.path
        let full = url.path
        guard full.hasPrefix(base) else { return "" }
        var rel = String(full.dropFirst(base.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        let dir = (rel as NSString).deletingLastPathComponent
        return dir
    }

    // MARK: 树内查找 / 改写（按 url）

    private func mutate(_ url: URL, _ transform: (inout FolderNode) -> Void) {
        Self.mutate(&tree, url: url, transform)
    }

    private static func mutate(_ node: inout FolderNode,
                               url: URL,
                               _ transform: (inout FolderNode) -> Void) {
        if node.url == url { transform(&node); return }
        guard var kids = node.children else { return }
        for i in kids.indices {
            mutate(&kids[i], url: url, transform)
        }
        node.children = kids
    }

    private static func find(in node: FolderNode, url: URL) -> FolderNode? {
        if node.url == url { return node }
        guard let kids = node.children else { return nil }
        for kid in kids {
            if let hit = find(in: kid, url: url) { return hit }
        }
        return nil
    }
}

// MARK: - 视图

/// 面板里的目录树（第三档内容）。**纯 SwiftUI**（离屏渲染照得到 —— 见文件头）。
struct FolderTreePane: View {

    @ObservedObject var model: FolderTreeModel

    /// 点一个**文件** ⇒ 面板**新开一个标签**显示它。
    /// 🔴 用户口径：「文件夹内如果有代码文件点击 **增加标签**并显示代码」
    ///    ⇒ 不是在树这个标签里换内容，而是**多一个标签**。
    let onOpenFile: (URL) -> Void

    @Environment(\.colorScheme) private var scheme

    /// 指针正划过哪一行（`nil` = 没划过）。
    /// ⚠️ 与起始页同一口径（`MAC-UI-RULES` 铁律 3）：**只换底色、不参与布局**；
    ///    且「离开」只在**当前记的就是我**时才清 —— 从 A 行挪到 B 行时，
    ///    A 的离开事件与 B 的进入事件谁先到**不确定**，无条件清会把 B 刚点亮的高亮抹掉。
    @State private var hovered: URL?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Rectangle()
                .fill(MacTheme.webPageToolbarBorder)
                .frame(height: 1)
            content
        }
        .background(MacTheme.pageBackground)
        .onAppear { model.startIfNeeded() }
    }

    // MARK: 搜索框

    /// ⚠️ 它是个 `TextField` ⇒ 离屏渲染里只有「黄条 + ⊘」（已知表现，不是缺陷）。
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(MacTheme.ui(MacTheme.treeIconSize))
                .foregroundStyle(MacTheme.webPageToolbarIconDisabled)
            TextField(L("搜索"), text: $model.filter)
                .textFieldStyle(.plain)
                .font(MacTheme.ui(MacTheme.treeSearchFontSize))
                .foregroundStyle(MacTheme.bodyColor)
            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
        }
        .padding(.horizontal, MacTheme.treeSearchPaddingH)
        .frame(height: MacTheme.treeSearchBarHeight)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.treeSearchBarRadius)
                .fill(MacTheme.webPageAddressBackground(scheme))
                .padding(.horizontal, MacTheme.treePaddingH)
                .padding(.vertical, MacTheme.treeSearchBarInset)
        )
        .padding(.vertical, MacTheme.treeSearchBarInset)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if model.isSearchMode {
            searchList
        } else {
            treeList
        }
    }

    private var treeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    treeRow(row)
                }
                if model.rows.isEmpty {
                    hint(model.rootFailed ? L("打不开这个文件夹") : L("这个文件夹是空的"))
                }
            }
            .padding(.vertical, MacTheme.treeListPaddingV)
        }
    }

    private var searchList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.searchHits) { hit in
                    searchRow(hit)
                }
                if model.searchHits.isEmpty, !model.isSearching {
                    hint(L("没有匹配项"))
                }
            }
            .padding(.vertical, MacTheme.treeListPaddingV)
        }
    }

    /// 树里的一行。点目录 = 展开 / 收起；点文件 = **开新标签**。
    private func treeRow(_ row: FolderRow) -> some View {
        let node = row.node
        return Button {
            if node.isDirectory { model.toggle(node) } else { onOpenFile(node.url) }
        } label: {
            HStack(spacing: MacTheme.treeIconSpacing) {
                // 🔴 chevron **恒占位**（文件行也占那一格，只是不可见）⇒ 同一层的文字左缘严格对齐。
                Image(systemName: "chevron.right")
                    .font(MacTheme.ui(9, weight: .semibold))
                    .foregroundStyle(MacTheme.webPageToolbarIconDisabled)
                    .rotationEffect(.degrees(node.isExpanded ? 90 : 0))
                    .frame(width: MacTheme.treeChevronWidth)
                    .opacity(node.isDirectory ? 1 : 0)

                Image(systemName: Self.symbol(for: node))
                    .font(MacTheme.ui(MacTheme.treeIconSize))
                    .foregroundStyle(node.isDirectory ? MacTheme.webPageToolbarIcon : MacTheme.meta)
                    .frame(width: MacTheme.treeIconWidth)

                Text(node.name)
                    .font(MacTheme.ui(MacTheme.treeFontSize))
                    .foregroundStyle(MacTheme.bodyColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if node.loadFailed {
                    Image(systemName: "exclamationmark.triangle")
                        .font(MacTheme.ui(MacTheme.treeIconSize))
                        .foregroundStyle(MacTheme.errorText)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, MacTheme.treePaddingH + CGFloat(row.depth) * MacTheme.treeIndentPerLevel)
            .padding(.trailing, MacTheme.treePaddingH)
            .frame(height: MacTheme.treeRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(PanelRowChrome(scheme: scheme, hovered: hovered == node.url))
        .onHover { setHover(node.url, $0) }
        .help(node.url.path)
    }

    /// 搜索结果的一行：名字 + 一行淡的「它在哪个目录」（否则同名文件分不出是哪一个）。
    private func searchRow(_ hit: FolderSearchHit) -> some View {
        Button {
            if hit.isDirectory { model.reveal(hit.url) } else { onOpenFile(hit.url) }
        } label: {
            HStack(spacing: MacTheme.treeIconSpacing) {
                Image(systemName: hit.isDirectory ? "folder" : Self.symbol(for: hit.url))
                    .font(MacTheme.ui(MacTheme.treeIconSize))
                    .foregroundStyle(hit.isDirectory ? MacTheme.webPageToolbarIcon : MacTheme.meta)
                    .frame(width: MacTheme.treeIconWidth)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.name)
                        .font(MacTheme.ui(MacTheme.treeFontSize))
                        .foregroundStyle(MacTheme.bodyColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(hit.relativePath.isEmpty ? L("根目录") : hit.relativePath)
                        .font(MacTheme.ui(MacTheme.treeSearchFontSize - 1))
                        .foregroundStyle(MacTheme.meta)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MacTheme.treePaddingH)
            .frame(height: MacTheme.treeSearchRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(PanelRowChrome(scheme: scheme, hovered: hovered == hit.url))
        .onHover { setHover(hit.url, $0) }
        .help(hit.url.path)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(MacTheme.ui(MacTheme.treeFontSize))
            .foregroundStyle(MacTheme.meta)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
    }

    /// 指针进出一行的记账（见 `hovered` 那段注释）。
    private func setHover(_ url: URL, _ inside: Bool) {
        if inside {
            hovered = url
        } else if hovered == url {
            hovered = nil
        }
    }

    // MARK: 图标

    /// ☠️ **不碰磁盘**：按类型给 SF Symbol（`NSWorkspace.icon(forFile:)` 是同步 IO，
    ///    在 `body` 里逐行取会卡 —— 与本工程 `RowMediaImage` 那条铁律同族）。
    private static func symbol(for node: FolderNode) -> String {
        node.isDirectory ? "folder" : symbol(for: node.url)
    }

    private static func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "h", "m", "mm", "c", "cc", "cpp", "hpp", "hxx", "cxx": return "curlybraces"
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "json", "json5": return "curlybraces"
        case "sh", "bash", "zsh", "fish", "command": return "terminal"
        case "yml", "yaml", "toml", "ini", "conf", "cfg", "env", "properties": return "gearshape"
        case "css", "scss", "less": return "paintbrush"
        case "html", "htm", "xml", "plist", "svg", "xib", "storyboard": return "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp": return "photo"
        case "mp4", "mov", "m4v", "avi", "mkv": return "film"
        case "mp3", "wav", "m4a", "aac", "flac": return "waveform"
        case "zip", "gz", "tar", "7z", "rar", "xz", "bz2": return "doc.zipper"
        case "pdf": return "doc.richtext"
        case "md", "markdown", "txt", "log", "rtf": return "doc.text"
        case "xlsx", "xls", "csv", "numbers": return "tablecells"
        case "docx", "doc", "pages": return "doc.richtext"
        case "pptx", "ppt", "key": return "rectangle.on.rectangle"
        default: return "doc"
        }
    }
}

// MARK: - 行外观

/// 目录树**一行**的外观（hover 底）。
///
/// ⚠️ 刻意**不复用**起始页那支 `StartPageRowChrome`：两者形状不同 ——
///    起始页的行是「描边常驻的胶囊」（还有一圈纵向内衬撑出行高），
///    树的行是「固定行高的清单行、只在 hover 时浮起来」。硬合成一个必须加一堆开关参数，
///    而且起始页那支的观感是逐张图调出来的（⛔ 别去动它）。
/// 🔴 但**底色的来源仍然只有一处**：`MacTheme.quickEntryHoverBackground`
///    —— 工程口径是「能点的行反馈必须一致」。
struct PanelRowChrome: ViewModifier {

    let scheme: ColorScheme
    let hovered: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: MacTheme.treeRowRadius, style: .continuous)
                    .fill(hovered ? MacTheme.quickEntryHoverBackground(scheme) : Color.clear)
                    .padding(.horizontal, MacTheme.treeChromeInset)
            )
    }
}
