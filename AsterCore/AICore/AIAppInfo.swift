//
//  AIAppInfo.swift
//  AICore
//
//  App 级的**静态事实**（不是偏好、不是配置、运行期不会变）集中放这里，
//  两端共用同一份，⛔ 别在视图里再写一份字符串。
//
//  ## 为什么要有这个文件（2026-10-27）
//  用户「头像和名称都删掉」⇒ 两端原来各自持有 GitHub 地址的**载体**被删了：
//    · iOS `AIAccountMenuViewController.gitHubURL`（账号弹窗整个文件删掉）
//    · Mac `SidebarAccountBar.gitHubURL`（改成纯设置栏）
//  但「设置 → 关于」页两端都还在用它（iOS `AIAboutViewController` / Mac `MacSettingsView`），
//  且注释里三处都写着「这是同一个地址、别另写一份」—— 那就把它挪到共享层，
//  从此**唯一来源在这里**，谁再写一遍字符串就是新的漂移点。
//
//  ⚠️ 为什么放 `AICore` 而不是 `StarryKitCore`：这属于「这个 App 的事」，
//     不是通用基础设施（StarryKitCore 将来要能被别的 App 拿去用）。
//

import Foundation

/// 本项目的 GitHub 主页（「关于」页那一行、以及任何「去 GitHub 看看」的入口）。
///
/// ⚠️ 跨模块要用 ⇒ 必须 `public`；`let` 而非 `static let` 是照本包其余常量的写法。
public let AIGitHubURL = "https://github.com/suzhibin"

/// 上面那个地址**给人看**的形态（去掉 `https://`）—— 关于页右侧那行小字用它。
///
/// ⚠️ 由 `AIGitHubURL` **派生**，⛔ 别在视图里写死 `"github.com/suzhibin"`：
///    那种写法和完整地址是两份真值，改一处漏一处。
public let AIGitHubDisplayName = AIGitHubURL
    .replacingOccurrences(of: "https://", with: "")
    .replacingOccurrences(of: "http://", with: "")
