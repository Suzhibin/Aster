//
//  RootView.swift
//  AsterMac
//
//  主界面骨架：`NavigationSplitView`（左栏会话列表 + 右栏聊天区）+ 一块**右侧网页面板**。
//
//  ⚠️ 窗口工具栏上那两颗（**搜索** + **网页开关**）都是挂在 `sidebar:` 那一列的 `.toolbar` 上，
//     位置与落点规则写在下面那段 `.secondaryAction` 注释里 ——
//     两者都**跟着侧栏走**：侧栏一收起来它们就一起消失（⌘F 因此另挂在 App 菜单里）。
//
//  ## 网页面板（点助手正文里的网址 → 会话页右侧滑出，2026-09-30）
//  它是挂在本视图上的 `.inspector`（`WebPageContentView`），**不是**第三个分栏、
//  也不是另开的窗口。三栏 `NavigationSplitView` 做不到「只在需要时出现第三栏」这件事，
//  完整取舍写在下面 `.inspector` 那一段注释里（含 `NavigationSplitViewVisibility` 三档表）。
//
//  ## 为什么是 NavigationSplitView 而不是自己拿 HStack 拼
//  它自带 Mac 该有的一切：侧栏可折叠（工具栏左上角那颗按钮）、拖拽分隔线调整宽度、
//  宽度状态由系统记忆。自己拼 HStack + DragGesture 复现这些要写不少代码，
//  而且拿不到「侧栏折叠」这种系统级行为。
//  ⚠️ `NavigationSplitView` 要求 **macOS 13+** —— 这也是包与 target 都定 14.0 的原因之一。
//

import SwiftUI
import AppKit
// 🔴 `AILanguageStore` 在 `AICore`（2026-10-13 接本地化后，本视图读它来当内容根身份）。
//    本工程开了 `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` ⇒ 用谁就显式 import 谁。
import AICore

struct RootView: View {
    @Environment(ChatModel.self) private var model

    // 🔴 面板宽度（2026-10-08 用户口径改成「与会话区**一样宽**」）：
    //    `面板宽 = (窗口宽 − 侧栏 260) / 2`（算法在 `MacTheme.webPagePanelHalfWidth`）。
    // ⚠️ 它喂的是 `inspectorColumnWidth` 的 **`min`** —— 因为 `.inspector` 打开时
    //    **只认 `min`、忽略 `ideal`**（2026-10-04 两个真窗口实测数据点，见
    //    本段开头那段实测记录）。⛔ 改回`ideal` = 面板又变回 340。
    // ⚠️ 名字里还留着 "Ideal" 是历史包袱，改名要连上面注释一起改，别只改一处。
    @State private var webPanelIdealWidth: CGFloat = MacTheme.webPagePanelIdealWidth

    /// **本视图所在的那个窗口**（由视图树里那颗 `HostWindowReporter` 喂进来）。
    /// 🔴 面板宽度跟随窗口量的是它，⛔ 不许用 `NSApp.mainWindow`（理由见 `HostWindowReporter`）。
    @State private var hostWindow: NSWindow?

    /// 「本视图这一层要不要重算」用的**语言计数**（2026-10-13 **第三版**）。
    ///
    /// 🔴 它的作用**只有一条**：`@State` 一变，SwiftUI 就重算 `RootView.body`。
    ///    本视图需要的重算**只有一处** —— 顶部 `pageTitle`（= `model.title`，而 `title` 是
    ///    **存储**属性，`L()` 那套观察机制救不到它，得靠 `languageDidChange()` 重算 + 本视图再读一次）。
    ///    其余所有文案（两栏里的）由 `L()` 自己的观察依赖负责，**与这里无关**。
    ///
    /// ☠️☠️ **它绝不喂给 `.id(...)`** —— 这一点是三版血泪换来的（成因见 `AILocalization.swift` 文件头）：
    ///    `.id` 挂在 `NavigationSplitView` 根 / 列上 ⇒ 撞工具栏分隔项断言（**点按钮崩 App**）；
    ///    挂在「带 `.toolbar` 的那一列的内容子树」里（哪怕挂到页面 body 最内层）⇒ 该列工具栏项的
    ///    hosting view 被拆掉后**不再回填** ⇒ 会话页右上那两颗（打电话 / 右侧页面）**当场消失**，
    ///    而 `toolbar.isVisible` / `visibleItems` 照样报 true（判据极易假绿）。
    ///    ⇒ **列的内容子树里一次身份变化都不许有**。
    @State private var languageTick: Int = 0

    var body: some View {
        // `@Observable` 的模型要拿到 `Binding` 得先包一层 `@Bindable` ——
        // sheet 的 `isPresented` 要的就是 binding。
        // ⚠️ 弹窗状态在**模型**里而不是这里的 `@State`：入口有两个（侧栏那颗按钮、
        //    App 菜单的 ⌘F），而菜单命令与视图之间没有层级可借（见 `ChatModel.isSearchPresented`）。
        @Bindable var model = model
        // ☠️ 必须**在 body 求值期**真读一次 `webPage` —— 理由见下面 `.inspector` 段里
        //    `hasWebPage` 那三行（`Binding` 的 get 闭包不跑在这里，读不到等于没依赖）。
        let hasWebPage = model.webPage != nil
        // 🔴 2026-10-02：面板的「**内容**」与「**显示**」是两个正交真值（`ChatModel` 里那两段）。
        //    用户要求「右上的按钮只切显示、内容常驻」—— 他开两个标签、点一下按钮收起、
        //    再打开时只剩一个标签，就是旧的「收起 = 销毁内容」造成的。
        //    ⚠️ 这个量同样必须在 **body 求值期**真读（同上面那条 ☠️ 的道理）。
        let isWebPagePanelShown = model.isWebPagePanelShown
        // 系统那一档：**有内容 且 显示中**。`.inspector` 与那颗开关都用它。
        let webPanelVisible = hasWebPage && isWebPagePanelShown
        // 详情列那颗「右侧页面」开关（`.toolbar` 里）也读这两个量 ——
        // ☠️ 同一条口径：`.toolbar` 的内容闭包**不是** body 求值期那一趟，
        //    在闭包里现读 `model.webPage` / `model.lastWebPageURL` = 观察依赖登记不上，
        //    症状是「模型里明明有页面、开关一动不动」。所以在这里先读好、再传进去。
        //    （这一段原来在 `ChatDetailView`，2026-09-30 随开关一起搬过来。）
        //
        // 🔴 2026-10-06：这里取的是「**给人看的那个名字**」，不再是 `url.host`。
        //    成因：**文件 URL 的 `host` 恒为 `nil`** ⇒ 只看 host 会把「上次看的是个文件」
        //    说成「什么都没看过」（而那颗开关点下去其实会**恢复那个文件**）。
        //    ⚠️ 口径与那两个账本对齐：网页给域名、文件给显示名（`lastPanelFileDisplayName`）。
        //    ⛔ 这段求值就在 body 里（别挪进 `.help` 的闭包）—— 同上那条 body 期读取。
        let lastPanelURL = model.lastWebPageURL
        let lastPanelLabel: String? = lastPanelURL.map { url in
            url.isFileURL
                ? (model.lastPanelFileDisplayName ?? url.lastPathComponent)
                : (url.host ?? url.absoluteString)
        }
        // 🔴 窗口标题栏那行字（2026-10-12 修用户报的「左上角 title 没有正确切换」）。
        //
        // ⚠️ 同样**在 body 顶层真读一次**（与上面 `hasWebPage` / `webPanelVisible` 一个口径）：
        //    这两个量下面要喂给 `NavigationSplitView` 的多个闭包（`detail:` 的内容、以及
        //    挂在整个 split 上的 `.navigationTitle`）—— 按本文件的统一做法**先读好再传进去**，
        //    以后谁把某处挪进「不求值在 body 那一趟」的闭包（`Binding` 的 get、`ToolbarItem`
        //    的内容闭包）也不会踩坑。
        // ⚠️ 标题的真值在 `ChatModel.title`（存储属性 + `refreshTitle()` 单漏斗，见它的注释）——
        //    这里**只转发**，⛔ 别在视图层自己拼（`isDocumentsShown ? "文档" : …`），
        //    那样又多一份口径。
        // ✅ 2026-10-12 已实测：这样读 + `.navigationTitle(pageTitle)` 挂 split 层，
        //    标题栏**逐态跟随**（`STARRY_ROOT_TITLE=1` 五态，见下面那条 `.navigationTitle` 的注释）。
        let showsDocuments = model.isDocumentsShown
        let pageTitle = model.title

        return NavigationSplitView {
            ConversationSidebar()
                // ☠️☠️ 2026-10-13 **第三版**：这里既没有 `.id(languageID)`、也没有 `.environment(...)`
                //    —— 两者都会让**本列的内容子树**整棵换掉，而 AppKit 会把挂在本列上的
                //    工具栏项（就是下面那颗放大镜）的 hosting view 拆掉、**且不再回填**。
                //    真窗口实测：`ToolbarItemHostingView` 从 `30x28` 缩成 `10x10`、`NSButton`
                //    子视图清零，而 `isVisible` / `visibleItems` 照样报 true（**极易假绿**）。
                //    ⇒ 文案重算改由 `L()` 自己的观察依赖负责，见 `AILocalization.swift` 文件头。
                // 侧栏宽度：给一个够放下「标题 + 时间」的区间，不让它被拖成一条缝
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 360)
                // 🔴 搜索入口**必须挂在这一列上**（而不是下面 `NavigationSplitView` 自己身上）。
                //
                // 两种挂法落点不同，真 App 场景探针实测过（工具栏项顺序）：
                // ```
                // 挂在侧栏列上 → [侧栏开合按钮, 我的搜索按钮, 〈分隔线〉, …]   ← ✅ 要的
                // 挂在整体上   → [侧栏开合按钮, 〈分隔线〉, 我的搜索按钮, …]   ← ❌ 跑到右半区
                // ```
                // 分隔线就是工具栏上那道把「侧栏区」与「内容区」分开的竖线。挂整体上时，
                // 搜索按钮落在**内容区**里，看起来像聊天页自己的按钮（第一版就是这么被否掉的：
                // 「应该在菜单栏上方，和隐藏菜单栏按钮平齐」）。
                // 挂在侧栏列上，它就与系统那颗侧栏开合按钮**同格、紧挨着** —— 也正是原来
                // 「新建对话（＋）」占的那个位置。
                //
                // ⚠️ 代价：侧栏收起后这一格可能跟着消失 → **⌘F 因此挂在 App 菜单上**
                //    （`AsterMacApp.commands`），不依赖这颗按钮在不在。
                .toolbar {
                    // 🔴 `placement: .secondaryAction` —— 这个值是**量出来的**，不是猜的。
                    //
                    // 挂在侧栏列上的工具栏项，四种 placement 在同一窗口里实测（真 App 场景探针）：
                    // ```
                    // 侧栏开合按钮            x= 91.5  w=33.5
                    // .secondaryAction       x=133.0  w=30.0   ← ✅ 紧贴开合按钮右侧（隔 8pt）
                    // .navigation            x=213.5  w=30.5   ← ❌ 落在**本区尾端**（离按钮 122pt）
                    // .automatic             w=0                ← ❌ 根本不布局（不可见）
                    // .primaryAction         w=0                ← ❌ 同上
                    // ```
                    // ⚠️ **2026-09-30 的两条反例（搬「网页」开关时测到，都别当成矛盾）**：
                    //   ㈠ 上表那两行 `w=0` 成立的前提是「这一列上**只有它一个** item」。同一列上
                    //      **已经有**一个 `.secondaryAction` 项时，再挂一个 `.primaryAction` **不再 w=0**
                    //      —— 系统会插一个 `NSToolbarFlexibleSpaceItem` 把它顶到**侧栏区右端**：
                    //      `[侧栏开合, 搜索, NSToolbarFlexibleSpaceItem, 网页开关, splitViewSeparator]`。
                    //   ㈡ ☠️☠️ **这一格里所有东西必须装进同一个 `ToolbarItem`** —— 见下面那段。
                    // 关键一条：`.navigation` 的 x **随侧栏宽度走**（侧栏 200 时 213.5、260 时 273.5），
                    // 也就是说它贴的是分隔线那一端，不是开合按钮那一端 —— 拖宽侧栏它会越跑越远。
                    // 用户要的是「和隐藏菜单栏按钮平齐」（也就是原来那颗「新建对话（＋）」的位置），
                    // 只有 `.secondaryAction` 落在那儿，而且不随侧栏宽度漂移。
                    // ⛔ 别再改回 `.navigation`（先后被否过两次，一次是挂在整体上、一次就是它）。
                    //
                    // ── ☠️☠️ 2026-09-30 踩出来的坑（写在这，别再绕）：**这同一列上若加第二个控件，
                    //    必须装进同一个 `ToolbarItem`（用 `HStack`）** ── 否则第二个会被系统整条收起。
                    // 当天曾把「网页」开关（原在**详情列** `.primaryAction` = 窗口最右）搬进这一格，
                    // 第一版写成**两颗并列的 `ToolbarItem`**（搜索 + 开关，都是 `.secondaryAction`），
                    // 真窗口探针实测：
                    // ```
                    // toolbar.items        = [侧栏开合, 搜索, 网页开关, splitViewSeparator]   ← 看着"在"
                    // toolbar.visibleItems = [侧栏开合, 搜索]                                 ← ☠️ 开关**根本没显示**
                    // 开关那一项：item.view = 0×0 · item.isVisible = false
                    // ```
                    // ⚠️ 而「开关的 identifier 在不在 toolbar.items 里」那种判据**一直是绿的**（很会骗人）。
                    // ⚠️ 与**控件形态完全无关**：`Toggle(.switch)` / `Toggle(.button)` /
                    //    与放大镜**逐字同构的 `Button`** 三种写法**全都** `isVisible = false` ——
                    //    是「同一列上第二个 `.secondaryAction` 项排不下、被系统整条收起」这件事本身。
                    //    ⇒ 正解：**一个 `ToolbarItem` 里放一个 `HStack`**；间距要自己给（`spacing: 6`），
                    //      系统只在**项与项之间**加默认间距，同一个 item 内部不会自动分开。
                    // 🔴 **但用户当晚再次改口**：网页开关**还是放回会话页导航右侧**（= 详情列 `.primaryAction`
                    //    = 窗口最右），只是**图标换成 `sidebar.left`**（与左侧菜单栏那颗侧栏开合按钮同款）。
                    //    ⇒ 它现在挂在下面 `detail: { ChatDetailView().toolbar {…} }` 里（见 `webPageToggle`），
                    //      这一格（侧栏列）就只剩搜索了。所以上面那条「装一个 ToolbarItem」的规矩，
                    //      是留给「以后谁要在侧栏列加第二个控件」的，不是当前状态。
                    ToolbarItem(id: "sidebarLeadingActions", placement: .secondaryAction) {
                        // ── 搜索（2026-09-22 起就在这一格）──────────────────────────
                        Button {
                            model.isSearchPresented = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .help(L("搜索历史对话（⌘F）"))
                        // ⛔ 这里**不要**再写 `.keyboardShortcut("f")`：⌘F 已挂在菜单上，
                        //    两处都注册同一个键位会让系统二选一（有时两边都不触发）。
                        // ⚠️ 2026-09-30 当晚：网页开关**一度**被搬进这一格（与搜索同装一个
                        //    ToolbarItem），但用户最终改口 —— 它**还是放在会话页导航右侧**（详情列
                        //    `.primaryAction` = 窗口最右），图标换成 `sidebar.left`（与左侧菜单栏
                        //    那颗侧栏开合按钮同款）。所以这一格现在只剩搜索。
                    }
                }
        } detail: {
            // 🔴 2026-10-10：主区域**二选一** —— 「文档」页 vs 会话页。
            //    用户拍板原话：「主区域整页替换，但是需要新建一个页面，**不要在对话页面继续开发**」
            //    ⇒ 文档页是独立一页（`DocumentsView`），⛔ 别把这块搬进 `ChatDetailView`
            //      当一段条件视图，也别做成 sheet。
            // ⚠️ 判据用 body 顶层读好的 `showsDocuments`（见上面那两行 `let`）——
            //    与 `hasWebPage` / `webPanelVisible` 同一个口径，别在这里现读模型。
            // ✅ 2026-10-12 实测：点「文档」主区域**确实换页**（`STARRY_ROOT_TITLE=1` 五态 +
            //    截图，收尾停在文档页）。
            //
            // 🔴 2026-10-13 **第三版**：这一层（以及两个页面内部）**都没有 `.id` 了**。
            //    前两版在这里 / 在页面 body 里挂过 `.id(languageID)`，各撞一个结构性 bug：
            //    挂根 ⇒ 撞工具栏分隔项断言（点按钮崩 App）；挂到这一列的内容子树里（**挂多深都一样**）
            //    ⇒ 下面那颗 `chatDetailTrailingActions` 的 hosting view 被拆掉后不再回填
            //    （会话页最右那两颗 + 文档页那颗 ✕ 一起消失，实测见 `AILocalization.swift` 文件头）。
            //    ⇒ 文案重算改由 `L()` 自己的观察依赖负责，**代价也没了**（切语言不再重建页面，
            //      滚动位置与选择态都保住）。
            Group {
                if showsDocuments {
                    DocumentsView()
                } else {
                    ChatDetailView()
                        // 🔴 网页开关 = 会话页导航**最右侧**（`.primaryAction` 落在详情列 = 窗口最右）。
                        // 2026-09-30 当晚用户改口两次：先说「搬到红绿灯旁（侧栏列）」、又改回
                        // 「还是放会话页导航右侧，但图标和左侧菜单栏那颗（红绿灯旁）一样」。
                        // ⇒ 落点 = 详情列最右；图标 = `sidebar.left`（与系统侧栏开合按钮同款）。
                        .toolbar {
                            // 🔴🔴 会话页导航最右这一格现在装着**两颗**（打电话 + 右侧页面），
                            //    必须装进**同一个 `ToolbarItem`**（用 `HStack` 排）——
                            //    这是本文件上面那段实测过的坑：同一列上放**两个** toolbar item 时，
                            //    系统会把第二个**整条收起**（实测 `isVisible = false`、`item.view` 是 0×0），
                            //    而「identifier 在不在 `toolbar.items` 里」那种判据**一直是绿的**（很会骗人）。
                            //    ⚠️ 间距要自己给（`spacing: 6`）：系统只在**项与项之间**加默认间距，
                            //    同一个 item 内部不会自动分开。
                            ToolbarItem(id: "chatDetailTrailingActions", placement: .primaryAction) {
                                HStack(spacing: 6) {
                                    // 左边那颗（2026-10-12 新增）：「打电话」→ 打开一个独立窗口
                                    voiceCallButton
                                    // 右边那颗：右侧页面开关。⚠️ 参数是**在 body 求值期读好的**
                                    //（见上面那三行 let）—— 这里（toolbar 的内容闭包）**不是**
                                    // body 求值期，在闭包里现读 `model.webPage` 等于没登记观察依赖，
                                    // 症状是「模型明明变了、这颗按钮一动不动」。
                                    webPageToggleButton(visible: webPanelVisible,
                                                        hasContent: hasWebPage,
                                                        lastPageLabel: lastPanelLabel)
                                }
                            }
                        }
                }
            }
            // ☠️☠️ **这里曾经有一句 `.environment(\.aiLanguageID, languageID)`，2026-10-13 第三版删掉**
            //    —— 它只灌给 `detail:` 这一侧，侧栏读到的永远是环境**默认值** ⇒ 侧栏那半边
            //    切语言时根本不动（而探针当时还报了 PASS，因为侧栏那格工具栏项「没被碰过」）。
            //    现在两栏都不需要它：文案重算由 `L()` 自己的观察依赖负责（见文件头那段）。
            //    ⛔ 别再加回来 —— 往列上灌环境 = 让整列子树失效，同样会牵动该列的工具栏项。
        }
        // 🔴 窗口标题栏那行字（= 主区域左上角那个标题）。
        //
        // ⚠️ 参数是 **body 顶层读好的 `pageTitle`**，⛔ **别改成 `.navigationTitle(model.title)`**
        //    之外的花样 —— 尤其别在视图层拼（`model.isDocumentsShown ? "文档" : …`）：
        //    那样等于把「当前该显示什么标题」这个口径复制到视图层，拼错了症状与本 bug 一样。
        //    口径单点在 `ChatModel.title`（存储属性 + `refreshTitle()` 单漏斗）。
        // ✅ **挂在这一层（`NavigationSplitView` 自己身上）是实测可用的** ——
        //    `STARRY_ROOT_TITLE=1` 真窗口探针五态实测：标题栏**逐态跟随**模型
        //    （①渲染夹具会话 ②第二个会话 ③文档 ④第二个会话 ⑤文档，与 `模型.title` 逐字一致）。
        // ⚠️ 2026-10-12 曾一度把它挪进 `detail:` 的两个分支，理由是「挂 split 层只在建窗那一拍
        //    生效」——**那个结论是错的**，它来自一台「观察追踪被阉掉」的验收台（见下面那段，
        //    以及 `render_mac_ui.sh` 里 `ChatModel` 那组手工补丁）。补好追踪后**两种挂法都正常**，
        //    ⇒ 回到原挂法（改动面最小）。
        .navigationTitle(pageTitle)
        // ⛔ 工具栏上只有**两颗**（「搜索」+「网页」开关）+ 系统那颗侧栏开合 —— 原来那颗
        //    「新建对话（＋）」已经搬到侧栏里当「新对话」了（同一个入口不摆两处），
        //    别为了「工具栏有点空」加回来。
        // 「弹出」= sheet：临时面板，Esc 可关，不占第二块工作区。
        // 环境里的 `ChatModel` 会**自动**传进 sheet，搜索页不需要另接数据线。
        .sheet(isPresented: $model.isSearchPresented) {
            MacSearchView()
        }
        // 🔴 **助手回复里的网址 → 会话页右侧滑出网页面板**（2026-09-30）。
        //
        // ## 用户的话分两句（第二句是第一版的返工）
        // ① 「豆包这种网页链接是可以点击的，点了在右侧又打开一个窗口显示网页」
        //    → 第一版按字面做成了**独立 `NSWindow`**（`WebPageWindow`，贴主窗右侧开出来）。
        // ② 「新打开的网页**不是一个新窗口**，而是在会话页面右侧又出现的窗口」
        //    → 要的是**嵌在 App 窗口里、与会话并排**，不是在桌面上多一个平级窗口。
        //
        // ## 🔴 为什么不用三栏 `NavigationSplitView`（用户点名问过）
        // 三栏**支持**（macOS 13+ 就有 `sidebar:content:detail:` 的写法），但
        // `NavigationSplitViewVisibility` **只能收起前导列**，三档全列在下面：
        // | 档位 | 效果 |
        // |---|---|
        // | `.all` | 侧栏 + 中栏 + 尾栏 |
        // | `.doubleColumn` | **收侧栏**，留中栏 + 尾栏 |
        // | `.detailOnly` | 只留尾栏 |
        // ⇒ **没有「留侧栏 + 中栏、收尾栏」这一档**。硬用三栏的后果是：
        //   ① 网页没打开时尾栏是一条**常驻的空条**（用户还能把它拖宽，宽度还会被系统记住）；
        //   ② 把 split view 写成 `if 两栏 else 三栏` 又更糟 —— 整个 `ChatDetailView`
        //      （连同滚动位置、输入草稿、选择态）会被**重建**。
        // ⇒ 正解是 `.inspector`：macOS 14 起系统自带的**尾部面板**，语义恰好是
        //    「会话页右侧滑出的一块」，可拖拽调宽、自带动画，而且**只在打开时才存在**。
        //    `NavigationSplitView` 保持两栏不动 —— 侧栏那颗放大镜的落位是量出来的
        //    （见上面 `.secondaryAction` 那段），不为了多一栏去动它。
        //
        // ## ⚠️ 为什么挂在**根**上、以及那条 `hasWebPage`
        // 挂在 `RootView`（整棵树的根）而不是某一个 `Text` 上：链接可能出现在助手正文、
        // 以后也可能出现在别处，逐处挂必然漏一处；这是 **App 级的产品口径**
        // （「点链接不离开 App」），本来就该在根上表达一次。
        // ☠️ `hasWebPage` 这个局部量**不是装饰**：`Binding(get:set:)` 的闭包**不在**
        //    body 求值期执行，光写 `model.webPage != nil` 进去**不会**登记观察依赖
        //    —— 表现是「`openWebPage` 改了模型、界面一动不动」（`@Observable` 的依赖
        //    只认 body 求值期真读到的属性）。所以必须在这里真读一次。
        // 🔴 2026-10-02 起判据是**两个真值**：`webPage`（内容）+ `isWebPagePanelShown`（显示）
        //    ⇒ 就是上面那个 `webPanelVisible`。**收起不再销毁内容**，所以「系统让它收起」
        //    只走 `hideWebPagePanel()`（见 `webPanelBinding`）。
        .inspector(isPresented: webPanelBinding(visible: webPanelVisible)) {
            if let page = model.webPage {
                WebPageContentView(
                    model: page,
                    onClose: {
                        // 🔴 面板那颗 ✕ = 关**当前标签**；关掉的若正好是**最后一个**标签，
                        //    整块右侧页面一起收起（用户 2026-10-06 口径）。
                        // ⚠️ 这里与 `closeWebPage()` 是同一件事（**连内容一起放掉**）——
                        //    与右上角那颗开关**刻意不同**：用户明确关掉了最后一个标签
                        //    = 连内容都不要了，再留着空面板反而是「关不掉」。
                        //    收起显示那条路是 `hideWebPagePanel()`。
                        // ☠️ 判据在 `ChatModel.closePanelTab(_:)` 那**一处** —— 标签条上那组
                        //    ✕ 也走它（那条路绕过 SwiftUI、直落 AppKit 桥），
                        //    ⛔ 别在这里再判一遍「空没空」，两处迟早漂移。
                        model.closePanelTab(page.activeTabIndex)
                    }
                )
                // 🔴 面板宽度 = **与会话区等宽**（2026-10-08 用户口径）。
                //    宽度写在 **`min`** 上 —— ☠️ `.inspector` 打开时只认 `min`、忽略 `ideal`
                //    （见上面 `webPanelIdealWidth` 那段与 `MacTheme` 面板列宽那段实测记录）。
                //    ⛔ 别改回 `ideal:`，那样面板会退回 340pt。
                //⚠️ 用户仍可用拖分隔条改宽；改了之后系统就用他的值，不再跟随窗口重算
                //    （这是 `.inspector` 的标准行为，不是 bug）。要恢复跟随：收起面板再打开。
                .inspectorColumnWidth(min: webPanelIdealWidth,
                                      ideal: webPanelIdealWidth)
                // 🔴 标签条 = **inspector 列自己的工具栏项**（2026-09-30 三改定型）。
                //
                // 为什么绕这么远（每条都实测过，别再走回头路）：
                // ① 标签行靠负 padding 画进窗口顶栏带 ⇒ **看得见、点不着** ——
                //    真窗口 hitTest 探针实测：带内**全宽**（最右 24pt 到距右 600pt）命中的
                //    全是 `NSToolbarView ⊂ NSTitlebarView ⊂ NSTitlebarContainerView`，
                //    一个像素都落不到下面的 SwiftUI 内容上。那条带归 AppKit 窗口管，
                //    「画得上去」和「点得着」是两回事。
                // ② 挂详情列 `.toolbar` ⇒ 点得着，但落在**面板左侧**（详情区尾端被
                //    inspector 挤到面板左边）—— 位置不对。
                // ③ 挂 **inspector 内容自己**（就是这里）⇒ 系统把它放进**面板上方那格
                //    工具栏区**：位置对（标签在最上面那条带里）+ 点得着（真工具栏项）。✅
                //    ⛔ 面板一关，inspector 内容连同这一项一起消失，不用另写清理。
                .toolbar {
                    // 🔴🔴 2026-10-02：**项本身要跟着「显示」那个真值挂 / 摘**。
                    //
                    // 用户报的现象（原话）：「会话页面右上角按钮 点击收起 web 页面，
                    // web 页上的标签会跟随显示到会话页面」。
                    // 根因：`.inspector` 收起**只把内容视图移出可见区**（这正是「内容常驻」
                    //      的天然机制，2026-10-02 那条需求要的就是它），但它**不负责**把
                    //      inspector 注册的工具栏项一起收走 —— 那一项还挂在窗口工具栏上，
                    //      而面板那格已让给了会话页 ⇒ 标签看起来「跟随」到了会话页的导航上。
                    // ⇒ 闸门：只在 `isWebPagePanelShown`（**body 求值期读到的**真值，见上面
                    //    `let isWebPagePanelShown = …`）为 true 时才挂这一项。
                    //    ⛔ 别改成「挂常驻 + 在 AppKit 桥里 `isHidden`」：工具栏项是系统
                    //       布局的，光藏视图会让那一格**留个空位**（会话页导航右边仍缺一块）。
                    //    ⚠️ 这个 `if` 属于 **body 那一层**（不是 `ToolbarItem` 的内容闭包），
                    //       所以不受「内容一次性快照」那条坑的影响 —— 那条只管闭包内部。
                    if isWebPagePanelShown {
                        // 🔴🔴 标签条是 **AppKit 桥**（`WebPageTabsBarBridge`，2026-10-02 定案）：
                        //    `ToolbarItem` 的 SwiftUI 内容是一次性快照 —— `@ObservedObject` /
                        //    `.id(指纹)` / `TimelineView` 时钟 / 项 id 带指纹，五轮实验**全带不动**
                        //    （模型 2 个标签，条上永远只画最初那 1 个胶囊）。
                        //    ⇒ 桥在 `makeNSView` 时自己订阅模型、直接重建 AppKit 子视图，
                        //      完全绕开 SwiftUI 更新管线。完整实验记录见 `WebPageTabsBarBridge` 头。
                        ToolbarItem(id: "webPageTabs", placement: .primaryAction) {
                            WebPageTabsBarBridge(model: page, onCloseTab: { index in
                                // 🔴 与上面导航条那颗 ✕ **同一个落点**（2026-10-06）：
                                //    关掉的若是**最后一个**标签 ⇒ 整块右侧页面一起收起。
                                //    ☠️ 这条闭包是**必须**的 —— 标签条是 AppKit 桥，它的 ✕
                                //    直落 `WebPageModel`、绕过 SwiftUI，接不上 `onClose`。
                                model.closePanelTab(index)
                            })
                                // 🔴 这一层**只报下限**（不报 `maxWidth`）：宽度上限由
                                //    `WebPageTabsBar` 用**面板实测列宽**算
                                //    （`WebPageModel.panelWidthRelay`，由 `WebPageContentView` 喂）。
                                //    ☠️ 为什么上限不能落在 SwiftUI 这层：`ToolbarItem` 内容在
                                //    macOS 上是**一次性快照**（见下面那段 AppKit 桥的来由）——
                                //    窗口 / 分隔条一动这里不会重算，写死一个上限等于拖一下就失效。
                                //    AppKit 那侧走的是订阅，什么时候变都跟得上。
                                .frame(minWidth: MacTheme.webPageTabStripMinWidth)
                        }
                    }
                }
            }
        }
        // 🔴 面板宽度跟随窗口（2026-09-30 当晚加）：窗口缩放时重算理想列宽。
        //    ⚠️ 算法是 `MacTheme.webPagePanelHalfWidth(windowWidth:)` 那**一份** ——
        //    ⛔ 别在这里再抄一遍公式。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in
            guard let w = hostWindow?.frame.width, w > 0 else { return }
            let next = MacTheme.webPagePanelHalfWidth(windowWidth: w)
            if webPanelIdealWidth != next { webPanelIdealWidth = next }
        }
        // 🔴 把「本视图所在的那个窗口」登记下来（面板宽度跟随窗口量的是它）。
        //    ☠️☠️ **不许用 `NSApp.mainWindow`**（2026-09-30 实测踩穿）：本 App 有别的窗口
        //    （媒体预览窗 / 设置窗），而且 root 验收台的夹具窗口**根本不是** `mainWindow`
        //    （探针实测 `NSApp.mainWindow === 夹具窗口` = **false**）。
        //    与 `ComposerWindowHint` 同一条铁律：**窗口由视图来喂，别去猜**。
        .background(HostWindowReporter { window in
            // ⚠️ 只在**换了窗口**时写 state：无脑写会在「改 state → 重排 → 再回调」之间空转。
            if hostWindow !== window {
                hostWindow = window
                // 🔴 窗口一认出来就按它把面板理想宽算一遍 —— 否则「App 起来后没缩放过窗口」
                //    这条路上，面板会用 `webPagePanelIdealWidth`（480）那个初值，
                //    窗口若不是 1120 就偏了。
                //    ⚠️ 形参是 `NSWindow?`（视图从窗口树上摘下来时就是 nil）⇒ 必须走可选链。
                if let w = window?.frame.width, w > 0 {
                    let next = MacTheme.webPagePanelHalfWidth(windowWidth: w)
                    if webPanelIdealWidth != next { webPanelIdealWidth = next }
                }
            }
        })
        // SwiftUI 的 `Text` 里带 `.link` 的 run 被点击时会走**这个环境值**，
        // 默认实现是 `NSWorkspace.open`（跳系统浏览器、离开 App）。
        // 这里把它改成在会话页右侧滑出我们自己的网页面板。
        // ⚠️ 非 http(s) 一律 `.systemAction` **交回系统**：`mailto:` / `tel:` 有自己的处理方
        //    （`ChatModel.openWebPage` 里还有第二道同样的闸）。
        .environment(\.openURL, OpenURLAction { url in
            switch url.scheme?.lowercased() {
            case "http", "https":
                model.openWebPage(url)
                return .handled
            default:
                return .systemAction
            }
        })
        // 2026-10-12 修用户报的「左侧菜单切换 开启AI / 文档 / 我的对话，会话页面左上角的
        // title 没有正确切换」。**真正的毛病只有一个**（在业务层，不在这里）：
        // ① **`ChatModel.title` 当时是计算属性**，读的是**非 `@Observable`** 的 `AIChatManager`
        //    ⇒ 观察依赖登记不上 ⇒ **`RootView.body` 压根不重算** ⇒ 标题永远停在第一拍；
        //    而且它当时的口径**不认页**（停在文档页仍报会话名）。
        //    ⇒ 已改成**存储**属性 + `refreshTitle()` 单漏斗（含「文档页 → 文档」的页感知口径）。
        // ⚠️ 上面那条 `.navigationTitle(pageTitle)` 挂在**这一层（split）**是**实测可用**的
        //    （即修好 ① 之后不需要动它）；详细实测记录写在它的注释里。
        //
        // ☠️☠️ **排查这件事时踩的最大一个坑，写在这里免得重踩**：真窗口探针一开始**五态全不动**
        //    （截图里主区域还停在会话页），看起来像「`RootView` 根本没订阅模型」，一度怀疑到
        //    「`@State` 注入了两个实例」「App 未激活」上去（都验过，**都不是**：`ObjectIdentifier`
        //    逐态相同、`isActive` 与重算无关）。
        //    **真因是验收台把观察追踪阉了**：`render_mac_ui.sh` 不能展开 `@Observable` 宏，
        //    靠一份**手工清单**给 `ChatModel` 的每个存储属性补 `access/withMutation`
        //    —— 而 `isDocumentsShown` / `title` **不在那份清单里** ⇒ 探针里读这两个属性
        //    登记不上依赖 ⇒ `RootView.body` 全程只求值 2 次。
        //    ⇒ 分辨「验收台假象」与「真 bug」**只有一个判据**：往 `body` 里插打点数次数
        //      （只跑 1~2 次 = 验收台缺补丁；跑很多次而标题栏不动 = 才是真的挂错层）。
        //    ⚠️ 新增任何一个 `@Observable` 的存储属性、且**渲染台里有视图读它**，
        //      就必须回去给 `render_mac_ui.sh` 补一条 —— 漏了就是整台渲染台**静默变砖**。
        // 出错 / 截断 / 上下文裁剪的提示条，浮在内容之上
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastBar(text: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
        // 🧪 `STARRY_CALL_UI=1` ⇒ 首屏落地后自动开一次「打电话」窗口（见 `openIfRequested`）。
        //    ⛔ 只在 `#if DEBUG` 内实现，Release 里这个方法体是空的 —— 调用点不用再包一层。
        .onAppear {
            MacVoiceCallWindowCenter.shared.openIfRequested(chatModel: model)
        }
        // 🔴 语言一变，本视图要做的**只有两件收尾**（2026-10-13 **第三版**定案）。
        //
        // ## 为什么这里**不再**有「重算」这一拍
        // 前两版都在这一拍里换视图身份（`.id(...)`）去逼所有文案重算，结果各撞一个结构性 bug
        // （点按钮崩溃 / 工具栏项消失，见下面那整段）。**现行机制不在这里**：
        // `L()` 自己会去读 `AILanguageRevision`（见 `AILocalization.swift`），
        // 于是「body 里调过 `L()`」的视图**各自**登记到那条依赖、切语言时自己重算
        // ⇒ 文案跟着翻这件事**不需要任何人为动作**。
        //
        // ## 那本拍还剩什么
        // ① `model.languageDidChange()` —— `title` 是**存储**属性（`refreshTitle()` 单漏斗），
        //    里面存的是上一档语言那份 `L()` 结果，观察依赖救不到它，必须让模型自己重算；
        // ② `MacMainMenuLocalizer.scheduleApply()` —— **系统菜单栏**的标题不是 SwiftUI 出的
        //    （工程没有本地化声明 ⇒ AppKit 按开发区 `en` 给），只能事后就地改标题。
        // ⚠️ 另加一个 `languageTick` 自增，纯粹是为了让**本视图**重算一次 —— 因为
        //    上面①改的是模型的**存储**属性（模型是 `@Observable`，但 `title` 的观察依赖只在
        //    body 里读过它才算登记；本视图确实读了，可 `didChange` 与「模型变更」是两件事，
        //    显式自增一个 `@State` 最省心、也最不会误伤）。⛔ 它**不喂给任何 `.id(...)`**。
        .onReceive(NotificationCenter.default.publisher(for: AILanguageStore.didChange)) { _ in
            model.languageDidChange()
            languageTick &+= 1
            MacMainMenuLocalizer.scheduleApply()
        }
        // 🔴 字号档位变化也要刷一遍菜单栏（2026-10-15 用户原话：「要把本地的文本
        //    比如菜单、设置内的文字大小同时改变」）。SwiftUI 那边的 chrome 靠
        //    `AIFontSizeRevision` 的观察依赖自动重算（`MacTheme.ui(...)` 里登记），
        //    **唯独菜单栏是 AppKit 的**，没有任何观察机制 ⇒ 只能在这里手动再 apply 一次。
        // ⚠️ 只需要单次 `apply()`（不像语言那样要跑三拍）：改字号不重建 `NSMenu`，
        //    没有「被 SwiftUI 重建盖掉」的竞态。
        .onReceive(NotificationCenter.default.publisher(for: AIFontSizeStore.didChange)) { _ in
            MacMainMenuLocalizer.apply()
        }
        // 启动也来一遍（那几张菜单在窗口出现之前就建好了，`onAppear` 这一拍拿得到）。
        .onAppear {
            MacMainMenuLocalizer.scheduleApply()
        }
        // ─────────────────────────────────────────────────────────────────────────
        // 🔴🔴 **切语言为什么曾经要「换身份」，以及为什么现在不许换**（三版，⛔ 别再走回头路）
        //      （2026-10-13，用户连着报了两条：①「点会话页右上那颗按钮 **崩溃**」
        //        ②「切完语言，会话页右上那**两颗按钮会消失**」）
        //
        // ## 第一版（错）：`.id(AILanguageStore.resolved.rawValue)` 挂在**根**上
        // 挂在 `NavigationSplitView` 自己身上。后果：切完语言后**第一次模型变更**会让
        // `body` 重算、`id` 跟着翻 ⇒ `NavigationSplitView` 连同它往窗口上注册的
        // **工具栏分隔项**被整棵拆掉、并在同一拍里重建。AppKit 直接断言失败
        // （真窗口探针 + 探针内的异常钩子取到的原文，逐字如下）：
        // ```
        // NSInternalInconsistencyException
        //   Cannot unregister separator item because it was not previously successfully registered
        //   NSAssertFile: NSWindowSectionController.m   NSAssertLine: 585
        // ```
        // 进程拿到 `EXC_BREAKPOINT / SIGTRAP`（AppKit 的 `_crashOnException:`），
        // 对用户就是「点一下按钮 App 直接没了」。
        //
        // ## 第二版（也是错的）：`.id` 挪到**两栏的内容**上
        // 不崩了，但 `.toolbar` 挂在**同一个节点**上 ⇒ 那一格工具栏项的 `hosting view`
        // 被 AppKit 拆掉之后**不再回填**。真窗口实测（`STARRY_ROOT_I18N=1`）：
        // ```
        // 切之前：_ViewList_View 69x28 ∧ SwiftUIAppKitButton 41x40 ∧ SwiftUIAppKitButton 45x40
        // 切之后：_ViewList_View 10x10        ← 一颗子视图都不剩（两格一起完蛋）
        // ```
        // ☠️ 而且**判据极易假绿**：identifier 还在 `toolbar.items` 里、还在 `visibleItems` 里、
        //    `isVisible` 也还是 `true` —— 只有「那一格里有几颗 `NSButton`」数得出来。
        //
        // ## 第三版 A（也错的）：`.id` 下沉到「各页自己的内容根」+ 环境值把档位灌下去
        // 以为「挂得够深就不会碰工具栏」。真窗口实测把它否掉了，而且暴露出**两件事**：
        // ```
        // I18NTOOL 切之前 [chatDetailTrailingActions] 里面的按钮数=2 期望=2 各自尺寸=["41x40","45x40"]
        // I18NTOOL 切后    [chatDetailTrailingActions] 里面的按钮数=0 期望=2 各自尺寸=[]
        // I18NTOOL 切后    [sidebarLeadingActions]     里面的按钮数=1 期望=1   ← ⚠️ 见下
        // ```
        // ① **结论一：身份变化只要落在一列的内容子树里（挂多深都一样），那一列的工具栏项就完蛋。**
        //    会话页那两颗照样没救。
        // ② ⚠️ 侧栏那格看着「活着」，**不是**因为挂得深，而是因为它**压根没被碰过** ——
        //    `.environment(\.aiLanguageID, …)` 当时只灌给了 `detail:` 那一侧，侧栏读的是
        //    环境**默认值**（= 首次求值那一档）⇒ 它的 `.id` 从来没翻过。
        //    抓包图（`root_i18n_lang.png`，切完语言、还没碰模型那一拍）把这件事照得很清楚：
        //    **主区域已是英文**（`What can I help you with today?`）、**侧栏还是中文**
        //    （「开启 AI / 文档 / 我的对话」）⇒ 那个「PASS」是**假绿**。
        //
        // ## 现行（第三版 B）：**一次身份变化都不做**，改用「让每个视图自己登记依赖」
        // `L()` 内部读一次 `AILanguageRevision.shared.value`（手写 `Observable` 一致性，
        // 不是 `@Observable` 宏 —— 渲染台展不开宏），SwiftUI 的 body 求值天然被
        // `withObservationTracking` 包着 ⇒ **每个渲染过文案的视图各自重算**，
        // 深度不限、也不需要谁去「制造」重算。于是：
        //   · 窗口级 AppKit（工具栏 / 分隔项 / 分栏）**纹丝不动** ⇒ 不再崩、也不掉按钮；
        //   · 侧栏不再依赖「环境值有没有灌到」⇒ 不会出现上面那种假绿。
        // 📖 完整铁律 + 三版实测数据在 `AILocalization.swift` 文件头（⛔ 别只读这里）。
        //
        // ⚠️ 可机械复验：`.workbuddy/scripts/render_mac_ui.sh` 的 `STARRY_ROOT_I18N=1`
        //    —— 它切完语言截一张图（侧栏必须已是新语言）· 数两格工具栏项里的按钮数
        //    （必须与切之前一样）· 再点那颗按钮（必须不崩）· 顺带判系统菜单栏跟没跟上语言。
        // ─────────────────────────────────────────────────────────────────────────
    }

    /// 会话页导航那颗「打电话」：打开**独立窗口**的语音对话页（2026-10-12）。
    ///
    /// 🔴 它不 push 一页、不是 sheet、也不占右侧面板 —— 通话是"会持续几分钟、且与聊天并读"
    ///    的一件事（参考图那个窗口本身就是独立窗口）。完整取舍见 `MacVoiceCallWindow` 文件头。
    /// ⚠️ 同时只开一个：再点一次是把已经开着的那扇**提到前面**（判据在中心单例里，
    ///    别在这里再判一遍 —— 两处必然漂）。
    private var voiceCallButton: some View {
        Button {
            MacVoiceCallWindowCenter.shared.open(chatModel: model)
        } label: {
            Image(systemName: "phone.fill")
        }
        .help(L("打电话（与 AI 语音对话，独立窗口）"))
    }

    /// 会话页导航最右侧那颗「右侧页面」开关。
    ///
    /// ⚠️ 三件事**必须**保持原样（每一条都有来历，见调用处那段注释）：
    /// ① `Binding` 的 `get` 读的是**传进来的** `visible`（= body 求值期读好的那个值），
    ///    ⛔ 别在闭包里现读 `model.webPage` / `model.isWebPagePanelShown`；
    /// ② `set(false)` 只**收起显示**（`hideWebPagePanel()`），**不销毁内容** ——
    ///    用户开好的标签在他"挪开一下"之后必须还在；
    /// ③ **没有 `.disabled`** —— 右侧空着时它正是唯一能凭空开出一页的入口
    ///    （点下去给**起始页**）。契约里有一条反向断言专门钉这件事。
    private func webPageToggleButton(visible: Bool,
                                     hasContent: Bool,
                                     lastPageLabel: String?) -> some View {
        Toggle(
            isOn: Binding(
                get: { visible },
                set: { wantsVisible in
                    if wantsVisible {
                        model.showWebPagePanel()
                    } else {
                        model.hideWebPagePanel()
                    }
                }
            )
        ) {
            Image(systemName: "sidebar.left")
        }
        .toggleStyle(.button)
        .labelStyle(.iconOnly)
        .help(webPanelToggleHelp(isVisible: visible,
                                 hasContent: hasContent,
                                 lastPageLabel: lastPageLabel))
    }

    /// 会话页导航最右侧那颗「右侧页面」开关的悬停提示（**四档**）。
    ///
    /// ⚠️ 参数由调用方在 **body 求值期**读好传进来（同上面那条 ☠️）。
    /// 🔴 2026-10-02 口径变过一次：收起**不再销毁内容**，所以「再点开」多半只是
    ///    「把刚才那块面板原样调回来」（标签都在）。
    /// 🔴 2026-10-06 又变一次：**从没看过也照样能点**（点下去是**起始页**，不再置灰）——
    ///    用户原话「如果没有页面 打开是起始页」⇒ 第三档那句「先点正文里的网址…」随之作废，
    ///    并多出「标签都还在」那一档（`hasContent`）—— 收起之后面板里到底还剩什么，
    ///    文案要说清楚，别让「展开」和「打开上次那一页」混成一句。
    /// 🔴 **2026-10-07 第三变**：用户原话「最后一个标签 关闭标签 后 …… 重新打开后
    ///    会加载 最后一个标签的内容，要求 **如果关闭了 重新打开 就是初始页**」
    ///    ⇒ 关掉最后一个标签会**清账本**（`ChatModel.forgetPanelLocation()`）
    ///    ⇒ 第四档现在同时承接两种情形：**从没看过** 与 **刚把标签全关掉**。
    ///    两句话是同一件事（都开起始页），所以这里就写「起始页」（用户说的「初始页」
    ///    = 我们内部的起始页标签），⛔ 别再分成两档。
    /// ⚠️ 第三档（`lastPageLabel`）在**产品路径**下已经走不到（账本被清），保留是因为
    ///    `lastWebPageURL` 那套底座还在（见 `ChatModel.reopenLastWebPage()` 头注）。
    /// ⚠️ `hasContent` 与 `lastPageLabel` **都要**：面板里还留着标签时（哪怕那些标签
    ///    一个 URL 都没有，比如刚开出来的起始页）走的是「标签都还在」，不是「恢复上次」。
    private func webPanelToggleHelp(isVisible: Bool, hasContent: Bool, lastPageLabel: String?) -> String {
        if isVisible { return L("收起右侧页面（标签保留，随时再点回来）") }
        if hasContent { return L("展开右侧页面（标签都还在）") }
        if let label = lastPageLabel { return String(format: L("打开右侧页面（上次看的是 %@）"), label) }
        return L("打开右侧页面（起始页：输入网址 / 打开本地文件）")
    }

    /// `.inspector` 要的是 `Binding<Bool>`；真值在模型里、而且是**两个**（内容 + 显示），
    /// 这里把它们合起来做一次翻译。
    ///
    /// ⚠️ **不另存一个 `@State private var showWebPanel`**：那会变成第三份状态，
    ///    与模型里那两个迟早错开，表现是「开关说开着、界面却没有面板」或者反过来
    ///    「收起来了、页面还在后台跑」。这里只翻译，真值永远在模型里。
    ///
    /// ☠️ 参数 `visible` 是**调用方在 body 求值期读好的那个值**，不能在闭包里现读
    ///    `model.webPage` / `model.isWebPagePanelShown` —— `get` 闭包不跑在 body 求值期，
    ///    那样读**不会登记观察依赖**，症状是「模型里明明有页面、面板就是不出来」
    ///    （与 `.inspector` 那段同一句话，别删）。
    ///
    /// 🔴 `set(false)` **只收起显示**（`hideWebPagePanel()`）：2026-10-02 用户明确要求
    ///    「只有内容，就是常驻的」—— 他开两个标签、按一下收起再打开，标签必须原样回来。
    ///    ☠️ 别写回 `closeWebPage()`（那会连 `WKWebView` 一起放掉，标签全丢，
    ///    正是用户这次报的那个 bug）。
    private func webPanelBinding(visible: Bool) -> Binding<Bool> {
        Binding(
            get: { visible },
            set: { isPresented in
                // ⚠️ 这里**只处理「被要求收起」那一半**：`.inspector` 自己收起来时
                //    （用户拖拽 / 系统收起）也得把模型那个「显示」真值同步关掉。
                //    「打开」那半的落点**不在这里** —— 那颗开关走
                //    `ChatModel.showWebPagePanel()`（⚠️ 它 2026-10-06 起也能**凭空开出一页
                //    起始页**，所以「打开必然先有点链接」那条旧说法已不成立）。
                if !isPresented { model.hideWebPagePanel() }
            }
        )
    }
}

/// 顶部提示条
private struct ToastBar: View {
    let text: String

    var body: some View {
        Text(text)
            .font(MacTheme.ui(13))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Color.black.opacity(0.78))
            )
            .padding(.top, 12)
            .allowsHitTesting(false)
    }
}

/// 只干一件事：把「本视图所在的那个窗口」喂给回调。
///
/// 挂在 `RootView` 的 `.background` 上（不画东西、不占位）。
/// 用 `viewDidMoveToWindow` 而不是 `makeNSView`：视图造出来那一刻 `window` 还是 `nil`，
/// 而 `viewDidMoveToWindow` 才是「真的进窗口了」和「换窗口了」都会走的那一拍
/// （与 `ComposerWindowHint` 同一条铁律、同一个坑）。
/// ⚠️ 回调里改 SwiftUI `@State` 没问题（`viewDidMoveToWindow` 在主线程），
///    但调用方要自己防「写了同样的值 → 触发重排 → 再回调」的空转。
private struct HostWindowReporter: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { Sink(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Sink)?.onWindow = onWindow
    }

    private final class Sink: NSView {
        var onWindow: (NSWindow?) -> Void
        // ⚠️ 自定义 init 会**抑制**父类构造器的继承（含 required 的 init(coder:)）——
        //    `ComposerWindowHint` 的 Sink 没写 init 所以不用补，这里写了就必须补。
        //    ⚠️ super.init 要**显式写**（App 侧 typecheck 会帮你插，渲染台的编译参数
        //       不一样就不插了 ⇒「super.init isn't called on all paths」——别省这一行）。
        required init?(coder: NSCoder) { fatalError("not used") }
        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}
