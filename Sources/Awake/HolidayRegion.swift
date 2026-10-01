import Foundation

/// Which public-holiday calendar decides 工作日 / 休息日 (setting "节假日日历").
public enum HolidayRegion: String, Codable, CaseIterable, Sendable {
    /// 自动（根据系统时区）: mainland-China zones → 中国大陆, Europe/Warsaw → 波兰, anything else → 不使用.
    case automatic
    /// 中国大陆（含调休）: holiday-cn data (downloaded, cached), including make-up workdays.
    case chinaMainland
    /// 波兰: Polish statutory holidays, computed offline.
    case poland
    /// 不使用节假日: only the weekly workdays and manual date overrides count.
    case disabled

    /// Picker label.
    public var title: String {
        switch self {
        case .automatic: return "自动（根据系统时区）"
        case .chinaMainland: return "中国大陆（含调休）"
        case .poland: return "波兰"
        case .disabled: return "不使用节假日"
        }
    }

    /// Short name of a resolved region ("中国大陆" / "波兰" / "不使用节假日").
    public var shortName: String {
        switch self {
        case .automatic: return "自动"
        case .chinaMainland: return "中国大陆"
        case .poland: return "波兰"
        case .disabled: return "不使用节假日"
        }
    }

    /// Time zones of mainland China (Hong Kong, Macau and Taiwan have different holidays and are not
    /// included). Legacy aliases are listed because `TimeZone.current` may report them verbatim.
    public static let mainlandChinaTimeZones: Set<String> = [
        "Asia/Shanghai", "Asia/Chongqing", "Asia/Chungking", "Asia/Harbin", "Asia/Urumqi", "Asia/Kashgar", "PRC",
    ]
    /// Time zones of Poland.
    public static let polandTimeZones: Set<String> = ["Europe/Warsaw", "Poland"]

    /// The region `automatic` maps to in `timeZone`.
    public static func automaticRegion(for timeZone: TimeZone) -> HolidayRegion {
        let id = timeZone.identifier
        if mainlandChinaTimeZones.contains(id) { return .chinaMainland }
        if polandTimeZones.contains(id) { return .poland }
        return .disabled
    }

    /// The concrete region in effect (never `.automatic`).
    public func resolved(for timeZone: TimeZone) -> HolidayRegion {
        self == .automatic ? Self.automaticRegion(for: timeZone) : self
    }
}

// MARK: - Day arithmetic (pure, time-zone independent)

public extension DayKey {
    /// Days since 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant's days_from_civil).
    var dayNumber: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = month > 2 ? month - 3 : month + 9
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// The date `dayNumber` days after 1970-01-01.
    init(dayNumber: Int) {
        let z = dayNumber + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(year: yoe + era * 400 + (m <= 2 ? 1 : 0), month: m, day: d)
    }

    func adding(days: Int) -> DayKey { DayKey(dayNumber: dayNumber + days) }
}

// MARK: - Polish public holidays (offline)

/// A public holiday with its Chinese name and its official local name.
public struct RegionalHoliday: Equatable, Sendable {
    public var date: DayKey
    public var chineseName: String
    public var localName: String

    public init(date: DayKey, chineseName: String, localName: String) {
        self.date = date
        self.chineseName = chineseName
        self.localName = localName
    }

    /// "复活节星期一（Poniedziałek Wielkanocny）"
    public var displayName: String { "\(chineseName)（\(localName)）" }
}

/// Polish statutory days off (ustawa o dniach wolnych od pracy), computed without network access.
public enum PolishHolidays {
    /// Wigilia (24 Dec) is a statutory day off from 2025 on.
    public static let wigiliaFirstYear = 2025
    /// Trzech Króli (6 Jan) is a statutory day off again since 2011.
    public static let epiphanyFirstYear = 2011

    /// Easter Sunday (anonymous Gregorian algorithm, Meeus/Jones/Butcher).
    public static func easterSunday(year: Int) -> DayKey {
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let n = h + l - 7 * m + 114
        return DayKey(year: year, month: n / 31, day: n % 31 + 1)
    }

    /// All holidays of `year`, in date order.
    public static func holidays(year: Int) -> [RegionalHoliday] {
        let easter = easterSunday(year: year)
        var list: [RegionalHoliday] = []
        func fixed(_ month: Int, _ day: Int, _ zh: String, _ pl: String) {
            list.append(RegionalHoliday(date: DayKey(year: year, month: month, day: day), chineseName: zh, localName: pl))
        }
        func movable(_ offset: Int, _ zh: String, _ pl: String) {
            list.append(RegionalHoliday(date: easter.adding(days: offset), chineseName: zh, localName: pl))
        }
        fixed(1, 1, "元旦", "Nowy Rok")
        if year >= epiphanyFirstYear { fixed(1, 6, "主显节", "Trzech Króli") }
        movable(0, "复活节", "Wielkanoc")
        movable(1, "复活节星期一", "Poniedziałek Wielkanocny")
        fixed(5, 1, "劳动节", "Święto Pracy")
        fixed(5, 3, "宪法日", "Święto Konstytucji 3 Maja")
        movable(49, "圣灵降临节", "Zielone Świątki")
        movable(60, "基督圣体节", "Boże Ciało")
        fixed(8, 15, "圣母升天节", "Wniebowzięcie NMP")
        fixed(11, 1, "诸圣节", "Wszystkich Świętych")
        fixed(11, 11, "独立日", "Święto Niepodległości")
        if year >= wigiliaFirstYear { fixed(12, 24, "平安夜", "Wigilia") }
        fixed(12, 25, "圣诞节", "Boże Narodzenie")
        fixed(12, 26, "圣诞节第二天", "drugi dzień Bożego Narodzenia")
        return list.sorted { $0.date < $1.date }
    }

    /// The holiday on `key`, if any. Pure integer arithmetic — cheap enough for per-day schedule scans.
    public static func holiday(on key: DayKey) -> RegionalHoliday? {
        switch (key.month, key.day) {
        case (1, 1), (1, 6), (5, 1), (5, 3), (8, 15), (11, 1), (11, 11), (12, 24), (12, 25), (12, 26):
            return holidays(year: key.year).first { $0.date == key }
        case (3, _), (4, _), (5, _), (6, _):
            // Easter falls on 22 Mar … 25 Apr, so Corpus Christi (Easter + 60) is 21 May … 24 Jun.
            let offset = key.dayNumber - easterSunday(year: key.year).dayNumber
            guard [0, 1, 49, 60].contains(offset) else { return nil }
            return holidays(year: key.year).first { $0.date == key }
        default:
            return nil
        }
    }

    /// The next `limit` holidays on or after `from`.
    public static func upcoming(from: DayKey, limit: Int) -> [RegionalHoliday] {
        var result: [RegionalHoliday] = []
        var year = from.year
        while result.count < limit && year <= from.year + 2 {
            result += holidays(year: year).filter { $0.date >= from }
            year += 1
        }
        return Array(result.prefix(limit))
    }
}
