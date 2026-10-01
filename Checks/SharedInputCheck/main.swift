import AppKit
import CoreGraphics
import Foundation
import OneSwitchCore
@testable import SharedInput

// Self-checks for 键鼠共享. Pure logic + fakes only: no event taps, no posted events, no cursor moves.

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message) (line \(line))")
    }
}

@MainActor
func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    return condition()
}

// MARK: - Fakes

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    var now: TimeInterval { lock.withLock { t } }
    func advance(_ dt: TimeInterval) { lock.withLock { t += dt } }
}

final class FakeServerEffects: ServerEffects, @unchecked Sendable {
    let clock: FakeClock
    private let lock = NSLock()
    private(set) var sent: [InputMessage] = []
    private(set) var parkedAt: CGPoint?
    private(set) var restoredAt: CGPoint?
    private(set) var keyboardCapture = false
    private(set) var clipboardRequests = 0
    private var appliedClipboards: [[ClipboardItem]] = []
    /// Effects in call order ("restore", "capture off", "send releaseAll", …).
    private var calls: [String] = []
    var forward: ((InputMessage) -> Void)?
    var canHide = true
    var canHideCursor: Bool { lock.withLock { canHide } }

    init(clock: FakeClock) { self.clock = clock }

    func send(_ message: InputMessage) {
        lock.withLock {
            sent.append(message)
            if case .releaseAll = message { calls.append("send releaseAll") }
        }
        forward?(message)
    }
    func parkCursor(at point: CGPoint) { lock.withLock { parkedAt = point; restoredAt = nil; calls.append("park") } }
    func keepCursorParked(at point: CGPoint) {}
    func restoreCursor(at point: CGPoint) { lock.withLock { restoredAt = point; parkedAt = nil; calls.append("restore") } }
    func setKeyboardCapture(_ enabled: Bool) { lock.withLock { keyboardCapture = enabled; calls.append(enabled ? "capture on" : "capture off") } }
    func sendClipboardIfChanged() { lock.withLock { clipboardRequests += 1 } }
    func applyClipboard(_ items: [ClipboardItem]) { lock.withLock { appliedClipboards.append(items) } }
    var applied: [[ClipboardItem]] { lock.withLock { appliedClipboards } }
    var callLog: [String] { lock.withLock { calls } }
    func clearCalls() { lock.withLock { calls.removeAll() } }
    func stateDidChange(_ snapshot: ServerCore.Snapshot) {}
    func now() -> TimeInterval { clock.now }

    var sentSnapshot: [InputMessage] { lock.withLock { sent } }
    func clear() { lock.withLock { sent.removeAll() } }
    var capture: Bool { lock.withLock { keyboardCapture } }
    var restored: CGPoint? { lock.withLock { restoredAt } }
    var parked: CGPoint? { lock.withLock { parkedAt } }
}

final class FakeInjector: EventInjector, @unchecked Sendable {
    private let lock = NSLock()
    var canInject = true
    private var cursor = CGPoint.zero
    private(set) var log: [String] = []
    /// > 0: `cursorLocation()` reports the position from that many moves ago, like a window server that
    /// has not yet applied the events we just posted.
    var readLag = 0
    private var history: [CGPoint] = []
    private(set) var activityReleases = 0

    func cursorLocation() -> CGPoint {
        lock.withLock {
            guard readLag > 0, !history.isEmpty else { return cursor }
            return history[max(0, history.count - 1 - readLag)]
        }
    }
    /// Simulates this Mac's own trackpad moving the cursor.
    func userMovedCursor(to point: CGPoint) { lock.withLock { cursor = point; history.append(point) } }
    func endUserActivity() { lock.withLock { activityReleases += 1 } }
    func moveCursor(to point: CGPoint, dx: Double, dy: Double, draggingButton: Int?, flags: UInt64) {
        lock.withLock {
            if history.isEmpty { history.append(cursor) }
            history.append(point)
            cursor = point
            log.append(draggingButton == nil ? "move \(Int(point.x)),\(Int(point.y))" : "drag\(draggingButton!) \(Int(point.x)),\(Int(point.y))")
        }
    }
    func postButton(_ button: Int, down: Bool, at point: CGPoint, clickState: Int64, flags: UInt64) {
        lock.withLock { log.append("button\(button) \(down ? "down" : "up") click\(clickState)") }
    }
    private var scrolls: [ScrollData] = []
    func postScroll(_ scroll: ScrollData, at point: CGPoint, flags: UInt64) {
        lock.withLock { scrolls.append(scroll); log.append("scroll \(scroll.point1)") }
    }
    /// Forwarded (continuous) scroll events posted, in order.
    var postedScrolls: [ScrollData] { lock.withLock { scrolls } }
    func clearScrolls() { lock.withLock { scrolls.removeAll() } }
    private var frames: [WheelFrame] = []
    func postScrollFrame(_ frame: WheelFrame, at point: CGPoint, flags: UInt64) {
        lock.withLock { frames.append(frame); log.append("wheel \(frame)") }
    }
    var wheelFrames: [WheelFrame] { lock.withLock { frames } }
    func clearFrames() { lock.withLock { frames.removeAll() } }
    func postKey(_ keyCode: UInt16, down: Bool, autorepeat: Bool, flags: UInt64) {
        lock.withLock { log.append("key\(keyCode) \(down ? "down" : "up")\(autorepeat ? " repeat" : "")") }
    }
    func postFlagsChanged(_ keyCode: UInt16, flags: UInt64) { lock.withLock { log.append("flags\(keyCode) \(flags)") } }
    func postSystemDefined(subtype: Int16, data1: Int64, data2: Int64, flags: UInt64) { lock.withLock { log.append("sys\(subtype) \(data1)") } }
    func declareUserActivity() { lock.withLock { log.append("activity") } }
    private var hidden = false
    func hideCursorUntilLocalInput() { lock.withLock { hidden = true; log.append("cursor hidden") } }
    func showCursor(reason: String) { lock.withLock { hidden = false; log.append("cursor shown") } }
    /// This Mac's cursor as the window server would show it.
    var cursorHidden: Bool { lock.withLock { hidden } }
    /// The reveal monitor saw real local input.
    func localInput() { showCursor(reason: "local input") }

    var entries: [String] { lock.withLock { log } }
    var position: CGPoint { lock.withLock { cursor } }
    func clear() { lock.withLock { log.removeAll() } }
}

final class FakeClientEffects: ClientEffects, @unchecked Sendable {
    let clock: FakeClock
    private let lock = NSLock()
    private(set) var sent: [InputMessage] = []
    private var clipboardCount = 0
    private var appliedClipboards: [[ClipboardItem]] = []
    var forward: ((InputMessage) -> Void)?
    /// What `currentGeometry()` reports (nil: the core keeps its stored geometry).
    var liveGeometry: ScreenGeometry?

    init(clock: FakeClock) { self.clock = clock }

    func currentGeometry() -> ScreenGeometry? { lock.withLock { liveGeometry } }

    func send(_ message: InputMessage) {
        lock.withLock { sent.append(message) }
        forward?(message)
    }
    func sendClipboardIfChanged() { lock.withLock { clipboardCount += 1 } }
    var clipboardRequests: Int { lock.withLock { clipboardCount } }
    func applyClipboard(_ items: [ClipboardItem]) { lock.withLock { appliedClipboards.append(items) } }
    var applied: [[ClipboardItem]] { lock.withLock { appliedClipboards } }
    func stateDidChange(_ snapshot: ClientCore.Snapshot) {}
    func now() -> TimeInterval { clock.now }
    var sentSnapshot: [InputMessage] { lock.withLock { sent } }
    func clear() { lock.withLock { sent.removeAll() } }
}

/// Frames are fired by hand (with the fake clock) instead of a real 120 Hz timer.
final class FakeFrameTimer: FrameTimer, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var startCount = 0
    var running: Bool { lock.withLock { handler != nil } }
    var starts: Int { lock.withLock { startCount } }
    func start(interval: TimeInterval, handler: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard self.handler == nil else { return }
            self.handler = handler
            startCount += 1
        }
    }
    func stop() { lock.withLock { handler = nil } }
    func fire() { let h = lock.withLock { handler }; h?() }
}

/// In-memory defaults: a real suite leaves an (empty) plist in ~/Library/Preferences behind.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]
    init() { super.init(suiteName: nil)! }
    override func object(forKey defaultName: String) -> Any? { lock.withLock { storage[defaultName] } }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func set(_ value: Any?, forKey defaultName: String) { lock.withLock { storage[defaultName] = value } }
    override func removeObject(forKey defaultName: String) { lock.withLock { storage[defaultName] = nil } }
}

func move(_ x: CGFloat, _ y: CGFloat, dx: Double = 0, dy: Double = 0, flags: UInt64 = 0) -> CapturedEvent {
    CapturedEvent(kind: .mouseMoved, location: CGPoint(x: x, y: y), dx: dx, dy: dy, flags: flags)
}

let cmd = CGEventFlags.maskCommand.rawValue
let ctrl = CGEventFlags.maskControl.rawValue
let opt = CGEventFlags.maskAlternate.rawValue
let shift = CGEventFlags.maskShift.rawValue

// MARK: - Codec

func checkCodec() {
    print("Codec round-trips")
    var s = ScrollData()
    s.delta1 = -3; s.point2 = 17; s.fixed1 = -2.5; s.isContinuous = 1; s.scrollPhase = 2; s.momentumPhase = 3; s.scrollCount = 4
    let messages: [InputMessage] = [
        .hello(InputHello(role: .server, deviceName: "测试 Mac Studio 工作站", ready: true, clientSide: .left)),
        .enter(edge: .top, fraction: 0.3125, center: true, flags: cmd | shift),
        .leave(fraction: 0.99),
        .releaseAll,
        .heartbeat(seq: 42, sentAt: 12345.678, isReply: true),
        .clipboard([ClipboardItem(type: "public.utf8-plain-text", data: Data("你好".utf8)), ClipboardItem(type: "public.png", data: Data([0, 1, 2, 255]))]),
        .mouseMove(dx: -1.5, dy: 42.25),
        .mouseButton(button: 4, down: true, clickState: 2, flags: opt),
        .scroll(s, flags: ctrl),
        .key(keyCode: 0x7B, down: false, autorepeat: true, flags: cmd | ctrl),
        .flagsChanged(keyCode: 55, flags: cmd),
        .systemDefined(subtype: 8, data1: 0x100A00, data2: -1, flags: 0),
    ]
    for m in messages {
        let (type, payload) = m.encode()
        let decoded = try? InputMessage.decode(type: type, payload: payload)
        check(decoded == m, "round-trip \(String(describing: m).prefix(40))")
        check(PeerLimits.serviceTypeRange.contains(type), "type 0x\(String(type, radix: 16)) in service range")
    }
    check((try? InputMessage.decode(type: 0x0013, payload: Data([1, 2]))) == nil, "truncated payload rejected")
    check((try? InputMessage.decode(type: 0x0999, payload: Data())) == nil, "unknown type rejected")
    check((try? InputMessage.decode(type: 0x0002, payload: Data([9] + [UInt8](repeating: 0, count: 17)))) == nil, "bad edge rejected")
}

// MARK: - Geometry

func checkGeometry() {
    print("Screen geometry")
    // Main 2560x1440 at origin, second 1920x1080 to the right, offset down by 200.
    let g = ScreenGeometry(displays: [CGRect(x: 2560, y: 200, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 2560, height: 1440)])
    check(g.mainDisplay == CGRect(x: 0, y: 0, width: 2560, height: 1440), "main display sorted first")
    check(g.union == CGRect(x: 0, y: 0, width: 4480, height: 1440), "union")
    // Right edge of the main display borders the second display for y in 200..<1280 → not outer.
    check(!g.isPushing(.right, at: CGPoint(x: 2559, y: 500), dx: 5, dy: 0), "inner edge (y=500) does not trigger")
    check(g.isPushing(.right, at: CGPoint(x: 2559, y: 100), dx: 5, dy: 0), "main right edge above the second display is outer (y=100)")
    check(g.isPushing(.right, at: CGPoint(x: 4479, y: 700), dx: 3, dy: 0), "far right edge triggers")
    check(!g.isPushing(.right, at: CGPoint(x: 4479, y: 700), dx: -3, dy: 0), "moving away does not trigger")
    check(!g.isPushing(.right, at: CGPoint(x: 4000, y: 700), dx: 3, dy: 0), "not at edge")
    check(g.isPushing(.left, at: CGPoint(x: 0, y: 700), dx: -1, dy: 0), "left outer edge")
    check(!g.isPushing(.left, at: CGPoint(x: 2560, y: 700), dx: -1, dy: 0), "second display's left edge is inner")
    check(g.isPushing(.top, at: CGPoint(x: 3000, y: 200), dx: 0, dy: -2), "top of offset display is outer")
    check(g.isPushing(.bottom, at: CGPoint(x: 100, y: 1439), dx: 0, dy: 2), "bottom outer edge of main")
    check(g.isPushing(.bottom, at: CGPoint(x: 3000, y: 1279), dx: 0, dy: 1), "bottom of second display is outer")

    // Stacked: external above the main display.
    let stacked = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: -200, y: -1080, width: 1920, height: 1080)])
    check(!stacked.isPushing(.top, at: CGPoint(x: 500, y: 0), dx: 0, dy: -4), "top edge under the upper display is inner")
    check(stacked.isPushing(.top, at: CGPoint(x: 500, y: -1080), dx: 0, dy: -4), "top of upper display is outer")
    check(stacked.isPushing(.right, at: CGPoint(x: 1719, y: -500), dx: 1, dy: 0), "right edge of upper display is outer")

    // Fractions and entry points.
    let single = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982)])
    let p = single.entryPoint(on: .left, fraction: 0.5)
    check(p.x == 8 && abs(p.y - 490.5) <= 1, "entry left at middle, 8 pt inside the edge -> \(p)")
    check(abs(single.fraction(along: .left, at: p) - 0.5) < 0.002, "fraction round-trip")
    let r = g.entryPoint(on: .right, fraction: 0.05)
    check(r.x == 2551 && r.y < 200, "entry right at 5% lands on main display's outer right edge -> \(r)")
    let r2 = g.entryPoint(on: .right, fraction: 0.5)
    check(r2.x == 4471, "entry right at 50% lands on far right display -> \(r2)")
    let gap = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1000, height: 500), CGRect(x: 1000, y: 800, width: 1000, height: 500)])
    let r3 = gap.entryPoint(on: .left, fraction: 0.5) // y≈650 lies in a vertical gap
    check(gap.display(containing: r3) != nil, "entry point in a gap is clamped onto a display -> \(r3)")
    check(gap.nearestPoint(to: CGPoint(x: 1200, y: 600)) == CGPoint(x: 1200, y: 800), "nearestPoint clamps into the closest display")
    check(gap.nearestPoint(to: CGPoint(x: -50, y: 100)) == CGPoint(x: 0, y: 100), "nearestPoint clamps x")
}

// MARK: - Server state machine

func checkServer() {
    print("Server state machine")
    let clock = FakeClock()
    let fx = FakeServerEffects(clock: clock)
    let geometry = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 2560, height: 1440)])
    var config = ServerCore.Config()
    config.clientSide = .right
    config.switchHotKey = (49, ctrl | opt | cmd)
    let core = ServerCore(geometry: geometry, config: config, effects: fx)

    check(core.handle(move(2559, 700, dx: 5)), "offline: events pass")
    check(core.currentMode == .offline && fx.sentSnapshot.isEmpty, "offline: never switches")
    core.setPeerReady(true)
    check(core.currentMode == .local, "peer ready -> local")
    check(!fx.capture, "keyboard capture off in local mode")

    // Button held blocks switching.
    check(core.handle(CapturedEvent(kind: .mouseDown(button: 0), location: CGPoint(x: 2500, y: 700))), "button down passes")
    check(core.handle(CapturedEvent(kind: .mouseDragged(button: 0), location: CGPoint(x: 2559, y: 700), dx: 4)), "drag at edge passes (blocked)")
    check(core.currentMode == .local, "no switch while button held")
    _ = core.handle(CapturedEvent(kind: .mouseUp(button: 0), location: CGPoint(x: 2559, y: 700)))

    // Edge push switches.
    check(core.handle(move(2000, 700, dx: 5)), "normal move passes")
    check(!core.handle(move(2559, 720, dx: 6, flags: shift)), "edge push is swallowed")
    check(core.currentMode == .remote, "switched to remote")
    check(fx.capture, "keyboard capture enabled only in remote")
    check(fx.parked == geometry.mainCenter, "cursor parked at centre")
    if case .enter(let edge, let f, let center, let flags)? = fx.sentSnapshot.last {
        check(edge == .left && !center && abs(f - 720.0 / 1439.0) < 0.001 && flags == shift, "enter(left, fraction, shift held)")
    } else { check(false, "enter sent") }
    fx.clear()

    // Forwarding & routing.
    check(!core.handle(move(1283, 718, dx: 3, dy: -2)), "moves swallowed")
    check(!core.handle(CapturedEvent(kind: .keyDown(keyCode: 0, autorepeat: false), flags: shift)), "key down swallowed")
    check(core.handle(CapturedEvent(kind: .keyUp(keyCode: 12))), "key-up of a key pressed before switching passes locally")
    check(!core.handle(CapturedEvent(kind: .keyUp(keyCode: 0))), "key-up of a forwarded key is swallowed")
    check(core.handle(CapturedEvent(kind: .flagsChanged(keyCode: 56), flags: 0)), "release of shift held at entry passes locally")
    check(!core.handle(CapturedEvent(kind: .flagsChanged(keyCode: 55), flags: cmd)), "new modifier press forwarded")
    check(!core.handle(CapturedEvent(kind: .systemDefined(subtype: 8, data1: 1, data2: 0))), "media key forwarded")
    check(core.handle(CapturedEvent(kind: .systemDefined(subtype: 7, data1: 1, data2: 0))), "other system-defined passes")
    check(!core.handle(CapturedEvent(kind: .mouseDown(button: 1), clickState: 2)), "right button forwarded")
    check(!core.handle(CapturedEvent(kind: .mouseUp(button: 1))), "right button up forwarded")
    let sent = fx.sentSnapshot
    check(sent.contains(.mouseMove(dx: 3, dy: -2)), "mouseMove sent")
    check(sent.contains(.key(keyCode: 0, down: true, autorepeat: false, flags: shift)), "key down sent")
    check(sent.contains(.key(keyCode: 0, down: false, autorepeat: false, flags: 0)), "key up sent")
    check(!sent.contains(where: { if case .key(12, _, _, _) = $0 { return true }; return false }), "local key never forwarded")
    check(sent.contains(.flagsChanged(keyCode: 55, flags: cmd)), "flagsChanged sent")
    check(sent.contains(.mouseButton(button: 1, down: true, clickState: 2, flags: 0)), "button with click state sent")

    // Leave from client → back to local at the right edge.
    fx.clear()
    core.receive(.leave(fraction: 0.25))
    check(core.currentMode == .local, "leave -> local")
    check(!fx.capture, "keyboard capture disabled after return")
    let expected = geometry.entryPoint(on: .right, fraction: 0.25)
    check(fx.restored == expected, "cursor restored at the right edge, same fraction")
    check(!fx.sentSnapshot.contains(.releaseAll), "no releaseAll needed when the client handed back")
    check(core.handle(move(2559, 300, dx: 4)), "cooldown prevents immediate re-switch")
    clock.advance(0.3)
    check(!core.handle(move(2559, 300, dx: 4)), "after cooldown edge switches again")

    // Hotkey inside the tap returns.
    fx.clear()
    check(!core.handle(CapturedEvent(kind: .keyDown(keyCode: 49, autorepeat: false), flags: ctrl | opt | cmd)), "hotkey swallowed")
    check(core.currentMode == .local, "hotkey returned control")
    check(fx.sentSnapshot.contains(.releaseAll), "releaseAll sent on hotkey return")
    check(fx.restored == geometry.mainCenter, "cursor restored at park point")

    // Heartbeat timeout.
    clock.advance(1)
    check(core.switchToRemote(), "manual switch")
    if case .enter(_, _, let center, _)? = fx.sentSnapshot.last { check(center, "manual switch enters at centre") }
    core.tick()
    check(core.currentMode == .remote, "still remote before timeout")
    clock.advance(2.5)
    core.tick()
    check(core.currentMode == .local, "heartbeat timeout returns to local")

    // Tap disabled / disconnect while remote.
    clock.advance(1)
    _ = core.switchToRemote()
    core.tapWasDisabled()
    check(core.currentMode == .local, "tap disabled returns to local")
    _ = core.switchToRemote()
    core.setPeerReady(false, reason: "test")
    check(core.currentMode == .offline && fx.restored != nil && !fx.capture, "disconnect while remote restores cursor & capture")

    // Required modifier + dwell.
    core.setPeerReady(true)
    config.requiredModifierMask = ctrl
    config.dwell = 0.2
    core.update(config: config)
    clock.advance(1)
    check(core.handle(move(2559, 500, dx: 5)), "required modifier missing -> pass")
    check(core.handle(move(2559, 500, dx: 5, flags: ctrl)), "dwell starts")
    clock.advance(0.1)
    check(core.handle(move(2559, 500, dx: 5, flags: ctrl)), "dwell not yet reached")
    clock.advance(0.15)
    check(!core.handle(move(2559, 500, dx: 5, flags: ctrl)), "dwell reached -> switch")
    check(core.currentMode == .remote, "remote after dwell")
}

// MARK: - Client state machine

func checkClient() {
    print("Client state machine")
    let clock = FakeClock()
    let fx = FakeClientEffects(clock: clock)
    let inj = FakeInjector()
    let geometry = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982)])
    let core = ClientCore(geometry: geometry, injector: inj, effects: fx)

    core.receive(.mouseMove(dx: 5, dy: 5))
    check(inj.entries.isEmpty, "input ignored while idle")
    core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0))
    check(core.currentMode == .controlled, "enter -> controlled")
    check(inj.position.x == 8, "cursor placed just inside the left edge")
    core.receive(.mouseMove(dx: 100, dy: -1000))
    check(inj.position == CGPoint(x: 108, y: 0), "clamped to top")
    core.receive(.key(keyCode: 0, down: true, autorepeat: false, flags: cmd))
    core.receive(.flagsChanged(keyCode: 55, flags: cmd))
    core.receive(.mouseButton(button: 0, down: true, clickState: 1, flags: 0))
    core.receive(.mouseMove(dx: -500, dy: 0))
    check(core.currentMode == .controlled, "no hand-back while a button is held (drag)")
    check(inj.entries.contains("drag0 0,0"), "drag event posted while button held")
    core.receive(.mouseButton(button: 0, down: false, clickState: 1, flags: 0))
    inj.clear()
    core.receive(.mouseMove(dx: -10, dy: 0))
    check(core.currentMode == .idle, "pushing through the entry edge hands control back")
    if case .leave(let f)? = fx.sentSnapshot.last { check(f == 0, "leave fraction at top = 0") } else { check(false, "leave sent") }
    check(inj.entries.contains("key0 up") && inj.entries.contains("flags55 0"), "held key & modifier released on hand-back")
    inj.clear()
    core.receive(.key(keyCode: 1, down: true, autorepeat: false, flags: 0))
    check(inj.entries.isEmpty, "late events after hand-back ignored")

    core.receive(.enter(edge: .left, fraction: 0.1, center: true, flags: 0))
    check(inj.position == geometry.mainCenter, "centre entry")
    core.receive(.key(keyCode: 3, down: true, autorepeat: false, flags: 0))
    core.receive(.key(keyCode: 3, down: true, autorepeat: true, flags: 0))
    check(inj.entries.contains("key3 down repeat"), "autorepeat forwarded")
    core.receive(.releaseAll)
    check(inj.entries.contains("key3 up") && core.currentMode == .idle, "releaseAll releases and idles")

    core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0))
    core.receive(.key(keyCode: 4, down: true, autorepeat: false, flags: 0))
    clock.advance(4)
    core.tick()
    check(core.currentMode == .idle && inj.entries.contains("key4 up"), "silence timeout releases keys")

    inj.canInject = false
    core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0))
    check(core.currentMode == .idle, "without permission the client refuses control")

    // Cursor symmetry: hidden while the server has control, shown when control arrives / session ends.
    inj.canInject = true
    inj.clear()
    core.receive(.enter(edge: .right, fraction: 0.5, center: false, flags: 0))
    check(inj.entries.first == "cursor shown", "enter shows this Mac's cursor first")
    core.receive(.mouseMove(dx: 30, dy: 0))
    check(core.currentMode == .idle && inj.entries.contains("cursor hidden"), "handing back through the edge hides this Mac's cursor")
    inj.clear()
    core.receive(.enter(edge: .right, fraction: 0.5, center: false, flags: 0))
    core.receive(.releaseAll)
    check(inj.entries.last == "cursor hidden", "server taking control back (hotkey) hides this Mac's cursor")
    core.peerDisconnected()
    check(inj.entries.last == "cursor shown", "disconnect shows the cursor again")

    // Session set up during a dark wake: the displays read as empty, and lighting them posts no change.
    // The next arrival must re-read them, or the cursor can never reach the edge back to the server.
    let staleFx = FakeClientEffects(clock: clock)
    let staleInj = FakeInjector()
    let stale = ClientCore(geometry: ScreenGeometry(displays: []), injector: staleInj, effects: staleFx)
    staleFx.liveGeometry = geometry
    stale.receive(.enter(edge: .right, fraction: 0.5, center: false, flags: 0))
    check(staleInj.position.x == 1503, "arrival after a dark wake uses the re-read displays")
    stale.receive(.mouseMove(dx: 30, dy: 0))
    check(stale.currentMode == .idle, "…so pushing through the entry edge hands control back")
    staleFx.liveGeometry = ScreenGeometry(displays: [])
    stale.receive(.enter(edge: .right, fraction: 0.5, center: false, flags: 0))
    check(staleInj.position.x == 1503, "an empty re-read keeps the last valid displays")
}

// MARK: - Readiness

func checkReadiness() {
    print("Readiness / role conflicts")
    let peerClient = InputHello(role: .client, deviceName: "MBP", ready: true, clientSide: .right)
    let peerServer = InputHello(role: .server, deviceName: "Studio", ready: true, clientSide: .left)
    check(InputReadiness.evaluate(localRole: .server, tapRunning: true, canInject: false, peer: peerClient).ready, "server + client ready")
    check(InputReadiness.evaluate(localRole: .server, tapRunning: true, canInject: true, peer: peerServer).problem?.contains("冲突") == true, "server/server conflict")
    check(InputReadiness.evaluate(localRole: .client, tapRunning: false, canInject: true, peer: peerClient).problem?.contains("冲突") == true, "client/client conflict")
    check(InputReadiness.evaluate(localRole: .server, tapRunning: false, canInject: true, peer: peerClient).problem?.contains("权限") == true, "server without tap")
    var notReady = peerClient
    notReady.ready = false
    check(InputReadiness.evaluate(localRole: .server, tapRunning: true, canInject: true, peer: notReady).problem?.contains("辅助功能") == true, "client lacking permission")
    check(InputReadiness.evaluate(localRole: .client, tapRunning: false, canInject: true, peer: peerServer).ready, "client + server ready")
    check(!InputReadiness.evaluate(localRole: .client, tapRunning: false, canInject: false, peer: peerServer).ready, "client without permission")
    var old = peerServer
    old.version = 99
    check(InputReadiness.evaluate(localRole: .client, tapRunning: false, canInject: true, peer: old).problem?.contains("版本") == true, "version mismatch")
    check(!InputReadiness.evaluate(localRole: .server, tapRunning: true, canInject: true, peer: nil).ready, "no peer yet")
}

// MARK: - Warp artifact (regression: client handed control back within ms after crossing the LEFT edge)

func checkWarpArtifact() {
    print("Motion after parking (warp artifact)")
    let clock = FakeClock()
    let fx = FakeServerEffects(clock: clock)
    let g = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1920, height: 1080)])
    var config = ServerCore.Config()
    config.clientSide = .left
    let core = ServerCore(geometry: g, config: config, effects: fx)
    core.setPeerReady(true)
    _ = core.handle(move(0, 500, dx: -6))
    check(core.currentMode == .remote, "left-edge push switches")
    fx.clear()
    // macOS folds the +960/+40 park warp into the next event's delta: only the real motion (-3) remains.
    _ = core.handle(move(960, 540, dx: 957, dy: 40))
    check(fx.sentSnapshot == [.mouseMove(dx: -3, dy: 0)], "the warp artifact is subtracted, the real motion kept -> \(fx.sentSnapshot)")
    fx.clear()
    _ = core.handle(move(959.8, 540, dx: -1, dy: 0))
    _ = core.handle(move(959.8, 540, dx: 0, dy: 0))
    _ = core.handle(move(955, 539, dx: -4, dy: 0))
    check(fx.sentSnapshot == [.mouseMove(dx: -1, dy: 0), .mouseMove(dx: -4, dy: 0)],
          "device deltas forwarded, zero deltas skipped, positions ignored -> \(fx.sentSnapshot)")
    fx.clear()
    for _ in 0..<5 { _ = core.handle(move(960, 540, dx: -10, dy: 0)) }
    check(fx.sentSnapshot == Array(repeating: .mouseMove(dx: -10, dy: 0), count: 5), "steady motion forwarded 1:1")
    fx.clear()
    // Only one artifact is expected per warp: a later large real move is kept whole.
    _ = core.handle(move(960, 540, dx: 950, dy: 40))
    check(fx.sentSnapshot == [.mouseMove(dx: 950, dy: 40)], "no second artifact after the first one")
    fx.clear()
    // The hidden (attached) cursor wandered 460 pt off: it is re-centred, and that warp's +460 artifact is
    // subtracted from the next event, keeping its real -2.
    _ = core.handle(move(500, 540, dx: -10, dy: 0))
    _ = core.handle(move(960, 540, dx: 458, dy: 0))
    _ = core.handle(move(960, 540, dx: -3, dy: 0))
    check(fx.sentSnapshot == [.mouseMove(dx: -10, dy: 0), .mouseMove(dx: -2, dy: 0), .mouseMove(dx: -3, dy: 0)],
          "re-centring artifact subtracted, real motion kept -> \(fx.sentSnapshot)")
    fx.clear()
    // A delta that does not contain the artifact (macOS did not fold it) is forwarded unchanged.
    _ = core.handle(move(700, 540, dx: -12, dy: 0))   // drift 260 → re-centre, artifact +260 armed
    _ = core.handle(move(960, 540, dx: -8, dy: 0))    // no artifact folded in: -8 is real
    check(fx.sentSnapshot == [.mouseMove(dx: -12, dy: 0), .mouseMove(dx: -8, dy: 0)], "unfolded delta kept -> \(fx.sentSnapshot)")
    // Small wander inside the re-centre distance does not warp.
    check(ServerCore.recentreDistance >= 150, "re-centring only after a real excursion (≥ 150 pt)")
    // The artifact window expires: an equal-looking delta long after the warp is real motion.
    clock.advance(1)
    _ = core.handle(move(0, 0, dx: 5, dy: 0))
    fx.clear()
    clock.advance(1)
    _ = core.handle(move(960, 540, dx: 960, dy: 540))
    check(fx.sentSnapshot == [.mouseMove(dx: 960, dy: 540)], "after the window, large deltas are real motion")
}

// MARK: - Tap disable policy (regression: control bounced back right after crossing)

func checkTapDisablePolicy() {
    print("Tap disable policy")
    check(!TapDisablePolicy.takesControlBack(.tapDisabledByUserInput), "disabled-by-user-input never hands control back")
    check(TapDisablePolicy.takesControlBack(.tapDisabledByTimeout), "timeout hands control back")
    check(!TapDisablePolicy.takesControlBack(.mouseMoved), "ordinary events are not disable notices")
}

// MARK: - End to end over LoopbackPeerHub

@MainActor
func checkEndToEnd() {
    print("End to end (server ⇄ client over LoopbackPeerHub)")
    let (hubA, hubB) = LoopbackPeerHub.makePair(nameA: "Studio", nameB: "MBP")
    final class Box<T>: @unchecked Sendable { var value: T?; init() {} }
    let chA = Box<PeerChannel>(), chB = Box<PeerChannel>()
    hubA.register(service: "input") { chA.value = $0 }
    hubB.register(service: "input") { chB.value = $0 }
    guard waitUntil(3, { chA.value != nil && chB.value != nil }), let a = chA.value, let b = chB.value else {
        check(false, "channels formed"); return
    }
    let clock = FakeClock()
    let sfx = FakeServerEffects(clock: clock)
    let cfx = FakeClientEffects(clock: clock)
    let inj = FakeInjector()
    let serverGeometry = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 2560, height: 1440)])
    var config = ServerCore.Config()
    config.clientSide = .right
    let server = ServerCore(geometry: serverGeometry, config: config, effects: sfx)
    let client = ClientCore(geometry: ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982)]), injector: inj, effects: cfx)
    sfx.forward = { m in let (t, p) = m.encode(); a.send(type: t, payload: p) }
    cfx.forward = { m in let (t, p) = m.encode(); b.send(type: t, payload: p) }
    let qa = DispatchQueue(label: "a"), qb = DispatchQueue(label: "b")
    a.setHandlers(queue: qa, onMessage: { t, p in if let m = try? InputMessage.decode(type: t, payload: p) { server.receive(m) } },
                  onClose: { _ in server.setPeerReady(false) })
    b.setHandlers(queue: qb, onMessage: { t, p in if let m = try? InputMessage.decode(type: t, payload: p) { client.receive(m) } },
                  onClose: { _ in client.peerDisconnected() })
    server.setPeerReady(true)

    _ = server.handle(move(2559, 1439, dx: 8))
    check(waitUntil { client.currentMode == .controlled }, "client controlled after edge push")
    check(inj.position.x == 8 && inj.position.y == 981, "client cursor enters bottom-left (same fraction)")
    for _ in 0..<20 { _ = server.handle(move(1290, 710, dx: 10, dy: -10)) }
    check(waitUntil { inj.position == CGPoint(x: 208, y: 781) }, "20 deltas applied on client -> \(inj.position)")
    _ = server.handle(CapturedEvent(kind: .keyDown(keyCode: 0, autorepeat: false)))
    check(waitUntil { inj.entries.contains("key0 down") }, "key typed on client")
    for _ in 0..<25 { _ = server.handle(move(1270, 720, dx: -10, dy: 0)) }
    check(waitUntil { server.currentMode == .local }, "client edge hands control back to server")
    check(client.currentMode == .idle, "client idle")
    if let r = sfx.restored { check(r.x == 2551, "server cursor restored just inside its right edge -> \(r)") } else { check(false, "restored") }
    check(inj.entries.contains("key0 up"), "key held during hand-back released on client")

    // Unplug while remote: both sides recover.
    _ = server.switchToRemote()
    check(waitUntil { client.currentMode == .controlled }, "manual switch reaches client")
    _ = server.handle(CapturedEvent(kind: .keyDown(keyCode: 9, autorepeat: false)))
    check(waitUntil { inj.entries.contains("key9 down") }, "key 9 down on client")
    hubA.setLinked(false)
    check(waitUntil { server.currentMode == .offline && client.currentMode == .idle }, "unplug: server back to local cursor, client idle")
    check(inj.entries.contains("key9 up"), "unplug: client released held key")
    check(!sfx.capture, "unplug: keyboard capture off")
}


// MARK: - Review regressions: codec & geometry hardening

func checkHardening() {
    print("Codec / geometry hardening")
    func payload(_ m: InputMessage, patchF64At offset: Int, _ value: Double) -> (UInt16, Data) {
        var (t, p) = m.encode()
        withUnsafeBytes(of: value.bitPattern.littleEndian) { p.replaceSubrange(offset..<(offset + 8), with: $0) }
        return (t, p)
    }
    let (t1, p1) = payload(.enter(edge: .left, fraction: 0.5, center: false, flags: 0), patchF64At: 1, .nan)
    check((try? InputMessage.decode(type: t1, payload: p1)) == nil, "enter with NaN fraction rejected")
    let (t2, p2) = payload(.leave(fraction: 0.5), patchF64At: 0, .infinity)
    check((try? InputMessage.decode(type: t2, payload: p2)) == nil, "leave with infinite fraction rejected")
    let (t3, p3) = payload(.mouseMove(dx: 1, dy: 2), patchF64At: 8, -.nan)
    check((try? InputMessage.decode(type: t3, payload: p3)) == nil, "mouseMove with NaN delta rejected")

    // Used to crash on a force unwrap (NaN compared false against every display).
    let g = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: -300, width: 1920, height: 1080)])
    for side in ScreenSide.allCases {
        let p = g.entryPoint(on: side, fraction: .nan)
        check(g.display(containing: p) != nil, "entryPoint(\(side), NaN) lands on a display -> \(p)")
    }
    // Mirrored displays report identical bounds; the old sort comparator was not a strict weak ordering.
    let mirrored = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                             CGRect(x: -1512, y: 100, width: 1512, height: 982)])
    check(mirrored.displays.count == 2 && mirrored.mainDisplay.origin == .zero, "mirrored duplicates collapsed, main first")

    // Modifier sides.
    let lShift: UInt64 = 0x2, rShift: UInt64 = 0x4
    check(ModifierKeys.isDown(keyCode: 56, flags: shift | rShift) == false, "left ⇧ released while right ⇧ held")
    check(ModifierKeys.isDown(keyCode: 60, flags: shift | rShift) == true, "right ⇧ still held")
    check(ModifierKeys.isDown(keyCode: 56, flags: shift) == true, "no device bits: fall back to ⇧ mask")
    check(ModifierKeys.isDown(keyCode: 0, flags: shift | lShift) == nil, "non-modifier -> nil")
    check(ModifierKeys.heldModifierKeys(flags: cmd | 0x8) == [55], "held keys from device bits (left ⌘)")
    check(ModifierKeys.heldModifierKeys(flags: cmd) == [55, 54], "held keys without device bits (both ⌘)")
}

// MARK: - Review regressions: server

func checkServerSafety() {
    print("Server safety (stuck keys / cursor / routing)")
    let clock = FakeClock()
    let geometry = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 2560, height: 1440)])
    var config = ServerCore.Config()
    config.clientSide = .right
    config.switchHotKey = (49, ctrl | opt | cmd)

    // Readiness lost while remote with the channel still open (role change, permission, version):
    // the client must be told to release, or it stays "controlled" with keys held.
    do {
        let fx = FakeServerEffects(clock: clock)
        let core = ServerCore(geometry: geometry, config: config, effects: fx)
        core.setPeerReady(true)
        _ = core.switchToRemote()
        fx.clear()
        core.setPeerReady(false, reason: "角色已更改")
        check(fx.sentSnapshot.contains(.releaseAll), "readiness lost while remote -> releaseAll sent")
        check(core.currentMode == .offline && fx.restored != nil && !fx.capture, "…and cursor / keyboard restored")
    }

    // Auto-repeat of a key that went down locally (e.g. the hotkey's Space) must not type on the client.
    do {
        let fx = FakeServerEffects(clock: clock)
        let core = ServerCore(geometry: geometry, config: config, effects: fx)
        core.setPeerReady(true)
        _ = core.switchToRemote(flags: ctrl | opt | cmd)
        fx.clear()
        check(!core.handle(CapturedEvent(kind: .keyDown(keyCode: 49, autorepeat: true), flags: ctrl | opt)), "local key's auto-repeat swallowed")
        check(!fx.sentSnapshot.contains(where: { if case .key(49, _, _, _) = $0 { return true }; return false }), "…and not forwarded")
        check(core.handle(CapturedEvent(kind: .keyUp(keyCode: 49))), "…its key-up still goes to this Mac")
        _ = core.handle(CapturedEvent(kind: .keyDown(keyCode: 0, autorepeat: false)))
        _ = core.handle(CapturedEvent(kind: .keyDown(keyCode: 0, autorepeat: true)))
        check(fx.sentSnapshot.contains(.key(keyCode: 0, down: true, autorepeat: true, flags: 0)), "forwarded key's auto-repeat still forwarded")
        // Entry modifiers (⌃⌥⌘ of the hotkey): the releases go to this Mac AND clear the client's flags.
        fx.clear()
        check(core.handle(CapturedEvent(kind: .flagsChanged(keyCode: 55), flags: ctrl | opt)), "entry ⌘ release delivered locally")
        check(fx.sentSnapshot.contains(.flagsChanged(keyCode: 55, flags: ctrl | opt)), "…and mirrored to the client")
    }

    // Per-side modifiers: entered with LEFT ⇧ held (device bits), then right ⇧ used on the client.
    do {
        let fx = FakeServerEffects(clock: clock)
        let core = ServerCore(geometry: geometry, config: config, effects: fx)
        core.setPeerReady(true)
        clock.advance(1)
        _ = core.handle(move(2559, 700, dx: 5, flags: shift | 0x2))
        check(core.currentMode == .remote, "entered with left ⇧ held")
        check(!core.handle(CapturedEvent(kind: .flagsChanged(keyCode: 60), flags: shift | 0x2 | 0x4)), "right ⇧ press forwarded")
        check(!core.handle(CapturedEvent(kind: .flagsChanged(keyCode: 60), flags: shift | 0x2)), "right ⇧ release forwarded (went down remotely)")
        check(core.handle(CapturedEvent(kind: .flagsChanged(keyCode: 56), flags: 0)), "left ⇧ release delivered locally (went down here)")
    }

    // A lost mouse-up (tap disabled, …) must not block edge switching forever.
    do {
        let fx = FakeServerEffects(clock: clock)
        let core = ServerCore(geometry: geometry, config: config, effects: fx)
        core.setPeerReady(true)
        clock.advance(1)
        _ = core.handle(CapturedEvent(kind: .mouseDown(button: 0), location: CGPoint(x: 100, y: 100)))
        _ = core.handle(move(2000, 700, dx: 5)) // mouseMoved (not dragged): no button is down any more
        check(!core.handle(move(2559, 700, dx: 5)), "edge switch works after a lost mouse-up")
    }

    // Button held while control moves (blockWhileButtonHeld off): its mouse-up is delivered here at the
    // parked position — that must be where the drag left, not the screen centre (Finder would drop files there).
    do {
        var c = config
        c.blockWhileButtonHeld = false
        let fx = FakeServerEffects(clock: clock)
        let core = ServerCore(geometry: geometry, config: c, effects: fx)
        core.setPeerReady(true)
        clock.advance(1)
        _ = core.handle(CapturedEvent(kind: .mouseDown(button: 0), location: CGPoint(x: 2400, y: 700)))
        check(!core.handle(CapturedEvent(kind: .mouseDragged(button: 0), location: CGPoint(x: 2559, y: 700), dx: 6)), "drag crosses the edge")
        check(fx.parked == CGPoint(x: 2559, y: 700), "cursor parked where the drag left, not at the centre -> \(String(describing: fx.parked))")
        check(core.handle(CapturedEvent(kind: .mouseUp(button: 0), location: CGPoint(x: 2559, y: 700))), "mouse-up of the local drag delivered locally")
    }

    // Spec: when the cursor cannot be hidden, park it at the edge instead of the centre.
    do {
        let fx = FakeServerEffects(clock: clock)
        fx.canHide = false
        let core = ServerCore(geometry: geometry, config: config, effects: fx)
        core.setPeerReady(true)
        clock.advance(1)
        _ = core.handle(move(2559, 300, dx: 5))
        check(fx.parked == CGPoint(x: 2559, y: 300), "no cursor hiding -> parked at the edge")
        core.returnToLocal(reason: "test")
        check(fx.restored == CGPoint(x: 2559, y: 300), "…and restored there")
    }

    // Force-return fallback ⌃⌥⌘← when the switch hotkey was cleared (otherwise no keyboard escape).
    do {
        var c = config
        c.switchHotKey = nil
        let fx = FakeServerEffects(clock: clock)
        let core = ServerCore(geometry: geometry, config: c, effects: fx)
        core.setPeerReady(true)
        _ = core.switchToRemote()
        check(!core.handle(CapturedEvent(kind: .keyDown(keyCode: 123, autorepeat: false), flags: ctrl | opt | cmd | 0x800000)),
              "⌃⌥⌘← swallowed")
        check(core.currentMode == .local, "no hotkey configured: ⌃⌥⌘← returns to local")
        let withHotKey = ServerCore(geometry: geometry, config: config, effects: FakeServerEffects(clock: clock))
        withHotKey.setPeerReady(true)
        _ = withHotKey.switchToRemote()
        _ = withHotKey.handle(CapturedEvent(kind: .keyDown(keyCode: 123, autorepeat: false), flags: ctrl | opt | cmd))
        check(withHotKey.currentMode == .remote, "with a hotkey configured ⌃⌥⌘← is forwarded as usual")
    }

    // Heartbeat loss threshold (spec: > 1.5 s).
    do {
        let fx = FakeServerEffects(clock: clock)
        let core = ServerCore(geometry: geometry, config: config, effects: fx)
        core.setPeerReady(true)
        _ = core.switchToRemote()
        clock.advance(1.4)
        core.tick()
        check(core.currentMode == .remote, "1.4 s without heartbeat: still remote")
        clock.advance(0.2)
        core.tick()
        check(core.currentMode == .local, "1.6 s without heartbeat: back to local")
    }

    // Display removed while remote: the hidden cursor is re-parked on a display that exists.
    do {
        let two = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 2560, height: 1440), CGRect(x: -1920, y: 0, width: 1920, height: 1080)])
        var c = config
        c.clientSide = .left
        let fx = FakeServerEffects(clock: clock)
        fx.canHide = false
        let core = ServerCore(geometry: two, config: c, effects: fx)
        core.setPeerReady(true)
        clock.advance(1)
        _ = core.handle(move(-1920, 500, dx: -5))
        check(core.currentMode == .remote && fx.parked == CGPoint(x: -1920, y: 500), "parked on the left display")
        core.update(geometry: geometry)
        if let p = fx.parked { check(geometry.display(containing: p) != nil, "left display removed -> re-parked on screen -> \(p)") } else { check(false, "re-parked") }
    }
}

// MARK: - Review regressions: client

func checkClientSafety() {
    print("Client safety (stuck keys / hand-back / cursor fidelity)")
    let clock = FakeClock()
    let geometry = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982)])

    // Refused enter (no 辅助功能) must hand control straight back, or the server swallows input forever.
    do {
        let fx = FakeClientEffects(clock: clock)
        let inj = FakeInjector()
        inj.canInject = false
        let core = ClientCore(geometry: geometry, injector: inj, effects: fx)
        core.receive(.enter(edge: .left, fraction: 0.3, center: false, flags: 0))
        check(core.currentMode == .idle && fx.sentSnapshot.contains(.leave(fraction: 0.3)), "refused enter -> leave sent back")
    }

    // A second enter without a releaseAll in between (lost on a flaky link) releases the old stint's keys.
    do {
        let fx = FakeClientEffects(clock: clock)
        let inj = FakeInjector()
        let core = ClientCore(geometry: geometry, injector: inj, effects: fx)
        core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0))
        core.receive(.key(keyCode: 7, down: true, autorepeat: false, flags: 0))
        core.receive(.mouseButton(button: 1, down: true, clickState: 1, flags: 0))
        inj.clear()
        core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0))
        check(inj.entries.contains("key7 up") && inj.entries.contains("button1 up click1"), "re-enter releases keys/buttons of the previous stint")

        // Server takes control back (hotkey / menu / timeout): the client is the side losing control and
        // must offer its clipboard (spec), not only when it hands back through the edge.
        let before = fx.clipboardRequests
        core.receive(.releaseAll)
        check(fx.clipboardRequests == before + 1, "releaseAll while controlled -> clipboard sent")
        core.receive(.releaseAll)
        check(fx.clipboardRequests == before + 1, "releaseAll while idle -> no clipboard")

        // Silence: release AND tell the server, which otherwise keeps swallowing input.
        core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0))
        fx.clear()
        clock.advance(4)
        core.tick()
        check(core.currentMode == .idle && fx.sentSnapshot.contains(where: { if case .leave = $0 { return true }; return false }),
              "silence timeout -> idle + leave sent")

        core.peerDisconnected()
        check(inj.activityReleases == 1, "session end releases the display-wake assertion")
    }

    // Stale cursor reads (window server applies posted moves asynchronously) must not eat deltas.
    do {
        let fx = FakeClientEffects(clock: clock)
        let inj = FakeInjector()
        inj.readLag = 1
        inj.userMovedCursor(to: CGPoint(x: 700, y: 700))
        let core = ClientCore(geometry: geometry, injector: inj, effects: fx)
        core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0))
        check(inj.position == CGPoint(x: 8, y: 491), "entered just inside the left edge")
        for _ in 0..<10 { core.receive(.mouseMove(dx: 10.25, dy: -3)) }
        check(inj.position == CGPoint(x: 110.5, y: 461), "10 deltas with lagging reads all applied (incl. fractions) -> \(inj.position)")
        // This Mac's own trackpad moved the cursor: continue from there.
        inj.userMovedCursor(to: CGPoint(x: 900, y: 100))
        inj.readLag = 0
        core.receive(.mouseMove(dx: 5, dy: 5))
        check(inj.position == CGPoint(x: 905, y: 105), "local trackpad movement respected -> \(inj.position)")
        core.receive(.mouseMove(dx: .nan, dy: 1))
        check(inj.position == CGPoint(x: 905, y: 105), "non-finite delta ignored")
    }

    // Left/right modifiers: releasing left ⇧ while right ⇧ is held is a release, not a press.
    do {
        let fx = FakeClientEffects(clock: clock)
        let inj = FakeInjector()
        let core = ClientCore(geometry: geometry, injector: inj, effects: fx)
        core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0))
        core.receive(.flagsChanged(keyCode: 56, flags: shift | 0x2))
        core.receive(.flagsChanged(keyCode: 60, flags: shift | 0x2 | 0x4))
        core.receive(.flagsChanged(keyCode: 56, flags: shift | 0x4))
        inj.clear()
        core.receive(.releaseAll)
        check(inj.entries.filter { !$0.hasPrefix("cursor") } == ["flags60 0"], "only right ⇧ still held and released -> \(inj.entries)")
    }
}

// MARK: - Cursor hide/show: applied at once on the calling thread, balanced

func checkCursorVisibility() {
    print("Cursor hide/show (immediate, lock-ordered, balanced)")
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(hide: Bool, main: Bool)] = []
        func record(_ hide: Bool) { lock.withLock { calls.append((hide, Thread.isMainThread)) } }
        var applied: [Bool] { lock.withLock { calls.map(\.hide) } }
        var onMain: [Bool] { lock.withLock { calls.map(\.main) } }
    }
    let log = Log()
    let v = CursorVisibility(apply: { log.record($0) })
    // Hide requested on the tap thread: applied right there, not deferred to a (possibly busy) main thread.
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread { v.setHidden(true); done.signal() }
    done.wait()
    check(log.applied == [true] && v.isHidden, "tap-thread hide applied immediately -> \(log.applied)")
    check(log.onMain == [false], "…on the calling thread, not main")
    // Show requested on main right after: applied immediately too (the old main-queue hop made it late).
    v.setHidden(false)
    check(log.applied == [true, false] && !v.isHidden, "main-thread show applied immediately")
    check(!v.setHidden(false) && log.applied.count == 2, "repeated show is a no-op (balanced)")
    // Many threads racing: calls always alternate hide/show and end in the recorded state.
    let group = DispatchGroup()
    for i in 0..<8 {
        group.enter()
        Thread.detachNewThread {
            for j in 0..<200 { v.setHidden((i + j) % 2 == 0) }
            group.leave()
        }
    }
    group.wait()
    let applied = log.applied
    let alternates = zip(applied, applied.dropFirst()).allSatisfy { $0 != $1 }
    check(alternates, "concurrent requests stay balanced (\(applied.count) calls, strictly alternating)")
    check(applied.last == v.isHidden, "final window-server state matches the bookkeeping")
    v.setHidden(false)

    print("Client cursor reveal policy (only real local input)")
    let grace = LocalInputReveal.gracePeriod
    check(!LocalInputReveal.shouldReveal(kind: .move, tagged: true, sinceHide: 5, dx: 4, dy: 0), "our own tagged events never reveal")
    check(!LocalInputReveal.shouldReveal(kind: .move, tagged: false, sinceHide: 0.05, dx: 4, dy: 0), "moves right after hiding (grace period) ignored")
    check(!LocalInputReveal.shouldReveal(kind: .button, tagged: false, sinceHide: grace - 0.01, dx: 0, dy: 0), "clicks within the grace period ignored")
    check(!LocalInputReveal.shouldReveal(kind: .move, tagged: false, sinceHide: 2, dx: 0, dy: 0), "system-generated zero-delta moves ignored")
    check(!LocalInputReveal.shouldReveal(kind: .scroll, tagged: false, sinceHide: 2, dx: 0, dy: 0), "zero-delta scroll ignored")
    check(LocalInputReveal.shouldReveal(kind: .move, tagged: false, sinceHide: grace + 0.01, dx: 0, dy: -2), "real trackpad move after the grace period reveals")
    check(LocalInputReveal.shouldReveal(kind: .button, tagged: false, sinceHide: 1, dx: 0, dy: 0), "real click reveals")
    check(LocalInputReveal.shouldReveal(kind: .scroll, tagged: false, sinceHide: 1, dx: 0, dy: 3), "real scroll reveals")
}

// MARK: - Review regressions: module status

@MainActor
func checkModuleStatus() {
    print("Module status follows settings")
    let suite = MemoryDefaults()
    var initial = InputSettings()
    initial.role = .client // no Carbon hotkey registration from a check
    initial.enabled = true
    suite.set(try? JSONEncoder().encode(initial), forKey: "input.settings")

    // Only one side registers the service, so no channel (and no real injector / tap) is ever created.
    let (hubA, hubB) = LoopbackPeerHub.makePair(nameA: "Studio", nameB: "MBP")
    let module = SharedInputModule(hub: hubA, defaults: suite)
    module.start()
    check(module.model.activity == .waitingForPeer, "enabled, no peer -> waiting")
    check(waitUntil { module.model.linkStatus.contains("MBP") }, "link status shown -> \(module.model.linkStatus)")
    module.store.update { $0.enabled = false }
    check(module.model.activity == .inactive && module.statusLine.contains("已关闭"), "disabled -> inactive (\(module.statusLine))")
    module.store.update { $0.enabled = true }
    check(module.model.activity == .waitingForPeer, "re-enabled -> waiting (\(module.model.activity))")
    module.stop()
    _ = hubB
}

// MARK: - Review regressions: end to end without client permission

@MainActor
func checkEndToEndRefusal() {
    print("End to end: client without 辅助功能")
    let (hubA, hubB) = LoopbackPeerHub.makePair(nameA: "Studio", nameB: "MBP")
    final class Box<T>: @unchecked Sendable { var value: T?; init() {} }
    let chA = Box<PeerChannel>(), chB = Box<PeerChannel>()
    hubA.register(service: "input") { chA.value = $0 }
    hubB.register(service: "input") { chB.value = $0 }
    guard waitUntil(3, { chA.value != nil && chB.value != nil }), let a = chA.value, let b = chB.value else {
        check(false, "channels formed"); return
    }
    let clock = FakeClock()
    let sfx = FakeServerEffects(clock: clock)
    let cfx = FakeClientEffects(clock: clock)
    let inj = FakeInjector()
    inj.canInject = false
    let server = ServerCore(geometry: ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 2560, height: 1440)]), config: ServerCore.Config(), effects: sfx)
    let client = ClientCore(geometry: ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982)]), injector: inj, effects: cfx)
    sfx.forward = { m in let (t, p) = m.encode(); a.send(type: t, payload: p) }
    cfx.forward = { m in let (t, p) = m.encode(); b.send(type: t, payload: p) }
    a.setHandlers(queue: DispatchQueue(label: "ra"), onMessage: { t, p in if let m = try? InputMessage.decode(type: t, payload: p) { server.receive(m) } },
                  onClose: { _ in server.setPeerReady(false) })
    b.setHandlers(queue: DispatchQueue(label: "rb"), onMessage: { t, p in if let m = try? InputMessage.decode(type: t, payload: p) { client.receive(m) } },
                  onClose: { _ in client.peerDisconnected() })
    server.setPeerReady(true)
    _ = server.switchToRemote()
    check(waitUntil { server.currentMode == .local }, "server gets control back at once")
    check(sfx.restored != nil && !sfx.capture, "server cursor and keyboard restored")
    check(inj.entries.isEmpty, "nothing injected on the client")
    a.close()
    _ = (hubA, hubB)
}


// MARK: - Protocol compatibility (hello fields, chunk message)

func checkProtocolCompatibility() {
    print("Protocol compatibility (hello extensions, clipboard pieces)")
    let hello = InputHello(role: .server, deviceName: "Studio", ready: true, clientSide: .right,
                           wheel: WheelConfig(smooth: false, speed: 5, direction: .natural))
    let (t, p) = InputMessage.hello(hello).encode()
    check((try? InputMessage.decode(type: t, payload: p)) == .hello(hello), "hello with wheel + features round-trips")
    check(hello.supports(InputFeature.clipboardChunks) && hello.supports(InputFeature.smoothWheel), "new builds advertise their features")
    // An older peer's hello (no wheel / features keys) still decodes; it supports nothing new.
    let old = Data(#"{"version":1,"role":"client","deviceName":"MBP","ready":true,"clientSide":"right"}"#.utf8)
    if case .hello(let h)? = try? InputMessage.decode(type: 0x0001, payload: old) {
        check(h.wheel == nil && h.features == nil && !h.supports(InputFeature.clipboardChunks), "old hello decodes, no new features")
        check(InputReadiness.evaluate(localRole: .server, tapRunning: true, canInject: true, peer: h).ready, "old peer still pairs (same version)")
    } else { check(false, "old hello decodes") }
    // An older build decodes our hello (it ignores the new keys).
    struct OldHello: Decodable { var version: Int; var role: InputRole; var deviceName: String; var ready: Bool; var clientSide: ScreenSide }
    check((try? JSONDecoder().decode(OldHello.self, from: p))?.deviceName == "Studio", "older builds can still read the new hello")
    // Tolerant wheel config.
    let partial = try? JSONDecoder().decode(WheelConfig.self, from: Data(#"{"smooth":false,"speed":9}"#.utf8))
    check(partial == WheelConfig(smooth: false, speed: 5, direction: .windows), "partial wheel config decodes (speed clamped) -> \(String(describing: partial))")

    let chunk = ClipboardChunk(transferID: 7, index: 2, count: 3, totalBytes: 12345, data: Data([1, 2, 3]))
    let (ct, cp) = InputMessage.clipboardChunk(chunk).encode()
    check((try? InputMessage.decode(type: ct, payload: cp)) == .clipboardChunk(chunk), "clipboard piece round-trips")
    check(PeerLimits.serviceTypeRange.contains(ct), "clipboard piece type in service range")
    let bad = InputMessage.clipboardChunk(ClipboardChunk(transferID: 1, index: 0, count: 1, totalBytes: 1, data: Data([9])))
    var (bt, bp) = bad.encode()
    bp[4] = 5 // index 5 of 1
    check((try? InputMessage.decode(type: bt, payload: bp)) == nil, "piece index beyond its count rejected")
    let legacy = InputMessage.clipboard([ClipboardItem(type: "public.utf8-plain-text", data: Data("hi".utf8))])
    let (lt, lp) = legacy.encode()
    check(lp == ClipboardCodec.encode([ClipboardItem(type: "public.utf8-plain-text", data: Data("hi".utf8))]) && lt == 0x0006,
          "single-message clipboard keeps its wire layout (older peers)")
}

// MARK: - Settings

@MainActor
func checkSettingsMigration() {
    print("Settings: wheel defaults and migration")
    let d = InputSettings()
    check(d.wheelDirection == .windows && d.smoothScrolling && d.scrollSpeed == 3, "defaults: Windows direction, smooth, speed 3")
    check(d.wheelConfig == WheelConfig(smooth: true, speed: 3, direction: .windows), "wheel config for the hello")
    // Settings saved by the previous version (no wheel keys) keep the user's choices and gain the defaults.
    let suite = MemoryDefaults()
    let oldJSON = #"{"enabled":true,"role":"server","clientSide":"left","dwellMilliseconds":250,"requiredModifier":"none","blockWhileButtonHeld":false,"clipboardSync":false}"#
    suite.set(Data(oldJSON.utf8), forKey: "input.settings")
    let store = SettingsStore(key: "input.settings", defaultValue: InputSettings(), defaults: suite)
    let v = store.value
    check(v.clientSide == .left && v.dwellMilliseconds == 250 && !v.blockWhileButtonHeld && !v.clipboardSync,
          "old choices survive -> \(v.clientSide) \(v.dwellMilliseconds)")
    check(v.wheelDirection == .windows && v.smoothScrolling && v.scrollSpeed == 3, "new wheel settings get their defaults")
    check(WheelDirection.windows.title.contains("上滚看上面") && WheelDirection.natural.title.contains("自然滚动"), "direction titles in Chinese")
}

// MARK: - Mouse wheel: direction (server) and distance

func checkWheelMath() {
    print("Wheel direction and distance")
    // CG: positive = wheel rolled away from the user. Natural scrolling on -> macOS inverted it.
    check(WheelMath.directionFactor(invertedFromDevice: true, style: .windows) == -1, "natural on + Windows style -> flip")
    check(WheelMath.directionFactor(invertedFromDevice: false, style: .windows) == 1, "natural off + Windows style -> keep")
    check(WheelMath.directionFactor(invertedFromDevice: true, style: .natural) == 1, "natural on + natural style -> keep")
    check(WheelMath.directionFactor(invertedFromDevice: false, style: .natural) == -1, "natural off + natural style -> flip")
    var s = ScrollData()
    s.delta1 = -1; s.point1 = -10; s.fixed1 = -0.93; s.delta2 = 2; s.point2 = 20; s.fixed2 = 2.1
    let w = WheelMath.applyDirection(s, invertedFromDevice: true, style: .windows)
    check(w.delta1 == 1 && w.point1 == 10 && w.fixed1 == 0.93 && w.delta2 == -2 && w.point2 == -20 && w.fixed2 == -2.1,
          "all fields of both axes flipped")
    check(WheelMath.applyDirection(s, invertedFromDevice: false, style: .windows) == s, "unchanged when no flip is needed")

    var one = ScrollData()
    one.delta1 = 1; one.point1 = 10; one.fixed1 = 0.93
    check(abs(WheelMath.pixels(for: one, speed: 3).dy - 27) < 0.001, "speed 3 = Mos default (×2.7): 10 pt -> 27 px")
    check(WheelMath.pixels(for: one, speed: 1).dy < WheelMath.pixels(for: one, speed: 5).dy, "speed 1 < speed 5")
    check(WheelMath.pixels(for: one, speed: 99).dy == WheelMath.pixels(for: one, speed: 5).dy, "speed clamped to 1…5")
    var lineOnly = ScrollData()
    lineOnly.delta1 = -2
    check(abs(WheelMath.pixels(for: lineOnly, speed: 3).dy + 54) < 0.001, "line-only event: 10 px per line")
    var fixedOnly = ScrollData()
    fixedOnly.fixed1 = 0.1
    check(WheelMath.pixels(for: fixedOnly, speed: 3).dy == 2.7, "tiny fixed-point delta -> at least 1 px × speed")
    check(WheelMath.pixels(for: ScrollData(), speed: 3) == (0, 0), "empty event -> no distance")
    var huge = ScrollData()
    huge.point1 = 1_000_000
    check(WheelMath.pixels(for: huge, speed: 1).dy <= WheelMath.maxPixelsPerEvent * 1.4 + 0.001, "absurd deltas capped")
}

func checkServerWheelForwarding() {
    print("Server: wheel direction applied, trackpad forwarded unchanged")
    let clock = FakeClock()
    let fx = FakeServerEffects(clock: clock)
    var config = ServerCore.Config()
    config.wheelDirection = .windows
    let core = ServerCore(geometry: ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 2560, height: 1440)]), config: config, effects: fx)
    core.setPeerReady(true)
    _ = core.switchToRemote()
    fx.clear()
    var wheelUp = ScrollData()      // natural scrolling on: wheel rolled up arrives negative
    wheelUp.delta1 = -1; wheelUp.point1 = -9; wheelUp.fixed1 = -0.86
    check(!core.handle(CapturedEvent(kind: .scroll(wheelUp), scrollInverted: true)), "wheel event swallowed")
    if case .scroll(let out, _)? = fx.sentSnapshot.last {
        check(out.delta1 == 1 && out.point1 == 9, "Windows style: wheel up forwarded as 'show content above' (+) -> \(out.point1)")
    } else { check(false, "scroll forwarded") }
    config.wheelDirection = .natural
    core.update(config: config)
    _ = core.handle(CapturedEvent(kind: .scroll(wheelUp), scrollInverted: true))
    if case .scroll(let out, _)? = fx.sentSnapshot.last {
        check(out.point1 == -9, "natural style: same event keeps the macOS natural direction")
    } else { check(false, "scroll forwarded (natural)") }
    var pad = ScrollData()
    pad.isContinuous = 1; pad.point1 = -14; pad.scrollPhase = 2
    _ = core.handle(CapturedEvent(kind: .scroll(pad), scrollInverted: true))
    check(fx.sentSnapshot.last == .scroll(pad, flags: 0), "trackpad (continuous) scroll forwarded unchanged")
}

// MARK: - Mouse wheel: smooth gesture synthesis (client)

func sum(_ frames: [WheelFrame]) -> (dy: Int, dx: Int) {
    frames.reduce((0, 0)) { ($0.0 + Int($1.dy), $0.1 + Int($1.dx)) }
}

func checkSmoothWheel() {
    print("Smooth wheel animator")
    var w = SmoothWheel()
    var frames: [WheelFrame] = []
    w.add(dy: 90, dx: 0, at: 0)
    var t = 0.0
    var endedAt: Double?
    while t < 1 {
        t += 1.0 / 120
        let f = w.frames(at: t)
        frames += f
        if endedAt == nil, f.contains(where: { $0.phase == .ended }) { endedAt = t }
    }
    check(frames.first?.phase == .began && frames.last?.phase == .ended, "one gesture: began … ended -> \(frames.first!) … \(frames.last!)")
    check(frames.dropFirst().dropLast().allSatisfy { $0.phase == .changed }, "changed in between")
    check(frames.filter { $0.phase == .began }.count == 1 && frames.filter { $0.phase == .ended }.count == 1, "exactly one began / ended")
    check(sum(frames).dy == 90, "pixels add up to the tick's distance -> \(sum(frames).dy)")
    check((endedAt ?? 9) <= SmoothWheel.defaultDuration + 1.0 / 120 + 1e-9, "done within the ease-out duration -> \(endedAt ?? -1)")
    let firstHalf = frames.prefix(frames.count / 2).reduce(0) { $0 + Int($1.dy) }
    check(firstHalf > 60, "ease-out: most distance early (\(firstHalf) of 90 px in the first half of the frames)")
    check(!w.isAnimating && !w.gestureOpen && w.frames(at: 2).isEmpty, "idle afterwards")

    // Additive: a second tick while animating adds to what is left.
    w = SmoothWheel()
    frames = []
    w.add(dy: -50, dx: 0, at: 0)
    for i in 1...6 { frames += w.frames(at: Double(i) / 120) }
    w.add(dy: -50, dx: 0, at: 6.0 / 120)
    for i in 7...80 { frames += w.frames(at: Double(i) / 120) }
    check(sum(frames).dy == -100 && frames.filter { $0.phase == .began }.count == 1, "two ticks in one gesture add up -> \(sum(frames).dy)")

    // Direction reversal drops what was left (like Mos) and heads the other way.
    w = SmoothWheel()
    frames = []
    w.add(dy: 100, dx: 0, at: 0)
    for i in 1...3 { frames += w.frames(at: Double(i) / 120) }
    let before = sum(frames).dy
    w.add(dy: -40, dx: 0, at: 3.0 / 120)
    var after: [WheelFrame] = []
    for i in 4...80 { after += w.frames(at: Double(i) / 120) }
    check(abs(sum(after).dy + 40) <= 1, "reversal: new direction only (\(sum(after).dy) px after \(before) px)")

    // Horizontal and finish().
    w = SmoothWheel()
    w.add(dy: 0, dx: 30, at: 0)
    let f1 = w.frames(at: 0.02)
    check(f1.first?.phase == .began && (f1.first?.dx ?? 0) > 0 && f1.first?.dy == 0, "horizontal wheel")
    check(w.finish() == WheelFrame(dy: 0, dx: 0, phase: .ended) && w.finish() == nil, "finish closes an open gesture once")
    var quiet = SmoothWheel()
    quiet.add(dy: 0.2, dx: 0, at: 0)
    check(quiet.frames(at: 1).isEmpty && quiet.finish() == nil, "sub-pixel tick: nothing posted, nothing to close")
    var instant = SmoothWheel()
    check(instant.immediate(dy: 27, dx: 0) == [WheelFrame(dy: 27, dx: 0, phase: .began), WheelFrame(dy: 0, dx: 0, phase: .ended)],
          "immediate mode: began(distance) + ended")
}

func checkClientWheel() {
    print("Client: wheel ticks replayed as trackpad-like gestures (Mos passes them through)")
    let clock = FakeClock()
    let fx = FakeClientEffects(clock: clock)
    let inj = FakeInjector()
    let timer = FakeFrameTimer()
    let core = ClientCore(geometry: ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982)]),
                          injector: inj, effects: fx, frameTimer: timer)
    func runFrames(_ n: Int) { for _ in 0..<n { clock.advance(1.0 / 120); timer.fire() } }
    var tick = ScrollData()
    tick.delta1 = 1; tick.point1 = 10; tick.fixed1 = 0.93

    core.receive(.scroll(tick, flags: 0))
    check(inj.wheelFrames.isEmpty && !timer.running, "ignored while idle")
    core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0))
    inj.clear()
    core.receive(.scroll(tick, flags: cmd))
    check(timer.running, "a wheel tick starts the frame timer")
    runFrames(60)
    let frames = inj.wheelFrames
    check(!frames.isEmpty && frames.allSatisfy { $0.phase.rawValue != 0 }, "every posted event carries a scroll phase (Mos treats it as a trackpad)")
    check(!inj.entries.contains { $0.hasPrefix("scroll ") }, "no plain (non-continuous) wheel event posted")
    check(frames.first?.phase == .began && frames.last?.phase == .ended, "began … ended")
    check(sum(frames).dy == 27, "distance = 10 pt × 2.7 (speed 3) -> \(sum(frames).dy)")
    check(!timer.running, "timer stops when the gesture ends")

    // Speed from the server's hello.
    core.update(wheel: WheelConfig(smooth: true, speed: 5, direction: .windows))
    inj.clearFrames()
    core.receive(.scroll(tick, flags: 0))
    runFrames(60)
    check(sum(inj.wheelFrames).dy == 48, "speed 5 -> 48 px -> \(sum(inj.wheelFrames).dy)")

    // Smooth scrolling off: one immediate gesture per tick, no timer.
    core.update(wheel: WheelConfig(smooth: false, speed: 3, direction: .windows))
    inj.clearFrames()
    core.receive(.scroll(tick, flags: 0))
    check(inj.wheelFrames == [WheelFrame(dy: 27, dx: 0, phase: .began), WheelFrame(dy: 0, dx: 0, phase: .ended)] && !timer.running,
          "smooth off: began(27) + ended at once -> \(inj.wheelFrames)")

    // A click stops the animation (the gesture is closed, nothing more is posted).
    core.update(wheel: WheelConfig())
    inj.clearFrames()
    core.receive(.scroll(tick, flags: 0))
    runFrames(3)
    core.receive(.mouseButton(button: 0, down: true, clickState: 1, flags: 0))
    check(inj.wheelFrames.last?.phase == .ended && !timer.running, "click ends the running gesture")
    let n = inj.wheelFrames.count
    runFrames(10)
    check(inj.wheelFrames.count == n, "…and nothing is posted afterwards")
    core.receive(.mouseButton(button: 0, down: false, clickState: 1, flags: 0))

    // A trackpad scroll takes over: the wheel gesture is closed first, the trackpad event posted as is.
    inj.clearFrames()
    inj.clear()
    core.receive(.scroll(tick, flags: 0))
    runFrames(2)
    var pad = ScrollData()
    pad.isContinuous = 1; pad.point1 = 5; pad.scrollPhase = 1
    core.receive(.scroll(pad, flags: 0))
    let e = inj.entries
    if let endIdx = e.firstIndex(where: { $0.hasPrefix("wheel ended") }), let padIdx = e.firstIndex(of: "scroll 5") {
        check(endIdx < padIdx, "wheel gesture ended before the trackpad scroll")
    } else { check(false, "wheel ended + trackpad scroll posted -> \(e)") }

    // Control leaves mid-gesture: the gesture is closed (no app stuck in a scroll gesture).
    inj.clearFrames()
    core.receive(.scroll(tick, flags: 0))
    runFrames(2)
    core.receive(.releaseAll)
    check(inj.wheelFrames.last?.phase == .ended && !timer.running, "releaseAll closes the gesture")
    runFrames(5)
    check(inj.wheelFrames.last?.phase == .ended, "no frames after control left")
}

// MARK: - Clipboard: pieces, reassembly, pacing, both directions

func checkClipboardTransfer() {
    print("Clipboard pieces and reassembly")
    var rng = SystemRandomNumberGenerator()
    let image = Data((0..<(5 * 1024 * 1024 + 123)).map { _ in UInt8.random(in: 0...255, using: &rng) })
    let items = [ClipboardItem(type: "public.utf8-plain-text", data: Data("截图".utf8)), ClipboardItem(type: "public.png", data: image)]
    let payload = ClipboardCodec.encode(items)
    let chunks = ClipboardChunker.chunks(for: payload, transferID: 1)
    check(chunks.count == 6 && chunks.allSatisfy { $0.data.count <= ClipboardLimits.chunkBytes }, "5 MB image -> 6 pieces of ≤ 1 MB")
    check(chunks.allSatisfy { $0.data.count <= 4 * 1024 * 1024 }, "every piece ≤ 4 MiB")
    var a = ClipboardAssembler()
    var outcome = ClipboardAssembler.Outcome.pending
    for c in chunks.reversed() { outcome = a.add(c, at: 0) } // out of order
    check(outcome == .complete(items), "out-of-order pieces reassemble to the same items")
    // Duplicates are ignored.
    a = ClipboardAssembler()
    _ = a.add(chunks[0], at: 0)
    _ = a.add(chunks[0], at: 0)
    for c in chunks.dropFirst() { outcome = a.add(c, at: 0) }
    check(outcome == .complete(items), "duplicate piece ignored")
    // A newer transfer replaces an unfinished one.
    a = ClipboardAssembler()
    _ = a.add(chunks[0], at: 0)
    let small = ClipboardChunker.chunks(for: ClipboardCodec.encode([items[0]]), transferID: 2)
    check(a.add(small[0], at: 1) == .complete([items[0]]) && a.notes.contains { $0.contains("superseded") }, "newer clipboard supersedes an unfinished transfer")
    check(!a.isReceiving, "nothing left over")
    // Stalled transfers are dropped after the timeout.
    a = ClipboardAssembler()
    _ = a.add(chunks[0], at: 0)
    check(a.expire(at: ClipboardLimits.transferTimeout - 1) == nil && a.isReceiving, "still waiting before the timeout")
    check(a.expire(at: ClipboardLimits.transferTimeout + 1) != nil && !a.isReceiving, "stalled transfer dropped after the timeout")
    check(a.add(chunks[1], at: 20) == .pending && !a.isReceiving && a.expire(at: 100) == nil,
          "late piece of the dropped transfer is ignored (no partial transfer that could only time out)")
    // Limits.
    a = ClipboardAssembler()
    let tooBig = ClipboardChunk(transferID: 3, index: 0, count: 200, totalBytes: UInt64(ClipboardLimits.maxTotalBytes) + 1, data: Data([0]))
    if case .dropped = a.add(tooBig, at: 0) { check(true, "over 100 MB rejected") } else { check(false, "over 100 MB rejected") }
    a = ClipboardAssembler()
    _ = a.add(ClipboardChunk(transferID: 4, index: 0, count: 2, totalBytes: 10, data: Data(count: 5)), at: 0)
    if case .dropped = a.add(ClipboardChunk(transferID: 4, index: 1, count: 3, totalBytes: 10, data: Data(count: 5)), at: 0) {
        check(true, "inconsistent piece count rejected")
    } else { check(false, "inconsistent piece count rejected") }
    a = ClipboardAssembler()
    _ = a.add(ClipboardChunk(transferID: 5, index: 0, count: 2, totalBytes: 4, data: Data(count: 3)), at: 0)
    if case .dropped = a.add(ClipboardChunk(transferID: 5, index: 1, count: 2, totalBytes: 4, data: Data(count: 3)), at: 0) {
        check(true, "pieces larger than announced rejected")
    } else { check(false, "pieces larger than announced rejected") }
    check(ClipboardChunker.chunks(for: Data(), transferID: 9).count == 1, "empty payload is one (empty) piece")

    print("Clipboard sending is paced (input interleaves) and a newer clipboard cancels")
    final class Wire: @unchecked Sendable {
        let lock = NSLock()
        var sent: [(UInt16, Data)] = []
        var pending: [(@Sendable (Error?) -> Void)] = []
        func send(_ t: UInt16, _ p: Data, _ c: (@Sendable (Error?) -> Void)?) {
            lock.withLock { sent.append((t, p)); if let c { pending.append(c) } }
        }
        func completeNext() { let c: (@Sendable (Error?) -> Void)? = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }; c?(nil) }
        var count: Int { lock.withLock { sent.count } }
    }
    let wire = Wire()
    let sender = ClipboardSender(chunkBytes: 1024 * 1024) { wire.send($0, $1, $2) }
    let summary = sender.send(items, chunked: true)
    check(wire.count == 1, "only the first piece is queued until it was handed to the network -> \(summary)")
    wire.completeNext()
    check(wire.count == 2, "next piece after the completion")
    let newer = [ClipboardItem(type: "public.utf8-plain-text", data: Data("new".utf8))]
    sender.send(newer, chunked: true)
    check(wire.count == 3, "newer clipboard starts at once")
    wire.completeNext() // completion of the old transfer's piece 2: must not continue the old transfer
    wire.completeNext()
    let types = wire.lock.withLock { wire.sent.map(\.0) }
    check(wire.count == 3 && types.allSatisfy { $0 == 0x0007 }, "old transfer cancelled by the newer clipboard")
    let legacyWire = Wire()
    let legacySender = ClipboardSender { legacyWire.send($0, $1, $2) }
    legacySender.send(newer, chunked: false)
    check(legacyWire.count == 1 && legacyWire.sent[0].0 == 0x0006, "older peer: one .clipboard message")
    let hugeItems = [ClipboardItem(type: "public.png", data: Data(count: PeerLimits.maxPayloadSize))]
    check(legacySender.send(hugeItems, chunked: false).contains("not sent") && legacyWire.count == 1, "older peer: over 16 MB not sent (logged)")
}

@MainActor
func checkClipboardBothDirections() {
    print("Clipboard both directions over LoopbackPeerHub (Studio → MBP and MBP → Studio)")
    let (hubA, hubB) = LoopbackPeerHub.makePair(nameA: "Studio", nameB: "MBP")
    final class Box<T>: @unchecked Sendable { var value: T?; init() {} }
    let chA = Box<PeerChannel>(), chB = Box<PeerChannel>()
    hubA.register(service: "input") { chA.value = $0 }
    hubB.register(service: "input") { chB.value = $0 }
    guard waitUntil(3, { chA.value != nil && chB.value != nil }), let a = chA.value, let b = chB.value else {
        check(false, "channels formed"); return
    }
    let clock = FakeClock()
    let sfx = FakeServerEffects(clock: clock)
    let cfx = FakeClientEffects(clock: clock)
    let inj = FakeInjector()
    let server = ServerCore(geometry: ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 2560, height: 1440)]), config: ServerCore.Config(), effects: sfx)
    let client = ClientCore(geometry: ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982)]), injector: inj, effects: cfx,
                            frameTimer: FakeFrameTimer())
    sfx.forward = { m in let (t, p) = m.encode(); a.send(type: t, payload: p) }
    cfx.forward = { m in let (t, p) = m.encode(); b.send(type: t, payload: p) }
    let inboxA = ClipboardInbox(), inboxB = ClipboardInbox()
    a.setHandlers(queue: DispatchQueue(label: "ca"), onMessage: { t, p in
        InputSession.route(type: t, payload: p, inbox: inboxA, hello: { _ in }, deliver: { server.receive($0) })
    }, onClose: { _ in })
    b.setHandlers(queue: DispatchQueue(label: "cb"), onMessage: { t, p in
        InputSession.route(type: t, payload: p, inbox: inboxB, hello: { _ in }, deliver: { client.receive($0) })
    }, onClose: { _ in })
    server.setPeerReady(true)

    var rng = SystemRandomNumberGenerator()
    let png = Data((0..<(3 * 1024 * 1024 + 7)).map { _ in UInt8.random(in: 0...255, using: &rng) })
    let studioClip = [ClipboardItem(type: "public.utf8-plain-text", data: Data("来自 Studio".utf8)), ClipboardItem(type: "public.png", data: png)]
    let studioSender = ClipboardSender { t, p, c in a.send(type: t, payload: p, completion: c) }
    studioSender.send(studioClip, chunked: true)
    check(waitUntil { cfx.applied.count == 1 }, "Studio → MBP: large image arrives in pieces")
    check(cfx.applied.first == studioClip, "…intact")

    let mbpClip = [ClipboardItem(type: "public.rtf", data: Data("{\\rtf1 hi}".utf8)), ClipboardItem(type: "public.png", data: png.prefix(100_000))]
    let mbpSender = ClipboardSender { t, p, c in b.send(type: t, payload: p, completion: c) }
    mbpSender.send(mbpClip, chunked: true)
    check(waitUntil { sfx.applied.count == 1 }, "MBP → Studio: the server now applies the client's clipboard")
    check(sfx.applied.first == mbpClip, "…intact")
    mbpSender.send([ClipboardItem(type: "public.utf8-plain-text", data: Data("legacy".utf8))], chunked: false)
    check(waitUntil { sfx.applied.count == 2 }, "MBP → Studio: single-message clipboard (older peer format) applied too")
    a.close()
    _ = (hubA, hubB)
}

@MainActor
func checkClipboardPasteboard() {
    print("Clipboard on a private pasteboard (PNG preferred, other image type on demand)")
    // A private, named pasteboard (never the user's general pasteboard); released at the end.
    let pb = NSPasteboard(name: NSPasteboard.Name("com.oneswitch.check.\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let pngData = rep.representation(using: .png, properties: [:]), let tiffData = rep.tiffRepresentation else {
        check(false, "test image"); return
    }
    let sync = ClipboardSync(pasteboard: pb)
    sync.apply([ClipboardItem(type: NSPasteboard.PasteboardType.png.rawValue, data: pngData),
                ClipboardItem(type: "com.evil.type", data: Data([1]))])
    let types = pb.types ?? []
    check(types.contains(.png) && types.contains(.tiff), "PNG written, TIFF offered for apps that only read TIFF -> \(types.map(\.rawValue))")
    check(!types.contains(NSPasteboard.PasteboardType("com.evil.type")), "unknown types from the wire are not written")
    check(pb.data(forType: .png) == pngData, "PNG bytes intact")
    if let tiff = pb.data(forType: .tiff), let back = NSBitmapImageRep(data: tiff) {
        check(back.pixelsWide == 4 && back.pixelsHigh == 3, "TIFF converted on demand (4×3)")
    } else { check(false, "TIFF converted on demand") }
    check(sync.snapshotIfChanged() == nil, "a clipboard we wrote is not echoed back")

    pb.clearContents()
    pb.setData(Data("文字".utf8), forType: .string)
    pb.setData(tiffData, forType: .tiff)
    pb.setData(pngData, forType: .png)
    let snap = sync.snapshotIfChanged() ?? []
    check(snap.map(\.type) == [NSPasteboard.PasteboardType.string.rawValue, NSPasteboard.PasteboardType.png.rawValue],
          "snapshot: text + PNG, TIFF skipped when PNG exists -> \(snap.map(\.type))")
    check(sync.snapshotIfChanged() == nil, "unchanged pasteboard not sent again")
    pb.clearContents()
    pb.setData(tiffData, forType: .tiff)
    check(sync.snapshotIfChanged()?.map(\.type) == [NSPasteboard.PasteboardType.tiff.rawValue], "TIFF sent when there is no PNG")
    check(ImageTypeConverter.convert(tiffData, to: .png).flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide == 4, "TIFF → PNG conversion")
    let tiny = ClipboardSync(pasteboard: pb, maxTotalBytes: 1024)
    pb.clearContents()
    pb.setData(Data(count: 4096), forType: .png)
    pb.setData(Data("ok".utf8), forType: .string)
    check(tiny.snapshotIfChanged()?.map(\.type) == [NSPasteboard.PasteboardType.string.rawValue], "items over the size limit are skipped")
}

// MARK: - Switching path order (return to the server must feel instant)

func checkSwitchOrder() {
    print("Switch order: cursor first on the server, leave first on the client")
    let clock = FakeClock()
    let fx = FakeServerEffects(clock: clock)
    let core = ServerCore(geometry: ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 2560, height: 1440)]), config: ServerCore.Config(), effects: fx)
    core.setPeerReady(true)
    _ = core.switchToRemote()
    fx.clearCalls()
    core.receive(.leave(fraction: 0.5))
    check(fx.callLog.first == "restore", "leave: cursor restored before anything else -> \(fx.callLog)")
    _ = core.switchToRemote()
    fx.clearCalls()
    core.returnToLocal(reason: "test")
    check(fx.callLog == ["restore", "capture off", "send releaseAll"], "hotkey return: restore, keyboard tap off, releaseAll -> \(fx.callLog)")

    let cfx = FakeClientEffects(clock: clock)
    let inj = FakeInjector()
    let client = ClientCore(geometry: ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982)]), injector: inj, effects: cfx,
                            frameTimer: FakeFrameTimer())
    final class Seen: @unchecked Sendable { var entriesAtLeave: [String]?; }
    let seen = Seen()
    cfx.forward = { m in if case .leave = m { seen.entriesAtLeave = inj.entries } }
    client.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0))
    client.receive(.key(keyCode: 3, down: true, autorepeat: false, flags: 0))
    inj.clear()
    client.receive(.mouseMove(dx: -50, dy: 0))
    check(seen.entriesAtLeave == [], "leave sent before releasing keys / hiding the cursor -> \(seen.entriesAtLeave ?? ["(no leave)"])")
    check(inj.entries.contains("key3 up") && inj.entries.contains("cursor hidden"), "…which still happen right after")
}

// MARK: - Adversarial verification (round 3)

/// Deterministic RNG for the fuzz checks (SplitMix64).
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Phase grammar of a synthesized wheel stream: (began changed* ended)*, no empty began / changed, ended
/// carries no distance.
func wheelGrammar(_ frames: [WheelFrame], allowOpenEnd: Bool = false) -> String? {
    var open = false
    for (i, f) in frames.enumerated() {
        switch f.phase {
        case .began:
            if open { return "began inside an open gesture at #\(i)" }
            if f.dy == 0 && f.dx == 0 { return "empty began at #\(i)" }
            open = true
        case .changed:
            if !open { return "changed outside a gesture at #\(i)" }
            if f.dy == 0 && f.dx == 0 { return "empty changed at #\(i)" }
        case .ended:
            if !open { return "ended outside a gesture at #\(i)" }
            if f.dy != 0 || f.dx != 0 { return "ended with a distance at #\(i)" }
            open = false
        }
    }
    return open && !allowOpenEnd ? "gesture left open" : nil
}

func checkWheelFuzz() {
    print("Wheel animator fuzz (bursts, reversals, hi-res ticks, both axes, finish / immediate)")
    var rng = SplitMix(seed: 0x5EED)
    // A: one direction, no interruptions: every gesture posts exactly its ticks (± rounding per gesture).
    do {
        var w = SmoothWheel()
        var frames: [WheelFrame] = []
        var t = 0.0, nextFrame = 1.0 / 120, ticked = 0.0
        for _ in 0..<600 {
            let hiRes = Bool.random(using: &rng)
            let d = hiRes ? 2.7 : Double(Int.random(in: 1...120, using: &rng))
            t += Bool.random(using: &rng) ? 0.008 : Double.random(in: 0...0.5, using: &rng)
            while nextFrame <= t { frames += w.frames(at: nextFrame); nextFrame += 1.0 / 120 }
            w.add(dy: d, dx: 0, at: t)
            ticked += d
        }
        while w.isAnimating { frames += w.frames(at: nextFrame); nextFrame += 1.0 / 120 }
        let gestures = frames.filter { $0.phase == .began }.count
        let err = wheelGrammar(frames)
        check(err == nil, "same-direction fuzz: phase grammar holds over \(frames.count) frames / \(gestures) gestures\(err.map { " — \($0)" } ?? "")")
        check(abs(Double(sum(frames).dy) - ticked) <= 0.5 * Double(gestures) + 1e-6,
              "…and posts the ticked distance (\(sum(frames).dy) px of \(String(format: "%.1f", ticked)))")
        check(frames.allSatisfy { $0.dx == 0 }, "…vertical only")
    }
    // B: both axes, both directions, bursts at one instant, finish() and immediate() at random.
    do {
        var w = SmoothWheel()
        var frames: [WheelFrame] = []
        var t = 0.0
        var framesAfterFinish = 0
        for _ in 0..<3000 {
            switch Int.random(in: 0..<20, using: &rng) {
            case 0:
                if let e = w.finish() { frames.append(e) }
                let more = w.frames(at: t + 0.01)
                framesAfterFinish += more.count
                frames += more
            case 1:
                frames += w.immediate(dy: Double.random(in: -300...300, using: &rng), dx: Double.random(in: -50...50, using: &rng))
            case 2:
                for _ in 0..<50 { w.add(dy: 400, dx: -400, at: t) } // burst at one instant (capped)
            default:
                let axisX = Int.random(in: 0..<4, using: &rng) == 0
                let v = Double.random(in: -150...150, using: &rng)
                w.add(dy: axisX ? 0 : v, dx: axisX ? v : 0, at: t)
            }
            for _ in 0..<Int.random(in: 0...40, using: &rng) {
                t += 1.0 / 120
                frames += w.frames(at: t)
            }
        }
        if let e = w.finish() { frames.append(e) }
        let err = wheelGrammar(frames)
        check(err == nil, "mixed fuzz (reversals, bursts, finish, immediate): phase grammar holds over \(frames.count) frames\(err.map { " — \($0)" } ?? "")")
        check(framesAfterFinish == 0, "nothing is posted after finish() until the next tick")
        check(frames.allSatisfy { abs(Int($0.dy)) <= 20_000 && abs(Int($0.dx)) <= 20_000 }, "no frame exceeds the outstanding cap")
    }
    // C: a high-resolution wheel (many small events) is one continuous gesture, not a stutter of many.
    do {
        var w = SmoothWheel()
        var frames: [WheelFrame] = []
        var t = 0.0
        for _ in 0..<100 {
            w.add(dy: 2.7, dx: 0, at: t)
            t += 0.008
            frames += w.frames(at: t)
        }
        while w.isAnimating { t += 1.0 / 120; frames += w.frames(at: t) }
        check(frames.filter { $0.phase == .began }.count == 1 && sum(frames).dy == 270,
              "hi-res wheel: 100 × 2.7 px at 125 Hz -> one gesture of \(sum(frames).dy) px")
    }
}

func checkShiftWheel() {
    print("⇧ + wheel scrolls sideways (AppKit converts plain wheel events only, not our gestures)")
    let a = WheelMath.applyShift(dy: 27, dx: 0, flags: shift)
    check(a.dy == 0 && a.dx == 27, "⇧: vertical -> horizontal, same sign (like AppKit)")
    let b = WheelMath.applyShift(dy: -27, dx: 5, flags: shift | cmd)
    check(b.dy == 0 && b.dx == -27, "⇧ with another modifier: vertical wins, horizontal part dropped (like AppKit)")
    let c = WheelMath.applyShift(dy: 0, dx: 13, flags: shift)
    check(c.dy == 0 && c.dx == 13, "⇧ + tilt wheel: stays horizontal")
    let d = WheelMath.applyShift(dy: 27, dx: 3, flags: opt)
    check(d.dy == 27 && d.dx == 3, "no ⇧: unchanged")

    let clock = FakeClock()
    let fx = FakeClientEffects(clock: clock)
    let inj = FakeInjector()
    let timer = FakeFrameTimer()
    let core = ClientCore(geometry: ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982)]),
                          injector: inj, effects: fx, frameTimer: timer)
    core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0))
    var tick = ScrollData()
    tick.delta1 = 1; tick.point1 = 10; tick.fixed1 = 1
    core.receive(.scroll(tick, flags: shift))
    for _ in 0..<60 { clock.advance(1.0 / 120); timer.fire() }
    check(sum(inj.wheelFrames).dx == 27 && sum(inj.wheelFrames).dy == 0, "client: ⇧ + wheel -> 27 px sideways -> \(sum(inj.wheelFrames))")
    core.update(wheel: WheelConfig(smooth: false))
    inj.clearFrames()
    core.receive(.scroll(tick, flags: shift))
    check(inj.wheelFrames.first?.dx == 27 && inj.wheelFrames.first?.dy == 0, "…also with smooth scrolling off")
}

func checkPadGestureClosing() {
    print("Forwarded trackpad / Magic Mouse gestures are closed when control leaves mid-scroll")
    func pad(_ phase: Int64, momentum: Int64 = 0, dy: Int64 = 3) -> ScrollData {
        var s = ScrollData()
        s.isContinuous = 1; s.scrollPhase = phase; s.momentumPhase = momentum; s.point1 = dy; s.delta1 = dy > 0 ? 1 : 0
        return s
    }
    var t = PadGestureTracker()
    t.track(pad(1)); t.track(pad(2))
    let closing = t.closingEvents()
    check(closing.count == 1 && closing[0].scrollPhase == 4 && closing[0].isContinuous == 1 && closing[0].point1 == 0 && closing[0].delta1 == 0,
          "open gesture -> one ended event without distance")
    check(t.closingEvents().isEmpty, "…only once")
    t.track(pad(1)); t.track(pad(2)); t.track(pad(4, dy: 0))
    check(t.closingEvents().isEmpty, "a gesture that ended normally needs nothing")
    t.track(pad(0, momentum: 1)); t.track(pad(0, momentum: 2))
    let m = t.closingEvents()
    check(m.count == 1 && m[0].momentumPhase == 3 && m[0].scrollPhase == 0, "momentum running -> momentum end")
    t.track(pad(0, momentum: 1)); t.track(pad(0, momentum: 3, dy: 0))
    check(t.closingEvents().isEmpty, "momentum that ended needs nothing")
    t.track(pad(128, dy: 0))
    check(t.closingEvents().first?.scrollPhase == 8, "may-begin -> cancelled")
    t.track(pad(0, momentum: 2)); t.track(pad(1))
    let restart = t.closingEvents()
    check(restart.count == 1 && restart[0].scrollPhase == 4, "fingers back during momentum: only the new gesture is open")

    let clock = FakeClock()
    let geometry = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982)])
    let fx = FakeClientEffects(clock: clock)
    let inj = FakeInjector()
    let core = ClientCore(geometry: geometry, injector: inj, effects: fx, frameTimer: FakeFrameTimer())
    func enter() { core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0)); inj.clearScrolls() }
    enter()
    core.receive(.scroll(pad(1), flags: 0)); core.receive(.scroll(pad(2), flags: 0))
    final class Seen: @unchecked Sendable { var scrollsAtLeave = -1 }
    let seen = Seen()
    fx.forward = { msg in if case .leave = msg { seen.scrollsAtLeave = inj.postedScrolls.count } }
    core.receive(.mouseMove(dx: -500, dy: 0)) // hand back through the edge mid-gesture
    check(core.currentMode == .idle && inj.postedScrolls.last?.scrollPhase == 4 && inj.postedScrolls.count == 3,
          "hand-back mid trackpad gesture posts its ended")
    check(seen.scrollsAtLeave == 2, "…after `leave` went out (the switch itself is not delayed)")
    fx.forward = nil
    enter()
    core.receive(.scroll(pad(0, momentum: 1), flags: 0)); core.receive(.scroll(pad(0, momentum: 2), flags: 0))
    core.receive(.releaseAll)
    check(inj.postedScrolls.last?.momentumPhase == 3, "server takes control back during momentum -> momentum end posted")
    enter()
    core.receive(.scroll(pad(1), flags: 0))
    core.peerDisconnected()
    check(inj.postedScrolls.last?.scrollPhase == 4, "disconnect mid-gesture -> ended posted")
    enter()
    core.receive(.scroll(pad(1), flags: 0))
    clock.advance(4)
    core.tick()
    check(core.currentMode == .idle && inj.postedScrolls.last?.scrollPhase == 4, "server silent mid-gesture -> ended posted")
    enter()
    core.receive(.scroll(pad(1), flags: 0)); core.receive(.scroll(pad(4, dy: 0), flags: 0))
    let n = inj.postedScrolls.count
    core.receive(.releaseAll)
    check(inj.postedScrolls.count == n, "finished gesture: nothing extra posted on releaseAll")
    enter()
    core.receive(.scroll(pad(1), flags: 0))
    enter() // a new stint without releaseAll in between
    check(inj.postedScrolls.isEmpty, "(enter clears)")
}

func checkPadGestureOwnership() {
    print("Server: a trackpad gesture (and its momentum) stays on the Mac where it began")
    func pad(_ phase: Int64, momentum: Int64 = 0, dy: Int64 = 4) -> ScrollData {
        var s = ScrollData()
        s.isContinuous = 1; s.scrollPhase = phase; s.momentumPhase = momentum; s.point1 = dy
        return s
    }
    var o = PadGestureOwner()
    check(!o.route(pad(128), remoteNow: false, at: 0) && !o.route(pad(1), remoteNow: true, at: 0.01), "may-begin → began is one gesture (began while remote stays local)")
    check(!o.route(pad(2), remoteNow: true, at: 0.02) && !o.route(pad(4, dy: 0), remoteNow: true, at: 0.03), "changed / ended stay local")
    check(!o.route(pad(0, momentum: 1), remoteNow: true, at: 0.05) && !o.route(pad(0, momentum: 3, dy: 0), remoteNow: true, at: 0.4),
          "its momentum stays local")
    check(o.route(pad(128), remoteNow: true, at: 0.5), "the next gesture belongs to the Mac controlled when it starts")
    check(o.route(pad(0, momentum: 2), remoteNow: false, at: 0.6), "…momentum tail after returning still belongs to it")
    check(!o.route(pad(0, momentum: 2), remoteNow: false, at: 2), "after a pause (> \(PadGestureOwner.maxGap) s) an event starts afresh")
    check(o.route(pad(0), remoteNow: true, at: 2.1) && !o.route(pad(0), remoteNow: false, at: 2.2), "phase-less smooth scrolling follows the current mode")

    let clock = FakeClock()
    let fx = FakeServerEffects(clock: clock)
    let core = ServerCore(geometry: ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 2560, height: 1440)]), config: ServerCore.Config(), effects: fx)
    core.setPeerReady(true)
    func scroll(_ s: ScrollData) -> Bool { clock.advance(0.016); return core.handle(CapturedEvent(kind: .scroll(s))) }
    func forwardedScrolls() -> Int { fx.sentSnapshot.filter { if case .scroll = $0 { return true }; return false }.count }
    // Local gesture, then control moves to the other Mac mid-momentum.
    check(scroll(pad(1)) && scroll(pad(2)), "local gesture passes through")
    _ = core.switchToRemote()
    fx.clear()
    check(scroll(pad(2)) && scroll(pad(4, dy: 0)) && scroll(pad(0, momentum: 1)) && scroll(pad(0, momentum: 3, dy: 0)),
          "after switching: the local gesture's rest and momentum stay on this Mac")
    check(forwardedScrolls() == 0, "…and are not forwarded")
    check(!scroll(pad(128)) && !scroll(pad(1)) && !scroll(pad(2)), "a new gesture while remote is forwarded")
    check(forwardedScrolls() == 3, "…all of it")
    // Control comes back mid-gesture: the tail is swallowed here (the other Mac closed its copy).
    core.receive(.leave(fraction: 0.5))
    fx.clear()
    check(!scroll(pad(2)) && !scroll(pad(4, dy: 0)) && !scroll(pad(0, momentum: 2)), "after returning: the forwarded gesture's tail does not scroll this Mac")
    check(forwardedScrolls() == 0, "…and is not forwarded any more")
    check(scroll(pad(128)) && scroll(pad(1)), "a new local gesture scrolls normally")
    var wheel = ScrollData()
    wheel.delta1 = 1; wheel.point1 = 10
    check(core.handle(CapturedEvent(kind: .scroll(wheel))), "mouse wheel in local mode untouched")
}

func checkServerCursorOrder() {
    print("Server cursor: hidden before the park warp (no flash), warped + re-attached before it is shown")
    final class OpLog: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ s: String) { lock.withLock { list.append(s) } }
        var ops: [String] { lock.withLock { list } }
        func clear() { lock.withLock { list.removeAll() } }
    }
    let log = OpLog()
    let ops = CursorOps(warp: { log.add("warp \(Int($0.x))") }, attach: { log.add($0 ? "attach" : "detach") },
                        hide: { log.add("hide") }, show: { log.add("show") }, place: { log.add("place \(Int($0.x))") })
    let c = SystemCursorControl(ops: ops)
    c.park(at: CGPoint(x: 960, y: 540))
    check(log.ops == ["hide", "attach", "place 960"], "park: hide, stay attached, place (never warp) -> \(log.ops)")
    log.clear()
    c.keepParked(at: CGPoint(x: 960, y: 540))
    check(log.ops == ["place 960"], "keep parked: placed back, no warp, no extra hide")
    log.clear()
    c.restore(at: CGPoint(x: 2559, y: 700))
    // Regression (real hardware): a warp on return froze the cursor ≥ 90 ms while deltas kept coming.
    check(log.ops == ["attach", "place 2559", "show"], "restore: re-attach, place like real motion (no warp), then show -> \(log.ops)")
    log.clear()
    let group = DispatchGroup()
    for i in 0..<8 {
        group.enter()
        Thread.detachNewThread {
            for j in 0..<150 {
                if (i + j) % 2 == 0 { c.park(at: CGPoint(x: 960, y: 540)) } else { c.restore(at: CGPoint(x: 10, y: 10)) }
            }
            group.leave()
        }
    }
    group.wait()
    let vis = log.ops.filter { $0 == "hide" || $0 == "show" }
    check(zip(vis, vis.dropFirst()).allSatisfy { $0 != $1 } && (vis.last == "hide") == c.isHidden,
          "concurrent park / restore: hide and show stay balanced (\(vis.count) calls)")
    check(!log.ops.contains("detach"), "…and the cursor is never detached from the mouse (a re-attach lags ≥ 90 ms)")
    var sequenceOK = true
    var i = 0
    let all = log.ops
    while i < all.count { // every park / restore ran as one uninterrupted sequence
        if all[i] == "hide" { // park: hide, attach, place
            let seq = Array(all[i..<min(i + 3, all.count)])
            if !(seq.count == 3 && seq[1] == "attach" && seq[2].hasPrefix("place")) { sequenceOK = false }
            i += seq.count
        } else if all[i] == "attach" { // restore: attach, place, [show]  — or park while already hidden
            let seq = Array(all[i..<min(i + 3, all.count)])
            if !(seq.count >= 2 && seq[1].hasPrefix("place")) { sequenceOK = false }
            i += seq.count == 3 && seq[2] == "show" ? 3 : 2
        } else {
            sequenceOK = false
            i += 1
        }
    }
    check(!log.ops.contains { $0.hasPrefix("warp") }, "…and the cursor is never warped (a warp freezes it for a moment)")
    check(sequenceOK, "…each park / restore applied as one uninterrupted sequence")
    c.restore(at: .zero)
    log.clear()
    do {
        let temp = SystemCursorControl(ops: ops)
        temp.park(at: CGPoint(x: 1, y: 1))
    }
    check(log.ops.last == "show", "a released controller never leaves the cursor hidden")
}

func checkCursorBalance() {
    print("Cursor balance in every path (fuzzed): server parked ⇔ remote; client hidden only after losing control")
    // Server.
    do {
        let clock = FakeClock()
        let fx = FakeServerEffects(clock: clock)
        let big = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 2560, height: 1440), CGRect(x: -1920, y: 0, width: 1920, height: 1080)])
        let small = ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 2560, height: 1440)])
        var config = ServerCore.Config()
        config.switchHotKey = (49, ctrl | opt | cmd)
        let core = ServerCore(geometry: big, config: config, effects: fx)
        core.setPeerReady(true)
        var rng = SplitMix(seed: 0xC0FFEE)
        var violations: [String] = []
        var entries = 0, returnsByPath = [Int](repeating: 0, count: 12)
        for step in 0..<4000 {
            let op = Int.random(in: 0..<12, using: &rng)
            let wasRemote = core.currentMode == .remote
            switch op {
            case 0: clock.advance(0.3); _ = core.handle(move(2559, 700, dx: 14, dy: 0))       // push against the edge
            case 1: _ = core.switchToRemote()                                                   // menu / hotkey (local)
            case 2: core.receive(.leave(fraction: Double.random(in: 0...1, using: &rng)))       // client hands back
            case 3: _ = core.handle(CapturedEvent(kind: .keyDown(keyCode: 49, autorepeat: false), flags: ctrl | opt | cmd)) // hotkey in the tap
            case 4: core.returnToLocal(reason: "菜单")                                          // menu / sleep / lock
            case 5: clock.advance(2); core.tick()                                              // heartbeat loss
            case 6: core.tapWasDisabled()                                                      // tap timeout
            case 7: core.setPeerReady(false, reason: "连接中断")                                // disconnect
            case 8: core.setPeerReady(true)                                                    // reconnect
            case 9: core.update(geometry: Bool.random(using: &rng) ? big : small)              // display added / removed
            case 10: clock.advance(0.4); core.receive(.heartbeat(seq: 1, sentAt: clock.now, isReply: false)); core.tick()
            default: _ = core.handle(move(1000, 500, dx: Double.random(in: -30...30, using: &rng), dy: 3)) // motion
            }
            let remote = core.currentMode == .remote
            if remote && !wasRemote { entries += 1 }
            if wasRemote && !remote { returnsByPath[op] += 1 }
            if (fx.parked != nil) != remote { violations.append("step \(step) op \(op): parked=\(fx.parked != nil) mode=\(core.currentMode)") }
            if fx.capture != remote { violations.append("step \(step) op \(op): keyboard capture \(fx.capture) in \(core.currentMode)") }
        }
        check(violations.isEmpty, "server: cursor parked/hidden exactly while remote, keyboard tap only then (\(entries) switches) \(violations.prefix(3))")
        let paths = [2, 3, 4, 5, 6, 7]
        check(paths.allSatisfy { returnsByPath[$0] > 0 }, "…every return path exercised (leave, hotkey, menu, heartbeat, tap, disconnect) -> \(paths.map { returnsByPath[$0] })")
    }
    // Client.
    do {
        let clock = FakeClock()
        let fx = FakeClientEffects(clock: clock)
        let inj = FakeInjector()
        let core = ClientCore(geometry: ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982)]), injector: inj, effects: fx,
                              frameTimer: FakeFrameTimer())
        var rng = SplitMix(seed: 0xBEEF)
        var violations: [String] = []
        var lost = 0
        let sides: [ScreenSide] = [.left, .right, .top, .bottom]
        var edge = ScreenSide.left
        for step in 0..<4000 {
            let op = Int.random(in: 0..<9, using: &rng)
            let wasControlled = core.currentMode == .controlled
            inj.canInject = true
            switch op {
            case 0:
                edge = sides[Int.random(in: 0..<4, using: &rng)]
                core.receive(.enter(edge: edge, fraction: Double.random(in: 0...1, using: &rng), center: Bool.random(using: &rng), flags: 0))
            case 1: // push out through the entry edge
                let d = 5000.0
                switch edge {
                case .left: core.receive(.mouseMove(dx: -d, dy: 0))
                case .right: core.receive(.mouseMove(dx: d, dy: 0))
                case .top: core.receive(.mouseMove(dx: 0, dy: -d))
                case .bottom: core.receive(.mouseMove(dx: 0, dy: d))
                }
            case 2: core.receive(.releaseAll)
            case 3: clock.advance(4); core.tick() // server silent
            case 4: core.peerDisconnected()
            case 5: inj.canInject = false; core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0)) // refused
            case 6: if inj.cursorHidden { inj.localInput() } // this Mac's own trackpad
            case 7: clock.advance(0.4); core.receive(.heartbeat(seq: 1, sentAt: clock.now, isReply: false)); core.tick()
            default: core.receive(.mouseMove(dx: Double.random(in: -40...40, using: &rng), dy: Double.random(in: -40...40, using: &rng)))
            }
            let controlled = core.currentMode == .controlled
            if controlled && inj.cursorHidden { violations.append("step \(step) op \(op): hidden while controlled") }
            if wasControlled && !controlled {
                if op == 4 {
                    if inj.cursorHidden { violations.append("step \(step): hidden after disconnect") }
                } else if op != 0 && op != 5 {
                    lost += 1
                    if !inj.cursorHidden { violations.append("step \(step) op \(op): still visible after losing control") }
                }
            }
            if op == 4 && inj.cursorHidden { violations.append("step \(step): hidden after the session ended") }
        }
        check(violations.isEmpty, "client: visible while controlled, hidden after every loss of control (\(lost)), shown when the session ends \(violations.prefix(3))")
    }
}

/// Live clock, no-op effects: for driving ClientCore with the real 120 Hz frame timer.
final class LiveClientEffects: ClientEffects, @unchecked Sendable {
    func send(_ message: InputMessage) {}
    func sendClipboardIfChanged() {}
    func applyClipboard(_ items: [ClipboardItem]) {}
    func stateDidChange(_ snapshot: ClientCore.Snapshot) {}
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

func checkClientWheelConcurrency() {
    print("Client wheel under concurrency (real 120 Hz timer, channel thread, settings changes)")
    let fx = LiveClientEffects()
    let inj = FakeInjector()
    let core = ClientCore(geometry: ScreenGeometry(displays: [CGRect(x: 0, y: 0, width: 1512, height: 982)]), injector: inj, effects: fx,
                          frameTimer: DispatchFrameTimer())
    core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0))
    let done = DispatchGroup()
    done.enter()
    Thread.detachNewThread {
        var rng = SplitMix(seed: 99)
        for i in 0..<400 {
            var s = ScrollData()
            let v = Int64.random(in: -12...12, using: &rng)
            if Int.random(in: 0..<5, using: &rng) == 0 { s.point2 = v } else { s.point1 = v }
            core.receive(.scroll(s, flags: 0))
            switch i % 97 {
            case 13: core.receive(.mouseButton(button: 0, down: true, clickState: 1, flags: 0))
            case 14: core.receive(.mouseButton(button: 0, down: false, clickState: 1, flags: 0))
            case 50: core.receive(.releaseAll); core.receive(.enter(edge: .left, fraction: 0.5, center: false, flags: 0))
            default: break
            }
            Thread.sleep(forTimeInterval: Double.random(in: 0...0.004, using: &rng))
        }
        done.leave()
    }
    done.enter()
    Thread.detachNewThread {
        for i in 0..<40 {
            core.update(wheel: WheelConfig(smooth: i % 5 != 0, speed: 1 + i % 5))
            Thread.sleep(forTimeInterval: 0.02)
        }
        done.leave()
    }
    done.wait()
    Thread.sleep(forTimeInterval: 0.35) // let the last gesture finish on its own
    core.receive(.releaseAll)
    let frames = inj.wheelFrames
    let err = wheelGrammar(frames)
    check(err == nil && !frames.isEmpty, "phase grammar holds across threads (\(frames.count) frames)\(err.map { " — \($0)" } ?? "")")
    let settled = frames.count
    Thread.sleep(forTimeInterval: 0.1)
    check(inj.wheelFrames.count == settled, "timer idle afterwards: nothing posted once control left")
    core.peerDisconnected()
}

@MainActor
func checkClipboardRobustness() {
    print("Clipboard robustness (stragglers, duplicates, missing pieces, id wrap, failures, disconnect mid-transfer)")
    var rng = SystemRandomNumberGenerator()
    let big = [ClipboardItem(type: "public.png", data: Data((0..<50_000).map { _ in UInt8.random(in: 0...255, using: &rng) }))]
    let small = [ClipboardItem(type: "public.utf8-plain-text", data: Data("新的".utf8))]
    let a7 = ClipboardChunker.chunks(for: ClipboardCodec.encode(big), transferID: 7, chunkBytes: 4096)
    let b8 = ClipboardChunker.chunks(for: ClipboardCodec.encode(small), transferID: 8, chunkBytes: 4096)
    var asm = ClipboardAssembler()
    _ = asm.add(a7[0], at: 0)
    check(asm.add(b8[0], at: 0) == .complete(small), "newer transfer completes")
    check(asm.add(a7[1], at: 0) == .pending && !asm.isReceiving, "straggler of the superseded transfer ignored")
    check(asm.add(b8[0], at: 0) == .pending && !asm.isReceiving, "late duplicate of the completed transfer ignored")
    // Missing piece: never completes; dropped on timeout; the next transfer is unaffected.
    asm = ClipboardAssembler()
    var outcome = ClipboardAssembler.Outcome.pending
    for (i, c) in a7.enumerated() where i != 5 { outcome = asm.add(c, at: 1) }
    check(outcome == .pending && asm.isReceiving, "one piece missing -> still pending")
    check(asm.expire(at: 1 + ClipboardLimits.transferTimeout + 0.1) != nil && !asm.isReceiving, "…dropped after the timeout")
    check(asm.add(a7[5], at: 20) == .pending && !asm.isReceiving, "the missing piece arriving late is ignored")
    let c9 = ClipboardChunker.chunks(for: ClipboardCodec.encode(small), transferID: 9, chunkBytes: 4096)
    check(asm.add(c9[0], at: 21) == .complete(small), "next transfer works")
    // Interleaved transfers (not produced by one sender, but must not wedge the receiver).
    asm = ClipboardAssembler()
    let a10 = ClipboardChunker.chunks(for: ClipboardCodec.encode(big), transferID: 10, chunkBytes: 20_000)
    let b11 = ClipboardChunker.chunks(for: ClipboardCodec.encode(big + small), transferID: 11, chunkBytes: 20_000)
    var results: [ClipboardAssembler.Outcome] = []
    for i in 0..<max(a10.count, b11.count) {
        if i < a10.count { results.append(asm.add(a10[i], at: 0)) }
        if i < b11.count { results.append(asm.add(b11[i], at: 0)) }
    }
    check(results.last == .complete(big + small) && !results.contains(.complete(big)), "interleaved: the newer transfer wins, the older one is ignored")
    // Transfer id wrap-around.
    asm = ClipboardAssembler()
    let wrapOld = ClipboardChunker.chunks(for: ClipboardCodec.encode(small), transferID: UInt32.max, chunkBytes: 4096)
    let wrapNew = ClipboardChunker.chunks(for: ClipboardCodec.encode(big), transferID: 0, chunkBytes: 4096)
    check(asm.add(wrapOld[0], at: 0) == .complete(small), "id 0xFFFFFFFF")
    var wrapOutcome = ClipboardAssembler.Outcome.pending
    for c in wrapNew { wrapOutcome = asm.add(c, at: 0) }
    check(wrapOutcome == .complete(big), "id 0 after 0xFFFFFFFF counts as newer")

    // Sender outcomes.
    final class Outcomes: @unchecked Sendable {
        let lock = NSLock()
        var list: [ClipboardSender.Outcome] = []
        func add(_ o: ClipboardSender.Outcome) { lock.withLock { list.append(o) } }
        var all: [ClipboardSender.Outcome] { lock.withLock { list } }
    }
    let outcomes = Outcomes()
    final class FailingWire: @unchecked Sendable {
        let lock = NSLock()
        var sent = 0
        let failAfter: Int
        init(failAfter: Int) { self.failAfter = failAfter }
        func send(_ c: (@Sendable (Error?) -> Void)?) {
            let n: Int = lock.withLock { sent += 1; return sent }
            c?(n > failAfter ? PeerLinkError.closed : nil)
        }
    }
    let failing = FailingWire(failAfter: 2)
    let s1 = ClipboardSender(chunkBytes: 4096) { _, _, c in failing.send(c) }
    s1.send(big, chunked: true) { outcomes.add($0) }
    check(outcomes.all == [.failed] && failing.sent == 3, "channel fails mid-transfer -> .failed, no more pieces sent")
    let ok = FailingWire(failAfter: .max)
    let s2 = ClipboardSender(chunkBytes: 4096) { _, _, c in ok.send(c) }
    s2.send(big, chunked: true) { outcomes.add($0) }
    check(outcomes.all.last == .sent && ok.sent == a7.count, "all pieces handed over -> .sent")
    s2.send([ClipboardItem(type: "public.png", data: Data(count: PeerLimits.maxPayloadSize))], chunked: false) { outcomes.add($0) }
    check(outcomes.all.last == .refused, "too large for an older peer -> .refused (not retried)")

    // Disconnect mid-transfer over a real channel pair: the receiver never applies a partial clipboard.
    let (hubA, hubB) = LoopbackPeerHub.makePair(nameA: "Studio", nameB: "MBP")
    final class Box<T>: @unchecked Sendable { var value: T?; init() {} }
    let chA = Box<PeerChannel>(), chB = Box<PeerChannel>()
    hubA.register(service: "input") { chA.value = $0 }
    hubB.register(service: "input") { chB.value = $0 }
    guard waitUntil(3, { chA.value != nil && chB.value != nil }), let a = chA.value, let b = chB.value else {
        check(false, "channels formed"); return
    }
    final class Delivered: @unchecked Sendable {
        let lock = NSLock()
        var messages: [InputMessage] = []
        func add(_ m: InputMessage) { lock.withLock { messages.append(m) } }
        var count: Int { lock.withLock { messages.count } }
    }
    let delivered = Delivered()
    let inbox = ClipboardInbox()
    b.setHandlers(queue: DispatchQueue(label: "cb.robust"), onMessage: { t, p in
        InputSession.route(type: t, payload: p, inbox: inbox, hello: { _ in }, deliver: { delivered.add($0) })
    }, onClose: { _ in })
    final class Counter: @unchecked Sendable { let lock = NSLock(); var n = 0 }
    let pieces = Counter()
    let failOutcome = Outcomes()
    let sender = ClipboardSender(chunkBytes: 4096) { t, p, c in
        let n: Int = pieces.lock.withLock { pieces.n += 1; return pieces.n }
        a.send(type: t, payload: p, completion: c)
        if n == 3 { a.close() } // the other Mac disconnects mid-transfer
    }
    sender.send(big, chunked: true) { failOutcome.add($0) }
    check(waitUntil { !failOutcome.all.isEmpty }, "sender learns about the disconnect")
    check(failOutcome.all == [.failed], "…as .failed (offered again at the next switch)")
    _ = waitUntil(0.3) { false }
    check(delivered.count == 0, "receiver: no partial clipboard delivered")
    _ = (hubA, hubB)

    // Re-offer after a failed transfer (ClipboardSync on a private pasteboard).
    let pb = NSPasteboard(name: NSPasteboard.Name("com.oneswitch.check.\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    let sync = ClipboardSync(pasteboard: pb)
    pb.clearContents()
    pb.setString("待同步", forType: .string)
    check(sync.snapshotIfChanged() != nil, "clipboard offered")
    let change = sync.syncedChange
    check(sync.snapshotIfChanged() == nil, "…once")
    sync.markUnsent(changeCount: change)
    check(sync.snapshotIfChanged()?.first?.data == Data("待同步".utf8), "failed transfer -> offered again at the next switch")
    let stale = sync.syncedChange
    pb.clearContents()
    pb.setString("更新的", forType: .string)
    _ = sync.snapshotIfChanged()
    sync.markUnsent(changeCount: stale)
    check(sync.snapshotIfChanged() == nil, "a failure of an older clipboard does not resend the current one")
}

MainActor.assumeIsolated {
    checkCodec()
    checkGeometry()
    checkServer()
    checkClient()
    checkReadiness()
    checkTapDisablePolicy()
    checkWarpArtifact()
    checkEndToEnd()
    checkHardening()
    checkServerSafety()
    checkClientSafety()
    checkCursorVisibility()
    checkModuleStatus()
    checkEndToEndRefusal()
    checkProtocolCompatibility()
    checkSettingsMigration()
    checkWheelMath()
    checkServerWheelForwarding()
    checkSmoothWheel()
    checkClientWheel()
    checkClipboardTransfer()
    checkClipboardBothDirections()
    checkClipboardPasteboard()
    checkSwitchOrder()
    checkWheelFuzz()
    checkShiftWheel()
    checkPadGestureClosing()
    checkPadGestureOwnership()
    checkServerCursorOrder()
    checkCursorBalance()
    checkClientWheelConcurrency()
    checkClipboardRobustness()
}
print(failures == 0 ? "SharedInputCheck: ALL PASSED" : "SharedInputCheck: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
