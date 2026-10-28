//
//  WebPageView.swift
//  AsterMac
//
//  网页**面板**的内容（2026-09-30 起；当晚加标签页 + 缩放 + 适配宽度）：
//  一条**导航条**（← → ⟳ + 地址栏 + 缩放 −/百分比/+/适配宽度 + 用浏览器打开
//  + 关闭当前标签），下面一块 `WKWebView`。
//  🔴 标签条**不在这个文件的面板内容里** —— 它挂成了 **inspector 列自己的工具栏项**
//     （`RootView` 里 `.toolbar { ToolbarItem(id: "webPageTabs", …) }`，内容是
//     **AppKit 桥** `WebPageTabsBarBridge` —— ⚠️ 不是 SwiftUI：ToolbarItem 的内容
//     是一次性快照，@ObservedObject 带不动它，见桥那段五轮实验记录）
//     ⇒ 正好落在窗口最上面那条带里、且点得着、且**随标签增删刷新**。
//
//  ## 🔴 标签条的落点（2026-09-30 当晚三改定稿；前两版都实测毙掉，别走回头路）
//  用户第一次说「把 tab 与加号按钮添加到 web 页面的导航上」⇒ 并进导航条那一行；
//  随后他贴图圈出**窗口最顶端那条空带子**说「我说的是图中画线的这个导航，把 tab 和
//  加号移动上去」⇒ 第二版用「负 top padding + 隐藏工具栏背景」把标签行**顶进那条带**
//  —— 看着对了，但用户报「加号点击不动」：真窗口 hitTest 探针查明，那条带归
//  `NSToolbarView`（窗口工具栏），**画进去的内容永远收不到点击**（「画得上去」和
//  「点得着」是两回事）。⇒ 第三版：标签条 = inspector 列自己的**真工具栏项**——
//  系统把它放进面板上方那格工具栏区，位置就是那条带、点击归 AppKit。✅
//
//  ## 这是干什么的
//  助手回复里出现网址时，点它 → **会话页右侧滑出一块面板**（`RootView` 挂的 `.inspector`），
//  面板里装的就是这个视图。形态照用户给的豆包 Mac 版截图（含标签页 + 适配宽度）。
//
//  ## 🔴 为什么是「面板」而不是「新开一个窗口」
//  第一版做成了独立 `NSWindow`（贴主窗右侧开出来）。用户看到后纠正：
//  「新打开的网页**不是一个新窗口**，而是在会话页面右侧又出现的窗口」——
//  要的是**嵌在 App 窗口里、与会话并排**，不是在桌面上多一个平级窗口。
//
//  顺手查了「`NavigationSplitView` 支不支持三栏」：支持，但**做不到「只收起第三栏」**——
//  `NavigationSplitViewVisibility` 只有三档，且都是「收前导列」。⇒ 改用 `.inspector`
//  （macOS 14 起系统自带的尾部面板，只在打开时才存在）。完整取舍写在 `RootView` 那段注释里。
//
//  ## 🔴 顶栏要**自己画**，而不是用 WKWebView 自带的返回手势
//  macOS 上 `WKWebView` 有 `allowsBackForwardNavigationGestures`（两指横扫），
//  但那是**隐藏手势**。⇒ 这里补一条极简顶栏，回答三个问题：这是哪个站、能不能回上一步、
//  怎么关掉它（外加一条出路：换个方式打开 / 缩放 / 适配宽度）。
//  ⚠️ 那颗 ✕ 是**面板关闭入口**（`.inspector` 不画系统关闭按钮），常驻、不许 hover 显隐。
//
//  ## 🔴 标签页形态（2026-09-30 当晚加；2026-10-02 二改：条 = AppKit 桥 + 面板常驻）
//  - 一个 `WebPageModel` 持有**多个 `WebTabModel`**，每个 `WebTabModel` 自己持有一块
//    `WKWebView`（切标签不重载，代价是每标签一个 Web 子进程内存）。
//  - 标签与「＋」住在**窗口最上面那条带里**（`WebPageTabsBarBridge` → `WebPageTabsBar`，
//    AppKit 自绘的真工具栏项）：每个标签一个「标题 + ✕」胶囊，末尾一颗「＋」新建。
//    🔴 标签条的宽度**自己 clamp** 到「**面板实测列宽** − 余量」（面板宽度由
//       `WebPageContentView` 自己量、经 `WebPageModel.panelWidthRelay` 喂给标签条），
//       超出的标签在条内**横向滚动**（`NSScrollView`）—— 标签再多也不会把工具栏撑爆、
//       溢到会话页面的导航上（2026-10-02 用户报的正是这个）。⛔ 别改成「设上限裁掉」。
//       ☠️ 上限**不能**用「按窗口算的开口宽」现算：那个值 2026-10-04 起虽然已经贴近实际
//          （口径改成塞 `min` 了），但窗口极窄时 `.inspector` 照样压缩它（实测 1120 窗口
//          曾算出 500、实际 342）⇒ 照样溢出。
//  - 新建标签是一张**极简起始页**（地址输入框 + 「打开」），不预载任何站点。
//  - 面板那颗 ✕（在导航条最右）= 关**当前标签**；关掉最后一个标签时整块面板收起（销毁）。
//  - 🔴 右上角那颗开关（`sidebar.left`）= **只切显示**（`hide/showWebPagePanel`），
//    **内容常驻**：收起再展开，标签一个不少（2026-10-02 用户要求，探针 ③/③′ 验）。
//  - 点助手正文里的网址：**已开面板则新开一个标签**（与当前标签同址则去重），没开则开面板 + 首标签。
//
//  ## 🔴 缩放 + 适配宽度（2026-09-30 当晚加）
//  - `WKWebView.pageZoom` 是整体缩放（不是 viewport 缩放）。百度这类**固定宽桌面布局**
//    在窄面板里只显示左上角一块 —— 用 `pageZoom = 面板宽 / 内容宽` 即可**整页落进面板**
//    （`适配宽度`按钮 / ⌘+ / ⌘- / ⌘0）。⚠️ 代价：正文跟着缩小。
//    ☠️ 2026-10-04 试过「打开网页**自动**适配一次」（`noteLoadFinished` → `scheduleAutoFit`），
//    与「把面板宽度塞进 `min`」同属一版改动 —— 用户觉得「web 太优先了」⇒ **已整块回退**
//    （`scheduleAutoFit` / `skipAutoFitOnce` / `webPageAutoFitDelay` 全删）。⛔ 别再重做。
//  - ⛔ **别指望 viewport meta / preferredContentMode**：macOS 的 WKWebView **完全忽略**
//    `<meta name="viewport">`，注入无效（已用离屏实验证实）。
//
//  ## 🔴 三个必须知道的技术口径
//  ① **`window.open` / `target=_blank` 的链接必须自己接住**（`decidePolicyFor` 里那段）。
//     不接住的话点了**没有任何反应**。接法：`decisionHandler(.cancel)` + 在同一块 webView 里 load。
//     ☠️ **这条「接住」自己会成环**：站点若每加载一遍就开一次 `_blank` ⇒ 无限重载。
//     ⇒ 必须配**循环打断器**（两条闸门写在 `MainActorWebPagePolicy` 类型注释里）。
//      ⛔ 别只删闸门留下这条接住。
//  ② **http 站点会被 ATS 拦掉**（错误码 -1022）。工程没有 `NSAllowsArbitraryLoadsInWebContent`，
//     且运行时绕不过。⇒ 在错误页说清原因 + 给「用默认浏览器打开」出路。
//  ③ **桌面 UA**：不设时 WKWebView 发的 UA 缺 `Version/… Safari/…` 尾巴，部分站点（百度）
//     会回「把 https 换掉」的降级桩页。⇒ 显式设一颗完整桌面 Safari UA（`MacTheme.webPageUserAgent`）。
//
//  ## ⚠️ 隔离与协议 conformance
//  本 target 是 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` ⇒ 类默认主 actor 隔离，
//  而 `WKNavigationDelegate` 是 **ObjC 协议**（要求 nonisolated 实现）——
//  所以那几个方法必须显式写 `nonisolated`，并在方法体里 `MainActor.assumeIsolated`。
//
//  ## ⚠️ 为什么用 `ObservableObject` 而不是 `@Observable`
//  验收台（`render_mac_ui.sh`）**完全不能展开宏**，每加一个 `@Observable` 都要手工补一致性代码。
//  `WebPageModel` / `WebTabModel` 只需要「值变了通知视图」，用 `@Published` 足够，
//  不给验收台多加必同步点。
//

import SwiftUI
import AppKit
import WebKit
import Combine
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

// MARK: - 状态

/// 加载失败时给用户看的东西（人话 + 系统原话两段）。
struct WebPageFailure: Equatable {
    let message: String
    let detail: String?
    let isTransportSecurity: Bool
}

// MARK: - 标签里装什么

/// **一个标签装的是什么**（2026-10-06 加；2026-10-07 从两档扩成四档）。
///
/// 用户口径（原话）：「QLPreviewView 放在右侧的 新页面，就是**点网页可以打开网页，
/// 点文件可以打开文件**」—— 右侧那块面板从「网页专用」升成「**内容面板**」。
/// 2026-10-07 再扩一次（「打开文件夹的功能 可以做成图中这样目录树显示吗？
/// 文件夹内如果有代码文件点击 增加标签并显示代码？」）⇒ 一个标签现在可以是：
/// 一张网页、一个不可预览文件的 QuickLook、**一棵目录树**、**一个代码文件**。
///
/// ⚠️ 四种内容**不共用渲染通道**，这是刻意的：
/// - `.web` ⇒ `WKWebView`；
/// - `.file` ⇒ `QLPreviewView`（见 `FilePreviewPane`）；
/// - `.folder` ⇒ 目录树（见 `FolderTreePane`，**纯 SwiftUI**，离屏渲染照得到）；
/// - `.code` ⇒ 代码视图（见 `CodePane`，**纯 SwiftUI**，同上）。
///
/// ⛔ **别想着用 `WKWebView.loadFileURL(_:allowingReadAccessTo:)` 统一**：WKWebView
///    只认文本/图片/PDF 那几类能自己渲染的格式，xlsx / docx / mp3 一律只会「下载」或空白
///    —— 而「打开文件」的绝大多数场景正是这些**需要 QuickLook 插件**的格式。
///    这也正是 macOS 上唯一能拿到系统级预览的那条路（`QLPreviewController` 在 macOS SDK 里
///    根本不存在，见 `FilePreviewPane` 文件头）。
///
/// 🔴 `.code` 与 `.file` 是**同一个入口的两个出口**：由 `CodeLanguage.forFile(_:)` 分流
///    （认出扩展名 ⇒ `.code`；否则 ⇒ `.file` 交回 QuickLook）⇒「点开任何文件都不吃亏」。
enum WebTabKind: Equatable {

    /// 网页。⚠️ **「起始页」也属于这一档**（它只是「还没加载任何站点的网页标签」，
    /// 那个 `isStartPage` 状态在 `WebTabModel` 上，不在这里再分一层）。
    case web

    /// 本地文件，交给系统 QuickLook 预览（不认识 / 不好自己画的那一类）。
    /// - `url`：磁盘上的真实路径（QuickLook 只认 `file://`，不做下载）。
    /// - `displayName`：**给用户看**的名字。☠️ 别用 `url.lastPathComponent` 代替 ——
    ///   会话附件落盘时文件名被换成了 UUID（`52EDE56F-….xlsx`），
    ///   用户认得的名字在 `AIBlock.text` 里（iOS 那轮实拍踩过同一个坑）。
    case file(url: URL, displayName: String)

    /// 一个**目录**（画成可展开的目录树，2026-10-07 加）。
    /// ⚠️ 名字同样由调用方给（起始页选的是目录名、恢复路径给的是记下来的那个）。
    case folder(url: URL, displayName: String)

    /// 一个**代码 / 文本文件**（画成带行号与语法色的只读视图，2026-10-07 加）。
    case code(url: URL, displayName: String)
}

extension WebTabKind {
    /// 是不是网页档。**只有 `.web` 才需要 `WKWebView`**（其余三档不该为它多养一个 Web 进程）。
    /// 🔴 `setupRelay()` 里就靠它那句三元表达式把这件事**结构上**钉住，⛔ 别改回去。
    var isWeb: Bool {
        if case .web = self { return true }
        return false
    }

    /// 是不是「本地面上的东西」（三档都用 `file://`）。
    /// ⚠️ 与 `isWeb` **互斥且互补**（现有四档里非 web 即 local）—— 但别写成 `!isWeb`：
    ///    将来若再加一档（比如「终端」），`!isWeb` 会把它错当成本地文件。
    var isLocal: Bool {
        switch self {
        case .web: return false
        case .file, .folder, .code: return true
        }
    }

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    var isCode: Bool {
        if case .code = self { return true }
        return false
    }

    /// 是不是「交给 QuickLook」那一档（只有它为真时 `activeFile` 才有值）。
    var isFilePreview: Bool {
        if case .file = self { return true }
        return false
    }

    var fileURL: URL? {
        if case .file(let url, _) = self { return url }
        return nil
    }

    var fileDisplayName: String? {
        if case .file(_, let name) = self { return name }
        return nil
    }

    /// 三档本地面向内容的**地址**（文件 / 目录 / 代码）。
    /// ⚠️ 单独一个属性而不是让调用方 switch：`currentURL` 与「第二个账本」都要它。
    var localURL: URL? {
        switch self {
        case .file(let url, _), .folder(let url, _), .code(let url, _): return url
        case .web: return nil
        }
    }

    /// 三档本地面向内容的**显示名**（文件 / 目录 / 代码）。
    var localDisplayName: String? {
        switch self {
        case .file(_, let name), .folder(_, let name), .code(_, let name): return name
        case .web: return nil
        }
    }

    /// 标签条胶囊上那个前置小图标（`nil` = 网页档不画）。
    /// 🔴 标签条上这是**唯一**能区分四类内容的地方 —— 光看标题分不出来
    ///    （一个叫「报告」的网页 / 一个叫「报告.pdf」的文件 / 一个叫「报告」的文件夹）。
    /// ⚠️ 收在这里而不是散在 `makePill` 里 switch：将来加档只改这一处。
    var tabSymbolName: String? {
        switch self {
        case .web:    return nil
        case .file:   return "doc.fill"
        case .folder: return "folder.fill"
        case .code:   return "curlybraces"
        }
    }

    /// 这个标签**养不养** `WKWebView`（= 需不需要它那块 `webView`）。
    /// ⚠️ 与 `isWeb` 同义，但这个名字在 `setupRelay()` 那句里读起来是它真正的意思。
    var needsWebView: Bool { isWeb }
}

/// 「本地面上的一个标签」要展示的三样东西：磁盘地址 + **给用户看的名字** + 它是哪一档。
///
/// ⚠️ 单独包一层、而不是到处传三个参数：这些**必须同生同死** ——
/// 有地址没名字 ⇒ 标题又变回那串 UUID（用户认不出来）；
/// 有名字没地址 ⇒ 「用默认应用打开」点了没反应。包在一起就没有「只传一半」的可能。
struct FileTabInfo: Equatable {
    let url: URL
    let displayName: String
}


// MARK: - 单个标签页

/// **一个标签**的状态 + 它**自己持有**的 `WKWebView`。
///
/// 🔴 每个标签一块独立的 `WKWebView`：切标签 = 换显示哪一块，原标签**不重载**
/// （用户在别的标签里滚到的位置、填过的表单都还在）。代价是每标签一个 Web 子进程内存，
/// 但这个面板本来就不是「浏览器」，标签数有限，可接受。
///
/// ℹ️ `ObservableObject` + `@Published`（见文件头「为什么不用 `@Observable`」）。
final class WebTabModel: ObservableObject {

    /// 稳定 id（标签条 `ForEach` 用，避免用下标当 id 带来的动画/复用错乱）。
    let id = UUID()
    /// 这个标签装的是网页还是本地文件（见 `WebTabKind`）。**建好就不再变**。
    let kind: WebTabKind
    /// 打开这个标签时那个 URL（`load()` 用它；也是「重试」的目标）。起始页标签为 `nil`。
    private(set) var initialURL: URL?
    /// 网页本体。由 model 持有而不是在 representable 里现建（避免 SwiftUI 重建导致整页重载）。
    ///
    /// 🔴 **懒创建**（2026-10-06）：文件标签（`kind == .file`）**一个 Web 进程都不该养**，
    ///    而「第一次访问它才建」让「文件标签不碰 `webView`」这件事**结构上成立**，
    ///    不靠调用方自觉。
    /// ☠️ 它是**计算属性** ⇒ **别在文件标签上读它**（读 = 建）。要「读了才建」的那种读法用
    ///    `webViewIfLoaded`；只有真的要用它干活的地方（`load` / `reload` / `fitWidth`…）才用本属性。
    var webView: WKWebView {
        if let existing = lazyWebView { return existing }
        let created = WebTabModel.makeWebView()
        lazyWebView = created
        configure(created)
        return created
    }

    /// 已经建出来的那一块（没建过就是 `nil`）。**只读、绝不触发创建**。
    private var lazyWebView: WKWebView?

    /// 「已经建出来的网页本体」——**问了不会顺手建一个**。
    /// `currentURL` 与 `WebPageModel.setupRelay()` 用它（那两处对文件标签也会被问到）。
    var webViewIfLoaded: WKWebView? { lazyWebView }

    /// 沙盒：从 `NSOpenPanel` 选来的**容器外**文件要靠它拿读取授权，
    /// 且授权必须**持有到这个标签被销毁**（中途 `stop` 的话 QuickLook 再读就是 EPERM）。
    /// 容器内的文件（会话附件）不需要，但多调一次 `start` 也无害（它只是返回 `false`）。
    private var securityScopedURL: URL?

    /// 目录树的状态（**只有 `.folder` 标签有**，2026-10-07 加）。
    ///
    /// 🔴 由**标签**持有而不是视图的 `@State`：切到别的标签再切回来，展开的层级与
    ///    滚动位置必须原样还在（与 `WKWebView` 由标签持有同一条理由）。
    /// ⚠️ 建在 `init` 里是**安全**的：`FolderTreeModel.init` 只记一个路径，**不读盘**
    ///    （第一次列目录由视图 `.onAppear` 触发）—— 否则开一个标签就要阻塞一次 IO。
    let folder: FolderTreeModel?

    /// 代码文档的状态（**只有 `.code` 标签有**，2026-10-07 加）。同理由标签持有。
    let code: CodeDocumentModel?

    @Published private(set) var pageTitle = ""
    @Published private(set) var address = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var failure: WebPageFailure?
    /// 缩放（整页缩放，见文件头口径）。默认 1.0 = 不缩放。
    @Published private(set) var pageZoom: Double = 1.0
    /// 是否还是「起始页」（没加载任何站点，显示地址输入框）。
    @Published private(set) var isStartPage: Bool

    private var observations: [NSKeyValueObservation] = []
    private let navigationDelegate = WebPageNavigationDelegate()
    private(set) var didStartLoading = false

    // MARK: 构造

    /// 直接打开一个 URL 的标签。
    init(url: URL) {
        kind = .web
        initialURL = url
        address = url.absoluteString
        isStartPage = false
        folder = nil
        code = nil
    }

    /// 起始页标签（地址输入框，等用户提交后才加载）。
    init(startPage: Bool) {
        kind = .web
        initialURL = nil
        address = ""
        isStartPage = true
        folder = nil
        code = nil
    }

    /// **本地文件**标签（2026-10-06）：内容由 `FilePreviewPane` 画（`QLPreviewView`），
    /// 本类只负责「标签条上的标题 / 身份」这一层。
    /// ⚠️ `displayName` 由调用方给（会话附件取 `AIBlock.text`、`NSOpenPanel` 取选中文件名）——
    ///    会话附件的磁盘名是 UUID，拿它当标题用户认不出来。
    init(fileURL: URL, displayName: String) {
        kind = .file(url: fileURL, displayName: displayName)
        initialURL = nil
        address = displayName
        isStartPage = false
        folder = nil
        code = nil
        // 容器外的文件在沙盒里要先拿授权（**持有到本对象销毁**，见 deinit）。
        claimSecurityScope(fileURL)
    }

    /// **目录**标签（2026-10-07）：内容由 `FolderTreePane` 画（可展开的目录树）。
    ///
    /// 🔴 目录也走 security scope：用户用 `NSOpenPanel` 选中的**目录**，
    ///    沙盒给的是**整棵子树**的读写权限（这正是「选一个文件夹就能浏览里面」的原理）。
    ///    ⚠️ 这一条**只能真机确认**（验收台编出来的可执行文件根本没有沙盒，
    ///    所以探针里「读得到」证明不了带沙盒的真 App 也读得到）。
    init(folderURL: URL, displayName: String) {
        kind = .folder(url: folderURL, displayName: displayName)
        initialURL = nil
        address = displayName
        isStartPage = false
        folder = FolderTreeModel(root: folderURL, displayName: displayName)
        code = nil
        claimSecurityScope(folderURL)
    }

    /// **代码 / 文本文件**标签（2026-10-07）：内容由 `CodePane` 画（行号 + 语法色，只读）。
    /// ⚠️ 只对 `CodeLanguage.forFile(_:)` 认得的扩展名开这一档（见 `WebPageModel.openLocal`）。
    init(codeURL: URL, displayName: String) {
        kind = .code(url: codeURL, displayName: displayName)
        initialURL = nil
        address = displayName
        isStartPage = false
        folder = nil
        code = CodeDocumentModel(url: codeURL, displayName: displayName)
        claimSecurityScope(codeURL)
    }

    /// 拿沙盒读取授权（容器外的路径才有；容器内的会返回 `false`，无害）。
    /// 🔴 必须在**每个**本地面向的 init 里调一次（`deinit` 负责还）。
    private func claimSecurityScope(_ url: URL) {
        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }
    }

    deinit {
        // ⚠️ 必须还：授权是进程级的，不还的话那条路径会一直被本进程占着。
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }

    /// 创建 `WKWebView`（懒创建那条路用；两处 init 都不再建）。
    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 🔴 不落盘：cookie / 缓存 / localStorage 一律不进沙盒容器（见文件头口径 ②）。
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }

    /// 建出来之后才做的后续配置（UA / 手势 / 代理 / KVO）。
    private func configure(_ view: WKWebView) {
        // ③ 桌面 Safari UA（缺尾巴会被部分站点回降级桩页）。
        view.customUserAgent = MacTheme.webPageUserAgent
        view.allowsBackForwardNavigationGestures = true
        navigationDelegate.model = self
        view.navigationDelegate = navigationDelegate
        observe(view)
    }

    // MARK: 动作

    /// 首次加载（只针对「有 initialURL」的标签）。⚠️ 由视图 `.onAppear` 调，不在构造里直接 load。
    func loadIfNeeded() {
        guard !didStartLoading, let url = initialURL else { return }
        didStartLoading = true
        load(url: url)
    }

    func load(url: URL? = nil) {
        guard let target = url ?? initialURL else { return }
        failure = nil
        isStartPage = false
        webView.load(URLRequest(url: target))
    }

    /// 起始页提交：把用户输入当网址加载（没写 scheme 自动补 https://）。
    func loadURL(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { return }
        initialURL = url
        address = url.absoluteString
        loadIfNeeded()
    }

    func reload() {
        failure = nil
        if webView.url == nil {
            // 还没真加载过（起始页标签）：照常加载
            load()
        } else {
            webView.reload()
        }
    }

    func stop() { webView.stopLoading() }

    func goBack() {
        guard webView.canGoBack else { return }
        failure = nil
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        failure = nil
        webView.goForward()
    }

    /// 当前页（还没加载完时是目标地址）。给「用默认应用打开」用。
    /// - 本地面上的三档（文件 / 目录 / 代码）⇒ 它们自己的 `file://` 地址
    ///   （收起面板时记账 / 去重都要它）；
    /// - 网页标签 ⇒ ⚠️ 走 `webViewIfLoaded`：**别因为被问一句就顺手建一块 `WKWebView`**。
    var currentURL: URL? {
        // ☠️ 这里**绝不能**碰 `webView`（它是懒创建的计算属性，读 = 建）——
        //    加了目录树与代码这两档之后，被问到的非网页标签更多了。
        if let local = kind.localURL { return local }
        return webViewIfLoaded?.url ?? initialURL
    }

    /// 「用外部程序打开」。
    /// - 网页标签 = 丢给系统默认浏览器；
    /// - 文件标签 = 丢给系统默认 App（正是文件档导航条那颗按钮要的语义）。
    func openInBrowser() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: 缩放

    func zoomIn() { setZoom(pageZoom + MacTheme.webPageZoomStep) }
    func zoomOut() { setZoom(pageZoom - MacTheme.webPageZoomStep) }
    func resetZoom() { setZoom(1.0) }

    private func setZoom(_ z: Double) {
        let z = min(max(z, MacTheme.webPageZoomMin), MacTheme.webPageZoomMax)
        webView.pageZoom = z
        pageZoom = z
    }

    /// 适配宽度：把整页缩到正好放进面板（`pageZoom = 面板宽 / 内容宽`）。
    /// ⚠️ 内容宽（`scrollWidth`）只能靠 JS 读，且面板必须先布局好（`bounds.width > 0`）。
    func fitWidth() {
        let width = webView.bounds.width
        guard width > 0 else { return }
        webView.evaluateJavaScript("document.documentElement.scrollWidth") { result, _ in
            guard let scrollWidth = (result as? NSNumber)?.doubleValue, scrollWidth > 0 else { return }
            let z = min(max(width / scrollWidth, MacTheme.webPageZoomMin), MacTheme.webPageZoomMax)
            DispatchQueue.main.async { self.webView.pageZoom = z; self.pageZoom = z }
        }
    }

    // MARK: KVO

    /// KVO 六条（⚠️ `observations` 必须留着 —— 一被释放观察当场失效，且没有任何报错，
    /// 症状是「进度条永远 0、标题永远不更新」）。
    /// ⚠️ 参数 `view` 而不是读 `self.webView`：本函数由懒创建那条路调进来，此刻
    ///    `lazyWebView` 已经赋值，但**从参数拿**能让「观察的到底是哪一块」一目了然。
    private func observe(_ view: WKWebView) {
        observations.append(view.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.progress = w.estimatedProgress
            }
        })
        observations.append(view.observe(\.title, options: [.new]) { [weak self] w, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pageTitle = w.title ?? ""
            }
        })
        observations.append(view.observe(\.url, options: [.new]) { [weak self] w, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.address = w.url?.absoluteString ?? ""
            }
        })
        observations.append(view.observe(\.isLoading, options: [.new]) { [weak self] w, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLoading = w.isLoading
            }
        })
        observations.append(view.observe(\.canGoBack, options: [.new]) { [weak self] w, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.canGoBack = w.canGoBack
            }
        })
        observations.append(view.observe(\.canGoForward, options: [.new]) { [weak self] w, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.canGoForward = w.canGoForward
            }
        })
    }

    /// 标签条上显示的标题：
    /// **本地面上的三档（文件 / 目录 / 代码）⇒ 各自的 `displayName`**（不是 UUID 那个磁盘名）；
    /// 网页标签 ⇒ 优先页面 title、其次域名；起始页显示「新标签页」。
    var displayTitle: String {
        if let name = kind.localDisplayName { return name }
        if isStartPage { return L("新标签页") }
        if !pageTitle.isEmpty { return pageTitle }
        return currentURL?.host ?? L("新标签页")
    }
}

// MARK: - 多标签容器

/// **整块面板**的状态：一组标签 + 当前激活标签，并把激活标签的状态**转发**给视图层。
///
/// 🔴 为什么要「转发」而不是让视图直接读 `tabs[activeTabIndex]`：
/// `WebPageContentView` / 探针都按「`model.address` / `model.webView` 这种扁平属性」在用，
/// 转发后它们一行都不用改；切标签时 `setupRelay()` 重订阅即可。
final class WebPageModel: ObservableObject {

    @Published var tabs: [WebTabModel] = []
    @Published var activeTabIndex: Int = 0

    // ↓↓↓ 这些全部转发自「当前激活标签」，视图层只认这一套 ↓↓↓
    @Published private(set) var webView: WKWebView?
    @Published private(set) var address = ""
    @Published private(set) var pageTitle = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var failure: WebPageFailure?
    @Published private(set) var pageZoom: Double = 1.0
    @Published private(set) var isStartPage = false

    var isEmpty: Bool { tabs.isEmpty }
    var activeTab: WebTabModel? {
        tabs.indices.contains(activeTabIndex) ? tabs[activeTabIndex] : nil
    }
    var currentURL: URL? { activeTab?.currentURL }

    /// 🔴 面板**实际**列宽（由 `WebPageContentView` 量自己的宽度喂进来，2026-10-02）。
    ///
    /// 标签条拿它当**宽度上限**的唯一依据（值 = 面板宽 − 余量）。☠️ 为什么不能用
    /// 「按窗口算的理想宽」（`MacTheme.webPagePanelWidth`）代替：那个值窗口极窄时
    /// 照样被 `.inspector` 压缩 —— root 探针实测过 1120 宽的窗口里算出 500、实际只有 342，
    /// 按它给上限，标签条照样盖到会话页的导航上（探针 ⑥ 曾 FAIL）。
    ///
    /// ⚠️ 用**独立的 subject**而不是 `@Published`：宽度变化只需让标签条重算尺寸，
    ///    **不该**走 `objectWillChange`（那会把整条标签重建一遍，窗口一拖就闪）。
    let panelWidthRelay = CurrentValueSubject<CGFloat, Never>(0)

    /// `WebPageContentView` 量到宽度后喂进来（差 <0.5pt 不写，免得拖窗口时抖）。
    func reportPanelWidth(_ width: CGFloat) {
        guard width > 0, abs(width - panelWidthRelay.value) > 0.5 else { return }
        panelWidthRelay.send(width)
    }

    /// 面板实测宽度的**只读出口**（标签条 / 探针用；`0` = 还没量到）。
    /// ⚠️ 留这个只读属性是为了让调用方**不必 import Combine** 去读 subject 的 `.value`
    ///    （本工程开了 `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`，漏 import 会直接报错）。
    var measuredPanelWidth: CGFloat { panelWidthRelay.value }

    private var relays: [AnyCancellable] = []

    // MARK: 构造

    /// 兼容旧调用 / 探针：直接开一个 URL 的标签（首标签）。
    convenience init(url: URL) {
        self.init()
        let tab = WebTabModel(url: url)
        tabs = [tab]
        activeTabIndex = 0
        setupRelay()
    }

    init() {
        tabs = []
        activeTabIndex = 0
        setupRelay()
    }

    // MARK: 标签管理

    /// 打开一个 URL：面板没开则开面板 + 首标签；已开则**新开一个标签**
    /// （与当前激活标签同址则去重，不重复开）。
    func open(url: URL) {
        if let active = activeTab, active.currentURL?.absoluteString == url.absoluteString { return }
        let tab = WebTabModel(url: url)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        setupRelay()
    }

    /// 在面板里打开一个**本地面上的东西**（文件 / 目录），自动按类型分档（2026-10-07）。
    ///
    /// - **目录** ⇒ `.folder`（目录树，见 `FolderTreePane`）；
    /// - `CodeLanguage.forFile(_:)` 认得的扩展名 ⇒ `.code`（代码视图，见 `CodePane`）；
    /// - 其余 ⇒ `.file`（交回 `QLPreviewView`）。
    ///
    /// 🔴 **当前标签正是「起始页」时复用它**，不另开一个 —— 与 `loadURL` 同一条口径：
    ///    用户点「＋」新建的那一页本来就是**为了装东西**的；装完还留一个空标签页在身边，
    ///    等于每次「＋ → 打开文件」都白多一个没人要的标签。
    ///
    /// - Parameter reuseExisting: 同址已经开在某个标签里时，**切过去**而不是再开一个。
    ///   - 目录树里点文件传 `true`：在树里点同一份文件是日常动作（看一眼、翻回去、再点一次），
    ///     每次都多一个一模一样的标签，十来下就满屏了；
    ///   - 会话里的文件消息传 `false`：那是 2026-10-06 定的口径「同一条文件消息点两次
    ///     就开两个标签」（用户能看见自己点了两次）。
    ///   ⚠️ 两条**都是刻意的**，所以做成参数而不是统一成一种 —— 别把其中一条「顺手改齐」。
    func openLocal(url: URL, displayName: String?, reuseExisting: Bool = false) {
        let name = (displayName?.isEmpty == false) ? displayName! : url.lastPathComponent
        if reuseExisting, let existing = tabs.firstIndex(where: { $0.kind.localURL == url }) {
            activeTabIndex = existing
            setupRelay()
            return
        }
        let tab = Self.makeLocalTab(url: url, displayName: name)
        if let active = activeTab, active.isStartPage {
            // 复用起始页那一格：位置不变、内容与标题换掉
            tabs[activeTabIndex] = tab
        } else {
            tabs.append(tab)
            activeTabIndex = tabs.count - 1
        }
        setupRelay()
    }

    /// 按 URL 造出对应档位的标签。
    /// 🔴 **分流的唯一判据在这里**（目录 ⇒ 树 / 认得的扩展名 ⇒ 代码 / 其余 ⇒ QuickLook）——
    ///    ⛔ 别在别处再写一遍扩展名判断（`CodeLanguage.forFile(_:)` 才是那份清单）。
    static func makeLocalTab(url: URL, displayName: String) -> WebTabModel {
        if isDirectory(url) { return WebTabModel(folderURL: url, displayName: displayName) }
        if CodeLanguage.forFile(url) != nil { return WebTabModel(codeURL: url, displayName: displayName) }
        return WebTabModel(fileURL: url, displayName: displayName)
    }

    /// 是不是目录。
    /// ⚠️ 用 `resourceValues` 而不是 `url.hasDirectoryPath`：后者只对**以斜杠结尾的路径字符串**
    ///    可靠，而 `NSOpenPanel` 交回来的 URL 不带尾斜杠（那样判会把目录当文件）。
    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    /// 弹系统「打开」面板挑一个本地文件，开成一个标签（起始页第②行的落点）。
    ///
    /// ⚠️ 沙盒：面板交回来的 URL 对**容器外**的文件带 security scope ——
    ///    授权由各档的 `WebTabModel.init` 持有到那个标签销毁。
    ///    ⛔ **别在这里 start 完就 stop**：QuickLook 是**稍后**才去读那个文件的。
    func openLocalFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = L("打开")
        panel.message = L("选一个文件，在右侧面板里预览")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openLocal(url: url, displayName: url.lastPathComponent)
    }

    /// 弹系统「打开」面板挑一个**文件夹**，开成一棵目录树（起始页第③行的落点，2026-10-07）。
    ///
    /// 🔴 沙盒口径（**这条只能真机确认**）：用户用 `NSOpenPanel` 选中的**目录**，沙盒给的是
    ///    **整棵子树**的读写权限 —— 这正是「选一个文件夹就能浏览里面」的原理。
    ///    ⚠️ 验收台编出来的可执行文件**根本没有沙盒**（它只是个命令行程序，没有 entitlement），
    ///    所以探针里「读得到」**证明不了**带沙盒的真 App 也读得到；这一条要在真机上点一次才算验过。
    /// ⚠️ `canChooseDirectories = true` + `canChooseFiles = false`：面板上先堵住，
    ///    免得用户选了个文件却期待「打开文件夹」。
    func openLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = L("打开")
        panel.message = L("选一个文件夹，在右侧面板里浏览")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openLocal(url: url, displayName: url.lastPathComponent)
    }

    /// 当前激活标签若是**本地面上的东西**（文件 / 目录 / 代码），返回地址 + 显示名。
    /// ⚠️ 收起面板时记的「第二个账本」用它 —— 目录与代码的显示名同样**不在 URL 里**。
    var activeLocal: FileTabInfo? {
        guard let kind = activeTab?.kind,
              let url = kind.localURL,
              let name = kind.localDisplayName else { return nil }
        return FileTabInfo(url: url, displayName: name)
    }

    /// 当前激活标签的**档位**（视图层据此分派画哪一块内容）。
    var activeKind: WebTabKind? { activeTab?.kind }

    /// 当前激活标签若是**交给 QuickLook 的文件**，返回它的地址与显示名
    /// （视图层据此画 `FilePreviewPane` 与导航条的文件档）。
    /// ⚠️ 只有 `.file` 这一档为真 —— 目录与代码各有自己的渲染通道（见 `activeKind`）。
    var activeFile: FileTabInfo? {
        guard let kind = activeTab?.kind, kind.isFilePreview else { return nil }
        return activeLocal
    }

    /// 当前激活标签若是**目录**（内容区据此画目录树、导航条据此换成目录档）。
    var activeFolder: FileTabInfo? {
        guard let kind = activeTab?.kind, kind.isFolder else { return nil }
        return activeLocal
    }

    /// 当前激活标签若是**代码 / 文本文件**。
    var activeCode: FileTabInfo? {
        guard let kind = activeTab?.kind, kind.isCode else { return nil }
        return activeLocal
    }

    /// 把当前标签**换成 QuickLook 那一档**（代码视图打不开时的出路，2026-10-07）。
    /// 位置不变 —— 用户看到的还是「同一个标签」，只是换了渲染通道。
    func switchActiveTabToPreview() {
        guard let kind = activeTab?.kind,
              let url = kind.localURL,
              let name = kind.localDisplayName else { return }
        tabs[activeTabIndex] = WebTabModel(fileURL: url, displayName: name)
        setupRelay()
    }

    func newTab() {
        let tab = WebTabModel(startPage: true)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        setupRelay()
    }

    func selectTab(_ index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }
        activeTabIndex = index
        setupRelay()
    }

    /// 删掉一个标签。**只管标签**，⛔ 不碰面板状态（那是 `ChatModel` 的账）。
    ///
    /// 🔴 生产路径**不直接调它** —— 两个 ✕（导航条那颗 / 标签条每颗胶囊上的）都走
    ///    `ChatModel.closePanelTab(_:)`，由它在删完之后判「空了没有 ⇒ 收掉整块面板」。
    /// ☠️ 别在外面绕过它：删空之后 `setupRelay()` 的空分支把 `webView` / `activeFile` /
    ///    `isStartPage` / `failure` 全置空 ⇒ 没人收面板的话屏幕上只剩一条光秃秃的导航条。
    /// ⚠️ 2026-10-06 顺手删了旧的 `closeActiveTab()`（`closeTab(at: activeTabIndex)`）——
    ///    它零调用点了，而**留着就是坑**：谁再捡起来用一次，那个「空面板」就会复活。
    ///    要关当前标签请用 `ChatModel.closePanelTab(activeTabIndex)`。
    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            // ⚠️ 空的时候把下标归零：此刻 `activeTab` 已经是 nil，归零只是让下一个
            //    进来的标签落在 0 号位（不归零会留下一个越界下标 —— `tabs.remove` 之后
            //    原下标可能已经出界）。
            activeTabIndex = 0
        } else {
            activeTabIndex = min(activeTabIndex, tabs.count - 1)
        }
        setupRelay()
    }

    // MARK: 激活标签的动作（转发）

    func loadIfNeeded() { activeTab?.loadIfNeeded() }
    func loadURL(_ string: String) { activeTab?.loadURL(string) }
    func reload() { activeTab?.reload() }
    func stop() { activeTab?.stop() }
    func goBack() { activeTab?.goBack() }
    func goForward() { activeTab?.goForward() }
    func openInBrowser() { activeTab?.openInBrowser() }
    func zoomIn() { activeTab?.zoomIn() }
    func zoomOut() { activeTab?.zoomOut() }
    func resetZoom() { activeTab?.resetZoom() }
    func fitWidth() { activeTab?.fitWidth() }

    // MARK: 转发订阅

    private func setupRelay() {
        relays.forEach { $0.cancel() }
        relays.removeAll()
        guard let tab = activeTab else {
            webView = nil; address = ""; pageTitle = ""; isLoading = false; progress = 0
            canGoBack = false; canGoForward = false; failure = nil; pageZoom = 1; isStartPage = false
            return
        }
        // 🔴 只有**网页**标签才去拿 `webView`：它是懒创建的计算属性，**读它 = 建它** ⇒
        //    文件标签若照读，会平白多养一个 Web 进程（正是懒创建要避免的那件事）。
        webView = tab.kind.isWeb ? tab.webView : nil
        address = tab.address; pageTitle = tab.pageTitle; isLoading = tab.isLoading
        progress = tab.progress; canGoBack = tab.canGoBack; canGoForward = tab.canGoForward
        failure = tab.failure; pageZoom = tab.pageZoom; isStartPage = tab.isStartPage
        tab.$address.sink { [weak self] v in
            guard let self else { return }
            self.address = v
        }.store(in: &relays)
        tab.$pageTitle.sink { [weak self] v in
            guard let self else { return }
            self.pageTitle = v
        }.store(in: &relays)
        tab.$isLoading.sink { [weak self] v in
            guard let self else { return }
            self.isLoading = v
        }.store(in: &relays)
        tab.$progress.sink { [weak self] v in
            guard let self else { return }
            self.progress = v
        }.store(in: &relays)
        tab.$canGoBack.sink { [weak self] v in
            guard let self else { return }
            self.canGoBack = v
        }.store(in: &relays)
        tab.$canGoForward.sink { [weak self] v in
            guard let self else { return }
            self.canGoForward = v
        }.store(in: &relays)
        tab.$failure.sink { [weak self] v in
            guard let self else { return }
            self.failure = v
        }.store(in: &relays)
        tab.$pageZoom.sink { [weak self] v in
            guard let self else { return }
            self.pageZoom = v
        }.store(in: &relays)
        tab.$isStartPage.sink { [weak self] v in
            guard let self else { return }
            self.isStartPage = v
        }.store(in: &relays)
    }

    /// 窗口标题文案：优先页面 title，没有就用域名（留给 `webpage` 探针那扇真窗口用）。
    ///
    /// ☠️ 调用方必须用 `$pageTitle.sink` 送进来的那个值，不许回头读 `model.pageTitle`
    /// （`@Published` 在 **willSet** 阶段发布 ⇒ 回调里读属性拿到旧值）。
    static func windowTitle(pageTitle: String, url: URL) -> String {
        pageTitle.isEmpty ? (url.host ?? L("网页")) : pageTitle
    }
}

// MARK: - 导航代理

/// `WKWebView` 的导航代理（每个标签一份）。
private final class WebPageNavigationDelegate: NSObject, WKNavigationDelegate {

    weak var model: WebTabModel?

    nonisolated func webView(_ webView: WKWebView,
                             decidePolicyFor navigationAction: WKNavigationAction,
                             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            decisionHandler(MainActorWebPagePolicy.decide(navigationAction, in: webView))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { model?.noteLoadStarted() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { model?.noteLoadFinished() }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        let nsError = error as NSError
        MainActor.assumeIsolated { model?.noteFailure(nsError, url: webView.url) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        MainActor.assumeIsolated { model?.noteFailure(nsError, url: webView.url) }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            model?.noteFailure(NSError(domain: "AsterWebPage", code: 0, userInfo: [
                NSLocalizedDescriptionKey: L("渲染进程被系统回收了"),
            ]), url: webView.url)
        }
    }
}

/// 导航策略（带循环打断器，见类型注释）。
@MainActor
private enum MainActorWebPagePolicy {

    private static let loopWindow: TimeInterval = 3
    private static let maxOpensPerURL = 2
    private static var openLog: [String: [Date]] = [:]

    static func decide(_ navigationAction: WKNavigationAction,
                       in webView: WKWebView) -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""

        // ① 非 http(s)：交回系统。
        if scheme != "http", scheme != "https" {
            if !scheme.isEmpty { NSWorkspace.shared.open(url) }
            return .cancel
        }

        // ② `target=_blank` / `window.open`：先 `.cancel` 再自己 load（顺序要紧）。
        if navigationAction.targetFrame == nil {
            let target = url.absoluteString
            // 闸门 ①：已经在这一页了 ⇒ 不重启
            if webView.url?.absoluteString == target { return .cancel }
            // 闸门 ②：同一地址短时间内被反复替它打开 ⇒ 判为循环，停手
            let now = Date()
            openLog = openLog.compactMapValues { stamps -> [Date]? in
                let fresh = stamps.filter { now.timeIntervalSince($0) < loopWindow }
                return fresh.isEmpty ? nil : fresh
            }
            let recent = openLog[target] ?? []
            guard recent.count < maxOpensPerURL else { return .cancel }
            openLog[target] = recent + [now]

            webView.load(navigationAction.request)
            return .cancel
        }

        return .allow
    }
}

// MARK: - 状态更新（由代理调）

extension WebTabModel {

    func noteLoadStarted() {
        failure = nil
        isLoading = true
    }

    func noteLoadFinished() {
        isLoading = false
        progress = 1
        failure = nil
    }

    func noteFailure(_ error: NSError, url: URL?) {
        isLoading = false
        progress = 0
        // 「被取消」（-999）不是失败：点 `target=_blank` 那一支每次都会先 cancel 再 load。
        if error.code == NSURLErrorCancelled { return }
        failure = Self.describe(error, url: url)
    }

    /// 把 `NSError` 转成给用户看的两段话。
    static func describe(_ error: NSError, url: URL?) -> WebPageFailure {
        let host = url?.host ?? ""
        if error.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            return WebPageFailure(
                message: L("这个网站只支持 http，被系统的安全策略拦住了。"),
                detail: String(format: L("%@ 没有 https。用默认浏览器就能看。"), host.isEmpty ? L("该地址") : host),
                isTransportSecurity: true)
        }
        switch error.code {
        case NSURLErrorNotConnectedToInternet:
            return WebPageFailure(message: L("网络似乎断开了。"), detail: L("检查一下 Wi-Fi 或有线连接。"),
                                  isTransportSecurity: false)
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return WebPageFailure(message: L("找不到这个网站。"), detail: host.isEmpty ? nil : String(format: L("域名：%@"), host),
                                  isTransportSecurity: false)
        case NSURLErrorTimedOut:
            return WebPageFailure(message: L("网站没有响应（超时）。"), detail: host.isEmpty ? nil : String(format: L("域名：%@"), host),
                                  isTransportSecurity: false)
        default:
            return WebPageFailure(message: L("网页加载失败。"),
                                  detail: "\(error.localizedDescription)（\(error.domain) \(error.code)）",
                                  isTransportSecurity: false)
        }
    }
}

// MARK: - 视图

/// 窗口里装的东西：导航条 + 网页（或起始页 / 错误页）。
///
/// 🔴 标签条**不在这里**（2026-09-30 三改定型）：它挂成了 **inspector 列自己的工具栏项**
///    （`RootView` 里 `.toolbar { ToolbarItem(id: "webPageTabs", …) }`，内容是
///    `WebPageTabsBarBridge`）。原因（实测踩出来的）：
///    ① 标签行靠负 padding 画进窗口顶栏带 ⇒ **看得见、点不着**（带内 hitTest 全宽
///       命中 `NSToolbarView`，一个像素都落不到内容上）；
///    ② 挂详情列 `.toolbar` ⇒ 点得着，但落在**面板左侧**（详情区尾端被 inspector 挤过去）；
///    ③ 挂 **inspector 内容自己** ⇒ 系统把它放进面板上方那格工具栏区：位置对 + 点得着。✅
struct WebPageContentView: View {

    @ObservedObject var model: WebPageModel

    /// 关掉当前标签。由 `RootView` 接到 `ChatModel.closePanelTab(_:)` —— 那边在
    /// **删空之后**才收起整块右侧页面（用户 2026-10-06 口径：
    /// 「如果上面标签 剩一个 关闭标签 就关闭整个右侧页面」）。
    /// 这里**不自己改面板状态**（`isWebPagePanelShown` / `webPage` 都不在 `WebPageModel` 上）。
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 🔴 导航条（纯值参数，便于离屏渲染）。标签与「＋」在它**上面的工具栏格里**。
            // 🔴🔴 **起始页不画这一整条导航条**（2026-10-07 用户口径）。
            //
            // 用户原话：「初始化页面的 about:blank 的整行 都可以删除了」。
            // 起始页（`isStartPage`）时这条导航条上**没有一个按钮是有意义的**：
            // 前进/后退恒禁用、刷新没有目标、缩放没有内容、用浏览器打开没有地址，
            // 而中间那颗地址框的唯一内容就是 `about:blank` 这个占位。
            // ⇒ 整条（连同下面那条 1pt 分割线）在起始页**直接不画**。
            //
            // ⚠️ 标签条**不在这里** —— 它是 inspector 的工具栏项（`WebPageTabsBarBridge`），
            //    所以起始页仍然有「新标签页」那颗胶囊可关，不影响「关到空 ⇒ 收面板」那条路。
            // 🔴 判据只认 `model.isStartPage`：地址栏一提交（`loadURL`）它立刻变 false，
            //    导航条随即出现 —— 这正是「从起始页换成真网页」那一刻该有的变化。
            // ⛔ 别改成「把按钮置灰」：用户要的是**这一行不存在**。
            if !model.isStartPage {
                WebPageToolbar(
                    address: model.address,
                    isLoading: model.isLoading,
                    progress: model.progress,
                    canGoBack: model.canGoBack,
                    canGoForward: model.canGoForward,
                    pageZoom: model.pageZoom,
                    onBack: { model.goBack() },
                    onForward: { model.goForward() },
                    onReload: { model.reload() },
                    onStop: { model.stop() },
                    onOpenInBrowser: { model.openInBrowser() },
                    onClose: onClose,
                    onZoomIn: { model.zoomIn() },
                    onZoomOut: { model.zoomOut() },
                    onResetZoom: { model.resetZoom() },
                    onFitWidth: { model.fitWidth() },
                    // 非 nil ⇒ 这是**本地面上的标签**，导航条换成对应那一档（见 `WebPageToolbar`）。
                    // ⚠️ 三档**互斥**：`activeFile` / `activeFolder` / `activeCode` 里最多一个非 nil。
                    file: model.activeFile,
                    folder: model.activeFolder,
                    code: model.activeCode,
                    // 目录档那颗「在访达中显示」的落点。
                    onRevealInFinder: {
                        guard let info = model.activeFolder else { return }
                        NSWorkspace.shared.activateFileViewerSelecting([info.url])
                    }
                )

                Rectangle()
                    .fill(MacTheme.webPageToolbarBorder)
                    .frame(height: 1)
            }

            ZStack {
                // ⚠️ 离屏渲染里只有「黄条 + ⊘」，网页本身验不了，只能真窗口验。
                // 🔴 `.id(activeTabIndex)`：切标签时强制重建，让这块 NSView 换成**另一个标签的**
                //    `WKWebView`（representable 的 `webView` 一旦变化，只有重建才换底层 view）。
                if let wv = model.webView {
                    WebPageWebView(webView: wv)
                        .id(model.activeTabIndex)
                }
                // 🔴 文件标签：内容交给 `QLPreviewView`（2026-10-06）。
                //    ⚠️ 与上面那块 `WKWebView` **互斥** —— 文件标签的 `model.webView` 恒为 nil
                //    （`setupRelay` 里那句 `tab.kind.isWeb ? … : nil`），两条 `if` 不会同时成立。
                //    ☠️ `.id(activeTabIndex)` 不能省：切标签必须**整块重建** ——
                //    representable 换内容靠重建而不是 `updateNSView`（那方法这里是空的），
                //    少了它，从 A 文件切到 B 文件屏幕上还是 A。
                if let file = model.activeFile {
                    FilePreviewPane(url: file.url, title: file.displayName)
                        .id(model.activeTabIndex)
                }
                // 🔴 目录标签：目录树（2026-10-07）。⚠️ 纯 SwiftUI ⇒ 上面那条「必须重建」的
                //    理由（representable）其实不适用，但 `.id` 仍然要留着：切标签时
                //    **滚动位置与展开状态**是标签自己的（`folder` 由 `WebTabModel` 持有），
                //    而 `.id` 保证新标签那一棵树是**新的一块视图**，不会串上一层的位置。
                //    ☠️ 点文件走 `reuseExisting: true`（见 `WebPageModel.openLocal` 的头注：
                //    在树里点同一份文件是日常动作，每次都多一个标签会很快满屏）。
                // 🔴 `folder` 只为「当前是不是目录标签」这道判据存在，body 里用的是 `tree`
                //    ⇒ 判存在即可，别绑变量（Xcode 27 起报 "immutable value 'folder' was
                //    never used"）。
                if model.activeFolder != nil, let tree = model.activeTab?.folder {
                    FolderTreePane(model: tree, onOpenFile: { url in
                        model.openLocal(url: url,
                                        displayName: url.lastPathComponent,
                                        reuseExisting: true)
                    })
                    .id(model.activeTabIndex)
                }
                // 🔴 代码标签：行号 + 语法色的只读视图（2026-10-07）。
                if model.activeCode != nil, let doc = model.activeTab?.code {
                    CodePane(doc: doc, onFallbackToPreview: { model.switchActiveTabToPreview() })
                        .id(model.activeTabIndex)
                }
                // 起始页（新标签还没加载任何站点）：盖在 webView 上，提交网址 / 选完文件后消失。
                if model.isStartPage {
                    WebPageStartPage(onOpen: { model.loadURL($0) },
                                     onOpenFile: { model.openLocalFile() },
                                     onOpenFolder: { model.openLocalFolder() })
                }
                if let failure = model.failure {
                    WebPageErrorView(
                        failure: failure,
                        onRetry: { model.reload() },
                        onOpenInBrowser: { model.openInBrowser() }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MacTheme.pageBackground)
        // 🔴 量「面板**实际**多宽」并喂给模型 —— 标签条的宽度上限用的就是这个值
        //    （见 `WebPageModel.panelWidthRelay` 那段：理想值不可信，`.inspector` 会压缩它）。
        //    ⚠️ 挂在 `.background` 里 ⇒ 参与布局的只有一个 `Color.clear`，不影响本视图。
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { model.reportPanelWidth(geo.size.width) }
                    .onChange(of: geo.size.width) { _, w in model.reportPanelWidth(w) }
            }
        )
        .onAppear { model.loadIfNeeded() }
    }
}

/// `WKWebView` 的 SwiftUI 包装（接受可选，空状态给一个占位 `NSView`）。
private struct WebPageWebView: NSViewRepresentable {
    let webView: WKWebView?
    func makeNSView(context: Context) -> NSView { webView ?? NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 新标签的起始页：**一列「图标 + 文字」的胶囊行**。
///
/// 🔴 2026-10-06 **二改**（用户：「起始页 改成图片的样式」）：原版是
/// 「globe 大图标 + 一句说明文字 + 输入框 + 打开 按钮 + 打开本地文件 按钮」，
/// 现在改成一列胶囊行 —— **大图标与说明文字都删了**（图里没有），
/// 那行输入框**自己就是第一行**。
///   ① `magnifyingglass` 搜索或输入网址（输入框本体，回车提交）
///   ② `doc` 打开文件 —— **真功能**，落点仍是 `onOpenFile`（旧版那颗按钮）
///   ③ `folder` 打开文件夹 —— 🔴 **真功能**（2026-10-07 落地）
///
/// 2026-10-07：用户在起始页截图上圈着第③行问「打开文件夹的功能 可以做成图中这样
/// 目录树显示吗？」⇒ 这一行不再是占位，落点 `onOpenFolder`（走
/// `NSOpenPanel.canChooseDirectories`，选中的目录开一个 `.folder` 标签渲染目录树）。
///
/// 🔴🔴 2026-10-07 **三改：第④行「打开终端」整行删掉**（用户原话：「那还是算了 不做终端了。
/// 把初始页的 打开终端按钮删除吧」）。⛔ 别把它加回来 —— 那不是「形态要看四行」的问题，
/// 是**做过可行性实测、结论为「代价远超收益」**（下面是原始结论，别凭印象重估）：
///
/// | 想要的形态 | 沙盒下可行性 |
/// |---|---|
/// | 拉起系统 Terminal.app | ✅ 能，但只能开成 `~`（带目录 `permErr -54`；Apple Events 也被封） |
/// | **面板内嵌真终端**（豆包那样） | ✅ 技术上通（`openpty` + `posix_spawn("/bin/zsh")` + 读写 PTY 全部实测通过），
///    但那是**一整套终端模拟器**：VT 解析器（光标/擦除/滚动区/备用屏幕）+ 字符网格自绘 +
///    ANSI 16/256/truecolor + 键盘编码 + 跨 chunk 转义序列状态机 ⇒ **1200~1800 行**。
///    本工程至今最大的单块工作量，收益是一个本机开发者不常用的功能 ⇒ 不做。
///
/// 📌 若将来非做不可，三个坑已经踩平了，**别重走**：
///   ① ⛔ 别用 `forkpty` —— 在 GUI 进程里它会挂（实测子进程立刻死、`write` 报 EPERM）
///      ⇒ 用 `posix_spawn` + `posix_spawn_file_actions_adddup2` 把 slave 接到 0/1/2；
///   ② `posix_spawn_file_actions_t` 在 Swift 里是**可空 raw pointer 包装**
///      ⇒ 必须 `withUnsafeMutablePointer(to:&rawActions)`，直接 `var fa = …()` 编译不过；
///   ③ ⚠️ 沙盒下 **`stdout` 不可靠**（连 `print` 都会让进程 exit 133）
///      ⇒ 调试日志一律写容器内文件，别指望打印到控制台。
///   另：`NSViewRepresentable` 在离屏渲染台里是黄条 + ⊘ ⇒ 网格要用纯 SwiftUI 画才验得到。
struct WebPageStartPage: View {

    let onOpen: (String) -> Void

    /// 「打开文件」。⚠️ 带默认值：这是**新增**的回调，给默认值能让
    /// 已经存在的构造点（渲染台那些「只验长相」的板）一行都不用改。
    var onOpenFile: () -> Void = {}

    /// 「打开文件夹」。同上带默认值（渲染台老板不改也能编过）。
    var onOpenFolder: () -> Void = {}

    @State private var text = ""
    /// 指针正划过哪一行（`nil` = 没划过）。⚠️ **只换底色、不参与布局**
    /// —— 与本工程所有可点行同一口径（`MAC-UI-RULES` 铁律 3）。
    /// 用一个 `Int?` 而不是每行一个 `Bool`：同一时刻只可能划过一行。
    @State private var hoveredRow: Int?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: MacTheme.webPageStartRowSpacing) {
            addressRow                       // ① 搜索 / 输入网址
            openFileRow                      // ② 打开文件
            openFolderRow                    // ③ 打开文件夹
        }
        // ⚠️ 顺序不能反：先定**列的宽度上限**、再加两侧留白。
        //    写成「padding 在前」的话 420 会变成「含留白的总宽」，窄面板里会算少 32。
        //    窄面板（340）时上限根本不生效 —— 行的宽度就是「可用宽 − 两侧留白」。
        .frame(maxWidth: MacTheme.webPageStartMaxWidth)
        .padding(.horizontal, MacTheme.webPageStartColumnInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacTheme.pageBackground)
    }

    // MARK: - 三行

    /// ① 搜索 / 输入网址。⚠️ 它不是按钮，是个**长得像行**的输入框
    ///    （图里第一行就是它：放大镜 + 灰字占位）。
    private var addressRow: some View {
        HStack(spacing: MacTheme.webPageStartIconSpacing) {
            Image(systemName: "magnifyingglass")
                .font(MacTheme.ui(MacTheme.webPageStartIconFontSize))
                .foregroundStyle(MacTheme.webPageToolbarIcon)
                .frame(width: MacTheme.webPageStartIconWidth)
            TextField(L("搜索或输入网址"), text: $text)
                .textFieldStyle(.plain)
                .font(MacTheme.ui(MacTheme.webPageStartFontSize))
                .foregroundStyle(MacTheme.bodyColor)
                .onSubmit { submit() }
        }
        .modifier(StartPageRowChrome(scheme: scheme, hovered: hoveredRow == 0))
        .onHover { trackHover(0, $0) }
    }

    /// ② 打开文件。🔴 这一行是**真功能**（旧版那颗「打开本地文件」按钮的落点）。
    /// ⚠️ `Button(action: onOpenFile)` 这个字面**不能动**：源码契约钉着它
    ///    （`render_mac_ui.sh` 里「起始页那颗按钮断线了」那三条）。
    private var openFileRow: some View {
        Button(action: onOpenFile) {
            startPageLabel(icon: "doc", title: L("打开文件"))
        }
        .buttonStyle(.plain)
        .modifier(StartPageRowChrome(scheme: scheme, hovered: hoveredRow == 1))
        .onHover { trackHover(1, $0) }
        .help(L("从磁盘上选一个文件，在右侧面板里预览"))
    }

    /// ③ 打开文件夹。🔴 真功能（2026-10-07）。与 `openFileRow` 同型：
    ///    唯一差别是图标与落点。选中的目录会被 `WebPageModel.openLocal`
    ///    识别成目录 ⇒ 开 `.folder` 标签渲目录树。
    private var openFolderRow: some View {
        Button(action: onOpenFolder) {
            startPageLabel(icon: "folder", title: L("打开文件夹"))
        }
        .buttonStyle(.plain)
        .modifier(StartPageRowChrome(scheme: scheme, hovered: hoveredRow == 2))
        .onHover { trackHover(2, $0) }
        .help(L("从磁盘上选一个文件夹，在右侧面板里以目录树展开"))
    }

    /// 一行里「图标 + 文字」的内容。🔴 图标列**定宽**（见 `webPageStartIconWidth`）
    /// ⇒ 三行的文字左缘严格对齐（三个 SF Symbol 的实际宽窄差得不少）。
    ///
    /// ⛔ 2026-10-07 起**没有 `enabled` 参数了**：它只服务已删除的「打开终端」占位行
    /// （那一行要靠 `enabled == false` 手动降色 + 降透明度）⇒ 唯一调用点没了就一起删，
    /// 别把 `webPageToolbarIconDisabled` / `webPageStartPlaceholderOpacity` 挂回来。
    private func startPageLabel(icon: String, title: String) -> some View {
        HStack(spacing: MacTheme.webPageStartIconSpacing) {
            Image(systemName: icon)
                .font(MacTheme.ui(MacTheme.webPageStartIconFontSize))
                .frame(width: MacTheme.webPageStartIconWidth)
            Text(title)
                .font(MacTheme.ui(MacTheme.webPageStartFontSize))
        }
        // ⚠️ 颜色在这里定稿（不是外面套一层）：`foregroundStyle` 越靠内优先级越高，
        //    外层再套一个是**盖不住**这层的。
        .foregroundStyle(MacTheme.bodyColor)
        // 🔴🔴 **整行可点（2026-10-07 修）** —— 这两句必须写在 **label 里面**。
        //
        // ☠️ 症状：起始页那几行只有「图标 + 文字」能点，**行右侧的空白点了没反应**
        //    （用户原话：「打开文件 和打开文件夹 现在只有 icon 响应点击事件」）。
        // ☠️ 成因：`Button(action:)` 的可点范围**等于 label 自己的边界**，而 label 只有
        //    「图标 + 文字」那么宽。外面那层 `StartPageRowChrome` 的 `padding` /
        //    `frame(maxWidth: .infinity)` / `contentShape` 统统套在 **Button 之外** ——
        //    它们撑开的是「这个按钮被摆在多宽的容器里」，**不会**扩大按钮自身。
        //    ⚠️ 也就是说：那层 `contentShape` 管得住 **hover**（`.onHover` 挂在 Button
        //    外层，命中的是整行），却管不住**点击**（点击进不到 Button 里面去）。
        //    ⇒ 这就是「hover 整行都亮、点下去只有图标有反应」这个不对称的来源。
        // ✅ 解法：让 label 自己吃掉整行宽，再在它身上定 `contentShape` —— 这样 Button
        //    的边界就是整行，`StartPageRowChrome` 那层 padding 也就顺理成章地成了
        //    「按钮内边距」（视觉与之前逐像素一致，因为整行宽度本来就没变）。
        // ⛔ 别改回「只在外层 chrome 上加 contentShape」：那条路验过了，不生效。
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 指针进出一行时的记账。
    /// ⚠️ 「离开」只在**当前记的就是我**时才清 —— 从 A 行移到 B 行时，A 的离开事件
    ///    与 B 的进入事件谁先到**不确定**，无条件清会把 B 刚点亮的高亮抹掉。
    private func trackHover(_ index: Int, _ inside: Bool) {
        if inside {
            hoveredRow = index
        } else if hoveredRow == index {
            hoveredRow = nil
        }
    }

    private func submit() {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { onOpen(s) }
    }
}

/// 起始页每一行的**外观**（胶囊底 + 描边 + hover 高亮）—— 三行共用。
///
/// ⚠️ 刻意抽成 `ViewModifier` 而**不是**子 `View`：`Button` 必须画在**调用点**上
/// （源码契约钉着起始页那颗「打开文件」的 `Button(action: onOpenFile)` 字面），
/// 换成子 View 会把那个字面藏进去 ⇒ 契约失配。
///
/// 🔴 行底常态**不填色**（透出 `pageBackground`）：浅色下页面底本来就是纯白，
/// 再填一层 `controlBackgroundColor` 也还是白 ⇒ 只会多一层看不见的底。
/// 与卡片同口径 —— **只靠描边**从页面分出来；hover 才浮起来，且复用侧栏入口行那支
/// 半透明底（工程口径：「能点的行」反馈必须一致）。
///
/// ⛔ 2026-10-07 起**没有 `dimmed` 参数了**（连同 `.opacity` 那句）：它只服务已删除的
/// 「打开终端」占位行（`.disabled` 管得了点击、管不了自绘观感，只能手动压一档透明度）。
/// ⛔ 别把它挂回来 —— 现在**每一行都是真能点的**，压暗等于骗用户。
private struct StartPageRowChrome: ViewModifier {

    let scheme: ColorScheme
    let hovered: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, MacTheme.webPageStartRowPaddingH)
            .padding(.vertical, MacTheme.webPageStartRowPaddingV)
            // ⚠️ 弹性 + 左对齐：三行必须**等宽**（图里就是齐刷刷的几条），
            //    内容各从自己那行的左缘起。
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MacTheme.webPageStartRowRadius, style: .continuous)
                    .fill(hovered ? MacTheme.quickEntryHoverBackground(scheme) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MacTheme.webPageStartRowRadius, style: .continuous)
                    .strokeBorder(MacTheme.webPageToolbarBorder, lineWidth: 1)
            )
            // ⚠️ 这条 `contentShape` 管的是**这一层合成视图**的命中形状 —— 也就是
            //    **hover 的范围**（`.onHover` 挂在 Button 外层，事件落在这里）。
            // ☠️ 它**管不了 Button 的点击**：点击必须落在 Button 自己的边界内才会触发
            //    `action`，而那是 label 撑出来的（见 `startPageLabel` 里那两句
            //    `frame(maxWidth: .infinity)` + `contentShape`，2026-10-07 修）。
            //    ⛔ 别以为有了这一条就「整行可点」—— 旧版正是这么以为的，
            //    结果是「hover 整行亮、点下去只有图标有反应」。
            .contentShape(
                RoundedRectangle(cornerRadius: MacTheme.webPageStartRowRadius, style: .continuous)
            )
    }
}

// ⚠️ 2026-10-04 删除：旧的 **SwiftUI 标签条**三件套（`WebPageTabItem` /
//    `WebPageTabStripView` / `WebPageInlineTabPill`）—— 真机自 2026-10-02 起走 AppKit 桥
//    `WebPageTabsBarBridge`（见下面那个 MARK），这套 SwiftUI 版唯一的使用者是**离屏渲染台**
//    的 `webPageTabRowBoard()` 那一档；该档已随之撤掉。要恢复：备份在
//    `/tmp/starry_deadcode_backup`。

/// 导航条（纯值参数，便于离屏渲染）。
struct WebPageToolbar: View {

    let address: String
    let isLoading: Bool
    let progress: Double
    let canGoBack: Bool
    let canGoForward: Bool
    let pageZoom: Double
    let onBack: () -> Void
    let onForward: () -> Void
    let onReload: () -> Void
    let onStop: () -> Void
    let onOpenInBrowser: () -> Void
    /// 关掉当前标签。⚠️ **关掉的若是最后一个标签，整块右侧页面跟着收起** ——
    /// 判据在 `ChatModel.closePanelTab(_:)`（见 `WebPageContentView.onClose` 那份头注）。
    let onClose: () -> Void
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void
    let onResetZoom: () -> Void
    let onFitWidth: () -> Void

    /// 非 `nil` ⇒ 这是**文件**标签 ⇒ 导航条换成「文件档」（`fileRow`）。
    ///
    /// ⚠️ 带默认值 `nil`（= 网页标签）：本视图在渲染台里有多处构造点，
    ///    给默认值能让它们一行都不用改。
    var file: FileTabInfo? = nil

    /// 非 `nil` ⇒ 这是**目录**标签 ⇒ 导航条换成「目录档」（`folderRow`，2026-10-07 加）。
    var folder: FileTabInfo? = nil

    /// 非 `nil` ⇒ 这是**代码**标签 ⇒ 导航条换成「代码档」（`codeRow`，2026-10-07 加）。
    var code: FileTabInfo? = nil

    /// 目录档那颗「在访达中显示」的落点（2026-10-07 加）。
    /// ⚠️ 带默认值：渲染台那些「只验长相」的板不必关心它。
    var onRevealInFinder: () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    private var zoomPercent: Int { Int((pageZoom * 100).rounded()) }

    var body: some View {
        VStack(spacing: 0) {
            // 🔴 本地面四档**互斥**（`activeFile` / `activeFolder` / `activeCode` 最多一个非 nil）。
            //    顺序：文件 → 目录 → 代码 → 网页。⛔ 别写成 `if file … else if folder …`
            //    之外的形式 —— 网页档必须落到最后的 `else`。
            if let file {
                // 🔴 文件档（2026-10-06）：整条换掉，不是「把网页档的按钮置灰」——
                //    前进 / 后退 / 刷新 / 缩放 / 进度条**一条都不该出现**，见 `localRow`。
                localRow(icon: "doc.fill",
                         info: file,
                         actionIcon: "arrow.up.forward.app",
                         actionHelp: L("用默认应用打开"),
                         action: onOpenInBrowser)
                    .frame(height: MacTheme.webPageBarHeight)
            } else if let folder {
                // 🔴 目录档（2026-10-07）：与文件档同型，第二颗按钮换成「在访达中显示」
                //    （目录在 QuickLook 里的表现不如直接交给访达）。
                localRow(icon: "folder.fill",
                         info: folder,
                         actionIcon: "arrow.up.forward.app",
                         actionHelp: L("在访达中显示"),
                         action: onRevealInFinder)
                    .frame(height: MacTheme.webPageBarHeight)
            } else if let code {
                // 🔴 代码档（2026-10-07）：同上，第二颗按钮是「用默认应用打开」
                //    —— 想在真编辑器里改，这颗是唯一出路（面板里是只读视图）。
                localRow(icon: "curlybraces",
                         info: code,
                         actionIcon: "arrow.up.forward.app",
                         actionHelp: L("用默认应用打开"),
                         action: onOpenInBrowser)
                    .frame(height: MacTheme.webPageBarHeight)
            } else {
                // 🔴 宽度自适应（2026-09-30）：这一行要装
                //    「← → ⟳ · 地址栏 · 缩放簇 · 出路 · 关闭」—— 窄面板装不下，
                //    硬塞会把**最右那颗「关闭当前标签」顶出画面**（渲染图
                //    `webpage_bar_loaded_narrow` 亲眼见过）。
                //    ⇒ 量这一行的宽：窄档撤掉「缩放簇 + 用浏览器打开」（缩放仍有 ⌘ 快捷键），
                //    把宽度让给**地址栏**这项最不能少的。
                GeometryReader { geo in
                    toolbarRow(compact: geo.size.width < MacTheme.webPageToolbarCompactWidth)
                }
                .frame(height: MacTheme.webPageBarHeight)

                GeometryReader { geometry in
                    Rectangle()
                        .fill(MacTheme.webPageProgressTint)
                        .frame(width: geometry.size.width * min(max(progress, 0), 1))
                }
                .frame(height: MacTheme.webPageProgressHeight)
                .opacity(progress > 0 && progress < 1 ? 1 : 0)
            }
        }
        .background(MacTheme.webPageToolbarBackground(scheme))
    }

    /// 本地面（文件 / 目录 / 代码）共用那一行：`[图标] 名字 …………… [出路] [✕]`。
    ///
    /// ⛔ **别把网页档那几颗搬过来**：前进 / 后退 / 刷新 / 缩放 / 进度条都是「网页」特有的概念，
    /// 摆在本地面标签上只会是一排点了没反应的按钮（翻页与缩放归 QuickLook / 代码视图自己管）。
    /// ⇒ 只留三样：**它是什么**（图标 + 名字）、**丢给别的去处**、**关掉**。
    ///
    /// 三档的唯一差别就是 `icon`（`doc.fill` / `folder.fill` / `curlybraces`）与那颗出路的落点
    /// （文件/代码 = 用默认应用打开；目录 = 在访达中显示）⇒ 收成一个函数，⛔ 别复制三份。
    private func localRow(icon: String,
                          info: FileTabInfo,
                          actionIcon: String,
                          actionHelp: String,
                          action: @escaping () -> Void) -> some View {
        HStack(spacing: MacTheme.webPageToolbarSpacing) {
            Image(systemName: icon)
                .font(MacTheme.ui(MacTheme.webPageToolbarIconSize))
                .foregroundStyle(MacTheme.webPageToolbarIcon)

            // 名字走 `info.displayName`（用户认得的那个），⛔ **不是** `url.lastPathComponent`
            // —— 会话附件的磁盘名是 UUID（`52EDE56F-….xlsx`）。
            // ⚠️ `.help` 给的才是**磁盘路径**：用户真要找这个文件时，需要的正是它。
            Text(info.displayName)
                .font(MacTheme.ui(MacTheme.webPageAddressFontSize))
                .foregroundStyle(MacTheme.webPageAddressText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: MacTheme.webPageToolbarButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(MacTheme.webPageAddressBackground(scheme))
                )
                .help(info.url.path)

            iconButton(actionIcon, help: actionHelp, enabled: true, action: action)
            iconButton("xmark", help: L("关闭当前标签页"), enabled: true, action: onClose)
        }
        .padding(.horizontal, MacTheme.webPageToolbarPaddingH)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// 导航条那一行（`compact` = 窄档：撤掉缩放簇与「用浏览器打开」）。
    private func toolbarRow(compact: Bool) -> some View {
        HStack(spacing: MacTheme.webPageToolbarSpacing) {
            iconButton("chevron.left", help: L("后退"), enabled: canGoBack, action: onBack)
            iconButton("chevron.right", help: L("前进"), enabled: canGoForward, action: onForward)
            if isLoading {
                iconButton("xmark", help: L("停止加载"), enabled: true, action: onStop)
            } else {
                iconButton("arrow.clockwise", help: L("重新加载"), enabled: true, action: onReload)
            }

            addressLabel

            // 🔴 缩放簇（2026-09-30 当晚加）：− / 百分比(⌘0) / + / 适配宽度。
            //    ⚠️ 窄档撤掉它们（只是**不显示**；`⌘+ / ⌘- / ⌘0` 三颗快捷键照旧可用）。
            if !compact {
                zoomButton("minus.magnifyingglass", help: L("缩小（⌘-）"), action: onZoomOut)
                    .keyboardShortcut("-", modifiers: .command)
                Button(action: onResetZoom) {
                    Text("\(zoomPercent)%")
                        .font(MacTheme.ui(11))
                        .foregroundStyle(MThemeZoomText)
                        .frame(minWidth: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("重置缩放（⌘0）"))
                .keyboardShortcut("0", modifiers: .command)
                zoomButton("plus.magnifyingglass", help: L("放大（⌘+）"), action: onZoomIn)
                    .keyboardShortcut("+", modifiers: .command)
                zoomButton("arrow.up.left.and.arrow.down.right", help: L("适配宽度"), action: onFitWidth)

                iconButton("safari", help: L("用默认浏览器打开"), enabled: true, action: onOpenInBrowser)
            }
            iconButton("xmark", help: L("关闭当前标签页"), enabled: true, action: onClose)
        }
        .padding(.horizontal, MacTheme.webPageToolbarPaddingH)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var addressLabel: some View {
        Text(address.isEmpty ? "about:blank" : address)
            .font(MacTheme.ui(MacTheme.webPageAddressFontSize))
            .foregroundStyle(MacTheme.webPageAddressText)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: MacTheme.webPageToolbarButtonSize)
            .background(
                RoundedRectangle(cornerRadius: 6).fill(MacTheme.webPageAddressBackground(scheme))
            )
            .help(address)
    }

    private func iconButton(_ systemName: String,
                            help: String,
                            enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(MacTheme.ui(MacTheme.webPageToolbarIconSize))
                .foregroundStyle(enabled ? MacTheme.webPageToolbarIcon : MacTheme.webPageToolbarIconDisabled)
                .frame(width: MacTheme.webPageToolbarButtonSize,
                       height: MacTheme.webPageToolbarButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    /// 缩放按钮（图标 + 命令快捷键）。
    private func zoomButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(MacTheme.ui(MacTheme.webPageToolbarIconSize))
                .foregroundStyle(MacTheme.webPageToolbarIcon)
                .frame(width: MacTheme.webPageToolbarButtonSize,
                       height: MacTheme.webPageToolbarButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 缩放百分比文字色（与图标同支，避免新增主题项）。
    private var MThemeZoomText: Color { MacTheme.webPageToolbarIcon }
}

// MARK: - 标签条的 **AppKit 桥**（2026-10-02 定案，五轮实验换来的）

/// 🔴🔴 标签条为什么**绕开 SwiftUI**（2026-10-02 root 探针 + 截图，五轮实验全灭）：
/// macOS 的 `ToolbarItem` 内容是一次性**快照** —— 下面这些全都带不动它：
///   ① 内容 View 的 `@ObservedObject`（`objectWillChange` 不进这条更新管线）；
///   ② 在内容上挂 `.id(标签指纹)` 强制重建（那行根本没机会重新求值）；
///   ③ `TimelineView(.periodic)` 时钟（同样不 tick）；
///   ④ `RootView.body` 重算 + `ToolbarItem` 的 **id 带指纹**（`RootView` 不订阅
///      `WebPageModel` ⇒ body 根本不重算；即便重算，NSToolbar 桥对同 id 项
///      也直接复用旧 `NSToolbarItem`，新内容被丢掉）。
/// 实测现象：模型里 2 个标签、项宽 308pt 足够（诊断证实），条上永远只画**最初那 1 个胶囊**。
///
/// ⇒ 这座桥在 `makeNSView` 时拿住 `WebPageModel`，**自己** `objectWillChange.sink`，
///    模型一动直接重建 AppKit 子视图 —— 完全不经 SwiftUI 的 diff / 更新管线。
///    ⚠️ `updateNSView` 在快照机制下多半调不到，别把「换模型」指望它：
///       面板被彻底关掉再开时 inspector 内容整个重建 ⇒ `makeNSView` 重跑 ⇒ 新模型接上。
///    ⚠️ 位置（「面板上方那条带」）与可点性是 2026-09-30 定的（真窗口 hitTest 实测：
///       负 padding 画进带里的内容**看得见点不着**；只有真工具栏项两头都对）——
///       这个桥保住了位置与可点性，只是把「画胶囊」从 SwiftUI 换成 AppKit。
struct WebPageTabsBarBridge: NSViewRepresentable {

    @ObservedObject var model: WebPageModel

    /// 点标签胶囊上那颗 ✕ 时要做什么。
    ///
    /// 🔴 **必填，而且必须接到 `ChatModel.closePanelTab(_:)`**（2026-10-06）——
    ///    关掉的若是**最后一个**标签，整块右侧页面要跟着收起来。
    ///    ⛔ 接不上就只能退回 `WebPageModel.closeTab(at:)`，那会留下一块**空面板**
    ///    （内容区什么都画不出来，只剩一条导航条）—— 正是用户报的那个样子。
    /// ⚠️ 为什么不让 `WebPageModel` 自己判「空了没有」：收面板是 `ChatModel` 的账
    ///    （`webPage` 与 `isWebPagePanelShown` 都在那边），`WebPageModel` 看不到它。
    let onCloseTab: (Int) -> Void

    func makeNSView(context: Context) -> WebPageTabsBar {
        let bar = WebPageTabsBar()
        bar.attach(model)
        bar.onCloseTab = onCloseTab
        return bar
    }

    func updateNSView(_ nsView: WebPageTabsBar, context: Context) {
        // ⚠️ 只处理「模型实例换了」（面板被彻底关掉又重开）。
        //    同实例的标签增删走 `objectWillChange` 那条订阅，不指望这里。
        nsView.attach(model)
        // ⚠️ 闭包**不能**写进 `attach()`：那里有 `guard model !== newModel else { return }`，
        //    同实例重入会被挡掉 ⇒ 换闭包就丢了。
        nsView.onCloseTab = onCloseTab
    }
}

/// AppKit 版标签条：**横向滚动**的胶囊行 ｜ 末尾一颗常驻「＋」。
/// 功能对齐 SwiftUI 版（点得到 / 选中高亮 / 随模型增删 / 语义色自适应深浅色）。
///
/// 🔴🔴 为什么里面是 `NSScrollView`（2026-10-02，用户报「标签增多后会溢出到会话页面的导航上」）：
///    这条是**窗口工具栏项** —— 它报多宽，工具栏就占多宽。标签一路加、宽度一路涨，
///    涨到把整条工具栏撑爆（系统只能开始把项往外挤），表现就是标签**溢到会话页面的导航上**。
///    ⇒ 本条的宽度**自己 clamp** 到「**面板实际列宽** − 余量」；超出的标签**滚**着看。
///    ☠️ 上限为什么不用「按窗口算的理想宽」（`MacTheme.webPagePanelWidth`）现算：
///       那个值窗口极窄时照样被 `.inspector` 压缩 —— root 探针实测 1120 的窗口里
///       算出 500、实际只有 342 ⇒ 按它给上限，条照样盖到会话页导航上（⑥ 曾 FAIL）。
///       正解是**面板自己量**（`WebPageModel.panelWidthRelay`），本条订阅它。
///    ⚠️ 不挂横向滚动条（`hasHorizontalScroller = false`）：22pt 的条里再塞一条滚动条
///       会把胶囊挤没。触控板横滑 / 滚轮横滚照常，把面板或窗口拖宽也能让它们露出来。
///    ⚠️「＋」**不参与滚动**（固定在条的最右）—— 否则标签一多它先滚出视野，
///       新建标签还得先滚到底。标签少时整条收缩到内容宽 ⇒「＋」天然**紧跟最后一个标签**
///       （那是用户 2026-09-30 明确要求过的，别弄丢）。
///    ⛔ 别退回「设上限 + 裁掉」：2026-10-02 实测，2 个标签时上限会把第 2 个整个裁没。
final class WebPageTabsBar: NSView {

    /// 胶囊行与「＋」之间的间距（`layout()` 里手写 frame 也要用 ⇒ 落成常量，免得两处不一致）。
    private static let gap: CGFloat = 6

    private var model: WebPageModel?
    private var cancellable: AnyCancellable?
    /// 点胶囊上那颗 ✕ 时的落点（由 `WebPageTabsBarBridge` 从 `RootView` 接进来）。
    ///
    /// 🔴 见 `WebPageTabsBarBridge.onCloseTab` 那份头注：**只有它知道**
    ///    「关掉最后一个标签」要不要连带收起整块右侧页面（那是 `ChatModel` 的账）。
    /// ⚠️ `nil` 只可能出现在非生产构造点 —— 那时退回 `model.closeTab(at:)`，
    ///    代价是留一块空面板（内容区画不出东西）。
    var onCloseTab: ((Int) -> Void)?
    /// 宽度那条订阅（`panelWidthRelay`）—— 与「标签变了」那条分开，见 `attach` 的注释。
    private var widthCancellable: AnyCancellable?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let plusButton = NSButton()

    /// 面板**实际**列宽（由 `WebPageModel.panelWidthRelay` 喂进来）。`0` = 还没量到。
    private var panelWidth: CGFloat = 0
    /// 上次算出来的宽度上限（`layout()` 里比对用：值**真变了**才作废尺寸，否则会空转）。
    private var lastMaxWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 🔴 宽度**只由 `intrinsicContentSize` 说了算**：不许被拉伸（拉伸＝又溢出去），
        //    也不许被无谓压缩（压缩＝胶囊挤成一团）。
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        // ⚠️ `documentView`（= `stack`）走 **frame 布局**（在 `layout()` 里自己摆）。
        //    ⛔ 别改成「AutoLayout 贴 `contentView`」：那样 clipView 会把 stack 拉满可视宽，
        //    内容一超出就滚不动了（等于白装一个 scrollView）。
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        stack.orientation = .horizontal
        stack.spacing = Self.gap
        stack.alignment = .centerY
        scrollView.documentView = stack
        addSubview(scrollView)

        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: L("新建标签页"))
        plusButton.isBordered = false
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.toolTip = L("新建标签页")
        plusButton.target = self
        plusButton.action = #selector(didNewTab(_:))
        addSubview(plusButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// 接上模型（`makeNSView` / 模型实例真的换了时）。
    /// 同实例重入无害：`guard` 挡掉，订阅不会被建两份。
    func attach(_ newModel: WebPageModel) {
        guard model !== newModel else { return }
        model = newModel
        // 🔴 `objectWillChange` 是**同步**在主线程发的（模型只在主线程改）⇒
        //    不需要 `receive(on:)`，直接重建。（加了反而把 Sendable 隔离搅进来。）
        cancellable = newModel.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.rebuild()
        }
        // 🔴 宽度**单独一条订阅**（不混进 `objectWillChange`）：面板列宽变了只需重算尺寸，
        //    没必要把整条标签重建（拖窗口 / 拖分隔条时那是每帧一次，会闪）。
        //    ⚠️ `CurrentValueSubject` 会**立刻**把当前值推过来（面板已量过时不用等下一次布局）。
        widthCancellable = newModel.panelWidthRelay.sink { [weak self] w in
            guard let self, w > 0, abs(w - self.panelWidth) > 0.5 else { return }
            self.panelWidth = w
            self.lastMaxWidth = 0        // 作废缓存 ⇒ 下一轮 `layout()` 重算并报新尺寸
            self.invalidateIntrinsicContentSize()
            self.needsLayout = true
        }
        rebuild()
    }

    // MARK: 宽度（本条自己说了算 —— 这就是「标签只在 web 页面里」那道闸门）

    /// 宽度上限 = **面板实际列宽** − 两侧余量（面板宽由 `WebPageModel.panelWidthRelay` 喂）。
    /// ⚠️ 面板还没量到时退回「按窗口算的合理宽」—— 那**只是首帧的合理尺寸**，
    ///    真正生效的是量到之后那个值（差一两帧收敛）。
    ///    ⚠️ 按窗口算的那个值是 **`ideal` 口径**、⛔ **不是**实测值：窗口极窄时 `.inspector`
    ///       照样压缩它（实测 1120 里算 500、实际 342），所以上限的权威来源始终是 `panelWidth`。
    private var currentMaxWidth: CGFloat {
        let panel = panelWidth > 0 ? panelWidth : idealPanelWidth
        return max(MacTheme.webPageTabStripMinWidth, panel - MacTheme.webPageTabStripSideInset)
    }

    private var idealPanelWidth: CGFloat {
        guard let w = window?.frame.width, w > 0 else { return MacTheme.webPagePanelMinWidth }
        return MacTheme.webPagePanelHalfWidth(windowWidth: w)
    }

    /// 报给 `NSToolbarItem` 的尺寸：**内容需要这么宽，但不超过上限**。
    /// ⇒ 标签再多也只把数字推到上限为止，不会再往外挤会话页面的导航。
    override var intrinsicContentSize: NSSize {
        let wanted = stack.fittingSize.width + Self.gap + plusButton.fittingSize.width
        let width = min(max(wanted, MacTheme.webPageTabStripMinWidth), currentMaxWidth)
        return NSSize(width: width, height: MacTheme.webPageTabPillHeight)
    }

    override func layout() {
        super.layout()
        // ⚠️ 上限的**来源**是订阅 `panelWidthRelay`（面板自己量的宽度），这里只负责
        //    「值变了就作废尺寸、重报一次」。⛔ 别在这里自己按窗口宽算 —— 理想值会偏大。
        let limit = currentMaxWidth
        if abs(limit - lastMaxWidth) > 0.5 {
            lastMaxWidth = limit
            invalidateIntrinsicContentSize()
        }

        let h = bounds.height
        let plusSize = plusButton.fittingSize
        let contentWidth = stack.fittingSize.width
        // 可视宽 = 本条宽 −「＋」− 那道间距。内容比它窄时**收缩到内容宽**
        // ⇒「＋」自然紧跟最后一个标签，而不是钉在条的最右。
        let available = max(bounds.width - plusSize.width - Self.gap, 0)
        let scrollWidth = min(contentWidth, available)

        scrollView.frame = NSRect(x: 0, y: 0, width: scrollWidth, height: h)
        // documentView 至少要跟可视区一样宽，否则内容窄于可视区时会被拉伸铺满。
        stack.frame = NSRect(x: 0, y: 0, width: max(contentWidth, scrollWidth), height: h)
        plusButton.frame = NSRect(x: scrollWidth + Self.gap,
                                  y: (h - plusSize.height) / 2,
                                  width: plusSize.width,
                                  height: plusSize.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 上窗前 `idealPanelWidth` 那条兜底算不出来 ⇒ 作废缓存、重算一次尺寸。
        lastMaxWidth = 0
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// 整条重建。标签增删 / 切换激活都会发 `objectWillChange` ⇒ 都会走到这里。
    private func rebuild() {
        guard let model else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, tab) in model.tabs.enumerated() {
            stack.addView(makePill(tab: tab, index: index, isActive: index == model.activeTabIndex),
                          in: .leading)
        }
        // 标签数变了 ⇒ 需要的宽度也变了：重新报一次尺寸（NSToolbarItem 那一层不会自己知道）。
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: 颗粒（全用语义色 ⇒ 深浅色自动跟随）

    /// 一颗胶囊 = 标题按钮（点击切标签）+ ✕（关闭）。选中态上强调色淡底。
    /// ⚠️ `tag` 装**下标**、`rebuild()` 在任何变化后整条重建 ⇒ tag 永远是最新值，
    ///    不存在「删掉中间一个标签后 tag 错位」的问题。
    private func makePill(tab: WebTabModel, index: Int, isActive: Bool) -> NSView {
        let title = NSButton(title: tab.displayTitle, target: self, action: #selector(didSelectTab(_:)))
        title.tag = index
        title.isBordered = false
        title.font = .systemFont(ofSize: 11)
        title.contentTintColor = .secondaryLabelColor
        // 🔴 **本地面的标签挂一个前置小图标**，跟网页标签一眼分得开
        //    （2026-10-06 文件档起，2026-10-07 扩到目录 / 代码共三档）。
        //    标签条上这是唯一能区分两类内容的地方 —— 光看标题分不出来
        //    （一个叫「报告」的网页和一个叫「报告.pdf」的文件，文字形状差不多）。
        //    🔴 图标名收在 `WebTabKind.tabSymbolName`（`nil` = 网页，不挂图标）——
        //    ⛔ 别在这里写 `if case .file`：加一档就得多改一处（这正是当初踩的坑）。
        //    ☠️ 必须给 `SymbolConfiguration`：不给的话 SF Symbol 用**自己的**默认字号
        //    （13pt 上下），在 11pt 的标题旁边显得头重脚轻。
        if let symbol = tab.kind.tabSymbolName {
            title.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L("本地内容"))?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
            title.imagePosition = .imageLeading
        }
        // 宽度吃紧时先压标题（SwiftUI 版同款取舍：标签优先、地址栏在下面那一行兜底）。
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 🔴 单个标签的宽度上限（与 SwiftUI 版 `webPageTabItemMaxWidth` 同一口径）：
        //    不设的话长标题会把一条标签撑得很宽，标签一多就更早顶到总宽上限。
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(lessThanOrEqualToConstant: MacTheme.webPageTabItemMaxWidth)
            .isActive = true
        title.toolTip = tab.displayTitle

        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L("关闭标签页")) ?? NSImage(),
            target: self, action: #selector(didCloseTab(_:)))
        close.tag = index
        close.isBordered = false
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = L("关闭标签页")
        close.translatesAutoresizingMaskIntoConstraints = false
        close.widthAnchor.constraint(equalToConstant: 14).isActive = true
        close.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let pill = NSStackView(views: [title, close])
        pill.orientation = .horizontal
        pill.spacing = 2
        pill.alignment = .centerY
        pill.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 4)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 6
        pill.layer?.backgroundColor = isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : NSColor.clear.cgColor
        return pill
    }

    // MARK: 动作（直接落模型 —— 不经 SwiftUI）

    @objc private func didSelectTab(_ sender: NSButton) { model?.selectTab(sender.tag) }

    /// 🔴 关标签**必须**走 `onCloseTab`（2026-10-06）：关掉的若是**最后一个**标签，
    ///    整块右侧页面要跟着收起 —— 那件事只有接线层（`ChatModel.closePanelTab(_:)`）知道，
    ///    `WebPageModel` 看不见面板状态。
    /// ⚠️ 没接上时退回直落模型：`WebPageModel.closeTab(at:)` 一样会把标签删掉，
    ///    只是没人收面板 ⇒ 留下一块空面板。生产路径上 `RootView` 必传，走不到这个分支。
    @objc private func didCloseTab(_ sender: NSButton) {
        guard let onCloseTab else {
            model?.closeTab(at: sender.tag)
            return
        }
        onCloseTab(sender.tag)
    }

    @objc private func didNewTab(_ sender: NSButton) { model?.newTab() }
}

/// 加载失败时盖住内容区的那一块（参数全值，便于离屏渲染）。
struct WebPageErrorView: View {

    let failure: WebPageFailure
    let onRetry: () -> Void
    let onOpenInBrowser: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: MacTheme.webPageErrorSpacing) {
            Image(systemName: "exclamationmark.triangle")
                .font(MacTheme.ui(MacTheme.webPageErrorIconSize))
                .foregroundStyle(MacTheme.errorText)
            Text(failure.message)
                .font(MacTheme.ui(MacTheme.webPageErrorFontSize))
                .foregroundStyle(MacTheme.bodyColor)
                .multilineTextAlignment(.center)
            if let detail = failure.detail {
                Text(detail)
                    .font(MacTheme.ui(MacTheme.webPageErrorDetailFontSize))
                    .foregroundStyle(MacTheme.meta)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                errorButton(L("重试"), action: onRetry)
                errorButton(failure.isTransportSecurity ? L("用浏览器打开") : L("在浏览器中打开"),
                            action: onOpenInBrowser)
            }
        }
        .padding(MacTheme.webPageErrorPadding)
        .frame(maxWidth: MacTheme.webPageErrorMaxWidth)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(MacTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(MacTheme.cardBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func errorButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(MacTheme.ui(MacTheme.webPageErrorButtonFontSize))
                .foregroundStyle(MacTheme.bodyColor)
                .padding(.horizontal, MacTheme.webPageErrorButtonPaddingH)
                .padding(.vertical, MacTheme.webPageErrorButtonPaddingV)
                .background(
                    RoundedRectangle(cornerRadius: MacTheme.webPageErrorButtonRadius)
                        .fill(MacTheme.webPageErrorButtonBackground(scheme))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
