import UIKit
import SnapKit
import AICore

/// **模型切换系统消息**（`.modelSwitch` 行，2026-10-21）：
/// 一行居中的小灰字「—— 模型已从 A 更改为 B ——」。
///
/// ## 三条硬约束
/// ① **零交互**（用户原话：「不用有任何点击事件和交互，就是系统消息」）——
///    本 cell 一个手势都不挂，也**不实现 `AIChatContentBlockProviding`**；
///    长按会被宿主 `handleCellLongPress` 提前挡掉（见那里的早退），
///    即便漏了，`AIRowAction.chatMenu(for:)` 返的是空集合，`presentActionMenu`
///    的 `guard !actions.isEmpty` 也会让它静默不弹 —— 两道闸，故意叠着。
/// ② **没有气泡**：左右贴到 12pt 边距、上下只有 `AIChatRow.noticeRowPaddingV`
///    （与 `AIChatRow.height(in:)` 的 `.modelSwitch` 分支**同一份常量**，
///    「量 A 布局 B」是本工程行高错乱的头号来源）。
/// ③ **文案现取 `block.modelSwitchText`**（不是 `block.text`）—— 前者走 `L()`，
///    切语言后这一行跟着换；后者是写入那一刻的快照，只在结构化数据丢失时兜底。
///
/// ⚠️ 与 `AIAssistantTextCell.configureNotice` **刻意不是同一个东西**：那个是失败提示
///    （橙字、贴左、算「这一轮的输出」），这个是系统流水（灰字、居中、不算任何内容）。
public final class AISystemNoticeCell: UITableViewCell {

    private let noticeLabel = UILabel()

    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        noticeLabel.font = AITypography.notice
        noticeLabel.textColor = .tertiaryLabel
        noticeLabel.textAlignment = .center
        noticeLabel.numberOfLines = 0
        contentView.addSubview(noticeLabel)

        noticeLabel.snp.makeConstraints { make in
            // 左右 12 + 12 = 24，与 `height(in:)` 里那个 `width - 24` 同一口径
            make.leading.equalToSuperview().offset(12)
            make.trailing.equalToSuperview().offset(-12)
            // 上下共用共享层那一份 padding（⛔ 别在这里另写数字）
            make.top.equalToSuperview().offset(AIChatRow.noticeRowPaddingV)
            make.bottom.equalToSuperview().offset(-AIChatRow.noticeRowPaddingV)
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func configure(_ text: String) {
        // 🔴 字号**现读**（2026-10-22，与 `AIUserTextCell` 同一个坑）：`init` 里那次
        //    `AITypography.notice` 是快照，cell 复用时只换文字不换字 ⇒ 改字号后这一行
        //    停在旧档（行高却按新字号量了）。`init` 那份留作初值。
        noticeLabel.font = AITypography.notice
        noticeLabel.text = text
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        noticeLabel.text = nil
    }
}
