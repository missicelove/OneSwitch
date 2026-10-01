import Foundation
import Network
import os
import OneSwitchCore

/// Who we are on the wire.
struct LocalIdentity: Sendable, Equatable {
    let deviceID: String
    let deviceName: String
    /// Random per engine start (lets the peer detect restarts).
    let instanceID: String
}

/// Live counters of one channel (read from the main actor for the settings page).
struct ChannelStats: Sendable, Equatable {
    var bytesIn: Int64 = 0
    var bytesOut: Int64 = 0
    var messagesIn: Int64 = 0
    var messagesOut: Int64 = 0
    var rtt: TimeInterval?
    var smoothedRTT: TimeInterval?
    var establishedAt: Date?
}

/// One TCP + TLS-PSK connection carrying one service: handshake, framing, heartbeat, buffering, and —
/// once established and handed out — the `PeerChannel` a service talks to.
///
/// Threading: every piece of mutable state below the `// ioQueue-confined` marker is only touched on
/// `ioQueue` (the NWConnection's queue). State read from other threads lives in `shared` (a lock).
/// The public API (`send`, `setHandlers`, `close`) is thread-safe and never blocks.
final class NetworkPeerChannel: PeerChannel, @unchecked Sendable, CustomStringConvertible {
    enum Role: String, Sendable { case dialer, acceptor }

    enum Phase: String {
        case connecting        // TCP / TLS in progress
        case transportReady    // TLS done; dialer waits for the engine, acceptor waits for hello
        case helloSent         // dialer: waiting for helloAck / reject
        case awaitingDecision  // acceptor: hello received; dialer: ack received — engine decides on main
        case established
        case closed
    }

    struct CloseInfo: Sendable {
        var error: PeerLinkError?
        var failure: LinkFailure?
        var wasEstablished: Bool
        var phase: String
    }

    /// Engine callbacks, invoked on `ioQueue` (implementations hop to the main actor).
    struct Events: Sendable {
        var transportReady: @Sendable (NetworkPeerChannel) -> Void
        var helloReceived: @Sendable (NetworkPeerChannel, HelloMessage) -> Void
        var ackReceived: @Sendable (NetworkPeerChannel, HelloAckMessage) -> Void
        var rejectReceived: @Sendable (NetworkPeerChannel, RejectMessage) -> Void
        var closed: @Sendable (NetworkPeerChannel, CloseInfo) -> Void
    }

    private struct Shared {
        var service: String
        var channelID: String
        var peer: PeerInfo
        var peerInstanceID = ""
        var interfaceName: String?
        var interfaceType: NWInterface.InterfaceType?
        var open = true
        var handedOut = false
        var stats = ChannelStats()
        var inflightBytes = 0
        var receivePaused = false
    }

    private enum CloseDelivery {
        case none
        case pending(Error?)
        case delivered
    }

    /// Receive-side back-pressure: stop reading from the socket while this many bytes are queued for a
    /// slow (or not yet attached) service handler; resume below `lowWater`.
    static let highWater = 48 << 20
    static let lowWater = 16 << 20
    /// Frames up to this size are sent as one buffer; larger payloads go out as header + payload.
    private static let coalesceLimit = 64 << 10

    let role: Role
    let identity: LocalIdentity
    private let connection: NWConnection
    private let ioQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let timing: PeerLinkTiming
    private let thunderboltOnly: Bool
    private let events: Events
    private let shared: OSAllocatedUnfairLock<Shared>

    // ioQueue-confined
    private var phase: Phase = .connecting
    private var decoder = FrameDecoder()
    private var receiveInFlight = false
    private var handlerQueue: DispatchQueue?
    private var onMessage: (@Sendable (UInt16, Data) -> Void)?
    private var onClose: (@Sendable (Error?) -> Void)?
    private var pending: [(UInt16, Data)] = []
    private var closeDelivery = CloseDelivery.none
    private var handshakeTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastReceived = DispatchTime.now()

    init(role: Role,
         connection: NWConnection,
         service: String,
         channelID: String,
         identity: LocalIdentity,
         timing: PeerLinkTiming,
         thunderboltOnly: Bool,
         events: Events) {
        self.role = role
        self.connection = connection
        self.identity = identity
        self.timing = timing
        self.thunderboltOnly = thunderboltOnly
        self.events = events
        let label = "oneswitch.peerlink.\(role.rawValue).\(service.isEmpty ? "incoming" : service)"
        self.ioQueue = DispatchQueue(label: label, qos: .userInteractive)
        self.callbackQueue = DispatchQueue(label: label + ".callbacks", qos: .userInitiated)
        self.shared = OSAllocatedUnfairLock(initialState: Shared(
            service: service, channelID: channelID,
            peer: PeerInfo(deviceID: "", name: "")))
    }

    deinit {
        handshakeTimer?.cancel()
        heartbeatTimer?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    // MARK: PeerChannel

    var service: String { shared.withLock { $0.service } }
    var peer: PeerInfo { shared.withLock { $0.peer } }
    var isOpen: Bool { shared.withLock { $0.open } }

    var channelID: String { shared.withLock { $0.channelID } }
    var peerInstanceID: String { shared.withLock { $0.peerInstanceID } }
    var initiatedLocally: Bool { role == .dialer }
    var stats: ChannelStats { shared.withLock { $0.stats } }

    /// "雷雳" / "Wi‑Fi" / "有线网络" / "本机回环" / "网络".
    var linkKind: String {
        let (name, type) = shared.withLock { ($0.interfaceName, $0.interfaceType) }
        if let name, ThunderboltBridge.isThunderboltInterface(name) { return "雷雳" }
        switch type {
        case .wifi?: return "Wi‑Fi"
        case .wiredEthernet?: return "有线网络"
        case .loopback?: return "本机回环"
        default: return "网络"
        }
    }

    var description: String {
        let s = shared.withLock { "\($0.service.isEmpty ? "?" : $0.service)#\($0.channelID.prefix(8))" }
        return "\(role.rawValue)(\(s))"
    }

    func setHandlers(queue: DispatchQueue,
                     onMessage: @escaping @Sendable (UInt16, Data) -> Void,
                     onClose: @escaping @Sendable (Error?) -> Void) {
        ioQueue.async { [self] in
            if case .delivered = closeDelivery { return }
            handlerQueue = queue
            self.onMessage = onMessage
            self.onClose = onClose
            let buffered = pending
            pending.removeAll()
            for (type, payload) in buffered { enqueueDelivery(type: type, payload: payload, queue: queue, handler: onMessage) }
            if case .pending(let error) = closeDelivery { deliverClose(error) }
        }
    }

    func send(type: UInt16, payload: Data, completion: (@Sendable (Error?) -> Void)?) {
        if payload.count > PeerLimits.maxPayloadSize {
            complete(completion, PeerLinkError.payloadTooLarge(payload.count))
            return
        }
        guard PeerLimits.serviceTypeRange.contains(type) else {
            complete(completion, PeerLinkError.protocolViolation(String(format: "消息类型 0x%04X 为保留类型", type)))
            return
        }
        guard isOpen else {
            complete(completion, PeerLinkError.closed)
            return
        }
        ioQueue.async { [self] in
            guard phase == .established else {
                complete(completion, PeerLinkError.closed)
                return
            }
            shared.withLock { $0.stats.messagesOut += 1 }
            writeFrame(type: type, payload: payload, completion: completion)
        }
    }

    func close() {
        close(error: nil)
    }

    // MARK: Engine API (thread-safe; work happens on ioQueue)

    func start() {
        ioQueue.async { [self] in
            connection.stateUpdateHandler = { [weak self] state in self?.handleState(state) }
            let timer = DispatchSource.makeTimerSource(queue: ioQueue)
            timer.schedule(deadline: .now() + timing.handshakeTimeout)
            timer.setEventHandler { [weak self] in
                guard let self, self.phase != .established, self.phase != .closed else { return }
                self.finish(error: .timeout, failure: .timeout, farewell: nil)
            }
            timer.resume()
            handshakeTimer = timer
            connection.start(queue: ioQueue)
        }
    }

    /// Dialer: the engine allowed the attempt → send hello.
    func sendHello(_ hello: HelloMessage) {
        ioQueue.async { [self] in
            guard phase == .transportReady else { return }
            phase = .helloSent
            writeFrame(type: WireType.hello, payload: Wire.encode(hello), completion: nil)
        }
    }

    /// Acceptor: the engine accepted the hello → ack and become established.
    func acceptIncoming(_ ack: HelloAckMessage) {
        ioQueue.async { [self] in
            guard phase == .awaitingDecision else { return }
            writeFrame(type: WireType.helloAck, payload: Wire.encode(ack), completion: nil)
            becomeEstablished()
        }
    }

    /// Acceptor: the engine rejected the hello → send the reason, then close.
    func rejectIncoming(_ reject: RejectMessage) {
        ioQueue.async { [self] in
            guard phase == .awaitingDecision || phase == .transportReady else { return }
            finish(error: nil, failure: nil, farewell: Wire.frame(type: WireType.reject, payload: Wire.encode(reject)))
        }
    }

    /// Dialer: the engine accepted the ack → established.
    func confirmEstablished() {
        ioQueue.async { [self] in
            guard phase == .awaitingDecision else { return }
            becomeEstablished()
        }
    }

    /// Atomically marks the channel as handed to a service. Returns false if it already closed; then
    /// it must not be handed out. After a successful claim `onClose` is guaranteed to be delivered.
    func claimForHandout() -> Bool {
        shared.withLock { s in
            guard s.open else { return false }
            s.handedOut = true
            return true
        }
    }

    /// Closes the channel; `error` is what the local `onClose` receives (nil for a deliberate close).
    func close(error: PeerLinkError?) {
        shared.withLock { $0.open = false }
        ioQueue.async { [self] in
            finish(error: error, failure: nil, farewell: Wire.frame(type: WireType.goodbye, payload: Data()))
        }
    }

    /// Test hook: writes a frame of any type (including reserved ones) bypassing the service checks.
    func sendRawFrameForTesting(type: UInt16, payload: Data) {
        ioQueue.async { [self] in
            guard phase == .established else { return }
            writeFrame(type: type, payload: payload, completion: nil)
        }
    }

    /// Test hook: writes arbitrary bytes (e.g. a header announcing an oversized payload).
    func sendRawBytesForTesting(_ bytes: Data) {
        ioQueue.async { [self] in
            guard phase == .established else { return }
            connection.send(content: bytes, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Connection state (ioQueue)

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard phase == .connecting else { return }
            capturePath()
            if thunderboltOnly {
                let name = shared.withLock { $0.interfaceName }
                if !(name.map(ThunderboltBridge.isThunderboltInterface) ?? false) {
                    finish(error: .network("连接未经过雷雳网桥"), failure: .notThunderbolt, farewell: nil)
                    return
                }
            }
            phase = .transportReady
            scheduleReceive()
            if role == .dialer { events.transportReady(self) }
        case .waiting(let error), .failed(let error):
            let failure = LinkFailure.classify(error, unsatisfiedReason: connection.currentPath?.unsatisfiedReason)
            finish(error: failure.peerLinkError, failure: failure, farewell: nil)
        case .cancelled:
            finish(error: .closed, failure: nil, farewell: nil)
        default:
            break
        }
    }

    private func capturePath() {
        let path = connection.currentPath
        let iface = path?.availableInterfaces.first
        let remote: NWEndpoint? = role == .acceptor ? connection.endpoint : (path?.remoteEndpoint ?? connection.endpoint)
        let address = remote.flatMap(Self.hostString)
        let via = iface.map { ThunderboltBridge.isThunderboltInterface($0.name) } ?? false
        shared.withLock { s in
            s.interfaceName = iface?.name
            s.interfaceType = iface?.type
            s.peer.address = address
            s.peer.viaThunderbolt = via
        }
    }

    static func hostString(_ endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        var text: String
        switch host {
        case .ipv4(let a): text = "\(a)"
        case .ipv6(let a): text = "\(a)"
        case .name(let n, _): text = n
        @unknown default: text = "\(host)"
        }
        if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
        return text
    }

    // MARK: - Receive (ioQueue)

    private func scheduleReceive() {
        guard phase != .closed, phase != .connecting, !receiveInFlight else { return }
        if shared.withLock({ $0.receivePaused }) { return }
        receiveInFlight = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: decoder.preferredReceiveLength) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.receiveInFlight = false
            guard self.phase != .closed else { return }
            if let data, !data.isEmpty {
                self.lastReceived = .now()
                self.shared.withLock { $0.stats.bytesIn += Int64(data.count) }
                do {
                    try self.decoder.feed(data) { type, payload in self.handleFrame(type: type, payload: payload) }
                } catch FrameDecodingError.payloadTooLarge(let n) {
                    self.protocolViolation("消息过大（\(n) 字节）")
                    return
                } catch {
                    self.protocolViolation("无法解析数据")
                    return
                }
            }
            guard self.phase != .closed else { return }
            if let error {
                let failure = LinkFailure.classify(error)
                self.finish(error: failure.peerLinkError, failure: failure, farewell: nil)
                return
            }
            if isComplete {
                self.finish(error: .closedByPeer, failure: nil, farewell: nil)
                return
            }
            self.scheduleReceive()
        }
    }

    private func handleFrame(type: UInt16, payload: Data) {
        switch phase {
        case .closed, .connecting:
            return
        case .transportReady:
            guard role == .acceptor, type == WireType.hello else {
                return protocolViolation(String(format: "握手前收到意外消息 0x%04X", type))
            }
            guard let hello = Wire.decode(HelloMessage.self, from: payload), !hello.service.isEmpty else {
                return protocolViolation("无效的握手消息")
            }
            shared.withLock { s in
                s.service = hello.service
                s.channelID = hello.channelID
                s.peerInstanceID = hello.instanceID
                s.peer.deviceID = hello.deviceID
                s.peer.name = hello.deviceName
            }
            phase = .awaitingDecision
            events.helloReceived(self, hello)
        case .helloSent:
            if type == WireType.helloAck {
                guard let ack = Wire.decode(HelloAckMessage.self, from: payload) else {
                    return protocolViolation("无效的握手应答")
                }
                let (service, channelID) = shared.withLock { ($0.service, $0.channelID) }
                guard ack.service == service, ack.channelID == channelID else {
                    return protocolViolation("握手应答与请求不一致")
                }
                shared.withLock { s in
                    s.peerInstanceID = ack.instanceID
                    s.peer.deviceID = ack.deviceID
                    s.peer.name = ack.deviceName
                }
                phase = .awaitingDecision
                events.ackReceived(self, ack)
            } else if type == WireType.reject {
                let reject = Wire.decode(RejectMessage.self, from: payload)
                    ?? RejectMessage(protocolVersion: 0, deviceID: "", deviceName: "",
                                     reason: RejectReason.protocolMismatch.rawValue, detail: nil)
                events.rejectReceived(self, reject)
                finish(error: nil, failure: nil, farewell: nil)
            } else if type == WireType.goodbye {
                finish(error: .closedByPeer, failure: nil, farewell: nil)
            } else {
                protocolViolation(String(format: "握手期间收到意外消息 0x%04X", type))
            }
        case .awaitingDecision, .established:
            handleSessionFrame(type: type, payload: payload)
        }
    }

    private func handleSessionFrame(type: UInt16, payload: Data) {
        guard WireType.isReserved(type) else {
            deliver(type: type, payload: payload)
            return
        }
        switch type {
        case WireType.ping:
            writeFrame(type: WireType.pong, payload: payload, completion: nil)
        case WireType.pong:
            guard payload.count == 8 else { return }
            let sent = payload.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= sent else { return }
            let rtt = TimeInterval(now - sent) / 1e9
            shared.withLock { s in
                s.stats.rtt = rtt
                s.stats.smoothedRTT = s.stats.smoothedRTT.map { $0 * 0.8 + rtt * 0.2 } ?? rtt
            }
        case WireType.goodbye:
            finish(error: .closedByPeer, failure: nil, farewell: nil)
        default:
            // Unknown / misplaced reserved frame (e.g. a newer peer's extension): never surfaced to services.
            AppLog.debug("peerlink", "\(self) ignoring reserved frame 0x\(String(type, radix: 16))")
        }
    }

    private func deliver(type: UInt16, payload: Data) {
        shared.withLock { s in
            s.stats.messagesIn += 1
            s.inflightBytes += payload.count
            if s.inflightBytes > Self.highWater { s.receivePaused = true }
        }
        if let queue = handlerQueue, let handler = onMessage {
            enqueueDelivery(type: type, payload: payload, queue: queue, handler: handler)
        } else {
            pending.append((type, payload))
        }
    }

    private func enqueueDelivery(type: UInt16, payload: Data, queue: DispatchQueue, handler: @escaping @Sendable (UInt16, Data) -> Void) {
        let size = payload.count
        queue.async { [self] in
            handler(type, payload)
            consumed(size)
        }
    }

    /// Called on the handler queue after a message was processed.
    private func consumed(_ size: Int) {
        let resume = shared.withLock { s -> Bool in
            s.inflightBytes -= size
            if s.receivePaused && s.inflightBytes <= Self.lowWater {
                s.receivePaused = false
                return true
            }
            return false
        }
        if resume {
            ioQueue.async { [self] in
                lastReceived = .now()   // time spent paused is not silence
                scheduleReceive()
            }
        }
    }

    private func deliverClose(_ error: Error?) {
        if case .delivered = closeDelivery { return }
        guard let queue = handlerQueue, let handler = onClose else {
            closeDelivery = .pending(error)
            return
        }
        closeDelivery = .delivered
        queue.async { handler(error) }
        // Break reference cycles between the service's closures and this channel.
        onMessage = nil
        onClose = nil
    }

    // MARK: - Send (ioQueue)

    private func writeFrame(type: UInt16, payload: Data, completion: (@Sendable (Error?) -> Void)?) {
        let total = Wire.headerSize + payload.count
        shared.withLock { $0.stats.bytesOut += Int64(total) }
        let done: NWConnection.SendCompletion = .contentProcessed { [weak self] error in
            guard let completion else { return }
            guard let self else {
                completion(error == nil ? nil : PeerLinkError.closed)
                return
            }
            self.complete(completion, error.map { self.mapSendError($0) })
        }
        if payload.count <= Self.coalesceLimit {
            connection.send(content: Wire.frame(type: type, payload: payload), completion: done)
        } else {
            connection.send(content: Wire.header(type: type, length: payload.count), completion: .contentProcessed { _ in })
            connection.send(content: payload, completion: done)
        }
    }

    private func mapSendError(_ error: NWError) -> PeerLinkError {
        if case .posix(.ECANCELED) = error { return .closed }
        if phase == .closed { return .closed }
        return .network(error.debugDescription)
    }

    private func complete(_ completion: (@Sendable (Error?) -> Void)?, _ error: Error?) {
        guard let completion else { return }
        callbackQueue.async { completion(error) }
    }

    // MARK: - Lifecycle (ioQueue)

    private func becomeEstablished() {
        phase = .established
        handshakeTimer?.cancel()
        handshakeTimer = nil
        lastReceived = .now()
        shared.withLock { $0.stats.establishedAt = Date() }
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        // First ping right away so the RTT is known as soon as the channel is up.
        timer.schedule(deadline: .now(), repeating: timing.heartbeatInterval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.heartbeat() }
        timer.resume()
        heartbeatTimer = timer
    }

    private func heartbeat() {
        guard phase == .established else { return }
        let paused = shared.withLock { $0.receivePaused }
        let silence = TimeInterval(DispatchTime.now().uptimeNanoseconds &- lastReceived.uptimeNanoseconds) / 1e9
        if !paused && silence > timing.heartbeatTimeout {
            AppLog.warning("peerlink", "\(self) heartbeat timeout (\(String(format: "%.1f", silence)) s silent)")
            finish(error: .timeout, failure: .timeout, farewell: nil)
            return
        }
        var stamp = DispatchTime.now().uptimeNanoseconds.bigEndian
        let payload = withUnsafeBytes(of: &stamp) { Data($0) }
        writeFrame(type: WireType.ping, payload: payload, completion: nil)
    }

    private func protocolViolation(_ reason: String) {
        AppLog.warning("peerlink", "\(self) protocol violation: \(reason)")
        finish(error: .protocolViolation(reason), failure: .protocolViolation(reason), farewell: nil)
    }

    /// The single exit path: runs once, delivers `onClose` (if handed out) after all queued messages,
    /// optionally flushes a last frame (goodbye / reject), releases the connection and timers.
    private func finish(error: PeerLinkError?, failure: LinkFailure?, farewell: Data?) {
        guard phase != .closed else { return }
        let previous = phase
        phase = .closed
        handshakeTimer?.cancel()
        handshakeTimer = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        let handedOut = shared.withLock { s -> Bool in
            s.open = false
            return s.handedOut
        }
        if handedOut {
            deliverClose(error)
        } else {
            pending.removeAll()
        }
        let connection = self.connection
        connection.stateUpdateHandler = nil
        if let farewell, previous != .connecting {
            connection.send(content: farewell, completion: .contentProcessed { _ in connection.cancel() })
            ioQueue.asyncAfter(deadline: .now() + 2) { connection.forceCancel() }
        } else {
            connection.cancel()
        }
        if previous == .established || failure != nil {
            // Include the remote endpoint for handshakes that never completed: periodic failures from
            // unknown hosts (e.g. port scans by endpoint-security software) must be tellable apart from
            // a real peer with a different 配对码.
            let from = previous == .established ? "" : " from \(connection.endpoint)"
            let line = "\(self) closed in phase \(previous.rawValue)\(from): \(failure?.logDescription ?? error?.localizedDescription ?? "normal")"
            // Local port scanners (endpoint-security software probes 127.0.0.1:52525 every ~15 min) fail the
            // TLS-PSK handshake harmlessly; keep them out of the normal log.
            if previous != .established, case .hostPort(let host, _) = connection.endpoint, "\(host)".hasPrefix("127.") || "\(host)" == "::1" {
                AppLog.debug("peerlink", line)
            } else {
                AppLog.info("peerlink", line)
            }
        }
        events.closed(self, CloseInfo(error: error, failure: failure,
                                      wasEstablished: previous == .established, phase: previous.rawValue))
    }
}
