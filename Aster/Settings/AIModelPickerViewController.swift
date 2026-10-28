//
//  AIModelPickerViewController.swift
//  AIModule
//
//  模型选择器（底部弹出的列表）：从**已配置的模型**里挑一个，选中即「这个窗口之后用哪条配置」。
//
//  ## 🔴 2026-10-14 起它只剩一件事（改造前是两件事）
//  改造前有两个入口、两个语义：
//  - 设置页那一栏 → `scope: .settings`，**单平台**列表，选择结果落「配置槽」=「这个平台我配了哪个模型」；
//  - 会话页那颗胶囊 → `scope: .session`，**跨平台**列表，选中 = 换平台 + 换模型（写会话槽 + `currentProvider`）。
//  JSON 化之后**设置页不再配模型**（它改成了「自定义模型」清单页，只回答「清单里有哪些」），
//  于是这个选择器只剩会话页一个入口，也只剩一个问题：**这一会儿用清单里的哪一条**。
//  ⇒ `scope` 整个删掉；「换平台」这个说法也不再成立（一条配置自带地址，平台是配置的属性，不是开关）。
//
//  ## 列表从哪来
//  `AIModelCatalog.readyChoices()` —— 读 `Documents/models.json`，**按文件里的原顺序**：
//  用户把某条提到第一行，这里就跟着变（所以本页刻意**不重排**、也不把当前项顶到最前）。
//  ⛔ 不列服务端 `/models` 的候选：那些用户没配过、点了也发不出去。
//  要「加一条新的」走本页底部那颗「管理模型」→ 清单页 → 表单。
//
//  ## 🔴 2026-10-14 两处收窄（用户原话：「iOS 端 AIModelPickerViewController 内，如果没有在
//  设置页面模型内配置，这里不显示，此页面也不需要搜索功能」）
//
//  **① 只列「配齐的」条目**（`readyChoices()`，判据 = 地址 / 模型名 / Key 三项都有，
//     见 `AIModelCatalog.readyChoices` 的注释）。
//     为什么「读 models.json」还不够 —— 清单里本来就躺着一批**点不动**的条目：
//     · 表单的保存门槛只有「模型名非空」，**Key 允许留空**（先建条目后补 Key 是刻意的）；
//     · 迁移（`AIModelStore.seedIfNeeded`）的门槛是「有模型名 **或** 有 Key」，
//       老版本选过模型名、从没填 Key 的那些会原样迁进来。
//     ⇒ 这些条目此前在本页会带一句「… · 还没配齐」，点下去只换来一次 401。
//     ⚠️ **清单页仍然列全部**（含没配齐的）：那一页是「配置」的地方，用户正需要看见
//        「我这条还缺 Key」才能去补。两页的差别是**刻意**的（口径写在 `readyChoices()` 上）。
//
//  **② 删掉搜索框**：本页列的就是「我配好的那几条」（常态个位数），
//     一个用来筛个位数的搜索框白白多占一行、多一条焦点路径，还多一套要跟着语言重建的文案。
//     ⚠️ 连带删掉的是**整条搜索链路**：输入框 + `keyword` 状态 + 两个 target + 命中筛选 +
//        「没有匹配的模型」那一支空态。⛔ 别只把输入框藏起来 ——
//        留着一个恒为空的 `keyword` 会让「列表为什么少了」变成一件要读代码才知道的事。
//
//  ⚠️ 落库**仍由调用方做**（本页只 `onPick` 回传整项）：写配置的入口只有 `AIConfig`。
//

import UIKit
import SnapKit
import AICore

final class AIModelPickerViewController: UIViewController {

    // MARK: - 输入 / 回调

    /// 打开那一刻「正在用」的那一条 id（**快照**）。
    ///
    /// ⚠️ 由调用方传入而不是本页现读 `AIConfig.currentID`：模态期间值可能被别处改
    ///    （配置变更广播会刷各处 UI），按快照打勾，用户看到的勾至少与他打开那一刻一致。
    private let currentID: String

    /// 选中回调（主线程）。回传整项（含 id）——写哪个槽由调用方决定。
    private let onPick: (AIModelCatalog.AIModelChoice) -> Void

    // MARK: - UI

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.backgroundColor = .systemBackground
        tv.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        tv.dataSource = self
        tv.delegate = self
        tv.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        return tv
    }()

    /// 空态提示（盖在列表上居中）
    private lazy var emptyLabel: UILabel = {
        let l = UILabel()
        l.font = AIChromeFont.ui(14)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        l.isHidden = true
        return l
    }()

    /// 底部那颗「管理模型」——**任何情况下都在**。
    ///
    /// 🔴 它是「列表里没有我想要的那条」时的**唯一**出路（改造前那颗「手动输入模型名」的位置）。
    ///    ⛔ 别把它藏掉：清单为空时它更是唯一能走的一步。文案随之变（见 `refreshManageTitle`）。
    private lazy var manageButton: UIButton = {
        let b = UIButton(type: .system)
        b.titleLabel?.font = AIChromeFont.ui(16)
        b.backgroundColor = .secondarySystemBackground
        b.layer.cornerRadius = 12
        b.addTarget(self, action: #selector(manageTapped), for: .touchUpInside)
        return b
    }()

    private static let cellID = "AIModelPickerCell"

    // MARK: - 生命周期

    /// - Parameters:
    ///   - currentID: 打开那一刻「正在用」的那条（打勾用）。清单空时传空串即可。
    ///   - onPick: 选中回调（主线程）。**落库由调用方做**（`AIConfig.currentID = choice.id`）。
    init(currentID: String, onPick: @escaping (AIModelCatalog.AIModelChoice) -> Void) {
        self.currentID = currentID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = L("选择模型")
        // 这一页与「自定义模型」清单页是两件事：那里是**配置**（长期），这里是**这一会儿用哪个**。
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close,
                                                           target: self,
                                                           action: #selector(closeTapped))
        // 高度（半屏起步）在上层设：被 present 的是包着本页的 UINavigationController，
        // detents 写在它身上最直接（见 `AIModuleViewController.presentSessionModelPicker`）
        setupUI()
        // 🔴 进页面先重读 JSON：用户可能刚在「文件」/ 访达里手改过这份文件
        //    （mtime 变了才真读，热路径上只是一次 stat）。
        AIConfig.reloadModels()
        refreshManageTitle()
        refreshEmptyState()
    }

    // MARK: - 布局

    private func setupUI() {
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        view.addSubview(manageButton)

        manageButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.trailing.equalToSuperview().offset(-16)
            make.bottom.equalTo(view.safeAreaLayoutGuide).offset(-12)
            make.height.equalTo(46)
        }
        // 搜索框没了 ⇒ 列表直接从安全区起（顶距 8 只是给第一行留点呼吸，
        // 与底部那颗按钮的 12 大致对称）
        tableView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide).offset(8)
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(manageButton.snp.top).offset(-8)
        }
        emptyLabel.snp.makeConstraints { make in
            make.center.equalTo(tableView)
            make.leading.equalToSuperview().offset(32)
            make.trailing.equalToSuperview().offset(-32)
        }
    }

    // MARK: - 派生

    /// 本页展示的那几条 = **配齐的**已配置条目（见文件头 ①）。
    ///
    /// 🔴 名字**刻意不叫 `choices`**（改造前那版叫 `displayChoices`）：本页里有**两个**
    ///    「choices」——这个计算属性和共享层的 `AIModelCatalog.choices()`（整份清单）——
    ///    而本页恰恰要**同时**用两者（下面 `refreshEmptyState` / `refreshManageTitle` 就在比它们）。
    ///    同名会让人一眼看漏「这里其实用了两份不同的名单」，那个误读不报错、只改错行为。
    private var readyRows: [AIModelCatalog.AIModelChoice] {
        AIModelCatalog.readyChoices()
    }

    /// 空态文案 —— **三种空法要说三句不同的话**，否则用户不知道下一步该去哪儿：
    /// - 清单**一条都没有** ⇒ 去「添加模型」加一条；
    /// - 清单**有**、但一条都没配齐 ⇒ 他其实有配置，只是缺 Key / 地址 ⇒ 该去「管理模型」补；
    private func refreshEmptyState() {
        emptyLabel.isHidden = !readyRows.isEmpty
        guard readyRows.isEmpty else { return }
        let all = AIConfig.allModels
        if all.isEmpty {
            emptyLabel.text = L("还没配置模型\n点下方「管理模型」加一条")
        } else {
            emptyLabel.text = L("这些模型还没配好\n点下方「管理模型」补上地址和 API Key")
        }
    }

    /// 底部那颗按钮的文案：清单空时说「添加」、非空时说「管理」（同一个去处，不同的说法）。
    ///
    /// ⚠️ 判据用**整份清单**（`AIModelCatalog.choices()`）而不是本页那几条（`readyRows`）——
    ///    清单里有、只是没配齐的情形下，用户要的是「进去补 Key」（管理），不是「再加一条」（添加）。
    private func refreshManageTitle() {
        let title = AIModelCatalog.choices().isEmpty ? L("添加模型…") : L("管理模型…")
        manageButton.setTitle(title, for: .normal)
    }

    // MARK: - 动作

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    /// 🔴 「管理模型」→ 把「自定义模型」清单页**push 进本页自己的导航栈**。
    ///
    /// 为什么在这里 push、而不是让调用方给个闭包：被 present 的是**包着本页的那个 nav**
    /// （见 `AIModuleViewController.presentSessionModelPicker`），调用方手上没有它 ——
    /// 要接这一手就得让调用方先去把 picker 的 `navigationController` 取回来，
    /// 多一层来回还没有更清楚。本页与清单页同属一个模块，直接 push 是这里最短的路。
    ///
    /// ⚠️ 清单页里点「添加模型」会再 push 表单 —— 于是这一条栈是
    ///    「选择模型 → 自定义模型 → 添加模型」，返回键一层层退回来，符合用户的心理模型。
    ///
    /// ⚠️ 这里**不再有** `view.endEditing(true)`（改造前那版有）：本页已无任何输入框
    ///    （搜索框于 2026-10-14 删除，见文件头 ②），收键盘是句空话。
    @objc private func manageTapped() {
        navigationController?.pushViewController(AIAddModelViewController(editingModel: nil), animated: true)
    }

    private func finish(with choice: AIModelCatalog.AIModelChoice) {
        onPick(choice)
        dismiss(animated: true)
    }
}

// MARK: - 列表

extension AIModelPickerViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        readyRows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        // 取一份快照再按下标取（每次回调各算一次，与原实现同一节奏）
        let rows = readyRows
        guard rows.indices.contains(indexPath.row) else { return cell }
        let choice = rows[indexPath.row]
        let isCurrent = !currentID.isEmpty && choice.id == currentID

        var content = cell.defaultContentConfiguration()
        content.text = choice.title
        // 等宽字体更贴近「标识符」的观感，长模型名也更容易逐字比对
        // 🔴 字号走 `AIChromeFont`（2026-10-22 接字号档位）：等宽那一支有专用重载
        //    （`uiMonospaced`），⛔ 别退回裸 `monospacedSystemFont`。
        content.textProperties.font = AIChromeFont.uiMonospaced(14)
        // 副标题 = 供应商备注（`choice.note`）。
        // 🔴 2026-10-16 用户要求「模型列表内『当前使用』字样去掉」⇒ 不再拼「当前使用 · 」
        //    前缀（与 Mac 侧 10-14 同款：当前项由行尾打勾表达，写进文案等于两处口径）。
        // 🔴 改造前这里还有一支「… · 还没配齐」（`choice.isReady` 为假时）—— 2026-10-14 连同
        //    那一支一起删了：列表**恒为**配齐的条目（`readyChoices()`，见文件头 ①），
        //    没配齐的压根进不来。留一个永远走不到的分支，只会让人以为这里还会列它们。
        content.secondaryText = choice.note
        content.secondaryTextProperties.font = AIChromeFont.ui(12)
        content.secondaryTextProperties.color = .secondaryLabel
        // 小图标 = 供应商预设给的（asset 优先，认不出时退回中性符号，见 `AIModelChoice.iconImage`）
        content.image = choice.iconImage(pointSize: 17)
        content.imageProperties.tintColor = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = isCurrent ? .checkmark : .none
        cell.tintColor = .systemBlue
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let rows = readyRows
        guard rows.indices.contains(indexPath.row) else { return }
        finish(with: rows[indexPath.row])
    }
}
