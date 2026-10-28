//
//  ChatRowActionBar.swift
//  AsterMac
//
//  消息底部的横排操作栏，四种（本文件只管「长什么样」，挂不挂在宿主那边）：
//
//  | 类型 | 组成 | 显隐 | 宿主 |
//  |---|---|---|---|
//  | `ChatRowActionBar`（助手文本） | 复制 / 朗读 / 重试 / 分享 / **⋯** / 时间（+ 条件项「继续生成」） | 常驻 | `ChatRowView` |
//  | `ChatRowUserActionBar`（用户） | 时间 / 编辑 / 复制 / **⋯** | hover 才显 | `ChatRowView` |
//  | `ChatRowMediaActionBar`（助手媒体） | 分享 / **⋯**（只有删除） / 时间 | 常驻 | `ChatDetailView.mediaItem` |
//  | `ChatRowUserMediaActionBar`（用户图片） | 时间 / 分享 / **⋯**（只有删除） | hover 才显 | `ChatDetailView.userImagesItem` |
//
//  ## ⋯ 里的集合
//  - **两条文本栏** = 引用 + 删除（集合与排布完全一致，见 `RowOverflowMenu`）；
//  - 🔴 **两条媒体栏只有删除**：用户 2026-09-29 明确去掉图 / 视频的「引用」。
//    理由不是「引用坏了」，而是**媒体引用没有站得住的语义**：文本 / 图 / 视频是同一次回复的
//    **三条独立消息**，引用一张图就该引那张图本身，而当时的实现只能取「同轮里 AI 那段文字」= 指错。
//    ☠️ 硬事实：助手侧的图 / 视频**根本不进请求上下文**（`contextMessages` 里 `case .image:`
//    只放行 `row.role == .user`），且 AI 的图是服务端远程 URL、从没落地 ⇒ 引用条上写
//    「[1 张图片]」模型也看不见那张图，那是**做不到的承诺**。
//    ⛔ 别不声不响把 `showsQuote` 改回 true。要做回来只有两条路（详见 `MAC-UI-RULES.md`）：
//    ① 引用条上放缩略图；② 连「下载远程图 → base64 内联」一起做（工程量大，非视觉模型要拦）。
//    ℹ️ 用户自己发的图同样不给引用：进了上下文但产品口径上没意义，与助手侧保持一致。
//  - 为什么收进菜单而不是并排铺开：一项会带内容进下一轮、一项**不可恢复地删数据**，
//    都属于「想清楚了才点」的动作，摆最右边 + 再点一次 = 一道人工确认。
//
//  ## 用户侧那一栏的三条硬约束
//  ① **顺序 = 时间 · 编辑 · 复制**，时间在**最左**（助手侧时间在栏尾）——用户当面指定，别"顺手对齐"。
//  ② **恒定占位、只改透明度**，不是「出现才长出来」。理由是硬的：这一行
//     `3 (VStack 间距) + 26 (底块) = 29pt`，而贴底判据容差是 **30pt** ⇒「悬停才长高」会让内容底边
//     下移 31pt ⇒ 判成「不贴底」⇒ 鼠标每划过一条用户消息，「回到底部」就闪一下；更糟的是
//     **最新那一条**的按钮会落在视口外，不滚动永远看不见。⇒ 见 `MacTheme.rowBarSlotHeight`。
//  ③ 用户侧**没有**「朗读 / 重试 / 分享」：朗读自己的问题没意义；「重试」在用户侧的语义
//     是「换个人重答」，与这里三件事不是一类（它仍在右键菜单里）。
//
//  ## 与 iOS 的对应
//  角色对应 `AIActionBarView` / `AIRowAction.barActions`。共享的是**定义**，不共享**排版**：
//  - 图标与文案一律取自 `AIRowAction`（`icon` / `activeIcon` / `title`）⇒ 业务层加一项这边自动有；
//  - ⛔ **不要为了少写几行改成遍历 `barActions`**：Mac 的助手侧顺序是用户指定的
//    （复制 / 朗读 / 重试 / 分享），与 iOS 的 `barActions` 顺序不同，遍历会把顺序一起换掉；
//  - **末尾的完整时间是 Mac 独有**，格式仍走 `AIMessageTime.fullString(from:)`，不在这里自己拼。
//
//  ## 为什么助手侧「每条都挂」（iOS 只挂最后一行）
//  iOS 的 `showsActionBar` 只在「最后一条已结束的文本回复」上为 true（`applyActionBarFlags` 算），
//  历史消息走长按操作卡。Mac 有意**不读**那个标志（它仍是 iOS 的真值）。
//  ⚠️ 别为了「统一」去改 `applyActionBarFlags`：iOS 的行高把 `actionBarHeight` 算进去了，会全表错位。
//
//  ## 「重试」落在哪
//  只在助手行 / 失败行上，落点就是它自己。本视图只拿一个 `canRetry` 结果，不自己找行
//  （落点计算在 `ChatDetailView.retryRowIndex(for:)`；用户行那条路径现在只剩右键菜单在用）。
//
//  ## 单次用量：实现过、当天被要求隐藏（2026-10-25）——⛔ 别再问用户第二次
//  一版「入 1.2k · 出 340」⇒ 用户「入 出 看不懂」；二版单值「共消耗 ✦ 1,574」⇒「算了 这个功能还是隐藏吧」。
//  现状：本栏**不显示任何 token 数字**，参数 / 绘制块 / 渲染台板子与探针 / 四条源码契约一并摘除
//  （留半截参数就是死代码）。✅ 数据层与格式化全留着：`block.usage` 照常落 `ai_usage` 表，
//  `AITokenUsage.totalText` / `breakdownText` 仍是两个口径的唯一出口。
//  🔴 要恢复只需接一处：加 `var usage: AITokenUsage? = nil`，在时间之后插
//  `if let usage, let total = usage.totalText { … }`，宿主传 `usage: row.block.usage`（词表条目还在）。
//  ⚠️ 恢复时别只接一半：声明了不传 = 恒 nil = 永远不画，跑图也看不出来。
//
//  ## 尺寸与 iOS 的差异（刻意的）
//  Mac 是指针不是指尖：底块 26（iOS 30）、间距 8（iOS 12）。**不复用** `AIChatRow.actionBarHeight`
//  （35，那是 iOS 的行高口径）——SwiftUI 自己按内容量高，不需要也不该去凑那个数字。
//

import SwiftUI
import AppKit
import AICore

// MARK: - 助手侧（常驻）

struct ChatRowActionBar: View {

    /// 本条消息的正文（复制 / 朗读 / 分享都用它）
    let text: String
    /// 这一条消息的时间（`AIChatRow.createdAt`）。渲染在分享之后 —— 见文件头。
    let timestamp: Date
    /// 这一行正在朗读（只影响「朗读」那颗的图标：`speaker.wave.2` ⇄ `stop.circle`）
    let isSpeaking: Bool
    /// 「重试」是否可用
    let canRetry: Bool
    /// 是否渲染那颗条件出现的「继续生成」（只在 `block.endedTruncated` 的行上）
    let showsContinue: Bool
    /// **全局**是否正在收流。
    ///
    /// 为 true 时「重试」与「继续生成」置灰 —— 两者都会先 `stop()` 再起一条新流，
    /// 与正在跑的那条互相踩（判据与业务层 `AIRowAction.blockedWhileStreaming` 同一套语义）。
    /// 复制 / 朗读 / 分享不受影响：它们不碰流，没理由跟着一起灰。
    let restartsBlocked: Bool

    let onCopy: () -> Void
    let onSpeak: () -> Void
    let onRetry: () -> Void
    let onContinue: () -> Void
    /// 「⋯」菜单里的**引用**：把这条回复的正文挂到输入框上方，等用户接着问
    /// （`ChatModel.beginQuote(rowId:)`）。
    let onQuote: () -> Void
    /// 「⋯」菜单里的**删除**：把列表切进「多选删除」选择模式（默认勾上**这一轮**）。
    ///
    /// 🔴 2026-09-29 起它的语义与另外三个删除入口**完全统一**（右键菜单那条、媒体栏那条、
    ///    以及**用户侧栏那条**）：
    ///    三者都只做一件事 —— `ChatModel.enterSelectionMode(startingAt:)`。
    ///    ⛔ 别在这里直接删行：删不可恢复，而「我要删的其实是另一条」只能靠
    ///    「先看见自己勾了哪几条」兜住（Mac 上一版是弹个确认框就删，挡不住这个）。
    let onRequestDelete: () -> Void

    var body: some View {
        HStack(spacing: MacTheme.actionChipSpacing) {
            ActionChipButton(action: .copy, handler: onCopy)

            ActionChipButton(action: .speak,
                             symbol: isSpeaking ? AIRowAction.speak.activeIcon : AIRowAction.speak.icon,
                             title: isSpeaking ? Self.stopSpeakingTitle : AIRowAction.speak.title,
                             handler: onSpeak)

            // 图标取 `.regenerate`、文案取 `.retry` —— 两者本来就是同一个图标（`arrow.clockwise`），
            // 文案用「重试」是用户的口径（失败行上的那一项业务层也叫这个）。
            // 两个不可用态：① 用户行后面还没有助手回复；② 正在收流（点了会打断当前这条）。
            ActionChipButton(action: .regenerate,
                             title: AIRowAction.retry.title,
                             enabled: canRetry && !restartsBlocked,
                             handler: onRetry)

            share

            // 「⋯」：引用 + 删除。位置**紧贴分享之后**（用户指定），
            // 也就是「常用的四颗」与「时间」之间 —— 它属于动作区，不该排到时间右边去。
            RowOverflowMenu(onQuote: onQuote,
                            canDelete: !restartsBlocked,
                            onDelete: onRequestDelete)

            // 时间：插在**动作区与条件项之间** —— 用户要的是「分享按钮后面」，
            // 而「继续生成」是偶尔才出现的条件项、永远排在最末，所以时间的位置
            // 与它有没有出现无关（不会今天贴分享、明天被挤到中间）。
            Text(AIMessageTime.fullString(from: timestamp))
                .font(MacTheme.ui(MacTheme.metaFontSize))
                .monospacedDigit()
                .foregroundStyle(MacTheme.meta)
                .padding(.leading, 2)

            // 条件项：没写完的回复才有。位置放最后 —— 它是「补救」，不该挤开常用的四颗。
            // 与「重试」同样受收流限制（它也会先 stop() 再起一条流）。
            if showsContinue {
                ActionChipButton(action: .continueGeneration, enabled: !restartsBlocked, handler: onContinue)
            }
        }
    }

    /// 🔴 计算属性，不是 `static let`（2026-10-13）：`static let` 会把 `L()` 的结果
    ///    进程级缓存住 ⇒ 切语言后永远停在旧语言那份，视图重建也救不回来。
    private static var stopSpeakingTitle: String { L("停止朗读") }

    /// 分享走系统原生的 `ShareLink`。
    ///
    /// 刻意**不**手写 `NSSharingServicePicker`：那个要一个 `NSView` 当锚点，
    /// SwiftUI 里得包一层 `NSViewRepresentable` 才能定位弹窗，纯属自找麻烦。
    /// `ShareLink` 自带定位、自带 Services 菜单（AirDrop / 信息 / 邮件 / 备忘录…），
    /// 而且它**本来就是一颗按钮**，样式与我们自己那几颗同源（都用 `ActionChip`）。
    private var share: some View {
        ShareLink(item: text) { ActionChip(symbol: AIRowAction.share.icon) }
            .buttonStyle(.plain)
            .help(AIRowAction.share.title)
    }
}

// MARK: - 用户侧（默认不可见，hover 才显）

/// 用户自己发的那条消息底部的横排操作栏：**时间 · 编辑 · 复制 · ⋯**。
///
/// 🔴 **本视图不决定显隐**：占位与淡入淡出都在 `ChatRowView.reservesUserBar` / `userBarSlot`
/// （恒定占高 + `opacity`），原因（31pt > 容差 30pt）见文件头第 ② 条。
/// 所以这里**不要**加 `.opacity` / `if` 之类的自隐逻辑 —— 两处各管一半必然打架。
/// 同理**不要**在这里加 `.padding(.top)`：助手侧那条有 `MacTheme.rowActionBarTopGap`（2pt），
/// 这条没有 —— 占位高度是按 `MacTheme.rowBarSlotHeight` 单点定义的，加了就把它撑破。
struct ChatRowUserActionBar: View {

    /// 本条消息的正文（复制用它）
    let text: String
    /// 这一条消息的时间（`AIChatRow.createdAt`）。**在最左** —— 见文件头第 ① 条。
    let timestamp: Date
    /// **全局**是否正在收流。「编辑」置灰用。
    ///
    /// 用户侧只有「编辑」属于「会打断流」那一类（`commitEdit` → `editAndResend` 第一步是 `stop()`）。
    /// 复制不碰流，不受影响。禁止进编辑的**硬校验**在 `ChatModel.beginEdit`（点了才拦），
    /// 这里置灰只是提前告知 —— 两处都要有，别只留一处。
    /// ⚠️ 「⋯」里的**删除**也读它（同一个标志位，第二个用途）：删行会让后面所有行的下标前移，
    ///    而流式正靠行下标定位 —— 判据与业务层 `AIRowAction.blockedWhileStreaming` 同源。
    let restartsBlocked: Bool

    let onEdit: () -> Void
    let onCopy: () -> Void
    /// 「⋯ → 引用」：把**自己发的那句话**挂到输入框上方，接着往下问
    /// （`ChatModel.beginQuote(rowId:)`；那边对两个 role 一视同仁，`AIQuote` 会带上 role）。
    ///
    /// ℹ️ 与 iOS 对齐：那边用户行的操作卡横排第一格也是「引用」（`AIRowAction.userMenu` 的 `grid`），
    ///    Mac 只是换了个入口（收进「⋯」），**能引用的范围两边一致**。
    let onQuote: () -> Void
    /// 「⋯ → 删除」：进「多选删除」选择模式，默认勾上**这一轮**（`ChatModel.enterSelectionMode`）。
    ///
    /// 🔴 与另外三个删除入口（右键菜单 / 助手文本栏 ⋯ / 媒体栏 ⋯）是**同一件事**：
    ///    都只做 `enterSelectionMode(startingAt:)`，⛔ 别在这里直接删行（删不可恢复，
    ///    而「我想删的其实是另一条」只能靠「先看见自己勾了哪几条」兜住）。
    let onRequestDelete: () -> Void

    var body: some View {
        HStack(spacing: MacTheme.actionChipSpacing) {
            Text(AIMessageTime.fullString(from: timestamp))
                .font(MacTheme.ui(MacTheme.metaFontSize))
                .monospacedDigit()
                .foregroundStyle(MacTheme.meta)
                .padding(.trailing, 2)

            ActionChipButton(action: .edit, enabled: !restartsBlocked, handler: onEdit)
            ActionChipButton(action: .copy, handler: onCopy)

            // 「⋯」：引用 + 删除（2026-09-29 用户要求「我发送的消息也增加三个点按钮，
            // 里面也是引用和删除」）。
            //
            // 位置 = **栏尾**（用户侧的时间在最左，所以「动作区末位」在这里就是最右）——
            // 与助手那两条栏同一个口径：破坏性动作离最常用的（复制 / 编辑）最远。
            // `canDelete` 与「编辑」共用 `restartsBlocked`：两者都会踩到正在跑的流。
            // ⚠️ 但收流中**这颗底块本身不置灰** —— 灰的只是菜单里那一项（`canDelete`），因为「引用」
            //    在收流中照常可用（引用只是把内容挂到输入框上方，不碰流）。与助手两条栏同一口径。
            //
            // ⚠️ 加这一颗**不改任何高度**：所有底块都是 `actionChipSize`(26)，而这一行的占位
            //    高度是 `rowBarSlotHeight`(26) 单点定的；变的只是宽度（向右多长出
            //    `间距 8 + 底块 26`）。而那一行是 `.frame(height:)` 定死、宽度自适应的 ⇒
            //    「占位常驻」那条约束（31pt > 贴底容差 30pt）不受影响。
            //    （实测：`rows_940` 与 `rows_940_hover` 两张图做垂直互相关，最佳位移 = 0。）
            // ⚠️ 它在**hover 才显**的那一行里 ⇒ 菜单弹窗与「会话行 hover 才显的『…』」
            //    完全同款（`ConversationRow.moreButton`，2026-09-26 起在用）：
            //    指针移进菜单后那一行会淡出，而弹窗本身是 AppKit 的独立窗口，不受影响。
            //    ☠️ 这件事**只能人按鼠标验**（合成事件投不出去，见 `VERIFY-PROBES.md`）。
            RowOverflowMenu(onQuote: onQuote,
                            canDelete: !restartsBlocked,
                            onDelete: onRequestDelete)
        }
    }
}

// MARK: - 单颗底块（两个操作栏共用）

/// 操作栏上的一颗底块：图标 + 圆角底。
///
/// 🔴 **两个宿主共用**（助手侧 / 用户侧）—— 各写一份迟早会漂成「两边圆角差 1」「暗色下底色
/// 深浅不一致」这种 review 不出来、但并排一看就很明显的差别。所以这里只留一处实现。
private struct ActionChip: View {

    let symbol: String

    /// 不可用态（如「重试」在用户行后面还没有回复时、收流中的「编辑」）。
    /// ⚠️ 必须**显式**给灰：`.disabled(true)` 只拦交互，管不到我们写死的 `foregroundStyle`。
    var enabled: Bool = true

    /// 破坏性动作画成红色（2026-09-29 加）。
    ///
    /// ⚠️ 判据**不在这里**、也不由调用方随手传 —— `ActionChipButton` 读业务层的
    ///    `action.isDestructive` 自动带上（那边现在只有 `.delete`）。
    ///    这样「业务层把某一项标成破坏性」与「这里画成红的」永远同步，
    ///    不会出现「新加了个危险动作，忘了上色」这种只有 review 才看得出的漏。
    var destructive: Bool = false

    /// 底块透明度分浅深两档，所以这里必须真的读到当前外观
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: symbol)
            .font(MacTheme.ui(MacTheme.actionIconSize, weight: .regular))
            .foregroundStyle(iconColor)
            .frame(width: MacTheme.actionChipSize, height: MacTheme.actionChipSize)
            .background(
                RoundedRectangle(cornerRadius: MacTheme.actionChipRadius)
                    .fill(MacTheme.actionChipBackground(scheme))
            )
            // 命中区 = 整个底块（不加的话只有图标本身那几个像素可点）
            .contentShape(RoundedRectangle(cornerRadius: MacTheme.actionChipRadius))
    }

    /// 不可用态优先（灰盖过红：置灰的删除不该还红着，那会读成「可以点」）。
    private var iconColor: Color {
        guard enabled else { return MacTheme.actionIconDisabled }
        return destructive ? MacTheme.actionIconDestructive : MacTheme.actionIcon
    }
}

/// 底块 + 点击 + tooltip。
///
/// - Parameters:
///   - action: 提供默认的图标与文案（**唯一来源**，见文件头）
///   - symbol: 覆盖图标（只有朗读的播放态会用到）
///   - title: 覆盖文案（同上）
///   - enabled: 不可用时置灰且不响应点击
///
/// ⚠️ 复制 / 朗读 / 分享**没有**「正文为空就置灰」的分支：两条栏都只在正文非空的行上出现
///    （判据在 `ChatRowView`），那种状态到不了这里 —— 加了就是永远走不到的死分支。
private struct ActionChipButton: View {

    let action: AIRowAction
    var symbol: String? = nil
    var title: String? = nil
    var enabled: Bool = true
    let handler: () -> Void

    var body: some View {
        Button(action: handler) {
            // 🔴 `destructive` 读业务层（`AIRowAction.isDestructive`）而不是由调用方传 ——
            //    「哪一项是危险动作」这句话只在业务层说一次（当前只有 `.delete`）。
            ActionChip(symbol: symbol ?? action.icon,
                       enabled: enabled,
                       destructive: action.isDestructive)
        }
        .buttonStyle(.plain)
        .help(title ?? action.title)
        .disabled(!enabled)
    }
}

// MARK: - 「⋯」溢出菜单（四条操作栏共用，2026-09-29）

/// **四条**操作栏共用的「⋯」菜单：**引用（可选）+ 删除**。
///
/// 🔴 共用是刻意的：助手文本栏 / 用户侧栏 / 助手媒体栏 / **用户图片栏**的「删除」那一项
///    **完全一致**（用户指定），各写一份迟早漂成「一个先引用、一个先删除」——这种差别 review
///    看不出来，并排点开一眼就看得出。
///    ⚠️ 「引用」**只有两条文本栏有**：两条媒体栏（助手图 / 视频、**用户自己发的图**）的那一项
///    已被用户 2026-09-29 要求去掉，判据与来由见文件头。
///    ⚠️ 两条文本栏的「引用」**取的内容不同**（助手正文 / 我自己发的那句话），
///    但那是调用方给的 `onQuote` 的事 —— 本视图只负责「长什么样、点了喊谁」。
///
/// ⚠️ 四处的「删除」自 2026-09-29 起是**同一件事**：都把列表切进「多选删除」选择模式
///    （`onDelete` 由调用方给，实际落在 `ChatModel.enterSelectionMode(startingAt:)`）。
///
/// ## 为什么用系统 `Menu` 而不是自绘弹层
/// 与输入栏的 `+` / 模型选择器同一个理由：打勾、键盘上下选、点外面关闭、Esc 全由系统给；
/// 自绘那一套三件事都得自己写，而且行高 / 高亮与系统菜单对不齐。
/// ☠️ 代价：离屏渲染里 `.menuStyle(.borderlessButton)` 那种 `Menu` 是「黄条 + ⊘」
///    （系统画的）⇒ **展开后长什么样只能靠 `render_mac_ui.sh root` 的真窗口截图验**，
///    `render` 那几张只能验「它占的位置对不对」。
///    ℹ️ 但本菜单用的是 `.menuStyle(.button)` + `.buttonStyle(.plain)` + 自绘 label ⇒
///    **离屏照得出来**（顶多 label 里的图标位置略有出入），2026-09-29 实测确认过，
///    见 `VERIFY-PROBES.md` 盲区清单里那条更正。
/// ⚠️ 用户侧那条栏是 **hover 才显** 的，本菜单因此跟着它一起隐现 ——
///    与「会话行 hover 才显的『…』」完全同款（`ConversationRow.moreButton`）。
private struct RowOverflowMenu: View {

    /// 「引用」的落点。
    ///
    /// 🔴 **可选 = 这一项在不在的判据**（`nil` ⇒ 菜单里没有这一项）。
    ///    刻意**不**另设一个 `showsQuote: Bool` 开关：那种设计迟早出现
    ///    「开关说显示、却没人给落点」= 一项点了没反应的死项，而这正是本工程
    ///    在 `onRequestDelete` 那条注释里点名的忌（「多一个 `nil` 就多一处『点了没反应』」）。
    ///    一个可选闭包把「有没有」和「点了喊谁」绑成一件事，想错都错不了。
    /// ⚠️ 收流中「引用」**照常可用**：它只是把内容挂到输入框上方，不碰流
    ///    （与业务层 `AIRowAction.blockedWhileStreaming` 不含 `.quote` 同口径）。
    var onQuote: (() -> Void)?
    /// 「删除」是否可用。收流中必须禁用：删行会让后面所有行的下标前移，
    /// 而流式正靠行下标定位（同 `AIRowAction.blockedWhileStreaming` 里 `.delete` 那一条）。
    let canDelete: Bool
    let onDelete: () -> Void

    var body: some View {
        Menu {
            if let onQuote {
                Button(action: onQuote) {
                    Label(Self.quoteTitle, systemImage: AIRowAction.quote.icon)
                }
                // 分隔线跟着那一项一起进出：媒体栏只有一项时，头顶多一条线会显得菜单被截断
                Divider()
            }

            // 破坏性项：交给系统画红（`.destructive` role）。
            // ⚠️ 与 `ActionChip` 那支红色（`ActionChip.isDestructive`）同一个语义、同一个来由
            //    （业务层 `AIRowAction.isDestructive`）—— 只是菜单项的颜色由 AppKit 给。
            Button(role: .destructive, action: onDelete) {
                Label(AIRowAction.delete.title, systemImage: AIRowAction.delete.icon)
            }
            .disabled(!canDelete)
        } label: {
            ActionChip(symbol: Self.symbol)
        }
        // 自己画的底块已经够清楚，再加系统的双箭头指示器会把底块挤宽
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(Self.title)
    }

    /// 图标：全 App 唯一一处「⋯」
    private static let symbol = "ellipsis"
    /// tooltip
    /// 🔴 计算属性，不是 `static let`（2026-10-13）—— 同 `stopSpeakingTitle` 那条。
    private static var title: String { L("更多") }

    /// 菜单里那一项的文案。
    ///
    /// 🔴 **用户 2026-09-29 先要「追问」、当晚改回「引用」** ⇒ Mac 与 iOS **两端文案现在一致**
    ///    （业务层 `AIRowAction.quote.title` 也是「引用」）。⚠️ 别再单方面改成别的叫法 ——
    ///    上一版为了让 Mac 显示「追问」在这儿硬编了一个常量，现在它只是「与业务层同值」，
    ///    ⛔ 别为了「少一处字面量」去读 `AIRowAction.quote.title`：那样以后想两端分叉又得改回来。
    /// 🔴 计算属性（同上）：`static let` 会把语言锁死。
    private static var quoteTitle: String { L("引用") }
}

// MARK: - 媒体侧（AI 回复里的图 / 视频，2026-09-29 加）

/// **AI 回复里的图片消息 / 视频消息**底部的操作栏：**只有分享 + ⋯ + 时间**。
///
/// 🔴 **⋯ 里只有「删除」**（2026-09-29 用户要求去掉媒体引用，原话「先把图片 和 视频的
///    引用去掉」）—— ⚠️ 所以这一栏**传 `onQuote` 的位置是空的**，那不是漏写，
///    是 `RowOverflowMenu` 里「有落点才有这一项」这条判据的用法（见那边注释）。
///    为什么去掉：图片 / 视频与同一次回复的那段文字是**三条独立消息**（用户口径），
///    引用一张图就该引「那张图」自己，而当时能取到的只有「同轮里 AI 的那段文字」= 指错对象；
///    更要紧的是**助手侧的图根本不进请求上下文**（远程 URL，从没落地），
///    写了「[1 张图片]」模型也看不见 ⇒ 那是个做不到的承诺。详见文件头那段。
///
/// 🔴 它属于**一组**媒体，不是「一条一栏」：Mac 侧连续的助手媒体行已被投影成一条横滑条
///    （`ChatTranscriptItem.group` → `ChatDetailView.mediaItem`）⇒ 这一栏天然服务整组。
///    ⚠️ 也因此**时间取的是整组的时间**（调用方给，取组首那行的 `createdAt`）——
///    组内每行时间只差几毫秒，画五个时间既没意义又把栏撑宽。
///
/// 🔴 **「删除」= 进「多选删除」选择模式，默认勾上整轮**（2026-09-29 起，与 iOS 完全一致）。
///    ⚠️ 上一版这里是「只删这组媒体、同轮文字留着」—— 那条语义已被用户推翻（他选了
///    「完全跟 iOS 一致」）。现在四个删除入口（右键菜单 / 助手文本栏 ⋯ / 本栏 ⋯ / 用户侧栏 ⋯）
///    走的是**同一条路**：`ChatModel.enterSelectionMode(startingAt:)`，
///    想只删这几张图就在选择模式里把同轮其它行取消勾选。
///    ⛔ 别改回「直接删这组」：那条路绕开了选择模式，等于给「删不可恢复」开了个后门。
///
/// ⚠️ 这里**没有**复制 / 朗读 / 重试：那几颗在媒体行上「对象不明确」
///    （见 `ChatRowView.showsActionBar` 第 ② 条），所以助手侧媒体行从来就没有那一栏。
/// ⚠️ 「分享」分享的是**媒体本身**（远程链接 / 本地文件），**不是**同一轮的文字 ——
///    与 iOS 媒体行同口径；⛔ 别照抄上面 `ChatRowActionBar.share` 那个走 `text` 的写法。
struct ChatRowMediaActionBar: View {

    /// 这一组媒体的地址（图片取 `imageURL`、视频取 `videoURL`，见 `ChatDetailView.mediaURLs(in:)`）。
    /// ⚠️ 调用方**必须先判空**：地址全缺时整栏都不画，别只藏掉分享、留一颗孤零零的 ⋯。
    let mediaURLs: [URL]

    /// 这一组媒体的时间（组首那行的 `createdAt`）。渲染在末尾 —— 与助手文本栏同一个位置。
    let timestamp: Date

    /// 「删除」是否可用。**流式进行中置灰**（与助手侧「重试」同一套判据）：
    /// 删行会让它后面所有行的下标前移，而流式正靠 `streamingRowIndex` 定位那一行
    /// （＝业务层 `AIRowAction.blockedWhileStreaming` 的语义）。
    /// ⚠️ 是「置灰」不是「藏起来」：Mac 每条媒体组都有这一栏，整栏隐现会让整屏按钮闪一下。
    let canDelete: Bool

    /// 「⋯ → 删除」：进「多选删除」选择模式（默认勾整轮，见文件头那段）。
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: MacTheme.actionChipSpacing) {
            share

            // 原先这里是一颗**裸露的红色垃圾桶**（用户上一轮要求「只有分享和删除」）。
            // 2026-09-29 起收进「⋯」：破坏性动作从「一眼可见的一颗红按钮」变成「要点两次」，
            // 刻意加一道确认。
            //
            // 🔴 **不传 `onQuote`** ⇒ 菜单里就只有「删除」一项（2026-09-29 用户要求去掉
            //    图片 / 视频的引用）。⛔ 别为了「跟文本栏长得一样」把它补上一个空闭包 ——
            //    那会让菜单里冒出一项点了没反应的「引用」。
            RowOverflowMenu(canDelete: canDelete, onDelete: onDelete)

            // 时间（2026-09-29 用户要求「图片消息和视频信息也要显示时间」）。
            // 格式仍走业务层 `AIMessageTime.fullString(from:)`，⛔ 不在这里自己拼。
            Text(AIMessageTime.fullString(from: timestamp))
                .font(MacTheme.ui(MacTheme.metaFontSize))
                .monospacedDigit()
                .foregroundStyle(MacTheme.meta)
                .padding(.leading, 2)
        }
    }

    /// 分享（系统 `ShareLink`）—— 与助手侧那条同一个理由：不手写 `NSSharingServicePicker`
    /// （那个要一个 `NSView` 当锚点，SwiftUI 里得包一层 `NSRepresentable` 才定位得了弹窗）。
    ///
    /// ⚠️ 用 `items:` 而不是 `item:` —— 一组可能是 5 张图，分享出去的就是 5 个地址。
    private var share: some View {
        ShareLink(items: mediaURLs) { ActionChip(symbol: AIRowAction.share.icon) }
            .buttonStyle(.plain)
            .help(mediaURLs.count > 1 ? String(format: L("分享这 %d 个文件"), mediaURLs.count) : AIRowAction.share.title)
    }
}

// MARK: - 用户图片侧（用户自己发的图，2026-10-09 加）

/// **用户自己发的图片**下方那条操作栏：**时间 · 分享 · ⋯（只有删除）**。
///
/// 用户 2026-10-09 要求：「Mac端 我发送的图片消息 也要和 文字消息一样 底部有 AIActionBarView，
/// 默认隐藏，鼠标移动到图片上显示，但图片的只有时间 和分享和 三个点 按钮」。
///
/// ## 🔴 为什么与 `ChatRowMediaActionBar`（助手媒体侧）是**两个视图**而不是一个加参数
///
/// 两条栏**能跑的**形态有三处不同，合并成一个 `isUser: Bool` 的视图会让三处各写一个 `if`：
/// ① **顺序**：助手侧是「分享 · ⋯ · 时间」（时间在**栏尾**），本栏按用户口述是
///    **时间在最左** —— 与用户侧文本栏（`ChatRowUserActionBar`）同一个口径，
///    用户侧两条栏必须长得一致；
/// ② **显隐**：助手侧**常驻**，本栏**hover 才显**（与用户侧文本栏同）；
/// ③ **⋯ 的内容**：本栏**不传 `onQuote`** ⇒ 菜单里只有「删除」。
/// ⛔ 别为了「少一个视图」把它们合并 —— 那是本仓库最常见的「参数 Bool 化」漂移来源。
///
/// ## 🔴 显隐**不在这里**（与另外两条 hover 栏同口径）
/// 恒占位 + `opacity` + `allowsHitTesting`，判据在 `ChatDetailView.userImagesItem`
/// —— ⚠️ **必须是恒占位**：用户图片条下方那一行原本**什么都不占**，
/// 若改成「hover 才插进来」，鼠标每划过一条图片消息，下方所有内容都会往下移 29pt
/// ⇒ `ChatDetailView` 的贴底判据（容差 30pt）当场翻成「不贴底」⇒「回到底部」按钮狂闪。
/// 成因与实测数字见 `ChatRowUserActionBar` 文件头第 ② 条（那里是同一类问题的第一次实录）。
///
/// ## 分享的是**图片文件本身**
/// `items:` 给的是这一组用户图的 `imageURL`（附件落盘后的本地地址），⛔ 不是同轮的文字
/// —— 与助手媒体栏同一口径，两者用的是**逐字相同**的 `ShareLink(items:)` 写法。
///
/// ⚠️ 地址全缺时整栏都不画（调用方 `userImagesItem` 判空）—— 留一颗点了没反应的分享更糟。
struct ChatRowUserMediaActionBar: View {

    /// 这一组用户图片的地址（`ChatDetailView.mediaURLs(in:)`，图片取 `imageURL`）。
    let mediaURLs: [URL]

    /// 这一组的时间（**组首**那行的 `createdAt`）。组内各行只差几毫秒，画五个时间既没意义
    /// 又把栏撑宽 —— 与助手媒体栏同一个理由（见那边注释）。
    let timestamp: Date

    /// 「删除」是否可用。**流式进行中置灰**（与其它三条栏同一套判据：
    /// 删行会让后面所有行的下标前移，而流式正靠 `streamingRowIndex` 定位那一行）。
    let canDelete: Bool

    /// 「⋯ → 删除」：进「多选删除」选择模式。
    /// 🔴 与其它三个删除入口（右键菜单 / 两条文本栏的 ⋯ / 助手媒体栏 ⋯）**完全统一**：
    /// 都只做 `enterSelectionMode(startingAt:)`，⛔ 别在这里直接删行。
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: MacTheme.actionChipSpacing) {
            // 🔴 时间在**最左**（用户 2026-10-09 口述的顺序，也是用户侧两条栏的统一口径）。
            // ⚠️ 与助手媒体栏相反**不是笔误**：那边时间在栏尾是 2026-09-29 定稿的用户要求，
            //    两条栏各按各自那一次的要求来，别「顺手对齐」。
            Text(AIMessageTime.fullString(from: timestamp))
                .font(MacTheme.ui(MacTheme.metaFontSize))
                .monospacedDigit()
                .foregroundStyle(MacTheme.meta)
                .padding(.trailing, 2)

            share

            // ⚠️ **不传 `onQuote`** ⇒ 菜单里只有「删除」一项（媒体不给引用，成因见文件头）。
            //    ⛔ 别为了「跟文本栏长得一样」补一个空闭包 —— 那会冒出一项点了没反应的「引用」。
            RowOverflowMenu(canDelete: canDelete, onDelete: onDelete)
        }
    }

    /// 分享（系统 `ShareLink`，`items:`）—— 与助手媒体栏同一个理由：
    /// 不手写 `NSSharingServicePicker`（要一个 `NSView` 锚点，SwiftUI 里得包一层
    /// `NSViewRepresentable` 才定位得了弹窗，纯属自找麻烦）。
    private var share: some View {
        ShareLink(items: mediaURLs) { ActionChip(symbol: AIRowAction.share.icon) }
            .buttonStyle(.plain)
            .help(mediaURLs.count > 1 ? String(format: L("分享这 %d 个文件"), mediaURLs.count) : AIRowAction.share.title)
    }
}

// MARK: - 文件卡片末尾的分享（用户发来的文件消息，2026-10-06 加）

/// **用户发来的文件消息**卡片**末尾**那颗「分享」的**外观**。
///
/// 用户 2026-10-06 要求：「Mac端 文件消息 的末尾 增加一个分享按钮 平时隐藏，
/// 鼠标移动到文件消息上 显示」。
///
/// 🔴 **显隐不在这里** —— 与另外两条「hover 才显」的东西同一个口径：
///    恒占位 + `opacity` + `allowsHitTesting`，判据在 `ChatRowView.fileShareButton`
///    （那边注释里写了「为什么必须一直留在布局里」）。⛔ 别在本视图里加 `.opacity` / `if`：
///    两处各管一半必然打架（同 `ChatRowUserActionBar` 那条约束）。
///
/// ## 为什么复用 `ActionChip`（而不是画一颗裸图标）
/// 全 App 三处「分享」——助手文本栏 / 助手媒体栏 / **这里**——用的是**同一颗底块**、
/// 同一个图标、同一句 tooltip（都取业务层 `AIRowAction.share`）。
/// 差别只在「挂在哪」：前两处在正文**下方**的栏里，这一颗在文件卡片**内部**的末尾。
/// 各画一份迟早漂成「三处圆角 / 深浅各不同」，而并排一看就很明显。
///
/// ## 🔴 分享的是**文件本身**
/// `item:` 拿到的是 `row.block.fileURL`，**不是**同轮的文字 —— 与媒体栏同口径。
/// ⚠️ 别照抄上面 `ChatRowActionBar.share` 那个 `ShareLink(item: text)` 的写法：
///    文件行的「分享」把一段话分享出去，用户拿到的不是他要的那个文件
///    （iOS 那边 `mediaShareURL(of:)` 为同一件事单列了一条 `case .file`）。
struct ChatFileShareButton: View {

    /// 要分享的**文件地址**。
    /// ⚠️ 调用方**必须先判空**（`row.block.fileURL` 是可选）：地址缺失时整颗都不画，
    ///    别留一颗点了没反应的按钮（同 `ChatRowMediaActionBar.mediaURLs` 那条约定）。
    let fileURL: URL

    var body: some View {
        ShareLink(item: fileURL) { ActionChip(symbol: AIRowAction.share.icon) }
            .buttonStyle(.plain)
            .help(AIRowAction.share.title)
    }
}
