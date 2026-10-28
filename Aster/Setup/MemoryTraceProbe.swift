//
//  MemoryTraceProbe.swift
//  Aster
//
//  🧪 iOS「长期记忆」验收探针（2026-10-25 加，`STARRY_MEMORY_PROBE=1` 才动）。
//
//  ## 为什么需要它
//  记忆这条链上「编译得过、功能是坏的」的点不少：JSON 落盘路径不对、原子写失败被
//  吞、`digest()` 块格式漂移、开关关了还注入 / 开着不注入、删除不幂等……
//  契约段（`typecheck_aster.sh` ⑱–㉖）只证得了「代码在、字符串对」；**真容器里的
//  读写 round-trip** 只有本探针验。
//
//  ## 判据（日志 `Documents/memory_probe.log`，取回见 `sim_ios.sh`）
//  ① add 返回真条目且落盘（`memories.json` 真的出现在 Documents 里）；
//  ② 列表计数 +1、新条目排最前（与 `all()` 排序口径一致）；
//  ③ `digest()` 含块头 / 编号条目 / 【使用要求】三段（格式单点别漂）；
//  ④ delete 后计数还原、digest 回落（空库时回到空串）；
//  ⑤ 纯空白 add 返回 nil（⛔ 别存空串——列表幽灵）；
//  ⑥ 开关关 ⇒ digest 空串；开 ⇒ 回来（注入总闸真的在管注入）；
//  ⑦ **自动抽取 round-trip**（2026-10-25 反转为自动记忆后加）：注入预录响应 →
//     trigger ⇒ add 落库 + update 按**编号**改写（编号先解析成 id，⛔ 别被 add
//     挤位）+ 预录里的 delete op **不执行**；消息构建真的带了 system prompt /
//     编号清单 / 对话记录（走真实路径，只换掉「网络 + SSE」那一段）；
//  ⑧ **闸门**：抽取开关关着时 trigger 静默不落库（「默认关」的代价判据）。
//
//  ## ⚠️ ⑦⑧ 为什么整段跑在后台队列
//  抽取链内部会 `DispatchQueue.main.async` 落库（store 的写入 post 同步通知，
//  必须在主线程）⇒ 探针⛔ 不能在主线程信号量等，否则主队列被占着、
//  落库那步永远排不上 = **死锁**。所以：安装夹具（造存量条目）在主线程做，
//  trigger + 等 + 断言在后台做，清理与日志收尾回主线程。
//
//  ## ⚠️ 不碰用户数据
//  只 add/delete 自己造的「探针-」前缀条目；存量记忆原样留着（判据全部用
//  「基线 ±1」的相对量，不是绝对值）。两个开关与去抖间隔跑完复原。
//
//  ⚠️ 只在 `#if DEBUG` 下编译进去（Release 包里这段代码根本不存在）；
//    `runIfRequested()` 内部还要 `STARRY_MEMORY_PROBE=1`，且**只跑一次**。
//

#if DEBUG
import UIKit
import AICore

enum MemoryTraceProbe {

    /// 只跑一次：纯逻辑探针，没有重复运行的必要。
    private static var didRun = false

    /// 日志文件名（与 `pdf_probe.log` / `panel_probe.log` 同一个目录口径）。
    private static let fileName = "memory_probe.log"

    /// 探针自用条目的正文前缀（判据靠它认出自己的东西，不碰存量）。
    private static let probePrefix = "探针-"

    /// ⑦ 等落库的超时（秒）。正常路径 0.2s 去抖 + 本地落库 ⇒ 5s 是宽裕的上界。
    private static let extractWaitTimeout: TimeInterval = 5

    // MARK: - 入口

    /// App 侧启动钩子（`AIModuleViewController.viewDidAppear` 调，与 PDFTraceProbe 并排）。
    static func runIfRequested() {
        guard !didRun else { return }
        guard ProcessInfo.processInfo.environment["STARRY_MEMORY_PROBE"] == "1" else { return }
        didRun = true

        reset()
        log("=== Memory-IOS 探针开始（STARRY_MEMORY_PROBE=1）===")

        let baseline = AIMemoryStore.all().count
        let wasEnabled = AIMemoryStore.isEnabled
        let probeText = "\(probePrefix)iOS 端到端验证用（跑完自动删）"

        // ① add 返回真条目 + 真的落了盘
        let added = AIMemoryStore.add(content: probeText)
        let ok1 = added != nil
            && added?.content == probeText
            && FileManager.default.fileExists(atPath: AIMemoryStore.fileURL.path)

        // ② 计数 +1、新条目排最前
        let afterAdd = AIMemoryStore.all()
        let ok2 = afterAdd.count == baseline + 1 && afterAdd.first?.id == added?.id

        // ③ digest 三段齐（块头 / 编号条目 / 使用要求护栏）
        let digestOn = AIMemoryStore.digest()
        let ok3 = digestOn.hasPrefix("【长期记忆】")
            && digestOn.contains("1. \(probeText)")
            && digestOn.contains("【使用要求】")
            && digestOn.contains("不要主动向用户复述")

        // ④ delete 后还原
        if let id = added?.id { AIMemoryStore.delete(id: id) }
        let ok4 = AIMemoryStore.all().count == baseline
            && !(AIMemoryStore.digest().contains(probeText))

        // ⑤ 纯空白 add 返回 nil（三种空白形态：空串 / 全空格 / 换行制表）
        let ok5 = AIMemoryStore.add(content: "") == nil
            && AIMemoryStore.add(content: "   ") == nil
            && AIMemoryStore.add(content: "\n\t ") == nil

        // ⑥ 开关管的是注入（digest），不是写入
        AIMemoryStore.isEnabled = false
        let ok6 = AIMemoryStore.digest().isEmpty
        AIMemoryStore.isEnabled = wasEnabled   // 探针不许改用户的偏好

        log("Memory-IOS 判据① add+落盘=\(ok1 ? "PASS" : "FAIL")（文件在 \(AIMemoryStore.shortDisplayPath)）")
        log("Memory-IOS 判据② 计数+1且排最前=\(ok2 ? "PASS" : "FAIL")（基线 \(baseline) → \(afterAdd.count)）")
        log("Memory-IOS 判据③ digest 三段=\(ok3 ? "PASS" : "FAIL")（长度 \(digestOn.count)）")
        log("Memory-IOS 判据④ delete 还原=\(ok4 ? "PASS" : "FAIL")")
        log("Memory-IOS 判据⑤ 空白 add=nil=\(ok5 ? "PASS" : "FAIL")")
        log("Memory-IOS 判据⑥ 开关管注入=\(ok6 ? "PASS" : "FAIL")")

        // ⑦⑧ 异步链（抽取器内部要跳主线程落库）⇒ 整段搬后台，⛔ 别在主线程等
        //    （死锁陷阱见文件头）。夹具（造存量）在主线程先装好。
        let wasAuto = AIMemoryStore.isAutoExtractEnabled
        let savedDebounce = AIMemoryExtractor.debounceInterval
        // 待改写的存量：update 的「编号 1」就指它（add 插最前 ⇒ 它此刻排第 1）
        let stale = AIMemoryStore.add(content: "\(probePrefix)旧内容（应被 update 改写）")
        let idsBefore = Set(AIMemoryStore.all().map { $0.id })
        let countBefore = AIMemoryStore.all().count
        // 预录的模型输出：一个 add + 一个 update + 一个 **不许执行**的 delete
        let canned = """
        {"ops":[{"op":"add","content":"探针-抽取新增（跑完自动删）"},{"op":"update","index":1,"content":"探针-新内容（update 改写）"},{"op":"delete","index":2}]}
        """
        let sema = DispatchSemaphore(value: 0)
        var capturedTexts: [String] = []
        AIMemoryExtractor.debounceInterval = 0.2
        AIMemoryExtractor.debugDidApply = { sema.signal() }
        AIMemoryExtractor.debugTransportOverride = { texts in
            capturedTexts = texts
            return canned
        }
        AIMemoryStore.isAutoExtractEnabled = true

        DispatchQueue.global().async {
            AIMemoryExtractor.debugTrigger {
                [
                    AIMemoryExtractor.Turn(role: .user, text: "我的持仓成本是 19.25 元"),
                    AIMemoryExtractor.Turn(role: .assistant, text: "记下了：成本 19.25 元。"),
                ]
            }
            // 等落库（超时 = 没跑起来，判据红）
            let waited = sema.wait(timeout: .now() + extractWaitTimeout)

            let items = AIMemoryStore.all()
            // ⑦a add 落库
            let okAdd = items.contains { $0.content == "探针-抽取新增（跑完自动删）" }
            // ⑦b update 按编号改写（内容换了、id 没换 —— 编号先解析成 id 的判据）
            let okUpdate = stale.map { staleItem in
                items.contains { $0.id == staleItem.id && $0.content == "探针-新内容（update 改写）" }
            } ?? false
            // ⑦c 预录里的 delete 不许执行：原有 id 一个不少、总数只 +1
            let idsAfter = Set(items.map { $0.id })
            let okNoDelete = idsBefore.isSubset(of: idsAfter) && items.count == countBefore + 1
            // ⑦d 消息构建走真实路径：system prompt / 对话 / 编号清单都在
            let okMessages = waited == .success
                && capturedTexts.count == 2
                && capturedTexts[0].contains("长期记忆提取员")
                && capturedTexts[1].contains("我的持仓成本是 19.25 元")
                && capturedTexts[1].contains("探针-旧内容（应被 update 改写）")

            // ⑧ 闸门：开关关掉再触发 ⇒ 一次落库都不该有（信号量再响 = 判据红）
            AIMemoryStore.isAutoExtractEnabled = false
            AIMemoryExtractor.debugTrigger { [] }
            let gated = sema.wait(timeout: .now() + 1.5)
            let okGate = gated == .timedOut && AIMemoryStore.all().count == items.count

            DispatchQueue.main.async {
                // 清理 + 复原（⛔ 别把探针的开关/去抖设置留给用户；⛔ 别 clearAll——
                //    那会连用户自己的记忆一起删，只删「探针-」前缀的自己造的）
                for item in AIMemoryStore.all() where item.content.hasPrefix(probePrefix) {
                    AIMemoryStore.delete(id: item.id)
                }
                AIMemoryStore.reload()
                AIMemoryStore.isAutoExtractEnabled = wasAuto
                AIMemoryStore.isEnabled = wasEnabled
                AIMemoryExtractor.debounceInterval = savedDebounce
                AIMemoryExtractor.debugDidApply = nil
                AIMemoryExtractor.debugTransportOverride = nil

                log("Memory-IOS 判据⑦a add 落库=\(okAdd ? "PASS" : "FAIL")")
                log("Memory-IOS 判据⑦b update 按编号改写=\(okUpdate ? "PASS" : "FAIL")")
                log("Memory-IOS 判据⑦c delete op 不执行=\(okNoDelete ? "PASS" : "FAIL")（总数 \(countBefore) → \(items.count)）")
                log("Memory-IOS 判据⑦d 消息构建=\(okMessages ? "PASS" : "FAIL")（条数 \(capturedTexts.count)）")
                log("Memory-IOS 判据⑧ 关开关不落库=\(okGate ? "PASS" : "FAIL")")

                let pass = ok1 && ok2 && ok3 && ok4 && ok5 && ok6
                    && okAdd && okUpdate && okNoDelete && okMessages && okGate
                log("Memory-IOS RESULT: \(pass ? "PASS" : "FAIL")")
                log("=== Memory-IOS 探针结束 ===")

                // 失败时把 digest 与预录响应打出来（判据红的那一趟，日志里要能直接读到差在哪）
                if !pass {
                    log("Memory-IOS 产物 digest: \(digestOn)")
                    log("Memory-IOS 产物 messages: \(capturedTexts)")
                }
            }
        }
    }

    // MARK: - 落盘

    /// 每次运行先清空 —— 整份日志就是本轮，判据不用在历史里翻。
    private static func reset() {
        try? FileManager.default.removeItem(at: url)
    }

    /// iOS 上 `Documents` 就是 App 容器的那个（与 I18NTraceProbe / PDFTraceProbe 同口径）。
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
        NSLog("%@", "[MemoryProbe] \(line)")
    }
}
#endif
