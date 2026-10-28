//
//  PhotosLibraryService.swift
//  AIModule
//
//  「+」面板里那块**最近照片网格**的数据源：相册授权 + 取图。
//
//  为什么要它（而不继续只靠 `PHPicker`）：
//  `PHPickerViewController` 是独立进程 picker，App 从头到尾碰不到整个相册，所以**免权限** ——
//  代价是只能「用户点了才把图递过来」，没法让我们自己列出照片。要在面板里铺一片缩略图，
//  就得拿 `.readWrite` 授权自己去读（Photos 框架没有「只读」这一档）。
//
//  两条路**都留着**：授权被拒时网格退化成一行引导，而「相册」按钮那条路照样能用 ——
//  功能不会因为一次拒绝就整块消失。
//

import Foundation
import Photos
import UIKit
// ⚠️ 必须显式 import：`presentLimitedLibraryPicker(from:)` 由 PhotosUI 定义，
// 而本工程开了 MemberImportVisibility（SPM 的 Package.swift 没开）——
// 缺了就报 "not available due to missing import of defining module 'PhotosUI'"。
// 且访问级别不能低于 Attachment.swift 里的 public import，否则报 ambiguous。
import PhotosUI
import AICore
import StarryKitCore

/// 相册授权态 —— 只保留我们真要区别对待的四档。
///
/// ⚠️ 为什么不直接用 `StarryPermissionStatus`：它把 `.limited`（只授权了部分照片）
/// 归进了 `.authorized`，而网格恰好要区分这一档 —— `limited` 时必须多给用户一个
/// 「管理」入口，否则他勾过的那几张之外的照片永远进不来。
/// **申请动作仍然走 `StarryPermission`**（全项目统一入口），只有状态判断自己来。
enum PhotosAuthState: Equatable {
    /// 还没问过（首次打开「+」面板时才问）
    case notDetermined
    /// 拒绝 / 受限制（家长控制）
    case denied
    /// 只勾了部分照片（iOS 14+ 的「选择照片…」，实际上最常见的授权态）
    case limited
    /// 全部照片
    case authorized

    /// 能不能读到照片（`limited` 也算能读，只是读到的少）
    var canRead: Bool { self == .authorized || self == .limited }
}

/// 相册的读授权 + 取图。取图分**缩略图**与**整图**两条路，参数取向完全相反：
///
/// | | 缩略图（网格里那一片） | 整图（点了一张要发给模型） |
/// |---|---|---|
/// | 时机 | 被动：面板一打开就批量铺 | 主动：用户点了某一格 |
/// | 质量 | 只要够撑满格子 | 长边 1600（与落盘口径一致） |
/// | iCloud | **不等**（等下载格子会长时间空着） | **等**（用户主动点的，值得等一下） |
/// | 回调 | `opportunistic` 两次（先糊后清，避免白块） | `highQualityFormat` 一次 |
final class PhotosLibraryService {

    static let shared = PhotosLibraryService()

    /// 缩略图与整图共用一个 manager。`PHCachingImageManager` 是 `PHImageManager` 的子类，
    /// 顺手拿到「同一张图重复请求」的缓存（面板反复开关时很有用）。
    private let manager = PHCachingImageManager()

    private init() {}

    // MARK: - 授权

    /// 当前授权态（**不弹窗**，随时可问）
    var authState: PhotosAuthState {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// 申请读权限。**只有 `.notDetermined` 会弹系统窗**，已决定过的直接回结果 ——
    /// 所以可以放心在每次打开面板时调，不会反复骚扰用户。
    /// 回调在主线程。
    func requestAuthorization(_ completion: @escaping (PhotosAuthState) -> Void) {
        let current = authState
        guard current == .notDetermined else {
            completion(current)
            return
        }
        // 弹窗走全项目统一的 `StarryPermission`；它回完再自己读一次细粒度状态，
        // 因为它把 `.limited` 并进了 `.authorized`（见 `PhotosAuthState` 的注释）。
        StarryPermission.request(.photoLibrary) { [weak self] _ in
            completion(self?.authState ?? .denied)
        }
    }

    /// 「只授权了部分照片」时，系统那个「管理已选照片」列表（iOS 14+）。
    /// 用户在里面增删之后相册会发变更通知 —— 网格注册了 `PHPhotoLibraryChangeObserver`，会自动刷新。
    func presentLimitedLibraryPicker(from viewController: UIViewController) {
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: viewController)
    }

    /// 跳系统设置（权限被拒后的唯一出路，走 `StarryPermission` 统一入口）
    func openSystemSettings() {
        StarryPermission.openSettings()
    }

    // MARK: - 写入（保存到相册）

    /// 把一张**本地图片文件**存进系统相册（2026-10-08 加，服务「保存到相册」）。
    ///
    /// ## 为什么走 `performChanges` 而不是 `UIImageWriteToSavedPhotosAlbum`
    /// 后者要先把整张图解成 `UIImage`（一张 1600px 的 JPEG 解码后 ≈ 10 MB 峰值），
    /// 而 `PHAssetCreationRequest.addResource(with: .photo, data:)` **直接收 JPEG 字节**，
    /// 全程不解码 —— 附件本来就是 JPEG（见 `AIAttachmentStorage.jpegQuality`），没有转码损失。
    ///
    /// ## 授权
    /// 走 `StarryPermission.request(.photoLibraryAdd)`（`PHAccessLevel.addOnly`，**只写**）：
    /// 🔴 **不能复用 `.photoLibrary`** —— 那是 `.readWrite`，会问用户「要不要让 Aster 访问你的照片」，
    /// 而存一张自己的附件只需要写。⚠️ Info.plist 里 `NSPhotoLibraryAddUsageDescription`
    /// **必须存在**，缺了系统是**直接 terminate**（不是拒绝授权）。
    ///
    /// - Parameter url: **必须是本地文件**（用户发的附件就是落盘的那份）。
    ///   远程 URL 不在这里处理 —— 调用方要先下载。
    /// - Returns: 目标位置是否真的有图（调用方据此 toast；**失败必须出声**，静默失败会被当成功能坏了）
    // ⚠️ 函数返回 Void ⇒ **不能**加 `@discardableResult`（Xcode 27 起这会报
    //    "declared on a function returning 'Void' is unnecessary"）。
    //    结果经 `completion` 回调给出，不是返回值。
    func saveImageToAlbum(at url: URL, completion: @escaping (Bool) -> Void) {
        guard url.isFileURL else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        // ⚠️ 先确认文件还在：附件可能被删了（清缓存 / 沙盒迁移），那时候 toast 要说「已不存在」而不是「保存失败」
        guard FileManager.default.fileExists(atPath: url.path) else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        StarryPermission.request(.photoLibraryAdd) { [weak self] status in
            // ⚠️ 本闭包里**没有一处用到 self**（权限结果只决定「做不做」，与实例状态无关）
            //    ⇒ `guard let self = self` 是多余强转，Xcode 27 起报「value 'self' was
            //    defined but never used」。保留 `[weak self]` + 判空只为维持原有语义：
            //    实例已释放就不做后续（别改成强捕获，那会改变生命周期）。
            guard self != nil else { return }
            guard status == .authorized else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            // 读盘放在后台队列：一张 1600px 的 JPEG 也有几百 KB，`.addResource` 之前得先拿到字节
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                    DispatchQueue.main.async { completion(false) }
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                } completionHandler: { success, _ in
                    // ⚠️ 这个回调**不在主线程**，回 UI 前必须自己切（与上面取图的写法同源）
                    DispatchQueue.main.async { completion(success) }
                }
            }
        }
    }

    // MARK: - 取数

    /// 最近的照片，`creationDate` 倒序。
    ///
    /// 只取图片：视频还没有能发给模型的链路（模型侧也不收），网格里放视频只会让用户点了没反应。
    /// 只读**头信息**（`PHAsset` 是轻量句柄，不含像素），所以每开一次面板取一次也不贵。
    func fetchRecentImages(limit: Int) -> [PHAsset] {
        guard authState.canRead, limit > 0 else { return [] }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = limit
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    // MARK: - 取图

    /// 网格缩略图。
    ///
    /// `deliveryMode = .opportunistic` 会**回调两次**：先给一张低清（立刻能上屏，避免一格白块），
    /// 再给最终图。两次都会调 `completion` —— 调用方要自己判「这回调还是不是我要的那张」
    /// （cell 被复用后旧请求的回调才到的情形，很常见）。
    ///
    /// - Parameter targetSize: **像素**尺寸（pt × screen scale），不是 pt。
    /// - Returns: 请求 ID，cell 复用 / 销毁时用它 `cancelRequest` 掐掉。
    @discardableResult
    func requestThumbnail(for asset: PHAsset,
                          targetSize: CGSize,
                          completion: @escaping (UIImage) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        // `.fast`：允许系统用更省的方式给（必要时直接拿相册里现成的缩略图）—— 网格要的就是快
        options.resizeMode = .fast
        // **不等 iCloud**：等下载会让格子长时间空着，不如让它空着，用户真点了再去下
        options.isNetworkAccessAllowed = false

        return manager.requestImage(for: asset,
                                    targetSize: targetSize,
                                    contentMode: .aspectFill,
                                    options: options) { image, _ in
            guard let image = image else { return }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// 点了某一格之后，真正要发给模型的那张图。
    ///
    /// 与缩略图相反：`highQualityFormat` 只会回调一次、给的就是终图；
    /// `isNetworkAccessAllowed = true` 让 iCloud 里的原图能被下下来（这一步是用户**主动**点的，
    /// 等一下可以接受，而在网格里被动加载就不该等）。
    /// 取到的图不超过 `maxPixel`（与 `AIAttachmentStorage.maxPixelSide` 同口径 ——
    /// 反正落盘时还要再压一次，这里取大了纯属浪费）。
    func requestFullImage(for asset: PHAsset,
                          maxPixel: CGFloat = AIAttachmentStorage.maxPixelSide,
                          completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.version = .current

        let side = max(1, maxPixel)
        manager.requestImage(for: asset,
                             targetSize: CGSize(width: side, height: side),
                             contentMode: .aspectFit,
                             options: options) { image, _ in
            DispatchQueue.main.async { completion(image) }
        }
    }

    func cancelRequest(_ id: PHImageRequestID) {
        manager.cancelImageRequest(id)
    }

    // MARK: - 私有

    private static func map(_ status: PHAuthorizationStatus) -> PhotosAuthState {
        switch status {
        case .notDetermined:        return .notDetermined
        case .restricted, .denied:  return .denied
        case .limited:              return .limited
        case .authorized:           return .authorized
        @unknown default:           return .denied
        }
    }
}
