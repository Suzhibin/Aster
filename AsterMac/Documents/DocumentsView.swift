//
//  DocumentsView.swift
//  AsterMac
//
//  「文档」页（2026-10-10 用户需求；入口 = 侧栏最上面那颗「文档」，取代原「AI创作」）。
//
//  > 「所有对话中 用户上传 和 AI 返回的文件、文档 都在这个文档页面显示，
//  >   以列表形式显示，顺序以最近的为第一个。」
//
//  ## 形态：**主区域整页替换**（用户 2026-10-10 拍板）
//  > 「主区域整页替换，但是需要新建一个页面，**不要在对话页面继续开发**」
//  ⇒ 它是**独立的一页**（就是本文件），由 `RootView` 的 `detail` 按
//    `model.isDocumentsShown` 在 `ChatDetailView` 与它之间二选一。
//  ⛔ 别把这块塞进 `ChatDetailView` 当一段条件视图，也别改成 sheet ——
//    前一种正是用户点名不要的「在对话页面继续开发」。
//
//  ## 收录范围 = **只文件**
//  PDF / 表格 / 压缩包 / 代码 / 文本那一类，**不含图片与视频**（用户同日拍板）。
//  口径写在共享层 `AIDocumentItem`，这一页只负责画。
//
//  ## 数据由 `ChatModel` 提供
//  `model.documents`（进页面时 `showDocuments()` 拉一次）。本视图**不直连 store** ——
//  与 Mac 侧其它视图一致：视图只读 VM。
//
//  ## 行为什么抽成 `DocumentRow`
//  `List` 在离屏渲染里只会被画成**黄条 + ⊘** ⇒ 留在本视图里的话，「文件名怎么截断、
//  副标题多小」这些一张图都拿不到。抽出来之后 `render_mac_ui.sh` 能单独渲它
//  （同 `ConversationRow` / `SidebarSettingsBar` 的做法）。
//
//  ## 时间走共享层的唯一入口
//  `AIMessageTime.string(from:)`。⛔ 视图层别自己 new `DateFormatter`
//  （那条规矩见 `AIMessageTime` 文件头）。
//

import SwiftUI
import AICore

struct DocumentsView: View {

    @Environment(ChatModel.self) private var model

    // ☠️ 这里曾有一行 `@Environment(\.aiLanguageID) private var languageID`（2026-10-13 第三版删）。
    //    换身份那套已整体废弃（成因见 `AILocalization.swift` 文件头）。

    var body: some View {
        Group {
            if model.documents.isEmpty {
                emptyState
            } else {
                documentList
            }
        }
        // ☠️☠️ 2026-10-13 **第三版**：这里**不许**再挂 `.id(languageID)`（前两版挂过）。
        //    前面那版把 `.id` 排在 `.toolbar` **之前**也没用 —— 只要本列的内容子树里出现身份变化，
        //    AppKit 就把挂在本列上的工具栏项（下面那颗「关闭文档页 ✕」）的 hosting view
        //    拆掉、**且不再回填**（实测见 `AILocalization.swift` 文件头）。
        //    ⇒ 文案重算改由 `L()` 自己的观察依赖负责。
        // 撑满详情区，否则 Group 里的内容会被 NavigationSplitView 按内容尺寸居中留白
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacTheme.pageBackground)
        .toolbar {
            // 🔴 唯一的「返回对话」入口。侧栏点会话也能回去，但那样用户得先想到「去点左边」——
            //    这一页占的是整个主区域，没有任何系统返回键可依赖（它不在导航栈里）。
            ToolbarItem(id: "closeDocumentsPage", placement: .primaryAction) {
                Button {
                    model.hideDocuments()
                } label: {
                    Image(systemName: "xmark")
                }
                .help(L("关闭文档页，回到对话"))
            }
        }
    }

    // MARK: - 列表

    private var documentList: some View {
        List(model.documents) { item in
            Button {
                model.openDocument(item)
            } label: {
                DocumentRow(item: item)
            }
            // `.plain` 才能让整行都是命中区（默认的 bordered 会把行画成一颗带边框的按钮）
            .buttonStyle(.plain)
        }
        .listStyle(.inset)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(MacTheme.ui(28))
                .foregroundStyle(MacTheme.meta)
            Text(L("还没有文件"))
                .font(MacTheme.ui(13))
                .foregroundStyle(MacTheme.bodyColor)
            Text(L("在对话里上传的文件都会出现在这里"))
                .font(MacTheme.ui(MacTheme.metaFontSize))
                .foregroundStyle(MacTheme.meta)
        }
    }
}

// MARK: - 行

/// 一行文档：左侧扩展名角标 + 文件名 + 「大小 · 来自哪个会话」+ 右侧时间。
///
/// ⚠️ 文件名用 `displayName`（= `block.text`）而不是 `fileURL.lastPathComponent`：
/// 附件落盘时名字被换成了 UUID（`52EDE56F-….xlsx`），用户认得的名字是
/// `iOS上线CheckList.xlsx` —— iOS 的 `AIFilePreviewController` 与 mac 的 `FilePreviewPane`
/// 都在这上面踩过，这里别再踩第三次。
///
/// ⚠️ **不吃 `@Environment`**：渲染台要能不带环境单独渲它（同 `ConversationRow` 的理由）。
struct DocumentRow: View {

    let item: AIDocumentItem

    var body: some View {
        HStack(spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(MacTheme.ui(13))
                    .foregroundStyle(MacTheme.bodyColor)
                    // 两行：长文件名（xlsx / markdown 那类）截一半就认不出来了
                    .lineLimit(2)
                Text(detailText)
                    .font(MacTheme.ui(MacTheme.metaFontSize))
                    .foregroundStyle(MacTheme.meta)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            // 时间不许被标题挤掉；要挤先挤标题（同 `MacSearchView` 的做法）
            Text(AIMessageTime.string(from: item.createdAt))
                .font(MacTheme.ui(MacTheme.metaFontSize))
                .foregroundStyle(MacTheme.meta)
                .fixedSize()
        }
        .padding(.vertical, 4)
        // 整行可点：默认命中形状只有「画了东西的地方」，标题右侧那片空白点不动
        .contentShape(Rectangle())
    }

    /// 「1.2 MB · 来自「某某会话」」
    private var detailText: String {
        String(format: L("%@ · 来自「%@」"), item.sizeText, item.displayConversationTitle)
    }

    /// 扩展名角标。
    /// ⚠️ **固定 34×34**：两种状态（有扩展名 / 没有）都不变尺寸，否则一行里
    /// 文件名与副标题的起始位置会随文件类型左右跳。
    private var badge: some View {
        Text(item.fileExtension.isEmpty ? "?" : item.fileExtension)
            .font(MacTheme.ui(10, weight: .semibold))
            .foregroundStyle(MacTheme.meta)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}
