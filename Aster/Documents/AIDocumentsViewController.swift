//
//  AIDocumentsViewController.swift
//  Aster
//
//  「文档」页（2026-10-10 用户需求；入口 = 侧滑菜单第 0 组那颗「文档」，取代原「AI创作」）。
//
//  > 「所有对话中 用户上传 和 AI 返回的文件、文档 都在这个文档页面显示，
//  >   以列表形式显示，顺序以最近的为第一个。」
//
//  ## 收录范围 = **只文件**（用户同日拍板）
//  PDF / 表格 / 压缩包 / 代码 / 文本那一类，**不含图片与视频**。
//  口径写在 `AIDocumentItem`（共享层），本页只负责画。
//
//  ## 形态：**push 一整页**
//  与搜索页 / 文件预览页同一条路线。iOS 屏窄，长文件名塞在 240pt 宽的抽屉里既截断又难扫；
//  ⛔ 别改成「抽屉里的就地列表」。
//
//  ## 数据走注入，页面不直连存储
//  `documentsProvider` 由宿主接 `AIChatStore.shared.fetchDocuments()` ——
//  与搜索页（`searchProvider`）同一条规矩：宿主要换数据源 / 加缓存都不用改这一页。
//
//  ## 点一行**不自己开预览**，抛给宿主
//  预览页要的是「用户当初发的文件名」（`block.text`）而不是磁盘上那串 UUID，而且
//  「开在哪条导航栈上」只有宿主知道 ⇒ 本页把整条 `AIDocumentItem` 抛出去（同搜索页）。
//

import UIKit
import SnapKit
import AICore

final class AIDocumentsViewController: UIViewController {

    // MARK: - 对外

    /// 文档数据源（**会在后台线程调用**，实现里别再碰 UI）
    var documentsProvider: (() -> [AIDocumentItem])?

    /// 点了某一行（整条记录抛出去，宿主负责 push 预览页）
    var onSelect: ((AIDocumentItem) -> Void)?

    // MARK: - 数据

    private var items: [AIDocumentItem] = []

    /// 递增的加载序号：连点进来两次时，慢的那次回来不能盖掉新结果
    private var loadToken = 0

    // MARK: - 视图

    private lazy var tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .plain)
        t.dataSource = self
        t.delegate = self
        t.register(AIDocumentCell.self, forCellReuseIdentifier: AIDocumentCell.reuseIdentifier)
        t.rowHeight = UITableView.automaticDimension
        t.estimatedRowHeight = 72
        // 分隔线与文字左对齐（16 边距 + 40 角标 + 12 间距）
        t.separatorInset = UIEdgeInsets(top: 0, left: 68, bottom: 0, right: 0)
        t.tableFooterView = UIView()
        return t
    }()

    /// 空态：一次都没上传过文件（**不是**「加载中」—— 加载很快，不给它造一个态）
    private lazy var emptyLabel: UILabel = {
        let l = UILabel()
        l.numberOfLines = 0
        l.textAlignment = .center
        l.font = .systemFont(ofSize: 14)
        l.textColor = .tertiaryLabel
        l.text = L("还没有文件\n在对话里上传的文件都会出现在这里")
        return l
    }()

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("文档")
        view.backgroundColor = .systemBackground
        // 会话页若开了大标题，push 进来的页面会跟着变大标题 ⇒ 显式收掉
        navigationItem.largeTitleDisplayMode = .never
        setupUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 放在 willAppear 而不是 viewDidLoad：从预览页返回、或刚在会话里传完文件回来，
        // 列表都该跟着变 —— 每次进页面重拉一次最省事，也不会读到过期数据
        load()
    }

    // MARK: - 布局

    private func setupUI() {
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
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
        loadToken += 1
        let token = loadToken
        // 在主线程取值再进后台：provider 可能被宿主替换，别在后台线程读 VC 属性
        let provider = documentsProvider
        emptyLabel.isHidden = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = provider?() ?? []
            DispatchQueue.main.async {
                guard let self = self, token == self.loadToken else { return }   // 过期结果丢弃
                self.items = result
                self.tableView.reloadData()
                self.emptyLabel.isHidden = !result.isEmpty
            }
        }
    }
}

// MARK: - 列表

extension AIDocumentsViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AIDocumentCell.reuseIdentifier,
                                                 for: indexPath)
        if let cell = cell as? AIDocumentCell, indexPath.row < items.count {
            cell.configure(with: items[indexPath.row])
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < items.count else { return }
        onSelect?(items[indexPath.row])
    }
}

// MARK: - 行

/// 一行文档：左侧「扩展名角标」+ 文件名 + 「大小 · 来自哪个会话」+ 右侧时间。
///
/// ⚠️ 文件名用 `displayName`（= `block.text`）而**不是** `fileURL.lastPathComponent`：
/// 附件落盘时名字被换成了 UUID，磁盘名和用户认得的名字不是一回事
///（iOS 的 `AIFilePreviewController` 与 mac 的 `FilePreviewPane` 都在这上面踩过）。
final class AIDocumentCell: UITableViewCell {

    static let reuseIdentifier = "AIDocumentCell"

    /// 扩展名角标：固定 40×40 的圆角方块，两种状态（有扩展名 / 没有）都不变尺寸，
    /// 否则一行里文件名与副标题的起始位置会随文件类型左右跳
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
        // 两行：长文件名（xlsx 那类）截一半就认不出来了
        l.numberOfLines = 2
        return l
    }()

    private let detailLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        l.numberOfLines = 1
        // 会话名长了要**能截断** —— 否则它会把右边的时间挤出屏幕（2026-10-10 实拍踩到）
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }()

    /// 时间（与 mac 的 `DocumentRow` 同款：**独立一列在右侧**，不拼进副标题）。
    ///
    /// ☠️ 2026-10-10 实证：第一版把时间拼在副标题尾巴上（`大小 · 来自「会话」· 时间`），
    /// 而 `detailLabel` 是 `numberOfLines = 1` ⇒ **长会话名直接把时间截掉**。
    /// 模拟器里那条真数据（会话名「帮我写一首关于星星的诗」）当场显形：
    /// `12 KB · 来自「帮我写一首关于星星的诗」· 10月6日…` —— 几点看不见了。
    /// ☠️ 这种事**契约脚本发现不了**（文案是拼出来的，grep 只看得到源码里那个格式串），
    /// 只有截图能 —— 这也是「iOS 侧能截的一律先截图」那条规矩的又一个实证。
    private let timeLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 13)
        l.textColor = .secondaryLabel
        l.textAlignment = .right
        l.numberOfLines = 1
        // 🔴 时间**永不许被压缩**：要挤先挤副标题（会话名）那一行
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        accessoryType = .disclosureIndicator
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupUI() {
        contentView.addSubview(badgeView)
        badgeView.addSubview(badgeLabel)
        contentView.addSubview(nameLabel)
        contentView.addSubview(detailLabel)
        contentView.addSubview(timeLabel)

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
            // 🔴 右边让给「时间」那一列（原本是 `-16` = 直抵 cell 右边缘 —— 时间没地方放）
            make.trailing.equalTo(timeLabel.snp.leading).offset(-8)
            make.top.equalTo(nameLabel.snp.bottom).offset(3)
            make.bottom.equalToSuperview().offset(-12)
        }
        timeLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-16)
            // 与 mac 的 `DocumentRow` 同款：时间在**整行垂直居中**（那边是 HStack 的末元素）
            make.centerY.equalToSuperview()
        }
    }

    func configure(with item: AIDocumentItem) {
        let ext = item.fileExtension
        // 超过 4 个字符的扩展名（markdown / xlsx 之类够用）会被缩排，
        // 不截断成 "MARK" 那种读不出来的东西 —— 让 `adjustsFontSizeToFitWidth` 去缩
        badgeLabel.text = ext.isEmpty ? "?" : ext
        nameLabel.text = item.displayName
        // 文案口径与 mac 的 `DocumentRow.detailText` **逐字一致**（时间**不**在这条里）
        detailLabel.text = String(format: L("%@ · 来自「%@」"), item.sizeText, item.displayConversationTitle)
        // 时间口径走共享层的唯一入口（⛔ 别在这里 new DateFormatter）
        timeLabel.text = AIMessageTime.string(from: item.createdAt)
    }
}
