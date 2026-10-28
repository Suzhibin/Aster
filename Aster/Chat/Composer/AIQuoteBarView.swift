//
//  AIQuoteBarView.swift
//  AIModule
//
//  用户气泡**内部上方**那条引用条：一条竖线 + 「引用了谁」+ 正文摘要，整条可点（跳回原消息）。
//
//  为什么放在气泡**里面**而不是上面（像时间小字那样）：
//  引用与被引用的那句话在语义上是同一件事（「针对这段内容，我的新要求是…」），
//  贴在气泡内才读得出来「这一段是引用、下面才是我的话」。放外面会和气泡外的时间小字
//  挤在一起，三层小字叠着反而分不清主次（豆包 / ChatGPT 也都是放在气泡内）。
//
//  配色是为**蓝色用户气泡**定的：白系（半透明底 + 白字）。助手气泡不会用到它
//  —— 引用是用户的行为，助手回复永远不带引用。
//
//  ⚠️ 高度由 `AIChatRow.quoteHeight` / `quoteHeightOrZero` 统一给出：
//  这里只画，不自己算高度；量行高那边也只读那两个常量。两处同源是硬约定
//  （本工程「气泡内外多出来的一条」反复出过行高事故）。
//

import UIKit
import SnapKit
import AICore

final class AIQuoteBarView: UIControl {

    /// 点按回调：把**被引用消息的 id** 交出去，宿主负责滚动定位 + 闪一下。
    var onTap: ((UUID) -> Void)?

    private var quotedMessageId: UUID?

    private lazy var accentLine: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(white: 1, alpha: 0.8)
        v.layer.cornerRadius = 1.5
        return v
    }()

    /// 「引用了 AI」/「引用了 我」
    private lazy var nameLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = UIColor(white: 1, alpha: 0.7)
        l.numberOfLines = 1
        return l
    }()

    private lazy var summaryLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12)
        l.textColor = .white
        l.numberOfLines = 1
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 1, alpha: 0.18)
        layer.cornerRadius = 8
        addSubview(accentLine)
        addSubview(nameLabel)
        addSubview(summaryLabel)

        accentLine.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.centerY.equalToSuperview()
            make.width.equalTo(3)
            // 竖线上下各留 8：贴满整条会显得像个边框，而不是「引用的标记」
            //
            // 🔴 **这条只能是 999，不能是 required**（2026-09-20 真机告警）：
            // 宿主 `AIUserTextCell` 在**无引用**时把本条的**高度钉成 0**（不是隐藏留白），
            // 于是 `自己.高度 - 16` 在那一刻等于 **-16** —— 尺寸不能为负，
            // 而「高度 == 0」那条是宿主为了「正文顶边接着引用条底边」而**必须**成立的，
            // 两条 required 直接对撞，UIKit 只能打破一条并刷
            // `Unable to simultaneously satisfy constraints`（真机破的正是这一条）。
            // 降到 999 后：本条（容器）高度照样是 0，让出的只是竖线自己的上下留白；
            // 有引用时（高度 == `AIChatRow.quoteHeight` = 42）这条依然被精确满足 → 竖线 26pt，
            // 与改动前逐项相同。
            //
            // ⛔ 别改成写死的 `AIChatRow.quoteHeight - 16`：那等于让「只负责画」的视图
            //    自己再算一遍高度（本文件的硬约定是高度只由宿主给），两处口径迟早漂。
            // ⛔ 也别去降宿主那条「高度 == 0」：降了引擎会反手把引用条撑到 16pt 高，
            //    无引用的行会凭空多出一段留白，行高（按 `quoteHeightOrZero` 预计算）立刻对不上。
            make.height.equalToSuperview().offset(-16).priority(999)
        }
        nameLabel.snp.makeConstraints { make in
            make.leading.equalTo(accentLine.snp.trailing).offset(8)
            make.trailing.equalToSuperview().offset(-8)
            make.top.equalToSuperview().offset(6)
        }
        summaryLabel.snp.makeConstraints { make in
            make.leading.trailing.equalTo(nameLabel)
            make.top.equalTo(nameLabel.snp.bottom).offset(2)
        }

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 配置内容。传 `nil` 即隐藏（此时宿主应把这一条的高度让出去，见 `AIChatRow.quoteHeightOrZero`）。
    func configure(with quote: AIQuote?) {
        guard let quote = quote else {
            quotedMessageId = nil
            nameLabel.text = nil
            summaryLabel.text = nil
            isHidden = true
            return
        }
        isHidden = false
        quotedMessageId = quote.messageId
        nameLabel.text = String(format: L("引用了%@"), quote.displayName)
        summaryLabel.text = quote.summary()
        accessibilityLabel = String(format: L("引用了%@的消息：%@"), quote.displayName, quote.summary())
    }

    @objc private func handleTap() {
        guard let id = quotedMessageId else { return }
        onTap?(id)
    }
}
