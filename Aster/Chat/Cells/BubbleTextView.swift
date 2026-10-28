//
//  BubbleTextView.swift
//  AIModule
//
//  聊天气泡正文用的 UITextView：**默认对触摸完全透明**，只有进入「选择文字」态后才接收触摸。
//
//  ## 为什么需要这一层开关
//  气泡里的 `UITextView` 一旦能接收触摸，它内部的文本手势会把单击 / 长按**全部吃掉**：
//  - 宿主「轻点气泡弹操作卡」不再触发（`didSelectRowAt` 根本收不到）；
//  - 宿主挂在 tableView 上的长按（弹操作卡）也拿不到触摸。
//  所以用命中测试开关分流：
//
//  - **未进入选择态**：`point(inside:)` 返回 false → `hitTest` 直接跳过本视图（连同子树），
//    触摸落到 cell 上，宿主行为**一字不改**（轻点 / 长按都弹操作卡）；
//  - **进入选择态**：恢复原生行为 —— 放大镜、拖动手柄、系统编辑菜单（拷贝/全选/查询）全可用。
//
//  ## 进入选择态的入口（2026-09-17 改）
//  **唯一入口是操作卡里的「选取文字」**（`AIRowAction.selectText` → 宿主 `beginTextSelection(atRow:)`）。
//  此前入口是「长按气泡正文」，但它与「长按弹操作卡」抢同一条长按手势 —— 用户实测两者冲突，
//  所以长按一律归操作卡，选字被放进卡里（竖排第一项）。本类的命中测试开关**照旧需要**：
//  进入选择态后要把触摸还给 UITextView（放大镜、拖柄、原生扩选）。
//
//  ## 选中范围 = 「你按住的那一行」，不是全选（2026-09-17 再改）
//  最初进选择态是 `selectAll(nil)`，理由是「程序化设 `selectedRange` 不弹编辑菜单」（见下）。
//  但整段全选在长回复上很糟：用户看到整屏高亮，还得拖两个手柄往里收。
//  现在按**长按气泡的位置**取「视觉行」范围 —— 手指按住哪一行就选中哪一行
//  （短消息只有一行时，效果自然等于全选，不需要特判）。
//
//  ⛔ **取行范围绝对不要自己用 `layoutManager` 算**：iOS 16+ 访问一次就 TextKit2 → TextKit1 退化
//  （项目铁律，会让长按输入框连放大镜和「粘贴」都不弹）。走 `tokenizer`：
//  `rangeEnclosingPosition(_:with: .line, inDirection:)` —— 它就是「视觉行」（气泡宽度折出来的那一行），
//  不是 `.paragraph`（整段）、也不是 `.sentence`（按标点断句）。
//
//  ## 菜单为什么要「手动弹」
//  程序化设置 `selectedRange` **不会**唤起编辑菜单（菜单由交互过程触发，不是由选区状态触发）——
//  这正是当初改用 `selectAll(nil)` 的唯一原因：它是 UIResponder 标准 action，UIKit 会顺带弹菜单。
//  现在改成先设选区、再**按系统版本主动呈现**菜单：
//  - **iOS 16+**：`UIEditMenuInteraction.presentEditMenu(with:)`
//    （delegate 传 `nil` → interaction 会向 responder 链要标准编辑项，正好是「拷贝 / 全选 / 查询」）；
//  - **iOS 14/15**：`UIMenuController.showMenu(from:rect:)`（当时唯一能主动呈现的公开 API）。
//
//  ⚠️ 呈现菜单是 **best-effort**：万一某个系统版本上没弹出来，选区与拖柄仍是原生的、照常可用，
//  用户此时双击 / 长按气泡里的文字也能唤起系统菜单 —— 功能不会「点了没反应」。
//
//  ## 与宿主手势的配合
//  宿主 `AIModuleViewController` 的 `gestureRecognizer(_:shouldReceive:)` 里显式排除了
//  本类型：未进入选择态时它本来就命中不到（exclude 是冗余保护）；进入选择态后
//  必须排除，否则原生长按「扩选」会同时弹出操作卡，两层 UI 叠在一起。
//
//  ## 🔴 唯一的例外：网址（2026-10-02）
//  未进入选择态时，**压在某条网址上**的那一拍要留给本视图（`point(inside:)` 返回 true）
//  —— 否则链接永远点不动（触摸全穿透给 cell，`UITextView` 的链接处理跑不到）。
//  判定走 `linkURL(at:)`；「点到了怎么跳」由 cell 通过 `onOpenURL` 交给宿主（本类不碰导航）。
//
//  ## 退出选择态的时机（三处都得做，漏一处就是「gate 卡住」）
//  ① 用户点了列表别处 / 滚动了列表（宿主 `endTextSelection`）；
//  ② 文本框自己 resign（`textViewDidEndEditing`，cell 作为 delegate 负责）；
//  ③ cell 被复用（`prepareForReuse`）。
//

import UIKit
import AICore

/// 「气泡正文可选中」的统一入口。两个气泡 cell（用户 / 助手）都实现它，
/// 宿主只认这个协议，不必 `as?` 到具体类型（否则加一种气泡就要改一遍宿主）。
///
/// 调用点只有两处：操作卡里的「选取文字」（`beginTextSelection`）与宿主的收尾
/// （`endTextSelection`：点别处 / 拖列表 / 换会话 / 弹操作卡前）。
protocol AIBubbleTextSelecting: AnyObject {
    /// 进入选择态，默认选中 `point` 所在的那一行。
    ///
    /// - Parameter point: 用户长按气泡的位置，**cell 坐标系**（`nil` = 没有锚点，
    ///   如气泡下方操作栏那条路径 → 退回全选整段）。
    /// - Returns: 是否成功。false = 这个 cell 没有可选正文（空占位行等），调用方应给一句提示。
    func beginTextSelection(at point: CGPoint?) -> Bool
    /// 退出选择态（未进入时安全，可反复调用）
    func endTextSelection()
}

final class BubbleTextView: UITextView {

    /// 是否已进入「选择文字」态（= 允许接收触摸）
    private(set) var isSelectionArmed = false

    /// 🔗 网址这一拍要不要留下来（默认要）。
    ///
    /// 多选删除模式下由 cell 关掉（见 `AIAssistantTextCell.setSelectionMode`）：
    /// 那个模式的语义是「点哪儿都是勾选」，此时点中网址却跳出网页页会很突兀
    /// （而且勾选那一拍会被本视图吃掉 ⇒ 压在网址上就是勾不上）。
    var isLinkTapEnabled = true

    /// iOS 16+ 手动呈现编辑菜单用的 interaction。
    /// ⚠️ **必须自己持有**：`addInteraction` 之后若不留引用，它会被立刻释放，菜单一闪就没了。
    private var editMenuInteractionRef: AnyObject?

    /// ⚠️ **本类存在的全部意义**：未进入选择态时把自己从命中测试里摘出去。
    /// 返回 false 会让 `hitTest` 直接跳过本视图**及其全部子视图**，触摸就落到下面的 cell 上。
    ///
    /// 🔴 **例外：压在某条网址上时要把这一拍留下来**（2026-10-02 用户需求
    /// 「点击网页地址 push 进入 web 页面」）。不留的话链接永远点不动 ——
    /// 触摸全穿透给 cell 了，`UITextView` 里的链接处理根本没机会跑。
    /// 判定走 `linkURL(at:)`（`UITextInput` 的字符命中，⛔ 不是 `layoutManager`，见那边说明）。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if isSelectionArmed { return super.point(inside: point, with: event) }
        guard super.point(inside: point, with: event) else { return false }
        guard isLinkTapEnabled else { return false }
        return linkURL(at: point) != nil
    }

    /// `point`（本视图坐标系）压在哪条链接上？没有则 `nil`。
    ///
    /// ## 为什么用 `characterRange(at:)`
    /// 它是 `UITextInput` 的**字符命中**接口（「这个点落在哪个字符上」，点不在字上返回 nil），
    /// 与 `closestPosition(to:)` 同属那一套。⛔ **绝不要改用 `layoutManager` 算字形矩形**：
    /// iOS 16+ 访问一次 `layoutManager` 就会把该 textView 从 TextKit2 退化回 TextKit1
    /// （本工程铁律，`lineRange(at:)` 上面那段注释就是为它写的）。
    ///
    /// ⚠️ 精确度只影响「链接可点区域的边界」（前后差半个字），可接受；
    ///    取值时把点夹进 bounds，与 `lineRange(at:)` 同一套做法（越界点会让命中跳到别处）。
    func linkURL(at point: CGPoint) -> URL? {
        guard let text = attributedText, text.length > 0 else { return nil }
        let x = min(max(point.x, 0), max(bounds.width - 1, 0))
        let y = min(max(point.y, 0), max(bounds.height - 1, 0))
        guard let range = characterRange(at: CGPoint(x: x, y: y)) else { return nil }
        let location = offset(from: beginningOfDocument, to: range.start)
        guard location >= 0, location < text.length else { return nil }
        guard let value = text.attribute(.link, at: location, effectiveRange: nil) else { return nil }
        // 属性值的包装类型跟着来源走：本页是 UIKit 直接给的 `NSURL`；
        // 若哪天富文本先经过 `AttributedString` 就会变成 `URL` ⇒ 两种都认。
        if let url = value as? URL { return url }
        if let url = value as? NSURL { return url as URL }
        if let string = value as? String { return URL(string: string) }
        return nil
    }

    /// 进入选择态、成为第一响应者，并选中 `point` 所在的那一行。
    ///
    /// - Parameter point: 本视图坐标系里的锚点（长按气泡的位置）。`nil` 或定位失败时**退回全选** ——
    ///   宁可多选也不要「什么都没选中」，那才是真的像坏了。
    /// - Returns: 是否成功。`becomeFirstResponder` 失败时**把 gate 关回去**，
    ///   否则会留下一个「状态显示已选中、触摸却依然穿透」的错位态。
    @discardableResult
    func beginSelection(at point: CGPoint?) -> Bool {
        isSelectionArmed = true
        guard becomeFirstResponder() else {
            isSelectionArmed = false
            return false
        }
        if let point = point, let range = lineRange(at: point) {
            selectedRange = range
            // 选区是程序化设的，菜单得自己补 —— 否则用户只看到高亮、找不到「拷贝」
            presentEditMenu(near: point)
        } else {
            // 兜底路径：没有锚点（或该点定位不到文字）→ 保持旧行为：全选 + 系统顺带弹菜单
            selectAll(nil)
        }
        return true
    }

    /// 退出选择态：收起菜单 + 清空选中 + 关掉 gate（触摸重新穿透给 cell）
    func endSelection() {
        guard isSelectionArmed else { return }
        isSelectionArmed = false
        dismissEditMenu()
        if isFirstResponder { resignFirstResponder() }
        selectedRange = NSRange(location: 0, length: 0)
    }

    // MARK: - 求「按住的那一行」的字符范围

    /// `point`（本视图坐标系）落在哪一行文字上，返回那一行的字符范围。
    ///
    /// 三种拿不到的情况都返回 nil（调用方会退回全选）：点完全在文字之外、空文本、
    /// tokenizer 给出的范围越界。
    private func lineRange(at point: CGPoint) -> NSRange? {
        // 先把点夹进自身 bounds：调用方给的是 cell 坐标转过来的点，可能落在正文之外
        // （例如用户按在气泡顶部的引用条上），越界的点会让 `closestPosition` 拿到意外的位置
        let x = min(max(point.x, 0), max(bounds.width - 1, 0))
        let y = min(max(point.y, 0), max(bounds.height - 1, 0))
        guard let position = closestPosition(to: CGPoint(x: x, y: y)) else { return nil }
        // `.line` = 视觉行（气泡宽度折出来的一行）。想改成「按句选」就把 .line 换成 .sentence，
        // 想在中文里按整段选就是 .paragraph —— 只改这一个字。
        guard let range = tokenizer.rangeEnclosingPosition(
            position, with: .line, inDirection: UITextDirection(rawValue: 0)
        ) else { return nil }
        let location = offset(from: beginningOfDocument, to: range.start)
        let length = offset(from: range.start, to: range.end)
        let total = (text as NSString).length
        guard location >= 0, length > 0, location + length <= total else { return nil }
        return NSRange(location: location, length: length)
    }

    // MARK: - 主动呈现编辑菜单

    /// 在 `point`（本视图坐标系）旁边呈现系统编辑菜单（拷贝 / 全选 / 查询…）。
    private func presentEditMenu(near point: CGPoint) {
        if #available(iOS 16.0, *) {
            let interaction: UIEditMenuInteraction
            if let existing = editMenuInteractionRef as? UIEditMenuInteraction {
                interaction = existing
            } else {
                // ⚠️ delegate **必须给**：`UIEditMenuInteraction` 的菜单项唯一来源就是
                // delegate 的 `menuFor:suggestedActions:`，传 nil 会弹出**空菜单**（看起来就是没反应）。
                let created = UIEditMenuInteraction(delegate: self)
                addInteraction(created)
                editMenuInteractionRef = created
                interaction = created
            }
            // sourcePoint 用「用户按的那个点」：它就在本视图坐标系里，与 API 要求一致，
            // 不用去猜 `firstRect(for:)` 到底返回哪个坐标系（那条路容易在真机上偏一屏）
            interaction.presentEditMenu(
                with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
            )
        } else {
            // iOS 14/15：UIMenuController 是当时唯一能主动呈现的公开 API（iOS 16 起弃用）
            let rect = CGRect(x: point.x, y: point.y, width: 1, height: 1)
            UIMenuController.shared.showMenu(from: self, rect: rect)
        }
    }

    /// 收起并卸掉手动加的 edit menu interaction（不卸会在 textView 上越攒越多）
    private func dismissEditMenu() {
        if #available(iOS 16.0, *), let interaction = editMenuInteractionRef as? UIEditMenuInteraction {
            interaction.dismissMenu()
            removeInteraction(interaction)
        }
        editMenuInteractionRef = nil
    }
}

// MARK: - 编辑菜单的菜单项来源（iOS 16+）

@available(iOS 16.0, *)
extension BubbleTextView: UIEditMenuInteractionDelegate {

    /// 菜单项的来源。**显式实现它**、把系统交上来的 `suggestedActions` 原样包成一个 `UIMenu`，
    /// 换来的好处是**行为确定**：头文件写明 `suggestedActions` 是「从 UIResponder 链上收集的建议项」，
    /// 对「first responder 且选区非空」的 textView 来说就是「拷贝 / 全选 / 查询」这些标准项，
    /// 与原生长按选字弹出的菜单一致。
    ///
    /// 头文件另一条路是「本方法返回 `nil` → 用系统默认菜单」，但那只在**实现了方法**时才成立；
    /// 干脆显式返回建议项，不依赖「压根不实现会怎样」这种没写明的情况。
    /// ⛔ 别在这里硬编码菜单项 —— 系统版本不同项也不同（iOS 17+ 还有「翻译」等）。
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: suggestedActions)
    }
}
