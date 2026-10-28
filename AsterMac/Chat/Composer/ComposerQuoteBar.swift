//
//  ComposerQuoteBar.swift
//  AsterMac
//
//  输入卡片**上方**那条「引用」条：显示你点了哪一条消息、以及可取消。
//  （2026-09-29 加。iOS 侧同一个角色是 `AIComposerBannerView` 的 `.quote(AIQuote)` 分支。）
//
//  ## 它回答的问题
//  「引用」在界面上必须**看得见**：点完之后如果输入区毫无变化，用户根本不知道
//  「我引用了什么 / 这条发出去会带上什么」。所以它是一条**常驻可见**的条，
//  直到发送成功、用户点 ×、或换会话为止（三种收尾都在 `ChatModel`）。
//
//  ## 与 iOS 的差别（都是 Mac 自己的口径，不是漏做）
//  - iOS 那条挂在输入栏上方、属于**输入栏自己的 banner 区**；Mac 的输入区是
//    「**一张卡片**」（见 `MacInputBar` 文件头），所以这条放在**卡片内部的顶部** ——
//    卡片外的东西会被「卡片 = 一个整体」的观感破坏。
//  - 不画角色标签（「你 / AI」）：气泡上的引用条已经有这个信息，这里只提示「引用了哪段」，
//    多一行标签只会把卡片顶高。
//
//  ## 外观
//  ⚠️ 配色用 `MacTheme.composerQuote*`（坐在卡片里，取语义色）——
//  ⛔ **别拿 `MacTheme.userQuote*`**：那一组是给「强调色气泡上的白字」用的
//    （见 `MacTheme` 里那两组的注释），互换会在浅色模式下变成黑字压蓝底。
//

import SwiftUI
import AICore

/// 输入卡片顶部的引用条。**自己不判断显不显示** —— 由 `MacInputBar` 按
/// `model.pendingQuote` 决定挂不挂，与附件条同一个形状。
struct ComposerQuoteBar: View {

    /// 被引用的那条消息的快照（正文 + 角色 + 原始消息 id）
    let quote: AIQuote
    /// 点 × → 请模型撤掉待发送的引用
    let onCancel: () -> Void

    /// 底块透明度分浅深两档，所以这里必须真的读到当前外观
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: MacTheme.quoteInnerSpacing) {
            // 图标名取自业务层（与操作栏那几颗同源）—— ⛔ 别在这里写死 SF Symbol 名
            Image(systemName: AIRowAction.quote.icon)
                .font(MacTheme.ui(MacTheme.quoteFontSize))
                .foregroundStyle(MacTheme.composerQuoteIcon)
                // 与首行文字的视觉中线对齐（`alignment: .top` 让图标贴顶，
                // 图标自身比文字矮，所以往下推一点点而不是贴着上边缘）
                .padding(.top, 1)

            // 正文最多两行：它只是「提醒你引用了什么」，不该把输入卡片顶高
            Text(quote.text)
                .font(MacTheme.ui(MacTheme.quoteFontSize))
                .foregroundStyle(MacTheme.composerQuoteText)
                .lineLimit(MacTheme.quoteLineLimit)
                .truncationMode(.tail)
                // 必须给 vertical 的 fixedSize：否则两行文本在 HStack 里会被压回一行高
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(MacTheme.ui(9, weight: .semibold))
                    .foregroundStyle(MacTheme.composerQuoteIcon)
                    // 命中区给足（图标本身只有几个像素）
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("取消引用"))
        }
        .padding(.horizontal, MacTheme.composerAttachmentPaddingH)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.quoteRadius)
                .fill(MacTheme.composerQuoteBackground(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacTheme.quoteRadius)
                .stroke(MacTheme.composerQuoteBorder, lineWidth: 1)
        )
    }
}
