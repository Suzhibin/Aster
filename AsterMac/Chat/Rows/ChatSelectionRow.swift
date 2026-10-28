//
//  ChatSelectionRow.swift
//  AsterMac
//
//  「多选删除」选择模式下，**每一行**外面套的那一层：左侧勾选圈 + 整行可点。
//  （2026-09-29 加，与 iOS 的表格编辑态同构 —— 那边是 `UITableView` 原生画圈，
//    Mac 没有表格，只能自己画。）
//
//  ## 结构
//  ```
//  ◉  这行消息的内容（气泡 / 缩略图条 / 占位…）
//  ```
//
//  ## 为什么圈要参与布局（而不是 `.overlay` 浮在内容上）
//  助手侧的内容从**最左边**开始 —— 浮一层圈上去就直接压在正文上了。
//  所以它必须是 `HStack` 的一个兄弟节点，让内容整体右移一格
//  （iOS 那边同款：系统编辑态会把 `contentView` 左侧内缩 4x pt）。
//
//  ## 为什么行内一切都要关掉命中
//  选择模式下「点一下 = 勾选」。而每个 cell 里都住着一堆会抢这一拍的东西：
//  图片/视频的点击预览、助手侧常驻的操作栏按钮、悬停才出的用户侧操作栏、
//  右键菜单、引用条…⇒ 用 `.allowsHitTesting(false)` 把**整块内容**一次性关掉，
//  由外面这一层接管点击。漏掉任何一处，症状都是「点这一行勾不上」——
//  而且只在那一种行上出现，极难联想到是别处的按钮吃掉了。
//  ⚠️ 它同时也会关掉 `onHover`：用户侧操作栏是 hover 才亮的，那正是我们要的效果。
//     两份「选择模式下不显操作栏」的逻辑（`ChatRowView` 里不画 + 这里不响应悬停）
//     缺一不可：少了前者，助手侧那条**常驻**栏会一直挂在屏幕上（点不到、但看着乱）。
//
//  ## 它不管显隐
//  挂不挂这一层由 `ChatDetailView` 决定（`selectionRow(rowIds:content:)`）——
//  本视图只管「长什么样」。
//

import SwiftUI

struct ChatSelectionRow<Content: View>: View {

    /// 这一行（或**这一组**）是否已经被勾上。
    ///
    /// ⚠️ 媒体横滑条是按**组**勾的：调用方传 `rowIds.allSatisfy { … }` ——
    ///    组内只要有一条没勾上，这一条在界面上就显示成未选（点一下补齐整组）。
    let isSelected: Bool

    /// 点这一行：勾上 / 取消。调用方给的是 `ChatModel.toggleSelection(rowIds:)`。
    let onToggle: () -> Void

    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: MacTheme.selectionCircleGap) {
            Image(systemName: isSelected ? Self.selectedSymbol : Self.idleSymbol)
                .font(MacTheme.ui(MacTheme.selectionCircleSize))
                .foregroundStyle(isSelected ? MacTheme.selectionCircleOn : MacTheme.selectionCircleOff)
                // 圈是 SF Symbol，字形宽度随符号变（`checkmark.circle.fill` 比 `circle` 宽一点点）
                // ⇒ **必须给固定框**，否则勾选前后整行会横向抖一下。
                .frame(width: MacTheme.selectionCircleSize, height: MacTheme.selectionCircleSize)

            content()
                // 见文件头「为什么行内一切都要关掉命中」。
                // ⛔ 别删：删了之后图片行 / 带操作栏的行会「点不动」（那一拍被它们接走）。
                .allowsHitTesting(false)
        }
        // 命中区 = **整行**：圈本身只有十来像素，而用户会习惯性地直接点消息（同 iOS）。
        // ⚠️ 顺序：先 `frame` 撑满、再 `contentShape`，否则命中区只有内容的固有宽度。
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    /// 选中：实心对号圈（走强调色 —— 与 App 里其它「选中」语义一致）
    /// ⚠️ 写成 `static var`（计算属性）而不是 `static let`：**泛型类型里不允许静态存储属性**
    ///    （`static stored properties not supported in generic types`，编译器当场报）。
    private static var selectedSymbol: String { "checkmark.circle.fill" }
    /// 未选中：空心圈
    private static var idleSymbol: String { "circle" }
}
