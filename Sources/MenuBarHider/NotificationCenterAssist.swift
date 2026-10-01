import AppKit
import ApplicationServices
import CoreGraphics
import OneSwitchCore

// 点击时钟打开通知中心 while icons are hidden (系统原生隐藏, macOS 27+).
//
// The native restriction is macOS's exam ("assessment") mode: MenuBarAgent then treats the bar as locked
// down and ignores clicks on the date / time — Notification Center does not open while a restriction is
// held (collapsed, and on a notched MacBook Pro also while expanded: a partial reveal keeps a restriction).
// No other restriction type is reachable, and Hidden Bar has the same limitation, so this works around it
// transparently:
//
// 1. A listen-only global monitor sees a left click in a menu bar while a restriction is held (nothing is
//    swallowed or changed on the way to MenuBarAgent).
// 2. Where the clock is, is read through Accessibility right then (MenuBarAgent's items, off the main
//    thread); a click on anything else is ignored — also one where the menu bar is not on screen at all (a
//    full-screen app, a menu bar that hides itself): the strip then belongs to the window underneath.
// 3. On the clock: the restriction is released at once (like 显示全部, but without the auto-hide timer).
// 4. Once the button is up, plus `decisionDelay`: if Notification Center reacted to the click by itself
//    (the release was quick enough), nothing else happens; otherwise ONE click, tagged with
//    `ClockClickPoster.userDataTag` (ignored by our own monitor), is posted on the clock so it opens.
//    Pressed again before that (a double click — its second press may reach the clock by itself once the
//    restriction is gone): the decision waits until that press is over and is taken for it; a press
//    somewhere else, a ⌘ / ⌃ press, a long press or a decision that comes far too late (sleep) posts nothing.
// 5. While Notification Center is open the bar stays unrestricted; it is polled every `pollInterval` —
//    only during such an episode — and once it closed (and the user is not busy in the menu bar) the
//    previous state comes back: the collapsed restriction, or the partial reveal.
//
// Any other change of the menu bar in between (toggle click, hotkey, menu, settings) ends the episode
// without restoring anything: the user's action wins.
//
// `NotificationCenterClockAssist` is pure logic driven through injected dependencies (the self-checks use
// fakes, no real click is ever posted there); `NotificationCenterAssistDependencies.system()` has the real
// monitor, readers and poster.

// MARK: - Values

/// A left-button event seen by the listen-only monitor (CG global coordinates).
public struct ClockAssistMouseEvent: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case down, up
    }

    public var kind: Kind
    public var location: CGPoint
    /// Posted by OneSwitch itself (tagged with `ClockClickPoster.userDataTag`): never acted upon.
    public var synthetic: Bool
    /// ⌘ or ⌃ was held (a ⌘-drag to rearrange icons, a context click): not a request for Notification Center.
    public var modified: Bool

    public init(kind: Kind, location: CGPoint, synthetic: Bool = false, modified: Bool = false) {
        self.kind = kind
        self.location = location
        self.synthetic = synthetic
        self.modified = modified
    }
}

/// What was found where the user clicked.
public struct ClockClickProbe: Equatable, Sendable {
    /// Frame (CG) of the clock under the click; nil = the click was not on the clock (or it is unknown).
    public var clock: CGRect?
    /// Notification Center was open when the click was examined.
    public var notificationCenterOpen: Bool

    public init(clock: CGRect?, notificationCenterOpen: Bool) {
        self.clock = clock
        self.notificationCenterOpen = notificationCenterOpen
    }
}

/// The state the bar returns to once Notification Center closed.
public enum ClockAssistPrevious: String, Equatable, Sendable {
    /// Collapsed: the restriction that hides the icons.
    case collapsed
    /// Expanded, showing only the hidden icons that fit (a restriction was still held).
    case revealed
}

// MARK: - Finding the clock

public enum ClockLocator {
    /// Accessibility identifier of macOS's date / time item.
    public static let clockIdentifier = "com.apple.menuextra.clock"

    /// Identifiers of macOS's other menu extras. Never taken for the clock by the right-most fallback: when one
    /// of them is at the edge, the clock was simply not reported (Control Center always sits next to it) — a
    /// click posted there would close the panel the user just opened.
    public static let otherExtraIdentifiers: Set<String> = [
        "com.apple.menuextra.controlcenter", "com.apple.menuextra.wifi", "com.apple.menuextra.battery",
        "com.apple.menuextra.bluetooth", "com.apple.menuextra.sound", "com.apple.menuextra.focusmode",
        "com.apple.menuextra.spotlight", "com.apple.menuextra.siri", "com.apple.menuextra.textinput",
        "com.apple.menuextra.user", "com.apple.menuextra.airdrop", "com.apple.menuextra.display",
        "com.apple.menuextra.screenmirroring", "com.apple.menuextra.nowplaying",
    ]
    /// Labels of the clock item (its description) when it carries no identifier.
    static let clockLabels: Set<String> = ["时钟", "時鐘", "clock"]

    /// macOS's own clock item: by identifier; by its label only when it has none (a label that merely
    /// contains "clock" — a timer, a world clock — is not enough).
    public static func isClock(_ item: MenuBarItemInfo) -> Bool {
        guard let bundle = item.bundleID, NativeLayoutResolver.systemItemOwners.contains(bundle) else { return false }
        if let identifier = item.identifier?.lowercased(), !identifier.isEmpty {
            return identifier == clockIdentifier || identifier.hasSuffix(".clock")
        }
        return [item.name, item.detail].compactMap { $0?.trimmingCharacters(in: .whitespaces).lowercased() }
            .contains(where: clockLabels.contains)
    }

    /// Where the clock is in each menu bar:
    /// 1. the clock item(s) found (by identifier / label);
    /// 2. on a display where none was recognised, macOS's own item nearest the status-item edge (right-most;
    ///    left-most right-to-left), which is where the clock always sits — unless that item is known to be
    ///    another extra;
    /// 3. with `projectToOtherDisplays` (each display has its own menu bar), on a display where macOS reported
    ///    nothing usable: the clock found on another display, at the same distance from the status-item edge
    ///    (every menu bar lays its status items out from that edge).
    public static func clockFrames(items: [MenuBarItemInfo], bands: [CGRect], rightToLeft: Bool,
                                   projectToOtherDisplays: Bool = false) -> [CGRect] {
        let laidOut = items.filter { $0.frame.width > 0 && $0.frame.height > 0 }
        var frames: [CGRect] = []
        var covered = Set<Int>()
        var reference: (frame: CGRect, band: CGRect)?
        for item in laidOut where isClock(item) {
            guard let index = bandIndex(of: item.frame, bands: bands), !covered.contains(index) else { continue }
            frames.append(item.frame)
            covered.insert(index)
            if reference == nil { reference = (item.frame, bands[index]) }
        }
        for index in bands.indices where !covered.contains(index) {
            let system = laidOut.filter { item in
                (item.bundleID.map(NativeLayoutResolver.systemItemOwners.contains) ?? false)
                    && bandIndex(of: item.frame, bands: bands) == index
            }
            let edge = rightToLeft ? system.min { $0.frame.minX < $1.frame.minX } : system.max { $0.frame.maxX < $1.frame.maxX }
            guard let edge, !(edge.identifier.map { otherExtraIdentifiers.contains($0.lowercased()) } ?? false) else { continue }
            frames.append(edge.frame)
            covered.insert(index)
        }
        if projectToOtherDisplays, let reference {
            for index in bands.indices where !covered.contains(index) {
                let band = bands[index]
                let x = rightToLeft ? band.minX + (reference.frame.minX - reference.band.minX)
                                    : band.maxX - (reference.band.maxX - reference.frame.minX)
                let projected = CGRect(x: x, y: band.minY, width: reference.frame.width, height: band.height)
                guard projected.minX >= band.minX, projected.maxX <= band.maxX else { continue }
                frames.append(projected)
            }
        }
        return frames
    }

    /// The clock frame containing `point` (CG), nil when the click was elsewhere.
    public static func clock(at point: CGPoint, items: [MenuBarItemInfo], bands: [CGRect], rightToLeft: Bool,
                             projectToOtherDisplays: Bool = false) -> CGRect? {
        clockFrames(items: items, bands: bands, rightToLeft: rightToLeft, projectToOtherDisplays: projectToOtherDisplays)
            .first { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }

    /// `point` (CG) lies in one of the menu-bar strips.
    public static func isInMenuBar(_ point: CGPoint, bands: [CGRect]) -> Bool {
        bands.contains { point.x >= $0.minX && point.x < $0.maxX && point.y >= $0.minY - 2 && point.y <= $0.maxY + 1 }
    }

    /// Window level macOS draws the menu bar at (Window Server's "Menubar" and MenuBarAgent's window: 24,
    /// measured on macOS 27).
    public static let menuBarWindowLevel = Int(CGWindowLevelForKey(.mainMenuWindow))

    /// The menu bar is really on screen at `point` (CG): a window at the menu-bar level covers it. Not so in a
    /// full-screen app, or while the menu bar hides itself (「自动隐藏和显示菜单栏」) — the strip then belongs to
    /// the window underneath, and a click of ours there would click into that app.
    public static func menuBarShown(at point: CGPoint, windows: [WindowSummary]) -> Bool {
        windows.contains { $0.layer == menuBarWindowLevel && $0.alpha > 0.01 && $0.bounds.insetBy(dx: -1, dy: -1).contains(point) }
    }

    /// Reads the on-screen window list (blocking: call off the main thread).
    public static func menuBarShown(at point: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return menuBarShown(at: point, windows: WindowSummary.parse(list))
    }

    /// The strip `rect` (CG) is laid out in.
    static func bandIndex(of rect: CGRect, bands: [CGRect]) -> Int? {
        bands.firstIndex { rect.midX >= $0.minX && rect.midX < $0.maxX && rect.midY >= $0.minY - 4 && rect.midY <= $0.maxY + 4 }
    }
}

// MARK: - Is Notification Center open?

/// One on-screen window, as far as the Notification Center check needs it.
public struct WindowSummary: Equatable, Sendable {
    public var pid: pid_t
    public var layer: Int
    public var bounds: CGRect
    public var alpha: Double

    public init(pid: pid_t, layer: Int, bounds: CGRect, alpha: Double = 1) {
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
        self.alpha = alpha
    }

    /// The windows of a `CGWindowListCopyWindowInfo` result.
    public static func parse(_ list: [[String: Any]]) -> [WindowSummary] {
        list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
            return WindowSummary(pid: pid, layer: layer, bounds: bounds, alpha: alpha)
        }
    }
}

public enum NotificationCenterDetector {
    public static let bundleID = "com.apple.notificationcenterui"
    /// Smaller windows are notification banners, not the panel.
    public static let minimumPanelSize = CGSize(width: 200, height: 300)

    /// Processes of Notification Center (normally one).
    @MainActor
    public static func processIDs() -> Set<pid_t> {
        Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }.map(\.processIdentifier))
    }

    /// Notification Center shows its panel: an on-screen window of its process above normal windows (desktop
    /// widgets sit below them) and panel-sized. Measured on macOS 27: one window at level 21 with the frame of
    /// the whole display, ordered out while nothing is shown. The same window also carries what Notification
    /// Center shows outside the panel — measured: the notification list of the lock screen (on screen for as
    /// long as the screen is locked with a notification); very likely banners and alerts too — so while the
    /// session is locked it never counts (the panel cannot be open then), and otherwise a banner / an alert
    /// counts as "open" (the bar then stays shown, or the auto-hide waits, until it is gone).
    public static func isOpen(windows: [WindowSummary], processIDs: Set<pid_t>, sessionLocked: Bool = false) -> Bool {
        guard !sessionLocked else { return false }
        return windows.contains { window in
            processIDs.contains(window.pid) && window.layer > 0 && window.alpha > 0.01
                && window.bounds.width >= minimumPanelSize.width && window.bounds.height >= minimumPanelSize.height
        }
    }

    /// Reads the on-screen window list (blocking: call off the main thread).
    public static func isOpen(processIDs: Set<pid_t>) -> Bool {
        guard !processIDs.isEmpty, !NativeHidingDependencies.sessionIsLocked(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return isOpen(windows: windows(from: list, processIDs: processIDs), processIDs: processIDs)
    }

    /// The windows of `processIDs` in a `CGWindowListCopyWindowInfo` result.
    public static func windows(from list: [[String: Any]], processIDs: Set<pid_t>) -> [WindowSummary] {
        WindowSummary.parse(list).filter { processIDs.contains($0.pid) }
    }
}

// MARK: - Dependencies

/// Everything the assist talks to (real objects in the app, fakes in the self-checks).
@MainActor
public struct NotificationCenterAssistDependencies {
    public typealias Remover = @MainActor () -> Void

    /// Installs a listen-only monitor of left-button down / up anywhere; returns what removes it.
    public var monitorClicks: @MainActor (_ handler: @escaping @MainActor (ClockAssistMouseEvent) -> Void) -> Remover
    /// Is `point` (CG) on the clock, and is Notification Center open? Completion on the main actor.
    public var probeClick: @MainActor (_ point: CGPoint, _ completion: @escaping @MainActor (ClockClickProbe?) -> Void) -> Void
    /// Is Notification Center open right now? Completion on the main actor.
    public var notificationCenterOpen: @MainActor (_ completion: @escaping @MainActor (Bool) -> Void) -> Void
    /// Posts one tagged click (down + up) at `point` (CG).
    public var postClick: @MainActor (_ point: CGPoint) -> Void
    /// The pointer (CG).
    public var pointerLocation: @MainActor () -> CGPoint
    /// Menu-bar strips of all displays (CG).
    public var menuBarBands: @MainActor () -> [CGRect]
    /// Whether the user is busy in the menu bar (a menu open, pointer in the bar…); nil = the controller's
    /// own interaction probe (the one that postpones the auto-hide).
    public var isInteracting: (@MainActor (_ completion: @escaping @MainActor (Bool) -> Void) -> Void)?
    /// One-shot timer (default: main-run-loop timers that also fire while a menu is tracking).
    public var schedule: AutoCollapseDriver.Scheduler
    public var now: () -> Date
    /// Waits until a click being posted is complete (never leave the button down on stop).
    public var drain: @MainActor () -> Void
    /// After the button is up: time Notification Center gets to react to the click by itself.
    public var decisionDelay: TimeInterval
    /// Notification Center is checked this often while an episode lasts.
    public var pollInterval: TimeInterval
    /// Without Notification Center ever seen open, the previous state comes back after this long.
    public var openGrace: TimeInterval
    /// The button still down after this long: no click is posted for it.
    public var buttonUpTimeout: TimeInterval
    /// A clock lookup that answers later than this is stale.
    public var staleClick: TimeInterval

    public init(monitorClicks: @escaping @MainActor (_ handler: @escaping @MainActor (ClockAssistMouseEvent) -> Void) -> Remover,
                probeClick: @escaping @MainActor (_ point: CGPoint, _ completion: @escaping @MainActor (ClockClickProbe?) -> Void) -> Void,
                notificationCenterOpen: @escaping @MainActor (_ completion: @escaping @MainActor (Bool) -> Void) -> Void,
                postClick: @escaping @MainActor (_ point: CGPoint) -> Void,
                pointerLocation: @escaping @MainActor () -> CGPoint,
                menuBarBands: @escaping @MainActor () -> [CGRect],
                isInteracting: (@MainActor (_ completion: @escaping @MainActor (Bool) -> Void) -> Void)? = nil,
                schedule: AutoCollapseDriver.Scheduler? = nil,
                now: @escaping () -> Date = { Date() },
                drain: @escaping @MainActor () -> Void = {},
                decisionDelay: TimeInterval = 0.12, pollInterval: TimeInterval = 0.3, openGrace: TimeInterval = 1,
                buttonUpTimeout: TimeInterval = 1.5, staleClick: TimeInterval = 1) {
        self.monitorClicks = monitorClicks
        self.probeClick = probeClick
        self.notificationCenterOpen = notificationCenterOpen
        self.postClick = postClick
        self.pointerLocation = pointerLocation
        self.menuBarBands = menuBarBands
        self.isInteracting = isInteracting
        self.schedule = schedule ?? AutoCollapseDriver.runLoopScheduler
        self.now = now
        self.drain = drain
        self.decisionDelay = decisionDelay
        self.pollInterval = pollInterval
        self.openGrace = openGrace
        self.buttonUpTimeout = buttonUpTimeout
        self.staleClick = staleClick
    }

    /// The real monitor (NSEvent global monitor, listen-only), readers (Accessibility, window list — off the
    /// main thread) and poster.
    public static func system() -> NotificationCenterAssistDependencies {
        let queue = DispatchQueue(label: "oneswitch.menubar.clockassist", qos: .userInitiated)
        return NotificationCenterAssistDependencies(
            monitorClicks: { handler in
                let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
                    guard let cg = event.cgEvent else { return }
                    let mouse = ClockAssistMouseEvent(
                        kind: event.type == .leftMouseDown ? .down : .up, location: cg.location,
                        synthetic: cg.getIntegerValueField(.eventSourceUserData) == ClockClickPoster.userDataTag,
                        modified: !cg.flags.intersection([.maskCommand, .maskControl]).isEmpty)
                    if Thread.isMainThread {
                        MainActor.assumeIsolated { handler(mouse) }
                    } else {
                        DispatchQueue.main.async { MainActor.assumeIsolated { handler(mouse) } }
                    }
                }
                if monitor == nil { AppLog.warning("menubar", "clock assist: the click monitor could not be installed") }
                return { if let monitor { NSEvent.removeMonitor(monitor) } }
            },
            probeClick: { point, completion in
                let bands = currentMenuBarBands()
                let fallbackRTL = NativeLayoutResolver.preferredLanguageIsRightToLeft()
                let owners = NativeLayoutResolver.systemItemOwners.sorted().flatMap { bundle in
                    NSRunningApplication.runningApplications(withBundleIdentifier: bundle).filter { !$0.isTerminated }.map {
                        RunningAppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? bundle, bundleID: bundle)
                    }
                }
                let center = NotificationCenterDetector.processIDs()
                let ownPID = getpid()
                // Without separate Spaces only the main display has a menu bar: nothing is projected elsewhere.
                let separateMenuBars = NSScreen.screensHaveSeparateSpaces
                queue.async {
                    let open = NotificationCenterDetector.isOpen(processIDs: center)
                    // A full-screen app / a menu bar that hides itself: the click belongs to the window underneath.
                    guard ClockLocator.menuBarShown(at: point) else {
                        let probe = ClockClickProbe(clock: nil, notificationCenterOpen: open)
                        DispatchQueue.main.async { MainActor.assumeIsolated { completion(probe) } }
                        return
                    }
                    let items = AXIsProcessTrusted() ? MenuBarItemScanner.scanAccessibility(apps: owners, excludingPID: ownPID).items : []
                    let rtl = NativeLayoutResolver.inferredRightToLeft(MenuBarInventory(items: items, bands: bands)) ?? fallbackRTL
                    let clock = ClockLocator.clock(at: point, items: items, bands: bands, rightToLeft: rtl,
                                                   projectToOtherDisplays: separateMenuBars)
                    let probe = ClockClickProbe(clock: clock, notificationCenterOpen: open)
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion(probe) } }
                }
            },
            notificationCenterOpen: { completion in
                let center = NotificationCenterDetector.processIDs()
                queue.async {
                    let open = NotificationCenterDetector.isOpen(processIDs: center)
                    DispatchQueue.main.async { MainActor.assumeIsolated { completion(open) } }
                }
            },
            postClick: { point in ClockClickPoster.post(at: point) },
            pointerLocation: {
                if let location = CGEvent(source: nil)?.location { return location }
                let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
                return MenuBarGeometry.toAppKit(NSEvent.mouseLocation, primaryMaxY: primaryMaxY) // symmetric flip
            },
            menuBarBands: { currentMenuBarBands() },
            drain: { ClockClickPoster.waitUntilIdle() })
    }

    @MainActor
    static func currentMenuBarBands() -> [CGRect] {
        MenuBarGeometry.menuBarBands(screens: ScreenGeometry.current(), thickness: NSStatusBar.system.thickness)
    }
}

// MARK: - Posting the click

/// Posts one left click at the HID level, tagged so our own monitor (and anyone who checks) can tell it
/// apart. Needs 辅助功能. Never used by the self-checks.
public enum ClockClickPoster {
    /// `kCGEventSourceUserData` of our clicks ('ONNC').
    public static let userDataTag: Int64 = 0x4F4E_4E43
    private static let queue = DispatchQueue(label: "oneswitch.menubar.clockclick", qos: .userInteractive)

    /// Posts mouse down + up at `point` (CG). When the pointer is somewhere else it is put back afterwards.
    /// Nothing is posted when the menu bar is not on screen there any more (it hid itself meanwhile): the
    /// click would land in the window underneath.
    public static func post(at point: CGPoint) {
        queue.async {
            guard ClockLocator.menuBarShown(at: point) else {
                AppLog.info("menubar", "clock assist: the menu bar is not shown at the clock any more; no click posted")
                return
            }
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            source.userData = userDataTag
            // Both events exist before anything is posted: the button can never be left down.
            guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
                AppLog.warning("menubar", "clock assist: could not create the click events")
                return
            }
            for event in [down, up] {
                event.setIntegerValueField(.mouseEventClickState, value: 1)
                event.setIntegerValueField(.eventSourceUserData, value: userDataTag)
                event.flags = []
            }
            let saved = CGEvent(source: nil)?.location
            down.post(tap: .cghidEventTap)
            usleep(30_000)
            up.post(tap: .cghidEventTap)
            if let saved, hypot(saved.x - point.x, saved.y - point.y) > 0.5 {
                CGWarpMouseCursorPosition(saved)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }
    }

    /// Blocks until a click being posted is complete (≤ 50 ms).
    public static func waitUntilIdle() {
        queue.sync {}
    }
}

// MARK: - The state machine

/// See the top of this file. Main-actor, pure: everything it does goes through the injected dependencies
/// and the controller's hooks.
@MainActor
public final class NotificationCenterClockAssist {
    public enum Phase: String, Equatable, Sendable {
        case idle
        /// A click in a menu bar: finding out whether it was on the clock.
        case locating
        /// The restriction was released for the clock click; waiting for the button to come up and for
        /// Notification Center to react.
        case released
        /// Notification Center is (or should be) open; the previous state comes back once it closed.
        case watching
    }

    /// The restriction is held and the feature is on (asked on every click and again before releasing).
    public var canEngage: () -> Bool = { false }
    /// Releases the restriction; returns the state to restore later (nil = could not).
    public var engage: () -> ClockAssistPrevious? = { nil }
    /// Puts `previous` back.
    public var restore: (ClockAssistPrevious) -> Void = { _ in }
    /// The user is busy in the menu bar: restoring waits (see `NotificationCenterAssistDependencies.isInteracting`).
    public var isInteracting: (@escaping @MainActor (Bool) -> Void) -> Void = { $0(false) }
    public var onPhaseChange: ((Phase) -> Void)?

    public private(set) var phase: Phase = .idle {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }
    /// What comes back once Notification Center closed (nil while idle / locating).
    public private(set) var previous: ClockAssistPrevious?
    /// The clock that was clicked (CG).
    public private(set) var clockFrame: CGRect?
    /// Episodes in which the restriction was released, and clicks posted (for logs and the checks).
    public private(set) var engagements = 0
    public private(set) var syntheticClicks = 0

    /// The restriction is released on the assist's behalf.
    public var isEngaged: Bool { phase == .released || phase == .watching }

    private let deps: NotificationCenterAssistDependencies
    /// Identity of the current episode: answers and timers of an earlier one are ignored.
    private var episode = 0
    private var cancelTimer: (() -> Void)?
    private var downAt: Date?
    /// When the button came up after the latest press (nil while it is down).
    private var upAt: Date?
    private var buttonUp = false
    /// Presses in this episode (the first included): a Notification Center reading only decides for the
    /// press it was taken after.
    private var presses = 0
    /// The latest press (the first one, or a second press of a double click / a click elsewhere right after).
    private var lastPress: ClockAssistMouseEvent?
    private var openAtClick = false
    private var sawOpen = false
    private var watchingSince: Date?

    public init(dependencies: NotificationCenterAssistDependencies) {
        self.deps = dependencies
    }

    /// One event from the monitor.
    public func handle(_ event: ClockAssistMouseEvent) {
        guard !event.synthetic else { return } // our own click
        switch event.kind {
        case .down:
            switch phase {
            case .idle:
                // ⌘ (rearranging icons) and ⌃ (context click) presses are no request for Notification Center.
                guard !event.modified, canEngage(), ClockLocator.isInMenuBar(event.location, bands: deps.menuBarBands()) else { return }
                startLocating(event)
            case .locating, .released:
                pressedAgain(event)
            case .watching:
                return // the bar is unrestricted: clicks reach macOS as usual
            }
        case .up:
            guard phase == .locating || phase == .released, !buttonUp else { return }
            buttonUp = true
            upAt = deps.now()
            if phase == .released { arm(deps.decisionDelay) { [weak self] in self?.decide() } }
        }
    }

    /// Pressed again before anything was decided — the second press of a double click (it may reach the
    /// clock itself once the restriction is gone, so a posted click would undo it), or a click somewhere
    /// else right after. Nothing is decided while the button is down; afterwards the latest press decides.
    private func pressedAgain(_ event: ClockAssistMouseEvent) {
        presses += 1
        lastPress = event
        buttonUp = false
        upAt = nil
        if phase == .released { arm(deps.buttonUpTimeout) { [weak self] in self?.buttonHeld() } }
    }

    /// `press` is a plain press on `clock` (not ⌘ / ⌃, not somewhere else).
    static func isPlainPress(_ press: ClockAssistMouseEvent, on clock: CGRect) -> Bool {
        !press.modified && clock.insetBy(dx: -1, dy: -1).contains(press.location)
    }

    /// Ends the episode (a user action, the feature switched off, stop). `restore`: put the previous state
    /// back (only if the restriction was released for it).
    public func cancel(restore: Bool, reason: String) {
        guard phase != .idle else { return }
        finish(restore: restore, reason: reason)
    }

    // MARK: Steps

    private func startLocating(_ press: ClockAssistMouseEvent) {
        reset()
        phase = .locating
        downAt = deps.now()
        presses = 1
        lastPress = press
        let current = episode
        deps.probeClick(press.location) { [weak self] probe in self?.located(probe, episode: current) }
    }

    private func located(_ probe: ClockClickProbe?, episode current: Int) {
        guard current == episode, phase == .locating else { return }
        guard let probe, let clock = probe.clock else {
            finish(restore: false, reason: nil) // not the clock
            return
        }
        if let downAt, deps.now().timeIntervalSince(downAt) > deps.staleClick {
            AppLog.info("menubar", "clock assist: the clock was found too late (\(Int(deps.now().timeIntervalSince(downAt) * 1000)) ms); ignoring the click")
            finish(restore: false, reason: nil)
            return
        }
        if let lastPress, !Self.isPlainPress(lastPress, on: clock) {
            AppLog.info("menubar", "clock assist: pressed somewhere else right after the clock; ignoring the click")
            finish(restore: false, reason: nil)
            return
        }
        guard canEngage(), let previous = engage() else {
            finish(restore: false, reason: nil)
            return
        }
        self.previous = previous
        clockFrame = clock
        openAtClick = probe.notificationCenterOpen
        engagements += 1
        phase = .released
        AppLog.info("menubar", "clock assist: the clock was clicked while icons are hidden (\(previous.rawValue)"
                    + "\(openAtClick ? ", Notification Center open" : "")); every icon shown so Notification Center can open")
        if buttonUp {
            arm(deps.decisionDelay) { [weak self] in self?.decide() }
        } else {
            arm(deps.buttonUpTimeout) { [weak self] in self?.buttonHeld() }
        }
    }

    /// Long press: nothing is clicked for it; the previous state comes back as usual.
    private func buttonHeld() {
        guard phase == .released, !buttonUp else { return }
        AppLog.info("menubar", "clock assist: the button is still down; no click is posted")
        startWatching(sawOpen: openAtClick)
    }

    /// Notification Center reacted to the click by itself (it changed since the click) — or it gets one click.
    private func decide() {
        guard phase == .released, buttonUp else { return }
        let current = episode, press = presses
        deps.notificationCenterOpen { [weak self] open in
            // Pressed again while this was read: that press decides once it is over.
            guard let self, current == self.episode, self.phase == .released, press == self.presses, self.buttonUp else { return }
            let late = self.upAt.map { self.deps.now().timeIntervalSince($0) } ?? 0
            if open != self.openAtClick {
                AppLog.info("menubar", "clock assist: Notification Center \(open ? "opened" : "closed") by the click itself")
            } else if let last = self.lastPress, let clock = self.clockFrame, !Self.isPlainPress(last, on: clock) {
                AppLog.info("menubar", "clock assist: the last press was not on the clock; no click is posted")
            } else if late > self.deps.staleClick {
                // E.g. the Mac slept right after the click, or the window list did not answer: far too late.
                AppLog.info("menubar", "clock assist: \(Int(late * 1000)) ms after the click; too late to click the clock")
            } else if let clock = self.clockFrame {
                // Where the user clicked, unless the pointer has left the clock since.
                let pointer = self.deps.pointerLocation()
                let point = clock.insetBy(dx: 1, dy: 1).contains(pointer) ? pointer : CGPoint(x: clock.midX, y: clock.midY)
                self.syntheticClicks += 1
                self.deps.postClick(point)
                AppLog.info("menubar", "clock assist: clicking the clock at (\(Int(point.x)), \(Int(point.y))) "
                            + "to \(open ? "close" : "open") Notification Center")
            }
            self.startWatching(sawOpen: open || self.openAtClick)
        }
    }

    private func startWatching(sawOpen: Bool) {
        phase = .watching
        self.sawOpen = sawOpen
        watchingSince = deps.now()
        arm(deps.pollInterval) { [weak self] in self?.poll() }
    }

    private func poll() {
        guard phase == .watching else { return }
        let current = episode
        deps.notificationCenterOpen { [weak self] open in
            guard let self, current == self.episode, self.phase == .watching else { return }
            if open {
                self.sawOpen = true
                self.arm(self.deps.pollInterval) { [weak self] in self?.poll() }
                return
            }
            let waited = self.watchingSince.map { self.deps.now().timeIntervalSince($0) } ?? .infinity
            guard self.sawOpen || waited >= self.deps.openGrace - 0.001 else {
                self.arm(self.deps.pollInterval) { [weak self] in self?.poll() } // may still be opening
                return
            }
            self.isInteracting { [weak self] busy in
                guard let self, current == self.episode, self.phase == .watching else { return }
                if busy {
                    // Like the auto-hide: not while a menu is open or the pointer is in the bar.
                    self.arm(self.deps.pollInterval) { [weak self] in self?.poll() }
                    return
                }
                self.finish(restore: true, reason: self.sawOpen ? "Notification Center closed" : "Notification Center did not open")
            }
        }
    }

    private func finish(restore: Bool, reason: String?) {
        let previous = self.previous
        let engaged = isEngaged
        reset()
        guard engaged else { return }
        if let reason {
            AppLog.info("menubar", "clock assist: \(reason); "
                        + (restore ? "restoring \(previous?.rawValue ?? "?")" : "the menu bar is left as it is"))
        }
        if restore, let previous { self.restore(previous) }
    }

    private func reset() {
        episode += 1
        cancelTimer?()
        cancelTimer = nil
        previous = nil
        clockFrame = nil
        downAt = nil
        upAt = nil
        presses = 0
        lastPress = nil
        buttonUp = false
        openAtClick = false
        sawOpen = false
        watchingSince = nil
        phase = .idle
    }

    /// One timer at a time; it belongs to the current episode.
    private func arm(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        cancelTimer?()
        let current = episode
        cancelTimer = deps.schedule(delay) { [weak self] in
            guard let self, current == self.episode else { return }
            self.cancelTimer = nil
            action()
        }
    }
}
