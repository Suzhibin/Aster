//
//  MediaThumbStrip.swift
//  AsterMac
//
//  会话里 AI 回复的**媒体缩略图条**：一条**横向滚动**的**竖版**格子（图片 / 视频封面）。
//  2026-09-28 用户要求（三轮）：「图片和视频可能会多个 ⇒ 图片应在一个 cell 横向多个显示」
//  ＋「图片显示应该是**竖着的** 16:9」＋「**图片和视频不能在一个 cell**」。
//
//      ┌────┐ ┌────┐ ┌────┐ ┌────┈┈
//      │图1 │ │图2 │ │图3 │ │图4      ← 竖版 108×192（宽:高 = 9:16），放不下就横向滚
//      └────┘ └────┘ └────┘ └────┈┈     图片一条、视频另一条，两条之间不混
//
//  ## 🔴 为什么要有「分组」这一层（数据层与界面层不是一回事）
//
//  数据层是**一块一行**：用户一次发 3 张图 ⇒ 3 个 `.image` 行；助手侧更直白 ——
//  流事件 `.image(url)` / `.video(url:cover:)` **每来一个就 append 一行**
//  （`AIChatManager.handle(_:)`）。所以「多张图」在容器里本来就是**多行**。
//
//  界面要的是「多张图排一条」⇒ 中间必须有一次**投影**。
//  🔴 **判据已下沉到业务层**（2026-09-28：`AICore/AIChatMediaGrouping.swift`），
//    因为 iOS 也要了同一件事（用户原话：「我看了 iOS 端图片，也要改 图片数据竖着显示
//    横向滑动效果」）—— 两个平台各写一份判据必然漂移（症状：同一段回复，
//    手机上图片和视频挤一条、Mac 上分两条，而且很难联想到是这个原因）。
//    本文件的 `ChatTranscriptItem.group` 只是**用它**，不再自带判据。
//  - **Mac（本文件）**：数据源换成「显示项」（`.row` / `.media`）—— SwiftUI 的高度由内容
//    决定，改数据源没有额外代价；
//  - **iOS**（`AIModuleViewController+Table`）：数据源**不动**（`indexPath.row` 仍是行号），
//    改成「**组首**那一行的 cell 渲染整条、组内其余行**行高归零**」
//    （`AIChatManager.normalizeMediaGroupHeights()`）—— 为的是不引入
//    「显示项 ↔ 行」的映射层（多选删除 / 搜索定位 / TTS / 编辑态全靠行号，那是本工程
//    最容易出错的一层）；代价是组内第 2..N 张点不到 ⇒ 选择模式下整组一起删。
//  - **落库与发给模型那一路完全没动**：`ai_message` 仍是「一行一块」的物理结构，
//    `contextMessages()` 与多模态数组都不受影响（图变多只是**行变多**，不是结构变）。
//  ⛔ 别去业务层加一个 `.imageGroup` block —— 那才会动到落库结构与数据库读回。
//
//  ## 🔴 分组键 = 「助手 + 媒体 + **同一种 media kind**」（2026-09-28 二轮）
//
//  用户原话：「**图片和视频不能在一个 cell**」。所以连续的两行只有 **kind 相同**时才并成一条：
//  图片一条、视频另一条 —— `图,图,视频,图` ⇒ **三条**（图×2 / 视频×1 / 图×1）。
//  - 为什么必须这样分：两种格的**长相与动作完全不同**（视频格压着颗播放标记、点开是播放器；
//    图片格点开是看图），混在一条里时「这一排到底几张图」在图上根本数不清 ——
//    验收图（`pane_media`）上表现为「一个奇怪的格子混在图里」。
//  - ⚠️ 分组**只看 kind**，不看 URL、不看是否同一轮（`isFirstBlockOfTurn`）——
//    「一轮回复里先给三张图、再给一个视频」是最常见的真实形状，而它应当是 **2 条**，
//    不是 1 条，也不是 4 条。
//  - ⚠️ 组与组之间**各自一条**：不跨组拼接、也不做「同一轮的图片都收上来」那种跨行重排 ——
//    那会把「行序 = 消息序」这条前提打破（`scrollTo(首行 id)` 的定位会跟着漂）。
//
//  ## 尺寸口径（用户 2026-09-28 二轮校正：**竖版 16:9 + 统一裁切**）
//
//  每一格都是 `MacTheme.mediaThumbWidth × mediaThumbHeight` = **108 × 192** 的竖框
//  （宽:高 = 9:16），图片 `.fill`（裁）。
//  - 🔴 「竖着的 16:9」= 把 16:9 那个框**竖过来** ⇒ 宽:高 = 9:16，**不是** 16:9 的横框。
//  - ✅ 好处：**零跳动** —— 不需要先量图片天然尺寸（助手侧图片只有 URL，本来量不到），
//    也就没有「先按固定比例占位、量到再改高」那一次列表抖动；
//  - ☠️ 代价（用户已知情并选择）：**横图左右被裁** —— 1080×810 的横图在竖格里只看到
//    中间约 42% 宽（`.fill` 居中）。要改成「按自身比例」，改 `layout:` 这一处 + 行高口径即可。
//  - 🔴 格子尺寸**与容器宽无关**（固定值）⇒ 窗口变宽时格子不变、只是**多露出几格**。
//    这与行内旧口径（`0.62 × 容器宽`）是两回事：那个会随窗口宽度变化，一拖窗口
//    每个格子的 `pixel` 都在变 ⇒ 每格都重解码一次（`RowMediaImage` 的 `.task(id: pixel)`）。
//
//  ## 单行横向滚动（用户选定）
//
//  - 永远只有一行，放不下就横向滚；**不换行、不网格**；
//  - 高度恒为 `mediaThumbHeight` ⇒ 行高与「几张图」无关，列表不会因为图片多寡而变。
//  - ⚠️ 可发现性靠**露出半格**：容器宽不会正好是格宽整数倍，右边那半格就是
//    「还能往右滑」的暗示。⛔ 别去加箭头/渐隐遮罩 —— 那一层会跟着滚动内容走，
//    要么盖住格子、要么需要额外追踪偏移（得不偿失）。
//  - ⚠️ `showsIndicators: false`：macOS 的 overlay 指示器本来也只在滚动时出现，
//    常驻一条细线在这个高度（144pt）里很显眼。触控板横向滑动是主要操作方式。
//
//  ## ☠️ 验收台：这条 ScrollView **必须同步脚本里的替换规则**
//
//  `render_mac_ui.sh` 会把工程源码里的 `ScrollView {` 机械替换成 `Group {`
//  （`ImageRenderer` 画不出 ScrollView 的内容，不替换的话整条**永远是空的**）。
//  本文件用的是 `ScrollView(.horizontal, showsIndicators: false) {` —— **带参数**，
//  老那条 `replace('ScrollView {', …)` **匹配不到** ⇒ 脚本里为它单加了一条补丁
//  （同一个 python 段里，改本文件时那两条 `assert` 的锚点也要跟着改）。
//  ⇒ 验收图里看到的是「**平铺展开**」：验得了格子长什么样、间距、裁切、播放标记，
//     验不了「滚不滚得动」（那只能真机滚一次）。
//  ⛔ 新增任何 `ScrollView` 都要先问一句「渲染台认不认得它」。
//

import SwiftUI
import AppKit
import AICore

// MARK: - 显示项投影（模型 → 界面）

/// 消息列表的一个**显示项**：要么是原来的一行，要么是「一组连续的助手媒体行」。
///
/// 它只活在 `ChatDetailView` 的渲染里 —— 不落库、不进业务层（理由见文件头）。
/// ⚠️ `id` 取**组内首行**的 id：`scrollTo` 找的是 `.id()` 锚点，用首行 id 才能让
///    「按行定位」这类既有逻辑（搜索定位 / 编辑态滚动）至少仍然指向**同一个位置**。
enum ChatTranscriptItem: Identifiable {

    case row(AIChatRow, index: Int)
    /// 一组连续的助手媒体行，**组内 kind 完全相同**（要么全是图片，要么全是视频）。
    /// `index` = 组内**首行**在 `rows` 里的下标。
    case media(rows: [AIChatRow], index: Int)
    /// **同一次发送里的连续用户图片行**（2026-10-08 用户要求「Mac 端发送一条消息内含多个
    /// 图片，要横排显示」⇒ 合成一条横排的 `UserImageStrip`）。
    ///
    /// ⚠️ **判据与助手侧是两个函数**（`AIChatMediaGrouping.isUserImage` /
    /// `userImageGroupRange`）：⛔ 别为了「统一」把用户图并进 `AIChatMediaGrouping.kind(of:)` ——
    /// iOS 的「组首渲染整条、其余行高归 0」正是拿 `kind(of:)` 当判据，用户图一旦进去，
    /// iOS 上第 2..N 张会**行高归 0 直接消失**。iOS 至今仍是「一图一行」，那是产品口径。
    case userImages(rows: [AIChatRow], index: Int)

    /// ⚠️ 标 `nonisolated`：`Identifiable` 的 `id` 是**非隔离**要求，而本 App target 开了
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`（类型默认 MainActor 隔离）——
    /// 不标的话编译器会报「main actor-isolated property 不能满足 nonisolated 协议要求」。
    nonisolated var id: UUID {
        switch self {
        case .row(let row, _):            return row.id
        case .media(let rows, _):         return rows[0].id
        case .userImages(let rows, _):    return rows[0].id
        }
    }

    /// 媒体组的 kind（图片 / 视频）。非媒体项 ⇒ `nil`。
    /// ⚠️ 只用于断言与验收台打印（组内 kind 一致是 `group` 的不变量）——
    /// ⛔ **别拿它去分叉渲染**：格子长相由 `MediaThumbStrip` 按**每一行**自己的 kind 决定。
    nonisolated var mediaKind: AIBlockKind? {
        guard case .media(let rows, _) = self else { return nil }
        return rows.first?.block.kind
    }

    /// 把「一行一块」的行数组投影成「一行一项」的显示数组。
    ///
    /// 规则（**三段，顺序不能换**）：
    /// ① **连续的助手媒体行、且 kind 相同 ⇒ 合成一组**（≥1 也成组 —— 单张也走同一条
    ///    渲染路径，免得好不容易对齐的口径又长出「单张用 A、多张用 B」两个分支）。
    ///    🔴 「kind 相同」这一条是 2026-09-28 二轮新加的（用户：**图片和视频不能在一个 cell**）：
    ///    `图,图,视频,图` ⇒ 三条；⛔ 别退化成「只看是不是媒体」——那会让图片与视频挤进同一条。
    /// ② **同一次发送里的连续用户图片行 ⇒ 合成一条**（2026-10-08；用户要求横排）。
    ///    判据走 `AIChatMediaGrouping.userImageGroupRange`（共享层单点，**只有 Mac 消费**）。
    /// ③ 其余 ⇒ 一行一项。
    nonisolated static func group(_ rows: [AIChatRow]) -> [ChatTranscriptItem] {
        var items: [ChatTranscriptItem] = []
        items.reserveCapacity(rows.count)
        var index = 0
        while index < rows.count {
            // 🔴 判据一律走**共享层**（iOS 的表格用的是同一份）。
            // ⛔ 别在这里自己比 `role` / `block.kind` —— 那正是两份判据漂移的起点。
            if let kind = AIChatMediaGrouping.kind(of: rows[index]) {
                var last = index
                while last + 1 < rows.count, AIChatMediaGrouping.kind(of: rows[last + 1]) == kind { last += 1 }
                items.append(.media(rows: Array(rows[index...last]), index: index))
                index = last + 1
                continue
            }
            if let range = AIChatMediaGrouping.userImageGroupRange(rows, at: index) {
                items.append(.userImages(rows: Array(rows[range]), index: range.lowerBound))
                index = range.upperBound
                continue
            }
            items.append(.row(rows[index], index: index))
            index += 1
        }
        return items
    }
}

// MARK: - 缩略图条

/// 一条横向滚动的媒体缩略图。**单张也用它**（用户选「单张跟组内一样大」）
/// —— 这样「一张」与「多张」共用同一条路径，不存在第二套尺寸口径。
struct MediaThumbStrip: View {

    /// 组内的行（按时间顺序）。每行是 `.image` 或 `.video`。
    let rows: [AIChatRow]

    /// 点某一格 → 开预览窗口（`MediaPreviewWindowCenter`）。
    /// ⚠️ 带默认值 `nil`：渲染台那些「只验长相」的板不必为它改一行
    /// （与 `ChatRowView.onOpenMedia` 同一条口径）。
    var onOpen: ((MediaPreviewItem) -> Void)? = nil

    private var cellSize: CGSize {
        CGSize(width: MacTheme.mediaThumbWidth, height: MacTheme.mediaThumbHeight)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: MacTheme.mediaThumbSpacing) {
                // ⚠️ 用 `HStack` 不用 `LazyHStack`：渲染台里 `Lazy` 那族**不 materialize**
                //    （`ImageRenderer` 只做一次同步布局），换成懒加载等于让这条在离屏验收里
                //    永远空着。图片条一屏也就几格，不值得为那点内存换掉验收能力。
                ForEach(rows) { row in
                    cell(row)
                }
            }
        }
        // 高度写死在外面：里面滚不滚、有几格，都不会改变这一条占的高度。
        .frame(height: MacTheme.mediaThumbHeight)
    }

    // MARK: 一格

    @ViewBuilder
    private func cell(_ row: AIChatRow) -> some View {
        ZStack {
            switch row.block.kind {
            case .video:
                videoFace(row)
            default:
                imageFace(row)
            }
        }
        .frame(width: cellSize.width, height: cellSize.height)
        .clipShape(RoundedRectangle(cornerRadius: MacTheme.mediaThumbCorner))
        // 整格可点（与行内视频块同一条：命中区是整格，不是那颗播放图标）
        .contentShape(RoundedRectangle(cornerRadius: MacTheme.mediaThumbCorner))
        .onTapGesture { if let item = previewItem(row) { onOpen?(item) } }
        .help(helpText(row))
    }

    @ViewBuilder
    private func imageFace(_ row: AIChatRow) -> some View {
        if let url = row.block.imageURL {
            RowMediaImage(url: url,
                          layout: .fixed(cellSize, contentMode: .fill),
                          cornerRadius: MacTheme.mediaThumbCorner)
        } else {
            unavailableFace
        }
    }

    @ViewBuilder
    private func videoFace(_ row: AIChatRow) -> some View {
        // Mac 端**不在这里放播放器**（与既有口径一致）：列表里塞 `AVPlayer` 会让
        // 每一格都持有一个播放器（滚动即建即销），而且行高会被播放器的最小高度带偏。
        // 播放发生在预览窗口里（`MediaPreviewWindow`）。这一格只做「封面 + 这里能播」。
        if let cover = row.block.videoCoverURL {
            RowMediaImage(url: cover,
                          layout: .fixed(cellSize, contentMode: .fill),
                          cornerRadius: MacTheme.mediaThumbCorner)
        } else {
            MacTheme.cardBackground
        }
        Image(systemName: "play.circle.fill")
            .font(MacTheme.ui(MacTheme.mediaThumbPlayIconSize))
            .foregroundStyle(.white.opacity(0.92))
            // ☠️ 阴影不是装饰：封面可能是**亮色**（本工程的夹具就是渐变紫，真实素材里白底截图更多），
            //    纯白图标压在亮底上会看不见。系统图标的 `shadow` 与 `.fill` 一起用是标准做法。
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }

    private var unavailableFace: some View {
        ZStack {
            MacTheme.cardBackground
            Text(L("媒体不可用"))
                .font(MacTheme.notice)
                .foregroundStyle(MacTheme.meta)
        }
    }

    // MARK: 回调与文案

    private func previewItem(_ row: AIChatRow) -> MediaPreviewItem? {
        switch row.block.kind {
        case .image: return row.block.imageURL.map(MediaPreviewItem.image)
        case .video: return row.block.videoURL.map { .video(url: $0, cover: row.block.videoCoverURL) }
        default:     return nil
        }
    }

    /// 文案取 `AIRowAction` 那一套吗？**不取** —— 那是「对消息能做的操作」（操作栏 / 右键菜单共用），
    /// 而「点开看大图」是媒体格自己的天然手势（与行内媒体块同一条口径）。
    private func helpText(_ row: AIChatRow) -> String {
        switch row.block.kind {
        case .video: return row.block.videoURL == nil ? L("视频不可用") : L("点开播放")
        case .image: return row.block.imageURL == nil ? L("媒体不可用") : L("点开查看大图")
        default:     return L("媒体不可用")
        }
    }
}
