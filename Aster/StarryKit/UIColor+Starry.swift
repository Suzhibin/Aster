//
//  Starry+UIColor.swift
//  BaseModule
//
//  Created by Suzhibin on 2026/5/21.
//

import UIKit

// MARK: - 十六进制
public extension UIColor {

    /// 十六进制整数初始化（0xRRGGBB）
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8)  & 0xFF) / 255.0,
            blue:  CGFloat( hex        & 0xFF) / 255.0,
            alpha: alpha
        )
    }

    /// 十六进制字符串初始化（支持 #RGB / #RRGGBB / #AARRGGBB / RRGGBB / AARRGGBB）
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .uppercased()

        guard hex.count == 3 || hex.count == 6 || hex.count == 8 else { return nil }

        // #RGB → #RRGGBB
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }

        var rgba: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&rgba) else { return nil }

        let r, g, b, a: CGFloat
        if hex.count == 8 {
            r = CGFloat((rgba >> 24) & 0xFF) / 255.0
            g = CGFloat((rgba >> 16) & 0xFF) / 255.0
            b = CGFloat((rgba >> 8)  & 0xFF) / 255.0
            a = CGFloat( rgba        & 0xFF) / 255.0
        } else {
            r = CGFloat((rgba >> 16) & 0xFF) / 255.0
            g = CGFloat((rgba >> 8)  & 0xFF) / 255.0
            b = CGFloat( rgba        & 0xFF) / 255.0
            a = 1.0
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    /// 转为十六进制字符串（#RRGGBB），不含 alpha
    var hexString: String? {
        guard let (r, g, b, _) = rgba else { return nil }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// 转为十六进制整数（0xRRGGBB），不含 alpha
    var hex: UInt32? {
        guard let (r, g, b, _) = rgba else { return nil }
        let ri = UInt32(r * 255), gi = UInt32(g * 255), bi = UInt32(b * 255)
        return (ri << 16) | (gi << 8) | bi
    }
}

// MARK: - RGB 分量构造

public extension UIColor {

    /// RGB 分量构造（各分量 0~255，alpha 默认 1.0）
    // MARK: - 通过RGBA创建颜色
    class func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, a: CGFloat = 1) -> Self {
        Self.init(red: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
    }
}

// MARK: - 颜色分量
public extension UIColor {

    /// RGBA 分量，获取失败返回 nil
    var rgba: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (r, g, b, a)
    }
}

// MARK: - 颜色生成
public extension UIColor {

    /// 随机颜色
    static var random: UIColor {
        UIColor(
            red:   CGFloat.random(in: 0...1),
            green: CGFloat.random(in: 0...1),
            blue:  CGFloat.random(in: 0...1),
            alpha: 1.0
        )
    }
}

// MARK: - 颜色调整
public extension UIColor {

    /// 混合叠加透明度，返回不透明色
    func withAlpha(_ alpha: CGFloat) -> UIColor {
        withAlphaComponent(alpha)
    }

    /// 变亮/变暗（factor > 1 变亮，< 1 变暗）
    func brightness(_ factor: CGFloat) -> UIColor {
        guard let (r, g, b, a) = rgba else { return self }
        return UIColor(red: min(r * factor, 1),
                       green: min(g * factor, 1),
                       blue: min(b * factor, 1),
                       alpha: a)
    }
}
