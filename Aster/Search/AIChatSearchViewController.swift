//
//  AIChatSearchViewController.swift
//  AIModule
//
//  搜索页（入口：侧滑菜单顶部的搜索框）。
//
//  与设置页同构：**以 push 进导航栈为主**（返回键 / 边缘侧滑即返回），
//  宿主拿不到导航栈时退化成模态（外层套一个 `UINavigationController`）。
//  菜单里的搜索框是不可编辑的（`textFieldShouldBeginEditing` 返回 false 并回调宿主），
//  所以进来时这里才是真正的输入框，一进来就自动聚焦。
//
//  数据来源走注入的 `searchProvider`，本页不直连 `AIChatStore`：
//  菜单 / 设置页都不直接碰存储（配置走 AIConfig），搜索保持一致 ——
//  宿主想换数据源或加缓存都不用改本页。
//

import UIKit
import SnapKit
import AICore

public final class AIChatSearchViewController: UIViewController {

    // MARK: - 对外回调

    /// 搜索数据源：参数为关键词，返回命中列表（会在**后台线程**调用，实现里别再碰 UI）
    public var searchProvider: ((String) -> [AIChatSearchHit])?

    /// 点击某条结果（**整条命中记录**，不只是会话 id）。宿主负责关掉本页并打开该会话。
    ///
    /// 抛整条而不是只抛 id，是因为「打开会话」之外还要**定位**：命中消息的 `messageId`
    /// （标题命中为 nil）要一路带下去，让聊天页滚到那一条并高亮一下。
    public var onSelectHit: ((AIChatSearchHit) -> Void)?

    // MARK: - 数据

    private var hits: [AIChatSearchHit] = []

    /// 搜索跑在后台队列上，用递增序号**丢弃过期结果**：
    /// 用户连打字时先后发起多次搜索，慢的那次后回来不能盖掉新结果。
    private var searchToken = 0

    /// 待执行的那次搜索（输入抖动抑制）。
    ///
    /// 为什么必须有：`keywordChanged` 是**每按一个键**触发一次，而 `AIChatStore.search`
    /// 是「一次把全库消息读进内存 + 全文匹配」（见它的头部说明）。打 8 个字 = 8 次全表读
    /// + 8 次全文匹配，几千条时还「能用」，上万条就是**按一次键卡一下**。
    ///
    /// 200ms 是「打字停顿」与「手感不延迟」之间的常用折中；清空输入框、回车这两条路
    /// 刻意**不走它**（见 `keywordChanged` 与 `textFieldShouldReturn`）。
    private var pendingSearch: DispatchWorkItem?

    /// 抖动窗口时长
    private static let searchDebounceInterval: TimeInterval = 0.2

    // MARK: - 视图

    /// 放在导航栏 titleView 里的搜索框
    private lazy var searchField: UITextField = {
        let f = UITextField()
        f.placeholder = L("搜索对话")
        f.font = .systemFont(ofSize: 15)
        f.borderStyle = .roundedRect
        f.clearButtonMode = .whileEditing
        f.returnKeyType = .search
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.delegate = self
        f.addTarget(self, action: #selector(keywordChanged), for: .editingChanged)

        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        icon.tintColor = .secondaryLabel
        icon.contentMode = .center
        icon.frame = CGRect(x: 0, y: 0, width: 30, height: 36)
        f.leftView = icon
        f.leftViewMode = .always
        return f
    }()

    private lazy var tableView: UITableView = {
        let t = UITableView(frame: .zero, style: .plain)
        t.dataSource = self
        t.delegate = self
        t.register(AIChatSearchCell.self, forCellReuseIdentifier: AIChatSearchCell.reuseIdentifier)
        t.rowHeight = UITableView.automaticDimension
        t.estimatedRowHeight = 76
        t.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        t.keyboardDismissMode = .onDrag
        t.tableFooterView = UIView()
        return t
    }()

    /// 空态：没输入关键词 / 搜不到，两种文案共用这一个 label
    private lazy var emptyLabel: UILabel = {
        let l = UILabel()
        l.numberOfLines = 0
        l.textAlignment = .center
        l.font = .systemFont(ofSize: 14)
        l.textColor = .tertiaryLabel
        return l
    }()

    // MARK: - 生命周期

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L("搜索")
        view.backgroundColor = .systemBackground
        setupUI()
        // 观察 changeFrame 而不是 willShow / willHide：
        // 切换输入法、联想条高度变化只发这一条，漏了它列表就会被键盘盖住一截
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardFrameChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification,
                                               object: nil)
        updateEmptyState(keyword: "")
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 放在 willAppear（不是 viewDidLoad）：push 时 view 还没上屏，
        // 那时 becomeFirstResponder 经常不生效，键盘要等下一次点击才出来
        searchField.becomeFirstResponder()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        searchField.resignFirstResponder()
        // 页面正在走 → 丢掉还没到点的那次搜索（否则它会在返回动画里再跑一遍全表读）
        pendingSearch?.cancel()
        pendingSearch = nil
    }

    // MARK: - 布局

    private func setupUI() {
        // 搜索框直接占导航栏中间，省掉一整行高度（与系统搜索页一致）。
        //
        // ⚠️ titleView 这里**只能用 frame，不能用 SnapKit 约束宽度**，两个原因叠加：
        //
        // ① `navigationItem.titleView` 最终挂在 UINavigationBar 上，而 UINavigationBar 属于
        //    UINavigationController 的视图树，**不在本 VC 的 view 树里**。
        //    写 `make.width.equalTo(view.snp.width)` 会因「no common ancestor」直接抛异常崩溃：
        //    "Unable to activate constraint ... because they have no common ancestor."
        //    （此刻 searchField 的 superview 还是 nil —— 导航栏要等布局才接管它）
        //
        // ② 就算把参照物换掉，只要 searchField 交给 SnapKit，它就会被设成
        //    `translatesAutoresizingMaskIntoConstraints = false`；而导航栏是靠
        //    **frame + autoresizing** 摆放 titleView 的，没有约束可解算 → 宽度塌成 0。
        //
        // 所以：titleView 一律用 frame 定位，宽度在 `viewWillLayoutSubviews` 里跟随屏幕重算。
        navigationItem.titleView = searchField
        updateSearchFieldFrame()

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

    /// titleView 靠 frame 定位（原因见 `setupUI`）：宽度跟随当前 view 宽度，
    /// 左右各留 60pt 给返回按钮与安全边距。
    ///
    /// 放在 `viewWillLayoutSubviews` 而不是只在 `setupUI` 里设一次：
    /// 旋转、分屏、导航栏重新布局都会再走一遍，宽度能自适应；
    /// 首次进来时 `viewDidLoad` 里也调了一次，避免那一帧宽度是 0。
    private func updateSearchFieldFrame() {
        let width = max(120, view.bounds.width - 120)
        let target = CGSize(width: width, height: 36)
        // 值没变就别再设：反复设 frame 会让导航栏一遍遍重新布局
        guard searchField.frame.size != target else { return }
        searchField.frame = CGRect(origin: .zero, size: target)
    }

    public override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateSearchFieldFrame()
    }

    private func updateEmptyState(keyword: String) {
        guard hits.isEmpty else {
            emptyLabel.isHidden = true
            return
        }
        emptyLabel.isHidden = false
        emptyLabel.text = keyword.isEmpty
            ? L("输入关键词，搜索全部对话\n标题和聊天内容都会匹配")
            // ⚠️ 带参文案：中文原文里写 `%@`，外面套 `String(format:)` 填值 ——
            //    词表的 key 就是这句原文，英文档换成对应格式串（见 `AILocalization.swift`）。
            : String(format: L("没有找到与「%@」相关的内容"), keyword)
    }

    // MARK: - 搜索

    @objc private func keywordChanged() {
        let keyword = searchField.text ?? ""
        pendingSearch?.cancel()
        // 清空（含只剩空格）= 用户要看「没输入」的空态。这一拍等 200ms 只会显得迟钝，
        // 而且它不查库（`runSearch` 对空关键词直接清列表），没有任何开销
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            runSearch(keyword: keyword)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.runSearch(keyword: keyword)
        }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.searchDebounceInterval,
                                      execute: work)
    }

    private func runSearch(keyword: String) {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        searchToken += 1                 // 先自增：在飞的那次结果一律作废
        let token = searchToken

        guard !kw.isEmpty else {
            hits = []
            tableView.reloadData()
            updateEmptyState(keyword: "")
            return
        }

        // 在主线程取值再进后台：provider 可能被宿主替换，别在后台线程读 VC 属性
        let provider = searchProvider
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = provider?(kw) ?? []
            DispatchQueue.main.async {
                guard let self = self, token == self.searchToken else { return }   // 过期结果丢弃
                self.hits = result
                self.tableView.reloadData()
                self.updateEmptyState(keyword: kw)
            }
        }
    }

    // MARK: - 键盘遮挡

    /// 键盘高度 / 位置变化时调整列表底部 inset。
    /// 动画的时长与曲线都取通知里的值（系统键盘用的是私有曲线 7），
    /// 这样列表让位和键盘升降是同一节奏；`.beginFromCurrentState` 保证连续打字时不跳。
    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let frame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let overlap = max(0, view.bounds.maxY - view.convert(frame, from: nil).minY)
        let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0
        let curve = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue
            ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        let options = UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.tableView.contentInset.bottom = overlap
            self.tableView.verticalScrollIndicatorInsets.bottom = overlap
        }
    }
}

// MARK: - 搜索框

extension AIChatSearchViewController: UITextFieldDelegate {

    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // 回车 = 「我现在就要结果」，不等抖动窗口
        pendingSearch?.cancel()
        pendingSearch = nil
        runSearch(keyword: textField.text ?? "")
        textField.resignFirstResponder()
        return true
    }
}

// MARK: - 结果列表

extension AIChatSearchViewController: UITableViewDataSource, UITableViewDelegate {

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        hits.count
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AIChatSearchCell.reuseIdentifier,
                                                 for: indexPath)
        if let cell = cell as? AIChatSearchCell, indexPath.row < hits.count {
            cell.configure(with: hits[indexPath.row])
        }
        return cell
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < hits.count else { return }
        // 关页交给宿主（它才知道要 pop 还是 dismiss），本页把整条命中抛出去
        // （宿主还要用 messageId 定位到那一条，见 onSelectHit 的说明）
        onSelectHit?(hits[indexPath.row])
    }
}
