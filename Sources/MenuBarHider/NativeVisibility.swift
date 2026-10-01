import AppKit
import ApplicationServices
import OneSwitchCore
import OneSwitchObjC

// macOS 27 "native" hiding.
//
// macOS 27 can restrict the menu bar to an allow-list of system items and apps (the mechanism behind
// assessment / exam mode, private framework MenuBarClientCore). Every status item of an app that is not
// allowed is hidden and macOS reflows the bar itself: no "«" overflow chevron, no gap, no separator.
// The restriction lasts until it is invalidated or until the holding process exits — a crash or a kill
// restores the bar by itself.
//
// Idea credit: Hidden Bar (MIT, github.com/dwarvesf/hidden — NativeVisibilityEngine,
// AccessibilityMenuBarInventory, MenuBarLayoutResolver). This is an independent implementation with a
// per-app rule (自动 / 始终隐藏 / 始终显示) on top of the position-based classification.

// MARK: - Per-app rule

/// What to do with an app's menu-bar icons while the hider is collapsed (hiding is per app / bundle id).
public enum AppVisibilityRule: String, Codable, CaseIterable, Identifiable, Sendable {
    /// By position: icons left of the「<」toggle are hidden, icons right of it stay visible.
    case auto
    case alwaysHide
    case alwaysShow

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "自动"
        case .alwaysHide: return "始终隐藏"
        case .alwaysShow: return "始终显示"
        }
    }
}

// MARK: - Visibility restriction (bridge + protocol for fakes)

/// A held restriction. Hiding lasts until `invalidate()` or until this process exits.
public protocol NativeVisibilityAssertion: AnyObject {
    func invalidate()
}

/// Activates menu-bar visibility restrictions. Completions run on the main actor.
@MainActor
public protocol NativeVisibilityProviding: AnyObject {
    var isAvailable: Bool { get }
    func activate(allowedSystemItems: [Int], allowedBundleIdentifiers: [String],
                  completion: @escaping @MainActor (Result<NativeVisibilityAssertion, Error>) -> Void)
}

/// The real restriction, through the exception-safe Objective-C bridge (OneSwitchObjC).
@MainActor
public final class SystemMenuBarVisibility: NativeVisibilityProviding {
    public init() {}

    /// Framework, classes and selectors resolve on this macOS (cheap after the first call).
    public nonisolated static var isSupported: Bool { OSNativeMenuBarIsAvailable() }

    public var isAvailable: Bool { Self.isSupported }

    public func activate(allowedSystemItems: [Int], allowedBundleIdentifiers: [String],
                         completion: @escaping @MainActor (Result<NativeVisibilityAssertion, Error>) -> Void) {
        OSNativeMenuBarActivate(allowedSystemItems.map { NSNumber(value: $0) }, allowedBundleIdentifiers) { raw, error in
            // The bridge calls back on the main queue.
            MainActor.assumeIsolated {
                if let raw {
                    completion(.success(Handle(raw: raw)))
                } else {
                    completion(.failure(error ?? NSError(domain: "OSNativeMenuBar", code: 4,
                                                         userInfo: [NSLocalizedDescriptionKey: "activation returned no assertion"])))
                }
            }
        }
    }

    /// Invalidates exactly once; dropping the last reference also releases the restriction (fail open).
    final class Handle: NativeVisibilityAssertion {
        private var raw: Any?
        private let lock = NSLock()

        init(raw: Any) { self.raw = raw }

        func invalidate() {
            lock.lock()
            let value = raw
            raw = nil
            lock.unlock()
            if let value { OSNativeMenuBarInvalidate(value) }
        }

        deinit { invalidate() }
    }
}

// MARK: - Inventory (who has menu-bar icons, and where)

/// Other apps' menu-bar items, read through Accessibility (CG coordinates).
public struct MenuBarInventory: Equatable, Sendable {
    public var items: [MenuBarItemInfo]
    /// The system "«" overflow button, when shown.
    public var overflowChevron: CGRect?
    /// Menu-bar strips of all screens (CG), to tell laid-out items from ones the bar has no room for.
    public var bands: [CGRect]

    public init(items: [MenuBarItemInfo], overflowChevron: CGRect? = nil, bands: [CGRect]) {
        self.items = items
        self.overflowChevron = overflowChevron
        self.bands = bands
    }
}

@MainActor
public protocol MenuBarInventoryProviding: AnyObject {
    var isAuthorized: Bool { get }
    /// Reads every other app's menu-bar items; completion on the main actor. Positions are only
    /// meaningful while the bar is unrestricted (hidden items keep stale frames).
    func snapshot(completion: @escaping @MainActor (MenuBarInventory) -> Void)
}

/// `AXExtrasMenuBar` of every running app (needs 辅助功能), scanned off the main thread.
@MainActor
public final class AccessibilityMenuBarInventory: MenuBarInventoryProviding {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "oneswitch.menubar.inventory", qos: .userInitiated)) {
        self.queue = queue
    }

    public var isAuthorized: Bool { AXIsProcessTrusted() }

    public func snapshot(completion: @escaping @MainActor (MenuBarInventory) -> Void) {
        let bands = MenuBarGeometry.menuBarBands(screens: ScreenGeometry.current(), thickness: NSStatusBar.system.thickness)
        let apps = RunningAppInfo.current()
        let ownPID = getpid()
        queue.async {
            let scanned = MenuBarItemScanner.scanAccessibility(apps: apps, excludingPID: ownPID)
            let inventory = MenuBarInventory(items: scanned.items, overflowChevron: scanned.chevron, bands: bands)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(inventory) }
            }
        }
    }
}

// MARK: - Layout (position of each app relative to the toggle)

/// Where an app's icons were, relative to the「<」toggle, the last time the bar was unrestricted.
public enum AppPlacement: Int, Comparable, Sendable {
    /// Right of the toggle → shown while collapsed (自动).
    case rightOfToggle = 0
    /// The toggle's position could not be read → shown (never hide on a guess).
    case unknown = 1
    /// Left of the toggle → hidden while collapsed (自动).
    case leftOfToggle = 2
    /// Not in the bar at all (in the system "«", or no room) → hidden while collapsed (自动).
    case overflow = 3

    public static func < (a: AppPlacement, b: AppPlacement) -> Bool { a.rawValue < b.rawValue }

    public var title: String {
        switch self {
        case .rightOfToggle: return "位于「<」右侧"
        case .unknown: return "位置未知"
        case .leftOfToggle: return "位于「<」左侧"
        case .overflow: return "在系统「«」中或未显示"
        }
    }
}

/// One app that owns menu-bar icons.
public struct MenuBarAppEntry: Identifiable, Equatable, Sendable {
    /// Bundle id, or "pid<n>" for processes without one.
    public var key: String
    public var bundleID: String?
    public var pid: pid_t
    public var name: String
    public var itemCount: Int
    /// Most visible placement among the app's icons (hiding is per app, so a visible icon wins).
    public var placement: AppPlacement
    /// Apple-owned (com.apple.*).
    public var isSystem: Bool
    /// x of the app's leftmost laid-out icon (CG), for display order; nil when none is in the bar.
    public var minX: CGFloat?
    /// The icons' own labels (AX title / description), e.g. "ABC" for the input menu.
    public var details: [String]

    public var id: String { key }

    public init(key: String, bundleID: String?, pid: pid_t, name: String, itemCount: Int,
                placement: AppPlacement, isSystem: Bool, minX: CGFloat?, details: [String] = []) {
        self.key = key
        self.bundleID = bundleID
        self.pid = pid
        self.name = name
        self.itemCount = itemCount
        self.placement = placement
        self.isSystem = isSystem
        self.minX = minX
        self.details = details
    }
}

/// The apps with menu-bar icons and their placement, read from an unrestricted bar.
public struct NativeLayout: Equatable, Sendable {
    /// Display order: laid-out apps left → right, then the others by name.
    public var apps: [MenuBarAppEntry]
    /// False when the toggle's position could not be used (not laid out, or parked in the «).
    public var toggleUsable: Bool
    /// The toggle has a frame but macOS pushed it out of the bar (into the «, parked with overflowed items,
    /// or below the strip) — the bar is too crowded. Our toggle belongs right of every third-party app, so
    /// then 自动 apps are hidden on collapse: freeing the room is what brings「<」back into the bar.
    public var toggleOverflowed: Bool

    public init(apps: [MenuBarAppEntry], toggleUsable: Bool, toggleOverflowed: Bool = false) {
        self.apps = apps
        self.toggleUsable = toggleUsable
        self.toggleOverflowed = toggleOverflowed && !toggleUsable
    }

    public func placement(ofBundle bundleID: String) -> AppPlacement? {
        apps.first { $0.bundleID == bundleID }?.placement
    }

    /// Apps whose icons sit right of the toggle (to remember across launches), nil when the toggle's
    /// position was not usable.
    public var visibleBundleIDs: [String]? {
        guard toggleUsable else { return nil }
        return apps.filter { $0.placement == .rightOfToggle }.compactMap(\.bundleID).sorted()
    }

    /// Merges this read into a remembered "visible" list: apps seen now replace what was known about
    /// them, apps not seen now (not running) keep their remembered state.
    public func mergedVisible(into remembered: [String]) -> [String] {
        guard let visible = visibleBundleIDs else { return remembered }
        let seen = Set(apps.compactMap(\.bundleID))
        return Set(remembered.filter { !seen.contains($0) }).union(visible).sorted()
    }

    /// `self` (fresh) with `.unknown` placements replaced by what `previous` knew — a momentarily
    /// unreadable toggle must not turn a known arrangement into "show everything".
    public func filledIn(from previous: NativeLayout?) -> NativeLayout {
        guard let previous else { return self }
        var copy = self
        for index in copy.apps.indices where copy.apps[index].placement == .unknown {
            if let key = copy.apps[index].bundleID, let old = previous.placement(ofBundle: key), old != .unknown {
                copy.apps[index].placement = old
            }
        }
        return copy
    }
}

public enum NativeLayoutResolver {
    /// Owners of macOS's own items (clock, Wi‑Fi, 控制中心…): kept visible through the numeric system
    /// item ids, never listed or hidden per bundle.
    public static let systemItemOwners: Set<String> = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"]

    /// Groups the inventory by app and places each app relative to the toggle.
    /// - Parameters:
    ///   - toggle: the toggle's window frame in CG coordinates (nil when not laid out).
    ///   - ownBundleIDs: our own app (always visible, not listed).
    ///   - rightToLeft: the menu bar's direction when the bar itself does not tell (see
    ///     `inferredRightToLeft`): in a right-to-left UI the status items are laid out from the LEFT edge,
    ///     so the visible side of the toggle is its left.
    public static func resolve(inventory: MenuBarInventory, toggle: CGRect?, ownBundleIDs: Set<String>,
                               rightToLeft fallbackRTL: Bool = false) -> NativeLayout {
        let rtl = inferredRightToLeft(inventory) ?? fallbackRTL
        let frames = inventory.items.map(\.frame)
        let parked = MenuBarClassifier.parkedIndices(frames)
        var overflowFrames: [CGRect] = []
        var placements: [AppPlacement?] = []
        for (index, item) in inventory.items.enumerated() {
            if isOverflowed(item.frame, parked: parked.contains(index), inventory: inventory) {
                placements.append(.overflow)
                overflowFrames.append(item.frame)
            } else {
                placements.append(nil)
            }
        }
        let reference = usableToggle(toggle, inventory: inventory, overflowFrames: overflowFrames)

        var order: [String] = []
        var entries: [String: MenuBarAppEntry] = [:]
        for (index, item) in inventory.items.enumerated() {
            if let bundle = item.bundleID, ownBundleIDs.contains(bundle) || systemItemOwners.contains(bundle) { continue }
            let placement = placements[index]
                ?? reference.map { placementOf(item.frame, toggle: $0, bands: inventory.bands, rightToLeft: rtl) } ?? .unknown
            let key = item.bundleID ?? "pid\(item.pid)"
            let laidOutX: CGFloat? = placements[index] == nil ? item.frame.minX : nil
            if var entry = entries[key] {
                entry.itemCount += 1
                entry.placement = min(entry.placement, placement)
                if let x = laidOutX { entry.minX = min(entry.minX ?? x, x) }
                if let detail = item.detail, !entry.details.contains(detail), entry.details.count < 3 { entry.details.append(detail) }
                entries[key] = entry
            } else {
                order.append(key)
                entries[key] = MenuBarAppEntry(key: key, bundleID: item.bundleID, pid: item.pid,
                                               name: item.name, itemCount: 1, placement: placement,
                                               isSystem: item.bundleID?.hasPrefix("com.apple.") ?? false, minX: laidOutX,
                                               details: item.detail.map { [$0] } ?? [])
            }
        }
        let apps = sortedForDisplay(order.compactMap { entries[$0] })
        let toggleOverflowed = reference == nil && toggle.map { t in
            t.width > 0 && t.height > 0 && (
                (!inventory.bands.isEmpty && !isInBar(t, bands: inventory.bands))
                || (inventory.overflowChevron.map { $0.width > 0 && overlapsX(t, $0) } ?? false)
                || overflowFrames.contains { abs($0.midY - t.midY) < 8 && (abs($0.maxX - t.maxX) < 1 || abs($0.minX - t.minX) < 0.5) })
        } == true
        return NativeLayout(apps: apps, toggleUsable: reference != nil, toggleOverflowed: toggleOverflowed)
    }

    /// The item is not laid out in the bar: outside every menu-bar strip (macOS 27 reports overflowed /
    /// turned-off items at the bottom of the screen), stacked on another item, or on the « button.
    static func isOverflowed(_ frame: CGRect, parked: Bool, inventory: MenuBarInventory) -> Bool {
        guard frame.width > 0 else { return true }
        if !inventory.bands.isEmpty && !isInBar(frame, bands: inventory.bands) { return true }
        if parked { return true }
        if let chevron = inventory.overflowChevron, chevron.width > 0, overlapsX(frame, chevron) { return true }
        return false
    }

    /// The vertical centre of `rect` (CG) is in a menu-bar strip — or up to one bar height ABOVE it: an
    /// auto-hidden menu bar (a full-screen app, or "自动隐藏和显示菜单栏") slides above its screen together
    /// with every item. Treating those items as "not in the bar" would hide every app on a collapse that
    /// happens while the bar is hidden, including the ones right of「<」.
    static func isInBar(_ rect: CGRect, bands: [CGRect], tolerance: CGFloat = 4) -> Bool {
        band(containing: rect, bands: bands, tolerance: tolerance) != nil
    }

    static func band(containing rect: CGRect, bands: [CGRect], tolerance: CGFloat = 4) -> CGRect? {
        let y = rect.midY
        return bands.first { y >= $0.minY - $0.height - tolerance && y <= $0.maxY + tolerance }
    }

    /// The toggle frame when it can serve as the boundary: laid out in a menu-bar strip, not on the «
    /// button and not parked together with overflowed items (right-aligned, macOS 27).
    static func usableToggle(_ toggle: CGRect?, inventory: MenuBarInventory, overflowFrames: [CGRect]) -> CGRect? {
        guard let toggle, toggle.width > 0, toggle.height > 0 else { return nil }
        if !inventory.bands.isEmpty && !isInBar(toggle, bands: inventory.bands) { return nil }
        if let chevron = inventory.overflowChevron, chevron.width > 0, overlapsX(toggle, chevron) { return nil }
        for frame in overflowFrames where abs(frame.midY - toggle.midY) < 8 {
            if abs(frame.maxX - toggle.maxX) < 1 || abs(frame.minX - toggle.minX) < 0.5 { return nil }
        }
        return toggle
    }

    /// Visible / hidden side of the toggle, compared as distances from the edge the status items are laid
    /// out from — the right edge of each one's screen, or the left edge in a right-to-left UI (with several
    /// displays the items may be on another screen than the toggle).
    public static func placementOf(_ frame: CGRect, toggle: CGRect, bands: [CGRect], rightToLeft: Bool = false) -> AppPlacement {
        let fallbackEdge = rightToLeft ? bands.map(\.minX).min() : bands.map(\.maxX).max()
        let toggleEdge = anchorEdge(of: toggle, bands: bands, rightToLeft: rightToLeft) ?? fallbackEdge ?? 0
        // An item outside every screen (pushed off-screen by another hider) is measured on the toggle's.
        let itemEdge = anchorEdge(of: frame, bands: bands, rightToLeft: rightToLeft) ?? toggleEdge
        func distance(_ rect: CGRect, from edge: CGFloat) -> CGFloat { rightToLeft ? rect.midX - edge : edge - rect.midX }
        return distance(frame, from: itemEdge) < distance(toggle, from: toggleEdge) ? .rightOfToggle : .leftOfToggle
    }

    /// The edge (right, or left when right-to-left) of the menu-bar strip containing `rect`'s centre (the
    /// vertical position picks the screen when displays are stacked; x alone when it matches no strip
    /// vertically).
    static func anchorEdge(of rect: CGRect, bands: [CGRect], rightToLeft: Bool = false) -> CGFloat? {
        guard let strip = strip(of: rect, bands: bands) else { return nil }
        return rightToLeft ? strip.minX : strip.maxX
    }

    /// The menu-bar strip of the screen `rect` is on: matched by x, then by y among side-by-side / stacked
    /// screens (x alone when no strip matches vertically).
    static func strip(of rect: CGRect, bands: [CGRect]) -> CGRect? {
        let x = rect.midX
        let horizontal = bands.filter { x >= $0.minX && x < $0.maxX }
        return band(containing: rect, bands: horizontal) ?? horizontal.first
    }

    /// The bar's direction read from the bar itself: macOS's clock / 控制中心 (never movable) sit at the end
    /// the status items are laid out from — the right end, or the left end in a right-to-left UI.
    /// nil when neither is in the inventory (e.g. while the screen is locked).
    public static func inferredRightToLeft(_ inventory: MenuBarInventory) -> Bool? {
        for item in inventory.items {
            guard let bundle = item.bundleID, systemItemOwners.contains(bundle),
                  let identifier = item.identifier, MenuBarItemScanner.immovableIdentifiers.contains(identifier),
                  item.frame.width > 0, isInBar(item.frame, bands: inventory.bands),
                  let strip = strip(of: item.frame, bands: inventory.bands) else { continue }
            return item.frame.midX - strip.minX < strip.maxX - item.frame.midX
        }
        return nil
    }

    /// The UI direction of the user's preferred language (the menu bar follows the system language, not
    /// OneSwitch's own localization).
    public static func preferredLanguageIsRightToLeft() -> Bool {
        guard let language = Locale.preferredLanguages.first else { return false }
        return NSLocale.characterDirection(forLanguage: language) == .rightToLeft
    }

    static func overlapsX(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && a.maxX > b.minX
    }
}

// MARK: - Plan (who is allowed while collapsed)

public struct NativeHidingPlan: Equatable, Sendable {
    /// Numeric identifiers of macOS's own items to keep: all of them (unknown ids are ignored; 0–63
    /// covers every item macOS 27.0 has).
    public static let systemItemsToKeep: [Int] = Array(0..<64)

    /// Bundle ids passed as allowed (sorted, unique).
    public var allowed: [String]
    /// Bundle ids of listed apps that will be hidden (sorted).
    public var hidden: [String]

    public init(allowed: [String], hidden: [String]) {
        self.allowed = allowed
        self.hidden = hidden
    }

    /// Whether an app is hidden while collapsed.
    public static func shouldHide(rule: AppVisibilityRule, placement: AppPlacement?, toggleOverflowed: Bool = false) -> Bool {
        switch rule {
        case .alwaysHide: return true
        case .alwaysShow: return false
        case .auto:
            if placement == .leftOfToggle || placement == .overflow { return true }
            // 「<」itself was pushed into the « (crowded, notched bar): every third-party app counts as left
            // of it — otherwise nothing gets hidden and「<」can never come back.
            return toggleOverflowed && placement == .unknown
        }
    }

    /// Builds the allow-list. Everything not allowed is hidden by macOS, so the list errs toward
    /// visible: every running app (and every app seen in the bar) is allowed unless its rule / position
    /// says hide. Our own app, macOS's item owners and 始终显示 apps (even when not running yet) are
    /// always allowed. An app launched after the restriction was activated is not in the list, so it
    /// stays hidden until the next expand.
    /// - Parameters:
    ///   - layout: last placement read from an unrestricted bar (nil = unknown, only rules apply).
    ///   - runningBundleIDs: bundle ids of the running apps that can own status items.
    ///   - preAllowed: apps seen right of the toggle in earlier sessions — allowed even when they are not
    ///     running yet (e.g. still launching at login), unless the current layout / rules hide them.
    public static func make(layout: NativeLayout?, rules: [String: AppVisibilityRule],
                            runningBundleIDs: [String], ownBundleIDs: [String],
                            preAllowed: [String] = []) -> NativeHidingPlan {
        let own = Set(ownBundleIDs)
        let running = Set(runningBundleIDs.filter { !$0.isEmpty })
        var hidden = Set<String>()
        var seen = Set<String>()
        for app in layout?.apps ?? [] {
            guard let bundle = app.bundleID else { continue } // no bundle id: cannot be targeted → keep visible
            seen.insert(bundle)
            // Apple's own agents (输入法, …) follow the same rules as any app — the user may have placed them
            // left of「<」on purpose — except that they are never hidden on a guess when「<」itself overflowed.
            if shouldHide(rule: rules[bundle] ?? .auto, placement: app.placement,
                          toggleOverflowed: (layout?.toggleOverflowed ?? false) && !app.isSystem) { hidden.insert(bundle) }
        }
        // 始终隐藏 apps that are not running are simply left out of the allow-list (hidden once they
        // start); `hidden` lists only the ones that are there now.
        for (bundle, rule) in rules where rule == .alwaysHide && (running.contains(bundle) || seen.contains(bundle)) {
            hidden.insert(bundle)
        }
        hidden.subtract(own)
        hidden.subtract(NativeLayoutResolver.systemItemOwners)

        var allowed = own.union(NativeLayoutResolver.systemItemOwners)
        allowed.formUnion(running)
        allowed.formUnion(seen)
        allowed.formUnion(rules.filter { $0.value == .alwaysShow }.map(\.key))
        allowed.formUnion(preAllowed.filter { !$0.isEmpty && rules[$0] != .alwaysHide })
        allowed.subtract(hidden)
        allowed.formUnion(own)
        return NativeHidingPlan(allowed: allowed.sorted(), hidden: hidden.sorted())
    }
}

// MARK: - Dependencies

/// One-shot main-actor timer (the checks inject a manual one).
public typealias NativeScheduler = @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void

/// Everything the native engine talks to (real objects in the app, fakes in the self-checks).
@MainActor
public struct NativeHidingDependencies {
    public var visibility: NativeVisibilityProviding
    public var inventory: MenuBarInventoryProviding
    /// Bundle ids of running apps that can own status items.
    public var runningBundleIDs: () -> [String]
    /// Our own bundle id(s): always allowed.
    public var ownBundleIDs: [String]
    /// Test hook: the toggle's frame in CG coordinates (default: read from our status item).
    public var toggleFrame: (() -> CGRect?)?
    /// Timer for the request timeouts.
    public var schedule: NativeScheduler
    /// Seconds a position read / an activation may stay unanswered before the request fails open (a
    /// request that never completes would otherwise leave the module "collapsed" with nothing hidden).
    public var snapshotTimeout: TimeInterval
    public var activationTimeout: TimeInterval
    /// Menu-bar direction when the bar itself does not tell (see `NativeLayoutResolver.inferredRightToLeft`).
    public var rightToLeft: () -> Bool
    /// The login session is locked (failures then do not count toward the 兼容模式 fallback).
    public var isSessionLocked: () -> Bool
    /// Reads the room on「<」's side of the bar when icons are revealed (see NativeReveal.swift). nil = the
    /// room cannot be told: expanding releases the restriction (shows everything), as it always did.
    public var revealProbe: NativeRevealProbing?
    /// Frames (CG) of all our own status items (系统监控, main icon…); nil = only the toggle is known.
    public var ownItemFrames: (@MainActor () -> [CGRect])?
    /// Seconds the reveal probe may take before expanding falls back to showing everything.
    public var revealProbeTimeout: TimeInterval
    /// Delay before a freshly granted restriction is measured (macOS needs a moment to reflow the bar).
    public var settleDelay: TimeInterval
    /// 点击时钟打开通知中心 (see NotificationCenterAssist.swift); nil = not wired in (the feature is off).
    public var clockAssist: NotificationCenterAssistDependencies?

    public init(visibility: NativeVisibilityProviding, inventory: MenuBarInventoryProviding,
                runningBundleIDs: @escaping () -> [String], ownBundleIDs: [String],
                toggleFrame: (() -> CGRect?)? = nil,
                schedule: @escaping NativeScheduler = { delay, action in
                    DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) {
                        MainActor.assumeIsolated { action() }
                    }
                },
                snapshotTimeout: TimeInterval = 10, activationTimeout: TimeInterval = 5,
                rightToLeft: @escaping () -> Bool = { false },
                isSessionLocked: @escaping () -> Bool = { false },
                revealProbe: NativeRevealProbing? = nil,
                ownItemFrames: (@MainActor () -> [CGRect])? = nil,
                revealProbeTimeout: TimeInterval = 1, settleDelay: TimeInterval = 0.8,
                clockAssist: NotificationCenterAssistDependencies? = nil) {
        self.visibility = visibility
        self.inventory = inventory
        self.runningBundleIDs = runningBundleIDs
        self.ownBundleIDs = ownBundleIDs
        self.toggleFrame = toggleFrame
        self.schedule = schedule
        self.snapshotTimeout = snapshotTimeout
        self.activationTimeout = activationTimeout
        self.rightToLeft = rightToLeft
        self.isSessionLocked = isSessionLocked
        self.revealProbe = revealProbe
        self.ownItemFrames = ownItemFrames
        self.revealProbeTimeout = revealProbeTimeout
        self.settleDelay = settleDelay
        self.clockAssist = clockAssist
    }

    /// The console session's screen is locked (or the session is not on the console).
    public nonisolated static func sessionIsLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (dict["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        return (dict[kCGSessionOnConsoleKey as String] as? Bool) == false
    }

    /// The real restriction + Accessibility inventory.
    public static func system() -> NativeHidingDependencies {
        NativeHidingDependencies(visibility: SystemMenuBarVisibility(),
                                 inventory: AccessibilityMenuBarInventory(),
                                 runningBundleIDs: { runningAppBundleIDs() },
                                 ownBundleIDs: defaultOwnBundleIDs(),
                                 rightToLeft: { NativeLayoutResolver.preferredLanguageIsRightToLeft() },
                                 isSessionLocked: { sessionIsLocked() },
                                 revealProbe: { request, completion in NativeRevealProbeReader.read(request, completion: completion) },
                                 ownItemFrames: { NativeRevealProbeReader.ownStatusItemFrames() },
                                 clockAssist: .system())
    }

    /// Running regular / accessory apps (background-only processes cannot own status items).
    public static func runningAppBundleIDs() -> [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited && !$0.isTerminated }
            .compactMap(\.bundleIdentifier)
    }

    public nonisolated static func defaultOwnBundleIDs() -> [String] {
        var ids = [AppEnvironment.bundleIdentifier]
        if let main = Bundle.main.bundleIdentifier, !ids.contains(main) { ids.insert(main, at: 0) }
        return ids
    }
}
