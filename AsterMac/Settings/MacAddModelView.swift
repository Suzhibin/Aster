//
//  MacAddModelView.swift
//  AsterMac
//
//  「添加模型」表单：被 `MacCustomModelListView` 以 **sheet** 弹出的**一条配置**的编辑面板。
//  读写全走 `AIModelStore`（唯一真值 = `Documents/models.json`）。
//
//  ## 版面（自上而下）
//  ① 标题（「添加模型」/「编辑模型」）+ 右上 ×；② 供应商下拉（带「查看文档 ↗」，**无搜索**）；
//  ③ API Key 输入框（右侧眼睛）+「测试连接」；④ 模型名称下拉（**不可手填**）；
//  ⑤ 右下角「取消 / 保存」。
//
//  ## 🔴 两条被用户砍掉的东西（⛔ 别再找、别加回来）
//  - **「服务地址」栏已删** ⇒ 地址恒等于 `vendor.defaultBaseURL`。实现上仍留一个不接 UI 的
//    `urlDraft` 当载体：编辑既有条目时先装它自己那份 url ⇒ 手改过地址的条目**不会**因为
//    打开一次面板就被重置成空串（换供应商才重置，那是刻意的）。
//  - **「用量与计费」整栏已删**（连带 `usageSection` / `priceRow` / `priceField` / `usage` 状态，
//    以及**只为它存在的 `manager` 入参**）⇒ 本页从此一条库查询都不做。
//    ⚠️ 连带后果，别当 bug：Mac 侧**没有任何地方**能看累计用量了。代码侧 `usageTotal()` /
//    `clearUsage()` 一行没动（iOS 设置页仍在用），要恢复把视图加回来即可。
//    `pricingDraft` 概念一并撤掉 ⇒ 保存时**不再碰 `entry.pricing`**，手改 JSON 写的单价原样留着。
//
//  ## 🔴 换供应商 = 连带换模型名
//  `selectProvider` 里有一句 `modelDraft = kind.defaultModel`。⚠️ 这与旧注释的意图**相反**
//  （旧注释写「选了模型名再换供应商，那个不该丢」，那是「能手填」时代的口径）。
//
//  ## 🔴 编辑的是**一条配置**，不是「一个平台」
//  `editingModel: AICustomModel?`（`nil` = 新增），一条配置自带地址与 Key。
//  - **模型名是键**：改名 = 改键，保存要「替换原来那条」（`AIModelStore.save(_:replacing:)`），
//    ⛔ 别写成「老那条还在 + 多出一条」。模型名只能下拉选，但两条不同供应商的同名模型**仍可能撞**，
//    所以「摘新旧两个键」那条逻辑一个字都不能少。
//  - **模型名不可手填** ⇒ 能改 `modelDraft` 的只有 `pick(_:)` 与 `selectProvider`；另有非用户写入点
//    `reloadAll()`（进页给**新建**那条预填该家的 `defaultModel`）。
//    ☠️ 代价写在案，别当漏掉的：服务端清单拉不到 / 用中转别名 / 清单里没有那支实验模型时，
//    **这一页没法再加**，只能手改 `models.json`。这是用户点名的取舍。
//  - **供应商下拉不含 `.custom`**（`providerRows` 显式筛掉）：地址栏没了之后它不再可用。
//    ⚠️ 枚举里的 `.custom` **保留**：手改 JSON 写 `"vendor": "custom"` 的条目仍要认得出。
//
//  ## 🔴 两个下拉都是**浮层覆盖**，不是行内展开
//  改之前「点一下把列表插进行里」⇒ 下面全被挤下去、窗口高度跟着跳，用户不接受。
//  现在列表**浮在控件正下方**、零高度占用 ⇒ 供应商 / Key / 模型一个像素都不动。
//  ⚠️ 三条只有做下去才知道的约束（都实跑验过）：
//  1. **必须给所在 section 提 `zIndex`** —— `VStack` 的后续兄弟画在上层，不提的话供应商浮层
//     会被下面的 API Key 整块盖住（症状：浮层只露上半截）；
//  2. **控件外层必须钉高**（`.frame(height: fieldHeight, alignment: .top)`）—— `offset` 不改布局，
//     但 `ZStack` 的布局高度取最大子视图，不钉的话浮层照样把下面几栏挤下去；
//  3. ⛔ **别用 `.overlay(alignment:) + alignmentGuide(.bottom) { $0[.top] }`** 那个经典写法：
//     实测在这里**反了**，浮层往上弹到控件上方、API Key 从底下露出来。现在是 ZStack + 定值 `offset`。
//  ⚠️ 浮层超出面板的部分用户看不见 ⇒ 列表长度仍是 `maxModelRows` 截断。
//
//  ## 🔴 草稿语义
//  输入框 / 下拉都只落在本页 `@State`，点「保存」才写 `AIModelStore`；× 与「取消」都是丢弃。
//  ⚠️「测试连接」用**草稿里的**地址与 Key（`AIModelCatalog.fetch(for:url:apiKey:)`）——
//  拿存着的那份去测等于测了个旧配置（症状：Key 填错了却提示成功）。
//
//  ## ⛔ 这一页**不许**写 `AIConfig.currentID`
//  它是编辑配置，不回答「现在用哪个」；改当前项会把正在聊的窗口顶上别的模型。
//  换当前模型的唯一入口是聊天窗口那颗跨平台选择器（`ChatModel.selectChoice`）。
//  ⚠️ `render_mac_ui.sh` 开头有一条机械契约盯着这件事，改回去就 FAIL。
//
//  ## 离屏渲染台验不了的两处
//  - `TextField` / `SecureField` 离屏渲成「黄条 + ⊘」（系统画的）⇒ 输入框外观只能走
//    `render_mac_ui.sh root`（真窗口）那张图；
//  - 本页**刻意不用 `ScrollView`**：离屏渲染里它的内容完全画不出来（那页图会一片空白）。
//    所以版面用固定高度 + `Spacer()` 撑开，窗口尺寸（`Self.panelSize`）与内容高度必须一起看。
//

import SwiftUI
import AppKit
import AICore

struct MacAddModelView: View {

    /// 被编辑的那一条；`nil` = 新增。
    ///
    /// 🔴 它是**快照**：打开面板时取一份，之后不再回读（面板开着时配置可能被别处改）。
    ///    面板只拥有它的一部分字段（供应商 / 地址 / 模型名 / 能力位 / Key / 计价），
    ///    其余（`name` / `maxInputTokens` / `maxOutputTokens` / `supportsToolCall`）
    ///    **原样保留** —— 那些栏本页不显示，但用户可能手改 JSON 写过（见 `draftEntry`）。
    var editingModel: AICustomModel?

    #if DEBUG
    /// 🧪 验收口子（2026-10-13）：进页面就展开哪个下拉，默认不开。
    ///
    /// 为什么非有它不可：两个下拉现在是**浮层**，而浮层**只有点击才会出现** ——
    /// simctl / 渲染台都投不出点击（本工程已知限制），不开口子的话
    /// 「浮层有没有压在下面那几栏上」「列表有没有被窗口下边缘截掉」**一张图都验不到**。
    /// ⚠️ 只是个初值，用户点一下照常开合 ⇒ **不进发布版**（`#if DEBUG`）。
    var initialPanel: Panel = .none

    enum Panel { case none, provider, model }

    /// 🧪 验收口子（2026-10-14 第三轮）：进页面后**模拟一次「换供应商」**，默认不切。
    ///
    /// 为什么非有它不可：`selectProvider` 是新加的「换供应商 ⇒ 连带换模型名」那个行为的**唯一**落点，
    /// 而它**只有点击才会跑**（渲染台投不出点击，本工程已知限制）⇒ 不开口子的话
    /// 「切成 kimi 之后模型名有没有跟着变成 `kimi-k2.5`」这件事**一张图都验不到**
    /// （只能靠源码 grep —— 那只能证明「那句话还在」，证不了「真的跑了」）。
    /// 🔴 走的是**跟点击同一条路**（直接调 `selectProvider(kind)`），⛔ 别在这里另写一遍赋值 ——
    ///    那会造出「图上对、真点不对」的假绿。
    /// ⚠️ 只在 `#if DEBUG` 里、只是个初值 ⇒ 不进发布版，用户点一下照常开合。
    var initialProviderSwitch: AIProviderKind?
    #endif

    // MARK: - 版面常量

    /// 窗口内容尺寸。⚠️ 与 `body` 里那串竖向间距是**配套**的：改间距就要回来调高度。
    ///
    /// ⚠️ 沿革：640 →（2026-10-14 加「服务地址」那一栏 +90）→ 720 →（同日晚删掉它）→ 640
    ///    →（同日第三轮删掉「用量与计费」那张卡）→ **520**。
    ///
    /// 🔴 **两个方向都能错，两边都得盯**（这就是为什么它不能只按「内容有多高」估）：
    ///    · **调太矮** ⇒ 页脚那两颗按钮被挤到可视区外。离屏渲染图里的表现是**按钮不见了**
    ///      （很容易误判成接线丢了，其实只是 h 给小了）；
    ///    · **调太矮还有第二种坏法**：模型浮层是**往下悬**的（定值 `offset`），
    ///      面板高度不够时它**伸出面板下边缘** ⇒ 后面那几行用户根本看不到（图里也不报错）。
    ///      删掉用量卡之后空出来的那一带**正好是它的落点** —— 别为了「紧凑」把这一带一起收掉。
    /// ⚠️ 改完**一定**要跑一次 `render_mac_ui.sh render`，同时看 `settings_deepseek`（页脚在不在）
    ///    与 `settings_model_open`（浮层六行有没有被下边缘截掉）两张图。
    static let panelSize = CGSize(width: 520, height: 520)

    /// 一行控件（下拉 / 输入框）的高度 —— 参考图里各控件高度一致。
    private let fieldHeight: CGFloat = 34
    private let fieldRadius: CGFloat = 8
    private let padH: CGFloat = 20

    // MARK: - 状态

    /// 本页正在编辑哪家**预设**（决定预填地址 / 能力位 / 图标 / 文档链接）。
    ///
    /// 🔴 **初值刻意是个字面量**（不是 `editingModel?.vendorKind`）：`@State` 的默认值
    ///    求值**早于** `init()`（铁律），在这里读入参会读到 nil。真正的值在
    ///    `onAppear` → `reloadAll()` 里定 —— 与改造前那一版读 `AIConfig.currentProvider` 的
    ///    位置是一样的（那边也踩过同一个坑）。
    @State private var vendor: AIProviderKind = .deepSeek

    /// 草稿：Key / 地址 / 模型名。点「保存」才落库（见文件头）。
    ///
    /// 🔴 **Key 输入框永远不回填明文**（与改造前的设置页同一条规矩）：`keyDraft` 初值恒为空串，
    ///    只在用户**真的敲了**东西之后才用得上；已存的那把只以脱敏形式显示在下面。
    ///    代价是「想改一个字母」得整把重贴 —— 收益是明文 Key 不会因为打开一次设置就出现在屏幕上。
    @State private var keyDraft: String = ""
    /// 用户点了「清除」——**也是一个草稿**（保存才真的清），否则「取消」就撤不回来了。
    @State private var keyCleared = false
    /// 服务地址草稿。⚠️ **界面上已经没有这一栏**（2026-10-14 第二轮删的）——
    ///    它现在是个**载体**：编辑既有条目时装的是这条自己的 url（所以手改过地址的 `.custom` 条目
    ///    不会因为打开一次面板就被重置）；只有**换供应商**才重置成该家的默认地址。
    @State private var urlDraft: String = ""
    @State private var modelDraft: String = ""
    // ⚠️ 这里原本还有一个 `pricingDraft`（配合「用量与计费」那张卡）。
    //    2026-10-14 第三轮把那张卡删掉后**再没有编辑入口** ⇒ 连状态一起撤掉：
    //    保存时不再写 `entry.pricing`，于是「手改 JSON 写过的单价原样留着 / 没写过的走默认」。

    /// 打开那一刻的**原始值**（「保存」可点与否靠它比，见 `isDirty`）
    @State private var originalModelID = ""
    @State private var originalURL = ""
    @State private var originalVendorRaw = ""

    /// 两个下拉的展开态 + 模型那一路的搜索词。
    ///
    /// 🔴 **供应商没有搜索**（2026-10-13 用户要求去掉）：它总共就五家，搜索框占掉浮层第一行、
    ///    却几乎筛不出结果 —— 是纯噪音。模型那一路保留搜索：清单可能有几十条，
    ///    而浮层受 `maxModelRows` 截断，没有搜索就够不到后面的模型。
    @State private var providerOpen = false
    @State private var modelOpen = false
    @State private var modelKeyword = ""

    /// 是否明文显示 Key（用户自证用：密文框里敲不进/粘不进时，切明文能立刻区分
    /// 「没进去」还是「进去了看不见」）。
    @State private var showsPlainKey = false

    /// 「测试连接」的状态机。
    @State private var testing = false
    @State private var testNote: String?
    @State private var testOK = false

    /// 「保存」之后的反馈（参考图没有位置放它，挂在按钮左边）。
    @State private var saveNote: String?

    /// 可选模型清单（内置候选 + 上次拉到的缓存）。切供应商 / 拉到新清单时重算。
    @State private var modelOptions: [AIModelCatalog.AIModelEntry] = []

    /// 已配置 Key 的脱敏值（同上：**不在 body 里现读** —— 它要读 JSON 文件）。
    @State private var storedMaskedKey: String?

    /// 关闭本 sheet（2026-10-14：本页现在是清单页弹出的 sheet，不再是 Settings 场景的根）。
    @Environment(\.dismiss) private var dismiss

    @FocusState private var keyFocused: Bool

    // MARK: - 版面

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 16) {
                // 🔴 这几行 `zIndex` 是浮层能完整显示的前提（见文件头「两个下拉都是浮层覆盖」）：
                //    展开的那一段要**压过它下面的所有 section**，否则浮层被后面的兄弟整块盖住。
                //    ⚠️ 不展开时给 0 即可 —— `zIndex` 只影响绘制/命中顺序，不参与布局。
                providerSection.zIndex(providerOpen ? 3 : 0)
                keySection.zIndex(1)
                modelSection.zIndex(modelOpen ? 3 : 0)
            }
            .padding(.horizontal, padH)
            .padding(.top, 4)

            Spacer(minLength: 12)
            footer
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .background(MacTheme.pageBackground)
        // 点面板空白处收起浮层（浮层是覆盖式的，没有这层就没法「点外面关掉」）。
        // ⚠️ 放在 `.background` 里 ⇒ 它**在内容之下**：只有没被任何控件吃掉的点击才落在这里，
        //    不会把输入框 / 按钮的点击抢走（写成 `.overlay` 就会全页点不动，必踩）。
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { closePanels() }
        )
        .onAppear(perform: openInitialPanelIfNeeded)
    }

    /// 进页面：先把 `vendor` 定下来（`@State` 的默认值读不到入参，见那边的注释），再读该条配置。
    private func openInitialPanelIfNeeded() {
        vendor = editingModel?.vendorKind ?? .deepSeek
        reloadAll()
        #if DEBUG
        // 🔴 必须**排在 `reloadAll()` 之后**：那个函数会用 `editingModel` 把草稿整个重装一遍，
        //    先切的话会被重新盖回去（症状：图上完全看不出切过，而你会以为是 `selectProvider` 坏了）。
        if let kind = initialProviderSwitch { selectProvider(kind) }
        switch initialPanel {
        case .none: break
        case .provider: providerOpen = true
        case .model: modelOpen = true
        }
        #endif
    }

    /// 标题栏：标题 + 右上 ×（× 的语义与「取消」一致 = 丢弃草稿）。
    ///
    /// ⚠️ 标题说实话：新增 / 编辑是两件事（编辑时用户会想确认自己在改哪一条）。
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(editingModel == nil ? L("添加模型") : L("编辑模型"))
                .font(MacTheme.ui(15, weight: .semibold))
            Spacer(minLength: 0)
            Button(action: discardDrafts) {
                Image(systemName: "xmark")
                    .font(MacTheme.ui(12, weight: .medium))
                    .foregroundStyle(.secondary)
                    // ⚠️ 命中区 = label 边界（铁律）：撑大只能写在 label **内部**。
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("关闭（Esc）：丢弃这次改动"))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, padH)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    // MARK: - 供应商

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(L("供应商"))
                    .font(MacTheme.ui(13))
                    .foregroundStyle(.primary)
                Text(L("（仅支持 OpenAI 兼容协议 API）"))
                    .font(MacTheme.ui(13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // 认不出供应商预设（手改 JSON 写了个没见过的 vendor 名）⇒ 没有官方文档可指，
                // 那一行链接就不渲染（给个可能过期的硬编码链接比不给更糟）
                if let url = vendor.documentationURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 3) {
                            Text(L("查看文档"))
                            Image(systemName: "arrow.up.right")
                                .font(MacTheme.ui(10, weight: .semibold))
                        }
                        .font(MacTheme.ui(13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MacTheme.linkText)
                }
            }
            providerField
        }
    }

    /// 供应商那一颗「值 + 箭头」+ **浮层**。
    ///
    /// 🔴 两条都不是随手写的，改之前先看懂（`settings_provider_open` / `settings_model_open` 出图盯着）：
    ///    1. `.frame(height: fieldHeight, alignment: .top)` **必须留**。浮层是 `.offset` 出来的，
    ///       `offset` 不改布局 —— 但 `ZStack` 的**布局高度**会取「最大子视图」，也就是浮层的高度
    ///       ⇒ 不钉这一行，浮层照样把下面那几栏挤下去（**正是用户提的那个问题**，症状一模一样）。
    ///    2. ⛔ **别改回 `.overlay(alignment: .bottomLeading) + alignmentGuide(.bottom) { $0[.top] }`**
    ///       那个「让浮层的顶对齐宿主的底」的经典写法。实测（2026-10-13 渲染台）它在这里**反了**：
    ///       浮层跑到控件**上方**（往上弹），API Key 那一栏从浮层底下完整露出来 —— 图上一眼可辨。
    ///       现在的写法（ZStack + 定值 `offset`）位置是**算出来的**，不依赖对齐语义的推导。
    private var providerField: some View {
        ZStack(alignment: .topLeading) {
            fieldShell(iconAsset: vendor.iconAssetName,
                       icon: vendor.symbolName,
                       keepBrandColor: vendor.iconKeepsBrandColor,
                       title: vendor.displayName,
                       expanded: providerOpen,
                       help: vendor.subtitle) {
                providerOpen.toggle()
                if providerOpen { closeModelPanel() }
            }
            if providerOpen {
                overlayPanel(rows: providerRows)
                    .offset(y: fieldHeight + Self.panelGap)
            }
        }
        .frame(height: fieldHeight, alignment: .top)
    }

    /// 供应商下拉的行（**当前选中的那家打勾**）。
    ///
    /// 🔴 **`.custom` 不在其中**（2026-10-14 用户要求「供应商内去掉自定义」）。
    ///    理由是**结构性的**、不是审美：这一页的「服务地址」栏同日被删 ⇒ 选了「自定义」
    ///    也没有任何地方能填地址，那一条会存成一个永远打不通的配置（症状是 404，
    ///    而界面上看不出哪儿不对）。⛔ 别「顺手」把它加回来 —— 要加就得先把地址栏加回来。
    ///    ⚠️ 枚举里的 `.custom` 仍在：手改 JSON 的 `"vendor": "custom"` 条目要能正常显示
    ///    （`vendorKind` 反查得到它，这时 `fieldShell` 会显示「自定义」，只是下拉里点不到）。
    private var providerRows: [MacAddModelRowModel] {
        AIProviderKind.allCases.filter { $0 != .custom }.map { kind in
            MacAddModelRowModel(id: kind.rawValue,
                                providerKind: kind,
                                iconAsset: kind.iconAssetName,
                                icon: kind.symbolName,
                                title: kind.displayName,
                                note: nil,
                                selected: kind == vendor,
                                help: kind.subtitle)
        }
    }

    // MARK: - 服务地址 —— 🗑️ 2026-10-14 已删除（别再找这一栏）
    //
    // 用户原话：「添加模型页面不要服务地址」。删掉之后：
    //   · 地址**恒等于供应商预设**（`vendor.defaultBaseURL`），由 `urlDraft` 携带（不接 UI）；
    //   · 编辑既有条目时 `urlDraft` 先装它自己那份 url ⇒ 手改过地址的 `.custom` 条目
    //     不会因为打开一次面板就被重置（只有「换供应商」才重置，那是刻意的）；
    //   · ⚠️ 因此**界面上再没有任何地方能填地址** —— 想给中转站/自建网关改地址只能手改
    //     `models.json`。这是用户点名的取舍，⛔ 别当成 bug 把这一栏加回来。
    //   · 连带后果：供应商下拉里的 `.custom` 同日一起去掉（见 `providerRows`）。

    // MARK: - API Key

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Key")
                .font(MacTheme.ui(13))
                .foregroundStyle(.primary)
            HStack(spacing: 10) {
                keyFieldShell
                testButton
            }
            if let testNote {
                Text(testNote)
                    .font(MacTheme.ui(11))
                    .foregroundStyle(testOK ? Color(nsColor: .systemGreen) : MacTheme.errorText)
            } else {
                HStack(spacing: 8) {
                    // 「已存的那把是什么」——用户换 Key 之前得知道现状。脱敏，不回填明文。
                    Text(keyStatusText)
                        .font(MacTheme.ui(11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // 🔴 「清除」必须留着：不留就等于「Key 填错了只能改不能删」，
                    //    而错 Key 会让这个模型**永远发不出请求**。
                    if storedMaskedKey != nil && !keyCleared {
                        Button(L("清除")) {
                            keyDraft = ""
                            keyCleared = true
                        }
                        .buttonStyle(.plain)
                        .font(MacTheme.ui(11))
                        .foregroundStyle(MacTheme.errorText)
                    }
                }
            }
        }
    }

    /// Key 输入框的占位符 —— 输入框**不回填明文**，占位符是用户唯一能看见
    /// 「已存的 Key 长什么样」的地方（2026-10-16：用户打开编辑页看到空框，
    /// 不知道 Key 存没存，还以为空框能测连接是 bug）。
    ///
    /// 有已存 ⇒ 「已保存 sk-xxxx**** · 留空不修改」；没有 ⇒ 默认提示。
    private var keyPrompt: Text {
        if let masked = storedMaskedKey {
            return Text(String(format: L("已保存 %@ · 留空不修改"), masked))
        }
        return Text(L("输入你的 API Key"))
    }

    /// Key 输入框：密文 / 明文两态 + 右侧眼睛。
    ///
    /// ⚠️ 用 `SecureField` 时**不能**靠 `.textFieldStyle(.plain)` 拿掉系统边框再自己画 ——
    ///    那在 macOS 上会把 SecureField 画成一个没有内容的框（实测）。所以这里反过来：
    ///    **外层自己画圆角底 + 描边**，里面放 `.textFieldStyle(.plain)` 的输入控件。
    private var keyFieldShell: some View {
        HStack(spacing: 6) {
            if showsPlainKey {
                TextField("", text: $keyDraft, prompt: keyPrompt)
                    .textFieldStyle(.plain)
                    .font(MacTheme.ui(13, design: .monospaced))
                    .focused($keyFocused)
                    .onChange(of: keyDraft) { _, _ in keyCleared = false }
            } else {
                SecureField("", text: $keyDraft, prompt: keyPrompt)
                    .textFieldStyle(.plain)
                    .font(MacTheme.ui(13, design: .monospaced))
                    .focused($keyFocused)
                    .onChange(of: keyDraft) { _, _ in keyCleared = false }
            }
            Button {
                showsPlainKey.toggle()
            } label: {
                Image(systemName: showsPlainKey ? "eye" : "eye.slash")
                    .font(MacTheme.ui(12))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("切换明文 / 密文：用来确认 Key 到底有没有粘进去"))
        }
        .padding(.horizontal, 10)
        .frame(height: fieldHeight)
        .background(fieldBackground)
    }

    /// Key 那一栏下面的状态文案（**脱敏**；`keyCleared` 与「草稿里有新 Key」都要说清）。
    private var keyStatusText: String {
        if keyCleared { return L("保存后清除这条配置的 Key") }
        if !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("保存后生效")
        }
        guard let masked = storedMaskedKey else { return L("未配置") }
        return String(format: L("已保存：%@"), masked)
    }

    private var testButton: some View {
        Button(action: runTest) {
            Text(testing ? L("测试中…") : L("测试连接"))
                .font(MacTheme.ui(13))
                .padding(.horizontal, 12)
                .frame(height: fieldHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(MacAddModelSecondaryButtonStyle())
        .disabled(testing)
    }

    // MARK: - 模型名称

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("模型名称"))
                .font(MacTheme.ui(13))
                .foregroundStyle(.primary)
            modelField
        }
    }

    /// 模型名那一栏（**与供应商同款**：一颗按钮，点开浮层）+ 浮层。
    ///
    /// 🔴 2026-10-14 用户要求「模型名称输入框**也不需要编辑功能**，和供应商一样点击就弹出模型列表」
    ///    ⇒ 从「可编辑输入框 + 箭头」改成**纯按钮**（`fieldShell`，与供应商共用同一个外观件）。
    ///    ☠️ `modelDraft` 因此**只能**由 `pick(_:)` 写入 —— 本页不再接受手填。
    ///    代价（用户点名的取舍）：清单拉不到 / 中转别名 / 实验模型名 ⇒ 只能手改 `models.json`。
    /// ⚠️ 浮层机制与 `providerField` 逐字同源（含那条「必须钉高」的坑），那边注释更全。
    /// ⚠️ **模型这一路保留搜索**（供应商那路没有）：候选可能几十条，而浮层受 `maxModelRows`
    ///    截断 ⇒ 没有搜索就够不到第 7 条以后的模型。这与「不可手填」不冲突 ——
    ///    搜索是在**已有候选里筛**，不会让用户造出一个新名字。
    private var modelField: some View {
        ZStack(alignment: .topLeading) {
            fieldShell(iconAsset: nil,
                       icon: nil,
                       title: modelDraft.isEmpty ? L("未设置") : modelDraft,
                       expanded: modelOpen,
                       help: L("从列表选择"),
                       dimmed: modelDraft.isEmpty) {
                modelOpen.toggle()
                if modelOpen {
                    modelKeyword = ""
                    closeProviderPanel()
                }
            }
            if modelOpen {
                overlayPanel(rows: modelRows, search: $modelKeyword)
                    .offset(y: fieldHeight + Self.panelGap)
            }
        }
        .frame(height: fieldHeight, alignment: .top)
    }

    private var modelRows: [MacAddModelRowModel] {
        let trimmed = modelKeyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rows = modelOptions.filter {
            trimmed.isEmpty || $0.id.lowercased().contains(trimmed)
        }
        return rows.prefix(Self.maxModelRows).map { entry in
            MacAddModelRowModel(id: entry.id,
                                providerKind: nil,
                                iconAsset: nil,
                                icon: nil,
                                title: entry.id,
                                note: entry.note,
                                selected: entry.id == modelDraft,
                                help: entry.note)
        }
    }

    /// 下拉最多显示几行。
    ///
    /// ⚠️ 参考图里那个列表是**限高**的（它自己有滚动条）。这里刻意**不做滚动**
    ///    ——离屏渲染台画不出 `ScrollView` 内容，加了就等于「下拉列表在图里是空的」，
    ///    而那正是这个面板最该被验的部分。改用截断 + 搜索框（列不全就去搜）。
    /// ⚠️ 改成浮层之后多了一条上限：**超出面板下边缘的部分用户根本看不见**（图里也不报错，
    ///    只是「列表好像少了几项」）。
    /// 🔴 2026-10-14 第三轮：删掉「用量与计费」那张卡之后，模型栏下面**空出来一带** ——
    ///    那一带正是这个浮层的落点，`panelSize.height` 是照着「五行浮层别伸出下边缘」定的
    ///    （见那边的注释）。⛔ 别为了「紧凑」把高度一起收掉，那会让最后几行看不见。
    private static let maxModelRows = 6

    // MARK: - 用量与计费 —— 🗑️ 2026-10-14 已删除（别再找这一段）
    //
    // 用户原话：「去掉 用量与费用」。删掉的是**整张卡**：标题行（刷新 / 清零统计）+ 累计文案
    // + 三档单价（命中 / 未命中 / 输出）+ 「恢复默认」+ 那句单价出处说明。
    //
    // 为什么连 `pricingDraft` 一起撤、而不是留一个「不接 UI 的载体」（`urlDraft` 那种做法）：
    //   `urlDraft` 留着是因为**换供应商还会写它**（有第二个写入点）；单价**再没有任何写入点**，
    //   留一个恒等于初值的 `@State` + 一条恒为 false 的 `isDirty` 分支 = 纯噪音。
    //   代价一样能做到：`draftEntry` 的起点是「原来那条」，⛔ 不碰 `entry.pricing` ⇒
    //   手改 JSON 写过的单价原样保留；没写过的（`pricing == nil`）继续走 `AIConfig.defaultPricing`。
    //   ⚠️ 顺带修掉一个旧毛病：老写法会把「原本没写 pricing 的那条」**写成一个显式 pricing 块**
    //   （因为 `pricingOrDefault` 把默认值实体化了），现在不会了。
    //
    // ⚠️ 连带：`manager`（`AIChatManager`）这个入参**只为这一张卡存在** ⇒ 一并删掉
    //   （连带 `MacCustomModelListView` / `Settings` 场景 / 渲染夹具那几处 `manager:` 实参）。
    //   本页从此**一条库查询都不做**，全部数据来自 `AIModelStore`（JSON）与 `AIConfig`（UserDefaults）。
    // ☠️ 功能代价写在案：Mac 侧**唯一**能看累计用量、能改单价的地方就是这里 ⇒ 现在**没地方看用量**了。
    //   代码侧 `AIChatManager.usageTotal()` / `clearUsage()` / `AIUsageTotal` **一行没删**
    //   （iOS 设置页「用量与计费」仍在用），要恢复只需把视图加回来 —— 但那要先把 `manager` 传回来。

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            if let saveNote {
                Text(saveNote)
                    .font(MacTheme.ui(12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: discardDrafts) {
                Text(L("取消"))
                    .font(MacTheme.ui(13))
                    .frame(minWidth: 52)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MacAddModelSecondaryButtonStyle())
            Button(action: save) {
                Text(L("保存"))
                    .font(MacTheme.ui(13))
                    .frame(minWidth: 52)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MacAddModelPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!isDirty)
        }
        .padding(.horizontal, padH)
        .padding(.bottom, 18)
    }

    // MARK: - 可复用的外观件

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: fieldRadius)
            .fill(MacTheme.cardBackground)
            .overlay(RoundedRectangle(cornerRadius: fieldRadius).stroke(MacTheme.cardBorder, lineWidth: 1))
    }

    /// 下拉那一颗「值 + 箭头」按钮（供应商与模型名称**共用同一个外观件**）。
    ///
    /// ⚠️ `dimmed`：模型名为空时那句「未设置」是**占位**，得用次要色 —— 否则它与「真的选了一个
    ///    叫未设置的模型」在图上分不开（而用户这一页现在**只能选不能填**，那个空态是常态首屏）。
    private func fieldShell(iconAsset: String?,
                            icon: String?,
                            keepBrandColor: Bool = false,
                            title: String,
                            expanded: Bool,
                            help: String?,
                            dimmed: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if icon != nil || iconAsset != nil {
                    MacProviderIcon(asset: iconAsset, symbol: icon, size: 12, keepBrandColor: keepBrandColor)
                        .foregroundStyle(.primary)
                }
                Text(title)
                    .font(MacTheme.ui(13))
                    .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(MacTheme.ui(11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: fieldHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(fieldBackground)
        .help(help ?? "")
    }

    /// 展开的下拉**浮层**：若干行（+ 可选搜索框）。
    ///
    /// 🔴 它是一个 `.overlay` 的内容，**不占布局高度**（见文件头）。所以这里没有 `Spacer()`
    ///    之类撑高的东西，高度完全由行数决定 —— 列表短，浮层就矮。
    /// ⚠️ 底色必须是**不透明**的（`MacTheme.cardBackground` = `controlBackgroundColor`）：
    ///    浮层是盖在别的控件上的，半透明底会让下面的文字透出来，看着像花了屏。
    /// ⚠️ 描边 + 投影都留着：浅色下 `pageBackground` 与 `cardBackground` **同色**（都是白），
    ///    只靠投影分不出边界，只靠描边看不出「浮起」。
    private func overlayPanel(rows: [MacAddModelRowModel],
                              search: Binding<String>? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let search {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(MacTheme.ui(11))
                        .foregroundStyle(.secondary)
                    TextField("", text: search, prompt: Text(L("搜索")))
                        .textFieldStyle(.plain)
                        .font(MacTheme.ui(12))
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(MacTheme.pageBackground)
                )
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }

            if rows.isEmpty {
                Text(L("没有匹配项"))
                    .font(MacTheme.ui(12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(rows) { row in
                    MacAddModelRowView(model: row) { pick(row) }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: fieldRadius)
                .fill(MacTheme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: fieldRadius).stroke(MacTheme.cardBorder, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
    }

    /// 浮层与控件之间的缝隙。
    private static let panelGap: CGFloat = 6

    /// 收起两个浮层（点面板空白处 / 展开另一个时调）。
    private func closePanels() {
        providerOpen = false
        modelOpen = false
    }

    private func closeProviderPanel() { providerOpen = false }

    private func closeModelPanel() { modelOpen = false }

    /// 两处下拉共用一份回调 —— 按行里带的「是不是供应商那一路」分派（见 `MacAddModelRowModel`）。
    private func pick(_ row: MacAddModelRowModel) {
        if let kind = row.providerKind {
            selectProvider(kind)
        } else {
            modelDraft = row.id
            modelOpen = false
            modelKeyword = ""
        }
    }

    // MARK: - 动作

    /// 进页面时把这一条的一切读进来（草稿、脱敏 Key、模型候选）。
    private func reloadAll() {
        // 🔴 不回填明文（见 `keyDraft`）；输入框永远从空开始，已存的只显示脱敏值。
        keyDraft = ""
        keyCleared = false
        showsPlainKey = false

        // 草稿初值：编辑既有条目 → 用它的值；新增 → 用**供应商的预设值**
        let entry = editingModel
        // 🔴 新增时模型名**预填该家的官方默认模型**（2026-10-19 用户点名要的：
        //    「供应商默认选择了，但模型名称为空」）—— 与换供应商时 `selectProvider` 同源
        //    （都是 `AIProviderKind.defaultModel`，⛔ 别在这两条路各写一个模型名）。
        //    ⚠️ `.custom` 的 defaultModel 是空串 ⇒ 仍显示「未设置」（而 .custom 从界面新建不了，
        //       正常路径走不到）；此时保存键的守卫（模型名非空）会挡住，行为与改动前一致。
        modelDraft = entry?.id ?? vendor.defaultModel
        urlDraft = entry?.url ?? vendor.defaultBaseURL
        storedMaskedKey = AIConfig.masked(entry?.apiKey)
        // ⚠️ 这里**不再装 pricingDraft**：本页没有编辑单价的入口了，保存时也不写这个字段
        //    （见文件头「第三轮」那条：手改 JSON 写过的单价原样留着）。

        // 「原始值」快照 —— `isDirty` 靠它比（见那边注释：⛔ 别改成恒为脏）
        originalModelID = modelDraft
        originalURL = urlDraft
        originalVendorRaw = vendor.rawValue

        modelOptions = AIModelCatalog.candidates(for: vendor, url: urlDraft)
        testNote = nil
        testOK = false
        saveNote = nil
    }

    /// 换供应商**预设**：地址、模型名、能力位跟着它走。
    ///
    /// 🔴 地址**直接重置成该家的默认地址**（`.custom` 则清空）：换了一家的地址留着上一家的，
    ///    是纯粹的陷阱 —— 请求会打到「A 家的模型名 + B 家的地址」上，而界面看起来一切正常。
    ///    ⚠️ 想保留手输地址的用户不受影响：他改地址就行，不换供应商就不会被重置。
    /// 🔴 **模型名同理重置成该家的 `defaultModel`**（2026-10-14 第三轮用户点名要的）。
    ///    ⚠️ 这一条**推翻了本文件旧注释的意图**（原文：“用户可能先填了 Key、选了模型名，
    ///    再回头换供应商，那些不该丢”）—— 那个口径是「模型名能手填」时代立的，现在不成立：
    ///    · 模型名**只能从该家的候选里选**（第二轮改成不可手填）⇒ 留着上一家的模型名
    ///      会得到一个**界面看不出错、请求必然失败**的组合（B 家的地址 + A 家的模型名）；
    ///    · 「不丢」的副作用是用户还得自己再点一次模型名下拉重选 —— 切换供应商本来就意味着
    ///      换一个平台，模型名跟着换才是符合直觉的（iOS 侧`AIAddModelViewController.selectProvider`
    ///      **还没有**这一句，两端暂时分叉）。
    ///    ⚠️ 用 `defaultModel` 而不是「候选里的第一条」：它是**该家的官方默认模型**
    ///    （`AIProviderKind.defaultModel`，地址与它是同一处维护的），而候选清单可能拉不到（离线）。
    /// ⚠️ 只改草稿、**不落库**（草稿语义，见文件头）；其余草稿保留（用户可能先填了 Key）。
    private func selectProvider(_ kind: AIProviderKind) {
        closePanels()
        guard kind != vendor else { return }
        vendor = kind
        urlDraft = kind.defaultBaseURL
        modelDraft = kind.defaultModel
        modelOptions = AIModelCatalog.candidates(for: kind, url: urlDraft)
    }

    /// 丢弃草稿：把界面拉回「存储里的样子」，并关掉这个 sheet。
    ///
    /// ⚠️ 与「保存」共用同一个收尾（`dismiss`）：本页现在是清单页弹出的 sheet
    ///    （改造前它是 Settings 场景的根，关不掉也不必关）。
    private func discardDrafts() {
        closePanels()
        reloadAll()
        dismiss()
    }

    /// 本页有没有未保存的改动（决定「保存」是否可点）。
    ///
    /// 🔴 比的是**与「打开那一刻的快照」**，不是「Key 输入框 ≠ 存着的明文」——
    ///    后者在「输入框从空开始」的前提下**恒为脏**，保存按钮永远亮着，
    ///    用户点一次就会把 Key 清成空串（空串被归一成清除）。
///    ⚠️ 新增一条时快照来自**供应商预设**（模型名 = 该家默认模型、地址是预设默认，
///       2026-10-19 起模型名不再空着手进来），所以「刚打开什么都没动」天然是干净的、
///       保存按钮是灰的 —— 这正是想要的。
    ///    ⚠️ 2026-10-14 第三轮去掉单价那一条（本页已没有编辑单价的入口，那一支恒为 false）。
    ///    换供应商会**连带**改 `modelDraft` / `urlDraft` ⇒ 只要换过，这里必然返回 true。（符合预期）
    private var isDirty: Bool {
        let typedKey = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedKey.isEmpty || keyCleared { return true }
        if modelDraft.trimmingCharacters(in: .whitespacesAndNewlines) != originalModelID { return true }
        if urlDraft.trimmingCharacters(in: .whitespacesAndNewlines) != originalURL { return true }
        if vendor.rawValue != originalVendorRaw { return true }
        return false
    }

    /// 把草稿拼成一条配置。
    ///
    /// 🔴 **起点是「原来那条」（新增时是预设推出来的那条）**，然后只覆盖本页拥有的字段 ——
    ///    这样 `name` / `maxInputTokens` / `maxOutputTokens` / `supportsToolCall` 这些
    ///    「本页不显示但用户可能手改过」的字段会被原样保留。⛔ 别改成从零 `init`
    ///    再逐字段赋值：漏一个就等于**用户手改过的那个字段被悄悄清掉**。
    private func draftEntry() -> AICustomModel {
        let modelID = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let inferred = AICustomModel.inferFrom(kind: vendor, modelID: modelID, url: url)
        var entry = editingModel ?? inferred
        entry.id = modelID
        entry.vendor = inferred.vendor
        entry.url = url
        entry.supportsImages = inferred.supportsImages
        entry.supportsReasoning = inferred.supportsReasoning
        entry.reasoning = inferred.reasoning
        // Key：敲了新的就用新的；明确点了「清除」才置空；**否则保留原来那把**
        // （输入框不回填明文 ⇒ 「没敲」不代表「要清空」，见 `isDirty` 的注释）
        let typed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            entry.apiKey = typed
        } else if keyCleared {
            entry.apiKey = ""
        }
        // ⚠️ **不碰 `entry.pricing`**（2026-10-14 第三轮起本页没有单价入口）：
        //    `entry` 的起点是「原来那条」⇒ 手改 JSON 写过的单价原样保留；
        //    新增时起点是 `inferred`（`pricing == nil`）⇒ 显示与计费都回落到 `AIConfig.defaultPricing`。
        //    ⛔ 别「顺手」在这里写一句 `entry.pricing = …`：那会把默认值**实体化**进文件，
        //    用户手改过的单价也就被覆盖了。
        return entry
    }

    /// 保存：把草稿写进 `AIModelStore`（`Documents/models.json`），然后关掉面板。
    ///
    /// 🔴 **只写被编辑的那一条**，⛔ 不碰 `AIConfig.currentID`
    ///    （编辑配置 = 纯编辑，见文件头与 `render_mac_ui.sh` 的机械契约）。
    /// 🔴 模型名是**键**：用户改名时要「替换原来那条」而不是「多出一条」
    ///    （`AIModelStore.save(_:replacing:)`，见那边注释）。
    /// ⚠️ 模型名为空时**不说保存、给一句提示**：这一条存不进清单（`id` 是它的键）。
    private func save() {
        let modelID = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            saveNote = L("还缺模型名称")
            return
        }
        let entry = draftEntry()
        AIModelStore.save(entry, replacing: editingModel?.id)
        // 把快照推到刚存下的那份（`isDirty` 才不会一直亮着）
        keyDraft = ""
        keyCleared = false
        showsPlainKey = false
        storedMaskedKey = AIConfig.masked(entry.apiKey)
        originalModelID = entry.id
        originalURL = entry.url
        originalVendorRaw = entry.vendor
        saveNote = L("已保存")
        testNote = nil
        // 本页是一次性的编辑面板 ⇒ 保存完就该收起（用户回到清单页看结果）
        dismiss()
    }

    /// 「测试连接」：打一次 `/models`。
    ///
    /// 判据不是「发一条最小对话」（那要花 token）：一次 GET 同时验完
    /// 「地址对不对 / Key 对不对 / 能拿到哪些模型」，成功还会把清单写进缓存 ⇒ 下拉立刻变长。
    /// ⚠️ 用**草稿里的地址与 Key**（敲了新的就用新的，没敲就用已存的）——
    ///    面板是「保存」才落库，拿存着的那份去测等于测了个旧配置（症状：Key 填错了却提示成功）。
    /// ⚠️ 成功**不代表**已经保存 —— 保存仍然要点那颗按钮。
    private func runTest() {
        testing = true
        testNote = nil
        let kind = vendor
        let url = urlDraft
        let typed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // 输入框空 ⇒ 显式用**这一条**已存的 Key。
        // 🔴 ⛔ 别传 nil：`AIModelCatalog.fetch(apiKey: nil)` 会回落 `AIConfig.currentAPIKey`
        //    = **当前选中条目**的 Key —— 在清单里编辑*别的*条目时，测的就是别人的 Key
        //    （2026-10-16 用户实测：空框点测试却成功，正是回落到了刚在用的那条）。
        //    连已存的也没有 ⇒ 空串：不带 Authorization，服务端 401 ⇒ 「API Key 是空的」。
        let storedKey = editingModel?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        AIModelCatalog.fetch(for: kind, url: url, apiKey: typed.isEmpty ? storedKey : typed) { result in
            testing = false
            switch result {
            case .success(let models):
                testOK = true
                testNote = String(format: L("连接成功 · 拉到 %d 个模型"), models.count)
                // 只在还停在同一家 + 同一个地址时才刷清单（用户可能在等待期间改了）
                if vendor == kind, urlDraft == url {
                    modelOptions = AIModelCatalog.candidates(for: kind, url: url)
                }
            case .failure(let error):
                testOK = false
                testNote = String(format: L("连接失败：%@"), error.localizedDescription)
            }
        }
    }
}

// MARK: - 下拉行

/// 下拉里一行的**展示模型**（纯值，方便 `ForEach` 与预览）。
struct MacAddModelRowModel: Identifiable {
    /// 兜底 id（`Identifiable` 要求）；真正回落库判据看下面两个字段。
    let id: String
    /// 非 nil = 这是**供应商**那一路的行（点它换编辑目标）。
    /// ⚠️ 刻意用「带着哪个供应商」而不是「拿 id 去 `AIProviderKind(rawValue:)` 反查」：
    ///    模型名与供应商名理论上可能撞（比如某家真出了个叫 `kimi` 的模型），
    ///    那时点模型会把编辑目标换掉 —— 一个很难复现、且完全看不出原因的 bug。
    let providerKind: AIProviderKind?
    /// 供应商品牌 asset 名（模型那一路传 nil）。
    /// ⚠️ 与 `icon` 并存：asset 缺失时由 `MacProviderIcon` 退回符号。
    let iconAsset: String?
    /// 供应商图标（SF Symbols 兜底；模型那一路传 nil）。
    let icon: String?
    let title: String
    let note: String?
    let selected: Bool
    let help: String?
}

/// 下拉里一行：图标 + 标题（+ 说明）+ 打勾。悬停有底色。
private struct MacAddModelRowView: View {

    let model: MacAddModelRowModel
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if model.icon != nil || model.iconAsset != nil {
                    MacProviderIcon(asset: model.iconAsset,
                                    symbol: model.icon,
                                    size: 12,
                                    keepBrandColor: model.providerKind?.iconKeepsBrandColor ?? false)
                        .foregroundStyle(.primary)
                        .frame(width: 16)
                }
                Text(model.title)
                    .font(MacTheme.ui(13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = model.note, !note.isEmpty {
                    Text("— " + note)
                        .font(MacTheme.ui(11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.selected {
                    Image(systemName: "checkmark")
                        .font(MacTheme.ui(11, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // ⚠️ 悬停底色由 `onHover` 驱动；离屏渲染里没有指针 ⇒ 恒为常态（那一档图看的是常态）。
        .background(hovered ? Color.primary.opacity(0.06) : Color.clear)
        .help(model.help ?? "")
        .onHover { hovered = $0 }
    }
}

// MARK: - 按钮样式

/// 「保存」那颗：实心深色底 + 反色字（对齐参考图）。深浅色下自动反过来（不写死黑白）。
///
/// ⚠️ 这两个样式**清单页（`MacCustomModelListView`）也在用**（那边的「添加模型」是次要按钮）
///    —— 所以它们不是 `private`，而且名字里的「AddModel」不要理解成「只有加模型那一页能用」。
///    改外观只改这一处，⛔ 别在调用方那里再叠一层样式。
struct MacAddModelPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.75 : 0.85))
            )
    }
}

/// 「取消 / 测试连接 / 恢复默认 / 添加模型」那颗：白底 + 描边。
struct MacAddModelSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0.0))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(MacTheme.cardBorder, lineWidth: 1))
            )
    }
}
