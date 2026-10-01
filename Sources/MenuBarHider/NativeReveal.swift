import AppKit
import ApplicationServices
import OneSwitchCore

// "Reveal what fits" (系统原生隐藏 on a crowded / notched menu bar).
//
// Expanding used to drop the restriction, which shows every hidden icon at once. On a notched MacBook Pro
// with many icons they do not fit right of the camera housing: macOS then shows its «, and because
// OneSwitch's items are among the most recently created ones it pushes「<」, the 系统监控 items and the main
// icon into it — and「<」cannot be clicked any more. Expanding now activates a restriction that allows the
// collapsed allow-list plus the hidden apps that fit (nearest to「<」first); only when every hidden app fits
// (always on a roomy display) is the restriction released exactly as before. Everything here is pure
// logic (the checks drive it with fakes), except `NativeRevealProbeReader` and `ownStatusItemFrames`.

// MARK: - What is known about an app's icons

/// One app's menu-bar icons as last seen. Counts and widths come from any read (an icon hidden by the
/// restriction, or parked in the «, still reports its width); the position only from a read in which the
/// icons were laid out and visible.
public struct NativeAppMetrics: Equatable, Sendable {
    public var itemCount: Int
    /// Sum of the icons' widths (pt); an icon without a usable width counts `NativeRevealPlanner.unknownItemWidth`.
    public var width: CGFloat
    /// Distance of the app's icon nearest to the status-item edge (the right edge; the left edge in a
    /// right-to-left UI) from that edge, the last time it was laid out. Smaller = closer to that edge.
    public var edgeDistance: CGFloat?

    public init(itemCount: Int, width: CGFloat, edgeDistance: CGFloat? = nil) {
        self.itemCount = itemCount
        self.width = width
        self.edgeDistance = edgeDistance
    }
}

public enum NativeMetricsRecorder {
    /// Updates `metrics` (per bundle id) from a read.
    /// - Parameters:
    ///   - trusted: bundle ids whose icons are shown right now (nil = every app: an unrestricted read). Apps
    ///     hidden by the restriction report stale frames: only their icon count is refreshed, and their
    ///     widths only when nothing was known or the count changed; their position is never taken.
    ///   - ownBundleIDs: our own app (not a candidate for revealing, not recorded).
    public static func record(_ inventory: MenuBarInventory, into metrics: inout [String: NativeAppMetrics],
                              trusted: Set<String>?, ownBundleIDs: Set<String>, rightToLeft: Bool) {
        let parked = MenuBarClassifier.parkedIndices(inventory.items.map(\.frame))
        var order: [String] = []
        var groups: [String: [(index: Int, frame: CGRect)]] = [:]
        for (index, item) in inventory.items.enumerated() {
            guard let bundle = item.bundleID, !bundle.isEmpty, !ownBundleIDs.contains(bundle),
                  !NativeLayoutResolver.systemItemOwners.contains(bundle) else { continue }
            if groups[bundle] == nil { order.append(bundle) }
            groups[bundle, default: []].append((index, item.frame))
        }
        for bundle in order {
            guard let entries = groups[bundle] else { continue }
            let count = entries.count
            let width = entries.reduce(CGFloat(0)) { $0 + NativeRevealPlanner.usableWidth($1.frame.width) }
            let known = metrics[bundle]
            if trusted?.contains(bundle) ?? true {
                let distance = entries.filter {
                    !NativeLayoutResolver.isOverflowed($0.frame, parked: parked.contains($0.index), inventory: inventory)
                }.compactMap { edgeDistance(of: $0.frame, bands: inventory.bands, rightToLeft: rightToLeft) }.min()
                metrics[bundle] = NativeAppMetrics(itemCount: count, width: width, edgeDistance: distance ?? known?.edgeDistance)
            } else if let known, known.itemCount == count {
                continue // hidden now: keep what was measured while it was visible
            } else {
                metrics[bundle] = NativeAppMetrics(itemCount: count, width: width, edgeDistance: known?.edgeDistance)
            }
        }
    }

    /// Distance of `frame` from the edge the status items are laid out from (right edge of its screen's
    /// strip; left edge right-to-left). nil when it is on no screen.
    public static func edgeDistance(of frame: CGRect, bands: [CGRect], rightToLeft: Bool) -> CGFloat? {
        guard let strip = NativeLayoutResolver.strip(of: frame, bands: bands) else { return nil }
        return rightToLeft ? frame.minX - strip.minX : strip.maxX - frame.maxX
    }
}

// MARK: - Room on「<」's side of the bar

/// The status-item side of the menu bar on the display that hosts「<」(CG), read when icons are revealed.
public struct NativeStatusStrip: Equatable, Sendable {
    /// The display's menu-bar strip (its x-range is the display's).
    public var band: CGRect
    /// Width of the unobscured area beside the camera housing on the status-item side
    /// (`NSScreen.auxiliaryTopRightArea`; the top-left one in a right-to-left UI). nil without a notch.
    public var notchSideWidth: CGFloat?
    /// x-range of the frontmost app's menus on this display; nil when it could not be read.
    public var menusMinX: CGFloat?
    public var menusMaxX: CGFloat?
    /// The other displays that show a menu bar (「显示器具有单独的空间」) and have a camera housing: the width
    /// beside it on the status-item side. They lay out the same icons from their own status-item edge, so
    /// an external display hosting「<」must not reveal more than fits beside the built-in display's notch —
    /// otherwise macOS pushes OneSwitch's items into the « there.
    public var otherNotchSides: [CGFloat]

    public init(band: CGRect, notchSideWidth: CGFloat? = nil, menusMinX: CGFloat? = nil, menusMaxX: CGFloat? = nil,
                otherNotchSides: [CGFloat] = []) {
        self.band = band
        self.notchSideWidth = notchSideWidth
        self.menusMinX = menusMinX
        self.menusMaxX = menusMaxX
        self.otherNotchSides = otherNotchSides
    }

    public var hasNotch: Bool { (notchSideWidth ?? 0) > 0 }

    /// A camera housing limits the room: on「<」's display or on another display showing the same icons.
    public var limitedByNotch: Bool { hasNotch || otherNotchSides.contains { $0 > 0 } }

    /// Where the status items' room ends toward the app menus: the camera housing and / or the end of the
    /// frontmost app's menus (plus a gap), whichever leaves less room. nil when neither is known — on a
    /// display without a notch the menus are then unknown and the room cannot be told.
    public func innerBoundary(rightToLeft: Bool) -> CGFloat? {
        let gap = NativeRevealPlanner.menuGap
        if rightToLeft {
            let notch = hasNotch ? notchSideWidth.map { band.minX + $0 } : nil
            let menus = menusMinX.map { $0 - gap }
            return [notch, menus].compactMap { $0 }.min()
        }
        let notch = hasNotch ? notchSideWidth.map { band.maxX - $0 } : nil
        let menus = menusMaxX.map { $0 + gap }
        return [notch, menus].compactMap { $0 }.max()
    }
}

/// What `NativeVisibilityEngine.reveal` asks for when icons are revealed.
public struct NativeRevealProbeRequest: Equatable, Sendable {
    /// The「<」toggle (CG): its display is the one measured.
    public var toggle: CGRect
    /// Apps started since the collapse (not in its allow-list): their icons are read too.
    public var bundleIDs: [String]
    public var rightToLeft: Bool

    public init(toggle: CGRect, bundleIDs: [String], rightToLeft: Bool) {
        self.toggle = toggle
        self.bundleIDs = bundleIDs
        self.rightToLeft = rightToLeft
    }
}

public struct NativeRevealProbe: Equatable, Sendable {
    /// nil when the toggle's display could not be found.
    public var strip: NativeStatusStrip?
    /// Icons of the requested apps (hidden right now: count and width only); nil when they could not be
    /// read (no 辅助功能).
    public var items: [MenuBarItemInfo]?

    public init(strip: NativeStatusStrip?, items: [MenuBarItemInfo]?) {
        self.strip = strip
        self.items = items
    }
}

/// Where our own status items are (「<」, 系统监控, main icon), summed up so two moments can be compared
/// (see `NativeRevealPlanner.ownItemsDisplaced`).
public struct NativeOwnItems: Equatable, Sendable {
    /// Items laid out in the menu bar of `band`'s display.
    public var laidOut: Int
    /// Items overlapping another of our items in the same row (parked together in the «).
    public var stacked: Int

    public init(laidOut: Int, stacked: Int) {
        self.laidOut = laidOut
        self.stacked = stacked
    }

    /// - Parameters:
    ///   - frames: our status items' window frames (CG).
    ///   - band: the menu-bar strip of「<」's display (CG).
    public init(frames: [CGRect], band: CGRect) {
        let shown = frames.filter {
            $0.width > 0 && $0.height > 0 && $0.midX >= band.minX && $0.midX < band.maxX
                && NativeLayoutResolver.isInBar($0, bands: [band])
        }
        var stacked = 0
        for (i, a) in shown.enumerated() {
            let overlapping = shown.enumerated().contains { j, b in
                j != i && abs(a.midY - b.midY) < 8 && min(a.maxX, b.maxX) - max(a.minX, b.minX) > 2
            }
            if overlapping { stacked += 1 }
        }
        self.init(laidOut: shown.count, stacked: stacked)
    }
}

/// Reads a `NativeRevealProbe`; completion on the main actor (the checks inject a fake).
public typealias NativeRevealProbing = @MainActor (_ request: NativeRevealProbeRequest,
                                                   _ completion: @escaping @MainActor (NativeRevealProbe?) -> Void) -> Void

// MARK: - Plan

/// One hidden app that could be revealed.
public struct NativeRevealCandidate: Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public var itemCount: Int
    /// Sum of the icons' widths; nil = unknown (each icon counts `unknownItemWidth`).
    public var width: CGFloat?
    /// See `NativeAppMetrics.edgeDistance` (nil = never laid out: ordered after the others, by name).
    public var edgeDistance: CGFloat?
    /// Known to have icons (hidden by the collapse, or seen with icons). Unknown ones (started since the
    /// collapse, icons unreadable) are revealed only with room to spare and never reported as "does not fit".
    public var known: Bool

    public init(bundleID: String, name: String, itemCount: Int, width: CGFloat?, edgeDistance: CGFloat?, known: Bool = true) {
        self.bundleID = bundleID
        self.name = name
        self.itemCount = itemCount
        self.width = width
        self.edgeDistance = edgeDistance
        self.known = known
    }
}

/// Which hidden apps a partial reveal shows.
public struct NativeRevealPlan: Equatable, Sendable {
    /// Revealed, in reveal order.
    public var revealed: [String]
    /// Known to have icons but kept hidden: no room (what the menu reports), in reveal order.
    public var unfit: [String]
    /// Unknown apps (see `NativeRevealCandidate.known`) kept hidden.
    public var withheld: [String]
    /// Room for more icons (pt, after the safety margin) and what the revealed ones take.
    public var available: CGFloat
    public var used: CGFloat
    /// The room is limited by a camera housing (notched display).
    public var notched: Bool
    /// Room each candidate takes (icons + spacing).
    public var costs: [String: CGFloat]

    public init(revealed: [String] = [], unfit: [String] = [], withheld: [String] = [], available: CGFloat, used: CGFloat = 0,
                notched: Bool, costs: [String: CGFloat] = [:]) {
        self.revealed = revealed
        self.unfit = unfit
        self.withheld = withheld
        self.available = available
        self.used = used
        self.notched = notched
        self.costs = costs
    }

    /// Every hidden app fits: releasing the restriction shows exactly the same.
    public var allFit: Bool { unfit.isEmpty && withheld.isEmpty }

    /// The farthest revealed app hidden again (the bar overflowed after all).
    public func droppingLast() -> NativeRevealPlan {
        guard let last = revealed.last else { return self }
        var copy = self
        copy.revealed.removeLast()
        copy.unfit.insert(last, at: 0)
        copy.used = max(0, used - (costs[last] ?? 0))
        return copy
    }
}

public enum NativeRevealPlanner {
    /// Gap macOS 27 leaves between two status items (measured 6–7 pt).
    public static let itemSpacing: CGFloat = 7
    /// Width assumed for an icon that never reported one.
    public static let unknownItemWidth: CGFloat = 30
    /// Kept free so small width changes (live text, a badge) never push anything into the «.
    public static let safetyMargin: CGFloat = 24
    /// Space between the last app menu and the first status item.
    public static let menuGap: CGFloat = OverflowPlanner.menuGap

    /// A reported icon width, or `unknownItemWidth` when it is not plausible.
    public static func usableWidth(_ width: CGFloat) -> CGFloat {
        width >= 8 && width <= 600 ? width : unknownItemWidth
    }

    /// Room an app's icons take in the bar: its icons plus one spacing each.
    public static func cost(of candidate: NativeRevealCandidate) -> CGFloat {
        let count = max(1, candidate.itemCount)
        return (candidate.width ?? CGFloat(count) * unknownItemWidth) + CGFloat(count) * itemSpacing
    }

    /// Room left for more icons: from the inner edge of the icons shown now to the notch / app menus, minus
    /// the safety margin (negative = none) — and never more than fits beside the notch of another display
    /// that shows the same icons (`NativeStatusStrip.otherNotchSides`). nil when no boundary is known (then
    /// reveal everything).
    public static func availableRoom(strip: NativeStatusStrip, innerEdge: CGFloat, rightToLeft: Bool) -> CGFloat? {
        var rooms: [CGFloat] = []
        if let boundary = strip.innerBoundary(rightToLeft: rightToLeft) {
            rooms.append(rightToLeft ? boundary - innerEdge : innerEdge - boundary)
        }
        // What the shown icons take from the status-item edge: the same on every display.
        let used = rightToLeft ? innerEdge - strip.band.minX : strip.band.maxX - innerEdge
        rooms += strip.otherNotchSides.filter { $0 > 0 }.map { $0 - used }
        guard let room = rooms.min() else { return nil }
        return room - safetyMargin
    }

    /// Inner edge (left edge; right edge right-to-left) of the icons shown right now on「<」's display: the
    /// toggle, our other icons (系统监控, main icon — wherever the user put them) and the other apps' visible
    /// icons (measured after the collapse, or estimated).
    public static func visibleInnerEdge(toggle: CGRect, ownItems: [CGRect], othersEdge: CGFloat?, band: CGRect,
                                        rightToLeft: Bool) -> CGFloat {
        let own = ownItems.filter {
            $0.width > 0 && $0.midX >= band.minX && $0.midX < band.maxX && NativeLayoutResolver.isInBar($0, bands: [band])
        }
        var edges = [rightToLeft ? toggle.maxX : toggle.minX] + own.map { rightToLeft ? $0.maxX : $0.minX }
        if let othersEdge { edges.append(othersEdge) }
        return (rightToLeft ? edges.max() : edges.min()) ?? toggle.minX
    }

    /// Estimated inner edge of the other apps' icons shown while collapsed when it was not measured: the
    /// allowed apps last seen beyond「<」(or in the «, or placed nowhere) sit next to it. nil = none.
    public static func estimatedOthersEdge(toggle: CGRect, layout: NativeLayout?, allowed: Set<String>,
                                           metrics: [String: NativeAppMetrics], rightToLeft: Bool) -> CGFloat? {
        estimatedOthersEdge(from: rightToLeft ? toggle.maxX : toggle.minX, layout: layout, allowed: allowed,
                            metrics: metrics, rightToLeft: rightToLeft)
    }

    /// Same, measured from `edge` — the inner edge of our own items (「<」, 系统监控, main icon). Where those
    /// apps sit relative to our items is unknown, so all of them are assumed beyond our items: the estimate
    /// only errs toward less room (fewer icons revealed), never toward an overflow.
    public static func estimatedOthersEdge(from edge: CGFloat, layout: NativeLayout?, allowed: Set<String>,
                                           metrics: [String: NativeAppMetrics], rightToLeft: Bool) -> CGFloat? {
        let far = (layout?.apps ?? []).filter { app in
            guard let bundle = app.bundleID, allowed.contains(bundle) else { return false }
            return app.placement != .rightOfToggle
        }
        guard !far.isEmpty else { return nil }
        let width = far.reduce(CGFloat(0)) { sum, app in
            let known = app.bundleID.flatMap { metrics[$0] }
            return sum + cost(of: NativeRevealCandidate(bundleID: app.key, name: app.name, itemCount: known?.itemCount ?? app.itemCount,
                                                        width: known?.width, edgeDistance: nil))
        }
        return rightToLeft ? edge + width : edge - width
    }

    /// The collapsed bar, read after the restriction took effect (only the allowed apps' frames are live):
    /// the inner edge of the other apps' visible icons on「<」's display, and whether macOS shows its « there
    /// (then there is no room at all).
    public static func measureVisible(inventory: MenuBarInventory, visible: Set<String>, toggle: CGRect?,
                                      rightToLeft: Bool) -> (edge: CGFloat?, overflowed: Bool) {
        let strip = toggle.flatMap { NativeLayoutResolver.strip(of: $0, bands: inventory.bands) }
        func onStrip(_ rect: CGRect) -> Bool {
            guard let strip else { return true }
            return rect.midX >= strip.minX && rect.midX < strip.maxX
        }
        let parked = MenuBarClassifier.parkedIndices(inventory.items.map(\.frame))
        var edge: CGFloat?
        for (index, item) in inventory.items.enumerated() {
            guard let bundle = item.bundleID,
                  visible.contains(bundle) || NativeLayoutResolver.systemItemOwners.contains(bundle),
                  !NativeLayoutResolver.isOverflowed(item.frame, parked: parked.contains(index), inventory: inventory),
                  onStrip(item.frame) else { continue }
            let e = rightToLeft ? item.frame.maxX : item.frame.minX
            edge = rightToLeft ? max(edge ?? e, e) : min(edge ?? e, e)
        }
        let overflowed = inventory.overflowChevron.map { $0.width > 0 && onStrip($0) } ?? false
        return (edge, overflowed)
    }

    /// After a partial reveal settled: macOS shows its « on「<」's display, or「<」itself is no longer laid out
    /// (a single overflowed icon gets no « but is dropped — ours are dropped first). A toggle whose frame
    /// cannot be read any more counts as dropped.
    public static func revealOverflowed(inventory: MenuBarInventory, toggle: CGRect?) -> Bool {
        guard let toggle else { return true }
        if let chevron = inventory.overflowChevron, chevron.width > 0 {
            let strip = NativeLayoutResolver.strip(of: toggle, bands: inventory.bands)
            if strip.map({ chevron.midX >= $0.minX && chevron.midX < $0.maxX }) ?? true { return true }
        }
        let parked = MenuBarClassifier.parkedIndices(inventory.items.map(\.frame))
        let overflowFrames = inventory.items.enumerated().filter {
            NativeLayoutResolver.isOverflowed($0.element.frame, parked: parked.contains($0.offset), inventory: inventory)
        }.map(\.element.frame)
        return NativeLayoutResolver.usableToggle(toggle, inventory: inventory, overflowFrames: overflowFrames) == nil
    }

    /// Our own items (「<」, 系统监控, main icon) after a reveal settled, compared with just before it: fewer
    /// of them laid out on「<」's display, or more of them stacked on each other (laid-out items never
    /// overlap; overflowed ones are parked on one anchor). macOS drops OneSwitch's items first, and a single
    /// dropped item gets no «, so `revealOverflowed` alone would miss a dropped 系统监控 item or main icon.
    public static func ownItemsDisplaced(before: NativeOwnItems, after: NativeOwnItems) -> Bool {
        after.laidOut < before.laidOut || after.stacked > before.stacked
    }

    /// The hidden apps that could be revealed: the ones the collapse hides, plus apps started since then
    /// (not in its allow-list) that have icons.
    /// - Parameters:
    ///   - newApps: running apps that are neither allowed nor hidden by `base`.
    ///   - newAppsWithIcons: the new apps whose icons were just read (nil = could not be read: unknown).
    public static func candidates(base: NativeHidingPlan, layout: NativeLayout?, metrics: [String: NativeAppMetrics],
                                  newApps: [String], newAppsWithIcons: Set<String>?, names: [String: String] = [:]) -> [NativeRevealCandidate] {
        var result: [NativeRevealCandidate] = []
        let hidden = Set(base.hidden)
        for bundle in base.hidden {
            let listed = layout?.apps.first { $0.bundleID == bundle }
            let known = metrics[bundle]
            result.append(NativeRevealCandidate(bundleID: bundle, name: listed?.name ?? names[bundle] ?? bundle,
                                                itemCount: known?.itemCount ?? listed?.itemCount ?? 1,
                                                width: known?.width, edgeDistance: known?.edgeDistance))
        }
        for bundle in Set(newApps).subtracting(hidden).sorted() {
            let name = names[bundle] ?? layout?.apps.first { $0.bundleID == bundle }?.name ?? bundle
            if let withIcons = newAppsWithIcons {
                // Read just now: no icons = nothing to reveal.
                guard withIcons.contains(bundle), let known = metrics[bundle] else { continue }
                result.append(NativeRevealCandidate(bundleID: bundle, name: name, itemCount: known.itemCount,
                                                    width: known.width, edgeDistance: known.edgeDistance))
            } else if let known = metrics[bundle] {
                result.append(NativeRevealCandidate(bundleID: bundle, name: name, itemCount: known.itemCount,
                                                    width: known.width, edgeDistance: known.edgeDistance))
            } else {
                result.append(NativeRevealCandidate(bundleID: bundle, name: name, itemCount: 1, width: nil,
                                                    edgeDistance: nil, known: false))
            }
        }
        return result
    }

    /// Reveal order: known apps nearest to「<」first (smallest distance from the status-item edge — the
    /// rightmost in a left-to-right bar), then known apps never laid out by name, then unknown ones by name.
    public static func ordered(_ candidates: [NativeRevealCandidate]) -> [NativeRevealCandidate] {
        func byName(_ a: NativeRevealCandidate, _ b: NativeRevealCandidate) -> Bool {
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.bundleID < b.bundleID
            }
        }
        return candidates.sorted { a, b in
            if a.known != b.known { return a.known }
            switch (a.edgeDistance, b.edgeDistance) {
            case let (x?, y?): return x != y ? x < y : byName(a, b)
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return byName(a, b)
            }
        }
    }

    /// Fills the room in reveal order. An app that does not fit is skipped (a smaller one further on may
    /// still fit); an app fits when the room it takes, added to what is used, is at most `available`.
    /// - Parameter revealable: when set, only these apps may be revealed (a re-check while icons are shown
    ///   only ever hides some of them again, it never adds any).
    public static func plan(candidates: [NativeRevealCandidate], available: CGFloat, notched: Bool,
                            revealable: Set<String>? = nil) -> NativeRevealPlan {
        var plan = NativeRevealPlan(available: available, notched: notched)
        for candidate in ordered(candidates) {
            let cost = cost(of: candidate)
            plan.costs[candidate.bundleID] = cost
            if revealable?.contains(candidate.bundleID) ?? true, plan.used + cost <= available + 0.001 {
                plan.revealed.append(candidate.bundleID)
                plan.used += cost
            } else if candidate.known {
                plan.unfit.append(candidate.bundleID)
            } else {
                plan.withheld.append(candidate.bundleID)
            }
        }
        return plan
    }
}

// MARK: - Placement read while only some apps are shown

extension NativeLayoutResolver {
    /// Placement from a read taken while a partial reveal is held: only the icons of the `visible` apps are
    /// laid out, so only their frames are used (a ⌘-drag across「<」during the reveal counts). Every other
    /// app keeps what `previous` knew — hidden icons report stale frames — with the crowded-bar rule baked
    /// in (a third-party app of unknown position counted as left of「<」when「<」had overflowed). Apps with
    /// icons that were never placed and are hidden now had no room: `.overflow`. Apps no longer in the read
    /// (quit) are dropped. nil when「<」cannot serve as the boundary (keep the previous layout).
    public static func resolveRestricted(inventory: MenuBarInventory, toggle: CGRect?, ownBundleIDs: Set<String>,
                                         visible: Set<String>, previous: NativeLayout?,
                                         rightToLeft fallbackRTL: Bool = false) -> NativeLayout? {
        let shown = inventory.items.filter { item in
            item.bundleID.map { visible.contains($0) || systemItemOwners.contains($0) } ?? false
        }
        let fresh = resolve(inventory: MenuBarInventory(items: shown, overflowChevron: inventory.overflowChevron, bands: inventory.bands),
                            toggle: toggle, ownBundleIDs: ownBundleIDs,
                            rightToLeft: inferredRightToLeft(inventory) ?? fallbackRTL)
        guard fresh.toggleUsable else { return nil }
        var apps = fresh.apps
        var listed = Set(apps.map(\.key))
        // Everything else in the read: hidden now (or without a bundle id, which is never allowed).
        var present: [String: (item: MenuBarItemInfo, count: Int)] = [:]
        var presentOrder: [String] = []
        for item in inventory.items where !shown.contains(item) {
            if let bundle = item.bundleID, ownBundleIDs.contains(bundle) || systemItemOwners.contains(bundle) { continue }
            let key = item.bundleID ?? "pid\(item.pid)"
            if let entry = present[key] {
                present[key] = (entry.item, entry.count + 1)
            } else {
                present[key] = (item, 1)
                presentOrder.append(key)
            }
        }
        let crowded = previous?.toggleOverflowed ?? false
        for old in previous?.apps ?? [] where !listed.contains(old.key) {
            guard let now = present[old.key] else { continue }
            var entry = old
            entry.itemCount = now.count
            if crowded && !entry.isSystem && entry.placement == .unknown { entry.placement = .leftOfToggle }
            apps.append(entry)
            listed.insert(old.key)
        }
        for key in presentOrder where !listed.contains(key) {
            guard let now = present[key] else { continue }
            apps.append(MenuBarAppEntry(key: key, bundleID: now.item.bundleID, pid: now.item.pid, name: now.item.name,
                                        itemCount: now.count, placement: .overflow,
                                        isSystem: now.item.bundleID?.hasPrefix("com.apple.") ?? false, minX: nil,
                                        details: now.item.detail.map { [$0] } ?? []))
        }
        return NativeLayout(apps: sortedForDisplay(apps), toggleUsable: true)
    }

    /// Display order: laid-out apps left → right, then the others by name.
    static func sortedForDisplay(_ apps: [MenuBarAppEntry]) -> [MenuBarAppEntry] {
        apps.sorted { a, b in
            switch (a.minX, b.minX) {
            case let (x?, y?): return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}

// MARK: - Real readers (AppKit / Accessibility)

public enum NativeRevealProbeReader {
    private static let queue = DispatchQueue(label: "oneswitch.menubar.reveal", qos: .userInitiated)

    /// The toggle's display (notch area, frontmost app's menus) and the requested apps' icons. The
    /// Accessibility reads run off the main thread; completion on the main actor. nil when the toggle is on
    /// no display.
    @MainActor
    public static func read(_ request: NativeRevealProbeRequest, completion: @escaping @MainActor (NativeRevealProbe?) -> Void) {
        let screens = NSScreen.screens
        let bands = MenuBarGeometry.menuBarBands(screens: screens.map(ScreenGeometry.init), thickness: NSStatusBar.system.thickness)
        guard let band = NativeLayoutResolver.strip(of: request.toggle, bands: bands),
              let index = bands.firstIndex(of: band), screens.indices.contains(index) else {
            completion(nil)
            return
        }
        // Only widths are used: auxiliaryTopLeft/RightArea reach the screen's left / right edge, and x is the
        // same in AppKit and CG coordinates (their origins / y are not needed).
        func notchSide(_ screen: NSScreen) -> CGFloat? {
            guard screen.safeAreaInsets.top > 0,
                  let side = request.rightToLeft ? screen.auxiliaryTopLeftArea : screen.auxiliaryTopRightArea,
                  side.width > 0 else { return nil }
            return side.width
        }
        let notchSideWidth = notchSide(screens[index])
        // With 「显示器具有单独的空间」 every display has a menu bar showing the same status items.
        let otherNotchSides: [CGFloat] = NSScreen.screensHaveSeparateSpaces
            ? screens.indices.filter { $0 != index }.compactMap { notchSide(screens[$0]) }
            : []
        let owner = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier
        let apps = request.bundleIDs.flatMap { bundle in
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle).filter { !$0.isTerminated }.map {
                RunningAppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? bundle, bundleID: bundle)
            }
        }
        let ownPID = getpid()
        queue.async {
            let trusted = AXIsProcessTrusted()
            // The menus must be in this display's bar (displays stacked vertically share x-ranges).
            let menus = owner.flatMap {
                MenuBarItemScanner.appMenusExtent(pid: $0, screenMinX: band.minX, screenMaxX: band.maxX, band: band)
            }
            let items: [MenuBarItemInfo]? = trusted
                ? (apps.isEmpty ? [] : MenuBarItemScanner.scanAccessibility(apps: apps, excludingPID: ownPID).items)
                : nil
            let probe = NativeRevealProbe(strip: NativeStatusStrip(band: band, notchSideWidth: notchSideWidth,
                                                                   menusMinX: menus?.lowerBound, menusMaxX: menus?.upperBound,
                                                                   otherNotchSides: otherNotchSides),
                                          items: items)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(probe) }
            }
        }
    }

    /// Frames (CG) of every status item of this process that is laid out in a menu bar — the toggle, the
    /// 系统监控 items and the main icon (other modules' items are not reachable otherwise).
    @MainActor
    public static func ownStatusItemFrames() -> [CGRect] {
        guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return [] }
        let screens = ScreenGeometry.current()
        return NSApplication.shared.windows
            .filter { $0.isVisible && String(describing: type(of: $0)).contains("StatusBarWindow") }
            .map(\.frame)
            .filter { MenuBarGeometry.isPlausibleStatusItemFrame($0, screens: screens) }
            .map { MenuBarGeometry.toCG($0, primaryMaxY: primaryMaxY) }
    }
}
