import UIKit
import AICore

/// 聊天列表：数据源、行高、cell 装配，以及「长按 cell 弹竖排操作卡」。
///
/// ## 高度只读缓存，从不现算
/// 行高在数据返回时由 `AIChatManager` 算好存进模型（`AIChatRow.cachedHeight`），
/// `heightForRowAt` 只读缓存。唯一例外是最后那句按屏宽现算的兜底 —— 正常走不到，
/// 仅仅防「数据已换、缓存未回填」的边界瞬态。
/// **估算行高（`estimatedHeightForRowAt`）返回同一份缓存值**，两者共用一个取数口 ——
/// 估算误差归零，UIKit 不必在滚动中边滚边修正内容高度（详见该方法的注释）。
/// ⚠️ 别在这里改成离屏 sizingCell：`UITextView` 离屏时 `intrinsicContentSize` 不准，
/// 那正是之前流式高度跳变的根因。
///
/// ## 长按与轻点分工（2026-09-17 改：操作卡只留长按一个入口）
/// **长按「内容块」→ 竖排操作卡**（本文件）；**「选取文字」就在那张卡里**（竖排第一项）。
/// 只认内容块（见 `AIChatContentBlockProviding`）—— 气泡外的留白不响应。
/// **轻点 → 只有「自己发的文字」进入编辑态**（`didSelectRowAt`）；助手回复 / 失败提示 / 文件
/// 一律不响应。轻点图片是预览、点视频是播放，由各自 cell 的手势 / 控件接管，不经本文件。
/// 轻点列表别处 → 退出编辑态 + 收起「+」面板 + 退出选字（`setupListBlankTapGesture`）。
/// 命中 `UIControl` 的触摸让给控件（视频播放按钮等），其余才归手势。
///
/// ## 多选删除（选择模式，2026-09-18 加）
/// 表格进编辑态（`allowsMultipleSelectionDuringEditing`）时，本文件只负责「表格那一半」：
/// 勾选回调（`didSelectRowAt` / `didDeselectRowAt`）只刷导航栏、**不碰 `deselectRow`**；
/// `willDisplay` 负责切「行选中底色」并让自带手势 / 控件的 cell 让出触摸。
/// 进入 / 退出 / 二次确认 / 真正删除都在 `+Selection.swift`。
///
/// 🔴 勾选集合**只收「自己占一行」的行**（`willSelectRowAt` 那道闸，2026-09-29）：
/// 媒体横滑条组内第 2..N 张行高为 0，勾上只会变成「交界处的半截蓝圈」，
/// 而且会让「取消勾选整条横滑条」失效。判据与两个症状见 `+Selection.isCheckableRow(at:)`。
extension AIModuleViewController: UITableViewDataSource, UITableViewDelegate {

    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        manager.rows.count
    }

    public func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        rowHeight(at: indexPath.row)
    }

    /// 估算行高 = **缓存真值**，不是常量猜测。
    ///
    /// UIKit 对**未上屏**的行一律用估算值去铺 `contentSize`。只给一个
    /// `estimatedRowHeight = 80` 的话，助手长回复（真实行高常是 200~600pt）每滚过一行
    /// 都要「发现估错了 → 修正 contentSize → 重排」，表现为滚动条抖动 + 额外的布局开销。
    /// 这里返回已经算好的缓存值，**估算误差归零**，一次修正都不需要。
    ///
    /// ⚠️ 别在这里改写成「更省的粗算」（按字符数 × 行高之类）：本工程的高度缓存本来就是
    /// 数据返回时一次性算好的（`cachedHeight`），粗算不会更省，却把估算与真值撕开 ——
    /// **估算恒等真值**才是这条的全部要点。
    /// ⚠️ 与 `heightForRowAt` 共用一个取数口（`rowHeight(at:)`），别再各写一份。
    public func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        rowHeight(at: indexPath.row)
    }

    /// 行高的**唯一取数口**：`heightForRowAt` 与 `estimatedHeightForRowAt` 都走这里，
    /// 保证「估算」与「真值」不可能不一致（不一致就会触发 UIKit 的高度修正流程）。
    private func rowHeight(at index: Int) -> CGFloat {
        // 只读缓存：高度已在数据返回时由 AIChatManager 算好存入模型
        if let cached = manager.cachedHeight(forRowAt: index) { return cached }
        // 安全网：正常不会走到（数据返回时已算好），仅防边界瞬态；按当前屏宽现算兜底
        guard manager.rows.indices.contains(index) else { return tableView.estimatedRowHeight }
        let row = manager.rows[index]
        // 🔴 媒体组的**非首行**高度为 0 —— 那一条横滑条由组首那一行统一渲染。
        // 正常路径由 `AIChatManager.normalizeMediaGroupHeights()` 写好；这里是兜底，
        // 两边必须同一口径（不一致时症状是「偶发多出一条 204pt 的空白」，极难复现）。
        // ⚠️ 「谁不占高」与「谁不能进勾选集合」是**同一个判据**
        //    （`AIChatMediaGrouping.occupiesOwnRow(_:at:)`）—— 这里与 `isCheckableRow(at:)`、以及
        //    `willDisplay` 里那行 `clipsToBounds` 必须永远一致，⛔ 别在任一处另写一套。
        if AIChatMediaGrouping.kind(of: row) != nil,
           !AIChatMediaGrouping.isGroupHead(manager.rows, at: index) {
            return 0
        }
        // 🔴 2026-10-09：用户多图横排同理 —— 组首按「整组最高那格 ×`userImageStripScale` + 12」，
        //    组内其余归零。⛔ **必须与 `normalizeUserImageGroupHeights()` 同一口径**，
        //    不一致时症状是「偶发多出一条空白」，且只在缓存未回填的边界瞬态出现（极难复现）。
        //    ⚠️ 判据要带上「组内 >1 张」：单张的原尺寸是 `height(in:)` 自己算的那笔，
        //    落到下面那行去算才是对的。
        if let range = AIChatMediaGrouping.userImageGroupRange(manager.rows, at: index),
           range.count > 1 {
            return range.lowerBound == index
                ? AIChatRow.userImageGroupRowHeight(rows: Array(manager.rows[range]),
                                                    in: manager.contentWidth,
                                                    scale: AIChatRow.userImageStripScale)
                : 0
        }
        return row.height(in: UIScreen.main.bounds.width)
    }

    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = manager.rows[indexPath.row]
        switch row.block.kind {
        case .text, .error:
            if row.role == .user {
                let cell = tableView.dequeueReusableCell(withIdentifier: "AIUserTextCell", for: indexPath) as! AIUserTextCell
                // 小字行（时间）由 `AIChatManager.applyMetaFlags` 算好挂在行上（nil = 不显示）；
                // 引用条取 `block.quote`（行高按 `AIChatRow.quoteHeightOrZero` 同源累加）
                cell.configure(row.block.text, metaText: row.metaText, quote: row.block.quote)
                // 点引用条 → 滚回被引用那条并闪一下（复用搜索结果定位那一套；
                // 那条消息若已被截断/重新生成删掉，revealMessage 会给出提示）
                cell.onQuoteTap = { [weak self] id in
                    guard let self else { return }
                    self.revealMessage(id: id)
                }
                return cell
            } else {
                let cell = tableView.dequeueReusableCell(withIdentifier: "AIAssistantTextCell", for: indexPath) as! AIAssistantTextCell
                // 操作栏回调按「操作时的实际行」定位：cell 复用后捕获的 indexPath 会失效，
                // 用 tableView.indexPath(for:) 现取最稳
                cell.onAction = { [weak self, weak cell] action in
                    guard let self = self, let cell = cell,
                          let ip = self.tableView.indexPath(for: cell) else { return }
                    self.performRowAction(action, rowIndex: ip.row)
                }
                // 代码卡片的「复制」：直接写剪贴板 + 提示。
                // ⚠️ 回调带的是**那段代码本身**、不是行号 —— cell 复用后行号会漂，字符串不会
                //（见 `AICodeBlockView.onCopy`）。所以这条闭包不依赖 indexPath，也不怕复用。
                cell.onCopyCode = { [weak self] code in
                    // ☠️ 写剪贴板 / 触感**不依赖 self**，而且在 self 已走时也必须照做
                    //    （用户按了「复制」，代码就该进剪贴板）⇒ 解包放在这两步**之后**。
                    UIPasteboard.general.string = code
                    StarryHaptic.impact(.light)
                    guard let self else { return }
                    self.showToast(L("已复制代码"))
                }
                // 正文里的网址：交给宿主 push 内置网页页（2026-10-02）。
                // ⚠️ 回调带的是 URL 本身（不是行号），所以 cell 复用不会张冠李戴。
                cell.onOpenURL = { [weak self] url in
                    guard let self else { return }
                    self.openWebPage(url)
                }
                // 思考块头部被点（2026-10-20）：展开 ⇄ 折叠。行号**现取**（同 onAction 的理由：
                // cell 复用后闭包里捕获的任何行号都会漂），展开态从行上读 —— 它与 cell 上显示的一致。
                cell.onToggleThinking = { [weak self, weak cell] in
                    guard let self = self, let cell = cell,
                          let ip = self.tableView.indexPath(for: cell) else { return }
                    self.manager.setThinkingExpanded(!self.manager.rows[ip.row].isThinkingExpanded,
                                                    atRowIndex: ip.row)
                }
                if case .error = row.block.kind {
                    // 失败提示：正文就是错误说明，没有时间小字（applyMetaFlags 也不给它）
                    cell.configureNotice(row.block.text)
                } else if row.block.isStreaming {
                    cell.configureStreaming(row.block.text,
                                            metaText: row.metaText,
                                            reasoning: row.block.reasoning)
                } else {
                    cell.configureFinal(row.block.text,
                                        showsActionBar: row.showsActionBar,
                                        isSpeaking: speakingRowIndex == indexPath.row,
                                        metaText: row.metaText,
                                        reasoning: row.block.reasoning,
                                        thinkingExpanded: row.isThinkingExpanded)
                }
                return cell
            }
        case .file:
            let cell = tableView.dequeueReusableCell(withIdentifier: "AIUserFileCell", for: indexPath) as! AIUserFileCell
            cell.configure(name: row.block.text, byteSize: row.block.fileSize)
            return cell
        case .modelSwitch:
            // 模型切换系统消息：居中灰字一行。**不分 role**（它只由 `.assistant` 产生，
            // 但这里不写 role 判断 —— 渲染与 role 无关，写了反而多一条会漂的分支）
            let cell = tableView.dequeueReusableCell(withIdentifier: "AISystemNoticeCell", for: indexPath) as! AISystemNoticeCell
            // 文案现取（`L()` 不被缓存 ⇒ 切语言后这一行跟着换），见 `AIBlock.modelSwitchText`
            cell.configure(row.block.modelSwitchText)
            return cell
        case .image:
            // 用户发的图与助手的图共用 `AIChatBlock.image`，但布局完全不同（右侧 / 真实比例），
            // 所以按 role 分流到两个 cell
            if row.role == .user {
                // 🔴 2026-09 用户多图横排（见 `AIUserImageStripCell` 文件头）：
                //    **组内 >1 张**走横排 cell（组首渲染整条、其余行高 0），
                //    **单张**仍走 `AIUserImageCell` 的原尺寸一图一行（用户明确「单张大小不变」）。
                if isUserImageGroupStrip(at: indexPath.row) {
                    let cell = tableView.dequeueReusableCell(withIdentifier: Self.userImageStripCellID,
                                                            for: indexPath) as! AIUserImageStripCell
                    configureUserImageStrip(cell, at: indexPath.row)
                    return cell
                }
                let cell = tableView.dequeueReusableCell(withIdentifier: "AIUserImageCell", for: indexPath) as! AIUserImageCell
                if let url = row.block.imageURL {
                    // 尺寸取的就是量行高用的那一个函数 —— 两边同源，图片不会被裁
                    let size = AIChatRow.userImageDisplaySize(in: manager.contentWidth,
                                                             mediaSize: row.block.mediaSize)
                    cell.configure(url: url, displaySize: size)
                    cell.onPreview = { [weak self] thumbnail in
                        guard let self else { return }
                        self.presentImagePreview(url, thumbnail: thumbnail)
                    }
                }
                return cell
            }
            // 🔴 助手侧的图**不再是「一行一张」**（2026-09-28 改）：连续的助手图片行在界面上是
            // **一条横向滚动的竖版（9:16）缩略图条**，由**组首**那一行的 cell 把整组画出来；
            // 组内其余行高度为 0（`AIChatManager.normalizeMediaGroupHeights()` 归的零）。
            // ⚠️ 用户侧的图 2026-10-09 起也横排了（上面那一支，组内 >1 张），
            //    但**两套形态刻意不同**：助手侧固定 9:16 裁切顶对齐，用户侧按真实比例底对齐。
            //    ⛔ 别把它们并成一个 cell（成因见 `AIUserImageStripCell` 文件头的对照表）。
            let cell = tableView.dequeueReusableCell(withIdentifier: "AIAssistantMediaStripCell", for: indexPath) as! AIAssistantMediaStripCell
            configureMediaStrip(cell, at: indexPath.row)
            return cell
        case .video:
            // 视频与图片**同一组尺寸、同一条横滑条路径**，但两者**分成两条**
            //（划组按 kind —— 用户原话「图片和视频不能在一个 cell」）。
            // 用户不会发视频 ⇒ 这一支恒是助手侧，没有 role 分支。
            let cell = tableView.dequeueReusableCell(withIdentifier: "AIAssistantMediaStripCell", for: indexPath) as! AIAssistantMediaStripCell
            configureMediaStrip(cell, at: indexPath.row)
            return cell
        }
    }

    /// 装配一条媒体横滑条（助手侧图片 / 视频共用）。
    ///
    /// 🔴 **只有组首那一行真的画东西**：要喂给 cell 的是**整组**
    ///（`AIChatMediaGrouping.groupRows`），而不是这一行自己。
    /// ⚠️ 组内非首行给**空数组**、而不是「提前 return 不 configure」—— 本 cell 会被复用，
    ///    不 configure 的话它会留着**上一组**的格子（那种「图片跑到别的消息下面」的 bug
    ///    只在滚动复用时才出现，最难查）。
    /// ⛔ 判据一律走 `AIChatMediaGrouping`（iOS / Mac 同一份），别在这里自己比 `block.kind`。
    private func configureMediaStrip(_ cell: AIAssistantMediaStripCell, at index: Int) {
        let isHead = AIChatMediaGrouping.isGroupHead(manager.rows, at: index)
        cell.configure(rows: isHead ? AIChatMediaGrouping.groupRows(manager.rows, at: index) : [])
        // 单击图片 → 全屏预览（thumbnail 供 zoom 转场定位）；点视频 → 播放。
        // 两条回调都按**点击那一刻**的参数走，不存下标 ⇒ cell 复用不会串（与旧 cell 同一条口径）。
        cell.onPreview = { [weak self] url, thumbnail in
            guard let self else { return }
            self.presentImagePreview(url, thumbnail: thumbnail)
        }
        cell.onPlay = { [weak self] url in
            guard let self else { return }
            self.playVideo(url)
        }
    }

    /// 横向 cell 的复用标识。
    ///
    /// ⚠️ 用 `static let` 而不是散在 `registerCell` 里的字面量：这几处字面量一旦哪次
    /// 少改一个，`dequeue` 会拿到**另一种 cell** 并在 `as!` 上当场崩（好在会崩、不难查，
    /// 但仍属「同一个标识抄两份」的隐患）。新增 cell 时在这里加一条。
    static let userImageStripCellID = "AIUserImageStripCell"

    /// 这一行是不是「用户多图横排」里要画整条的**组首**。
    ///
    /// 🔴 判据是**三个条件同时成立**，缺一个都会出错：
    /// ① 它是用户图片行（`isUserImage`）；
    /// ② 它是组首（`isUserImageGroupHead`）—— 否则组内第 2..N 张会各自画一条
    ///    **重复的**横排（那几张行高为 0，画面上勉强看不见，但 cell 仍被白白创建、
    ///    图片仍被解码，滚动起来白耗性能）；
    /// ③ **组内张数 > 1** —— 单张必须留在 `AIUserImageCell`（用户要求原尺寸）。
    ///
    /// ⛔ 别拿 `occupiesOwnRow` 顶替这一条：那个函数的语义是「这一行有不属于自己的位置」
    /// （选择模式用），它对**单张**也返回 `true`（单张的组首就是它自己）⇒ 用它会把
    /// 单张也拉去横排，直接违背「单张大小不变」。
    private func isUserImageGroupStrip(at index: Int) -> Bool {
        guard AIChatMediaGrouping.isUserImage(manager.rows[index]),
              let range = AIChatMediaGrouping.userImageGroupRange(manager.rows, at: index),
              range.count > 1,
              AIChatMediaGrouping.isUserImageGroupHead(manager.rows, at: index) else { return false }
        return true
    }

    /// 装配用户多图横排（只有组首真的画东西，其余行给**空数组**）。
    ///
    /// ⚠️ 与 `configureMediaStrip` 同一条坑：组内非首行**必须**给空数组而不是提前 return，
    /// 否则复用时会留着上一组的格子（「图片跑到别的消息下面」，只在滚动复用时出现）。
    private func configureUserImageStrip(_ cell: AIUserImageStripCell, at index: Int) {
        let rows = AIChatMediaGrouping.isUserImageGroupHead(manager.rows, at: index)
            ? AIChatMediaGrouping.userImageGroupRows(manager.rows, at: index)
            : []
        // 🔴 `containerWidth` 必须传 `manager.contentWidth` —— 与量行高用的是同一个值，
        //    ⛔ 别传 cell 的 bounds.width（选择模式下编辑态会把 contentView 内缩 4pt，
        //    编辑态那一趟每格尺寸就会与行高对不上）。
        cell.configure(rows: rows, containerWidth: manager.contentWidth)
        cell.onPreview = { [weak self] url, thumbnail in
            guard let self else { return }
            self.presentImagePreview(url, thumbnail: thumbnail)
        }
    }

    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        // 拖动列表 = 用户要把注意力挪回对话 → 底部那块让出去。
        // 键盘靠 `keyboardDismissMode = .interactive`（系统自己跟着手指走）；
        // 「+」面板不是 `inputView` 了，系统看不见它，必须在这里自己收（见 `dismissAttachmentPanelForListDrag`）。
        inputToolbar.dismissAttachmentPanelForListDrag()
        // 拖动列表 = 放弃选字：选中态会吃掉气泡上的触摸，不收掉的话滚动结束后
        // 用户再点这一行就弹不出操作卡了（点哪儿都被 textView 接走）
        endTextSelection()
    }

    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        // 贴底判定留容差（常量见 `bottomPinnedTolerance`）：手指没完全到底时也该继续自动跟随流式输出
        isPinnedToBottom = isListPinnedToBottom()
        // 悬浮按钮跟着每次滚动更新：往上翻历史 → 淡入；回到最后一条 → 收起
        updateScrollToBottomButton()
    }

    // MARK: - 「回到底部」悬浮按钮

    /// 「是否停在最后一条消息」的容差（pt）：手指没完全到底时也该继续自动跟随流式输出。
    ///
    /// ⚠️ **「贴底」全仓只有这一个口径**：`scrollViewDidScroll` 用它维护 `isPinnedToBottom`、
    /// 悬浮按钮的显隐读的也是同一个函数。两处各写一遍 30 的话，迟早出现
    /// 「自动跟随认为到底了、按钮却还挂在屏幕上」这种自相矛盾的状态。
    static let bottomPinnedTolerance: CGFloat = 30

    /// 悬浮按钮边长（44 = 最小可点尺寸）。定义与布局共用这一个值，别在别处再写 44。
    static let scrollToBottomButtonSide: CGFloat = 44

    /// 列表当前是否停在最后一条消息处（容差见上）。
    ///
    /// 刻意**现算**而不是读 `isPinnedToBottom`：那个标志要靠 `scrollViewDidScroll` 才会刷新，
    /// 而「内容不足一屏」「`scrollToRow` 没产生位移」这些情况下滚动回调不一定会来，
    /// 标志就会停在旧值上（表现为按钮一直挂在屏幕上收不掉）。
    func isListPinnedToBottom() -> Bool {
        tableView.contentOffset.y + tableView.bounds.height
            >= tableView.contentSize.height - Self.bottomPinnedTolerance
    }

    /// 把按钮摆到输入栏正上方、贴右侧。
    ///
    /// 输入栏是 frame 布局且会随键盘 / 「+」面板整体上移，所以**每次输入栏变形都要重算**
    /// （入口：`inputToolbar.onFrameChange` 与 `viewDidLayoutSubviews`，与录音浮层同一套）。
    func layoutScrollToBottomButton() {
        guard scrollToBottomButton.superview != nil, view.bounds.width > 0 else { return }
        let side = Self.scrollToBottomButtonSide
        let gap: CGFloat = 12      // 与输入栏之间的留白（同录音浮层）
        let margin: CGFloat = 16   // 右边距（同输入栏 horizontalMargin）
        let y = max(tableView.frame.minY + 8, inputToolbar.frame.minY - gap - side)
        let target = CGRect(x: view.bounds.width - margin - side,
                            y: y,
                            width: side,
                            height: side)
        if scrollToBottomButton.frame != target { scrollToBottomButton.frame = target }
    }

    /// 按「下面还有没有内容」显隐按钮（淡入淡出）。
    ///
    /// 四个附加条件都不是多余的：
    /// - `mode == .chat`：落地页没有列表；
    /// - `rows` 非空：空会话没什么可回的；
    /// - `!isVoiceSessionActive`：录音浮层正好占着输入栏上方这块地方，不藏会叠在一起；
    /// - `!isSelectionMode`：多选删除时它会盖住最后几行，而且「回到最新」这件事与挑消息无关。
    func updateScrollToBottomButton() {
        guard isViewLoaded else { return }
        let shouldShow = mode == .chat
            && !manager.rows.isEmpty
            && !isVoiceSessionActive
            && !isSelectionMode
            && !isListPinnedToBottom()
        guard shouldShow != isScrollToBottomButtonShown else { return }
        isScrollToBottomButtonShown = shouldShow
        // 触摸权立刻跟着切，**不等淡出动画结束**：淡出那 0.18s 里不该再吃掉本该给列表的点击
        scrollToBottomButton.isUserInteractionEnabled = shouldShow
        UIView.animate(withDuration: 0.18) { [weak self] in
            guard let self else { return }
            self.scrollToBottomButton.alpha = shouldShow ? 1 : 0
        }
    }

    @objc func handleScrollToBottomTap() {
        StarryHaptic.impact(.light)
        // 手动回到底部 = 用户重新要跟随流式输出，先把贴底标志置回来
        isPinnedToBottom = true
        scrollToBottom(animated: true)
        // 滚动回调会负责收起按钮；这里补一次是为了「内容不足一屏、`scrollToRow` 没有位移」
        // 那种滚动回调不来的情况，别让按钮赖着不走
        updateScrollToBottomButton()
    }

    // MARK: - 竖排操作卡菜单（自定义气泡，长按 cell 弹出）

    /// cell 长按手势：长按取 location，使菜单能按「用户实际按压的位置」弹出（箭头指向按压处）。
    ///
    /// ⚠️ **别把 `cancelsTouchesInView` 改成 `false`**：默认 `true` 会在长按识别后取消触摸，
    /// 而这正是「长按松手那一拍不会顺带触发 `didSelectRowAt`」的**唯一保障**
    /// （否则长按自己发的消息松手会顺带进编辑态）。旁边那条「轻点收面板」的手势刻意设了
    /// `false`，照抄过来就会坏；`require(toFail:)` 只挡得住手势，**挡不住表格内部的选中机制**。
    func setupCellLongPressGesture() {
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handleCellLongPress(_:)))
        press.minimumPressDuration = 0.5
        press.name = AIModuleViewController.cellLongPressName
        press.delegate = self
        tableView.addGestureRecognizer(press)
    }

    /// 开关「长按弹操作卡」。选择模式下必须关掉：长按同一行又弹出一张卡的话，
    /// 卡片浮在列表上方与勾选抢同一块区域（而且卡片上的项此时大多没有意义）。
    ///
    /// ⚠️ 复用 `setupCellLongPressGesture` 注册时用的**名字**来找它：
    /// `tableView.gestureRecognizers` 里还有表格自己的内部手势，按类型找会挑错人。
    func setCellLongPressEnabled(_ enabled: Bool) {
        tableView.gestureRecognizers?
            .first { $0.name == Self.cellLongPressName }?
            .isEnabled = enabled
    }

    // MARK: - 轻点列表收起「+」面板

    /// 「轻点列表」那条手势的名字。
    /// 只用来在 `shouldRecognizeSimultaneouslyWith` 里认出它自己 —— 别的办法都得额外存一份引用。
    static let listBlankTapName = "aimodule.listBlankTap"

    /// 长按那条手势的名字。轻点要 `require(toFail:)` 它，而 `tableView.gestureRecognizers` 里
    /// **还有表格自己的内部手势**（滚动、高亮…）说不定也含长按 —— 按类型找会挑错人，按名字找才准。
    static let cellLongPressName = "aimodule.cellLongPress"

    /// 轻点对话列表 → 收起「+」面板。
    ///
    /// 为什么要自己接：面板已经是**输入栏自己的子视图**，不再是 `textView.inputView`，
    /// 系统那套「点一下就收键盘」不认识它（拖动那条同理，见 `scrollViewWillBeginDragging`）。
    /// 键盘那条路不动 —— 它归系统管，面板没开时这条手势就是空转。
    ///
    /// ⚠️ 两处都要处理，否则会打坏已有交互：
    /// - `require(toFail:)` 长按：长按是「按住不放」，松手那一拍轻点手势也会成立 ——
    ///   不排这个失败依赖，菜单刚弹出来就被「收面板」顶掉了；
    /// - 与 cell 自己的手势**同时识别**（见 `shouldRecognizeSimultaneouslyWith`）：
    ///   图片 cell 那条「点开大图」也在这一层，默认互斥 → 轻则点图不关面板，重则预览被顶掉。
    func setupListBlankTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleListBlankTap(_:)))
        tap.name = AIModuleViewController.listBlankTapName
        tap.delegate = self
        tap.cancelsTouchesInView = false     // 只旁观，不接管 cell 的点击
        // 必须在 `setupCellLongPressGesture()` **之后**调用（要能按名字找到那条长按）
        if let press = tableView.gestureRecognizers?
            .first(where: { $0.name == AIModuleViewController.cellLongPressName }) {
            tap.require(toFail: press)
        }
        tableView.addGestureRecognizer(tap)
    }

    @objc private func handleListBlankTap(_ tap: UITapGestureRecognizer) {
        // 选择模式下轻点只用于勾选：进来时该收的（选字 / 编辑态 / 面板）已经收过一遍，
        // 这里再做一遍只会多出无谓的状态抖动
        if isSelectionMode { return }
        // 「选中文字」态下点别处 = 退出选择（否则那一行的气泡会一直吃触摸）
        endTextSelection()
        // 点列表别处 = 放弃编辑（2026-09-17 加）
        //
        // ⚠️ 但「点的就是自己发的那条文字」时**不能退出**：那一拍正在走 `didSelectRowAt`
        // 进编辑。这条 tap 是 `cancelsTouchesInView = false`（只旁观），所以两条都会收到
        // 这次触摸，**先后顺序由 UIKit 决定、不可依赖** —— 不判一下就会变成
        // 「刚进编辑就被退出 + 输入栏被清空」，编辑功能整个用不了。
        if !tapLandsOnEditableUserText(tap) {
            exitEditing(clearInput: true)
        }
        // 面板没开时是空转（内部 `guard isAttachmentPanelVisible`）
        inputToolbar.dismissAttachmentPanelForBlankTap()
    }

    /// 这次轻点是不是落在一行「可编辑的用户文字」上（那种情况归 `didSelectRowAt` 管，别抢）。
    ///
    /// 命中判定与 `didSelectRowAt` **必须是同一个口径**（都是整行矩形）：若这边收紧成
    /// 「只认内容块」而那边是整行，点气泡外的留白就会「进编辑」与「退出编辑 + 清空」
    /// 同时发生，净效果是输入栏莫名其妙空掉。
    private func tapLandsOnEditableUserText(_ tap: UITapGestureRecognizer) -> Bool {
        let point = tap.location(in: tableView)
        guard let ip = tableView.indexPathForRow(at: point),
              ip.row < manager.rows.count else { return false }
        let row = manager.rows[ip.row]
        guard row.role == .user, case .text = row.block.kind else { return false }
        return true
    }

    /// 轻点某一行，**两类**有反应：
    /// ① **自己发的文字** → 进入编辑态（正文回填输入栏 + 弹键盘）；
    /// ② **文件行** → push 系统预览页（2026-10-06 加，见 `openFilePreview`）。
    /// 其余一律不响应 —— 助手回复 / 失败提示点了什么都不做。
    ///
    /// ⚠️ **操作卡不再由轻点唤起**（2026-09-17 改）：两个入口彻底分工 ——
    /// 长按「内容块」= 竖排操作卡（`handleCellLongPress`），轻点 = 编辑自己发的那条 / 打开文件。
    /// 原先「轻点也弹卡」的前提仍然成立（气泡正文的 textView 未选中态不参与命中测试，
    /// 触摸会走到表格的选中机制里来，见 `BubbleTextView.point(inside:)`），只是那一拍现在归编辑。
    ///
    /// ⚠️ 轻点的图片预览 / 视频播放**不经这里**（各自 cell 的 tap / `UIControl` 按钮），
    /// 所以这里**只为文件行**按 kind 分流 —— 文件卡片自己没有手势（见 `AIUserFileCell`）。
    /// 选择模式：**只让「自己占一行」的行进勾选集合**（2026-09-29）。
    ///
    /// 🔴 零高度的媒体非组首行必须在这里挡住：它们没有可见的勾选圈，勾上了用户也看不见，
    /// 而 `UITableView` 会照样把圈画出来（症状：图片横滑条与视频横滑条交界处冒半截蓝圈），
    /// 更糟的是它们留在集合里会让「取消勾选整条横滑条」变成假的
    ///（成因与两个症状都写在 `+Selection.isCheckableRow(at:)`）。
    /// 返回 `nil` = 「这一行不可选」，表格自己就不会勾上它（也不需要 `deselectRow` 回滚）。
    ///
    /// ⚠️ `selectRow(at:)` 是**程序化**的、不过这一道闸 —— 所以 `enterSelectionMode` 里
    ///    默认勾整轮那一趟必须自己过一遍同一个判据，**两处缺一不可**。
    /// 非选择模式下原样放行：那条路只用来「轻点自己发的文字进编辑态」，语义不变。
    public func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard isSelectionMode else { return indexPath }
        return isCheckableRow(at: indexPath.row) ? indexPath : nil
    }

    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        // 选择模式：勾选由表格自己维护（这是「多选」的机制本身），这里只把导航栏那两颗按钮
        // 跟着刷一遍。⚠️ **绝不能走下面的 `deselectRow`** —— 那会把刚勾上的一行立刻取消掉，
        // 多选整个失效。
        if isSelectionMode {
            StarryHaptic.impact(.light)
            updateSelectionUI()
            return
        }
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < manager.rows.count else { return }
        let row = manager.rows[indexPath.row]
        // 🔴 **文件行：轻点 = 打开预览页**（2026-10-06 用户要求）。
        // ⚠️ 必须排在下面那条 `case .text` 的 guard **之前** —— 否则会被它直接挡掉，
        //    而症状是「点了一点反应都没有」（那条 guard 是**静默** return 的，不弹提示）。
        // ⚠️ 这里**刻意不判 role**：`.file` 目前只由附件面板产生（只有用户侧），但不写 role
        //    判断，将来助手侧也能发文件时不会出现两处口径分叉 —— 与
        //    `AIRowAction.chatMenu(for:)` 里那句「附件行不分 role」是同一个口径。
        if case .file = row.block.kind {
            // `AIBlock.fileURL` 是**可选**（历史数据/异常路径可能没有）⇒ 拿不到就静默返回：
            // 进一个既没文件名也没内容的预览页，比「没反应」更像坏了。
            guard let url = row.block.fileURL else { return }
            // 🔴 显示名取 `block.text`（用户当初发的那份文件名），**不是** `url.lastPathComponent`
            // —— 附件落盘时名字被换成了 UUID，磁盘名用户根本认不出来（2026-10-06 实拍踩到，
            // 详见 `AIFilePreviewController` 文件头）。
            openFilePreview(url, displayName: row.block.text)
            return
        }
        // 类型判定必须写在这里，**不能直接调 `enterEditing` 靠它的 guard 兜底**：
        // 那两道 guard 是给长按菜单那条路写的（会 showToast「这条没有可编辑的文字」），
        // 轻点助手回复会冒出不该有的提示。
        guard row.role == .user, case .text = row.block.kind else { return }
        // 流式中不给进（静默）：一旦进编辑，发送时会截断列表并起新流 —— 先把当前这轮让完。
        // 这里刻意不 toast：轻点误触率高，弹提示会比"没反应"更烦。
        guard !isStreaming else { return }
        enterEditing(atRow: indexPath.row)
    }

    /// 取消勾选某一行（选择模式下由系统回调）。与 `didSelectRowAt` 对称：只刷导航栏。
    public func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        guard isSelectionMode else { return }
        StarryHaptic.impact(.light)
        updateSelectionUI()
    }

    /// 行即将上屏：把「系统行选中底色」按当前模式切好，并把表格记录的勾选状态补回 cell。
    ///
    /// ⚠️ **为什么改 `selectionStyle`**：六种 cell 都在 `init` 里设了 `.none`（气泡自带样式，
    /// 不要系统的灰色高亮）。勾选对号是系统编辑控件画的、与它无关，但**选中底色的有无**
    /// 由它决定 —— 长列表里光靠对号找「勾了哪几条」太费眼。
    /// 放在 `willDisplay` 而不是六个 `cellForRowAt` 分支里：那里有六个 `return`，
    /// 漏一个就是「这一种选中看不出来」，而且新增 cell 类型时不会有人记得回来补。
    ///
    /// `setSelected` 那一句是**兜底**：进编辑态那一拍 `selectRow` 早于 cell 建成时，
    /// 圆圈可能没跟上（系统不保证顺序）；这里按表格的勾选真值再对齐一次。
    /// 它不会触发 `didSelectRowAt`（那个只由用户交互产生），所以不会与勾选联动打架。
    ///
    /// 🔴 那行 `clipsToBounds` 是**给「零高度的媒体非组首行」准备的兜底**（2026-09-29）：
    /// 表格一进编辑态就会给每个 cell 摆一个勾选圈（**不管这一行勾没勾上**），而零高度的 cell
    /// 会把控件贴着顶边往下落 ⇒ 交界处露出半截圈。裁掉即可 —— 这些行本来就没有任何内容。
    /// ⚠️ 必须**两向都写、且写在 `guard` 之前**：cell 是复用的，只设 `true` 不还的话，
    ///    普通行会被上一轮的裁切带上（症状是「滚过去再滚回来，气泡/图片被裁掉一截」，
    ///    只在复用后出现，且只在这种 cell 上）—— 写在 `guard` 之后就会被「非选择模式」漏掉。
    public func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell,
                          forRowAt indexPath: IndexPath) {
        cell.selectionStyle = isSelectionMode ? .default : .none
        // 自带手势 / 控件的内容块在选择模式下要让出触摸，否则那一行永远勾不上（见协议说明）
        (cell as? AIChatSelectionTouchYielding)?.setSelectionMode(isSelectionMode)
        cell.clipsToBounds = !AIChatMediaGrouping.occupiesOwnRow(manager.rows, at: indexPath.row)
        guard isSelectionMode else { return }
        let checked = tableView.indexPathsForSelectedRows?.contains(indexPath) == true
        if cell.isSelected != checked { cell.setSelected(checked, animated: false) }
    }

    /// 长按 cell → 弹竖排操作卡。
    ///
    /// ⚠️ **长按不再直接进入「选中文字」态**（2026-09-17 改）：原先的分流是「长按气泡正文 = 选字、
    /// 长按别处 = 弹卡」，但两者用的是同一条长按手势，用户实测互相冲突（想选字弹出了菜单、
    /// 想弹菜单却进了选字）。现在长按**一律弹卡**，选字是卡里的竖排第一项。
    ///
    /// 选中态里长按仍然是「原生扩选」—— 那种情况下宿主这条手势根本收不到触摸
    /// （`gestureRecognizer(_:shouldReceive:)` 排除了 `BubbleTextView`）。
    @objc private func handleCellLongPress(_ press: UILongPressGestureRecognizer) {
        // 菜单弹出后全屏遮罩已拦截触摸，能走到这里的都是 tableView 内的长按
        guard press.state == .began else { return }
        // 选择模式下长按不弹卡：手势本身已被 `setCellLongPressEnabled(false)` 关掉，
        // 这里是兜底 —— 万一将来有别的入口把开关打回 true，也不会两层 UI 叠在一起
        guard !isSelectionMode else { return }
        let pointInTable = press.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: pointInTable),
              indexPath.row < manager.rows.count,
              let cell = tableView.cellForRow(at: indexPath) else { return }
        // 🔴 系统消息（模型切换）**不长按出任何东西**（用户明确「不用有任何点击事件和交互」）。
        //    排在触感之前：不弹就不该给反馈 —— 「按了没反应却嗡一下」比不反馈更怪。
        //    （`presentActionMenu` 里那道 `guard !actions.isEmpty` 是第二道闸，留着。）
        if case .modelSwitch = manager.rows[indexPath.row].block.kind { return }
        // ⚠️ **只认「内容块」**（2026-09-17 改）：`indexPathForRow(at:)` 的判定单位是
        // **整行矩形**（不是「点到了哪个视图」），而气泡宽度是文案撑出来的（约束是
        // 「≤ 80% 屏宽」的 `lessThanOrEqualTo`）→ 旁边那圈留白全落在这行矩形里，
        // 长按留白也会弹卡。各 cell 的内容块视图不同，由 cell 自己回答。
        if let block = (cell as? AIChatContentBlockProviding)?.contentBlockView {
            // 点转到内容块自己的坐标系再判 bounds —— 跟着实际布局走，不手算 frame
            //
            // 🔴 **`convert` 的基准是「接收者」**：`a.convert(p, to: b)` ≡ `b.convert(p, from: a)`，
            // 都表示「p 当前在 **a** 坐标系，要转到 b 坐标系」。
            // ⛔ 别写成 `cell.convert(pointInTable, to: block)` —— 那等于把 **tableView 坐标**
            // 当成 **cell 坐标**，结果整体偏移「cell 在表里的位移」：越靠下的行偏得越多，
            // 所有行都判成未命中（2026-09-17 实测症状：长按**完全弹不出**卡，
            // 而编译 / 类型检查**一条错都不报**，代码看起来完全合理）。
            let pointInBlock = block.convert(pointInTable, from: tableView)
            guard block.bounds.contains(pointInBlock) else { return }
        }
        // 长按到位触发菜单，轻触感反馈
        StarryHaptic.impact(.light)
        presentActionMenu(at: indexPath.row, tapPoint: press.location(in: view))
    }

    /// 退出所有可见行的「选中文字」态。
    ///
    /// 只遍历**可见行**：不可见的 cell 早已被复用（`prepareForReuse` 会自己复位），
    /// 全表 `visibleCells` 已经足够，也避免为了复位去建一堆离屏 cell。
    func endTextSelection() {
        for cell in tableView.visibleCells {
            (cell as? AIBubbleTextSelecting)?.endTextSelection()
        }
    }

    // MARK: - 搜索结果定位

    /// 滚到某条消息并闪一下（搜索页点结果 → 打开会话 → 这里负责「就是这一条」）。
    ///
    /// ⚠️ 必须**先 `layoutIfNeeded` 再滚**：`reloadData` 之后表格还不知道各行的位置，
    /// 此刻 `scrollToRow` 会落在错的偏移上（首次载入历史会话时必然踩到）。
    func revealMessage(id: UUID) {
        guard mode == .chat else { return }
        guard let index = manager.rows.firstIndex(where: { $0.block.id == id }) else {
            // 消息可能已被重新生成删掉 / 会话已变 —— 别静默什么都不做，给个交代
            showToast(L("这条消息已不在当前会话里"))
            return
        }
        let ip = IndexPath(row: index, section: 0)
        tableView.layoutIfNeeded()
        // 用户此刻要看的是历史消息 → 不再跟随底部（否则下一条流式回复又会把视图拽走）
        isPinnedToBottom = false
        tableView.scrollToRow(at: ip, at: .middle, animated: false)
        updateScrollToBottomButton()
        // 滚完再取 cell：此刻它才真正在屏上（`cellForRow(at:)` 对不可见的行返回 nil）
        tableView.cellForRow(at: ip)?.flashFocusHighlight()
    }

    /// 长按 cell：收起旧菜单后，在用户实际按压位置旁弹出竖排操作卡
    private func presentActionMenu(at row: Int, tapPoint: CGPoint? = nil) {
        dismissActionMenu()
        guard row < manager.rows.count,
              let cell = tableView.cellForRow(at: IndexPath(row: row, section: 0)) else { return }

        // 操作卡与气泡下方的操作栏共用同一份动作定义（`AIRowAction`）。
        // **按行类型给不同集合**：给失败提示挂「喜欢/朗读」、给用户消息挂「重新生成」都是噪音，
        // 用户会在一堆无效项里找不到那个真正有用的按钮。
        let layout = AIRowAction.chatMenu(for: manager.rows[row])
        // 流式进行中把「不能与流共存」的项摘掉 —— 两类，都归 `blockedWhileStreaming` 表达：
        // ① 会 `stop()` 掉当前流再起一条的（`restartsStream`，两个流互相踩）；
        // ② 「删除」（删行会让后面所有行的下标前移，而流式正靠 `streamingRowIndex` 写那一行）。
        // 菜单项没有置灰态，直接不给比给个点不动的更清楚。
        // ⚠️ **只过滤给用户的项、不改 `Menu` 数组**：过滤是运行时的，数组是产品定的排版。
        // 这段过滤**不能跟着删** —— 将来往任一菜单里加回会打断流的动作时，它还得接着用。
        // ⚠️ **两段要分别过滤**：先合并再过滤的话，横排/竖排的分界就错了 ——
        // 「选取文字」会被挤进横排，而它的位置是产品指定的，不能随运行状态漂移。
        let grid = isStreaming ? layout.grid.filter { !$0.blockedWhileStreaming } : layout.grid
        let list = isStreaming ? layout.list.filter { !$0.blockedWhileStreaming } : layout.list
        let actions = grid + list
        guard !actions.isEmpty else { return }

        // 选中态与操作卡是两套 UI，不能同时存在：弹卡前先把别处的选字收掉
        //（选中态会吃掉那一行气泡上的触摸，留着它会与卡片抢焦点）
        endTextSelection()

        let targetRow = row
        // 收键盘，避免遮罩/定位受键盘影响
        view.endEditing(true)

        let items: [AIChatActionMenuView.Item] = actions.map {
            // `isDestructive` 必须一起传：漏了的话「删除」会画成普通黑色项，
            // 在一列同色文字里失去「这是危险操作」的唯一提示
            AIChatActionMenuView.Item(icon: $0.icon, title: $0.title,
                                      isDestructive: $0.isDestructive)
        }
        let menu = AIChatActionMenuView(items: items, gridCount: grid.count) { [weak self] index in
            // ⚠️ 下标是**子集里的下标**，必须从同一份 `actions` 取，不能再用 rawValue 反查
            // （子集与 `allCases` 顺序不同 —— 按 rawValue 取会点「复制」执行「朗读」）
            guard index < actions.count else { return }
            guard let self else { return }
            // 把「长按位置」一起带下去：选字要用它定位到用户按住的那一行
            //（`tapPoint` 是弹卡那一刻捕获的，之后列表滚动也不影响 —— 它是 cell 内的相对位置）
            self.performRowAction(actions[index], rowIndex: targetRow, tapPoint: tapPoint)
        }
        actionMenuView = menu
        if let tapPoint = tapPoint {
            // 点击点夹在 cell 范围内，保证箭头尖端不跑出气泡边界
            let cellFrame = cell.convert(cell.bounds, to: view)
            let x = min(max(tapPoint.x, cellFrame.minX + 12), cellFrame.maxX - 12)
            let y = min(max(tapPoint.y, cellFrame.minY + 8), cellFrame.maxY - 8)
            menu.show(in: view, anchorPoint: CGPoint(x: x, y: y))
        } else {
            // 兜底：无点击坐标时以气泡中心为锚
            let anchor = cell.convert(cell.bounds, to: view)
            menu.show(in: view, anchorPoint: CGPoint(x: anchor.midX, y: anchor.midY))
        }
    }

    /// 收起当前操作卡（无则不动）
    func dismissActionMenu() {
        actionMenuView?.dismiss(animated: false)
        actionMenuView = nil
    }
}

// MARK: - UIGestureRecognizerDelegate

extension AIModuleViewController: UIGestureRecognizerDelegate {

    /// 点击命中 UIControl（视频播放按钮 / 消息复制按钮等）时，把触摸让给控件本身，
    /// 长按弹菜单与轻点收面板都不接管；其余区域（文本/图片 cell、列表空白）才归手势。
    ///
    /// 同时排除 `BubbleTextView`：**只有它进入「选中文字」态时才会被命中到**
    /// （未选中时 `point(inside:)` 就返回 false，根本到不了这里），
    /// 那种状态下触摸该由文本框自己处理（放大镜、拖柄、编辑菜单），宿主两条手势都不该插手 ——
    /// 不排除的话选中态里的原生长按「扩选」会顺带弹出操作卡，两层 UI 叠在一起。
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: tableView)
        guard let hit = tableView.hitTest(point, with: nil) else { return false }
        return !(hit is UIControl) && !(hit is BubbleTextView)
    }

    /// 只给「轻点列表收面板」开绿灯，**别的一律保持默认互斥**。
    ///
    /// 两个手势默认不能同时识别：`tableView` 上那条轻点与 cell 自己的轻点（图片/视频 cell 的
    /// 「点开大图」）会互斥 —— 要么点图不关面板，要么**预览直接被顶掉**（真正的回归）。
    /// 这里按名字精确放行这一对；长按 ⇄ 表格滚动的仲裁不受影响（它们俩都不叫这个名字）。
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer.name == AIModuleViewController.listBlankTapName
            || other.name == AIModuleViewController.listBlankTapName
    }
}
