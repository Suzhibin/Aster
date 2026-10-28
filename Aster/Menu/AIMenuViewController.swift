//
//  AIMenuViewController.swift
//  AIModule
//
//  Created by Suzhibin on 2026/8/31.
//

import UIKit
import SnapKit
import AICore

/// AI 模块侧滑菜单：头部（搜索框 + 新对话按钮）+ 分组列表 + 底部账号栏。
///
/// ## 列表结构（2026-10-21 起）
/// - **section 0**：固定入口（新对话 / 文档 / 新建项目），**无组头**；
/// - **section 1..N**：`AIConversationGrouping` 算出的分组投影 ——
///   置顶（无组头）→ 各项目（组头 = 项目名 + 条数 + 「…」；默认项目「任务」
///   sortOrder = -1 恒在最前，2026-10-25 起「未归类」已消灭 ⇒ 恒有项目组头）。
///
/// 点击任一项自动关闭菜单并触发对应回调；长按历史项弹「置顶 / 重命名 / 移动到项目 / 分享 / 删除」。
/// 与 AModule 的 MenuViewController 各自独立演化（模块自治，不抽公共基类）。
public class AIMenuViewController: UIViewController {

    // MARK: - 对外数据 / 回调

    /// 对话数据源（最新在前），菜单每次即将展示时拉取。
    /// 返回摘要而非标题数组：列表要显示条数/时间，且点击按 id 定位（数组下标会随增删错位）。
    public var conversationProvider: (() -> [AIConversationSummary])?

    /// 当前正在查看的会话 id（用于列表高亮）
    public var activeConversationIdProvider: (() -> UUID?)?

    /// 新对话（抽屉第 0 组那颗 / 会话页头部按钮，两个入口同一动作）
    public var onNewChat: (() -> Void)?

    /// 「文档」—— push 一整页「所有会话里的文件」的聚合列表。
    ///
    /// 🔴 2026-10-10 取代原来的「AI创作」（那一项用户明确要去掉，且它的动作当时已被注释成
    ///    **静默无反应**）。语义从「新开一段对话」变成「打开一个跨会话的资源页」，
    ///    所以它走的是 **push 整页**那条路线（同搜索页），不再是 `onNewChat` 那一家。
    public var onDocumentsTapped: (() -> Void)?

    /// 🔴 这里**刻意没有**「点了底栏某颗按钮要通知宿主」的回调：
    /// 底栏那几颗全部**就地完成**，没有一个需要宿主配合 ⇒
    /// 加一个回调出来只是逼着接线方去判「关不关抽屉」，而这些动作都与抽屉无关。
    /// 真要加新入口时，先确认它是不是真的需要宿主。
    ///（「设置」齿轮那颗另有 `onSettings`，那是**兜底**路径，见 `settingsTapped`。）
    /// ⚠️ 2026-10-27 之前这里还有「头像 + 名称 + `>`」那一块（点开账号菜单），
    /// 随用户要求一起删掉了 —— 那三个入口的现落点见本文那个 `// MARK: - 操作` 的注释。
    /// ⚠️ 扫一扫那颗也已由用户删掉（同日）⇒ 底栏现在只剩齿轮一颗。

    /// 设置按钮（右下角齿轮）
    public var onSettings: (() -> Void)?

    /// 点击顶部搜索框。菜单里**不做就地过滤**：搜索请求交给宿主 push 一个独立的搜索页
    /// （结果要显示命中片段并高亮关键词，塞在 240pt 宽的抽屉里看不清）。
    public var onSearchTapped: (() -> Void)?

    /// 点击历史对话（参数为会话 id）
    public var onSelectConversation: ((UUID) -> Void)?

    /// 重命名历史对话（会话 id + 新标题）
    public var onRenameConversation: ((UUID, String) -> Void)?

    /// 置顶 / 取消置顶（会话 id + 目标状态）
    public var onSetPinned: ((UUID, Bool) -> Void)?

    /// 从对话列表删除（会话 id）
    public var onDeleteConversation: ((UUID) -> Void)?

    /// 分享内容提供（会话 id → 待分享文本；读库由宿主负责，菜单只负责弹系统分享）
    public var conversationTextProvider: ((UUID) -> String?)?

    // MARK: - 项目（会话文件夹，2026-10-21）
    //
    // 形态与 Mac 侧 `ConversationSidebar` **刻意同构**：分组投影不在这里算，
    // 走共享层 `AIConversationGrouping.groups(summaries:projects:)` —— 两端画的是
    // **同一份排好序的分组**，否则「置顶算不算项目内」很快会分叉。
    //
    // 🔴 2026-10-25 起「未归类」已消灭：默认项目「任务」恒存在 ⇒ `groups`
    //    恒产出「置顶（无组头，可能有）」+ 至少一个项目组，不存在「零项目」退化态。
    //    与功能上线前的平铺列表逐行一致 —— 组头只在**真有项目**时才出现。

    /// 项目列表提供者（按 sortOrder 升序），与 `conversationProvider` 同一拍刷新
    public var projectProvider: (() -> [AIChatProject])?

    /// 新建项目（第二个参数 = 建完顺带移入的会话 id，来自行菜单「移动到项目 → 新建项目…」）。
    /// ⚠️ 刻意做成「一次回调带两件事」：菜单拿不到新建项目的 id（那是库的事），
    ///    分两步回调就得让菜单先存一个待办 id，容易漏清。
    public var onCreateProject: ((_ name: String, _ moveConversationId: UUID?) -> Void)?

    /// 重命名项目（项目 id + 新名称）
    public var onRenameProject: ((UUID, String) -> Void)?

    /// 删除项目（会话不会被删，只会移回默认项目「任务」；项目资料一并删）
    public var onDeleteProject: ((UUID) -> Void)?

    /// 移动会话的归属（会话 id + 目标项目 id；传 nil 由底层归一成默认项目「任务」）
    public var onMoveConversation: ((UUID, UUID?) -> Void)?

    /// 造一个「项目详情页」交给抽屉**就地模态呈现**。
    ///
    /// 🔴 为什么是「宿主造、抽屉弹」而不是让宿主自己 `present`：
    /// 抽屉是宿主 present 出来的 ⇒ 宿主再 `present` 会撞上
    /// 「already presenting」而**静默不出**（同 `presentSettings` 那条注释说的事）。
    /// 而页面里的数据接线（manager / 预览回调）只有宿主知道 ⇒ 只能拆成
    /// 「宿主造 + 抽屉弹」两半。⛔ 别把造页面的活搬进抽屉（要 import 一堆业务细节）。
    public var makeProjectDetailPage: ((_ project: AIChatProject) -> UIViewController?)?

    // MARK: - 数据

    /// 第 0 组固定入口
    ///
    /// ⚠️ 图标与文案是**每条入口自己的语义**，别为了「看着统一」把两条图标改成同一套
    ///（mac 侧 `SidebarQuickEntries` 也是各用各的，两端刻意同构）。
    ///
    /// 🔴🔴 **必须是计算属性**（2026-10-13，用户报「iOS 端 菜单 开启AI 和 文档 没有及时切换语言」）：
    /// 抽屉菜单**全进程只有一份实例** —— SideMenu 6 的 `Protected` 闸门会**静默拒绝**换新：
    /// 旧菜单还在呈现（`isHidden` = `presentingViewController == nil` 为 false）时，
    /// `SideMenuManager.default.leftMenuNavigationController = …` **原样返回旧值**、只打一条 warning。
    /// （逐字源码与实测证据见技能 `ios-sidemenu-drawer` §4.5。）
    /// 而用户偏偏就是在**抽屉开着**的时候点账号弹窗里的语言档 ⇒ 那一刻「换实例」必然失败。
    /// ⇒ 文案若放**存储** `let`，它就等于「这个实例第一次求值那一刻的语言」，之后切多少次都不动
    ///（典型症状：整屏都翻了，就这两处死活不变）。
    /// ⚠️ 这与 `I18N.md` §三·乙「`static let X = L("…")` 是**进程级**缓存」是**同一条铁律的两个变体**：
    /// 缓存层级不同（进程级 / 实例级），症状一模一样。⛔ 别为了「省一次查表」改回 `let`。
    private var quickItems: [(icon: String, title: String)] {
        [
            // 🔴 2026-10-25 用户要求：「两端的 菜单第一项 新对话 改成 新对话」。
            //    ⚠️ 只改文案、不改行为（仍是 `startNewChat()`）、不改图标（仍是 sparkles）。
            ("sparkles", L("新对话")),
            ("doc.text", L("文档")),
            // 🔴 第三条（2026-10-21）：项目能力的**唯一入口**。
            // ⚠️ 为什么放这一组而不是「我的对话」标题右边（Mac 是把 `folder.badge.plus`
            //    挂在那个标题上的）：iOS 抽屉**没有**「我的对话」这条标题 —— 第 0 组连组头都没有。
            //    挂到分组头上就等于「有项目才看得见新建按钮」，第一个项目永远建不出来。
            //    ⇒ 这一组本来就是「固定入口」，加一条是它语义内的事。
            ("folder.badge.plus", L("新建项目"))
        ]
    }

    /// 主题色（图标 / 当前会话高亮统一使用）
    /// ⚠️ 2026-10-27 起不再用于头像 —— 底栏那块头像已按用户要求删除。
    private static let activeTintColor = UIColor(red: 0.46, green: 0.54, blue: 1.0, alpha: 1)

    /// 历史对话（最新在前，viewWillAppear 时从 provider 拉取）
    private var conversations: [AIConversationSummary] = []

    /// 项目列表（viewWillAppear 时与 `conversations` 同一拍拉取）
    private var projects: [AIChatProject] = []

    /// 分组投影（共享层算，两端同口径）。第 `i` 组对应 **section = i + 1**（section 0 是固定入口）
    ///
    /// ⚠️ **存储属性**、由 `refreshConversations()` 重算，不是计算属性：
    /// 计算属性会在 `numberOfRowsInSection` / `cellForRowAt` 里被**每行调一次**，
    /// 而它内部是 `summaries × projects` 的两次 `filter` ⇒ 100 条会话 × 5 个项目就是
    /// 每帧几十万次比较。缓存在刷新点既够用（所有改归属的路径都会 refresh）又不会算错。
    private var groups: [AIConversationGroup] = []

    /// 当前会话 id（列表高亮用）
    private var activeConversationId: UUID?

    // MARK: - 视图

    /// 头部导航：搜索框 + 新对话按钮
    private lazy var topBar: UIView = {
        let v = UIView()
        v.backgroundColor = .systemBackground
        return v
    }()

    private lazy var searchField: UITextField = {
        let f = UITextField()
        // ⚠️ 这里**刻意不写** `placeholder`：文案放在 `applyLocalizedText()` 里统一重读
        //（这个实例是全进程共用的一份，见 `quickItems` 上面那段铁律）。
        // ⚠️ 字号走 `AIChromeFont`（2026-10-22 接字号档位）：构造值只是首帧快照，
        //    换档后由 `applyFonts()` 重刷（同 `applyLocalizedText()` 的理由）。
        f.font = AIChromeFont.ui(14)
        f.clearButtonMode = .whileEditing
        f.returnKeyType = .search
        f.autocorrectionType = .no
        f.borderStyle = .roundedRect
        f.backgroundColor = .secondarySystemFill
        f.textColor = .label
        // 交给 delegate 拦下「开始编辑」→ 转为回调宿主 push 搜索页，
        // 这样这里永远是个「长得像输入框的按钮」，不会在抽屉里弹出键盘
        f.delegate = self
        return f
    }()

    private lazy var newChatButton: UIButton = {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "square.and.pencil"), for: .normal)
        b.tintColor = .label
        b.backgroundColor = .secondarySystemFill
        b.layer.cornerRadius = 10
        b.addTarget(self, action: #selector(newChatTapped), for: .touchUpInside)
        return b
    }()

    /// 列表：0=固定入口，1..N=分组（分组投影见 `groups`）
    ///
    /// ⚠️ `sectionHeaderTopPadding = 0` 是**必须的**（2026-10-21）：iOS 15 起 `.plain` 表会给
    ///    每个组头**额外加 22pt 上边距**（默认值 `automaticDimension`）。不关掉的话，
    ///    「置顶组」这些**不画组头**的组也会被顶出一道 22pt 的空隙 ——
    ///    症状正是本功能最怕的那条：默认态（零项目）列表不再与上线前一致。
    private lazy var tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .plain)
        t.delegate = self
        t.dataSource = self
        t.register(UITableViewCell.self, forCellReuseIdentifier: "AIMenuCell")
        t.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        t.backgroundColor = .systemBackground
        t.tableFooterView = UIView()
        t.keyboardDismissMode = .onDrag
        t.sectionHeaderTopPadding = 0
        return t
    }()

    // MARK: - 底部固定栏（高度同 tabBar，安全区自适应）
    //
    // 一行放一颗：设置齿轮（靠右；扫一扫已由用户删除，2026-10-27）。
    //
    // 🔴 2026-10-27 用户「那就把头像和名称都删除吧」⇒ 原来这里最左边还有一整块
    //    「头像 + 名称 + `>`」（点它弹账号菜单）。删的理由与 Mac 侧 `SidebarSettingsBar`
    //    文件头**逐条同源**：本 App 没有账号体系，头像/姓名是「假装有个我」；
    //    设置这颗齿轮本来就在；GitHub 在「设置 → 关于」；「退出登录」本来就是占位。
    //    ⛔ 别把那一块加回来（要加先回答「这个'我'是谁」）。

    /// 底栏**内容**高度（不含底部安全区）。原来由 `profileButton` 的约束间接撑出来，
    /// 那块删掉之后必须**显式给出来** —— 否则底栏高度会塌成 0（两颗按钮画在屏幕外，不报错）。
    private static let bottomBarContentHeight: CGFloat = 49

    private lazy var bottomBar: UIView = {
        let v = UIView()
        v.backgroundColor = .systemBackground
        return v
    }()

    /// 分割线（贴 bottomBar 顶部）
    private lazy var bottomTopLine: UIView = {
        let v = UIView()
        v.backgroundColor = .separator
        return v
    }()

    // 🗑️ 2026-10-27 扫一扫那颗按钮**是用户主动删的**（不是删「头像 + 名称」时连带掉的）。
    //    所以底栏现在只有一颗齿轮，`scanTapped` 与它的 toast 先留着当接线点：
    //    真接扫描时在那层 present 扫码页即可（相机权限走 `StarryPermission`）。
    //    ⛔ 别「看到契约报红就把按钮加回来」—— 那条契约已改成反向断言。

    private lazy var settingsButton: UIButton = {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "gearshape"), for: .normal)
        b.tintColor = .label
        b.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        return b
    }()

    // MARK: - 生命周期

    public override func viewDidLoad() {
        super.viewDidLoad()
        // 去掉 SideMenuNavigationController 自带的导航栏高度
        navigationController?.setNavigationBarHidden(true, animated: false)
        view.backgroundColor = .systemBackground
        setupUI()
        // 「字体大小」换档（设置页 → 字体大小页）：本页 chrome 字号走 `AIChromeFont`
        // （共享层 `uiScale` 比例口径，2026-10-22 方案 A）⇒ 换档要重刷，见 `applyFonts()`。
        // ⚠️ iOS 侧只能这么接：Observation（Mac 那条零接线的路）在 UIKit 里用不上。
        //    本实例是全进程共用的一份（见 `quickItems` 铁律）⇒ observer 跟着它活全程，
        //    在 `deinit` 里统一摘（真机上看不到 deinit 也无妨：进程级单例本就同生共死）。
        NotificationCenter.default.addObserver(self,
                                              selector: #selector(fontSizeDidChange),
                                              name: AIFontSizeStore.didChange,
                                              object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 设置页换了「字体大小」档位（`AIFontSizeStore.didChange`）。
    @objc private func fontSizeDidChange() {
        applyFonts()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 🔴 先把「随语言变」的那几处文案重新取一遍，再拉数据。
        //    顺序有意：文案是**每次展示都该准**的，数据是**可能变**的 —— 两步都放在这里，
        //    是因为本实例**全进程只有一份**（成因见 `quickItems` 上面那段铁律），
        //    ⛔ 一旦写进 `lazy var` 就再也没机会翻。
        applyLocalizedText()
        // 每次即将展示时把 chrome 字号按当前档位重刷一遍（2026-10-22 方案 A）。
        // 顺序有意：与 `applyLocalizedText()` 同一拍，都在拉数据之前 ——
        // 两件事都是「每次展示都该准」的，数据是「可能变」的。
        applyFonts()
        // 每次即将展示时拉最新数据（新对话 / 标题变化 / 重命名都能及时反映）
        refreshConversations()
    }

    /// 把「懒加载控件里那几处一次性赋值」的文案**每次展示时重读**一遍。
    ///
    /// 🔴 这个方法是本页唯一的「文案刷新点」。缺了它，用户看到的会是「抽屉第一次被打开那一刻的语言」。
    /// ⛔ 别把这几行搬回 `lazy var` 的构造闭包里 —— 那是**一次性求值**，正是 2026-10-13 那个 bug 的成因。
    /// ⚠️ `quickItems` 不在这里刷新：它是**计算属性**，取行数 / 建 cell 时天然现读。
    private func applyLocalizedText() {
        searchField.placeholder = L("搜索对话")
    }

    /// 把「随字号档位变」的 chrome 字号**每次展示 / 换档时重刷**一遍（2026-10-22 方案 A）。
    ///
    /// 🔴 为什么必须有这个方法：`AIChromeFont.ui(...)` 读的是**当前**档位，而
    /// `searchField` 是 `lazy var` —— 构造那一刻一次性快照，
    /// 之后改档位不会自己重算（UIKit 不吃 Observation）。与 `applyLocalizedText()`
    /// 同一条理由、同一套模式：⛔ 别把这几行搬回 `lazy var` 构造闭包。
    /// ⚠️ 列表侧（cell / 组头）不用逐个点：`reloadData()` 时 `cellForRowAt` 的
    ///    `config.textProperties.font` 与 `viewForHeaderInSection` 的组头（每次新建）
    ///    都会现读 `AIChromeFont` ⇒ 一次重载全覆盖。
    private func applyFonts() {
        searchField.font = AIChromeFont.ui(14)
        tableView.reloadData()
    }

    // MARK: - 数据刷新

    /// 重新拉取会话列表 / 项目列表 / 当前会话 id（供高亮）并刷新列表
    ///
    /// ⚠️ 两者**同一拍**取：分组投影要同时用 `conversations` 与 `projects`，
    /// 分两次刷新会出现「会话已在项目里、项目名还是旧的」这种半帧状态。
    private func refreshConversations() {
        conversations = conversationProvider?() ?? []
        projects = projectProvider?() ?? []
        activeConversationId = activeConversationIdProvider?()
        groups = AIConversationGrouping.groups(summaries: conversations, projects: projects)
        tableView.reloadData()
    }

    // MARK: - 长按菜单（UIContextMenu：置顶 / 重命名 / 分享 / 删除）

    private func presentRenameAlert(for summary: AIConversationSummary) {
        let alert = UIAlertController(title: L("重命名对话"), message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = summary.displayTitle
            textField.clearButtonMode = .whileEditing
            textField.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("确定"), style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard let self else { return }
            self.onRenameConversation?(summary.id, trimmed)
            self.refreshConversations()
        })
        present(alert, animated: true)
    }

    /// 组装长按菜单：置顶 / 重命名 / 移动到项目 / 分享对话 / 从对话列表删除
    ///
    /// ⚠️ 「移动到项目」放在**重命名之后、分享之前**（与 Mac 行菜单同序）：
    /// 前两条都是「改这条会话自身的属性」，分享/删除是「把它交出去 / 干掉」，
    /// 归类属于前者，别插到后面去。
    private func makeContextMenu(for summary: AIConversationSummary) -> UIMenu {
        let pin = UIAction(title: summary.isPinned ? L("取消置顶") : L("置顶对话"),
                           image: UIImage(systemName: summary.isPinned ? "pin.slash" : "pin")) { [weak self] _ in
                               guard let self else { return }
            self.onSetPinned?(summary.id, !summary.isPinned)
            self.refreshConversations()          // 置顶会改变排序，立即刷新
        }
        let rename = UIAction(title: L("重命名"), image: UIImage(systemName: "pencil")) { [weak self] _ in
            // 菜单正在消失，下一帧再弹输入框，避免「dismiss 过程中 present」告警
            DispatchQueue.main.async {
                guard let self else { return }
                self.presentRenameAlert(for: summary)
            }
        }
        let move = makeMoveToProjectMenu(for: summary)
        let share = UIAction(title: L("分享对话"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.presentShare(for: summary)
            }
        }
        let delete = UIAction(title: L("从对话列表删除"),
                              image: UIImage(systemName: "trash"),
                              attributes: .destructive) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.presentDeleteConfirm(for: summary)
            }
        }
        return UIMenu(title: "", children: [pin, rename, move, share, delete])
    }

    /// 「移动到项目」子菜单：各项目（当前所在条打勾）+ 新建项目…。
    ///
    /// 🔴 一个项目都没有时**不能整个子菜单消失**（那样用户永远找不到「归到某项目」这条路，
    ///    而新建项目的入口就藏在里面），此时它只剩「新建项目…」一条 —— 仍然有用。
    ///    （2026-10-25 起默认项目「任务」恒存在 ⇒ 实际上永远不会空，防御留着。）
    /// 🔴 用 `state: .on` 表示当前归属，而不是 `attributes: .disabled`：
    ///    禁用会让「点自己所在的项目」看起来像坏了；这里点了就是**幂等**动作
    ///    （`setConversationProject` 写同一个值），无害。
    private func makeMoveToProjectMenu(for summary: AIConversationSummary) -> UIMenu {
        var children: [UIAction] = projects.map { project in
            UIAction(title: project.name,
                     image: UIImage(systemName: "folder"),
                     state: summary.projectId == project.id ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.onMoveConversation?(summary.id, project.id)
                self.refreshConversations()      // 归属变了 = 行要换组，必须刷新
            }
        }
        let create = UIAction(title: L("新建项目"), image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
            // 同重命名：等菜单消失的下一帧再弹
            DispatchQueue.main.async {
                guard let self else { return }
                self.presentCreateProject(moveConversationId: summary.id)
            }
        }
        // 2026-10-25 起「未归类」已消灭：原来那条 tray 图标的 UIAction 删了。
        // 「移出项目」= 移进默认项目「任务」（它就在上面的列表里）。
        children.append(create)
        return UIMenu(title: L("移动到项目"),
                      image: UIImage(systemName: "folder"),
                      children: children)
    }

    /// 分享：整段对话由宿主拼成文本，菜单只负责弹系统分享面板
    private func presentShare(for summary: AIConversationSummary) {
        guard let text = conversationTextProvider?(summary.id), !text.isEmpty else { return }
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        // iPad 必须给锚点，否则崩溃
        activity.popoverPresentationController?.sourceView = view
        activity.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX,
                                                                    y: view.bounds.midY,
                                                                    width: 0, height: 0)
        present(activity, animated: true)
    }

    /// 删除二次确认（破坏性操作）
    private func presentDeleteConfirm(for summary: AIConversationSummary) {
        let alert = UIAlertController(
            title: L("删除对话"),
            message: String(format: L("「%@」将从对话列表中移除，且无法恢复。"), summary.displayTitle),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.onDeleteConversation?(summary.id)
            self.refreshConversations()
        })
        present(alert, animated: true)
    }

    // MARK: - 项目（新建 / 重命名 / 删除）
    //
    // 三个弹窗都**就地 present 在抽屉自己身上**（同重命名会话）：
    // 抽屉是模态、主页被推到右边还盖了遮罩 ⇒ 交给宿主弹，用户在画外看不见。
    //
    // ⚠️ 全部用 `UIAlertController(.alert)` 而不是 `.actionSheet`：`.actionSheet` 在 iPad 上
    //    解析成 popover、**不给锚点会崩**（`presentShare` 就是为这个补的锚点）。

    /// 新建项目
    ///
    /// - Parameter moveConversationId: 非空 ⇒ 建成后把这条会话移进去
    ///   （行菜单「移动到项目 → 新建项目…」那条路径）。**靠闭包捕获传下去**，
    ///   不用实例变量存 —— 存了就得在每个出口（取消 / 空名字 / 成功）都记得清一次，漏一个就是串味。
    private func presentCreateProject(moveConversationId: UUID?) {
        view.endEditing(true)
        let alert = UIAlertController(title: L("新建项目"), message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = L("项目名称")
            textField.clearButtonMode = .whileEditing
            textField.returnKeyType = .done
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("创建"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let raw = alert?.textFields?.first?.text ?? ""
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空名字 = 用户没填，不是「创建失败」⇒ 静默放弃（不弹提示，同重命名会话那条）
            guard !name.isEmpty else { return }
            self.onCreateProject?(name, moveConversationId)
            self.refreshConversations()
        })
        present(alert, animated: true)
    }

    /// 重命名项目（入口：分组头右侧「…」菜单）
    private func presentRenameProject(_ project: AIChatProject) {
        view.endEditing(true)
        let alert = UIAlertController(title: L("重命名项目"), message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = project.name
            textField.clearButtonMode = .whileEditing
            textField.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("确定"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let raw = alert?.textFields?.first?.text ?? ""
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            self.onRenameProject?(project.id, name)
            self.refreshConversations()
        })
        present(alert, animated: true)
    }

    /// 删除项目二次确认。
    ///
    /// 🔴 文案必须写清「会话不会被删除」：用户最怕的是「删个文件夹把聊天记录删了」。
    ///    实际级联在 `AIChatStore.deleteProject`（会话解除归类 + 资料物理删除）。
    private func presentDeleteProjectConfirm(_ project: AIChatProject) {
        let alert = UIAlertController(
            title: L("删除项目？"),
            message: String(format: L("「%@」里的会话不会被删除，只会移回「任务」；项目里的资料会一并删除。"),
                            project.name),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除项目"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.onDeleteProject?(project.id)
            self.refreshConversations()
        })
        present(alert, animated: true)
    }

    // MARK: - 布局

    private func setupUI() {
        view.addSubview(topBar)
        topBar.addSubview(searchField)
        topBar.addSubview(newChatButton)
        view.addSubview(tableView)
        // 底部固定栏最后添加，盖在 tableView 之上
        view.addSubview(bottomBar)
        bottomBar.addSubview(bottomTopLine)
        bottomBar.addSubview(settingsButton)

        topBar.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(56)
        }
        searchField.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
            make.height.equalTo(36)
        }
        newChatButton.snp.makeConstraints { make in
            make.leading.equalTo(searchField.snp.trailing).offset(10)
            make.trailing.equalToSuperview().offset(-16)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(36)
        }
        tableView.snp.makeConstraints { make in
            make.top.equalTo(topBar.snp.bottom)
            make.leading.trailing.equalToSuperview()
            // 列表底 = bottomBar 顶，滚动内容不会被固定栏遮挡
            make.bottom.equalTo(bottomBar.snp.top)
        }

        // 底部固定栏：高度由「内容区 49pt + 底部安全区」约束推导，
        // 不手动读 safeAreaInsets（viewDidLoad 阶段读不到，SideMenu 模态未布局），
        // 安全区变化由 safeAreaLayoutGuide 自动适配。
        // 🔴 2026-10-27：原来底栏高度是**间接**由 `profileButton`（top=栏顶 / height=49 / bottom=安全区）
        //    撑出来的，那块删掉之后必须**显式**给一条 —— 否则底栏高度塌成 0，
        //    两颗按钮会被画到屏幕外，而且**不报错**。
        bottomBar.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.top.equalTo(view.safeAreaLayoutGuide.snp.bottom).offset(-Self.bottomBarContentHeight)
        }
        bottomTopLine.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
            make.height.equalTo(0.5)
        }
        // 齿轮贴右缘 16（扫一扫已删 ⇒ 底栏只剩这一颗）。
        // ⚠️ 垂直居中要挂在「底栏内容区」上（`bottomBar.top + 49/2`），
        //    ⛔ 别用 `equalToSuperview()`：底栏含底部安全区，那样按钮会整体下移半个安全区。
        settingsButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-16)
            make.width.height.equalTo(36)
            make.centerY.equalTo(bottomBar.snp.top).offset(Self.bottomBarContentHeight / 2)
        }
    }

    // MARK: - 操作

    // 🗑️ 2026-10-27 删掉的两个方法：`profileTapped()` 与 `presentAccountMenu()`。
    //    它们只服务「头像 + 名称 + `>`」那一块（点了弹账号菜单：设置 / GitHub）。
    //    用户「那就把头像和名称都删除吧」⇒ 入口没了，弹窗类 `AIAccountMenuViewController`
    //    整个文件也一起删了。三个动作的现落点：
    //      · 设置   → 本文件那颗齿轮（`settingsTapped` → `presentSettings`，一直在）
    //      · GitHub → 「设置 → 关于」页（`AIAboutViewController`，地址走共享层 `AIGitHubURL`）
    //      · 退出登录 → 删（本来就只是占位提示，没有账号体系可退）
    //    ⛔ 别照着旧版把这一块加回来（要加先回答「这个'我'是谁」）。

    /// 扫一扫（⚠️ 那颗按钮已由用户删除 2026-10-27 ⇒ 目前**没有调用方**，先留作接线点）。
    ///
    /// ⚠️ 现在只弹提示（用户 2026-10-03：「扫描事件先弹吐司就行」）。
    /// 🔴 提示**必须贴在菜单自己身上**（`AIToast.show(in: view)`），不能回调宿主去弹：
    ///    抽屉是模态、主页面被推到右边还盖了遮罩 ⇒ 会话页的 toast 在**画外**（用户只会以为点了没反应）。
    /// ⚠️ `bottomInset` 给 61 = 底栏 49 + 12 的间隙：不传就会盖在最下面那一行上。
    /// 真接扫描时：就在这一层 present 一个扫码页（同设置齿轮那套「就地模态、抽屉不关」），
    /// 相机权限走 `StarryPermission`（别自己去 requestAccess，权限预热与拒绝引导本工程已统一收口）。
    @objc private func scanTapped() {
        AIToast.show(L("扫一扫功能开发中"), in: view, bottomInset: 61)
    }

    @objc private func settingsTapped() {
        presentSettings()
    }

    /// 在**这层菜单上**直接模态弹出设置页（观感对齐 DeepSeek）：
    /// 抽屉保持打开，设置页盖在菜单之上，左上角「关闭」→ 回到菜单（抽屉还在）。
    ///
    /// ⚠️ 这里**绝不能 `dismissAndNotify`** —— 那是「抽屉收起 + 设置页 push 进主栈」那条旧做法，
    /// 关掉抽屉后 pop 回来菜单就没了。两者是互斥的两套方案，别混。
    ///
    /// ⚠️ 依赖 `SideMenuNavigationController.dismissOnPresent = false`（在
    /// `SceneDelegate.setupAIMenu` 里设）。该属性 SideMenu **默认 true**，会在
    /// 「从菜单 present 新页面」时自动把菜单 dismiss 掉 → 漏设的话抽屉照样关，白改。
    ///
    /// 呈现用系统默认的 `.automatic`：iPhone 上解析为 `.pageSheet`，即从下滑入的卡片
    /// （正是 DeepSeek 那个观感），并自带下拉关闭；iPad 上则自动变 formSheet。
    ///
    /// 🔴 **单点**：`settingsTapped`（齿轮）与账号菜单里的「设置」是**同一个动作**，
    ///    必须落到这一个方法上 —— 分两份写，将来改呈现方式一定只改一处。
    private func presentSettings() {
        view.endEditing(true)
        guard presentingViewController != nil else {
            // 菜单不是被模态呈现的（异常路径）→ 退回宿主自己开设置页
            onSettings?()
            return
        }
        // 🔴 2026-10-14 起落点是**设置页**（`AISettingsViewController`，本轮新建）：
        //    它取代了原来直连的「自定义模型」清单页 —— 用户要求「设置页面可以把外边的
        //    语言设置、外观设置 都移动设置里」⇒ 设置成了一个容器，清单页降为它的一个子页。
        //    设置页是那个 nav 的 root ⇒ 传 `isModal: true` 让它自备左上角「关闭」
        //    （抽屉保持打开，关掉它回到菜单 —— 见本方法的注释）。
        let nav = UINavigationController(rootViewController: AISettingsViewController(isModal: true))
        present(nav, animated: true)
    }

    @objc private func newChatTapped() {
        dismissAndNotify { [weak self] in
            guard let self else { return }
            self.onNewChat?()
        }
    }

    /// 关闭菜单（若以模态 / SideMenu 呈现）后回调宿主
    ///
    /// - Parameter animated: 关闭是否带动画。默认 `true`（只是切列表内容、不跳页时，滑走动画本身就是反馈）。
    ///   **目标页要 push / present 时传 `false`**：否则两段 0.35s 动画串行，点完要等两段。
    ///
    /// 无动画时 `dismiss` 的 completion 是**同步**回调（SideMenu 的
    /// `SideMenuAnimationController.transition(...)` 里 `if !animated { animations(); completion(true); return }`），
    /// 所以紧接着 push 不会多等一帧：抽屉瞬间收起 → 目标页立刻滑入，中间主页面不会闪。
    /// （搜索页走的就是这条：`animated: false` + 宿主立刻 push。
    ///   设置页与账号菜单**不走**这里 —— 它们是「就地模态、抽屉不关」，见 `presentSettings`。
    /// （SideMenu 的 `alwaysAnimate` 只作用于 `dismissOnPush` 那条路径，本处不受其影响。）
    private func dismissAndNotify(animated: Bool = true, _ notify: @escaping () -> Void) {
        if presentingViewController != nil {
            dismiss(animated: animated) { notify() }
        } else {
            notify()
        }
    }
}

// MARK: - UITableViewDataSource / Delegate

extension AIMenuViewController: UITableViewDataSource, UITableViewDelegate {

    // MARK: 行 / 组 的映射（唯一口径，别在别处再算一遍 section - 1）

    /// 某个 section 对应的分组；section 0（固定入口）返回 nil
    private func group(atSection section: Int) -> AIConversationGroup? {
        let index = section - 1
        guard index >= 0, index < groups.count else { return nil }
        return groups[index]
    }

    /// 某个 indexPath 对应的会话；**占位行**（空项目的「暂无对话」）与固定入口返回 nil
    ///
    /// ⚠️ 空项目要显一行占位 ⇒ `row` 有可能指向「不存在的东西」，
    ///    所有拿会话的地方都必须走这个函数，⛔ 别直接 `group.items[indexPath.row]`（会越界）。
    private func summary(at indexPath: IndexPath) -> AIConversationSummary? {
        guard let group = group(atSection: indexPath.section) else { return nil }
        guard indexPath.row < group.items.count else { return nil }
        return group.items[indexPath.row]
    }

    /// 这一行是不是「空项目」的占位行
    private func isPlaceholderRow(_ indexPath: IndexPath) -> Bool {
        guard let group = group(atSection: indexPath.section) else { return false }
        // 2026-10-25 起「未归类」已消灭 ⇒ 所有组都是项目，空了**都要画占位**
        // （用户刚建的项目 / 刚清空的默认组，都得看得见）。`isProject` 判断是防御。
        // 项目为空时**要画**（用户刚建的项目得看得见，否则会以为没建成）
        return group.kind.isProject && group.items.isEmpty
    }

    public func numberOfSections(in tableView: UITableView) -> Int {
        // 0 = 固定入口；1..N = 分组
        1 + groups.count
    }

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return quickItems.count }
        guard let group = group(atSection: section) else { return 0 }
        // 空项目占一行（占位文案）；其余按实际条数
        return group.items.isEmpty ? (group.kind.isProject ? 1 : 0) : group.items.count
    }

    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        52
    }

    // MARK: 组头

    public func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        // section 0 没有组头；「置顶」段也没有（title == nil）
        // ⇒ 默认态（没有任何置顶会话）只剩项目组头，列表与上线前逐行一致。
        (group(atSection: section)?.title == nil) ? 0 : 34
    }

    public func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let group = group(atSection: section), let title = group.title else { return nil }
        // 所有组都是项目（2026-10-25 起「未归类」已消灭）⇒ 恒有「…」；
        // 默认项目「任务」也有，只是菜单里少一项「删除」（见 makeGroupMenu）
        let menu = group.kind.isProject ? makeGroupMenu(for: group) : nil
        return AIMenuGroupHeaderView(title: title, count: group.items.count, menu: menu)
    }

    /// 分组头「…」的菜单（管理资料 / 重命名 / 删除项目）
    private func makeGroupMenu(for group: AIConversationGroup) -> UIMenu? {
        guard case .project(let projectId) = group.kind,
              let project = projects.first(where: { $0.id == projectId }) else { return nil }
        let manage = UIAction(title: L("管理项目"), image: UIImage(systemName: "folder")) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.presentProjectDetail(project)
            }
        }
        let rename = UIAction(title: L("重命名项目"), image: UIImage(systemName: "pencil")) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.presentRenameProject(project)
            }
        }
        // 🔴 默认项目「任务」**不给删除这一项**（store 层 `deleteProject` 双保险）：
        //    它是无归属会话的唯一容器，删了系统就没有默认去处。
        //    重命名与管理资料照给 —— 默认组允许用户起专属名、也可以放资料。
        if projectId != AIChatStore.defaultProjectId {
            let delete = UIAction(title: L("删除项目"),
                                  image: UIImage(systemName: "trash"),
                                  attributes: .destructive) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.presentDeleteProjectConfirm(project)
                }
            }
            return UIMenu(title: "", children: [manage, rename, delete])
        }
        return UIMenu(title: "", children: [manage, rename])
    }

    /// 就地模态弹出项目详情页（抽屉**不关**，与设置页同一套）。
    ///
    /// ⚠️ 自备 nav：详情页要 push 预览页，没有 nav 就推不动（同 `presentSettings`）。
    private func presentProjectDetail(_ project: AIChatProject) {
        view.endEditing(true)
        guard let page = makeProjectDetailPage?(project) else { return }
        present(UINavigationController(rootViewController: page), animated: true)
    }

    // MARK: 行

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "AIMenuCell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.imageProperties.tintColor = Self.activeTintColor
        config.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18)
        // 🔴 字号走 `AIChromeFont`（2026-10-22 接档位）：cell 是复用的，这里每次配置都现读
        //    ⇒ 换档后一次 `reloadData()`（`applyFonts()` / `refreshConversations()` 都会带）
        //    就能全部翻过来，不需要给 cell 记「旧字号」。
        config.textProperties.font = AIChromeFont.ui(16)
        if indexPath.section == 0 {
            let item = quickItems[indexPath.row]
            config.image = UIImage(systemName: item.icon)
            config.text = item.title
            cell.accessoryType = .none
        } else if isPlaceholderRow(indexPath) {
            // 空项目占位：**不画图标**（画个气泡会让人以为能点进去）
            config.image = nil
            config.text = L("暂无对话")
            config.textProperties.font = AIChromeFont.ui(14)
            config.textProperties.color = .tertiaryLabel
            cell.accessoryType = .none
        } else if let summary = summary(at: indexPath) {
            config.image = UIImage(systemName: "bubble.left")
            config.text = summary.displayTitle
            // 当前正在查看的会话打勾高亮
            cell.accessoryType = (summary.id == activeConversationId) ? .checkmark : .none
            config.textProperties.color = (summary.id == activeConversationId) ? Self.activeTintColor : .label
        }
        cell.contentConfiguration = config
        cell.backgroundColor = .systemBackground
        cell.selectionStyle = .none
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            switch indexPath.row {
            case 0:
                // 新对话：只切当前会话的内容、不 push ⇒ 抽屉照常动画收起
                dismissAndNotify { [weak self] in
                    guard let self else { return }
                    self.onNewChat?()
                }
            case 1:
                // 🔴 接下来是 **push 一整页**（自带动画）：抽屉必须**无动画**关，
                //    否则「抽屉收起 + push」两段串行会变成「点完等半天才进」
                //    —— 与顶部搜索框那条同一理由（见 `textFieldShouldBeginEditing`）。
                dismissAndNotify(animated: false) { [weak self] in
                    guard let self else { return }
                    self.onDocumentsTapped?()
                }
            default:
                // 新建项目：也是一个弹窗，抽屉**不关**（同重命名 / 设置那一路）
                presentCreateProject(moveConversationId: nil)
            }
            return
        }
        // 占位行不响应点击（点「暂无对话」什么都不该发生）
        guard let summary = summary(at: indexPath) else { return }
        dismissAndNotify { [weak self] in
            guard let self else { return }
            self.onSelectConversation?(summary.id)
        }
    }

    /// 长按历史对话：系统 UIContextMenu（置顶 / 重命名 / 移动到项目 / 分享 / 删除）。
    /// 第 0 组的固定入口与占位行都不弹菜单。
    public func tableView(_ tableView: UITableView,
                          contextMenuConfigurationForRowAt indexPath: IndexPath,
                          point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.section > 0, let summary = summary(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            // ☠️ 本闭包要**返回 `UIMenu?`**（`UIContextMenuActionProvider` = `… -> UIMenu?`）。
            //    原来靠"单表达式隐式返回"，改成 `guard` 后就是多语句了 ⇒ **必须显式 `return`**，
            //    否则编译报 `cannot convert value of type '()' to closure result type 'UIMenu'`
            //    （2026-10-12 实测；这是转换器漏判"隐式返回"的盲点）。
            guard let self else { return nil }
            return self.makeContextMenu(for: summary)
        }
    }
}

// MARK: - UITextFieldDelegate

extension AIMenuViewController: UITextFieldDelegate {

    /// 顶部搜索框**不允许就地编辑**：拦下「开始编辑」改为回调宿主 push 独立搜索页，并返回 false。
    ///
    /// 为什么不用「加个透明按钮盖住」那套（本工程输入栏切换键盘时用过）：这里返回 false 更直接 ——
    /// 键盘一次都不会弹，也不会给搜索框留下焦点/光标之类的残留状态。
    /// 返回 false 是**必须的**：不返回的话抽屉里会直接弹出键盘，而这里根本没有能展示结果的列表。
    ///
    /// 关闭抽屉走**无动画**（同设置齿轮）：紧跟着的 push 自带 0.35s 动画，
    /// 两段串行会变成「点完等半天才进」；非动画路径下 `dismiss` 的 completion 是同步的，不会闪。
    public func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        dismissAndNotify(animated: false) { [weak self] in
            guard let self else { return }
            self.onSearchTapped?()
        }
        return false
    }
}

// MARK: - 分组头（项目名 + 条数 + 「…」菜单）

/// 抽屉里的分组头，2026-10-21 随「项目（会话文件夹）」一起新增。
///
/// ## 为什么不是 `UITableViewHeaderFooterView` + `register` 复用
/// 组头数量 = 项目数（个位数），复用省不下什么；而复用要额外处理一类**静默错**：
/// 上一次挂的 `menu` 还留在按钮上 —— 删掉一个项目后组头被另一个项目复用，
/// 菜单里指的仍是**旧 project id**，点了就删错项目（不报错、看起来还挺正常）。
/// **每次新建**反而没有状态可残留。
///
/// ## 「…」为什么是 `showsMenuAsPrimaryAction`
/// 点一下就开菜单（iOS 14+）。长按开菜单在这里**不成立** —— 组头本身长按没有语义，
/// 而用户对「抽屉里的分组标题」是不会去长按试探的。
final class AIMenuGroupHeaderView: UIView {

    /// - Parameters:
    ///   - count: 组内会话条数（显示在名字右侧，弱化成灰字）
    ///   - menu: 「…」的菜单；**nil ⇒ 不画这颗按钮**（置顶段不是实体，没有可改名/删除的东西）
    init(title: String, count: Int, menu: UIMenu?) {
        super.init(frame: .zero)
        backgroundColor = .systemBackground

        let iconView = UIImageView(image: UIImage(systemName: "folder"))
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)

        let titleLabel = UILabel()
        titleLabel.text = title
        // 🔴 字号走 `AIChromeFont`（2026-10-22 接档位）：组头**每次新建**（不复用，见类注释）
        //    ⇒ `tableView.reloadData()` 时现读当前档位，天然跟上，无需额外刷新点。
        titleLabel.font = AIChromeFont.ui(14, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        titleLabel.lineBreakMode = .byTruncatingTail
        // 名字长的时候先牺牲它，别去挤右侧的计数与「…」
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let countLabel = UILabel()
        countLabel.text = "\(count)"
        countLabel.font = AIChromeFont.ui(13)
        countLabel.textColor = .tertiaryLabel
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let moreButton = UIButton(type: .system)
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = .secondaryLabel
        // ⚠️ `UIButton` **没有** `preferredSymbolConfiguration` 属性（那是 `UIImageView` 的），
        //    要按态给图配符号得走 `setPreferredSymbolConfiguration(_:forImageIn:)`。
        moreButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold), forImageIn: .normal)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = menu
        moreButton.isHidden = (menu == nil)

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(countLabel)
        addSubview(moreButton)

        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(14)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(5)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(countLabel.snp.leading).offset(-6)
        }
        moreButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-10)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(28)
        }
        countLabel.snp.makeConstraints { make in
            make.trailing.equalTo(moreButton.snp.leading).offset(-4)
            make.centerY.equalToSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// MARK: - 🧪 探针专用（`STARRY_I18N_TRACE=1`，见 `I18NTraceProbe.swift`）

#if DEBUG
extension AIMenuViewController {

    /// 第 0 组那两条固定入口**此刻**的文案。
    ///
    /// 🔴 这个取值口本身就是判据的关键：`quickItems` 是**实例级存储属性**，
    ///    文案在 `init` 那一刻就定死了 ⇒ 只有**换过实例**它才会翻。
    var debugQuickTitles: [String] { quickItems.map(\.title) }

    /// 数据接线有没有接上（宿主 `wireMenu(_:)` 是唯一接线点）。
    var debugIsWired: Bool { conversationProvider != nil }

    /// 走真实入口开设置页（本体是 `settingsTapped()`，点右下角齿轮走的就是它）。
    /// ⚠️ 2026-10-27 之前这里是「弹账号菜单」的探针 —— 账号菜单删了之后改走齿轮，
    ///    仍然**绕开不了真实路径**（同一个 `presentSettings()`），探针才有意义。
    func debugPresentSettings() { settingsTapped() }
}
#endif
