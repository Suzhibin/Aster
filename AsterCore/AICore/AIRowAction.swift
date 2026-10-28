import Foundation

/// 助手回复可执行的操作。
///
/// **气泡下方的操作栏**与**长按弹出的操作卡**共用这一份定义：两处都从这里取 icon / title，
/// 不会再出现「菜单里改了名字、操作栏没跟上」这类漂移；新增一项操作只需加一个 case，
/// 两个入口自动都出现（点下去做什么由 `AIModuleViewController.performRowAction` 统一处理）。
///
/// `rawValue` 只是**按钮标识**（操作栏的 `tag` 用的是数组下标，见 `AIActionBarView`），
/// **没有任何持久化** —— 所以插入新 case 是安全的。
/// 但一旦把「喜欢 / 不喜欢」这类**状态**按 rawValue 存起来（UserDefaults / 数据库），
/// 顺序就再也不能动了 —— 那时请改成显式赋值或另加稳定 id。
///
/// ⚠️ 操作卡是**两段布局**（顶部横排 `grid` + 竖排整行 `list`），分界**显式声明**、不靠数组长度推断，
/// 见文件末尾的 `Menu`。各入口显示哪些动作由 `barActions` / `chatMenu(for:)` 决定；
/// **新增一项操作的标准流程**是：加 case → 选好它属于哪一段 → 在 `performRowAction` 加分支。
public enum AIRowAction: Int, CaseIterable {
    case copy
    case speak
    case like
    case dislike
    case share
    /// 把这张图片**存回系统相册**（2026-10-08 加，**只出现在用户自己发的图片行上**）。
    ///
    /// ## 为什么只给用户侧
    /// 用户发的那张图是**本地附件**（`AIAttachmentStorage` 落盘的那份）⇒ 存进相册是一次本地写入。
    /// 助手侧的图是**远程 URL** ⇒ 要先下载才能写进相册，那是另一条链路（进度 / 失败 / 体积），
    /// 一次授权失败还会牵连「分享」。⛔ 别顺手把助手侧也加上——真要做，单独一条分支。
    ///
    /// ⚠️ 与「分享」的区别：分享交给系统面板（用户可以选「存储到文件」等任意目标），
    /// 这一项是**直接写进「照片」App**，一步到位但没有选择余地。
    case save
    /// 进入「选中文字」态（原生长按选字 UI：放大镜 / 拖柄 / 编辑菜单）。
    ///
    /// ⚠️ 它**本来是长按气泡直接触发的**，但那个分流与「长按弹操作卡」抢同一条长按手势
    /// （用户实测冲突：想选字弹了菜单、想弹菜单进了选字）。现在长按一律弹卡，
    /// 选字作为操作卡里的**竖排第一项**（位置由用户指定）。
    case selectText
    /// 引用这一条，然后再提问。
    ///
    /// 服务端没有「引用」这个字段（OpenAI 兼容格式里都没有），所以引用是**本地概念**：
    /// 落库进 `ai_quote` 表、界面上画成气泡里的一条，发送时把被引用的正文写进请求正文
    /// （见 `AIQuote.contextText`）。用户 / 助手消息都能被引用。
    case quote
    /// 编辑这条自己发的消息，然后重发（**只出现在用户消息上**）。
    ///
    /// 语义是「改完之后，从我这句话重新往下走」——所以它会**截断**这条之后的所有消息
    /// （见 `AIChatManager.editAndResend`）。这与「重新生成」（只撤助手那条回复）不是一回事。
    case edit
    /// 重新生成这一条回复（**只出现在助手消息上**）。
    ///
    /// ⚠️ 入口**只剩气泡下方操作栏**（`barActions`）—— 长按操作卡里已按产品要求移除它
    /// （见 `assistantMenu`）。操作栏只挂在「当前会话最后一条已结束的文本回复」上，
    /// 所以这个 case 与 `performRowAction` 里的分支都**不是**可删的死代码，别顺手清掉。
    case regenerate
    /// 重试（**只出现在失败提示行上**）：语义就是「把这一轮再问一次」
    case retry
    /// **接着上一段往下写**（只出现在「没写完就结束了」的助手回复上）。
    ///
    /// 与「重新生成」是相反的两件事，别混：
    /// - 「重新生成」= 撤掉这条回复**整段重写**（`regenerate`，会**删行**）；
    /// - 「继续生成」= **保留已有的半截正文**，让模型接着往下写（`continueGeneration`，不删行）。
    ///
    /// ⚠️ 只在 `block.endedTruncated == true` 的行上出现（见 `chatMenu(for:)`）——
    /// 已经写完的回复给它，点下去只会白得一段重复的话。
    case continueGeneration
    /// 进入**多选删除**（这一条所在的「一整轮」默认勾上，用户自己加减，再确认删）。
    ///
    /// 位置由产品指定（2026-09-18）：**长按操作卡的竖排最后一项**。三个菜单都有它。
    ///
    /// ⚠️ 它**不再直接删**（2026-09-18 改）：点下去只是让列表进「选择模式」——
    /// 每行左侧长出系统勾选圆圈、导航栏变成「取消 / 删除(N)」，完整实现在 `+Selection.swift`。
    /// 两条硬约束仍然成立（删除是**不可恢复**的：内存里删了、库里也删了，没有撤销）：
    /// ① 按「删除(N)」后**还要过一次二次确认**，不直接删；
    /// ② **流式进行中不出现**（见 `blockedWhileStreaming`）—— 删行会让后面所有行的下标前移，
    ///    而流式正靠 `streamingRowIndex` 定位那一行。
    case delete

    /// SF Symbol 名（默认态）
    public var icon: String {
        switch self {
        case .copy:       return "doc.on.doc"
        case .speak:      return "speaker.wave.2"
        case .like:       return "hand.thumbsup"
        case .dislike:    return "hand.thumbsdown"
        case .share:      return "square.and.arrow.up"
        // 「方框 + 箭头向下」= 存进本机（与「分享」的箭头向上正好相反，一眼能分开）
        case .save:       return "square.and.arrow.down"
        case .selectText: return "text.cursor"
        case .quote:      return "text.quote"
        case .edit:       return "square.and.pencil"
        case .regenerate: return "arrow.clockwise"
        case .retry:      return "arrow.clockwise"
        // `text.append` = 在文本末尾追加，正是「接着往下写」的语义
        case .continueGeneration: return "text.append"
        // 垃圾桶图标 + 红色（`isDestructive`）：这是全卡唯一的危险色，一眼能认出来
        case .delete:     return "trash"
        }
    }

    /// 播放中态的图标（只有 `.speak` 用得上，其余回落到 `icon`）。
    ///
    /// 状态**不放进这里**——`AIRowAction` 是纯定义，不该知道运行时有没有在朗读；
    /// 由 `AIActionBarView.setSpeaking(_:)` 决定当前该显示哪一个。
    public var activeIcon: String {
        self == .speak ? "stop.circle" : icon
    }

    /// 操作卡里的文案
    public var title: String {
        switch self {
        case .copy:       return L("复制")
        case .speak:      return L("朗读")
        case .like:       return L("喜欢")
        case .dislike:    return L("不喜欢")
        case .share:      return L("分享")
        case .save:       return L("保存到相册")
        case .selectText: return L("选取文字")
        case .quote:      return L("引用")
        case .edit:       return L("编辑")
        case .regenerate: return L("重新生成")
        case .retry:      return L("重试")
        case .continueGeneration: return L("继续生成")
        case .delete:     return L("删除")
        }
    }

    /// 是否会打断当前对话（点了就要重发一次请求）。
    /// 流式进行中要把这些项置灰：正在生成时再点「重新生成」，两个流会互相踩。
    /// 「继续生成」同属这一类 —— 它也会先 `stop()` 再起一条新流。
    public var restartsStream: Bool { self == .regenerate || self == .retry || self == .continueGeneration }

    /// 是否是**破坏性**动作（画成红色）。当前只有「删除」。
    ///
    /// ⚠️ 与 `blockedWhileStreaming` 是**两件事**：这个只管配色，那个管「流式中给不给」。
    /// 现在两者恰好都只有 `.delete`，但将来加「清空」这类动作时它们会分开走。
    public var isDestructive: Bool { self == .delete }

    /// **流式进行中要从操作卡里摘掉**的动作（弹卡时过滤用）。
    ///
    /// 两类：
    /// - `restartsStream`：会起第二条流，与正在跑的那条互相踩；
    /// - `.delete`：删行会让它后面所有行的下标前移，而流式正靠 `streamingRowIndex`
    ///   定位那一行（`didUpdateStreamingText` 直接按下标写 cell）→ 删掉前面几行之后，
    ///   回复会被写进**别人**的气泡里。
    ///
    /// ⚠️ 弹卡时**用这个属性过滤、别再用 `restartsStream`** —— 后者只表达「会重发请求」，
    /// 删除不重发，但它同样不能与流式共存。
    public var blockedWhileStreaming: Bool { restartsStream || self == .delete }
}

// MARK: - 各入口显示哪些动作

extension AIRowAction {

    /// **气泡下方那一条横排操作栏**显示的动作。
    ///
    /// 复制 / 朗读 / 分享 / 重新生成。
    /// 「喜欢 / 不喜欢」不在本栏，且**已从所有入口移除**（2026-09-18 产品要求）：`.like/.dislike`
    /// 的 case、图标、文案与执行分支都还在（`performRowAction` 里那两条只弹 toast），
    /// 但**当前没有任何菜单会把它们渲染出来** —— 想恢复就把它们加回某个 `Menu` 的 `grid`/`list`。
    /// 「选取文字」也不在本栏 —— 它归长按操作卡。
    ///
    /// **为什么「重新生成」放最右**：它是本栏唯一带破坏性的动作（会先 `stop()` 再重发），
    /// 摆在最右与最常点的「复制」（最左）拉开最大距离，降低误触。
    /// ⚠️ **本栏是「重新生成」现在唯一的入口**（长按操作卡里已移除）—— 从这儿删掉等于删功能。
    /// ⚠️ 操作栏只在**没有任何行在流式**时出现（`AIChatManager.applyActionBarFlags`），
    /// 所以它上面的 `restartsStream` 项不需要额外置灰 —— 流式中这条栏根本不存在。
    ///
    /// 数量受屏宽约束：`30×n + 12×(n-1) + 左右留白 12×2 ≤ 屏宽`；四颗 = 156pt。
    /// 而 `allCases` 有 8 项 = 324pt，在 375pt 屏上会顶到边 —— 所以这里永远是**显式子集**。
    public static let barActions: [AIRowAction] = [.copy, .speak, .share, .regenerate]

    /// 操作卡的**两段布局**：顶部横排 + 竖排整行。
    ///
    /// **为什么显式分两段，而不是「前 3 个进横排」**：竖排第一项是谁是**产品指定**的
    /// （本工程要求「选取文字」永远第一个）。按「前 N 个」的隐式规则，一旦某个集合凑不满
    /// 横排的格子数，那一项就会滑进横排；流式时横排被过滤掉「重新生成」后只剩 2 项，
    /// 后面那一项也会顺势补进横排 —— 位置随运行状态漂移，用户会觉得「菜单会自己变」。
    public struct Menu {
        /// 顶部横排：`icon` 在上、`title` 在下的等宽格子（当前最多 3 格）
        public let grid: [AIRowAction]
        /// 竖排整行：`icon` 在左、`title` 在右。**数组第一项 = 用户看到的第一条竖排项**
        public let list: [AIRowAction]
    }

    /// 普通助手消息的操作卡。
    ///
    /// **横排三项固定为：复制 / 朗读 / 引用**（顺序由产品指定）。这三个是「拿这条回复本身做的事」——
    /// 搬运它的内容（复制）、听它（朗读）、把它当下一问的上下文（引用），概念上同一组，
    /// 所以放最显眼的第一排。
    ///
    /// ⚠️ **横排里没有「重新生成」**（产品要求移除，2026-09-17）。它现在只剩**气泡下方操作栏**
    /// 一个入口（`barActions`）—— 也就是长按**历史**助手消息时不再能重新生成，只有当前会话
    /// **最后一条已结束的文本回复**才带操作栏。这是刻意的取舍，不是漏接线。
    ///
    /// 竖排四项：选取文字 / **继续生成** / 分享 / **删除**（「喜欢 / 不喜欢」已于
    /// 2026-09-18 从所有入口移除；「删除」仍在**竖排最后一位**）。
    ///
    /// 「继续生成」插在 `selectText` **之后**、`share` **之前**，三个理由：
    /// ① 竖排第一项永远是「选取文字」（产品指定，不许动）；
    /// ② 被它挤下去的 `share` 只是下移一位，顺序仍是「常用的在上」；
    /// ③ **它是条件项**（只有 `block.endedTruncated` 的行才渲染出来，见 `chatMenu(for:)`），
    ///    所以这一份数组同时服务「写完的回复」和「没写完的回复」两种行，不需要第二份 `Menu`。
    /// ⚠️ 「记住这条」2026-10-25 上线当天即被用户拍板移除（记忆改成模型自动抽取，
    ///    与豆包对齐，见 `AIMemoryStore` 文件头第 1 条）——⛔ 别顺着旧印象加回来。
    /// ⚠️ 代码块的「复制」**不在操作卡里**：代码卡片自己带一颗常驻的复制按钮
    /// （见 `AICodeBlockView`），不需要再占一个菜单项。
    /// 竖排第一项「选取文字」是产品指定的固定位置，
    /// 所以引用换到横排只能靠**显式分段**（`grid` / `list`）表达 —— 按「前 N 个进横排」的隐式
    /// 规则，流式过滤一变它就会滑回横排，位置随运行状态漂移。
    /// 「删除」放最后同样是**位置约定**：它是唯一破坏性项，离最常用的复制/选取最远，降误触。
    public static let assistantMenu = Menu(
        grid: [.copy, .speak, .quote],
        list: [.selectText, .continueGeneration, .share, .delete]
    )

    /// **失败提示行**的操作卡。
    ///
    /// 失败行有三个有意义的动作：重试、复制报错信息、删除。
    /// 「删除」在这里格外有用：失败这一轮的**提问**大概率也发不出去（Key 没填 / 图太大），
    /// 留着它下一轮还会把同样的失败原样带一遍 —— 删掉整轮才是真正的收拾干净。
    /// 喜欢/不喜欢/朗读/重新生成对一个「HTTP 402 提示」毫无意义 ——
    /// 给全量的话，用户会在一堆无效项里找不到那个唯一有用的按钮。
    /// 也没有「选取文字」：报错文案是系统提示，复制整段已经够了。
    public static let errorMenu = Menu(grid: [.retry, .copy], list: [.delete])

    /// **模型切换系统消息**（`.modelSwitch`）的操作卡 —— **空集合**。
    ///
    /// 用户原话：「不用有任何点击事件和交互，就是系统消息」⇒ 长按什么都不弹。
    /// ⚠️ 宿主 `presentActionMenu` 有 `guard !actions.isEmpty else { return }`，
    ///    所以返空就是「静默不弹」；这里显式给一份空 `Menu` 而不是让调用方写 if ——
    ///    分发点仍然只有 `chatMenu(for:)` 这一个（两个入口迟早会分叉）。
    public static let systemNoticeMenu = Menu(grid: [], list: [])

    /// **附件行（图片 / 视频 / 文件）**的操作卡 —— 只留「分享 + 删除」。
    ///
    /// 2026-09-29 用户要求：「iOS 端 图片和视频 cell 长按弹窗 只留分享和删除」。
    /// 2026-10-06 用户要求把**文件行**也纳进来：「我发送的消息如果是文件，长按
    /// 只有分享和删除，和我发送的图片一样」⇒ 三者的判据是同一个
    ///（见下面「为什么摘掉」那段：**附件本身没有正文**，对正文做的事都不成立）。
    ///
    /// ## 为什么全竖排（`grid: []`）
    /// 两项里「删除」按既有约定**永远在竖排末位**（见 `assistantMenu` 那段），
    /// 剩下的「分享」单独进横排会是一格居中、上下留白的空落落形态（与
    /// `errorMenu` 的「两格横排」不同，那边横排是**满的**）⇒ 两行竖排最整齐、也最短。
    /// `AIChatActionMenuView` 对 `gridCount == 0` 有专门处理（`totalRowCount` / `listStartY`）。
    ///
    /// ## 为什么摘掉「选取文字 / 复制 / 朗读 / 引用」
    /// 这五项都是**对正文做的事**，而图片 / 视频 / 文件**本身没有正文**：
    /// - 「选取文字」「朗读」在附件行上本来就会弹「这条没有可选取/可朗读的文字」；
    /// - 「复制」「引用」取的是**同一条回复里的文字**（见 `actionText(atRow:)`）——
    ///   用户长按的是一个附件，拿到的却是隔壁那段文字，语义是拧的。
    /// - 「编辑」对附件行更是无效项（点下去只弹「这条没有可编辑的文字」）。
    ///
    /// ⚠️ 文件行按这条判据也**属于附件**：它的「复制」复的是**文件名**（`block.text`）、
    /// 「引用」取的是**同轮文字** —— 两者都**不是文件本身**，与长按一张图拿到隔壁文字同理。
    /// 2026-09-29 当时把文件行留在 `userMenu`、理由是「文件名复制、引用仍然有意义」；
    /// 2026-10-06 用户选定按图片的口径统一（见上面那行），该理由作废。
    ///
    /// ## 🔴 「分享」在本菜单里的语义**不同**
    /// 分享的是**附件本身**，不是同一条回复的文字：
    /// 图片 / 视频 / 文件是本地文件 ⇒ 直接分享文件；助手侧是远程地址 ⇒ 分享链接。
    /// ⚠️ 这也是「只剩分享」之后必须一起修的隐患：附件行**没有同轮文字**时，
    /// 旧实现在 `actionText` 的退化分支里会把 `file:///...` 当分享内容，
    /// 分享出去是一串没用的地址（实现见 `AIModuleViewController+RowAction.shareRow(at:)`
    /// 的 `mediaShareURL(of:)`）。
    /// ⛔ 所以**每加一种 `kind` 都要同步给 `mediaShareURL` 加分支** —— 漏了不会编译报错，
    /// 只会让那一类的「分享」悄悄退化成 `file:///...`（`actionText` 的兜底会兜住，
    /// 兜出来的正是那个没用的地址）。
    /// ⚠️ 这条**只对附件行成立**：文字行的「分享」仍分享正文。
    ///
    /// ## 覆盖范围
    /// ⚠️ 图片（`.image`）、视频（`.video`）、文件（`.file`）共用这一份，且**不分 role**——
    /// 用户发的图与助手侧的图给**同一套**菜单（2026-09-29 用户选定「所有图片/视频行」）；
    /// 文件行在实际数据里只有用户侧（`.file` 只由附件面板产生），但不写 role 判断，
    /// 免得将来助手侧也能发文件时两处口径分叉。
    /// 🔴 **2026-10-08 起有一处例外**：**用户侧图片**已改走下面的 `userImageMenu`（多一项「保存到相册」）
    /// ⇒ 这份现在服务的是「助手侧图片 / 两侧视频 / 用户侧文件」。
    public static let mediaMenu = Menu(grid: [], list: [.share, .delete])

    /// **用户自己发的图片**的操作卡 —— `mediaMenu` + 一项「保存到相册」。
    ///
    /// 2026-10-08 用户要求：「我发送的图片消息 长按弹窗 增加保存选项」。
    ///
    /// ## 为什么单独一份，而不是往 `mediaMenu` 里加
    /// `mediaMenu` 是**图片 / 视频 / 文件 × 两个 role 共用**的一套（见上面「覆盖范围」）。
    /// 「保存到相册」只对**用户侧图片**成立：
    /// - 视频存进相册是另一条链路（AVAsset / 相册视频），⛔ 别混进来；
    /// - 文件（xlsx / pdf…）存相册没有意义；
    /// - 助手侧的图是**远程 URL**，得先下载才能写进相册（见 `case save` 的注释）。
    /// ⇒ 只能新开一份，⛔ 别去改 `mediaMenu`（那会让四类行一起长出「保存到相册」）。
    ///
    /// ## 位置
    /// 竖排三项：**分享 / 保存到相册 / 删除**。仍是**全竖排**（`grid: []`）——
    /// 理由同 `mediaMenu`：单项进横排会是一格居中、上下留白的空落落形态。
    /// ⚠️ **删除仍在竖排最后一位**（全工程的约定，见 `assistantMenu`）。
    public static let userImageMenu = Menu(grid: [], list: [.share, .save, .delete])

    /// **用户自己发的那条消息**的操作卡。
    ///
    /// 没有「朗读」（把自己的问题念出来没有意义）、没有「喜欢/不喜欢」（那是给回复打的）、
    /// 更没有「重新生成」（`regenerate` 的前置条件就是助手行，给用户行挂上只会点了没反应）。
    ///
    /// 横排三项固定为：**复制 / 编辑 / 引用**（顺序由产品指定，2026-09-17）。这一组是
    /// 「拿自己发出去的这句话做的事」—— 搬运它的内容（复制）、改写它并从我这儿重走（编辑）、
    /// 把它当下一问的上下文（引用）。
    /// ⚠️ 「编辑」原先在**竖排最后一位**，当时的理由是「离最常用的复制最远、降低误触」；
    /// 产品要求提到第一排后该理由不再成立 —— 横排是等宽格子，「编辑」与「复制」的间距
    /// 由格子本身拉开，不再靠位置远近来防误触。
    ///
    /// 竖排三项：选取文字 / 分享 / **删除**（删除**永远最后一位**，2026-09-18 加）。
    /// 竖排第一项「选取文字」由产品指定、**永远第一位** ——
    /// 横排被「引用 / 编辑」占满 3 格后，「分享」只能落在这里（与助手侧同构，那边的分享也在竖排）。
    ///
    /// ⚠️ 横排是**显式**分段（`grid` / `list`），**别改成「前 N 个进横排」**：流式过滤一变
    /// （见 `presentActionMenu` 里对 `blockedWhileStreaming` 的过滤），竖排第一项就会滑进横排，
    /// 位置随运行状态漂移。分界的完整理由见文件开头 `Menu` 那段注释。
    ///
    /// ⚠️ 本菜单服务于**用户发来的文字行**（2026-10-06 起）——
    /// 2026-09-29 起**不再含图片 / 视频行**，2026-10-06 起**也不再含文件行**
    ///（三类附件改走 `mediaMenu`，见 `chatMenu(for:)` 里那句按 `block.kind` 的提前返回）。
    /// 因此下面那句「编辑在文件行会弹提示」的旧注释一并作废：文件行已经没有「编辑」入口了。
    /// 剩下唯一的「编辑」服务对象就是**文字行**，它对文字行始终有意义。
    /// 若要按 `kind` 再细分，落点仍是 `chatMenu(for:)`
    ///（⛔ 别在宿主里写 `if`，否则两个入口迟早给出不一致的集合）。
    public static let userMenu = Menu(grid: [.copy, .edit, .quote], list: [.selectText, .share, .delete])

    /// 某一行该给哪套操作卡。**唯一的分发点** —— 宿主（`presentActionMenu`）不要自己写 if，
    /// 否则「气泡下方操作栏」「长按操作卡」两处迟早给出不一致的集合。
    public static func chatMenu(for row: AIChatRow) -> Menu {
        // 🔴 系统消息排在**最前**：它连「这一轮的输出」都不是（见 `AIModelSwitch`），
        //    任何一套菜单挂在它头上都是噪音
        if case .modelSwitch = row.block.kind { return systemNoticeMenu }
        if case .error = row.block.kind { return errorMenu }
        // 🔴 用户自己发的**图片**行：比下面那条附件分支**更早**返回，多一项「保存到相册」
        //（见 `userImageMenu`）。
        // ⚠️ 顺序反了的话它会被下面那条截走、安静地退回 `mediaMenu` ⇒ 菜单里根本没有「保存」，
        //    而**编译与运行都不报错**（只是少了一项）。改这段时先看这句。
        // ⚠️ 判据是两个条件**都要**满足：`role == .user`（助手侧的图是远程 URL，另说）
        //    且 `kind == .image`（视频 / 文件都不该长出这一项）。
        if row.role == .user && row.block.kind == .image {
            return userImageMenu
        }
        // 附件行（图片 / 视频 / 文件）：**不分 role**，只留「分享 + 删除」（见 `mediaMenu`）。
        // 🔴 必须排在下面 `role != .user` 那一行**之前** —— 附件行两个 role 都有
        //（用户发的图走 `AIUserImageCell`、助手侧走 `AIAssistantMediaStripCell`，
        // 文件行走 `AIUserFileCell`），顺序反了的话用户发的附件会掉回 `userMenu`
        //（那正是一堆对附件无意义的项）。
        // ⚠️ 新增一种附件 `kind` 时**只改这一行**：宿主里别写 `if`（两个入口会分叉）。
        if row.block.kind == .image || row.block.kind == .video || row.block.kind == .file {
            return mediaMenu
        }
        guard row.role != .user else { return userMenu }
        // 「继续生成」**只对没写完的回复有意义**：回复已经写完还给这一项，点下去只会得到
        // 一段重复的话。过滤放在**这里**（唯一的分发点）而不是渲染菜单的宿主里 ——
        // 气泡下方操作栏与长按操作卡两处因此不可能给出不一致的集合。
        // ⚠️ 只从 `list` 里摘：`grid` 本来就没有它，也不用担心横排分界漂移。
        guard !row.block.endedTruncated else { return assistantMenu }
        return Menu(grid: assistantMenu.grid,
                    list: assistantMenu.list.filter { $0 != .continueGeneration })
    }
}
