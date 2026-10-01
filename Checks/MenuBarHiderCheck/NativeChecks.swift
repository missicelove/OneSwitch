import AppKit
import SwiftUI
import OneSwitchCore
import MenuBarHider

// 系统原生隐藏 (macOS 27+) checks. Everything here runs against fakes — the real restriction is only
// touched by `checkNativeLiveProbe` (allow-all, invalidated on arrival, skipped while locked).

// MARK: - Fakes

final class FakeAssertion: NativeVisibilityAssertion {
    let allowed: [String]
    private(set) var invalidations = 0
    var onInvalidate: (() -> Void)?

    init(allowed: [String]) { self.allowed = allowed }

    var isInvalidated: Bool { invalidations > 0 }

    func invalidate() {
        invalidations += 1
        onInvalidate?()
    }
}

struct FakeError: LocalizedError {
    var errorDescription: String? { "fake activation failure" }
}

/// Hands every activation to the check, which decides when and how it completes.
@MainActor
final class FakeVisibility: NativeVisibilityProviding {
    struct Request {
        let systemItems: [Int]
        let bundles: [String]
        let completion: @MainActor (Result<NativeVisibilityAssertion, Error>) -> Void
    }

    var isAvailable = true
    private(set) var requests: [Request] = []
    private(set) var granted: [FakeAssertion] = []

    func activate(allowedSystemItems: [Int], allowedBundleIdentifiers: [String],
                  completion: @escaping @MainActor (Result<NativeVisibilityAssertion, Error>) -> Void) {
        requests.append(Request(systemItems: allowedSystemItems, bundles: allowedBundleIdentifiers, completion: completion))
    }

    /// Grants request `index` (a missing request is reported as a failed check instead of crashing).
    @discardableResult
    func succeed(_ index: Int, line: Int = #line) -> FakeAssertion {
        guard requests.indices.contains(index) else {
            check(false, "request index \(index) exists (\(requests.count) made)", line: line)
            return FakeAssertion(allowed: [])
        }
        let assertion = FakeAssertion(allowed: requests[index].bundles)
        granted.append(assertion)
        requests[index].completion(.success(assertion))
        return assertion
    }

    func fail(_ index: Int, line: Int = #line) {
        guard requests.indices.contains(index) else {
            check(false, "request index \(index) exists (\(requests.count) made)", line: line)
            return
        }
        requests[index].completion(.failure(FakeError()))
    }

    /// Restrictions granted and not invalidated (what macOS would still apply).
    var active: [FakeAssertion] { granted.filter { !$0.isInvalidated } }
}

@MainActor
final class FakeInventory: MenuBarInventoryProviding {
    var isAuthorized = true
    var inventory: MenuBarInventory
    /// When true, snapshots wait for `deliver()`.
    var manual = false
    private(set) var snapshots = 0
    private var pending: [@MainActor (MenuBarInventory) -> Void] = []

    init(_ inventory: MenuBarInventory) { self.inventory = inventory }

    func snapshot(completion: @escaping @MainActor (MenuBarInventory) -> Void) {
        snapshots += 1
        if manual { pending.append(completion) } else { completion(inventory) }
    }

    func deliverAll() {
        let calls = pending
        pending.removeAll()
        calls.forEach { $0(inventory) }
    }
}

/// Manual timers for the engine's request timeouts (nothing fires unless the check says so).
@MainActor
final class FakeTimers {
    private(set) var pending: [(delay: TimeInterval, action: @MainActor () -> Void)] = []

    var schedule: NativeScheduler {
        { [weak self] delay, action in self?.pending.append((delay, action)) }
    }

    func fireAll() {
        let due = pending
        pending.removeAll()
        due.forEach { $0.action() }
    }
}

// MARK: - Test data (Mac Studio: 1920 pt wide, 30 pt bar; CG coordinates)

let ownID = "com.oneswitch.app"
let studioBand = CGRect(x: 0, y: 0, width: 1920, height: 30)
/// The「<」toggle (CG): midX 1313, 607 pt from the right edge.
let toggleCG = CGRect(x: 1300, y: 0, width: 26, height: 30)
let chevronCG = CGRect(x: 1240, y: 1, width: 18, height: 27)

func barItem(_ bundle: String?, x: CGFloat, y: CGFloat = 3, w: CGFloat = 24, pid: pid_t = 100, name: String? = nil,
             detail: String? = nil) -> MenuBarItemInfo {
    MenuBarItemInfo(id: "\(bundle ?? "pid\(pid)")|\(x)", pid: pid, name: name ?? bundle ?? "PID \(pid)", detail: detail,
                    bundleID: bundle, frame: CGRect(x: x, y: y, width: w, height: 24), source: .accessibility,
                    isSystemItem: bundle?.hasPrefix("com.apple.") ?? false, isMovable: true)
}

/// Left of the toggle: com.left, com.left2; right: com.right; split across it: com.split;
/// in the « / not laid out: com.overflow (y 1068), com.parked (two stacked); plus our own app,
/// macOS's MenuBarAgent and a process without a bundle id.
func sampleInventory(chevron: CGRect? = nil) -> MenuBarInventory {
    MenuBarInventory(items: [
        barItem("com.left", x: 1100, pid: 1),
        barItem("com.left2", x: 1180, pid: 2),
        barItem("com.right", x: 1400, pid: 3),
        barItem("com.split", x: 1150, pid: 4),
        barItem("com.split", x: 1450, pid: 4, detail: "second icon"),
        barItem("com.overflow", x: -1, y: 1068, w: 40, pid: 5),
        barItem("com.parked", x: 1261, pid: 6),
        barItem("com.parked", x: 1261, pid: 6),
        barItem(ownID, x: 1350, pid: 7),
        barItem("com.apple.MenuBarAgent", x: 1700, pid: 8, name: "Wi‑Fi"),
        barItem(nil, x: 1000, pid: 77, name: "cli-tool"),
        barItem("com.apple.TextInputMenuAgent", x: 1572, w: 46, pid: 9, name: "TextInputMenuAgent", detail: "ABC"),
    ], overflowChevron: chevron, bands: [studioBand])
}

@MainActor
func makeDeps(_ visibility: FakeVisibility, _ inventory: FakeInventory, running: [String],
              toggle: CGRect? = toggleCG, timers: FakeTimers? = nil, rightToLeft: Bool = false,
              locked: @escaping () -> Bool = { false }) -> NativeHidingDependencies {
    NativeHidingDependencies(visibility: visibility, inventory: inventory, runningBundleIDs: { running },
                             ownBundleIDs: [ownID], toggleFrame: { toggle },
                             schedule: timers?.schedule ?? { _, _ in }, rightToLeft: { rightToLeft }, isSessionLocked: locked)
}

// MARK: - Resolver

@MainActor
func checkNativeResolver() {
    print("系统原生隐藏: inventory → placement per app")
    let layout = NativeLayoutResolver.resolve(inventory: sampleInventory(), toggle: toggleCG, ownBundleIDs: [ownID])
    func place(_ key: String) -> AppPlacement? { layout.apps.first { $0.key == key }?.placement }
    check(layout.toggleUsable, "toggle laid out → usable boundary")
    check(place("com.left") == .leftOfToggle && place("com.left2") == .leftOfToggle, "left of「<」→ leftOfToggle")
    check(place("com.right") == .rightOfToggle, "right of「<」→ rightOfToggle")
    check(place("com.split") == .rightOfToggle, "app with icons on both sides → most visible wins (right)")
    check(layout.apps.first { $0.key == "com.split" }?.itemCount == 2, "icons of one app are grouped (count 2)")
    check(place("com.overflow") == .overflow, "macOS 27 overflowed item (y 1068, outside the bar) → overflow")
    check(place("com.parked") == .overflow, "stacked (parked) items → overflow")
    check(place(ownID) == nil && place("com.apple.MenuBarAgent") == nil, "own app and macOS's item owner are not listed")
    check(place("pid77") == .leftOfToggle && layout.apps.first { $0.key == "pid77" }?.bundleID == nil,
          "process without bundle id is listed (keyed by pid) without a bundle id")
    check(place("com.apple.TextInputMenuAgent") == .rightOfToggle
          && layout.apps.first { $0.key == "com.apple.TextInputMenuAgent" }?.isSystem == true,
          "Apple agent icons right of「<」(input menu) → visible, flagged 系统")
    let order = layout.apps.map(\.key)
    check(order.prefix(5) == ["pid77", "com.left", "com.split", "com.left2", "com.right"],
          "display order: left → right as in the bar (\(order.prefix(5).joined(separator: ", ")))")
    check(Array(order.suffix(2)) == ["com.overflow", "com.parked"], "apps not in the bar listed last, by name")

    let withChevron = NativeLayoutResolver.resolve(inventory: sampleInventory(chevron: CGRect(x: 1175, y: 1, width: 18, height: 27)),
                                                   toggle: toggleCG, ownBundleIDs: [ownID])
    check(withChevron.placement(ofBundle: "com.left2") == .overflow, "item on the « button → overflow")

    let noToggle = NativeLayoutResolver.resolve(inventory: sampleInventory(), toggle: nil, ownBundleIDs: [ownID])
    check(!noToggle.toggleUsable && noToggle.placement(ofBundle: "com.left") == .unknown
          && noToggle.placement(ofBundle: "com.overflow") == .overflow,
          "toggle not laid out → in-bar apps unknown (never hidden on a guess), overflowed stay overflow")
    let onChevron = NativeLayoutResolver.resolve(inventory: sampleInventory(chevron: chevronCG),
                                                 toggle: CGRect(x: 1236, y: 0, width: 26, height: 30), ownBundleIDs: [ownID])
    check(!onChevron.toggleUsable, "toggle on the « button (tucked into the overflow) → not usable")
    let parkedToggle = NativeLayoutResolver.resolve(inventory: sampleInventory(), toggle: CGRect(x: 1259, y: 0, width: 26, height: 30),
                                                    ownBundleIDs: [ownID])
    check(!parkedToggle.toggleUsable, "toggle right-aligned with parked items → not usable")
    let offBar = NativeLayoutResolver.resolve(inventory: sampleInventory(), toggle: CGRect(x: 0, y: 1068, width: 26, height: 30),
                                              ownBundleIDs: [ownID])
    check(!offBar.toggleUsable, "toggle outside the menu-bar strip → not usable")

    // Two displays: distances from each screen's right edge decide.
    let second = CGRect(x: 1920, y: 98, width: 1512, height: 37)
    check(NativeLayoutResolver.placementOf(CGRect(x: 3300, y: 100, width: 24, height: 24), toggle: toggleCG, bands: [studioBand, second])
          == .rightOfToggle, "other display: 120 pt from its right edge < toggle's 607 → right")
    check(NativeLayoutResolver.placementOf(CGRect(x: 2500, y: 100, width: 24, height: 24), toggle: toggleCG, bands: [studioBand, second])
          == .leftOfToggle, "other display: 920 pt from its right edge → left")

    check(NativeLayoutResolver.placementOf(CGRect(x: -4000, y: 3, width: 24, height: 24), toggle: toggleCG, bands: [studioBand])
          == .leftOfToggle, "item pushed off-screen left (another hider) → left")
    let above = CGRect(x: 0, y: -1080, width: 1920, height: 30) // a display stacked above the primary
    check(NativeLayoutResolver.placementOf(CGRect(x: 1800, y: -1077, width: 24, height: 24), toggle: toggleCG, bands: [studioBand, above])
          == .rightOfToggle, "stacked displays: the item's own strip (by y) is used")

    // Auto-hidden menu bar (full-screen app / "自动隐藏和显示菜单栏"): the bar and every item sit just above
    // the screen. They are still in the bar — not "overflow", which would hide every app.
    let raised = MenuBarInventory(items: sampleInventory().items.map { item in
        var moved = item
        if item.frame.minY < 40 { moved.frame.origin.y -= 30 }
        return moved
    }, bands: [studioBand])
    let hiddenBar = NativeLayoutResolver.resolve(inventory: raised, toggle: toggleCG.offsetBy(dx: 0, dy: -30), ownBundleIDs: [ownID])
    check(hiddenBar.toggleUsable && hiddenBar.placement(ofBundle: "com.right") == .rightOfToggle
          && hiddenBar.placement(ofBundle: "com.left") == .leftOfToggle && hiddenBar.placement(ofBundle: "com.overflow") == .overflow,
          "auto-hidden bar (items just above the screen): same placements as a shown bar, overflowed stay overflow")
    check(NativeHidingPlan.make(layout: hiddenBar, rules: [:], runningBundleIDs: ["com.right"], ownBundleIDs: [ownID]).allowed.contains("com.right"),
          "…so a collapse while a full-screen app hides the bar keeps right-side apps visible")

    // Right-to-left UI: status items are laid out from the LEFT edge (clock / 控制中心 there).
    func clock(x: CGFloat) -> MenuBarItemInfo {
        MenuBarItemInfo(id: "clock", pid: 8, name: "时钟", bundleID: "com.apple.MenuBarAgent", identifier: "com.apple.menuextra.clock",
                        frame: CGRect(x: x, y: 0, width: 125, height: 30), source: .accessibility, isSystemItem: true, isMovable: false)
    }
    let rtlToggle = CGRect(x: 420, y: 0, width: 26, height: 30)
    let rtlInventory = MenuBarInventory(items: [
        clock(x: 20),
        barItem("com.near", x: 200, pid: 11),   // between the clock and「<」→ visible side
        barItem("com.far", x: 700, pid: 12),    // beyond「<」→ hidden side
    ], bands: [studioBand])
    check(NativeLayoutResolver.inferredRightToLeft(rtlInventory) == true, "clock at the left end → right-to-left bar")
    check(NativeLayoutResolver.inferredRightToLeft(MenuBarInventory(items: [clock(x: 1775)], bands: [studioBand])) == false,
          "clock at the right end → left-to-right bar")
    check(NativeLayoutResolver.inferredRightToLeft(sampleInventory()) == nil, "no clock / 控制中心 in the read → direction unknown")
    let sideBySide = CGRect(x: 1920, y: 0, width: 1512, height: 37)
    check(NativeLayoutResolver.inferredRightToLeft(MenuBarInventory(items: [clock(x: 1940)], bands: [studioBand, sideBySide])) == true
          && NativeLayoutResolver.inferredRightToLeft(MenuBarInventory(items: [clock(x: 3290)], bands: [studioBand, sideBySide])) == false,
          "clock on a second, side-by-side display is measured on that display")
    let rtl = NativeLayoutResolver.resolve(inventory: rtlInventory, toggle: rtlToggle, ownBundleIDs: [ownID])
    check(rtl.placement(ofBundle: "com.near") == .rightOfToggle && rtl.placement(ofBundle: "com.far") == .leftOfToggle,
          "right-to-left: the side toward the clock is the visible side")
    let rtlNoClock = MenuBarInventory(items: Array(rtlInventory.items.dropFirst()), bands: [studioBand])
    check(NativeLayoutResolver.resolve(inventory: rtlNoClock, toggle: rtlToggle, ownBundleIDs: [ownID], rightToLeft: true)
            .placement(ofBundle: "com.near") == .rightOfToggle
          && NativeLayoutResolver.resolve(inventory: rtlNoClock, toggle: rtlToggle, ownBundleIDs: [ownID])
            .placement(ofBundle: "com.near") == .leftOfToggle,
          "without a clock in the read the language direction decides")
    check(NativeLayoutResolver.resolve(inventory: rtlInventory, toggle: rtlToggle, ownBundleIDs: [ownID], rightToLeft: false) == rtl,
          "the bar's own direction wins over the language fallback")
    check(NativeLayoutResolver.placementOf(CGRect(x: 2000, y: 100, width: 24, height: 24), toggle: rtlToggle, bands: [studioBand, second],
                                           rightToLeft: true) == .rightOfToggle,
          "right-to-left, other display: 92 pt from its left edge < toggle's 433 → visible side")

    // A momentarily unreadable toggle keeps the last known arrangement.
    let filled = noToggle.filledIn(from: layout)
    check(filled.placement(ofBundle: "com.left") == .leftOfToggle && filled.placement(ofBundle: "com.right") == .rightOfToggle,
          "unknown placements filled from the previous read")
    check(layout.filledIn(from: noToggle) == layout, "known placements never overwritten by older unknowns")
    check(AppPlacement.rightOfToggle < .unknown && AppPlacement.unknown < .leftOfToggle && AppPlacement.leftOfToggle < .overflow,
          "placement order: visible < unknown < left < overflow")
}

// MARK: - Plan

/// Crowded notched bar: macOS pushed「<」itself into the «. Then 自动 apps must hide on collapse
/// (otherwise nothing is hidden and「<」never comes back); a merely unreadable toggle still hides nothing.
@MainActor
func checkNativeCrowdedToggle() {
    print("系统原生隐藏: 「<」 in the « (crowded bar)")
    typealias P = NativeHidingPlan
    check(P.shouldHide(rule: .auto, placement: .unknown, toggleOverflowed: true), "自动 + unknown hides when「<」overflowed")
    check(!P.shouldHide(rule: .auto, placement: .unknown, toggleOverflowed: false), "自动 + unknown stays visible otherwise")
    check(!P.shouldHide(rule: .alwaysShow, placement: .unknown, toggleOverflowed: true), "始终显示 wins even then")
    let crowdedToggle = CGRect(x: -1, y: 1068, width: 24, height: 24) // reported below the strip, like overflowed items
    let layout = NativeLayoutResolver.resolve(inventory: sampleInventory(), toggle: crowdedToggle, ownBundleIDs: [ownID])
    check(!layout.toggleUsable && layout.toggleOverflowed, "toggle below the strip → overflowed")
    let running = ["com.left", "com.right", "com.split", ownID, "com.apple.TextInputMenuAgent"]
    let plan = P.make(layout: layout, rules: ["com.right": .alwaysShow], runningBundleIDs: running, ownBundleIDs: [ownID])
    check(plan.hidden.contains("com.left") && plan.hidden.contains("com.split") && !plan.hidden.contains("com.right"),
          "crowded: 自动 apps hidden, 始终显示 kept (\(plan.hidden))")
    check(plan.allowed.contains(ownID) && plan.allowed.contains("com.apple.TextInputMenuAgent"), "own app + system owners still allowed")
    let unreadable = NativeLayoutResolver.resolve(inventory: sampleInventory(), toggle: nil, ownBundleIDs: [ownID])
    check(!unreadable.toggleUsable && !unreadable.toggleOverflowed, "no toggle frame → not 'overflowed'")
    let calm = P.make(layout: unreadable, rules: [:], runningBundleIDs: running, ownBundleIDs: [ownID])
    check(!calm.hidden.contains("com.left") && !calm.hidden.contains("com.split"), "unreadable toggle: nothing hidden on a guess")
    let onChevron = NativeLayoutResolver.resolve(inventory: sampleInventory(chevron: CGRect(x: 1290, y: 3, width: 24, height: 24)),
                                                 toggle: CGRect(x: 1292, y: 3, width: 20, height: 24), ownBundleIDs: [ownID])
    check(onChevron.toggleOverflowed, "toggle on the « button → overflowed")

    // The user put Apple's input-method item LEFT of「<」on purpose: 自动 hides it like any other app.
    let appleLeft = MenuBarInventory(items: [
        barItem("com.apple.TextInputMenuAgent", x: 1000, w: 46, pid: 9, name: "TextInputMenuAgent"),
        barItem("com.left", x: 1100, pid: 1),
    ], overflowChevron: nil, bands: [studioBand])
    let appleLayout = NativeLayoutResolver.resolve(inventory: appleLeft, toggle: toggleCG, ownBundleIDs: [ownID])
    let keepApple = P.make(layout: appleLayout, rules: [:], runningBundleIDs: ["com.left", "com.apple.TextInputMenuAgent"], ownBundleIDs: [ownID])
    check(keepApple.hidden.contains("com.apple.TextInputMenuAgent") && keepApple.hidden.contains("com.left"),
          "自动 hides an Apple agent the user placed left of「<」 (\(keepApple.hidden))")
    let hideApple = P.make(layout: appleLayout, rules: ["com.apple.TextInputMenuAgent": .alwaysHide],
                           runningBundleIDs: ["com.left", "com.apple.TextInputMenuAgent"], ownBundleIDs: [ownID])
    check(hideApple.hidden.contains("com.apple.TextInputMenuAgent"), "始终隐藏 still hides an Apple agent")
}

@MainActor
func checkNativePlan() {
    print("系统原生隐藏: rules × placement → allow-list")
    typealias P = NativeHidingPlan
    check(P.systemItemsToKeep == Array(0..<64), "all system items 0…63 kept")
    let matrix: [(AppVisibilityRule, AppPlacement?, Bool)] = [
        (.auto, .leftOfToggle, true), (.auto, .overflow, true), (.auto, .rightOfToggle, false),
        (.auto, .unknown, false), (.auto, nil, false),
        (.alwaysHide, .rightOfToggle, true), (.alwaysHide, nil, true),
        (.alwaysShow, .leftOfToggle, false), (.alwaysShow, .overflow, false),
    ]
    check(matrix.allSatisfy { P.shouldHide(rule: $0.0, placement: $0.1) == $0.2 },
          "自动 hides left / overflow only; 始终隐藏 always; 始终显示 never")

    let layout = NativeLayoutResolver.resolve(inventory: sampleInventory(), toggle: toggleCG, ownBundleIDs: [ownID])
    let running = ["com.left", "com.left2", "com.right", "com.split", "com.overflow", "com.parked", ownID,
                   "com.idle", "com.hide.running", "com.apple.TextInputMenuAgent", ""]
    let plain = P.make(layout: layout, rules: [:], runningBundleIDs: running, ownBundleIDs: [ownID])
    check(plain.hidden == ["com.left", "com.left2", "com.overflow", "com.parked"], "自动: hides left + overflowed apps (\(plain.hidden))")
    check(Set(plain.allowed).isSuperset(of: [ownID, "com.right", "com.split", "com.idle", "com.hide.running",
                                             "com.apple.TextInputMenuAgent", "com.apple.MenuBarAgent", "com.apple.controlcenter"]),
          "allowed: own app, right-side apps, other running apps, macOS item owners")
    check(Set(plain.allowed).isDisjoint(with: plain.hidden), "hidden apps are not allowed")
    check(plain.allowed == Array(Set(plain.allowed)).sorted() && !plain.allowed.contains(""), "allow-list sorted, unique, no empty ids")

    let rules: [String: AppVisibilityRule] = ["com.left": .alwaysShow, "com.right": .alwaysHide, "com.hide.running": .alwaysHide,
                                              "com.later.show": .alwaysShow, "com.later.hide": .alwaysHide, ownID: .alwaysHide]
    let ruled = P.make(layout: layout, rules: rules, runningBundleIDs: running, ownBundleIDs: [ownID])
    check(ruled.hidden == ["com.hide.running", "com.left2", "com.overflow", "com.parked", "com.right"], "rules override positions (\(ruled.hidden))")
    check(ruled.allowed.contains("com.left") && !ruled.allowed.contains("com.right"), "始终显示 left app allowed, 始终隐藏 right app not")
    check(ruled.allowed.contains("com.later.show"), "始终显示 app that is not running yet is pre-allowed (visible when it starts)")
    check(!ruled.allowed.contains("com.later.hide") && !ruled.hidden.contains("com.later.hide"),
          "始终隐藏 app that is not running: not allowed (hidden when it starts), not counted")
    check(ruled.allowed.contains(ownID) && !ruled.hidden.contains(ownID), "our own app is never hidden, whatever the rule says")

    let blind = P.make(layout: nil, rules: ["com.right": .alwaysHide], runningBundleIDs: running, ownBundleIDs: [ownID])
    check(blind.hidden == ["com.right"] && blind.allowed.contains("com.left"),
          "no positions (no 辅助功能): only 始终隐藏 apps are hidden, everything else stays")
    let unknown = NativeLayoutResolver.resolve(inventory: sampleInventory(), toggle: nil, ownBundleIDs: [ownID])
    let unsure = P.make(layout: unknown, rules: [:], runningBundleIDs: running, ownBundleIDs: [ownID])
    check(unsure.hidden == ["com.overflow", "com.parked"], "toggle position unknown: in-bar apps stay visible")

    // Remembered "right of「<」" apps (login: they may start after the first collapse).
    let pre = P.make(layout: layout, rules: ["com.pre.hidden": .alwaysHide], runningBundleIDs: running, ownBundleIDs: [ownID],
                     preAllowed: ["com.pre.later", "com.left", "com.pre.hidden", ""])
    check(pre.allowed.contains("com.pre.later"), "remembered visible app pre-allowed before it starts")
    check(!pre.allowed.contains("com.left") && pre.hidden.contains("com.left"), "…unless it is now seen left of「<」")
    check(!pre.allowed.contains("com.pre.hidden") && !pre.allowed.contains(""), "…or its rule is 始终隐藏")
    check(layout.visibleBundleIDs == ["com.apple.TextInputMenuAgent", "com.right", "com.split"], "visible apps of a read")
    check(unknown.visibleBundleIDs == nil, "no visible list when the toggle position is unknown")
    check(layout.mergedVisible(into: ["com.left", "com.not.running", "com.right"])
          == ["com.apple.TextInputMenuAgent", "com.not.running", "com.right", "com.split"],
          "remembered list: seen apps updated (com.left dropped), unseen kept")
    check(unknown.mergedVisible(into: ["com.x"]) == ["com.x"], "unusable read leaves the remembered list alone")
}

// MARK: - Engine (generation, replace-then-drop, fail open)

@MainActor
func checkNativeEngine() {
    print("系统原生隐藏 engine (fake restriction + inventory)")
    let running = ["com.left", "com.right", "com.split", "com.idle"]

    // 1. collapse → snapshot → activate → collapsed; expand drops it.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory())
        let engine = NativeVisibilityEngine(dependencies: makeDeps(vis, inv, running: running)) { nil }
        var outcomes: [NativeVisibilityEngine.Outcome] = []
        var layouts = 0
        engine.onLayout = { _ in layouts += 1 }
        engine.collapse(rules: [:]) { outcomes.append($0) }
        check(inv.snapshots == 1 && layouts == 1 && vis.requests.count == 1 && engine.state == .activating,
              "collapse reads positions once and requests a restriction")
        check(vis.requests[0].systemItems == Array(0..<64), "system items 0…63 always allowed")
        check(vis.requests[0].bundles.contains(ownID) && vis.requests[0].bundles.contains("com.right")
              && !vis.requests[0].bundles.contains("com.left"), "allow-list: own + right-side apps, not the left ones")
        let a = vis.succeed(0)
        check(engine.state == .collapsed && engine.isRestricted && outcomes.count == 1, "granted → collapsed")
        if case .collapsed(let plan)? = outcomes.first {
            check(plan.hidden.contains("com.left") && engine.activePlan == plan, "outcome carries the applied plan")
        } else {
            check(false, "outcome is .collapsed")
        }
        engine.expand()
        check(a.isInvalidated && !engine.isRestricted && engine.state == .expanded && engine.activePlan == nil,
              "expand invalidates the restriction")
        check(vis.requests.count == 1, "expand never activates anything")
        engine.releaseAll()
        check(a.invalidations == 1, "releasing twice invalidates once")
    }
    // 2. expand while the activation is in flight → late grant invalidated, no completion.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory())
        let engine = NativeVisibilityEngine(dependencies: makeDeps(vis, inv, running: running)) { nil }
        var outcomes = 0
        engine.collapse(rules: [:]) { _ in outcomes += 1 }
        engine.expand()
        let late = vis.succeed(0)
        check(late.isInvalidated && !engine.isRestricted && engine.state == .expanded && outcomes == 0,
              "grant arriving after an expand is invalidated at once (and not reported)")
    }
    // 3. expand while positions are being read → no activation at all.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory())
        inv.manual = true
        let engine = NativeVisibilityEngine(dependencies: makeDeps(vis, inv, running: running)) { nil }
        engine.collapse(rules: [:]) { _ in }
        engine.expand()
        inv.deliverAll()
        check(vis.requests.isEmpty && engine.state == .expanded, "snapshot finishing after an expand is discarded")
    }
    // 4. re-apply while collapsed: cached positions, replace-then-drop.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory())
        let engine = NativeVisibilityEngine(dependencies: makeDeps(vis, inv, running: running)) { nil }
        engine.collapse(rules: [:]) { _ in }
        let first = vis.succeed(0)
        // Hidden items would now report stale positions — must not be re-read.
        inv.inventory = MenuBarInventory(items: [barItem("com.left", x: 1500)], bands: [studioBand])
        var outcomes: [NativeVisibilityEngine.Outcome] = []
        engine.collapse(rules: ["com.left": .alwaysShow]) { outcomes.append($0) }
        check(inv.snapshots == 1, "positions are not re-read while restricted (cached ones used)")
        check(vis.requests.count == 2 && vis.requests[1].bundles.contains("com.left"), "new rules → new allow-list")
        check(!first.isInvalidated && engine.isRestricted, "old restriction kept until the new one is granted (no flash)")
        var newActiveWhenOldDropped = false
        first.onInvalidate = { newActiveWhenOldDropped = vis.granted.count == 2 }
        let second = vis.succeed(1)
        check(first.isInvalidated && newActiveWhenOldDropped && !second.isInvalidated && vis.active.count == 1,
              "…then the old one is dropped (replace, then drop)")
        check(outcomes.count == 1 && engine.state == .collapsed, "re-apply reported once")
        engine.releaseAll()
        check(vis.active.isEmpty, "release leaves nothing active")
    }
    // 5. two rapid collapses: the superseded grant is invalidated whenever it arrives.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory())
        let engine = NativeVisibilityEngine(dependencies: makeDeps(vis, inv, running: running)) { nil }
        var outcomes = 0
        engine.collapse(rules: [:]) { _ in outcomes += 1 }
        engine.collapse(rules: ["com.right": .alwaysHide]) { _ in outcomes += 1 }
        check(vis.requests.count == 2 && engine.generation >= 2, "second request supersedes the first (generation \(engine.generation))")
        let newer = vis.succeed(1)
        let older = vis.succeed(0) // arrives last
        check(older.isInvalidated && !newer.isInvalidated && vis.active.count == 1 && outcomes == 1,
              "late grant of the superseded request invalidated; the newer one stays")
        check(engine.activePlan?.hidden.contains("com.right") == true, "state reflects the newest request")
        engine.releaseAll()
    }
    // 6. fail open.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory())
        let engine = NativeVisibilityEngine(dependencies: makeDeps(vis, inv, running: running)) { nil }
        engine.collapse(rules: [:]) { _ in }
        let held = vis.succeed(0)
        var outcome: NativeVisibilityEngine.Outcome?
        engine.collapse(rules: ["com.left": .alwaysShow]) { outcome = $0 }
        vis.fail(1)
        check(held.isInvalidated && vis.active.isEmpty && !engine.isRestricted && engine.state == .expanded,
              "activation error: every restriction released (icons visible again)")
        if case .failed(let reason)? = outcome {
            check(reason.contains("fake activation failure"), "failure reported with its reason")
        } else {
            check(false, "failure reported")
        }
        vis.isAvailable = false
        var unavailable: NativeVisibilityEngine.Outcome?
        engine.collapse(rules: [:]) { unavailable = $0 }
        check(vis.requests.count == 2 && inv.snapshots == 1, "API unavailable: nothing read or requested")
        if case .failed? = unavailable { check(engine.state == .expanded, "API unavailable: reported as failure, stays expanded") } else {
            check(false, "API unavailable reported")
        }
    }
    // 7. no 辅助功能: rules only, no position reads.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory())
        inv.isAuthorized = false
        let engine = NativeVisibilityEngine(dependencies: makeDeps(vis, inv, running: running)) { nil }
        engine.collapse(rules: ["com.right": .alwaysHide]) { _ in }
        check(inv.snapshots == 0 && vis.requests.count == 1, "without 辅助功能 positions are not read")
        check(!vis.requests[0].bundles.contains("com.right") && vis.requests[0].bundles.contains("com.left"),
              "…only 始终隐藏 apps are hidden, the rest stays visible")
        vis.succeed(0)
        engine.releaseAll()
    }
    // 9. an activation that never answers fails open; a grant arriving afterwards is invalidated.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory()), timers = FakeTimers()
        let engine = NativeVisibilityEngine(dependencies: makeDeps(vis, inv, running: running, timers: timers)) { nil }
        var outcome: NativeVisibilityEngine.Outcome?
        engine.collapse(rules: [:]) { outcome = $0 }
        check(vis.requests.count == 1 && engine.state == .activating, "activation pending")
        timers.fireAll()
        if case .failed(let reason)? = outcome {
            check(reason.contains("did not answer") && engine.state == .expanded && !engine.isRestricted,
                  "no answer within the timeout → failure (fail open): \(reason)")
        } else {
            check(false, "activation timeout reported as failure")
        }
        let late = vis.succeed(0)
        check(late.isInvalidated && vis.active.isEmpty && !engine.isRestricted, "grant after the timeout is invalidated at once")
    }
    // 10. a position read that never finishes fails open without requesting anything.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory()), timers = FakeTimers()
        inv.manual = true
        let engine = NativeVisibilityEngine(dependencies: makeDeps(vis, inv, running: running, timers: timers)) { nil }
        var outcome: NativeVisibilityEngine.Outcome?
        engine.collapse(rules: [:]) { outcome = $0 }
        timers.fireAll()
        if case .failed(let reason)? = outcome { check(reason.contains("timed out"), "read timeout → failure (\(reason))") } else {
            check(false, "read timeout reported")
        }
        inv.deliverAll()
        check(vis.requests.isEmpty && engine.state == .expanded, "read finishing after its timeout requests nothing")
    }
    // 11. timers of finished phases never fire a failure.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory()), timers = FakeTimers()
        let engine = NativeVisibilityEngine(dependencies: makeDeps(vis, inv, running: running, timers: timers)) { nil }
        var outcomes: [NativeVisibilityEngine.Outcome] = []
        engine.collapse(rules: [:]) { outcomes.append($0) }
        let held = vis.succeed(0)
        timers.fireAll()
        check(outcomes.count == 1 && engine.state == .collapsed && !held.isInvalidated && timers.pending.isEmpty,
              "granted in time: the read / activation timers are harmless")
        // Re-apply (rules changed) that times out: the old restriction is released too (fail open).
        engine.collapse(rules: ["com.left": .alwaysShow]) { outcomes.append($0) }
        timers.fireAll()
        check(held.isInvalidated && vis.active.isEmpty && engine.state == .expanded, "re-apply timing out releases everything")
        vis.succeed(1)
        check(vis.active.isEmpty, "…and its late grant is invalidated")
    }
    // 12. the engine goes away with a request in flight: the late grant is invalidated, not leaked.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory())
        var engine: NativeVisibilityEngine? = NativeVisibilityEngine(dependencies: makeDeps(vis, inv, running: running)) { nil }
        engine?.collapse(rules: [:]) { _ in }
        engine = nil
        let orphan = vis.succeed(0)
        check(engine == nil && orphan.isInvalidated && vis.active.isEmpty, "grant for a released engine is invalidated")
    }
    // 13. the language direction reaches the resolver when the bar does not tell.
    do {
        let vis = FakeVisibility()
        let rtlBar = MenuBarInventory(items: [barItem("com.near", x: 200, pid: 11), barItem("com.far", x: 700, pid: 12)], bands: [studioBand])
        let inv = FakeInventory(rtlBar)
        let engine = NativeVisibilityEngine(dependencies: makeDeps(vis, inv, running: [], toggle: CGRect(x: 420, y: 0, width: 26, height: 30),
                                                                   rightToLeft: true)) { nil }
        engine.collapse(rules: [:]) { _ in }
        check(engine.layout?.placement(ofBundle: "com.near") == .rightOfToggle
              && vis.requests.first?.bundles.contains("com.near") == true && vis.requests.first?.bundles.contains("com.far") == false,
              "right-to-left language: apps between the edge and「<」stay visible")
        vis.succeed(0)
        engine.releaseAll()
    }
    // 8. list refresh.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory())
        let engine = NativeVisibilityEngine(dependencies: makeDeps(vis, inv, running: running)) { nil }
        var got: NativeLayout?
        engine.refreshLayout { got = $0 }
        check(inv.snapshots == 1 && got?.apps.isEmpty == false && engine.layout == got, "refresh while expanded reads positions")
        engine.collapse(rules: [:]) { _ in }
        vis.succeed(0)
        engine.refreshLayout { got = $0 }
        check(inv.snapshots == 2 && got == engine.layout, "refresh while restricted returns the cached layout without reading")
        inv.manual = true
        engine.expand()
        engine.refreshLayout { _ in }
        let generation = engine.generation
        engine.collapse(rules: [:]) { _ in }
        inv.deliverAll()
        check(engine.generation == generation + 1 && vis.requests.count == 2, "a refresh never supersedes a collapse")
        vis.succeed(1)
        engine.releaseAll()
        check(vis.active.isEmpty, "nothing left active")
    }
}

// MARK: - Controller with fakes (toggle item only; no real restriction)

@MainActor
func checkNativeController() {
    print("系统原生隐藏 controller (fake restriction; real toggle item, removed again)")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let suiteName = "oneswitch.menubarhidercheck.native"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    let suffix = "-selfcheck-native"
    defer {
        let std = UserDefaults.standard
        for key in std.dictionaryRepresentation().keys where key.hasPrefix("NSStatusItem") && key.hasSuffix(suffix) {
            std.removeObject(forKey: key)
        }
        suite.removePersistentDomain(forName: suiteName)
    }

    // API missing → separator engine from the start.
    do {
        let vis = FakeVisibility(), inv = FakeInventory(sampleInventory())
        vis.isAvailable = false
        let module = MenuBarHiderModule(defaults: suite, autosaveSuffix: suffix, strategy: .systemOverflow,
                                        native: makeDeps(vis, inv, running: []))
        module.controller.store.update { $0.collapseAtLaunch = false }
        module.start()
        let d = module.controller.diagnostics()
        check(module.controller.engineKind == .legacy && d.hasSeparator && module.controller.nativeFallbackReason != nil,
              "API unavailable → 兼容模式 with separator, reason shown")
        check(module.controller.engineTitle == "兼容模式", "engine title 兼容模式")
        module.stop()
        check(!module.controller.diagnostics().isInstalled, "stopped")
        suite.removePersistentDomain(forName: suiteName)
    }

    let vis = FakeVisibility(), inv = FakeInventory(sampleInventory()), timers = FakeTimers()
    var lockedNow = false
    let running = ["com.left", "com.left2", "com.right", "com.split", "com.idle"]
    // As left by a previous launch: com.late was right of「<」, com.left too (it has moved since).
    suite.set(["com.late", "com.left"], forKey: "menubar.nativeVisibleApps")
    let module = MenuBarHiderModule(defaults: suite, autosaveSuffix: suffix, strategy: .systemOverflow,
                                    native: makeDeps(vis, inv, running: running, timers: timers, locked: { lockedNow }))
    let c = module.controller
    module.start()
    let d0 = c.diagnostics()
    check(c.engineKind == .native && c.engineTitle == "系统原生隐藏", "macOS 27 + API available → 系统原生隐藏")
    check(d0.isInstalled && !d0.hasSeparator && d0.separatorLength == nil, "only the「<」toggle is in the bar (no separator, no gap)")
    check(waitUntil(3) { vis.requests.count == 1 }, "启动时自动隐藏 requests a restriction once the toggle is placed")
    check(c.visibility == .collapsed && c.stateText == "正在隐藏图标…", "collapsed state while the request is pending")
    guard vis.requests.count == 1 else {
        module.stop()
        return
    }
    check(vis.requests[0].bundles.contains("com.late") && !vis.requests[0].bundles.contains("com.left"),
          "remembered visible app (not running yet) pre-allowed; one now left of「<」is not")
    check(c.rememberedVisibleApps == ["com.apple.TextInputMenuAgent", "com.late", "com.right", "com.split"],
          "remembered visible apps updated from the fresh read")
    let first = vis.succeed(0)
    check(c.diagnostics().nativeRestricted && c.nativeHiddenBundles == ["com.left", "com.left2", "com.overflow", "com.parked"],
          "granted: left / overflowed apps hidden")
    check(c.stateText == "已隐藏 4 个 App 的图标", "state text counts hidden apps")
    let menu = module.menuItems()
    check(menu.first?.title == "显示隐藏的图标（10 秒后自动隐藏）", "menu: reveal (auto-hide delay)")
    check(menu.dropFirst().first?.title == "系统原生隐藏 · 已隐藏 4 个 App 的图标", "menu: engine + hidden count")
    check(menu.last?.title == "设置要隐藏的 App…", "menu: settings entry")
    let rows = c.nativeAppRows()
    check(rows.count == 8 && rows.first(where: { $0.key == "com.left" })?.hides == true
          && rows.first(where: { $0.key == "com.right" })?.hides == false
          && rows.first(where: { $0.key == "pid77" })?.bundleID == nil,
          "settings list: \(rows.count) apps with effective result (no-bundle process listed, not settable)")

    c.expand()
    check(first.isInvalidated && !c.diagnostics().nativeRestricted && c.visibility == .expanded, "expand drops the restriction")
    check(c.secondsUntilCollapse.map { $0 >= 9 && $0 <= 10 } == true, "auto re-hide armed (~10 s)")
    check(module.menuItems().first?.title == "立即隐藏图标", "menu: hide now")
    c.collapse()
    check(inv.snapshots == 2 && vis.requests.count == 2, "collapse from an unrestricted bar re-reads positions")
    let second = vis.succeed(1)

    // Rule change while collapsed → re-applied without re-reading, old restriction kept until granted.
    c.setRule(.alwaysShow, for: "com.left")
    check(vis.requests.count == 3 && vis.requests[2].bundles.contains("com.left") && inv.snapshots == 2,
          "rule change while collapsed re-applies with cached positions")
    check(!second.isInvalidated, "old restriction still active while the new one is pending")
    let third = vis.succeed(2)
    check(second.isInvalidated && !third.isInvalidated && c.nativeHiddenBundles?.contains("com.left") == false,
          "new restriction active, old one dropped")
    check(c.nativeAppRows().first(where: { $0.key == "com.left" }).map { $0.rule == .alwaysShow && !$0.hides } == true,
          "settings list reflects the rule")

    // Toggle (click / hotkey path).
    c.userToggle(revealAlwaysHidden: false)
    check(third.isInvalidated && c.visibility == .expanded, "toggle → expanded, restriction dropped")
    c.userToggle(revealAlwaysHidden: false)
    check(c.visibility == .collapsed && vis.requests.count == 4, "toggle again → collapse requested")

    // First activation failure → fail open, but stay 系统原生隐藏 (a transient error must not bring back the «).
    vis.fail(3)
    check(vis.active.isEmpty && !c.diagnostics().nativeRestricted, "activation failure: nothing hidden")
    check(waitUntil(1) { c.visibility == .expanded }, "first failure: icons shown (「>」)")
    check(c.engineKind == .native && !c.diagnostics().hasSeparator && c.secondsUntilCollapse != nil,
          "…still 系统原生隐藏 (no separator), auto-hide re-armed to try again")
    c.collapse() // what the auto-hide does after the delay
    check(vis.requests.count == 5 && c.visibility == .collapsed, "next collapse tries again")
    vis.succeed(4)
    check(vis.active.count == 1 && c.nativeHiddenBundles != nil, "…granted")

    // A timeout counts as a failure; the success above reset the count, so this one only shows the icons.
    c.expand()
    c.collapse()
    check(vis.requests.count == 6, "collapse requested")
    timers.fireAll()
    check(waitUntil(1) { c.visibility == .expanded } && c.engineKind == .native && vis.active.isEmpty,
          "unanswered request → icons shown, still 系统原生隐藏 (a success in between resets the count)")
    vis.succeed(5)
    check(vis.active.isEmpty, "late grant of the timed-out request is invalidated")

    // Failures while the screen is locked are not counted (the auto-hide also fires behind the lock screen).
    lockedNow = true
    for _ in 0..<2 {
        let r = vis.requests.count
        c.collapse()
        vis.fail(r)
        check(waitUntil(1) { c.visibility == .expanded } && c.engineKind == .native,
              "failure while the screen is locked: icons shown, not counted toward 兼容模式")
    }
    lockedNow = false

    // Second (counted) failure in a row → automatic fallback to the separator engine.
    var r = vis.requests.count
    c.collapse()
    check(vis.requests.count == r + 1, "collapse requested again")
    vis.fail(r)
    check(vis.active.isEmpty && !c.diagnostics().nativeRestricted, "second failure: nothing hidden")
    check(waitUntil(1) { c.engineKind == .legacy }, "…two failures in a row fall back to 兼容模式")
    check(c.diagnostics().hasSeparator && c.nativeFallbackReason?.contains("fake activation failure") == true,
          "fallback installs the separator and explains why")
    check(c.engineTitle == "兼容模式" && c.visibility == .expanded, "兼容模式, expanded until the separator is placed")
    c.reassertNativeRestriction()
    check(vis.requests.count == r + 1, "兼容模式: re-assert (wake / MenuBarAgent relaunch) never touches the native restriction")

    // Retry.
    r = vis.requests.count
    c.retryNativeHiding()
    check(c.engineKind == .native && !c.diagnostics().hasSeparator && c.nativeFallbackReason == nil, "retry: back to 系统原生隐藏, separator removed")
    check(vis.requests.count == r + 1 && c.visibility == .collapsed, "retry collapses natively")
    let retried = vis.succeed(r)
    check(vis.active.count == 1, "one restriction active")

    // Wake / unlock / session switch / MenuBarAgent relaunch: requested again (replace, then drop).
    lockedNow = true
    c.reassertNativeRestriction()
    check(vis.requests.count == r + 1, "re-assert while the screen is locked waits for the unlock")
    lockedNow = false
    c.reassertNativeRestriction()
    check(vis.requests.count == r + 2 && vis.requests[r + 1].bundles == vis.requests[r].bundles,
          "re-assert requests the same allow-list again")
    check(!retried.isInvalidated && c.stateText == "正在隐藏图标…", "…old restriction kept while the new one is pending")
    c.reassertNativeRestriction()
    check(vis.requests.count == r + 2, "a second re-assert while one is pending does nothing")
    let reasserted = vis.succeed(r + 1)
    check(retried.isInvalidated && !reasserted.isInvalidated && vis.active.count == 1 && c.nativeState == .collapsed,
          "exactly one restriction afterwards (the new one)")

    // Rapid clicks / hotkey: whatever order the grants arrive in, the result matches the final state.
    let base = vis.requests.count
    for _ in 0..<5 { c.userToggle(revealAlwaysHidden: false) } // → expanded, 2 requests superseded
    check(c.visibility == .expanded && vis.requests.count == base + 2 && vis.active.isEmpty, "5 quick toggles end expanded, nothing held")
    vis.succeed(base + 1)
    vis.succeed(base)
    check(vis.active.isEmpty && !c.diagnostics().nativeRestricted, "late grants of superseded collapses are invalidated")
    for _ in 0..<3 { c.userToggle(revealAlwaysHidden: false) } // → collapsed
    check(c.visibility == .collapsed && vis.requests.count == base + 4, "3 more toggles end collapsed")
    vis.succeed(base + 3)
    vis.succeed(base + 2)
    check(vis.active.count == 1 && c.diagnostics().nativeRestricted && c.nativeState == .collapsed,
          "exactly one restriction held, the newest")
    c.reassertNativeRestriction()
    c.expand()
    vis.succeed(base + 4)
    check(vis.active.isEmpty && c.visibility == .expanded, "re-assert overtaken by an expand: its grant is invalidated")
    c.reassertNativeRestriction()
    check(vis.requests.count == base + 5, "re-assert while expanded does nothing")
    c.collapse()
    vis.succeed(base + 5)
    check(vis.active.count == 1, "collapsed again")

    // Disable / enable.
    c.store.update { $0.enabled = false }
    check(vis.active.isEmpty && !c.isActive && !c.diagnostics().isInstalled, "disabling drops the restriction and removes「<」")
    c.store.update { $0.enabled = true }
    check(c.isActive && !c.diagnostics().hasSeparator, "re-enabling reinstalls only the toggle")
    let enabledAt = vis.requests.count
    check(waitUntil(3) { vis.requests.count == enabledAt + 1 }, "…and hides again at once (启动时自动隐藏)")
    // Disabled again while that request is pending: the late grant must not stick.
    c.store.update { $0.enabled = false }
    if vis.requests.count == enabledAt + 1 { vis.succeed(enabledAt) }
    check(vis.active.isEmpty && !c.diagnostics().nativeRestricted, "disabled while hiding: the late grant is invalidated")
    c.store.update { $0.enabled = true }
    check(waitUntil(3) { vis.requests.count == enabledAt + 2 }, "re-enabled: hides again")
    if vis.requests.count == enabledAt + 2 { vis.succeed(enabledAt + 1) }

    if let path = ProcessInfo.processInfo.environment["MENUBAR_RENDER_SETTINGS"] {
        renderSettings(module, to: path)
    }

    check(vis.requests.count > 10 && vis.requests.allSatisfy { $0.bundles.contains(ownID) && $0.systemItems == Array(0..<64) },
          "every one of the \(vis.requests.count) requests kept OneSwitch (「<」, main icon, 系统监控) and all system items visible")
    check(NativeHidingDependencies.defaultOwnBundleIDs().contains(AppEnvironment.bundleIdentifier),
          "the app's own bundle id is always in the keep-visible list")

    // stop() must release synchronously.
    check(vis.active.count == 1, "restriction active before stop")
    module.stop()
    check(vis.active.isEmpty && !c.diagnostics().isInstalled && !c.diagnostics().nativeRestricted,
          "stop invalidates the restriction synchronously and removes the toggle")
    module.stop()
    c.reassertNativeRestriction()
    check(vis.active.isEmpty && vis.requests.count == enabledAt + 2, "after stop nothing is requested any more")

    // stop() while a request is still pending (quit right after launch): nothing may stay hidden.
    do {
        let vis2 = FakeVisibility(), inv2 = FakeInventory(sampleInventory())
        let module2 = MenuBarHiderModule(defaults: suite, autosaveSuffix: suffix, strategy: .systemOverflow,
                                         native: makeDeps(vis2, inv2, running: running))
        module2.start()
        check(waitUntil(3) { vis2.requests.count == 1 }, "second instance: hide-at-launch request pending")
        module2.stop()
        if !vis2.requests.isEmpty { vis2.succeed(0) }
        check(vis2.active.isEmpty && !module2.controller.diagnostics().isInstalled, "stop with a pending request: late grant invalidated")
    }
}

// MARK: - macOS 14–26 keep the separator engine

@MainActor
func checkLegacyOnOlderMacOS() {
    print("macOS 14–26 (push-offscreen strategy): separator engine, native hiding never used")
    let suiteName = "oneswitch.menubarhidercheck.native" // same throw-away suite as the native controller checks
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    let suffix = "-selfcheck-legacy"
    defer {
        let std = UserDefaults.standard
        for key in std.dictionaryRepresentation().keys where key.hasPrefix("NSStatusItem") && key.hasSuffix(suffix) {
            std.removeObject(forKey: key)
        }
        suite.removePersistentDomain(forName: suiteName)
    }
    let vis = FakeVisibility(), inv = FakeInventory(sampleInventory())
    // Even with native dependencies wired in (the app only wires them on macOS 27+).
    let module = MenuBarHiderModule(defaults: suite, autosaveSuffix: suffix, strategy: .pushOffscreen,
                                    native: makeDeps(vis, inv, running: ["com.left"]))
    let c = module.controller
    c.store.update { $0.collapseAtLaunch = false }
    module.start()
    let d = c.diagnostics()
    check(c.engineKind == .legacy && d.hasSeparator && c.nativeFallbackReason == nil && c.engineTitle == "分隔线模式",
          "separator engine with its separator, no fallback note")
    c.setRule(.alwaysHide, for: "com.left")
    c.reassertNativeRestriction()
    check(vis.requests.isEmpty && inv.snapshots == 0 && !d.nativeRestricted, "rules / re-assert never touch the native restriction")
    check(module.menuItems().last?.title == "整理菜单栏图标…", "menu keeps the separator wording")
    module.stop()
    check(!c.diagnostics().isInstalled && vis.requests.isEmpty, "stopped, nothing requested")
}

// MARK: - Live probe (real API, ≤ 2 s, allow-all)

@MainActor
func checkNativeLiveProbe() {
    print("系统原生隐藏 API (live)")
    let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    guard major >= 27 else {
        print("  (macOS \(major): not applicable)")
        return
    }
    check(SystemMenuBarVisibility.isSupported, "macOS \(major): MenuBarClientCore restriction API resolves")
    guard SystemMenuBarVisibility.isSupported else { return }
    guard !sessionLocked else {
        print("  (screen locked — live activation probe skipped)")
        return
    }
    guard ProcessInfo.processInfo.environment["MENUBAR_NATIVE_PROBE"] != "0" else {
        print("  (MENUBAR_NATIVE_PROBE=0 — live activation probe skipped)")
        return
    }
    // Allow every running app (and ours): nothing visible should change. The grant is invalidated the
    // moment it arrives, also when it arrives after we stopped waiting.
    let allowed = Array(Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) + [ownID])).sorted()
    let provider = SystemMenuBarVisibility()
    var result: String?
    var heldFor: TimeInterval = 0
    let started = Date()
    provider.activate(allowedSystemItems: NativeHidingPlan.systemItemsToKeep, allowedBundleIdentifiers: allowed) { r in
        switch r {
        case .success(let assertion):
            let granted = Date()
            assertion.invalidate()
            heldFor = Date().timeIntervalSince(granted)
            result = "granted after \(Int(granted.timeIntervalSince(started) * 1000)) ms"
        case .failure(let error):
            result = "failed: \(error.localizedDescription)"
        }
    }
    _ = waitUntil(1.5) { result != nil }
    print("  activation (\(allowed.count) apps allowed): \(result ?? "no answer within 1.5 s (a late grant is invalidated on arrival)")")
    if let result, result.hasPrefix("granted") {
        check(heldFor < 0.5, "live restriction invalidated immediately (held \(Int(heldFor * 1000)) ms)")
    }
}

/// Opt-in (MENUBAR_RENDER_SETTINGS=/path.png): renders the settings page offscreen for a visual check.
@MainActor
func renderSettings(_ module: MenuBarHiderModule, to path: String) {
    let size = NSSize(width: 680, height: 1900)
    let host = NSHostingView(rootView: module.settingsView().frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    _ = waitUntil(0.5) { false }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
        print("  settings page rendered to \(path)")
    }
    window.contentView = nil
}
