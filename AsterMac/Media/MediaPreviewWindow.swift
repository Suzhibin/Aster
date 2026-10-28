//
//  MediaPreviewWindow.swift
//  AsterMac
//
//  点会话里的**图片 / 视频封面** → **另开一个独立窗口**预览（2026-09-27）。
//
//  ## 为什么是窗口，不是盖在会话页上的浮层
//  第一版做的是「整页浮层」（`MediaPreviewOverlay` 直接 `.overlay` 在 `ChatDetailView` 上），
//  用户看过之后明确要求改成**新开一个窗口**。两点实际差别：
//  - 预览是**独立任务**：看着图的时候还想接着聊天 / 翻别的会话，浮层会把整个会话页锁住
//    （连输入栏都被盖住），而窗口不锁 —— 还能把两张图并排摆着对比。
//  - 窗口有系统级的身份：能最小化、能 ⌘` 切换、能被「窗口」菜单列出来、关闭方式与全 App 一致。
//
//  ✅ `MediaPreviewOverlay` 那一层**原样保留**，这里只做「把它装进窗口」这件事 ——
//    于是它的离屏验收图（`mediapreview_*`）继续有效，一行都不用重渲。
//
//  ## 🔴 2026-10-09 两处调整（用户要求：「增加旋转图片按钮，上边的 title 可以去掉」）
//  - **加了第四颗「旋转」**（顺时针 90°、四档循环）：缩小 / 放大 / **旋转** / 另存为。
//    旋转状态与缩放、另存为一样住在 `MediaPreviewModel`（两处 UI 共用），
//    且**只对图片有效**（视频那颗置灰，见 `canRotate`）。
//    🔴 顺带把 `MacTheme.mediaPreviewTitlebarWidth` 从 3 颗改成 4 颗 —— 不改则
//    附件宽度不够、最后一颗被截掉，而**离屏图照不出来**（离屏没有标题栏）。
//  - **标题栏不显示窗口标题**：`titleVisibility = .hidden`（⛔ 不是把 `window.title` 置空串，
//    那会让系统仍居中留出一块空位）。`window.title` 本身**仍然要设**——
//    「窗口」菜单 / ⌘` 切换 / 辅助功能读的是它。
//
//  ## 🔴 三处口径差异（都在 `MediaPreviewOverlay` 的参数里）
//  ① **内容区不画顶栏**（`showsToolbar: false`）：那四颗（缩小 / 放大 / 旋转 / 另存为）
//     2026-09-28 起装在**标题栏**上（见下一节）—— 两边都画就是同一批按钮出现两次。
//     ⚠️ 它不只是「画不画」：`contentArea` 也不再扣掉顶栏那条高度（否则内容会平白缩一条、
//        上面还多一条空带）。
//  ② **点内容空白处不关窗**（`closesOnBackdropTap: false`）：浮层时代那条手势是为了给
//     「一整页都被占住」留一个退出路；窗口里误关的代价变大了（关掉就得回列表重新找那张图，
//     而且可能是十几条消息以前的），所以关窗只留「红绿灯 / ⌘W / Esc」三条明确的路。
//     ⚠️ 那条手势**不是删掉**，是收进参数 —— 浮层那张验收图里它还在。
//  ③ **窗口尺寸按媒体天然尺寸给**（见 `preferredContentSize`）。
//
//  ## 🔴 标题栏那一组按钮（2026-09-28 加，用户要求「放在交通灯旁边」）
//  装法：`NSTitlebarAccessoryViewController` + `layoutAttribute = .left` + `NSHostingView`
//  （`installTitlebarToolbar(on:model:)`）。`.left` 的语义正是 AppKit 头文件里那句
//  「adjacent and to the right of the close/minimize/maximize buttons」—— 就是用户要的位置。
//  - ⛔ **别改成在内容区自绘、再把内容往上顶**：标题栏那片是**窗口**画的（红绿灯、拖窗口、
//    双击缩放都在那）；自绘的按钮要么被窗口画的盖住，要么把「拖标题栏移动窗口」吃掉。
//    `MacTheme.mediaPreviewTitlebarWidth`。⚠️ 这个坑**离屏图照不出来** —— 离屏里根本没有标题栏。
//    `MacTheme.mediaPreviewTitlebarWidth`。⚠️ 这个坑**离屏图照不出来** —— 离屏里根本没有标题栏。
//  - 🔴 按钮与内容区**共用一份 `MediaPreviewModel`**（缩放档位 / 另存为 / 结果提示）：
//    两处是两个独立的 `NSHostingView`，各持一份状态 = 「点标题栏的放大，图片不动」。
//  - ⚠️ 标题栏在离屏渲染里画不出来 ⇒ 这一组的**位置**只能靠 `render_mac_ui.sh preview` 的
//    真窗口截图验；离屏那张 `mediapreview_titlebar` 只能验「四颗并排长什么样」。
//
//  ## ☠️ 四个必须记住的坑
//  ① **`isReleasedWhenClosed` 默认是 `true`**。那种情况下 `close()` 会把这个窗口 `release`
//     掉一次，而**我们表里还持有一份引用** ⇒ 之后任何一次访问都是野指针（崩），
//     摘表那一步还会**二次释放**。第一句就把它设成 `false`。
//  ② 🔴🔴 **别在 `close()` 里 `contentView = nil`**（这一条是踩出来的，反直觉，见
//     `MediaPreviewWindow.close()` 里的完整取证）。直觉是「窗口 `close()` 只让它离屏、视图仍在
//     层级里 ⇒ SwiftUI 不跑 `onDisappear` ⇒ 播放器不会被停 ⇒ 手动拆掉内容」，推理没错，
//     但**实测拆内容会让同进程里其它还开着的预览窗口不再重绘**（窗口在屏上、`occlusionState`
//     说 visible、子视图数也没变，截图却只剩一个空框）。
//     ⇒ 改成 `MediaPreviewPlaybackHandle`：视图把「怎么停播放」交出来，关窗那一拍调一下。
//  ③ **`⌘W` 走的是 `performClose:` → `close()`**，所以 ②那套对快捷键同样生效；
//     而 **Esc 不走响应链**（见下）。
//  ④ **`tabbingMode = .disallowed`**：不然系统会把同类窗口合并成标签页，
//     而挂在窗口上的模态面板（比如说「另存为」）会弹在一个**用户根本没打开过的标签**上。
//  ⑤ ⚠️ 标题栏附件的宽度要显式给（上面那节）。
//
//  ## Esc 为什么用「本地事件监视器」而不是 `cancelOperation(_:)`
//  `cancelOperation` 是响应链上的一站，而这条链的**第一响应者可能是 `AVPlayerView`**
//  （点过视频之后就是它）—— 那一支自己也要用 Esc（退出全屏），吃掉就不再往上传，
//  症状是「点了视频之后 Esc 关不掉窗口」。监视器在**事件派发之前**就拿到它，与第一响应者无关。
//  ⚠️ 只吞「本中心的窗口恰好是 key window」那一种情形，别的 Esc **原样放行** ——
//     否则会把主窗口的 Esc（气泡就地编辑的「取消」）一起吃掉。
//
//  ## 尺寸口径：按媒体天然尺寸开窗，读不到就退回默认
//  本地图片能**便宜**地量到尺寸：`CGImageSourceCopyPropertiesAtIndex` 只解析文件头、
//  不解码像素。远程 URL **绝不**在这里同步下载去量 —— 那正是 `RowMediaImage` 当初要修的 bug
//  （见它的文件头：`NSImage(contentsOf:)` 写在 `body` 里 = 每次求值阻塞主线程）。
//
//  ## ⚠️ 一张图一个窗口，同一张再点则**聚焦已有窗口**
//  钥匙是 `MediaPreviewItem.id`（`"image|<url>"` / `"video|<url>"`）。
//  不这样做的话「连点两下」会开出两个一模一样的窗口。
//

import SwiftUI
import AppKit
import ImageIO

// MARK: - 窗口

/// 预览窗口。
///
/// 🔴 继承 `NSWindow` 只为了「关窗时把那两件收尾做掉」（拆内容 + 通知中心摘表），
///    **不是为了外观** —— 外观全在 `MediaPreviewOverlay` 里。
final class MediaPreviewWindow: NSWindow {

    /// 窗口关掉了（中心用它把这一条从表里摘掉）。
    var onClose: (() -> Void)?

    /// 收尾只做一次：`close()` 可能被走多条路进来（红绿灯 / ⌘W / Esc / 代码）。
    private var didTearDown = false

    /// 关窗那一拍要停的播放（见 `MediaPreviewPlaybackHandle`）。
    var playback: MediaPreviewPlaybackHandle?

    override func close() {
        if !didTearDown {
            didTearDown = true
            // 🔴 **只停播放，不拆 `contentView`** —— 这里踩过一个坑，务必读完再改。
            //
            // 直觉写法是「窗口 `close()` 只让它离屏、视图还在层级里 ⇒ SwiftUI 不跑 `onDisappear`
            // ⇒ 播放器不会被停 ⇒ 所以手动 `contentView = nil` 把内容拆下来」。
            // **推理没错，但代价极大**：实测在 `close()` 里 `contentView = nil` 会让
            // **同进程里其它还开着的预览窗口不再重绘** —— 窗口仍在屏上、`isVisible` 为真、
            // `occlusionState` 也说 visible、`contentView` 的子视图数一个没少，
            // 但 `screencapture -l` 拍出来只剩一个**空框**（内容一片空白）。
            //
            // 取证（`render_mac_ui.sh preview` 的控制组，2026-09-27）：
            //   状态②「两个窗口都开着、只多等一拍」           → 有内容
            //   状态③「关掉其中一个」+ 有 `contentView = nil` → **空框**
            //   同一状态 + 去掉 `contentView = nil`           → 有内容 ✅
            //   （换成 `super.close()` 之后再拆，同样空框 ⇒ 与**顺序无关**，是「拆」这个动作本身）
            //
            // ⇒ 拆内容这条路走不通，改成「单独通知播放器停」：播放器由视图交给
            //   `MediaPreviewPlaybackHandle`，窗口在关的那一拍 `stop()` 一下。
            //   ⚠️ 视图与播放器随后与窗口一起被释放，所以这条只是「更早、更确定」。
            playback?.stop?()
        }
        super.close()
        onClose?()
        onClose = nil
    }
}

// MARK: - 播放句柄

/// 关窗时用来把播放停掉的把手。
///
/// 存在的唯一理由见 `MediaPreviewWindow.close()` 里那段取证：**不能用拆 `contentView` 的办法**
/// （会让同进程其它预览窗口不再重绘）。于是改成「视图把『怎么停』交出来，窗口在关的那一拍调一下」。
///
/// ⚠️ 交货点写在 `MediaPreviewOverlay.startVideoIfNeeded()` 的 `onAppear` 里，
///    里面**只 capture `AVPlayer`、不碰任何 SwiftUI 状态** —— 这样从窗口的收尾里调它是安全的。
/// ⚠️ 浮层模式（`MediaPreviewOverlay` 直接盖在页面上）不需要它：那边 `onDisappear` 靠得住。
@MainActor
final class MediaPreviewPlaybackHandle {
    /// 视图登记进来的「暂停自己那个播放器」。
    var stop: (() -> Void)?
}

// MARK: - 窗口中心

/// 预览窗口的「一张图一个窗口」登记处 + 开窗逻辑。
///
/// 🔴 单例是**必须**的：不持有窗口引用的话，`NSWindow` 会在闭包返回后被释放（窗口一闪就没）。
///    本仓库没有别的窗口管理需求，所以不做成一整套 WindowController 体系。
@MainActor
final class MediaPreviewWindowCenter {

    static let shared = MediaPreviewWindowCenter()

    /// 钥匙 = `MediaPreviewItem.id`。
    private var windows: [String: MediaPreviewWindow] = [:]

    /// Esc 监视器（`NSEvent.addLocalMonitorForEvents` 的返回值必须留着，否则会被回收）。
    private var escapeMonitor: Any?

    private init() {
        installEscapeMonitor()
    }

    // MARK: 开窗

    /// 打开（或把已经开着的那一个提到前面）。
    func open(_ item: MediaPreviewItem) {
        if let existing = windows[item.id] {
            // 同一张媒体再点一次：**聚焦**已有窗口，不再开一个。
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = makeWindow(for: item)
        position(window, offsetIndex: windows.count)
        windows[item.id] = window
        window.onClose = { [weak self] in
            guard let self else { return }
            self.windows.removeValue(forKey: item.id)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow(for item: MediaPreviewItem) -> MediaPreviewWindow {
        let window = MediaPreviewWindow(
            contentRect: NSRect(origin: .zero, size: Self.preferredContentSize(for: item)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // 🔴 2026-10-09 用户要求「上边的 title 可以去掉」⇒ 标题栏**不显示窗口标题**。
        //
        // ⚠️ **必须用 `titleVisibility = .hidden`，⛔ 别把 `window.title` 置成空串**：
        // 置空串的话系统仍会在标题栏**居中留出标题的位置**（空但占位），
        // 观感是「标题栏中间有一块空的」—— 那不是「去掉」，是「换成一个空标题」。
        // `.hidden` 才是真的不画，也把那块位置让出来给附件。
        // 📌 `item.windowTitle`（文件名/主机名）**仍然留着**、仍被 `window.title` 用 ——
        //    因为「窗口」菜单、⌘` 切换、辅助功能都读它；那属于**窗口身份**，
        //    与「标题栏上写不写给人看」是两件事（同一个字符串，两个用途）。
        window.title = item.windowTitle
        window.titleVisibility = .hidden

        // ☠️ 默认 `true` ⇒ `close()` 会再 release 一次我们表里那份引用（野指针 / 二次释放）。
        window.isReleasedWhenClosed = false
        // ⛔ 别让系统把预览窗口合并成标签页：合并之后「另存为」弹出的面板会挂在一个
        //    用户根本没打开过的标签上，观感是「面板凭空出现」。
        window.tabbingMode = .disallowed

        window.contentMinSize = MacTheme.mediaPreviewWindowMinContentSize
        // 关窗时用来停播放的把手（⛔ 不是为了拆内容 —— 那件事已证明有害，见 `close()`）。
        let playback = MediaPreviewPlaybackHandle()
        window.playback = playback
        // 🔴 这一份状态**两处共用**：内容区（按档位缩放 / 旋转 + 左下角飘结果）与标题栏那四颗按钮。
        //    各持一份 = 点标题栏的放大，图片不动（见文件头那一节）。
        let model = MediaPreviewModel(item: item)
        window.contentView = NSHostingView(rootView: MediaPreviewOverlay(
            item: item,
            onClose: { [weak window] in window?.close() },
            model: model,
            showsToolbar: false,         // 四颗按钮在标题栏上（见文件头口径 ①）
            closesOnBackdropTap: false,  // 独立窗口里误点代价大（见文件头口径 ②）
            playback: playback
        ))
        installTitlebarToolbar(on: window, model: model)
        return window
    }

    /// 把「缩小 / 放大 / 旋转 / 另存为」装到窗口**标题栏**上（交通灯右边）。
    ///
    /// 🔴 为什么必须走这一套而**不是**在内容区自绘：标题栏那片是**窗口**画的 ——
    ///    红绿灯、拖动窗口、双击缩放都在那；自绘的按钮要么被盖住、要么把拖动吃掉。
    ///    `layoutAttribute = .left` 的语义正是 AppKit 头文件那句
    ///    「adjacent and to the right of the close/minimize/maximize buttons」。
    /// ☠️ 传进去的**宽度必须显式给**（`MacTheme.mediaPreviewTitlebarWidth`）：
    ///    左侧附件的**高度**会被窗口填满，**宽**才是我们说了算的那个方向 ——
    ///    不给宽度就是 0 宽，四颗按钮一个都看不见（而离屏图里根本看不出这件事，离屏没有标题栏）。
    /// ⚠️ 高度这里按窗口的标题栏实际高度给（`frame − contentLayoutRect`），
    ///    不是常量：全屏 / 带工具栏的窗口那条高度不一样。
    private func installTitlebarToolbar(on window: NSWindow, model: MediaPreviewModel) {
        let host = NSHostingView(rootView: MediaPreviewTitlebarToolbar(model: model))
        let titlebarHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
        host.frame = NSRect(x: 0, y: 0,
                            width: MacTheme.mediaPreviewTitlebarWidth,
                            height: titlebarHeight)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = host
        // ⛔ 别用 `.right`（那是窗口最右端）、也**别不设**（默认是 `.bottom`，会另起一条带子）。
        accessory.layoutAttribute = .left
        window.addTitlebarAccessoryViewController(accessory)
    }

    /// 居中；已经开着别的预览窗时**逐级错开** —— 否则第二张会严丝合缝盖住第一张
    /// （`center()` 每次都回到同一个点），用户看到的还是「那一张」。
    ///
    /// 🔴 顺带在这一处**统一夹进屏幕可见区**（大图窗口的天然尺寸可能超过一屏）：
    ///    别在 `preferredContentSize` 里也夹一遍 —— 两个地方各夹一半，改一个漏一个。
    private func position(_ window: MediaPreviewWindow, offsetIndex: Int) {
        window.center()
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 24, dy: 24)
        let step = CGFloat(offsetIndex) * 24

        var frame = window.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX + step, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY - step, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: false)
    }

    // MARK: Esc

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // ☠️ NSEvent **不能进** `assumeIsolated` 的闭包：Xcode 27 起那个闭包是
            //    `@Sendable`，而 `NSEvent` 没有 `Sendable` 一致性（警告：conformance
            //    of 'NSEvent' to 'Sendable' is unavailable）⇒ 在边界**外**把要用的值取出来，
            //    闭包里只回 Bool（要不要吞），`event` 本身留在最外层 return。
            let keyCode = event.keyCode
            let swallow = MainActor.assumeIsolated { () -> Bool in
                // 53 = Esc。只在本中心的窗口是 key window 时吞（理由见文件头）。
                guard keyCode == 53,
                      let window = NSApp.keyWindow as? MediaPreviewWindow
                else { return false }
                window.close()
                return true
            }
            return swallow ? nil : event
        }
    }

    // MARK: 尺寸

    /// 开窗用的内容尺寸（不含标题栏）。
    ///
    /// 口径：按媒体天然尺寸 + 四周留白 + 底部来源胶囊那条，再**等比**缩进上限盒子（等比是为了别把
    /// 竖图压成横的），最后抬到下限。
    /// ⚠️ **不加顶栏那一条高度**（2026-09-28 三颗按钮搬到标题栏之后，内容区已经没有顶栏）——
    ///    加了的话窗户平白高 `mediaPreviewBarHeight`（50pt），图上方多一条空带。
    /// ⚠️ 但要**补** `mediaPreviewChipStripHeight`：`contentArea` 扣了它 ⇒ 这里不补的话
    ///    形状正常的图会被判成「比窗口高」而缩一档。两处必须同源。
    private static func preferredContentSize(for item: MediaPreviewItem) -> NSSize {
        guard let natural = naturalSize(of: item) else {
            return MacTheme.mediaPreviewWindowDefaultContentSize
        }
        let padded = NSSize(width: natural.width + MacTheme.mediaPreviewPadding * 2,
                            height: natural.height + MacTheme.mediaPreviewPadding * 2
                                    + MacTheme.mediaPreviewChipStripHeight)
        let box = MacTheme.mediaPreviewWindowMaxContentSize
        let scale = min(1, min(box.width / padded.width, box.height / padded.height))
        let minSize = MacTheme.mediaPreviewWindowMinContentSize
        return NSSize(width: max(padded.width * scale, minSize.width),
                      height: max(padded.height * scale, minSize.height))
    }

    /// 媒体的天然**像素**尺寸；量不到就返回 `nil`（走默认尺寸）。
    ///
    /// ⚠️ 只对**本地文件**量：`CGImageSourceCopyPropertiesAtIndex` 只读文件头，
    ///    远程 URL 用它等于同步下载一次（那正是要避免的 bug）。
    /// ⚠️ 视频**不量**：尺寸在 track 里，要 `AVAsset` 异步读 —— 不值得为「开窗时尺寸更准」
    ///    铺一条异步链（打开后窗口本来就可以拉）。
    private static func naturalSize(of item: MediaPreviewItem) -> CGSize? {
        guard !item.isVideo, let url = item.posterURL, url.isFileURL else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                                                      [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              // ⚠️ 走 `NSNumber.doubleValue` 而不是 `as? CGFloat`：属性字典里的数是 CFNumber
              //    桥过来的，取 Double 这条路最稳（CGFloat 的桥接在部分 SDK 上会静默拿到 nil）。
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
