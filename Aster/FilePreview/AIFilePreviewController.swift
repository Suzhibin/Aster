//
//  AIFilePreviewController.swift
//  Aster
//
//  会话里点「文件消息」→ push 进来的**系统预览页**（2026-10-06 用户需求）。
//
//  > 「iOS 端 使用 QLPreviewController，单独打开一页，只要是文件消息 都可以进入」
//
//  ## 形态：**push 一整页**，与 `AIWebPageViewController` 同一口径
//  iOS 屏窄，浮层 / 半屏放不下文档 ⇒ 推一整页、左上角返回键（或侧滑）回来。
//  ⛔ 别改成「盖在会话上的浮层」：那会把返回入口一起藏掉。
//
//  ## ☠️ 为什么本类是 `QLPreviewController` 的**子类**，而不是「新建容器 VC 把 QL 嵌进去」
//  两条各自独立、方向相反的硬约束，合起来只剩这一条路：
//
//  ① 🔴 **`QLPreviewController.dataSource` 是 `weak`**
//     （头文件：`@property(nonatomic, weak, nullable) id <QLPreviewControllerDataSource> dataSource;`）
//     ⇒ 写成 `ql.dataSource = AIFilePreviewDataSource(url: url)` 这种「一次性对象」，
//     **赋值那一拍就被释放**（没有任何强引用），预览页空白。而且**编译期毫无提示**，
//     运行时也可能只是「没内容」而不是崩 —— 是本页最容易踩、也最难查的坑。
//     让 **`self` 当数据源**（`self` 被导航栈强引用）从根上不存在这个问题。
//
//  ② ☠️ **Apple 明写：把 `QLPreviewController` 作为子控制器嵌进别的 VC，只会显示一张
//     缩略图，不是实时预览**（`QLPreviewController` 文档 "Presenting a preview controller"：
//     *the system doesn't display a live preview if you embed the QLPreviewController in
//     another view controller. Instead, it displays a thumbnail*）。
//     ⇒ 「自己写个容器 VC 再 `addChild(ql)`」这条路是**死的**，别试。
//
//  ⚠️ `QLPreviewController` 就是个普通的 `UIViewController` 子类，头文件里**没有任何
//     「禁止继承」的标注** ⇒ 子类是正解。要加行为加在这里，⛔ 别在外面套容器。
//     ⚠️ 因为它是完整继承的，**别在本类里重写 `viewDidLoad` 之外的布局**：内容区是
//     QuickLook 自己画的，插视图进去只会打架。
//
//  ## ⚠️ 只认**本地文件**
//  QuickLook 走 `file://` 通道，**它不做下载** —— 给 http(s) 地址不会出内容。
//  本页的调用方（`didSelectRowAt` 的 `.file` 那支）拿的是 `AIAttachmentStorage` 落地的
//  本地附件，天然满足；将来若**助手侧**也能发文件且存的是远程地址，
//  **必须先下载到本地再进这一页**（否则是一片空白，且看起来像「预览坏了」）。
//
//  ## 🔴 标题**必须**用「用户当初发的文件名」，不是磁盘名（2026-10-06 实拍踩到）
//  附件落盘时文件名被**换成了 UUID**（实测那条 xlsx 在沙盒里叫
//  `52EDE56F-0455-4D46-BDF5-22F328A3400C.xlsx`），而用户认得的名字是
//  `iOS上线CheckList.xlsx`（存在 `block.text` 里）。
//  QuickLook 的标题**默认取 `previewItemURL` 的 `lastPathComponent`** ⇒ 什么都不做的话，
//  导航栏中间会明晃晃写着那串 UUID，用户根本认不出这是哪个文件。
//  🔴 光设 `self.title` **不够**：Apple 文档写明标题由 `previewItemTitle` 覆盖
//  （*"You can override it by implementing a `previewItemTitle` accessor for the preview item"*）
//  ⇒ 正解是**回一个实现了 `previewItemTitle` 的 item**（见 `AIFilePreviewItem`）。
//  两处都写（`title` + `previewItemTitle`）：不管 QuickLook 采信哪一个，看到的都是真文件名。
//

import UIKit
import QuickLook

final class AIFilePreviewController: QLPreviewController {

    /// 要预览的那一个文件。
    ///
    /// ⚠️ `AIBlock.fileURL` 是**可选**的，但本类只接受**非可选**值 —— 判空放在调用方
    /// （拿不到路径就根本不该进这一页），免得这里再造一套「没文件时显示什么」的分支。
    private let fileURL: URL

    /// 导航栏 / QuickLook 标题要显示的名字 —— **用户当初发的那个文件名**（`row.block.text`）。
    /// 详见文件头那节「标题必须用用户认得的名字」。
    private let displayName: String

    /// - Parameter displayName: 用户看到的文件名。☠️ **别传 `fileURL.lastPathComponent`** ——
    ///   落盘时名字被换成了 UUID，磁盘名和用户认得的名字**不是一回事**。
    ///   传空串 / `nil` 时才退回磁盘名（历史数据里 `block.text` 可能为空，
    ///   那时「一串 UUID」也好过「导航栏中间空一块」）。
    init(fileURL: URL, displayName: String?) {
        self.fileURL = fileURL
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.displayName = trimmed.isEmpty ? fileURL.lastPathComponent : trimmed
        super.init(nibName: nil, bundle: nil)
        // ☠️ 必须在 `init` 里设、且设的**就是 `self`** —— `dataSource` 是 weak，见文件头 ①。
        dataSource = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 与本类的 `AIFilePreviewItem.previewItemTitle` **同一个值**，见文件头。
        title = displayName
        // 会话页若开了大标题，push 进来的页面会跟着变大标题 ⇒ 显式收掉。
        navigationItem.largeTitleDisplayMode = .never
    }
}

// MARK: - QLPreviewItem（带标题）

/// 为什么需要它：`NSURL` 虽然**本身**就 conform `QLPreviewItem`
///（`QuickLook/QLPreviewItem.h` 里的 `@interface NSURL (QLPreviewConvenienceAdditions) <QLPreviewItem>`），
/// 但它的 `previewItemTitle` 是 `nil` ⇒ QuickLook 会退回「取 URL 的最后一段路径」
/// = 那串 UUID。**`previewItemTitle` 只能由自定义 item 提供**（`NSURL` 上你改不了它）。
///
/// ⚠️ 顺带一提：`previewItemURL` 必须给 `file://`（QuickLook 不做下载）。
private final class AIFilePreviewItem: NSObject, QLPreviewItem {

    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}

// MARK: - QLPreviewControllerDataSource

/// ⚠️ 这个协议在头文件里标了 `NS_SWIFT_UI_ACTOR` ⇒ 在 Swift 里**就是 `@MainActor`**，
///    所以本工程那条「老 ObjC 协议 conformance 要标 `nonisolated`」的规矩**在这里不适用**。
///    （那条规矩针对的是**没标** `NS_SWIFT_UI_ACTOR` 的老协议。）
extension AIFilePreviewController: QLPreviewControllerDataSource {

    /// 一页只放**一个**文件。
    ///
    /// ⚠️ 传 >1 会让 QuickLook 在**导航栏上画左右翻页箭头** —— 本页是 push 进会话栈的，
    ///    那两个箭头会和返回键挤在一起；而「文件行」本来就是「一条消息一个文件」，
    ///    没有「翻到下一个」的语义。要支持「在一批文件里翻」是另一个需求，别顺手加。
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController,
                           previewItemAt index: Int) -> QLPreviewItem {
        AIFilePreviewItem(url: fileURL, title: displayName)
    }
}
