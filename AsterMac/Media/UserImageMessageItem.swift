//
//  UserImageMessageItem.swift
//  AsterMac
//
//  「用户自己发的一组图片」这条**显示项**的完整渲染：横排的图（`UserImageStrip`）
//  + 下面那条**时间 · 分享 · ⋯** 的操作栏（`ChatRowUserMediaActionBar`）。
//
//      ┌────┐┌────┐┌────┈┈
//      │ 图1 ││ 图2 ││ 图3┈┈ ← UserImageStrip（横向，放不下就滚）
//      └────┘└────┘└────┈┈
//        11:46  ⤴  ⋯          ← ChatRowUserMediaActionBar（**hover 才显**，恒占位）
//
//  ## 🔴 2026-10-09 用户要求
//
//  原话：「Mac端 我发送的图片消息 也要和 文字消息一样 底部有 AIActionBarView，
//  默认隐藏，鼠标移动到图片上显示，但图片的只有时间 和分享和 三个点 按钮」。
//
//  ⚠️ 这条要求**推翻了 2026-10-08 的第 ④ 条**（当时刻意「不挂操作栏」，理由是
//  「凭空多出一行高度」）—— 现在用户就是要这一行。**那条理由本身仍然成立**
//  （hover 显隐绝不能改变行高），所以实现改成「**恒占位**」而不是「悬停才长出来」：
//  详见下面「恒占位」那一节。
//
//  ## 🔴 为什么这一条**不是** `ChatRowView` 的一部分
//
//  用户图片行在 `ChatDetailView` 里被投影成 `.userImages` 显示项
//  （`ChatTranscriptItem.group` → `AIChatMediaGrouping.userImageGroupRange`），
//  **一条显示项代表 N 行** ⇒ `ChatRowView` 那一套「一行一块 + `rowIndex`」的模型
//  在这里不成立（`ChatRowView` 收到的是单行，不存在「整组」这个概念）。
//  ⇒ 与助手媒体那条（`ChatDetailView.mediaItem` + `ChatRowMediaActionBar`）**完全同构**。
//  ⛔ 别为了「统一」把它塞回 `ChatRowView`：那要么把整组塞进一个 `row`（`rows` 与显示项
//  一一对应的假设立刻破），要么在 `ChatRowView` 里开一个「我可能代表多行」的后门。
//
//  ## 🔴 hover 命中区必须是**内容宽**，不是全宽
//
//  `.onHover` 必须挂在撑满全宽那个 `.frame(maxWidth: .infinity)` **之前**
//  （与 `ChatRowView` 同一条约束，理由见那边 `body` 里的注释）：
//  挂之后的话，鼠标从列表中间横穿过去会**沿途点亮每一条**图片消息的操作栏。
//  ⚠️ 这一条**必须**自己上报 hover（以前图片行没有 hover 东西，现在有了）——
//  ⛔ 别因为「从前不需要」就以为可以复用 `ChatRowView` 那套。
//
//  ## 🔴 宽度 = 「图」与「栏」里更宽的那个
//
//  用户图片整档乘 `MacTheme.userImageScale`（0.25）之后**常常比操作栏窄**
//  （单张竖图可能只有 ~90pt，而「时间 · 分享 · ⋯」约 160pt）。
//  只按图的宽给这一条 ⇒ 栏右边那颗「⋯」被裁掉一截 —— 而「⋯」恰好是这条栏里
//  最重要的一颗（删除入口在那里面）。
//  ⇒ 宽度取 `max(图的实际占宽, 栏的最小宽)`，**再夹到容器宽**。
//  ⚠️ 图那一档的宽由 `UserImageStrip.occupiedWidth` 给（**单点**，⛔ 别在这里另算一遍）。
//
//  ## 🔴 恒占位（与 `ChatRowUserActionBar` 同一条铁律）
//
//  那一行**恒占** `MacTheme.rowBarSlotHeight`（26），只改 `opacity` + `allowsHitTesting`。
//  ⚠️ 这一条**比文本那条更要紧**：它原本**什么都不占**，所以「悬停才长出来」会让
//  下方所有内容在鼠标划过时整体下移 `3 + 26 = 29pt`
//  ⇒ `ChatDetailView` 的贴底判据（容差 30pt）当场翻成「不贴底」⇒「回到底部」按钮狂闪。
//  同类事故的第一次实录（实测 31 > 30）见 `ChatRowUserActionBar` 文件头第 ② 条。
//
//  ## 与 iOS 的对应关系
//
//  iOS 侧同一角色是 `AIUserImageStripCell`（**只有图，没有操作栏**）—— 那边是长按出操作卡。
//  两边**不共享排版**：Mac 是「底部常驻一行 + hover 显隐」，iOS 是「表格 cell + 长按」。
//  ⚠️ 别把 Mac 这个形态搬进共享层：`AIUserImageStripCell` 的行高是 iOS 表格口径
//  （`userImageGroupRowHeight` = 最高格 + 12），加一条 26pt 的栏会把那一档行高全表带歪。

import SwiftUI
import AppKit
import AICore

/// 「用户自己发的一组图片」+ 它下面那条 hover 才显的操作栏。
///
/// ⚠️ 宿主（`ChatDetailView`）负责的三件事，本视图**一律不管**：
/// ① `.id(组首 id)` 锚点 · ② `liveRowIds` 行存活上报 · ③ 右键菜单。
/// 那三样都属于「消息列表」而不是「一条消息长什么样」，与 `MediaThumbStrip` 的切分同一条理由。
struct UserImageMessageItem: View {

    /// 同一次发送里的用户图片行（按发送顺序）。⚠️ 是**整组**，不是单行。
    let rows: [AIChatRow]

    /// 滚动区容器宽（由 `ChatDetailView` 的 `GeometryReader` 传入）。
    /// 🔴 它同时是**格子尺寸**与**本条宽度上限**的唯一输入 —— 两个用途都必须用同一个值，
    /// 否则「图按 A 宽、这条按 B 宽」⇒ 栏会被裁（见文件头「宽度」那一节）。
    let containerWidth: CGFloat

    /// 这一组图片的地址（宿主用 `mediaURLs(in:)` 取 —— **单点**，⛔ 别在这里重算一遍）。
    /// ⚠️ 为空时整条操作栏**不画**（留一颗点了没反应的分享更糟）。
    let urls: [URL]

    /// 指针是否停在这一条上（宿主按 `hoveredRowId` 给，与 `ChatRowView.isHovered` 同一套）。
    var isHovered: Bool = false

    /// 是否处于「多选删除」选择模式。此刻整条操作栏**不画**（点不到它）。
    var isSelectionMode: Bool = false

    /// 「删除」是否可用（流式中置灰）。判据与其它三条栏同源。
    var canDelete: Bool = true

    /// 点某一格 → 开预览窗口（`MediaPreviewWindowCenter`）。
    /// ⚠️ 带默认值 `nil`：渲染台那些「只验长相」的板不必为它改一行。
    var onOpen: ((MediaPreviewItem) -> Void)? = nil

    /// 「⋯ → 删除」：进「多选删除」选择模式（`ChatModel.enterSelectionMode`）。
    /// 🔴 与其它三个删除入口**完全统一**：⛔ 别在这里直接删行。
    let onDelete: () -> Void

    /// 指针进出的回调（宿主据此维护 `hoveredRowId`）。
    /// ⚠️ 与 `ChatRowView.onHoverChange` 同款：状态放在宿主按 `row.id` 记，
    /// 不能用本视图的 `@State` —— `ForEach` 的 id 是显示项下标，行一插一删就会走错行。
    let onHoverChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            UserImageStrip(rows: rows,
                           containerWidth: containerWidth,
                           onOpen: onOpen)
            barSlot
        }
        // 🔴 宽度取「图」与「栏」里更宽的那个，再夹到容器宽 —— 理由见文件头。
        //    ⚠️ 这个 `.frame(width:)` 是**恒定**的（不随 hover 变）⇒ 不破坏「恒占位」。
        .frame(width: itemWidth, alignment: .trailing)
        // 🔴 `onHover` 必须在这个撑满全宽的 frame **之前**（理由见文件头）。
        //    ⚠️ 选择模式下直接忽略：那一栏此刻根本不显（见 `revealsBar`）。
        .onHover { inside in
            guard !isSelectionMode else { return }
            onHoverChange(inside)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: - 宽度

    /// 「图 + 栏」这一条**实际占多宽**。
    ///
    /// ⚠️ 三档的顺序有讲究：**先取更宽的、再夹容器宽**。反过来的话
    /// 「图很宽 + 栏 160」那档会被容器宽夹掉 ⇒ 栏被裁（症状：⋯ 被切掉一半）。
    private var itemWidth: CGFloat {
        let strip = UserImageStrip.occupiedWidth(rows: rows, containerWidth: containerWidth)
        guard showsBar else { return strip }
        return min(containerWidth, max(strip, Self.barMinWidth))
    }

    /// 操作栏那一行的**最小宽度**（时间 · 分享 · ⋯）。
    ///
    /// 📌 这个数只用于「别把栏裁了」这一个判断，**不参与任何高度计算**
    /// ⇒ 与 `MacTheme` 里那些尺寸一样，**两端不需要同值**。
    /// 验算：`AIMessageTime.fullString` 最长一档（"2026/10/09 11:46" 那一族）
    /// + 两颗 26 的底块 + 一个 8 的间距 + 两侧各 2 的内衬 ≈ 150pt ⇒ 取 **160** 留一档余量。
    /// 🔴 改它之前先看一眼 `ChatRowUserMediaActionBar` 的 `body`：那里是**三件东西**
    /// （时间 / 分享 / ⋯），少一颗就得多留 26+8 的余量。
    ///
    /// 📌 **刻意不是 `private`**：渲染台探针 `USERIMGBAR` 要拿它复算「这一条该有多宽」，
    /// 好与「栏的自然宽」比一比（判据「三颗没被裁」）。与 `UserImageStrip.occupiedWidth`
    /// 同一个理由 —— 这两个数是同一条宽度规则的**两半**，探针里不许再抄一份。
    static let barMinWidth: CGFloat = 160

    // MARK: - 操作栏（恒占位）

    /// 那一栏此刻**存不存在**（不是「显不显」—— 显隐是 `revealsBar` 的事）。
    ///
    /// ⚠️ 三条判据与 `mediaItem` 那一栏**逐字同源**：选择模式不画 · 有地址才画。
    /// 🔴 **判据是「存不存在」而不是「有没有 hover」** —— 本视图**恒占位**，
    /// 所以即使 `isHovered == false`，那个 `.frame(height:)` 也必须在（见文件头「恒占位」）。
    private var showsBar: Bool {
        !isSelectionMode && !urls.isEmpty && !rows.isEmpty
    }

    /// 「hover 才显」的**单点**判据。
    ///
    /// ⚠️ `opacity` 与 `allowsHitTesting` 必须读**同一个**函数 —— 少判一处就是
    /// 「看不见却点得动」（`opacity(0)` 的按钮照样能点、`.help` 照样会弹）。
    private var revealsBar: Bool { isHovered && !isSelectionMode }

    private var barSlot: some View {
        Group {
            if showsBar, let head = rows.first {
                ChatRowUserMediaActionBar(mediaURLs: urls,
                                          // 时间取**组首**那行（组内各行只差几毫秒，
                                          // 画五个时间既没意义又把栏撑宽）—— 与 `mediaItem` 同口径。
                                          timestamp: head.createdAt,
                                          canDelete: canDelete,
                                          onDelete: onDelete)
                    // 淡入淡出而不是 `if`：位置不参与布局（占位是 `.frame(height:)` 给的），
                    // 所以这里怎么变都不会推动别的行。
                    .opacity(revealsBar ? 1 : 0)
                    // ☠️ 淡出之后**必须**交还触摸权 —— 与「回到底部」那颗按钮、
                    // 「文件卡片末尾的分享」是同一条处理。
                    .allowsHitTesting(revealsBar)
            }
        }
        // 🔴 占位高度与用户侧那条**文本**操作栏**同一个常数**（用户要的是「和文字消息一样」）。
        //    两处若差一像素，同屏里两类消息的操作栏会高低不齐。
        .frame(height: MacTheme.rowBarSlotHeight, alignment: .trailing)
    }
}
