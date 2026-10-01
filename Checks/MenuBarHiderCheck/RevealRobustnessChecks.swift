import AppKit
import OneSwitchCore
import MenuBarHider

// "Reveal what fits", adversarial cases: several displays, our own items dropped without a «, the frontmost
// app / running apps changing while icons are revealed, and rapid clicks. Everything runs against fakes.

/// Collapsed (granted) and measured, ready to expand.
@MainActor
func collapsedRevealEngine(_ vis: FakeVisibility, _ inv: FakeInventory, _ timers: FakeTimers, _ probe: FakeRevealProbe?,
                           running: @escaping () -> [String] = { mbpRunning }, toggle: CGRect = mbpToggle,
                           own: FakeOwnItems? = nil) -> (NativeVisibilityEngine, FakeAssertion) {
    let engine = NativeVisibilityEngine(dependencies: makeRevealDeps(vis, inv, running: running, toggle: toggle, timers: timers,
                                                                     probe: probe, own: own)) { nil }
    engine.collapse(rules: [:]) { _ in }
    let held = vis.succeed(vis.requests.count - 1)
    timers.fireAll() // the collapsed bar is measured
    return (engine, held)
}

// MARK: - Pure pieces

@MainActor
func checkRevealEdgeCases() {
    print("系统原生隐藏 · reveal what fits: several displays, our own items, re-check planning")
    typealias R = NativeRevealPlanner

    // An external display (primary, no notch) hosts「<」; the notched built-in display shows the same icons.
    let external = CGRect(x: 0, y: 0, width: 1920, height: 30)
    let both = NativeStatusStrip(band: external, menusMinX: 0, menusMaxX: 600, otherNotchSides: [663])
    check(R.availableRoom(strip: both, innerEdge: 1300, rightToLeft: false) == 19,
          "external display hosts「<」: icons take 620 pt from the right edge on every display → 663 − 620 − 24 = 19 pt beside the built-in notch (not 668)")
    check(both.limitedByNotch && !both.hasNotch, "…limited by the other display's notch (刘海右侧空间不足)")
    check(R.availableRoom(strip: NativeStatusStrip(band: external, otherNotchSides: [663]), innerEdge: 1300, rightToLeft: false) == 19,
          "…menus unreadable on the external display: the notched display still bounds the room (no blind release)")
    check(R.availableRoom(strip: NativeStatusStrip(band: external, menusMinX: 1300, menusMaxX: 1900, otherNotchSides: [663]),
                          innerEdge: 500, rightToLeft: true) == 139,
          "right-to-left: icons take 500 pt from the left edge → 663 − 500 − 24 = 139 pt (own display: 768)")
    let zero = NativeStatusStrip(band: external, menusMinX: 0, menusMaxX: 600, otherNotchSides: [0])
    check(R.availableRoom(strip: zero, innerEdge: 1300, rightToLeft: false) == 668 && !zero.limitedByNotch,
          "a zero-width notch area elsewhere is ignored (Studio: unchanged 1300 − 608 − 24)")
    check(R.availableRoom(strip: NativeStatusStrip(band: mbpBand, notchSideWidth: mbpNotchSide, menusMinX: 0, menusMaxX: 420,
                                                   otherNotchSides: [500]), innerEdge: 1000, rightToLeft: false) == -36,
          "two notched displays: the tighter one wins (500 − 512 − 24)")

    // Our own items, compared before / after a reveal.
    let monitor = CGRect(x: 1040, y: 0, width: 50, height: 37)
    let before = NativeOwnItems(frames: [mbpToggle, monitor], band: mbpBand)
    check(before == NativeOwnItems(laidOut: 2, stacked: 0), "「<」+ 系统监控 laid out, not stacked")
    check(NativeOwnItems(frames: [mbpToggle, monitor, CGRect(x: 2000, y: 0, width: 30, height: 30)], band: mbpBand).laidOut == 2,
          "an item on another display is not counted")
    let dropped = NativeOwnItems(frames: [mbpToggle, CGRect(x: 1040, y: 1068, width: 50, height: 24)], band: mbpBand)
    check(dropped.laidOut == 1 && R.ownItemsDisplaced(before: before, after: dropped), "an item reported below the bar (y 1068) → displaced")
    check(R.ownItemsDisplaced(before: before, after: NativeOwnItems(frames: [mbpToggle], band: mbpBand)), "an item gone from the bar → displaced")
    let parked = NativeOwnItems(frames: [mbpToggle, CGRect(x: 1003, y: 0, width: 50, height: 37)], band: mbpBand)
    check(parked.stacked == 2 && R.ownItemsDisplaced(before: before, after: parked), "two of our items stacked (parked in the «) → displaced")
    let shifted = NativeOwnItems(frames: [mbpToggle.offsetBy(dx: -109, dy: 0), CGRect(x: 931, y: 0, width: 50, height: 37)], band: mbpBand)
    check(!R.ownItemsDisplaced(before: before, after: shifted), "pushed further in by revealed icons, still side by side → fine")
    let touching = NativeOwnItems(frames: [mbpToggle, CGRect(x: 1025, y: 0, width: 50, height: 37)], band: mbpBand)
    check(touching.stacked == 0, "1 pt of overlap (rounding) is not stacking")
    check(!R.ownItemsDisplaced(before: parked, after: parked), "already parked before the reveal → not the reveal's doing")
    check(!R.ownItemsDisplaced(before: before, after: NativeOwnItems(frames: [mbpToggle, monitor, CGRect(x: 1100, y: 0, width: 30, height: 37)],
                                                                      band: mbpBand)),
          "an item added meanwhile is fine")

    // A re-check only ever hides: apps outside `revealable` are never revealed.
    func c(_ id: String, edge: CGFloat) -> NativeRevealCandidate {
        NativeRevealCandidate(bundleID: id, name: id, itemCount: 1, width: 24, edgeDistance: edge)
    }
    let limited = R.plan(candidates: [c("a", edge: 1), c("b", edge: 2), c("c", edge: 3)], available: 200, notched: true,
                         revealable: ["a", "c"])
    check(limited.revealed == ["a", "c"] && limited.unfit == ["b"], "revealable set: b (not shown now) is never added, even with room")

    // Estimate anchored at our leftmost item: allowed apps beyond it are assumed further in.
    let layout = NativeLayoutResolver.resolve(inventory: mbpInventory(), toggle: mbpToggle, ownBundleIDs: [ownID])
    check(R.estimatedOthersEdge(from: 880, layout: layout, allowed: ["com.right", "com.mid"],
                                metrics: ["com.mid": NativeAppMetrics(itemCount: 1, width: 40)], rightToLeft: false) == 833,
          "estimate from our leftmost item (系统监控 at x 880): 880 − 47")
    check(R.estimatedOthersEdge(from: 880, layout: layout, allowed: ["com.right", "com.mid"],
                                metrics: ["com.mid": NativeAppMetrics(itemCount: 1, width: 40)], rightToLeft: true) == 927,
          "…right-to-left: 880 + 47")
}

// MARK: - Engine with fakes

@MainActor
func checkRevealEngineEdgeCases() {
    print("系统原生隐藏 · reveal what fits: engine edge cases (fake restriction, probe, timers)")

    // 1. 「<」on an external display, the notched built-in display shows the same icons.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory()), timers = FakeTimers()
        let probe = FakeRevealProbe(strip: NativeStatusStrip(band: studioBand, menusMinX: 0, menusMaxX: 600, otherNotchSides: [663]))
        let running = ["com.left", "com.left2", "com.right", "com.split"]
        let (engine, collapsed) = collapsedRevealEngine(vis, inv, timers, probe, running: { running }, toggle: toggleCG)
        var outcome: NativeVisibilityEngine.RevealOutcome?
        engine.reveal { outcome = $0 }
        check(vis.requests.count == 1 && !collapsed.isInvalidated && engine.isRestricted && engine.state == .revealed,
              "icons shown already take 770 pt, the built-in notch leaves 663 → nothing revealed, nothing released")
        if case .partial(let plan)? = outcome {
            check(plan.revealed.isEmpty && Set(plan.unfit) == ["com.left", "com.left2"] && plan.notched,
                  "…both hidden apps reported as not fitting (刘海); com.overflow / com.parked are not running → not counted")
        } else {
            check(false, "partial outcome on the external display (\(String(describing: outcome)))")
        }
        engine.collapse(rules: [:]) { _ in }
        vis.succeed(1)
        timers.fireAll()
        probe.strip = NativeStatusStrip(band: studioBand, menusMinX: 0, menusMaxX: 600, otherNotchSides: [830])
        outcome = nil
        engine.reveal { outcome = $0 }
        check(vis.requests.count == 3 && vis.requests[2].bundles.contains("com.left2") && !vis.requests[2].bundles.contains("com.left"),
              "room for one icon beside that notch (830 − 770 − 24 = 36 pt) → only the nearest (com.left2) revealed")
        vis.succeed(2)
        if case .partial(let plan)? = outcome { check(plan.revealed == ["com.left2"] && plan.unfit == ["com.left"], "…com.left kept hidden") } else {
            check(false, "partial outcome with one app (\(String(describing: outcome)))")
        }
        engine.releaseAll()
        check(vis.active.isEmpty, "released")

        let vis2 = FakeVisibility(), inv2 = FakeInventory(sampleInventory()), timers2 = FakeTimers()
        let single = FakeRevealProbe(strip: NativeStatusStrip(band: studioBand, menusMinX: 0, menusMaxX: 600))
        let (studio, held) = collapsedRevealEngine(vis2, inv2, timers2, single, running: { running }, toggle: toggleCG)
        outcome = nil
        studio.reveal { outcome = $0 }
        if case .all(let plan?)? = outcome {
            check(plan.allFit && held.isInvalidated && vis2.active.isEmpty && vis2.requests.count == 1,
                  "the same bar on the Studio alone (no notch anywhere) → released exactly as before")
        } else {
            check(false, "Studio outcome is .all (\(String(describing: outcome)))")
        }
    }

    // 2. macOS drops one of our other items without a « (a single overflowed item gets none).
    do {
        let own = FakeOwnItems([mbpToggle, CGRect(x: 1040, y: 0, width: 50, height: 37)])
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let (engine, _) = collapsedRevealEngine(vis, inv, timers, probe, own: own)
        var updates: [NativeVisibilityEngine.RevealOutcome] = []
        engine.onRevealUpdate = { updates.append($0) }
        engine.reveal { _ in }
        check(vis.requests.count == 2 && ["com.near", "com.mid", "com.gone"].allSatisfy(vis.requests[1].bundles.contains),
              "partial reveal with our 系统监控 item right of「<」(room still 127 pt)")
        vis.succeed(1)
        own.frames = [mbpToggle.offsetBy(dx: -40, dy: 0), CGRect(x: 1000, y: 0, width: 50, height: 37)]
        timers.fireAll()
        check(vis.requests.count == 2, "first settle check: our items pushed further in, still laid out → nothing changes")
        own.frames = [mbpToggle.offsetBy(dx: -40, dy: 0), CGRect(x: 1040, y: 1068, width: 50, height: 24)]
        timers.fireAll()
        check(vis.requests.count == 3 && !vis.requests[2].bundles.contains("com.gone") && vis.requests[2].bundles.contains("com.mid"),
              "second settle check: 系统监控 dropped (no «) → the farthest revealed app (com.gone) hidden again")
        vis.succeed(2)
        if case .partial(let plan)? = updates.last { check(plan.revealed == ["com.near", "com.mid"], "…reported") } else {
            check(false, "drop reported")
        }
        own.frames = [mbpToggle, CGRect(x: 1003, y: 0, width: 50, height: 37)]
        timers.fireAll()
        check(vis.requests.count == 4 && !vis.requests[3].bundles.contains("com.mid") && vis.requests[3].bundles.contains(ownID),
              "our items stacked on each other (parked in the «) → the next one hidden again; OneSwitch stays allowed")
        vis.succeed(3)
        own.frames = [mbpToggle, CGRect(x: 1040, y: 0, width: 50, height: 37)]
        timers.fireAll()
        timers.fireAll()
        check(vis.requests.count == 4 && engine.state == .revealed && vis.active.count == 1, "back in place → nothing else changes")
        engine.releaseAll()
        check(vis.active.isEmpty, "released")
    }

    // 3. Re-checks while icons are shown (another app in front, apps starting / quitting).
    do {
        var running = mbpRunning
        let own = FakeOwnItems([mbpToggle])
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let (engine, _) = collapsedRevealEngine(vis, inv, timers, probe, running: { running }, own: own)
        var updates: [NativeVisibilityEngine.RevealOutcome] = []
        engine.onRevealUpdate = { updates.append($0) }
        engine.recheckReveal()
        check(probe.requests.isEmpty && vis.requests.count == 1, "re-check while collapsed: no-op")
        engine.reveal { _ in }
        let base = Set(vis.requests[0].bundles)
        let revealed = vis.succeed(1)
        timers.fireAll()
        timers.fireAll()

        // The revealed icons pushed「<」in (a 始终隐藏 app right of it): the room must not count them twice.
        own.frames = [mbpToggle.offsetBy(dx: -109, dy: 0)]
        engine.recheckReveal()
        check(probe.requests.count == 2 && vis.requests.count == 2, "same menus, our items pushed in by the revealed icons → nothing hidden")
        var again: NativeVisibilityEngine.RevealOutcome?
        engine.reveal { again = $0 }
        if case .partial(let plan)? = again {
            check(vis.requests.count == 2 && engine.state == .revealed && plan.revealed == ["com.near", "com.mid", "com.gone"],
                  "expand requested again while shown: planned from the collapsed bar, not our pushed-in items → same apps, nothing requested")
        } else {
            check(false, "expand again while shown (\(String(describing: again)))")
        }
        timers.fireAll()
        timers.fireAll()

        // An app whose menus continue right of the camera housing (to x 900) comes to the front.
        probe.strip = NativeStatusStrip(band: mbpBand, notchSideWidth: mbpNotchSide, menusMinX: 0, menusMaxX: 900)
        engine.recheckReveal()
        check(vis.requests.count == 3 && Set(vis.requests[2].bundles) == base.union(["com.near", "com.gone"]),
              "longer menus (68 pt left): com.mid (47 pt) hidden again, com.gone (31 pt) still fits")
        check(!revealed.isInvalidated && engine.isRestricted, "…the shown restriction is kept until the smaller one is granted")
        let smaller = vis.succeed(2)
        check(revealed.isInvalidated && !smaller.isInvalidated && vis.active.count == 1 && engine.state == .revealed, "…then replaced")
        if case .partial(let plan)? = updates.last {
            check(plan.revealed == ["com.near", "com.gone"] && plan.unfit == ["com.mid", "com.far"] && engine.activeReveal == plan,
                  "…reported: 2 shown, 2 kept hidden")
        } else {
            check(false, "shrink reported (\(updates))")
        }

        // Shorter menus again: nothing is added while icons are shown.
        probe.strip = mbpStrip
        engine.recheckReveal()
        check(vis.requests.count == 3, "more room again → nothing added while shown (the next expand reveals more)")

        // com.gone turns out 60 pt wide (learned by a settle check): with the room unchanged that alone hides nothing.
        probe.strip = NativeStatusStrip(band: mbpBand, notchSideWidth: mbpNotchSide, menusMinX: 0, menusMaxX: 900)
        var wide = mbpInventory()
        wide.items = wide.items.map { item in
            var item = item
            if item.bundleID == "com.gone" { item.frame = CGRect(x: 930, y: 3, width: 60, height: 24) }
            return item
        }
        inv.inventory = wide
        timers.fireAll()
        check(engine.metrics["com.gone"]?.width == 60, "settle check learned com.gone's real width (60 pt)")
        engine.recheckReveal()
        check(vis.requests.count == 3, "same room, only a width learned → nothing hidden (the bar was checked fine)")

        // An app that did not fit quits: the note's count follows.
        running.removeAll { $0 == "com.far" }
        let reported = updates.count
        engine.recheckReveal()
        if updates.count == reported + 1, case .partial(let plan)? = updates.last {
            check(plan.unfit == ["com.mid"] && vis.requests.count == 3, "com.far quit → 1 app kept hidden, nothing requested")
        } else {
            check(false, "quit app reported (\(updates.count - reported) update(s))")
        }

        // Room unknown during a re-check: only the overflow check runs.
        probe.answersNil = true
        let snapshots = inv.snapshots
        engine.recheckReveal()
        check(vis.requests.count == 3, "room unreadable → nothing hidden on a guess")
        timers.fireAll()
        check(inv.snapshots > snapshots, "…but the bar is still checked for an overflow")
        probe.answersNil = false

        // A collapse while the re-check reads the room wins.
        probe.manual = true
        engine.recheckReveal()
        engine.collapse(rules: [:]) { _ in }
        probe.strip = NativeStatusStrip(band: mbpBand, notchSideWidth: mbpNotchSide, menusMinX: 0, menusMaxX: 1200)
        probe.deliverAll()
        check(vis.requests.count == 4 && vis.requests[3].bundles.contains(ownID)
              && !["com.near", "com.mid", "com.gone", "com.far"].contains(where: vis.requests[3].bundles.contains),
              "collapse during a re-check: its late answer requests nothing (only the collapse, from the shown apps' positions)")
        vis.succeed(3)
        check(vis.active.count == 1 && engine.state == .collapsed && engine.activeReveal == nil, "collapsed, one restriction")
        engine.recheckReveal()
        check(vis.requests.count == 4, "re-check after the collapse: no-op")
        engine.releaseAll()
    }

    // 4. Rapid clicks while the first expand is still being granted.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let (engine, collapsed) = collapsedRevealEngine(vis, inv, timers, probe)
        var reports: [String] = []
        engine.reveal { reports.append("reveal-1 \($0)") }
        engine.collapse(rules: [:]) { reports.append("collapse \($0)") }
        engine.reveal { reports.append("reveal-2 \($0)") }
        check(vis.requests.count == 4 && engine.state == .activating && !collapsed.isInvalidated && vis.active.count == 1,
              "expand, collapse, expand before anything was granted: the collapsed restriction stays meanwhile")
        let latest = vis.succeed(3)
        check(collapsed.isInvalidated && !latest.isInvalidated && vis.active.count == 1 && engine.state == .revealed,
              "the last click granted → held, then the collapsed one dropped")
        let late1 = vis.succeed(1)
        vis.fail(2)
        check(late1.isInvalidated && vis.active.count == 1 && engine.state == .revealed && engine.isRestricted,
              "late grant of the first expand invalidated, late failure of the collapse ignored")
        check(reports.count == 1 && reports[0].hasPrefix("reveal-2 partial"),
              "only the last click reports (\(reports.map { String($0.prefix(16)) }))")
        timers.fireAll()
        check(vis.active.count == 1 && engine.state == .revealed, "timeouts of the superseded requests do nothing")
        engine.reveal { reports.append("reveal-3 \($0)") }
        check(vis.requests.count == 4 && engine.state == .revealed && reports.last?.hasPrefix("reveal-3") == true,
              "expand again while shown: planned from the same collapsed bar → the same apps, nothing requested")
        engine.releaseAll()
        check(vis.active.isEmpty, "released")
    }

    // 5b. 「<」follows the active menu bar to another display (with 「显示器具有单独的空间」 status items move to
    //     the display in use): before expanding, and while icons are shown.
    do {
        let external = CGRect(x: 1512, y: 0, width: 1920, height: 30)
        let onExternal = CGRect(x: external.maxX - 512, y: 0, width: 26, height: 30)
        var toggle = mbpToggle
        let own = FakeOwnItems([mbpToggle])
        var inventory = mbpInventory()
        inventory.bands = [mbpBand, external]
        let vis = FakeVisibility(), inv = FakeInventory(inventory), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let deps = NativeHidingDependencies(visibility: vis, inventory: inv, runningBundleIDs: { mbpRunning }, ownBundleIDs: [ownID],
                                            toggleFrame: { toggle }, schedule: timers.schedule, revealProbe: probe.probing,
                                            ownItemFrames: { own.frames })
        let engine = NativeVisibilityEngine(dependencies: deps) { nil }
        engine.collapse(rules: [:]) { _ in }
        vis.succeed(0)
        timers.fireAll() // measured on the built-in display
        toggle = onExternal
        own.frames = [onExternal]
        let externalStrip = NativeStatusStrip(band: external, menusMinX: 1512, menusMaxX: 2112, otherNotchSides: [mbpNotchSide])
        probe.strip = externalStrip
        var outcome: NativeVisibilityEngine.RevealOutcome?
        engine.reveal { outcome = $0 }
        check(vis.requests.count == 2, "reveal requested on the external display")
        vis.succeed(1)
        if case .partial(let plan)? = outcome {
            check(plan.available == 127 && plan.revealed == ["com.near", "com.mid", "com.gone"] && plan.notched,
                  "「<」moved to the external display after the collapse: the measured icons' width carries over → 127 pt beside the built-in notch, same 3 apps")
        } else {
            check(false, "partial reveal on the external display (\(String(describing: outcome)))")
        }
        timers.fireAll()
        toggle = mbpToggle
        own.frames = [mbpToggle]
        timers.fireAll()
        check(vis.requests.count == 2 && engine.state == .revealed, "shown, then「<」back on the built-in display: our items counted where「<」is → nothing hidden")
        probe.strip = mbpStrip
        engine.recheckReveal()
        timers.fireAll()
        check(vis.requests.count == 2, "…re-check there: same room (127 pt) → nothing hidden")
        toggle = onExternal
        own.frames = [onExternal]
        probe.strip = externalStrip
        engine.recheckReveal()
        timers.fireAll()
        timers.fireAll()
        check(vis.requests.count == 2 && engine.state == .revealed && vis.active.count == 1,
              "…and over to the external display again: re-check and settle checks there → nothing hidden")
        engine.releaseAll()
        check(vis.active.isEmpty, "released")
    }

    // 5. Hidden apps that quit since the collapse are no candidates.
    do {
        var running = mbpRunning
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let (engine, collapsed) = collapsedRevealEngine(vis, inv, timers, probe, running: { running })
        running.removeAll { $0 == "com.far" }
        var outcome: NativeVisibilityEngine.RevealOutcome?
        engine.reveal { outcome = $0 }
        if case .all(let plan?)? = outcome {
            check(plan.allFit && plan.costs["com.far"] == nil && collapsed.isInvalidated && vis.active.isEmpty && vis.requests.count == 1,
                  "com.far quit: the rest fits (109 of 127 pt) → released as usual, no「放不下」for a quit app")
        } else {
            check(false, "all-fit outcome after a quit (\(String(describing: outcome)))")
        }
        let vis2 = FakeVisibility(), inv2 = FakeInventory(mbpInventory()), timers2 = FakeTimers()
        var running2 = mbpRunning
        let (engine2, collapsed2) = collapsedRevealEngine(vis2, inv2, timers2, probe, running: { running2 })
        running2 = ["com.right", ownID]
        outcome = nil
        engine2.reveal { outcome = $0 }
        check(outcome == .all(nil) && collapsed2.isInvalidated && vis2.active.isEmpty, "every hidden app quit → nothing to reveal, released")
    }
}

// MARK: - Controller: re-check when another app comes to the front

@MainActor
func checkRevealControllerRecheck() {
    print("系统原生隐藏 · reveal what fits: re-check on app switches, 显示全部 / hotkey, stop (controller; fake restriction)")
    let suiteName = "oneswitch.menubarhidercheck.reveal2"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    let suffix = "-selfcheck-reveal2"
    defer {
        let std = UserDefaults.standard
        for key in std.dictionaryRepresentation().keys where key.hasPrefix("NSStatusItem") && key.hasSuffix(suffix) {
            std.removeObject(forKey: key)
        }
        suite.removePersistentDomain(forName: suiteName)
    }
    let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
    let module = MenuBarHiderModule(defaults: suite, autosaveSuffix: suffix, strategy: .systemOverflow,
                                    native: makeRevealDeps(vis, inv, running: { mbpRunning }, toggle: mbpToggle, timers: timers, probe: probe))
    let c = module.controller
    module.start()
    defer { module.stop() }
    guard waitUntil(3, { vis.requests.count == 1 }) else {
        check(false, "hide at launch requested")
        return
    }
    vis.succeed(0)
    timers.fireAll()
    let workspace = NSWorkspace.shared.notificationCenter
    func appActivated() { workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared) }

    c.expand()
    vis.succeed(1)
    check(c.nativeRevealPlan?.unfit == ["com.far"], "partial reveal (com.far kept hidden)")
    let seconds = c.secondsUntilCollapse

    // Another app comes to the front; its menus continue right of the notch.
    probe.strip = NativeStatusStrip(band: mbpBand, notchSideWidth: mbpNotchSide, menusMinX: 0, menusMaxX: 900)
    let probes = probe.requests.count
    appActivated()
    check(probe.requests.count == probes, "app switch: debounced, nothing read at once")
    check(waitUntil(2) { vis.requests.count == 3 }, "…then the room is re-read and com.mid hidden again")
    vis.succeed(2)
    check(c.nativeRevealPlan?.revealed == ["com.near", "com.gone"] && c.visibility == .expanded && vis.active.count == 1,
          "still shown, 2 apps revealed, one restriction")
    check(c.nativeRevealNote == "还有 2 个 App 的图标放不下（刘海右侧空间不足）", "note follows (\(c.nativeRevealNote ?? "nil"))")
    check(c.contextMenu().items.map(\.title).contains(MenuBarHiderController.showAllIconsTitle), "显示全部 still offered")
    check(c.secondsUntilCollapse.map { s in seconds.map { abs($0 - s) <= 2 } ?? false } == true, "the auto-hide deadline is not re-armed by re-checks")

    // A burst of app switches → one re-read (a real app switch on this Mac may add one).
    let burst = probe.requests.count
    for _ in 0..<5 { appActivated() }
    _ = waitUntil(1.2) { probe.requests.count > burst + 1 }
    check(probe.requests.count > burst && probe.requests.count - burst < 5, "5 app switches in a row → re-read once (\(probe.requests.count - burst))")
    check(vis.requests.count == 3, "…same room: nothing requested")

    // An app starts (an allowed one may add icons) → re-checked too.
    let launched = probe.requests.count
    workspace.post(name: NSWorkspace.didLaunchApplicationNotification, object: NSWorkspace.shared)
    check(waitUntil(2) { probe.requests.count > launched }, "app launched while shown → room re-read")

    // 显示全部: nothing held → nothing to re-check; the hotkey collapses from there.
    c.revealAllIcons()
    check(c.visibility == .expandedAll && vis.active.isEmpty && c.nativeRevealPlan == nil, "显示全部: everything released")
    let afterAll = probe.requests.count
    appActivated()
    _ = waitUntil(0.8) { probe.requests.count > afterAll }
    check(probe.requests.count == afterAll, "…app switch while everything is shown: no re-check")
    c.userToggle(revealAlwaysHidden: false)
    check(c.visibility == .collapsed && vis.requests.count == 4, "hotkey after 显示全部 → collapse requested")
    vis.succeed(3)
    timers.fireAll()
    check(c.contextMenu().items.map(\.title).contains(MenuBarHiderController.showAllIconsTitle), "collapsed after a partial reveal: 显示全部 offered")

    // The next expand shows everything (room unknown): nothing was held back any more.
    probe.strip = NativeStatusStrip(band: studioBand)
    c.expand()
    check(vis.active.isEmpty && c.nativeRevealPlan == nil && c.visibility == .expanded, "room unknown → everything shown")
    c.collapse()
    vis.succeed(4)
    timers.fireAll()
    check(!c.contextMenu().items.map(\.title).contains(MenuBarHiderController.showAllIconsTitle),
          "…collapsed again: 显示全部 no longer offered (the last expand held nothing back)")

    // A re-check pending when the module stops does nothing afterwards.
    probe.strip = mbpStrip
    c.expand()
    vis.succeed(5)
    check(c.nativeState == .revealed, "partial again")
    appActivated()
    module.stop()
    let stopped = probe.requests.count
    _ = waitUntil(0.8) { probe.requests.count > stopped }
    check(probe.requests.count == stopped && vis.active.isEmpty && !c.diagnostics().isInstalled,
          "stop: pending re-check cancelled, everything released, toggle removed")
}
