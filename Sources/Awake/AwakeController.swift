import AppKit
import Combine
import OneSwitchCore

/// Orchestrates the Awake module: settings, persisted runtime state, holiday data, timers, OS power
/// assertions and system notifications. Main-actor only.
///
/// Timing: a one-shot timer at the next deadline (session end or schedule transition) plus a 30 s
/// safety re-evaluation; re-evaluates after wake, clock / day / time-zone changes and settings changes.
@MainActor
public final class AwakeController: ObservableObject {
    public static let stateKey = "awake.state"
    public static let settingsKey = "awake.settings"
    public static let safetyInterval: TimeInterval = 30
    /// A timed session that ended longer ago than this (e.g. while the Mac slept or the app was not
    /// running) ends silently.
    public static let notifyGrace: TimeInterval = 10 * 60

    public let store: SettingsStore<AwakeSettings>
    public let holidays: HolidayStore

    @Published public private(set) var status: AwakeStatus
    /// User-facing hotkey registration problem (set by the module).
    @Published public var hotKeyMessage: String?

    /// Called when the main status-bar icon must be re-evaluated: the active state flipped or the
    /// 菜单栏图标 choice changed (`settings` already holds the new choice). The module refreshes the icon.
    public var onStatusIconChange: (() -> Void)?

    public private(set) var settings: AwakeSettings
    public private(set) var isRunning = false

    private var engine: AwakeEngine
    private let power: AwakePowerControlling
    private let stateDefaults: UserDefaults
    private let clock: () -> Date
    private let calendarProvider: () -> Calendar
    private let notifier: (String, String) -> Void

    private var deadlineTimer: Timer?
    /// A persisted manual session was discarded because it predates the current boot (persisted in start()).
    private var droppedSessionAtLaunch = false
    private var safetyTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancellables: Set<AnyCancellable> = []

    /// - Parameters:
    ///   - defaults: where settings ("awake.settings") and runtime state ("awake.state") live.
    ///   - dataDirectory: holiday cache directory.
    ///   - power: OS power backend (default: real IOKit assertions).
    ///   - clock / calendar: injectable for tests.
    ///   - notifier: user notification sink (default: `AppContext.shared.notify`).
    ///   - bootTime: when the system booted (default: `kern.boottime`); a persisted manual session that
    ///     started before it is not restored.
    public init(defaults: UserDefaults = AppEnvironment.defaults,
                dataDirectory: URL = AppEnvironment.dataDirectory,
                power: AwakePowerControlling? = nil,
                holidayURLTemplates: [String] = HolidayStore.defaultURLTemplates,
                clock: @escaping () -> Date = Date.init,
                calendar: @escaping () -> Calendar = Calendar.awakeSystem,
                notifier: ((String, String) -> Void)? = nil,
                bootTime: () -> Date? = AwakeController.systemBootTime) {
        let store = SettingsStore(key: Self.settingsKey, defaultValue: AwakeSettings(), defaults: defaults)
        self.store = store
        self.settings = store.value.sanitized
        self.holidays = HolidayStore(directory: dataDirectory, defaults: defaults,
                                     urlTemplates: holidayURLTemplates, clock: clock)
        self.power = power ?? PowerAssertionManager()
        self.stateDefaults = defaults
        self.clock = clock
        self.calendarProvider = calendar
        self.notifier = notifier ?? { title, body in
            AppContext.shared.notify(title: title, body: body, identifier: "awake.sessionEnded")
        }
        var restored = AwakeRuntimeState()
        if let data = defaults.data(forKey: Self.stateKey),
           let decoded = try? JSONDecoder().decode(AwakeRuntimeState.self, from: data) {
            restored = decoded
        }
        // A restart ends manual sessions: restoring e.g. a 无限期 session after the Mac was shut down
        // would keep it (a MacBook on battery, too) awake indefinitely without anyone asking for it.
        // A relaunch of the app alone (crash, update) keeps the session. The schedule is unaffected.
        if let session = restored.session, let boot = bootTime(), session.startedAt < boot {
            restored.session = nil
            droppedSessionAtLaunch = true
        }
        self.engine = AwakeEngine(state: restored)
        // Pure snapshot; no side effects before start().
        let policy = AwakePolicy(settings: store.value.sanitized, holidays: HolidayData(), calendar: calendar())
        self.status = engine.peek(policy: policy, now: clock())
    }

    /// Boot time of the system (`kern.boottime`), nil when unavailable.
    public nonisolated static func systemBootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    // MARK: Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        // Settings are only mirrored while running (the store sink below): pick up changes made
        // before start() or while stopped (e.g. a 菜单栏图标 choice), or they would stay ignored.
        settings = store.value.sanitized
        pruneOldOverrides()
        if droppedSessionAtLaunch {
            droppedSessionAtLaunch = false
            persistState()
            AppLog.info("awake", "manual session from before the last restart discarded")
        }

        store.$value
            .dropFirst()
            .sink { [weak self] newValue in self?.settingsDidChange(newValue) }
            .store(in: &cancellables)
        holidays.onDataChange = { [weak self] in self?.evaluate(reason: "holiday data") }

        installObservers()
        let safety = Timer(timeInterval: Self.safetyInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.safetyTick() }
        }
        safety.tolerance = 3
        RunLoop.main.add(safety, forMode: .common)
        safetyTimer = safety

        let years = holidayYears()
        // Evaluate once the (tiny) cache has been read so a holiday is not treated as a workday for a
        // moment at launch; the cache read happens off the main thread.
        holidays.loadCache(years: [years[0] - 1] + years) { [weak self] in
            guard let self, self.isRunning else { return }
            self.evaluate(reason: "start")
            self.refreshHolidayDataIfDue()
        }
        AppLog.info("awake", "started (schedule \(settings.scheduleEnabled ? "on" : "off"), \(AwakeText.window(settings.startMinute, settings.endMinute)), holidays \(effectiveHolidayRegion.rawValue))")
    }

    /// Synchronously releases the power assertion and all timers / observers.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        safetyTimer?.invalidate()
        safetyTimer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        cancellables.removeAll()
        holidays.onDataChange = nil
        holidays.cancel()
        power.releaseAll()
        persistState()
        AppLog.info("awake", "stopped")
    }

    // MARK: User actions

    /// Starts a manual session of `minutes` (5…720), or 无限期 when nil.
    public func startSession(minutes: Int?) {
        engine.startSession(minutes: minutes, now: clock())
        AppLog.info("awake", "manual session started: \(AwakeText.durationLabel(minutes.map(AwakeLimits.clampSession)))")
        persistState()
        evaluate(reason: "manual start")
    }

    /// Manual 关闭 (ends a session; suppresses the schedule until its next transition).
    public func turnOff() {
        engine.turnOff(policy: makePolicy(), now: clock())
        AppLog.info("awake", "turned off manually\(engine.state.suppressed ? " (schedule suppressed)" : "")")
        persistState()
        evaluate(reason: "manual off")
    }

    /// Menu / hotkey toggle: off → 无限期 session, on → 关闭.
    public func toggle() {
        let current = evaluate(reason: "toggle")
        if current.isActive { turnOff() } else { startSession(minutes: nil) }
    }

    public func setScheduleEnabled(_ enabled: Bool) {
        store.update { $0.scheduleEnabled = enabled }
    }

    /// 立即更新 holiday data.
    public func refreshHolidays() {
        holidays.refresh(years: holidayYears())
    }

    // MARK: Queries for UI

    public var now: Date { clock() }
    public var calendar: Calendar { calendarProvider() }

    public func makePolicy() -> AwakePolicy {
        AwakePolicy(settings: settings, holidays: holidays.data, calendar: calendarProvider())
    }

    /// The holiday calendar in effect ("节假日日历" resolved with the current time zone; never `.automatic`).
    public var effectiveHolidayRegion: HolidayRegion {
        settings.holidayRegion.resolved(for: calendarProvider().timeZone)
    }

    /// Current and next year (the years whose holiday data is fetched).
    public func holidayYears() -> [Int] {
        let year = calendarProvider().component(.year, from: clock())
        return [year, year + 1]
    }

    // MARK: Evaluation

    /// Re-evaluates the state machine and applies the result (assertion, timers, icon, notification).
    @discardableResult
    public func evaluate(reason: String) -> AwakeStatus {
        let now = clock()
        let policy = makePolicy()
        guard isRunning else {
            let snapshot = engine.peek(policy: policy, now: now)
            if snapshot != status { status = snapshot }
            return snapshot
        }
        let wasActive = status.isActive
        let result = engine.evaluate(policy: policy, now: now)
        if result.status != status { status = result.status }
        if result.stateChanged { persistState() }
        if result.suppressionCleared { AppLog.info("awake", "schedule suppression cleared") }

        power.apply(active: status.isActive, simulateActivity: settings.simulateUserActivity)
        scheduleDeadline(status.nextDeadline, now: now)

        if let expired = result.expiredSession {
            sessionEnded(expired, now: now, policy: policy)
        }
        if wasActive != status.isActive {
            AppLog.info("awake", "\(status.isActive ? "activated" : "deactivated") (\(reason); mode \(status.mode))")
            onStatusIconChange?()
        }
        return status
    }

    private func sessionEnded(_ session: ManualSession, now: Date, policy: AwakePolicy) {
        AppLog.info("awake", "timed session ended (\(session.minutes.map(Fmt.minutes) ?? "?"))")
        guard settings.notifyOnEnd, let end = session.endsAt, now.timeIntervalSince(end) < Self.notifyGrace else { return }
        let length = session.minutes.map { "（\(Fmt.minutes($0))）" } ?? ""
        if status.mode == .schedule {
            let until = status.nextTransition.map { "至 \(AwakeText.moment($0, now: now, calendar: policy.calendar, omitToday: true))" } ?? ""
            notifier("定时已结束", "已到设定时长\(length)，将按自动计划继续保持开启\(until)。")
        } else {
            notifier("防止锁屏已结束", "已到设定时长\(length)，Mac 将恢复正常的自动锁屏与睡眠。")
        }
    }

    private func scheduleDeadline(_ deadline: Date?, now: Date) {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard let deadline else { return }
        // Fire just after the boundary; never spin faster than 2 Hz.
        let interval = max(0.5, deadline.timeIntervalSince(now) + 0.05)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.evaluate(reason: "deadline") }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    private func safetyTick() {
        evaluate(reason: "safety")
        refreshHolidayDataIfDue()
    }

    /// holiday-cn data is downloaded only while 中国大陆 is the effective holiday calendar (Polish holidays
    /// are computed offline; nothing is fetched for 不使用节假日).
    private func refreshHolidayDataIfDue() {
        guard effectiveHolidayRegion == .chinaMainland else { return }
        holidays.refreshIfDue(years: holidayYears())
    }

    private func settingsDidChange(_ newValue: AwakeSettings) {
        let previousIcon = settings.statusIcon
        settings = newValue.sanitized
        refreshHolidayDataIfDue()
        evaluate(reason: "settings")
        if settings.statusIcon != previousIcon {
            AppLog.info("awake", "status icon choice: \(settings.statusIcon.rawValue)")
            onStatusIconChange?()
        }
    }

    private func persistState() {
        do {
            stateDefaults.set(try JSONEncoder().encode(engine.state), forKey: Self.stateKey)
        } catch {
            AppLog.error("awake", "failed to persist state: \(error)")
        }
    }

    /// Drops date overrides that lie more than 30 days in the past.
    private func pruneOldOverrides() {
        let cal = calendarProvider()
        guard let cutoffDate = cal.date(byAdding: .day, value: -30, to: clock()) else { return }
        let cutoff = DayKey(cutoffDate, calendar: cal)
        let stale = store.value.dayOverrides.keys.filter { DayKey($0).map { $0 < cutoff } ?? true }
        guard !stale.isEmpty else { return }
        store.update { s in stale.forEach { s.dayOverrides[$0] = nil } }
        settings = store.value.sanitized
        AppLog.info("awake", "pruned \(stale.count) past date override(s)")
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [.NSSystemClockDidChange, .NSCalendarDayChanged, .NSSystemTimeZoneDidChange]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if note.name == .NSSystemTimeZoneDidChange { NSTimeZone.resetSystemTimeZone() }
                    // A long-running menu-bar app must also drop stale overrides, not only at launch.
                    if note.name == .NSCalendarDayChanged { self.pruneOldOverrides() }
                    self.evaluate(reason: note.name.rawValue)
                    // A new year or a new time zone (→ 自动 may now mean 中国大陆) can make a download due.
                    self.refreshHolidayDataIfDue()
                }
            }
            observers.append((center, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.evaluate(reason: "wake")
                self.refreshHolidayDataIfDue()
            }
        }
        observers.append((workspace, wake))
    }
}
