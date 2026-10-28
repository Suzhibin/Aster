//
//  PDFTraceProbe.swift
//  Aster
//
//  🧪 iOS「PDF 解析链路」验收探针（2026-10-23 加，`STARRY_PDF_PROBE=1` 才动）。
//
//  ## 为什么需要它
//  「文件 → 可注入文本」这条链 2026-10-23 起多了 PDF 一条支路：
//  `AIChatManager.fileContextText` → `AIAttachmentStorage.extractedText` → PDFKit 抽正文。
//  分流器（`extractedText`）本体由 **Mac 渲染台的 `PDFTEXT` 判据**覆盖（七种真 PDF），
//  但 iOS 侧在此前**只有编译证据** —— 而「附件发得过去、PDF 却解析不出」正是那种
//  **编译得过、界面上要等用户真发一次才被发现**的病。
//  ⇒ 本探针在 iOS 上把整条路跑一遍：造真 PDF → 走 `debugFileContextText`
//    （它就是 `fileContextText` 本体，只多一层转发）→ 把产物写进日志。
//
//  ## 判据（日志 `Documents/pdf_probe.log`，取回见 `sim_ios.sh`）
//  ① 中文两页 PDF ⇒ 块头是【附件 …】且两页文字都抽到了；
//  ② 同一份 PDF 换「项目资料」标签 ⇒ 块头跟着换（缓存键含标签，别拿错标题）；
//  ③ txt 回归 ⇒ 白名单老路没被分流器带坏；
//  ④ zip ⇒ 降级那句「当前无法解析其内容」还在（PDF 转正 ≠ 别的类型也转正）。
//
//  ## 与 Mac 侧探针的分工（⛔ 别互相替代）
//  - Mac `PDFTEXT`：验**分流器本体**（扫描件/双密码/仅权限密码/超长截断/zip 回归）；
//  - 本探针：验**iOS 上的调用点 + PDFKit 在该平台的抽取**（标签、缓存、降级文案）。
//  两边都不覆盖「importFile 拷进沙盒」那一步 —— 那是一条纯 `copyItem`，
//  由 Mac 渲染台的「落地区①/②/③」判据守着（见 `macrender/main.swift`）。
//
//  ⚠️ 只在 `#if DEBUG` 下编译进去（Release 包里这段代码根本不存在）；
//     `runIfRequested()` 内部还要 `STARRY_PDF_PROBE=1`，且**只跑一次**。
//

#if DEBUG
import UIKit
import AICore

enum PDFTraceProbe {

    /// 只跑一次：本探针是纯逻辑（不碰界面），但没有重复运行的必要。
    private static var didRun = false

    /// 日志文件名（与 `tts_trace.log` / `i18n_trace.log` 同一个目录口径）。
    private static let fileName = "pdf_probe.log"

    // MARK: - 入口

    /// App 侧启动钩子（`AIModuleViewController.viewDidAppear` 调）。
    static func runIfRequested() {
        guard !didRun else { return }
        guard ProcessInfo.processInfo.environment["STARRY_PDF_PROBE"] == "1" else { return }
        didRun = true

        reset()
        log("=== PDF-IOS 探针开始（STARRY_PDF_PROBE=1）===")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("starry-pdf-probe", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // ── 夹具：UIKit 的 PDF 上下文画真文字（落进去的是文本层，不是图片）──
        let textPDF = dir.appendingPathComponent("周报.pdf")
        let noteTXT = dir.appendingPathComponent("笔记.txt")
        let zipFile = dir.appendingPathComponent("压缩包.zip")
        makeTextPDF(at: textPDF, pages: ["第一页：项目周报。", "第二页：下周计划。"])
        try? "普通文本附件".data(using: .utf8)?.write(to: noteTXT)
        try? Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]).write(to: zipFile)

        // ── 判据 ──
        // ① 附件标签：块头 + 两页正文都要在
        //    ⚠️ 断言只查**片段**（"第一页"/"项目周报"），⛔ 别查整句带标点的原文：
        //    PDFKit 抽取时会按字符边界插空格（实测全角冒号后多一个「第一页： 项目周报。」），
        //    那是抽取器的启发式、不是产品契约 —— 拿它当判据会把探针逼成假红
        //    （Mac 侧 `PDFTEXT` 同口径，见那边的注释）。
        let asAttachment = AIChatManager.debugFileContextText(name: "周报.pdf", url: textPDF)
        let ok1 = asAttachment.hasPrefix("【附件 周报.pdf】")
            && asAttachment.contains("第一页") && asAttachment.contains("项目周报")
            && asAttachment.contains("第二页") && asAttachment.contains("下周计划")

        // ② 项目资料标签：同一份文件、只换标签 ⇒ 块头必须跟着换
        //    （缓存键含 label，拿错标题 = 模型把长期资料当成本次上传的）
        let asMention = AIChatManager.debugFileContextText(name: "周报.pdf", url: textPDF, label: "项目资料")
        let ok2 = asMention.hasPrefix("【项目资料 周报.pdf】")
            && asMention.contains("第一页") && asMention.contains("下周计划")
            && !asMention.contains("【附件")

        // ③ txt 回归：白名单老路没坏
        let asText = AIChatManager.debugFileContextText(name: "笔记.txt", url: noteTXT)
        let ok3 = asText.hasPrefix("【附件 笔记.txt】") && asText.contains("普通文本附件")

        // ④ zip 回归：PDF 转正了，zip 仍要走降级那句
        let asZip = AIChatManager.debugFileContextText(name: "压缩包.zip", url: zipFile)
        let ok4 = asZip.contains("当前无法解析其内容")

        let pass = ok1 && ok2 && ok3 && ok4
        log("PDF-IOS 判据① 附件标签+两页正文=\(ok1 ? "PASS" : "FAIL") 长度=\(asAttachment.count)")
        log("PDF-IOS 判据② 项目资料标签=\(ok2 ? "PASS" : "FAIL") 长度=\(asMention.count)")
        log("PDF-IOS 判据③ txt 回归=\(ok3 ? "PASS" : "FAIL")")
        log("PDF-IOS 判据④ zip 降级文案=\(ok4 ? "PASS" : "FAIL")")
        log("PDF-IOS RESULT: \(pass ? "PASS" : "FAIL")")
        log("=== PDF-IOS 探针结束 ===")

        // 失败时把产物打出来（判据红的那一趟，日志里要能直接读到差在哪）
        if !pass {
            log("PDF-IOS 产物①（附件标签）: \(asAttachment)")
            log("PDF-IOS 产物②（资料标签）: \(asMention)")
            log("PDF-IOS 产物③（txt）: \(asText)")
            log("PDF-IOS 产物④（zip）: \(asZip)")
        }
    }

    // MARK: - 夹具

    /// 画一个**有文本层**的 PDF（每页一段文字）。
    ///
    /// 走 UIKit 的 `UIGraphicsBeginPDFContextToFile`（iOS 上没有 AppKit 那套
    /// `NSGraphicsContext` 玩法）—— 上下文由 UIKit 自己管，字符串绘制直接落文本层。
    private static func makeTextPDF(at url: URL, pages: [String]) {
        let rect = CGRect(x: 0, y: 0, width: 595, height: 842)  // A4
        UIGraphicsBeginPDFContextToFile(url.path, rect, nil)
        for text in pages {
            UIGraphicsBeginPDFPageWithInfo(rect, nil)
            (text as NSString).draw(at: CGPoint(x: 40, y: 40),
                                    withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
        UIGraphicsEndPDFContext()
    }

    // MARK: - 落盘

    /// 每次运行先清空 —— 整份日志就是本轮，判据不用在历史里翻。
    private static func reset() {
        try? FileManager.default.removeItem(at: url)
    }

    /// iOS 上 `AIPlatformPaths.appDataDirectory` 就是 `Documents`（与 I18NTraceProbe 同口径）。
    private static var url: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent(fileName)
    }

    private static func log(_ line: String) {
        // ① 落盘（判据来源）
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
        // ② 顺带打一份到控制台（`simctl launch --console` 那趟能直接看到）
        NSLog("%@", "[PDFProbe] \(line)")
    }
}
#endif
