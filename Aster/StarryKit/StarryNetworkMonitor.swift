//
//  StarryNetworkStatus.swift
//  StarryKIt
//
//  网络连接状态管理：WiFi / 5G / 4G / 3G / 2G / 无网络 实时查询
//  基于 Alamofire NetworkReachabilityManager + CoreTelephony
//

import Foundation
import Alamofire
import CoreTelephony

// MARK: - 网络类型

/// 细粒度网络类型，覆盖 WiFi 到 2G
public enum StarryNetworkStatus: String {
    case wifi             // WiFi
    case cellular5G       // 5G (NR / NRNSA)
    case cellular4G       // 4G (LTE)
    case cellular3_75G    // eHRPD
    case cellular3_5G     // HSDPA / HSUPA
    case cellular3G       // WCDMA / CDMA EVDO
    case cellular2G       // EDGE / GPRS / CDMA1x
    case cellular         // 蜂窝网络（无法区分代数）
    case ethernet         // 有线以太网
    case notReachable     // 无网络
    case unknown          // 未知
}

// MARK: - 网络状态管理器

public final class StarryNetworkMonitor {

    // MARK: 单例
    public static let shared = StarryNetworkMonitor()
    private init() {}

    // MARK: 底层依赖
    private let reachability = NetworkReachabilityManager()

    /// CoreTelephony 句柄（**用到才建**）。
    ///
    /// ⚠️ 不要在 init 里无条件 `CTTelephonyNetworkInfo()`：它的构造会立刻发起一条到
    /// `com.apple.commcenter.coretelephony.xpc` 的连接。模拟器没有 commcenter（无蜂窝基带），
    /// 这条连接必然失败，启动时控制台会连打 4 条 E 级：
    ///
    /// ```
    /// Updating selectors failed with: Error Domain=NSCocoaErrorDomain Code=4099
    /// "The connection to service named com.apple.commcenter.coretelephony.xpc was invalidated…"
    /// ```
    ///
    /// 而这里本来也用不着那么早：`telephonyInfo` 只有 `currentCellularType()` 一处消费，
    /// 也就是「可达性确实是蜂窝」时才需要 —— 模拟器的可达性永远是 `.ethernetOrWiFi`，
    /// 真机连 WiFi 时同样走不到。所以推迟到真正读取时再建，两端都不再有这次无谓的连接。
    private lazy var telephonyInfo: CTTelephonyNetworkInfo? = {
        #if targetEnvironment(simulator)
        // 模拟器无蜂窝基带，建了只会报 4099，直接不建
        return nil
        #else
        return CTTelephonyNetworkInfo()
        #endif
    }()

    // MARK: 当前状态（核心 API）

    /// 当前网络类型，随时查询，无需注册监听
    public var current: StarryNetworkStatus {
        guard let reachability else { return .unknown }
        switch reachability.status {
        case .reachable(.ethernetOrWiFi):
            return .wifi
        case .reachable(.cellular):
            return currentCellularType()
        case .notReachable:
            return .notReachable
        case .unknown:
            return .unknown
        }
    }

    // MARK: 蜂窝网络细化（CoreTelephony：2G → 5G 全覆盖）

    private func currentCellularType() -> StarryNetworkStatus {
        // 模拟器上 telephonyInfo 恒为 nil（见其声明处的注释），拿不到代际 → 退化成「蜂窝网络」。
        // 这种情况实际不会发生：模拟器的可达性永远是 .ethernetOrWiFi，走不到这里。
        guard let radioTech = telephonyInfo?.serviceCurrentRadioAccessTechnology?.values.first else {
            return .cellular
        }

        // iOS 14.1+ 区分 5G
        if #available(iOS 14.1, *) {
            if radioTech == CTRadioAccessTechnologyNRNSA || radioTech == CTRadioAccessTechnologyNR {
                return .cellular5G
            }
        }
        if radioTech == CTRadioAccessTechnologyLTE {
            return .cellular4G
        }
        if radioTech == CTRadioAccessTechnologyeHRPD {
            return .cellular3_75G
        }
        if radioTech == CTRadioAccessTechnologyHSDPA || radioTech == CTRadioAccessTechnologyHSUPA {
            return .cellular3_5G
        }
        if radioTech == CTRadioAccessTechnologyWCDMA
            || radioTech == CTRadioAccessTechnologyCDMAEVDORev0
            || radioTech == CTRadioAccessTechnologyCDMAEVDORevA
            || radioTech == CTRadioAccessTechnologyCDMAEVDORevB {
            return .cellular3G
        }
        if radioTech == CTRadioAccessTechnologyEdge
            || radioTech == CTRadioAccessTechnologyGPRS
            || radioTech == CTRadioAccessTechnologyCDMA1x {
            return .cellular2G
        }
        return .cellular
    }

    // MARK: 蜂窝网络描述（给 UI 展示用）

    /// 蜂窝网络类型的人类可读描述
    public var cellularDescription: String {
        switch current {
        case .cellular5G:    return "5G"
        case .cellular4G:    return "4G"
        case .cellular3_75G: return "3G"
        case .cellular3_5G:  return "3G"
        case .cellular3G:    return "3G"
        case .cellular2G:    return "2G"
        case .cellular:      return "蜂窝网络"
        default:             return ""
        }
    }

    // MARK: 便捷查询属性

    public var isReachable: Bool {
        reachability?.isReachable ?? false
    }

    public var isWiFi: Bool {
        current == .wifi
    }

    public var isCellular: Bool {
        switch current {
        case .cellular5G, .cellular4G,
             .cellular3_75G, .cellular3_5G, .cellular3G, .cellular2G,
             .cellular:
            return true
        default:
            return false
        }
    }

    public var isOffline: Bool {
        current == .notReachable
    }

    // MARK: 实时监控（闭包 + 通知 二选一）

    /// 网络状态变化回调（主线程，可直接更新 UI）
    public var onStatusChange: ((StarryNetworkStatus) -> Void)?

    /// 通知名：网络状态变化（主线程广播，可直接在 VC 中监听）
    ///
    /// ```swift
    /// NotificationCenter.default.addObserver(forName: .starryNetworkStatusDidChange, ...)
    /// ```
    /// `userInfo["type"]` → `StarryNetworkType` 枚举值
    public static let notificationName = Notification.Name("StarryNetworkStatusDidChange")

    // MARK: 启动 / 停止

    /// 启动底层监听（App 启动时调一次，内部自动通知回调方）
    public func startListening() {
        reachability?.startListening { [weak self] _ in
            guard let self else { return }
            let type = self.current
            DispatchQueue.main.async {
                // 闭包回调（主线程，可直接更新 UI）
                self.onStatusChange?(type)
                // 通知广播
                NotificationCenter.default.post(
                    name: StarryNetworkMonitor.notificationName,
                    object: nil,
                    userInfo: ["type": type]
                )
            }
        }
    }

    public func stopListening() {
        reachability?.stopListening()
    }
}
