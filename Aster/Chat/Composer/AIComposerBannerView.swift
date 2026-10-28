//
//  AIComposerBannerView.swift
//  AIModule
//
//  输入**卡片内部**的那条「状态条」：眼下正处在两种特殊输入态之一。
//
//  - `quote`   —— 待发送的引用（引用了某条历史消息，等着提问）
//  - `editing` —— 正在编辑某条自己发过的消息（发送 = 截断重发）
//
// 🔴 2026-10-09 起它住在带描边的输入**卡片里面**（卡片最上方）。
// 用户原话「引用和编辑的文本现在在输入框的描边上面，现在需要放在输入框的描边内」
// ⇒ 与 10-08 附件条搬进卡片那一次完全同构（自上而下：**状态条 →（附件条 →）输入框**）。
// 之前它在卡片**外面**（卡片上方通栏），看着像另起一条。
//
//  **为什么把两件事做成一个视图的两种形态**：它们在屏幕上占的是同一个位置、
//  长得一样（一行说明 + 一行摘要 + 一个取消按钮）、生命周期也一致（都随输入栏长高）。
//  做成两个视图就要在 `InputToolbar.cardContentHeight()` 里叠两条高度、还要处理两者同时出现的布局，
//  而「一边编辑旧消息一边引用另一条」是个几乎不存在的组合（真需要时先取消编辑即可）。
//  **两者互斥的优先级由宿主决定**（见 `AIModuleViewController.refreshComposerBanner`）。
//
//  ⚠️ `barHeight` 是给 `InputToolbar.cardContentHeight()` 用的（同 `AIAttachmentBarView.barHeight`）：
//  输入栏高度必须是「卡片上方留白 +（状态条 + 附件条 + 输入行）+ 卡片下方留白」的和，
//  少算一条，列表底部内边距就会差一截。
//

import UIKit
import SnapKit
import AICore

final class AIComposerBannerView: UIView {

    /// 固定高度（由 `InputToolbar` 计入自身高度）
    static let barHeight: CGFloat = 48

    /// 这条状态条在说什么
    enum Kind: Equatable {
        /// 待发送的引用
        case quote(AIQuote)
        /// 正在编辑某条自己发过的消息（关联值是原消息的摘要，让用户确认「就是这条」）
        case editing(String)
    }

    /// 点取消（引用 → 清掉引用；编辑 → 退出编辑态）
    var onCancel: (() -> Void)?

    private lazy var accentLine: UIView = {
        let v = UIView()
        v.layer.cornerRadius = 1.5
        return v
    }()

    private lazy var nameLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.numberOfLines = 1
        return l
    }()

    private lazy var summaryLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        l.numberOfLines = 1
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    private lazy var cancelButton: UIButton = {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        b.tintColor = .tertiaryLabel
        b.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        b.accessibilityLabel = L("取消")
        return b
    }()

    /// 内部那张小卡片（`card`）距本视图四边的留白。
    ///
    /// 🔴 2026-10-09 起本视图住在**输入卡片内部最上方**，而那张输入卡片的左右内边距是
    ///    **8**（`InputToolbar.cardPaddingH`）—— 描边内侧就那么多。
    ///    ⛔ 原来这里左右是 **16**（对齐 `InputToolbarConfigure.horizontalMargin`，那时本视图
    ///    在卡片**外面**通栏摆放）。搬进来后不改就会比附件条 / 输入框多缩 8，两侧对不齐。
    /// 📌 上下这两条留白别动：状态条内部结构（名称 + 摘要两行）要靠它们撑开。
    private enum Metrics {
        static let insetH: CGFloat = 8
        static let insetV: CGFloat = 4
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 8
        addSubview(card)
        card.addSubview(accentLine)
        card.addSubview(nameLabel)
        card.addSubview(summaryLabel)
        card.addSubview(cancelButton)

        card.snp.makeConstraints { make in
            // 左右与**输入行 / 附件条**对齐（同 `InputToolbar.cardPaddingH` = 8）。
            //
            // ⚠️ **四条 inset 都只能是 999，不能是 required**（与 `AIAttachmentPanelView` / `AIAttachmentBarView` 同因）：
            // 本视图是 frame 布局（`InputToolbar.layoutSubviews` 按输入栏宽度摆），从 init 到首次上屏之间
            // 宽**和**高都是 **0** —— 这两个 0 会被引擎翻译成
            // `NSAutoresizingMaskLayoutConstraint: width/height == 0`（required）。
            //
            // 横向：「card 左右各缩 8 → 内部 accentLine 宽 3 + cancelButton 宽 28 + 两段 8/4 的间距」
            // → card 至少要 59pt 宽，而上限是 `0 - 16`（实测被破坏的正是 `card.trailing`，差 91pt）。
            // 纵向：「card 上下各缩 4」→ card 高 = `0 - 8` = **-8**；再往下 accentLine 高 = `card 高 - 12`
            // → **-20**。尺寸不能为负，两条链必有一条让出（实测被破坏的正是
            // `accentLine.height == card.height - 12`，引擎把 card 高顶到 12 才放得下装饰条）。
            //
            // 语义上这四条也只是「尽量」：卡片距状态条四边各留 4/8 —— 容器小到装不下时，该牺牲的是留白。
            // ⚠️ **让出的是 card 自己的 inset，`accentLine` 的 height 保持 required**：
            // 于是引擎反过来把 card 撑到「够放装饰条」的最小高度，
            // 「卡片适配状态条、装饰条适配卡片」的从属关系不变。
            // 降到 999 后 required 全部保住（被压缩的 optional 从不报错）；
            // 正常尺寸（48 高 / 卡片宽）下四条依然被精确满足 —— 实测 0 高时需破坏的 required 从 2 条降到 0 条，
            // 48 高时改动前后帧值逐项相同。
            make.leading.equalToSuperview().offset(Metrics.insetH).priority(999)
            make.trailing.equalToSuperview().offset(-Metrics.insetH).priority(999)
            make.top.equalToSuperview().offset(Metrics.insetV).priority(999)
            make.bottom.equalToSuperview().offset(-Metrics.insetV).priority(999)
        }
        accentLine.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(8)
            make.centerY.equalToSuperview()
            make.width.equalTo(3)
            make.height.equalToSuperview().offset(-12)
        }
        cancelButton.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-8)
            make.centerY.equalToSuperview()
            make.width.height.equalTo(28)
        }
        nameLabel.snp.makeConstraints { make in
            make.leading.equalTo(accentLine.snp.trailing).offset(8)
            make.trailing.equalTo(cancelButton.snp.leading).offset(-4)
            make.top.equalToSuperview().offset(6)
        }
        summaryLabel.snp.makeConstraints { make in
            make.leading.trailing.equalTo(nameLabel)
            make.top.equalTo(nameLabel.snp.bottom).offset(2)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 配置内容。传 `nil` 即隐藏（宿主同时要把这一条的高度让出去）。
    func configure(kind: Kind?) {
        guard let kind = kind else {
            nameLabel.text = nil
            summaryLabel.text = nil
            isHidden = true
            return
        }
        isHidden = false
        switch kind {
        case .quote(let quote):
            // 蓝色 = 「附加上下文」，与强调色一致；摘要比气泡里那条更短（旁边还有取消按钮，容器更窄）
            accentLine.backgroundColor = .systemBlue
            nameLabel.textColor = .systemBlue
            nameLabel.text = String(format: L("引用%@"), quote.displayName)
            summaryLabel.text = quote.summary(limit: 30)

        case .editing(let summary):
            // 橙色 = 「这次发送会改写历史」，与普通的「追加一条」区分开
            accentLine.backgroundColor = .systemOrange
            nameLabel.textColor = .systemOrange
            nameLabel.text = L("正在编辑这条消息")
            summaryLabel.text = summary
        }
    }

    @objc private func cancelTapped() {
        onCancel?()
    }
}
