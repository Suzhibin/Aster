//
//  StarryHaptic.swift
//  BaseModule
//
//  Created by Suzhibin on 2026/7/9.
//

import UIKit

/// 触觉反馈统一封装
///
/// 使用方式：
///     StarryHaptic.impact(.light)        // 轻触
///     StarryHaptic.impact(.heavy)        // 重击
///     StarryHaptic.notify(.success)      // 成功
///     StarryHaptic.notify(.warning)      // 警告
///     StarryHaptic.notify(.error)        // 错误
///     StarryHaptic.selection()           // 选择切换
public enum StarryHaptic {

    // MARK: - 触碰反馈

    /// 触碰强度
    public enum ImpactStyle {
        case light
        case medium
        case heavy
        case soft      // iOS 13+
        case rigid     // iOS 13+
    }

    /// 触碰反馈
    /// - Parameter style: 触碰强度，默认 .light
    public static func impact(_ style: ImpactStyle = .light) {
        let generator: UIImpactFeedbackGenerator
        switch style {
        case .light:
            generator = UIImpactFeedbackGenerator(style: .light)
        case .medium:
            generator = UIImpactFeedbackGenerator(style: .medium)
        case .heavy:
            generator = UIImpactFeedbackGenerator(style: .heavy)
        case .soft:
            if #available(iOS 13.0, *) {
                generator = UIImpactFeedbackGenerator(style: .soft)
            } else {
                generator = UIImpactFeedbackGenerator(style: .light)
            }
        case .rigid:
            if #available(iOS 13.0, *) {
                generator = UIImpactFeedbackGenerator(style: .rigid)
            } else {
                generator = UIImpactFeedbackGenerator(style: .heavy)
            }
        }
        generator.prepare()
        generator.impactOccurred()
    }

    // MARK: - 通知反馈

    /// 通知类型
    public enum NotificationType {
        case success
        case warning
        case error
    }

    /// 通知反馈
    /// - Parameter type: 通知类型
    public static func notify(_ type: NotificationType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        switch type {
        case .success:
            generator.notificationOccurred(.success)
        case .warning:
            generator.notificationOccurred(.warning)
        case .error:
            generator.notificationOccurred(.error)
        }
    }

    // MARK: - 选择反馈

    /// 选择切换反馈（如切换 tab、segmented control）
    public static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
}
