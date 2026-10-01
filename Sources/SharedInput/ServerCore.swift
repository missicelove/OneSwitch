import CoreGraphics
import Foundation

/// Side effects the server state machine needs. The real implementation drives the event tap,
/// the cursor and the peer channel; checks use fakes. Called with the core's lock held — must not
/// call back into the core synchronously.
public protocol ServerEffects: AnyObject {
    func send(_ message: InputMessage)
    /// Detach and hide the local cursor, parking it at `point` while the other Mac is controlled.
    func parkCursor(at point: CGPoint)
    /// Keep the hidden cursor parked (re-warp if it drifted).
    func keepCursorParked(at point: CGPoint)
    /// Warp the cursor to `point`, re-attach it to the mouse and show it.
    func restoreCursor(at point: CGPoint)
    /// Enable / disable interception of keyboard events. Enabled ONLY while the other Mac is controlled.
    func setKeyboardCapture(_ enabled: Bool)
    /// Send this Mac's clipboard to the peer if it changed since the last sync.
    func sendClipboardIfChanged()
    /// The other Mac handed over its clipboard (it lost control): write it here, off the switching path.
    func applyClipboard(_ items: [ClipboardItem])
    func stateDidChange(_ snapshot: ServerCore.Snapshot)
    /// Monotonic seconds.
    func now() -> TimeInterval
    /// False when the cursor cannot be hidden (the private background-cursor switch is unavailable): the
    /// cursor is then parked where it left the screen instead of at the centre of the main display.
    var canHideCursor: Bool { get }
    /// Diagnostics line (INFO) — default no-op.
    func log(_ line: String)
}

public extension ServerEffects {
    var canHideCursor: Bool { true }
    func log(_ line: String) {}
}

/// The server's switching logic (the Mac whose physical keyboard & mouse are shared).
///
/// Privacy by construction: in `.local` mode keyboard events are never intercepted (the keyboard tap is
/// disabled) and mouse events pass through untouched; only mouse positions are examined to detect the
/// screen edge. Keyboard events are intercepted only in `.remote` mode — after the user deliberately moved
/// control to the other Mac — and are then forwarded to that Mac to be typed there. Nothing is stored.
///
/// Thread-safe: `handle` runs on the event-tap thread, `receive`/`tick` on the channel queue, the rest
/// on the main thread.
public final class ServerCore: @unchecked Sendable {
    public enum Mode: Equatable, Sendable {
        /// No usable peer (not connected, role conflict, client lacks permission).
        case offline
        /// This Mac has control.
        case local
        /// The other Mac has control; local input is forwarded.
        case remote
    }

    public struct Config: Equatable, Sendable {
        public var clientSide: ScreenSide = .right
        public var dwell: TimeInterval = 0
        public var requiredModifierMask: UInt64 = 0
        public var blockWhileButtonHeld = true
        /// Hotkey detected inside the tap while remote: (virtual key code, CGEventFlags modifier mask).
        public var switchHotKey: (keyCode: UInt16, modifiers: UInt64)?
        /// Return to local if nothing was heard from the client for this long while remote (spec: > 1.5 s;
        /// both sides send a heartbeat every 0.5 s).
        public var heartbeatTimeout: TimeInterval = 1.5
        /// Direction of forwarded mouse-wheel (non-continuous) scrolling on the other Mac.
        public var wheelDirection: WheelDirection = .windows

        public init() {}

        public static func == (a: Config, b: Config) -> Bool {
            a.clientSide == b.clientSide && a.dwell == b.dwell && a.requiredModifierMask == b.requiredModifierMask
                && a.blockWhileButtonHeld == b.blockWhileButtonHeld && a.heartbeatTimeout == b.heartbeatTimeout
                && a.wheelDirection == b.wheelDirection
                && a.switchHotKey?.keyCode == b.switchHotKey?.keyCode && a.switchHotKey?.modifiers == b.switchHotKey?.modifiers
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public var mode: Mode
        public var lastReason: String?
        public var rtt: TimeInterval?
        public var eventsPerSecond: Int
    }

    private let lock = NSLock()
    private weak var effects: ServerEffects?
    private var geometry: ScreenGeometry
    private var config: Config

    private var mode: Mode = .offline
    private var heldButtons = Set<Int>()        // physical buttons down while local
    private var remoteKeys = Set<UInt16>()      // keys whose key-down was forwarded
    private var remoteButtons = Set<Int>()      // buttons whose down was forwarded
    private var entryFlags: UInt64 = 0          // modifiers already held when control moved
    private var entryKeys = Set<UInt16>()       // modifier keys (per side) held when control moved
    private var edgeSince: TimeInterval?
    private var cooldownUntil: TimeInterval = 0
    private var parkPoint = CGPoint.zero
    /// The delta macOS is expected to fold into the next mouse event after we warped the cursor (the
    /// warp vector), until when to expect it.
    private var warpArtifact: (dx: Double, dy: Double, until: TimeInterval)?
    /// Forwarded moves logged after each switch (diagnostics for real-hardware testing).
    private var movesToLog = 0
    private var scrollsToLog = 0
    /// When control last came back (diagnostics: delay until the first local mouse event).
    private var returnedAt: TimeInterval?
    private var returnTraceCount = 0
    private var lastHeard: TimeInterval = 0
    /// Which Mac a trackpad / Magic Mouse scroll gesture (incl. its momentum) belongs to.
    private var padGestureOwner = PadGestureOwner()
    private var heartbeatSeq: UInt32 = 0
    private var rtt: TimeInterval?
    private var lastReason: String?
    private var eventCount = 0
    private var eventsPerSecond = 0
    private var lastRateSample: TimeInterval = 0

    public init(geometry: ScreenGeometry, config: Config, effects: ServerEffects) {
        self.geometry = geometry
        self.config = config
        self.effects = effects
    }

    // MARK: Queries

    public var currentMode: Mode { lock.withLock { mode } }

    public var snapshot: Snapshot { lock.withLock { makeSnapshot() } }

    // MARK: Configuration

    public func update(geometry: ScreenGeometry) {
        lock.withLock {
            self.geometry = geometry
            // A display was removed while the other Mac is controlled: re-park the hidden cursor on a display
            // that still exists (otherwise every forwarded move would fight the system's clamping).
            if mode == .remote, !geometry.isEmpty, geometry.display(containing: parkPoint) == nil {
                parkPoint = geometry.nearestPoint(to: parkPoint)
                effects?.parkCursor(at: parkPoint)
            }
        }
    }

    public func update(config: Config) {
        lock.withLock { self.config = config }
    }

    /// Peer usable (connected, it is a client, and it can inject events) or not.
    public func setPeerReady(_ ready: Bool, reason: String? = nil) {
        lock.withLock {
            if ready {
                guard mode == .offline else { return }
                mode = .local
                lastHeard = now
                lastReason = reason
            } else {
                if mode == .remote {
                    // Not only on disconnect: a role change, a permission change or a version mismatch also
                    // lands here while the channel is still open. Tell the client to release what it holds —
                    // it keeps answering our heartbeats, so its silence timeout would never fire. (If the
                    // channel is already gone the send is simply dropped.)
                    leaveRemote(to: nil, reason: reason ?? "连接中断", notifyPeer: true)
                }
                mode = .offline
                lastReason = reason
                edgeSince = nil
            }
            publish()
        }
    }

    // MARK: Event tap entry point

    /// Returns true to let the event through, false to swallow it.
    public func handle(_ event: CapturedEvent) -> Bool {
        lock.withLock { handleLocked(event) }
    }

    private func handleLocked(_ e: CapturedEvent) -> Bool {
        switch mode {
        case .offline:
            trackLocalButtons(e.kind)
            if case .scroll(let s) = e.kind, s.isContinuous != 0 { _ = padGestureOwner.route(s, remoteNow: false, at: now) }
            return true
        case .local:
            trackLocalButtons(e.kind)
            if case .scroll(let s) = e.kind, s.isContinuous != 0, padGestureOwner.route(s, remoteNow: false, at: now) {
                // The tail (momentum) of a trackpad gesture that was forwarded before control came back: it
                // must not scroll whatever is under this Mac's cursor now (the other Mac closed its copy).
                return false
            }
            if let back = returnedAt {
                // Diagnostics for the "hitch" after control returns: trace the first local mouse events
                // (time since return, reported cursor location, device delta). A cursor whose location
                // stops changing while deltas keep coming would mean macOS suppressed the motion.
                let ms = (now - back) * 1000
                effects?.log(String(format: "return trace #%d +%.1f ms at %.1f,%.1f delta %.1f,%.1f",
                                    returnTraceCount + 1, ms, e.location.x, e.location.y, e.dx, e.dy))
                returnTraceCount += 1
                if returnTraceCount >= 12 || ms > 400 { returnedAt = nil }
            }
            switch e.kind {
            case .mouseMoved, .mouseDragged:
                if shouldSwitch(for: e) {
                    enterRemote(fraction: geometry.fraction(along: config.clientSide, at: e.location),
                                center: false, flags: e.flags, location: e.location, reason: "鼠标移到屏幕边缘")
                    return false
                }
                return true
            default:
                return true
            }
        case .remote:
            return forward(e)
        }
    }

    private func trackLocalButtons(_ kind: CapturedKind) {
        switch kind {
        case .mouseDown(let b): heldButtons.insert(b)
        case .mouseUp(let b): heldButtons.remove(b)
        // A plain mouseMoved (not *Dragged) means no button is down: resynchronise, so one lost mouse-up
        // (e.g. while the tap was disabled) cannot block edge switching forever.
        case .mouseMoved: heldButtons.removeAll()
        default: break
        }
    }

    private func shouldSwitch(for e: CapturedEvent) -> Bool {
        let t = now
        guard t >= cooldownUntil else { edgeSince = nil; return false }
        if config.blockWhileButtonHeld {
            // A drag means a button is held; that is authoritative even if a button event was missed.
            if case .mouseDragged = e.kind { edgeSince = nil; return false }
            if !heldButtons.isEmpty { edgeSince = nil; return false }
        }
        if config.requiredModifierMask != 0 && (e.flags & config.requiredModifierMask) == 0 { edgeSince = nil; return false }
        guard geometry.isPushing(config.clientSide, at: e.location, dx: e.dx, dy: e.dy) else {
            edgeSince = nil
            return false
        }
        if edgeSince == nil { edgeSince = t }
        return t - (edgeSince ?? t) >= config.dwell
    }

    private func forward(_ e: CapturedEvent) -> Bool {
        switch e.kind {
        case .mouseMoved, .mouseDragged:
            forwardMotion(e)
            return false
        case .mouseDown(let b):
            remoteButtons.insert(b)
            send(.mouseButton(button: UInt8(clamping: b), down: true, clickState: e.clickState, flags: e.flags))
            return false
        case .mouseUp(let b):
            if remoteButtons.remove(b) != nil {
                send(.mouseButton(button: UInt8(clamping: b), down: false, clickState: e.clickState, flags: e.flags))
                return false
            }
            heldButtons.remove(b)
            return true // pressed before control moved: release locally
        case .scroll(let raw):
            if raw.isContinuous != 0, !padGestureOwner.route(raw, remoteNow: true, at: now) {
                // The rest of a trackpad gesture (e.g. its momentum) that began on this Mac before control
                // moved: it ends here, like a key-up (the app scrolling it would otherwise stay mid-gesture).
                return true
            }
            // Trackpad / Magic Mouse (continuous) scrolling is forwarded as is. A mouse wheel gets the
            // configured direction: this tap sees the events before scroll utilities such as Mos, i.e. with
            // macOS's own natural-scrolling inversion applied — undone here, then the chosen style applied.
            let s = raw.isContinuous != 0 ? raw
                : WheelMath.applyDirection(raw, invertedFromDevice: e.scrollInverted, style: config.wheelDirection)
            send(.scroll(s, flags: e.flags))
            if scrollsToLog > 0 {
                scrollsToLog -= 1
                effects?.log("forwarded scroll delta=\(s.delta1),\(s.delta2) point=\(s.point1),\(s.point2) fixed=\(s.fixed1),\(s.fixed2) continuous=\(s.isContinuous) phase=\(s.scrollPhase)/\(s.momentumPhase) inverted=\(e.scrollInverted) style=\(config.wheelDirection.rawValue)")
            }
            return false
        case .keyDown(let keyCode, let autorepeat):
            if isSwitchHotKey(keyCode: keyCode, flags: e.flags) || isFallbackReturnKey(keyCode: keyCode, flags: e.flags) {
                if !autorepeat { leaveRemote(to: nil, reason: "快捷键切回本机", notifyPeer: true) }
                return false
            }
            if autorepeat {
                // Auto-repeat of a key that went down on this Mac before control moved (e.g. the hotkey's
                // Space still held): it must not start typing on the other Mac, whose key-up would then
                // never come. Swallow it.
                guard remoteKeys.contains(keyCode) else { return false }
            } else {
                remoteKeys.insert(keyCode)
            }
            send(.key(keyCode: keyCode, down: true, autorepeat: autorepeat, flags: e.flags))
            return false
        case .keyUp(let keyCode):
            if remoteKeys.remove(keyCode) != nil {
                send(.key(keyCode: keyCode, down: false, autorepeat: false, flags: e.flags))
                return false
            }
            return true // went down on this Mac: its key-up belongs here too
        case .flagsChanged(let keyCode):
            if entryKeys.contains(keyCode), ModifierKeys.isDown(keyCode: keyCode, flags: e.flags) == false {
                // A modifier held before control moved is released: deliver the release locally (it went
                // down here). The client also saw it as held (enter carried the flags), so mirror the
                // release there too; otherwise its mouse events keep e.g. ⌃⌥⌘ until the next key.
                entryKeys.remove(keyCode)
                if let mask = ModifierKeys.mask(forKeyCode: keyCode), e.flags & mask == 0 {
                    // No key of this modifier is down any more (covers flags without left/right bits).
                    entryKeys = entryKeys.filter { ModifierKeys.mask(forKeyCode: $0) != mask }
                }
                send(.flagsChanged(keyCode: keyCode, flags: e.flags))
                return true
            }
            send(.flagsChanged(keyCode: keyCode, flags: e.flags))
            return false
        case .systemDefined(let subtype, let data1, let data2):
            guard subtype == 8 else { return true } // only media / brightness / volume keys
            send(.systemDefined(subtype: subtype, data1: data1, data2: data2, flags: e.flags))
            return false
        }
    }

    /// Motion while controlling the other Mac comes from the events' DEVICE deltas (what games read). The
    /// local cursor is parked (hidden, detached from the mouse) so it does not wander. Two traps, both
    /// seen on real hardware (macOS 27):
    /// - macOS folds a warp's distance into the next event's delta: parking the cursor at the screen centre
    ///   after crossing the left edge produced one "+960 pt" move, which the other Mac read as pushing back
    ///   through its edge. That single artifact (delta ≈ warp vector) is dropped.
    /// - Positions are useless as a motion source: after a warp, later events keep reporting stale or
    ///   partially-updated locations (jittery, wrong direction and distance).
    private func forwardMotion(_ e: CapturedEvent) {
        let t = now
        var dx = e.dx, dy = e.dy
        if let a = warpArtifact {
            if t > a.until {
                warpArtifact = nil
            } else if hypot(e.dx - a.dx, e.dy - a.dy) < hypot(e.dx, e.dy) {
                // macOS folded our warp into this event's delta: keep only the real motion. (Dropping the
                // whole event would also drop the hand's movement in it — noticeable now that the hidden
                // cursor stays attached and is re-centred regularly.)
                warpArtifact = nil
                dx = e.dx - a.dx
                dy = e.dy - a.dy
                if movesToLog > 0 {
                    effects?.log(String(format: "removed warp artifact %.1f,%.1f from delta %.1f,%.1f", a.dx, a.dy, e.dx, e.dy))
                }
            }
        }
        if abs(dx) >= 0.01 || abs(dy) >= 0.01 {
            send(.mouseMove(dx: dx, dy: dy))
            if movesToLog > 0 {
                movesToLog -= 1
                effects?.log(String(format: "forwarded move dx=%.1f dy=%.1f (at %.1f,%.1f; park %.0f,%.0f)",
                                    dx, dy, e.location.x, e.location.y, parkPoint.x, parkPoint.y))
            }
        }
        // The hidden cursor stays attached to the mouse (see SystemCursorControl.park) and wanders with it:
        // re-centre it well before it could reach a screen edge / hot corner, and expect that warp's delta
        // artifact in the next event.
        let drift = CGPoint(x: parkPoint.x - e.location.x, y: parkPoint.y - e.location.y)
        if hypot(drift.x, drift.y) > Self.recentreDistance {
            armWarpArtifact(dx: Double(drift.x), dy: Double(drift.y), at: t)
            effects?.keepCursorParked(at: parkPoint)
        }
    }

    /// How far the hidden, attached cursor may wander from the park point before it is warped back.
    static let recentreDistance: CGFloat = 200

    private func armWarpArtifact(dx: Double, dy: Double, at t: TimeInterval) {
        guard hypot(dx, dy) > 30 else { warpArtifact = nil; return } // too small to tell apart from real motion
        warpArtifact = (dx: dx, dy: dy, until: t + 0.3)
    }

    private func isSwitchHotKey(keyCode: UInt16, flags: UInt64) -> Bool {
        guard let hk = config.switchHotKey, hk.keyCode == keyCode else { return false }
        let relevant = flags & (CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue)
        return relevant == hk.modifiers
    }

    /// The spec's force-return combination ⌃⌥⌘←. Only used when no switch hotkey is configured, so that a
    /// cleared hotkey never leaves the user without a keyboard way back (it is not taken from the other
    /// Mac otherwise).
    public static let fallbackReturnKey: (keyCode: UInt16, modifiers: UInt64) =
        (123, CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue)

    private func isFallbackReturnKey(keyCode: UInt16, flags: UInt64) -> Bool {
        guard config.switchHotKey == nil, keyCode == Self.fallbackReturnKey.keyCode else { return false }
        let relevant = flags & (CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue)
        return relevant == Self.fallbackReturnKey.modifiers
    }

    // MARK: Switching

    /// Menu / hotkey: move control to the other Mac (cursor appears at its main display's centre).
    /// `location` is this Mac's current cursor position (used when the cursor has to stay where it is).
    @discardableResult
    public func switchToRemote(flags: UInt64 = 0, location: CGPoint? = nil) -> Bool {
        lock.withLock {
            guard mode == .local else { return false }
            enterRemote(fraction: 0.5, center: true, flags: flags, location: location, reason: "手动切换")
            return true
        }
    }

    /// Menu / hotkey / safety: take control back.
    public func returnToLocal(reason: String) {
        lock.withLock {
            guard mode == .remote else { return }
            leaveRemote(to: nil, reason: reason, notifyPeer: true)
        }
    }

    private func enterRemote(fraction: Double, center: Bool, flags: UInt64, location: CGPoint?, reason: String) {
        mode = .remote
        edgeSince = nil
        remoteKeys.removeAll()
        remoteButtons.removeAll()
        entryFlags = flags & (ModifierKeys.relevantMask | ModifierKeys.deviceMaskAll)
        entryKeys = ModifierKeys.heldModifierKeys(flags: entryFlags)
        // Normally the hidden cursor waits at the centre of the main display. Keep it where it is instead
        // when (a) a local button is still held — its mouse-up is delivered here at the parked position, and
        // releasing a Finder drag at the screen centre would drop files into whatever folder is there — or
        // (b) the cursor cannot be hidden (spec: park it at the edge instead).
        let keepInPlace = !heldButtons.isEmpty || !(effects?.canHideCursor ?? true)
        if keepInPlace, let location, !geometry.isEmpty {
            parkPoint = geometry.nearestPoint(to: location)
        } else {
            parkPoint = geometry.mainCenter
        }
        lastHeard = now
        lastReason = reason
        if let from = location {
            armWarpArtifact(dx: Double(parkPoint.x - from.x), dy: Double(parkPoint.y - from.y), at: now)
        } else {
            warpArtifact = nil
        }
        movesToLog = 3
        scrollsToLog = 3
        effects?.setKeyboardCapture(true)
        effects?.parkCursor(at: parkPoint)
        effects?.sendClipboardIfChanged()
        send(.enter(edge: config.clientSide.opposite, fraction: fraction, center: center, flags: entryFlags))
        publish()
    }

    private func leaveRemote(to fraction: Double?, reason: String, notifyPeer: Bool) {
        mode = .local
        // The cursor first: it is what the user watches for (warp + re-attach + show, applied at once on
        // this thread). Everything else — keyboard tap, peer notice, state publishing (status icon) and
        // clipboard work — is cheap here or deferred off this path by the effects.
        let point = fraction.map { geometry.entryPoint(on: config.clientSide, fraction: $0) } ?? parkPoint
        effects?.restoreCursor(at: point)
        effects?.setKeyboardCapture(false)
        if notifyPeer { send(.releaseAll) }
        remoteKeys.removeAll()
        remoteButtons.removeAll()
        entryFlags = 0
        entryKeys.removeAll()
        edgeSince = nil
        cooldownUntil = now + 0.25
        returnedAt = now
        returnTraceCount = 0
        lastReason = reason
        publish()
    }

    // MARK: Channel messages

    public func receive(_ message: InputMessage) {
        lock.withLock {
            lastHeard = now
            switch message {
            case .leave(let fraction):
                if mode == .remote {
                    leaveRemote(to: fraction, reason: "鼠标从另一台 Mac 返回", notifyPeer: false)
                }
            case .heartbeat(let seq, let sentAt, let isReply):
                if isReply {
                    rtt = max(0, now - sentAt)
                } else {
                    send(.heartbeat(seq: seq, sentAt: sentAt, isReply: true))
                }
            case .clipboard(let items):
                // The client lost control (it handed back, or we took control back) and sent its clipboard.
                effects?.applyClipboard(items)
            default:
                break
            }
        }
    }

    /// Called every ~0.5 s: heartbeat + timeout supervision + diagnostics.
    public func tick() {
        lock.withLock {
            let t = now
            heartbeatSeq &+= 1
            if mode != .offline {
                send(.heartbeat(seq: heartbeatSeq, sentAt: t, isReply: false))
            }
            if mode == .remote && t - lastHeard > config.heartbeatTimeout {
                leaveRemote(to: nil, reason: "对方无响应，已切回本机", notifyPeer: true)
            }
            if t - lastRateSample >= 1 {
                eventsPerSecond = Int(Double(eventCount) / max(t - lastRateSample, 0.001))
                eventCount = 0
                lastRateSample = t
                publish()
            }
        }
    }

    /// The event tap was disabled by the system (timeout / user input). Safety: take control back.
    public func tapWasDisabled() {
        lock.withLock {
            if mode == .remote { leaveRemote(to: nil, reason: "事件监听被系统中断，已切回本机", notifyPeer: true) }
        }
    }

    // MARK: Helpers

    private var now: TimeInterval { effects?.now() ?? ProcessInfo.processInfo.systemUptime }

    private func send(_ m: InputMessage) {
        if m.isInputEvent { eventCount += 1 }
        effects?.send(m)
    }

    private func makeSnapshot() -> Snapshot {
        Snapshot(mode: mode, lastReason: lastReason, rtt: rtt, eventsPerSecond: eventsPerSecond)
    }

    private func publish() {
        effects?.stateDidChange(makeSnapshot())
    }
}
