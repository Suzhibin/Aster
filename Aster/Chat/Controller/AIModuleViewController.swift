import UIKit
import SnapKit
import AICore

/// AI 助手主页面。
///
/// ## 本文件放什么（拆分的边界）
/// 只放**必须留在类型体内**的东西 + 横切工具：
/// - **全部存储属性**（含 11 个 `lazy var` 视图定义）——
///   Swift 的 `extension` **不能声明存储属性**，这部分无论怎么拆都只能在这里；
/// - 生命周期、视图装配（`setupUI`）、两态切换、顶部地址框、Toast。
///
/// 其余按职能拆在同目录的扩展文件里：
///
/// | 文件 | 职责 |
/// |---|---|
/// | `+Menu`         | 侧滑菜单接线、搜索 / 设置跳转、会话载入、分享文本 |
/// | `+InputToolbar` | 输入栏配置、底部占位、发送链路、`InputToolbarDelegate` |
/// | `+Attachment`   | 相册 / 文件 picker、待发附件增删、两个系统 picker 代理 |
/// | `+Voice`        | 录音会话（权限预热 / 开始 / 收尾 / 回调清理 / 浮层定位） |
/// | `+Table`        | 表格数据源与行高、cell 装配、长按操作卡、手势代理、多选勾选回调 |
/// | `+RowAction`    | 行操作（复制 / 朗读 / 分享 / 选取文字 / 引用 / 编辑 / 重新生成）、图片预览 |
/// | `+Selection`    | 多选删除（进/退选择模式、勾选联动、二次确认与执行） |
/// | `+ChatManager`  | 流式事件回调 |
///
/// ## ⚠️ 维护约定：为什么一堆成员没有 `private`
/// Swift 的 `private` 是**文件级**作用域 —— 被扩展文件用到的成员一旦标 `private`，
/// 那边就**编译不过**。所以本类里：
/// - **跨文件使用的属性 / 方法一律 `internal`**（不写修饰符）；
/// - **只在本文件用的**（如 `toastLabel`、`landingView`、`landingStack`）保持 `private`，
///   别为了「统一好看」全部放开 —— 暴露面越小越好。
///
/// 改动时顺手加回 `private` 会立刻编译失败（不是静默故障），所以放心重构。
public class AIModuleViewController: UIViewController {

    // MARK: - 状态

    let manager = AIChatManager()

    /// 当前正在展示的「打电话」页（`nil` = 不在通话页）。
    ///
    /// 为什么要留着这个引用：通话页**不持有自己的会话**（见 `AIVoiceCallViewController` 文件头），
    /// 它说的每一句都从本页的 `sendInput` 出去、AI 的回复也长在本页的 `manager` 上。
    /// 于是「这一轮回复结束了没」只有本页知道 —— 由本页转告通话页，它才能自动开下一轮麦
    /// （见 `+ChatManager.finishStreamingUI` → `sessionDidFinishReply()`）。
    ///
    /// ⚠️ 弱引用：导航栈持有通话页，pop 之后这里自动变 `nil`，不需要任何手工清理
    ///    （手工清就一定会漏某条路径，然后那个野引用会在用户早就离开通话页之后，
    ///    把麦克风莫名其妙地打开）。
    weak var voiceCallVC: AIVoiceCallViewController?

    /// 是否正在生成回复。
    ///
    /// ⚠️ **它同时驱动输入栏右下角那颗按钮**（「+」⇄「停止」）—— 见下面的 `didSet`。
    /// 所以给它赋值就等于把「输入栏外观」一起改了，**不需要**（也不该）在别处再手写一句
    /// `inputToolbar.setStreaming(...)`：那种两处配对正是最容易漏的地方
    /// （漏掉复位那一次，按钮会永远停在「停止」上，用户再也点不出「+」面板）。
    var isStreaming = false {
        didSet {
            guard oldValue != isStreaming else { return }
            inputToolbar.setStreaming(isStreaming)
        }
    }

    var isPinnedToBottom = true

    /// 「回到底部」悬浮按钮当前是否可见。
    ///
    /// **视图状态，不入库**；只用来挡住重复动画（见 `+Table.updateScrollToBottomButton()`），
    /// 真值来源始终是「列表是不是还停在最后一条消息」——`+Table.isListPinnedToBottom()`。
    /// 非 `private`：跨文件被扩展用到（`private` 是文件级作用域）。
    var isScrollToBottomButtonShown = false

    /// 当前正在朗读的行（**视图状态，不入库**，恢复会话时自然为 nil）。
    /// 同一时刻至多一行：换一行朗读会先停旧的；朗读自然结束由 `AISpeechReader` 的
    /// 「读完」回调复位。
    var speakingRowIndex: Int?

    /// 监听「朗读自然读完」的注册凭据（多播注册，见 `AISpeechReader.addFinishHandler`）。
    /// ⚠️ 必须留着这个 token 才能注销 —— 单例活得比本页久，不注销的话本页销毁后
    ///    那个闭包会一直挂在那张表里。
    private var speechFinishToken: AISpeechReader.FinishToken?

    /// 当前展示的竖排操作卡菜单（自定义气泡）；点其它 cell 时先收起旧的
    var actionMenuView: AIChatActionMenuView?

    // MARK: - 多选删除（选择模式）

    /// 是否处于「多选删除」模式：表格停在编辑态，每行左侧有系统勾选圆圈。
    ///
    /// 进入 / 退出 / 删除的完整实现都在 `+Selection.swift`，这里只放**状态** ——
    /// Swift 的 `extension` 不能声明存储属性（见文件头那段约定）。
    /// ⚠️ 它被多处读取：表格的三个数据源回调、`willDisplay`、悬浮按钮的显隐判定。
    var isSelectionMode = false

    /// 进选择模式时被**摘掉**的导航栏按钮（退出时原样装回去）。
    /// ⚠️ 存引用而不是「退出时硬写一个菜单按钮」：哪天导航栏加了别的按钮，还原逻辑不会把它抹掉。
    /// ⚠️ 摘的办法只能是「整条置 nil」—— `UIBarButtonItem.isHidden` 是 iOS 16+，本工程 target 14。
    /// 选择模式下导航栏只留标题报数 —— 动作（取消 / 删除）全在底部那条选择栏里（见 `+Selection`）。
    var selectionSavedLeftItem: UIBarButtonItem?
    var selectionSavedRightItems: [UIBarButtonItem]?

    /// 会话页导航栏标题 —— **就是它本身，不再拼模型名**（2026-10-02 用户要求去掉）。
    /// 模型名现在只出现在输入栏按钮行那颗胶囊上（`InputToolbar.modelTitle`），
    /// 那儿才是「点一下就能换」的地方；标题再写一份等于同一信息占两处。
    /// 选择模式下标题会被临时改成「已选择 N 条」，退出时调 `refreshTitle()` 还原。
    /// 🔴 **计算属性、⛔ 不是 `static let`**（2026-10-13 接本地化时踩到）：切语言后 iOS 会重建
    ///    rootViewController，但 `static let` 是**进程级缓存** —— 新建的 VC 读到的还是旧语言那份。
    static var defaultTitle: String { L("Aster") }

    /// 全屏图片浏览（JXPhotoBrowser）：当前点击的图片 URL 列表（预留多图扩展）与缩略图源视图。
    /// 源视图用 weak：cell 被复用/离屏后自动失效，zoom 转场随之降级为 fade，避免误隐藏其它行图片。
    var previewImageURLs: [URL] = []
    weak var previewThumbnailView: UIView?

    /// 页面两态：落地页（图标 + 文案 + 输入栏）/ 对话态（聊天列表 + 输入栏）。
    /// ⚠️ 不能标 `private`：`+Table` / `+InputToolbar` 里要写 `.landing` / `.chat`。
    enum Mode { case landing, chat }
    var mode: Mode = .landing

    /// 待发送的附件（相册图片 / 文件）。**真身在这里**，输入栏只拿它渲染预览条。
    ///
    /// 发送后即清空；文件已在选中那一刻拷进沙盒，所以这里清空不会让已发出的消息丢图。
    var pendingAttachments: [AIAttachment] = []

    /// 待发送的 **@ 项目资料**（2026-10-21）。**真身在这里**，输入栏只拿它渲染 chip 条。
    ///
    /// 与 `pendingAttachments` 的**关键区别**：这些资料**不会**变成对话里的一行 ——
    /// 它们只在这一轮的请求上下文里出现（见 `AIChatManager.contextMessages`）。
    /// 所以「发完就清」不会丢任何东西：资料本身还在项目里。
    /// 🔴 上限见 `AIMention.maxPerMessage`（3）：面板选满就提示，⛔ 别在这里另写一个数。
    var pendingMentions: [AIMention] = []

    /// 单次最多带几个附件。下限来自服务端（单请求图片体积上限 48 MiB），
    /// 上限来自观感（选太多会把输入栏挤爆）。9 是聊天类 App 的常见惯例。
    static let maxAttachmentCount = 9

    /// 「通话页拍照」那条路的**回执**（nil = 当前不在那条路上）。
    ///
    /// 通话页点「拍照提问」时，相机由**本页**开（复用"有没有相机 + 权限 + 失败引导"那套实现，
    /// 见 `presentImageSourceForVoiceCall`），但拍到的图**不进待发区**、直接发一条 ——
    /// 于是相机回调要先问一句"这次是通话页那条路吗"（`isVoiceCallPath`）。
    /// ⚠️ 相册那条路**不会**有它的值（那颗钮只开相机，2026-10-12 用户明确「不要相册了」）。
    /// 有值 = 是；且**每一条出口都必须调它一次**（`Bool` = 有没有真的发出去）。
    /// ☠️ 漏调一次，通话页就停在「麦已关、状态没变」的样子上，而且**不报任何错**。
    var voiceCallImageCompletion: ((Bool) -> Void)?

    /// 待发送的引用（**真身在这里**，输入栏只拿它渲染上方那条状态条）。
    /// 发送成功后清掉；引用条上的「取消」也清它（见 `refreshComposerBanner`）。
    var pendingQuote: AIQuote?

    /// 正在编辑的那条用户消息的 **id**（`nil` = 不在编辑态）。
    ///
    /// ⚠️ **必须存 id 而不是行号**：行号会随列表变化而失效 —— 编辑期间用户仍可能长按别的
    /// 消息点「重新生成」（那会删掉若干行）、或从抽屉切走再切回来。存行号就会变成
    /// 「编辑的是另一条消息」（甚至截断掉一个毫不相干的行），而且**不会报错**。
    /// 存 id 之后，找不到就是找不到，直接判失败并退出编辑态（见 `send`）。
    var editingMessageId: UUID?

    // 行高在数据返回时（AIChatManager）即由 AIChatRow.height(in:) 算好存入 cachedHeight；
    // heightForRowAt 只读缓存，不做任何计算。量算用手算 boundingRect（见 AIChatModels.swift），
    // 不再用离屏 sizingCell（UITextView 离屏时 intrinsicContentSize 不准，正是之前流式高度错的根因）。

    // MARK: - 落地页 UI（2026-10-26 起与 Mac **完全同款**）

    // 🔴 原来这里是「问候语（你好，我是 Starry AI）+ 4 颗快捷提问 chips」，
    //    而 Mac 那版是「图标 + 标题 + 副文案」（`ChatDetailView.emptyState`）。
    //    用户要求**以 Mac 为准**（原话：「iOS 和Mac 的空白页不统一，去掉iOS的 都按照Mac的来」）
    //    ⇒ 问候语与 chips 整体删除。⛔ 别以「chips 挺好用」为由加回来 —— 那是用户明确要删的。
    //
    //    两端**必须逐字对齐的只有结构**（icon 40pt → 标题 → 副文案 → 间距 10）；
    //    字号各按平台常规（iOS 副文案 12pt、标题 `.title3`，与 Mac 那两行一致）。

    private lazy var landingView: UIView = {
        let v = UIView()
        v.backgroundColor = .systemBackground
        return v
    }()

    /// 落地页全部内容（对应 Mac 那个 `VStack(spacing: 10)`）。
    /// 用 stack 而不是逐条约束：未配置模型时**多出两行**，stack 会自动重排，
    /// 逐条约束的话得手写「有/无引导」两套常量。
    private lazy var landingStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.alignment = .center
        sv.spacing = 10
        return sv
    }()

    private lazy var landingIconView: UIImageView = {
        let cfg = UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        let iv = UIImageView(image: UIImage(systemName: "bubble.left.and.bubble.right",
                                           withConfiguration: cfg))
        iv.tintColor = .tertiaryLabel
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    private lazy var landingTitleLabel: UILabel = {
        let l = UILabel()
        l.text = L("开始一个新对话")
        l.font = .preferredFont(forTextStyle: .title3)
        l.textColor = .label
        l.textAlignment = .center
        return l
    }()

    private lazy var landingSubtitleLabel: UILabel = {
        let l = UILabel()
        // ⚠️ 不能复用 Mac 那句「…⌘N 可以新建一个对话。」—— iOS 没有键盘快捷键，
        //    照搬等于教用户按一个不存在的键。见 `AILocalization` 里那条注释。
        l.text = L("在下面输入你的问题。")
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        return l
    }()

    /// 未配置模型时的引导文案（与 Mac `ChatDetailView.modelGuide` 逐字同款：12pt · secondary）。
    private lazy var modelGuideLabel: UILabel = {
        let l = UILabel()
        l.text = L("还没有配置模型，先配置一个才能开始对话")
        // ⚠️ 字号必须与副标题一致（都是 12）—— Mac 那两行就是同一个尺寸，
        //    层级只靠「间距拉开」区分（见 `landingStack.setCustomSpacing`）。
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.numberOfLines = 0
        return l
    }()

    /// 「去配置模型」—— 点了**直接进「自定义模型」清单页**（不是先绕设置页）。
    private lazy var modelGuideButton: UIButton = {
        var cfg = UIButton.Configuration.borderedTinted()
        cfg.title = L("去配置模型")
        cfg.cornerStyle = .capsule
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        let b = UIButton(configuration: cfg)
        b.addAction(UIAction { [weak self] _ in self?.openModelSettings() }, for: .touchUpInside)
        return b
    }()

    // MARK: - 对话态 UI

    lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .plain)
        tv.separatorStyle = .none
        tv.backgroundColor = .systemBackground
        tv.keyboardDismissMode = .interactive
        // ⚠️ 这个常量只是 `estimatedHeightForRowAt` 的**末位兜底**（正常取不到时才用）。
        // 真正生效的是 `+Table.swift` 里那条：估算值 = 已算好的缓存真值。
        tv.estimatedRowHeight = 80
        tv.register(AIUserTextCell.self, forCellReuseIdentifier: "AIUserTextCell")
        tv.register(AIAssistantTextCell.self, forCellReuseIdentifier: "AIAssistantTextCell")
        // 助手侧的图片与视频**共用**这一个 cell（同一条横滑条、同一组尺寸，只按 kind 分条）。
        // 它取代了旧的单图 / 单视频两个 cell —— 那两个文件 2026-10-26 已删。
        tv.register(AIAssistantMediaStripCell.self, forCellReuseIdentifier: "AIAssistantMediaStripCell")
        tv.register(AIUserImageCell.self, forCellReuseIdentifier: "AIUserImageCell")
        // 用户**多图**横排（2026-10-09）：与上面那个单图 cell 并存 ——
        // 组内 >1 张走这个（缩小 0.25、贴右横排），单张仍旧走 `AIUserImageCell`（原尺寸）。
        // ⛔ 别用同一个复用标识：两个类布局完全不同，复用池里混了会在 `as!` 当场崩。
        tv.register(AIUserImageStripCell.self, forCellReuseIdentifier: AIModuleViewController.userImageStripCellID)
        tv.register(AIUserFileCell.self, forCellReuseIdentifier: "AIUserFileCell")
        // 模型切换系统消息（2026-10-21）：居中灰字、零交互 —— 与上面那几个都不同版式，
        // ⛔ 别复用同一个标识（复用池混了会在 `as!` 当场崩）
        tv.register(AISystemNoticeCell.self, forCellReuseIdentifier: "AISystemNoticeCell")
        tv.dataSource = self
        tv.delegate = self
        tv.isHidden = true
        return tv
    }()

    // 输入栏（frame 布局，自带键盘跟随；落地页与对话态均在底部）
    lazy var inputToolbar: InputToolbar = {
        let bar = InputToolbar()
        bar.backgroundColor = .systemBackground
        bar.delegate = self
        bar.onFrameChange = { [weak self] rect in
            guard let self else { return }
            self.updateBottomOccupancy(rect.minY)
            self.layoutVoicePanel()
            // 悬浮按钮挂在输入栏上方，输入栏随键盘 / 「+」面板变形时它得跟着走
            self.layoutScrollToBottomButton()
            // 选择栏直接抄输入栏的 frame（同位置同高）→ 输入栏一动它就得跟着重摆。
            // 键盘收起是动画的：进入选择模式那一刻输入栏还悬在键盘上方，靠这里逐帧跟回来
            self.layoutSelectionToolbar()
        }
        bar.onInputModeChange = { [weak self] isVoice in
            guard let self else { return }
            self.handleInputModeChange(isVoice: isVoice)
        }
        return bar
    }()

    /// 「多选删除」选择模式下**顶替输入栏**的底部操作条（左「取消」/ 右「删除(N)」）。
    ///
    /// ⚠️ 它由 `layoutSelectionToolbar()` 直接按 `inputToolbar.frame` 摆位 —— 两者**同位置同高**，
    /// 于是列表底部内边距（`updateBottomOccupancy`）一格都不用改。差一截的表现是
    /// 最后几条消息被它盖住（底部占位全仓只有输入栏这一个口径）。
    /// ⚠️ `addSubview` 顺序在 `inputToolbar` **之后**（见 `setupUI`），层级才压得住。
    lazy var selectionToolbar: AISelectionToolbar = {
        let bar = AISelectionToolbar()
        bar.isHidden = true
        bar.onCancel = { [weak self] in
            guard let self else { return }
            self.handleSelectionCancel()
        }
        bar.onDelete = { [weak self] in
            guard let self else { return }
            self.handleSelectionDelete()
        }
        return bar
    }()

    /// 「回到列表底部」悬浮按钮（44×44 圆形，向下箭头）。
    ///
    /// 贴在**输入栏正上方、覆盖在列表之上**：停在最后一条消息时收起，往上翻历史时淡入
    /// （判定与布局都在 `+Table`——那才是列表交互的地盘）。
    ///
    /// ⚠️ **加进视图的顺序不能改**：必须在 `inputToolbar` **之后** `addSubview`。
    /// `InputToolbar.point(inside:)` 在键盘弹起时**无条件返回 true**（「点屏幕任意处收键盘」就是它实现的），
    /// 而 `hitTest` 是**倒序**遍历子视图 —— 加在输入栏前面的话，键盘一弹起来这个按钮就再也点不到了。
    lazy var scrollToBottomButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(systemName: "arrow.down",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
                     for: .normal)
        // ⚠️ 底色**固定白**、阴影**固定黑**，所以箭头也必须固定深色：
        // 用 `.label` 的话暗黑模式下它是白的 → 白底白箭头 = 看不见（这块刻意不跟随系统外观）。
        btn.tintColor = UIColor(white: 0.15, alpha: 1)
        // 白底 + 黑色投影，让它从列表内容上「浮」起来
        btn.backgroundColor = .white
        btn.layer.cornerRadius = Self.scrollToBottomButtonSide / 2
        btn.layer.shadowColor = UIColor.black.cgColor
        btn.layer.shadowOpacity = 0.18
        btn.layer.shadowRadius = 8
        btn.layer.shadowOffset = CGSize(width: 0, height: 3)
        // 阴影要溢出圆角之外才看得见；`masksToBounds`/`clipsToBounds` 千万不能开
        btn.clipsToBounds = false
        // 初始态 = 隐藏态（alpha 0 + 不吃触摸），与 `updateScrollToBottomButton` 的口径一致
        btn.alpha = 0
        btn.isUserInteractionEnabled = false
        btn.accessibilityLabel = L("回到底部")
        btn.addTarget(self, action: #selector(handleScrollToBottomTap), for: .touchUpInside)
        return btn
    }()

    /// 录音浮层（**贴屏幕最底部**铺满整宽：底部蓝光 + 白色刻度波形 + 提示语，展示实时识别文字）
    lazy var voicePanel: VoiceRecordingPanel = {
        let panel = VoiceRecordingPanel()
        return panel
    }()

    /// 语音会话是否进行中（覆盖「按住说话」的按下~抬起；自动超时收尾后抬起事件会被忽略）
    var isVoiceSessionActive = false

    /// 🧪 验收钩子的**一次性闩**（`STARRY_CALL_UI=1` 时自动进一次「打电话」页）。
    /// ⚠️ 必须有它：钩子挂在 `viewDidAppear` 上，而从通话页返回还会再走一次
    /// ⇒ 没有这个闩就是「返回 → 又被推进去」的死循环。
    var didAutoOpenVoiceCall = false

    /// 🧪 验收钩子的**一次性闩**（`STARRY_SETTINGS_UI=1` 时自动进一次「添加模型」页）。
    /// 与 `didAutoOpenVoiceCall` 同一条理由：钩子挂在 `viewDidAppear` 上，
    /// 从面板返回还会再走一次 ⇒ 没有这个闩就是「返回 → 又被推进去」的死循环。
    var didAutoOpenSettings = false

    /// 🧪 验收钩子的**一次性闩**（`STARRY_EMPTY_GUIDE=1` 时自动点一次空态「去配置模型」，2026-10-26）。
    /// 同上：从表单返回还会再走一次 `viewDidAppear`，没闩就会被反复推进去。
    var didAutoOpenModelGuide = false

    /// 🧪 验收钩子的**一次性闩**（`STARRY_PROJECT_UI=instruction` 时自动进一次「项目指令」页，2026-10-27）。
    /// 同上：从编辑页返回还会再走一次 `viewDidAppear`，没闩就会被反复推。
    var didAutoOpenProjectInstruction = false

    /// 🧪 验收钩子的**一次性闩**（`STARRY_PICKER_UI=1` 时自动弹一次「选择模型」）。
    ///
    /// 与上面两条同一条理由 —— 而且这里更硬：那是个 **sheet**，关掉它会**再次**触发
    /// `viewDidAppear`（sheet 关闭 = 宿主重新 appear）⇒ 没有这个闩就是「关不掉」。
    var didAutoOpenSessionPicker = false

    /// 🧪 验收钩子的**一次性闩**（`STARRY_PANEL_UI=1` 时自动开一次「+」附件面板）。
    /// 与上面两条同一条理由：钩子挂在 `viewDidAppear` 上，面板开合会再次触发它。
    var didAutoOpenAttachmentPanel = false

    /// 🧪 联网开关决策探针的**一次性闩**（`STARRY_WEBSEARCH_PROBE=on|off`）。
    /// 这里比别处更要闩：钩子会**发一条真消息**，重复触发就是白打接口。
    var didAutoRunWebSearchProbe = false

    /// 🧪 `@` 项目资料探针的一次性闩（`STARRY_MENTION_PROBE=1`，2026-10-21）
    var didAutoRunMentionProbe = false

    /// 🧪 模型切换系统消息探针的一次性闩（`STARRY_MODEL_SWITCH_PROBE=1`，2026-10-21）
    var didAutoRunModelSwitchProbe = false

    /// 🧪 「+」面板第 4 格显隐探针的一次性闩（`STARRY_PANEL_PROBE=1`，2026-10-24）
    var didAutoRunPanelEntryProbe = false

    private lazy var inputTopLine: UIView = {
        let line = UIView()
        line.backgroundColor = .separator
        line.autoresizingMask = [.flexibleWidth]
        return line
    }()

    var toastBottomConstraint: Constraint?

    private lazy var toastLabel: UILabel = {
        let label = UILabel()
        label.textColor = .white
        label.font = .systemFont(ofSize: 13)
        label.backgroundColor = UIColor(white: 0, alpha: 0.8)
        label.textAlignment = .center
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.isHidden = true
        return label
    }()

    // MARK: - 生命周期

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        refreshTitle()
        // 导航栏左按钮：呼出侧滑菜单（页面已由宿主包进 UINavigationController）
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal"),
            style: .plain,
            target: self,
            action: #selector(menuButtonTapped)
        )
        navigationItem.leftBarButtonItem?.tintColor = .label
        // 导航栏右按钮：进「打电话」（AI 语音通话页，2026-10-10）。
        // ⚠️ 用的是 `rightBarButtonItem`（单数）而**不是** `rightBarButtonItems`：
        //    选择模式那套「整条置 nil 再原样装回」对两者都成立，但单数写法更不容易被
        //    以后新加的按钮挤到第二位（第二位在窄屏上会被 title 压掉）。
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "phone.fill"),
            style: .plain,
            target: self,
            action: #selector(callButtonTapped)
        )
        navigationItem.rightBarButtonItem?.tintColor = .label
        manager.delegate = self
        // 冷启动：恢复上次打开的会话（有历史则直接进对话态，否则新建空会话停在落地页）。
        // 空会话不落库，因此「上次新建但没发过消息」会自然回落到落地页。
        let restored = manager.restoreLastConversation()
        if !restored { manager.newConversation() }
        setupUI()
        // 🔴 按**恢复出来的会话归属**刷一次输入栏状态（`refreshComposerBanner` 第一行
        // 就是「+」面板第 4 格的显隐）：冷启动恢复的是项目组里的会话时，
        // 不刷这句首次开「+」面板就少一格「项目资料」（静默，无报错）。
        // ⚠️ 必须在 `setupUI()` **之后** —— `refreshProjectEntry()` 要碰
        // `inputToolbar`（那一步才装好它），同下面 `refreshModelState()` 的次序理由。
        refreshComposerBanner()
        // 输入栏下方那行模型名 + 导航标题。先跑一次：清单非空而「当前使用」的指针还没落地时
        // 要钉一下（`refreshModelState` 内部就是 ensureCurrent → 刷那一行）。
        // ⚠️ 必须在 `configureInputToolbar()`（在 `setupUI` 里）**之后** —— 那一步才装好
        //    `onTapModel` 与输入栏本身；写反了那一行会拿不到模型名。
        refreshModelState()
        // 设置页改配置后**主动**通知：设置页是 sheet，关闭时本页收不到 viewWillAppear，
        // 只靠 viewWillAppear 同步会留下旧平台的地址（详见 AIConfig.didChangeNotification）
        NotificationCenter.default.addObserver(self,
                                              selector: #selector(configDidChange),
                                              name: AIConfig.didChangeNotification,
                                              object: nil)
        // 「字体大小」换档（设置页 → 字体大小页）：行高是**预计算缓存**，
        // 里面全是旧字号量出来的值 ⇒ 必须整表重算 + 重载，否则字号不换、行高与显示不符。
        // ⚠️ iOS 侧只能这么接：Observation（Mac 那条零接线的路）在 UIKit 里用不上。
        NotificationCenter.default.addObserver(self,
                                              selector: #selector(fontSizeDidChange),
                                              name: AIFontSizeStore.didChange,
                                              object: nil)
        // 「生成参数」变更（2026-10-20：指令 / 采样 / **展示思考过程总闸**）。
        // 采样与指令的消费方是**下一轮请求**（现读，不需要刷新界面）；但「展示思考过程」
        // 的消费方是**已渲染的行** —— 关掉它时屏幕上那些思考块不会自己消失。
        // 行高里也含思考块（`thinkingHeightOrZero` 现读总闸）⇒ 与字号同一套：重算 + 重载。
        NotificationCenter.default.addObserver(self,
                                              selector: #selector(generationSettingsDidChange),
                                              name: AIGenerationSettings.didChangeNotification,
                                              object: nil)
        // 模型清单变化（增删 / 换当前）⇒ 落地页那两行「还没有配置模型」引导要跟着显隐。
        // ⚠️ **不用再注册一次**：上面那条 `AIConfig.didChangeNotification` 已经接了
        //    `configDidChange`，落地页刷新并进那个回调里（见它的实现）。
        //    这里重复注册会让同一个回调跑两遍（不报错，只是白刷一次界面）。
        // 联网搜索失败（2026-10-21）：**不影响这一轮**（业务层已降级成普通对话），
        // 这里只负责说一声 —— 否则用户看到「开了联网但答案里没有来源」会以为功能坏了。
        NotificationCenter.default.addObserver(self,
                                              selector: #selector(webSearchDidFail(_:)),
                                              name: AIChatManager.didFailWebSearchNotification,
                                              object: nil)
        // 朗读**自然读完**（或被系统打断）时复位图标；主动停止不回调——那时是调用方自己改的状态。
        // ⚠️ 走**多播**注册（不是 `onFinish = ...`）：通话页也监听同一个事件（读完自动开麦），
        //    单槽位会让两边互相挤掉，被挤掉的那一边**不报错**、只是静默失灵。
        speechFinishToken = AISpeechReader.shared.addFinishHandler { [weak self] in
            guard let self else { return }
            self.clearSpeakingRow()
        }
        setupMenu()
        setupCellLongPressGesture()
        setupListBlankTapGesture()
        // 有历史则直接进对话态（enterChat 内含 applyMode）；否则停在落地页
        if restored { enterChat() } else { applyMode() }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从「自定义模型」清单页返回时（刚加/删了一条），落地页引导要跟上
        refreshLanding()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 🧪 验收钩子（只在 `#if DEBUG` + 环境变量下生效，见 `+Voice.openVoiceCallIfRequested`）
        openVoiceCallIfRequested()
        // 🧪 「添加模型」页验收钩子（`STARRY_SETTINGS_UI=1`，见 `+Menu.openSettingsIfRequested`）
        openSettingsIfRequested()
        // 🧪 空态「去配置模型」验收钩子（`STARRY_EMPTY_GUIDE=1`，见 `+Menu.openModelGuideIfRequested`）
        openModelGuideIfRequested()
        // 🧪 「项目指令」页验收钩子（`STARRY_PROJECT_UI=instruction`，
        //    见 `+Menu.openProjectInstructionIfRequested`）
        openProjectInstructionIfRequested()
        // 🧪 会话页「选择模型」模态页验收钩子（`STARRY_PICKER_UI=1`，
        //    见 `+InputToolbar.openSessionPickerIfRequested`）
        openSessionPickerIfRequested()
        // 🧪 「+」附件面板验收钩子（`STARRY_PANEL_UI=1`，2026-10-16 画图入口用，
        //    见 `+InputToolbar.openAttachmentPanelIfRequested`）
        openAttachmentPanelIfRequested()
        // 🧪 朗读节奏探针（`STARRY_TTS_TRACE=1` 才动，本体见 `+RowAction.runSpeechTraceIfRequested`）
        runSpeechTraceIfRequested()
        // 🧪 联网开关决策探针（`STARRY_WEBSEARCH_PROBE=on|off`，2026-10-21）：
        //    设好开关 → 发一条真消息，证据是控制台的 `[WebSearch]` 三行
        //    （本体见 `+InputToolbar.runWebSearchProbeIfRequested`）
        runWebSearchProbeIfRequested()
        // 🧪 `@` 项目资料探针（`STARRY_MENTION_PROBE=1`，2026-10-21）：
        //    建项目 → 归档当前会话 → 导入示例资料 → 走 `appendMention` 真路径，
        //    证据是 chip 条截图 + 控制台一行 `[MentionProbe]`
        //    （本体见 `+InputToolbar.runMentionProbeIfRequested`）
        runMentionProbeIfRequested()
        // （项目资料检索探针 2026-10-23 当晚随放大镜入口一起删了 —— 它验的就是那颗钮；
        //  底层检索链路没删，见 VERIFY-PROBES.md §32.4）
        // 🧪 模型切换系统消息探针（`STARRY_MODEL_SWITCH_PROBE=1`，2026-10-21）：
        //    依次演 append / replace / undo 三态，证据是控制台 `[ModelSwitchProbe]` 三行
        //    （本体见 `+InputToolbar.runModelSwitchProbeIfRequested`）
        runModelSwitchProbeIfRequested()
        // 🧪 切语言探针（`STARRY_I18N_TRACE=1` 才动，本体见 `Setup/I18NTraceProbe.swift`）——
        //    它自己会把「开抽屉 → 开账号弹窗 → 点语言档」走一遍，判据落在 Documents/i18n_trace.log
        //    ⚠️ 整个 `I18NTraceProbe` 都在 `#if DEBUG` 里 ⇒ 调用点也得条件编译（Release 包里没有这个符号）
        #if DEBUG
        I18NTraceProbe.runIfRequested(from: self)
        #endif
        // 🧪 PDF 解析链路探针（`STARRY_PDF_PROBE=1` 才动，本体见 `Setup/PDFTraceProbe.swift`）——
        //    造真 PDF 走 `debugFileContextText`（= `fileContextText` 本体），判据落在
        //    Documents/pdf_probe.log。纯逻辑、不碰界面 ⇒ 不需要等待与截图配合。
        #if DEBUG
        PDFTraceProbe.runIfRequested()
        #endif
        // 🧪 长期记忆读写 round-trip 探针（`STARRY_MEMORY_PROBE=1`，2026-10-25）：
        //    add → all → digest → delete → 开关 六步，全部走 AIMemoryStore 公开 API
        //    （真容器真文件），判据落在 Documents/memory_probe.log
        //    （本体见 `Setup/MemoryTraceProbe.swift`）
        #if DEBUG
        MemoryTraceProbe.runIfRequested()
        #endif
        // 🧪 默认项目「任务」全链路探针（`STARRY_PANEL_PROBE=1`，2026-10-24 建 /
        //    2026-10-25 重写）：新建归默认组 / 切用户项目 / 切默认组 / 移入 / 删项目回落 /
        //    默认组禁删六步，证据是控制台 `[PanelProbe] … RESULT: PASS|FAIL` 一行
        //    （本体见 `+InputToolbar.runPanelEntryProbeIfRequested`）
        runPanelEntryProbeIfRequested()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // 单例持有的朗读回调和正在进行的朗读都要收掉，避免本页销毁后还在念
        // ⚠️ 只摘**自己注册的那一个**（多播：通话页 / Mac 那边的注册不能被我一起清掉）
        if let token = speechFinishToken {
            AISpeechReader.shared.removeFinishHandler(token)
        }
        AISpeechReader.shared.stop()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.endEditing(true)
        // 录音必须立刻停：麦克风不能在本页被别的页面盖住时还开着
        endVoiceSession(cancel: true)
        // 朗读是即时行为：一旦离开（含 push 子页）就停，不在后台继续念
        stopSpeech()

        // 正在生成的回复**不**因为「push 子页（设置页）」而中断 —— 本页仍在导航栈里，
        // 返回后应该还能看到它继续长完。只有真的出栈 / 被 dismiss 才算离开。
        // （模态弹设置页时 iOS 13+ 的 sheet 根本不会触发本方法，所以这里不影响旧路径。）
        let isLeaving = isMovingFromParent || isBeingDismissed || navigationController == nil
        if isLeaving { manager.stop() }
    }

    public override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        // 屏宽变化 → 更新宽度并按新宽度全部重算（heightForRowAt 只读缓存，必须预先算好）
        manager.contentWidth = size.width
        manager.recomputeAllRowHeights()
        tableView.reloadData()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 输入栏为 frame 布局：安全区注入 + 复位到底部（键盘弹起时由其自行跟随，不干预）
        inputToolbar.restingBottomInset = view.safeAreaInsets.bottom
        inputTopLine.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 0.5)
        // 悬浮按钮跟着输入栏走。放在下面那个 guard **之前**：键盘弹起时输入栏由键盘通知带着走
        // （这一趟会提前 return），但转屏 / 分屏改宽度这一趟必须把按钮重算。
        layoutScrollToBottomButton()
        // 选择栏与输入栏同位置同高：输入栏的 frame 在上面刚复位过，这里跟着重摆一次
        //（这条在下面那个 guard 之前 —— 键盘态提前 return 时它照样要摆对）
        layoutSelectionToolbar()
        // 首帧布局完成后 `tableView.bounds` 才不是 0 —— 之前算出来的「是否贴底」不作数，
        // 这里补判一次（`update` 内部有状态守卫，反复调用无副作用）
        updateScrollToBottomButton()
        // 键盘在时输入栏由键盘通知带着走，别插手。
        // （「+」展开态不用特判：`heightThatFits()` 已经把面板高度算进去了，复位目标就是对的。）
        guard !inputToolbar.isFirstResponder() else { return }
        let height = inputToolbar.heightThatFits()
        let target = CGRect(x: 0,
                            y: view.bounds.height - height,
                            width: view.bounds.width,
                            height: height)
        if inputToolbar.frame != target {
            inputToolbar.frame = target
        }
        layoutVoicePanel()
    }

    // MARK: - UI

    private func setupUI() {
        // 落地页：图标 + 标题 + 副文案（未配置模型时再追加两行引导）—— 与 Mac 同款
        view.addSubview(landingView)
        landingView.addSubview(landingStack)
        [landingIconView, landingTitleLabel, landingSubtitleLabel,
         modelGuideLabel, modelGuideButton].forEach(landingStack.addArrangedSubview)
        // 引导默认藏起来，显隐只由 `refreshLanding()` 决定（它读 `AIConfig.hasModel`）
        modelGuideLabel.isHidden = true
        modelGuideButton.isHidden = true
        // 🔴 引导块与上面那两行要拉开。Mac 那边是「主块 + 引导」用 overlay 挂在下方
        //    （gap 44，不参与居中），这里把副标题之后的间距**替换**成同一个值
        //    （`setCustomSpacing` 是覆盖不是叠加）—— 24 → 44 是用户 2026-10-26 的要求。
        //    ⛔ 别用「在 label 上加约束」那种写法：stack 会与约束打架。
        landingStack.setCustomSpacing(44, after: landingSubtitleLabel)

        // 对话态：聊天列表
        view.addSubview(tableView)
        view.addSubview(toastLabel)
        // 输入栏走 frame 布局，最后添加保证层级在最上
        view.addSubview(inputToolbar)
        inputToolbar.addSubview(inputTopLine)
        // ⚠️ 悬浮按钮**必须**加在输入栏之后（层级在它之上），原因见 `scrollToBottomButton` 的注释
        view.addSubview(scrollToBottomButton)
        // 选择栏（多选删除时顶替输入栏）：同样加在输入栏之后，层级在它之上；默认隐藏
        view.addSubview(selectionToolbar)

        configureInputToolbar()

        landingView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.leading.trailing.bottom.equalToSuperview()
        }
        landingStack.snp.makeConstraints { make in
            // 左右留 32：让未配置模型那句引导有余量折行（它是 `numberOfLines = 0`）
            make.leading.equalToSuperview().offset(32)
            make.trailing.equalToSuperview().offset(-32)
            // ⚠️ 比正中略上移 40pt：底部还压着输入栏，正中会让整块看起来偏下
            make.centerY.equalToSuperview().offset(-40)
        }
        tableView.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.leading.trailing.bottom.equalToSuperview()
        }

        toastLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.height.equalTo(32)
            self.toastBottomConstraint = make.bottom.equalToSuperview().offset(-16).constraint
        }
    }

    // MARK: - 落地页刷新 + 去配置模型

    /// 落地页的**唯一刷新入口**：按「有没有配过模型」显隐那两行引导。
    ///
    /// 三个触发点（缺一个就会停在旧状态）：
    /// ① `viewWillAppear` —— 从配置页返回时（用户刚加 / 删了模型）；
    /// ② `configDidChange`（`AIConfig.didChangeNotification`）—— 本页活着时配置在别处被改；
    /// ③ `setupUI` 之后由 `viewWillAppear` 覆盖，不需要额外调。
    ///
    /// ⚠️ 不写进 `applyMode()`（那个函数只管两态显隐、每次切态都跑）：配置几乎不变，
    ///    每切一次态读一次盘纯属浪费。`AIConfig.hasModel` 内部有 mtime 判断，但仍是 IO。
    func refreshLanding() {
        let hasModel = AIConfig.hasModel
        modelGuideLabel.isHidden = hasModel
        modelGuideButton.isHidden = hasModel
    }

    /// 「去配置模型」→ **直接**进「自定义模型」清单页，**并立刻压上「添加模型」表单**（2026-10-26）。
    ///
    /// 为什么要一次压两层：这颗钮只在**一个模型都没有**时出现，用户点它的意思就是
    /// 「我要填一条新的」。只推到清单页的话，他还得自己找右上角那颗「添加模型」——
    /// 白跑一趟（与 Mac 侧 `MacSettingsRouter.request(.model, openAddForm: true)` 同口径）。
    ///
    /// ⚠️ 两层要**分别** push，不要想着「把表单当根」：
    ///    用户从表单返回时应该落回清单页（能看到刚加的那条），而不是直接退回会话。
    /// ⚠️ 第一层 `animated: false`：两层连着 push，只让**表单一层**做滑入动画，
    ///    否则用户会看见「清单页闪一下再被表单盖住」。
    func openModelSettings() {
        view.endEditing(true)
        let list = AICustomModelListViewController()
        let form = AIAddModelViewController(editingModel: nil)
        if let nav = navigationController {
            nav.pushViewController(list, animated: false)
            nav.pushViewController(form, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: list)
            nav.pushViewController(form, animated: false)
            present(nav, animated: true)
        }
    }

    // MARK: - 两态切换

    /// 按 mode 显隐各部分 UI
    func applyMode() {
        // 选择模式只存在于对话态：回落地页（新建对话 / 删掉当前会话）时先把它收掉，
        // 否则表格停在编辑态、导航栏还挂着「取消 / 删除」，而列表已经空了
        if mode == .landing { exitSelectionMode() }
        landingView.isHidden = (mode == .chat)
        tableView.isHidden = (mode == .landing)
        // 两态切换后重判一次悬浮按钮：落地页没有列表，不该挂着「回到底部」
        updateScrollToBottomButton()
    }

    func enterChat() {
        mode = .chat
        applyMode()
        tableView.reloadData()
        scrollToBottom(animated: false)
    }

    /// 开启新对话（AI创作可预填文案），回到落地页
    func startNewChat(prefill: String? = nil) {
        if isStreaming { manager.stop() }
        isStreaming = false
        stopSpeech()
        inputToolbar.clearText()
        // 新建对话 = 丢掉这一轮的所有上下文，待发附件也跟着清（连盘一起清：
        // 这些文件从没被任何消息引用过，留着就是沙盒垃圾）
        clearPendingAttachments(removeFiles: true)
        // 引用与编辑态都指向「某条具体的消息」，换了会话它们就不成立了
        // （不清的话，编辑态发送会去截断新会话里一个毫不相干的行）
        pendingQuote = nil
        editingMessageId = nil
        manager.newConversation()
        // 🔴 同 `openConversation`：先建新会话再刷 —— 放在 `newConversation()` 之前
        // 的话，`refreshProjectEntry()` 读到的是**上一个会话**的归属
        // （从项目里的对话点「新建」⇒ 新对话会错误地多出「项目资料」格）。
        refreshComposerBanner()
        mode = .landing
        applyMode()
        if let p = prefill, !p.isEmpty {
            inputToolbar.updateWithConfig { $0.text = p }
        }
    }

    // MARK: - 导航栏标题

    /// 平台 / 模型 / Key 变更后刷新提示（通知回调）。
    /// 设置页是 sheet，关掉时本页收不到 `viewWillAppear` —— 标题与输入栏那行模型名
    /// 只能靠这条广播更新。
    ///
    /// ⚠️ 走 `refreshModelState()`（而不是只刷标题）：别处（清单页 / 表单）改了配置之后，
    ///    「当前使用」那条可能被删掉或改了名 ⇒ 指针要重新落地一次，
    ///    否则输入栏下方的名字会停在空 / 旧值上。
    @objc private func configDidChange() {
        refreshModelState()
        // 落地页那两行「还没有配置模型」引导（2026-10-26）：增删模型后要跟着显隐。
        // ⚠️ 挂在这里而不是另注册一条通知：同一个通知名注册两次会让本回调跑两遍。
        refreshLanding()
    }

    /// 设置页换了「字体大小」档位（`AIFontSizeStore.didChange`）。
    ///
    /// 🔴 为什么必须**整表重算**：`heightForRowAt` 只读 `cachedHeight`（数据返回时按当时的
    ///    `AITypography.body` 算好并缓存），光 `reloadData()` 只会让 cell 用新字号画、
    ///    行高还是旧的 ⇒ 大字号被裁、小字号底部空一截（本工程「量算必须与渲染同源」那条）。
    /// ⚠️ `AIMarkdown` 那两份缓存的清理**不在这里做** —— 收在 `AIFontSizeStore` 的 setter 里
    ///    （唯一写入口），⛔ 别在各页面各清一遍。
    @objc private func fontSizeDidChange() {
        // 输入框那颗字号也要跟上（`refreshAttribute()` 里就是 `textView.font = configure.font`）。
        // ⚠️ 只改 font 一项：`updateWithConfig` 是「跑一遍配置块 + refreshAttribute」，
        //    `configure` 是已装配好的那份，其它字段不会被重置。
        inputToolbar.updateWithConfig { $0.font = AITypography.body }
        // 按钮行那颗模型名胶囊（12pt 写死 → 2026-10-22 起吃 chrome 档位 `AIChromeFont.ui(12)`）。
        // transformer 闭包存在 configuration 里，必须整体重设才重新求值 ⇒ 单独一条路。
        inputToolbar.applyChromeFonts()
        manager.recomputeAllRowHeights()
        tableView.reloadData()
    }

    /// 「生成参数」变更（2026-10-20）。系统提示词 / 采样参数只影响**下一轮请求**（现读），
    /// 这里唯一要反应的是「展示思考过程」总闸：思考块的渲染与行高都现读它
    /// （`AIThinkingBlockView.configure` 与 `AIChatRow.thinkingHeightOrZero` 两处同口径）。
    @objc private func generationSettingsDidChange() {
        manager.recomputeAllRowHeights()
        tableView.reloadData()
    }

    /// 把导航栏标题刷回常态 —— **标题的唯一出口**。
    ///
    /// 🔴 2026-10-02 起标题**不再拼模型名**（用户要求去掉）：内容恒为 `Self.defaultTitle`，
    ///    与模型无关。模型名改由**输入栏按钮行那颗胶囊**承担
    ///    （`InputToolbar.modelTitle` ← `AIModelCatalog.composerLabel`）——
    ///    那儿才是「点一下就能换模型」的地方，标题再写一份只是让同一信息占两处。
    ///    ⛔ 别再把模型名拼回来：会话页换了模型时标题会跟着跳一大段，
    ///       而用户此刻看的是下方那颗胶囊。
    ///
    /// ⚠️ 标题**不是**常驻显示：选择模式下会被临时改成「已选择 N 条」，
    ///    退出时必须调回这里还原（见 `+Selection` 的 `exitSelectionMode`）。
    ///    所以**别因为这个函数体只有一行赋值就把它删掉**：它是那组
    ///    「进入时改标题 / 退出时还原」的还原点，散成裸赋值就没有唯一出处了。
    func refreshTitle() {
        title = Self.defaultTitle
    }

    // MARK: - 通用工具（多个扩展文件共用，故留在主文件）

    /// 会话页自己的轻提示（贴在输入栏上方）。
    ///
    /// ⚠️ 时长读 `AIToast.duration` —— 原来这里写死 2.2，通话页那份也写死 2.2，两处各写一份；
    ///    2026-10-26 用户要求"报错的 toast 加长 2 秒"，统一成一个常量才不会改一处漏一处
    ///    （漏掉的那处表现是"通话页看得清、输入框看不清"）。
    /// 🔴 时长翻倍后，「同一句话连弹两次」的窗口也跟着翻倍：旧定时器会把第二次那条**提前藏掉**
    ///    （用户看到"一闪就没"，比原来更糟）。所以用「文案有没有被改过」判这次定时器还算不算数 ——
    ///    与 `AIToast.show` 同一套判据。
    func showToast(_ message: String) {
        let text = "  \(message)  "
        toastLabel.text = text
        toastLabel.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + AIToast.duration) { [weak self] in
            guard let self, self.toastLabel.text == text else { return }
            self.toastLabel.isHidden = true
        }
    }

    /// 滚到列表底部（键盘弹着时 = 贴到输入栏上沿，新内容始终露在键盘之上）。
    ///
    /// 🔴 **必须走 `scrollToRow`，别改成直接写 `contentOffset`**（踩过，已回滚）：
    /// 流式期间本方法每秒被调 33 次，看着像「`scrollToRow` 内部要定位 cell、取 frame、
    /// 算可见性，太啰嗦，我按内容高度自己算个偏移更快」—— 试过，结果就是
    /// **回复被键盘挡住**：自己算 offset 只能读到 `contentSize` / `adjustedContentInset`
    /// 这两个**滞后的派生值**。调用点全是 `begin/endUpdates()` 刚改完行高、
    /// 或 `contentInset.bottom` 刚被 `updateBottomOccupancy` 写入的那一拍，
    /// 此刻新行高还没并进 `contentSize`、新 inset 也未必已折进 `adjustedContentInset`，
    /// 算出来的偏移正好**短一个键盘高**（内容底边停在屏幕下沿，而不是输入栏上沿）。
    /// `scrollToRow` 走的是 UIKit 自己的路径：内部会先让布局落定再去取 cell 的 rect，
    /// 顺带把 inset / 安全区一并算对 —— 快不快不知道，但它是对的。
    func scrollToBottom(animated: Bool) {
        guard !manager.rows.isEmpty else { return }
        let ip = IndexPath(row: manager.rows.count - 1, section: 0)
        tableView.scrollToRow(at: ip, at: .bottom, animated: animated)
    }
}
