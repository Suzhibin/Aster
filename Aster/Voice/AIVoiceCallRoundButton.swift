//
//  AIVoiceCallRoundButton.swift
//  Aster
//
//  通话页底部那一排**圆形按钮**（参考图 4 颗，直径 60pt）。
//
//  ## 用 `UIControl` 而不是 `UIButton`
//  这一排按钮**没有文字、没有高亮态、也没有 `UIButton` 那套 contentInsets** ——
//  要的只是「一个圆 + 正中间一个 SF Symbol + 按下去有个反馈」。
//  用 `UIButton` 反而要跟它的默认 inset / 触摸放大 / tintColor 叠色打架
//  （`UIButton` 会把 SF Symbol 当模板图**再套一层 tint**，红色那颗叉就是这么被染成洋红的）。
//
//  ## 🔴 `style` 是**语义**，不是装饰
//  参考图里最左那颗是**白底实心**、其余是半透明 —— 这不是随机配色：
//  白底 = **当前生效的那一档**。
//  🔴 2026-10-12：第 2 颗（静音）删掉后，「麦克风」**一颗钮承载两态** ——
//    拾音中 = 白底 + `mic.fill`；已静音 = 玻璃底 + `mic.slash.fill`
//    （见 `AIVoiceCallControlsView.setMuted(_:)`；换符号走 `setSystemName(_:)`）。
//  ⛔ 别把它当成「按下态」去用 —— 按下态是 `isHighlighted`，两者互不相干。
//
//  ## 深色页（2026-10-11）：白底那颗**不动**，其余换"深色玻璃 + 浅图标"
//  底从浅粉换成深空后，原来那几颗"半透明白底"（压在深空上 ≈ 中灰）配深图标偏糊。
//  ⇒ 未生效的那几颗改成**低透明白（≈ 深灰玻璃）+ 近白图标**；白底那颗仍是白底深图标（深色页的焦点）。
//  图标色因此**跟着 style 走**（`Style.defaultIconColor`），只有挂断那颗显式给红。
//

import UIKit
import SnapKit

final class AIVoiceCallRoundButton: UIControl {

    enum Style {
        /// 白底实心 = **当前生效**（图标取深）
        case filled
        /// 深色玻璃底 = 未生效 / 次要（图标取浅）
        case translucent

        /// 该档的默认图标色（深色页：白底配深图标、玻璃底配浅图标，见 `AIVoiceCallPalette`）
        var defaultIconColor: UIColor {
            switch self {
            case .filled: return AIVoiceCallPalette.buttonIconOnFilled
            case .translucent: return AIVoiceCallPalette.buttonIconOnTranslucent
            }
        }
    }

    var style: Style = .translucent {
        didSet { if oldValue != style { applyStyle() } }
    }

    /// 图标色。`nil`（默认）= **跟随 `style`**（见 `Style.defaultIconColor`）。
    /// 只有"图片标不跟底走"的那颗（挂断的红）才显式赋值，赋了会压过 style 默认色。
    var iconColor: UIColor? {
        didSet { if oldValue != iconColor { applyStyle() } }
    }

    private let iconView = UIImageView()

    /// 当前图标的字号 / 粗细。
    /// 🔴 换符号时要照**同一组**参数重建（见 `setSystemName(_:)`）—— 否则一颗钮的两态
    ///    会一大一小（`mic.fill` 与 `mic.slash.fill` 的包围盒本来就不一样）。
    private let iconPointSize: CGFloat
    private let iconWeight: UIImage.SymbolWeight

    // MARK: - 初始化

    /// - Parameters:
    ///   - systemName: SF Symbol 名（本工程 target iOS 15，⛔ 别用 16+ 才有的符号）
    ///   - pointSize: 图标字号（参考图：图标高 ≈ 直径的 0.4）
    ///   - weight: 符号粗细（挂断那颗叉在图上明显更粗）
    init(systemName: String, pointSize: CGFloat, weight: UIImage.SymbolWeight = .medium) {
        self.iconPointSize = pointSize
        self.iconWeight = weight
        super.init(frame: .zero)
        iconView.image = Self.symbol(named: systemName, pointSize: pointSize, weight: weight)
        iconView.contentMode = .center
        iconView.isUserInteractionEnabled = false
        addSubview(iconView)
        iconView.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        applyStyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func symbol(named name: String, pointSize: CGFloat,
                               weight: UIImage.SymbolWeight) -> UIImage? {
        // ⚠️ 必须写全 `UIImage.SymbolConfiguration`：`withConfiguration:` 的形参声明类型是
        //    基类 `UIImage.Configuration?`，用 `.init(pointSize:weight:)` 简写会去基类上找
        //    这个初始化器 ⇒ 编译不过（"no exact matches in call to initializer"）。
        UIImage(systemName: name,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight))
    }

    // MARK: - 换符号

    /// 换一颗 SF Symbol。**只有「麦克风」那颗会用到**。
    ///
    /// 第 2 颗（静音）2026-10-12 删掉后，麦克风**一颗钮承载两态** ⇒ 图标得跟着态走
    /// （`mic.fill` = 拾音中 / `mic.slash.fill` = 已静音）。只靠底色分不出是哪一态时，
    /// 用户会以为"麦关了 / 麦开了"而反复点 —— 这正是本页最典型的**不报错**的困惑。
    /// ⚠️ 沿用 init 那一组字号与粗细，⛔ 别在这里另给尺寸。
    func setSystemName(_ name: String) {
        iconView.image = Self.symbol(named: name, pointSize: iconPointSize, weight: iconWeight)
    }

    // MARK: - 外观

    private func applyStyle() {
        switch style {
        case .filled:
            backgroundColor = AIVoiceCallPalette.buttonFilled
        case .translucent:
            backgroundColor = AIVoiceCallPalette.buttonTranslucent
        }
        // 🔴 图标上色**只有这一个入口**。
        //    `UIImage(systemName:)` 给的是**模板图**（`.alwaysTemplate`）⇒ 实际颜色由 tintColor 决定。
        //    ⛔ 别用 `UIColor` 去画一颗彩色的符号图（那要 `withTintColor(_:renderingMode:)`，
        //    而它会把图上色成**位图**，深浅色/尺寸一变就糊）；⛔ 也别给 `iconView.image` 设
        //    `.alwaysOriginal` —— 那样红色会变成图里自带的黑，朱红就没了。
        //    ⚠️ 底一翻深，图标就必须跟着翻浅（深图标压在深玻璃上是看不见的）⇒ 默认跟随 style；
        //       只有挂断那颗显式给红（`iconColor`）时以它为准。
        iconView.tintColor = iconColor ?? style.defaultIconColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 圆角恒为边长一半（⛔ 别写死 30：改直径时这里要跟着走）
        let side = min(bounds.width, bounds.height)
        if layer.cornerRadius != side / 2 { layer.cornerRadius = side / 2 }
    }

    // MARK: - 按下反馈

    override var isHighlighted: Bool {
        didSet {
            guard oldValue != isHighlighted else { return }
            UIView.animate(withDuration: 0.12) {
                self.alpha = self.isHighlighted ? 0.72 : 1
            }
        }
    }
}
