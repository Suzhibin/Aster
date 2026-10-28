//
//  ComposerMentionBar.swift
//  AsterMac
//
//  输入卡片里那条「本轮 `@` 到的项目资料」（2026-10-21）。
//
//  ## 位置与次序
//  卡片内部自上而下：引用条 → 附件条 →（**本视图**）→ 文本区 → 控制行。
//  ⚠️ 放在附件条**之后**、文本区**之前**：附件是「我要发出去的东西」，@ 是「我参考的东西」——
//     后者更贴输入的那一句。iOS 侧同次序（`AIMentionBarView`），⛔ 别一端一个样。
//
//  ## 与「引用」条的区别（两个都在这张卡片里，别合成一条）
//  - **引用**（`ComposerQuoteBar`）= 针对某条历史消息，**一行文字**，最多两行；
//  - **@ 资料** = 项目里的**几份文件**，横向 chip、可多个、每个能单独删。
//  合成一条的话，「删哪一个」和「长什么样」都会打架。
//
//  ## 配色
//  与引用条同一族（`composerQuote*`）：两者都坐在卡片里、都是「这条消息的上下文」。
//  ⛔ 别用 `userQuote*`（那是强调色气泡上的白字组）。
//

import SwiftUI
import AICore

/// 输入卡片里的 `@` 资料 chip 条。**自己不判断显不显示** —— 由 `MacInputBar` 按
/// `model.pendingMentions` 决定挂不挂（与 `ComposerQuoteBar` 同一个形状）。
struct ComposerMentionBar: View {

    let items: [AIMention]
    /// 点某个 chip 的 ×（回调下标；数据在 `ChatModel`）
    let onRemove: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            MentionChipsRow(items: items, onRemove: onRemove)
        }
        // 高度固定：卡片高度是 SwiftUI 自己撑的，但它不该随名字长短跳
        .frame(height: 24)
    }
}

/// chip 那一行（**不含滚动容器**）。
///
/// 🔴 **为什么单独成一个类型**：`ImageRenderer` 照 `ScrollView` 里的内容会得到一张**空图**
/// （2026-10-21 实测：840×48 全白，chips 一个都没画出来；而同样的 `HStack` 单独照就正常）。
/// 渲染台要照的是「chip 长什么样」（这里才有真布局），滚动行为本身不值得照 ——
/// 所以把它拆出来给渲染台单独 dump（见 `macrender/main.swift` 的 `composer_mentions`）。
/// ⛔ 别为了「少一个类型」把它合回去：合回去之后这条视觉判据就**永远照不到**，
///    而空白图看起来像「功能没做」。
struct MentionChipsRow: View {

    let items: [AIMention]
    let onRemove: (Int) -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                chip(item, index: index)
            }
        }
    }

    private func chip(_ item: AIMention, index: Int) -> some View {
        HStack(spacing: 4) {
            Text("@")
                .font(MacTheme.ui(11, weight: .semibold))
                .foregroundStyle(MacTheme.composerQuoteIcon)
            Text(item.summary(limit: 22))
                .font(MacTheme.ui(11, weight: .medium))
                .foregroundStyle(MacTheme.composerQuoteText)
                // 长名字从中间省略：文件名最有辨识度的往往是**扩展名与开头**（同账号栏那条）
                .lineLimit(1)
                .truncationMode(.middle)
            Text(item.sizeText)
                .font(MacTheme.ui(10))
                .foregroundStyle(MacTheme.composerQuoteIcon)

            Button { onRemove(index) } label: {
                Image(systemName: "xmark")
                    .font(MacTheme.ui(8, weight: .semibold))
                    .foregroundStyle(MacTheme.composerQuoteIcon)
                    // 命中区给足（图标本身只有几个像素）
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("移除资料"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(MacTheme.composerQuoteBackground(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(MacTheme.composerQuoteBorder, lineWidth: 1)
        )
    }
}
