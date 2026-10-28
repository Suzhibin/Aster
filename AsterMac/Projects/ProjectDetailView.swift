//
//  ProjectDetailView.swift
//  AsterMac
//
//  项目详情面板（macOS，sheet）—— 2026-10-21 随「项目（会话文件夹）」的 L2 新建。
//
//  ## 形态：**sheet**（不是主区域整页替换）
//  「文档」页占整页是因为它回答的是「我这一路传过哪些文件」（全局视角）；
//  项目资料回答的是「这个项目里放了什么」，属于**某个分组的属性**，弹一张表就够。
//  ⛔ 别改成主区域整页：那样点开一个项目会把会话一起挤走，用户根本记不住自己刚才在聊什么。
//  ⚠️ 与 iOS 的 `AIProjectDetailViewController` 是**两个实现、同一套口径**：
//    `manage`（可增删）/ `pick`（选一份带进输入框）。
//
//  ## 两种模式
//  - `.manage`：侧栏分组头「…」→「管理项目」—— 添加 / 删除 / 双击预览；
//  - `.pick`  ：输入栏「+」→「项目资料」—— 点一行就带进待发送列表，不给增删。
//  用 `onPick` 是不是 nil 来区分（同 iOS 侧 `mode` 的作用），⛔ 别再加一个布尔。
//
//  ## 数据走 `ChatModel`
//  与 Mac 侧其它视图一致：本视图**不直连 store**。
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AICore

struct ProjectDetailView: View {

    @Environment(ChatModel.self) private var model

    /// 目标项目（sheet 的 `item` 传进来）
    let project: AIChatProject

    /// 非 nil ⇒ 选取态（点一行交出去）；nil ⇒ 管理态
    var onPick: ((AIChatProjectFile) -> Void)?

    /// sheet 关闭
    @Environment(\.dismiss) private var dismiss

    /// 资料列表（**本地副本**：`ChatModel.projectFiles` 是现查的，
    /// 不存一份的话增删之后 SwiftUI 不知道该重算 —— 它看不见 store 的变化）
    @State private var files: [AIChatProjectFile] = []

    /// 文件选中失败的提示（如「文件已不存在」）——不弹 alert，底部一行红字就够
    @State private var hint: String?

    /// 项目级指令（L3）的编辑缓存。
    ///
    /// ⚠️ 必须有个本地副本：`ChatModel` 不是每帧都能现查（它没有把 instruction 发布出来）。
    /// 初值在 `onAppear` 读一次，之后由编辑器驱动。
    @State private var instruction: String = ""
    /// 防抖保存的任务（见 `scheduleInstructionSave`）
    @State private var instructionSaveTask: Task<Void, Never>?
    /// 指令初值是否已灌过（一次性闩，见 `reload()`）
    @State private var instructionLoaded = false

    /// 资料索引状态（RAG，2026-10-23）。本地副本的理由同 `files`：
    /// `ChatModel.projectIndexStatus` 是现查的，不存一份 SwiftUI 不知道何时重算。
    @State private var indexStatus: AIProjectIndexStatus?

    private var isPicking: Bool { onPick != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isPicking { instructionBox }
            if !isPicking { indexStatusBox }
            Divider()
            if files.isEmpty {
                emptyState
            } else {
                fileList
            }
            Divider()
            footer
        }
        // 🔴 固定尺寸（sheet 不自己长高）。494 → **528**：2026-10-27 指令块补了
        //    chip + 字数那一行（≈29pt）⇒ 高度必须跟着加，否则被挤掉的是下面的资料列表。
        //    ⚠️ 离屏验收档（`macrender/main.swift` ⑪）的 dump 尺寸与本行**必须同值**，
        //       那边写小了会把新加的那一行裁出画外 = 等于没验。
        .frame(width: 460, height: 528)
        .background(MacTheme.pageBackground)
        .onAppear(perform: reload)
        // 面板被关掉时把没落盘的那一次补上（防抖窗口内直接关窗会被吞掉）
        .onDisappear {
            instructionSaveTask?.cancel()
            commitInstruction()
        }
    }

    // MARK: - 资料索引状态（RAG，2026-10-23）

    /// 「资料索引」状态行：**只读状态 + 一个重建动作**。
    ///
    /// 为什么在这张面板里：索引是「这个项目的资料能不能被自动检索」的总闸，
    /// 用户看到「已索引 1/2」会自然想问「另一份怎么不行」—— 答案就写在副标题里
    /// （PDF/二进制一期不索引）。⛔ 别把它藏进设置窗：它是**项目属性**，
    /// 与指令、资料同属一个心智位置（同 `instructionBox` 的理由）。
    ///
    /// ⚠️ 只在管理态出现：选取态（挑一份带进输入框）不看这个。
    private var indexStatusBox: some View {
        HStack(spacing: 8) {
            Image(systemName: indexStatus?.hasIndexedContent == true ? "checkmark.seal" : "exclamationmark.triangle")
                .font(MacTheme.ui(13))
                .foregroundStyle(MacTheme.meta)
            VStack(alignment: .leading, spacing: 2) {
                Text(indexStatusTitle)
                    .font(MacTheme.ui(MacTheme.metaFontSize, weight: .semibold))
                    .foregroundStyle(MacTheme.bodyColor)
                if let hint = indexStatusHint {
                    Text(hint)
                        .font(MacTheme.ui(MacTheme.metaFontSize))
                        .foregroundStyle(MacTheme.meta.opacity(0.8))
                }
            }
            Spacer(minLength: 0)
            // 重建：文件在项目外被改过 / 早期版本导入的文件没建上索引时用。
            // ⚠️ 它是**全量重读**（每份文件重新切块），项目大时会慢 —— 但这是用户
            //    主动点的修复动作，⛔ 别做成自动的（每次进面板都重建 = 白读整个库）。
            Button(L("重建索引")) { rebuildIndex() }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// 状态行主文案（`nil` = 还没读出来，给一句中性的）
    private var indexStatusTitle: String {
        guard let status = indexStatus else { return L("索引状态读取中…") }
        return String(format: L("已索引 %d/%d · %d 个片段"),
                      status.indexedFileCount, status.fileCount, status.chunkCount)
    }

    /// 状态行副标题：有未索引资料时解释一句（没有 ⇒ nil，不占位）
    private var indexStatusHint: String? {
        guard let status = indexStatus, status.pendingCount > 0 else { return nil }
        return String(format: L("有 %d 份未索引：压缩包等暂不支持检索"), status.pendingCount)
    }

    /// 点「重建索引」
    private func rebuildIndex() {
        model.rebuildProjectIndex(project.id)
        reload()
        hint = L("索引已重建")
    }

    // MARK: - 项目指令（L3）

    /// 「项目指令」编辑块。
    ///
    /// ## 为什么在项目面板里编辑（而不是塞进设置窗）
    /// 指令是「这个项目里 AI 该怎么干活」，和项目的资料同属一个心智位置；
    /// 放进设置窗用户会在两个窗口之间来回跳。
    /// ⚠️ 只读/不可编辑的选取态不显示它（那是「挑一份资料」，不是改配置）。
    ///
    /// ## 🔴 与「设置 → 指令」是**叠加**，不是二选一（2026-10-27 补文案）
    /// 注入点 `AIChatManager.withSystemPrompt` 把 `[全局, 项目, 记忆]` 用空行 join 成
    /// 一条 system 消息 ⇒ 非空时两段**同时**进请求。原来这里写的是「空 = 只用全局指令」，
    /// 字面没错，但用户会读成「非空就替换全局」—— 于是把全局那段又抄一遍，
    /// system 里就出现两份近似文本（白烧 token 且容易互相打架）。改成直说关系。
    ///
    /// ## 快捷预设与字数（2026-10-27）
    /// 补上全局页有的两样：预设 chips（共享组件 `MacInstructionChipRow`）与字数。
    /// 少了它们，同一个「项目指令」在 iOS 端有、在 Mac 端没有（iOS 是复用全局那一页）
    /// ⇒ 同一功能两端能力不对等，而这在截图里看不出来（各看各的面板）。
    private var instructionBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(L("项目指令"))
                    .font(MacTheme.ui(MacTheme.metaFontSize, weight: .semibold))
                    .foregroundStyle(MacTheme.meta)
                Spacer(minLength: 0)
                Text(L("与全局指令叠加使用"))
                    .font(MacTheme.ui(MacTheme.metaFontSize))
                    .foregroundStyle(MacTheme.meta.opacity(0.8))
            }
            TextEditor(text: $instruction)
                .font(MacTheme.ui(12))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 64)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .onChange(of: instruction) { _, newValue in
                    // 🔴 与全局页同一条截断口径（`clampInstruction` 是唯一实现）。
                    //    超限才回写：那一拍会再触发一次本闭包，第二次 `clamped == newValue`
                    //    ⇒ 不再回写，防抖任务也只会留最后一个。
                    let clamped = AIGenerationSettings.clampInstruction(newValue)
                    if clamped != newValue { instruction = clamped }
                    scheduleInstructionSave()
                }
            // chips 与字数**同一行**：项目面板宽 460（内容区 428），四颗 chip ≈ 250pt
            // + 字数 ≈ 50pt 放得下 ⇒ 只多占一行高度（设置窗那边空间宽松才分行）。
            HStack(spacing: 8) {
                // 🔴 共享组件（设置页用的是同一个）：⛔ 别在这里再抄一份 chip 的实现
                MacInstructionChipRow { text in instruction = text }
                Spacer(minLength: 0)
                // ⚠️ `Text(verbatim:)` 不是可选写法：`Text("\(整数)")` 走的是
                //    LocalizedStringKey ⇒ 数字被本地化分组，2000 会显示成「2,000」，
                //    与 iOS 那页的「2000」对不上（同一个数两种写法，像是两套上限）。
                Text(verbatim: "\(instruction.count) / \(AIGenerationSettings.instructionMaxLength)")
                    .font(MacTheme.ui(MacTheme.metaFontSize))
                    // 打满上限后转红：编辑器会静默停止接收，不给提示的话像卡住了
                    .foregroundStyle(instruction.count >= AIGenerationSettings.instructionMaxLength
                                     ? Color.red.opacity(0.85)
                                     : MacTheme.meta.opacity(0.8))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    /// 击键 → 0.6 秒静默后再落库。
    ///
    /// 🔴 为什么不像 iOS 那样击键即存：那边写的是 `UserDefaults`（一次 set 是内存操作）；
    ///    这边是 **SQLite 一行 UPDATE**，每个字都写一次等于把一条指令敲成几十次磁盘提交。
    /// ⚠️ 关窗时 `onDisappear` 会补一次，所以「打完最后一个字马上关」也不会丢。
    private func scheduleInstructionSave() {
        instructionSaveTask?.cancel()
        instructionSaveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            commitInstruction()
        }
    }

    private func commitInstruction() {
        // 值没变就不写（`setProjectInstruction` 会顺带 refreshAll）
        guard instruction != model.projectInstruction(project.id) else { return }
        model.setProjectInstruction(project.id, instruction)
    }

    // MARK: - 三段

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(MacTheme.ui(13))
                .foregroundStyle(MacTheme.meta)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(MacTheme.ui(14, weight: .semibold))
                    .foregroundStyle(MacTheme.bodyColor)
                    .lineLimit(1)
                Text(String(format: L("%d 份资料"), files.count))
                    .font(MacTheme.ui(MacTheme.metaFontSize))
                    .foregroundStyle(MacTheme.meta)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var fileList: some View {
        List(files) { file in
            ProjectFileRow(file: file,
                           canDelete: !isPicking,
                           onOpen: { open(file) },
                           onDelete: { delete(file) })
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Image(systemName: "books.vertical")
                .font(MacTheme.ui(26))
                .foregroundStyle(MacTheme.meta)
            Text(L("还没有资料"))
                .font(MacTheme.ui(13))
                .foregroundStyle(MacTheme.bodyColor)
            Text(L("把常看的文件放进项目，聊这个项目时随时取用"))
                .font(MacTheme.ui(MacTheme.metaFontSize))
                .foregroundStyle(MacTheme.meta)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let hint {
                Text(hint)
                    .font(MacTheme.ui(MacTheme.metaFontSize))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // 「添加文件」只在管理态出现：选取态是「挑一个」，加进来是**改数据**
            if !isPicking {
                Button(L("添加文件…")) { addFiles() }
            }
            Button(L("完成")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 动作

    private func reload() {
        files = model.projectFiles(project.id)
        indexStatus = model.projectIndexStatus(project.id)
        // ⚠️ 指令**只灌一次初值**：`reload()` 在增删文件后也会调，每次都覆盖会把
        //    用户正在打的内容冲掉（尤其「清空了一部分还没落库」那一帧）。
        //    ⇒ 用一次性闩，别用「当前为空才灌」—— 用户真清空时那条件又成立了。
        if !instructionLoaded {
            instructionLoaded = true
            instruction = model.projectInstruction(project.id)
        }
    }

    /// 添加：系统文件选择器（沙盒下由 Powerbox 授权，可直接读）
    ///
    /// ⚠️ `canChooseDirectories = false`：`importFile` 用的是 `copyItem`，
    ///    一个文件夹会被**递归整棵拷进沙盒**（iOS 侧同一条闸门，见 `ComposerAttachmentPicker`）。
    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = L("添加")
        panel.message = L("选择要放进这个项目的文件")
        guard panel.runModal() == .OK else { return }
        var failed = 0
        for url in panel.urls where !model.addProjectFile(project.id, from: url) {
            failed += 1
        }
        if failed > 0 {
            hint = String(format: L("%d 个文件读不进来"), failed)
        } else {
            hint = nil
        }
        reload()
    }

    /// 点一行：管理态 = 用系统默认程序打开；选取态 = 带进待发送列表
    private func open(_ file: AIChatProjectFile) {
        if let onPick {
            onPick(file)
            dismiss()
            return
        }
        guard let url = file.fileURL, FileManager.default.fileExists(atPath: url.path) else {
            hint = L("文件已不存在")
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func delete(_ file: AIChatProjectFile) {
        model.deleteProjectFile(file.id)
        reload()
    }
}

// MARK: - 行

/// 一行项目资料：扩展名角标 + 文件名 + 「大小 · 加入时间」+（管理态）删除按钮。
///
/// ⚠️ **不吃 `@Environment`**：渲染台要能不带环境单独渲它（同 `DocumentRow` 的理由）。
struct ProjectFileRow: View {

    let file: AIChatProjectFile
    /// 管理态才给删除（选取态不该顺手改掉项目资料）
    let canDelete: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName)
                    .font(MacTheme.ui(13))
                    .foregroundStyle(MacTheme.bodyColor)
                    .lineLimit(2)
                Text(detailText)
                    .font(MacTheme.ui(MacTheme.metaFontSize))
                    .foregroundStyle(MacTheme.meta)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if canDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(MacTheme.ui(11))
                        .foregroundStyle(MacTheme.meta)
                }
                .buttonStyle(.plain)
                .help(L("删除"))
            }
        }
        .padding(.vertical, 4)
        // 整行可点：默认命中形状只有「画了东西的地方」，标题右侧那片空白点不动
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private var detailText: String {
        String(format: L("%@ · 加入于 %@"), file.sizeText,
               AIMessageTime.string(from: file.createdAt))
    }

    /// 扩展名角标（固定 34×34，两种状态都不变尺寸 —— 同 `DocumentRow.badge`）
    private var badge: some View {
        Text(file.fileExtension.isEmpty ? "?" : file.fileExtension)
            .font(MacTheme.ui(10, weight: .semibold))
            .foregroundStyle(MacTheme.meta)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(0.06))
            )
    }
}
