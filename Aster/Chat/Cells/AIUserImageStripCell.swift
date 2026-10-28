//
//  AIUserImageStripCell.swift
//  Aster
//
//  用户一次发送里的**多张图横排一条**（2026-10-09 用户要求：
//  「iOS端 我发送的图片 如果是多个图片，就是横排显示，而且要缩小现在的 4/1。单张的图片 大小不变」）。
//
//      ┌───┐┌───┐┌───┐┌──┈┈
//      │图1 ││图2 ││图3 ││图4┈┈ ← 同一轮里的用户图，横向排一行，放不下就横滑
//      └───┘└───┘└───┘└──┈┈
//
//  ## 🔴 挂在**组首**那一行（同助手侧那套机制）
//
//  数据层是「一块一行」，一次发 5 张图在容器里就是**五行** ⇒ 组首那个 cell 把整组画出来
//  （`AIChatMediaGrouping.userImageGroupRows`），组内其余行高度由
//  `AIChatManager.normalizeUserImageGroupHeights()` **归零**。
//  ⚠️ 这与助手侧 `AIAssistantMediaStripCell` 是**同一套机制**，⛔ 别改成换数据源
//  （Mac 那种「显示项投影」）：`indexPath.row` 的语义一变，多选删除 / 搜索定位 / 引用跳转 /
//  TTS / 编辑态 / 操作卡全都要再加一层「显示项 ↔ 行」的映射—— 那是本工程最容易出错的地方。
//
//  ## ⛔ 与助手侧那个 cell 是**两个类**（别合并）
//
//  | | 用户侧（本文件） | 助手侧（`AIAssistantMediaStripCell`） |
//  |---|---|---|
//  | 格子尺寸 | `userImageDisplaySize(…scale: userImageStripScale)`：**按真实宽高比**、整档 ×`userImageStripScale`（0.25→0.5，2026-10-09 调档） | 固定 **108×192 竖版 9:16**、`.fill` 裁切 |
//  | 格子高 | **每张各自的高**（竖图就是竖的）⇒ 行高 = 最高那张 | 恒 192（所以它能把高度写死成常量） |
//  | 对齐 | **右对齐 + 底边齐平**（用户消息整体贴右） | 左起 + 顶部对齐 |
//  | 分组判据 | `AIChatMediaGrouping.userImageGroupRange` | `AIChatMediaGrouping.kind(of:)` |
//
//  ⛔ **别把两边并成一套**：尺寸口径完全不同。合成一个必然出现「用户图被裁成 9:16」
//  或「助手图退回按真实比例」这种回潮。
//
//  ## 🔴 右对齐必须**分两支**（与 Mac 的 `UserImageStrip` 同一条解法）
//
//  「放得下 ⇒ 贴右；放不下 ⇒ 横滑」在 UIKit 上**不能靠一条约束表达**，两条都不成立：
//
//  - `stack.frame(maxWidth: .infinity, alignment: .trailing)`：横向 `ScrollView` 对内容是
//    **无界提议** ⇒ `.infinity` 是空操作（Mac 侧同一条教训）。
//  - `stack.trailing == scrollView.contentLayoutGuide.trailing`：`contentLayoutGuide` 只决定
//    **内容起点**，内容比可视区窄时 stack 依然贴**左缘** ⇒ 右对齐完全失效。
//
//  ⇒ 判据是纯算术（`contentWidth > 可用宽`），两支各自一套约束：
//  **放得下 ⇒ stack 直接挂 container.trailing**；**放不下 ⇒ 进 scrollView 贴 leading**。
//
//  ## 🔴🔴 高度不许成环（2026-10-09 用户实拍「整条不显示」换来的）
//
//  踩过的形状：`stack` 的 `top` / `bottom` / `height` **全部**钉到 `contentLayoutGuide`
//  ⇒ `contentLayoutGuide` 的高度只能由 stack 撑出来，而 stack 的高度又等于它 ⇒ **约束成环**
//  ⇒ 整条塌成 0 ⇒ **横排彻底看不见**（图上与「这一行本来就没内容」一模一样，
// 极易跑去查数据源与判据）。助手侧不犯这个错是因为它把高度钉在**具体常量** 192 上；
//  本 cell 每组高度不同，必须现算，但**只能算一次、钉成常量**。
//
//  ## 尺寸全部取共享层那一个函数（不另算一遍）
//
//  每格都调 `AIChatRow.userImageDisplaySize`，`scale` 传 `AIChatRow.userImageStripScale`
//  ⇒ 与行高量算（`userImageGroupRowHeight`）**同源**。
// ⛔ 别在这里写 `contentWidth * 0.62 / 3` 这种「按张数摊」——
// 那会让同一张图在 1 张 / 3 张 / 5 张下三个大小，而行高那边算的是「整组最高那格」，
// 于是又变成「量的时候按 A、布局按 B」（本工程行高错乱的头号来源）。
//
//  ## ⚠️ 单张不走本 cell
//
//  用户明确「单张的图片大小不变」⇒ 单张仍是**一图一行的原尺寸**（`AIUserImageCell`）。
//  分流判据在 `+Table.cellForRowAt`：**组内张数 > 1** 才用这里。
//  本 cell 因此**永远至少有两格**，不存在「一格也要贴右对齐」的边界 ——
//  但那一档仍由同一个 `overflows` 判据自然覆盖（1 格必然放得下）。
//

import UIKit
import SnapKit
import AICore

public final class AIUserImageStripCell: UITableViewCell {

    /// 点某一格里的图片 → 全屏预览。参数是那一格的缩略图视图（供 zoom 转场定位起止位置）。
    ///
    /// ⚠️ 带的是**视图**而不是下标：cell 复用后下标会漂，视图不会（同 `AIUserImageCell.onPreview`）。
    public var onPreview: ((URL, UIView) -> Void)?

    /// 定位容器。铺满 `contentView` 宽；右侧那 12 的留白由内部两条分支各自表达，
    /// 这样「贴右」与「横滑」不会互相干扰。
    private let container = UIView()

    /// 横向滚动容器。⚠️ **只在放不下时**才把 `stack` 挂进来（见文件头「右对齐必须分两支」）。
    private let scrollView = UIScrollView()

    /// 格子容器。⚠️ `alignment = .bottom`（底边齐平，竖图高横图矮时像桌上摆一排照片）。
    private let stack = UIStackView()

    /// 圆角与留白。与 `AIUserImageCell` 同一档 —— 用户图在两端是同一个视觉家族，
    ///⛔ 别在任一处另写一个数字（那边是 `rightInset = 12`）。
    private enum Metrics {
        static let corner: CGFloat = 12
        /// 右侧留白（贴右那支用）。与 `AIUserImageCell.Metrics.rightInset` 同值。
        static let rightInset: CGFloat = 12
        /// 上下留白，合计 12 = 与单张那笔 `+12` 同口径。
        static let insetV: CGFloat = 6
    }

    /// 本组用到的容器宽（外部传入，与量行高用的是同一个值）。
    private var containerWidth: CGFloat = 0

    /// 本组的每格尺寸（算一次、复用给所有格，别每格都算一遍）。
    private var cellSizes: [CGSize] = []

    /// 这一组是「放得下」（贴右）还是「放不下」（进 scrollView 横滑）。
    ///
    /// ⚠️ 这就是文件头那条「右对齐必须分两支」的判据，**纯算术**：
    /// 各格宽之和 + 格间距，与「容器宽 - 右侧留白」比。
    private var overflows: Bool { contentWidth > containerWidth - Metrics.rightInset }

    /// 本组内容的总宽（各格宽之和 + 格间距）。
    private var contentWidth: CGFloat {
        guard !cellSizes.isEmpty else { return 0 }
        let cells = cellSizes.reduce(0) { $0 + $1.width }
        return cells + AIChatRow.userImageStripSpacing * CGFloat(cellSizes.count - 1)
    }

    /// 本组最高那一格的高度 —— **行高真值**（`userImageGroupRowHeight` = 它 + 上下 12）。
    private var tallestCellHeight: CGFloat { cellSizes.map(\.height).max() ?? 0 }

    /// 容器宽（外部传入，与量行高用的是同一个值）。
    ///
    /// ⚠️ 必须传**行高量算时那个 `contentWidth`**，不能传 `UIScreen` 或 cell 的 bounds.width ——
    /// 后两者在分屏 / 编辑态内缩下与真实值不一致 ⇒ 每格尺寸与行高对不上（那条横排会被裁一截）。
    /// - Parameter rows: **整组**行。组内非组首传**空数组**（它们高度为 0，见文件头）。
    public func configure(rows: [AIChatRow], containerWidth: CGFloat) {
        clearThumbs()
        self.containerWidth = containerWidth
        let scale = AIChatRow.userImageStripScale
        cellSizes = rows.map { AIChatRow.userImageDisplaySize(in: containerWidth,
                                                              mediaSize: $0.block.mediaSize,
                                                              scale: scale) }
        for (index, row) in rows.enumerated() where index < cellSizes.count {
            stack.addArrangedSubview(makeThumb(for: row, size: cellSizes[index]))
        }
        applyLayout()
    }

    /// 按「放得下 / 放不下」重建这一组的约束。
    ///
    /// 🔴 `remakeConstraints` 而不是两套约束切换：`UIScrollView` 的 `contentLayoutGuide`
    /// 一旦离开 scrollView 就没有意义，留着旧约束只会得到一堆冲突日志。
    private func applyLayout() {
        let height = tallestCellHeight
        if overflows {
            scrollView.isHidden = false
            if stack.superview !== scrollView {
                stack.removeFromSuperview()
                scrollView.addSubview(stack)
            }
            scrollView.snp.remakeConstraints { make in
                make.top.bottom.left.equalToSuperview()
                make.right.equalToSuperview().offset(-Metrics.rightInset)
            }
            stack.snp.remakeConstraints { make in
                make.edges.equalTo(scrollView.contentLayoutGuide)
                // 🔴 高度钉成**算出来的常量**，⛔ 别改成 `top.bottom.height` 三连全钉
                //    contentLayoutGuide（成环 ⇒ 整条塌成 0 ⇒ 完全不显示）。
                make.height.equalTo(height)
            }
        } else {
            scrollView.isHidden = true
            if stack.superview !== container {
                stack.removeFromSuperview()
                container.addSubview(stack)
            }
            stack.snp.remakeConstraints { make in
                make.top.bottom.equalToSuperview()
                // 贴右；`leading` 只要求 ≥ ⇒ 一格也自然贴右，且不会被拉变形。
                make.trailing.equalToSuperview().offset(-Metrics.rightInset)
                make.leading.greaterThanOrEqualToSuperview()
                make.height.equalTo(height)
            }
        }
    }

    private func clearThumbs() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        cellSizes = []
    }

    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // ⚠️ 指示器关掉：这一条只有几十 pt 高，常驻一条细线很显眼。
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true        // 放不下时能滑
        scrollView.contentInsetAdjustmentBehavior = .never
        contentView.addSubview(container)
        container.addSubview(scrollView)

        stack.axis = .horizontal
        stack.alignment = .bottom                          // 底边齐平
        stack.spacing = AIChatRow.userImageStripSpacing

        // `container` 铺满整行宽、上下各内缩 6（6+6 = 与单张那笔 +12 同口径 ⇒
        // 与 `userImageGroupRowHeight` 的 `+12` 正好凑成同一个数）。
        // ⚠️ 左右**不**在这里内缩：右侧那 12 交给 `applyLayout()` 的两支各自表达。
        container.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(Metrics.insetV)
            make.left.right.equalToSuperview()
        }
        // ⚠️ 本 cell **不做** `contentView` 级手势：那会与 `UIScrollView` 的 pan 抢触摸，
        //    症状是「横滑滑不动、或者一点就开预览」。命中区**逐格**挂（见 `makeThumb`）。
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 一格

    /// 造一个格子：**按各自比例**给宽高（竖图窄、横图宽），只有高参与底边齐平。
    private func makeThumb(for row: AIChatRow, size: CGSize) -> UserImageThumbView {
        let thumb = UserImageThumbView()
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = Metrics.corner
        // ⚠️ 宽高都要钉：`alignment = .bottom` 只对齐底边、不约束尺寸。
        // 只钉高会让宽度被压缩（图片被拉变形），只钉宽会让高度按比例跑掉。
        thumb.snp.makeConstraints { make in
            make.width.equalTo(size.width)
            make.height.equalTo(size.height)
        }

        let image = UIImageView()
        // 🔴 `.scaleAspectFit`（不是助手侧那个 `.fill`）：这一侧按**真实比例**给格子尺寸，
        // 再裁就等于把用户精心选的构图裁掉。
        image.contentMode = .scaleAspectFit
        image.clipsToBounds = true
        image.backgroundColor = .tertiarySystemFill
        thumb.addSubview(image)
        image.snp.makeConstraints { make in make.edges.equalToSuperview() }

        guard let url = row.block.imageURL else { return thumb }
        // 本地附件走降采样：按「实际要显示的像素」解码，别把整张 1600px 读进内存。
        let target = max(size.width, size.height) * UIScreen.main.scale
        image.image = AIAttachmentStorage.image(at: url, maxPixelSize: target)
        thumb.onTap = { [weak self, weak image] in
            guard let self = self, let view = image else { return }
            self.onPreview?(url, view)
        }
        return thumb
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        clearThumbs()
        containerWidth = 0
        onPreview = nil
    }
}

// MARK: - 一格

/// 一个格子：负责圆角 / 裁切 / 点击。
///
/// ⚠️ **刻意不是 `UIControl`**（助手侧那个格子也是）：宿主的表格长按手势有一条
/// 「命中 `UIControl` 就把触摸整个让出去」的规则（`gestureRecognizer(_:shouldReceive:)`），
/// 那样这一格就**弹不出操作卡**了。用 `UIView` + 手势，命中区仍是整格。
private final class UserImageThumbView: UIView {

    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemFill
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped() { onTap?() }
}

// MARK: - AIChatContentBlockProviding

/// 内容块 = **格子容器**（长按照到这里才弹操作卡；横排右边的空白不该弹卡）。
///
/// ⚠️ 不能给 `scrollView`：它铺满整行宽，长按右侧空白也会命中。
/// ⚠️ 不能给 `container`：放得下那支它铺满整行、且右缘那 12 留白也不该响应。
/// 与 `AIAssistantMediaStripCell` 同一条口径。
extension AIUserImageStripCell: AIChatContentBlockProviding {
    var contentBlockView: UIView? { stack }
}

// MARK: - AIChatSelectionTouchYielding

extension AIUserImageStripCell: AIChatSelectionTouchYielding {

    /// 选择模式（多选删除）下关掉各格子的单击 —— 让触摸落到表格的勾选机制里，
    /// 否则这一行永远勾不上（与 `AIAssistantMediaStripCell` 同一条理由）。
    ///
    /// ⚠️ 关的是**格子**不是 `contentView`：横滑在选择模式下仍然可用
    ///（用户从一条长条里挑图时，横滑比逐张点方便得多）。
    func setSelectionMode(_ on: Bool) {
        for case let thumb as UserImageThumbView in stack.arrangedSubviews {
            thumb.isUserInteractionEnabled = !on
        }
    }
}
