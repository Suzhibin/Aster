//
//  AIChatSearchCell.swift
//  AIModule
//
//  搜索结果行：会话标题 + 命中片段，**命中的关键词在两侧都用富文本高亮**。
//
//  高亮位置不在这里算 —— `AIChatSearchHit` 已经带好了（store 用 `AISearchMatcher` 产出）。
//  cell 只负责上色，避免「列表里高亮偏一个字符」这类算/画不同源的问题。
//

import UIKit
import SnapKit
import AICore

final class AIChatSearchCell: UITableViewCell {

    static let reuseIdentifier = "AIChatSearchCell"

    /// 模块主题色（与 `AIMenuViewController.activeTintColor` 同值，两处观感保持一致）
    private static let tint = UIColor(red: 0.46, green: 0.54, blue: 1.0, alpha: 1)

    private enum Metrics {
        static let titleFont = UIFont.systemFont(ofSize: 15, weight: .medium)
        static let timeFont = UIFont.systemFont(ofSize: 12)
        static let bodyFont = UIFont.systemFont(ofSize: 14)
        /// 命中处加粗一档，光靠颜色在浅色底上不够醒目
        static let highlightFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
        static let taggingFont = UIFont.systemFont(ofSize: 11, weight: .medium)
        /// 高亮底色透明度。别调高：0.15 是「标出来但不抢戏」，再深就像整行被选中了
        static let highlightBgAlpha: CGFloat = 0.15
    }

    // MARK: - 视图

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.font = Metrics.titleFont
        l.textColor = .label
        l.numberOfLines = 1
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    private let timeLabel: UILabel = {
        let l = UILabel()
        l.font = Metrics.timeFont
        l.textColor = .tertiaryLabel
        l.textAlignment = .right
        // 时间不能被标题挤掉：内容压缩抗力拉满，标题先截断
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }()

    /// 「我」/「AI」/「标题」小标记，让人一眼看出这条命中出自哪一侧。
    /// ⚠️ 存储属性的初始化器里不能用 `Self.xxx`（编译器报 covariant 'Self'），只能写类型名
    private let roleTag: UILabel = {
        let l = UILabel()
        l.font = Metrics.taggingFont
        l.textColor = AIChatSearchCell.tint
        l.backgroundColor = AIChatSearchCell.tint.withAlphaComponent(Metrics.highlightBgAlpha)
        l.textAlignment = .center
        l.layer.cornerRadius = 4
        l.clipsToBounds = true
        return l
    }()

    private let snippetLabel: UILabel = {
        let l = UILabel()
        l.font = Metrics.bodyFont
        l.textColor = .secondaryLabel
        l.numberOfLines = 2
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    // MARK: - 构造

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupUI() {
        backgroundColor = .systemBackground
        selectionStyle = .default

        contentView.addSubview(titleLabel)
        contentView.addSubview(timeLabel)
        contentView.addSubview(roleTag)
        contentView.addSubview(snippetLabel)

        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.top.equalToSuperview().offset(12)
            make.trailing.equalTo(timeLabel.snp.leading).offset(-8)
        }
        timeLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-16)
            make.centerY.equalTo(titleLabel)
            make.width.lessThanOrEqualTo(72)
        }
        roleTag.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(16)
            make.top.equalTo(titleLabel.snp.bottom).offset(6)
            make.width.greaterThanOrEqualTo(24)
            make.height.equalTo(16)
        }
        snippetLabel.snp.makeConstraints { make in
            make.leading.equalTo(roleTag.snp.trailing).offset(6)
            make.trailing.equalToSuperview().offset(-16)
            make.top.equalTo(roleTag)
            make.bottom.equalToSuperview().offset(-12)
        }
    }

    // MARK: - 绑定

    func configure(with hit: AIChatSearchHit) {
        timeLabel.text = Self.timeText(for: hit.updatedAt)
        roleTag.text = hit.roleText

        // 标题：命中时才带高亮（titleRanges 为空就是纯文本）
        titleLabel.attributedText = AISearchMatcher.highlight(
            hit.displayTitle,
            ranges: hit.titleRanges,
            baseAttributes: [.font: Metrics.titleFont, .foregroundColor: UIColor.label],
            highlightAttributes: Self.highlightAttributes(font: Metrics.titleFont)
        )
        // 片段
        snippetLabel.attributedText = AISearchMatcher.highlight(
            hit.snippet,
            ranges: hit.snippetRanges,
            baseAttributes: [.font: Metrics.bodyFont, .foregroundColor: UIColor.secondaryLabel],
            highlightAttributes: Self.highlightAttributes(font: Metrics.highlightFont)
        )
    }

    /// 命中处的富文本样式：主题色 + 半粗 + 浅底
    private static func highlightAttributes(font: UIFont) -> [NSAttributedString.Key: Any] {
        [.font: font,
         .foregroundColor: tint,
         .backgroundColor: tint.withAlphaComponent(Metrics.highlightBgAlpha)]
    }

    // MARK: - 时间

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    /// 今天只给时分、昨天给「昨天」，更早给月日（跨年再补年份）—— 搜索结果里时间只是辅助信息
    private static func timeText(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            timeFormatter.dateFormat = "HH:mm"
        } else if calendar.isDateInYesterday(date) {
            timeFormatter.dateFormat = L("昨天")
            return timeFormatter.string(from: date)
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            timeFormatter.dateFormat = L("M月d日")
        } else {
            timeFormatter.dateFormat = L("yyyy年M月d日")
        }
        return timeFormatter.string(from: date)
    }
}
