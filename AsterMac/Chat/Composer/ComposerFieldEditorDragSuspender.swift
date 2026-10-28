//
//  ComposerFieldEditorDragSuspender.swift
//  AsterMac
//
//  一个**只在拖拽期间生效**的开关：让输入框的字段编辑器别再接受拖拽。
//
//  ## 它解决的那个洞（2026-09-26 实测查出来的）
//  会话页把 `.onDrop(of: [.fileURL])` 挂在**整页**上，可输入框里那个 `TextField`
//  在**聚焦**时会向 AppKit 要一个字段编辑器（`_SystemTextFieldFieldEditor`），
//  而那个文本视图注册了 `NSFilenamesPboardType`（以及一串文本类型）。
//  AppKit 的落点规则是「指针下**最深**的已注册视图赢」——字段编辑器在页面里面，
//  比页面深 ⇒ **把文件拖到输入框上松手，会被它会吃掉**：草稿里多出一行路径，附件一个不加。
//  而「拖到输入框上」恰恰是最自然的那一下（那一层落区上写的就是「松开即可添加到输入框」）。
//
//  ### 实测取证（前三个探针，结论都很硬）
//  | 问 | 答 |
//  |---|---|
//  | 未聚焦时字段编辑器在不在？ | **不在** —— `AppKitTextField` 自己 `draggedTypes=[]` ⇒ 拖拽会正常往上层找 |
//  | 聚焦后呢？ | `_SystemTextFieldFieldEditor` 注册了 `NSFilenamesPboardType` |
//  | 「注册了」＝「会收」吗？ | **会** —— `preferredPasteboardType` 返回 `NSStringPboardType` |
//  | 为什么文本视图会收文件？ | Apple 文档《Text Editing》：文本视图注册拖拽类型与 `isRichText`/`importsGraphics` 有关 |
//
//  ## 修法：**挂起 → 拖完恢复**，而不是永久关掉
//  Apple 文档与社区共识都指向同一件事：让那个文本视图**别注册**（`unregisterDraggedTypes()`），
//  拖拽就会继续往上层找、落到页面级的 `.onDrop` 上。
//  ⚠️ 但「永久关掉」会**静默地**砍掉一个既有能力：往输入框里拖一段文字（从别的 App 拖文案过来）。
//  ⇒ 所以做成开关，**只在拖拽进行中挂起**，松手/拖出窗口就恢复：
//    非拖拽状态下输入框的行为**一点没改**，被牺牲的只有「拖拽期间往输入框里拖文字」这一种情况 ——
//    而那一刻用户的意图已经被整页落区覆盖了（他要放的是文件）。
//
//  ## 恢复为什么要**先存原样**
//  字段编辑器的类型表是它自己按 `acceptableDragTypes` 算出来的（不同系统版本会变）。
//  所以我们**不猜**那张表 —— 挂起前把 `registeredDraggedTypes` 原样抄下来，恢复时照着装回去。
//  ⛔ 别写成「恢复时手写一份类型清单」：那份清单迟早与系统对不上，而症状是
//     「输入框突然拖不进字了」这种极难往这里联想的故障。
//
//  ## ⚠️ 挂起不覆盖的那一格（已知残留，接受）
//  若用户**从窗口外直接拖进输入框那条窄带**、全程没经过消息区，那么这个开关**没有机会被打开**
//  （我们靠页面级 `.onDrop` 的 `isTargeted` 才知道「正在拖」）。
//  实际情况里做不到：输入框只有窗口底部约 120pt 高，正常拖拽必然先经过消息区。
//
//  ## ⚠️ 为什么不做成「永久关闭」
//  除了上面那条能力损失，还有一个理由：`unregisterDraggedTypes()` 只在**当前这个**
//  字段编辑器实例上生效，而字段编辑器会随焦点反复创建。做成「拖拽期间」之后，
//  每次拖拽我们都会重新找一个当前存在的实例，不依赖它活多久。
//

import SwiftUI
import AppKit

enum ComposerFieldEditorDragSuspender {

    /// 输入框所在的那个窗口（由下面那个 `NSViewRepresentable` 在挂上/移动时登记）。
    ///
    /// ⚠️ 用 `weak` 且**由视图来喂**，而不是去猜 `NSApp.mainWindow`：
    ///    设置页是**另一个窗口**，猜错的后果是「把设置页的输入框也一起挂起了」——
    ///    而那个窗口里根本没有拖拽落区，症状是设置页的输入框莫名其妙拖不进字。
    private static weak var composerWindow: NSWindow?

    /// 挂起前抄下来的类型表（**唯一**一份，恢复时照抄回去）。
    private static var savedTypes: [NSPasteboard.PasteboardType] = []
    /// 现在是挂起状态吗。用它保证 `suspend`/`resume` 幂等 ——
    /// 拖拽会反复进出落区（`isTargeted` 一开一关好几次），没有这个标志就会
    /// 「第二次挂起」把空表当成原样存下来，恢复时**清空**输入框的拖拽能力。
    private static var suspended = false

    // MARK: - 开关

    /// 挂起：让输入框的字段编辑器不再接受任何拖拽。
    static func suspend() {
        guard !suspended else { return }
        let editors = textViews()
        guard !editors.isEmpty else { return }          // 没聚焦 ⇒ 本来就没有字段编辑器，无需动手
        // 原样抄一份（所有字段编辑器共享同一张表，取第一个即可）
        savedTypes = editors[0].registeredDraggedTypes
        for editor in editors { editor.unregisterDraggedTypes() }
        suspended = true
    }

    /// 恢复：把原样的类型表装回去。
    ///
    /// ⚠️ 每次拖拽都**重新找一遍**字段编辑器：它有可能是拖拽期间新建的
    ///    （用户拖到一半点了输入框，焦点一变字段编辑器就换了一个实例）。
    ///    对旧实例恢复没有意义，对不存在的实例动手也没事 —— 所以这里不缓存实例、只认当前这一批。
    static func resume() {
        guard suspended else { return }
        for editor in textViews() where !savedTypes.isEmpty {
            editor.registerForDraggedTypes(savedTypes)
        }
        suspended = false
        savedTypes = []
    }

    /// ⛔ **只在「窗口已经没了」这条路上用**（见 `attach(_:)`）——
    ///    它是「忘掉自己在挂起」，**不是**「撤销挂起」：调它不会把类型表装回去。
    ///    有活的字段编辑器时一律用 `resume()`；用错会让输入框**永久**拖不进任何东西，
    ///    而症状离触发它的那次拖拽隔了很久，根本联想不到这里。
    static func reset() {
        suspended = false
        savedTypes = []
    }

    // MARK: - 找到「输入框的那个字段编辑器」

    /// 当前窗口里所有 `NSTextView`（= 字段编辑器）。
    ///
    /// - Note: 走**视图树**而不是 `window.fieldEditor(_:for:)`：后者要传「是哪个控件的编辑器」，
    ///   而那个控件是 SwiftUI 自己造的私有子类，App 侧拿不到句柄（实测传 `nil` 直接返回 `nil`）。
    ///   树里现成的 `NSTextView` 只有字段编辑器这一类，够用。
    private static func textViews() -> [NSTextView] {
        guard let root = composerWindow?.contentView else { return [] }
        var found: [NSTextView] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            if let text = view as? NSTextView { found.append(text) }
        }
        return found
    }
}

/// 只干一件事：把「输入框所在的窗口」交给上面那个开关。
///
/// - Note: 挂在 `MacInputBar` 的卡片 `.background` 上（贴在任何位置都行，它不画东西、不占位）。
///   用 `viewDidMoveToWindow` 而不是 `makeNSView`：视图造出来那一刻 `window` 还是 `nil`，
///   而 `viewDidMoveToWindow` 才是「真的进窗口了」和「换窗口了」都会走的那一拍。
struct ComposerWindowHint: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Sink() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Sink: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            ComposerFieldEditorDragSuspender.attach(window)
        }
    }
}

extension ComposerFieldEditorDragSuspender {
    /// 由 `Sink` 调用（写在这里是为了让「谁喂窗口」这件事在同一个文件里看得见）。
    fileprivate static func attach(_ window: NSWindow?) {
        // 窗口从有到无（视图拆掉）⇒ 状态复位，别把挂起态带出去
        if window == nil { reset() }
        composerWindow = window
    }
}
