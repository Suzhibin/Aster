//
//  MediaPreviewOverlay.swift
//  AsterMac
//
//  点会话里的**图片 / 视频封面** → 媒体预览（2026-09-27 加）。
//  样式照用户给的**豆包 Mac 版**截图定：
//
//      ┌──────────────────────────────────────────────┐
//      │  ⊖  ⊕  ↻  ⤓                            ✕     │ ← 内容区顶栏：**只有浮层形态**才画
//      │                                              │
//      │                ┌────────────┐                │
//      │                │   图 / 视频  │                │ ← 按自身比例居中，四周留白
//      │                └────────────┘                │
//      │  🌐 news.newsweek…                            │ ← 左下角来源小胶囊
//      └──────────────────────────────────────────────┘
//
//  ## 🔴 它现在住在一个**独立窗口**里（2026-09-27 改）
//  第一版是直接 `.overlay` 在 `ChatDetailView` 上的**整页浮层**；用户要求改成新开窗口。
//  本文件**只负责长相**，开窗那一套在 `MediaPreviewWindow.swift`。
//
//  ## 🔴 四颗按钮已经搬到窗口**标题栏**上（2026-09-28 用户要求「放在交通灯旁边」；
//  2026-10-09 加了第四颗「旋转」：缩小 / 放大 / **旋转** / 另存为）
//  ⇒ 窗口形态**不再画内容区顶栏**（`showsToolbar: false`）：两边都画就是同一批按钮出现两次。
//  装进标题栏那一套（`NSTitlebarAccessoryViewController` + `.left` + `NSHostingView`）写在
//  `MediaPreviewWindow.swift`；按钮那一排自己的长相见下面 `MediaPreviewTitlebarToolbar`。
//  ⚠️ 于是「按钮长什么样」有两张离屏验收图（内容区版 `mediapreview_image` / 标题栏版
//     `mediapreview_titlebar`）+ 一张**真窗口截图**（`render_mac_ui.sh preview`）。
//     三者缺一不可：前两张验按钮本身，第三张验它在交通灯旁边的**位置** ——
//     标题栏是窗口画的，离屏图里只有一块面色，画不出红绿灯，也画不出「贴得够不够近」。
//
//  形态差异全部收成**参数**（默认值 = 浮层时代的行为）：
//  | 参数 | 浮层（`ChatDetailView`，已不用） | 独立窗口（现在的用法） |
//  |---|---|---|
//  | `showsToolbar` | `true` —— 内容区顶栏：靠左**四颗** + **靠右一颗 ✕** | `false` —— 顶栏整条不画（四颗在标题栏上） |
//  | `closesOnBackdropTap` | `true` —— 点图以外的任何地方关掉 | `false` —— 独立窗口误关代价大，只留红绿灯 / ⌘W / Esc |
//
//  ⛔ 别把这两个参数删了「只留窗口那一套」：浮层那几张验收图是**参数化之前**的行为基准，
//     而且「有顶栏 / 没顶栏」两种**内容区尺寸口径**（`contentArea` 要不要扣掉那条高度）
//     只有把两态都留着才对得上账。
//
//  ## 🔴 缩放 / 旋转 / 另存为的状态是**跨层级共享**的（`MediaPreviewModel`）
//  这一组东西现在被两处 UI 驱动：**标题栏那四颗**（住在另一个 `NSHostingView` 里）
//  与**内容区**（按档位缩放、在左下角飘结果提示）。两处若各持一份 `@State`，
//  症状是「点标题栏的放大，图片不动」。
//  ⇒ 状态提到 `MediaPreviewModel`，窗口造**一个**同时喂给两处；离屏验收板自己造一个。
//  ⚠️ 与 `MediaPreviewPlaybackHandle` 同一类东西：**跨「窗口 ↔ 内容」的把手**。
//
//  ## 🔴 底色走**语义色**，不做「固定深色遮罩」
//  参考图那张是**浅色底**，而且它跟随系统外观（豆包自己的窗口底色也是白的）。
//  本仓库的颜色口径就是语义色（见 `MacTheme` 文件头：助手行连气泡底都不画，背景 = 页面背景），
//  固定深色会在浅色模式下变成「整页被一块黑糊住」。
//  ⚠️ 别拿录音板那组（固定深色 HUD）来类比 —— 那是底部一小块浮层，方向正好相反。
//
//  ## 内容为什么**不裁切**（与行内刻意不同的第二个口径）
//  行内（`ChatRowView`）是「16:9 固定框 + 视频封面 `.fill`」，与 iOS 同源，**别动**。
//  浮层是「把这张图看全」，所以走 `RowMediaImage` 的 `.fitIn`：按图片自身比例缩放到
//  不超过盒子、四周留白 —— 参考图里那张照片也是完整的、有留白的。
//
//  ## 三个坑
//  ① ☠️ `AVPlayer` **不能**写成 `@State private var player = AVPlayer()`：属性默认值的
//     求值**早于 `init()`**（本仓库在 `ChatModel` 上踩过同一条），而且它得按「这次要看哪个
//     视频」来建。⇒ `@State private var player: AVPlayer?` + `.onAppear` 里造。
//  ② ⚠️ **视频那一支在离屏渲染里画不出来** —— 2026-09-27 实测，顺带**修正了旧说法**：
//     `ImageRenderer` 里 **`.onAppear` 是会跑**的，而且是**同步**跑在抓图之前
//     ⇒ `player` 不是 nil、走的就是 `MacVideoPlayer` 那一支。而 `NSViewRepresentable`
//     在离屏只有 SwiftUI 的「**黄条 + ⊘**」标准画法（与 `TextField` / `Menu` 同一类）
//     ⇒ 验收图 `mediapreview_video` 中间那条黄带**不是渲染失败**。
//     能验的只有外圈那一套（按钮 / 来源胶囊 / 底板 / 内容尺寸）；「真能播」只能真机。
//     ℹ️ 下面 `posterURL` 那一支（player 还是 nil 时先画封面）是给**真机首帧**用的：
//     SwiftUI 先渲染一帧、`.onAppear` 之后才跑，那一帧不该是空的。
//     ⚠️ 旧手册说的「`.task` 不跑」**也不准**：实测 `.onAppear` 与 `.task` **都会触发**，
//     区别是 `.task` 异步 —— 它跑完时图早就抓完了。完整探针见 `VERIFY-PROBES.md`。
//  ③ 缩放是**纯视图状态**（`zoomIndex`）：盒子变大 ⇒ `RowMediaImage` 的 `pixel` 跟着变大
//     ⇒ `.task(id: pixel)` 按新档重取一份更高分辨率的图（放大后不糊）。
//     这就是「画多大就解多大」在本文件的落点；也是**不给缩放加动画**的原因（见 `MacTheme`）。
//
//  ## 🔴 视频用 `AVPlayerView`（AppKit）而**不是** SwiftUI 的 `VideoPlayer`（2026-09-27 实测）
//
//  一句话：**SwiftUI `VideoPlayer` 会让链接器把 `AVKit.framework` 整个剥掉，建类元数据时当场 abort。**
//
//  取证（最小复现 + 崩溃报告）：
//  - 崩溃报告主线程栈：`_AVKit_SwiftUI → _swift_initClassMetadataImpl → getSuperclassMetadata
//    → swift::fatalError → abort`，退出码 **134**，而且**没有任何文字输出**；
//    伴随启动时那句 `failed to demangle superclass of VideoPlayerView from mangled name
//    'So12AVPlayerViewC'`（`So…C` = ObjC 类 `AVPlayerView`）。
//  - `otool -L`：出事的二进制里**只有 `_AVKit_SwiftUI.framework`、没有 `AVKit.framework`**。
//    而 `_AVKit_SwiftUI` 自己不依赖 AVKit（`otool -L` 查过，一个都没有）。
//  - 成因：`import AVKit` 自动链**确实**带了 `-framework AVKit`（`otool -l` 看 `LC_LINKER_OPTION`
//    里有），但 `VideoPlayer` 引用 `AVPlayerView` 是**运行期按 mangled name 查**的 ——
//    链接期看不到任何 AVKit 符号 ⇒ 链接器把它当**无用依赖剥掉**。
//  - 对照实验（同一个 SDK / 工具链，默认链接参数）：
//      `use VideoPlayer`              → LC 里 AVKit **0** 个 → abort(134)
//      同代码 + 命令行显式 `-framework AVKit` → LC 里 AVKit 1 个 → 正常
//      `AVPlayerView` + `NSViewRepresentable` → LC 里 AVKit **1** 个 → 正常（静态类符号）
//
//  ⇒ 本文件用后者。**别改回 `VideoPlayer`**，除非同时给**两个**构建路径显式加 AVKit：
//  渲染台 `render_mac_ui.sh` 的链接行 + Mac target 的 `OTHER_LDFLAGS`（两处 config）——
//  而那是本仓库标红的改动区，为「少写 20 行」不值得。
//  ✅ 顺带与 iOS 侧同口径：那边也是直接用 AVKit 的 **ObjC 视图控制器**（`AVPlayerViewController`），
//    不是 SwiftUI 包装。
//
//  ## 「另存为」为什么弹面板、为什么落盘写在业务层
//  用户在两个选项里选了「另存为」（`NSSavePanel`），不是「直存下载文件夹」。两件事：
//  - 面板给的目标 URL 要能**写** ⇒ Mac target 的 `ENABLE_USER_SELECTED_FILES` 本轮从
//    `readonly` 升成 `readwrite`（两个 config 各一个词）。沙盒里没有这个权限时，
//    面板照弹、写入**静默失败** —— 所以下面那句「保存失败」不是装饰，是唯一的信号。
//  - 真正落盘的一步在业务层 `AIAttachmentStorage.export(from:to:)`：
//    视图层只负责「弹面板拿 URL」，⛔ 别在视图里写文件（与附件落地同一条边界）。
//

import SwiftUI
import AppKit
import AVKit
import Observation
import UniformTypeIdentifiers
import AICore

// MARK: - 被预览的媒体

/// 浮层要显示的东西。**只带 URL，不带 `AIChatRow`** ——
/// 浮层不该知道「这条消息长什么样」，那会让它跟着业务模型一起漂。
enum MediaPreviewItem: Identifiable {
    case image(URL)
    case video(url: URL, cover: URL?)

    /// 稳定钥匙（同一张图/同一个视频可能在列表里出现多次，浮层需要能区分身份）。
    var id: String {
        switch self {
        case .image(let url):    return "image|\(url.absoluteString)"
        case .video(let url, _): return "video|\(url.absoluteString)"
        }
    }

    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }

    /// **内容本身**（图片文件 / 视频文件）—— 播放与「另存为」用的都是它
    var contentURL: URL {
        switch self {
        case .image(let url):    return url
        case .video(let url, _): return url
        }
    }

    /// 画出来的那一张。视频取**封面**（没有封面就只能画一块底 —— 去抓视频第 0 帧是异步的，
    /// 而本工程的 mock 视频**都带封面**，不值得为此铺一条链路）。
    var posterURL: URL? {
        switch self {
        case .image(let url):      return url
        case .video(_, let cover): return cover
        }
    }

    /// 左下角来源小胶囊上的字。
    /// - 远程：主机名（去掉 `www.`）—— 参考图那颗写的就是 `news.newsweek…`
    /// - 本地文件：文件名。⚠️ **别改成 nil**：离线验收图的夹具是本地文件，
    ///   给 nil 的话这颗胶囊在渲染台上永远看不见，等于没人验过它长什么样。
    var sourceLabel: String? {
        if contentURL.isFileURL {
            let name = contentURL.lastPathComponent
            return name.isEmpty ? nil : name
        }
        guard let host = contentURL.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// 「另存为」面板里的默认文件名。
    /// ⚠️ 远程图片的 URL 常常没有扩展名（mock 的 `…/1200/900`）⇒ 退回按类型取个默认名，
    /// 否则面板会给一个叫「900」的文件。
    var suggestedFileName: String {
        let name = contentURL.lastPathComponent
        return name.contains(".") ? name : (isVideo ? L("视频.mp4") : L("图片.png"))
    }

    /// 「另存为」面板限定扩展名。⚠️ 猜不出来就**不要限定**（返回空数组）——
    /// 塞一个错的扩展名会让面板把默认文件名改掉，比不限定更烦。
    var allowedContentTypes: [UTType] {
        guard !contentURL.pathExtension.isEmpty,
              let type = UTType(filenameExtension: contentURL.pathExtension) else { return [] }
        return [type]
    }

    /// 窗口的**身份名**（浮层模式不用它）。
    /// 口径与左下角那颗来源胶囊**同源**（`sourceLabel`）：远程是主机名、本地是文件名。
    /// ⚠️ 别在窗口那边另写一套（`MediaPreviewWindow.swift` 直接读这个）。
    ///
    /// 🔴 2026-10-09 起它**不再显示在标题栏上**（用户要求去掉标题，窗口那边
    /// `titleVisibility = .hidden`）—— 但**不能删**：它是 `window.title` 的值，
    /// 而「窗口」菜单 / ⌘` 切换 / 辅助功能都读那个。
    /// ⇒ 口径变成「**窗口身份用这一份，标题栏不画它**」，两件事刻意分开。
    var windowTitle: String {
        sourceLabel ?? (isVideo ? L("视频") : L("图片"))
    }
}

// MARK: - 共享状态（标题栏 ↔ 内容区）

/// 预览窗那一组的**共享状态**：缩放档位 + 「另存为」+ 结果提示。
///
/// 🔴 存在的唯一理由：这三样被**两处 UI** 驱动，而它们是两个独立的 SwiftUI 层级
/// （标题栏那个 `NSHostingView` 与内容区那个，见文件头）：状态各持一份的话，
/// 点标题栏的「放大」内容区不会有反应。
/// ⚠️ 别把 `zoomIndex` 退回成 `MediaPreviewOverlay` 的 `@State` —— 那是搬按钮前的写法。
///
/// ☠️ `zoomIndex` 变了会让内容区**重新解码**（`RowMediaImage` 的 `.task(id: pixel)`），
///    所以缩放**刻意不给动画**（理由写在 `MacTheme.mediaPreviewZoomLevels`）。
///
/// ⚠️ 用 `@Observable`（`import Observation`）而**不是** Combine 的 `ObservableObject`：
///    本工程整套状态都是 Observation（见 `ChatModel`），而且 target 上开着
///    `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` ⇒ 用 `ObservableObject`/`@Published`
///    还得单独 `import Combine`（实测五段检查直接报 15 条 error）。
///    两处视图读它的属性时被 SwiftUI 自动追踪，不需要 `@Bindable`（只读不写）。
@MainActor
@Observable
final class MediaPreviewModel {

    let item: MediaPreviewItem

    /// 当前缩放档在 `MacTheme.mediaPreviewZoomLevels` 里的下标（1.0 = 适应窗口）。
    var zoomIndex = MacTheme.mediaPreviewZoomDefaultIndex

    /// 「另存为」的结果：成功 / 失败都飘一句（失败**必须**说出来 —— 沙盒拒写是静默的）。
    var notice: String?

    /// 🔴 旋转档位：**顺时针 90° 的次数**，取0/1/2/3（2026-10-09 加，用户要求「旋转图片按钮」）。
    ///
    /// ⚠️ 为什么存「转了几次」而不是存角度：角度只会是 0/90/180/270 四个值，
    ///    存次数才能自己在 `rotate()` 里取模循环（`% 4`），不用在渲染处写归一化。
    /// 🔴 **只对图片有效**（`canRotate`）—— 视频转 90° 没有意义，而且下面 `rotatedBox`
    ///    交换宽高那套算术是按「图片」推的，视频走它会拿到一个错的盒子。
    ///    ⛔ 别为了「让视频也能转」把它放开：真要做得给视频播放器套一层旋转视图，
    ///    那是另一条链路（且 `AVPlayerView` 转起来控制条会跟着歪）。
    var rotationQuarters = 0

    /// 能不能旋转（视频恒false ⇒ 那颗按钮置灰）。
    var canRotate: Bool { !item.isVideo }

    /// 顺时针再转 90°，四档循环（90→180→270→0）。
    ///
    /// ⚠️ 刻意**不给动画**：与缩放同一条理由（`MacTheme.mediaPreviewZoomLevels`）——
    ///    `.rotationEffect` 带动画会让图片在转的那一拍反复触发
    ///    `RowMediaImage` 的 `.task(id: pixel)` 重解码，闪一下。
    func rotate() {
        guard canRotate else { return }
        rotationQuarters = (rotationQuarters + 1) % 4
    }

    /// 旋转后的**朝向角**（度）。`0/90/180/270`。
    var rotationDegrees: Double { Double(rotationQuarters) * 90 }

    /// 🔴🔴 旋转 90/270 时**盒子宽高要互换**（2026-10-09，加旋转时踩出来的）。
    ///
    /// 原因：`.fitIn(box)` 的语义是「图片按自身比例缩到**不超过这个盒子**」。
    /// 而 `box` 来自窗口的宽高（横的）。一张竖图在横盒子里 fit 完是「竖着占中间」，
    /// 转 90° 之后它就变成了「横着占中间」—— 若**不**把盒子也转过来：
    /// -横图（1600×900）在 800×600 盒子里 fit 成 800×450，转 90° 后视觉占 450×800
    ///   ⇒ 上下超出盒子被裁掉（或被上下邻着的别的内容压住）；
    /// -正确做法是先把盒子转成 600×800，图片 fit 成 600×338，再转 90° ⇒ 视觉 338×600，
    ///   正好落在「上下留白、左右居中」的位置上。
    /// ⇒ **盒子必须与图片转到同一个朝向**，两者一起转，结果才与未旋转时同形。
    ///⚠️ 只在**奇数档**（90/270）交换 —— 180 与 0 同形。
    /// 📌 与 `scaledBox` 的顺序：先按本函数交换，再乘缩放档（`scaledBox` 里已经这么写）。
    ///    顺序反了会让放大后的盒子被交换错方向（放大档 >1 时看得出来）。
    func rotatedBox(_ box: CGSize) -> CGSize {
        rotationQuarters % 2 == 0 ? box : CGSize(width: box.height, height: box.width)
    }

    /// ⚠️ 标 `@ObservationIgnored`：它是内部收尾用的，不是 UI 状态
    ///    （让它参与观察只会白构建一次依赖）。
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(item: MediaPreviewItem) {
        self.item = item
    }

    var zoom: CGFloat { MacTheme.mediaPreviewZoomLevels[zoomIndex] }
    var canZoomOut: Bool { zoomIndex > 0 }
    var canZoomIn: Bool { zoomIndex < MacTheme.mediaPreviewZoomLevels.count - 1 }

    /// 档位步进（`±1`）。到边界就停住 —— 按钮同一刻会被置灰，所以这层夹取只是兜底。
    func step(_ delta: Int) {
        let next = min(max(zoomIndex + delta, 0), MacTheme.mediaPreviewZoomLevels.count - 1)
        guard next != zoomIndex else { return }
        zoomIndex = next
    }

    /// 弹「另存为」面板，然后**请业务层**落盘。
    ///
    /// ⚠️ 真正写文件在 `AIAttachmentStorage.export(from:to:)` —— 视图层只负责「弹面板拿 URL」
    ///    （与附件落地同一条边界，⛔ 别在视图里写文件）。
    /// ⚠️ 用 `runModal()` 而不是 `beginSheetModal`：这条路径从「内容区那个按钮」时代就是它，
    ///    行为（一个独立的模态面板）没变过。改 sheet 会让面板**挂在鼠标所在的那个窗口**上，
    ///    而这里有两个窗口（预览窗 + 会话窗），挂错窗口比不挂更怪。
    func saveAs() {
        let panel = NSSavePanel()
        panel.title = L("另存为")
        panel.nameFieldStringValue = item.suggestedFileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if !item.allowedContentTypes.isEmpty {
            panel.allowedContentTypes = item.allowedContentTypes
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        // 存盘是异步的（远程资源要先下字节）—— 结果**必须**说出来：
        // 沙盒里缺权限时写入是**静默失败**的，不提示用户会以为存好了。
        Task { @MainActor in
            let ok = await AIAttachmentStorage.export(from: item.contentURL, to: destination)
            show(notice: ok ? L("已保存") : L("保存失败"))
        }
    }

    /// 飘一句提示、2.2 秒后自动消失（连点两次以最后一次为准）。
    func show(notice text: String) {
        noticeTask?.cancel()
        notice = text
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}

// MARK: - 浮层

/// 媒体预览（一张图 / 一段视频）。**只负责长相**，装在哪由调用方定：
/// - 独立窗口 → `MediaPreviewWindowCenter`（现在的用法；三颗按钮在**标题栏**上）
/// - 整页浮层 → `ChatDetailView`（第一版的用法，参数默认值就是为它留的）
struct MediaPreviewOverlay: View {

    let item: MediaPreviewItem
    /// 关闭。四条路（点遮罩 / Esc / 内容区顶栏的 ✕ / 窗口红绿灯）最后都落到它。
    let onClose: () -> Void

    /// 缩放档位 + 另存为 + 结果提示。**同一份实例要给标题栏那一排按钮也喂一份** ——
    /// 否则「点标题栏的放大、图片不动」（见文件头那一节）。
    /// ⚠️ 只读不写 ⇒ 不用 `@Bindable`；`@Observable` 的属性在 `body` 里被读到就自动追踪。
    let model: MediaPreviewModel

    /// 内容区要不要画自己那一排按钮（窗口模式 `false`：三颗已经在标题栏上了，见文件头）。
    /// ⚠️ 它同时决定**内容区要不要给那一条让位**（`contentArea`）—— 不是纯装饰开关。
    var showsToolbar: Bool = true

    /// 点内容空白处要不要关（窗口模式 `false`：误关代价大，见文件头）。
    var closesOnBackdropTap: Bool = true

    /// 关窗时用来停播放的把手。**只有窗口模式传**（浮层模式传 `nil`：那边 `onDisappear` 靠得住）。
    /// ☠️ 为什么不靠「关窗时把 `contentView` 拆掉、逼 SwiftUI 跑 `onDisappear`」——
    ///    实测那会让**同进程里其它**预览窗口不再重绘，取证见 `MediaPreviewWindow.close()`。
    var playback: MediaPreviewPlaybackHandle? = nil

    @Environment(\.colorScheme) private var scheme
    /// ☠️ nil 起步，`.onAppear` 里造 —— 见文件头坑 ①
    @State private var player: AVPlayer?

    var body: some View {
        GeometryReader { geometry in
            let box = scaledBox(contentArea(in: geometry.size))
            ZStack {
                // 🔴 「点一下关掉」只挂在**遮罩本身**上，不挂整层：
                //    挂在 `ZStack` 上的话，点图片也关（看图时想放大却把图关了）。
                //    图片自己不带手势 ⇒ 命中它时事件不会回到遮罩这一层（兄弟节点不是祖先）。
                // ⚠️ 窗口模式关掉这条（`closesOnBackdropTap == false`）—— 见文件头口径 ②。
                MacTheme.mediaPreviewBackground
                    .onTapGesture { if closesOnBackdropTap { onClose() } }
                // 🔴 整块内容**上移半个胶囊条**（`mediaPreviewChipStripHeight / 2`）：
                //    盒子虽然抠掉了底部那条，但内容仍然是在**整页**里居中的
                //    （`ZStack` 居中，与那个盒子无关）⇒ 不上移的话图片会往下多伸半条，
                //    照样压到左下角那颗来源胶囊。
                //    等价说法：**图片在「胶囊之上那块区域」里居中**（算术见 `MacTheme` 那条）。
                content(box: box)
                    .offset(y: -MacTheme.mediaPreviewChipStripHeight / 2)
            }
            // ⚠️ 窗口模式这条整个不挂（`showsToolbar == false`）：三颗按钮在**标题栏**上。
            //    别改成「画成透明的」—— 那会白占一条高度，而且按钮还在（会不会被点到全看运气）。
            .overlay(alignment: .top) { if showsToolbar { toolbar } }
            .overlay(alignment: .bottomLeading) { bottomBar }
        }
        .onAppear { startVideoIfNeeded() }
        .onDisappear { stopVideo() }
    }

    // MARK: 内容

    @ViewBuilder
    private func content(box: CGSize) -> some View {
        if item.isVideo {
            video(box: box)
        } else if let poster = item.posterURL {
            // ⚠️ 圆角 0：参考图里那张照片是**直角**的（行内媒体块才是 14 圆角）
            //
            // 🔴 2026-10-09 加旋转：`.rotationEffect` **只挂这一支**。
            // ⛔ 别把它提到 `body` 的 ZStack 上——那会把视频播放器也转起来
            // （`AVPlayerView` 的控制条会跟着歪，见 `canRotate` 的注释）。
            // ⚠️ 盒子那边**已经**在 `scaledBox` 里交换过宽高了（`rotatedBox`），
            //    这里只需要把视图转过去 —— 两处**必须**都做、且都只对图片生效：
            //    只转视图不交换盒子 ⇒ 竖图转横后超出盒子（见 `rotatedBox` 的注释）。
            RowMediaImage(url: poster, layout: .fitIn(box), cornerRadius: 0)
                .rotationEffect(.degrees(model.rotationDegrees))
        } else {
            unavailable(icon: "video.slash")
        }
    }

    @ViewBuilder
    private func video(box: CGSize) -> some View {
        if let player {
            MacVideoPlayer(player: player)
                .frame(width: box.width, height: box.height)
        } else if let poster = item.posterURL {
            // 播放器还没起来时先画封面，**尺寸同框** ⇒ 起来的那一拍不会跳。
            // （离屏渲染恒定走这一支，所以媒体浮层的验收图看到的就是这个。）
            RowMediaImage(url: poster, layout: .fitIn(box), cornerRadius: 0)
        } else {
            unavailable(icon: "video.slash")
        }
    }

    private func unavailable(icon: String) -> some View {
        ZStack {
            MacTheme.cardBackground
            Image(systemName: icon)
                .font(MacTheme.ui(34))
                .foregroundStyle(MacTheme.meta)
        }
        .frame(width: 240, height: 135)
        .clipShape(RoundedRectangle(cornerRadius: MacTheme.bubbleRadius))
    }

    /// 内容可用区域：整页 − 四周留白 −（**画顶栏时**）那一行的高度 − 底部**来源胶囊那条**。
    /// ⚠️ 窗口形态没有内容区顶栏 ⇒ 那条高度**不扣**（`bar = 0`）。否则内容会平白缩掉
    ///    `mediaPreviewBarHeight` 且上方多一条空带 —— 这正是 `showsToolbar` 必须是参数、
    ///    而不是「只控制画不画」的原因。
    /// ⚠️ 底部那条**两种形态都扣**（胶囊在两种形态里都在左下角）。
    /// ⚠️ 下限 `mediaPreviewMinContentSide`：窗口拉到极窄时盒子不能变成 0（否则 `.fit` 会算除零，
    /// 且内容会缩成一个点）。
    private func contentArea(in size: CGSize) -> CGSize {
        let bar = showsToolbar ? MacTheme.mediaPreviewBarHeight : 0
        return CGSize(width: max(size.width - MacTheme.mediaPreviewPadding * 2,
                                 MacTheme.mediaPreviewMinContentSide),
                      height: max(size.height - MacTheme.mediaPreviewPadding * 2 - bar
                                      - MacTheme.mediaPreviewChipStripHeight,
                                  MacTheme.mediaPreviewMinContentSide))
    }

    /// 缩放：**缩放的是那个盒子**，图片在里面重新按比例 fit —— 于是它必然还是完整的。
    ///
    /// 🔴🔴 **旋转与缩放的顺序不能反**（2026-10-09 加旋转时定的）：
    ///先 `rotatedBox`（按档位交换宽高，让盒子与图片转到同一朝向），
    /// **再**乘缩放档。反过来的话，放大档 >1 时交换发生在放大之后的宽高上
    /// ⇒ 盒子被转错了方向（表现为「放大后图片偏出格子」）。
    /// ⚠️ `rotatedBox` 在`canRotate == false`（视频）时是恒等函数（档位恒 0），
    ///    所以这一行对视频也是安全的，不需要另开分支。
    private func scaledBox(_ base: CGSize) -> CGSize {
        let upright = model.rotatedBox(base)
        return CGSize(width: upright.width * model.zoom, height: upright.height * model.zoom)
    }

    // MARK: 内容区顶栏（**只有浮层形态**还画它）

    /// ⚠️ 窗口形态这一排不存在 —— 那三颗在**标题栏**上（`MediaPreviewTitlebarToolbar`）。
    ///    两处是同一批按钮的两种装法，所以图标 / 命中区 / hover 底**共用同一套常量**，
    ///    只差一个外圈留白（这里 `mediaPreviewBarMargin`，标题栏那边 `mediaPreviewTitlebarPaddingH`）。
    private var toolbar: some View {
        HStack(spacing: MacTheme.mediaPreviewButtonSpacing) {
            PreviewIconButton(icon: "minus.magnifyingglass", help: L("缩小"),
                              enabled: model.canZoomOut) { model.step(-1) }
            PreviewIconButton(icon: "plus.magnifyingglass", help: L("放大"),
                              enabled: model.canZoomIn) { model.step(1) }
            // 🔴 2026-10-09 加（用户要求「旋转图片按钮」）：顺时针 90°、四档循环。
            //    `canRotate` 在视频上是 false ⇒ 那颗自动置灰（灰是 `PreviewIconButton` 自己画的）。
            //    ☠️ 图标用 `rotate.right` 而不是 `arrow.triangle.2.circlepath`：后者是
            //    「循环/刷新」的意思（Apple 自带的刷新按钮就是它），会与「转一下」混淆。
            PreviewIconButton(icon: "rotate.right", help: L("旋转 90°"),
                              enabled: model.canRotate) { model.rotate() }
            PreviewIconButton(icon: "square.and.arrow.down", help: L("另存为…")) { model.saveAs() }
            Spacer(minLength: 0)
            // Esc = 关闭。⚠️ 挂在按钮上而不是 `onExitCommand`：后者要求视图先拿到键盘焦点
            // （与语音面板那颗取消同一条口径，见 `VoiceRecordingPanel`）。
            // ⚠️ 窗口形态没有这一颗 ⇒ Esc 改由窗口那侧的**本地事件监视器**接
            //    （`MediaPreviewWindow.swift`）：那条路不依赖键盘焦点，比这里更可靠。
            PreviewIconButton(icon: "xmark", help: L("关闭（Esc）"), shortcut: .escape) { onClose() }
        }
        .padding(.horizontal, MacTheme.mediaPreviewBarMargin)
        .padding(.vertical, MacTheme.mediaPreviewBarMargin)
    }

    // MARK: 左下角（来源胶囊 + 提示）

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if let label = item.sourceLabel {
                HStack(spacing: MacTheme.mediaPreviewSourceSpacing) {
                    Image(systemName: "globe")
                    Text(label)
                        .lineLimit(1)
                        // `.middle`：长域名的头（`news.`）与尾（`.com`）都比中间有用
                        .truncationMode(.middle)
                        .frame(maxWidth: MacTheme.mediaPreviewSourceMaxWidth, alignment: .leading)
                }
                .font(MacTheme.ui(MacTheme.mediaPreviewSourceFontSize))
                .foregroundStyle(MacTheme.mediaPreviewSourceText)
                .padding(.horizontal, MacTheme.mediaPreviewSourcePaddingH)
                .frame(height: MacTheme.mediaPreviewSourceHeight)
                .background(Capsule().fill(MacTheme.mediaPreviewSourceBackground(scheme)))
            }
            if let notice = model.notice {
                Text(notice)
                    .font(MacTheme.ui(MacTheme.mediaPreviewNoticeFontSize))
                    .foregroundStyle(MacTheme.mediaPreviewNoticeText)
                    .padding(.horizontal, MacTheme.mediaPreviewSourcePaddingH)
                    .frame(height: MacTheme.mediaPreviewSourceHeight)
                    .background(Capsule().fill(MacTheme.mediaPreviewSourceBackground(scheme)))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MacTheme.mediaPreviewPadding)
        .padding(.bottom, MacTheme.mediaPreviewPadding)
    }

    // MARK: 播放

    private func startVideoIfNeeded() {
        guard case .video(let url, _) = item else { return }
        let player = AVPlayer(url: url)
        // 点开就播：与 iOS 侧视频/图片预览同一口径（点开即自动开始，⛔ 不给二次确认）
        player.play()
        self.player = player
        // 🔴 把「怎么停」交给窗口那一侧（窗口 `close()` 那一拍调它）。
        //    ⚠️ 注册进句柄的是**局部** `player`，不是 `self.player` —— `@State` 的写在同一个
        //       闭包里读不回来（本仓库在 `ChatModel` 上踩过同一条）。
        //    ⚠️ 闭包里**只碰 `AVPlayer`、不碰任何 SwiftUI 状态**，所以从窗口的收尾里调它是安全的。
        playback?.stop = { [weak player] in player?.pause() }
    }

    /// 浮层关掉 / 视图被拆时**必须**停：不停的话声音还在放，而画面已经没了。
    /// ⚠️ 窗口模式走的是另一条路（`MediaPreviewPlaybackHandle`）—— 因为窗口 `close()` 不会让
    ///    SwiftUI 跑这里（视图仍在窗口层级里），而那件事的取证见 `MediaPreviewWindow.close()`。
    private func stopVideo() {
        player?.pause()
        player = nil
        playback?.stop = nil
    }
}

// MARK: - 标题栏上那一组（交通灯右边）

/// 窗口**标题栏**上那一组按钮：缩小 / 放大 / 另存为。
///
/// 🔴 装法在 `MediaPreviewWindow.installTitlebarToolbar(on:model:)`：
///    `NSTitlebarAccessoryViewController` + `layoutAttribute = .left` + `NSHostingView`。
///    ⛔ **别改成在内容区自绘、再把内容往上顶**：标题栏那片是**窗口**画的 ——
///    红绿灯、拖动窗口、双击缩放都在那；自绘的东西要么被窗口画的盖住，要么把拖动吃掉。
///    （`.left` 的语义就是 AppKit 文档里那句「adjacent and to the right of the
///      close/minimize/maximize buttons」。）
///
/// ⚠️ 与内容区那排（`MediaPreviewOverlay.toolbar`）共用**同一份** `MediaPreviewModel` ——
///    各持一份的话，点这里的放大，图片不会动。
///
/// ⚠️ 已知差异（没修，先记着）：窗口**失活**时系统红绿灯会自己变淡，而这套 SwiftUI 图标不会 ——
///    `Color(nsColor: .secondaryLabelColor)` 不随窗口激活状态变。要跟齐得读
///    `@Environment(\.controlActiveState)` 再压不透明度；但**那件事离屏验不了**
///    （`onHover` / 激活态在 `ImageRenderer` 里都没有），先不做。
struct MediaPreviewTitlebarToolbar: View {

    /// ⚠️ 与内容区是**同一份**实例（只读不写 ⇒ 不用 `@Bindable`）。
    let model: MediaPreviewModel

    var body: some View {
        HStack(spacing: MacTheme.mediaPreviewTitlebarSpacing) {
            PreviewIconButton(icon: "minus.magnifyingglass", help: L("缩小"),
                              enabled: model.canZoomOut) { model.step(-1) }
            PreviewIconButton(icon: "plus.magnifyingglass", help: L("放大"),
                              enabled: model.canZoomIn) { model.step(1) }
            // 🔴 2026-10-09 加旋转（与内容区那排**同一颗**，共用 `model.rotate()`）。
            //    ⚠️ `enabled: model.canRotate` 必须与内容区那排**逐字一致** ——
            //    视频时两颗都置灰；少判一处就是「标题栏那颗能点、内容区不动」
            //    （标题栏与内容区是两个独立的 `NSHostingView`，症状与「点放大图片不动」同源）。
            PreviewIconButton(icon: "rotate.right", help: L("旋转 90°"),
                              enabled: model.canRotate) { model.rotate() }
            PreviewIconButton(icon: "square.and.arrow.down", help: L("另存为…")) { model.saveAs() }
        }
        .padding(.horizontal, MacTheme.mediaPreviewTitlebarPaddingH)
        // ⚠️ `maxHeight: .infinity` 是**故意**的：标题栏那条的高度归**窗口**管
        //    （我们只定宽度，见 `MacTheme.mediaPreviewTitlebarWidth`）。
        //    给死高度会让三颗贴着顶边 —— 而在不同标题栏高度（全屏）下还不一样。
        .frame(maxHeight: .infinity)
    }
}

// MARK: - 顶栏按钮

/// 预览里的一颗图标按钮。**两处共用**：内容区顶栏（浮层形态）与窗口**标题栏**。
///
/// 🔴 hover 底**必须自己画**：`.buttonStyle(.plain)` 在 macOS 上零指针反馈 ——
///    本仓库的侧栏入口行 / 会话行都踩过，「一排看不出能不能点的图标」比没有还糟。
/// 🔴 命中区恒为 `mediaPreviewButtonSize`：图标只有十几像素，不加命中区点不中。
/// 🔴 `enabled == false` 时**显式**给灰：`.disabled(true)` 只拦交互，管不到写死的 `foregroundStyle`
///    （与操作栏那颗「重试」同一条）。
/// ⚠️ 标题栏那版**不另立一套尺寸**：同一批图标在两个位置长得必须一样，
///    所以这里读的还是 `mediaPreviewButtonSize`（标题栏 28pt 高，26 的命中区正好放得下）。
private struct PreviewIconButton: View {

    let icon: String
    let help: String
    var enabled: Bool = true
    var shortcut: KeyEquivalent?
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(MacTheme.ui(MacTheme.mediaPreviewIconSize))
                .foregroundStyle(enabled ? MacTheme.mediaPreviewIcon : MacTheme.mediaPreviewIconDisabled)
                .frame(width: MacTheme.mediaPreviewButtonSize, height: MacTheme.mediaPreviewButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: MacTheme.mediaPreviewButtonRadius)
                        .fill(isHovered && enabled ? MacTheme.mediaPreviewButtonHover(scheme) : .clear)
                )
                // 文字/图形按钮的命中区只有字形那么大 ⇒ 垫一层 `contentShape`
                // （与输入栏那几颗图标同一个坑）
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .onHover { isHovered = $0 }
        .modifier(OptionalShortcut(shortcut: shortcut))
    }
}

/// 只在给了快捷键时才挂 `keyboardShortcut`（不给就不挂 —— 免得注册一个空键位）。
private struct OptionalShortcut: ViewModifier {
    let shortcut: KeyEquivalent?

    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut, modifiers: [])
        } else {
            content
        }
    }
}

// MARK: - 播放器（AppKit 的 `AVPlayerView`）

/// 视频画面 + 系统自带的一套浮层控件（播放/暂停/进度/音量/画中画）。
///
/// 🔴 **为什么是 AppKit 这个而不是 SwiftUI 的 `VideoPlayer`** —— 见文件头那一节：
///    `VideoPlayer` 对 `AVPlayerView` 是运行期按名字查的，链接器看不见符号 ⇒ 会把
///    `AVKit.framework` 当无用依赖剥掉 ⇒ 建类元数据时 `fatalError` + abort（实测退出码 134，
///    一声不响）。换成本文件里的写法，`AVPlayerView` 是**静态类符号**，AVKit 一定进得了 LC。
/// ⚠️ 所以这个类型**别为了「省 20 行」删掉换回 `VideoPlayer`**。
private struct MacVideoPlayer: NSViewRepresentable {

    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // `.floating` = 鼠标移上去才浮出控件、移开自动隐 —— 与参考图那种「干净的画面 + 需要时才有控件」
        // 一致（`.inline` 会常驻占掉画面底部一条）。
        view.controlsStyle = .floating
        view.player = player
        return view
    }

    /// 浮层里换了媒体（同一次打开不会换，但 SwiftUI 可能重建）时把 player 对上。
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
