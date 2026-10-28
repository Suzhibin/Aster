//
//  AIListPickerViewController.swift
//  Aster
//
//  「供应商 / 模型名称」的**模态选择页** —— 2026-10-14 新建。
//
//  ## 🔴 为什么是「模态弹一个卡片」而不是「字段正下方行内展开」
//  改造前，「添加模型」表单里那两个下拉是**行内展开面板**（`contentStack` 的一个
//  arrangedSubview，点一下切 `isHidden`），形态照的是 2026-10-13 用户给的参考图。
//  用户 2026-10-14 的原话把这条推翻了：
//    > 「涉及到 iOS 端**供应商和模型的弹窗 使用模态弹页面处理**」
//  ⇒ 两个下拉统一改成：点那颗字段 → **present 一个模态卡片**。
//
//  ## 形态：矮卡片（2026-10-14 当天**第二次**修正）
//  第一版用的是系统默认的 `.pageSheet` = **近乎整屏**，用户紧接着要求：
//    > 「供应商 和 模型 弹窗 都不要全屏幕，风格和点击用户名的弹窗一样」
//  ⇒ 沿用**矮卡片**那一套呈现口径（原注释以账号弹窗为参照 —— 那个弹窗 2026-10-27 已随
//    「删掉头像和名称」一起删除，但**这套形态口径本身仍然有效**，照下面几条写就对了）：
//    · iOS 16+ `Detent.custom { 刚好包住内容 }`；iOS 15 没有 `.custom` ⇒ 退 `.medium()`；
//    · `prefersGrabberVisible = true`；⛔ **高度里绝不加底部安全区**（系统 sheet 自己会补）。
//  ☠️ 与那个已删弹窗的**唯一差别**：它是**裸 VC**（没有 navigationItem，包 nav 只会多一条空栏）；
//     这里包一层 `UINavigationController` —— 标题与「取消」挂在 `navigationItem` 上。
//  ☠️ 高度**必须 clamp**：模型候选可能几十条，不设上限卡片会顶到全屏 = 回到被推翻的形态。
//     超出部分**在卡片内滚动**（⛔ 别为此加 `.large()` detent 把全屏那档又放回来）。
//
//  ## 为什么这个改法在 iOS 上其实更好
//  ① 行内面板会把下面的「API Key / 模型名称」整段**顶下去** —— 展开一下版面跳一次；
//     模态卡片**一个像素都不动**上面的表单。
//  ② 行内面板的高度受可视区限制（键盘一弹更惨），而模型候选可能几十条；
//     卡片内滚动 + 搜索框才装得下（Mac 那边用的浮层之所以限高，是因为它没有滚动余量）。
//  ⚠️ 与 Mac 侧**刻意不同形态**：那边是 `.overlay` 浮层（窗口宽、不挡上下文），
//     iOS 屏窄 ⇒ 系统 sheet 才是原生形态。⛔ 别把浮层那套搬过来。
//
//  ## 两路共用一个类
//  供应商（5 条、**无搜索**）与模型（几十条、**有搜索**）结构只差两处：
//  「选项从哪来」与「有没有搜索框」⇒ 用 `Content` 一个枚举分派，
//  ⛔ 别复制成两个 VC —— 两份的下一步一定是「取消按钮的文案只改了一边」。
//
//  ## 🔴 供应商列表里**没有 `.custom`**
//  与 Mac 侧 `providerRows` 同一条理由（那边注释更全）：本表单的「服务地址」栏同日被删，
//  选了「自定义」也没有任何地方能填地址 ⇒ 那一条会存成一个永远打不通的配置。
//  ⚠️ 枚举里的 `.custom` 仍在（手改 JSON 的 `"vendor": "custom"` 条目要能正常显示）。
//
//  ## 选中判据
//  供应商按 `AIProviderKind` 比、模型按**条目 id** 比 —— 与表单那份草稿是同一个口径。
//  回传用 `Pick` 枚举（不是裸 String）：供应商那一路回的是**枚举值**，
//  免得将来拿 rawValue 反查（模型名与供应商名理论上可能撞，见 Mac 侧 `MacAddModelRowModel` 那条注释）。
//

import UIKit
import SnapKit
import AICore

final class AIListPickerViewController: UIViewController {

    // MARK: - 对外

    /// 这一页在选什么。
    enum Content {
        /// 供应商 —— 固定的五家官方预设（⛔ 不含 `.custom`，见文件头）
        case provider(current: AIProviderKind)
        /// 模型名称 —— 该家的候选清单（内置 + 上次「测试连接」拉到并缓存下来的）
        case model(entries: [AIModelCatalog.AIModelEntry], current: String)
    }

    /// 选中的结果。
    enum Pick {
        case provider(AIProviderKind)
        case model(String)
    }

    // MARK: - 状态

    private let content: Content
    private let onPick: (Pick) -> Void
    private var keyword = ""

    /// 供应商那一路的选项（⛔ `.custom` 不在其中，见文件头）。
    private var providerOptions: [AIProviderKind] {
        AIProviderKind.allCases.filter { $0 != .custom }
    }

    private var modelEntries: [AIModelCatalog.AIModelEntry] {
        guard case .model(let entries, _) = content else { return [] }
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { $0.id.lowercased().contains(trimmed) }
    }

    private var isModelPicker: Bool {
        if case .model = content { return true }
        return false
    }

    // MARK: - 尺寸

    private enum Metric {
        /// 卡片里那一行 —— `.subtitleCell()`（主标题 + 一行小字）的**估算**高度。
        /// ⚠️ 只是**估算兜底**：布局完成后一律以 `tableView.contentSize` 为准（见 `sheetHeight`）。
        ///    若副标题折成两行，实测会比这高 ⇒ 估算这支只用于「布局还没跑完」的第一次，
        ///    真正定高走实测，所以这值宁大勿小（大了只是多一截空白，小了会裁最后一行）。
        static let rowHeight: CGFloat = 64
        /// 搜索框那一整条（**只有模型那一路有**）—— 与 `searchContainer` 的约束一致（8 + 38 + 8）。
        static let searchHeight: CGFloat = 54
        /// 导航栏高（估算用兜底，实测那一支直接读 `navigationBar.frame.height`）。
        static let navBarHeight: CGFloat = 44
        /// `.insetGrouped` 自带的上下段间距（分组表在首行前 / 末行后各留一截）。
        /// 只在**估算**那一支用：走实测 `contentSize` 时它已经含在里面了，加了就重复。
        static let groupedChrome: CGFloat = 36
        /// 卡片底部留白。☠️ **绝不能**再加底部安全区 —— 系统 sheet 会自己补一次，
        ///    实测（账号弹窗 2026-10-10）会因此凭空高出 34pt。
        static let bottomPadding: CGFloat = 8
        /// 亚像素安全余量：实测高度可能是小数，向下取整的 sheet 会差不到 1pt 把末行底边压掉。
        ///    加 1pt 永不让「刚好」变成「少 1pt 裁一行」。
        static let safety: CGFloat = 1
        /// 上限 = 可用高度的比例。☠️ 没有它，几十条模型候选会把卡片顶到全屏。
        static let maxHeightRatio: CGFloat = 0.72
        /// 兜底高（`picker` 已被释放 / 还没布局时）—— 约「一条搜索 + 四行」的量。
        static let fallbackHeight: CGFloat = 320
    }

    /// 卡片希望的**内容高**（**不含**底部安全区，见 `Metric.bottomPadding`）。
    ///
    /// 🔴 **先估后量**两档精度：`present` 那一刻 view 还没布局（`contentSize` 是 0）
    ///    ⇒ 先用「行数 × `rowHeight`」估一个；布局完成后 `viewDidAppear`
    ///    拿**实测值**调 `invalidateDetents()` 校准 ⇒ 最终高度贴合内容。
    ///    ⛔ 别省掉校准（只靠估算会让卡片底部多/少一截空白）。
    ///
    /// ☠️ **实测那一支只抓「高度」，不抓绝对坐标**：
    ///    导航栏占多高（含系统抓手让位）直接读 `navigationBar.frame.height`（就是个 44 上下的值）；
    ///    列表占多高读 `tableView.contentSize.height`（`.insetGrouped` 的段间距已含在内）；
    ///    搜索条占多高读 `searchContainer.frame.height`（布局完后是 54）。
    ///    三者都是「相对自身多高」，加起来就是卡片内容高 —— **不混坐标系**，
    ///    也就不会像第一版那样把 `navigationBar.frame.maxY`（绝对坐标）和
    ///    `tableView.frame.minY`（相对 picker.view 的坐标）加在一起算错。
    private var sheetHeight: CGFloat {
        let navBarH = navigationController?.navigationBar.frame.height ?? Metric.navBarHeight
        let listed = tableView.contentSize.height
        // 🔴 实测条件更宽：只要有「导航栏高 + 列表真实高度」就走实测（不再要求 navBottom>0）。
        //    副标题折行的行、几十行的模型清单，全靠这一步拿到真值，才不会裁末行 / 留大片空。
        if navBarH > 0, listed > 0 {
            return navBarH + listed + Metric.bottomPadding + Metric.safety
        }
        // 还没布局（`present` 当场那一次）⇒ 用估算顶一版，`viewDidAppear` 会立刻校准。
        // ⚠️ 这里必须自己把 `.insetGrouped` 的段间距算进去（实测那一支已含，别重复加）。
        let rows = isModelPicker ? modelEntries.count : providerOptions.count
        return Metric.navBarHeight + CGFloat(max(rows, 1)) * Metric.rowHeight
            + Metric.groupedChrome + Metric.bottomPadding + Metric.safety
    }

    /// 上一次上报给 detent 的高度 —— 只在**真变了**时才 invalidate，见 `syncSheetHeight()`。
    private var lastAppliedHeight: CGFloat = 0

    // MARK: - UI

    private static let cellID = "AIListPickerCell"

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.backgroundColor = .systemGroupedBackground
        tv.dataSource = self
        tv.delegate = self
        tv.rowHeight = UITableView.automaticDimension
        // 🔴 `estimatedRowHeight` **必须是正数**（2026-10-14 修）：这里原写成 `0`（想「关掉估算
        //    让 `contentSize` 立刻是真值」），结果**每一格的副标题都被截掉一半** ——
        //    `estimatedRowHeight = 0` 会让 `contentConfiguration`（`subtitleCell()`）的自撑高
        //    算不出副标题那一行，行高只够主标题 ⇒ 分隔线紧贴着被切断的副标题。
        //    ⚠️ 本仓其它列表页（`AIDocuments` 72 · `AIChatSearch` 76 · 会话页 80）**一律给正数**，
        //    只有这一处写了 0 ⇒ 就是它。内容实测约 64pt，估算取 60 足够贴近。
        //    实测真值由 `viewDidAppear` 的 `syncSheetHeight()` 兜底，⛔ 不必再靠 0 去逼 `contentSize`。
        tv.estimatedRowHeight = 60
        // 拖列表就能收键盘（矮卡片里键盘占了半张卡，这点比整屏那版更要紧）
        tv.keyboardDismissMode = .interactive
        tv.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        return tv
    }()

    private lazy var searchField: UITextField = {
        let f = UITextField()
        f.placeholder = L("搜索")
        // 🔴 字号走 `AIChromeFont`（2026-10-22 接字号档位）：本页是**每次现搭的模态卡片**
        //    （`present(content:from:onPick:)` 里新建）⇒ 构造时现读就是当前档位。
        f.font = AIChromeFont.ui(15)
        f.borderStyle = .none
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.spellCheckingType = .no
        f.clearButtonMode = .whileEditing
        f.returnKeyType = .done
        f.addTarget(self, action: #selector(keywordChanged), for: .editingChanged)
        return f
    }()

    // MARK: - 生命周期

    private init(content: Content, onPick: @escaping (Pick) -> Void) {
        self.content = content
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 从 `host` 弹出选择页（**矮卡片**，形态口径见文件头）。
    ///
    /// 🔴 **呈现配置只此一处** —— 表单里那两个字段都调这里，⛔ 别在调用点各配一份
    ///（配置散成两份时，验过的与线上跑的就不是同一套参数）。
    ///
    /// ⚠️ detent 的闭包**只 weak 抓 picker**、不抓 `host`：闭包会被 sheet 一直持有，
    ///    强抓宿主会把整个表单拽到弹窗关闭之后。
    /// ⚠️ 包一层 `UINavigationController`：标题与「取消」都挂在 `navigationItem` 上
    ///（与账号弹窗那个裸 VC **刻意相反** —— 那边没有 navigationItem 可挂，包一层只会多一条空栏）。
    static func present(content: Content,
                        from host: UIViewController,
                        onPick: @escaping (Pick) -> Void) {
        let picker = AIListPickerViewController(content: content, onPick: onPick)
        let nav = UINavigationController(rootViewController: picker)
        nav.modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *), let sheet = nav.sheetPresentationController {
            if #available(iOS 16.0, *) {
                // ⚠️ 闭包里读的是 picker **当下**的内容高（布局完以后是真实值，见 `sheetHeight`）
                //    ⇒ 搜索过滤导致行数变化时，`syncSheetHeight()` 会让它重算一次。
                sheet.detents = [.custom { [weak picker] context in
                    min(picker?.sheetHeight ?? Metric.fallbackHeight,
                        context.maximumDetentValue * Metric.maxHeightRatio)
                }]
            } else {
                // iOS 15 没有 `.custom` ⇒ 与账号弹窗同一个退路（半屏，下面会空一截）。
                sheet.detents = [.medium()]
            }
            sheet.prefersGrabberVisible = true
        }
        host.present(nav, animated: true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        switch content {
        case .provider: title = L("选择供应商")
        case .model:    title = L("选择模型")
        }
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: L("取消"),
                                                           style: .plain,
                                                           target: self,
                                                           action: #selector(cancelTapped))
        // 矮卡片 + 搜索框的必然组合：键盘一弹会盖住大半张列表（见 `keyboardWillChange`）。
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification,
                                               object: nil)
        setupUI()
        // 🔴 立刻把数据铺出来 ⇒ `viewDidAppear` 量高度时 `contentSize` 已经是真值
        //    （否则首帧没有行、`contentSize` 为 0，会掉回估算那一支，矮卡片可能裁末行）。
        tableView.reloadData()
    }

    /// ⚠️ 这一步**不够**（2026-10-14 实测）：`present` 当场那次布局里 `contentSize` 还是 0，
    ///    而之后 tableView 内部把行加载完**不会再改变 picker.view 的 bounds**
    ///    ⇒ 本回调不会再来第二次，卡片就永远停在估算值上
    ///    （症状：**最后一行被卡片底边裁掉**，第一版截图就是这么暴露的）。
    ///    真正的校准点在 `viewDidAppear`，那里一定已经渲染完。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        syncSheetHeight()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 🔴 **真正的校准点**（理由见 `viewDidLayoutSubviews` 那条注释）：此时
        //    `contentSize` 与 `navigationBar.frame` 都是实测值 ⇒ 卡片一次就量准，⛔ 别删。
        syncSheetHeight()
    }

    /// 内容高变了就让 sheet 重算 detent（高度贴合内容，不会多出一截空白）。
    ///
    /// 🔴 **只在真变了时**才 `invalidateDetents()`：它会触发新一轮布局 ⇒
    ///    无条件调用就与 `viewDidLayoutSubviews` 形成回路（界面会一直抖）。
    private func syncSheetHeight() {
        guard #available(iOS 16.0, *) else { return }
        let height = sheetHeight
        guard abs(height - lastAppliedHeight) > 1 else { return }
        lastAppliedHeight = height
        navigationController?.sheetPresentationController?.invalidateDetents()
    }

    /// 键盘遮住列表的那一段 —— 把列表的滚动区往下延同样长，
    /// 让用户能把内容滚到键盘上方（**卡片不长高**，那会回到「全屏」）。
    ///
    /// ⚠️ 这是改成矮卡片后**新引入**的问题：整屏那版卡片底部本来就远在键盘之上。
    ///    ⛔ 别省掉这段 —— 否则模型那一路的搜索等于废了（看得见输入框，看不见结果）。
    @objc private func keyboardWillChange(_ note: Notification) {
        guard isModelPicker,
              let raw = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else { return }
        // 键盘 frame 是**屏幕**坐标系 ⇒ 先转到本 view 再比（不转会得到完全错的 overlap）。
        let keyboard = view.convert(raw.cgRectValue, from: UIScreen.main.coordinateSpace)
        let overlap = max(0, view.bounds.maxY - keyboard.minY)
        tableView.contentInset.bottom = overlap
        // 🔴 `scrollIndicatorInsets` 的**取值** iOS 13 起弃用（赋值不禁）⇒ 这里改读写
        //    `verticalScrollIndicatorInsets`（同义，iOS 11 起可用），语义完全一致。
        tableView.verticalScrollIndicatorInsets.bottom = overlap
    }

    // MARK: - 布局

    private func setupUI() {
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide)
        }
    }

    // MARK: - 动作

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func keywordChanged() {
        keyword = searchField.text ?? ""
        tableView.reloadData()
        // 过滤后行数变了 ⇒ 卡片该跟着变矮（⛔ 不重算的话会留一截空白/裁掉最后一行）
        lastAppliedHeight = 0
        syncSheetHeight()
    }

    /// 选了一条 —— 回调 + 关掉本页。
    ///
    /// ⚠️ **先回调再关**（与账号弹窗那条相反）：这里回调只是往**表单的草稿**里写值，
    ///    不涉及「表单要 present 新页面」⇒ 不会撞 "already presenting"。
    private func pick(_ value: Pick) {
        onPick(value)
        dismiss(animated: true)
    }

    // MARK: - 行内容

    private func isCurrentProvider(_ kind: AIProviderKind) -> Bool {
        guard case .provider(let current) = content else { return false }
        return kind == current
    }

    private func isCurrentModel(_ id: String) -> Bool {
        guard case .model(_, let current) = content else { return false }
        return id == current.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 列表数据源

extension AIListPickerViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        isModelPicker ? modelEntries.count : providerOptions.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        cell.backgroundColor = .secondarySystemGroupedBackground
        if isModelPicker {
            guard modelEntries.indices.contains(indexPath.row) else { return cell }
            let entry = modelEntries[indexPath.row]
            // 用 subtitle 配置：模型名下面挂它那条说明（「旗舰 · 纯文本」这类）
            var config = UIListContentConfiguration.subtitleCell()
            config.text = entry.id
            config.secondaryText = entry.note
            // 🔴 字号走 `AIChromeFont`（2026-10-22 接字号档位）。这里**显式钉**文本样式
            //    （`.body` / `.footnote`）而不是让配置吃默认值：默认值不随档位走，
            //    本页就会是「半生效」——正是这一轮要消灭的东西（见 `AIChromeFont` 文件头）。
            config.textProperties.font = AIChromeFont.ui(.body)
            config.secondaryTextProperties.font = AIChromeFont.ui(.footnote)
            // 🔴 正文右侧给勾让位 —— 与下面那次 `aiApplyCheckmark` 是**成对的**（漏了它长名字会被勾压住）。
            config.directionalLayoutMargins.trailing = UITableViewCell.aiCheckmarkReserve
            cell.contentConfiguration = config
            cell.aiApplyCheckmark(isCurrentModel(entry.id))
        } else {
            guard providerOptions.indices.contains(indexPath.row) else { return cell }
            let kind = providerOptions[indexPath.row]
            var config = UIListContentConfiguration.subtitleCell()
            config.text = kind.displayName
            // 「打到哪儿去」这行小字是选供应商时唯一的信息量 —— ⛔ 别为了整齐把它去掉
            config.secondaryText = kind.subtitle
            // 字号显式钉（与上面那颗 subtitleCell 同一口径，见那边的注释）。
            config.textProperties.font = AIChromeFont.ui(.body)
            config.secondaryTextProperties.font = AIChromeFont.ui(.footnote)
            // 品牌图标（asset 优先）+ 符号兜底，规则见 `AIVendorIcon`。
            // ⚠️ `preferredSymbolConfiguration` 只对兜底的 SF Symbol 生效 —— asset 是
            //    24pt 的矢量图，尺寸由内容配置自己决定（视觉上略大于原 17pt 符号，这是
            //    换品牌图必然的变化，不是尺寸算错）。
            config.image = kind.iconImage(pointSize: 17)
            config.imageProperties.tintColor = .label
            config.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17)
            // 🔴 同上：给勾让位，与 `aiApplyCheckmark` 成对。
            config.directionalLayoutMargins.trailing = UITableViewCell.aiCheckmarkReserve
            cell.contentConfiguration = config
            cell.aiApplyCheckmark(isCurrentProvider(kind))
        }
        return cell
    }

    /// 一条候选都没有（离线 / 服务端清单为空 / 搜索没命中）时给一句话，
    /// 否则整页是空白 —— 用户读不出「是没数据还是界面坏了」。
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard isModelPicker, modelEntries.isEmpty else { return nil }
        return L("没有匹配项")
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if isModelPicker {
            guard modelEntries.indices.contains(indexPath.row) else { return }
            pick(.model(modelEntries[indexPath.row].id))
        } else {
            guard providerOptions.indices.contains(indexPath.row) else { return }
            pick(.provider(providerOptions[indexPath.row]))
        }
    }
}
