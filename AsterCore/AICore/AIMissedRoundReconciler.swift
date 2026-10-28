//
//  AIMissedRoundReconciler.swift
//  AICore
//
//  「进行中的一轮」的持久记账 + **回前台对账**（2026-10-19，通知策略补丁 B 方案）。
//
//  ## 为什么需要它（iOS 的后台物理上限）
//  「回复生成完 ⇒ 发通知」的前提是**结束事件会来**。但 iOS 把 App 挂起后
//  （退后台约 5 秒起，无 `UIBackgroundModes`、无 background 会话）：
//   - SSE 连接停滞（`SSEClient` 走 Alamofire `.default` 会话，不是 background 会话）；
//   - 打字机 `Timer` 停；
//   - 最要紧的：**整个进程没有 CPU** ⇒ `chatManagerDidFinish` / `didError`
//     一个都不会触发 ⇒ `AIReplyNotifier.replyFinished/replyFailed` 永远不会被调。
//  用户切走几分钟回来，屏幕上躺着半截回复 / 失败提示，却没有任何通知——
//  而这个功能的全部意义就是「不用盯着屏幕也知道好了 / 挂了」。
//
//  ## 做法：发送时记账，回前台对账
//  ① `AIChatManager.isReceiving` 置位时记一条 pending（会话 + prompt + 开始时间，
//      UserDefaults 单条 JSON——量极小，不值得为此建表）；
//  ② 四个收尾点（done / error / stop / 后台中断）都经 `isReceiving` 复位 ⇒ 统一清账；
//  ③ 回前台（iOS `sceneDidBecomeActive` / Mac `WindowGroup.onAppear`）对账：
//     - 本进程还在收流（`isStreamingActive`）⇒ 结束事件会正常来，不插手；
//     - 否则查库（`AIChatStore`）：该会话最后一条助手行是不是**本轮新产的完整回复**
//       ⇒ 是：补发「回复已生成」（流在挂起前/被杀前刚好跑完，事件丢了）；
//       ⇒ 否：补发「生成未完成」（半截 / 失败 / 进程死掉续不上）。
//     补发后清账（`AIReplyNotifier.notifyMissedRound`，force 绕过前台守卫）。
//
//  ## 三个边界（都有实测成因，⛔ 别绕）
//  1. ☠️ **`AIChatStore` 未就绪时跳过且不清账**：`loadConversation` 在 store 没 ready 时
//     返回 nil，而「会话被删」也是 nil——两者必须分开。前者下次回前台还会对，
//     后者直接清账（会话都没了，通知没有落点）。
//  2. ☠️ **时间戳判据**（`createdAt >= startedAt - 容差`）：没有它，「继续生成」被杀
//     会被误判成完成——库里那行是上一轮落的部分文本，看着非空。
//     容差 10s：发送与占位行落库相隔通常 < 1s，10s 覆盖慢磁盘，又不至于把
//     「几分钟前的历史行」算进来。
//  3. ☠️ **总闸关时直接清账**：用户在设置里关了桌面通知，pending 就没有对账价值，
//     挂在 UserDefaults 里只会让下次开启时补发一条过期通知。
//
//  ## 为什么对账逻辑在共享层而不是两端各写一份
//  判据（查库 + 时间戳 + kind）两端完全一致；两端只差「什么时候调」
//  （iOS 回前台 / Mac 窗口出现）与「本进程是否在收流」从哪拿。
//  ⚠️ macOS 其实不会被挂起 ⇒ 正常路径 pending 总会被清；对账在 Mac 上只兜
//  「进程 crash」这一种，仍然值得（成本为零，调用就一行）。

import Foundation

public enum AIMissedRoundReconciler {

    // MARK: - 常量

    /// UserDefaults 键。带命名空间前缀（与 `AINotificationPreferences` 同款理由）。
    private static let pendingKey = "Aster.notifyReply.pendingRound"

    /// 行时间判据的容差（秒）。见文件头边界 2。
    private static let timestampTolerance: TimeInterval = 10

    /// pending 记录。单条、极小 ⇒ UserDefaults + JSON，不建表。
    private struct PendingRound: Codable {
        let conversationId: UUID
        let prompt: String
        /// 发送时刻（`Date().timeIntervalSince1970`）。
        let startedAt: TimeInterval
    }

    // MARK: - 记账（AIChatManager 的 isReceiving didSet 调）

    /// 一轮开始：记账。重复调用覆盖旧账（「重新生成」= 同一会话再开一轮）。
    static func recordStart(conversationId: UUID, prompt: String) {
        let record = PendingRound(conversationId: conversationId,
                                  prompt: prompt,
                                  startedAt: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: pendingKey)
    }

    /// 一轮结束（四个收尾点共用）：清账。
    static func recordEnd() {
        UserDefaults.standard.removeObject(forKey: pendingKey)
    }

    // MARK: - 探针辅助（DEBUG 验证用，产品路径不调）

    /// 按**指定**开始时刻记账（探针要构造「5 分钟前 / 1 小时前」的假时刻；
    /// 产品路径永远走 `recordStart`，那里取当前时间）。
    public static func probeRecordStart(conversationId: UUID, prompt: String, startedAt: TimeInterval) {
        let record = PendingRound(conversationId: conversationId,
                                  prompt: prompt,
                                  startedAt: startedAt)
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: pendingKey)
    }

    /// 当前是否有 pending（探针验「守卫挡住 ⇒ 不清账」用）。
    public static func probeHasPending() -> Bool {
        load() != nil
    }

    /// 探针收尾专用：清掉探针写的 pending（产品路径的清理走 `recordEnd`）。
    public static func probeEnd() {
        recordEnd()
    }

    // MARK: - 对账

    /// 回前台对账。**幂等**：没有 pending / 还在收流 / 总闸关着，三种情况都是空跑。
    /// - Parameter isStreamingActive: 本进程此刻是否还在收流（调用方传
    ///   `AIChatManager.isReceiving`）。true ⇒ 结束事件会正常来，不插手。
    /// - Note: 同步执行（`loadConversation` 是同步查库）。调用点在主线程
    ///   （`sceneDidBecomeActive` / `onAppear`），与 VC 切会话时查库同款代价。
    public static func reconcileIfNeeded(isStreamingActive: Bool) {
        guard let pending = load() else { return }
        // 总闸关 ⇒ 账没价值，直接清（见文件头边界 3）
        guard AINotificationPreferences.isEnabled else {
            recordEnd()
            return
        }
        // 本进程还在跑 ⇒ 结束事件会来，别抢在它前面发（发了也会被随后的正常通知覆盖，
        // 但那是同 id 覆盖，用户看到哪条全凭时序——不值得赌）
        guard !isStreamingActive else { return }
        // store 没就绪 ⇒ 这次对不了，留账下次再来（见文件头边界 1）
        guard AIChatStore.shared.isReady else { return }
        // 会话被删 / 载入失败 ⇒ 通知没有落点，清账了事
        guard let conversation = AIChatStore.shared.loadConversation(id: pending.conversationId) else {
            recordEnd()
            return
        }

        let finished = lastAssistantRowFinished(conversation, since: pending.startedAt)
        AIReplyNotifier.notifyMissedRound(conversationId: pending.conversationId,
                                          prompt: pending.prompt,
                                          finished: finished)
        recordEnd()
    }

    // MARK: - 判据

    /// 「本轮是否产出了一条完整回复」。
    ///
    /// 三个条件同时成立才算完成：
    /// ① 最后一条助手行是**本轮之后**落的（时间戳判据，见边界 2）；
    /// ② 不是 `.error` 行（失败提示 / 后台中断写的都是它）；
    /// ③ 有实际内容——`.text` 要求非空（流式中被杀的占位行是空 text），
    ///    图片 / 视频 / 文件行天然算有产出（纯图回复没有正文）。
    private static func lastAssistantRowFinished(_ conversation: AIConversation,
                                                 since startedAt: TimeInterval) -> Bool {
        guard let row = conversation.rows.last(where: { $0.role == .assistant }) else { return false }
        guard row.createdAt.timeIntervalSince1970 >= startedAt - timestampTolerance else { return false }
        switch row.block.kind {
        case .error: return false
        case .modelSwitch: return false     // 系统的流水不是「这一轮的产出」
        case .text:  return !row.block.text.isEmpty
        case .image, .video, .file: return true
        }
    }

    // MARK: - 存取

    private static func load() -> PendingRound? {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return nil }
        return try? JSONDecoder().decode(PendingRound.self, from: data)
    }
}
