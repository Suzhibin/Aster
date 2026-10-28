//
//  MacTheme.swift
//  AsterMac
//
//  聊天区的字体与配色口径。**字体**全部转发到业务层 `AITypography` ——
//  字号在两个 App 之间同源，改一处两边一致。
//
//  ## 为什么这里不需要任何「NSFont → Font」转换
//  `AITypography.body` 的静态类型是 `AIPlatformFont`，它在 macOS 上就是 `NSFont`
//  （`typealias` 是透明的）。而 SwiftUI 自带桥接：`Font(_ font: NSFont)` /
//  `Color(_ color: NSColor)`（macOS 11+，已离线 typecheck 验证）。
//  所以直接 `Font(AITypography.body)` 就是对的 —— 手写一个转换器反而会引入偏差
//  （比如把 Menlo 认成 `system(design: .monospaced)`，代码区看起来就不一样了）。
//
//  ## 🔴 颜色口径：**语义色**（2026-09-21 起与 iOS 分叉）
//
//  助手行**不画气泡底** —— 它的背景就是 `MacTheme.pageBackground`（页面底），
//  而这个值随系统明暗变。于是 Mac 侧的正文 / 代码卡片 / 占位底**必须全部用语义色**：
//  正文若继续用业务层的 `AITypography.bodyColor`（固定黑），暗黑模式下就是
//  「黑字写深底」= 直接看不见。
//
//  ⛔ **不要去改业务层的 `AITypography`**。iOS 侧的助手气泡是**固定浅灰**
//  （`aiGray(white: 0.95)`），那边必须配固定深字 —— 改成语义色的话，暗黑模式下
//  `.label` 变白，白字写浅灰底，同样看不见。两个平台从「气泡形态」这一步就分叉了；
//  分叉点收在本文件（视图层），业务层保持平台无关。
//
//  ## 用户气泡相反：**颜色不变**
//  强调色底 + 固定白字（iOS 侧写死 `systemBlue`，Mac 侧跟系统强调色）。
//  强调色在明暗两种模式下都足够深，白字始终能看 —— 所以这里不需要语义色。
//
//  ## 语义色的实测取值（2026-09-21 色板探针，对照调色时用）
//
//  | NSColor | 浅色 | 深色 |
//  |---|---|---|
//  | `windowBackgroundColor` | `#ECECEC` | `#323232` |
//  | `textBackgroundColor` | `#FFFFFF` | `#1E1E1E` |
//  | `controlBackgroundColor` | `#FFFFFF` | `#1E1E1E` |
//  | `Color.primary`（文字） | `#000000` | `#D8D8D8` |
//
//  ⚠️ **2026-10-04 起 `pageBackground` 不再是上面的 `windowBackgroundColor`** ——
//  它改成了自定义动态色（浅 `#FFFFFF` / 深 `#323232`，见下面常量那段）。
//  表里那行是**系统值**，仍作参照；`mediaPreviewBackground` 等其它常量还在用它。
//
//  ⚠️ `Color(nsColor:)` **会跟随 SwiftUI 的 `\.colorScheme`**（离屏渲染下也一样，
//  探针实测过），所以本文件可以放心用「裸 NSColor」去表达明暗两套值。
//  ⚠️ `separatorColor` 带 alpha，实测会被解析成很低对比的一条线 —— 这正是想要的。
//

import SwiftUI
import AppKit
import AICore

enum MacTheme {

    // MARK: - 字体（唯一来源：AITypography）

    static var body: Font { Font(AITypography.body) }
    static var notice: Font { Font(AITypography.notice) }
    static var code: Font { Font(AITypography.code) }

    /// 正文字号（pt）。给**量算层**用：`body` 是 SwiftUI 的 `Font`（拿不到 pointSize），
    /// 而 `MacLinkHit` 判「这一行没有字体」时要落回它 —— 那一行在 SwiftUI 里就是用
    /// `body` 这个字体画的。⛔ 别在这里写死数字，来源仍是 `AITypography`。
    static var bodyFontSize: CGFloat { AITypography.bodyFontSize }

    // MARK: - 界面 chrome 的字号缩放（2026-10-15）
    //
    // 🔴 **为什么要有这一组**：原先「字体大小」四档只作用于**会话正文**
    //    （`AITypography.bodyFontSize`），而设置页 / 侧栏 / 输入栏 / 菜单的字号全是
    //    视图层写死的常量 ⇒ 用户在设置里调档位，那些地方**毫无反应**
    //    （用户 2026-10-15 原话：「要把本地的文本 比如菜单、设置内的文字大小同时改变」）。
    //
    // ## 用法
    // ```swift
    // .font(MacTheme.ui(13))                          // 原 `.font(MacTheme.ui(13))`
    // .font(MacTheme.ui(13, weight: .semibold))       // 原 `.system(size: 13, weight: .semibold)`
    // ```
    // ⚠️ **只用于「界面 chrome」**，⛔ 不要拿它包会话正文 —— 正文走 `MacTheme.body`
    //    （`AITypography` 的加减口径），不走这里的比例口径（`uiScale` 的文件注释有分工）。
    // ⚠️ **图标尺寸不缩放**（`*IconSize` / `*Size` 常量保持原样）：用户点名的是「文本」，
    //    且不少图标与写死的 frame 配对，一起放大容易溢出/偏心。文字放大后
    //    视觉重心已经足够，图标维持原尺寸是可接受的取舍。
    //
    // ## 依赖登记
    // `uiScale` 读一次 `AIFontSizeRevision`（与 `AITypography.bodyFontSize` 同一手法）
    // ⇒ 任何在 body 里调过 `MacTheme.ui(...)` 的视图都登记了「档位变了叫我重算」，
    //    `bump()` 一下各自重算，**零接线**。⚠️ 因此它必须是 `static var`（计算属性），
    //    ⛔ 不许缓存成 `static let` —— 那会让全进程共用第一次求值的结果（改档位不生效）。

    /// 当前 chrome 缩放系数（0.875 / 1 / 1.125 / 1.25）。来源 `AIFontSizeStore.uiScale`。
    static var uiScale: CGFloat {
        if #available(iOS 17.0, macOS 14.0, *) { _ = AIFontSizeRevision.shared.value }
        return AIFontSizeStore.uiScale
    }

    /// chrome 文本字体：按 `uiScale` 缩放后的系统字体。
    static func ui(_ size: CGFloat) -> Font {
        Font.system(size: max(size * uiScale, 1))
    }

    /// chrome 文本字体（带字重）。
    static func ui(_ size: CGFloat, weight: Font.Weight) -> Font {
        Font.system(size: max(size * uiScale, 1), weight: weight)
    }

    /// chrome 文本字体（带设计，等宽用）。
    static func ui(_ size: CGFloat, design: Font.Design) -> Font {
        Font.system(size: max(size * uiScale, 1), design: design)
    }

    // MARK: - 文字

    /// 正文。⚠️ 刻意**不走** `AITypography.bodyColor` —— 那个固定黑是给 iOS 的
    /// 固定浅灰气泡准备的，在 Mac 上（背景随明暗）会看不见（见文件头）。
    static let bodyColor: Color = .primary
    /// 元信息：时间戳、文件大小、图标
    static let meta = Color(nsColor: .tertiaryLabelColor)

    // MARK: - 正文的富文本墨色（2026-10-07 加，Down 固定色的替换表）
    //
    // 🔴 **为什么需要这一组**：`AIMarkdown` 把正文交给 Down 渲染，而 Down 的
    // `StaticColorCollection` **默认 `body: .black`** —— 它把这个值
    // **写进每个 run 的 `.foregroundColor`**。run 属性的优先级**高于**视图层的
    // `.foregroundStyle`，所以 `AssistantTextChrome` 那个 `.foregroundStyle(bodyColor)`
    // 在这里**完全不起作用** ⇒ 深色模式下助手正文是「黑字写深底」。
    //
    // 📌 **实测**（`ImageRenderer`，铺 `textBackgroundColor` 底，统计墨色像素）：
    // | run 上的前景色 | 浅色 | 深色 |
    // |---|---|---|
    // | `NSColor.black`（现状 = Down 默认） | 黑字 ✅ | **ink=0，完全看不见** ❌ |
    // | `NSColor.labelColor` | 黑字 ✅ | 白字 ✅ |
    // | 不带色 + 视图层 `.foregroundStyle` | 黑字 ✅ | 白字 ✅ |
    //
    // ⚠️ 由此得出两条口径（`MacDownInk` 照着办）：
    // ① **必须改 run 上的色**，光改视图层没用；
    // ② 用 `NSColor.labelColor` 这类**系统动态色**（它自己跟随外观），
    //    不要把 `Color.primary` 解析成一个**静态分量值**再写回 run —— 那样外观切换后不跟随。
    //
    // ⛔ 下面三个只服务 `MacDownInk` 的替换表，⛔ 别拿它们去改视图层的颜色
    //    （视图层用上面的 `bodyColor` / `meta`）。它们存在的唯一理由是：
    //    **Down 的默认调色板是按「白底文档」设计的**，得整档换成 Mac 的语义色。
    /// 🔴 **替换表：Down 的默认墨色 → Mac 的语义色**（`MacDownInk` 唯一取色处）
    ///
    /// ⚠️ **为什么浅色档「原样沿用 Down 的值」，而不是换成 `labelColor` 那一套**：
    /// `labelColor` 之类系统语义色**都带 alpha**（实测 `labelColor` = `RGB(0,0,0) A=0.85`
    /// / `secondaryLabelColor` A=0.50 / `tertiaryLabelColor` A=0.26）⇒ 浅色下正文会从
    /// 纯黑变成 `#262626`、引用从 `#555` 变成 50% 灰 ⇒ **浅色模式观感被偷偷改掉**。
    /// 本工程口径是「改深色不许动浅色」⇒ 浅色档必须是**原值**（`0.000 / 0.333 / 0.667`）。
    ///
    /// 📌 **深色档的取值是量出来的**，不是拍的。底色取 `textBackgroundColor` 深色值 `#1E1E1E`
    ///    （= 助手行真正趴着的那层底），对比度按 WCAG 相对亮度公式算：
    /// | 档 | 浅色（沿用原值·对比） | 深色 | 深色对比 |
    /// |---|---|---|---|
    /// | `.body` | `#000000` · 21.0:1 | `#E8E8E8` | **5.5:1** |
    /// | `.quote` | `#555555` · 2.7:1 | `#A8A8A8` | 4.0:1 |
    /// | `.meta` | `#AAAAAA` · 1.5:1 | `#8C8C8C` | 3.2:1 |
    /// （`.quote` 在浅色下本来就只有 2.7:1 —— 那是 Down 的既有观感，⛔ 不在本次改动范围。）
    ///
    /// 🔴 **必须用 `NSColor(name:dynamicProvider:)` 而不是 `Color.primary`**：
    ///    run 上的 `.foregroundColor` 只认 `NSColor`，且**必须是动态色** ——
    ///    把 `Color.primary` 在某一刻解析成静态分量写回 run，外观切换后**不跟随**。
    static let downInk: [DownInkSlot: NSColor] = [
        .body:  dynamicInk(light: 0.000, dark: 0.910),
        .quote: dynamicInk(light: 0.333, dark: 0.659),
        .meta:  dynamicInk(light: 0.667, dark: 0.549),
    ]

    /// 造一支「浅色 `light` / 深色 `dark`」的灰阶动态色（两个参数都是 0…1 的灰）。
    ///
    /// ⚠️ `NSAppearance.performAsCurrentDrawingAppearance` 是**唯一**可靠的判别方式：
    /// 只看 `appearance.name` 拿不到「当前实际生效的那一套」（`NSAppearance(named:)` 的
    /// 名字与 `bestMatch` 在某些组合下会不一致）。
    private static func dynamicInk(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            // 📌 `bestMatch(from:)` 就是判「这套外观里哪个是深色」的标准做法，
            //    本工程 `pageBackground`（上面那段）用的也是它 —— 两处保持一致。
            //    ⚠️ 别试图用 `NSAppearance.currentDrawingAppearance` 包一层来「更准」：
            //    那个 API 的闭包**同步执行且不返回值**，套上去只会让动态色在某些
            //    取色时机下退化成静态值（实测过一次，见 git 外的验证记录）。
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        }
    }

    /// 替换表里用到哪几档。
    ///
    /// ⚠️ **刻意不含 `link`** —— 链接色由 `MacLinkify` / `linkTextNSColor` 单独管，
    ///    两处各管一支色、互不覆盖（Down 给的 `.blue` 会被 `MacLinkify` 整段刷掉）。
    enum DownInkSlot {
        /// Down 的 `colors.body`：正文 / 各级标题 / **行内代码**（三者在 Down 里同色）
        case body
        /// Down 的 `colors.quote`：引用块文字
        case quote
        /// Down 的 `colors.listItemPrefix`：有序列表的序号
        case meta
    }

    // MARK: - 正文里的链接（2026-09-30 加）
    //
    // 入口：用户点助手正文里的网址 → 会话页右侧滑出网页面板（`Views/WebPageView.swift`）。
    // 用户当天补了一句「网址应该显示蓝色」—— 在那之前，链接**没有任何颜色**：
    // 既没有系统帮忙上色（SwiftUI 的 `Text` 不会给 `.link` run 换色），
    // 我们自己也只补了 `.link` 属性（见 `MacLinkify`）。

    /// 🔴 **链接色的唯一来源**。AppKit 侧（`MacLinkify` 往 run 上写 `.foregroundColor`）
    ///    直接用它；SwiftUI 侧由 `linkText` 导出 —— 两边同一支色，改这一行就够。
    ///
    /// 📌 实测值（2026-09-30，`NSColor.linkColor` 在本机解析出来的 sRGB）：
    ///    浅色 `#0068DA` / 暗色 `#419CFF` —— 两档都是明确的蓝，且在各自底上都读得清。
    ///    它的浅色值**不等于** `controlAccentColor`（`#007AFF`）⇒ 它是系统固定的「链接色」，
    ///    不随用户改强调色而变。
    ///
    /// ⛔ **不要改成 `Color.accentColor`**：强调色是用户能改的偏好（改成粉色/石墨色，
    ///    网址就不再是蓝的），而这一条是用户点名要的观感。
    /// ⚠️ 也别写死 `systemBlue`：浅色底上 `#007AFF` 偏亮、暗色底上又偏浓，
    ///    而 `.linkColor` 两档各自调过（苹果在系统里就是这么用的）。
    static let linkTextNSColor: NSColor = .linkColor

    /// 正文里的网址颜色（SwiftUI 版，源自 `linkTextNSColor`，别另写一个色值）
    static let linkText = Color(nsColor: linkTextNSColor)

    // MARK: - 代码卡片
    //
    // 助手行没有气泡底之后，代码卡片是唯一「有面」的正文元素 ——
    // 靠 `textBackgroundColor`（比页面亮/暗一档）从页面底上浮起来。

    static let codeCardBackground = Color(nsColor: .textBackgroundColor)
    static let codeCardBorder = Color(nsColor: .separatorColor)
    static let codeText: Color = .primary
    static let codeHeaderText = Color(nsColor: .secondaryLabelColor)

    // MARK: - 气泡 / 面板

    /// 用户气泡：跟系统强调色（iOS 侧写死 `systemBlue`，Mac 侧遵循系统偏好更自然）
    static let userBubble = Color.accentColor
    /// 用户气泡文字：固定白（强调色底足够深，两种模式下都成立）
    static let userBubbleText: Color = .white

    /// 🔴 **页面底色**：聊天区显式刷成它。
    ///
    /// 🔴 **2026-10-04 改：浅色模式 = 纯白**（用户要求「Mac 端会话页面改成白色」）。
    ///    改之前是裸的 `windowBackgroundColor` ⇒ 浅色下 `#ECECEC`（浅灰）。
    ///
    /// ⚠️ **深色模式刻意保持原来的 `windowBackgroundColor`（`#323232`）** ——
    ///    绝不能一并刷白：正文/时间走的是语义色（`.primary` / `.tertiaryLabelColor`），
    ///    暗色下它们是**浅色字** ⇒ 白底浅字直接看不见。
    ///    所以这里必须用**自定义动态色**（浅白 / 深灰），⛔ 不是写死 `Color.white`。
    ///
    /// ⚠️ 也别图省事换成 `Color(nsColor: .textBackgroundColor)`：那个深色值是 `#1E1E1E`，
    ///    页面会掉到**与卡片同色**（比现在的 `#323232` 还暗一档，层次反而没了），
    ///    与「深色保持原样」的口径不符。
    ///
    /// 📌 同一常量还管着**搜索页 / 网页面板 / 输入栏 / 选择栏 / 拖拽浮层**（同为「页面底」语义）
    ///    ⇒ 这几个页面会一起变白（2026-10-04 与用户确认过是想要的）。
    ///    ⚠️ **媒体预览窗不走这里**（它是独立窗口，自己用 `mediaPreviewBackground`），保持原样。
    ///
    /// 这是「AI 返回的内容背景与页面背景统一」这句话的落点 ——
    /// 助手行不画任何底，看到的就是这个色。之所以要在 `ChatDetailView` **显式刷一遍**
    /// 而不是「反正不画底就透出页面」：显式刷过之后，两者是**同一个常量**，
    /// 不会因为 `NavigationSplitView` 的默认材质在某个系统版本上变了而悄悄分家。
    ///
    /// ⚠️ 浅色下页面底（纯白）现在**与卡片底同色了**（`codeCardBackground` / `cardBackground`
    ///    / `composerBackground` 都是 `textBackgroundColor` = `#FFFFFF`）⇒ 卡片只靠描边
    ///    从页面上分出来（2026-10-04 与用户确认「保留描边即可」）。⛔ 别为此把卡片刷深一档。
    static let pageBackground = Color(nsColor: NSColor(name: nil) { appearance in
        // `.bestMatch(from:)` 而不是 `== .darkAqua`：外观可以是 accessories 那些变体，
        // 直接比较会漏。取到 darkAqua 才算暗色。
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x32 / 255.0, green: 0x32 / 255.0, blue: 0x32 / 255.0, alpha: 1)
            : .white
    })

    /// 附件卡片 / 媒体占位底（文件卡片、图片占位、视频占位共用）
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let cardBorder = Color(nsColor: .separatorColor)

    /// 失败提示的文字色（与 iOS 侧 `.systemOrange` 一致）
    static let errorText = Color.orange

    /// 流式等待的三点。语义色：助手行已无浅底，固定灰在暗黑模式下会偏亮。
    static let typingDot = Color(nsColor: .secondaryLabelColor)

    static let bubbleRadius: CGFloat = 14

    // MARK: - 消息底部操作栏（2026-09-21）
    //
    // 每条消息底部那一排图标按钮（复制 / 朗读 / 重试 / 分享）。**图标名与文案不在这里** ——
    // 一律取业务层的 `AIRowAction`（`icon` / `activeIcon` / `title`），与 iOS 侧的
    // `AIActionBarView` 同源；本文件只管尺寸与配色。
    // ⚠️ 别把 SF Symbol 名或中文字串抄进来：那会和业务层漂移（那边加一项操作，这边就得改两处）。

    /// 图标色：跟系统强调色（与用户气泡同一支色，对应 iOS 侧的 `systemBlue`）
    static let actionIcon = Color.accentColor

    /// 不可用态（如「重试」在用户行后面还没有回复时）。三级标签色，与可用态一眼分得开。
    /// ⚠️ 必须**显式**给灰 —— `.disabled(true)` 只拦交互，管不到我们写死的 `foregroundStyle`。
    static let actionIconDisabled = Color(nsColor: .tertiaryLabelColor)

    /// 破坏性动作的图标色（2026-09-29 加；当前只有媒体行的「删除」）。
    ///
    /// 取系统红，与 iOS 侧 `AIRowAction.isDestructive`（`systemRed`）同一支色 ——
    /// 两端对「删除」的观感必须一致。
    /// ⚠️ **判据不在这里**：调用方读业务层的 `action.isDestructive` 决定传不传这个色
    /// （见 `ActionChipButton`）。本文件只提供颜色本身 —— 业务层哪天加第二个破坏性动作，
    /// 这一行不用动。
    static let actionIconDestructive = Color(nsColor: .systemRed)

    /// 图标底色块：强调色降透明度，**明暗两档不同**。
    /// 页面底在暗色下更深（`#323232`），照搬浅色的 0.12 会糊成一片看不出来。
    static func actionChipBackground(_ scheme: ColorScheme) -> Color {
        Color.accentColor.opacity(scheme == .dark ? 0.26 : 0.12)
    }

    /// 底块边长。iOS 侧是 30（指尖目标）；Mac 是鼠标指针，收到 26 —— 更贴 macOS 工具栏的密度。
    static let actionChipSize: CGFloat = 26
    /// 底块圆角（iOS 侧是 6，同一档）
    static let actionChipRadius: CGFloat = 6
    /// 底块间距。iOS 是 12；这里底块小了，间距同比收到 8。
    static let actionChipSpacing: CGFloat = 8
    /// 图标字号：比底块小一圈，四周留出呼吸（与 iOS 侧 30 / 15 的比例一致）
    static let actionIconSize: CGFloat = 12

    // MARK: - 用户侧操作栏 / 就地编辑（2026-09-24）
    //
    // 用户自己发的那几条：**底部那一行恒定占位**，鼠标移上去才显出一排按钮
    // （时间 · 编辑 · 复制 · ⋯，见 `ChatRowUserActionBar`）。
    // 与助手侧的差别只有两点：**默认不可见**、**项数更少**（没有朗读 / 重试 / 分享；
    // ⋯ 里那两项与助手侧同一个集合）—— 尺寸与配色完全共用上面那组
    // `actionChip*`，两块摆在一起不会差一像素。

    /// 用户侧那一行按钮的**占位高度**。
    ///
    /// 🔴 它同时是「常态那条操作栏」与「编辑态那两颗（取消 / 保存）」的高度，
    /// 两处**必须逐像素相同** —— 这一行是**常驻占位**、只靠 `opacity` 显隐；
    /// 一旦两种状态差一像素，一进一出编辑整列消息都会跳一下。
    /// 顺势也是「别把这一行做高」的理由：它给**每一条**用户消息都加了同等空隙。
    static let rowBarSlotHeight: CGFloat = 26

    /// 助手侧操作栏与**上方内容**之间的那点间距（2026-09-29 单点化）。
    ///
    /// 🔴 **文本行与媒体行必须同值** —— 用户 2026-09-29 反馈「图片/视频的操作栏贴着内容、
    ///    文本消息却有间距」。成因是这条间距一直只写在**文本行那一侧的调用点**
    ///    （`ChatRowView.actionBar` 里一个裸 `2`），媒体行（`ChatDetailView.mediaItem`）没有。
    ///    ⇒ 抽成常量、两处共用：以后谁再挪一条栏的位置，另两条不会莫名其妙不齐。
    /// ⚠️ 它叠加在容器 `VStack` 的 `spacing: 3` 之上 ⇒ 可视间距 = `3 + 2 = 5pt`。
    static let rowActionBarTopGap: CGFloat = 2
    /// 编辑态那两颗文字按钮的字号（与 `metaFontSize` 同档附近：它们是「行内的动作」，不该抢正文）
    static var editActionFontSize: CGFloat { 13 * uiScale }
    /// 「取消 / 保存」的间距
    static let editActionSpacing: CGFloat = 14

    /// 就地编辑器的底色：**沿用输入卡片那一套**（`composerBackground` = `textBackgroundColor`，
    /// 比页面亮/暗一档）。
    ///
    /// 🔴 刻意**不**继续用强调色气泡：白字输入框在 macOS 上跟静态文字几乎分不出来，
    /// 「这一块现在能打字」必须一眼看出。轮廓仍走 `bubbleRadius` —— 位置与形状没变，
    /// 变的只是「它现在是个输入框」。
    /// ⚠️ 与 `composerBackground` 是**同一个语义**（App 里「能打字的表面」），
    /// 所以直接引用那个常量、不另立一份：将来输入卡片换底，编辑器一起换才对。
    static let inlineEditorBackground = Color(nsColor: .textBackgroundColor)
    /// 编辑器描边：**强调色**（不是分隔线色）—— 它是「正在编辑」的唯一静态标记，
    /// 用分隔线灰就与代码卡片/文件卡片（那些也能有描边）区分不开了。
    static let inlineEditorBorder = Color.accentColor

    // MARK: - 选择模式 / 勾选圈（2026-09-29）
    //
    // 「多选删除」选择模式下的两块：每行左侧那个勾选圈（`ChatSelectionRow`）与
    // 底部那条顶替输入栏的选择栏（`ChatSelectionBar`）。
    // ⚠️ 圈的尺寸比 iOS 小一档：那边是 `UITableView` 编辑态的**系统圈**（指尖目标，约 22pt），
    //    这边是鼠标，跟 `actionChipSize`（26）同一个密度档。
    // ⛔ 配色**不要**在这里再分「明暗两档」：这两个色都是语义色（强调色 / tertiary），
    //    系统自己会在暗色下换值 —— 手写两档只会比系统更差。

    /// 勾选圈的边长。也是「选中 / 未选中」两个符号的固定框宽（防勾选前后横向抖）。
    static let selectionCircleSize: CGFloat = 18
    /// 圈与行内容的间距。要给足：圈的圆环很细，贴太近会看成内容的一部分。
    static let selectionCircleGap: CGFloat = 10
    /// 选中态的圈（实心对号）：走强调色 —— 与 App 里其它「选中」语义同源。
    static let selectionCircleOn = Color.accentColor
    /// 未选中态的圈（空心）：tertiary 是**刻意**的 —— 它要「在那里」但不能抢正文的注意力。
    static let selectionCircleOff = Color(nsColor: .tertiaryLabelColor)

    /// 选择栏的上下内边距。取 14 与输入栏那一档（`composerMarginTop` 10 + 卡片自身）附近的观感对齐 ——
    /// 它顶替的就是输入栏那一块位置，太扁会看起来像一条突兀的横幅。
    static let selectionBarPaddingV: CGFloat = 14
    /// 选择栏里那个「已选择 N 条」的字号。与 `metaFontSize`（11）同档附近：它是状态报数，不是标题
    static var selectionBarCountFontSize: CGFloat { 13 * uiScale }
    /// 选择栏「删除」那颗的底色。
    /// ⚠️ 引用操作栏那支红而**不是**再写一遍 `systemRed` —— 同一个语义色只该有一个来源
    ///    （业务层 `AIRowAction.isDestructive` → `actionIconDestructive`）。
    static let selectionDeleteTint = actionIconDestructive
    /// 「删除」置灰时的底色。与输入栏那颗发送按钮的禁用底**同值同源**（`composerSendDisabled`）——
    /// 「不能按」在这两块里的观感必须一致。
    static let selectionDeleteDisabled = composerSendDisabled
    /// 「取消」那颗的底色（中性、不抢红按钮的注意力）
    static let selectionCancelBackground = Color.primary.opacity(0.10)
    /// 「取消」那颗的字色
    static let selectionCancelText = Color.primary
    /// 选择栏两颗按钮的字号。与 `selectionBarCountFontSize` 同档：它们是同一行里的东西。
    static var selectionBarButtonFontSize: CGFloat { 13 * uiScale }
    /// 选择栏两颗按钮的内边距（左右 / 上下）与圆角。
    /// ⚠️ 圆角与操作栏底块（`actionChipRadius` = 6）同档 —— 这两个都是「行内的动作块」。
    static let selectionBarButtonPaddingH: CGFloat = 14
    static let selectionBarButtonPaddingV: CGFloat = 5
    static let selectionBarButtonRadius: CGFloat = 6

    // MARK: - 侧栏顶部固定入口（2026-09-22）
    //
    // 左栏**顶上**那两条固定入口：新对话 / AI创作（`Views/SidebarQuickEntries.swift`）。
    // 它们不随下面的会话列表滚动 —— 侧栏从此是三段：**固定入口 / 可滚动列表 / 固定账号栏**。
    // 尺寸参照 macOS 侧栏的行密度（Finder / 备忘录那类），比工具栏紧一档。
    // ⚠️ 图标名与文案**不在这里** —— 那是每条入口自己的语义（见那个文件的文件头），
    //    本文件只管它们长多大、什么颜色。

    /// 单条入口的行高。26 = 鼠标点得中，又不把固定区撑高（侧栏高度是稀缺资源）
    static let quickEntryRowHeight: CGFloat = 26
    /// 两条入口之间的间距
    static let quickEntrySpacing: CGFloat = 2
    /// 固定区的**外层**内边距；行内还各有 `quickEntryRowPaddingH`，
    /// 两者相加 = 文字左边缘距侧栏边 ≈ 12，与账号栏的 `accountBarPaddingH` 对齐。
    static let quickEntryPaddingH: CGFloat = 6
    static let quickEntryPaddingV: CGFloat = 8
    static let quickEntryRowPaddingH: CGFloat = 6
    /// 图标列宽：两条入口的图标左对齐靠它，不靠各自的图标宽度
    static let quickEntryIconWidth: CGFloat = 18
    static let quickEntryIconSize: CGFloat = 12
    static var quickEntryFontSize: CGFloat { 13 * uiScale }
    /// 图标与文字的距离
    static let quickEntryInnerSpacing: CGFloat = 6
    /// 图标色：二级标签色（文字才是正文色 —— 图标是辅助，不该比文字还抢眼）
    static let quickEntryIcon = Color(nsColor: .secondaryLabelColor)
    /// hover 高亮底。侧栏里的行**必须对指针有反应**，否则看不出「能不能点」。
    /// 明暗两档不同（与操作栏底块同一套口径）：暗色底更深，照搬浅色的比例会糊掉。
    static func quickEntryHoverBackground(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.10 : 0.06)
    }
    /// hover 高亮的圆角
    static let quickEntryRadius: CGFloat = 6

    // MARK: - 侧栏分组标题（2026-09-22）
    //
    // 「我的对话」——会话列表那一组的小标题（`ConversationSidebar.conversationArea`）。
    // 它是 `List` 的**兄弟节点**而不是 `List` 里的 `Section`：理由写在那段注释里。

    static var sidebarSectionTitleFontSize: CGFloat { 12 * uiScale }
    /// **会话行标题**字号（2026-10-15 加）。
    ///
    /// 🔴 为什么必须有它：`ConversationRow` 的标题原先**一个 `.font` 都没挂**
    ///    （全仓也没有任何容器级 `.font` / `environment(\.font)`）⇒ 它吃的是 SwiftUI
    ///    默认字体，**从来不在字号档位的缩放链上**（重启也不变）。用户 2026-10-15 报
    ///    「左侧菜单每个对话 title 没有跟随调整」的就是它。
    /// 取 13：与 SwiftUI 给 `.sidebar` 样式 `List` 行的默认字号同档 ⇒ 默认档外观不变。
    static var sidebarRowTitleFontSize: CGFloat { 13 * uiScale }
    /// 标题左边缘与侧栏边距 —— 与入口行、账号栏同一条竖线（≈12）
    static let sidebarSectionPaddingH: CGFloat = 12
    /// 上边距：这是**唯一**把「固定入口」和「会话列表」分成两段的东西
    /// （刻意不画分隔线 —— macOS 的侧栏（备忘录 / 邮件）都靠留白分组，加线反而碎）。
    /// 渲染图实测：2 的时候标题几乎贴住入口区，两段看起来是一段 → 给到 6。
    static let sidebarSectionPaddingTop: CGFloat = 6
    static let sidebarSectionPaddingBottom: CGFloat = 4

    // MARK: - 侧栏会话行的「更多」按钮（2026-09-26）
    //
    // 鼠标滑到会话标题上时，行尾出现一颗「…」（见 `ConversationRow.moreButton`）。
    // 这个尺寸**同时是三样东西**：按钮的命中区边长、图标在其中居中、以及它在行里
    // **恒定占的宽度**（见 `ConversationRow` 里那条「恒占位、只改 opacity」）。

    /// 「…」的命中区边长（也是它在行里恒占的宽度）。
    /// 取 18 而不是 24：侧栏行本来就窄，再宽会把长标题的可用宽度吃掉一大截，
    /// 而 `.middle` 截断的开头几个字正是「找会话」时唯一有用的信息。
    static let sidebarRowMoreButtonSize: CGFloat = 18

    // MARK: - 侧栏列表的系统内距（2026-10-26 实测）
    //
    // 「对齐」这件事必须靠实测值算，不能靠猜：系统给 section header 和普通行的是**两套**
    // 不同的左右内距，于是同一个侧栏里会同时出现三条不同的竖线 —— 用户 2026-10-26 报的
    // 「上面的新建项目图标和底下那三个点没对齐」就是这么来的。
    //
    // ## 怎么测的（可复现）
    // 把 `List { Section { … } header: { … } }.listStyle(.sidebar)` 塞进一个 260×400 的
    // 离屏 `NSWindow` + `NSHostingView`，跑一轮 runloop 后 dump 视图树：
    //   - `ListTableHeaderView`  x=14  w=244  ⇒ 内容右缘 **258**（距侧栏右 260 只有 **2**）
    //   - `ListTableCellView`    x=16  w=228  ⇒ 内容右缘 **244**（距右 **16**）
    // ⚠️ 两个值都随**系统版本**变（本次 macOS 26.x）。升级系统后若又歪了，重跑那个探针
    //    （脚本思路见 VERIFY-PROBES.md §41），⛔ 别凭手感调数字。

    /// `List(.sidebar)` 里**普通行**内容距侧栏右缘的内距（实测 16）。
    /// 会话行那两颗「…」天然落在这条线上 ⇒ 侧栏里其它按钮都往这条线靠。
    static let sidebarListRowTrailingInset: CGFloat = 16

    /// `List(.sidebar)` 里 **section header** 内容距侧栏右缘的内距（实测 2）。
    /// 与上面那条的差（14）就是 header 里的按钮要多收的 `trailing` 量。
    /// ⚠️ 别直接给 16：header 的内容**本来**就贴到 2 了，再给 16 会多缩一倍。
    static let sidebarListHeaderTrailingInset: CGFloat = 2

    // MARK: - 侧栏底部设置栏（2026-09-21 建 · 2026-10-27 改造）
    //
    // 左栏**最下面**那一行：只剩一颗设置齿轮（`Sidebar/SidebarSettingsBar.swift`）。
    //
    // 🔴 2026-10-27 用户「那就把头像和名称都删除吧」⇒ 这里跟着**删掉四个常量**：
    //    `accountAvatarSize` / `accountNameFontSize` / `accountChevronSize` / `accountChevronGap`
    //    （外加 `accountBarSpacing`）—— 它们只服务那块「头像 + 姓名 + `>`」。
    //    ⚠️ 但 **行高 64 的口径**是用户 2026-10-21 单独点名保留的，别当成头像的附属品一起删。
    //    理由与去处见那个视图的文件头（本 App 没有账号体系，那块是假身份）。
    //
    // ## 🔴 2026-10-21 两版（第二版是当前口径，别只看第一版就改回去）
    // **第一版**：用户「头像和名称。还有设置 都放大一倍」⇒ 24/12/13/22 全翻倍、间距也翻。
    //   ⚠️ 结果是整行又高又挤，260 窄档连人名都放不下（`Suzhi…`）。
    // **第二版（当前）**：用户「还是恢复原来大小吧，但是所在区域行高保留限制的吧，
    //   设置按钮的颜色换成黑色」⇒ **内容尺寸回原样**，但**行高留在 64**（见 `accountBarRowHeight`），
    //   齿轮色从 `meta`（浅灰）改成 `bodyColor`。
    //   ⇒ 「内容小、区域大」是**用户明确的取舍**：这一行不贴着内容收紧。
    //   ⛔ 别按「行高 64 但齿轮才 18，太松」把它压回 40 —— 那条审美判断被用户覆盖过一次了。

    /// 齿轮图标字号，以及它的命中区边长 ——
    /// 图标本身只有十几个像素，不加命中区根本点不中（工具栏里的按钮自带一块底板，这里没有）。
    ///
    /// 🔴 **2026-10-21 第三版：13 → 18**（用户「设置按钮偏小 大一些」）。
    ///    为什么是 18 而不是更大：这一行里最大的元素原来是 24 的头像，齿轮是同一层级的
    ///    独立动作入口，比主体还大就会抢视觉地位；13 则明显像「残留的小图标」。
    ///    18 大约 = 24 × 3/4，是这个密度下「够醒目但仍属次级」的位置。
    /// ⚠️ **命中区 22 → 24**：原口径是「等于头像直径」，头像删掉后这条**由 64 行高接管** ——
    ///    `24 + accountBarPaddingV×2 = 64` 仍然成立（见下面的派生），所以数值一个都不用改。
    /// ⛔ 别把命中区再往上调（26 就会把整行顶到 66，与 `accountBarRowHeight` 的口径不一致
    ///    —— 还不报错，只是这一行比设计的略高）。
    static let accountIconSize: CGFloat = 18
    static let accountIconHitSize: CGFloat = 24
    /// 底部栏**内容**右缘距侧栏边的距离（12）。
    /// ⚠️ 这个常量现在是**那条竖线口径的名字** —— 改它等于整个侧栏的竖线跟着动。
    static let accountBarPaddingH: CGFloat = 12

    // MARK: 行高（2026-10-21 第二版新增 —— 唯一的行高真值）

    /// 底部栏的行高：**64**（= 第一版放大后自然撑出来的高度，被用户点名保留）。
    /// 🔴 这是**区域的**高度，不是内容高度：齿轮按 24 的命中区居中，上下各留 20。
    /// ⚠️ 改它只影响「这一行多高」；改齿轮尺寸不会再把行高带跑（见下面的派生）。
    static let accountBarRowHeight: CGFloat = 64

    /// 垂直内边距 = **派生值**：把 `accountIconHitSize` 撑到 `accountBarRowHeight` 所需的余量。
    /// 🔴 必须是计算属性、⛔ 别写死数字：行高与内容尺寸是两条独立的用户口径，
    ///    写死 20 之后谁改命中区谁就得回来手算一遍 —— 漏了的表现是「齿轮偏上/偏下」，
    ///    **不报错**，只是看着歪。
    /// ⚠️ 2026-10-27 之前这里减的是 `accountAvatarSize`（值同样是 24 ⇒ 20pt 不变）；
    ///    头像删掉后改成减命中区，口径从「图像素对齐」变成「命中区撑高」，结果一致。
    static var accountBarPaddingV: CGFloat {
        max(0, (accountBarRowHeight - accountIconHitSize) / 2)
    }

    /// 底栏顶部的 1pt 分隔线（`separatorColor` 带 alpha，是一条低对比的线 —— 正是想要的）
    static let accountBarBorder = Color(nsColor: .separatorColor)

    // MARK: - 「回到底部」悬浮按钮（2026-09-21）
    //
    // 覆盖在消息列表右下角、压在输入栏正上方的那颗圆形按钮。
    // 视图本体见 `Views/ScrollToBottomButton.swift`；iOS 侧同一颗按钮（UIKit 版）
    // 连同它的坑记在技能 `ios-chat-scroll-to-bottom-button` —— 那边**不共用**这份常量
    // （iOS 是 44pt 白底 + 黑投影，见下面的取舍差异）。
    //
    // ## 取舍差异：Mac 这颗**跟随系统外观**，不做固定白底
    // iOS 那颗是「固定白底 + 固定黑阴影」，所以它的图标色必须**写死**中性深色
    // （若用 `.label`，暗黑下会变成白底白箭头 = 一个纯白圆圈）。
    // Mac 这边反过来选：底 / 描边 / 图标**三件全部语义色**，明暗两档自动成对，不冒混搭风险。
    // 代价是黑投影在暗色下几乎看不见 —— 用一圈描边把「浮起来」的观感补回来。

    /// 圆直径。iOS 是 44（指尖目标）；Mac 是鼠标，收到 30，与工具栏的密度一致。
    static let scrollToBottomSide: CGFloat = 30
    /// 箭头字号：比圆小一圈，四周留呼吸
    static let scrollToBottomIconSize: CGFloat = 13
    /// 底：比页面背景亮/暗一档（与输入框同族），从列表内容上「浮」起来
    static let scrollToBottomBackground = Color(nsColor: .controlBackgroundColor)
    /// 描边：暗色下它是**唯一**还能表达的层级线索（黑投影在深底上看不见）
    static let scrollToBottomBorder = Color(nsColor: .separatorColor)
    /// 箭头色：二级标签色（不是强调色 —— 它是个辅助控件，不该跟主要动作抢注意力）
    static let scrollToBottomIcon = Color(nsColor: .secondaryLabelColor)
    /// 投影：浅色下负责「浮起来」；暗色下近乎失效，由描边接手
    static let scrollToBottomShadow = Color.black.opacity(0.18)
    /// 与输入栏之间的留白
    static let scrollToBottomGap: CGFloat = 14
    /// 距窗口右边缘的留白（与消息列表的 `padding(.horizontal, 16)` 同一档）
    static let scrollToBottomMargin: CGFloat = 18

    // MARK: - 搜索页（2026-09-22）
    //
    // 顶部工具栏那颗放大镜弹出来的页面（`Views/MacSearchView.swift`）：
    // 搜索框 + 结果列表 + 底部计数。尺寸比聊天区紧一档 —— 它是一个「临时面板」，
    // 占满整窗会让人以为换了个界面，而不是「弹出的一页」。
    // ⚠️ 关键词高亮的**位置**不在这里 —— range 由业务层 `AISearchMatcher` 算，
    //    本文件只管高亮长什么样（这是「算位置与画位置同源」那条铁律在视图层的落点）。

    /// 页面尺寸。macOS 的 sheet 是按内容尺寸弹的，所以这两个值就是窗口大小。
    static let searchPageWidth: CGFloat = 560
    static let searchPageHeight: CGFloat = 460
    /// 搜索框（外层容器）
    static let searchFieldHeight: CGFloat = 30
    static let searchFieldRadius: CGFloat = 7
    static let searchFieldBackground = Color(nsColor: .textBackgroundColor)
    static let searchFieldBorder = Color(nsColor: .separatorColor)
    static let searchFieldIconSize: CGFloat = 13
    static var searchFieldFontSize: CGFloat { 14 * uiScale }
    /// 页面内边距（搜索框、结果行共用同一条竖线）
    static let searchPaddingH: CGFloat = 12
    /// 顶部区（搜索框那一行）的上下留白
    static let searchHeaderPaddingV: CGFloat = 10

    /// 结果行
    static let searchRowPaddingH: CGFloat = 10
    static let searchRowPaddingV: CGFloat = 7
    static let searchRowRadius: CGFloat = 6
    static let searchRowSpacing: CGFloat = 2
    /// 标题字号；片段比它小一档（片段是辅助信息，不该跟标题抢）
    static var searchTitleFontSize: CGFloat { 13 * uiScale }
    static var searchSnippetFontSize: CGFloat { 12 * uiScale }
    /// 标题与片段之间的行距
    static let searchRowInnerSpacing: CGFloat = 3
    /// hover 高亮底：与侧栏入口行同一口径（侧栏能点、结果行也能点，反馈必须一致）
    static func searchRowHoverBackground(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.10 : 0.06)
    }
    /// 关键词高亮色 = 强调色。⚠️ **只改颜色，不改字重** —— 加粗会让整行抖动
    /// （命中前后字宽变化 → 换行位置跳），而颜色变化不影响排版。
    static let searchHighlight = Color.accentColor
    /// 结果行的分隔线（比页面分隔线更淡：行很密，画满会很吵）
    static let searchRowSeparator = Color(nsColor: .separatorColor).opacity(0.5)

    // MARK: - 搜索命中的定位高亮（2026-09-22）
    //
    // 点搜索结果之后，聊天页把**命中的那一条消息**圈一下（`ChatDetailView`），
    // 否则从几百条里滚过去，用户不知道停在哪一行。
    // 用「淡底 + 描边」而不是只描边：助手行没有气泡底，只有描边时在长正文里几乎注意不到。

    static let revealRadius: CGFloat = 10
    static let revealFill = Color.accentColor.opacity(0.10)
    static let revealBorder = Color.accentColor.opacity(0.55)
    static let revealBorderWidth: CGFloat = 1.5
    /// 高亮圈相对行本身向外扩的边距（负 padding）。给行留出呼吸，别贴着文字画框。
    static let revealPadding: CGFloat = -6
    /// 闪一下的持续时间（秒）；淡出时长写在 `ChatDetailView` 的动画里
    static let revealDuration: TimeInterval = 1.6

    // MARK: - 输入区 Composer（2026-09-22 按用户给的参考图重做）
    //
    // 底部那一整块 = **一张卡片**（文本区 + 控制行）+ 卡片下方一行免责声明。
    // 与旧版的差别（用户原话：「根据图片样式重新设计我的输入框」）：
    //   ① 旧版是「输入框 + 输入框**外面**一排小字」，新版把控制行放**卡片内部**，
    //      整块只有一张卡片 —— 这是参考图的骨架，别按旧版的分法改回去；
    //   ② 旧版输入栏有自己的底色 + 顶部 1pt 分隔线（把聊天区切成两段）。
    //      新版卡片自己就是一块「面」（`composerBackground` 比页面亮/暗一档），
    //      栏底改回**页面背景**、分隔线**去掉** —— 卡片浮在页面上，与参考图一致。
    //
    // 尺寸口径直接照参考图量（2x 截图，除以 2 得 pt）：`+` 字形 13、mic 12、
    // 送信圆 32、控制行文字 13、卡片圆角 ~16。⚠️ 参考图是**裁过的**（上下都切掉了），
    // 所以卡片总高只能反推 ≈ 118（我这边给到 ~96，见 `composerTextMinHeight` 那条）。

    /// 卡片距窗口左右边缘（与消息列表的 `padding(.horizontal, 16)` 同一档）
    static let composerMarginH: CGFloat = 16
    static let composerMarginTop: CGFloat = 10
    static let composerMarginBottom: CGFloat = 8
    /// 卡片与下方免责声明的距离
    static let composerFooterSpacing: CGFloat = 6

    /// 卡片圆角。参考图里它明显比消息气泡（14）更圆 —— 靠近 macOS 的「大控件」观感
    static let composerRadius: CGFloat = 16
    /// 卡片底：`textBackgroundColor`（浅色下纯白、深色下 #1E1E1E），从页面底上浮起来
    static let composerBackground = Color(nsColor: .textBackgroundColor)
    /// 卡片描边。⚠️ 明暗两档都要靠它立边界（暗色下白底→深底只差一档，没有描边会糊）
    static let composerBorder = Color(nsColor: .separatorColor)

    static let composerPaddingH: CGFloat = 12
    static let composerPaddingTop: CGFloat = 12
    /// ⚠️ 下边距**刻意小于**上边距：控制行自己带着一圈内边距（图标命中区），
    /// 两边都按上边距给会显得卡片「下面漏了一截」。
    static let composerPaddingBottom: CGFloat = 8

    /// 文本区最小高度 ≈ 两行（正文 16，行高约 20）。参考图里那块空白比两行还大
    /// （≈3.5 行），但那是它的窗口高度富余；这里取两行 —— 空着太多会让输入栏显得虚。
    static let composerTextMinHeight: CGFloat = 42
    /// 文本区与控制行的距离
    static let composerTextControlSpacing: CGFloat = 8
    /// 控制行高度（所有控件都在这条带上垂直居中）
    ///
    /// 2026-10-21 用户报「输入框内按钮都太小了（语音 / 联网 / 加号 / 模型）」⇒ 26 → **30**；
    /// 2026-10-22 用户又点「+ 号按钮还小，在大一些」⇒ 纯图标键命中区 28 → **32**，行高跟着 30 → **34**。
    /// 行高是**派生自最大的控件**：纯图标键命中区 32、模型块高 32（同日追平，见 `composerChipHeight`）、
    /// 送信圆 30 ⇒ 取 34（= 命中区 32 + 2pt 呼吸；送信圆 30 不变 —— 用户没点它，居中两侧各 2pt）。
    /// ⚠️ 别为「行高配送信圆太贴」把行高压回去 —— 用户点的就是「大」，
    ///    而控件变大后行高不跟着长，hover 底会互相叠（同账号栏那条：命中区 > 行高余量）。
    static let composerControlHeight: CGFloat = 34
    /// 控制行内相邻控件的距离
    /// （2026-10-21 随控件一起放大：4 → 6，否则变大的命中区之间只剩 2pt 缝）
    static let composerControlSpacing: CGFloat = 6

    // 控制行上的「文字块」（工作区 / 权限 / 模型）—— 三个长得一样，用同一个组件画。
    //
    // 参考图里它们**没有底色**（常态就是白底上的一行字 + 图标），只有 hover 才浮起来。
    // 🔴 别给常态加底：加了会读成一排「胶囊按钮」，与参考图那种「这是当前状态、点进去能改」
    //    的观感正好相反（顺带一提，这也是 macOS 上 Picker 的常规画法）。

    // 2026-10-21 用户报「按钮都太小了」⇒ 整组放大一档（22/6/6/14/12/13/5 → 26/7/8/16/14/14/6）。
    // 放大幅度参照账号栏那颗齿轮的第三版（13→18 被接受、翻倍被否）：**约 +15~25%**，
    // ⛔ 不是翻倍 —— 那一版当场被用户否掉（「还是恢复原来大小吧」）。
    // 半径跟着高度走（22→6、26→7，同一比例）：圆角不跟着长，块会从「胶囊」读成「圆角矩形」。
    // ⚠️ 2026-10-22 高度追平纯图标键时半径**没跟着涨**（见 `composerChipHeight` 注释）——
    //    那一轮是「比例让位一致」：一行里的圆角必须同一个数，而纯图标键 32 高配的就是 7。

    /// 模型块高（控制行上唯一一颗**文字块**：图标 + 模型名 + 系统箭头）。
    ///
    /// 🔴 2026-10-22 用户原话「模型按钮 移动鼠标可以变身了，但是按钮的高度 应该和 其他按钮
    ///    一样，现在太矮小」⇒ 26 → **32** = `composerIconHitSize`（与 `+` / 联网 / 🎤 三颗
    ///    纯图标键同高）。仍 ≤ 控制行高 34 − 2 ⇒ 行高不用动、行高派生链不变。
    /// ⚠️ 半径仍 7（没按 22→6、26→7 的比例涨到 ≈9）：一行里圆角必须同一个数，
    ///    而 32 高的纯图标键配的就是 7 —— 一致性 > 比例。
    /// ☠️ 有机械契约钉住「= composerIconHitSize」（`render_mac_ui.sh`）：
    ///    两个数各改一半 = 又漂回「一颗高一颗矮」，而那正是用户这次报的。
    static let composerChipHeight: CGFloat = 32
    static let composerChipRadius: CGFloat = 7
    static let composerChipPaddingH: CGFloat = 8
    /// 图标列宽：同一行里几个块的图标左对齐靠它，不靠各自图标宽度
    static let composerChipIconWidth: CGFloat = 16
    static let composerChipIconSize: CGFloat = 14
    static var composerChipFontSize: CGFloat { 14 * uiScale }
    /// 图标与文字的距离
    static let composerChipGap: CGFloat = 6
    /// 文字色 = 正文色（参考图里这几行字是实的，不是次要信息）
    static let composerChipText: Color = .primary
    /// 图标色：二级标签色（图标是辅助，不该比文字抢眼）
    static let composerChipIcon = Color(nsColor: .secondaryLabelColor)
    /// hover 底：与侧栏入口行 / 搜索结果行同一口径（三处都是「能点的行」，反馈必须一致）
    static func composerChipHoverBackground(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.10 : 0.06)
    }

    /// 纯图标按钮（`+` / 联网 / 麦克风）的命中区边长。
    /// 🔴 图标只有十几个像素，不加命中区**点不中** —— 与账号栏那颗齿轮同一个坑。
    ///
    /// 2026-10-21 用户报「按钮都太小了」⇒ 命中区 24 → **28**、图标 13 → **16**；
    /// 2026-10-22 用户又点「+ 号按钮还小，在大一些」⇒ 命中区 28 → **32**、图标 16 → **18**。
    /// ⚠️ 三颗纯图标键（+ / 联网 / 🎤）**同尺寸**（共用这两个常量）—— 用户这次只点了「+」，
    ///    但⛔ 别单独放大某一颗：一行里一颗大两颗小会读成「那颗是主按钮」，而这一行没有主次
    ///    （送信才是主入口，且它另有自己的尺寸）。
    /// 32 的两个来历：① 比图标大出一圈（命中区 ≥ 图标 + 12pt，鼠标/触摸都好点）；
    /// ② **≤ 控制行高 34 减 2** —— 与账号栏那条同构：命中区一旦超过行高余量，
    ///    整行会被顶高（不报错，只是间距悄悄变了）。
    static let composerIconHitSize: CGFloat = 32
    static let composerIconSize: CGFloat = 18

    /// 送信圆直径（参考图实测 32）
    static let composerSendSize: CGFloat = 30
    static let composerSendIconSize: CGFloat = 13
    /// 流式中的「停止」方块比箭头小一圈，四周留呼吸
    static let composerSendStopIconSize: CGFloat = 10
    /// 可发送时的底色 = 强调色（与用户气泡同一支色）
    static let composerSendEnabled = Color.accentColor
    /// **不可发送**时的底色：参考图里那颗浅灰圆 = 禁用态。
    /// ⚠️ 不能写成 `Color(nsColor: .quaternaryLabelColor)` 之类 —— 那在暗色下几乎看不见；
    ///    用 `primary` 降透明度，明暗两档都能自动成对（浅色=浅灰、深色=深灰）。
    static let composerSendDisabled: Color = Color.primary.opacity(0.14)
    /// 圆里的图形：**固定白**。⚠️ 与「用户气泡用固定白字」同一个理由：
    /// 底色在明暗两档都够深/够实，白图形始终看得见；换成 `.primary` 会在浅色下变黑箭头。
    static let composerSendGlyph: Color = .white

    /// 流式中的小转圈（参考图里送信按钮左边那个半圈环）
    static let composerSpinnerSize: CGFloat = 15
    static let composerSpinnerLineWidth: CGFloat = 1.5
    static let composerSpinnerColor = Color(nsColor: .tertiaryLabelColor)
    /// 转一圈的时长（秒）
    static let composerSpinnerPeriod: Double = 0.9

    /// 卡片下方那行免责声明
    static var composerFooterFontSize: CGFloat { 11 * uiScale }
    static let composerFooter = Color(nsColor: .tertiaryLabelColor)

    // 附件预览条（`+ → 截图提问 / 上传文件或图片` 选完之后，卡片顶部那排小卡）
    //
    // ⚠️ 真实附件**上限是 6**（`ChatModel.maxPendingAttachments`）—— 那一排不换行也不滚动，
    //    不设上限迟早会撑出卡片。要放开上限就得先把这一排改成可滚动的容器。

    static let composerAttachmentHeight: CGFloat = 24
    static let composerAttachmentPaddingH: CGFloat = 6
    static let composerAttachmentRadius: CGFloat = 6
    static let composerAttachmentSpacing: CGFloat = 6
    /// 缩略图边长（图片附件）；非图片附件走同一个尺寸的图标格
    static let composerAttachmentThumbSize: CGFloat = 18
    /// 名称字号：比控制行小一档（它是「回执」，不是操作）
    static var composerAttachmentFontSize: CGFloat { 11 * uiScale }
    /// 单个小卡的最大宽度 —— 长文件名靠它截断，否则一张卡就能吃掉半张卡片
    static let composerAttachmentMaxWidth: CGFloat = 150
    /// 小卡的底。
    /// 🔴 **不能用 `controlBackgroundColor`**：它和卡片的 `textBackgroundColor` 明暗两档
    ///    **都是同一个色**（浅色下都是 #FFFFFF、深色下都是 #1E1E1E）→ 小卡只剩一圈描边，
    ///    在渲染图上根本看不出是「一颗小卡」。改成同色系叠一层透明度，与 hover 底同一套口径。
    static func composerAttachmentBackground(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.10 : 0.05)
    }
    static let composerAttachmentBorder = Color(nsColor: .separatorColor)

    // MARK: - 引用（quote，2026-09-29）
    //
    // 同一个东西有**两处外观**，所以这里分成两组常量、别混用：
    // ① 输入卡片上方那条（`ComposerQuoteBar`）—— 坐在卡片里（`textBackgroundColor`），
    //    用「语义色 + 分隔线」，与附件小卡同一套；
    // ② 用户气泡里那条（`ChatRowView.userQuoteStrip`）—— 坐在**强调色底**上，
    //    那里**不能再取语义色**（浅色模式下 `Color.primary` 是黑的，压在蓝底上等于看不见），
    //    只能用「白色降透明」。
    // ⚠️ 两处的字号与圆角共用下面这几个数值（同一个东西不该有两种大小）。

    /// 引用条字号：比正文小一档（它是「被引用的那段」，不是本条正文）
    static var quoteFontSize: CGFloat { 12 * uiScale }
    /// 引用条最多显示几行（再多就把输入卡片顶高了，而它只是个「提醒你引用了什么」）
    static let quoteLineLimit: Int = 2
    static let quoteRadius: CGFloat = 6
    /// 图标与文字的距离
    static let quoteInnerSpacing: CGFloat = 5

    /// ① 输入卡片上方那条：底 = 附件小卡同一支（卡片内再叠一层，浅深两档）
    static func composerQuoteBackground(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.10 : 0.05)
    }
    static let composerQuoteBorder = Color(nsColor: .separatorColor)
    static let composerQuoteIcon = Color(nsColor: .secondaryLabelColor)
    static let composerQuoteText: Color = .primary

    /// ② 用户气泡里那条：气泡是**强调色底 + 白字**⇒ 这里只能白色降透明。
    static let userQuoteBackground: Color = Color.white.opacity(0.18)
    /// ② 的悬停态（2026-10-21：引用条可点之后的「这块能点」线索，跟着**行级** hover 走）。
    /// 只是把同一支白色提亮一档 —— ⛔ 别用彩色/阴影：它坐在强调色气泡里，
    /// 任何「另一支颜色」都会显得脏；默认态（非悬停）一字不改，旧验收图不回归。
    static let userQuoteBackgroundHovered: Color = Color.white.opacity(0.30)
    static let userQuoteText: Color = Color.white.opacity(0.95)
    static let userQuoteIcon: Color = Color.white.opacity(0.7)

    // MARK: - 录音浮层（豆包式「窗口底部蓝光」，2026-10-03 改版）
    //
    //  ## 它从哪来
    //  用户拿豆包语音输入的截图对标，要求「按屏幕最底部那套，样式 / 动画 / 颜色都改」。
    //  ⇒ 面板从「输入栏上方一块深色玻璃小卡片」改成「**铺满整宽、贴在窗口最底部**的蓝色光晕」，
    //    卡片底 / 圆角 / 描边 / 红点 / 「正在聆听」标题**全部去掉**（豆包那块没有这些）。
    //  ⚠️ 与 iOS 是**同一套实测值**（推导写在 `Aster/Sources/Voice/VoiceGlowView.swift` 的文件头）
    //     —— 两端看起来得是同一个东西，改一边记得看另一边。
    //
    //  🔴 与「拖拽落区」那一组的取色口径**刻意相反**：那组必须走语义色（它是盖在页面上的提示），
    //     这一组的颜色是**按参考图像素实测固定的**（深蓝 → 白的径向渐变 + 固定白字），
    //     ⛔ 不要为了「跟随明暗模式」换成 `Color.primary` 之类 —— 那会让蓝色光晕漏成灰的。

    /// 浮层高度（pt）。光晕在距底 300pt 处已彻底透明 ⇒ 310 保证顶边不会切出一条横线。
    static let voicePanelHeight: CGFloat = 310

    /// 蓝光椭圆的**圆心高于浮层底边**的距离（pt）
    static let voiceGlowCenterAboveBottom: CGFloat = 23
    /// 蓝光椭圆横向半径（pt）—— 参考机（414pt 宽屏）上的实测值
    static let voiceGlowRadiusX: CGFloat = 392
    /// 蓝光椭圆纵向半径（pt）
    static let voiceGlowRadiusY: CGFloat = 277
    /// `rx / 半宽` 的比值（参考机 392 / 207 = 1.894）。
    ///
    /// 🔴 **只按宽度放大 rx、ry 恒定**：Mac 窗口比手机宽得多（600…1400pt），若把整个椭圆等比放大，
    ///    纵向半径会跟着涨到几百 pt ⇒ 蓝光爬满大半个窗口；只放大 rx 得到的是「一条更平缓的弧」，
    ///    垂直尺度恒定、与参考图的观感一致。⛔ 别改成等比缩放。
    static let voiceGlowRadiusXToHalfWidth: CGFloat = 1.894

    /// 径向渐变的站点。
    ///
    /// 位置是**归一化的椭圆距离** `t`（0 = 圆心，1 = 椭圆边界）；色相取自参考图中轴的实测剖面
    /// （下 → 上：深蓝 → 浅蓝 → 近白）。
    ///
    /// 🔴 **收尾三段（t ≥ 0.71）刻意带 alpha、且逐段降到 0** —— 这是 2026-10-03 渲染台上
    ///    看图之后补的，⛔ 别"顺手"改回全不透明：
    ///    · 参考图是**浅色**界面截的，那一带的"白"其实是「蓝光淡到几乎没有、露出浅色底」的观感；
    ///    · 若照抄成不透明的近白（`alpha = 1`），**深色模式下就会在弧顶糊出一条刺眼的白墙**
    ///      （`voice_panel_dark` 那张图一眼可见）。
    ///    · 带 alpha 之后：浅色底下合成值几乎不变（0.71 处 212 vs 原来的 205 —— 肉眼看不出），
    ///      深色底下则自然淡入深底（150 → 164 → 167 → 99 → 底），不再有实白块。
    /// ⚠️ 最后一段是**全透明**（不是白）—— 录音时底下的会话内容要能透出来，参考图也是这么做的。
    /// ⚠️ iOS 侧 `VoiceGlowView.stops` 是**同一组数**（那边注释里有同样的来由），改一边记得改另一边。
    static let voiceGlowStops: [Gradient.Stop] = [
        .init(color: Color(red:  46/255, green: 105/255, blue: 234/255), location: 0.00),
        .init(color: Color(red:  52/255, green: 114/255, blue: 237/255), location: 0.20),
        .init(color: Color(red:  64/255, green: 130/255, blue: 239/255), location: 0.39),
        .init(color: Color(red:  92/255, green: 152/255, blue: 242/255), location: 0.50),
        .init(color: Color(red: 150/255, green: 195/255, blue: 247/255), location: 0.60),
        .init(color: Color(red: 205/255, green: 228/255, blue: 252/255).opacity(0.75), location: 0.71),
        .init(color: Color(red: 244/255, green: 249/255, blue: 254/255).opacity(0.62), location: 0.82),
        .init(color: Color(red: 251/255, green: 253/255, blue: 255/255).opacity(0.28), location: 0.93),
        .init(color: Color(red: 253/255, green: 254/255, blue: 255/255).opacity(0.00), location: 1.00),
    ]

    /// 蓝光**呼吸**：缩放 / 透明度的两个端点 + 单程时长（与 iOS 的 `CABasicAnimation` 同参）
    static let voiceGlowBreathScaleLow: CGFloat = 0.985
    static let voiceGlowBreathScaleHigh: CGFloat = 1.015
    static let voiceGlowBreathOpacityLow: Double = 0.90
    static let voiceGlowBreathDuration: Double = 2.6

    /// 竖排位置：各元素的**中心距浮层底边**的距离（pt）。
    /// 🔴 与 iOS `VoiceRecordingPanel` 的四个 `pinToBottom` 参数**逐字相同** —— 两端同款。
    /// ⚠️ 位置一律「显式高度 + bottom 偏移」钉死（`.padding(.bottom, 中心距底 − 高度/2)`），
    ///    ⛔ 别换成 `Spacer` / `centerY` 那类相对布局 —— 会被字体行高偷偷带偏，改字号时整排一起漂。
    static let voiceTimerCenterAboveBottom: CGFloat = 38
    static let voiceWaveformCenterAboveBottom: CGFloat = 74
    static let voiceHintCenterAboveBottom: CGFloat = 122
    static let voiceTranscriptCenterAboveBottom: CGFloat = 158

    /// 录音时长：等宽数字，否则秒数一跳整行宽度就变，看着在抖
    static var voiceTimerFontSize: CGFloat { 12 * uiScale }
    static let voiceTimerHeight: CGFloat = 16
    static let voiceTimerColor = Color.white.opacity(0.55)

    // ── 波形（与 iOS `VoiceWaveformView` 同参）────────────────────────────
    //
    // ☠️ 三条「与旧版 mac 相反」的结论，别再改回去（完整来由见 iOS 那个文件的头注释）：
    //  ① **条宽固定 3pt**，⛔ 不再「可用宽度 ÷ 条数」反推 —— 反推在 Mac 这种宽栏上会得到
    //     一排 22pt 的药丸（2026-09-24 的渲染图就是这个样子，当时靠 `voiceWaveformMaxBarWidth`
    //     封顶兜着；现在直接改成**带子居中、不拉伸**，那个上限常量随之删掉）。
    //  ② **没有对称包络** —— 实测参考图上峰值散落各处，不是「中间高两侧低」。
    //  ③ **基线可见**（6pt）—— 它就是那条「刻度线」的本体，音量只负责让它长高。

    /// 每根条的宽度（pt）。**固定值**，不随面板宽度变化。
    static let voiceWaveformBarWidth: CGFloat = 3
    /// 条间距（pt）
    static let voiceWaveformSpacing: CGFloat = 2
    /// 波形视图的高度（pt）—— 带子在其中围绕中轴上下对称生长
    static let voiceWaveformHeight: CGFloat = 60
    /// 基线条高（pt）—— **不能是 0**，否则不说话时整条带子会消失
    static let voiceWaveformMinBarHeight: CGFloat = 6
    /// 音量拉满时的条高（pt）
    static let voiceWaveformMaxBarHeight: CGFloat = 28
    static let voiceWaveformBarColor = Color.white.opacity(0.92)

    /// 实时识别文字（豆包没有这一行，是本 App 的功能件）
    static var voiceTranscriptFontSize: CGFloat { 14 * uiScale }
    static let voiceTranscriptHeight: CGFloat = 20
    static let voiceTranscriptColor: Color = .white
    /// 还没出字时的占位色（「请开始说话…」）
    static let voiceTranscriptPlaceholderColor = Color.white.opacity(0.58)

    /// 操作提示
    static var voiceHintFontSize: CGFloat { 15 * uiScale }
    static let voiceHintHeight: CGFloat = 20
    static let voiceHintColor = Color.white.opacity(0.78)
    /// 「正在整理文字…」那一态：还没结束但已经不是「在听」了，用弱一点的色
    static let voiceHintBusyColor = Color.white.opacity(0.55)

    /// 波形**两侧**的两颗圆形按钮（**Mac 独有**：iOS 是按住说话、取消靠「上移」手势；
    /// Mac 是点按式、没有滑动，必须给可见入口）。
    /// 左 = ✗ **结束**（放弃这次录音，`cancelVoice`）、右 = ✓ **结束并发送**（`finishVoice`）。
    ///
    /// 🔴 图标是 `xmark` / `checkmark`（用户点名「图标是 X / 对号」），⛔ 别换成文字。
    /// ⚠️ 颜色与这一组的取色口径一致（半透明白压在深蓝光晕上）——
    ///    ⛔ 别换成语义色，那会跟着明暗模式走、压在蓝光上会糊。
    static let voiceActionButtonSize: CGFloat = 36
    static let voiceActionIconSize: CGFloat = 15
    /// 圆钮与**波形带子端头**的间距（pt）
    static let voiceActionButtonGap: CGFloat = 18
    static let voiceActionButtonFill = Color.white.opacity(0.18)
    static let voiceActionButtonStroke = Color.white.opacity(0.30)
    static let voiceActionIconColor = Color.white.opacity(0.95)

    /// 波形**带子的总宽**（pt）= `条宽 × 条数 + 间距 × (条数 − 1)`（46 条 ⇒ 228pt）。
    ///
    /// 🔴 **单点**：`VoiceWaveform` 内部排版用它，本面板「在带子两侧给按钮让位」也用它
    /// （占位块的宽度必须与带子实际宽度一致，否则两颗按钮会离带子忽远忽近）。
    /// ⛔ 别在两处各算一遍 —— 条宽/间距/条数任何一个一调，两处就会对不上。
    static func voiceWaveformBandWidth(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return voiceWaveformBarWidth * CGFloat(count)
            + voiceWaveformSpacing * CGFloat(max(0, count - 1))
    }

    /// 录音中的 🎤（控制行那颗）——换成实心 + 红，与「点了会开始/结束」的语义对齐
    static let composerMicRecording = Color(nsColor: .systemRed)

    /// 联网搜索**开着**时控制行那颗地球的图标色（2026-10-21）。
    ///
    /// 用强调色而不是另一个写死色：这一行里「已激活」的语义已经由
    /// `selectionCircleOn` / `actionIcon` / `composerSendEnabled` 统一成强调色，
    /// 这里跟着走，⛔ 别再单独挑一个绿/蓝（深色模式下会与强调色打架）。
    /// 底色那层（`.opacity(0.16)`）由 `ComposerGlyphLabel.activeTint` 自己算，不要重复。
    static let composerWebSearchOn = Color.accentColor

    // MARK: - 拖拽落区（`DropFileOverlay`，2026-09-26 加）

    // 🔴 这一组**必须全部走语义色**（与录音板那组刻意相反）。
    //    它是「盖在会话页上的一层」—— 页面底是 `pageBackground`，正文是 `.primary`，
    //    明暗两档都跟着系统走。写死成深色的话，浅色模式下会变成「整页被一块黑糊住」。

    /// 遮罩的不透明度。
    /// 🔴 **刻意不盖满**（不是 1.0）：底下那层消息要**隐约还在** —— 用户正拖着一个文件悬在
    ///    窗口上，此刻还得看得见「我要放到哪个会话里」。全遮会把上下文擦掉，只剩一块牌子。
    static let dropScrimOpacity: CGFloat = 0.95
    /// 虚线框距页面边缘的留白。给足是因为它就是「整页都是落区」的那圈**可视承诺**。
    static let dropPanelMargin: CGFloat = 18
    static let dropPanelRadius: CGFloat = 16
    static let dropPanelBorderWidth: CGFloat = 2
    /// 虚线的「实/空」节奏。⚠️ 别写成实线：实线会被读成「一个卡片控件」，
    ///    虚线才是通行的「可以往这儿放」的语义。
    static let dropPanelDash: [CGFloat] = [9, 7]
    /// 落区内的淡底（强调色 + 极低透明度）—— 让那圈虚线**有面**，不只是个空心框。
    static func dropPanelFill(_ scheme: ColorScheme) -> Color {
        Color.accentColor.opacity(scheme == .dark ? 0.10 : 0.06)
    }
    static let dropPanelBorder = Color.accentColor

    static let dropIconSize: CGFloat = 38
    static var dropTitleFontSize: CGFloat { 17 * uiScale }
    /// 面板内各行（图标 / 标题 / 格式清单 / 上限说明）之间的间距
    static let dropPanelSpacing: CGFloat = 14
    /// 「图片 / 文本 / 其它」那几颗小标签
    static var dropChipFontSize: CGFloat { 11.5 * uiScale }
    static let dropChipPaddingH: CGFloat = 8
    static let dropChipPaddingV: CGFloat = 4
    static let dropChipRadius: CGFloat = 6
    static let dropChipSpacing: CGFloat = 6
    /// 标签的**固定宽度**：三颗字数不同，不固定右列就会参差不齐。
    /// 取值 = 「其它」那两个字 + 左右内边距，再留一点余量。
    static let dropChipWidth: CGFloat = 44
    /// 格式清单那一块的最大宽度。超过它就不再变宽 —— 否则在超宽窗口下
    /// 「图片 …」那一行会孤零零地贴到左边缘，整块牌子的居中感就散了。
    static let dropFormatListMaxWidth: CGFloat = 300
    /// 标签的文字（强调色，与虚线同色系）
    static let dropChipText = Color.accentColor
    /// 标签的底。⚠️ 与 `composerAttachmentBackground` 同一个来由：
    ///    `controlBackgroundColor` 与页面底在明暗两档下都是同一个值 ⇒ 标签会只剩文字没有面。
    static func dropChipBackground(_ scheme: ColorScheme) -> Color {
        Color.accentColor.opacity(scheme == .dark ? 0.20 : 0.12)
    }
    static let dropTitle: Color = .primary
    static let dropSubtitle = Color(nsColor: .secondaryLabelColor)
    static var dropSubtitleFontSize: CGFloat { 12 * uiScale }
    static let dropIconTint = Color.accentColor

    // MARK: - 行内媒体缩略图条（2026-09-28 加：AI 回复里的图片 / 视频横向排一条）
    //
    // `Views/MediaThumbStrip.swift` —— 一条横向滚动的**竖版 16:9** 格子。用户 2026-09-28 定的四件事：
    // ① **格子是竖的 16:9**（宽:高 = 9:16 —— 见下方 `mediaThumbWidth/Height` 的来由）；
    // ② **统一裁切**（不是「按图片自身比例」）；
    // ③ **单行横向滚动**（不换行、不网格）；
    // ④ **单张也跟组内一样大**（单张不再单独走「0.62 × 容器宽」那套大图口径）。
    // 🔴 **图片与视频各排各的一条**，绝不混在同一条里（分组判据在共享层
    // `AICore/AIChatMediaGrouping.swift`，iOS 的表格用同一份）。
    // ⚠️ 用户侧（自己发的图）**不走这条**：那边仍是一图一行、按真实比例（旧口径原样保留）。
    // ⚠️ **尺寸那四个数已下沉到业务层**（`AIChatRow.mediaStrip*`）—— 因为 iOS 也要同一组数，
    //    而 iOS 的行高量算在业务层。这一节里剩下的只是**转发**（见下面各条注释）。

    /// 格子**宽 / 高**：**转发共享口径**（`AIChatRow.mediaStripThumbWidth/Height` = 108 × 192，
    /// 竖版 9:16）。108 是「竖版」这一件事的落点（用户先要「16:9」，2026-09-28 二轮校正为
    /// 「**竖着的** 16:9」⇒ 宽:高 = 9:16），取 108 是因为它 × 16/9 = **192 整数**、不出半像素毛边。
    ///
    /// 🔴 **2026-09-28 起这两个数下沉到业务层**：iOS 侧也要用同一组数
    ///（`AIAssistantMediaStripCell` 的约束 + `AIChatRow.height(in:)` 的行高），
    /// 而行高量算在业务层 ⇒ 真值只能有一份，留在 MacTheme 里的只是**转发**。
    /// ⛔ 别在这里再写一个 108 / 192 —— 那正是「量的时候按 A、布局按 B」的老坑
    ///（与 `userImageDisplaySize` 同一课）。
    static let mediaThumbWidth: CGFloat = AIChatRow.mediaStripThumbWidth

    /// 格子高。🔴 **固定值，不跟容器宽走**：横向条一旦随窗口变宽，每格的 `pixel` 就都在变
    /// ⇒ `RowMediaImage` 的 `.task(id: pixel)` 会对每格各起一次重解码，而 9:16 `.fill` 裁切
    /// 让画面变化肉眼看不出来，纯属白烧 CPU。固定之后「窗口变宽 = 多露出几格」。
    static let mediaThumbHeight: CGFloat = AIChatRow.mediaStripThumbHeight

    /// 格子间距（转发共享口径）。8 与输入栏附件条同档（同一类「小图并排」的观感）。
    static let mediaThumbSpacing: CGFloat = AIChatRow.mediaStripSpacing

    /// 圆角。用气泡那一档（14）而不是附件条的 6：这些格子在**消息流**里，
    /// 与图片气泡属于同一族（旧行内媒体也是 `bubbleRadius`）。
    /// ⚠️ 它**不参与行高**，所以两端刻意允许不同（iOS 那个 cell 里写的是 14）——
    /// 只有「影响高度」的数才必须共享。
    static let mediaThumbCorner: CGFloat = bubbleRadius

    /// 视频格上那颗播放图标（转发共享口径；从横版格子的 30 收到 26 —— 竖格子只有 108 宽，
    /// 30 的图标会占掉近三成宽度）。⚠️ 它只是「这里能播」的提示，**不是命中区**（整格可点）。
    static let mediaThumbPlayIconSize: CGFloat = AIChatRow.mediaStripPlayIconSize

    // MARK: - 用户侧（自己发的图）尺寸缩放（2026-10-08）

    /// **Mac 端**用户图片整档缩放系数（0.62 × 0.25 ≈ 0.155×容器宽，iOS 不变 = 1）。
    ///
    /// 🔴 为什么是「传系数」而不是在 Mac 视图里乘一遍：
    /// 尺寸的**唯一真值**在共享层 `AIChatRow.userImageDisplaySize`（`height(in:)` 与渲染
    /// 都取它），⛔ 在视图层二次缩放就是本工程反复踩的「量的时候按 A、布局按 B」
    /// ⇒ 图片被裁或被留白撑开（`AIChatModels.swift` 那个函数的头注就是这条）。
    /// 正确姿势：把 `scale` 一路传进去，**行高与渲染吃同一个值**。
    ///
    /// ⚠️ 只作用于**用户侧**（自己发的那张，一图一行按真实比例）。
    /// 助手侧的横滑条走 `mediaStrip*` 那一套（竖版 9:16 固定高），两者互不影响。
    ///
    /// ⚠️ 调档史（2026-10-08 同一天三轮）：0.72 → 0.5 → **0.25**，
    ///    每轮都是「再减半」。容器宽 ~640 时约 **99pt 宽**。
    /// ⚠️ 下限：`AIChatRow.userImageDisplaySize` 里 `k = max(scale, 0.05)` 兜底，
    ///    但 0.25 已经进入「看不清内容、只能当缩略图点开」区间—— ⚠️ **别再往 0.15 以下压**。
    static let userImageScale: CGFloat = 0.25

    /// 用户多图横排时**格与格之间的间距**（2026-10-08）。
    ///
    /// 取 8 —— 与助手侧缩略图条、输入栏附件条**同一档**（`AIChatRow.mediaStripSpacing`）。
    /// 三者都是「小图并排」，间距不同档会让同屏里两种并排看起来像两种东西。
    /// ⚠️ 它**不参与任何高度计算**（格子高度由 `userImageDisplaySize` 给）⇒ 两端允许不同值，
    ///    但既然是同一类观感，就别分叉。
    static let userImageSpacing: CGFloat = AIChatRow.mediaStripSpacing

    // MARK: - 媒体预览（2026-09-27 加，样式照用户给的豆包 Mac 版截图）
    //
    // 点会话里的图片 / 视频封面 → **独立窗口**（`Views/MediaPreviewOverlay.swift` + `MediaPreviewWindow.swift`）：
    // 内容区是一片版面色底 + 居中的图、左下角一颗来源小胶囊；
    // 三颗按钮（缩小 / 放大 / 另存为）**在窗口标题栏上**（2026-09-28 起，见下面那节）。
    //
    // 🔴 底色**走语义色**（与下面「拖拽落区」那组同一口径），**不做固定深色遮罩**：
    //    参考图是浅色底、且它跟随系统外观（豆包自己的窗口底色也是白的）。
    //    固定深色会在浅色模式下变成「整页被一块黑糊住」。
    //    ⚠️ 别拿录音板那组（固定深色 HUD）来类比 —— 那是底部一小块浮层，方向相反。

    /// 浮层底色 = **页面背景**（与聊天区同一个常量，不另立一支色）
    static let mediaPreviewBackground = Color(nsColor: .windowBackgroundColor)
    /// 内容区四周留白（除顶栏那一行之外）
    static let mediaPreviewPadding: CGFloat = 24
    /// 顶栏距窗口边缘的留白
    static let mediaPreviewBarMargin: CGFloat = 12
    /// 内容区顶栏**占掉的高度**。它不是一条有底色的栏，只是一排悬浮按钮 ——
    /// 所以这个值只用来给内容区让位（`contentArea` 扣它），别拿去画线。
    /// ⚠️ **只有浮层形态扣它**：窗口形态那三颗在标题栏上、内容区没有顶栏 ⇒ `bar = 0`
    ///    （判断在 `MediaPreviewOverlay.contentArea`）。
    static let mediaPreviewBarHeight: CGFloat = mediaPreviewButtonSize + mediaPreviewBarMargin * 2

    /// 顶栏按钮的命中区边长。🔴 图标只有十几像素，不加命中区**点不中** ——
    /// 与账号栏那颗齿轮、输入栏那几颗同一个坑（`accountIconHitSize` / `composerIconHitSize`）。
    static let mediaPreviewButtonSize: CGFloat = 26
    static let mediaPreviewButtonRadius: CGFloat = 6
    static let mediaPreviewIconSize: CGFloat = 13
    static let mediaPreviewButtonSpacing: CGFloat = 4
    /// hover 底：与侧栏入口行 / 搜索结果行 / 输入栏文字块同一口径（能点的地方反馈一致）。
    /// ⚠️ 必须自己画 —— `.buttonStyle(.plain)` 在 macOS 上零指针反馈。
    static func mediaPreviewButtonHover(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.10 : 0.06)
    }
    /// 图标色：二级标签色（辅助控件，不该跟主要动作抢注意力 —— 与「回到底部」那颗同口径）
    static let mediaPreviewIcon = Color(nsColor: .secondaryLabelColor)
    /// 到边界时置灰（与操作栏那颗禁用色同色）
    static let mediaPreviewIconDisabled = Color(nsColor: .tertiaryLabelColor)

    /// 左下角那颗「来源」小胶囊（地球图标 + 主机名 / 文件名）
    static let mediaPreviewSourceHeight: CGFloat = 22
    /// 胶囊与内容之间要留的空隙（见 `mediaPreviewChipStripHeight`）
    static let mediaPreviewChipStripGap: CGFloat = 8
    /// 内容区底部**给来源胶囊留的那一条**（胶囊高 + 上面的空隙）。
    /// 🔴 必须留，而且**两处同源**：`contentArea` 扣它、`preferredContentSize` 补它。
    ///    2026-09-28 去掉内容区顶栏之后，`.fitIn` 的盒子会正好把图铺到底 ——
    ///    胶囊就压在图上（深色图上那行字直接看不清）。⚠️ 别指望「顶栏那条高度顺带顶出来的
    ///    余量」—— 那是巧合，这一版就撞上了。
    static let mediaPreviewChipStripHeight: CGFloat = mediaPreviewSourceHeight + mediaPreviewChipStripGap
    static let mediaPreviewSourcePaddingH: CGFloat = 8
    static let mediaPreviewSourceSpacing: CGFloat = 5
    static var mediaPreviewSourceFontSize: CGFloat { 11 * uiScale }
    /// 上限宽度：长域名/长文件名靠它截断（`.middle`，保住头尾）
    static let mediaPreviewSourceMaxWidth: CGFloat = 240
    static let mediaPreviewSourceText = Color(nsColor: .secondaryLabelColor)
    /// 胶囊的底。⚠️ 与 `composerAttachmentBackground` 同一个来由：
    /// `controlBackgroundColor` 与页面底在明暗两档下都是同一个值 ⇒ 胶囊会只剩文字没有面。
    static func mediaPreviewSourceBackground(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.10 : 0.05)
    }

    /// 另存为的结果提示（成功 / 失败都飘一句）。
    /// 🔴 失败**必须说出来**：沙盒拒写是**静默**的，不说用户会以为存好了。
    static var mediaPreviewNoticeFontSize: CGFloat { 11 * uiScale }
    static let mediaPreviewNoticeText = Color.accentColor

    /// 「缩小 / 放大」的档位（步进值，1.0 = 适应窗口）。
    ///
    /// ☠️ 别给缩放加动画：盒子连续变化会让 `RowMediaImage` 的 `pixel` 连续变化 ⇒
    ///    每个中间档都起一次 fetch + decode（那条取舍写在 `RowMediaImage` 的 `.task(id:)` 上）。
    ///    按钮是**离散**的，一次一下正好落在档位上。
    static let mediaPreviewZoomLevels: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3]
    /// 默认档 = 下标 3 = **1.0（适应窗口）** —— 参考图里打开就是「整张图刚好放下」。
    static let mediaPreviewZoomDefaultIndex = 3
    /// 缩放的**下限**：再小就没法看了（0.25 已经是「退到很远」）。
    static let mediaPreviewMinContentSide: CGFloat = 80

    // MARK: - 媒体预览窗口（2026-09-27：从整页浮层改成独立窗口）

    /// 开窗内容尺寸的**上限**。超过这个尺寸就不再跟着媒体长大了 ——
    /// 一张 4K 截图按天然尺寸开窗会大过屏幕，而这个窗口是「看一眼」用的。
    /// ⚠️ 三个尺寸都**不含标题栏**（`NSWindow.contentRect` 的口径）。
    static let mediaPreviewWindowMaxContentSize = CGSize(width: 1100, height: 760)

    /// 开窗内容尺寸的**下限**。再小就没法看图了。
    /// ⚠️ 2026-09-28 起三颗按钮在**标题栏**上 ⇒ 这个下限**与按钮无关**
    ///    （旧注释写的是「再小顶栏那三颗就摆不开了」，那时按钮在内容区）。
    static let mediaPreviewWindowMinContentSize = CGSize(width: 420, height: 320)

    /// 量不到媒体天然尺寸时（远程 URL / 视频）的兜底内容尺寸。
    static let mediaPreviewWindowDefaultContentSize = CGSize(width: 1000, height: 700)

    // MARK: - 预览窗**标题栏**那一组（2026-09-28：从内容区搬上来）
    //
    // 用户看过成品后要求「缩放和下载按钮放到交通灯旁边、标题栏上」——
    // 那是 macOS 的原生位置（`NSTitlebarAccessoryViewController` + `layoutAttribute = .left`）。
    // 装上之后**内容区顶栏整条不画**（`MediaPreviewOverlay.showsToolbar = false`），
    // 否则同一批按钮会出现两次。
    //
    // ⚠️ 三颗按钮的**命中区 / 图标 / hover 底不另立一套** —— 用的还是上面那组
    //    `mediaPreviewButtonSize` / `mediaPreviewIconSize` / `mediaPreviewButtonHover`，
    //    只多一个外圈留白。同一批图标在两个位置长得不一样才是问题。

    /// 标题栏那组按钮**左右**的留白（也是宽度的来源之一，见 `mediaPreviewTitlebarWidth`）
    static let mediaPreviewTitlebarPaddingH: CGFloat = 8
    /// 标题栏那组按钮之间的间距（比内容区那排略紧：标题栏左右都挨着别的东西）
    static let mediaPreviewTitlebarSpacing: CGFloat = 4

    /// 标题栏附件的**宽度**。
    /// ☠️ 必须自己算：`NSTitlebarAccessoryViewController` 的左侧附件**高度由窗口填满**，
    ///    **宽**才是我们说了算的那个方向（AppKit 头文件原话：another direction
    ///    "will automatically be filled to the maximum size"）。
    ///    ⇒ 不给宽度 = 附件宽度 0 = 四颗按钮一个都看不见。
    /// ⚠️ 别改用 `NSHostingView.fittingSize` 去量：根视图里有 `maxHeight: .infinity`，
    ///    那个数在这种约束下不可靠；从按钮尺寸推是确定的。
    /// 🔴 2026-10-09 加旋转 ⇒ 从 3 颗变**4 颗**（缩小 / 放大 / 旋转 / 另存为）。
    /// ⚠️ 这里的 `* 4` 与 `spacing * 3` 是**耦合**的：加/删一颗按钮时两处必须一起改，
    ///    只改一处 ⇒ 附件宽度不够、最后一颗被截掉。
    ///    而这个错**离屏图照不出来**（离屏里根本没有标题栏，只有 `render_mac_ui.sh preview`
    ///    的真窗口截图能发现）—— 与上面那条「不给宽度三颗都看不见」同一个坑的两种表现。
    static var mediaPreviewTitlebarWidth: CGFloat {
        mediaPreviewButtonSize * 4 + mediaPreviewTitlebarSpacing * 3 + mediaPreviewTitlebarPaddingH * 2
    }

    // MARK: - 网页面板（2026-09-30 加）
    //
    // 点助手回复里的网址 → **会话页右侧滑出**一块面板显示网页（`Views/WebPageView.swift`）。
    // 形态照用户给的豆包 Mac 版截图（「点了在会话页面右侧又出现」）。
    // ⚠️ 「面板而不是独立窗口」是用户**返工纠正**过的（第一版真开了个 NSWindow）——
    //    来由与「为什么不是三栏 split view」见 `WebPageView.swift` 文件头 / `RootView`。
    //
    // 🔴 与「媒体预览」那组同一口径：**底色走语义色**，不写死浅色/深色。
    //    顶栏与地址栏两块面都必须**明暗两档各取一个值** —— 直接拿
    //    `controlBackgroundColor` 会与页面底撞成同一个色（那组注释里记过这个坑）。

    /// 顶栏那条的高度（不含下面那条进度线）
    static let webPageBarHeight: CGFloat = 36
    /// 顶栏左右留白 / 控件间距
    static let webPageToolbarPaddingH: CGFloat = 10
    static let webPageToolbarSpacing: CGFloat = 6
    /// 图标按钮的命中区边长（图标只有十几像素，不加命中区点不中 —— 与预览窗那三颗同坑）
    static let webPageToolbarButtonSize: CGFloat = 26
    static let webPageToolbarIconSize: CGFloat = 12
    /// 地址栏那行字。⚠️ 比正文小一号：它是**工具**，与消息里的正文不是一回事
    static var webPageAddressFontSize: CGFloat { 12 * uiScale }

    /// 顶栏底。⚠️ 两档不同：`Color.primary.opacity(…)` 在浅色下是极浅的灰、
    /// 暗色下是比页面底略亮的一层 —— 这一条正是「一条栏」与「一片空白」的差别。
    /// ⚠️ **刻意压得很淡**（比地址栏浅两档）：macOS 的工具栏本来就是「同色 + 一条分隔线」，
    ///    两块面都做重的话，整条栏会像一截横插进来的色带，与窗口其余部分脱节。
    static func webPageToolbarBackground(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.05 : 0.03)
    }

    /// 地址栏那条输入框形状的底。同样两档不同，且**必须比顶栏更深一档** ——
    /// 两者同值时地址栏会「融进栏里」，看起来只是一行灰字（而它其实是可选中、可复制的）。
    /// ⚠️ 这一档是**看图调出来的**（`webpage_bar_*` 那几张）：0.05 与 0.09 并排时
    ///    几乎分不出两块面，得拉到 0.03 / 0.11 才有「一块输入框」的样子。
    static func webPageAddressBackground(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.18 : 0.11)
    }

    static let webPageToolbarBorder = Color(nsColor: .separatorColor)
    static let webPageToolbarIcon = Color(nsColor: .secondaryLabelColor)
    static let webPageToolbarIconDisabled = Color(nsColor: .tertiaryLabelColor)
    static let webPageAddressText = Color(nsColor: .secondaryLabelColor)

    /// 加载进度线：贴着顶栏下沿的一条细线。
    /// ⚠️ 走强调色 —— 与 App 里其它「正在进行」的指示同一支色。
    static let webPageProgressHeight: CGFloat = 2
    static let webPageProgressTint = Color.accentColor

    /// 错误页（盖住内容区的那一块）
    static let webPageErrorSpacing: CGFloat = 10
    static let webPageErrorIconSize: CGFloat = 26
    static var webPageErrorFontSize: CGFloat { 13 * uiScale }
    static var webPageErrorDetailFontSize: CGFloat { 11 * uiScale }
    static let webPageErrorPadding: CGFloat = 22
    /// 上限宽度：一句话太长时不让它横贯整个窗口（居中一段窄卡片更好读）
    static let webPageErrorMaxWidth: CGFloat = 380

    /// 错误页那两颗按钮（重试 / 用浏览器打开）。
    /// ⚠️ 字号与内边距**另立一份**、不复用选择栏那组（`selectionBarButton*`）：
    ///    那组的语义是「选择模式底部那一条栏里的按钮」，将来它要变大变小，
    ///    不该连带把网页错误页这两颗也拽着动。
    /// 🔴 这两颗必须**自绘底块**（`.buttonStyle(.plain)`）—— 系统样式按钮在离屏渲染里
    ///    只有「黄条 + ⊘」，验收图会因此什么都照不到（理由写在 `WebPageErrorView.errorButton`）。
    static var webPageErrorButtonFontSize: CGFloat { 12 * uiScale }
    static let webPageErrorButtonPaddingH: CGFloat = 12
    static let webPageErrorButtonPaddingV: CGFloat = 4
    static let webPageErrorButtonRadius: CGFloat = 6
    static func webPageErrorButtonBackground(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.14 : 0.09)
    }

    // ── 起始页（2026-10-06 二改：从「大图标 + 说明 + 输入框 + 两颗按钮」
    //    改成**一列「图标 + 文字」的胶囊行**，照用户给的图）──────────────────
    //
    // 🔴 **这一组里刻意没有颜色项**，两处都是复用：
    //   · 行底**不填色**（常态透出 `pageBackground`）—— 浅色下它就是**纯白**，
    //     再填 `controlBackgroundColor` 也还是白 ⇒ 只会多一层看不见的底。
    //     与卡片同口径：**只靠描边**从页面分出来（2026-10-04 与用户确认过）。
    //   · hover 复用 `quickEntryHoverBackground`（侧栏入口行那支）——
    //     工程口径是「能点的行反馈必须一致」，⛔ 别为起始页另立一支差不多的灰。
    /// 行间距
    static let webPageStartRowSpacing: CGFloat = 10
    /// 整列相对面板两侧的留白。⚠️ 与下面那个「行内左右留白」**语义不同**
    /// （那个是图标到行左缘），两者数值撞在一起纯属巧合 ⇒ 分开写，免得改一个带歪另一个。
    static let webPageStartColumnInset: CGFloat = 16
    /// 一行内部的左右留白（图标到行左缘）
    static let webPageStartRowPaddingH: CGFloat = 16
    /// 一行内部的上下留白。⚠️ 与上面的字号一起决定行高（≈ 41pt）
    static let webPageStartRowPaddingV: CGFloat = 12
    /// 🔴 行圆角 = **半高** ⇒ 整条胶囊（图里就是这种形状）。
    ///    ⛔ 别改成 8 / 12 那种圆角矩形：那样顶多像「一颗卡片」，不像图里那一列。
    static let webPageStartRowRadius: CGFloat = 20
    /// 图标到文字的距离
    static let webPageStartIconSpacing: CGFloat = 10
    /// 图标列的**定宽**。⚠️ 三个图标的实际宽窄差得多（放大镜 / 文稿 / 文件夹），
    ///   不定宽的话每行文字的左缘会差几个点，几行并排一眼就看得出没对齐。
    static let webPageStartIconWidth: CGFloat = 18
    static var webPageStartIconFontSize: CGFloat { 14 * uiScale }
    static var webPageStartFontSize: CGFloat { 13 * uiScale }
    /// 整列的宽度上限。⚠️ 面板能被拖到 700 宽，而「一行胶囊横贯 700pt」很难看
    /// ⇒ 超过这个宽度就居中定格（窄面板时不受影响，它就是可用宽 - 两侧留白）。
    static let webPageStartMaxWidth: CGFloat = 420
    // ⚠️ 2026-10-07 删除：`webPageStartPlaceholderOpacity`（原 0.55）。
    //    ⛔ 别挂回来：它只服务起始页那个已删掉的「打开终端」**占位行**
    //    （`.disabled` 管得了点击、管不了自绘观感，只能手动压一档透明度）。
    //    现在起始页**每一行都是真能点的** ⇒ 压暗等于骗用户。

    // ── 目录树（2026-10-07 加：面板第三档内容，见 `FolderTreePane.swift`）──────
    //
    // 用户口径：「打开文件夹的功能 可以做成图中这样目录树显示吗？」
    // 🔴 颜色项刻意**只有两支**（hover 复用 `quickEntryHoverBackground`、图标复用
    //    `webPageToolbarIcon`）—— 与起始页同一条理由：「能点的行」反馈必须一致，
    //    行底常态不填色（浅色下页面底本来就是纯白，再填一层也还是白）。
    /// 一行的高度（固定）—— 树是清单，行高统一，不像起始页那样靠内衬撑出来。
    static let treeRowHeight: CGFloat = 24
    /// 搜索结果行高（多一行淡的小字「它在哪个目录」）
    static let treeSearchRowHeight: CGFloat = 38
    /// 每往里一层缩进多少
    static let treeIndentPerLevel: CGFloat = 14
    /// ☠️ chevron 的**定宽**（文件行也占这一格，只是不可见）⇒ 同层文字左缘严格对齐。
    static let treeChevronWidth: CGFloat = 12
    /// 图标列的定宽（同理：不同 SF Symbol 的实际宽窄差得多）
    static let treeIconWidth: CGFloat = 16
    static let treeIconSize: CGFloat = 12
    static let treeIconSpacing: CGFloat = 6
    static var treeFontSize: CGFloat { 13 * uiScale }
    static let treePaddingH: CGFloat = 10
    /// 列表上下留白
    static let treeListPaddingV: CGFloat = 6
    /// 行 hover 底的圆角 / 左右内缩（不内缩的话高亮条会顶到面板两边）
    static let treeRowRadius: CGFloat = 5
    static let treeChromeInset: CGFloat = 5
    /// 搜索框
    static let treeSearchBarHeight: CGFloat = 26
    static let treeSearchBarRadius: CGFloat = 6
    /// 搜索框那圈底色相对栏位的上下内缩
    static let treeSearchBarInset: CGFloat = 6
    static let treeSearchPaddingH: CGFloat = 8
    static var treeSearchFontSize: CGFloat { 12 * uiScale }
    /// ☠️ 递归搜索的两条**上限**（硬要求：`node_modules` / `~/` 不设上限会读几万个文件）。
    ///    深度按「从根往里几层」算，条数到了就停。
    static let treeSearchMaxDepth = 6
    static let treeSearchMaxResults = 300

    // ── 代码视图（2026-10-07 加：面板第四档内容，见 `CodePane.swift`）─────────
    //
    // 🔴 用户 2026-10-07 拍板：高亮走**自写词法器**（不引 highlight.js / 不借 WKWebView）
    //    ⇒ 颜色**必须**在 MacTheme 这一处分叉（本工程铁律：颜色只有这一处来源）。
    // ☠️ 语法色只能**硬编码 RGB** —— 系统没有「语法色」这套语义色（`.labelColor` 那一族
    //    是给文本/控件的，拿它上色等于没上色）。所以这里**是本工程唯一允许硬编码颜色**
    //    的地方，⛔ 别在别处再抄一份。
    //
    // 🔴🔴 下面这一组**全部标 `nonisolated`**（2026-10-15，Xcode 27 起不标就报 11 条
    //    main actor 隔离警告）：`CodeLoader` / `CodeAssembler` 是**故意**的
    //    `nonisolated static func`（读文件 / 解码 / 高亮全在全局执行器上跑，见
    //    `CodePane.swift` 文件头 ②），它们要取这几个常量与配色函数。
    //    这里全是纯常量 / 纯函数（无共享可变状态、不读 Observation 版本号）⇒
    //    标 `nonisolated` 零风险，且 MainActor 侧照调不误。
    static var codeFontSize: CGFloat { 12 * uiScale }
    static let codeLineSpacing: CGFloat = 3
    static let codePadding: CGFloat = 12
    static var codeNoteFontSize: CGFloat { 11 * uiScale }
    /// 行号列的颜色（与工具栏禁用图标同支，够淡但不至于看不见）
    nonisolated static let codeLineNumber = Color(nsColor: .tertiaryLabelColor)
    /// ☠️ 三档体量（见 `CodeLoader.load`）：
    ///    ≤ `codeHighlightMaxBytes` ⇒ 高亮；≤ `codeReadMaxBytes` ⇒ 只给纯文本 + 行号；
    ///    再大 ⇒ 不读，直接劝退并给「用系统预览打开」的出路。
    nonisolated static let codeHighlightMaxBytes = 200 * 1024
    nonisolated static let codeReadMaxBytes = 2 * 1024 * 1024
    /// 最多画多少行（再多就没意义了，而且会拖垮一次性排版）
    nonisolated static let codeMaxLines = 20000

    nonisolated static func codeKeyword(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 1.00, green: 0.48, blue: 0.70)
                        : Color(red: 0.68, green: 0.14, blue: 0.64)
    }
    nonisolated static func codeType(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.42, green: 0.90, blue: 0.88)
                        : Color(red: 0.03, green: 0.31, blue: 0.53)
    }
    nonisolated static func codeString(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.99, green: 0.42, blue: 0.36)
                        : Color(red: 0.77, green: 0.10, blue: 0.09)
    }
    nonisolated static func codeComment(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.50, green: 0.56, blue: 0.60)
                        : Color(red: 0.36, green: 0.42, blue: 0.47)
    }
    nonisolated static func codeNumber(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.82, green: 0.75, blue: 0.41)
                        : Color(red: 0.11, green: 0.00, blue: 0.81)
    }
    nonisolated static func codePreprocessor(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 1.00, green: 0.63, blue: 0.31)
                        : Color(red: 0.47, green: 0.29, blue: 0.16)
    }

    // ── 标签行（2026-09-30 当晚加；当晚二改：**标签 + ＋ 独占面板第一行**，
    //    并被**顶进窗口顶栏那一条带子里**）──────────────────────────────────
    //
    // 用户当晚纠正过三次：
    // ① 「把 tab 与加号按钮添加到 web 页面的导航上」⇒ 先并进了导航条那一行；
    // ② 用户贴图圈出**窗口最上面那条空带子**（只有侧栏开合按钮、其余空着）说
    //    「我说的是图中画线的这个导航，把 tab 和加号移动上去」⇒ 又用「负 padding
    //    + 隐藏工具栏背景」把标签行顶进了那条带 —— **结果点不动**；
    // ③ 用户报「加号点击不动」⇒ 真窗口 hitTest 探针查明：那条带归窗口工具栏
    //    （`NSToolbarView`），**画进去的内容永远收不到点击**。
    // ⇒ 定案（③ 改）：标签条 = **inspector 列自己的工具栏项**
    //    （`RootView` 里 `.toolbar { ToolbarItem(id: "webPageTabs", …) }`）——
    //    系统把它放进面板上方那格工具栏区：位置就是「最上面那条带」且点得着。
    // ④ 2026-10-02：用户报「标签增多后会溢出到会话页面的导航上」⇒ 它是**窗口工具栏项**，
    //    报多宽就占多宽 ⇒ 加宽上限（= 面板宽 − 余量）+ 条内横向滚动。口径见下面那两条常量。

    /// 单个标签胶囊的高度。比窗口工具栏矮一档 —— 它是「栏里的一颗控件」，
    /// 撑满栏高会把它读成一条独立的栏。
    static let webPageTabPillHeight: CGFloat = 22
    /// 标签标题的**最大**宽度。
    ///
    /// ⚠️ 2026-10-04：与它配对的 `MinWidth` 兄弟常量已随 SwiftUI 离屏标签条一起删除
    ///    （那条「不让标题被压成 1 个字」的保险现在由 AppKit 桥自己保证）。
    /// 标签独占一行之后，一个标题可以给得比「并进导航条」那版宽 ——
    /// 那一行里只有胶囊和「＋」，地址栏在**下面一行**，不再跟标签抢宽度。
    static let webPageTabItemMaxWidth: CGFloat = 110
    /// 标签条**总宽上限**的口径（2026-10-02，用户报「标签增多后会溢出到会话页面的导航上」）。
    ///
    /// 🔴 为什么必须有上限：标签条是**窗口工具栏项**，宽度随标签数一路增长 ——
    ///    涨过头就把整条工具栏撑爆（系统只能开始把项往外挤），表现就是标签
    ///    **溢到会话页面那段导航上**。⇒ 上限 = **面板实际列宽** − 这个余量。
    /// ⚠️「面板实际列宽」由面板自己量（`WebPageModel.panelWidthRelay`），
    ///    ⛔ **不是** `webPagePanelWidth(windowWidth:)` 那个理想值 —— 窗口不够宽时
    ///    `.inspector` 会把理想值压到最小列宽（实测 1120 窗口里算 500、实际 342）。
    /// ⚠️ 上限**不是用来裁标签的**：`WebPageTabsBar` 内部是**横向滚动**，
    ///    第 N 个标签滚过去照样点得到。⛔ 别退回「设上限 + 裁掉」——
    ///    2026-10-02 实测过：2 个标签时上限把第 2 个整个裁掉，用户开了却看不见。
    static let webPageTabStripSideInset: CGFloat = 28
    /// 标签条的**最小宽度**：窗口 / 面板窄到极点时也别硬撑（硬撑就是溢出）。
    static let webPageTabStripMinWidth: CGFloat = 120

    /// **导航条**（标签下面那一行）宽度自适应的阈值：低于它就撤掉
    /// 「缩放簇 + 用浏览器打开」（缩放仍有 ⌘+ / ⌘- / ⌘0 三颗快捷键；出路在错误页也有一份）。
    ///
    /// ⚠️ 从 600 收到 440（2026-09-30 二改）：标签搬走之后，这一行只剩
    ///    「← → ⟳ · 地址栏 · 缩放簇 · 出路 · 关闭」，实测 **450 就能装下**。
    ///    阈值留在 600 的话，真机上面板（典型 580~760 里偏窄的那半）会白白丢掉缩放簇。
    static let webPageToolbarCompactWidth: CGFloat = 440
    // ⚠️ 2026-10-04 删除：`webPageTabTitle` 与 `webPageTabActiveBackground(_:)`
    //    —— 只服务于已删的 SwiftUI 离屏标签条（AppKit 桥 `WebPageTabsBar` 用 NSColor 自己取）。

    // ── 缩放（2026-09-30 当晚加）────────────────────────────────────────────
    static let webPageZoomMin: Double = 0.1
    static let webPageZoomMax: Double = 3.0
    static let webPageZoomStep: Double = 0.1

    // ── 桌面 UA（2026-09-30 当晚加）：补齐 Version/Safari 尾巴，避免站点回降级桩页 ──
    static let webPageUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// 网页面板的列宽（`.inspector` 的 `inspectorColumnWidth`）。
    ///
    /// 🔴 **当前口径（2026-10-08）：面板与会话区等宽**，算法见下面
    ///    `webPagePanelHalfWidth` —— ⛔ 别再写「面板占窗口 0.5、给聊天区留 620」那套
    ///    （`webPagePanelFollowFraction` / `webPagePanelChatReserve` / 旧的 `webPagePanelWidth`
    ///    已随之删除，留着必然被误用）。
    ///
    /// ⚠️ **下面那条实测仍然成立，是本段所有口径的前提**：`.inspector` 打开时
    ///   **只认 `min`、忽略 `ideal`**（2026-10-04 真窗口实测两个数据点：
    ///   min 340/ideal 480 → 实际 341；min 620/ideal 660 → 实际 621）。
    ///   ⇒ 想让面板多宽，**必须写进 `min`**。
    ///
    /// ⚠️ `webPagePanelMinWidth` 也是**算法里的下限**（不只是给 `.inspector` 的），
    ///   窗口窄到 `侧栏 + 2×340` 以下时保它（会话区窄比看不见好）。
    static let webPagePanelMinWidth: CGFloat = 340
    static let webPagePanelIdealWidth: CGFloat = 480
    /// 动态宽度上限（面板最宽不超过这个值）。
    static let webPagePanelMaxWidth: CGFloat = 760

    /// 侧栏列宽（`RootView` 的 `navigationSplitViewColumnWidth` 的 `ideal`）。
    /// 🔴 算面板宽要用**它**做减数 —— 50/50 是「**剩下的**一分为二」，不是「窗口一分为二」。
    static let sidebarIdealWidth: CGFloat = 260

    /// 🔴 面板与会话区**等宽**（2026-10-08 用户口径：「右侧页面和会话页面要一样宽」）。
    ///
    /// 口径：`面板宽 = (窗口宽 − 侧栏宽) / 2`。
    /// ⚠️ 减数是**侧栏宽**不是 0 —— 三栏是「侧栏 | 会话 | 面板」，
    ///    拿窗口宽直接除二会把侧栏那份也算进分母里，面板会比会话区宽 ~130pt。
    ///
    /// ☠️ **`min` 与 `ideal` 只能给 `min`**：`.inspector` 打开时系统忽略 `ideal`
    ///   （2026-10-04 两个实测数据点，见本段开头那段实测记录）。
    ///   ⇒ 这段算出来的值必须喂给 `inspectorColumnWidth(min:)`，写进 `ideal` 是空转。
    ///
    /// ⚠️ 下限 `webPagePanelMinWidth`(340) 仍然生效：窗口窄到 2×340 + 侧栏 = 940 以下时
    ///    面板压不下去，硬撑会把会话区挤没，此时**保面板下限**（会话区窄比看不见好）。
    /// ⚠️ 上限 760（`webPagePanelMaxWidth`）**故意抬到 1100**：50/50 在宽屏下会很宽
    ///    （窗口 1540 → 面板 640），但若仍卡 760，深色长文/代码块那侧就不够看了。
    static let webPagePanelEvenWidthMax: CGFloat = 1100

    /// 面板与会话区等宽的**唯一算法**（喂给 `inspectorColumnWidth(min:)`）。
    ///
    /// - Parameters:
    ///   - windowWidth: 窗口内容区宽（`NSWindow.frame.width`）。
    ///   - sidebarWidth: 侧栏实际宽（缺省 `sidebarIdealWidth` —— 侧栏收起时按 0 算更准，
    ///                   但那会让面板突然变宽，体验上更差，故**统一按理想宽**减）。
    static func webPagePanelHalfWidth(windowWidth w: CGFloat,
                                      sidebarWidth s: CGFloat = sidebarIdealWidth) -> CGFloat {
        guard w > 0 else { return webPagePanelIdealWidth }
        let rest = max(w - s, 0)          // 会话区 + 面板合起来能分的那份
        let half = rest / 2
        return min(max(half, webPagePanelMinWidth), webPagePanelEvenWidthMax)
    }

    // MARK: - 设置窗口（2026-10-14 加）
    //
    //  ⌘, 打开的那个独立设置窗（`MacSettingsView`）：**左侧分组菜单 + 右侧内容区**，
    //  形态照用户给的参考图。它是本 App 的第二个「一整页」级的容器（第一个是主窗口）。
    //
    //  🔴 三条口径，改之前先看：
    //  ① **左侧菜单不能用 `List`** —— `List` 是 AppKit 桥接容器，离屏渲染里只会被整块画成
    //     「黄条 + ⊘」（技能 `ios-swiftui-headless-render`），整台渲染台对这一页就瞎了。
    //     所以侧栏是 `VStack` + 自绘行（与 `SidebarQuickEntries` 同一套手法）。
    //  ② **右侧内容也不许用 `ScrollView`**：离屏渲染画不出滚动内容 —— 那一档图会是**一片空白**
    //     （不是「看着不对」，是「什么都没有」）。我们的设置项一共没几行，固定版面就够。
    //  ③ 颜色一律取语义色（与 `pageBackground` / `cardBackground` 同一套）——
    //     ⛔ 别为这一页写死浅灰 / 纯白，暗色模式下会直接看不见。

    /// 设置窗的**内容尺寸**（不含标题栏）。它同时是 `Settings` 场景开出来那扇窗的大小。
    /// ⚠️ 左栏 200 + 分隔线 1 + 右侧 559 —— 右侧这个宽度是照着「模型」页（原 `panelSize` 520
    ///    加上两侧留白）定的，⛔ 别再收到 700 以下：那一页的行尾有三颗动作按钮。
    static let settingsWindowSize = CGSize(width: 760, height: 520)

    /// 左栏宽。⚠️ 比主窗口侧栏（260）窄一档：这一栏里只有五个设置项，260 会显得空。
    static let settingsSidebarWidth: CGFloat = 200
    static let settingsSidebarPaddingH: CGFloat = 10
    static let settingsSidebarPaddingV: CGFloat = 12
    /// 分组标题（「设置 / 功能 / 关于」）字号 —— 与主窗口侧栏的 `sidebarSectionTitleFontSize` 同档
    static var settingsGroupTitleFontSize: CGFloat { 11 * uiScale }
    /// 分组之间的间距（组标题自己还带上下留白，见 `settingsGroupTitlePaddingTop/Bottom`）
    static let settingsGroupSpacing: CGFloat = 14
    static let settingsGroupTitlePaddingTop: CGFloat = 8
    static let settingsGroupTitlePaddingBottom: CGFloat = 2

    /// 一条导航项的行高 / 圆角 / 组内间距。30 是 macOS 设置窗（系统设置 / Xcode）的常规密度。
    static let settingsNavRowHeight: CGFloat = 30
    static let settingsNavRowRadius: CGFloat = 6
    static let settingsNavRowSpacing: CGFloat = 2
    /// 图标列的**定宽**：不做的话每一行文字的左缘会跟着各自图标的宽窄漂（与侧栏入口同一个坑）
    static let settingsNavIconWidth: CGFloat = 18
    static let settingsNavIconSize: CGFloat = 13
    static var settingsNavFontSize: CGFloat { 13 * uiScale }

    /// 选中态的底。⚠️ 明暗两档不同（与 `quickEntryHoverBackground` 同一套口径）：
    ///    暗色底更深，照搬浅色的比例会糊成一片看不出来。
    static func settingsNavSelection(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.16 : 0.10)
    }
    /// 左栏底色。浅色 = 系统的「窗口背景」（`#ECECEC`），深色 = **比页面底再暗一档**（`#2A2A2A`）。
    ///
    /// 🔴 为什么要写成一个**自定义动态色**、而不是直接用 `windowBackgroundColor`：
    ///    那个系统色在暗色下的值是 `#323232` —— 与右侧内容区用的 `pageBackground`
    ///    （同样 `#323232`）**一模一样** ⇒ 整扇窗在暗色下糊成一整片，两栏只剩一条分隔线，
    ///    macOS 侧栏「比内容区深一档」的那个关系**当场没了**（渲染图 `settings_window_model_dark`
    ///    一眼可辨）。⇒ 暗色档取 `#2A2A2A`（比 `#323232` 深一档，与浅色档的对比关系对齐）。
    /// ⚠️ 浅色档用 `#ECECEC`：就是 `windowBackgroundColor` 的浅色值，**与改动前逐像素相同**
    ///    （只动深色，是本工程一贯的口径）。
    /// ⚠️ 写法照 `pageBackground`：`NSColor(name:dynamicProvider:)` + `bestMatch(from:)`
    ///    （⛔ 别用 `appearance.name ==` 直接比：外观还有 accessories 那些变体会漏）。
    static let settingsSidebarBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x2A / 255.0, green: 0x2A / 255.0, blue: 0x2A / 255.0, alpha: 1)
            : NSColor(srgbRed: 0xEC / 255.0, green: 0xEC / 255.0, blue: 0xEC / 255.0, alpha: 1)
    })
    /// 左栏与右侧之间的那条 1pt 竖线（`separatorColor` 带 alpha，是一条低对比的线 —— 正是想要的）
    static let settingsSidebarBorder = Color(nsColor: .separatorColor)

    /// 右侧内容区的四周留白
    static let settingsContentPadding: CGFloat = 20
    /// 卡片（右侧每一块内容都装在一张卡片里，照参考图）
    static let settingsCardRadius: CGFloat = 10
    static let settingsCardPadding: CGFloat = 16
    /// ⚠️ 与 `cardBackground` 同源：浅色下页面底本来就是白的 ⇒ **卡片只靠描边分出来**
    ///    （2026-10-04 与用户确认过的口径，⛔ 别为此把卡片刷深一档）。
    static let settingsCardBackground = Color(nsColor: .textBackgroundColor)
    static let settingsCardBorder = Color(nsColor: .separatorColor)
    /// 卡片内「标题 + 说明」与下面选项之间的距离
    static let settingsCardHeaderSpacing: CGFloat = 10
    /// 一条选项行的上下内边距（行高由内容 + 它撑出来，不走固定高度：说明文字可能折行）
    static let settingsChoiceRowPaddingV: CGFloat = 6

    // MARK: - 小字

    static var metaFontSize: CGFloat { 11 * uiScale }
}
