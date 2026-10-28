//
//  AICustomModelListViewController.swift
//  AIModule
//
//  「自定义模型」清单页 —— 2026-10-14 新增，形态照用户在参考图里给的那一页。
//
//  ## 它在页面层级里的位置（2026-10-14 起本页是设置页的一个子页）
//      侧滑菜单齿轮 / 账号弹窗「设置」 / 聊天页兜底入口
//            ↓
//      「设置」页（`AISettingsViewController`）   ← 只管「有哪几块设置」
//            ↓ 点「自定义模型」那一行
//      「自定义模型」清单页（本页）   ← 只管「清单里有哪些」
//            ↓ 点右上「添加模型」/ 点某一行（或行尾的 ✎）
//      「添加模型」表单（`AIAddModelViewController`）  ← 只管「这一条怎么填」
//
//  改造前是**直连**：设置入口 → 表单，而「有哪些模型」这件事由表单里那颗供应商下拉隐式表达
//  （一平台一条，永远是三条）。JSON 化之后清单是**用户自己攒的任意多条**，
//  「有哪些 / 加一条 / 删一条」需要一块自己的地方 —— 就是本页。
//  ⚠️ 会话页那颗胶囊的「管理模型」也会 push 到本页（那条路不经过设置页）——
//     两处的 `AICustomModelListViewController()` 是**同一个类、同一个形态**（都被 push）。
//
//  ## 三件必须记住的事
//  1. 🔴 **本页不回答「现在用哪个」**。那是运行时状态（`AIModelStore.currentID`，存 UserDefaults），
//     换它的入口是**聊天窗口那颗胶囊**。行上**不标**当前项（2026-10-16 用户要求去掉字样，
//     与 Mac 侧 10-14 同款；在用哪个看会话页胶囊/选择器里的打勾）——⛔ 别做成可点的选择器
//     （那会让「配置」与「这一会儿用谁」两件事粘回一起，正是 2026-10-02 拆开的那对）。
//  2. 🔴 **行的顺序 = 文件里的顺序**，本页不排序（`AIModelStore.all()` 原样返回）。
//     用户把某条提到第一行，界面就跟着变 —— 这是那份 JSON「可手改」价值的一部分。
//  3. ⚠️ 文件解析失败时（用户手改坏了 JSON）**不能显示成空清单**：那会诱导用户
//     「我的配置丢了」→ 重新加一遍 → 覆盖掉他手写的内容。所以顶部挂一条红字说明，
//     并保留上一份能解析出来的内容（`AIModelStore.lastLoadError` 的行为见那边的注释）。
//  4. 🔴 **本页列全部条目（含「还没配齐」的）；会话页那个选择器只列配齐的** —— 两页刻意不同：
//     这里答「我有哪些、哪条还缺东西」，那边答「这会儿能拿哪一个去发」（口径写在
//     `AIModelCatalog.readyChoices()` 上）。⇒ 没配齐的条目在行尾带一个「· 还没配齐」标记
//     （见 `AICustomModelCell.configure`），⛔ 别把它当装饰删掉 —— 选择器已经不列它们了，
//     这里是它们**唯一**能被人看见的地方。
//

import UIKit
import SnapKit
import AICore

final class AICustomModelListViewController: UIViewController {

    // MARK: - 入口方式
    //
    // 🔴 2026-10-14：原来这里有个 `isModal` 开关（决定左上角用「关闭」还是系统返回键）。
    //    「设置」升格成容器页（`AISettingsViewController`）之后，本页**永远是被 push 的**
    //    （设置页 → 本页 · 会话页胶囊的「管理模型」→ 本页），那个开关**零调用点** ⇒ 删掉。
    //    ⛔ 别以「万一将来有人模态弹它」为由加回来：本页的 `openForm` 已经给
    //      「拿不到导航栈」那一种情况备了兜底（自己包一个 nav），够用。

    // MARK: - 状态

    private var entries: [AICustomModel] = []

    // MARK: - UI

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.backgroundColor = .systemBackground
        tv.separatorInset = UIEdgeInsets(top: 0, left: 60, bottom: 0, right: 16)
        tv.rowHeight = 90
        tv.dataSource = self
        tv.delegate = self
        tv.register(AICustomModelCell.self, forCellReuseIdentifier: AICustomModelCell.reuseID)
        return tv
    }()

    private lazy var emptyLabel: UILabel = {
        let l = UILabel()
        l.font = AIChromeFont.ui(14)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        l.isHidden = true
        return l
    }()

    private lazy var addItem = UIBarButtonItem(title: L("添加模型"),
                                               style: .plain,
                                               target: self,
                                               action: #selector(addTapped))

    // MARK: - 生命周期

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("模型")
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = addItem
        // ⛔ **不设** `leftBarButtonItem`：本页永远是被 push 的，设了会把系统返回键顶掉。
        setupUI()
        reload()
        // 本页自己的动作（删 / 表单保存）会广播配置变更；也有可能别处改了文件
        NotificationCenter.default.addObserver(self,
                                              selector: #selector(configDidChange),
                                              name: AIConfig.didChangeNotification,
                                              object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从表单返回 / 用户刚在「文件」App 里改过这份 JSON ⇒ 重读一次（mtime 没变时是空操作）
        AIConfig.reloadModels()
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        openFormIfRequested()
    }

    // MARK: - 🧪 验收钩子：再往里推一层「添加模型」表单

    /// 一次性闩（同表单那个 `didAutoExpandProvider`）。
    private var didAutoOpenForm = false

    /// `STARRY_SETTINGS_UI=form|provider|model|draft|draft-discard` 时进页自动再推一次表单（只推一次）。
    ///
    /// ## 为什么需要它
    /// 表单页现在在导航栈**第四层**（设置页 → 清单页 → 表单），而模拟器**投不出合成触摸**
    /// ⇒ 没有它，「表单页长什么样、三个字段的次序对不对、保存按钮还在不在可视区」
    /// agent 侧一张图都拿不到。
    /// ⚠️ 走的是**和点「添加模型」那颗按钮完全相同的那条路**（`openForm(editing: nil)`），
    ///    ⛔ 别自己 `pushViewController` 走捷径 —— 那样验的不是用户走的那条路。
    /// ⚠️ 这是**一条链上的中间一段**：`AISettingsViewController.openSubPageIfRequested()`
    ///    负责把清单页推出来，本段负责再往里一层，表单那一段（`openPickerIfRequested`）
    ///    负责最后弹一层选择页。三段的取值都在同一个 `STARRY_SETTINGS_UI` 上。
    /// 🔴 `form|provider|model|draft|draft-discard` 五档都要推表单 —— 后三档只是
    ///    「在表单上再做个动作」（弹选择页 / 填草稿 / 填完不保存就离开）。
    private func openFormIfRequested() {
        #if DEBUG
        guard !didAutoOpenForm else { return }
        let mode = ProcessInfo.processInfo.environment["STARRY_SETTINGS_UI"] ?? ""
        guard mode == "form" || mode == "provider" || mode == "model"
            || mode == "draft" || mode == "draft-discard" else { return }
        didAutoOpenForm = true
        // 等这一帧画完再推（与上一层钩子同一条理由：当场 push 会截到半透明残影）
        DispatchQueue.main.async { [weak self] in
            self?.openForm(editing: nil)
        }
        #endif
    }

    // MARK: - 布局

    private func setupUI() {
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        tableView.snp.makeConstraints { make in make.edges.equalTo(view.safeAreaLayoutGuide) }
        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(tableView)
            make.leading.equalToSuperview().offset(32)
            make.trailing.equalToSuperview().offset(-32)
        }
    }

    // MARK: - 刷新

    private func reload() {
        entries = AIModelStore.all()
        tableView.tableHeaderView = makeHeader()
        tableView.reloadData()
        emptyLabel.isHidden = !entries.isEmpty
        emptyLabel.text = L("还没有配置模型\n点右上角「添加模型」加一条")
    }

    @objc private func configDidChange() {
        // 广播可能来自本页（删除）也可能来自别处；统一重读，幂等
        reload()
    }

    /// 顶部说明：**加完写到哪**（参考图那一行）+ 文件坏了时的红字警告。
    ///
    /// ⚠️ 这两块拼在同一个 `tableHeaderView` 里：表头是**按内容自动量高**的
    ///    （`systemLayoutSizeFitting` 那一套），分成两个视图就得自己算总高。
    private func makeHeader() -> UIView {
        let container = UIView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        container.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(10)
            make.bottom.equalToSuperview().offset(-14)
            make.leading.equalToSuperview().offset(20)
            make.trailing.equalToSuperview().offset(-20)
        }
/*
        // 「模型添加后会写入到本地 Documents/models.json 文件中。」——路径用等宽体，
        // 与参考图一致（它能帮用户一眼认出「就是那个文件」）。
        let note = UILabel()
        note.numberOfLines = 0
        let text = String(format: L("模型添加后会写入到本地 %@ 文件中。"), AIModelStore.shortDisplayPath)
        let attr = NSMutableAttributedString(string: text,
                                             attributes: [.font: UIFont.systemFont(ofSize: 13),
                                                          .foregroundColor: UIColor.secondaryLabel])
        if let range = text.range(of: AIModelStore.shortDisplayPath) {
            attr.addAttributes([.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                .foregroundColor: UIColor.label],
                               range: NSRange(range, in: text))
        }
        note.attributedText = attr
        stack.addArrangedSubview(note)
*/
        // 🔴 文件坏了：必须说出来（见文件头第 3 条）。不报的话，用户会以为配置被清空了。
        if let error = AIModelStore.lastLoadError {
            let warn = UILabel()
            warn.numberOfLines = 0
            warn.font = AIChromeFont.ui(13)
            warn.textColor = .systemRed
            warn.text = String(format: L("这个文件读不出来：%@\n下面显示的是上一次能读到的内容；改好文件后回到这一页即生效。"),
                               error)
            stack.addArrangedSubview(warn)
        }

        container.frame.size = container.systemLayoutSizeFitting(
            CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel)
        return container
    }

    // MARK: - 动作

    @objc private func addTapped() {
        openForm(editing: nil)
    }

    /// 打开「添加模型」表单。
    ///
    /// - Parameter editing: `nil` = 新增；非 nil = 改这一条（`id` 是不可改的键，见表单那边）。
    private func openForm(editing entry: AICustomModel?) {
        let form = AIAddModelViewController(editingModel: entry)
        guard let nav = navigationController else {
            present(UINavigationController(rootViewController: form), animated: true)
            return
        }
        nav.pushViewController(form, animated: true)
    }

    /// 删除一条 —— **带确认**。
    ///
    /// 为什么必须确认：这一条配置里有用户贴的 API Key，删掉就得重新去服务商后台复制一遍
    /// （很多 Key 只在创建时显示一次）。而误触的代价正是这个，所以哪怕是第二下也要拦一道。
    private func confirmDelete(_ entry: AICustomModel) {
        let alert = UIAlertController(
            title: String(format: L("删除「%@」？"), entry.displayName),
            message: L("会从 models.json 里移除这一条（含它存的 API Key），无法撤销。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { _ in
            // ☠️ 这一笔是**写全局存储**、不依赖 self，而且哪怕本页已经不在了也该执行
            //    （用户已经确认过）。所以这里**不解包 self** —— 提一个 `guard let self`
            //    只是为了一行用不上的代码，反而会让人觉得「本页不在了就不删了」。
            // ⚠️ 写入会广播（`AIModelStore.remove` → `notifyChange`）⇒ `configDidChange`
            //    会重读一遍并重绘表格；本页已销毁时观察者早被移除，什么也不发生。
            AIModelStore.remove(id: entry.id)
        })
        present(alert, animated: true)
    }

    private func openDocumentation(_ entry: AICustomModel) {
        guard let url = entry.documentationURL else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - 列表数据源

extension AICustomModelListViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AICustomModelCell.reuseID,
                                                for: indexPath)
        guard let cell = cell as? AICustomModelCell, entries.indices.contains(indexPath.row) else {
            return cell
        }
        let entry = entries[indexPath.row]
        cell.configure(with: entry)
        // 三颗行尾按钮：改 / 看文档 / 删。⚠️ 回调里**不捕获 entry**而是重新按行号取
        // ——列表可能在弹窗/回调之间变过（配置变更广播），捕获那一份会删错行。
        cell.onEdit = { [weak self] in
            guard let self, self.entries.indices.contains(indexPath.row) else { return }
            self.openForm(editing: self.entries[indexPath.row])
        }
        cell.onOpenDocs = { [weak self] in
            guard let self, self.entries.indices.contains(indexPath.row) else { return }
            self.openDocumentation(self.entries[indexPath.row])
        }
        cell.onDelete = { [weak self] in
            guard let self, self.entries.indices.contains(indexPath.row) else { return }
            self.confirmDelete(self.entries[indexPath.row])
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard entries.indices.contains(indexPath.row) else { return }
        openForm(editing: entries[indexPath.row])
    }
}

// MARK: - 一行

/// 清单里的一行（2026-10-16 起**两行**）：第一行 图标 + 名称 + 供应商；
/// 第二行 三颗动作（改 / 看文档 / 删），靠左、与模型名称文本对齐。
///
/// 🔴 为什么是两行：改造前四样挤一行（图标 + 长模型名 + 供应商 + 三颗 36×36 按钮），
///    名称被压得最狠（用户：「cell 有点拥挤」）。按钮下移后第一行独占整宽。
///
/// ⚠️ 行尾那三颗是**常驻**的（不是悬停才出现）：iOS 没有 hover，
///    而它们正是这一页的主要操作 —— 藏起来等于「这一页点不动」。
private final class AICustomModelCell: UITableViewCell {

    static let reuseID = "AICustomModelCell"

    var onEdit: (() -> Void)?
    var onOpenDocs: (() -> Void)?
    var onDelete: (() -> Void)?

    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let vendorLabel = UILabel()
    private let editButton = AICustomModelCell.makeActionButton(symbol: "pencil")
    private let docsButton = AICustomModelCell.makeActionButton(symbol: "link")
    private let deleteButton = AICustomModelCell.makeActionButton(symbol: "trash")

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        backgroundColor = .systemBackground

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .label
        // 名称：可截断（模型名可以很长），中间省略更能保留前后缀信息
        // ⚠️ 2026-10-16 用户反馈「文字小、按钮大」⇒ 字号调到 iOS 设置页标准量级
        //    （17 = `textLabel` 默认 / 14 = 行内联小字）：原来 16/13 在第二行三连排
        //    图标按钮的对照下显得单薄。
        nameLabel.font = AIChromeFont.ui(18)
        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingMiddle
        // 供应商 +（没配齐时）一个标记，都用同一行小字
        vendorLabel.font = AIChromeFont.ui(16)
        vendorLabel.textColor = .secondaryLabel
        // 🔴 抗压缩：这一行是**两个角色的分工**，必须显式写死，不能靠两边的默认值。
        //    名称可以很长（`deepseek-v4-flash-vision-exp`），而供应商是**短标签**
        //    （最长「智谱开放平台 · 还没配齐」）。
        //    ☠️☠️ 两边都用默认值（`UILabel` 默认抗压缩 = **750**）时，长名称会把供应商
        //       **整个压成 0 宽** —— 屏幕上看是「这一行没有供应商」，而它其实是被压没了
        //       （不是没设文案、也不是数据缺字段）。
        //       2026-10-14 真机截图抓到：第一行那句「深度求索 · 当前使用」整块不见了，
        //       而它正是**当前使用**那个标记 —— 一个信息位就这么静默消失了。
        //    ☠️ 踩过的坑：第一次「修复」写的是 `vendorLabel` 用 `.defaultHigh`，还注释成
        //       「= 751」——**错的**。UIKit 里 `.defaultHigh` **就是 750**，与默认值**相等**
        //       ⇒ 优先级没差、等于没改（两轮截图逐字节相同就是铁证，见 `VERIFY-PROBES.md`
        //       「两次截图相同 = 改动没生效」）。⛔ 别再写 `.defaultHigh` 当「略高于默认」用。
        //    ✅ 正解：**名称降到 `.defaultLow`（250）、供应商留 `.defaultHigh`（750）** ——
        //       差值 500，谁让位一目了然，不依赖「750 vs 751」这种易错知识。
        //    角色分工：名称负责**可截断**（`byTruncatingMiddle`，前后缀都要留住），
        //    供应商负责**必须完整**。⛔ 别把这两条反过来。
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        vendorLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // 名称与供应商**同一行**（参考图就是一行：「DeepSeek-V4.1-Flash 深度求索」）
        let titleRow = UIStackView(arrangedSubviews: [nameLabel, vendorLabel, UIView()])
        titleRow.axis = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .firstBaseline

        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        docsButton.addTarget(self, action: #selector(docsTapped), for: .touchUpInside)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

        let actions = UIStackView(arrangedSubviews: [editButton, docsButton, deleteButton])
        actions.axis = .horizontal
        actions.spacing = 8
        actions.alignment = .center

        // 第一行：图标 + 名称 + 供应商。
        // 🔴 2026-10-16 用户：「cell 有点拥挤」⇒ 行尾三颗按钮**移到第二行**
        //    （原来四样挤一行：图标 + 长模型名 + 供应商 + 三颗 36×36 按钮，名称被压得最狠）。
        //    移下去之后第一行独占整宽，名称不再被按钮抢宽度。
        // 🔴 这一层必须 `isUserInteractionEnabled = false` —— 否则点它会被这一层吃掉，
        //    `didSelectRowAt`（点行 → 进编辑）就永远不触发。
        //    ☠️ ⛔ 别为了「两行」把 infoRow 和 actions 套进一个外层 VStack 再整体管交互：
        //    UIStackView 的 hit-testing 是**单向门**，父级关掉交互后子级设 true 也收不到
        //    （三颗按钮会集体失灵）。⇒ 两行是**兄弟**，直接挂在 contentView 下。
        let infoRow = UIStackView(arrangedSubviews: [iconView, titleRow])
        infoRow.axis = .horizontal
        infoRow.spacing = 12
        infoRow.alignment = .center
        infoRow.isUserInteractionEnabled = false

        contentView.addSubview(infoRow)
        contentView.addSubview(actions)
        iconView.snp.makeConstraints { make in make.width.height.equalTo(28) }
        for button in [editButton, docsButton, deleteButton] {
            button.snp.makeConstraints { make in make.width.height.equalTo(36) }
        }
        infoRow.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(20)
            make.trailing.equalToSuperview().offset(-16)
            make.top.equalToSuperview().offset(12)
        }
        // 第二行：三颗按钮**靠左**，左缘与模型名称文本对齐（不是与图标对齐）——
        // 20（leading）+ 28（图标）+ 12（infoRow spacing）= 60，正是 nameLabel 的起点。
        // 🔴 2026-10-16 用户：「三个按钮靠左侧与模型名称文本对齐」（前一刻刚让它们下移）。
        actions.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(60)
            make.top.equalTo(infoRow.snp.bottom).offset(5)
        }
        // 行高由 `rowHeight = 96` 定：12（上）+ 28（图标行）+ 10（行间距）+ 36（按钮行）
        // ⇒ 内容 86，底部余 10，上下大致均衡。底部不设约束（给了会与 rowHeight 打架）。
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 行尾那一颗方形图标按钮。
    ///
    /// 🔴 **命中区必须撑满按钮自身**（铁律）：`UIButton` 的命中区默认等于 label 边界，
    ///    图标只有 ~16pt ⇒ 手指点不中。做法是给按钮一个 36×36 的尺寸约束（见 `init`），
    ///    图标本身居中 —— 这样命中区就是 36×36。
    ///
    /// 🔴 图标**视觉大小**用 `SymbolConfiguration` 单独压，⛔ 别去缩按钮尺寸：
    ///    2026-10-16 用户反馈「文字小、按钮大」——SF Symbol 默认渲染（~20pt）在第二行
    ///    三连排时视觉重量远超第一行文字。pointSize 15 ⇒ 与第一行 17/14pt 文字同量级，
    ///    而命中区仍是 36×36（铁律与观感各管一条，别互相将就）。
    private static func makeActionButton(symbol: String) -> UIButton {
        let b = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        b.setImage(UIImage(systemName: symbol, withConfiguration: config), for: .normal)
        b.tintColor = .secondaryLabel
        return b
    }

    func configure(with entry: AICustomModel) {
        // 品牌图标（asset 优先）+ 符号兜底；容器 28×28 + `scaleAspectFit` 会把它收到框内
        iconView.image = entry.iconImage(pointSize: 17)
        nameLabel.text = entry.displayName
        // 行尾小字 = 供应商 + **最多一个**状态标记。
        //
        // 🔴 2026-10-14 新增「还没配齐」这一档：会话页那个选择器**不再列没配齐的条目**
        //    （用户：「如果没有在设置页面模型内配置，这里不显示」）⇒ 那些条目现在**只在这里**
        //    见得到，而这里此前不带任何标记（`vendorLabel` 只有供应商名）——
        //    于是选择器空态的「点下方「管理模型」补上地址和 API Key」会把用户丢进
        //    一个**看不出哪条有问题**的页面，只能逐条点开猜。
        //    本页是「配置」的地方，缺什么就该在这里看得见。
        //
        // 🔴 2026-10-16 用户要求「模型列表内『当前使用』字样去掉」⇒ 行上**只剩这一个标记**
        //    （原来还有一个「%@ · 当前使用」，与 Mac 侧 10-14 的处理同款：本页只列清单，
        //    不回答「在用哪个」—— 那看会话页胶囊/选择器里的打勾）。
        // ⚠️ 这一行还有名称（可截断，行宽有限）：`深度求索 · 还没配齐` 已接近上限，
        //    ⛔ 别再往这行加**装饰性**标记（会把名称挤到几乎看不见）。
        let ready = AIModelCatalog.isReady(entry)
        if !ready {
            vendorLabel.text = String(format: L("%@ · 还没配齐"), entry.vendorDisplayName)
        } else {
            vendorLabel.text = entry.vendorDisplayName
        }
        // 认不出预设（手改 JSON 写了个没见过的 vendor 名）⇒ 没有文档入口。
        // ⚠️ 这里用 `isHidden` 而**不是**把它从栈里拿掉：拿掉会让按钮位置左右跳，
        //    而且必须在复用前恢复，容易漏（见 `prepareForReuse`）。
        docsButton.isHidden = (entry.documentationURL == nil)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onEdit = nil
        onOpenDocs = nil
        onDelete = nil
        docsButton.isHidden = false
    }

    @objc private func editTapped() { onEdit?() }
    @objc private func docsTapped() { onOpenDocs?() }
    @objc private func deleteTapped() { onDelete?() }
}
