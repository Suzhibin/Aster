//
//  FilePreviewPane.swift
//  AsterMac
//
//  右侧面板里「这个标签装的是个本地文件」时画的那一块：把 `QLPreviewView` 嵌进 SwiftUI。
//
//  ## 为什么只能是 `QLPreviewView`（macOS 的 QuickLook 只有这一条可嵌的路）
//  ☠️ **macOS 上没有 `QLPreviewController`** —— 那个类只在 iOS / Mac Catalyst / visionOS 有。
//  本机 macOS 26.2 SDK 的 `QuickLookUI.framework/Headers/` 里只有 `QLPreviewPanel.h` 与
//  `QLPreviewView.h`，**连 `QLPreviewController.h` 这个文件都没有**。三条路摆在一起：
//
//  | API | 形态 | 为什么不用 |
//  |---|---|---|
//  | **`QLPreviewView`** : `NSView` | **可嵌**（10.6+，`initWithFrame:style:` 10.7+） | ✅ **本文件用的就是它** |
//  | `QLPreviewPanel` : `NSPanel` | 系统单例面板 | 要 responder chain（`acceptsPreviewPanelControl:` / `beginPreviewPanelControl:` / `endPreviewPanelControl:` 三个方法必须由响应链里的对象实现），SwiftUI 里非常别扭；而且它是**独立面板**，不是「会话页右侧那块」 |
//  | SwiftUI `.quickLookPreview(_:)` | 系统浮层面板 | 形态对不上（我们要的是 `.inspector` 里的一块）；且它**必须同时 `import SwiftUI` + `import QuickLook`**（crossimport 才激活，少一个直接报 `has no member 'quickLookPreview'` —— 编译实测过） |
//
//  ⛔ **别想用 `WKWebView.loadFileURL(_:allowingReadAccessTo:)` 统一两种标签**：
//  WebKit 只会渲染文本 / 图片 / PDF 那几类，xlsx / docx / mp3 一律空白或变成「下载」
//  —— 而「打开文件」的绝大多数场景正是这些**需要 QuickLook 插件**的格式。
//
//  ## ☠️ 标题必须自己给：`QLPreviewView` 默认取 `lastPathComponent`
//  会话附件落盘时文件名被换成了 **UUID**（`52EDE56F-0455-4D46-BD….xlsx`），用户认得的名字
//  存在 `AIBlock.text` 里。而 `NSURL` 上**改不了** `previewItemTitle`（它只是 `QLPreviewItem`
//  的一个 category 实现）⇒ 必须回一个**自定义 `QLPreviewItem`**（见 `NamedPreviewItem`）。
//  ⚠️ iOS 那轮（`AIFilePreviewController`）实拍踩过同一个坑：导航栏标题显示成一串 UUID。
//
//  ## ⚠️ 它照不进离屏验收图
//  `NSViewRepresentable` 在 `ImageRenderer` 里是**黄条 + ⊘**（`VERIFY-PROBES` §2 第 5 条）
//  ⇒ 这里面的内容**离屏一格都照不到**，只能靠 `root` / `webpage` 档的**真窗口**探针验
//  （「窗口里有没有 `QLPreviewView` / 它的 frame 对不对」）。
//
//  ## ⚠️ 只认本地 `file://`
//  QuickLook **不做下载** —— 给 http(s) 地址不会出内容（不是「网速慢」那类问题）。
//  调用方（`WebPageContentView`）拿的是 `WebTabKind.file(url:)`，天然满足。
//
//  ## ☠️ 沙盒：容器外的文件要 security scope
//  授权由 `WebTabModel.init(fileURL:displayName:)` 持有（到那个标签销毁才还），
//  本文件**不再自己 start / stop** —— 两处各管一半，漏一处就是「预览一片空白」。
//  ⚠️ 但有一条**只能真机确认**：Office 文档是 QuickLook 的**另一个进程**（`QuickLookUIService`
//  及其插件）解析的，而 security scope 的授权**不会传染给 XPC 服务** ⇒ 沙盒下打开
//  **容器外**的 xlsx 有可能读不出来。容器内的附件（「点文件消息」那条主路）不受影响。
//  真出问题的话正解是「先拷进容器再预览」（同 iOS 的 `AIAttachmentStorage`），
//  落点在 `WebPageModel.openLocal(url:displayName:)`，⛔ 不是在这里。
//

import SwiftUI
import AppKit
import QuickLookUI
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

// MARK: - 预览项（带自定义标题）

/// 一个「有名字的」被预览项。
///
/// `NSURL` 本身就 conform `QLPreviewItem`（`QLPreviewItem.h` 里那个 category），但它的
/// `previewItemTitle` 恒等于 `lastPathComponent` —— 而我们的磁盘名是 UUID。
/// ⛔ 别试图给 `NSURL` 加分类或 `setValue(_:forKey:)` 去改它：两条都不靠谱，
/// 正解就是本类这种「自带标题的包装」。
final class NamedPreviewItem: NSObject, QLPreviewItem {

    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        // 空标题给 `nil` ⇒ 退回 QuickLook 自己的兜底（好过标题栏空一块）
        previewItemTitle = title.isEmpty ? nil : title
    }
}

// MARK: - 视图

/// 「文件标签」的内容区。
struct FilePreviewPane: NSViewRepresentable {

    let url: URL
    /// 给用户看的名字（标题栏 / 「无法预览」兜底文案用）。
    let title: String

    func makeNSView(context: Context) -> NSView {
        // ☠️ `QLPreviewView(frame:style:)` 在 Swift 里是 **optional**（建不出来时是 nil）——
        //    极少发生，但签名允许；给一块写清原因的占位，好过让用户对着纯白面板猜。
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else {
            return Self.unavailableLabel()
        }
        // 一上来就渲染。⚠️ 默认就是 `true`，写出来是为了让下面那条时序读得懂：
        // SwiftUI 拿到这块 view 时它已开始工作，**不需要**我们再催一次 `refreshPreviewItem()`。
        preview.autostarts = true
        // ⛔ 不要「跟着窗口关」：这块 view 活在 `.inspector` 里，自己没有任何「关窗」语义；
        //    置 true 会让窗口一关它就顺带收掉，而面板的标签还在（再展开就一片空白）。
        preview.shouldCloseWithWindow = false
        preview.previewItem = NamedPreviewItem(url: url, title: title)
        return preview
    }

    /// ⚠️ **空实现是对的**：`url` / `title` 变了的时候，`WebPageContentView` 那边是
    /// **整块重建**（`.id(activeTabIndex)`）⇒ 本方法在这块 view 的生命周期里根本不该承担
    /// 「换个文件」的职责。真在这里写赋值反而要自己处理「换了 `previewItem` 之后要不要
    /// `refreshPreviewItem()`」那类时序问题 —— 而换标签已经整块重建了，不值当。
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// 建不出 `QLPreviewView` 时的占位。
    /// 用纯 AppKit：本文件处在 representable 内部，不该为此再套一层 SwiftUI 桥。
    private static func unavailableLabel() -> NSView {
        let label = NSTextField(labelWithString: L("无法预览这个文件"))
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)
        return label
    }
}
