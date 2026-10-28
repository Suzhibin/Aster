//
//  AIThinkingBlockView.swift
//  AIModule
//
//  助手气泡内的「思考过程」子块（2026-10-20）：左侧竖线 + 头部行（标题/耗时 + chevron）
//  + 展开时的思考正文。**整块是一个 UIControl**，点哪都展开/折叠（同 `AIQuoteBarView` 的形态）。
//
//  ## 尺寸全部来自 `AIThinkingBlockMetrics`
//  与 `AIChatRow.height(in:)` 同源（⛔ 别在这里写数字）：头部行高 = `collapsedHeight`，
//  正文宽 = 传入宽 − 竖线 − 间距 − 右留白，段落样式同 `paragraphStyle`。
//  「量的时候按 A、显示按 B」是本工程行高事故的头号成因。
//
//  ## 自撑高（不钉高度）
//  内部是一个 stack：头部（固定 `collapsedHeight`）+ 正文（折叠时 hidden）。
//  - 无思考 / 总闸关着 ⇒ 两个都藏 ⇒ 全块 0 高（宿主同时把 top 偏移归 0）；
//  - 折叠 ⇒ 只有头部 ⇒ `collapsedHeight`；
//  - 展开 ⇒ 头部 + 间距 + 正文。
//  宿主 `AIAssistantTextCell` 的 `contentStack` 恒接在本块 bottom 之下（偏移 `spacingBelow`），
//  所以「本块不存在」时正文落点与加这个功能之前**逐像素一致**（见 metrics 里 `spacingBelow` 的注释）。
//

import UIKit
import SnapKit
import AICore

final class AIThinkingBlockView: UIControl {

    /// 点按（展开 ⇄ 折叠）。宿主转交 `AIChatManager.setThinkingExpanded` ——
    /// 视图不知道自己第几行（cell 复用后行号会漂，回调里不该带行号）。
    var onToggle: (() -> Void)?

    private let accentLine = UIView()
    private let stack = UIStackView()
    private let headerRow = UIView()
    private let titleLabel = UILabel()
    private let chevron = UIImageView()
    private let bodyLabel = UILabel()

    /// 上一次配置的状态。流式期间 `configure` 每秒被调约 33 次，绝大多数是「正文又长了一点」——
    /// 标题 / 展开态没变就别碰约束与ImageView（`update(offset:)` 即使值不变也会触发一次布局）。
    private var applied: Applied?

    private struct Applied: Equatable {
        var hasThinking: Bool
        var title: String
        var expanded: Bool
        var body: String
        /// 🔴 正文字号（2026-10-22 加）：**不把它算进状态，早退就会绕过富文本重建** ——
        ///     改字号档位时 `reloadData` 复用旧 cell，文本四项都没变 ⇒ `state == applied`
        ///     提前 return，`bodyLabel.attributedText` 还是按旧字号建的（行高却按新字号量了）。
        ///     带上它，字号一变 state 就不同，必然走完整重建。与 `AIUserTextCell.configure`
        ///     现读 font 是同一个病的两个变体（快照 / 早退绕过）。
        var bodyFontSize: CGFloat
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        // 竖线：颜色跟随工程强调色（用户气泡 / 操作栏 / 横幅同一支 systemBlue）
        accentLine.backgroundColor = .systemBlue
        accentLine.layer.cornerRadius = 1
        addSubview(accentLine)

        stack.axis = .vertical
        stack.alignment = .fill
        // 段间距 = 头部与正文之间那一笔（与量高同源）
        stack.spacing = AIThinkingBlockMetrics.headerSpacing
        addSubview(stack)

        titleLabel.font = AIThinkingBlockMetrics.font
        titleLabel.textColor = .secondaryLabel
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        headerRow.addSubview(titleLabel)

        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        // ☠️ 必须先 addSubview 再上约束：SnapKit 在没有 superview 的视图上装约束会
        //    直接崩（common ancestor 找不到）——2026-10-21 真机踩过，本条就是漏网的那一个。
        headerRow.addSubview(chevron)
        // 与标题同一行、贴右：给「这一行能点开」一个视觉把柄
        chevron.snp.makeConstraints { make in
            make.trailing.centerY.equalTo(headerRow)
            make.width.height.equalTo(12)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.top.bottom.equalTo(headerRow)
            make.trailing.equalTo(chevron.snp.leading).offset(-4)
        }
        // 头部行高 = 折叠态高度（量高口径的那一行，⛔ 别让内容自撑 —— 撑出来与量高必漂）
        headerRow.snp.makeConstraints { $0.height.equalTo(AIThinkingBlockMetrics.collapsedHeight) }
        stack.addArrangedSubview(headerRow)

        // 正文：字体 / 段落样式与量高同源；颜色改成本端语义色（不影响高度 —— 高度只认字体与段落）
        bodyLabel.numberOfLines = 0
        stack.addArrangedSubview(bodyLabel)

        accentLine.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.width.equalTo(AIThinkingBlockMetrics.accentLineWidth)
        }
        stack.snp.makeConstraints { make in
            make.leading.equalTo(accentLine.snp.trailing).offset(AIThinkingBlockMetrics.accentSpacing)
            make.trailing.equalToSuperview().offset(-AIThinkingBlockMetrics.rightInset)
            make.top.bottom.equalToSuperview()
        }

        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 配置。
    ///
    /// - Parameters:
    ///   - reasoning: 思考内容；`nil` / 空 / **展示总闸关着** ⇒ 整块收起（0 高）
    ///   - expanded: 展开还是折叠（取 `AIChatRow.isThinkingExpanded`）
    ///   - streaming: 流式中（头部显示「思考中…」、不显示耗时）
    func configure(reasoning: AIReasoning?, expanded: Bool, streaming: Bool) {
        // 总闸判据与 `AIChatRow.thinkingHeightOrZero` **逐字一致**（同一件事两处判，必然同口径）
        let visible: Bool
        if let reasoning, !reasoning.isEmpty, AIGenerationSettings.showsThinkingProcess {
            visible = true
        } else {
            visible = false
        }
        let title: String
        if visible {
            title = streaming ? reasoning!.streamingTitle : reasoning!.collapsedText
        } else {
            title = ""
        }
        let body = (visible && expanded) ? reasoning!.text : ""
        let state = Applied(hasThinking: visible, title: title, expanded: expanded, body: body,
                            bodyFontSize: AITypography.bodyFontSize)
        guard state != applied else { return }
        applied = state

        isHidden = !visible
        // 头部 / 正文的显隐 = stack 的自撑高开关（hidden 的 arrangedSubview 不占高度）
        headerRow.isHidden = !visible
        bodyLabel.isHidden = !(visible && expanded)
        titleLabel.text = title
        chevron.image = UIImage(systemName: expanded ? "chevron.down" : "chevron.right")
        if !body.isEmpty {
            // 颜色覆盖成 secondaryLabel（metrics.attributes 里那色是「没有语义色时的默认」）
            var attributes = AIThinkingBlockMetrics.attributes
            attributes[.foregroundColor] = UIColor.secondaryLabel
            bodyLabel.attributedText = NSAttributedString(string: body, attributes: attributes)
        } else {
            bodyLabel.attributedText = nil
        }
        // VoiceOver：折叠时念头部那一行就够；展开时把正文一起念
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = expanded && !body.isEmpty ? "\(title)\n\(body)" : title
    }

    @objc private func handleTap() {
        onToggle?()
    }

    // MARK: - 🧪 探针自检（#if DEBUG）

    /// chevron 是否真的挂进了视图树。
    ///
    /// 2026-10-21 崩溃修复的**回归守门**：当初就是漏了 `headerRow.addSubview(chevron)`
    /// —— SnapKit 给没有 superview 的视图装约束**直接崩**，而这类错误
    /// **编译零症状**（typecheck 全绿、一上真机每条助手文本 cell 都崩）。
    /// 这个判据让「忘了挂」在无人值守探针里现形，不靠人眼。
    #if DEBUG
    var probeChevronIsMounted: Bool { chevron.superview != nil }
    #endif
}
