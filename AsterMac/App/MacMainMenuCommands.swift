//
//  MacMainMenuCommands.swift
//  AsterMac
//
//  App 菜单里**我们自己加的那两条**命令（其余菜单项都由 AppKit / SwiftUI 提供）。
//
//  ## 为什么单独一个文件（而不是直接写在 `AsterMacApp.body` 里）
//  🔴 验收台 `render_mac_ui.sh` 会把 `AsterMac/` 的源码**递归**编进来，但**排除**
//     `App/AsterMacApp.swift`（它带 `@main`，与渲染台的 `main.swift` 顶层代码冲突）。
//     而 `root` 档的真窗口探针要判「**菜单栏跟没跟上语言**」—— 它读的是 `NSApp.mainMenu`，
//     只有让探针那个 App 也挂上**同一份** `.commands`，探针看到的菜单才与产品里那张一致。
//     ⇒ 抽到这个文件里，两个 App（产品的 / 探针的）共用一份。
//
//  ## ⚠️ 这两条标题**切语言时不会自己刷新**
//  `.commands` 的正文是场景建好那一拍求值的；App 的 `body` 之后不会因为语言变化重算
//  ⇒ 这两条在切换后由 `MacMainMenuLocalizer` **按标题双向翻**（它那张 `exactTable` /
//  反向表里就收着这两条）。⛔ 改这里的标题必须**同时**改那张表，否则切换后不翻。
//

import SwiftUI
import AICore

/// App 级菜单命令（挂在 `WindowGroup` 的 `.commands` 上）。
struct MacMainMenuCommands: Commands {
    /// 唯一数据源（App 级 `@State` 的那个 `ChatModel`）。
    let model: ChatModel

    var body: some Commands {
        // 「新建对话」挂在「文件」菜单下，快捷键沿用 Mac 惯例 Cmd+N
        CommandGroup(replacing: .newItem) {
            Button(L("新建对话")) { model.newConversation() }
                .keyboardShortcut("n", modifiers: .command)
        }
        // 🔴 「搜索对话」必须挂在**菜单**上，不能只写在侧栏那颗按钮的 `.keyboardShortcut` 里。
        //
        // 侧栏一收起，那颗按钮就从视图层级里消失，挂在它身上的快捷键**跟着失效** ——
        // 而「侧栏收起、窗口里全是聊天内容」恰恰是最想按 ⌘F 找东西的时候。
        // 菜单命令不随侧栏开合，这是 ⌘F 唯一可靠的家。
        //
        // 位置选「编辑」菜单里、剪切/拷贝/粘贴之后：⌘F 在 macOS 上的默认归属就是
        // 「编辑 → 查找」，不用另立门户（`.pasteboard` 正是剪切/拷贝/粘贴那一组）。
        // ⚠️ 分隔线把「编辑动作」与「查找」分开 —— 不加的话它像第四项剪贴板操作。
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(L("搜索对话…")) { model.isSearchPresented = true }
                .keyboardShortcut("f", modifiers: .command)
        }
    }
}
