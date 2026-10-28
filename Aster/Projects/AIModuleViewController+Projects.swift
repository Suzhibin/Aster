//
//  AIModuleViewController+Projects.swift
//  Aster
//
//  项目（会话文件夹）在 iOS 会话页这一侧的全部接线 —— 2026-10-21。
//
//  ## 为什么接线放在会话页，而不是抽屉里
//  抽屉（`AIMenuViewController`）只负责**画**和**发信号**：它拿不到 `manager`，
//  也不该拿（抽屉是「一份全局实例」，一旦握住某个会话的 manager，切换会话就等于换了一份数据源）。
//  ⇒ 「造页面 + 接数据」全在会话页这边（它握着 `manager`），抽屉只调
//  `makeProjectDetailPage` 把页面拿到手、然后自己就地模态弹出来
//  （抽屉是宿主 present 出来的，宿主再 present 会撞「already presenting」）。
//
//  ## 两个入口，两条路
//  - **管理**（抽屉分组头「…」→「管理项目」）：加 / 删 / 预览 —— 直接写库；
//  - **选取**（输入区「+」→「项目资料」）：选一份带进待发区 —— **拷一份**再说，
//    理由见 `presentProjectFilePicker` 里那段（撤销附件会删盘）。
//

import UIKit
import AICore

extension AIModuleViewController {

    // MARK: - 管理态（抽屉 → 分组头「…」→ 管理项目）

    /// 造一个管理态的项目详情页（由抽屉负责 modal 呈现，见 `makeProjectDetailPage` 的注释）
    func makeProjectDetailPage(_ project: AIChatProject) -> UIViewController {
        let page = AIProjectDetailViewController(project: project, mode: .manage, isModal: true)
        // 读：优先走 manager（它握着当前会话），会话无关的项目资料返回的也是同一份库
        page.filesProvider = { [weak self] in
            self?.manager.fetchProjectFiles(projectId: project.id)
                ?? AIChatStore.shared.fetchProjectFiles(projectId: project.id)
        }
        // 写：导入外部文件（`importFile` 落盘 + 落库，失败会回滚删文件，见 store）
        page.onAddFiles = { [weak self] urls in
            guard let self else { return }
            for url in urls {
                self.manager.addProjectFile(projectId: project.id, sourceURL: url)
            }
        }
        page.onDeleteFile = { [weak self] fileId in
            self?.manager.deleteProjectFile(id: fileId)
        }
        // 资料索引（RAG，2026-10-23）：状态读口 + 重建动作。
        // ⚠️ 与 Mac 同一个取舍：索引是派生物（真值是磁盘上那份文件），
        //    所以「重建」是**全量重读**的修复动作，只在管理态给。
        page.indexStatusProvider = { [weak self] in
            self?.manager.projectIndexStatus(projectId: project.id)
                ?? AIChatStore.shared.projectIndexStatus(projectId: project.id)
        }
        page.onRebuildIndex = { [weak self] in
            self?.manager.rebuildProjectIndex(projectId: project.id)
        }
        // 预览：推在**这个模态自己的 nav** 上。
        // ☠️ 不能调 `self.openFilePreview(...)` —— 那个推的是宿主自己的导航栈，
        //    页面会被推到模态**后面**去（用户看到的是「点了没反应」，且返回键在画外）。
        page.onPreviewFile = { [weak page] file in
            guard let page, let url = file.fileURL else { return }
            // QuickLook 只认实打实的本地文件（同 `openFilePreview` 的口径）：
            // 行还在、文件被删了（比如手动清了沙盒）⇒ 宁可不进去
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let preview = AIFilePreviewController(fileURL: url, displayName: file.displayName)
            page.navigationController?.pushViewController(preview, animated: true)
        }
        // 项目级指令（L3）：显示「已设置 / 未设置」，点进去复用**全局指令页**编辑。
        page.instructionProvider = { [weak self] in
            self?.manager.projectInstruction(id: project.id) ?? ""
        }
        page.onOpenInstruction = { [weak self, weak page] in
            guard let self, let page else { return }
            let editor = AIInstructionSettingsViewController()
            editor.screenTitle = L("项目指令")
            // 🔴 复用全局那一页、只换读写口（理由见 `AIInstructionSettingsViewController`
            //    里 `instructionProvider` 那段）：编辑器行为（击键即存 / 字数 / 预设 / 不 reload）
            //    一模一样，另写一页只会把那些坑重踩一遍。
            editor.instructionProvider = { [weak self] in
                self?.manager.projectInstruction(id: project.id) ?? ""
            }
            editor.onInstructionChange = { [weak self] text in
                self?.manager.setProjectInstruction(id: project.id, instruction: text)
            }
            page.navigationController?.pushViewController(editor, animated: true)
        }
        return page
    }

    // MARK: - 选取态（输入区「+」→ 项目资料）

    /// 列出**当前会话所属项目**的资料，选一份带进待发区。
    ///
    /// ## 🔴 为什么必须先 `importFile` 再进待发区
    /// 待发区那条 ✕ 会**连盘一起删**（`removeAttachment` → `AIAttachmentStorage.remove`）。
    /// 如果直接把项目资料的 URL 塞进待发区，用户点一次撤销就把项目里的文件删了 ——
    /// 而且是静默的（项目页下次刷新只是那一行不见了）。
    /// `importFile` 会拷一份新的（新 UUID 名）⇒ 撤销删的是副本，项目资料安然无恙。
    /// ⚠️ 代价是同一份文件在沙盒里存了两份。这个交换是划算的：
    ///    「发出去的文件」和「项目里的资料」本来就是两条命（前者可能被清理，后者要长期留着）。
    func presentProjectFilePicker() {
        guard let projectId = manager.activeProjectId,
              let project = manager.fetchProjects().first(where: { $0.id == projectId }) else {
            // 理论上进不来（那一格只在有项目时出现）；真出现了就说清原因，别静默
            showToast(L("当前会话不属于任何项目"))
            return
        }
        let page = AIProjectDetailViewController(project: project, mode: .pick, isModal: true)
        page.filesProvider = { [weak self] in
            self?.manager.fetchProjectFiles(projectId: projectId)
                ?? AIChatStore.shared.fetchProjectFiles(projectId: projectId)
        }
        page.onSelectFile = { [weak self] file in
            guard let self else { return }
            guard let url = file.fileURL else {
                self.showToast(L("文件已不存在"))
                return
            }
            guard let copy = AIAttachmentStorage.importFile(at: url) else { return }
            self.appendAttachments([copy])
        }
        // ⚠️ 选取页**自带 dismiss**（见 `didSelectRowAt`），这里不用再管关闭
        present(UINavigationController(rootViewController: page), animated: true)
    }

    // MARK: - `@` 项目资料（2026-10-21）

    /// 输入框里打 `@` 时弹的选择页。
    ///
    /// 🔴 **复用 `.pick` 模式那张表**，只是回调不同（`appendMention` 而不是 `appendAttachments`）：
    ///    - `presentProjectFilePicker()` = 「＋ → 项目资料」= **导入一份副本**变成附件；
    ///    - 这里 = 「@ 一份资料」= **引用项目里那一份**（不复制、不落成消息行）。
    ///    两者共用同一个列表视图（`ProjectDetailView` 那套），⛔ 别为了「少一个参数」合成一条路径：
    ///    合成的结果必然是「@ 也会复制一份文件」或「＋ 也不复制」，两边都错。
    ///
    /// ⚠️ 没项目时**不静默**：用户打了 `@` 却什么都没发生，只会以为功能坏了。
    func presentProjectMentionPicker() {
        guard let projectId = manager.activeProjectId,
              let project = manager.fetchProjects().first(where: { $0.id == projectId }) else {
            showToast(L("当前会话不属于任何项目"))
            return
        }
        let page = AIProjectDetailViewController(project: project, mode: .pick, isModal: true)
        page.filesProvider = { [weak self] in
            self?.manager.fetchProjectFiles(projectId: projectId)
                ?? AIChatStore.shared.fetchProjectFiles(projectId: projectId)
        }
        page.onSelectFile = { [weak self] file in
            self?.appendMention(file)
        }
        // ⚠️ 选取页**自带 dismiss**（见 `didSelectRowAt`），这里只管把关。
        // ⛔ 别在这里的 completion 里收焦点：那个 completion 是「弹出动画结束」时调的，
        //    此刻选择页还在屏上 —— 把焦点抢回输入框会让 sheet 立刻塌下去。
        //    「选完之后焦点还给输入框」那件事在 `appendMention` 里延后做。
        present(UINavigationController(rootViewController: page), animated: true)
    }

    // MARK: - 「+」面板第 4 格的开合
    /// 会话归属变了 ⇒ 决定「+」面板里要不要出现「项目资料」。
    ///
    /// 调用点只有一处：`refreshComposerBanner()` 的第一行（切会话 / 新建对话 / 切归属
    /// 都会走那条链）。⛔ 别在多处各调一遍 —— 迟早有一处漏掉，症状是
    /// 「切到项目里的会话，面板还是三格」（不报错）。
    ///
    /// 🔴 更隐蔽的坑是**那条链的调用时机**：`refreshComposerBanner()` 必须发生在
    /// 会话状态变更**之后**（`switchToConversation` / `newConversation` /
    /// `setConversationProject` 成功之后）。放在前面 = 读到上一个会话的归属 ——
    /// 症状「项目里的对话没有『项目资料』格、未归类反而有」（2026-10-24 实测，
    /// 编译零症状）。冷启动那次也不例外：放在 `setupUI()` 之后（要碰 inputToolbar）。
    ///
    /// 2026-10-25 起「未归类」已消灭（所有会话必有项目，默认容器 = 任务）
    /// ⇒ 这个判断实际上恒真、面板恒 4 格。`!= nil` 留着防 ensure 极端失败，
    /// ⛔ 别因此把函数整个删了 —— 探针读的就是 `debugKinds`，链路要留着能被验。
    func refreshProjectEntry() {
        inputToolbar.setProjectEntryAvailable(manager.activeProjectId != nil)
    }
}
