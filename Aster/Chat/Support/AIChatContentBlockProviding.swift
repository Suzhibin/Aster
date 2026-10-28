//
//  AIChatContentBlockProviding.swift
//  AIModule
//
//  「这一行的内容块是哪个视图」—— 长按只在内容块上生效，行内留白不响应。
//
//  🔴 这是一个 **协议**，不是基类：工程里 6 个 cell 仍然全部是 `UITableViewCell`
//  的直接子类，**一条 cell 继承链都没有**（2026-09-17 决策，见当日日志）。
//
//  为什么这里必须是协议而不是 extension（像 `UITableViewCell+FocusFlash` 那样）：
//  6 个 cell 的内容块视图**各不相同**，必须由 cell 自己回答。extension 无法表达
//  「每个子类给不同答案」；写 `switch cell { case let c as AIUserTextCell: c.bubble ... }`
//  等于把每个 cell 的内部结构抄进宿主 VC，新增 cell 类型时编译器不会提醒。
//
//  为什么需要它：长按手势挂在 `tableView` 上，而命中判定用的是
//  `indexPathForRow(at:)` = **整行矩形**，不是「点到了哪个视图」。
//  气泡宽度是文案撑出来的（约束是「≤ 80% 屏宽」的 `lessThanOrEqualTo`），
//  所以气泡旁边那圈留白宽度不定，却全部落在这行的矩形里 → 长按留白也弹操作卡。
//
//  ⛔ 别改成基类：基类能提供的公共层只有 `contentView`（= 满行 = 命中范围一点没变，
//  白改）；而且 `AIChatSearchCell`（在另一个 VC、`selectionStyle = .default`）会被迫
//  出链，否则白带一条长按。
//
//  ⚠️ 判定用「点转到内容块坐标系后是否落在 `bounds` 内」，**不手算 frame**：
//  气泡的 frame 随文案变，而 `convert(_:to:)` 跟着实际布局走。
//
//  ⚠️ 只有 2 个文本 cell 有 `bubble`，所以别把这件事写成「只认气泡」——
//  文件行认卡片、图片行认图、视频行认封面，统一抽象才是「内容块」。
//
//  🔴 conformance **必须写在各自 cell 文件内**（就是本文件末尾没有它们的原因）：
//  内容块都是 `private let`，而 `private` 是**文件级**作用域 —— 集中写在这里会报
//  `'bubble' is inaccessible due to 'private' protection level`（本次先踩了这个坑）。
//  放宽成 `internal` 也能编过，但那会把 6 个纯内部视图暴露给整个模块，且与
//  「只在本文件用的继续留 private」的约定相悖。
//

import UIKit

/// 由 cell 自己回答「这一行的内容块是哪个视图」。
///
/// 采用者见各自 cell 文件末尾：`bubble`（两个文本 cell）/ `card`（文件）/
/// `pictureView`（用户图）/ `imageView2`（助手图）/ `coverView`（视频）。
protocol AIChatContentBlockProviding: AnyObject {

    /// 「这一行的内容块」：长按照到这里才算命中。
    ///
    /// 返回 `nil` = 整行都算命中（宽松降级，给将来不认识的 cell 用）。
    var contentBlockView: UIView? { get }
}
