//
//  ConversationSidebar.swift
//  AsterMac
//
//  左栏：**固定入口 + 会话列表 + 底部设置栏**三段（2026-09-22 用户要求分成两部分）。
//
//  ```
//  ┌─[▤] [⌕] [网页◉]──┐  ← 窗口工具栏：系统「侧栏开合」+ 搜索 + 网页开关（全在 `RootView` 里挂上来）
//  │ 新对话           │ ← 固定（`SidebarQuickEntries`，不随列表滚）
//  │ 文档             │ ← 2026-10-10 取代「AI创作」（主区域整页换成 `DocumentsView`）
//  ├──────────────────┤
//  │ 我的对话          │ ← 分组标题（固定）
//  │  ▸ 最新的一条     │ ← 可滚动（`List(.sidebar)`）
//  │  ▸ …             │
//  ├──────────────────┤
//  │             ⚙︎ │ ← 固定（`SidebarSettingsBar`；2026-10-27 删掉头像+姓名，只剩齿轮）
//  └──────────────────┘
//  ```
//
//  ## 🔴 搜索按钮**不在这三段里**（2026-09-22 试过又撤了）
//  曾经把搜索做成侧栏第一格的一个「长得像输入框的按钮」（`SidebarSearchEntry.swift`，
//  已移出工程 —— 不是删，挪到 `/tmp/aster_removed/` 留着）。用户否掉了：
//  「和隐藏菜单栏按钮**平齐**」—— 指的是要跟系统那颗侧栏开合按钮同处**窗口工具栏**，
//  而且要紧贴着它，不是侧栏内部的顶上、也不是工具栏里离它 120pt 的地方。
//  ⚠️ 最终落点靠两件事同时成立：`.toolbar` 挂在本侧栏这一列上（**不是** `NavigationSplitView` 自身）
//  ＋ `placement: .secondaryAction`（**不是** `.navigation`）。
//  两个都是量出来的坐标，记在 `RootView` 那段注释里，别再改回去。
//  🔴 2026-09-30 晚：会话页导航上那颗「网页」开关也搬到了**同一格**
//  （`RootView` 侧栏列 `.toolbar` 里的第二个 `ToolbarItem`，排在放大镜**右边**）——
//  同一条落点规则、同一个代价（侧栏收起时一起消失）。
//
//  ## 三段之间刻意**不画分隔线**（只有底部设置栏顶上那条是例外）
//  macOS 的侧栏（备忘录 / 邮件）靠留白分组，加线反而碎。这条理由和
//  `MacTheme.sidebarSectionPaddingTop` 那条是同一个口径。
//
//  ## 数据源为什么是 `summaries` 而不是 `conversation`
//  `AIConversationSummary` 是「列表项」的专用模型：只有标题/时间/条数/置顶，
//  **不带消息内容**（历史会话是按需载入的，见 `AIChatStore.loadConversation`）。
//  用它渲染左栏，等于天然不会把十几段历史全读进内存。
//
//  ## 会话行的「更多」入口（2026-09-26 改）
//  原本**只**挂右键菜单，用户反馈「右键触发更多菜单不灵敏」。现在：
//  - 鼠标滑到某一行上时，行尾出现一颗「…」（`ConversationRow.moreButton`）；
//  - 点它 / 右键，弹的是**同一份**菜单项（`ConversationRow.menuItems`）：
//    **置顶 / 重命名… / 分享… / — / 删除**（顺序是用户指定的）；
//  - 「不灵敏」的真实成因是**命中形状**：默认只有「画了东西的地方」收得到指针/右键，
//    标题右侧那片 `Spacer` 空白两边都不响应 ⇒ 补 `.contentShape(Rectangle())`；
//  - 行**抽成了独立视图 `ConversationRow`**：`List` 在离屏渲染里只是黄条，不抽出来
//    「hover 才出现」「标题一个像素都不动」这两件事一张图都拿不到。
//
//  ## 「最新的在上面」是**业务层**的事，不在这里排
//  `AIChatStore.fetchSummaries()` 的 SQL 是 `updated_at DESC`，取回后再按置顶集合 +
//  项目 sortOrder 稳定重排 —— 即**置顶优先 → 项目分组（组间按 sortOrder，
//  默认项目「任务」sortOrder = -1 恒在最前）**。
//  视图层原样画，不排序。
//
//  ## 项目分组（2026-10-21，照豆包 / WorkBuddy 的形态）
//  分组**投影**在本文件做（`groups(summaries:projects:)`），共享层只返回排好序的扁平数组
//  —— 「共享层管顺序、视图管形态」与置顶只排序不分组同一哲学。
//  三条口径（⛔ 别改，改了两端行为和豆包/WorkBuddy 就不一样了）：
//  ① **置顶段没有分组头**：置顶是全局概念，不参与项目分组（归进某组会让"它属于哪"变浑）；
//  ② **空项目也画**（配「暂无对话」），否则「建了项目却看不见」像是没建成；
//  ③ **「未归类」已消灭**（2026-10-25）：非置顶会话必有项目，无归属行的容器是
//     默认项目「任务」⇒ 侧栏恒有至少一个分组头（默认组），不存在「零项目」态。
//     （默认态零扰动，这是本工程验收的硬要求）。
//  ⚠️ 分组头抽成独立视图 `ConversationGroupHeader`：`List` 在离屏渲染里只是黄条，
//     「图标 / 字号 / hover 才出『…』」这些事只有单独渲一张图才验得到（同 `ConversationRow`）。
//
//  ## `List(selection:)` 与 `model.selectedConversationId` 的关系
//  选中态是**受控**的：`List` 只负责把「点了哪一行」写回 `selectedConversationId`，
//  真正的切换由 `model.select(_:)` 落定（它会调 `manager.switchToConversation`）。
//  这里不能只改 `selectedConversationId` —— 那只换了高亮，右栏还是旧会话的内容。
//

import SwiftUI
import AppKit
import AICore

struct ConversationSidebar: View {
    @Environment(ChatModel.self) private var model

    // ☠️ 这里曾有一行 `@Environment(\.aiLanguageID) private var languageID`（2026-10-13 第三版删）。
    //    它读的是环境**默认值**（`RootView` 只把那个值灌给了 `detail:` 一侧）⇒ 侧栏永远不动，
    //    探针还因此报过一次假 PASS。⛔ 别再加回来。

    @State private var renameTarget: AIConversationSummary?
    @State private var renameText: String = ""
    @State private var deleteTarget: AIConversationSummary?

    // MARK: 项目（2026-10-21）

    /// 「新建项目」弹窗是否显示。用 Bool 而不是「名字非空」推断——
    /// 输入为空时那个推断会立刻把弹窗关掉（SwiftUI 的 TextField alert 需要稳定的是否状态）。
    @State private var newProjectShown = false
    /// 新建项目弹窗的输入内容
    @State private var newProjectName: String = ""
    /// 正在重命名的项目（`nil` = 没在改名）—— 与会话重命名**分开两套**：
    /// 合成一个「正在改某个名字」的状态会让弹窗内容和目标各自错配。
    @State private var projectRenameTarget: AIChatProject?
    @State private var projectRenameText: String = ""
    /// 正在确认删除的项目
    @State private var deleteProjectTarget: AIChatProject?
    /// 正在看资料的项目（非 nil ⇒ 弹「管理项目」sheet）—— 2026-10-21 L2
    @State private var projectDetailTarget: AIChatProject?

    /// 指针停在哪个分组头上（驱动分组头右侧那颗「…」的显隐）。
    /// 与 `hoveredId` 分开：会话行和分组头是两套 hover，混用一个 id 会让「划过标题行」
    /// 错误点亮某一个会话行的「…」。
    @State private var hoveredGroupId: String?

    /// 指针停在哪一行上（驱动行尾那颗「…」的显隐）。
    ///
    /// ⚠️ 放在**这一层**而不是 `ConversationRow` 内部当 `@State`：渲染台没有指针，
    ///    只有「由父视图传进去」的 hover 态才渲得出来（同 `ChatRowView.isHovered` 那条）。
    @State private var hoveredId: UUID?

    var body: some View {
        // ⚠️ 三段用 `VStack` 串起来，而**不是** `.safeAreaInset` 把某一端钉住：
        //    `List` 是 AppKit 桥接容器，渲染台看不见**它**，但看得见它的**兄弟节点** ——
        //    VStack 方案下「固定入口在上、设置栏在下」这两件事都真的画得出来，
        //    各有一张图能证明。`safeAreaInset` 的内容不保证画得出来。
        VStack(spacing: 0) {
            // ⛔ 这里**不要**放搜索入口（试过，被否）。它在窗口工具栏上，由 `RootView` 挂到
            //    本侧栏这一列 —— 见文件头「搜索按钮不在这三段里」。
            SidebarQuickEntries(
                onNewChat: { model.newConversation() },
                // 「文档」：把主区域整页换成 `DocumentsView`（2026-10-10 取代原「AI创作」）。
                // ⚠️ 它**不是**「开一段新对话」，别接到 `newConversation()` 那一家。
                onDocuments: { model.showDocuments() }
            )
            conversationArea
            // 🔴 2026-10-27 用户要求「把头像和名称都删除」——这一行原来还有
            //    「头像 + 姓名 + `>`」那块（点了弹账号菜单：设置… / GitHub / 退出登录）。
            //    删的理由与去处都写在 `SidebarSettingsBar` 文件头：
            //    本 App 没有账号体系，头像/姓名是「假装有个我」；设置这颗齿轮本来就在；
            //    GitHub 在「设置 → 关于」；「退出登录」本来就是占位。
            //    ⛔ 别把这三件套加回来（要加先回答「这个'我'是谁」）。
            SidebarSettingsBar()
        }
        // ☠️☠️ 2026-10-13 **第三版**：这里**不许**再挂 `.id(languageID)`（前两版挂过）。
        //    成因：本列的工具栏项（下面那颗放大镜，挂在 `RootView` 的侧栏列上）会因为在
        //    **本列的内容子树里出现身份变化**而被 AppKit 拆掉 hosting view、**且不再回填**
        //    —— 实测 `ToolbarItemHostingView` 从 `30x28` 缩成 `10x10`、`NSButton` 清零，
        //    而 `isVisible` / `visibleItems` 照样报 true（**极易假绿**）。
        //    ⇒ 文案重算改由 `L()` 自己的观察依赖负责（`AILocalization.swift` 文件头）。
        //    ⚠️ 挂在 `.alert` **之前**这条老规矩已经不需要了（连 `.id` 一起没了）。
        // 🔴 工具栏**撤空了**（2026-09-22）：那颗「新建对话（＋）」已经变成上面的「新对话」。
        //    同一个入口不摆两处 —— 两个都能新建只能让人犹豫点哪个。
        //    ⚠️ 这条只管**同层的重复按钮**（两个都能新建只能让人犹豫点哪个）；
        //    设置那颗齿轮在最下面，属**另一层**，不适用这条。
        //    ⚠️ 工具栏上现在是三颗：系统那颗侧栏开合 +「搜索」+「网页」开关
        //    （后两颗挂在 `RootView` 的侧栏列上，规则见该文件注释）。
        //    ⚠️ ⌘N / ⌘F 都不受影响：两者都挂在 App 菜单里（`AsterMacApp.commands`）
        //    —— 这一点很重要，**菜单不随侧栏开合消失**，而挂在工具栏/侧栏上的按钮会
        //    （「网页」开关 2026-09-30 从详情列搬到这里后，就多了这条特性：折叠侧栏即消失）。
        //    齿轮（设置）在侧栏最下面，见 `SidebarSettingsBar`。
        .alert(L("重命名会话"), isPresented: renamingPresented) {
            TextField(L("标题"), text: $renameText)
            Button(L("取消"), role: .cancel) { renameTarget = nil }
            Button(L("保存")) {
                if let target = renameTarget {
                    model.rename(target.id, to: renameText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                renameTarget = nil
            }
        }
        .alert(L("删除这个会话？"), isPresented: deletingPresented) {
            Button(L("取消"), role: .cancel) { deleteTarget = nil }
            Button(L("删除"), role: .destructive) {
                if let target = deleteTarget { model.delete(target.id) }
                deleteTarget = nil
            }
        } message: {
            if let target = deleteTarget {
                Text(String(format: L("「%@」的全部消息都会被删除，无法恢复。"), target.displayTitle))
            }
        }
        // MARK: 项目（2026-10-21）—— 三个弹窗与会话那两个同构，共用同一套 `.alert` 链
        .alert(L("新建对话项目"), isPresented: $newProjectShown) {
            TextField(L("项目名称"), text: $newProjectName)
            Button(L("取消"), role: .cancel) { newProjectName = "" }
            Button(L("创建")) {
                // 空名由 store 兜底拒绝（返回 nil）——这里不做 trim 判断，免得两处口径
                model.createProject(name: newProjectName)
                newProjectName = ""
            }
        }
        .alert(L("重命名项目"), isPresented: projectRenamingPresented) {
            TextField(L("项目名称"), text: $projectRenameText)
            Button(L("取消"), role: .cancel) { projectRenameTarget = nil }
            Button(L("保存")) {
                if let target = projectRenameTarget {
                    model.renameProject(target.id, to: projectRenameText)
                }
                projectRenameTarget = nil
            }
        }
        .alert(L("删除项目？"), isPresented: deletingProjectPresented) {
            Button(L("取消"), role: .cancel) { deleteProjectTarget = nil }
            Button(L("删除"), role: .destructive) {
                if let target = deleteProjectTarget { model.deleteProject(target.id) }
                deleteProjectTarget = nil
            }
        } message: {
            if let target = deleteProjectTarget {
                // 🔴 必须说清「会话不会丢」——否则用户不敢删项目（级联策略见 store）
                Text(String(format: L("「%@」里的会话不会被删除，只会移回「任务」；项目里的资料会一并删除。"),
                            target.name))
            }
        }
        // 管理项目（L2）：一张 sheet 看/加/删这个项目的资料。
        // ⚠️ `item:` 形式而不是 `isPresented` + 另一个「当前项目」状态：
        //    后者在切换项目时会让 sheet 内容闪一下旧值（两个状态分开更新的那一帧）。
        .sheet(item: $projectDetailTarget) { project in
            ProjectDetailView(project: project)
                // ⚠️ sheet 的内容**不会**自动继承父视图的 `@Environment(ChatModel.self)`？——
                //    实测会继承（SwiftUI 把环境带到 sheet），但这行显式再灌一次更稳：
                //    少了它，`@Environment(ChatModel.self)` 会在 sheet 里拿到默认值而**崩溃**，
                //    且崩在 sheet 呈现那一拍，看起来像「点管理项目就闪退」。
                .environment(model)
        }
    }

    // MARK: - 会话区（分组标题 + 可滚动列表）

    /// **固定**的分组标题 + 可滚动的会话列表。
    ///
    /// 标题刻意不用 `Section("我的对话")` 放进 `List` 里，两个理由：
    /// ① macOS 的 `.sidebar` 样式下 `Section` 带**折叠**行为（整组能收起来），
    ///    而这里要的是「一组」，不是「可以收起来的一组」；
    /// ② 标题做成 `List` 的**兄弟节点**之后，离屏渲染能真把它画出来（`List` 本身只会是黄条）
    ///    ——「标题在列表上方」这件事因此有一张图能证明。
    ///
    /// 代价：标题不随列表滚动（真实产品里两种都有，固定更常见于侧栏）。
    /// 若哪天要它跟着滚，换回 `Section` 即可，但要一并接受折叠行为。
    private var conversationArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(L("我的对话"))
                    .font(MacTheme.ui(MacTheme.sidebarSectionTitleFontSize, weight: .semibold))
                    .foregroundStyle(MacTheme.meta)
                Spacer(minLength: 0)
                // 「+ 新项目」（2026-10-21）：与「我的对话」同一行、贴右。
                // ⚠️ 恒显示（不挂 hover 才显）—— 分组头每组的「…」才是 hover 显隐；
                //    这颗是**整个列表级**的入口，藏起来用户找不到「怎么建项目」。
                //    ⛔ 也别做成 `Menu`（它只有一件事：新建 —> 直接弹输入框更快）。
                Button {
                    newProjectName = ""
                    newProjectShown = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(MacTheme.ui(11))
                        .foregroundStyle(MacTheme.meta)
                        // 🔴 尺寸必须与分组头那颗「…」**同一个常量**（2026-10-26）：
                        //    两颗按钮宽度不同的话，哪怕右缘对齐，图形中心也会差半个差值。
                        .frame(width: MacTheme.sidebarRowMoreButtonSize,
                               height: MacTheme.sidebarRowMoreButtonSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("新建项目"))
            }
            .padding(.leading, MacTheme.sidebarSectionPaddingH)
            // 🔴 右侧**不能**用 `sidebarSectionPaddingH`（12）（2026-10-26 改）：
            //    这颗钮要和下面 List 里的「…」落在同一条竖线上，而 List 内部的内容右缘
            //    由**系统内距**决定（普通行 16 / header 2，实测见 `MacTheme`）。取行的 16 后
            //    三颗按钮（本行 + 分组头 + 会话行）右缘全部 = 侧栏宽 − 16。
            .padding(.trailing, MacTheme.sidebarListRowTrailingInset)
            .padding(.top, MacTheme.sidebarSectionPaddingTop)
            .padding(.bottom, MacTheme.sidebarSectionPaddingBottom)
            conversationList
        }
    }

    // MARK: - 会话列表

    private var conversationList: some View {
        List(selection: selection) {
            ForEach(AIConversationGrouping.groups(summaries: model.summaries,
                                                  projects: model.projects)) { group in
                Section {
                    ForEach(group.items) { summary in
                        row(summary).tag(summary.id)
                    }
                    // 空项目也画出来（口径 ②）：不画的话「建了项目却在侧栏看不见」
                    // 看起来像没建成。占位行不参与选中（没有 .tag）。
                    // 2026-10-25 起所有组都是项目（「未归类」已消灭）⇒ 空组恒画占位。
                    if group.items.isEmpty {
                        Text(L("暂无对话"))
                            .font(MacTheme.ui(11))
                            .foregroundStyle(MacTheme.meta)
                            .padding(.leading, 20)
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    // `group.title == nil` ⇒ 只有置顶段（口径 ①）；2026-10-25 起
                    // 非置顶会话全在某个项目里，「未归类」段已消灭（口径 ③）
                    if let title = group.title {
                        ConversationGroupHeader(
                            title: title,
                            isProject: group.kind.isProject,
                            count: group.items.count,
                            isHovered: hoveredGroupId == group.id,
                            onHoverChange: { inside in
                                if inside { hoveredGroupId = group.id }
                                else if hoveredGroupId == group.id { hoveredGroupId = nil }
                            },
                            onRename: {
                                if let project = project(for: group) {
                                    projectRenameTarget = project
                                    projectRenameText = project.name
                                }
                            },
                            // 🔴 默认项目「任务」不可删（store 层双保险）：
                            //    它是无归属会话的唯一容器，删了系统就没有默认去处。
                            //    UI 层直接不给这颗钮（沉默失败比没有更糟）。
                            canDelete: project(for: group)?.id != AIChatStore.defaultProjectId,
                            onDelete: {
                                if let project = project(for: group) { deleteProjectTarget = project }
                            },
                            // 管理项目（2026-10-21）：弹一张 sheet 看/加/删**项目资料**。
                            // ⚠️ 与「重命名 / 删除」同一层，排在菜单第一项 —— 它是这一组里
                            //    唯一「进去看看」的动作，另两条是改属性/破坏性操作。
                            onManage: {
                                if let project = project(for: group) { projectDetailTarget = project }
                            }
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.summaries.isEmpty {
                Text(L("还没有会话"))
                    .font(MacTheme.ui(12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 分组 → 项目对象（只有项目段才有；置顶段返回 nil）
    private func project(for group: AIConversationGroup) -> AIChatProject? {
        guard case .project(let id) = group.kind else { return nil }
        return model.projects.first { $0.id == id }
    }

    // 分组投影本身在**共享层** `AIConversationGrouping`（两端同一份口径，见那个文件的注释）。
    // 这里只把它接进 `List` —— ⛔ 别在视图层另写一份分组逻辑（两端迟早漂）。

    // MARK: - 行

    /// 列表行：置顶/普通图标 + **只有标题** + 行尾（hover 才显）的「…」。
    ///
    /// 副标题（「N 条 · 相对时间」）已于 2026-09-21 按用户要求去掉：
    /// 列表里真正用来「找会话」的信息只有标题，条数与时间是在选中之后才有意义的东西，
    /// 摆在每一行上只是把行高撑成两倍、让可扫的一列变成两列。
    /// 少了一层 `VStack` 之后行高自然落回单行高度（`List` 自己量，不用写死）。
    /// ⚠️ **数据层没动**：`messageCount` / `updatedAt` 仍在 `AIConversationSummary` 上
    /// （iOS 左栏与排序都在用），Mac 这里只是不画。
    ///
    /// 2026-09-26 起，**行本体挪进了 `ConversationRow`**（本函数只负责接线）——
    /// 抽出去的理由见那个类型的文档注释（`List` 里验不了）。
    private func row(_ summary: AIConversationSummary) -> some View {
        ConversationRow(
            summary: summary,
            projects: model.projects,
            isHovered: hoveredId == summary.id,
            onHoverChange: { inside in
                // 只清**自己**那一行：快速划过列表时，A 行收到的 `false` 不该把
                // B 行刚刚点亮的按钮抹掉（同 `MacSearchView` 的写法）。
                if inside { hoveredId = summary.id }
                else if hoveredId == summary.id { hoveredId = nil }
            },
            onTogglePin: { model.setPinned(summary.id, !summary.isPinned) },
            onRename: {
                renameTarget = summary
                renameText = summary.title
            },
            // 归类（2026-10-21）：`nil` 由 manager/store 归一成默认项目「任务」
            onMoveToProject: { projectId in
                model.moveConversation(summary.id, toProject: projectId)
            },
            onShare: { share(summary) },
            onDelete: { deleteTarget = summary }
        )
    }

    // MARK: - 分享

    /// 分享一个会话：把整段对话导出成纯文本，交给系统分享面板（AirDrop / 信息 / 邮件 / 备忘录…）。
    ///
    /// 🔴 **为什么不用 `ShareLink`**（助手侧那条消息操作栏用的就是它）：
    /// `ShareLink` 的 item 必须在 **body 求值时**就算出来，而这里一算就是
    /// 「按会话 id 查一次库 + 拼全文」—— 挂在侧栏每一行上等于每帧若干次查询。
    /// AppKit 的 `NSSharingServicePicker` 是**点击时才干活**，而且「这个会话还没有内容」时
    /// 能给一句明确提示（`ShareLink` 只会给一颗点不亮的按钮）。
    private func share(_ summary: AIConversationSummary) {
        guard let text = model.transcript(of: summary.id), !text.isEmpty else {
            model.show(L("这个会话还没有可分享的内容"))
            return
        }
        let picker = NSSharingServicePicker(items: [text])
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        // 弹出位置取鼠标附近（≈ 用户刚点下的那一项）—— macOS 上最自然的位置。
        // ⚠️ `mouseLocationOutsideOfEventStream` 是**窗口坐标**（原点在左下角），
        //    必须 `convert(_:from: nil)` 转成 view 坐标，否则面板会弹到别处。
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        // 菜单项的回调里**立刻**弹面板会撞上「菜单还在收起」的时序 ⇒ 挪到下一拍再弹。
        DispatchQueue.main.async {
            picker.show(relativeTo: NSRect(origin: point, size: CGSize(width: 1, height: 1)),
                        of: view, preferredEdge: .minY)
        }
    }

    // MARK: - 绑定

    private var selection: Binding<UUID?> {
        Binding(
            get: { model.selectedConversationId },
            set: { newValue in
                // 取消选中（用户按住 ⌘ 点掉高亮）不做任何事：会话总得有一个是当前会话
                guard let id = newValue else { return }
                model.select(id)
            }
        )
    }

    private var renamingPresented: Binding<Bool> {
        Binding(get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } })
    }

    private var deletingPresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } })
    }

    private var projectRenamingPresented: Binding<Bool> {
        Binding(get: { projectRenameTarget != nil },
                set: { if !$0 { projectRenameTarget = nil } })
    }

    private var deletingProjectPresented: Binding<Bool> {
        Binding(get: { deleteProjectTarget != nil },
                set: { if !$0 { deleteProjectTarget = nil } })
    }
}

// MARK: - 分组头（抽成独立视图：包在 `List` 的 Section header 里渲染台验不了）

/// 侧栏的一根分组头：文件夹图标 + 项目名 + 会话数 + **hover 才显的「…」**
/// （重命名 / 删除项目）。
///
/// 🔴 与 `ConversationRow` 同一条纪律：**按钮恒占位、只改 `opacity`** + `.allowsHitTesting`
/// ——写成 `if isHovered { 按钮 }` 的话，hover 时标题可用宽度变化，`.middle` 截断位置会跳，
/// 指针上下移动时整列标题都在抖。
///
/// ⚠️ 2026-10-25 起「未归类」段已消灭：非置顶会话全在某个项目里 ⇒ `isProject`
/// 现在恒 true（默认项目「任务」也是项目段）。留着这个参数是防御
/// （万一未来又有无头段），不是给「未归类」招魂。
struct ConversationGroupHeader: View {
    let title: String
    /// 是不是真项目（决定图标与「…」菜单出不出）
    let isProject: Bool
    let count: Int
    /// 指针是否停在这根头上。**从外面传进来**（渲染台没有指针，同 `ConversationRow.isHovered`）
    let isHovered: Bool
    let onHoverChange: (Bool) -> Void
    let onRename: () -> Void
    /// 默认项目「任务」传 false：那颗组没有「删除」这一项
    /// （它是无归属会话的唯一容器；store 层 `deleteProject` 双保险）。
    var canDelete: Bool = true
    let onDelete: () -> Void
    /// 打开「管理项目」面板（看/加/删这个项目的**资料**）
    ///
    /// ⚠️ 参数带默认值是为了让 `ConversationGroupHeader` 的既有构造点（渲染台等）
    ///    一行不用改 —— 不传 = 行为与功能上线前一致（没有那颗「…」里的第一条）。
    var onManage: () -> Void = {}

    var body: some View {
        HStack(spacing: 4) {
            if isProject {
                Image(systemName: "folder")
                    .font(MacTheme.ui(10))
                    .foregroundStyle(MacTheme.meta)
            }
            Text(title)
                .font(MacTheme.ui(MacTheme.sidebarSectionTitleFontSize, weight: .semibold))
                .foregroundStyle(MacTheme.meta)
                .lineLimit(1)
                .truncationMode(.middle)
            // 计数：空项目也画（0），让「建了但没会话」一眼可辨
            Text("\(count)")
                .font(MacTheme.ui(10))
                .foregroundStyle(MacTheme.meta.opacity(0.7))
            Spacer(minLength: 0)
            if isProject {
                moreButton
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: onHoverChange)
    }

    /// 分组头右侧那颗「…」：**恒占位**（约束见类型文档），hover 才显
    private var moreButton: some View {
        Menu {
            Button(L("管理项目…")) { onManage() }
            Divider()
            Button(L("重命名…")) { onRename() }
            if canDelete {
                Divider()
                Button(L("删除项目"), role: .destructive) { onDelete() }
            }
        } label: {
            ConversationRowMoreLabel()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: MacTheme.sidebarRowMoreButtonSize)
        // 🔴 header 的内容**天然贴到侧栏右缘 2pt**（系统内距，实测见 `MacTheme`），而会话行的
        //    「…」和「我的对话」行那颗都在 16 ⇒ 这里补上差额，三颗按钮才在一条竖线上（2026-10-26）。
        //    ⚠️ 加在**按钮自己**上而不是外层 `HStack`：挂外层的话右边缘会有一截不响应 hover
        //    （`contentShape` 在那儿，见上面的类型注释）。
        .padding(.trailing,
                 MacTheme.sidebarListRowTrailingInset - MacTheme.sidebarListHeaderTrailingInset)
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .help(L("管理项目"))
    }
}

// MARK: - 会话行（抽成独立视图：包在 `List` 里的话渲染台验不了）

/// 会话列表的一行：置顶/会话图标 + 标题 + **hover 才显的「…」**。
///
/// ## 为什么单独抽一个视图
/// 它被 `List` 包着，而 `List` 在离屏渲染里只会画成**黄条** ⇒ 留在
/// `ConversationSidebar.row(_:)` 里的话，「hover 时按钮出现」与「标题一个像素都不动」
/// 这两件事一张图都拿不到。抽成独立视图后渲染台能直接渲它（同 `SidebarSettingsBar`）。
///
/// ## 三条约束（都有理由，别当顺手写的）
/// ① **按钮恒占位、只改 `opacity`**（不是「出现才长出来」）：写成 `if isHovered { 按钮 }` 的话，
///    hover 时标题的可用宽度会变，`.middle` 截断的长标题**截断位置会跳** ——
///    指针在列表里上下移动时整列标题都在抖。占位之后行宽恒定，出不出按钮都不影响标题。
/// ② `opacity(0)` **照样能点** ⇒ 必须配 `.allowsHitTesting(isHovered)`（同「回到底部」那颗）。
/// ③ `.contentShape(Rectangle())` 挂在 `HStack` 上：默认的命中形状只有「画了东西的地方」，
///    标题右侧那一大片 `Spacer` 空白既点亮不了按钮、右键也不响应 ——
///    这正是用户反馈的右键「不灵敏」的成因。
struct ConversationRow: View {
    let summary: AIConversationSummary
    /// 可移动到的项目列表（「移动到项目」子菜单的数据源，2026-10-21）。
    /// ⚠️ 由外面传进来而不是读单例：渲染台要能构造「有 N 个项目」的夹具而不碰数据库。
    /// 带默认值 `[]` ⇒ 渲染台那些「只验长相」的旧调用点零改动（空项目 = 不显示子菜单，
    /// 正好就是功能上线前的行为）。
    var projects: [AIChatProject] = []
    /// 指针是否停在这一行上。**从外面传进来**（不是本视图的 `@State`）——
    /// 渲染台没有指针，只有提成参数才渲得出 hover 态（同 `ChatRowView.isHovered`）。
    let isHovered: Bool
    let onHoverChange: (Bool) -> Void
    let onTogglePin: () -> Void
    let onRename: () -> Void
    /// 移动到某项目；`nil` = 归一成默认项目「任务」（默认空实现，同 `projects` 的理由）
    var onMoveToProject: (UUID?) -> Void = { _ in }
    let onShare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: summary.isPinned ? "pin.fill" : "bubble.left")
                .font(MacTheme.ui(11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            // 🔴 必须显式给字号（2026-10-15 修）：不挂 `.font` 的话标题吃 SwiftUI
            //    默认字体，**不在字号档位的缩放链上** —— 用户在设置里改字体大小，
            //    这一列毫无反应（重启也不变，因为压根没人读档位）。
            Text(summary.displayTitle)
                .font(MacTheme.ui(MacTheme.sidebarRowTitleFontSize))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            moreButton
        }
        .contentShape(Rectangle())
        .contextMenu { menuItems }
        .onHover(perform: onHoverChange)
    }

    /// 行尾那颗「…」。**恒占位**（约束 ①），只在 hover 时显出来。
    private var moreButton: some View {
        Menu {
            menuItems
        } label: {
            ConversationRowMoreLabel()
        }
        // 纯图标按钮 ⇒ 藏掉系统指示器更干净（同输入栏那颗「+」）。
        // ⛔ 也**别**在 label 末尾自绘箭头：`Menu` 会把「形状像指示器」的图吃掉，
        //    再配 hidden 就会变成「看不出能点开」（见 `MacInputBar` 那段实证）。
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: MacTheme.sidebarRowMoreButtonSize)
        .opacity(isHovered ? 1 : 0)
        .allowsHitTesting(isHovered)
        .help(L("更多操作"))
    }

    /// 菜单内容。**「…」按钮与右键菜单共用这一份** —— 两个入口各写一遍，
    /// 迟早漂成「右键里能删除、更多菜单里没有」，顺序也会各是各的
    /// （顺序 = 用户 2026-09-26 指定的「置顶 / 重命名 / 分享」，然后才是删除）。
    @ViewBuilder
    private var menuItems: some View {
        Button(summary.isPinned ? L("取消置顶") : L("置顶")) { onTogglePin() }
        Button(L("重命名…")) { onRename() }
        moveToProjectMenu
        Button(L("分享…")) { onShare() }
        Divider()
        Button(L("删除"), role: .destructive) { onDelete() }
    }

    /// 「移动到项目」子菜单（2026-10-21）。插在**重命名之后**：归类是「整理」类动作，
    /// 与置顶/重命名同族；分享与删除留在末尾（删除必须离常用的远一点）。
    ///
    /// - 2026-10-25 起「未归类」已消灭：默认项目「任务」恒存在 ⇒ 本菜单实际上
    ///   恒出现（`projects` 永不为空）。`if` 留着防 ensure 极端失败时的空列表。
    /// - 当前所在项目那一条 **disable**（点了没有任何效果，不如明说）。
    /// - 默认项目也在列表里（它就是普通一行）—— 「移出项目」= 移进它。
    @ViewBuilder
    private var moveToProjectMenu: some View {
        if !projects.isEmpty {
            Menu(L("移动到项目")) {
                ForEach(projects) { project in
                    Button(project.name) { onMoveToProject(project.id) }
                        .disabled(summary.projectId == project.id)
                }
            }
        }
    }
}

/// 「…」那颗按钮的**外观**（图标 + 命中区尺寸 + 居中）。
///
/// 🔴 单独抽出来是为了能在渲染台**单独渲它**：`Menu` 在离屏渲染里是「黄条 + ⊘」，
/// 「图标多大、什么颜色、命中区多宽」这些信息在带 `Menu` 的整行图上是拿不到的 ——
/// 把它装进一颗普通 `Button` 渲一次就全看见了。`ConversationRow` 与本视图
/// **共用同一份外观**，所以那一张图能替整行里的它作证。
struct ConversationRowMoreLabel: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(MacTheme.ui(12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: MacTheme.sidebarRowMoreButtonSize,
                   height: MacTheme.sidebarRowMoreButtonSize)
            .contentShape(Rectangle())
    }
}
