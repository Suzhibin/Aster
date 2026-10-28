//
//  AIChunker.swift
//  AICore
//
//  文本分块器（RAG 第一版，2026-10-23）—— 把一份资料的正文切成检索用的片段。
//
//  ## 为什么按「段落」切，不按固定字数硬切
//  硬切会把一句话/一段代码拦腰斩断，片段失去语义完整性，检索命中时模型读到半句话。
//  段落是天然的语义边界：以 **target 字数为上界**攒段落，超了才收块；单个超长段落
//  （没有换行的一整坨，比如 minified JS）才退化成硬切。
//
//  ## 块间重叠（overlap）
//  相邻块共享末尾一小段（默认 80 字）：答案正好跨块边界时，另一块里还留着一半上下文。
//  代价是同样的文字会存两遍（索引体积 +~16%），换来的收益在边界场景上是实的。
//
//  ## 为什么这些数字
//  - target 500 字：一段话的量级，注入 5 个片段 ≈ 2500 字，与联网搜索的资料块同量级；
//  - overlap 80 字：约一句话，够接上被斩断的半句，又不至于让块与块长得太像（重复会稀释检索区分度）；
//  - maxIndexChars 200_000 字：一份资料最多索引这么多（再大的通常是日志/数据文件，
//    全索引既慢又占地方）。超出部分**直接不索引**（状态计入「待索引」），⛔ 不静默截断到 200k
//    —— 那会给用户「已索引」的错觉。
//

import Foundation

public enum AIChunker {

    /// 单块目标字数（上界；段落装得下就小于它）
    public static let targetChunkChars = 500

    /// 相邻块重叠字数
    public static let overlapChars = 80

    /// 单份资料最多索引的字符数（超出 ⇒ 整份不索引）
    public static let maxIndexChars = 200_000

    /// 把正文切成片段。空文本 / 纯空白返回 `[]`。
    ///
    /// - 返回的片段都已去首尾空白、非空；顺序 = 文件内出现顺序（`AIProjectFileChunk.index`）。
    public static func chunks(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var result: [String] = []
        var buffer = ""
        // 上一个已收块的「尾部」—— 下一块的开头要带上它（见文件头「块间重叠」）
        var carry = ""

        func flush() {
            let chunk = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { result.append(chunk) }
            carry = tail(chunk, overlapChars)
            buffer = ""
        }

        for paragraph in normalized.components(separatedBy: "\n") {
            let para = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if para.isEmpty { continue }   // 空行只是分隔，不进块

            // 超长单段：按字数硬切（每片仍带重叠），切完的尾部进 carry
            if para.count > targetChunkChars {
                if !buffer.isEmpty { flush() }
                var rest = para
                while rest.count > targetChunkChars {
                    let head = String(rest.prefix(targetChunkChars))
                    result.append(head)
                    carry = tail(head, overlapChars)
                    rest = String(rest.suffix(rest.count - targetChunkChars))
                }
                buffer = carry + rest
                continue
            }

            // buffer + carry 会超目标 ⇒ 收块，新块以 carry 开头
            if !buffer.isEmpty, buffer.count + 1 + para.count > targetChunkChars {
                flush()
                buffer = carry
            }
            if buffer.isEmpty {
                buffer = para
            } else {
                buffer += "\n" + para
            }
        }
        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    /// 取一段文字的末尾 `count` 字（丢前导空白，避免下一块以半句话的中间开头）。
    private static func tail(_ text: String, _ count: Int) -> String {
        guard text.count > count else { return text }
        return String(text.suffix(count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
