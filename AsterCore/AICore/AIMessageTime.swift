//
//  AIMessageTime.swift
//  AIModule
//
//  消息时间戳的格式化与「什么时候该显示」的判定。
//
//  抽成一份的原因和 `AITypography` 一样：**显示与量行高必须同源**。
//  时间文案的宽度决定了它会不会换行，而换行会改变行高 —— 两处各写一份格式，
//  迟早出现「量的时候一行、显示出来两行」把下一条消息挤变形。
//

import Foundation

public enum AIMessageTime {

    /// 两条消息间隔超过这个时长，就该在下面那条上方重新报一次时间。
    ///
    /// 5 分钟是聊天类 App 的常见取值：连着一问一答（几秒到一两分钟）时不刷屏，
    /// 走开一会儿再回来能立刻看出「这是新的一段」。
    public static let gapThreshold: TimeInterval = 5 * 60

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    /// 时间文案。
    ///
    /// 今天只给时分（同一天里再写日期纯属噪音），昨天/更早才补日期，
    /// **跨年再补年份** —— 否则去年 3 月 5 日和今年 3 月 5 日在界面上完全一样。
    public static func string(from date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                  calendar.isDate(date, inSameDayAs: yesterday) {
            formatter.dateFormat = L("昨天 HH:mm")
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = L("M月d日 HH:mm")
        } else {
            formatter.dateFormat = L("yyyy年M月d日 HH:mm")
        }
        return formatter.string(from: date)
    }

    /// **完整**的时间文案 —— `M月d日 HH:mm`，跨年才在前面补年份。
    ///
    /// 与 `string(from:now:)` 的差别只在**省不省日期**：那边是气泡上方那行小字，
    /// 走的是省略式（同一天里再写日期是噪音）；这里是**每条消息都要报时间**的位置
    /// （Mac 每条消息操作栏的末尾，2026-09-21 用户指定），省了就看不出是哪天。
    ///
    /// 两个方法共用同一个 `formatter`，格式串也只存在于本文件 ——
    /// ⛔ 视图层别自己 new 一个 `DateFormatter`，那种「两边各写一遍」正是本文件开头防的事。
    public static func fullString(from date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? L("M月d日 HH:mm")
            : L("yyyy年M月d日 HH:mm")
        return formatter.string(from: date)
    }

    /// 距离上一条消息是否已经隔得够久（`previous == nil` = 这是第一条）
    public static func needsSeparator(since previous: Date?, to current: Date) -> Bool {
        guard let previous = previous else { return true }
        // 时钟回拨（手动改时间 / 跨设备导入）时差值为负，按「需要分隔」处理更安全
        return current.timeIntervalSince(previous) >= gapThreshold
            || current.timeIntervalSince(previous) < 0
    }
}
