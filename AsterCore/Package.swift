// swift-tools-version: 5.9
//
//  Package.swift
//  AsterCore
//
//  共享业务层包：iOS App（Aster）与 macOS App（AsterMac）共用同一份业务代码。
//
//  目录结构（用 `path:` 指定，不套 Sources/ 一层）：
//    AIPlatform/     —— 跨平台接缝层（**唯一的平台分支边界**）
//                       值类型用 typealias（字体/颜色/段落样式/图像），
//                       行为用 protocol + 平台实现（音频会话 / 后台任务 / 系统集成 / 图像编解码）
//    StarryKitCore/  —— 从 Aster/StarryKit 抽出的「非 UI 基础设施」
//                       （SSE 客户端 / SQLite / Keychain / 服务总线 / 权限）
//    AICore/         —— 从 Aster/Sources 抽出的「AI 业务层」
//                       （会话管理 / 落库 / Provider / Markdown 解析 / token 统计 / 附件 / 朗读）
//
//  依赖方向（**单向，别倒过来**）：
//      AIPlatform  ←  StarryKitCore  ←  AICore
//
//  ⚠️ 平台声明两段都要有，且**各自的最低版本可以不同**：
//     `platforms:` 是「这个包支持哪些平台」，不是白名单 ——
//     缺 `.macOS` 时包在 Mac 上仍会尝试按默认版本编译（实测 SwiftPM 直接按 macosx14.0 处理），
//     真正拦住的是包里 `import UIKit` 这类代码。所以**先做接缝、再声明确认**，顺序别倒。
//
//  ⚠️ 本文件里的版本号必须与 ../Aster.xcodeproj/.../Package.resolved 对齐，
//     否则同一个库会在工程里解析出两个版本（SwiftPM 会各自建一份产物）。
//

import PackageDescription

let package = Package(
    name: "AsterCore",
    platforms: [
        .iOS(.v15),
        .macOS(.v14),
    ],
    products: [
        // 只把两个业务包做成 product —— AIPlatform 是**实现细节**，
        // App 侧不需要 import 它（`AIPlatformFont` 这类别名对 App 是透明的：
        // 在 iOS 上它就等于 `UIFont`）。
        .library(name: "StarryKitCore", targets: ["StarryKitCore"]),
        .library(name: "AICore", targets: ["AICore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Alamofire/Alamofire.git", .upToNextMajor(from: "5.12.2")),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", .upToNextMajor(from: "0.16.0")),
        .package(url: "https://github.com/intsig171/SmartCodable.git", .upToNextMajor(from: "6.0.8")),
        .package(url: "https://github.com/johnxnguyen/Down.git", .upToNextMajor(from: "0.11.0")),
        // 数学公式排版（2026-10-27）：纯 Swift + CoreText，无 JS、无 WebView。
        // ⚠️ 依赖挂在 `AIPlatform` 而不是 `AICore`：把排版结果画成图片这一步
        //    必须按平台分叉（UIKit / AppKit），而 `#if os(` 只允许出现在 AIPlatform 内。
        .package(url: "https://github.com/mgriebling/SwiftMath.git", .upToNextMajor(from: "1.7.3")),
    ],
    targets: [
        .target(
            name: "AIPlatform",
            dependencies: [
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            path: "AIPlatform"
        ),
        .target(
            name: "StarryKitCore",
            dependencies: [
                "AIPlatform",
                .product(name: "Alamofire", package: "Alamofire"),
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "SmartCodable", package: "SmartCodable"),
            ],
            path: "StarryKitCore"
        ),
        .target(
            name: "AICore",
            dependencies: [
                "AIPlatform",
                "StarryKitCore",
                .product(name: "Down", package: "Down"),
                .product(name: "SmartCodable", package: "SmartCodable"),
            ],
            path: "AICore"
        ),
    ]
)
