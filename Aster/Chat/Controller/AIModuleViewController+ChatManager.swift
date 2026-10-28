import UIKit
import AICore

/// 流式回复的下行事件：`AIChatManager` 把「数据层发生了什么」通知上来，这里只负责**最小刷新**。
///
/// ## 三条刷新纪律（改这里之前先读）
/// 1. **流式不刷整表**：`chatManagerDidUpdateStreamingText` 只改末 cell 的 textView，
///    再用 `begin/endUpdates` 顶一次行高 —— `reloadRows`/`reloadData` 会把正在生长的
///    气泡闪没，还会把用户滚动位置弹回顶部。
/// 2. **贴底才自动滚**：`isPinnedToBottom` 由 `+Table` 的 `scrollViewDidScroll` 维护，
///    用户往上翻历史时**不能**硬把他拽回底部。
/// 3. **行的附加结构变了必须走 `reloadRows`**：`begin/endUpdates` 只重问高度、
///    不会重跑 `cellForRowAt`，操作栏的显隐就刷不出来。
extension AIModuleViewController: AIChatManagerDelegate {

    public func chatManagerDidInsertRows(_ manager: AIChatManager, at indexes: [Int]) {
        let ips = indexes.map { IndexPath(row: $0, section: 0) }
        tableView.insertRows(at: ips, with: .automatic)
        if isPinnedToBottom { scrollToBottom(animated: true) }
        // 行数变了 → 内容高度变了。贴底那条路会因滚动回调自动更新，但「从空列表变成有内容」
        // 「内容不足一屏」时滚动回调不一定来，这里补判一次，别让按钮停在过期状态
        updateScrollToBottomButton()
    }

    public func chatManagerDidUpdateStreamingText(_ manager: AIChatManager, rowIndex: Int, text: String) {
        let ip = IndexPath(row: rowIndex, section: 0)
        if let cell = tableView.cellForRow(at: ip) as? AIAssistantTextCell {
            // ⚠️ 必须把 `metaText` 一起传：`configureStreaming` 内部会按它重设小字行，
            // 漏传等于每来一个字就把刚显示出来的时间抹掉（表现为时间戳一闪一闪）
            // ⚠️ `reasoning` 也必须一起传：思考先于正文到达，正文 tick 若不把它带回去，
            //    会把刚显示出来的思考块**擦掉**（`configure` 的判据是「参数是不是 nil」）
            cell.configureStreaming(text,
                                    metaText: manager.rows[rowIndex].metaText,
                                    reasoning: manager.rows[rowIndex].block.reasoning)
        }
        tableView.beginUpdates()
        tableView.endUpdates()
        if isPinnedToBottom { scrollToBottom(animated: false) }
    }

    /// 流式**思考过程**刷新（2026-10-20）：思考先于正文到达，此刻正文字段还是空的。
    ///
    /// 与 `chatManagerDidUpdateStreamingText` 同一套最小刷新：只重配末行的思考子块 +
    /// `begin/endUpdates` 顶一次行高。⛔ 别用 `reloadRows` —— 那会重跑 `cellForRow`，
    /// 把正在流式的行整棵视图树拆装（本文件头部纪律 1）。
    public func chatManagerDidUpdateStreamingReasoning(_ manager: AIChatManager, rowIndex: Int) {
        let ip = IndexPath(row: rowIndex, section: 0)
        if let cell = tableView.cellForRow(at: ip) as? AIAssistantTextCell {
            let row = manager.rows[rowIndex]
            cell.configureStreaming(row.block.text,
                                    metaText: row.metaText,
                                    reasoning: row.block.reasoning)
        }
        tableView.beginUpdates()
        tableView.endUpdates()
        if isPinnedToBottom { scrollToBottom(animated: false) }
    }

    public func chatManagerDidFinalizeRow(_ manager: AIChatManager, rowIndex: Int) {
        let ip = IndexPath(row: rowIndex, section: 0)
        let row = manager.rows[rowIndex]
        let text = row.block.text
        if let cell = tableView.cellForRow(at: ip) as? AIAssistantTextCell {
            // 收尾这一行可能是「失败提示」：空占位行在出错时被就地改了 kind，渲染方式要跟着换
            if case .error = row.block.kind {
                cell.configureNotice(text)
            } else {
                // 操作栏归属与小字文案都可能在最后一次重排里刚变过（`refreshRowDecorations`），
                // 所以这里必须重传一次，别指望 cell 上残留的状态还是对的
                // `reasoning` / `thinkingExpanded` 同理（2026-10-20）：收尾时思考块折叠成一行，
                // 用户之后可点开 —— 展开态是行上的运行时状态，必须原样带回 cell
                cell.configureFinal(text,
                                    showsActionBar: row.showsActionBar,
                                    isSpeaking: speakingRowIndex == rowIndex,
                                    metaText: row.metaText,
                                    reasoning: row.block.reasoning,
                                    thinkingExpanded: row.isThinkingExpanded)
            }
        }
        tableView.beginUpdates()
        tableView.endUpdates()
        if isPinnedToBottom { scrollToBottom(animated: false) }

        // 「这一轮没写完」要**主动说一声**。不提示就等于这个功能不可发现 ——
        // 「继续生成」只挂在长按操作卡里（气泡下方那条操作栏是 4 颗固定项，塞不下条件项），
        // 用户看到半句话只会以为「模型就是这么答的」。
        // ⚠️ 与 `didError` 不会撞车：出错收尾的行不标截断（manager 的 `endedByError`），
        // 所以「失败提示」与「被截断提示」互斥。
        if row.block.endedTruncated {
            showToast(L("回复没写完，长按这条可「继续生成」"))
        }

        // 🔴 这一轮的正文**上屏完了** → 转告通话页念出来。
        //    这是朗读转发的**主入口**（`finishStreamingUI` 里那段说明了为什么不能在那儿转发）。
        forwardReplyToVoiceCall()
    }

    /// 整表内容被替换（「重新生成 / 重试」= 删掉若干行 + 立刻插入新的占位行；
    /// 「删除一整轮」= **只删不插**）：行数变了，增量刷新既啰嗦又容易算错下标，直接整表重建。
    ///
    /// ⚠️ 这里**只做 reloadData**，不做插入：manager 是「先发本回调（此刻行数已减完）
    /// 再 appendRow 新的占位行」，两边行数始终对得上，紧接着那次 `insertRows` 才不会抛异常。
    public func chatManagerDidReplaceRows(_ manager: AIChatManager) {
        // 旧行整段换掉 → 指向它们的选中态 / 操作卡 / 朗读都要收掉（否则会指着一个不存在的行）
        endTextSelection()
        dismissActionMenu()
        stopSpeech()
        tableView.reloadData()
        updateScrollToBottomButton()
        // 重新生成的回复长在最后：无论用户之前滚到哪儿，都该跟上去看新内容
        if isPinnedToBottom { scrollToBottom(animated: false) }
    }

    public func chatManagerDidFinish(_ manager: AIChatManager) {
        finishStreamingUI()
        // 这一轮回复生成完毕。用户等长回复时多半切去了别的 App ⇒ 不在前台才发通知
        // （前台判断在 notifier 内部，这里无条件调即可）
        // ⚠️ 描述用**本轮发送的文本**（`latestUserPrompt`），不是会话标题 ——
        //    标题是首条消息，多轮对话后会文不对题（2026-10-19 用户反馈）。
        AIReplyNotifier.replyFinished(conversationId: manager.activeConversationId,
                                      prompt: manager.latestUserPrompt)
    }

    /// 行的附加结构变了（操作栏出现/收起）：行高已由 manager 重算，这里只需让这些行重新配置自己。
    /// ⚠️ 必须走 `reloadRows` 而不是 `begin/endUpdates`——后者只重问高度，不会重新跑 `cellForRowAt`，
    /// 操作栏的显隐就刷不出来。只 reload 目标行，**不影响正在流式的末行**。
    public func chatManagerDidUpdateRowLayout(_ manager: AIChatManager, atRowIndexes indexes: [Int]) {
        let ips = indexes.filter { $0 < manager.rows.count }.map { IndexPath(row: $0, section: 0) }
        guard !ips.isEmpty else { return }
        tableView.reloadRows(at: ips, with: .none)
        if isPinnedToBottom { scrollToBottom(animated: false) }
    }

    public func chatManager(_ manager: AIChatManager, didError error: Error) {
        finishStreamingUI()
        showToast(String(format: L("出错了：%@"), error.localizedDescription))
        // 🔴 兜底转发：**发起之前**就失败的错误（缺 Key / 地址非法）在 `AIChatManager` 里是
        //    几处**同步** `didError`，`handleError` 根本没进 ⇒ 一行都没动、也不会有
        //    `chatManagerDidFinalizeRow`。不在这里补一刀，通话页会**永久卡在「正在思考…」**
        //    （用户以为还在等，其实早就断了 —— 一次断网就够了）。
        //    ⚠️ 与 finalize 那条重复时安全（通话页侧有状态守卫）。
        //    ⚠️ 出错时 `latestAssistantSpeech()` 返回 nil ⇒ 通话页不念，直接接回「听着」。
        forwardReplyToVoiceCall()
        // 同上：失败也通知（用户切走后更该知道「挂了、原因是什么」）。
        // ⚠️ 同步类错误（刚点发送就缺 Key）那一刻用户必然在前台 ⇒ notifier 内部会挡掉，不扰民。
        AIReplyNotifier.replyFailed(conversationId: manager.activeConversationId,
                                    prompt: manager.latestUserPrompt,
                                    reason: error.localizedDescription)
    }

    /// 上下文超预算、最早的若干条被丢掉了。
    ///
    /// 这里**只提示、不阻止**：裁多裁少都是估算值（模块里没有 tokenizer），
    /// 拿估算去拦请求，会把本来发得出去的内容挡在门外 —— 那比让服务端自己报错更糟。
    /// 提示的意义是「模型为什么像失忆了一样」，所以必须把原因说出来，
    /// 否则用户只会以为这模型不行。同一会话只提示一次（门禁在 manager 侧）。
    public func chatManager(_ manager: AIChatManager, didTrimContext droppedCount: Int, isOverBudget: Bool) {
        if isOverBudget {
            // 连「当前提问」都快装不下了：这一轮大概率失败。说清楚，别让他对着转圈猜
            showToast(L("上下文已超出模型上限，这一轮可能失败"))
        } else {
            showToast(String(format: L("上下文较长，已省略最早 %d 条消息"), droppedCount))
        }
    }

    /// 复位「正在回复」状态。
    /// 只被上面两个收尾回调用到，故留在本文件；主文件/输入栏读的是 `isStreaming` 本身。
    private func finishStreamingUI() {
        isStreaming = false
        // ☠️☠️ 这里**不许**转告通话页（2026-10-12 改，真事故）—— 转发挪到
        //    `chatManagerDidFinalizeRow`（主入口）与 `chatManager(_:didError:)`（兜底）。
        //
        //    本方法挂在 `chatManagerDidFinish` 上，而那是「**流**结束」的当下。
        //    `AIChatManager.finish()` 里白纸黑字写着「流结束 ≠ 已经上屏完」：
        //    正文由打字机（`tickReveal`）按 0.03s/帧、每帧最多 12 字慢慢写进 `block.text`。
        //    ⇒ 此刻 `latestAssistantSpeech()` 取到的是**已上屏的那一截**，差的就是还没吐出来的
        //    部分，用户听到的症状正是「**最后几个字或最后一小段读不出来**」
        //    （差多少取决于积压量 ⇒ 时多时少）。
        //
        //    ✅ 现在只在正文**全部上屏**（`didFinalizeRow`）之后转发。
        //    ⛔ 别再挪回来"为了早点出声"：那不是节省，那是把结尾念丢。
    }

    /// 最后一条助手回复的**可朗读文本**（已脱 Markdown），没有就返回 nil。
    ///
    /// - 出错收尾时最后一行是 `.error`，`speechText` 会把错误提示也念出来 —— 那不是「回复」，
    ///   所以显式排除（用户听到「出错了：…」只会更困惑）；
    /// - 在最后一条里找 `.assistant` 而不是直接取 `rows.last`：万一末尾还挂着用户的新消息
    ///   （理论上不会，`finishStreamingUI` 是这一轮的收尾），也不至于把用户自己的话念回去。
    private func latestAssistantSpeech() -> String? {
        guard let index = manager.rows.lastIndex(where: { $0.role == .assistant }) else { return nil }
        if case .error = manager.rows[index].block.kind { return nil }
        // 模型切换系统消息同理：那不是「回复」（末尾挂着它时不该被念出来）
        if case .modelSwitch = manager.rows[index].block.kind { return nil }
        let text = speechText(atRow: index)
        return text.isEmpty ? nil : text
    }

    /// 把「这一轮回复的可朗读正文」转告通话页。**两个收尾回调共用**：
    /// `chatManagerDidFinalizeRow`（主入口，正文已全部上屏）与 `chatManager(_:didError:)`（兜底，防卡死）。
    ///
    /// 🔴 **只有在这两处调**。⛔ 尤其别挂在 `chatManagerDidUpdateStreamingText` 上
    ///    （那是 0.03s 一帧，会把整段回复反复从头念一遍）。
    /// - Note: 不在通话页时 `voiceCallVC` 是 nil，这个调用是零代价。
    private func forwardReplyToVoiceCall() {
        voiceCallVC?.sessionDidFinishReply(replyText: latestAssistantSpeech())
    }
}
