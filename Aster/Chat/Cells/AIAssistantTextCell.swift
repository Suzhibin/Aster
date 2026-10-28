import UIKit
import SnapKit
import AICore
// 行内公式的附件类型定义在接缝层（`NSTextAttachment` 是平台类型，只能在 `AIPlatform/` 里碰）。
// ⚠️ `import AICore` **不会**顺带把 AIPlatform 的符号带进来 —— 必须显式 import。
import AIPlatform

/// 助手文本气泡（左侧）：流式用纯文本，结束后按 Markdown **分段渲染**
/// （文本段走 `BubbleTextView`、围栏代码段走 `AICodeBlockView` 卡片）。
///
/// 气泡**下方**可选一条横排操作栏（内容见 `AIRowAction.barActions`）——是否显示由宿主的
/// `AIChatRow.showsActionBar` 决定（判定在 `AIChatManager`，cell 自己不该知道「我是不是最后一条」）。
/// 未显示操作栏的那条，操作用长按 cell 弹出的操作卡。
public final class AIAssistantTextCell: UITableViewCell {

    /// 操作栏点击回调（与长按操作卡共用同一套动作 `AIRowAction`）
    var onAction: ((AIRowAction) -> Void)?

    /// 代码卡片的「复制」回调，参数是**那一段**代码。
    /// 由宿主接过去写剪贴板 + 提示 —— cell 不该知道 toast 长什么样。
    var onCopyCode: ((String) -> Void)?

    /// 正文里的网址被点中（2026-10-02）。宿主负责**跳转**（push 内置网页页）——
    /// cell 不该知道导航栈长什么样，与 `onCopyCode` 同一分工。
    ///
    /// ⚠️ 回调带的是**那个 URL 本身**、不是行号：cell 复用后行号会漂，URL 不会。
    var onOpenURL: ((URL) -> Void)?

    /// 思考块的头部被点（展开 ⇄ 折叠，2026-10-20）。宿主转交
    /// `AIChatManager.setThinkingExpanded` —— 与上面几个回调同一分工：cell 不知道自己第几行。
    var onToggleThinking: (() -> Void)?

    /// 「思考过程」子块（2026-10-20）：坐在气泡内、正文**上方**，左侧一条竖线。
    ///
    /// 🔴 与 `contentStack` 是**兄弟**而不是它的 arrangedSubview：`drainContent()` 会摘空
    ///    stack 上全部视图，思考块进去就会被误收；且 `applyPlainText` 的「单段纯文本」快路径
    ///    按 `arrangedSubviews.count == 1` 判定，多一个成员就永远走不上快路径（流式 33 帧/秒）。
    ///    做成兄弟后那条快路径与 `drainContent` **一行都不用改**。
    ///
    /// 🔴 `contentStack` 的 top **恒接在本块 bottom 之下**（偏移 `spacingBelow`）——
    ///    本块不存在时高度 0、top 偏移也归 0，正文落点与加这个功能之前逐像素一致
    ///    （等式见 `AIThinkingBlockMetrics.spacingBelow` 的注释）。
    private let thinkingView = AIThinkingBlockView()
    /// 思考块 top 相对气泡顶的偏移：有思考 = `AIMarkdown.contentPaddingV`，无思考 = 0。
    /// 只改偏移、不换约束（两条约束激活/切换正是本文件明令禁止的「两条同时活」风险）。
    private var thinkingViewTop: Constraint?

    private let bubble = UIView()

    /// 正文容器：把消息按「文本段 / 代码段」竖排。
    ///
    /// 2026-09-18 之前这里是一个 `textView`。改成 stack 的**唯一原因**是代码块：
    /// 圆角 / 内边距 / 一颗常驻的复制按钮都要求代码块**有自己的 frame**，
    /// 而字符串上的一段属性给不了 frame（见 `AICodeBlockView` 的文件头）。
    ///
    /// ⚠️ 竖直留白与段间距的**唯一来源**在 `AIMarkdown`：
    /// `contentPaddingV`（上下）+ `segmentSpacing`（段间）。
    /// `AIChatRow.height(in:)` 那边按同样的常量累加 —— 两边必须一起改。
    private let contentStack = UIStackView()

    /// 分段视图的复用池。cell 复用很频繁，`UITextView` 的创建不便宜。
    /// ⚠️ 池只会涨到「历史最大段数」，有界（`drainContent` 每次都把在用视图收回来）。
    private var textViewPool: [BubbleTextView] = []
    private var codeViewPool: [AICodeBlockView] = []
    /// 公式块的复用池（视图本身只是一个 `UIImageView`，复用是零成本的）
    private var mathViewPool: [AIMathBlockView] = []
    /// 当前终态源文。**只为明暗切换时重渲公式**：文字用语义色会自己变，
    /// 而公式是**位图**，不会跟着 trait 变 —— 见 `traitCollectionDidChange`。
    private var currentMarkdown: String?
    /// 当前挂在 `contentStack` 上的**文本段**（顺序与 stack 一致）。
    /// 「选取文字」要在其中找到锚点所在的那一段。
    private var activeTextViews: [BubbleTextView] = []

    /// 气泡上方的「时间」小字（不显示时整行收起，高度归 0）
    ///
    /// ⚠️ 用量**不在这里，也不在聊天页任何地方**（2026-09-17 撤掉）：这条小字只承担「报时间」，
    /// 所以它可能整条不存在（与上一条间隔不够）。
    private let metaLabel = UILabel()
    /// 气泡顶边约束：显示小字行时要往下让出 `AIChatRow.metaHeight`
    private var bubbleTop: Constraint?
    /// 「首字未到」时的三点等待指示（只在**空文本的流式行**显示，见 `setTyping(_:)`）
    private let typingView = AITypingIndicatorView()
    /// 三点是否正显示 —— 让 `setTyping(_:)` **完全幂等**（流式期间它每秒被调约 33 次）
    private var isTypingShown = false
    /// 气泡宽度的**唯一**「钉宽」约束（默认关）。开/关只有 `setBubbleWidthPin(_:)` 一个入口。
    ///
    /// 两件事共用它**一条**，靠「常量 + 启停」切换：
    ///
    /// - **三点等待** → 钉 `typingWidth`（12 + 26 + 12 = 50）。首字未到时正文是**空串**，
    ///   而空 `UITextView` 的 `intrinsicContentSize.width` 是 `noIntrinsicMetric`（不是 0）——
    ///   宽度这一维**凭空失去了唯一来源**。Auto Layout 对欠定维度的处理是**保持当前 frame**，
    ///   于是被复用的 cell 会把上一条（通常很长、早已顶到上限）的气泡宽度**原样带过来**
    ///   → 等待态就画成**一条最宽的灰条 + 三个小点**。钉死后这一维确定，与 cell 是新是旧无关。
    /// - **含代码块** → 钉 `fullBubbleWidth`（0.8×屏宽）。`AIChatRow.height(in:)` 正是按这个宽度
    ///   预测代码卡折行位置的，而气泡宽度本该**由内容撑出来** —— 两者不一致时实际折行与预测不同，
    ///   行高就对不上（表现为裁掉最后一行 / 底部多出一截空白）。
    ///   只有「宽度确定 → 折行确定 → 高度确定」这条链才闭合。
    ///
    /// 🔴 **为什么是「一条」而不是「两条各管一摊」**（2026-09-19 返工）：
    /// 两条宽度**等式**（50 与 0.8×屏宽）都是 required，**只要同时活着就无解** ——
    /// 引擎只能打破一条并在控制台刷 `Unable to simultaneously satisfy constraints`
    /// （真机日志：`#149 UIView.width == 50.0` 与 `#151 UIView.width == 336.0` 并列）。
    /// 而「两条永不同时激活」只能靠**调用顺序纪律**维持：任何入口漏掉一次撤钉（或被门禁挡掉）
    /// 就当场复发 —— **靠纪律维持的不变量迟早被踩坏**。收敛成「一条约束 + 一个状态」之后，
    /// 「两条同时活」在结构上**不可表达**。
    private var bubbleWidthPin: Constraint?
    /// 气泡右侧留白的**基准值**。
    ///
    /// ⚠️ 它与 `AIChatRow.height(in:)` 里「0.8×屏宽」的折行预测是**同一套口径的两半**
    ///（12 + 64 ≈ 屏宽的 20%），所以两边都得基于「不含任何编辑器内缩」的宽度。
    /// 改动它会同时挪动折行位置与行高，⛔ 别单独动这一个数。
    private static let bubbleRightMargin: CGFloat = 64
    /// 气泡右边界约束（`≤ contentView 右边 - 留白`）。会随表格的编辑态内缩动态调整，
    /// 见 `applyEditInsetCompensation()`。
    private var bubbleRight: Constraint?
    /// 已经落在 `bubbleRight` 上的留白值 —— 只用来挡住重复设置（同一个值反复 update 会白跑一次布局）
    private var appliedBubbleRightMargin = AIAssistantTextCell.bubbleRightMargin

    // MARK: 流式期间的「免重复设置」状态位
    //
    // 下面几个值都会在流式刷新里被反复写，而 `configureStreaming` 每秒被调约 33 次
    //（`AIChatManager.revealInterval` = 0.03）。约束的 `update(offset:)` **即使值没变**
    // 也会重新激活一次约束并当场触发布局 —— 这是本文件里最便宜就能省掉的一笔开销。
    //
    // ⚠️ 每个状态位的初始值都**必须与 init 里实际设定的值一致**，否则第一次「本该发生」的
    //    设置会被门禁挡掉（表现是首屏缺一条约束 / 小字行没让位 / 栏位错位）。

    /// `contentStack` 上当前是不是「那一个纯文本段」（`applyPlainText` 铺的那种）。
    /// 为 true 时流式刷新只换文本、不拆装视图树。
    private var isPlainTextLayout = false
    /// 操作栏当前是否展开（与 init 里 `actionBar.isHidden = true` + 高度 0 对应）
    private var appliedActionBarVisible = false
    /// 当前**钉住**的宽度值；`-1` = 未钉（宽度交还给内容撑）。与 init 里 `isActive = false` 对应。
    ///
    /// ⚠️ 钉宽的「已生效值」**只有这一个来源** —— 从前的两个标志（三点一个、满宽一个）
    /// 就是「两条约束各自记账」的产物，它们一旦与约束的实际状态脱钩就再也不会自愈。
    private var appliedBubbleWidthPin: CGFloat = -1
    private let actionBar = AIActionBarView()
    /// 操作栏高度约束：收起时置 0（配合 `isHidden`），展开时 `AIChatRow.actionBarHeight`
    private var actionBarHeight: Constraint?

    public override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        bubble.backgroundColor = UIColor(white: 0.95, alpha: 1)
        bubble.layer.cornerRadius = 14
        contentView.addSubview(bubble)

        metaLabel.font = Self.metaFont
        metaLabel.textColor = .tertiaryLabel
        metaLabel.numberOfLines = 1
        metaLabel.lineBreakMode = .byTruncatingTail
        // 初始即「无小字」态：与 `applyMeta(nil)` 的结果一致，这样 `applyMeta` 的
        // 「值没变就不写」门禁在第一次遇到 nil 时不会漏掉 `isHidden`
        metaLabel.isHidden = true
        contentView.addSubview(metaLabel)

        contentStack.axis = .vertical
        contentStack.alignment = .fill
        contentStack.spacing = AIMarkdown.segmentSpacing
        bubble.addSubview(contentStack)

        // 思考块：气泡内、正文上方（2026-10-20）。与 contentStack 兄弟关系见声明处注释。
        thinkingView.onToggle = { [weak self] in
            self?.onToggleThinking?()
        }
        bubble.addSubview(thinkingView)

        // 三点等待指示：叠在正文之上（两者互斥 —— 有正文时它一定是收起的）
        bubble.addSubview(typingView)

        // 操作栏：贴气泡下方、与气泡左对齐；默认收起（隐藏 + 高度 0）
        actionBar.isHidden = true
        actionBar.onTap = { [weak self] action in
            guard let self else { return }
            self.onAction?(action)
        }
        contentView.addSubview(actionBar)

        metaLabel.snp.makeConstraints { make in
            // 与气泡左对齐：小字跟着气泡走，一眼能看出它属于哪一条
            make.leading.equalToSuperview().offset(12)
            make.trailing.lessThanOrEqualToSuperview().offset(-16)
            make.top.equalToSuperview()
            make.height.equalTo(AIChatRow.metaHeight)
        }
        bubble.snp.makeConstraints { make in
            bubbleTop = make.top.equalToSuperview().offset(6).constraint
            make.left.equalToSuperview().offset(12)
            bubbleRight = make.right.lessThanOrEqualToSuperview()
                .offset(-Self.bubbleRightMargin).constraint
            make.width.lessThanOrEqualTo(Self.fullBubbleWidth)
            // 气泡宽度的**唯一**「钉宽」约束（默认关；开/关见 `setBubbleWidthPin(_:)`）。
            // ⚠️ 必须随「三点」或「代码块」启停：常开的话单字气泡（「好」≈ 12+16+12 = 40pt）
            //    会被无故撑到 0.8×屏宽。
            bubbleWidthPin = make.width.equalTo(Self.fullBubbleWidth).constraint
        }
        // 🔴 上面那条「默认关闭」的宽度约束，**只能在这里关** —— ⛔ 绝不能把那句
        //   `isActive = false` 写在上面那个闭包**里面**（2026-09-19 踩过，代价是整屏气泡全废）。
        //
        //   原因在 SnapKit 的安装顺序：`makeConstraints` 是「**先跑闭包、再把闭包里攒下的约束
        //   无条件 activate**」（`ConstraintMaker.prepareConstraints` → `Constraint.activateIfNeeded
        //   (updatingExisting: false)` → `NSLayoutConstraint.activate`）。而 `isActive = false`
        //   走的是 `deactivate()`，对一条**尚未安装**的约束是 **no-op** —— 闭包里那句「关」
        //   在闭包返回后就等价于没写，紧接着照样被激活。
        //   （已实测：闭包内关 → init 结束即 `typing=ON full=ON`；闭包外关 → 两条都 off。）
        //
        //   症状（2026-09-19 真机）：`width == 50` 常开 → 每个气泡都被钉成 50pt 宽，
        //   正文每行只放得下两个字 → 整屏看起来「只剩下竖着的一行」。
        //
        //   📌 判据：**判断一条约束「装没装」要看闭包边界，不看代码顺序。**
        //   闭包内只能"造"约束（取 `.constraint` 存起来），要"关"必须等闭包返回之后。
        bubbleWidthPin?.isActive = false
        // 上下留白归 stack（不再让每个 textView 自带）：这样「文本段 + 代码段」之间
        // 不会多出一份重复的留白 —— `AIMarkdown.contentPaddingV` 是唯一来源。
        // 左右与气泡齐平（正文自己的 12pt 内缩在 textView 里），思考块同理 —— 它的竖线
        // 因此与正文左缘对齐。
        thinkingView.snp.makeConstraints { make in
            // 偏移默认 0（无思考态）—— 与「本块高度 0」合起来保证正文落点与从前一致
            thinkingViewTop = make.top.equalToSuperview().offset(0).constraint
            make.leading.equalToSuperview().offset(12)
            make.trailing.equalToSuperview().offset(-12)
        }
        contentStack.snp.makeConstraints { make in
            // 🔴 top 恒接思考块 bottom（偏移 `spacingBelow` = `contentPaddingV`）——
            //    ⛔ 别回到「top = 气泡顶 + contentPaddingV」再按有无思考切约束：
            //    那正是本文件 `bubbleWidthPin` 踩过的「两条约束抢激活」坑。
            make.leading.trailing.equalToSuperview()
            make.top.equalTo(thinkingView.snp.bottom).offset(AIThinkingBlockMetrics.spacingBelow)
            make.bottom.equalToSuperview().offset(-AIMarkdown.contentPaddingV)
        }
        // 三点：左侧与正文同一起始位置（`typingInset` == 正文的左右 inset），
        // 垂直居中于气泡；尺寸取 `AITypingIndicatorView.intrinsicSize`（唯一来源）
        typingView.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(Self.typingInset)
            make.centerY.equalToSuperview()
            make.width.equalTo(AITypingIndicatorView.intrinsicSize.width)
            make.height.equalTo(AITypingIndicatorView.intrinsicSize.height)
        }
        // 竖直方向是一条链：小字行(0 或 metaHeight) → 气泡(上 6) → 操作栏 → 底 6
        // 因此行高必须等于 metaH + 内容高 + 12 + (操作栏 0 或 AIChatRow.actionBarHeight)，
        // 与 `AIChatRow.height(in:)` 一致（内容高的算法在 `AIMarkdown.contentHeight`）
        //
        // 水平方向刻意用 `lessThanOrEqualTo`（**不撑满**）：栏的宽度只包住那几颗按钮，
        // 右侧留下的空白仍然归 cell —— 否则这条 35pt 高的横带会自己接住轻点，
        // 「点操作栏右侧空白弹操作卡」就不灵了（曾经为了右对齐一段文案改成 `equalTo`，已还原）。
        actionBar.snp.makeConstraints { make in
            make.top.equalTo(bubble.snp.bottom)
            make.left.equalTo(bubble)
            make.right.lessThanOrEqualToSuperview().offset(-12)
            make.bottom.equalToSuperview().inset(6)
            actionBarHeight = make.height.equalTo(0).constraint
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 配置

    /// 流式中的纯文本（带可选光标）。
    /// 必须用显式 attributedText（普通字重 + 正文色）而非 textView.text，
    /// 否则会继承上一条已结束消息（Markdown 粗体）残留在 typingAttributes 里的粗体属性。
    ///
    /// `text` 为空 = **首字还没到**（`AIChatManager` 发送时先插一个空文本行，然后等 TTFB）
    /// → 换成三点等待指示，见 `setTyping(_:)`。判据就是这个 `isEmpty`，不需要新状态位。
    ///
    /// - Parameter reasoning: 本行的思考内容（2026-10-20；推理模型「先想后说」，
    ///   正文还没开始流的时候它就开始了）。`nil` = 这一行没有思考。
    public func configureStreaming(_ text: String,
                                   metaText: String? = nil,
                                   reasoning: AIReasoning? = nil) {
        applyActionBar(visible: false)
        applyMeta(metaText)
        // 🔴 三点只在「既没正文、也没思考」时出现（2026-10-20）：推理模型的思考先于正文到达，
        //    那一刻该显示的是思考块，不是「干等」的三点 —— 两者同屏会互相打架。
        //    宽度钉住的判据同步收紧：有思考时气泡要由思考块撑宽，钉 50 会把它压成一条。
        let hasThinking = reasoning != nil && AIGenerationSettings.showsThinkingProcess
        setTyping(text.isEmpty && !hasThinking)
        setBubbleWidthPin(text.isEmpty && !hasThinking ? Self.typingWidth : nil)
        applyPlainText(text.isEmpty ? "" : text + "▍",
                       font: AITypography.body,
                       color: AITypography.bodyColor)
        thinkingView.configure(reasoning: hasThinking ? reasoning : nil,
                               expanded: true,      // 流式中自动展开（收尾时折叠）
                               streaming: true)
        thinkingViewTop?.update(offset: hasThinking ? AIMarkdown.contentPaddingV : 0)
    }

    /// 流式结束：按 Markdown **分段**渲染（文本段 + 代码卡片）
    /// - Parameters:
    ///   - showsActionBar: 是否显示下方操作栏（取 `AIChatRow.showsActionBar`）
    ///   - isSpeaking: 本行是否正在朗读（只影响 `.speak` 那颗按钮的图标）
    ///   - metaText: 气泡上方的**时间**小字（取 `AIChatRow.metaText`，nil = 不显示）
    ///   - reasoning: 本行的思考内容（2026-10-20；nil = 没有思考 / 总闸关着）
    ///   - thinkingExpanded: 思考块是否展开（取 `AIChatRow.isThinkingExpanded`）
    public func configureFinal(_ text: String,
                               showsActionBar: Bool,
                               isSpeaking: Bool = false,
                               metaText: String? = nil,
                               reasoning: AIReasoning? = nil,
                               thinkingExpanded: Bool = false) {
        // 次序保持「先撤等待态、再上终态」：`setTyping` 现在只关指示器（不再碰宽度），
        // 钉宽的接替（三点 50 → 代码块 0.8×屏宽 / 交还内容）由 `applySegments` 一次说清 ——
        // 顺序不再决定成败（单条约束没有「两条同时活」这种状态），但读起来与状态机语义一致。
        setTyping(false)
        applySegments(text)
        applyActionBar(visible: showsActionBar)
        actionBar.setSpeaking(showsActionBar && isSpeaking)
        applyMeta(metaText)
        let hasThinking = reasoning != nil && AIGenerationSettings.showsThinkingProcess
        thinkingView.configure(reasoning: hasThinking ? reasoning : nil,
                               expanded: thinkingExpanded,
                               streaming: false)
        thinkingViewTop?.update(offset: hasThinking ? AIMarkdown.contentPaddingV : 0)
    }

    /// 失败提示：正文就是错误说明（如「⚠️ 账户余额不足（HTTP 402）\n请到该平台充值后再试」）。
    ///
    /// 与 `configureFinal` 的差别：走纯文本渲染（Markdown 会把提示里的换行吞成空格）、用警示色，
    /// 且**没有操作栏**——这里要复制的是「重发一次」，不是这段文案
    /// （那条路走长按操作卡的「重试」）。
    public func configureNotice(_ text: String) {
        applyActionBar(visible: false)
        applyMeta(nil)
        setTyping(false)
        setBubbleWidthPin(nil)
        applyPlainText(text, font: AITypography.notice, color: .systemOrange)
        // 失败提示不带思考块（那一轮的思考随失败提示一并舍去，见 `finalizeStreamingText`）
        thinkingView.configure(reasoning: nil, expanded: false, streaming: false)
        thinkingViewTop?.update(offset: 0)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        applyEditInsetCompensation()
    }

    /// 明暗切换：**公式要重渲**，文字不用。
    ///
    /// 🔴 文字走语义色（`AITypography.bodyColor` / SwiftUI 的 `.foregroundStyle`），
    ///    系统自己会换色；而公式是**业务层渲好的位图**，位图不知道 trait 变了 ——
    ///    不重渲的话，切到深色模式后公式还是黑图，等于「公式凭空消失」。
    ///
    /// ⚠️ 判据只比 `userInterfaceStyle`，别用 `hasDifferentColorAppearance`：
    ///    后者在对比度 / 色域变化时也为真，那些情况不需要重排公式。
    /// ⚠️ 图本身按墨色分档缓存（`inkKey`），所以这里的「重排」只是去取另一档，不会真重绘。
    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard let markdown = currentMarkdown,
              previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle
        else { return }
        applySegments(markdown)
    }

    /// 表格进入编辑态（多选删除）时，把气泡右侧留白**等量收回**，让气泡宽度保持原样。
    ///
    /// ## 为什么必须有这一步
    /// 编辑态会给每行左侧腾出勾选圆圈的位置，做法是把 `contentView` **整体右移**
    ///（只有左侧内缩，右侧仍与 cell 齐平）。于是气泡可用的横向空间凭空少掉那一个内缩：
    /// - 长段落会按更窄的宽度**重新折行**，多出来的行被裁掉 —— 因为行高是数据层按
    ///   「0.8×屏宽」预先算好、`heightForRowAt` **只读缓存**的（见 `+Table` 头部说明）；
    /// - 含代码块时更严重：`bubbleWidthPin` 是一条「宽度 = 0.8×屏宽」的**等式**约束，
    ///   与右侧边界限制直接冲突 → 系统只能打破其中一条并打日志。
    /// 把右侧留白减去同一个内缩值，可用宽度就回到原值，上面两件事都不会发生。
    ///
    /// ## 为什么不写死 4x pt
    /// 内缩宽度由系统的勾选控件决定（机型 / iOS 版本 / 辅助功能都可能不同），
    /// 所以直接读 `contentView.frame.minX` 实测值 —— 用了它，正常态（= 0）也自动对得上。
    ///
    /// ⚠️ 运行在 `layoutSubviews` 里：`update` 会触发下一轮布局，靠 `appliedBubbleRightMargin`
    /// 这个门禁保证「同一个值只写一次」，否则会来回摆（值稳定后必然提前 return）。
    private func applyEditInsetCompensation() {
        // 只在左侧内缩才是编辑态；正常态的 contentView 与 cell 同宽（minX == 0）
        let inset = contentView.frame.minX
        // 下限 12：极端情况下（超大字号 / 加大触控区）内缩可能把留白吃成负数，
        // 留一点余量，宁可气泡窄一点也别让它顶出屏幕
        let margin = max(12, Self.bubbleRightMargin - inset)
        guard margin != appliedBubbleRightMargin else { return }
        appliedBubbleRightMargin = margin
        bubbleRight?.update(offset: -margin)
    }

    public override func prepareForReuse() {
        super.prepareForReuse()
        // 选择态的 gate 必须复位：复用后这一行已经不是当初被长按的那条
        //（`drainContent` 会把每个回收的 textView 都 `endSelection()`）
        drainContent()
        // 钉宽是**一次性**的：复用后不许把上一条的「钉住/交还」状态带过来
        setBubbleWidthPin(nil)
        applyActionBar(visible: false)
        applyMeta(nil)
        // 三点是**一次性**的：复用后不带过来（与上面「黄底」同一类坑）
        setTyping(false)
        // 思考块同理：收起 + 偏移归 0（不这么做的话，复用到一条无思考的行上时，
        // 上一行的思考内容会残留，且 top 偏移留着 10 ⇒ 正文凭空低一截）
        thinkingView.configure(reasoning: nil, expanded: false, streaming: false)
        thinkingViewTop?.update(offset: 0)
        // 定位高亮是**一次性**的：cell 复用后不该把上一行的黄底带过来
        contentView.backgroundColor = .clear
    }

    // MARK: - 分段内容

    /// 单段纯文本（流式态 / 失败提示）。
    ///
    /// 刻意也走 `contentStack`（而不是另留一条「直接铺在 bubble 上」的老路）：
    /// 竖直留白只有一份来源，否则「流式 → 终态」的切换瞬间会跳一下高度。
    private func applyPlainText(_ text: String, font: UIFont, color: UIColor) {
        // 纯文本态（流式 / 失败提示）没有公式段 ⇒ 抹掉「终态源文」，
        // 否则明暗切换时 `traitCollectionDidChange` 会拿上一轮的旧 markdown 重排一次。
        currentMarkdown = nil
        let attributed = NSAttributedString(string: text,
                                            attributes: [.font: font, .foregroundColor: color])
        // 流式态的内容永远是「一个纯文本段」：视图结构与约束从头到尾不变，每秒 33 帧里
        // 绝大多数只是在换那一串字。`drainContent() + addArrangedSubview` 会把整棵 stack
        // 摘空再装回去（每一步都让布局失效），对这种情况纯属白跑 —— 直接换文本即可。
        //
        // ⚠️ 字号与颜色都在 `attributed` 里自带，所以「流式(正文) → 失败提示(警示色)」
        //    这条切换即使走快路径也是对的：它换的正是这份富文本本身。
        if isPlainTextLayout, contentStack.arrangedSubviews.count == 1,
           let textView = activeTextViews.first {
            // ⚠️ 选择态必须跟着收掉：旧实现每帧都走 `drainContent()`，而它会给每个回收的
            //    textView 调 `endSelection()` —— 所以流式期间的选择态本来就活不过一帧。
            //    走快路径绕过了 drain，这一条得自己补上，否则「在流式中的回复上点了选取文字」
            //    会一直卡住这一行的触摸（`BubbleTextView.point(inside:)` 在选择态下会吃掉一切）。
            //    `endSelection` 内部有 `isSelectionArmed` 门禁，没进选择态时只是一次布尔判断。
            textView.endSelection()
            textView.attributedText = attributed
            return
        }
        drainContent()
        let textView = dequeueTextView()
        activeTextViews = [textView]
        contentStack.addArrangedSubview(textView)
        textView.attributedText = attributed
        isPlainTextLayout = true
    }

    /// 终态：按 Markdown 分段渲染
    private func applySegments(_ markdown: String) {
        drainContent()
        // 记下来：明暗切换时要按新墨色重渲公式（位图不跟语义色走）
        currentMarkdown = markdown
        // 公式墨色：**先按当前 trait 解析成具体色**，再交给排版库。
        // ⛔ 别直接传 `.label`（动态色）—— 它会在 `UIGraphicsImageRenderer` 绘制那一刻才解析，
        //    那时与 `traitCollection` 已经脱钩，深色模式下可能画出一张**黑图**。
        let mathInkKey = traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
        let mathInk = UIColor.label.resolvedColor(with: traitCollection)
        var hasCode = false
        for segment in AIMarkdown.segments(from: markdown) {
            switch segment {
            case .text(let attributed):
                let textView = dequeueTextView()
                // 🔴 网址在这里补成**看得见（蓝）+ 点得动**的链接（2026-10-02 用户需求：
                //    「会话返回 网页地址 显示蓝色，点击网页地址 push 进入 web 页面」）。
                //    逻辑在共享层 `AILinkify`（mac 端同一份），颜色由本端给
                //    —— iOS 用系统链接色（`UIColor.link`，明暗两档自带）。
                //    ⚠️ 只加 `.link` 与 `.foregroundColor`，不动字体 / 段落样式 ⇒
                //       行高量算（`AIMarkdown.contentHeight` 读同一份富文本）逐像素不变。
                //
                // 🔴 行内公式的图**必须在这里换**：业务层塞的是**透明占位图**
                //    （它只负责把行高撑到正确尺寸，见 `AIPlatformMath.placeholder`），
                //    真图要按当前明暗档的墨色现渲 —— 业务层不知道主题色。
                let inked = applyInlineMathInk(attributed, inkKey: mathInkKey, ink: mathInk)
                textView.attributedText = AILinkify.apply(to: inked, linkColor: Self.linkColor)
                activeTextViews.append(textView)
                contentStack.addArrangedSubview(textView)
            case .code(let code, let language):
                hasCode = true
                let codeView = dequeueCodeView()
                codeView.configure(code: code, language: language)
                contentStack.addArrangedSubview(codeView)
            case .math(let latex):
                // 公式：业务层渲一张图，这里只管铺（尺寸也由业务层给，与量高同源）
                if let result = AIMathBlockMetrics.image(for: latex,
                                                         width: Self.fullTextWidth,
                                                         inkKey: mathInkKey,
                                                         color: mathInk) {
                    let mathView = dequeueMathView()
                    mathView.configure(image: result.image, displaySize: result.displaySize)
                    contentStack.addArrangedSubview(mathView)
                } else {
                    // 排不出（LaTeX 语法错 / 只有空白）⇒ **降级显示源码**，别让这块凭空消失。
                    // ⚠️ 高度与 `AIMathBlockMetrics.height` 用的是同一份 `fallbackTextAttributes`
                    //    ⇒ 降级后行高仍对得上，不会裁字或多出空白。
                    let textView = dequeueTextView()
                    let fallback = NSMutableAttributedString(
                        attributedString: AIMathBlockMetrics.fallbackText(for: latex))
                    fallback.addAttribute(.foregroundColor,
                                          value: UIColor.secondaryLabel,
                                          range: NSRange(location: 0, length: fallback.length))
                    textView.attributedText = fallback
                    activeTextViews.append(textView)
                    contentStack.addArrangedSubview(textView)
                }
            }
        }
        // 含代码块 → 钉宽。理由见 `bubbleWidthPin` 的声明处。
        // ⚠️ 公式**不钉宽**：短公式该让气泡缩到公式宽（与正文一样由内容撑出来）；
        //    超宽的那部分已经在 `AIMathBlockMetrics.displaySize` 里按 `fullTextWidth` 缩过，
        //    不会撑破气泡。
        setBubbleWidthPin(hasCode ? Self.fullBubbleWidth : nil)
    }

    /// 把正文里的**行内公式**换成当前墨色的真图。
    ///
    /// 业务层（`AIMarkdown.attachInlineMath`）塞进富文本的是**透明占位图** ——
    /// 它只负责让 `boundingRect` 把行高撑到正确尺寸（无图的 attachment 完全不参与行高，
    /// 实测见 `AIPlatformMath.placeholder` 的注释）。真图必须由视图层按主题墨色现渲。
    ///
    /// ⚠️ **每次都新建 attachment，⛔ 别去改原对象**：富文本来自 `AIMarkdown.segments`
    ///    的共享缓存，同一个公式可能同时被浅色 cell 与深色 cell 持有 ——
    ///    原地改 `image` 会让先渲染的那个跟着变色（表现为「滚过去的那些公式颜色乱了」）。
    /// ⚠️ `baselineOffset` 直接沿用业务层算好的 `bounds.origin.y`，⛔ 别在这里另算一遍。
    private func applyInlineMathInk(_ attributed: NSAttributedString,
                                    inkKey: String,
                                    ink: UIColor) -> NSAttributedString {
        var hits: [(range: NSRange, math: AIMathAttachment)] = []
        attributed.enumerateAttribute(.attachment,
                                      in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if let math = value as? AIMathAttachment { hits.append((range, math)) }
        }
        guard !hits.isEmpty else { return attributed }
        let mutable = NSMutableAttributedString(attributedString: attributed)
        // 从后往前换：长度虽然不变（1 个附件字符换 1 个），但位置仍按原序更稳
        for hit in hits.reversed() {
            guard let image = AIMathBlockMetrics.inlineImage(latex: hit.math.latex,
                                                            inkKey: inkKey,
                                                            color: ink) else { continue }
            let replacement = AIMathAttachment.make(
                latex: hit.math.latex,
                image: image,
                displaySize: hit.math.displaySize,
                baselineOffset: hit.math.bounds.origin.y)
            mutable.replaceCharacters(in: hit.range, with: replacement.attributed)
        }
        return mutable
    }

    /// 正文里网址的颜色：**系统链接色**（明暗各一档，跟着外观走）。
    ///
    /// ⚠️ 只有这一处取色（`AILinkify` 拿它当参数、textView 的 `linkTextAttributes` 也用它）——
    ///    两处各写一个色值，迟早会出现「补的那条是浅蓝、系统画的是深蓝」。
    private static var linkColor: UIColor { .link }

    /// 把 `contentStack` 上的分段视图全部收回池里。
    ///
    /// ⚠️ 必须**两步都做**：只 `removeArrangedSubview` 的话视图仍留在视图树上
    ///（`UIStackView` 的文档明确要求再 `removeFromSuperview`），下一次 add 会撞车。
    private func drainContent() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
            switch view {
            case let textView as BubbleTextView:
                textView.attributedText = nil
                // 选择态是一次性的，别带回池里（回到屏上会变成「上一行的选中范围」）
                textView.endSelection()
                textViewPool.append(textView)
            case let codeView as AICodeBlockView:
                codeViewPool.append(codeView)
            case let mathView as AIMathBlockView:
                // 尺寸必须归零再回池：不归零的话，下一次 configure 之前它会先按
                // **上一条公式的尺寸**撑一下子高度（复用坑，与三点宽度同类）
                mathView.prepareForReuse()
                mathViewPool.append(mathView)
            default:
                break
            }
        }
        activeTextViews.removeAll()
        // 视图树已清空 → 「当前是单段纯文本」这个前提不再成立。
        // 复位放在这里最稳：`applySegments` / `applyPlainText` / `prepareForReuse`
        // 三条路径都经过它（漏掉的话下一次流式会往一个多段 stack 上「只换文本」）
        isPlainTextLayout = false
    }

    /// 取一个正文 textView（池里有就复用）。
    ///
    /// ⚠️ 上下 `textContainerInset` **归 0**：竖直留白统一由 `contentStack`
    /// （`AIMarkdown.contentPaddingV`）承担。两边都留的话，「文本段 + 代码段」之间会多出
    /// 一份重复的 10pt，而 `AIMarkdown.contentHeight` 只算一份 → 量出来比实际矮 → 裁字。
    private func dequeueTextView() -> BubbleTextView {
        if let pooled = textViewPool.popLast() { return pooled }
        let textView = BubbleTextView()
        // ⚠️ `isEditable = false` + `isSelectable = true` = **能选、不能改**。
        // 从前这里是 `isSelectable = false` + `isUserInteractionEnabled = false`（纯展示），
        // 代价是「没法只选一句话」。但「能选」不等于「一直吃触摸」：直接打开交互会让 textView
        // 把单击/长按全吃掉，宿主的「轻点弹操作卡」「长按弹操作卡」当场失效。
        // 真正的分流在 `BubbleTextView` 的 `point(inside:)`（未进入选择态时不参与命中测试）
        // —— 这里只是把能力打开。
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = true
        // 🔴 链接色**钉一次**（2026-10-02）：`UITextView` 自己会给 `.link` run 上色
        //    （默认取 tintColor —— 那可能是主题色、不一定是蓝）⇒ 显式写死成系统链接色，
        //    与 `AILinkify` 补进富文本里的颜色是**同一个值**（`Self.linkColor`）。
        //    ⚠️ 这里**只给颜色**：不加下划线（用户只要「蓝色」，下划线是 mac 那边 hover 才有的反馈）。
        textView.linkTextAttributes = [.foregroundColor: Self.linkColor]
        // 失焦（点了别处 / 菜单收起）时把选择态的 gate 关回去，别让它卡住
        textView.delegate = self
        // 字号/颜色统一取 AITypography（与用户气泡、Markdown 终态、行高量算同一份值）
        textView.font = AITypography.body
        textView.textColor = AITypography.bodyColor
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 0, left: Self.textInsetH,
                                                   bottom: 0, right: Self.textInsetH)
        textView.textContainer.lineFragmentPadding = 0
        return textView
    }

    /// 取一个代码卡片（池里有就复用）
    private func dequeueCodeView() -> AICodeBlockView {
        let codeView = codeViewPool.popLast() ?? AICodeBlockView()
        // 每次都重挂闭包：转发的是**字符串**（不带行号），所以 cell 复用不会张冠李戴
        codeView.onCopy = { [weak self] code in
            guard let self else { return }
            self.onCopyCode?(code)
        }
        return codeView
    }

    /// 取一个公式块（池里有就复用）。
    ///
    /// 与代码卡片不同，公式**没有闭包要转发**（它不可点、不可复制）——
    /// 「复制公式源码」走的是长按操作卡里的「复制」，复制的是整条回复的源文。
    private func dequeueMathView() -> AIMathBlockView {
        mathViewPool.popLast() ?? AIMathBlockView()
    }

    // MARK: - 私有

    /// 显示/收起操作栏。
    /// 高度与 `AIChatRow.actionBarHeight` 同源——两处不一致会挤变形或裁切。
    ///
    /// 收起时顺手复位「朗读中」图标：`configureStreaming` / `configureNotice` /
    /// `prepareForReuse` 都只调到这里，集中复位才不会漏
    /// （cell 复用后残留播放态图标会让人以为还在读）。
    private func applyActionBar(visible: Bool) {
        // 「朗读中」图标的复位**不能**跟着下面的门禁走：`prepareForReuse` 也调到这里，
        // 门禁若把它挡掉，上一行残留的播放态图标就会被带到新行上
        //（本工程「定位黄底」犯过同一类错）
        if !visible { actionBar.setSpeaking(false) }
        // 值没变就不动约束：`update(offset:)` 即使值相同也会重新激活约束并触发布局，
        // 而流式期间这里每秒被调 33 次
        guard visible != appliedActionBarVisible else { return }
        appliedActionBarVisible = visible
        actionBarHeight?.update(offset: visible ? AIChatRow.actionBarHeight : 0)
        actionBar.isHidden = !visible
    }

    /// 显示/隐藏「时间」小字行，并把气泡顶边让出对应高度。
    /// 让位的距离**必须**取 `AIChatRow.metaHeight` —— 行高量算用的是同一个值（见该常量的说明）。
    private func applyMeta(_ text: String?) {
        let text = (text?.isEmpty ?? true) ? nil : text
        let hidden = (text == nil)
        // 一整轮流式里 `metaText` 是不变的（时间按「上一条消息」算，与本次回复的内容无关），
        // 而这里每秒被调 33 次 —— 没有门禁就是每帧一次 label 赋值 + 一次约束更新。
        // ⚠️ 文案与 `isHidden` 要一起判：`isHidden` 也参与布局，只看文案会漏掉让位
        guard metaLabel.text != text || metaLabel.isHidden != hidden else { return }
        metaLabel.text = text
        metaLabel.isHidden = hidden
        bubbleTop?.update(offset: 6 + (hidden ? 0 : AIChatRow.metaHeight))
    }

    /// 显示/收起「首字未到」的三点等待指示。
    ///
    /// 只在 `configureStreaming` 且 `text.isEmpty` 时为真。另外三个入口
    /// （`configureFinal` / `configureNotice` / `prepareForReuse`）都显式收起它 ——
    /// 一次性状态必须每个入口都覆盖，靠自觉一定会漏（本工程「黄底」已经漏过一次）。
    ///
    /// ⚠️ 本方法在流式期间**每秒被调约 33 次**（`revealInterval 0.03` 一个 tick），
    /// 所以每一步都必须幂等：这里用 `isTypingShown` 直接短路，
    /// 动画那层还有 `AITypingIndicatorView.setAnimating(_:)` 自己的守卫。
    ///
    /// 行高**不用动**：`AIChatRow.height(in:)` 对空文本走 `max(textH, font.lineHeight)`，
    /// 已经兜了一行高，三点复用这一行 —— 不动行高公式就不会犯「量高与布局不同源」的老毛病。
    private func setTyping(_ on: Bool) {
        guard on != isTypingShown else { return }
        isTypingShown = on
        typingView.isHidden = !on
        // ⚠️ 钉宽**不在这里**：气泡宽度只由 `setBubbleWidthPin(_:)` 一个入口决定。
        // 「三点要不要钉宽」是调用方（`configureStreaming`）的语义，不是指示器自己的事 ——
        // 两处都写就退化成「谁最后调用谁生效」，而这正是这次返工的起因。
        typingView.setAnimating(on)
    }

    /// 气泡「钉宽」的**唯一**入口。
    ///
    /// - `nil`：撤销钉宽，宽度交还给正文内容撑（流式正文 / 无代码块的终态 / 失败提示 / 复用）
    /// - 有值：把气泡钉到该宽度（三点 `typingWidth`；含代码块 `fullBubbleWidth`）
    ///
    /// ⚠️ 门禁用**已生效的宽度值**而不是一个布尔：转屏后 `UIScreen.main.bounds.width` 会变，
    /// 而含代码块的 cell 未必重建 —— 只看布尔会以为「已经钉过了」，继续用旧常量，
    /// 于是折行位置与行高预测对不上（表现是最后一行被裁）。
    /// ⚠️ 流式期间每秒被调约 33 次：**同值必须提前 return**，`update(offset:)` 即使值没变
    /// 也会重新激活约束并当场触发布局。
    private func setBubbleWidthPin(_ width: CGFloat?) {
        guard let width else {
            guard appliedBubbleWidthPin != -1 else { return }
            appliedBubbleWidthPin = -1
            bubbleWidthPin?.isActive = false
            return
        }
        guard appliedBubbleWidthPin != width else { return }
        appliedBubbleWidthPin = width
        bubbleWidthPin?.update(offset: width)
        bubbleWidthPin?.isActive = true
    }

    /// 正文左右内边距（12）。`typingInset` 取同一个值 —— 三点要与正文左对齐。
    private static let textInsetH: CGFloat = 12
    /// 三点指示的左内边距（与正文的左右 inset 同值 —— 视觉上与正文对齐）
    private static let typingInset: CGFloat = textInsetH
    /// 三点显示时气泡的宽度：左右 inset + 三点自身宽（12 + 26 + 12 = 50）
    private static let typingWidth = typingInset * 2 + AITypingIndicatorView.intrinsicSize.width
    /// 含代码块时气泡钉的宽度：0.8×屏宽（与 `AIChatRow.height(in:)` 的折行预测同一口径）。
    /// ⚠️ 写成计算属性、每次都现取屏宽：转屏后 cell 未必重建，用初始化那一刻的旧值会让折行与行高对不上。
    private static var fullBubbleWidth: CGFloat { UIScreen.main.bounds.width * 0.8 }

    /// 气泡**正文**可用宽 = 0.8×屏宽 − 左右 inset（12+12）。
    ///
    /// 🔴 公式的缩放上限必须用它，且必须与 `AIChatRow.height(in:)` 里的 `maxTextW`
    ///    （`width * 0.8 - 24`）同源 —— 视图按一个宽缩、量高按另一个宽算，
    ///    结果就是「图缩了但行高没缩」，公式下方空出一截。
    private static var fullTextWidth: CGFloat { fullBubbleWidth - textInsetH * 2 }

    /// 小字字号：12pt。比正文（16）小两级、比系统 caption 稍大一档 ——
    /// 它是「元信息」，要能看清但不该和正文抢注意力。
    private static let metaFont = UIFont.systemFont(ofSize: 12)
}

// MARK: - 正文选中（操作卡里的「选取文字」调用）

extension AIAssistantTextCell: AIBubbleTextSelecting {

    /// 进入选择态，选中 `point`（**cell 坐标系**）所在**那一段**文本里的那一行；
    /// 拿不到锚点（或锚点落在文本段之外，比如按在代码卡上）时选第一段。
    ///
    /// **空正文（如流式起始的空占位）返回 false** —— 对空文本做选中是没有任何反馈的死操作，
    /// 宿主会据此给一句 toast。
    func beginTextSelection(at point: CGPoint?) -> Bool {
        let candidates = activeTextViews.filter { !($0.text ?? "").isEmpty }
        guard !candidates.isEmpty else { return false }
        // 点在哪一段就选哪一段：段是**多个** textView，先做一次命中分流，
        // 否则锚点会被当成第一段的坐标用（长按第三段却从第一段算起，选中范围全错）
        let target = candidates.first { textView in
            guard let point = point else { return false }
            return textView.bounds.contains(textView.convert(point, from: self))
        } ?? candidates[0]
        // cell 坐标 → textView 坐标（接收者是 textView，from 传 cell 自己）
        return target.beginSelection(at: point.map { target.convert($0, from: self) })
    }

    func endTextSelection() {
        for textView in activeTextViews { textView.endSelection() }
        // 池里的也收：它们下一刻可能被复用，带着选择态回到屏上就是「上一行的选中范围」
        for textView in textViewPool { textView.endSelection() }
    }
}

// MARK: - UITextViewDelegate（选择态收尾 + 点链接）

extension AIAssistantTextCell: UITextViewDelegate {

    /// 失焦 = 用户点了别处或系统收起了编辑菜单 → 把 gate 关回去，
    /// 否则这一行会保持「触摸被 textView 吃掉」的状态，之后点它再也弹不出操作卡。
    public func textViewDidEndEditing(_ textView: UITextView) {
        (textView as? BubbleTextView)?.endSelection()
    }

    /// 点中网址（iOS **16 及以前**走这条；17 起走下面的 `primaryActionFor`）。
    ///
    /// 返回 `false` 是关键：它同时表达两件事 ——「我处理了」+「别让系统再开一次」
    /// （返回 true 会让 `UIKit` 用系统浏览器打开，用户就被踢出 App 了）。
    ///
    /// ⚠️ 只有**轻点**（`.invokeDefaultAction`）才算「我要打开」；长按预览 / 弹菜单那两种
    ///    交互一律回 false（本页不提供链接预览，长按在气泡上另有用途）。
    public func textView(_ textView: UITextView,
                         shouldInteractWith URL: URL,
                         in characterRange: NSRange,
                         interaction: UITextItemInteraction) -> Bool {
        guard interaction == .invokeDefaultAction else { return false }
        onOpenURL?(URL)
        return false
    }

    /// 点中网址（**iOS 17 起**走这条 —— 上面那条已被系统弃用）。
    ///
    /// `defaultAction` 是系统的默认行为（用系统浏览器打开）；我们换成「交给宿主 push 内置网页页」。
    /// ⚠️ 这条与上面那条**同时实现**是刻意的：系统只在实现了新 API 时才改走新路，
    ///    只实现旧的在 17+ 上能不能被调到并无保证 ⇒ 两条都在，哪个系统用哪条由系统自己挑。
    @available(iOS 17.0, *)
    public func textView(_ textView: UITextView,
                         primaryActionFor textItem: UITextItem,
                         defaultAction: UIAction) -> UIAction? {
        guard case .link(let url) = textItem.content else { return defaultAction }
        return UIAction { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onOpenURL?(url)
            }
        }
    }
}

// MARK: - AIChatContentBlockProviding

/// 内容块 = 文本行：气泡（长按照到这里才弹操作卡，气泡外的留白不响应）。
///
/// ⚠️ 实现必须留在本文件：`bubble` 是 `private let`，而 `private` 是**文件级**
/// 作用域 —— 挪到协议所在文件会 `inaccessible due to 'private' protection level`。
extension AIAssistantTextCell: AIChatContentBlockProviding {
    var contentBlockView: UIView? { bubble }
}

// MARK: - AIChatSelectionTouchYielding

extension AIAssistantTextCell: AIChatSelectionTouchYielding {

    /// 选择模式（多选删除）下关掉气泡下方那条操作栏。
    ///
    /// 操作栏里四颗都是 `UIControl`（按钮），**UIControl 会把触摸整个吃掉** →
    /// 表格收不到这一拍 → 这一行永远勾不上（其它行的正文对触摸透明，本来就会落到勾选机制里）。
    /// 顺带也避免了「一边勾选一边点出重新生成」这种互相打架的操作。
    func setSelectionMode(_ on: Bool) {
        actionBar.isUserInteractionEnabled = !on
        // 🔴 正文里的网址也一样：多选模式下「点哪儿都是勾选」，此时点中网址跳出网页页很突兀，
        //    而且那一拍会被 textView 吃掉 ⇒ 压在网址上就**勾不上这一行**。
        //    ⚠️ 与操作栏同一套：屏上 cell 不走 `willDisplay`，所以宿主 `exitSelectionMode`
        //       里还要遍历可见 cell 调一次（见该处注释）。
        for textView in activeTextViews { textView.isLinkTapEnabled = !on }
        for textView in textViewPool { textView.isLinkTapEnabled = !on }
        // 代码卡片里那颗「复制」也是 `UIControl`，同样会吃掉那一拍（点卡片右上角就勾不上）。
        // 卡片是**动态取出**挂在 stack 上的（池里复用），所以按当前内容遍历，而不是存一份引用；
        // 卡片正文本身是普通 `UIView`（不吃触摸），整张关掉更省事也更彻底。
        // ⚠️ 退出（`on == false`）时这里会一起放开；但屏上 cell 不走 `willDisplay`，
        // 所以宿主 `exitSelectionMode` 里还要遍历可见 cell 调一次（见该处注释）。
        for view in contentStack.arrangedSubviews where view is AICodeBlockView {
            view.isUserInteractionEnabled = !on
        }
    }
}

// MARK: - 🧪 探针自检（#if DEBUG）

extension AIAssistantTextCell {
    /// 思考块 chevron 的挂载态（转发给 `AIThinkingBlockView.probeChevronIsMounted`，
    /// 供 SceneDelegate 的思考展示探针数数 —— 2026-10-21 崩溃修复的回归守门）。
    #if DEBUG
    var probeThinkingChevronMounted: Bool { thinkingView.probeChevronIsMounted }
    #endif
}
