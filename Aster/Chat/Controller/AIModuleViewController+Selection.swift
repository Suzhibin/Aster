import UIKit
import AICore

/// 「多选删除」的完整流程：进入 / 退出选择模式、勾选联动、二次确认、执行删除。
///
/// ## 交互（2026-09-18 产品要求，两次改版后的最终形态）
/// 长按操作卡的**竖排最后一项「删除」** → 表格进入编辑态：每行左侧长出系统勾选圆圈，
/// 选中变对号；**默认勾上「这一轮」**（提问 + 它的 AI 回复），其余不勾，用户自己加减。
/// 动作全部走**底部那条顶替输入栏的选择栏**（`AISelectionToolbar`）：
/// 左「取消」、右「删除(N)」；导航栏只留标题报数。
///
/// ⚠️ 删除按钮**不在导航栏**（2026-09-18 二次改版）：删除不可逆，触发它的手指必须够得着 ——
/// 导航栏右上角是单手最难碰到的位置，而底部那块本来就是拇指区。所以进入选择模式时
/// **输入栏整条藏起来、选择栏顶上去**，位置一动没动。
///
/// ## 为什么用「表格编辑态」而不是自己画圆圈
/// 圆圈 / 对号是 `UITableView` 的原生能力：`allowsMultipleSelectionDuringEditing = true`
/// + `setEditing(true)`：点按与拖动、VoiceOver、选中反馈都由系统维护。
/// 自己画一套等于复刻这些行为，还得跟着滚动同步位置。
///
/// ## 代价：编辑态会把 `contentView` **左侧**内缩（4x pt）
/// 系统靠这个内缩给圆圈腾位置（**右侧仍与 cell 齐平**）→ 所有「按屏宽算出宽度」的气泡
/// 可用宽度都少了一截，长文本会按更窄的宽度重新折行；而行高是数据层按 0.8×屏宽
/// **预计算并只读缓存**的（见 `+Table.heightForRowAt`）→ 多出来的行会被裁掉。
/// 含代码块时更糟：气泡有一条「钉到 0.8×屏宽」的**等式**约束，会与右侧限制直接冲突。
/// 所以两个 cell 各自做了补偿 —— ⛔ **删任何一处，长消息都会裁字 / 报约束冲突**：
/// - `AIAssistantTextCell.applyEditInsetCompensation()`：右侧留白**等量收回**；
/// - `AIUserTextCell`：左侧 64pt 限制改成相对 **cell**（静态改法，不需要运行时补偿）。
///
/// ## 与其它交互的边界（都在 `enterSelectionMode` 里收掉）
/// - **长按弹卡**：关掉（否则长按同一行又弹出一张卡，两层 UI 打架）；
/// - **输入栏**：整条隐藏（换成选择栏），用户不可能一边勾消息一边发新消息；
/// - **选中文字态 / 操作卡 / 编辑态**：进之前全部收掉；
/// - **流式中**：不许进（删行会让后面所有行的下标前移，流式正靠 `streamingRowIndex` 写那一行）。
///
/// ## 🔴 勾选集合只装「自己占一行」的行（2026-09-29 加，用户实拍驱动）
/// 媒体横滑条组内第 2..N 张行高为 0，**不进勾选集合**（判据 `isCheckableRow(at:)`，
/// 程序化勾选与用户点选各有各的闸）。整组一起删不受影响 —— 删除时按 `groupIds` 展开。
/// 标题与底部栏报数一律读 `selectedMessageIds()`（会删掉几条消息），与二次确认同源。
extension AIModuleViewController {

    // MARK: - 勾选真值

    /// 当前勾选的行下标（升序）。
    ///
    /// ⚠️ **表格是勾选的唯一真值来源**，别在 VC 里另存一份集合：`reloadData` 之后表格的
    /// 勾选状态会自己复原/清空，我们那份不会 —— 两份状态迟早不同步，那时删的就是错的那些行。
    var selectedRowIndexes: [Int] {
        (tableView.indexPathsForSelectedRows ?? []).map(\.row).sorted()
    }

    /// 「这一行能不能进勾选集合」的**唯一判据** = 它在界面上**自己占一行**
    ///（共享层 `AIChatMediaGrouping.occupiesOwnRow(_:at:)`）。
    ///
    /// 🔴 为什么必须有这道闸（2026-09-29 用户实拍）：媒体横滑条**只有组首那一行有高度**，
    /// 组内第 2..N 张行高为 0（`AIChatManager.normalizeMediaGroupHeights()`），
    /// 而 `UITableView` 在编辑态下**照样**给这些零高度的 cell 摆勾选圈 ——
    /// 控件贴着 cell 顶边往下落，于是「图片横滑条 ↔ 视频横滑条」的交界处会露出**半截蓝圈**。
    /// 它不是多画了一个控件，是「有一个看不见的行被勾上了」。
    ///
    /// ⚠️ 还有第二个后果，比那个圈更严重：这些看不见的行一旦留在勾选集合里，
    /// 用户**取消勾选**那条横滑条（点到的只有组首那一行）时，组内其余行**仍然是勾着的** ⇒
    /// 删除时照样被 `groupIds` 展开删掉。表现是「我明明取消了，图还是没了」。
    ///
    /// ⛔ **两处**都得过这道判据，缺一不可：
    /// - 程序化勾选（`enterSelectionMode` 的默认勾整轮）—— `selectRow(at:)` **不走**代理；
    /// - 用户点选（`+Table.willSelectRowAt`）—— 拖选时触摸可能落在零高度行的那条边界上。
    func isCheckableRow(at index: Int) -> Bool {
        AIChatMediaGrouping.occupiesOwnRow(manager.rows, at: index)
    }

    /// 当前勾选**真正会删掉的消息 id**（按行序、已去重）—— **删除的**唯一来源。
    ///
    /// 🔴 2026-10-09：**报数不再走它**（`.count` 是「要删几个 block」，不是「我勾了几条」）。
    /// 用户原话「删除数量 现在按照图片个数算的，要改成按照消息个数算」
    /// ⇒ 一次发 5 张图时本函数给 **5**（删5 个块、**正确**），而报数要给 **1**
    ///（界面上是**一条横排**）。报数读 `selectedMessageCount`，两端换算都在共享层。
    /// ⚠️ 本函数**只管删除**（整组展开），⛔ 别拿它的长度当报数。
    ///
    /// 🔴 展开整组的理由（2026-09-28 用户选定）：连续的助手图片在界面上是**一条**横滑条，
    /// 组内第 2..N 张**根本点不到**（行高为 0）。不展开的话，用户勾中「那条图」再删，
    /// 看到的是「删掉一条消息，可图还剩好几张」—— 与「一条消息 = 一个整体」的直觉不符。
    /// 判据走共享层 `AIChatMediaGrouping`：非媒体行返回的就是它自己 ⇒ 其它行不受影响。
    /// ⚠️ 现在的勾选集合只装「自己占一行」的行 ⇒ 各组互不相交、理论上不会重复；仍按 id 去重
    ///    是一道**廉价保险**：万一将来勾选集合又混进同组的另一行（判据回退、新增入口），
    ///    **也不会漏删**—— 「删除」是不可逆动作，值得多这一道。
    ///
    /// 🔴 2026-10-09：用户多图横排**也要整组删**，且它走的是**另一把尺**
    ///    （`userImageGroupIds`）。⛔ 漏了这一支的症状很隐蔽：勾中那条横排、确认删除，
    ///    第 2..N 张图**留在原地**（组首那张被删了）⇒ 用户看到「横排被删掉一格，后面几张还在」，
    ///    而横排在界面上明明是一个整体。
    /// ⚠️ 判据是「这一行是不是用户图片」——**不是**「在不在多图组里」：
    ///    单张时两个函数都只返回它自己，天然正确，不需要额外分「单张/多张」。
    func selectedMessageIds() -> [UUID] {
        var ids: [UUID] = []
        var seen = Set<UUID>()
        for index in selectedRowIndexes {
            guard manager.rows.indices.contains(index) else { continue }
            let group = AIChatMediaGrouping.isUserImage(manager.rows[index])
                ? AIChatMediaGrouping.userImageGroupIds(manager.rows, including: index)
                : AIChatMediaGrouping.groupIds(manager.rows, including: index)
            for id in group where seen.insert(id).inserted {
                ids.append(id)
            }
        }
        return ids
    }

    // MARK: - 进入 / 退出

    /// 进入选择模式，并把 `rowIndex` 所在的**整轮**（提问 + AI 回复）默认勾上。
    ///
    /// 入口只有一个：长按操作卡里的「删除」（三个菜单都有它）。
    func enterSelectionMode(startingAt rowIndex: Int) {
        guard !isSelectionMode, mode == .chat, !manager.rows.isEmpty,
              manager.rows.indices.contains(rowIndex) else { return }
        // 流式中不给进。菜单里已经按 `blockedWhileStreaming` 摘掉了这一项，这里是**兜底**：
        // 将来若有别的入口接进来，不会绕过这道闸
        guard !isStreaming else {
            showToast(L("正在回复中，先停下再删"))
            return
        }

        // 进之前把三样东西收掉：操作卡还浮在列表上（遮罩会拦住勾选）、选字态会吃掉气泡上的
        // 触摸、编辑态下轻点消息会去进编辑（与「轻点 = 勾选」抢同一拍）
        endTextSelection()
        dismissActionMenu()
        exitEditing(clearInput: true)
        view.endEditing(true)

        isSelectionMode = true

        // ① 表格进编辑态：圆圈 / 对号是系统画的。
        // ⚠️ 三条**缺一不可**，任一条写错都只是「行为不对」、**不报任何错**：
        // - `allowsMultipleSelectionDuringEditing`：允许多选（圆圈能画出来靠它）；
        // - `allowsSelectionDuringEditing`：**编辑态下允许选择**。它俩在 UIKit 里是两个独立开关
        //   （头文件各自注明 default is NO），只设前者时真机表现为「圆圈在、点不动、没有对号」；
        // - 顺序：**先设两个 allows 再 setEditing**，反过来这一趟进去没有圆圈。
        // 用无动画：编辑态过渡期间表格还在插值，紧随其后的 `selectRow` 可能被吞掉
        // （那一刻的观感就是「进去一个对号都没有」）；模式切换本来就该是干脆的一下。
        tableView.allowsSelectionDuringEditing = true
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.setEditing(true, animated: false)
        // 屏上已有的 cell 这一趟**不会**走 `willDisplay`（那只在 cell 上屏时触发）→
        // 两件事都得在这里补一次：① 行选中底色（否则勾上的行只有对号、没有底色，一列里找
        // 「勾了哪几条」很费眼）；② **让出触摸**（否则点图片行 / 视频行 / 带操作栏的助手行，
        // 那一拍被它们的手势与按钮接走，看着像「勾不上」）。离屏的 cell 上屏时由 `willDisplay` 兜住。
        for cell in tableView.visibleCells {
            cell.selectionStyle = .default
            (cell as? AIChatSelectionTouchYielding)?.setSelectionMode(true)
        }

        // ② 默认勾上这一轮。行区间**在这一刻现算**：进来之后列表不会再变
        //    （输入栏已藏、流式已停、长按已关），此刻算出来的行号就是稳的
        //
        // 🔴 只勾「自己占一行」的行（2026-09-29）：媒体组内第 2..N 张行高为 0，
        //    它们没有可见的勾选圈 —— 勾上了只会变成「图片与视频交界处冒出的半截蓝圈」，
        //    而且会让「取消勾选整条横滑条」失效（两件事的成因都在 `isCheckableRow(at:)`）。
        //    整组一起删**不受影响**：删除时按 `groupIds` 展开（`selectedMessageIds()`）。
        if let range = manager.turnRowRange(containingRowAt: rowIndex) {
            for index in range where isCheckableRow(at: index) {
                tableView.selectRow(at: IndexPath(row: index, section: 0),
                                    animated: false,
                                    scrollPosition: .none)
            }
        }

        // ③ 导航栏：摘掉原来的按钮（选择模式下它们都没意义，且抽屉按钮会把用户带走），
        //    **只留标题报数**。⚠️ 存下引用再置 nil —— 退出时原样装回去，
        //    哪天导航栏加了别的按钮，这段逻辑不会把它抹掉。
        selectionSavedLeftItem = navigationItem.leftBarButtonItem
        selectionSavedRightItems = navigationItem.rightBarButtonItems
        // ⛔ 只能整条置 nil：`UIBarButtonItem.isHidden` 是 **iOS 16+**，本工程 target 是 14 ——
        // 用它编译不过（离线类型检查会当场报「isHidden is only available in iOS 16.0 or newer」），
        // 侥幸改进去也会在 iOS 14/15 真机上崩。
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItems = nil

        // ④ 底部：输入栏让位给选择栏。两者**同位置同高**（frame 直接取输入栏的），
        //    所以列表底部内边距一格都不用动
        inputToolbar.isHidden = true
        selectionToolbar.isHidden = false
        view.bringSubviewToFront(selectionToolbar)
        layoutSelectionToolbar()
        updateSelectionUI()

        // ⑤ 关掉与勾选抢戏的入口
        setCellLongPressEnabled(false)
        // 悬浮按钮会盖在最后几行上方，选择模式下它没有意义（而且会挡住点选）
        updateScrollToBottomButton()
        StarryHaptic.impact(.medium)
    }

    /// 退出选择模式：还原导航栏 / 表格 / 底部栏 / 长按手势。**幂等**（不在选择模式时什么都不做）。
    ///
    /// 五条退出路径都走这里：点「取消」、删完、切会话、回落地页（新建 / 删掉当前会话）、
    /// 以及「删除」在确认弹窗里被取消后**不**退出（那时选择还得留着）。
    func exitSelectionMode() {
        guard isSelectionMode else { return }
        // ⚠️ 先落标志再清勾选：`deselectRow` 会回调 `didDeselectRowAt`，那边按这个标志决定
        // 要不要刷 UI —— 反过来的话每次退出都会白刷一遍
        isSelectionMode = false

        for ip in tableView.indexPathsForSelectedRows ?? [] {
            tableView.deselectRow(at: ip, animated: false)
        }
        tableView.allowsSelectionDuringEditing = false
        tableView.allowsMultipleSelectionDuringEditing = false
        tableView.setEditing(false, animated: false)
        // 选择模式把「行选中底色」打开了（进入时遍历 + `willDisplay` 里按标志切）→ 屏上这些行要还原。
        // 离屏的 cell 下次上屏时 `willDisplay` 会按新标志设回 `.none`，不必整表刷。
        //
        // ⚠️ 触摸权也必须在这里还回来：选择模式关掉了各 cell 的操作栏 / 引用条 / 图片手势 /
        // 视频播放按钮，而**屏上这些 cell 不会走 `willDisplay`**（那只在 cell 上屏时触发）——
        // 不还的话用户点它们会「什么都不发生」，直到滚出屏幕再滚回来才恢复（上一版的漏项）。
        for cell in tableView.visibleCells {
            cell.selectionStyle = .none
            (cell as? AIChatSelectionTouchYielding)?.setSelectionMode(false)
        }

        // 底部：选择栏收起，输入栏回来（它一直没动过位置，所以列表内边距仍然对得上）
        selectionToolbar.isHidden = true
        inputToolbar.isHidden = false

        // 导航栏原样恢复（把进入时摘掉的那两个装回来，而不是硬写一个新按钮）
        navigationItem.leftBarButtonItem = selectionSavedLeftItem
        navigationItem.rightBarButtonItems = selectionSavedRightItems
        // 标题还原走 `refreshTitle()`（**标题的唯一出口**，内容恒为 `Self.defaultTitle`）。
        // ⚠️ 别在这里裸写 `title = ...`：进入选择模式时被改的就是 `title`，
        //    还原必须与它成对、且出自同一个地方（2026-10-02 之前这里还负责拼回模型名）。
        refreshTitle()
        selectionSavedLeftItem = nil
        selectionSavedRightItems = nil

        setCellLongPressEnabled(true)
        updateScrollToBottomButton()
    }

    // MARK: - 底部选择栏

    /// 把选择栏摆到**输入栏的位置**（同 x/y/宽/高）。
    ///
    /// ⚠️ 为什么不是自己算底部安全区：输入栏的高度是「内容 + `restingBottomInset`」且随键盘 /
    /// 「+」面板变形，**它是底部占位的唯一口径**（列表内边距读的就是它的 minY）。
    /// 直接抄它的 frame，两者就永远不会差一截 —— 差一截的表现是最后几条消息被这条盖住。
    ///
    /// 调用点有三处，缺一不可：进入时（立刻摆好，不等下一次布局）、`inputToolbar.onFrameChange`
    /// （键盘收起 / 转屏时它还在动）、`viewDidLayoutSubviews`（首帧与安全区变化）。
    func layoutSelectionToolbar() {
        guard isSelectionMode, !selectionToolbar.isHidden,
              selectionToolbar.superview != nil,
              view.bounds.width > 0 else { return }
        // 输入栏虽被隐藏，frame 仍在持续更新（宿主每一趟 `viewDidLayoutSubviews` 都会复位它）
        let top = inputToolbar.frame.minY
        guard top > 0, top < view.bounds.height else { return }
        let target = CGRect(x: 0,
                            y: top,
                            width: view.bounds.width,
                            height: view.bounds.height - top)
        if selectionToolbar.frame != target { selectionToolbar.frame = target }
    }

    // MARK: - 勾选联动

    /// 勾选集合变了 → 刷新底部「删除(N)」与标题报数。
    /// 由 `didSelectRowAt` / `didDeselectRowAt` 调用（表格是勾选的真值来源）。
    ///
    /// 🔴 这里数的**不是「底层要删几个块」**（那是 `selectedMessageIds().count`），
    /// 而是**「我勾了几条消息」** —— 用户 2026-10-09 原话：「删除数量 现在按照图片个数算的，
    /// 要改成按照消息个数算」。一次发 5 张图在界面上是**一条横排**，报数就该写 1 而不是 5。
    /// 换算走共享层 `AIChatMediaGrouping.selectedMessageCount(_:rowIndexes:)`
    ///（复用 `occupiesOwnRow`：组内第 2..N 行不占行 ⇒ 一条横排恒算 1 条）。
    /// 📌 与**勾选粒度**天然一致：界面上一条 = 一个勾选圈 ⇒「勾了几个圈就报几条」。
    /// ⚠️ 与二次确认弹窗**同源**（都读它）—— 否则又是「上面写 1、弹窗写 5」的错位
    ///（2026-09-29 统一过一次，那次统一的是「按块」，这次按同一条原则改成「按条」）。
    func updateSelectionUI() {
        guard isSelectionMode else { return }
        let count = selectedMessageCount
        selectionToolbar.setSelectedCount(count)
        navigationItem.title = count > 0 ? String(format: L("已选择 %d 条"), count) : L("请选择要删除的消息")
    }

    /// 勾中的**消息条数**（报数的唯一来源）—— = `selectedRowIndexes` 里
    /// **界面上自己占一行**的那些行的个数（换算在共享层）。
    ///
    /// 🔴⛔ **别用 `selectedMessageIds().count` 当报数**：那个数是「底层要删几个块」，
    /// 一次发 5 张图会给 5 —— 界面上一条横排，用户勾了 1 个圈，写「已选择 5 条」当场把人吓退。
    ///⚠️ 但**删除仍按 `selectedMessageIds()` 全量 id 走**（整组删，2026-09-28 用户选定）
    /// —— 「勾了几条」与「删几个块」是**两件事**，别顺手把删除也改成按条。
    var selectedMessageCount: Int {
        AIChatMediaGrouping.selectedMessageCount(manager.rows, rowIndexes: selectedRowIndexes)
    }

    // MARK: - 取消 / 删除

    /// 底部栏左「取消」：原样退出，一条都不动
    func handleSelectionCancel() {
        StarryHaptic.impact(.light)
        exitSelectionMode()
    }

    /// 底部栏右「删除(N)」：把勾中的行换成**消息 id** 再走二次确认。
    func handleSelectionDelete() {
        guard isSelectionMode else { return }
        // 行号 → 消息 id 在**点下去这一刻**换掉，之后一路只用 id：
        // 确认弹窗弹起到用户点「删除」之间列表可能变，行号会漂（本工程老坑 ——
        // 编辑重发之所以存消息 id 而不是行号，是同一条理由）。
        // ⚠️ 展开整组 / 去重的全部理由都在 `selectedMessageIds()` 里，⛔ 别在这儿再写一份。
        //
        // 🔴🔴 2026-10-09：**`ids` 与 `count` 是两件不同的事，别混**
        // - `ids` = **要删的 block**（整组展开，按块）：「我一次发的 5 张图」要删干净 ⇒ 5 个 id。
        //   这是 2026-09-28 用户选定的「整组一起删」，⛔ 千万别改成按条只删 1 个。
        // - `count` = **勾了几条消息**（界面上占一条算一条）：横排是**一条** ⇒ 报 1。
        // 混了就会出现「弹窗写 1、实际删了 5 个块」或者反过来「弹窗写 5、像删了 5 条消息」。
        let ids = selectedMessageIds()
        guard !ids.isEmpty else { return }
        // ⚠️ count 必须在**这一拍**取（与 ids 同一时刻）：`exitSelectionMode()` 之后勾选集合清零，
        //    那时再读会得到 0，弹窗标题会闪一下「删除选中的 0 条消息？」。
        let count = selectedMessageCount
        confirmDeleteSelection(ids: Set(ids), count: count)
    }

    /// 删除前的二次确认。
    ///
    /// 为什么留着这一步：**删除不可恢复**（内存里删、库里也删，没有撤销/回收站，
    /// 见 `AIChatManager.deleteMessages(withIds:)`）。选择模式已经把「删哪几条」交给用户确认过，
    /// 但「按错按钮」这一拍仍然只能靠这一步兜住（豆包同样有确认）。
    ///
    /// - Parameter ids: 要删的消息 id。⚠️ 传 id 不传行号 —— 见 `handleSelectionDelete`。
    /// - Parameter count: **报数用的条数**（按「条」不按「块」，2026-10-09）——
    ///   ⚠️ 它与 `ids.count` **故意不相等**：一次发 5 张图时 `ids.count == 5` 而 `count == 1`
    ///   （界面上是**一条横排**）。标题与 toast 都读它，⛔ 别改成 `ids.count`。
    private func confirmDeleteSelection(ids: Set<UUID>, count: Int) {
        let alert = UIAlertController(title: String(format: L("删除选中的 %d 条消息？"), count),
                                      message: L("删除后无法恢复。"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("删除"), style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            // 先退出选择模式**再**删：删完那一拍表格会整表重建（`chatManagerDidReplaceRows`），
            // 此刻若还停在编辑态，行数与勾选集合就对不上了（表格会自己按下标去找 cell）
            self.exitSelectionMode()
            // ⚠️ 失败**不能静默 return**：这里返回 false 只有两种原因（弹窗期间刚好开始了流式 /
            // 这些消息已经不在了），静默的话用户看到的是「点了删除却什么都没发生」——
            // 那和功能坏了的观感一模一样
            guard self.manager.deleteMessages(withIds: ids) else {
                self.showToast(self.isStreaming ? L("正在回复中，先停下再删") : L("这些消息已经不在了"))
                return
            }
            self.showToast(count > 1 ? String(format: L("已删除 %d 条"), count) : L("已删除"))
        })
        present(alert, animated: true)
    }
}
