//
//  AICodeBlockMetrics.swift
//  AsterCore
//
//  代码卡片的尺寸常量 / 文本属性 / 高度量算 —— **量高与显示的唯一来源**。
//
//  ## 为什么它在业务层，而不是跟视图放一起
//  `AIMarkdown`（业务层）算行高时要知道代码卡片多高，`AIChatRow.height(in:)` 走的也是
//  同一条路；而真正把卡片画出来的 `AICodeBlockView` 是 UIKit 视图、留在 App 侧。
//  两端必须用**同一份**字体 / 段落样式 / 折行模式 / 内边距 —— 否则就是
//  「量的时候按一套、显示按另一套」，本工程反复栽过的坑。
//
//  所以把这份「口径」提到业务层：
//    - 业务层（`AIMarkdown` / `AIChatModels`）直接读这里算高；
//    - App 侧视图（`AICodeBlockView`）**只负责画**，常量与属性全部转发到这里取。
//
//  ⚠️ 改任何一个数字只改本文件 —— 不要在视图里再写一份数值。
//

import Foundation
import AIPlatform

public enum AICodeBlockMetrics {

    // MARK: - 尺寸常量

    /// 卡片左右外边距（相对气泡内缘）。取 12 与正文的左右 inset 同值 —— 左边对齐。
    public static let sideInset: CGFloat = 12
    /// 卡片内边距（头部 / 代码到卡片边缘）
    public static let contentPadding: CGFloat = 12
    /// 头部条高度（**含**底部那条发丝分隔线）
    public static let headerHeight: CGFloat = 27

    // MARK: - 文本属性

    /// 代码段落样式。
    ///
    /// ⚠️ 折行模式是「量高与显示同源」的一部分：`boundingRect` 拿不到 UILabel 的
    /// `lineBreakMode`，只能靠这份段落样式传达，两边必须字面一致。
    ///
    /// ⚠️ 代码里没有空格可依 → 必须按**字符**折行（`.byCharWrapping`）；
    /// 用 `.byWordWrapping` 会让长标识符（`someVeryLongFunctionName(...)`）直接溢出卡片。
    ///
    /// - Note: 样式本身由 `AIPlatformText` 造（`NSMutableParagraphStyle` 不在 Foundation，
    ///   两平台分别在 UIKit / AppKit —— 构造点收在接缝层，这里只说「要什么节奏」）。
    public static var paragraphStyle: AIPlatformParagraphStyle {
        AIPlatformText.paragraphStyle(charWrapping: true, lineSpacing: 3)
    }

    /// 代码正文的富文本属性（字体 / 颜色 / 段落样式）。
    /// 字体与颜色取自 `AITypography`，**不在这里另写字号**。
    public static var attributes: [NSAttributedString.Key: Any] {
        [.font: AITypography.code,
         .foregroundColor: AITypography.codeText,
         .paragraphStyle: paragraphStyle]
    }

    // MARK: - 高度

    /// 整条卡片的高度（含头部条与上下内边距）。
    ///
    /// - Parameter width: **气泡内可用宽**（与 `AIChatRow.height(in:)` 的 `maxTextW` 同源）。
    ///   卡片自己再扣掉 `sideInset`（左右外边距）与 `contentPadding`（卡片内边距）。
    public static func height(for code: String, width: CGFloat) -> CGFloat {
        let textWidth = max(width - sideInset * 2 - contentPadding * 2, 1)
        let bounding = (code as NSString).boundingRect(
            with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil).height
        // 与正文量高同口径兜一行高：空代码块（```` ```\n``` ````）不应该把卡片压成一条缝
        let textHeight = max(ceil(bounding), AITypography.code.aiLineHeight)
        return headerHeight + contentPadding + textHeight + contentPadding
    }
}
