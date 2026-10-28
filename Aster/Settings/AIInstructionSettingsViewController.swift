//
//  AIInstructionSettingsViewController.swift
//  Aster
//
//  「指令」页（iOS，2026-10-20 新建）—— 系统提示词（system prompt）的编辑入口。
//
//  ## 页面层级里的位置
//      设置页（`AISettingsViewController`）组2「功能」
//            ↓
//      **本页**（被 push；左上角交系统返回键）
//  ⚠️ 本页是导航链的终点（没有子页）。
//
//  ## 它管什么
//  写 `AIGenerationSettings.systemPrompt` —— 每轮请求最前面的 `role: system` 消息
//  （注入点见 `AIChatManager.withSystemPrompt`）。空指令 = 不发，请求体与上线前一致。
//
//  ## 🔴 为什么「自动保存」而不是「完成按钮」
//  指令是**低频长文**（写一段话，不是拨个开关）：每次击键直接写存取点
//  （UserDefaults，2000 字以内一次 set 的开销可忽略），没有「忘了保存」这个失败模式。
//  导航栏右侧那颗「已自动保存」是**常显的状态说明**（不可点），不是按钮 ——
//  有了它用户才知道不用去找保存入口。
//
//  ## 🔴 击键时⛔ 不许 reloadData
//  reloadData 会重建 cell ⇒ 编辑器里的 `UITextView` 被换掉、**焦点丢失**（键盘收起）。
//  所以占位符 / 字数 / 编辑器内容全部走**直接持有的 weak 引用**更新，
//  只有 preset 点击那种「内容整体替换」也走同一套引用（不走 reload）。
//
//  ## 🔴 开关 / 勾那套教训的同类应用：控件挂 contentView
//  本页没有开关，但两条同类纪律仍在：① 预设 chips 是**恒存在**的按钮
//  （⛔ 别按「有几个 preset」增删子视图）；② cell 复用后靠**子类令牌**认控件
//  （`AIInstructionEditorCell` / `AIInstructionChipsCell`，⛔ 不用 tag —— 数字撞车是静默 bug）。
//
//  ## 🔴 分组表写在计算属性里（⛔ 不是 static let）
//  与设置页同一条铁律：切语言后重建界面要拿到新文案。
//

import UIKit
import SnapKit
import AICore

final class AIInstructionSettingsViewController: UIViewController {

    // MARK: - 指令的读写口（2026-10-21 起可注入）
    //
    // 🔴 为什么要注入：**项目级指令（L3）复用这一页** —— 编辑器的行为
    //    （击键即存 / 字数上限 / 预设 chips / 不许 reloadData）与全局那份逐字相同，
    //    只有「读哪个值、写到哪里」不一样。
    //    ⛔ 别为项目级另写一页：那一页要重新踩一遍「焦点丢失」「预设替换」这些坑。
    //
    // ⚠️ 必须在**呈现之前**设置（`editorCell` 在 `viewDidLoad` 那一拍就读了 `currentInstruction`）。

    /// 指令读口；`nil` ⇒ 全局 `AIGenerationSettings.systemPrompt`
    var instructionProvider: (() -> String)?

    /// 指令写口；`nil` ⇒ 写全局 `AIGenerationSettings.systemPrompt`
    var onInstructionChange: ((String) -> Void)?

    /// 页面标题覆盖（项目级传「项目指令」）；`nil` ⇒ 「指令」
    var screenTitle: String?

    /// 是不是**项目级**这一份（`instructionProvider` 非 nil 就是）。
    ///
    /// 🔴 2026-10-27 只给项目级加「与全局指令叠加使用」那句说明：全局页是**最底层**，
    ///    对它说「和全局叠加」等于自指（用户会以为还有更底一层）。判据也因此只能
    ///    看读口注没注入 —— ⛔ 别改用 `screenTitle != nil`（那只是文案，谁都能设）。
    private var isProjectScoped: Bool { instructionProvider != nil }

    /// 当前指令的**唯一读口**（⛔ 别在别处直读存取点）
    private var currentInstruction: String {
        instructionProvider?() ?? AIGenerationSettings.systemPrompt
    }

    /// 当前指令的**唯一写口**
    private func saveInstruction(_ text: String) {
        if let onInstructionChange {
            onInstructionChange(text)
        } else {
            AIGenerationSettings.systemPrompt = text
        }
    }

    // MARK: - 行

    /// 本页三段。⚠️ 顺序就是屏上顺序。
    private enum Section: Int, CaseIterable {
        /// 编辑器（一行高的 cell，里面一颗 UITextView）
        case editor
        /// 快捷预设（横排 chips）
        case presets
        /// 底部操作行（字数 + 恢复默认）
        case footer

        var header: String? {
            switch self {
            case .editor:   return nil
            case .presets:  return L("快捷预设")
            case .footer:   return nil
            }
        }
    }

    /// 指令字数上限。🔴 2026-10-27 起**不在本页定义**：真值在
    /// `AIGenerationSettings.instructionMaxLength`（Mac 两处也读它）。
    /// ⛔ 别在这里写回字面量 —— 那正是「一处改完、另一处静默不一致」的来路。
    private static let maxLength = AIGenerationSettings.instructionMaxLength

    private static let editorCellID = "AIInstructionEditorCell"
    private static let chipsCellID = "AIInstructionChipsCell"
    private static let footerCellID = "AIInstructionFooterCell"

    /// chips / 恢复默认两颗按钮的 UIAction 标识（复用去重用，见 `chipsCell` 里那条注释）。
    /// ⚠️ 类型是 `UIAction.Identifier`（结构体）—— ⛔ 不是 String，直接传字面量编不过。
    private static let chipActionID = UIAction.Identifier("ai.instruction.chip")
    private static let resetActionID = UIAction.Identifier("ai.instruction.reset")

    // MARK: 直接持有的控件引用（⛔ 别改成 reloadData 刷新，见文件头）

    private weak var editor: UITextView?
    private weak var placeholderLabel: UILabel?
    private weak var countLabel: UILabel?

    // MARK: - UI

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.backgroundColor = .systemGroupedBackground
        tv.dataSource = self
        tv.delegate = self
        tv.rowHeight = UITableView.automaticDimension
        tv.estimatedRowHeight = 120
        tv.keyboardDismissMode = .interactive
        // 🔴 两个自定义 cell 类**必须注册**：`dequeueReusableCell(withIdentifier:for:)`
        //    对没注册的标识符是**崩溃**（不是返回 nil），`as?` 兜不到。
        tv.register(AIInstructionEditorCell.self, forCellReuseIdentifier: Self.editorCellID)
        tv.register(AIInstructionChipsCell.self, forCellReuseIdentifier: Self.chipsCellID)
        tv.register(UITableViewCell.self, forCellReuseIdentifier: Self.footerCellID)
        return tv
    }()

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        title = screenTitle ?? L("指令")
        view.backgroundColor = .systemGroupedBackground
        // 「已自动保存」状态说明（常显、不可点）。
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L("已自动保存"),
            style: .plain, target: nil, action: nil)
        navigationItem.rightBarButtonItem?.tintColor = .secondaryLabel
        navigationItem.rightBarButtonItem?.isEnabled = false
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in make.edges.equalToSuperview() }
    }

    // MARK: - 直接刷新（不走 reloadData）

    /// 把三段 UI（占位符 / 字数 / 编辑器内容）刷成与当前存取点一致。
    private func refreshDirect(replacingText: String? = nil) {
        if let replacingText {
            editor?.text = replacingText
            saveInstruction(replacingText)
        }
        let text = editor?.text ?? currentInstruction
        placeholderLabel?.alpha = text.isEmpty ? 1 : 0
        countLabel?.text = "\(text.count) / \(Self.maxLength)"
    }
}

// MARK: - 列表数据源

extension AIInstructionSettingsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch Section(rawValue: indexPath.section) {
        case .editor: return 200
        // 其余两段交给自动高度（chips 一行、底部操作行一行）。
        default: return UITableView.automaticDimension
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section) {
        case .editor:
            return editorCell(in: tableView, for: indexPath)
        case .presets:
            return chipsCell(in: tableView, for: indexPath)
        case .footer, .none:
            return footerCell(in: tableView, for: indexPath)
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.header
    }

    /// 「与全局指令叠加使用」—— 挂在**编辑器段的下方**（section footer）。
    ///
    /// ## 🔴 为什么用 section footer 而不是多加一个 cell
    /// ① footer 是系统原生位置，零新增 cell 类型 ⇒ 不用管注册标识符、不用管
    ///    「复用后先摘干净子视图」，也不会动 `heightForRowAt` 那套（本页 editor 段是写死的 200）。
    /// ② 文案随语言变：⚠️ 必须写成**计算属性/函数**里现算的 `L()`（与设置页同一条铁律），
    ///    ⛔ 别提到 `static let` 上去（切语言后永远是旧语言）。
    /// ## 🔴 只在项目级出现
    /// 全局页自己就是「全局」⇒ 对它说「与全局叠加」是自指。判据见 `isProjectScoped`。
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard isProjectScoped, Section(rawValue: section) == .editor else { return nil }
        // ⚠️ 句子刻意写全：只说「叠加使用」用户仍可能理解成「两个开关」，
        //    这里点明「全局仍然生效、本页只追加」，与注入侧
        //    `AIChatManager.withSystemPrompt` 的 [global, project, memory] 一致。
        return L("与全局指令叠加使用：全局那份仍然生效，这里只追加本项目的规则。")
    }
}

// MARK: - 编辑器段

/// 编辑器行的**身份令牌**（cell 复用后靠它认出来，⛔ 不用 tag）。
private final class AIInstructionEditorCell: UITableViewCell {
    let textView = UITextView()
    let placeholder = UILabel()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        contentView.addSubview(textView)
        contentView.addSubview(placeholder)
        textView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
            make.height.greaterThanOrEqualTo(160)
        }
        placeholder.snp.makeConstraints { make in
            make.top.equalTo(textView).offset(8)
            make.leading.equalTo(textView).offset(5)
            make.trailing.lessThanOrEqualTo(textView).offset(-5)
        }
        // 🔴 字号走 `AIChromeFont`（2026-10-22 接字号档位）：保留 Dynamic Type 文本样式，
        //    再乘档位系数（见 `AIChromeFont.ui(_ style:)` 的文件注释）。
        textView.font = AIChromeFont.ui(.body)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        placeholder.font = AIChromeFont.ui(.body)
        placeholder.textColor = .tertiaryLabel
        placeholder.numberOfLines = 0
        placeholder.text = L("例如：你是一名严谨的技术顾问。回答先给结论，再给理由；不确定时直说，不要编造。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension AIInstructionSettingsViewController {

    private func editorCell(in tableView: UITableView, for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.editorCellID, for: indexPath)
            as? AIInstructionEditorCell
            ?? AIInstructionEditorCell(style: .default, reuseIdentifier: Self.editorCellID)
        cell.textView.delegate = self
        cell.textView.text = currentInstruction
        cell.placeholder.alpha = cell.textView.text.isEmpty ? 1 : 0
        cell.selectionStyle = .none
        cell.backgroundColor = .secondarySystemGroupedBackground
        // 存引用（⛔ 别 reloadData 刷新，见文件头）
        editor = cell.textView
        placeholderLabel = cell.placeholder
        return cell
    }
}

// MARK: - 预设段

/// 预设 chips 行的**身份令牌**。
private final class AIInstructionChipsCell: UITableViewCell {
    let scrollView = UIScrollView()
    let stack = UIStackView()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        contentView.addSubview(scrollView)
        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        }
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        scrollView.addSubview(stack)
        stack.snp.makeConstraints { make in
            make.edges.equalTo(scrollView.contentLayoutGuide)
            make.height.equalTo(scrollView.frameLayoutGuide)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension AIInstructionSettingsViewController {

    private func chipsCell(in tableView: UITableView, for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.chipsCellID, for: indexPath)
            as? AIInstructionChipsCell
            ?? AIInstructionChipsCell(style: .default, reuseIdentifier: Self.chipsCellID)
        // 🔴 chips **恒存在、只换 configuration / target**：⛔ 别按 preset 个数增删子视图
        //    （增删时机与 cell 复用纠缠不清，会漏按钮 —— 与开关「恒占位只翻 alpha」同一条纪律）。
        let titles = AIInstructionPreset.allCases.map(\.title) + [L("清空")]
        while cell.stack.arrangedSubviews.count < titles.count {
            let button = UIButton(type: .system)
            cell.stack.addArrangedSubview(button)
        }
        // 多出来的（将来 preset 变少）藏掉而不是摘掉 —— 保持「恒存在」口径。
        for (index, view) in cell.stack.arrangedSubviews.enumerated() {
            guard let button = view as? UIButton else { continue }
            if index < titles.count {
                button.alpha = 1
                // 🔴 走 `UIButton.Configuration`（iOS 15+）：⛔ 别用 setTitle +
                //    contentEdgeInsets —— 后者在 iOS 15 已弃用（用 configuration 时被忽略），
                //    会平白多三条 deprecation warning。
                var config = UIButton.Configuration.plain()
                config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
                config.background.backgroundColor = index == titles.count - 1
                    ? .secondarySystemFill
                    : .systemGray5
                config.background.cornerRadius = 8
                config.attributedTitle = AttributedString(
                    titles[index],
                    attributes: AttributeContainer([
                        .font: AIChromeFont.ui(.footnote),
                        .foregroundColor: UIColor.link
                    ]))
                button.configuration = config
                // 🔴 UIAction 走 **identifier + removeAction**：⛔ 别用裸 addAction ——
                //    cell 复用时同一个 button 对象还在，裸加会把旧 handler 叠上
                //    （点一下换两次文本，且不报错）。⛔ 也别用 addTarget(self) ——
                //    UIControl 强持有 target，button 比 VC 活得久就是隐式 retain cycle
                //    （`AINotifySwitchView` 文件头同款教训）。
                button.removeAction(identifiedBy: Self.chipActionID, for: .touchUpInside)
                button.addAction(UIAction(identifier: Self.chipActionID) { [weak self] _ in
                    self?.presetTapped(index: index)
                }, for: .touchUpInside)
            } else {
                button.alpha = 0
            }
        }
        cell.selectionStyle = .none
        cell.backgroundColor = .secondarySystemGroupedBackground
        return cell
    }

    /// 点一颗 chip：preset ⇒ 写入它的正文；最后一颗（清空）⇒ 空串。
    private func presetTapped(index: Int) {
        let presets = AIInstructionPreset.allCases
        let text: String
        if index < presets.count {
            text = presets[index].body
        } else {
            text = ""
        }
        // 走 refreshDirect 的替换分支：编辑器 / 占位符 / 字数 / 存取点一次刷齐
        //（⛔ 不 reloadData —— 会把键盘收掉）。
        refreshDirect(replacingText: text)
    }
}

// MARK: - 底部操作段

extension AIInstructionSettingsViewController {

    private func footerCell(in tableView: UITableView, for indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.footerCellID, for: indexPath)
        // 复用的 cell 先摘干净（⛔ 别让上一行的 target 漏到下一行）。
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }
        let count = UILabel()
        count.font = AIChromeFont.ui(.footnote)
        count.textColor = .tertiaryLabel
        let reset = UIButton(type: .system)
        // 同 chips：走 configuration（⛔ 别 setTitle + contentEdgeInsets —— iOS 15 弃用）。
        var resetConfig = UIButton.Configuration.plain()
        resetConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 0)
        resetConfig.attributedTitle = AttributedString(
            L("恢复默认"),
            attributes: AttributeContainer([
                .font: AIChromeFont.ui(.body),
                .foregroundColor: UIColor.systemRed
            ]))
        reset.configuration = resetConfig
        // 同 chips：identifier + removeAction 防复用叠加（footer cell 整行重建，
        // 但 button 对象在 stack 复用路径下仍可能活着 —— 统一按会复用来写）。
        reset.removeAction(identifiedBy: Self.resetActionID, for: .touchUpInside)
        reset.addAction(UIAction(identifier: Self.resetActionID) { [weak self] _ in
            // 清空指令 = 恢复默认态（存取点侧 resetToDefaults 会顺带把采样参数也复位，
            // 这里只动指令本身 —— 「恢复默认」那颗按钮在生成参数页管全部）。
            self?.refreshDirect(replacingText: "")
        }, for: .touchUpInside)
        let row = UIStackView(arrangedSubviews: [count, UIView(), reset])
        row.axis = .horizontal
        row.alignment = .center
        cell.contentView.addSubview(row)
        row.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 14))
        }
        cell.selectionStyle = .none
        cell.backgroundColor = .secondarySystemGroupedBackground
        countLabel = count
        refreshDirect()
        return cell
    }
}

// MARK: - 编辑器输入

extension AIInstructionSettingsViewController: UITextViewDelegate {

    func textViewDidChange(_ textView: UITextView) {
        // 击键即存（⛔ 不 reloadData，见文件头）；占位符与字数走直接引用刷。
        saveInstruction(textView.text)
        placeholderLabel?.alpha = textView.text.isEmpty ? 1 : 0
        countLabel?.text = "\(textView.text.count) / \(Self.maxLength)"
    }

    func textView(_ textView: UITextView,
                  shouldChangeTextIn range: NSRange,
                  replacementText text: String) -> Bool {
        // 字数上限：粘贴超长文本时直接拒掉（比「粘进来了再截」体验好 ——
        // 后者会把光标跳到末尾，用户没处说理）。
        let projected = (textView.text as NSString).replacingCharacters(in: range, with: text)
        return projected.count <= Self.maxLength
    }
}
