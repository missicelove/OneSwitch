import AppKit
import CoreGraphics
import os

/// One synthetic input event of a ⌘-drag (CG global coordinates, origin top-left).
public struct SyntheticInputEvent: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case commandDown, mouseMoved, leftMouseDown, leftMouseDragged, leftMouseUp, commandUp
    }

    public var kind: Kind
    public var location: CGPoint
    public var flags: CGEventFlags
    /// Pause after posting this event, in seconds.
    public var pauseAfter: TimeInterval

    public init(kind: Kind, location: CGPoint, flags: CGEventFlags, pauseAfter: TimeInterval) {
        self.kind = kind
        self.location = location
        self.flags = flags
        self.pauseAfter = pauseAfter
    }

    /// The CGEventType this event is posted as.
    public var cgEventType: CGEventType {
        switch kind {
        case .commandDown: return .keyDown
        case .commandUp: return .keyUp
        case .mouseMoved: return .mouseMoved
        case .leftMouseDown: return .leftMouseDown
        case .leftMouseDragged: return .leftMouseDragged
        case .leftMouseUp: return .leftMouseUp
        }
    }

    public var isMouseEvent: Bool { kind != .commandDown && kind != .commandUp }
}

/// Where to move a menu-bar item.
public enum MoveDestination: String, Sendable {
    /// Just left of the separator (hidden section).
    case hidden
    /// Just right of the separator (always-visible section).
    case visible

    public var title: String {
        switch self {
        case .hidden: return "移到隐藏区"
        case .visible: return "移到显示区"
        }
    }
}

/// Builds the event sequence of a ⌘-drag (pure; unit-tested). Posting is done by `SyntheticDragPoster`.
public enum DragPlanner {
    public static let defaultSteps = 12
    /// Horizontal distance from the separator edge where the item is dropped.
    public static let dropInset: CGFloat = 4

    /// ⌘ down → move to start → mouse down → `steps` drags ending at `end` → mouse up → ⌘ up.
    /// Every mouse event carries `.maskCommand`; the final key-up clears it.
    public static func commandDragSequence(from start: CGPoint, to end: CGPoint, steps: Int = defaultSteps) -> [SyntheticInputEvent] {
        let n = max(1, steps)
        var events: [SyntheticInputEvent] = [
            SyntheticInputEvent(kind: .commandDown, location: start, flags: .maskCommand, pauseAfter: 0.05),
            SyntheticInputEvent(kind: .mouseMoved, location: start, flags: .maskCommand, pauseAfter: 0.08),
            SyntheticInputEvent(kind: .leftMouseDown, location: start, flags: .maskCommand, pauseAfter: 0.25),
        ]
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            events.append(SyntheticInputEvent(kind: .leftMouseDragged, location: p, flags: .maskCommand,
                                              pauseAfter: i == n ? 0.2 : 0.025))
        }
        events.append(SyntheticInputEvent(kind: .leftMouseUp, location: end, flags: .maskCommand, pauseAfter: 0.08))
        events.append(SyntheticInputEvent(kind: .commandUp, location: end, flags: [], pauseAfter: 0))
        return events
    }

    /// Drop point for `destination`, from our separator / toggle frames (CG coordinates).
    /// - hidden: just left of the separator.
    /// - visible: just right of the separator, but still left of the toggle's centre (so the item lands
    ///   between the separator and the toggle).
    public static func dropPoint(for destination: MoveDestination, separator: CGRect, toggle: CGRect) -> CGPoint {
        let y = separator.midY
        switch destination {
        case .hidden:
            return CGPoint(x: separator.minX - dropInset, y: y)
        case .visible:
            let x = min(separator.maxX + dropInset, toggle.midX - 2)
            return CGPoint(x: max(x, separator.midX + 1), y: y)
        }
    }

    /// Total duration of a sequence (seconds).
    public static func duration(of events: [SyntheticInputEvent]) -> TimeInterval {
        events.reduce(0) { $0 + $1.pauseAfter }
    }
}

/// Posts a planned ⌘-drag at the HID level on a private serial queue, then restores the cursor.
/// Requires 辅助功能 permission. Never used by the self-checks.
public final class SyntheticDragPoster: @unchecked Sendable {
    private let queue = DispatchQueue(label: "oneswitch.menubar.drag", qos: .userInitiated)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    /// Posts `events`; `completion` runs on the main queue with false when posting failed.
    public func post(_ events: [SyntheticInputEvent], completion: @escaping @Sendable (Bool) -> Void) {
        cancelled.withLock { $0 = false }
        queue.async { [cancelled] in
            let ok = Self.run(events, cancelled: cancelled)
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Aborts a running drag (the button and ⌘ are still released) and waits until it has finished.
    /// Safe to call from the main thread (a drag lasts < 1.5 s).
    public func cancelAndWait() {
        cancelled.withLock { $0 = true }
        queue.sync {}
    }

    private static func run(_ events: [SyntheticInputEvent], cancelled: OSAllocatedUnfairLock<Bool>) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let savedCursor = CGEvent(source: nil)?.location
        var buttonDown = false
        var commandDown = false
        var last = events.first?.location ?? .zero
        var ok = true

        for event in events {
            if cancelled.withLock({ $0 }) { break }
            guard let cg = makeEvent(event, source: source) else { ok = false; break }
            cg.post(tap: .cghidEventTap)
            last = event.location
            switch event.kind {
            case .commandDown: commandDown = true
            case .commandUp: commandDown = false
            case .leftMouseDown: buttonDown = true
            case .leftMouseUp: buttonDown = false
            default: break
            }
            if event.pauseAfter > 0 { usleep(useconds_t(event.pauseAfter * 1_000_000)) }
        }
        // Never leave the button or ⌘ stuck, even when aborted half-way.
        if buttonDown {
            let up = SyntheticInputEvent(kind: .leftMouseUp, location: last, flags: commandDown ? .maskCommand : [], pauseAfter: 0)
            makeEvent(up, source: source)?.post(tap: .cghidEventTap)
            usleep(50_000)
        }
        if commandDown {
            let up = SyntheticInputEvent(kind: .commandUp, location: last, flags: [], pauseAfter: 0)
            makeEvent(up, source: source)?.post(tap: .cghidEventTap)
        }
        if let savedCursor {
            CGWarpMouseCursorPosition(savedCursor)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        return ok && !cancelled.withLock { $0 }
    }

    private static func makeEvent(_ event: SyntheticInputEvent, source: CGEventSource) -> CGEvent? {
        let cg: CGEvent?
        switch event.kind {
        case .commandDown, .commandUp:
            cg = CGEvent(keyboardEventSource: source, virtualKey: 0x37 /* kVK_Command */, keyDown: event.kind == .commandDown)
        default:
            cg = CGEvent(mouseEventSource: source, mouseType: event.cgEventType,
                         mouseCursorPosition: event.location, mouseButton: .left)
            if event.kind == .leftMouseDown || event.kind == .leftMouseUp {
                cg?.setIntegerValueField(.mouseEventClickState, value: 1)
            }
        }
        cg?.flags = event.flags
        return cg
    }
}
