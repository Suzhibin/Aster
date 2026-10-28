//
//  StarryPermission.swift
//  BaseModule
//
//  Created by Suzhibin on 2026/7/9.
//

import Foundation
import AVFoundation
import Photos
import CoreLocation
import UserNotifications
import Contacts
import EventKit
import Speech
import CoreBluetooth
import AIPlatform

// - Note: ① `import UIKit` 撤掉了 —— 原先只用它取 `UIApplication.openSettingsURLString`，
//     现在走 `AIPlatform.system.openAppSettings()`。
//   ② `import AppTrackingTransparency` + `ATTrackingManager` 也撤了 —— 那是 **iOS 独有**的框架
//     （macOS 上压根不存在），搬进 `AIPlatform.system` 的 iOS 实现里。
//   其余框架（AVFoundation / Photos / CoreLocation / EventKit / Contacts / Speech / CoreBluetooth）
//   在 macOS 上都有，所以本文件**一个 `#if os(...)` 都不需要**。

// MARK: - 权限类型

public enum StarryPermissionType {
    /// 相机
    case camera
    /// 相册 (只读 .readWrite 是 iOS 14+，内部自动降级)
    case photoLibrary
    /// 相册**只写**（2026-10-08 加：「保存图片到相册」用这一档）
    ///
    /// 🔴 **为什么不能复用 `.photoLibrary`**：那一档请求的是 `.readWrite`（**读**相册），
    /// 而「保存一张我们自己落盘的附件」只需要**写**。用 `.readWrite` 会让用户为了存一张图
    /// 被问「要不要让 StarryAI 访问你的照片」—— 权限与实际用途不匹配。
    /// `PHAccessLevel.addOnly` 是系统专为此存在的档位：只允许添加，不给任何读取。
    ///
    /// ⚠️ **`.limited`（有限相册访问）也能存** —— 限制的是「能读到哪些」，
    /// 添加永远允许。所以判据是「`.addOnly` 这一档的 `authorized` 就算过」，
    /// 而 `.photoLibrary` 那档把 `.limited` 归成 `.authorized` 是为网格服务的，两条路互不影响。
    ///
    /// ☠️ **Info.plist 必须有 `NSPhotoLibraryAddUsageDescription`**，缺了系统会**直接崩**
    /// （不是拒绝授权，是 terminate）。它与 `.photoLibrary` 那个
    /// `NSPhotoLibraryUsageDescription` 是**两个独立 key**，加权限类型时必须一起加。
    case photoLibraryAdd
    /// 麦克风
    case microphone
    /// 定位-使用时
    case locationWhenInUse
    /// 定位-始终
    case locationAlways
    /// 通知
    case notification
    /// 通讯录
    case contacts
    /// 日历
    case calendar
    /// 提醒事项
    case reminders
    /// 语音识别
    case speechRecognition
    /// 蓝牙
    case bluetooth
    /// 跟踪 (iOS 14+)
    case tracking

    /// 权限对应的 Info.plist key（用于文案提示）
    var infoPlistKey: String {
        switch self {
        case .camera:               return "NSCameraUsageDescription"
        case .photoLibrary:         return "NSPhotoLibraryUsageDescription"
        case .photoLibraryAdd:      return "NSPhotoLibraryAddUsageDescription"
        case .microphone:           return "NSMicrophoneUsageDescription"
        case .locationWhenInUse:    return "NSLocationWhenInUseUsageDescription"
        case .locationAlways:       return "NSLocationAlwaysAndWhenInUseUsageDescription"
        case .notification:         return "-"
        case .contacts:             return "NSContactsUsageDescription"
        case .calendar:             return "NSCalendarsUsageDescription"
        case .reminders:            return "NSRemindersUsageDescription"
        case .speechRecognition:    return "NSSpeechRecognitionUsageDescription"
        case .bluetooth:            return "NSBluetoothAlwaysUsageDescription"
        case .tracking:             return "NSUserTrackingUsageDescription"
        }
    }
}

// MARK: - 权限状态

public enum StarryPermissionStatus {
    /// 尚未请求
    case notDetermined
    /// 已授权
    case authorized
    /// 已拒绝
    case denied
    /// 受限制 (如家长控制)
    case restricted
}

// MARK: - 权限管理器

public final class StarryPermission: NSObject {

    // MARK: 使用说明
    //
    //  1. 查询权限状态（同步）：
    //     let status = StarryPermission.status(for: .camera)
    //
    //  2. 请求权限（异步，主线程回调）：
    //     StarryPermission.request(.camera) { status in
    //         switch status {
    //         case .authorized:      // 已授权，执行业务逻辑
    //         case .denied:          // 已拒绝，引导用户去设置
    //             StarryPermission.openSettings()
    //         case .notDetermined:   // 尚未请求过
    //         case .restricted:      // 受家长控制等限制
    //         }
    //     }
    //
    //  3. 跳转系统设置：
    //     StarryPermission.openSettings()
    //
    //  4. 获取对应 Info.plist key（用于提示文案）：
    //     let key = StarryPermissionType.camera.infoPlistKey  // "NSCameraUsageDescription"

    // MARK: - 查询当前权限状态

    public static func status(for type: StarryPermissionType) -> StarryPermissionStatus {
        switch type {
        case .camera:
            return cameraStatus
        case .photoLibrary:
            return photoLibraryStatus
        case .photoLibraryAdd:
            return photoLibraryAddStatus
        case .microphone:
            return microphoneStatus
        case .locationWhenInUse, .locationAlways:
            return locationStatus(for: type)
        case .notification:
            return .notDetermined // 通知只能用异步回调查询
        case .contacts:
            return contactsStatus
        case .calendar:
            return calendarStatus
        case .reminders:
            return remindersStatus
        case .speechRecognition:
            return speechRecognitionStatus
        case .bluetooth:
            return bluetoothStatus
        case .tracking:
            return trackingStatus
        }
    }

    // MARK: - 请求权限

    /// 请求指定权限
    /// - Parameters:
    ///   - type: 权限类型
    ///   - completion: 请求结果回调 (在主线程)
    public static func request(_ type: StarryPermissionType, completion: @escaping (StarryPermissionStatus) -> Void) {
        switch type {
        case .camera:
            requestCamera(completion: completion)
        case .photoLibrary:
            requestPhotoLibrary(completion: completion)
        case .photoLibraryAdd:
            requestPhotoLibraryAdd(completion: completion)
        case .microphone:
            requestMicrophone(completion: completion)
        case .locationWhenInUse, .locationAlways:
            requestLocation(type, completion: completion)
        case .notification:
            requestNotification(completion: completion)
        case .contacts:
            requestContacts(completion: completion)
        case .calendar:
            requestCalendar(completion: completion)
        case .reminders:
            requestReminders(completion: completion)
        case .speechRecognition:
            requestSpeechRecognition(completion: completion)
        case .bluetooth:
            requestBluetooth(completion: completion)
        case .tracking:
            requestTracking(completion: completion)
        }
    }

    /// 跳转到系统设置
    ///
    /// - iOS: 打开本 App 的设置页（`UIApplication.openSettingsURLString`）
    /// - macOS: 打开「系统设置 › 隐私与安全性」（Mac 没有「App 设置页」这个概念）
    public static func openSettings() {
        AIPlatform.system.openAppSettings()
    }
}

// MARK: - 各权限实现

private extension StarryPermission {

    // MARK: 相机

    static var cameraStatus: StarryPermissionStatus {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return mapStatus(status)
    }

    static func requestCamera(completion: @escaping (StarryPermissionStatus) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.runOnMain {
                completion(cameraStatus)
            }
        }
    }

    // MARK: 相册

    static var photoLibraryStatus: StarryPermissionStatus {
        if #available(iOS 14, *) {
            return mapStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        } else {
            return mapStatus(PHPhotoLibrary.authorizationStatus())
        }
    }

    static func requestPhotoLibrary(completion: @escaping (StarryPermissionStatus) -> Void) {
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
                DispatchQueue.runOnMain {
                    completion(photoLibraryStatus)
                }
            }
        } else {
            PHPhotoLibrary.requestAuthorization { _ in
                DispatchQueue.runOnMain {
                    completion(photoLibraryStatus)
                }
            }
        }
    }

    /// 相册**只写**档的状态（`.addOnly`）。
    ///
    /// ⚠️ `PHAccessLevel.addOnly` 是 iOS 14+ / macOS 11+，而本包下限是 iOS 15 / macOS 14，
    /// 所以**不需要** `if #available`（上面 `.readWrite` 那段留着是因为它还兼顾了 iOS 14 以下的写法）。
    static var photoLibraryAddStatus: StarryPermissionStatus {
        mapStatus(PHPhotoLibrary.authorizationStatus(for: .addOnly))
    }

    static func requestPhotoLibraryAdd(completion: @escaping (StarryPermissionStatus) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
            DispatchQueue.runOnMain {
                completion(photoLibraryAddStatus)
            }
        }
    }

    // MARK: 麦克风

    static var microphoneStatus: StarryPermissionStatus {
        mapStatus(AIPlatform.audio.recordPermission())
    }

    static func requestMicrophone(completion: @escaping (StarryPermissionStatus) -> Void) {
        AIPlatform.audio.requestRecordPermission { _ in
            DispatchQueue.runOnMain {
                completion(microphoneStatus)
            }
        }
    }

    // MARK: 定位

    static let locationManager = CLLocationManager()
    static var locationCompletion: ((StarryPermissionStatus) -> Void)?
    static var pendingLocationType: StarryPermissionType?

    static func locationStatus(for type: StarryPermissionType) -> StarryPermissionStatus {
        guard CLLocationManager.locationServicesEnabled() else {
            return .denied
        }
        // 🔴 实例属性而非类方法：`CLLocationManager.authorizationStatus()`（类方法）
        //    iOS 14 / macOS 11 起弃用，官方替换就是实例属性（Xcode 27 起报弃用警告）。
        //    部署目标 iOS 15 / macOS 14 ⇒ 实例属性两边都可用。
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:    return .notDetermined
        case .restricted:       return .restricted
        case .denied:           return .denied
        case .authorizedAlways: return .authorized
        case .authorizedWhenInUse:
            return type == .locationAlways ? .denied : .authorized
        @unknown default:       return .notDetermined
        }
    }

    static func requestLocation(_ type: StarryPermissionType, completion: @escaping (StarryPermissionStatus) -> Void) {
        let currentStatus = locationStatus(for: type)
        guard currentStatus == .notDetermined else {
            DispatchQueue.runOnMain { completion(currentStatus) }
            return
        }

        pendingLocationType = type
        locationCompletion = completion
        locationManager.delegate = shared

        switch type {
        case .locationWhenInUse:
            locationManager.requestWhenInUseAuthorization()
        case .locationAlways:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    // MARK: 通知

    static func requestNotification(completion: @escaping (StarryPermissionStatus) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.badge, .sound, .alert]) { granted, _ in
            DispatchQueue.runOnMain {
                completion(granted ? .authorized : .denied)
            }
        }
    }

    // MARK: 通讯录

    static var contactsStatus: StarryPermissionStatus {
        mapStatus(CNContactStore.authorizationStatus(for: .contacts))
    }

    static func requestContacts(completion: @escaping (StarryPermissionStatus) -> Void) {
        CNContactStore().requestAccess(for: .contacts) { _, _ in
            DispatchQueue.runOnMain {
                completion(contactsStatus)
            }
        }
    }

    // MARK: 日历

    static var calendarStatus: StarryPermissionStatus {
        mapStatus(EKEventStore.authorizationStatus(for: .event))
    }

    // ⚠️ `requestAccess(to:)` 在 macOS 14 起弃用（官方建议改用
    //    `requestFullAccessToEventsWithCompletion:` 等）。**刻意不换**，原因：
    //    ① 替换 API **按平台不同名**（iOS 是 `requestFullAccess(to:)`，macOS 是
    //       `requestFullAccessToEvents/Reminders`）⇒ 本文件是跨平台共享层，
    //       `#if os(` 按项目铁律只许出现在 `AIPlatform/`，在这里没法写；
    //    ② 旧 API 在 macOS 14+ 仍可正常工作（就是申请完全访问），没有行为问题；
    //    ③ 真要消这条警告得在 `AIPlatform` 加平台缝（protocol + 两端实现），
    //       收益（两条 cosmetic 警告）远低于风险。**别顺手改。**
    static func requestCalendar(completion: @escaping (StarryPermissionStatus) -> Void) {
        EKEventStore().requestAccess(to: .event) { _, _ in
            DispatchQueue.runOnMain {
                completion(calendarStatus)
            }
        }
    }

    // MARK: 提醒事项

    static var remindersStatus: StarryPermissionStatus {
        mapStatus(EKEventStore.authorizationStatus(for: .reminder))
    }

    static func requestReminders(completion: @escaping (StarryPermissionStatus) -> Void) {
        EKEventStore().requestAccess(to: .reminder) { _, _ in
            DispatchQueue.runOnMain {
                completion(remindersStatus)
            }
        }
    }

    // MARK: 语音识别

    static var speechRecognitionStatus: StarryPermissionStatus {
        mapStatus(SFSpeechRecognizer.authorizationStatus())
    }

    static func requestSpeechRecognition(completion: @escaping (StarryPermissionStatus) -> Void) {
        SFSpeechRecognizer.requestAuthorization { _ in
            DispatchQueue.runOnMain {
                completion(speechRecognitionStatus)
            }
        }
    }

    // MARK: 蓝牙

    static var bluetoothManager: CBCentralManager?
    static var bluetoothCompletion: ((StarryPermissionStatus) -> Void)?

    static var bluetoothStatus: StarryPermissionStatus {
        if #available(iOS 13.1, *) {
            return mapStatus(CBCentralManager.authorization)
        } else {
            return mapStatus(CBCentralManager.authorization)
        }
    }

    static func requestBluetooth(completion: @escaping (StarryPermissionStatus) -> Void) {
        let current = bluetoothStatus
        guard current == .notDetermined else {
            DispatchQueue.runOnMain { completion(current) }
            return
        }
        // 蓝牙权限触发：创建 CBCentralManager 实例即可弹出系统授权弹窗
        bluetoothCompletion = completion
        bluetoothManager = CBCentralManager(delegate: shared, queue: nil)
    }

    // MARK: 跟踪 (iOS 14+；macOS 无此概念)

    /// - Note: `ATTrackingManager` 是 **iOS 独有**框架（macOS 上不存在），
    ///   所以整条判定搬进 `AIPlatform.system`。iOS 侧保留了原先的兼容分支
    ///   （14 以下无需 IDFA 授权 → `.authorized`），macOS 侧恒 `.authorized`（无此限制）。
    static var trackingStatus: StarryPermissionStatus {
        mapStatus(AIPlatform.system.trackingStatus())
    }

    static func requestTracking(completion: @escaping (StarryPermissionStatus) -> Void) {
        AIPlatform.system.requestTracking { status in
            DispatchQueue.runOnMain {
                completion(mapStatus(status))
            }
        }
    }

    // MARK: - 状态映射

    static func mapStatus(_ status: AVAuthorizationStatus) -> StarryPermissionStatus {
        switch status {
        case .notDetermined:    return .notDetermined
        case .restricted:       return .restricted
        case .denied:           return .denied
        case .authorized:       return .authorized
        @unknown default:       return .notDetermined
        }
    }

    static func mapStatus(_ status: PHAuthorizationStatus) -> StarryPermissionStatus {
        switch status {
        case .notDetermined:    return .notDetermined
        case .restricted:       return .restricted
        case .denied:           return .denied
        case .authorized:       return .authorized
        case .limited:          return .authorized // iOS 14 有限相册访问视为已授权
        @unknown default:       return .notDetermined
        }
    }

    static func mapStatus(_ permission: AIRecordPermission) -> StarryPermissionStatus {
        switch permission {
        case .notDetermined:    return .notDetermined
        case .denied:           return .denied
        case .granted:          return .authorized
        }
    }

    static func mapStatus(_ status: CNAuthorizationStatus) -> StarryPermissionStatus {
        switch status {
        case .notDetermined:    return .notDetermined
        case .restricted:       return .restricted
        case .denied:           return .denied
        case .authorized:       return .authorized
        // iOS 14 有限通讯录访问：能读（部分）⇒ 视为已授权。
        // 🔴 Xcode 27（Swift 6.2）起 `@unknown default` **不再兜住 SDK 里已存在**的
        //    case —— 少一个就报 `switch must be exhaustive`，必须显式列出。
        case .limited:          return .authorized
        @unknown default:       return .notDetermined
        }
    }

    static func mapStatus(_ status: EKAuthorizationStatus) -> StarryPermissionStatus {
        switch status {
        case .notDetermined:    return .notDetermined
        case .restricted:       return .restricted
        case .denied:           return .denied
        case .authorized:       return .authorized
        // macOS 14 / iOS 17 起的两档新权限（同上：Xcode 27 起 @unknown default 兜不住）：
        // `.fullAccess` = 完全访问 ⇒ 已授权；`.writeOnly` = 只写 ⇒ 读不了 ⇒ 拒绝。
        case .fullAccess:       return .authorized
        case .writeOnly:        return .denied
        @unknown default:       return .notDetermined
        }
    }

    static func mapStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> StarryPermissionStatus {
        switch status {
        case .notDetermined:    return .notDetermined
        case .denied:           return .denied
        case .restricted:       return .restricted
        case .authorized:       return .authorized
        @unknown default:       return .notDetermined
        }
    }

    static func mapStatus(_ status: CBManagerAuthorization) -> StarryPermissionStatus {
        switch status {
        case .notDetermined:    return .notDetermined
        case .restricted:       return .restricted
        case .denied:           return .denied
        case .allowedAlways:    return .authorized
        @unknown default:       return .notDetermined
        }
    }

    static func mapStatus(_ status: AIPlatformTrackingStatus) -> StarryPermissionStatus {
        switch status {
        case .notDetermined:    return .notDetermined
        case .restricted:       return .restricted
        case .denied:           return .denied
        case .authorized:       return .authorized
        }
    }
}

// MARK: - Delegate 代理（定位 & 蓝牙回调）

extension StarryPermission: CLLocationManagerDelegate, CBCentralManagerDelegate {

    // 持有单例 delegate
    private static let shared = StarryPermission()

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let completion = StarryPermission.locationCompletion else { return }
        StarryPermission.locationCompletion = nil
        let type = StarryPermission.pendingLocationType ?? .locationWhenInUse
        DispatchQueue.runOnMain {
            completion(StarryPermission.locationStatus(for: type))
        }
    }

    // iOS 13 以下
    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if #available(iOS 14, *) { return }
        guard let completion = StarryPermission.locationCompletion else { return }
        StarryPermission.locationCompletion = nil
        let type = StarryPermission.pendingLocationType ?? .locationWhenInUse
        DispatchQueue.runOnMain {
            completion(StarryPermission.locationStatus(for: type))
        }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let completion = StarryPermission.bluetoothCompletion else { return }
        StarryPermission.bluetoothCompletion = nil
        StarryPermission.bluetoothManager = nil
        DispatchQueue.runOnMain {
            completion(StarryPermission.bluetoothStatus)
        }
    }
}

