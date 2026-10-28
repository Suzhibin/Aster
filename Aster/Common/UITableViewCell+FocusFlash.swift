//
//  UITableViewCell+FocusFlash.swift
//  AIModule
//
//  搜索结果定位用：整行闪一下，告诉用户「就是这一条」。
//
//  为什么闪**整行底色**而不是给气泡描个圈：
//  气泡有蓝底（用户消息）和浅灰底（助手消息）两种，一个描边色不可能兼顾 ——
//  蓝描边落在蓝气泡上等于没画。整行底色是中性的，两种气泡上都成立。
//

import UIKit

extension UITableViewCell {

    /// 定位高亮的底色。用 systemYellow 的半透明：与两种气泡底色都不撞，暗黑模式下也看得见。
    private static var focusFlashColor: UIColor {
        UIColor.systemYellow.withAlphaComponent(0.22)
    }

    /// 闪一下（无则不动）。重复调用安全：只是把底色重新点亮一次。
    ///
    /// 时序：立刻点亮 → 停 0.6s → 0.9s 内淡出。
    /// 先亮后淡而不是「渐入渐出」，是因为它出现在**滚动动画结束的同时**，
    /// 那时候如果还在渐入，用户会以为是自己看花了。
    func flashFocusHighlight() {
        contentView.backgroundColor = Self.focusFlashColor
        UIView.animate(withDuration: 0.9,
                       delay: 0.6,
                       options: [.beginFromCurrentState]) {
            self.contentView.backgroundColor = .clear
        }
    }
}
