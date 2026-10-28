//
//  ChatSelectionBar.swift
//  AsterMac
//
//  「多选删除」选择模式下，**顶替输入栏**的底部操作条（2026-09-29 加）。
//
//  ## 结构
//  ```
//  已选择 3 条                          [ 取消 ]  [ 删除(3) ]
//  ```
//
//  ## 为什么动作全在底部（与 iOS 同一个理由）
//  删除**不可恢复**，触发它的手指（这里是光标）必须够得着。iOS 那边当年就是从导航栏右上角
//  挪到这条栏里的 —— 那边是「单手最难碰的位置」，这边是「窗口最远的一角」+ 一条
//  用户已经习惯「底部 = 我做的事情」的肌肉记忆。⇒ 进选择模式时**输入栏整条让位给这一条**，
//  位置与输入栏重合（`ChatDetailView` 的 `safeAreaInset` 里二选一）。
//
//  ## 与输入栏的关系
//  两者是**互斥**的：一边勾消息一边发新消息没有任何意义（iOS 同样把输入栏整条隐藏）。
//  ⚠️ 因此切进 / 切出时底部这一块的**高度会变**（选择栏是定高，输入栏随引用条 / 附件条长高），
//     列表的内边距跟着变 —— 这是可接受的：用户此刻在挑消息，不在看最后一条。
//
//  ## 报数为什么在左边
//  与 iOS 那条同款：「已选择 N 条」是**状态**，动作在右。一句话读完就知道自己勾了几条，
//  不用去数屏幕上的圈。
//

import SwiftUI
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

struct ChatSelectionBar: View {

    /// 当前勾中的条数（`ChatModel.selectedCount`）
    let count: Int
    /// 「取消」= 原样退出选择模式，一条都不动
    let onCancel: () -> Void
    /// 「删除(N)」= 交给上层弹二次确认（删不可恢复，这一步不能省）
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(countText)
                .font(MacTheme.ui(MacTheme.selectionBarCountFontSize))
                // 一条都没勾时把颜色降下去：这句是**提示**，不是报数
                .foregroundStyle(count > 0 ? Color.primary : MacTheme.meta)
                // 报数在勾选之间变化（1 位 → 2 位）时后面两颗按钮会跟着挪一下 ——
                // 用等宽数字把宽度抖动压到最小。
                .monospacedDigit()

            Spacer(minLength: 12)

            cancelButton
            deleteButton
        }
        .padding(.horizontal, MacTheme.composerMarginH)
        .padding(.vertical, MacTheme.selectionBarPaddingV)
        // 与输入栏刷同一个底色（那块「面」的语义没变，只是内容换了）——
        // ⛔ 别在这儿加分隔线：输入栏当初就刻意去掉了（见 `MacInputBar` 文件头）。
        .background(MacTheme.pageBackground)
    }

    /// 「取消」：原样退出，一条都不动。
    ///
    /// Esc 退出的落点。⚠️ 用 `.cancelAction` 而不是在 `ChatDetailView` 上挂 `onExitCommand`：
    /// 那个要求键盘焦点正好落在那一层里，而这里按钮就在树里、由 SwiftUI 全窗口派发，可靠得多。
    private var cancelButton: some View {
        Button(action: onCancel) {
            Text(L("取消"))
                .font(MacTheme.ui(MacTheme.selectionBarButtonFontSize))
                .foregroundStyle(MacTheme.selectionCancelText)
                .padding(.horizontal, MacTheme.selectionBarButtonPaddingH)
                .padding(.vertical, MacTheme.selectionBarButtonPaddingV)
                .background(
                    RoundedRectangle(cornerRadius: MacTheme.selectionBarButtonRadius)
                        .fill(MacTheme.selectionCancelBackground)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.cancelAction)
    }

    /// 「删除(N)」：交给上层弹二次确认（删不可恢复，这一步不能省）。
    ///
    /// 🔴 **自绘底块而不是 `.borderedProminent`**（2026-09-29 改）：系统按钮在离屏渲染里
    ///    只会被画成「黄条 + ⊘」（与 `Menu` / `TextField` 同一个盲区）—— 而这两颗按钮正是
    ///    「用户按下去之前的最后一眼」，验收图上必须是真长出来的样子。
    ///    顺带也与 App 里其它底块（操作栏那几颗 `ActionChip`）同一套视觉语言。
    private var deleteButton: some View {
        Button(action: onDelete) {
            Text(deleteTitle)
                .font(MacTheme.ui(MacTheme.selectionBarButtonFontSize, weight: .medium))
                // 置灰时连字一起变淡：底块变灰而字还是白的会读成「可以点」
                .foregroundStyle(count > 0 ? Color.white : MacTheme.meta)
                .padding(.horizontal, MacTheme.selectionBarButtonPaddingH)
                .padding(.vertical, MacTheme.selectionBarButtonPaddingV)
                .background(
                    RoundedRectangle(cornerRadius: MacTheme.selectionBarButtonRadius)
                        .fill(count > 0 ? MacTheme.selectionDeleteTint : MacTheme.selectionDeleteDisabled)
                )
        }
        .buttonStyle(.plain)
        // 一条都没勾时置灰（点了也没东西可删）。判据与报数同源，不会出现「显示 0 条却能点」。
        .disabled(count == 0)
        // ⚠️ 刻意**不**绑 `.defaultAction`（⏎）：⏎ 是肌肉记忆级别的按键，
        //    绑在一个不可恢复的动作上是拿用户的误按换便利。
    }

    /// 报数文案。一条都没勾时给一句**怎么用**，而不是「已选择 0 条」那半句空话。
    private var countText: String {
        count > 0 ? String(format: L("已选择 %d 条"), count) : L("点消息来选择要删除的内容")
    }

    /// 带上条数 —— 用户按下去之前最后一眼能看到的数字（与确认弹窗里的数字同源）。
    private var deleteTitle: String {
        count > 0 ? String(format: L("删除(%d)"), count) : L("删除")
    }
}
