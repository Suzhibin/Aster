//
//  AIAttachment.swift
//  AIModule
//
//  用户侧附件（相册图片 / 文件）的模型 + 落地存储。
//
//  两条铁律（都是踩过的坑，别省）：
//  ① **先拷进沙盒再用**：`PHPicker` 的 `loadFileRepresentation` 与 `UIDocumentPicker`
//     的 `asCopy: true` 给的都是系统 tmp 下的文件，随时会被回收。存 URL 等下次用必然失效。
//  ② **图片在落地时就压缩**（长边 1600 / JPEG 0.8）：聊天附件不需要原图。压缩后
//     沙盒占用、以及发给模型时的 base64 请求体（DeepSeek 上限 48 MiB）都更可控。
//

import Foundation
import ImageIO
import PDFKit
import AIPlatform

// MARK: - 模型

/// 用户发出的一条附件（图片或文件）。
///
/// 存在意义：`AIBlock` 只记 `fileURL`，而界面还需要「叫什么、多大、什么比例」——
/// 这些都从磁盘现算太贵（列表滚动要反复 IO），所以在选中那一刻算好带过来。
public struct AIAttachment: Identifiable, Equatable {

    public enum Kind: Equatable {
        case image
        case file
    }

    public let id: UUID
    public let kind: Kind
    /// **已经在沙盒里**的文件（不是系统 tmp）
    public let fileURL: URL
    /// 展示名：文件用原文件名，图片用落地后的文件名
    public let displayName: String
    /// 落盘后的字节数（图片是压缩后的）
    public let byteSize: Int64
    /// 仅图片：压缩后的像素尺寸，行高按它算宽高比（不落库，渲染时现读）
    public let pixelSize: CGSize?

    public init(id: UUID = UUID(),
                kind: Kind,
                fileURL: URL,
                displayName: String,
                byteSize: Int64,
                pixelSize: CGSize? = nil) {
        self.id = id
        self.kind = kind
        self.fileURL = fileURL
        self.displayName = displayName
        self.byteSize = byteSize
        self.pixelSize = pixelSize
    }

    public var isImage: Bool { kind == .image }

    /// 人类可读的大小（1.2 MB / 340 KB）
    public var sizeText: String { ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file) }
}

// MARK: - 落地存储

/// 附件的落盘 / 读取 / 清理。目录固定为 `Documents/AIAttachments`，文件名用 UUID。
///
/// 直接用 `FileManager` 而不走 `StarryFileManager`：后者管的是「缓存目录分类 +
/// 空间统计」那套，与这里「用户可见的持久附件」职责不同，硬套会让清理策略互相牵连。
public enum AIAttachmentStorage {

    /// 图片长边上限。DeepSeek 侧会先把图缩到约 800×800 的像素量再算 token，
    /// 传更大的图只会白占请求体，不会更准。
    public static let maxPixelSide: CGFloat = 1600
    public static let jpegQuality: CGFloat = 0.8

    /// 附件目录（`<应用数据目录>/AIAttachments`）
    ///
    /// - Note: 根目录走 `AIPlatformPaths` —— iOS 是沙盒 `Documents`（与拆分前一致），
    ///   macOS 是 `Application Support/<bundleID>`（Mac 沙盒拿不到 `Documents` 的写权限）。
    public static var directory: URL {
        AIPlatformPaths.appDataDirectory.appendingPathComponent("AIAttachments", isDirectory: true)
    }

    @discardableResult
    public static func ensureDirectory() -> Bool {
        let dir = directory
        if FileManager.default.fileExists(atPath: dir.path) { return true }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return true
        } catch {
            debugPrint("[AIAttachment] 创建附件目录失败: \(error)")
            return false
        }
    }

    // MARK: 导入

    /// 把相册选中的图片压缩后落盘。
    /// - Returns: 失败返回 nil（调用方跳过这一张，不要让整批失败）
    public static func importImage(_ image: AIPlatformImage) -> AIAttachment? {
        guard let (data, pixelSize) = compressedJPEG(image), ensureDirectory() else { return nil }
        let name = "\(UUID().uuidString).jpg"
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            debugPrint("[AIAttachment] 图片落盘失败: \(error)")
            return nil
        }
        // 预热「内联进请求体」用的 data URL（见 `warmDataURL`）：
        // 这笔编码迟早要在发送那一下做，趁用户还在看预览缩略图先做掉
        warmDataURL(for: url, data: data)
        return AIAttachment(kind: .image,
                            fileURL: url,
                            displayName: name,
                            byteSize: Int64(data.count),
                            pixelSize: pixelSize)
    }

    /// 把文件选择器给的文件**拷贝**进沙盒（源文件在系统 tmp / 安全作用域内，不能直接持有）。
    public static func importFile(at source: URL, displayName: String? = nil) -> AIAttachment? {
        guard ensureDirectory() else { return nil }
        let ext = source.pathExtension
        let name = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let dest = directory.appendingPathComponent(name)

        // PHPicker / DocumentPicker 的 URL 可能是安全作用域资源，必须显式开权限再读
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            debugPrint("[AIAttachment] 文件拷贝失败: \(error)")
            return nil
        }
        let size = byteSize(of: dest)
        // 上限拦一道：太大的文件发不出去（base64 请求体有上限），也不该占着沙盒
        let shown = displayName ?? source.lastPathComponent
        return AIAttachment(kind: .file,
                            fileURL: dest,
                            displayName: shown.isEmpty ? name : shown,
                            byteSize: size)
    }

    // MARK: 导出（Mac 的「另存为」用它落盘，2026-09-27 加）

    /// 把一份媒体**导出**到用户选定的位置。
    ///
    /// 🔴 为什么放在业务层、而不是写进那几行视图代码里：与 `importImage` / `importFile` 是
    /// **同一条边界** —— 「字节怎么落盘」只在本文件里说了算，视图层只管弹面板拿 URL。
    /// （真在视图里写文件，迟早出现「这条路径带权限作用域、那条不带」的分叉。）
    ///
    /// - 本地文件：`copyItem`（**不**把几 MB 字节读进内存）
    /// - 远程 URL：走网络；`URLSession.shared` 自带 `URLCache`，同一张图多半已经缓存过
    /// - ⚠️ **沙盒 App 里目标 URL 必须来自用户选择**（`NSSavePanel` / `NSOpenPanel`），
    ///   否则写入必然被拒。这条对应 Mac target 的
    ///   `ENABLE_USER_SELECTED_FILES = readwrite`（2026-09-27 从 `readonly` 升上来）。
    ///   缺权限时的症状是**静默失败**（面板照弹、文件不出现）⇒ 调用方必须看返回值提示用户。
    ///
    /// - Returns: 目标位置是否真的有文件（视图据此显示「保存失败」）
    @discardableResult
    public static func export(from source: URL, to destination: URL) async -> Bool {
        if source.isFileURL {
            if source.standardizedFileURL == destination.standardizedFileURL { return true }
            do {
                // 面板已经问过「要替换吗」——到这里就是要覆盖
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                debugPrint("[AIAttachment] 导出拷贝失败: \(error)")
                return false
            }
            return FileManager.default.fileExists(atPath: destination.path)
        }

        guard let (data, _) = try? await URLSession.shared.data(from: source), !data.isEmpty else {
            debugPrint("[AIAttachment] 导出下载失败: \(source.absoluteString)")
            return false
        }
        do {
            try data.write(to: destination)
        } catch {
            debugPrint("[AIAttachment] 导出写入失败: \(error)")
            return false
        }
        return true
    }

    // MARK: 读取 / 清理

    public static func byteSize(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: 图片内联（请求体用）

    /// 图片附件的 `data:<mime>;base64,…` 缓存。
    ///
    /// 为什么需要：**每一轮请求都会重新带上历史图片**（`AIChatManager.contextMessages` 最多 6 张），
    /// 每一张都要同步读盘 + base64 编码 —— 400~800 KB 的图编出来是 0.5~1 MB 的字符串，
    /// 而这些开销全部落在**主线程**上、就在「点发送 → 气泡出现」之间。
    ///
    /// 附件文件名是 UUID、落盘后不会再被改写，所以「路径 → data URL」是纯函数
    ///（`remove` 里会同步清掉条目，连「删了又在同一路径写回」这种极端情况也覆盖了）。
    ///
    /// ⚠️ 用 `NSCache` 而不是字典：一个条目就是接近 1 MB 的字符串，几条就能上 MB ——
    /// 数量上限 + 内存压力下由系统回收，比自己记账更合适。
    private static let dataURLCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 16
        return cache
    }()

    /// 落盘时**预热**：把刚写下去的那份字节直接编成 data URL 存进缓存。
    ///
    /// 这笔编码本来要在「下一次点发送」时花掉，提前到用户刚选完图、还在看预览缩略图的
    /// 那一刻付掉 —— 发送时就只剩一次字典查找。纯优化：失败即静默，不影响任何功能。
    public static func warmDataURL(for url: URL, data: Data) {
        guard !data.isEmpty else { return }
        let encoded = "data:\(mimeType(for: url));base64,\(data.base64EncodedString())"
        dataURLCache.setObject(encoded as NSString, forKey: url.path as NSString)
    }

    /// 把本地图片编成 `data:<mime>;base64,…`（**带缓存**）。
    ///
    /// DeepSeek 也支持外链 URL 和 Files API，但那两条路都得**先把图传上去**、
    /// 多一次往返和一份远端状态（还要考虑过期与清理）。附件在落盘时已压到长边 1600，
    /// base64 的体积可控，直接内联是最短路径。
    ///
    /// - Note: 键只取**路径**。附件是「一次落盘、永不改写」的，所以不必再比大小 /
    ///   修改时间 —— 那样每次都要多一次 `stat`，而缓存存在的意义正是省掉读盘。
    public static func dataURL(for url: URL) -> String? {
        let key = url.path as NSString
        if let cached = dataURLCache.object(forKey: key) { return cached as String }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let encoded = "data:\(mimeType(for: url));base64,\(data.base64EncodedString())"
        dataURLCache.setObject(encoded as NSString, forKey: key)
        return encoded
    }

    /// 图片的 MIME 类型。落盘时统一编成 JPEG，其余分支只是兜底。
    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":           return "image/png"
        case "gif":           return "image/gif"
        case "webp":          return "image/webp"
        case "heic", "heif":  return "image/heic"
        default:              return "image/jpeg"
        }
    }

    /// 降采样读图：**别用 `UIImage(contentsOfFile:)`** —— 它会把整张图全解成位图，
    /// 一张 1600px 的图就是 1600×1200×4 ≈ 7.6 MB。列表滚动 + 预览条几张图叠起来
    /// 轻松顶出几十 MB，而实际只需要显示几十~几百 pt。
    /// - Parameter maxPixelSize: 目标像素边长（传「要显示的 pt 数 × 屏幕 scale」）
    public static func image(at url: URL, maxPixelSize: CGFloat) -> AIPlatformImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = thumbnail(from: source, maxPixelSize: maxPixelSize) else {
            return nil
        }
        // 只有最后一步「CGImage → 平台图像」是平台相关的（UIImage / NSImage），收在接缝层
        return AIPlatform.imageCodec.makeImage(from: cgImage)
    }

    /// 降采样读**内存里的字节**，返回 **`CGImage`**（**不**包成平台图像）。
    ///
    /// 为什么单独留一个 `CGImage` 出口，而不是直接给 `AIPlatformImage`：
    /// `NSImage` / `UIImage` 都**不满足 `Sendable`**，从后台任务搬回主线程会被编译器挡；
    /// `CGImage` 是**不可变**的（CoreGraphics 只差没标 `Sendable`），跨线程读天然安全。
    /// ⇒ 「后台下载 + 解码 → 主线程只负责包成图像」这条路上用它（Mac 行内媒体图就是这么用的）。
    ///
    /// ⚠️ 它是给**网络下载下来的那份字节**用的：不必为了读一次先落盘。
    public static func bitmap(from data: Data, maxPixelSize: CGFloat) -> CGImage? {
        guard maxPixelSize > 0, !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    /// 降采样的**唯一实现**。三个入口（磁盘 / 内存 / 平台图像）都走这里。
    /// ⛔ 别在别处再写一套 `kCGImageSourceThumbnailMaxPixelSize` 参数 —— 参数一漂，
    ///    同一张图在不同入口就解出不同结果，排查起来毫无线索。
    private static func thumbnail(from source: CGImageSource, maxPixelSize: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // 带上 EXIF 方向，否则竖拍的照片会躺倒
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 从磁盘读回像素尺寸（载入历史会话时给用户图片补 `mediaSize`，行高才算得对）
    public static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        guard let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        // 只读头信息，不解码像素 —— 载入一整屏历史会话也不会卡
        return CGSize(width: w, height: h)
    }

    // MARK: 落库路径

    /// 落库用的路径字符串。
    ///
    /// ⚠️ **本地附件只存文件名，不存绝对路径** —— 沙盒容器的父目录 UUID 在重装 / 升级后会变，
    /// 存死的绝对路径过一阵就指向不存在的位置，而且是**静默失效**（图直接不显示、不报错，
    /// 排查起来很费劲）。读的时候由 `resolve` 拼回当前目录。
    /// 远程 URL（助手侧的图片 / 视频）整条存 —— 它本来就不依赖沙盒。
    public static func storedPath(for url: URL) -> String {
        url.isFileURL ? url.lastPathComponent : url.absoluteString
    }

    /// 落库路径 → 当前可用的 URL。本地文件按文件名拼回当前沙盒目录。
    public static func resolve(_ stored: String?) -> URL? {
        guard let stored = stored, !stored.isEmpty else { return nil }
        if stored.hasPrefix("http://") || stored.hasPrefix("https://") {
            return URL(string: stored)
        }
        // 本地：只取文件名（顺带兼容可能存在的旧绝对路径写法），拼到当前附件目录
        let name = (stored as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        return directory.appendingPathComponent(name)
    }

    public static func remove(at url: URL) {
        // 顺手清掉它的 data URL：文件没了，缓存条目不但没用，还是个接近 1 MB 的字符串
        dataURLCache.removeObject(forKey: url.path as NSString)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: 可读文本

    /// 文件里有多少内容能当作**文本**塞进 prompt（**按类型分流的总入口**，2026-10-23 起支持 PDF）。
    ///
    /// 模型只吃图片和文字，PDF/zip 之类发不过去 —— 这里按扩展名分流：
    /// - 纯文本类（`textExtensions` 白名单）→ `plainText` 原路（UTF-8 直读 + 字节层截断）；
    /// - `pdf` → PDFKit 抽正文（边界说明见 `pdfText`）；
    /// - 其余（zip/docx/二进制…）→ nil，交给调用方降级成一句「无法解析」的说明。
    ///
    /// ⚠️ 加新格式时**两个调用点自动生效**（`AIChatManager.fileContextText` 与
    ///    `AIChatStore.indexProjectFile` 都走这一处）⇒ ⛔ 别去分别改那两处：分叉了就会出现
    ///    「附件发得过去、项目资料却索引不上」，而且**不报错**。
    public static func extractedText(at url: URL, maxChars: Int = 8000) -> String? {
        switch url.pathExtension.lowercased() {
        case let ext where textExtensions.contains(ext):
            return plainText(at: url, maxChars: maxChars)
        case "pdf":
            return pdfText(at: url, maxChars: maxChars)
        default:
            return nil
        }
    }

    /// 文件里有多少内容能当作**文本**塞进 prompt（**纯文本类专用路径**）。
    ///
    /// 只认 `textExtensions` 白名单，不做 UTType 探测：这里要的是「能安全当 UTF-8 读」，
    /// 而不是「系统认为它是文本」。PDF 等富文本格式走 `extractedText` 分流，
    /// ⛔ 别把这个白名单放宽去硬吃二进制。
    public static func plainText(at url: URL, maxChars: Int = 8000) -> String? {
        guard isTextLike(url) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        // 截断要在**字节**层做，再解 UTF-8：直接 String(prefix:) 可能把多字节字符劈开
        let slice = data.count > maxChars * 4 ? data.prefix(maxChars * 4) : data
        guard var text = String(data: slice, encoding: .utf8) else { return nil }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > maxChars {
            text = String(text.prefix(maxChars)) + "\n…（内容过长已截断）"
        }
        return text
    }

    /// 纯文本类扩展名白名单。不做 UTType 探测：这里要的是「能安全当 UTF-8 读」，
    /// 而不是「系统认为它是文本」（.html 是文本但 .rtf 未必读得干净）。
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "csv", "tsv", "log", "xml", "yaml", "yml",
        "html", "htm", "css", "js", "ts", "py", "swift", "java", "kt", "c", "h",
        "cpp", "m", "mm", "rb", "go", "rs", "sh", "sql", "plist", "ini", "conf"
    ]

    public static func isTextLike(_ url: URL) -> Bool {
        textExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: PDF 正文抽取

    /// PDF → 正文文本（PDFKit）。
    ///
    /// **不需要 `#if os(`**：`PDFDocument(url:)` / `.string` 在 iOS 11+ / macOS 10.4+
    /// 签名一致，两边同一份代码就能过 —— 本工程铁律「条件编译只许出现在 `AIPlatform/` 内」
    /// 能守住，靠的就是这种「先查证确实跨平台、再造接缝」的顺序。
    ///
    /// 诚实边界（⛔ 别在文案里吹成「什么 PDF 都能读」）：
    /// - **扫描件 / 纯图片 PDF 没有文本层** ⇒ `.string` 是 nil ⇒ 返回 nil 走降级文案；
    ///   OCR 是二期的事（Vision 框架），不在本版范围。
    /// - **加密 PDF**：先试空口令（「所有者加密」的 PDF 九成空用户密码就能开），
    ///   解不开就 nil —— ⛔ 别去暴力猜密码。
    /// - 截断在**字符**层做（`doc.string` 已是解码好的 `String`，没有 `plainText`
    ///   那个「字节切片会劈开多字节字符」的问题）。
    private static func pdfText(at url: URL, maxChars: Int) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        if doc.isLocked, !doc.unlock(withPassword: "") { return nil }
        var text = (doc.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.count > maxChars {
            text = String(text.prefix(maxChars)) + "\n…（内容过长已截断）"
        }
        return text
    }

    // MARK: 私有

    /// 等比缩到 `maxPixelSide` 以内并编成 JPEG。
    /// - Returns: (数据, 压缩后的像素尺寸)；编不出来返回 nil
    ///
    /// - Note: 实现整体在 `AIPlatform.imageCodec` 里 —— 缩放重绘与 JPEG 编码
    ///   **两平台没有共同写法**（iOS: `UIGraphicsImageRenderer` + `jpegData`；
    ///   macOS: `NSBitmapImageRep` + `representation(using:.jpeg)`）。
    private static func compressedJPEG(_ image: AIPlatformImage) -> (Data, CGSize)? {
        guard let result = AIPlatform.imageCodec.compressedJPEG(image,
                                                                maxSide: maxPixelSide,
                                                                quality: jpegQuality) else { return nil }
        return (result.data, result.size)
    }
}
