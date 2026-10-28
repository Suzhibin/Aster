import UIKit
import SideMenu
import AICore

/// 侧滑菜单接线 + 菜单里的跳转入口。
///
/// 菜单数据 / 回调统一在这里接线：菜单实例可能是宿主全局注册的（`SceneDelegate.setupAIMenu`），
/// 也可能是本页兜底创建的，两条路都收敛到 `wireMenu(_:)` 一个入口。
///
/// 跳转的两条路线（别搞混）：
/// - **搜索页**：无动画关抽屉 + push 主栈（完整一页，靠返回键回来）；
/// - **设置页 / 账号菜单**：抽屉**不关**，就地模态弹出（见 `AIMenuViewController.presentSettings`）。
extension AIModuleViewController {

    // MARK: - 侧滑菜单

    /// 菜单数据 / 回调接线（菜单实例可能由宿主全局注册，也可能由本页兜底创建，统一在此接线）
    func wireMenu(_ menu: AIMenuViewController) {
        // 对话列表：直接读持久化仓库，不依赖 VC 是否存活
        menu.conversationProvider = { [weak self] in
            self?.manager.fetchSummaries() ?? AIChatStore.shared.fetchSummaries()
        }
        // 当前会话 id（列表高亮）
        menu.activeConversationIdProvider = { [weak self] in
            guard let self = self, self.manager.hasActiveConversation else { return nil }
            return self.manager.activeConversationId
        }
        // 新对话 / 头部新对话按钮
        menu.onNewChat = { [weak self] in
            guard let self else { return }
            self.startNewChat()
        }
        // 文档（2026-10-10 取代「AI创作」）：push 一整页跨会话的文件列表
        menu.onDocumentsTapped = { [weak self] in
            guard let self else { return }
            self.openDocuments()
        }
        // 历史对话：按 id 从库里载入该会话的全部历史
        menu.onSelectConversation = { [weak self] id in
            guard let self else { return }
            self.openConversation(id)
        }
        // 重命名：改库 + 同步内存标题
        menu.onRenameConversation = { [weak self] id, title in
            guard let self else { return }
            self.manager.renameConversation(id: id, to: title)
        }
        // 置顶 / 取消置顶
        menu.onSetPinned = { [weak self] id, isPinned in
            guard let self else { return }
            self.manager.setConversationPinned(id: id, isPinned: isPinned)
        }
        // 删除会话：若删的正是当前会话，回到落地页
        menu.onDeleteConversation = { [weak self] id in
            guard let self = self, self.manager.deleteConversation(id: id) else { return }
            self.isStreaming = false
            self.dismissActionMenu()
            self.mode = .landing
            self.applyMode()
            self.tableView.reloadData()
        }
        // 分享：把会话内容拼成纯文本交给菜单弹系统分享面板
        menu.conversationTextProvider = { id in
            guard let conversation = AIChatStore.shared.loadConversation(id: id) else { return nil }
            return Self.shareText(for: conversation)
        }
        // MARK: 项目（会话文件夹，2026-10-21）
        //
        // ⚠️ 项目列表与 `conversationProvider` **同一拍**取（菜单在 `refreshConversations()`
        // 里连着调两个 provider）—— 分组投影同时要用这两份数据，分两拍就会画出半帧状态。
        menu.projectProvider = { [weak self] in
            self?.manager.fetchProjects() ?? AIChatStore.shared.fetchProjects()
        }
        // 新建项目：第二个参数来自行菜单「移动到项目 → 新建项目…」那条路径，
        // 建完顺手把那条会话移进去（⚠️ 两步都在**同一层**做完，菜单拿不到新建项目的 id）
        menu.onCreateProject = { [weak self] name, moveConversationId in
            guard let self, let project = self.manager.createProject(name: name) else { return }
            if let moveConversationId {
                self.manager.setConversationProject(conversationId: moveConversationId,
                                                    projectId: project.id)
                self.tableView.reloadData()
                // 移进来的可能正是**当前会话** ⇒ 刷一次归属相关的输入栏状态
                // （「+」面板第 4 格 + `@` 资料条校验，幂等）
                self.refreshComposerBanner()
            }
        }
        menu.onRenameProject = { [weak self] id, name in
            self?.manager.renameProject(id: id, name: name)
        }
        // 删除项目：会话不会跟着删（store 里级联 = 会话移回默认项目「任务」+ 删资料）。
        // ⚠️ 若删的是**当前会话**所在的项目，`manager` 会把内存里的归属落回默认组 ——
        //    输入栏也要跟着刷（`@` 资料条的归属校验；第 4 格 2026-10-25 起恒显示）。
        menu.onDeleteProject = { [weak self] id in
            self?.manager.deleteProject(id: id)
            self?.refreshComposerBanner()
        }
        // 移动归属：不动 updatedAt（见 `AIChatStore.setConversationProject`），
        // 所以**不需要**重载会话页 —— 消息列表与顺序都没变。
        // ⚠️ 但输入栏要刷：移动的正是当前会话时，「+」面板第 4 格与 `@` 资料条
        // 的显隐都跟着归属走（`refreshComposerBanner` 第一行，幂等）。
        menu.onMoveConversation = { [weak self] conversationId, projectId in
            self?.manager.setConversationProject(conversationId: conversationId, projectId: projectId)
            self?.refreshComposerBanner()
        }
        // 项目详情页：**宿主造、抽屉弹**（抽屉是宿主 present 出来的，
        // 宿主自己再 present 会撞「already presenting」而静默不出）。
        // 页面里的数据接线在 `+Projects.swift`，这里只交一个构造闭包。
        menu.makeProjectDetailPage = { [weak self] project in
            self?.makeProjectDetailPage(project)
        }
        // 设置（右下角齿轮 / 账号菜单里的「设置」）：**正常情况下菜单自己就地模态弹出设置页**
        //（抽屉不关，见 AIMenuViewController.presentSettings），压根不会走到这里；
        // 只有菜单不是被模态呈现、present 不了时，才回调宿主兜底代开。
        menu.onSettings = { [weak self] in
            guard let self else { return }
            self.openSettings()
        }
        // ⚠️ 这里**没有** `onProfileTapped` 接线（2026-10-09 起该回调已删）：
        // 点「头像 + 名称」弹的是账号菜单（设置 / 暗黑模式 / GitHub），三个入口都在菜单
        // 那一层就地完成，压根不需要宿主 —— 别又把个人资料页接回来（那一页已按要求删掉）。
        // 顶部搜索框：菜单已自行无动画关闭，这里 push 搜索页
        menu.onSearchTapped = { [weak self] in
            guard let self else { return }
            self.openSearch()
        }
    }

    /// 注册侧滑菜单：宿主（如 SceneDelegate.setupAIMenu）已注册则复用其实例（保留其 presentationStyle 等配置），
    /// 仅补数据接线；否则本页兜底注册一个默认样式的菜单。
    func setupMenu() {
        if let existing = SideMenuManager.default.leftMenuNavigationController?
            .viewControllers.first as? AIMenuViewController {
            wireMenu(existing)
        } else {
            let menu = AIMenuViewController()
            wireMenu(menu)
            let nav = SideMenuNavigationController(rootViewController: menu)
            SideMenuManager.default.leftMenuNavigationController = nav
        }
        SideMenuManager.default.addPanGestureToPresent(toView: self.view)
    }

    /// 顶栏左按钮：呼出侧滑菜单
    @objc func menuButtonTapped() {
        view.endEditing(true)
        guard let menu = SideMenuManager.default.leftMenuNavigationController else { return }
        present(menu, animated: true, completion: nil)
    }

    // MARK: - 跳转

    /// 打开搜索页：**推进当前导航栈**（与设置页同一套做法）。
    ///
    /// 搜索框在菜单里是「长得像输入框的按钮」（菜单拦下编辑、无动画关抽屉），
    /// 真正的输入与结果列表都在这一页；所以这一页一进来就自动聚焦、把键盘顶起来。
    /// 选中某条结果 = 关掉本页 + 载入该会话：**先 pop 再切内容**，
    /// 返回动画进行时后面已经就位，比「先切内容再 pop」少一次可见的跳变。
    private func openSearch() {
        view.endEditing(true)
        let search = AIChatSearchViewController()
        search.searchProvider = { keyword in
            AIChatStore.shared.search(keyword: keyword)
        }
        search.onSelectHit = { [weak self] hit in
            guard let self = self else { return }
            self.navigationController?.popViewController(animated: true)
            // 标题命中没有 messageId → 只打开会话（`openConversation` 里会判空）
            self.openConversation(hit.conversationId, revealing: hit.messageId)
        }
        if let nav = navigationController {
            nav.pushViewController(search, animated: false)
        } else {
            // 宿主没给导航栈（本页被模态呈现）→ 自己套一层，搜索页才能有返回键
            present(UINavigationController(rootViewController: search), animated: false)
        }
    }

    /// 打开「文档」页（2026-10-10：侧滑菜单第 0 组那颗，取代原「AI创作」）。
    ///
    /// 形态与搜索页**刻意一致**：菜单已自行**无动画**关抽屉，这里 push 一整页，
    /// 返回键 / 边缘侧滑即回。⛔ 别改成抽屉里的就地列表（240pt 宽读不了长文件名）。
    ///
    /// ⚠️ 数据源接的是 `AIChatStore.shared` 而**不是** `manager`：这一页要的是
    /// **全部会话**的文件，而 `manager` 只握着当前会话。
    private func openDocuments() {
        view.endEditing(true)
        let documents = AIDocumentsViewController()
        documents.documentsProvider = {
            AIChatStore.shared.fetchDocuments()
        }
        documents.onSelect = { [weak self] item in
            guard let self else { return }
            // 打开预览的是**本地文件**：能进这个列表的天然都是 `AIAttachmentStorage` 落地的路径
            //（`fetchDocuments` 已经把解析不出路径 / 文件已不存在的行滤掉了）
            self.openFilePreview(item.fileURL, displayName: item.displayName)
        }
        if let nav = navigationController {
            nav.pushViewController(documents, animated: true)
        } else {
            // 宿主没给导航栈（本页被模态呈现）→ 自己套一层，文档页才有返回键
            present(UINavigationController(rootViewController: documents), animated: true)
        }
    }

    /// 打开设置页 —— **现在只是兜底路径**。
    ///
    /// 主路径已改成「`AIMenuViewController` 就地模态弹出设置页」（抽屉保持打开，对齐 DeepSeek），
    /// 见 `AIMenuViewController.presentSettings`。只有菜单不被模态呈现、自己 present 不了时，
    /// 才由宿主在这里代开。
    ///
    /// 两个分支都保留：本页正常是导航栈的 root（宿主 `UINavigationController(rootViewController:)`），
    /// 推入导航栈（返回键 / 侧滑即返回）；拿不到导航栈时才退化成模态（此时设置页自备关闭按钮）。
    /// 🔴 落点是**设置页**（`AISettingsViewController`，2026-10-14 新建）——
    ///    它取代了原来直连的「自定义模型」清单页（用户要求把语言 / 外观入口收进设置）。
    ///    ⚠️ push 时 `isModal` 传 **false**（左上角交系统返回键）；
    ///    模态时才传 true（没有返回键，得自备关闭）。
    private func openSettings() {
        view.endEditing(true)
        if let nav = navigationController {
            nav.pushViewController(AISettingsViewController(), animated: true)
        } else {
            let nav = UINavigationController(
                rootViewController: AISettingsViewController(isModal: true))
            present(nav, animated: true)
        }
    }

    // MARK: - 🧪 验收钩子：直接进「添加模型」页

    /// `STARRY_SETTINGS_UI` 非空时启动后**自动**推一次设置页（只推一次，闩在 `didAutoOpenSettings`）。
    ///
    /// ## 为什么非要有这个钩子（与 `+Voice.openVoiceCallIfRequested` 同一条理由）
    /// 设置页在导航栈的第二层，而模拟器**没有任何命令行点按手段**
    /// （`xcrun simctl` 不提供 tap / touch，`io` 只能截图录屏）——
    /// 没有它，「设置页长什么样 / 四个子页各自长什么样」agent 侧完全验收不了。
    /// `typecheck_aster.sh` 那几条契约只能证明「哪几段代码在、次序对不对」，
    /// 证不了「控件有没有互相挤坏」。
    ///
    /// ## 三个约束（逐条照抄通话页那个钩子）
    /// 1. **只在 `#if DEBUG` 下编译进去** —— Release 包里这段代码根本不存在；
    /// 2. **只触发一次**（闩在 `didAutoOpenSettings`）—— 否则从子页返回会又被推进去；
    /// 3. 走的是**和点齿轮完全相同的那条路**（`openSettings()`），
    ///    ⛔ 别另写一条"直接 push"的捷径 —— 那样验的就不是用户真实走的路径了。
    ///
    /// ## 取值（2026-10-14 起它是一条**链**，各层各认领一段）
    ///        取值          停在哪一层
    ///        `1`（默认）    设置页
    ///        `lang`         设置页 → 语言三档页
    ///        `appearance`   设置页 → 外观三档页
    ///        `about`        设置页 → 关于页
    ///        `list`         设置页 →「自定义模型」清单页
    ///        `form`         … → 清单页 →「添加模型」表单
    ///        `provider`     … → 表单 → 供应商**模态选择页**
    ///        `model`        … → 表单 → 模型**模态选择页**
    ///        `draft`        … → 表单，自动把字段填上（「填了没保存」长什么样）
    ///        `draft-discard` … → 同上，2 秒后**不点保存**自动离开（离开即丢弃探针）
    ///    ⚠️ 本段只负责**把设置页推出来**；再往下每一层由那一页自己的钩子认领
    ///    （`AISettingsViewController.openSubPageIfRequested` ·
    ///      `AICustomModelListViewController.openFormIfRequested` ·
    ///      `AIAddModelViewController.openPickerIfRequested`），取值都读同一个变量。
    func openSettingsIfRequested() {
        #if DEBUG
        guard !didAutoOpenSettings else { return }
        let mode = ProcessInfo.processInfo.environment["STARRY_SETTINGS_UI"] ?? ""
        guard !mode.isEmpty else { return }
        didAutoOpenSettings = true
        // 等这一帧画完再推（同通话页那条注释：直接在 `viewDidAppear` 里 push 会截到半透明残影）。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.openSettings()
        }
        #endif
    }

    // MARK: - 🧪 验收钩子：空态「去配置模型」那条路

    /// `STARRY_EMPTY_GUIDE=1` 时启动后**自动点一次**会话空态的「去配置模型」（2026-10-26）。
    ///
    /// ## 为什么需要
    /// 那颗钮现在落点是**两层**（清单页 + 立刻压上的「添加模型」表单），而模拟器没有任何
    /// 点按手段（`xcrun simctl` 只给截图录屏，见 `openSettingsIfRequested`）——
    /// 不开这个口子，「点完到底停在哪一层」agent 侧一张图都拿不到。
    ///
    /// ## 三条约束（与 `openSettingsIfRequested` 逐条同义）
    /// 1. 只在 `#if DEBUG` 下编译；
    /// 2. 只触发一次（闩在 `didAutoOpenModelGuide`）—— 从表单返回会再走一次 `viewDidAppear`；
    /// 3. 走的是**和点击完全相同**的那个方法（`openModelSettings()`），⛔ 另写"直接 push"等于验了别的路径。
    ///
    /// ⚠️ 前置条件是「当前没有模型」：有模型时引导根本不显示，钩子也不该动。
    func openModelGuideIfRequested() {
        #if DEBUG
        guard !didAutoOpenModelGuide else { return }
        guard ProcessInfo.processInfo.environment["STARRY_EMPTY_GUIDE"] == "1" else { return }
        guard !AIConfig.hasModel else { return }
        didAutoOpenModelGuide = true
        // 等这一帧画完再推（同上面那条：直接在 `viewDidAppear` 里 push 会截到半透明残影）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.openModelSettings()
        }
        #endif
    }

    // MARK: - 🧪 验收钩子：直接进「项目指令」编辑页（2026-10-27）

    /// `STARRY_PROJECT_UI=instruction` 时启动后自动走「管理项目 → 项目指令」那条链。
    ///
    /// ## 为什么非要有它
    /// 项目指令页在「抽屉 → 项目详情（模态）→ push 编辑页」**三层深**，而模拟器没有任何
    /// 命令行点按手段（`simctl` 不提供 tap）⇒ 不替用户点，项目级那版页面上
    /// 「与全局指令叠加使用」那句 footer **一张图都拿不到**
    /// （`typecheck_aster.sh` 只证得了「footer 函数在、守卫在、文案在」）。
    ///
    /// ## 三个约束（逐条照抄 `openSettingsIfRequested`）
    /// 1. **只在 `#if DEBUG` 下编译进去** —— Release 包里这段代码根本不存在；
    /// 2. **只触发一次**（闩在 `didAutoOpenProjectInstruction`）；
    /// 3. 造页走**同一个** `makeProjectDetailPage`（抽屉「管理项目」点的就是它），
    ///    进编辑页调 `onOpenInstruction`（详情页那一行的真实回调）。
    ///    ⛔ 别在这里 new 一个 `AIInstructionSettingsViewController` 自己注入读写口 ——
    ///    那样验的就不是「注入口那条路」了（正是它最可能坏）。
    func openProjectInstructionIfRequested() {
        #if DEBUG
        guard !didAutoOpenProjectInstruction else { return }
        guard ProcessInfo.processInfo.environment["STARRY_PROJECT_UI"] == "instruction" else { return }
        didAutoOpenProjectInstruction = true
        // 等这一帧画完（同上面几条：直接在 `viewDidAppear` 里 present 会截到半透明残影）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 项目来源走 manager 的真实读口；默认项目「任务」删不掉 ⇒ 一定有
            guard let project = self.manager.fetchProjects().first,
                  let page = self.makeProjectDetailPage(project) as? AIProjectDetailViewController
            else { return }
            // 与抽屉 `presentProjectDetail` 同一套包法（自备 nav，编辑页要 push 上去）
            self.present(UINavigationController(rootViewController: page), animated: false) {
                // 再等一拍：模态呈现的 layout 还没走完就 push 会 push 到 nav 之外的时序上
                DispatchQueue.main.async { page.onOpenInstruction?() }
            }
        }
        #endif
    }

    /// ⚠️ 2026-10-09：`openProfile()` 与 `AIProfileViewController` **已删**
    /// （用户要求「iOS 端个人资料页删掉」）。账号菜单的三个入口（设置 / 暗黑模式 / GitHub）
    /// 全部在菜单那一层就地完成，**不再有「从抽屉跳到主流程某一页」的第二条路线** ——
    /// 现在这条路线只剩**搜索页**一处。⛔ 别把资料页接回来。
    ///
    /// ## 打开内置网页页（2026-10-02：助手回复里的网址点一下 push 进去）。
    ///
    /// 形态与 mac 端刻意不同：那边窗口宽、会话页与网页同屏并排（`.inspector` 面板）；
    /// iOS 屏窄 ⇒ 推一整页、左上角返回键回来。⛔ 别把面板那套搬过来。
    ///
    /// ⚠️ 非 http(s)（`mailto:` / `tel:` / 自定义 scheme）**不进网页页**，交回系统
    ///（邮件 / 电话）—— 与共享层 `AILinkify` 不主动造这类链接是同一个口径。
    func openWebPage(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url)
            return
        }
        view.endEditing(true)
        let page = AIWebPageViewController(url: url)
        if let nav = navigationController {
            nav.pushViewController(page, animated: true)
        } else {
            // 宿主没给导航栈（本页被模态呈现）→ 自己套一层，网页页才有返回键
            present(UINavigationController(rootViewController: page), animated: true)
        }
    }

    /// 打开**文件预览页**（2026-10-06：轻点「自己发出的文件」那一行 push 进去）。
    ///
    /// 形态与网页页**刻意一致**：推一整页、左上角返回。⛔ 别改成「盖在会话上的浮层」——
    /// 那会把返回入口一起藏掉，而预览的是文档、不是一句提示。
    ///
    /// ⚠️ 拿到的是 `AIAttachmentStorage` 落地的**本地**附件路径。QuickLook **只认 `file://`、
    /// 不做下载**（见 `AIFilePreviewController` 文件头）⇒ 这里不做任何网络兜底：
    /// 路径无效时宁可不进这一页（空白预览页比「没反应」更像坏了）。
    ///
    /// ⚠️ **不做 `canPreview` 预检**：用户口径是「只要是文件消息都可以进入」（2026-10-06 原话），
    /// 所以冷门格式也照进 —— QuickLook 自己会画「无法预览」那套兜底界面，比我们挡下来更清楚。
    ///（真要改成「不能预览就转分享」，落点就是这里，**别在 cell 里判**。）
    ///
    /// - Parameter displayName: **用户当初发的文件名**（`row.block.text`）。🔴 必须传 ——
    ///   附件落盘时名字被换成了 UUID，不传的话预览页标题会写成那串 UUID（2026-10-06 实拍踩到）。
    func openFilePreview(_ url: URL, displayName: String) {
        // 只认本地文件：`file://` 之外的地址 QuickLook 出不来内容（不是「网速慢」那类问题）。
        guard url.isFileURL else { return }
        // 文件已经被删 / 从没落地过 —— 进去只会是一片空白。
        guard FileManager.default.fileExists(atPath: url.path) else {
            showToast(L("文件已不存在"))
            return
        }
        view.endEditing(true)
        let page = AIFilePreviewController(fileURL: url, displayName: displayName)
        if let nav = navigationController {
            nav.pushViewController(page, animated: true)
        } else {
            // 宿主没给导航栈（本页被模态呈现）→ 自己套一层，预览页才有返回键
            present(UINavigationController(rootViewController: page), animated: true)
        }
    }

    // MARK: - 会话

    /// 打开历史会话：载入该会话全部消息并进入对话态。
    ///
    /// - Parameter revealing: 需要**滚动定位并高亮**的消息 id（搜索结果点击时传入；
    ///   标题命中 / 从列表进入时为 nil）。
    ///   ⚠️ 定位必须在 `enterChat()` **之后**：`enterChat` 会 `reloadData` + 滚到底，
    ///   先定位会被那次「滚到底」顶掉，用户看到的还是最新消息。
    func openConversation(_ id: UUID, revealing messageID: UUID? = nil) {
        isStreaming = false
        stopSpeech()
        dismissActionMenu()
        // 换会话 = 列表整批换掉，选择模式里勾的那些行号一个都不作数了 → 先退出来
        //（`applyMode` 里只在回落地页时退，这里走的是 `enterChat`，得自己收）
        exitSelectionMode()
        // 引用与编辑态都锚定「某条具体的消息」，换了会话它们就不成立了 ——
        // 不清的话，编辑态下发送会去截断新会话里一个毫不相干的行（行号是旧会话的）
        pendingQuote = nil
        editingMessageId = nil
        guard manager.switchToConversation(id: id) else {
            // 会话不存在：`conversation` 没换成（还是旧那个），但引用 / 编辑态已经清了
            // ⇒ 这里也得刷一次，否则状态条上留着一条「不会被使用」的引用 / 编辑态
            refreshComposerBanner()
            showToast(L("该会话已不存在"))
            return
        }
        // 🔴 刷新必须放在**载入成功之后**：`refreshComposerBanner` 第一行的
        // `refreshProjectEntry()` 读的是 `manager.activeProjectId`（= **新**会话的
        // projectId）。放在 switch 之前，读到的是**上一个会话**的归属 ——
        // 症状「切到项目里的对话没有『项目资料』格、切回未归类反而有」
        // （2026-10-24 用户实测；编译零症状、静默错位，`@` 资料条的归属校验
        // 也走同一条链，一并修好）。
        // 注：2026-10-25「未归类」消灭后第 4 格恒显示，这条时序纪律对 `@` 资料条
        // 的归属校验仍然有效（那条链没错就没事，错了 = 读到别的项目的资料）。
        refreshComposerBanner()
        enterChat()
        if let messageID = messageID { revealMessage(id: messageID) }
    }

    /// 分享文本：标题 + 逐条「我/AI：内容」（图片视频退化为 URL）
    static func shareText(for conversation: AIConversation) -> String {
        var lines: [String] = [conversation.title.isEmpty ? L("新对话") : conversation.title, ""]
        for row in conversation.rows {
            let prefix = row.role == .user ? L("我") : "AI"
            switch row.block.kind {
            case .text:
                guard !row.block.text.isEmpty else { continue }
                lines.append("\(prefix)：\(row.block.text)")
            case .image:
                if let url = row.block.imageURL { lines.append("\(prefix)：[图片] \(url.absoluteString)") }
            case .file:
                // 分享出去只带文件名，不带沙盒路径 —— 对面打开一个本机路径没有意义
                lines.append("\(prefix)：[文件] \(row.block.text)")
            case .video:
                if let url = row.block.videoURL { lines.append("\(prefix)：[视频] \(url.absoluteString)") }
            case .error:
                // 失败提示也如实带出去，分享出去的记录跟界面上看到的一致
                lines.append("\(prefix)：\(row.block.text)")
            case .modelSwitch:
                // 系统流水不是对话内容：分享出去的记录里塞一行「模型已从 A 更改为 B」
                // 只会让对面以为这是谁说过的一句话（与 `AIChatManager.transcript` 同一口径）
                continue
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 🧪 思考展示探针辅助（#if DEBUG）

#if DEBUG
extension AIModuleViewController {
    /// 探针专用：把指定行补成「用户点开」态。
    ///
    /// `isThinkingExpanded` 是**运行时状态、不落库**（读回恒 false）⇒ 展开态只能内存补；
    /// 展开 / 重算高度 / reload 全走 `manager.setThinkingExpanded`（用户点开的**同一路径**），
    /// ⛔ 视图层不自己估高度（本工程铁律）。
    func probeExpandThinking(atRowIndex index: Int) {
        manager.setThinkingExpanded(true, atRowIndex: index)
    }

    /// 探针判据：当前屏上「chevron 已挂载」的思考块数量。
    ///
    /// 走 `visibleCells` 而不是 rows —— 2026-10-21 那个崩溃当初就发生在
    /// cell 的 `init(frame:)` 里（SnapKit 给没有 superview 的 chevron 装约束），
    /// 只有**真的实例化过**的 cell 才能证明「init 这条路走通了」。
    func probeMountedChevronCount() -> Int {
        tableView.visibleCells
            .compactMap { $0 as? AIAssistantTextCell }
            .filter { $0.probeThinkingChevronMounted }
            .count
    }

    /// 探针判据：某行**读回来的** reasoning 字符数（0 = 落库/读回链路断了）。
    ///
    /// ☠️ 与 `probeMountedChevronCount` **必须分开判**（2026-10-21 首轮探针的教训）：
    /// 后者只证明「cell 实例化过、init 没崩」；思考内容读不读得回来是**落库链路**的事
    /// —— 当初 `appendMessages` 漏插 reasoning，chevron 绿着、图上却没有思考行。
    func probeReasoningChars(atRowIndex index: Int) -> Int {
        guard manager.rows.indices.contains(index) else { return -1 }
        return manager.rows[index].block.reasoning?.text.count ?? 0
    }
}
#endif
