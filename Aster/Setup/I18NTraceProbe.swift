//
//  I18NTraceProbe.swift
//  Aster
//
//  🧪 iOS「切语言」验收探针（2026-10-13 加，`STARRY_I18N_TRACE=1` 才动）。
//
//  ## 为什么需要它
//  用户原话（2026-10-13）：「iOS 端 也是同样，**菜单 开启AI 和 文档 没有及时切换语言**」。
//  这句话命中的是**侧滑抽屉第 0 组那两条固定入口**（`AIMenuViewController.quickItems`）。
//  ☠️ 它**不是**截图能一眼断的：抽屉要人手动滑出来，而 `simctl` **投不出合成手势**
//     （见 `sim_ios.sh` 文件头那几条「必须靠钩子」的说明）。
//  ⇒ 只能由 App 自己把整条路走一遍，并把状态写进日志。
//
//  ## 🔴 2026-10-14：语言入口搬进了**设置页**，这条链因此多一层
//      点左上角三横 → 抽屉 → 点左下角头像 → 账号弹窗 → 点「设置」→ **设置页**
//        → 点「语言」→ **三档页** → 点目标档
//  改造前是「账号弹窗 → 二级页 → 点档」（少一层）。探针随之多两次跳转，
//  时间轴整体往后挪（见下面每一拍的秒数，配 `STARRY_SIM_WAIT=13`）。
//
//  ## 为什么必须走「真实路径」
//  ⛔ 不许图省事直接写 `AILanguageStore.current = .en`：那条**不是**用户走的路。
//  用户那条路上有几个「非比寻常的中间态」，而 bug 恰恰可能藏在其中：
//  ① 写偏好的那一刻，**抽屉是开着的**（整个模态链是**从抽屉里**弹出来的，关掉它之后抽屉还在）；
//  ② 写偏好发生在**整条模态链的 `dismiss` 完成回调里**（`AIChoiceListViewController.select(_:)`），
//     也就是一次模态转场刚结束的当口；
//  ③ 中间**跨了三层转场**（设置页就地模态滑上来 → 设置页内 push → 点档），
//     任何一层的时序错位都可能让「重建界面」与「模态收场」打架。
//  ⇒ 本探针一律调真实入口：`menuButtonTapped()`（点左上角三横）
//     → `AIMenuViewController.debugPresentSettings()`（点抽屉右下角那颗**齿轮**，
//        本体是 `settingsTapped()`）
//     → `AISettingsViewController.debugOpenLanguagePage()`（点设置页那一行「语言」）
//     → `AIChoiceListViewController.debugSelectLanguage(_:)`（点三档页里那一档，**本体**）。
//
//  ⚠️ 2026-10-27 链条**少了一层**：原来自「头像 + 名称 + `>`」点开的账号弹窗
//     （先关自己、再 present 设置页）随用户要求一起删了 ⇒ 现在齿轮直接开设置。
//     少一层转场意味着这条探针**验的东西变少了**，别当成「反正还绿」——
//     `④ 切后` 那三条判据（固定项换字 / 已接线 / 会话页实例变）一条都没松。
//
//  ## 判据（日志 `Documents/i18n_trace.log`，取回见 `sim_ios.sh`）
//  `④ 切后` 那一行里三件事必须同时成立：
//  ① `注册菜单固定项` = **新语言**（这是用户报的那一条）；
//  ② `已接线=true` —— 抽屉被换成新实例之后必须**重新接线**，否则列表空、点两条入口没反应
//     （`setupMenu()` 的「复用已注册实例」与 `setupAIMenu()` 的「换新实例」谁先谁后决定这件事）；
//  ③ `会话页` 那个实例号要**变了**（证明重建真的发生），且 `屏上抽屉` 若还在也得是新实例。
//
//  ## 产物
//  `<App 容器>/Documents/i18n_trace.log`（**每次运行先清空**，整份就是本次那一轮）。取回：
//  ```sh
//  xcrun simctl get_app_container <udid> com.github.suzhibin.Aster data
//  ```
//  ⚠️ 目录口径与 `tts_trace.log` 相同（iOS 上就是 `Documents`）—— 这里**刻意不 import
//     `AIPlatform`**：App target 里没有一处 import 过它，为一个探针去动包可见性不划算。
//
//  ⚠️ 只在 `#if DEBUG` 下编译进去（Release 包里这段代码根本不存在）；
//     `runIfRequested(from:)` 内部还要 `STARRY_I18N_TRACE=1`，且**只跑一次**（重建会再触发 `viewDidAppear`）。
//

#if DEBUG
import UIKit
import SideMenu
import AICore

enum I18NTraceProbe {

    /// 只跑一次：本探针会把 root 整个换掉 ⇒ 新页的 `viewDidAppear` 会再进来一趟。
    private static var didRun = false

    /// 日志文件名（与 `tts_trace.log` 同一个目录口径）。
    private static let fileName = "i18n_trace.log"

    // MARK: - 入口

    /// App 侧启动钩子（`AIModuleViewController.viewDidAppear` 调）。
    ///
    /// - Parameter chat: 触发时的会话页 —— 只用它来走「点左上角三横」那条真实入口。
    static func runIfRequested(from chat: UIViewController) {
        guard ProcessInfo.processInfo.environment["STARRY_I18N_TRACE"] == "1" else { return }
        guard !didRun else { return }
        didRun = true

        reset()
        log("=== I18N-IOS 探针开始（STARRY_I18N_TRACE=1）===")
        log("I18N-IOS ⓪ 启动态 生效=\(AILanguageStore.resolved.rawValue)"
            + " 用户选档=\(AILanguageStore.current.rawValue)")

        // 目标档 = 与当下**相反**那一档（⛔ 别写死：模拟器 UD 里可能留着上一轮的值，
        // 写死就可能「切了个寂寞」—— 什么都没验到。与 Mac 侧那条探针同一口径。）
        let target: AILanguage = (AILanguageStore.resolved == .zhHans) ? .en : .zhHans
        log("I18N-IOS ⓪ 本轮目标档=\(target.rawValue)（与当下相反，保证真的产生一次切换）")

        // ① 切前
        after(1.0) {
            dump("① 切前(抽屉还没开)")
            log("I18N-IOS ① → 点左上角三横（`menuButtonTapped()`，真实入口）")
            chat.perform(NSSelectorFromString("menuButtonTapped"))
        }

        // ② 抽屉已开 ⇒ 点右下角**齿轮**（2026-10-27 起：账号弹窗删了，齿轮是唯一设置入口）
        after(2.8) {
            dump("② 抽屉已开")
            log("I18N-IOS ② → 点抽屉右下角齿轮（`debugPresentSettings()`，本体是 `settingsTapped()`）")
            (presentedMenu() ?? registeredMenu())?.debugPresentSettings()
        }

        // ③ 设置页已开 ⇒ 点「语言」进去（🔴 2026-10-14 新的一层）
        after(6.8) {
            dump("④ 设置页已开")
            guard let settings = presentedSettings() else {
                log("I18N-IOS ④ ✗ 拿不到设置页 —— 探针到此为止（这条本身就是失败）")
                return
            }
            log("I18N-IOS ④ → 点「语言」（`debugOpenLanguagePage()`，本体是 `open(.language)`）")
            settings.debugOpenLanguagePage()
        }

        // ⑤ 三档页 ⇒ 点语言档（**真实**的 `select(_:)`：先关自己、再写偏好）
        after(8.4) {
            dump("⑤ 三档页已开")
            guard let choice = presentedChoicePage() else {
                log("I18N-IOS ⑤ ✗ 拿不到三档页 —— 探针到此为止（这条本身就是失败）")
                return
            }
            log("I18N-IOS ⑤ → 点语言档 \(target.rawValue)（`debugSelectLanguage(_:)`，本体是 `select(_:)`）")
            choice.debugSelectLanguage(target)
        }

        // ⑥ 切后 —— 这一行是**判据**
        after(10.8) {
            dump("⑥ 切后(未碰界面)")
            // 为了让最后那张截图拍的是**新注册**那份菜单（等价于用户「先关掉再滑一次」）：
            // 先把屏上可能残留的旧抽屉无动画收掉，再走真实入口打开一次。
            // ⚠️ 判据用 `chatPage()` 而**不是** `topViewController()`：没有模态时链上最后一个
            //    就是根那个 `UINavigationController` 本身，`as? AIModuleViewController` 永远不中
            //    （首版就这么写，打出过一条「顶层不是会话页」的假故障）。
            if let top = topViewController(), top is SideMenuNavigationController {
                log("I18N-IOS ⑥ 屏上还留着抽屉 → 无动画收掉，再重新打开（= 用户关掉抽屉再滑一次）")
                top.dismiss(animated: false)
            }
            if let chat = chatPage() as? AIModuleViewController {
                log("I18N-IOS ⑥ → 重新打开抽屉（`menuButtonTapped()`）")
                chat.perform(NSSelectorFromString("menuButtonTapped"))
            } else {
                let pageName = chatPage().map { String(describing: type(of: $0)) } ?? "nil"
                log("I18N-IOS ⑥ ✗ 会话页不是 AIModuleViewController（\(pageName)）—— 打不开抽屉，截图会是空的")
            }
        }

        // ⑦ 最终态（截图就拍在这一拍）
        after(12.4) {
            dump("⑦ 最终(截图拍这一拍)")
            let registered = registeredMenu()
            let want = expectedTitles(for: target)
            let got = registered?.debugQuickTitles ?? []
            log("I18N-IOS 判据①：注册菜单固定项=\(got) 期望=\(want) ⇒ \(got == want ? "PASS" : "FAIL")")
            let wired = registered?.debugIsWired ?? false
            log("I18N-IOS 判据②：注册菜单已接线=\(wired) ⇒ \(wired ? "PASS" : "FAIL（抽屉里列表会空、点两条入口没反应）")")
            // 🔴 判据③：**抽屉还打不打得到** —— 换 root 之后旧抽屉可能挂着过期的
            //    `presentingViewController`（SideMenu 的 `isHidden` 就是拿它算的）
            //    ⇒ 若这里 `屏上抽屉=nil`，说明切完语言**抽屉根本滑不出来**，那是比文案更重的病。
            let shown = presentedMenu()
            let shownTitles = shown?.debugQuickTitles ?? []
            log("I18N-IOS 判据③：重新打开后屏上抽屉=\(id(of: shown)) 固定项=\(shownTitles)"
                + " ⇒ \(shown != nil ? "PASS（滑得出来）" : "FAIL（滑不出来了）")")
            log("=== I18N-IOS 探针结束 ===")
        }
    }

    // MARK: - 期望值

    /// 目标档下第 0 组那几条**应该**显示成什么。
    ///
    /// ⚠️ 这里**刻意写死两份字面**（而不是调 `L()`）：`L()` 读的正是我们怀疑没生效的那条路，
    ///    用它算期望值 = 拿嫌疑人当证人，永远自证清白。
    /// 🔴 2026-10-22 补第三条「新建项目」（2026-10-21 加项目能力时漏同步 ⇒ 判据①连假红
    ///    一整天）：第 0 组是「固定入口」组，加一条是它语义内的事（见 `quickItems` 注释）。
    private static func expectedTitles(for target: AILanguage) -> [String] {
        switch target {
        // 🔴 2026-10-25 第一项文案「开启AI」→「新对话」（用户要求），期望值跟着换：
        //    `新对话` 在词表里是 **"New Chat"**（与 `"开启AI": "New AI Chat"` 不是同一条，
        //    那条已无调用点、删除）⇒ 忘了同步这里，探针会拿旧期望值判新界面 = 假红。
        case .zhHans: return ["新对话", "文档", "新建项目"]
        case .en:     return ["New Chat", "Documents", "New project"]
        case .system: return []   // 目标档恒为具体档，不会走到
        }
    }

    // MARK: - 状态读取

    private static func window() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
            ?? scenes.flatMap { $0.windows }.first
    }

    /// 从根一路 `presentedViewController` 走到底的那条链。
    private static func chain() -> [UIViewController] {
        var result: [UIViewController] = []
        var current = window()?.rootViewController
        while let vc = current {
            result.append(vc)
            current = vc.presentedViewController
        }
        return result
    }

    /// 链上最下面那个（= 此刻真正在最前面的那个人）。
    private static func topViewController() -> UIViewController? { chain().last }

    /// 会话页实例（证明「重建真的发生了」用 —— 类型名两次都是 `UINavigationController`，
    /// 只有里面那个 `topViewController` 的身份才会变）。
    private static func chatPage() -> UIViewController? {
        (window()?.rootViewController as? UINavigationController)?.topViewController
    }

    /// **注册在全局 manager 上**的那份菜单 —— 用户下次滑出抽屉时看到的就是它。
    private static func registeredMenu() -> AIMenuViewController? {
        SideMenuManager.default.leftMenuNavigationController?.viewControllers.first as? AIMenuViewController
    }

    /// **此刻挂在呈现链上**的那份菜单（抽屉没开时为 nil）。⚠️ 设置页盖在上面时它照样找得到
    /// —— 抽屉还在链上、只是被盖住，这正是「写偏好的那一刻屏幕下面还开着抽屉」那个中间态。
    private static func presentedMenu() -> AIMenuViewController? {
        for vc in chain() {
            if let menu = vc as? AIMenuViewController { return menu }
            if let nav = vc as? SideMenuNavigationController,
               let menu = nav.viewControllers.first as? AIMenuViewController { return menu }
        }
        return nil
    }

    /// 设置页 —— 它被包在一个 `UINavigationController` 里模态弹出来 ⇒ 得往 nav 里再挖一层。
    private static func presentedSettings() -> AISettingsViewController? {
        for vc in chain() {
            if let settings = vc as? AISettingsViewController { return settings }
            if let nav = vc as? UINavigationController,
               let settings = nav.topViewController as? AISettingsViewController { return settings }
        }
        return nil
    }

    /// 三档页 —— 它是被**push** 进设置页那个 nav 的 ⇒ 同样往 nav 里挖。
    private static func presentedChoicePage() -> AIChoiceListViewController? {
        for vc in chain() {
            if let choice = vc as? AIChoiceListViewController { return choice }
            if let nav = vc as? UINavigationController,
               let choice = nav.topViewController as? AIChoiceListViewController { return choice }
        }
        return nil
    }

    private static func dump(_ tag: String) {
        let registered = registeredMenu()
        let onScreen = presentedMenu()
        let regTitles = registered?.debugQuickTitles.joined(separator: "|") ?? "-"
        let onTitles = onScreen?.debugQuickTitles.joined(separator: "|") ?? "-"
        let wired = registered.map { "\($0.debugIsWired)" } ?? "-"
        var line = "I18N-IOS \(tag) 生效=\(AILanguageStore.resolved.rawValue)"
        line += " · 注册菜单=\(id(of: registered)) 固定项=[\(regTitles)] 已接线=\(wired)"
        line += " · 屏上抽屉=\(id(of: onScreen)) 屏上固定项=[\(onTitles)]"
        line += " · 会话页=\(id(of: chatPage()))"
        line += " · 设置页=\(id(of: presentedSettings()))"
        line += " · 三档页=\(id(of: presentedChoicePage()))"
        log(line)
    }

    private static func id(of object: AnyObject?) -> String {
        guard let object else { return "nil" }
        return "#" + String(UInt(bitPattern: ObjectIdentifier(object)), radix: 16)
    }

    // MARK: - 落盘

    private static func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// 每次运行先清空 —— 整份日志就是本轮，判据不用在历史里翻。
    private static func reset() {
        try? FileManager.default.removeItem(at: url)
    }

    /// iOS 上 `AIPlatformPaths.appDataDirectory` 就是 `Documents`（见它 `AIPlatformServices+iOS.swift`）。
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
        NSLog("[I18N-IOS] %@", line)
    }
}
#endif
