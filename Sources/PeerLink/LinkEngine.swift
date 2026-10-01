import Foundation
import Network
import OneSwitchCore

/// The connection manager behind `PeerLinkModule`: one NWListener (TLS-PSK) advertised over Bonjour,
/// one NWBrowser, direct-address fallback, per-service dialing with backoff, the duplicate-channel
/// tie-break, and an internal control channel used for presence / service announcements / RTT.
///
/// All engine state lives on the main actor (it only does bookkeeping); every connection does its I/O on
/// its own serial queue (see `NetworkPeerChannel`). Listener / browser / path-monitor callbacks are
/// delivered on the main queue.
@MainActor
final class LinkEngine {
    /// Internal service carried by every link (never surfaced; names starting with "_" are reserved).
    static let controlService = "_peerlink.control"
    /// Longest time an incoming hello is held while our own winning dial is still connecting.
    static let parkTimeout: TimeInterval = 1.5
    /// Minimum spacing of automatic Wi‑Fi → Thunderbolt migrations.
    static let upgradeInterval: TimeInterval = 300

    struct Config: Equatable {
        var deviceID: String
        var deviceName: String
        var passcode: String
        var port: UInt16
        var serviceType: String
        var policy: InterfacePolicy
        var bonjourEnabled: Bool
        var directPeers: [PeerAddress]
        var timing: PeerLinkTiming

        /// Changing any of these requires a new engine; direct-dial targets can change in place.
        func requiresRestart(comparedTo other: Config) -> Bool {
            var a = self, b = other
            a.directPeers = []
            b.directPeers = []
            return a != b
        }
    }

    struct DiscoveredPeer {
        var id: String
        var name: String
        var endpoint: NWEndpoint
        var interfaces: [NWInterface]
        var thunderbolt: NWInterface?
        var firstSeen: Date
        var protocolVersion: Int?
    }

    private struct DialTarget: CustomStringConvertible {
        var endpoint: NWEndpoint
        var requiredInterface: NWInterface?
        var label: String
        var description: String { label }
    }

    final class ServiceState {
        let name: String
        var established: NetworkPeerChannel?
        var outgoing: NetworkPeerChannel?
        var outgoingHelloSent = false
        /// An incoming hello held while our own (winning) dial is still connecting.
        var parked: (channel: NetworkPeerChannel, hello: HelloMessage, since: Date)?
        var lastChannelID: String?
        var backoff: Backoff
        var nextAttempt = Date.distantPast
        var unconnectedSince: Date
        var attempts = 0
        var failures = 0
        var lastError: String?
        var lastTarget: String?

        init(name: String, timing: PeerLinkTiming, now: Date) {
            self.name = name
            self.backoff = Backoff(initial: timing.backoffInitial, maximum: timing.backoffMax)
            self.unconnectedSince = now
        }
    }

    // MARK: Outputs

    /// An established *service* channel (never the control channel). Main actor.
    var onChannel: ((NetworkPeerChannel) -> Void)?
    /// Status or diagnostics changed. Main actor.
    var onChange: (() -> Void)?
    /// This Mac's Thunderbolt-bridge IPv4 addresses, announced to the peer for display.
    var bridgeAddressesProvider: () -> [String] = { [] }

    private(set) var config: Config
    let identity: LocalIdentity
    private(set) var isRunning = false
    private(set) var startedAt = Date()

    private var services: [String: ServiceState] = [:]
    private var incoming: [ObjectIdentifier: NetworkPeerChannel] = [:]
    private var listener: NWListener?
    private(set) var listenerPort: UInt16?
    private var usingFallbackPort = false
    private var portAttempts = 0
    private var listenerRestartPending = false
    private var browser: NWBrowser?
    private var browserRestartPending = false
    private(set) var browserState = "未启动"
    private(set) var discovered: [String: DiscoveredPeer] = [:]
    private var thunderboltInterface: NWInterface?
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?
    private var tickTimer: Timer?
    private var tickScheduled = false
    private var knownPeerID: String?
    private var lastUpgradeAttempt = Date.distantPast

    private var authFailureAt: Date?
    private var localNetworkDenied = false
    private var protocolMismatch = false
    private(set) var listenerError: String?

    private var controlChannel: NetworkPeerChannel?
    private(set) var peerServices: Set<String>?
    private(set) var peerBridgeAddresses: [String] = []

    /// Per service: how many duplicate connections this side refused (tie-break diagnostics / checks).
    private(set) var duplicateRejections: [String: Int] = [:]

    private(set) var recentEvents: [String] = []
    private static let eventLimit = 80
    private static let eventTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(config: Config, services userServices: Set<String>) {
        self.config = config
        self.identity = LocalIdentity(deviceID: config.deviceID, deviceName: config.deviceName,
                                      instanceID: UUID().uuidString)
        let now = Date()
        for name in userServices.union([Self.controlService]) {
            services[name] = ServiceState(name: name, timing: config.timing, now: now)
        }
    }

    private lazy var channelEvents: NetworkPeerChannel.Events = {
        // Channel events arrive on each connection's queue; hop to the main actor in FIFO order.
        let hop: @Sendable (@escaping @MainActor (LinkEngine) -> Void) -> Void = { [weak self] body in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    body(self)
                }
            }
        }
        return NetworkPeerChannel.Events(
            transportReady: { ch in hop { $0.channelTransportReady(ch) } },
            helloReceived: { ch, hello in hop { $0.channelHello(ch, hello) } },
            ackReceived: { ch, ack in hop { $0.channelAck(ch, ack) } },
            rejectReceived: { ch, reject in hop { $0.channelRejected(ch, reject) } },
            closed: { ch, info in hop { $0.channelClosed(ch, info) } }
        )
    }()

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startedAt = Date()
        for s in services.values {
            s.unconnectedSince = startedAt
            s.nextAttempt = startedAt
        }
        log("started (id \(config.deviceID.prefix(8)), port \(config.port), policy \(config.policy.rawValue), bonjour \(config.bonjourEnabled), direct \(config.directPeers.map(\.description).joined(separator: ", ")))")
        startListener()
        if config.bonjourEnabled { startBrowser() } else { browserState = "已停用" }
        startPathMonitor()
        let timer = Timer(timeInterval: config.timing.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
        tickSoon()
    }

    /// Closes every channel (services get `onClose(error)`), cancels the listener, browser and monitor.
    func stop(error: PeerLinkError? = .closed) {
        guard isRunning else { return }
        isRunning = false
        tickTimer?.invalidate()
        tickTimer = nil
        if let listener {
            listener.stateUpdateHandler = nil
            // A connection accepted while the cancel is in flight must still be released.
            listener.newConnectionHandler = { $0.cancel() }
            listener.cancel()
        }
        listener = nil
        listenerPort = nil
        if let browser {
            browser.stateUpdateHandler = nil
            browser.browseResultsChangedHandler = nil
            browser.cancel()
        }
        browser = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        for s in services.values {
            s.outgoing?.close(error: error)
            s.outgoing = nil
            s.established?.close(error: error)
            s.established = nil
            s.parked = nil
        }
        for ch in incoming.values { ch.close(error: error) }
        incoming.removeAll()
        controlChannel = nil
        peerServices = nil
        discovered.removeAll()
        log("stopped")
    }

    // MARK: - Services

    var userServices: Set<String> { Set(services.keys).subtracting([Self.controlService]) }

    func setServices(_ names: Set<String>) {
        let wanted = names.union([Self.controlService])
        let now = Date()
        for (name, s) in services where !wanted.contains(name) {
            if let parked = s.parked {
                s.parked = nil
                reject(parked.channel, .serviceNotRegistered)
            }
            s.outgoing?.close(error: nil)
            s.established?.close(error: nil)
            services[name] = nil
            log("service \(name) unregistered")
        }
        for name in wanted where services[name] == nil {
            let s = ServiceState(name: name, timing: config.timing, now: now)
            s.nextAttempt = now
            services[name] = s
            log("service \(name) registered")
        }
        sendAnnouncement()
        tickSoon()
        changed()
    }

    /// Updates the direct-dial targets (对方 IP / static-IP plan) without dropping live channels.
    func updateDirectPeers(_ peers: [PeerAddress]) {
        guard peers != config.directPeers else { return }
        config.directPeers = peers
        log("direct addresses: \(peers.map(\.description).joined(separator: ", "))")
        networkChanged("direct addresses changed")
    }

    /// Closes the live channel of `service` so a fresh one is formed (used when a handler is replaced).
    func resetChannel(for service: String) {
        guard let s = services[service], let ch = s.established else { return }
        s.established = nil
        s.unconnectedSince = Date()
        s.nextAttempt = Date()
        ch.close(error: nil)
        tickSoon()
    }

    /// 重新连接: drops every channel, clears errors and backoff, restarts discovery.
    func reconnectAll() {
        guard isRunning else { return }
        log("manual reconnect")
        authFailureAt = nil
        protocolMismatch = false
        localNetworkDenied = false
        let now = Date()
        for s in services.values {
            s.outgoing?.close(error: .closed)
            s.outgoing = nil
            if let parked = s.parked {
                s.parked = nil
                parked.channel.close(error: .closed)
            }
            if let ch = s.established {
                s.established = nil
                ch.close(error: .closed)
            }
            s.backoff.reset()
            s.nextAttempt = now
            s.unconnectedSince = now
        }
        controlChannel = nil
        peerServices = nil
        if config.bonjourEnabled {
            if let browser {
                browser.stateUpdateHandler = nil
                browser.browseResultsChangedHandler = nil
                browser.cancel()
            }
            browser = nil
            discovered.removeAll()
            startBrowser()
        }
        if listener == nil && !listenerRestartPending { startListener() }
        tickSoon()
        changed()
    }

    /// Network path / bridge address changed: retry right away instead of waiting for the backoff.
    func networkChanged(_ reason: String) {
        guard isRunning else { return }
        log("network changed (\(reason)); resetting backoff")
        let now = Date()
        for s in services.values {
            s.backoff.reset()
            if s.established == nil && s.outgoing == nil { s.nextAttempt = now }
        }
        considerThunderboltUpgrade()
        tickSoon()
    }

    /// 优先雷雳网桥: when the link came up over Wi‑Fi / Ethernet (e.g. the bridge got its address later at
    /// login) and the peer is now reachable over the bridge, move those channels to Thunderbolt.
    /// Rate-limited so a bridge that does not actually work can never cause reconnect loops.
    private func considerThunderboltUpgrade() {
        guard isRunning, config.policy == .preferThunderbolt,
              let peer = preferredDiscoveredPeer(), peer.thunderbolt != nil else { return }
        let slow = establishedChannels.filter { ch in
            !ch.peer.viaThunderbolt && (ch.linkKind == "Wi‑Fi" || ch.linkKind == "有线网络")
        }
        let now = Date()
        guard !slow.isEmpty, now.timeIntervalSince(lastUpgradeAttempt) > Self.upgradeInterval else { return }
        lastUpgradeAttempt = now
        log("Thunderbolt bridge available; moving \(slow.count) channel(s) off \(slow[0].linkKind)")
        for ch in slow {
            guard let s = services[ch.service], s.established === ch else { continue }
            s.established = nil
            s.unconnectedSince = now
            s.nextAttempt = now
            s.failures = 0
            s.backoff.reset()
            if s.name == Self.controlService {
                controlChannel = nil
                peerServices = nil
                peerBridgeAddresses = []
            }
            ch.close(error: .closed)
        }
        changed()
    }

    // MARK: - Status

    var status: PeerLinkStatus {
        if let peer = primaryChannel?.peer { return .connected(peer) }
        if protocolMismatch { return .error("对方的 OneSwitch 版本与本机不兼容：请将两台 Mac 更新到同一版本") }
        if let at = authFailureAt, Date().timeIntervalSince(at) < max(75, config.timing.backoffMax * 2.5) {
            return .error("配对码不匹配：请确认两台 Mac 的配对码一致")
        }
        if localNetworkDenied {
            return .error("未获得“本地网络”权限：请在 系统设置 → 隐私与安全性 → 本地网络 中允许 OneSwitch")
        }
        if let listenerError { return .error(listenerError) }
        return .searching
    }

    /// The channel describing the link: the control channel, else any established service channel.
    var primaryChannel: NetworkPeerChannel? {
        if let c = services[Self.controlService]?.established { return c }
        return services.keys.sorted().lazy.compactMap { self.services[$0]?.established }.first
    }

    var establishedChannels: [NetworkPeerChannel] {
        services.keys.sorted().compactMap { services[$0]?.established }
    }

    func serviceStates() -> [ServiceState] {
        services.keys.sorted().compactMap { services[$0] }
    }

    // MARK: - Tick / dialing

    private func tickSoon() {
        guard !tickScheduled else { return }
        tickScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.tickScheduled = false
                self?.tick()
            }
        }
    }

    private func tick() {
        guard isRunning else { return }
        let now = Date()
        let control = services[Self.controlService]
        let controlUp = control?.established != nil
        // Control channel first, then services in name order (deterministic logs).
        let ordered = [Self.controlService] + services.keys.filter { $0 != Self.controlService }.sorted()
        for name in ordered {
            // A service handler run from `establish` below may stop the engine (e.g. by unregistering
            // the last service); never start new dials after that.
            guard isRunning else { return }
            // Our dial has been connecting for too long while the peer's hello waits: take the peer's.
            if let s = services[name], let parked = s.parked, now.timeIntervalSince(parked.since) > Self.parkTimeout {
                AppLog.debug("peerlink", "\(name): own dial still connecting; accepting the parked incoming channel")
                s.parked = nil
                if let out = s.outgoing {
                    s.outgoing = nil
                    out.close(error: .closed)
                }
                channelHello(parked.channel, parked.hello)
            }
            guard let s = services[name], s.established == nil, s.outgoing == nil, now >= s.nextAttempt else { continue }
            if name != Self.controlService, controlUp, let ps = peerServices, !ps.contains(name) { continue }
            guard let target = chooseTarget(for: s, now: now) else { continue }
            dial(s, target: target)
        }
        onChange?()
    }

    private func preferredDiscoveredPeer() -> DiscoveredPeer? {
        var peers = Array(discovered.values)
        if config.policy == .thunderboltOnly { peers = peers.filter { $0.thunderbolt != nil } }
        if let known = knownPeerID, let p = peers.first(where: { $0.id == known }) { return p }
        return peers.sorted { $0.id < $1.id }.first
    }

    private func chooseTarget(for s: ServiceState, now: Date) -> DialTarget? {
        var candidates: [DialTarget] = []
        let peer = preferredDiscoveredPeer()
        if let peer {
            let waited = now.timeIntervalSince(max(s.unconnectedSince, peer.firstSeen))
            guard DialRules.shouldDial(localID: identity.deviceID, peerID: peer.id, waited: waited,
                                       asymmetricDelay: config.timing.asymmetricDialDelay) else { return nil }
            let label = "Bonjour “\(peer.name)”"
            if let tb = peer.thunderbolt, config.policy != .any {
                candidates.append(DialTarget(endpoint: peer.endpoint, requiredInterface: tb, label: label + " via \(tb.name)"))
                // 优先雷雳网桥: if the bridge keeps failing, alternate with an unpinned attempt.
                if config.policy == .preferThunderbolt {
                    candidates.append(DialTarget(endpoint: peer.endpoint, requiredInterface: nil, label: label))
                }
            } else {
                candidates.append(DialTarget(endpoint: peer.endpoint, requiredInterface: nil, label: label))
            }
        }
        if !config.directPeers.isEmpty {
            let bonjourGrace = now.timeIntervalSince(startedAt) >= config.timing.directDialDelay
            if peer != nil || bonjourGrace {
                let peerID = peer?.id ?? knownPeerID
                let waited = now.timeIntervalSince(s.unconnectedSince)
                if peer != nil || DialRules.shouldDial(localID: identity.deviceID, peerID: peerID, waited: waited,
                                                       asymmetricDelay: config.timing.asymmetricDialDelay) {
                    for addr in config.directPeers {
                        guard let port = NWEndpoint.Port(rawValue: addr.port) else { continue }
                        // Pin to the bridge in 仅雷雳网桥 mode and for static-plan addresses (which only exist
                        // on the bridge); a user override may be a Wi‑Fi IP and stays unpinned otherwise.
                        let iface: NWInterface? = (config.policy == .thunderboltOnly || addr.viaBridge) ? thunderboltInterface : nil
                        candidates.append(DialTarget(endpoint: .hostPort(host: NWEndpoint.Host(addr.host), port: port),
                                                     requiredInterface: iface,
                                                     label: addr.description + (iface.map { " via \($0.name)" } ?? "")))
                    }
                }
            }
        }
        guard !candidates.isEmpty else { return nil }
        // Alternate between Bonjour and direct addresses when attempts keep failing.
        let target = candidates[s.failures % candidates.count]
        return target
    }

    private func dial(_ s: ServiceState, target: DialTarget) {
        guard isRunning, services[s.name] === s else { return }
        let params = PeerSecurity.parameters(passcode: config.passcode, timing: config.timing,
                                             requiredInterface: target.requiredInterface)
        // Bulk file sync must not compete with keyboard / mouse traffic in the network stack's queues.
        params.serviceClass = s.name == "sync" ? .bestEffort : .responsiveData
        let connection = NWConnection(to: target.endpoint, using: params)
        let ch = NetworkPeerChannel(role: .dialer, connection: connection, service: s.name,
                                    channelID: UUID().uuidString, identity: identity, timing: config.timing,
                                    thunderboltOnly: config.policy == .thunderboltOnly, events: channelEvents)
        s.outgoing = ch
        s.outgoingHelloSent = false
        s.attempts += 1
        s.lastTarget = target.label
        AppLog.debug("peerlink", "dial \(s.name) → \(target.label) (attempt \(s.attempts))")
        ch.start()
    }

    // MARK: - Channel events (main actor)

    private func channelTransportReady(_ ch: NetworkPeerChannel) {
        guard isRunning, let s = services[ch.service], s.outgoing === ch else {
            ch.close(error: .closed)
            return
        }
        if s.established != nil {
            s.outgoing = nil
            ch.close(error: .closed)
            return
        }
        s.outgoingHelloSent = true
        ch.sendHello(HelloMessage(protocolVersion: Wire.protocolVersion, deviceID: identity.deviceID,
                                  deviceName: identity.deviceName, service: s.name,
                                  instanceID: identity.instanceID, channelID: ch.channelID,
                                  lastChannelID: s.lastChannelID))
        if let parked = s.parked {
            // Our dial is handshaking now and wins the tie-break.
            s.parked = nil
            reject(parked.channel, .duplicate)
        }
    }

    private func acceptConnection(_ connection: NWConnection) {
        guard isRunning, incoming.count < 32 else {
            connection.cancel()
            return
        }
        let ch = NetworkPeerChannel(role: .acceptor, connection: connection, service: "", channelID: "",
                                    identity: identity, timing: config.timing,
                                    thunderboltOnly: config.policy == .thunderboltOnly, events: channelEvents)
        incoming[ObjectIdentifier(ch)] = ch
        ch.start()
    }

    private func channelHello(_ ch: NetworkPeerChannel, _ hello: HelloMessage) {
        guard incoming[ObjectIdentifier(ch)] != nil else {
            ch.close(error: .closed)
            return
        }
        guard isRunning else { return reject(ch, .shuttingDown) }
        if hello.protocolVersion != Wire.protocolVersion {
            protocolMismatch = true
            log("peer \(hello.deviceName) speaks protocol v\(hello.protocolVersion); rejecting")
            changed()
            return reject(ch, .protocolMismatch)
        }
        if hello.deviceID == identity.deviceID { return reject(ch, .selfConnection) }
        peerAuthenticated()
        if let active = activePeerID, active != hello.deviceID { return reject(ch, .busy) }
        guard let s = services[hello.service] else { return reject(ch, .serviceNotRegistered) }

        let decision = DialRules.decideIncoming(
            localID: identity.deviceID, hello: hello,
            established: s.established.map { ($0.channelID, $0.peerInstanceID) },
            outgoingHelloSent: s.outgoing == nil ? nil : s.outgoingHelloSent)
        switch decision {
        case .park:
            if let previous = s.parked, previous.channel !== ch {
                reject(previous.channel, .duplicate)
            }
            s.parked = (ch, hello, Date())
        case .reject(let reason):
            log("\(s.name): rejecting duplicate channel from \(hello.deviceName)")
            reject(ch, reason)
        case .accept(let replacing, let cancelOutgoing):
            if cancelOutgoing, let out = s.outgoing {
                s.outgoing = nil
                out.close(error: .closed)
            }
            if replacing, let old = s.established {
                log("\(s.name): peer reconnected; replacing channel \(old.channelID.prefix(8))")
                s.established = nil
                old.close(error: nil)
            }
            if let parked = s.parked, parked.channel === ch { s.parked = nil }
            incoming[ObjectIdentifier(ch)] = nil
            ch.acceptIncoming(HelloAckMessage(protocolVersion: Wire.protocolVersion, deviceID: identity.deviceID,
                                              deviceName: identity.deviceName, service: s.name,
                                              instanceID: identity.instanceID, channelID: hello.channelID))
            establish(s, ch)
        }
    }

    private func reject(_ ch: NetworkPeerChannel, _ reason: RejectReason) {
        incoming[ObjectIdentifier(ch)] = nil
        if reason == .duplicate { duplicateRejections[ch.service, default: 0] += 1 }
        ch.rejectIncoming(RejectMessage(protocolVersion: Wire.protocolVersion, deviceID: identity.deviceID,
                                        deviceName: identity.deviceName, reason: reason.rawValue, detail: nil))
    }

    private func channelAck(_ ch: NetworkPeerChannel, _ ack: HelloAckMessage) {
        guard isRunning, let s = services[ch.service], s.outgoing === ch else {
            ch.close(error: .closed)
            return
        }
        s.outgoing = nil
        guard ack.deviceID != identity.deviceID else {
            ch.close(error: .protocolViolation("连接到了本机"))
            s.nextAttempt = Date().addingTimeInterval(s.backoff.next())
            return
        }
        guard ack.protocolVersion == Wire.protocolVersion else {
            protocolMismatch = true
            ch.close(error: .protocolViolation("协议版本不兼容"))
            s.nextAttempt = Date().addingTimeInterval(config.timing.backoffMax)
            changed()
            return
        }
        peerAuthenticated()
        if let old = s.established {
            s.established = nil
            old.close(error: nil)
        }
        ch.confirmEstablished()
        establish(s, ch)
    }

    private func channelRejected(_ ch: NetworkPeerChannel, _ reject: RejectMessage) {
        guard let s = services[ch.service], s.outgoing === ch else { return }
        s.outgoing = nil
        if !reject.deviceID.isEmpty { peerAuthenticated() }
        let now = Date()
        switch reject.knownReason {
        case .duplicate?:
            // The peer kept its own connection for this service; it will be ours shortly.
            s.lastError = "对方已有同一通道，等待对方连接"
            s.nextAttempt = now.addingTimeInterval(max(config.timing.backoffInitial, config.timing.asymmetricDialDelay / 2))
        case .serviceNotRegistered?:
            s.lastError = "对方未启用此功能"
            s.failures += 1
            s.nextAttempt = now.addingTimeInterval(s.backoff.next())
        case .protocolMismatch?, nil:
            protocolMismatch = true
            s.lastError = "对方版本不兼容"
            s.nextAttempt = now.addingTimeInterval(config.timing.backoffMax)
        case .selfConnection?:
            s.lastError = "目标地址是本机"
            s.failures += 1
            s.nextAttempt = now.addingTimeInterval(config.timing.backoffMax)
        case .busy?, .notThunderbolt?, .shuttingDown?:
            switch reject.knownReason {
            case .busy?: s.lastError = "对方已与另一台 Mac 连接"
            case .notThunderbolt?: s.lastError = "对方只接受雷雳网桥连接"
            default: s.lastError = "对方正在退出"
            }
            s.failures += 1
            s.nextAttempt = now.addingTimeInterval(s.backoff.next())
        }
        AppLog.debug("peerlink", "\(s.name): rejected by peer (\(reject.reason))")
        if let parked = s.parked {
            // Our dial was refused, so the peer's parked connection is the one to keep.
            s.parked = nil
            channelHello(parked.channel, parked.hello)
        }
        changed()
    }

    private func establish(_ s: ServiceState, _ ch: NetworkPeerChannel) {
        if let parked = s.parked, parked.channel !== ch {
            s.parked = nil
            reject(parked.channel, .duplicate)
        }
        s.established = ch
        s.lastChannelID = ch.channelID
        s.backoff.reset()
        s.failures = 0
        s.lastError = nil
        let peer = ch.peer
        knownPeerID = peer.deviceID
        authFailureAt = nil
        localNetworkDenied = false
        protocolMismatch = false
        log("\(s.name): connected to \(peer.name) at \(peer.address ?? "?") via \(ch.linkKind) (\(ch.initiatedLocally ? "outgoing" : "incoming"))")
        if s.name == Self.controlService {
            setUpControl(ch)
        } else {
            onChannel?(ch)
        }
        changed()
    }

    private func channelClosed(_ ch: NetworkPeerChannel, _ info: NetworkPeerChannel.CloseInfo) {
        incoming[ObjectIdentifier(ch)] = nil
        guard isRunning else { return }
        if let failure = info.failure {
            switch failure {
            case .authentication:
                if authFailureAt == nil { log("TLS authentication failed: 配对码不匹配") }
                authFailureAt = Date()
            case .localNetworkDenied:
                if !localNetworkDenied { log("local network access denied") }
                localNetworkDenied = true
            default:
                break
            }
        }
        guard let s = services[ch.service] else {
            changed()
            return
        }
        let now = Date()
        if let parked = s.parked, parked.channel === ch {
            s.parked = nil
        }
        if s.outgoing === ch {
            s.outgoing = nil
            s.failures += 1
            s.lastError = info.failure.map(Self.describe) ?? info.error?.localizedDescription
            let delay = s.backoff.next()
            s.nextAttempt = now.addingTimeInterval(delay)
            AppLog.debug("peerlink", "\(s.name): dial failed in \(info.phase) (\(info.failure?.logDescription ?? "-")); retry in \(delay) s")
            if let parked = s.parked {
                // Our dial lost; the peer's parked connection takes over.
                s.parked = nil
                channelHello(parked.channel, parked.hello)
            }
        }
        if s.established === ch {
            s.established = nil
            s.unconnectedSince = now
            s.nextAttempt = now
            s.backoff.reset()
            s.lastError = info.error.map { $0.localizedDescription }
            log("\(s.name): channel closed (\(info.failure?.logDescription ?? info.error?.localizedDescription ?? "closed locally"))")
            if s.name == Self.controlService {
                controlChannel = nil
                peerServices = nil
                peerBridgeAddresses = []
            }
        }
        tickSoon()
        changed()
    }

    private var activePeerID: String? {
        services.values.lazy.compactMap { $0.established?.peer.deviceID }.first
    }

    private func peerAuthenticated() {
        authFailureAt = nil
    }

    private static func describe(_ failure: LinkFailure) -> String {
        switch failure {
        case .authentication: return "配对码不匹配"
        case .localNetworkDenied: return "未获得本地网络权限"
        case .refused: return "连接被拒绝（对方未运行 OneSwitch？）"
        case .unreachable: return "无法访问对方"
        case .timeout: return "连接超时"
        case .notThunderbolt: return "连接未经过雷雳网桥"
        case .protocolViolation(let s): return "协议错误：\(s)"
        case .other(let s): return s
        }
    }

    // MARK: - Control channel

    private func setUpControl(_ ch: NetworkPeerChannel) {
        controlChannel = ch
        _ = ch.claimForHandout()
        let id = ObjectIdentifier(ch)
        let queue = DispatchQueue(label: "oneswitch.peerlink.control", qos: .utility)
        ch.setHandlers(queue: queue, onMessage: { [weak self] type, payload in
            guard type == ControlAnnouncement.type,
                  let message = Wire.decode(ControlAnnouncement.self, from: payload) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receivedAnnouncement(message, channel: id) }
            }
        }, onClose: { _ in })
        sendAnnouncement()
    }

    private func sendAnnouncement() {
        guard let ch = controlChannel, ch.isOpen else { return }
        let message = ControlAnnouncement(services: userServices.sorted(),
                                          bridgeAddresses: bridgeAddressesProvider(),
                                          appVersion: AppEnvironment.appVersion)
        ch.send(type: ControlAnnouncement.type, payload: Wire.encode(message))
    }

    /// Re-announces this Mac's bridge addresses (after the static IP changed).
    func announceBridgeAddresses() { sendAnnouncement() }

    private func receivedAnnouncement(_ message: ControlAnnouncement, channel: ObjectIdentifier) {
        guard isRunning, let ch = controlChannel, ObjectIdentifier(ch) == channel else { return }
        let services = Set(message.services)
        let added = services.subtracting(peerServices ?? [])
        peerServices = services
        peerBridgeAddresses = message.bridgeAddresses
        let now = Date()
        for name in added {
            guard let s = self.services[name], s.established == nil, s.outgoing == nil else { continue }
            s.backoff.reset()
            s.nextAttempt = now
        }
        AppLog.debug("peerlink", "peer services: \(message.services.joined(separator: ", "))")
        tickSoon()
        changed()
    }

    // MARK: - Listener

    private var bonjourInstanceName: String {
        // DNS-SD instance names are limited to 63 bytes of UTF-8.
        var name = config.deviceName
        while name.utf8.count > 63 { name.removeLast() }
        return name.isEmpty ? "OneSwitch" : name
    }

    private func txtRecord(port: UInt16) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["id"] = config.deviceID
        txt["v"] = String(Wire.protocolVersion)
        txt["port"] = String(port)
        return txt
    }

    private func startListener() {
        listenerRestartPending = false
        guard isRunning else { return }
        let params = PeerSecurity.parameters(passcode: config.passcode, timing: config.timing,
                                             requiredInterface: config.policy == .thunderboltOnly ? thunderboltInterface : nil)
        // SO_REUSEADDR: lets the fixed port be re-bound while our own closed connections on it are in
        // TIME_WAIT (e.g. right after an engine restart). It does not allow two active listeners.
        params.allowLocalEndpointReuse = true
        let port: NWEndpoint.Port = usingFallbackPort ? .any : (NWEndpoint.Port(rawValue: config.port) ?? .any)
        let l: NWListener
        do {
            l = try NWListener(using: params, on: port)
        } catch {
            listenerError = "无法监听端口 \(config.port)：\(error.localizedDescription)"
            log("listener creation failed: \(error)")
            scheduleListenerRestart(after: config.timing.restartDelay)
            changed()
            return
        }
        if config.bonjourEnabled {
            l.service = NWListener.Service(name: bonjourInstanceName, type: config.serviceType, domain: nil,
                                           txtRecord: txtRecord(port: config.port))
        }
        l.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.acceptConnection(connection) }
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            MainActor.assumeIsolated {
                guard let self, let l, self.listener === l else { return }
                self.listenerStateChanged(state, l)
            }
        }
        listener = l
        l.start(queue: .main)
    }

    private func listenerStateChanged(_ state: NWListener.State, _ l: NWListener) {
        switch state {
        case .ready:
            let actual = l.port?.rawValue
            listenerPort = actual
            listenerError = nil
            portAttempts = 0
            if let actual, config.bonjourEnabled, actual != config.port {
                l.service = NWListener.Service(name: bonjourInstanceName, type: config.serviceType, domain: nil,
                                               txtRecord: txtRecord(port: actual))
            }
            log("listening on port \(actual.map(String.init) ?? "?")\(usingFallbackPort ? "（端口 \(config.port) 被占用，已改用系统分配端口）" : "")")
            changed()
        case .failed(let error):
            l.stateUpdateHandler = nil
            l.newConnectionHandler = { $0.cancel() }
            l.cancel()
            listener = nil
            listenerPort = nil
            if case .posix(.EADDRINUSE) = error, !usingFallbackPort {
                portAttempts += 1
                if portAttempts >= 5 {
                    usingFallbackPort = true
                    log("port \(config.port) is in use; falling back to a system-assigned port")
                }
                scheduleListenerRestart(after: 0.4)
            } else {
                if LinkFailure.classify(error) == .localNetworkDenied { localNetworkDenied = true }
                listenerError = "无法监听端口 \(config.port)：\(error.localizedDescription)"
                log("listener failed: \(error)")
                scheduleListenerRestart(after: config.timing.restartDelay)
            }
            changed()
        case .waiting(let error):
            if LinkFailure.classify(error) == .localNetworkDenied {
                localNetworkDenied = true
                changed()
            }
        default:
            break
        }
    }

    private func scheduleListenerRestart(after delay: TimeInterval) {
        guard !listenerRestartPending else { return }
        listenerRestartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.listener == nil else {
                    self?.listenerRestartPending = false
                    return
                }
                self.startListener()
            }
        }
    }

    // MARK: - Browser

    private func startBrowser() {
        browserRestartPending = false
        guard isRunning, config.bonjourEnabled else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        if config.policy == .thunderboltOnly, let tb = thunderboltInterface { params.requiredInterface = tb }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: config.serviceType, domain: nil), using: params)
        b.stateUpdateHandler = { [weak self, weak b] state in
            MainActor.assumeIsolated {
                guard let self, let b, self.browser === b else { return }
                self.browserStateChanged(state, b)
            }
        }
        b.browseResultsChangedHandler = { [weak self, weak b] results, _ in
            MainActor.assumeIsolated {
                guard let self, let b, self.browser === b else { return }
                self.browseResultsChanged(results)
            }
        }
        browser = b
        browserState = "启动中"
        b.start(queue: .main)
    }

    private func browserStateChanged(_ state: NWBrowser.State, _ b: NWBrowser) {
        switch state {
        case .ready:
            browserState = "正常"
            if localNetworkDenied {
                localNetworkDenied = false
                changed()
            }
        case .failed(let error):
            browserState = "失败：\(error.localizedDescription)"
            if LinkFailure.classify(error) == .localNetworkDenied { localNetworkDenied = true }
            log("Bonjour browser failed: \(error)")
            b.stateUpdateHandler = nil
            b.browseResultsChangedHandler = nil
            b.cancel()
            browser = nil
            scheduleBrowserRestart()
            changed()
        case .waiting(let error):
            browserState = "等待：\(error.localizedDescription)"
            if LinkFailure.classify(error) == .localNetworkDenied {
                localNetworkDenied = true
                log("Bonjour browsing denied by local network privacy")
            }
            changed()
        default:
            break
        }
    }

    private func scheduleBrowserRestart() {
        guard !browserRestartPending else { return }
        browserRestartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + config.timing.restartDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, self.browser == nil else {
                    self?.browserRestartPending = false
                    return
                }
                self.startBrowser()
            }
        }
    }

    private func browseResultsChanged(_ results: Set<NWBrowser.Result>) {
        let now = Date()
        var found: [String: DiscoveredPeer] = [:]
        for r in results {
            guard case .bonjour(let txt) = r.metadata, let id = txt["id"], !id.isEmpty,
                  id != identity.deviceID else { continue }
            var name = id
            if case .service(let n, _, _, _) = r.endpoint { name = n }
            let tb = r.interfaces.first { ThunderboltBridge.isThunderboltInterface($0.name) }
            if let tb { thunderboltInterface = tb }
            if let existing = found[id], existing.thunderbolt != nil, tb == nil { continue }
            found[id] = DiscoveredPeer(id: id, name: name, endpoint: r.endpoint, interfaces: r.interfaces,
                                       thunderbolt: tb, firstSeen: discovered[id]?.firstSeen ?? now,
                                       protocolVersion: txt["v"].flatMap { Int($0) })
        }
        let newIDs = Set(found.keys).subtracting(discovered.keys)
        for id in newIDs {
            if let p = found[id] {
                log("discovered \(p.name) (\(p.interfaces.map(\.name).joined(separator: ", ")))")
            }
        }
        for id in Set(discovered.keys).subtracting(found.keys) {
            log("lost Bonjour peer \(discovered[id]?.name ?? id)")
        }
        discovered = found
        if !newIDs.isEmpty { networkChanged("peer discovered") } else { considerThunderboltUpgrade() }
        tickSoon()
        changed()
    }

    // MARK: - Path monitor

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.pathUpdated(path) }
        }
        pathMonitor = monitor
        pathSignature = nil
        monitor.start(queue: .main)
    }

    private func pathUpdated(_ path: NWPath) {
        // The default path lists the bridge only once it has a routable (non link-local) address;
        // otherwise the interface object is learned from Bonjour results / connection paths.
        if let tb = path.availableInterfaces.first(where: { ThunderboltBridge.isThunderboltInterface($0.name) }) {
            thunderboltInterface = tb
        }
        let signature = "\(path.status) " + path.availableInterfaces.map(\.name).joined(separator: ",")
        defer { pathSignature = signature }
        guard let previous = pathSignature, previous != signature else { return }
        networkChanged("path: \(signature)")
    }

    // MARK: - Diagnostics

    private func changed() { onChange?() }

    func log(_ message: String) {
        AppLog.info("peerlink", message)
        recentEvents.append("\(Self.eventTimeFormatter.string(from: Date())) \(message)")
        if recentEvents.count > Self.eventLimit { recentEvents.removeFirst(recentEvents.count - Self.eventLimit) }
    }
}
