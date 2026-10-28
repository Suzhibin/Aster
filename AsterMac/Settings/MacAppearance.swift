//
//  MacAppearance.swift
//  AsterMac
//
//  外观偏好的实现：三档偏好（浅色 / 深色 / 跟随系统）+ 本地持久化 + 应用。
//  📌 2026-10-14 起入口从**账号菜单的「外观设置 ▸」子菜单**搬到**设置窗的「外观」页**
//     （用户要求「可以把外边的 语言设置、外观设置 都移动设置里」）。
//     ⇒ 本文件**只改了入口，机制一行没动**：仍是「静态存取点 + UserDefaults + `NSApp.appearance`」，
//       只是读它的位置从 「账号菜单 → 外观设置」`makeAppearanceItem()` 换成了
//       `MacSettingsView` 的 `MacAppearanceSettingsView`。
//
//  ## 为什么单独一个文件、且不进共享层
//  它是 Mac 端**唯一**一个「App 级外观偏好」，与 iOS 无关（iOS 走系统外观，没有这个入口），
//  所以 ⛔ 不进 `AsterCore` —— 那是两个 App 共用的业务层，塞一个 Mac 专有的 UI 偏好进去，
//  只会让 iOS 侧多一个永远不读的键。
//
//  ## 🔴 为什么应用走 `NSApp.appearance` 而不是 `.preferredColorScheme`
//  本 App 有**多个独立窗口**：主窗口、设置窗（独立 `Settings` 场景）、媒体预览窗、网页面板…
//  `.preferredColorScheme` 是**视图修饰符** ⇒ 得挂在每一个窗口的根视图上，必然漏一个
//  （最典型的就是设置窗：它是另一个 Scene，拿不到主窗口的 environment）。
//  `NSApp.appearance` 一刀切所有窗口 + 菜单栏，是唯一不漏的做法。
//  附带的好处：SwiftUI 的 `\.colorScheme` 也跟着变 ⇒ `MacTheme` 里那些明暗分档自动跟随。
//
//  ⚠️ 代价：**离屏渲染台照不到它** —— `render_mac_ui.sh` 里没有真实的 `NSApp` 窗口体系，
//     它只能验「设置页那一行**勾在哪一档**」（那是视图自己的 `@State` 镜像）；
//     三档**实际配色**只能在真窗口里看（`preview` / `root` 档，或者自己跑一次）。
//
//  ## 为什么不用 `@Observable`
//  `render_mac_ui.sh` **不能展开宏**（每个 `@Observable` 都得手工补一份），
//  而这个偏好本身是「改完立刻全局生效」的一次性副作用，没有需要 SwiftUI 观察的状态：
//  入口那一行自己的选中态由视图层的 `@State` 镜像（`MacAppearanceSettingsView`）即可。
//  ⇒ 做成**静态存取点 + UserDefaults**，渲染台零补丁。
//

import AppKit
// 🔴 档位文案要走 `L()`（2026-10-13 接的本地化）；`SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY`
//    在本工程是开的 ⇒ 用谁就得显式 import 谁。
import AICore

/// 外观三档。`rawValue` 直接落 `UserDefaults`。
/// ⚠️ ⛔ 别改已有 case 的 `rawValue` —— 那就是存档格式，改了等于把用户选过的偏好丢掉。
enum MacAppearance: String, CaseIterable, Identifiable {
    /// 跟随系统（默认）—— 对应 `NSApp.appearance = nil`
    case system
    case light
    case dark

    var id: String { rawValue }

    /// 设置窗「外观」页里那一行的文案。
    /// ⚠️ 走 `L()`（与 iOS 那份同一个 key，英文只译一条 —— 见 `AILocalization.en`）。
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .light:  return L("浅色")
        case .dark:   return L("深色")
        }
    }
}

/// 「外观」偏好的**唯一存取点**（读 / 写 / 应用）。
enum MacAppearanceStore {

    /// ⚠️ 带命名空间前缀：`UserDefaults` 是与系统及其它版本共用的命名空间，
    ///    裸 `"appearance"` 这种键名迟早撞上。
    private static let key = "AsterMac.appearance"

    /// 当前偏好。
    ///
    /// ⛔ 别在视图里直接 `UserDefaults.string(forKey:)` —— 那样默认值（`.system`）
    ///    会在各处散成好几份，哪天改默认值一定漏掉某处。
    static var current: MacAppearance {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let value = MacAppearance(rawValue: raw) else { return .system }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            apply(newValue)
        }
    }

    /// 把偏好应用到 App。见文件头「为什么不是 `.preferredColorScheme`」。
    ///
    /// ⚠️ `NSApplication.shared` 会**顺手创建** app 实例 —— 这是刻意的：
    ///    调用它的两条路径（启动恢复 / 用户点菜单）本来就都在 GUI 进程里。
    static func apply(_ appearance: MacAppearance) {
        let app = NSApplication.shared
        switch appearance {
        case .system: app.appearance = nil
        case .light:  app.appearance = NSAppearance(named: .aqua)
        case .dark:   app.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// 启动时套用一次。
    ///
    /// 🔴 **必须在窗口出现之前调**（`AsterMacApp.init` 里）：晚了会先按系统外观画一帧、
    ///    再跳成用户选的那档（视觉上就是「启动闪一下」）。
    static func restoreAtLaunch() { apply(current) }
}
