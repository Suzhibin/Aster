//
//  AINotificationSettingsViewController.swift
//  Aster
//
//  「通知设置」页（iOS，2026-10-18 新建）—— 形态参照 Mac 的「通知」分页
//  （`MacNotificationSettingsView`），但**刻意不同形态**：macOS 设置窗是「左菜单 + 右分页」，
//  iOS 是「分组表 + 点进子页」（`UITableView(.insetGrouped)`，本工程一贯口径，
//  见 `AISettingsViewController` 文件头）。
//
//  ## 页面层级里的位置
//      侧滑菜单 / 账号弹窗「设置」→ 设置页（`AISettingsViewController`）
//            ↓
//      **本页**（被 push 进那个模态 nav；左上角交系统返回键）
//  ⚠️ 2026-10-19 起本页**不再有子页**（提示音三档删除）—— 它是导航链的终点。
//
//  ## 两行各管什么（2026-10-19 改版：提示音删除，「前往系统设置」并入第一行）
//  ① **桌面通知**（UISwitch）—— **智能行**，行为跟着系统授权状态走：
//     · 系统**开着** ⇒ 这一行就是总闸本体，拨动直接写 `AINotificationPreferences.isEnabled`；
//     · 系统**关着**（denied / notDetermined）⇒ 开关**跟着关**（置灰拨不动 ——
//       系统关着时通知本就发不出去，留着能拨的开关是骗人的），
//       **点这一行** ⇒ `openNotificationSettings()` 去系统设置开权限。
//     ⚠️ 参考图（飞书）这一行没有开关、只给「前往系统设置」：它把权限整个交给系统。
//     我们的通知是 App 内功能，没开关用户就得跑去系统设置才能闭嘴 ⇒ 总闸与
//     系统引导合成这一行（用户 2026-10-19 原话：「如果系统关闭，第一项也关闭，
//     点击去系统设置；如果系统开启，点击第一项直接开启」）。
//  ② **显示内容预览**（UISwitch）：关掉后通知不透露会话标题 / 错误原因（锁屏防窥）。
//
//  ## 🔴 分组表写在**计算属性**里（⛔ 不是 `static let`）
//  与 `AISettingsViewController` 同一条铁律：切语言后重建界面要拿到新文案。
//
//  ## 🔴 UISwitch 挂 `contentView`、**绝不用 `accessoryView`**
//  `AIChoiceListViewController` 那颗勾的教训（2026-10-14 实测）：走 cell 的 accessory
//  机制，`alpha` / 状态在系统配置更新流程里**留不住**。自绘子视图挂 `contentView`
//  是那条「已被验证的路」—— 开关同理（`isOn` 每次 configure 重设 + 先摘旧 target
//  再挂新的，防 target-action 重复叠加）。
//  ⚠️ 开关是**身份令牌子类**（`AINotifySwitchView`）：cell 复用后要在
//    `contentView.subviews` 里认出它来，`tag` 会撞车（与勾同一个理由）。
//
//  ## ⚠️ 授权状态每次 `viewWillAppear` 重读
// 用户可能刚去系统设置改完权限回来（`openNotificationSettings` 落在 App 设置页，
// 返回时 `viewWillAppear` 必然触发）⇒ 第一行的「智能」必须那时就翻过来。
//  存取点不是可观察的，写它不会让本页重算 —— 所以 reload 也在这一个方法里。

import UIKit
import SnapKit
import AICore
// 🔴 `AIPlatform.system.openNotificationSettings()` 在 AIPlatform 模块 ——
//    本工程 `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`：用谁的 API 就得显式 import 谁。
import AIPlatform

final class AINotificationSettingsViewController: UIViewController {

    // MARK: - 行

    /// 本页两行。⚠️ 顺序就是屏上顺序。
    private enum Row: CaseIterable {
        /// 桌面通知总闸（UISwitch；系统关时置灰 + 点行跳系统设置，见文件头）
        case desktop
        /// 显示内容预览（UISwitch）
        case preview

        var title: String {
            switch self {
            case .desktop: return L("桌面通知")
            case .preview: return L("显示内容预览")
            }
        }

        /// 行下那行灰色小字（系统关时第一行会被换成引导语，见 `configure`）。
        var detail: String {
            switch self {
            case .desktop: return L("任务完成，将会通过系统弹窗提醒你。")
            case .preview: return L("在通知中显示你发送的消息内容。")
            }
        }

        var icon: String {
            switch self {
            case .desktop: return "app.badge"
            case .preview: return "text.bubble"
            }
        }
    }

    // MARK: - 状态

    /// 系统授权状态。异步查、`viewWillAppear` 刷新；第一行的「智能」全看它。
    /// 初值给 `.authorized` = **不误导**（没查到之前别把开关置灰）。
    private var authorization: AINotificationAuthorization = .authorized

    /// 系统通知**关着**（denied / notDetermined 都算 —— 没问过 = 现在也发不出去）。
    private var isSystemOff: Bool { authorization != .authorized }

    // MARK: - UI

    private static let cellID = "AINotifySettingsCell"

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.backgroundColor = .systemGroupedBackground
        tv.dataSource = self
        tv.delegate = self
        // 副标题两行 + 标题一行 ≈ 20+30，加默认上下内边距（16×2）⇒ 88 才放得下两行整句。
        // ⚠️ 66 实测会被按单行截断（配置布局按行高收榨 ⇒ 出现「…App ...」的截断尾）；
        //    88 之后两行完整显示。⛔ 别为了「矮一点」砍回 66 —— 截断的说明等于没有说明。
        tv.rowHeight = 88
        tv.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        return tv
    }()

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("通知")
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in make.edges.equalToSuperview() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 授权状态刷新（见文件头那条）—— 从系统设置改完权限回来时靠它翻面。
        refreshAuthorization()
        tableView.reloadData()
    }

    // MARK: - 授权状态

    private func refreshAuthorization() {
        // ⚠️ UN 的完成处理器**不保证主线程** ⇒ 自己跳回来再 reload
        //    （UIKit 的 reload 在后台线程调是未定义行为）。
        AINotificationPreferences.authorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorization = status
                self.tableView.reloadData()
            }
        }
    }

    // MARK: - 行内容

    /// 一行的配置。
    ///
    /// ⚠️ 「当前值」**每次建 cell 现读**存取点，不缓存（与设置页同一口径）：
    ///    缓存只会在用户刚改过之后给出旧值。
    private func configure(_ cell: UITableViewCell, with row: Row) {
        // 复用的 cell 先清干净：accessory 不设、旧开关的 target 摘掉、**非开关行必须藏**
        // （☠️ 不藏的后果实测过：cell 复用会把一行的开关漏到别的行上 ——
        //  与 `aiApplyCheckmark` 那条「恒占位、只翻 alpha」是同一条教训的变体）。
        cell.accessoryView = nil
        cell.accessoryType = .none
        let isSwitchRow = true   // 本页两行都是开关行（保留判据：将来加非开关行时别忘了藏）
        if let old = cell.contentView.subviews.first(where: { $0 is AINotifySwitchView }) as? AINotifySwitchView {
            old.removeTarget(nil, action: nil, for: .allEvents)
            old.alpha = isSwitchRow ? 1 : 0
        }

        var config = UIListContentConfiguration.valueCell()
        config.text = row.title
        config.image = UIImage(systemName: row.icon)
        config.imageProperties.tintColor = .label
        config.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17)
        // 🔴 第一行的副标题跟着系统状态走：关着时换成「轻点前往系统设置」引导语
        //    （同时解释开关为什么是灰的）；开着时是常规说明。
        config.secondaryText = (row == .desktop && isSystemOff)
            ? L("系统通知已关闭，轻点前往系统设置")
            : row.detail
        config.secondaryTextProperties.color = .secondaryLabel
        config.secondaryTextProperties.font = AIChromeFont.ui(.footnote)
        // 🔴 副标题**允许多行**：不设的话 `valueCell` 默认按单行截断
        //    （「在通知中显示你发送的消息内容。」会被砍成半句）。
        config.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = config
        cell.backgroundColor = .secondarySystemGroupedBackground

        // 开关行：正文右侧给开关让位（与勾的 `aiCheckmarkReserve` 成对，宽度同值）。
        config.directionalLayoutMargins.trailing = AINotificationSettingsViewController.switchReserve
        cell.contentConfiguration = config
        cell.aiApplyNotifySwitch(
            // 🔴 第一行「系统关 ⇒ 跟着关」：置 `false` + 置灰（`enabled: false`）。
            //    系统开着时才是 App 内总闸的真实值。
            on: row == .desktop
                ? (!isSystemOff && AINotificationPreferences.isEnabled)
                : AINotificationPreferences.showsPreview,
            enabled: row == .preview || !isSystemOff) { on in
            // 🔴 只写存取点（共享层唯一入口）—— UserDefaults 落盘，
            //    `AIReplyNotifier.post` 现读 ⇒ 下一条通知即生效。
            // ⚠️ 闭包**不捕 self**（开关回调不该把 VC 拖进 retain cycle；
            //    这里也本来就不需要 VC 出场）。
            if row == .desktop {
                AINotificationPreferences.isEnabled = on
            } else {
                AINotificationPreferences.showsPreview = on
            }
        }
    }

    /// 正文右侧给开关让位的留白宽度 —— **唯一常量**（与 `aiApplyNotifySwitch` 成对）。
    /// 构成：开关 51pt 宽 + 距右 16pt（比勾那 40 宽一截，UISwitch 本来就比勾大）。
    /// ⚠️ **刻意 `internal`**：长期记忆页复用（见 `AINotifySwitchView` 的文档）。
    static let switchReserve: CGFloat = 51 + 16
}

// MARK: - 列表数据源

extension AINotificationSettingsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        guard Row.allCases.indices.contains(indexPath.row) else { return cell }
        configure(cell, with: Row.allCases[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Row.allCases.indices.contains(indexPath.row) else { return }
        let row = Row.allCases[indexPath.row]
        // 🔴 系统关着时，第一行整行 = 「前往系统设置」的入口（开关已置灰拨不动，
        //    副标题也写着「轻点前往系统设置」）—— 用户 2026-10-19 的原话：
        //    「点击去系统设置」。系统开着时第一行就是开关本体，点行不做事
        //    （拨动走开关自己的 target-action，⛔ 别给整行挂点击 —— 会误触）。
        if row == .desktop, isSystemOff {
            // 🔴 平台差异全在接缝里（iOS → App 设置页；macOS → 通知面板）。
            //    ⛔ 别在这里 `#if os(iOS)` 自己拼 `openSettingsURLString`。
            AIPlatform.system.openNotificationSettings()
        }
    }
}

// MARK: - 行内那颗开关

/// 开关视图的**身份令牌**：`UISwitch` 私有子类。
///
/// ⚠️ **刻意 `internal`（不是 private）**：长期记忆页（`AIMemorySettingsViewController`，
/// 2026-10-25）复用它 + 下面的 `aiApplyNotifySwitch` / `switchReserve` ——
/// 同一份「挂 contentView 的开关」实现⛔ 别抄第二遍（抄了就是两处约束各自漂移）。
///
/// 两个职责（都只为「在 `contentView.subviews` 里认出来」这个身份服务）：
/// ① 子类本身 = 令牌（⛔ 不用 `tag`：数字撞车是**静默** bug，与勾同一个理由）；
/// ② 回调挂在**自己身上**（⛔ 别让调用方 VC 当 target：UIControl 会强持有 target，
///    cell 比 VC 活得久的话就是一条隐式 retain cycle）。
final class AINotifySwitchView: UISwitch {

    /// 值变回调。`configure` 每次重设（跟着 cell 复用一起换）。
    var onChange: ((Bool) -> Void)?

    /// 值变的**唯一**出口。`@objc` 天然 nonisolated（Swift 5 并发下 selector 方法
    /// 不参与 actor 隔离检查），且 UIKit 控件事件本就在主线程。
    @objc private func valueChanged() {
        onChange?(isOn)
    }

    /// 挂 / 换回调。**幂等**：重复调用不会叠加 target-action
    /// （`removeTarget` 先摘，与 `configure` 里「先摘旧 target」是同一件事的两端）。
    func bind(_ onChange: @escaping (Bool) -> Void) {
        removeTarget(self, action: #selector(valueChanged), for: .valueChanged)
        self.onChange = onChange
        addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    }
}

extension UITableViewCell {

    /// 列表行右侧那颗「挂在 `contentView` 里」的开关。
    ///
    /// ## 为什么不放 `accessoryView`
    /// `AIChoiceListViewController` 那颗勾的实测教训（2026-10-14）：走 cell 的
    /// accessory 机制，系统在配置更新流程里会**重置**我们设的状态。挂在 `contentView`
    /// 上的自定义子视图系统不动 ⇒ 状态留得住。
    ///
    /// ## ⚠️ 三条配套约束
    /// ① **正文必须让出右侧那截宽度**（`switchReserve`），否则长文案会被开关压住；
    /// ② **恒存在、只翻 `isOn` / `alpha`**（⛔ 别写成 `on ? addSubview : removeFromSuperview`）——
    ///    加/删的时机与 cell 复用纠缠不清。**非开关行必须 `alpha = 0`**（cell 复用会把
    ///    上一行的开关带到下一行，2026-10-18 实测漏到过两行上）；
    /// ③ 回调走 `bind(_:)`（幂等，不会叠加 target-action）。
    ///
    /// ## `enabled: false` 用在哪
    /// 通知设置页第一行「系统通知关着」时：开关置灰（拨不动）+ 点整行跳系统设置
    /// （2026-10-19，用户要求「系统关闭，第一项也关闭，点击去系统设置」）。
    func aiApplyNotifySwitch(on: Bool, enabled: Bool = true, onChange: @escaping (Bool) -> Void) {
        let toggle: AINotifySwitchView
        if let existing = contentView.subviews.first(where: { $0 is AINotifySwitchView }) as? AINotifySwitchView {
            toggle = existing
        } else {
            toggle = AINotifySwitchView()
            toggle.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(toggle)
            NSLayoutConstraint.activate([
                toggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                toggle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            ])
        }
        toggle.isOn = on
        toggle.isEnabled = enabled
        toggle.alpha = 1   // 开关行恒显（非开关行由 configure 翻 0，见那条注释）
        toggle.bind(onChange)
    }
}
