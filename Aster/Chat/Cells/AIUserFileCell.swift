import UIKit
import SnapKit
import AICore

/// 用户发出的文件附件（右侧卡片）。
///
/// 只有「图标 + 文件名 + 大小」。**卡片自己没有手势** ——
/// - 轻点 = 打开系统预览页（走表格的 `didSelectRowAt`，见 `+Table` 的 `.file` 那一支）；
/// - 长按 = 竖排操作卡「分享 / 删除」（`AIRowAction.mediaMenu`）。
///
/// ⚠️ 两条路**都经宿主**，本 cell 一个手势都不挂。若哪天真要在这里挂 tap，注意与
///    表格的选中机制会打架（`didSelectRowAt` 也会被触发 ⇒ 一次点击开两个预览页）。
public final class AIUserFileCell: UITableViewCell {

    private enum Metrics {
        static let corner: CGFloat = 12
        static let cardHeight = AIChatRow.userFileCardHeight   // 与行高量算同源
        static let topInset: CGFloat = 6
        static let rightInset: CGFloat = 12
    }

    private let card = UIView()
    private let iconWrap = UIView()
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let sizeLabel = UILabel()

    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        card.backgroundColor = .secondarySystemFill
        card.layer.cornerRadius = Metrics.corner
        contentView.addSubview(card)

        iconWrap.backgroundColor = .systemBlue.withAlphaComponent(0.15)
        iconWrap.layer.cornerRadius = 8
        card.addSubview(iconWrap)

        iconView.image = UIImage(systemName: "doc.fill")
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        iconWrap.addSubview(iconView)

        // 文件名用中间截断：尾巴是扩展名，比前缀更能说明「这是什么文件」。
        // ⚠️ 这只是**初值**：每次复用的刷新点在 `configure`（那边现读 `AITypography.body`）——
        //    只在这里设 = 快照，改字号后文件卡不换字（2026-10-22 踩过）。
        nameLabel.font = AITypography.body
        nameLabel.textColor = .label
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.numberOfLines = 1

        sizeLabel.font = .systemFont(ofSize: 12)
        sizeLabel.textColor = .secondaryLabel
        sizeLabel.numberOfLines = 1

        card.addSubview(nameLabel)
        card.addSubview(sizeLabel)

        card.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(Metrics.topInset)
            make.bottom.lessThanOrEqualToSuperview().offset(-Metrics.topInset)
            make.right.equalToSuperview().offset(-Metrics.rightInset)
            make.left.greaterThanOrEqualToSuperview().offset(64)
            make.height.equalTo(Metrics.cardHeight)
            make.width.equalTo(UIScreen.main.bounds.width * AIChatRow.userMediaWidthRatio)
        }
        iconWrap.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(12)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(36)
        }
        iconView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.height.equalTo(18)
        }
        nameLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconWrap.snp.trailing).offset(10)
            make.trailing.equalToSuperview().offset(-12)
            make.bottom.equalTo(card.snp.centerY).offset(-1)
        }
        sizeLabel.snp.makeConstraints { make in
            make.leading.equalTo(nameLabel)
            make.trailing.equalToSuperview().offset(-12)
            make.top.equalTo(card.snp.centerY).offset(2)
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// - Parameter byteSize: 传 0 表示未知（历史数据没存），此时不显示大小那一行
    public func configure(name: String, byteSize: Int64) {
        // 🔴 文件名现读正文字号（2026-10-22）：原先写死 14pt = 改字号档位时文件卡
        //    毫无反应（重启也不变——它压根不读 AITypography）。文件名是用户发的
        //    内容主体，跟 `AIUserTextCell` 的气泡正文同一口径。
        //    ⚠️ 大小那行（sizeLabel）**刻意保持 12**：它是辅助信息，与两行气泡的
        //    时间小字（`metaFont`）同档—— chrome 性质的小字不跟档位（同 Mac 侧口径）。
        nameLabel.font = AITypography.body
        nameLabel.text = name.isEmpty ? L("文件") : name
        sizeLabel.text = byteSize > 0
            ? ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
            : L("文件")
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        nameLabel.text = nil
        sizeLabel.text = nil
    }
}

// MARK: - AIChatContentBlockProviding

/// 内容块 = 文件行：卡片（长按照到这里才弹操作卡，气泡外的留白不响应）。
///
/// ⚠️ 实现必须留在本文件：`card` 是 `private let`，而 `private` 是**文件级**
/// 作用域 —— 挪到协议所在文件会 `inaccessible due to 'private' protection level`。
extension AIUserFileCell: AIChatContentBlockProviding {
    var contentBlockView: UIView? { card }
}
