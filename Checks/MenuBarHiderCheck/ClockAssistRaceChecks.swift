import AppKit
import OneSwitchCore
import MenuBarHider

// 点击时钟打开通知中心 — adversarial cases: double clicks, presses elsewhere / with ⌘ ⌃, readings that come
// late (sleep, a hung window list), Notification Center opened without a click, several displays,
// right-to-left, the lock screen, settings changes and restores racing with the user, stop / start hygiene.
// Fakes only: nothing is clicked, no real monitor is installed, the real restriction is never touched.

@MainActor
final class ClockHooks {
    var canEngage = true
    var previous: ClockAssistPrevious? = .collapsed
    var engaged: [ClockAssistPrevious] = []
    var restored: [ClockAssistPrevious] = []
}

@MainActor
func makeClockAssist(_ env: FakeClockEnv, _ hooks: ClockHooks) -> NotificationCenterClockAssist {
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

// MARK: - Pure pieces

@MainActor
func checkClockAssistLocatorEdgeCases() {
    print("点击时钟打开通知中心: recognising the clock (other extras, displays, right-to-left, lock screen)")
    let wifi = agentItem("com.apple.menuextra.wifi", x: 1663, w: 22, name: "Wi‑Fi")
    let cc = agentItem("com.apple.menuextra.controlcenter", x: 1733, w: 26, name: "控制中心")
    let clockItem = agentItem(ClockLocator.clockIdentifier, x: 1775, w: 125, name: "时钟")
    let bands = [studioBand]

    // The fallback must never pick another extra: a click posted there would close the panel just opened.
    check(ClockLocator.clockFrames(items: [wifi, cc], bands: bands, rightToLeft: false).isEmpty,
          "clock not reported, 控制中心 at the edge: no fallback (never taken for the clock)")
    check(ClockLocator.clock(at: CGPoint(x: 1745, y: 15), items: [wifi, cc], bands: bands, rightToLeft: false) == nil,
          "…a click on 控制中心 is left alone")
    check(!ClockLocator.isClock(agentItem("com.apple.menuextra.timer", x: 1600, w: 60, name: "Clock Timer")),
          "an extra with its own identifier is not the clock because its label mentions one")
    check(!ClockLocator.isClock(agentItem(nil, x: 1600, w: 60, name: "World Clock"))
          && ClockLocator.isClock(agentItem(nil, x: 1775, w: 125, name: "Clock"))
          && ClockLocator.isClock(agentItem(nil, x: 1775, w: 125, name: "系统图标", detail: "时钟")),
          "without an identifier: the clock's own label (Clock / 时钟), not a label that merely contains it")
    check(ClockLocator.isClock(agentItem(ClockLocator.clockIdentifier, x: 1775, w: 125, name: "9:41")), "the identifier alone is enough")
    check(ClockLocator.clockFrames(items: [clockItem, agentItem(nil, x: 1775, w: 125, name: "时钟")], bands: bands, rightToLeft: false)
          == [studioClock], "one clock per menu bar")

    // Several displays, each with its own menu bar (CG: the second one above, 25 pt bar).
    let second = CGRect(x: 1920, y: -200, width: 2560, height: 25)
    let projected = CGRect(x: 4480 - 145, y: -200, width: 125, height: 25)
    check(ClockLocator.clockFrames(items: [clockItem], bands: [studioBand, second], rightToLeft: false, projectToOtherDisplays: true)
          == [studioClock, projected],
          "separate menu bars, macOS reported the clock on one display only: projected onto the other (same distance from the edge)")
    check(ClockLocator.clock(at: CGPoint(x: 4400, y: -188), items: [clockItem], bands: [studioBand, second], rightToLeft: false,
                             projectToOtherDisplays: true) == projected, "…a click on the other display's clock is on the clock")
    check(ClockLocator.clock(at: CGPoint(x: 4400, y: -188), items: [clockItem], bands: [studioBand, second], rightToLeft: false) == nil,
          "…without separate Spaces (no menu bar on that display): nothing projected")
    let clock2 = agentItem(ClockLocator.clockIdentifier, x: 4380, w: 100, y: -200, h: 25)
    check(ClockLocator.clockFrames(items: [clockItem, clock2], bands: [studioBand, second], rightToLeft: false, projectToOtherDisplays: true)
          == [studioClock, clock2.frame], "a display with its own clock keeps it (nothing projected over it)")
    check(ClockLocator.clockFrames(items: [agentItem(nil, x: 1775, w: 125)], bands: [studioBand, second], rightToLeft: false,
                                   projectToOtherDisplays: true) == [studioClock],
          "only a recognised clock is projected (not the fallback guess)")

    // Right-to-left: the clock is left-most.
    let rtlClock = agentItem(ClockLocator.clockIdentifier, x: 0, w: 125, name: "时钟")
    check(ClockLocator.clockFrames(items: [rtlClock], bands: [studioBand, second], rightToLeft: true, projectToOtherDisplays: true)
          == [rtlClock.frame, CGRect(x: 1920, y: -200, width: 125, height: 25)], "right-to-left: projected from the left edge")
    check(ClockLocator.clock(at: CGPoint(x: 1850, y: 15), items: [rtlClock, agentItem("com.apple.menuextra.wifi", x: 1800)],
                             bands: bands, rightToLeft: true) == nil, "right-to-left: a click at the right end is not the clock")
    check(ClockLocator.clockFrames(items: [agentItem(nil, x: 0, w: 125), agentItem(nil, x: 1800)], bands: bands, rightToLeft: true)
          == [CGRect(x: 0, y: 0, width: 125, height: 30)], "right-to-left fallback: the left-most unidentified system item")
    check(ClockLocator.clockFrames(items: [cc.moved(toX: 0), agentItem(nil, x: 1800)], bands: bands, rightToLeft: true).isEmpty,
          "right-to-left: 控制中心 at the edge is never taken for the clock")

    // Lock screen: measured on this Mac — the full-size window is on screen while the lock screen lists notifications.
    let panel = WindowSummary(pid: 1251, layer: 21, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    check(!NotificationCenterDetector.isOpen(windows: [panel], processIDs: [1251], sessionLocked: true)
          && NotificationCenterDetector.isOpen(windows: [panel], processIDs: [1251], sessionLocked: false),
          "screen locked (its notification list uses the same window): never counted as open")
    check(ClockAssistMouseEvent(kind: .down, location: .zero).modified == false, "a plain press by default")

    // Is the menu bar on screen where the user clicked? (macOS 27: Window Server's "Menubar" + MenuBarAgent, level 24.)
    let level = ClockLocator.menuBarWindowLevel
    let menubar = WindowSummary(pid: 0, layer: level, bounds: CGRect(x: 0, y: 0, width: 1920, height: 30))
    let fullScreenApp = WindowSummary(pid: 400, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    check(level == 24, "menu-bar window level: \(level)")
    check(ClockLocator.menuBarShown(at: studioClockPoint, windows: [fullScreenApp, menubar]), "menu bar on screen at the clock")
    check(!ClockLocator.menuBarShown(at: studioClockPoint, windows: [fullScreenApp]),
          "full-screen app / hidden menu bar: the top strip is the app's → never treated as the clock")
    check(!ClockLocator.menuBarShown(at: studioClockPoint, windows: [fullScreenApp, WindowSummary(pid: 0, layer: level, bounds: CGRect(x: 0, y: -30, width: 1920, height: 30))]),
          "menu bar slid up out of the screen (hiding itself): not shown")
    check(!ClockLocator.menuBarShown(at: studioClockPoint, windows: [WindowSummary(pid: 0, layer: level, bounds: menubar.bounds, alpha: 0)]),
          "transparent menu-bar window: not shown")
    check(!ClockLocator.menuBarShown(at: studioClockPoint, windows: [WindowSummary(pid: 500, layer: 25, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))]),
          "an overlay at the status level is no menu bar")
    check(ClockLocator.menuBarShown(at: CGPoint(x: 4400, y: -188),
                                    windows: [menubar, WindowSummary(pid: 0, layer: level, bounds: CGRect(x: 1920, y: -200, width: 2560, height: 25))]),
          "each display's own menu bar counts")
    let parsed = WindowSummary.parse([
        [kCGWindowOwnerPID as String: pid_t(0), kCGWindowLayer as String: 24, kCGWindowName as String: "Menubar",
         kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 1920, height: 30).dictionaryRepresentation],
        [kCGWindowOwnerPID as String: pid_t(9)], // incomplete entry
    ])
    check(parsed == [WindowSummary(pid: 0, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1920, height: 30))], "window list parsed")
}

private extension MenuBarItemInfo {
    func moved(toX x: CGFloat) -> MenuBarItemInfo {
        var copy = self
        copy.frame.origin.x = x
        return copy
    }
}

// MARK: - State machine

@MainActor
func checkClockAssistRaces() {
    print("点击时钟打开通知中心: double clicks, other presses, late readings, displays (fakes; nothing posted)")
    let p = studioClockPoint

    // Double click: the second press comes once the restriction is gone and opens Notification Center itself.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = ClockHooks()
        let assist = makeClockAssist(env, hooks)
        env.click(p)
        env.time.advance(by: 0.08)
        env.press(p)
        env.time.advance(by: 0.3)
        check(env.posted.isEmpty && env.ncQueries == 0 && assist.phase == .released,
              "double click: nothing decided while the second press is down (the first decision is dropped)")
        env.ncOpen = true // the second press reached the clock
        env.lift(p)
        env.time.advance(by: 0.13)
        check(env.posted.isEmpty && assist.phase == .watching && hooks.engaged.count == 1 && env.probeRequests.count == 1,
              "…it opened Notification Center by itself → no click posted (it would close it again); one lookup, one release")
        env.ncOpen = false
        env.time.advance(by: 0.3)
        check(hooks.restored == [.collapsed], "…restored once closed")
    }

    // Double click whose second press came too early to reach the clock: one click, after the second press.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = ClockHooks()
        let assist = makeClockAssist(env, hooks)
        env.click(p)
        env.time.advance(by: 0.1)
        env.press(p)
        env.time.advance(by: 0.1) // past the first press's decision time
        check(env.posted.isEmpty, "second press down: never a click while the user's button is down")
        env.lift(p)
        env.time.advance(by: 0.11)
        check(env.posted.isEmpty, "…the decision waits ~120 ms after the second press")
        env.time.advance(by: 0.02)
        check(env.posted.count == 1 && assist.syntheticClicks == 1, "…then exactly one click")
        env.ncOpen = true
        env.time.advance(by: 0.3)
        env.ncOpen = false
        env.time.advance(by: 0.3)
        check(hooks.restored == [.collapsed] && env.posted.count == 1, "…restored; still one click")
    }

    // Triple click: the last press decides, once.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = ClockHooks()
        _ = makeClockAssist(env, hooks)
        for _ in 0..<3 {
            env.click(p)
            env.time.advance(by: 0.05)
        }
        env.time.advance(by: 0.1)
        check(env.posted.count == 1 && hooks.engaged.count == 1, "triple click: one release, one click")
    }

    // Double click before the lookup answered.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = ClockHooks()
        env.manualProbe = true
        let assist = makeClockAssist(env, hooks)
        env.click(p)
        env.press(p)
        env.deliverProbes()
        check(assist.phase == .released && env.probeRequests.count == 1, "double click before the lookup answered: one lookup, released")
        env.time.advance(by: 0.5)
        check(env.posted.isEmpty, "…nothing posted while the second press is down")
        env.lift(p)
        env.time.advance(by: 0.13)
        check(env.posted.count == 1, "…one click after it")
    }

    // A reading in flight when the user presses again: it decides nothing; the next one does.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = ClockHooks()
        env.manualNC = true
        let assist = makeClockAssist(env, hooks)
        env.click(p)
        env.time.advance(by: 0.13)
        check(env.pendingNCCount == 1, "Notification Center being read (slow)")
        env.press(p)
        env.deliverNC()
        check(env.posted.isEmpty && assist.phase == .released, "pressed again while it was read: that reading decides nothing")
        env.lift(p)
        env.time.advance(by: 0.13)
        env.deliverNC()
        check(env.posted.count == 1 && assist.phase == .watching, "…the reading after the second press does")
        env.time.advance(by: 0.3)
        env.deliverNC()
        env.time.advance(by: 1)
        env.deliverNC()
        check(hooks.restored == [.collapsed], "…restored after the grace period (it never opened here)")
    }

    // ⌘ / ⌃ presses, presses elsewhere right after the clock.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = ClockHooks()
        let assist = makeClockAssist(env, hooks)
        env.press(p, modified: true)
        env.lift(p)
        check(env.probeRequests.isEmpty && hooks.engaged.isEmpty, "⌘ / ⌃ press on the clock (rearranging, context click): not even looked up")

        env.click(p)
        env.time.advance(by: 0.05)
        env.click(CGPoint(x: 700, y: 500)) // the desktop, right away
        env.time.advance(by: 0.13)
        check(env.posted.isEmpty && assist.phase == .watching && hooks.engaged.count == 1,
              "clock, then a click elsewhere right away: no click posted")
        env.time.advance(by: 1.2)
        check(hooks.restored == [.collapsed], "…restored after the grace period")

        env.click(p)
        env.time.advance(by: 0.05)
        env.press(p, modified: true)
        env.lift(p)
        env.time.advance(by: 0.13)
        check(env.posted.isEmpty && hooks.engaged.count == 2, "clock, then a ⌘-press on it: no click posted")
        assist.cancel(restore: false, reason: "check")

        env.manualProbe = true
        env.press(p)
        env.lift(p)
        env.press(CGPoint(x: 1745, y: 15)) // 控制中心, before the lookup answered
        env.deliverProbes()
        check(hooks.engaged.count == 2 && assist.phase == .idle, "another item pressed before the lookup answered: nothing released")
        env.lift(CGPoint(x: 1745, y: 15))
        env.time.advance(by: 2)
        check(env.posted.isEmpty && env.time.pendingCount == 0, "…nothing posted or scheduled")
    }

    // Readings that come far too late: the Mac slept right after the click, or the window list hung.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = ClockHooks()
        let assist = makeClockAssist(env, hooks)
        env.click(p)
        env.time.now = env.time.now.addingTimeInterval(8 * 3600) // asleep: the timer fires hours late
        env.time.advance(by: 0)
        check(env.posted.isEmpty && assist.phase == .watching, "the decision runs hours late (sleep): no click posted")
        env.time.advance(by: 1.3)
        check(hooks.restored == [.collapsed], "…the previous state comes back")

        env.manualNC = true
        env.click(p)
        env.time.advance(by: 0.13)
        env.time.advance(by: 2)
        env.deliverNC()
        check(env.posted.isEmpty && assist.phase == .watching, "a reading that answers 2 s late: no click posted")
        assist.cancel(restore: false, reason: "check")
        check(env.time.pendingCount == 0, "…cancelled: no timer left")
    }

    // Long second press: nothing posted for it.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = ClockHooks()
        let assist = makeClockAssist(env, hooks)
        env.click(p)
        env.time.advance(by: 0.05)
        env.press(p)
        env.time.advance(by: 1.6)
        check(assist.phase == .watching && env.posted.isEmpty, "second press held > 1.5 s: no click posted")
        env.lift(p)
        env.time.advance(by: 1.2)
        check(hooks.restored == [.collapsed] && env.posted.isEmpty, "…restored, still nothing posted")
    }

    // Notification Center opened without a click (trackpad gesture, fn N): nothing happens at all.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = ClockHooks()
        let assist = makeClockAssist(env, hooks)
        env.ncOpen = true
        env.time.advance(by: 5)
        check(env.probeRequests.isEmpty && env.ncQueries == 0 && env.posted.isEmpty && assist.phase == .idle && env.time.pendingCount == 0,
              "Notification Center opened by a gesture / fn N: nothing looked up, read, posted or scheduled")
        env.click(CGPoint(x: 1700, y: 400))
        check(env.probeRequests.isEmpty && hooks.engaged.isEmpty, "clicks in its panel (below the menu bar) are not even looked up")
        env.ncOpen = false
        env.time.advance(by: 1)
        check(hooks.restored.isEmpty && env.ncQueries == 0, "…closing it restores nothing")
    }

    // Presses while watching reach macOS; nothing new starts, nothing is cancelled.
    do {
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand]), hooks = ClockHooks()
        let assist = makeClockAssist(env, hooks)
        env.click(p)
        env.time.advance(by: 0.13)
        env.ncOpen = true
        env.time.advance(by: 0.3)
        env.click(p) // the user closes it by clicking the clock again
        env.ncOpen = false
        env.interacting = true // pointer still in the bar
        env.time.advance(by: 0.6)
        check(assist.phase == .watching && env.posted.count == 1 && env.probeRequests.count == 1 && hooks.restored.isEmpty,
              "clock clicked again while watching: reaches macOS, nothing posted; restore waits for the pointer")
        env.interacting = false
        env.time.advance(by: 0.3)
        check(hooks.restored == [.collapsed] && env.time.pendingCount == 0, "…restored, polling stopped")
    }

    // Several displays: the clock of the second display.
    do {
        let second = CGRect(x: 1920, y: -200, width: 2560, height: 25)
        let clock2 = CGRect(x: 4335, y: -200, width: 125, height: 25)
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand, second]), hooks = ClockHooks()
        env.clocks.append(clock2)
        let assist = makeClockAssist(env, hooks)
        let p2 = CGPoint(x: 4400, y: -188)
        env.pointer = CGPoint(x: 900, y: 500) // moved away meanwhile
        env.click(p2)
        env.time.advance(by: 0.13)
        check(assist.clockFrame == clock2 && env.posted == [CGPoint(x: clock2.midX, y: clock2.midY)],
              "second display: its clock is clicked (centre, the pointer had left)")
        assist.cancel(restore: true, reason: "check")
        check(hooks.restored == [.collapsed], "…restored")
    }
}

// MARK: - Controller (fake restriction + fake monitor; real toggle item, removed again)

@MainActor
func checkClockAssistControllerRaces() {
    print("点击时钟打开通知中心: controller races (settings mid-episode, restore steps, stop / start hygiene)")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let suiteName = "oneswitch.menubarhidercheck.clockraces"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    let suffix = "-selfcheck-clockraces"
    defer {
        let std = UserDefaults.standard
        for key in std.dictionaryRepresentation().keys where key.hasPrefix("NSStatusItem")
            && (key.hasSuffix(suffix) || key.hasSuffix(suffix + "-mbp") || key.hasSuffix(suffix + "-legacy")) {
            std.removeObject(forKey: key)
        }
        suite.removePersistentDomain(forName: suiteName)
    }
    let p = studioClockPoint

    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory()), timers = FakeTimers()
        let env = FakeClockEnv(clock: studioClock, bands: [studioBand])
        var deps = makeDeps(vis, inv, running: ["com.left", "com.left2", "com.right", "com.split"], timers: timers)
        deps.clockAssist = env.deps
        let module = MenuBarHiderModule(defaults: suite, autosaveSuffix: suffix, strategy: .systemOverflow, native: deps)
        let c = module.controller
        c.store.update { $0.collapseAtLaunch = false }
        module.start()
        c.collapse()
        vis.succeed(0)

        // Notification Center opened by a gesture while collapsed: nothing happens.
        env.ncOpen = true
        _ = waitUntil(0.2) { false }
        check(c.visibility == .collapsed && vis.requests.count == 1 && env.probeRequests.isEmpty && c.clockAssistPhase == .idle,
              "Notification Center opened without a click while collapsed: nothing released")
        env.ncOpen = false

        // The auto-hide settings change while Notification Center is open.
        env.click(p)
        env.time.advance(by: 0.13)
        env.ncOpen = true
        env.time.advance(by: 0.3)
        c.store.update { $0.autoCollapseDelay = 20 }
        check(c.visibility == .expandedAll && c.secondsUntilCollapse == nil && c.clockAssistPhase == .watching,
              "auto-hide delay changed while Notification Center is open: still no deadline, the episode goes on")
        c.store.update { $0.autoCollapse = false }
        check(c.secondsUntilCollapse == nil && c.clockAssistPhase == .watching, "auto-hide switched off meanwhile: same")
        c.store.update { $0.autoCollapse = true }
        env.ncOpen = false
        env.time.advance(by: 0.3)
        check(c.visibility == .collapsed && vis.requests.count == 2, "…closed → collapsed again")
        vis.succeed(1)

        // Double click: the second press opened Notification Center by itself.
        let posted = env.posted.count
        env.click(p)
        env.time.advance(by: 0.05)
        env.press(p)
        env.ncOpen = true
        env.lift(p)
        env.time.advance(by: 0.13)
        check(env.posted.count == posted && vis.active.isEmpty && c.clockAssistPhase == .watching,
              "double click that opened Notification Center: no click posted, bar unrestricted")
        env.ncOpen = false
        env.time.advance(by: 0.3)
        check(c.visibility == .collapsed && vis.requests.count == 3, "…closed → collapsed again")
        vis.succeed(2)

        // stop while the clock is being looked up: a late answer does nothing.
        env.manualProbe = true
        env.press(p)
        module.stop()
        env.deliverProbes()
        env.lift(p)
        env.time.advance(by: 2)
        check(vis.requests.count == 3 && env.posted.count == posted && vis.active.isEmpty && env.time.pendingCount == 0
              && env.handler == nil && env.installs == env.removals,
              "stopped while looking the clock up: the late answer releases / posts nothing, no monitor, no timer")
        env.manualProbe = false

        // start / stop cycles never leak a monitor or a timer.
        for _ in 0..<3 {
            module.start()
            module.stop()
        }
        check(env.installs == env.removals && env.handler == nil && env.time.pendingCount == 0,
              "start / stop ×3: every monitor removed, no timer left (\(env.installs) installed)")
        c.store.update { $0.enabled = false }
        let installs = env.installs
        module.start()
        check(!c.clockAssistMonitoring && env.installs == installs, "started disabled: no monitor")
        module.stop()
        c.store.update { $0.enabled = true }
    }

    // Legacy engine: Notification Center is never read, not even for the auto-hide.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory()), env = FakeClockEnv(clock: studioClock, bands: [studioBand])
        var deps = makeDeps(vis, inv, running: ["com.left"])
        deps.clockAssist = env.deps
        let legacy = MenuBarHiderModule(defaults: suite, autosaveSuffix: suffix + "-legacy", strategy: .pushOffscreen, native: deps)
        legacy.controller.store.update { $0.collapseAtLaunch = false }
        legacy.start()
        env.ncOpen = true
        var busy: Bool?
        legacy.controller.isMenuBarInUse { busy = $0 }
        _ = waitUntil(1) { busy != nil }
        check(env.ncQueries == 0 && env.installs == 0, "separator engine: Notification Center never read, no monitor")
        legacy.stop()
        suite.removePersistentDomain(forName: suiteName)
    }

    // MacBook Pro: the clock clicked between the two steps of restoring a partial reveal.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let mbpClock = CGRect(x: 1420, y: 0, width: 82, height: 37)
        let q = CGPoint(x: 1460, y: 18)
        let env = FakeClockEnv(clock: mbpClock, bands: [mbpBand])
        var deps = makeRevealDeps(vis, inv, running: { mbpRunning }, toggle: mbpToggle, timers: timers, probe: probe)
        deps.clockAssist = env.deps
        let mbp = MenuBarHiderModule(defaults: suite, autosaveSuffix: suffix + "-mbp", strategy: .systemOverflow, native: deps)
        let m = mbp.controller
        mbp.start()
        defer { mbp.stop() }
        guard waitUntil(3, { vis.requests.count == 1 }) else {
            check(false, "MacBook Pro: hide at launch requested")
            return
        }
        vis.succeed(0)
        timers.fireAll()

        // The clock clicked while the partial reveal is still being requested (the collapsed restriction held).
        m.expand()
        check(vis.requests.count == 2 && m.nativeState == .activating && m.diagnostics().nativeRestricted,
              "MacBook Pro expanding: the reveal is being requested")
        env.click(q)
        check(m.visibility == .expandedAll && vis.active.isEmpty && !m.diagnostics().nativeRestricted,
              "clock clicked while the reveal was being set up → everything released at once")
        vis.succeed(1) // the reveal is granted late
        check(vis.active.isEmpty && m.visibility == .expandedAll && m.nativeRevealPlan == nil, "…the late grant is dropped on arrival")
        env.time.advance(by: 0.13)
        env.ncOpen = true
        env.time.advance(by: 0.3)
        env.ncOpen = false
        env.time.advance(by: 0.3)
        check(m.visibility == .collapsed && vis.requests.count == 3, "closed → restore step 1: collapse")
        vis.succeed(2)
        check(waitUntil(1) { vis.requests.count == 4 }, "…step 2: the reveal the user had asked for")
        vis.succeed(3)
        check(m.visibility == .expanded && m.nativeRevealPlan?.unfit == ["com.far"], "MacBook Pro expanded: partial reveal")

        // The clock clicked between the two restore steps.
        env.click(q)
        env.time.advance(by: 0.13)
        env.ncOpen = true
        env.time.advance(by: 0.3)
        env.ncOpen = false
        env.time.advance(by: 0.3)
        check(m.visibility == .collapsed && vis.requests.count == 5, "closed → restore step 1: collapse")
        vis.succeed(4) // granted: step 2 (reveal what fits) is queued
        env.click(q)   // …but the clock is clicked first
        check(m.visibility == .expandedAll && vis.active.isEmpty && m.clockAssistPhase == .released,
              "clock clicked between the two restore steps → released again")
        _ = waitUntil(0.3) { false } // the queued step runs: it must not reveal now
        check(m.visibility == .expandedAll && vis.requests.count == 5, "…the queued reveal step does nothing")
        env.time.advance(by: 0.13)
        env.time.advance(by: 1.2) // never opened → restore
        check(m.visibility == .collapsed && vis.requests.count == 6, "…restore: collapse first")
        vis.succeed(5)
        check(waitUntil(1) { vis.requests.count == 7 }, "…then the partial reveal it interrupted comes back (not just collapsed)")
        vis.succeed(6)
        check(m.visibility == .expanded && m.nativeRevealPlan?.unfit == ["com.far"] && vis.active.count == 1,
              "partial reveal restored, one restriction")
    }
}
