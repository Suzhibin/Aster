//
//  AIDocument.swift
//  AIModule
//
//  「文档」页的数据模型（2026-10-10 用户需求）。
//
//  > 「去掉 AI创作，增加『文档』选项。所有对话中 用户上传 和 AI 返回的文件、文档
//  >   都在这个文档页面显示，以列表形式显示，顺序以最近的为第一个。」
//
//  ## 收录口径 = **只文件**（用户 2026-10-10 拍板）
//  即 `AIBlockKind.file` 那一类（PDF / 表格 / 压缩包 / 代码 / 文本…），
//  **不含图片与视频** —— 图片有行内缩略图和各自的预览入口，混进这个列表只会让它变成
//  一个「什么都装」的抽屉；「文档」页要回答的是「我传过哪些文件」。
//
//  ⚠️ AI 侧目前**不会**返回文件块（助手侧只有图片 / 视频），所以现在数据实际全来自
//  「用户上传」一侧。这不是 bug：查询条件写的是 **kind = file**，将来助手侧真发了文件，
//  它自动就会出现在这里 —— ⛔ 别为了「现在只有一侧」把条件收紧成「role = user」。
//
//  ## 为什么单独一个模型、而不是复用 `AIBlock`
//  `AIBlock` 只有「本会话」的上下文（它连自己的会话标题都不知道），而这一页要跨会话；
//  列表行还要显示「来自哪个会话」——那是消息表里没有的字段，得 join 会话表补。
//

import Foundation

/// 「文档」页里的一行：某次对话中出现的**一个文件**。
public struct AIDocumentItem: Identifiable, Equatable {

    /// 对应消息块 id。
    ///
    /// ⚠️ 用它当列表身份而不是 `fileURL`：同一个文件可以被发进两段对话（附件是拷贝，
    /// 两份路径不同，但「同一份文件的两次发送」应当各自成行）。反过来，拿路径当 id 时
    /// 若将来支持「同一个路径被引用两次」，`Identifiable` 会给出重复 id。
    public let id: UUID

    /// 这份文件出现在哪次对话里（点行后可以据此回跳会话）。
    public let conversationId: UUID

    /// 该会话的标题（**可能为空串** —— 会话还没起标题时就落库了；展示走 `displayConversationTitle`）
    public let conversationTitle: String

    /// 沙盒里的本地文件（`AIAttachmentStorage` 落地）
    public let fileURL: URL

    /// 用户当初发出的文件名（存在 `ai_message.text` 列）。
    /// ⚠️ 磁盘上的名字是 UUID ⇒ 展示**必须**用它，别用 `fileURL.lastPathComponent`
    ///（同 `AIFilePreviewController` / `FilePreviewPane` 踩过的那个坑）。
    public let displayName: String

    /// 字节数（**不入库**，查询时从磁盘现算）
    public let byteSize: Int64

    /// 这条消息的落库时间（列表排序依据）
    public let createdAt: Date

    public init(id: UUID,
                conversationId: UUID,
                conversationTitle: String,
                fileURL: URL,
                displayName: String,
                byteSize: Int64,
                createdAt: Date) {
        self.id = id
        self.conversationId = conversationId
        self.conversationTitle = conversationTitle
        self.fileURL = fileURL
        self.displayName = displayName
        self.byteSize = byteSize
        self.createdAt = createdAt
    }

    /// 人类可读的大小（1.2 MB / 340 KB）
    public var sizeText: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    /// 扩展名（大写，给行首那枚角标用）。无扩展名时给空串，调用方画通用图标。
    public var fileExtension: String {
        fileURL.pathExtension.uppercased()
    }

    /// 会话标题的展示口径。
    /// 🔴 与 `AIConversation.displayTitle` / `AIConversationSummary.displayTitle` **同一口径**
    ///（空标题补「新对话」）—— 三处都是「给人看的那个标题」，改一处就三处一起改。
    public var displayConversationTitle: String {
        conversationTitle.isEmpty ? L("新对话") : conversationTitle
    }
}
