//
//  ChatDetailView.swift
//  AsterMac
//
//  右栏：消息列表 + 底部输入栏。
//
//  ## 与 iOS 的结构差异
//  iOS 是 UITableView + 行高缓存（`insertRows` / `cachedHeight`）；SwiftUI 的 `LazyVStack`
//  自己按内容量高、数据一变就重算 body ⇒ 这里只读 `model.rows`，不碰任何行高接口。
//
//  ## 🔴 滚动这一块全是坑，动之前先读完这一段
//  判据**全页只有一处**：`isScrolledToBottom`（由 `ChatScrollMetrics` 算）。
//  跟随与「回到底部」按钮各写一套的后果是自相矛盾：跟随认为到底了、按钮还挂在屏幕上。
//
//  ① **进会话必须收敛式贴底**（`beginSettling`：按 `settleTick` 轮询量几何，真贴底才收手）。
//     只滚一次会停在半路 —— `LazyVStack` 首帧给的是**估计高度**，真实行高长出来后锚点往下跑、
//     滚动位置却不动（真机长会话实测停在 ~1/4 处）。⚠️ 离屏探针复现不出来（夹具的估计≈真实），
//     只能 `macshot` 截真窗口，且**新起实例**（`open -n`）才算重放用户的启动路径。
//     退出条件只有「内容底边不再变」。⛔ 别用「距离变大 ⇒ 用户上滚」：内容长高时形状一模一样。
//  ② **按拍交替滚两个锚点**：偶数拍行锚点（把底部 materialize 出来）、奇数拍底边锚点（精确贴底）。
//     底边锚点在 `LazyVStack` 外面 ⇒ SwiftUI 认为它「总是存在」、不肯为它 materialize 任何行 ⇒
//     滚到的是按估计高度算的**不存在的位置**（实测离真底 651pt）。同一拍连滚两下只有最后一次生效。
//  ③ **内容总高变大也要补一次贴底**：`LazyVStack` 到 ~1.4s 才把底部那段量出来，那一拍行数没变、
//     `isStreaming` 也是 false ⇒ 三条 onChange 一条都不触发。判据必须用**总高**
//     （`contentHeight` = 底边 − 顶边）：底边变大既可能是内容长高也可能是用户上滑，形状一样。
//     顶边 / 底边两颗 0 高探针**共用一个 preference 通道**（分两个 key 会让总高在中间态虚增）。
//  ④ **「滚到底」的锚点 = 内容底边，不是最后一行**：对齐最后一行会停在 `padding(.vertical, 14)`
//     之前（看着到底、其实还能滑 14pt，探针 `METER d=14`）。这颗锚点同时就是 ③ 的底边探针，
//     ⛔ 别拆成两个视图。⚠️ 锚点不能写进 `LazyVStack`（会被底部 padding 顶上来，等于没修）。
//  ⑤ **别扣 `geometry.safeAreaInsets.bottom`**：`safeAreaInset(.bottom)` 已经让 ScrollView 的
//     frame 变矮，再扣等于连减两次（症状：贴底时按钮照样显示、还被顶高一整个输入栏）。
//
//  ## 搜索命中定位
//  搜索页点结果 → `ChatModel.open(searchHit:)` → `revealTarget` → 滚到那条（`.center`）并圈一下。
//  🔴 两条硬约束：① 它必须是**最后**一个 `onChange`（否则刚定位到就被「贴底跟随」拽回底部）；
//  ② 高亮只许挂 `.background` + 负 padding 向外扩，**不许改变任何一行的高度**（行高一变滚动位置就漂）。
//
//  ## 拖文件进来
//  整页都能落（`DropFileOverlay`），落地走输入栏「+」同一条路（`ComposerAttachmentPicker`），
//  所以压缩 / 命名 / 上限 / 部分失败的口径与点「+」完全一致。
//  🔴 遮罩层必须 `allowsHitTesting(false)`（否则挡住 onDrop 的落点判定）；落点挂**最外层**
//  （`.alert` 之后），挂 `ScrollView` 上只盖得住列表那一半。
//
//  ## 怎么验
//  `ImageRenderer` **不渲染 `ScrollView` 的内容** ⇒ 滚动相关一律走交互探针：
//  真 `NSWindow` + 进程内注入滚轮 + 截真窗口，跑 `zsh .workbuddy/scripts/render_mac_ui.sh geom`。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AICore

struct ChatDetailView: View {
    @Environment(ChatModel.self) private var model
    /// 打开设置窗（macOS 14+）。空态的「去配置模型」要用 ——
    /// ⚠️ 与 `SidebarSettingsBar` 走**同一个**环境值，⛔ 别另写 `showSettingsWindow:` 那种 selector。
    @Environment(\.openSettings) private var openSettings

    // ☠️ 这里曾有一行 `@Environment(\.aiLanguageID) private var languageID`（2026-10-13 第三版删）。
    //    换身份那套已整体废弃（成因见 `AILocalization.swift` 文件头与 `body` 末尾那段）。

    // MARK: - 删除选中项的二次确认（2026-09-29 起只有这一条）
    //
    //  勾选状态**不在这一页** —— 唯一真值在 `ChatModel.selectedRowIds`（那一条注释里写了原因）。
    //  这一页只管两件事：弹窗开着没有、弹窗上写几条。
    //
    //  ⚠️ 2026-09-29 之前这里有**两个**状态（`pendingDeleteRow` 删整轮 / `pendingDeleteMediaIds`
    //     只删媒体），对应两条 alert。各删除入口统一成「进选择模式」之后，两条路径合成了
    //     一条，那两个状态一起删掉了 —— ⛔ 别再因为「媒体想删得不一样」把它们加回来：
    //     「只删这几张图」现在由用户在选择模式里取消勾选来达成的。
    //     ℹ️ 入口数是**四**（右键菜单 / 助手文本栏 ⋯ / 媒体栏 ⋯ / 用户侧栏 ⋯），
    //        但它们都只喊 `model.enterSelectionMode(startingAt:)` —— 这一页不需要知道是哪一个。

    /// 二次确认弹窗是否开着
    @State private var isConfirmingDeleteSelection = false

    /// 弹窗标题里那个条数。**必须在点「删除」那一拍记下来**：
    /// `deleteSelection()` 会先退出选择模式（勾选集合清零），标题若直接读
    /// `model.selectedCount`，会在弹窗关闭动画里闪一下「删除选中的 0 条消息？」。
    @State private var pendingDeleteCount = 0

    // MARK: - 用户消息的悬停态（2026-09-24）

    /// 指针**停在**哪一条消息上（`row.id`）。用户侧那条操作栏据此淡入淡出。
    ///
    /// 🔴 记 `row.id` 而**不是行下标**，并且移出时**只清自己那一行** —— 与
    /// `MacSearchView.hoveredIndex` 同一个坑：快速从一条划到另一条时，两个 `onHover`
    /// 回调的顺序不保证，后到的那个 `false` 会把新那一行的悬停态一起清掉
    /// （症状是「划过去闪一下又没了」）。
    /// 记 id 还顺带解决了换会话的情形：行下标会在新会话里对上另一条消息，id 不会。
    @State private var hoveredRowId: UUID?

    // MARK: - 搜索命中的定位高亮

    /// 正在高亮的行（搜索页点了一条结果之后，把那条消息圈一下再淡出）。`nil` = 没在闪。
    @State private var revealedRowId: UUID?
    /// 闪一下的收尾任务（换目标 / 视图消失时取消，免得前一次把后一次的高亮提前清掉）
    @State private var revealFlashTask: Task<Void, Never>?
    /// 「进入编辑态后滚到那一行」的延迟任务（同上：换目标 / 视图消失时要取消）
    @State private var editScrollTask: Task<Void, Never>?

    // MARK: - 贴底判据（唯一口径，见文件头）

    /// 视口高度。**就是**滚动内容可见区域的底边 —— 别再扣安全区（文件头有实测说明）。
    @State private var viewportHeight: CGFloat = 0
    /// 内容底边在滚动坐标系里的 y
    @State private var contentBottom: CGFloat = 0
    /// 内容**顶边**在滚动坐标系里的 y（≈ `-滚动偏移`）。2026-09-26 加，见 `contentHeight`。
    @State private var contentTop: CGFloat = 0
    /// 当前是否贴着底部。首帧 = `true`（等价于「还没滚动过」）。
    @State private var isScrolledToBottom = true

    /// 内容**总高** = 底边 − 顶边。
    ///
    /// ## 🔴 为什么要专门量它，而不是拿现成的一个几何量凑（2026-09-26 加）
    /// 要区分这两件事，**只有总高能做到**：
    /// - **内容长高**（`LazyVStack` 把底部那一段量出来了）⇒ 总高**变大**；
    /// - **用户上滑**（内容整体往下平移）⇒ 底边位置**同样变大**，但**总高不变**。
    ///
    /// 只盯底边那一个量时两者**形状一模一样** —— 本项目为此栽过两次：
    /// ① 文件头那条「别用『距离变大 = 用户在上滚』」（内容长高时距离本来就会变大）；
    /// ② 本轮先按底边写了个「长高就补一次贴底」，切会话确实治好了，
    ///    但短行夹具立刻抓到**把用户 90pt 的上滑当场拽回去**（偏移只动 1pt）。
    /// ⇒ 判据必须建立在「总高」这种**只随内容变化、不随滚动变化**的量上。
    private var contentHeight: CGFloat { contentBottom - contentTop }

    // MARK: - 「用户自己翻走了」—— 跟随的开关（2026-09-26 加）

    /// 用户是否**主动往上翻**了历史（= 我们不该再把他拽回底部）。
    ///
    /// ## 🔴 这就是「发送后不自动到底 / AI 回复也要手动滚」的修法
    /// 旧写法拿 `isScrolledToBottom`（几何量）当「用户是否在底部」的代理，可它同时
    /// 被**内容长高**影响：流式回复一撑开，判据就翻成 false，于是
    /// `guard isScrolledToBottom else { return }` **把之后每一次跟随全掐断** ——
    /// 用户看到的就是「我发的和 AI 回的都得自己滚」。
    /// 这与文件头里那条已记的教训是**同一个错**（「别用『距离变大 = 用户在上滚』，
    /// 内容长高时距离本来就会变大」）：**内容变化 ≠ 用户操作**，两者必须分开。
    ///
    /// ⇒ 用户意图改由**滚轮事件**判定（`installScrollMonitor()`）：
    /// 程序化的 `scrollTo` **不产生** `scrollWheel` 事件，所以这个信号只代表「用户的手」。
    /// 几何判据退回去只管它擅长的事 —— 「回到底部」按钮显不显示。
    @State private var userScrolledAway = false

    /// 本地滚轮事件监听器的 token（`onDisappear` 要卸，否则监听器活得比视图久）。
    @State private var scrollMonitor: Any?

    // MARK: - 「底部那一行到底有没有被创建」（2026-09-26，切会话白屏的判据）

    /// 当前**活着**的行 id（`onAppear` 已到、`onDisappear` 还没到）。
    ///
    /// ## 🔴 为什么贴底判据必须再补这一个信号
    /// 真机 + 真会话日志实测（2026-09-26，6 条的会话 A → 6 条的会话 B，**行数相同**）：
    /// ```
    /// SETTLE-BEGIN rows=6 选中=B
    /// SETTLE-TICK 0 总高=1989 cb=634          ← 收敛首拍同步滚了一次
    /// STATE pin=T cb=588 vh=574 总高=1989     ← 判据说「已贴底」
    /// 🚨 一个行都没被创建                       ← 而屏幕上什么都没有
    /// ```
    /// 根因是**两套账**：容器高度（`contentBottom`/`contentHeight` 的来路）用的是
    /// `LazyVStack` 的**估计值**，而「哪些行要画在屏幕上」用的是它自己那份偏移。
    /// 于是完全可以出现「几何说贴底、一行都没画」—— 用户看到的就是一片空白。
    /// 几何量在「行没被创建」与「行建了但画在视口外」这两种成因下**分不开**，
    /// 而这一条**只能由渲染本身产生**，是唯一能一眼定案的判据。
    ///
    /// ⚠️ 钥匙用 **id 不用下标**：切会话是整表替换，新旧两批行的下标完全一样（都是 0…5），
    ///    若 SwiftUI 先给新行 `onAppear`、再给旧行 `onDisappear`，同一组下标会抵消，
    ///    集合变空 ⇒ 假读数。id 不会抵消。
    @State private var liveRowIds: Set<UUID> = []

    /// 现在屏幕上是否真的有消息行活着（≈ `LazyVStack` 这一轮实例化过了）。
    private var hasMaterializedRows: Bool { !liveRowIds.isEmpty }

    /// 滚动坐标系的命名。内容侧的探针要与视口侧同一个坐标系才能相减。
    private static let scrollSpace = "starry.chat.scroll"
    /// 滚动内容**底边**的锚点 id ——「回到底部」滚的是它，不是最后一行（文件头有成因）。
    private static let bottomAnchorID = "starry.chat.bottom"
    /// 「贴底」容差：贴底时判据的残差只有 1~2pt（系统给滚动内容加的 inset），
    /// 30 是「手指/滚轮抖一下不算翻页」的余量 —— 与 iOS 侧那个 `bottomPinnedTolerance` 同值同义。
    private static let bottomTolerance: CGFloat = 30

    // MARK: - 拖拽落区（2026-09-26 加）

    /// 正有文件悬在本页上方（访达拖拽进行中）。落区那一层据此显隐。
    ///
    /// - Note: 由 `.onDrop(of:isTargeted:)` 的 `isTargeted` 写进来 ——
    ///   它是**系统给的**判定（载荷类型匹配 + 指针在落区内），比自己去猜
    ///   `NSDraggingInfo` 可靠得多。
    /// - Note: 只在**本页**为真。左栏（会话列表）不接受落文件 ——
    ///   「把文件拖到某个会话上 = 发给那个会话」是另一个功能（要能跨会话投递），
    ///   当前没有，所以也别让它亮起来，否则是承诺做不到的事。
    @State private var isDropTargeted = false

    // MARK: - 媒体预览（2026-09-27 加；当天从「整页浮层」改成**独立窗口**）
    //
    //  🔴 这里**刻意不留任何状态**：预览窗由 `MediaPreviewWindowCenter` 自己管
    //     （一张图一个窗口、同一张再点则聚焦）。第一版是 `@State private var previewingMedia`
    //     + 一层 `.overlay`，改成窗口之后那套全删了 ——
    //     ⛔ 别因为「想省一个单例」把它退回页内浮层：用户明确要求过要独立窗口
    //     （理由见 `MediaPreviewWindow.swift` 文件头）。
    //  ✅ 顺带的好处：切会话**不再需要**关预览（窗口与会话无关），
    //     所以 `onChange(of: selectedConversationId)` 里那条 `previewingMedia = nil` 也一并去掉了。

    // MARK: - 进入会话时的贴底收敛（2026-09-22「启动不在最底部」的修法）

    /// 收敛任务：进入会话后把「贴底」持续纠到位（成因见文件头）。
    @State private var settleTask: Task<Void, Never>?
    /// 是否正在收敛。收敛期间**不显示**「回到底部」按钮 ——
    /// 否则每次启动都会先闪出一颗按钮（那本来就是「没贴底」的信号，不必让用户看见）。
    @State private var isSettling = false

    // MARK: - 空态：有没有配过模型（2026-10-26）

    /// 「模型清单是不是空的」。**必须镜像成 `@State`**，理由同语言 / 外观那一族：
    /// `AIConfig.hasModel` 是普通静态属性，**不登记任何观察依赖** ⇒ 直接在 `body` 里读它，
    /// 配置变了界面不动。
    ///
    /// 刷新点：`.onAppear`（进页面）+ `AIConfig.didChangeNotification`（保存 / 删除模型）。
    @State private var hasModel = ChatDetailView.lastKnownHasModel

    /// `hasModel` 的初值来源。
    ///
    /// ☠️ **⛔ 别直接把 `= AIConfig.hasModel` 写成 `@State` 的默认值**：
    ///    `@State` 的默认值表达式**每次 View init 都求值一次**（求完就被存储丢掉），
    ///    而本页是热页面（流式输出时父级不断重建本 struct）⇒ 那等于每帧 stat 一次
    ///    `models.json`。这里只读一个内存变量，成本为零。
    /// ⚠️ 它**只是初值**，真值永远以 `AIConfig.hasModel` 为准（上面两个刷新点会纠正）。
    private static var lastKnownHasModel = AIConfig.hasModel

    /// 收敛窗口时长。取值的两头：短了盖不住长文档的测量收敛（真机实测要几百毫秒），
    /// 长了会跟「刚打开就往上翻历史」的手打架。
    ///
    /// 🔴 **2026-09-26 从 1.5 放宽到 2.5**：长文档夹具的底层几何曲线显示，
    /// `LazyVStack` 把底部那一段（一屏高的大代码块）**量出来**要到 **1.4s 左右**，
    /// 而总高一旦被修正（实测 `8858 → 9517`，+659pt）就必须再滚一次才贴底 ——
    /// 1.5s 的窗口只剩最后 1 拍，那一拍的 `scrollTo` 赶不上布局变化，于是列表
    /// **停在离真底一屏处**（用户看到的「切回来一片空白，往上滑一下才出内容」）。
    /// ⚠️ 放宽窗口**不会**让「已经贴底」的会话多等：贴底判据 + 稳定判据都会提前收手，
    ///    只有真没贴底时才跑满窗口 —— 也就是只有本来就会出问题的那些会话才多花这 1 秒。
    /// ⚠️ 这是**兜底**，`onChange(of: contentHeight)`（「内容长高就补一次跟随」）才是主力：
    ///    真实会话的富文本比夹具更难量，多晚长出来都能补上。
    ///    ☠️ 那条盯的必须是**总高**，不是底边（盯底边会把用户的上滑当成内容长高、把人拽回去）。
    private static let settleWindow: TimeInterval = 2.5
    /// 收敛轮询间隔。**必须轮询而不是只依赖几何回调**：相机不动时几何偏好就不发通知，
    /// 而「上一拍滚了、这一拍还没生效」的空窗期正好会被漏掉。
    private static let settleTick: UInt64 = 80_000_000
    /// 判定「布局已经不再长」的连续拍数：内容底边连着这么多拍**一模一样**，
    /// 就说明测量收敛完了 —— 此时若还没贴上底，再滚也不会有变化，收手。
    ///
    /// ⚠️ 这里**刻意不用**「距离变大 = 用户在往上滚」那种判据。第一版写了，探针当场打脸：
    ///    内容从估计高度长到真实高度时距离**本来就会变大**（实测 3996 → 4431），
    ///    与用户上滚无法区分 —— 真机上会把它当用户操作提前收手，修复等于没做。
    ///    换成「不再变」，就只依赖一个事实：**这个 bug 的驱动力就是内容在长**。
    private static let settleStableTicks = 3

    var body: some View {
        // ⛔ 这里**不再**读 `model.webPage` / `model.lastWebPageURL`，也**不再**有 `.toolbar`：
        //    那颗「网页」开关 2026-09-30 已按用户要求搬到**侧栏列**的导航上
        //    （「换成 左侧菜单页面导航上的按钮，就是红绿灯旁边的那种」）。
        //    读模型的那两行跟着搬去 `RootView`（时机要求一模一样：必须在 body 求值期，
        //    成因见 `RootView` 里 `hasWebPage` 那段注释）。
        GeometryReader { geometry in
            content(containerWidth: geometry.size.width)
        }
        // ☠️☠️ 2026-10-13 **第三版**：这里**不许**再挂 `.id(languageID)`（前两版挂过）。
        //    成因（真窗口实测）：只要在**本列的内容子树里**出现身份变化（挂多深都一样），
        //    AppKit 就把挂在本列上的工具栏项 —— 右上那两颗「打电话 / 右侧页面」——
        //    的 hosting view 拆掉、**且不再回填**：`ToolbarItemHostingView` 从 `69x28`
        //    缩成 `10x10`、`NSButton` 子视图清零，而 `isVisible` / `visibleItems`
        //    照样报 true（**判据极易假绿**，本工程栽过两次）。
        //    ⇒ 文案重算改由 `L()` 自己的观察依赖负责（见 `AILocalization.swift` 文件头）：
        //      每个在 body 里调过 `L()` 的视图各自登记、各自重算。
        //    ⚠️ 顺带把「切语言会重建本页」那个代价也去掉了 —— 滚动位置 / 选择态都保住。
    }

    private func content(containerWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            if model.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                transcript(containerWidth: containerWidth)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 🔴 聊天区**显式刷页面底色**。
        //  助手行不画气泡底（见 `ChatRowView` 文件头），它的背景就是这一层 ——
        //  所以「AI 返回的背景 = 页面背景」要成立，就必须让这里刷的就是
        //  `MacTheme.pageBackground` 这个常量本身（而不是碰运气指望
        //  `NavigationSplitView` 的默认材质与之同色；材质在系统版本之间会变）。
        .background(MacTheme.pageBackground)
        // 🔴 输入栏用 `safeAreaInset(edge: .bottom)` 挂，而**不是**当 VStack 的最后一个兄弟。
        //  ① 位置变成结构性的：输入栏不再参与 VStack 的高度分配，列表再长也压不下去；
        //  ② 列表内容自动被 inset 一条，最后一条消息不会贴着输入栏。
        //  旧写法（VStack 里排一个 1pt `Divider()` + 输入栏）在语义上没错，但输入栏**自己没有底色**，
        //  加上 Divider 只有 1pt，整块看起来就是「同一张面」—— 用户第一眼的反馈正是「输入框在列表上」。
        //  修饰顺序也有讲究：必须挂在**内容**这一层、`alert` 之前，否则 inset 只作用于空态。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 🔴 选择模式下**输入栏整条让位**给选择栏（2026-09-29，与 iOS 同口径）：
            //    一边勾消息一边发新消息没有意义，而删除这个动作该在底部这一块（光标最容易够到）。
            //    ⚠️ 两者是**互斥**的，不叠加 —— 叠加会让底部同时挂着两排按钮。
            //    ⚠️ 副作用：录音板长在 `MacInputBar` 里，会跟着一起消失 ⇒
            //       `enterSelectionMode` 里必须先把语音收掉（否则录音还在跑、
            //       松手那一刻会凭空发出一条新消息）。
            if model.isSelectionMode {
                ChatSelectionBar(count: model.selectedCount,
                                 onCancel: { model.exitSelectionMode() },
                                 onDelete: {
                                     // 条数在**这一拍**记下（成因见 `pendingDeleteCount`）
                                     pendingDeleteCount = model.selectedCount
                                     isConfirmingDeleteSelection = true
                                 })
            } else {
                MacInputBar()
            }
        }
        // 容器宽度灌给业务层：SwiftUI 自己不读行高，但 `AIChatManager` 每次插行/收尾都会
        // 用 contentWidth 算一遍高度 —— 让它拿到真实宽度，别停在 900 的占位值上。
        // ⚠️ 刻意**不**调 `recomputeAllRowHeights()`：那是「按新宽度把全表重算一遍」，
        // 拖拽窗口时会每帧跑一次，而 SwiftUI 根本不读那些值 —— 纯浪费。
        .onAppear { model.updateContentWidth(containerWidth) }
        .onChange(of: containerWidth) { _, width in model.updateContentWidth(width) }
        // ⚠️ 同样是 `.animation(_:value:)`（与下面落区那条同一个写法），不给整条链挂无条件动画。
        // 🔴 **删除前的二次确认**（2026-09-29 由两条合并成一条）。
        //    为什么留着这一步：**删除不可恢复**（内存里删、库里也删，没有撤销 / 回收站，
        //    见 `AIChatManager.deleteMessages(withIds:)`）。选择模式已经把「删哪几条」交给用户
        //    确认过，但「按错按钮」这一拍仍然只能靠这一步兜住（iOS 侧同样保留）。
        //    ⚠️ 标题里的条数读 `pendingDeleteCount`（不是 `model.selectedCount`，成因见它的注释）。
        .alert(String(format: L("删除选中的 %d 条消息？"), pendingDeleteCount), isPresented: $isConfirmingDeleteSelection) {
            Button(L("取消"), role: .cancel) { }
            Button(L("删除"), role: .destructive) {
                // 失败会自己出声（`deleteSelection()` 内部按成因给「正在回复中」/「已经不在了」）——
                // 这里**不能**静默：点了删除却什么都没发生的观感，与「功能坏了」一模一样。
                model.deleteSelection()
            }
        } message: {
            Text(L("删除后无法恢复。"))
        }
        // 🔴 拖拽落区（2026-09-26 加）。
        //
        // ## 为什么这两条挂在**整条链的最外层**（`.alert` 之后）
        // 要盖住的是「消息列表 **+** 输入栏」两块，而输入栏是 `.safeAreaInset` 挂出来的 ——
        // 挂在 `ScrollView` 上就只盖住上面那一半，落在输入栏上的拖拽连高亮都不出现。
        // 最外层这一层是 `safeAreaInset` 的**复合结果**，它的 frame 就是整个详情页
        // （`render_mac_ui.sh` 那台机器上有一张 `drop_coverage` 专门验这件事：
        //  虚线框必须画到图片最底边，而不是停在输入栏上沿）。
        //
        // ## 「谁来处理这次松手」在拖拽期间会变，所以遮罩必须 `allowsHitTesting(false)`
        // 落区是在**拖拽进行中**才冒出来的 —— 它一旦参与命中测试，
        // 「松手」那一刻的落点视图就会变成它自己（而不是下面那个 `.onDrop` 宿主）。
        // 见 `DropFileOverlay` 文件头第 ① 条。
        .overlay {
            if isDropTargeted {
                DropFileOverlay()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        // ⚠️ 用 `.animation(_:value:)`（与 `RootView` 那条提示条同一个写法），
        //    不给整条链挂无条件动画：落区是「拖进来/拖出去」两拍切换，
        //    淡入淡出就够了，而整页还有流式文本在动，不该被一起加上缓动。
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        // 🔴 **拖拽期间把输入框的字段编辑器挂起**（2026-09-26 实测补的洞）。
        // 字段编辑器（AppKit 的 `_SystemTextFieldFieldEditor`）注册了 `NSFilenamesPboardType`，
        // 而它在视图树里比页面**深** ⇒ 按 AppKit 的落点规则「最深的已注册视图赢」，
        // 把文件拖到聚焦着的输入框上松手会**被它吃掉**（草稿里多一行路径、附件一个不加）。
        // 挂起之后它不接受拖拽，事件继续往上找 ⇒ 落到本页这个 `.onDrop`。
        // ⚠️ 松手/拖出窗口立刻恢复 —— 非拖拽状态下输入框的行为一点没改。
        //    完整取证（四个探针）与取舍见 `ComposerFieldEditorDragSuspender` 文件头。
        .onChange(of: isDropTargeted) { _, targeted in
            if targeted {
                ComposerFieldEditorDragSuspender.suspend()
            } else {
                ComposerFieldEditorDragSuspender.resume()
            }
        }
        // 兜底：视图拆掉时**先恢复再复位**。
        // ⚠️ 这里必须用 `resume()`（= 把类型表装回去 + 清状态），**不能**用 `reset()` ——
        //    `reset()` 是「忘掉自己在挂起」而不是「撤销挂起」，用它会把字段编辑器
        //    永久留成空类型表，症状是「输入框从此拖不进任何东西」，
        //    而且离触发它的那次拖拽隔了很久，根本联想不到这里。
        .onDisappear { ComposerFieldEditorDragSuspender.resume() }
        // ## 落点：只认**文件**，不认别的拖拽载荷
        // `of: [.fileURL]` 已经过滤掉大部分（拖一段文字/一张来自网页的图片不会进来），
        // 但给到的 provider 里仍可能有个别不是文件的 —— 所以①还要逐个体检，
        // 一个都没有就返回 `false`（=「我不接这次拖拽」），让系统自己去找别的落点。
        // ②真正的落地是**异步**的（读盘 + 图片压缩可能要几百毫秒），
        //   而 `onDrop` 的闭包必须同步返回 —— 所以先认下（`return true`）、
        //   再进 `Task` 干活。这也是「松手后附件不是立刻出现」的唯一原因，
        //   不是 bug。
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            // 🔴 选择模式下**不收文件**：输入栏此刻被选择栏顶替，附件加进去用户**看不见**
            //    （要等退出选择模式才冒出来）—— 与其「悄悄收下」，不如让系统直接显示禁止光标。
            guard !model.isSelectionMode else { return false }
            guard providers.contains(where: { $0.canLoadObject(ofClass: URL.self) }) else {
                return false
            }
            Task { @MainActor in
                // 收 URL → 落地 → 收尾，全部复用输入栏「+」那一条（含提示文案口径）。
                // `apply` 是 `@MainActor`：`collectDropped` 里那个后台回调正是靠它搬回主线程。
                ComposerAttachmentPicker.apply(
                    await ComposerAttachmentPicker.collectDropped(providers),
                    to: model)
            }
            return true
        }
        // 🔴 录音浮层（2026-10-03 从 `MacInputBar` 搬到这里）。
        //
        // ## 为什么必须挂在**这一层**
        // 它要盖住的是「消息列表 **+** 输入栏」，而输入栏是 `.safeAreaInset` 挂出来的 ——
        // 挂在列表上就只盖住上面那一半（与 `DropFileOverlay` 那条注释同一个理由）。
        // 而它现在是个**顶着窗口底边的大浮层**（铺满整宽、高 `voicePanelHeight`），
        // 所以只能挂在这里；`MacInputBar` 那一列里根本放不下「盖住自己」的东西。
        //
        // ## 为什么是 `.overlay` 而不是 `.safeAreaInset`
        // inset 的语义是「多了一条栏」，会把列表内容整块顶上去；这里是**浮层** ——
        // 豆包那块也是压在内容上的（上半段是透明的，底下的消息要能透出来）。
        //
        // ⚠️ `isVoiceFinishing` 那一拍也要显示，不能省：识别器吐最终文字最多要等 0.8s
        //    （见 `VoiceInputManager.stopRecording`）。面板若在点结束的**那一拍**就消失、
        //    消息又要等半秒才冒出来，中间那段空白读起来就是「我点了但它没反应」。
        //
        // 🔴 两个回调对应波形两侧那两颗圆钮（2026-10-03 加）：左 ✗ 结束并放弃 / 右 ✓ 结束并发送。
        //    `onSend` 走 `finishVoice()` —— 与点 🎤 期间再点一次是**同一个动作**（识别 → 直接发一条）。
        .overlay(alignment: .bottom) {
            if model.isVoiceRecording || model.isVoiceFinishing {
                VoiceRecordingPanel(levels: model.voiceLevels,
                                    transcript: model.voiceTranscript,
                                    elapsed: model.voiceElapsed,
                                    isFinishing: model.isVoiceFinishing,
                                    onCancel: { model.cancelVoice() },
                                    onSend: { model.finishVoice() })
                .transition(.opacity)
            }
        }
        // ⚠️ 用 `.animation(_:value:)`（与本页其它几条同一个写法），不给整条链挂无条件动画：
        //    录音浮层是「起录 / 收尾」两拍切换，淡入淡出就够了，而整页还有流式文本在动。
        // ⚠️ value 是**两个态的合成**（不是只看 `isVoiceRecording`）：收尾那一拍
        //    `isVoiceRecording` 已经是 false、面板靠 `isVoiceFinishing` 留着，
        //    只看前者会让面板在收尾结束的那一瞬间**直接消失**（没有淡出）。
        .animation(.easeOut(duration: 0.18),
                   value: model.isVoiceRecording || model.isVoiceFinishing)
    }

    // MARK: - 消息列表

    private func transcript(containerWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                // ⚠️ 外面这层 `VStack(spacing: 0)` **只为**在最末尾塞下那颗 0 高的锚点（见 ①）。
                //    `LazyVStack` 套在普通 `VStack` 里**仍然是懒的** —— 上面没有第二个 `ScrollView`，
                //    行照旧按可见性产出，不是「为了锚点牺牲懒加载」。
                VStack(spacing: 0) {
                    // ⓪ 内容**顶边**探针（2026-09-26 加）。与末尾那颗底边锚点对称：
                    //    0 高、`Color.clear`，不占高也不影响行间距（`spacing: 0`）。
                    //    它读到的 y ≈ `-滚动偏移`，于是 `底边 − 顶边` = **内容总高**
                    //    —— 那个「只随内容变化、不随滚动变化」的量（见 `contentHeight`）。
                    //    ⚠️ 位置必须在 `LazyVStack` 那圈 `padding` **之外**：里面的话
                    //    会把顶部 14pt 边距算进总高，白白让它跟着动。
                    Color.clear
                        .frame(height: 0)
                        .background { contentTopProbe }
                    LazyVStack(alignment: .leading, spacing: 14) {
                        // 🔴 `id:` 必须是 **`\.element.id`**（每行的稳定 UUID），
                        //    **不能是 `\.offset`**（2026-09-26 修的，两个用户可见 bug 的根因）。
                        //
                        // 用下标当 identity 是 SwiftUI 里明确的反模式，但它在这里特别毒：
                        // 插入两行时 SwiftUI 得到的信息是「id 0…11 一个都没变，多了 12、13」——
                        // 而真实情况是**每一行的内容都可能不是原来那条**（切会话 = 整表替换）。
                        // 症状有两个，用户都报过：
                        //   ① **发送后列表不跟到底部**，新消息/AI 回复要手动滚才出现；
                        //   ② **切到另一个会话一片空白**，上滑内容才冒出来。
                        // 两者的共同点都是「**没有滚动这类外部事件时，新内容不 materialize**」。
                        // ⚠️ 探针实测（2026-09-26）：`rows` 从 12 涨到 14、末行文本 0→234 字
                        //    （数据层完全正常），而窗口截图**一行新内容都没有**，
                        //    连几何探针都一条没打（内容高度压根没被算进布局）——
                        //    换掉 `\.offset` 之后立刻正常。
                        //
                        //  ⚠️ 下面那个 `.id(row.id)` **仍然要留**：它建立的是「视图身份」，
                        //     而 `scrollTo(row.id)`（搜索定位、编辑态滚动）找的是 `.id()` 修饰符
                        //     给出的锚点。两者值相同，各管一件事，别删。
                        // 🔴 **显示项**而不是「行」（2026-09-28 改）：连续的助手媒体行会被投影成
                        //    一条横向滚动的缩略图条（`ChatTranscriptItem.group`，见 `MediaThumbStrip.swift`）。
                        //    ⚠️ 因此 `ForEach` 的 id 从「每行一个」变成「每项一个」，但**每一项的 id 都取自
                        //    它覆盖的第一行** ⇒ `scrollTo(row.id)` 那套（搜索定位 / 编辑态滚动）仍然有效。
                        ForEach(ChatTranscriptItem.group(model.rows)) { item in
                            switch item {
                            case .row(let row, let index):
                                // 选择模式下外面套一层「勾选圈 + 整行可点」（`ChatSelectionRow`）。
                                // ⚠️ 文本行传**自己的 id**，媒体行传**整组的 id**（见下一个分支）——
                                //    界面上一条代表几行的那个，勾选也必须整组一起，否则删完
                                //    用户会看到「删了一条，可图还剩好几张」。
                                selectable(rowIds: [row.id]) {
                                    rowItem(row: row, index: index, containerWidth: containerWidth)
                                }
                            case .media(let rows, _):
                                selectable(rowIds: rows.map(\.id)) {
                                    mediaItem(rows)
                                }
                            case .userImages(let rows, _):
                                // ⚠️ 用户自己发的多张图 → 一条横向排列（2026-10-08 用户要求）。
                                //    四件事与 `rowItem` / `mediaItem` 同构，理由逐条见
                                //    `userImagesItem` 的注释。
                                selectable(rowIds: rows.map(\.id)) {
                                    userImagesItem(rows, containerWidth: containerWidth)
                                }
                            }
                        }

                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // ① 内容底边探针 + 「回到底部」的滚动锚点 —— **同一个 0 高视图，一体两用**。
                    //
                    //  🔴 它必须在上面那圈 padding **之外**（这就是外面要搭一层 VStack 的原因）。
                    //     进 `LazyVStack`（哪怕 0 高）就会被底部那 14pt padding 顶上来，
                    //     `scrollTo` 永远差 14pt —— 正是 2026-09-22「点按钮还差一截」的根因。
                    //  ⚠️ 探针与锚点**不能拆成两个视图**：两处几何一旦漂移，
                    //     「按钮显隐」和「滚到哪」就会自相矛盾（iOS 侧同款坑见技能第 2 条）。
                    Color.clear
                        .frame(height: 0)                 // 不占高、不影响行间距
                        .id(Self.bottomAnchorID)
                        .background { contentBottomProbe }
                }
                // 🔴 **切会话 ⇒ 让整棵滚动子树换一次身份**（2026-09-26 加，切会话白屏的正解）
                //
                // ## 症状 + 真因（真机 + 真会话取证，2026-09-26）
                // 「在会话 A 里滑一下 → 切到 B → 切回 A ⇒ 一片空白，往上滑一下才出内容」。
                // 复现出来那一组的日志（6 条的会话 ↔ 6 条的会话）：
                // ```
                // SETTLE-BEGIN rows=6 选中=B
                // SETTLE-TICK 0 总高=1989 cb=634          ← 收敛首拍那次同步 scrollTo 落地
                // STATE pin=T cb=588 vh=574 总高=1989     ← 几何说「已贴底」
                // 🚨 一个行都没被创建                       ← 屏幕上什么都没有
                // ```
                // 真因是**两个会话的高度几乎一样** ⇒ 切过去之后偏移**几乎没变**
                // （实测 `偏移 1363 → 1348`，只差 13pt）⇒ `LazyVStack` 没发生过任何滚动，
                // 而它在换数据那一拍已经把旧行全部回收了 ⇒ **旧行没了、新行没建** = 空白。
                // 行数不同的会话互切之所以全都正常（自测版 6 组里 4 组 ✅），
                // 正是因为高度差得远、偏移真的动了。
                // ⚠️ 这与「内容高度有没有量准」**无关**：`总高` 全程都是对的
                //    （1989 / 2147 / …），量准了也没用 —— 坏掉的是**实例化**，不是量高。
                // ☠️ 实测结论：这个状态**程序化滚动救不回来**（`proxy.scrollTo` 与
                //    `NSScrollView.contentView.scroll(to:)` 两条路都试过：后者改了偏移
                //    （`1521 → 1384`）而「哪些行要画」纹丝不动），**只有真实滚轮事件能** ——
                //    也就是用户自己那一下「往上滑」。⇒ 正解不是事后补救，而是
                //    **从源头不进入这个状态**。
                //    （曾为此写过一个 `jiggle` 兜底，实测无效、已删；全过程见技能
                //     `ios-chat-scroll-to-bottom-button` 的 ⑦。）
                //
                // ## 修法
                // 给内容根节点一个**随会话变化**的身份 ⇒ 切会话时 SwiftUI 会**丢掉整棵子树、
                // 重新构建**（全新的 `LazyVStack`，第一次布局就是一次完整的实例化），
                // 不去复用那份已经失效的懒加载状态。
                // ⚠️ 代价换确定性：切会话本来就是「回到最底部重看」，而 `beginSettling`
                //    紧接着就会把它收敛到底 —— 两件事取向一致。
                // ⛔ 别为了「少建一次树」把它删掉：删了那个白屏会原样回来。
                .id(model.selectedConversationId)
            }
            // ② 视口探针。挂在 `ScrollView` **自身**上：量的是视口，不是内容。
            .coordinateSpace(name: Self.scrollSpace)
            .background { viewportProbe }
            .onPreferenceChange(ChatViewportHeightKey.self) { value in
                viewportHeight = value
                updateScrolledToBottom()
            }
            // 🔴 顶边与底边走**同一个**通道 ⇒ 一次回调拿到同帧的完整几何（见 key 定义处的说明）。
            //    ⚠️ `updateScrolledToBottom()` 只在拿到**底边**时调：贴底判据只认底边与视口，
            //    顶边的唯一用途是参与 `contentHeight`（总高）的计算。
            .onPreferenceChange(ChatContentMetricsKey.self) { metrics in
                if let top = metrics.top { contentTop = top }
                if let bottom = metrics.bottom {
                    contentBottom = bottom
                    updateScrolledToBottom()
                }
            }
            .onAppear {
                beginSettling(proxy)
                installScrollMonitor()
            }
            // 切换会话也要收敛：`onAppear` 只在视图**进层级**时来一次，切会话是同一个
            // `transcript` 换数据，它不会再来 —— 少了这条，「切到一个长会话」同样停在半路。
            // ⚠️ 必须排在下面「搜索命中定位」那条**之前**：`open(searchHit:)` 会先切会话
            //    （触发这里的收敛）再挂 `revealTarget`（那条把它关掉）。顺序反了就会出现
            //    「刚定位到命中处、又被收敛拽回列表底部」。
            .onChange(of: model.selectedConversationId) { _, _ in
                beginSettling(proxy)
            }
            // 行数变化 = **发送 / 删除 / 切会话 / 重试** —— 一律回到底部，且**不带条件**。
            //
            // 🔴 这里**刻意不再**问「是不是已经贴底」（2026-09-26 去掉了 `guard isScrolledToBottom`）。
            //    行数变化意味着用户刚做了一个明确动作（最典型的就是「我发了一条」），
            //    此时他要看的就是新内容。旧写法在「内容刚长高过、判据还 false」时
            //    会把这次跟随也拦掉 —— 于是**新发的那条消息根本没被滚到眼前**。
            //    顺手把「用户翻走了」清掉：他都发消息了，当然要回到跟随状态。
            .onChange(of: model.rows.count) { _, _ in
                userScrolledAway = false
                scrollToBottom(proxy, animated: true)
            }
            // 收流那一拍：最后一行的操作栏长出来，内容底边**凭空**下移约 31pt。
            //
            // 🔴 必须单独跟一条（2026-09-26 真机探针抓到的）：`ChatRowView.showsActionBar`
            //    里有 `guard !row.block.isStreaming else { return false }`（**行自己的**标志，
            //    不是全局 `isStreaming`）—— 正在长的那一行不挂操作栏，因为栏在行尾、
            //    正文每来一个字它就往下跳一格，看着抖。所以「AI 说完了」这件事本身
            //    就会让最后一行再长高一整条 —— 而此刻 `rows.count` 与最后一行文本
            //    **都没有变**，上面那两条 onChange 一个都不触发。
            //    真机实测：收流前 `METER d=0`（精确贴底），收流后 `d=31` —— 容差是 30，
            //    差那 1pt 判据就翻面 ⇒ 列表停在差 31pt 处，最后那条回复的操作栏
            //    （复制/朗读/重试/分享）被输入栏吃掉一半。截图可见痕迹就在最后一行下方。
            //  ⚠️ 别指望 `METER` 自己纠回来：几何探针只负责**判**，不负责**滚**。
            //  ⚠️ 也刻意不用「内容一变就补一次纠偏」那种自愈写法 —— 滚轮事件监听
            //     看不见**拖滚动条**（那不是 wheel 事件），自愈会把拖条往上翻的用户
            //     一路拽回底部。宁可只补我们已知会变动的那一拍。
            .onChange(of: model.isStreaming) { _, streaming in
                guard !streaming, !userScrolledAway else { return }
                scrollToBottom(proxy, animated: true)
            }
            // 流式增长：用户**没有自己翻走**就一直跟（不带动画 —— 带动画会与打字机节奏打架）。
            //
            // 🔴 判据从 `isScrolledToBottom` 换成 `!userScrolledAway`（2026-09-26）。
            //    旧判据会被「内容正在长高」本身打翻 ⇒ 跟随在**第一个 chunk 之后**就永久停摆，
            //    而这正是用户报的「AI 返回的也要手动滚」。内容长高**不是**用户的意图，
            //    不能拿它当「用户走开了」的证据。
            .onChange(of: model.rows.last?.block.text) { _, _ in
                guard model.isStreaming, !userScrolledAway else { return }
                scrollToBottom(proxy, animated: false)
            }
            // 🔴 第三条跟随：**内容总高变大**就补一次贴底（2026-09-26，切走再切回空白的正解）。
            //
            // ## 它是怎么被逼出来的
            // 底层几何曲线显示：切到一个长文档会话时，收敛**一开始就是贴底的**
            // （曲线里 `离底=-134` 连着十来拍），问题出在它之后 —— `LazyVStack` 到 **1.4s**
            // 才把底部那一段（一屏高的大代码块）量出来，总高从估计值修正到真实值
            // （`8858 → 9517`，+659pt），而**这一拍没有任何既有机制会接手**：
            // 行数没变（不是发送/删除）、`isStreaming` 为 false（不是流式）⇒
            // 上面三条 `onChange` 一条都不触发 ⇒ 列表停在离真底一屏处
            // ⇒ 用户看到「切回来一片空白 / 停在半路，必须往上滑一下才出内容」。
            //
            // ## 🔴 判据必须是「总高」，**不能**用底边那个量
            // 第一版就是盯底边写的（`onChange(of: contentBottom)` + `new > old`），
            // 切会话确实治好了，但短行夹具当场抓到回归：**⑮「上滑 90pt」之后偏移只动了 1pt
            // —— 用户自己的滚动被拽回去了**。
            // 成因：底边那**一个**量区分不了「内容长高」（底部往下长）与「用户上滑」
            // （内容整体往下平移）—— **两者都让底边变大**。加 `new > old` 挡不住（那正是共同形状），
            // 用「刚才是我们自己滚的」时间窗也挡不住（流式期间每帧都在滚，窗口被不断续期）。
            // 而 `contentHeight` 是**总高**：只随内容变化、不随滚动变化 ⇒ 上滑时纹丝不动 ✓
            // （与文件头那条老教训同源 —— **内容变化 ≠ 用户操作**。）
            //
            // ## 三道闸门
            // - `isSettling`：收敛期间交给循环（它每 80ms 滚一次，比这里勤）；
            // - `userScrolledAway`：用户翻走了就别打扰（何时回来由他决定）；
            // - `isStreaming`：流式交给上面那条逐 chunk 跟随。
            // ⚠️ 阈值用 `> old + 1` 而不是 `!=`：布局在滚动/回收行时会抖动零点几 pt，
            //    不设阈值会让这条在滚动过程中反复触发。
            .onChange(of: contentHeight) { old, new in
                guard !isSettling, !userScrolledAway, !model.isStreaming else { return }
                guard new > old + 1 else { return }
                scrollToBottom(proxy, animated: false)
            }
            // 进入就地编辑：把那一行滚进视野。
            //
            // 🔴 必须有：编辑**最新那一条**时，那一行本来就在视口底部，编辑器一长出来，
            //    下面那行「取消 / 保存」就落到视口外面去了 —— 点了编辑却看不见保存键。
            // 🔴 先 `endSettling()`，与搜索定位同理（`reveal` 里那句）：收敛循环会在 1.5s 内
            //    反复 `scrollToBottom`，不关掉就会把这次滚动又拽回列表底部。
            // ⚠️ 还得**延迟一拍**再滚：`editingRowId` 变化的那一拍编辑器还没量高，
            //    立刻 `scrollTo` 会停在旧高度上（结果差一行编辑器）。这与「链上的顺序」
            //    是两件事：顺序只解决谁最后拍板，不解决「布局好了没有」。
            .onChange(of: model.editingRowId) { _, id in
                guard let id else { return }
                endSettling()
                editScrollTask?.cancel()
                editScrollTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            // 搜索命中定位（`ChatModel.revealTarget`）。
            // 🔴 必须排在**最后**：切会话时上面那条「贴底才跟随」也会滚一次
            //    （换会话 = rows 换了，若原先贴着底就会滚到底）—— 这里得是最后拍板的那个，
            //    否则刚滚到命中处又被拽回列表底部，搜索等于白点。
            .onChange(of: model.revealTarget) { _, target in
                guard let target else { return }
                reveal(target, proxy: proxy)
            }
            .onDisappear {
                revealFlashTask?.cancel()
                editScrollTask?.cancel()
                endSettling()
                // 🔴 监听器必须卸：它比视图活得久（本地监听挂在 App 上），
                //    留着就是「闭包持有一份已经离场的视图状态」——换窗口/重进会话时
                //    会攒下多个监听器，每个都往旧 storage 里写。
                removeScrollMonitor()
                // 窗口关掉 / 视图离场时，录到一半的语音要丢掉：麦克风还开着、音频 tap 还装着，
                // 比「多说一句被吞掉」严重得多。（没在录时是空操作。）
                model.cancelVoice(toast: nil)
            }
            // ③ 「回到底部」。`overlay` 让它在列表**之上**、也不参与列表布局。
            //    底部留白只要一个固定间隙 —— 视口 frame 本身已经到输入栏顶边了（见文件头实测）。
            .overlay(alignment: .bottomTrailing) {
                ScrollToBottomButton { scrollToBottom(proxy, animated: true) }
                    .padding(.trailing, MacTheme.scrollToBottomMargin)
                    .padding(.bottom, MacTheme.scrollToBottomGap)
                    .opacity(showsScrollToBottomButton ? 1 : 0)
                    .scaleEffect(showsScrollToBottomButton ? 1 : 0.86)
                    // 触摸权与淡出**同时**交还（不等动画结束）——
                    // 那 0.18s 里它不该再吃掉本该给列表的点击。iOS 侧对应 `isUserInteractionEnabled`。
                    .allowsHitTesting(showsScrollToBottomButton)
                    .animation(.easeOut(duration: 0.18), value: showsScrollToBottomButton)
            }
        }
    }

    // MARK: - 几何探针（贴底判据的两个输入）

    /// 视口高度：`ScrollView` 自身 frame 的高度（= 滚动内容可见区域的底边）。
    /// 用 `Color.clear` 是为了「只发偏好、不画东西」。
    private var viewportProbe: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: ChatViewportHeightKey.self, value: geometry.size.height)
        }
    }

    /// 内容**顶边**：在滚动坐标系里的 `minY`（≈ `-滚动偏移`）。
    /// 与底边探针配对，`底边 − 顶边` 就是**内容总高**（见 `contentHeight` 的说明）。
    /// ⚠️ 它与底边探针写的是**同一个** `ChatContentMetricsKey`（只写 `top` 那一格），
    ///    这样一次 `onPreferenceChange` 就能同时拿到两条边的当帧值 —— 分成两个 key 会让
    ///    「总高」在通道不同步的中间态里虚增，把用户的上滑误判成「内容长高」（key 定义处有详述）。
    private var contentTopProbe: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: ChatContentMetricsKey.self,
                value: ChatContentMetrics(
                    top: geometry.frame(in: .named(Self.scrollSpace)).minY,
                    bottom: nil
                )
            )
        }
    }

    /// 内容底边：在**滚动坐标系**里的 `maxY` —— 也就是「内容底边此刻落在视口的哪一行」。
    /// 挂在那颗 0 高的底边锚点上（①），所以读到的是**内容底边**本身，不是最后一行的底边。
    private var contentBottomProbe: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: ChatContentMetricsKey.self,
                value: ChatContentMetrics(
                    top: nil,
                    bottom: geometry.frame(in: .named(Self.scrollSpace)).maxY
                )
            )
        }
    }

    /// 由几何量刷新贴底状态。
    ///
    /// 滚动 → 布局重算 → 偏好变化，所以这个函数**每帧都可能被调**；里面那个 `if`
    /// 是必须的：不加的话每帧都会写一次 `@State` → 每帧一次重绘。
    ///
    /// 🔴 **判据必须带下界 `contentBottom > 0`**（2026-09-26 加，切会话空白那个 bug 的一半）。
    /// 只写上界（`<= tolerance`）时，「视口跑到内容**下方**」（`contentBottom` 变成负数）
    /// 也会被判成「已贴底」—— 那正是 LazyVStack 布局失准时的病态中间态：
    /// 肉眼是一片空白，判据却说「到底了」⇒ 收敛收手、按钮也不显，用户只能自己上滑救。
    /// 正常贴底时 `contentBottom == viewportHeight`（正数几百）；「内容不足一屏」时
    /// `contentBottom == 内容高`（同样为正）—— 两种健康局面都不会被这个下界误伤。
    ///
    /// 🔴 **第三条闸门 `hasMaterializedRows`**（2026-09-26 加，切会话白屏的正面判据）。
    /// 前两条都只盯着几何，而几何是 `LazyVStack` 报的**估计值** —— 它可以在
    /// **一行都没创建**的情况下照样说「贴底」。这时若判成 `pinned`：
    /// ① 收敛循环当场收手，从此再没有任何机制会去滚一下（= 白屏永久化）；
    /// ② 跟随状态被误标成「已在底部」。⇒ 必须由**渲染本身**再确认一次。
    private func updateScrolledToBottom() {
        guard viewportHeight > 0 else { return }   // 还没量到（首帧前）→ 保持原值
        let pinned = contentBottom - viewportHeight <= Self.bottomTolerance
            && contentBottom > 0
            && hasMaterializedRows
        if pinned != isScrolledToBottom { isScrolledToBottom = pinned }
        // 回到贴底 → 把跟随权交还给「自动跟随」。
        // 触发场景有三：用户自己滚到底、点了「回到底部」、发送/切会话后的那次强制滚。
        // ⚠️ 流式期间内容长高会让 `pinned` 变 false，但那只影响按钮显隐 ——
        //    `userScrolledAway` 只由滚轮事件置位，**不会被内容变化误清**（这正是这次修的核心）。
        if pinned, userScrolledAway { userScrolledAway = false }
    }

    /// 「回到底部」是否可见。
    ///
    /// 🔴 **判据是「用户自己翻走了」这个意图，不是几何量**（2026-09-26 改）。
    /// 用 `!isScrolledToBottom` 时的毛病：流式回复**每长高一点**判据就翻一次面，
    /// 于是这颗按钮在 AI 输出期间反复闪；而它现在的语义
    /// 「你可能想回来」本来就该由**用户的操作**触发，不是由内容在长触发。
    /// ⚠️ 几何量仍然负责**清掉**这个意图（滚到底 = 意图达成），见 `updateScrolledToBottom()`。
    ///
    /// 除了「用户翻走了」，还有四条边界：
    /// ① 空会话不显示（没有可回的）；
    /// ② 还没量到几何时不显示（否则首帧会闪一下）；
    /// ③ **贴底收敛期间不显示**（2026-09-22 加）—— 进会话头几百毫秒里列表本来就还没
    ///    贴到底，这时候亮出按钮，用户每次启动都会看见它闪一下；那不是「你可以回到底部」
    ///    的提示，只是收敛还没跑完。
    /// ④ **录音板顶起来时不显示**（2026-09-24 加）：录音板是输入区的一部分，它一出现
    ///    `safeAreaInset` 就变高、`ScrollView` frame 随之变矮；而滚动位置没动 ⇒
    ///    几何判据会凭空多出面板那一截（约 140pt），一颗按钮毫无理由地冒出来。
    ///    （改用 `userScrolledAway` 后这条其实已经天然不受影响，但录音结束时
    ///    面板收起同样会让几何抖一下 —— 留着这道闸门，语义也仍然对。）
    /// 「内容不足一屏」**不需要**单独判 —— 那时用户根本没得翻。
    private var showsScrollToBottomButton: Bool {
        guard !model.isEmpty, viewportHeight > 0, !isSettling else { return false }
        guard !model.isVoiceRecording, !model.isVoiceFinishing else { return false }
        // ⑤ **选择模式下不显示**（2026-09-29 加）：它浮在列表右下角、正好压在最后几行上，
        //    会挡住那里的勾选；而且「回到最新」不是挑消息时要做的事（iOS 那边同样收掉它）。
        guard !model.isSelectionMode else { return false }
        return userScrolledAway
    }

    private var emptyState: some View {
        // 🔴 居中的基准是**主块**（图标 + 标题 + 副文案），不是「主块 + 引导」整块（2026-10-26）。
        //    整块居中时，引导那一截把视觉重心往下拽 ⇒ 标题看起来偏上；用户要的是
        //    「开始一个新对话」这一块**自身**在可视区上下居中（Mac 端）。
        //    ⇒ 引导改走 `overlay`：overlay 不参与父级布局，主块的居中位置与「有没有引导」无关。
        //    ⚠️ 代价：引导画在主块框**外面**（SwiftUI 的 overlay 不裁剪）。所以窗口被拖到
        //       极矮（主块 + 44 + 引导 ≈ 220pt 都放不下）时，它可能贴到输入栏上。
        //       正常窗高不会撞；真要兜底就得上 `GeometryReader` 量可用高度，届时再说。
        //    间距 44（原来是 24）是用户 2026-10-26 的要求「距离再拉开一些」。
        let guideGap: CGFloat = 44

        return VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(MacTheme.ui(40))
                .foregroundStyle(.tertiary)
            Text(L("开始一个新对话"))
                .font(.title3)
            Text(L("在下面输入你的问题，⌘N 可以新建一个对话。"))
                .font(MacTheme.ui(12))
                .foregroundStyle(.secondary)
        }
        // 🔴 未配置模型时才多这一块（iOS 端同款文案与顺序，见 `AIModuleViewController.landingStack`）
        .overlay(alignment: .bottom) {
            if !hasModel {
                // ☠️ 这里**不许**用 `alignmentGuide` 定位（2026-10-26 真机踩过，见 VERIFY-PROBES §40.6）：
                //    `if` 会把子视图包进 `_ConditionalContent`，而那一层**不转发 alignment guide**
                //    ⇒ 定位退化成「普通底对齐」，引导叠在标题和副文案上（用户截图就是这个）。
                //    ‼️ 单写一个不带 `if` 的探针是**验不出来**的 —— 它恰好能过。
                //    ✅ 改用普通 alignment 搭一个 0×0 锚点：锚点底边贴在主块底边（`.bottom` 对齐），
                //      引导再从锚点**顶部**往下 offset guideGap —— 全程只用到默认 guide。
                Color.clear
                    .frame(width: 0, height: 0)
                    .overlay(alignment: .top) {
                        // ⚠️ 必须 `fixedSize`：overlay 给的宽度只有锚点那么宽（0），
                        //    否则这句长文案会被压成一列字
                        modelGuide.fixedSize().offset(y: guideGap)
                    }
            }
        }
        .padding(40)
        .onAppear { syncHasModel() }
        .onReceive(NotificationCenter.default.publisher(for: AIConfig.didChangeNotification)) { _ in
            syncHasModel()
        }
    }

    /// 读一次配置、同步到 `@State` **和**那个静态初值（后者让下一个本页实例不再读盘）。
    private func syncHasModel() {
        let value = AIConfig.hasModel
        ChatDetailView.lastKnownHasModel = value
        hasModel = value
    }

    /// 空态里的「去哪儿配模型」引导（2026-10-26）。
    ///
    /// - 文案与 iOS 逐字相同（同一个 `L()` key），只是一个 UILable 一个 SwiftUI `Text`；
    /// - 按钮落点是**设置窗的「模型」页 + 直接弹出的「添加模型」表单**（2026-10-26 追加）：
    ///   这颗钮只会在**一个模型都没有**时出现，所以「清单 → 再点添加」那一跳纯属多余。
    private var modelGuide: some View {
        // spacing 10 与外层 VStack 一致；两行之间不再额外收紧（与 iOS 那个 UIStackView 同款）
        VStack(spacing: 10) {
            Text(L("还没有配置模型，先配置一个才能开始对话"))
                .font(MacTheme.ui(12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L("去配置模型")) {
                // ⚠️ 顺序要紧：先记「打开后落到哪一页」，再开窗。
                //    反过来（先开窗再记）会在窗**刚建**的那一拍丢掉请求 —— 那时
                //    `MacSettingsView.onAppear` 已经跑完了，`onReceive` 还没注册。
                MacSettingsRouter.request(.model, openAddForm: true)
                openSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    // MARK: - 小工具

    /// 把**搜索命中的那一行**露出来：滚到它 + 圈一下再淡出。
    ///
    /// - `anchor: .center`：命中常在长会话的深处，停在视口中间比停在边缘好认
    ///   （贴边时用户分不清「滚到了」还是「滚过了」）。
    /// - 这次滚动**带**动画（0.25s）：距离可能很长，瞬移会让人丢掉位置感；
    ///   ⚠️ 而「自动跟随」那种场景是不带动画的（那里怕和打字机打架）——
    ///   两者诉求相反，别想着统一成一个。
    private func reveal(_ target: ChatModel.RevealTarget, proxy: ScrollViewProxy) {
        // 收敛先让位：搜索定位是「用户明确要去看某一条」，不能被「拉到底」抢走。
        endSettling()
        // 同上，跟随也要让位：定到命中处之后，若 AI 恰好在流式输出，
        // 「跟随到底」会立刻把用户从命中那条拽到列表底 —— 搜索就白点了。
        // ⚠️ 排在 `onChange(rows.count)` **之后**执行（那条 onChange 的注册顺序在它前面），
        //    所以这次置位不会被「切会话 ⇒ 清掉翻走标记」覆盖。
        userScrolledAway = true
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(target.rowId, anchor: .center)
        }
        revealedRowId = target.rowId
        // 上一次的收尾任务先取消：连着点两条结果时，前一次的「延时清零」
        // 会把后一次刚点亮的高亮提前抹掉（表现为「点了没反应」）。
        revealFlashTask?.cancel()
        revealFlashTask = Task { @MainActor in
            // 🔴 **晚一拍补一次同样的滚动**（2026-09-26 加，为 `.id(selectedConversationId)` 兜底）。
            //    跨会话点搜索命中时 `selectedConversationId` 变了 ⇒ 内容根节点换身份、
            //    整棵子树重建；而上面那次 `scrollTo` 与这次重建**在同一个更新周期**里发出，
            //    目标行很可能还没进树（`scrollTo` 找不到那个 id 就是空操作）⇒ 搜索定位会白点。
            //    等一帧再滚一次即可。第一次若已经成功，这一下是**同目标**的重复滚动
            //    ⇒ 位置不动、不抖，纯保险。
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(target.rowId, anchor: .center)
            }
            // 高亮闪一下再淡出。
            try? await Task.sleep(nanoseconds: UInt64(MacTheme.revealDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { revealedRowId = nil }
        }
    }

    /// 滚到列表**真正的底**（「回到底部」、新消息跟随、流式跟随、收流纠偏四处共用）。
    ///
    /// 🔴 目标是那颗 0 高的**底边锚点**，**不是最后一行**。
    /// `scrollTo(最后一行, anchor: .bottom)` 对齐的是「最后一行自己的底边」，而行外面还有
    /// 内容容器那 14pt 底边距 —— 停下时内容底边仍在视口下方 14pt，用户还能再滑一点
    /// （2026-09-22 报的 bug，探针实测 `METER d=14`；换成锚点后 `d=0`）。
    /// 一句话：**行锚点 = 停在最后一条消息上；内容底边锚点 = 停在最底部。**
    /// ⚠️ 与 iOS 的差异：iOS 那边 `scrollToRow` 停在 insets 之上就是滚动上限（没这个问题），
    ///    别照抄那边的印象回来「顺手改回最后一行」。
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard !model.isEmpty else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    /// 收敛一拍的动作。`tick` = 第几拍（从 0 起，偶数拍滚行锚点、奇数拍滚底边锚点）。
    ///
    /// ## 🔴 为什么必须滚两下，而且必须**按拍交替**
    /// ### 为什么需要「行锚点」（长文档夹具实测抓到的）
    /// 只滚底边锚点时，「切到一个长文档会话」的收敛**永远差近一屏**。
    /// 探针实测（`STARRY_FIXTURE_DOC=1 STARRY_FIXTURE_ROWS=40`，视口 720）：
    /// ```
    /// ⑪长→短     内容=9419 偏移=8168 离底=531
    /// ⑭切回短会话 内容=9571 偏移=8334 离底=517
    /// ```
    /// 而同一台探针里「贴底」的基准读数是 `离底=-134` ⇒ **实际差 ≈ 651pt ≈ 0.9 个视口**。
    /// 成因：底边锚点在 `LazyVStack` **外面**，它的位置 = 内容容器的高度；而底部那一段
    /// （大代码块、不折行的表格单元格）还没 materialize 时，`LazyVStack` 报的是**估计高度**
    /// 且估得偏小 ⇒ `scrollTo(锚点, .bottom)` 滚到的是一个**不存在的位置**。
    /// 这个夹具里一行就 ≈750pt（比视口还大），所以「估错一行」就等于「差一屏」。
    /// ⚠️ 短行夹具里「估计高度 ≈ 真实高度」，一次就滚到位 —— 这个 bug 因此躲过了上一轮验收
    ///    （又是那条铁律：**夹具形状不对，探针就是在验别的东西**）。
    ///
    /// ### 为什么不能在同一拍里连滚两下
    /// 第一版就是「一拍里先 `scrollTo(最后一行)` 再 `scrollTo(底边锚点)`」，**毫无改善**：
    /// ⑪/⑭ 的离底仍是 `569 / 546`，与「只滚底边锚点」那版逐位同级。
    /// ⇒ 说明**同一拍内的多次 `scrollTo` 只有最后一次生效**（否则行锚点至少会把偏移推进一点）。
    /// 所以只能**分拍**：行锚点先把底部**拽出来**（`scrollTo(行的 id)` 会强制
    /// `LazyVStack` materialize 那一行、量出真实位置），再用底边锚点**精确贴底**。
    ///
    /// ## 🔴 2026-10-20：行锚点改成**按需要**触发，不再「按拍交替」
    /// 用户报「Mac 启动后会话列表上下跳动几秒」。连拍取证（40 帧 / 5s，逐帧相关性）：
    /// 内容在**两个离散位置**之间来回跳，振幅 `29px @2x = 14.5pt`，持续 **2.3s**
    /// （= `settleWindow` 到点才收手）。
    /// 成因就是无条件交替：两个锚点**天然差 14pt**（内容容器底边距，见 `scrollToBottom`），
    /// 一旦已经到底，偶数拍回到「行锚点」、奇数拍回到「底边锚点」= 原地来回跳 14pt；
    /// 而且 `contentBottom` 跟着翻 ⇒ `stableTicks` 永远数不到 3 ⇒ 只能耗到窗口结束。
    /// ⇒ 现在只有两处用行锚点：**首拍**（必须先把最后一行拽出来量真实位置）
    ///   与**「离底还远且底边两拍没动」**（底边估小了，只滚底边推不动的那个僵局）。
    ///    其余各拍一律底边锚点 ⇒ 位置单调收敛、几何不再来回翻。
    /// ⚠️ 别改回「`tick % 2`」——那正是这次跳动的原因（有实测帧序列，见
    ///    `.workbuddy/memory/2026-10-20.md`）。
    ///
    /// ⚠️ 两下都**不带**动画：收敛期间要与后续每一拍衔接，带动画会让位置在半路被下一拍截断。
    /// ⚠️ 只在**收敛**里用（`beginSettling`）。「发送跟随」「回到底部」那些场景视口本就在底部、
    ///    内容早已量全，底边锚点是准的 —— 多滚一下只会平白多一次 `scrollTo`。
    private func settleScroll(_ proxy: ScrollViewProxy, needsMaterialize: Bool) {
        if needsMaterialize, let lastId = model.rows.last?.id {
            proxy.scrollTo(lastId, anchor: .bottom)
        } else {
            scrollToBottom(proxy, animated: false)
        }
    }

    // MARK: - 贴底收敛（进入会话时）

    /// 进入会话：开始收敛，把列表持续纠到**真**贴底为止（成因与取舍见文件头）。
    ///
    /// 为什么不是「滚一次就完事」：`scrollTo(锚点)` 对齐的是**那一刻**锚点所在的位置，
    /// 而 `LazyVStack` 首帧给的是**估计高度** —— 真实行高（尤其大代码块、长文档）要到
    /// 后面几帧才长出来，锚点随之往下跑，于是「滚到底」变成「停在半路」。
    /// 真机（967×665、上千字 Markdown 会话）实测停在约 1/4 处，而短内容的探针场景
    /// 因为估计≈真实，一次就能到底 —— 这正是这个 bug 一直躲过离线验收的原因。
    ///
    /// ## 🔴 一拍要滚**两下**（2026-09-26，长文档夹具抓到的「差近一屏」）
    /// 见 `settleScroll`：**行锚点先把底部 materialize 出来，底边锚点再精确贴底**。
    /// 只滚底边锚点时，长文档会话的收敛停在离真底 ≈651pt（≈0.9 个视口）处 ——
    /// 用户看到的就是「切回来停在半路 / 一片空白，往上滑一下才出内容」。
    /// ⚠️ 短行夹具里估计高度≈真实高度，这条复现不出来，所以上一轮验收漏掉了它。
    ///
    /// 循环里三条退出条件，缺一不可：
    /// ① **几何贴底** → 达到目的，收手；
    /// ② **内容底边连着 `settleStableTicks` 拍没动**（`stableTicks`）→ 布局稳定了，
    ///    再滚也不会有变化，收手。这一条是「用户没在滚」的自然判据 ——
    ///    换成「距离变大 = 用户上滚」会误伤：内容长高时距离本来就会变大（见常量注释）。
    ///    🔴 **且只在「底边已落在视口范围内」时才认**（2026-09-26 加的闸门）：离底还远时
    ///    「不变」多半是「底部那一屏还没 materialize、推不动」，收手就会把错位留在屏幕上。
    /// ③ 兜底：`settleWindow` 到点。
    // MARK: - 一行 / 一组媒体（2026-09-28：显示项投影的两个分支）

    /// 选择模式下给一行（或一组）套上**勾选层**；不在选择模式时**原样返回**。
    ///
    /// - Parameter rowIds: 这一项代表的**全部**行 id —— 文本行是它自己，媒体组是组内所有行。
    ///
    /// ⚠️ 这个 `if/else` 会让整棵行子树在切模式时换一次身份（SwiftUI 按结构位置认视图）⇒
    ///    切进 / 切出选择模式时列表会整体重建一次。这是**可接受**的：重建顺带把懒加载状态
    ///    重置一遍（正是「切会话白屏」修法里想要的那个性质），而且此刻用户刚点完删除，
    ///    没有「保持滚动位置」的诉求。⛔ 别为了「少重建一次」改成恒定套一层 ——
    ///    恒定套会让不在选择模式时也多一层 `HStack`，行内命中区与最大宽度跟着一起变。
    @ViewBuilder
    private func selectable<Content: View>(rowIds: [UUID],
                                           @ViewBuilder content: @escaping () -> Content) -> some View {
        if model.isSelectionMode {
            // 整组都已勾上才算「选中」：组内只要有一条没勾，界面上就显示成未选（点一下补齐整组）
            ChatSelectionRow(isSelected: rowIds.allSatisfy { model.selectedRowIds.contains($0) },
                             onToggle: { model.toggleSelection(rowIds: rowIds) },
                             content: content)
        } else {
            content()
        }
    }

    /// **一行**（原来 `ForEach` 里那套原样搬进来；除了 `row` / `index` 变成参数，其余一字未改）。
    @ViewBuilder
    private func rowItem(row: AIChatRow, index: Int, containerWidth: CGFloat) -> some View {
        let retryTarget = retryRowIndex(for: index)
        ChatRowView(
            row: row,
            containerWidth: containerWidth,
            isStreaming: model.isStreaming,
            isSpeaking: model.speakingRowId == row.id,
            canRetry: retryTarget != nil,
            isHovered: hoveredRowId == row.id,
            isEditing: model.isEditing(rowId: row.id),
            editingText: editingBinding,
            onCopy: { copy(row.block.text) },
            onSpeak: { model.toggleSpeech(rowId: row.id, text: row.block.text) },
            onRetry: { if let target = retryTarget { model.regenerate(rowIndex: target) } },
            onContinue: { model.continueGeneration(rowIndex: index) },
            // 「删除」→ 进「多选删除」选择模式（2026-09-29）。四个删除入口（右键菜单 /
            // 助手文本栏 ⋯ / 媒体栏 ⋯ / 用户侧栏 ⋯）统一走这一条，⛔ 别在这里直接调删除 ——
            // 删不可恢复，「我想删的其实是另一条」只能靠选择模式先看见再兜住。
            onRequestDelete: { model.enterSelectionMode(startingAt: row.id) },
            // 「⋯ → 引用」：把这一条挂到输入框上方（模型层自己会判「空正文 / 系统提示」两种情况）
            onQuote: { model.beginQuote(rowId: row.id) },
            onBeginEdit: { model.beginEdit(rowId: row.id, text: row.block.text) },
            onCommitEdit: { model.commitEdit() },
            onCancelEdit: { model.cancelEdit() },
            // ⚠️ 移出时**只清自己**（理由见 `hoveredRowId` 的注释）
            onHoverChange: { inside in
                if inside {
                    hoveredRowId = row.id
                } else if hoveredRowId == row.id {
                    hoveredRowId = nil
                }
            },
            // 点图片 / 视频封面 → **另开一个窗口**预览（`MediaPreviewWindowCenter`）。
            // 行本身只负责「报告点了谁」，开不开窗由这一页决定 ——
            // 行是纯视图（渲染台直接构造它），不该自己持有一个窗口。
            // ⚠️ 已开着的同一张媒体再点：那边只把窗口提到前面，不会再开一个。
            onOpenMedia: { MediaPreviewWindowCenter.shared.open($0) },
            // 点文件卡片 → 在**会话页右侧那块面板**里打开（`ChatModel.openLocalInPanel`），
            // 与图片/视频「另开一个窗口」是两条路（见 `ChatRowView.onOpenFile` 的注释）。
            // ⚠️ 名字必须传 `row.block.text` —— 用户当初发的那份文件名；附件落盘时磁盘名被
            //    换成了 UUID（`52EDE56F-….xlsx`），拿它当标签标题用户认不出来。
            onOpenFile: { url in
                model.openLocalInPanel(url, displayName: row.block.text)
            },
            // 思考块头部被点（2026-10-20）→ 模型层翻展开态（行高重算 + 刷新都在那边）
            onToggleThinking: { model.toggleThinking(rowId: row.id) },
            // 点气泡里那条引用 → 滚到被引用的原消息 + 圈一下（2026-10-21，Mac 补上与
            // iOS `revealMessage` 对等的能力）。模型层内部复用搜索定位那套 `RevealTarget`，
            // 原消息已不在时会飘一条交代（与 iOS 同口径）—— 那些都归 `ChatModel`，
            // 这里只负责「把 quote 递过去」。
            onRevealQuoted: { model.revealQuotedMessage($0) },
            // 选择模式下这一行不画操作栏（见 `ChatRowView` 里那条注释）。
            // ⚠️ 顺序按 `ChatRowView` 的**声明顺序**排 —— 带默认值的参数乱序直接编译错。
            isSelectionMode: model.isSelectionMode
        )
        .id(row.id)
        // 🔴 行**存活追踪**（2026-09-26 加，切会话白屏那个 bug 的正面判据）。
        //   白屏的两类成因（① 行压根没 materialize ② 行建了但画在视口外）
        //   只有这一条能分开 —— 几何量在两种情况下都长得像「正常」。
        //   ⚠️ 钥匙用 **id 不用下标**：切会话是整表替换，新旧两批行的下标
        //      完全一样（都是 0…5），若 `onAppear`/`onDisappear` 的派发顺序是
        //      新先旧后，同一组下标会 insert 完又被 remove ⇒ 集合变空 = 假读数。
        //   ⛔ 这是**正式修复的一部分**（`hasMaterializedRows` 的三处闸门靠它），
        //      与日志无关，别当插桩删掉。
        .onAppear {
            liveRowIds.insert(row.id)
        }
        .onDisappear {
            liveRowIds.remove(row.id)
        }
        // 搜索命中定位：被点到的那条消息圈一下（见下面的 `reveal`）。
        // 用 `.background` 而不是插一个视图进去 —— 那里加东西会动布局，
        // 而这一圈只是「临时指一下」，绝不能改变任何一行的高度。
        .background {
            if revealedRowId == row.id {
                RoundedRectangle(cornerRadius: MacTheme.revealRadius)
                    .fill(MacTheme.revealFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: MacTheme.revealRadius)
                            .strokeBorder(MacTheme.revealBorder,
                                          lineWidth: MacTheme.revealBorderWidth)
                    )
                    // 负边距 = 向外扩一圈：贴着文字画框看起来像「选中了文本」
                    .padding(MacTheme.revealPadding)
            }
        }
    }

    /// **一组连续的助手媒体行** → 一条横向滚动的缩略图条（`MediaThumbStrip`），
    /// 条下面挂一条**只有分享 + ⋯ + 时间**的操作栏（2026-09-29 用户要求）。
    ///
    /// 🔴 四件事与「一行」那套刻意保持一致（少一件都是坑）：
    /// ① **`.id(首行 id)`**：`scrollTo` 找的是 `.id()` 锚点 —— 用首行 id 才能让「按行定位」
    ///    至少仍然指向**同一个位置**（组从第一条的位置开始长）。
    /// ② **整组的行存活都要报**：组内每一行的 id 都进/出 `liveRowIds`。
    ///    `hasMaterializedRows` 是「切会话白屏」那三条闸门之一 —— 漏报等于让
    ///    「只有媒体行的会话」永远过不了闸门（那正是白屏判据的用途）。
    /// ③ **时间小字只取首行**：媒体行原本由 `ChatRowView` 画那条 meta 小字
    ///    （助手侧才画），合成一条之后它天然只剩「这一组的报时」一个语义 ——
    ///    而连续媒体行本来也不可能触发「隔了 ≥5 分钟」的报时。
    /// ④ **操作栏属于整组**（见 `ChatRowMediaActionBar`）：连续媒体行已经合成一条，
    ///    「一条一栏」在这里根本摆不开 —— 组内第 2 张起就不再是独立的一行。
    /// ⑤ **选择模式下整组一起勾**：外层 `selectable(rowIds: rows.map(\.id))` 把组内
    ///    **所有**行的 id 一起交给 `ChatSelectionRow` —— 界面上一条代表几行，
    ///    勾选 / 删除也必须整组一起（否则「删掉一条，可图还剩好几张」）。
    /// ⚠️ 搜索命中圈仍然**不挂**：搜索只命中文本 ⇒ `revealedRowId` 落不到媒体行上。
    @ViewBuilder
    private func mediaItem(_ rows: [AIChatRow]) -> some View {
        let urls = mediaURLs(in: rows)
        VStack(alignment: .leading, spacing: 3) {
            if let meta = rows.first?.metaText {
                Text(meta)
                    .font(MacTheme.ui(MacTheme.metaFontSize))
                    .foregroundStyle(MacTheme.meta)
            }
            MediaThumbStrip(rows: rows, onOpen: { MediaPreviewWindowCenter.shared.open($0) })
            // 🔴 操作栏**只有分享 + ⋯（只有删除）+ 时间**（2026-09-29 用户要求）。
            //    ⚠️ 「引用」已被用户明确去掉（「先把图片和视频的引用去掉」）：图片/视频
            //       与同轮那段文字是**三条独立消息**，引用图就该引图本身，而当时能取到的
            //       只有同轮的文字（指错对象）；且助手侧的图根本不进请求上下文 ⇒ 做不到。
            //       来由与「要加回来的两条路」记在 `ChatRowActionBar` 文件头。
            //    ⚠️ 地址全缺时不画整栏 —— 那种行不该冒出一个只剩「⋯」的栏
            //       （`mediaURLs` 是 `compactMap`，取不到地址的行会被丢掉）。
            //    ⚠️ 选择模式下也**整栏不画**：此刻点不到它（外层 `ChatSelectionRow` 关了
            //       整块行内容的命中），留着只会让「我在挑消息」的屏幕上挂着一排用不了的按钮。
            //       （判据与 `ChatRowView` 里那条同源，别只改一边。）
            if !urls.isEmpty, !model.isSelectionMode {
                ChatRowMediaActionBar(mediaURLs: urls,
                                      // 时间取**组首**那行（组内各行只差几毫秒，画五个时间既没意义
                                      // 又把栏撑宽）；首行缺失时用当下兜底，绝不会空着。
                                      timestamp: rows.first?.createdAt ?? Date(),
                                      // 流式中置灰（删行会让后面所有行的下标前移）
                                      canDelete: !model.isStreaming,
                                      // 「删除」→ 选择模式（2026-09-29 起与其它三个入口**完全一致**）。
                                      // ⚠️ 传**组首那行**的 id 就够了：模型层会用
                                      //    `turnRowRange(containingRowAt:)` 算出整轮，组内其余行
                                      //    天然都在那一轮里。默认勾的就是整轮 —— 想只删这几张图，
                                      //    在选择模式里把同轮其它行取消勾选。
                                      onDelete: {
                                          if let head = rows.first {
                                              model.enterSelectionMode(startingAt: head.id)
                                          }
                                      })
                    // 🔴 与缩略图条之间让出一点空隙（2026-09-29 用户反馈：媒体栏贴着图，
                    //    而文本消息的栏有间距）—— 用**和文本栏同一个常量**，⛔ 别在这儿写裸数字。
                    .padding(.top, MacTheme.rowActionBarTopGap)
            }
        }
        .id(rows.first?.id)
        .onAppear { rows.forEach { liveRowIds.insert($0.id) } }
        .onDisappear { rows.forEach { liveRowIds.remove($0.id) } }
    }

    /// **同一次发送里的连续用户图片行** → 一条**横向排列**的图（`UserImageStrip`），
    /// 下面挂一条**只有时间 · 分享 · ⋯** 的操作栏（2026-10-09 用户要求）。
    ///
    /// 2026-10-08 用户要求：「Mac端发送一条消息 内含多个图片，要横排显示」
    /// （此前是「一张图一行」，`AIChatManager.send` 每张图 append 一行 ⇒ 竖着摞一列）。
    ///
    /// ## 🔴 五件事与 `rowItem` / `mediaItem` 刻意同构（少一件都是坑）
    ///
    /// ① **`.id(组首 id)`**：`scrollTo` 找的是 `.id()` 锚点 —— 用首行 id 才能让「按行定位」
    ///    （搜索定位 / 编辑态滚动）至少仍指向**同一个位置**。组内第 2..N 张的 id 不挂锚点，
    ///    与助手侧媒体组同代价（那也是只挂首行）。
    /// ② **整组的行存活都要报**（`liveRowIds`）：`hasMaterializedRows` 是「切会话白屏」
    ///    那三条闸门之一 —— 漏报等于让「只有图片的会话」永远过不了闸门。
    /// ③ **不画时间小字**：用户侧本来就不画（`ChatRowView` 里 `if let meta = row.metaText, !isUser`）
    ///    —— 用户自己发的消息上方不报时（产品要求，时间在 hover 操作栏里）。
    /// ④ **操作栏（2026-10-09 新加）**：用户要求「我发送的图片消息也要和文字消息一样
    ///    底部有 ActionBar，默认隐藏，鼠标移动到图片上显示，但图片的只有时间 和分享和
    ///    三个点 按钮」⇒ `UserImageMessageItem`（图 + `ChatRowUserMediaActionBar` 一条视图），
    ///    显隐判据是本页的 `revealsUserImageBar`。
    ///    ⚠️ 位置 = **图的下方**（不是卡片内部末尾）：文字那条栏就在正文下方，
    ///    用户说的是「和文字消息一样」⇒ 同一个位置口径。
    ///    📌 本页只做**接线**（锚点 / 行存活 / 右键菜单 / hover 状态），长相在那个文件里。
    /// ⑤ **选择模式整组一起勾**：外层 `selectable(rowIds: rows.map(\.id))`
    ///    —— 界面上一条代表几行，勾选/删除也必须整组（同 `mediaItem`）。
    ///
    /// ⚠️ `containerWidth` **必须透传**：它是格子尺寸的唯一输入（`UserImageStrip` 转发
    /// 共享层 `userImageDisplaySize`），⛔ 别在宿主改用一个更大的宽（那会让图突然变大）。
    @ViewBuilder
    private func userImagesItem(_ rows: [AIChatRow], containerWidth: CGFloat) -> some View {
        // ⚠️ 地址全缺时整栏都不画（`mediaURLs` 是 `compactMap`）—— 那种行不该冒出一个
        //   点了没反应的分享。判据与 `mediaItem` 那条完全一致。
        let urls = mediaURLs(in: rows)
        let head = rows.first
        // ⚠️ 这一条**只是接线**：长相、宽度、hover 命中区、恒占位那一行全在
        //    `UserImageMessageItem` 里（渲染台也照它渲 ⇒ 验的是生产代码本身）。
        //    本页只留三样「属于列表而不属于一条消息」的：锚点 / 行存活 / 右键菜单。
        UserImageMessageItem(rows: rows,
                             containerWidth: containerWidth,
                             urls: urls,
                             // hover 判据与 `revealsUserImageBar` 逐字同源（同一个 `hoveredRowId`）。
                             isHovered: head.map { revealsUserImageBar($0.id) } ?? false,
                             isSelectionMode: model.isSelectionMode,
                             // 流式中置灰（删行会让后面所有行的下标前移，
                             // 而流式正靠 `streamingRowIndex` 定位那一行）。
                             canDelete: !model.isStreaming,
                             onOpen: { MediaPreviewWindowCenter.shared.open($0) },
                             // 「删除」→ 选择模式，**传组首那行**的 id 就够了：
                             // 模型层用 `turnRowRange(containingRowAt:)` 算整轮，
                             // 组内其余行天然都在那一轮里。
                             onDelete: { if let head { model.enterSelectionMode(startingAt: head.id) } },
                             // ⚠️ 与 `ChatRowView` 同一条：移出时**只清自己**
                             //（`hoveredRowId` 那条状态的老坑，见它的注释）。
                             onHoverChange: { inside in
                                 guard let head else { return }
                                 if inside {
                                     hoveredRowId = head.id
                                 } else if hoveredRowId == head.id {
                                     hoveredRowId = nil
                                 }
                             })
        .id(rows.first?.id)
        .onAppear { rows.forEach { liveRowIds.insert($0.id) } }
        .onDisappear { rows.forEach { liveRowIds.remove($0.id) } }
        // ⚠️ 右键菜单与改之前一致：`ChatRowView` 那份菜单挂在行上，投影成一条之后
        //    这一条就没有宿主了 ⇒ 必须在这里补一个，否则「右键删除自己发的图」这条路没了。
        //    ℹ️ 集合 = **只有「删除」**（`mediaRowMenu`，理由见那边）。
        .contextMenu { mediaRowMenu(for: rows.first) }
    }

    /// 「hover 才显」的那一条此刻**要不要显出来**（用户图片条下面那栏的**单点**判据）。
    ///
    /// ⚠️ 别在两处各写一半：`UserImageMessageItem` 里 `opacity` 与 `allowsHitTesting`
    ///    必须读到**同一个值**，少判一处就是「看不见却点得动」。
    /// 📌 与 `ChatRowView.revealsHoverControls` 同名同义（那边多一层 `isHovered`，
    ///    这边直接比 id）—— 刻意分成两处：那边的 hover 状态由 `ChatRowView` 自己上报，
    ///    这一条由 `userImagesItem` 上报（它不走 `ChatRowView`），共用一个 `@State`
    ///    但**各自的判据在本页**。
    private func revealsUserImageBar(_ headId: UUID?) -> Bool {
        guard let headId else { return false }
        return hoveredRowId == headId && !model.isSelectionMode
    }

    /// 媒体行（用户图组）的右键菜单：**只有「删除」**。
    ///
    /// ⚠️ 为什么不给「分享」：`ChatRowView` 那份右键菜单里**本来就没有分享**
    /// （它文件头写着「值得为菜单再铺一层 `NSSharingServicePicker` 不值」）——
    /// 合成一条之后**不要顺手加功能**，那会让用户侧与助手侧菜单不对称。
    /// ℹ️ 改之前用户图片行的右键菜单里，「复制 / 朗读」那两项取的是 `row.block.text`
    /// （图片行恒为空串）⇒ 对图片**本来就是两个无效项**，这里不恢复它们。
    ///
    /// 🔴 删除进的是**选择模式**而不是直接删（与其它三个删除入口同一条路，
    /// 理由见 `ChatRowMediaActionBar` 文件头：删不可恢复，得给一次反悔的机会）。
    private func mediaRowMenu(for row: AIChatRow?) -> some View {
        Group {
            if let row {
                Button(AIRowAction.delete.title, role: .destructive) {
                    model.enterSelectionMode(startingAt: row.id)
                }
            }
        }
    }

    /// 一组媒体行各自的**媒体地址**（媒体操作栏的「分享」用）。
    ///
    /// 图片取 `imageURL`、视频取 `videoURL`。
    /// ⚠️ 视频**不取** `videoCoverURL`：分享一张封面图对「分享这个视频」是误导。
    /// ⚠️ 用 `compactMap` ⇒ 分享的是「拿得到地址的那几个」，而不是硬凑成「组里几行就几个」。
    ///    用它的调用方（`mediaItem`）必须先判空 —— 返回空数组时整栏都不该出现。
    private func mediaURLs(in rows: [AIChatRow]) -> [URL] {
        rows.compactMap { row in
            switch row.block.kind {
            case .image: return row.block.imageURL
            case .video: return row.block.videoURL
            default:     return nil
            }
        }
    }

    private func beginSettling(_ proxy: ScrollViewProxy) {
        settleTask?.cancel()
        // 🔴 **几何量必须作废**（2026-09-26 加，切会话空白那个 bug 的另一半）。
        //
        //  `contentBottom` 是**上一个会话**留下的读数，而那个读数几乎必然满足「贴底」
        //  （上一个会话也是贴底的）⇒ 收敛循环第一拍就判「已贴底 / 内容底边不再变」，
        //  直接 `return`，**一次都没滚**。探针实测（2026-09-26，40 行切 12 行）：
        //  `SETTLE begin` 之后只落 2 拍 `METER` 就 `SETTLE end`，收手时 `cb=541 / vh=720`
        //  —— 离贴底差得远，而循环自己以为已经收工了。
        //  清零 = 「这个数现在没有意义」，于是首拍的条件不成立 → 至少执行一次 `scrollToBottom`，
        //  滚动本身会把真实几何带回来，后续判断才用得上新值。
        //  ⚠️ 只清 `contentBottom`，**不清 `viewportHeight`**：视口高在切会话时并不变
        //  （同一个 `ScrollView` frame），清了只会让首拍白跳过一次判断。
        contentBottom = 0
        // 🔴 **「用户翻走了」也要一起清掉**（2026-09-26 加）。
        //
        // 切会话是用户的明确动作（「我要看这个会话」），此时跟随状态就该校准成「从底部开始看」，
        // 与这条收敛循环本身的取向一致（它无论如何都会往底部滚）。
        // ⚠️ 搜索定位（`reveal`）不受影响：它自己会把这颗标记置回 `true`，
        //    且它的置位排在切会话那条 onChange **之后**（见那边的注释）。
        //
        // 📌 历史（⛔ 别再按旧结论改回去）：这一行**曾被当成**「滑过后切回来空白」的真凶 ——
        //    理由是那颗标记只由 `onChange(rows.count)` 顺手清，而两会话行数相同时那条不触发。
        //    但第四轮真机复现时 `away` 明明是 `False`、白屏照样发生 ⇒ **归因被推翻**。
        //    真凶是另一回事：两个会话**高度几乎一样** ⇒ 切过去**偏移零位移** ⇒ `LazyVStack`
        //    旧行已回收、新行却不创建。正解见 `transcript` 里的 `.id(model.selectedConversationId)`。
        //    ⇒ 这一行**仍然保留**（「清掉上一个会话的用户状态」与清几何量同理），只是不再当成因。
        userScrolledAway = false
        isSettling = true
        settleTask = Task { @MainActor in
            defer { isSettling = false }
            let deadline = Date().addingTimeInterval(Self.settleWindow)
            var lastBottom: CGFloat = -1
            var stableTicks = 0
            var tick = 0
            while !Task.isCancelled, Date() < deadline {
                if viewportHeight > 0, contentBottom > 0 {
                    // 🔴 收敛里的贴底判据必须是**双向**的（`abs`）—— 2026-09-26 修。
                    //    单向 `<= tolerance` 时，「**滚过头**」（内容底边落在视口**上方**，
                    //    于是 `contentBottom` 是个比视口矮的小正数）也算「已贴底」⇒
                    //    循环当场收手，把那个错位留在屏幕上（用户看到「内容停在半路 + 大片空白」）。
                    //    探针实测：切会话后 `SETTLE begin` → 只落 2 拍就 `SETTLE end`，
                    //    收手时 `cb=541 / vh=720` —— 差 179pt，而循环自己以为到站了。
                    // 🔴 必须**同时**满足「行真的被创建了」（2026-09-26 加）。
                    //    几何量是 `LazyVStack` 报的**估计值**，它可以在**屏幕全空**时照样报贴底
                    //    （实测：`cb=588 / vh=574` 而 `实例化行=无`）。那一拍收手，
                    //    后面就再没有任何机制会去滚一下了 ⇒ 白屏永久化。
                    if abs(contentBottom - viewportHeight) <= Self.bottomTolerance,
                       hasMaterializedRows { return }
                    // 🔴 「内容底边连着几拍没动」这条，**只在「底边已经落在视口范围内」时才可信**
                    //    （2026-09-26 加的闸门，长文档夹具抓到的第二个缺陷）。
                    //    不看这个前提的话，「不变」会被当成「布局稳定」——
                    //    而长文档会话里它多半是 **「底部那一屏还没 materialize，`scrollTo` 推不动」**：
                    //    实测（`STARRY_FIXTURE_DOC=1`）收手时 `cb=1289 / vh=586`（差 703pt ≈ 一屏），
                    //    屏幕上就是「切回来停在半路 / 一片空白，往上滑一下才出内容」。
                    //    ⇒ 离底还远时**宁可继续滚到窗口结束**，也别把错位留在屏幕上。
                    // ⚠️ 同样要**先有「行真的被创建了」这个前提**（2026-09-26 加）：屏幕全空时
                    //    `contentBottom` 正好是**一动不动**的（僵局）⇒ 不加这道闸门，
                    //    3 拍后就会被当成「布局已稳定」收手 —— 而那正是绝不能收手的时刻。
                    if hasMaterializedRows, contentBottom <= viewportHeight + Self.bottomTolerance {
                        if contentBottom == lastBottom {
                            // 「再滚也一动不动」= 到极限了。**这是主力退出条件**：
                            // 双向判据永远覆盖不到「内容比视口矮」（那时两者永不齐平），
                            // 那种局面只能靠这一条认出来（此时 `cb` = 内容高 < 视口高，上面的闸门放行）。
                            stableTicks += 1
                            if stableTicks >= Self.settleStableTicks { return }
                        } else {
                            stableTicks = 0
                        }
                    } else {
                        stableTicks = 0
                    }
                    lastBottom = contentBottom
                }
                // 🔴 行锚点**按需要**触发，不再「偶数拍 / 奇数拍」交替（2026-10-20 修
                //    「启动后会话列表上下跳几秒」）—— 两个锚点天然差 14pt，无条件交替就是
                //    到底之后原地来回跳 14pt，一直跳到 `settleWindow` 到点。实证与取舍见
                //    `settleScroll` 的文档注释。
                //
                // ☠️ 这里**试过**一条「僵局就用一次强制位移撞开」的路，当天实测推翻、已撤：
                //    程序化滚动救不回那个状态（实测：偏移真动了 `1521 → 1384`，而「哪些行
                //    要画」纹丝不动）⇒ 只有真实滚轮事件能。正的修法在源头 ——
                //    切会话让整棵子树重建（见 `transcript` 的 `.id`）。
                let needsMaterialize = tick == 0
                    || (contentBottom > viewportHeight + Self.bottomTolerance
                        && contentBottom == lastBottom)
                settleScroll(proxy, needsMaterialize: needsMaterialize)
                tick += 1
                try? await Task.sleep(nanoseconds: Self.settleTick)
            }
        }
    }

    /// 立刻停掉收敛（视图消失、搜索定位要接管时用）。
    private func endSettling() {
        settleTask?.cancel()
        settleTask = nil
        isSettling = false
    }

    // MARK: - 「用户自己滚了」的监听（2026-09-26）

    /// 装上滚轮事件监听：用户一往上翻，就把「自动跟随」关掉。
    ///
    /// ## 为什么不能用几何量去猜（试过，不行）
    /// `contentBottom` 变小既可能是**用户上翻**（整个内容往上走），也可能是**我们自己滚**
    /// （`scrollTo` 把内容往下拉时是同一个形状）—— 在任何单个几何量里这两者一模一样。
    /// 想用「刚才是我们自己滚的，先别判」的时间窗去躲也不行：流式输出期间我们**每帧都在滚**，
    /// 窗口会被不断续期 ⇒ 用户在流式时想上翻看历史会被一直拽回来。
    ///
    /// ⇒ 换成一个**只有用户的手能产生**的信号：滚轮事件（程序化 `scrollTo` 不发 `scrollWheel`）。
    ///
    /// ## 两道确认，缺一不可
    /// ① `scrollingDeltaY > 0` —— 「内容往下走」= 在翻**更早**的历史。
    ///    往下滚（deltaY < 0，想回底部）不置位，那是往回走、不该停跟随。
    /// ② `!isScrolledToBottom` —— 本地监听收的是**全 App** 的滚轮事件，
    ///    用户在**侧栏**（会话列表）滚时列表仍贴着底，这一道会把那个事件挡掉。
    ///    ⚠️ 它比实际滞后一拍（几何要下一帧才更新），所以「往上滚第一下」通常不置位、
    ///    第二下才置位 —— 结果是**在底部附近微调不会被判成翻走**，行为上正是想要的。
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        // 🔴 捕的是 `$` 投影（`Binding`），**不是 `_` 存储、也不是当时的取值**：
        //    - 捕**值**（`isScrolledToBottom`）不行：闭包读到的是「安装那一刻」的快照，
        //      之后无论怎么滚都拿着一个死的值，判断当场失效。
        //    - 捕 **`_` 存储**（`_isScrolledToBottom`）Xcode 27 起也编不过了：`@State`
        //      在那时换成了宏（`SwiftUIMacros.StateMacro`），`_` 兄弟是 **IUO**
        //      （`State<Bool>!`）⇒ `let s = _isScrolledToBottom` 一绑到局部量就降级成
        //      `State<Bool>?`，`s.wrappedValue` 直接报
        //      「Value of optional type 'State<Bool>?' must be unwrapped to refer to
        //       member 'wrappedValue' of wrapped base type 'State<Bool>'」。
        //    - `Binding` 的 get/set 一路转发到同一份 State 存储（引用语义的盒子）⇒
        //      读到的永远是最新值、写进去视图照样重算；且 `$` 投影自 iOS 13 起就是
        //      公开契约，跨 SDK 版本稳定。⛔ 别再改回 `_`。
        let atBottom = $isScrolledToBottom
        let away = $userScrolledAway
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if event.scrollingDeltaY > 0, !atBottom.wrappedValue {
                away.wrappedValue = true
            }
            return event
        }
    }

    /// 卸掉监听（视图离场时）。没装过时是空操作。
    private func removeScrollMonitor() {
        if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
        scrollMonitor = nil
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 就地编辑器的双向绑定。
    ///
    /// 手写 `Binding` 而不是 `@Bindable`：绑的是**模型的 `editingText`**，不是某个 `@State`
    /// —— 状态得住在外面的理由见 `ChatModel.editingRowId`（要能被切会话 / 删除一起收掉）。
    /// ⚠️ 同一时刻只有一个 `TextField` 在用它（`editingRowId` 只可能是一条），
    ///    所以「所有行共用同一个绑定」不会串。
    private var editingBinding: Binding<String> {
        Binding(get: { model.editingText }, set: { model.editingText = $0 })
    }

    /// 「重试」真正作用在哪一行（操作栏与右键菜单共用这一个判据）。
    ///
    /// - 助手行 / 失败行：**就是它自己**。`AIChatManager.regenerate(fromRowAt:)` 的前置条件
    ///   本来就是 `role == .assistant`，而失败提示行的 role 也是 `.assistant` —— 所以「重试」
    ///   与「重新生成」在业务层是同一份实现（见那边的注释），这边不需要分两个入口。
    /// - 用户行：**紧随其后的第一条助手回复**。「重试」落在这一行，意思显然是
    ///   「这句话让 AI 再答一次」（重发我的问题是「编辑」的语义，不在这一栏）。
    ///   后面还没有回复时返回 `nil` → 置灰。
    ///   ⚠️ 用户行现在**不挂操作栏**（2026-09-21 用户要求），这条路径只剩**右键菜单**在用。
    ///
    /// ⚠️ 返回 `nil` 有两种成因，都该置灰：① 用户行后面确实没有助手行（刚发出 / 那一轮失败了）；
    ///   ② 下标越界（`ForEach` 与 `model.rows` 在极端情况下错开一帧）。
    private func retryRowIndex(for index: Int) -> Int? {
        guard model.rows.indices.contains(index) else { return nil }
        if model.rows[index].role == .assistant { return index }
        let start = index + 1
        // `start == count` 时下面取到的是空切片（合法），`start > count` 才是越界
        guard start <= model.rows.count else { return nil }
        return model.rows[start...].firstIndex { $0.role == .assistant }
    }
}

// MARK: - 贴底判据的几何量（文件级，只服务 `ChatDetailView`）

/// 内容**顶边 + 底边**的偏好通道（2026-09-26 加，两者**必须一起传**）。
///
/// ## 🔴 为什么不是两个独立的 key（试过，会连着两次翻车）
/// 「总高 = 底边 − 顶边」是「内容长高就补一次贴底」那条跟随的唯一判据，而总高必须
/// **在同一帧里用同一次更新拿到的两个值**算。分成两个 key 时两条通道的
/// `onPreferenceChange` **不同时**触发，中间态会让总高虚增：
/// 上滑 30pt 时若 `contentTop` 先更新，`底边 − 顶边` 会凭空多出 30 ⇒ 被判成「内容长高」
/// ⇒ 补跟 ⇒ **把用户的上滑当场拽回去**（探针实测：⑫ 上滑 240pt、⑮ 上滑 90pt，偏移纹丝不动）。
/// 合并成一个 key 之后，`reduce` 会把两条探针的值并进**同一个** `Value`，
/// 回调每次拿到的都是**同一帧的完整几何**。
///
/// ⚠️ 字段用 `CGFloat?` 而不是 `CGFloat` + 「非 0 才算数」：顶边滚到内容最顶部时
/// `minY` **正是 0**，用 0 当「没写」会把合法值丢掉。
private struct ChatContentMetrics: Equatable {
    /// 内容顶边在滚动坐标系里的 `minY`（≈ `-滚动偏移`）。`nil` = 这一路没有探针写值。
    var top: CGFloat?
    /// 内容底边在滚动坐标系里的 `maxY`。
    var bottom: CGFloat?
}

/// 写入者有两个：`contentTopProbe`（只写 `top`）与 `contentBottomProbe`（只写 `bottom`）。
private struct ChatContentMetricsKey: PreferenceKey {
    static let defaultValue = ChatContentMetrics()
    static func reduce(value: inout ChatContentMetrics, nextValue: () -> ChatContentMetrics) {
        let next = nextValue()
        if let t = next.top { value.top = t }
        if let b = next.bottom { value.bottom = b }
    }
}

/// 视口高度的偏好通道。写入者只有 `ChatDetailView.viewportProbe` 一个。
///
/// ⚠️ 只传高度、**不传安全区** —— 实测安全区那一份是重复的（见 `ChatDetailView` 文件头）。
private struct ChatViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        // 没有探针的分支会带着默认值（0）过来；直接 `value = next` 会被它清空。
        if next != 0 { value = next }
    }
}
