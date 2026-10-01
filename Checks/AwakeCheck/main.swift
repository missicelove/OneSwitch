import Foundation
import AppKit
import SwiftUI
import IOKit.pwr_mgt
import OneSwitchCore
import Awake

// Self-checks for the Awake module (防止锁屏). Exit code 0 = all checks passed.

/// Real holiday-cn data for 2026 (fetched from fastly.jsdelivr.net, reformatted one entry per line).
let holiday2026JSON = #"""
{
  "$schema": "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/schema.json",
  "$id": "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/2026.json",
  "year": 2026,
  "papers": ["https://www.gov.cn/zhengce/zhengceku/202511/content_7047091.htm"],
  "days": [
    {"name": "元旦", "date": "2026-01-01", "isOffDay": true},
    {"name": "元旦", "date": "2026-01-02", "isOffDay": true},
    {"name": "元旦", "date": "2026-01-03", "isOffDay": true},
    {"name": "元旦", "date": "2026-01-04", "isOffDay": false},
    {"name": "春节", "date": "2026-02-14", "isOffDay": false},
    {"name": "春节", "date": "2026-02-15", "isOffDay": true},
    {"name": "春节", "date": "2026-02-16", "isOffDay": true},
    {"name": "春节", "date": "2026-02-17", "isOffDay": true},
    {"name": "春节", "date": "2026-02-18", "isOffDay": true},
    {"name": "春节", "date": "2026-02-19", "isOffDay": true},
    {"name": "春节", "date": "2026-02-20", "isOffDay": true},
    {"name": "春节", "date": "2026-02-21", "isOffDay": true},
    {"name": "春节", "date": "2026-02-22", "isOffDay": true},
    {"name": "春节", "date": "2026-02-23", "isOffDay": true},
    {"name": "春节", "date": "2026-02-28", "isOffDay": false},
    {"name": "清明节", "date": "2026-04-04", "isOffDay": true},
    {"name": "清明节", "date": "2026-04-05", "isOffDay": true},
    {"name": "清明节", "date": "2026-04-06", "isOffDay": true},
    {"name": "劳动节", "date": "2026-05-01", "isOffDay": true},
    {"name": "劳动节", "date": "2026-05-02", "isOffDay": true},
    {"name": "劳动节", "date": "2026-05-03", "isOffDay": true},
    {"name": "劳动节", "date": "2026-05-04", "isOffDay": true},
    {"name": "劳动节", "date": "2026-05-05", "isOffDay": true},
    {"name": "劳动节", "date": "2026-05-09", "isOffDay": false},
    {"name": "端午节", "date": "2026-06-19", "isOffDay": true},
    {"name": "端午节", "date": "2026-06-20", "isOffDay": true},
    {"name": "端午节", "date": "2026-06-21", "isOffDay": true},
    {"name": "国庆节", "date": "2026-09-20", "isOffDay": false},
    {"name": "中秋节", "date": "2026-09-25", "isOffDay": true},
    {"name": "中秋节", "date": "2026-09-26", "isOffDay": true},
    {"name": "中秋节", "date": "2026-09-27", "isOffDay": true},
    {"name": "国庆节", "date": "2026-10-01", "isOffDay": true},
    {"name": "国庆节", "date": "2026-10-02", "isOffDay": true},
    {"name": "国庆节", "date": "2026-10-03", "isOffDay": true},
    {"name": "国庆节", "date": "2026-10-04", "isOffDay": true},
    {"name": "国庆节", "date": "2026-10-05", "isOffDay": true},
    {"name": "国庆节", "date": "2026-10-06", "isOffDay": true},
    {"name": "国庆节", "date": "2026-10-07", "isOffDay": true},
    {"name": "国庆节", "date": "2026-10-10", "isOffDay": false}
  ]
}
"""#

// MARK: - Helpers

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message) (line \(line))")
    }
}

/// Spins the main run loop until `condition` is true or `timeout` elapses.
@MainActor
func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

let shanghai: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    c.locale = Locale(identifier: "zh_Hans_CN")
    return c
}()

func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0, calendar: Calendar = shanghai) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
}

func fmt(_ d: Date?) -> String {
    guard let d else { return "nil" }
    let f = DateFormatter()
    f.calendar = shanghai
    f.timeZone = shanghai.timeZone
    f.dateFormat = "yyyy-MM-dd HH:mm:ss EEE"
    return f.string(from: d)
}

/// Lines of `pmset -g assertions` owned by this process.
func pmsetLinesForSelf() -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g", "assertions"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let me = "pid \(getpid())("
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { $0.contains(me) }
}

/// Assertions of this process as reported by powerd: [(type, name)].
func ownAssertions() -> [(type: String, name: String)] {
    var dict: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
          let map = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
    return (map[NSNumber(value: getpid())] ?? []).map {
        (type: $0["AssertType"] as? String ?? "", name: $0["AssertName"] as? String ?? "")
    }
}

/// UserDefaults that keeps everything in memory. A real scratch suite cannot be used: even after
/// `removePersistentDomain` + deleting its plist, cfprefsd re-creates an empty
/// ~/Library/Preferences/<suite>.plist when the process exits, leaving files behind on this Mac.
final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() { super.init(suiteName: nil)! }

    private func get(_ key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    private func put(_ key: String, _ value: Any?) { lock.lock(); values[key] = value; lock.unlock() }

    override func object(forKey defaultName: String) -> Any? { get(defaultName) }
    override func set(_ value: Any?, forKey defaultName: String) { put(defaultName, value) }
    override func removeObject(forKey defaultName: String) { put(defaultName, nil) }
    override func data(forKey defaultName: String) -> Data? { get(defaultName) as? Data }
    override func string(forKey defaultName: String) -> String? { get(defaultName) as? String }
    override func double(forKey defaultName: String) -> Double { (get(defaultName) as? NSNumber)?.doubleValue ?? 0 }
    override func integer(forKey defaultName: String) -> Int { (get(defaultName) as? NSNumber)?.intValue ?? 0 }
    override func bool(forKey defaultName: String) -> Bool { (get(defaultName) as? NSNumber)?.boolValue ?? false }
    override func set(_ value: Double, forKey defaultName: String) { put(defaultName, NSNumber(value: value)) }
    override func set(_ value: Int, forKey defaultName: String) { put(defaultName, NSNumber(value: value)) }
    override func set(_ value: Bool, forKey defaultName: String) { put(defaultName, NSNumber(value: value)) }
    override func dictionaryRepresentation() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return values }
    override func synchronize() -> Bool { true }
}

/// Scratch defaults for one group of checks (in memory; `name` only documents the purpose).
func withScratchDefaults<T>(_ name: String, _ body: (UserDefaults) throws -> T) rethrows -> T {
    try body(InMemoryDefaults())
}

@MainActor
final class FakePower: AwakePowerControlling {
    var isHolding = false
    var simulating = false
    var applyCount = 0
    var releaseAllCount = 0
    func apply(active: Bool, simulateActivity: Bool) {
        applyCount += 1
        isHolding = active
        simulating = active && simulateActivity
    }
    func releaseAll() {
        releaseAllCount += 1
        isHolding = false
        simulating = false
    }
}

// MARK: - Checks

@MainActor
func runChecks() throws {
    // ------------------------------------------------------------------
    print("Holiday JSON parsing (real holiday-cn 2026 sample)")
    let file = try HolidayYearFile.parse(Data(holiday2026JSON.utf8), expectedYear: 2026)
    check(file.year == 2026 && file.days.count == 39, "parsed 39 entries for 2026 (got \(file.days.count))")
    check(file.days.first == .init(name: "元旦", date: "2026-01-01", isOffDay: true), "first entry 元旦 2026-01-01 off")
    check(file.days.contains(.init(name: "国庆节", date: "2026-10-10", isOffDay: false)), "调休 2026-10-10 is a workday entry")
    var threw: HolidayYearFile.ParseError?
    do { _ = try HolidayYearFile.parse(Data(holiday2026JSON.utf8), expectedYear: 2027) } catch { threw = error as? HolidayYearFile.ParseError }
    check(threw == .yearMismatch(expected: 2027, found: 2026), "year mismatch rejected")
    threw = nil
    do { _ = try HolidayYearFile.parse(Data("<html>rate limited</html>".utf8)) } catch { threw = error as? HolidayYearFile.ParseError }
    check(threw == .invalidJSON, "non-JSON rejected")
    threw = nil
    do { _ = try HolidayYearFile.parse(Data(#"{"year":2026,"days":[{"name":"x","date":"2026/10/01","isOffDay":true}]}"#.utf8)) } catch { threw = error as? HolidayYearFile.ParseError }
    check(threw == .invalidDate("2026/10/01"), "malformed date rejected")
    let empty2027 = try HolidayYearFile.parse(Data(#"{"$schema":"x","year":2027,"papers":[],"days":[]}"#.utf8), expectedYear: 2027)
    check(empty2027.days.isEmpty, "unpublished year (empty days) parses")
    check(DayKey("2026-10-01") == DayKey(year: 2026, month: 10, day: 1) && DayKey("2026-13-01") == nil && DayKey("20261001") == nil,
          "DayKey parsing")
    check(DayKey(date(2026, 10, 1, 0, 0, 0), calendar: shanghai).string == "2026-10-01", "DayKey from date at midnight")

    let holidays = HolidayData(files: [file])
    let base = AwakeSettings()
    func policy(_ mutate: (inout AwakeSettings) -> Void = { _ in }) -> AwakePolicy {
        var s = base
        mutate(&s)
        return AwakePolicy(settings: s, holidays: holidays, calendar: shanghai)
    }
    let p = policy()

    // ------------------------------------------------------------------
    print("Defaults")
    check(base.scheduleEnabled && base.workWeekdays == [2, 3, 4, 5, 6] && base.startMinute == 480 && base.endMinute == 1140,
          "default schedule: Mon–Fri 08:00–19:00 enabled")
    check(base.holidayRegion == .automatic && base.simulateUserActivity && base.notifyOnEnd, "holidays 自动 / activity / notify default ON")
    check(base.statusIcon == .bolt && AwakeStatusIcon.defaultChoice == .bolt, "菜单栏图标 defaults to 闪电")

    // ------------------------------------------------------------------
    print("Policy truth table")
    let table: [(String, Date, AwakePolicy, Bool)] = [
        ("Tue 09-29 10:00 in window", date(2026, 9, 29, 10), p, true),
        ("Tue 07:59:59 before window", date(2026, 9, 29, 7, 59, 59), p, false),
        ("Tue 08:00 window start inclusive", date(2026, 9, 29, 8), p, true),
        ("Tue 18:59:59 inside", date(2026, 9, 29, 18, 59, 59), p, true),
        ("Tue 19:00 window end exclusive", date(2026, 9, 29, 19), p, false),
        ("Sat 10-17 weekend", date(2026, 10, 17, 10), p, false),
        ("Fri 09-25 中秋 holiday on weekday", date(2026, 9, 25, 10), p, false),
        ("Thu 10-01 国庆 holiday", date(2026, 10, 1, 10), p, false),
        ("Sun 09-20 调休 on weekend", date(2026, 9, 20, 10), p, true),
        ("Sat 10-10 调休 on weekend", date(2026, 10, 10, 10), p, true),
        ("holidays off: Thu 10-01 regular weekday", date(2026, 10, 1, 10), policy { $0.holidayRegion = .disabled }, true),
        ("holidays off: Sat 10-10 regular weekend", date(2026, 10, 10, 10), policy { $0.holidayRegion = .disabled }, false),
        ("override 工作日 beats holiday 10-01", date(2026, 10, 1, 10), policy { $0.dayOverrides = ["2026-10-01": true] }, true),
        ("override 休息日 beats 调休 10-10", date(2026, 10, 10, 10), policy { $0.dayOverrides = ["2026-10-10": false] }, false),
        ("override 休息日 on weekday", date(2026, 9, 29, 10), policy { $0.dayOverrides = ["2026-09-29": false] }, false),
        ("schedule disabled", date(2026, 9, 29, 10), policy { $0.scheduleEnabled = false }, false),
        ("invalid window end <= start", date(2026, 9, 29, 10), policy { $0.startMinute = 600; $0.endMinute = 600 }, false),
        ("custom weekdays: Sat only (no holidays)", date(2026, 10, 17, 10), policy { $0.workWeekdays = [7]; $0.holidayRegion = .disabled }, true),
        ("custom weekdays: Mon excluded", date(2026, 10, 19, 10), policy { $0.workWeekdays = [7]; $0.holidayRegion = .disabled }, false),
    ]
    for (name, d, pol, expected) in table {
        check(pol.scheduleDesired(at: d) == expected, "\(name) → \(expected)")
    }
    check(p.dayInfo(for: date(2026, 10, 1, 12)).reason == .holiday("国庆节"), "10-01 reason holiday(国庆节)")
    check(p.dayInfo(for: date(2026, 10, 10, 12)).reason == .makeupWorkday("国庆节"), "10-10 reason makeupWorkday")
    check(AwakeText.dayType(p.dayInfo(for: date(2026, 10, 1))) == "休息日（国庆节）", "label 休息日（国庆节）")
    check(AwakeText.todayLine(p.dayInfo(for: date(2026, 10, 10))) == "今天：调休上班", "label 今天：调休上班")
    check(AwakeText.todayLine(p.dayInfo(for: date(2026, 9, 29))) == "今天：工作日", "label 今天：工作日")
    check(AwakeText.todayLine(p.dayInfo(for: date(2026, 10, 17))) == "今天：休息日", "label 今天：休息日")
    check(AwakeText.dayType(policy { $0.dayOverrides = ["2026-10-01": true] }.dayInfo(for: date(2026, 10, 1))) == "工作日（手动指定）",
          "label 工作日（手动指定）")

    // ------------------------------------------------------------------
    print("nextTransition / nextActivation")
    func expectTransition(_ pol: AwakePolicy, _ from: Date, _ expected: Date?, _ name: String, line: Int = #line) {
        let got = pol.nextTransition(after: from)
        check(got == expected, "\(name): \(fmt(got))", line: line)
    }
    expectTransition(p, date(2026, 9, 29, 10), date(2026, 9, 29, 19), "Tue 10:00 → Tue 19:00")
    expectTransition(p, date(2026, 9, 29, 19), date(2026, 9, 30, 8), "Tue 19:00 (exact end) → Wed 08:00")
    expectTransition(p, date(2026, 9, 29, 7), date(2026, 9, 29, 8), "Tue 07:00 → Tue 08:00")
    expectTransition(p, date(2026, 9, 30, 20), date(2026, 10, 8, 8), "Wed 09-30 20:00 → Thu 10-08 08:00 (国庆 skipped)")
    expectTransition(p, date(2026, 10, 9, 19, 30), date(2026, 10, 10, 8), "Fri 10-09 19:30 → Sat 10-10 08:00 (调休)")
    expectTransition(p, date(2026, 10, 16, 20), date(2026, 10, 19, 8), "Fri 10-16 20:00 → Mon 10-19 08:00 (weekend)")
    expectTransition(p, date(2026, 9, 24, 12), date(2026, 9, 24, 19), "Thu 09-24 12:00 → 19:00")
    check(p.nextActivation(after: date(2026, 9, 24, 12)) == date(2026, 9, 28, 8),
          "nextActivation from Thu 09-24 12:00 skips 中秋 → Mon 09-28 08:00: \(fmt(p.nextActivation(after: date(2026, 9, 24, 12))))")
    expectTransition(policy { $0.holidayRegion = .disabled }, date(2026, 9, 30, 20), date(2026, 10, 1, 8), "holidays off: Wed 20:00 → Thu 08:00")
    expectTransition(policy { $0.scheduleEnabled = false }, date(2026, 9, 29, 10), nil, "schedule disabled → nil")
    expectTransition(policy { $0.workWeekdays = []; $0.holidayRegion = .disabled }, date(2026, 9, 29, 10), nil, "no workdays → nil")
    expectTransition(policy { $0.startMinute = 0; $0.endMinute = 1440; $0.holidayRegion = .disabled },
                     date(2026, 10, 12, 10), date(2026, 10, 17, 0), "all-day window Mon–Fri: Mon → Sat 00:00")
    expectTransition(policy { $0.dayOverrides = ["2026-10-03": true] }, date(2026, 9, 30, 20), date(2026, 10, 3, 8),
                     "override 工作日 inside holiday → 10-03 08:00")

    // DST correctness (America/New_York, DST ends 2026-11-01).
    var ny = Calendar(identifier: .gregorian)
    ny.timeZone = TimeZone(identifier: "America/New_York")!
    let pNY = AwakePolicy(settings: base, holidays: HolidayData(), calendar: ny)
    let nyNext = pNY.nextTransition(after: date(2026, 10, 30, 20, calendar: ny))
    check(nyNext == date(2026, 11, 2, 8, calendar: ny), "DST week: Fri 20:00 → Mon 08:00 local (\(nyNext.map { ny.component(.hour, from: $0) } ?? -1)h)")

    // Preview
    let preview = p.preview(from: date(2026, 9, 30, 15), days: 7)
    check(preview.count == 7 && preview.map(\.info.isWorkday) == [true, false, false, false, false, false, false],
          "未来 7 天 from 09-30: workday then 国庆 holidays")
    check(preview[0].windowStart == date(2026, 9, 30, 8) && preview[0].windowEnd == date(2026, 9, 30, 19), "preview window 08:00–19:00")
    check(preview[1].windowStart == nil, "no window on holiday")

    // ------------------------------------------------------------------
    print("State machine: suppression")
    var e = AwakeEngine()
    var r = e.evaluate(policy: p, now: date(2026, 9, 29, 10))
    check(r.status.mode == .schedule && r.status.isActive, "Tue 10:00 active by schedule")
    check(AwakeText.statusLine(r.status, now: date(2026, 9, 29, 10), calendar: shanghai) == "● 已开启 · 按计划至 19:00",
          "status line: ● 已开启 · 按计划至 19:00")
    e.turnOff(policy: p, now: date(2026, 9, 29, 10))
    check(e.state.suppressed, "关闭 during window → suppressed")
    r = e.evaluate(policy: p, now: date(2026, 9, 29, 10, 30))
    check(r.status.mode == .off && r.status.suppressed, "stays off within window")
    check(r.status.nextActivation == date(2026, 9, 30, 8), "next activation tomorrow 08:00")
    check(AwakeText.statusLine(r.status, now: date(2026, 9, 29, 10, 30), calendar: shanghai) == "○ 已关闭 · 计划于 明天 08:00 开启",
          "status line: ○ 已关闭 · 计划于 明天 08:00 开启")
    r = e.evaluate(policy: p, now: date(2026, 9, 29, 18, 59, 59))
    check(r.status.mode == .off, "still off at 18:59:59")
    r = e.evaluate(policy: p, now: date(2026, 9, 29, 19))
    check(r.status.mode == .off && !r.status.suppressed && r.suppressionCleared, "19:00 transition clears suppression, off")
    r = e.evaluate(policy: p, now: date(2026, 9, 30, 8))
    check(r.status.mode == .schedule, "Wed 08:00 active again")

    print("State machine: transitions missed while asleep")
    var e2 = AwakeEngine()
    _ = e2.evaluate(policy: p, now: date(2026, 9, 29, 18))
    e2.turnOff(policy: p, now: date(2026, 9, 29, 18))
    r = e2.evaluate(policy: p, now: date(2026, 9, 30, 9))
    check(r.status.mode == .schedule && r.suppressionCleared, "suppression cleared by missed 19:00/08:00 transitions")
    var e3 = AwakeEngine()
    _ = e3.evaluate(policy: p, now: date(2026, 9, 29, 18))
    e3.turnOff(policy: p, now: date(2026, 9, 30, 9)) // first action after wake, before any evaluation
    r = e3.evaluate(policy: p, now: date(2026, 9, 30, 9, 5))
    check(r.status.mode == .off && r.status.suppressed, "关闭 right after wake is not undone by the stale transition")

    print("State machine: manual sessions")
    var e4 = AwakeEngine()
    _ = e4.evaluate(policy: p, now: date(2026, 9, 29, 10))
    e4.turnOff(policy: p, now: date(2026, 9, 29, 10))
    e4.startSession(minutes: 30, now: date(2026, 9, 29, 10, 5))
    check(!e4.state.suppressed, "manual start clears suppression")
    r = e4.evaluate(policy: p, now: date(2026, 9, 29, 10, 5))
    check(r.status.mode == .manual && r.status.nextDeadline == date(2026, 9, 29, 10, 35), "timed session active, deadline = its end")
    r = e4.evaluate(policy: p, now: date(2026, 9, 29, 10, 35))
    check(r.expiredSession?.minutes == 30 && r.status.mode == .schedule, "session expiry inside window → schedule keeps it on")

    var e5 = AwakeEngine()
    e5.startSession(minutes: 60, now: date(2026, 9, 29, 18, 30))
    r = e5.evaluate(policy: p, now: date(2026, 9, 29, 18, 30))
    check(r.status.mode == .manual && r.status.nextDeadline == date(2026, 9, 29, 19), "18:30 +60 min: next deadline 19:00 (transition)")
    r = e5.evaluate(policy: p, now: date(2026, 9, 29, 19))
    check(r.status.mode == .manual && r.status.nextDeadline == date(2026, 9, 29, 19, 30), "past window end: manual keeps running until 19:30")
    r = e5.evaluate(policy: p, now: date(2026, 9, 29, 19, 29, 59))
    check(r.status.mode == .manual, "19:29:59 still on")
    check(AwakeText.statusLine(r.status, now: date(2026, 9, 29, 19, 29, 59), calendar: shanghai) == "● 已开启 · 剩余 0:01",
          "countdown 0:01")
    r = e5.evaluate(policy: p, now: date(2026, 9, 29, 19, 30))
    check(r.status.mode == .off && r.expiredSession != nil, "19:30 session over, off")

    var e6 = AwakeEngine()
    e6.startSession(minutes: 120, now: date(2026, 10, 17, 10))
    r = e6.evaluate(policy: p, now: date(2026, 10, 17, 10, 36, 15))
    check(AwakeText.statusLine(r.status, now: date(2026, 10, 17, 10, 36, 15), calendar: shanghai) == "● 已开启 · 剩余 1:23:45",
          "status line: ● 已开启 · 剩余 1:23:45")

    var e7 = AwakeEngine()
    e7.startSession(minutes: nil, now: date(2026, 10, 17, 10))
    r = e7.evaluate(policy: p, now: date(2026, 10, 19, 12))
    check(r.status.mode == .manual && r.status.session?.isInfinite == true, "infinite session survives days")
    check(AwakeText.statusLine(r.status, now: date(2026, 10, 19, 12), calendar: shanghai) == "● 已开启 · 无限期", "status line 无限期")
    e7.turnOff(policy: p, now: date(2026, 10, 19, 12))
    r = e7.evaluate(policy: p, now: date(2026, 10, 19, 12))
    check(r.status.mode == .off && r.status.suppressed, "关闭 infinite session inside window → off + suppressed")
    var e8 = AwakeEngine()
    e8.startSession(minutes: nil, now: date(2026, 10, 17, 10))
    e8.turnOff(policy: p, now: date(2026, 10, 17, 11))
    check(!e8.state.suppressed && e8.state.session == nil, "关闭 on weekend: no suppression")

    var e9 = AwakeEngine()
    e9.startSession(minutes: 3, now: date(2026, 10, 17, 10))
    check(e9.state.session?.minutes == 5, "duration clamped to ≥ 5 min")
    e9.startSession(minutes: 1000, now: date(2026, 10, 17, 10))
    check(e9.state.session?.minutes == 720 && e9.state.session?.endsAt == date(2026, 10, 17, 22), "duration clamped to ≤ 12 h")
    check(AwakeLimits.clampSession(7) == 5 && AwakeLimits.clampSession(8) == 10 && AwakeLimits.clampSession(719) == 720, "5-min step rounding")

    print("State machine: settings changes")
    var e10 = AwakeEngine()
    _ = e10.evaluate(policy: p, now: date(2026, 9, 29, 10))
    e10.turnOff(policy: p, now: date(2026, 9, 29, 10))
    let pEnd20 = policy { $0.endMinute = 20 * 60 }
    r = e10.evaluate(policy: pEnd20, now: date(2026, 9, 29, 10, 1))
    check(r.status.mode == .off && r.status.suppressed, "moving window end keeps suppression (scheduleDesired unchanged)")
    r = e10.evaluate(policy: pEnd20, now: date(2026, 9, 29, 19, 30))
    check(r.status.mode == .off, "still suppressed at 19:30 with new end 20:00")
    r = e10.evaluate(policy: pEnd20, now: date(2026, 9, 29, 20))
    check(!r.status.suppressed, "cleared at the new end 20:00")
    var e11 = AwakeEngine()
    _ = e11.evaluate(policy: p, now: date(2026, 9, 29, 10))
    e11.turnOff(policy: p, now: date(2026, 9, 29, 10))
    r = e11.evaluate(policy: policy { $0.scheduleEnabled = false }, now: date(2026, 9, 29, 10, 1))
    check(r.status.mode == .off && !r.status.suppressed, "disabling the schedule clears suppression")
    r = e11.evaluate(policy: p, now: date(2026, 9, 29, 10, 2))
    check(r.status.mode == .schedule, "re-enabling → active again")

    print("Status texts")
    var e12 = AwakeEngine()
    r = e12.evaluate(policy: p, now: date(2026, 10, 16, 20))
    check(AwakeText.statusLine(r.status, now: date(2026, 10, 16, 20), calendar: shanghai) == "○ 已关闭 · 计划于 周一 08:00 开启",
          "Fri evening: ○ 已关闭 · 计划于 周一 08:00 开启")
    r = e12.evaluate(policy: p, now: date(2026, 9, 30, 20))
    check(AwakeText.statusLine(r.status, now: date(2026, 9, 30, 20), calendar: shanghai) == "○ 已关闭 · 计划于 10月8日 08:00 开启",
          "before 国庆: ○ 已关闭 · 计划于 10月8日 08:00 开启")
    r = e12.evaluate(policy: policy { $0.scheduleEnabled = false }, now: date(2026, 9, 29, 10))
    check(AwakeText.statusLine(r.status, now: date(2026, 9, 29, 10), calendar: shanghai) == "○ 已关闭", "schedule off: ○ 已关闭")
    check(AwakeText.scheduleMenuTitle(base) == "自动计划（工作日 08:00–19:00）", "schedule menu title")
    check(AwakeText.moment(date(2026, 9, 29, 8), now: date(2026, 9, 29, 7), calendar: shanghai) == "今天 08:00", "moment 今天")
    check(AwakeText.moment(date(2026, 10, 1, 8), now: date(2026, 9, 29, 7), calendar: shanghai) == "后天 08:00", "moment 后天")
    check(AwakeText.moment(date(2026, 9, 28, 10, 12), now: date(2026, 9, 29, 7), calendar: shanghai) == "昨天 10:12", "moment 昨天")
    check(AwakeText.moment(date(2026, 9, 20, 10, 12), now: date(2026, 9, 29, 7), calendar: shanghai) == "9月20日 10:12", "moment older date")
    check(AwakeText.toggleTitle(isActive: false) == "立即开启（无限期）" && AwakeText.toggleTitle(isActive: true) == "关闭防止锁屏",
          "toggle titles")

    print("Settings decoding")
    let decodedEmpty = try JSONDecoder().decode(AwakeSettings.self, from: Data("{}".utf8))
    check(decodedEmpty == AwakeSettings(), "missing keys fall back to defaults")
    var custom = AwakeSettings()
    custom.hotKey = HotKey(keyCode: 37, modifiers: [.control, .option])
    custom.dayOverrides = ["2026-10-01": true]
    let roundTrip = try JSONDecoder().decode(AwakeSettings.self, from: JSONEncoder().encode(custom))
    check(roundTrip == custom, "settings round-trip incl. hotKey and overrides")
    let partial = try JSONDecoder().decode(AwakeSettings.self, from: Data(#"{"startMinute":540,"hotKey":{"keyCode":37,"modifiers":786432}}"#.utf8))
    check(partial.startMinute == 540 && partial.hotKey?.keyCode == 37 && partial.endMinute == 1140, "partial JSON keeps stored values incl. optional hotKey")
    let insane = try JSONDecoder().decode(AwakeSettings.self, from: Data(#"{"workWeekdays":[0,2,2,9],"customMinutes":3,"manualChoice":77}"#.utf8))
    check(insane.workWeekdays == [2] && insane.customMinutes == 5 && insane.manualChoice == 60, "out-of-range values sanitized")

    try statusIconChecks()
    try holidayRegionChecks(holidays: holidays)
    try controllerChecks()
    try statusIconControllerChecks()
    try regionControllerChecks()
    try holidayCancelCheck()
    assertionChecks()
    liveNetworkCheck()
}

// MARK: - 菜单栏图标 (status-bar icon while active)

/// `awake.settings` exactly as a build without 菜单栏图标 wrote it (every other field customised).
let legacyAwakeSettingsJSON = #"""
{"scheduleEnabled":false,"workWeekdays":[2,3,4,5,6,7],"startMinute":540,"endMinute":1260,"holidayRegion":"poland",
"dayOverrides":{"2026-10-08":false},"simulateUserActivity":false,"notifyOnEnd":false,
"hotKey":{"keyCode":37,"modifiers":786432},"customMinutes":45,"manualChoice":0}
"""#

/// `awake.settings` as the build deployed before 菜单栏图标 actually stored it on both Macs (read with
/// `defaults export com.oneswitch.app`, all values at their defaults, key order as written).
let deployedAwakeSettingsJSON: [(String, String)] = [
    ("Mac Studio", #"{"startMinute":480,"dayOverrides":{},"scheduleEnabled":true,"notifyOnEnd":true,"endMinute":1140,"customMinutes":90,"holidayRegion":"automatic","manualChoice":60,"workWeekdays":[2,3,4,5,6],"simulateUserActivity":true}"#),
    ("MacBook Pro", #"{"workWeekdays":[2,3,4,5,6],"manualChoice":60,"startMinute":480,"endMinute":1140,"scheduleEnabled":true,"customMinutes":90,"dayOverrides":{},"simulateUserActivity":true,"holidayRegion":"automatic","notifyOnEnd":true}"#),
]

/// True when `item` shows the SF Symbol `name` (compares the rendered images).
@MainActor
func menuItemShowsSymbol(_ item: NSMenuItem, _ name: String) -> Bool {
    guard let shown = item.image?.tiffRepresentation,
          let expected = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.tiffRepresentation else { return false }
    return shown == expected
}

/// Spins the main run loop in the menu-tracking mode (as while a menu is open) until `condition` holds.
@MainActor
func spinWhileMenuTracking(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    // NSApplication makes the tracking mode a common mode (so `.common` timers fire while a menu is open);
    // this check process has no NSApplication, so do the same here (idempotent).
    CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
    }
    return condition()
}

/// True when `s` carries every customised value of `legacyAwakeSettingsJSON`.
func keepsLegacyFields(_ s: AwakeSettings, hotKey: Bool = true) -> Bool {
    !s.scheduleEnabled && s.workWeekdays == [2, 3, 4, 5, 6, 7] && s.startMinute == 540 && s.endMinute == 1260
        && s.holidayRegion == .poland && s.dayOverrides == ["2026-10-08": false] && !s.simulateUserActivity
        && !s.notifyOnEnd && (!hotKey || s.hotKey == HotKey(keyCode: 37, modifiers: [.control, .option]))
        && s.customMinutes == 45 && s.manualChoice == AwakeLimits.choiceCustom
}

@MainActor
func statusIconChecks() throws {
    print("菜单栏图标: choices and SF Symbol availability")
    let all = AwakeStatusIcon.allCases
    check(all.map(\.title) == ["闪电", "眼睛", "太阳", "显示器", "灯泡", "电源", "咖啡杯", "不改变图标"], "choice titles in order")
    check(all.map(\.activeSymbol) == ["bolt.fill", "eye.fill", "sun.max.fill", "display", "lightbulb.fill", "power",
                                     "cup.and.saucer.fill", nil], "status-bar symbols (不改变图标 → nil)")
    check(Set(all.map(\.rawValue)).count == all.count && Set(all.compactMap(\.activeSymbol)).count == all.count - 1,
          "raw values and symbols are unique")
    for icon in all {
        if let symbol = icon.activeSymbol {
            check(AwakeStatusIcon.isSymbolAvailable(symbol), "\(icon.title): status-bar symbol \(symbol) exists on this macOS")
            check(icon.resolvedActiveSymbol() == symbol, "\(icon.title): resolves to its own symbol")
        } else {
            check(icon.resolvedActiveSymbol() == nil, "\(icon.title): no override")
        }
        if let outline = icon.outlineSymbol {
            check(AwakeStatusIcon.isSymbolAvailable(outline) && icon.resolvedMenuSymbol() == outline,
                  "\(icon.title): menu symbol \(outline) exists")
        }
        check(AwakeStatusIcon.isSymbolAvailable(icon.previewSymbol), "\(icon.title): picker symbol \(icon.previewSymbol) exists")
    }
    check((AwakeStatusIcon.fallbackActiveSymbols + [AwakeStatusIcon.genericMenuSymbol, "stop.circle"]).allSatisfy(AwakeStatusIcon.isSymbolAvailable),
          "fallback symbols exist")
    check(!AwakeStatusIcon.isSymbolAvailable("oneswitch.no.such.symbol"), "a missing symbol is reported as missing")
    check(AwakeStatusIcon.pickerChoices == all, "the picker offers all 8 choices on this macOS")
    check(AwakeStatusIcon.unchanged.resolvedMenuSymbol() == "play.circle", "不改变图标: generic menu symbol")

    print("菜单栏图标: fallback when a symbol is missing")
    check(AwakeStatusIcon.eye.resolvedActiveSymbol(isAvailable: { $0 != "eye.fill" }) == "bolt.fill", "missing eye.fill → bolt.fill")
    check(AwakeStatusIcon.eye.resolvedActiveSymbol(isAvailable: { !["eye.fill", "bolt.fill"].contains($0) }) == "cup.and.saucer.fill",
          "missing eye.fill and bolt.fill → cup.and.saucer.fill")
    check(AwakeStatusIcon.bolt.resolvedActiveSymbol(isAvailable: { _ in false }) == nil, "nothing available → nil (app keeps its icon)")
    check(AwakeStatusIcon.unchanged.resolvedActiveSymbol(isAvailable: { _ in true }) == nil, "不改变图标 → nil even when all exist")
    check(AwakeStatusIcon.sun.resolvedMenuSymbol(isAvailable: { _ in false }) == "play.circle", "missing menu symbol → play.circle")

    print("菜单栏图标: menu toggle item symbol")
    check(all.allSatisfy { $0.menuToggleSymbol(isActive: true) == "stop.circle" }, "active → stop.circle for every choice")
    check(all.map { $0.menuToggleSymbol(isActive: false) }
            == ["bolt", "eye", "sun.max", "display", "lightbulb", "power", "cup.and.saucer", "play.circle"],
          "off → the chosen icon's outline (不改变图标 → play.circle)")
    check(AwakeStatusIcon.eye.menuToggleSymbol(isActive: false, isAvailable: { _ in false }) == "play.circle",
          "off with a missing outline symbol → play.circle")

    print("菜单栏图标: texts")
    check(AwakeText.statusIconFooter(.bolt).contains("“闪电”") && !AwakeText.statusIconFooter(.bolt).contains("咖啡"),
          "footer names the chosen icon (no coffee wording)")
    check(AwakeText.statusIconFooter(.unchanged) == "防止锁屏开启时，菜单栏中的 OneSwitch 图标保持不变。", "footer for 不改变图标")

    print("菜单栏图标: settings decoding and migration")
    let legacy = try JSONDecoder().decode(AwakeSettings.self, from: Data(legacyAwakeSettingsJSON.utf8))
    check(legacy.statusIcon == .bolt, "settings without the field → 闪电")
    check(keepsLegacyFields(legacy), "…and every other stored field is kept")
    for (name, json) in deployedAwakeSettingsJSON {
        let decoded = try JSONDecoder().decode(AwakeSettings.self, from: Data(json.utf8))
        check(decoded == AwakeSettings() && decoded.statusIcon == .bolt, "\(name): the deployed build's stored settings → 闪电, all fields kept")
    }
    let unknown = try JSONDecoder().decode(AwakeSettings.self, from: Data(#"{"statusIcon":"rocket","startMinute":600,"notifyOnEnd":false}"#.utf8))
    check(unknown.statusIcon == .bolt && unknown.startMinute == 600 && !unknown.notifyOnEnd, "unknown icon value → 闪电, other fields kept")
    let wrongType = try JSONDecoder().decode(AwakeSettings.self, from: Data(#"{"statusIcon":5,"endMinute":1200}"#.utf8))
    check(wrongType.statusIcon == .bolt && wrongType.endMinute == 1200, "mistyped icon value → 闪电")
    for icon in all {
        var s = AwakeSettings()
        s.statusIcon = icon
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AwakeSettings.self, from: data)
        check(decoded.statusIcon == icon && decoded == s, "\(icon.title) round-trips")
    }
    var unchanged = AwakeSettings()
    unchanged.statusIcon = .unchanged
    let unchangedJSON = String(decoding: try JSONEncoder().encode(unchanged), as: UTF8.self)
    check(unchangedJSON.contains(#""statusIcon":"none""#), "不改变图标 is stored explicitly (never omitted → 闪电)")

    // Through SettingsStore, as at app launch after an update.
    withScratchDefaults("oneswitch.awakecheck.icon.store") { defaults in
        let key = AwakeController.settingsKey
        defaults.set(Data(legacyAwakeSettingsJSON.utf8), forKey: key)
        let store = SettingsStore(key: key, defaultValue: AwakeSettings(), defaults: defaults)
        check(store.value.statusIcon == .bolt && keepsLegacyFields(store.value), "SettingsStore migration: 闪电 + old fields kept")
        check(defaults.data(forKey: key + ".unreadable") == nil, "old data decodes (not set aside as unreadable)")
        store.update { $0.statusIcon = .unchanged }
        let relaunched = SettingsStore(key: key, defaultValue: AwakeSettings(), defaults: defaults)
        check(relaunched.value.statusIcon == .unchanged && keepsLegacyFields(relaunched.value), "不改变图标 persists across relaunch")
    }
    // A value this build does not know (e.g. written by a newer build) reads as 闪电 but is not rewritten
    // just by launching: it survives until the user changes a setting.
    withScratchDefaults("oneswitch.awakecheck.icon.newer") { defaults in
        let key = AwakeController.settingsKey
        let newer = Data(#"{"statusIcon":"rocket","startMinute":600,"notifyOnEnd":false}"#.utf8)
        defaults.set(newer, forKey: key)
        let store = SettingsStore(key: key, defaultValue: AwakeSettings(), defaults: defaults)
        check(store.value.statusIcon == .bolt && store.value.startMinute == 600 && !store.value.notifyOnEnd,
              "SettingsStore: unknown icon value → 闪电, other fields kept")
        check(defaults.data(forKey: key) == newer && defaults.data(forKey: key + ".unreadable") == nil,
              "…and loading leaves the stored data untouched")
    }
}

@MainActor
func statusIconControllerChecks() throws {
    print("菜单栏图标: live refresh through the module")
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("AwakeCheckIcon-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    withScratchDefaults("oneswitch.awakecheck.icon") { defaults in
        statusIconControllerChecks(defaults: defaults, tmp: tmp)
    }
}

@MainActor
func statusIconControllerChecks(defaults: UserDefaults, tmp: URL) {
    // Legacy settings without the hotkey: starting the module must not register a real global hotkey.
    var legacy = try! JSONSerialization.jsonObject(with: Data(legacyAwakeSettingsJSON.utf8)) as! [String: Any]
    legacy["hotKey"] = nil
    defaults.set(try! JSONSerialization.data(withJSONObject: legacy), forKey: AwakeController.settingsKey)

    let offset = date(2026, 10, 17, 10).timeIntervalSinceNow // Sat; schedule disabled in the legacy settings
    let fake = FakePower()
    let controller = AwakeController(defaults: defaults, dataDirectory: tmp, power: fake,
                                     holidayURLTemplates: ["file://\(tmp.path)/none/{year}.json"],
                                     clock: { Date().addingTimeInterval(offset) }, calendar: { shanghai },
                                     notifier: { _, _ in }, bootTime: { date(2026, 9, 1) })
    check(controller.settings.statusIcon == .bolt && keepsLegacyFields(controller.settings, hotKey: false),
          "controller loads legacy settings: 闪电 + old fields kept")
    let module = AwakeModule(controller: controller)
    check(module.symbolName == "bolt", "settings sidebar symbol is no longer a coffee cup")

    // The app's refresh handler records the symbol it would draw at that moment.
    let seen = Box<[String]>([])
    AppContext.shared.install(openSettings: { _ in }, refreshStatusIcon: { [weak module] in
        seen.value.append(module?.statusIconSymbol ?? "<app icon>")
    })
    defer { AppContext.shared.install(openSettings: { _ in }, refreshStatusIcon: {}) }

    // A choice saved before start() (the store is only mirrored while running) is picked up by start().
    controller.store.update { $0.statusIcon = .sun }
    module.start()
    _ = waitUntil(0.3) { false } // holiday cache load + first evaluation
    check(controller.settings.statusIcon == .sun && keepsLegacyFields(controller.settings, hotKey: false),
          "start() picks up a choice saved before it (太阳), other fields kept")
    controller.store.update { $0.statusIcon = .bolt }
    check(controller.status.mode == .off && module.statusIconSymbol == nil, "off → no icon override")
    check(seen.value.last == "<app icon>", "start() refreshes the icon")

    controller.startSession(minutes: nil)
    check(seen.value.last == "bolt.fill" && module.statusIconSymbol == "bolt.fill", "activation → 闪电 (bolt.fill)")
    var count = seen.value.count
    controller.store.update { $0.statusIcon = .eye }
    check(seen.value.count == count + 1 && seen.value.last == "eye.fill",
          "choosing 眼睛 refreshes at once and the refresh already sees eye.fill")
    controller.store.value.statusIcon = .display // the settings picker's binding path
    check(seen.value.last == "display" && module.statusIconSymbol == "display", "choosing 显示器 via the binding path")
    controller.store.update { $0.statusIcon = .unchanged }
    check(seen.value.last == "<app icon>" && module.statusIconSymbol == nil, "不改变图标 → normal icon while active")
    controller.store.update { $0.statusIcon = .sun }
    check(seen.value.last == "sun.max.fill", "choosing 太阳 while active")
    count = seen.value.count
    controller.store.update { $0.notifyOnEnd.toggle() }
    check(seen.value.count == count, "an unrelated settings change does not refresh the icon")

    // The menu is open (its items are in a menu, the run loop is in the tracking mode) when the state flips:
    // the live update must switch the toggle item's title AND symbol.
    let liveItems = module.menuItems()
    let liveMenu = NSMenu()
    liveItems.forEach(liveMenu.addItem)
    check(liveItems[1].title == "关闭防止锁屏" && menuItemShowsSymbol(liveItems[1], "stop.circle")
            && !menuItemShowsSymbol(liveItems[1], "sun.max"), "open menu while active: 关闭 item with stop.circle")
    controller.turnOff()
    check(seen.value.last == "<app icon>" && module.statusIconSymbol == nil, "deactivation → normal icon")
    check(spinWhileMenuTracking(2.5) { liveItems[1].title == "立即开启（无限期）" }, "open menu: toggle title follows the state")
    check(menuItemShowsSymbol(liveItems[1], "sun.max"), "open menu: toggle symbol follows the state (stop.circle → 太阳 outline)")
    liveMenu.removeAllItems()

    count = seen.value.count
    controller.store.update { $0.statusIcon = .lightbulb }
    check(seen.value.count == count + 1 && module.statusIconSymbol == nil, "changing while off refreshes, no override yet")
    // Activation and a new choice in one settings change: every refresh already sees the new symbol.
    count = seen.value.count
    controller.store.update { $0.scheduleEnabled = true; $0.statusIcon = .eye } // Sat 10:00 is in the legacy window
    check(controller.status.mode == .schedule && module.statusIconSymbol == "eye.fill", "schedule on + 眼睛 in one change → eye.fill")
    check(seen.value.count > count && seen.value[count...].allSatisfy { $0 == "eye.fill" }, "…and no refresh drew a stale icon")
    controller.store.update { $0.scheduleEnabled = false; $0.statusIcon = .lightbulb }
    check(controller.status.mode == .off && seen.value.last == "<app icon>" && module.statusIconSymbol == nil,
          "schedule off + 灯泡 in one change → normal icon")
    let items = module.menuItems()
    check(items[1].title == "立即开启（无限期）" && menuItemShowsSymbol(items[1], "lightbulb"),
          "menu toggle item shows the chosen icon's outline (灯泡)")
    controller.startSession(minutes: 30)
    check(seen.value.last == "lightbulb.fill" && module.statusIconSymbol == "lightbulb.fill", "activation → 灯泡")
    let reloaded = SettingsStore(key: AwakeController.settingsKey, defaultValue: AwakeSettings(), defaults: defaults)
    check(reloaded.value.statusIcon == .lightbulb && reloaded.value.startMinute == 540, "choice persisted with the other settings")

    module.stop()
    check(!fake.isHolding && !module.isMenuLive, "module stop releases power and the menu timer")
    count = seen.value.count
    controller.store.update { $0.statusIcon = .power }
    check(seen.value.count == count, "no icon refreshes after stop()")
    check(controller.status.isActive && module.statusIconSymbol == nil,
          "stopped: no icon override although the persisted session has not ended (no assertion is held)")

    // Restart: the choice made while stopped applies at once.
    module.start()
    check(controller.settings.statusIcon == .power && seen.value.last == "power" && module.statusIconSymbol == "power",
          "restart picks up the choice made while stopped (电源)")
    check(waitUntil(1) { fake.isHolding }, "restart re-applies the running session")
    module.stop()
    check(!fake.isHolding && !module.isMenuLive && module.statusIconSymbol == nil, "second stop releases everything")
}

// MARK: - Holiday regions (节假日日历) and Polish holidays

let warsaw: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    c.locale = Locale(identifier: "zh_Hans_CN")
    return c
}()

@MainActor
func holidayRegionChecks(holidays: HolidayData) throws {
    print("Polish holidays (offline)")
    let easter: [(Int, Int, Int)] = [(2024, 3, 31), (2025, 4, 20), (2026, 4, 5), (2027, 3, 28), (2028, 4, 16), (2029, 4, 1), (2030, 4, 21)]
    for (y, m, d) in easter {
        let got = PolishHolidays.easterSunday(year: y)
        check(got == DayKey(year: y, month: m, day: d), "Easter \(y) = \(got)")
    }
    // Extremes of the Gregorian computus: earliest (22 Mar) and latest (25 Apr) possible dates.
    check(PolishHolidays.easterSunday(year: 1818) == DayKey(year: 1818, month: 3, day: 22)
          && PolishHolidays.easterSunday(year: 1943) == DayKey(year: 1943, month: 4, day: 25)
          && PolishHolidays.easterSunday(year: 2000) == DayKey(year: 2000, month: 4, day: 23)
          && PolishHolidays.easterSunday(year: 2038) == DayKey(year: 2038, month: 4, day: 25),
          "Easter extremes 1818-03-22 / 1943-04-25 / 2000-04-23 / 2038-04-25")

    func keys(_ year: Int) -> [String] { PolishHolidays.holidays(year: year).map(\.date.string) }
    check(keys(2026) == ["2026-01-01", "2026-01-06", "2026-04-05", "2026-04-06", "2026-05-01", "2026-05-03", "2026-05-24",
                         "2026-06-04", "2026-08-15", "2026-11-01", "2026-11-11", "2026-12-24", "2026-12-25", "2026-12-26"],
          "2026 Polish holidays: \(keys(2026))")
    check(PolishHolidays.holiday(on: DayKey(year: 2026, month: 6, day: 4))?.localName == "Boże Ciało", "Corpus Christi (Boże Ciało) 2026-06-04")
    check(PolishHolidays.holiday(on: DayKey(year: 2026, month: 5, day: 24))?.localName == "Zielone Świątki", "Pentecost (Zielone Świątki) 2026-05-24")
    check(keys(2025).contains("2025-06-19") && keys(2025).contains("2025-04-21") && keys(2024).contains("2024-05-30"),
          "Corpus Christi 2025-06-19 / 2024-05-30, Easter Monday 2025-04-21")
    check(keys(2025).contains("2025-12-24") && keys(2030).contains("2030-12-24"), "Wigilia is a holiday from 2025 on")
    check(!keys(2024).contains("2024-12-24") && PolishHolidays.holiday(on: DayKey(year: 2024, month: 12, day: 24)) == nil,
          "Wigilia is not a holiday in 2024")
    check(keys(2024).count == 13 && keys(2025).count == 14, "13 holidays in 2024, 14 from 2025")
    check(PolishHolidays.holiday(on: DayKey(year: 2026, month: 4, day: 6))?.displayName == "复活节星期一（Poniedziałek Wielkanocny）",
          "Chinese name with the Polish name in parentheses")
    // `holiday(on:)` (fast path used by schedule scans) agrees with the full lists, day by day.
    var mismatches: [String] = []
    for year in 2020...2035 {
        let listed = Set(PolishHolidays.holidays(year: year).map(\.date))
        let first = DayKey(year: year, month: 1, day: 1).dayNumber
        let last = DayKey(year: year, month: 12, day: 31).dayNumber
        for n in first...last {
            let key = DayKey(dayNumber: n)
            if (PolishHolidays.holiday(on: key) != nil) != listed.contains(key) { mismatches.append(key.string) }
        }
    }
    check(mismatches.isEmpty, "holiday(on:) matches holidays(year:) for 2020–2035 \(mismatches.prefix(5))")
    check(PolishHolidays.upcoming(from: DayKey(year: 2026, month: 12, day: 25), limit: 3).map(\.date.string)
          == ["2026-12-25", "2026-12-26", "2027-01-01"], "upcoming holidays cross the year boundary")

    print("DayKey day arithmetic")
    check(DayKey(year: 1970, month: 1, day: 1).dayNumber == 0 && DayKey(dayNumber: 0) == DayKey(year: 1970, month: 1, day: 1), "epoch")
    check(DayKey(year: 2024, month: 2, day: 28).adding(days: 1) == DayKey(year: 2024, month: 2, day: 29)
          && DayKey(year: 2024, month: 12, day: 31).adding(days: 1) == DayKey(year: 2025, month: 1, day: 1)
          && DayKey(year: 2100, month: 3, day: 1).adding(days: -1) == DayKey(year: 2100, month: 2, day: 28)
          && DayKey(year: 2000, month: 3, day: 1).adding(days: -1) == DayKey(year: 2000, month: 2, day: 29),
          "leap years and year boundaries")
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    var arithmeticOK = true
    // Foundation's .gregorian switches to the Julian calendar before 1582-10-15; compare 1600…2517 only.
    for n in stride(from: -135_000, through: 200_000, by: 997) {
        let viaCalendar = DayKey(Date(timeIntervalSince1970: TimeInterval(n) * 86_400 + 43_200), calendar: utc)
        if DayKey(dayNumber: n) != viaCalendar || viaCalendar.dayNumber != n { arithmeticOK = false; break }
    }
    check(arithmeticOK, "dayNumber ⇄ DayKey agrees with Foundation for 1600–2517")

    print("Region auto-mapping")
    func auto(_ id: String) -> HolidayRegion? {
        TimeZone(identifier: id).map { HolidayRegion.automaticRegion(for: $0) }
    }
    check(auto("Asia/Shanghai") == .chinaMainland && auto("Asia/Urumqi") == .chinaMainland, "Asia/Shanghai, Asia/Urumqi → 中国大陆")
    check([auto("Asia/Chongqing"), auto("Asia/Harbin")].allSatisfy { $0 == nil || $0 == .chinaMainland }, "Asia/Chongqing, Asia/Harbin → 中国大陆")
    check(auto("Europe/Warsaw") == .poland, "Europe/Warsaw → 波兰")
    check(auto("Asia/Hong_Kong") == .disabled && auto("Asia/Macau") == .disabled && auto("Asia/Taipei") == .disabled,
          "Hong Kong / Macau / Taipei → 不使用 (different holidays)")
    check(auto("Europe/Berlin") == .disabled && auto("America/New_York") == .disabled && auto("UTC") == .disabled, "other zones → 不使用")
    let tzWarsaw = TimeZone(identifier: "Europe/Warsaw")!, tzShanghai = TimeZone(identifier: "Asia/Shanghai")!
    check(HolidayRegion.chinaMainland.resolved(for: tzWarsaw) == .chinaMainland && HolidayRegion.poland.resolved(for: tzShanghai) == .poland
          && HolidayRegion.disabled.resolved(for: tzShanghai) == .disabled && HolidayRegion.automatic.resolved(for: tzWarsaw) == .poland,
          "explicit regions ignore the time zone; 自动 resolves")
    check(HolidayRegion.allCases.map(\.title) == ["自动（根据系统时区）", "中国大陆（含调休）", "波兰", "不使用节假日"], "picker titles")

    print("Schedule per holiday region")
    var base = AwakeSettings()
    base.holidayRegion = .automatic
    func policy(_ region: HolidayRegion, _ cal: Calendar) -> AwakePolicy {
        var s = base
        s.holidayRegion = region
        return AwakePolicy(settings: s, holidays: holidays, calendar: cal)
    }
    let autoPL = policy(.automatic, warsaw)
    let pl = policy(.poland, shanghai)
    check(autoPL.holidayRegion == .poland && policy(.automatic, shanghai).holidayRegion == .chinaMainland, "policy resolves 自动 by its calendar's zone")
    let nov11 = date(2026, 11, 11, 10, calendar: warsaw)
    check(!autoPL.scheduleDesired(at: nov11), "2026-11-11 (Wed) 10:00 OFF under 自动 in Europe/Warsaw")
    check(!pl.scheduleDesired(at: date(2026, 11, 11, 10)), "2026-11-11 (Wed) 10:00 OFF under 波兰")
    check(policy(.disabled, warsaw).scheduleDesired(at: nov11), "2026-11-11 ON under 不使用节假日")
    check(policy(.automatic, shanghai).scheduleDesired(at: date(2026, 11, 11, 10)), "2026-11-11 ON under 中国大陆 (no Chinese holiday)")
    check(autoPL.dayInfo(for: nov11).reason == .holiday("独立日（Święto Niepodległości）"), "11-11 reason: 独立日（Święto Niepodległości）")
    check(AwakeText.todayLine(autoPL.dayInfo(for: nov11)) == "今天：休息日 · 独立日（Święto Niepodległości）",
          "label 今天：休息日 · 独立日（Święto Niepodległości）")
    check(AwakeText.dayType(autoPL.dayInfo(for: date(2026, 4, 6, 12, calendar: warsaw))) == "休息日 · 复活节星期一（Poniedziałek Wielkanocny）",
          "label for Easter Monday")
    check(!autoPL.scheduleDesired(at: date(2026, 6, 4, 10, calendar: warsaw)), "Corpus Christi 2026-06-04 (Thu) OFF under 波兰")
    check(!autoPL.scheduleDesired(at: date(2026, 12, 24, 10, calendar: warsaw))
          && autoPL.scheduleDesired(at: date(2024, 12, 24, 10, calendar: warsaw)), "Wigilia: OFF on 2026-12-24, ON on 2024-12-24 (Tue)")
    check(autoPL.scheduleDesired(at: date(2026, 10, 1, 10, calendar: warsaw)), "波兰 ignores Chinese data: 国庆 2026-10-01 is a workday")
    check(!autoPL.scheduleDesired(at: date(2026, 10, 10, 10, calendar: warsaw)), "波兰 ignores Chinese data: no 调休 on Sat 2026-10-10")
    check(!policy(.chinaMainland, warsaw).scheduleDesired(at: date(2026, 10, 1, 10, calendar: warsaw)), "explicit 中国大陆 in Warsaw: 国庆 off")
    var withOverride = base
    withOverride.dayOverrides = ["2026-11-11": true]
    check(AwakePolicy(settings: withOverride, holidays: holidays, calendar: warsaw).scheduleDesired(at: nov11),
          "manual 工作日 override beats a Polish holiday")
    let previewPL = autoPL.preview(from: date(2026, 12, 21, 9, calendar: warsaw), days: 7)
    check(previewPL.map(\.info.isWorkday) == [true, true, true, false, false, false, false], "未来 7 天 from Mon 12-21 under 波兰: Wigilia + Christmas off")
    check(previewPL[3].windowStart == nil && previewPL[0].windowStart == date(2026, 12, 21, 8, calendar: warsaw), "preview windows under 波兰")
    let nextPL = autoPL.nextTransition(after: date(2026, 12, 23, 20, calendar: warsaw))
    check(nextPL == date(2026, 12, 28, 8, calendar: warsaw), "波兰: Wed 12-23 20:00 → Mon 12-28 08:00 (\(nextPL.map { DayKey($0, calendar: warsaw).string } ?? "nil"))")
    var e = AwakeEngine()
    let r = e.evaluate(policy: autoPL, now: date(2026, 11, 10, 20, calendar: warsaw))
    check(AwakeText.statusLine(r.status, now: date(2026, 11, 10, 20, calendar: warsaw), calendar: warsaw) == "○ 已关闭 · 计划于 后天 08:00 开启",
          "status line under 波兰 skips 11-11: ○ 已关闭 · 计划于 后天 08:00 开启")

    print("Holiday region settings & migration")
    func decode(_ json: String) -> AwakeSettings? { try? JSONDecoder().decode(AwakeSettings.self, from: Data(json.utf8)) }
    check(decode(#"{"useChineseHolidays":false}"#)?.holidayRegion == .disabled, "legacy useChineseHolidays=false → 不使用节假日")
    check(decode(#"{"useChineseHolidays":true,"startMinute":540}"#)?.holidayRegion == .automatic, "legacy useChineseHolidays=true → 自动")
    check(decode(#"{"holidayRegion":"poland","useChineseHolidays":true}"#)?.holidayRegion == .poland, "new key wins over the legacy key")
    check(decode(#"{"holidayRegion":"mars"}"#)?.holidayRegion == .automatic, "unknown region → default 自动")
    check(decode(#"{"holidayRegion":"mars","useChineseHolidays":false}"#)?.holidayRegion == .disabled, "unknown region falls back to the legacy key")
    var pol = AwakeSettings()
    pol.holidayRegion = .chinaMainland
    let encoded = try JSONEncoder().encode(pol)
    let encodedJSON = String(decoding: encoded, as: UTF8.self)
    check((try? JSONDecoder().decode(AwakeSettings.self, from: encoded))?.holidayRegion == .chinaMainland
          && encodedJSON.contains(#""holidayRegion":"chinaMainland""#) && !encodedJSON.contains("useChineseHolidays"),
          "region round-trips; the legacy key is no longer written")
    withScratchDefaults("oneswitch.awakecheck.migrate") { defaults in
        defaults.set(Data(#"{"scheduleEnabled":true,"useChineseHolidays":false,"startMinute":510}"#.utf8), forKey: AwakeController.settingsKey)
        let store = SettingsStore(key: AwakeController.settingsKey, defaultValue: AwakeSettings(), defaults: defaults)
        check(store.value.holidayRegion == .disabled && store.value.startMinute == 510, "SettingsStore migrates stored legacy settings")
    }

    print("Start / end time pickers")
    var roundTrip = true
    for cal in [utc, warsaw, shanghai] {
        for m in 0..<(24 * 60) where AwakeTimeOfDay.minute(of: AwakeTimeOfDay.date(minute: m, calendar: cal), calendar: cal) != m {
            roundTrip = false
        }
    }
    check(roundTrip, "every minute 00:00–23:59 round-trips (fixed reference day, no DST gap)")
    // The old implementation built the picker date on *today* in the local zone: on a spring-forward
    // day 02:30 does not exist, it became 03:00, and the picker's onChange saved 03:00 as the window.
    let springForward = warsaw.date(from: DateComponents(year: 2026, month: 3, day: 29))!
    let oldWay = warsaw.date(bySettingHour: 2, minute: 30, second: 0, of: springForward)
    check(oldWay.map { AwakeTimeOfDay.minute(of: $0, calendar: warsaw) } != 150
          && AwakeTimeOfDay.minute(of: AwakeTimeOfDay.date(minute: 150, calendar: warsaw), calendar: warsaw) == 150,
          "02:30 survives a DST-gap day (on 2026-03-29 in Warsaw the old way yielded 03:00)")
    check(AwakeTimeOfDay.committedEnd(pickerMinute: 1439, storedEnd: 1440) == 1440
          && AwakeTimeOfDay.committedEnd(pickerMinute: 1439, storedEnd: 1140) == 1439
          && AwakeTimeOfDay.committedEnd(pickerMinute: 1200, storedEnd: 1440) == 1200,
          "a stored 24:00 end is not rewritten to 23:59 by the picker")
}

// MARK: - Holiday refresh cancellation (deterministic, via an injected I/O queue)

@MainActor
func holidayCancelCheck() throws {
    print("Holiday refresh cancellation")
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("AwakeCheckCancel-\(UUID().uuidString)", isDirectory: true)
    let remote = tmp.appendingPathComponent("remote", isDirectory: true)
    let cache = tmp.appendingPathComponent("cache", isDirectory: true)
    try fm.createDirectory(at: remote, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    try Data(holiday2026JSON.utf8).write(to: remote.appendingPathComponent("2026.json"))
    let io = DispatchQueue(label: "awakecheck.holidays.io")
    let store = HolidayStore(directory: cache, defaults: InMemoryDefaults(),
                             urlTemplates: ["file://\(remote.path)/{year}.json"], ioQueue: io)
    // Let the fetch start (task created on `io`), then park `io` so the download's completion handler
    // is queued behind the suspension — i.e. it is "about to write the cache" when cancel() runs.
    io.suspend()
    store.refresh(years: [2026])
    io.async { io.suspend() }
    io.resume()
    _ = waitUntil(0.3) { false } // file:// download finishes; its completion waits on `io`
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { io.resume() }
    store.cancel()
    _ = waitUntil(0.5) { false }
    check(!fm.fileExists(atPath: store.cacheURL(for: 2026).path), "no cache file is written after cancel() returned")
    check(!store.isRefreshing && store.lastUpdated == nil && store.data.years.isEmpty, "a cancelled refresh delivers nothing")
}

// MARK: - Controller with holiday regions (Warsaw, fake power, fake clock, temp dirs)

@MainActor
func regionControllerChecks() throws {
    print("Controller: holiday regions")
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("AwakeCheckRegion-\(UUID().uuidString)", isDirectory: true)
    let remote = tmp.appendingPathComponent("remote", isDirectory: true)
    let dataDir = tmp.appendingPathComponent("data", isDirectory: true)
    try fm.createDirectory(at: remote, withIntermediateDirectories: true)
    try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    try Data(holiday2026JSON.utf8).write(to: remote.appendingPathComponent("2026.json"))
    withScratchDefaults("oneswitch.awakecheck.region") { defaults in
        regionControllerChecks(defaults: defaults, tmp: tmp, remote: remote, dataDir: dataDir)
    }
}

@MainActor
func regionControllerChecks(defaults: UserDefaults, tmp: URL, remote: URL, dataDir: URL) {
    let fm = FileManager.default
    let offset = Box<TimeInterval>(0)
    func setNow(_ d: Date) { offset.value = d.timeIntervalSinceNow }
    setNow(date(2026, 11, 11, 10, calendar: warsaw))
    let calendarBox = Box<Calendar>(warsaw)
    let fake = FakePower()
    let controller = AwakeController(defaults: defaults, dataDirectory: dataDir, power: fake,
                                     holidayURLTemplates: ["file://\(remote.path)/{year}.json"],
                                     clock: { Date().addingTimeInterval(offset.value) },
                                     calendar: { calendarBox.value },
                                     notifier: { _, _ in })
    check(controller.settings.holidayRegion == .automatic && controller.effectiveHolidayRegion == .poland, "fresh settings: 自动 → 波兰 in Warsaw")
    controller.start()
    _ = waitUntil(0.5) { false } // cache load + first evaluation
    check(controller.holidays.lastUpdated == nil && !controller.holidays.isRefreshing
          && !fm.fileExists(atPath: dataDir.appendingPathComponent("awake-holidays-2026.json").path),
          "no holiday-cn download while the effective region is 波兰")
    check(controller.status.mode == .off && !fake.isHolding, "Wed 2026-11-11 10:00 (独立日) → off")
    let module = AwakeModule(controller: controller)
    let items = module.menuItems()
    check(items[0].title == "○ 已关闭 · 计划于 明天 08:00 开启", "menu status line under 波兰: \(items[0].title)")
    check(items[4].title == "今天：休息日 · 独立日（Święto Niepodległości）", "menu today line under 波兰: \(items[4].title)")
    _ = waitUntil(2.5) { !module.isMenuLive }

    controller.store.update { $0.holidayRegion = .disabled }
    check(controller.status.mode == .schedule && fake.isHolding, "不使用节假日 applies live → 11-11 is a workday → on")
    controller.store.update { $0.holidayRegion = .poland }
    check(controller.status.mode == .off && !fake.isHolding, "波兰 applies live → off")
    _ = waitUntil(0.3) { false }
    check(controller.holidays.lastUpdated == nil && !controller.holidays.isRefreshing, "still no download after region changes to 不使用 / 波兰")

    // The system time zone moves to China while 自动 is selected → 中国大陆 → holiday-cn is fetched.
    controller.store.update { $0.holidayRegion = .automatic }
    calendarBox.value = shanghai
    NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
    check(waitUntil(5) { controller.holidays.lastUpdated != nil && !controller.holidays.isRefreshing },
          "time-zone change to Asia/Shanghai under 自动 triggers the holiday-cn download")
    check(controller.effectiveHolidayRegion == .chinaMainland && controller.holidays.data.entryCount(forYear: 2026) == 39, "2026 China data loaded")
    check(controller.status.mode == .schedule && controller.status.today.reason == .regular,
          "11-11 17:00 in Shanghai: regular workday, on")

    // Past overrides are pruned on a day change too (not only at launch).
    controller.store.update { $0.dayOverrides = ["2026-11-12": false, "2027-01-04": true] }
    setNow(date(2026, 12, 30, 10))
    NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
    check(waitUntil(2) { controller.store.value.dayOverrides == ["2027-01-04": true] }, "day change prunes overrides older than 30 days")

    // The day change above started a holiday-cn refresh (a day passed since the last one); stop() must
    // cancel it synchronously — no cache file may appear afterwards (it used to be written, re-creating
    // the directory, by a completion handler already running on the I/O queue).
    controller.stop()
    check(!fake.isHolding && fake.releaseAllCount == 1, "stop() releases power")
    check(!controller.holidays.isRefreshing, "stop() cancels the in-flight holiday refresh")
    try? fm.removeItem(at: dataDir)
    _ = waitUntil(0.5) { false }
    check(!fm.fileExists(atPath: dataDir.path), "nothing is written to the data directory after stop()")
}

// MARK: - Controller integration (fake power, fake clock, temp dirs)

@MainActor
func controllerChecks() throws {
    print("Controller integration")
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("AwakeCheck-\(UUID().uuidString)", isDirectory: true)
    let remote = tmp.appendingPathComponent("remote", isDirectory: true)
    let dataDir = tmp.appendingPathComponent("data", isDirectory: true)
    try fm.createDirectory(at: remote, withIntermediateDirectories: true)
    try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    try Data(holiday2026JSON.utf8).write(to: remote.appendingPathComponent("2026.json"))

    try withScratchDefaults("oneswitch.awakecheck") { defaults in
        try controllerChecks(defaults: defaults, tmp: tmp, remote: remote, dataDir: dataDir)
    }
}

@MainActor
func controllerChecks(defaults: UserDefaults, tmp: URL, remote: URL, dataDir: URL) throws {
    let fm = FileManager.default

    // Real-time clock shifted to a target instant, so real timers line up with fake dates.
    let offset = Box<TimeInterval>(0)
    func setNow(_ d: Date) { offset.value = d.timeIntervalSinceNow }
    func advance(_ seconds: TimeInterval) { offset.value += seconds }
    setNow(date(2026, 9, 29, 10))
    let notes = Box<[(String, String)]>([])
    let fake = FakePower()
    let templates = ["file://\(tmp.path)/missing/{year}.json", "file://\(remote.path)/{year}.json"]
    // The Mac "booted" before every fake date used below (unless a check says otherwise).
    func makeController(power: AwakePowerControlling, bootTime: Date? = date(2026, 9, 1)) -> AwakeController {
        AwakeController(defaults: defaults, dataDirectory: dataDir, power: power,
                        holidayURLTemplates: templates,
                        clock: { Date().addingTimeInterval(offset.value) },
                        calendar: { shanghai },
                        notifier: { t, b in notes.value.append((t, b)) },
                        bootTime: { bootTime })
    }
    let controller = makeController(power: fake)
    check(fake.applyCount == 0 && !fake.isHolding, "init has no side effects")
    controller.start()
    check(waitUntil(5) { controller.holidays.lastUpdated != nil && !controller.holidays.isRefreshing },
          "holiday refresh at launch (file:// source, falls back past missing URL)")
    check(controller.holidays.data.entryCount(forYear: 2026) == 39, "2026 data loaded")
    check(controller.holidays.unpublishedYears.contains(2027) && controller.holidays.lastError == nil, "2027 not published, no error")
    check(fm.fileExists(atPath: dataDir.appendingPathComponent("awake-holidays-2026.json").path), "cache written to data dir")
    check(controller.holidays.summary(years: [2026, 2027]) == "2026 年：39 条 · 2027 年：尚未公布", "summary text")
    check(waitUntil { controller.status.mode == .schedule }, "Tue 10:00 → active by schedule")
    check(fake.isHolding && fake.simulating, "power assertion + activity simulation applied")

    controller.turnOff()
    check(controller.status.mode == .off && controller.status.suppressed && !fake.isHolding, "关闭 → off, suppressed, released")
    setNow(date(2026, 9, 29, 19, 0, 1))
    controller.evaluate(reason: "check")
    check(controller.status.mode == .off && !controller.status.suppressed, "after 19:00 suppression cleared")
    setNow(date(2026, 9, 30, 8, 0, 1))
    controller.evaluate(reason: "check")
    check(controller.status.mode == .schedule && fake.isHolding, "Wed 08:00 active")

    controller.startSession(minutes: 30)
    check(controller.status.mode == .manual, "manual 30 min")
    advance(31 * 60)
    controller.evaluate(reason: "check")
    check(controller.status.mode == .schedule && notes.value.last?.0 == "定时已结束", "expiry inside window notifies 定时已结束")

    setNow(date(2026, 10, 1, 10))
    controller.evaluate(reason: "check")
    check(controller.status.mode == .off && controller.status.today.reason == .holiday("国庆节"), "国庆 holiday → off")
    controller.startSession(minutes: 5)
    check(controller.status.mode == .manual && fake.isHolding, "manual 5 min on holiday")
    advance(5 * 60 + 1)
    controller.evaluate(reason: "check")
    check(controller.status.mode == .off && !fake.isHolding && notes.value.last?.0 == "防止锁屏已结束",
          "expiry → off + notification 防止锁屏已结束")
    check(notes.value.last?.1.contains("5分钟") == true, "notification mentions duration")
    let noteCount = notes.value.count
    controller.startSession(minutes: 5)
    advance(3 * 3600)
    controller.evaluate(reason: "check")
    check(controller.status.mode == .off && notes.value.count == noteCount, "long-past expiry ends silently")
    controller.store.update { $0.notifyOnEnd = false }
    controller.startSession(minutes: 5)
    advance(5 * 60 + 1)
    controller.evaluate(reason: "check")
    check(notes.value.count == noteCount, "no notification when 结束时通知 is off")
    controller.store.update { $0.notifyOnEnd = true }

    // Settings changes apply immediately.
    controller.store.update { $0.holidayRegion = .disabled }
    check(controller.status.mode == .schedule, "holidays off → 10-01 is a regular workday → active")
    controller.store.update { $0.holidayRegion = .automatic }
    check(controller.status.mode == .off, "holidays on → off again")
    controller.store.update { $0.dayOverrides = ["2026-10-01": true] }
    check(controller.status.mode == .schedule && controller.status.today.reason == .manualWorkday, "override 工作日 → active")
    controller.store.update { $0.simulateUserActivity = false }
    check(fake.isHolding && !fake.simulating, "模拟用户活动 off → assertion only")
    controller.setScheduleEnabled(false)
    check(controller.status.mode == .off && !fake.isHolding, "schedule disabled from menu → off")
    controller.setScheduleEnabled(true)
    controller.store.update { $0.dayOverrides = [:]; $0.simulateUserActivity = true }

    // Toggle.
    setNow(date(2026, 10, 17, 10))
    controller.toggle()
    check(controller.status.mode == .manual && controller.status.session?.isInfinite == true, "toggle on → 无限期")
    controller.toggle()
    check(controller.status.mode == .off, "toggle off")

    // Menu section.
    controller.startSession(minutes: 60)
    let module = AwakeModule(controller: controller)
    let items = module.menuItems()
    check(items.count == 5, "menu section has 5 items")
    check(items[0].title == "● 已开启 · 剩余 1:00:00", "menu status line: \(items[0].title)")
    check(items[1].title == "关闭防止锁屏", "menu toggle title")
    let presets = items[2].submenu?.items ?? []
    check(items[2].title == "开启一段时间" && presets.filter { $0.state == .on }.map(\.title) == ["1小时"],
          "durations submenu checks the running preset")
    check(presets.prefix(11).map(\.title) == ["5分钟", "10分钟", "15分钟", "30分钟", "1小时", "2小时", "3小时", "4小时", "6小时", "8小时", "12小时"],
          "preset titles")
    check(presets.contains { $0.title == "自定义：1小时30分钟" }, "custom duration item")
    check(items[3].title == "自动计划（工作日 08:00–19:00）" && items[3].state == .on, "schedule toggle item")
    check(items[4].title == "今天：休息日", "today info line")
    check(module.statusIconSymbol == "bolt.fill", "status icon while active: 闪电 (default)")
    check(module.isMenuLive, "live countdown starts when the menu is built")
    check(waitUntil(2.5) { !module.isMenuLive }, "live countdown stops when the menu is not being tracked")
    controller.turnOff()
    check(module.statusIconSymbol == nil, "no status icon override while off")

    // One-shot deadline timer fires at the schedule boundary (real timer, shifted clock).
    setNow(date(2026, 10, 19, 18, 59, 58))
    controller.evaluate(reason: "check")
    check(controller.status.mode == .schedule, "Mon 18:59:58 active")
    check(waitUntil(4) { controller.status.mode == .off }, "deadline timer switches off at 19:00 without polling")
    check(!fake.isHolding, "assertion released at 19:00")

    // Persistence across relaunch.
    controller.startSession(minutes: nil)
    let restored = makeController(power: FakePower())
    check(restored.status.mode == .manual && restored.status.session?.isInfinite == true, "running session restored after relaunch")

    controller.stop()
    check(fake.releaseAllCount == 1 && !fake.isHolding, "stop() releases power synchronously")
    controller.evaluate(reason: "after stop")
    check(!fake.isHolding && fake.releaseAllCount == 1, "no side effects after stop()")

    let boot = AwakeController.systemBootTime()
    check(boot.map { $0 < Date() && $0 > Date().addingTimeInterval(-400 * 86_400) } == true, "kern.boottime is read (\(boot.map { "\($0)" } ?? "nil"))")
    check(makeController(power: FakePower(), bootTime: nil).status.session?.isInfinite == true,
          "unknown boot time: the session is restored (relaunch semantics)")
    // A restart (boot after the session started) ends the manual session; the schedule still applies.
    advance(3600)
    let rebooted = makeController(power: FakePower(), bootTime: Date().addingTimeInterval(offset.value - 60))
    check(rebooted.status.session == nil, "无限期 session from before a restart is not restored")
    rebooted.start()
    rebooted.stop()
    let relaunched = makeController(power: FakePower())
    check(relaunched.status.session == nil, "the discarded session stays discarded (state persisted by start())")
}

// MARK: - Real IOKit assertion probe (brief, released)

@MainActor
func assertionChecks() {
    print("Power assertion (pmset probe)")
    let manager = PowerAssertionManager()
    let before = pmsetLinesForSelf()
    check(!before.contains { $0.contains("PreventUserIdleDisplaySleep") }, "no assertion before activation")
    manager.apply(active: true, simulateActivity: false)
    check(manager.isHolding, "assertion created")
    let during = pmsetLinesForSelf()
    check(during.contains { $0.contains("PreventUserIdleDisplaySleep") }, "pmset lists PreventUserIdleDisplaySleep for this pid")
    // pmset prints non-ASCII assertion names as "" — verify the exact name via powerd's API instead.
    check(ownAssertions().contains { $0.type == "PreventUserIdleDisplaySleep" && $0.name == "OneSwitch 防止锁屏" },
          "powerd reports the assertion named \"OneSwitch 防止锁屏\"")
    manager.apply(active: true, simulateActivity: false)
    check(ownAssertions().filter { $0.type == "PreventUserIdleDisplaySleep" }.count == 1, "apply is idempotent (one assertion)")
    manager.apply(active: false, simulateActivity: false)
    check(!manager.isHolding, "assertion released")
    check(waitUntil(2) { !pmsetLinesForSelf().contains { $0.contains("PreventUserIdleDisplaySleep") } }, "pmset no longer lists it")

    // User activity declaration (skipped automatically when the display is asleep / locked).
    manager.apply(active: true, simulateActivity: true)
    check(manager.isSimulatingActivity, "activity timer running")
    if manager.lastActivityDeclaration != nil {
        check(ownAssertions().contains { $0.type == "UserIsActive" && $0.name == "OneSwitch 防止锁屏" }, "UserIsActive declared")
    } else {
        print("  – user-activity ping skipped (display asleep or session locked)")
    }
    manager.releaseAll()
    check(!manager.isHolding && !manager.isSimulatingActivity, "releaseAll stops everything")
    check(waitUntil(2) { ownAssertions().isEmpty && pmsetLinesForSelf().isEmpty }, "no assertions left for this process")
}

// MARK: - Live holiday-cn endpoint (network; skipped when offline)

@MainActor
func liveNetworkCheck() {
    print("Live holiday-cn fetch")
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("AwakeCheckLive-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    withScratchDefaults("oneswitch.awakecheck.live") { defaults in
        liveNetworkCheck(store: HolidayStore(directory: tmp, defaults: defaults), tmp: tmp)
    }
}

@MainActor
func liveNetworkCheck(store: HolidayStore, tmp: URL) {
    let fm = FileManager.default
    let done = Box(false)
    store.refresh(years: [2026]) { done.value = true }
    guard waitUntil(40, { done.value }) else {
        store.cancel()
        print("  – skipped (timed out)")
        return
    }
    if let error = store.lastError {
        print("  – skipped (offline: \(error))")
        return
    }
    check(store.data.entry(for: DayKey(year: 2026, month: 10, day: 1)) == HolidayEntry(name: "国庆节", isOffDay: true),
          "live data: 2026-10-01 国庆节 off")
    check(fm.fileExists(atPath: tmp.appendingPathComponent("awake-holidays-2026.json").path), "live data cached")
}

// MARK: - Optional UI snapshot (development aid, not part of the pass/fail checks)
//
// `AWAKE_RENDER_SETTINGS=/path/out.png .build-awake/debug/AwakeCheck` renders the settings page in an
// off-screen borderless window (never ordered on screen) to a PNG and exits.

@MainActor
func renderSettingsSnapshot(to path: String) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AwakeRender-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    try Data(holiday2026JSON.utf8).write(to: tmp.appendingPathComponent("awake-holidays-2026.json"))
    try withScratchDefaults("oneswitch.awakecheck.render") { defaults in
        try renderSettingsSnapshot(to: path, tmp: tmp, defaults: defaults)
    }
}

@MainActor
func renderSettingsSnapshot(to path: String, tmp: URL, defaults: UserDefaults) throws {
    // AWAKE_RENDER_TZ=Europe/Warsaw renders with that zone (e.g. to see the 波兰 holiday calendar).
    var renderCalendar = shanghai
    if let tz = ProcessInfo.processInfo.environment["AWAKE_RENDER_TZ"].flatMap(TimeZone.init(identifier:)) {
        renderCalendar.timeZone = tz
    }
    let offset = date(2026, 9, 30, 10, 12, calendar: renderCalendar).timeIntervalSinceNow
    let controller = AwakeController(defaults: defaults, dataDirectory: tmp, power: FakePower(),
                                     holidayURLTemplates: ["file://\(tmp.path)/none/{year}.json"],
                                     clock: { Date().addingTimeInterval(offset) }, calendar: { renderCalendar },
                                     notifier: { _, _ in })
    controller.store.update { $0.dayOverrides = ["2026-10-08": false, "2026-10-11": true]; $0.manualChoice = AwakeLimits.choiceCustom }
    controller.start()
    _ = waitUntil(3) { controller.holidays.data.files[2026] != nil && !controller.holidays.isRefreshing }
    controller.startSession(minutes: 90)
    let module = AwakeModule(controller: controller)
    let height = Double(ProcessInfo.processInfo.environment["AWAKE_RENDER_HEIGHT"] ?? "") ?? 2300
    let size = NSSize(width: 640, height: height)
    let hosting = NSHostingView(rootView: module.settingsView().frame(width: size.width, height: size.height))
    hosting.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    // AWAKE_RENDER_DARK / AWAKE_RENDER_LIGHT force an appearance (default: the system's).
    if ProcessInfo.processInfo.environment["AWAKE_RENDER_DARK"] != nil { window.appearance = NSAppearance(named: .darkAqua) }
    if ProcessInfo.processInfo.environment["AWAKE_RENDER_LIGHT"] != nil { window.appearance = NSAppearance(named: .aqua) }
    _ = waitUntil(1.5) { false }
    hosting.layoutSubtreeIfNeeded()
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    controller.stop()
    window.close()
    print("rendered settings page to \(path)")
}

if let path = ProcessInfo.processInfo.environment["AWAKE_RENDER_SETTINGS"] {
    do { try MainActor.assumeIsolated { try renderSettingsSnapshot(to: path) } } catch { print("render failed: \(error)") }
    exit(0)
}

AppLog.echoToStderr = false
do {
    try MainActor.assumeIsolated { try runChecks() }
} catch {
    failures += 1
    print("  ✗ unexpected error: \(error)")
}
print(failures == 0 ? "AwakeCheck: ALL PASSED" : "AwakeCheck: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
