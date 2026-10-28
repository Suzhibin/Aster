//
//  SceneDelegate+Init.swift
//  Aster
//
//  Created by Suzhibin on 2026/9/20.
//
//  启动期的基础设施初始化。相比 StarryApp 去掉了：
//    DownloadRestoreTasks()（下载模块与本 App 无关）
//    setupThirdPlatForm() / setupMetricKit()（原本就是空实现）
//    setupLogger()（2026-10-04 按要求去掉：不再初始化日志系统）
//
//  ⚠️ `setupLogger()` 已被删除，不是漏了。StarryKit 里的 StarryLogger / StarryLogConfiguration
//     源码仍在（`Sources/StarryKit/APM/StarryLogger/`），只是**不再于启动时配置与 bootstrap**。
//     业务代码本来就没有任何 `StarryLogger.*` 调用点，所以删掉后行为等价、只是不再落盘日志文件。
//     需要恢复时：把 SceneDelegate 的 setupLogger() 调用加回 + 在此重新定义即可。

import Foundation
import UIKit
import StarryKitCore

extension SceneDelegate {

    /// 网络注册
    func setupNetwork() {
        StarryNetworkMonitor.shared.startListening()
        StarryNetworkMonitor.shared.onStatusChange = { type in
            print("网络状态：\(type.rawValue)")
        }
    }

    /// AI 模块注册。
    ///
    /// 📌 2026-10-04 由 `SceneDelegate+Navigator.swift` 的 `setupNavigator()` **改名搬来**：
    /// URLNavigator 依赖已整体摘除（那条 `RoutePath.AIModuleVC` 路由从没被 push/present 过），
    /// 于是这里只剩它的**承重部分** —— 把 `AIModuleImpl` 注册进服务总线。
    /// 原文件改名 `SceneDelegate+Menu.swift`，只剩抽屉菜单。
    ///
    /// 🔴 **必须在 `StarryServiceBus.shared.resolve(AIModuleEntryProtocol.self)` 之前调用**：
    /// 就是本函数把 `AIModuleImpl` 注册进总线的，写在 `resolve` 之后就 resolve 不到 → 首屏白屏。
    /// ⛔ 别把它当成「没用了的路由代码」删掉 —— 删了 App 直接白屏。
    func registerAIModule() {
        AIModuleRouter.register()
    }

}
