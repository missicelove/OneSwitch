import Foundation

/// CGScrollPhase values carried by synthesized wheel gestures (kCGScrollPhaseBegan/Changed/Ended).
public enum WheelPhase: Int64, Sendable {
    case began = 1
    case changed = 2
    case ended = 4
}

/// One synthesized, continuous (pixel) scroll event of a wheel gesture.
public struct WheelFrame: Equatable, Sendable, CustomStringConvertible {
    public var dy: Int32
    public var dx: Int32
    public var phase: WheelPhase

    public init(dy: Int32, dx: Int32, phase: WheelPhase) {
        self.dy = dy
        self.dx = dx
        self.phase = phase
    }

    public var description: String { "\(phase)(\(dy),\(dx))" }
}

/// Turns mouse-wheel ticks into a smooth, trackpad-like scroll gesture (pure; driven by a frame timer).
///
/// Why: scroll utilities such as Mos intercept non-continuous wheel events and re-post their own
/// smoothed events to the target process — for events injected by us that silently failed (the scroll
/// vanished). Events carrying a scroll phase are treated as trackpad input and passed through untouched,
/// and apps scroll them smoothly by pixels. So the client replays wheel input as began → changed… → ended.
///
/// Each tick restarts an ease-out curve (`duration`) over the distance still outstanding plus the new
/// tick (additive while animating; a tick in the opposite direction drops the outstanding distance on
/// that axis, as Mos does). Integer pixel deltas carry their rounding remainder, so the pixels posted over
/// a gesture add up to the requested distance.
public struct SmoothWheel: Sendable {
    public var duration: TimeInterval
    /// A curve still has distance to post.
    public private(set) var isAnimating = false
    /// `began` was posted and `ended` not yet.
    public private(set) var gestureOpen = false

    private var totalY = 0.0, totalX = 0.0        // distance of the current curve
    private var start: TimeInterval = 0
    private var progress = 0.0                    // eased fraction of the current curve already emitted
    private var exactY = 0.0, exactX = 0.0        // exact distance emitted in this gesture
    private var postedY = 0, postedX = 0          // integer pixels posted in this gesture

    public static let defaultDuration: TimeInterval = 0.28
    /// Outstanding distance is capped (pixels per axis) so a flood of ticks cannot scroll forever.
    public static let maxOutstanding = 20_000.0

    public init(duration: TimeInterval = SmoothWheel.defaultDuration) {
        self.duration = max(duration, 0.01)
    }

    /// Ease-out cubic.
    static func ease(_ p: Double) -> Double {
        let q = 1 - min(max(p, 0), 1)
        return 1 - q * q * q
    }

    /// Adds a wheel tick of (dy, dx) pixels at time `t`.
    public mutating func add(dy: Double, dx: Double, at t: TimeInterval) {
        guard dy.isFinite, dx.isFinite, dy != 0 || dx != 0 else { return }
        var leftY = 0.0, leftX = 0.0
        if isAnimating {
            leftY = totalY * (1 - progress)
            leftX = totalX * (1 - progress)
            if dy != 0 && leftY * dy < 0 { leftY = 0 } // direction reversed: drop what was left
            if dx != 0 && leftX * dx < 0 { leftX = 0 }
        }
        totalY = min(max(leftY + dy, -Self.maxOutstanding), Self.maxOutstanding)
        totalX = min(max(leftX + dx, -Self.maxOutstanding), Self.maxOutstanding)
        start = t
        progress = 0
        isAnimating = true
    }

    /// The events to post at time `t` (0–2: a delta frame and/or the closing `ended`).
    public mutating func frames(at t: TimeInterval) -> [WheelFrame] {
        guard isAnimating else { return [] }
        let p = min(max((t - start) / duration, 0), 1)
        let e = Self.ease(p)
        exactY += totalY * (e - progress)
        exactX += totalX * (e - progress)
        progress = e
        let targetY = Int(exactY.rounded()), targetX = Int(exactX.rounded())
        let dy = targetY - postedY, dx = targetX - postedX
        postedY = targetY
        postedX = targetX
        var out: [WheelFrame] = []
        if dy != 0 || dx != 0 {
            out.append(WheelFrame(dy: Int32(clamping: dy), dx: Int32(clamping: dx), phase: gestureOpen ? .changed : .began))
            gestureOpen = true
        }
        if p >= 1 {
            isAnimating = false
            if let end = closeGesture() { out.append(end) }
        }
        return out
    }

    /// Stops at once (a click, control leaving this Mac, a trackpad scroll): the closing `ended` if a
    /// gesture is open. The outstanding distance is dropped.
    public mutating func finish() -> WheelFrame? {
        isAnimating = false
        return closeGesture()
    }

    /// A whole gesture posted at once (smooth scrolling off): began with the full distance, then ended.
    /// Closes an open smooth gesture first.
    public mutating func immediate(dy: Double, dx: Double) -> [WheelFrame] {
        var out: [WheelFrame] = []
        if let end = finish() { out.append(end) }
        guard dy.isFinite, dx.isFinite else { return out }
        let iy = Int32(clamping: Int(min(max(dy, -Self.maxOutstanding), Self.maxOutstanding).rounded()))
        let ix = Int32(clamping: Int(min(max(dx, -Self.maxOutstanding), Self.maxOutstanding).rounded()))
        guard iy != 0 || ix != 0 else { return out }
        out.append(WheelFrame(dy: iy, dx: ix, phase: .began))
        out.append(WheelFrame(dy: 0, dx: 0, phase: .ended))
        return out
    }

    private mutating func closeGesture() -> WheelFrame? {
        let wasOpen = gestureOpen
        gestureOpen = false
        exactY = 0; exactX = 0
        postedY = 0; postedX = 0
        totalY = 0; totalX = 0
        progress = 0
        return wasOpen ? WheelFrame(dy: 0, dx: 0, phase: .ended) : nil
    }
}

/// Follows the phases of a forwarded trackpad / Magic Mouse scroll (pure). When control leaves this Mac
/// mid-gesture the rest of it — its `ended`, or the end of its momentum — never arrives here, so the client
/// posts the closing events itself (`closingEvents()`).
///
/// CG values: scroll phase began 1, changed 2, ended 4, cancelled 8, may-begin 128; momentum phase
/// begin 1, continue 2, end 3.
public struct PadGestureTracker: Equatable, Sendable {
    /// Last scroll phase of a gesture still open (began / changed / may-begin), else nil.
    public private(set) var openScrollPhase: Int64?
    /// Momentum (inertia) scrolling started and has not ended.
    public private(set) var momentumOpen = false

    public init() {}

    public mutating func track(_ s: ScrollData) {
        switch s.scrollPhase {
        case 1, 2, 128:
            openScrollPhase = s.scrollPhase
            momentumOpen = false // fingers back on the pad: any momentum is over
        case 4, 8:
            openScrollPhase = nil
        default:
            break
        }
        switch s.momentumPhase {
        case 1, 2:
            momentumOpen = true
            openScrollPhase = nil
        case 3:
            momentumOpen = false
        default:
            break
        }
    }

    /// Events that close whatever is open (zero deltas): cancelled for a gesture that only "may begin",
    /// ended for a running one, momentum end for inertia scrolling. Resets the tracker.
    public mutating func closingEvents() -> [ScrollData] {
        var out: [ScrollData] = []
        if let phase = openScrollPhase {
            var s = ScrollData()
            s.isContinuous = 1
            s.scrollPhase = phase == 128 ? 8 : 4
            out.append(s)
        }
        if momentumOpen {
            var s = ScrollData()
            s.isContinuous = 1
            s.momentumPhase = 3
            out.append(s)
        }
        self = PadGestureTracker()
        return out
    }
}

/// Server side: a trackpad / Magic Mouse scroll gesture — including the momentum after the fingers lift —
/// stays on the Mac where it began, like a key goes up where it went down (pure; covered by the checks).
/// Otherwise switching mid-scroll leaves the app on one Mac inside a gesture whose end never comes, and
/// scrolls whatever is under the cursor on the other Mac with a gesture tail it never saw begin.
public struct PadGestureOwner: Equatable, Sendable {
    /// The current / last gesture was started while the other Mac was controlled.
    public private(set) var remote = false
    private var lastPhase: Int64 = 0
    private var lastAt: TimeInterval = -.infinity

    /// Events of one gesture follow each other closely (≈ 60–120 Hz, momentum included); after a longer gap
    /// the next event is treated as a new gesture.
    public static let maxGap: TimeInterval = 0.5

    public init() {}

    /// Whether the continuous scroll `s` belongs to the other Mac. `remoteNow`: it is controlled right now.
    public mutating func route(_ s: ScrollData, remoteNow: Bool, at t: TimeInterval) -> Bool {
        let phased = s.scrollPhase != 0 || s.momentumPhase != 0
        guard phased else { return remoteNow } // phase-less smooth scrolling: no gesture to keep together
        // may-begin, or began not preceded by may-begin, starts a gesture; so does anything after a pause.
        let starts = s.scrollPhase == 128 || (s.scrollPhase == 1 && lastPhase != 128) || t - lastAt > Self.maxGap
        if starts { remote = remoteNow }
        if s.scrollPhase != 0 { lastPhase = s.scrollPhase }
        lastAt = t
        return remote
    }
}

/// Calls a handler at a steady rate while a wheel gesture animates. Real: `DispatchFrameTimer`;
/// checks drive frames by hand.
public protocol FrameTimer: AnyObject {
    /// Starts calling `handler` about every `interval` seconds (no-op while already running).
    func start(interval: TimeInterval, handler: @escaping @Sendable () -> Void)
    func stop()
}

/// ~120 Hz frames on a dedicated high-priority queue (never the main thread).
final class DispatchFrameTimer: FrameTimer, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "oneswitch.input.wheel", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    func start(interval: TimeInterval, handler: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .microseconds(500))
            t.setEventHandler(handler: handler)
            t.resume()
            timer = t
        }
    }

    func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }

    deinit { timer?.cancel() }
}
