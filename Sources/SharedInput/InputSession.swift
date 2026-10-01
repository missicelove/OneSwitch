import AppKit
import Carbon.HIToolbox
import OneSwitchCore

/// Live state for the menu and settings page.
@MainActor
public final class InputStatusModel: ObservableObject {
    public enum Activity: Equatable, Sendable {
        /// Feature disabled.
        case inactive
        /// Enabled, no channel to the other Mac yet.
        case waitingForPeer
        /// Connected; this Mac has control (server) / waits to be controlled (client).
        case ready
        /// Server is controlling the other Mac.
        case controllingPeer
        /// Client is being controlled by the server.
        case controlledByPeer
    }

    @Published public internal(set) var activity: Activity = .inactive
    @Published public internal(set) var peerName: String?
    /// The layout configured on the server (shown on the client).
    @Published public internal(set) var serverClientSide: ScreenSide?
    /// The mouse-wheel settings of the server (shown on the client).
    @Published public internal(set) var serverWheel: WheelConfig?
    @Published public internal(set) var peerReady = false
    @Published public internal(set) var problem: String?
    @Published public internal(set) var lastReason: String?
    @Published public internal(set) var rtt: TimeInterval?
    @Published public internal(set) var eventsPerSecond = 0
    @Published public internal(set) var secureInputActive = false
    /// The switch hotkey could not be registered (taken by another app). Kept apart from `lastReason`,
    /// which every state update overwrites.
    @Published public internal(set) var hotKeyProblem: String?
    /// PeerLink status line ("已连接 …"), maintained by the module.
    @Published public internal(set) var linkStatus = ""

    public init() {}
}

/// Glue between one PeerChannel and the server / client state machine for the local role.
@MainActor
final class InputSession {
    let channel: PeerChannel
    private(set) var settings: InputSettings
    private let model: InputStatusModel
    private let clipboard: ClipboardSync
    private let queue = DispatchQueue(label: "oneswitch.input.session", qos: .userInteractive)
    /// Reassembles chunked clipboards (channel queue).
    private let inbox = ClipboardInbox()
    /// Sends this Mac's clipboard (paced pieces for large ones).
    private let clipboardSender: ClipboardSender
    /// Runtimes are read from the channel queue for every input event, so they live behind a lock
    /// instead of requiring a hop to the main thread.
    private let box = RuntimeBox()
    private var server: ServerRuntime? {
        get { box.server }
        set { box.server = newValue }
    }
    private var client: ClientRuntime? {
        get { box.client }
        set { box.client = newValue }
    }
    private var heartbeat: DispatchSourceTimer?
    private var maintenance: Timer?
    private var peerHello: InputHello?
    private var lastSentHello: InputHello?
    private var closed = false
    /// Keeps App Nap / timer coalescing away while connected: this is a background (menu-bar) app, and a
    /// napped heartbeat timer makes the other side time out — or delays every forwarded event.
    private var activity: NSObjectProtocol?
    /// This Mac's name for the hello (from the PeerHub; `Host.current()` can block on name resolution).
    private let localName: String
    var onClosed: (() -> Void)?

    init(channel: PeerChannel, settings: InputSettings, model: InputStatusModel, clipboard: ClipboardSync,
         localName: String) {
        self.channel = channel
        self.settings = settings
        self.model = model
        self.clipboard = clipboard
        self.localName = localName
        clipboardSender = ClipboardSender { [channel] type, payload, completion in
            channel.send(type: type, payload: payload, completion: completion)
        }
    }

    func start() {
        model.peerName = channel.peer.name
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "键鼠共享")
        buildRuntime()
        let box = self.box
        let inbox = self.inbox
        channel.setHandlers(queue: queue, onMessage: { [weak self] type, payload in
            InputSession.route(type: type, payload: payload, inbox: inbox, hello: { hello in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.peerHelloReceived(hello) } }
            }, deliver: { message in
                box.server?.core.receive(message)
                box.client?.core.receive(message)
            })
        }, onClose: { [weak self] error in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.channelClosed(error) } }
        })
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
        timer.setEventHandler {
            box.server?.core.tick()
            box.client?.core.tick()
            inbox.expire()
        }
        timer.resume()
        heartbeat = timer
        maintenance = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.maintain() }
        }
        sendHello()
        AppLog.info("input", "session started with \(channel.peer.name) as \(settings.role.rawValue)")
    }

    func close() {
        guard !closed else { return }
        closed = true
        teardownRuntime(reason: "已断开")
        heartbeat?.cancel()
        heartbeat = nil
        maintenance?.invalidate()
        maintenance = nil
        channel.close()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: Settings / environment changes

    func apply(settings newValue: InputSettings) {
        let roleChanged = newValue.role != settings.role
        settings = newValue
        if roleChanged {
            teardownRuntime(reason: "角色已更改")
            buildRuntime()
        } else {
            server?.core.update(config: Self.serverConfig(from: newValue))
        }
        sendHello()
        evaluateReadiness()
    }

    func updateGeometry() {
        let geometry = SystemScreens.current()
        server?.core.update(geometry: geometry)
        client?.core.update(geometry: geometry)
    }

    /// Hotkey / menu: move control to the other Mac, or take it back.
    func toggleControl() {
        guard let server else { return }
        switch server.core.currentMode {
        case .local:
            server.core.switchToRemote(flags: CGEventSource.flagsState(.combinedSessionState).rawValue,
                                       location: CGEvent(source: nil)?.location)
        case .remote:
            server.core.returnToLocal(reason: "手动切回本机")
        case .offline:
            NSSound.beep()
        }
    }

    /// Safety: e.g. this Mac's screen locked or went to sleep.
    func forceReturn(reason: String) {
        server?.core.returnToLocal(reason: reason)
    }

    var isServerControllingPeer: Bool { server?.core.currentMode == .remote }
    var canSwitch: Bool { server.map { $0.core.currentMode != .offline } ?? false }

    // MARK: Runtime

    private func buildRuntime() {
        let geometry = SystemScreens.current()
        // Both roles hide the cursor at times (server while it controls the other Mac, client after handing
        // control back): set the private background-cursor property now, before the first hide.
        SystemCursorControl.prepare()
        switch settings.role {
        case .server:
            let runtime = ServerRuntime(channel: channel, geometry: geometry, config: Self.serverConfig(from: settings))
            runtime.onState = { [weak self] snapshot in MainActor.assumeIsolated { self?.serverStateChanged(snapshot) } }
            runtime.onClipboardNeeded = { [weak self] in MainActor.assumeIsolated { self?.sendClipboard() } }
            runtime.onClipboardReceived = { [weak self] items in MainActor.assumeIsolated { self?.receiveClipboard(items) } }
            server = runtime
            _ = runtime.startTapIfPossible()
        case .client:
            let runtime = ClientRuntime(channel: channel, geometry: geometry)
            runtime.onState = { [weak self] snapshot in MainActor.assumeIsolated { self?.clientStateChanged(snapshot) } }
            runtime.onClipboardNeeded = { [weak self] in MainActor.assumeIsolated { self?.sendClipboard() } }
            runtime.onClipboardReceived = { [weak self] items in MainActor.assumeIsolated { self?.receiveClipboard(items) } }
            if let hello = peerHello, hello.role == .server {
                runtime.core.update(wheel: hello.wheel ?? WheelConfig())
            }
            client = runtime
        }
        model.activity = .ready
        evaluateReadiness()
    }

    private func teardownRuntime(reason: String) {
        if let server {
            server.core.setPeerReady(false, reason: reason)
            server.stopTap()
        }
        client?.core.peerDisconnected()
        server = nil
        client = nil
    }

    private static func serverConfig(from s: InputSettings) -> ServerCore.Config {
        var c = ServerCore.Config()
        c.clientSide = s.clientSide
        c.dwell = Double(s.dwellMilliseconds) / 1000
        c.requiredModifierMask = s.requiredModifier.flagMask
        c.blockWhileButtonHeld = s.blockWhileButtonHeld
        c.switchHotKey = s.switchHotKey.map { (UInt16($0.keyCode), ModifierKeys.cgMask(fromHotKeyModifiers: $0.modifiers)) }
        c.wheelDirection = s.wheelDirection
        return c
    }

    // MARK: Messages

    /// Runs on the channel queue: input events go straight to the state machine (no main-thread hop).
    /// Hellos go to `hello`; pieces of a large clipboard are collected in `inbox` and delivered as one
    /// `.clipboard` once complete (from the inbox queue); everything else is delivered as is, right here.
    nonisolated static func route(type: UInt16, payload: Data, inbox: ClipboardInbox,
                                  hello: (InputHello) -> Void, deliver: @escaping @Sendable (InputMessage) -> Void) {
        let message: InputMessage
        do {
            message = try InputMessage.decode(type: type, payload: payload)
        } catch {
            AppLog.warning("input", "undecodable message type \(type): \(error)")
            return
        }
        if case .hello(let h) = message {
            hello(h)
            return
        }
        if case .clipboardChunk(let chunk) = message {
            // Pieces of a large clipboard: collected off this queue; the whole clipboard is delivered (from
            // the inbox queue) once the last piece arrived.
            inbox.add(chunk) { items in deliver(.clipboard(items)) }
            return
        }
        deliver(message)
    }

    private func peerHelloReceived(_ hello: InputHello) {
        peerHello = hello
        model.peerName = hello.deviceName
        model.serverClientSide = hello.role == .server ? hello.clientSide : nil
        model.serverWheel = hello.role == .server ? (hello.wheel ?? WheelConfig()) : nil
        if hello.role == .server {
            client?.core.update(wheel: hello.wheel ?? WheelConfig())
        }
        evaluateReadiness()
    }

    private func sendHello() {
        let ready: Bool
        switch settings.role {
        case .server: ready = server?.isTapRunning ?? false
        case .client: ready = Permissions.isGranted(.accessibility)
        }
        let hello = InputHello(role: settings.role,
                               deviceName: localName,
                               ready: ready,
                               clientSide: settings.clientSide,
                               wheel: settings.role == .server ? settings.wheelConfig : nil)
        lastSentHello = hello
        let (type, payload) = InputMessage.hello(hello).encode()
        channel.send(type: type, payload: payload)
    }

    /// Decides whether switching is possible and surfaces problems in the UI.
    private func evaluateReadiness() {
        let result = InputReadiness.evaluate(localRole: settings.role,
                                             tapRunning: server?.isTapRunning ?? false,
                                             canInject: Permissions.isGranted(.accessibility),
                                             peer: peerHello)
        model.problem = result.problem
        model.peerReady = result.ready
        server?.core.setPeerReady(result.ready, reason: result.problem)
    }

    /// Every 2 s on main: retry the event tap after permissions are granted, refresh hello, secure input.
    private func maintain() {
        if let server, server.isTapRunning, !server.isTapHealthy {
            // The system invalidated or disabled the tap without telling our callback (e.g. permission
            // revoked): take control back and rebuild it below.
            AppLog.warning("input", "event tap no longer healthy; restarting")
            server.core.returnToLocal(reason: "事件监听失效，已切回本机")
            server.stopTap()
        }
        if let server, !server.isTapRunning, Permissions.isGranted(.accessibility) {
            if server.startTapIfPossible() { AppLog.info("input", "event tap started after permission grant") }
        }
        let expectedReady = settings.role == .server ? (server?.isTapRunning ?? false) : Permissions.isGranted(.accessibility)
        if lastSentHello?.ready != expectedReady { sendHello() }
        evaluateReadiness()
        model.secureInputActive = settings.role == .server && IsSecureEventInputEnabled()
    }

    // MARK: State from runtimes (main)

    private var lastLoggedServerMode: ServerCore.Mode?
    private var lastLoggedClientMode: ClientCore.Mode?

    private func serverStateChanged(_ s: ServerCore.Snapshot) {
        if s.mode != lastLoggedServerMode {
            AppLog.info("input", "server mode \(lastLoggedServerMode.map { "\($0)" } ?? "-") → \(s.mode)\(s.lastReason.map { "（\($0)）" } ?? "")")
            lastLoggedServerMode = s.mode
        }
        switch s.mode {
        case .offline: model.activity = .ready
        case .local: model.activity = .ready
        case .remote: model.activity = .controllingPeer
        }
        model.lastReason = s.lastReason
        model.rtt = s.rtt
        model.eventsPerSecond = s.eventsPerSecond
        // One more runloop turn: redrawing the status item is never on the switching path.
        DispatchQueue.main.async { MainActor.assumeIsolated { AppContext.shared.refreshStatusIcon() } }
    }

    private func clientStateChanged(_ s: ClientCore.Snapshot) {
        if s.mode != lastLoggedClientMode {
            AppLog.info("input", "client mode \(lastLoggedClientMode.map { "\($0)" } ?? "-") → \(s.mode)")
            lastLoggedClientMode = s.mode
        }
        model.activity = s.mode == .controlled ? .controlledByPeer : .ready
        model.rtt = s.rtt
        model.eventsPerSecond = s.eventsPerSecond
    }

    /// This Mac lost control: offer its clipboard. Deferred by a runloop turn (the switch itself goes
    /// first); encoding and the paced transfer run off the main thread.
    private func sendClipboard() {
        guard settings.clipboardSync else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.closed, self.settings.clipboardSync,
                      let items = self.clipboard.snapshotIfChanged() else { return }
                let chunked = self.peerHello?.supports(InputFeature.clipboardChunks) ?? false
                let sender = self.clipboardSender
                let clipboard = self.clipboard
                let change = clipboard.syncedChange
                DispatchQueue.global(qos: .utility).async {
                    AppLog.info("input", sender.send(items, chunked: chunked) { outcome in
                        // The link broke mid-transfer (e.g. the other Mac disconnected): offer it again next
                        // time. Superseded / too large: nothing to retry.
                        guard outcome == .failed else { return }
                        DispatchQueue.main.async { MainActor.assumeIsolated { clipboard.markUnsent(changeCount: change) } }
                    })
                }
            }
        }
    }

    /// Main, `ClipboardLimits.applyDelay` after the clipboard arrived.
    private func receiveClipboard(_ items: [ClipboardItem]) {
        guard settings.clipboardSync else {
            AppLog.info("input", "clipboard received but 剪贴板同步 is off here; ignored")
            return
        }
        clipboard.apply(items)
    }

    private func channelClosed(_ error: Error?) {
        AppLog.info("input", "channel closed\(error.map { ": \($0.localizedDescription)" } ?? "")")
        // Already closed by the module (disabled, stopped, or replaced by a newer channel): the shared model
        // may belong to the newer session by now, so leave it alone.
        let wasOpen = !closed
        close()
        if wasOpen { model.peerReady = false }
        onClosed?()
    }
}

/// Pure readiness rules (role conflict, versions, permissions on either side).
enum InputReadiness {
    static func evaluate(localRole: InputRole, tapRunning: Bool, canInject: Bool, peer: InputHello?) -> (ready: Bool, problem: String?) {
        guard let peer else { return (false, nil) }
        if peer.version != InputHello.currentVersion {
            return (false, "两台 Mac 上的 OneSwitch 版本不一致，请更新到同一版本")
        }
        if peer.role == localRole {
            let other = localRole == .server ? "客户端" : "服务端"
            return (false, "两台 Mac 的角色设置冲突：都设成了“\(localRole.shortTitle)”。请把其中一台改为\(other)")
        }
        switch localRole {
        case .server:
            if !tapRunning { return (false, "本机需要“辅助功能”和“输入监控”权限才能共享键盘鼠标") }
            if !peer.ready { return (false, "\(peer.deviceName) 尚未授予 OneSwitch “辅助功能”权限，暂时无法控制它") }
            return (true, nil)
        case .client:
            if !canInject { return (false, "本机需要“辅助功能”权限才能被另一台 Mac 控制") }
            return (true, nil)
        }
    }
}

/// Lock-protected holder for the active runtime (read on the channel queue, written on main).
final class RuntimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _server: ServerRuntime?
    private var _client: ClientRuntime?

    var server: ServerRuntime? {
        get { lock.withLock { _server } }
        set { lock.withLock { _server = newValue } }
    }

    var client: ClientRuntime? {
        get { lock.withLock { _client } }
        set { lock.withLock { _client = newValue } }
    }
}

// MARK: - Server runtime

/// Real side effects for the server: event tap, cursor, channel.
final class ServerRuntime: ServerEffects, @unchecked Sendable {
    private(set) var core: ServerCore!
    private let channel: PeerChannel
    private let cursor = SystemCursorControl()
    private var tap: EventTapRunner?
    private let lock = NSLock()
    /// Invoked on the main queue.
    var onState: ((ServerCore.Snapshot) -> Void)?
    var onClipboardNeeded: (() -> Void)?
    var onClipboardReceived: (([ClipboardItem]) -> Void)?

    /// Resolved on the main thread (`init` runs there) before the tap thread can ask.
    let canHideCursor: Bool

    init(channel: PeerChannel, geometry: ScreenGeometry, config: ServerCore.Config) {
        self.channel = channel
        canHideCursor = SystemCursorControl.canHideCursor
        core = ServerCore(geometry: geometry, config: config, effects: self)
    }

    var isTapRunning: Bool { lock.withLock { tap != nil } }

    var isTapHealthy: Bool {
        let runner = lock.withLock { tap }
        return runner?.isHealthy ?? false
    }

    @MainActor
    func startTapIfPossible() -> Bool {
        if isTapRunning { return true }
        guard Permissions.isGranted(.accessibility) else { return false }
        let runner = EventTapRunner(core: core)
        guard runner.start() else { return false }
        lock.withLock { tap = runner }
        return true
    }

    func stopTap() {
        let runner: EventTapRunner? = lock.withLock {
            let t = tap
            tap = nil
            return t
        }
        runner?.stop()
    }

    func send(_ message: InputMessage) {
        let (type, payload) = message.encode()
        channel.send(type: type, payload: payload)
    }

    func parkCursor(at point: CGPoint) { cursor.park(at: point) }
    /// Per-switch diagnostics (first moves, scroll samples, return trace): only with 详细日志 on.
    func log(_ line: String) { AppLog.debug("input", line) }
    func keepCursorParked(at point: CGPoint) { cursor.keepParked(at: point) }
    func restoreCursor(at point: CGPoint) {
        let start = ProcessInfo.processInfo.systemUptime
        cursor.restore(at: point)
        AppLog.debug("input", String(format: "server cursor restored at %.0f,%.0f in %.2f ms (place + show on the calling thread)",
                                    point.x, point.y, (ProcessInfo.processInfo.systemUptime - start) * 1000))
    }

    func setKeyboardCapture(_ enabled: Bool) {
        let runner = lock.withLock { tap }
        runner?.setKeyboardCapture(enabled)
    }

    func sendClipboardIfChanged() {
        DispatchQueue.main.async { [weak self] in self?.onClipboardNeeded?() }
    }

    func applyClipboard(_ items: [ClipboardItem]) {
        AppLog.info("input", "clipboard received: \(ClipboardSender.describe(items))")
        DispatchQueue.main.asyncAfter(deadline: .now() + ClipboardLimits.applyDelay) { [weak self] in
            self?.onClipboardReceived?(items)
        }
    }

    func stateDidChange(_ snapshot: ServerCore.Snapshot) {
        DispatchQueue.main.async { [weak self] in self?.onState?(snapshot) }
    }

    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}

// MARK: - Client runtime

final class ClientRuntime: ClientEffects, @unchecked Sendable {
    private(set) var core: ClientCore!
    private let channel: PeerChannel
    private let injector = SystemEventInjector()
    /// Invoked on the main queue.
    var onState: ((ClientCore.Snapshot) -> Void)?
    var onClipboardNeeded: (() -> Void)?
    var onClipboardReceived: (([ClipboardItem]) -> Void)?

    init(channel: PeerChannel, geometry: ScreenGeometry) {
        self.channel = channel
        core = ClientCore(geometry: geometry, injector: injector, effects: self)
    }

    /// Per-switch diagnostics (first moves, scroll samples, return trace): only with 详细日志 on.
    func log(_ line: String) { AppLog.debug("input", line) }

    func currentGeometry() -> ScreenGeometry? { SystemScreens.current() }

    func send(_ message: InputMessage) {
        let (type, payload) = message.encode()
        channel.send(type: type, payload: payload)
    }

    func sendClipboardIfChanged() {
        DispatchQueue.main.async { [weak self] in self?.onClipboardNeeded?() }
    }

    func applyClipboard(_ items: [ClipboardItem]) {
        AppLog.info("input", "clipboard received: \(ClipboardSender.describe(items))")
        DispatchQueue.main.asyncAfter(deadline: .now() + ClipboardLimits.applyDelay) { [weak self] in
            self?.onClipboardReceived?(items)
        }
    }

    func stateDidChange(_ snapshot: ClientCore.Snapshot) {
        DispatchQueue.main.async { [weak self] in self?.onState?(snapshot) }
    }

    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
}
