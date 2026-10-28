//
//  RowMediaImage.swift
//  AsterMac
//
//  会话行里的**图片 / 视频封面** —— 异步取图 + 降采样 + 缓存。
//
//  ## 🔴 为什么必须单开这一个视图（2026-09-27 修）
//
//  原来 `ChatRowView.imageBlock` / `videoBlock` 是这么写的：
//
//      if let url = row.block.imageURL, let image = NSImage(contentsOf: url) { … }
//
//  两件事同时错：
//  ① **`NSImage(contentsOf:)` 是同步的**，写进 `body` = 「每次求值都在主线程上取一遍图」；
//  ② 它对**远程 URL 也会真的去下载** —— 而助手侧的图片 / 视频封面**全是 http(s)**
//     （本地 mock 返回的也是 http 链接，用户发出去的附件才是本地文件）。
//
//  本机实测（拿 mock 那对资源量的）：
//      `NSImage(contentsOf: 1.2MB 远程图)`  首次 **309ms**，之后 33~40ms；连续 20 次 **1442ms ≈ 72ms/次**
//      `NSImage(contentsOf: picsum 封面)`   每次 **400ms**（首次 1253ms —— 它每次都重下）
//  72ms/次 = 每次 body 求值至少掉 4 帧。一次滚动里 body 被求值几次，就是几百 ms~秒级的主线程阻塞：
//  ⇒ **上下滑动卡顿**；同时 SwiftUI 的懒加载被饿死，中间那一段一片空白
//    —— 用户看到的「**会话数据被吞了**」就是这个（库里一条都没少，是没画出来）。
//  ⇒ 另外它把图**全解成位图**（1080×810×4 = 3MB/张），每次求值重新分配一遍。
//
//  ## 三条口径
//
//  ① **本地文件走同步**（`AIAttachmentStorage.image(at:maxPixelSize:)` + `NSCache`）——
//     与输入栏 `ComposerThumbnailCache` 是**同一套手法**，理由也是同一条：
//     `ImageRenderer` 里 `.task` 根本不会跑，只有同步取才拿得到离屏验收图。
//     降采样 + 缓存命中 ⇒ 一次求值 ≈ 0ms。
//  ② **远程 URL 走异步，一行网络 IO 都不许上主线程**：命中缓存就直接画；
//     没命中先画占位底，后台下载 + 解码，回来再显示。
//     ☠️ **失败要记账**（`failures`）—— 不然每次求值都会重下一遍，那正是「每次 400ms」的来源。
//  ③ **降采样目标 = 显示尺寸 × 屏幕 scale**（不是原图、也不是固定值）——
//     与 `MacInputBar` 里那条注释同一个理由：用得到多少就解多少。
//     取宽高里的**上界**（`.fit` 时实际画得更小），换来「不必先读源图比例、缓存键也简单」。
//  ④ 取图挂在 **`.task(id: pixel)`**（不是 `.task`）：盒子变了（窗口变宽、浮层放大）
//     就按新档重取一份。⚠️ **已知取舍**：拖窗口边缘/连续缩放时 `pixel` 是连续变化的
//     ⇒ 每个中间档都会起一次 fetch + decode（fetch 多半命中 `URLCache`，decode ≈33ms
//     且是 `.utility` 优先级）。不阻塞主线程，但会白烧一点 CPU。要削就在 `key` 里把 pixel
//     量化成粗档（例如向上取整到 128 的倍数）；**当前没做**（不为没出现的症状加策略）——
//     这也是媒体浮层的缩放**刻意不加动画**的原因（见 `MacTheme.mediaPreviewZoomLevels`）。
//
//  ## 为什么解码结果用 `DecodedBitmap` 那个盒子搬
//  `NSImage` 不满足 `Sendable`，没法从后台任务里交回主线程；`CGImage` **不可变**、可以。
//  所以后台只产 `CGImage`，`NSImage` 一律在主线程造。
//
//  ## ⛔ 别提议「换成 Kingfisher / KFImage」（2026-09-27 定案，问过一次了）
//
//  先把事实摆清，免得下次又要重查一遍：
//  ✅ **能用**。Kingfisher **8.12.0 早就在本工程里**（iOS target 的
//     `packageProductDependencies`，`Chat/AIAssistantMediaStripCell.swift` /
//     `Chat/AIModuleViewController+RowAction.swift` 两处就在 `kf.setImage`）。
//     SwiftUI 支持在 8.x 已并入主模块（不用单独的
//     `KingfisherSwiftUI`），`KFImage` 要 iOS 14+ / macOS 11+ —— 我们是 iOS 15 / macOS 14，
//     **版本上完全够**。所以「不该引第三方」「版本不支持」都**不是**理由，别拿它们当借口。
//
//  ⛔ 但 Mac 侧**仍然不用它**，三条（硬 → 软）：
//
//  ① **离屏验收台会瞎**（决定性）。渲染台 `render_mac_ui.sh` 是「裸编
//     `AsterMac/Views/*.swift` + 静态库链」，第三方模块要么真编进去、要么**打桩** ——
//     先例就是 `macstub/Down.swift`（注释原话「只保证有字」）。而 `KFImage` 的加载挂在
//     `onAppear` 那一类生命周期上，本仓库**已实测** `ImageRenderer` 里 `.task` 不跑
//     （`VERIFY-PROBES.md` 硬限制第 4 条）⇒ 媒体行**永远只画占位底**。
//     本文件「本地文件走同步」那条口径正是为这个存在的：夹具用本地 PNG 才能离屏画出真图，
//     才验得出圆角 / 16:9 / `.fill` 有没有把画面裁变形。
//     ⚠️ 而**上一个 bug 恰好是因为夹具里一条媒体行都没有**，从没被任何一张离屏图照到过 ——
//     别再把这个盲区装回去。
//
//  ② **Mac target 接 Kingfisher 要动 pbxproj**：package 在工程级已存在，但给 target 加
//     product 依赖要动三处（`PBXBuildFile` + `PBXFrameworksBuildPhase.files` +
//     `packageProductDependencies`），ID 从 `0095` 起取。`MEMORY.md` 标红的高危区
//     （漏 `PBXBuildFile` 只在链接期报 `Undefined symbol`；ID 撞车直接 Xcode 打不开）。
//
//  ③ **降采样口径会分叉**：现在 `AIAttachmentStorage.bitmap(from:maxPixelSize:)` 是唯一实现
//     （沿用 `AICodeBlockMetrics` 那条「量算必须与渲染同源」）。
//
//  🔓 **什么条件下可以重新考虑**：离屏验收台不再需要**同步**出图（例如改成真机截图验收、
//     或给渲染台补上事件泵让 `onAppear` 跑起来），**且**愿意动 pbxproj。
//     届时正确用法是 `KFImage(url).resizable().aspectRatio(…)` +
//     `.processor(DownsamplingImageProcessor(size:))` + `.scaleFactor(displayScale)` ——
//     ⚠️ **降采样不是默认开的**，不传 processor 就是原图全尺寸解码进内存。
//

import SwiftUI
import AppKit
import AICore

// MARK: - 取图 + 缓存

/// 行内媒体图的取图与缓存。
///
/// 全部状态（缓存 / 失败表 / 在途表）都归主线程 —— 本工程 App target 开了
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，所以这里天然是主线程隔离的。
/// 唯一离开主线程的是 `fetch`（标了 `nonisolated`，不碰任何共享状态）。
@MainActor
enum RowMediaImageStore {

    /// 内存缓存。用 `NSCache` 而不是字典：一个条目就是一张位图，几十条就是几十 MB
    /// （与输入栏 `ComposerThumbnailCache`、业务层 `dataURLCache` 同一个理由 ——
    /// 交给系统在内存压力下回收，比自己记账合适）。
    private static let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    /// 取失败过的 key。☠️ **别省这张表**：远程 URL 一旦取不到（404 / 断网 / 代理拦），
    /// 没有它就等于「每次 body 求值都重试一遍网络」，那是原来卡顿的另一半原因。
    private static var failures: Set<String> = []

    /// 在途的**字节下载**任务。键按 **URL**（**不带**像素）：同一张图同时被多行引用时
    /// （mock 每轮返回的都是同一张）字节只下一份。
    ///
    /// ☠️ 但**解码绝不能塞进这个任务里** —— 降采样目标是**解码时**生效的
    /// （`kCGImageSourceThumbnailMaxPixelSize`），不是「下完之后再分叉」。
    /// 2026-09-27 修过一次：原来把解码一并塞进来，于是「搭顺风车的那一行」会拿到
    /// **别人像素档**的位图、还被按**自己的 key** 存进缓存（`load` 里用的是 `k`）。
    /// ☠️ 这在**本 App 里必然撞上**：mock 的图片行与视频封面是**同一个 URL**、
    /// 而两者请求的像素档不同（`0.62×` vs `0.66×` 容器宽）⇒ 每次启动都撞一次。
    /// 差异只有 6% 肉眼看不出来，但**缓存里那条记录的账是错的**（`cost` 也因此记错）。
    private static var inFlightData: [String: Task<Data?, Never>] = [:]

    /// 在途的**解码**任务。键按 **`key(url, pixel)`** —— 同一像素档被多行同时引用时只解一份。
    ///
    /// 为什么要和上面那张表分开：两个轴各自去重才都成立。
    /// - 字节那条轴按 URL（同一张图只下一份）；
    /// - 解码这条轴按像素档（同一档只解一份）—— ☠️ 曾经合成一条，结果是
    ///   「搭顺风车的那一行拿到**别人像素档**的位图、又按自己的 key 存进缓存」。
    /// ⚠️ mock 每轮返回**同一张图** ⇒ 一个会话里会出现很多同 URL 的媒体行，
    ///    而它们几乎同时进入视口 ⇒ 这张表挡掉的正是「N 行各解一遍」。
    private static var inFlightDecode: [String: Task<DecodedBitmap?, Never>] = [:]

    /// 缓存键：**URL + 目标像素**。同一个 URL 在窗口变宽后会以更高分辨率重新解一份，
    /// 两者互不覆盖（旧的那份由 `NSCache` 自己回收）。
    static func key(_ url: URL, _ pixel: CGFloat) -> String {
        "\(url.absoluteString)|\(Int(pixel.rounded()))"
    }

    /// 主线程取图。**命中缓存 / 本地文件都在这儿直接拿到图**；远程未命中返回 nil。
    ///
    /// 🔴 远程分支只查表、**绝不下载** —— 这个方法会被 `body` 调用，它必须便宜。
    static func image(_ url: URL, pixel: CGFloat) -> NSImage? {
        let k = key(url, pixel)
        if let hit = memory.object(forKey: k as NSString) { return hit }
        guard url.isFileURL else { return nil }          // 远程：只查表
        guard let image = AIAttachmentStorage.image(at: url, maxPixelSize: pixel) else {
            failures.insert(k)
            return nil
        }
        memory.setObject(image, forKey: k as NSString, cost: cost(pixel))
        return image
    }

    static func hasFailed(_ url: URL, pixel: CGFloat) -> Bool {
        failures.contains(key(url, pixel))
    }

    /// 异步取图（**远程专用**；本地文件上面那条同步路径已经拿到了）。
    ///
    /// 两级、两个去重轴：**① 字节按 URL**（`bytes(url:)`）→ **② 解码按像素档**（`inFlightDecode`）。
    /// - Returns: 取不到返回 nil（调用方据此显示「图片不可用」）
    static func load(url: URL, pixel: CGFloat) async -> NSImage? {
        let k = key(url, pixel)
        if let hit = memory.object(forKey: k as NSString) { return hit }
        if failures.contains(k) { return nil }

        // ① 字节
        guard let data = await bytes(url: url) else {
            failures.insert(k)
            return nil
        }

        // ② 解码：**每个像素档各解各的**，在后台（≈33ms，别搬回主线程）
        let bitmap: DecodedBitmap?
        if let running = inFlightDecode[k] {
            bitmap = await running.value                     // 同上：搭同一档的顺风车
        } else {
            let task = Task.detached(priority: .utility) {
                AIAttachmentStorage.bitmap(from: data, maxPixelSize: pixel).map(DecodedBitmap.init)
            }
            inFlightDecode[k] = task
            bitmap = await task.value
            inFlightDecode[k] = nil
        }
        guard let bitmap else {
            failures.insert(k)
            return nil
        }

        // `NSImage` 只在主线程造 —— 这一步很便宜（位图已经解好了）
        let image = NSImage(cgImage: bitmap.cgImage, size: .zero)
        memory.setObject(image, forKey: k as NSString, cost: cost(pixel))
        return image
    }

    /// `NSCache` 的 cost：**按请求的目标像素算**，不去问图像本身
    /// （问它要 `cgImage(forProposedRect:)` 会把图**再解一遍**，等于为了记账把省下的又花掉）。
    private static func cost(_ pixel: CGFloat) -> Int {
        Int(pixel * pixel * 4)
    }

    /// 取字节，按 **URL** 去重；**不**解码（解码由 `load` 按自己的像素档做）。
    ///
    /// 会读写 `inFlightData` ⇒ **必须在主线程**（本工程 App target 默认 MainActor 隔离）；
    /// 真正的网络 IO 才放进 `Task.detached`。
    private static func bytes(url: URL) async -> Data? {
        if let running = inFlightData[url.absoluteString] {
            return await running.value                       // 去重：同一张图只下一次
        }
        let task = Task.detached(priority: .utility) { await Self.fetch(url: url) }
        inFlightData[url.absoluteString] = task
        let data = await task.value
        inFlightData[url.absoluteString] = nil
        return data
    }

    // MARK: 后台（不碰任何共享状态）

    /// 只下字节，**不解码**（解码由调用方按自己的像素档做，见 `inFlightData` 上那段）。
    /// 全程在后台，**不碰任何共享状态**、更不碰 `NSImage`（它不可跨线程搬）。
    ///
    /// ⚠️ 走 `URLSession.shared`：它自带 `URLCache`（沙盒容器里的 `Cache.db`）
    /// ⇒ 同一张图重开 App 也多半命中 HTTP 缓存，不必自己再写一层磁盘缓存。
    /// （真要做「助手侧图片离线可看」是另一件事：那该把字节落到 `AIAttachments` 并纳入清理策略。）
    private nonisolated static func fetch(url: URL) async -> Data? {
        guard let (data, _) = try? await URLSession.shared.data(from: url), !data.isEmpty else { return nil }
        return data
    }
}

/// 跨线程搬一次「解好的位图」用的盒子。
///
/// `CGImage` 是**不可变**的 —— 跨线程读天然安全，CoreGraphics 只是没给它标 `Sendable`，
/// 所以这里显式 `@unchecked` 承担这个判断。
/// ⛔ 盒子里**只许放不可变值**（放 `NSImage` 就是把「不可变」这个前提撒谎了）。
private struct DecodedBitmap: @unchecked Sendable {
    let cgImage: CGImage
}

// MARK: - 视图

/// 媒体块**怎么占地方**。两种，别混（2026-09-27 加第二种）。
enum RowMediaImageLayout {
    /// 行内：**固定**占这个尺寸。
    /// 图片是 16:9 框 `.fit`（不裁）、视频封面是撑满 `.fill`（裁）—— 与 iOS 同口径。
    /// 🔴 两种状态占**同样大小** ⇒ 「加载中 → 出图」不会引起任何行高变化、列表不跳。
    case fixed(CGSize, contentMode: ContentMode)
    /// 浮层（`MediaPreviewOverlay`）：按图片**自身比例**缩放到不超过这个盒子
    /// （`.fit`、不裁切、不撑满），四周留白。
    /// ⛔ 别拿它去替行内那两种：行内是「列表里的一致口径」，浮层才是「把这张图看全」。
    case fitIn(CGSize)
}

/// 行内 / 浮层共用的媒体图。图片用 `.fit`（行高固定 16:9，保持现状），视频封面用 `.fill`。
///
/// 取图这条路**只有这一份**（异步 + 降采样 + 缓存 + 失败记账）—— 浮层只是换了种「怎么占地方」，
/// 所以走 `layout` 参数而不是另写一个视图：另写一份必然与这里漂移。
struct RowMediaImage: View {

    let url: URL
    /// 盒子。`.fixed` 就是显示尺寸本身；`.fitIn` 是「最大不超过」的那个框。
    let layout: RowMediaImageLayout
    let cornerRadius: CGFloat

    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var failed = false

    /// 降采样目标边长（**宽高里的上界**，见文件头第 ③ 条）
    private var pixel: CGFloat {
        max(box.width, box.height) * max(displayScale, 1)
    }

    private var box: CGSize {
        switch layout {
        case .fixed(let size, _): return size
        case .fitIn(let size):    return size
        }
    }

    /// 先看 `@State`，再查表。
    /// 后半截（查表）才是关键：**滚出去又滚回来**时 `@State` 会重建，
    /// 只有同步查表才能当场出图、不闪一下占位底。
    private var resolved: NSImage? {
        image ?? RowMediaImageStore.image(url, pixel: pixel)
    }

    var body: some View {
        switch layout {
        case .fixed(let size, let contentMode):
            picture(contentMode: contentMode)
                .frame(width: size.width, height: size.height)
                // `.fill` 溢出的部分由这层裁掉（与原来 `.clipped()` 的效果一致，且顺手带上圆角）
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .task(id: pixel) { await load() }

        case .fitIn(let box):
            picture(contentMode: .fit)
                // ⚠️ 是 `maxWidth/maxHeight`（上限）不是 `width/height`（固定）：
                //    可缩放的 `Image` 会把这一层填满、图片在内部按比例居中 —— 也就是
                //    「按自身比例缩放到不超过盒子」。⛔ 别改成固定尺寸，那会把比例算死。
                .frame(maxWidth: box.width, maxHeight: box.height)
                .task(id: pixel) { await load() }
        }
    }

    @ViewBuilder
    private func picture(contentMode: ContentMode) -> some View {
        if let resolved {
            Image(nsImage: resolved)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            MacTheme.cardBackground
            if failed {
                Text(L("图片不可用"))
                    .font(MacTheme.notice)
                    .foregroundStyle(MacTheme.meta)
            }
        }
        .frame(width: placeholderSize.width, height: placeholderSize.height)
    }

    /// 占位底多大。`.fixed` 就用盒子本身（必须 —— 它要撑住行高）。
    /// `.fitIn`（浮层）刻意**不占满整屏**：一块 16:9 的卡就够了，占满会像「整页糊了一张卡」。
    private var placeholderSize: CGSize {
        switch layout {
        case .fixed(let size, _):
            return size
        case .fitIn(let box):
            let width = box.width * 0.4
            return CGSize(width: width, height: width * 9 / 16)
        }
    }

    private func load() async {
        // 缓存 / 本地文件已经在 `resolved` 里出图了，这里不用再做任何事
        guard RowMediaImageStore.image(url, pixel: pixel) == nil else { return }
        let loaded = await RowMediaImageStore.load(url: url, pixel: pixel)
        // ⚠️ 即使这个 task 因为「行被回收」而被取消，上面的 await 也已经把结果写进缓存了 ——
        //    所以缓存一定会被预热，只是这两行 `@State` 的赋值可能落在一个已经不在的视图上（无害）。
        image = loaded
        failed = loaded == nil
    }
}
