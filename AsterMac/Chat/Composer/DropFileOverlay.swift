//
//  DropFileOverlay.swift
//  AsterMac
//
//  从访达往会话页拖文件时，盖在**整页**（消息列表 + 输入栏）上的那一层落区。
//
//  ```
//  ┌──────────────────────────────────────────────────────────┐
//  │  ╭ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─╮  │ ← 虚线框（整页）
//  │  ┆                                                  ┆  │
//  │  ┆                    ⬇ doc                         ┆  │ ← 大图标
//  │  ┆            松开即可添加到输入框                    ┆  │ ← 主标题
//  │  ┆        [图片]  PNG · JPEG · HEIC · GIF · WebP     ┆  │ ┐
//  │  ┆        [文本]  TXT · MD · JSON · CSV · 代码…       ┆  │ ├ 支持哪些格式
//  │  ┆        [其它]  任意文件（原样存进沙盒）             ┆  │ ┘
//  │  ┆              一条消息最多 6 个附件                 ┆  │ ← 上限（取自业务层）
//  │  ╰ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─╯  │
//  └──────────────────────────────────────────────────────────┘
//  ```
//
//  ## 🔴 三个必须记住的约束
//  ① **`allowsHitTesting(false)` 不能省**（挂在 `ChatDetailView` 那边）。
//     这一层是**在拖拽进行中**才冒出来的 —— 它一旦参与命中测试，就会挡住
//     `onDrop` 的落点判定，「松手」那一刻的目标视图已经不是原来那个了。
//     而它表面上是个「盖住整页的东西」，写代码时最容易顺手让它可交互。
//  ② **遮罩不能盖满**（`dropScrimOpacity = 0.82`，见 MacTheme 里那条注释）：
//     底下那层消息要隐约还在 —— 用户拖着一个文件悬在窗口上时，还得看得清
//     「我要放到哪个会话里」。全遮等于把上下文擦掉。
//  ③ **尺寸与颜色全部走 `MacTheme`**（与全 App 一致），且**必须是语义色**：
//     这一层盖的是页面底（`MacTheme.pageBackground`：浅色 `#FFFFFF` / 深色 `#323232`）——
//     写死成深色的话，浅色模式下整页会被一块黑糊住（渲染图上一眼可见）。
//
//  ## 为什么「支持哪些格式」要写出来
//  这块牌子唯一要回答的问题是「**我能不能把手上这个文件放进来**」。
//  用户从访达拖东西时心里是有疑问的（尤其是非图片的文件），而 App 平时**从不解释**
//  这件事（附件面板只有图标）。所以这一层要把口径一次说清，包括最后那句
//  「任意文件」——那是真的：落地上不做任何类型过滤（见 `ComposerAttachmentPicker` 文件头）。
//
//  ⚠️ 格式清单的**真值来源**是业务层，不是这里：
//    - 图片：`AIAttachmentStorage.mimeType(for:)` 认的几种（png / gif / webp / heic / jpeg）；
//    - 文本：`AIAttachmentStorage.isTextLike(_:)` 的白名单（32 种，此处只列代表），
//      外加 `pdf`（2026-10-23 起走 PDFKit 抽正文，见 `AIAttachmentStorage.extractedText`）；
//    - 其余：`importFile` 原样拷进沙盒，**不解析内容** —— 所以是「任意文件」。
//    这里写的是**给人看的摘要**，不是判据。别把这份清单当成「放行名单」去改：
//    真要收窄类型，得改业务层那两个函数，而不是改这几行文案。
//

import SwiftUI
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

struct DropFileOverlay: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // ① 遮罩。⚠️ 用**页面底色**加透明度，而不是 `Color.black`：
            //    浅色模式下黑遮罩会把整页压成灰色（看起来像窗口失焦了），
            //    而页面底色本身就是「同一张面变淡」，明暗两档都自然。
            MacTheme.pageBackground
                .opacity(MacTheme.dropScrimOpacity)

            // ② 虚线落区 —— 那圈边距就是「整页都是落区」的可视承诺，
            //    所以它跟着页面尺寸走，不是一块居中固定大小的卡片。
            panel
                .padding(MacTheme.dropPanelMargin)
        }
    }

    private var panel: some View {
        VStack(spacing: MacTheme.dropPanelSpacing) {
            Image(systemName: Self.icon)
                .font(MacTheme.ui(MacTheme.dropIconSize, weight: .light))
                .foregroundStyle(MacTheme.dropIconTint)

            Text(Self.title)
                .font(MacTheme.ui(MacTheme.dropTitleFontSize, weight: .medium))
                .foregroundStyle(MacTheme.dropTitle)

            formatList

            // 上限那句放在最后、用最弱的色：它是「补充说明」，不是「能不能放进来」的答案。
            // 数字取自业务层 —— 文案里写死 6 的话，改上限时这里会静默说谎。
            Text(String(format: L("一条消息最多 %d 个附件"), ChatModel.maxPendingAttachments))
                .font(MacTheme.ui(MacTheme.dropSubtitleFontSize))
                .foregroundStyle(MacTheme.dropSubtitle)
        }
        .multilineTextAlignment(.center)
        // 内容撑不满时居中，撑满时（窄窗口）能正常换行 —— 两边都不要被裁掉。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: MacTheme.dropPanelRadius)
                .fill(MacTheme.dropPanelFill(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MacTheme.dropPanelRadius)
                .strokeBorder(MacTheme.dropPanelBorder,
                              style: StrokeStyle(lineWidth: MacTheme.dropPanelBorderWidth,
                                                 dash: MacTheme.dropPanelDash))
        )
    }

    /// 三行「类别 + 代表后缀」。
    ///
    /// ⚠️ 一行一类、**不并排成三个胶囊**：并排那种写法在窄窗口下必然挤爆
    ///    （每行都是一串后缀，合起来近 500pt），而这一层最需要「窄窗口下也看得全」——
    ///    它的全部价值就是那句话说得清不清楚。
    /// ⚠️ 后缀那一列**不设 `lineLimit(1)`**：宁可折成两行，也不要被截成
    ///    「PNG · JPEG · HE…」（那正好把「支不支持 HEIC」这个最需要回答的问题截掉了）。
    private var formatList: some View {
        VStack(alignment: .leading, spacing: MacTheme.dropChipSpacing) {
            ForEach(Self.formats) { item in
                HStack(alignment: .firstTextBaseline, spacing: MacTheme.dropChipSpacing) {
                    Text(item.category)
                        .font(MacTheme.ui(MacTheme.dropChipFontSize, weight: .medium))
                        .foregroundStyle(MacTheme.dropChipText)
                        .padding(.horizontal, MacTheme.dropChipPaddingH)
                        .padding(.vertical, MacTheme.dropChipPaddingV)
                        .background(
                            RoundedRectangle(cornerRadius: MacTheme.dropChipRadius)
                                .fill(MacTheme.dropChipBackground(scheme))
                        )
                        // 三颗标签**等宽**：不然「图片 / 文本 / 其它」字数不同，
                        // 右边那列后缀就会参差不齐（与 `ComposerChipVisual` 里
                        // 「图标列宽固定」同一个坑）。
                        .frame(width: MacTheme.dropChipWidth)
                    Text(item.extensions)
                        .font(MacTheme.ui(MacTheme.dropChipFontSize))
                        .foregroundStyle(MacTheme.dropSubtitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // 整块居中：它是「牌子」的一部分，不该像表格那样贴着左边。
        .frame(maxWidth: MacTheme.dropFormatListMaxWidth, alignment: .leading)
    }

    // MARK: - 文案
    //
    // 与 `MacInputBar` 同一个做法：图标名与文案集中在文件尾，散在布局里 review 时看不全。

    /// `arrow.down.doc` 而不是 `square.and.arrow.down`：
    /// 后者是「下载」的通用符号（在浏览器里就长这样），而这个 App 里没有下载这件事；
    /// `arrow.down.doc` 的「一张纸落下来」正好对上「拖文件进来」。
    private static let icon = "arrow.down.doc"
    /// 🔴 计算属性（2026-10-13）：`static let` 会把 `L()` 的结果进程级缓存住 ⇒ 切语言后不翻。
    private static var title: String { L("松开即可添加到输入框") }

    /// ⚠️ `id` 用 `category` —— 三项文案互不相同，够用；别用下标（那是 SwiftUI 的反模式，
    //    与 `LazyVStack` 那边同一个理由，虽然这里静态不会动）。
    private struct FormatRow: Identifiable {
        let category: String
        let extensions: String
        var id: String { category }
    }

    /// 「支持哪些格式」的口径 —— 真值来源见文件头那段注释。
    ///
    /// ⚠️ 第三行那句「**文件夹不支持**」不是客套：拖拽**必然**会碰到用户把文件夹拖进来
    ///    （访达里文件夹和文件长得一样），而工具层用的是 `copyItem`（会递归整棵拷）。
    ///    与其等用户拖一个大目录进来才发现发不出去，不如在这儿先说清楚。
    ///    拦截落在 `ComposerAttachmentPicker.importURLs` 里（选文件那条路也共用）。
    private static let formats: [FormatRow] = [
        FormatRow(category: L("图片"), extensions: "PNG · JPEG · HEIC · GIF · WebP"),
        FormatRow(category: L("文本"), extensions: L("TXT · MD · JSON · CSV · PDF · 代码等 32 种")),
        FormatRow(category: L("其它"), extensions: L("任意文件（文件夹不支持）")),
    ]
}
