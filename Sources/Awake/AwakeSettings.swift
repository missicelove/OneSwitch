import Foundation
import OneSwitchCore

/// Limits and presets for manual 防止锁屏 sessions.
public enum AwakeLimits {
    public static let minSessionMinutes = 5
    public static let maxSessionMinutes = 12 * 60
    public static let sessionStepMinutes = 5
    /// 5, 10, 15, 30 min, 1, 2, 3, 4, 6, 8, 12 h.
    public static let presetMinutes = [5, 10, 15, 30, 60, 120, 180, 240, 360, 480, 720]

    /// `AwakeSettings.manualChoice` sentinel: 无限期 (until turned off).
    public static let choiceInfinite = -1
    /// `AwakeSettings.manualChoice` sentinel: 自定义 (uses `customMinutes`).
    public static let choiceCustom = 0

    /// Clamps to 5…720 and rounds to the 5-minute step.
    public static func clampSession(_ minutes: Int) -> Int {
        let clamped = min(max(minutes, minSessionMinutes), maxSessionMinutes)
        let step = sessionStepMinutes
        return min(maxSessionMinutes, max(minSessionMinutes, (clamped + step / 2) / step * step))
    }
}

/// Persisted user settings of the Awake module (`SettingsStore` key "awake.settings").
///
/// Decoding tolerates missing keys (each falls back to its default), so adding fields never loses
/// the user's existing choices — including optional fields such as `hotKey`.
public struct AwakeSettings: Codable, Equatable {
    // Automatic schedule (自动计划)
    public var scheduleEnabled: Bool
    /// `Calendar` weekday numbers (1 = Sunday … 7 = Saturday) that count as workdays.
    public var workWeekdays: [Int]
    /// Window start / end as minutes since midnight. Valid when 0 <= start < end <= 1440.
    public var startMinute: Int
    public var endMinute: Int
    /// 节假日日历 (default: 自动 — by system time zone).
    public var holidayRegion: HolidayRegion
    /// Manual per-date overrides: "yyyy-MM-dd" → true (工作日) / false (休息日).
    public var dayOverrides: [String: Bool]

    // Options (选项)
    public var simulateUserActivity: Bool
    public var notifyOnEnd: Bool
    public var hotKey: HotKey?
    /// 菜单栏图标: the main status-bar icon while active (default 闪电; added after the first release —
    /// settings saved before it decode with the default and keep every other field).
    public var statusIcon: AwakeStatusIcon

    // Manual session UI state (手动开启)
    /// Custom duration in minutes (5…720, step 5).
    public var customMinutes: Int
    /// Selected duration in the settings picker: a preset in minutes, `AwakeLimits.choiceInfinite`
    /// or `AwakeLimits.choiceCustom`.
    public var manualChoice: Int

    public init(scheduleEnabled: Bool = true,
                workWeekdays: [Int] = [2, 3, 4, 5, 6],
                startMinute: Int = 8 * 60,
                endMinute: Int = 19 * 60,
                holidayRegion: HolidayRegion = .automatic,
                dayOverrides: [String: Bool] = [:],
                simulateUserActivity: Bool = true,
                notifyOnEnd: Bool = true,
                hotKey: HotKey? = nil,
                statusIcon: AwakeStatusIcon = .defaultChoice,
                customMinutes: Int = 90,
                manualChoice: Int = 60) {
        self.scheduleEnabled = scheduleEnabled
        self.workWeekdays = workWeekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.holidayRegion = holidayRegion
        self.dayOverrides = dayOverrides
        self.simulateUserActivity = simulateUserActivity
        self.notifyOnEnd = notifyOnEnd
        self.hotKey = hotKey
        self.statusIcon = statusIcon
        self.customMinutes = customMinutes
        self.manualChoice = manualChoice
    }

    enum CodingKeys: String, CodingKey {
        case scheduleEnabled, workWeekdays, startMinute, endMinute, holidayRegion, dayOverrides
        case simulateUserActivity, notifyOnEnd, hotKey, statusIcon, customMinutes, manualChoice
    }

    /// Keys written by earlier versions (read for migration only, never written).
    enum LegacyCodingKeys: String, CodingKey {
        /// Bool "使用中国法定节假日与调休安排" (default true). Migrates to `holidayRegion`:
        /// false → 不使用节假日; true (the old default) → 自动, which still means 中国大陆 in China's
        /// time zones but no longer imposes Chinese holidays / 调休 on a Mac set to e.g. Europe/Warsaw.
        case useChineseHolidays
    }

    public init(from decoder: Decoder) throws {
        let d = AwakeSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scheduleEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .scheduleEnabled)) ?? d.scheduleEnabled
        workWeekdays = (try? c.decodeIfPresent([Int].self, forKey: .workWeekdays)) ?? d.workWeekdays
        startMinute = (try? c.decodeIfPresent(Int.self, forKey: .startMinute)) ?? d.startMinute
        endMinute = (try? c.decodeIfPresent(Int.self, forKey: .endMinute)) ?? d.endMinute
        if let region = try? c.decodeIfPresent(HolidayRegion.self, forKey: .holidayRegion) {
            holidayRegion = region
        } else if let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self),
                  let useChinese = try? legacy.decodeIfPresent(Bool.self, forKey: .useChineseHolidays) {
            holidayRegion = useChinese ? .automatic : .disabled
        } else {
            holidayRegion = d.holidayRegion
        }
        dayOverrides = (try? c.decodeIfPresent([String: Bool].self, forKey: .dayOverrides)) ?? d.dayOverrides
        simulateUserActivity = (try? c.decodeIfPresent(Bool.self, forKey: .simulateUserActivity)) ?? d.simulateUserActivity
        notifyOnEnd = (try? c.decodeIfPresent(Bool.self, forKey: .notifyOnEnd)) ?? d.notifyOnEnd
        hotKey = (try? c.decodeIfPresent(HotKey.self, forKey: .hotKey)) ?? d.hotKey
        // Missing (older builds) or unknown (newer builds) → 闪电.
        statusIcon = (try? c.decodeIfPresent(AwakeStatusIcon.self, forKey: .statusIcon)) ?? d.statusIcon
        customMinutes = (try? c.decodeIfPresent(Int.self, forKey: .customMinutes)) ?? d.customMinutes
        manualChoice = (try? c.decodeIfPresent(Int.self, forKey: .manualChoice)) ?? d.manualChoice
        self = sanitized
    }

    /// True when 0 <= start < end <= 1440.
    public var hasValidWindow: Bool {
        startMinute >= 0 && endMinute <= 24 * 60 && endMinute > startMinute
    }

    /// Settings with out-of-range values repaired (weekdays deduplicated and in 1…7, durations clamped).
    public var sanitized: AwakeSettings {
        var s = self
        s.workWeekdays = Array(Set(workWeekdays.filter { (1...7).contains($0) })).sorted()
        s.startMinute = min(max(startMinute, 0), 24 * 60 - 1)
        s.endMinute = min(max(endMinute, 1), 24 * 60)
        s.customMinutes = AwakeLimits.clampSession(customMinutes)
        if manualChoice != AwakeLimits.choiceInfinite && manualChoice != AwakeLimits.choiceCustom
            && !AwakeLimits.presetMinutes.contains(manualChoice) {
            s.manualChoice = 60
        }
        s.dayOverrides = dayOverrides.filter { DayKey($0.key) != nil }
        return s
    }

    /// Duration (minutes) selected in the settings picker; nil = 无限期.
    public var selectedDurationMinutes: Int? {
        switch manualChoice {
        case AwakeLimits.choiceInfinite: return nil
        case AwakeLimits.choiceCustom: return AwakeLimits.clampSession(customMinutes)
        default: return AwakeLimits.clampSession(manualChoice)
        }
    }
}
