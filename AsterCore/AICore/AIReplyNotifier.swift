//
//  AIReplyNotifier.swift
//  AICore
//
//  「AI 回复生成完了」本地通知（2026-10-18 新增，第 6 家消费方之外的第一个通知场景）。
//
//  ## 为什么需要它
//  一轮长回复（长回答 / 慢模型 / 弱网）可能要几十秒。用户等不及会切去别的 App，
//  而回来时只能看到「还亮着个转圈」或者「早就答完了但没提示」——
//  发一条本地通知，用户不用盯着屏幕也知道「好了 / 挂了」。
//
//  ## 四条入口（按触发时机）
//  ① `replyFinished` —— 流正常结束（`chatManagerDidFinish`）；
//  ② `replyFailed` —— 出错收尾（`didError`）；
//  ③ `replyInterrupted` —— iOS 后台宽限期用尽（`handleBackgroundTimeExpired`，
//     那一刻用户已切走、进程还活着，是「断了」唯一还能告知的时机）；
//  ④ `notifyMissedRound` —— **回前台对账补发**（`AIMissedRoundReconciler`）：
//     iOS 挂起后① ②的事件根本不会来，靠持久化的 pending 记录在回前台时补。
//  ① ② ③ 都守「前台静默」；④ 刻意 `force`（见该函数的注释）。
//
//  ## 三条设计约束（⛔ 别绕）
//  1. 🔴 **只在 App 不在前台时发**：用户正盯着对话页时弹系统通知纯属骚扰。
//     前台判断是平台硬差异 ⇒ 走 `AIPlatformApp.isActive` 接缝（iOS `applicationState`、
//     macOS `NSApp.isActive`）。
//     ⚠️ 唯一例外是对账补发（`notifyMissedRound`，force 参数）——理由见那个函数。
//  2. 🔴 **权限要在前台时预热**：授权弹窗只在 App active 时弹得出来。等到「生成完」
//     那一刻再请求（用户多半已切走）⇒ 系统不展示授权框 ⇒ 这次通知**静默丢失**。
//     `warmup()` 有两个调用点，都在「用户必然在前台」的时刻：
//     ① **启动后首次 active**（2026-10-19 加，用户要求「首次启动就请求权限」）——
//        iOS `SceneDelegate.sceneDidBecomeActive` / Mac `AsterMacApp` 的
//        `WindowGroup` content `.onAppear`；
//     ② **每轮发送**（`AIChatManager.startStreaming`，三个发送入口的共用路径）——
//        兜底：冷启动那次若没弹成（启动即被切走等），首次发消息时补。
//  3. 🔴 **一个会话一条**：identifier 带 conversationId ⇒ 同一会话连出两条回复时
//     新通知**覆盖**旧的，不在通知中心里堆成一列。
//  4. 🔴 **用户偏好两件套**（2026-10-18 通知设置页）：总闸 / 内容预览
//     全在 `post()` 这一个出口兑现（`AINotificationPreferences`）——
//     两端设置页改的都存在同一份 UserDefaults 里，这里现读。
//     ⚠️ 提示音档位 2026-10-19 删除（用户要求）：通知一律跟随系统默认音
//     （`notifyNow` 的 `sound` 参数有默认值 `.default`，不传即是）。
//
//  ## 为什么接线在两端 UI 层而不是 AIChatManager 里
//  通知是「用户可感知的反馈」，与 toast / 通话页转发同类 —— 都挂两端的
//  `AIChatManagerDelegate` 实现上（iOS `+ChatManager.swift` / Mac `ChatModel.swift`）。
//  manager 里 `didError` 有 7 个抛出点（含发送前的同步失败），在业务层逐个接会漏；
//  而 delegate 出口两端各只有一个，天然是收口。
//

import Foundation
import UserNotifications
// 🔴 `AIPlatformApp`（App 是否在前台，平台接缝）在 AIPlatform 模块 ——
//    本工程 `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`：用谁的 API 就得显式 import 谁。
import AIPlatform
import StarryKitCore

public enum AIReplyNotifier {

    // MARK: - 常量

    /// 通知 identifier 前缀。全 id = `ai_reply_<conversationId>`。
    private static let identifierPrefix = "ai_reply_"

    /// 通知正文里用户发送文本的最大长度（字符数，超出截断加「…」）。
    /// 40 ≈ 通知 banner 两行能舒服放下的全宽字符数，见 `displayPrompt`。
    private static let maxPromptDisplayLength = 40

    /// userInfo 里会话 id 的键（点击通知时取回「该跳哪个会话」）。
    private static let conversationIdKey = "conversationId"

    // MARK: - 发通知（两个入口）

    /// 这一轮回复**正常生成完毕**。
    /// - Parameters:
    ///   - conversationId: 会话 id（决定通知身份：同会话覆盖、点击可跳转）
    ///   - prompt: **本轮**用户发送的文本（`manager.latestUserPrompt`）
    public static func replyFinished(conversationId: UUID, prompt: String) {
        post(conversationId: conversationId,
             title: L("回复已生成"),
             // 「显示内容预览」关 ⇒ 不透露用户问了什么（锁屏旁人也能看到通知）。
             body: AINotificationPreferences.showsPreview
                 ? displayPrompt(prompt)
                 : L("轻点查看详情"))
    }

    /// 这一轮回复**失败**（含流中断、配置类错误、后台被系统掐断）。
    /// - Parameter reason: 失败原因单行文案（`didError` 回传的 `localizedDescription`）
    public static func replyFailed(conversationId: UUID, prompt: String, reason: String) {
        post(conversationId: conversationId,
             title: L("生成失败"),
             // 同上：预览关时连错误原因都不进通知（原因里可能带 Key / 地址等敏感串）。
             body: AINotificationPreferences.showsPreview
                 ? "\(displayPrompt(prompt))\(reason)"
                 : L("轻点查看详情"))
    }

    /// 这一轮回复**被系统中断**（iOS 后台宽限期用尽，见
    /// `AIChatManager.handleBackgroundTimeExpired`）。
    ///
    /// 与 `replyFailed` 的分工：那条是「请求本身出错了」，这条是「请求还好好的，
    /// 但系统不让它继续跑」。文案因此也不同——回到 App 点「重试」就能接着来。
    /// ⚠️ 只在后台触发（宽限期到点 ⇒ 用户必然已切走），`post` 的前台守卫天然放行。
    public static func replyInterrupted(conversationId: UUID, prompt: String) {
        post(conversationId: conversationId,
             title: L("生成被中断"),
             body: AINotificationPreferences.showsPreview
                 ? displayPrompt(prompt)
                 : L("轻点查看详情"))
    }

    /// **回前台对账**时补发通知（2026-10-19，「通知策略补丁」B 方案）。
    ///
    /// 为什么需要它：iOS 把 App 挂起后「流结束 / 报错」事件根本不会来 ⇒
    /// 正常链路（`replyFinished` / `replyFailed`）在这条世界线上**永远不会触发**，
    /// 用户切走几分钟回来，屏幕上躺着半截回复却没有任何提示。对账在
    /// `sceneDidBecomeActive` 发现「上一轮的结束事件丢了」时补发这一条。
    ///
    /// 🔴 `force: true` —— 补发时 App **已经回前台**，`post` 的前台守卫会把它挡掉。
    ///     而这条通知的全部意义就是「锁屏 / 通知中心里要留痕」：用户可能没解锁、
    ///     只是拿起手机看了一眼锁屏。代价是「用户正在对话页时也会看到一条」——
    ///     那是补救通知的应有形态（banner 一闪而过，且内容说的正是眼前这件事）。
    public static func notifyMissedRound(conversationId: UUID, prompt: String, finished: Bool) {
        if finished {
            post(conversationId: conversationId,
                 title: L("回复已生成"),
                 body: AINotificationPreferences.showsPreview
                     ? displayPrompt(prompt)
                     : L("轻点查看详情"),
                 force: true)
        } else {
            post(conversationId: conversationId,
                 title: L("生成未完成"),
                 body: AINotificationPreferences.showsPreview
                     ? displayPrompt(prompt)
                     : L("轻点查看详情"),
                 force: true)
        }
    }

    /// 通知 identifier（`ai_reply_<conversationId>`）。
    /// public 是为了验收探针 / 调试能对上号（产品代码走 `clear(conversationId:)`）。
    public static func identifier(for conversationId: UUID) -> String {
        identifierPrefix + conversationId.uuidString
    }

    /// 清掉某个会话的通知（进到那个会话时调，避免「人都在里面了通知还挂着」）。
    public static func clear(conversationId: UUID) {
        StarryNotificationManager.shared.remove(identifier: identifier(for: conversationId))
    }

    /// 全清（已送达 + 待触发）。回前台时调：用户能看到内容了，通知再无意义。
    /// ⚠️ 本 App 目前只有这一类通知，全清是安全的；将来若加别的类别需改成分类清理。
    public static func clearAll() {
        StarryNotificationManager.shared.clearDelivered()
        StarryNotificationManager.shared.clearPending()
    }

    /// 从通知的 userInfo 里取回会话 id（两端 delegate 的点击处理共用）。
    public static func conversationId(from userInfo: [AnyHashable: Any]?) -> UUID? {
        guard let raw = userInfo?[conversationIdKey] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    // MARK: - 权限预热

    private static var didWarmup = false

    /// 预热通知权限。**必须在 App 在前台时调用**（授权框只在 active 时弹得出来）。
    /// 进程内只请求一次：`UNUserNotificationCenter` 对已授权/已拒绝的重复请求
    /// 不会弹窗、直接回调状态，但也没必要每轮生成都白问一次。
    ///
    /// ## 两个调用点（都是「用户在前台」的时刻，见文件头约束 2）
    /// ① 启动后首次 active（iOS `sceneDidBecomeActive` / Mac `WindowGroup.onAppear`）
    ///    —— 2026-10-19 用户要求「首次启动就请求」；
    /// ② `AIChatManager.startStreaming` —— 兜底补①没弹成的场景。
    /// ⚠️ 两处都调是**刻意**的：`didWarmup` 闩保证只真请求一次，重复调用零副作用。
    ///
    /// ⚠️ 总闸关着时**不预热**（也不置闩）：用户哪天在设置里打开，下次发送仍会预热
    ///    —— 闩只在「真的请求过」时置位（见下面 guard 的两个条件顺序）。
    public static func warmup() {
        guard !didWarmup, AINotificationPreferences.isEnabled else { return }
        didWarmup = true
        StarryPermission.request(.notification) { _ in }
    }

    // MARK: - 内部

    /// 统一的发送口：前台静默 + 权限已在 `notifyNow` 内部走 `StarryPermission` 要过。
    /// - Parameter force: 绕过「前台不发」守卫。只有**回前台对账补发**用得到
    ///   （见 `notifyMissedRound`）——⛔ 别处不许传 true。
    private static func post(conversationId: UUID, title: String, body: String, force: Bool = false) {
        // 🔴 用户偏好的第一道闸：设置页「桌面通知」关 ⇒ 一条都不发（⛔ 别只靠 UI 层判断）。
        guard AINotificationPreferences.isEnabled else { return }
        guard force || isInBackground else { return }
        StarryNotificationManager.shared.notifyNow(
            identifier: identifier(for: conversationId),
            title: title,
            body: body,
            userInfo: [conversationIdKey: conversationId.uuidString])
        // 提示音：不传 sound ⇒ `notifyNow` 默认 `.default`（系统默认音）。
        // 2026-10-19 删了提示音档位（用户要求），⛔ 别在这补 `UNNotificationSound(named:)`
        // —— 自合成音效文件已删，硬编码只会静默回落默认音。
    }

    /// 「用户此刻是否不在看 App」。⚠️ `active` 的精确语义见 `AIPlatformApp`。
    private static var isInBackground: Bool {
        !AIPlatformApp.isActive
    }

    /// 通知正文的展示形态：把用户这一轮的发送文本压成「通知 banner 一行放得下」的样子。
    ///
    /// 三步处理，每步都有实证成因：
    /// ① **换行压成空格** —— 用户常敲多行输入，通知正文里的 `\n` 会被系统渲染成
    ///    一个怪异的断行甚至直接把正文截掉一半；
    /// ② **超长截断**（40 个字符）—— 通知 banner 正文只有约两行，用户长文提问
    ///    （几百字的 prompt 很常见）不截断会被系统按中部省略号切得更难看，
    ///    自己截还能保证「开头几字 + …」是可读的；
    /// ③ **空文本回落**「新消息」—— 纯附件消息的占位文案（`[图片]`）理论上已覆盖，
    ///    这里是双保险（万一调用方传来空串，通知不能没有正文）。
    private static func displayPrompt(_ prompt: String) -> String {
        let flattened = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return L("新消息") }
        if flattened.count > Self.maxPromptDisplayLength {
            return String(flattened.prefix(Self.maxPromptDisplayLength)) + "…"
        }
        return flattened
    }
}
