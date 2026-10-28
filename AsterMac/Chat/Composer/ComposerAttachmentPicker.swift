//
//  ComposerAttachmentPicker.swift
//  AsterMac
//
//  输入区「+」菜单背后那两件事：**截图提问** 与 **上传文件或图片**；
//  外加 2026-09-26 加的第三条来源：**从访达把文件拖进会话页**。
//
//  ## 为什么这几件事收在一个文件里
//  它们是同一类动作（「往输入框里塞一个附件」），只是**来源不同**：
//  系统截图工具 / 系统文件选择器 / 拖拽会话。调用方只关心
//  「拿到了几个附件 / 用户取消了 / 失败了」，所以三条路汇成同一个返回类型
//  —— 调用方不必为每一种来源各写一遍错误处理。
//
//  ## 🔴 三条路**共用同一个收尾**（`apply(_:to:)`）与同一个落地循环（`importURLs(_:)`）
//  「选了 3 个文件、其中 1 个读不进来」时该说什么、取消时该不该说话 —— 这些口径
//  必须在三条路上**逐字一致**。各写一份的后果是「拖进来读不进来时静默、选文件时说话」，
//  而用户完全无法理解为什么同样是放不进去，一个说一个不说。
//  ⇒ 新增第四条来源时，也**只加一个「怎么拿到 URL」的函数**，收尾照旧复用。
//
//  ## ⛔ 统一**不过滤类型**（截图那条除外，它只可能出图）
//  文件选择器与拖拽都**不做类型过滤**：这里的「文件」是任意的。
//  加了过滤反而会把用户想发的文件挡在外面，而附件面板上什么都看不出来（静默丢弃最难查）。
//  图片与别的文件的分叉发生在 `importAttachment(at:)` 里（图片压缩、其余原样拷）——
//  那是**落地口径**，不是选取口径。
//
//  ## 落地口径：一律走业务层的 `AIAttachmentStorage`
//  ⛔ **不要在这里自己写文件、自己压缩**。业务层那两条铁律（先拷进沙盒再用 /
//  图片落地即压缩到长边 1600）是 iOS 侧踩出来的，Mac 这边照用同一套：
//    - 图片（含截图）→ `importImage`：压缩 + 落盘 + 预热 data URL；
//    - 其余文件    → `importFile` ：拷进沙盒，不解析内容。
//  自己再实现一遍的后果是「同一个附件在两端的体积 / 名字口径不一样」。
//
//  ## 两个系统交互的坑（都实测过）
//  ① **`screencapture -i` 是交互式的**：它要等用户拉完选区才退出。所以必须
//     `await` 它的退出，**绝不能**同步等 —— 那会把主线程卡到用户点完为止。
//  ② **取消不是失败**：用户按 Esc 时 `screencapture` 退出码是 1 且不落文件。
//     那要当成 `.cancelled`（静默），不能弹一句「截图失败」—— 用户自己取消的。
//
//  ⚠️ 关于屏幕录制权限：`screencapture` 抓的是**别的** App 的窗口，所以要在
//     「系统设置 → 隐私与安全性 → 屏幕录制」里勾上本 App。**没勾时它不一定报错**
//     （可能落一张全黑/空图），所以 `captureScreenshot` 里**先预检**再说 ——
//     否则用户拉完选区才发现白干，且不知道该去哪儿开。
//

import AppKit
import CoreGraphics
import UniformTypeIdentifiers
import AICore

enum ComposerAttachmentPicker {

    /// 一次选取的结果。**三种结局分开**，调用方按它们分别处理
    /// （取消不提示、失败要说话、成功就加进待发送列表）。
    ///
    /// - Note: `picked` 带一个 `note`：多选时可能「一部分成功、一部分读不进来」，
    ///   那既不是失败（附件已经进沙盒了，没理由整批丢掉）也不能沉默
    ///   （用户会以为少掉的那个也发过去了）。
    enum Outcome {
        case picked([AIAttachment], note: String?)
        case cancelled
        case failed(String)
    }

    /// 系统截图工具的路径。⚠️ 写全路径，不走 `PATH`（App 的环境变量里未必有 `/usr/sbin`）。
    private static let screencapturePath = "/usr/sbin/screencapture"

    // MARK: - 截图提问

    /// 拉系统选区截一张图，导入成图片附件。
    ///
    /// - Note: 用系统的 `screencapture -i` 而不是 `ScreenCaptureKit` + 自绘选区层：
    ///   后者要自己写一个跨屏全屏透明窗口 + 拖拽选区 + 坐标换算（Retina 缩放、多屏偏移），
    ///   而且**离屏渲染台验不了拖拽**（`ImageRenderer` 不模拟鼠标）—— 那等于写一段没验过的交互。
    ///   系统工具顺带还有「空格切窗口模式」这些用户已经熟悉的操作。
    static func captureScreenshot() async -> Outcome {
        // 🔴 **先查屏幕录制权限，再动手**。
        //    没有权限时 `screencapture` 不一定报错 —— 它可能就落一张黑图，用户拉完选区
        //    才发现白干了（排查成本极高）。这里提前拦下来，并把「去哪儿开」直接说出来。
        //    `CGRequestScreenCaptureAccess()` 会弹一次系统提示（同一条提示系统只弹一次）。
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            // ⚠️ 提示条是**纯文本**（`ToastBar` 不做 Markdown）—— 别在里面写 `**强调**`，
            //    那几个星号会原样显示出来。
            return .failed(L("还没有「屏幕录制」权限。")
                + L("去「系统设置 → 隐私与安全性 → 屏幕录制」里勾上本 App，")
                + L("然后退出重开本 App（授权要重启才生效），再试一次。"))
        }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("starry-shot-\(UUID().uuidString).png")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: screencapturePath)
        // -i 交互式选区（空格键可切「窗口」模式）；-x 静音；-t png 存 PNG
        task.arguments = ["-i", "-x", "-t", "png", temp.path]

        let status: Int32
        do {
            status = try await run(task)
        } catch {
            return .failed(String(format: L("系统截图工具起不来：%@"), error.localizedDescription))
        }

        guard status == 0, FileManager.default.fileExists(atPath: temp.path) else {
            // 退出码 1 = 用户按 Esc 取消（**不是**错误）
            if status == 1 { return .cancelled }
            return .failed("截图没成功（退出码 \(status)）。"
                + L("若一直失败，去「系统设置 → 隐私与安全性 → 屏幕录制」里确认本 App 已勾上。"))
        }
        defer { try? FileManager.default.removeItem(at: temp) }

        // 🔴 读盘 + 压缩编码放到**后台**：一张 5K 截图缩到长边 1600 再编 JPEG
        //    在主线程上是几十上百毫秒的卡顿（就在用户刚拉完选区那一拍）。
        //    ⚠️ 这是**刻意的跨线程 AppKit 绘制**：`importImage` 内部会开一个
        //    `NSGraphicsContext(bitmapImageRep:)` 画进离屏位图（见 `AIPlatformServices+macOS`）。
        //    离屏位图绘制不碰窗口系统，且 `NSGraphicsContext.current` 是**线程局部**的，
        //    所以这里安全；真出问题也只会是「图不对」而不是崩（返回 nil → 提示条说话）。
        return await Task.detached(priority: .userInitiated) {
            guard let image = NSImage(contentsOf: temp) else {
                return Outcome.failed(L("截出来的图读不出来"))
            }
            guard let attachment = AIAttachmentStorage.importImage(image) else {
                return Outcome.failed(L("截图存不进附件目录（磁盘满了？）"))
            }
            return Outcome.picked([attachment], note: nil)
        }.value
    }

    // MARK: - 上传文件或图片

    /// 系统文件选择器（可多选）。
    ///
    /// - Note: **不过滤类型** —— 为什么见文件头「统一不过滤类型」那条。
    ///
    /// - Note: 沙盒下 `NSOpenPanel` 由 Powerbox 代为选择，选中的文件会**自动**授权给本 App
    ///   （工程里的 `ENABLE_USER_SELECTED_FILES = readonly` 就是它）。
    ///   所以拿到 URL 之后能直接读 —— 但读之前仍要包一层安全作用域，见 `importAttachment`。
    static func chooseFiles() -> Outcome {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = L("添加")
        panel.message = L("选择要一起发给 AI 的图片或文件")

        guard panel.runModal() == .OK else { return .cancelled }
        return importURLs(panel.urls)
    }

    // MARK: - 从访达拖进来（2026-09-26 加）

    /// 拖拽会话给的是 `NSItemProvider` 的数组 —— 先把其中的文件 URL **收齐**，
    /// 再交给 `importURLs` 走**与文件选择器逐字相同**的那条落地。
    ///
    /// ## 为什么先收齐、而不是收到一个就落地一个
    /// ① 顺序：收齐才能保持「用户拖进来的那个顺序」（`addAttachments` 是按数组顺序排的）；
    /// ② 提示：批量落地只会出一条「有 N 个读不进来」——
    ///    一个一个落地会连弹 N 条，把提示条刷爆（用户根本来不及读）。
    ///
    /// ## 为什么用 `await` 串行取、而不是并发收
    /// 并发 + 计数器也能收齐，但**顺序会乱**（谁先回来谁在前）。而 providers 通常只有
    /// 一两个、每个的 `loadObject` 都是本地读元数据（微秒级），串行的代价可以忽略。
    ///
    /// - Note: 拖进来的 URL **不需要**安全作用域：拖拽本身就把 access 交给了本 App
    ///   （与 `NSOpenPanel` 的 Powerbox 授权同性质）。但 `importAttachment` 里那层
    ///   `startAccessingSecurityScopedResource()` 依然要留着 —— 它返回 false 时是安全的
    ///   空操作，留着才能让「选文件」那条路继续成立。**一个实现伺候两条来源**正是要的效果。
    static func collectDropped(_ providers: [NSItemProvider]) async -> Outcome {
        var urls: [URL] = []
        for provider in providers {
            if let url = await fileURL(from: provider) { urls.append(url) }
        }
        // 一个文件都没收出来：**这不是「取消」**（用户明确做了「放进来」这个动作），
        // 必须说话。最常见的真实情形是从浏览器拖一段**选中文字**过来 ——
        // 它确实不是文件，而用户以为能当上下文发。
        guard !urls.isEmpty else {
            return .failed(L("拖进来的不是文件。从访达拖文件或图片过来，或者用输入框的「+」选一个。"))
        }
        return importURLs(urls)
    }

    /// 从一个 `NSItemProvider` 里取文件 URL。不是文件就返回 nil ——
    /// **跳过这一个、不让整批失败**（与 `importURLs` 内部的「部分失败」同一个口径）。
    ///
    /// ⚠️ 完成回调**不在主线程**（`NSItemProvider` 的既定行为，与它是不是 SwiftUI 无关），
    ///    所以这里用 continuation 把结果交回 `await` 那一侧，由调用方在 `@MainActor` 上收尾。
    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            // ⚠️ `loadObject(ofClass:)` 的返回值是 `Progress`，这里**刻意不持有**：
            //    单个文件元数据的读取没有可取消的中间态（取消反而可能让 continuation 永不 resume）。
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    // MARK: - 一批 URL → 一批附件（选文件 / 拖拽共用）

    /// 逐个落地，**部分失败不打断成功的那部分**。
    ///
    /// - Returns: 失败的分两类 —— 全失败是 `.failed`、部分失败是 `.picked(note:)`。
    ///   两种都必须说话：附件已经进了沙盒，没理由整批丢掉；但不说一声，
    ///   用户会以为少掉的那个也发过去了。
    static func importURLs(_ urls: [URL]) -> Outcome {
        var items: [AIAttachment] = []
        var failedNames: [String] = []
        var folderNames: [String] = []

        for url in urls {
            // 🔴 **文件夹必须先拦住**（2026-09-26 加，拖拽引进来的新输入类别）。
            //    下面 `AIAttachmentStorage.importFile` 用的是 `copyItem` ——
            //    一个文件夹会被**递归整棵拷进沙盒**。用户顺手拖一个几个 G 的工程目录进来
            //    就是灾难（拷完才发现发不出去，且沙盒里多了一大坨）。而拖拽**必然**会遇到
            //    这一类：访达里文件夹和文件长得一样，拖错是常事。
            //    ⚠️ 文件选择器那条路天然遇不到（`panel.canChooseDirectories = false`）——
            //       正因为这样，这道闸门只能加在**共用的这一层**，不能加在 `collectDropped` 里
            //       （那样选文件那条路就少了同样的保护）。
            if isDirectory(url) {
                folderNames.append(url.lastPathComponent)
                continue
            }
            if let attachment = importAttachment(at: url) {
                items.append(attachment)
            } else {
                failedNames.append(url.lastPathComponent)
            }
        }

        // 一个都没成：把两种原因分别说清（说成「读不进来」会误导 —— 文件夹不是读不进来）。
        if items.isEmpty {
            if !folderNames.isEmpty, failedNames.isEmpty {
                return .failed(L("文件夹不能一条发出去。请拖它里面的文件，或者用输入框的「+」选一个。"))
            }
            return .failed(failedNames.isEmpty
                ? L("没有可添加的文件")
                : String(format: L("这些文件读不进来：%@"), failedNames.joined(separator: L("、"))))
        }

        // 部分失败不打断成功的那部分：附件已经进了沙盒，没理由整批丢掉。
        // 但**必须说一声**，否则用户会以为少掉的那个也发过去了。
        // ⚠️ 只打**名字**不打路径（与列表里其它提示一致），且两个原因合成一条 ——
        //    拖 10 个进来弹两条提示会把提示条刷掉，用户来不及读。
        var reasons: [String] = []
        if !folderNames.isEmpty {
            reasons.append(String(format: L("%d 个文件夹跳过了（文件夹发不了）"), folderNames.count))
        }
        if !failedNames.isEmpty {
            reasons.append(String(format: L("%d 个读不进来：%@"), failedNames.count, failedNames.joined(separator: L("、"))))
        }
        return .picked(items, note: reasons.isEmpty ? nil : reasons.joined(separator: "；"))
    }

    /// 这个 URL 是不是文件夹。
    ///
    /// ⚠️ 先问 `resourceValues`、失败才退回 `hasDirectoryPath`：
    ///   后者看的是 URL 末尾有没有斜杠，而**斜杠不保证有**（访达拖出来的目录通常带，
    ///   但别的来源不一定）。反过来只用 `resourceValues` 也不行 —— 拿不到权限时它抛错，
    ///   而那正是最需要拦住的时候。两条一起用，任一条说「是目录」就按目录处理。
    private static func isDirectory(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
           let isDir = values.isDirectory {
            return isDir
        }
        return url.hasDirectoryPath
    }

    // MARK: - 收尾（三条路共用）

    /// 一次选取结果的统一收尾：成功加进待发送列表、取消静默、失败说话。
    ///
    /// 🔴 **必须是唯一一份**（文件头「三条路共用同一个收尾」那条）。调用方有三处：
    ///   `MacInputBar.pick(_:)`（截图 / 选文件）与 `ChatDetailView` 的 `onDrop`。
    ///   各写一份 switch 的后果是「拖进来失败会弹提示、选文件失败不弹」这类漂移，
    ///   而它**编译得过、review 也看不出来**（两处长得几乎一样）。
    ///
    /// - Note: 标 `@MainActor` 是因为它要写 `model`（`@Observable`，主线程隔离）。
    ///   `collectDropped` 那条路从后台回调里回来，正是靠这一层把执行权搬回主线程。
    @MainActor
    static func apply(_ outcome: Outcome, to model: ChatModel) {
        switch outcome {
        case .picked(let items, let note):
            model.addAttachments(items)
            if let note { model.show(note) }
        case .cancelled:
            // 用户自己取消的（Esc）—— **静默**。弹一句「已取消」纯属噪音。
            break
        case .failed(let message):
            model.show(message)
        }
    }

    /// 一个 URL → 一个附件。
    /// - Returns: 失败返回 nil（调用方跳过这一个，不让整批失败 —— 与业务层同一个口径）
    private static func importAttachment(at url: URL) -> AIAttachment? {
        // 🔴 安全作用域要**自己开**：`AIAttachmentStorage.importFile` 内部只负责拷贝那一段，
        //    而下面读图片（`NSImage(contentsOf:)`）是这里发起的。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true, let image = NSImage(contentsOf: url) {
            return AIAttachmentStorage.importImage(image)
        }
        return AIAttachmentStorage.importFile(at: url)
    }

    // MARK: - 私有

    /// 跑一个进程并等它退出。
    ///
    /// ⚠️ `terminationHandler` **必须在 `run()` 之前**装好：进程可能快到这个 handler
    ///    还没装上就已经退出了（那是竞态，表现是 await 永远不返回）。所以这里把
    ///    `run()` 放进 continuation 里、在装好 handler 之后才调。
    private static func run(_ task: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            task.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try task.run()
            } catch {
                task.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
