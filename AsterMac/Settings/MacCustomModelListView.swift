//
//  MacCustomModelListView.swift
//  AsterMac
//
//  「自定义模型」清单页 —— 2026-10-14 新增，形态照用户在参考图里给的那一页。
//
//  ## 它在页面层级里的位置（🔴 2026-10-14 第五轮：它成了**设置窗右侧的一页**）
//      ⌘, 设置窗（`MacSettingsView`：左栏分组菜单 + 右侧内容）
//            ↓ 左栏选「功能 → 模型」
//      「自定义模型」（本页）   ← 只管「清单里有哪些」
//            ↓ 点「添加模型」/ 点某一行（或行尾的 ✎）
//      「添加模型」表单（`MacAddModelView`，以 **sheet** 呈现）
//
//  ⚠️ 改造前它是 `Settings` 场景的**根**（设置窗打开就是它）。现在设置窗升格成一个容器
//     （左菜单 / 右内容），本页被嵌进右侧 ⇒ 它**不再自己钉死尺寸**，改由 `fixedSize` 决定
//     （`nil` = 交给父级；非 `nil` = 渲染台单独验它时钉住，见那个属性的注释）。
//  🔴 但它**仍然不吃外层 padding**：设置窗里另外两页（通用 / 外观）各自带
//     `MacTheme.settingsContentPadding`，而本页自己那套 `padH`（20）正好是同一个视觉留白
//     ⇒ 嵌进去时**不要再套一层**，否则它比另外两页多缩一截。
//
//  改造前是**直连**：设置 = 表单，而「有哪些模型」这件事由表单里那颗供应商下拉隐式表达
//  （一平台一条，永远是三条）。JSON 化之后清单是**用户自己攒的任意多条**，
//  「有哪些 / 加一条 / 删一条」需要一块自己的地方 —— 就是本页。
//  ⚠️ 与 iOS 侧（`AICustomModelListViewController`）是**同一件事的两套控件**：那边 push、
//     这边 sheet（macOS 的设置窗口没有导航栈，弹出式面板才是这一平台的做法）。
//
//  ## 三件必须记住的事（与 iOS 那份逐条同义）
//  1. 🔴 **本页不回答「现在用哪个」**。那是运行时状态（`AIModelStore.currentID`，存 UserDefaults），
//     换它的入口是**聊天窗口那颗跨平台选择器**。
//     ⚠️ 2026-10-14 用户要求「不要显示『当前使用』这种字样」⇒ 行上**不再标当前项**。
//        这反而让这一页的职责更纯：它只回答「清单里有哪些」。⛔ 别把那个标记加回来 ——
//        用户觉得它在暗示「这一页能改哪个在用」，而那是另一件事。
//  2. 🔴 **行的顺序 = 文件里的顺序**，本页不排序。
//  3. ⚠️ 文件解析失败时**不能显示成空清单**（会诱导用户「配置丢了」→ 重新加一遍 → 覆盖手写内容）：
//     顶部挂一条红字说明，内容保留上一次能解析出来的那份。
//
//  ## ⚠️ 两处「离屏渲染验不到」的坑（与 `MacAddModelView` 同源）
//  - 本页**默认不用 `ScrollView`**（只有条目超过 `maxVisibleRows` 时才启用）：
//    离屏渲染里 `ScrollView` 的内容**完全画不出来** —— 那一档图会变成一片空白
//    （不是「看着不对」，是「什么都没有」）。夹具只用 3~4 条 ⇒ 走的是不滚的那一支。
//  - 🔴 **`toolbar` 项离屏渲染画不出来**（那是「窗口级」的东西，只能走 `render_mac_ui.sh root`
//    或真机）。所以「添加模型」那颗按钮**不做成 toolbar 项**，而是摆在内容区右上角 ——
//    它同时也是这一页最主要的动作，摆在内容里更显眼。
//

import SwiftUI
import AICore

struct MacCustomModelListView: View {

    // ⚠️ 这里原本有一个 `manager: AIChatManager` 入参，**只为**转交给表单里那张「用量与计费」卡
    //    （表单要读累计用量；Settings 是独立场景，拿不到 `WindowGroup` 的 `@Environment`）。
    //    2026-10-14 第三轮那张卡被用户删掉 ⇒ 本页与表单**都不再需要管理器** ⇒ 入参一并删掉
    //    （`AsterMacApp` 里 `MacCustomModelListView(manager: model.manager)` 那处实参也删了）。
    //    本页的数据只有一个来源：`AIModelStore`（`Documents/models.json`）。

    /// 内容尺寸。
    ///
    /// - `nil` = **交给父级**（2026-10-14 起它被嵌进设置窗的右侧 —— `MacSettingsView`）。
    /// - 非 `nil` = 自己钉死（渲染台单独验这一页时用，默认值就是 `panelSize`）。
    ///
    /// ⚠️ 为什么不是「删掉固定尺寸、一律撑满父级」：这一页有一档是**单独渲染**的
    ///    （`render_mac_ui.sh render` 里的 `model_list`），而 `ImageRenderer` 需要一个明确的
    ///    `proposedSize` —— 没有 `.frame` 的话它只会按内容长出来，行数与留白全都对不上真窗口。
    /// ⚠️ `.frame(width: nil, height: nil)` 是**合法且无副作用**的（不改变尺寸）——
    ///    所以下面那一行不用分两支写。
    var fixedSize: CGSize? = MacCustomModelListView.panelSize

    #if DEBUG
    /// 🧪 验收口子（2026-10-14）：进页面就打开哪一层，默认不开。
    ///
    /// 为什么非有它不可：表单现在是**sheet**，而 sheet **只有点击才会出现** ——
    /// simctl / 渲染台都投不出点击（本工程已知限制），不开口子的话
    /// 「表单那一页有没有被挤坏」一张图都验不到。只是个初值 ⇒ 不进发布版。
    var initialLayer: Layer = .none

    enum Layer { case none, form }
    #endif

    // MARK: - 版面常量

    /// 窗口内容尺寸。⚠️ 与 `body` 里那几串间距是**配套**的：改间距就要回来调高度，
    /// 否则最下面那几行会被窗口下边缘截掉（图里表现为**少了几条**，很容易误判成数据没读到）。
    static let panelSize = CGSize(width: 520, height: 480)

    private let rowHeight: CGFloat = 44
    private let padH: CGFloat = 20

    /// 一屏最多平铺几行；**超过它才**退化成可滚动（见文件头那条「离屏渲染」的说明）。
    ///
    /// 取值由来：内容区高度 ≈ 480 − 标题区(~86) − 页脚(~40) ⇒ 354；354 / 44 ≈ 8，
    /// 留一点余量取 7 —— 取大了会出现「窗口只画得下 7 行、第 8 行被裁一半」那种难看的样子。
    private static let maxVisibleRows = 7

    /// 当前清单（**不在 `body` 里现读**：那是文件 I/O，重绘路径上反复读盘是坏味道）
    @State private var entries: [AICustomModel] = []
    /// 文件坏了的原因（非 nil 时顶部挂红字）
    @State private var loadError: String?

    /// 表单要编辑的落点：`nil` = 不开 sheet。
    @State private var formTarget: FormTarget?

    /// 待确认删除的那一条（非 nil = 弹确认框）
    @State private var pendingDelete: AICustomModel?

    /// 表单要编辑哪一条。🔴 用一层包装而不是 `AICustomModel?`：
    /// `.sheet(item:)` 需要一个 `Identifiable`，而「新增」在 `AICustomModel` 里没有对应值
    /// （拿一条空 id 的假配置当哨兵，会在列表里闪出一行幽灵）。
    private enum FormTarget: Identifiable {
        case new
        case edit(AICustomModel)

        var id: String {
            switch self {
            case .new: return "__starry_new_model__"
            case .edit(let entry): return entry.id
            }
        }
    }

    // MARK: - 版面

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let loadError { errorBanner(loadError) }
            Divider().padding(.horizontal, padH)
            listBody
        }
        .frame(width: fixedSize?.width, height: fixedSize?.height)
        .background(MacTheme.pageBackground)
        .onAppear(perform: onAppearAction)
        // 🔴 配置变更（本页删的 / 表单保存的 / 别处改的）都要重读 —— `AIModelStore` 不是
        //    `@Observable`，不订这条广播的话「删完那一行还挂在列表上」。
        .onReceive(NotificationCenter.default.publisher(for: AIConfig.didChangeNotification)) { _ in
            reload()
        }
        .sheet(item: $formTarget) { target in
            switch target {
            case .new:
                MacAddModelView(editingModel: nil)
            case .edit(let entry):
                MacAddModelView(editingModel: entry)
            }
        }
        .alert(item: $pendingDelete) { entry in
            // 🔴 删除**必须确认**：那一条里存着用户贴的 API Key，删了要重新去服务商后台复制
            //    （很多 Key 只在创建时显示一次）。误点的代价正是这个。
            Alert(title: Text(String(format: L("删除「%@」？"), entry.displayName)),
                  message: Text(L("会从 models.json 里移除这一条（含它存的 API Key），无法撤销。")),
                  primaryButton: .destructive(Text(L("删除"))) {
                      AIModelStore.remove(id: entry.id)
                      // ⚠️ 上面那次写自己会广播 ⇒ `onReceive` 会重读一次；这里不重复调 `reload()`
                  },
                  secondaryButton: .cancel(Text(L("取消"))))
        }
    }

    /// 页头 —— **一张卡片**：左边「自定义模型 + 说明」，右边「添加模型」。
    ///
    /// 🔴 2026-10-14 第五轮：形态照用户的设置页参考图改成**卡片式**（改之前是
    ///    「按钮在左、说明在右」的一行光板）。参考图里那一页就是「一张卡里：标题 + 说明 + 右上按钮」。
    /// 🔴 卡片外观（圆角 / 内边距 / 底 / 描边）取 `MacTheme.settingsCard*` **同一组常量** ——
    ///    它与设置窗里「通用 / 外观 / 关于」三页的卡是同一张，⛔ 别在这里另写一套数字。
    /// ⚠️ 刻意**没有**复用那三页用的 `MacSettingsCard` 组件：它的标题是 13pt 的**行内**标题，
    ///    而这里是**页标题**（参考图里它明显比说明大一号）。形状相同、语义不同 ——
    ///    硬套只会让「以后改卡片圆角」时把页标题一起拽歪。
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("模型"))
                    .font(MacTheme.ui(14, weight: .semibold))
                    .foregroundStyle(MacTheme.bodyColor)
                // ⚠️ 说明里那句「写到哪个文件」是**这一页的存在意义**（用户参考图上那行就是它）：
                //    路径走 `AIModelStore.shortDisplayPath`（恒为 `Documents/models.json`），
                //    ⛔ 别换成完整路径 —— 沙盒路径有 80 多个字符，会把这一行撑成两行。
                Text(String(format: L("模型添加后会写入到本地 %@ 文件中。"), AIModelStore.shortDisplayPath))
                    .font(MacTheme.ui(12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                formTarget = .new
            } label: {
                Text(L("添加模型"))
                    .font(MacTheme.ui(13))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MacAddModelSecondaryButtonStyle())
        }
        .padding(MacTheme.settingsCardPadding)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.settingsCardRadius)
                .fill(MacTheme.settingsCardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: MacTheme.settingsCardRadius)
                        .stroke(MacTheme.settingsCardBorder, lineWidth: 1)
                )
        )
        .padding(.horizontal, padH)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    /// 文件读不出来时的红字（见文件头第 3 条）。
    private func errorBanner(_ message: String) -> some View {
        Text(String(format: L("这个文件读不出来：%@\n下面显示的是上一次能读到的内容；改好文件后回到这一页即生效。"), message))
            .font(MacTheme.ui(12))
            .foregroundStyle(MacTheme.errorText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, padH)
            .padding(.bottom, 10)
    }

    @ViewBuilder
    private var listBody: some View {
        if entries.isEmpty {
            VStack(spacing: 6) {
                Text(L("还没有自定义模型"))
                    .font(MacTheme.ui(13))
                    .foregroundStyle(.secondary)
                Text(L("点右上角「添加模型」加一条"))
                    .font(MacTheme.ui(12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else if entries.count > Self.maxVisibleRows {
            // ⚠️ 只有这一支用 `ScrollView` —— 见文件头那条「离屏渲染画不出滚动内容」的说明：
            //    夹具只摆 3~4 条，走的是下面那一支，图里能看到每一行。
            ScrollView {
                rows
            }
            .frame(maxHeight: CGFloat(Self.maxVisibleRows) * rowHeight, alignment: .top)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(entries) { entry in
                MacCustomModelRowView(entry: entry,
                                      onEdit: { formTarget = .edit(entry) },
                                      onOpenDocs: {
                                          if let url = entry.documentationURL { NSWorkspace.shared.open(url) }
                                      },
                                      onDelete: { pendingDelete = entry })
                .frame(height: rowHeight)
            }
        }
    }


    // MARK: - 动作

    private func onAppearAction() {
        // 🔴 进页面**强制重读**：用户可能刚在访达里手改过这份文件
        AIConfig.reloadModels()
        reload()
        #if DEBUG
        if case .form = initialLayer { formTarget = .new }
        #endif
    }

    private func reload() {
        entries = AIModelStore.all()
        loadError = AIModelStore.lastLoadError
    }
}

// MARK: - 一行

/// 清单里的一行：图标 + 名称 + 供应商 + 行尾三颗动作（改 / 看文档 / 删）。
///
/// ⚠️ 行尾那三颗是**常驻**的，不做 hover 显隐：与参考图一致，也让「这一页能做哪几件事」
///    一眼可见（hover 才出现的东西，在离屏渲染里也验不到 —— 那一档图恒为常态）。
///
/// 🔴 2026-10-14 用户要求：「不要显示『当前使用』这种字样」「编辑、链接、删除 三个按钮的**间距缩小**」。
///    · 「当前使用」标记**整个删掉**（连带 `isCurrent` 这个入参）—— 本页只列清单，不回答「在用哪个」；
///    · 三颗按钮**自成一组**（`HStack(spacing: actionGap)`），组内间距比行内间距小得多：
///      行内 `spacing = 12`，组内 `actionGap = 0` + 每颗 26×26 —— 中心距 40pt → **26pt**。
///      ⛔ 别只是把最外层那个 `spacing` 调小：那会**连着**把「图标 ↔ 名称 ↔ 供应商」一起挤紧，
///         而用户只要求动那三颗（名称/供应商本来就靠 `Spacer` 撑开，一改这里会跟着变）。
private struct MacCustomModelRowView: View {

    let entry: AICustomModel
    let onEdit: () -> Void
    let onOpenDocs: () -> Void
    let onDelete: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 12) {
            // 品牌图标（asset 优先）+ 符号兜底；宽度仍由外层 20pt 框对齐
            MacProviderIcon(asset: entry.iconAssetName,
                            symbol: entry.symbolName,
                            size: 14,
                            keepBrandColor: entry.vendorKind?.iconKeepsBrandColor ?? false)
                .foregroundStyle(.primary)
                .frame(width: 20)
            Text(entry.displayName)
                .font(MacTheme.ui(14))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(entry.vendorDisplayName)
                .font(MacTheme.ui(12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)

            // 🔴 三颗按钮**自成一组**：组内 `spacing: 0` 且命中区收到 26×26
            //    ⇒ 只影响这三颗之间的距离，不碰行内其它间距（见上面那条注释）。
            HStack(spacing: Self.actionGap) {
                actionButton(symbol: "pencil", help: L("编辑这一条"), action: onEdit)
                // 认不出供应商预设（手改 JSON 写了个没见过的 vendor 名）⇒ 没有文档可指，不渲染那一颗
                if entry.documentationURL != nil {
                    actionButton(symbol: "link", help: L("打开该供应商的文档"), action: onOpenDocs)
                }
                actionButton(symbol: "trash", help: L("删除这一条"), action: onDelete)
            }
        }
        .padding(.horizontal, padH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 点「行」（不是那三颗按钮）→ 进编辑 —— 与 iOS 的 `didSelectRowAt` 同一个语义
        .onTapGesture(perform: onEdit)
        .background(hovered ? Color.primary.opacity(0.05) : Color.clear)
        // ⚠️ 悬停底色由 `onHover` 驱动；离屏渲染里没有指针 ⇒ 恒为常态（那一档图看的是常态）。
        .onHover { hovered = $0 }
    }

    /// 行尾三颗之间的间距（用户要求「缩小」）。取 0 —— 三颗各自 26pt 的命中区已经把它们
    /// 自然分开了，再留空隙只会让这一组显得发散。⛔ 别调成负数或去掉命中区。
    private static let actionGap: CGFloat = 0

    /// 行尾那一颗方形图标按钮。
    ///
    /// 🔴 **命中区必须撑满按钮自身**（铁律）：图标只有 ~13pt，不撑开的话鼠标很难点中。
    ///    撑开只能写在 label **内部**（`.frame(width:height:) + .contentShape(Rectangle())`），
    ///    写在按钮外面的 `padding` 对命中区无效。
    /// ⚠️ 尺寸 28 → **26**（2026-10-14 配合「间距缩小」一起收）：再小就低于 macOS 的舒适点击尺寸了。
    private func actionButton(symbol: String,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(MacTheme.ui(12))
                .foregroundStyle(.secondary)
                .frame(width: Self.actionSize, height: Self.actionSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private static let actionSize: CGFloat = 26

    private var padH: CGFloat { 20 }
}
