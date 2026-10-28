//
//  AISettingsViewController.swift
//  Aster
//
//  设置页（iOS）—— 2026-10-14 新建，形态**参照 Mac 的 `MacSettingsView`**。
//
//  ## 它在页面层级里的位置（这一页是**新增的一层**）
//      侧滑菜单右下角齿轮 / 账号弹窗「设置」
//            ↓
//      **本页**（模态弹出的 `UINavigationController` 的 root）
//            ↓ 语言 / 外观 → 三档选择页 · 自定义模型 → 清单页 · 通知 → 通知设置页
//            ↓ 指令 → 指令编辑页 · 生成参数 → 参数页（2026-10-20 加）
//            ↓ 长期记忆 → 记忆管理页（2026-10-25 加）· 关于 → 关于页
//
//  ## 🔴 为什么要这一页（与 Mac 侧同一个理由）
//  改造前：齿轮直接弹「自定义模型」清单页 —— 设置**就是**模型管理，语言/外观挂在账号弹窗里。
//  用户 2026-10-14 的要求是「设置页面左侧是菜单，右侧是不同设置功能」并把外边的
//  「语言设置 / 外观设置」都收进设置里。
//  ⚠️ 两端形态**刻意不同**：macOS 的设置窗本该是「左栏一列 + 右侧一片」（系统设置 / Xcode 都这样）；
//    iOS 上「一列分组 + 点进子页」才是原生形态（`UITableView(.insetGrouped)`），
//    ⛔ 别把 Mac 那个右侧分页搬过来 —— iOS 屏宽根本放不下两栏。
//
//  ## 🔴 分组表必须写在**计算属性**里
//  `sections` 每次现读 ⇒ 切语言之后重建界面时拿到的是新文案。
//  ⛔ 别提成 `static let`：静态初始化只跑一次，切语言后那三个组标题永远是旧语言
//  （与 `AIMenuViewController.quickItems` 是**同一条铁律的两个变体**，见 `AILocalization.swift` 文件头）。
//
//  ## ⚠️ 「当前档」右侧值必须**每次 `viewWillAppear` 重读**
//  用户可能在「外观」子页里换了一档再返回 ⇒ 不重读的话本页右侧还写着旧档
//  （存取点不是可观察的，写它不会让本页重算）。
//  语言那条同理 —— 只是语言一旦换了，整棵界面（含本页）会被 `SceneDelegate` 重建。
//
//  ## 入口方式决定左上角
//  - `isModal: true`（侧滑菜单 / 账号弹窗那条路）⇒ 本页是那个 nav 的 root，自备「关闭」；
//  - `isModal: false`（会话页那条兜底路）⇒ 被 push 进导航栈，交系统返回键。
//  ⚠️ 抽屉**不关**（就地模态）—— 关掉设置回到的应该是还开着的抽屉，见 `AIMenuViewController.presentSettings`。
//

import UIKit
import SnapKit
import AICore

final class AISettingsViewController: UIViewController {

    // MARK: - 入口方式

    /// 见文件头「入口方式决定左上角」。
    private let isModal: Bool

    // MARK: - 分组 / 行

    /// 本页的功能入口（= 「功能」组那几行 + 第一组三行 + 关于）。
    ///
    /// ⚠️ 顺序就是屏上顺序（分组由 `sections` 决定，这里只是把 `Row` 的名字列齐）。
    private enum Row: CaseIterable {
        /// 语言（右侧显示当前档）—— macOS 惯例里语言属于「通用」，iOS 跟随同一分组
        case language
        /// 外观（浅色 / 深色 / 跟随系统）
        case appearance
        /// 字体大小（14 / 16 / 18 / 20 四档，默认第 2 档）
        case fontSize
        /// 自定义模型 → 清单页（本轮之前设置窗的本体）
        case models
        /// 通知设置 →「通知设置」二级页（2026-10-18 加：桌面通知总闸 / 提示音 / 内容预览）
        case notifications
        /// 指令（系统提示词）→「指令」二级页（2026-10-20 加：预设 chips + 自动保存）
        case instruction
        /// 生成参数 →「生成参数」二级页（2026-10-20 加：采样 slider + 思考展示开关）
        case generation
        /// 长期记忆 →「长期记忆」二级页（2026-10-25 加：总开关 + 逐条管理 + 手动添加）
        case memory
        /// 关于 Aster
        case about

        var title: String {
            switch self {
            case .language:     return L("语言")
            case .appearance:   return L("外观")
            case .fontSize:     return L("字体大小")
            case .models:       return L("模型")
            case .notifications: return L("通知")
            case .instruction:  return L("指令")
            case .generation:   return L("生成参数")
            case .memory:       return L("长期记忆")
            case .about:        return L("关于 Aster")
            }
        }

        /// 行首图标。⚠️ 与 Mac 侧不必逐字同款，但同一件事尽量挑同一个符号
        ///（「外观」两端都是 `circle.lefthalf.filled`，「模型」两端都是 `cpu`）。
        var icon: String {
            switch self {
            case .language:     return "globe"
            case .appearance:   return "circle.lefthalf.filled"
            case .fontSize:     return "textformat"
            case .models:       return "cpu"
            case .notifications: return "bell.badge"
            case .instruction:  return "text.quote"
            case .generation:   return "slider.horizontal.3"
            // 「大脑侧影」= 记住（与 Mac 侧设置窗「记忆」分页同一个符号）
            case .memory:       return "brain.head.profile"
            case .about:        return "info.circle"
            }
        }
    }

    private struct Section {
        /// 组标题。`nil` = 不画（第一组用它 —— 导航栏标题「设置」就在正上方，再写一遍就是两个「设置」）。
        let header: String?
        let rows: [Row]
    }

    /// 🔴 **计算属性**（⛔ 不是 `static let`）—— 见文件头。
    /// 📌 2026-10-28：用户要求「把通知移动到第一组，与语言、外观、字体一组」⇒「通知」从「功能」组
    ///    上移到第一组末尾。理由：那三项都是**这台设备的显示/提醒偏好**，通知同属这类；
    ///    「功能」组留给真正会改 AI 行为的开关（模型 / 指令 / 生成参数 / 长期记忆）。
    private var sections: [Section] {
        [
            Section(header: nil, rows: [.language, .appearance, .fontSize, .notifications]),
            Section(header: L("功能"), rows: [.models, .instruction, .generation, .memory]),
            Section(header: L("关于"), rows: [.about]),
        ]
    }

    // MARK: - UI

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.backgroundColor = .systemGroupedBackground
        tv.dataSource = self
        tv.delegate = self
        tv.rowHeight = 52
        tv.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        return tv
    }()

    private static let cellID = "AISettingsCell"

    #if DEBUG
    /// 🧪 验收钩子的一次性闩（本体见文件末尾那段）。
    /// ⚠️ 存储属性**必须**声明在类体里（extension 里放不了）—— 钩子的方法体在 extension 里。
    private var didAutoOpenSubPage = false
    #endif

    // MARK: - 生命周期

    init(isModal: Bool = false) {
        self.isModal = isModal
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("设置")
        view.backgroundColor = .systemGroupedBackground
        // push 时**不设** leftBarButtonItem：设了会把系统返回键顶掉
        if isModal {
            navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close,
                                                               target: self,
                                                               action: #selector(closeTapped))
        }
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从子页返回时把「当前档」刷新一遍（见文件头那条）。
        // ⚠️ 组标题也跟着重读（切语言是整棵界面重建，走不到这里；但重进本页时它必须准）。
        tableView.reloadData()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        openSubPageIfRequested()
        #endif
    }

    // MARK: - 布局

    private func setupUI() {
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    // MARK: - 动作

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    /// 打开某个子页（四个入口**唯一**的跳转点）。
    ///
    /// 🔴 单点：`didSelectRowAt` 与本页的验收钩子都走这里 ——
    ///    分两份写，将来改呈现方式一定只改一处（与 `presentSettings` 同款理由）。
    private func open(_ row: Row) {
        switch row {
        case .language:
            push(AIChoiceListViewController(kind: .language))
        case .appearance:
            push(AIChoiceListViewController(kind: .appearance))
        case .fontSize:
            push(AIChoiceListViewController(kind: .fontSize))
        case .models:
            // ⚠️ 清单页在这里是**被 push 的**（nav 的 root 是本页）⇒ 左上角交系统返回键
            //    （它那边那个 `isModal` 开关 2026-10-14 已删，见 `AICustomModelListViewController` 文件头）。
            push(AICustomModelListViewController())
        case .notifications:
            // 「通知设置」二级页（2026-10-18）：同样被 push，左上角系统返回键。
            push(AINotificationSettingsViewController())
        case .instruction:
            // 「指令」二级页（2026-10-20）：系统提示词编辑。
            push(AIInstructionSettingsViewController())
        case .generation:
            // 「生成参数」二级页（2026-10-20）：采样参数 + 思考展示开关。
            push(AIGenerationSettingsViewController())
        case .memory:
            // 「长期记忆」二级页（2026-10-25）：总开关 + 逐条列表 + 手动添加。
            push(AIMemorySettingsViewController())
        case .about:
            push(AIAboutViewController())
        }
    }

    /// push 一个子页；拿不到导航栈时（极少数宿主不给 stack）退化成模态。
    private func push(_ page: UIViewController) {
        guard let nav = navigationController else {
            present(UINavigationController(rootViewController: page), animated: true)
            return
        }
        nav.pushViewController(page, animated: true)
    }

    // MARK: - 行内容

    /// 一行的配置（图标 / 标题 / 右侧当前值）。
    ///
    /// ⚠️ 「当前值」**每次建 cell 现读**存取点，不缓存 —— 缓存只会在用户刚改过之后给出旧值。
    private func configure(_ cell: UITableViewCell, with row: Row) {
        var config = UIListContentConfiguration.valueCell()
        config.text = row.title
        config.image = UIImage(systemName: row.icon)
        config.imageProperties.tintColor = .label
        config.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17)
        // 🔴 字号走 `AIChromeFont`（2026-10-22 接字号档位）。这里**显式钉**文本样式
        //    （`.body` / `.subheadline`）而不是让配置吃系统默认：默认值不随档位走，
        //    本页就会是「半生效」——正是这一轮要消灭的东西（见 `AIChromeFont` 文件头）。
        config.textProperties.font = AIChromeFont.ui(.body)
        config.secondaryTextProperties.font = AIChromeFont.ui(.subheadline)
        switch row {
        case .language:   config.secondaryText = AILanguageStore.current.title
        case .appearance: config.secondaryText = AIAppearanceStore.current.title
        case .fontSize:   config.secondaryText = AIFontSizeStore.current.title
        case .models, .notifications, .instruction, .generation, .about: config.secondaryText = nil
        // 记忆行右侧显示条数（0 条不显示 —— 与「通知」那些行一样留空，不制造噪音）。
        // ⚠️ 现读 `AIMemoryStore.count`：从记忆页删完几条回来，这个数必须是新的
        //    （`viewWillAppear` 的 reloadData 会重建 cell ⇒ 走的就是这条现读）。
        case .memory: config.secondaryText = AIMemoryStore.count > 0
            ? String(format: L("%d 条记忆"), AIMemoryStore.count)
            : nil
        }
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        cell.backgroundColor = .secondarySystemGroupedBackground
    }
}

// MARK: - 列表数据源

extension AISettingsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].header
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].rows.indices.contains(indexPath.row) else { return cell }
        configure(cell, with: sections[indexPath.section].rows[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].rows.indices.contains(indexPath.row) else { return }
        open(sections[indexPath.section].rows[indexPath.row])
    }
}

// MARK: - 🧪 验收钩子（`STARRY_SETTINGS_UI=lang|appearance|about|notify|list|form|provider|model|draft|draft-discard`）
//
// ## 为什么非有它不可
// 本页在导航栈第二层（会话页 → 设置页），四个子页在**第三层**，而模拟器
// **投不出合成触摸**（`xcrun simctl` 不提供 tap）⇒ 不替用户点一下，
// 「设置页长什么样、四个子页各自长什么样」agent 侧一张图都拿不到
//（`typecheck_aster.sh` 那几条契约只证得了「代码在、次序对」）。
//
// ## 三个约束（逐条照抄通话页 / 表单页那两个钩子的）
// 1. **只在 `#if DEBUG` 下编译进去** —— Release 包里这段代码根本不存在；
// 2. **只触发一次**（闩在 `didAutoOpenSubPage`）—— 否则从子页返回会又被推进去；
// 3. 走的是**和点这一行完全相同的那条路**（`open(_:)`），⛔ 别另写一条只 push 的捷径。
//
// ⚠️ 「再往里一层」的两档（`form` / `provider` / `model`）由**下游**各自认领：
//    本页只负责把「自定义模型」清单页推出来，剩下的见清单页 / 表单页自己的钩子。

#if DEBUG
extension AISettingsViewController {

    /// `STARRY_SETTINGS_UI` 里那几档「从本页往下推」的取值。
    ///
    /// ⚠️ `"1"` / 空串 ⇒ 停在本页（默认档就是「看设置页本身」）。
    func openSubPageIfRequested() {
        guard !didAutoOpenSubPage else { return }
        switch ProcessInfo.processInfo.environment["STARRY_SETTINGS_UI"] ?? "" {
        case "lang":       didAutoOpenSubPage = true; autoPush { $0.open(.language) }
        case "appearance": didAutoOpenSubPage = true; autoPush { $0.open(.appearance) }
        case "fontsize":   didAutoOpenSubPage = true; autoPush { $0.open(.fontSize) }
        case "notify":
            // 通知设置页是导航链终点（2026-10-19 起没有子页了 —— 提示音三档已删），
            // 本页推出来即止，⛔ 不存在也不许再回来「notify-sound」这个档。
            didAutoOpenSubPage = true; autoPush { $0.open(.notifications) }
        case "about":      didAutoOpenSubPage = true; autoPush { $0.open(.about) }
        case "memory":
            // 「长期记忆」页（2026-10-25）：同样被 push 出来即止（它没有子页）。
            didAutoOpenSubPage = true; autoPush { $0.open(.memory) }
        case "instruction":
            // 「指令」页（2026-10-27 加）：出图用来确认**全局**这一份**不显示**
            // 「与全局指令叠加使用」那句（它是自指）。项目级那一份要注入读写口，
            // 走的是项目详情页那条真实路径 ⇒ 这里没有对应档位（⛔ 别为截图在钩子里
            // 伪造 instructionProvider —— 那验的就不是用户走的那条路）。
            didAutoOpenSubPage = true; autoPush { $0.open(.instruction) }
        // 「清单页及更深」那几档都要先经过清单页（层级：设置 → 清单 → 表单 → 选择页）
        case "list", "form", "provider", "model", "draft", "draft-discard":
            didAutoOpenSubPage = true
            autoPush { $0.open(.models) }
        default: break
        }
    }

    /// 等这一帧画完再推（直接在 `viewDidAppear` 里 push 会截到半透明残影 —— 与通话页那条同源）。
    private func autoPush(_ work: @escaping (AISettingsViewController) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            work(self)
        }
    }

    /// 给切语言探针用的真实入口：推「语言」那一页（本体就是 `open(_:)`）。
    /// ⛔ 探针里**绝不许**直接写 `AILanguageStore.current`：那条不是用户走的路。
    func debugOpenLanguagePage() { open(.language) }
}
#endif
