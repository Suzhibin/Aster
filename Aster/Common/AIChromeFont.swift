//
//  AIChromeFont.swift
//  Aster
//
//  iOS 侧「界面 chrome」的字号助手 —— 与 Mac 侧 `MacTheme.ui(...)` 一一对应。
//
//  ## 它解决什么（2026-10-15 用户原话的 iOS 半边）
//  「Mac 端调整字体大小，要把**本地的文本** 比如菜单、设置内的文字大小**同时改变**」。
//  Mac 侧已全部接上（`MacTheme.ui` + `AIFontSizeStore.uiScale`，见 `MacTheme.swift`
//  「界面 chrome 的字号缩放」段）；iOS 侧此前**一处都没接** —— 菜单页 / 设置页 / 输入栏
//  的字号全是视图层写死的常量（`.systemFont(ofSize: 14)` 等），用户在设置里调档位，
//  只有会话正文（`AITypography.bodyFontSize`）跟着变，观感就是「这个开关只对一半生效」。
//  本文件把 iOS 半边补齐：⛔ 新写 iOS chrome 字号**别再写死数字**，一律走这里。
//
//  ## 口径：与 Mac 同一个 uiScale，但**基准各按各的**（iOS/Mac 字号不可能全等）
//  - 缩放系数 `uiScale = (16 + offset) / 16`（0.875 / 1 / 1.125 / 1.25）定义在共享层
//    `AIFontSizeStore.uiScale`，两端同源 ⇒ 调档位两端同步。
//  - 但**绝对值两端不同且刻意不同**：Mac chrome 基准是 12/13/14/16（大窗口、稀疏布局），
//    iOS chrome 基准是 UIKit 体系的 14/15/16/17（小屏、紧凑布局）。传进来的 `size`
//    就是各端自己的基准值，本文件只负责乘 `uiScale`。
//  - ⚠️ **会话正文不要走这里**：正文走 `AITypography.body`（加减口径，精确落在
//    14/16/18/20）；chrome 走这里的比例口径 —— 分工写在 `AIFontSizeScale.swift`
//    的文件注释里（「chrome 要保住层级，正文要精确落在 14/16/18/20」）。
//
//  ## 🔴 刷新是调用方的事（UIKit 不吃 Observation）
//  Mac 侧 SwiftUI 读一次 `AIFontSizeRevision` 就自动重算；iOS 侧 UIKit 没有这套机制，
//  档位变化只发 `AIFontSizeStore.didChange` 通知。所以每个接进来的页面都要：
//  1. 页级 `applyFonts()`：把所有字号点**重新设一遍**（lazy 控件的 font 是构造时
//     一次性快照，⛔ 光 reloadData 不刷 tableView 之外的 label）；
//  2. `viewWillAppear` 里调一次（抄 `AIMenuViewController.applyLocalizedText()` 的
//     「懒加载控件每次展示重读」模式）；
//  3. 页级 `addObserver` 收 `didChange` 实时刷（页面还活着时改档位要立刻变）；
//  4. `UITableView` 另加 `reloadData()`（cell 是复用的，配置在 cellForRow 里）。
//
//  ## ⚠️ 图标尺寸不缩放
//  与 Mac 侧同一取舍（用户点名的是「文本」；图标多与写死 frame 配对，一起放容易溢出）。
//  ⛔ 别拿这里的返回值去推图标 frame。
//

import UIKit
import AICore

enum AIChromeFont {

    /// 当前 chrome 缩放系数（0.875 / 1 / 1.125 / 1.25）。来源 `AIFontSizeStore.uiScale`。
    ///
    /// ⚠️ 必须是计算属性，⛔ 不许缓存 —— 与 MacTheme.uiScale 同款理由：
    /// 改档位后要能读到新值。
    static var uiScale: CGFloat { AIFontSizeStore.uiScale }

    /// chrome 文本字体：按 `uiScale` 缩放后的系统字体。替代 `.systemFont(ofSize: 14)`。
    static func ui(_ size: CGFloat) -> UIFont {
        UIFont.systemFont(ofSize: max(size * uiScale, 1))
    }

    /// chrome 文本字体（带字重）。替代 `.systemFont(ofSize: 16, weight: .medium)`。
    static func ui(_ size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: max(size * uiScale, 1), weight: weight)
    }

    /// chrome 等宽字体（API Key / 模型 ID 这类要逐字符对齐的字段）。
    /// 替代 `.monospacedSystemFont(ofSize: 15, weight: .regular)`。
    static func uiMonospaced(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: max(size * uiScale, 1), weight: weight)
    }

    /// chrome 文本字体（按 Dynamic Type 文本样式取基准，再乘 `uiScale`）。
    /// 替代 `UIFont.preferredFont(forTextStyle: .body)`。
    ///
    /// 两级缩放是刻意的：系统「文字大小」（Dynamic Type）管可访问性，
    /// App 内字号档位（`uiScale`）管偏好，各乘各的。
    static func ui(_ style: UIFont.TextStyle) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        return base.withSize(max(base.pointSize * uiScale, 1))
    }
}
