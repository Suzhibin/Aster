//
//  AILocalization.swift
//  AsterCore
//
//  App 内语言的**唯一口径**：语言档位（跟随系统 / 简体中文 / English）+ 查表函数 + 英文词表。
//  两端（iOS / Mac）共用这一份 —— 语言这件事两端语义**完全相同**（不像「外观」那样
//  一边是 `overrideUserInterfaceStyle`、一边是 `NSApp.appearance`，见 `AIAppearance.swift` 文件头）。
//
//  ## 🔴 为什么不用标准的 `.strings` / `NSLocalizedString`（2026-10-13 决策）
//
//  **决定性理由：验收台读不到 bundle 资源。**
//  `render_mac_ui.sh` 是用 `swiftc` 把源码（+ 桩）**直编**成一个可执行文件的
//  （见那个脚本文件头「各自编成静态库 → 与真实源码 + main.swift 链成一个可执行文件」），
//  它**没有打包任何资源** ⇒ `Bundle.main` 里没有 `Localizable.strings` ⇒ 走标准本地化的话，
//  渲染台里所有文案会变成 key（或空串）⇒ **整台验收台变砖**。
//  这与 2026-10-12 那个「渲染台展不开 `@Observable` 宏、得手工补 `access/withMutation`」
//  是**同一类坑**：任何依赖「Xcode 打包 / 宏展开」的机制，在离屏渲染台上都会**静默**失效。
//
//  次要理由：
//  - 运行时切换语言**本来就需要自定义查找**（`NSLocalizedString` 认 `Bundle.main`，
//    换语言要重启或 swizzle bundle）⇒ 既然都要自定义查找函数，词表「存哪儿」就是次要问题；
//  - 走 `.strings` 要动 pbxproj 的 `knownRegions` + `PBXVariantGroup`，而本工程手工改 pbxproj
//    有过 **ID 撞车 → Xcode 直接打不开**的事故史（见 `MEMORY.md` 包契约第 6 条），
//    为一个能用纯源码解决的机制去动它不划算。
//
//  ## 词表用「**中文原文**当 key」
//  ```swift
//  L("设置")            // 中文档 → 「设置」；英文档 → "Settings"
//  L("模型没有返回内容")  // 中文档 → 「模型没有返回内容」；英文档 → "The model returned no content."
//  ```
//  ⚠️ 这是**刻意**的，三个好处：
//  ① **改造时不动文案位置**：把 `"设置"` 包成 `L("设置")` 即可，一眼看出这行是待翻译文案；
//  ② **漏了也不破相**：词表里没有的中文**回落成中文原文**（⛔ 不是回落成 key 那种乱码），
//     所以文案接入可以**分批推进**，中途任何一版都是可用的；
//  ③ **可脚本检查**：扫「源码里还有没被 `L(...)` 包住的中文字面量」就能给出漏检清单。
//  ⛔ 别把 key 改成英文标识符（`"account.settings"`）—— 那样「没接完」的部分会显示成
//     `account.settings` 这种破相文本，把「分批推进」这条退路堵死。
//
//  ## 🔴 切语言后界面怎么重算（**第三版，2026-10-13 定案**）
//
//  `L()` 是普通函数，本身**不登记**任何观察依赖 —— 但它现在会去读一个 `@Observable` 风格的
//  「语言版本号」（`AILanguageRevision`），于是**每一个在 body 里调过 `L()` 的视图**都会
//  在语言切换时各自重算（Observation 的依赖同样只在 **body 求值期**登记）。
//  - **Mac**：靠上面那条 ⇒ 不需要任何重建动作。RootView 只多做两件事（都**不是**换身份）：
//    ① 收到 `didChange` 时调 `model.languageDidChange()`（`title` 是存储属性，存的是旧语言那份）；
//    ② `MacMainMenuLocalizer.scheduleApply()`（菜单栏不在视图树里）。
//  - **iOS**：`L()` 在 `viewDidLoad` 期求值 ⇒ 切完**重建主 window 的 rootViewController**
//    （会话数据在 `AIChatStore` 单例里，不丢）。
//
//  ### ☠️☠️ 为什么不许再用 `.id(...)` 换身份（**三版血泪，⛔ 别再走回头路**）
//  `.id` 确实能强制整棵子树重算，但它在 Mac 上有两个**结构性**代价：
//  ① 挂在 `NavigationSplitView` **根 / 列**上 ⇒ 切语言后第一次模型变更会让
//     窗口工具栏分隔项（`splitViewSeparator-0`）在同一拍里注销 + 重注册
//     ⇒ AppKit 断言失败（`NSWindowSectionController.m:585`）⇒ **点一下 App 就没了**；
//  ② 挂在「**带 `.toolbar` 的那一列的内容子树**」里（不管挂多深）⇒ 该列的工具栏项
//     被 AppKit 拆掉 hosting view 之后**不再回填** ⇒ 会话页右上那两颗按钮**当场消失**
//     （测得 `ToolbarItemHostingView` 从 `69x28` 缩成 `10x10`、`NSButton` 子视图清零，
//      而 `isVisible` / `visibleItems` 照样报 true ⇒ 判据极易假绿）。
//  ⇒ 结论：**列的内容子树里一次身份变化都不许有**。重算改用「让每个视图自己登记依赖」这条路。
//  ⚠️ 这里用 Observation 是**手写**的一致性（`registrar.access/withMutation`），
//     ⛔ **不是 `@Observable` 宏** —— 渲染台展不开宏（这是本文件一直避开的那个坑），
//     手写就没有这个问题。
//
//  ## 范围：只做**本地功能文案**
//  用户 2026-10-13 明确：「只做我们本地功能文本的适配，发送和AI返回数据不用」。
//  ⇒ **不要**接进词表的东西：用户输入、AI 回复、Markdown 正文、模型名 / 服务地址这些自填项。
//     要接的：按钮 / 标题 / 占位符 / 空态 / tooltip / **本地生成的**提示与错误（如「已取消」）。
//
//  ## 词表维护
//  英文词表在 `AILocalization.en`，按「通用 / iOS / Mac」分节（`#pragma MARK` 式的行注释）。
//  ⚠️ 加文案时**只加 `L("…")` 调用点就够了**（缺项回落中文），补翻译是第二件事 ——
//     但补翻译时记得**两端共用的字面只写一条**（本文件就是唯一来源）。
//

import Foundation
// ⚠️ `Observation` 的符号（`Observable` / `ObservationRegistrar`）是 iOS 17 / macOS 14 起，
//    本包两端都在用 ⇒ 用到的每一处都得 `@available` 兜住（iOS 15 target 照旧能编过）。
import Observation

// MARK: - 语言档位

/// App 内语言。`rawValue` 直接落 `UserDefaults`。
///
/// ⚠️ ⛔ **别改已有 case 的 `rawValue`** —— 那就是存档格式，改了等于把用户选过的偏好丢掉
///    （与 `AIAppearance` / `MacAppearance` 同一条规矩）。
public enum AILanguage: String, CaseIterable {

    /// 跟随系统（**默认档**，用户 2026-10-13 要求）。系统语言是中文 ⇒ 简体中文，其余 ⇒ English。
    case system
    /// 简体中文
    case zhHans = "zh-Hans"
    /// English
    case en

    /// 菜单 / 二级页里那一行显示的名字。
    ///
    /// 🔴 **语言名按「该语言自己的写法」显示、不进词表**（Apple 的语言列表就是这么做的）：
    ///    中文档里那一行是「简体中文」，英文档里**还是**「简体中文」—— 它说的是语言本身，
    ///    翻成 "Simplified Chinese" 反而让母语用户认不出自己那一行。
    ///    ⚠️ 只有「跟随系统」是**描述**而不是语言名，所以它走 `L()`。
    public var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .zhHans: return "简体中文"
        case .en:     return "English"
        }
    }
}

// MARK: - 存取（唯一入口）

/// 「语言」偏好的**唯一存取点**。
///
/// ⛔ 别在视图 / VC 里直接 `UserDefaults.string(forKey:)` —— 那样默认值（`.system`）
///    会在各处散成好几份，哪天改默认值一定漏掉某处（与 `AIAppearanceStore` 同款理由）。
public enum AILanguageStore {

    /// ⚠️ 带命名空间前缀：`UserDefaults` 与系统及其它版本共用命名空间，裸 `"language"` 迟早撞上。
    ///    ⚠️ iOS 与 Mac 是两个 App（bundle id 不同）⇒ `UserDefaults.standard` 本就互相独立，
    ///    两端用**同一个键名**是安全的，也让「换端不用改代码」成立。
    private static let key = "Aster.language"

    /// 语言档位变更通知（`.object` 为空）。
    /// - iOS 侧靠它触发「重建 rootViewController」；
    /// - Mac 侧靠它做两件**不属于「重算文案」**的收尾：`model.languageDidChange()`（重算标题）
    ///   与 `MacMainMenuLocalizer.scheduleApply()`（菜单栏不在视图树里）。
    ///   ⚠️ 文案重算**不靠**它 —— 那条路走 `AILanguageRevision`（见文件头）。
    public static let didChange = Notification.Name("Aster.languageDidChange")

    /// 用户选的档位。
    public static var current: AILanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let value = AILanguage(rawValue: raw) else { return .system }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            // 🔴 **先**把「语言版本号」推一格（2026-10-13 第三版）—— 这一下会让所有
            //   「body 里调过 `L()`」的视图各自登记到变更 ⇒ 文案立刻跟着翻。
            //   ⚠️ 顺序有意：放在 post 之前，保证「通知的收尾逻辑」跑的时候界面已经是新语言。
            //   ⚠️ 它**只有这个作用**（不是缓存、不是「脏标记」），⛔ 别拿它当状态判断用。
            if #available(iOS 17.0, macOS 14.0, *) { AILanguageRevision.shared.bump() }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// **实际生效**的语言（把 `.system` 按系统语言解析成具体一档）。
    ///
    /// 🔴 查表要用的是**这个**，⛔ 不是 `current` —— `current` 可能是 `.system`，
    ///    而词表里没有「system 档」这一说。
    /// ⚠️ **每次现算**、不缓存：用户可以在 App 运行期间去系统设置里改语言，
    ///    缓存只会在那一刻给出过期的结果（本工程偏好项一律「现读」）。
    public static var resolved: AILanguage {
        let selected = current
        guard selected == .system else { return selected }
        return systemLanguage()
    }

    /// 系统语言解析：`zh*`（含 `zh-Hant`）⇒ 简体中文，其余 ⇒ English。
    ///
    /// ⚠️ `Locale.preferredLanguages` 给的是**用户语言偏好序列**（如 `"zh-Hans-CN"`），
    ///    不是 `Locale.current` —— 后者会把「地区」也算进来（`zh_CN` 与 `zh_TW` 靠它分不开）。
    /// ⚠️ 繁体（`zh-Hant`）目前也归简体中文：本工程只有一份中文词表（简体），
    ///    对繁体用户显示简体是「看得懂」的那一档，比回落英文合理。
    private static func systemLanguage() -> AILanguage {
        let code = Locale.preferredLanguages.first ?? "en"
        return code.hasPrefix("zh") ? .zhHans : .en
    }

    /// 启动时规范化一次。
    ///
    /// 作用只有一个：把**认不出的残留值**清掉（比如手改 UserDefaults、或旧版本写过的档位名），
    /// 免得它一直以「非法 rawValue」的形式躺在盘上（虽然 `current` 的 getter 已经会回落默认值）。
    /// ⚠️ 它**不需要**像 `AIAppearanceStore.restoreAtLaunch()` 那样「在窗口出现之前应用」——
    ///    语言没有「应用」这一步，查表是即时的。
    public static func restoreAtLaunch() {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return }
        if AILanguage(rawValue: raw) == nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - 🔴 语言版本号（让「切语言」变成一次**可被 SwiftUI 观察**的变更）

/// 语言版本号 —— **整个「切语言界面立刻重算」机制就靠它**（2026-10-13 第三版，成因见文件头）。
///
/// ## 用法：只读它，别写它
/// `L()` 每次求值都会读一次 `AILanguageRevision.shared.value`。
/// 因为 `L()` 是在**视图 body 求值期**被调用的，而 SwiftUI 正是用 Observation 的
/// `withObservationTracking` 包住 body 求值的 ⇒ **每个渲染过本地化文案的视图都会登记到它**，
/// 于是 `bump()` 一下，那些视图**各自**重算。⛔ 不需要（也不许）再用 `.id(...)` 换身份。
///
/// ## 为什么**手写** `Observable` 一致性，而不用 `@Observable` 宏
/// 渲染台 `render_mac_ui.sh` 用 `swiftc` 直编源码，**宏展不开**
/// （`@Observable` 会报 `produced malformed response`），而「手写」只需要一个
/// `ObservationRegistrar` + 在 getter / setter 里各调一次 `access` / `withMutation` ——
/// 两边都能编过、行为一致。⚠️ 本工程此前**刻意避免**新建 `@Observable` 类型，指的就是**宏**那条路，
/// 不是 Observation 这套运行时。
///
/// ## ⚠️ 三条边界
/// ① **不能把存储属性直接 `public var value: Int`** —— 那样读它不会登记任何依赖（宏帮你生成的
///    `access` 调用没有宏就没有）。必须像下面这样**自己包一层**。
/// ② `keyPath` 只是个**身份令牌**，与真正的存储无关；换名字要连着 getter / setter 一起换。
/// ③ 语言档位**只有** `AILanguageStore.current` 的 setter 一处该调 `bump()`（别在视图里调）。
@available(iOS 17.0, macOS 14.0, *)
public final class AILanguageRevision: Observable {

    /// 进程内唯一一份。
    public static let shared = AILanguageRevision()

    private let registrar = ObservationRegistrar()
    private var storage: Int = 0

    /// 当前版本号。**读** = 登记一条「语言变了请叫我重算」的依赖。
    public var value: Int {
        get {
            registrar.access(self, keyPath: \.value)
            return storage
        }
        set {
            registrar.withMutation(of: self, keyPath: \.value) { storage = newValue }
        }
    }

    /// 推一格（`AILanguageStore.current` 的 setter 里调）。
    public func bump() { value &+= 1 }
}

// MARK: - 查表

/// 本地化查表。
public enum AILocalization {

    /// 把中文原文翻成当前生效语言的文案。
    ///
    /// - Parameter zh: **中文原文**（就是词表的 key，见文件头）。
    /// - Returns: 英文档且词表命中 ⇒ 英文；否则**原样返回中文**（回落，见文件头 ②）。
    public static func text(_ zh: String) -> String {
        switch AILanguageStore.resolved {
        case .zhHans: return zh
        case .en:     return en[zh] ?? zh
        // `.system` 不会走到（`resolved` 已经解析过），列在这里只是为了**穷尽 switch**。
        case .system: return zh
        }
    }

    /// 英文词表。⛔ **唯一来源** —— 两端共用的字面只在这里写一条。
    ///
    /// ## 维护规矩
    /// - key 一律是**中文原文**（含标点与换行转义，`\n` 照抄）。
    /// - 同一条中文只写一次；两端共用的字面（如「取消」「复制」）**不许**各写一份。
    /// - ⚠️ 带参数的 key 里写 `%@` / `%d`（调用处套 `String(format:)`），**别**写具名占位符。
    /// - ⚠️ 「设置」与「设置…」是**两个** key（Mac 菜单项带省略号），别合并。
    /// - ⚠️ 语言名（`简体中文` / `English`）**不进表** —— 按各自写法显示，见 `AILanguage.title`。
    /// - 🔴 漏一条 = 英文档里那句显示成中文（回落，不破相）。查漏用 `.workbuddy/notes/i18n/` 下的自检。
    static let en: [String: String] = [

        // ── 设置 / 外观 / 语言（iOS 设置页与 Mac 设置窗共用）──────────────────
        // ⚠️ 2026-10-27 这一组原来带「账号菜单」：用户「把头像和名称都删除」之后，
        //    iOS 的账号弹窗（`AIAccountMenuViewController`）与 Mac 的账号菜单一起删了 ⇒
        //    下面三条 key **已无任何调用点，一并删掉**：
        //      · "退出登录"
        //      · "「退出登录」还没接上：当前版本没有账号体系"
        //      · "Starry 用户"（iOS 抽屉底栏那行假名字）
        //    ⛔ 别照着旧版加回来 —— 没有账号体系就没有「登录/登出」这件事。
        "设置": "Settings",
        "设置…": "Settings…",
        "外观设置": "Appearance",
        "语言设置": "Language",
        "跟随系统": "System",
        "浅色": "Light",
        "深色": "Dark",
        "立即应用到所有窗口": "Applies to all windows immediately",
        "只切换界面文案，AI 回复不受影响": "Switches interface text only — AI replies are unaffected",
        "取消": "Cancel",
        "确定": "OK",
        "打开设置": "Open Settings",

        // ── 侧栏 / 会话列表 ────────────────────────────────────────────────
        // ⚠️ 2026-10-25 删掉 `"开启AI": "New AI Chat"`（两端菜单第一项改成「新对话」，
        //    复用下面已有的 `"新对话": "New Chat"`）⇒ 那条已无任何调用点。
        "开启一段新的 AI 对话（⌘N）": "Start a new AI chat (⌘N)",
        "文档": "Documents",
        "我的对话": "My Chats",
        "查看全部对话里上传过的文件": "Files uploaded across all chats",
        "新建对话": "New Chat",
        "新建标签页": "New Tab",
        "开始一个新对话": "Start a new chat",
        "新对话": "New Chat",
        "今天帮你做些什么？": "What can I help you with today?",
        "在下面输入你的问题，⌘N 可以新建一个对话。": "Type your question below. ⌘N starts a new chat.",
        // 🔴 2026-10-26 会话页空态两端统一成 **Mac 那一版**（图标 + 标题 + 副文案）。
        //    iOS 原来那套「问候语 + 4 颗快捷提问 chips」整体删除。
        //    ⚠️ 副文案**必须**另起一条：Mac 那句带 `⌘N`，iOS 没有键盘快捷键，
        //       照搬会在手机上教用户按一个不存在的键。⛔ 别为了「少一条词」合并。
        "在下面输入你的问题。": "Type your question below.",
        // 未配置模型时的引导（两端同款，按钮落点见各自的 `openModelSettings` /
        // `MacSettingsRouter.request(.model)`）。
        "还没有配置模型，先配置一个才能开始对话": "No model configured yet — add one to start chatting.",
        "去配置模型": "Configure Model",
        // ⚠️ 下面 6 条是**已删掉的 iOS 旧落地页**用的（问候语 + 4 颗 chips，2026-10-26 删）。
        //    刻意留着不删：与「单次用量」那次同一个道理 —— 用户可能反悔，恢复时不用重译。
        //    确认永不再用可以一起清掉。
        "你好，我是 Starry AI": "Hi, I’m Starry AI",
        "很高兴见到你！有什么可以帮忙的吗？": "Nice to meet you! How can I help?",
        "帮我写一首关于星星的诗": "Write a poem about the stars",
        "用 Swift 写一个单例": "Write a singleton in Swift",
        "推荐几部科幻电影": "Recommend some sci-fi movies",
        "什么是 CPO 光模块？": "What is a CPO optical module?",
        "重命名": "Rename",
        "重命名…": "Rename…",
        "重命名会话": "Rename Chat",
        "重命名对话": "Rename Chat",
        "置顶": "Pin",
        "置顶对话": "Pin Chat",
        "取消置顶": "Unpin",
        "删除": "Delete",
        "删除对话": "Delete Chat",
        "删除这个会话？": "Delete this chat?",
        "删除后无法恢复。": "This can’t be undone.",
        "从对话列表删除": "Remove from chat list",
        "分享": "Share",
        "分享…": "Share…",
        "分享对话": "Share Chat",
        "该会话已不存在": "This chat no longer exists",
        "这个会话还没有可分享的内容": "This chat has nothing to share yet",
        "还没有会话": "No chats yet",
        "还没有文件": "No files yet",
        "在对话里上传的文件都会出现在这里": "Files you upload in chats will show up here",
        "还没有文件\n在对话里上传的文件都会出现在这里": "No files yet\nFiles you upload in chats will show up here",
        "关闭文档页，回到对话": "Close the documents page and return to chat",
        "内容由 AI 生成": "AI-generated content",
        "内容由 AI 生成，请核实重要信息": "AI-generated content — please verify important information",

        // ── 搜索 ────────────────────────────────────────────────────────
        "搜索": "Search",
        "搜索对话": "Search chats",
        "搜索对话…": "Search chats…",
        "搜索历史对话（⌘F）": "Search chats (⌘F)",
        "搜索或输入网址": "Search or enter a URL",
        "搜索模型名": "Search model names",
        "标题": "Title",
        "回车打开第一条": "Press Enter to open the first result",
        "输入关键词，搜索全部对话\n标题和聊天内容都会匹配": "Type a keyword to search all chats\nTitles and message content are both matched",
        "没有找到与「%@」相关的内容": "No results for “%@”",

        // ── 输入区 ──────────────────────────────────────────────────────
        "问点什么…": "Ask anything…",
        "请输入消息内容": "Type a message",
        "发送": "Send",
        "发送（⏎ / ⌘⏎）": "Send (⏎ / ⌘⏎)",
        "停止生成": "Stop Generating",
        "停止朗读": "Stop Reading",
        "停止加载": "Stop Loading",
        "上传文件或图片": "Upload file or image",
        "添加": "Add",
        "添加内容：截图提问 / 上传文件或图片": "Add: Screenshot / Upload file or image",
        "画图": "Draw",
        "选择要一起发给 AI 的图片或文件": "Choose images or files to send with your message",
        "移除这个附件": "Remove this attachment",
        "截图提问": "Ask with Screenshot",
        "拍照提问": "Ask with Photo",
        "相机": "Camera",
        "相册": "Photos",
        "照片": "Photo",
        "文件": "File",
        "图片": "Image",
        "视频": "Video",
        "文本": "Text",
        "其它": "Other",
        "管理": "Manage",
        "管理已选照片": "Manage selected photos",
        "继续添加图片": "Add more images",
        "没有可添加的文件": "No files to add",
        "切换键盘": "Switch keyboard",
        "引用": "Quote",
        "取消引用": "Cancel Quote",
        "引用%@": "Quote %@",
        "引用了%@": "Quoted %@",
        "正在编辑这条消息": "Editing this message",
        "编辑": "Edit",
        "保存": "Save",
        "放弃改动": "Discard changes",
        "修改后自动保存。": "Saves automatically as you type.",
        "选取文字": "Select Text",
        "取消选择": "Cancel Selection",
        "删除选中的消息": "Delete selected messages",
        "回到底部": "Back to Bottom",
        "关闭（Esc）": "Close (Esc)",

        // ── 语音（按住说话 / 录音面板 / 通话页）─────────────────────────────
        "按住说话": "Hold to Talk",
        "松开即可添加到输入框": "Release to add to the composer",
        "松手发送，上移取消": "Release to send, swipe up to cancel",
        "松手取消": "Release to cancel",
        "请开始说话": "Start speaking",
        "请开始说话…": "Start speaking…",
        "点 ✗ 结束 · 点 ✓ 发送": "Tap ✗ to finish · Tap ✓ to send",
        "结束并发送": "Finish & Send",
        "结束并发送（Esc 取消）": "Finish & send (Esc to cancel)",
        "结束并放弃这次语音输入（Esc）": "Finish and discard this voice input (Esc)",
        "结束语音并发送（也可以再点一次 🎤）": "Finish voice and send (or tap 🎤 again)",
        "正在整理文字…": "Transcribing…",
        "语音输入：点一下开始说话": "Voice input: tap to start speaking",
        "未命中输入": "No speech detected",
        "没听清，请再说一次": "Didn’t catch that — please say it again",
        "录音被中断，请重试": "Recording was interrupted — try again",
        "麦克风被系统中断，请重试": "Microphone was interrupted by the system — try again",
        "语音通话": "Voice Call",
        "打电话（与 AI 语音对话，独立窗口）": "Call (voice chat with AI, separate window)",
        "挂断": "Hang Up",
        "麦克风": "Microphone",
        "麦克风（已静音）": "Microphone (muted)",
        "打开麦克风": "Unmute",
        "静音（不再拾音）": "Mute (stop listening)",
        "已静音": "Muted",
        "已静音，点麦克风继续": "Muted — tap the mic to continue",
        "说话或点击打断": "Speak, or tap to interrupt",
        "点击打断": "Tap to interrupt",
        "字幕": "Subtitles",
        "字": "A",
        "选择情景": "Choose Scenario",
        "视频通话暂未支持": "Video calls aren’t supported yet",
        "回到会话窗口打字（通话保持）": "Back to the chat window to type (call stays on)",
        "按住「⌥+E」可以暂时打开麦克风": "Hold ⌥+E to temporarily unmute",
        "通话被系统打断": "Call interrupted by the system",
        "通话窗口正在使用麦克风": "The call window is using the microphone",

        // ── 消息行操作 / 媒体 ─────────────────────────────────────────────
        "复制": "Copy",
        "复制这段代码": "Copy this code",
        "已复制": "Copied",
        "已复制代码": "Code copied",
        "朗读": "Read Aloud",
        "喜欢": "Like",
        "不喜欢": "Dislike",
        "已喜欢": "Liked",
        "已不喜欢": "Disliked",
        "保存到相册": "Save to Photos",
        "已保存": "Saved",
        "已保存到相册": "Saved to Photos",
        "保存失败": "Save failed",
        "保存失败，请检查相册权限": "Save failed — check Photos permission",
        "重新生成": "Regenerate",
        "从这条起重新生成（这条之后的对话会被替换）": "Regenerate from here (later messages will be replaced)",
        "重试": "Retry",
        "继续生成": "Continue",
        "回复没写完，可在气泡上右键「继续生成」": "The reply was cut off — right-click the bubble to Continue",
        "回复没写完，长按这条可「继续生成」": "The reply was cut off — long-press to Continue",
        "更多": "More",
        "更多操作": "More actions",
        "显示": "Show",
        "隐藏": "Hide",
        "返回": "Back",
        "另存为": "Save As",
        "另存为…": "Save As…",
        "旋转 90°": "Rotate 90°",
        "放大": "Zoom In",
        "缩小": "Zoom Out",
        "放大（⌘+）": "Zoom In (⌘+)",
        "缩小（⌘-）": "Zoom Out (⌘-)",
        "重置缩放（⌘0）": "Reset Zoom (⌘0)",
        "用默认应用打开": "Open with Default App",
        "用浏览器打开": "Open in Browser",
        "用默认浏览器打开": "Open in Default Browser",
        "在浏览器中打开": "Open in Browser",
        "在访达中显示": "Reveal in Finder",
        "用系统预览打开": "Open with System Preview",
        "交给系统的 QuickLook 预览（它认更多格式）": "Hand off to the system QuickLook preview (supports more formats)",
        "点开查看大图": "Tap to view full size",
        "点开查看文件": "Tap to view file",
        "点开播放": "Tap to play",
        "媒体不可用": "Media unavailable",
        "图片不可用": "Image unavailable",
        "视频不可用": "Video unavailable",
        "图片已不存在": "Image no longer exists",
        "这张图还没下载，暂时不能保存": "This image hasn’t downloaded yet — can’t save it for now",
        "图片读取失败，换一张试试": "Failed to read the image — try another one",
        "图片保存失败，再试一次": "Failed to save the image — try again",
        "拍照失败，再试一次": "Photo capture failed — try again",
        "文件读取失败": "Failed to read the file",
        "文件已不存在": "File no longer exists",
        "这条没有可保存的图片": "No image to save in this message",
        "这条没有可引用的文字": "No text to quote in this message",
        "这条没有可朗读的文字": "No text to read aloud in this message",
        "这条没有可编辑的文字": "No text to edit in this message",
        "这条没有可选取的文字": "No text to select in this message",
        "这条是系统提示，不用引用": "This is a system notice — no need to quote it",
        "这条消息已不在当前会话里": "This message is no longer in the current chat",
        "跳到被引用的消息": "Jump to the quoted message",
        // 项目 / 会话文件夹（2026-10-21）
        "新建项目": "New project",
        // 🔴 2026-10-25 产品改名「任务项目组」→「任务」（用户原话：「默认的任务项目组 改成 任务 两个字」）。
        //    ⚠️ 默认项目名是**写库快照**（创建那一刻的语言）⇒ 老库不会自动跟上，
        //       由 `AIChatStore.ensureDefaultProject()` 原地补改名（只改还叫旧名的，尊重用户自己起的名）。
        //    ⚠️ 英文两侧都是 "Tasks" ⇒ 英文用户界面**看不出变化**，这是正常的。
        "任务": "Tasks",
        "项目名称": "Project name",
        "创建": "Create",
        "重命名项目": "Rename project",
        "删除项目": "Delete project",
        "删除项目？": "Delete this project?",
        // ⚠️ 长句也要进表（2026-10-21）：`L()` 查不到就**原样返回中文** —— 英文界面下
        //    这句会漏成中文，而它偏偏是唯一说清「会话不会丢」的那句，漏翻最刺眼。
        "「%@」里的会话不会被删除，只会移回「任务」；项目里的资料会一并删除。":
            "Chats inside \"%@\" are kept and moved to Tasks; the project and its files will be deleted.",
        "管理项目": "Manage project",
        "管理项目…": "Manage project…",
        "移动到项目": "Move to project",
        "暂无对话": "No chats yet",
        // 项目资料（L2，2026-10-21）
        "项目资料": "Project files",
        "选择项目资料": "Choose project files",
        "这个项目还没有资料": "No files in this project yet",
        "还没有资料\n把常看的文件放进项目，聊这个项目时随时取用":
            "No files yet\nAdd the files you use often so they are one tap away while chatting",
        "%@ · 加入于 %@": "%@ · added %@",
        "当前会话不属于任何项目": "This chat is not in any project",
        "还没有资料": "No files yet",
        "把常看的文件放进项目，聊这个项目时随时取用":
            "Add the files you use often so they are one tap away while chatting",
        "%d 份资料": "%d files",
        "添加文件…": "Add files…",
        "选择要放进这个项目的文件": "Choose files to put into this project",
        "%d 个文件读不进来": "%d files could not be read",
        "完成": "Done",
        "项目指令": "Project instructions",
        // 2026-10-27 改口径：原「空 = 只用全局指令」字面没错，但会被读成
        // 「非空就替换全局」⇒ 用户把全局那段再抄一遍（两份近似文本同时进 system）。
        // 注入侧一直是**叠加**（`AIChatManager.withSystemPrompt` 的 `[global, project, memory]`）。
        "与全局指令叠加使用": "Used together with the global instructions",
        // iOS 项目指令页的**整句**说明（2026-10-27）。与上面那条不是同一个键：
        // 上面是 Mac 面板上的短标签，下面是 iOS section footer 的整句 —— 短标签在
        // footer 里太寡淡（用户读不出「那全局那份算不算」）。⚠️ 两处都留，别合并成一个。
        "与全局指令叠加使用：全局那份仍然生效，这里只追加本项目的规则。":
            "Used together with the global instructions: the global one still applies; this only adds rules for this project.",
        // ⚠️「未设置」已在下面出现过一次（同一个英文）⇒ 这里**不再重复登记**字典键
        //    （重复键会编译警告，且先出现的那条赢 —— 维护时极容易改错一条）。
        "已设置": "Set",
        // 联网搜索（A 方案 · AnySearch 匿名，2026-10-21）
        // ⚠️ 只登记**界面能看见的**文案 + 会弹给用户的错误；注入给模型的资料块正文
        //    （「【刚检索到的网页资料】」那段）**不进词表** —— 见 `AIWebSearch.digest` 的注释。
        "联网搜索": "Web search",
        "联网搜索：先查网页再回答": "Web search: look things up before answering",
        "联网搜索已开启：发送前先查网页（点一下关掉）":
            "Web search is on — pages are looked up before answering (click to turn off)",
        "联网搜索：发送前先查网页再回答（点一下开）":
            "Web search — look up pages before answering (click to turn on)",
        "正在联网搜索…": "Searching the web…",
        "正在联网搜索": "Searching the web",
        "要搜什么？": "What should I search for?",
        "联网搜索没连上：%@": "Web search could not connect: %@",
        "联网搜索失败（HTTP %d）": "Web search failed (HTTP %d)",
        "联网搜索被拒绝：%@": "Web search was rejected: %@",
        "联网搜索没有找到相关网页，我直接回答": "No web pages found — answering directly",
        "联网搜索没搜到，直接回答": "Web search found nothing — answering directly",
        // `@` 项目资料（2026-10-21）
        // ⚠️ 与联网搜索同一条口径：只登记**界面能看见的**文案。
        //    注入给模型的资料块（「【项目资料 名字】」与「已不在」那句）**不进词表** ——
        //    它们属于 prompt，切语言不影响已经发出去的历史消息，混进词表只会让人以为能切。
        "@ 项目资料": "@ Project files",
        "@ 一份项目资料": "@ a project file",
        "这份资料已经 @ 过了": "That file is already mentioned",
        "一次最多 @ 3 份资料": "Up to 3 files per message",
        "移除资料": "Remove file",
        "这些消息已经不在了": "These messages are gone",
        "正在回复中…": "Replying…",
        "正在回复中，先停下再试": "Still replying — stop first, then try",
        "正在回复中，先停下再删": "Still replying — stop first, then delete",
        "正在回复中，稍等一下": "Still replying — just a moment",
        "正在思考…": "Thinking…",
        "正在回答…": "Answering…",
        "我": "Me",
        "[图片]": "[Image]",
        "[附件]": "[Attachment]",
        "图片.png": "image.png",
        "视频.mp4": "video.mp4",

        // ── 设置：平台 / 模型 / Key ────────────────────────────────────────
        "平台": "Provider",
        "平台配置": "Provider Settings",
        "接入平台": "Provider",
        "模型": "Model",
        "模型名": "Model name",
        "模型名（可直接手填）": "Model name (you can type it directly)",
        "手动输入模型名": "Enter model name",
        "手动输入模型名…": "Enter model name…",
        // 🗑️ 2026-10-13 随「本地 Mock / 自定义平台」一起删掉的 7 条（服务地址不再可编辑、
        //    平台固定在三家官方端点上）：
        //    「服务地址」「完整聊天端点」「自填服务地址与模型」
        //    「本地 Mock」「本地调试用的 mock 服务」「本机 mock 服务器，走内置私有协议」
        //    「自定义（OpenAI 兼容）」
        "api.deepseek.com · OpenAI 兼容": "api.deepseek.com · OpenAI-compatible",
        "拉取模型列表": "Fetch model list",
        "拉取中…": "Fetching…",
        "当前没有可选模型": "No models available",
        "从列表选择": "Choose from list",
        "选择模型": "Choose Model",
        // ── 会话页那一页「选择模型」（`AIModelPickerViewController`）──────
        // ⚠️ 2026-10-14 补：这几条**一直没进词表**（英文档下这一页此前是中文）。
        // ⚠️ 英文侧刻意与清单页那颗按钮用词一致（"Add Model" / 那一页的标题），
        //    因为点下去落到的就是同一页 —— 换个说法会让英文用户以为是两个不同的地方。
        "添加模型…": "Add Model…",
        "管理模型…": "Manage Models…",
        "还没配置模型\n点下方「管理模型」加一条": "No models configured yet\nTap “Manage Models” below to add one",
        "这些模型还没配好\n点下方「管理模型」补上地址和 API Key": "These models aren’t ready yet\nTap “Manage Models” below to add the URL and API Key",
        "这些是画图模型，不能用来聊天\n点下方「管理模型」加一个对话模型": "These are image-generation models — they can’t chat\nTap “Manage Models” below to add a chat model",
        "选择平台与模型": "Choose Provider & Model",
        "当前": "Current",
        "使用": "Use",
        "设置中配置": "Configured in Settings",
        "默认 · 纯文本": "Default · text only",
        "支持图片（实验）": "Supports images (experimental)",
        "未设置": "Not set",
        "未配置": "Not configured",
        "刷新": "Refresh",
        "生成": "Generate",
        "恢复默认": "Restore Defaults",
        "API Key：未填写（该平台可留空）": "API Key: not set (optional for this provider)",
        "API Key：未配置（该平台暂不可用）": "API Key: not configured (provider unavailable)",
        "粘贴或输入新的 API Key": "Paste or type a new API Key",
        "清除 API Key": "Clear API Key",
        "清除该平台的 Key": "Clear this provider’s Key",
        "切换明文 / 密文：用来确认 Key 到底有没有粘进去": "Toggle visibility to confirm the Key was pasted",
        "这个平台必须填 Key，否则发不出请求。": "This provider requires an API Key or requests will fail.",
        // 🗑️ 这两条随 Mock / 自定义平台与「可自填服务地址」一起删：前者是「地址栏的提示」，
        //    后者是「Mock 平台不显示 Key 输入框」时的引导语 —— 两个前提现在都不存在了。
        "点一行只是切换「在编辑哪个平台」的配置；要用某个平台说话，": "Tapping a row only switches which provider you’re editing; to talk with one,",
        "请到会话页点输入栏那颗模型名 —— 换平台也在那里。": "Go to the chat page and tap the model name in the composer — provider switching is there too.",
        "这里只决定在编辑哪个平台的配置。聊天窗口正在用哪个平台，请到聊天窗口的模型下拉里换（列表里每一项都带平台名）。": "This only selects which provider’s settings you’re editing. To change the provider used in a chat, use the model dropdown there (each entry shows its provider).",
        "这里改的是本平台的配置。会话页输入框下方可以单独切换「当前这一会儿」用的模型，两者互不覆盖。": "This edits the provider’s configuration. The chat composer can switch the model for the current session independently — the two don’t override each other.",
        "含切换平台；只改当前窗口，不影响设置里配置的": "Includes switching providers; affects only this window, not your saved settings",
        "思考模式": "Reasoning Mode",
        "开启后模型会先输出推理过程，首字等待明显变长（当前界面不展示推理内容）。": "The model will reason first, so the first token takes noticeably longer (reasoning isn’t shown yet).",
        "当前地址推导不出模型列表接口": "Can’t derive the model-list endpoint from the current base URL",
        "API Key 无效（HTTP 401）": "Invalid API Key (HTTP 401)",
        "没有查看模型列表的权限（HTTP 403）": "No permission to view the model list (HTTP 403)",
        "该服务没有 /models 接口（HTTP 404）": "This service has no /models endpoint (HTTP 404)",
        "模型列表返回格式无法识别": "Unrecognized model-list response format",
        "该服务没有返回可选模型\n用下方的手动输入吧": "The service returned no models\nUse the manual input below",
        "还没有可选模型：去「设置 → 模型」填一个模型名，或点「拉取模型列表」": "No models yet — set a model name in Settings → Model, or tap “Fetch model list”",

        // ── 「添加模型」面板（2026-10-13 按参考图重做；Mac / iOS 共用同一套文案）──
        // ⚠️ 五家供应商的名字也在这里 —— `AIProviderKind.displayName` 是 `L(...)`，
        //    所以它们**必须**有英文条目（否则英文档里冒出中文平台名）。
        "添加模型": "Add Model",
        // ⚠️ 编辑既有条目时表单标题换成这一条（两件事，用户要能确认自己在改哪一条）
        "编辑模型": "Edit Model",
        "选择供应商": "Choose Provider",
        "供应商": "Provider",
        "（仅支持 OpenAI 兼容协议 API）": "(OpenAI-compatible APIs only)",
        "深度求索": "DeepSeek",
        "智谱开放平台": "Zhipu Open Platform",
        "Kimi 中国版": "Kimi (China)",
        // 豆包（火山方舟，2026-10-16 接入）
        "豆包": "Doubao",
        // MiniMax（稀宇科技，2026-10-17 接入）—— 品牌名中英同形，但仍要走词表：
        // `AIProviderKind.displayName` 是 `L(...)`，英文档里不能冒出未登记的键。
        "MiniMax": "MiniMax",
        // ⚠️ `.custom` 这一档**不在供应商选择页里**（那一页筛掉了它，见 `AIListPickerViewController`），
        //    但手改 JSON 写成 `"vendor": "custom"` 的条目在清单页仍要能正确显示 ⇒ 这条必须留着。
        "自定义": "Custom",
        "open.bigmodel.cn · OpenAI 兼容": "open.bigmodel.cn · OpenAI-compatible",
        "api.moonshot.cn · OpenAI 兼容": "api.moonshot.cn · OpenAI-compatible",
        "ark.cn-beijing.volces.com · OpenAI 兼容": "ark.cn-beijing.volces.com · OpenAI-compatible",
        "查看文档": "View Docs",
        "模型名称": "Model Name",
        "输入你的 API Key": "Enter your API Key",
        "测试连接": "Test Connection",
        "测试中…": "Testing…",
        // 「回复生成完」本地通知（`AIReplyNotifier`，2026-10-18）。⚠️ 这是**计算属性/查表**
        // 场景：通知发出时 App 在后台，`L()` 查的是当前语言 —— 与切语言那条铁律无冲突
        // （通知是即时产物，不缓存）。
        "回复已生成": "Reply ready",
        "生成失败": "Generation failed",
        // 通知正文 = **本轮发送的文本**（2026-10-19 从「会话标题」改过来：标题是首条消息，
        //   多轮对话后文不对题）。空文本（纯附件兜底）时回落这条。
        "新消息": "New message",
        // 「显示内容预览」关掉时的通知正文（不透露用户问了什么 / 错误原因）。
        "轻点查看详情": "Tap to see details",
        // ── 「通知设置」页（2026-10-18 随设置页新增；Mac / iOS 共用同一套文案）──
        // 2026-10-19：① 删提示音三档（用户要求，通知跟随系统默认音）；
        //   ② 「前往系统设置」并入第一行 —— 系统关时第一行开关跟着关、点第一行去系统设置；
        //      系统开时第一行就是总闸本体（见 `AINotificationPreferences` 文件头）。
        "通知": "Notifications",
        "桌面通知": "Desktop Notifications",
        "启用桌面通知": "Enable Desktop Notifications",
        "显示内容预览": "Show Content Preview",
        "关闭后不再发送任何回复通知": "No reply notifications will be sent when off",
        "AI 回复生成完成或失败、且 App 不在前台时发送系统通知。": "Sends a system notification when an AI reply finishes or fails while the app is in the background.",
        "在通知中显示你发送的消息内容。": "Show the message you sent in notifications.",
        // 第一行在「系统通知关着」时的副标题 —— 同时就是「前往系统设置」的入口提示
        //   （那一行整行可点：iOS didSelectRow / Mac onTapGesture → openNotificationSettings）。
        "系统通知已关闭，轻点前往系统设置": "System notifications are off — tap to open System Settings",
        // ── 「指令」与「生成参数」两页（2026-10-20 随设置页新增；Mac / iOS 共用）────
        // ⚠️ 「恢复默认 / 清空」两条**上面已有**（账号菜单 / 别处），同键只能出现一次，
        //    这里不重复加（查重：`grep -c "\"恢复默认\": \""`）。
        "指令": "Instructions",
        "生成参数": "Generation Settings",
        "追加在每轮请求最前面的系统提示词": "A system prompt prepended to every request",
        "快捷预设": "Quick Presets",
        "通用助手": "General Assistant",
        "中译英": "Chinese → English",
        "代码审查": "Code Review",
        "已自动保存": "Saved automatically",
        "例如：你是一名严谨的技术顾问。回答先给结论，再给理由；不确定时直说，不要编造。": "e.g. You are a rigorous technical advisor — conclusion first, then reasoning. When unsure, say so; never make things up.",
        "拖动调整": "Drag to adjust",
        // 生成参数页
        "采样": "Sampling",
        "思考": "Thinking",
        "思考过程的显示与保存": "Display and storage of the thinking process",
        "温度": "Temperature",
        "最大长度": "Max Length",
        "服务端默认": "Server default",
        "越低越确定，越高越有随机性": "Lower is more deterministic, higher more random",
        "单次回复的最大 token 数": "Maximum tokens per reply",
        "展示思考过程": "Show Thinking Process",
        "关闭后，思考内容不再显示、也不再保存。": "When off, thinking content is neither displayed nor saved.",
        "关闭时使用服务端默认值": "When off, the server default is used",
        "重置为推荐值": "Reset to Recommended",
        "连接成功 · 拉到 %d 个模型": "Connected · %d models available",
        // 思考过程展示（2026-10-20，`AIReasoning` / `AIThinkingBlockMetrics`）
        "思考过程": "Thinking",
        "思考中…": "Thinking…",
        "不到 1 秒": "under 1s",
        "%.1f 秒": "%.1fs",
        "%.0f 秒": "%.0fs",
        "连接失败：%@": "Connection failed: %@",
        "保存后生效": "Applies when saved",
        "保存后清除该平台的 Key": "Clears this provider’s Key when saved",
        // ⚠️ 与上一条**是两个 key**：上面那条是「按平台」配置时代的措辞，这条是 JSON 化之后
        //    「一条配置自带 Key」的措辞。混用会让英文档里出现「这个平台的 Web」这种半截语义。
        "保存后清除这条配置的 Key": "Clears this entry’s Key when saved",
        "还缺模型名称": "Model name is missing",
        "模型名称是这条配置的标识（也是发给服务端的那个字符串），不能为空。": "The model name is this entry’s identifier — and the exact string sent to the service — so it can’t be empty.",
        "好": "OK",
        "已保存：%@": "Saved: %@",
        // Key 输入框的占位符（输入框不回填明文，占位符是唯一「已存 Key 长什么样」的提示）
        "已保存 %@ · 留空不修改": "Saved %@ — leave blank to keep",
        "命中": "Cache hit",
        "未命中": "Cache miss",
        "单价（元 / 百万 token），默认取自 DeepSeek V4-Flash 空闲时段价，随时可能过期；三项全填 0 = 不计价。": "Price (CNY / million tokens). Defaults come from DeepSeek V4-Flash off-peak pricing and may be outdated. Set all three to 0 to disable billing.",
        "单价默认取自 DeepSeek V4-Flash 空闲时段价，随时可能过期，可自行修改；三项全填 0 = 不计价。": "Defaults come from DeepSeek V4-Flash off-peak pricing and may be outdated — feel free to edit. Set all three to 0 to disable billing.",
        // 内置模型条目的说明（`AIModelCatalog.builtin(for:)`，各家几条）
        // ⚠️ 「默认」这条**两端两处共用**：模型说明（「默认 · 纯文本」）+ 设置页「字体大小」
        //    四档里的第 2 档。⛔ 别在字体大小那一段再写一份同键（字典字面量同键只能有一次）。
        "默认": "Default",
        "默认 · 旗舰": "Default · flagship",
        "旗舰 · 纯文本": "Flagship · text only",
        "支持图片": "Supports images",
        "上一代": "Previous generation",
        "长文本 128K": "Long context · 128K",
        // 2026-10-17 智谱 / Kimi 当代候选的备注
        "免费": "Free",
        "代码专精": "Code-specialized",
        // 豆包内置候选的备注（2026-10-16）
        "默认 · 均衡主力": "Default · balanced",
        "全模态理解": "Omni-modal understanding",
        "低时延低成本": "Low latency, low cost",
        "图像生成 · 不用于对话": "Image generation · not for chat",
        // 可手填模型名时的引导（iOS 选择器）
        "填服务端要求的模型标识，如 %@；要发图片用 %@。": "Enter the model ID the service expects, e.g. %@; to send images use %@.",

        // ── 设置窗（左菜单 + 右侧各页，2026-10-14 加）────────────────────────
        // ⚠️ 左栏那三个**分组标题**（设置 / 功能 / 关于）也在这张表里 —— 它们看着像通用词，
        //    但确实是本 App 设置窗的文案，英文档里必须是 Settings / Features / About。
        //    （「设置」这条本来就有，见上面「账号菜单」那一段，别重复加。）
        "通用": "General",
        "外观": "Appearance",
        "语言": "Language",
        "功能": "Features",
        "关于": "About",
        "关于 Aster": "About Aster",
        // ── 「字体大小」页（2026-10-14 加，两端设置页共用）──────────────────
        // ⚠️ 四档文案里「小 / 默认 / 大」与用户参考图上的三个标签逐字对齐；
        //    第 4 档图上没有标签（4 档是用户后加的），取名「特大」。
        // ⚠️ 「默认」这个词**可能**与别处撞义 —— 本表按中文原文做 key，
        //    同一条中文只译一次，所以这里只会有一个「默认」条目（查重用自检脚本）。
        "字体大小": "Font Size",
        "小": "Small",
        // ⚠️ 「默认」这条**不在本段**——它上面「内置模型条目的说明」那一段里已经有一条
        //    （同为 "Default"，模型说明里的「默认 · 纯文本」用的就是它）。
        //    Swift 字典字面量**同键只能出现一次**，写两份直接编译不过。
        "大": "Large",
        "特大": "Extra Large",
        "调整对话中文字的大小，立即生效": "Resizes chat text. Applies immediately",
        // 「关于」页那一行的标题（右侧显示版本号）—— 与「版本 %@」那条**刻意分开**：
        // 那条是 Mac 侧卡片的副标题（整句），这条是 iOS 行标题（一个词）。
        "版本": "Version",
        "版本 %@": "Version %@",
        "版本 %@（%@）": "Version %@ (%@)",
        "源码": "Source",
        "一个本地优先的 AI 对话客户端：会话与配置都留在本机，模型写在自己的 models.json 里。": "A local-first AI chat client — conversations and settings stay on this Mac, and your models live in your own models.json.",
        // 🗑️ 2026-10-27 删掉 `"账号：设置 / GitHub / 退出登录"`（那行账号栏的 tooltip）：
        //    账号栏已改成纯设置栏（只剩一颗齿轮，tooltip 是「打开设置」）⇒ 本条无调用点。

        // ── 「长期记忆」页（2026-10-25 加，两端设置页共用）──────────────────
        // ⚠️ 注入给模型的记忆块（【长期记忆】那一段）**不在这里** —— 那是发给模型的内容，
        //    固定中文不进词表（见 `AIMemoryStore` 文件头第 3 条）。
        // ⚠️ 2026-10-25 当天反转成**模型自动抽取**（与豆包对齐）⇒ 「记住这条」/「新记忆」/
        //    「添加记忆」/「已加入长期记忆」等手动写点词条**全部删除**；两端现在共用
        //    同一条空态引导（入口都是「上面的自动记忆」，无平台差异，⛔ 别拆成两条）。
        "长期记忆": "Long-term Memory",
        // 两个开关各管一件事：抽取侧（默认关）+ 注入侧（默认开）
        "自动记忆": "Auto Memory",
        "回答时参考": "Use When Replying",
        "每轮对话后自动提取值得记住的信息": "Automatically extracts memorable details after each reply",
        "开启后每轮对话会多一次模型调用": "When on, each reply costs one extra model call",
        "开启后，助手会在回答时参考这些记忆": "When on, the assistant refers to these memories when replying",
        "关闭后不再参考；已保存的记忆仍会保留。": "When off, they are kept but no longer used",
        "清除全部记忆": "Clear All Memories",
        "清除全部记忆？": "Clear all memories?",
        "此操作不可恢复。": "This can’t be undone.",
        "删除这条记忆？": "Delete this memory?",
        "还没有记忆。开启上面的「自动记忆」，助手会在每轮对话中记住你的事，可在这里查看和删除。": "No memories yet. Turn on “Auto Memory” above and the assistant will remember things from your conversations — you can review and delete them here.",
        "%d 条记忆": "%d memories",
        "保存在 %@，可在「文件」App 中查看。": "Saved in %@. View it in the Files app.",
        // ── 以下 4 条是 **Mac 设置窗**专用（iOS 侧没有对应形态）─────────────────
        // ⚠️ 与上面那条 iOS 尾注**故意各写一条**：macOS 上放文件的地方叫「访达」，
        //    照抄「文件」App 在这一端是一句错话（⛔ 别为了少一行合并）。
        "保存在 %@，可在「访达」中查看。": "Saved in %@. View it in Finder.",
        "记住你希望助手跨会话记得的事，回答时会参考。": "Things you want the assistant to remember across sessions.",
        "新的在前；点行尾图标删除。": "Newest first; click the icon at the end of a row to delete.",
        "记忆文件读取失败：%@。显示的是上次的内容，请检查文件格式。": "Failed to read the memory file: %@. Showing the last known contents — please check the file format.",

        // ── 「自定义模型」清单页（2026-10-14 加）──────────────────────────────
        // ⚠️ 这一页 2026-10-14 之前的文案**一直没进词表**（上一轮只补了「添加模型」那套）
        //    ⇒ 英文档下这一整页都是中文。本轮随设置窗一起补齐。
        "自定义模型": "Custom Models",
        "模型添加后会写入到本地 %@ 文件中。": "Models are written to the local %@ file.",
        "还没有自定义模型": "No custom models yet",
        "点右上角「添加模型」加一条": "Click “Add Model” in the top-right to add one",
        "编辑这一条": "Edit this entry",
        "打开该供应商的文档": "Open this provider’s docs",
        "删除这一条": "Delete this entry",
        "删除「%@」？": "Delete “%@”?",
        "会从 models.json 里移除这一条（含它存的 API Key），无法撤销。": "This removes the entry — including its saved API Key — from models.json. It can’t be undone.",
        "这个文件读不出来：%@\n下面显示的是上一次能读到的内容；改好文件后回到这一页即生效。": "Couldn’t read this file: %@\nShowing what could be read last time — fix the file and come back to this page.",
        "改完文件记得回到这一页 —— 内容会自动重新读一遍（不必重启 App）。": "After editing the file, come back to this page — it reloads automatically (no App restart needed).",

        // ── 设置：用量与计费 ───────────────────────────────────────────────
        "用量与计价": "Usage & Pricing",
        "用量与计费": "Usage & Billing",
        "累计用量": "Total Usage",
        "清零": "Reset",
        "清零统计": "Reset Stats",
        "清零累计用量": "Reset total usage",
        "清空": "Clear",
        "清除": "Clear",
        "已清除": "Cleared",
        "已取消": "Cancelled",
        "只清空「用量与计费」的累计统计，不影响任何会话与消息。": "Only clears the Usage & Billing totals — no chats or messages are affected.",
        "单价（元 / 百万 token）": "Price (CNY / million tokens)",
        "输入 · 缓存命中（元 / 百万 token）": "Input · cache hit (CNY / million tokens)",
        "输入 · 缓存未命中（元 / 百万 token）": "Input · cache miss (CNY / million tokens)",
        "输出（元 / 百万 token）": "Output (CNY / million tokens)",
        "缓存命中输入": "Cache-hit input",
        "输出": "Output",
        "默认值取自 DeepSeek V4-Flash 空闲时段价，随时可能过期，可自行修改。": "Defaults come from DeepSeek V4-Flash off-peak pricing and may be outdated — feel free to edit.",

        // ── 提示条 / toast / 本地错误 ──────────────────────────────────────
        "AI 助手": "AI Assistant",
        "当前没有网络连接": "No network connection",
        "网络连接不可用": "Network unavailable",
        "网络连接中断": "Network connection lost",
        "连接不上服务器": "Can’t reach the server",
        "请求超时": "Request timed out",
        "请求失败": "Request failed",
        "配置有误": "Configuration error",
        "未获得麦克风或语音识别权限，请在系统设置里开启": "Microphone or speech recognition permission not granted — enable it in Settings",
        "未获得麦克风或语音识别权限，请在设置中开启": "Microphone or speech recognition permission not granted — enable it in Settings",
        "请先在设置中开启麦克风与语音识别权限": "Enable microphone and speech recognition in Settings first",
        "当前设备没有可用的相机": "No camera available on this device",
        "无法使用相机": "Camera unavailable",
        "请在系统设置里允许访问相机，才能拍照发给 AI。": "Allow camera access in Settings to take photos for the AI.",
        "去设置": "Open Settings",
        "上下文已超出模型上限，这一轮可能失败": "Context exceeds the model limit — this turn may fail",
        "没能发出去，检查一下模型配置": "Couldn’t send — check the model configuration",
        "还没能发出去，检查一下模型配置": "Couldn’t send — check the model configuration",
        "扫一扫功能开发中": "Scan feature coming soon",
        "渲染进程被系统回收了": "The render process was reclaimed by the system",
        "这一轮没有可重新提问的内容": "Nothing to re-ask in this turn",
        "这条回复后面已经有新消息了，直接接着问吧": "There are newer messages after this reply — just ask again",
        "⚠️ 模型没有返回内容\n换个说法再试一次，或检查该模型的名称是否正确": "⚠️ The model returned no content\nTry rephrasing, or check the model name",
        "⚠️ 回复被系统中断\nApp 在后台停留过久，已保留收到的内容；点「重试」继续": "⚠️ Reply interrupted by the system\nThe app was backgrounded too long; what arrived was kept — tap “Retry” to continue",

        // ── HTTP / 网络错误（带参用 %d）─────────────────────────────────────
        "请求格式有误（HTTP 400）": "Bad request (HTTP 400)",
        "多半是模型名或参数不对，去设置里检查": "Usually a wrong model name or parameter — check your settings",
        "API Key 无效或未授权（HTTP 401）": "Invalid or unauthorized API Key (HTTP 401)",
        "去设置里检查该平台的 API Key": "Check this provider’s API Key in Settings",
        "账户余额不足（HTTP 402）": "Insufficient balance (HTTP 402)",
        "请到该平台充值后再试": "Top up your account on that platform and try again",
        "无权访问该模型（HTTP 403）": "No access to this model (HTTP 403)",
        // 🔴 2026-10-17：403 的第二种语义 = 欠费（方舟 AccountOverdueError）。
        //    与 404 分层同一个道理：只按状态码猜会把用户引去查一个没问题的权限。
        "账户欠费（HTTP 403）": "The account has an overdue balance (HTTP 403)",
        "去火山方舟控制台充值后再试": "Top up in the Volcengine Ark console, then try again",
        "检查当前账号有没有该模型的权限": "Check whether your account has access to this model",
        "接口地址不存在（HTTP 404）": "Endpoint not found (HTTP 404)",
        // 🔴 2026-10-17：方舟 404 的 body 是 InvalidEndpointOrModel.NotFound ——
        //    问题在模型名/开通状态，不在地址（豆包地址由代码强制预设、无填写入口）。
        "模型不存在或没有访问权限（HTTP 404）":
            "The model doesn’t exist or this key has no access to it (HTTP 404)",
        "核对「模型名」是否填对；或去控制台确认已开通该模型":
            "Check that the model name is correct, or confirm the model is enabled in the console",
        "服务端拒绝（HTTP 404）：%@": "Rejected by the server (HTTP 404): %@",
        "地址要填到完整路径，如 /chat/completions": "Enter the full path, e.g. /chat/completions",
        "请求太频繁（HTTP 429）": "Too many requests (HTTP 429)",
        "稍等片刻再发一次": "Wait a moment and resend",
        "服务端异常（HTTP %d）": "Server error (HTTP %d)",
        "请求失败（HTTP %d）": "Request failed (HTTP %d)",
        "稍后重试，或换个平台": "Try again later, or switch providers",
        "稍后重试；开了思考模式会等更久": "Try again later; reasoning mode takes longer",
        "检查网络后重发": "Check your connection and resend",
        "确认服务地址；本地 mock 需先启动服务": "Verify the base URL; local mock requires starting the server first",
        "网络异常（%d）": "Network error (%d)",
        "%@ 还没填 API Key，去设置里填一下": "%@ needs an API Key — add one in Settings",
        "%@ 的服务地址无效，去设置里检查一下": "%@ has an invalid base URL — check it in Settings",
        "%@ 还没填模型名，去设置里填一下": "%@ needs a model name — add one in Settings",
        "%@ 的「%@」不支持图片，把模型名换成 %@ 再发": "%@’s “%@” doesn’t support images — switch the model to %@ and resend",

        // ── 右侧面板 / 网页 / 文件 ─────────────────────────────────────────
        "网页": "Web",
        "本地内容": "Local Content",
        "新标签页": "New Tab",
        "关闭标签页": "Close Tab",
        "关闭当前标签页": "Close Current Tab",
        "后退": "Back",
        "前进": "Forward",
        "重新加载": "Reload",
        "适配宽度": "Fit Width",
        "打开": "Open",
        "打开文件": "Open File",
        "打开文件夹": "Open Folder",
        "打开右侧页面（起始页：输入网址 / 打开本地文件）": "Open the right panel (start page: enter a URL / open a local file)",
        "收起右侧页面（标签保留，随时再点回来）": "Collapse the right panel (tabs kept; click to reopen)",
        "展开右侧页面（标签都还在）": "Expand the right panel (tabs still there)",
        "选一个文件，在右侧面板里预览": "Choose a file to preview in the right panel",
        "选一个文件夹，在右侧面板里浏览": "Choose a folder to browse in the right panel",
        "从磁盘上选一个文件，在右侧面板里预览": "Pick a file from disk to preview in the right panel",
        "从磁盘上选一个文件夹，在右侧面板里以目录树展开": "Pick a folder from disk to expand as a tree in the right panel",
        "打不开这个文件夹": "Can’t open this folder",
        "这个文件夹是空的": "This folder is empty",
        "没有匹配项": "No matches",
        "根目录": "Root",
        "无法预览这个文件": "Can’t preview this file",
        "这个文件不是纯文本，打不开。": "This file isn’t plain text — can’t open it.",
        "文件较大，未做语法高亮": "File is large — syntax highlighting skipped",
        "代码": "Code",
        "打不开这个网址：找不到服务器。": "Can’t open this URL — server not found.",
        "网页加载失败。": "Failed to load the page.",
        "这个网站只支持 http，被系统的安全策略拦住了。": "This site only supports http, which the system security policy blocks.",
        "加载超时，可能是网络太慢或对方服务器没响应。": "Timed out — the network may be slow or the server isn’t responding.",
        "网络不可用，请检查网络后返回重试。": "Network unavailable — check your connection and try again.",
        "网络似乎断开了。": "It seems the network is down.",
        "检查一下 Wi-Fi 或有线连接。": "Check your Wi-Fi or wired connection.",

        // ── 拖拽 / 附件格式 ────────────────────────────────────────────────
        "拖进来的不是文件。从访达拖文件或图片过来，或者用输入框的「+」选一个。": "That wasn’t a file. Drag files or images from Finder, or use the “+” in the composer.",
        "文件夹不能一条发出去。请拖它里面的文件，或者用输入框的「+」选一个。": "Folders can’t be sent as one item. Drag the files inside, or use the “+” in the composer.",
        "TXT · MD · JSON · CSV · 代码等 29 种": "TXT · MD · JSON · CSV · 29 code types",
        "任意文件（文件夹不支持）": "Any file (folders not supported)",

        // ── 截图 / 权限引导 ────────────────────────────────────────────────
        "还没有「屏幕录制」权限。": "Screen Recording permission not granted yet.",
        "去「系统设置 → 隐私与安全性 → 屏幕录制」里勾上本 App，": "Enable this app under System Settings → Privacy & Security → Screen Recording,",
        "然后退出重开本 App（授权要重启才生效），再试一次。": "then quit and reopen the app (the grant takes effect after a restart) and try again.",
        "若一直失败，去「系统设置 → 隐私与安全性 → 屏幕录制」里确认本 App 已勾上。": "If it keeps failing, make sure this app is checked under System Settings → Privacy & Security → Screen Recording.",
        "截出来的图读不出来": "Couldn’t read the captured image",
        "截图存不进附件目录（磁盘满了？）": "Couldn’t save the screenshot to the attachments folder (disk full?)",
        "去「设置」开启相册权限，这里就能选图": "Allow Photos access in Settings to pick images here",

        // ── 带参数文案（调用处套 `String(format:)`；`%@` 填字符串、`%d` 填整数）──
        // ⚠️ ⛔ **别用 `\(…)` 插值** —— 那种串没法进词表（key 会随值变），必须写成 `%@` / `%d`。
        //    ⚠️ 中文原文里因此**不能出现裸 `%`**（会被当格式符）。
        "、": ", ",
        "未填写": "Not set",
        "该地址": "This address",
        "%@ · 来自「%@」": "%@ · from “%@”",
        "%@\n可以点右上角重试，或用下方的手动输入": "%@\nRetry from the top-right, or use the manual input below",
        "%@ 没有 https。用默认浏览器就能看。": "%@ has no https. Open it in your default browser to view.",
        "%d 条结果": "%d results",
        "%d 个文件夹跳过了（文件夹发不了）": "%d folders skipped (folders can’t be sent)",
        "%d 个读不进来：%@": "%d couldn’t be read: %@",
        "「%@」不需要 API Key。": "“%@” doesn’t require an API Key.",
        "「%@」将从对话列表中移除，且无法恢复。": "“%@” will be removed from the chat list. This can’t be undone.",
        "「%@」的全部消息都会被删除，无法恢复。": "All messages in “%@” will be deleted. This can’t be undone.",
        "一条消息最多 %d 个附件": "Up to %d attachments per message",
        "一条消息最多带 %d 个附件": "Up to %d attachments per message",
        "一条消息最多带 %d 个附件，多出来的没加上": "Up to %d attachments per message; the rest weren’t added",
        "上下文较长，已省略最早 %d 条消息": "Long context — earliest %d messages omitted",
        "出错了：%@": "Error: %@",
        "分享这 %d 个文件": "Share these %d files",
        "删除(%d)": "Delete (%d)",
        "删除选中的 %d 条消息？": "Delete the %d selected messages?",
        "域名：%@": "Domain: %@",
        "填服务端要求的模型标识，如 deepseek-flash；要发图片用 %@。": "Enter the model ID the server expects, e.g. deepseek-flash; use %@ to send images.",
        "将清除「%@」已保存的 Key，需要重新输入才能使用该平台。": "This will clear the saved Key for “%@”. You’ll need to enter it again to use this provider.",
        "已删除": "Deleted",
        "已删除 %d 条": "Deleted %d",
        "已选择 %d 条": "%d selected",
        "引用了%@的消息：%@": "Quoted %@’s message: %@",
        // 「供应商 · 状态」那一版（清单页行尾用：`深度求索 · 还没配齐`）——
        // ⚠️ 2026-10-16：原来这里还有一对「当前使用」词序相反的 key（选择器副标题 / 清单页
        //    行尾各一个），用户要求去掉字样后**两个 key 一起删**（全端已无调用点）。
        "%@ · 还没配齐": "%@ · Not ready",
        "%@ · 画图专用": "%@ · Image generation only",
        "当前模型 %@，点按切换模型": "Current model: %@ — tap to switch",
        "当前模型：%@（点这里换，列表里每一项都带平台名）": "Current model: %@ (click here to switch; each entry shows its provider)",
        "当前生效：%@（换平台请到会话页点那颗模型名）": "Active: %@ (to switch providers, tap the model name in the chat composer)",
        "打开右侧页面（上次看的是 %@）": "Open the right panel (last viewed: %@)",
        "找不到这个网站。": "Can’t find this site.",
        "拉到 %d 个模型": "Fetched %d models",
        "拉取失败：%@（可手填模型名）": "Fetch failed: %@ (you can type a model name manually)",
        "文件太长，只显示前 %d 行": "File too long — showing only the first %d lines",
        "最多带 %d 个附件": "Up to %d attachments per message",
        "最多输入 %d 字": "Up to %d characters",
        "服务地址：%@": "Base URL: %@",
        "模型：%@": "Model: %@",
        "正在编辑：%@": "Editing: %@",
        "点消息来选择要删除的内容": "Tap messages to choose what to delete",
        "系统截图工具起不来：%@": "The system screenshot tool couldn’t start: %@",
        "网站没有响应（超时）。": "The site didn’t respond (timed out).",
        "网页打不开（%@）": "Can’t open the page (%@)",
        "请选择要删除的消息": "Select the messages to delete",
        "读不出这个文件：%@": "Couldn’t read this file: %@",
        "这个文件太大（%@），没有以文本方式打开。": "This file is too large (%@) — opened as text is disabled.",
        "这些文件读不进来：%@": "Couldn’t read these files: %@",
        // 切换模型的居中系统消息（`AIModelSwitch.noticeText`，两端共用一份）
        "—— 模型已从 %@ 更改为 %@ ——": "—— Model switched from %@ to %@ ——",

        // ── 单次 token 用量（`ChatRowActionBar` 栏尾，2026-10-25）───────────
        // ⚠️ 那条显示**当天就被用户要求隐藏**了（原话「算了 这个功能还是隐藏吧」），
        // 词条刻意留着：恢复时要用的就是这两句（栏上只报合计，拆分只进悬停提示）。
        "共消耗": "Used",
        "输入 %@ · 输出 %@ · 合计 %@": "In %@ · Out %@ · Total %@",

        // ── 时间（`AIMessageTime` 的 dateFormat，英文档换本地格式）───────────
        "昨天": "Yesterday",
        "昨天 HH:mm": "'Yesterday' HH:mm",
        "M月d日": "MMM d",
        "M月d日 HH:mm": "MMM d HH:mm",
        "yyyy年M月d日": "MMM d, yyyy",
        "yyyy年M月d日 HH:mm": "MMM d, yyyy HH:mm",
    ]
}

/// 查表的**唯一调用形态**（短名字是为了让几百处调用点不至于满屏噪声）。
///
/// ## 🔴 它**会**登记观察依赖（2026-10-13 第三版）—— 这一点是整个切语言机制的地基
/// 第一行读一次 `AILanguageRevision.shared.value`：凡是在 SwiftUI **body 求值期**调过
/// `L()` 的视图，都会因此登记到「语言版本号」这条依赖上 ⇒ 切语言时**各自**重算。
/// ⚠️ 所以「切语言后文案不翻」这类 bug 的判据是：**那一处是不是在 body 里调的 `L()`**；
///    ⛔ 别再用 `.id(...)` 换身份去救（两个结构性代价见文件头）。
/// ⚠️ `@available` 那一层是给 **iOS 15 / 16** 的：那边没有 Observation，退回
///    「iOS 重建 rootViewController」那条老路（`L()` 在 `viewDidLoad` 期求值，够用）。
public func L(_ zh: String) -> String {
    if #available(iOS 17.0, macOS 14.0, *) { _ = AILanguageRevision.shared.value }
    return AILocalization.text(zh)
}

