import AppKit
import OneSwitchCore
import MenuBarHider

// "Reveal what fits" (系统原生隐藏 on a crowded / notched bar). Everything runs against fakes: the real
// restriction is never activated here.

// MARK: - Fakes

/// The reveal probe (toggle's display + new apps' icons); answers at once unless `manual`.
@MainActor
final class FakeRevealProbe {
    var strip: NativeStatusStrip?
    /// Icons reported for the requested apps (filtered by bundle id); nil = unreadable (no 辅助功能).
    var icons: [MenuBarItemInfo]? = []
    /// The toggle's display could not be found.
    var answersNil = false
    var manual = false
    private(set) var requests: [NativeRevealProbeRequest] = []
    private var pending: [@MainActor () -> Void] = []

    init(strip: NativeStatusStrip?) { self.strip = strip }

    var probing: NativeRevealProbing {
        { [weak self] request, completion in
            guard let self else { return }
            self.requests.append(request)
            let answer: @MainActor () -> Void = { [weak self] in
                guard let self else { return }
                if self.answersNil {
                    completion(nil)
                    return
                }
                let items = self.icons.map { list in list.filter { $0.bundleID.map(request.bundleIDs.contains) ?? false } }
                completion(NativeRevealProbe(strip: self.strip, items: items))
            }
            if self.manual { self.pending.append(answer) } else { answer() }
        }
    }

    func deliverAll() {
        let calls = pending
        pending.removeAll()
        calls.forEach { $0() }
    }
}

/// Our own status items' frames (CG), changeable while a check runs.
@MainActor
final class FakeOwnItems {
    var frames: [CGRect]
    init(_ frames: [CGRect]) { self.frames = frames }
}

@MainActor
func makeRevealDeps(_ visibility: FakeVisibility, _ inventory: FakeInventory, running: @escaping () -> [String],
                    toggle: CGRect, timers: FakeTimers, probe: FakeRevealProbe?,
                    ownFrames: [CGRect]? = nil, own: FakeOwnItems? = nil) -> NativeHidingDependencies {
    let ownItemFrames: (@MainActor () -> [CGRect])? = own.map { box in { box.frames } } ?? ownFrames.map { frames in { frames } }
    return NativeHidingDependencies(visibility: visibility, inventory: inventory, runningBundleIDs: running,
                                    ownBundleIDs: [ownID], toggleFrame: { toggle }, schedule: timers.schedule,
                                    revealProbe: probe?.probing, ownItemFrames: ownItemFrames)
}

// MARK: - Test data: MacBook Pro 1512 pt, notch; 663 pt right of it → status items from x 849 (CG)

let mbpBand = CGRect(x: 0, y: 0, width: 1512, height: 37)
let mbpNotchSide: CGFloat = 663
let mbpToggle = CGRect(x: 1000, y: 0, width: 26, height: 37)
let mbpStrip = NativeStatusStrip(band: mbpBand, notchSideWidth: mbpNotchSide, menusMinX: 0, menusMaxX: 420)
let mbpRunning = ["com.near", "com.mid", "com.far", "com.gone", "com.right", "com.apple.TextInputMenuAgent", ownID]

/// Left of「<」(x 1000): com.near (1 icon, nearest), com.mid (1 wide text icon), com.far (2 icons);
/// com.gone was in the « (never laid out); right of「<」: com.right, the input menu, Wi‑Fi.
/// Room while collapsed: 1000 − 849 − 24 = 127 pt; costs: near 31, mid 47, far 62, gone 31.
func mbpInventory(chevron: CGRect? = nil) -> MenuBarInventory {
    MenuBarInventory(items: [
        barItem("com.far", x: 850, pid: 21),
        barItem("com.far", x: 876, pid: 21),
        barItem("com.mid", x: 900, w: 40, pid: 22),
        barItem("com.near", x: 960, pid: 23),
        barItem("com.gone", x: -1, y: 1068, pid: 24),
        barItem(ownID, x: 1040, pid: 7),
        barItem("com.right", x: 1100, pid: 25),
        barItem("com.apple.TextInputMenuAgent", x: 1300, w: 46, pid: 9, name: "TextInputMenuAgent"),
        barItem("com.apple.MenuBarAgent", x: 1400, pid: 8, name: "Wi‑Fi"),
    ], overflowChevron: chevron, bands: [mbpBand])
}

// MARK: - Pure pieces

@MainActor
func checkRevealGeometry() {
    print("系统原生隐藏 · reveal what fits: room on「<」's side")
    let notched = NativeStatusStrip(band: mbpBand, notchSideWidth: mbpNotchSide)
    check(notched.hasNotch && notched.innerBoundary(rightToLeft: false) == 849, "notch: status items start right of the camera housing (x 849)")
    check(NativeStatusStrip(band: mbpBand, notchSideWidth: mbpNotchSide, menusMinX: 0, menusMaxX: 900).innerBoundary(rightToLeft: false) == 908,
          "notch + app menus continuing right of it: the menus' end (+8 pt gap) limits")
    check(mbpStrip.innerBoundary(rightToLeft: false) == 849, "short menus left of the notch: the notch limits")
    let studio = NativeStatusStrip(band: studioBand, menusMinX: 0, menusMaxX: 600)
    check(!studio.hasNotch && studio.innerBoundary(rightToLeft: false) == 608, "no notch: end of the frontmost app's menus + gap")
    check(NativeStatusStrip(band: studioBand).innerBoundary(rightToLeft: false) == nil, "no notch, menus unreadable → room unknown")
    check(NativeStatusStrip(band: studioBand, notchSideWidth: 0, menusMaxX: 600).innerBoundary(rightToLeft: false) == 608,
          "a zero-width notch area counts as no notch")
    let rtl = NativeStatusStrip(band: mbpBand, notchSideWidth: mbpNotchSide, menusMinX: 1200, menusMaxX: 1500)
    check(rtl.innerBoundary(rightToLeft: true) == 663, "right-to-left: status items on the left, up to the camera housing")
    check(NativeStatusStrip(band: studioBand, menusMinX: 1300, menusMaxX: 1900).innerBoundary(rightToLeft: true) == 1292,
          "right-to-left, no notch: up to the start of the menus − gap")

    check(NativeRevealPlanner.availableRoom(strip: mbpStrip, innerEdge: 1000, rightToLeft: false) == 127,
          "room = inner edge of the shown icons − boundary − 24 pt margin (1000 − 849 − 24)")
    check(NativeRevealPlanner.availableRoom(strip: rtl, innerEdge: 500, rightToLeft: true) == 139, "right-to-left room (663 − 500 − 24)")
    check(NativeRevealPlanner.availableRoom(strip: NativeStatusStrip(band: studioBand), innerEdge: 1000, rightToLeft: false) == nil,
          "unknown boundary → unknown room")
    check((NativeRevealPlanner.availableRoom(strip: mbpStrip, innerEdge: 860, rightToLeft: false) ?? 1) < 0, "icons already reach the notch → negative room")

    // The inner edge of what is shown now: toggle, our own other items, the other apps' visible icons.
    let monitor = CGRect(x: 880, y: 0, width: 157, height: 37)
    check(NativeRevealPlanner.visibleInnerEdge(toggle: mbpToggle, ownItems: [], othersEdge: nil, band: mbpBand, rightToLeft: false) == 1000,
          "only「<」shown on its side → its left edge")
    check(NativeRevealPlanner.visibleInnerEdge(toggle: mbpToggle, ownItems: [monitor], othersEdge: 1100, band: mbpBand, rightToLeft: false) == 880,
          "系统监控 dragged left of「<」counts (x 880)")
    check(NativeRevealPlanner.visibleInnerEdge(toggle: mbpToggle, ownItems: [CGRect(x: 2000, y: 0, width: 30, height: 30)],
                                               othersEdge: 950, band: mbpBand, rightToLeft: false) == 950,
          "own item on another display ignored; other apps' visible icons count")
    check(NativeRevealPlanner.visibleInnerEdge(toggle: CGRect(x: 400, y: 0, width: 26, height: 37), ownItems: [CGRect(x: 430, y: 0, width: 150, height: 37)],
                                               othersEdge: 560, band: mbpBand, rightToLeft: true) == 580,
          "right-to-left: the rightmost shown edge")

    // The collapsed bar as read while restricted: only the allowed apps' frames are live.
    let collapsedRead = mbpInventory()
    let measured = NativeRevealPlanner.measureVisible(inventory: collapsedRead, visible: ["com.right", "com.apple.TextInputMenuAgent"],
                                                      toggle: mbpToggle, rightToLeft: false)
    check(measured.edge == 1100 && !measured.overflowed, "collapsed read: stale frames of hidden apps ignored, inner edge of the shown ones = 1100")
    let withLeft = NativeRevealPlanner.measureVisible(inventory: collapsedRead, visible: ["com.right", "com.mid"], toggle: mbpToggle, rightToLeft: false)
    check(withLeft.edge == 900, "an allowed app left of「<」(始终显示) moves the edge (900)")
    check(NativeRevealPlanner.measureVisible(inventory: mbpInventory(chevron: CGRect(x: 860, y: 5, width: 20, height: 27)), visible: ["com.right"],
                                             toggle: mbpToggle, rightToLeft: false).overflowed,
          "« shown while collapsed → no room at all")

    // After a partial reveal settled.
    check(!NativeRevealPlanner.revealOverflowed(inventory: mbpInventory(), toggle: mbpToggle), "revealed bar without «: fine")
    check(NativeRevealPlanner.revealOverflowed(inventory: mbpInventory(chevron: CGRect(x: 860, y: 5, width: 20, height: 27)), toggle: mbpToggle),
          "« on「<」's display → overflowed")
    check(!NativeRevealPlanner.revealOverflowed(inventory: MenuBarInventory(items: [], overflowChevron: CGRect(x: 1700, y: 5, width: 20, height: 27),
                                                                           bands: [mbpBand, CGRect(x: 1512, y: 0, width: 1920, height: 30)]),
                                                toggle: mbpToggle),
          "« on another display → not ours")
    check(NativeRevealPlanner.revealOverflowed(inventory: mbpInventory(), toggle: CGRect(x: 0, y: 1068, width: 26, height: 30)),
          "「<」pushed out of the bar → overflowed")
    check(NativeRevealPlanner.revealOverflowed(inventory: mbpInventory(), toggle: nil), "「<」frame unreadable after a reveal → counted as dropped")
}

@MainActor
func checkRevealPlanner() {
    print("系统原生隐藏 · reveal what fits: widths, order, fit")
    typealias R = NativeRevealPlanner
    func c(_ id: String, count: Int = 1, width: CGFloat? = 24, edge: CGFloat? = nil, known: Bool = true) -> NativeRevealCandidate {
        NativeRevealCandidate(bundleID: id, name: id, itemCount: count, width: width, edgeDistance: edge, known: known)
    }
    check(R.cost(of: c("a")) == 31, "one 24 pt icon + 7 pt spacing = 31")
    check(R.cost(of: c("m", count: 3, width: 90)) == 111, "multi-icon app: sum of its icons + one spacing each (90 + 21)")
    check(R.cost(of: c("u", count: 2, width: nil)) == 74, "unknown width: 30 pt per icon (+ spacing): 2 × 37")
    check(R.usableWidth(0) == 30 && R.usableWidth(3000) == 30 && R.usableWidth(97) == 97, "implausible reported widths → 30 pt")

    let ordered = R.ordered([c("z.noedge"), c("far", edge: 300), c("unknown", width: nil, known: false), c("near", edge: 100),
                             c("a.noedge"), c("mid", edge: 200)]).map(\.bundleID)
    check(ordered == ["near", "mid", "far", "a.noedge", "z.noedge", "unknown"],
          "order: nearest to「<」first (by last laid-out position), then never laid out by name, unknown last (\(ordered))")

    // Exact boundary.
    let two = [c("a", edge: 10), c("b", width: 40, edge: 20)] // 31 + 47 = 78
    check(R.plan(candidates: two, available: 78, notched: true).allFit, "exact fit (78 of 78 pt) → everything fits")
    let tight = R.plan(candidates: two, available: 77.5, notched: true)
    check(tight.revealed == ["a"] && tight.unfit == ["b"] && tight.used == 31, "half a point short → the farther app stays hidden")
    check(R.plan(candidates: two, available: -5, notched: false).revealed.isEmpty, "no room → nothing revealed")
    check(R.plan(candidates: [], available: 0, notched: false).allFit, "nothing hidden → all fit")

    // Skip what does not fit, keep filling (a big text item must not block the small ones behind it).
    let skip = R.plan(candidates: [c("big", width: 150, edge: 10), c("small", edge: 20)], available: 100, notched: true)
    check(skip.revealed == ["small"] && skip.unfit == ["big"], "an app that does not fit is skipped, smaller ones further on still fit")

    // Unknown apps only with room to spare, never counted as "does not fit".
    let unknown = R.plan(candidates: [c("known", edge: 10), c("new", width: nil, known: false)], available: 50, notched: true)
    check(unknown.revealed == ["known"] && unknown.unfit.isEmpty && unknown.withheld == ["new"] && !unknown.allFit,
          "unknown new app without room: withheld, not reported as unfit")
    check(R.plan(candidates: [c("known", edge: 10), c("new", width: nil, known: false)], available: 68, notched: true).allFit,
          "…and revealed when there is room for 30 pt per icon")

    let dropped = R.plan(candidates: [c("a", edge: 1), c("b", edge: 2), c("x", width: 200, edge: 3)], available: 70, notched: true).droppingLast()
    check(dropped.revealed == ["a"] && dropped.unfit == ["b", "x"] && dropped.used == 31, "hiding the farthest revealed app again")

    // Metrics from reads.
    var metrics: [String: NativeAppMetrics] = [:]
    NativeMetricsRecorder.record(sampleInventory(), into: &metrics, trusted: nil, ownBundleIDs: [ownID], rightToLeft: false)
    check(metrics["com.split"] == NativeAppMetrics(itemCount: 2, width: 48, edgeDistance: 446),
          "multi-icon app: count 2, widths summed, distance of its icon nearest to the edge (1920 − 1474)")
    check(metrics["com.parked"]?.itemCount == 2 && metrics["com.parked"]?.edgeDistance == nil && metrics["com.parked"]?.width == 48,
          "parked icons: width known, never a position")
    check(metrics["com.overflow"]?.width == 40 && metrics["com.overflow"]?.edgeDistance == nil, "overflowed icon (y 1068) reports its width")
    check(metrics[ownID] == nil && metrics["com.apple.MenuBarAgent"] == nil && metrics["pid77"] == nil,
          "own app, macOS's item owners and processes without a bundle id are not recorded")
    // A restricted read: hidden apps keep what was measured while visible.
    var moved = sampleInventory()
    moved.items = moved.items.map { var i = $0; if i.bundleID == "com.left" { i.frame.origin.x = 1800 }; return i }
    moved.items.append(barItem("com.left2", x: 1810, pid: 2))
    NativeMetricsRecorder.record(moved, into: &metrics, trusted: ["com.right"], ownBundleIDs: [ownID], rightToLeft: false)
    check(metrics["com.left"]?.edgeDistance == 1920 - 1124, "hidden app's stale frame never moves its position")
    check(metrics["com.left2"]?.itemCount == 2 && metrics["com.left2"]?.width == 48 && metrics["com.left2"]?.edgeDistance == 1920 - 1204,
          "hidden app with a new icon: count and width updated, position kept")

    // Estimated edge of the collapsed bar when it was not measured yet.
    let layout = NativeLayoutResolver.resolve(inventory: mbpInventory(), toggle: mbpToggle, ownBundleIDs: [ownID])
    check(NativeRevealPlanner.estimatedOthersEdge(toggle: mbpToggle, layout: layout, allowed: ["com.right"], metrics: [:], rightToLeft: false) == nil,
          "estimate: only right-side apps shown → nothing beyond「<」")
    check(NativeRevealPlanner.estimatedOthersEdge(toggle: mbpToggle, layout: layout, allowed: ["com.right", "com.mid"],
                                                  metrics: ["com.mid": NativeAppMetrics(itemCount: 1, width: 40)], rightToLeft: false) == 953,
          "estimate: an allowed app beyond「<」takes its measured room (1000 − 47)")

    // Candidates.
    let base = NativeHidingPlan(allowed: [ownID, "com.right"], hidden: ["com.near", "com.far"])
    let cands = R.candidates(base: base, layout: layout,
                             metrics: ["com.near": NativeAppMetrics(itemCount: 1, width: 24, edgeDistance: 528),
                                       "com.new.icon": NativeAppMetrics(itemCount: 1, width: 24),
                                       "com.new.plain": NativeAppMetrics(itemCount: 1, width: 24)],
                             newApps: ["com.new.icon", "com.new.plain"], newAppsWithIcons: ["com.new.icon"])
    check(cands.map(\.bundleID) == ["com.near", "com.far", "com.new.icon"],
          "new app with icons (read just now) is a candidate; one read without icons is not, whatever was known (\(cands.map(\.bundleID)))")
    check(cands.first { $0.bundleID == "com.far" }.map { $0.itemCount == 2 && $0.width == nil && $0.known } == true,
          "hidden app without metrics: icon count from the layout, width unknown")
    let unreadable = R.candidates(base: base, layout: layout, metrics: [:], newApps: ["com.new.plain"], newAppsWithIcons: nil)
    check(unreadable.last.map { $0.bundleID == "com.new.plain" && !$0.known } == true, "new app, icons unreadable → unknown candidate")
}

// MARK: - Engine with fakes

@MainActor
func checkRevealEngine() {
    print("系统原生隐藏 · reveal what fits: engine (fake restriction, probe, timers)")

    /// Collapsed and measured, ready to expand.
    func collapsedEngine(_ vis: FakeVisibility, _ inv: FakeInventory, _ timers: FakeTimers, _ probe: FakeRevealProbe?,
                         running: [String] = mbpRunning, toggle: CGRect = mbpToggle,
                         measure: Bool = true) -> (NativeVisibilityEngine, FakeAssertion) {
        let engine = NativeVisibilityEngine(dependencies: makeRevealDeps(vis, inv, running: { running }, toggle: toggle,
                                                                         timers: timers, probe: probe)) { nil }
        engine.collapse(rules: [:]) { _ in }
        let held = vis.succeed(vis.requests.count - 1)
        if measure { timers.fireAll() }
        return (engine, held)
    }

    // 1. MacBook Pro: only what fits right of the notch; replace, then drop.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let (engine, collapsed) = collapsedEngine(vis, inv, timers, probe)
        check(inv.snapshots == 2 && engine.state == .collapsed, "the collapsed bar is measured once after the grant")
        var outcomes: [NativeVisibilityEngine.RevealOutcome] = []
        engine.reveal { outcomes.append($0) }
        check(probe.requests.count == 1 && probe.requests[0].toggle == mbpToggle && probe.requests[0].bundleIDs.isEmpty,
              "expand reads the room on「<」's display (no new apps to read)")
        check(vis.requests.count == 2 && engine.state == .activating && outcomes.isEmpty, "not everything fits → a reveal restriction is requested")
        let base = Set(vis.requests[0].bundles)
        check(Set(vis.requests[1].bundles) == base.union(["com.near", "com.mid", "com.gone"]) && !vis.requests[1].bundles.contains("com.far"),
              "allowed = collapsed allow-list + the apps that fit (com.far's 2 icons do not)")
        check(vis.requests[1].systemItems == Array(0..<64) && vis.requests[1].bundles.contains(ownID), "system items and OneSwitch stay allowed")
        check(!collapsed.isInvalidated && engine.isRestricted, "collapsed restriction kept while the reveal is pending (no flash)")
        var droppedAfterGrant = false
        collapsed.onInvalidate = { droppedAfterGrant = vis.granted.count == 2 }
        let revealed = vis.succeed(1)
        check(collapsed.isInvalidated && droppedAfterGrant && !revealed.isInvalidated && vis.active.count == 1,
              "…granted: new restriction held, then the collapsed one dropped (replace, then drop)")
        check(engine.state == .revealed && engine.isRestricted && engine.activeReveal != nil, "state: revealed (restricted)")
        if case .partial(let plan)? = outcomes.first {
            check(plan.revealed == ["com.near", "com.mid", "com.gone"] && plan.unfit == ["com.far"] && plan.notched,
                  "nearest first; com.far does not fit, com.gone (never laid out) still does (\(plan.revealed) / \(plan.unfit))")
            check(plan.available == 127 && plan.used == 109, "room 127 pt, used 31 + 47 + 31 = 109 pt")
        } else {
            check(false, "outcome is .partial (\(outcomes))")
        }

        // 2. The bar overflowed after all (widths were off): the farthest revealed app is hidden again.
        inv.inventory = mbpInventory(chevron: CGRect(x: 860, y: 5, width: 20, height: 27))
        var updates: [NativeVisibilityEngine.RevealOutcome] = []
        engine.onRevealUpdate = { updates.append($0) }
        timers.fireAll()
        check(vis.requests.count == 3 && Set(vis.requests[2].bundles) == base.union(["com.near", "com.mid"]),
              "« appeared after the reveal → re-requested without the farthest app (com.gone)")
        check(!revealed.isInvalidated, "…the shown restriction is kept until the smaller one is granted")
        let smaller = vis.succeed(2)
        check(revealed.isInvalidated && !smaller.isInvalidated && vis.active.count == 1, "…then replaced")
        if case .partial(let plan)? = updates.first {
            check(plan.revealed == ["com.near", "com.mid"] && plan.unfit == ["com.gone", "com.far"] && engine.activeReveal == plan,
                  "update reported: 2 revealed, 2 kept hidden")
        } else {
            check(false, "reveal update reported")
        }
        inv.inventory = mbpInventory()
        timers.fireAll()
        check(vis.requests.count == 3, "no « any more → nothing else changes")

        // 3. Collapse from the partial reveal: only the shown apps are re-read.
        var moved = mbpInventory()
        moved.items = moved.items.map { item in
            var item = item
            if item.bundleID == "com.near" { item.frame.origin.x = 1050 }   // ⌘-dragged right of「<」while shown
            if item.bundleID == "com.far" { item.frame.origin.x = 1060 }    // hidden: stale frame, must be ignored
            return item
        }
        moved.items.append(barItem("com.new", x: -1, y: 1068, pid: 26))    // started during the reveal, hidden
        inv.inventory = moved
        let snapshots = inv.snapshots
        var collapseOutcome: NativeVisibilityEngine.Outcome?
        engine.collapse(rules: [:]) { collapseOutcome = $0 }
        check(inv.snapshots == snapshots + 1, "collapse from a partial reveal re-reads the bar")
        let layout = engine.layout
        check(layout?.placement(ofBundle: "com.near") == .rightOfToggle, "shown app dragged right of「<」→ stays visible")
        check(layout?.placement(ofBundle: "com.mid") == .leftOfToggle, "shown app still left of「<」→ hidden")
        check(layout?.placement(ofBundle: "com.far") == .leftOfToggle, "hidden app keeps its last known place (stale frame ignored)")
        check(layout?.placement(ofBundle: "com.new") == .overflow, "app that never got room → 在系统「«」中或未显示")
        check(vis.requests.count == 4 && vis.requests[3].bundles.contains("com.near")
              && !vis.requests[3].bundles.contains("com.mid") && !vis.requests[3].bundles.contains("com.far"),
              "collapse allow-list from the new placements")
        check(!smaller.isInvalidated, "the reveal restriction stays until the collapse is granted")
        let recollapsed = vis.succeed(3)
        check(smaller.isInvalidated && !recollapsed.isInvalidated && vis.active.count == 1 && engine.state == .collapsed
              && engine.activeReveal == nil, "…then dropped (replace, then drop)")
        if case .collapsed? = collapseOutcome {} else { check(false, "collapse reported") }
        engine.releaseAll()
        check(vis.active.isEmpty, "released")
    }

    // 4. Studio: plenty of room → exactly as before (no extra restriction, released at once).
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory()), timers = FakeTimers()
        let probe = FakeRevealProbe(strip: NativeStatusStrip(band: studioBand, menusMinX: 0, menusMaxX: 600))
        let running = ["com.left", "com.left2", "com.right", "com.split", "com.idle"]
        for measure in [true, false] {
            let (engine, collapsed) = collapsedEngine(vis, inv, timers, probe, running: running, toggle: toggleCG, measure: measure)
            let before = vis.requests.count
            var outcome: NativeVisibilityEngine.RevealOutcome?
            engine.reveal { outcome = $0 }
            check(vis.requests.count == before && collapsed.isInvalidated && vis.active.isEmpty && !engine.isRestricted
                  && engine.state == .expanded, "Studio (\(measure ? "measured" : "estimated") room): nothing new requested, restriction released")
            if case .all(let plan?)? = outcome {
                check(plan.allFit && plan.unfit.isEmpty && plan.available > plan.used, "…every hidden app fits (\(Int(plan.used)) of \(Int(plan.available)) pt)")
            } else {
                check(false, "Studio outcome is .all with a plan (\(String(describing: outcome)))")
            }
        }
    }

    // 5. Room cannot be told → everything (current behaviour).
    do {
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers()
        let noMenus = FakeRevealProbe(strip: NativeStatusStrip(band: studioBand))
        var (engine, collapsed) = collapsedEngine(vis, inv, timers, noMenus)
        var outcome: NativeVisibilityEngine.RevealOutcome?
        engine.reveal { outcome = $0 }
        check(outcome == .all(nil) && collapsed.isInvalidated && vis.active.isEmpty && vis.requests.count == 1,
              "no notch and the app menus unreadable → released (everything shown)")
        let lost = FakeRevealProbe(strip: nil)
        (engine, collapsed) = collapsedEngine(vis, inv, timers, lost)
        engine.reveal { outcome = $0 }
        check(outcome == .all(nil) && collapsed.isInvalidated && vis.active.isEmpty, "toggle's display not found → released")
        (engine, collapsed) = collapsedEngine(vis, inv, timers, nil)
        engine.reveal { outcome = $0 }
        check(outcome == .all(nil) && collapsed.isInvalidated, "no probe wired in → released")
    }

    // 6. Fail open: the reveal activation fails → everything shown.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let (engine, collapsed) = collapsedEngine(vis, inv, timers, probe)
        var outcome: NativeVisibilityEngine.RevealOutcome?
        engine.reveal { outcome = $0 }
        vis.fail(1)
        check(collapsed.isInvalidated && vis.active.isEmpty && !engine.isRestricted && engine.state == .expanded,
              "reveal activation error → every restriction released (all icons visible)")
        if case .failed(let reason)? = outcome { check(reason.contains("fake activation failure"), "reported with its reason") } else {
            check(false, "failure reported")
        }
    }

    // 7. A probe that never answers fails open; its late answer is ignored.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let (engine, collapsed) = collapsedEngine(vis, inv, timers, probe)
        probe.manual = true
        var outcome: NativeVisibilityEngine.RevealOutcome?
        engine.reveal { outcome = $0 }
        check(engine.state == .activating && !collapsed.isInvalidated, "probe pending: still collapsed")
        timers.fireAll()
        if case .failed(let reason)? = outcome {
            check(reason.contains("timed out") && collapsed.isInvalidated && vis.active.isEmpty, "probe timeout → everything shown (\(reason))")
        } else {
            check(false, "probe timeout reported")
        }
        probe.deliverAll()
        check(vis.requests.count == 1 && vis.active.isEmpty, "late probe answer requests nothing")
    }

    // 8. The reveal activation never answers.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let (engine, collapsed) = collapsedEngine(vis, inv, timers, probe)
        var outcome: NativeVisibilityEngine.RevealOutcome?
        engine.reveal { outcome = $0 }
        timers.fireAll()
        if case .failed? = outcome { check(collapsed.isInvalidated && vis.active.isEmpty, "reveal activation timeout → everything shown") } else {
            check(false, "reveal activation timeout reported")
        }
        let late = vis.succeed(1)
        check(late.isInvalidated && vis.active.isEmpty, "late reveal grant invalidated")
    }

    // 9. Superseded reveals.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let (engine, collapsed) = collapsedEngine(vis, inv, timers, probe)
        probe.manual = true
        var revealOutcomes = 0
        engine.reveal { _ in revealOutcomes += 1 }
        engine.collapse(rules: [:]) { _ in }        // clicked again before the room was read
        probe.deliverAll()
        check(revealOutcomes == 0 && vis.requests.count == 2 && Set(vis.requests[1].bundles) == Set(vis.requests[0].bundles),
              "collapse while the room is read: the reveal is dropped, the collapse re-applies the same allow-list")
        let again = vis.succeed(1)
        check(collapsed.isInvalidated && !again.isInvalidated && vis.active.count == 1 && engine.state == .collapsed, "one restriction, collapsed")
        probe.manual = false
        engine.reveal { _ in revealOutcomes += 1 }
        engine.expand()                             // 显示全部 while the reveal is pending
        let late = vis.succeed(2)
        check(late.isInvalidated && vis.active.isEmpty && revealOutcomes == 0, "expand while the reveal is pending: late grant invalidated")
    }

    // 10. The collapsed bar already shows « → nothing fits: nothing is requested — the held restriction
    //     already shows exactly that, and a request that failed would fail open into the overflow.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory(chevron: CGRect(x: 860, y: 5, width: 20, height: 27)))
        let timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let (engine, collapsed) = collapsedEngine(vis, inv, timers, probe)
        var outcome: NativeVisibilityEngine.RevealOutcome?
        engine.reveal { outcome = $0 }
        check(vis.requests.count == 1 && !collapsed.isInvalidated && engine.isRestricted && engine.state == .revealed,
              "« already there while collapsed → no new request, the collapsed restriction is kept")
        if case .partial(let plan)? = outcome {
            check(plan.revealed.isEmpty && plan.unfit.count == 4, "…nothing revealed, all 4 reported as not fitting")
        } else {
            check(false, "partial outcome with nothing revealed")
        }
        let snapshots = inv.snapshots
        timers.fireAll()
        check(inv.snapshots == snapshots && vis.requests.count == 1, "…nothing revealed → no settle checks")
        engine.collapse(rules: [:]) { _ in }
        check(vis.requests.count == 2 && inv.snapshots == snapshots + 1, "collapse from there re-reads the shown apps and re-applies")
        vis.succeed(1)
        check(collapsed.isInvalidated && vis.active.count == 1 && engine.state == .collapsed, "…one restriction, collapsed")
        engine.releaseAll()
    }

    // 11. Apps started since the collapse: their icons are read at expand time.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        var running = mbpRunning
        let engine = NativeVisibilityEngine(dependencies: makeRevealDeps(vis, inv, running: { running }, toggle: mbpToggle,
                                                                         timers: timers, probe: probe)) { nil }
        engine.collapse(rules: [:]) { _ in }
        vis.succeed(0)
        timers.fireAll()
        running += ["com.fresh", "com.plain"]
        probe.icons = [barItem("com.fresh", x: -1, y: 1068, pid: 30)]
        var outcome: NativeVisibilityEngine.RevealOutcome?
        engine.reveal { outcome = $0 }
        check(probe.requests.last?.bundleIDs == ["com.fresh", "com.plain"], "new apps' icons are read with the room")
        check(vis.requests.count == 2 && vis.requests[1].bundles.contains("com.fresh") && !vis.requests[1].bundles.contains("com.plain"),
              "new app with an icon revealed when it fits; the one without icons is not allowed")
        vis.succeed(1)
        if case .partial(let plan)? = outcome {
            check(plan.revealed == ["com.near", "com.mid", "com.fresh"] && plan.unfit == ["com.far", "com.gone"] && plan.withheld.isEmpty,
                  "new app with an icon is a normal candidate (by name after the placed ones); one without icons is none (\(plan.revealed))")
        } else {
            check(false, "partial outcome for new apps (\(String(describing: outcome)))")
        }
        // Icons unreadable (no 辅助功能): the new apps are unknown — only with room to spare, never counted.
        engine.collapse(rules: [:]) { _ in }
        vis.succeed(vis.requests.count - 1)
        running += ["com.unread"]
        probe.icons = nil
        outcome = nil
        engine.reveal { outcome = $0 }
        vis.succeed(vis.requests.count - 1)
        if case .partial(let plan)? = outcome {
            check(plan.withheld == ["com.unread"] && !plan.unfit.contains("com.unread"), "unreadable new app withheld, not reported as unfit")
        } else {
            check(false, "partial outcome with an unreadable new app (\(String(describing: outcome)))")
        }
        engine.releaseAll()
        check(vis.active.isEmpty, "released")
    }

    // 12. macOS reflows late: the « shows up only after the first settle check — the second one catches it.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(mbpInventory()), timers = FakeTimers(), probe = FakeRevealProbe(strip: mbpStrip)
        let (engine, _) = collapsedEngine(vis, inv, timers, probe)
        engine.reveal { _ in }
        vis.succeed(1)
        timers.fireAll()
        check(vis.requests.count == 2 && inv.snapshots == 3, "first settle check: bar fine, nothing changes")
        inv.inventory = mbpInventory(chevron: CGRect(x: 860, y: 5, width: 20, height: 27))
        timers.fireAll()
        check(vis.requests.count == 3 && !vis.requests[2].bundles.contains("com.gone") && vis.requests[2].bundles.contains("com.mid"),
              "late « caught by the second check → the farthest revealed app hidden again")
        vis.succeed(2)
        inv.inventory = mbpInventory()
        for _ in 0..<3 { timers.fireAll() }
        check(vis.requests.count == 3 && vis.active.count == 1 && engine.state == .revealed, "checks stop once the bar stayed fine twice")
        engine.releaseAll()
        check(vis.active.isEmpty, "released")
    }
}

// MARK: - Controller with fakes (notched MacBook Pro)

@MainActor
func checkRevealController() {
    print("系统原生隐藏 · reveal what fits: controller, menu, 显示全部图标 (fake restriction; real toggle item, removed again)")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let suiteName = "oneswitch.menubarhidercheck.reveal"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    let suffix = "-selfcheck-reveal"
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
    timers.fireAll() // the collapsed bar is measured
    // Our own items (系统监控, main icon…) are found through the app's status-bar windows (real toggle here).
    softFailures = sessionLocked
    if let frame = c.diagnostics().toggleFrame, let primaryMaxY = NSScreen.screens.first?.frame.maxY {
        let cg = MenuBarGeometry.toCG(frame, primaryMaxY: primaryMaxY)
        check(NativeRevealProbeReader.ownStatusItemFrames().contains(cg),
              "own status items found through the app's windows (this check's「<」at x \(Int(cg.minX)))")
    } else {
        print("  (toggle not laid out — own-items probe skipped)")
    }
    softFailures = false
    let showAll = MenuBarHiderController.showAllIconsTitle
    check(showAll == "显示全部图标（使用系统「«」）", "action title")
    check(!c.contextMenu().items.map(\.title).contains(showAll), "no 显示全部 before anything was held back")

    // Expand (click / menu / hotkey) → only what fits.
    c.expand()
    check(probe.requests.count == 1 && vis.requests.count == 2 && c.visibility == .expanded, "expand reads the room and requests a reveal")
    check(c.stateText.hasPrefix("图标已显示"), "state: shown (\(c.stateText))")
    vis.succeed(1)
    check(c.nativeState == .revealed && c.diagnostics().nativeRestricted && c.nativeRevealPlan?.unfit == ["com.far"],
          "partial reveal held (com.far kept hidden)")
    let note = "还有 1 个 App 的图标放不下（刘海右侧空间不足）"
    check(c.nativeRevealNote == note, "note: \(c.nativeRevealNote ?? "nil")")
    let menu = module.menuItems()
    check(menu.map(\.title).contains(note) && menu.map(\.title).contains(showAll), "main menu: note + 显示全部图标（使用系统「«」）")
    let context = c.contextMenu().items.map(\.title)
    check(context.contains(note) && context.contains(showAll), "right-click menu: note + the same action")
    check(c.secondsUntilCollapse.map { $0 >= 9 && $0 <= 10 } == true, "auto-hide armed as usual")
    check(MenuBarHiderController.revealNote(unfit: 3, notched: false) == "还有 3 个 App 的图标放不下（菜单栏空间不足）",
          "no notch: 菜单栏空间不足")
    if let path = ProcessInfo.processInfo.environment["MENUBAR_RENDER_REVEAL"] {
        renderSettings(module, to: path) // opt-in visual check of the page while icons are held back
    }

    // 显示全部图标 (the menu item itself) → restriction released entirely, auto-hide for the same period.
    if let item = menu.first(where: { $0.title == showAll }), let action = item.action {
        _ = (item.target as AnyObject?)?.perform(action, with: item)
    } else {
        check(false, "show-all menu item has an action")
    }
    check(c.visibility == .expandedAll && vis.active.isEmpty && !c.diagnostics().nativeRestricted && c.nativeRevealPlan == nil,
          "显示全部图标: every restriction released (macOS puts what does not fit into its «)")
    check(vis.requests.count == 2, "…nothing new requested")
    check(c.secondsUntilCollapse.map { $0 >= 9 && $0 <= 10 } == true && c.nativeRevealNote == nil
          && !module.menuItems().map(\.title).contains(showAll), "…auto-hides after the same delay; no note any more")

    // What the auto-hide does after the delay: collapse from the unrestricted bar (fresh positions).
    let snapshots = inv.snapshots
    c.collapse()
    check(inv.snapshots == snapshots + 1 && vis.requests.count == 3 && c.visibility == .collapsed,
          "auto-collapse after 显示全部: positions re-read, hiding requested")
    vis.succeed(2)
    check(vis.active.count == 1 && c.nativeState == .collapsed, "collapsed again")
    check(c.contextMenu().items.map(\.title).contains(showAll), "right-click menu keeps offering 显示全部 while collapsed (last reveal was partial)")
    timers.fireAll()

    // Hotkey path → partial again; collapse from it re-reads the shown apps.
    c.userToggle(revealAlwaysHidden: false)
    check(vis.requests.count == 4 && c.visibility == .expanded, "hotkey → reveal requested")
    vis.succeed(3)
    check(c.nativeRevealPlan != nil && vis.active.count == 1, "partial again")
    let before = inv.snapshots
    c.userToggle(revealAlwaysHidden: false)
    check(inv.snapshots == before + 1 && vis.requests.count == 5 && vis.active.count == 1, "hotkey → collapse re-reads the shown apps; reveal kept until granted")
    vis.succeed(4)
    check(vis.active.count == 1 && c.visibility == .collapsed && c.nativeRevealPlan == nil, "collapsed, one restriction")
    timers.fireAll()

    // Fail open during expand: everything shown, still 系统原生隐藏, not counted toward 兼容模式 — a collapse
    // failure right after it is only the first counted one (two in a row would switch to 兼容模式).
    var r = vis.requests.count
    c.expand()
    vis.fail(r)
    check(vis.active.isEmpty && !c.diagnostics().nativeRestricted && c.visibility == .expanded && c.nativeState == .expanded
          && c.nativeRevealPlan == nil, "reveal activation failure: every icon shown, still expanded")
    check(c.engineKind == .native, "…still 系统原生隐藏")
    c.collapse()
    check(vis.requests.count == r + 2, "collapse requested")
    vis.fail(r + 1)
    check(waitUntil(1) { c.visibility == .expanded } && c.engineKind == .native,
          "a collapse failure right after it stays 系统原生隐藏: the reveal failure was not counted")
    c.collapse()
    vis.succeed(r + 2)
    timers.fireAll()
    check(vis.active.count == 1 && c.visibility == .collapsed, "collapsed again")

    // Studio-like room: behaves exactly as before.
    probe.strip = NativeStatusStrip(band: CGRect(x: 0, y: 0, width: 3000, height: 37), menusMinX: 0, menusMaxX: 300)
    r = vis.requests.count
    c.expand()
    check(vis.requests.count == r && vis.active.isEmpty && c.nativeRevealPlan == nil && c.nativeRevealNote == nil,
          "plenty of room: restriction simply released, nothing new requested, no note")
    c.collapse()
    vis.succeed(r)
    check(!c.contextMenu().items.map(\.title).contains(showAll), "everything fit last time → no 显示全部 in the right-click menu")

    module.stop()
    check(vis.active.isEmpty && !c.diagnostics().isInstalled, "stop releases everything")
}

// MARK: - Live, read-only: the real room reader on this Mac (no restriction is activated)

@MainActor
func probeRevealRoom() {
    print("Read-only probe: room for revealed icons on this Mac (informational; nothing is activated)")
    softFailures = sessionLocked
    defer { softFailures = false }
    guard Permissions.isGranted(.accessibility) else {
        print("  (辅助功能 not granted — skipped)")
        return
    }
    let screens = ScreenGeometry.current()
    let bands = MenuBarGeometry.menuBarBands(screens: screens, thickness: NSStatusBar.system.thickness)
    let apps = RunningAppInfo.current()
    var scanned: MenuBarScanResult?
    DispatchQueue.global(qos: .userInitiated).async {
        let r = MenuBarItemScanner.scan(apps: apps, excludingPID: getpid(), bands: bands)
        DispatchQueue.main.async { scanned = r }
    }
    guard waitUntil(15, { scanned != nil }), let scan = scanned else {
        print("  (scan did not finish — skipped)")
        return
    }
    let own = AppEnvironment.bundleIdentifier
    guard let toggle = scan.items.first(where: { $0.bundleID == own && ($0.detail ?? "").contains("菜单栏图标") })?.frame else {
        print("  (no running OneSwitch「<」in the bar — skipped)")
        return
    }
    var answer: NativeRevealProbe??
    let started = Date()
    NativeRevealProbeReader.read(NativeRevealProbeRequest(toggle: toggle, bundleIDs: [], rightToLeft: false)) { answer = .some($0) }
    guard waitUntil(3, { answer != nil }), let probe = answer ?? nil, let strip = probe.strip else {
        check(false, "the real reader finds the display of the running「<」")
        return
    }
    let ms = Int(Date().timeIntervalSince(started) * 1000)
    check(strip.band.contains(CGPoint(x: toggle.midX, y: strip.band.midY)), "the real reader finds「<」's display (\(ms) ms)")
    print("  display x \(Int(strip.band.minX))…\(Int(strip.band.maxX)), notch side: \(strip.notchSideWidth.map { "\(Int($0)) pt" } ?? "none"), "
          + "other notched displays: \(strip.otherNotchSides.isEmpty ? "none" : strip.otherNotchSides.map { "\(Int($0)) pt" }.joined(separator: ", ")), "
          + "frontmost menus: \(strip.menusMaxX.map { "…\(Int($0))" } ?? "unreadable") → room starts at "
          + "\(strip.innerBoundary(rightToLeft: false).map { "x \(Int($0))" } ?? "unknown")")
    print("  own status items seen by this process: \(NativeRevealProbeReader.ownStatusItemFrames().count)")

    // What the running OneSwitch would do on its next expand (its hidden apps, their real widths).
    let inventory = MenuBarInventory(items: scan.items, overflowChevron: scan.overflowChevron, bands: bands)
    let layout = NativeLayoutResolver.resolve(inventory: inventory, toggle: toggle, ownBundleIDs: [own])
    var metrics: [String: NativeAppMetrics] = [:]
    NativeMetricsRecorder.record(inventory, into: &metrics, trusted: nil, ownBundleIDs: [own], rightToLeft: false)
    let hidden = layout.apps.filter { $0.bundleID != nil && NativeHidingPlan.shouldHide(rule: .auto, placement: $0.placement) }.compactMap(\.bundleID)
    let shown = Set(scan.items.compactMap(\.bundleID)).subtracting(hidden)
    let measured = NativeRevealPlanner.measureVisible(inventory: inventory, visible: shown, toggle: toggle, rightToLeft: false)
    let edge = NativeRevealPlanner.visibleInnerEdge(toggle: toggle, ownItems: [], othersEdge: measured.edge, band: strip.band, rightToLeft: false)
    guard let room = NativeRevealPlanner.availableRoom(strip: strip, innerEdge: edge, rightToLeft: false) else {
        print("  room unknown → the running app would show everything (as before)")
        return
    }
    let candidates = NativeRevealPlanner.candidates(base: NativeHidingPlan(allowed: [], hidden: hidden), layout: layout, metrics: metrics,
                                                    newApps: [], newAppsWithIcons: [])
    let plan = NativeRevealPlanner.plan(candidates: candidates, available: room, notched: strip.hasNotch)
    let need = candidates.reduce(CGFloat(0)) { $0 + NativeRevealPlanner.cost(of: $1) }
    print("  \(hidden.count) hidden app(s) need \(Int(need)) pt; room \(Int(room)) pt (icons shown from x \(Int(edge))"
          + (measured.overflowed ? ", « shown" : "") + ") → "
          + (plan.allFit ? "all fit: released exactly as before" : "partial: \(plan.revealed.count) shown, \(plan.unfit.count) kept hidden"))
}
