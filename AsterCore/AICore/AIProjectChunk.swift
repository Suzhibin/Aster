//
//  AIProjectChunk.swift
//  AICore
//
//  项目资料的「检索索引」模型（RAG 第一版，2026-10-23）。
//
//  ## 这是什么
//  项目里每一份可读文本的资料，被切成一串**片段**（chunk）存进 `ai_project_file_chunk` 表。
//  提问时按关键词相关度挑出 top-k 片段，拼成本轮 user 消息的参考资料（见 `AIProjectRetriever`）。
//  它是「@ 项目资料」（人肉选文件、全文硬塞）的**自动版**：@ 是指哪打哪，这是库大了之后的检索路。
//
//  ## 三条设计口径（⛔ 别绕）
//  ① **片段是派生物，不是真值**：磁盘上那份文件才是真值。所以片段表只管「加快检索」，
//     任何时刻都能整表重建（`rebuildProjectIndex`）—— 别把它当业务数据供起来。
//  ② **二进制不索引**：只索引 `AIAttachmentStorage.extractedText` 读得出正文的
//     （txt/md/代码/csv/pdf…——PDF 走 PDFKit 抽文本层，2026-10-23 起）。
//     其余（zip/二进制/扫描件 PDF）跳过，状态里计入「待索引」，不报错。
//  ③ **不上向量**：第一版是关键词评分（BM25 思路的简化版），零依赖、iOS 15 兼容、
//     可解释（每个片段为什么命中说得清）。Embedding 是二期的事，别提前把接口堵死。
//

import Foundation

/// 项目资料的一个**分块**（检索的最小单位，2026-10-23）。
///
/// 一条 chunk 对应「某文件某一段文字」；`index` 是文件内的序号（0 起），
/// 检索结果的排序 tie-break 与注入次序都靠它保持稳定（同文件按出现顺序）。
public struct AIProjectFileChunk: Identifiable, Hashable {

    public let id: UUID
    public let projectId: UUID
    /// 所属资料行（`AIChatProjectFile.id`）。资料被删 ⇒ chunk 级联删
    public let fileId: UUID
    /// 文件内的第几块（0 起）
    public let index: Int
    public let text: String
    /// 字符数（冗余一列：注入前算预算 / 调试时不用现算）
    public let charCount: Int
    public let createdAt: Date

    public init(id: UUID = UUID(),
                projectId: UUID,
                fileId: UUID,
                index: Int,
                text: String,
                charCount: Int? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.projectId = projectId
        self.fileId = fileId
        self.index = index
        self.text = text
        self.charCount = charCount ?? text.count
        self.createdAt = createdAt
    }
}

/// 一个项目的索引状态（详情页那一行「已索引 N/M」读它）。
public struct AIProjectIndexStatus {

    /// 项目资料总数（含读不出文本的二进制）
    public let fileCount: Int
    /// 已建出片段的资料数
    public let indexedFileCount: Int
    /// 片段总数
    public let chunkCount: Int

    public init(fileCount: Int, indexedFileCount: Int, chunkCount: Int) {
        self.fileCount = fileCount
        self.indexedFileCount = indexedFileCount
        self.chunkCount = chunkCount
    }

    /// 还没索引的资料数（二进制 / 空文本 / 还没轮到）
    public var pendingCount: Int { max(0, fileCount - indexedFileCount) }

    /// 有没有可检索的内容（控制行那颗开关的可用性判据也读它）
    public var hasIndexedContent: Bool { chunkCount > 0 }
}

/// 一次检索的**一个命中**（带来源文件与分数，注入与展示都用它）。
public struct AIProjectChunkHit: Hashable {

    public let chunk: AIProjectFileChunk
    /// 来源资料的显示名（`AIChatProjectFile.displayName`；查不到时给占位）
    public let fileName: String
    /// 相关度（0…1，口径见 `AIProjectRetriever`：查询词信息量的覆盖比例）
    public let score: Double

    public init(chunk: AIProjectFileChunk, fileName: String, score: Double) {
        self.chunk = chunk
        self.fileName = fileName
        self.score = score
    }
}
