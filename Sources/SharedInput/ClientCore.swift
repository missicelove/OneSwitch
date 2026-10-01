import CoreGraphics
import Foundation

/// Posts synthetic input on the client Mac. Real implementation: `SystemEventInjector`.
public protocol EventInjector: AnyObject {
    /// Whether posting is permitted (辅助功能 granted).
    var canInject: Bool { get }
    func cursorLocation() -> CGPoint
    func moveCursor(to point: CGPoint, dx: Double, dy: Double, draggingButton: Int?, flags: UInt64)
    func postButton(_ button: Int, down: Bool, at point: CGPoint, clickState: Int64, flags: UInt64)
    func postScroll(_ scroll: ScrollData, at point: CGPoint, flags: UInt64)
    /// One synthesized continuous (pixel) scroll event of a wheel gesture, carrying its scroll phase.
    func postScrollFrame(_ frame: WheelFrame, at point: CGPoint, flags: UInt64)
    func postKey(_ keyCode: UInt16, down: Bool, autorepeat: Bool, flags: UInt64)
    func postFlagsChanged(_ keyCode: UInt16, flags: UInt64)
    func postSystemDefined(subtype: Int16, data1: Int64, data2: Int64, flags: UInt64)
    /// Wake the display / reset the idle timer.
    func declareUserActivity()
    /// Release whatever `declareUserActivity` holds (called when the session ends).
    func endUserActivity()
    /// Control went back to the server: hide this Mac's cursor until its own mouse / trackpad moves.
    func hideCursorUntilLocalInput()
    /// Show this Mac's cursor (control arrived, or the session ended). `reason` is for the log.
    func showCursor(reason: String)
}

public extension EventInjector {
    func endUserActivity() {}
    func hideCursorUntilLocalInput() {}
    func showCursor(reason: String) {}
}

/// When the client's hidden cursor comes back: only on real input from this Mac's own mouse / trackpad.
/// Pure policy (covered by the checks) for the global monitor in `SystemEventInjector`.
public enum LocalInputReveal {
    public enum Kind: Sendable { case move, button, scroll }

    /// Events right after hiding are ignored: our last injected moves (possibly delivered to the monitor
    /// without their tag) and system-generated mouse events land in this window.
    public static let gracePeriod: TimeInterval = 0.3

    public static func shouldReveal(kind: Kind, tagged: Bool, sinceHide: TimeInterval, dx: Double, dy: Double) -> Bool {
        guard !tagged, sinceHide >= gracePeriod else { return false }
        switch kind {
        case .button: return true
        case .move, .scroll: return (dx != 0 || dy != 0) && dx.isFinite && dy.isFinite
        }
    }
}

public protocol ClientEffects: AnyObject {
    func send(_ message: InputMessage)
    func sendClipboardIfChanged()
    /// The server handed over its clipboard: write it here, off the switching path.
    func applyClipboard(_ items: [ClipboardItem])
    func stateDidChange(_ snapshot: ClientCore.Snapshot)
    func now() -> TimeInterval
    /// Diagnostics line (INFO) — default no-op.
    func log(_ line: String)
    /// This Mac's display arrangement right now (nil: keep the stored one) — default nil.
    func currentGeometry() -> ScreenGeometry?
}

public extension ClientEffects {
    func log(_ line: String) {}
    func currentGeometry() -> ScreenGeometry? { nil }
}

/// The client's side: replays forwarded input and hands control back when its cursor pushes against
/// the edge facing the server. Runs on the channel queue (plus `update(geometry:)` from main).
public final class ClientCore: @unchecked Sendable {
    public enum Mode: Equatable, Sendable {
        case idle
        case controlled
    }

    public struct Snapshot: Equatable, Sendable {
        public var mode: Mode
        public var rtt: TimeInterval?
        public var eventsPerSecond: Int
    }

    private let lock = NSLock()
    private weak var effects: ClientEffects?
    private let injector: EventInjector
    private var geometry: ScreenGeometry
    private var mode: Mode = .idle
    private var entryEdge: ScreenSide = .left
    private var pressedKeys = Set<UInt16>()
    private var pressedModifiers = Set<UInt16>()
    private var pressedButtons = Set<Int>()
    private var flags: UInt64 = 0
    private var lastHeard: TimeInterval = 0
    private var lastActivity: TimeInterval = 0
    private var heartbeatSeq: UInt32 = 0
    private var rtt: TimeInterval?
    private var eventCount = 0
    private var eventsPerSecond = 0
    private var lastRateSample: TimeInterval = 0
    /// Where we last put the cursor, and the recent positions we posted (see `basePosition`).
    private var virtualCursor: CGPoint?
    private var recentPositions: [CGPoint] = []
    /// Mouse-wheel replay (smooth, phase-carrying gestures; see `SmoothWheel`).
    private var wheel = WheelConfig()
    private var smoother = SmoothWheel()
    private var wheelFlags: UInt64 = 0
    /// Forwarded trackpad / Magic Mouse gesture state (closed when control leaves mid-gesture).
    private var padGesture = PadGestureTracker()
    private var padFlags: UInt64 = 0
    private let frameTimer: FrameTimer
    /// Wheel gestures logged after each switch (diagnostics).
    private var wheelLogBudget = 0

    /// Release everything if the server goes silent for this long while controlling us.
    public var silenceTimeout: TimeInterval = 3.0
    /// Frame period of smooth wheel gestures (~120 Hz).
    public static let wheelFrameInterval: TimeInterval = 1.0 / 120

    public init(geometry: ScreenGeometry, injector: EventInjector, effects: ClientEffects, frameTimer: FrameTimer? = nil) {
        self.geometry = geometry
        self.injector = injector
        self.effects = effects
        self.frameTimer = frameTimer ?? DispatchFrameTimer()
    }

    /// The server's wheel settings (from its hello).
    public func update(wheel config: WheelConfig) {
        lock.withLock {
            wheel = config
            if !config.smooth { endWheelGesture() }
        }
    }

    public var wheelConfig: WheelConfig { lock.withLock { wheel } }

    public var currentMode: Mode { lock.withLock { mode } }
    public var snapshot: Snapshot { lock.withLock { makeSnapshot() } }

    public func update(geometry: ScreenGeometry) {
        lock.withLock { self.geometry = geometry }
    }

    public func receive(_ message: InputMessage) {
        lock.withLock { receiveLocked(message) }
    }

    private func receiveLocked(_ message: InputMessage) {
        let t = now
        lastHeard = t
        switch message {
        case .enter(let edge, let fraction, let center, let flags):
            // A new remote stint starts with empty key/button sets on the server: anything still held from
            // a previous stint (whose releaseAll never arrived) would otherwise stay stuck forever.
            releaseAll()
            guard injector.canInject else {
                // Refuse, but say so: the server has already hidden its cursor and swallows all input, and
                // our heartbeat replies would keep it waiting indefinitely.
                if mode != .idle {
                    mode = .idle
                    publish()
                }
                effects?.send(.leave(fraction: center ? 0.5 : fraction))
                return
            }
            mode = .controlled
            entryEdge = edge
            self.flags = flags
            // Re-read the displays on every arrival. A session set up during a dark wake (display still off)
            // captured an empty / wrong arrangement, and lighting the display later posts no change
            // notification: without a valid edge the cursor could never hand control back.
            if let fresh = effects?.currentGeometry(), !fresh.isEmpty, fresh != geometry {
                effects?.log("screen geometry refreshed on arrival: \(geometry.displays) → \(fresh.displays)")
                geometry = fresh
            }
            let point = center ? geometry.mainCenter : geometry.entryPoint(on: edge, fraction: fraction)
            resetVirtualCursor(including: injector.cursorLocation())
            injector.showCursor(reason: "control arrived")
            wheelLogBudget = 3
            post(moveTo: point, dx: 0, dy: 0, draggingButton: nil)
            injector.declareUserActivity()
            lastActivity = t
            publish()
        case .releaseAll:
            // The server took control back (hotkey / menu / timeout): we are the side losing control.
            let wasControlled = mode == .controlled
            releaseAll()
            if mode != .idle {
                mode = .idle
                publish()
            }
            if wasControlled {
                injector.hideCursorUntilLocalInput()
                effects?.sendClipboardIfChanged()
            }
        case .heartbeat(let seq, let sentAt, let isReply):
            if isReply {
                rtt = max(0, t - sentAt)
            } else {
                effects?.send(.heartbeat(seq: seq, sentAt: sentAt, isReply: true))
            }
        case .clipboard(let items):
            effects?.applyClipboard(items)
        case .hello, .leave, .clipboardChunk: // pieces are reassembled by the session before reaching us
            break
        default:
            guard mode == .controlled else { return } // late events after we handed control back
            eventCount += 1
            if t - lastActivity > 20 {
                injector.declareUserActivity()
                lastActivity = t
            }
            inject(message)
        }
    }

    private func inject(_ message: InputMessage) {
        switch message {
        case .mouseMove(let dx, let dy):
            guard dx.isFinite, dy.isFinite else { return }
            let current = basePosition()
            let target = CGPoint(x: current.x + dx, y: current.y + dy)
            let clamped = geometry.nearestPoint(to: target)
            if pressedButtons.isEmpty,
               ScreenGeometry.isBeyond(entryEdge, target: target, clamped: clamped),
               geometry.isOuterEdge(entryEdge, at: clamped) {
                handBack(fraction: geometry.fraction(along: entryEdge, at: clamped))
                return
            }
            post(moveTo: clamped, dx: dx, dy: dy, draggingButton: pressedButtons.min())
        case .mouseButton(let button, let down, let clickState, let flags):
            let b = Int(button)
            // A click stops a wheel animation (as Mos does): the page must not keep moving under it.
            if down { endWheelGesture() }
            if down { pressedButtons.insert(b) } else { pressedButtons.remove(b) }
            self.flags = flags
            injector.postButton(b, down: down, at: basePosition(), clickState: clickState, flags: flags)
        case .scroll(let s, let flags):
            if s.isContinuous != 0 {
                // Trackpad / Magic Mouse: replay as is (after closing a wheel gesture still running).
                endWheelGesture()
                padGesture.track(s)
                padFlags = flags
                injector.postScroll(s, at: basePosition(), flags: flags)
            } else {
                scrollWheel(s, flags: flags)
            }
        case .key(let keyCode, let down, let autorepeat, let flags):
            if down { pressedKeys.insert(keyCode) } else { pressedKeys.remove(keyCode) }
            self.flags = flags
            injector.postKey(keyCode, down: down, autorepeat: autorepeat, flags: flags)
        case .flagsChanged(let keyCode, let flags):
            if let isDown = ModifierKeys.isDown(keyCode: keyCode, flags: flags) {
                if isDown { pressedModifiers.insert(keyCode) } else { pressedModifiers.remove(keyCode) }
            }
            self.flags = flags
            injector.postFlagsChanged(keyCode, flags: flags)
        case .systemDefined(let subtype, let data1, let data2, let flags):
            injector.postSystemDefined(subtype: subtype, data1: data1, data2: data2, flags: flags)
        default:
            break
        }
    }

    // MARK: Mouse wheel

    /// A mouse-wheel tick (already in the server's chosen direction): replay it as a continuous gesture
    /// with scroll phases, which scroll utilities like Mos pass through (they only smooth plain wheel
    /// events) and apps scroll by pixels.
    private func scrollWheel(_ s: ScrollData, flags: UInt64) {
        wheelFlags = flags
        let raw = WheelMath.pixels(for: s, speed: wheel.speed)
        // ⇧ + wheel = sideways (AppKit would do this for a plain wheel event, not for our gestures).
        let (dy, dx) = WheelMath.applyShift(dy: raw.dy, dx: raw.dx, flags: flags)
        if wheelLogBudget > 0 {
            wheelLogBudget -= 1
            effects?.log(String(format: "wheel tick point=%lld,%lld -> %.1f,%.1f px (%@, speed %d)",
                                s.point1, s.point2, dy, dx, wheel.smooth ? "smooth" : "immediate", wheel.speed))
        }
        if wheel.smooth {
            smoother.add(dy: dy, dx: dx, at: now)
            frameTimer.start(interval: Self.wheelFrameInterval) { [weak self] in self?.wheelTick() }
        } else {
            frameTimer.stop()
            postWheel(smoother.immediate(dy: dy, dx: dx))
        }
    }

    /// Frame timer (its own queue): post the next frames of the running wheel gesture.
    public func wheelTick() {
        lock.withLock {
            guard mode == .controlled else {
                endWheelGesture()
                return
            }
            postWheel(smoother.frames(at: now))
            if !smoother.isAnimating { frameTimer.stop() }
        }
    }

    /// Stops a running wheel animation and closes its gesture (posts `ended` if `began` was posted).
    private func endWheelGesture() {
        frameTimer.stop()
        if let end = smoother.finish() { postWheel([end]) }
    }

    /// Closes a forwarded trackpad / Magic Mouse gesture whose end will never arrive (control left this Mac
    /// mid-scroll): without it the app under the cursor stays inside a scroll / momentum gesture.
    private func endPadGesture() {
        let closing = padGesture.closingEvents()
        guard !closing.isEmpty else { return }
        let at = basePosition()
        for s in closing { injector.postScroll(s, at: at, flags: padFlags) }
    }

    private func postWheel(_ frames: [WheelFrame]) {
        guard !frames.isEmpty else { return }
        let at = basePosition()
        for f in frames { injector.postScrollFrame(f, at: at, flags: wheelFlags) }
    }

    // MARK: Cursor position

    /// The position forwarded deltas apply to. Reading the cursor right after posting a move can return
    /// the position from before that move (the window server applies posted events asynchronously), which
    /// would silently drop deltas and round away sub-pixel motion. So: if the reported location is one we
    /// posted recently (or where the cursor was when control arrived), continue from our own last position;
    /// anything else means this Mac's own trackpad / mouse moved the cursor — respect that.
    private func basePosition() -> CGPoint {
        let actual = injector.cursorLocation()
        guard let virtualCursor else { return actual }
        let stale = recentPositions.contains { abs($0.x - actual.x) <= 1 && abs($0.y - actual.y) <= 1 }
        return stale ? virtualCursor : actual
    }

    private func post(moveTo point: CGPoint, dx: Double, dy: Double, draggingButton: Int?) {
        injector.moveCursor(to: point, dx: dx, dy: dy, draggingButton: draggingButton, flags: flags)
        virtualCursor = point
        recentPositions.append(point)
        if recentPositions.count > 16 { recentPositions.removeFirst(recentPositions.count - 16) }
    }

    private func resetVirtualCursor(including previous: CGPoint? = nil) {
        virtualCursor = nil
        recentPositions = previous.map { [$0] } ?? []
    }

    // MARK: Hand-over

    private func handBack(fraction: Double) {
        mode = .idle
        // Tell the server first: its cursor reappearing is what the user waits for. Releasing our held
        // keys / buttons does not have to happen before that.
        effects?.send(.leave(fraction: fraction))
        releaseAll()
        resetVirtualCursor()
        // Symmetric with the server, which hides its cursor while it controls us.
        injector.hideCursorUntilLocalInput()
        effects?.sendClipboardIfChanged()
        publish()
    }

    /// Posts key-ups / button-ups for everything this Mac pressed on the server's behalf (and closes a
    /// running wheel gesture).
    private func releaseAll() {
        endWheelGesture()
        endPadGesture()
        if !pressedButtons.isEmpty {
            let at = basePosition()
            for b in pressedButtons.sorted() {
                injector.postButton(b, down: false, at: at, clickState: 1, flags: 0)
            }
        }
        for k in pressedKeys.sorted() {
            injector.postKey(k, down: false, autorepeat: false, flags: 0)
        }
        for m in pressedModifiers.sorted() {
            injector.postFlagsChanged(m, flags: 0)
        }
        pressedButtons.removeAll()
        pressedKeys.removeAll()
        pressedModifiers.removeAll()
        flags = 0
    }

    /// Channel closed / session torn down: release everything (keys, buttons, the display-wake assertion).
    public func peerDisconnected() {
        lock.withLock {
            releaseAll()
            resetVirtualCursor()
            injector.showCursor(reason: "session ended")
            injector.endUserActivity()
            if mode != .idle {
                mode = .idle
                publish()
            }
        }
    }

    /// Called every ~0.5 s: heartbeat + silence supervision + diagnostics.
    public func tick() {
        lock.withLock {
            let t = now
            heartbeatSeq &+= 1
            effects?.send(.heartbeat(seq: heartbeatSeq, sentAt: t, isReply: false))
            if mode == .controlled && t - lastHeard > silenceTimeout {
                // Tell the server too (if it can still hear us): otherwise it may keep swallowing input for
                // a client that now ignores it, since our heartbeats keep its own timeout from firing.
                let fraction = geometry.fraction(along: entryEdge, at: basePosition())
                releaseAll()
                mode = .idle
                resetVirtualCursor()
                effects?.send(.leave(fraction: fraction))
                // Like any other loss of control: the server (if it is still there) shows its cursor on our
                // `leave`, so ours goes away until this Mac's own mouse / trackpad is used — which is also
                // how it comes back at once if the server really is gone.
                injector.hideCursorUntilLocalInput()
                effects?.log(String(format: "nothing heard from the server for %.1f s: released held input and handed control back", t - lastHeard))
                publish()
            }
            if t - lastRateSample >= 1 {
                eventsPerSecond = Int(Double(eventCount) / max(t - lastRateSample, 0.001))
                eventCount = 0
                lastRateSample = t
                publish()
            }
        }
    }

    private var now: TimeInterval { effects?.now() ?? ProcessInfo.processInfo.systemUptime }

    private func makeSnapshot() -> Snapshot {
        Snapshot(mode: mode, rtt: rtt, eventsPerSecond: eventsPerSecond)
    }

    private func publish() {
        effects?.stateDidChange(makeSnapshot())
    }
}
