import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import OneSwitchCore

// MARK: - Displays

enum SystemScreens {
    /// Active displays in global display coordinates (top-left origin).
    static func current() -> ScreenGeometry {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return ScreenGeometry(displays: []) }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return ScreenGeometry(displays: []) }
        return ScreenGeometry(displays: ids.prefix(Int(count)).map { CGDisplayBounds($0) })
    }
}

// MARK: - Server cursor

/// Hide / show bookkeeping for a cursor. Requests come from any thread (the event-tap thread, the channel
/// queue, main) and are applied AT ONCE on the calling thread, under a lock: CGDisplayHideCursor /
/// CGDisplayShowCursor are window-server calls that need no main thread, and applying them in lock order
/// keeps them balanced whatever the interleaving.
///
/// History: requests from other threads used to hop to the main queue. When the main thread was busy
/// (status icon, menus, other modules) the cursor reappeared late on the server — felt as a hitch when
/// control came back — and the client's hide could come too late to matter.
final class CursorVisibility: @unchecked Sendable {
    private let lock = NSLock()
    private var hidden = false
    private let apply: (Bool) -> Void

    init(apply: @escaping (Bool) -> Void) {
        self.apply = apply
    }

    /// Returns true when the state changed (the window server was called).
    @discardableResult
    func setHidden(_ hide: Bool) -> Bool {
        lock.withLock {
            guard hide != hidden else { return false }
            hidden = hide
            apply(hide)
            return true
        }
    }

    var isHidden: Bool { lock.withLock { hidden } }

    deinit {
        // Safety net: never leave the cursor hidden behind.
        if hidden { apply(false) }
    }
}

/// The private "SetsCursorInBackground" connection property: a background (menu-bar) app may hide the
/// cursor only while it is set. Resolved at runtime via dlsym; harmless if unavailable.
///
/// It is asserted again right before every hide (as Barrier / Deskflow do): it is one window-server call,
/// and it keeps hiding working even if something reset the connection's properties meanwhile (e.g. the
/// app switching its activation policy to show a Dock icon while the settings window is open).
enum BackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private typealias IsVisible = @convention(c) () -> Int32

    private static let functions: (connection: DefaultConnection, set: SetProperty)? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connSym = dlsym(handle, "_CGSDefaultConnection"),
              let setSym = dlsym(handle, "CGSSetConnectionProperty") else {
            AppLog.warning("input", "background cursor hiding unavailable (private API not found)")
            return nil
        }
        return (unsafeBitCast(connSym, to: DefaultConnection.self), unsafeBitCast(setSym, to: SetProperty.self))
    }()

    /// CGCursorIsVisible (deprecated, so looked up instead of linked: diagnostics only).
    private static let isVisibleFunction: IsVisible? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(sym, to: IsVisible.self)
    }()

    private final class Last: @unchecked Sendable {
        let lock = NSLock()
        var result: Int32?
    }
    private static let last = Last()

    /// Sets the property. Logs the first result and every change of it (not every call).
    @discardableResult
    static func enable() -> Bool {
        guard let f = functions else { return false }
        let conn = f.connection()
        let result = f.set(conn, conn, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        let changed: Bool = last.lock.withLock {
            defer { last.result = result }
            return last.result != result
        }
        if changed {
            if result == 0 {
                AppLog.info("input", "background cursor control enabled")
            } else {
                AppLog.warning("input", "background cursor control refused (error \(result)); the cursor may stay visible")
            }
        }
        return result == 0
    }

    /// Whether the window server reports the cursor visible (nil when that cannot be asked).
    static var cursorReportedVisible: Bool? {
        isVisibleFunction.map { $0() != 0 }
    }
}

/// The window-server calls behind `SystemCursorControl` (injectable, so the checks can verify their order
/// without touching the real cursor).
struct CursorOps: @unchecked Sendable {
    var warp: (CGPoint) -> Void
    var attach: (Bool) -> Void
    var hide: () -> Void
    var show: () -> Void
    /// Moves the cursor like real mouse motion (a posted, tagged mouse-moved event from a source with no
    /// local-event suppression). Unlike CGWarpMouseCursorPosition this does not make macOS ignore the mouse
    /// for a moment afterwards — measured on real hardware, a warp on return froze the cursor for ≥ 90 ms
    /// while mouse deltas kept arriving (the "hitch" when coming back from the other Mac).
    var place: (CGPoint) -> Void

    /// Tag on the placement event, so our own event tap lets it pass without treating it as user input.
    static let placementTag: Int64 = 0x4F4E_5350 // 'ONSP'

    private static let placementSource: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    static let system = CursorOps(
        warp: { CGWarpMouseCursorPosition($0) },
        attach: { CGAssociateMouseAndMouseCursorPosition($0 ? 1 : 0) },
        hide: {
            BackgroundCursor.enable()
            CGDisplayHideCursor(CGMainDisplayID())
        },
        show: { CGDisplayShowCursor(CGMainDisplayID()) },
        place: { point in
            guard let e = CGEvent(mouseEventSource: placementSource, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) else {
                CGWarpMouseCursorPosition(point)
                return
            }
            e.setIntegerValueField(.eventSourceUserData, value: placementTag)
            e.post(tap: .cghidEventTap)
        })
}

/// Parks / hides the server's cursor while the other Mac is controlled.
final class SystemCursorControl: @unchecked Sendable {
    private let lock = NSLock()
    private static let backgroundCursorEnabled: Bool = BackgroundCursor.enable()
    private let ops: CursorOps
    private let visibility: CursorVisibility

    init(ops: CursorOps = .system) {
        self.ops = ops
        visibility = CursorVisibility(apply: { hide in if hide { ops.hide() } else { ops.show() } })
    }

    /// Whether this (background) app can hide the cursor at all. Resolved once; `prepare()` does it early.
    static var canHideCursor: Bool { backgroundCursorEnabled }

    /// Sets the private background-cursor connection property now (both roles call this on the main
    /// thread when a session starts), so it is in place before the first hide.
    @discardableResult
    static func prepare() -> Bool { backgroundCursorEnabled }

    /// Warps the (hidden) cursor to its park point and detaches it from the mouse, so it stays put while
    /// the device deltas are forwarded. Calling CGAssociate… right after the warp also ends the post-warp
    /// suppression of hardware events.
    /// Hides the cursor and moves it to its park point. The cursor stays ATTACHED to the mouse (like
    /// Deskflow): re-attaching after a detach lagged ≥ 90 ms on real hardware. It is never WARPED either:
    /// CGWarpMouseCursorPosition makes macOS ignore the mouse for a moment (measured: the cursor froze at
    /// the edge after a fast flick back when a re-centring warp had happened just before). All placement
    /// goes through `ops.place` — a posted, tagged mouse-moved from a source without event suppression.
    /// The server drops each placement's delta artifact; its event tap swallows the tagged placements while
    /// the other Mac is controlled (no hover effects here) and lets them through otherwise.
    func park(at point: CGPoint) {
        // One lock around the whole sequence, so a park and a restore from different threads never
        // interleave. Hide first: moving a still-visible cursor flashed it at the park point.
        lock.withLock {
            visibility.setHidden(true)
            ops.attach(true)
            ops.place(point)
        }
    }

    /// Brings the wandering hidden cursor back to the park point.
    func keepParked(at point: CGPoint) {
        lock.withLock {
            ops.place(point)
        }
    }

    /// Hands the cursor back at `point` (still attached, moved like real motion — the rest of a flick
    /// keeps moving it), then shows it.
    func restore(at point: CGPoint) {
        lock.withLock {
            ops.attach(true)
            ops.place(point)
            visibility.setHidden(false)
        }
    }

    var isHidden: Bool { visibility.isHidden }
}

// MARK: - Client injection

/// Posts synthetic events on the client Mac (requires 辅助功能).
final class SystemEventInjector: EventInjector, @unchecked Sendable {
    private let source: CGEventSource?
    private var activityAssertion: IOPMAssertionID = 0

    /// Marks events we post (kCGEventSourceUserData), so this Mac's own input can be told apart.
    static let postedEventTag: Int64 = 0x4F4E_5357 // 'ONSW'

    private let cursorVisibility = CursorVisibility(apply: { hide in
        if hide {
            BackgroundCursor.enable() // a background app may hide the cursor only while this is set
            CGDisplayHideCursor(CGMainDisplayID())
            // Barrier's fix for a client cursor that "randomly does not hide". This Mac's cursor is never
            // detached from its mouse, so re-attaching changes nothing else.
            CGAssociateMouseAndMouseCursorPosition(1)
        } else {
            CGDisplayShowCursor(CGMainDisplayID())
        }
    })
    private let lock = NSLock()
    /// When the cursor was last hidden (monotonic), for the reveal grace period.
    private var hiddenAt: TimeInterval = 0
    /// Monitors that bring the cursor back on this Mac's own mouse / trackpad input (main thread): a
    /// global one, plus a local one for events over OneSwitch's own windows (global monitors skip those).
    private var localInputMonitors: [Any] = []
    /// Scroll events logged after each switch (diagnostics).
    private let scrollLogBudget = OSAllocatedUnfairLockCounter()

    init() {
        source = CGEventSource(stateID: .hidSystemState)
        // Keep this Mac's own trackpad / keyboard responsive while we post events.
        source?.localEventsSuppressionInterval = 0
    }

    private func post(_ e: CGEvent) {
        e.setIntegerValueField(.eventSourceUserData, value: Self.postedEventTag)
        e.post(tap: .cghidEventTap)
    }

    /// Control went back to the other Mac: hide this Mac's cursor (as the server does while it controls
    /// us) until this Mac's own mouse / trackpad is used again. The hide itself happens right here, on the
    /// calling thread; only the event monitor needs the main thread.
    func hideCursorUntilLocalInput() {
        lock.withLock { hiddenAt = ProcessInfo.processInfo.systemUptime }
        if cursorVisibility.setHidden(true) {
            let stillVisible = BackgroundCursor.cursorReportedVisible == true
            AppLog.info("input", "client cursor hidden (control went back to the other Mac)\(stillVisible ? "; the window server still reports it visible" : "")")
            redrawCursor()
        }
        DispatchQueue.main.async { [self] in
            // Shown again (control arrived) before this ran: no monitor needed.
            guard cursorVisibility.isHidden, localInputMonitors.isEmpty else { return }
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
                                               .rightMouseDragged, .otherMouseDragged, .scrollWheel]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.localEvent(event)
            }) {
                localInputMonitors.append(global)
            } else {
                // Without the global monitor nothing would bring the cursor back when this Mac's own mouse /
                // trackpad is used: never leave it hidden like that.
                showCursor(reason: "no event monitor available to reveal it later")
                return
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.localEvent(event)
                return event
            }) {
                localInputMonitors.append(local)
            }
        }
    }

    /// A hide from a background app takes effect in the window server at once, but the cursor image already
    /// on screen is only redrawn on its next movement — seen on real hardware as the cursor lingering for
    /// ~30 s after control went back. Nudge it 1 pt and back with tagged moves (the reveal monitor ignores
    /// tagged events) so it disappears now.
    private func redrawCursor() {
        let p = cursorLocation()
        let nudge = CGPoint(x: p.x >= 1 ? p.x - 1 : p.x + 1, y: p.y)
        for point in [nudge, p] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                                  mouseButton: .left) else { return }
            post(e)
        }
    }

    /// Global monitor (main thread): real input from this Mac's own mouse / trackpad reveals the cursor.
    private func localEvent(_ event: NSEvent) {
        let tagged = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.postedEventTag
        let sinceHide = ProcessInfo.processInfo.systemUptime - lock.withLock { hiddenAt }
        let kind: LocalInputReveal.Kind
        let dx: Double, dy: Double
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            kind = .button; dx = 0; dy = 0
        case .scrollWheel:
            kind = .scroll; dx = Double(event.scrollingDeltaX); dy = Double(event.scrollingDeltaY)
        default:
            kind = .move; dx = Double(event.deltaX); dy = Double(event.deltaY)
        }
        guard LocalInputReveal.shouldReveal(kind: kind, tagged: tagged, sinceHide: sinceHide, dx: dx, dy: dy) else { return }
        showCursor(reason: String(format: "local %@ (dx %.1f, dy %.1f, %.0f ms after hiding)",
                                  "\(kind)", dx, dy, sinceHide * 1000))
    }

    func showCursor(reason: String) {
        scrollLogBudget.reset(3)
        if cursorVisibility.setHidden(false) {
            AppLog.info("input", "client cursor shown (\(reason))")
        }
        let removeMonitor = { [self] in
            localInputMonitors.forEach(NSEvent.removeMonitor)
            localInputMonitors.removeAll()
        }
        if Thread.isMainThread { removeMonitor() } else { DispatchQueue.main.async(execute: removeMonitor) }
    }

    var canInject: Bool { AXIsProcessTrusted() }

    func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    func moveCursor(to point: CGPoint, dx: Double, dy: Double, draggingButton: Int?, flags: UInt64) {
        let type: CGEventType
        let button: CGMouseButton
        switch draggingButton {
        case nil: type = .mouseMoved; button = .left
        case 0?: type = .leftMouseDragged; button = .left
        case 1?: type = .rightMouseDragged; button = .right
        default: type = .otherMouseDragged; button = .center
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        e.setDoubleValueField(.mouseEventDeltaX, value: dx)
        e.setDoubleValueField(.mouseEventDeltaY, value: dy)
        if let b = draggingButton, b >= 2 { e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(b)) }
        e.flags = CGEventFlags(rawValue: flags)
        post(e)
    }

    func postButton(_ button: Int, down: Bool, at point: CGPoint, clickState: Int64, flags: UInt64) {
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case 0: type = down ? .leftMouseDown : .leftMouseUp; cgButton = .left
        case 1: type = down ? .rightMouseDown : .rightMouseUp; cgButton = .right
        default: type = down ? .otherMouseDown : .otherMouseUp; cgButton = .center
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: max(1, clickState))
        if button >= 2 { e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button)) }
        e.flags = CGEventFlags(rawValue: flags)
        post(e)
    }

    func postScroll(_ s: ScrollData, at point: CGPoint, flags: UInt64) {
        if scrollLogBudget.take() {
            AppLog.info("input", "posting scroll delta=\(s.delta1),\(s.delta2) point=\(s.point1),\(s.point2) continuous=\(s.isContinuous) at \(Int(point.x)),\(Int(point.y))")
        }
        let units: CGScrollEventUnit = s.isContinuous != 0 ? .pixel : .line
        let w1 = Int32(clamping: s.isContinuous != 0 ? s.point1 : s.delta1)
        let w2 = Int32(clamping: s.isContinuous != 0 ? s.point2 : s.delta2)
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: units, wheelCount: 2, wheel1: w1, wheel2: w2, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: s.delta1)
        e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: s.delta2)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: s.point1)
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: s.point2)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: s.fixed1)
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: s.fixed2)
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: s.isContinuous)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: s.scrollPhase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: s.momentumPhase)
        e.setIntegerValueField(.scrollWheelEventScrollCount, value: s.scrollCount)
        e.location = point
        e.flags = CGEventFlags(rawValue: flags)
        post(e)
    }

    /// A frame of a synthesized wheel gesture: a pixel scroll event (CG derives the line / fixed-point
    /// deltas and marks it continuous) carrying a scroll phase. Scroll utilities such as Mos treat
    /// phase-carrying events as trackpad input and pass them through; apps scroll them by pixels.
    func postScrollFrame(_ frame: WheelFrame, at point: CGPoint, flags: UInt64) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: frame.dy, wheel2: frame.dx, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: frame.phase.rawValue)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        e.setIntegerValueField(.scrollWheelEventScrollCount, value: 0)
        e.location = point
        e.flags = CGEventFlags(rawValue: flags)
        if frame.phase != .changed, scrollLogBudget.take() {
            AppLog.info("input", "posting wheel gesture \(frame) at \(Int(point.x)),\(Int(point.y))")
        }
        post(e)
    }

    func postKey(_ keyCode: UInt16, down: Bool, autorepeat: Bool, flags: UInt64) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        e.flags = CGEventFlags(rawValue: flags)
        if autorepeat { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        post(e)
    }

    func postFlagsChanged(_ keyCode: UInt16, flags: UInt64) {
        let isDown = ModifierKeys.isDown(keyCode: keyCode, flags: flags) ?? false
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { return }
        e.type = .flagsChanged
        e.flags = CGEventFlags(rawValue: flags)
        post(e)
    }

    func postSystemDefined(subtype: Int16, data1: Int64, data2: Int64, flags: UInt64) {
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: flags) & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue)
        guard let ns = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: modifiers,
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                          subtype: subtype, data1: Int(data1), data2: Int(data2)),
              let e = ns.cgEvent else { return }
        post(e)
    }

    func declareUserActivity() {
        IOPMAssertionDeclareUserActivity("OneSwitch 键鼠共享" as CFString, kIOPMUserActiveLocal, &activityAssertion)
    }

    func endUserActivity() {
        guard activityAssertion != IOPMAssertionID(kIOPMNullAssertionID) else { return }
        IOPMAssertionRelease(activityAssertion)
        activityAssertion = IOPMAssertionID(kIOPMNullAssertionID)
    }
}

// MARK: - Clipboard

/// Clipboard hand-over: the Mac losing control sends its pasteboard if it changed since the last sync.
/// Text, RTF, HTML and images (PNG preferred; TIFF only when there is no PNG), up to
/// `ClipboardLimits.maxTotalBytes`. Files are not transferred.
@MainActor
final class ClipboardSync {
    static let types: [NSPasteboard.PasteboardType] = [.string, .rtf, .html, .png, .tiff]
    private let pasteboard: NSPasteboard
    private let maxTotalBytes: Int
    /// changeCount already sent or written by us (-1: never synced, so the first hand-over sends).
    private var syncedChangeCount = -1
    /// Converts a received image into the other image type on demand (kept alive while it is on the board).
    private var converter: ImageTypeConverter?

    init(pasteboard: NSPasteboard = .general, maxTotalBytes: Int = ClipboardLimits.maxTotalBytes) {
        self.pasteboard = pasteboard
        self.maxTotalBytes = maxTotalBytes
    }

    /// The pasteboard change last sent or written by us.
    var syncedChange: Int { syncedChangeCount }

    /// Sending the clipboard of change `changeCount` failed (the channel broke mid-transfer): offer it
    /// again at the next hand-over — unless the pasteboard changed (or was synced) since.
    func markUnsent(changeCount: Int) {
        guard syncedChangeCount == changeCount, pasteboard.changeCount == changeCount else { return }
        syncedChangeCount = -1
        AppLog.info("input", "clipboard will be offered again at the next switch (the last transfer failed)")
    }

    func snapshotIfChanged() -> [ClipboardItem]? {
        let pb = pasteboard
        guard pb.changeCount != syncedChangeCount else { return nil }
        syncedChangeCount = pb.changeCount
        let available = Set(pb.types ?? [])
        var items: [ClipboardItem] = []
        var total = 0
        // Room for the codec's framing (count + two length prefixes and the type name per item).
        let overhead = 4 + Self.types.count * 64
        for type in Self.types where available.contains(type) {
            // Prefer PNG over the (much larger) TIFF rendition of the same image — decide before asking for
            // the data: a promised TIFF would otherwise be rendered by the source app, synchronously on main.
            if type == .tiff && items.contains(where: { $0.type == NSPasteboard.PasteboardType.png.rawValue }) { continue }
            guard let data = pb.data(forType: type), !data.isEmpty else { continue }
            guard total + data.count + overhead <= maxTotalBytes else {
                AppLog.warning("input", "clipboard \(type.rawValue) skipped: \(ClipboardSender.formatBytes(data.count)) exceeds the \(maxTotalBytes / 1_048_576) MB limit")
                continue
            }
            total += data.count
            items.append(ClipboardItem(type: type.rawValue, data: data))
        }
        return items.isEmpty ? nil : items
    }

    func apply(_ items: [ClipboardItem]) {
        // Only the types we send ourselves (never arbitrary pasteboard types from the wire).
        let allowed = Set(Self.types.map(\.rawValue))
        let items = items.filter { allowed.contains($0.type) && !$0.data.isEmpty }
        guard !items.isEmpty else { return }
        let item = NSPasteboardItem()
        for i in items {
            item.setData(i.data, forType: NSPasteboard.PasteboardType(i.type))
        }
        // Many apps read only one image type (older Cocoa apps / some chat apps: TIFF only). Offer the other
        // type as well, converted only if an app actually asks for it.
        let png = items.first { $0.type == NSPasteboard.PasteboardType.png.rawValue }
        let tiff = items.first { $0.type == NSPasteboard.PasteboardType.tiff.rawValue }
        var extra = ""
        converter = nil
        if let png, tiff == nil {
            let c = ImageTypeConverter(source: png.data)
            item.setDataProvider(c, forTypes: [.tiff])
            converter = c
            extra = " + TIFF on demand"
        } else if let tiff, png == nil {
            let c = ImageTypeConverter(source: tiff.data)
            item.setDataProvider(c, forTypes: [.png])
            converter = c
            extra = " + PNG on demand"
        }
        let pb = pasteboard
        pb.clearContents()
        guard pb.writeObjects([item]) else {
            AppLog.warning("input", "clipboard could not be written (\(ClipboardSender.describe(items)))")
            return
        }
        syncedChangeCount = pb.changeCount
        AppLog.info("input", "clipboard applied: \(ClipboardSender.describe(items))\(extra)")
    }
}

/// Supplies a received image in the other image type (PNG ⇄ TIFF) when an app asks for it.
final class ImageTypeConverter: NSObject, NSPasteboardItemDataProvider {
    private let source: Data

    init(source: Data) {
        self.source = source
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let data = Self.convert(source, to: type) else {
            AppLog.warning("input", "clipboard image could not be converted to \(type.rawValue)")
            return
        }
        item.setData(data, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {}

    static func convert(_ data: Data, to type: NSPasteboard.PasteboardType) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        switch type {
        case .tiff: return rep.tiffRepresentation
        case .png: return rep.representation(using: .png, properties: [:])
        default: return nil
        }
    }
}

/// A tiny thread-safe countdown used to rate-limit diagnostics.
final class OSAllocatedUnfairLockCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 0

    func reset(_ n: Int) { lock.withLock { remaining = n } }

    /// True (and decrements) while budget remains.
    func take() -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}
