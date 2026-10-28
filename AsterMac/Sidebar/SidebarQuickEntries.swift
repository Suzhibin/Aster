//
//  SidebarQuickEntries.swift
//  AsterMac
//
//  左栏**最上面**那两条固定入口：「新对话」与「文档」（2026-09-22 起是这两格；
//  第二格 2026-10-10 由「AI创作」换成「文档」—— 用户要求去掉前者）。
//  侧栏从此分三段：**固定入口** / 可滚动的会话列表 / 底部设置栏（`SidebarSettingsBar`，2026-10-27 起只剩一颗齿轮）。
//  这两条**不随列表滚动** —— 「固定」正是这次改动的全部要点。
//
//  ## 为什么单独一个文件
//  同 `SidebarSettingsBar`：只有**独立成视图**，渲染台才验得了它。侧栏本体是 `List(.sidebar)`，
//  而 `List` 是 AppKit 桥接容器 —— 离屏渲染只会被整块画成「黄条 + ⊘」（见技能
//  `ios-swiftui-headless-render`）。摘出来之后 `render_mac_ui.sh` 里
//  `dump("sidebar_entries", ..., SidebarQuickEntries(...))` 就能真看到这两行长什么样。
//
//  ## 两条入口的分工（2026-09-22 与用户确认）
//
//  | 入口 | 行为 |
//  |---|---|
//  | 新对话 | 开启一段**新对话** —— 即原来的「新建对话（⌘N）」 |
//  | 文档 | 把主区域**整页换成**「文档」页（跨会话的文件列表），见 `DocumentsView` |
//
//  - **新对话**：所以侧栏工具栏那颗 `square.and.pencil` 已经撤掉，同一个入口不摆两处。
//    图标仍用 `square.and.pencil`，让从旧位置找过来的人认得出是同一件事。
//    ⚠️ ⌘N 不受影响 —— 它挂在 App 的「文件」菜单里（`AsterMacApp` 的 `CommandGroup`），
//       从来不是工具栏那颗按钮提供的。
//  - **文档**（2026-10-10 取代「AI创作」）：原来的「AI创作」是个**功能没接的占位**
//    （点了只飘一句「AI 创作还没接上」），用户明确要求去掉。新的这一格有真功能。
//    🔴 图标 `doc.text` 与 iOS 侧（`AIMenuViewController.quickItems`）**刻意同款**
//       —— 两端同一件事用同一个图标。
//    ⚠️ 它**不是**「打开一段对话」，所以别接 `model.newConversation` 那一家；
//       落点是 `ChatModel.showDocuments()`（主区域整页替换，用户 2026-10-10 拍板）。
//
//  ## hover 高亮为什么必须有
//  `.buttonStyle(.plain)` 在 macOS 上**不画任何指针反馈**，一行纯文字摆在侧栏里，
//  用户看不出它是不是能点。所以自己跟 `onHover` 画一层圆角底。
//  ⚠️ 它和 `.help` 一起构成「这条入口是活的」的全部信号 —— 别为了少几行删掉。
//  ⚠️ hover 是**指针态**，渲染台没有指针、验不了（脚本里靠改初值强行造出悬停态，
//     见 `render_mac_ui.sh` 的 `hovered` 那一段）。
//

import SwiftUI
// 🔴 入口文案走 `L()`（2026-10-13 接本地化）；`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`
//    在本工程是开的 ⇒ 用谁就显式 import 谁。
import AICore

struct SidebarQuickEntries: View {

    /// 「新对话」→ 开启一段新对话
    let onNewChat: () -> Void
    /// 「文档」→ 把主区域整页换成「文档」页（见 `DocumentsView`）
    let onDocuments: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    /// 当前悬停的那一条（`nil` = 指针不在固定区里）
    @State private var hovered: Entry?

    private enum Entry: Hashable { case newChat, documents }

    var body: some View {
        VStack(alignment: .leading, spacing: MacTheme.quickEntrySpacing) {
            row(.newChat,
                icon: "square.and.pencil",
                // 🔴 2026-10-25 用户要求：「两端的 菜单第一项 新对话 改成 新对话」
                //    （与 iOS 侧 `AIMenuViewController.quickItems` 同一拍改的，两端刻意同文）。
                //    ⚠️ 只改文案，不改行为 / 不改图标。
                title: L("新对话"),
                help: L("开启一段新的 AI 对话（⌘N）"),
                action: onNewChat)

            row(.documents,
                icon: "doc.text",
                title: L("文档"),
                help: L("查看全部对话里上传过的文件"),
                action: onDocuments)
        }
        .padding(.horizontal, MacTheme.quickEntryPaddingH)
        .padding(.vertical, MacTheme.quickEntryPaddingV)
    }

    // MARK: - 单条入口

    private func row(_ id: Entry,
                     icon: String,
                     title: String,
                     help: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: MacTheme.quickEntryInnerSpacing) {
                // 定宽，而不是让图标自己撑 —— 两条入口的图标才在一条竖线上
                Image(systemName: icon)
                    .font(.system(size: MacTheme.quickEntryIconSize))
                    .foregroundStyle(MacTheme.quickEntryIcon)
                    .frame(width: MacTheme.quickEntryIconWidth)
                Text(title)
                    .font(MacTheme.ui(MacTheme.quickEntryFontSize))
                    .foregroundStyle(MacTheme.bodyColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MacTheme.quickEntryRowPaddingH)
            .frame(height: MacTheme.quickEntryRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 命中区必须在 `background` **之前**撑满整行：否则只有图标和文字那几个像素可点
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: MacTheme.quickEntryRadius)
                    .fill(hovered == id
                          ? MacTheme.quickEntryHoverBackground(colorScheme)
                          : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = id
            } else if hovered == id {
                hovered = nil
            }
        }
        .help(help)
    }
}
