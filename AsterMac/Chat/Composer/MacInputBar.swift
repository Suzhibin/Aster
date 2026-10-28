//
//  MacInputBar.swift
//  AsterMac
//
//  底部输入区（Composer）：**一张卡片** + 卡片下方一行免责声明。
//
//  ## 结构（2026-09-22 按用户给的参考图重做，别按旧版的分法改回去）
//
//  ```
//  ┌────────────────────────────────────────────────────────┐
//  │  ⌜ “被引用的那段内容”                            ✕ ⌟    │ ← 引用条（只有点过「⋯ → 引用」才出现）
//  │  [附件小卡] [附件小卡]                                   │ ← 只有选了附件才出现
//  │  今天帮你做些什么？                                      │ ← 多行文本区（1…10 行）
//  │                                                        │
//  │  ＋                               ◌  🖥 模型 ⌄  🎤  ⬆  │ ← 控制行
//  └────────────────────────────────────────────────────────┘
//                  内容由 AI 生成，请核实重要信息
//  ```
//
//  - 旧版是「输入框 + 输入框**外面**一排小字（模型名 / ⏎ 提示）」，控制行在卡片外；
//    新版把控制行放进卡片**内部**，整块只有一张卡片 —— 这是参考图的骨架。
//  - 旧版输入栏有自己的底色 + 顶部 1pt 分隔线；新版**去掉**了，卡片自己就是那一块「面」
//    （见 `MacTheme` 的 `composerBackground` 那条注释）。所以这里刷的是**页面背景**。
//  - **引用条在卡片内部的最上面**（2026-09-29 加，`ComposerQuoteBar`）：放在卡片外会破坏
//    「整块只有一张卡片」这个骨架；排在附件条之前是因为它是「这条消息要带上什么上下文」。
//    ⚠️ iOS 那边这条是**输入栏自己的 banner 区**（`AIComposerBannerView`），位置语义相同、
//    容器不同 —— 与录音板同款的「同语义、各随平台」。⛔ 别为了「两端一致」把它挪到卡片外。
//
//  ## 控制行上各控件的能力边界（用户明确同意「其他按钮先不实现」）
//  | 控件 | 状态 |
//  |---|---|
//  | `+`（截图提问 / 上传文件或图片） | ✅ **已接**（`ComposerAttachmentPicker` + `ChatModel.pendingAttachments`） |
//  | 模型选择 | ✅ **已接**（`Menu` + `AIModelCatalog.choices()` = `models.json` 里的条目，见下面 `modelMenu`） |
//  | 🎤 语音输入 | ✅ **已接**（点击开始 / 点击结束，面板见 `VoiceRecordingPanel`，会话在 `ChatModel` 的「语音输入」段） |
//  | 送信 / 停止 | ✅ 已接（⏎ 发送、⌘⏎ 发送；流式中同一位置变「停止」；**录音中变「结束并发送」**） |
//  | ~~`main`（工作区）/ `默认权限`~~ | 🗑 **2026-09-29 删除**（用户要求）。原先那两个块点了只弹一句
//  |    | 「还没接」—— **那是在承诺做不到的事**，与文件尾 `placeholder` 那段是同一条口径
//  |    | （那边刻意没照抄参考图的「@ 添加上下文，/调用技能与指令」也是这个理由）。
//  |    | 删后左侧只剩 `+`，**与 iOS 输入栏同构**（iOS 那边本来就只有 相机 / 语音 / `+` / 停止）。
//  |    | ⚠️ 将来真要接「工作区」：入口应该在**侧栏**（那是「我在哪个项目里」这种跨会话的选择），
//  |    | 不在输入框这一行 —— 这一行只放「每轮都可能变、且变了要立刻看见」的开关（模型 / 语音）。 |
//  | 引用条（卡片顶部） | ✅ **2026-09-29 加**（`ComposerQuoteBar` + `ChatModel.pendingQuote`）：
//  |    | 由消息操作栏的「⋯ → 引用」写入、发送成功后自动清空（`ChatModel.send`）。
//  |    | ⚠️ 它**不是控制行上的控件**，是卡片内独立的一条 —— 别混进上面那张控制行表。 |
//
//  🔴 这颗模型选择器是**全 App 唯一换模型的入口**（2026-09-22 用户定，2026-10-14 JSON 化后口径不变）：
//     设置侧（「自定义模型」清单页 +「添加模型」表单）只管**清单里有哪些**，不回答「现在用哪个」
//     （⛔ 它不许写 `AIConfig.currentID`，`render_mac_ui.sh` 有机械契约盯着）——
//     所以列表 = 文件里那些条目，选一项 = 写当前指针，见 `modelMenu` 的注释。
//
//  ## 键位的取舍（沿用旧版结论）
//  ⏎ 发送、⇧⏎ 换行 —— 多数 Mac 聊天客户端的习惯，但 `TextField(axis: .vertical)`
//  在不同 macOS 版本上对 ⏎ 的处理不完全一致（有可能插换行而不是提交）。所以两条路都给：
//    - `.onSubmit` 接 ⏎（认它是提交时就生效）；
//    - 送信按钮挂 ⌘⏎（不认时用这个，按钮本身也一直可点）。
//  两个入口都落到同一个 `model.send()`。
//

import SwiftUI
import AppKit
import AICore

struct MacInputBar: View {
    @Environment(ChatModel.self) private var model

    /// 指针是否停在 `+` 那颗上（2026-10-22 加）。只驱动 hover 底色、**不改任何布局** ——
    /// 与账号栏那颗同一手法（底块恒占位、只翻色，否则行高会跟着指针抖）。
    ///
    /// 🔴 为什么这颗要一个**自己的** `@State`：`+` 是 `Menu`（不是 `Button`），它的
    /// label 里那颗 `ComposerGlyphLabel` 自带的 `onHover` **在 Menu 宿主下不触发** ——
    /// 2026-10-22 用户报「鼠标移到 + 上没有背景变深的效果」，根因就在这里
    /// （联网 / 🎤 两颗是 `Button` 宿主，同一个 label 组件就好使）。
    /// ⇒ hover 信号改由**外层容器**收（指针一进 bounds 就一定收到，侧栏行同机制），见 `plusMenu`。
    @State private var plusHovered = false

    /// 指针是否停在**模型块**上（2026-10-22 加）。与 `plusHovered` 同源同因：
    /// `modelMenu` 也是 `Menu` 宿主，label 里 `ComposerChipVisual` 自带的 `onHover`
    /// 同样不触发 ⇒ 也由外层容器收信号，见 `modelMenu`。
    @State private var modelMenuHovered = false

    /// 明暗分档要读（hover 底的透明度两档不同，与账号栏那颗同一个原因）。
    @Environment(\.colorScheme) private var colorScheme

    /// 「+ → 项目资料」那张表开没开（2026-10-21）
    @State private var projectPickShown = false

    /// `@` 唤出的项目资料选择页（2026-10-21）。
    ///
    /// ⚠️ 与 `projectPickShown` **分成两个开关**，虽然弹的是同一个视图：
    ///    差别在**选完之后干什么** —— 「＋」是导入一份副本变成附件，
    ///    「@」是引用项目里那一份（不复制）。合成一个开关就必须再带一个 mode 变量，
    ///    而那条路一旦写反，表现是「@ 也悄悄复制了一份文件」或「＋ 不再复制」（都不报错）。
    @State private var mentionPickShown = false

    var body: some View {
        VStack(spacing: MacTheme.composerFooterSpacing) {
            // 🔴 录音浮层**不在这里**（2026-10-03 搬走）。它改成「铺满整宽、贴窗口最底部」之后
            //    必须盖住输入栏本身，所以挂在 `ChatDetailView` 的 `.overlay(alignment: .bottom)` 上。
            //    ⛔ 别为了「少写一处接线」把它挪回这一列 —— 那样它只能长在卡片上方，
            //       而那正是用户否掉的旧形态（豆包那块是顶着屏幕底边的）。
            card
            disclaimer
        }
        .padding(.horizontal, MacTheme.composerMarginH)
        .padding(.top, MacTheme.composerMarginTop)
        .padding(.bottom, MacTheme.composerMarginBottom)
        // 卡片浮在页面底上 —— 这一块**不留栏底色、不画分隔线**（与旧版相反）。
        .background(MacTheme.pageBackground)
        // 「+ → 项目资料」（2026-10-21 L2）：列出当前会话所属项目的资料，选一份带进待发送列表。
        // ⚠️ 用 `ProjectDetailView` 的**选取态**（`onPick` 非 nil）而不是另写一张表 ——
        //    同一份列表两处实现，必然出现「一边改了行、另一边没改」（同 iOS 侧那条注释）。
        .sheet(isPresented: $projectPickShown) {
            if let project = currentProject {
                ProjectDetailView(project: project,
                                  onPick: { file in model.attachProjectFile(file) })
                    // 与侧栏那张 sheet 同一条：显式再灌一次环境（见那边的注释）
                    .environment(model)
            }
        }
        // `@` 唤出的选择页：同一张列表，选完**只是引用**（`addMention`，不拷贝文件）。
        // ⚠️ 不能复用上面那个 sheet：`onPick` 不同（见 `mentionPickShown` 的注释）。
        .sheet(isPresented: $mentionPickShown) {
            if let project = currentProject {
                ProjectDetailView(project: project,
                                  onPick: { file in model.addMention(file) })
                    .environment(model)
            }
        }
        // `@` 触发（2026-10-21）：只在**行尾**打出的那一个 `@` 才算。
        //
        // 🔴 为什么只认行尾：Mac 输入框是 SwiftUI `TextField`，**拿不到光标位置**
        //    （要拿得走 `ComposerFieldEditorDragSuspender` 那套视图树找字段编辑器，
        //     而那条路是为拖拽写的、有"字段编辑器会随焦点重建"的已知不确定性）。
        //    「用户在句末打 @」是这个功能的主用法，覆盖它、并把这个限制写在文档里，
        //    比为了句中的 @ 去赌一套焦点时机要稳得多。
        // ⚠️ 判据必须带 `!old.hasSuffix("@")`：否则每敲一个字（draft 变了）都会再弹一次。
        .onChange(of: model.draft) { old, new in
            guard new.hasSuffix("@"), !old.hasSuffix("@") else { return }
            mentionPickShown = true
        }
    }

    /// 当前会话所属项目（2026-10-25 起恒非 nil ⇒ 「+」菜单里恒有「项目资料」；
    /// 旧注释「nil = 未归类 ⇒ 不出现」随「未归类」消灭一起作废）
    private var currentProject: AIChatProject? {
        guard let id = model.activeProjectId else { return nil }
        return model.projects.first { $0.id == id }
    }

    /// 送信按钮能不能点。
    ///
    /// ⚠️ 判据是「有字**或**有附件」：纯附件消息（截图直接发）是合法的一条消息，
    /// 业务层的 `send(_:attachments:)` 也支持正文为空。旧版只判文字，那样选完图
    /// 还得随便打个字才能发（用户会以为图没选上）。
    /// ⚠️ 录音中恒为真：那一拍它不是「发送草稿」而是「结束并发送」，见 `sendButton`。
    private var canSend: Bool {
        guard !model.isStreaming else { return false }
        if model.isVoiceRecording { return true }
        if !model.pendingAttachments.isEmpty { return true }
        // 只 @ 了资料、一个字没打也发得出去（业务层会把正文回填成 `@名字`）
        if !model.pendingMentions.isEmpty { return true }
        return !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 卡片

    private var card: some View {
        VStack(alignment: .leading, spacing: MacTheme.composerTextControlSpacing) {
            // 引用条（2026-09-29）：操作栏「⋯ → 引用」点过之后挂在这里，直到发送 / 点 × / 换会话。
            // 🔴 排在**附件条之前**：它是「这条消息要带上什么上下文」，比附件更接近消息本身；
            //    而且它最多两行、高度会变，放在最上面时「卡片变高」这件事一眼看得出是它干的。
            if let quote = model.pendingQuote {
                ComposerQuoteBar(quote: quote) { model.cancelQuote() }
            }
            if !model.pendingAttachments.isEmpty { attachmentStrip }
            // `@` 项目资料（2026-10-21）：附件条之后、文本区之前 —— 见 `ComposerMentionBar` 文件头
            if !model.pendingMentions.isEmpty {
                ComposerMentionBar(items: model.pendingMentions) { index in
                    model.removeMention(at: index)
                }
            }
            textArea
            controlRow
        }
        .padding(.horizontal, MacTheme.composerPaddingH)
        .padding(.top, MacTheme.composerPaddingTop)
        .padding(.bottom, MacTheme.composerPaddingBottom)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.composerRadius)
                .fill(MacTheme.composerBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacTheme.composerRadius)
                .stroke(MacTheme.composerBorder, lineWidth: 1)
        )
        // 把「本窗口」交给拖拽那一套（见 `ComposerFieldEditorDragSuspender` 文件头）：
        // 文件拖到输入框上时，要靠它把字段编辑器**临时**挂起，否则松手会变成一段路径文字。
        // ⚠️ 它不画东西也不占位，挂在哪里都行 —— 放在这里是因为「输入框所在的窗口」这件事
        //    只有输入栏自己最清楚（设置页是另一个窗口，别去猜 `NSApp.mainWindow`）。
        .background { ComposerWindowHint() }
    }

    // MARK: - 文本区

    private var textArea: some View {
        TextField(Self.placeholder, text: draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(MacTheme.body)
            .lineLimit(1...10)
            // 最小高度给到两行（参考图里那块空白更大，但那是它的窗口富余）——
            // 太矮会显得输入区「只够写一句」，太高则把消息列表挤掉。
            .frame(minHeight: MacTheme.composerTextMinHeight, alignment: .topLeading)
            .onSubmit { model.send() }
    }

    // MARK: - 控制行

    private var controlRow: some View {
        HStack(spacing: MacTheme.composerControlSpacing) {
            // ① 添加内容（截图提问 / 上传文件或图片）—— 本行左侧唯一的入口
            plusMenu
            // ② 联网搜索开关（2026-10-21）。**每轮会变**、变了要立刻看见 ⇒ 家就在这里，
            //    ⛔ 别搬进设置页（搬进去等于「一开永久生效」，用户想在某个问题前临时关一下就没地方点）
            webSearchButton
            // ②b 项目资料检索开关（放大镜）**2026-10-23 已删**：用户拍板「默认关闭 +
            //     删入口」。底层检索链路全保留（`beginProjectRetrieval` / 片段表 /
            //     导入即建索引 / 详情页索引状态行），删的只是「谁能把它打开」——
            //     恢复指南见 `VERIFY-PROBES.md` §32.4，⛔ 别"顺手补一颗"填这个空。
            // ⚠️ 左侧原先还有「工作区（`main`）」与「默认权限」两颗占位块，**2026-09-29 已删**
            //    （用户要求，见文件头那张能力边界表）—— 它们点了只弹一句「还没接」。
            //    ⛔ 别再"顺手补一颗"填这个空：这一行只放**每轮都可能变、且变了要立刻看见**的
            //    开关（模型 / 语音是这个性质；工作区 / 权限是设置一次就不动的，家在设置页）。
            //    真想填这块空间，优先考虑**只读的会话状态**（上下文条数 / token 用量这类数字），
            //    而不是又一颗按钮 —— 只读文本不会误点、也不会「点了看不出效果」。

            Spacer(minLength: 8)

            // ③ 右侧：收流中先一个转圈（参考图里送信按钮左边那个半圈环），再模型、麦克风、送信
            if model.isStreaming || model.isSearchingWeb {
                ComposerSpinner()
                    // 联网那 1–4 秒里**要说清楚在等什么**：只说「正在回答」会让用户以为模型慢
                    .help(model.isSearchingWeb ? L("正在联网搜索…") : L("正在回答…"))
            }
            modelChip
            micButton
            sendButton
        }
        .frame(height: MacTheme.composerControlHeight)
    }

    /// 模型那一格：**有可选列表就是选择器，没有就退回「点了给个说法」**。
    ///
    /// 🔴 2026-10-14 起「列表为空」**是真的会发生了**：清单来源是用户自己攒的
    ///    `Documents/models.json`（首次启动会播三家预设各一条，但用户可以把它们全删掉）。
    ///    改造前列表里恒有内置条目，这个降级分支只是防御；现在它是**一条真实路径** ——
    ///    所以这里那句说法必须给出「去哪儿加一条」（见 `modelListEmptyHint`）。
    @ViewBuilder
    private var modelChip: some View {
        if !model.modelChoices.isEmpty {
            modelMenu
        } else {
            ComposerChipLabel(icon: Self.modelIcon,
                              title: model.currentModelLabel,
                              help: Self.modelUnavailableHelp) {
                model.show(Self.modelListEmptyHint)
            }
        }
    }

    /// 模型选择器（下拉列表）—— 列出**已配置的那些模型**，也是全 App 唯一换模型的入口。
    ///
    /// 列表取自 `ChatModel.modelChoices`（= `AIModelCatalog.choices()`，读 `Documents/models.json`），
    /// 每一项 = 一条配置，行文案形如 `deepseek-flash — 深度求索`。
    ///
    /// 🔴 **2026-10-14 起的语义变化**：改造前这份列表是「跨平台」的
    ///    （`availableAcrossPlatforms`：三家的可选模型全列，选一项 = 换平台 + 换模型），
    ///    因为当时设置页只编辑单个平台、换平台得另找入口。
    ///    现在**清单页只管清单、不回答「用哪个」**，而且一条配置自带地址 ——
    ///    「换平台」不再是一个动作：选哪一条，就等于从那一条背后的服务要回复。
    ///    于是这里的列表就是用户攒的那几条，不再拼平台。
    ///
    /// 🔴 与「自定义模型」清单页（`MacCustomModelListView`）的**分工**（别混）：
    ///    - 清单页 = **配置**（长期：有哪些模型、各自的地址与 Key）；
    ///    - 这里 = **这一会儿用哪一条**（运行时的一个指针，`AIConfig.currentID`）。
    ///    所以「在清单页里改了配置，聊天窗口还是旧的」不是 bug —— 改的是配置，不是当前选择。
    ///
    /// 🔴 用 `Picker` + `.pickerStyle(.inline)` 装在 `Menu` 里，而不是自己排一排 `Button`：
    ///    这是 macOS 上「一组互斥选项 + 给当前项打勾」的系统写法 —— 打勾、键盘上下选择、
    ///    点外面关闭全由系统给。自绘那一套三件事都得自己写，而且行高/高亮与系统菜单对不齐。
    ///    （与上面 `plusMenu` 同一个理由。）
    ///
    /// ⚠️ **不要**在 label 里自己画 `chevron.down`：`Menu` 会把 label 末尾那颗「像指示器」的
    ///    `Image` 吞掉（2026-09-22 用独立探针排过 5 个变体，带与不带自定义箭头的渲染结果
    ///    **逐像素一样**，只剩系统那一个），而配上的 `.menuIndicator(.hidden)` 会让箭头
    ///    **彻底不见** —— 块上看不出「这里能点开」。所以这里 `trailingChevron: false`
    ///    且**不写** `.menuIndicator(.hidden)`，把箭头交给系统画。
    ///    （`+` 那颗藏掉指示器是因为它是纯图标，藏了更干净；两者取舍不同，别照抄。）
    ///
    /// ☠️ 别把 `ChatModel.selectChoice` 改回「写平台槽 + 模型槽」：那两个概念已经不存在了，
    ///    而且「一次动作改两处」正是当初「胶囊写着 qwen3、请求还发给 DeepSeek」那个半改状态的来源。
    ///
    /// 🔴 hover 底与 `onHover` 挂在这层**外层容器**上，不靠 label 里那颗自带的
    /// （2026-10-22 与 `+` 同一次修、同一个根因）：`ComposerChipVisual` 的 `onHover` 对
    ///    `Button` 宿主好使（模型兜底块 `ComposerChipLabel` 正常），但 **`Menu` 宿主下不触发**
    ///    —— label 被菜单按钮的内部机制托管，hover 传不进去。而外层容器是「指针一进 bounds
    ///    就一定收到」的那一层（侧栏行 / 搜索结果行 / `plusMenu` 全是这个机制）⇒ 底块必须画在这里。
    /// ⚠️ 与之配套：菜单那层的 label 传 `drawsHoverBackground: false` —— 两层都画会是
    ///    同一块区域涂两遍（0.06 × 2），比 hover 正常的块深一档，一眼看出不像一个妈生的。
    ///
    /// 🔴🔴 **高度必须显式钉**（`.frame(height:)`，2026-10-22 用户报「模型按钮比其他按钮
    ///     矮这么多」实测抓到的第二个坑）：`borderlessButton` 的 `Menu` **会吞掉 label 的
    ///     `.frame(height:)`** —— label 里那颗 `ComposerChipVisual` 写着 `frame(height: 32)`，
    ///     实测 hover 底只有 **16pt**（Menu 按内容自然高布局，2x 截图量出 pill 32px）。
    ///     与 `plusMenu` 那条注释是同一个坑（「Menu 自带尺寸可能与 label 不完全一致」）——
    ///     `+` 靠外层 `.frame(32×32)` 兜底所以才没事；这颗当初漏了这层。
    ///     ⚠️ 只钉**高**不钉宽：宽随模型名长度变（`fixedSize` + 文字撑），钉死会把长名字截断。
    ///     ☠️ `.frame` 必须放在 `.background` **之前**——background 应用的是 frame 之后的
    ///        view；放反了底块只覆盖原来那 16pt，等于没修。
    private var modelMenu: some View {
        ZStack {
            modelMenuButton
        }
        .frame(height: MacTheme.composerChipHeight)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.composerChipRadius)
                .fill(modelMenuHovered ? MacTheme.composerChipHoverBackground(colorScheme) : .clear)
        )
        .onHover { modelMenuHovered = $0 }
    }

    /// `modelMenu` 里那颗系统菜单本体（抽出来只为可读：外层容器管 hover，这一层管弹菜单）。
    private var modelMenuButton: some View {
        Menu {
            Picker("", selection: modelSelection) {
                ForEach(model.modelChoices) { choice in
                    Text(Self.menuTitle(for: choice)).tag(choice.id)
                }
            }
            .pickerStyle(.inline)
        } label: {
            ComposerChipVisual(icon: Self.modelIcon,
                               title: model.currentModelLabel,
                               trailingChevron: false,
                               drawsHoverBackground: false)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(String(format: L("当前模型：%@（点这里换，列表里是「自定义模型」里配好的那些）"), model.currentChoiceLabel))
    }

    /// 选择器的绑定：读**条目 id**（`AIModelChoice.id` = `AICustomModel.id`）。
    ///
    /// 🔴 与列表项的 `tag(choice.id)` **同一个值** —— 这就是「打勾必然落到对的那一行」的保证。
    /// ⛔ 别拿块上那个**文案**当 selection：一条都没有时它会退回「未配置模型」，
    ///    拿文案当 tag 永远匹配不上，勾直接消失。
    private var modelSelection: Binding<String> {
        Binding(get: { model.currentChoiceKey }, set: { model.selectChoice($0) })
    }

    /// `+`：截图提问 / 上传文件或图片 / 项目资料。
    ///
    /// ⚠️ 用系统 `Menu` 而不是自绘弹层：菜单项里有「用户在系统里认得的行高与高亮」，
    /// 自绘那套还得自己处理点外面关闭、键盘上下选择。图标色由 `Label` 自己按菜单口径上色，
    /// 所以菜单本体（`plusMenuButton`）里**只管标签**。
    ///
    /// 🔴 hover 底与 `onHover` 挂在这层**外层容器**上，不靠 label 里那颗自带的
    /// （2026-10-22 用户报「鼠标移到 + 上没有背景变深的效果」）：`ComposerGlyphLabel`
    /// 的 `onHover` 对 `Button` 宿主好使（联网 / 🎤 都正常），但 **`Menu` 宿主下不触发**
    /// —— label 被菜单按钮的内部机制托管，hover 传不进去。而外层容器是「指针一进 bounds
    /// 就一定收到」的那一层（侧栏行 / 搜索结果行全是这个机制）⇒ 底块必须画在这里。
    /// ⚠️ 与之配套：菜单那层的 label 传 `drawsHoverBackground: false` —— 两层都画会是
    ///    同一块区域涂两遍（0.06 × 2），比旁边两颗深一档，一眼看出不像一个妈生的。
    private var plusMenu: some View {
        ZStack {
            plusMenuButton
        }
        // 显式给满命中区：borderlessButton 的 Menu 自带尺寸可能与 label 不完全一致
        .frame(width: MacTheme.composerIconHitSize, height: MacTheme.composerIconHitSize)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.composerChipRadius)
                .fill(plusHovered ? MacTheme.composerChipHoverBackground(colorScheme) : .clear)
        )
        .onHover { plusHovered = $0 }
    }

    /// `plusMenu` 里那颗系统菜单本体（抽出来只为可读：外层容器管 hover，这一层管弹菜单）。
    private var plusMenuButton: some View {
        Menu {
            Button {
                pick(.screenshot)
            } label: {
                Label(Self.screenshotTitle, systemImage: Self.screenshotIcon)
            }
            Button {
                pick(.files)
            } label: {
                Label(Self.uploadTitle, systemImage: Self.uploadIcon)
            }
            // 项目资料（2026-10-21）：2026-10-25 起所有会话必有项目（默认项目
            // 「任务」兜底，「未归类」已消灭）⇒ 这一项**恒显示**。
            // `if` 留着防 ensure 极端失败时的 nil（那种时候藏起来比进去报错好）。
            // ⚠️ iOS 侧同口径（那边第 4 格也恒显示）。
            if currentProject != nil {
                Divider()
                Button {
                    projectPickShown = true
                } label: {
                    Label(L("项目资料"), systemImage: "books.vertical")
                }
            }
        } label: {
            ComposerGlyphLabel(icon: "plus", drawsHoverBackground: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("添加内容：截图提问 / 上传文件或图片"))
    }

    /// 🎤 语音输入：**点一下开始，再点一下结束并发送**。
    ///
    /// 🔴 为什么不做成「按住说话」（iOS 那套）：Mac 上要用鼠标一直按着，长句会累、
    ///    中途腾不出手；而系统听写本身就是「连按两下 Fn 开始、再按一下结束」的切换语义。
    ///
    /// 录音中换 `mic.fill` + 红：图标换态是「点一下会**结束**」最直接的暗示，
    /// 再配上面板里那句「点击 🎤 结束并发送 · Esc 取消」，两条路都说清楚了。
    /// 面板在上方同步显示波形与实时文字 —— 所以这里不需要再放别的状态指示。
    /// 联网搜索开关（2026-10-21）。
    ///
    /// 开 / 关只靠 `activeTint` 那一层底色 + 图标染强调色（与录音中那颗 🎤 同一个机制）：
    /// 只把图标描深一点，在浅色主题下几乎看不出来 ⇒「它是活的」得靠一整块颜色说。
    /// ⛔ 别改成两颗图标（`globe` / `globe.fill`）—— 这一行里换图标是
    ///    「点一下会**结束**当前动作」的语义（🎤 那套），开关混进去会误读成录音态。
    private var webSearchButton: some View {
        Button {
            model.toggleWebSearch()
        } label: {
            ComposerGlyphLabel(icon: "globe",
                               activeTint: model.webSearchEnabled ? MacTheme.composerWebSearchOn : nil)
        }
        .buttonStyle(.plain)
        .help(model.webSearchEnabled
              ? L("联网搜索已开启：发送前先查网页（点一下关掉）")
              : L("联网搜索：发送前先查网页再回答（点一下开）"))
    }

    /// 项目资料检索开关（放大镜）**2026-10-23 已删**（用户拍板「默认关闭 + 删入口」）。
    ///
    /// 底层全保留：`AIGenerationSettings` 里那个偏好（默认关、已无 UI 写点）、
    /// `AIChatManager.beginProjectRetrieval`（唯一判据）、`ai_project_file_chunk` 表、
    /// 导入即建索引、项目详情页的索引状态行 + 重建钮。删的只是控制行这颗钮。
    /// 恢复入口照 `VERIFY-PROBES.md` §32.4 的清单加回来，⛔ 别凭记忆重写（那份连
    /// 「镜像 / 单点写 / 相邻判据 / 转圈并态」四条契约一起列了）。
    private var micButton: some View {
        Button {
            model.toggleVoice()
        } label: {
            ComposerGlyphLabel(icon: model.isVoiceRecording ? "mic.fill" : "mic",
                               activeTint: model.isVoiceRecording ? MacTheme.composerMicRecording : nil)
        }
        .buttonStyle(.plain)
        // 「正在整理文字…」那一拍不可点（文字已经在路上，再点没有语义）——
        // 置灰而不是静默忽略，否则用户会以为按钮坏了
        .disabled(model.isVoiceFinishing)
        .help(model.isVoiceRecording
              ? L("结束并发送（Esc 取消）")
              : (model.isVoiceFinishing ? L("正在整理文字…") : L("语音输入：点一下开始说话")))
    }

    /// 送信 / 停止 —— **同一个位置两颗语义**（旧版就是这个处理），外加第三态：
    /// **录音中它是「结束并发送」**。
    ///
    /// 为什么录音中也要接过来：那颗按钮在用户眼里就是「把我说的话送出去」。录音中若还按
    /// 「发草稿」处理，用户对着它点一下的期待（把我刚说的发出去）与实际行为（发草稿，
    /// 而草稿往往是空的 → 按钮还是灰的）正好相反 —— 那是陷阱，不是精简。
    /// 两条路（再点 🎤 / 点这里）落到同一个 `toggleVoice()`，怎么点都对。
    ///
    /// 为什么不并排摆两颗：那样会出现「想停止却点到发送」的误触（iOS 输入栏同款取舍）。
    /// 底色自己算（`sendFill`）：`.disabled` 只拦交互，管不到我们写死的填充色。
    private var sendButton: some View {
        Button {
            if model.isVoiceRecording {
                // 结束语音并发送（与再点一次 🎤 等价）。`toggleVoice` 自带
                // `isVoiceFinishing` 守卫，所以「正在整理文字」那一拍点它也不会重复收尾。
                model.toggleVoice()
            } else if model.isStreaming {
                model.stop()
            } else {
                model.send()
            }
        } label: {
            ZStack {
                Circle().fill(sendFill)
                Image(systemName: model.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: model.isStreaming
                                  ? MacTheme.composerSendStopIconSize
                                  : MacTheme.composerSendIconSize,
                                  weight: .semibold))
                    .foregroundStyle(MacTheme.composerSendGlyph)
            }
            .frame(width: MacTheme.composerSendSize, height: MacTheme.composerSendSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isStreaming && !canSend)
        .help(Self.sendHelp(isVoice: model.isVoiceRecording, isStreaming: model.isStreaming))
        // ⌘⏎ 走快捷键；⏎ 由文本区的 onSubmit 接（两条路都落到 `model.send()`）
        .keyboardShortcut(.return, modifiers: .command)
    }

    private static func sendHelp(isVoice: Bool, isStreaming: Bool) -> String {
        if isVoice { return L("结束语音并发送（也可以再点一次 🎤）") }
        return isStreaming ? L("停止生成") : L("发送（⏎ / ⌘⏎）")
    }

    private var sendFill: Color {
        if model.isStreaming { return MacTheme.composerSendEnabled }
        return canSend ? MacTheme.composerSendEnabled : MacTheme.composerSendDisabled
    }

    // MARK: - 附件条

    /// 选好的附件（截图 / 图片 / 文件）—— 卡在文本区**上面**。
    ///
    /// 放卡片内部而不是卡片外面：附件是「这条消息的一部分」，与正文属于同一个整体；
    /// 放到卡片外会读成另一个区块。
    private var attachmentStrip: some View {
        HStack(spacing: MacTheme.composerAttachmentSpacing) {
            ForEach(model.pendingAttachments) { item in
                ComposerAttachmentChip(item: item) {
                    model.removeAttachment(item.id)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 免责声明

    private var disclaimer: some View {
        Text(Self.disclaimerText)
            .font(MacTheme.ui(MacTheme.composerFooterFontSize))
            .foregroundStyle(MacTheme.composerFooter)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - 动作

    private enum AttachmentSource {
        case screenshot
        case files
    }

    private func pick(_ source: AttachmentSource) {
        switch source {
        case .files:
            // 文件选择器是 AppKit 的模态面板，**必须在主线程跑**（这里就是主线程）
            ComposerAttachmentPicker.apply(ComposerAttachmentPicker.chooseFiles(), to: model)
        case .screenshot:
            // 截图是交互式的、会等用户拉完选区 —— 用 Task 挂起，别卡住这一拍
            Task {
                ComposerAttachmentPicker.apply(await ComposerAttachmentPicker.captureScreenshot(),
                                               to: model)
            }
        }
    }

    /// 草稿的双向绑定。
    /// - Note: `ChatModel` 是 `@Observable`，理论上可以用 `@Bindable`；这里手写
    ///   `Binding` 是为了把「环境里的模型」与「子视图的可写绑定」之间的关系写得足够显式
    ///   （`@Bindable var x = x` 那种局部写法的可读性在 review 时更差）。
    private var draft: Binding<String> {
        Binding(get: { model.draft }, set: { model.draft = $0 })
    }

    /// 下拉列表里那一行的文案。
    ///
    /// **平台在前、模型在后**（`<平台> · <模型>`）；内置条目带的那句能力说明**跟在破折号后面** ——
    /// 系统菜单不给副标题（iOS 那版是 cell 的 `secondaryText`），而这句话恰恰是
    /// 「想发图片却被拦下」时最该看到的线索（`AIProviderError.visionModelHint` 指的就是它）。
    ///
    /// ⚠️ 用破折号而不是括号：说明本身带括号（如「支持图片（实验）」），
    ///    再套一层就成了 `（…（…））`。
    /// ⚠️ **不在文案里写「当前使用」**：当前项由 `Picker` 打勾，写进文案等于两处口径。
    /// ⚠️ 第一段是 **`<条目名>`**（列表是「已配置的模型」，见 `modelMenu`），后面跟破折号 + 供应商名：
    ///    用户可能同时配了好几条（同一家的两个模型、或者两个中转站），不写供应商就分不清点的是哪个。
    /// 🔴 第一段（head）的口径**收在共享层**：`AIModelChoice.title`，iOS 那版列表读的是同一个属性
    ///    —— 两平台各拼一遍迟早分家（表现是「同一条在 mac 叫 A、在 iOS 叫 B」）。
    ///    这里只保留本端特有的那半：note 跟在破折号后面（系统菜单不给副标题）。
    /// ⚠️ 缺东少西的条目（地址 / 模型名 / Key 有一个没填）要标一句「还没配齐」——
    ///    系统菜单只给一行文案，不标的话用户点了会发现发不出去、而列表上完全看不出来。
    private static func menuTitle(for choice: AIModelCatalog.AIModelChoice) -> String {
        let note = choice.isReady ? choice.note : String(format: L("%@ · 还没配齐"), choice.note)
        guard !note.isEmpty else { return choice.title }
        return "\(choice.title) — \(note)"
    }

    // MARK: - 文案
    //
    // 图标名与文案集中在文件尾：它们是一组，散在布局里 review 时看不全。
    //
    // 🔴 下面这几条**文案**一律写成**计算属性**（2026-10-13 接本地化时踩到）：
    //    `static let` 会在第一次读到就把 `L()` 的结果**进程级缓存**住 ⇒ 切语言之后
    //    永远是旧语言那份，**连视图整棵重建都救不回来**（它不在视图里，在类型上）。
    //    ⚠️ 纯图标名（`screenshotIcon` 那种）没有这个问题，继续用 `static let`。
    //    同款坑全仓还有十来处，见 `.workbuddy/memory/I18N.md`。

    /// ⚠️ **刻意没照抄参考图的完整占位文案**（`今天帮你做些什么？ @ 添加上下文，/调用技能与指令`）：
    /// 这个 App 既没有 `@` 引用上下文、也没有 `/` 调技能 —— 写了就是在承诺做不到的事。
    /// 等真接了那两条再补上去（先把这句换成完整的）。
    private static var placeholder: String { L("今天帮你做些什么？") }
    private static var disclaimerText: String { L("内容由 AI 生成，请核实重要信息") }

    private static var screenshotTitle: String { L("截图提问") }
    private static let screenshotIcon = "camera.viewfinder"
    private static var uploadTitle: String { L("上传文件或图片") }
    private static let uploadIcon = "photo.on.rectangle"

    // ⛔ 原先这里还有 `workspaceIcon / workspaceTitle / workspaceHint` 与
    //    `permissionIcon / permissionTitle / permissionHint` 六个常量（「工作区 main」与
    //    「默认权限」两颗占位块的文案）—— **2026-09-29 随那两颗块一起删除**（用户要求）。
    //    要恢复的话别只把常量加回来：先回答「它属于输入框还是设置页」（见文件头那张表）。
    private static let modelIcon = "cpu"
    /// 列表为空时的悬停说明。
    /// ⚠️ 2026-10-14 起这条**真会走到**（清单是用户自己攒的，可以全删光），
    ///    所以它必须给出「去哪儿加一条」，而不是一句「没有可选模型」。
    private static var modelUnavailableHelp: String { L("当前没有可选模型") }
    /// 真出现空列表时点一下给出的说法 —— 出路是「去清单页加一条」
    private static var modelListEmptyHint: String { L("还没有配置模型：去「设置 → 模型」加一条") }
}

// MARK: - 控制行上的小控件

/// 控制行上的**图标**（`+` / 🎤）：常态透明、hover 浮一层底。
///
/// 单独抽出来是因为两个用法一模一样，而且 hover 需要自己的 `@State`
/// （父视图不该为了子视图的指针态多存两份状态）。
private struct ComposerGlyphLabel: View {
    let icon: String
    /// 强调态：录音中那颗 🎤 用（图标换色 + **常驻**一层同色底）。
    ///
    /// 常驻底是必须的：只把图标染红的话，在深色主题下与默认的浅灰图标区分度不够，
    /// 「它现在是活的」这件事得靠一整块颜色说。`nil` = 常态（透明底，只 hover 时浮底）。
    var activeTint: Color? = nil

    /// 这颗**自己画不画 hover 底**。默认 `true`（`Button` 宿主：联网 / 🎤 两颗）。
    ///
    /// 🔴 `Menu` 宿主（目前只有 `+`）传 `false`：那个宿主的 hover 由外层容器画
    /// （`plusMenu`），而 label 自带的 `onHover` 在 Menu 里**不触发** —— 两层都画
    /// 不会是「双保险」，而是同一块区域涂两遍（0.06 叠 0.06），比别的按钮深一档。
    var drawsHoverBackground: Bool = true

    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image(systemName: icon)
            .font(MacTheme.ui(MacTheme.composerIconSize, weight: .regular))
            .foregroundStyle(activeTint ?? MacTheme.composerChipText)
            // 🔴 命中区比图标大一圈（图标只有十几像素，不加这一层点不中）——
            //    与账号栏那颗齿轮同一个坑。
            .frame(width: MacTheme.composerIconHitSize, height: MacTheme.composerIconHitSize)
            .background(
                RoundedRectangle(cornerRadius: MacTheme.composerChipRadius)
                    .fill(background)
            )
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }

    private var background: Color {
        if let activeTint { return activeTint.opacity(0.16) }
        guard drawsHoverBackground else { return .clear }
        return hovered ? MacTheme.composerChipHoverBackground(scheme) : .clear
    }
}

/// 控制行上那颗块的**外观**：图标 + 文字 +（可选）向下的箭头，常态无底色、hover 浮一层底。
///
/// 单独抽出来是因为它有**两个宿主**：① `ComposerChipLabel`（一颗 `Button`，点了飘提示）；
/// ② 模型选择器（`Menu` 的 label）。两处必须长得**一模一样** —— 各抄一份迟早会漂成
/// 「菜单那颗的 hover 底淡一点」这种说不清、也 review 不出来的差别。
///
/// 常态**没有底色** —— 参考图里它们就是白底上的一行字。加了底色会读成一排胶囊按钮，
/// 与「这是当前状态、点进去能改」的观感正好相反。
///
/// 🔴 宿主② 的 hover **不靠这颗自带的 `onHover`**（2026-10-22 与 `ComposerGlyphLabel`
///    同一个根因）：`Menu` 托管下 label 的 hover 传不进去，由 `modelMenu` 外层容器画，
///    所以那边传 `drawsHoverBackground: false`。宿主① 是 `Button`，`onHover` 正常，默认 `true`。
private struct ComposerChipVisual: View {
    let icon: String
    let title: String
    var trailingChevron: Bool = false

    /// 这颗**自己画不画 hover 底**。默认 `true`（`Button` 宿主：模型兜底块）。
    ///
    /// 🔴 `Menu` 宿主（模型选择器 `modelMenu`）传 `false`：那个宿主的 hover 由外层容器画
    /// （`modelMenu`），而 label 自带的 `onHover` 在 Menu 里**不触发** —— 两层都画
    /// 不会是「双保险」，而是同一块区域涂两遍（0.06 叠 0.06），比别的块深一档。
    var drawsHoverBackground: Bool = true

    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: MacTheme.composerChipGap) {
            // 图标列宽固定：同一行里几个块的图标才会落在同一条竖线上
            // （图标各自宽度不同，靠 HStack 自然排会参差不齐）
            Image(systemName: icon)
                .font(.system(size: MacTheme.composerChipIconSize))
                .foregroundStyle(MacTheme.composerChipIcon)
                .frame(width: MacTheme.composerChipIconWidth)
            Text(title)
                .font(MacTheme.ui(MacTheme.composerChipFontSize))
                .foregroundStyle(MacTheme.composerChipText)
                .lineLimit(1)
            if trailingChevron {
                Image(systemName: "chevron.down")
                    .font(MacTheme.ui(MacTheme.composerChipFontSize - 4, weight: .semibold))
                    .foregroundStyle(MacTheme.composerChipIcon)
            }
        }
        .padding(.horizontal, MacTheme.composerChipPaddingH)
        .frame(height: MacTheme.composerChipHeight)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.composerChipRadius)
                .fill(background)
        )
        // 🔴 命中区要比内容大一圈（图标只有十几像素，不垫这层点不中）——
        //    与账号栏那颗齿轮同一个坑。放这里而不是宿主：两个宿主的点击判定都靠它。
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private var background: Color {
        guard drawsHoverBackground else { return .clear }
        return hovered ? MacTheme.composerChipHoverBackground(scheme) : .clear
    }
}

/// 控制行上的**文字块**（只剩「没有可选模型时的模型块」这一个宿主）：外观 + 一个点击动作。
///
/// ⚠️ 它原先有三个宿主（工作区 / 权限 / 模型兜底），2026-09-29 删掉前两个 ⇒ **现在只有一个调用点**
/// （`modelChip` 的 else 分支），而且那条分支几乎不可达（跨平台列表恒非空）。
/// 之所以**不顺手删掉这个类型**：它是「控制行上一颗点了给说法的文字块」的唯一现成实现 ——
/// 真出现空列表时宁可给一句「去哪配」，也不要弹一个空菜单。留着的是能力，不是一个入口。
private struct ComposerChipLabel: View {
    let icon: String
    let title: String
    var trailingChevron: Bool = false
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ComposerChipVisual(icon: icon, title: title, trailingChevron: trailingChevron)
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }
}

/// 待发送附件的小卡：缩略图（图片）/ 图标（文件）+ 名字 + 大小 + 移除。
private struct ComposerAttachmentChip: View {
    let item: AIAttachment
    let onRemove: () -> Void

    @State private var hovered = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            thumbnail
            Text(item.displayName)
                .font(MacTheme.ui(MacTheme.composerAttachmentFontSize))
                .foregroundStyle(MacTheme.bodyColor)
                .lineLimit(1)
                // 名称可以被挤，大小不行（大小是「这张图多大」的唯一线索）
                .layoutPriority(1)
            Text(item.sizeText)
                .font(MacTheme.ui(MacTheme.composerAttachmentFontSize))
                .foregroundStyle(MacTheme.meta)
                .fixedSize()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(MacTheme.ui(MacTheme.composerAttachmentFontSize))
                    // 指针停在这张小卡上时才把 × 提亮：它平时很淡，不熟的人看不出能点；
                    // 但一直画实又会跟名字抢注意力。hover 是这两者之间唯一的折中。
                    .foregroundStyle(hovered ? MacTheme.bodyColor : MacTheme.meta)
            }
            .buttonStyle(.plain)
            .help(L("移除这个附件"))
        }
        .padding(.horizontal, MacTheme.composerAttachmentPaddingH)
        .frame(height: MacTheme.composerAttachmentHeight)
        .frame(maxWidth: MacTheme.composerAttachmentMaxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.composerAttachmentRadius)
                .fill(MacTheme.composerAttachmentBackground(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacTheme.composerAttachmentRadius)
                .stroke(MacTheme.composerAttachmentBorder, lineWidth: 1)
        )
        .onHover { hovered = $0 }
        .help(item.displayName)
    }

    /// 图片走降采样缩略图（**不要** `NSImage(contentsOfFile:)`，那会把整张图解成位图 ——
    /// 一张 1600px 的图就是 7MB 内存，而这里只用得到 18pt）。非图片给一个文档图标。
    ///
    /// ⚠️ 同步取（`init` 期）而不是 `.task`：`ImageRenderer` 里 `.task` 根本不会跑，
    /// 那样离屏验收就永远看到的是兜底图标。代价是每次重建视图要读一次盘 ——
    /// 用一层 `NSCache` 挡掉（与业务层 `AIAttachmentStorage.dataURLCache` 同一个手法）。
    @ViewBuilder
    private var thumbnail: some View {
        if item.isImage, let image = ComposerThumbnailCache.thumbnail(for: item.fileURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: MacTheme.composerAttachmentThumbSize,
                       height: MacTheme.composerAttachmentThumbSize)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: item.isImage ? "photo" : "doc.fill")
                .font(MacTheme.ui(MacTheme.composerAttachmentFontSize))
                .foregroundStyle(MacTheme.composerChipIcon)
                .frame(width: MacTheme.composerAttachmentThumbSize,
                       height: MacTheme.composerAttachmentThumbSize)
        }
    }
}

/// 附件缩略图的缓存。
///
/// 用 `NSCache` 而不是字典：一个条目是一张位图，几条就是几 MB ——
/// 数量上限 + 内存压力时由系统回收，比自己记账合适（业务层同一个理由）。
/// 键取**路径**：附件落盘后不会被改写（UUID 命名），所以「路径 → 缩略图」是纯函数。
private enum ComposerThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        return cache
    }()

    static func thumbnail(for url: URL) -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = AIAttachmentStorage.image(at: url, maxPixelSize: 48) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// 收流中的小转圈：一个 3/4 环原地匀速转。
///
/// 只在 `model.isStreaming` 时出现（参考图里它在送信按钮左边）。
/// ⚠️ 用 `.onAppear` 起动画：它没有终点（`repeatForever`），所以**不能**挂在
/// 「值变化」上 —— 那样每次收流都要重新起一次、且旧动画不会停。
private struct ComposerSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(MacTheme.composerSpinnerColor,
                    style: StrokeStyle(lineWidth: MacTheme.composerSpinnerLineWidth, lineCap: .round))
            .frame(width: MacTheme.composerSpinnerSize, height: MacTheme.composerSpinnerSize)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: MacTheme.composerSpinnerPeriod).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
    }
}
