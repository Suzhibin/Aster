//
//  UserImageStrip.swift
//  AsterMac
//
//  会话里**用户自己发的**图片：一条**横向排列**的图（2026-10-08 用户要求
//  「Mac端 发送一条消息 内含多个图片 ，要横排显示」）。
//
//      ┌────┐┌────┐┌────┐┌────┈┈
//      │ 图1 ││ 图2 ││ 图3 ││ 图4  ← 同一轮里的用户图，横向排一行
//      └────┘└────┘└────┘└────┈┈
//
//  ## 🔴 为什么与助手侧的 `MediaThumbStrip` 是**两个视图**（别合并）
//
//  | | 用户侧（本文件） | 助手侧（`MediaThumbStrip`） |
//  |---|---|---|
//  | 格子尺寸 | `AIChatRow.userImageDisplaySize(…:scale: MacTheme.userImageScale)`：**按真实宽高比**、整档乘 0.25 | 固定 **108×192 竖版 9:16**、`.fill` 裁切 |
//  | 格子高 | **每张各自的高**（竖图就是竖的）⇒ 行高 = 最高那张 | 恒192 |
//  | 对齐 | **底部对齐**（底边齐平，像桌上摆一排照片） | 顶部对齐（统一裁切，无所谓） |
//  | 分组判据 | `AIChatMediaGrouping.userImageGroupRange` | `AIChatMediaGrouping.kind(of:)` |
//
//  ⛔ **别把两边并成一套**：尺寸口径完全不同（真实比例 vs 统一裁切）。
//  合成一个视图就必然出现「用户图被裁成 9:16」或「助手图退回按比例」这种回潮。
//
//  ## 🔴 格子尺寸仍然走共享层那一个函数（不另算一遍）
//
//  `userImageDisplaySize` 是用户图尺寸的**唯一真值**（`AIChatRow.height(in:)` 与渲染同源）。
//  本文件每一格都调它、`scale` 传同一个 `MacTheme.userImageScale`
//  ⇒ **单张发与多张发，每一格都是同一个大小**，用户不会看到「发一张大、发三张小」。
//  ⛔ 别在视图层写 `containerWidth * AIChatRow.userMediaWidthRatio / 3` 这种「按张数摊」。
//  那会让同一张图在 1 张 / 3 张 / 5 张下**三个大小** —— 而 `height(in:)` 那边完全不知道张数，
//  于是Mac 的渲染与 iOS 的行高量算又分叉（「量的时候按 A、布局按 B」那个老坑）。
//
//  ## ⚠️ 放不下就**横向滚**，绝不换行、绝不压缩
//
//  用户一次最多能发几张图没有硬上限（`ComposerAttachmentPicker` 只挑不计数），
//  而格子宽固定 ⇒ 放不下必须能滚。压缩格子会立刻破坏上面那条「每格同大小」。
//  ⚠️ `showsIndicators: false` 与助手侧同款：macOS 的 overlay 指示器本来也只在滚动时出现，
//  常驻一条细线在这个高度里太显眼。
//  ⚠️ **可发现性靠「露出半格」**：容器宽不会正好是格宽整数倍，右边那半格就是暗示。
//  ⛔ 别加箭头 / 渐隐遮罩 —— 那一层要么盖住格子、要么要额外追踪偏移。
//
//  ## ⚠️ 离屏验收台：`ScrollView(.horizontal, …)` 必须同步渲染脚本
//
//  与 `MediaThumbStrip` 同一条约束（那里有完整说明）：`render_mac_ui.sh` 会把它机械替换成
//  `Group {`，不同步的话验收图里这一条**永远是空的**（`ImageRenderer` 不渲染 ScrollView 内容），
//  而「空」与「这一条高度塌了」在图上长得一模一样 ⇒ 极易误判成布局 bug。
//  ⚠️ 改本文件的调用形状时，`render_mac_ui.sh` 里那条锚点的 `assert` 也要跟着改。
//

import SwiftUI
import AppKit
import AICore

/// 用户一次发送里的**多张图横排一条**。单张也走它（≥1 成组），
/// 这样「一张」与「多张」共用同一条渲染路径，不存在第二套尺寸口径。
struct UserImageStrip: View {

    /// 同一次发送里的用户图片行（按发送顺序）。每行都是 `.image` 且 `role == .user`。
    let rows: [AIChatRow]

    /// 滚动区容器宽（由 `ChatDetailView` 的 GeometryReader 传入）。
    /// ⚠️ 只用于「透传给共享层那个尺寸函数」，⛔ 本视图**不**拿它自己算格子宽
    /// （理由见文件头「格子尺寸仍然走共享层那一个函数」）。
    let containerWidth: CGFloat

    /// 点某一格 → 开预览窗口（`MediaPreviewWindowCenter`）。
    /// ⚠️ 带默认值 `nil`：渲染台那些「只验长相」的板不必为它改一行（与 `MediaThumbStrip` 同款）。
    var onOpen: ((MediaPreviewItem) -> Void)? = nil

    var body: some View {
        Group {
            if overflows {
                // 放不下 ⇒ 横向滚。⚠️ 此时内容本来就撑满视口宽，贴不贴右已无意义
                //（ScrollView 是贪宽的，它的**内容**默认从左缘开始）。
                scroller
            } else {
                // 放得下 ⇒ **不套ScrollView**，直接右对齐。
                //
                // 🔴 为什么不能「永远套 ScrollView +内容 `.frame(maxWidth:.infinity,
                //    alignment:.trailing)`」那一招：横向 ScrollView 对内容是**无界提议**
                //    ⇒ 那个 `.infinity` 永远等于内容宽，alignment 是**空操作**，条会贴在左边。
                //    而用户消息整体是**贴右**的（`ChatRowView` 的 `.frame(maxWidth:.infinity,
                //    alignment: .trailing)`）⇒ 图贴左、字贴右，同一条消息里自相矛盾。
                //    这个分支是「算得出来」的（`overflows` 是纯函数），所以不丢功能。
                cells
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        // 高度在外面写死：里面滚不滚、有几格，都不改变这一条占的高度。
        .frame(height: maxCellHeight, alignment: .bottom)
    }

    /// 横向滚动容器。⚠️ `ScrollView(.horizontal, …)` 这个**带参数的形状**离屏渲染台
    /// 不认（`ImageRenderer` 不渲染 ScrollView 内容）⇒ `render_mac_ui.sh` 里有对应的替换补丁。
    private var scroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            cells
        }
    }

    /// 一行格子。底边齐平（`alignment: .bottom`）—— 竖图高、横图矮，底边齐平才像桌上摆一排照片。
    private var cells: some View {
        // ⚠️ 用 `HStack` 不用 `LazyHStack`：渲染台里 `Lazy` 那族**不 materialize**
        //    （`ImageRenderer` 只做一次同步布局），换成懒加载等于让这一条在离屏验收里
        //    永远空着。与 `MediaThumbStrip` 同一条理由。
        HStack(alignment: .bottom, spacing: MacTheme.userImageSpacing) {
            ForEach(rows) { row in
                cell(row)
            }
        }
    }

    /// 内容总宽（各格宽 + 格间距）。**纯函数** ⇒ 视图里随时能重算，不存 `@State`。
    private var contentWidth: CGFloat {
        Self.contentWidth(rows: rows, containerWidth: containerWidth)
    }

    /// 内容总宽的**单点实现**（各格宽 + 格间距）。
    ///
    /// ⚠️ 刻意做成 `static`：宿主（`ChatDetailView.userImagesItem`）要用它算出
    /// 「这一条实际占多宽」，才能把**整条（含下面的操作栏）**的宽度钉住 ——
    /// 那样 `onHover` 的命中区才等于内容宽，而不是横贯全宽（理由见那边注释）。
    /// 两处各算一遍必然漂（改了一处忘了另一处 ⇒ 命中区与画出来的对不上）。
    static func contentWidth(rows: [AIChatRow], containerWidth: CGFloat) -> CGFloat {
        let widths = rows.map {
            AIChatRow.userImageDisplaySize(in: containerWidth,
                                           mediaSize: $0.block.mediaSize,
                                           scale: MacTheme.userImageScale).width
        }
        guard !widths.isEmpty else { return 0 }
        return widths.reduce(0, +) + MacTheme.userImageSpacing * CGFloat(widths.count - 1)
    }

    /// 这一条在界面上**实际占多宽** = `min(内容宽, 容器宽)`。
    ///
    /// 📌 放不下时是 `containerWidth`（横向滚动条本身就撑满那一段），
    /// 所以这一项**恒 ≤ `containerWidth`** ⇒ 宿主可以放心拿它当宽度上限。
    static func occupiedWidth(rows: [AIChatRow], containerWidth: CGFloat) -> CGFloat {
        min(contentWidth(rows: rows, containerWidth: containerWidth), containerWidth)
    }

    /// 放不下吗（⇒ 该横向滚了）。
    ///
    /// ⚠️ 判据用 `containerWidth` —— 那就是横排真正能占的宽（`ChatDetailView` 的
    /// GeometryReader 传进来的滚动区宽度），⛔ 别拿 `UIScreen` / `NSScreen` 的宽来比：
    /// 那个数在50/50 分栏下比真实容器宽大得多 ⇒ 永远判「放得下」⇒ 第 7 张图开始被裁掉。
    private var overflows: Bool { contentWidth > containerWidth }

    // MARK: - 一格

    @ViewBuilder
    private func cell(_ row: AIChatRow) -> some View {
        Group {
            if let url = row.block.imageURL {
                RowMediaImage(url: url,
                              layout: .fixed(size(of: row), contentMode: .fit),
                              cornerRadius: MacTheme.bubbleRadius)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen?(.image(url)) }
                    .help(L("点开查看大图"))
            } else {
                placeholder(width: size(of: row).width)
            }
        }
        // 固定每格的**高**（上面那格按比例算出来的），底边因此齐平。
        // ⚠️ 只固定高、不固定宽 —— 宽度必须由 `size(of:)` 按各自比例给（竖图窄、横图宽）。
        .frame(height: size(of: row).height, alignment: .bottom)
    }

    // MARK: - 尺寸（转发共享层唯一真值）

    /// 这一格显示多大 —— **共享层那个函数的原样转发**。
    ///
    /// ⚠️ `scale` 传 `MacTheme.userImageScale`（与 `ChatRowView.userImageBlock` 同一个常数）
    /// ⇒ 「单张发」与「多张发」的每格大小**逐像素相同**。
    /// ⛔ 别在这里传 1，也别按张数摊宽度。
    private func size(of row: AIChatRow) -> CGSize {
        AIChatRow.userImageDisplaySize(in: containerWidth,
                                       mediaSize: row.block.mediaSize,
                                       scale: MacTheme.userImageScale)
    }

    /// 组内最高那一格的高度（这一条占多高由它决定）。
    private var maxCellHeight: CGFloat {
        rows.map { size(of: $0).height }.max() ?? 0
    }

    // MARK: - 占位

    /// 「图片不可用」。🔴 **必须也走 `size(of:)`** —— 与 `ChatRowView` 里那条同源：
    /// 真实图缩了而占位还是满宽的话，加载失败瞬间整行会「跳一下」。
    private func placeholder(width: CGFloat) -> some View {
        ZStack {
            MacTheme.cardBackground
            Text(L("图片不可用"))
                .font(MacTheme.notice)
                .foregroundStyle(MacTheme.meta)
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: MacTheme.bubbleRadius))
        .overlay(
            RoundedRectangle(cornerRadius: MacTheme.bubbleRadius)
                .stroke(MacTheme.cardBorder, lineWidth: 1)
        )
    }
}