import UIKit

/// 「多选删除」选择模式下**需要让出触摸**的 cell。
///
/// ## 为什么需要它
/// 选择模式的勾选由表格的编辑态机制驱动（`allowsMultipleSelectionDuringEditing`）：
/// 轻点一行 → 系统自己勾上/取消。但**自带点击手势或 `UIControl` 的内容块会把那一拍吃掉** ——
/// 触摸被它们接走，表格收不到，于是「图片 / 视频那几行怎么点都勾不上」。
/// 其余 cell 的内容块都是纯展示视图（`UILabel` / `UITextView` 未选中态不参与命中），不受影响。
///
/// ## 为什么是协议而不是基类
/// 与 `AIChatContentBlockProviding` 同一套理由（2026-09-17 定案）：宿主在
/// `willDisplay` 里统一按 `as?` 问一句即可，六种 cell 各自答一次；
/// 真去造一个公共基类，得把所有 cell 的继承链一起改，收益却只是省两行 `as?`。
///
/// ⚠️ 实现必须留在各自 cell 文件内：要关掉的手势 / 按钮都是 `private`，
/// 而 Swift 的 `private` 是**文件级**作用域。
protocol AIChatSelectionTouchYielding: AnyObject {
    /// 进出选择模式时调用（幂等：同一状态反复调没有副作用）
    func setSelectionMode(_ on: Bool)
}
