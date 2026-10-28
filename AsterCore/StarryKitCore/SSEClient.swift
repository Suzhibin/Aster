//
//  SSEClient.swift
//  BaseModule
//
//  Created by Suzhibin on 2026/8/27.
//
//  SSE（Server-Sent Events）流式客户端。
//  职责单一：只负责"流式消费 + SSE 解析"，不绑定 Moya。
//  请求由调用方构造好 URLRequest 传入（用 Moya 的场景：
//    let request = try provider.endpoint(target).urlRequest()
//  注意该方式不经过 Moya 的 plugin 链，鉴权 token 请写在 TargetType.headers）。
//  底层用 Alamofire 的 DataStreamRequest 流式读取，兼容 iOS 14，不依赖 Swift.Task / async。

import Foundation
import Alamofire

// MARK: - SSE 事件模型
public struct SSEEvent {
    public let id: String?
    public let event: String?
    public let data: String
    public let retry: Int?

    public init(id: String?, event: String?, data: String, retry: Int?) {
        self.id = id
        self.event = event
        self.data = data
        self.retry = retry
    }
}

// MARK: - SSE 解析器
/// 按行喂入文本，遇到空行（事件分隔符）输出一个完整事件。
/// 支持 data: / event: / id: / retry: 字段；多行 data 以 \n 拼接。
/// 注意：解析器有跨分片状态（未完结的行/事件会暂存），一条连接必须独享一个实例。
public final class SSEParser {
    private var pendingLines: [String] = []

    /// 行首行尾要裁掉的字符。
    ///
    /// **必须包含 `\r`**：SSE 规范允许行尾是 `\r\n`，不少网关/代理会这么发。
    /// 只裁 `.whitespaces`（不含 `\r`）的后果是**整条流一个字都解析不出来**——
    /// 分隔空行那个 `\r` 不是空串，于是永远等不到事件终止符，所有行都堆在 `pendingLines` 里。
    private static let lineTrimSet = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\r"))

    /// 上一分片末尾那段「还没等到 \n」的半截行。
    ///
    /// 必须留着，否则下一分片里它的后半段没有 `data:` 前缀，在 build 阶段会被整行忽略，
    /// 那条 delta 就被静默吞掉。mock 每帧都是完整事件所以看不出来，真实网络下
    /// TCP 分片边界任意，会随机丢字。
    private var trailingPartialLine = ""

    public init() {}

    /// 喂入一行原始文本。遇到分隔空行时返回一个事件，否则返回 nil。
    public func feed(_ line: String) -> SSEEvent? {
        let trimmed = line.trimmingCharacters(in: Self.lineTrimSet)
        if trimmed.isEmpty {
            guard !pendingLines.isEmpty else { return nil }
            let event = Self.build(from: pendingLines)
            pendingLines.removeAll()
            return event
        }
        pendingLines.append(line)
        return nil
    }

    /// 直接喂入一段文本（可包含多个事件、也可为半截事件），返回本次解析出的完整事件。
    public func parse(_ text: String) -> [SSEEvent] {
        // 先接上上次残留的半截行，再按 \n 切
        let combined = trailingPartialLine + text
        var segments = combined.components(separatedBy: "\n")
        // 最后一段（可能在下一个分片里才结束）留到下次；以 \n 收尾时它就是空串
        trailingPartialLine = segments.removeLast()

        var events: [SSEEvent] = []
        for line in segments {
            if let event = feed(line) { events.append(event) }
        }
        return events
    }

    /// 流结束时调用：把「已经收全、只差末尾那个空行」的最后一个事件吐出来。
    ///
    /// 服务端正常都会在每个事件后补一个空行，但**最后一个事件可能不带**就直接断开
    /// （`Response.completed` / `response.failed` 这类收尾事件尤其容易这样）。
    /// 不 flush 的话，`handleComplete` 会把它当成「流正常结束但什么也没说」，
    /// 用户看到的就是一句兜底的「模型没有返回内容」，而不是服务端真正的原因。
    ///
    /// 安全性：`pendingLines` 里只会是**已经收到 `\n` 的完整行**（半截行在
    /// `trailingPartialLine` 里），所以这里不会把没收全的事件提前吐出来。
    /// - Returns: 残留的最后一个事件；没有则返回 nil
    @discardableResult
    public func flush() -> SSEEvent? {
        guard !pendingLines.isEmpty else { return nil }
        let event = Self.build(from: pendingLines)
        pendingLines.removeAll()
        trailingPartialLine = ""
        return event
    }

    public func reset() {
        pendingLines.removeAll()
        trailingPartialLine = ""
    }

    private static func build(from lines: [String]) -> SSEEvent? {
        var id: String?
        var event: String?
        var retry: Int?
        var dataParts: [String] = []

        for raw in lines {
            let line = raw.trimmingCharacters(in: lineTrimSet)
            if line.hasPrefix("data:") {
                dataParts.append(String(line.dropFirst(5)).trimmingCharacters(in: lineTrimSet))
            } else if line.hasPrefix("event:") {
                event = String(line.dropFirst(6)).trimmingCharacters(in: lineTrimSet)
            } else if line.hasPrefix("id:") {
                id = String(line.dropFirst(3)).trimmingCharacters(in: lineTrimSet)
            } else if line.hasPrefix("retry:") {
                let v = String(line.dropFirst(6)).trimmingCharacters(in: lineTrimSet)
                retry = Int(v)
            }
        }
        guard !dataParts.isEmpty else { return nil }
        return SSEEvent(id: id, event: event, data: dataParts.joined(separator: "\n"), retry: retry)
    }
}

// MARK: - 错误

/// 服务端返回了非 2xx。
/// SSE 场景下必须单独判：错误体是普通 JSON（不是 `data:` 帧），
/// 不判的话会被当成「流正常结束但一个字都没收到」，表现为静默无响应。
///
/// ☠️ `body` 必须带上（2026-10-17 真事故）：只报 statusCode 的话，调用方只能按码猜，
///    而**同一个码在不同服务端语义完全不同** —— 方舟的 404 body 是
///    `{"error":{"code":"InvalidEndpointOrModel.NotFound", ...}}`（模型名不对 /
///    没开通），App 却显示「接口地址不存在，地址要填到完整路径」，把用户引去
///    改一个**本来就对的地址**（豆包那条的地址由代码强制预设，压根没有填写入口）。
///    上午刚为画图链路修过同型文案，聊天侧这一层一直没修 —— 用户 Mac 端实测踩中。
public struct SSEHTTPStatusError: LocalizedError {
    public let statusCode: Int
    /// 非 2xx 的响应体（可能为 nil：服务端没给体 / 没收全）。通常是
    /// OpenAI 兼容形状 `{"error":{"code":…,"message":…}}`。
    public let body: Data?

    public init(statusCode: Int, body: Data? = nil) {
        self.statusCode = statusCode
        self.body = body
    }

    public var errorDescription: String? { "服务返回 HTTP \(statusCode)" }

    /// 错误体里的 `error.code`（OpenAI 兼容形状；方舟 = `InvalidEndpointOrModel.NotFound` 等）。
    /// 解不出来返回 nil。
    public var serverErrorCode: String? {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let code = error["code"] as? String else { return nil }
        return code
    }

    /// 错误体里的 `error.message`（服务端的原话，含它认定的问题对象）。
    public var serverMessage: String? {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return message
    }
}

/// `.stream` 原始字节的暂存器：**非 2xx 的错误体也会走 `.stream` 事件**。
///
/// Alamofire 的 `DataStreamRequest` 对 statusCode 不做任何拦截
/// （`didReceiveResponse` 没有 handler 时直接 `.allow`），错误体 JSON 会先于
/// `.complete` 一段段流过来 —— 它不是 SSE 帧，`SSEParser` 解析不出事件，
/// 不在这里接住就整段丢掉（表现为「只看到 HTTP 码，看不到服务端说了什么」）。
///
/// ⚠️ 有上限（错误体都很小）：SSE 成功响应可能是几 MB 的流，全程累积没有意义。
/// ⚠️ 只在 `parseQueue`（串行）上被读写，不需要额外加锁。
final class SSEErrorBodyBuffer {
    /// 上限 8KB —— 见过的错误体都 < 1KB；超了说明不是错误体，截断即可
    static let limit = 8 * 1024

    private(set) var data = Data()

    func append(_ chunk: Data) {
        guard data.count < Self.limit else { return }
        data.append(chunk.prefix(Self.limit - data.count))
    }
}

// MARK: - 跨分片 UTF-8 解码

/// 把字节流安全地转成字符串。
///
/// URLSession 的分片边界是任意的：一个汉字（3 字节）/ emoji（4 字节）很容易被劈成两半。
/// 直接 `String(data:encoding:.utf8)` 遇到半截字符会返回 **nil**，
/// 调用方一 `if let` 就把**整块**数据丢了——表现为随机缺字，而且很难复现。
/// 这里把「不完整的尾部」留到下一分片拼接。
final class UTF8StreamDecoder {

    /// 上一次未解码完的尾部字节
    private var carry = Data()

    func decode(_ data: Data) -> String {
        var buffer = carry
        buffer.append(data)
        carry = Data()

        // 从末尾往回最多退 3 个字节（UTF-8 单字符最长 4 字节），
        // 取「能完整解码的最长前缀」；退掉的那几字节就是被切断的字符，留到下一分片。
        //
        // 注意不能写成「退到某个长度能解就返回，退无可退时有损解码」——
        // 那样当整个 buffer 恰好只有一个字符的前 1~3 字节时会把它吃掉（1 字节分片的极端情况）。
        let maxBack = min(3, buffer.count)
        for back in 0...maxBack {
            let cut = buffer.count - back
            if cut == 0 {
                carry = buffer
                return ""
            }
            let prefix = buffer.prefix(cut)
            if String(data: prefix, encoding: .utf8) != nil {
                carry = buffer.suffix(back)
                return String(decoding: prefix, as: UTF8.self)
            }
        }

        // 整体都不是合法 UTF-8（正常不该走到）：有损兜底，不留残留以免状态卡死
        return String(decoding: buffer, as: UTF8.self)
    }
}

// MARK: - 连接句柄
public protocol SSEConnection: AnyObject {
    func cancel()
}

/// 包装单条 DataStreamRequest 的取消句柄。
private final class StreamConnection: SSEConnection {
    private weak var request: DataStreamRequest?

    init(request: DataStreamRequest) {
        self.request = request
    }

    func cancel() { request?.cancel() }
}

// MARK: - SSEClient
/// 非泛型、不绑定 Moya：请求由调用方构造，会话可注入（默认 Alamofire.Session.default）。
/// 若想复用 Moya 的会话配置，注入 provider.session（Alamofire.Session）即可。
public final class SSEClient {
    private let session: Alamofire.Session

    /// 解析所在的串行队列。
    ///
    /// `responseStream` 的回调队列默认是 **主队列**，若把 UTF-8 解码、SSE 分行、
    /// JSON 解析全留在主线程，就会和 UI 抢时间：流一快，主线程来不及逐帧消费，
    /// 攒下的分片会成批上屏。放到专用串行队列后主线程只做「上屏」这一件事。
    private static let parseQueue = DispatchQueue(label: "com.starrykit.sse.parse")

    /// - Parameters:
    ///   - session: Alamofire 会话。默认 `.default`；复用 Moya 会话时传 `provider.session`。
    public init(session: Alamofire.Session = .default) {
        self.session = session
    }

    /// 判断错误是否由主动 cancel 引起（不算真正的失败）。
    /// 注意：Alamofire 5.12 中 `sessionTaskFailed` 的关联值是 `any Error`（存在类型），
    /// 不能直接当 URLError 用，需先 cast 再判断 code。
    private static func isCancellation(_ error: AFError) -> Bool {
        switch error {
        case .explicitlyCancelled:
            // 取消发生在请求启动前的路径
            return true
        case .sessionTaskFailed(let underlying):
            // 运行中取消：底层是 URLError.cancelled（-999）
            return (underlying as? URLError)?.code == .cancelled
        default:
            return false
        }
    }

    /// 把 Alamofire 的包装错误还原成底层 `URLError`。
    ///
    /// 流的网络失败基本都是 `AFError.sessionTaskFailed(underlying:)`。直接把 AFError 抛给上层，
    /// 调用方就拿不到 `.notConnectedToInternet` / `.timedOut` 这类可判别的网络错误码，
    /// 也就没法给出「检查网络」这种具体文案（只能兜底一句英文的 localizedDescription）。
    private static func normalized(_ error: Error) -> Error {
        guard let afError = error as? AFError,
              case .sessionTaskFailed(let underlying) = afError,
              let urlError = underlying as? URLError else { return error }
        return urlError
    }

    /// 流式读取。回调在后台线程执行，如需刷新 UI 请在 onEvent 内切回主线程。
    /// - Parameters:
    ///   - request: 调用方构造好的请求（SSE 通常需 Accept: text/event-stream）
    ///   - onEvent: 每解析出一个完整 SSE 事件回调一次
    ///   - onError: 出错时回调（主动 cancel 不算错误）
    ///   - onComplete: 流结束（无论成功/失败/取消）后回调
    /// - Returns: 连接句柄，调 cancel() 取消本次流
    @discardableResult
    public func connectWithStream(
        _ request: URLRequest,
        onEvent: @escaping (SSEEvent) -> Void,
        onError: @escaping (Error) -> Void,
        onComplete: (() -> Void)? = nil
    ) -> SSEConnection {
        let req = session.streamRequest(request)
        // 一条连接独享一套跨分片状态：SSE 事件可能跨多个网络分片，必须保留未完结的半截内容；
        // 同理，被劈开的 UTF-8 字符也要留着等下一分片补齐
        let parser = SSEParser()
        let decoder = UTF8StreamDecoder()
        // 非 2xx 的错误体暂存（见 `SSEErrorBodyBuffer`）：它经 .stream 事件流过来，
        // 但不是 SSE 帧，parser 那儿会被静默丢掉 —— 在这里接住，complete 时随错误带上
        let errorBody = SSEErrorBodyBuffer()

        // 解析挂在专用串行队列（见 parseQueue），onEvent 因此**不在主线程**——
        // 调用方要在回调里碰 UI 的话，自己切回主线程。
        req.responseStream(on: Self.parseQueue) { stream in
            switch stream.event {
            case .stream(let result):
                switch result {
                case .success(let data):
                    errorBody.append(data)
                    let text = decoder.decode(data)
                    guard !text.isEmpty else { return }
                    parser.parse(text).forEach { onEvent($0) }
                case .failure(let error):
                    onError(Self.normalized(error))
                }
            case .complete(let completion):
                if let err = completion.error, !Self.isCancellation(err) {
                    onError(Self.normalized(err))
                } else if let code = completion.response?.statusCode, !(200..<300).contains(code) {
                    // 非 2xx（401 Key 无效 / 402 余额不足 / 429 限流…）：
                    // 错误体不是 SSE，不会产生任何 onEvent，交给调用方报告。
                    // 🔴 body 必须带上（2026-10-17）：方舟 404 = 模型名不对，
                    //    只有 body 里的 error.code 分得清「模型问题」与「地址问题」。
                    onError(SSEHTTPStatusError(statusCode: code, body: errorBody.data))
                } else if let last = parser.flush() {
                    // 正常结束时补吐「已收全、只差末尾空行」的最后一个事件。
                    // 收尾事件（`[DONE]` / `response.completed` / `response.failed`）经常就是这样
                    // 直接断开、不带后面的空行，不补的话会被当成「流正常结束但什么也没说」。
                    // 注意只在正常路径 flush：错误体不是 SSE，吐出去只会是垃圾。
                    onEvent(last)
                }
                onComplete?()
            }
        }
        return StreamConnection(request: req)
    }
}
