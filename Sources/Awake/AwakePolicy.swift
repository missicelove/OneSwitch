import Foundation

/// Whether a date is a workday, and why.
public struct DayInfo: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// Decided by the weekly workday setting (周一…周日).
        case regular
        /// Statutory holiday (放假) from the holiday data.
        case holiday(String)
        /// Make-up workday (调休上班) from the holiday data.
        case makeupWorkday(String)
        /// User override: 工作日.
        case manualWorkday
        /// User override: 休息日.
        case manualRestDay
    }

    public var key: DayKey
    /// `Calendar` weekday, 1 = Sunday … 7 = Saturday.
    public var weekday: Int
    public var isWorkday: Bool
    public var reason: Reason

    public init(key: DayKey, weekday: Int, isWorkday: Bool, reason: Reason) {
        self.key = key
        self.weekday = weekday
        self.isWorkday = isWorkday
        self.reason = reason
    }
}

/// One row of the "未来 7 天" preview.
public struct DayPreview: Identifiable, Equatable, Sendable {
    public var id: String { info.key.string }
    public var date: Date
    public var info: DayInfo
    /// Start / end of the active window that day, nil when the schedule does not run that day.
    public var windowStart: Date?
    public var windowEnd: Date?
}

/// Pure schedule policy: workday resolution and the automatic window, with injected calendar and
/// holiday data so it can be tested deterministically.
///
/// Workday precedence: manual date override > holiday calendar of the effective region (中国大陆: holiday-cn
/// data incl. 调休; 波兰: offline Polish holidays; none) > weekday setting.
/// `scheduleDesired(at:)` = scheduleEnabled && isWorkday && start <= minuteOfDay < end.
public struct AwakePolicy {
    public let scheduleEnabled: Bool
    public let workWeekdays: Set<Int>
    public let startMinute: Int
    public let endMinute: Int
    /// The holiday calendar in effect (`settings.holidayRegion` resolved with `calendar.timeZone`;
    /// never `.automatic`).
    public let holidayRegion: HolidayRegion
    public let overrides: [DayKey: Bool]
    public let holidays: HolidayData
    public let calendar: Calendar

    /// How far ahead `nextTransition(after:)` searches (days).
    public static let searchHorizonDays = 370

    public init(settings: AwakeSettings, holidays: HolidayData, calendar: Calendar) {
        scheduleEnabled = settings.scheduleEnabled
        workWeekdays = Set(settings.workWeekdays)
        startMinute = settings.startMinute
        endMinute = settings.endMinute
        holidayRegion = settings.holidayRegion.resolved(for: calendar.timeZone)
        var map: [DayKey: Bool] = [:]
        for (k, v) in settings.dayOverrides {
            if let key = DayKey(k) { map[key] = v }
        }
        overrides = map
        self.holidays = holidays
        self.calendar = calendar
    }

    /// True when 0 <= start < end <= 1440.
    public var hasValidWindow: Bool {
        startMinute >= 0 && endMinute <= 24 * 60 && endMinute > startMinute
    }

    /// Whether the schedule can ever be active (used to decide whether a "next" time is meaningful).
    public var isEffective: Bool { scheduleEnabled && hasValidWindow }

    // MARK: Workdays

    public func dayInfo(for date: Date) -> DayInfo {
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let key = DayKey(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
        return dayInfo(key: key, weekday: c.weekday ?? 1)
    }

    public func dayInfo(key: DayKey, weekday: Int) -> DayInfo {
        if let isWork = overrides[key] {
            return DayInfo(key: key, weekday: weekday, isWorkday: isWork, reason: isWork ? .manualWorkday : .manualRestDay)
        }
        switch holidayRegion {
        case .chinaMainland:
            if let entry = holidays.entry(for: key) {
                return DayInfo(key: key, weekday: weekday, isWorkday: !entry.isOffDay,
                               reason: entry.isOffDay ? .holiday(entry.name) : .makeupWorkday(entry.name))
            }
        case .poland:
            if let holiday = PolishHolidays.holiday(on: key) {
                return DayInfo(key: key, weekday: weekday, isWorkday: false, reason: .holiday(holiday.displayName))
            }
        case .automatic, .disabled:
            break
        }
        return DayInfo(key: key, weekday: weekday, isWorkday: workWeekdays.contains(weekday), reason: .regular)
    }

    public func isWorkday(_ date: Date) -> Bool { dayInfo(for: date).isWorkday }

    // MARK: Window

    /// Wall-clock minutes since local midnight (0…1439).
    public func minuteOfDay(_ date: Date) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    public func scheduleDesired(at date: Date) -> Bool {
        guard isEffective else { return false }
        guard dayInfo(for: date).isWorkday else { return false }
        let m = minuteOfDay(date)
        return m >= startMinute && m < endMinute
    }

    /// The instant at wall-clock `minute` (0…1440) of the day that starts at `dayStart`.
    public func instant(dayStart: Date, minute: Int) -> Date? {
        if minute >= 24 * 60 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
            return calendar.startOfDay(for: next)
        }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: dayStart,
                             matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    /// The first instant strictly after `date` at which `scheduleDesired` changes value, or nil when it
    /// never changes within the search horizon (schedule off, no workdays, …).
    public func nextTransition(after date: Date) -> Date? {
        guard isEffective else { return nil }
        let current = scheduleDesired(at: date)
        var day = calendar.startOfDay(for: date)
        for _ in 0..<Self.searchHorizonDays {
            if dayInfo(for: day).isWorkday {
                for minute in [startMinute, endMinute] {
                    // `scheduleDesired` is constant between consecutive candidate instants, so the first
                    // candidate whose value differs from the current one is the transition.
                    if let t = instant(dayStart: day, minute: minute), t > date, scheduleDesired(at: t) != current {
                        return t
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = calendar.startOfDay(for: next)
        }
        return nil
    }

    /// The next instant after `date` at which the schedule switches ON (skipping a currently running window).
    public func nextActivation(after date: Date) -> Date? {
        var t = date
        for _ in 0..<2 {
            guard let next = nextTransition(after: t) else { return nil }
            if scheduleDesired(at: next) { return next }
            t = next
        }
        return nil
    }

    /// The day containing `date` and the following `days - 1` days.
    public func preview(from date: Date, days: Int) -> [DayPreview] {
        var result: [DayPreview] = []
        var day = calendar.startOfDay(for: date)
        for _ in 0..<max(0, days) {
            let info = dayInfo(for: day)
            var start: Date?
            var end: Date?
            if isEffective && info.isWorkday {
                start = instant(dayStart: day, minute: startMinute)
                end = instant(dayStart: day, minute: endMinute)
            }
            result.append(DayPreview(date: day, info: info, windowStart: start, windowEnd: end))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }
        return result
    }
}

public extension Calendar {
    /// Gregorian calendar in the current system time zone (holiday dates are Gregorian even when the
    /// user's preferred calendar is e.g. the Chinese lunar calendar).
    static func awakeSystem() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        c.locale = Locale(identifier: "zh_Hans_CN")
        return c
    }
}
