import UIKit
import Photos
import PhotosUI
import UniformTypeIdentifiers
import AICore
import StarryKitCore

/// 待发附件（拍照 / 相册图片 / 文件）的**选中、入待发区、出待发区**。
///
/// 四条来路，互相独立、最终都汇到 `appendAttachments`：
/// - 「相机」按钮 → `UIImagePickerController`（`sourceType = .camera`）：系统相机 → **要相机权限**；
/// - 「相册」按钮 → `PHPickerViewController`：独立进程 picker，App 碰不到整个相册 → **免权限**；
/// - 「文件」按钮 → `UIDocumentPickerViewController`：系统「文件」App 同一套 UI，`asCopy: true` 免 security-scoped URL；
/// - 「+」面板下半部分那块**最近照片网格** → 自己读相册列表，**要 `.readWrite` 授权**
///   （见 `importRecentPhoto` / `PhotosLibraryService`）。
///
/// 四条里只有「相机」要相机权限、「网格」要相册权限，所以相册按钮 / 文件按钮在任何授权状态下
/// 都必须照常可用 —— 一次拒绝不该让整个入口作废。
///
/// ## 这里的核心不变量
/// **文件一旦落地就归本 App 沙盒管**（选中那一刻就拷进来，见 `AIAttachmentStorage`）。
/// 于是「谁能删盘」这件事必须精确：
/// - **发送后** → `clearPendingAttachments()`（**不删盘**）：消息已经引用这些文件了；
/// - **新建对话 / 手动删除某项** → 删盘：这些文件从没被任何消息引用过，留着就是沙盒垃圾。
extension AIModuleViewController {

    // MARK: - 呈现 picker

    /// 弹模态时**真正**该由谁去 `present`。
    ///
    /// ☠️ **别直接 `self.present(...)`**（2026-10-12 通话页那条路上发现的既有隐患）：
    /// 那条路里本页**已经被 push 出去**，而 `UINavigationController` 在转场结束后会把
    /// 非栈顶的 `view` 从层级里**摘掉** ⇒ `self.view.window == nil` ⇒ `present` **静默失败**
    /// （控制台只留一条 *whose view is not in the window hierarchy* 的警告，
    ///   用户看到的是「点了那颗钮什么都不发生」，不崩、也不报错）。
    /// ⇒ 一律解析到**当前在屏上**的那个：先取同一导航栈的栈顶（通话页就在那儿），
    ///    再往下钻已经呈现出来的模态（避免叠在别人后面）。
    /// 普通路径（输入栏的相机 / 相册 / 文件按钮）解析结果就是本页自己，行为不变。
    var attachmentPresenter: UIViewController {
        var vc: UIViewController = navigationController?.topViewController ?? self
        while let presented = vc.presentedViewController { vc = presented }
        return vc
    }

    /// 相机：打开系统相机拍照。
    ///
    /// **两个入口共用这一个实现**：输入栏左侧那个相机按钮（`cameraEvent`）和
    /// 「+」面板里的「相机」入口（`attachmentEvent(.camera)`）—— 对用户是同一件事，
    /// 没必要做成两套（两套就是两份权限处理、两份降级提示）。
    ///
    /// ## 为什么用 `UIImagePickerController` 而不是自建 `AVCaptureSession`
    /// 系统相机自带对焦 / 曝光 / 闪光灯 / 前后摄切换 / 缩放，**拿到的还是系统多帧合成的结果**
    /// （HDR、夜景都在系统那一侧做完）—— 自建要把这套复刻一遍，代码量上一个量级，
    /// 成片质量反而更差。与「相册用 `PHPicker`、文件用 `UIDocumentPicker`」同一个取向：
    /// 能借系统 UI 就不自己画。
    ///
    /// ## 三道门禁，顺序不能换
    /// ① **设备有没有相机**：模拟器、部分 iPad 没有。必须先问设备 —— 顺序反了的话
    ///    会先弹「允许访问相机」，用户点完允许才发现根本拍不了；
    /// ② **权限**：走全项目统一的 `StarryPermission`（内部是 `AVCaptureDevice.requestAccess`）；
    /// ③ 起 picker。被拒时给一条**能真的走下去**的路（见 `showCameraPermissionGuide`）。
    ///
    /// ⚠️ `UIApplication` 上那个是 `isSourceTypeAvailable(_:)` —— **类型方法**，不是实例方法。
    ///
    /// ⚠️ 面板不用做任何配合（和相册 / 文件一致）：相机是全屏模态，盖上来又滑走，
    /// 面板与输入栏原样待在原地 —— 它们跟系统键盘没关系，系统也就无从把它们收走。
    ///
    /// ## `onUnavailable`（2026-10-11）
    /// 上面两道门禁都是**提前 return** 的出口。普通路径上不需要回执（用户看到 toast 就完了），
    /// 但**通话页那条路必须有** —— 那边在等着 `Bool` 才能决定接回哪个状态（见
    /// `presentImageSourceForVoiceCall`）。默认 `nil`，原有调用点不用改。
    ///
    /// ## 🔴 2026-10-12：它现在是通话页那颗钮的**唯一**实现
    /// 用户明确「第三个按钮变成直接拍照，不要相册了」⇒ 通话页那颗钮**直接调本方法**，
    /// 不再经过任何「来源选择」。⇒ 这里的每一条失败出口（没相机 / 权限被拒）都必须把
    /// `onUnavailable` 叫到，那边才不会卡在"麦已关、状态没变"的半路上。
    func presentCamera(onUnavailable: (() -> Void)? = nil) {
        // 相机一上来就盖满全屏，此时还挂着键盘没有意义（回来也不会自动恢复输入态）
        view.endEditing(true)

        // ① 先问设备。模拟器上 `sourceType = .camera` 会直接把 App 崩掉，
        //    所以这一步不是「优化」，是必须。
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            showToast(L("当前设备没有可用的相机"))
            onUnavailable?()
            return
        }

        // ② 再问权限。`request` 的回调在主线程，且返回时一定已经有结论
        //    （`.notDetermined` 不会被回上来）。
        StarryPermission.request(.camera) { [weak self] status in
            guard let self = self else { return }
            switch status {
            case .authorized:
                self.presentCameraPicker()
            case .denied, .restricted:
                self.showCameraPermissionGuide()
                onUnavailable?()
            case .notDetermined:
                break   // 写全 switch；`request` 之后不会出现这一档
            }
        }
    }

    /// 真正把相机模态推出来（权限已到手）。
    private func presentCameraPicker() {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        // 拍完直接「使用照片」，不做裁剪 —— 发给 AI 的图不需要方形裁切那一步，
        // 多一个编辑页只是多一次点击
        picker.allowsEditing = false
        picker.delegate = self
        // 由**在屏上**的那个 VC 弹（见 `attachmentPresenter`：通话页那条路里本页的 view 已被摘掉）
        attachmentPresenter.present(picker, animated: true)
    }

    /// 相机权限被拒 → 给一条真的能走下去的路。
    ///
    /// 这里用 alert 而不是 toast：toast 只能干说一句「请去设置里打开」，用户知道了也没处点；
    /// alert 能带一个「去设置」直接把本 App 的系统设置页推出来。
    private func showCameraPermissionGuide() {
        let alert = UIAlertController(title: L("无法使用相机"),
                                      message: L("请在系统设置里允许访问相机，才能拍照发给 AI。"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L("去设置"), style: .default) { _ in
            StarryPermission.openSettings()
        })
        attachmentPresenter.present(alert, animated: true)
    }

    /// 相册：`PHPickerViewController`（iOS 14+）。
    ///
    /// 选它的两个理由：
    /// ① **不需要相册权限** —— 它在独立进程里跑，只把用户勾中的那几张交给 App，
    ///    App 从头到尾碰不到整个相册，所以不用弹「允许访问所有照片」；
    /// ② 第三方相册库（TZImagePickerController 之类）都建立在 `PHPhotoLibrary` 上，
    ///    代价是**申请整个相册的读写权限** —— 为了一个 picker 付这个代价不划算。
    ///
    /// ⚠️ 与面板里那块最近照片网格的分工：网格要**自己列出**照片，所以必须拿
    /// `.readWrite` 授权（`NSPhotoLibraryUsageDescription` 现在有了）。两条路都留着 ——
    /// 授权被拒时网格退化成一行引导，这个按钮照旧可用。
    ///
    /// 只筛 `.images`：视频发给模型的链路还没做（模型侧也不收），
    /// 让用户选了却没反应，比一开始就筛掉更糟。
    ///
    /// ## `remaining`（2026-10-08）
    /// 预览条末尾那颗「＋」进来时**已经有一批待发了**，所以上限要按**空出来的位数**给。
    /// ⚠️ 不给的话：已有 8 张时 `selectionLimit` 仍是 9，用户能勾 9 张 →
    ///   `appendAttachments` 只收下 1 张、其余 8 张删盘 + 一句 toast ⇒ 白选一场。
    ///   传 `nil` = 按总上限（面板入口「相册」那种「当前无待发」的情形）。
    func presentPhotoPicker(remaining: Int? = nil) {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        let room = remaining ?? Self.maxAttachmentCount
        // 🔴 `selectionLimit` 传 0（= 不限）是**合法**的，所以必须在这里收口，
        //    不能指望系统替我们拦 —— 让用户在「最多 9 个」的会话里勾 50 张才是真的错。
        guard room > 0 else {
            showToast(String(format: L("最多带 %d 个附件"), Self.maxAttachmentCount))
            return
        }
        configuration.selectionLimit = room
        // `.current`：要原图，不让系统为了「兼容播放」把图转码
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        // 面板**不用**做任何配合：它是输入栏自己的子视图，picker 盖上来又滑走，
        // 面板和输入栏原样待在原地（面板与键盘无关，系统也就没有机会把它收走）。
        attachmentPresenter.present(picker, animated: true)
    }

    /// 文件：`UIDocumentPickerViewController`。
    ///
    /// `asCopy: true` 是关键：系统直接把文件**拷一份**到 tmp 给 App，
    /// 于是完全不用碰 security-scoped URL 那套（`startAccessingSecurityScopedResource`
    /// + `NSFileCoordinator`）——反正我们本来就要把它拷进自己的沙盒。
    /// 不设的话拿到的是原文件的安全作用域 URL，要成对 start/stop，还得处理 bookmark。
    func presentFilePicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        attachmentPresenter.present(picker, animated: true)
    }

    // MARK: - 待发区增删

    /// 附件进待发区。数量上限与「超出的部分删盘」都收在这一处，选图 / 选文件 / 项目资料三条路共用。
    ///
    /// ⚠️ 自 2026-10-21 起改为 **internal**（原 `private`）：`+Projects.swift` 里那条
    /// 「从项目资料带一份进来」也要走这里，否则上限与超量删盘会变成两份实现。
    func appendAttachments(_ items: [AIAttachment]) {
        guard !items.isEmpty else { return }
        let room = max(0, Self.maxAttachmentCount - pendingAttachments.count)
        guard room > 0 else {
            // 超出的已经在沙盒里了 —— 直接删掉，不然就是攒垃圾
            items.forEach { AIAttachmentStorage.remove(at: $0.fileURL) }
            showToast(String(format: L("最多带 %d 个附件"), Self.maxAttachmentCount))
            return
        }
        if items.count > room {
            items.dropFirst(room).forEach { AIAttachmentStorage.remove(at: $0.fileURL) }
            showToast(String(format: L("最多带 %d 个附件"), Self.maxAttachmentCount))
        }
        pendingAttachments.append(contentsOf: items.prefix(room))
        inputToolbar.setAttachments(pendingAttachments)
    }

    /// 从待发区删掉一项（预览条上那个 ✕）。
    ///
    /// **顺手删盘**：用户撤销预览就代表这张图不会被发出去了，
    /// 不删的话沙盒里会攒下一堆没有任何消息引用的孤儿文件。
    func removeAttachment(at index: Int) {
        guard pendingAttachments.indices.contains(index) else { return }
        let removed = pendingAttachments.remove(at: index)
        AIAttachmentStorage.remove(at: removed.fileURL)
        inputToolbar.setAttachments(pendingAttachments)
    }

    /// 清空待发附件（发送后 / 新建对话时调用）。
    /// - Parameter removeFiles: 是否连沙盒文件一起删。
    ///   **发送后要传 false** —— 消息已经引用这些文件了，删了历史会话就会显示不出图；
    ///   新建对话时传 true —— 那些文件从没被引用过，不删就是纯垃圾。
    func clearPendingAttachments(removeFiles: Bool = false) {
        guard !pendingAttachments.isEmpty else { return }
        if removeFiles {
            pendingAttachments.forEach { AIAttachmentStorage.remove(at: $0.fileURL) }
        }
        pendingAttachments.removeAll()
        inputToolbar.setAttachments([])
    }

    // MARK: - 最近照片网格（「+」面板下半部分那块）

    /// 网格里点了一张缩略图 → 取整图 → 落盘 → 进待发区。
    ///
    /// 与 `PHPicker` 那条路（`importPickedImages`）最终**汇到同一处**：
    /// 都要 `AIAttachmentStorage.importImage` 压到长边 1600 才进预览条 ——
    /// 所以下面这行 `appendAttachments` 才能和相册按钮完全共用。
    ///
    /// 取图这一步**会等一下**：`requestFullImage` 允许联网，iCloud 里没下载到本机的原图
    /// 要走一次下载（这也是网格缩略图那侧刻意不等 iCloud 的原因 —— 那是被动加载，
    /// 让用户对着空白格等没有道理；这里是用户主动点的一张，等得起）。
    func importRecentPhoto(_ asset: PHAsset) {
        PhotosLibraryService.shared.requestFullImage(for: asset) { [weak self] image in
            guard let self = self else { return }
            guard let image = image, let attachment = AIAttachmentStorage.importImage(image) else {
                self.showToast(L("图片读取失败，换一张试试"))
                return
            }
            self.appendAttachments([attachment])
        }
    }

    // MARK: - 通话页「拍照提问」（2026-10-11 加；2026-10-12 起**直接开相机**）

    /// 通话页那颗钮 → **直接开相机** → 拍到的图**立刻发一条**。
    ///
    /// ## 🔴 2026-10-12：不再有「来源选择」那一层
    /// 用户明确「第三个按钮变成直接拍照，不要相册了」⇒ 本方法**直接调 `presentCamera`**。
    /// ⛔ 别再把 `.actionSheet`（拍照 / 从相册选择）挂回来 —— 那是**被明确否掉**的形态；
    ///    相册仍可从输入栏的相册按钮 / 「+」面板进（那条路照旧），只是不再从通话页进。
    ///
    /// ## 为什么 picker 由**本页**弹，而不是通话页自己弹
    /// 相机要"设备有没有相机 + `StarryPermission` + 失败引导"三道门禁 —— 全在本页
    /// （`presentCamera`）。通话页再写一份必然漂（两份权限处理、两份降级提示），
    /// 而且"落盘 + 发送"本来就只该有一条管线（`AIAttachmentStorage` + `send`）。
    /// ⇒ 通话页只交出 `onRequestImage` 一个出口，其余全在这里。
    /// ☠️ 连"由谁弹"都得先解析出来 —— 本页这时**已经被 push 出去**（`view.window == nil`），
    ///    直接 `self.present` 会**静默失败**（见 `attachmentPresenter` 那段）。
    ///
    /// ## 与普通附件路径的**唯一**差别：不进待发区
    /// 通话页没有"待发"这个概念 —— 拍完就该发出去，用户手上还举着手机在打电话。
    /// 分流靠 `voiceCallImageCompletion` 有没有值（见相机回调里的 `isVoiceCallPath`）。
    ///
    /// ## 正文留空
    /// `send("", attachments:)` 是**合法**的（`AIChatManager` 的 `prompt` 明确允许为空 ——
    /// 只发附件），会话标题会退化成 `attachmentTitlePlaceholder` 占位文案。
    /// ⛔ 别在这里编一句"请描述这张图"塞进去：AI 看着图就知道该说什么，
    ///    而那句话会**永久留在聊天记录里**，用户回头翻会觉得莫名其妙。
    ///
    /// - Parameter completion: `true` = 真的发出去了。☠️ **每一条出口都要调它一次**
    ///   （没相机 / 权限被拒 / 用户取消 / 读图失败 / `send` 被拦下），否则通话页停在半路。
    func presentImageSourceForVoiceCall(completion: @escaping (Bool) -> Void) {
        voiceCallImageCompletion = completion

        #if DEBUG
        // 🧪 验收钩子（`STARRY_CALL_PHOTO=1`）：模拟器上这个相机 **没法被驱动**
        //    （投不出合成触摸、模拟器也没有相机），这里用一张**当场画出来的图**替代
        //    "用户刚拍的那张"。除此之外全是真链路：落盘 → `send` → 通话页切「正在思考」
        //    → 回复 → 念出来。
        //    ⚠️ 短路点放在**开相机之前**：那一步正是无人值守时走不过去的地方。
        if ProcessInfo.processInfo.environment["STARRY_CALL_PHOTO"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self = self else { return }
                guard let image = Self.simulatedPhotoForVoiceCall(),
                      let attachment = AIAttachmentStorage.importImage(image) else {
                    self.showToast(L("图片保存失败，再试一次"))
                    self.finishVoiceCallImage(false)
                    return
                }
                self.sendImportedForVoiceCall(attachment)
            }
            return
        }
        #endif

        // 🔴 就这一步：**直接开相机**（自带"设备有没有相机"与权限两道门禁，以及各自的失败提示）。
        //    两道门禁都是提前 return 的出口，所以必须把回执补上 —— 见 `onUnavailable` 那段注释。
        presentCamera { self.finishVoiceCallImage(false) }
    }

    /// 通话页那条路的**唯一**回执出口。
    /// 调完即清 —— 不清的话下一次普通选图会被上一次的完成块误当成"通话页那条路"。
    func finishVoiceCallImage(_ started: Bool) {
        let handler = voiceCallImageCompletion
        voiceCallImageCompletion = nil
        handler?(started)
    }

    /// 附件**已经落盘** → 发一条只有附件的消息。
    /// ☠️ 没发出去就把它删掉：没被任何消息引用的文件留着就是纯沙盒垃圾
    ///    （与 `removeAttachment` 那条"撤销预览就删盘"同一条道理）。
    private func sendImportedForVoiceCall(_ attachment: AIAttachment) {
        let started = send("", attachments: [attachment])
        if !started { AIAttachmentStorage.remove(at: attachment.fileURL) }
        finishVoiceCallImage(started)
    }

    #if DEBUG
    /// 🧪 造一张"用户刚选的照片"：纯色底 + 一行字 —— 好在会话页截图里一眼认出来
    /// （截图要能证明"这张图真的发进去了"，一张纯色块证明不了）。
    private static func simulatedPhotoForVoiceCall() -> UIImage? {
        let size = CGSize(width: 640, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor(red: 0.16, green: 0.34, blue: 0.62, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = "STARRY-CALL-PHOTO 验收用图"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 34, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2,
                                  y: (size.height - textSize.height) / 2),
                      withAttributes: attributes)
        }
    }
    #endif
}

// MARK: - 相册选图的收集器

/// 收集 `PHPicker` 的异步读取结果。
///
/// 用引用类型而不是在闭包里改 `var` 数组：多个 provider 的回调在不同线程上跑，
/// 直接写同一个数组既会触发并发访问检查、语义上也不保证安全。锁收在这里面。
private final class PickedImageCollector {

    private let lock = NSLock()
    private var storage: [AIAttachment?]

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    /// 按**原始下标**写回 —— 并发回调的完成顺序是乱的，靠下标才能保持用户选择的先后
    func set(_ item: AIAttachment?, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard storage.indices.contains(index) else { return }
        storage[index] = item
    }

    var items: [AIAttachment] {
        lock.lock()
        defer { lock.unlock() }
        return storage.compactMap { $0 }
    }
}

// MARK: - PHPickerViewControllerDelegate（相册）

extension AIModuleViewController: PHPickerViewControllerDelegate {

    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        // 取消时 results 为空、照样走这里 —— 两条出口都只是收场，面板不用管（它没被动过）
        picker.dismiss(animated: true)

        // ⚠️ 这里**没有**通话页的分支：那颗钮已经是「直接开相机」（2026-10-12 用户明确
        //    「不要相册了」）⇒ 从通话页进来时 `voiceCallImageCompletion` 一定为 nil，
        //    相册这条路上不可能有它的值。⛔ 别为了"将来可能还要相册"把分支加回来。
        guard !results.isEmpty else { return }
        importPickedImages(results)
    }

    /// 把选中的图**读完并落盘**，再进预览条。
    ///
    /// 必须一次读完：`NSItemProvider` 背后是系统给的临时文件，回调返回后随时可能被回收，
    /// 「先记住 provider、以后再读」这条路走不通。
    private func importPickedImages(_ results: [PHPickerResult]) {
        let collector = PickedImageCollector(count: results.count)
        let group = DispatchGroup()

        for (index, result) in results.enumerated() {
            let provider = result.itemProvider
            guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
            group.enter()
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                defer { group.leave() }
                guard let image = object as? UIImage,
                      let attachment = AIAttachmentStorage.importImage(image) else { return }
                collector.set(attachment, at: index)
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let ordered = collector.items
            guard !ordered.isEmpty else {
                self.showToast(L("图片读取失败，换一张试试"))
                return
            }
            self.appendAttachments(ordered)
        }
    }
}

// MARK: - UIImagePickerControllerDelegate（相机）

/// ⚠️ 必须**同时**实现 `UINavigationControllerDelegate`：`UIImagePickerController` 的
/// `delegate` 声明是 `id<UIImagePickerControllerDelegate, UINavigationControllerDelegate>`，
/// 少一个协议，连 `picker.delegate = self` 那一句都编译不过。
extension AIModuleViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    /// 拍完（点了「使用照片」）。
    public func imagePickerController(_ picker: UIImagePickerController,
                                      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        // 先收模态再处理图：落盘 + 进待发区之后用户立刻能看到预览条多了一张；
        // 模态还挂着的话这些变化全被盖在下面，看起来像「点了没反应」
        picker.dismiss(animated: true)

        // `allowsEditing = false` → 有值的只有 `.originalImage`；`.editedImage` 留个保险
        // （哪天改成允许裁剪，这里不用跟着改）
        guard let image = (info[.originalImage] as? UIImage) ?? (info[.editedImage] as? UIImage) else {
            showToast(L("拍照失败，再试一次"))
            return
        }

        // 落盘是同步重活（重绘到长边 1600 + JPEG 编码）→ 挪到后台，
        // 与「相册选图」那条路（`loadObject` 的回调本来就在后台）保持一致
        //
        // 🔴 两条路在这里分岔（2026-10-11）：**通话页那条路「立刻发一条」**，
        //    不进待发区、不等用户再按发送 —— 通话页没有"待发"这个概念。
        //    分岔判据只看 `voiceCallImageCompletion` 有没有值（见那个属性的注释）。
        let isVoiceCallPath = (voiceCallImageCompletion != nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let attachment = AIAttachmentStorage.importImage(image)
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let attachment = attachment else {
                    self.showToast(L("图片保存失败，再试一次"))
                    // ⚠️ 通话页那条路**必须有回执**，否则它会停在"麦已关、状态没变"的样子上
                    if isVoiceCallPath { self.finishVoiceCallImage(false) }
                    return
                }
                if isVoiceCallPath {
                    self.sendImportedForVoiceCall(attachment)
                } else {
                    // 与「相册」「最近照片网格」两条路汇到同一处
                    self.appendAttachments([attachment])
                }
            }
        }
    }

    /// 点「取消」/ 下拉关闭。面板与输入栏原样留着，什么都不用做。
    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        // 通话页那条路：取消也要回执（不然那边一直等着，麦是关的、提示语却还写着"说话"）
        finishVoiceCallImage(false)
    }
}

// MARK: - UIDocumentPickerDelegate（文件）

extension AIModuleViewController: UIDocumentPickerDelegate {

    public func documentPicker(_ controller: UIDocumentPickerViewController,
                               didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        // 拷贝放到后台：从 iCloud 选一个还没下载到本机的文件时，这次拷贝会**同步等下载**，
        // 放主线程就是界面整个卡住（而且没有超时）。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let imported = urls.compactMap { url -> AIAttachment? in
                // asCopy 之后 tmp 里的文件名就是原文件名，直接拿来当展示名
                AIAttachmentStorage.importFile(at: url, displayName: url.lastPathComponent)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard !imported.isEmpty else {
                    self.showToast(L("文件读取失败"))
                    return
                }
                self.appendAttachments(imported)
            }
        }
    }

    /// 取消（点「取消」或下拉关闭）。面板不用管 —— 它一直开着，取消与选中看到的界面完全一样。
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    }
}
