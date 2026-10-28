//
//  AIMention.swift
//  AICore
//
//  输入框里用 `@` 挑进来的**项目资料**（2026-10-21）。
//
//  ## 为什么只做「项目资料」（用户 2026-10-21 明确圈的范围）
//  候选来源必须落在 **App 自己管的文件**上：本 App 是沙盒，读不到任意磁盘路径
//  （「读代码仓库」= L4，当年刻意不做）⇒ 能 @ 的只有
//  ① 项目资料（`AIChatProjectFile`，`storageName` 是 `AIAttachmentStorage` 的存储标识）、
//  ② 本条会话已发出的附件 —— 那个已有「+ → 文件」入口，v1 不重复做；
//  ③ 历史消息 —— 那已经由「引用」(`AIQuote`) 占着，两条语义会打架。
//  ⇒ v1 = **只有项目资料**。⛔ 别顺手把 ②③ 加进来：那两条各自需要另一套 UI 与语义。
//
//  ## 与 `AIQuote` 的分工（这两者最容易被混成一件东西）
//  | | `AIQuote` | `AIMention` |
//  |---|---|---|
//  | 语义 | 「针对**这段内容**提问」 | 「这轮**参考这几份资料**」 |
//  | 内容 | **文本快照**（被引消息可能已被删） | **指针**（`projectFileId` + `storageName`） |
//  | 原因 | 引用是「当时那句话」的事实 | 资料是**活的**：文件改了就该读新版；也不该把 8k 字塞进数据库 |
//  | 注入 | 正文**之前**（先说清在指哪段） | 正文**之后**（先问问题，再附材料） |
//  ⇒ 所以 `AIMention` **不存正文** —— 存了就成了另一份会过期的事实。
//
//  ## 为什么在正文里还要留一串 `@文件名`
//  输入框里插入的是**纯文本** `@季度报告.md `（不是自绘 chip）：纯文本才能正常编辑 / 删除 /
//  全选复制，也不必去碰「输入框里内联富文本」那套最容易崩的东西。
//  🔴 但**唯一真值是这个 mention 数组**，正文那串只是给人看的提示。
//     手删了正文里那串 `@…` 而 chip 还在 ⇒ 以 chip 为准（照发）。
//  ⚠️ 反过来（正文里手打 `@名字`、但没从面板里选）**不会**被解析成资料 ——
//     重名 / 改名 / 同名不同目录都会解析错，而「说了却没带上」比「没带」更难查。
//

import Foundation

/// 一条「@ 进来的项目资料」。
///
/// 与 `AIChatProjectFile` 的关系：这里是**发送那一刻的快照**（名字、大小、存储标识），
/// 不持有 `AIChatProjectFile` 本身 —— 那个记录可能在发送之后被删，
/// 而这条消息「当时 @ 了哪份资料」是既成事实，要显示得出来。
public struct AIMention: Equatable, Hashable {

    /// 资料 id（点待发条 / 回看消息时用来定位；那份资料可能已被删除）
    public let projectFileId: UUID
    /// 显示名（原文件名；磁盘上是一串 UUID，那个不能给人看）
    public let displayName: String
    /// `AIAttachmentStorage` 的存储标识（⛔ 不是绝对路径 —— 沙盒容器路径会变）
    public let storageName: String
    public let byteSize: Int64

    public init(projectFileId: UUID,
                displayName: String,
                storageName: String,
                byteSize: Int64) {
        self.projectFileId = projectFileId
        self.displayName = displayName
        self.storageName = storageName
        self.byteSize = byteSize
    }

    /// 从项目资料记录建一条（UI 从面板里选中的那一下）
    public init(_ file: AIChatProjectFile) {
        self.init(projectFileId: file.id,
                  displayName: file.displayName,
                  storageName: file.storageName,
                  byteSize: file.byteSize)
    }

    public var sizeText: String { ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file) }

    /// 输入框里插入的那串文本（结尾带一个空格，好接着打字）。
    ///
    /// ⚠️ 它是**函数不是属性**（`func token()`）：调用处一眼看得出「这里在生成一串要写进正文的字」，
    ///    而属性名容易被误读成「这条资料本身的值」。
    /// ⚠️ 别把它写成 key path（`map(\.token())`）—— Swift 的 key path 不能指向实例方法，会编译报错。
    public func token() -> String { "@\(displayName) " }

    /// 待发条上的单行摘要（名字可能很长）—— 与 `AIQuote.summary` 同款：压掉换行再截断。
    public func summary(limit: Int = 28) -> String {
        let flattened = displayName
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }

    /// 同一条消息里最多带几份资料。
    ///
    /// 定 3 的理由是**上下文预算**而不是界面：单份资料读进上下文最多 8000 字符
    /// （`AIAttachmentStorage.extractedText` 的 `maxChars`）⇒ 3 份 ≈ 24k 字符，
    /// 已经接近一轮对话的合理输入量。再多，模型反而会「每份都只看开头」。
    /// ⚠️ 这是**共享层与 UI 共用的同一个数**：面板到达上限就禁用新增，
    /// 发送前还会再 `prefix` 一次兜底（防御式，正常路径到不了）。
    public static let maxPerMessage = 3
}
