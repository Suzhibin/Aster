//
//  CodePane.swift
//  AsterMac
//
//  右侧面板的**第四种内容**：一个**代码 / 文本文件**（2026-10-07 加）。
//
//  用户口径（原话）：「文件夹内如果有代码文件点击 增加标签并显示代码？」
//  ⇒ 面板里点目录树里的一个代码文件 = **新开一个标签**，那个标签里画这个文件。
//
//  ## 🔴 高亮方案：**自写词法器**（用户 2026-10-07 拍板选的 B 方案）
//  macOS **没有**公开的「高亮这段代码」API。四条路当时比过：
//    | 方案 | 依赖 | 主题口径 | 离屏能照到 |
//    |---|---|---|---|
//    | **A 纯文本 + 行号** | 无 | 天然合规 | ✅ |
//    | **B 自写词法器 → `AttributedString` + `Text`** ← 选这条 | 无 | ✅ 全走 `MacTheme` | ✅ |
//    | C Highlightr（highlight.js / JavaScriptCore） | +1 SPM（含 JS 引擎与 1MB+ 资源） | ⚠️ 自带主题是 CSS，得手动映射 | ✅ |
//    | D 复用 `WKWebView` + highlight.js | 无（复用） | ⚠️ 要从 MacTheme 生成 CSS | ❌ 且打破「非网页标签不养 Web 进程」那条不变量 |
//  ⇒ B 的好处正好命中本工程两条既有惯例：**零依赖** + **颜色只在 `MacTheme` 分叉**。
//    代价是语言覆盖窄（就下面 `CodeLanguage` 那几个族），⛔ 别指望它比得上 highlight.js。
//
//  ## 🔴 行号**内嵌在同一个文本里**（不是旁边再放一列 `Text`）
//  分成两列时，两边的字宽 / 行高 / 行距只要有一处不一致，几十行之后就开始**错位**
//  —— 这是这类视图最容易翻的车。内嵌进**同一次排版**则结构上不可能错。
//  ⚠️ 两笔已知代价（用户已接受「先要形态」）：
//    ① 水平滚动时行号**跟着一起走**（Xcode 那种「行号钉住」做不到）；
//    ② 整体选中复制时会把行号一起复制走。
//
//  ## ☠️ 三条不许违反的
//  ① **高亮不许在 `body` 里做**（本工程铁律：body 期别干重活）⇒ 扫描在
//     `nonisolated async` 里跑（全局执行器），组装结果**按 `ColorScheme` 缓存**。
//  ② **读盘 / 解码 / 扫描一律 `nonisolated async`**：本 target 是
//     `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，不写 `nonisolated` 就等于在主线程读盘。
//  ③ 体量三档：小 ⇒ 高亮；中 ⇒ 只给纯文本 + 行号；大 ⇒ 直接劝退（给「用系统预览打开」的出路）。
//
//  ## ⚠️ 为什么用 `ObservableObject` 而不是 `@Observable`
//  与 `WebPageModel` 同一理由（见 `WebPageView.swift` 文件头）：本工程的验收台
//  **完全不能展开宏**，每加一个 `@Observable` 都要去脚本里手工补一致性代码。⛔ 别改。
//

import SwiftUI
import Combine
import Foundation
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

// MARK: - 语言

/// 语法族。**刻意只分几个族**，不是「一种语言一个 `case`」——
/// 一个族就是一套「注释符 + 关键字表」，同族语言共用就够了（见文件头那条取舍）。
enum CodeLanguage: String, Sendable, CaseIterable {

    case swift
    case cFamily
    case jsLike
    case python
    case shell
    case json
    case css
    case sql
    case config
    case plain

    /// 🔴 **唯一**的「这个文件该不该进代码视图」判据（`WebPageModel` 与目录树共用它，
    ///    ⛔ 别在别处再写一份扩展名判断）。
    ///
    /// `nil` = **不是代码** ⇒ 交回 QuickLook（`.file` 那一档）。
    /// ⚠️ 这是**明示清单**，不是「凡文本皆可」：`md` / `html` / `plist` / `svg` /
    ///    `txt` / `csv` 都**刻意排除** —— QuickLook 把它们渲染得比我们这块只读文本好得多
    ///    （`.md` 渲染成排版、`.plist` 是树、`.html` 直接画、`.svg` 当图）。
    ///    ⛔ 别图省事把它们收进来。
    static func forFile(_ url: URL) -> CodeLanguage? {
        if let byName = byFileName[url.lastPathComponent] { return byName }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        switch ext {
        case "swift": return .swift
        case "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "hxx", "c": return .cFamily
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": return .jsLike
        case "py", "pyw": return .python
        case "sh", "bash", "zsh", "fish", "command", "mk": return .shell
        case "json", "json5", "geojson", "resolved": return .json
        case "css", "scss", "less", "sass": return .css
        case "sql": return .sql
        case "yml", "yaml", "toml", "ini", "conf", "cfg", "env", "properties", "pbxproj": return .config
        // 「肯定是代码，但不是上面任何一族」⇒ 归 `cFamily`：注释符与引号规则够用了，
        // 关键字表匹配不上就是「只有字符串/注释/数字上色」，不会出错。
        case "go", "rs", "java", "kt", "kts", "cs", "scala", "dart", "lua", "php",
             "pl", "pm", "r", "asm", "s", "vb", "fs", "gradle", "podspec", "lock":
            return .cFamily
        default: return nil
        }
    }

    /// 没有扩展名、但明显是代码 / 配置的那几个（靠**文件名**认）。
    private static var byFileName: [String: CodeLanguage] {
        [
            "Makefile": .shell, "makefile": .shell, "GNUmakefile": .shell,
            "Dockerfile": .shell, "Podfile": .cFamily, "Gemfile": .cFamily,
            "Rakefile": .cFamily, "Procfile": .shell, "Brewfile": .cFamily,
            ".gitignore": .config, ".gitattributes": .config,
            ".editorconfig": .config, ".env": .config,
        ]
    }
}

// MARK: - 高亮结果

/// 一段被上色的区间。⚠️ 偏移是 **Character**（不是 UTF-16）—— 见 `CodeAssembler` 的用法。
struct CodeSpan: Sendable, Equatable {
    let kind: CodeTokenKind
    let start: Int
    let end: Int
}

enum CodeTokenKind: Sendable {
    case keyword
    case type
    case string
    case comment
    case number
    case preprocessor
}

/// 一个语法族的规则表。
/// ⚠️ 全部是**值类型**、并且都由 `CodeSyntax.forLanguage(_:)` **现造**（不是静态存储属性）
///    —— 本 target 默认 `MainActor` 隔离，静态存储属性会变成主 actor 的，
///    而 `scan` 必须能在全局执行器上读它。现造一份的成本是**一次文件打开一次**，可以忽略。
struct CodeSyntax: Sendable {
    var keywords: Set<String> = []
    var types: Set<String> = []
    var lineComments: [String] = []
    var blockComments: [CommentPair] = []
    var quotes: [Character] = ["\"", "'"]
    /// `#import` / `#define` 那种「井号开头」的记号要不要上色。
    var hashDirective = false

    struct CommentPair: Sendable {
        let open: String
        let close: String
    }
}

// MARK: - 词法器

/// 单遍扫描的词法器。
///
/// 🔴 顺序要紧：**注释 → 字符串 → 数字 → 标识符**。反过来的话，
///    `// 这里有一句 "引号"` 会被当成字符串开始、把后面半段文件吃掉。
enum CodeHighlighter {

    /// `nonisolated` + 无副作用 ⇒ 可以在全局执行器上跑（见文件头 ②）。
    nonisolated static func scan(_ text: String, language: CodeLanguage) -> [CodeSpan] {
        let syntax = CodeSyntax.forLanguage(language)
        guard !syntax.keywords.isEmpty || !syntax.lineComments.isEmpty
                || !syntax.blockComments.isEmpty || !syntax.quotes.isEmpty else {
            return []      // `.plain`：一个字都不上色（诚实：不假装高亮）
        }
        let chars = Array(text)
        let n = chars.count
        var spans: [CodeSpan] = []
        var i = 0
        while i < n {
            let c = chars[i]

            // ① 行注释
            if let marker = syntax.lineComments.first(where: { matches(chars, i, $0) }) {
                let start = i
                i += marker.count
                while i < n, chars[i] != "\n" { i += 1 }
                spans.append(CodeSpan(kind: .comment, start: start, end: i))
                continue
            }

            // ② 块注释（☠️ 必须有「未闭合」兜底：少写一个 `*/` 时不能把后面整个文件吃掉）
            if let pair = syntax.blockComments.first(where: { matches(chars, i, $0.open) }) {
                let start = i
                i += pair.open.count
                while i < n, !matches(chars, i, pair.close) { i += 1 }
                i = min(n, i + pair.close.count)
                spans.append(CodeSpan(kind: .comment, start: start, end: i))
                continue
            }

            // ③ 字符串
            if syntax.quotes.contains(c) {
                let start = i
                i += 1
                while i < n {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == c { i += 1; break }
                    // ☠️ 引号没闭合时不要把**后面整个文件**当字符串：
                    //    遇到换行就收手（反引号/`'''` 那种多行字符串除外，见 `quotes` 表）。
                    if chars[i] == "\n" { break }
                    i += 1
                }
                spans.append(CodeSpan(kind: .string, start: start, end: min(i, n)))
                continue
            }

            // ④ `#` 开头的预处理指令
            if syntax.hashDirective, c == "#", i + 1 < n, chars[i + 1].isLetter {
                let start = i
                i += 1
                while i < n, isWordChar(chars[i]) { i += 1 }
                spans.append(CodeSpan(kind: .preprocessor, start: start, end: i))
                continue
            }

            // ⑤ `@interface` 那一类（ObjC 的 `@` 关键字）——只认表里有的，别的一律放过
            if c == "@", i + 1 < n, chars[i + 1].isLetter {
                let start = i
                var j = i + 1
                while j < n, isWordChar(chars[j]) { j += 1 }
                if syntax.keywords.contains(String(chars[start..<j])) {
                    spans.append(CodeSpan(kind: .keyword, start: start, end: j))
                    i = j
                    continue
                }
                i = j
                continue
            }

            // ⑥ 数字（前面不能紧跟字母/数字/下划线 —— 否则把 `abc1` 里的 1 也点出来）
            if c.isNumber, !(i > 0 && isWordChar(chars[i - 1])) {
                let start = i
                while i < n, chars[i].isNumber || chars[i].isLetter || chars[i] == "_" || chars[i] == "." {
                    i += 1
                }
                spans.append(CodeSpan(kind: .number, start: start, end: i))
                continue
            }

            // ⑦ 标识符 ⇒ 关键字 / 类型
            if c.isLetter || c == "_" {
                let start = i
                while i < n, isWordChar(chars[i]) { i += 1 }
                let word = String(chars[start..<i])
                if syntax.keywords.contains(word) {
                    spans.append(CodeSpan(kind: .keyword, start: start, end: i))
                } else if syntax.types.contains(word) {
                    spans.append(CodeSpan(kind: .type, start: start, end: i))
                }
                continue
            }

            i += 1
        }
        return spans
    }

    // MARK: 小工具

    private nonisolated static func matches(_ chars: [Character], _ at: Int, _ token: String) -> Bool {
        guard !token.isEmpty, at + token.count <= chars.count else { return false }
        var j = 0
        for ch in token {
            if chars[at + j] != ch { return false }
            j += 1
        }
        return true
    }

    private nonisolated static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}

// MARK: - 规则表（按语言）

extension CodeSyntax {

    /// 现造一份规则（见类型头注：⛔ 别改成静态存储属性）。
    nonisolated static func forLanguage(_ language: CodeLanguage) -> CodeSyntax {
        switch language {
        case .swift:
            return CodeSyntax(
                keywords: ["func", "let", "var", "if", "else", "guard", "return", "for", "while",
                           "switch", "case", "default", "break", "continue", "struct", "class",
                           "enum", "protocol", "extension", "import", "init", "deinit", "self",
                           "super", "nil", "true", "false", "try", "catch", "throw", "throws",
                           "async", "await", "actor", "some", "any", "in", "where", "as", "is",
                           "private", "fileprivate", "internal", "public", "open", "static",
                           "final", "lazy", "weak", "unowned", "mutating", "nonmutating",
                           "override", "required", "convenience", "typealias", "associatedtype",
                           "inout", "defer", "repeat", "do", "willSet", "didSet", "get", "set",
                           "subscript", "indirect", "internal"],
                types: ["String", "Int", "Double", "Float", "Bool", "Array", "Dictionary", "Set",
                        "Optional", "Result", "Error", "Void", "Any", "AnyObject", "Character",
                        "Data", "Date", "URL", "UUID", "Task", "Set"],
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/")],
                quotes: ["\""],
                hashDirective: true)
        case .cFamily:
            return CodeSyntax(
                keywords: ["if", "else", "for", "while", "do", "switch", "case", "default",
                           "break", "continue", "return", "goto", "sizeof", "typedef", "struct",
                           "union", "enum", "static", "const", "extern", "inline", "register",
                           "volatile", "signed", "unsigned", "void", "char", "short", "int",
                           "long", "float", "double", "class", "public", "private", "protected",
                           "virtual", "template", "typename", "namespace", "using", "new",
                           "delete", "this", "nullptr", "NULL", "true", "false",
                           // ObjC 的 `@` 关键字（`scan` 里按「@ + 表里有」认）
                           "@interface", "@implementation", "@end", "@protocol", "@property",
                           "@synthesize", "@dynamic", "@class", "@selector", "@param",
                           "@return", "@import", "@autoreleasepool", "@available", "@objc",
                           "@try", "@catch", "@finally", "@throw"],
                types: ["BOOL", "NSInteger", "NSUInteger", "CGFloat", "NSString", "NSArray",
                        "NSDictionary", "NSObject", "NSError", "NSURL", "NSData", "id", "instancetype",
                        "size_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t",
                        "int8_t", "int16_t", "int32_t", "int64_t", "dispatch_queue_t"],
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/")],
                quotes: ["\"", "'"],
                hashDirective: true)
        case .jsLike:
            return CodeSyntax(
                keywords: ["function", "return", "if", "else", "for", "while", "do", "switch",
                           "case", "default", "break", "continue", "const", "let", "var", "new",
                           "delete", "typeof", "instanceof", "in", "of", "class", "extends",
                           "super", "this", "try", "catch", "finally", "throw", "async", "await",
                           "yield", "import", "export", "from", "default", "null", "undefined",
                           "true", "false", "interface", "type", "enum", "implements", "declare",
                           "readonly", "public", "private", "protected", "static"],
                types: ["string", "number", "boolean", "any", "unknown", "never", "void",
                        "object", "Array", "Promise", "Record", "Partial", "Map", "Set"],
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/")],
                quotes: ["\"", "'", "`"])
        case .python:
            return CodeSyntax(
                keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in",
                           "not", "and", "or", "is", "None", "True", "False", "import", "from",
                           "as", "with", "try", "except", "finally", "raise", "pass", "break",
                           "continue", "lambda", "global", "nonlocal", "yield", "assert", "del",
                           "async", "await", "self"],
                types: ["int", "float", "str", "bool", "list", "dict", "tuple", "set", "bytes",
                        "Exception", "ValueError", "TypeError", "KeyError"],
                lineComments: ["#"],
                blockComments: [],
                quotes: ["\"", "'"])
        case .shell:
            return CodeSyntax(
                keywords: ["if", "then", "else", "elif", "fi", "for", "while", "do", "done",
                           "case", "esac", "function", "in", "return", "exit", "export", "local",
                           "readonly", "source", "alias", "echo", "cd", "set", "unset", "shift",
                           "trap", "eval", "exec"],
                types: [],
                lineComments: ["#"],
                blockComments: [],
                quotes: ["\"", "'", "`"])
        case .json:
            return CodeSyntax(
                keywords: ["true", "false", "null"],
                types: [],
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/")],
                quotes: ["\""])
        case .css:
            return CodeSyntax(
                keywords: [],
                types: [],
                lineComments: ["//"],
                blockComments: [.init(open: "/*", close: "*/")],
                quotes: ["\"", "'"])
        case .sql:
            return CodeSyntax(
                keywords: ["select", "from", "where", "insert", "into", "values", "update", "set",
                           "delete", "create", "table", "drop", "alter", "index", "join", "left",
                           "inner", "outer", "group", "by", "order", "having", "limit", "offset",
                           "as", "and", "or", "not", "null", "primary", "key", "foreign",
                           "references", "default", "unique", "if", "exists", "pragma"],
                types: ["int", "integer", "text", "real", "blob", "varchar", "datetime", "boolean"],
                lineComments: ["--"],
                blockComments: [.init(open: "/*", close: "*/")],
                quotes: ["\"", "'"])
        case .config:
            return CodeSyntax(
                keywords: ["true", "false", "null", "yes", "no", "on", "off"],
                types: [],
                lineComments: ["#", ";"],
                blockComments: [],
                quotes: ["\"", "'"])
        case .plain:
            return CodeSyntax(keywords: [], types: [],
                              lineComments: [], blockComments: [], quotes: [])
        }
    }
}

// MARK: - 读盘

/// 打不开的原因（每一档都要有**出路**，见 `CodePane.failureView`）。
/// ☠️ 必须显式写 `Error`：它要当 `Result<LoadedCode, CodeLoadFailure>` 的 `Failure`
///    —— 只写 `Sendable, Equatable` 的话 `Result` 那行编译不过
///    （`type 'CodeLoadFailure' does not conform to protocol 'Error'`）。
enum CodeLoadFailure: Error, Sendable, Equatable {
    /// 太大（字节数）
    case tooLarge(Int)
    /// 解不出文本（二进制 / 编码不认识）
    case notText
    case readFailed(String)

    var message: String {
        switch self {
        case .tooLarge(let bytes):
            return String(format: L("这个文件太大（%@），没有以文本方式打开。"), CodeLoader.sizeText(bytes))
        case .notText:
            return L("这个文件不是纯文本，打不开。")
        case .readFailed(let reason):
            return String(format: L("读不出这个文件：%@"), reason)
        }
    }
}

/// 一次加载的产物。⚠️ `Sendable`：在全局执行器上造出来、再跨回主 actor。
struct LoadedCode: Sendable {
    /// 已归一化：`\r\n` → `\n`、TAB → 4 空格。
    /// ☠️ **TAB 必须在这里展开**：`CodeSpan` 记的是字符偏移，而 TAB 展开会改变偏移量
    ///    ⇒ 必须「先展开、再扫描」，两者用的是同一份文本。⛔ 别在组装时再展开一次。
    let text: String
    let spans: [CodeSpan]
    let highlighted: Bool
    let truncated: Bool
    let lineCount: Int
}

enum CodeLoader {

    /// 读 + 解码 + 扫描，**全部在全局执行器上**（`nonisolated async`，见文件头 ②）。
    nonisolated static func load(url: URL, language: CodeLanguage) async -> Result<LoadedCode, CodeLoadFailure> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(.readFailed(error.localizedDescription))
        }
        if data.count > MacTheme.codeReadMaxBytes { return .failure(.tooLarge(data.count)) }

        // ☠️ 二进制探测必须**排在解码之前**：GB18030 那种编码对**任何字节**都有解
        //    （实测：一张 PNG 的头也能「解出」一串汉字），靠「解不出来」判二进制是判不出来的。
        if looksBinary(data) { return .failure(.notText) }
        guard var text = decode(data) else { return .failure(.notText) }

        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")

        var truncated = false
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > MacTheme.codeMaxLines {
            // ⚠️ 必须包一层 `Array(...)`：`prefix` 返回的是 `ArraySlice<Substring>`，
            //    直接赋回 `[Substring]` 编译不过（`no 'prefix' candidates produce …`）。
            lines = Array(lines.prefix(MacTheme.codeMaxLines))
            text = lines.joined(separator: "\n")
            truncated = true
        }

        let highlighted = data.count <= MacTheme.codeHighlightMaxBytes
        let spans = highlighted ? CodeHighlighter.scan(text, language: language) : []
        return .success(LoadedCode(text: text,
                                   spans: spans,
                                   highlighted: highlighted,
                                   truncated: truncated,
                                   lineCount: lines.count))
    }

    /// 采样看前 64KB 有没有 NUL。
    /// ⚠️ 只看 NUL 不看「控制字符比例」的话，某些二进制（没有 NUL）会漏过去 ⇒
    ///    解码后的 `hasTooManyControlChars` 是第二道闸。
    nonisolated static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(64 * 1024)
        return sample.contains(0x00)
    }

    /// 解码。顺序：BOM → UTF-8 → GB18030 → Big5 → Shift-JIS。
    ///
    /// ☠️ **中文老代码的高频坑**：很多年前的 `.m` / `.h` 是 **GB18030 / GBK** 存的
    ///    （注释里有中文），纯 UTF-8 解会直接失败。
    ///    ⚠️ `String.Encoding` **没有** `.gb18030` 这个成员，只能拿它对应的
    ///    `NSStringEncoding` 现造 —— `0x8000_0632` 就是
    ///    `kCFStringEncodingGB_18030_2000` 换算过来的值（已用一段 GB18030 中文实测确认）。
    ///    ☠️ **Big5 同理也没有成员**（`.big5` 不存在，`.shiftJIS` 才存在）：
    ///    `0x8000_0A03` = `kCFStringEncodingBig5`（已用 `A4A4 A4E5 → 中文` 实测确认，
    ///    见 `/tmp/enccheck/main.swift`）。
    /// ⛔ **不用 `isoLatin1` 兜底**：它对任何字节都「成功」，得到的是一屏乱码 ——
    ///    那种「看着像打开了、其实全是垃圾」比明确说「不是纯文本」更糟。
    nonisolated static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian) }
        if let s = String(data: data, encoding: .utf8), !hasTooManyControlChars(s) { return s }
        let gb18030 = String.Encoding(rawValue: 0x8000_0632)
        if let s = String(data: data, encoding: gb18030), !hasTooManyControlChars(s) { return s }
        let big5 = String.Encoding(rawValue: 0x8000_0A03)
        if let s = String(data: data, encoding: big5), !hasTooManyControlChars(s) { return s }
        if let s = String(data: data, encoding: .shiftJIS), !hasTooManyControlChars(s) { return s }
        return nil
    }

    /// 控制字符占比过高 ⇒ 当作二进制（第二道闸，见 `looksBinary`）。
    nonisolated static func hasTooManyControlChars(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let sample = text.prefix(8192)
        var bad = 0
        for scalar in sample.unicodeScalars {
            let v = scalar.value
            if v == 0x09 || v == 0x0A || v == 0x0D { continue }
            if v < 0x20 || v == 0x7F { bad += 1 }
        }
        return Double(bad) / Double(sample.unicodeScalars.count) > 0.02
    }

    nonisolated static func sizeText(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

// MARK: - 组装（代码 + 行号 → 一个 `AttributedString`）

enum CodeAssembler {

    /// 把「代码文本 + 高亮区间」拼成**一块** `AttributedString`，行号内嵌在每行开头。
    ///
    /// ⚠️ 前提：`text` **已经展开 TAB**（见 `LoadedCode.text`）。
    /// ⚠️ 行号宽度按**最大行号**定，右边补两个空格 —— 定宽才能让所有行的代码左缘对齐。
    nonisolated static func make(text: String,
                                 spans: [CodeSpan],
                                 highlighted: Bool,
                                 scheme: ColorScheme) -> AttributedString {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let digits = max(2, String(max(lines.count, 1)).count)
        var out = AttributedString()
        var codeOffset = 0
        var spanCursor = 0

        for (index, lineSub) in lines.enumerated() {
            // 行号（内嵌）
            var gutter = AttributedString(String(format: "%\(digits)d  ", index + 1))
            gutter.foregroundColor = MacTheme.codeLineNumber
            out.append(gutter)

            let line = String(lineSub)
            var run = AttributedString(line)
            if highlighted {
                let lineStart = codeOffset
                let lineEnd = codeOffset + line.count
                // 游标只往前走：`spans` 是有序的 ⇒ 整体还是 O(总长)，不是 O(行数 × 区间数)
                while spanCursor < spans.count, spans[spanCursor].end <= lineStart { spanCursor += 1 }
                var k = spanCursor
                while k < spans.count, spans[k].start < lineEnd {
                    let span = spans[k]
                    let from = max(span.start, lineStart) - lineStart
                    let to = min(span.end, lineEnd) - lineStart
                    if to > from, let range = characterRange(of: run, from: from, to: to) {
                        run[range].foregroundColor = Self.color(for: span.kind, scheme: scheme)
                    }
                    k += 1
                }
            }
            out.append(run)

            codeOffset += line.count
            if index < lines.count - 1 {
                out.append(AttributedString("\n"))
                codeOffset += 1
            }
        }
        return out
    }

    /// 记号种类 → 颜色。**色的值**在 `MacTheme`（颜色只有那一处来源），
    /// 这里只做「哪一类用哪一支」的翻译 —— ⛔ 别把色值搬进来。
    nonisolated static func color(for kind: CodeTokenKind, scheme: ColorScheme) -> Color {
        switch kind {
        case .keyword:      return MacTheme.codeKeyword(scheme)
        case .type:         return MacTheme.codeType(scheme)
        case .string:       return MacTheme.codeString(scheme)
        case .comment:      return MacTheme.codeComment(scheme)
        case .number:       return MacTheme.codeNumber(scheme)
        case .preprocessor: return MacTheme.codePreprocessor(scheme)
        }
    }

    private nonisolated static func characterRange(of text: AttributedString,
                                                  from: Int,
                                                  to: Int) -> Range<AttributedString.Index>? {
        let chars = text.characters
        guard let start = chars.index(chars.startIndex, offsetBy: from, limitedBy: chars.endIndex),
              let end = chars.index(chars.startIndex, offsetBy: to, limitedBy: chars.endIndex) else {
            return nil
        }
        return start..<end
    }
}

// MARK: - 模型

/// 一个代码标签的文档状态。
final class CodeDocumentModel: ObservableObject {

    enum State {
        case loading
        case ready(LoadedCode)
        case failed(CodeLoadFailure)
    }

    let url: URL
    let displayName: String

    @Published private(set) var state: State = .loading

    /// 组装结果按 `ColorScheme` 缓存：**同一个文件同一种外观只组装一次**。
    /// 🔴 为什么要缓存：组装是 O(总长) 的活，而它在 `body` 里被读 ——
    ///    不缓存就等于「每次重算 body 都重新拼一遍全文」（本工程铁律：body 期别干重活）。
    private var assembled: (scheme: ColorScheme, value: AttributedString)?

    private var didStart = false

    init(url: URL, displayName: String) {
        self.url = url
        self.displayName = displayName
    }

    /// 取（或现造）该外观下的组装结果。
    func attributed(for scheme: ColorScheme) -> AttributedString? {
        guard case .ready(let loaded) = state else { return nil }
        if let cached = assembled, cached.scheme == scheme { return cached.value }
        let built = CodeAssembler.make(text: loaded.text,
                                       spans: loaded.spans,
                                       highlighted: loaded.highlighted,
                                       scheme: scheme)
        assembled = (scheme, built)
        return built
    }

    /// 第一次读盘（视图 `.onAppear` 调）。
    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        let url = self.url
        let language = CodeLanguage.forFile(url) ?? .plain
        Task {
            let result = await CodeLoader.load(url: url, language: language)
            switch result {
            case .success(let loaded): state = .ready(loaded)
            case .failure(let failure): state = .failed(failure)
            }
        }
    }

    /// 🔴 **验收入口**：从一段文本**同步**造出「已就绪」的文档。
    ///
    /// 与 `FolderTreeModel.seeded` 同一条理由：离屏渲染里**异步副作用一概不跑**
    /// （`.task` / `Task {}` 都不跑，见 `VERIFY-PROBES` 那条「离屏渲染照不到任何异步结果」）
    /// ⇒ 不给这个同步入口，代码那几张档位图**永远是空的**。
    /// ⚠️ 只在渲染台 / 探针里用，生产路径永远走 `init(url:)` + `startIfNeeded()`。
    static func readyForRendering(text: String, displayName: String, language: CodeLanguage) -> CodeDocumentModel {
        let normalized = text.replacingOccurrences(of: "\t", with: "    ")
        let model = CodeDocumentModel(url: URL(fileURLWithPath: "/tmp/\(displayName)"),
                                      displayName: displayName)
        model.didStart = true
        let spans = CodeHighlighter.scan(normalized, language: language)
        model.state = .ready(LoadedCode(text: normalized,
                                        spans: spans,
                                        highlighted: true,
                                        truncated: false,
                                        lineCount: normalized.split(separator: "\n",
                                                                      omittingEmptySubsequences: false).count))
        return model
    }

    /// 🔴 **验收入口（失败档）**：同步造出「打不开」那个画面（`failureView`）。
    ///
    /// 理由同上：失败态在生产里只有「读完盘才知道」这一条路（异步）⇒ 离屏渲不出来。
    /// 而这一档**必须**看得见：「每一档都要有出路」是这一功能的验收口径之一
    /// （`CodePane.failureView` 那颗「用系统预览打开」掉了，用户就只剩一页死字）。
    static func failedForRendering(_ failure: CodeLoadFailure, displayName: String) -> CodeDocumentModel {
        let model = CodeDocumentModel(url: URL(fileURLWithPath: "/tmp/\(displayName)"),
                                      displayName: displayName)
        model.didStart = true
        model.state = .failed(failure)
        return model
    }
}

// MARK: - 视图

/// 面板里的代码视图（第四档内容）。**纯 SwiftUI** ⇒ 离屏渲染照得到。
struct CodePane: View {

    @ObservedObject var doc: CodeDocumentModel

    /// 打不开文本时的**出路**：把当前标签换成「系统预览」那一档
    /// （落点 `WebPageModel.switchActiveTabToPreview()`）。用户至少要能看到点东西。
    let onFallbackToPreview: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            switch doc.state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
            case .ready(let loaded):
                if let attributed = doc.attributed(for: scheme) {
                    codeScroll(attributed, loaded: loaded)
                }
            case .failed(let failure):
                failureView(failure)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacTheme.pageBackground)
        .onAppear { doc.startIfNeeded() }
    }

    /// ⚠️ **只读**：不做编辑、不保存（用户没要，且那要引入 undo / 编码回写 / 行尾一整套）。
    private func codeScroll(_ attributed: AttributedString, loaded: LoadedCode) -> some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                Text(attributed)
                    .font(.system(size: MacTheme.codeFontSize, design: .monospaced))
                    .lineSpacing(MacTheme.codeLineSpacing)
                    .textSelection(.enabled)
                    // ☠️ **不许折行**：折行会让「行号与内容」错位（一行代码占两行，行号却只标了一行）。
                    //    靠横向滚动看长行 —— 与用户给的图同口径。
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(MacTheme.codePadding)

                if loaded.truncated || !loaded.highlighted {
                    Text(noteText(loaded))
                        .font(MacTheme.ui(MacTheme.codeNoteFontSize))
                        .foregroundStyle(MacTheme.meta)
                        .padding(.horizontal, MacTheme.codePadding)
                        .padding(.bottom, MacTheme.codePadding)
                }
            }
        }
    }

    private func noteText(_ loaded: LoadedCode) -> String {
        var parts: [String] = []
        if loaded.truncated { parts.append(String(format: L("文件太长，只显示前 %d 行"), loaded.lineCount)) }
        if !loaded.highlighted { parts.append(L("文件较大，未做语法高亮")) }
        return parts.joined(separator: " · ")
    }

    private func failureView(_ failure: CodeLoadFailure) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.questionmark")
                .font(MacTheme.ui(MacTheme.webPageErrorIconSize))
                .foregroundStyle(MacTheme.webPageToolbarIcon)
            Text(failure.message)
                .font(MacTheme.ui(MacTheme.webPageErrorFontSize))
                .foregroundStyle(MacTheme.bodyColor)
                .multilineTextAlignment(.center)
            Button(action: onFallbackToPreview) {
                Text(L("用系统预览打开"))
                    .font(MacTheme.ui(MacTheme.webPageErrorButtonFontSize))
                    .foregroundStyle(MacTheme.bodyColor)
                    .padding(.horizontal, MacTheme.webPageErrorButtonPaddingH)
                    .padding(.vertical, MacTheme.webPageErrorButtonPaddingV)
                    .background(
                        RoundedRectangle(cornerRadius: MacTheme.webPageErrorButtonRadius)
                            .fill(MacTheme.webPageErrorButtonBackground(scheme))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("交给系统的 QuickLook 预览（它认更多格式）"))
        }
        .padding(MacTheme.webPageErrorPadding)
        .frame(maxWidth: MacTheme.webPageErrorMaxWidth)
    }
}
