//
//  MacLinkify.swift
//  AsterMac
//
//  mac 侧的「链接色绑定壳」—— 逻辑本身在共享层 `AICore/AILinkify.swift`。
//
//  ## 为什么这里只剩一层壳
//  判定与改写（裸网址补 `.link` / 上色 / http→https / 跳过 mailto）是**纯富文本变换**，
//  与平台无关；2026-10-02 iOS 也提了同一个需求（「会话返回 网页地址 显示蓝色，
//  点击网页地址 push 进入 web 页面」）⇒ 那份逻辑上移到 `AILinkify`，
//  两端各自只保留**自己那份链接色**。⛔ 别把逻辑抄回本文件。
//
//  ## 保留本枚举（而不是让调用点直接写 `AILinkify.apply`）的两个理由
//  ① 颜色来源单一：`MacTheme.linkTextNSColor`（明暗两档实测值）只在 `linkColor` 一处出现；
//  ② `MarkdownRenderer` / `MacLinkHit` / 渲染台探针（`LINKIFY` / `LINKCOLOR` / `LINKHOVER`）
//     按 `MacLinkify.apply(to:)` 与 `MacLinkify.linkRanges(in:)` 调用，签名不变 ⇒ 调用点零改动。
//

import Foundation
import AppKit
import AICore

enum MacLinkify {

    /// 补链接 + 上色。没网址也没链接时**原样返回入参**（`AILinkify.apply` 内部早退）。
    static func apply(to attributed: NSAttributedString) -> NSAttributedString {
        AILinkify.apply(to: attributed, linkColor: linkColor)
    }

    /// 链接色。**值来自 `MacTheme`**（唯一来源，见那边的注释：实测浅 #0068DA / 暗 #419CFF）。
    ///
    /// ⚠️ 这里拿的是 `.linkColor` 这个**动态** `NSColor`（明暗各解析一次），
    ///    所以暗色模式下自动是较亮的那档蓝 —— 不要替换成某个写死的 `NSColor`。
    static var linkColor: NSColor { MacTheme.linkTextNSColor }

    /// 富文本里**带 `.link`** 的区间。转发到共享层 —— 判据只此一份。
    static func linkRanges(in attributed: NSAttributedString) -> [NSRange] {
        AILinkify.linkRanges(in: attributed)
    }
}
