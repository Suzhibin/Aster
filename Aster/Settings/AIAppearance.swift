//
//  AIAppearance.swift
//  Aster
//
//  账号菜单里「暗黑模式」那一项的实现：三档偏好（跟随系统 / 浅色 / 深色）+ 本地持久化 + 应用。
//
//  ## 为什么不复用 Mac 那份 `MacAppearance`
//  两端**应用方式根本不同**，共用一个枚举反而要多写一层 if：
//  - Mac：`NSApp.appearance = NSAppearance(named:)`（一刀切所有窗口，见那个文件头的说明）；
//  - iOS：`UIWindow.overrideUserInterfaceStyle`（**视图**级语义，没有 App 级开关）。
//  ⇒ 两份各写各的，⛔ 别为了「去重」把 iOS 这份塞进 `AsterCore` —— 那是共用业务层，
//    塞一个 iOS 专有的 UI 偏好进去只会让 Mac 侧多一个永远不读的键（与 `MacAppearance` 同款理由）。
//
//  ## 🔴 为什么应用要**遍历所有 window**
//  iOS 上外观是**挂在 window 上**的，而本 App 的界面散在不止一个 window：
//  主 window（会话页）+ 抽屉菜单是 SideMenu **present** 出来的（同一个 window，但它是
//  present 出来的 VC，得靠继承才跟上）+ 设置页又是一个模态。
//  只设主 window 的话，抽屉与设置页在切换的那一刻仍按旧档绘制 ⇒ 用户看到「菜单还是浅的、
//  底下已经深了」的半截状态。
//  ⇒ `apply` 走 `connectedScenes` 把**每个** window 都设一遍（实测一网打尽，且不怕将来加窗口）。
//
//  ⚠️ `overrideUserInterfaceStyle` 会被 UIKit 继承给其下的 view / presented VC，
//    所以**不需要**手动刷新界面或重建 rootViewController。

import UIKit
// 🔴 档位文案要走 `L()`（2026-10-13 接的本地化）。本工程开了
//    `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` ⇒ **用谁的 API 就得显式 import 谁**，
//    `L()` 在 `AICore` 里，只有 `import UIKit` 是拿不到的。
import AICore

/// 外观三档。`rawValue` 直接落 `UserDefaults`。
/// ⚠️ ⛔ 别改已有 case 的 `rawValue` —— 那就是存档格式，改了等于把用户选过的偏好丢掉。
enum AIAppearance: String, CaseIterable {
    /// 跟随系统（默认）—— 对应 `overrideUserInterfaceStyle = .unspecified`
    case system
    case light
    case dark

    /// 菜单里那一行的文案。
    ///
    /// ⚠️ 走 `L()` 而不是写死中文：它是**界面文案**，跟着 App 语言走
    ///    （「跟随系统」这个 key 与语言档位那个是**同一个**，英文只译一条，见 `AILocalization.en`）。
    var title: String {
        switch self {
        case .system: return L("跟随系统")
        case .light:  return L("浅色")
        case .dark:   return L("深色")
        }
    }

    /// 对应的 `UIUserInterfaceStyle`。`.system` 必须落 `.unspecified` 而不是 `.light`/`.dark`
    /// —— 写成具体档就变成「强制浅色」了，与「跟随系统」的字面意思相反。
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// 「外观」偏好的**唯一存取点**（读 / 写 / 应用）。
enum AIAppearanceStore {

    /// ⚠️ 带命名空间前缀：`UserDefaults` 是与系统及其它版本共用的命名空间，
    ///    裸 `"appearance"` 这种键名迟早撞上（与 `MacAppearanceStore` 同款理由，
    ///    但**键名故意不同**：两端偏好互相独立，不该串）。
    private static let key = "Aster.appearance"

    /// 当前偏好。
    ///
    /// ⛔ 别在视图里直接 `UserDefaults.string(forKey:)` —— 那样默认值（`.system`）
    ///    会在各处散成好几份，哪天改默认值一定漏掉某处。
    static var current: AIAppearance {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let value = AIAppearance(rawValue: raw) else { return .system }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            apply(newValue)
        }
    }

    /// 把偏好应用到**所有** window。见文件头「为什么要遍历」。
    static func apply(_ appearance: AIAppearance) {
        let style = appearance.interfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }

    /// 启动时套用一次。
    ///
    /// 🔴 **必须在窗口 `makeKeyAndVisible()` 之前调**（`SceneDelegate.willConnectTo` 里）：
    /// 晚了会先按系统外观画一帧、再跳成用户选的那档（视觉上就是「启动闪一下」）。
    static func restoreAtLaunch() { apply(current) }
}