//
//  AIFontSizeScale.swift
//  AICore
//
//  对话区正文字号：**四档**（14 / 16 / 18 / 20），每档差 2pt，**第 2 档就是当前默认**（16）。
//
//  ## 为什么是 4 档、且默认落在第 2 档
//  用户 2026-10-14 原话：「就用 4 档 每档差 2 个字号，现在的字号为第二档」。
//  ⇒ 档位 = [-2, 0, +2, +4]（相对 `AITypography` 的基准 16），默认 `.standard`（偏移 0）
//    —— **不居中**是刻意的：那是用户指定的档位表，不是对称的一根轴。
//  ⚠️ `rawValue` 就是存档格式（直接落 `UserDefaults`）⇒ ⛔ 别改已有 case 的 `rawValue`。
//
//  ## 为什么这个偏好在**共享层**，而语言 / 外观各在两端
//  语言 / 外观的**应用方式**两平台根本不同（iOS 重建界面 / 遍历 window；macOS 改 `NSApp.appearance`），
//  所以那两个刻意各写一份（见 `AIAppearance.swift` / `MacAppearance.swift` 文件头）。
//  字号不一样：它只有一个落点 —— `AITypography.bodyFontSize`（共享层），
//  两端的气泡 / 输入框 / 行高量算全都从那一个值出发 ⇒ 存取点也必须在这里，
//  ⛔ 别在某一端另写一个（两端 UserDefaults 本就互相独立，同一個 store 两处各存各的，正好）。
//
//  ## 🔴 改档位要连带清两份缓存（`AIMarkdown`）
//  `AIMarkdown` 有**两个**按「源文（+ 宽度）」做键的缓存：段切分缓存里躺着**已经带旧字号的富文本**、
//  高度缓存里躺着**按旧字号量出来的行高**。不清的话改完档位，界面还是老字号（且行高与显示不符）。
//  ⇒ 清理点收在 `AIFontSizeStore.current` 的 setter 里（**唯一写入口**），两端都不用自己记得。
//
//  ## 两端怎么「让界面跟上」
//  - **Mac（SwiftUI）**：`AITypography.bodyFontSize` 会读一次 `AIFontSizeRevision`（手写 `Observable`，
//    与 `AILanguageRevision` 同一套手法，渲染台展不开宏）⇒ 凡是渲染过正文的视图自动重算，零接线。
//  - **iOS（UIKit）**：Observation 用不上 ⇒ 发 `didChange` 通知，会话页收到后
//    `recomputeAllRowHeights()` + `reloadData()`（行高是**预计算缓存**，见 `AIChatManager`）。
//
//  ## 主题
//  档位文案走 `L()`（与 `AIAppearance.title` / `AILanguage.title` 同一个口径）。

import Foundation
import Observation
import AIPlatform

// MARK: - 档位

/// 正文字号档位。`rawValue` 直接落 `UserDefaults`。
public enum AIFontSizeScale: String, CaseIterable, Identifiable {

    /// 第 1 档：14（比默认小 2）
    case small
    /// 第 2 档：16 —— **默认档**，就是改造前的字号
    case standard
    /// 第 3 档：18
    case large
    /// 第 4 档：20
    case extraLarge

    public var id: String { rawValue }

    /// 相对 `AITypography.bodyFontSizeBase`（16）的偏移量。🔴 **每档 2pt**。
    public var offset: CGFloat {
        switch self {
        case .small:      return -2
        case .standard:   return 0
        case .large:      return 2
        case .extraLarge: return 4
        }
    }

    /// 设置页里那一行的文案。
    ///
    /// ⚠️ 走 `L()`：它是界面文案，跟着 App 语言走（与 `AIAppearance.title` 同款理由）。
    /// 「小 / 默认 / 大」三个 key 与参考图上的三个标签对齐；第 4 档没有标签，取名「特大」。
    public var title: String {
        switch self {
        case .small:      return L("小")
        case .standard:   return L("默认")
        case .large:      return L("大")
        case .extraLarge: return L("特大")
        }
    }

    /// 行首图标。⚠️ **四档同一颗**：`textformat.size.*` 那一族是 SF Symbols 4（iOS 16+），
    ///    本工程 iOS target 是 15 ⇒ 在老系统上 `UIImage(systemName:)` 会返 nil（图标凭空消失）。
    ///    `textformat` 从 iOS 13 起就有，四档共用不会少图；档位靠**标题文字**区分，不靠图标。
    public var symbol: String { "textformat" }
}

// MARK: - 版本号（Mac 侧 SwiftUI 的「重算」信号）

/// 字号档位的版本号 —— 每改一次档位推一格。
///
/// ## 为什么手写 `Observable` 而不用 `@Observable` 宏
/// 与 `AILanguageRevision` **完全同一条理由**：`render_mac_ui.sh` 用 `swiftc` 直编源码，
/// 宏展不开（`@Observable` 会报 `produced malformed response`）⇒ 手写 `ObservationRegistrar`
/// + getter/setter 各调一次 `access` / `withMutation`，渲染台与真机行为一致。
///
/// ## 谁在读它
/// **只有 `AITypography.bodyFontSize` 一处**（`MacTheme.body` → `AITypography.body` 一路转到它）。
/// 于是每一个在 body 里渲染过正文的 SwiftUI 视图都登记了这条依赖，`bump()` 一下各自重算。
/// ⛔ 别在视图里直接读它换身份（`.id(...)`）—— 那是本工程明令禁止的路。
@available(iOS 17.0, macOS 14.0, *)
public final class AIFontSizeRevision: Observable {

    /// 进程内唯一一份。
    public static let shared = AIFontSizeRevision()

    private let registrar = ObservationRegistrar()
    private var storage: Int = 0

    /// 当前版本号。**读** = 登记一条「字号变了请叫我重算」的依赖。
    public var value: Int {
        get {
            registrar.access(self, keyPath: \.value)
            return storage
        }
        set {
            registrar.withMutation(of: self, keyPath: \.value) { storage = newValue }
        }
    }

    /// 推一格（`AIFontSizeStore.current` 的 setter 里调）。
    public func bump() { value &+= 1 }
}

// MARK: - 存取点

/// 「正文字号」偏好的**唯一存取点**（读 / 写 / 广播）。
public enum AIFontSizeStore {

    /// ⚠️ 带命名空间前缀：`UserDefaults` 是与系统及其它版本共用的命名空间
    ///    （与 `AIAppearanceStore` / `MacAppearanceStore` 同款理由）。
    ///    两端**键名故意相同**：这是同一个偏好，只是各存在各自的容器里。
    private static let key = "Aster.fontSizeScale"

    /// 改档位的广播。**iOS** 侧靠它刷新界面（Mac 走 Observation，见文件头）。
    public static let didChange = Notification.Name("Aster.fontSizeScaleDidChange")

    /// 进程内缓存：`AITypography.bodyFontSize` 是热路径上的（行高量算按行反复读），
    /// 每次都回 UserDefaults 太浪费。⛔ 别在视图里直接 `UserDefaults` 读它 ——
    /// 默认值会散成好几份（与 `AIAppearanceStore` 同款理由）。
    private static var cached: AIFontSizeScale?

    /// 当前档位。读不写盘；写会**连带清缓存 + 广播**（见文件头）。
    public static var current: AIFontSizeScale {
        get {
            if let cached { return cached }
            let value = UserDefaults.standard.string(forKey: key)
                .flatMap(AIFontSizeScale.init(rawValue:)) ?? .standard
            cached = value
            return value
        }
        set {
            // 点了当前档：什么都不做（不重算、不广播 = 不闪）。
            guard newValue != current else { return }
            cached = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            // 🔴 两份按源文做键的缓存里全是旧字号 ⇒ 必须先清，否则界面不换字（见文件头）。
            AIMarkdown.invalidateCaches()
            // Mac：推版本号让渲染过正文的视图各自重算。
            if #available(iOS 17.0, macOS 14.0, *) { AIFontSizeRevision.shared.bump() }
            // iOS：UIKit 不吃 Observation ⇒ 会话页收这条通知后重载。
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// **界面 chrome**（设置页 / 侧栏 / 输入栏 / 菜单…）相对当前档位的缩放系数。
    ///
    /// ## 为什么需要它（2026-10-15 用户原话）
    /// 「Mac 端调整字体大小，要把**本地的文本**比如菜单、设置内的文字大小**同时改变**」。
    /// 原先只有**会话正文**跟档位走（`AITypography.bodyFontSize`），界面 chrome 的字号
    /// 全是视图层写死的常量（`.font(.system(size: 13))`）⇒ 调档位只动会话区，
    /// 设置页 / 侧栏 / 菜单毫无反应，观感就是「这个开关只对一半界面生效」。
    ///
    /// ## 口径：比例缩放，不是加减
    /// `uiScale = (16 + offset) / 16` ⇒ 0.875 / 1 / 1.125 / 1.25。
    /// 用**比例**而不是「所有 chrome 也 ±2pt」：chrome 的字号跨 10~17pt 五档，
    /// 统一加减会把层级压扁（11pt + 4 = 15pt 与正文 20 只差 5）或拉出负值。
    ///
    /// ⚠️ **正文不要走这里**：`bodyFontSizeBase + offset` 是加减口径（用户指定的档位表），
    ///    两者故意不同源 —— chrome 要保住层级，正文要精确落在 14/16/18/20 上。
    public static var uiScale: CGFloat {
        let base = AITypography.bodyFontSizeBase
        return (base + current.offset) / base
    }
}
