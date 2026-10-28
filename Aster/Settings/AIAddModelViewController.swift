//
//  AIAddModelViewController.swift
//  AIModule
//
//  「添加模型」表单 —— 2026-10-13 按参考图重做，2026-10-14 两轮改造（JSON 化 / 对齐 Mac）。
//
//  ## 与 Mac 端的关系：**同一份数据，同一套版面，各自一套控件**
//  读写全走 `AIModelStore`（唯一真值 = `Documents/models.json`）。
//  版面 = 标题「添加模型」→ 供应商（+ 查看文档）→ API Key（+ 眼睛 + 测试连接）→ 模型名称 → 取消 / 保存。
//  🔴 与 Mac 的 `MacAddModelView` **逐段同构**：那边删了哪一栏、这边就删哪一栏
//  （「服务地址」栏、整张「用量与计费」卡都是 2026-10-14 同日删的，见下面两段）。
//
//  ## 🗑️ 「服务地址」那一栏已删（2026-10-14，与 Mac 同日）
//  地址**恒等于供应商预设**（`vendor.defaultBaseURL`），由 `urlDraft` 携带（**不接 UI**）。
//  · 编辑既有条目时 `urlDraft` 先装它自己那份 url ⇒ 手改过地址的 `.custom` 条目
//    不会因为打开一次表单就被重置；只有**换供应商**才重置成该家的默认地址（那是刻意的）。
//  · 连带后果：供应商列表里**没有 `.custom`**（选了它也没有地方填地址，
//    那一条会存成一个永远打不通的配置）—— 见 `AIListPickerViewController` 文件头。
//  ⚠️ 因此界面上**再没有任何地方能填地址**，想给中转站 / 自建网关改地址只能手改 `models.json`。
//    这是用户点名的取舍，⛔ 别当成 bug 把那一栏加回来。
//
//  ## 🗑️ 「用量与计费」整张卡已删（2026-10-14，与 Mac 同日）
//  用户原话：「去掉 用量与费用」。删掉的是**整张卡**：标题行（刷新 / 清零统计）+ 累计文案
//  + 三档单价（命中 / 未命中 / 输出）+ 「恢复默认」+ 那句单价出处说明。
//  🔴 `pricingDraft` 的概念一并撤掉 —— 保存时**根本不再碰 `entry.pricing`**：
//    起点是「原来那条」⇒ 手改 JSON 写过的单价原样保留；没写过的（`pricing == nil`）
//    继续走 `AIConfig.defaultPricing`。⛔ 别「顺手」补一句 `entry.pricing = …`：
//    那会把默认值**实体化**进文件，用户手改过的单价也就被覆盖了。
//  ☠️ 功能代价写在案：iOS 侧**唯一**能看累计用量、能改单价的地方就是这里 ⇒ 现在**没地方看**了。
//    代码侧 `AIChatStore.usageTotal()` / `clearUsage()` / `AIUsageTotal` **一行没删**，要恢复只需把视图加回来。
//
//  ## 🔴 模型名**不能手填**（2026-10-14 第三轮，与 Mac 同日）
//  用户原话：「模型名称输入框**也不需要编辑功能**，和供应商一样点击就弹出模型列表」。
//  ⇒ 从「可编辑输入框 + 箭头」改成**纯按钮**（与供应商**共用同一个外观件** `AIAddModelFieldButton`）。
//  ☠️ `modelDraft` 的**用户**写入点因此只有 `pickModel(_:)`（下拉选中）与 `selectProvider`
//    （换供应商连带重置）；另有一个**非用户**写入点：`reloadAll()` 进页时给**新建**那条
//    预填该家的 `defaultModel`（2026-10-19 用户点名要的：供应商默认选上了，模型名也要选上）。
//    代价（用户点名的取舍）：清单拉不到 / 中转别名 / 实验模型名 ⇒ 只能手改 `models.json`。
//
//  ## 🔴 两个字段都是**模态选择页**（2026-10-14 用户要求）
//  用户原话：「涉及到 iOS 端**供应商和模型的弹窗 使用模态弹页面处理**」。
//  改造前它们是**行内展开面板**（`contentStack` 的 arrangedSubview + 切 `isHidden`，照 2026-10-13 那张参考图）。
//  ⇒ 现在点那颗字段 → `AIListPickerViewController.present(…)` 弹一整页。
//  ⛔ **别改回行内面板**：它会把下面的 API Key / 模型名称整段顶下去，展开一次版面跳一次。
//
//  ## 🔴 页脚（取消 / 保存）**钉在屏幕底部，不在滚动区里**
//  这一页在 iPhone 上内容超一屏，页脚若跟着滚动区走就**首屏看不到「保存」**
//  （真机截图里那两颗钮被屏幕下沿切掉一半）。而「保存」是这一页唯一的前进动作。
//  ⇒ 结构是「滚动区 + 固定页脚条」，`typecheck_aster.sh` 有反向断言盯着
//    「页脚⛔ 不许再被塞回 `contentStack`」。
//
//  ## 🔴 它编辑的是**一条配置**，不是「一个平台」
//  `editingModel: AICustomModel?`（`nil` = 新增）—— 一条配置自带地址与 Key。
//  **模型名是键**：改模型名 = 改键。表单负责把「老键那条」替换掉（`AIModelStore.save(_:replacing:)`），
//  ⛔ 别写成「老那条还在 + 多出新的一条」——同一模型标识存两条会让「当前用哪条」有歧义。
//
//  ## 🔴 入口
//  设置入口 →「自定义模型」清单页（`AICustomModelListViewController`）→ 本页。
//  ⇒ 本页永远是被 push 进来的，左上角交给系统返回键（`isModal` 那个参数已删）。
//
//  ## 🔴 草稿语义
//  改的都先落在本页的 `keyDraft` / `urlDraft` / `modelDraft` 里。
//  - 「保存」→ 写 `AIModelStore` + 关页面（**唯一落库路径**）；
//  - 「取消」/ 关闭 / 侧滑返回 / 系统返回键 → **全部丢弃**，库存里不会出现任何东西。
//    🔴 2026-10-16 用户要求：「没有点击保存按钮，模型列表也不要出现该数据」。
//    改造前 `viewWillDisappear` 有一次「兜底提交」（侧滑返回 = 保存），本意是
//    「不小心划到别丢 Key」，实际效果是填了一半返回也会**凭空多一条半成品**。
//    已删。现在与 Mac 端（⌘W 关窗 = 丢弃）口径一致：明确动作才落库。
//
//  ## ⛔ 这一页**不许**写 `AIConfig.currentID`
//  它是**编辑配置**，不回答「现在用哪个」。换当前模型的唯一入口是**会话页输入栏那颗胶囊**。
//  ⚠️ `typecheck_aster.sh` 有一条机械契约盯着这件事，改回去就报 ✗。
//

import UIKit
import SnapKit
import AICore

public final class AIAddModelViewController: UIViewController {

    // MARK: - 版面常量

    private enum Metrics {
        /// 字段高度（与参考图一致：各行控件等高）
        static let fieldHeight: CGFloat = 44
        static let fieldRadius: CGFloat = 10
    }

    // MARK: - 容器

    private let scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.alwaysBounceVertical = true
        sv.keyboardDismissMode = .interactive
        return sv
    }()

    private let contentStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.spacing = 16
        sv.alignment = .fill
        return sv
    }()

    // MARK: - 输入 / 状态

    /// 被编辑的那一条；`nil` = 新增。
    ///
    /// 🔴 它是**快照**：本页打开时取一份，之后不再回读（模态期间配置可能被别处改）。
    ///    表单只拥有它的一部分字段（供应商 / 地址 / 模型名 / 能力位 / Key），
    ///    其余（`name` / `maxInputTokens` / `maxOutputTokens` / `supportsToolCall` / `pricing`）
    ///    **原样保留** —— 那些栏本页不显示，但用户可能手改 JSON 写过（见 `draftEntry`）。
    private let editingModel: AICustomModel?

    /// 「最近一次落库后那一份」—— 初值 = `editingModel`，每次 `commitDrafts` 落库后推进。
    ///
    /// 🔴🔴 **为什么不能直接用 `editingModel`（打开那一刻的快照）当 `draftEntry` 的起点**：
    ///     `commitDrafts` 保存后**输入框被清空、`keyCleared` 复位** ⇒ 此刻「框是空的」
    ///     会被 `draftEntry` 当成「没敲过 Key」⇒ 回落到起点那把 Key。
    ///     起点若还是打开时的快照（新条目那里就是空 Key）⇒ **刚存好的 Key 被覆盖成空**
    ///     （2026-10-16 真事故：测试连接通过 → 保存 → models.json 里 apiKey 是空串
    ///     → 列表显示「还没配齐」、对话报「还没填 API Key」、模型选择器空）。
    ///     起点随落库推进后，落库后的任何再读取都落在「刚存的那条」上 = 语义正确。
    ///
    /// ⚠️ 与 `editingModel` 的分工：后者是「打开时是谁」（只用于标题 添加/编辑 与 DEBUG 深链）；
    ///     **一切「从哪条改起」都读这个**。
    private var persistedEntry: AICustomModel?

    /// 本页正在编辑哪家**预设**（决定预填地址 / 能力位 / 图标 / 文档链接）。
    /// 🔴 它不是「App 当前用哪家」（那个概念已经不存在了，见文件头）。
    private var vendor: AIProviderKind

    /// Key 草稿 = **输入框里的内容**（计算属性，直接读框）。
    ///
    /// 🔴🔴 **⛔ 别改回「存储属性 + `editingChanged` 里同步」那种写法**——
    ///     2026-10-16 真事故：那一版把同步行写在 `keyChanged` 里，行在一次重构中丢了，
    ///     **编译不报错、界面也正常**（框里显示点号），但 `keyDraft` 永远是空串 ⇒
    ///     用户粘贴/敲进去的 Key **测不了（报「API Key 是空的」）也存不下（写出空 Key）**。
    ///     事件中转是这类静默 bug 的温床；「草稿就是框本身」没有同步可漏。
    ///     （Mac 侧 `MacAddModelView` 用 SwiftUI 双向绑定 `$keyDraft`，天然是同一条真源。）
    ///
    /// ⚠️ Key 输入框**不回填明文**（编辑既有条目时也从空开始，已存的只显示脱敏值）——
    ///    所以「框是空」有三种含义：没敲 / 敲了又删 / 想清除，靠 `keyCleared` 区分（见 `draftEntry`）。
    private var keyDraft: String { keyField.text ?? "" }
    private var keyCleared = false

    /// 服务地址草稿。⚠️ **界面上已经没有这一栏**（2026-10-14 删的）——
    ///    它现在是个**载体**：编辑既有条目时装的是这条自己的 url（所以手改过地址的 `.custom` 条目
    ///    不会因为打开一次表单就被重置）；只有**换供应商**才重置成该家的默认地址。
    private var urlDraft = ""

    private var modelDraft = ""

    /// 打开那一刻的**原始值**（「保存」可点与否靠它比）。
    ///
    /// 🔴 新增一条时这些不是从某条配置里读的，而是从**供应商预设**读的 ——
    ///    所以「刚打开什么都没动」天然是干净的（见 `isDirty`），⛔ 别改成「恒为脏」。
    private var originalModelID = ""
    private var originalURL = ""
    private var originalVendorRaw = ""

    /// 已存 Key 的脱敏显示值（`nil` = 这条还没填 Key）
    private var storedMaskedKey: String?

    /// 可选模型清单（内置候选 + 上次拉到的缓存）。
    private var modelOptions: [AIModelCatalog.AIModelEntry] = []

    /// 「测试连接」的状态。
    private var testing = false
    /// 测试连接的反馈文案与成败（**与 `testing` 分开**：它们只被 `refreshKeyStatus` 读，
    /// 不参与任何布局判断）。
    private var testNote: String?
    private var testOK = false

    #if DEBUG
    /// 🧪 验收钩子的一次性闩（本体见文件末尾那段）。
    /// ⚠️ 存储属性**必须**声明在类体里（extension 里放不了）—— 钩子的方法体在 extension 里。
    private var didAutoOpenPicker = false
    /// 🧪「填了草稿不保存」探针的一次性闩（本体见文件末尾那段，闩的理由同上）。
    private var didAutoRunDraftProbe = false
    /// 🧪「Key 粘贴链路」探针的一次性闩（本体见文件末尾那段，闩的理由同上）。
    private var didAutoRunKeyPasteProbe = false
    #endif

    // MARK: - 控件

    private lazy var providerField = AIAddModelFieldButton(image: vendor.iconImage(pointSize: 16),
                                                          title: vendor.displayName)

    /// 模型名那一栏 —— **与供应商同款**（一颗按钮，点了弹模态选择页）。见文件头。
    /// ⚠️ 没有图标（`image: nil`）——与 Mac 侧 `fieldShell(icon: nil)` 同款。
    private lazy var modelField = AIAddModelFieldButton(image: nil, title: L("未设置"))

    /// 文档链接（右侧「查看文档 ↗」）—— 认不出供应商预设时（手改 JSON 写了个没见过的
    /// vendor 名）没有官方文档可指，那一行就不渲染。
    private lazy var docButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle(L("查看文档") + " ↗", for: .normal)
        b.titleLabel?.font = AIChromeFont.ui(14)
        b.addTarget(self, action: #selector(docTapped), for: .touchUpInside)
        return b
    }()

    /// Key 输入框：默认密文 + 右侧眼睛。
    /// ⚠️ 用 `rightView` 而不是 `clearButtonMode`（右侧已被眼睛占用）。
    /// 🔴 类型是 `AIAPIKeyTextField` 而不是裸 `UITextField`（2026-10-19）——
    ///    为键盘上那两个顽症（「Passwords」自动填充栏 / 长按无粘贴）专门设的，
    ///    两条对策的完整理由见那个子类的注释。
    private lazy var keyField: AIAPIKeyTextField = {
        let f = AIAPIKeyTextField()
        f.placeholder = L("输入你的 API Key")
        // ⚠️ Key 是等宽字体更好读（容易看出少没少字符）。iOS 上**没有**
        //    `.systemFont(ofSize:design:)` 这个构造（那是 macOS 的）⇒ 走 `monospacedSystemFont`。
        // 🔴 字号走 `AIChromeFont`（2026-10-22 接字号档位）：等宽那一支有专用重载
        //    （`uiMonospaced`），⛔ 别退回裸 `monospacedSystemFont`。
        f.font = AIChromeFont.uiMonospaced(15)
        f.borderStyle = .none
        f.autocapitalizationType = .none
        f.autocorrectionType = .no
        f.spellCheckingType = .no
        f.returnKeyType = .done
        f.isSecureTextEntry = true
        f.clearButtonMode = .never
        f.rightView = eyeButton
        f.rightViewMode = .always
        f.addTarget(self, action: #selector(keyChanged), for: .editingChanged)
        f.addTarget(self, action: #selector(backgroundTapped), for: .editingDidEndOnExit)
        // 粘贴失败时的那句提示贴在本页视图上（字段自己没地方贴）。
        // 键盘正开着（粘贴只发生在字段是第一响应者时）⇒ 贴在键盘上方。
        f.onPasteFailed = { [weak self] message in
            guard let self else { return }
            AIToast.show(message, in: self.view, bottomInset: 336)
        }
        return f
    }()

    private lazy var eyeButton: UIButton = {
        let b = UIButton(type: .system)
        b.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        b.tintColor = .secondaryLabel
        b.setImage(UIImage(systemName: "eye.slash"), for: .normal)
        b.addTarget(self, action: #selector(eyeTapped), for: .touchUpInside)
        return b
    }()

    private lazy var testButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle(L("测试连接"), for: .normal)
        b.titleLabel?.font = AIChromeFont.ui(15)
        b.layer.cornerRadius = Metrics.fieldRadius
        b.layer.borderWidth = 1
        b.layer.borderColor = UIColor.separator.cgColor
        b.setTitleColor(.label, for: .normal)
        b.addTarget(self, action: #selector(testTapped), for: .touchUpInside)
        return b
    }()

    /// Key 那一栏下面的状态 / 反馈（脱敏值、待清除、连接结果）
    private lazy var keyStatusLabel: UILabel = makeHintLabel()

    private lazy var clearKeyButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle(L("清除"), for: .normal)
        b.titleLabel?.font = AIChromeFont.ui(12)
        b.setTitleColor(.systemRed, for: .normal)
        b.addTarget(self, action: #selector(clearKeyTapped), for: .touchUpInside)
        return b
    }()

    // MARK: - 底部

    private lazy var cancelButton: UIButton = makeFooterButton(title: L("取消"), primary: false,
                                                              action: #selector(cancelTapped))
    private lazy var saveButton: UIButton = makeFooterButton(title: L("保存"), primary: true,
                                                             action: #selector(saveTapped))

    // MARK: - 初始化

    /// - Parameter editingModel: 要编辑的那一条；`nil` = 新增（供应商预设默认停在深度求索，
    ///   地址/模型名都从预设预填，用户改哪栏算哪栏）。
    ///
    ///   🔴 传进来的这**一份是快照**（见 `editingModel`）：本页打开后不再回读 ——
    ///      模态期间别处改了配置，用户看到的也该还是他打开那一刻的样子。
    public init(editingModel: AICustomModel? = nil) {
        self.editingModel = editingModel
        // 「从哪条改起」的起点 = 打开那一刻的那条；之后每次落库会推进（见 `persistedEntry`）
        self.persistedEntry = editingModel
        // 预设初值：编辑既有条目时跟着它走（认不出的 vendor 名回落深度求索 ——
        // 那是唯一能保证「图标/文档/预填」都有值的预设）
        self.vendor = editingModel?.vendorKind ?? AIProviderKind.allCases.first ?? .deepSeek
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 生命周期

    public override func viewDidLoad() {
        super.viewDidLoad()
        // 标题说实话：新增 / 编辑是两件事（编辑时用户会想确认自己在改哪一条）
        title = editingModel == nil ? L("添加模型") : L("编辑模型")
        view.backgroundColor = .systemBackground
        setupUI()
        reloadAll()
    }

    /// 离开这一页 —— **什么都不提交**。
    ///
    /// 🔴 2026-10-16 用户要求：「没有点击保存按钮，模型列表也不要出现该数据」。
    ///    改造前这里有一次「兜底提交」（侧滑返回 = 保存），本意是「不小心划到别丢 Key」，
    ///    实际效果是：填了一半侧滑返回 / 系统返回键返回，**列表里凭空多一条半成品**。
    ///    现在唯一落库路径就是「保存」按钮（`saveTapped`）——
    ///    侧滑返回 / 系统返回键 / 「取消」一律丢弃，与 Mac 端（⌘W 关窗 = 丢弃）一致。
    /// ⚠️ 「保存」按钮走的是 `commitDrafts()` **主动**落库，不依赖这里；
    ///    点完保存 pop 时走到本方法，库存里早已是刚存的那条（幂等由
    ///    `persistedEntry` 保证，见那边的注释）。
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        openPickerIfRequested()
        runDraftDiscardProbeIfRequested()
        runKeyPasteProbeIfRequested()
        #endif
    }

    /// 页脚（取消 / 保存）—— **钉在屏幕底部，不在滚动区里**（理由见文件头）。
    ///
    /// 🔴 它必须**后于** `scrollView` 加进 `view`（画在滚动内容之上），且 `scrollView` 的下沿
    ///    要贴它的上沿。⛔ 别图省事把它塞回 `contentStack`。
    /// ⚠️ 底色**必须给**（`.systemBackground`）：不给的话滚动内容会从页脚背后透出来。
    private lazy var footerBar: UIView = {
        let bar = UIView()
        bar.backgroundColor = .systemBackground
        let hairline = UIView()
        hairline.backgroundColor = .separator
        let row = makeFooterSection()
        bar.addSubview(hairline)
        bar.addSubview(row)
        hairline.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(1)
        }
        row.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(12)
            make.leading.trailing.equalToSuperview().inset(20)
            make.bottom.equalToSuperview().offset(-12)
        }
        return bar
    }()

    // MARK: - 布局

    private func setupUI() {
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        // 🔴 页脚**后加**（要画在滚动区之上）且**不进 `contentStack`** —— 见 `footerBar` 的注释。
        view.addSubview(footerBar)

        // 点空白收键盘（`cancelsTouchesInView = false` 保证字段按钮照常点得到）
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        dismissTap.cancelsTouchesInView = false
        dismissTap.delegate = self
        scrollView.addGestureRecognizer(dismissTap)

        contentStack.addArrangedSubview(makeSupplierSection())
        contentStack.addArrangedSubview(makeKeySection())
        contentStack.addArrangedSubview(makeModelSection())

        footerBar.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(view.safeAreaLayoutGuide)
        }
        // ⚠️ 滚动区下沿贴页脚上沿（不是贴 safe area）—— 页脚占掉的那 64pt 不能再被内容压住。
        scrollView.snp.makeConstraints { make in
            make.top.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            make.bottom.equalTo(footerBar.snp.top)
        }
        // 纵向滚动：上下贴 contentLayoutGuide（撑出 contentSize），左右贴 frameLayoutGuide（定宽，不横向溢出）。
        // ⚠️ 不能贴 superview：那样 contentSize 会被锁成 frame 大小，高度超出就滚不动了。
        contentStack.snp.makeConstraints { make in
            make.top.equalTo(scrollView.contentLayoutGuide).offset(16)
            make.bottom.equalTo(scrollView.contentLayoutGuide).offset(-16)
            make.leading.equalTo(scrollView.frameLayoutGuide).offset(20)
            make.trailing.equalTo(scrollView.frameLayoutGuide).offset(-20)
        }
    }

    /// ① 供应商：标题行（说明 + 查看文档）+ 字段按钮（点了弹模态选择页）
    private func makeSupplierSection() -> UIView {
        let title = UILabel()
        title.font = AIChromeFont.ui(14)
        title.textColor = .label
        title.text = L("供应商")

        let subtitle = UILabel()
        subtitle.font = AIChromeFont.ui(14)
        subtitle.textColor = .secondaryLabel
        subtitle.text = L("（仅支持 OpenAI 兼容协议 API）")
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleRow = UIStackView(arrangedSubviews: [title, subtitle, UIView(), docButton])
        titleRow.axis = .horizontal
        titleRow.spacing = 6
        titleRow.alignment = .center

        providerField.addTarget(self, action: #selector(openProviderPicker), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleRow, providerField])
        stack.axis = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(6, after: titleRow)
        // ⚠️ 高度约束必须写在**入栈之后**：SnapKit 对尚未挂进视图树的对象做约束会断言失败
        //    （本工程旧设置页踩过，注释还留在那儿）。
        providerField.snp.makeConstraints { make in make.height.equalTo(Metrics.fieldHeight) }
        return stack
    }

    /// ② API Key：标题 + （输入框 + 测试连接）+ 状态行
    private func makeKeySection() -> UIView {
        let title = UILabel()
        title.font = AIChromeFont.ui(14)
        title.textColor = .label
        title.text = "API Key"

        let fieldBox = UIView()
        fieldBox.backgroundColor = .secondarySystemBackground
        fieldBox.layer.cornerRadius = Metrics.fieldRadius
        fieldBox.layer.borderWidth = 1
        fieldBox.layer.borderColor = UIColor.separator.cgColor
        fieldBox.addSubview(keyField)
        keyField.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.trailing.equalToSuperview().offset(-4)
            make.centerY.equalToSuperview()
        }

        let fieldRow = UIStackView(arrangedSubviews: [fieldBox, testButton])
        fieldRow.axis = .horizontal
        fieldRow.spacing = 10
        fieldRow.alignment = .fill
        // ⚠️ 尺寸约束写在**入栈之后**（见 `makeSupplierSection` 里那条注释）
        fieldBox.snp.makeConstraints { make in make.height.equalTo(Metrics.fieldHeight) }
        testButton.snp.makeConstraints { make in
            make.width.equalTo(96)
            make.height.equalTo(Metrics.fieldHeight)
        }

        let statusRow = UIStackView(arrangedSubviews: [keyStatusLabel, UIView(), clearKeyButton])
        statusRow.axis = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .center

        let stack = UIStackView(arrangedSubviews: [title, fieldRow, statusRow])
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }

    /// ③ 模型名称：标题 + 字段按钮（**不可手填**，点了弹模态选择页）
    private func makeModelSection() -> UIView {
        let title = UILabel()
        title.font = AIChromeFont.ui(14)
        title.textColor = .label
        title.text = L("模型名称")

        modelField.addTarget(self, action: #selector(openModelPicker), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, modelField])
        stack.axis = .vertical
        stack.spacing = 8
        modelField.snp.makeConstraints { make in make.height.equalTo(Metrics.fieldHeight) }
        return stack
    }

    /// ④ 取消 / 保存（右下角，与参考图一致）
    private func makeFooterSection() -> UIView {
        let row = UIStackView(arrangedSubviews: [UIView(), cancelButton, saveButton])
        row.axis = .horizontal
        row.spacing = 10
        row.alignment = .center
        cancelButton.snp.makeConstraints { make in
            make.width.equalTo(88)
            make.height.equalTo(40)
        }
        saveButton.snp.makeConstraints { make in
            make.width.equalTo(88)
            make.height.equalTo(40)
        }
        return row
    }

    // MARK: - 小件

    private func makeHintLabel() -> UILabel {
        let l = UILabel()
        l.font = AIChromeFont.ui(12)
        l.textColor = .tertiaryLabel
        l.numberOfLines = 0
        return l
    }

    private func makeFooterButton(title: String, primary: Bool, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = AIChromeFont.ui(15, weight: primary ? .semibold : .regular)
        b.layer.cornerRadius = 8
        if primary {
            // 对齐参考图：实心深底 + 反色字。⛔ 不写死黑白 —— 用 `.label` / `.systemBackground`
            // 这对语义色，深浅色下自动反过来。
            b.backgroundColor = .label
            b.setTitleColor(.systemBackground, for: .normal)
        } else {
            b.backgroundColor = .secondarySystemBackground
            b.layer.borderWidth = 1
            b.layer.borderColor = UIColor.separator.cgColor
            b.setTitleColor(.label, for: .normal)
        }
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    // MARK: - 刷新

    /// 进页面 / 换供应商时把这一条的一切读进来（草稿、脱敏 Key、模型候选）。
    private func reloadAll() {
        // 🔴 不回填明文（`keyDraft` 就是框本身）：输入框永远从空开始，已存的只显示脱敏值。
        keyCleared = false
        keyField.text = ""
        keyField.isSecureTextEntry = true
        eyeButton.setImage(UIImage(systemName: "eye.slash"), for: .normal)

        // 草稿初值：编辑既有条目 → 用它的值；新增 → 用**供应商的预设值**
        // （读 `persistedEntry` 而不是 `editingModel`：本页若已落库过，「原来那条」是刚存的那份）
        let entry = persistedEntry
        // 🔴 新增时模型名**预填该家的官方默认模型**（2026-10-19 用户点名要的：
        //    「供应商默认选择了，但模型名称为空」）—— 与换供应商时 `selectProvider` 同源
        //    （都是 `AIProviderKind.defaultModel`，⛔ 别在这两条路各写一个模型名）。
        //    ⚠️ `.custom` 的 defaultModel 是空串 ⇒ 仍显示「未设置」（而 .custom 从界面新建不了，
        //       正常路径走不到）；此时保存键的守卫（模型名非空）会挡住，行为与改动前一致。
        modelDraft = entry?.id ?? vendor.defaultModel
        urlDraft = entry?.url ?? vendor.defaultBaseURL
        storedMaskedKey = AIConfig.masked(entry?.apiKey)

        // 「原始值」快照 —— `isDirty` 靠它比（见那边注释：⛔ 别改成恒为脏）
        originalModelID = modelDraft
        originalURL = urlDraft
        originalVendorRaw = vendor.rawValue

        modelOptions = AIModelCatalog.candidates(for: vendor, url: urlDraft)

        refreshFieldButtons()
        refreshKeyPlaceholder()
        // 预设认不出（手改 JSON 写了个没见过的 vendor 名）⇒ 没有官方文档可指，那一行不渲染
        docButton.isHidden = (vendor.documentationURL == nil)
        testing = false
        testButton.setTitle(L("测试连接"), for: .normal)
        testButton.isEnabled = true

        refreshKeyStatus()
        refreshSaveEnabled()
    }

    /// 两个字段按钮上的字（供应商名 / 模型名）。
    ///
    /// ⚠️ 单点：进页面、换供应商、选模型三处都要刷它 —— 散着写必定漏一处，
    /// 而漏了的那处症状是「按钮上还是上一个值」，很难一眼看出来。
    private func refreshFieldButtons() {
        providerField.update(image: vendor.iconImage(pointSize: 16), title: vendor.displayName)
        // 模型名为空时显示灰色的「未设置」（与 Mac 侧 `dimmed` 同款）
        modelField.update(image: nil,
                          title: modelDraft.isEmpty ? L("未设置") : modelDraft,
                          dimmed: modelDraft.isEmpty)
    }

    /// Key 那一栏下面的状态：脱敏现状 / 待清除 / 连接结果（**不显示明文**）。
    private func refreshKeyStatus() {
        if let note = testNote {
            keyStatusLabel.text = note
            keyStatusLabel.textColor = testOK ? .systemGreen : .systemRed
        } else if keyCleared {
            keyStatusLabel.text = L("保存后清除这条配置的 Key")
            keyStatusLabel.textColor = .secondaryLabel
        } else if !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            keyStatusLabel.text = L("保存后生效")
            keyStatusLabel.textColor = .secondaryLabel
        } else if let masked = storedMaskedKey {
            keyStatusLabel.text = String(format: L("已保存：%@"), masked)
            keyStatusLabel.textColor = .secondaryLabel
        } else {
            keyStatusLabel.text = L("未配置")
            keyStatusLabel.textColor = .secondaryLabel
        }
        clearKeyButton.isHidden = (storedMaskedKey == nil || keyCleared)
    }

    /// Key 输入框的占位符 —— 输入框**不回填明文**，占位符是用户唯一能看见
    /// 「已存的 Key 长什么样」的地方（2026-10-16：用户打开编辑页看到空框，
    /// 不知道 Key 存没存，还以为空框能测连接是 bug）。
    ///
    /// 有已存 ⇒ 「已保存 sk-xxxx**** · 留空不修改」；没有 ⇒ 默认提示。
    /// ⚠️ 用户一开始敲字，占位符自动让位（UIKit 行为），不用管。
    private func refreshKeyPlaceholder() {
        if let masked = storedMaskedKey {
            keyField.placeholder = String(format: L("已保存 %@ · 留空不修改"), masked)
        } else {
            keyField.placeholder = L("输入你的 API Key")
        }
    }

    /// 「保存」是否可点 —— 与 Mac 端 `isDirty` 同口径。
    ///
    /// 🔴 **新增那一路不能写成「恒为脏」**：改造前比的是「Key 输入框 ≠ 已存的明文」，
    ///    而输入框从空开始（不回填明文）⇒ 那样比会**恒为脏**，保存按钮永远亮着，
    ///    用户点一次就会把配置写成空 Key（空串被归一成清除，见 `draftEntry`）。
    ///    所以这里比的是**与「打开那一刻的快照」**（`originalXxx`）。
    ///    ⚠️ 2026-10-14 第三轮去掉单价那一条（本页已没有编辑单价的入口，那一支恒为 false）。
    private var isDirty: Bool {
        let typed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty || keyCleared { return true }
        if modelDraft.trimmingCharacters(in: .whitespacesAndNewlines) != originalModelID { return true }
        if urlDraft.trimmingCharacters(in: .whitespacesAndNewlines) != originalURL { return true }
        if vendor.rawValue != originalVendorRaw { return true }
        return false
    }

    /// 按 `isDirty` 更新「保存」按钮的外观（灰掉 = 这一会儿没有可存的改动）。
    ///
    /// ⚠️ 单独一个函数而不是在每处 `isDirty` 之后手写两行：调用点有十来处
    ///    （输入框改动 / 选供应商 / 选模型 / 清 Key / 落库之后…），
    ///    散着写必定漏一处，而漏了的那处症状是「按钮该亮没亮」——很难一眼看出来。
    private func refreshSaveEnabled() {
        let dirty = isDirty
        saveButton.isEnabled = dirty
        saveButton.alpha = dirty ? 1 : 0.5
    }

    // MARK: - 动作

    /// 打开「供应商」模态选择页。
    ///
    /// 🔴 呈现配置全在 `AIListPickerViewController.present(…)` 里（单点）——
    ///    这里只管把「现在的编辑目标 + 选中回调」传进去。
    @objc private func openProviderPicker() {
        view.endEditing(true)
        AIListPickerViewController.present(content: .provider(current: vendor), from: self) { [weak self] pick in
            guard case .provider(let kind) = pick else { return }
            self?.selectProvider(kind)
        }
    }

    /// 打开「模型名称」模态选择页。
    @objc private func openModelPicker() {
        view.endEditing(true)
        let content = AIListPickerViewController.Content.model(entries: modelOptions, current: modelDraft)
        AIListPickerViewController.present(content: content, from: self) { [weak self] pick in
            guard case .model(let id) = pick else { return }
            self?.pickModel(id)
        }
    }

    /// 换供应商**预设**：地址与模型名跟着它走。
    ///
    /// 🔴 地址**直接重置成该家的默认地址**（`.custom` 则清空）：换了一家的地址留着上一家的，
    ///    是纯粹的陷阱 —— 请求会打到「A 家的模型名 + B 家的地址」上，而界面看起来一切正常。
    ///    ⚠️ 想保留手输地址的用户不受影响：他改地址就行，不换供应商就不会被重置。
    /// 🔴 **模型名同理重置成该家的 `defaultModel`**（2026-10-14 第三轮用户点名要的，
    ///    与 Mac 侧 `MacAddModelView.selectProvider` 同口径）。
    ///    ⚠️ 这一条**推翻了本文件旧注释的意图**（原文：“用户可能先填了 Key、选了模型名，
    ///    再回头换供应商，那些不该丢”）—— 那个口径是「模型名能手填」时代立的，现在不成立：
    ///    模型名**只能从该家的候选里选** ⇒ 留着上一家的模型名会得到一个
    ///    **界面看不出错、请求必然失败**的组合（B 家的地址 + A 家的模型名）。
    ///    ⚠️ 用 `defaultModel` 而不是「候选里的第一条」：它是**该家的官方默认模型**
    ///    （`AIProviderKind.defaultModel`，与地址同一处维护），而候选清单可能拉不到（离线）。
    /// ⚠️ 只改草稿、**不落库**（草稿语义，见文件头）—— 其余草稿保留（用户可能先填了 Key）。
    private func selectProvider(_ kind: AIProviderKind) {
        view.endEditing(true)
        guard kind != vendor else { return }
        vendor = kind
        urlDraft = kind.defaultBaseURL
        modelDraft = kind.defaultModel
        modelOptions = AIModelCatalog.candidates(for: kind, url: urlDraft)
        docButton.isHidden = (kind.documentationURL == nil)
        refreshFieldButtons()
        refreshSaveEnabled()
    }

    /// 选中一个模型名（**唯一**的写入点 —— 本页不再接受手填，见文件头）。
    private func pickModel(_ id: String) {
        modelDraft = id
        refreshFieldButtons()
        refreshSaveEnabled()
    }

    /// 把草稿拼成一条配置。
    ///
    /// 🔴 **起点是「最近一次落库的那条」（从没落过 = 打开时的那条；新增时是预设推出来的那条）**，
    ///    然后只覆盖本页拥有的字段 —— 这样 `name` / `maxInputTokens` / `maxOutputTokens` /
    ///    `supportsToolCall` / `pricing` 这些「本页不显示但用户可能手改过」的字段会被原样保留。
    ///    ⛔ 别改成从零 `init` 再逐字段赋值：漏一个就等于**用户手改过的那个字段被悄悄清掉**。
    ///    ⚠️ 也⛔ 别把起点换回 `editingModel`（打开时快照）—— 那正是 2026-10-16
    ///    「保存后 Key 被清空」事故的根因，见 `persistedEntry` 的注释。
    private func draftEntry() -> AICustomModel {
        let modelID = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // 供应商 + 模型名 → 能力位（把改造前「按平台特征串判收图」那套搬到这一层，
        // 保证从界面加出来的配置行为与改造前一致，见 `AICustomModel.inferFrom`）
        let inferred = AICustomModel.inferFrom(kind: vendor, modelID: modelID, url: url)
        var entry = persistedEntry ?? inferred
        entry.id = modelID
        entry.vendor = inferred.vendor
        entry.url = url
        entry.supportsImages = inferred.supportsImages
        entry.supportsReasoning = inferred.supportsReasoning
        entry.reasoning = inferred.reasoning
        // Key：敲了新的就用新的；明确点了「清除」才置空；**否则保留原来那把**
        // （输入框不回填明文 ⇒ 「没敲」不代表「要清空」，见 `isDirty` 的注释）
        let typed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            entry.apiKey = typed
        } else if keyCleared {
            entry.apiKey = ""
        }
        // ⚠️ **不碰 `entry.pricing`**（2026-10-14 第三轮起本页没有单价入口）：
        //    `entry` 的起点是「原来那条」⇒ 手改 JSON 写过的单价原样保留；
        //    新增时起点是 `inferred`（`pricing == nil`）⇒ 显示与计费都回落到 `AIConfig.defaultPricing`。
        //    ⛔ 别「顺手」在这里写一句 `entry.pricing = …`：那会把默认值**实体化**进文件。
        return entry
    }

    /// 提交草稿。**唯一调用点是「保存」按钮**（`saveTapped`）。
    ///
    /// 🔴 **模型名为空时整个跳过**：那是「新增到一半 / 只是进来看看」的样子，
    ///    真写下去就是往用户的 JSON 里塞一条空条目。
    /// 🔴 **落库后的再读取必须落在「刚存的那条」上**（`persistedEntry` 随落库推进）：
    ///    保存后输入框已清空，若起点还是打开时快照就会把刚存好的 Key 覆盖成空
    ///    （2026-10-16 事故，见 `persistedEntry` 的注释）。
    private func commitDrafts() {
        guard !modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let originalID = persistedEntry?.id
        let saved = draftEntry()
        // 🔴 用 `save(_:replacing:)`（不是 `upsert`）：模型名是**键**，用户改名字时
        //    必须「替换原来那条」而不是「多出一条」，见 `AIModelStore.save` 的注释。
        AIModelStore.save(saved, replacing: originalID)
        // 推进起点：保存后的任何再读取（draftEntry / isDirty）都落在「刚存的那条」上
        persistedEntry = saved
        keyCleared = false
        keyField.text = ""
        // 落库之后再拉一次这条（拿到归一化后的样子：能力位、计价都定下来了）
        syncOriginals(from: saved)
    }

    /// 提交之后把「打开那一刻的快照」推到刚存下的那份 ——
    /// 否则保存后再读 `persistedEntry` / `isDirty` 会拿老快照比，`isDirty` 会一直亮着。
    private func syncOriginals(from entry: AICustomModel) {
        modelDraft = entry.id
        urlDraft = entry.url
        originalModelID = entry.id
        originalURL = entry.url
        originalVendorRaw = entry.vendor
        storedMaskedKey = AIConfig.masked(entry.apiKey)
        refreshFieldButtons()
        refreshKeyPlaceholder()
        refreshKeyStatus()
        refreshSaveEnabled()
    }

    /// 「保存」按钮：提交 + 关页面。
    @objc private func saveTapped() {
        view.endEditing(true)
        // 模型名是**键**，空的话这一条存不进清单（`commitDrafts` 会跳过）——
        // 与其「点了没反应」，不如说清缺什么
        guard !modelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showMissingModelAlert()
            return
        }
        commitDrafts()
        close()
    }

    private func showMissingModelAlert() {
        let alert = UIAlertController(title: L("还缺模型名称"),
                                      message: L("模型名称是这条配置的标识（也是发给服务端的那个字符串），不能为空。"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("好"), style: .default))
        present(alert, animated: true)
    }

    /// 「取消」/ 关闭：**丢弃草稿**（拉回存储里的样子）+ 关页面。
    ///
    /// 🔴 2026-10-16 起侧滑返回 / 系统返回键也是这个语义（`viewWillDisappear` 不再兜底
    ///    提交）⇒ 「不点保存，列表里就不会出现该数据」是**所有离开路径**的统一行为。
    @objc private func cancelTapped() {
        view.endEditing(true)
        reloadAll()
        close()
    }

    private func close() {
        // 本页永远是被 push 进来的（清单页保证有导航栈，见文件头）——
        // 返回键 / 侧滑返回都会走到这里
        navigationController?.popViewController(animated: true)
    }

    @objc private func docTapped() {
        guard let url = vendor.documentationURL else { return }
        UIApplication.shared.open(url)
    }

    @objc private func keyChanged() {
        // 用户开始敲新 Key ⇒ 「待清除」这个草稿自动作废（两个草稿不该同时挂着）
        // ⚠️ 这里**没有**「把框里内容同步进草稿」那一行 —— 不需要，`keyDraft` 就是框本身
        //    （计算属性）。⛔ 别把同步行加回来：加回来的那次就是 2026-10-16 事故的起点。
        keyCleared = false
        refreshKeyStatus()
        refreshSaveEnabled()
    }

    /// 切换明文 / 密文。
    /// ⚠️ firstResponder 状态下直接改 `isSecureTextEntry` 系统会清空已输入内容，
    ///    故先取出文本、切换后再写回。
    @objc private func eyeTapped() {
        let saved = keyField.text
        keyField.isSecureTextEntry.toggle()
        keyField.text = nil
        keyField.text = saved
        eyeButton.setImage(UIImage(systemName: keyField.isSecureTextEntry ? "eye.slash" : "eye"),
                           for: .normal)
    }

    @objc private func clearKeyTapped() {
        view.endEditing(true)
        keyField.text = ""
        keyCleared = true
        refreshKeyStatus()
        refreshSaveEnabled()
    }

    /// 「测试连接」：打一次 `/models`。
    ///
    /// ⚠️ 用**草稿里的地址与 Key**（敲了新的就用新的，没敲就用已存的）—— 表单是
    ///    「保存」才落库，拿存着的那份去测等于测了个旧配置（症状：Key 填错了却提示成功）。
    /// ⚠️ 成功**不代表**已经保存。
    @objc private func testTapped() {
        view.endEditing(true)
        guard !testing else { return }
        testing = true
        testNote = nil
        testOK = false
        testButton.setTitle(L("测试中…"), for: .normal)
        testButton.isEnabled = false
        refreshKeyStatus()

        let kind = vendor
        let url = urlDraft
        let typed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // 输入框空 ⇒ 显式用**这一条**已存的 Key。
        // 🔴 ⛔ 别传 nil：`AIModelCatalog.fetch(apiKey: nil)` 会回落 `AIConfig.currentAPIKey`
        //    = **当前选中条目**的 Key —— 在清单里编辑*别的*条目时，测的就是别人的 Key
        //    （2026-10-16 用户实测：空框点测试却成功，正是回落到了刚在用的那条）。
        //    连已存的也没有 ⇒ 空串：不带 Authorization，服务端 401 ⇒ 「API Key 是空的」。
        let storedKey = persistedEntry?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        AIModelCatalog.fetch(for: kind, url: url, apiKey: typed.isEmpty ? storedKey : typed) { [weak self] result in
            guard let self else { return }
            self.testing = false
            self.testButton.setTitle(L("测试连接"), for: .normal)
            self.testButton.isEnabled = true
            switch result {
            case .success(let models):
                self.testOK = true
                self.testNote = String(format: L("连接成功 · 拉到 %d 个模型"), models.count)
                // 只在还停在同一家 + 同一个地址时才刷清单（用户可能在等待期间改了）
                if self.vendor == kind, self.urlDraft == url {
                    self.modelOptions = AIModelCatalog.candidates(for: kind, url: url)
                }
            case .failure(let error):
                self.testOK = false
                self.testNote = String(format: L("连接失败：%@"), error.localizedDescription)
            }
            self.refreshKeyStatus()
        }
    }

    @objc private func backgroundTapped() {
        view.endEditing(true)
    }

    // MARK: - 收键盘手势要排除的控件

    /// 收键盘手势要**排除**的控件：Key 输入框（含它右侧的眼睛）、两个字段按钮、测试连接。
    ///
    /// 不排除的话，连「点同一个输入框挪光标」都会先收键盘再弹起（键盘闪一下）；
    /// 字段按钮更要排除 —— 点它是要弹选择页，收键盘那一拍会与转场打架。
    private var gestureExcludedViews: [UIView] {
        [keyField, providerField, modelField, testButton, eyeButton]
    }
}

// MARK: - 点空白收键盘（手势代理）

extension AIAddModelViewController: UIGestureRecognizerDelegate {

    /// 只让「输入框 / 按钮以外」的触摸触发收键盘（详见 `gestureExcludedViews` 的说明）
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldReceive touch: UITouch) -> Bool {
        guard let touched = touch.view else { return true }
        return !gestureExcludedViews.contains { touched === $0 || touched.isDescendant(of: $0) }
    }
}

// MARK: - 🧪 验收钩子：把两个模态选择页之一弹出来

#if DEBUG
extension AIAddModelViewController {

    /// `STARRY_SETTINGS_UI=provider|model` 时进页自动弹一次对应的选择页（只弹一次）。
    ///
    /// ## 为什么需要它
    /// 那两个选择页是**模态**弹出来的，而模拟器**投不出合成触摸**（`xcrun simctl` 没有 tap）
    /// ⇒ 不替用户点一下，「选择页长什么样、打勾在不在、搜索框会不会把列表挤坏」
    /// agent 侧一张图都拿不到（源码契约只证得了「哪段代码在」）。
    /// 与设置页 / 清单页那两段钩子是**同一次启动里配合使用的**：
    /// 那两段负责把本页推出来，这段负责再往下弹一层。
    ///
    /// ## 三个约束（逐条照抄通话页那个钩子）
    /// 1. **只在 `#if DEBUG` 下编译进去**；2. **只弹一次**（闩在 `didAutoOpenPicker`）；
    /// 3. 🔴 **必须发一次 `.touchUpInside` 让 UIKit 自己派发**，⛔ 别图省事直接调
    ///    `openProviderPicker()` —— 那样会**绕过触摸派发那一层**，而 2026-10-14 那个
    ///    「点供应商即崩」的坑**正藏在这一层**：
    ///    第一版 `AIAddModelFieldButton` 把自己的 `.touchUpInside` 接到
    ///    `handleTap() { sendActions(for: .touchUpInside) }` 上 ⇒ **无限递归**，
    ///    栈溢出（`EXC_BAD_ACCESS / KERN_PROTECTION_FAILURE`）。
    ///    当时本钩子走的恰恰是「直接调 `openProviderPicker()`」⇒
    ///    **八张截图全绿、用户手一点就崩** —— 钩子与真实路径差的那一层，正好就是坏掉的那层。
    ///    ⇒ 现在改成发 `.touchUpInside`：这一档从此兼任那个坑的**回归探针**，
    ///      派发链上只要再长出自我递归，跑这一档会**当场崩**，不用等用户去点。
    func openPickerIfRequested() {
        guard !didAutoOpenPicker else { return }
        let mode = ProcessInfo.processInfo.environment["STARRY_SETTINGS_UI"] ?? ""
        guard mode == "provider" || mode == "model" else { return }
        didAutoOpenPicker = true
        // 等这一帧画完再弹（与上游两层钩子同一条理由：当场 present 会截到半透明残影）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let field = (mode == "provider") ? self.providerField : self.modelField
            field.sendActions(for: .touchUpInside)
        }
    }

    /// 🧪「填了草稿、**不点保存**就离开」探针（`STARRY_SETTINGS_UI=draft|draft-discard`）。
    ///
    /// ## 为什么需要它
    /// 2026-10-16 用户要求：「没有点击保存按钮，模型列表也不要出现该数据」——
    /// `viewWillDisappear` 的兜底提交已删，唯一落库路径是「保存」按钮。
    /// 而这条语义**没有任何现成钩子验得了**：模拟器投不出合成触摸
    /// （既点不了「保存」也划不了侧滑返回）⇒ 不替用户走一遍，
    /// 「离开即丢弃」是回归了还是又被改坏了，agent 侧一张图都拿不到。
    ///
    /// ## 两个档位
    /// - `draft`：填三个字段后**停在本页**（截图证「草稿填上了、保存按钮亮了」——
    ///   排除「没填所以没存」的假阴性）；
    /// - `draft-discard`：同上，2 秒后 `close()` 离开（**不调 `saveTapped`**）。
    ///    最终截图落在清单页 + 直接读 `models.json` 双判据：列表里不能有这条。
    ///
    /// ## 约束（逐条照抄上面那段）
    /// 1. 只在 `#if DEBUG` 下编译；2. 只跑一次（闩在 `didAutoRunDraftProbe`）；
    /// 3. 🔴 填字段走的是**用户那条路**（设草稿 + 调字段自己的 `xxxChanged()`），
    ///    ⛔ 别直接调 `commitDrafts()` —— 那正是要防的「绕过用户路径」；
    ///    离开也走 `close()`（与「取消」按钮同一条路，pop 会触发 `viewWillDisappear`）。
    func runDraftDiscardProbeIfRequested() {
        guard !didAutoRunDraftProbe else { return }
        let mode = ProcessInfo.processInfo.environment["STARRY_SETTINGS_UI"] ?? ""
        guard mode == "draft" || mode == "draft-discard" else { return }
        didAutoRunDraftProbe = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 像用户一样把字段填上 —— 走**各自真实的写入点**：
            // · 模型名：`pickModel`（本页不接受手填，用户就是在选择页里点一个）。
            //   取一个 deepseek 的候选名（进页默认供应商就是深度求索，别造出
            //   「豆包模型名 + 深度求索供应商」的错位画面）；
            // · Key：设 `keyField.text` + `keyChanged()`（`keyDraft` 是计算属性）。
            // ⛔ 别直接写 `modelDraft = …` 绕过 `pickModel`：那两条路差的那一层
            //    （refreshFieldButtons / 保存按钮刷新）正是要照的。
            self.pickModel("deepseek-chat")
            self.keyField.text = "sk-probe-discard-key"
            self.keyChanged()
            guard mode == "draft-discard" else { return }
            // 不点保存，等一帧让「填好了」的样子画出来，再按用户那条路离开
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.close()
            }
        }
    }

    /// 🧪「API Key 粘贴链路」体检探针（`STARRY_KEY_PASTE_PROBE=self|external` 时进页自动跑一次）。
    ///
    /// ## 为什么需要它（2026-10-19 用户实测「长按出粘贴、点下去没反应」）
    /// 控制台伴随 `PBErrorDomain Code=13 "Operation not authorized."` —— 这是**剪贴板 daemon
    /// 的授权失败**。而本机是 Xcode 26.4+：那一版有一个**已确认的系统 bug** ——
    /// 「Mac 宿主机复制 → 模拟器粘贴」整条同步链断掉（Cmd+V 无效、模拟器剪贴板为空、
    /// 任何 App 里点 Paste 都报 Code=13；旁证：Apple 开发者论坛 thread/820393、820644）。
    /// ⇒ 本探针只回答一个问题：**剪贴板里确实有内容时，App 这一侧
    ///   （读 → trim → `insertText` → `.editingChanged` 广播）是不是好的？**
    ///   答案必须是「好」——剩下的故障全在模拟器同步链上，⛔ 不该再去改 App 代码。
    ///
    /// ## 两个档位（2026-10-19 实测结论）
    /// - `self`：App 自己往 `UIPasteboard.general` 写一串再粘（读写都在 App 进程内，必通）——
    ///   **本档 PASS = App 这一侧（读→trim→insertText→editingChanged）全部健康**；
    /// - `external`：**不碰剪贴板**、直接读当前内容粘。设计意图是脚本用 `simctl pbcopy` 预灌
    ///   （模拟「同步链没坏时用户复制进来的样子」）—— ☠️ 但实测（Xcode 27.0）：**`simctl pbcopy`
    ///   根本落不进 App 可见的剪贴板**（`pbpaste` 读回仍是旧值）⇒ 本档在当前环境**恒 FAIL**。
    ///   留着它当**金丝雀**：等 Apple 修好这个 bug，它就该变 PASS；在那之前 FAIL 是预期。
    ///   ⚠️ 顺带实测：读不到时**三条读法全被拒**（`.string`→nil / 老式 `data(forPasteboardType:)`
    ///   →0 字节 / `itemProvider.loadObject`→coerce 失败，底层都是 `PBErrorDomain Code=13`）
    ///   ⇒ App 侧没有任何绕过的读法，⛔ 别再去试第四种。
    ///
    /// ## 与真实路径差在哪（诚实记账）
    /// 两档都走 `keyField.paste(nil)` —— 与长按菜单那个 `paste:` 是**同一个 selector**；
    /// 差的两层只有「菜单派发」和「指尖」，而模拟器投不出合成触摸（本工程一贯限制）。
    /// 真机组装包上没有这个钩子（`#if DEBUG`），`STARRY_KEY_PASTE_PROBE` 也不会被设置。
    ///
    /// ## 判据落在哪
    /// 每步都写进 `<容器>/Documents/key_paste_probe.log`（每次运行先清空，整份就是本轮），
    /// 同时 `print` 一份进 Xcode 控制台；最后一行是 `RESULT: PASS|FAIL`，脚本跑完自动回显。
    func runKeyPasteProbeIfRequested() {
        guard !didAutoRunKeyPasteProbe else { return }
        let mode = ProcessInfo.processInfo.environment["STARRY_KEY_PASTE_PROBE"] ?? ""
        guard !mode.isEmpty else { return }
        didAutoRunKeyPasteProbe = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.keyPasteProbeResetLog()
            self.keyPasteProbeLog("=== key paste probe · mode=\(mode) · iOS \(UIDevice.current.systemVersion) ===")
            self.keyPasteProbeLog("config: isSecureTextEntry=\(self.keyField.isSecureTextEntry) textContentType=\(self.keyField.textContentType?.rawValue ?? "nil")")
            self.keyPasteProbeDumpPasteboard("before")
            self.keyPasteProbeTryFallbackReads()
            if mode == "self" {
                UIPasteboard.general.string = "sk-probe-483920"
                self.keyPasteProbeLog("wrote self string: sk-probe-483920")
                self.keyPasteProbeDumpPasteboard("after-write")
            }
            // 让键盘起来：截图要看键盘，且粘贴本来就发生在键盘开着的时候
            self.keyField.becomeFirstResponder()
            // 等键盘动画落定再粘（与截图时序错开，别抢同一帧）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let before = self.keyField.text ?? ""
                self.keyField.paste(nil)   // ← 与长按菜单的 paste: 同一个 selector
                let after = self.keyField.text ?? ""
                self.keyPasteProbeLog("canPerformAction(paste:) = \(self.keyField.canPerformAction(#selector(paste(_:)), withSender: nil))")
                self.keyPasteProbeLog("field.text: before=\(before.isEmpty ? "<empty>" : before) → after=\(after.isEmpty ? "<empty>" : after)")
                let ok = !after.isEmpty && after != before
                self.keyPasteProbeLog("RESULT: \(ok ? "PASS" : "FAIL")")
            }
        }
    }

    private func keyPasteProbeDumpPasteboard(_ tag: String) {
        let pb = UIPasteboard.general
        let s = pb.string
        keyPasteProbeLog("[\(tag)] numberOfItems=\(pb.numberOfItems) hasStrings=\(pb.hasStrings) "
            + "string=\(s.map { "\($0.count) chars: \($0.prefix(24))" } ?? "nil") providers=\(pb.itemProviders.count)")
    }

    /// 备用读法三连：`.string`（item-request 新路径）被拒时，试试老式
    /// `data(forPasteboardType:)` 与 `NSItemProvider.loadObject` —— 三条路走的是不同的
    /// daemon 请求，万一有一条能绕过 Xcode 27.0 这个坏掉的授权，那就是 App 侧的真修法。
    /// 只是探针诊断，⛔ 别把没验证过的读法直接搬进 `paste(_:)`。
    private func keyPasteProbeTryFallbackReads() {
        let pb = UIPasteboard.general
        let oldStyle = pb.data(forPasteboardType: "public.utf8-plain-text", inItemSet: nil)
        keyPasteProbeLog("[fallback-data] \(oldStyle.map { "\($0.count) bytes" } ?? "nil")")
        if let provider = pb.itemProviders.first {
            provider.loadObject(ofClass: String.self) { [weak self] obj, err in
                self?.keyPasteProbeLog("[fallback-provider] obj=\(obj.map { "\($0)" } ?? "nil") err=\(err?.localizedDescription ?? "nil")")
            }
        } else {
            keyPasteProbeLog("[fallback-provider] no provider")
        }
    }

    private func keyPasteProbeResetLog() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? Data().write(to: dir.appendingPathComponent("key_paste_probe.log"))
    }

    private func keyPasteProbeLog(_ line: String) {
        print("[KEYPASTE] \(line)")
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("key_paste_probe.log")
        guard let data = (line + "\n").data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}
#endif

// MARK: - 「图标 + 值 + 箭头」的字段按钮

/// 下拉那一颗字段（供应商 / 模型名称**共用同一个外观件**）：左图标（可选）+ 值 + 右侧箭头。
///
/// 为什么不是 `UITextField`：这里要表达的语义只有一个 —— **点一下弹选择页**。
/// 假输入框会被「点空白收键盘」「点同行挪光标」那套逻辑收进来，还会被无障碍读成文本框。
/// ⚠️ 模型名那一栏 2026-10-14 从「可编辑输入框」换成这颗 —— 与 Mac 侧 `fieldShell` 同款。
private final class AIAddModelFieldButton: UIControl {

    private let iconView = UIImageView()
    private let valueLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))

    /// - Parameter image: 左侧图标（**已取好**的 `UIImage`）。`nil` = 不画图标
    ///   （模型名那一栏就是 `nil`，与 Mac 侧同款）。
    ///   🔴 这里刻意收 `UIImage` 而不是「asset 名 / 符号名」两个字符串：
    ///     取图规则（asset 优先、符号兜底）只该有**一份**（`AIVendorIcon`），
    ///     交给这个只负责布局的控件再判一次，等于把退路抄成第二份。
    init(image: UIImage?, title: String) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.separator.cgColor

        valueLabel.font = AIChromeFont.ui(15)
        valueLabel.textColor = .label
        valueLabel.lineBreakMode = .byTruncatingMiddle

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .label
        // ⚠️ 这颗箭头**必须给足色与尺寸**（2026-10-14 实测踩坑）：第一版是
        //    `tintColor = .tertiaryLabel` + `12×12` 的框，截图里它被压成几乎看不见的一个淡点
        //    —— 而它就长在「这一栏能点开」这个语义上，看不见 = 用户根本不知道可以点。
        //    正解 = `.secondaryLabel`（浅色下 60% 黑，可见但不抢正文）+ 显式 `pointSize`
        //    （不给配置时按 body 字号解析，塞进小框后 `scaleAspectFit` 会把它再缩一圈）。
        chevron.tintColor = .secondaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        chevron.contentMode = .scaleAspectFit

        addSubview(valueLabel)
        addSubview(chevron)
        // ⚠️ 有图标 / 无图标是**两条布局分支**，不是「隐藏了还在占位」——
        //    模型名那一栏没有图标，隐藏式留白会让文字左缘多出一截空白。
        if image != nil {
            addSubview(iconView)
            iconView.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(12)
                make.centerY.equalToSuperview()
                make.width.height.equalTo(16)
            }
            valueLabel.snp.makeConstraints { make in
                make.leading.equalTo(iconView.snp.trailing).offset(8)
                make.centerY.equalToSuperview()
                make.trailing.lessThanOrEqualTo(chevron.snp.leading).offset(-8)
            }
        } else {
            valueLabel.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(12)
                make.centerY.equalToSuperview()
                make.trailing.lessThanOrEqualTo(chevron.snp.leading).offset(-8)
            }
        }
        chevron.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-12)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(14)
        }
        // ☠️☠️ 这里**刻意没有**任何「自我转发」，⛔ 别加回来。
        //
        // 第一版写的是 `@objc private func handleTap() { sendActions(for: .touchUpInside) }`
        // 并把 `handleTap` 用 `addTarget(self, …)` 挂在本控件的 `.touchUpInside` 上 ——
        // 那是**无限递归**：触摸结束 → UIKit 发 `.touchUpInside` → 调 `handleTap`
        // → 里面又 `sendActions(for: .touchUpInside)` → 又发一次 → 又调 `handleTap` → …
        //
        // 2026-10-14 用户在图示「添加模型」表单里**点「供应商」当场崩溃**。崩溃日志
        // （`~/Library/Logs/DiagnosticReports/Aster-*.ips`）的调用栈把这条环路打印得
        // 清清楚楚：`handleTap → _sendActionsForEvents:withEvent: → handleTap → …` 重复十几层，
        // 最后 `EXC_BAD_ACCESS (SIGSEGV) / KERN_PROTECTION_FAILURE` —— 是**栈溢出**打穿了保护页。
        //
        // 🔴 这个坑**编译不报、渲染/截图探针也照不出来**：`STARRY_SETTINGS_UI=provider` 那条
        //    钩子走的是**直接调 `openProviderPicker()`**，绕过了触摸派发这一层 ⇒
        //    前一轮八张截图全绿，而人手一点就崩。「探针过了」不等于「用户点了没问题」。
        //
        // ✅ `UIControl` 的触摸跟踪**本来就会**在「手指抬起且仍落在控件内」时发 `.touchUpInside`
        //    （`valueLabel` / `chevron` / `iconView` 默认 `isUserInteractionEnabled = false`，
        //     不挡触摸）⇒ 调用方那句 `addTarget(_:action:for: .touchUpInside)` 直接就能收到。
        //    佐证：下面 `isHighlighted` 的 `didSet` 每次按下都变色，说明 tracking 一直在正常工作。
        update(image: image, title: title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .tertiarySystemFill : .secondarySystemBackground }
    }

    /// 高度只在 `superview` 里定一次（`height == 44`）——
    /// ⚠️ 别在这里再写一遍 `snp.makeConstraints` 下的高度：两处高度会打架（约束冲突日志刷屏）。
    ///
    /// - Parameter dimmed: `true` = 用二级文字色（模型名为空时的「未设置」占位）。
    func update(image: UIImage?, title: String, dimmed: Bool = false) {
        iconView.image = image
        valueLabel.text = title
        valueLabel.textColor = dimmed ? .secondaryLabel : .label
    }
}

// MARK: - API Key 输入框（密文 + 键盘两个顽症的对策）

/// `keyField` 的专属子类 —— 2026-10-19 用户实测两个顽症，对策都收在这一处：
///
/// ## ① 键盘上方那条「Passwords」自动填充栏
/// iOS 12+ 的密码启发式**单凭 `isSecureTextEntry = true`** 就把字段判成登录密码框
/// （不显式设 `textContentType` 也照样判 —— Apple 文档口径 + SO 实测）⇒ 键盘上方冒出
/// 带钥匙图标的「Passwords」栏，点开是 iCloud 钥匙串 / 第三方密码管理器。
/// API Key **不是登录密码**：这一栏既误导（用户会以为 Key 被存进了钥匙串），
/// 又正是「长按不出粘贴」那件事的伴生症状。⇒ 给它一个**非凭证类** content type
/// 把启发式盖掉：`.oneTimeCode`（Apple 安全指南对 API token 类敏感字段的推荐值；
/// 该 API iOS 12+ 就有，本工程 target iOS 15，无需 `#available`）。
/// ⚠️ 别用 `UITextContentType("")`（空串 hack）—— iOS 12+ 起对密文字段不可靠（同帖实测）。
/// ⚠️ 更别为了消这条栏去掉 `isSecureTextEntry` —— 掩码 + 挡第三方键盘是它的安全本职
///    （OWASP MASTG 口径）；本类只改「键盘建议」，不动掩码。
///
/// ## ② 长按不出「粘贴」/ 出了也没反应
/// 密文态下系统菜单 historically 只保留「粘贴」一项（`copy`/`cut` 被 `isSecureTextEntry`
/// 禁掉是**既定安全语义** —— Apple 文档原文 "disables the user's ability to copy"），
/// 但「粘贴」这一项在部分 iOS 版本上会整条消失 ⇒ 显式放行，⛔ 别指望系统默认。
/// 🔴 **放行只是让菜单项显示出来**；密文字段对 `paste:` 的默认实现是空动作
///    （Apple 安全语义：不收剪贴板内容）⇒ 还必须自己实现 `paste(_:)`
///    （见下方 override 的注释）。两层缺一不可：只放行 = 项在但点了没反应（10-19 实测）。
/// 而「粘贴」是这个字段的**主要录入路径**（Key 都是从供应商后台复制来的）。
/// 🔴 只放行 `paste:`：`copy`/`cut`/`select`… 一律走系统默认 ——
///    把 Key 拷出字段是**不该存在**的能力，别为了「菜单看起来全」把它们放回来。
/// ⚠️ 恒返 true 而不是先查 `UIPasteboard.hasStrings`：免得在 `canPerformAction` 里
///    碰剪贴板（iOS 16+ 读剪贴板会弹「粘贴来源」横幅，长按菜单弹出那一拍弹它很怪）；
///    剪贴板真为空时 `paste(_:)` 里自然什么都不做。
private final class AIAPIKeyTextField: UITextField {

    /// 粘贴失败（剪贴板里读不到文本）时给宿主的一句提示 —— 由宿主接上 `AIToast`。
    ///
    /// 🔴 为什么失败**必须出声**：2026-10-19 用户实测「长按出粘贴、点下去没反应」，
    ///    真相是 Xcode 26.4 起模拟器「Mac 复制 → 模拟器粘贴」同步链断掉（系统 bug，
    ///    剪贴板确实是空的）。静默 return 让这件事看起来像 App 坏了，白绕一轮。
    /// ⚠️ 为什么不自己在字段上弹：字段不知道往哪贴合适（它自己就那么一行高），
    ///    宿主（添加模型页）才有整页视图与键盘高度信息。
    var onPasteFailed: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // 盖掉密码启发式 ⇒ 键盘上方不再出现「Passwords」栏（见类注释 ①）。
        textContentType = .oneTimeCode
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// 🔴 为什么必须自己实现 `paste:`（2026-10-19 用户实测：菜单项出来了，点下去**没反应**）
    ///
    /// `canPerformAction` 返 true 只负责让菜单项**显示**；真正被点击时系统调用的是
    /// `UIResponderStandardEditActions.paste(_:)`，而 **`isSecureTextEntry = true` 的字段
    /// 对这个方法的默认实现是空动作**——Apple 的既定安全语义：密文字段不收剪贴板内容
    /// （防恶意 App 借「剪贴板预置」往密码框塞值）。`copy`/`cut` 同理被禁。
    ///
    /// 但 API Key 不是登录密码，且「粘贴」恰是这个字段的**主要录入路径**
    /// （Key 都从供应商后台复制）⇒ 这里显式兑现这一下：自己读剪贴板 → `insertText`。
    ///
    /// ⚠️ trim 掉首尾空白/换行：从网页复制 Key 常带上尾随换行，留着会让校验必失败。
    /// 🔴 读不到内容时**必须出声**（`onPasteFailed` → toast），⛔ 别静默 return：
    ///    2026-10-19 用户遇到的正是「点了没反应 + 不知道为啥」—— 剪贴板确实是空的
    ///    （Xcode 26.4 起模拟器收不到 Mac 复制的内容，系统 bug，判据见探针注释）。
    ///    模拟器构建里那句话直接点名病因；`targetEnvironment(simulator)` 才编得进去，
    ///    ⚠️ 真机构建只会看到通用文案（这句永不随包发布）。
    override func paste(_ sender: Any?) {
        let trimmed = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            #if targetEnvironment(simulator)
            onPasteFailed?("模拟器剪贴板是空的：Xcode 26.4 起「Mac 复制→模拟器」同步已坏")
            #else
            onPasteFailed?(L("剪贴板里没有可粘贴的文本"))
            #endif
            return
        }
        insertText(trimmed)
        sendActions(for: .editingChanged)
    }
}
