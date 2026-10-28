//
//  AIProjectDetailViewController.swift
//  Aster
//
//  项目详情页（iOS）—— 2026-10-21 随「项目（会话文件夹）」的 L2 一起新建。
//
//  ## 它是干什么的
//  项目 = 会话的文件夹。文件夹里除了会话，还能挂**资料**（PDF / 表格 / 代码…），
//  这就是「项目资料库」：和某件事相关的文件都放在项目里，聊这件事时随时取用。
//  ⚠️ 与豆包 / WorkBuddy 的差别：那两家的空间能**读**资料内容（agent 环境 / 轻量 RAG），
//  Aster 目前没有工具调用能力 ⇒ 这里的资料是「可一键带进消息的素材库」，
//  **不自动进上下文**。这一条别在文案里说过头（别写「AI 会记住这些文件」）。
//
//  ## 两种模式（同一个列表，两种用法）
//  - `.manage`：从抽屉分组头「…」→「管理项目」进来 —— 可添加 / 滑动删除 / 点开预览；
//  - `.pick`  ：从会话输入区「+ → 项目资料」进来 —— 只选一个带进待发区，不给增删。
//  ⚠️ 刻意复用同一个类而不是写两页：两边列表长得一样，分开写必然会出现
//  「一个页面改了行高、另一个没改」这种两端分叉（本工程最熟悉的那类回归）。
//
//  ## 数据走注入，页面不直连存储
//  与 `AIDocumentsViewController` / 搜索页同一条规矩：读写都抛给宿主（`AIModuleViewController`
//  里接线），本页只管画。这样将来换数据源 / 加缓存都不用改这一页。
//

import UIKit
import SnapKit
// 🔴 `UTType.item` 要显式 import（本工程开了 `MEMBER_IMPORT_VISIBILITY`）——
//    `UIKit` 只是**再导出**了它，用它当 `forOpeningContentTypes:` 的参数时会报
//    「static property 'item' is not available due to missing import」。
import UniformTypeIdentifiers
import AICore

final class AIProjectDetailViewController: UIViewController {

    // MARK: - 模式

    enum Mode {
        /// 管理：添加 / 删除 / 预览
        case manage
        /// 选取：点一行就交出去（带进待发区）
        case pick
    }

    // MARK: - 对外

    /// 资料数据源（宿主接 `manager.fetchProjectFiles(projectId:)`）
    var filesProvider: (() -> [AIChatProjectFile])?

    /// 选了要导入的文件（`asCopy: true` 拿到的临时副本 URL；落盘 + 落库由宿主做）
    var onAddFiles: (([URL]) -> Void)?

    /// 删除某条资料（行 + 物理文件由宿主负责）
    var onDeleteFile: ((UUID) -> Void)?

    /// `.pick` 模式点了某一行（= 选中，带进待发区）
    var onSelectFile: ((AIChatProjectFile) -> Void)?

    /// `.manage` 模式点了某一行（= 预览）
    ///
    /// ⚠️ 与 `onSelectFile` **刻意分开**：两件事的语义不一样（一个「带进消息」、
    /// 一个「看一眼」），合成一个回调，将来任一侧改语义都会悄悄串味。
    var onPreviewFile: ((AIChatProjectFile) -> Void)?

    /// 项目级指令的读口（只用来显示「已设置 / 未设置」，不在这里编辑）
    var instructionProvider: (() -> String)?

    /// 点了「项目指令」那一行（宿主导航里 push 编辑页 —— 复用全局指令页，见 `+Projects.swift`）
    var onOpenInstruction: (() -> Void)?

    /// 索引状态读口（RAG，2026-10-23；宿主接 `manager.projectIndexStatus(projectId:)`）
    var indexStatusProvider: (() -> AIProjectIndexStatus)?

    /// 点了「重建索引」（宿主调 `manager.rebuildProjectIndex(projectId:)` 后重拉）
    var onRebuildIndex: (() -> Void)?

    // MARK: - 入口参数

    private let project: AIChatProject
    private let mode: Mode
    private let isModal: Bool

    // MARK: - 数据

    private var files: [AIChatProjectFile] = []

    // MARK: - 视图

    private lazy var tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .plain)
        t.dataSource = self
        t.delegate = self
        t.register(AIProjectFileCell.self, forCellReuseIdentifier: AIProjectFileCell.reuseIdentifier)
        t.rowHeight = UITableView.automaticDimension
        t.estimatedRowHeight = 64
        // 分隔线与文字左对齐（16 边距 + 40 角标 + 12 间距），与「文档」页同款
        t.separatorInset = UIEdgeInsets(top: 0, left: 68, bottom: 0, right: 0)
        t.tableFooterView = UIView()
        return t
    }()

    /// 空态（**不是**「加载中」—— 本地查询很快，不给它造一个态）
    private lazy var emptyLabel: UILabel = {
        let l = UILabel()
        l.numberOfLines = 0
        l.textAlignment = .center
        l.font = .systemFont(ofSize: 14)
        l.textColor = .tertiaryLabel
        l.text = mode == .pick
            ? L("这个项目还没有资料")
            : L("还没有资料\n把常看的文件放进项目，聊这个项目时随时取用")
        return l
    }()

    /// 顶部「项目指令」一行（**钉在列表上方、不跟着滚**）
    ///
    /// 🔴 只在管理态出现：选取态是「挑一份资料带进消息」，改指令是**改配置**，
    ///    不该出现在那条路上（同「选取态不给增删」）。
    /// ⚠️ 它不是表格里的行：钉在顶上才符合「这是这个项目的属性，不是一份资料」，
    ///    混进列表会让人以为点它等于打开某个文件。
    private lazy var instructionRow: UIControl = {
        let c = UIControl()
        c.backgroundColor = .secondarySystemGroupedBackground
        c.addTarget(self, action: #selector(instructionTapped), for: .touchUpInside)
        return c
    }()

    private let instructionTitleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 16)
        l.textColor = .label
        l.text = L("项目指令")
        return l
    }()

    /// 右侧状态（已设置 / 未设置）—— ⚠️ 每次 `viewWillAppear` 重读，编辑完返回要跟着变
    private let instructionValueLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14)
        l.textColor = .secondaryLabel
        l.textAlignment = .right
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }()

    private let instructionChevron: UIImageView = {
        let v = UIImageView(image: UIImage(systemName: "chevron.right"))
        v.tintColor = .tertiaryLabel
        v.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        v.contentMode = .center
        return v
    }()

    /// 「资料索引」状态行（RAG，2026-10-23）—— 钉在指令行下方、不跟着滚。
    ///
    /// 与 Mac 的 `ProjectDetailView.indexStatusBox` 同一套口径（管理态才出现）：
    /// 左边标题、中间「已索引 N/M · K 个片段」、右边一颗「重建」。
    /// ⛔ 别把状态做成表格行：它是**项目属性**（这批资料能不能被检索），
    ///    不是一份资料（同 `instructionRow` 的理由）。
    private lazy var indexRow: UIControl = {
        let c = UIControl()
        c.backgroundColor = .secondarySystemGroupedBackground
        return c
    }()

    private let indexTitleLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 16)
        l.textColor = .label
        l.text = L("资料索引")
        return l
    }()

    /// 右侧状态（每次 `viewWillAppear` 重读 —— 刚导入完资料回来，索引数要跟着变）
    private let indexValueLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 14)
        l.textColor = .secondaryLabel
        l.textAlignment = .right
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }()

    /// 「重建」—— 一颗文字钮。全量重读是用户主动的修复动作，⛔ 别自动化
    /// （每次进页面都重建 = 白读整个库）。
    private lazy var rebuildIndexButton: UIButton = {
        let b = UIButton(type: .system)
        b.titleLabel?.font = .systemFont(ofSize: 14)
        b.setTitle(L("重建"), for: .normal)
        b.addTarget(self, action: #selector(rebuildIndexTapped), for: .touchUpInside)
        return b
    }()

    // MARK: - 初始化

    /// - Parameters:
    ///   - project: 目标项目（标题用它，排序/归属不需要再查）
    ///   - mode: 见 `Mode`；`.pick` 不给增删入口
    ///   - isModal: `true` ⇒ 自备左上角「关闭」（同 `AISettingsViewController` 的口径）
    init(project: AIChatProject, mode: Mode = .manage, isModal: Bool = true) {
        self.project = project
        self.mode = mode
        self.isModal = isModal
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = mode == .pick ? L("选择项目资料") : project.name
        view.backgroundColor = .systemBackground
        // 从会话页 push 进来的那条路会跟着变大标题 ⇒ 显式收掉（同文档页）
        navigationItem.largeTitleDisplayMode = .never
        if isModal {
            navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close,
                                                               target: self,
                                                               action: #selector(closeTapped))
        }
        // 只有管理态给「添加」；选取态加进来是**改数据**，与「选一个带进消息」是两件事
        if mode == .manage {
            navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add,
                                                                target: self,
                                                                action: #selector(addTapped))
        }
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 每次进页面重拉：从预览页返回、刚添加完回来，列表都该跟着变（同文档页）
        load()
    }

    // MARK: - 布局

    private func setupUI() {
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        view.addSubview(instructionRow)
        instructionRow.addSubview(instructionTitleLabel)
        instructionRow.addSubview(instructionValueLabel)
        instructionRow.addSubview(instructionChevron)
        view.addSubview(indexRow)
        indexRow.addSubview(indexTitleLabel)
        indexRow.addSubview(indexValueLabel)
        indexRow.addSubview(rebuildIndexButton)

        // 🔴 管理态才有那两行；选取态（`isHidden = true`）时表格直接顶到安全区
        instructionRow.isHidden = (mode == .pick)
        indexRow.isHidden = (mode == .pick)
        let top: ConstraintRelatableTarget = indexRow.isHidden ? view.safeAreaLayoutGuide.snp.top
                                                               : indexRow.snp.bottom
        instructionRow.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(52)
        }
        indexRow.snp.makeConstraints { make in
            make.top.equalTo(instructionRow.snp.bottom)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(52)
        }
        indexTitleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
        }
        rebuildIndexButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-16)
            make.centerY.equalToSuperview()
        }
        indexValueLabel.snp.makeConstraints { make in
            make.leading.greaterThanOrEqualTo(indexTitleLabel.snp.trailing).offset(12)
            make.trailing.equalTo(rebuildIndexButton.snp.leading).offset(-12)
            make.centerY.equalToSuperview()
        }
        instructionTitleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
        }
        instructionChevron.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-16)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(16)
        }
        instructionValueLabel.snp.makeConstraints { make in
            make.leading.greaterThanOrEqualTo(instructionTitleLabel.snp.trailing).offset(12)
            make.trailing.equalTo(instructionChevron.snp.leading).offset(-6)
            make.centerY.equalToSuperview()
        }
        tableView.snp.makeConstraints { make in
            make.top.equalTo(top)
            make.leading.trailing.bottom.equalToSuperview()
        }
        emptyLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview().offset(-40)
            make.leading.greaterThanOrEqualToSuperview().offset(32)
            make.trailing.lessThanOrEqualToSuperview().offset(-32)
        }
    }

    // MARK: - 加载

    private func load() {
        files = filesProvider?() ?? []
        tableView.reloadData()
        emptyLabel.isHidden = !files.isEmpty
        refreshInstructionValue()
        refreshIndexValue()
    }

    /// 「已索引 N/M · K 个片段」—— 与 Mac 同一口径。没有宿主接（理论不存在，
    /// 两个入口都接）时给一句中性的，⛔ 别留空。
    private func refreshIndexValue() {
        guard mode == .manage else { return }
        guard let status = indexStatusProvider?() else {
            indexValueLabel.text = L("索引状态读取中…")
            return
        }
        indexValueLabel.text = String(format: L("已索引 %d/%d · %d 个片段"),
                                      status.indexedFileCount, status.fileCount, status.chunkCount)
    }

    /// 点「重建」：宿主重建（全量重读）后回调里重拉 —— 本页只管要数据。
    @objc private func rebuildIndexTapped() {
        onRebuildIndex?()
        refreshIndexValue()
    }

    /// 「已设置 / 未设置」—— 只显示有无，**不把指令正文铺出来**：
    /// 指令是长文，截断显示在窄行里既读不出重点，也会随语言/字号变高。
    private func refreshInstructionValue() {
        guard mode == .manage else { return }
        let text = (instructionProvider?() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        instructionValueLabel.text = text.isEmpty ? L("未设置") : L("已设置")
        instructionValueLabel.textColor = text.isEmpty ? .secondaryLabel : .tintColor
    }

    @objc private func instructionTapped() {
        onOpenInstruction?()
    }

    // MARK: - 动作

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    /// 添加资料：系统文件选择器。
    ///
    /// `asCopy: true` 是关键（与输入栏那条**同一个理由**，见 `presentFilePicker`）：
    /// 系统直接把文件拷一份到 tmp，于是完全不用碰 security-scoped URL 那套。
    @objc private func addTapped() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }
}

// MARK: - 列表

extension AIProjectDetailViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        files.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AIProjectFileCell.reuseIdentifier,
                                                 for: indexPath)
        if let cell = cell as? AIProjectFileCell, indexPath.row < files.count {
            // 选取态不画箭头：点它就是「选中」，不是「进下一页」
            cell.configure(with: files[indexPath.row], showsDisclosure: mode == .manage)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < files.count else { return }
        let file = files[indexPath.row]
        switch mode {
        case .pick:
            onSelectFile?(file)
            dismiss(animated: true)
        case .manage:
            // 管理态点一行 = 预览（与「文档」页同一件事）。交给宿主 push，别在这一页自己开。
            onPreviewFile?(file)
        }
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        // 选取态不给删除：那一刻用户是来「挑一个」的，不该顺手改掉项目的资料
        guard mode == .manage, indexPath.row < files.count else { return nil }
        let file = files[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: L("删除")) { [weak self] _, _, done in
            guard let self else { return done(false) }
            self.onDeleteFile?(file.id)
            self.load()
            done(true)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }
}

// MARK: - 文件选择

extension AIProjectDetailViewController: UIDocumentPickerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        onAddFiles?(urls)
        load()
    }
}

// MARK: - 行

/// 一行项目资料：扩展名角标 + 文件名 + 「大小 · 加入时间」。
///
/// 与「文档」页的 `AIDocumentCell` **刻意不共用**：那一行要显示「来自哪个会话」，
/// 这一行没有会话维度（资料属于项目、不属于某次对话）。共用就得给半个字段加可选，
/// 到头来两边都别扭。
final class AIProjectFileCell: UITableViewCell {

    static let reuseIdentifier = "AIProjectFileCell"

    private let badgeView: UIView = {
        let v = UIView()
        v.backgroundColor = .secondarySystemFill
        v.layer.cornerRadius = 8
        v.clipsToBounds = true
        return v
    }()

    private let badgeLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.adjustsFontSizeToFitWidth = true
        l.minimumScaleFactor = 0.7
        return l
    }()

    private let nameLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 16)
        l.textColor = .label
        l.numberOfLines = 2
        return l
    }()

    private let detailLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        l.numberOfLines = 1
        return l
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupUI() {
        contentView.addSubview(badgeView)
        badgeView.addSubview(badgeLabel)
        contentView.addSubview(nameLabel)
        contentView.addSubview(detailLabel)

        badgeView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(40)
        }
        badgeLabel.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(4)
        }
        nameLabel.snp.makeConstraints { make in
            make.leading.equalTo(badgeView.snp.trailing).offset(12)
            make.trailing.equalToSuperview().offset(-16)
            make.top.equalToSuperview().offset(12)
        }
        detailLabel.snp.makeConstraints { make in
            make.leading.equalTo(nameLabel)
            make.trailing.equalTo(nameLabel)
            make.top.equalTo(nameLabel.snp.bottom).offset(3)
            make.bottom.equalToSuperview().offset(-12)
        }
    }

    func configure(with file: AIChatProjectFile, showsDisclosure: Bool) {
        let ext = file.fileExtension
        badgeLabel.text = ext.isEmpty ? "?" : ext
        nameLabel.text = file.displayName
        // 时间口径走共享层的唯一入口（⛔ 别在这里 new DateFormatter）
        detailLabel.text = String(format: L("%@ · 加入于 %@"), file.sizeText,
                                 AIMessageTime.string(from: file.createdAt))
        accessoryType = showsDisclosure ? .disclosureIndicator : .none
    }
}
