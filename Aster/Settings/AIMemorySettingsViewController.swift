//
//  AIMemorySettingsViewController.swift
//  Aster
//
//  「长期记忆」页（iOS，2026-10-25 新建）—— 形态参照 Mac 的「记忆」分页
//  （`MacMemorySettingsView`），但**刻意不同形态**：macOS 设置窗是「左菜单 + 右分页」，
//  iOS 是「分组表 + 点进子页」（`UITableView(.insetGrouped)`，见 `AISettingsViewController` 文件头）。
//
//  ## 页面层级里的位置
//      设置页（`AISettingsViewController`，「功能」组）
//            ↓
//      **本页**（被 push；左上角交系统返回键）—— 导航链终点，无子页。
//
//  ## 三块内容
//  ① **两个开关**（各一个 UISwitch）：「自动记忆」（`isAutoExtractEnabled`，默认**关**）=
//     每轮对话后模型自动提取；「回答时参考」（`isEnabled`，默认开）= 拼不拼进 system
//     消息。副标题各随自己的开关状态换文案。**没有任何「添加」入口** —— 上线当天的
//     手动写点（右上角添加 / 长按「记住这条」）当天即被用户拍板移除（与豆包对齐成纯自动）。
//  ② **清除全部**（红字行，仅在有记忆时出现）—— 二次确认后 `clearAll()`。
//  ③ **记忆列表**（新的在前）：正文 + 创建时间，**左滑删除**（ destructive swipe，
//     再过一次 `UIAlertController` 确认——删除不可恢复，与 `AICustomModelListViewController
//     .confirmDelete` 同一条纪律）；空列表给一行引导（引导去开上面的「自动记忆」）。
//
//  ## 🔴 四个别踩的
//  1. **开关挂 `contentView`、⛔ 不用 `accessoryView`** —— 直接复用
//     `AINotificationSettingsViewController` 里那个 `aiApplyNotifySwitch`（同一 module，
//     那条「accessory 会被系统重置」的教训见那边文件头，2026-10-14 实测）。
//  2. **每次 `viewWillAppear` 重读**（`AIMemoryStore.reload()` + reloadData）——
//     用户可能刚在「文件」App 里手改过 `memories.json`，也可能刚在聊天页「记住了一条」
//     再返回来（本页是 push 出来的，返回时 `viewWillAppear` 必然触发）。
//  3. **分组表 / 行集是计算属性或现算**（⛔ `static let`）—— 切语言后重建要拿到新文案，
//     与 `AISettingsViewController` 同一条铁律。
//  4. **条数 / 空态都现算**（`AIMemoryStore.count` / `all()`）—— 存取点不是可观察的，
//     缓存只会在用户刚增删之后给出旧值。
//

import UIKit
import SnapKit
import AICore

final class AIMemorySettingsViewController: UIViewController {

    // MARK: - 第一组的行（开关 + 清除全部）

    /// ⚠️ 顺序就是屏上顺序。「清除全部」是**条件行**（有记忆才出现）——
    ///    由 `topRows` 现算，⛔ 别写成静态数组。
    private enum TopRow: CaseIterable {
        /// 「自动记忆」（抽取侧，UISwitch，默认关）
        case autoExtract
        /// 「回答时参考」（注入侧，UISwitch，默认开）
        case inject
        /// 清除全部记忆（红字；仅 `count > 0` 时出现）
        case clearAll

        var title: String {
            switch self {
            case .autoExtract: return L("自动记忆")
            case .inject:     return L("回答时参考")
            case .clearAll:   return L("清除全部记忆")
            }
        }

        var icon: String {
            switch self {
            case .autoExtract: return "brain.head.profile"
            case .inject:     return "text.bubble"
            case .clearAll:   return "trash"
            }
        }

        /// 是不是开关行（两行共用一套「开关挂 contentView」的布线，见 `configure`）。
        var isToggle: Bool {
            switch self {
            case .autoExtract, .inject: return true
            case .clearAll:             return false
            }
        }
    }

    /// 第一组实际显示的行（「清除全部」有条件）。
    private var topRows: [TopRow] {
        AIMemoryStore.count > 0 ? TopRow.allCases : [.autoExtract, .inject]
    }

    // MARK: - UI

    private static let cellID = "AIMemorySettingsCell"

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.backgroundColor = .systemGroupedBackground
        tv.dataSource = self
        tv.delegate = self
        // 副标题两行 + 标题一行 ≈ 20+30，加默认上下内边距 ⇒ 88 才放得下（与通知页同一实测结论）
        tv.rowHeight = 88
        tv.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        return tv
    }()

    /// 时间行的格式（`MM-dd HH:mm`）。🔴 **static let**：`DateFormatter` 创建代价高，
    ///     而它不含任何随语言变的文案（月份数字是区域格式，跟着 locale 走，安全）。
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("长期记忆")
        view.backgroundColor = .systemGroupedBackground
        // ⛔ 没有右上角「添加」：2026-10-25 记忆反转成模型自动抽取，添加入口按
        //    用户拍板移除（与豆包对齐）—— 添加只有一个输入框却要用户自己想
        //    「该写什么」，那是纯手动时代的产物。
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in make.edges.equalToSuperview() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 手改文件 / 抽取器刚写进一条，都可能让盘上的内容变了 ⇒ 先重读再重建
        // （reload 内部有 mtime 闩，没变就是一次 stat，热路径无感）
        AIMemoryStore.reload()
        tableView.reloadData()
    }

    // MARK: - 动作

    private func confirmDelete(_ item: AIMemoryItem) {
        let alert = UIAlertController(title: L("删除这条记忆？"),
                                      message: item.content,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { _ in
            AIMemoryStore.delete(id: item.id)
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func confirmClearAll() {
        let alert = UIAlertController(title: L("清除全部记忆？"),
                                      message: L("此操作不可恢复。"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("清除"), style: .destructive) { _ in
            AIMemoryStore.clearAll()
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    // MARK: - 行内容

    private func configure(_ cell: UITableViewCell, with row: TopRow) {
        // 复用先摘旧开关（与通知页同一纪律：target 叠加 = 拨一下改两行）
        if let old = cell.contentView.subviews.first(where: { $0 is AINotifySwitchView }) as? AINotifySwitchView {
            old.removeTarget(nil, action: nil, for: .allEvents)
            old.alpha = row.isToggle ? 1 : 0
        }
        var config = UIListContentConfiguration.valueCell()
        config.text = row.title
        config.image = UIImage(systemName: row.icon)
        config.imageProperties.tintColor = row == .clearAll ? .systemRed : .label
        config.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17)
        config.textProperties.font = AIChromeFont.ui(.body)
        config.secondaryTextProperties.font = AIChromeFont.ui(.footnote)
        config.secondaryTextProperties.numberOfLines = 0
        switch row {
        case .autoExtract:
            // 副标题跟着开关状态走（两条文案与 Mac 页**同一份词条**，⛔ 别另写）
            config.secondaryText = AIMemoryStore.isAutoExtractEnabled
                ? L("每轮对话后自动提取值得记住的信息")
                : L("开启后每轮对话会多一次模型调用")
        case .inject:
            // 副标题跟着开关状态走：开着说「会参考」，关着说「不再参考、但保留」
            config.secondaryText = AIMemoryStore.isEnabled
                ? L("开启后，助手会在回答时参考这些记忆")
                : L("关闭后不再参考；已保存的记忆仍会保留。")
        case .clearAll:
            config.secondaryText = nil
        }
        // 红字行的标题也染红（与图标一致；副标题没有，不制造双红）
        if row == .clearAll { config.textProperties.color = .systemRed }
        cell.contentConfiguration = config
        cell.backgroundColor = .secondarySystemGroupedBackground

        if row.isToggle {
            // 正文给开关让位（宽度常量与 `aiApplyNotifySwitch` 成对，见通知页）
            config.directionalLayoutMargins.trailing = AINotificationSettingsViewController.switchReserve
            cell.contentConfiguration = config
            // 🔴 只写存取点（共享层唯一入口）；列表 / 副标题由 viewWillAppear 兜底刷新
            cell.aiApplyNotifySwitch(on: row == .autoExtract
                                        ? AIMemoryStore.isAutoExtractEnabled
                                        : AIMemoryStore.isEnabled) { on in
                if row == .autoExtract {
                    AIMemoryStore.isAutoExtractEnabled = on
                } else {
                    AIMemoryStore.isEnabled = on
                }
            }
        }
    }

    /// 记忆列表行（第 2 组）：正文 + 时间。
    private func configure(_ cell: UITableViewCell, with item: AIMemoryItem) {
        var config = UIListContentConfiguration.valueCell()
        config.text = item.content
        config.textProperties.font = AIChromeFont.ui(.body)
        config.textProperties.numberOfLines = 0   // 记忆可能很长，⛔ 别截断
        config.secondaryText = Self.timeFormatter.string(from: item.createdAt)
        config.secondaryTextProperties.font = AIChromeFont.ui(.footnote)
        config.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = config
        cell.backgroundColor = .secondarySystemGroupedBackground
    }

    /// 空列表那一行（第 2 组、零记忆时）：引导 + 文件位置。
    private func configureEmpty(_ cell: UITableViewCell) {
        var config = UIListContentConfiguration.valueCell()
        config.text = L("还没有记忆。开启上面的「自动记忆」，助手会在每轮对话中记住你的事，可在这里查看和删除。")
        config.textProperties.font = AIChromeFont.ui(.body)
        config.textProperties.color = .secondaryLabel
        config.textProperties.numberOfLines = 0
        cell.contentConfiguration = config
        cell.backgroundColor = .secondarySystemGroupedBackground
    }

    /// 组尾文字（第 2 组）：文件位置；盘上手改坏了 JSON 时换成错误提示
    /// （⛔ 别静默显示空列表 —— 那会诱导用户以为记忆全丢了，见 `AIMemoryStore.lastLoadError`）。
    private func footerText() -> String? {
        if let error = AIMemoryStore.lastLoadError {
            return String(format: L("记忆文件读取失败：%@。显示的是上次的内容，请检查文件格式。"), error)
        }
        return String(format: L("保存在 %@，可在「文件」App 中查看。"), AIMemoryStore.shortDisplayPath)
    }
}

// MARK: - 列表数据源

extension AIMemorySettingsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? topRows.count : max(AIMemoryStore.count, 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        if indexPath.section == 0 {
            guard topRows.indices.contains(indexPath.row) else { return cell }
            configure(cell, with: topRows[indexPath.row])
        } else {
            let items = AIMemoryStore.all()
            guard items.indices.contains(indexPath.row) else {
                // count == 0 的空态行（numberOfRows 已给 1 保底）
                configureEmpty(cell)
                return cell
            }
            configure(cell, with: items[indexPath.row])
        }
        return cell
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? footerText() : nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0, topRows.indices.contains(indexPath.row) else { return }
        // 只有「清除全部」可点（开关行拨动走开关自己的 target-action，
        // ⛔ 别给整行挂点击 —— 会误触，与通知页第一行同一条纪律）
        if topRows[indexPath.row] == .clearAll { confirmClearAll() }
    }

    /// 第 2 组左滑删除（系统原生 swipe + 二次确认 —— 删除不可恢复）。
    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 1, AIMemoryStore.count > 0 else { return nil }
        let items = AIMemoryStore.all()
        guard items.indices.contains(indexPath.row) else { return nil }
        let item = items[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: L("删除")) { [weak self] _, _, done in
            // ⚠️ swipe 只负责「发起确认」，真正删除在 alert 的 destructive 里
            //    （不可恢复的操作必须再过一次确认，与 confirmDelete 同一纪律）
            self?.confirmDelete(item)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
}
