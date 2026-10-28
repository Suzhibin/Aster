import UIKit
import SnapKit
import AICore

/// 用户消息气泡（右侧）
public final class AIUserTextCell: UITableViewCell {

    private let bubble = UIView()
    /// 同助手气泡：默认对触摸透明，进入「选择文字」态后才接管（见 `BubbleTextView`）
    private let textView = BubbleTextView()
    /// 气泡上方的「时间」小字（聊天页不显示 token 用量，所以这里只可能是时间）
    private let metaLabel = UILabel()
    /// 气泡顶边约束：显示小字行时要往下让出 `AIChatRow.metaHeight`
    private var bubbleTop: Constraint?

    /// 气泡**内部**上方的引用条（这一条引用了谁）。无引用时高度收到 0 并隐藏。
    private let quoteBar = AIQuoteBarView()
    /// 引用条高度约束 —— 数值只能来自 `AIChatRow.quoteHeight`（与行高量算同源）
    private var quoteBarHeight: Constraint?

    /// 点引用条（把被引用消息的 id 交给宿主去滚动定位）
    var onQuoteTap: ((UUID) -> Void)?

    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        bubble.backgroundColor = .systemBlue
        bubble.layer.cornerRadius = 14
        contentView.addSubview(bubble)

        metaLabel.font = Self.metaFont
        metaLabel.textColor = .tertiaryLabel
        metaLabel.numberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.textAlignment = .right
        contentView.addSubview(metaLabel)

        // 与助手气泡同理：能选、不能改。**默认不吃触摸**（见 `BubbleTextView`），
        // 因而「轻点弹操作卡」「长按选中」两条路互不干扰。
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = true
        textView.delegate = self
        // 字号取 AITypography.body —— 与助手气泡共用同一个值（见 AITypography 注释）。
        // ⚠️ 这只是**初值**：每次复用的刷新点在 `configure`（那边现读）——
        //    只在这里设 = 快照，改字号后已显示的行不换字（2026-10-22 踩过）。
        textView.font = AITypography.body
        textView.textColor = .white
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        textView.textContainer.lineFragmentPadding = 0

        // 引用条在气泡**内部**上方：先加它，再把正文接在它下面（顺序 = 层级，正文不会盖住它）
        quoteBar.onTap = { [weak self] id in
            guard let self else { return }
            self.onQuoteTap?(id)
        }
        bubble.addSubview(quoteBar)
        bubble.addSubview(textView)

        metaLabel.snp.makeConstraints { make in
            // 与气泡右对齐（用户消息在右侧）
            make.trailing.equalToSuperview().offset(-12)
            make.leading.greaterThanOrEqualToSuperview().offset(64)
            make.top.equalToSuperview()
            make.height.equalTo(AIChatRow.metaHeight)
        }
        bubble.snp.makeConstraints { make in
            bubbleTop = make.top.equalToSuperview().offset(6).constraint
            make.bottom.equalToSuperview().inset(6)
            make.right.equalToSuperview().offset(-12)
            // ⚠️ 这条左侧限制相对的是 **cell** 而不是 `superview`（= contentView）：
            // 表格进入编辑态（多选删除）时会把 contentView **左侧**内缩 4x pt 给勾选圆圈腾位置，
            // 而气泡右侧仍贴着 contentView 的右边（= cell 的右边）→ 可用宽度会凭空少掉那一个内缩。
            // 相对 cell 表达「离屏幕左边至少 64」才是原意：内缩多少都自动补回来，
            // 长文本不会重新折行（行高是预计算并只读缓存的，折行一变就会裁字）。
            make.left.greaterThanOrEqualTo(self).offset(64)
            make.width.lessThanOrEqualTo(UIScreen.main.bounds.width * 0.8)
        }
        quoteBar.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            // 高度是**可变的**：无引用时 0（不是隐藏留白），有引用时 `AIChatRow.quoteHeight`
            quoteBarHeight = make.height.equalTo(0).constraint
        }
        textView.snp.makeConstraints { make in
            make.top.equalTo(quoteBar.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// - Parameters:
    ///   - metaText: 气泡上方的时间小字（取 `AIChatRow.metaText`，nil = 不显示）
    ///   - quote: 这一条引用了谁（取 `AIChatRow.block.quote`，nil = 不显示引用条）
    public func configure(_ text: String, metaText: String? = nil, quote: AIQuote? = nil) {
        // 🔴 字号必须**现读**（2026-10-22 用户报「改字号后已发的消息不变，重启才变」）：
        //    `init` 里那次 `textView.font = AITypography.body` 是**快照** —— cell 复用时
        //    configure 只换文字，font 停在创建那一刻的字号上。改档位的链路是
        //    `recomputeAllRowHeights()`（行高按新字号重算）+ `reloadData()`（复用旧 cell）
        //    ⇒ 行高新字号、文字旧字号，「量算与渲染不同源」：大字号裁字、小字号底部空一截。
        //    ⚠️ 与助手气泡三条 configure 路径同一口径（`applyPlainText` / `applySegments`
        //    的富文本都自带 font，每次 configure 现读）—— 用户气泡是唯一漏这条的。
        textView.font = AITypography.body
        textView.text = text
        applyMeta(metaText)
        applyQuote(quote)
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        // 选择态 gate 必须复位（复用后这一行已不是当初被长按的那条）
        textView.endSelection()
        textView.text = nil
        applyMeta(nil)
        applyQuote(nil)
        // 定位高亮是一次性的，别带到复用后的下一行
        contentView.backgroundColor = .clear
    }

    /// 显示/隐藏时间小字，并把气泡顶边让出对应高度（数值与行高量算同源）
    private func applyMeta(_ text: String?) {
        let text = (text?.isEmpty ?? true) ? nil : text
        metaLabel.text = text
        metaLabel.isHidden = (text == nil)
        bubbleTop?.update(offset: 6 + (text == nil ? 0 : AIChatRow.metaHeight))
    }

    /// 显示/隐藏引用条，并把气泡内正文的顶边让出对应高度。
    /// ⚠️ 高度值**只能**来自 `AIChatRow.quoteHeight`：`height(in:)` 那边按同一个常量累加，
    /// 两边写成不同数字 → 不是引用条被裁，就是气泡底部空一段。
    private func applyQuote(_ quote: AIQuote?) {
        quoteBar.configure(with: quote)
        quoteBarHeight?.update(offset: quote == nil ? 0 : AIChatRow.quoteHeight)
    }

    private static let metaFont = UIFont.systemFont(ofSize: 12)
}

// MARK: - 正文选中（操作卡里的「选取文字」调用）

extension AIUserTextCell: AIBubbleTextSelecting {

    /// 进入选择态，选中 `point`（**cell 坐标系**）所在的那一行；没有锚点时全选正文。
    /// 空白消息返回 false，宿主会据此给一句 toast。
    func beginTextSelection(at point: CGPoint?) -> Bool {
        guard !(textView.text ?? "").isEmpty else { return false }
        // cell 坐标 → textView 坐标。⚠️ `convert(_:from:)` 的接收者是**目标**视图（textView），
        // 入参点当前在 `from`（= cell 自己）里；写反了会得到恒偏移的点，而编译不报错。
        return textView.beginSelection(at: point.map { textView.convert($0, from: self) })
    }

    func endTextSelection() {
        textView.endSelection()
    }
}

// MARK: - UITextViewDelegate（选择态收尾）

extension AIUserTextCell: UITextViewDelegate {

    /// 失焦（点别处 / 菜单收起）→ 关掉 gate，别让它卡在「吃触摸」的状态
    public func textViewDidEndEditing(_ textView: UITextView) {
        (textView as? BubbleTextView)?.endSelection()
    }
}

// MARK: - AIChatContentBlockProviding

/// 内容块 = 文本行：气泡（长按照到这里才弹操作卡，气泡外的留白不响应）。
///
/// ⚠️ 实现必须留在本文件：`bubble` 是 `private let`，而 `private` 是**文件级**
/// 作用域 —— 挪到协议所在文件会 `inaccessible due to 'private' protection level`。
extension AIUserTextCell: AIChatContentBlockProviding {
    var contentBlockView: UIView? { bubble }
}

// MARK: - AIChatSelectionTouchYielding

extension AIUserTextCell: AIChatSelectionTouchYielding {

    /// 选择模式（多选删除）下关掉引用条上的跳转。
    ///
    /// 点引用条 = 「滚回被引用的那条并闪一下」，与「勾选这一行」是两件事，而它就压在气泡里，
    /// 勾选时极易误触。关掉之后点它只是勾选，不会把列表滚走。
    /// （正文的 `BubbleTextView` 不用管：未进选字态时它本来就对触摸透明。）
    func setSelectionMode(_ on: Bool) {
        quoteBar.isUserInteractionEnabled = !on
    }
}
