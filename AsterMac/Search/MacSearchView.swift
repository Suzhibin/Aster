//
//  MacSearchView.swift
//  AsterMac
//
//  搜索页：侧栏最上面那颗「搜索对话」弹出来的面板，用来**搜历史对话**。
//
//  ## 入口为什么不在这里
//  入口在**窗口工具栏**上（`RootView` 里 `.toolbar` 挂在侧栏那一列上 —— 与系统那颗
//  「收起/展开侧栏」按钮同格，也就是原来「新建对话（＋）」占的位置）；
//  快捷键 ⌘F 挂在 App 菜单上（`AsterMacApp.commands`）。
//  本文件只管「弹出来之后长什么样」—— 与 `ScrollToBottomButton` 同一条分工：
//  形状归视图，**什么时候出现、点了做什么**归调用方。
//  ⚠️ 入口搬过两次家（工具栏 → 侧栏第一格 → 回工具栏、但换了挂法），本文件**一行没动** ——
//     这正是这条分工的意义：谁负责弹出这件事变了，页面本身不用跟着改。
//
//  ## 为什么是 sheet
//  「点搜索按钮弹出」= 一个临时面板。macOS 上对应的就是 sheet：贴着标题栏滑下来、
//  Esc 可关、不参与窗口尺寸记忆。
//  ⛔ 别改成独立窗口（`Window` 场景）：那会多出一个窗口菜单项，而搜索是「用完就走」的
//     动作，不是第二个工作区。
//
//  ## 数据从哪来：`ChatModel.searchHistory(keyword:)`
//  视图**不直连** `AIChatStore`（与 iOS 侧搜索页同一约定：`searchProvider` 注入）。
//  换数据源 / 加缓存时本文件不用动。
//
//  ## 🔴 抖动窗口是**能用的前提**，不是优化
//  `AIChatStore.search` 是「把全库消息读进内存 + 全文匹配」的一次**同步**扫描，
//  而且 Mac 这边是在主线程上跑的（业务层是同步 API，没有后台队列可借，见
//  `AIChatManager.search` 的说明）。每按一个键扫一遍全库，打 8 个字就是 8 遍 ——
//  真卡起来是**转菊花**，比 iOS 那边「按一下卡一下」还难看。
//  200ms 是「打字停顿」与「手感不延迟」之间的常用折中；**清空输入**那条路不等它
//  （不查库，直接回空态）。
//  ⚠️ 真到了「上万条消息、主线程也扛不住」的时候，正确做法是把扫描挪到后台
//     （那要先让 `AIChatSearchHit` 满足 `Sendable`），而不是把抖动调大 —— 调大只是把
//     卡顿换成延迟。
//
//  ## 高亮的 range 从哪来
//  从命中记录自己带的 `titleRanges` / `snippetRanges`（业务层 `AISearchMatcher` 算的）。
//  🔴 本文件**不重算**关键词位置 ——「算位置」与「画位置」一旦分成两处，迟早出现
//  「列表里高亮偏一个字符」。这条铁律两端（iOS / Mac）的搜索页共用。
//
//  ## 与 iOS 侧的信息结构**故意有一处分叉**
//  标题命中那条记录，业务层给的 `snippet` 就是**标题本身**（见 `AIChatStore.search` ①）——
//  iOS 的 cell 照画，于是同一条文案上下各出现一次。Mac 这边**片段与标题相同时不画第二行**
//  （见 `row(_:index:)`）：重复两遍看起来只像 bug，不像信息。其余（标签文案、空态文案、
//  标题命中排最前）与 iOS 保持一致。
//
//  ## 怎么验的
//  离屏渲染（`render_mac_ui.sh`）能验布局与高亮，但有三条限制（`ScrollView` 内容不渲染、
//  `LazyVStack` 不 materialize、`TextField` 画成黄条+⊘）—— 脚本里已做机械替换，
//  并且**用初值改写造出「有结果」「悬停」两个离屏造不出的状态**（见脚本 ③.5）。
//  键盘聚焦、Esc、点击打开这三件事离屏验不了，要 ⌘B 真跑一次。
//

import SwiftUI
import AICore

struct MacSearchView: View {

    @Environment(ChatModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    /// 输入框里的原文（可能带首尾空格，查库前才 trim）
    @State private var keyword = ""
    @State private var hits: [AIChatSearchHit] = []
    /// 在飞的那次抖动任务。新的一次进来先取消它 —— 连打字只会跑最后那一次。
    @State private var searchTask: Task<Void, Never>?
    /// 指针停在第几行（`nil` = 没停在任何一行）。离屏渲染没有指针，脚本会改初值造出它。
    @State private var hoveredIndex: Int?

    /// 进来就聚焦：搜索是个「打开就打字」的页面，多一次点击纯属浪费。
    @FocusState private var fieldFocused: Bool

    private static let debounceNanoseconds: UInt64 = 200_000_000

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            results
            if !hits.isEmpty {
                Divider()
                footer
            }
        }
        .frame(width: MacTheme.searchPageWidth, height: MacTheme.searchPageHeight)
        // 显式刷底：结果行的 hover 底是「相对底色」算的（`Color.primary.opacity`），
        // 底与它必须一起定 —— 不写这一句，暗色下 hover 的比例会落到 sheet 的默认底上，
        // 明暗两张渲染图就对不上了。
        .background(MacTheme.pageBackground)
        .onAppear { fieldFocused = true }
        .onChange(of: keyword) { _, newValue in scheduleSearch(newValue) }
        // 面板正在关就别再查了：那一次扫描的结果没人看，还占着主线程
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: - 顶部：搜索框 + 取消

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(MacTheme.ui(MacTheme.searchFieldIconSize))
                    .foregroundStyle(MacTheme.meta)
                TextField(L("搜索对话"), text: $keyword)
                    .textFieldStyle(.plain)
                    .font(MacTheme.ui(MacTheme.searchFieldFontSize))
                    .focused($fieldFocused)
                    // 回车 = 「我现在就要结果」，不等抖动窗口；顺手打开第一条
                    // （与 iOS 侧「回车立刻搜」同一个意思，只是那边不自动打开）
                    .onSubmit { if let first = hits.first { open(first) } }
                if !keyword.isEmpty {
                    Button {
                        keyword = ""      // 清空 → 回空态（不查库，见 `scheduleSearch`）
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(MacTheme.ui(MacTheme.searchFieldIconSize))
                            .foregroundStyle(MacTheme.meta)
                    }
                    .buttonStyle(.plain)
                    .help(L("清空"))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: MacTheme.searchFieldHeight)
            .background(
                RoundedRectangle(cornerRadius: MacTheme.searchFieldRadius)
                    .fill(MacTheme.searchFieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MacTheme.searchFieldRadius)
                    .strokeBorder(MacTheme.searchFieldBorder, lineWidth: 1)
            )

            // 面板的「退出」必须有一条能看见的路。Esc 也走它（`.cancelAction`）。
            Button(L("取消")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, MacTheme.searchPaddingH)
        .padding(.vertical, MacTheme.searchHeaderPaddingV)
    }

    // MARK: - 结果区

    private var results: some View {
        Group {
            if hits.isEmpty {
                MacSearchEmptyHint(keyword: trimmedKeyword)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: MacTheme.searchRowSpacing) {
                        ForEach(Array(hits.enumerated()), id: \.offset) { item in
                            row(item.element, index: item.offset)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 一行结果：**标题**（命中处高亮）+ 角色标签 + 片段（命中处高亮）+ 时间。
    ///
    /// 整行是一个 `Button` 而不是 `.onTapGesture`：前者自带「可点」的语义
    /// （键盘可达、旁白认得出、按下有反馈），后者只是一个手势。
    private func row(_ hit: AIChatSearchHit, index: Int) -> some View {
        Button {
            open(hit)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: MacTheme.searchRowInnerSpacing) {
                    highlighted(hit.displayTitle, ranges: hit.titleRanges)
                        .font(MacTheme.ui(MacTheme.searchTitleFontSize, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // ⚠️ 标题命中的 `snippet` 就是标题本身 —— 不画（见文件头「故意分叉」）。
                    if hit.snippet != hit.displayTitle {
                        HStack(alignment: .top, spacing: 6) {
                            Text(hit.roleText)
                                .font(MacTheme.ui(MacTheme.searchSnippetFontSize, weight: .medium))
                                .foregroundStyle(MacTheme.searchHighlight)
                                // 定宽：「标题 / 我 / AI」字数不一，不定宽第二列的起始位置就会抖
                                .frame(width: 22, alignment: .leading)
                            highlighted(hit.snippet, ranges: hit.snippetRanges)
                                .font(MacTheme.ui(MacTheme.searchSnippetFontSize))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                Spacer(minLength: 8)
                // 时间只取现成的格式化入口（业务层 `AIMessageTime`）——
                // ⛔ 视图层别自己 new `DateFormatter`（那是「同一件事两处各写一遍」）
                Text(AIMessageTime.string(from: hit.updatedAt))
                    .font(MacTheme.ui(MacTheme.metaFontSize))
                    .foregroundStyle(MacTheme.meta)
                    .fixedSize()      // 时间不许被标题挤掉；要挤先挤标题
            }
            .padding(.horizontal, MacTheme.searchRowPaddingH)
            .padding(.vertical, MacTheme.searchRowPaddingV)
            // 整行可点：不加它，只有文字那几个像素吃点击，行内的空白会漏成「点不动」
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: MacTheme.searchRowRadius)
                    .fill(hoveredIndex == index ? MacTheme.searchRowHoverBackground(scheme) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            // 移出时只清「自己那一行」：快速划过两行时，后一个 onHover(false) 会把
            // 新那一行的悬停态清掉（光标已经挪过去了，事件顺序不保证）
            hoveredIndex = inside ? index : (hoveredIndex == index ? nil : hoveredIndex)
        }
    }

    // MARK: - 底部计数

    private var footer: some View {
        HStack(spacing: 8) {
            Text(String(format: L("%d 条结果"), hits.count))
            Spacer(minLength: 0)
            Text(L("回车打开第一条"))
        }
        .font(MacTheme.ui(MacTheme.metaFontSize))
        .foregroundStyle(MacTheme.meta)
        .padding(.horizontal, MacTheme.searchPaddingH)
        .padding(.vertical, 6)
    }

    // MARK: - 搜索

    private var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 输入变化 → 抖动窗口后查一次。
    ///
    /// `Task.sleep` 版防抖：新的一次先把上一个 `cancel()` 掉，所以连打字只会跑最后那一次
    /// （等价于 iOS 侧那个 `DispatchWorkItem` + `cancel`）。
    /// ⚠️ 查库仍在主 actor 上：业务层是同步 API（见文件头），这里不假装它是异步的。
    private func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        let kw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else {
            hits = []           // 清空 = 用户要看「没输入」的空态；不查库、也就没延迟
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            let result = model.searchHistory(keyword: kw)
            guard !Task.isCancelled else { return }
            hits = result
        }
    }

    /// 打开一条结果：**先让业务层落定，再关面板**。
    ///
    /// 顺序反过来的话，面板还在收，右栏已经在换会话 —— 看起来像「闪了一下又变」。
    /// 业务层要做的两件事（切会话 + 请右栏滚到命中那条）见 `ChatModel.open(searchHit:)`。
    private func open(_ hit: AIChatSearchHit) {
        model.open(searchHit: hit)
        dismiss()
    }

    // MARK: - 高亮

    /// 把命中位置画成高亮文字。**位置**来自命中记录（业务层算的），这里只切段与上色。
    ///
    /// 用 `Text` 拼接而不是 `AttributedString`：`Text + Text` 的样式是**片段级**的，
    /// 拼出来的整段在换行 / 截断上的行为与单个 `Text` 完全一致；而 `AttributedString`
    /// 那条路要额外做 `NSRange → Range<AttributedString.Index>` 的转换，
    /// 多一处会算错的算术，而这里是「算错了也看不出来，只觉得高亮偏了一点」的地方。
    private func highlighted(_ text: String, ranges: [NSRange]) -> Text {
        let ns = text as NSString
        guard !ranges.isEmpty, ns.length > 0 else { return Text(text) }
        var result = Text("")
        var cursor = 0
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            // 越界 / 重叠一律跳过：宁可少高亮一处，也不能让 `substring` 越界把页面搞崩
            guard range.location != NSNotFound,
                  range.location >= cursor,
                  NSMaxRange(range) <= ns.length else { continue }
            if range.location > cursor {
                result = result + Text(ns.substring(with: NSRange(location: cursor,
                                                                 length: range.location - cursor)))
            }
            result = result + Text(ns.substring(with: range))
                .foregroundColor(MacTheme.searchHighlight)
            cursor = NSMaxRange(range)
        }
        if cursor < ns.length {
            result = result + Text(ns.substring(with: NSRange(location: cursor,
                                                             length: ns.length - cursor)))
        }
        return result
    }
}

/// 搜索页的空态（**单独成类型**，两个理由）。
///
/// ① 两种空态（「还没输入」/「搜不到」）只差文案，放在一起才看得出它们是同一件事的两面；
/// ② 离屏渲染台能把它**单独拎出来**渲一张 —— 空态长在滚动区里，而 `ScrollView` 的内容
///    渲染不出来（与 `SidebarSettingsBar` / `SidebarQuickEntries` 同一个理由：
///    能独立成图的东西才有图能证明）。
struct MacSearchEmptyHint: View {
    /// 已输入的关键词（空串 = 「还没输入」那一态）
    let keyword: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: keyword.isEmpty ? "magnifyingglass" : "magnifyingglass.circle")
                .font(MacTheme.ui(26))
                .foregroundStyle(.tertiary)
            Text(keyword.isEmpty
                 ? L("输入关键词，搜索全部对话\n标题和聊天内容都会匹配")
                 : String(format: L("没有找到与「%@」相关的内容"), keyword))
                .font(MacTheme.ui(12))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
