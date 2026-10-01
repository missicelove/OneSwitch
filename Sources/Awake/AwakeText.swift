import Foundation
import OneSwitchCore

/// Chinese UI strings for the Awake module (pure functions, testable).
public enum AwakeText {
    /// 1 = 周日 … 7 = 周六.
    public static func weekdayName(_ weekday: Int) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names[((weekday - 1) % 7 + 7) % 7]
    }

    /// Order of weekday toggles in the UI (周一 first).
    public static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    /// "08:00–19:00"
    public static func window(_ start: Int, _ end: Int) -> String {
        "\(Fmt.timeOfDay(start))–\(end >= 24 * 60 ? "24:00" : Fmt.timeOfDay(end))"
    }

    /// Relative moment: "昨天 10:12", "08:00" / "今天 08:00", "明天 08:00", "后天 08:00", "周一 08:00" (within a week),
    /// otherwise "10月8日 08:00".
    public static func moment(_ date: Date, now: Date, calendar: Calendar, omitToday: Bool = false) -> String {
        let c = calendar.dateComponents([.hour, .minute, .month, .day, .weekday], from: date)
        let time = Fmt.timeOfDay((c.hour ?? 0) * 60 + (c.minute ?? 0))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case -1: return "昨天 \(time)"
        case 0: return omitToday ? time : "今天 \(time)"
        case 1: return "明天 \(time)"
        case 2: return "后天 \(time)"
        case 3...6: return "\(weekdayName(c.weekday ?? 1)) \(time)"
        default: return "\(c.month ?? 1)月\(c.day ?? 1)日 \(time)"
        }
    }

    /// "10月1日 周四"
    public static func dayTitle(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.month, .day, .weekday], from: date)
        return "\(c.month ?? 1)月\(c.day ?? 1)日 \(weekdayName(c.weekday ?? 1))"
    }

    /// "工作日" / "休息日" / "休息日（国庆节）" / "休息日 · 独立日（Święto Niepodległości）" / "调休上班" /
    /// "工作日（手动指定）" / "休息日（手动指定）".
    public static func dayType(_ info: DayInfo) -> String {
        switch info.reason {
        case .regular: return info.isWorkday ? "工作日" : "休息日"
        case .holiday(let name):
            // Regional names already carry the local name in parentheses; avoid nesting them.
            return name.contains("（") ? "休息日 · \(name)" : "休息日（\(name)）"
        case .makeupWorkday: return "调休上班"
        case .manualWorkday: return "工作日（手动指定）"
        case .manualRestDay: return "休息日（手动指定）"
        }
    }

    /// Menu info line: "今天：工作日".
    public static func todayLine(_ info: DayInfo) -> String { "今天：\(dayType(info))" }

    /// One-line status for the menu:
    /// "● 已开启 · 剩余 1:23:45", "● 已开启 · 无限期", "● 已开启 · 按计划至 19:00",
    /// "○ 已关闭 · 计划于 明天 08:00 开启", "○ 已关闭".
    public static func statusLine(_ status: AwakeStatus, now: Date, calendar: Calendar) -> String {
        switch status.mode {
        case .manual:
            if let end = status.session?.endsAt {
                return "● 已开启 · 剩余 \(Fmt.clock(end.timeIntervalSince(now)))"
            }
            return "● 已开启 · 无限期"
        case .schedule:
            if let until = status.nextTransition {
                return "● 已开启 · 按计划至 \(moment(until, now: now, calendar: calendar, omitToday: true))"
            }
            return "● 已开启 · 按计划"
        case .off:
            if let next = status.nextActivation {
                return "○ 已关闭 · 计划于 \(moment(next, now: now, calendar: calendar)) 开启"
            }
            return "○ 已关闭"
        }
    }

    /// Longer explanation for the settings page.
    public static func statusDetail(_ status: AwakeStatus, settings: AwakeSettings, now: Date, calendar: Calendar) -> String {
        switch status.mode {
        case .manual:
            guard let session = status.session else { return "" }
            if let end = session.endsAt, let minutes = session.minutes {
                var s = "手动开启 \(Fmt.minutes(minutes))，将于 \(moment(end, now: now, calendar: calendar)) 自动结束"
                s += "（剩余 \(Fmt.clock(end.timeIntervalSince(now)))）"
                return s
            }
            return "手动开启（无限期），直到手动关闭"
        case .schedule:
            let until = status.nextTransition.map { "，至 \(moment($0, now: now, calendar: calendar, omitToday: true))" } ?? ""
            return "按自动计划开启（\(window(settings.startMinute, settings.endMinute))）\(until)"
        case .off:
            var s: String
            if status.suppressed {
                s = "已手动关闭，本时段内不再自动开启"
            } else if !settings.scheduleEnabled {
                s = "自动计划未启用"
            } else if !settings.hasValidWindow {
                s = "计划时段无效：结束时间必须晚于开始时间"
            } else if !status.today.isWorkday {
                s = "今天是\(dayType(status.today))，自动计划不开启"
            } else {
                s = "当前不在计划时段（\(window(settings.startMinute, settings.endMinute))）"
            }
            if let next = status.nextActivation {
                s += "；将于 \(moment(next, now: now, calendar: calendar)) 自动开启"
            }
            return s
        }
    }

    /// Menu toggle title.
    public static func toggleTitle(isActive: Bool) -> String {
        isActive ? "关闭防止锁屏" : "立即开启（无限期）"
    }

    /// "自动计划（工作日 08:00–19:00）"
    public static func scheduleMenuTitle(_ settings: AwakeSettings) -> String {
        guard settings.hasValidWindow else { return "自动计划（时段无效）" }
        return "自动计划（工作日 \(window(settings.startMinute, settings.endMinute))）"
    }

    /// Label for a duration choice in menus and pickers.
    public static func durationLabel(_ minutes: Int?) -> String {
        guard let minutes else { return "无限期" }
        return Fmt.minutes(minutes)
    }

    /// Footer of the "菜单栏图标" settings section.
    public static func statusIconFooter(_ icon: AwakeStatusIcon) -> String {
        if icon == .unchanged {
            return "防止锁屏开启时，菜单栏中的 OneSwitch 图标保持不变。"
        }
        return "防止锁屏开启时，菜单栏中的 OneSwitch 图标会变为“\(icon.title)”，关闭后恢复原样。键鼠共享正在控制另一台 Mac 时，优先显示键鼠共享的图标。"
    }

    /// Footer of the "节假日日历" settings section.
    public static func holidayFooter(selected: HolidayRegion, effective: HolidayRegion, timeZone: TimeZone) -> String {
        var s = ""
        if selected == .automatic {
            s = "自动：系统时区为中国大陆时使用中国大陆日历，为波兰（Europe/Warsaw）时使用波兰日历，其他时区不使用节假日。"
        }
        switch effective {
        case .chinaMainland:
            s += "中国大陆日历数据来自 holiday-cn（国务院办公厅发布的放假安排），每天自动更新一次，离线时使用本地缓存。放假日按休息日处理，调休补班日按工作日处理。"
        case .poland:
            s += "波兰法定假日在本机离线计算（含复活节、圣灵降临节、基督圣体节等移动节日；平安夜自 2025 年起为法定假日）。假日适逢周六时雇主须另行补休一天，可在“手动指定日期”中添加。"
        case .automatic, .disabled:
            if selected == .automatic {
                s += "当前系统时区（\(timeZone.identifier)）没有对应的节假日日历，可在上方手动选择。"
            } else {
                s += "不使用任何节假日日历。"
            }
        }
        return s
    }
}

/// Minute-of-day ⇄ Date conversion for the start / end time pickers.
public enum AwakeTimeOfDay {
    /// Reference day of the pickers (a fixed date: the picked value only carries hour and minute).
    public static let referenceDay = DateComponents(year: 2001, month: 1, day: 1)

    /// The instant at `minute` (clamped to 0…1439) on the reference day in `calendar`.
    public static func date(minute: Int, calendar: Calendar) -> Date {
        let m = min(max(minute, 0), 24 * 60 - 1)
        var c = referenceDay
        c.hour = m / 60
        c.minute = m % 60
        return calendar.date(from: c) ?? Date(timeIntervalSinceReferenceDate: TimeInterval(m * 60))
    }

    /// Wall-clock minute of `date` in `calendar`.
    public static func minute(of date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// The end minute to save for a picker showing `pickerMinute`: a stored 24:00 end (displayed as
    /// 23:59, the picker's maximum) is kept.
    public static func committedEnd(pickerMinute: Int, storedEnd: Int) -> Int {
        (pickerMinute == 24 * 60 - 1 && storedEnd == 24 * 60) ? storedEnd : pickerMinute
    }
}
