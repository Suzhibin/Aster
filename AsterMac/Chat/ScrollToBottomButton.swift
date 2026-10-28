//
//  ScrollToBottomButton.swift
//  AsterMac
//
//  覆盖在消息列表右下角、压在输入栏正上方的圆形「回到底部」按钮：
//  **上滑翻历史时淡入，回到最底部时淡出**（豆包 / DeepSeek / 微信同款交互）。
//
//  ## 与 iOS 版的实现差异（同观感，不同做法 —— 别拿 iOS 的做法往这里套）
//
//  | | iOS（`AIModuleViewController`） | Mac（本文件 + `ChatDetailView`） |
//  |---|---|---|
//  | 位置 | 手写 `frame`，跟随输入栏；要挂**两个**布局入口（键盘通知 + `viewDidLayoutSubviews`） | 交给布局系统：`.overlay(alignment: .bottomTrailing)` 挂在输入栏之上，一行 padding |
//  | 显隐 | `alpha` + `isUserInteractionEnabled`，靠 `scrollViewDidScroll` 逐帧推 | 一个贴底布尔量 → `.opacity` + `.allowsHitTesting` |
//  | 隐藏时的触摸 | 必须**立刻**交还（`isHidden` 做不到） | `.allowsHitTesting(false)` —— 与淡出动画同时生效，不需要额外处理 |
//
//  ⚠️ iOS 那边有一条「`addSubview` 必须在输入栏之后，否则 `point(inside:)` 会把触摸全吃掉」
//  的坑 —— 那是 UIKit 的 `hitTest` 倒序遍历。SwiftUI 的 `overlay` **永远在底层视图之上**，
//  不存在顺序问题。看到 iOS 技能里那段别慌，这里不适用。
//
//  ## ⚠️ 本视图只负责「长什么样」
//  **显不显示**、**点了做什么**全由调用方（`ChatDetailView`）给。这个分工是刻意的：
//  「是否贴着底部」的判据全页只能有一处（自动跟随与它共用），做进按钮里就必然出现
//  「自动跟随认为到底了、按钮却还挂着」的自相矛盾状态（iOS 侧踩过，见技能第 2 条）。
//

import SwiftUI
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

/// 圆形「回到底部」按钮。无状态 —— 显隐与动作都由调用方决定。
struct ScrollToBottomButton: View {
    /// 点击动作（调用方负责真正滚到底）
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(MacTheme.ui(MacTheme.scrollToBottomIconSize, weight: .semibold))
                .foregroundStyle(MacTheme.scrollToBottomIcon)
                .frame(width: MacTheme.scrollToBottomSide, height: MacTheme.scrollToBottomSide)
                // 顺序有讲究：先铺底，再描边，最后投影 ——
                // 投影放在最后才是给「整颗圆（含描边）」加，放前面就只给底色加。
                .background(Circle().fill(MacTheme.scrollToBottomBackground))
                .overlay(Circle().strokeBorder(MacTheme.scrollToBottomBorder, lineWidth: 1))
                .shadow(color: MacTheme.scrollToBottomShadow, radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .help(L("回到底部"))
        .accessibilityLabel(L("回到底部"))
    }
}
