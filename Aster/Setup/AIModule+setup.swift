//
//  AIModule+setup.swift
//  Aster
//
//  模块注册。这是**刻意与上游 StarrySPM 分叉**的唯一一处（2026-10-04）。
//  ⛔ 别为了「与 SPM 版零分叉」把 `navigator:` 参数补回来 —— 那会把 URLNavigator 依赖一起拖回来，
//     而它在本 App 里是死的（原因见 `AIModuleRouter.register()` 的注释）。
//

import Foundation
import UIKit
import StarryKitCore

/// ⚠️ 名字里的 "Router" 是历史遗留（原上游用它同时兼做 URLNavigator 路由表），
///    现在它只负责「把模块注册进服务总线」。为减少无谓 diff 保留此名。
public enum AIModuleRouter {

    /// 🔴 全 App 只需要做一件事：把 `AIModuleImpl` 注册进 `StarryServiceBus`。
    ///
    /// `SceneDelegate` 紧接着 `StarryServiceBus.shared.resolve(AIModuleEntryProtocol.self)`
    /// 取首屏 ⇒ **本函数必须在那个 `resolve` 之前调用**（见 `SceneDelegate.registerAIModule()`），
    /// 写在之后就 resolve 不到 → 首屏白屏。
    ///
    /// ⚠️ 与上游的差异（已确认是主动为之，不是漏写）：
    /// 原签名是 `register(navigator: NavigatorProtocol)`，额外往 URLNavigator 注册
    /// `RoutePath.AIModuleVC` 路由。但本 App 是**单入口**（首屏恒为 AI 会话页）——
    /// 那条路由从注册至今**一次都没被 push / present 过**（全仓 0 处调用），
    /// 配套的 `NavigatorDelegate` 也只是两个 `print` 调试残留
    /// ⇒ 2026-10-04 连同 URLNavigator 依赖一并摘除，`Sources/Setup/RoutePath.swift` 同步删除。
    public static func register() {
        let entry = AIModuleImpl()
        StarryServiceBus.shared.register(AIModuleEntryProtocol.self, impl: entry)
    }
}

public final class AIModuleImpl: AIModuleEntryProtocol {
    public init() {}

    public func AIModuleRegisterViewController() -> UIViewController {
        return AIModuleViewController()
    }
}
