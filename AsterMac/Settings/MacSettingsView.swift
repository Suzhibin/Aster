//
//  MacSettingsView.swift
//  AsterMac
//
//  设置窗口 —— **左侧分组菜单 + 右侧内容区**（2026-10-14 按用户给的参考图新建）。
//
//  ## 它在页面层级里的位置
//      ⌘, / 左栏账号栏那颗齿轮 / 账号菜单「设置…」
//            ↓
//      **本页**（`Settings` 场景的根 = 一扇独立窗口）
//            ↓ 「功能 → 模型」那一页里点「添加模型」/ 点某一行
//      「添加模型」表单（`MacAddModelView`，以 **sheet** 呈现）
//
//  ## 🔴 这一页是**新增的一层**，为什么需要它
//  改造前：`Settings { MacCustomModelListView() }` —— 设置窗**直接**就是「自定义模型」清单页。
//  用户 2026-10-14 的要求是「设置页面左侧是菜单，右侧是不同设置功能」，并且
//  **把外面的「语言设置」「外观设置」都收进设置里**。
//  ⇒ 设置窗从「一页」升格成「一个容器」：左边摆导航、右边按选中项换页。
//  ⚠️ 与 iOS 侧**不同形态**（那边侧滑菜单里就地弹卡片）：macOS 的设置窗本来就该是
//     「左边一列、右边一片」—— 系统设置、Xcode、Safari 全是这么摆的。
//
//  ## 🔴 为什么左侧菜单**不是** `List` / `NavigationSplitView`
//  ① **离屏渲染验不到**：`List` 是 AppKit 桥接容器，渲染台只会把它整块画成「黄条 + ⊘」
//     （技能 `ios-swiftui-headless-render`）；`NavigationSplitView` 的侧栏同理。
//     侧栏一旦照不出来，「菜单项有没有、选中态落在哪一行」就只能靠人开 App 看 —— 等于没验。
//     ⇒ 用 `VStack` + 自绘行（与 `SidebarQuickEntries` 同一套手法），每一行都是纯 SwiftUI。
//  ② **这是一个固定尺寸的窗**：设置项一共四项，不需要拖拽调宽 / 折叠 / 滚动这些
//     `NavigationSplitView` 才提供的系统行为 —— 为它们付一个「渲染台瞎掉」的代价不划算。
//  ⚠️ 右侧内容同理**不许用 `ScrollView`**（离屏渲染画不出滚动内容，那一档图会是一片空白）。
//
//  ## 分组与条目：**只列真实存在的功能**
//  参考图里那张菜单（通用 / 个人主页 / 套餐与积分 / 外观 / 快捷键 / 个性化 / 记忆与进化 /
//  智能体 / 模型 / 助理 / 数据管理 / 应用管理 / 安全中心 / 关于）是本 App 的**目标形态**，
//  而本工程目前只有四件事真能用：**语言 / 外观 / 字体大小 / 模型配置**。
//  ⇒ 本轮只落这四项 + 一个「关于」（它是唯一不需要后端的功能）。
//  🔴 **刻意不做占位项**：用户 2026-10-10 亲手删掉过侧栏那个「AI创作」占位
//     （「点了只飘一句『还没接上』」）—— 同一件事不要在这里再犯一次。
//     要加新项：先在 `MacSettingsPage` 里加一个 case，再在 `content` 里给它一页真内容。
//
//  ## ⚠️ 三个「切页面」之外的坑
//  ① **`L()` 必须在 body 求值期调用**（`MacSettingsPage.title` / 分组标题都是计算属性，
//     在 body 里被读到）—— 那是「切语言时文案自己重算」的唯一机制（见 `AILocalization.swift`
//     文件头）。⛔ 别把分组表提成 `static let`：静态初始化只跑一次，切语言后它永远是旧语言。
//  ② **语言 / 外观 / 字体大小的选中态存 `@State`**：三个存取点（`AILanguageStore` /
//     `MacAppearanceStore` / `AIFontSizeStore`）都不是 `@Observable`，写进去不会让
//     SwiftUI 重算 —— 光读它们，点一下界面不会动。
//     ⇒ `@State` 镜像一份、点选时两边一起写（`MacSettingsChoiceRow` 靠 `selected:` 比较）。
//  ③ **切语言会让这一页整体重算**（`L()` 登记了语言版本号那条依赖），但 `@State` 不会丢
//     （视图身份没变）—— 所以选中态不会「切完语言又跳回第一项」。
//

import SwiftUI
import AppKit
import AICore
// 🔴 `AIPlatform.system.openNotificationSettings()` 在 AIPlatform 模块 ——
//    本工程 `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`：用谁的 API 就得显式 import 谁。
import AIPlatform

// MARK: - 页面枚举（左栏导航的条目 = 右侧的一页）

/// 设置窗左侧菜单里的一项，也就是右侧的一页。
///
/// ⚠️ `rawValue` 只是身份（不落盘），随便改；**加项**时记得同步三处：
///    `title` / `icon` / `MacSettingsView.content`。
enum MacSettingsPage: String, CaseIterable, Identifiable {
    /// 通用 —— 目前只有「语言」（macOS 惯例：语言在通用里）
    case language
    /// 外观（浅色 / 深色 / 跟随系统）
    case appearance
    /// 字体大小（对话正文 14 / 16 / 18 / 20 四档，默认第 2 档）
    case fontSize
    /// 模型（= 原来的设置窗本体，「自定义模型」清单页）
    case model
    /// 通知（2026-10-18 加；2026-10-19 改版：桌面通知智能行 / 内容预览 ——
    /// 提示音三档已删，「前往系统设置」并入第一行）
    /// 📌 2026-10-28：显示位置已上移到**第一组**（与语言 / 外观 / 字体同组）。
    /// ⚠️ 菜单顺序由 `MacSettingsSidebar.body` 里的 `group(...)` 决定，**与这里的声明顺序无关**
    ///    （`allCases` 没被用来生成菜单）。
    case notifications
    /// 指令（系统提示词，2026-10-20 加；与 iOS 设置页组2同批新增）
    case instruction
    /// 生成参数（采样 + 思考展示开关，2026-10-20 加）
    case generation
    /// 长期记忆（跨会话记忆：总闸 + 清单，2026-10-25 加；与 iOS 设置页同批新增）
    case memory
    /// 关于
    case about

    var id: String { rawValue }

    /// 菜单里那一行的文案。
    /// ⚠️ 计算属性 + `L()`：必须在 **body 求值期**读（见文件头 ①）。
    var title: String {
        switch self {
        case .language:    return L("语言")
        case .appearance: return L("外观")
        case .fontSize:   return L("字体大小")
        case .model:      return L("模型")
        case .notifications: return L("通知")
        case .instruction:  return L("指令")
        case .generation:   return L("生成参数")
        case .memory:       return L("长期记忆")
        case .about:      return L("关于 Aster")
        }
    }

    /// SF Symbol。⚠️ 与 iOS 侧那套侧滑菜单的图标**不必同款**（两边菜单项本来就不同套），
    ///    但同一件事在两端要尽量挑同一个符号（如「模型」两端都是 `cpu`）。
    var icon: String {
        switch self {
        case .language:   return "gearshape"
        case .appearance: return "circle.lefthalf.filled"
        case .fontSize:   return "textformat"
        case .model:      return "cpu"
        case .notifications: return "bell.badge"
        case .instruction:  return "text.quote"
        case .generation:   return "slider.horizontal.3"
        case .memory:       return "brain.head.profile"
        case .about:      return "info.circle"
        }
    }
}

// MARK: - 外部「打开设置窗并落到某一页」

/// 让**设置窗之外**的地方也能把设置窗直接开到某一页（2026-10-26 加）。
///
/// ## 为什么不能只靠 `MacSettingsView(initialPage:)`
/// `initialPage` 只在**构造时**生效，而 `Settings` 场景是**单例**：
/// 用户先 ⌘, 打过一次窗、再关掉，第二次打开时 SwiftUI 复用那棵树 ——
/// `init` 不会重跑，`initialPage` 静默失效（不报错，只是停在旧页）。
///
/// ## 两条通道，各管一种时序
/// - `NotificationCenter`：窗**已经存在**（开过没关）⇒ 立刻切页，用户无感；
/// - `pending`：窗**还没建**（第一次打开）⇒ 广播时 `MacSettingsView` 的
///   `onReceive` 还没注册，必然收不到 ⇒ 存一份，等 `onAppear` 取走。
/// 只留任一条都会漏：只发通知 = 首次点没反应；只存 pending = 窗开着时点了没反应。
enum MacSettingsRouter {

    /// 「请切到这一页」。object 就是目标页（`MacSettingsPage` 是 `String` 枚举，可跨通知传）。
    static let didRequestPage = Notification.Name("mac_settings_did_request_page")

    /// 待消费的请求（窗还没建时用）。
    private static var pending: MacSettingsPage?

    /// 待消费的「顺手把添加表单也打开」（2026-10-26 加）。
    ///
    /// 会话空态的「去配置模型」是给**还没有任何模型**的用户看的 —— 让他落到清单页、
    /// 再自己找右上角那颗「添加模型」，等于白跑一趟。所以这一路请求额外带一个标记：
    /// 清单页 `onAppear` 时取走它并直接弹表单。
    ///
    /// ⚠️ **与 `pending` 分开清**：`MacSettingsView.onReceive` 会立刻 `consumePending()`
    ///    （它当场就换页了），而这份标记要活到**清单页出现**那一刻才该被取走 ——
    ///    跟 `pending` 绑在一起清的话，切页那一拍就丢了。
    private static var pendingAddForm = false

    /// 记下「打开后落到哪一页」，并广播给**已经活着**的设置窗。
    /// ⚠️ 调用方要在 `openSettings()` **之前**调（见 `ChatDetailView.modelGuide` 那条注释）。
    /// - Parameter openAddForm: `true` = 落到模型页后再直接弹出「添加模型」表单。
    static func request(_ page: MacSettingsPage, openAddForm: Bool = false) {
        pending = page
        pendingAddForm = openAddForm
        NotificationCenter.default.post(name: didRequestPage, object: page)
    }

    /// 取走并清掉待消费的请求（`MacSettingsView.onAppear` 里调）。
    /// ⚠️ 必须**取走就清**：不清的话用户下次 ⌘, 会被上一次的请求又拽到那一页去。
    static func consumePending() -> MacSettingsPage? {
        defer { pending = nil }
        return pending
    }

    /// 取走并清掉「顺手打开添加表单」的标记（`MacCustomModelListView` 里调）。
    /// ⚠️ 同样**取走就清**：不清的话用户下次自己点进「模型」页会被莫名其妙弹出表单。
    /// ⚠️ 幂等：清单页的 `onAppear` 与页请求通知都会调它，先到先清、后到的拿到 `false` —— 正好。
    static func consumePendingAddForm() -> Bool {
        defer { pendingAddForm = false }
        return pendingAddForm
    }
}

// MARK: - 设置窗根视图

struct MacSettingsView: View {

    /// 当前选中的那一页。
    ///
    /// ⚠️ 它**没有默认值** —— 初值由 `init` 的 `initialPage` 给。⛔ 别图省事改成
    ///    `@State private var selection: MacSettingsPage = .general`：`@State` 的默认值
    ///    求值**早于** `init`（本工程铁律），那样写 `initialPage` 永远读不到、恒是 `.general`。
    @State private var selection: MacSettingsPage

    /// 「添加模型」表单是否弹出（2026-10-26）。
    ///
    /// 🔴 **挂在设置窗这一层，而不是 `MacCustomModelListView` 里面**。
    ///    成因：路由请求可能在「切页」的同一拍到达，而模型页那个实例那一刻**还没建**；
    ///    若把 sheet 放在清单页上，就只能靠它的 `onAppear` 补 —— 而「设置窗已经停在模型页」
    ///    时切换不发生、清单页不重建、`onAppear` 也不跑，那条路直接断。
    ///    放在根上就没有「谁来接这一棒」的问题：与有没有切页、清单页重不重建都无关。
    /// ⚠️ 清单页自己那颗「添加模型」按钮仍用**它自己的** `formTarget` sheet（那是用户主动点的，
    ///    落在页面上下文里更自然）—— 两个 sheet 不会同时弹，互不干扰。
    @State private var showAddModelForm = false

    /// - Parameter initialPage: 进页面就停在哪一页，默认「通用」。
    ///   ⚠️ 它**不只是**给验收用的：`⌘,` 打开设置窗停在「通用」本来就是 macOS 的常规。
    ///   🔴 但它确实是**渲染台唯一能造出「选中了别的页」那个态**的手段 ——
    ///      左栏那五行只有**点击**才会改 `selection`，而渲染台投不出点击（本工程已知限制）
    ///      ⇒ 不给它的话「外观 / 字体大小 / 模型 / 关于」四页**一张图都验不到**，只能靠源码 grep
    ///      （那只能证明「分支还在」，证不了「那一页长得对」）。
    init(initialPage: MacSettingsPage = .language) {
        _selection = State(initialValue: initialPage)
    }

    var body: some View {
        HStack(spacing: 0) {
            MacSettingsSidebar(selection: $selection)
                .frame(width: MacTheme.settingsSidebarWidth)
            // 系统那条 1pt 竖线（`.separatorColor`）—— 与左栏底色一起把两片分开
            Divider()
            content
        }
        // 🔴 尺寸定死：`Settings` 场景开出来的窗就照内容尺寸走。
        //    ⚠️ 右侧内容靠 `maxWidth/maxHeight: .infinity` 吃掉除左栏之外的全部空间 ——
        //    不写的话 `MacCustomModelListView` 会缩成它自己的理想宽度（那一页里没有
        //    「吃掉剩余宽度」的容器），窗口右边会空出一大片。
        .frame(width: MacTheme.settingsWindowSize.width,
               height: MacTheme.settingsWindowSize.height)
        // 「去配置模型」那条路要直接弹「添加模型」表单（2026-10-26）。成因见 `showAddModelForm`。
        .sheet(isPresented: $showAddModelForm) {
            MacAddModelView(editingModel: nil)
        }
        // 🔴 外部要求「打开就停在某一页」（会话页空态的「去配置模型」）——两条通道
        //    各管一种时序，成因见 `MacSettingsRouter` 的注释。
        .onAppear {
            if let page = MacSettingsRouter.consumePending() { selection = page }
            openAddModelFormIfRequested()
        }
        .onReceive(NotificationCenter.default.publisher(for: MacSettingsRouter.didRequestPage)) { note in
            guard let page = note.object as? MacSettingsPage else { return }
            // 已经就地处理了 ⇒ 清掉 pending，免得下次 ⌘, 又被这次请求拽走
            _ = MacSettingsRouter.consumePending()
            selection = page
            openAddModelFormIfRequested()
        }
    }

    /// 路由请求里带了「顺手打开添加表单」时照办。
    ///
    /// ⚠️ **必须延后一拍**：设置窗可能是**这一拍刚建出来**的（首次点「去配置模型」），
    ///    那时本视图还在挂载、还没进窗口层级，同步置 `showAddModelForm` 会让 sheet
    ///    挂到一个不存在的宿主上 —— 表现是「点了没反应」，不崩也不报警。
    /// ⚠️ 只在**取到标记**时才动：`consumePendingAddForm()` 取走即清 ⇒ 用户自己 ⌘, 进模型页
    ///    永远不会被凭空弹出的表单打扰。
    private func openAddModelFormIfRequested() {
        guard MacSettingsRouter.consumePendingAddForm() else { return }
        DispatchQueue.main.async { showAddModelForm = true }
    }

    /// 右侧内容区（按选中项换页）。
    /// ⚠️ 三个页自己带页面留白与卡片；`.model` 例外 —— 那一页（`MacCustomModelListView`）
    ///    是本轮之前就有的整页，它自己管内外边距，嵌进来时**不要再套一层 padding**
    ///    （套了会让它与另外两页的左缘差一截）。
    @ViewBuilder
    private var content: some View {
        Group {
            switch selection {
            case .language:    MacGeneralSettingsView()
            case .appearance: MacAppearanceSettingsView()
            case .fontSize:   MacFontSizeSettingsView()
            // 🔴 `fixedSize: nil` = 「尺寸交给父级」（那一页自己那份 520×480 是给
            //    `render_mac_ui.sh` 单独验它时用的，嵌进设置窗时不该生效）。
            case .model:      MacCustomModelListView(fixedSize: nil)
            case .notifications: MacNotificationSettingsView()
            case .instruction:  MacInstructionSettingsView()
            case .generation:   MacGenerationSettingsView()
            case .memory:       MacMemorySettingsView()
            case .about:      MacAboutSettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // ⚠️ 页面底铺在**这一层**（而不是各页自己铺）：换页时底色不会闪一下，
        //    而且三条 `.model` 之外的页就不用手写这行背景了。
        .background(MacTheme.pageBackground)
    }
}

// MARK: - 左栏

/// 左侧导航：`设置（通用 / 外观 / 字体大小 / 通知）· 功能（模型 / 指令 / 生成参数 / 长期记忆）· 关于（关于 Aster）`。
///
/// ⚠️ 三条口径（都是「不做就坏、但不报错」）：
///  ① 行**必须 `contentShape(Rectangle())`**：图标 + 文字只有十几个像素是可点的，
///     撑不满行的话用户得瞄准着点（与侧栏入口 / 账号栏同一个坑）。
///  ② hover 底**恒占位、只翻 fill**（⛔ 别用 `if hovered { … }` 插一层）——
///     那样行高会跟着指针抖。
///  ③ 图标列**定宽**（`settingsNavIconWidth`）：不定宽的话四个图标的实际宽窄不同，
///     四行文字的左缘会参差不齐（一眼能看出来）。
private struct MacSettingsSidebar: View {

    @Binding var selection: MacSettingsPage

    @Environment(\.colorScheme) private var colorScheme

    /// 指针停在哪一行（`nil` = 不在侧栏里）。只驱动底色，不改任何布局。
    @State private var hovered: MacSettingsPage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 窗顶那个「设置」标题。
            // 🔴 它**同时是第一组的分组标题** —— 参考图里最上面那个「设置」就是它
            //    （字号比后面的「功能 / 关于」大一号、颜色也更实），第一组因此**不再另画标题**。
            //    ⚠️ 改之前这里是「一个标题 + 第一组标题也叫『设置』」⇒ 图上连着出现两个
            //       「设置」，上面那个黑、下面那个灰（`settings_window_general` 那张一眼可辨）。
            //    ⚠️ 也走 `L()` —— 它是本页文案的一部分。
            Text(L("设置"))
                .font(MacTheme.ui(13, weight: .semibold))
                .foregroundStyle(MacTheme.bodyColor)
                .padding(.horizontal, MacTheme.settingsSidebarPaddingH + 8)
                .padding(.top, MacTheme.settingsSidebarPaddingV)
                .padding(.bottom, 8)

            // 🔴 分组表写在**计算属性 / body 里**（⛔ 不是 `static let`）—— 见文件头 ①：
            //    静态初始化只跑一次，切语言后这三行标题会永远停在旧语言。
            // ⚠️ 第一组传 `nil` = 不画组标题（见上面那条）；
            //    「设置 / 功能 / 关于」三个字都走 `L()`（词表里有独立条目）。
            // 📌 2026-10-28：用户要求「把通知移动到第一组，与语言、外观、字体一组」⇒ 与 iOS 同步上移。
            group(nil, [.language, .appearance, .fontSize, .notifications])
            group(L("功能"), [.model, .instruction, .generation, .memory])
            group(L("关于"), [.about])

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(MacTheme.settingsSidebarBackground)
    }

    /// 一组（可选小标题 + 若干条）。
    /// - Parameter title: `nil` = 不画组标题（第一组「通用 / 外观」用它 —— 它头顶那个
    ///   大一号的「设置」已经在 `body` 里画过了，再写一遍会出现两个「设置」）。
    private func group(_ title: String?, _ pages: [MacSettingsPage]) -> some View {
        VStack(alignment: .leading, spacing: MacTheme.settingsNavRowSpacing) {
            if let title {
                Text(title)
                    .font(MacTheme.ui(MacTheme.settingsGroupTitleFontSize))
                    .foregroundStyle(MacTheme.meta)
                    .padding(.horizontal, MacTheme.settingsSidebarPaddingH + 8)
                    .padding(.top, MacTheme.settingsGroupTitlePaddingTop)
                    .padding(.bottom, MacTheme.settingsGroupTitlePaddingBottom)
            }
            ForEach(pages) { page in
                row(page)
            }
        }
        .padding(.horizontal, MacTheme.settingsSidebarPaddingH)
        .padding(.bottom, MacTheme.settingsGroupSpacing)
    }

    /// 一条导航项。
    private func row(_ page: MacSettingsPage) -> some View {
        let isSelected = (page == selection)
        return Button {
            selection = page
        } label: {
            HStack(spacing: 8) {
                Image(systemName: page.icon)
                    .font(MacTheme.ui(MacTheme.settingsNavIconSize))
                    // 选中那一行图标走强调色（与 App 里其它「选中」语义同源）；
                    // 其余走二级标签色 —— 图标是辅助，不该比文字抢眼。
                    .foregroundStyle(isSelected ? MacTheme.actionIcon
                                                : Color(nsColor: .secondaryLabelColor))
                    .frame(width: MacTheme.settingsNavIconWidth)
                Text(page.title)
                    .font(MacTheme.ui(MacTheme.settingsNavFontSize))
                    .foregroundStyle(MacTheme.bodyColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: MacTheme.settingsNavRowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            // ② 命中区撑满整行（见类型头注释 ①）
            .contentShape(Rectangle())
            // ② hover / 选中底**恒占位**，只翻颜色
            .background {
                RoundedRectangle(cornerRadius: MacTheme.settingsNavRowRadius)
                    .fill(rowFill(isSelected: isSelected, hovered: hovered == page))
            }
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hovered = page
            } else if hovered == page {
                hovered = nil
            }
        }
    }

    /// 一行底色的**唯一**判据（选中 > 悬停 > 无）。
    /// ⚠️ 选中与悬停**不同档**：只差透明度的话指针扫过选中项时看不出「它已经是当前页」。
    private func rowFill(isSelected: Bool, hovered isHovered: Bool) -> Color {
        if isSelected { return MacTheme.settingsNavSelection(colorScheme) }
        if isHovered { return MacTheme.quickEntryHoverBackground(colorScheme) }
        return .clear
    }
}

// MARK: - 右侧：页面骨架

/// 右侧每一页的公共骨架：四周留白 + 靠上摆放 + 页面底。
///
/// 🔴 「不留 `ScrollView`」是刻意的（见文件头）—— 设置项一共没几行，固定版面就够；
///    换成滚动容器会让离屏渲染那一档变成**空白图**（不是「看着不对」，是「什么都没有」）。
/// ⚠️ **internal 而不是 `private`**（2026-10-25 放松）：设置窗里其余几页都写在
///    **本文件**内，所以原来是 private；「长期记忆」页拆去了
///    `MacMemorySettingsView.swift`（它带条件式 ScrollView，而本文件受
///    `render_mac_ui.sh` 那条「不许出现 ScrollView」的契约管着），它也要用这个骨架
///    ⇒ 放开。⛔ 别为了省这一行把它在那边重抄一份。
struct MacSettingsPageScaffold<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            Spacer(minLength: 0)
        }
        .padding(MacTheme.settingsContentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 右侧一张卡片（照参考图：每一块设置内容都装在一张圆角卡里，卡片内是「标题 + 说明 + 内容」）。
///
/// ⚠️ 与 `MacCustomModelListView` 的页头是同一种卡 —— 但那边是本轮之前就有的整页，
///    它自己那份卡片留在原处（两处样式**刻意共用同一组 `MacTheme.settingsCard*` 常量**，
///    ⛔ 别在某一处另写一份圆角 / 内边距）。
struct MacSettingsCard<Content: View>: View {

    let title: String
    /// 副标题（说明那一行）。`nil` = 不画。
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: MacTheme.settingsCardHeaderSpacing) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(MacTheme.ui(13, weight: .semibold))
                    .foregroundStyle(MacTheme.bodyColor)
                if let subtitle {
                    Text(subtitle)
                        .font(MacTheme.ui(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(MacTheme.settingsCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.settingsCardRadius)
                .fill(MacTheme.settingsCardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: MacTheme.settingsCardRadius)
                        .stroke(MacTheme.settingsCardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - 右侧：一条可选项

/// 卡片里的一条选项（选中打勾）—— 语言与外观两页共用。
///
/// 🔴 为什么是**自绘的一行**、而不是 `Picker`：`Picker` 在离屏渲染里是系统控件
///    （`.segmented` 那一档照不出来、`.menu` 只有「黄条 + ⊘」），验收图会看不出
///    「勾在哪一档」—— 而这一页的全部内容就是那三档。自绘之后每一档都在图里。
/// ⚠️ 勾号**恒占位、只翻 opacity**（⛔ 别用 `if selected { … }`）：否则选中态一变，
///    文字右边那一截宽度跟着变，整行会横着抖一下。
struct MacSettingsChoiceRow: View {

    let title: String
    /// 那一行小字说明。`nil` = 不画（语言的三档不需要逐条解释）。
    var detail: String?
    let selected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(MacTheme.ui(13))
                        .foregroundStyle(MacTheme.bodyColor)
                    if let detail {
                        Text(detail)
                            .font(MacTheme.ui(11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(MacTheme.ui(12, weight: .semibold))
                    .foregroundStyle(MacTheme.linkText)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, MacTheme.settingsChoiceRowPaddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: MacTheme.settingsNavRowRadius)
                    .fill(fill)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var fill: Color {
        if selected { return MacTheme.settingsNavSelection(colorScheme) }
        if hovered { return MacTheme.quickEntryHoverBackground(colorScheme) }
        return .clear
    }
}

// MARK: - 右侧：一颗开关（通知页 / 记忆页共用）

/// 「标题 + 小字说明 + 右侧开关」一行。
///
/// 🔴 2026-10-25 从 `MacNotificationSettingsView` 的私有方法**提成共用组件** ——
///    「长期记忆」页也要一颗总闸开关，⛔ 不抄第二遍（与 iOS 侧把 `AINotifySwitchView`
///    从 private 放松为 internal 给记忆页复用同一条纪律）。
///    提的是**逐字同一份布局**（连内边距常量都没换）⇒ 通知页那张验收图一个像素都不该动。
///
/// ⚠️ `Toggle` 用 `labelsHidden()` + 空标签：标签由左边的 `VStack` 自己画
///    （说明那行小字也得在 SwiftUI 手里，才能 `fixedSize` 换行）。
/// ⚠️ 行本体**不可点**（点开关本身）—— 与 `MacSettingsChoiceRow` 同一口径，
///    命中区就是控件边界，⛔ 别给整行挂 `onTapGesture`（用户点说明文字也会跳）。
struct MacSettingsToggleRow: View {

    let title: String
    /// 小字说明（跟着开关状态换文案由调用方给）。
    var detail: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MacTheme.ui(13))
                    .foregroundStyle(MacTheme.bodyColor)
                Text(detail)
                    .font(MacTheme.ui(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, MacTheme.settingsChoiceRowPaddingV)
    }
}

// MARK: - 右侧：通用（语言）

/// 「通用」页 —— 目前只有**语言**一项。
///
/// 🔴 语言档位从**账号菜单**搬到这里（2026-10-14 用户要求「可以把外边的语言设置…都移动设置里」）。
///    ⚠️ 搬运**只动了入口**：`AILanguageStore` 是唯一存取点，写它照旧触发
///    `AILanguageRevision.bump()` + `didChange` 通知 ⇒ 「切完立刻全界面换语言」那条路一个字没动。
private struct MacGeneralSettingsView: View {

    /// 选中档位的**镜像**。⚠️ 非 `@Observable` 的存取点：光读它界面不会跟着动（见文件头 ②）。
    @State private var language: AILanguage = AILanguageStore.current

    var body: some View {
        MacSettingsPageScaffold {
            MacSettingsCard(title: L("语言"), subtitle: L("只切换界面文案，AI 回复不受影响")) {
                VStack(spacing: 2) {
                    ForEach(AILanguage.allCases, id: \.self) { option in
                        MacSettingsChoiceRow(title: option.title, selected: option == language) {
                            // 🔴 先改镜像再写存取点（顺序其实无所谓，但**两处都要写**）：
                            //    只写存取点 ⇒ 点一下界面不动（它不登记观察依赖）。
                            language = option
                            AILanguageStore.current = option
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 右侧：外观

/// 「外观」页 —— 浅色 / 深色 / 跟随系统三档。
///
/// 🔴 与语言同一次搬运（入口从账号菜单移到设置）。
/// ⚠️ 应用方式照旧是 `NSApp.appearance`（`MacAppearanceStore.current` 的 setter 里调 `apply`）——
///    ⛔ **别在这里补一句 `MacAppearanceStore.apply(…)`**：两处都会改 `NSApp.appearance`，
///    将来换应用方式就得多改一处（那条取舍写在 `MacAppearance.swift` 文件头）。
private struct MacAppearanceSettingsView: View {

    /// 同「通用」页：非 `@Observable` 的存取点，需要一份镜像（见文件头 ②）。
    @State private var appearance: MacAppearance = MacAppearanceStore.current

    var body: some View {
        MacSettingsPageScaffold {
            MacSettingsCard(title: L("外观"), subtitle: L("立即应用到所有窗口")) {
                VStack(spacing: 2) {
                    ForEach(MacAppearance.allCases) { option in
                        MacSettingsChoiceRow(title: option.title, selected: option == appearance) {
                            appearance = option
                            MacAppearanceStore.current = option
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 右侧：字体大小

/// 「字体大小」页 —— 对话正文四档（14 / 16 / 18 / 20，默认第 2 档 = 16）。
///
/// 🔴 **为什么它不需要任何「应用」代码**：`AITypography.bodyFontSize` 是个计算属性
///    （基准 16 + 档位偏移），而它会读一次 `AIFontSizeRevision`（手写 `Observable`，
///    与 `AILanguageRevision` 同一套手法）⇒ `MacTheme.body` → 它 这条链上**每一个**渲染过
///    正文的视图都登记了依赖，写一次档位就各自重算。⛔ 别在这里补 `apply` / 通知转发。
///
/// ⚠️ 与语言 / 外观**同一套镜像套路**：存取点（`AIFontSizeStore`）不是 `@Observable`，
///    光读它界面不会动 ⇒ `@State` 镜像一份、点选时两边一起写（见文件头 ②）。
///
/// ⚠️ 选完**留在本页**（与外观同）：用户想再比一档不用重新点进来。
private struct MacFontSizeSettingsView: View {

    /// 同「通用」页：非 `@Observable` 的存取点，需要一份镜像（见文件头 ②）。
    @State private var scale: AIFontSizeScale = AIFontSizeStore.current

    var body: some View {
        MacSettingsPageScaffold {
            MacSettingsCard(title: L("字体大小"), subtitle: L("调整对话中文字的大小，立即生效")) {
                VStack(spacing: 2) {
                    ForEach(AIFontSizeScale.allCases) { option in
                        MacSettingsChoiceRow(title: option.title, selected: option == scale) {
                            // 🔴 先改镜像再写存取点（顺序其实无所谓，但**两处都要写**）：
                            //    只写存取点 ⇒ 点一下界面不动（它不登记观察依赖）。
                            scale = option
                            AIFontSizeStore.current = option
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 右侧：通知（2026-10-18 新增；2026-10-19 改版）

/// 「通知」页 —— 一张卡：「启用桌面通知」（智能行）+「显示内容预览」。
///
/// ## 2026-10-19 改版（用户原话）：「两端去掉通知提示音项…把前往系统设置放在第一项。
/// 第一项逻辑是如果系统关闭，第一项也关闭，点击去系统设置；如果系统开启，
/// 点击第一项直接开启」
/// ① **提示音三档整卡删除** —— 通知跟随系统默认音（`AIReplyNotifier` 不传 sound）；
/// ② **「系统权限 + 前往系统设置」行删除**，能力并入第一行（见 `desktopRow`）：
///    - 系统**关着**（denied / notDetermined）⇒ 开关**跟着关**（`.disabled` + get 恒 false
///      —— 系统关着时通知发不出去，留着能拨的开关是骗人的），**整行可点** ⇒
///      `openNotificationSettings()`；副标题换成「系统通知已关闭，轻点前往系统设置」。
///    - 系统**开着** ⇒ 第一行就是总闸本体（拨动直接写存取点）。
///
/// ## 🔴 偏好必须配 `@State` 镜像（与语言 / 外观 / 字号同一条铁律）
/// `AINotificationPreferences` 是静态存取点、**不是** `@Observable`：只写它界面不动
/// （编译得过、不报错 —— 本工程最费时间的那类坑）。点选时**两处都要写**：
/// 先改镜像（视图随即重求）再写存取点（落盘；`AIReplyNotifier.post` 现读即生效）。
///
/// ## ⚠️ 授权状态是异步的，且有**两个刷新时机**
/// `UNUserNotificationCenter.getNotificationSettings` 的完成处理器**不保证主线程**
/// ⇒ 回主线程再赋值。初值给 `.authorized`（「已开启」）是刻意的：查完之前
/// 别把第一行置灰（反正下一帧就刷成真值）。
/// 刷新点：① `onAppear`（首入本页）；② **`NSApplication.didBecomeActiveNotification`** ——
/// 用户去系统设置改权限再切回本 App 时，窗口一直开着、`onAppear` **不会再跑**
/// ⇒ 不监听激活通知，改完权限回来第一行还停在旧状态（静默错状态，最难发现的那类）。
private struct MacNotificationSettingsView: View {

    /// 两个偏好的镜像（见文件头 🔴）。⚠️ `@State` 默认值求值早于 `init` 没问题 ——
    /// 这里读的是**静态存取点**（那一刻已可用），不是入参。
    @State private var isEnabled: Bool = AINotificationPreferences.isEnabled
    @State private var showsPreview: Bool = AINotificationPreferences.showsPreview
    /// 系统授权状态（异步刷新，见 `refreshAuthorization`）。
    @State private var authorization: AINotificationAuthorization = .authorized

    /// 系统通知**关着**（denied / notDetermined 都算 —— 没问过 = 现在也发不出去）。
    private var isSystemOff: Bool { authorization != .authorized }

    var body: some View {
        MacSettingsPageScaffold {
            notificationCard
        }
        .onAppear(perform: refreshAuthorization)
        // ② 从系统设置改完权限切回来（窗口没关 ⇒ onAppear 不会再跑，见文件头）。
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAuthorization()
        }
    }

    // MARK: 唯一一张卡：通知

    private var notificationCard: some View {
        MacSettingsCard(title: L("通知"),
                        subtitle: L("任务完成，将会通过系统弹窗提醒你。")) {
            VStack(alignment: .leading, spacing: 0) {
                desktopRow
                Divider().padding(.horizontal, 10)
                MacSettingsToggleRow(title: L("显示内容预览"),
                          detail: L("在通知中显示你发送的消息内容。"),
                          isOn: Binding(
                            get: { showsPreview },
                            set: { showsPreview = $0; AINotificationPreferences.showsPreview = $0 }))
            }
        }
    }

    // MARK: 第一行：桌面通知（智能行）

    /// 「启用桌面通知」一行 —— **系统开着时是普通开关行；系统关着时整行变成
    /// 「前往系统设置」的入口**（改版说明见类型头）。
    ///
    /// 🔴 跳转走 `AIPlatform.system.openNotificationSettings()` 接缝 ——
    ///    iOS 落 App 设置页、macOS 落通知面板，平台差异全在那个 impl 里。
    ///    ⛔ 别在这里写 `NSWorkspace` / URL scheme（那是把平台分支漏进 UI 层）。
    private var desktopRow: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("启用桌面通知"))
                    .font(MacTheme.ui(13))
                    .foregroundStyle(MacTheme.bodyColor)
                // 系统关着时副标题换成引导语（同时解释开关为什么是灰的）。
                Text(isSystemOff
                     ? L("系统通知已关闭，轻点前往系统设置")
                     : L("关闭后不再发送任何回复通知"))
                    .font(MacTheme.ui(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                // 🔴 系统关 ⇒ 恒 false（「第一项也关闭」）；开着 ⇒ 总闸真实值。
                get: { isSystemOff ? false : isEnabled },
                set: { isEnabled = $0; AINotificationPreferences.isEnabled = $0 }))
                .labelsHidden()
                .fixedSize()
                // 系统关着时拨不动（通知此刻发不出去；要开先去系统设置）。
                .disabled(isSystemOff)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, MacTheme.settingsChoiceRowPaddingV)
        // 🔴 整行命中区：**只有系统关着时才办事**（去系统设置）。
        //    系统开着时点行 = 什么都不做（拨动走开关本体）—— 与 `toggleRow`
        //    「命中区就是控件边界」那条口径不冲突：开着时不会误跳任何地方。
        .contentShape(Rectangle())
        .onTapGesture {
            if isSystemOff {
                AIPlatform.system.openNotificationSettings()
            }
        }
    }

    // MARK: 授权状态

    private func refreshAuthorization() {
        AINotificationPreferences.authorization { status in
            // ⚠️ UN 的完成处理器不保证主线程 ⇒ 跳回来再赋值（SwiftUI 的状态更新
            //    虽然在后台线程多半也不崩，但那是未定义行为，别赌）。
            DispatchQueue.main.async {
                authorization = status
            }
        }
    }
}

// MARK: - 右侧：关于

/// 「关于 Aster」页 —— 版本 + 一句说明 + 源码地址。
///
/// ⚠️ 它是本轮唯一一个**不需要任何后端 / 配置**的页面，所以顺手做了；
///    参考图里那一组的其余项（数据管理 / 应用管理 / 安全中心）本工程一个都没有，
///    ⛔ **不做占位**（见文件头）。
private struct MacAboutSettingsView: View {

    /// 「GitHub」那一项打开的地址。
    /// 🔴 2026-10-27：口径从已删除的 `SidebarAccountBar.gitHubURL` 挪到共享层
    ///    `AIGitHubURL`（`AsterCore/AICore/AIAppInfo.swift`，两端唯一来源）。
    ///    ⛔ 别在这里再写一份字符串。
    private static let repoURL = URL(string: AIGitHubURL)

    var body: some View {
        MacSettingsPageScaffold {
            MacSettingsCard(title: L("关于 Aster"), subtitle: versionLine) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("一个本地优先的 AI 对话客户端：会话与配置都留在本机，模型写在自己的 models.json 里。"))
                        .font(MacTheme.ui(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        // ⚠️ 图标色走语义色（`actionIcon` = 系统强调色）—— ⛔ 别在这里硬编码紫色，
                        //    本工程「颜色只有 `MacTheme` 一处来源」（唯一例外是代码语法色）。
                        Image(systemName: "sparkles")
                            .font(MacTheme.ui(12))
                            .foregroundStyle(MacTheme.actionIcon)
                        Text(L("源码"))
                            .font(MacTheme.ui(13))
                            .foregroundStyle(MacTheme.bodyColor)
                        Spacer(minLength: 8)
                        // ⚠️ 由 `AIGitHubURL` 派生（`AIGitHubDisplayName`），⛔ 别写死这串字
                        Text(AIGitHubDisplayName)
                            .font(MacTheme.ui(12))
                            .foregroundStyle(MacTheme.linkText)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, MacTheme.settingsChoiceRowPaddingV)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let url = Self.repoURL { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
    }

    /// 版本号那一行。
    ///
    /// ⚠️ 取不到就回落 `"1.0"`：`Bundle.main` 在**离屏渲染台**里是那个裸可执行文件（没有
    ///    Info.plist）⇒ 那一档图会显示「版本未知」，看不出「接线对不对」。
    ///    🔴 回落成与真机同一个值，图才有验收意义（真机上读到的就是 `CFBundleShortVersionString`）。
    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (info?["CFBundleVersion"] as? String) ?? ""
        return build.isEmpty ? String(format: L("版本 %@"), version)
                             : String(format: L("版本 %@（%@）"), version, build)
    }
}

// MARK: - 右侧：指令（系统提示词）

/// 「指令」页（2026-10-20 新建，与 iOS 的 `AIInstructionSettingsViewController` 同批）。
///
/// 写 `AIGenerationSettings.systemPrompt` —— 每轮请求最前面的 `role: system` 消息
/// （注入点见 `AIChatManager.withSystemPrompt`）。空 = 不发，请求体与上线前一致。
///
/// 🔴 非 `@Observable` 的存取点 ⇒ `@State` 镜像 + `onChange` 回写（见文件头 ②）：
///    只写镜像 ⇒ 存取点不变（请求不带指令）；只写存取点 ⇒ 界面不动。
/// ⚠️ 击键即存（`onChange` 每次击键都回写）—— 与 iOS 页「自动保存」同一口径，
///    没有「忘了保存」这个失败模式；`systemPrompt` 的 setter 自带「变了才广播」守卫，
///    所以不会因为击键刷屏式发通知。
private struct MacInstructionSettingsView: View {

    @State private var prompt: String = AIGenerationSettings.systemPrompt

    var body: some View {
        MacSettingsPageScaffold {
            MacSettingsCard(title: L("指令"),
                            subtitle: L("追加在每轮请求最前面的系统提示词")) {
                VStack(alignment: .leading, spacing: 12) {
                    editor
                    presets
                    footer
                }
            }
        }
        // ⚠️ macOS 14 起 `onChange` 的单参闭包已弃用 ⇒ 用双参（old, new）形态。
        .onChange(of: prompt) { _, newValue in
            // 🔴 上限拦截（2026-10-27）：原来只显示 `x / 2000` 却**不拦**，
            //    粘贴一段长文照样能进 `systemPrompt` ⇒ 那个 "2000" 是假的。
            //    现在与项目面板同走 `clampInstruction`（iOS 那边由 shouldChangeTextIn 硬拒）。
            //    ⚠️ 超限时才回写：无脑回写会让 `onChange` 多跑一轮。
            let clamped = AIGenerationSettings.clampInstruction(newValue)
            if clamped != newValue { prompt = clamped }
            AIGenerationSettings.systemPrompt = clamped
        }
    }

    /// 多行编辑器 + 占位符（空串时叠在编辑器上，⛔ 别用 `if` 插层 —— 会抖）。
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $prompt)
                .font(MacTheme.ui(12))
                .lineSpacing(4)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(MacTheme.pageBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(MacTheme.settingsCardBorder, lineWidth: 1)
                        )
                )
                .frame(height: 132)
            if prompt.isEmpty {
                Text(L("例如：你是一名严谨的技术顾问。回答先给结论，再给理由；不确定时直说，不要编造。"))
                    .font(MacTheme.ui(12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 快捷预设 chips。🔴 2026-10-27 起走**共享组件** `MacInstructionChipRow`
    /// （项目指令面板用的是同一个）—— 单一真值从「预设正文」扩到「chip 长什么样」。
    /// 外观/间距/不许加 ScrollView 的理由都在那个结构体上。
    private var presets: some View {
        MacInstructionChipRow { text in prompt = text }
    }

    /// 底部一行：字数 + 恢复默认。
    private var footer: some View {
        HStack {
            // 🔴 上限读共享常量（⛔ 别再写字面量 2000：改了常量这里会静默不动）
            // ⚠️ `Text(verbatim:)`：`Text("\(整数)")` 会把 2000 本地化成「2,000」，
            //    与 iOS 那页的「2000」不一致（看着像两套上限）。
            Text(verbatim: "\(prompt.count) / \(AIGenerationSettings.instructionMaxLength)")
                .font(MacTheme.ui(11))
                .foregroundStyle(MacTheme.meta)
            Spacer(minLength: 8)
            Button(L("恢复默认")) { prompt = "" }
                .font(MacTheme.ui(12))
                .foregroundStyle(.red)
                .buttonStyle(.plain)
        }
    }
}

// MARK: - 指令预设 chips（两个编辑入口共用的那一条）

/// 「指令」编辑器下方那条预设 chips —— **全局指令页 与 项目指令面板共用一份**。
///
/// ## 为什么抽出来（2026-10-27）
/// 全局页先有这一条；项目面板补 chips 时若照抄一遍，就是第二份「chip 长什么样」
/// （边框色 / 圆角 / 字号 / 内外边距）。改一处漏一处不报错，表现是
/// **两个入口里做同一件事的按钮长得不一样**，而两边各有各的验收图，很难并排发现。
/// 与 `AIInstructionPreset`（预设正文的单一真值）同一条纪律，这一份管**外观**。
///
/// ## 🔴 刻意不用 `ScrollView(.horizontal)`
/// 设置窗里出现 ScrollView 会让「设置窗」那几档离屏验收图**整页空白**
/// （`ImageRenderer` 画不出滚动内容，`render_mac_ui.sh` 里一条硬契约的由来）。
/// 四颗 chip 一行放得下（合计 ≈ 270pt；设置窗内容区 500+，项目面板内容区 428）
/// ⇒ 不需要横滑。⚠️ 将来 preset 加到一行放不下时**换成换行布局**（⛔ 别改回 ScrollView）。
///
/// ## 自绘而不是系统 Button
/// 离屏渲染台照得出自绘的边框/底色，系统 `Button` 的边框在 `ImageRenderer` 里会丢
/// （与 `MacSettingsSliderRow` 自绘 slider 同一条理由）。
struct MacInstructionChipRow: View {

    /// 点了一颗要写入编辑器的正文：preset ⇒ 它的 `body`；「清空」⇒ 空串。
    /// ⚠️ 只交出**文本**，不碰存取点 —— 写哪儿由调用方决定（全局 UserDefaults /
    ///    项目 SQLite 的防抖落库），这正是两个入口能共用一个视图的原因。
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AIInstructionPreset.allCases, id: \.self) { preset in
                chip(preset.title) { onPick(preset.body) }
            }
            chip(L("清空")) { onPick("") }
        }
    }

    /// 一颗 chip。
    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(MacTheme.ui(11))
                .foregroundStyle(MacTheme.linkText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(MacTheme.settingsSidebarBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(MacTheme.settingsCardBorder, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 右侧：生成参数

/// 「生成参数」页（2026-10-20 新建，与 iOS 的 `AIGenerationSettingsViewController` 同批）。
///
/// 两段：**采样参数**（温度 / 最大长度，每项一颗「自定义」开关 —— 关 = 不发字段、
/// 用服务端默认）+ **思考**（展示思考过程总闸）。
///
/// 🔴 slider 是**自绘**的（`MacSettingsSliderRow`）：SwiftUI 原生 `Slider` 在
///    离屏渲染台里是 AppKit 控件照不出来（本工程既有教训：`.segmented`  picker
///    同理）⇒ 那一页的关键内容会变成「黄条 + ⊘」。自绘之后每一档都在图里。
private struct MacGenerationSettingsView: View {

    /// 四个镜像（见文件头 ②：非 `@Observable` ⇒ 镜像 + 双写）。
    /// ⚠️ `@State` 默认值求值早于 `init` 没问题 —— 读的是**静态存取点**，那一刻已可用。
    @State private var temperatureEnabled: Bool = AIGenerationSettings.temperatureEnabled
    @State private var temperature: Double = AIGenerationSettings.temperature
    @State private var maxTokensEnabled: Bool = AIGenerationSettings.maxTokensEnabled
    @State private var maxTokens: Double = Double(AIGenerationSettings.maxTokens)
    @State private var showsThinking: Bool = AIGenerationSettings.showsThinkingProcess

    var body: some View {
        MacSettingsPageScaffold {
            samplingCard
            thinkingCard
            resetRow
        }
    }

    private var samplingCard: some View {
        MacSettingsCard(title: L("采样参数"), subtitle: L("关闭时使用服务端默认值")) {
            VStack(spacing: 0) {
                paramRow(title: L("温度"),
                         valueText: temperatureEnabled
                             ? String(format: "%.1f", temperature)
                             : L("服务端默认"),
                         detail: L("越低越确定，越高越有随机性"),
                         isOn: $temperatureEnabled,
                         onChange: { AIGenerationSettings.temperatureEnabled = $0 })
                if temperatureEnabled {
                    Divider().padding(.horizontal, 10)
                    MacSettingsSliderRow(title: L("拖动调整"),
                                         range: AIGenerationSettings.temperatureRange,
                                         step: 0.1,
                                         format: "%.1f",
                                         value: $temperature,
                                         onChange: { AIGenerationSettings.temperature = $0 })
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                Divider().padding(.horizontal, 10)
                paramRow(title: L("最大长度"),
                         valueText: maxTokensEnabled
                             ? "\(Int(maxTokens))"
                             : L("服务端默认"),
                         detail: L("单次回复的最大 token 数"),
                         isOn: $maxTokensEnabled,
                         onChange: { AIGenerationSettings.maxTokensEnabled = $0 })
                if maxTokensEnabled {
                    Divider().padding(.horizontal, 10)
                    MacSettingsSliderRow(title: L("拖动调整"),
                                         // ⚠️ 区间表达式必须**在一行内**（`...` 运算符跨行
                                         //    会被解析成前缀形式 PartialRangeThrough，
                                         //    报错位置还很误导）—— 与 iOS 侧同一条坑。
                                         range: Double(AIGenerationSettings.maxTokensRange.lowerBound)...Double(AIGenerationSettings.maxTokensRange.upperBound),
                                         step: 256,
                                         format: "%.0f",
                                         value: $maxTokens,
                                         onChange: { AIGenerationSettings.maxTokens = Int($0.rounded()) })
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    /// 「标题 + 右侧值 + 小字说明 + 开关」一行（形态同通知页 `toggleRow`，多一个右侧值）。
    private func paramRow(title: String,
                          valueText: String,
                          detail: String,
                          isOn: Binding<Bool>,
                          onChange: @escaping (Bool) -> Void) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .font(MacTheme.ui(13))
                        .foregroundStyle(MacTheme.bodyColor)
                    Spacer(minLength: 8)
                    Text(valueText)
                        .font(MacTheme.ui(12))
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(MacTheme.ui(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { isOn.wrappedValue },
                // 🔴 双写：镜像 + 存取点（只写一个都是「界面不动」或「请求不带」）。
                set: { isOn.wrappedValue = $0; onChange($0) }))
                .labelsHidden()
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, MacTheme.settingsChoiceRowPaddingV)
    }

    private var thinkingCard: some View {
        MacSettingsCard(title: L("思考"), subtitle: L("思考过程的显示与保存")) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("展示思考过程"))
                        .font(MacTheme.ui(13))
                        .foregroundStyle(MacTheme.bodyColor)
                    Text(L("关闭后，思考内容不再显示、也不再保存。"))
                        .font(MacTheme.ui(11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { showsThinking },
                    set: { showsThinking = $0; AIGenerationSettings.showsThinkingProcess = $0 }))
                    .labelsHidden()
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, MacTheme.settingsChoiceRowPaddingV)
        }
    }

    /// 「重置为推荐值」—— 存取点侧 `resetToDefaults` 一次复位全部，镜像跟着重读。
    private var resetRow: some View {
        HStack {
            Spacer(minLength: 0)
            Button(L("重置为推荐值")) {
                AIGenerationSettings.resetToDefaults()
                // 镜像从存取点重读（⛔ 别在这儿逐项手写默认值 —— 会与存取点漂移）。
                temperatureEnabled = AIGenerationSettings.temperatureEnabled
                temperature = AIGenerationSettings.temperature
                maxTokensEnabled = AIGenerationSettings.maxTokensEnabled
                maxTokens = Double(AIGenerationSettings.maxTokens)
                showsThinking = AIGenerationSettings.showsThinkingProcess
            }
            .font(MacTheme.ui(12))
            .buttonStyle(.plain)
            .foregroundStyle(MacTheme.linkText)
        }
    }
}

// MARK: - 右侧：一条自绘 slider

/// 「标题 + 当前值 + 自绘滑轨」一行（生成参数页专用）。
///
/// 🔴 为什么自绘而不用 SwiftUI `Slider`：原生 `Slider` 在 macOS 上是 AppKit 控件，
///    离屏渲染台照不出来（既有教训同 `MacSettingsChoiceRow` 那段）—— 验收图会
///    变成「黄条 + ⊘」，看不出「滑到哪一档」。自绘之后滑轨 / 填充 / 滑块都在图里。
/// ⚠️ 拖拽是 `DragGesture(minimumDistance: 0)` 打在整条滑轨上（`contentShape` 撑满）：
///    真机手势只能人手验（离屏渲染台投不出拖拽），但**静态图**能验「滑块位置对不对」。
private struct MacSettingsSliderRow: View {

    let title: String
    let range: ClosedRange<Double>
    /// 步长（温度 0.1 / 最大长度 256）—— 显示值与存取点都按它取整。
    let step: Double
    let format: String
    @Binding var value: Double
    /// 拖拽中实时回写存取点（拖动即存，与 iOS slider 行同口径）。
    let onChange: (Double) -> Void

    /// 取整到步长（显示与回写同源，⛔ 别显示浮点原值）。
    private var snapped: Double { (value / step).rounded() * step }

    /// 当前值在滑轨上的比例（0...1）。
    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((snapped - range.lowerBound) / span, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(MacTheme.ui(12))
                    .foregroundStyle(MacTheme.bodyColor)
                Spacer(minLength: 8)
                Text(String(format: format, snapped))
                    .font(MacTheme.ui(12))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(MacTheme.settingsCardBorder)
                        .frame(height: 4)
                    Capsule()
                        .fill(MacTheme.linkText)
                        .frame(width: fraction * width, height: 4)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(MacTheme.settingsCardBorder, lineWidth: 0.5))
                        .frame(width: 13, height: 13)
                        .offset(x: fraction * (width - 13))
                }
                .frame(height: 13)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let pct = min(max(drag.location.x / width, 0), 1)
                    let target = (range.lowerBound + pct * (range.upperBound - range.lowerBound))
                        .roundedToStep(step)
                    value = target
                    onChange(target)
                })
            }
            .frame(height: 13)
        }
    }
}

extension Double {
    /// 取整到步长的整数倍（slider 专用；与 `AIGenerationSettings` 的钳位各司其职）。
    fileprivate func roundedToStep(_ step: Double) -> Double {
        guard step > 0 else { return self }
        return (self / step).rounded() * step
    }
}

