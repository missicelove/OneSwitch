import AppKit
import Combine
import OneSwitchCore
import SwiftUI

/// Whether the detail popover stays open while the user works in other apps (e.g. to watch the GPU
/// while a model runs). Observed by the popover's pin button.
@MainActor
final class PopoverPinState: ObservableObject {
    @Published var isPinned = false
}

/// Calls `onLeave` (once) when the observed status-item window has left every screen for `grace`
/// seconds — e.g. the 菜单栏图标 hider collapsed (by default automatically after 10 s) and pushed the
/// item out of the bar. A popover anchored there is invisible, yet a pinned one would stay open for good
/// and keep every metric and `ps` running each interval. The grace period ignores transient layouts
/// (the items moving to another display's menu bar).
@MainActor
final class AnchorWatcher {
    private var observers: [NSObjectProtocol] = []
    private weak var window: NSWindow?
    private let screens: () -> [CGRect]
    private let grace: TimeInterval
    private var onLeave: (() -> Void)?
    private var pending = false

    init(window: NSWindow, grace: TimeInterval = 1.5, screens: @escaping () -> [CGRect] = { NSScreen.screens.map(\.frame) },
         onLeave: @escaping () -> Void) {
        self.window = window
        self.grace = grace
        self.screens = screens
        self.onLeave = onLeave
        let names: [Notification.Name] = [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                                          NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        })
    }

    /// Whether a status item in `window` can anchor a visible popover.
    static func isOnScreen(_ window: NSWindow?, screens: [CGRect]) -> Bool {
        guard let window else { return false }
        return StatusItemsController.isOnScreen(window.frame, screens: screens)
    }

    /// Re-checks the anchor after a layout change; still off screen after `grace` → `onLeave`.
    func evaluate() {
        guard onLeave != nil, !pending, !Self.isOnScreen(window, screens: screens()) else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = false
                guard self.onLeave != nil, !Self.isOnScreen(self.window, screens: self.screens()) else { return }
                let leave = self.onLeave
                self.invalidate()
                leave?()
            }
        }
    }

    func invalidate() {
        onLeave = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
    }
}

/// The detail popover shown below a monitor status item. A fresh popover (and SwiftUI tree) is
/// created on every open and released on close, so nothing re-renders while it is hidden.
@MainActor
final class DetailPopoverController: NSObject, NSPopoverDelegate {
    /// Pinned: the popover only closes from its status item (or when the item is hidden); unpinned it
    /// closes on any click outside. Reset when the popover closes.
    let pin = PopoverPinState()
    private var pinObserver: AnyCancellable?
    private var popover: NSPopover?
    private weak var anchor: NSStatusBarButton?
    private var anchorWatcher: AnchorWatcher?
    /// The transient popover closes on mouse-down outside it — including on its own status item, whose
    /// action then fires on mouse-up. Remember that close so the same click does not reopen it.
    private weak var lastClosedAnchor: NSStatusBarButton?
    private var lastCloseTime: TimeInterval = 0
    /// Called with true when the popover opens and false once it has closed.
    var onVisibilityChange: ((Bool) -> Void)?

    var isShown: Bool { popover?.isShown ?? false }
    var anchorButton: NSStatusBarButton? { anchor }
    /// The behaviour of the current popover (for checks).
    var currentBehavior: NSPopover.Behavior? { popover?.behavior }

    override init() {
        super.init()
        pinObserver = pin.$isPinned.removeDuplicates().sink { [weak self] pinned in
            MainActor.assumeIsolated { self?.popover?.behavior = Self.behavior(pinned: pinned) }
        }
    }

    static func behavior(pinned: Bool) -> NSPopover.Behavior {
        pinned ? .applicationDefined : .transient
    }

    /// Opens the popover under `button`, or closes it when it is already open there.
    func toggle(relativeTo button: NSStatusBarButton, content: () -> AnyView) {
        if let current = popover, current.isShown {
            if anchor === button {
                current.performClose(nil)
                return
            }
            // Moving to another item: detach first so the old popover's close is not reported.
            popover = nil
            anchor = nil
            current.animates = false
            current.close()
        } else if lastClosedAnchor === button, ProcessInfo.processInfo.systemUptime - lastCloseTime < 0.4 {
            return
        }
        show(relativeTo: button, content: content())
    }

    func show(relativeTo button: NSStatusBarButton, content: AnyView) {
        guard let anchorWindow = button.window else { return }
        let p = NSPopover()
        p.behavior = Self.behavior(pinned: pin.isPinned)
        p.delegate = self
        var hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = [.preferredContentSize] // popover follows the SwiftUI content size
        // On short screens (e.g. a scaled 13" display) make the content scroll instead of being clipped.
        let available = (button.window?.screen ?? NSScreen.main).map { $0.visibleFrame.height - 24 } ?? .greatestFiniteMagnitude
        let fitting = hosting.view.fittingSize
        if fitting.height > available, available > 200 {
            hosting = NSHostingController(rootView: AnyView(ScrollView { content }.frame(width: fitting.width, height: available)))
            hosting.sizingOptions = [.preferredContentSize]
        }
        p.contentViewController = hosting
        popover = p
        anchor = button
        anchorWatcher?.invalidate()
        anchorWatcher = nil
        // Close once the item leaves the screen (e.g. the menu-bar hider collapsed). Only an item that is
        // on screen now is watched: one the system presents elsewhere (menu-bar overflow) keeps working.
        if AnchorWatcher.isOnScreen(anchorWindow, screens: NSScreen.screens.map(\.frame)) {
            anchorWatcher = AnchorWatcher(window: anchorWindow) { [weak self, weak p] in
                guard let self, let p, self.popover === p else { return }
                AppLog.info("monitor", "detail popover closed: its menu-bar item left the screen")
                self.close()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
        onVisibilityChange?(true)
    }

    /// Closes immediately (no animation) — used by stop() and when the anchor item gets hidden.
    func close() {
        guard let p = popover else { return }
        p.animates = false
        if p.isShown {
            p.close()
        }
        if popover === p { finish(p) }
    }

    // MARK: NSPopoverDelegate

    func popoverWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPopover, closing === popover else { return }
        lastClosedAnchor = anchor
        lastCloseTime = ProcessInfo.processInfo.systemUptime
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover else { return }
        closed.contentViewController = nil
        if closed === popover { finish(closed) }
    }

    private func finish(_ p: NSPopover) {
        p.contentViewController = nil
        popover = nil
        anchor = nil
        anchorWatcher?.invalidate()
        anchorWatcher = nil
        pin.isPinned = false
        onVisibilityChange?(false)
    }
}
