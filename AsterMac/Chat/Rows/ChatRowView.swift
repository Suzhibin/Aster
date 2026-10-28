//
//  ChatRowView.swift
//  AsterMac
//
//  一行消息（= 一个内容块）的渲染。
//  内容模型与配色口径都取自业务层与 `MacTheme`，这里只决定「怎么摆」。
//
//  ## 🔴 只有用户气泡有底（2026-09-21 改）
//  - **用户消息**：强调色圆角气泡 + 固定白字，贴右 —— 那是「我说的话」，需要一个实体。
//  - **AI 消息**：**不画任何底**，背景就是页面背景（`MacTheme.pageBackground`），贴左。
//    这样正文与页面是同一块面，读起来是「文档」而不是「一堆灰盒子」。
//    ⚠️ 去掉底之后文字不能再用固定色 —— 见 `MacTheme` 文件头（暗黑模式）。
//  - 例外：代码卡片 / 附件卡片 / 图片是**内容容器**（不是气泡），仍然有面 ——
//    它们本来就需要从页面底上浮出来才看得清边界。
//
//  ## 底部操作栏（2026-09-21 起，2026-09-24 加用户侧）
//  - **助手侧**：文本 / 失败消息在**正文下方**挂一排图标按钮（复制 / 朗读 / 重试 / 分享，
//    末尾带这条消息的时间；见 `ChatRowActionBar`）—— **每条都挂、常驻可见**。
//  - **用户侧**（2026-09-24 用户要求）：**每条用户文本行都占位**，但默认**看不见**，
//    鼠标移到这条消息上才淡入（时间 / 编辑 / 复制 / ⋯；见 `ChatRowUserActionBar`）。
//    用「占位 + 透明度」而**不是**「悬停才长出来」—— 理由是硬的（31pt > 贴底容差 30pt），
//    写在 `ChatRowUserActionBar` 文件头第 ② 条，改之前务必先读。
//  判据都在下面的 `showsActionBar` / `reservesUserBar` —— **不读** `row.showsActionBar`：
//  那个标志是给 iOS 的「只有最后一条挂栏」用的，Mac 两边都不采信。
//
//  ## 🔴 文件消息：末尾那颗分享按钮（2026-10-06 用户要求）
//  原话「Mac端 文件消息 的末尾 增加一个分享按钮 平时隐藏，鼠标移动到文件消息上 显示」。
//  - **位置 = 附件卡片内部、文件名右侧**（`fileBlock` 的 `Spacer` 之后）—— ⛔ 不是在卡片
//    **下方**另起一栏：那会凭空给每条文件消息加一行高度，而用户要的是「卡片末尾」。
//    这也是全 App 既有的长相：会话行 hover 才显的「…」就在**行尾**
//    （`ConversationSidebar` 的 `moreButton`），同一个「行尾 + 悬停才出」的语汇。
//  - 🔴 **必须恒占位**（一直留在布局里，只改 `opacity` / `allowsHitTesting`）：
//    卡片的**宽度**本身不会变（`Spacer(minLength: 0)` 把它撑满、再被 `.frame(maxWidth: 320)`
//    夹住 ⇒ 恒为 `min(容器宽, 320)`），但**文件名拿到的可用宽度**会少 34pt ⇒
//    长文件名的**截断点**会在鼠标移进移出时来回跳。判据见 `fileShareButton` 那段注释。
//  - 它的显隐**跟着这一行的 hover 态走**，与用户侧那条栏共用同一个判据
//    （`tracksHover` / `revealsHoverControls`）—— ⛔ 别在 `onHover` 里再写一串 `||`。
//
//  ## 就地编辑（2026-09-24）
//  用户消息点「编辑」→ 气泡**就地**变成输入框，下方那一行换成「取消 / 保存」；
//  保存 = 从这条起重新生成（业务层 `editAndResend` 会截断这条之后的所有行）。
//  🔴 **只有正文变了才改行高**：那一行按钮是占位常驻的，两种状态共用同一个高度 ——
//  所以进出编辑态，列表里动的只有「气泡 ⇄ 编辑器」这一处，不会有第二处抖动。
//
//  ## 行宽的两个层次（别把它们混成一件事）
//  - `bubbleMaxWidth`：气泡**自身**的上限（0.8 × 容器宽，与 iOS 行高量算同口径）。
//    用「两层 frame」实现：内层 frame 只负责把提议宽度夹到上限（`Text` 因此在这里折行、
//    背景因此贴住内容），外层 frame 才把这一行撑满、把气泡推到对应的边。
//    若只写一层 `frame(maxWidth: .infinity)`，气泡会被拉满整行 —— 变成一堵墙。
//  - 媒体（图片/文件）：尺寸由业务层算（`AIChatRow.userImageDisplaySize`），
//    保证与 iOS 侧同一套比例；Mac 自己再算一次迟早漂移。
//
//  ## 🔴 AI 回复里的媒体 = **一条横向滚动的缩略图条**（2026-09-28 用户要求）
//
//  用户：「图片和视频可能会多个 ⇒ 图片应在一个 cell 横向多个显示」。
//  - 本视图**「一行一块」的语义没变**：把「连续的助手媒体行合成一条」那一步在
//    `ChatDetailView`（`ChatTranscriptItem.group` 投影），格子口径在 `MediaThumbStrip`；
//  - 尺寸口径 = **统一 16:9 裁切 + 固定高度**（单张也跟组内一样大，用户选定）。
//    旧的「用户侧按真实比例 / 助手侧 0.62×容器宽」那套**只留给用户侧图片**；
//  - ⚠️ 行高因此从「跟随容器宽」变成常量（`MacTheme.mediaThumbHeight`）：
//    验收图 `media_940` / `media_420` 上媒体行的高度会与 2026-09-27 那版不同，**不是回归**。
//  - ⛔ 别顺手把用户侧图片也换成缩略图条 —— 用户明确「只改 AI 回复侧」。
//
//  ## 🔴 媒体图**不许**在 `body` 里同步取（2026-09-27 修）
//  图片与视频封面一律走 `RowMediaImage`（异步 + 降采样 + 缓存），
//  ⛔ **别退回 `NSImage(contentsOf: url)`** —— 它是**同步**的，且对 http(s) 会**真的去下载**。
//  写在 `body` 里就是「每次求值都在主线程上取一遍图」：实测 72ms/次（视频封面 400ms/次），
//  再叠上「每次都全解位图」，结果就是**上下滑动卡顿 + 中间一片空白**（看着像数据被吞了）。
//  成因、实测数字与三条口径都在 `RowMediaImage.swift` 文件头。
//
//  ## 🔴 点媒体 → **另开一个窗口**预览（2026-09-27 加；当天改过一次形态）
//  图片块与视频块各自挂 `onTapGesture` → 回调 `onOpenMedia` → `MediaPreviewWindowCenter`
//  开一个独立窗口（样式照用户给的豆包 Mac 版截图；窗户纸那一层在 `MediaPreviewWindow.swift`）。
//  ⚠️ 第一版是**页内整页浮层**，用户看过之后要求改成**新开窗口** ——
//    行这一侧**一行没改**，因为行从来只负责「报告点了谁、长什么样」，弹在哪由宿主决定。
//  - 视频**整块可点**，不只 play 图标那一圈（图标只有 34pt，是「这里能播」的提示，不是命中区）；
//  - ⛔ **两种状态的行高必须不变**：挂 `contentShape` / `onTapGesture` / `help` 都不参与布局，
//    所以「能不能点」这件事一行高度都不该动（这条有渲染图 `media_940` 兜着）；
//  - 文案取 `AIRowAction` 那一套吗？**不取** —— 那是「对消息能做的操作」（操作栏/右键菜单共用），
//    而「点开看大图」是媒体块自己的天然手势，不是菜单项。所以这里用 `.help` 里的一句短语。
//

import SwiftUI
import AppKit
import AICore

struct ChatRowView: View {
    let row: AIChatRow
    /// 容器宽度（滚动区实际宽度，由 `ChatDetailView` 的 GeometryReader 传入）
    let containerWidth: CGFloat

    /// **全局**是否正在收流（`ChatModel.isStreaming`）。只用来置灰会打断流的动作 —— 见 `actionBar`。
    let isStreaming: Bool
    /// 这一行正在朗读（`ChatModel.speakingRowId == row.id`）
    let isSpeaking: Bool
    /// 「重试」在这一行是否可用（用户行后面还没有助手回复时为 false，按钮置灰）
    let canRetry: Bool

    /// 指针是否停在这一行上（`ChatDetailView` 的 `hoveredRowId`）。
    ///
    /// **只影响「hover 才显」的东西**，现在有两处：用户侧那一栏操作栏、
    /// **文件卡片末尾那颗分享**。两处的显隐判据都收在 `revealsHoverControls`（单点）。
    let isHovered: Bool
    /// 这一行是否正在**就地编辑**（`ChatModel.editingRowId`）
    let isEditing: Bool
    /// 就地编辑器里的文字（绑 `ChatModel.editingText`，**不是** `draft`）
    @Binding var editingText: String

    let onCopy: () -> Void
    let onSpeak: () -> Void
    let onRetry: () -> Void
    let onContinue: () -> Void
    /// 「删除」：**不直接删**，而是请宿主把列表切进「多选删除」选择模式，并默认勾上这一轮
    /// （`ChatModel.enterSelectionMode(startingAt:)`）。
    ///
    /// 🔴 名字 2026-09-29 从 `onDeleteTurn` 改成 `onRequestDelete` —— **它表达的语义变了**：
    ///    上一版点下去当场删整轮，现在它只是一个「请求删除」，删哪几条由用户在选择模式里定。
    ///    名字不改的话，下一个读代码的人会以为点下去就删了。
    /// ℹ️ 现在有**四个**入口都走它：本视图的右键菜单、助手文本栏的「⋯」、助手媒体栏的「⋯」、
    ///    以及**用户侧栏的「⋯」**（2026-09-29 加）。
    /// ⚠️ 与 `onQuote` 一样**必填**（不给默认值）：点下去必须有落点，
    ///    多一个 `nil` 就多一处「点了没反应」的可能。
    let onRequestDelete: () -> Void
    /// 「⋯ → 引用」：把这一条的内容挂到输入框上方（`ChatModel.beginQuote(rowId:)`）。
    /// **两侧的「⋯」都用它** —— 助手侧引的是这条回复，用户侧引的是我自己发的那句话
    /// （同一个回调，模型层按 `rowId` 自己取正文，不关心 role）。
    /// ⚠️ 与 `onRequestDelete` 一样**必填**（不给默认值）：点下去必须有落点，
    ///    多一个 `nil` 就多一处「点了没反应」的可能。
    let onQuote: () -> Void

    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    /// 指针进出的回调（`ChatDetailView` 据此维护 `hoveredRowId`）。
    ///
    /// 为什么要回调出去、而不是在本视图里用一个 `@State`：`ForEach` 的 id 是**行下标**
    /// （`id: \.offset`），行一插一删下标就重排 —— 行内的 `@State` 会跟着下标走错行。
    /// 放在宿主里按 `row.id` 记，就没有这个问题（与 `MacSearchView.hoveredIndex` 同款）。
    let onHoverChange: (Bool) -> Void

    /// 点了图片块 / 视频块 → 请宿主**开一个预览窗口**（`MediaPreviewWindowCenter`）。
    ///
    /// ⚠️ 带默认值 `nil`：渲染台那些「只验长相」的板（`rowsBoard` / `mediaBoard`）不必
    /// 为它改一行 —— 但它们也**顺带**失去了「有没有真的接上点击」这条证据（那由
    /// `ChatDetailView` 那处接线兜着）。
    var onOpenMedia: ((MediaPreviewItem) -> Void)? = nil

    /// 点了文件卡片 → 请宿主**在右侧面板里打开这个文件**（2026-10-06）。
    ///
    /// ⚠️ 与 `onOpenMedia` 的**形态刻意不同**：媒体走「另开一个独立窗口」
    ///    （`MediaPreviewWindowCenter`），文件走「会话页右侧那块面板的某个标签」
    ///    （用户 2026-10-06 指定把 `QLPreviewView` 放进面板）。两条路各归各的，
    ///    ⛔ 别为了「统一」把其中一个改掉。
    /// ⚠️ 同样带默认值 `nil`：渲染台那些「只验长相」的板不必为它改一行。
    var onOpenFile: ((URL) -> Void)? = nil

    /// 思考块头部被点（展开 ⇄ 折叠，2026-10-20）→ 宿主转 `ChatModel.toggleThinking(rowId:)`。
    ///
    /// ⚠️ 带默认值 `nil`（同 `onOpenMedia`）：渲染台那些「只验长相」的板不必为它改一行，
    ///    「点击真的接上了」的证据由 `ChatDetailView` 那处接线兜着。
    var onToggleThinking: (() -> Void)? = nil

    /// 点了气泡里那条**引用** → 请宿主把被引用的原消息露出来（2026-10-21，Mac 补上与 iOS
    /// `revealMessage(id:)` 对等的能力）。宿主转 `ChatModel.revealQuotedMessage(_:)`
    /// （内部复用搜索定位那套 `RevealTarget`：滚到那一条 + 圈一下 + 取消贴底跟随）。
    ///
    /// ⚠️ 带默认值 `nil`（同 `onOpenMedia` / `onToggleThinking`）：渲染台那些「只验长相」的板
    /// 不必为它改一行 —— 它们照样画得出「引用条长什么样」，只是再顺带失去「接上了」这条
    /// 证据（那由 `ChatDetailView` 的接线 + 渲染台 `probeQuoteReveal` 逻辑探针兜着）。
    var onRevealQuoted: ((AIQuote) -> Void)? = nil

    /// 是否处于「多选删除」选择模式（`ChatModel.isSelectionMode`）。
    ///
    /// ⚠️ **带默认值放在参数表后段**是刻意的：它在语义上属于上面那组「输入」，
    ///    但插进中间会让渲染台那 9 个 `ChatRowView(...)` 构造点**参数顺序全错**
    ///    （Swift 的 memberwise init 是位置敏感的）—— 一个默认值换 9 处无谓改动。
    /// 它的唯一用途是「选择模式下**不画**操作栏」（见 `body`）：那两栏此刻点不到，
    /// 留着只会让「我在挑消息」的屏幕上挂着一排用不了的按钮。
    var isSelectionMode: Bool = false

    private var isUser: Bool { row.role == .user }
    private var edge: HorizontalAlignment { isUser ? .trailing : .leading }
    private var maxBubbleWidth: CGFloat { max(containerWidth * 0.8, 160) }

    /// 气泡在「最多 80% 宽的那个盒子」内部的贴边方向。
    ///
    /// 🔴 **必须跟随 `edge`，不能写死 `.leading`。**
    /// 内层 `frame(maxWidth:)` 会把盒子撑到 80% 宽，气泡在这盒子里贴哪边由这里的 alignment 决定；
    /// 写死 `.leading` 的结果是：**长消息撑满盒子所以看着没问题，短消息（「你好」）贴在盒子左边**
    /// —— 也就是「发送的文本不在最右侧」。外层 `frame(maxWidth: .infinity)` 只负责把盒子推到右/左，
    /// 两层都得对，缺一层就露馅。
    private var bubbleAlignment: Alignment { isUser ? .trailing : .leading }

    var body: some View {
        let core = VStack(alignment: edge, spacing: 3) {
            // 上方小字行（「与上一条隔了 ≥5 分钟」才报的那次时间）：**只给助手侧画**。
            //
            // 2026-09-26 用户要求「我发送的消息上面的时间显示就不需要了」——
            // 用户侧已经有操作栏里的完整时间（hover 可见），这一行对用户消息是重复的。
            //
            // ⚠️ **只在这里不画，别去动业务层**：`metaText` 仍由 `AIChatManager.applyMetaFlags`
            //    照常算出来 —— iOS 的 `AIChatRow.metaHeightOrZero` 把这一行算进了**行高**
            //    （`AIChatCell` 与 `height(in:)` 两处同源），改业务层会连带改掉 iOS 的界面与行高。
            //    这就是「UI 层分叉、业务层共享」在本仓库的又一次兑现。
            // ✅ 去掉显示**不会**让后面的报时跟着少：`applyMetaFlags` 里的 `previousDate` 是
            //    **逐行推进**的（在 if 之外），那边注释明确写着「时间基准始终是上一条消息，
            //    与该条自己显不显示无关」—— 所以助手侧那一条仍照常按真实间隔判断。
            //
            // ℹ️ 已知取舍：若「隔了很久之后」的第一条恰好是用户消息，那次时间现在只在
            //    hover 操作栏里才看得到（用户明确要这个效果，故不额外补偿）。
            if let meta = row.metaText, !isUser {
                Text(meta)
                    .font(MacTheme.ui(MacTheme.metaFontSize))
                    .foregroundStyle(MacTheme.meta)
            }
            content
            // 🔴 **选择模式下两侧都不画**（2026-09-29）。那两栏此刻点不到
            //   （外面的 `ChatSelectionRow` 关了整块行内容的命中），留着只会让
            //   「我在挑消息」的屏幕上挂着一排复制 / 朗读 / ⋯。
            //   ⚠️ 条件是**两侧共用**的一条 —— 别只给用户侧加：助手侧那条是**常驻**的，
            //      不判的话它会一直亮着（用户侧本来就 hover 才出，看着「像没坏」）。
            if !isSelectionMode {
                if showsActionBar { actionBar }          // 助手侧：常驻
                else if reservesUserBar { userBarSlot }  // 用户侧：**恒占位**，hover 才显（见下）
            }
        }
        // 🔴 `onHover` 必须挂在 `frame(maxWidth: .infinity)` **之前**：
        //    挂之后的话，整条**横贯全宽**的空白带都算在这一行头上 —— 鼠标从列表中间横穿过去，
        //    沿途每一条用户消息都会亮一下操作栏。挂之前，命中区只有 VStack 的固有宽度
        //    （= 气泡与那一行按钮里更宽的那个），指针要真落在消息上才算。
        .onHover { inside in
            // 只有「有 hover 才显的东西」的行需要这个信号；其余行不必为它刷新一次 `@State`。
            // ⚠️ 判据是 `tracksHover`（= 用户侧那条栏 **或** 文件卡片末尾那颗分享）——
            //    两处共用一份，⛔ 别在这里再补一串 `||`：漏掉一半的症状是
            //    「按钮画出来了、鼠标移上去它永远不出现」（hover 信号压根没上报到宿主）。
            // ⚠️ 选择模式下直接忽略：那些东西根本不显（见 `revealsHoverControls`），
            //    上报只会让宿主白刷一次 `@State`。
            //    外层 `ChatSelectionRow` 的 `allowsHitTesting(false)` 其实已经把 hover 一起关了，
            //    这里是第二道 —— 将来那个包装层挪走时这一条仍然成立。
            guard tracksHover, !isSelectionMode else { return }
            onHoverChange(inside)
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        // 🔴 系统消息（模型切换）**整条不给右键菜单**（用户明确「不用有任何点击事件和交互」）。
        //    用 if/else 拆两条路，而不是「塞个空 menu 赌它不显示」——
        //    空 `contextMenu` 的行为随系统版本变过，而这里要的是确定性。
        //    （iOS 侧同一件事靠 `chatMenu` 返空集合 + 长按早退两道闸，见那边的注释。）
        if row.block.kind == .modelSwitch {
            core
        } else {
            core.contextMenu { menu }
        }
    }

    // MARK: - 按块类型分发

    @ViewBuilder
    private var content: some View {
        switch row.block.kind {
        case .text:  textBlock
        case .error: errorBlock
        case .modelSwitch: noticeBlock
        case .image: imageBlock
        case .file:  fileBlock
        case .video: videoBlock
        }
    }

    @ViewBuilder
    private var textBlock: some View {
        if isUser {
            if isEditing {
                inlineEditor
            } else {
                userTextBubble
            }
        } else if row.block.isStreaming && row.block.text.isEmpty && visibleReasoning == nil {
            TypingIndicator()
                .padding(.vertical, 9)
                .frame(maxWidth: maxBubbleWidth, alignment: bubbleAlignment)
        } else {
            // 助手正文：**没有气泡底**，背景即页面背景。
            // 原来那对 `.padding(.horizontal, 12)` 是气泡的「内衬」，气泡没了就一并去掉 ——
            // 留着只会让正文比左侧内容多缩进一截，且没有任何视觉依据。
            //
            // 2026-10-20：正文**上方**多了一块「思考过程」（推理模型先想后说）。
            // 三点等待的判据同步收紧：有思考时该显示的是思考块，不是「干等」的三点
            // （与 iOS `AIAssistantTextCell.configureStreaming` 同一条口径）。
            VStack(alignment: .leading, spacing: 0) {
                thinkingBlock
                AssistantTextView(text: row.block.text,
                                  isStreaming: row.block.isStreaming,
                                  // ⚠️ 传的是**提议宽度**（同一个 `maxBubbleWidth`，也用在下面那行 `.frame`）：
                                  //    正文就是在这个宽度上折行的，链接的鼠标命中判定必须用同一把尺子。
                                  layoutWidth: maxBubbleWidth)
                    .padding(.vertical, 2)
                    .frame(maxWidth: maxBubbleWidth, alignment: .leading)
            }
            .frame(maxWidth: maxBubbleWidth, alignment: bubbleAlignment)
        }
    }

    // MARK: - 思考过程（2026-10-20）

    /// 思考块可见性判据。
    ///
    /// 🔴 与 iOS 两侧**逐字同口径**（`AIThinkingBlockView.configure` 的 `visible` 判定、
    ///    `AIChatRow.thinkingHeightOrZero` 的行高判据）：三处对「什么时候画」必须是同一个答案，
    ///    否则会出现「iOS 画了 Mac 没画」或「行高算了块没画」这类对不上的症状。
    private var visibleReasoning: AIReasoning? {
        guard !isUser, row.block.kind == .text,
              let reasoning = row.block.reasoning, !reasoning.isEmpty,
              AIGenerationSettings.showsThinkingProcess else { return nil }
        return reasoning
    }

    /// 头部行文案：流式中是「思考中…」，完成后是「思考过程 · X 秒」（`AIReasoning` 的两个计算属性）。
    private var thinkingTitle: String {
        guard let reasoning = visibleReasoning else { return "" }
        return row.block.isStreaming ? reasoning.streamingTitle : reasoning.collapsedText
    }

    /// 思考块本体：左竖线 + 头部行（可点）+ 展开时的正文。
    ///
    /// 尺寸全部取 `AIThinkingBlockMetrics`（与 iOS 共用一份口径，⛔ 别在这里写数字）。
    /// Mac 侧是 SwiftUI **自撑高**（没有行高预计算这回事），所以这里的任务是
    /// 「长得和 iOS 一样」而不是「凑某个数」。
    @ViewBuilder
    private var thinkingBlock: some View {
        if let reasoning = visibleReasoning {
            HStack(alignment: .top, spacing: 0) {
                // 左竖线：「这是思考、不是正文」的标记。颜色取链接色那一支
                //（MacTheme 的强调色，与 iOS 侧 systemBlue 同族）。
                // 🔴 `maxHeight: .infinity` 不能省：只给 width 的 Rectangle 在 HStack 里
                //    会被压成 0 高（一根看不见的线），撑高才能「贯穿思考块」。
                //    ⚠️ 必须写成 `maxWidth/maxHeight` 这一档全可选重载 ——
                //    `frame(width:maxHeight:)` 把两个重载的标签混在一起，直接编译不过。
                Rectangle()
                    .fill(MacTheme.linkText)
                    .frame(maxWidth: AIThinkingBlockMetrics.accentLineWidth,
                           maxHeight: .infinity)
                    .padding(.trailing, AIThinkingBlockMetrics.accentSpacing)
                VStack(alignment: .leading, spacing: AIThinkingBlockMetrics.headerSpacing) {
                    // 头部行：标题 + chevron，整条可点（`contentShape` 把 Spacer 那截也纳入命中区）
                    HStack(spacing: 4) {
                        Text(thinkingTitle)
                            .font(Font(AIThinkingBlockMetrics.font))
                            .foregroundStyle(MacTheme.meta)
                        Spacer(minLength: 0)
                        Image(systemName: row.isThinkingExpanded ? "chevron.down" : "chevron.right")
                            .font(MacTheme.ui(MacTheme.metaFontSize))
                            .foregroundStyle(MacTheme.meta)
                    }
                    .frame(height: AIThinkingBlockMetrics.collapsedHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { onToggleThinking?() }
                    // 展开态的思考正文。折叠时整段不渲染（与行高判据同源：只看 isThinkingExpanded）
                    if row.isThinkingExpanded {
                        Text(reasoning.text)
                            .font(Font(AIThinkingBlockMetrics.font))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: maxBubbleWidth, alignment: .leading)
            // 与正文之间那 10pt：metrics 的 spacingBelow（Mac 自撑高，照抄这份间距保持两端一致）
            .padding(.bottom, AIThinkingBlockMetrics.spacingBelow)
        }
    }

    /// 用户气泡：强调色底 + 白字（iOS 侧是 systemBlue 底 + 白字）—— **配色不变**。
    ///
    /// 2026-09-29 起多了一种内容：**带引用的用户消息**。被引用的那段画在正文**上方**、
    /// 压在同一块强调色底里（缩放版的气泡内引用条，与 iOS `AIUserTextCell` 里那颗
    /// `AIQuoteBarView` 位置一致）。
    /// ⚠️ 引用条**只在 `block.quote` 有值时才出现** —— 不必去动行高相关的任何东西：
    ///    Mac 侧是 SwiftUI 自撑高，而 iOS 的行高口径（`AIChatRow.quoteHeightOrZero`）
    ///    只认**文本行 + quote 非空**，与这里同源。
    private var userTextBubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let quote = row.block.quote { userQuoteStrip(quote) }
            Text(row.block.text)
                .font(MacTheme.body)
                .foregroundStyle(MacTheme.userBubbleText)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: MacTheme.bubbleRadius).fill(MacTheme.userBubble))
        .frame(maxWidth: maxBubbleWidth, alignment: bubbleAlignment)
    }

    /// 气泡内的引用条。⚠️ 配色走 `MacTheme.userQuote*`（**白色降透明**）——
    /// 这里坐在强调色底上，⛔ 不能取 `composerQuote*` 那一组语义色（浅色模式下 `Color.primary`
    /// 是黑字，压在蓝底上等于看不见）。两组常量的分工见 `MacTheme` 里那段注释。
    ///
    /// 🔴 2026-10-21 起**可点**：点它 → `onRevealQuoted` → 滚到被引用的原消息（iOS 的
    ///    `revealMessage(id:)` 对等能力，A1 最后一块）。三条口径：
    ///    ① **可点线索跟整行 hover 走**（复用现成的 `isHovered`）—— ⛔ 不在本视图里加
    ///       `@State` 记 hover：`ForEach` 的 id 是行下标（见 `onHoverChange` 的注释），
    ///       行内 `@State` 会跟着下标走错行；
    ///    ② **手型光标走 `MacLinkCursor.applyInteractive(_:)`**（全 App 只许一个文件给手型光标，
    ///       理由与「注释里也不许写那个常量名」的怪规矩都见下面调用处的注释）；
    ///    ③ `onTapGesture` / `.contentShape` / 光标都**不参与布局** ⇒ 「能不能点」
    ///       一行高度都不该动（与媒体块那条铁律同源，渲染图兜着）。
    private func userQuoteStrip(_ quote: AIQuote) -> some View {
        HStack(alignment: .top, spacing: MacTheme.quoteInnerSpacing) {
            Image(systemName: AIRowAction.quote.icon)
                .font(MacTheme.ui(MacTheme.quoteFontSize))
                .foregroundStyle(MacTheme.userQuoteIcon)
                .padding(.top, 1)
            Text(quote.text)
                .font(MacTheme.ui(MacTheme.quoteFontSize))
                .foregroundStyle(MacTheme.userQuoteText)
                .lineLimit(MacTheme.quoteLineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.quoteRadius)
                .fill(isHovered ? MacTheme.userQuoteBackgroundHovered : MacTheme.userQuoteBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture { onRevealQuoted?(quote) }
        // 手型光标走 `MacLinkCursor`（2026-10-21 从本文件直接 set 改为收敛调用）：
        // 🔴 **全 App 的手型光标只许一个文件给**（`MarkdownRenderer.swift`）——
        //    `render_mac_ui.sh` 有条契约按字面量数它出现在几个文件里（期望 1，注释也算）。
        //    单点的理由是「每次回调都 set、不许 guard」这个要点只该守护在一处
        //    （2026-10-02/10-04 两个 bug 都是多处各写光标写出来的），详见 `MacLinkCursor` 的文档。
        //    ⛔ 所以本文件连**注释里都不许出现那个光标常量名**（契约不滤注释）——
        //       要提它就写「手型光标」三个字。
        // ☠️ 必须用 `onContinuousHover`（每帧回调）：`NSCursor.set()` **不粘**，
        //    每次鼠标移动 AppKit 都会按 cursor rect 重置；⛔ 别图省事用 `onHover`
        //    + `push`/`pop` —— 快速划过窗口时 `.ended` 不触发 ⇒ pop 缺失 ⇒ 光标粘在小手上。
        .onContinuousHover { phase in
            switch phase {
            case .active: MacLinkCursor.applyInteractive(true)
            case .ended:  MacLinkCursor.applyInteractive(false)
            }
        }
        .help(L("跳到被引用的消息"))
    }

    private var errorBlock: some View {
        // 失败提示同样不画底：它是助手这一轮的输出，跟着正文走。
        // 层级靠**橙字 + 小一号字号**表达，不靠底色。
        Text(row.block.text)
            .font(MacTheme.notice)
            .foregroundStyle(MacTheme.errorText)
            .textSelection(.enabled)
            .padding(.vertical, 2)
            .frame(maxWidth: maxBubbleWidth, alignment: bubbleAlignment)
    }

    /// 模型切换系统消息（2026-10-21）：**居中**一行小灰字，无气泡无底。
    ///
    /// 与 `errorBlock` 的三处差别都是刻意的：
    /// ① **居中**（它是系统流水，不属于任何一侧）；
    /// ② **灰字**（`MacTheme.meta`，与时间小字同色）—— 失败提示是橙的，那是「这一轮出事了」；
    /// ③ **不可选文字** —— 用户明确「不用有任何点击事件和交互」。
    ///
    /// 上下留白取共享层 `AIChatRow.noticeRowPaddingV`（与 iOS 那颗 cell、
    /// `AIChatRow.height(in:)` 的 `.modelSwitch` 分支**同一份常量**）。
    /// 左右各 12 与 iOS cell 的约束同值 —— `height(in:)` 按 `width - 24` 量文案，
    /// Mac 少了这份内衬就会「iOS 按 884 折行、Mac 按 908 折行」，长模型名在两端
    /// 折的行数不一样（渲染台 `probeModelSwitchNotice` 拿自然高度对账，会当场红）。
    /// 文案现取 `modelSwitchText`（`L()` 不被缓存 ⇒ 切语言后这一行跟着换）。
    private var noticeBlock: some View {
        Text(row.block.modelSwitchText)
            .font(MacTheme.notice)
            .foregroundStyle(MacTheme.meta)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.vertical, AIChatRow.noticeRowPaddingV)
    }

    @ViewBuilder
    private var imageBlock: some View {
        if isUser {
            userImageBlock
        } else {
            // 🔴 **AI 回复里的图片走媒体缩略图条**（2026-09-28 起，`MediaThumbStrip.swift`）。
            //
            // 用户要求：「图片和视频可能会多个 ⇒ 图片应在一个 cell 横向多个显示」。
            // 这里传**单行**是因为「分组」那一步在 `ChatDetailView`（它把连续的助手媒体行
            // 合成一条 strip 交给这里以外的路径）—— 本视图仍保持「一行一块」的语义。
            // ✅ 单张与多张共用同一条渲染路径（单张也跟组内一样大，用户选定）。
            // ⛔ 别在这里自己拼 `HStack`：分组规则与格子口径都在 `MediaThumbStrip` 里，
            //    分两处写必然漂移（最典型的就是「多张时的高度」与「单张时的高度」不一致）。
            MediaThumbStrip(rows: [row], onOpen: onOpenMedia)
        }
    }

    /// 用户自己发出的图片：**保持旧口径**（2026-09-28 用户明确「只改 AI 回复侧」）。
    ///
    /// 一行一张、按**真实宽高比**（`AIChatRow.userImageDisplaySize`，竖图就竖着），
    /// 与 iOS 侧那颗 `AIUserImageCell` 同源。⛔ 别顺手把它也换成缩略图条。
    ///
    /// 🔴 2026-10-08：整档乘 `MacTheme.userImageScale`（0.25 = 原来的四分之一）—— 用户连喊三轮
    ///    「太大了 / 还是不小 / 再缩小一半」，且**明确只有 Mac 要小**，iOS 保持原尺寸。
    ///    缩放**走共享层的 `scale` 形参**，
    /// ⛔ 别在本视图里自己乘/除那一下（那会让「渲染尺寸」与 `AIChatRow.height(in:)` 的
    /// 行高量算分叉 ⇒ 图片被裁或被留白撑开，成因见 `AIChatModels.swift` 该函数头注）。
    /// ⚠️ Mac 端行高由 SwiftUI 自然布局给（本视图不查 `height(in:)`），所以这里
    ///    只有**渲染**一个消费点；将来若 Mac 也改走业务层行高，记得把同一个 `scale` 传下去。
    @ViewBuilder
    private var userImageBlock: some View {
        if let url = row.block.imageURL {
            // 🔴 **别退回 `NSImage(contentsOf: url)`** —— 它是同步的，而且对 http(s) 会真去下载。
            //    写进 `body` 就是「每次求值都在主线程上取一遍图」，实测 72ms/次（远程封面 400ms/次）
            //    ⇒ 上下滑动卡顿 + 懒加载被饿死（中间一片空白）。改用异步 + 降采样 + 缓存的
            //    `RowMediaImage`，原因与实测数字都在它的文件头。
            RowMediaImage(url: url,
                          layout: .fixed(AIChatRow.userImageDisplaySize(in: containerWidth,
                                                                        mediaSize: row.block.mediaSize,
                                                                        scale: MacTheme.userImageScale),
                                         contentMode: .fit),
                          cornerRadius: MacTheme.bubbleRadius)
                // 点开看大图（2026-09-27）。`.contentShape` 显式垫上：图片的命中区只有
                // 「画出来的那块」，而 `.fit` 时盒子与画面本来就同尺寸 —— 写着是为了哪天
                // 换成 `.fitIn`（盒子比画面大）时「留白处点不动」不至于变成惊喜。
                .contentShape(Rectangle())
                .onTapGesture { onOpenMedia?(.image(url)) }
                .help(L("点开查看大图"))
        } else {
            // ⚠️ 这里**必须也走`userImageDisplaySize`**（2026-10-08 修）：原来直接写
            //    `containerWidth * 0.62` —— 那是把共享层的比例**又抄了一遍**，⛔ 正是该函数头注
            //    警告的「量的时候按 A、布局按 B」。真实图片缩到 0.25 而占位还是满宽的话，
            //    图片加载失败瞬间整行会「跳一下」。
            placeholder(text: L("图片不可用"),
                        width: AIChatRow.userImageDisplaySize(in: containerWidth,
                                                             mediaSize: nil,
                                                             scale: MacTheme.userImageScale).width)
        }
    }

    /// 视频：**只有助手侧会有**（业务层只把流事件里的 `.video` 挂到 assistant 行；
    /// 用户侧的视频发不出去，`contextMessages()` 里也是直接 `continue`）。
    /// 所以这里不分叉，直接走缩略图条 —— 那条路径本来就是为它写的。
    ///
    /// ℹ️ 被它取代的旧实现：0.66 × 容器宽 的 16:9 封面 + 34pt 播放图标。用户 2026-09-28
    /// 要求「多个媒体排一条、单张也跟组内一样大」⇒ 尺寸口径统一收进 `MacTheme.mediaThumb*`。
    private var videoBlock: some View {
        MediaThumbStrip(rows: [row], onOpen: onOpenMedia)
    }

    private var fileBlock: some View {
        // 附件卡片：与代码卡片同一套「面 + 描边」画法（它是内容容器，不是气泡）
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(MacTheme.ui(18))
                .foregroundStyle(MacTheme.meta)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.block.text)
                    .font(MacTheme.body)
                    .foregroundStyle(MacTheme.bodyColor)
                    .lineLimit(1)
                Text(fileSizeText)
                    .font(MacTheme.ui(MacTheme.metaFontSize))
                    .foregroundStyle(MacTheme.meta)
            }
            Spacer(minLength: 0)
            // 🔴 末尾那颗「分享」（2026-10-06）—— **必须紧跟 `Spacer` 之后、且不在任何 `if` 里**。
            //    它「平时隐藏」靠的是 `opacity` + `allowsHitTesting`（见 `fileShareButton`），
            //    ⛔ 别改成 `if revealsHoverControls { fileShareButton }`：那样文件名拿到的
            //    可用宽度会在鼠标进出的瞬间少 34pt，**长文件名的截断点会来回跳**。
            //    卡片宽度本身不受影响（`Spacer(minLength: 0)` 撑满 + `.frame(maxWidth: 320)` 夹住）。
            //    📌 这一条有**机读判据**兜着：渲染台的 `FILESHARE`（两态逐像素比，
            //    差异必须**只**落在卡片右端那颗底块的范围内）。见 `VERIFY-PROBES.md`。
            fileShareButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(MacTheme.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(MacTheme.cardBorder, lineWidth: 1))
        // 🔴 点卡片 → 在**右侧面板**里打开这个文件（2026-10-06）。
        //    ⚠️ `.contentShape` 显式垫上：卡片命中的本来就是「画出来的那块」，写它是为了
        //    将来卡片变成「带留白的容器」时，「留白处点不动」不至于变成一个惊喜
        //    —— 与图片块那条同一个理由。
        //    🔴 这三个修饰符**都不参与布局** ⇒ **行高一个点都不变**
        //    （与 2026-09-27 给媒体块挂点击时同一条口径，那边有渲染图兜着）。
        //    ⚠️ 选择模式不用在这判：外层 `ChatSelectionRow` 一句 `.allowsHitTesting(false)`
        //    把整块行内容（连同 hover）都关了，那一拍归它。
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = row.block.fileURL { onOpenFile?(url) }
        }
        .help(L("点开查看文件"))
    }

    /// 文件卡片末尾那颗「分享」。
    ///
    /// 🔴 **恒占位、只改显隐**：`.opacity` 决定看不看得见，`.allowsHitTesting` 决定点不点得动
    ///    —— 两个**都必须**跟着 `revealsHoverControls` 走。
    ///    ⚠️ 只改 `opacity` 会留下一颗**看不见却点得动**的按钮（连同 `.help` 的 tooltip 一起），
    ///    比看得见的更糟；这条老坑与用户侧那条栏、以及「回到底部」那颗按钮是同一个
    ///    （`ChatDetailView.showsScrollToBottomButton`）。
    ///
    /// ⚠️ 地址缺失时整颗不画：`AIBlock.file` 的 `fileURL` 是可选。
    ///    真实数据里它恒有值 —— `AIChatStore.block(from:)` 的 `case 4` 里
    ///    `AIAttachmentStorage.resolve` 拿不到就**直接不造这一行**（不会留下无地址的文件行）。
    ///    这里判空纯属不给自己留「点了没反应」的可能。
    @ViewBuilder
    private var fileShareButton: some View {
        if let url = row.block.fileURL {
            ChatFileShareButton(fileURL: url)
                .opacity(revealsHoverControls ? 1 : 0)
                .allowsHitTesting(revealsHoverControls)
        }
    }

    // MARK: - 占位

    private func placeholder(text: String, width: CGFloat) -> some View {
        ZStack {
            MacTheme.cardBackground
            Text(text)
                .font(MacTheme.notice)
                .foregroundStyle(MacTheme.meta)
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: MacTheme.bubbleRadius))
        .overlay(
            RoundedRectangle(cornerRadius: MacTheme.bubbleRadius)
                .stroke(MacTheme.cardBorder, lineWidth: 1)
        )
    }

    private var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: row.block.fileSize, countStyle: .file)
    }

    // MARK: - 正文下方的横排操作栏
    //
    // **两侧口径不同**（2026-09-24 起）：
    // - 助手侧：**每条都挂、常驻可见**（2026-09-21 起）。判据 `showsActionBar`。
    // - 用户侧：**每条都占位，但默认不可见、hover 才显**（2026-09-24 用户要求
    //   「我发送的消息默认隐藏底部操作栏，鼠标滑上去才显示」）。判据 `reservesUserBar`。
    //
    // ⚠️ 注意用户侧用的是「**占位**」而不是「挂不挂」—— 这两个词在这里不是一回事：
    //    占位 = 这一行**恒占** 29pt（`MacTheme.rowBarSlotHeight` + VStack 间距），
    //    只靠 `opacity` 显隐。理由见 `ChatRowUserActionBar` 文件头第 ② 条（31pt > 贴底容差 30pt）。
    //    ☠️ 别把 `userBarSlot` 改成 `if isHovered { … }` —— 那就是「悬停才长高」，
    //    鼠标每划过一条用户消息都会让「回到底部」按钮闪一下，而且最新那条的按钮会落在视口外。
    //
    // 助手侧那条的四条边界（都是有理由的，别当成「漏了」）：
    //  ⓪ **用户行不挂那一条**（复制/朗读/重试/分享是「对 AI 的回答做点什么」，用户行是另一栏）
    //  ① **正在长的那一条**（`row.block.isStreaming`）不挂 —— 栏在行尾，正文每来一个字它就往下跳一格，
    //     看着像在抖。**注意这里用的是行自己的标志，不是全局的 `isStreaming`**：全局那个只用来
    //     把「重试 / 继续生成」置灰（见下），不影响其他行继续挂着栏。
    //  ② 图片 / 文件 / 视频行**这里**不挂 —— 那几行的正文是媒体，复制/朗读/分享**对象不明确**。
    //     ⚠️ 2026-09-29 起要分清「哪一侧的媒体行」：
    //     · **助手侧**的媒体行根本不走本视图（早被投影成一条横滑条，
    //       `ChatTranscriptItem.group` → `ChatDetailView.mediaItem`），它那条
    //       「分享 + ⋯ + 时间」的操作栏挂在 `mediaItem` 里（`ChatRowMediaActionBar`）；
    //     · **用户侧**的图片行走本视图，仍然不挂栏（也**连占位都不占**，见 `reservesUserBar`）
    //       —— 本次改动按用户选择**只做助手侧**，别顺手给用户侧也加上。
    //  ③ 空正文不挂 —— 没有可复制的字，一排按钮只是噪音。
    //     用户侧同理：`编辑 / 复制` 也需要有字，所以媒体行与空正文行**连占位都不占**。

    private var showsActionBar: Bool {
        guard !isUser else { return false }
        guard !row.block.isStreaming else { return false }
        switch row.block.kind {
        case .text:  return !row.block.text.isEmpty
        case .error: return true
        case .image, .file, .video: return false
        case .modelSwitch: return false     // 系统流水：零交互，连栏都不占
        }
    }

    /// 用户侧那一行**是不是要占位**（注意：是「占位」，不是「显示」）。
    ///
    /// 与 `showsActionBar` 的差别只在第一条：那边是「助手行才挂」，这边是「用户文本行才占」。
    /// 其余三条（不流式 / 非媒体 / 非空正文）完全一致 —— 两处刻意写成一个形状，
    /// 免得以后改一处漏一处。
    ///
    /// ⚠️ 编辑态**也要占位**（`isEditing` 不影响本判据）：编辑时那一行放的是「取消 / 保存」，
    ///    两者共用同一个高度，所以进出编辑态这一行不会改变高度。
    private var reservesUserBar: Bool {
        guard isUser else { return false }
        guard !row.block.isStreaming else { return false }
        switch row.block.kind {
        case .text:  return !row.block.text.isEmpty
        case .error: return false                       // 用户侧没有失败行
        case .image, .file, .video: return false
        case .modelSwitch: return false                 // 同上：它不是用户消息
        }
    }

    // MARK: - 「hover 才显」的两处（单点定义，见文件头）

    /// 这一行**需不需要「指针进出」这个信号**（= 有没有 hover 才显的东西）。
    ///
    /// 判据就一条：**有没有东西要靠它显出来**。现在两处 —— 用户侧那条操作栏、
    /// 文件卡片末尾那颗分享。
    /// 🔴 `onHover` 只问这里：⛔ 别在那边再写一串 `||`，漏掉一半的症状是
    ///    「按钮画出来了、鼠标移上去它永远不出现」（hover 信号压根没上报到宿主）。
    /// ⚠️ 文件行也**报告** hover，但它的 hover **不驱动任何栏**（`reservesUserBar` 仍是 false）
    ///    —— 别把这两个概念混成一个：一个是「要信号」，一个是「有一栏要占位」。
    private var tracksHover: Bool { reservesUserBar || showsFileShareButton }

    /// 「hover 才显」的东西此刻**要不要显出来**（两处共用这一份判据）。
    ///
    /// ⚠️ 选择模式那一半对**用户侧那条栏**是**冗余**的（那时整个 `userBarSlot` 都不渲染，
    ///    见 `body`）；留着是为了让两处**逐字同源** —— 上一版是「一处判、一处不判」，
    ///    而那正是将来「挪走包装层之后漏判」的来源。
    private var revealsHoverControls: Bool { isHovered && !isSelectionMode }

    /// 文件行末尾那颗「分享」**存不存在**（= 是文件行、且拿得到文件地址）。
    ///
    /// ⚠️ 与 `showsActionBar` / `reservesUserBar` **刻意分开**：那两条决定「正文下方那一栏」，
    ///    本条的宿主在**卡片内部**（`fileBlock` 的 `Spacer` 之后）。三者共用一张表的话，
    ///    迟早有人为了改一处而去动另一处。
    /// ⚠️ `.file` 在实际数据里只有用户侧（只由附件面板产生），所以这里不判 `role`
    ///    —— 与 `fileBlock` 本身不分叉同一个口径。
    private var showsFileShareButton: Bool {
        row.block.kind == .file && row.block.fileURL != nil
    }

    private var actionBar: some View {
        ChatRowActionBar(
            text: row.block.text,
            // ⚠️ 取 `createdAt` 而**不是** `metaText`：后者是气泡上方那行小字的成品文案，
            //   只有「与上一条隔了 ≥5 分钟」才有值（`AIChatManager.applyMetaFlags`），
            //   连着一问一答的中间几条全是 nil —— 拿它当时间显示，大部分行会空着。
            //   `createdAt` 是这一行自己的时间，恒有值（恢复会话时沿用落库时间）。
            timestamp: row.createdAt,
            isSpeaking: isSpeaking,
            canRetry: canRetry,
            showsContinue: row.block.endedTruncated,
            // 🔴 收流期间只**置灰**会打断流的动作（重试 / 继续生成），**不整栏藏起来**。
            //   iOS 那边是整栏藏（`applyActionBarFlags` 在流式中把 target 设为 nil），
            //   但那边全表只有一条栏，藏着不显眼；Mac 每条都有栏，全藏会让整屏按钮闪一下。
            //   置灰的判据与业务层对长按操作卡用的那个属性（`AIRowAction.blockedWhileStreaming`
            //   = restartsStream ‖ delete）是同一套语义：点了就会先 stop() 再起第二条流。
            restartsBlocked: isStreaming,
            onCopy: onCopy,
            onSpeak: onSpeak,
            onRetry: onRetry,
            onContinue: onContinue,
            // 「⋯」里那两项（2026-09-29）。删除**沿用右键菜单那一条** ——
            // 同一个词在两个入口必须给出同一件事（都是「删这一轮」）。
            onQuote: onQuote,
            onRequestDelete: onRequestDelete
        )
        // 与正文之间让出一点空隙（口径见 `MacTheme.rowActionBarTopGap`）——
        // 🔴 媒体行那条栏用的是**同一个常量**（`ChatDetailView.mediaItem`），两处别各写各的。
        .padding(.top, MacTheme.rowActionBarTopGap)
    }

    // MARK: - 用户侧那一行（操作栏 / 编辑控件，**同一个占位高度**）

    /// 用户文本行下方那一行。**恒占 `MacTheme.rowBarSlotHeight`**，里面装的两种东西：
    ///
    /// | 状态 | 装什么 | 显隐 |
    /// |---|---|---|
    /// | 常态 | `ChatRowUserActionBar`（时间 · 编辑 · 复制 · ⋯） | `opacity` 随 hover，**不可点**（藏起来时） |
    /// | 编辑中 | 「取消 / 保存」 | **恒可见**（这是用户刚点出来的，不该还要悬停才看得见） |
    ///
    /// 🔴 两种状态**高度必须一样**：`.frame(height:)` 写在外面、里面两个分支都不许自己撑高
    ///    （所以 `ChatRowUserActionBar` 里刻意没有 `.padding(.top)`）。
    private var userBarSlot: some View {
        Group {
            if isEditing { editControls } else { userActionBar }
        }
        .frame(height: MacTheme.rowBarSlotHeight, alignment: .trailing)
    }

    private var userActionBar: some View {
        ChatRowUserActionBar(
            text: row.block.text,
            timestamp: row.createdAt,
            restartsBlocked: isStreaming,
            onEdit: onBeginEdit,
            onCopy: onCopy,
            // 「⋯」里那两项（2026-09-29 用户要求「我发送的消息也加三个点按钮」）。
            // ⚠️ 传的是**同一个回调**：`enterSelectionMode(startingAt: row.id)` 对两个 role
            //    一视同仁（它按行号现算整轮），引用也一样（`beginQuote(rowId:)` 会把 role 存进 `AIQuote`）。
            onQuote: onQuote,
            onRequestDelete: onRequestDelete
        )
        // 淡入淡出而不是 `if`：位置不参与布局（占位是外层 `.frame(height:)` 给的），
        // 所以这里怎么变都不会推动别的行。
        // ⚠️ 判据与文件卡片末尾那颗分享**共用** `revealsHoverControls`（单点定义，
        //    见那边注释）—— ⛔ 别改回裸 `isHovered`，那会变成「一处记得判选择模式、一处忘了」。
        .opacity(revealsHoverControls ? 1 : 0)
        // ☠️ 淡出之后**必须**交还触摸权：`opacity(0)` 的按钮照样能点、`.help` 照样会弹
        //    （一副看不见却可点的按钮，比看得见的更糟）。
        //    与「回到底部」那颗按钮同一条处理（那边是 `.allowsHitTesting(shows…)`）。
        .allowsHitTesting(revealsHoverControls)
    }

    /// 编辑态：取消 / 保存。
    ///
    /// 放在下方那一行（而不是编辑器右侧）：右侧要塞就得挤窄编辑器，而这一行**本来就是空的**
    /// —— 复用之后进出编辑态的高度变化只剩「气泡 → 编辑器」那一处，少一个变量。
    private var editControls: some View {
        HStack(spacing: MacTheme.editActionSpacing) {
            Button(Self.cancelEditTitle) { onCancelEdit() }
                .buttonStyle(.plain)
                .foregroundStyle(MacTheme.meta)
                .help(L("放弃改动"))
                // Esc = 取消。与录音面板的 Esc 不冲突：`beginEdit` 已经把「正在录音」挡在外面了。
                .keyboardShortcut(.escape, modifiers: [])

            Button(Self.commitEditTitle) { onCommitEdit() }
                .buttonStyle(.plain)
                .foregroundStyle(canCommitEdit ? MacTheme.userBubble : MacTheme.actionIconDisabled)
                .help(L("从这条起重新生成（这条之后的对话会被替换）"))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCommitEdit)
        }
        .font(MacTheme.ui(MacTheme.editActionFontSize))
        // 文字按钮的命中区只有字形本身那么大（十几像素高），垫一层把它撑到接近整行 ——
        // 与输入栏那几颗图标按钮同一个坑（`.contentShape` 垫命中区）。
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// 「取消 / 保存」的文案。**不放进 `AIRowAction`** —— 那边是「对消息能做的操作」的
    /// 定义（两侧操作卡与操作栏共用、`CaseIterable`），而这两颗是**编辑态自己的**确认键，
    /// 不是菜单项：加进去会让 `allCases` 多出两个永远不该出现在任何菜单里的成员。
    /// 🔴 两条都是**计算属性**（2026-10-13）：`static let` 会把 `L()` 的结果进程级缓存住
    ///    ⇒ 切语言后永远停在旧语言那份，视图重建也救不回来（见 `.workbuddy/memory/I18N.md`）。
    private static var cancelEditTitle: String { L("取消") }
    private static var commitEditTitle: String { L("保存") }

    /// 保存是否可用：空文本没有意义（业务层的 `editAndResend` 也会先 `guard !trimmed.isEmpty`）。
    private var canCommitEdit: Bool {
        !editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 就地编辑器（编辑态下替掉用户气泡）

    /// 把气泡换成**输入框**。
    ///
    /// 🔴 刻意**不沿用**强调色气泡的配色：白字输入框在 macOS 上跟静态文字几乎分不出来，
    ///    「这一块现在能打字」必须一眼看出。所以表面走输入卡片那一套
    ///    （`MacTheme.inlineEditorBackground` = 输入卡片的底 + 强调色 1pt 描边），
    ///    而轮廓仍用 `bubbleRadius` —— 位置与形状没变，变的只是「它现在是个输入框」。
    private var inlineEditor: some View {
        TextField("", text: $editingText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(MacTheme.body)
            .foregroundStyle(MacTheme.bodyColor)
            .lineLimit(1...8)
            // 内衬与气泡同档（12 / 6）：同一块地方，换了个壳而已
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: MacTheme.bubbleRadius)
                    .fill(MacTheme.inlineEditorBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MacTheme.bubbleRadius)
                    .stroke(MacTheme.inlineEditorBorder, lineWidth: 1)
            )
            .frame(maxWidth: maxBubbleWidth, alignment: bubbleAlignment)
    }

    // MARK: - 右键菜单
    //
    // 与操作栏**列同一批动作**（文案同样取自 `AIRowAction`，不另起一套字符串），
    // 多出来的只有「删除」—— 它是破坏性操作，不进横排（降误触）。
    // ⚠️ 这里没有「分享」：右键菜单里弹系统 Services 需要 `NSSharingServicePicker` + 一个 NSView 锚点，
    //    而操作栏那颗 `ShareLink` 已经覆盖了分享，不值得为菜单再铺一层。想补的话落点就在这里。
    //
    // ⚠️ 选择模式下这个菜单**弹不出来**：外层的 `ChatSelectionRow` 把整块行内容的命中关了
    //    （`allowsHitTesting(false)`），右键进不来。这里**不要**再加一个 `isSelectionMode` 判断 ——
    //    两处各判一半，将来那个包装层挪走时就会剩下一处永远为真的死条件。

    @ViewBuilder
    private var menu: some View {
        // 「编辑」只在用户文本行上出现（判据与占位那条一致）—— 它是操作栏上那颗的
        // **第二个入口**：操作栏得把鼠标移上去才出得来，右键菜单随时可用。
        // 顺序也跟操作栏对齐（编辑在复制之前）。
        if reservesUserBar {
            Button(AIRowAction.edit.title) { onBeginEdit() }
        }
        Button(AIRowAction.copy.title) { onCopy() }
        Button(isSpeaking ? Self.stopSpeakingTitle : AIRowAction.speak.title) { onSpeak() }
        // 与操作栏同一判据（`canRetry`）：用户行只有在后面已经有助手回复时才出现这一项
        if canRetry {
            Button(AIRowAction.regenerate.title) { onRetry() }
        }
        if row.block.endedTruncated {
            Button(AIRowAction.continueGeneration.title) { onContinue() }
        }
        Divider()
        // 文案取业务层 `AIRowAction.delete.title`（=「删除」）—— 与「⋯」菜单里那一项**同一个词**。
        // ⚠️ 2026-09-29 之前这里写的是「**删除这一轮**」：那时点下去真的只删这一轮。
        //    现在它进的是选择模式（默认勾整轮、但用户可以改），再写「这一轮」就是一句错话。
        Button(AIRowAction.delete.title, role: .destructive) { onRequestDelete() }
    }

    /// 与 `ChatRowActionBar` 里那颗的文案保持一致（同一状态两个入口，措辞不能两样）
    /// 🔴 计算属性（2026-10-13）：同上，`static let` 会把语言锁死。
    private static var stopSpeakingTitle: String { L("停止朗读") }
}
