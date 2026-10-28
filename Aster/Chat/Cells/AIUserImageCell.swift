import UIKit
import SnapKit
import AICore

/// 用户发出的图片（右侧气泡）。
///
/// 尺寸**完全由外部传入**（`AIChatRow.userImageDisplaySize`）：行高与这里用的是同一个值，
/// cell 自己不要再按屏宽算一遍 —— 那正是「图片被裁 / 气泡留白」的经典来源。
public final class AIUserImageCell: UITableViewCell {

    /// 单击图片回调（宿主打开全屏预览）；参数是缩略图视图，供 JXPhotoBrowser zoom 转场定位
    public var onPreview: ((UIView?) -> Void)?

    /// 用户图片固定右对齐；圆角比文本气泡略大一点，视觉上更像「图片卡」
    private enum Metrics {
        static let corner: CGFloat = 12
        static let topInset: CGFloat = 6
        static let rightInset: CGFloat = 12
        static let leftLimit: CGFloat = 64
    }

    private let pictureView = UIImageView()
    private var widthConstraint: Constraint?
    private var heightConstraint: Constraint?

    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        pictureView.contentMode = .scaleAspectFill
        pictureView.layer.cornerRadius = Metrics.corner
        pictureView.clipsToBounds = true
        pictureView.backgroundColor = .tertiarySystemFill
        contentView.addSubview(pictureView)

        pictureView.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(Metrics.topInset)
            // 「≤」而不是「=」：行高比图片高度略大时不该报约束冲突
            make.bottom.lessThanOrEqualToSuperview().offset(-Metrics.topInset)
            make.right.equalToSuperview().offset(-Metrics.rightInset)
            make.left.greaterThanOrEqualToSuperview().offset(Metrics.leftLimit)
            widthConstraint = make.width.equalTo(1).constraint
            heightConstraint = make.height.equalTo(1).constraint
        }

        // 单击预览（加在 contentView 上：UIImageView 默认不接收交互）
        contentView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(previewTapped)))
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// - Parameter displaySize: 必须在 `heightForRowAt` 用的**同一个**值（见 AIChatRow）
    public func configure(url: URL, displaySize: CGSize) {
        widthConstraint?.update(offset: displaySize.width)
        heightConstraint?.update(offset: displaySize.height)
        // 本地文件走降采样：按「实际要显示的像素」解码，别把整张 1600px 全读进内存
        let target = max(displaySize.width, displaySize.height) * UIScreen.main.scale
        pictureView.image = AIAttachmentStorage.image(at: url, maxPixelSize: target)
    }

    @objc private func previewTapped() {
        onPreview?(pictureView)
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        pictureView.image = nil
        onPreview = nil
    }
}

// MARK: - AIChatContentBlockProviding

/// 内容块 = 图片行：图片视图（长按照到这里才弹操作卡，气泡外的留白不响应）。
///
/// ⚠️ 实现必须留在本文件：`pictureView` 是 `private let`，而 `private` 是**文件级**
/// 作用域 —— 挪到协议所在文件会 `inaccessible due to 'private' protection level`。
extension AIUserImageCell: AIChatContentBlockProviding {
    var contentBlockView: UIView? { pictureView }
}

// MARK: - AIChatSelectionTouchYielding

extension AIUserImageCell: AIChatSelectionTouchYielding {

    /// 选择模式（多选删除）下关掉单击预览。
    ///
    /// ⚠️ 不关的话这一拍被手势接走，表格收不到 → **这一行永远勾不上**
    ///（其它行的内容块都是纯展示视图，触摸本来就会落到表格的勾选机制里）。
    /// 这里直接把 `contentView` 上的手势全关掉：本 cell 只有预览这一条。
    func setSelectionMode(_ on: Bool) {
        contentView.gestureRecognizers?.forEach { $0.isEnabled = !on }
    }
}
