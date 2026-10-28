//
//  MacMemorySettingsView.swift
//  AsterMac
//
//  设置窗「长期记忆」分页（2026-10-25 新建，与 iOS 的 `AIMemorySettingsViewController` 同批）
//  —— 被 `MacSettingsView.content` 的 `case .memory` 引用，本身是设置窗右栏的一页。
//
//  ## 🔴 为什么它是独立文件、不并进 `MacSettingsView.swift`
//  本页的清单卡用了**条件式 `ScrollView`**（条数超过 `maxVisibleRows` 才包，见 `listBody`），
//  而 `render_mac_ui.sh` 里有一条硬契约：**`MacSettingsView.swift` 里不许出现 `ScrollView`**
//  （离屏渲染画不出滚动内容，那一档图会整片空白，不是「看着不对」）。
//  `MacCustomModelListView` 那条一模一样的条件 ScrollView 能活，正因为它在自己文件里
//  ⇒ 本页照抄那条路。⛔ 别为了「设置页都在一个文件里」把它搬回去。
//
//  ## 页面形态（与 iOS 页**刻意不同形**）
//  iOS 是「分组表 + 点进子页」，本页是「设置窗右栏的一页」：一张**控制卡**
//  （两个开关 + 条件行「清除全部记忆」）+ 一张**清单卡**（逐条删；空 = 一行引导，
//  不画卡）+ 一行尾注（文件位置 / 读盘失败）。
//  两边共用同一个存取点（`AIMemoryStore`，口径在它文件头）——⛔ 别为了「统一」
//  把任一边改成另一边。
//
//  ## 三个开关各管一件事（2026-10-25 反转后）
//  ①「自动记忆」（`isAutoExtractEnabled`，默认**关**）：每轮对话后模型自动提取；
//  ②「回答时参考」（`isEnabled`，默认开）：拼不拼进 system 消息；
//  ③ 清除全部（条件行）。**没有任何「添加记忆」入口** —— 上线当天的手动写点
//  ：「记住这条」+「添加记忆」当天即被用户拍板移除（与豆包对齐成纯自动）。
//
//  ## 三条别踩的（详细成因在 `MacMemorySettingsView` 类型头）
//  ① 非 `@Observable` 存取点 ⇒ `@State` 镜像 + 订 `didChangeNotification`；
//  ② 进页面强制重读（用户可能刚在「访达」里手改过 `memories.json`）；
//  ③ 删除必须二次确认（`pendingDelete` / `confirmsClearAll` 两个 alert）。
//

import SwiftUI
import AICore

// MARK: - 右侧：长期记忆（2026-10-25 新建，与 iOS 的 AIMemorySettingsViewController 同批）

/// 「长期记忆」页 —— 一张**控制卡**（两个开关 + 条件行清除全部）+ 一张**清单卡**（逐条删）。
///
/// ## 与 iOS 页的分工
/// 两边共用同一个存取点（`AIMemoryStore`，形态与口径都在它文件头），**页面形态各按平台**：
/// iOS 是「分组表 + 点进子页」，本页是「设置窗右栏的一页」。⛔ 别为了「统一」
/// 把任一边改成另一边。
///
/// ## 🔴 三条别踩的
/// 1. **非 `@Observable` 存取点 ⇒ 镜像 + 广播**（文件头 ② 那条铁律）：`items` /
///    `isAutoExtract` / `isEnabled` 三份 `@State` 镜像，写的时候**几处都写**；外加订
///    `AIMemoryStore.didChangeNotification` —— 不订的话「抽取器刚写进一条」在设置页
///    看不见（`onAppear` 只在首次进页跑）。
/// 2. **进页面强制重读**（`reload()`）：用户可能刚在「访达」里手改过 `memories.json`。
/// 3. **删除必须二次确认**（`pendingDelete` / `confirmsClearAll` 两个 alert）——
///    与 `MacCustomModelListView.pendingDelete` 同一条纪律：删不可恢复。
///
/// ⚠️ **internal（无修饰符）而不是 `private`**：它被 `MacSettingsView.content` 的
///    `case .memory` 引用，而那个文件在**另一个文件**里 —— 设置窗里其余几页是
///    `private struct`，因为它们与 `MacSettingsView` 同在 `MacSettingsView.swift`。
///    本页拆出去之后（见文件头），访问级别必须跟着放开。⛔ 别改回 `private`。
///    `MacMemoryRow` 只在本文件内使用，仍是 `private`。
struct MacMemorySettingsView: View {

    // MARK: 镜像（见类型头第 1 条）

    /// 清单（新的在前 —— 存取点自己的排序，⛔ 别在这儿再排一次）。
    @State private var items: [AIMemoryItem] = AIMemoryStore.all()
    /// 「自动记忆」（抽取侧，默认关）。⚠️ 只管**记不记**，不管注入。
    @State private var isAutoExtract: Bool = AIMemoryStore.isAutoExtractEnabled
    /// 「回答时参考」（注入侧，默认开）。⚠️ 只管**拼不拼进请求**，不管记不记。
    @State private var isEnabled: Bool = AIMemoryStore.isEnabled

    /// 待确认删除的那一条（非 nil = 弹确认框）。
    @State private var pendingDelete: AIMemoryItem?
    /// 「清除全部」确认中。
    @State private var confirmsClearAll = false

    var body: some View {
        MacSettingsPageScaffold {
            // ⚠️ 内层再套一层 `VStack(spacing: 12)`：骨架那个 VStack 是 `spacing: 0`，
            //    多张卡直接扔进去会**贴在一起**（2026-10-25 最小复现实测：两卡合成
            //    一整块灰色、中间零白行）——「生成参数」页（`MacGenerationSettingsView`）
            //    就是直接扔的，它那两卡现在**贴着**（潜在版面问题，不在本页范围内动它）。
            //    12 = 与 `MacCustomModelListView` 页头到分隔线那个间距同一档。
            VStack(alignment: .leading, spacing: 12) {
                controlsCard
                listCard
                footerLine
            }
        }
        // 进页面强制重读（访达里手改过 ⇒ 现读，见类型头第 2 条）。
        .onAppear(perform: reload)
        // 抽取器刚写进一条 / 在另一处设置页删了 / 手改文件被重读出来 ⇒ 镜像跟着刷。
        .onReceive(NotificationCenter.default.publisher(for: AIMemoryStore.didChangeNotification)) { _ in
            reload()
        }
        .alert(item: $pendingDelete) { item in
            Alert(title: Text(L("删除这条记忆？")),
                  message: Text(item.content),
                  primaryButton: .destructive(Text(L("删除"))) {
                      AIMemoryStore.delete(id: item.id)
                  },
                  secondaryButton: .cancel(Text(L("取消"))))
        }
        .alert(L("清除全部记忆？"), isPresented: $confirmsClearAll) {
            Button(L("清除"), role: .destructive) { AIMemoryStore.clearAll() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(L("此操作不可恢复。"))
        }
    }

    // MARK: 卡一：控制（两个开关 + 条件行「清除全部」）

    private var controlsCard: some View {
        MacSettingsCard(title: L("长期记忆"),
                        subtitle: L("记住你希望助手跨会话记得的事，回答时会参考。")) {
            VStack(alignment: .leading, spacing: 0) {
                MacSettingsToggleRow(
                    title: L("自动记忆"),
                    // 副标题跟着开关状态走（两条文案与 iOS 页**同一份词条**，⛔ 别另写）
                    detail: isAutoExtract
                        ? L("每轮对话后自动提取值得记住的信息")
                        : L("开启后每轮对话会多一次模型调用"),
                    isOn: Binding(
                        get: { isAutoExtract },
                        // 🔴 双写：镜像 + 存取点（只写一个都是「界面不动」或「开关没落盘」）。
                        set: { isAutoExtract = $0; AIMemoryStore.isAutoExtractEnabled = $0 }))
                Divider().padding(.horizontal, 10)
                MacSettingsToggleRow(
                    title: L("回答时参考"),
                    // 副标题跟着开关状态走（两条文案与 iOS 页**同一份词条**，⛔ 别另写）
                    detail: isEnabled
                        ? L("开启后，助手会在回答时参考这些记忆")
                        : L("关闭后不再参考；已保存的记忆仍会保留。"),
                    isOn: Binding(
                        get: { isEnabled },
                        // 🔴 双写：镜像 + 存取点（只写一个都是「界面不动」或「开关没落盘」）。
                        set: { isEnabled = $0; AIMemoryStore.isEnabled = $0 }))
                // 「清除全部」是**条件行**（有记忆才出现）—— 由 body 现算，⛔ 别写成静态版面。
                if !items.isEmpty {
                    Divider().padding(.horizontal, 10)
                    clearAllRow
                }
            }
        }
    }

    /// 「清除全部记忆」一行（红字；二次确认后 `clearAll()`）。
    private var clearAllRow: some View {
        Button { confirmsClearAll = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(MacTheme.ui(13))
                    .foregroundStyle(MacTheme.actionIconDestructive)
                Text(L("清除全部记忆"))
                    .font(MacTheme.ui(13))
                    .foregroundStyle(MacTheme.actionIconDestructive)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, MacTheme.settingsChoiceRowPaddingV)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 卡二：清单（空 = 一行引导，不画卡）

    @ViewBuilder
    private var listCard: some View {
        if items.isEmpty {
            // 空态：**不画卡**，照 `MacCustomModelListView` 的空态（两行居中的小字）——
            // 空列表套一张卡只会得到一张大半张空白的卡。
            VStack(spacing: 6) {
                Text(L("还没有记忆。开启上面的「自动记忆」，助手会在每轮对话中记住你的事，可在这里查看和删除。"))
                    .font(MacTheme.ui(13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            MacSettingsCard(title: String(format: L("%d 条记忆"), items.count),
                            subtitle: L("新的在前；点行尾图标删除。")) {
                listBody
            }
        }
    }

    /// 清单本体。
    ///
    /// ⚠️ 与 `MacCustomModelListView.listBody` **同一条纪律**：默认**不用 `ScrollView`**
    ///    （离屏渲染画不出滚动内容，那一档图会整片空白）—— 只有条数超过
    ///    `maxVisibleRows` 才包一层，且封顶高度按估算行高算（估偏了只是多看一眼少看一眼，
    ///    不参与任何布局）。
    @ViewBuilder
    private var listBody: some View {
        if items.count > Self.maxVisibleRows {
            ScrollView {
                rows
            }
            .frame(maxHeight: CGFloat(Self.maxVisibleRows) * Self.estimatedRowHeight, alignment: .top)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 下标只为画分隔线（最后一条之后不画）；`ForEach` 的 id 仍是 `item.id`
            // （⛔ 别改成 `\.offset` —— 删一条之后下标重排，行内状态会跟着走错行）。
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                MacMemoryRow(item: item, onDelete: { pendingDelete = item })
                if index < items.count - 1 {
                    Divider().padding(.horizontal, 10)
                }
            }
        }
    }

    // MARK: 尾注

    /// 文件位置；盘上手改坏了 JSON 时换成错误提示
    /// （⛔ 别静默显示空列表 —— 那会诱导用户以为记忆全丢了，见 `AIMemoryStore.lastLoadError`）。
    @ViewBuilder
    private var footerLine: some View {
        if let error = AIMemoryStore.lastLoadError {
            Text(String(format: L("记忆文件读取失败：%@。显示的是上次的内容，请检查文件格式。"), error))
                .font(MacTheme.ui(11))
                .foregroundStyle(MacTheme.errorText)
                .fixedSize(horizontal: false, vertical: true)
        } else {

        }
    }

    // MARK: 动作

    /// 强制重读 + 刷三份镜像（存取点内部有 mtime 闩，没变就是一次 stat）。
    private func reload() {
        AIMemoryStore.reload()
        items = AIMemoryStore.all()
        isAutoExtract = AIMemoryStore.isAutoExtractEnabled
        isEnabled = AIMemoryStore.isEnabled
    }

    /// 超过这个条数才包 `ScrollView`（见 `listBody` 注释）。
    private static let maxVisibleRows = 6

    /// 估算行高（正文一行 ≈15pt + 时间一行 ≈13pt + 上下内边距 16pt ≈ 60pt；
    /// 长正文换行后会更高）。**只用来算滚动区封顶高度**，⛔ 别拿它钉行高。
    private static let estimatedRowHeight: CGFloat = 60
}

// MARK: - 清单里的一行

/// 一行记忆：正文（**可换行、⛔ 不截断** —— 记忆可能很长）+ 创建时间 + 行尾删除。
private struct MacMemoryRow: View {

    let item: AIMemoryItem
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.content)
                    .font(MacTheme.ui(12))
                    .foregroundStyle(MacTheme.bodyColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Self.timeFormatter.string(from: item.createdAt))
                    .font(MacTheme.ui(11))
                    .foregroundStyle(MacTheme.meta)
            }
            Spacer(minLength: 8)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(MacTheme.ui(12))
                    .foregroundStyle(MacTheme.actionIconDestructive)
                    // 🔴 命中区撑满写在 label **内部**（铁律，与 `MacCustomModelRowView.actionButton`
                    //    同一条）：写在按钮外面的 padding 对命中区无效。
                    .frame(width: Self.actionSize, height: Self.actionSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // ⚠️ 复用模型清单页那条 tooltip（`删除这一条`），⛔ 别为记忆另写一条。
            .help(L("删除这一条"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private static let actionSize: CGFloat = 26

    /// 时间行的格式（`MM-dd HH:mm`）。
    /// 🔴 **static let** 是安全的：`DateFormatter` 创建代价高，而它**不含任何随语言变的
    ///    文案**（月份数字是区域格式，跟着 locale 走，不跟 `L()`）—— 与 iOS 记忆页那个
    ///    `timeFormatter` 同一条理由（`static let` 锁语言那条教训在这儿不适用）。
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
