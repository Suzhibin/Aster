import UIKit
import SnapKit
import AICore

/// 助手消息里的代码卡片：白底 + 细描边 + 圆角，顶部一条头部（左：语言名 / 右：「复制」），
/// 正文等宽字体、长行**按字符折行**。
///
/// ## 为什么它是一个**视图**，而不是字符串上的一段属性
/// 「圆角 / 内边距 / 一颗常驻的复制按钮」这三样都要求代码块**有自己的 frame**。
/// 打属性做不到 —— `UITextView` 的 `.backgroundColor` 只按行片段画矩形（圆角无从谈起），
/// 更没有地方挂按钮。本工程 2026-09-18 先试过那条路（方案 A：给富文本打底色 + 把复制
/// 藏进长按卡），结论是**天花板就在那**：底色是逐行色带、复制入口不可见。
/// 所以助手文本 cell 改成**分段渲染**：文本段走 `BubbleTextView`、代码段走本视图，
/// 竖直堆在 `contentStack` 里（见 `AIAssistantTextCell`）。
///
/// ## 颜色一律**固定**，不跟随深色模式
/// 气泡本身是「固定浅底（white 0.95）+ 固定深字」，代码卡片是它内部的一块。
/// 卡片若用 `systemBackground` / `label` 这类动态色，深色模式下会变黑底，
/// 在浅色气泡里戳出一个黑洞（而且卡片里外的文字颜色会一半反相一半不反）。
///
/// ## 量高与显示同源
/// 高度**只**由 `height(for:width:)` 给出 —— cell 的布局与 `AIChatRow.height(in:)` 都调它。
/// 它内部用的字体 / 段落样式 / 折行模式 / 内边距，与 `configure(code:language:)` 交给
/// `codeLabel` 的**是同一份**。⛔ 改任何一个数字都要两边一起变
/// （「量的时候按一套、显示按另一套」是本工程反复栽过的坑）。
///
/// - Note: `height(for:width:)` 的 `width` 传的是**气泡内的可用宽**
///   （= `AIChatRow` 里的 `maxTextW`），卡片自己再扣掉 `sideInset` 与 `contentPadding`。
final class AICodeBlockView: UIView {

    // MARK: - 回调

    /// 点「复制」时回调，参数是**当前**代码正文。
    ///
    /// ⚠️ 传字符串、而不是「让宿主自己回查行号」：cell 会被复用，
    /// 回查行号等于引入一次时序风险（本工程「按行号取内容」栽过）。
    var onCopy: ((String) -> Void)?

    // MARK: - 尺寸常量（**真源在业务层，这里只转发**）

    // ⚠️ 这三个数值的真源是 `AsterCore/AICore/AICodeBlockMetrics.swift`。
    // 原因：量高的那半（`AIChatRow.height(in:)` / `AIMarkdown`）在业务层，
    // 画卡片的这半在 App 侧 —— 两端必须同一份口径，所以**不能在两边各写一次数字**。
    // 视图侧保留同名属性只是为了不改动本文件里已有的调用点（`Self.sideInset` 等）。

    /// 卡片左右外边距（相对气泡内缘）。取 12 与正文的左右 inset 同值 —— 左边对齐。
    static let sideInset: CGFloat = AICodeBlockMetrics.sideInset
    /// 卡片内边距（头部 / 代码到卡片边缘）
    static let contentPadding: CGFloat = AICodeBlockMetrics.contentPadding
    /// 头部条高度（**含**底部那条发丝分隔线）
    static let headerHeight: CGFloat = AICodeBlockMetrics.headerHeight
    /// 头部条内的左右内边距（纯视觉，不参与量高，留在视图侧）
    private static let headerPadding: CGFloat = 10
    /// 卡片圆角（纯视觉，不参与量高）
    private static let cornerRadius: CGFloat = 10
    /// 发丝线宽度（1 物理像素，高分屏上是 1/3pt）
    private static let hairline: CGFloat = 1 / UIScreen.main.scale

    /// 代码段落样式 —— 转发自业务层（量高与显示共用同一份）。
    private static var codeParagraphStyle: NSParagraphStyle { AICodeBlockMetrics.paragraphStyle }

    private static var codeAttributes: [NSAttributedString.Key: Any] { AICodeBlockMetrics.attributes }

    // MARK: - 子视图

    private let card = UIView()
    private let header = UIView()
    private let languageLabel = UILabel()
    private let separator = UIView()
    private let copyControl = AICodeCopyControl()
    private let codeLabel = UILabel()

    /// 当前展示的代码正文（点「复制」时回传它）
    private var code = ""

    // MARK: - 高度

    /// 整条卡片的高度（含头部条与上下内边距）。
    ///
    /// ⚠️ 实现**转发到业务层** `AICodeBlockMetrics.height(for:width:)`。
    /// 业务层的行高量算（`AIChatRow.height(in:)`）与这里必须走**同一条**计算 ——
    /// 各写一份就是「量的时候按一套、显示按另一套」，本工程栽过的坑。
    /// 视图侧保留这个入口，只是为了让本文件已有的调用点不必改。
    ///
    /// - Parameter width: **气泡内可用宽**（与 `AIChatRow.height(in:)` 的 `maxTextW` 同源）。
    static func height(for code: String, width: CGFloat) -> CGFloat {
        AICodeBlockMetrics.height(for: code, width: width)
    }

    // MARK: - 配置

    func configure(code: String, language: String?) {
        self.code = code
        // 语言名统一小写（`Swift` → `swift`）；只取 info 串的第一个词
        //（`swift title=foo` 这种附加信息不该整个显示出来）
        let info = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        languageLabel.text = info.isEmpty
            ? L("代码")
            : (info.split(separator: " ").first.map { $0.lowercased() } ?? L("代码"))
        codeLabel.attributedText = NSAttributedString(string: code, attributes: Self.codeAttributes)
    }

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        card.backgroundColor = AITypography.codeCardBackground
        card.layer.cornerRadius = Self.cornerRadius
        card.layer.borderWidth = Self.hairline
        // ⚠️ 固定色，深色模式不换（换一次就得跟着换底色，见文件头的说明）
        card.layer.borderColor = AITypography.codeCardBorder.cgColor
        // 头部条贴圆角 → 需要裁；⚠️ 别在 card 上开 `masksToBounds` 之外的效果
        card.clipsToBounds = true
        addSubview(card)

        languageLabel.font = Self.headerFont
        languageLabel.textColor = AITypography.codeHeaderText
        languageLabel.numberOfLines = 1
        languageLabel.lineBreakMode = .byTruncatingTail
        header.addSubview(languageLabel)

        copyControl.onTap = { [weak self] in
            guard let self = self else { return }
            self.onCopy?(self.code)
        }
        header.addSubview(copyControl)

        separator.backgroundColor = AITypography.codeCardBorder
        header.addSubview(separator)
        card.addSubview(header)

        codeLabel.numberOfLines = 0
        codeLabel.attributedText = NSAttributedString(string: "", attributes: Self.codeAttributes)
        card.addSubview(codeLabel)

        card.snp.makeConstraints { make in
            make.top.bottom.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(Self.sideInset)
        }
        header.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.height.equalTo(Self.headerHeight)
        }
        separator.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(Self.hairline)
        }
        languageLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(Self.headerPadding)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(copyControl.snp.leading).offset(-8)
        }
        copyControl.snp.makeConstraints { make in
            make.trailing.equalToSuperview().offset(-Self.headerPadding)
            make.centerY.equalToSuperview()
        }
        // 代码区：上接头部、下留内边距。**高度不写死** —— 由 `codeLabel` 的内容撑，
        // 用与 `height(for:width:)` 完全相同的那份 attributes 算出来，两处天然一致。
        codeLabel.snp.makeConstraints { make in
            make.top.equalTo(header.snp.bottom).offset(Self.contentPadding)
            make.leading.trailing.equalToSuperview().inset(Self.contentPadding)
            make.bottom.equalToSuperview().offset(-Self.contentPadding)
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 头部小字字号（语言名）。比代码小一号，属元信息。
    private static let headerFont = UIFont.systemFont(ofSize: 11)
}

// MARK: - 「复制」按钮

/// 头部右侧的「复制」：一张图标 + 一段文字。
///
/// ⛔ **刻意不用 `UIButton` 的 `contentEdgeInsets` / `imageEdgeInsets`**：
/// 它们在 iOS 15 起被弃用，一用就是编译警告 —— 而本工程的验收基线是
/// 「**0 error + 1 warning**」（那 1 条是既有的 `allowBluetooth` 弃用）。
/// 用 `UIButton.Configuration` 又只能盖 iOS 15+（工程下限是 14）。
/// 这点样式手写更省事，也顺手拿到「按下压暗」的反馈。
private final class AICodeCopyControl: UIControl {

    var onTap: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        iconView.image = UIImage(systemName: "doc.on.doc")
        iconView.tintColor = AITypography.codeHeaderText
        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)

        titleLabel.text = L("复制")
        titleLabel.font = UIFont.systemFont(ofSize: 12)
        titleLabel.textColor = AITypography.codeHeaderText
        addSubview(titleLabel)

        // 高度 24：图标（13）之外再往外扩一圈，手指好点；同时**不超过头部条**（27）
        snp.makeConstraints { make in
            make.height.equalTo(24)
        }
        iconView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalToSuperview()
            make.width.height.equalTo(13)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(iconView.snp.trailing).offset(4)
            make.trailing.equalToSuperview()
            make.centerY.equalToSuperview()
        }
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func handleTap() { onTap?() }

    /// 按下压暗 —— 没有底色的控件靠这个给「按到了」的反馈
    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.45 : 1 }
    }
}
