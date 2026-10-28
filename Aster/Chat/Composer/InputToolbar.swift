//
//  InputToolbar.swift
//  LEDBullet
//
//  Created by Suzhibin on 2024/9/27.
//

import UIKit
import Photos
import AICore

public typealias InputToolbarConfigureClosure = (_ configure: InputToolbarConfigure)-> Void

protocol InputToolbarDelegate : NSObjectProtocol {
    func keyboardState(state:Bool,text:String)//键盘状态
    func inputTextMaxCount(count:Int)//文本超出的个数
    func sendEvent(_ text:String)
    /// 加号按钮切到「发送」态后被点：**发送当前输入区**（文本可空、附件可空，两者至少有一个）。
    ///
    /// 🔴 2026-10-08 加：原先「只发附件不打字」靠附件条右侧那颗蓝色按钮（已删），
    ///    那个洞现在由按钮行里那颗「＋」顶上来 —— 它在同一个位置按「有附件 / 生成中 / 面板开合」
    ///    换面孔（见 `InputToolbar.refreshMoreButtonState`），所以要一条独立事件。
    ///    ⛔ 别改回 `sendEvent("")`：那条要求文本非空（`triggerSend` 里就挡了），
    ///    「只选图不打字」会发不出去。
    func sendCurrentInputEvent()// 加号处于发送态时被点
    func attachmentEvent(_ kind:InputAttachmentKind)// 加号面板里的入口（相机 / 相册 / 文件）
    func attachmentPhotoPicked(_ asset: PHAsset)// 加号面板里那块最近照片网格被点了一张
    func cameraEvent()// 拍照
    func voiceRecordDidBegin()// 「按住说话」按下
    func voiceRecordDidEnd(cancel:Bool)// 「按住说话」抬起（cancel：手指移出按钮范围）
    func voiceRecordCancelStateChanged(isCancelling:Bool)// 松手前是否会取消（上滑移出=true，移回=false）
    func stopStreamingEvent()// 「停止生成」（流式进行中，最右那颗按钮）
    /// 点了「联网搜索」开关（2026-10-21）。
    ///
    /// 分工与 `cameraEvent` 一致：工具栏**不碰任何偏好存储**，只把「被点了」这件事
    /// 报给宿主；翻转 `AIGenerationSettings.webSearchEnabled` 与回写按钮态由 VC 做
    /// （回写走 `setWebSearchEnabled(_:)`，那是唯一改图标色的地方）。
    func webSearchToggleEvent()

    /// 用户刚打了一个 `@`（2026-10-21）。
    ///
    /// 分工与 `cameraEvent` 同一条：工具栏**不查库、不弹页面**，只把「打了 @」这件事报上去；
    /// 弹不弹「项目资料」选择页、弹完插不插 token，全在宿主（VC）——
    /// 因为「这个会话属不属于某个项目」只有宿主知道（`manager.activeProjectId`）。
    /// ⚠️ `@` 本身**已经落进输入框**（不拦），所以宿主取消选择时什么也不用回滚：
    ///    用户想写邮箱地址也照常写，只是多弹了一次面板（`markedTextRange` 期间不会弹）。
    func mentionTriggerEvent()
}
public class InputToolbarConfigure : NSObject{
    var textViewMinLine:Int = 1 //设置输入框最小行数
    var textViewMaxLine:Int = 3//设置输入框最大行数
    var font:UIFont = UIFont.systemFont(ofSize: 14) //输入框文字大小
    var placeholder:String = L("请输入消息内容")//占位文字
    var text:String = ""//输入框文本
    var textMaxCount:Int = 500//输入框文本最大个数
    var headTitle:String = ""//输入框上面的 文字
    var cursorColor:UIColor = UIColor.rgb(20, 138, 242) //光标颜色
    var textColor:UIColor =  UIColor.label //输入文字颜色
    var headColor:UIColor = UIColor.white //head颜色
    var placeholderTextColor:UIColor = UIColor.gray //占位文字颜色
    var textViewTopMargin:CGFloat = 16 //上边距
    var textViewBottomMargin:CGFloat = 16 //上边距
    var textViewHeight:CGFloat = 32 //输入框高度
    var textViewLineSpacing:Int = 5//行简距离
    var isShowCameraButton:Bool = true//是否展示拍照按钮（最左）
    var isShowMoreButton:Bool = true//是否展示更多（加号）按钮（最右）
    var isShowVoiceButton:Bool = true//是否展示「键盘/语音」切换按钮（加号左侧）
    /// 两侧边距。2026-10-04 起口径变成**输入卡片距输入栏左右的距离**（卡片内部的
    /// 输入框与按钮再各自内缩一个 `InputToolbar.cardPaddingH`）。
    var horizontalMargin:CGFloat = 16
    var buttonSide:CGFloat = 32//两侧按钮边长
    var buttonGap:CGFloat = 10//按钮与输入框之间的间距
    var voiceButtonTitle:String = L("按住说话")//语音态盖在输入框上的按钮文案
    /// 加号附件面板里**那一行入口**的高度（面板总高另有出处：跟系统键盘等高，见 `InputToolbar.systemKeyboardHeight`）。
    /// 面板比这一行高出来的部分全部落在这行下方当留白。
    var panelHeight:CGFloat = 100
}
class InputToolbar: UIView {
    weak var delegate : InputToolbarDelegate?

    /// 键盘收起时额外附加到底部的安全区高度（由宿主注入，一般为 view.safeAreaInsets.bottom）
    var restingBottomInset: CGFloat = 0 {
        didSet { guard oldValue != restingBottomInset, !isKeyboardVisible else { return }; setNeedsLayout() }
    }
    /// 键盘收起时距宿主底部的距离（有 TabBar 时传 TabBar 高度，默认 0 贴底）
    var restingBottomOffset: CGFloat = 0
    /// 自身 frame 变化回调（键盘弹收、输入框增高都会触发），宿主据此调整列表内边距
    var onFrameChange: ((CGRect) -> Void)?
    /// 输入形态切换回调（true = 进入语音态）。宿主可借此提前请求麦克风/语音识别权限：
    /// 系统权限框一弹出就会强制松开手指，等到按住时才请求则这一次录音必然失败。
    var onInputModeChange: ((Bool) -> Void)?
    /// 待发附件里某一项被点了删除（回调下标）。**数据由宿主持有**，这里只负责「第几个被点了」。
    var onRemoveAttachment: ((Int) -> Void)?
    /// 附件预览条**末尾那颗「＋」**被点了（2026-10-08）⇒ 继续加附件。
    ///
    /// ⚠️ 它与按钮行里那颗「＋」**是两件事**，别混：
    /// - 按钮行那颗 = `attachmentEvent(_:)`，弹**面板**（相机 / 相册 / 文件三个入口）；
    /// - 预览条末尾这颗 = 直接**进系统相册**，一步到位、少一层面板。
    ///
    /// 同分工：这里只上报，宿主决定弹什么。
    var onAddAttachment: (() -> Void)?

    /// 待发 **@ 资料**里某一项被点了删除（回调下标，2026-10-21）。
    /// 同 `onRemoveAttachment` 的分工：数据在宿主，这里只报「第几个」。
    ///
    /// ⚠️ 宿主删 chip 时**要顺手删掉正文里那串 `@名字`**（见 VC 的实现）：
    ///    不删的话输入框里还留着名字、而这一轮其实不带它，用户会以为还带着。
    var onRemoveMention: ((Int) -> Void)?
    /// 附件数上限，会透给预览条用于**决定末尾那颗「＋」还摆不摆**。
    /// 真身是 `AIModuleViewController.maxAttachmentCount`，⛔ 别在工具栏里另写一个数字。
    ///
    /// ⚠️ 赋值顺序不可假设：宿主是 `viewDidLoad` 里设它，而附件可能**更早**由别处灌进来
    ///   ⇒ 走 `setMaxCount(_:)`（内部会重画），⛔ 别在 `didSet` 里只做赋值。
    var maxAttachmentCount: Int = .max {
        didSet { attachmentBar.setMaxCount(maxAttachmentCount) }
    }
    /// 状态条上那颗「取消」被点了（引用 → 清引用；编辑 → 退出编辑态）。
    /// 同样只上报，真正的状态在宿主。
    var onCancelBanner: (() -> Void)?

    /// 输入框**下方那一行**的模型名被点了。宿主负责弹列表、落库、回填文字。
    ///
    /// 分工与本类其他回调一致：输入栏只管**显示**与**上报点击**，
    /// 「现在在用哪条配置 / 换了之后写哪个指针」全是宿主的事（`AIConfig.currentID`），
    /// 这里绝不读配置 —— 读配置就等于把配置真值粘进视图层。
    var onTapModel: (() -> Void)?

    /// **按钮行**里那枚模型名胶囊要显示的文字。
    ///
    /// 🔴 会话页传的是 `AIModelCatalog.composerLabel()`（共享口径）：给当前那条配置的显示名，
    ///    一条配置都没有时给「未配置模型」（**永不返回空串**）——
    ///    那颗胶囊是 iOS 换模型的唯一入口，传空把它藏掉等于把出口焊死
    ///    （成因见 `AIModuleViewController.refreshModelState`）。
    ///    ⚠️ 2026-10-02 起「收起胶囊」**不等于「整行不占位」**：那一行里还有相机 / 语音 / 加号，
    ///       行高由 `buttonRowHeight` 决定（基本恒定），只有它自己消失。
    ///    ⚠️ 它进 `contentHeight()` ⇒ 与 `pendingAttachments` / `bannerKind` 同一套口径：
    ///       变了一定要 `sizeToFit()`（输入栏是底部锚点向上长高），否则会盖住列表底部。
    private(set) var modelTitle: String?

    /// 当前展示的待发附件。只用来算高度 / 驱动预览条，真身存在宿主（VC）里。
    private(set) var pendingAttachments: [AIAttachment] = []

    /// 附件预览条的高度贡献：有附件才占位。
    ///
    /// 🔴 2026-10-08 起这笔高度算在**卡片内部**（`cardContentHeight()` 里），
    ///    不再是卡片外面的一段 —— 用户要求「图片放在底部输入框（描边）内」。
    /// ⚠️ 它仍然是 `contentHeight()` 的实际组成部分（经由 `cardContentHeight()`），
    ///    所以增删附件后照样必须 `sizeToFit()`，否则输入栏高度不跟着变、盖住列表底部。
    private var attachmentBarHeight: CGFloat {
        pendingAttachments.isEmpty ? 0 : AIAttachmentBarView.barHeight
    }

    /// 当前展示的待发 **@ 项目资料**（2026-10-21）。与 `pendingAttachments` 同一分工：
    /// 只用来算高度 / 驱动 chip 条，真身存在宿主（VC）里。
    private(set) var pendingMentions: [AIMention] = []

    /// `@` 资料条的高度贡献：有内容才占位。
    /// 🔴 它在附件条**之下**、输入框**之上**（见 `cardContentHeight()` 那段的次序图），
    ///    所以 `frameTextView()` 的 y 偏移必须同时加上它 —— 漏了就是 chip 压在文字上。
    private var mentionBarHeight: CGFloat {
        pendingMentions.isEmpty ? 0 : AIMentionBarView.barHeight
    }

    /// 重设待发 `@` 资料（VC 是唯一数据源，每次变更都整体同步过来）。
    ///
    /// ⚠️ 与 `setAttachments` 不同，这里**不碰**「＋ ⇄ 发送」那颗按钮：
    ///    @ 资料**不能**单独发（它只是这一轮的参考资料，连问题都没有就没什么可发的），
    ///    所以「只 @ 了资料、一个字没打」时按钮仍是「＋」。
    func setMentions(_ items: [AIMention]) {
        let heightChanged = (items.isEmpty != pendingMentions.isEmpty)
        pendingMentions = items
        mentionBar.setItems(items)
        mentionBar.isHidden = items.isEmpty
        guard heightChanged else {
            setNeedsLayout()
            return
        }
        // 同附件条：高度变了要 `sizeToFit`（底部锚点向上长），否则会盖住列表底部
        sizeToFit()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    /// 重设待发附件（VC 是唯一数据源，每次变更都整体同步过来）
    func setAttachments(_ items: [AIAttachment]) {
        let heightChanged = (items.isEmpty != pendingAttachments.isEmpty)
        pendingAttachments = items
        attachmentBar.setItems(items)
        attachmentBar.isHidden = items.isEmpty
        let hasItems = !items.isEmpty
        // 🔴 加号按钮要跟着换面孔：有附件 ⇒「＋」变「发送」（附件条上那颗蓝色发送钮已删，
        //    入口只剩这一处）；附件清空 ⇒ 退回「＋」。
        // ⚠️ 这一句必须**无条件**跑，⛔ 别塞进下面 `guard heightChanged` 的 else 分支：
        //    「删到 0 张」恰好是高度**变了**的那一档，走不到 else 里 ⇒ 用户删完最后一张，
        //    按钮还停在蓝色发送态，既点不动也不回到「＋」面板。
        //    （判据只有 `moreButtonState` 一处，这里只负责把算出的结果落到视图上。）
        refreshMoreButtonState()
        guard heightChanged else {
            setNeedsLayout()
            return
        }
        // 高度变了：sizeToFit 保持**底部锚点**向上长高/缩回，正好是输入栏该有的行为
        // （跟着键盘上沿，而不是从顶部往下长）
        sizeToFit()
        setNeedsLayout()
        superview?.setNeedsLayout()
        // ⚠️ 收「+」面板必须排在 `sizeToFit` **之后**：`hideAttachmentPanel` 内部会按
        //    `heightThatFits()` 重摆 frame（那一次动画），抢在它前面改尺寸两者会打架。
        //
        // 🔴 附件一进待发区就收面板：面板顶着那块区域时按钮显示的是「✕」（关面板），
        //    附件选好了却没有发送入口 ⇒ 用户会以为「选完没反应」。
        if hasItems { hideAttachmentPanel(showKeyboard: false) }
    }

    /// 输入**卡片内部**那条状态条的当前内容（待发引用 / 正在编辑；**真身在宿主 VC**）。
    /// 这里只用于算高度与驱动那条视图 —— 同 `pendingAttachments` 的分工。
    private(set) var bannerKind: AIComposerBannerView.Kind?

    /// 状态条的高度贡献：有内容才占位。
    ///
    /// 🔴 2026-10-09 起它算在 **`cardContentHeight()`** 里（不再是 `contentHeight()` 的独立一项）
    ///    —— 状态条已搬进描边卡片内部，与 `attachmentBarHeight` **完全同一口径**。
    /// ⚠️ 少算这一项的症状：卡片比输入栏矮一截（状态条压在卡片上沿外 / 与卡片上沿齐平）。
    private var bannerHeight: CGFloat {
        bannerKind == nil ? 0 : AIComposerBannerView.barHeight
    }

    // MARK: - 按钮行（相机 · 模型名 · 语音 · 加号，同在输入框下方一行）

    /// 模型名胶囊的高度（**小于**行高，行内垂直居中）。
    static let modelRowHeight: CGFloat = 26
    /// 卡片**底部**与输入栏底沿的留白。
    ///
    /// 原来叫「按钮行底部与输入栏底沿的留白」，含义没变（卡片底沿就在按钮行下面一拍），
    /// 只是 2026-10-04 起中间多了一层卡片边框。
    static let modelRowBottomGap: CGFloat = 8

    // MARK: - 输入卡片（描边外框，2026-10-04 加）

    /// 🔴 输入框与按钮行（相机 / 模型名 / 语音 / 加号）**全部装进一张带描边的圆角卡片**里，
    ///    底部整块看起来是一个整体。
    ///    用户原话：「增加描边，把输入框和底部按钮、模型名称等都放置描边内，使底部看着像整体」。
    ///
    /// 形态：卡片外沿 = `configure.horizontalMargin`（16）⇒ 与状态条 / 附件条的左右对齐口径一致；
    ///      内部再留 `cardPaddingH`，输入框与两侧按钮都从卡片内缘往里缩。
    ///
    /// ⚠️ 卡片是**纯背景**角色（两层视图，见 `composerCard` / `composerCardSurface`）：
    ///    不吃触摸（`isUserInteractionEnabled = false`），命中测试直接穿透到上面真正的控件。
    static let cardCornerRadius: CGFloat = 22
    /// 描边宽度（外层卡片与内层底色之间那一圈）
    static let cardBorderWidth: CGFloat = 1
    /// 卡片**内部**左右留白：输入框与两侧按钮都从卡片内缘再缩这么多 ⇒ 不贴着描边
    static let cardPaddingH: CGFloat = 8
    /// 卡片**内部**上 / 下留白
    static let cardPaddingTop: CGFloat = 8
    static let cardPaddingBottom: CGFloat = 8
    /// 语音态「按住说话」那颗盖在输入框位置上的圆角（属卡片内部件，跟着卡片内缘走）
    static let voicePillCornerRadius: CGFloat = 14

    /// 按钮行对 `contentHeight()` 的贡献。
    ///
    /// 🔴 2026-10-02 布局调整后它**基本恒等于 `buttonSide`**：这一行不再是「有模型名才有」——
    ///    相机 / 语音 / 加号本来就在这行里。只有三个开关全关**且**没有模型名时才归 0
    ///    （纯防御：那种配置下这行确实什么都不剩）。
    /// ⚠️ 2026-10-04 起它还多担一职：卡片内部「输入框 ↔ 按钮行」的间距与卡片下内边距
    ///    只在有这一行时才加（见 `cardContentHeight()`）。
    private var buttonRowHeight: CGFloat {
        let hasAnyButton = configure.isShowCameraButton
            || configure.isShowVoiceButton
            || configure.isShowMoreButton
        let hasModel = !(modelTitle?.isEmpty ?? true)
        return (hasAnyButton || hasModel) ? configure.buttonSide : 0
    }

    /// 设置 / 清除状态条内容（nil = 清除）。
    ///
    /// 高度变化时必须 `sizeToFit()`：输入栏是「底部锚点」向上长高/缩回，
    /// 不重新定尺寸的话会盖住列表底部（或在收起时留一条空白）。
    /// 内容变化但高度没变（引用 A 换成引用 B）只需重画，不必动尺寸。
    func setBanner(_ kind: AIComposerBannerView.Kind?) {
        let heightChanged = (kind == nil) != (bannerKind == nil)
        bannerKind = kind
        bannerView.configure(kind: kind)
        guard heightChanged else {
            setNeedsLayout()
            return
        }
        sizeToFit()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    /// 设置按钮行里那枚模型名胶囊的文字（`nil` / 空 = 收起胶囊）。
    ///
    /// 与 `setBanner` 同一套节奏：只在「胶囊有没有」真的变了才 `sizeToFit()`
    /// （换模型只是换个名字时，重画按钮文字就够了，不必重算尺寸）。
    /// ⚠️ 2026-10-02 起这一步多半是个 no-op —— 按钮行的高度由三颗按钮撑着，
    ///    胶囊在与不在都不改变行高；留着是为了「三颗按钮全关 + 没有模型名 ⇒ 整行归 0」那条路。
    func setModelTitle(_ title: String?) {
        let normalized = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (normalized?.isEmpty ?? true) ? nil : normalized
        let heightChanged = (value == nil) != (modelTitle == nil)
        modelTitle = value
        applyModelTitle()
        guard heightChanged else {
            setNeedsLayout()
            return
        }
        sizeToFit()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    /// 把 `modelTitle` 刷到胶囊上（文字 + 显隐 + 无障碍标签）。
    private func applyModelTitle() {
        guard let title = modelTitle else {
            modelButton.isHidden = true
            return
        }
        modelButton.isHidden = false
        var config = modelButton.configuration ?? Self.makeModelButtonConfiguration()
        config.title = title
        modelButton.configuration = config
        // 按钮宽度按内容自适应 ⇒ 换了个长名字必须作废缓存宽度（见 `layoutSubviews`）
        modelButton.invalidateIntrinsicContentSize()
        // 念出来的是「当前模型 X，可切换」—— 光念模型名，读屏用户不知道它能点
        modelButton.accessibilityLabel = String(format: L("当前模型 %@，点按切换模型"), title)
    }

    /// 换「字体大小」档位后，把**模型名胶囊**的字号重算一遍
    /// （`AIFontSizeStore.didChange` 的收件箱之一，由宿主 VC 转调）。
    ///
    /// 🔴 为什么必须**整体重设 configuration**：`titleTextAttributesTransformer` 是存在
    ///    configuration 里的**闭包**，只在 configuration 被应用到按钮时求值一次。换档后
    ///    按钮上挂的还是旧闭包（按旧 `uiScale` 算出的字号）⇒ 拿 `makeModelButtonConfiguration()`
    ///    造一份新的整体赋值，新闭包才进得去。⛔ 别想着「只改 font 一项」—— transformer
    ///    不单独刷新，改 `config.titleTextAttributes` 也不会重跑 transformer。
    /// ⚠️ 胶囊收起（`modelTitle == nil`）时也要设：`applyModelTitle` 是「复用 button 上
    ///    那份 configuration」的，不收这里的刷新；不设的话下次展开模型名就变回旧字号。
    func applyChromeFonts() {
        var config = Self.makeModelButtonConfiguration()
        config.title = modelTitle
        modelButton.configuration = config
        // 宽度按内容自适应 ⇒ 字号变了必须作废缓存宽度（见 `layoutSubviews`）
        modelButton.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private var isKeyboardVisible = false

    /// 最近一次**真实系统键盘**的高度（屏幕坐标，已含底部安全区）。
    ///
    /// 「+」面板要跟它对**等高** —— 这是观感的关键，不是动画曲线：
    /// 面板比键盘矮（例如只有 134pt）时，点「+」= 键盘消失 + 输入栏**往下掉 200pt** +
    /// 面板在掉出来的空隙里淡入，两件事同时发生，再怎么调曲线都突兀。
    /// 等高时输入栏**一动不动**，看起来只是「键盘那块区域换了内容」——
    /// 豆包 / DeepSeek 那种顺滑感就来自这一步，不是动画参数。
    private var lastKeyboardHeight: CGFloat = 0

    /// 上一次启动实测到的键盘高度，**落盘**。
    /// 面板高度不能依赖「本次启动弹过键盘」：冷启动进来直接点「文件」时还没有任何实测值，
    /// 面板会矮一截，等用户弹过一次键盘后又突然变高 —— 同一个面板两种高度。
    private static let keyboardHeightDefaultsKey = "ai_chat_keyboard_height"
    private lazy var persistedKeyboardHeight =
        CGFloat(UserDefaults.standard.double(forKey: Self.keyboardHeightDefaultsKey))

    /// 输入形态：text（正常输入）/ voice（用「按住说话」盖住输入框，按住录音）
    private enum InputMode { case text, voice }
    private var inputMode: InputMode = .text

    /// 是否正在生成（流式进行中）。只用来决定右下角那颗按钮是「＋」还是「停止」，
    /// 由宿主调 `setStreaming(_:)` 维护 —— **开始与结束必须成对**。
    private var isStreaming = false

    /// 右下角那颗按钮当前的**面孔**（图标 + 点击行为），单一判据出口。
    ///
    /// 🔴 2026-10-08 起一共四种（此前三种），优先级从上到下：
    /// ```
    /// 1. 生成中          → 「停止」圆钮（stopButton **顶替**加号的位置，不是并排）
    /// 2. 「+」面板开着    → 「✕」（点它收起面板 + 弹回键盘）
    /// 3. 有待发附件      → 「↑ 发送」（点它把附件与文字一起发出去）
    /// 4. 其余            → 「＋」（点它顶起附件面板）
    /// ```
    /// 为什么「有附件」排在「面板开着」**后面**：面板开着时用户还在挑附件，此刻点那颗钮的
    /// 意图是「收起面板」，不是「现在就发」。而面板一收（第 3 条接管）就变成发送钮。
    /// ⚠️ 「停止」不是这张表的一格而是**另一颗按钮顶替位置**（`stopButton`，见 `layoutSubviews`），
    ///    它存在的原因是生成中不该还能发出去。
    /// ⚠️ 附件条右侧那颗蓝色发送钮**已删**（2026-10-08 用户要求）⇒ 第 3 条是「只发图不打字」
    ///    的**唯一**出口，⛔ 别把它一起删掉或改回只发文字。
    private enum MoreButtonState {
        case plus, panelOpen, send, streaming

        var iconName: String {
            switch self {
            case .plus:      return "plus"
            case .panelOpen: return "xmark"
            case .send:      return "arrow.up"
            case .streaming: return "stop.fill"
            }
        }
        /// 发送态要更醒目：主色实心圆 + 白箭头（其余都是灰底 + label 色）。
        /// ⛔ 别用 `.secondarySystemFill`：那与另外两颗按钮一模一样，用户看不出这颗现在是「发」。
        var isProminent: Bool { self == .send }
    }

    /// 当前该显示哪张面孔。**纯计算**，不碰视图 —— 显隐/布局仍在 `layoutSubviews`。
    private var moreButtonState: MoreButtonState {
        if isStreaming { return .streaming }
        if isAttachmentPanelVisible { return .panelOpen }
        if !pendingAttachments.isEmpty { return .send }
        return .plus
    }

    /// 按 `moreButtonState` 刷那颗钮的图标与配色（带 crossDissolve 过渡）。
    ///
    /// ⚠️ 时长与面板进场、输入栏位移统一到 `AIAttachmentPanelView.appearDuration`：
    ///    图标 0.2 先变完、面板 0.25 才到位会显得图标「抢跑」，三者同节奏观感才是一体的。
    private func refreshMoreButtonState() {
        // 整颗钮被配置关掉时不必刷（它永远不可见，见 `layoutSubviews`）。
        // ⚠️ 别写成 `guard state != .streaming`：关掉这颗钮时 `showsStop` 也是 false
        //    （它要求 `isShowMoreButton`），此时刷图标纯属白做。
        guard configure.isShowMoreButton else { return }
        let state = moreButtonState
        UIView.transition(with: moreButton,
                          duration: AIAttachmentPanelView.appearDuration,
                          options: [.transitionCrossDissolve, .beginFromCurrentState]) {
            self.moreButton.setImage(UIImage(systemName: state.iconName), for: .normal)
            // 配色跟着状态走。⚠️ 「＋ / ✕」两态必须回到调用方给三颗按钮设的统一外观
            //    （configureInputToolbar 里那个循环），否则从发送态退回时会留着一颗蓝钮。
            self.moreButton.backgroundColor = state.isProminent
                ? .systemBlue
                : .secondarySystemFill
            self.moreButton.tintColor = state.isProminent ? .white : .label
        }
        // 发送态顺带说清它是干什么的（读屏用户看不到图标）
        moreButton.accessibilityLabel = (state == .send) ? L("发送") : nil
    }

//    var keepsPreModeTextViewWillEdited:Bool = true
    override init(frame: CGRect) {
        super.init(frame: frame)
//        backgroundColor = UIColor.white
//        isHidden = true
        contentMode = .redraw
        isExclusiveTouch = true
//        keepsPreModeTextViewWillEdited = true
//        addSubview(headView)
//        headView.addSubview(headTitleLabel)
        // 输入卡片（描边外框）：**最先加** = 层级最低，垫在输入框与按钮行下面当背景。
        // 它底下再垫一层底色（`composerCardSurface`），两层叠出「一圈描边」的效果，
        // 明细见 `composerCard` 头注。⚠️ 两层都不吃触摸，命中测试穿透到上面的控件。
        addSubview(composerCard)
        composerCard.addSubview(composerCardSurface)
        // 附件面板是**自家子视图**（不再当 `textView.inputView`）：挂在输入行下方，
        // 输入栏「长高」就是它顶起来了。挂在自家视图树里的最大好处是——
        // 相册 / 文件那种全屏系统 picker 顶上来时，面板不会被系统连着键盘一起收走。
        addSubview(attachmentPanel)
        addSubview(bannerView)
        addSubview(attachmentBar)
        // `@` 资料条：附件条之下、输入框之上（层级与摆放次序见 `layoutSubviews`）
        addSubview(mentionBar)
        addSubview(textView)
        // 输入框下方那一行（模型名）—— 与语句顺序无关，它俩在竖向不重叠
        addSubview(modelButton)
        addSubview(voiceInputButton)
        addSubview(cameraButton)
        // 联网搜索开关：紧挨相机右侧（位置在 `layoutSubviews` 里接在相机之后算）
        addSubview(webSearchButton)
        // （项目资料检索那颗放大镜 2026-10-23 已删：用户拍板「默认关闭 + 删入口」，
        //  底层检索链路全保留，恢复指南见 VERIFY-PROBES.md §32.4）
        addSubview(modeButton)
        addSubview(moreButton)
        // 「停止」与「+」同位（生成中互相顶替），先后无妨，靠 isHidden 决定命中
        addSubview(stopButton)
        // 最后添加 = 层级最高，面板顶起时才能盖住 textView 接管点击
        addSubview(keyboardSwitchButton)
        
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification , object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame), name: UIResponder.keyboardWillChangeFrameNotification , object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification , object: nil)
    }
    
    override func layoutSubviews(){
        super.layoutSubviews()
        // 「+」面板贴在输入行下方（高度固定，见 `syncAttachmentPanelFrame`）
        syncAttachmentPanelFrame()
        let side = configure.buttonSide
        let gap = configure.buttonGap

        // 🔴 输入卡片（描边外框，2026-10-04 加；2026-10-08 附件条搬进来）：输入框 + 按钮行
        //    （+ 待发附件条）都在它里面。
        //    卡片 frame **只由内容高 + 内部留白决定**（`frameCard()`），不依赖下面那些控件 frame，
        //    所以先摆它、再摆里面的人。内层底色四周内缩 `cardBorderWidth` ⇒ 两层的差就是那圈描边。
        let card = frameCard()
        composerCard.frame = card
        composerCardSurface.frame = composerCard.bounds.insetBy(dx: Self.cardBorderWidth,
                                                               dy: Self.cardBorderWidth)

        // 🔴 状态条现在住在**卡片内部最上方**（输入框之上、附件条之上；2026-10-09）。
        //    左右铺满卡片内缘，由 `AIComposerBannerView` 自己内缩（⛔ 别再在这里减宽度）。
        // ⚠️ 它与附件条的先后**不能颠倒**：用户先看到的是「这次发送属于哪种情形」，
        //    再说「带了什么附件」—— 搬进卡片前就是这个上下次序（状态条在卡片外、附件条在卡片内顶部）。
        bannerView.frame = CGRect(x: card.minX,
                                  y: card.minY + Self.cardPaddingTop,
                                  width: card.width,
                                  height: bannerHeight)
        // 🔴 附件预览条在**状态条之下**（卡片内部，2026-10-08；次序 2026-10-09 定下）。
        //    左右同样铺满卡片内缘，由 `AIAttachmentBarView` 自己内缩 8（⛔ 别再在这里减宽度）。
        attachmentBar.frame = CGRect(x: card.minX,
                                     y: card.minY + Self.cardPaddingTop + bannerHeight,
                                     width: card.width,
                                     height: attachmentBarHeight)
        // 🔴 `@` 资料条在**附件条之下、输入框之上**（2026-10-21）。
        //    次序的理由：附件是「我要发出去的东西」，@ 是「我参考的东西」——
        //    前者更靠外（离用户的手更近），后者更贴输入框（它是输入这一句的上下文）。
        //    ⚠️ 与 `cardContentHeight()` / `frameTextView()` 三处的次序必须一模一样，
        //    漏一处就是「chip 压着文字」或「卡片比内容高一条」——都不报错，只是看着错位。
        mentionBar.frame = CGRect(x: card.minX,
                                  y: card.minY + Self.cardPaddingTop + bannerHeight + attachmentBarHeight,
                                  width: card.width,
                                  height: mentionBarHeight)

        textView.frame = frameTextView()
        // 🔴 按钮行在**输入框下方**（2026-10-02 用户要求：相机 / 语音输入 / 加号 / 模型名 同行）。
        //    四颗元素共用这一个 y 基准，行高 = `configure.buttonSide`。
        //    ⛔ 别再退回「按钮与输入框同行、跟着输入框底部对齐」——那样输入框两侧被按钮夹住，
        //       模型名就只剩下方一行可待，正是这次要改掉的形态。
        //    ⚠️ 2026-10-04 起整行都在**卡片内部**：左右从卡片内缘 + `cardPaddingH` 起算，
        //       ⛔ 不再直接贴 `configure.horizontalMargin`（那样按钮会压到描边上）。
        let rowLeft = card.minX + Self.cardPaddingH
        let rowRight = card.maxX - Self.cardPaddingH
        let buttonY = textView.frame.maxY + configure.textViewBottomMargin
        // 语音态：用「按住说话」按钮盖住输入框，输入框本身隐藏（避免光标/选中态露出）
        voiceInputButton.frame = textView.frame
        // 圆角走自己的常量（输入框已经没圆角了，抄它只会抄到一个 0）
        voiceInputButton.layer.cornerRadius = Self.voicePillCornerRadius
        voiceInputButton.isHidden = (inputMode != .voice)
        textView.isHidden = (inputMode == .voice)

        // 面板顶起时用透明按钮盖住输入框（点它切回键盘，见该按钮的注释）。
        // 面板收起时隐藏 → 命中测试直接落到 textView，不影响原生的「点一下开始编辑」。
        keyboardSwitchButton.frame = textView.frame
        keyboardSwitchButton.isHidden = !isAttachmentPanelVisible

        cameraButton.isHidden = !configure.isShowCameraButton
        cameraButton.frame = configure.isShowCameraButton
            ? CGRect(x: rowLeft, y: buttonY, width: side, height: side)
            : .zero

        // 联网搜索（2026-10-21）：紧挨相机右侧，**恒显示**（它是开关，不是随态出现的入口）。
        // 相机隐藏时它就顶到卡片内缘。⚠️ 它必须排在 `cameraButton.frame` 之后（用它当锚点），
        // 又要排在模型胶囊之前（胶囊的左边界要读它的右缘）。
        let webSearchX = cameraButton.isHidden ? rowLeft : cameraButton.frame.maxX + gap
        webSearchButton.frame = CGRect(x: webSearchX, y: buttonY, width: side, height: side)

        // （项目资料检索那颗放大镜 2026-10-23 已删 —— 它原先紧挨联网右侧、只在会话
        //  属于某个项目时出现。删了之后模型胶囊的左端直接退回到联网键右缘，见下面
        //  `zoneMinX`；底层检索链路全保留，恢复指南见 VERIFY-PROBES.md §32.4）

        // 右侧两个按钮从右往左排：加号最靠边，切换按钮在其左侧。
        // ⚠️ 生成中「停止」**顶替**加号的位置（不是并排多一颗）：位置重合，
        //    用户不用重新找；输入框宽度也不会被挤。
        var rightX = rowRight - side
        let showsStop = isStreaming && configure.isShowMoreButton
        moreButton.isHidden = !configure.isShowMoreButton || showsStop
        moreButton.frame = moreButton.isHidden
            ? .zero
            : CGRect(x: rightX, y: buttonY, width: side, height: side)
        stopButton.isHidden = !showsStop
        stopButton.layer.cornerRadius = side / 2
        stopButton.frame = showsStop
            ? CGRect(x: rightX, y: buttonY, width: side, height: side)
            : .zero
        if configure.isShowMoreButton { rightX -= (side + gap) }

        modeButton.isHidden = !configure.isShowVoiceButton
        modeButton.frame = configure.isShowVoiceButton
            ? CGRect(x: rightX, y: buttonY, width: side, height: side)
            : .zero

        // 模型名胶囊：**与上面三颗按钮同一行**，在两侧按钮之间**居中**。
        //
        // 🔴 居中判据是「可用区间的中点」而不是整行中点：左右两侧按钮数量不等
        //    （左边相机 1 颗、右边语音 + 加号 2 颗），按整行中点摆会被右边那两颗挤得偏右，
        //    看着就不在中间了。区间两端直接读刚摆好的按钮 frame ⇒ 不需要第二份尺寸账。
        // ⚠️ 这一段必须排在**三颗按钮 frame 之后**（它靠按钮 frame 当边界）。
        // ⚠️ 行高与 y 也不是随手写的：`contentHeight()` 里加了同一份 `buttonRowHeight`
        //    （间距 + 行高 + `modelRowBottomGap`）⇒ 两处必须同步，
        //    否则输入栏总高与这一行的实际位置会差一截（表现为列表底部被多盖/少盖一条）。
        let hasModel = !(modelTitle?.isEmpty ?? true)
        modelButton.isHidden = !hasModel
        if hasModel {
            // 左端：联网键右缘（项目资料检索那颗放大镜 2026-10-23 已删 ——
            //      它原先出现时左端读它的右缘，现在恒退到 globe 右缘）
            let zoneMinX = webSearchButton.frame.maxX + gap
            // 右端：从右往左第一颗按钮的左缘（生成中是「停止」，平时是「＋」，再左边是语音）；
            //      一颗都没有时收到卡片内缘（同 `rowRight`）
            var zoneMaxX = rowRight
            let rightmostButton = moreButton.isHidden ? stopButton : moreButton
            if !rightmostButton.isHidden { zoneMaxX = rightmostButton.frame.minX - gap }
            if !modeButton.isHidden { zoneMaxX = modeButton.frame.minX - gap }

            let zoneWidth = max(zoneMaxX - zoneMinX, 0)
            let fitted = modelButton.sizeThatFits(CGSize(width: zoneWidth,
                                                         height: Self.modelRowHeight))
            let width = min(fitted.width, zoneWidth)
            modelButton.frame = CGRect(x: (zoneMinX + zoneMaxX - width) / 2,
                                       y: buttonY + (side - Self.modelRowHeight) / 2,
                                       width: width,
                                       height: Self.modelRowHeight)
        } else {
            modelButton.frame = .zero
        }

        layoutPlaceholder()
        refreshTextUI()
    }

    /// 自行给占位 Label 布局并控制显隐，不依赖系统私有 _placeholderLabel 的托管
    private func layoutPlaceholder() {
        guard let lb = textView.placeholderLabel else { return }
        let inset = textView.textContainerInset
        let width = max(textView.bounds.width - inset.left - inset.right, 0)
        let size = lb.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        lb.frame = CGRect(x: inset.left, y: inset.top, width: width, height: size.height)
        lb.isHidden = !(textView.text.isEmpty && textView.markedTextRange == nil)
    }
    // MARK: - 更新属性
    func refreshAttribute(){
        self.textView.font = configure.font
        if !configure.text.isEmpty {
            self.textView.text = configure.text
        }
        // let lineH = self.textView.font?.lineHeight
        /*
        if !InputToolbar.configure.headTitle.isEmpty {
            self.headTitleLabel.text = InputToolbar.configure.headTitle
            self.headView.isHidden = false
            self.headView.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 45)
            self.headTitleLabel.frame = CGRect(x: 16, y: 5, width: UIScreen.main.bounds.width - 32, height: 40)
        } else {
            self.headView.isHidden = true
            self.headView.frame = .zero
            self.headTitleLabel.frame = .zero
        }*/
        self.textView.tintColor = isAttachmentPanelVisible ? .clear : configure.cursorColor
        self.textView.textColor = configure.textColor
        self.textView.placeholder = configure.placeholder
        self.textView.placeholderColor = configure.placeholderTextColor
        self.textView.placeholderFont = configure.font
        self.textView.textContainerInset = UIEdgeInsets(top: 6, left: 14, bottom: 4, right: 10)
        self.headView.backgroundColor = configure.headColor
        // 语音态按钮文案与切换图标按当前形态刷新
        self.voiceInputButton.setTitle(configure.voiceButtonTitle, for: .normal)
        self.modeButton.setImage(
            UIImage(systemName: inputMode == .voice ? "keyboard" : "mic"), for: .normal
        )
    }
    func updateWithConfig(configBlock: @escaping InputToolbarConfigureClosure) {
//        if let block = configBlock {
        configBlock(configure)
//        }
        refreshAttribute()
    }
    /// 输入框自身应有的高度（按行数上下限收敛）
    private func fittedTextHeight() -> CGFloat {
        let usedHeight = textUsedHeight + textViewVerticalInset
        let minHeight = self.heightWithLine(configure.textViewMinLine)
        let maxHeight = self.heightWithLine(max(configure.textViewMaxLine, configure.textViewMinLine))
        return min(maxHeight, max(minHeight, usedHeight))
    }

    /// 文本已经占用的高度。**TextKit2 优先，绝不碰 `layoutManager`。**
    ///
    /// ⚠️⚠️ 这里是「输入框长按弹不出编辑菜单（连放大镜和『粘贴』气泡都没有）」的根因，别改回去：
    /// iOS 16+ 上，**只要访问一次 `textView.layoutManager`**，`UITextView` 就会从 TextKit2
    /// 退化成 TextKit1 兼容模式；退化如果发生得**晚**（老代码是在首次 `layoutSubviews` /
    /// `heightThatFits()` 里量的高），UIKit 那套建立在 TextKit2 上的文本交互就被留在半坏状态 ——
    /// 长按输入框什么都不弹（不是被谁拦了，是系统那套交互压根没起来）。Apple DTS 在
    /// Xcode 16 + iOS 18 上确认过这个 case（Developer Forums thread 773540）。
    /// 对比：设置页那个 API Key 输入框是 `UITextField`，没有 `layoutManager`，所以它一直正常。
    ///
    /// 取法：`textLayoutManager` 非 nil 就走 TextKit2（`UITextView.textLayoutManager` 是 **iOS 16+**，
    /// 且只有**没退化过**的实例才非 nil）；iOS 14/15，或这个实例**已经**退化了
    /// （此时再碰 `layoutManager` 不会产生新的退化）才走老路。
    ///
    /// ⚠️ TextKit2 这里**没有** `ensureLayout(for: NSTextContainer)`，只有
    /// `ensureLayout(for: NSTextRange)` —— 传 `tlm.documentRange` 才是「整篇布局落地」。
    private var textUsedHeight: CGFloat {
        if #available(iOS 16.0, *), let tlm = textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            let used = tlm.usageBoundsForTextContainer.height
            // 文本已经不为空、usageBounds 却还是 0 → 布局尚未落地，用 sizeThatFits 兜底
            // （同样不碰 layoutManager；否则输入栏会卡在最小行高、多行输入时不长高）
            if used > 0 || textView.text.isEmpty {
                return used
            }
            let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width,
                                                       height: .greatestFiniteMagnitude)).height
            return max(fitting - textViewVerticalInset, 0)
        }
        return textView.layoutManager.usedRect(for: textView.textContainer).size.height
    }

    /// 强制文本布局立即落地（`clearText` 之后要马上量高，不能读到旧值）。同样避开 `layoutManager`。
    private func ensureTextLayout() {
        if #available(iOS 16.0, *), let tlm = textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            return
        }
        textView.layoutManager.ensureLayout(for: textView.textContainer)
    }

    /// 内容高度（不含底部安全区）。
    ///
    /// ⚠️ 2026-10-09 起**卡片外面什么都不留**了：状态条（引用 / 编辑）与附件条
    ///    **都在卡片内部**（都算在 `cardContentHeight()` 里）。
    ///    ⛔ 别再在这里加 `bannerHeight` 或 `attachmentBarHeight`
    ///    —— 加了输入栏会比实际高一截（列表底部被多盖一条，卡片下方还凭空多一道空隙）。
    /// ⚠️ 2026-10-02 起**按钮行也算**（`buttonRowHeight` + 行底留白）：
    ///    相机 / 模型名 / 语音 / 加号这四颗就在输入框下方实打实占着一行，
    ///    漏算的表现是最后几条消息被它盖住。
    /// ⚠️ 2026-10-04 起输入框 + 按钮行被**卡片**包住，所以这里改成
    /// 「卡片上方留白 + 卡片本体（`cardContentHeight()`）+ 卡片下方留白」——
    /// ⛔ 别再直接加 `fittedTextHeight()` / `textViewBottomMargin`，那会把卡片内部的
    /// 上下留白漏掉，输入栏总高与卡片实际画出来的高度就对不上（列表底部被多盖/少盖）。
    func contentHeight() -> CGFloat {
        configure.textViewTopMargin                 // 卡片**上方**留白
            + cardContentHeight()                   // 卡片本体（含状态条 + 附件条）
            + Self.modelRowBottomGap                // 卡片**下方**留白（到输入栏底沿）
    }

    /// 输入卡片**本体**的高度 = 内部上留白 +（状态条）+（附件条）+ 输入框 +（按钮行：与其间距 + 行高 + 内部下留白）。
    ///
    /// 🔴 2026-10-08 起附件条是**卡片内部的第一段**（在输入框之上）——
    ///    用户原话「图片的位置需要放在底部输入框，也就是描边内」。
    /// 🔴 2026-10-09 起**状态条也搬进来了**（在附件条之上，仍是它俩中更靠上的那一个）——
    ///    用户原话「引用和编辑的文本现在在输入框的描边上面，现在需要放在输入框的描边内」。
    ///    ⇒ 卡片内部自上而下三段：**状态条 →（附件条 →）输入框 →（按钮行）**，
    ///    顺序与搬进来之前在屏幕上看到的**完全一致**（原来是「状态条 / 卡片顶 / 附件条」）。
    /// ⚠️ 没有按钮行（三颗按钮全关且没有模型名，纯防御路径）时只剩内部下留白。
    /// ⚠️ 它必须与 `layoutSubviews` 里 `frameCard()` 用的是**同一份账**（`frameCard` 直接调它）。
    private func cardContentHeight() -> CGFloat {
        let textHeight = max(fittedTextHeight(), configure.textViewHeight)
        var height = Self.cardPaddingTop + bannerHeight + attachmentBarHeight + mentionBarHeight + textHeight
        if buttonRowHeight > 0 {
            height += configure.textViewBottomMargin    // 输入框 ↔ 按钮行的间距（卡片内）
                + buttonRowHeight
                + Self.cardPaddingBottom
        } else {
            height += Self.cardPaddingBottom
        }
        return height
    }

    func heightThatFits() -> CGFloat{
        // 底部这一段被键盘 / 面板占着时，安全区不再叠加（面板自带安全区，见 `panelTotalHeight`）
        contentHeight() + bottomOccupancy()
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        return CGSize(width: size.width, height: heightThatFits())
    }

    override func sizeToFit() {
        let size = sizeThatFits(bounds.size)
        frame = CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// 当前输入框文本（宿主发送附件时取用：有可能一个字都没打）
    var currentText: String { textView.text ?? "" }

    // MARK: -  public method
    func clearText(){
        textView.text = ""
        ensureTextLayout()
        sizeToFit()
        setNeedsLayout()
    }

    // MARK: - @ 项目资料（2026-10-21）

    /// 把一条资料插成正文里那串 `@文件名 `。
    ///
    /// 🔴 **只动正文，不动数据**：chip 由宿主（VC）持有并通过 `setMentions` 灌进来 ——
    ///    这里做两件事（插入 token、清掉那个裸 `@`）是纯文本操作，方便一起撤销 / 编辑。
    /// ⚠️ 一律**接在末尾**而不是插在光标处：选择页一弹，键盘与光标位置都收走了，
    ///    这时硬去猜插入点只会插歪。末尾追加在「@ 后接着写」的主用法下是正确的。
    func insertMentionToken(_ mention: AIMention) {
        var text = textView.text ?? ""
        if text.hasSuffix("@") {
            // 用户刚打的那个 `@`（触发选择页的那一个）直接被 token 顶掉
            text.removeLast()
            text += mention.token()
        } else {
            // 结尾没有裸 `@`（比如面板是从别处打开的）：补一个空格再追加
            if !text.isEmpty, !text.hasSuffix(" ") { text += " " }
            text += mention.token()
        }
        textView.text = text
        // 光标放到末尾：不然接下去打字会插在文本中间（`textView.text =` 会把选中区复位到 0）
        let end = (text as NSString).length
        textView.selectedRange = NSRange(location: end, length: 0)
        ensureTextLayout()
        sizeToFit()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    /// 从正文里抹掉某条资料对应的那串 `@文件名`（chip 上点 ✕ 时调）。
    ///
    /// ⚠️ 只删**第一处**：同一份资料重复 @ 两次时，删 chip 删一次、正文也只该少一处。
    ///    真值在 chip 那边（见 `AIMention` 文件头），正文不同步最多是一串多余的字，不会多发资料。
    func removeMentionToken(_ mention: AIMention) {
        let text = textView.text ?? ""
        guard let range = text.range(of: mention.token()) else {
            // 末尾那种没带空格的写法（`… @名字`）：兜一手
            guard let bare = text.range(of: "@\(mention.displayName)") else { return }
            var next = text
            next.removeSubrange(bare)
            textView.text = next
            ensureTextLayout()
            sizeToFit()
            setNeedsLayout()
            return
        }
        var next = text
        next.removeSubrange(range)
        textView.text = next
        ensureTextLayout()
        sizeToFit()
        setNeedsLayout()
    }

    /// 主动触发发送（键盘 return 走这里）。
    ///
    /// ⚠️ 空文本时**直接返回**：`enablesReturnKeyAutomatically = true` 时 UIKit 本来就把
    ///    return 置灰，这条 guard 是双保险。
    /// 🔴 「只发图不打字」靠的是那颗**加号切成发送钮**（`delegate?.sendCurrentInputEvent()`），
    ///    不是这条路 —— 别为了让空文本也能 return 就改成调用 `sendEvent("")`。
    func triggerSend() {
        let newMessage = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newMessage.isEmpty else { return }
        delegate?.sendEvent(newMessage)
    }

    /// 切换「正在生成」外观：右下角那颗钮 ⇄「停止」（显隐在 `layoutSubviews`，图标在这里刷）。
    ///
    /// 由宿主在**开始生成 / 生成结束（含出错、被停止）**时调用，必须成对 ——
    /// 漏掉复位那一次，按钮会一直停在「停止」上，用户再也点不出「+」面板。
    func setStreaming(_ streaming: Bool) {
        guard isStreaming != streaming else { return }
        isStreaming = streaming
        // 生成开始时把「+」面板收掉：面板开着时那颗按钮要变成「停止」，
        // 用户此时若想关面板会发现 ✕ 不见了（同一个位置已经被占）。
        // 走「点空白收起」那条路：不弹键盘、观感一致。
        if streaming { dismissAttachmentPanelForBlankTap() }
        // 图标/配色跟着走（否则生成结束后那颗钮会停在生成中的面孔上）
        refreshMoreButtonState()
        // 立即落地：按钮显隐不该等下一次布局（否则生成开始后还能点到已经没用的「+」）
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// 当前是否处于语音态
    var isVoiceMode: Bool { inputMode == .voice }

    /// 从外部切回文本态（权限被拒等场景）
    func showTextMode(focus: Bool) {
        // 面板开着先收掉：否则下面 focus 会「按不动」（键盘与面板会抢底部同一段）
        dismissAttachmentPanelImmediately()
        if inputMode == .voice { switchToTextMode(showKeyboard: focus) }
        else if focus { textView.becomeFirstResponder() }
    }

    // MARK: - getter / setter
    lazy var configure:InputToolbarConfigure = {
        let configure = InputToolbarConfigure()
        return configure
    }()

    lazy var headView: UIView = {
        let headView = UIView()
        headView.backgroundColor=UIColor.white
        return headView
    }()
    lazy var headTitleLabel: UILabel = {
        let headTitleLabel = UILabel()
        headTitleLabel.textColor = UIColor.gray
        headTitleLabel.font = UIFont.systemFont(ofSize: 14)
        headTitleLabel.numberOfLines = 2
        return headTitleLabel
    }()
    /// 输入卡片的**描边层**（外层）：只负责那一圈 `cardBorderWidth` 的边。
    ///
    /// 🔴 为什么拆两层（外层当边、内层当底）而不用 `layer.borderWidth` + `borderColor`：
    ///    `layer.borderColor` 是 **CGColor** —— 它**不吃动态系统色**（`UIColor.separator` 在赋值
    ///    那一刻就被解析成固定值，之后切深浅色不会再变）；要手动跟 trait 就得用
    ///    `traitCollectionDidChange`（**iOS 17 起已弃用**）或 `registerForTraitChanges`（**iOS 17+**），
    ///    而本 target 是 iOS 15。⇒ 用两层 `UIView`、各自吃 `.systemGray4` / `.systemBackground`
    ///    这类**动态 UIColor**，深浅色由 UIKit 自动跟随，零维护。
    /// ⚠️ 描边色**别用 `.separator`**：模拟器实测它在浅色下渲染成 `#E8E8E8`，白底上几乎看不见
    ///    （`.systemGray4` = `#D1D1D6` 才合适；深色下是 `(58,58,60)`，在黑色卡片底上清楚）。
    /// ⚠️ 它 `clipsToBounds` + `cornerCurve = .continuous`（连续曲率，和系统大圆角一致）。
    private lazy var composerCard: UIView = {
        let v = UIView()
        v.backgroundColor = .systemGray4
        v.layer.cornerRadius = Self.cardCornerRadius
        v.layer.cornerCurve = .continuous
        v.clipsToBounds = true
        // 纯背景：不吃触摸，否则输入框四周的留白会把点击吞掉（虽无副作用，但白占命中层）
        v.isUserInteractionEnabled = false
        return v
    }()

    /// 输入卡片的**底色层**（内层，四周内缩 `cardBorderWidth`）。
    /// 底色取 `.systemBackground`（与页面同色）⇒ 效果就是「一圈描边」，不多一层灰底。
    /// 要改卡片底色只改这一处（外层那个是描边色，不是底色）。
    private lazy var composerCardSurface: UIView = {
        let v = UIView()
        v.backgroundColor = .systemBackground
        v.layer.cornerRadius = Self.cardCornerRadius - Self.cardBorderWidth
        v.layer.cornerCurve = .continuous
        v.isUserInteractionEnabled = false
        return v
    }()

    lazy var textView:UITextView = {
        let textView = UITextView()
        textView.enablesReturnKeyAutomatically = true
        textView.delegate = self
        textView.placeholder = L("请输入消息内容")
        textView.scrollsToTop = false
        textView.textContainer
            .lineFragmentPadding = 0
        // 🔴 2026-10-04：输入框不再自带底色 / 圆角 —— 它现在住在带描边的**卡片**里，
        //    底色与圆角都归卡片（`composerCardSurface` / `composerCard`）。
        //    这里必须保持透明，否则卡片里会浮出一个灰块、和卡片不是一体。
        textView.backgroundColor = .clear
        textView.returnKeyType = .send
        // ⛔️ 这里**绝对不要**给 textView 挂手势识别器。
        // 曾挂过一条「点输入框 = 切回键盘」的 tap，结果正常点击输入框再也弹不出键盘：
        // 自定义 tap 会与 textView 内部负责「点一下开始编辑」的私有识别器抢同一次手势，
        // UIKit 默认不允许二者同时识别，内部那条被挡掉 → textView 不成为第一响应者。
        // （`cancelsTouchesInView = false` 也救不了，那是给「手势 vs 触摸」用的，管不到「手势 vs 手势」。）
        // 面板顶起时的「切回键盘」改由盖在输入框上的 `keyboardSwitchButton` 承担。
        return textView
    }()
    lazy var cameraButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.tintColor = UIColor.label
        btn.setImage(UIImage(systemName: "camera"), for: .normal)
        btn.addTarget(self, action: #selector(cameraButtonClick(_:)), for: .touchUpInside)
        return btn
    }()
    /// 联网搜索开关（2026-10-21）。
    ///
    /// 位置：**紧挨相机右侧**，与左侧那组按钮同一套尺寸/间距；模型胶囊的居中区间
    /// 会自动从它的右缘起算（见 `layoutButtons` 里的 `zoneMinX`）。
    /// 🔴 它是**恒显示**的开关（不像相机/语音那样随状态出现）—— 所以不接
    /// `configure.isShowCameraButton`：那颗只管「这一行要不要放工具按钮」，
    /// 而联网搜索是每轮都可能要临时开一下的东西。
    ///
    /// 🔴 **外观必须与旁边三颗圆钮一致**（2026-10-21 用户指正）：浅灰圆底 + 圆角 16。
    /// 灰底与圆角**不在这里设** —— 它们在 `configureInputToolbar()` 那个「三颗按钮统一样式」
    /// 的循环里，这颗也必须进那个循环（漏了的表现：图标光秃秃浮在卡片上、看着比邻钮小一圈）。
    ///
    /// 图标尺寸：`globe` 这颗的字形自带较大内边距，用默认尺寸会比 `camera`/`mic` 看着小 ⇒
    /// 显式给 18pt 才与邻钮**视觉等大**（⛔ 别只按「都是 32pt 的按钮」就认为一样大）。
    lazy var webSearchButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.tintColor = UIColor.label
        btn.setImage(UIImage(systemName: "globe",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 18,
                                                                            weight: .regular)),
                     for: .normal)
        btn.accessibilityLabel = L("联网搜索")
        btn.addTarget(self, action: #selector(webSearchButtonClick(_:)), for: .touchUpInside)
        return btn
    }()

    /// 刷「联网搜索」开关的外观。**唯一改图标色与底色的地方**
    /// （⛔ 别在别的路径里直接碰这里的 `tintColor` / `backgroundColor`）。
    ///
    /// ⚠️ 用 `UIColor.tintColor`（iOS 15+ 的语义强调色）而不是 `view.tintColor`：
    ///    后者是**继承来的实际值**，在卡片里可能被父视图改过，写回去会与其它按钮不一致。
    /// 🔴 「已开启」除了图标换色，**底也换成一层 16% 的强调色**（与 Mac 那颗
    /// `activeTint.opacity(0.16)` 同口径）：只染图标的话，在一排同色圆钮里分不出开没开。
    func setWebSearchEnabled(_ enabled: Bool) {
        webSearchButton.tintColor = enabled ? UIColor.tintColor : UIColor.label
        webSearchButton.backgroundColor = enabled
            ? UIColor.tintColor.withAlphaComponent(0.16)
            : UIColor.secondarySystemFill
    }

    /// 「键盘 / 语音」切换按钮（右侧）。文本态显示 mic，点击进入语音态；语音态显示 keyboard，点击切回文本态并弹起键盘。
    lazy var modeButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.tintColor = UIColor.label
        btn.setImage(UIImage(systemName: "mic"), for: .normal)
        btn.addTarget(self, action: #selector(modeButtonClick(_:)), for: .touchUpInside)
        return btn
    }()
    /// 「+」按钮的当前面孔（面板开合 / 附件进出 / 生成中都要用它，见 `moreButtonState`）。
    ///
    /// ⚠️ 图标**只在 `refreshMoreButtonState()` 里改** —— 以前这里是 `setMoreButtonOpen(_:)`
    ///    单独管面板开合那两态，现在合成一处四态判据（⛔ 别再写第二个改图标的地方，
    ///    两处各改一次就会互相覆盖，用户看到「面板开着却显示＋」）。
    lazy var moreButton: UIButton = {
        let moreButton = UIButton(type: .custom)
        moreButton.tintColor = UIColor.label
        moreButton.setImage(UIImage(systemName: "plus"), for: .normal)
        moreButton.addTarget(self, action: #selector(moreButtonClick(_:)), for: .touchUpInside)
        return moreButton
    }()
    /// 「停止生成」按钮（最右，**与加号同位**）。
    ///
    /// 为什么是「顶替」而不是「并排多一颗」：位置重合用户不用重新找，
    /// 输入框宽度也不被挤；生成结束图标换回「＋」，一切都回到原位。
    /// 底色故意跟「按住说话」那颗保持一致（浅灰圆），在工具栏里不抢眼但看得见。
    ///
    /// ⚠️ 它是 `moreButton` 的**替身**而不是它自己的一种状态：命中测试按显隐走，
    ///    两者**永远不同时可见**（见 `layoutSubviews` 的 `showsStop`）。
    lazy var stopButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.backgroundColor = .secondarySystemFill
        btn.tintColor = UIColor.label
        btn.setImage(UIImage(systemName: "stop.fill"), for: .normal)
        btn.accessibilityLabel = L("停止生成")
        // 圆角靠 layoutSubviews 里的 cornerRadius（跟随 buttonSide），这里必须夹住
        btn.clipsToBounds = true
        btn.isHidden = true
        btn.addTarget(self, action: #selector(stopButtonClick(_:)), for: .touchUpInside)
        return btn
    }()
    /// 语音态：盖在 textView 上的「按住说话」按钮（按下/抬起/移出分别有回调）
    lazy var voiceInputButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.setTitle(L("按住说话"), for: .normal)
        btn.setTitleColor(UIColor.label, for: .normal)
        btn.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        // 底色用**动态**填充色（同那三颗圆按钮），⛔ 别再写死 `UIColor.rgb(244,244,244)`：
        // 深色下那颗是浅灰底 + `.label`(白) 文字 ⇒ 白字白底、看不见（2026-10-04 顺手修）。
        btn.backgroundColor = .secondarySystemFill
        btn.isHidden = true
        btn.addTarget(self, action: #selector(voiceTouchDown(_:)), for: .touchDown)
        btn.addTarget(self, action: #selector(voiceTouchUpInside(_:)), for: .touchUpInside)
        btn.addTarget(self, action: #selector(voiceTouchUpOutside(_:)), for: [.touchUpOutside, .touchCancel])
        // 手指移出/移回按钮范围 → 切换「松开取消」提示（这就是「上滑取消」手势）
        btn.addTarget(self, action: #selector(voiceTouchDragExit(_:)), for: .touchDragExit)
        btn.addTarget(self, action: #selector(voiceTouchDragEnter(_:)), for: .touchDragEnter)
        return btn
    }()
    /// 附件面板顶起时**盖在输入框上**的透明按钮：点它 = 收起面板、换回系统键盘。
    ///
    /// 为什么用「盖一层按钮」而不是靠 textView 原生的「点一下开始编辑」：
    /// 点输入框要同时做两件事（收面板 + 弹键盘），走原生路径就只能分两处发起、
    /// 各用各的节奏；走按钮则在**一处**把两件事一起发起，时长与曲线都由我们定。
    /// 按钮是普通 `UIControl`，命中即独占、不参与 textView 的手势仲裁
    /// （那套的坑见 `textView` 上的注释）；面板收起时 `isHidden = true`，
    /// 命中测试根本不会命中它，原生编辑不受影响。
    /// 与 `voiceInputButton`（语音态盖住输入框）是同一个套路。
    lazy var keyboardSwitchButton: UIButton = {
        let btn = UIButton(type: .custom)
        btn.backgroundColor = .clear
        btn.isHidden = true
        btn.accessibilityLabel = L("切换键盘")
        btn.addTarget(self, action: #selector(keyboardSwitchTapped), for: .touchUpInside)
        return btn
    }()

    /// **按钮行**里的模型名胶囊（点它 → 宿主弹模型列表）。
    ///
    /// 🔴 位置口径（2026-10-02 用户两次要求叠加后的最终形态）：
    ///    相机 / 语音输入 / 加号 / 模型名 **同一行**，而这一行在输入框**下方**；
    ///    模型名摆在这一行可用宽度的**中间**（两侧按钮之间居中，见 `layoutSubviews`）。
    ///    于是输入框独占上一整行（左右只剩卡片内边距 `cardPaddingH`）。
    ///
    /// ⚠️ 只用 `UIButton.Configuration` 驱动（`configuration` 一旦存在，
    ///    `setTitle` / `setImage` 那套老 API 就不再生效 —— 别两种混着写）。
    private lazy var modelButton: UIButton = {
        let btn = UIButton(type: .system)
        btn.configuration = Self.makeModelButtonConfiguration()
        btn.isHidden = true
        btn.addTarget(self, action: #selector(modelButtonClick(_:)), for: .touchUpInside)
        // 行高固定，胶囊自己不该被拉长；宽度按内容自适应（`layoutSubviews` 里再夹一次上限）。
        // 内容居中：胶囊本身是**居中摆放**的，文字再靠左会显得胶囊在"漏气"。
        btn.contentHorizontalAlignment = .center
        return btn
    }()

    /// 模型胶囊的样式（`.plain` 打底 + 自己配底色圆角，跟随深浅色）。
    private static func makeModelButtonConfiguration() -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "chevron.down",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 9,
                                                                             weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10)
        config.background.backgroundColor = .secondarySystemFill
        config.background.cornerRadius = modelRowHeight / 2
        config.baseForegroundColor = .secondaryLabel
        // 🔴 **一行，超宽省略号截断**（2026-10-21 加）：
        // 控制行只有一个 `modelRowHeight` 高，而 `layoutSubviews` 会把宽度夹到
        // 「地球键右缘 .. 语音键左缘」之间。默认折行的话，长模型名（如
        // `deepseek-v4-flash-vision-exp`）会在这颗小胶囊里**折成两行**，字挤出胶囊外，
        // 看着像整行被压歪了。⛔ 别改成折行显示全名 —— 看全名请点开选择器。
        config.titleLineBreakMode = .byTruncatingTail
        // 🔴 字号走 `AIChromeFont`（2026-10-22 接「字体大小」档位）：原先写死 12pt，
        //    调档位时这颗胶囊毫无反应（Mac 侧的胶囊是跟档位的，两端不一致）。
        //    ⚠️ transformer 是存在 configuration 里的闭包 ⇒ 换档后必须**整体重设
        //    configuration** 才会重新求值（见 `applyChromeFonts()`）。
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var out = incoming
            out.font = AIChromeFont.ui(12)
            return out
        }
        return config
    }

    /// 「待发附件」预览条（懒加载：没发过附件就不建视图）与状态条（待发引用 / 正在编辑）。
    ///
    /// 🔴 2026-10-09 起两条都在**描边卡片内部**，上下次序 = **状态条 →（附件条 →）输入框**：
    /// 先看到的是「这次发送属于哪种情形」，再说「带了什么附件」——
    /// 这与搬进卡片**之前**屏幕上看到的次序一致（那时状态条在卡片外、附件条在卡片内顶部）。
    lazy var bannerView: AIComposerBannerView = {
        let bar = AIComposerBannerView()
        bar.isHidden = true
        bar.onCancel = { [weak self] in
            guard let self else { return }
            // 宿主是这个状态的持有者（同待发附件），这里只上报「用户点了取消」
            self.onCancelBanner?()
        }
        return bar
    }()

    lazy var attachmentBar: AIAttachmentBarView = {
        let bar = AIAttachmentBarView()
        bar.isHidden = true
        bar.onRemove = { [weak self] index in
            guard let self else { return }
            self.onRemoveAttachment?(index)
        }
        bar.onAddMore = { [weak self] in
            guard let self else { return }
            self.onAddAttachment?()
        }
        return bar
    }()

    /// `@` 资料待发条（2026-10-21）。与 `attachmentBar` 同构，只是更矮、只画文件名。
    lazy var mentionBar: AIMentionBarView = {
        let bar = AIMentionBarView()
        bar.isHidden = true
        bar.onRemove = { [weak self] index in
            guard let self else { return }
            self.onRemoveMention?(index)
        }
        return bar
    }()

    /// 「+」附件面板（相机 / 相册 / 文件）。
    ///
    /// 它是**输入栏自己的子视图**（挂在输入行下方），不再走 `textView.inputView`：
    /// 「面板顶起」= 输入栏长高，「收起」= 缩回去，高度见 `panelTotalHeight`。
    /// 好处是它永远待在我们的视图树里 —— 系统键盘来去、相册/文件那种全屏 picker 盖上来，
    /// 都带不走它，于是也就没有「回来后面板没了 / 输入框被盖掉」这类问题。
    lazy var attachmentPanel: AIAttachmentPanelView = {
        let panel = AIAttachmentPanelView()
        panel.onSelect = { [weak self] kind in
            guard let self else { return }
            self.delegate?.attachmentEvent(kind)
        }
        // 网格里点了一张 → 原样上行给宿主（取整图、落盘、进待发区都是宿主的事）
        panel.onPickAsset = { [weak self] asset in
            guard let self else { return }
            self.delegate?.attachmentPhotoPicked(asset)
        }
        // 面板里的空白处轻点 → 收起面板
        panel.onBlankTap = { [weak self] in
            guard let self else { return }
            self.dismissAttachmentPanelForBlankTap()
        }
        return panel
    }()

    /// 附件面板是否已经顶起（顶起时那个位置本该是系统键盘）。
    /// 所有开合路径（点「+」、点输入框切回键盘、`textViewDidEndEditing`、
    /// `becomeFirstResponder(index:)`）都只改这一个值，图标与光标由 `didSet` 统一联动。
    private var isAttachmentPanelVisible = false {
        didSet {
            guard isAttachmentPanelVisible != oldValue else { return }
            refreshMoreButtonState()
            // 立即同步遮罩按钮，不等下一次 layout（过渡期内也不能让点击穿透到 textView）
            keyboardSwitchButton.isHidden = !isAttachmentPanelVisible
            setNeedsLayout()
        }
    }

    /// 附件面板总高（**含**底部安全区）= 系统键盘高度，**恒定一个值**。
    ///
    /// 与系统键盘**等高**是关键，不是动画参数：等高时切换前后输入行一动不动，
    /// 看起来只是「键盘那块区域换了内容」；面板矮一截的话输入行要往下掉，
    /// 那一下本身就是最突兀的。
    ///
    /// ⚠️ 不能再写成「`configure.panelHeight` + 安全区」再跟实测值取 `max`：
    /// 那样「先点输入框（已经量到键盘高）再点文件」和「冷启动直接点文件（还没量到）」
    /// 会算出两个高度，同一个面板时高时矮（用户实测到的就是这个）。
    /// 现在无条件取 `systemKeyboardHeight`，三条来路都由它兜住。
    private var panelTotalHeight: CGFloat { systemKeyboardHeight }

    /// 系统键盘高度（**含**底部安全区）。面板与它等高，来源按可靠度取：
    ///
    /// ① `lastKeyboardHeight` —— 本次启动从键盘通知里实测到的，最准；
    /// ② 上次启动实测值（落盘在 UserDefaults）—— 冷启动还没弹过键盘时用它，
    ///    换启动也还是同一个高度；
    /// ③ 兜底估算 —— **首次安装后一次键盘都没弹过**才会走到（否则面板会矮一大截）。
    ///    全面屏机型：键盘本体 302 + Home 指示条（→ 常见机型 = 336）；带 Home 键机型：216 + 候选条 44 = 260。
    ///    只要弹过一次键盘，② 就会把这个估算值永久接管。
    private var systemKeyboardHeight: CGFloat {
        if lastKeyboardHeight > 0 { return lastKeyboardHeight }
        if persistedKeyboardHeight > 0 { return persistedKeyboardHeight }
        let safeBottom = window?.safeAreaInsets.bottom ?? 0
        if UIDevice.current.userInterfaceIdiom == .pad { return 300 + safeBottom }
        return safeBottom > 0 ? 302 + safeBottom : 260
    }

    /// 输入栏底部这一段该被谁占着：键盘 / 附件面板 / 底部安全区。
    /// `heightThatFits()` 靠它算总高，`layoutSubviews` 靠它摆面板 —— 两处口径必须一致。
    private func bottomOccupancy() -> CGFloat {
        if isKeyboardVisible { return 0 }                        // 键盘占着，安全区已被键盘盖掉
        if isAttachmentPanelVisible { return panelTotalHeight }  // 面板占着（面板自带安全区）
        return restingBottomInset
    }

    /// 「+」面板要不要多出一格「项目资料」。
    ///
    /// 🔴 由宿主在**切会话 / 改归属**之后调（唯一调用点是
    /// `AIModuleViewController.refreshProjectEntry()`）—— 面板不知道也不该知道
    /// 「当前会话属于哪个项目」，那是业务层的事。
    /// ⚠️ 幂等，可以每帧调（见 `AIAttachmentPanelView.setProjectEntryAvailable`）。
    func setProjectEntryAvailable(_ available: Bool) {
        attachmentPanel.setProjectEntryAvailable(available)
    }

    /// 摆好面板的位置。
    ///
    /// 面板**高度固定**（就是 `panelTotalHeight`），不跟着输入栏的 frame 变形 ——
    /// 于是输入栏做任何动画（跟随键盘、长高变矮）都只是「把面板挡住 / 让出来」，
    /// 面板自己不需要参与插值，也就不会出现「按钮飞到别处」这种事。
    private func syncAttachmentPanelFrame() {        guard isAttachmentPanelVisible else { return }
        // 底部安全区同步给面板：最近照片网格要用它把最后一行让出 Home 指示条
        attachmentPanel.bottomSafeInset = restingBottomInset
        attachmentPanel.frame = CGRect(x: 0,
                                       y: contentHeight(),
                                       width: bounds.width,
                                       height: panelTotalHeight)
    }

    /// 收面板的**瞬时**版本（无过渡）。
    /// 给「输入态直接结束」的路径用（切语音态、拖动列表收起输入栏…）：
    /// 那些路径本来就要求输入栏瞬间复位，面板单独播一段动画反而更乱。
    private func dismissAttachmentPanelImmediately() {
        guard isAttachmentPanelVisible else { return }
        isAttachmentPanelVisible = false
        attachmentPanel.isHidden = true
        attachmentPanel.alpha = 0
        setCursorVisible(true)
    }

    /// 光标显隐。面板顶起时输入框已经不再是第一响应者（不会有真光标），
    /// 但 `tintColor` 还管着插入点与选中手柄的残留，一并置空才是干净的「没在输入」的样子。
    /// 收起面板 / 离开输入态时恢复 `configure.cursorColor`。
    private func setCursorVisible(_ visible: Bool) {
        textView.tintColor = visible ? configure.cursorColor : .clear
    }

    /// 键盘通知里的动画时长。
    /// ⚠️ duration 为 0 = **交互式收键盘**（拖动列表 `.interactive`）：必须保持 0（跟手），
    /// 补动画会让输入栏滞后于手指。
    private func animationDuration(from userInfo: [AnyHashable: Any]) -> TimeInterval {
        userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0
    }

    /// 键盘通知里的动画**曲线**。系统键盘用的不是 `easeInOut`，而是曲线 `7`
    /// （`UIView.AnimationCurve` 没有对应 case，是系统私有曲线，偏「先快后缓」）。
    /// 只用 `UIView.animate(withDuration:)`（默认 easeInOut）跟手移动输入栏，
    /// 节奏会和面板进场、系统键盘位移**错开半拍** —— 时长一样、速度感不一样，
    /// 看起来就是「差一点点不顺」。这里把曲线原样取出来透传给动画块。
    ///
    /// 固定带上 `.beginFromCurrentState`：快速连点「+」/ 输入框时，上一次动画可能还没跑完，
    /// 默认会从**模型值**重新插值（先跳回目标位再走），从**呈现值**接着走才是连着的。
    private func animationOptions(from userInfo: [AnyHashable: Any]) -> UIView.AnimationOptions {
        let curve = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue
            ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        return UIView.AnimationOptions(rawValue: curve << 16).union(.beginFromCurrentState)
    }

    /// 记下真实键盘的高度，供「+」面板等高校准（见 `systemKeyboardHeight`）。
    /// 只记键盘**真的在屏上**那几拍：收起时给的 frame 是屏幕外的位置，别拿它污染基准。
    private func recordKeyboardHeight(_ keyboardFrame: CGRect) {
        guard !isAttachmentPanelVisible, keyboardFrame.height > 0 else { return }
        lastKeyboardHeight = keyboardFrame.height
        // 落盘：下次冷启动不用再等「先弹一次键盘」才知道面板该多高（否则第一次点「文件」会矮一截）
        guard abs(persistedKeyboardHeight - keyboardFrame.height) > 0.5 else { return }
        persistedKeyboardHeight = keyboardFrame.height
        UserDefaults.standard.set(Double(keyboardFrame.height),
                                  forKey: Self.keyboardHeightDefaultsKey)
    }

    lazy var bottomBGView: UIView = {
        let bottomBGView = UIView()
        bottomBGView.backgroundColor=UIColor.white
        return bottomBGView
    }()
    
    // MARK: -  private method
    func refreshTextUI() {
        guard !textView.text.isEmpty else {
            return
        }
/*
        if let markedTextRange = textView.markedTextRange,
           let position = textView.position(from: markedTextRange.start, offset: 0) {
            return // 正处于输入拼音还未点确定的中间状态
        }

        let selectedRange = textView.selectedRange
        printLog(plainText)
        let attributedComment = NSMutableAttributedString(string: plainText, attributes: [
            .font: configure.font,
            .foregroundColor: kMediaColor51
        ])

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = CGFloat(configure.textViewLineSpacing)
        attributedComment.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: attributedComment.length))

        let offset = textView.attributedText.length - attributedComment.length
        textView.attributedText = attributedComment
        textView.selectedRange = NSRange(location: selectedRange.location - offset, length: 0)
 */
    }

    @objc private func cameraButtonClick(_ button: UIButton) {
        delegate?.cameraEvent()
    }

    /// 联网搜索开关：**只上报**，不在这里改偏好也不在这里换图标色
    /// （见 `InputToolbarDelegate.webSearchToggleEvent` 的分工说明）。
    @objc private func webSearchButtonClick(_ button: UIButton) {
        delegate?.webSearchToggleEvent()
    }

    /// 输入框下方那颗模型名被点了：只上报，弹列表 / 落库 / 回填都在宿主
    /// （见 `onTapModel` 的注释 —— 输入栏不读配置）。
    @objc private func modelButtonClick(_ button: UIButton) {
        onTapModel?()
    }

    @objc private func modeButtonClick(_ button: UIButton) {
        if inputMode == .text {
            switchToVoiceMode()
        } else {
            switchToTextMode(showKeyboard: true)
        }
    }

    @objc private func moreButtonClick(_ button: UIButton) {
        // 四态分流，判据只有 `moreButtonState` 一处（⛔ 别在这里另写 if 链，
        // 那会让「图标显示的面孔」和「点击做的事」各算一次，迟早对不上）。
        switch moreButtonState {
        case .plus:
            showAttachmentPanel()
        case .panelOpen:
            // 点 ✕ = 收起面板并把系统键盘弹回来（与「点输入框」同一条路：用户接下来要打字）
            hideAttachmentPanel(showKeyboard: true)
        case .send:
            // 文本可以一个字都没有：这条就是「只发图不打字」的唯一出口
            // （`enablesReturnKeyAutomatically = true` 时空文本的 return 是禁用的）。
            delegate?.sendCurrentInputEvent()
        case .streaming:
            break   // 生成中这颗钮被 stopButton 顶替（`showsStop`），点不到这里
        }
    }

    /// 「停止生成」：只播一个事件，真正的收尾（停流、把已收到的字落定）在 manager 里，
    /// 宿主收到后还会回调 `setStreaming(false)` 把图标换回来 —— 这里不复位，避免两处打架。
    @objc private func stopButtonClick(_ button: UIButton) {
        delegate?.stopStreamingEvent()
    }

    // MARK: - 加号附件面板（相机 / 相册 / 文件）

    /// 顶起附件面板。
    ///
    /// 面板是自家子视图，所以整个切换只改**一个口径**：输入栏底部这一段由「键盘」换成「面板」。
    /// 因为两者等高（见 `panelTotalHeight`），过程中输入行**原地不动**，
    /// 看起来就只是「键盘那一块区域换成了面板」。
    ///
    /// ⚠️ 面板高度必须**含底部安全区**（`panelTotalHeight`）—— 不补的话按钮会被 Home 指示条压住。
    private func showAttachmentPanel() {
        // 语音态下 textView 是藏起来的，先切回文本态
        if inputMode == .voice { switchToTextMode(showKeyboard: false) }
        guard !isAttachmentPanelVisible else { return }
        isAttachmentPanelVisible = true
        textView.isHidden = false
        attachmentPanel.contentHeight = configure.panelHeight
        attachmentPanel.alpha = 0
        attachmentPanel.isHidden = false
        // 先把面板摆到位再收键盘：紧接着那拍 `keyboardWillHide` 会同步读 `heightThatFits()`
        syncAttachmentPanelFrame()
        // 下半部分那块最近照片网格：**第一次打开面板时才问相册权限**（幂等，之后只重建列表）
        attachmentPanel.preparePhotoGrid()

        if textView.isFirstResponder {
            // 键盘收走 → `keyboardWillHide` 带着**系统的时长与曲线**，把输入栏从
            // 「输入行 + 键盘」平滑铺成「输入行 + 面板」（等高 → 输入行不动）
            textView.resignFirstResponder()
        } else {
            // 用户没点输入框就直接点了「+」：没有键盘通知可等，自己补一次同样的过渡
            resetToRestingPosition(duration: AIAttachmentPanelView.appearDuration,
                                   options: [AIAttachmentPanelView.systemCurveOptions, .beginFromCurrentState])
        }
        // 面板内容依次浮现
        attachmentPanel.playEntryAnimation()
        // 面板顶起 = 操作重心交到面板，输入框不该再显示「正在输入」的样子
        setCursorVisible(false)
    }

    /// 收起附件面板
    ///
    /// - Parameter showKeyboard: `true` 时接着把系统键盘弹回来（点输入框那条路，用户要打字）；
    ///   `false` 回到「静止」态（再点一次「+」、或离开输入态时用）。
    private func hideAttachmentPanel(showKeyboard: Bool = false) {
        guard isAttachmentPanelVisible else { return }
        isAttachmentPanelVisible = false
        setCursorVisible(true)
        fadeOutAttachmentPanel()
        if showKeyboard {
            // 键盘从底部升上来盖住面板那块区域；输入栏由 `keyboardWillShow` 带着系统的时长与
            // 曲线收回「只剩输入行」的高度 —— 两条边同步，所以输入行看上去没动
            textView.becomeFirstResponder()
        } else {
            resetToRestingPosition(duration: AIAttachmentPanelView.appearDuration,
                                   options: [AIAttachmentPanelView.systemCurveOptions, .beginFromCurrentState])
        }
    }

    /// 点面板里的**空白处** → 收起面板。
    ///
    /// 走「再点一次『+』」同一条路（面板淡出 + 输入栏带着同一条系统曲线复位），观感一致。
    /// 与点输入框那条路（`keyboardSwitchTapped`）的区别是**不弹键盘** ——
    /// 点空白说明用户只是想把这个面板收掉，并没有要打字。
    func dismissAttachmentPanelForBlankTap() {
        guard isAttachmentPanelVisible else { return }
        hideAttachmentPanel(showKeyboard: false)
    }

    // MARK: - 🧪 验收钩子：自动打开「+」附件面板

    /// `STARRY_PANEL_UI=1` 时由宿主自动开一次面板（2026-10-16 画图入口验收用）。
    ///
    /// ## 为什么非要有这个钩子
    /// 「+」面板只从输入栏那颗钮点出来，而模拟器**投不出合成触摸**
    /// （`xcrun simctl` 没有 tap）⇒ 没有它，「面板里现在有几个入口、画图项长在哪、
    /// 四项平分宽不挤」agent 侧一张图都拿不到（同 `STARRY_PICKER_UI` 的理由）。
    ///
    /// ⚠️ 走的是**和点「+」完全相同的那条路**（`showAttachmentPanel`）——
    ///    ⛔ 别在这里自己 `attachmentPanel.isHidden = false` 摆一个，那样验的不是用户走的那条。
    func openAttachmentPanelForProbe() {
        #if DEBUG
        showAttachmentPanel()
        #endif
    }

    /// 拖动对话列表 → 收起「+」面板（走点「+」收起那条路：下滑 + 淡出，观感一致）。
    ///
    /// 键盘那条路是系统管的（`keyboardDismissMode = .interactive`：拖动时键盘自己跟着走），
    /// 但面板已经不是 `inputView` 了，系统看不见它 —— 不自己收的话，用户拖列表时
    /// 底部这一块纹丝不动，感觉就是「收不起来」。
    func dismissAttachmentPanelForListDrag() {
        guard isAttachmentPanelVisible else { return }
        hideAttachmentPanel(showKeyboard: false)
    }

    /// 面板淡出，收完再真正隐藏。
    ///
    /// 为什么不直接 `isHidden = true`：面板高度固定、就压在输入栏下沿，直接隐藏会「啪」地消失，
    /// 跟输入栏 / 键盘那段过渡完全不是一个节奏 —— 「切换很生硬」里有一部分就是它。
    /// ⚠️ 回调里复查 `isAttachmentPanelVisible`：淡出途中用户又点了「+」的话，这份回调已经过期，
    /// 不能把刚打开的面板按下去。
    private func fadeOutAttachmentPanel() {
        UIView.animate(withDuration: AIAttachmentPanelView.appearDuration,
                       delay: 0,
                       options: [AIAttachmentPanelView.systemCurveOptions, .beginFromCurrentState, .allowUserInteraction]) {
            self.attachmentPanel.alpha = 0
        } completion: { [weak self] _ in
            guard let self = self, !self.isAttachmentPanelVisible else { return }
            self.attachmentPanel.isHidden = true
        }
    }

    /// 点输入框区域（面板顶起时那层透明遮罩按钮）：收起面板、换回系统键盘。
    /// 面板没开时这个按钮是隐藏的，命中不到 → textView 走系统原生的「点一下开始编辑」。
    @objc private func keyboardSwitchTapped() {
        hideAttachmentPanel(showKeyboard: true)
    }

    @objc private func voiceTouchDown(_ button: UIButton) {
        delegate?.voiceRecordDidBegin()
    }

    @objc private func voiceTouchUpInside(_ button: UIButton) {
        delegate?.voiceRecordDidEnd(cancel: false)
    }

    @objc private func voiceTouchUpOutside(_ button: UIButton) {
        // 手指移出按钮范围或系统中断都视为取消
        delegate?.voiceRecordDidEnd(cancel: true)
    }

    @objc private func voiceTouchDragExit(_ button: UIButton) {
        delegate?.voiceRecordCancelStateChanged(isCancelling: true)
    }

    @objc private func voiceTouchDragEnter(_ button: UIButton) {
        delegate?.voiceRecordCancelStateChanged(isCancelling: false)
    }

    /// 切换到语音态：收起键盘 + 用「按住说话」盖住输入框
    private func switchToVoiceMode() {
        guard inputMode != .voice else { return }
        // 面板开着先收掉：这时 textView 不是 first responder，下面那句 resign 不会触发
        // keyboardWillHide，输入栏会一直卡在「面板顶起」的高度上。
        dismissAttachmentPanelImmediately()
        inputMode = .voice
        // textView 是 firstResponder 时 resignFirstResponder 会触发 keyboardWillHide，
        // 走正常复位流程；面板顶起时它不是第一响应者 → 自己补一次复位
        if textView.isFirstResponder {
            textView.resignFirstResponder()
        } else {
            resetToRestingPosition(duration: AIAttachmentPanelView.appearDuration,
                                   options: [AIAttachmentPanelView.systemCurveOptions, .beginFromCurrentState])
        }
        modeButton.setImage(UIImage(systemName: "keyboard"), for: .normal)
        setNeedsLayout()
        layoutIfNeeded()   // 立刻落地「按住说话」的显隐，避免视觉延迟
        onInputModeChange?(true)
    }

    /// 切换到文本态：移除遮罩 + 可选弹起键盘
    private func switchToTextMode(showKeyboard: Bool) {
        guard inputMode != .text else { return }
        inputMode = .text
        modeButton.setImage(UIImage(systemName: "mic"), for: .normal)
        setNeedsLayout()
        // 必须立刻落地 hidden：隐藏中的视图 becomeFirstResponder 会返回 false，键盘弹不起来
        layoutIfNeeded()
        onInputModeChange?(false)
        if showKeyboard { textView.becomeFirstResponder() }
    }
    
    func heightWithLine(_ lineNumber: Int) -> CGFloat {
        // 注意：不能用空串 boundingRect 取行高（空串恒为 0，会让 textViewMaxLine 失效）
        let lineHeight = configure.font.lineHeight
        let height = CGFloat(lineNumber) * lineHeight
            + CGFloat(max(lineNumber - 1, 0)) * CGFloat(configure.textViewLineSpacing)
            + textViewVerticalInset
        return height < configure.textViewHeight ? configure.textViewHeight : height
    }

    /// 输入框上下内边距（与 usedRect 口径对齐）
    private var textViewVerticalInset: CGFloat {
        textView.textContainerInset.top + textView.textContainerInset.bottom
    }
    /// 输入**卡片**（描边外框）的 frame。
    ///
    /// 🔴 这是全类**唯一**的卡片几何出处：`layoutSubviews` 用它摆卡片，
    ///    `frameTextView()` 再用它推输入框 —— ⛔ 别在两处各算一遍（那样一改尺寸就错位）。
    /// 口径：左右各留 `configure.horizontalMargin`（与输入行对齐）、
    ///      高 = `cardContentHeight()`（状态条与附件条都已在它内部）。
    private func frameCard() -> CGRect {
        let x = configure.horizontalMargin
        // 🔴 2026-10-09：`+ bannerHeight` 已删除 —— 状态条搬进卡片内部了，
        //    它的位置由 `cardContentHeight()` 内部贡献；这里再加一次 = 卡片上移一截、留一道缝
        //    （与 10-08 删掉 `attachmentBarHeight` 是同一条理由、同一刀）。
        let y = self.headView.frame.height
            + configure.textViewTopMargin
        return CGRect(x: x,
                      y: y,
                      width: max(self.frame.size.width - x * 2, 0),
                      height: cardContentHeight())
    }

    func frameTextView() -> CGRect {
        // 高度按内容行数计算，不再从 bounds 反推，避免底部安全区把输入框整体拉高
        let height = max(fittedTextHeight(), configure.textViewHeight)
        // 输入框在**卡片内部**：左右 / 上各再缩一个卡片内边距。
        // 🔴 2026-10-02 起三颗按钮都在输入框**下方**那一行 ⇒ 输入框两侧只剩卡片内边距，
        //    左右对称（整宽输入框）。⛔ 别在这里加按钮宽度 —— 一加输入框就会缩回原样。
        // 🔴 2026-10-08：输入框的 y 要再让开**附件条**（它在卡片内、输入框之上），
        //    ⛔ 漏了这段偏移两者就会重叠（附件压在文字上）。
        // 🔴 2026-10-09：还要让开**状态条**（引用 / 编辑），且它在附件条**之上**
        //    ⇒ 偏移量 = bannerHeight + attachmentBarHeight，顺序不能颠倒。
        // 🔴 2026-10-21：再加 `mentionBarHeight`（@ 资料条，在附件条**之下**）——
        //    ⛔ 漏了这段偏移，chip 会与第一行文字重叠。
        let card = frameCard()
        let x = card.minX + Self.cardPaddingH
        return CGRect(x: x,
                      y: card.minY + Self.cardPaddingTop + bannerHeight + attachmentBarHeight + mentionBarHeight,
                      width: max(card.width - Self.cardPaddingH * 2, 0),
                      height: height)
    }
   
  
    
    override var frame: CGRect {
        get {
            return super.frame
        }
        set {
            // 执行自定义逻辑前，‌先调用super.frame的设置
            super.frame = newValue
            onFrameChange?(newValue)
//            bottomBGView.frame = CGRect(x: 0, y: frame.maxY, width: bounds.width, height: UIScreen.main.bounds.height - frame.maxY)
        }
    }


    func setFrame(_ frame: CGRect, animated: Bool) {
        guard frame != self.frame else { return }
        let changesAnimations: () -> Void = {
            self.frame = frame
            self.setNeedsLayout()
        }
        
        if animated {
            UIView.animate(withDuration: 0.25, delay: 0, options: .beginFromCurrentState, animations: changesAnimations, completion: nil)
        } else {
            changesAnimations()
        }
    }
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if textView.isFirstResponder {
            return true
        }
        return super.point(inside: point, with: event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let touchPoint = touch.location(in: self)
        if !bounds.contains(touchPoint) {
            if isFirstResponder() {
                textView.resignFirstResponder()
            }
        } else {
            super.touchesBegan(touches, with: event)
        }
    }

    func isFirstResponder() -> Bool {
        return textView.isFirstResponder
    }
    
    override func resignFirstResponder() -> Bool {
        super.resignFirstResponder()
//        self.isHidden = true
        self.headView.isHidden = true
        self.headTitleLabel.isHidden = true
//        self.sendBtn.isHidden = true
//        self.textView.isHidden = true
//        self.keepsPreModeTextViewWillEdited = true
        self.setNeedsLayout()
        return self.textView.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        return becomeFirstResponder(index: 0)
    }

    func becomeFirstResponder(index: Int) -> Bool {
//        self.isHidden = false
//        self.headView.isHidden = false
//        self.headTitleLabel.isHidden = false
//        self.sendBtn.isHidden = false
        // 外部要求弹键盘时，若在语音态先切回文本态
        if inputMode == .voice { switchToTextMode(showKeyboard: false) }
        // 面板还开着就先收掉，避免带着面板弹键盘（宿主调 showTextMode(focus:) 会走到这）
        dismissAttachmentPanelImmediately()
        self.textView.isHidden = false
//        self.keepsPreModeTextViewWillEdited = false

        self.setNeedsLayout()
    
        /*
        switch index {
        case 0:
            self.isShowTextKeyboard = true
            self.isShowPhotoKeyboard = false
            self.isShowEmojiKeyboard = false
            self.textView.inputView = nil
        case 1:
            emojiButtonClick(self.emojiButton)
        case 2:
            moreButtonClick(self.moreButton)
            // showMoreView()
        default:
            self.isShowTextKeyboard = true
            self.isShowPhotoKeyboard = false
            self.isShowEmojiKeyboard = false
            self.textView.inputView = nil
        }
         */
        return self.textView.becomeFirstResponder()
    }


    @objc private func keyboardWillShow(notification: Notification) {
//        if self.bottomBGView.superview == nil {
//            superview.insertSubview(self.bottomBGView, belowSubview: self)
//        }
        guard let userInfo = notification.userInfo else { return }
        isKeyboardVisible = true
        let duration = animationDuration(from: userInfo)
        let keyboardFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        recordKeyboardHeight(keyboardFrame)
        positionAboveKeyboard(keyboardFrame, duration: duration, options: animationOptions(from: userInfo))
    }

    /// 键盘**已经弹出**时再换输入视图（把键盘换成「+」附件面板、切表情/第三方键盘、
    /// 输入联想条高度变化）只发这条通知，`keyboardWillShow` 不会再发。
    /// 不跟的话输入栏会停在旧键盘的高度上 —— 表现为面板弹出来了，输入栏却浮在半空。
    @objc private func keyboardWillChangeFrame(notification: Notification) {
        guard isKeyboardVisible, let userInfo = notification.userInfo else { return }
        let duration = animationDuration(from: userInfo)
        let keyboardFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
        // 正在收起（frame 已移出屏幕）交给 keyboardWillHide 复位，这里不插手
        guard let superview = self.superview,
              superview.bounds.intersects(superview.convert(keyboardFrame, from: nil)) else { return }
        recordKeyboardHeight(keyboardFrame)
        positionAboveKeyboard(keyboardFrame, duration: duration, options: animationOptions(from: userInfo))
    }

    /// 把输入栏摆到键盘（或自定义输入视图）正上方。
    /// 算的是绝对 frame，所以同一次变化里重复调用没有副作用。
    private func positionAboveKeyboard(_ keyboardFrame: CGRect,
                                       duration: TimeInterval,
                                       options: UIView.AnimationOptions) {
        guard let superview = self.superview else { return }
        let keyboardOverlap = max(0, superview.bounds.height - superview.convert(keyboardFrame, from: nil).minY)
        var inputViewFrame = self.frame
        let textViewHeight = heightThatFits()
        inputViewFrame.origin.y = superview.bounds.height - keyboardOverlap - textViewHeight
        inputViewFrame.size.height = textViewHeight
//        if configure.headTitle.isEmpty {
//            inputViewFrame.origin.y -= 45
//        }
        // 曲线/时长/进行中动画的接续全部跟系统键盘一致，输入栏才不会和键盘「差半拍」
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.frame = inputViewFrame
        }
    }

    /// 复位到「静止位」：键盘收起后、以及「+」面板顶起时都走这里。
    ///
    /// 区别只在 `heightThatFits()` 里多算了谁的高度（见 `bottomOccupancy()`）：
    /// - 键盘收起 → 只剩「输入行 + 安全区」；
    /// - 面板顶起 → 「输入行 + 面板」，因为面板与键盘等高，输入行**停在原处**。
    private func resetToRestingPosition(duration: TimeInterval, options: UIView.AnimationOptions) {
        guard let superview = self.superview else { return }
        isKeyboardVisible = false
        var inputViewFrame = self.frame
        let textViewHeight = heightThatFits()
        inputViewFrame.origin.y = superview.bounds.height - restingBottomOffset - textViewHeight
        inputViewFrame.size.height = textViewHeight
        guard inputViewFrame != self.frame else { return }
        if duration > 0 {
            UIView.animate(withDuration: duration, delay: 0, options: options) {
                self.frame = inputViewFrame
            }
        } else {
            self.frame = inputViewFrame
        }
    }

    @objc private func keyboardWillHide(notification: Notification) {
//        if self.bottomBGView.superview != nil {
//            self.bottomBGView.removeFromSuperview()
//        }
        guard let userInfo = notification.userInfo else { return }
        let duration = animationDuration(from: userInfo)
        resetToRestingPosition(duration: duration, options: animationOptions(from: userInfo))
    }
    
    
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
}
extension InputToolbar:UITextViewDelegate{
    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        // 兜底：面板还开着时点输入框（比如点到了输入框两侧缝隙）→ 先把面板收掉再弹键盘，
        // 否则键盘和面板会同时占着底部那一段。
        if isAttachmentPanelVisible { hideAttachmentPanel(showKeyboard: false) }
        setCursorVisible(true)
        if self.delegate != nil {
            self.delegate?.keyboardState(state: true,text: textView.text)
        }
        return true
    }
    private func textViewDidBeginEditing(_ textView: UITextView) -> Bool{
//        keepsPreModeTextViewWillEdited  = false
        if self.delegate != nil {
            self.delegate?.keyboardState(state: true,text: textView.text)
        }

        return true
    }
    
    internal func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        if text == "\n"{
            triggerSend()
            return false
        }
        // `@` 触发「项目资料」选择页（2026-10-21）。
        //
        // 🔴 必须判 `markedTextRange == nil`：中文拼音 / 日文假名输入过程中，
        //    一次按键会先落在**marked text** 上（还没上屏），此时读到的不该被当成「用户想 @」。
        //    不加这条守卫的典型症状：用拼音打「艾特」时莫名弹出面板。
        // 🔴 也**不拦截**这个字符（返回 true）：用户可能只是想写邮箱 / 用户名。
        //    取消选择时什么都不用回滚，正文里就留一个 `@`，人自己会删。
        if text == "@", textView.markedTextRange == nil {
            // 延后到下一个 runloop：宿主会在回调里 `present(...)` 一个控制器，
            // 而在 `shouldChangeTextIn` **期间**换第一响应者 / 弹模态，UIKit 会把这一个字符
            // 的插入流程打断（表现为「面板弹了，但 @ 没进输入框」）。
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.mentionTriggerEvent()
            }
        }
        if range.location > configure.textMaxCount {
            if text == "" {
                return true
            }else{
                return false
            }
        }
        return true
    }
    func textViewDidBeginEditing(_ textView: UITextView) {

    }
    func textViewDidEndEditing(_ textView: UITextView) {
//        keepsPreModeTextViewWillEdited  = true
        // ⚠️ 面板开着时的「结束编辑」是我们自己收的键盘（`showAttachmentPanel` 里那次
        // `resignFirstResponder`，目的就是把键盘那块让给面板）—— 不是「用户离开了输入态」，
        // 走到下面就会把刚打开的面板立刻收回去。面板态下 textView 本来就不是第一响应者，
        // 因此这里的 endEditing 只可能来自那一次，直接放行。
        guard !isAttachmentPanelVisible else { return }
        // 键盘收起（发完消息、拖动列表、切语音态…）→ 面板状态一起复位。
        // 走瞬时版本：这条路径本来就要求输入栏瞬间复位，面板单独播一段动画反而更乱。
        // 不复位的话面板会一直留在输入栏里，用户下次点输入框会「莫名其妙」又看到它。
        dismissAttachmentPanelImmediately()
        // 面板顶起时它被判「离开输入态」（切语音态、拖动列表、发完消息），
        // 光标必须一起恢复，否则会一直停在 `.clear`（看不见光标，像没聚焦）
        setCursorVisible(true)
        resetToRestingPosition(duration: 0, options: [.beginFromCurrentState])
        if self.delegate != nil {
            self.delegate?.keyboardState(state: false,text: textView.text)
        }
    }
    func textViewDidChange(_ textView: UITextView) {
        layoutPlaceholder()
        if textView.markedTextRange != nil { // 有预输入文字
            return
        }
        refreshTextUI()
        let count = textView.text.count
        if count > configure.textMaxCount {
            textView.text = String(textView.text.prefix(configure.textMaxCount))
            if self.delegate != nil {
                self.delegate?.inputTextMaxCount(count: configure.textMaxCount)
            }
        }
        let size = sizeThatFits(bounds.size)
        let newFrame = CGRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)
        setFrame(newFrame, animated: true)
//        if !keepsPreModeTextViewWillEdited {
            textView.frame = frameTextView()
//        }
        textView.scrollRangeToVisible(textView.selectedRange)
    }
   
}
extension UITextView {
    
    fileprivate static let kPlaceholderTag = 20240202

    /// 占位文字 Label（由 placeholder setter 创建）
    var placeholderLabel: UILabel? {
        viewWithTag(UITextView.kPlaceholderTag) as? UILabel
    }

    /// 占位文字颜色
    var placeholderColor: UIColor {
        set { placeholderLabel?.textColor = newValue }
        get { placeholderLabel?.textColor ?? .gray }
    }

    /// 占位文字字体
    var placeholderFont: UIFont {
        set { placeholderLabel?.font = newValue }
        get { placeholderLabel?.font ?? .systemFont(ofSize: 14) }
    }

    var placeholder: String {
        set {
            if let lb = viewWithTag(UITextView.kPlaceholderTag) as? UILabel {
                lb.text = newValue
            } else {
                let lb = UILabel()
                lb.tag = UITextView.kPlaceholderTag
                lb.font = UIFont.systemFont(ofSize: 14)
                lb.numberOfLines = 0
                lb.textColor = UIColor.gray
                lb.text = newValue
                addSubview(lb)
                setValue(lb, forKey: "_placeholderLabel")
            }
        }
        get {
            let lb = value(forKey: "_placeholderLabel") as? UILabel
            return lb?.text ?? ""
        }
    }
}
