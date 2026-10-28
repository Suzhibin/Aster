//
//  AIGenerationSettingsViewController.swift
//  Aster
//
//  「生成参数」页（iOS，2026-10-20 新建）—— 采样参数 + 思考过程展示开关。
//
//  ## 页面层级里的位置
//      设置页（`AISettingsViewController`）组2「功能」
//            ↓
//      **本页**（被 push；左上角交系统返回键）
//  ⚠️ 本页是导航链的终点（没有子页）。
//
//  ## 两段各管什么
//  ① **采样**：温度 / 最大长度。每项一颗「自定义」开关 —— **关 = 请求不发这个字段、
//     用服务端默认**（默认态，见 `AIGenerationSettings` 文件头 🔴）；开 = 下面
//     长出 slider 行，值随拖随存。
//  ② **思考**：展示思考过程总闸（默认开）。关掉后聊天行不渲染思考块、
//     流式增量不落库（渲染判据是现读，见 `AIGenerationSettings.showsThinkingProcess`）。
//
//  ## 🔴 slider 行是**动态行**（开关驱动插入 / 删除）
//  为什么不是「slider 恒在、置灰」：置灰的 slider 是假控件 —— 看着能拖、拖了没反应，
//  比没有更糟。插入 / 删除走 `performBatchUpdates`，与「开关行刷新副标题」
//  （服务端默认 ⇄ 当前值）同一个 batch 里做。
//
//  ## 🔴 三条既有纪律的落点
//  ① 分组表 / 行集合是**计算属性**（⛔ 不是 static let）—— 切语言后重建要新文案；
//  ② 开关挂 `contentView`、**绝不用 accessoryView**（`AIChoiceListViewController`
//     那颗勾的实测教训：accessory 会被系统重置）⇒ 直接复用通知页那颗
//     `aiApplyNotifySwitch`（同一模块，token 子类认领，见那个文件头）；
//  ③ 「当前值」每次建 cell **现读**存取点，不缓存。
//

import UIKit
import SnapKit
import AICore

final class AIGenerationSettingsViewController: UIViewController {

    // MARK: - 行

    /// 全部可能的行（实际显示哪些由 `sections` 按开关态算，⛔ 别在渲染处写 if）。
    private enum Row: Int, CaseIterable {
        /// 温度开关行（右侧副标题：服务端默认 ⇄ 当前值）
        case temperature
        /// 温度 slider 行（仅 `temperatureEnabled` 时插入）
        case temperatureSlider
        /// 最大长度开关行
        case maxTokens
        /// 最大长度 slider 行（仅 `maxTokensEnabled` 时插入）
        case maxTokensSlider
        /// 展示思考过程开关行
        case showThinking

        var title: String {
            switch self {
            case .temperature, .temperatureSlider: return L("温度")
            case .maxTokens, .maxTokensSlider:       return L("最大长度")
            case .showThinking:                      return L("展示思考过程")
            }
        }
    }

    private enum Section: Int, CaseIterable {
        case sampling
        case thinking

        var header: String {
            switch self {
            case .sampling: return L("采样")
            case .thinking: return L("思考")
            }
        }
    }

    // MARK: - 动态行集合（计算属性）

    /// 采样段实际显示的行：开关行恒在，slider 行随开关插拔。
    private var samplingRows: [Row] {
        var rows: [Row] = [.temperature]
        if AIGenerationSettings.temperatureEnabled { rows.append(.temperatureSlider) }
        rows.append(.maxTokens)
        if AIGenerationSettings.maxTokensEnabled { rows.append(.maxTokensSlider) }
        return rows
    }

    private func rows(in section: Section) -> [Row] {
        switch section {
        case .sampling: return samplingRows
        case .thinking: return [.showThinking]
        }
    }

    private func indexPath(of row: Row) -> IndexPath? {
        for section in Section.allCases {
            if let index = rows(in: section).firstIndex(of: row) {
                return IndexPath(row: index, section: section.rawValue)
            }
        }
        return nil
    }

    // MARK: - UI

    private static let cellID = "AIGenerationCell"

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.backgroundColor = .systemGroupedBackground
        tv.dataSource = self
        tv.delegate = self
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 72
        tv.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        return tv
    }()

    /// slider 行的目标高度（标题 + slider 两行，比开关行高一截）。
    private static let sliderRowHeight: CGFloat = 96

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("生成参数")
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in make.edges.equalToSuperview() }
    }
}

// MARK: - 列表数据源

extension AIGenerationSettingsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows(in: Section(rawValue: section) ?? .sampling).count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        guard let row = Row(rawValue: rowValue(at: indexPath)) else { return cell }
        configure(cell, with: row)
        return cell
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.header
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        // slider 行高一些（标题 + 滑块两行）；开关行交给自动高度（副标题两行）。
        let row = Row(rawValue: rowValue(at: indexPath))
        return row == .temperatureSlider || row == .maxTokensSlider
            ? Self.sliderRowHeight
            : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    /// `IndexPath` → 稳定行号（行集合会随开关变，⛔ 别直接用 indexPath.row 索引）。
    private func rowValue(at indexPath: IndexPath) -> Int {
        // Row 的 rawValue 是**全量枚举序**，与屏上行号不同；这里反查：
        // 屏上行号 → rows(in:) 的第几个 → 它的 rawValue。
        guard let section = Section(rawValue: indexPath.section) else { return Row.temperature.rawValue }
        let rows = rows(in: section)
        guard rows.indices.contains(indexPath.row) else { return rows.first?.rawValue ?? Row.temperature.rawValue }
        return rows[indexPath.row].rawValue
    }
}

// MARK: - 行内容

extension AIGenerationSettingsViewController {

    private func configure(_ cell: UITableViewCell, with row: Row) {
        // 复用先清干净：旧 slider / 旧开关 target 一律摘（cell 复用会把上一行的
        // 控件漏到下一行 —— 通知页那颗开关的实测教训，滑块同理）。
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none
        cell.backgroundColor = .secondarySystemGroupedBackground

        switch row {
        case .temperature:
            configureToggleRow(cell, title: L("温度"),
                               value: AIGenerationSettings.temperatureEnabled
                                   ? String(format: "%.1f", AIGenerationSettings.temperature)
                                   : L("服务端默认"),
                               detail: L("越低越确定，越高越有随机性"),
                               isOn: AIGenerationSettings.temperatureEnabled) { [weak self] on in
                self?.temperatureToggled(on)
            }
        case .maxTokens:
            configureToggleRow(cell, title: L("最大长度"),
                               value: AIGenerationSettings.maxTokensEnabled
                                   ? "\(AIGenerationSettings.maxTokens)"
                                   : L("服务端默认"),
                               detail: L("单次回复的最大 token 数"),
                               isOn: AIGenerationSettings.maxTokensEnabled) { [weak self] on in
                self?.maxTokensToggled(on)
            }
        case .temperatureSlider:
            configureSliderRow(cell,
                               range: AIGenerationSettings.temperatureRange,
                               value: AIGenerationSettings.temperature,
                               step: 0.1,
                               format: "%.1f") { value in
                AIGenerationSettings.temperature = value
            }
        case .maxTokensSlider:
            configureSliderRow(cell,
                               // ⚠️ 区间表达式必须**在一行内**：`...` 运算符在参数列表里
                               //    换行续接会被解析成前缀形式（PartialRangeThrough）——
                               //    编译报错的位置还很误导，⛔ 别为了排版把它拆两行。
                               range: Double(AIGenerationSettings.maxTokensRange.lowerBound)...Double(AIGenerationSettings.maxTokensRange.upperBound),
                               value: Double(AIGenerationSettings.maxTokens),
                               step: 256,
                               format: "%.0f") { value in
                AIGenerationSettings.maxTokens = Int(value.rounded())
            }
        case .showThinking:
            configureToggleRow(cell, title: L("展示思考过程"),
                               value: nil,
                               detail: L("关闭后，思考内容不再显示、也不再保存。"),
                               isOn: AIGenerationSettings.showsThinkingProcess) { on in
                AIGenerationSettings.showsThinkingProcess = on
            }
        }
    }

    /// 「标题 + 右侧值 / 小字说明 + 开关」一行。
    ///
    /// 🔴 为什么**手绘**而不用 `UIListContentConfiguration.valueCell()`：
    ///    本行是三段结构（标题行带右侧值 + 说明小字 + 开关），valueCell 的
    ///    text/secondaryText 两行结构摆不下「右侧值」—— 与通知页（两行 + 开关）
    ///    不同形。手绘之后每一段的位置都是确定的，不靠系统配置布局去猜。
    /// ⚠️ 开关那颗仍然复用通知页的 `aiApplyNotifySwitch`（挂 contentView、
    ///    自带 trailing + centerY 约束与让位宽度契约，见那个文件头）。
    private func configureToggleRow(_ cell: UITableViewCell,
                                    title: String,
                                    value: String?,
                                    detail: String,
                                    isOn: Bool,
                                    onChange: @escaping (Bool) -> Void) {
        let titleLabel = UILabel()
        // 🔴 字号走 `AIChromeFont`（2026-10-22 接字号档位）：保留 Dynamic Type 文本样式，
        //    再乘档位系数 —— 两级缩放各管各的（见 `AIChromeFont.ui(_ style:)` 的文件注释）。
        titleLabel.font = AIChromeFont.ui(.body)
        titleLabel.textColor = .label
        titleLabel.text = title
        let valueLabel = UILabel()
        valueLabel.font = AIChromeFont.ui(.subheadline)
        valueLabel.textColor = .secondaryLabel
        valueLabel.text = value ?? ""
        let detailLabel = UILabel()
        detailLabel.font = AIChromeFont.ui(.footnote)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.text = detail

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), valueLabel])
        titleRow.axis = .horizontal
        let stack = UIStackView(arrangedSubviews: [titleRow, detailLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.alignment = .fill
        cell.contentView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.leading.equalTo(cell.contentView.snp.leading).offset(16)
            // 🔴 让位宽度与 `aiApplyNotifySwitch` 那颗开关成对（同通知页口径）——
            //    不长的话说明文字会被开关压住。
            make.trailing.equalTo(cell.contentView.snp.trailing)
                .offset(-AIGenerationSettingsViewController.switchReserve)
            make.top.equalTo(cell.contentView.snp.top).offset(11)
            make.bottom.equalTo(cell.contentView.snp.bottom).offset(-11)
        }
        cell.aiApplyNotifySwitch(on: isOn, onChange: onChange)
    }

    /// 「标题 + 当前值 + slider」一行（仅自定义开着时插入）。
    private func configureSliderRow(_ cell: UITableViewCell,
                                    range: ClosedRange<Double>,
                                    value: Double,
                                    step: Double,
                                    format: String,
                                    onChange: @escaping (Double) -> Void) {
        let title = UILabel()
        title.font = AIChromeFont.ui(.body)
        title.textColor = .label
        title.text = L("拖动调整")
        let valueLabel = UILabel()
        valueLabel.font = AIChromeFont.ui(.subheadline)
        valueLabel.textColor = .secondaryLabel
        let slider = UISlider()
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.value = Float(value)

        // 按 step 取整显示（温度 0.1、最大长度 256）—— 显示值与存取点同源，
        // ⛔ 别显示浮点原值（0.7000000001 那种）。
        func snapped(_ v: Double) -> Double { (v / step).rounded() * step }
        valueLabel.text = String(format: format, snapped(value))
        // 🔴 identifier + removeAction 防复用叠加（⛔ 别裸 addAction ——
        //    cell 复用时同一个 slider 对象还在，会把旧 handler 叠上）。
        slider.removeAction(identifiedBy: Self.sliderActionID, for: .valueChanged)
        slider.addAction(UIAction(identifier: Self.sliderActionID) { _ in
            let target = snapped(Double(slider.value))
            valueLabel.text = String(format: format, target)
            onChange(target)
        }, for: .valueChanged)

        let header = UIStackView(arrangedSubviews: [title, UIView(), valueLabel])
        header.axis = .horizontal
        cell.contentView.addSubview(header)
        cell.contentView.addSubview(slider)
        header.snp.makeConstraints { make in
            make.leading.equalTo(cell.contentView.snp.leading).offset(16)
            make.trailing.equalTo(cell.contentView.snp.trailing).offset(-16)
            make.top.equalTo(cell.contentView.snp.top).offset(12)
        }
        slider.snp.makeConstraints { make in
            make.leading.equalTo(cell.contentView.snp.leading).offset(16)
            make.trailing.equalTo(cell.contentView.snp.trailing).offset(-16)
            make.top.equalTo(header.snp.bottom).offset(6)
            make.bottom.lessThanOrEqualTo(cell.contentView.snp.bottom).offset(-10)
        }
    }

    /// 正文右侧给开关让位的留白宽度 —— 与 `aiApplyNotifySwitch` 成对（同通知页口径）。
    private static let switchReserve: CGFloat = 51 + 16

    /// slider 的 UIAction 标识（复用去重）。⚠️ 类型是 `UIAction.Identifier`，⛔ 不是 String。
    private static let sliderActionID = UIAction.Identifier("ai.generation.slider")
}

// MARK: - 开关驱动的行插拔

extension AIGenerationSettingsViewController {

    private func temperatureToggled(_ on: Bool) {
        let changed = AIGenerationSettings.temperatureEnabled != on
        AIGenerationSettings.temperatureEnabled = on
        applySamplingLayout(temperatureChanged: changed, maxTokensChanged: false)
    }

    private func maxTokensToggled(_ on: Bool) {
        let changed = AIGenerationSettings.maxTokensEnabled != on
        AIGenerationSettings.maxTokensEnabled = on
        applySamplingLayout(temperatureChanged: false, maxTokensChanged: changed)
    }

    /// 采样段按新开关态重排行：插入 / 删除 slider 行 + 刷新两颗开关行的右侧值。
    ///
    /// 🔴 **先写存取点、再算位置**：`rows(in:)` 读的是存取点（新态），
    ///    所以「插入」直接用 slider 行的新 indexPath；「删除」反过来 ——
    ///    新态里已经没有 slider 行，要按**开关行下一行**推它的旧位置。
    ///    ⛔ 别在写存取点之前快照 indexPath（那是旧态位置，插进去会错位到别的行）。
    /// 🔴 为什么必须 `performBatchUpdates` 而不是 `reloadData`：插入 / 删除
    ///    有动画，用户看得见「下面长出一行」这个因果关系；且 reloadData 会让
    ///    两段的开关全部重建（白刷一遍）。
    private func applySamplingLayout(temperatureChanged: Bool, maxTokensChanged: Bool) {
        tableView.performBatchUpdates {
            let samplingSection = Section.sampling.rawValue
            if temperatureChanged {
                if AIGenerationSettings.temperatureEnabled {
                    if let inserted = indexPath(of: .temperatureSlider) {
                        tableView.insertRows(at: [inserted], with: .automatic)
                    }
                } else if let toggle = indexPath(of: .temperature) {
                    tableView.deleteRows(at: [IndexPath(row: toggle.row + 1, section: samplingSection)],
                                         with: .automatic)
                }
            }
            if maxTokensChanged {
                if AIGenerationSettings.maxTokensEnabled {
                    if let inserted = indexPath(of: .maxTokensSlider) {
                        tableView.insertRows(at: [inserted], with: .automatic)
                    }
                } else if let toggle = indexPath(of: .maxTokens) {
                    tableView.deleteRows(at: [IndexPath(row: toggle.row + 1, section: samplingSection)],
                                         with: .automatic)
                }
            }
            // 两颗开关行的右侧值（服务端默认 ⇄ 当前值）。
            for row in [Row.temperature, Row.maxTokens] {
                if let indexPath = indexPath(of: row) {
                    tableView.reloadRows(at: [indexPath], with: .none)
                }
            }
        }
    }
}
