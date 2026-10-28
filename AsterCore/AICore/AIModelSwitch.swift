//
//  AIModelSwitch.swift
//  AICore
//
//  「切换模型」时在会话里插一条**居中系统消息**（2026-10-21）。
//
//  ## 它长什么样
//  「—— 模型已从 A 更改为 B ——」，居中、小灰字、两侧的分隔线由文案自带。
//  🔴 **没有任何点击事件与交互**（用户原话：「不用有任何点击事件和交互，就是系统消息」）：
//    不画气泡、不挂操作栏、不进长按操作卡、不进右键菜单、不参与上下文组装、
//    不被分享文本带出去 —— 它就是「系统在这时说过一句话」的记录。
//
//  ## 为什么是独立 kind（`AIBlockKind.modelSwitch`）
//  复用 `.text`：它会被 `contextMessages()` 当「助手说过的话」回传给模型，
//  也会被分享文本当成对话内容带出去；复用 `.error`：它会被当成一次失败
//  （自带重试菜单、橙色、算「这一轮的输出」）。照 `.error` 那条先例走独立 kind ——
//  `contextMessages()` / `transcript()` 的 switch 里补一个 case 就天然排除，
//  落库后重启也认得出来，无需靠文案前缀猜。
//
//  ## 两条显示规则（用户 2026-10-21 原话）
//  ① A 切 B 之后**又切回 A** ⇒ **撤销**这条消息（整条删掉）；
//  ② A 切 B 之后**又切 C** ⇒ **只显示「A 切换 C」**（改写，不是新增）。
//
//  ⇒ 所以 `fromID` / `fromName` 必须**落库**：
//     · 规则 ① 要判「切回来的是不是原来那一个」—— 名字会变（用户改模型名）、id 不会；
//     · 规则 ② 要留住最早的 `from`、只改 `to`。
//     `toID` / `toName` 是 `var`：规则 ② 就地改它们（连同 `ai_message.text`
//     在**同一个事务**里回写，见 `AIChatStore.rewriteModelSwitch`）。
//
//  ⚠️ 两条规则只在「**末行就是这条系统消息**」时成立（其后一条消息都没有）——
//     中间聊过天就该新插一条，老记录保留（历史更诚实）。实现见
//     `AIChatManager.noteModelSwitch(from:to:)`。
//
//  ## 存在哪
//  结构化数据走**新表** `ai_model_switch`（主键 = 消息 id，1:1）——
//  同 `ai_quote` / `ai_reasoning` 的纪律：⛔ 不给 `ai_message` 加列。
//  渲染好的文案**同时**写进 `ai_message.text`（kind 5）⇒ 表丢了也能退化成
//  一条纯文本行（`AIBlock.modelSwitchText` 会现算一份）。
//

import Foundation

/// 一条「模型被切换」的记录（挂在 `.modelSwitch` 行上，1:1）。
///
/// 与 `AIQuote` 同一种思路：**名字是那一刻的快照**。用户之后改了模型名，
/// 历史记录里那句「从 A 切换到 B」不该跟着变成新名字 —— 那是改写历史。
public struct AIModelSwitch: Equatable {

    /// 切换**前**那条模型的 id（`AIModelStore.currentID` 的旧值）。
    ///
    /// `let`：两条规则都不改它（规则 ② 改的是 `toID`）。
    public let fromID: String

    /// 切换**后**那条模型的 id。规则 ② 会就地改它。
    public var toID: String

    /// 切换那一刻 `from` 的显示名快照。
    public let fromName: String

    /// 切换那一刻 `to` 的显示名快照。规则 ② 会就地改它。
    public var toName: String

    public init(fromID: String, toID: String, fromName: String, toName: String) {
        self.fromID = fromID
        self.toID = toID
        self.fromName = fromName
        self.toName = toName
    }

    /// 这一条要显示的文案。
    ///
    /// 🔴 **计算属性、⛔ 不是 `static let`**：`L()` 的结果不能被进程级缓存住，
    ///    否则切语言后这一行永远是旧语言（同 `AIReasoning.collapsedTitle` 那条教训）。
    ///    也正因如此，**渲染与量行高都必须现取它**（见 `AIBlock.modelSwitchText`）——
    ///    落库那份 `text` 只在「表丢了」时当兜底。
    public var noticeText: String {
        String(format: L("—— 模型已从 %@ 更改为 %@ ——"), fromName, toName)
    }

    /// 两条规则的「是不是同一条链上」判据：这条记录的**目的地**正是本次要离开的那个模型。
    ///
    /// 放在这里而不是让调用方各写一遍：规则 ① ② 的**全部**前提都是这一句，
    /// 而它的另一半（`fromID == to.id` ⇒ 撤销）也在下面成对给出。
    public func continuesFrom(_ modelID: String) -> Bool { toID == modelID }

    /// 切回去的那个就是最初的来源 ⇒ 该撤销（规则 ①）。
    public func returnsTo(_ modelID: String) -> Bool { fromID == modelID }
}
