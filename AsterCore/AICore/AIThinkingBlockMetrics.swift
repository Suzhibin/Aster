//
//  AIThinkingBlockMetrics.swift
//  AsterCore
//
//  「思考过程」子块的尺寸常量 / 文本属性 / 高度量算 —— **量高与显示的唯一来源**。
//
//  与 `AICodeBlockMetrics` 同一定位：量算在共享层（`AIChatRow.height(in:)` 要算它），
//  显示在两端视图（iOS `AIAssistantTextCell` / Mac `ChatRowView`）—— 两边必须用
//  同一份字体 / 段落样式 / 内边距，否则就是「量的时候按一套、显示按另一套」，
//  本工程反复栽过的坑。
//
//  ☑ 2026-10-20 随「思考展示」功能新增。
//
//  ⚠️ 改任何一个数字只改本文件 —— 不要在视图里再写一份数值。
//

import Foundation
import AIPlatform

public enum AIThinkingBlockMetrics {

    // MARK: - 尺寸常量

    /// 折叠态高度（一行标题：标题 + 耗时 + chevron）。含上下留白 ——
    /// 它就是「折叠时这一条占多高」的完整答案。
    public static let collapsedHeight: CGFloat = 28

    /// 展开态：标题行与思考正文之间的间距
    public static let headerSpacing: CGFloat = 6

    /// 左侧竖线宽（「这是思考、不是正文」的视觉标记；颜色由视图层给）
    public static let accentLineWidth: CGFloat = 2

    /// 竖线与文字的间距
    public static let accentSpacing: CGFloat = 8

    /// 思考正文右侧留白（相对气泡内缘）
    public static let rightInset: CGFloat = 4

    /// 思考块底部与**主正文**之间的间距。
    ///
    /// 🔴 **必须等于 `AIMarkdown.contentPaddingV`（都是 10）**，改一侧就要一起改 ——
    ///    iOS cell 的布局靠这个等式成立：思考块不存在时它的高度归 0、top 偏移归 0，
    ///    于是 `contentStack` 的 top 落点 = 气泡顶 + 0 + 本常量 = 气泡顶 + `contentPaddingV`，
    ///    与「没有思考功能时的布局」逐像素一致（量高与显示才不会对不上）。
    public static let spacingBelow: CGFloat = 10

    // MARK: - 文本属性

    /// 思考正文的字体。比正文小一档（`notice` 15pt）—— 它是「次要内容」。
    public static var font: AIPlatformFont { AITypography.notice }

    /// 段落样式。
    ///
    /// ⚠️ 折行模式是「量高与显示同源」的一部分：`boundingRect` 拿不到视图的
    ///    `lineBreakMode`，只能靠这份段落样式传达，两边必须字面一致。
    /// - Note: 样式本身由 `AIPlatformText` 造（`NSParagraphStyle` 不在 Foundation，
    ///   两平台分别在 UIKit / AppKit —— 构造点收在接缝层，这里只说「要什么节奏」）。
    public static var paragraphStyle: AIPlatformParagraphStyle {
        AIPlatformText.paragraphStyle(charWrapping: false, lineSpacing: 3)
    }

    /// 思考正文的富文本属性（字体 / 颜色 / 段落样式）。
    ///
    /// 颜色取 `AITypography.codeText`（比正文浅一档的深灰，与代码卡片正文同一档）——
    /// 视图层可覆盖成各自的语义色，但**量高只依赖字体与段落**，两边永远对得上。
    public static var attributes: [NSAttributedString.Key: Any] {
        [.font: font,
         .foregroundColor: AITypography.codeText,
         .paragraphStyle: paragraphStyle]
    }

    // MARK: - 高度

    /// 思考块占的高度（**含**底部与主正文的间距 `spacingBelow`）。
    ///
    /// - Parameter width: **气泡内可用宽**（与 `AIChatRow.height(in:)` 的 `maxTextW` 同源）。
    ///   块自己再扣掉竖线、竖线间距与右侧留白。
    /// - Parameter expanded: 展开（流式中 / 用户点开）还是折叠（完成后的默认态）。
    public static func height(for text: String, width: CGFloat, expanded: Bool) -> CGFloat {
        guard expanded else { return collapsedHeight + spacingBelow }
        let textWidth = max(width - accentLineWidth - accentSpacing - rightInset, 1)
        let bounding = (text as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil).height
        // 与正文量高同口径兜一行高：刚展开还没内容的瞬间不该把块压成一条缝
        let textHeight = max(ceil(bounding), font.aiLineHeight)
        return collapsedHeight + headerSpacing + textHeight + spacingBelow
    }
}
