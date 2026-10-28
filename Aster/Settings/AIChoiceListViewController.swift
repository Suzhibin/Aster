//
//  AIChoiceListViewController.swift
//  Aster
//
//  档位选择页（语言 / 外观 / **字体大小** 三页共用这一份）—— 2026-10-14 新建。
//  （「通知提示音」2026-10-18 曾并入本页，2026-10-19 随提示音功能一起删除。）
//
//  ## 它是从哪搬来的
//  这一页的内容原来在**账号弹窗的二级页**里（`AIAccountMenuViewController` 的
//  `appearancePage` / `languagePage`）。用户 2026-10-14 要求把这两个入口
//  收进设置页 ⇒ 二级页随之从「弹窗里翻层」改成「设置页 push 一整页」。
//  ⚠️ 搬运**只动了形态**，写偏好那两条路的语义一个字没改（见下面两段）。
//
//  ## 🔴 语言：必须先关自己、再写偏好
//  `L()` 是普通函数、**不登记任何观察依赖**（见 `AILocalization.swift` 文件头）⇒
//  不重建界面的话，除了本页自己，屏幕上所有文案都会停在旧语言。
//  重建由 `SceneDelegate` 监听 `AILanguageStore.didChange` 完成（它才持有 window）。
//  🔴 顺序刻意是「**先关自己、关完再写偏好**」：`NotificationCenter.post` 是**同步**投递的
//  ⇒ 写偏好的那一行就会触发重建、而重建会换掉 window 的 rootViewController ⇒
//  本页连同它所在的整个模态当场被销毁。放进 `dismiss` 的 completion 里，等转场跑完再换，干净。
//  ⚠️ 这里 `dismiss` 会**关掉整个模态**（本页是被 push 进那个 nav 的，`presentingViewController`
//  一路向上解析到 nav 的呈现者）—— 正是想要的：语言换完整棵界面重建，设置页不该留着。
//
//  ## 🔴 外观：**留在本页**
//  `AIAppearanceStore.current` 的 setter 内部就会 `apply`（改所有 window 的
//  `overrideUserInterfaceStyle`）⇒ 本页自己当场换色。留着不走，用户想再试另一档不用重新点进来。
//  ⛔ 别在这儿补一句 `AIAppearanceStore.apply(...)`：两处都改将来必漏一处。
//
//  ## 主题
//  全部用**语义色**（`.systemGroupedBackground` / `.label` / `.systemBlue` …）⇒
//  用户在**本页**切档时，`AIAppearanceStore` 改的是本 window 的 `overrideUserInterfaceStyle`，
//  本页自己就跟着重绘（这正是「外观开关放在自己身上」必须做到的事）。
//

import UIKit
import SnapKit
import AICore

final class AIChoiceListViewController: UIViewController {

    // MARK: - 种类

    /// 这一页在选什么。语言 / 外观 / 字号**结构完全一样**（若干档 + 打勾 + 一行说明），
    /// 差的只有「选项从哪来」与「选完干什么」⇒ 用同一个 VC + 一个枚举，
    /// ⛔ 别复制成两份 —— 两份的下一步一定是「说明行的措辞只改了一边」。
    enum Kind {
        case language
        case appearance
        case fontSize

        var pageTitle: String {
            switch self {
            case .language:   return L("语言")
            case .appearance: return L("外观")
            case .fontSize:   return L("字体大小")
            }
        }

        /// 列表下面那行**灰色说明**。
        /// ⚠️ 各页**刻意不同**：外观是「立刻生效」，语言是「只翻文案」，
        ///    字号是「只管对话里的字」—— 共用一句用户会以为它说的是同一件事
        ///    （与账号弹窗那两页同款理由）。
        var note: String {
            switch self {
            case .language:   return L("只切换界面文案，AI 回复不受影响")
            case .appearance: return L("立即应用到所有窗口")
            case .fontSize:   return L("调整对话中文字的大小，立即生效")
            }
        }
    }

    /// 一档选项（把几个不同的枚举收成一个值，好让表格只有一份代码）。
    private enum Option {
        case language(AILanguage)
        case appearance(AIAppearance)
        case fontSize(AIFontSizeScale)

        var title: String {
            switch self {
            case .language(let value):   return value.title
            case .appearance(let value): return value.title
            case .fontSize(let value):   return value.title
            }
        }

        var symbol: String {
            switch self {
            case .language(let value):   return AIChoiceListViewController.symbol(for: value)
            case .appearance(let value): return AIChoiceListViewController.symbol(for: value)
            case .fontSize(let value):   return AIChoiceListViewController.symbol(for: value)
            }
        }
    }

    // MARK: - 状态

    private let kind: Kind

    private var options: [Option] {
        switch kind {
        case .language:   return AILanguage.allCases.map(Option.language)
        case .appearance: return AIAppearance.allCases.map(Option.appearance)
        case .fontSize:   return AIFontSizeScale.allCases.map(Option.fontSize)
        }
    }

    // MARK: - UI

    private static let cellID = "AIChoiceCell"

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.backgroundColor = .systemGroupedBackground
        tv.dataSource = self
        tv.delegate = self
        tv.rowHeight = 52
        tv.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        return tv
    }()

    // MARK: - 生命周期

    init(kind: Kind) {
        self.kind = kind
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = kind.pageTitle
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in make.edges.equalToSuperview() }
    }

    // MARK: - 状态读取

    /// 某一档是不是**当前档**。
    ///
    /// ⚠️ **每次点击现读** `…Store.current`，不缓存 —— 缓存只会在别处改过偏好之后给出错的勾
    ///（Mac 侧那张 `NSMenu`、账号弹窗那两页都是同一个口径）。
    private func isCurrent(_ option: Option) -> Bool {
        switch option {
        case .language(let value):   return value == AILanguageStore.current
        case .appearance(let value): return value == AIAppearanceStore.current
        case .fontSize(let value):   return value == AIFontSizeStore.current
        }
    }

    /// 选中一档。
    private func select(_ option: Option) {
        switch option {
        case .appearance(let value):
            // 只写存取点：setter 内部就会 `apply`（改所有 window 的 overrideUserInterfaceStyle）。
            AIAppearanceStore.current = value
            // 选完**留在本页**：切档后本页自己就换色了，用户想再试另一档不用重新点进来。
            tableView.reloadData()
        case .fontSize(let value):
            // 与外观同一套理由：选完**留在本页**，用户想再比一档不用重新点进来。
            // 🔴 只写存取点 —— setter 内部会**清 `AIMarkdown` 两份缓存** + 推版本号 + 发通知，
            //    会话页收到通知后自己 `recomputeAllRowHeights()` + `reloadData()`（见 `AIModuleViewController`）。
            //    ⛔ 别在这里手动 reload 会话页 / 手动清缓存：清理点只此一处（`AIFontSizeStore`）。
            AIFontSizeStore.current = value
            // 勾要跟着动：本页是普通 table，`isCurrent` 每次建 cell 现读 ⇒ reload 一次就够。
            tableView.reloadData()
        case .language(let value):
            // 点了当前档：什么都不做（不重建 = 不闪）。
            guard value != AILanguageStore.current else { return }
            // 🔴 顺序见文件头：先关自己（整个模态），关完再写偏好。
            dismiss(animated: true) {
                AILanguageStore.current = value
            }
        }
    }

    // MARK: - 图标

    /// 外观三档各自的图标。
    static func symbol(for appearance: AIAppearance) -> String {
        switch appearance {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }

    /// 语言三档各自的图标。
    ///
    /// ⚠️「跟随系统」用与外观同一颗 `circle.lefthalf.filled`：两者语义相同（交给系统），
    ///   同一颗图标能让用户一眼看出「这两行是一类东西」。
    static func symbol(for language: AILanguage) -> String {
        switch language {
        case .system: return "circle.lefthalf.filled"
        case .zhHans: return "character.book.closed"
        case .en:     return "globe"
        }
    }

    /// 字号四档各自的图标。
    ///
    /// ⚠️ **四档同一颗**（`textformat`）：`textformat.size.*` 那一族是 SF Symbols 4（iOS 16+），
    ///    本工程 target 是 iOS 15 ⇒ 在老系统上 `UIImage(systemName:)` 返 nil，图标会凭空消失。
    ///    档位靠**标题文字**（小 / 默认 / 大 / 特大）区分，不靠图标 ⇒ 四档共用不会少图。
    static func symbol(for fontSize: AIFontSizeScale) -> String { fontSize.symbol }
}

// MARK: - 列表数据源

extension AIChoiceListViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        options.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        guard options.indices.contains(indexPath.row) else { return cell }
        let option = options[indexPath.row]
        var config = UIListContentConfiguration.cell()
        config.text = option.title
        config.image = UIImage(systemName: option.symbol)
        // 🔴 字号走 `AIChromeFont`（2026-10-22 接字号档位）：显式钉 `.body`（即系统默认
        //    那一档）而不是吃默认值 —— 默认值不随档位走，本页就会「半生效」。
        //    ⚠️ 本页是字号档位的**所在地**：`select(.fontSize)` 写完存取点会
        //    `tableView.reloadData()` ⇒ 这里现读新档位，用户点完当场看到行变大。
        config.textProperties.font = AIChromeFont.ui(.body)
        // 选中那档走强调色（与 App 里其它「选中」语义同源）
        let on = isCurrent(option)
        config.textProperties.color = on ? .systemBlue : .label
        config.imageProperties.tintColor = on ? .systemBlue : .label
        config.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17)
        // 🔴 正文右侧给勾让位 —— 与下面那次 `aiApplyCheckmark` 是**成对的**（漏了它长文案会被勾压住）。
        config.directionalLayoutMargins.trailing = UITableViewCell.aiCheckmarkReserve
        cell.contentConfiguration = config
        // 🔴 右侧那颗勾**恒占位、只翻可见性**（本工程铁律）。
        //    ⚠️ 具体怎么做**只看 `aiApplyCheckmark(_:)` 那一处**（文件末尾那条扩展）——
        //    第一版用 `accessoryView` + `alpha`，被系统在配置更新流程里重置成了「全勾」，
        //    成因与正解都记在那个函数头上，⛔ 别在这儿另写一套。
        cell.aiApplyCheckmark(on)
        cell.backgroundColor = .secondarySystemGroupedBackground
        return cell
    }

    /// 说明行（组尾）。
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        kind.note
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard options.indices.contains(indexPath.row) else { return }
        select(options[indexPath.row])
    }
}

// MARK: - 行尾那颗勾（选择页 4 处共用）

/// 勾视图的**身份令牌**：`UIImageView` 的私有子类，只为「在 `contentView.subviews` 里认出来」而存在。
/// ⚠️ 刻意**不用 `tag`**：本工程别处也有用 `tag` 的地方，数字撞车是个**静默** bug（拿错视图、不报错）。
private final class AICheckmarkView: UIImageView {}

extension UITableViewCell {

    /// 「正文右侧给勾让位」的留白宽度 —— **唯一常量**。
    /// 构成：勾本体 20pt 宽 + 距右 16pt + 与文字留 4pt。
    /// 🔴 它必须与 `aiApplyCheckmark(_:)` **成对出现**（见那个函数头上的说明 ①）。
    static let aiCheckmarkReserve: CGFloat = 40

    /// 列表行右侧那颗「**恒占位、只翻可见性**」的勾（语言 / 外观 / 供应商 / 模型 四页共用）。
    ///
    /// ## 为什么不用 `accessoryType = on ? .checkmark : .none`
    /// 那会让「有没有 accessory」影响正文的可用宽度 ⇒ 选中态一变整行**横着抖一下**
    ///（本工程 hover 显隐那条铁律的同源问题）。
    ///
    /// ## ☠️☠️ 为什么也不用 `cell.accessoryView` + `alpha`（**2026-10-14 实测踩坑：第一版就是这么写的**）
    /// `cell.contentConfiguration = …` 的赋值 / 随后的布局过程里，**自己设的 `accessoryView.alpha` 留不住**
    ///（表现：明明只该有一行打勾，**每一行都画着勾**）。
    /// 症状特别好认 —— 同一张截图里「当前档」那行的**蓝色强调色只有一行**（说明 `on` 判据是**对的**）
    /// ⇒ 一眼就能把「判据错」排除掉，锁定在「显隐没留住」。
    /// 危害不止难看：这几个页面的**唯一**「当前选的是哪一条」的指示就是这个勾
    /// ⇒ 全勾 = 整页读不出当前值，选择页等于废了。
    /// ⚠️ 顺手记一笔：`UITableViewCell` 上**没有** `accessories`（那是 `UICollectionViewListCell` 的），
    ///    ⇒ 「换 `UICellAccessory` 就没事了」这条路在 UITableView 上**走不通**（编译期就报
    ///    `cannot find 'accessories' in scope`，已实测）。
    ///
    /// ## ✅ 正解 = 干脆绕开 cell 的 accessory 机制，勾**自己画在 `contentView` 里**
    /// 勾视图挂在 `contentView` 上（`contentView` 的自定义子视图系统不会去动），
    /// 每次 `cellForRowAt` 只翻它的 `alpha` —— 与账号弹窗那些自绘行（`AIAccountMenuRow`）
    /// 是同一条**已被验证**的路。
    ///
    /// ## ⚠️ 两条配套约束（漏一条就出静默毛病）
    /// ① **正文必须让出右侧那 40pt**：`config.directionalLayoutMargins.trailing = Self.aiCheckmarkReserve`
    ///    —— 漏了它，长的模型名会一直伸到勾底下，看着像勾压在字上（短名字上看不出来）。
    /// ② 勾视图**恒存在**、只翻 `alpha`（⛔ 别写成 `on ? addSubview : removeFromSuperview`：
    ///    加/删的时机与 cell 复用纠缠不清，纯属自找麻烦）。
    func aiApplyCheckmark(_ on: Bool, tint: UIColor = .systemBlue) {
        let check: AICheckmarkView
        if let existing = contentView.subviews.first(where: { $0 is AICheckmarkView }) as? AICheckmarkView {
            check = existing
        } else {
            check = AICheckmarkView(image: UIImage(systemName: "checkmark"))
            check.contentMode = .scaleAspectFit
            check.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(check)
            NSLayoutConstraint.activate([
                check.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                check.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
                check.widthAnchor.constraint(equalToConstant: 20),
                check.heightAnchor.constraint(equalToConstant: 20),
            ])
        }
        check.tintColor = tint
        check.alpha = on ? 1 : 0
    }
}

// MARK: - 🧪 探针专用（`STARRY_I18N_TRACE=1`，见 `I18NTraceProbe.swift`）

#if DEBUG
extension AIChoiceListViewController {

    /// 走真实入口点语言档（本体就是 `select(_:)` —— 连「先关自己、关完再写偏好」那条顺序一起复用）。
    /// ⛔ 探针里**绝不许**直接写 `AILanguageStore.current`：那条不是用户走的路。
    func debugSelectLanguage(_ option: AILanguage) { select(.language(option)) }
}
#endif
