//
//  AIWebPageViewController.swift
//  Aster
//
//  会话里点网址 → **push 进来的内置网页页**（2026-10-02 用户需求）。
//
//  > 「iOS端 会话返回 网页地址 显示蓝色，创建一个 web 页面，点击网页地址 push 进入 web 页面，
//  >   web 页面导航上左上时返回按钮，右上是分享，中间 title 是网址名称」
//
//  ## 形态：**push 一整页**，不是 mac 那种右侧面板
//  两端刻意不同口径：mac 窗口宽、会话页与网页**同屏并排**才有意义（那边是 `.inspector`）；
//  iOS 屏窄，并排只会两边都残废 ⇒ 推一整页、左上角返回。⛔ 别把 mac 的多标签 / 面板那套搬过来。
//
//  ## 导航栏三样（就是用户列的那三样）
//  - **左**：返回（`chevron.backward`）→ `popViewController`
//  - **右**：分享 → `UIActivityViewController`（分享**当前**地址，页面内跳转过也是新的那个）
//  - **中**：网页名称 → 页面标题优先，取不到退回**域名**（与 mac `displayTitle` 同一口径）
//
//  ## 🔴 为什么自己实现 `point(inside:)` 之外的麻烦事都在别处
//  链接「能不能点」不归本页管：那取决于会话页的 `BubbleTextView`（它在没进选择态时
//  默认对触摸完全透明）——见那边的 `linkURL(at:)` / `point(inside:)`。
//  本页只负责「给了 URL 就把网页打开给我们看」。
//
//  ## ⚠️ `target=_blank` 的循环打断器（从 mac 端搬过来的同一套）
//  `WKWebView` 对 `target=_blank` / `window.open` 的行为是**什么都不做**（iOS 上尤其明显：
//  点了没反应）。所以策略层把它 `.cancel` 掉、再自己在**当前 webView** 里 load。
//  ☠️ 但这件事有自我成环的风险：遇到「每次加载完都开一个 `_blank`」的页面，
//  「cancel + 自己 load」就是一个死循环（mac 那次实测 8 秒重启 9 次）。
//  所以带**两道闸门**（同一地址已在当前页 / 同一地址短时间内已被替它开过 N 次）。
//  📌 这两道闸门的判据与 mac `MainActorWebPagePolicy` **逐条同源**，改一处要一起改。
//

import UIKit
import WebKit
import SnapKit
import AICore

final class AIWebPageViewController: UIViewController {

    /// 进来时的地址（`webView.url` 在首帧之前是 nil，标题 / 分享都要有个兜底）
    private let initialURL: URL

    private let webView = WKWebView()
    /// 导航代理（`WKNavigationDelegate` 是 ObjC 协议 ⇒ 必须是独立 NSObject，见该类的说明）
    private let navigationProxy = AIWebPageNavigationDelegate()

    /// 加载指示器：`webView.isLoading` 变化时启停（KVO，见 `observeWebView()`）
    private let spinner = UIActivityIndicatorView(style: .medium)
    /// 失败提示（打不开时盖在 webView 上；成功加载那一刻收起）
    private let failureLabel = UILabel()

    /// 右侧分享项 —— iPad 的 `UIActivityViewController` 必须给锚点，否则崩溃
    private weak var shareItem: UIBarButtonItem?

    private var titleObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?

    init(url: URL) {
        initialURL = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupNavigationItems()
        setupSubviews()
        navigationProxy.host = self
        webView.navigationDelegate = navigationProxy
        observeWebView()
        applyTitle()
        webView.load(URLRequest(url: initialURL))
    }

    // MARK: - 导航栏

    /// 左上返回 / 右上分享 / 中间标题（三样就是用户列的那三样）
    private func setupNavigationItems() {
        let back = UIBarButtonItem(image: UIImage(systemName: "chevron.backward"),
                                   style: .plain,
                                   target: self,
                                   action: #selector(backTapped))
        back.tintColor = .label
        back.accessibilityLabel = L("返回")
        navigationItem.leftBarButtonItem = back
        // 自定义左按钮会把系统返回键顶掉（我们要的就是它）——顺带也会把「边缘右滑返回」关掉，
        // 所以 `viewDidAppear` 里再把那条手势的闸重新打开（见那里的说明）。
        navigationItem.hidesBackButton = true

        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"),
                                    style: .plain,
                                    target: self,
                                    action: #selector(shareTapped))
        share.tintColor = .label
        share.accessibilityLabel = L("分享")
        navigationItem.rightBarButtonItem = share
        shareItem = share
    }

    /// 自定义左按钮会连带关掉 `interactivePopGestureRecognizer`
    /// （iOS 7 起的行为）—— 用户按不到按钮时还能右滑返回，别丢这条。
    ///
    /// ⚠️ 放在 `viewDidAppear`：`viewDidLoad` 那会儿本页还没进栈，
    ///    `viewControllers.count > 1` 判不出来。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.delegate = self
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    @objc private func backTapped() {
        // 拿不到导航栈时（理论上不会，本页就是 push 进来的）兜底 dismiss，别让按钮点了没反应
        if let nav = navigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func shareTapped() {
        // 分享**当前**地址：页面内跳转过之后，用户想分享的是眼前这一页
        let url = webView.url ?? initialURL
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // iPad 必须给锚点，否则崩溃（与 `AIMenuViewController` 同一套做法）
        activity.popoverPresentationController?.barButtonItem = shareItem
        present(activity, animated: true)
    }

    // MARK: - 视图

    private func setupSubviews() {
        webView.allowsBackForwardNavigationGestures = false   // 见文件头：右滑保留给「返回会话页」
        view.addSubview(webView)

        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        view.addSubview(spinner)

        failureLabel.numberOfLines = 0
        failureLabel.textAlignment = .center
        failureLabel.font = AITypography.body
        failureLabel.textColor = .secondaryLabel
        failureLabel.isHidden = true
        view.addSubview(failureLabel)

        webView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        spinner.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        // 失败提示左右各留 32：窄屏上也能整段读到，不贴边
        failureLabel.snp.makeConstraints { make in
            make.centerY.equalToSuperview()
            make.leading.equalToSuperview().offset(32)
            make.trailing.equalToSuperview().offset(-32)
        }
    }

    // MARK: - 状态跟踪

    /// `isLoading` / `title` 都走 KVO —— 与 mac 端同一套（`WebTabModel.observe()`）。
    ///
    /// ⚠️ 回调是 nonisolated 的（KVO 不是 actor 感知的），所以要 `MainActor.assumeIsolated`：
    ///    本工程 App target 开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
    ///    直接在里面碰 `self` 会报隔离错。KVO 的通知线程就是**改属性那个线程**，
    ///    而 `WKWebView` 只在主线程改自己 ⇒ 这里确实在主线程上（`assumeIsolated` 成立）。
    private func observeWebView() {
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyTitle()
            }
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.applyLoadingState()
            }
        }
    }

    /// 导航栏标题：**网页标题优先，取不到退回域名**（与 mac `WebTabModel.displayTitle` 同口径）。
    private func applyTitle() {
        let pageTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !pageTitle.isEmpty {
            navigationItem.title = pageTitle
            return
        }
        navigationItem.title = (webView.url ?? initialURL).host ?? initialURL.absoluteString
    }

    /// 转圈与失败提示互斥：加载中只转圈，加载完两样都没有。
    private func applyLoadingState() {
        if webView.isLoading {
            spinner.startAnimating()
            failureLabel.isHidden = true
        } else {
            spinner.stopAnimating()
        }
    }

    // MARK: - 代理回调（由 `AIWebPageNavigationDelegate` 转发，都在主线程）

    func webPageDidStartLoad() {
        failureLabel.isHidden = true
        spinner.startAnimating()
    }

    func webPageDidFinishLoad() {
        spinner.stopAnimating()
        failureLabel.isHidden = true
        // 有些站点 `title` 是在 `didFinish` 之后才设的 ⇒ 收尾再刷一次（KVO 也会补，双保险）
        applyTitle()
    }

    func webPageDidFail(_ error: NSError) {
        spinner.stopAnimating()
        // 「被取消」不是失败：`target=_blank` 那支每次都会先 cancel 再 load（见文件头）
        if error.code == NSURLErrorCancelled { return }
        failureLabel.text = Self.describe(error)
        failureLabel.isHidden = false
    }

    /// 失败文案（给用户看的，不是给日志看的）
    static func describe(_ error: NSError) -> String {
        switch error.code {
        case NSURLErrorNotConnectedToInternet:
            return L("网络不可用，请检查网络后返回重试。")
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
            return L("打不开这个网址：找不到服务器。")
        case NSURLErrorTimedOut:
            return L("加载超时，可能是网络太慢或对方服务器没响应。")
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return L("这个网站只支持 http，被系统的安全策略拦住了。")
        default:
            return String(format: L("网页打不开（%@）"), error.localizedDescription)
        }
    }
}

// MARK: - 边缘右滑返回（自定义左按钮会把它关掉，这里重新放开）

extension AIWebPageViewController: UIGestureRecognizerDelegate {

    /// 只有「栈里还有上一页」才放行 —— 否则在根页右滑会把栈滑空（白屏）。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (navigationController?.viewControllers.count ?? 0) > 1
    }
}

// MARK: - WKWebView 的导航代理

/// `WKNavigationDelegate` 是 **ObjC 协议**（本工程要求 `nonisolated` 实现，`@preconcurrency` 无效）
/// ⇒ 单独一个 `NSObject` 装着，回调里再 `MainActor.assumeIsolated` 落回主线程。
/// 与 mac 端 `WebPageNavigationDelegate` 同一形态。
private final class AIWebPageNavigationDelegate: NSObject, WKNavigationDelegate {

    weak var host: AIWebPageViewController?

    nonisolated func webView(_ webView: WKWebView,
                            decidePolicyFor navigationAction: WKNavigationAction,
                            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated {
            decisionHandler(AIWebPagePolicy.decide(navigationAction, in: webView))
        }
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { host?.webPageDidStartLoad() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { host?.webPageDidFinishLoad() }
    }

    nonisolated func webView(_ webView: WKWebView,
                            didFailProvisionalNavigation navigation: WKNavigation!,
                            withError error: Error) {
        let nsError = error as NSError
        MainActor.assumeIsolated { host?.webPageDidFail(nsError) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        MainActor.assumeIsolated { host?.webPageDidFail(nsError) }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            host?.webPageDidFail(NSError(domain: "AsterWebPage", code: 0, userInfo: [
                NSLocalizedDescriptionKey: L("渲染进程被系统回收了"),
            ]))
        }
    }
}

// MARK: - 导航策略（带 `target=_blank` 的循环打断器）

/// 📌 与 mac 端 `MainActorWebPagePolicy` **同源**：判据逐条一样，只把
///    「非 http(s) 交给系统」那一支从 `NSWorkspace.open` 换成 `UIApplication.open`。
///    ⛔ 改这里记得两边一起改（那边有契约盯着，见 `render_mac_ui.sh` 的「循环打断器」一段）。
@MainActor
private enum AIWebPagePolicy {

    /// 循环判定的时间窗
    private static let loopWindow: TimeInterval = 3
    /// 同一地址在窗口内最多被「替它打开」几次
    private static let maxOpensPerURL = 2
    /// 每个地址最近几次「替它打开」的时间戳
    private static var openLog: [String: [Date]] = [:]

    static func decide(_ navigationAction: WKNavigationAction,
                       in webView: WKWebView) -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        let scheme = url.scheme?.lowercased() ?? ""

        // ① 非 http(s)（`mailto:` / `tel:` / 自定义 scheme）：交回系统，别在我们这页里开。
        if scheme != "http", scheme != "https" {
            if !scheme.isEmpty { UIApplication.shared.open(url) }
            return .cancel
        }

        // ② `target=_blank` / `window.open`：WKWebView 自己**什么都不做** ⇒
        //    先 `.cancel` 再自己 load（顺序要紧：不 cancel 会开出一块我们看不见的新 frame）。
        if navigationAction.targetFrame == nil {
            let target = url.absoluteString
            // 闸门 ①：已经在这一页了 ⇒ 不重启（这就是「网页不断重新加载」的第一道闸）
            if webView.url?.absoluteString == target { return .cancel }
            // 闸门 ②：同一地址短时间内被反复「替它打开」 ⇒ 判为循环，停手
            let now = Date()
            openLog = openLog.compactMapValues { stamps -> [Date]? in
                let fresh = stamps.filter { now.timeIntervalSince($0) < loopWindow }
                return fresh.isEmpty ? nil : fresh
            }
            let recent = openLog[target] ?? []
            guard recent.count < maxOpensPerURL else { return .cancel }
            openLog[target] = recent + [now]

            webView.load(navigationAction.request)
            return .cancel
        }

        return .allow
    }
}
