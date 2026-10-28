//
//  AITypography.swift
//  AICore
//
//  对话区排版基准：字号与配色的**唯一**来源。
//
//  为什么要有这个文件：字号原先散落在 5 处（用户气泡、助手气泡流式、助手气泡兜底、
//  Markdown 渲染、行高量算），数字各写各的就会漂 —— 实际表现是「流式时 16，Markdown 渲染完
//  变了另一档」，同一段话在收尾瞬间跳字号。
//  约定：**需要字号的代码一律引用这里，不再直接写数字**（行高量算也必须用同一份，
//  否则会出现「量的时候按 16、显示按 17」→ 高度不够裁掉最后一行）。
//
//  ## 类型为什么是 `AIPlatformFont` / `AIPlatformColor` 而不是 `UIFont` / `UIColor`
//  本文件已从 App 内联代码搬进 `AICore`，而 `AICore` 要同时给 iOS 与 macOS 用。
//  平台别名在 iOS 上**就等于** `UIFont` / `UIColor`（`typealias` 是透明的），
//  所以对 App 侧是零影响的改动 —— 那边写 `UIFont` 接这些值照样编译。
//
//  ## ⚠️ 颜色一律走 `AIPlatformColor.aiGray(...)` / `.aiBlack` / `.aiWhite`
//  不是因为这些成员两平台不同名（其实同名），而是工程的
//  `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`：
//  **用某个成员就必须 import 声明它的模块**，`.white` 的声明在 UIKit / AppKit。
//  经过 `AIPlatform` 转一手，本文件就只需 `import AIPlatform`。
//

import Foundation
import AIPlatform

public enum AITypography {

    // MARK: - 正文（用户气泡与助手气泡共用）

    /// 正文字号的**基准值**（16）—— 档位偏移量的原点。
    ///
    /// 🔴 `bodyFontSize` = 这个基准 + 用户在设置里选的档位偏移（见 `AIFontSizeScale`）。
    ///    ⛔ 别把「当前字号」写成一个常量：那样设置页改档位就没有任何效果。
    public static let bodyFontSizeBase: CGFloat = 16

    /// 当前档位偏移量（-2 / 0 / +2 / +4）。
    ///
    /// 🔴 这里是 Mac 侧 SwiftUI 的**统一依赖登记点**：读一次 `AIFontSizeRevision`
    ///    （与 `AILanguageRevision` 同一套手写 `Observable`）⇒ `bodyFontSize` / `notice` /
    ///    `code` 三个字号属性**全都经过它**，凡是渲染过这三类字体的视图都在改档位时
    ///    各自重算，零接线。
    ///    ☠️ 2026-10-15 的教训：原先只有 `bodyFontSize` 读版本号，`notice` / `code` 不读
    ///    ⇒ 挂 `MacTheme.notice` 的视图（失败提示行、媒体说明）改档位时不重算。
    ///    ⛔ 别在某个字体属性里单独读一遍又漏掉另一个 —— 要加新字号就加在这里。
    ///    ⚠️ `@available` 那一层是给 **iOS 15 / 16** 的：那边没有 Observation，
    ///    走 `AIFontSizeStore.didChange` 通知那条路（UIKit 侧由会话页自己重载）。
    private static var offset: CGFloat {
        if #available(iOS 17.0, macOS 14.0, *) { _ = AIFontSizeRevision.shared.value }
        return AIFontSizeStore.current.offset
    }

    /// 正文字号 —— 用户消息和 AI 消息**共用同一个值**，
    /// 这就是「AI 返回的普通文本，最终显示和我说的一样大」的落点。
    ///
    /// ⚠️ 2026-10-14 起它是**计算属性**（原来是 `static let 16`）：设置页新增「字体大小」四档，
    ///    每处读它的代码（气泡 / 输入框 / Markdown 渲染 / 行高量算）自动跟上，不需要逐个改。
    public static var bodyFontSize: CGFloat { bodyFontSizeBase + offset }

    /// 正文常规字重（流式态、Markdown 降级兜底、行高量算都用它）
    public static var body: AIPlatformFont { .aiSystem(ofSize: bodyFontSize) }

    /// 气泡正文颜色。
    ///
    /// 助手气泡是**固定浅底**（`aiGray(white: 0.95)`，不跟暗黑模式变），
    /// 所以正文必须是**固定深色**：用 `.label` 的话暗黑模式下是白字写浅底，直接看不见。
    /// 统一到这里之后，流式态与 Markdown 终态的正文颜色也终于一致了
    /// （Down 默认给的本来就是黑色，只有流式态是 `.label`）。
    public static let bodyColor: AIPlatformColor = .aiBlack

    // MARK: - 失败提示（`.error` 块）

    /// 失败提示字号：比正文小一号。这是**刻意的层级区分**（它是系统提示，不是模型输出），
    /// 与 `AIChatRow.height(in:)` 里那个分支保持同一口径。
    ///
    /// ⚠️ 这是**基准值**（与 `bodyFontSizeBase` 同性质）；实际字号走下面的 `notice`
    ///    （基准 + 档位偏移）—— 2026-10-15 用户报「会话页数据不跟随」时发现它原是常量，
    ///    失败提示是会话数据的一部分，不跟随就是层级断裂。
    public static let noticeFontSize: CGFloat = 15

    /// 失败提示字体。**计算属性**（基准 + 档位偏移，与 `bodyFontSize` 同一口径）——
    /// 量算（`AIChatRow.height(in:)` 的 `.error` 分支）与渲染读的是同一个属性，天然同源。
    /// 偏移量走私有的 `offset`（顺带登记字号依赖），⛔ 别绕过它直接读 Store。
    public static var notice: AIPlatformFont {
        .aiSystem(ofSize: noticeFontSize + offset)
    }

    // MARK: - 流式等待指示（首字到达前的三点）

    /// 三点等待指示的颜色。
    ///
    /// 与 `bodyColor` 同理：助手气泡是**固定浅底**，所以这里必须是**固定灰**而不是语义色
    /// （`.secondaryLabel` 在暗黑模式下变浅 → 写浅底上直接看不见）。
    /// 取值是刻意的中间档：比正文（纯黑）浅得多、不与内容抢注意力，
    /// 但比气泡底（white 0.95）深到一眼能看见。
    public static let typingDotColor: AIPlatformColor = .aiGray(white: 0.45)

    // MARK: - 代码（行内代码 + 代码卡片）

    /// 代码字号：13。
    ///
    /// 比正文（16）小一档：等宽字体同字号看起来更大，而且代码属**引用性内容**，
    /// 不该和正文抢注意力。
    /// ⚠️ 这是**基准值**（与 `bodyFontSizeBase` 同性质）；实际字号走下面的 `code`
    ///    （基准 + 档位偏移）—— 2026-10-15 起它不再是 `static let`：那个常量形态会把
    ///    Menlo **定死在首次访问那一刻的字号**上，之后用户改档位，行内代码与代码卡片
    ///    毫无反应（`AIMarkdown` 的 styler 曾犯过一模一样的错，见那个文件头的铁律）。
    public static let codeFontSize: CGFloat = 13

    /// 代码字体（等宽）。**唯一来源**：Markdown 渲染器的 `fonts.code`（行内代码 `code`）、
    /// 代码卡片视图、以及两处量高函数全都取它。
    /// ⛔ 别在别处再写一次 `aiNamed(...)` —— 那会变成「量的时候按 A 字体、显示按 B 字体」。
    /// 🔴 **必须是计算属性**（基准 + 档位偏移）：⛔ 不许改回 `static let`，理由见上。
    ///    量算（`AICodeBlockMetrics`）与渲染读的是同一个属性 ⇒ 改档位后仍然同源。
    public static var code: AIPlatformFont {
        let size = codeFontSize + offset
        return AIPlatformFont.aiNamed("Menlo", size: size)
            ?? AIPlatformFont.aiMonospaced(ofSize: size)
    }

    /// 代码**卡片**底色：纯白。
    /// 气泡是固定浅灰（white 0.95），卡片比它更亮 → 一块内嵌的白，再靠描边「切」出来。
    ///
    /// ⚠️ 必须**固定色**：用 `systemBackground` 会在暗黑模式变成黑底，
    /// 在固定浅色的气泡里戳出一个黑洞（与 `bodyColor` 同一条理由）。
    public static let codeCardBackground: AIPlatformColor = .aiWhite

    /// 代码卡片描边。很浅的一条灰 —— 只负责把白卡从浅灰气泡里切出来。
    /// 头部与代码之间的分隔线也用同一个色（视觉上是一套线）。
    public static let codeCardBorder: AIPlatformColor = .aiGray(white: 0.88)

    /// 代码正文颜色：近黑。
    /// ⚠️ 刻意**不用纯黑**：等宽小字用纯黑会比正文更「重」，层级就反了（正文才是主体）。
    public static let codeText: AIPlatformColor = .aiGray(white: 0.13)

    /// 卡片头部（语言名 / 「复制」按钮）的颜色：中灰，属元信息
    public static let codeHeaderText: AIPlatformColor = .aiGray(white: 0.52)
}
