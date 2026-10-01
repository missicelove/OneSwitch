import AppKit
import OneSwitchCore
import MenuBarHider

// 点击时钟打开通知中心 (系统原生隐藏 disables Notification Center while a restriction is held). Everything
// runs against fakes: no click is ever posted, no event monitor is installed, the real restriction is never
// touched. One read-only probe prints where the real clock is and whether Notification Center is open.

// MARK: - Fakes

/// Monitor, clock lookup, Notification Center, poster, pointer and timers of the assist.
@MainActor
final class FakeClockEnv {
    let time = FakeTime()
    private(set) var handler: (@MainActor (ClockAssistMouseEvent) -> Void)?
    private(set) var installs = 0
    private(set) var removals = 0
    /// Clock frames (CG) the lookup reports when a click lands on one.
    var clocks: [CGRect]
    /// Lookups wait for `deliverProbes()`.
    var manualProbe = false
    private(set) var probeRequests: [CGPoint] = []
    private var pendingProbes: [(point: CGPoint, completion: @MainActor (ClockClickProbe?) -> Void)] = []
    var ncOpen = false
    private(set) var ncQueries = 0
    /// Notification Center readings wait for `deliverNC()` (a slow window-list read).
    var manualNC = false
    private var pendingNC: [@MainActor (Bool) -> Void] = []
    var pendingNCCount: Int { pendingNC.count }
    private(set) var posted: [CGPoint] = []
    var pointer: CGPoint
    var interacting = false
    private(set) var interactionQueries = 0
    private(set) var drains = 0
    var bands: [CGRect]

    init(clock: CGRect, bands: [CGRect]) {
        clocks = [clock]
        pointer = CGPoint(x: clock.midX - 20, y: clock.midY)
        self.bands = bands
    }

    var deps: NotificationCenterAssistDependencies {
        NotificationCenterAssistDependencies(
            monitorClicks: { [unowned self] handler in
                self.installs += 1
                self.handler = handler
                return { [unowned self] in
                    self.removals += 1
                    self.handler = nil
                }
            },
            probeClick: { [unowned self] point, completion in
                self.probeRequests.append(point)
                if self.manualProbe { self.pendingProbes.append((point, completion)) } else { completion(self.answer(point)) }
            },
            notificationCenterOpen: { [unowned self] completion in
                self.ncQueries += 1
                if self.manualNC { self.pendingNC.append(completion) } else { completion(self.ncOpen) }
            },
            postClick: { [unowned self] point in self.posted.append(point) },
            pointerLocation: { [unowned self] in self.pointer },
            menuBarBands: { [unowned self] in self.bands },
            isInteracting: { [unowned self] completion in
                self.interactionQueries += 1
                completion(self.interacting)
            },
            schedule: time.scheduler,
            now: { [unowned self] in self.time.now },
            drain: { [unowned self] in self.drains += 1 })
    }

    func answer(_ point: CGPoint) -> ClockClickProbe {
        ClockClickProbe(clock: clocks.first { $0.contains(point) }, notificationCenterOpen: ncOpen)
    }

    func deliverProbes() {
        let pending = pendingProbes
        pendingProbes.removeAll()
        for (point, completion) in pending { completion(answer(point)) }
    }

    func deliverNC() {
        let pending = pendingNC
        pendingNC.removeAll()
        for completion in pending { completion(ncOpen) }
    }

    /// Through the installed monitor (nothing happens when none is installed).
    func press(_ point: CGPoint, synthetic: Bool = false, modified: Bool = false) {
        handler?(ClockAssistMouseEvent(kind: .down, location: point, synthetic: synthetic, modified: modified))
    }

    func lift(_ point: CGPoint, synthetic: Bool = false) {
        handler?(ClockAssistMouseEvent(kind: .up, location: point, synthetic: synthetic))
    }

    func click(_ point: CGPoint, synthetic: Bool = false) {
        press(point, synthetic: synthetic)
        lift(point, synthetic: synthetic)
    }
}

/// The Mac Studio's clock (CG, measured through Accessibility on macOS 27.0.1).
let studioClock = CGRect(x: 1775, y: 0, width: 125, height: 30)
let studioClockPoint = CGPoint(x: 1830, y: 15)

func agentItem(_ identifier: String?, x: CGFloat, w: CGFloat = 24, y: CGFloat = 0, h: CGFloat = 30, name: String = "系统图标",
               detail: String? = nil, bundle: String = "com.apple.MenuBarAgent") -> MenuBarItemInfo {
    MenuBarItemInfo(id: "\(bundle)|\(identifier ?? "\(x)")", pid: 8, name: name, detail: detail, bundleID: bundle,
                    identifier: identifier, frame: CGRect(x: x, y: y, width: w, height: h), source: .accessibility,
                    isSystemItem: true, isMovable: identifier != ClockLocator.clockIdentifier)
}

// MARK: - Pure pieces

@MainActor
func checkClockAssistPieces() {
    print("点击时钟打开通知中心: setting, finding the clock, detecting Notification Center")
    let d = MenuBarHiderSettings()
    check(d.clockOpensNotificationCenter, "default: on")
    var s = MenuBarHiderSettings()
    s.clockOpensNotificationCenter = false
    let data = try? JSONEncoder().encode(s)
    check(data.flatMap { try? JSONDecoder().decode(MenuBarHiderSettings.self, from: $0) } == s, "off round-trips")
    check(data.flatMap { String(data: $0, encoding: .utf8) }?.contains("\"clockOpensNotificationCenter\":false") == true, "stored as a named field")
    let older = try? JSONDecoder().decode(MenuBarHiderSettings.self, from: Data(#"{"enabled":true,"autoCollapseDelay":25}"#.utf8))
    check(older?.clockOpensNotificationCenter == true && older?.autoCollapseDelay == 25, "settings from before the field: on, other fields kept")
    let wrong = try? JSONDecoder().decode(MenuBarHiderSettings.self, from: Data(#"{"clockOpensNotificationCenter":"no"}"#.utf8))
    check(wrong?.clockOpensNotificationCenter == true, "malformed value → default")

    // Where the clock is.
    let wifi = agentItem("com.apple.menuextra.wifi", x: 1663, w: 22, name: "Wi‑Fi")
    let cc = agentItem("com.apple.menuextra.controlcenter", x: 1733, w: 26, name: "控制中心")
    let clock = agentItem(ClockLocator.clockIdentifier, x: 1775, w: 125, name: "时钟")
    let bands = [studioBand]
    check(ClockLocator.clockFrames(items: [wifi, cc, clock], bands: bands, rightToLeft: false) == [studioClock], "clock found by its identifier")
    check(ClockLocator.clock(at: studioClockPoint, items: [wifi, cc, clock], bands: bands, rightToLeft: false) == studioClock, "click on the date / time")
    check(ClockLocator.clock(at: CGPoint(x: 1745, y: 15), items: [wifi, cc, clock], bands: bands, rightToLeft: false) == nil,
          "click on 控制中心 is not the clock")
    let unnamed = agentItem(nil, x: 1775, w: 125, name: "时钟", detail: "9月30日 周二 10:05")
    check(ClockLocator.clockFrames(items: [wifi, unnamed], bands: bands, rightToLeft: false) == [studioClock], "no identifier: found by its label (时钟)")
    let anonymous = agentItem(nil, x: 1775, w: 125, name: "系统图标")
    check(ClockLocator.clockFrames(items: [wifi, cc, anonymous], bands: bands, rightToLeft: false) == [studioClock],
          "not recognisable: the right-most system item")
    check(ClockLocator.clockFrames(items: [agentItem(nil, x: 20, w: 125), agentItem(nil, x: 160, w: 22)], bands: bands, rightToLeft: true)
          == [CGRect(x: 20, y: 0, width: 125, height: 30)], "right-to-left: the left-most system item")
    let thirdParty = MenuBarItemInfo(id: "x", pid: 50, name: "World Clock", bundleID: "com.example.worldclock",
                                     frame: CGRect(x: 1500, y: 0, width: 40, height: 30), source: .accessibility,
                                     isSystemItem: false, isMovable: true)
    check(!ClockLocator.isClock(thirdParty) && ClockLocator.clock(at: CGPoint(x: 1510, y: 15), items: [thirdParty, clock], bands: bands,
                                                                   rightToLeft: false) == nil,
          "another app's \"Clock\" item is never the clock")
    let second = CGRect(x: 1920, y: -200, width: 2560, height: 25)
    let clock2 = agentItem(ClockLocator.clockIdentifier, x: 4380, w: 100, y: -200, h: 25)
    check(ClockLocator.clockFrames(items: [clock, clock2], bands: [studioBand, second], rightToLeft: false).count == 2, "a clock on each display")
    check(ClockLocator.clockFrames(items: [clock], bands: [studioBand, second], rightToLeft: false) == [studioClock],
          "a display without system items adds nothing")
    let offscreen = agentItem(ClockLocator.clockIdentifier, x: -1, w: 125, y: 1068)
    check(ClockLocator.clockFrames(items: [offscreen], bands: bands, rightToLeft: false).isEmpty, "an item that is not in a menu bar is not the clock")
    check(ClockLocator.isInMenuBar(studioClockPoint, bands: bands) && ClockLocator.isInMenuBar(CGPoint(x: 1919, y: 0), bands: bands)
          && !ClockLocator.isInMenuBar(CGPoint(x: 1830, y: 40), bands: bands) && !ClockLocator.isInMenuBar(CGPoint(x: 1920, y: 15), bands: bands),
          "menu-bar strip test")

    // Notification Center: macOS 27 shows one window of the display's size at level 21 while it is open.
    let nc: Set<pid_t> = [1251]
    let panel = WindowSummary(pid: 1251, layer: 21, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    check(NotificationCenterDetector.isOpen(windows: [panel], processIDs: nc), "full-size Notification Center window on screen → open")
    check(!NotificationCenterDetector.isOpen(windows: [], processIDs: nc), "not on screen → closed")
    check(!NotificationCenterDetector.isOpen(windows: [WindowSummary(pid: 1251, layer: 21, bounds: CGRect(x: 1550, y: 40, width: 360, height: 80))],
                                             processIDs: nc), "a banner-sized window is not the panel")
    check(!NotificationCenterDetector.isOpen(windows: [WindowSummary(pid: 1251, layer: -2147483603, bounds: CGRect(x: 40, y: 80, width: 344, height: 344))],
                                             processIDs: nc), "a desktop widget is not the panel")
    check(!NotificationCenterDetector.isOpen(windows: [WindowSummary(pid: 999, layer: 21, bounds: panel.bounds)], processIDs: nc),
          "another process's window is not Notification Center")
    check(!NotificationCenterDetector.isOpen(windows: [WindowSummary(pid: 1251, layer: 21, bounds: panel.bounds, alpha: 0)], processIDs: nc),
          "a transparent window is not shown")
    check(!NotificationCenterDetector.isOpen(windows: [panel], processIDs: []), "Notification Center not running → closed")
    let list: [[String: Any]] = [
        [kCGWindowOwnerPID as String: pid_t(1251), kCGWindowLayer as String: 21, kCGWindowAlpha as String: 1.0,
         kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 1512, height: 982).dictionaryRepresentation],
        [kCGWindowOwnerPID as String: pid_t(77), kCGWindowLayer as String: 0,
         kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 800, height: 600).dictionaryRepresentation],
    ]
    let parsed = NotificationCenterDetector.windows(from: list, processIDs: nc)
    check(parsed == [WindowSummary(pid: 1251, layer: 21, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))]
          && NotificationCenterDetector.isOpen(windows: parsed, processIDs: nc), "window list parsed (MacBook Pro: 1512 × 982)")

    check(MenuBarHiderController.stateText(enabled: true, active: true, visibility: .expandedAll, secondsUntilCollapse: nil,
                                           forNotificationCenter: true) == "通知中心打开期间临时显示全部图标", "state text while Notification Center is open")
    check(ClockClickPoster.userDataTag == 0x4F4E_4E43, "our clicks carry their own tag ('ONNC')")
}

// MARK: - State machine

@MainActor
func checkClockAssistStateMachine() {
    print("点击时钟打开通知中心: state machine (fake clock, monitor, Notification Center; nothing posted)")

    final class Hooks {
        var canEngage = true
        var previous: ClockAssistPrevious? = .collapsed
        var engaged: [ClockAssistPrevious] = []
        var restored: [ClockAssistPrevious] = []
    }

    func make(_ env: FakeClockEnv, _ hooks: Hooks) -> NotificationCenterClockAssist {
        let assist = NotificationCenterClockAssist(dependencies: env.deps)
        assist.canEngage = { hooks.canEngage }
        assist.engage = {
            guard let previous = hooks.previous else { return nil }
            hooks.engaged.append(previous)
            return previous
        }
        assist.restore = { hooks.restored.append($0) }
        assist.isInteracting = { completion in completion(env.interacting) }
        _ = env.deps.monitorClicks { event in assist.handle(event) } // the fake monitor feeds the assist
        return assist
    }

    // The whole episode.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = Hooks()
        let assist = make(env, hooks)
        var phases: [NotificationCenterClockAssist.Phase] = []
        assist.onPhaseChange = { phases.append($0) }
        env.press(studioClockPoint)
        check(hooks.engaged == [.collapsed] && assist.phase == .released && assist.clockFrame == studioClock,
              "clock pressed → restriction released at once (previous: collapsed)")
        env.time.advance(by: 0.5)
        check(env.posted.isEmpty && env.ncQueries == 0, "nothing decided while the button is down")
        env.lift(studioClockPoint)
        env.time.advance(by: 0.11)
        check(env.posted.isEmpty, "button up: Notification Center gets ~120 ms to react by itself")
        env.time.advance(by: 0.02)
        check(env.posted == [env.pointer] && assist.phase == .watching && assist.syntheticClicks == 1,
              "it did not → one click posted where the pointer is (on the clock)")
        env.ncOpen = true
        env.time.advance(by: 0.3)
        check(assist.phase == .watching && hooks.restored.isEmpty, "Notification Center open → bar stays unrestricted")
        env.time.advance(by: 30)
        check(assist.phase == .watching && hooks.restored.isEmpty && env.posted.count == 1, "…as long as it is open (polled, nothing else posted)")
        env.ncOpen = false
        env.time.advance(by: 0.3)
        check(hooks.restored == [.collapsed] && assist.phase == .idle && !assist.isEngaged, "closed → the collapsed restriction is restored")
        check(env.time.pendingCount == 0, "…and polling stops")
        check(phases == [.locating, .released, .watching, .idle], "phases: \(phases.map(\.rawValue).joined(separator: " → "))")
        let polls = env.ncQueries
        env.time.advance(by: 5)
        check(env.ncQueries == polls, "no polling while idle")
    }

    // Opened by the click itself (the release was quick enough).
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = Hooks()
        let assist = make(env, hooks)
        env.click(studioClockPoint)
        env.ncOpen = true
        env.time.advance(by: 0.13)
        check(env.posted.isEmpty && assist.phase == .watching, "Notification Center opened by itself → no click posted (it would close it again)")
        env.ncOpen = false
        env.time.advance(by: 0.3)
        check(hooks.restored == [.collapsed], "…restored once it closed")
    }

    // Already open when the clock was clicked (the click is meant to close it).
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = Hooks()
        hooks.previous = .revealed
        let assist = make(env, hooks)
        env.ncOpen = true
        env.click(studioClockPoint)
        check(hooks.engaged == [.revealed], "Notification Center already open: released too (previous: partial reveal)")
        env.time.advance(by: 0.13)
        check(env.posted.count == 1, "the click did nothing → one click posted to close it")
        env.ncOpen = false
        env.time.advance(by: 0.3)
        check(hooks.restored == [.revealed] && assist.phase == .idle, "closed → the partial reveal is restored")
    }
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = Hooks()
        _ = make(env, hooks)
        env.ncOpen = true
        env.click(studioClockPoint)
        env.ncOpen = false // closed by the click itself
        env.time.advance(by: 0.13)
        check(env.posted.isEmpty, "already open and closed by the click itself → nothing posted")
        env.time.advance(by: 0.3)
        check(hooks.restored == [.collapsed], "…restored")
    }

    // The posted click did not open it: the bar comes back after the grace period, not before.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = Hooks()
        let assist = make(env, hooks)
        env.click(studioClockPoint)
        env.time.advance(by: 0.13)
        check(env.posted.count == 1, "click posted")
        env.time.advance(by: 0.9)
        check(hooks.restored.isEmpty && assist.phase == .watching, "not seen open yet: waits (it may still be opening)")
        env.time.advance(by: 0.3)
        check(hooks.restored == [.collapsed] && env.posted.count == 1, "never opened → restored after ~1 s; only one click ever posted")
    }

    // Restoring waits while the user is busy in the menu bar (like the auto-hide).
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = Hooks()
        let assist = make(env, hooks)
        env.click(studioClockPoint)
        env.ncOpen = true
        env.time.advance(by: 0.5)
        env.ncOpen = false
        env.interacting = true // e.g. closed by clicking the clock again: the pointer is in the bar
        env.time.advance(by: 2)
        check(hooks.restored.isEmpty && assist.phase == .watching, "closed, but the pointer is in the bar / a menu is open → waits")
        env.interacting = false
        env.time.advance(by: 0.3)
        check(hooks.restored == [.collapsed], "…restored once the user left the menu bar")
    }

    // A user action ends the episode without restoring.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = Hooks()
        let assist = make(env, hooks)
        env.click(studioClockPoint)
        env.time.advance(by: 0.13)
        env.ncOpen = true
        env.time.advance(by: 0.3)
        assist.cancel(restore: false, reason: "check: toggle clicked")
        check(assist.phase == .idle && env.time.pendingCount == 0, "user action: episode over, no timer left")
        env.ncOpen = false
        env.time.advance(by: 2)
        check(hooks.restored.isEmpty, "…nothing restored afterwards")
        env.click(studioClockPoint)
        check(hooks.engaged.count == 2, "the next clock click engages again")
        assist.cancel(restore: true, reason: "check: feature switched off")
        check(hooks.restored == [.collapsed], "switched off during an episode → restored")
    }

    // Ignored clicks.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = Hooks()
        let assist = make(env, hooks)
        env.click(CGPoint(x: 800, y: 500))
        check(env.probeRequests.isEmpty, "click outside the menu bar: not even looked up")
        env.click(CGPoint(x: 1745, y: 15))
        check(env.probeRequests.count == 1 && hooks.engaged.isEmpty && assist.phase == .idle, "click on another item: looked up, ignored")
        env.click(studioClockPoint, synthetic: true)
        check(env.probeRequests.count == 1 && hooks.engaged.isEmpty, "our own (tagged) click is ignored")
        hooks.canEngage = false
        env.click(studioClockPoint)
        check(env.probeRequests.count == 1 && hooks.engaged.isEmpty, "feature off / nothing hidden: clock clicks left alone")
        hooks.canEngage = true
        hooks.previous = nil
        env.click(studioClockPoint)
        check(hooks.engaged.isEmpty && assist.phase == .idle, "the controller refuses to release → idle")
        hooks.previous = .collapsed

        // A second click while the bar is unrestricted for Notification Center reaches it as usual.
        env.click(studioClockPoint)
        let lookups = env.probeRequests.count
        env.click(studioClockPoint)
        env.time.advance(by: 0.13)
        check(env.probeRequests.count == lookups && hooks.engaged.count == 1 && env.posted.count == 1, "clicks during an episode start nothing new")
        env.time.advance(by: 1.2)
        check(hooks.restored.count == 1, "episode ends normally")
    }

    // The lookup answers late; the button came up before it answered; the pointer left the clock.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = Hooks()
        env.manualProbe = true
        let assist = make(env, hooks)
        env.press(studioClockPoint)
        env.time.advance(by: 1.2)
        env.deliverProbes()
        check(hooks.engaged.isEmpty && assist.phase == .idle, "clock found after > 1 s: stale, ignored")
        env.press(studioClockPoint)
        env.lift(studioClockPoint)
        env.pointer = CGPoint(x: 900, y: 400)
        env.deliverProbes()
        check(assist.phase == .released, "button up before the answer: released on the answer")
        env.time.advance(by: 0.13)
        check(env.posted == [CGPoint(x: studioClock.midX, y: studioClock.midY)], "pointer left the clock → click on the clock's centre")
        assist.cancel(restore: false, reason: "check")
        env.press(studioClockPoint)
        assist.cancel(restore: false, reason: "check: stopped while looking")
        env.deliverProbes()
        check(hooks.engaged.count == 1 && assist.phase == .idle, "cancelled while looking the clock up: the answer is ignored")
        hooks.canEngage = true
        env.press(studioClockPoint)
        hooks.canEngage = false // e.g. expanded meanwhile
        env.deliverProbes()
        check(hooks.engaged.count == 1 && assist.phase == .idle, "nothing hidden any more when the answer arrives → not released")
    }

    // Long press: nothing is posted for it.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = Hooks()
        let assist = make(env, hooks)
        env.press(studioClockPoint)
        env.time.advance(by: 1.6)
        check(assist.phase == .watching && env.posted.isEmpty, "button held > 1.5 s: no click posted")
        env.lift(studioClockPoint)
        env.time.advance(by: 0.8)
        check(hooks.restored.isEmpty, "…the bar waits the grace period")
        env.time.advance(by: 0.4)
        check(hooks.restored == [.collapsed] && env.posted.isEmpty, "…then it is restored")
    }
}

// MARK: - Controller (fake restriction, fake assist; real toggle item, removed again)

@MainActor
func checkClockAssistController() {
    print("点击时钟打开通知中心: controller (fake restriction + fake monitor; real toggle item, removed again)")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let suiteName = "oneswitch.menubarhidercheck.clock"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    let suffix = "-selfcheck-clock"
    defer {
        let std = UserDefaults.standard
        for key in std.dictionaryRepresentation().keys where key.hasPrefix("NSStatusItem") && (key.hasSuffix(suffix) || key.hasSuffix(suffix + "-mbp") || key.hasSuffix(suffix + "-legacy")) {
            std.removeObject(forKey: key)
        }
        suite.removePersistentDomain(forName: suiteName)
    }

    let vis = FakeVisibility(), inv = FakeInventory(sampleInventory()), timers = FakeTimers()
    let env = FakeClockEnv(clock: studioClock, bands: [studioBand])
    var deps = makeDeps(vis, inv, running: ["com.left", "com.left2", "com.right", "com.split"], timers: timers)
    deps.clockAssist = env.deps
    let module = MenuBarHiderModule(defaults: suite, autosaveSuffix: suffix, strategy: .systemOverflow, native: deps)
    let c = module.controller
    c.store.update { $0.collapseAtLaunch = false }
    module.start()
    check(c.engineKind == .native && c.clockAssistMonitoring && env.installs == 1, "系统原生隐藏 + feature on → click monitor installed")

    // Unrestricted (expanded, everything fits): Notification Center works, nothing to do.
    env.click(studioClockPoint)
    check(env.probeRequests.isEmpty && c.clockAssistPhase == .idle, "nothing hidden: clock clicks are left alone")

    c.collapse()
    check(vis.requests.count == 1, "collapse requested")
    vis.succeed(0)
    check(c.diagnostics().nativeRestricted && c.visibility == .collapsed, "collapsed, restriction held")

    env.click(CGPoint(x: 1500, y: 15))
    env.click(studioClockPoint, synthetic: true)
    check(env.probeRequests.count == 1 && c.visibility == .collapsed && vis.active.count == 1,
          "another item / our own click: the restriction stays")

    // The clock.
    env.press(studioClockPoint)
    check(c.visibility == .expandedAll && vis.active.isEmpty && !c.diagnostics().nativeRestricted,
          "clock clicked → every restriction released at once")
    check(c.secondsUntilCollapse == nil && c.notificationCenterAssistActive && c.clockAssistPhase == .released,
          "…without the auto-hide timer")
    check(c.stateText == "通知中心打开期间临时显示全部图标", "state: \(c.stateText)")
    env.lift(studioClockPoint)
    env.time.advance(by: 0.13)
    check(env.posted.count == 1 && c.clockAssistPhase == .watching, "one click posted for Notification Center")
    env.ncOpen = true
    env.time.advance(by: 0.6)
    check(c.visibility == .expandedAll && vis.requests.count == 1, "open: the bar stays unrestricted")
    var busy: Bool?
    c.isMenuBarInUse { busy = $0 }
    check(waitUntil(1) { busy != nil } && busy == true, "an open Notification Center also holds the auto-hide back")
    env.ncOpen = false
    env.interacting = true
    env.time.advance(by: 0.6)
    check(c.visibility == .expandedAll && vis.requests.count == 1, "closed while the user is busy in the menu bar: waits")
    env.interacting = false
    env.time.advance(by: 0.3)
    check(c.visibility == .collapsed && vis.requests.count == 2 && !c.notificationCenterAssistActive && c.clockAssistPhase == .idle,
          "closed → collapsed again (fresh collapse requested)")
    vis.succeed(1)
    check(vis.active.count == 1 && c.nativeState == .collapsed && env.time.pendingCount == 0, "restriction held again, no polling")

    // User actions in between win.
    env.click(studioClockPoint)
    env.time.advance(by: 0.13)
    env.ncOpen = true
    env.time.advance(by: 0.3)
    c.userToggle(revealAlwaysHidden: false) // hotkey / toggle click on「>」
    check(c.visibility == .collapsed && vis.requests.count == 3 && c.clockAssistPhase == .idle && !c.notificationCenterAssistActive,
          "hotkey while Notification Center is open → collapsed, episode over")
    vis.succeed(2)
    env.ncOpen = false
    env.time.advance(by: 2)
    check(vis.requests.count == 3 && vis.active.count == 1 && c.visibility == .collapsed, "…nothing restored later")

    env.click(studioClockPoint)
    env.time.advance(by: 0.13)
    c.expand() // menu / settings: 显示隐藏的图标
    check(c.visibility == .expanded && c.clockAssistPhase == .idle && vis.active.isEmpty, "expanded by the user meanwhile → stays expanded")
    env.time.advance(by: 2)
    check(c.visibility == .expanded && vis.requests.count == 3, "…not collapsed behind the user's back")
    c.collapse()
    vis.succeed(3)

    // Already open while collapsed: the click is meant to close it.
    env.ncOpen = true
    env.click(studioClockPoint)
    env.time.advance(by: 0.13)
    check(c.visibility == .expandedAll && env.posted.count == 4, "Notification Center already open: released, one click posted to close it")
    env.ncOpen = false
    env.time.advance(by: 0.3)
    check(c.visibility == .collapsed && vis.requests.count == 5, "closed → collapsed again")
    vis.succeed(4)

    // 显示全部: nothing is hidden, nothing to do.
    c.revealAllIcons()
    let lookups = env.probeRequests.count
    env.click(studioClockPoint)
    check(env.probeRequests.count == lookups && c.visibility == .expandedAll && c.clockAssistPhase == .idle, "显示全部: clock clicks left alone")
    c.collapse()
    vis.succeed(5)

    // Feature off / on.
    c.store.update { $0.clockOpensNotificationCenter = false }
    check(!c.clockAssistMonitoring && env.removals == 1 && env.handler == nil, "switched off → monitor removed")
    let queries = env.ncQueries
    var busyOff: Bool?
    c.isMenuBarInUse { busyOff = $0 }
    _ = waitUntil(1) { busyOff != nil }
    check(env.ncQueries == queries, "switched off: Notification Center no longer holds the auto-hide back")
    c.store.update { $0.clockOpensNotificationCenter = true }
    check(c.clockAssistMonitoring && env.installs == 2, "switched on → monitor back")
    env.click(studioClockPoint)
    check(c.visibility == .expandedAll, "episode started")
    c.store.update { $0.clockOpensNotificationCenter = false }
    check(c.visibility == .collapsed && vis.requests.count == 7 && c.clockAssistPhase == .idle, "switched off during an episode → collapsed again")
    vis.succeed(6)
    c.store.update { $0.clockOpensNotificationCenter = true }

    // 启用 off during an episode: everything shown, monitor gone; on again: back.
    env.click(studioClockPoint)
    c.store.update { $0.enabled = false }
    check(!c.clockAssistMonitoring && vis.active.isEmpty && c.clockAssistPhase == .idle && !c.diagnostics().isInstalled,
          "disabled during an episode: monitor removed, nothing held")
    c.store.update { $0.enabled = true }
    check(c.clockAssistMonitoring, "re-enabled: monitor back")
    c.collapse() // 启动时自动隐藏 is off in this check
    vis.succeed(vis.requests.count - 1)
    check(vis.active.count == 1 && c.visibility == .collapsed, "collapsed again")

    // Two failures in a row → 兼容模式: no monitor; retry → back.
    for _ in 0..<2 {
        let r = vis.requests.count
        c.expand()
        c.collapse()
        if vis.requests.count > r { vis.fail(vis.requests.count - 1) }
        _ = waitUntil(1) { c.visibility == .expanded || c.engineKind == .legacy }
    }
    check(c.engineKind == .legacy && !c.clockAssistMonitoring, "fallback to 兼容模式 → monitor removed")
    let beforeRetry = vis.requests.count
    c.retryNativeHiding()
    check(c.engineKind == .native && c.clockAssistMonitoring, "retry 系统原生隐藏 → monitor back")
    if vis.requests.count > beforeRetry { vis.succeed(vis.requests.count - 1) }
    check(vis.active.count == 1, "collapsed natively again")

    // stop() during an episode.
    env.click(studioClockPoint)
    env.time.advance(by: 0.13)
    let posted = env.posted.count
    let requests = vis.requests.count
    module.stop()
    check(env.drains == 1 && !c.clockAssistMonitoring && c.clockAssistPhase == .idle && vis.active.isEmpty && !c.diagnostics().isInstalled,
          "stop: monitor removed, a click being posted completed, nothing held")
    env.ncOpen = true
    env.time.advance(by: 1)
    env.ncOpen = false
    env.time.advance(by: 2)
    check(vis.requests.count == requests && env.posted.count == posted, "…nothing requested or posted afterwards")

    // Separator engine (macOS 14–26): never watches clicks.
    do {
        let vis2 = FakeVisibility(), inv2 = FakeInventory(sampleInventory()), env2 = FakeClockEnv(clock: studioClock, bands: [studioBand])
        var deps2 = makeDeps(vis2, inv2, running: ["com.left"])
        deps2.clockAssist = env2.deps
        let legacy = MenuBarHiderModule(defaults: suite, autosaveSuffix: suffix + "-legacy", strategy: .pushOffscreen, native: deps2)
        legacy.controller.store.update { $0.collapseAtLaunch = false }
        legacy.start()
        check(legacy.controller.engineKind == .legacy && !legacy.controller.clockAssistMonitoring && env2.installs == 0,
              "separator engine: no click monitor")
        legacy.stop()
        check(vis2.requests.isEmpty && env2.posted.isEmpty, "…nothing requested or posted")
        suite.removePersistentDomain(forName: suiteName)
    }

    // MacBook Pro: expanded is a partial reveal (a restriction is held) → restored as a partial reveal.
    do {
        let vis3 = FakeVisibility(), inv3 = FakeInventory(mbpInventory()), timers3 = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let mbpClock = CGRect(x: 1420, y: 0, width: 82, height: 37)
        let mbpClockPoint = CGPoint(x: 1460, y: 18)
        let env3 = FakeClockEnv(clock: mbpClock, bands: [mbpBand])
        var deps3 = makeRevealDeps(vis3, inv3, running: { mbpRunning }, toggle: mbpToggle, timers: timers3, probe: probe)
        deps3.clockAssist = env3.deps
        let mbp = MenuBarHiderModule(defaults: suite, autosaveSuffix: suffix + "-mbp", strategy: .systemOverflow, native: deps3)
        let m = mbp.controller
        mbp.start()
        defer { mbp.stop() }
        guard waitUntil(3, { vis3.requests.count == 1 }) else {
            check(false, "MacBook Pro: hide at launch requested")
            return
        }
        vis3.succeed(0)
        timers3.fireAll() // the collapsed bar is measured
        m.expand()
        vis3.succeed(1)
        check(m.nativeRevealPlan?.unfit == ["com.far"] && m.diagnostics().nativeRestricted, "MacBook Pro expanded: partial reveal, restriction held")
        env3.click(mbpClockPoint)
        check(m.visibility == .expandedAll && vis3.active.isEmpty && m.nativeRevealPlan == nil && m.secondsUntilCollapse == nil,
              "clock clicked during the partial reveal → everything released")
        env3.time.advance(by: 0.13)
        check(env3.posted.count == 1, "click posted")
        env3.ncOpen = true
        env3.time.advance(by: 0.3)
        env3.ncOpen = false
        env3.time.advance(by: 0.3)
        check(m.visibility == .collapsed && vis3.requests.count == 3, "closed → collapse first (the base of a partial reveal)")
        vis3.succeed(2)
        check(waitUntil(1) { vis3.requests.count == 4 }, "…then the icons that fit are revealed again")
        vis3.succeed(3)
        check(m.visibility == .expanded && m.nativeRevealPlan?.unfit == ["com.far"] && vis3.active.count == 1,
              "partial reveal restored (com.far still held back), one restriction")
        check(m.secondsUntilCollapse.map { $0 >= 9 && $0 <= 10 } == true, "…with the auto-hide re-armed")

        // A user action between the two steps: no reveal afterwards.
        env3.click(mbpClockPoint)
        env3.time.advance(by: 0.13)
        env3.time.advance(by: 1.2) // never opened → restore
        check(m.visibility == .collapsed && vis3.requests.count == 5, "restore started (collapse requested)")
        m.expand() // the user expands before the collapse is granted
        vis3.succeed(4)
        let settled = vis3.requests.count
        _ = waitUntil(0.5) { vis3.requests.count > settled }
        check(m.visibility == .expanded && vis3.requests.count == settled, "user expanded meanwhile: the restore does not reveal on its own")
    }
}

// MARK: - Live, read-only: the clock and Notification Center on this Mac

@MainActor
func probeClockAssistLive() {
    print("Read-only probe: clock + Notification Center on this Mac (informational; nothing is clicked or activated)")
    softFailures = sessionLocked
    defer { softFailures = false }
    let pids = NotificationCenterDetector.processIDs()
    print("  Notification Center: \(pids.isEmpty ? "not running" : "pid \(pids.sorted().map(String.init).joined(separator: ", "))"), "
          + "open now: \(NotificationCenterDetector.isOpen(processIDs: pids))")
    guard Permissions.isGranted(.accessibility) else {
        print("  (辅助功能 not granted — clock lookup skipped)")
        return
    }
    let bands = MenuBarGeometry.menuBarBands(screens: ScreenGeometry.current(), thickness: NSStatusBar.system.thickness)
    let owners = NativeLayoutResolver.systemItemOwners.sorted().flatMap { bundle in
        NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map {
            RunningAppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? bundle, bundleID: bundle)
        }
    }
    var items: [MenuBarItemInfo]?
    DispatchQueue.global(qos: .userInitiated).async {
        let scanned = MenuBarItemScanner.scan(apps: owners, excludingPID: getpid(), bands: bands).items
        DispatchQueue.main.async { items = scanned }
    }
    guard waitUntil(5, { items != nil }), let items else {
        print("  (scan did not finish — skipped)")
        return
    }
    let frames = ClockLocator.clockFrames(items: items, bands: bands, rightToLeft: NativeLayoutResolver.preferredLanguageIsRightToLeft(),
                                          projectToOtherDisplays: NSScreen.screensHaveSeparateSpaces)
    print("  clock: " + (frames.isEmpty ? "not found" : frames.map { "(\(Int($0.minX)), \(Int($0.minY)), \(Int($0.width)) × \(Int($0.height)))" }
        .joined(separator: ", ")) + " — identified: \(items.contains(where: ClockLocator.isClock))")
    var shown: [Bool]?
    let centres = frames.map { CGPoint(x: $0.midX, y: $0.midY) }
    DispatchQueue.global(qos: .userInitiated).async {
        let result = centres.map { ClockLocator.menuBarShown(at: $0) }
        DispatchQueue.main.async { shown = result }
    }
    _ = waitUntil(3) { shown != nil }
    print("  menu bar on screen at the clock (window level \(ClockLocator.menuBarWindowLevel)): \(shown.map { "\($0)" } ?? "not read")")
    if !sessionLocked {
        check(!frames.isEmpty, "the clock is found in the menu bar")
        check(shown.map { !$0.isEmpty && !$0.contains(false) } == true, "the menu bar is seen on screen at the clock (menu-bar-level window)")
    }
}
