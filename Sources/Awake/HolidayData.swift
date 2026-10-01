import Foundation

/// A calendar date (Gregorian, local time) independent of time zone, e.g. 2026-10-01.
public struct DayKey: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses "yyyy-MM-dd". Returns nil for malformed or out-of-range values.
    public init?(_ string: String) {
        let parts = string.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, (1...2).contains(parts[1].count), (1...2).contains(parts[2].count),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...9999).contains(y), (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The local date of `date` in `calendar` (must be Gregorian).
    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1)
    }

    /// "2026-10-01"
    public var string: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { string }

    /// Start of this day in `calendar`.
    public func startDate(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    public static func < (a: DayKey, b: DayKey) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }
}

/// One year of Chinese statutory holiday data in the holiday-cn format
/// (https://github.com/NateScarlet/holiday-cn):
/// `{"year":2026,"days":[{"name":"国庆节","date":"2026-10-01","isOffDay":true}, …]}`.
/// `isOffDay == true` → 放假 (non-workday); `false` → 调休补班 (workday, usually on a weekend).
public struct HolidayYearFile: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public var name: String
        public var date: String
        public var isOffDay: Bool

        public init(name: String, date: String, isOffDay: Bool) {
            self.name = name
            self.date = date
            self.isOffDay = isOffDay
        }
    }

    public var year: Int
    public var days: [Day]

    public init(year: Int, days: [Day]) {
        self.year = year
        self.days = days
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case invalidJSON
        case yearMismatch(expected: Int, found: Int)
        case invalidDate(String)

        public var errorDescription: String? {
            switch self {
            case .invalidJSON: return "数据格式错误"
            case .yearMismatch(let e, let f): return "年份不符（应为 \(e)，实际为 \(f)）"
            case .invalidDate(let s): return "日期格式错误：\(s)"
            }
        }
    }

    /// Decodes and validates a holiday-cn year file. Unknown keys ("$schema", "papers", …) are ignored.
    public static func parse(_ data: Data, expectedYear: Int? = nil) throws -> HolidayYearFile {
        let file: HolidayYearFile
        do {
            file = try JSONDecoder().decode(HolidayYearFile.self, from: data)
        } catch {
            throw ParseError.invalidJSON
        }
        if let expectedYear, file.year != expectedYear {
            throw ParseError.yearMismatch(expected: expectedYear, found: file.year)
        }
        for day in file.days where DayKey(day.date) == nil {
            throw ParseError.invalidDate(day.date)
        }
        return file
    }
}

/// One holiday-cn entry for a specific date.
public struct HolidayEntry: Equatable, Sendable {
    public var name: String
    /// true = 放假; false = 调休补班.
    public var isOffDay: Bool

    public init(name: String, isOffDay: Bool) {
        self.name = name
        self.isOffDay = isOffDay
    }
}

/// Holiday data merged from several year files, indexed by date.
public struct HolidayData: Equatable, Sendable {
    public private(set) var files: [Int: HolidayYearFile] = [:]
    public private(set) var days: [DayKey: HolidayEntry] = [:]

    public init() {}

    public init(files: [HolidayYearFile]) {
        for f in files { self.files[f.year] = f }
        rebuild()
    }

    /// Adds or replaces the data of `file.year`.
    public mutating func set(_ file: HolidayYearFile) {
        files[file.year] = file
        rebuild()
    }

    public func entry(for key: DayKey) -> HolidayEntry? { days[key] }

    public var years: [Int] { files.keys.sorted() }

    /// Number of entries loaded for `year` (nil when no file for that year is loaded).
    public func entryCount(forYear year: Int) -> Int? { files[year]?.days.count }

    private mutating func rebuild() {
        var map: [DayKey: HolidayEntry] = [:]
        // Later year files win on (unexpected) conflicts.
        for year in files.keys.sorted() {
            for d in files[year]?.days ?? [] {
                if let key = DayKey(d.date) { map[key] = HolidayEntry(name: d.name, isOffDay: d.isOffDay) }
            }
        }
        days = map
    }
}
