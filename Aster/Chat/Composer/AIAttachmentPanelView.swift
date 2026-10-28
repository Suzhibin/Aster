//
//  AIAttachmentPanelView.swift
//  AIModule
//
//  Created by Suzhibin on 2026/9/14.
//

import UIKit
import Photos
import SnapKit
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

/// 输入栏「+」面板里的入口（相机 / 相册 / 文件 / 项目资料）。
/// `rawValue` 同时用作按钮 tag，顺序即从左到右，别随意调整。
///
/// 🔴 `.project`（2026-10-21）：**只在当前会话属于某个项目时出现**
/// （见 `AIAttachmentPanelView.setProjectEntryAvailable(_:)`）。
/// 它不是第四颗按钮那点位置的事 —— 一个跟项目无关的会话不该看见「项目资料」，
/// 那会让人以为「这个项目里有什么我不知道的东西」。默认态仍是三格，与上线前一致。
enum InputAttachmentKind: Int, CaseIterable {
    case camera, album, file, project

    /// 方块内的文案
    var title: String {
        switch self {
        case .camera:  return L("相机")
        case .album:   return L("相册")
        case .file:    return L("文件")
        case .project: return L("项目资料")
        }
    }

    /// SF Symbol 名
    var icon: String {
        switch self {
        case .camera:  return "camera"
        case .album:   return "photo"
        case .file:    return "folder"
        // 「一叠」= 资料库的通用意象；`.file` 已经占了 folder
        case .project: return "books.vertical"
        }
    }

    /// 默认显示的那几项（`.project` 由宿主按会话归属决定要不要加）
    static let defaultKinds: [InputAttachmentKind] = [.camera, .album, .file]
}

/// 输入栏「+」唤出的附件面板（相机 / 相册 / 文件），三个入口**平分屏宽**。
///
/// 它是 `InputToolbar` 的**子视图**，挂在输入行下方 —— 宿主把输入栏「长高」就是它顶起来了。
/// 挂自家视图树（而不是 `textView.inputView`）的好处：系统键盘来去、相册/文件那种全屏
/// picker 盖上来，都带不走它；开合动画也全归宿主控制，不用跟系统键盘那套通知较劲。
///
/// ⚠️ 总高由宿主按 frame 给（`panelTotalHeight`，与系统键盘等高），
/// 本视图内部把按钮那一行**贴在顶部**固定高 —— 多出来的高度给下面的**最近照片网格**
/// （`photoGrid`），底部再留出安全区，无论系统有没有额外补安全区，
/// 按钮和网格都不会被 Home 指示条压住。
///
/// 单个入口是**一整块浅灰圆角方块**：图标在上、文案在下，**两者都在方块内部**
/// （不是「图标一个方块 + 文案裸在下方」）。方块四边留 `Metrics.columnInset` 的间距，
/// 三列由 `row.distribution = .fillEqually` 平分屏宽，所以方块宽度自动跟着屏宽走。
final class AIAttachmentPanelView: UIView {

    /// 点击某一项
    var onSelect: ((InputAttachmentKind) -> Void)?

    /// 点了下方**最近照片网格**里的一张图（宿主负责取整图 → 落盘 → 进待发区）
    var onPickAsset: ((PHAsset) -> Void)?

    /// 点了面板里的**空白处**（三个入口之外、照片格子之外的区域）→ 宿主收起面板。
    ///
    /// 为什么用「手势 + 代理」而不是「垫一层透明按钮」：面板整块都被入口行和照片网格盖着，
    /// 垫在最底下的按钮根本收不到网格范围内的点击（`UICollectionView` 会把范围内的触摸全吃掉），
    /// 格子之间的缝、以及照片不满一屏时下方那块白就都点不动。
    /// 挂在面板这一层、再用代理把落在按钮 / 格子上的触摸剔掉（见 `shouldReceive`），
    /// 才能做到「除了能点的，剩下全是空白」。
    var onBlankTap: (() -> Void)?

    /// 面板底部的**安全区高度**（Home 指示条）。由宿主摆 frame 时同步过来。
    /// 网格要把这一段让出来，否则最后一行会被指示条压住。
    var bottomSafeInset: CGFloat = 0 {
        didSet {
            guard bottomSafeInset != oldValue else { return }
            setNeedsLayout()
        }
    }

    /// 「+」面板下半部分那块**最近照片网格**（入口那一行下面的全部空白）。
    /// 懒加载：不用到「+」就不建它，也就不会去碰相册权限。
    lazy var photoGrid: AIAttachmentPhotoGrid = {
        let grid = AIAttachmentPhotoGrid()
        grid.onPickAsset = { [weak self] asset in
            guard let self else { return }
            self.onPickAsset?(asset)
        }
        return grid
    }()

    /// 打开面板时叫一次：**第一次会问相册权限**，之后只重建列表（幂等，见 `reloadIfNeeded`）。
    func preparePhotoGrid() {
        photoGrid.reloadIfNeeded()
    }

    /// 会话归属变了 ⇒ 决定「项目资料」那一格要不要出来。
    ///
    /// 🔴 由宿主在**每次切会话 / 切项目归属**之后调（`refreshComposerBanner` 那条链的旁边）。
    /// ⚠️ 幂等：值没变就直接返回，不会反复拆装按钮（拆装会让正在播的进场动画错位）。
    func setProjectEntryAvailable(_ available: Bool) {
        var next = InputAttachmentKind.defaultKinds
        if available { next.append(.project) }
        guard next != kinds else { return }
        kinds = next
        rebuildRow()
    }

    #if DEBUG
    /// 🧪 探针专用只读出口：面板当前有哪几格（`STARRY_PANEL_PROBE` 判据用，
    /// 见 `AIModuleViewController.runPanelEntryProbeIfRequested`）。
    ///
    /// 为什么加它：`kinds` 是 `private`，而「切会话后第 4 格显隐对不对」这个 bug
    /// **编译零症状**（2026-10-24：`refreshComposerBanner` 调在 `switchToConversation`
    /// 之前，读到上一个会话的归属）⇒ 必须有个运行时判据，光靠 typecheck 证不了。
    /// ⛔ Release 包里没有这个属性，产品代码别读它。
    var debugKinds: [InputAttachmentKind] { kinds }
    #endif

    /// 按 `kinds` 重排那一行（拆掉旧的按钮、按新列表重建）
    private func rebuildRow() {
        row.arrangedSubviews.forEach {
            row.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for kind in kinds {
            row.addArrangedSubview(makeButton(kind))
        }
    }

    /// 内容区（按钮那一行）的高度。由宿主按 `InputToolbarConfigure.panelHeight` 同步过来。
    /// 方块自身高度 = 这个值 − `Metrics.columnInset * 2`，所以调小它整块会一起变小。
    var contentHeight: CGFloat = 100 {
        didSet {
            guard contentHeight != oldValue else { return }
            rowHeightConstraint?.update(offset: contentHeight)
        }
    }

    // MARK: - 尺寸

    /// ⚠️ 方块内容（图标 22 + 间距 6 + 文案 ≈17 ≈ 45）是高度的下限：
    /// `contentHeight - columnInset * 2` 必须大于它，否则图标和文案会被压在一起。
    private enum Metrics {
        /// 方块到列边缘的横向间距（决定三个方块之间、以及两侧的留白）
        static let columnInsetH: CGFloat = 16
        /// 方块到列边缘的纵向间距（决定方块高度）
        static let columnInsetV: CGFloat = 10
        static let boxCornerRadius: CGFloat = 14
        static let iconSide: CGFloat = 22
        static let iconTextSpacing: CGFloat = 6
        /// 三个入口依次浮现的间隔与初始下移量（见 `playStaggeredItemAppearance`）。
        /// ⚠️ 初始下移量**必须小于** `columnInsetV`：方块贴着按钮上下各 inset 这么多，
        /// 超了就会溢出按钮边界（父视图不裁剪，会露到输入栏上去）。
        static let staggerInterval: TimeInterval = 0.035
        static let staggerOffset: CGFloat = 8
    }

    private let row = UIStackView()
    private var rowHeightConstraint: Constraint?

    /// 当前显示哪几个入口（默认三格；会话属于某项目时多一格「项目资料」）
    ///
    /// ⚠️ 用**增删按钮**而不是「藏掉第四个」：`row.distribution = .fillEqually` 按
    /// 实际排列数平分宽度 —— 藏掉一个（`isHidden`）在 UIStackView 里确实会退出排布，
    /// 但多一格时那三格的宽度变化会晚一帧才到位（第一次开面板能看到「挤一下」）。
    /// 直接换掉排列项最干净：面板本来就是每次打开时现搭的。
    private var kinds: [InputAttachmentKind] = InputAttachmentKind.defaultKinds

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground   // 与输入栏同底，视觉上连成一片
        // 初始不显示：宿主点「+」时才摆好位置（`syncAttachmentPanelFrame`）并显示。
        // 不藏的话，第一次 layout 之前它是个 frame 为 .zero 的视图，里面的方块会以
        // 「宽度 0 但高度 100」这种畸形尺寸存在。
        isHidden = true

        row.axis = .horizontal
        row.distribution = .fillEqually       // 三个按钮平分屏宽
        row.alignment = .fill
        addSubview(row)
        row.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            rowHeightConstraint = make.height.equalTo(contentHeight).constraint
        }

        for kind in kinds {
            row.addArrangedSubview(makeButton(kind))
        }

        // 网格是 frame 布局（见 `layoutSubviews`）：面板总高是宿主按键盘高给的**常量**，
        // 用约束表达「占满剩余高度」反而要多绕一层。
        addSubview(photoGrid)

        // 空白处轻点 = 收起面板。落在按钮 / 格子上的触摸由代理剔除，
        // 所以这条手势不会抢走「点相册」「点某张图」这些正事。
        let blankTap = UITapGestureRecognizer(target: self, action: #selector(blankTapped))
        blankTap.delegate = self
        addGestureRecognizer(blankTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 网格占「入口那一行」到「底部安全区」之间的全部空白。
    ///
    /// ⚠️ 这一段高度**随机型变**（面板总高 = 系统键盘高，全面屏 ≈336、带 Home 键 ≈260），
    /// 所以这里只负责把可用高度给出去，行列怎么排由网格自己按实际尺寸算。
    override func layoutSubviews() {
        super.layoutSubviews()
        let top = contentHeight
        photoGrid.frame = CGRect(x: 0,
                                 y: top,
                                 width: bounds.width,
                                 height: max(0, bounds.height - top - bottomSafeInset))
    }

    // MARK: - 进场动画

    /// 与系统键盘动画时长对齐（`keyboardAnimationDuration` 通常是 0.25s）
    static let appearDuration: TimeInterval = 0.25

    /// 与系统键盘动画**同曲线**。系统在 `keyboardAnimationCurveUserInfoKey` 里给的是 `7`
    /// （系统键盘私有曲线，`UIView.AnimationCurve` 没有这个 case），只能按 rawValue 左移 16 位构造。
    /// 必须和输入栏「随键盘位移」那段用同一条曲线：时长一样但速度感不同的话，
    /// 面板内容滑动和输入栏浮动会差半拍，看着就是「差一点点顺」。
    static let systemCurveOptions = UIView.AnimationOptions(rawValue: 7 << 16)

    /// 播一次进场：本体淡入 + 三个入口依次从下方浮现。
    ///
    /// 由宿主在「面板顶起」那一刻主动调用 —— 面板现在是输入栏自己的子视图，
    /// 不再需要靠 `didMoveToWindow` 等系统把它挂上键盘窗口。
    /// 每次都是从初始态**重新设置**，所以可以反复播。
    ///
    /// 面板**本体**只做淡入，位移全部交给下面三个方块：
    /// 本体和方块都位移的话两层会叠加，看起来是「整块抖一下」而不是「依次浮现」。
    func playEntryAnimation() {
        // 上一次的淡出可能还在跑（用户收得快、开得也快）→ 先掐掉，
        // 否则它会和后加进来的动画抢 alpha，出现「忽明忽暗」。
        layer.removeAllAnimations()
        alpha = 0
        transform = .identity
        UIView.animate(withDuration: Self.appearDuration,
                       delay: 0,
                       options: [Self.systemCurveOptions, .beginFromCurrentState, .allowUserInteraction]) {
            self.alpha = 1
        }
        playStaggeredItemAppearance()
    }

    /// 三个入口**依次浮现**：从下方 `staggerOffset` 浮上来 + 淡入，每个间隔 `staggerInterval`。
    ///
    /// 面板高度已与系统键盘等高、切换时输入行一动不动 → 这层错落就是整个过渡里**唯一在动的东西**，
    /// 有它观感才「活」；不做的话整块面板只是一起淡入，跟图片加载没区别。
    /// ⚠️ 间隔别加大到 0.05 以上 —— 会显得拖沓，像在等加载。
    private func playStaggeredItemAppearance() {
        for (index, item) in row.arrangedSubviews.enumerated() {
            guard let box = item.subviews.first else { continue }   // 按钮里那一个圆角方块
            box.layer.removeAllAnimations()
            box.alpha = 0
            box.transform = CGAffineTransform(translationX: 0, y: Metrics.staggerOffset)
            UIView.animate(withDuration: Self.appearDuration * 0.8,
                           delay: Double(index) * Metrics.staggerInterval,
                           options: [Self.systemCurveOptions, .beginFromCurrentState, .allowUserInteraction]) {
                box.alpha = 1
                box.transform = .identity
            }
        }
    }

    // MARK: - 构建

    /// 单个入口：**整块**一个浅灰圆角方块，图标 + 文案都装在里面。
    /// 整列都是点击热区（按钮本身就是一列），比只点方块好按。
    private func makeButton(_ kind: InputAttachmentKind) -> UIButton {
        let button = UIButton(type: .custom)
        button.tag = kind.rawValue
        button.accessibilityLabel = kind.title
        button.addTarget(self, action: #selector(itemTapped(_:)), for: .touchUpInside)

        let box = UIView()
        box.backgroundColor = .secondarySystemFill
        box.layer.cornerRadius = Metrics.boxCornerRadius
        box.isUserInteractionEnabled = false

        let icon = UIImageView(image: UIImage(systemName: kind.icon))
        icon.tintColor = .label
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20)

        let title = UILabel()
        title.text = kind.title
        title.font = .systemFont(ofSize: 12)
        title.textColor = .secondaryLabel
        title.textAlignment = .center

        let column = UIStackView(arrangedSubviews: [icon, title])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = Metrics.iconTextSpacing
        column.isUserInteractionEnabled = false

        box.addSubview(column)
        button.addSubview(box)
        // ⚠️ 横向这几条**必须是 999 而非 required**（`icon.width == 22` 才是真硬规则，不动）。
        //
        // 本视图是**frame 布局**的（宿主在 `syncAttachmentPanelFrame` 里摆 frame），所以布局引擎会把
        // frame 翻译成 `NSAutoresizingMaskLayoutConstraint`（`width == 0` / `width == 375` …）。
        // 而面板在 init 就被 `addSubview` 了、宿主却要等「点 +」才给它 frame —— 中间这段时间它宽度是 0：
        //     0（面板）− 16×2（方块左右 inset）< 22（图标宽）
        // 于是「row 钉死面板左右 → 三列 fillEqually → 方块左右各 16 → 内容至少 22pt」这条链
        // **在 required 下无解**，引擎只能破坏一条 required，UIKit 就打印
        // `Unable to simultaneously satisfy constraints`（实测被破坏的正是 `UIImageView.width == 22`）。
        //
        // 语义上这三条也只是「尽量」：方块距列边**尽量** 16、内容距方块**尽量**留 4。
        // 降到 999 后，窄容器里被牺牲的是它们（被压缩的 optional 不报错），required 全部保住；
        // 正常宽度（= 屏宽/3，约 125pt）下四条依然被精确满足 —— 实测 375 宽时两模式帧值逐项相同。
        box.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(Metrics.columnInsetH).priority(999)
            make.trailing.equalToSuperview().inset(Metrics.columnInsetH).priority(999)
            make.top.equalToSuperview().inset(Metrics.columnInsetV)
            make.bottom.equalToSuperview().inset(Metrics.columnInsetV)
        }
        // 内容整体居中，宽度由图标 / 文案里较宽的那个决定（窄屏长文案也不会顶出方块）
        column.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.greaterThanOrEqualToSuperview().inset(4).priority(999)
            make.trailing.lessThanOrEqualToSuperview().inset(4).priority(999)
        }
        icon.snp.makeConstraints { make in
            make.width.height.equalTo(Metrics.iconSide)
        }
        return button
    }

    @objc private func itemTapped(_ sender: UIButton) {
        guard let kind = InputAttachmentKind(rawValue: sender.tag) else { return }
        onSelect?(kind)
    }

    @objc private func blankTapped() {
        onBlankTap?()
    }
}

// MARK: - 空白处判定

extension AIAttachmentPanelView: UIGestureRecognizerDelegate {

    /// 只认「空白处」：从命中的视图往上走到面板本体，途中只要碰到交互元素就把这次点击让给对方。
    ///
    /// - 三个入口、拒绝态那行「去设置开启相册权限」都是 `UIButton`（`UIControl`）；
    /// - 照片格子（含 `limited` 态末尾那个「管理」）是 `UICollectionViewCell`。
    ///
    /// 命中集合视图的空白区时，命中的就是 `UICollectionView` 本身 —— 既不是 `UIControl`
    /// 也不是 cell → 判定为空白 ✓（这正是「照片不满一屏时点下方那块白」的那条路）。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        var current = touch.view
        while let view = current, view !== self {
            if view is UIControl || view is UICollectionViewCell { return false }
            current = view.superview
        }
        return true
    }
}
