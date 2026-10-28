//
//  MacMainMenuLocalizer.swift
//  AsterMac
//
//  把**系统菜单栏**（App / 文件 / 编辑 / 显示 / 窗口 / 帮助）翻成当前语言。
//
//  ## 🔴 为什么需要它（2026-10-13，用户原话）
//  「Mac 应用的 **菜单栏** 上 **一直是英文**，需要也跟随切换」。
//
//  ## 成因：那几张菜单的标题**不是我们的代码出的**
//  工程里**一份本地化声明都没有**（没有 `.lproj`、没有 `CFBundleLocalizations`）
//  ⇒ AppKit 给标准菜单取标题时按「开发区」（= `en`）走 ⇒ `File / Edit / View / Window / Help`
//  以及 `Undo / Cut / Copy / Minimize / Services / Quit …` **永远英文**，
//  与 `AILanguageStore` 里选了什么**毫无关系**。
//  ⚠️ 我们自己的两条（`新建对话` ⌘N / `搜索对话…` ⌘F）是 `L()` 出的，本来就跟语言走 ——
//     所以「菜单栏一直英文」说的完全是**系统那几张**。
//
//  ## 为什么走「改标题」而不是「自己重建菜单」
//  ① `CommandGroup(replacing:)` 能换掉**组内条目**，却**换不掉顶层菜单的标题**
//     （`File` 那两个字没有对应的 SwiftUI API）⇒ 无论如何都得回来改 `NSApp.mainMenu`；
//  ② 一旦替换 `.textEditing` 那一组，就会**丢掉**「自动填充 / 开始听写 / 表情与符号」
//     —— 那些没法自己重写（系统私有行为）⇒ 换组是**功能倒退**。
//  ⇒ 只**改标题**：selector / 快捷键 / Services / 窗口列表 / 听写 / 表情全都原样保留。
//
//  ## ⚠️ 四条边界（改这张表之前先读）
//  ① **必须双向**（2026-10-13 真窗口实测追加）：最初只做了 `en → zh`，理由是「AppKit 给系统的
//     菜单项出的永远是英文，所以切回 `en` 时不需要动它们」。**那是错的** —— 一旦我们把标题
//     改成了中文，原标题就**没了**，`en` 档下它们会**一直停在中文**。
//     真窗口实测（`STARRY_ROOT_I18N=1`，切到 `en` 那一拍）：
//     ```
//     I18NMENU 切后 顶层=["macrender_bin", "文件", "编辑", "显示", "窗口", "帮助"]   ← ☠️ 期望 File/Edit/…
//     I18NMENU 切后 「文件」=["New Chat", "", "关闭", "全部关闭"]                  ← 我们自己那条翻了，系统那些没翻
//     ```
//     ⇒ 现在按 `exactTable` **生成一张反向表**（中文 → 英文），两个方向都翻。
//     ⚠️ 生成的前提是**值不重复**（`zh` 各不相同）；往表里加条目时别让两条英文撞同一个中文。
//  ② **窗口列表不翻**：`窗口` 菜单**最后那一项**的子菜单里是**窗口标题**（用户的会话名），
//     那不是 UI 文案。若放任递归，一个恰好叫 `Copy` 的会话会被改名 —— 所以显式跳过它。
//  ③ **必须可重入**：两个方向都是「翻过的标题不在该方向的表里」⇒ 再跑一次不动它（幂等）。
//     这条很要紧 —— 下面 `scheduleApply()` 会连跑三拍。
//  ④ **只改标题，⛔ 绝不整棵替换菜单**（`NSApp.mainMenu = …`）：手搓的菜单会丢掉系统那三条
//     **改不出来**的私有项（AutoFill / Start Dictation… / Emoji & Symbols）。契约段有守卫钉这条。
//
//  ## 什么时候调
//  `RootView` 在两个时刻调 `scheduleApply()`：启动（`onAppear`）、收到 `AILanguageStore.didChange`。
//  ⚠️ **跑三拍（0 / 0.2 / 0.7 秒）不是凑数**：切语言的同一拍里 SwiftUI 会重建整张 `NSMenu`
//     （App 的 `.commands` 重算）⇒ 谁先谁后不确定，只跑一次会**随机**被重建盖掉。
//     三拍都是幂等的，多跑不花钱。
//

import AppKit
import AICore

/// 系统菜单栏的标题本地化（见文件头）。
enum MacMainMenuLocalizer {

    /// 把这些英文标题翻成中文。**精确匹配优先**，再走下面的前后缀规则。
    ///
    /// ⚠️ 表里同时收了**我们自己那两条**（`New Chat` / `Search Conversations…`）：
    ///    App 的 `.commands` 若没跟着语言重建，它们会停在英文 —— 一并收进来即可自愈。
    ///    （它们**不需要**单独一份双向表：反向表是从这张表生成的，天然覆盖。）
    private static let exactTable: [String: String] = [
        // ── 顶层菜单 ──
        "File": "文件",
        "Edit": "编辑",
        "View": "显示",
        "Window": "窗口",
        "Help": "帮助",

        // ── App 菜单 ──
        "Services": "服务",
        "Settings…": "设置…",
        "Hide Others": "隐藏其他",       // ⚠️ 必须排在 `Hide ` 前缀规则**之前**（精确匹配先跑）
        "Show All": "全部显示",

        // ── 文件 ──
        "New Window": "新建窗口",
        "New Chat": "新建对话",          // 我们自己的（⌘N）
        "Open…": "打开…",
        "Open Recent": "最近使用",
        "Close": "关闭",
        "Close All": "全部关闭",
        "Save": "存储",
        "Save As…": "存储为…",
        "Revert to Saved": "复原到已存储",
        "Page Setup…": "页面设置…",
        "Print…": "打印…",

        // ── 编辑 ──
        "Undo": "撤销",
        "Redo": "重做",
        "Cut": "剪切",
        "Copy": "拷贝",
        "Paste": "粘贴",
        "Paste and Match Style": "粘贴并匹配样式",
        "Delete": "删除",
        "Select All": "全选",
        "Find": "查找",
        "Find…": "查找…",
        "Find Next": "查找下一个",
        "Find Previous": "查找上一个",
        "Spelling and Grammar": "拼写和语法",
        "Substitutions": "替换",
        "Transformations": "变换",
        "Speech": "语音",
        "AutoFill": "自动填充",
        "Start Dictation…": "开始听写…",
        "Emoji & Symbols": "表情与符号",
        "Search Conversations…": "搜索对话…",   // 我们自己的（⌘F）

        // ── 显示 ──
        "Enter Full Screen": "进入全屏幕",
        "Exit Full Screen": "退出全屏幕",
        "Toggle Sidebar": "显示/隐藏侧栏",
        "Show Toolbar": "显示工具栏",
        "Hide Toolbar": "隐藏工具栏",
        "Customize Toolbar…": "自定工具栏…",

        // ── 窗口 ──
        "Minimize": "最小化",
        "Zoom": "缩放",
        "Bring All to Front": "全部置于顶层",
        "Move & Resize": "移动与调整大小",
        "Fill": "填充",
        "Center": "居中",
    ]

    /// `exactTable` 的**反向**（中文 → 英文）。
    ///
    /// ## 🔴 为什么必须有它（2026-10-13 真窗口实测追加）
    /// 原来只做单向（英文 → 中文），理由写的是「系统的菜单项本来就是英文，切回 `en` 不用动」。
    /// **那个理由不成立**：标题是**就地改掉的**，改完原标题就没了 ⇒ 切回 `en` 时那些
    /// `文件 / 编辑 / 显示 / 窗口 / 帮助` 会**一直停在中文**。实测（`I18NMENU 切后` 那几行）：
    /// 我们那两条（`New Chat`）翻回去了，系统那些没翻 —— 因为当时只有它们有反向表。
    ///
    /// ⚠️ 生成前提：`exactTable` 的**值两两不同**（`Dictionary(uniqueKeysWithValues:)` 遇重复会**崩**）。
    ///    往表里加条目时注意别让两条英文共用一个中文。
    private static let reverseTable: [String: String] =
        Dictionary(uniqueKeysWithValues: exactTable.map { ($0.value, $0.key) })

    /// 把 `NSApp.mainMenu` 按**当下生效的语言**翻一遍。
    ///
    /// 幂等：翻过的标题不在**该方向**的表里，再跑一次不会动它。
    @MainActor
    static func apply() {
        guard let main = NSApp.mainMenu else { return }
        // 「窗口」菜单最后那一项挂着**窗口列表**（里面是用户自己的会话名）⇒ 不进去。
        // ⚠️ 两个语言都要认：翻过一遍之后顶层标题已经是中文了，再跑一次得找得到它。
        let windowMenu = main.items.first { $0.title == "Window" || $0.title == "窗口" }
        let windowList: NSMenu? = windowMenu?.submenu?.items.last?.submenu
        for item in main.items {
            localize(item: item, skipSubmenu: windowList)
        }
    }

    /// 连跑三拍（成因见文件头「什么时候调」）。
    @MainActor
    static func scheduleApply() {
        apply()
        for delay: UInt64 in [200_000_000, 700_000_000] {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: delay)
                apply()
            }
        }
    }

    // MARK: - 递归

    @MainActor
    private static func localize(item: NSMenuItem, skipSubmenu: NSMenu?) {
        item.title = localized(item.title)
        // 🔴 字号跟随「字体大小」档位（2026-10-15 用户原话：「要把本地的文本
        //    比如菜单、设置内的文字大小同时改变」）。`NSMenuItem` **没有 font 属性**
        //    ⇒ 唯一的口子是 `attributedTitle`（AppKit 会按它渲染，含字号）。
        // ⚠️ 顺序承重：**必须先设 `title` 再设 `attributedTitle`** —— `title` 的 setter
        //    会把 `attributedTitle` 清成 nil（两份互斥），反了字号就丢。
        // ⚠️ 幂等不受影响：设了 `attributedTitle` 之后 `item.title` 读回的仍是
        //    `attributedString.string`（= 标题本身）⇒ `localized()` 的匹配照旧生效。
        // ⚠️ `keyEquivalent` 不吃这套样式：快捷键是 AppKit 单独画的，不受影响。
        let base = NSFont.menuFont(ofSize: 0).pointSize   // 系统菜单字号（≈13）
        item.attributedTitle = NSAttributedString(
            string: item.title,
            attributes: [.font: NSFont.menuFont(ofSize: base * AIFontSizeStore.uiScale)])
        if let sub = item.submenu, sub !== skipSubmenu {
            // 顶层菜单项自己的 `title` 与 `submenu.title` 是两份，都改（AppKit 显示的是 item 那份）
            sub.title = item.title
            for child in sub.items {
                localize(item: child, skipSubmenu: skipSubmenu)
            }
        }
    }

    /// 一个标题 → 当下的目标语言（认得就翻，不认得原样返回）。
    ///
    /// 🔴 **两个方向都要走**（成因见文件头 ①）：`en` 档不是「什么都不做」，而是把这几个
    /// 标题**改回英文** —— 否则一旦翻成过中文，就再也回不去了。
    @MainActor
    private static func localized(_ title: String) -> String {
        guard AILanguageStore.resolved == .zhHans else {
            // ── en 档：中文 → 英文（把我们上一轮写上去的那些改回来）──
            if let hit = reverseTable[title] { return hit }
            for (zh, en) in [("关于 ", "About "), ("隐藏 ", "Hide "), ("退出 ", "Quit ")] {
                if title.hasPrefix(zh) {
                    return en + title.dropFirst(zh.count)
                }
            }
            if title.hasSuffix(" 帮助") {
                return String(title.dropLast(" 帮助".count)) + " Help"
            }
            return title
        }
        // ── zh-Hans 档：英文 → 中文 ──
        if let hit = exactTable[title] { return hit }
        // 带 App 名的三种（App 名本身不翻，与「关于 / 隐藏 / 退出」一个道理）
        for (prefix, zh) in [("About ", "关于 "), ("Hide ", "隐藏 "), ("Quit ", "退出 ")] {
            if title.hasPrefix(prefix) {
                return zh + title.dropFirst(prefix.count)
            }
        }
        // `<App> Help`
        if title.hasSuffix(" Help") {
            return String(title.dropLast(" Help".count)) + " 帮助"
        }
        return title
    }
}
