import AppKit
import CoreGraphics
import OneSwitchCore

/// Runs the server's event taps on a dedicated high-priority thread.
///
/// Two taps:
/// - the **mouse tap** (moves, buttons, scroll) is active while a client is connected. In local mode it
///   only reads the cursor position to detect the screen edge and lets every event through;
/// - the **keyboard tap** (keys, modifiers, media keys) is created disabled and is enabled only while the
///   other Mac is being controlled (`setKeyboardCapture(true)`), so keystrokes are never intercepted
///   while you are working on this Mac.
final class EventTapRunner: @unchecked Sendable {
    private let core: ServerCore
    private let lock = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var mouseTap: CFMachPort?
    private var keyboardTap: CFMachPort?
    private var keyboardWanted = false
    /// Per-tap callback contexts, so the callback knows which tap an event (or a disable notice) came from.
    private lazy var mouseContext = TapContext(runner: self, isKeyboard: false)
    private lazy var keyboardContext = TapContext(runner: self, isKeyboard: true)

    init(core: ServerCore) {
        self.core = core
    }

    /// Creates the taps on the tap thread. Returns false if the system refused (missing permission).
    func start() -> Bool {
        let started = DispatchSemaphore(value: 0)
        var ok = false
        let thread = Thread { [weak self] in
            guard let self else { started.signal(); return }
            ok = self.installTaps()
            started.signal()
            if ok { CFRunLoopRun() }
        }
        thread.name = "OneSwitch.EventTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        started.wait()
        if ok {
            lock.withLock { self.thread = thread }
        }
        return ok
    }

    func stop() {
        let (rl, mouse, keyboard): (CFRunLoop?, CFMachPort?, CFMachPort?) = lock.withLock {
            let r = (runLoop, mouseTap, keyboardTap)
            runLoop = nil
            mouseTap = nil
            keyboardTap = nil
            thread = nil
            keyboardWanted = false
            return r
        }
        if let keyboard { CGEvent.tapEnable(tap: keyboard, enable: false); CFMachPortInvalidate(keyboard) }
        if let mouse { CGEvent.tapEnable(tap: mouse, enable: false); CFMachPortInvalidate(mouse) }
        if let rl { CFRunLoopStop(rl) }
    }

    /// Both taps still exist and the mouse tap is enabled (the keyboard tap is off by design in local mode).
    var isHealthy: Bool {
        let (mouse, keyboard) = lock.withLock { (mouseTap, keyboardTap) }
        guard let mouse, let keyboard else { return false }
        return CFMachPortIsValid(mouse) && CFMachPortIsValid(keyboard) && CGEvent.tapIsEnabled(tap: mouse)
    }

    func setKeyboardCapture(_ enabled: Bool) {
        let tap: CFMachPort? = lock.withLock {
            keyboardWanted = enabled
            return keyboardTap
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
    }

    private func installTaps() -> Bool {
        let mouseInfo = Unmanaged.passUnretained(mouseContext).toOpaque()
        let keyboardInfo = Unmanaged.passUnretained(keyboardContext).toOpaque()
        let mouseTypes: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                         .leftMouseDragged, .rightMouseDragged, .otherMouseDown, .otherMouseUp,
                                         .otherMouseDragged, .scrollWheel]
        let keyboardTypes: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mouseMask = mouseTypes.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let keyboardMask = keyboardTypes.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
            | (1 << CGEventMask(EventTapRunner.systemDefinedType))

        guard let mouse = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                            eventsOfInterest: mouseMask, callback: eventTapCallback, userInfo: mouseInfo) else {
            AppLog.warning("input", "mouse event tap could not be created (permission?)")
            return false
        }
        // The keyboard tap sits at the HID level, ahead of every session-level tap: apps with their own
        // session tap for global shortcuts (e.g. a screenshot tool's Ctrl+A), placed in front of ours, would
        // otherwise consume the keystroke on this Mac before it could be forwarded to the other one.
        let hidKeyboard = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                            eventsOfInterest: keyboardMask, callback: eventTapCallback, userInfo: keyboardInfo)
        if hidKeyboard == nil { AppLog.warning("input", "HID-level keyboard tap refused; using a session-level tap") }
        guard let keyboard = hidKeyboard ?? CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: keyboardMask, callback: eventTapCallback, userInfo: keyboardInfo) else {
            CFMachPortInvalidate(mouse)
            AppLog.warning("input", "keyboard event tap could not be created (permission?)")
            return false
        }
        CGEvent.tapEnable(tap: keyboard, enable: false)
        let rl = CFRunLoopGetCurrent()
        for tap in [mouse, keyboard] {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(rl, source, .commonModes)
        }
        CGEvent.tapEnable(tap: mouse, enable: true)
        lock.withLock {
            runLoop = rl
            mouseTap = mouse
            keyboardTap = keyboard
        }
        AppLog.info("input", "event taps installed")
        return true
    }

    static let systemDefinedType: UInt32 = 14 // NX_SYSDEFINED

    fileprivate func handle(type: CGEventType, event: CGEvent, fromKeyboardTap: Bool) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByUserInput {
            // Sent when a tap is disabled programmatically — including our own keyboard tap being switched
            // off (setKeyboardCapture(false) / right after creation). macOS may deliver that notice late,
            // e.g. only once the tap is enabled again when control moves to the other Mac. It is never a
            // reason to take control back (doing so bounced the user back within milliseconds). Just make
            // sure the tap is in the state we want.
            let (mouse, keyboard, wanted) = lock.withLock { (mouseTap, keyboardTap, keyboardWanted) }
            if fromKeyboardTap {
                if let keyboard, wanted { CGEvent.tapEnable(tap: keyboard, enable: true) }
            } else if let mouse {
                CGEvent.tapEnable(tap: mouse, enable: true)
            }
            AppLog.debug("input", "\(fromKeyboardTap ? "keyboard" : "mouse") tap reported disabled-by-user-input (wanted: \(fromKeyboardTap ? wanted : true))")
            return Unmanaged.passUnretained(event)
        }
        if TapDisablePolicy.takesControlBack(type) {
            // The system switched the tap off because a callback was too slow. While controlling the other
            // Mac some input may have reached this Mac in the meantime, so hand control back (safety), then
            // re-arm the taps.
            core.tapWasDisabled()
            let (mouse, keyboard, wanted) = lock.withLock { (mouseTap, keyboardTap, keyboardWanted) }
            if fromKeyboardTap {
                if let keyboard, wanted { CGEvent.tapEnable(tap: keyboard, enable: true) }
            } else if let mouse {
                CGEvent.tapEnable(tap: mouse, enable: true)
            }
            AppLog.warning("input", "\(fromKeyboardTap ? "keyboard" : "mouse") event tap timed out; re-enabled")
            return Unmanaged.passUnretained(event)
        }
        // Our own cursor placements (see CursorOps.place) are not user input. While the other Mac is
        // controlled they only park the hidden cursor: swallow them so apps here see no hover motion. On
        // return, let the placement through so apps learn where the cursor is.
        if event.getIntegerValueField(.eventSourceUserData) == CursorOps.placementTag {
            return core.currentMode == .remote ? nil : Unmanaged.passUnretained(event)
        }
        guard let captured = EventTapRunner.capture(type: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }
        return core.handle(captured) ? Unmanaged.passUnretained(event) : nil
    }

    /// Reduces a CGEvent to what the switching logic needs.
    static func capture(type: CGEventType, event: CGEvent) -> CapturedEvent? {
        let kind: CapturedKind
        var scrollInverted = false
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        switch type {
        case .mouseMoved: kind = .mouseMoved
        case .leftMouseDown: kind = .mouseDown(button: 0)
        case .leftMouseUp: kind = .mouseUp(button: 0)
        case .rightMouseDown: kind = .mouseDown(button: 1)
        case .rightMouseUp: kind = .mouseUp(button: 1)
        case .otherMouseDown: kind = .mouseDown(button: button)
        case .otherMouseUp: kind = .mouseUp(button: button)
        case .leftMouseDragged: kind = .mouseDragged(button: 0)
        case .rightMouseDragged: kind = .mouseDragged(button: 1)
        case .otherMouseDragged: kind = .mouseDragged(button: button)
        case .scrollWheel:
            var s = ScrollData()
            s.delta1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            s.delta2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            s.point1 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            s.point2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            s.fixed1 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            s.fixed2 = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            s.isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
            s.scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
            s.momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
            s.scrollCount = event.getIntegerValueField(.scrollWheelEventScrollCount)
            kind = .scroll(s)
            // Mouse wheel: remember whether macOS inverted it (natural scrolling), so the server can apply
            // the direction chosen for the other Mac from the physical wheel motion. The per-event flag is
            // authoritative; the system setting is a fallback in case a device's events lack the flag.
            if s.isContinuous == 0 {
                scrollInverted = (NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false) || NaturalScrolling.isEnabled
            }
        case .keyDown:
            kind = .keyDown(keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
                            autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp:
            kind = .keyUp(keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)))
        case .flagsChanged:
            kind = .flagsChanged(keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)))
        default:
            guard type.rawValue == systemDefinedType, let ns = NSEvent(cgEvent: event) else { return nil }
            kind = .systemDefined(subtype: Int16(truncatingIfNeeded: ns.subtype.rawValue),
                                  data1: Int64(ns.data1), data2: Int64(ns.data2))
        }
        return CapturedEvent(kind: kind,
                             location: event.location,
                             dx: event.getDoubleValueField(.mouseEventDeltaX),
                             dy: event.getDoubleValueField(.mouseEventDeltaY),
                             clickState: event.getIntegerValueField(.mouseEventClickState),
                             flags: event.flags.rawValue,
                             scrollInverted: scrollInverted)
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue()
    guard let runner = context.runner else { return Unmanaged.passUnretained(event) }
    return runner.handle(type: type, event: event, fromKeyboardTap: context.isKeyboard)
}

/// Callback context for one tap (the runner owns both contexts, so they live as long as the taps).
private final class TapContext {
    weak var runner: EventTapRunner?
    let isKeyboard: Bool

    init(runner: EventTapRunner, isKeyboard: Bool) {
        self.runner = runner
        self.isKeyboard = isKeyboard
    }
}

/// The system "natural scrolling" setting (系统设置 › 鼠标/触控板 › 自然滚动), cached for a second because it
/// is read on the event-tap thread for every wheel event. Absent means macOS's default: on.
enum NaturalScrolling {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var value: Bool?
        var at: TimeInterval = 0
    }

    private static let cache = Cache()

    static var isEnabled: Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return cache.lock.withLock {
            if let v = cache.value, now - cache.at < 1 { return v }
            let v = (UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool) ?? true
            cache.value = v
            cache.at = now
            return v
        }
    }
}

/// What a "tap disabled" notice means for control (pure; covered by SharedInputCheck).
enum TapDisablePolicy {
    /// Only a timeout is a real failure. `tapDisabledByUserInput` also arrives — possibly late — for our
    /// own deliberate disables, so it must never hand control back.
    static func takesControlBack(_ type: CGEventType) -> Bool {
        type == .tapDisabledByTimeout
    }
}
