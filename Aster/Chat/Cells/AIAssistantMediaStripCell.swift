//
//  AIAssistantMediaStripCell.swift
//  Aster
//
//  助手侧的**媒体横滑条**（2026-09-28 加）：把「连续的助手媒体行」画成一条
//  **横向滚动**的**竖版 9:16** 格子 —— 与 Mac 的 `Views/MediaThumbStrip.swift` 同口径
//  （用户原话：「我看了 iOS 端图片，也要改 图片数据竖着显示 横向滑动效果」）。
//
//      ┌────┐ ┌────┐ ┌────┐ ┌───┈
//      │ 图1 │ │ 图2 │ │ ▶视频│ │ 图4
//      └────┘ └────┘ └────┘ └───┈   ← 放不下就横向滚，永远只有一行
//
//  ## 这个 cell 挂在**哪一行**
//
//  挂在**组首**那一行（`AIChatMediaGrouping.isGroupHead`）。同组其余行由
//  `AIChatManager.normalizeMediaGroupHeights()` 把高度归零 ⇒ 那几行不会有人来长东西。
//  组首 `configure(rows:)` 拿到的是**整组**（`AIChatMediaGrouping.groupRows`）。
//
//  ⚠️ 为什么不是「把数据源换成显示项」（Mac 的做法）：那样 `indexPath.row` 的含义就变了，
//     多选删除 / 搜索定位 / 引用跳转 / TTS / 编辑态 / 操作卡全都要再加一层
//     「显示项 ↔ 行」的映射 —— 那一层是本工程最容易出错的地方。
//     iOS 侧刻意保留「一行一格」，只让**组首那一格长得像一整条**（用户 2026-09-28 选定）。
//     代价（已知情并接受）：组内第 2..N 张**点不到** ⇒ 选择模式下整条一起选、一起删
//     （见 `AIModuleViewController+Selection.swift` 的 `handleSelectionDelete`）。
//
//  ## 尺寸口径：全部取 `AIChatRow.mediaStrip*`
//
//  ⛔ **别在本文件里写死 192 / 108 / 8**：`AIChatRow.height(in:)` 量出来的行高就是
//  `mediaStripRowHeight`（= 格子高 + 上下留白 12），本 cell 的约束必须正好凑出这个数。
//  两边各写一份的经典症状是「量的时候按 A、布局按 B」—— 那一条横滑条会把下面的消息顶歪
//  或者自己被裁掉一截（与 `userImageDisplaySize` 同一课，见 `AIChatModels.swift`）。
//
//  ## 为什么用 UIScrollView + UIStackView 而不是 UICollectionView
//
//  一屏就几格、不换行、不分组、不需要复用（一张图一格的成本远低于一个 collection view
//  的布局流程）；横滑条是**纯静态内容**。UICollectionView 在这里只会多带来两件事：
//  「必须先 layout 才知道 contentSize」与一个复用队列。等哪天要「点开九宫格/多行网格」再换。
//

import UIKit
import Kingfisher
import SnapKit
import AICore

public final class AIAssistantMediaStripCell: UITableViewCell {

    /// 点某一格里的**图片** → 全屏预览。
    /// 参数：图片地址 + 那一格的缩略图视图（供 JXPhotoBrowser 的 zoom 转场定位起止位置）。
    /// ⚠️ 带的是**视图**而不是下标：cell 复用后下标会漂，视图不会（同 `AIUserImageCell` 那套）。
    public var onPreview: ((URL, UIView) -> Void)?

    /// 点某一格里的**视频** → 播放。
    public var onPlay: ((URL) -> Void)?

    /// 横向滚动容器。左右各留 12（与文本 / 用户图片气泡的左边界对齐）。
    private let scrollView = UIScrollView()

    /// 格子容器。间距用 `spacing`（取共享常量），⛔ 别改成 `distribution` ——
    /// 那会让格子宽度跟着屏宽变，而格子宽度**必须与屏宽无关**（高度口径才成立）。
    private let stack = UIStackView()

    /// 圆角。取 14 —— 与本工程其余图片 cell（`AIUserImageCell`）
    /// 同一档。⚠️ 它只影响长相、**不进行高**，所以留在本文件而不是共享常量里
    /// （Mac 那边同族圆角是 `bubbleRadius`=12，两端在这一项上刻意允许不同）。
    private let corner: CGFloat = 14

    /// 上下留白。与 `height(in:)` 里那笔 `+12` **同源**（6+6）。
    private let insetV: CGFloat = 6

    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        // ⚠️ 指示器关掉：这个高度（192）里常驻一条细线很显眼。
        //（iOS 与 macOS 不同 —— macOS 的 overlay 指示器只在滚动时出现，iOS 默认是常驻的。）
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true      // 一格时也能横滑一下，暗示「这里可以滑」
        scrollView.contentInsetAdjustmentBehavior = .never
        contentView.addSubview(scrollView)

        stack.axis = .horizontal
        stack.alignment = .fill
        stack.spacing = AIChatRow.mediaStripSpacing
        scrollView.addSubview(stack)

        scrollView.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview().inset(insetV)
            make.left.equalToSuperview().offset(12)
            make.right.equalToSuperview().offset(-12)
        }
        // 挂 scrollView 的子视图 → UIKit 会把约束解析成相对 contentLayoutGuide，
        // 于是这两条就是「内容尺寸 = stack 的尺寸」（与 `AIAttachmentBarView` 的附件条同一写法）。
        // ⚠️ **必须有**：没有它 contentSize 会塌成 0 ⇒ 横滑条整条看不见，
        //    而图上看起来与「这一行本来就没内容」一模一样（极容易跑去查数据源）。
        // ⚠️ 高度钉在格子上而不是 `edges` 里靠子视图撑：内容高度恒 192，
        //    与可见区同高 ⇒ 不会出现「竖着也能拖一点」的橡皮筋。
        stack.snp.makeConstraints { make in
            make.edges.equalToSuperview()
            make.height.equalTo(AIChatRow.mediaStripThumbHeight)
        }

        // 长按弹操作卡要落在**内容块**上（见 `AIChatContentBlockProviding` 的说明）：
        // 这里的内容块就是格子容器本身 —— 长按那条图右边的空白不该弹卡（与文本气泡留白同理）。
        // ⚠️ 不能给 `scrollView`：它铺满整行宽，长按右侧空白也会命中。
        //
        // 单击预览 / 播放走各格子自己的手势（与行内图片 cell 同一条口径），不经表格的选中机制。
        //
        // ⚠️ 本 cell 不做 `contentView` 级手势：那会与 UIScrollView 的 pan 抢触摸，
        //    症状是「横滑滑不动、或者一点就开预览」。命中区**逐格**挂。
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 装配

    /// 装配整组。`rows` = 组内全部行（按时间顺序）；**空数组**用于组内非首行
    /// （它们高度为 0，本 cell 画不出任何东西 —— 见文件头）。
    public func configure(rows: [AIChatRow]) {
        clearThumbs()
        for row in rows {
            stack.addArrangedSubview(makeThumb(for: row))
        }
    }

    private func clearThumbs() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    /// 造一个格子。图片用 `.scaleAspectFill` 裁（竖版 9:16 框 ⇒ **横图只看到中间一条**，
    /// 与 Mac 完全一致）；视频画封面 + 播放图标。
    private func makeThumb(for row: AIChatRow) -> MediaThumbView {
        let thumb = MediaThumbView()
        thumb.clipsToBounds = true
        thumb.layer.cornerRadius = corner
        thumb.snp.makeConstraints { make in
            make.width.equalTo(AIChatRow.mediaStripThumbWidth)
            make.height.equalTo(AIChatRow.mediaStripThumbHeight)
        }

        let image = UIImageView()
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        thumb.addSubview(image)
        image.snp.makeConstraints { make in make.edges.equalToSuperview() }

        switch row.block.kind {
        case .video:
            // 封面（可能没有）→ 兜底黑底，否则封面没加载出来时那格是白板，看不出是视频
            image.backgroundColor = .black
            if let cover = row.block.videoCoverURL {
                image.kf.setImage(with: cover)
            } else {
                image.image = nil
            }
            // 播放标记：**不是命中区**（整格可点），带阴影 —— 封面可能是亮色，
            // 纯白图标压在亮底上会看不见（与 Mac `MediaThumbStrip` 同一条理由）
            let play = UIImageView(image: UIImage(systemName: "play.circle.fill"))
            play.tintColor = .white
            play.layer.shadowColor = UIColor.black.cgColor
            play.layer.shadowOpacity = 0.35
            play.layer.shadowRadius = 3
            play.layer.shadowOffset = CGSize(width: 0, height: 1)
            thumb.addSubview(play)
            play.snp.makeConstraints { make in
                let side = AIChatRow.mediaStripPlayIconSize
                make.center.equalToSuperview()
                make.width.height.equalTo(side)
            }
            if let url = row.block.videoURL {
                thumb.onTap = { [weak self] in
                    guard let self else { return }
                    self.onPlay?(url)
                }
            } else {
                // 地址都没有 ⇒ 这格不可播（别给一个点了没反应的格子）
                image.backgroundColor = UIColor(white: 0.92, alpha: 1)
                play.isHidden = true
            }
        default:
            // 图片格。占位底色取本工程图片 cell 的同一档
            image.backgroundColor = UIColor(white: 0.92, alpha: 1)
            if let url = row.block.imageURL {
                image.kf.setImage(with: url)
                thumb.onTap = { [weak self, weak image] in
                    guard let self = self, let view = image else { return }
                    self.onPreview?(url, view)
                }
            }
        }
        return thumb
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        for case let thumb as MediaThumbView in stack.arrangedSubviews {
            for case let image as UIImageView in thumb.subviews {
                image.kf.cancelDownloadTask()
            }
        }
        clearThumbs()
        onPreview = nil
        onPlay = nil
    }
}

// MARK: - 一格

/// 一个格子：一层容器负责圆角 / 裁切 / 点击，里面可能叠着图片与播放标记。
///
/// 单独一个类是为了**手势不打架**：整格一个 `onTap`，命中区就是这个格子的矩形
///（与 Mac「整格可点」同一条口径）。⛔ 别改成 `UIControl`：宿主的长按手势会
/// 因为 `hit is UIControl` 把触摸整个让出去（见 `gestureRecognizer(_:shouldReceive:)`），
/// 那样这一格就**弹不出操作卡**了。
private final class MediaThumbView: UIView {

    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.92, alpha: 1)
        isUserInteractionEnabled = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func tapped() { onTap?() }
}

// MARK: - AIChatContentBlockProviding

/// 内容块 = **格子容器**（长按照到这里才弹操作卡；横滑条右边那条空白不响应）。
/// 组内非首行拿到的是空容器（`bounds` 为零）⇒ 永远不命中，正合预期。
extension AIAssistantMediaStripCell: AIChatContentBlockProviding {
    var contentBlockView: UIView? { stack }
}

// MARK: - AIChatSelectionTouchYielding

extension AIAssistantMediaStripCell: AIChatSelectionTouchYielding {

    /// 选择模式（多选删除）下关掉各格子的单击 —— 让触摸落到表格的勾选机制里，
    /// 否则这一行永远勾不上（与 `AIUserImageCell` 同一条理由）。
    ///
    /// ⚠️ 关的是**格子**不是 `contentView`：`contentView` 上的手势包含不了
    /// `UIScrollView` 的 pan，横滑在选择模式下仍然可用（对长列表挑图挺方便）。
    func setSelectionMode(_ on: Bool) {
        for case let thumb as MediaThumbView in stack.arrangedSubviews {
            thumb.isUserInteractionEnabled = !on
        }
    }
}
