import AppKit
import IOKit
import OneSwitchCore
import MenuBarHider

// Self-checks for the 菜单栏图标 module. Exit code 0 = all checks passed.
//
// No synthetic input is ever posted and the cursor is never moved. Live side effects:
// - a brief integration run that adds our own toggle + separator (leftmost, nothing else to their left)
//   and removes them again;
// - 系统原生隐藏 is exercised with fakes only; one optional live probe (only while the screen is
//   unlocked) activates the real restriction with EVERY running app allowed (a visual no-op) and
//   invalidates it the moment it is granted — never held for more than a fraction of a second, and any
//   late grant is invalidated on arrival (the restriction also ends when this process exits).
// UI / layout-dependent live checks never fail while the session is locked (reported as "~ ignored").

// Log to a throw-away profile file instead of interleaving with a running OneSwitch's real log
// (must run before anything touches AppEnvironment / AppLog; a caller-supplied profile wins).
let checkProfile = "menubarhidercheck"
setenv("ONESWITCH_PROFILE", checkProfile, 0)

var failures = 0
/// Set while running live UI checks on a locked session: failures are reported but not counted.
var softFailures = false
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() {
        print("  ✓ \(message)")
    } else if softFailures {
        print("  ~ \(message) (line \(line); ignored: screen locked)")
    } else {
        failures += 1
        print("  ✗ \(message) (line \(line))")
    }
}

/// The login session is locked (screen locked / not on the console): menu-bar layout is unreliable.
func isSessionLocked() -> Bool {
    if let dict = CGSessionCopyCurrentDictionary() as? [String: Any] {
        if (dict["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        if (dict[kCGSessionOnConsoleKey as String] as? Bool) == false { return true }
    }
    let root = IORegistryGetRootEntry(kIOMainPortDefault)
    defer { IOObjectRelease(root) }
    if let value = IORegistryEntryCreateCFProperty(root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Bool, value {
        return true
    }
    return false
}
let sessionLocked = isSessionLocked()

/// Spins the main run loop until `condition` is true or `timeout` elapses.
@MainActor
func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

func approx(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.01) -> Bool { abs(a - b) <= eps }
func approx(_ a: TimeInterval, _ b: TimeInterval, _ eps: TimeInterval = 0.001) -> Bool { abs(a - b) <= eps }

// MARK: - Fake clock + scheduler for the auto-collapse driver

@MainActor
final class FakeTime {
    struct Job {
        let id: Int
        let fireAt: Date
        let action: @MainActor () -> Void
    }

    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private(set) var jobs: [Job] = []
    private var nextID = 0
    private(set) var firedCount = 0

    lazy var scheduler: AutoCollapseDriver.Scheduler = { [unowned self] delay, action in
        let id = self.nextID
        self.nextID += 1
        self.jobs.append(Job(id: id, fireAt: self.now.addingTimeInterval(delay), action: action))
        return { [weak self] in self?.jobs.removeAll { $0.id == id } }
    }

    var pendingCount: Int { jobs.count }

    /// Advances the clock to `t0 + seconds`, running due jobs in order.
    func advance(to target: Date) {
        while let next = jobs.min(by: { $0.fireAt < $1.fireAt }), next.fireAt <= target {
            jobs.removeAll { $0.id == next.id }
            if next.fireAt > now { now = next.fireAt }
            firedCount += 1
            next.action()
        }
        if target > now { now = target }
    }

    func advance(by seconds: TimeInterval) { advance(to: now.addingTimeInterval(seconds)) }
}

@MainActor
func makeDriver(_ time: FakeTime, autoCollapse: Bool = true, delay: TimeInterval = 10,
                interacting: @escaping () -> Bool = { false }) -> AutoCollapseDriver {
    AutoCollapseDriver(machine: RevealStateMachine(visibility: .collapsed, autoCollapse: autoCollapse, delay: delay),
                       now: { [unowned time] in time.now },
                       schedule: time.scheduler,
                       probe: { completion in completion(interacting()) })
}

// MARK: - Checks

@MainActor
func checkSettings() {
    print("Settings")
    let d = MenuBarHiderSettings()
    check(d.enabled && d.autoCollapse && d.collapseAtLaunch, "defaults: enabled, auto re-hide, hide at launch")
    check(d.autoCollapseDelay == 10 && !d.alwaysHiddenEnabled && d.hotKey == nil, "defaults: 10 s, no always-hidden, no hotkey")
    check(d.separatorStyle == .line && d.toggleStyle == .chevron && d.hideSeparatorWhenCollapsed, "default styles")

    check(MenuBarHiderSettings.clampDelay(3) == 5, "clamp 3 → 5")
    check(MenuBarHiderSettings.clampDelay(7) == 5, "clamp 7 → 5")
    check(MenuBarHiderSettings.clampDelay(8) == 10, "clamp 8 → 10")
    check(MenuBarHiderSettings.clampDelay(13) == 15, "clamp 13 → 15")
    check(MenuBarHiderSettings.clampDelay(61) == 60 && MenuBarHiderSettings.clampDelay(10_000) == 60, "clamp > 60 → 60")
    check(MenuBarHiderSettings.clampDelay(-5) == 5, "clamp negative → 5")

    var s = MenuBarHiderSettings()
    s.enabled = false
    s.autoCollapse = false
    s.autoCollapseDelay = 45
    s.collapseAtLaunch = false
    s.alwaysHiddenEnabled = true
    s.separatorStyle = .dot
    s.hideSeparatorWhenCollapsed = false
    s.toggleStyle = .dot
    s.hotKey = HotKey(keyCode: 4, modifiers: [.command, .option])
    let data = try? JSONEncoder().encode(s)
    let decoded = data.flatMap { try? JSONDecoder().decode(MenuBarHiderSettings.self, from: $0) }
    check(decoded == s, "encode → decode round-trip (all fields + hotkey)")
    let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check(json.contains("\"hotKey\"") && json.contains("\"separatorStyle\":\"dot\""), "JSON contains hotKey and style")

    let partial = try? JSONDecoder().decode(MenuBarHiderSettings.self, from: Data(#"{"autoCollapseDelay":30,"enabled":false}"#.utf8))
    check(partial?.autoCollapseDelay == 30 && partial?.enabled == false && partial?.autoCollapse == true
          && partial?.collapseAtLaunch == true, "partial JSON keeps defaults for missing fields")
    let bad = try? JSONDecoder().decode(MenuBarHiderSettings.self,
                                        from: Data(#"{"separatorStyle":"zigzag","autoCollapseDelay":999,"toggleStyle":3,"hotKey":null}"#.utf8))
    check(bad?.separatorStyle == .line && bad?.autoCollapseDelay == 60 && bad?.toggleStyle == .chevron && bad?.hotKey == nil,
          "unknown enum values fall back, delay clamped")
    let empty = try? JSONDecoder().decode(MenuBarHiderSettings.self, from: Data("{}".utf8))
    check(empty == MenuBarHiderSettings(), "empty JSON → defaults")

    let suiteName = "oneswitch.menubarhidercheck.settings"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    let store = SettingsStore(key: MenuBarHiderSettings.storeKey, defaultValue: MenuBarHiderSettings(), defaults: suite)
    store.update { $0.autoCollapseDelay = 25; $0.alwaysHiddenEnabled = true; $0.hotKey = HotKey(keyCode: 11, modifiers: [.control, .option]) }
    let reloaded = SettingsStore(key: MenuBarHiderSettings.storeKey, defaultValue: MenuBarHiderSettings(), defaults: suite)
    check(reloaded.value == store.value && reloaded.value.autoCollapseDelay == 25, "SettingsStore persists under \"menubar.settings\"")
    suite.removePersistentDomain(forName: suiteName)

    print("Settings: per-app rules (系统原生隐藏) + migration")
    check(d.appRules.isEmpty && d.rule(for: "com.example.a") == .auto, "default: no rules, every app 自动")
    check(AppVisibilityRule.allCases.map(\.title) == ["自动", "始终隐藏", "始终显示"], "rule titles")
    var r = MenuBarHiderSettings()
    r.setRule(.alwaysHide, for: "com.example.hide")
    r.setRule(.alwaysShow, for: "com.example.show")
    r.setRule(.alwaysHide, for: "com.example.reset")
    r.setRule(.auto, for: "com.example.reset")
    r.setRule(.alwaysShow, for: "")
    check(r.appRules == ["com.example.hide": .alwaysHide, "com.example.show": .alwaysShow],
          "setRule stores hide / show, .auto clears, empty ids ignored")
    let rData = try? JSONEncoder().encode(r)
    let rDecoded = rData.flatMap { try? JSONDecoder().decode(MenuBarHiderSettings.self, from: $0) }
    check(rDecoded == r, "rules round-trip")
    let rJSON = rData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check(rJSON.contains("\"appRules\"") && rJSON.contains("\"com.example.hide\":\"alwaysHide\""), "rules stored as bundle id → rule name")
    let lenient = try? JSONDecoder().decode(MenuBarHiderSettings.self, from: Data(#"""
        {"autoCollapseDelay":20,"appRules":{"a.hide":"alwaysHide","b.bogus":"sometimes","c.number":3,"":"alwaysShow","d.auto":"auto","e.show":"alwaysShow"}}
        """#.utf8))
    check(lenient?.appRules == ["a.hide": .alwaysHide, "e.show": .alwaysShow] && lenient?.autoCollapseDelay == 20,
          "unknown / malformed rule values dropped one by one, the rest kept")
    let wrongType = try? JSONDecoder().decode(MenuBarHiderSettings.self, from: Data(#"{"appRules":["x"],"enabled":false}"#.utf8))
    check(wrongType?.appRules.isEmpty == true && wrongType?.enabled == false, "appRules of the wrong type → empty, other fields kept")

    // Exactly what the previous release (separator engine only) stored.
    let v1 = #"{"enabled":true,"autoCollapse":false,"autoCollapseDelay":25,"collapseAtLaunch":false,"alwaysHiddenEnabled":true,"separatorStyle":"dot","hideSeparatorWhenCollapsed":false,"toggleStyle":"dot","hotKey":{"keyCode":4,"modifiers":1572864}}"#
    let migrationSuite = "oneswitch.menubarhidercheck.migration"
    let ms = UserDefaults(suiteName: migrationSuite)!
    ms.removePersistentDomain(forName: migrationSuite)
    ms.set(Data(v1.utf8), forKey: MenuBarHiderSettings.storeKey)
    let migrated = SettingsStore(key: MenuBarHiderSettings.storeKey, defaultValue: MenuBarHiderSettings(), defaults: ms)
    let m = migrated.value
    check(m.enabled && !m.autoCollapse && m.autoCollapseDelay == 25 && !m.collapseAtLaunch && m.alwaysHiddenEnabled
          && m.separatorStyle == .dot && !m.hideSeparatorWhenCollapsed && m.toggleStyle == .dot,
          "old settings migrate: every previous choice kept")
    check(m.hotKey != nil && m.appRules.isEmpty, "old settings migrate: hotkey kept, no per-app rules (all 自动)")
    check(ms.data(forKey: MenuBarHiderSettings.storeKey + ".unreadable") == nil, "old settings are readable (nothing parked as .unreadable)")
    migrated.update { $0.setRule(.alwaysShow, for: "com.example.keep") }
    let rewritten = ms.data(forKey: MenuBarHiderSettings.storeKey).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check(rewritten.contains("com.example.keep") && rewritten.contains("\"autoCollapseDelay\":25"),
          "first change writes the new format (rules + old fields)")
    let again = SettingsStore(key: MenuBarHiderSettings.storeKey, defaultValue: MenuBarHiderSettings(), defaults: ms)
    check(again.value.rule(for: "com.example.keep") == .alwaysShow && again.value.alwaysHiddenEnabled, "new format reloads")
    ms.removePersistentDomain(forName: migrationSuite)
}

@MainActor
func checkGeometry() {
    print("Geometry")
    // This Mac: 1920×1080 display, 30 pt menu bar.
    let studio = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                visibleFrame: CGRect(x: 0, y: 90, width: 1920, height: 960))
    // A notched 14" MacBook Pro to the right of it (menu bar 37 pt).
    let mbp = ScreenGeometry(frame: CGRect(x: 1920, y: 0, width: 1512, height: 982),
                             visibleFrame: CGRect(x: 1920, y: 0, width: 1512, height: 945),
                             safeAreaTop: 37, hasNotch: true)
    let autoHide = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900))
    check(MenuBarGeometry.menuBarHeight(of: studio, thickness: 22) == 30, "menu bar height from visibleFrame (30)")
    check(MenuBarGeometry.menuBarHeight(of: mbp, thickness: 22) == 37, "notched menu bar height (37)")
    check(MenuBarGeometry.menuBarHeight(of: autoHide, thickness: 22) == 24, "auto-hidden menu bar falls back to ≥ 24")

    let screens = [studio, mbp]
    check(MenuBarGeometry.isPointInMenuBar(CGPoint(x: 500, y: 1070), screens: screens, thickness: 22), "pointer in bar (primary)")
    check(MenuBarGeometry.isPointInMenuBar(CGPoint(x: 500, y: 1080), screens: screens, thickness: 22), "pointer at top edge counts")
    check(!MenuBarGeometry.isPointInMenuBar(CGPoint(x: 500, y: 1040), screens: screens, thickness: 22), "pointer below bar")
    check(MenuBarGeometry.isPointInMenuBar(CGPoint(x: 2500, y: 960), screens: screens, thickness: 22), "pointer in bar (second screen)")
    check(!MenuBarGeometry.isPointInMenuBar(CGPoint(x: 2500, y: 1070), screens: screens, thickness: 22), "pointer above shorter screen is nowhere")
    check(!MenuBarGeometry.isPointInMenuBar(CGPoint(x: 2500, y: 930), screens: screens, thickness: 22), "pointer below second bar")

    let cg = MenuBarGeometry.toCG(CGRect(x: 1219, y: 1050, width: 28, height: 30), primaryMaxY: 1080)
    check(cg == CGRect(x: 1219, y: 0, width: 28, height: 30), "AppKit → CG rect")
    check(MenuBarGeometry.toAppKit(CGPoint(x: 10, y: 15), primaryMaxY: 1080) == CGPoint(x: 10, y: 1065), "CG → AppKit point")

    let bands = MenuBarGeometry.menuBarBands(screens: screens, thickness: 22)
    check(bands.count == 2 && bands[0] == CGRect(x: 0, y: 0, width: 1920, height: 30), "primary band in CG")
    check(bands.count == 2 && bands[1] == CGRect(x: 1920, y: 98, width: 1512, height: 37), "second screen band in CG (y = 1080 − 982)")
    check(MenuBarGeometry.isInMenuBar(CGRect(x: 1625, y: 4, width: 22, height: 22), bands: bands), "item in band")
    check(!MenuBarGeometry.isInMenuBar(CGRect(x: 7, y: 1068, width: 24, height: 24), bands: bands), "parked/disabled item (y 1068) not in band")
    check(MenuBarGeometry.isInMenuBar(CGRect(x: -5000, y: 3, width: 24, height: 24), bands: bands), "item pushed off-screen left is still in the bar strip")

    // Status-item window frames: AppKit reports (0, -30) right after creation, then slides the item in.
    check(!MenuBarGeometry.isPlausibleStatusItemFrame(CGRect(x: 0, y: -30, width: 27, height: 30), screens: screens),
          "transient frame (0, -30) rejected")
    check(MenuBarGeometry.isPlausibleStatusItemFrame(CGRect(x: 1246, y: 1050, width: 27, height: 30), screens: screens),
          "laid-out frame accepted")
    check(MenuBarGeometry.isPlausibleStatusItemFrame(CGRect(x: 1246, y: 1020, width: 27, height: 30), screens: screens),
          "frame sliding in accepted (x already final)")
    check(MenuBarGeometry.isPlausibleStatusItemFrame(CGRect(x: -8000, y: 1050, width: 10_016, height: 30), screens: screens),
          "wide collapsed separator accepted")
    check(MenuBarGeometry.isPlausibleStatusItemFrame(CGRect(x: 2600, y: 945, width: 26, height: 37), screens: screens),
          "frame on the second screen's bar accepted")
    check(!MenuBarGeometry.isPlausibleStatusItemFrame(CGRect(x: 100, y: 500, width: 26, height: 30), screens: screens),
          "frame in the middle of a screen rejected")
    check(!MenuBarGeometry.isPlausibleStatusItemFrame(.zero, screens: screens), "zero frame rejected")
}

@MainActor
func checkSafety() {
    print("Separator order safety")
    let toggle = CGRect(x: 1247, y: 1050, width: 26, height: 30)
    let sep = CGRect(x: 1219, y: 1050, width: 28, height: 30)
    check(SeparatorOrder.check(toggle: toggle, separator: sep) == .ok, "separator left of toggle → ok")
    check(SeparatorOrder.check(toggle: toggle, separator: sep).allowsCollapse, "ok allows collapse")
    let right = SeparatorOrder.check(toggle: toggle, separator: CGRect(x: 1300, y: 1050, width: 28, height: 30))
    check(right == .separatorRightOfToggle && !right.allowsCollapse, "separator right of toggle → refused")
    check(right.warning == "分隔线位置不正确：请按住 ⌘ 将分隔线拖到切换按钮左侧", "warning text")
    check(SeparatorOrder.check(toggle: toggle, separator: CGRect(x: 1247, y: 1050, width: 28, height: 30)) == .separatorRightOfToggle,
          "same x is not safe")
    check(SeparatorOrder.check(toggle: nil, separator: sep) == .unknown, "missing toggle frame → unknown")
    check(SeparatorOrder.check(toggle: toggle, separator: .zero) == .unknown, "zero frame → unknown")
    check(!SeparatorOrder.unknown.allowsCollapse && SeparatorOrder.unknown.warning == nil, "unknown refuses silently")
    let ahOK = SeparatorOrder.check(toggle: toggle, separator: sep, alwaysHidden: CGRect(x: 1100, y: 1050, width: 24, height: 30))
    check(ahOK == .ok && ahOK.allowsAlwaysHidden, "always-hidden separator left of separator → ok")
    let ahBad = SeparatorOrder.check(toggle: toggle, separator: sep, alwaysHidden: CGRect(x: 1260, y: 1050, width: 24, height: 30))
    check(ahBad == .alwaysHiddenMisplaced && ahBad.allowsCollapse && !ahBad.allowsAlwaysHidden,
          "misplaced always-hidden separator: collapse ok, never widened")
    let ahPending = SeparatorOrder.check(toggle: toggle, separator: sep, alwaysHidden: nil, alwaysHiddenExpected: true)
    check(ahPending == .alwaysHiddenUnknown && ahPending.allowsCollapse && !ahPending.allowsAlwaysHidden && ahPending.warning == nil,
          "always-hidden separator without a frame yet: not widened, no warning")

    // macOS 27 on the crowded, notched MacBook Pro (measured): freshly created toggle + separator do not
    // fit and are parked in the "«" overflow, right-aligned to one anchor with placeholder widths (the
    // separator is 10 pt long but reports 26). That used to read as "separator right of toggle" (903 ≥ 902)
    // → bogus warning at launch and the hider never worked there.
    let parkedToggle = CGRect(x: 902, y: 949, width: 27, height: 33)
    let parkedSep = CGRect(x: 903, y: 949, width: 26, height: 33)
    let mbpScreens = [ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                     visibleFrame: CGRect(x: 0, y: 100, width: 1512, height: 849), safeAreaTop: 32, hasNotch: true)]
    check(MenuBarGeometry.isPlausibleStatusItemFrame(parkedToggle, screens: mbpScreens)
          && MenuBarGeometry.isPlausibleStatusItemFrame(parkedSep, screens: mbpScreens), "parked frames look laid out (so they must be recognised)")
    let parked = SeparatorOrder.check(toggle: parkedToggle, separator: parkedSep)
    check(parked == .parkedInOverflow, "MBP-measured parked toggle (902+27) / separator (903+26) → parkedInOverflow, not separatorRightOfToggle")
    check(!parked.allowsCollapse && !parked.allowsAlwaysHidden, "parked: never collapse / widen (real order unknown)")
    check(parked.warning?.contains("«") == true && parked.warning != SeparatorOrder.separatorRightOfToggle.warning,
          "parked: explains the « overflow instead of asking to drag the separator")
    let equalWidth = CGRect(x: 886, y: 949, width: 26, height: 33) // earlier MBP measurement, equal widths
    check(SeparatorOrder.check(toggle: equalWidth, separator: equalWidth) == .parkedInOverflow, "identical parked frames → parkedInOverflow")
    check(SeparatorOrder.check(toggle: parkedToggle, separator: parkedSep.offsetBy(dx: 0.4, dy: 0)) == .parkedInOverflow,
          "sub-point jitter still counts as parked")
    let laidOutToggle = CGRect(x: 1180, y: 949, width: 27, height: 33)
    check(SeparatorOrder.check(toggle: laidOutToggle, separator: parkedSep) == .ok,
          "only the separator parked (toggle laid out right of it) → ok")
    let ahParked = SeparatorOrder.check(toggle: laidOutToggle, separator: parkedSep, alwaysHidden: parkedSep)
    check(ahParked == .alwaysHiddenUnknown && ahParked.warning == nil && ahParked.allowsCollapse && !ahParked.allowsAlwaysHidden,
          "always-hidden parked with the separator → unknown (no bogus 'misplaced' warning, not widened)")
    check(SeparatorOrder.check(toggle: parkedToggle, separator: parkedSep, alwaysHidden: parkedSep, alwaysHiddenExpected: true) == .parkedInOverflow,
          "all three parked (MBP-measured) → parkedInOverflow")
    check(!MenuBarGeometry.areParkedTogether(toggle, CGRect(x: 1247, y: 1050, width: 28, height: 30)),
          "same x but different right edge is not a parked pair")
    check(!MenuBarGeometry.areParkedTogether(CGRect(x: 1219, y: 1050, width: 28, height: 30), toggle),
          "adjacent laid-out items (separator | toggle) are not parked")

    // Toggling the 永久隐藏区 while collapsed (frames unreadable): never trust the new separator yet.
    check(SeparatorOrder.ok.afterAlwaysHiddenChange(enabled: true) == .alwaysHiddenUnknown, "added while collapsed → unverified")
    check(SeparatorOrder.alwaysHiddenMisplaced.afterAlwaysHiddenChange(enabled: false) == .ok
          && SeparatorOrder.alwaysHiddenUnknown.afterAlwaysHiddenChange(enabled: false) == .ok, "removed → its warning goes away")
    check(SeparatorOrder.separatorRightOfToggle.afterAlwaysHiddenChange(enabled: true) == .separatorRightOfToggle
          && SeparatorOrder.parkedInOverflow.afterAlwaysHiddenChange(enabled: false) == .parkedInOverflow,
          "unrelated problems are kept")

    print("Hide at launch (initial collapse policy)")
    typealias C = MenuBarHiderController
    check(C.initialCollapseStep(order: .unknown, previous: nil, attempt: 0) == .retry, "unknown order → wait")
    check(C.initialCollapseStep(order: .parkedInOverflow, previous: .parkedInOverflow, attempt: 3) == .retry,
          "parked in « → wait (may still be laid out)")
    check(C.initialCollapseStep(order: .separatorRightOfToggle, previous: .separatorRightOfToggle, attempt: 3) == .retry,
          "an unsafe reading is not final before the retries are used up")
    check(C.initialCollapseStep(order: .ok, previous: nil, attempt: 0) == .retry,
          "a single safe reading is confirmed first (MBP: separator briefly reports x 0 while being placed)")
    check(C.initialCollapseStep(order: .ok, previous: .parkedInOverflow, attempt: 2) == .retry, "order just changed → confirm")
    check(C.initialCollapseStep(order: .ok, previous: .ok, attempt: 1) == .collapse, "two consistent safe readings → collapse")
    check(C.initialCollapseStep(order: .alwaysHiddenUnknown, previous: .alwaysHiddenUnknown, attempt: 1) == .collapse,
          "always-hidden still unknown → normal collapse is safe")
    check(C.initialCollapseStep(order: .parkedInOverflow, previous: .parkedInOverflow, attempt: 10) == .collapse,
          "gives up after 10 tries (collapse() then refuses and warns)")
}

@MainActor
func checkCollapseLength() {
    print("Collapsed separator length")
    check(CollapseStrategy.forMajorVersion(14) == .pushOffscreen && CollapseStrategy.forMajorVersion(26) == .pushOffscreen,
          "macOS 14–26 → push off-screen")
    check(CollapseStrategy.forMajorVersion(27) == .systemOverflow && CollapseStrategy.forMajorVersion(28) == .systemOverflow,
          "macOS 27+ → system overflow")
    check(SeparatorMetrics.collapsedLength(strategy: .pushOffscreen, screenWidth: 1920, windowPadding: 16) == 10_000, "classic length 10 000")
    for (width, padding) in [(1920.0, 16.0), (1512.0, 16.0), (1728.0, 16.0), (2560.0, 16.0), (1920.0, 0.0), (1920.0, 40.0)] {
        let len = SeparatorMetrics.collapsedLength(strategy: .systemOverflow, screenWidth: CGFloat(width), windowPadding: CGFloat(padding))
        check(len + max(CGFloat(padding), 8) < CGFloat(width) / 2 && len > CGFloat(width) / 2 - 80,
              "macOS 27 length \(Int(len)) keeps window below half of \(Int(width)) (padding \(Int(padding)))")
    }
    // Measured on this Mac (1920 pt): window 916 → overflowed (hidden), 966 → dropped (not hidden).
    let here = SeparatorMetrics.collapsedLength(strategy: .systemOverflow, screenWidth: 1920, windowPadding: 16)
    check(here + 16 > 916 && here + 16 < 960, "1920 pt: window \(Int(here + 16)) between measured overflow (916) and drop (960) limits")
    check(SeparatorMetrics.collapsedLength(strategy: .systemOverflow, screenWidth: 100, windowPadding: 16) == 120, "tiny screen floor")

    print("macOS 27 toggle padding (OverflowPlanner)")
    // Measured here: Claude's menus end at x 396; toggle window 27 wide; collapsed separator window 944.
    let sepWindow: CGFloat = 944
    let none = OverflowPlanner.toggleExtraWidth(toggleMaxX: 1273, toggleWindowWidth: 27, separatorWindowWidth: sepWindow, menusMaxX: 396, screenWidth: 1920)
    check(none == 0, "toggle at 1273: separator already overflows → no padding")
    let wide = OverflowPlanner.toggleExtraWidth(toggleMaxX: 1527, toggleWindowWidth: 27, separatorWindowWidth: sepWindow, menusMaxX: 396, screenWidth: 1920)
    let available: CGFloat = 1527 - 27 - (396 + OverflowPlanner.menuGap)
    check(wide > 0 && sepWindow + wide > available + 40, "toggle at 1527: padding \(Int(wide)) makes the separator overflow with margin")
    check(27 + wide <= 1527 - (396 + OverflowPlanner.menuGap) - OverflowPlanner.toggleRoom + 27, "widened toggle still fits and leaves room for «")
    let shortMenus = OverflowPlanner.toggleExtraWidth(toggleMaxX: 1527, toggleWindowWidth: 27, separatorWindowWidth: sepWindow, menusMaxX: 150, screenWidth: 1920)
    check(shortMenus > wide, "shorter app menus → more padding (\(Int(shortMenus)))")
    let between = OverflowPlanner.toggleExtraWidth(toggleMaxX: 1527, toggleWindowWidth: 27, itemsBetween: 120,
                                                   separatorWindowWidth: sepWindow, menusMaxX: 396, screenWidth: 1920)
    check(between == max(0, wide - 120), "icons between separator and toggle reduce the padding (\(Int(between)))")
    let betweenRoom = OverflowPlanner.toggleExtraWidth(toggleMaxX: 1527, toggleWindowWidth: 27, itemsBetween: 900,
                                                       separatorWindowWidth: 200, menusMaxX: 396, screenWidth: 1920)
    check(27 + betweenRoom + 900 <= 1527 - 404 - OverflowPlanner.toggleRoom + 1, "icons between keep their room (\(Int(betweenRoom)))")
    let crowded = OverflowPlanner.toggleExtraWidth(toggleMaxX: 1527, toggleWindowWidth: 27, separatorWindowWidth: sepWindow, menusMaxX: 1480, screenWidth: 1920)
    check(crowded == 0, "no room at all → no padding (never pushes the toggle out)")
    let capped = OverflowPlanner.toggleExtraWidth(toggleMaxX: 3800, toggleWindowWidth: 27, separatorWindowWidth: 1900, menusMaxX: 100,
                                                  screenWidth: 3840)
    check(capped > 0 && capped + 27 < 1920, "padding capped below half the screen so the toggle is never dropped (\(Int(capped)))")
    check(capped + 27 + 1900 > 3800 - 108, "wide display: separator + widened toggle cover the whole status area")
    // Notched 14" MacBook Pro (measured): 1512 pt wide, auxiliaryTopRightArea = (848.5, 950, 663.5, 32).
    let notch = MenuBarGeometry.notchMaxX(screenMaxX: 1512, auxiliaryTopRightWidth: 663.5)
    check(notch == 848.5, "notch right edge from auxiliaryTopRightArea (848.5)")
    check(MenuBarGeometry.notchMaxX(screenMaxX: 1920, auxiliaryTopRightWidth: nil) == nil
          && MenuBarGeometry.notchMaxX(screenMaxX: 1920, auxiliaryTopRightWidth: 0) == nil, "no notch on the Mac Studio display")
    check(OverflowPlanner.statusAreaMinX(menusMaxX: 300, notchMaxX: 848.5) == 848.5, "short app menus: status items start right of the notch")
    check(OverflowPlanner.statusAreaMinX(menusMaxX: 900, notchMaxX: 848.5) == 900, "menus continuing right of the notch win")
    check(OverflowPlanner.statusAreaMinX(menusMaxX: 396, notchMaxX: nil) == 396, "no notch: app menus only")
    let mbpSep = SeparatorMetrics.collapsedLength(strategy: .systemOverflow, screenWidth: 1512, windowPadding: 16) + 16
    let mbpArea = OverflowPlanner.statusAreaMinX(menusMaxX: 300, notchMaxX: notch)
    let mbpPad = OverflowPlanner.toggleExtraWidth(toggleMaxX: 1100, toggleWindowWidth: 27, itemsBetween: 60,
                                                  separatorWindowWidth: mbpSep, menusMaxX: mbpArea, screenWidth: 1512)
    check(mbpPad == 0, "MBP: the collapsed separator (\(Int(mbpSep))) never fits right of the notch → no toggle padding")
    // Property: whatever the inputs, the widened toggle + the icons between it and the separator stay in
    // the usable strip (right of menus / notch) with room for «, or no padding is added at all.
    var planOK = true
    for toggleMaxX in stride(from: 900.0, through: 1500.0, by: 50.0) {
        for menus in [150.0, 300.0, 600.0, 900.0] {
            for between in [0.0, 60.0, 200.0] {
                let area = OverflowPlanner.statusAreaMinX(menusMaxX: CGFloat(menus), notchMaxX: notch)
                let extra = OverflowPlanner.toggleExtraWidth(toggleMaxX: CGFloat(toggleMaxX), toggleWindowWidth: 27, itemsBetween: CGFloat(between),
                                                             separatorWindowWidth: mbpSep, menusMaxX: area, screenWidth: 1512)
                let leftEdge = CGFloat(toggleMaxX) - 27 - extra - CGFloat(between)
                if extra < 0 || (extra > 0 && leftEdge < area + OverflowPlanner.menuGap + OverflowPlanner.toggleRoom - 1) { planOK = false }
            }
        }
    }
    check(planOK, "MBP: padding never pushes the toggle or the visible icons under the notch / into «")
    check(OverflowPlanner.settle(current: 200, proposed: 205) == 200, "hysteresis keeps small changes")
    check(OverflowPlanner.settle(current: 200, proposed: 230) == 230, "larger changes applied")
    check(OverflowPlanner.settle(current: 200, proposed: 0) == 0 && OverflowPlanner.settle(current: 0, proposed: 3) == 3, "switching on/off is immediate")
}

@MainActor
func checkClassification() {
    print("Classification")
    let bands = [CGRect(x: 0, y: 0, width: 1920, height: 30)]
    let anchors = MenuBarAnchors(toggle: CGRect(x: 1247, y: 0, width: 26, height: 30),
                                 separator: CGRect(x: 1219, y: 0, width: 28, height: 30),
                                 alwaysHidden: CGRect(x: 1100, y: 0, width: 24, height: 30))
    func cls(_ x: CGFloat, y: CGFloat = 3, w: CGFloat = 24, a: MenuBarAnchors? = nil, chevron: CGRect? = nil, parked: Bool = false) -> MenuBarSection {
        MenuBarClassifier.classify(frame: CGRect(x: x, y: y, width: w, height: 24), anchors: a ?? anchors, bands: bands,
                                   overflowChevron: chevron, isParked: parked)
    }
    check(cls(1280) == .visible, "right of toggle → visible")
    check(cls(1625, w: 22) == .visible, "system extra far right → visible")
    check(cls(1188) == .hidden, "between separators → hidden")
    check(cls(1130) == .hidden, "just right of always-hidden separator → hidden")
    check(cls(1050) == .alwaysHidden, "left of always-hidden separator → always hidden")
    check(cls(-4000) == .alwaysHidden, "far off-screen left → always hidden")
    check(cls(7, y: 1068) == .offscreen, "item turned off in System Settings (y 1068) → offscreen")
    check(cls(1000, w: 0) == .offscreen, "zero-width → offscreen")
    let noAH = MenuBarAnchors(toggle: anchors.toggle, separator: anchors.separator)
    check(cls(1050, a: noAH) == .hidden, "without always-hidden separator everything left is hidden")
    // macOS 27 overflow: items parked on the "«" button.
    let chevron = CGRect(x: 1222.5, y: 1, width: 17.5, height: 27)
    check(cls(1208, chevron: chevron) == .overflow, "item overlapping the « chevron → overflow")
    check(cls(1188, chevron: chevron) == .hidden, "item next to the chevron is not overflow")
    check(cls(1188, parked: true) == .overflow, "parked item → overflow")

    let parked = MenuBarClassifier.parkedIndices([
        CGRect(x: 1208, y: 3, width: 24, height: 24), CGRect(x: 1208, y: 3, width: 24, height: 24),
        CGRect(x: 1280, y: 3, width: 24, height: 24), CGRect(x: 7, y: 1068, width: 24, height: 24),
    ])
    check(parked == [0, 1], "stacked items detected as parked")

    let items = [
        MenuBarItemInfo(id: "a", pid: 1, name: "A", frame: CGRect(x: 1280, y: 3, width: 24, height: 24), source: .accessibility, isSystemItem: false, isMovable: true),
        MenuBarItemInfo(id: "b", pid: 2, name: "B", frame: CGRect(x: 1188, y: 3, width: 24, height: 24), source: .accessibility, isSystemItem: false, isMovable: true),
        MenuBarItemInfo(id: "c", pid: 3, name: "C", frame: CGRect(x: 7, y: 1068, width: 24, height: 24), source: .accessibility, isSystemItem: false, isMovable: true),
        MenuBarItemInfo(id: "d", pid: 4, name: "D", frame: CGRect(x: 1050, y: 3, width: 24, height: 24), source: .accessibility, isSystemItem: false, isMovable: true),
        MenuBarItemInfo(id: "e", pid: 5, name: "E", frame: CGRect(x: 1400, y: 3, width: 24, height: 24), source: .accessibility, isSystemItem: false, isMovable: true),
    ]
    let all = MenuBarClassifier.classifyAll(items, anchors: anchors, bands: bands, overflowChevron: nil)
    check(all.map(\.section) == [.visible, .hidden, .offscreen, .alwaysHidden, .visible], "classifyAll with anchors")
    let sorted = MenuBarClassifier.sortedForDisplay(all).map(\.id)
    check(sorted == ["a", "e", "b", "d", "c"], "display order: visible, hidden, always hidden, offscreen (left → right)")
    let noAnchors = MenuBarClassifier.classifyAll(items, anchors: nil, bands: bands, overflowChevron: nil)
    check(noAnchors.map(\.section) == [.visible, .visible, .offscreen, .visible, .visible], "classifyAll without separators (disabled)")
}

@MainActor
func checkStateMachine() {
    print("Reveal state machine (pure)")
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    var m = RevealStateMachine(visibility: .collapsed, autoCollapse: true, delay: 10)
    check(m.tick(now: t0, userIsInteracting: false) == .idle && m.nextCheckDelay(now: t0) == nil, "collapsed: idle, no timer")
    m.expand(now: t0)
    check(m.visibility == .expanded && m.deadline == t0.addingTimeInterval(10), "expand arms deadline +10 s")
    check(m.nextCheckDelay(now: t0.addingTimeInterval(4)).map { approx($0, 6) } == true, "next check at the deadline")
    if case .waiting(let remaining) = m.tick(now: t0.addingTimeInterval(9.9), userIsInteracting: false) {
        check(approx(remaining, 0.1) && m.isExpanded, "waiting 0.1 s before the deadline")
    } else {
        check(false, "waiting before deadline")
    }
    check(m.tick(now: t0.addingTimeInterval(10), userIsInteracting: true) == .postponed && m.isExpanded, "overdue + interacting → postponed")
    check(m.nextCheckDelay(now: t0.addingTimeInterval(10.2)) == RevealStateMachine.recheckInterval, "re-check every 0.5 s while overdue")
    check(m.tick(now: t0.addingTimeInterval(10.5), userIsInteracting: false) == .collapsed && m.visibility == .collapsed, "collapses once pointer leaves")
    check(m.deadline == nil, "deadline cleared after collapse")

    m.expand(now: t0)
    m.collapse()
    check(m.visibility == .collapsed && m.deadline == nil && m.tick(now: t0.addingTimeInterval(20), userIsInteracting: false) == .idle,
          "manual collapse cancels the deadline")

    m.expand(now: t0)
    m.expand(now: t0.addingTimeInterval(8))
    check(m.deadline == t0.addingTimeInterval(18), "re-expand resets the deadline")

    m.toggle(now: t0)
    check(m.visibility == .collapsed, "toggle while expanded → collapse")
    m.toggle(now: t0, revealAlwaysHidden: true)
    check(m.visibility == .expandedAll, "⌥-toggle while collapsed → expanded all")
    m.toggle(now: t0)
    check(m.visibility == .collapsed, "toggle while expanded all → collapse")
    m.expand(now: t0)
    m.toggle(now: t0, revealAlwaysHidden: true)
    check(m.visibility == .expandedAll, "⌥-toggle while expanded → reveal always-hidden too")

    var off = RevealStateMachine(visibility: .collapsed, autoCollapse: false, delay: 10)
    off.expand(now: t0)
    check(off.deadline == nil && off.tick(now: t0.addingTimeInterval(1000), userIsInteracting: false) == .idle && off.isExpanded,
          "auto re-hide off: stays expanded")
    off.updateSettings(autoCollapse: true, delay: 30, now: t0.addingTimeInterval(5))
    check(off.deadline == t0.addingTimeInterval(35), "enabling auto re-hide while expanded arms deadline from now")

    var refused = RevealStateMachine(visibility: .expanded, autoCollapse: true, delay: 10)
    refused.expand(now: t0)
    refused.collapseRefused()
    check(refused.isExpanded && refused.deadline == nil, "refused collapse: expanded, no retry loop")
    refused.reset(to: .collapsed)
    check(refused.visibility == .collapsed && refused.deadline == nil, "reset")
}

@MainActor
func checkDriver() {
    print("Auto-collapse driver (injected clock + scheduler)")
    // 1. expand → delay → collapse
    do {
        let time = FakeTime()
        let driver = makeDriver(time)
        var changes: [RevealStateMachine.Visibility] = []
        driver.onVisibilityChange = { changes.append($0) }
        let t0 = time.now
        driver.expand()
        check(driver.visibility == .expanded && driver.hasPendingCheck && time.pendingCount == 1, "expand schedules one check")
        time.advance(to: t0.addingTimeInterval(9.9))
        check(driver.visibility == .expanded, "still expanded at 9.9 s")
        time.advance(to: t0.addingTimeInterval(10))
        check(driver.visibility == .collapsed && changes == [.expanded, .collapsed], "collapsed at 10 s")
        check(!driver.hasPendingCheck && time.pendingCount == 0, "no timer left after collapse")
    }
    // 2. postponed while the pointer is in the bar, re-checked every 0.5 s
    do {
        let time = FakeTime()
        var interacting = true
        let driver = makeDriver(time, interacting: { interacting })
        let t0 = time.now
        driver.expand()
        time.advance(to: t0.addingTimeInterval(12.2))
        check(driver.visibility == .expanded, "postponed while pointer in menu bar")
        check(time.firedCount == 5, "re-checked at 10, 10.5, 11, 11.5, 12 s (\(time.firedCount) checks)")
        interacting = false
        time.advance(to: t0.addingTimeInterval(12.49))
        check(driver.visibility == .expanded, "not collapsed before the next 0.5 s check")
        time.advance(to: t0.addingTimeInterval(12.5))
        check(driver.visibility == .collapsed, "collapsed at the first check after leaving")
    }
    // 3. manual collapse cancels the timer
    do {
        let time = FakeTime()
        let driver = makeDriver(time)
        driver.expand()
        time.advance(by: 3)
        check(driver.collapse(), "manual collapse accepted")
        check(!driver.hasPendingCheck && time.pendingCount == 0 && driver.deadline == nil, "manual collapse cancels the timer")
        let fired = time.firedCount
        time.advance(by: 30)
        check(time.firedCount == fired && driver.visibility == .collapsed, "nothing fires afterwards")
    }
    // 4. re-expand resets the countdown
    do {
        let time = FakeTime()
        let driver = makeDriver(time)
        let t0 = time.now
        driver.expand()
        time.advance(to: t0.addingTimeInterval(8))
        driver.expand()
        check(time.pendingCount == 1, "old timer replaced, not duplicated")
        time.advance(to: t0.addingTimeInterval(17.9))
        check(driver.visibility == .expanded, "still expanded at 17.9 s (reset at 8 s)")
        time.advance(to: t0.addingTimeInterval(18))
        check(driver.visibility == .collapsed, "collapsed 10 s after the re-expand")
    }
    // 5. safety veto (separator right of toggle)
    do {
        let time = FakeTime()
        let driver = makeDriver(time)
        var allowed = false
        driver.canCollapse = { allowed }
        driver.expand()
        time.advance(by: 10)
        check(driver.visibility == .expanded && driver.deadline == nil && !driver.hasPendingCheck,
              "unsafe order: auto-collapse refused, no retry loop")
        check(!driver.collapse() && driver.visibility == .expanded, "unsafe order: manual collapse refused")
        allowed = true
        check(driver.collapse() && driver.visibility == .collapsed, "collapse works once the order is fixed")
    }
    // 6. auto re-hide disabled / settings change while expanded
    do {
        let time = FakeTime()
        let driver = makeDriver(time, autoCollapse: false)
        driver.expand()
        check(!driver.hasPendingCheck, "auto re-hide off: no timer")
        time.advance(by: 100)
        check(driver.visibility == .expanded, "auto re-hide off: stays expanded")
        let t1 = time.now
        driver.updateSettings(autoCollapse: true, delay: 5)
        check(driver.deadline == t1.addingTimeInterval(5) && driver.hasPendingCheck, "turning it on arms 5 s from now")
        time.advance(by: 5)
        check(driver.visibility == .collapsed, "collapsed after the new delay")
    }
    // 7. a stale asynchronous probe result is ignored
    do {
        let time = FakeTime()
        var pending: ((Bool) -> Void)?
        let driver = AutoCollapseDriver(machine: RevealStateMachine(visibility: .collapsed, autoCollapse: true, delay: 10),
                                        now: { [unowned time] in time.now }, schedule: time.scheduler,
                                        probe: { completion in pending = completion })
        driver.expand()
        time.advance(by: 10)
        check(pending != nil && driver.visibility == .expanded, "probe in flight at the deadline")
        driver.expand() // user clicks again while the probe runs
        pending?(false)
        check(driver.visibility == .expanded, "stale probe result does not collapse after a re-expand")
        pending = nil
        time.advance(by: 10)
        pending?(false)
        check(driver.visibility == .collapsed, "fresh probe result collapses")
    }
    // 8. toggle + ⌥
    do {
        let time = FakeTime()
        let driver = makeDriver(time)
        driver.toggle(revealAlwaysHidden: true)
        check(driver.visibility == .expandedAll, "⌥-click reveals the always-hidden section")
        driver.toggle()
        check(driver.visibility == .collapsed && !driver.hasPendingCheck, "click again collapses and cancels")
        driver.invalidate()
    }
}

@MainActor
func checkDragPlanner() {
    print("⌘-drag event sequence builder")
    let start = CGPoint(x: 1300, y: 15)
    let end = CGPoint(x: 1215, y: 15)
    let seq = DragPlanner.commandDragSequence(from: start, to: end, steps: 6)
    let kinds = seq.map(\.kind)
    check(kinds == [.commandDown, .mouseMoved, .leftMouseDown] + Array(repeating: .leftMouseDragged, count: 6) + [.leftMouseUp, .commandUp],
          "event order: ⌘↓ move ↓ drag×6 ↑ ⌘↑")
    check(seq.filter(\.isMouseEvent).allSatisfy { $0.flags.contains(.maskCommand) }, "every mouse event carries ⌘")
    check(seq.first?.flags == .maskCommand && seq.last?.flags == [], "⌘ pressed first, released last")
    check(seq[1].location == start && seq[2].location == start, "move + mouse-down at the item centre")
    let drags = seq.filter { $0.kind == .leftMouseDragged }
    check(drags.last?.location == end && seq[seq.count - 2].location == end, "last drag + mouse-up at the drop point")
    check(zip(drags, drags.dropFirst()).allSatisfy { $0.location.x > $1.location.x } && drags.allSatisfy { $0.location.y == 15 },
          "drag steps move monotonically along the bar")
    check(approx(drags.first!.location.x, 1300 - 85.0 / 6), "first step = 1/6 of the way")
    check(seq[2].cgEventType == .leftMouseDown && drags[0].cgEventType == .leftMouseDragged
          && seq[seq.count - 2].cgEventType == .leftMouseUp && seq[0].cgEventType == .keyDown
          && seq.last?.cgEventType == .keyUp && seq[1].cgEventType == .mouseMoved, "CGEventType mapping")
    let total = DragPlanner.duration(of: seq)
    check(total > 0.4 && total < 1.5, "drag takes \(String(format: "%.2f", total)) s (0.4–1.5 s)")
    check(DragPlanner.commandDragSequence(from: start, to: end, steps: 0).filter { $0.kind == .leftMouseDragged }.count == 1,
          "steps < 1 → one drag step")

    let sep = CGRect(x: 1219, y: 0, width: 28, height: 30)
    let toggle = CGRect(x: 1247, y: 0, width: 26, height: 30)
    let hide = DragPlanner.dropPoint(for: .hidden, separator: sep, toggle: toggle)
    check(hide == CGPoint(x: 1215, y: 15), "hide target just left of the separator (\(hide))")
    let show = DragPlanner.dropPoint(for: .visible, separator: sep, toggle: toggle)
    check(show.x > sep.midX && show.x < toggle.midX && show.y == 15, "show target right of separator, left of toggle centre (\(show))")
    let tight = DragPlanner.dropPoint(for: .visible, separator: sep, toggle: CGRect(x: 1247, y: 0, width: 4, height: 30))
    check(tight.x > sep.midX, "show target stays right of the separator even with a tiny toggle")
}

@MainActor
func checkScannerHelpers() {
    print("Scanner helpers")
    check(MenuBarItemScanner.shortName("Wi‑Fi，已接入，3格") == "Wi‑Fi", "short name from AX description")
    check(MenuBarItemScanner.shortName("时钟") == "时钟", "plain name kept")
    check(MenuBarItemScanner.singleLine("Syncthing v2.1.5\nUp to date") == "Syncthing v2.1.5 Up to date", "multi-line titles flattened")
    check(MenuBarItemScanner.shortName("  ") == nil && MenuBarItemScanner.shortName(nil) == nil, "empty → nil")
    check(MenuBarItemScanner.itemKey(owner: "com.apple.MenuBarAgent", identifier: "com.apple.menuextra.wifi", ordinal: 3)
          == "com.apple.MenuBarAgent|com.apple.menuextra.wifi", "key uses identifier when present")
    check(MenuBarItemScanner.itemKey(owner: "com.example.app", identifier: nil, ordinal: 1) == "com.example.app|#1", "key falls back to ordinal")
    check(MoveDestination.hidden.title == "移到隐藏区" && MoveDestination.visible.title == "移到显示区", "button titles")
    check(MenuBarSection.visible.title == "显示区" && MenuBarSection.hidden.title == "隐藏区", "section titles")

    print("State text")
    typealias C = MenuBarHiderController
    check(C.stateText(enabled: false, active: false, visibility: .expanded, secondsUntilCollapse: nil) == "已停用，所有图标正常显示", "disabled")
    check(C.stateText(enabled: true, active: true, visibility: .collapsed, secondsUntilCollapse: nil) == "隐藏区的图标已收起", "collapsed")
    check(C.stateText(enabled: true, active: true, visibility: .expanded, secondsUntilCollapse: 7) == "图标已显示，7 秒后自动隐藏", "countdown")
    check(C.stateText(enabled: true, active: true, visibility: .expandedAll, secondsUntilCollapse: 0)
          == "图标已显示（含永久隐藏区），鼠标离开菜单栏后自动隐藏", "overdue (postponed) never reads \"0 秒后\"")
    check(C.stateText(enabled: true, active: true, visibility: .expanded, secondsUntilCollapse: nil) == "图标已显示", "auto re-hide off")
    check(C.stateText(enabled: true, active: true, visibility: .expandedAll, secondsUntilCollapse: 4, alwaysHiddenEnabled: false)
          == "图标已显示，4 秒后自动隐藏", "no 永久隐藏区 → never mentions it (item listing reveals \"all\")")
    check(C.stateText(enabled: true, active: true, visibility: .collapsed, secondsUntilCollapse: nil, hiddenAppCount: 5)
          == "已隐藏 5 个 App 的图标", "native: hidden app count")
    check(C.stateText(enabled: true, active: true, visibility: .collapsed, secondsUntilCollapse: nil, hiddenAppCount: 0)
          == "图标已收起（没有需要隐藏的 App）", "native: nothing to hide")
    check(C.stateText(enabled: true, active: true, visibility: .collapsed, secondsUntilCollapse: nil, hiddenAppCount: 2, hiding: true)
          == "正在隐藏图标…", "native: request pending")
    check(C.menuStatusLine(engine: "系统原生隐藏", state: "已隐藏 5 个 App 的图标") == "系统原生隐藏 · 已隐藏 5 个 App 的图标", "menu status line")
    check(C.engineTitle(.native, strategy: .systemOverflow) == "系统原生隐藏" && C.engineTitle(.legacy, strategy: .systemOverflow) == "兼容模式"
          && C.engineTitle(.legacy, strategy: .pushOffscreen) == "分隔线模式", "engine titles")
}

@MainActor
func probeListing() {
    print("Read-only probe of the current menu-bar items (informational)")
    softFailures = sessionLocked
    defer { softFailures = false }
    let screens = ScreenGeometry.current()
    let bands = MenuBarGeometry.menuBarBands(screens: screens, thickness: NSStatusBar.system.thickness)
    let apps = RunningAppInfo.current()
    print("  screens: \(screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) bar \(Int(MenuBarGeometry.menuBarHeight(of: $0, thickness: NSStatusBar.system.thickness)))\($0.hasNotch ? " notch" : "")" })")
    print("  strategy: \(CollapseStrategy.current.rawValue), 辅助功能: \(Permissions.isGranted(.accessibility)), 屏幕录制: \(Permissions.isGranted(.screenRecording))")
    var result: MenuBarScanResult?
    let started = Date()
    DispatchQueue.global(qos: .userInitiated).async {
        let r = MenuBarItemScanner.scan(apps: apps, excludingPID: getpid(), bands: bands)
        DispatchQueue.main.async { result = r }
    }
    guard waitUntil(15, { result != nil }), let result else {
        print("  (scan did not finish in 15 s — skipped)")
        return
    }
    print("  source: \(result.source?.rawValue ?? "none"), \(result.items.count) items in \(String(format: "%.0f", Date().timeIntervalSince(started) * 1000)) ms"
          + (result.note.map { ", note: \($0)" } ?? "")
          + (result.overflowChevron.map { ", « at x=\(Int($0.minX))" } ?? ""))
    let classified = MenuBarClassifier.classifyAll(result.items, anchors: nil, bands: bands, overflowChevron: result.overflowChevron)
    for item in MenuBarClassifier.sortedForDisplay(classified) {
        let detail = item.detail.map { " — \($0)" } ?? ""
        print("    [\(item.section.title)] \(item.name)\(detail)  x=\(Int(item.frame.minX)) y=\(Int(item.frame.minY)) w=\(Int(item.frame.width))"
              + (item.isSystemItem ? " (系统)" : "") + (item.isMovable ? "" : " (不可移动)"))
    }
    check(result.items.allSatisfy { $0.pid != getpid() }, "own items excluded from the listing")

    // How 系统原生隐藏 would classify this bar, with a running OneSwitch's「<」as the boundary.
    let realToggle = result.items.first { $0.bundleID == AppEnvironment.bundleIdentifier && ($0.detail ?? "").contains("菜单栏图标") }
    let inventory = MenuBarInventory(items: result.items, overflowChevron: result.overflowChevron, bands: bands)
    let layout = NativeLayoutResolver.resolve(inventory: inventory, toggle: realToggle?.frame, ownBundleIDs: [AppEnvironment.bundleIdentifier])
    print("  native placement (boundary: " + (realToggle.map { "running OneSwitch「<」 at x=\(Int($0.frame.minX))" } ?? "none found")
          + (layout.toggleUsable ? "" : ", not usable") + "):")
    for app in layout.apps {
        let hides = app.bundleID != nil && NativeHidingPlan.shouldHide(rule: .auto, placement: app.placement)
        print("    \(app.name) [\(app.bundleID ?? "no bundle id")] — \(app.placement.title)\(app.bundleID == nil ? "" : hides ? " → 收起时隐藏" : " → 收起时显示")")
    }
}

@MainActor
func checkIntegration() {
    print("Integration (兼容模式 / separator engine): module start → collapse → expand → stop (own items only)"
          + (sessionLocked ? " — screen locked: layout checks are informational" : ""))
    softFailures = sessionLocked
    defer { softFailures = false }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    let suiteName = "oneswitch.menubarhidercheck.integration"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    let suffix = "-selfcheck"
    let module = MenuBarHiderModule(defaults: suite, autosaveSuffix: suffix)
    let controller = module.controller
    check(controller.engineKind == .legacy || !controller.isActive, "no native dependencies → separator engine")
    check(module.id == "menubar" && module.displayName == "菜单栏图标" && module.symbolName == "menubar.rectangle", "module identity")
    _ = module.settingsView()
    module.start()
    check(controller.isActive && controller.diagnostics().isInstalled, "status items installed on start")

    // Our new items are inserted left-most; on a full menu bar (or left of a running OneSwitch's collapsed
    // separator) macOS 27 puts them straight into the "«" overflow, so there may be no usable layout.
    // Frames are transient while the items are placed (the MBP briefly reports the separator at x 0), so
    // require the same laid-out order for 0.3 s.
    var stableSince: Date?
    var lastOrder: SeparatorOrder?
    let laidOut = waitUntil(3) {
        let order = controller.diagnostics().order
        if order != lastOrder { lastOrder = order; stableSince = Date() }
        let usable = order != .unknown && order != .parkedInOverflow
        return usable && Date().timeIntervalSince(stableSince ?? Date()) >= 0.3
    }
    if laidOut {
        checkLaidOutIntegration(module: module, controller: controller)
    } else {
        let order = controller.diagnostics().order
        print("  (own items not laid out: " + (order == .parkedInOverflow ? "parked in the « overflow, menu bar full" : "no frames — in «, or no window server")
              + "; layout-dependent checks skipped)")
        // Safety and lifecycle checks that need no layout.
        controller.collapse()
        check(controller.visibility != .collapsed, "never collapses while the separator order is not verified")
        check(controller.warningText != SeparatorOrder.separatorRightOfToggle.warning, "no bogus \"drag the separator\" warning")
        check(module.menuItems().first?.title == "立即隐藏图标" && controller.diagnostics().separatorLength == SeparatorMetrics.expandedLength,
              "stays expanded with a normal separator")
        controller.store.update { $0.alwaysHiddenEnabled = true }
        check(controller.diagnostics().alwaysHiddenLength == SeparatorMetrics.expandedLength,
              "always-hidden separator added live, not widened without a verified position")
        controller.store.update { $0.alwaysHiddenEnabled = false }
        check(controller.diagnostics().alwaysHiddenLength == nil, "always-hidden separator removed live")
        controller.store.update { $0.enabled = false }
        check(!controller.isActive && !controller.diagnostics().isInstalled, "disabling removes the items")
        check(module.menuItems().count == 2, "disabled menu: info + enable")
        controller.store.update { $0.enabled = true }
        check(controller.isActive && controller.diagnostics().isInstalled, "re-enabling reinstalls the items")
    }

    module.stop()
    check(!controller.isActive && !controller.diagnostics().isInstalled, "stop removes every status item")
    check(controller.visibility == .expanded, "stop restores normal lengths (expanded)")
    module.stop() // idempotent

    // Clean up anything the status bar persisted for our test autosave names.
    let std = UserDefaults.standard
    for key in std.dictionaryRepresentation().keys where key.hasSuffix(suffix) && key.hasPrefix("NSStatusItem") {
        std.removeObject(forKey: key)
    }
    suite.removePersistentDomain(forName: suiteName)
}

/// The part of the integration run that needs our items to be laid out in the menu bar.
@MainActor
func checkLaidOutIntegration(module: MenuBarHiderModule, controller: MenuBarHiderController) {
    let d0 = controller.diagnostics()
    check(d0.order == .ok, "new separator appears left of the toggle (\(Int(d0.separatorFrame?.minX ?? -1)) < \(Int(d0.toggleFrame?.minX ?? -1)))")
    check(waitUntil(4) { controller.visibility == .collapsed }, "collapsed automatically at launch")
    let d1 = controller.diagnostics()
    check(d1.separatorLength.map { approx($0, d1.collapsedLength) } == true, "collapsed separator length \(Int(d1.separatorLength ?? -1)) = \(Int(d1.collapsedLength))")
    if controller.strategy == .systemOverflow, let screen = NSScreen.main {
        check(d1.collapsedLength + 8 < screen.frame.width / 2, "macOS 27: collapsed window stays below half the screen width")
    }
    check(module.menuItems().first?.title == "显示隐藏的图标（10 秒后自动隐藏）", "menu offers reveal with delay")

    controller.expand()
    check(controller.visibility == .expanded, "expand")
    let d2 = controller.diagnostics()
    check(d2.separatorLength.map { approx($0, SeparatorMetrics.expandedLength) } == true, "expanded separator length restored")
    check(controller.secondsUntilCollapse.map { $0 >= 9 && $0 <= 10 } == true, "auto re-hide armed (~10 s)")
    check(module.menuItems().first?.title == "立即隐藏图标", "menu offers hide now")

    controller.store.update { $0.alwaysHiddenEnabled = true }
    check(controller.diagnostics().alwaysHiddenLength != nil, "always-hidden separator added")
    check(waitUntil(2) {
        let d = controller.diagnostics()
        return d.alwaysHiddenFrame != nil && (d.alwaysHiddenFrame!.minX < d.separatorFrame!.minX)
    }, "always-hidden separator appears left of the separator")
    controller.store.update { $0.alwaysHiddenEnabled = false }
    check(controller.diagnostics().alwaysHiddenLength == nil, "always-hidden separator removed")

    controller.collapse()
    check(controller.visibility == .collapsed, "manual collapse")
    if controller.visibility == .collapsed {
        // 永久隐藏区 switched on while collapsed: its frame cannot be verified yet, so it must not be
        // widened on the next expand (it used to reuse the stale "ok" order and widen immediately).
        controller.store.update { $0.alwaysHiddenEnabled = true }
        check(controller.orderStatus == .alwaysHiddenUnknown, "always-hidden added while collapsed: position not trusted yet")
        controller.expand()
        check(controller.diagnostics().alwaysHiddenLength.map { approx($0, SeparatorMetrics.expandedLength) } == true,
              "…and not widened on the next expand before its position was verified")
        controller.store.update { $0.alwaysHiddenEnabled = false }
        check(controller.diagnostics().alwaysHiddenLength == nil, "always-hidden separator removed again")
        controller.collapse()
        check(controller.visibility == .collapsed, "collapse again")
    }
    controller.store.update { $0.enabled = false }
    check(!controller.isActive && !controller.diagnostics().isInstalled, "disabling removes the items")
    check(module.menuItems().count == 2, "disabled menu: info + enable")
    controller.store.update { $0.enabled = true }
    check(controller.isActive, "re-enabling reinstalls the items")
    _ = waitUntil(1.5) { controller.visibility == .collapsed }
}

/// Opt-in (MENUBAR_E2E=1): places our toggle / separator toward the right via saved positions so that
/// real icons of other apps sit left of the separator, collapses, and verifies via Accessibility that
/// those icons are really hidden (parked in macOS 27's "«" overflow or pushed off-screen). Icons come
/// back when the items are removed a few seconds later. No input events are posted.
@MainActor
func checkEndToEndHiding() {
    guard ProcessInfo.processInfo.environment["MENUBAR_E2E"] == "1" else {
        print("End-to-end hiding: skipped (set MENUBAR_E2E=1 to run; briefly hides this Mac's icons)")
        return
    }
    print("End-to-end hiding (opt-in)")
    guard Permissions.isGranted(.accessibility) else {
        print("  (辅助功能 not granted — skipped)")
        return
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    let suffix = "-e2e"
    let std = UserDefaults.standard
    let toggleKey = "NSStatusItem Preferred Position OneSwitchHiderToggle\(suffix)"
    let sepKey = "NSStatusItem Preferred Position OneSwitchHiderSeparator\(suffix)"
    std.set(400.0, forKey: toggleKey)   // distance from the right edge
    std.set(430.0, forKey: sepKey)
    let suiteName = "oneswitch.menubarhidercheck.e2e"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    let module = MenuBarHiderModule(defaults: suite, autosaveSuffix: suffix)
    let controller = module.controller
    defer {
        module.stop()
        for key in std.dictionaryRepresentation().keys where key.hasPrefix("NSStatusItem") && key.hasSuffix(suffix) {
            std.removeObject(forKey: key)
        }
        suite.removePersistentDomain(forName: suiteName)
    }

    func scan() -> MenuBarScanResult? {
        let bands = MenuBarGeometry.menuBarBands(screens: ScreenGeometry.current(), thickness: NSStatusBar.system.thickness)
        let apps = RunningAppInfo.current()
        var result: MenuBarScanResult?
        DispatchQueue.global().async {
            let r = MenuBarItemScanner.scan(apps: apps, excludingPID: getpid(), bands: bands)
            DispatchQueue.main.async { result = r }
        }
        _ = waitUntil(10) { result != nil }
        return result
    }

    module.start()
    guard waitUntil(4, { controller.visibility == .collapsed }) else {
        print("  (items not laid out / not collapsed — skipped)")
        return
    }
    controller.expand()
    _ = waitUntil(0.8) { false }
    let d = controller.diagnostics()
    guard let sep = d.separatorFrame, let toggle = d.toggleFrame else { return }
    print("  expanded: separator x=\(Int(sep.minX)) toggle x=\(Int(toggle.minX))")
    guard let before = scan() else { return }
    let leftOfSeparator = before.items.filter {
        $0.frame.midX < sep.minX && $0.frame.minY < 40 && $0.frame.minX > 0 && $0.isMovable
    }
    print("  icons left of the separator: \(leftOfSeparator.map(\.name))")
    guard !leftOfSeparator.isEmpty else {
        print("  (no icons left of the separator — nothing to verify)")
        return
    }
    controller.collapse()
    _ = waitUntil(2.0) { false } // collapse + overflow padding (0.35 s) + layout
    let dc = controller.diagnostics()
    print("  collapsed: separator \(dc.separatorFrame.map { "\(Int($0.minX))+\(Int($0.width))" } ?? "nil"), toggle \(dc.toggleFrame.map { "\(Int($0.minX))+\(Int($0.width))" } ?? "nil")")
    let shot = FileManager.default.temporaryDirectory.appendingPathComponent("menubar-e2e.png").path
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R0,0,\(Int(NSScreen.main?.frame.width ?? 1920)),40", shot]
    try? p.run()
    p.waitUntilExit()
    print("  screenshot: \(shot)")
    // Overflowed items keep stale AX positions on macOS 27, so verify the mechanism instead: once the
    // separator overflows (its reported frame starts left of the app menus, impossible for a laid-out
    // item) everything left of it is in the "«" overflow.
    var menusMaxX: CGFloat?
    if let owner = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier {
        let width = NSScreen.main?.frame.width ?? 1920
        var done = false
        DispatchQueue.global().async {
            let v = MenuBarItemScanner.appMenusMaxX(pid: owner, screenMinX: 0, screenMaxX: width)
            DispatchQueue.main.async { menusMaxX = v; done = true }
        }
        _ = waitUntil(3) { done }
    }
    if controller.strategy == .systemOverflow, let menusMaxX, let sepFrame = dc.separatorFrame {
        check(sepFrame.minX < menusMaxX,
              "separator overflowed (reported x \(Int(sepFrame.minX)) < app menus end \(Int(menusMaxX))) → icons left of it are in «")
    } else if let sepFrame = dc.separatorFrame {
        check(sepFrame.minX < 0, "classic: separator pushes icons off-screen (x \(Int(sepFrame.minX)))")
    }
    if let after = scan() {
        print("  « button: \(after.overflowChevron.map { "x=\(Int($0.minX))" } ?? "none")")
    }
    check(dc.toggleFrame != nil, "toggle itself stays visible")
}

@MainActor
func runChecks() {
    print("Session: " + (sessionLocked ? "LOCKED (live UI checks informational, live restriction probe skipped)" : "unlocked"))
    checkSettings()
    checkGeometry()
    checkSafety()
    checkCollapseLength()
    checkClassification()
    checkStateMachine()
    checkDriver()
    checkDragPlanner()
    checkScannerHelpers()
    checkNativeResolver()
    checkNativePlan()
    checkNativeCrowdedToggle()
    checkNativeEngine()
    checkRevealGeometry()
    checkRevealPlanner()
    checkRevealEngine()
    checkRevealEdgeCases()
    checkRevealEngineEdgeCases()
    checkClockAssistPieces()
    checkClockAssistStateMachine()
    checkClockAssistLocatorEdgeCases()
    checkClockAssistRaces()
    probeListing()
    probeRevealRoom()
    probeClockAssistLive()
    checkIntegration()
    checkNativeController()
    checkRevealController()
    checkRevealControllerRecheck()
    checkClockAssistController()
    checkClockAssistControllerRaces()
    checkLegacyOnOlderMacOS()
    checkEndToEndHiding()
    checkNativeLiveProbe()
}

MainActor.assumeIsolated { runChecks() }
AppLog.flush()
if failures == 0 && AppEnvironment.profile == checkProfile {
    try? FileManager.default.removeItem(at: AppLog.logFileURL) // keep it only to diagnose failures
} else if AppEnvironment.profile == checkProfile {
    print("log: \(AppLog.logFileURL.path)")
}
print(failures == 0 ? "MenuBarHiderCheck: ALL PASSED" : "MenuBarHiderCheck: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
