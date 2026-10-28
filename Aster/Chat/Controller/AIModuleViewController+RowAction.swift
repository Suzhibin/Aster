import UIKit
import AVKit
import JXPhotoBrowser
import Kingfisher
import AICore
// ⚠️ `StarryPermission`（保存到相册要申请 `.photoLibraryAdd`）在 StarryKitCore 里，
// 本工程开了 MemberImportVisibility ⇒ 用谁的 API 就得显式 import 谁。
import StarryKitCore

/// 「一行」上能做的事：操作栏 / 长按操作卡的动作（含「选取文字」）、语音朗读、图片与视频预览。
///
/// 这三件事放在一起是有原因的 —— 它们**共用同一套「行的文本」取值逻辑**：
/// - `actionText(atRow:)`：复制 / 分享用，图片视频行取同一轮里的文字，退化时才给 URL；
/// - `speechText(atRow:)`：朗读用，必须洗成**纯文本**（Markdown 的 `**`、`#` 会被真的念出来），
///   退化场景直接返回空（不念裸链接）。
///
/// 两个入口（气泡下方操作栏 / 长按操作卡）都走 `performRowAction`，**行为不会各写一套**：
/// 想加一项操作 → `AIRowAction` 加 case + 这里加分支，两个入口自动都出现。
///
/// ## 朗读与录音互斥
/// 与 `+Voice.swift` 共用一份 `AVAudioSession`：开始朗读前先结束录音会话，
/// 否则 `.playAndRecord` 会把朗读要的 `.playback` 顶掉（表现为「点了朗读没声音」）。
extension AIModuleViewController {

    // MARK: - 行操作

    /// 执行某一行的操作。
    ///
    /// ⚠️ 这是**唯一**的执行点：气泡下方操作栏、轻点操作卡、长按操作卡三个入口都汇到这里
    /// （加入口时只需在 `AIRowAction` 里选好它属于哪几个集合）。新增动作时在这里加一个 case。
    /// - Parameter tapPoint: 长按气泡的位置（**`view` 坐标系**），只有「选取文字」用得上
    ///   （用它定位到用户按住的那一行，见 `beginTextSelection`）。操作栏那条入口不传。
    func performRowAction(_ action: AIRowAction, rowIndex: Int, tapPoint: CGPoint? = nil) {
        guard manager.rows.indices.contains(rowIndex) else { return }
        StarryHaptic.impact(.light)
        switch action {
        case .copy:
            let text = actionText(atRow: rowIndex)
            guard !text.isEmpty else { return }
            UIPasteboard.general.string = text
            showToast(L("已复制"))
        case .speak:
            toggleSpeech(at: rowIndex)
        // ⚠️ 「喜欢 / 不喜欢」当前**没有任何菜单入口**（2026-09-18 按要求从助手长按卡移除），
        // 这两条分支是**刻意保留**的实现（将来若要接反馈落库仍从这里走），不是漏删。
        case .like:
            // TODO: 尚未落状态（只给反馈）。要做持久化建议按 message id 存 UserDefaults 集合
            showToast(L("已喜欢"))
        case .dislike:
            showToast(L("已不喜欢"))
        case .share:
            shareRow(at: rowIndex)
        case .save:
            saveImageRow(at: rowIndex)
        case .selectText:
            beginTextSelection(atRow: rowIndex, tapPoint: tapPoint)
        case .quote:
            beginQuote(atRow: rowIndex)
        case .edit:
            enterEditing(atRow: rowIndex)
        case .delete:
            // ⚠️ **不在这里删**：先让列表进「多选删除」模式（左侧勾选圆圈），把这一轮预勾上，
            // 由用户自己确认要删哪几条，最后按导航栏的「删除(N)」执行 —— 全部实现见 `+Selection.swift`
            enterSelectionMode(startingAt: rowIndex)
        case .regenerate, .retry:
            // 「重新生成」与「重试」在数据层是同一件事（撤掉这一轮的助手回复 + 按现有上下文重问），
            // 差别只在入口：「重试」在失败提示行的操作卡里，「重新生成」在气泡下方操作栏上
            // （长按操作卡已按产品要求移除它）—— 两个入口共用这一份实现，别再各写一份。
            regenerateResponse(fromRowAt: rowIndex)
        case .continueGeneration:
            // 与「重新生成」**相反**：这里不删行、不建行，保留半截正文接着往下写
            //（实现见 `AIChatManager.continueGeneration`）
            continueGenerationResponse(fromRowAt: rowIndex)
        }
    }

    /// 触发重新生成 / 重试，并处理「发不出去」的情形。
    ///
    /// manager 里 `regenerate` 的返回值只有两种含义，都必须在这里交代清楚，
    /// 否则用户点了菜单却毫无反应，只能以为功能坏了：
    /// - `true`：已经重新开始流式（旧回复已撤、占位行已插入，UI 由 manager 的回调驱动）；
    /// - `false`：被前置校验拦下了（配置类错误 / 前面没有可重问的用户内容）——
    ///   manager 已经回调 `didError` 弹过 toast，这里**不能再弹**（会叠成两条）。
    private func regenerateResponse(fromRowAt rowIndex: Int) {
        // 正在生成时不允许再来一轮：菜单虽然已经摘掉了这两项，但别的入口仍可能绕过
        guard !isStreaming else {
            showToast(L("正在回复中，先停下再试"))
            return
        }
        // 同 `send()`：先确认有网。这里格外要紧 —— `regenerate` 会**先撤掉旧回复**，
        // 撤完才发现发不出去，等于白丢一条用户已经看到的回答。
        // ⚠️ 位置在所有副作用（收浮层、震动、`isStreaming = true`）之前
        guard ensureNetworkAvailable() else { return }
        // 重新生成会把这一轮的回复整段换掉 → 收起选中态与操作卡，别让它们指向已经消失的行
        endTextSelection()
        dismissActionMenu()
        StarryHaptic.impact(.medium)
        // 与 `send()` 同一套顺序：**先置位再发起**。配置类错误会在 `regenerate` 内同步回调
        // `didError`（那里复位 isStreaming），顺序反了会把刚复位的状态又置回 true，卡在「正在回复」
        isStreaming = true
        let started = manager.regenerate(fromRowAt: rowIndex)
        // 失败兜底（didError 已经复位过一次，这里幂等）：不能因为一次前置校验失败
        // 就把输入栏永远停在「停止」上
        if !started { isStreaming = false }
        // 光标挪到底部：新一轮回复长在最后，用户期待看到它
        if started {
            isPinnedToBottom = true
            scrollToBottom(animated: false)
        }
    }

    /// 触发「继续生成」，并处理「发不出去 / 这条已经不能续写」的情形。
    ///
    /// 与 `regenerateResponse` 是同构的（先置位再发起 + 失败兜底），三件事都别省：
    /// - `ensureNetworkAvailable()` 尤其要紧 —— 用户点「继续生成」多半正是因为**上一次断在这**；
    /// - `isStreaming = true` 必须在 `manager` 调用**之前**：配置类错误是**同步**回调 `didError`
    ///   的，那里会复位它，顺序反了就会卡在「正在回复」；
    /// - 失败兜底（`if !started`）幂等：`didError` 已经复位过一次，这里只是保底。
    private func continueGenerationResponse(fromRowAt rowIndex: Int) {
        guard !isStreaming else {
            showToast(L("正在回复中，先停下再试"))
            return
        }
        guard ensureNetworkAvailable() else { return }
        endTextSelection()
        dismissActionMenu()
        StarryHaptic.impact(.medium)
        isStreaming = true
        let started = manager.continueGeneration(fromRowAt: rowIndex)
        if !started { isStreaming = false }
        if started {
            isPinnedToBottom = true
            scrollToBottom(animated: false)
        }
    }

    /// 分享某一行。
    ///
    /// 🔴 **附件行（图片 / 视频 / 文件）分享的是「附件本身」**，不再是同一条回复的文字
    /// （2026-09-29 用户选定图片/视频、2026-10-06 扩到文件）：用户发的附件是本地文件 ⇒
    /// 把 `file://` 交给系统分享面板，系统会识别成图片 / 影片 / 文件；助手侧是远程地址 ⇒ 分享链接。
    ///
    /// ⚠️ **这是一处必须一起改的行为**，不是顺手优化：附件行的操作卡自 2026-09-29 起
    /// 只剩「分享 + 删除」（`AIRowAction.mediaMenu`），「分享」成了那套菜单里唯一的非破坏项 ——
    /// 而旧实现走 `actionText`，纯附件消息（**没有同轮文字**：用户只发了一张图、没说别的话）
    /// 会退化成 `file:///...` 字符串，分享出去是一串没用的地址，等于这个菜单只剩「删除」能用。
    /// ⛔ 2026-10-06 把文件行并进来时**正是这个坑**：`mediaShareURL` 原来只认 `.image/.video`，
    /// 文件行的「分享」会静默退化成路径字符串。加 `kind` 必须同步加分支。
    ///
    /// ⚠️ 只有**取不到附件地址**时才退回文字（同轮正文 / 附件标识）—— 菜单项点了完全没反应
    /// 比分享出次优内容更糟（同 `share` 分支原有的 `guard !text.isEmpty`）。
    private func shareRow(at index: Int) {
        guard manager.rows.indices.contains(index) else { return }
        if let url = mediaShareURL(of: manager.rows[index]) {
            present(UIActivityViewController(activityItems: [url], applicationActivities: nil),
                    animated: true)
            return
        }
        let text = actionText(atRow: index)
        guard !text.isEmpty else { return }
        present(UIActivityViewController(activityItems: [text], applicationActivities: nil),
                animated: true)
    }

    /// 把某一行的图片存进系统相册（2026-10-08 加，「保存到相册」的执行点）。
    ///
    /// 🔴 **只对用户侧图片开放**（菜单集合见 `AIRowAction.userImageMenu`）——
    /// 用户发的那张图是 `AIAttachmentStorage` 落盘的**本地文件**，存进相册是一次本地写入。
    /// ⛔ 别把助手侧也接上：那边 `imageURL` 是**远程地址**，`saveImageToAlbum` 只吃 `file://`，
    /// 得先下载（另一条链路：进度 / 失败 / 体积），不做就把「保存」做成永远失败的一项。
    ///
    /// ⚠️ 三种失败都要**各自出声**（`guard` 静默返回会被用户当成功能坏了）：
    /// ① 这一行不是图片 / 没有地址 —— 正常走不到（菜单不给），算防御；
    /// ② 附件已被删 —— 与③的提示必须不同，否则用户在「重装迁移」后一直看到「保存失败」却不知为何；
    /// ③ 用户拒绝或未授权 —— 引导去系统设置。
    private func saveImageRow(at index: Int) {
        guard manager.rows.indices.contains(index) else { return }
        let row = manager.rows[index]
        guard row.block.kind == .image, let url = row.block.imageURL else {
            showToast(L("这条没有可保存的图片"))
            return
        }
        guard url.isFileURL else {
            // 用户侧图片一定是落盘附件；走到这里说明数据异常（见上面「⛔ 别把助手侧也接上」）
            showToast(L("这张图还没下载，暂时不能保存"))
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast(L("图片已不存在"))
            return
        }
        PhotosLibraryService.shared.saveImageToAlbum(at: url) { [weak self] ok in
            guard let self = self else { return }
            if ok {
                self.showToast(L("已保存到相册"))
            } else {
                // 授权被拒与写入失败在这里不可区分（Photos 不给细分错误）⇒ 引导去设置，
                // 那是两种情况下都可能有用的下一步
                self.showToast(L("保存失败，请检查相册权限"))
                StarryPermission.openSettings()
            }
        }
    }

    /// 这一行要分享的**附件文件 / 地址**；非附件行、或地址缺失时返回 `nil`。
    ///
    /// 图片取 `imageURL`、视频取 `videoURL`、**文件取 `fileURL`** —— 与各自 cell 渲染用的是
    /// **同一个字段**，不会出现「点开能看、分享却说没有」。
    /// ⚠️ 视频**不取 `videoCoverURL`**：分享一张封面图不是用户点「分享」的意思
    /// （封面缺失时宁可退回文字兜底）。
    /// 🔴 三者的操作卡是**同一套**（`AIRowAction.mediaMenu`）⇒ **加一种 `kind` 就要加一条分支**，
    /// 漏了不报错，只会让那一类的「分享」退化成 `file:///...`（`actionText` 兜底会兜住那个地址）。
    private func mediaShareURL(of row: AIChatRow) -> URL? {
        switch row.block.kind {
        case .image: return row.block.imageURL
        case .video: return row.block.videoURL
        case .file:  return row.block.fileURL
        default:     return nil
        }
    }

    /// 某行用于**复制**的文本（也是分享取不到附件时的**兜底**，见 `shareRow(at:)`）。
    ///
    /// 文本行取正文；图片 / 视频 / 文件行取**同一条回复里的文字**（往前找到该轮的开头块为止），
    /// 都没有才退化成 URL 字符串。
    /// ⚠️ 附件行的操作卡自 2026-09-29（图片/视频）、2026-10-06（文件）起只剩「分享 + 删除」
    /// （`AIRowAction.mediaMenu`），所以下面那条「附件分支」**不再服务于「复制」**，
    /// 只作为分享的兜底存在 —— 别因为「附件行已经没有复制入口了」就把这个分支当死代码删掉。
    private func actionText(atRow index: Int) -> String {
        guard manager.rows.indices.contains(index) else { return "" }
        let row = manager.rows[index]
        switch row.block.kind {
        case .text, .error:
            return row.block.text
        case .modelSwitch:
            // 系统流水不进复制 / 分享（它没有菜单入口，这里是类型穷尽的兜底）
            return ""
        case .image, .video, .file:
            if let text = turnText(endingAt: index) { return text }
            // 同一轮里没有文字（纯附件消息）：退回附件自身的标识，至少复制/分享不是空的
            return row.block.imageURL?.absoluteString
                ?? row.block.videoURL?.absoluteString
                ?? row.block.fileURL?.absoluteString
                ?? ""
        }
    }

    /// 从 index 往前找同一轮（`isFirstBlockOfTurn` 是轮起点）里的第一段非空正文
    private func turnText(endingAt index: Int) -> String? {
        var i = index
        while i >= 0 && i < manager.rows.count {
            let row = manager.rows[i]
            if case .text = row.block.kind, !row.block.text.isEmpty { return row.block.text }
            if row.isFirstBlockOfTurn { break }
            i -= 1
        }
        return nil
    }

    // MARK: - 选中文字

    /// 让某一行的气泡进入「选中文字」态（原生放大镜 / 拖柄 / 编辑菜单）。
    ///
    /// ⚠️ 这是**现在唯一的入口**：长按气泡本身不再直接选字 —— 那个分流与「长按弹操作卡」
    /// 抢同一条手势（用户实测冲突），所以选字收进操作卡的**竖排第一项**。
    ///
    /// 失败要出声（toast）：菜单点下去毫无反应会被当成功能坏了。失败有两种，都真实存在 ——
    /// cell 不在屏上（理论上不会，卡片就是从这一行弹出来的）、以及**空正文**
    /// （流式起始的空占位行、纯附件行的气泡里没有文字可全选）。
    /// - Parameter tapPoint: 用户长按气泡的位置（**`view` 坐标系**）——
    ///   有它就选中「按住的那一行」，没有（如从气泡下方操作栏进来）就退回全选整段。
    func beginTextSelection(atRow index: Int, tapPoint: CGPoint? = nil) {
        guard manager.rows.indices.contains(index),
              let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)),
              let selectable = cell as? AIBubbleTextSelecting else {
            showToast(L("这条没有可选取的文字"))
            return
        }
        // `view` 坐标 → cell 坐标。⚠️ `convert(_:from:)` 的接收者是**目标**视图（cell），
        // 入参点当前在 `from`（= view）里。写反（`cell.convert(point, to: ...)`）会得到
        // 恒偏「cell 在表里的位移」的点，**编译 / 类型检查一条错都不报** —— 上次栽过一次。
        let pointInCell = tapPoint.map { cell.convert($0, from: view) }
        guard selectable.beginTextSelection(at: pointInCell) else {
            showToast(L("这条没有可选取的文字"))
            return
        }
    }

    /// 引用某一行的内容，然后接着提问。
    ///
    /// 引用条会出现在输入栏上方（可取消），发送时随消息一起落库并进入上下文
    /// （见 `AIChatManager.send` / `AIQuote.contextText`）。
    ///
    /// 图片 / 文件行取的是**同一轮里的文字**（与复制 / 分享同一套取值逻辑）——
    /// 用户看到的是「我说过的这段话」，而不是一个文件路径。
    func beginQuote(atRow index: Int) {
        guard manager.rows.indices.contains(index) else { return }
        let row = manager.rows[index]
        // 失败提示是系统给的说明，引用它没有意义（真想问「这个报错怎么办」，
        // 直接打字问就行，模型本来就看得到上下文）
        guard row.block.kind != .error else {
            showToast(L("这条是系统提示，不用引用"))
            return
        }
        let text = actionText(atRow: index)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast(L("这条没有可引用的文字"))
            return
        }
        setPendingQuote(AIQuote(messageId: row.block.id, role: row.role, text: text))
        // 引用是为了「接着说」，顺手把键盘弹起来 —— 否则用户还得再点一下输入框
        _ = inputToolbar.becomeFirstResponder()
    }

    // MARK: - 🧪 朗读节奏探针的入口

    /// `STARRY_TTS_TRACE=1` 时，首屏落地后**自动念一段固定夹具**并记录节奏（边界静默时长）。
    ///
    /// 为什么需要它：用户反馈的「朗读断断续续」是听感问题 —— 截图看不见、契约 grep 不出来。
    /// 而它等价于「每条 utterance 边界上静默多久」，那个量**能测**：探针把结果写进
    /// `Documents/tts_trace.log`（本体与原理见 `AISpeechReader` 末尾的探针段）。
    ///
    /// ⚠️ 只在 `#if DEBUG` 下编译进去；`runTraceProbe()` 内部还要 `STARRY_TTS_TRACE=1` 才动。
    func runSpeechTraceIfRequested() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["STARRY_TTS_TRACE"] == "1" else { return }
        // 等一会儿：首屏（含导航栏 / 表格布局）先落地，别把首帧工作量算进「首字延迟」
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard self != nil else { return }
            AISpeechReader.shared.runTraceProbe()
        }
        #endif
    }

    // MARK: - 语音朗读

    /// 朗读 / 停止朗读某一行。
    ///
    /// - 同一行再点 = 停；
    /// - 换一行 = 切过去（`AISpeechReader.speak` 内部会先停旧的）；
    /// - 朗读与录音**共用一份 `AVAudioSession`**，所以开始前先结束录音会话。
    private func toggleSpeech(at rowIndex: Int) {
        if speakingRowIndex == rowIndex {
            stopSpeech()
            return
        }
        let text = speechText(atRow: rowIndex)
        guard !text.isEmpty else {
            showToast(L("这条没有可朗读的文字"))
            return
        }
        let previous = speakingRowIndex
        // 麦克风让位：语音输入的 `.playAndRecord` 会把朗读要的 `.playback` 顶掉
        endVoiceSession(cancel: true, toast: false)
        speakingRowIndex = rowIndex
        AISpeechReader.shared.speak(text)
        // 图标是两态：上一行还原、这一行切成「停止」
        refreshSpeakingRow(previous)
        refreshSpeakingRow(speakingRowIndex)
    }

    /// 停止朗读并复位 UI（未在朗读时安全）
    func stopSpeech() {
        guard speakingRowIndex != nil || AISpeechReader.shared.isSpeaking else { return }
        AISpeechReader.shared.stop()
        clearSpeakingRow()
    }

    /// 清掉「正在朗读」的行标记并刷新那一行的图标（朗读**自然读完**时也走这里）
    func clearSpeakingRow() {
        guard let index = speakingRowIndex else { return }
        speakingRowIndex = nil
        refreshSpeakingRow(index)
    }

    /// 刷新某一行的操作栏图标。**只刷屏上可见的行**：图标切换不影响高度，
    /// 离屏的行下次 `cellForRowAt` 会按 `speakingRowIndex` 重新配置，不必整表刷。
    private func refreshSpeakingRow(_ index: Int?) {
        guard let index = index, manager.rows.indices.contains(index) else { return }
        let ip = IndexPath(row: index, section: 0)
        guard tableView.indexPathsForVisibleRows?.contains(ip) == true else { return }
        tableView.reloadRows(at: [ip], with: .none)
    }

    /// 某行用于朗读的文本。
    ///
    /// 与复制/分享的区别：**必须洗成纯文本**——Markdown 的 `**`、`#`、`|` 会被真的念出来；
    /// 图片/视频行只读同一轮里的文字，退化成裸 URL 的场景直接返回空（不念链接）。
    ///
    /// ⚠️ 故意**不写 `private`**：`+ChatManager.finishStreamingUI` 要把回复文本回传给通话页
    /// （让那边念出来），而 `private` 在本工程是**文件级**作用域，写成 private 会跨文件看不见。
    func speechText(atRow index: Int) -> String {
        guard manager.rows.indices.contains(index) else { return "" }
        let row = manager.rows[index]
        let raw: String
        switch row.block.kind {
        case .text, .error:
            raw = row.block.text
        case .modelSwitch:
            // 系统流水不朗读（它没有菜单入口，这里是类型穷尽的兜底）
            raw = ""
        case .image, .video, .file:
            raw = turnText(endingAt: index) ?? ""
        }
        return AIMarkdown.plainText(from: raw)
    }

    // MARK: - 预览（图片 / 视频）

    func playVideo(_ url: URL) {
        let player = AVPlayer(url: url)
        let vc = AVPlayerViewController()
        vc.player = player
        present(vc, animated: true) { player.play() }
    }

    /// 全屏图片浏览（JXPhotoBrowser：内置捏合/双击缩放、下拉关闭；zoom 转场从点击的缩略图位置展开）
    func presentImagePreview(_ url: URL, thumbnail: UIView?) {
        let browser = JXPhotoBrowserViewController()
        browser.delegate = self
        browser.initialIndex = 0
        browser.scrollDirection = .horizontal
        browser.transitionType = .zoom
        browser.isLoopingEnabled = false
        previewImageURLs = [url]
        previewThumbnailView = thumbnail
        browser.present(from: self)
    }
}

// MARK: - JXPhotoBrowserDelegate（图片全屏浏览：数据提供 + 网络图加载 + zoom 转场源视图）

extension AIModuleViewController: JXPhotoBrowserDelegate {

    public func numberOfItems(in browser: JXPhotoBrowserViewController) -> Int {
        previewImageURLs.count
    }

    public func photoBrowser(_ browser: JXPhotoBrowserViewController,
                             cellForItemAt index: Int,
                             at indexPath: IndexPath) -> JXPhotoBrowserAnyCell {
        browser.dequeueReusableCell(withReuseIdentifier: JXZoomImageCell.reuseIdentifier, for: indexPath)
    }

    public func photoBrowser(_ browser: JXPhotoBrowserViewController,
                             willDisplay cell: JXPhotoBrowserAnyCell,
                             at index: Int) {
        guard let photoCell = cell as? JXZoomImageCell,
              previewImageURLs.indices.contains(index) else { return }
        let url = previewImageURLs[index]
        if url.isFileURL {
            // 用户发的图是本地附件：**不要走 Kingfisher** —— 它是给网络请求用的，
            // 对 `file://` 不保证有处理（URLSession 本来就不支持 file scheme）。
            // 直接读盘，并且按屏幕像素降采样，别把整张图解进内存。
            photoCell.imageView.kf.indicatorType = .none
            photoCell.imageView.image = AIAttachmentStorage.image(
                at: url,
                maxPixelSize: max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * UIScreen.main.scale
            )
        } else {
            // 复用聊天列表已缓存的 Kingfisher 图片，避免二次下载
            photoCell.imageView.kf.indicatorType = .activity
            photoCell.imageView.kf.setImage(with: url)
        }
    }

    public func photoBrowser(_ browser: JXPhotoBrowserViewController,
                             thumbnailViewAt index: Int) -> UIView? {
        previewThumbnailView
    }
}
