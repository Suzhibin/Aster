//
//  AIVendorIcon.swift
//  AIPlatform
//
//  供应商品牌图标的**取图唯一入口**：asset 优先，SF Symbols 兜底。
//
//  ## 为什么要有这一层
//  品牌图标是 2026-10-20 接入的（LobeHub 那套单色 24×24 矢量，A 方案 = 单色
//  template 跟随文字色）。但「有 asset」**不能假设恒成立**：
//    · 手改 models.json 写了没见过的 vendor ⇒ `vendorKind` 为 nil ⇒ 没有 asset 名；
//    · 以后新增第六家供应商时，代码先落地、图后补 ⇒ asset 缺失；
//    · 某个 target 的 asset catalog 漏拷（两个 App 各一份）⇒ 运行时取不到。
//  三种情况下 **`UIImage(named:)` 都返回 nil 且不报错** —— 界面上就是一片空白，
//  而且只有肉眼能发现。所以退路必须是代码保证的，不是约定。
//
//  ## asset 到底在哪
//  **不在本包内**：`ProviderXxx.imageset` 分别放在 `Aster/Assets.xcassets` 与
//  `AsterMac/Assets.xcassets`（两个 App 各一份）。这里用 `UIImage(named:)` /
//  `NSImage(named:)`，它们查的是 **main bundle** —— 在本包代码里调用也一样。
//  ⛔ 别改成 `Bundle.module`：本包没有 resources，改成它会永远取不到。
//

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - 取图

/// 品牌图标的**着色方式**。
///
/// 2026-10-20 加：Kimi 换成**官方 app-icon 形态**（黑底圆角方块 + 白 K + 右上蓝点）后，
/// 单色 template 就再也行不通了 —— 见 `.brandColor` 的注释。
public enum AIVendorIconRendering: Sendable {

    /// 单色 + template：颜色跟随 tint / `foregroundStyle`（DeepSeek / 智谱 / 豆包 / MiniMax
    /// 那套单笔触矢量记号走这条）。
    case tinted

    /// 原色：图上**自带品牌色**，⛔ 不受 tint 影响。
    ///
    /// 🔴 为什么必须有这一档：template 模式下 UIKit/SwiftUI 只认 **alpha**，把整张图当成
    ///    一个色块去涂。Kimi 的方块底 alpha 恒为 1 ⇒ 整张图会被涂成一个**实心色块**，
    ///    K 与蓝点全部消失（浅色模式下就是一个纯黑圆角方块，看着像「图标没加载出来」）。
    ///    而且**不报错、不崩溃** —— 只能靠这里显式声明。
    case brandColor
}

public enum AIVendorIcon {

    /// 取供应商图标：**asset 优先，SF Symbols 兜底**。
    ///
    /// - Parameters:
    ///   - asset: asset catalog 里的名字（`AIProviderKind.iconAssetName`），nil = 没有品牌资产。
    ///   - symbol: SF Symbols 名（`AIProviderKind.symbolName`），asset 缺失时用它。
    ///   - rendering: 着色方式（`.tinted` 默认 / `.brandColor` 自带颜色）。**只对 asset 生效** ——
    ///     SF Symbols 永远是单色的，兜底分支不看这个参数。
    ///   - pointSize: **只对 SF Symbol 生效**（符号的绘制尺寸）。asset 返回的是**原始尺寸**的
    ///     矢量图（当前 SVG 的 `viewBox` 是 24×24 ⇒ 固有 24pt），显示大小交给调用方的容器
    ///     （`UIImageView` 的 frame + `scaleAspectFit`、SwiftUI 的 `.resizable().frame(…)`）。
    ///     ⚠️ 别指望用这个参数去缩 asset —— `UIImage` 没有「按字号重排矢量」的能力。
    /// - Returns: 按 `rendering` 标好着色模式的图；两者都取不到时 nil。
    public static func image(asset: String?,
                             symbol: String,
                             pointSize: CGFloat,
                             rendering: AIVendorIconRendering = .tinted) -> AIPlatformImage? {
        #if canImport(UIKit)
        if let asset, let img = UIImage(named: asset) {
            // ⚠️ 即使 imageset 的 `template-rendering-intent` 已经写了，这里再标一次：
            //    那个字段是「Xcode 编译时给的默认值」，而本函数是**唯一入口** —— 保证
            //    任何取图路径拿到的着色方式都一致，⛔ 别删（删了会退化成「看 catalog 心情」：
            //    单色图在 tint 下不变色、彩色图在 tint 下被涂成一块实心色）。
            switch rendering {
            case .tinted:     return img.withRenderingMode(.alwaysTemplate)
            case .brandColor: return img.withRenderingMode(.alwaysOriginal)
            }
        }
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        return UIImage(systemName: symbol, withConfiguration: config)

        #elseif canImport(AppKit)
        if let asset, let cached = NSImage(named: asset) {
            // ⚠️ `NSImage(named:)` 返回的是**缓存实例**；直接改 `isTemplate` 会污染
            //    其他使用点（同一个 asset 在别处被当原色图用就会跟着变成单色）。
            //    拷一份再改，代价可忽略。
            let img = (cached.copy() as? NSImage) ?? cached
            switch rendering {
            case .tinted:     img.isTemplate = true
            case .brandColor: img.isTemplate = false
            }
            return img
        }
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        // ⚠️ 标签是 `systemSymbolName:`（与 UIKit 的 `UIImage(systemName:)` **不同名**）——
        //    写 `systemName:` 编译报 incorrect argument label，别凭 iOS 的习惯手写。
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)

        #else
        _ = asset
        _ = symbol
        _ = pointSize
        return nil
        #endif
    }

    /// 这个 asset 名在**当前 bundle** 里到底有没有。
    ///
    /// SwiftUI 侧需要它：`Image("X")` 取不到 asset 时**不报错**，而是渲染空白 ——
    /// 想「有图用图、没图用符号」必须自己先问一句。
    public static func hasAsset(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return false }
        #if canImport(UIKit)
        return UIImage(named: name) != nil
        #elseif canImport(AppKit)
        return NSImage(named: name) != nil
        #else
        return false
        #endif
    }
}
