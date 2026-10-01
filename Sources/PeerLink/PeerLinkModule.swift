import AppKit
import Combine
import CryptoKit
import IOKit
import SwiftUI
import SystemConfiguration
import OneSwitchCore

/// 雷雳互联 — links this Mac with the other one over the Thunderbolt Bridge (Bonjour + direct address,
/// TLS-PSK keyed by the shared 配对码) and hands encrypted per-service channels to 文件同步 / 键鼠共享.
/// Also keeps the Thunderbolt Bridge on a static IP (10.77.0.1 ⇄ 10.77.0.2) when enabled.
@MainActor
public final class PeerLinkModule: FeatureModule, PeerHub, ObservableObject {
    public let id = "peerlink"
    public let displayName = "雷雳互联"
    public let symbolName = "cable.connector"

    public let localDeviceID: String
    public let localDeviceName: String

    @Published public private(set) var status: PeerLinkStatus
    public var statusPublisher: AnyPublisher<PeerLinkStatus, Never> { statusSubject.eraseToAnyPublisher() }

    let configuration: PeerLinkConfiguration
    let store: SettingsStore<PeerLinkSettings>
    let bridge: BridgeManager
    private(set) var engine: LinkEngine?

    private let statusSubject: CurrentValueSubject<PeerLinkStatus, Never>
    private var handlers: [String: @MainActor (PeerChannel) -> Void] = [:]
    private var started = false
    private var cancellables = Set<AnyCancellable>()

    static let deviceIDKey = "peerlink.deviceID"
    /// Hash of the hardware the device id was generated on (see `resolveDeviceID`).
    static let deviceHostKey = "peerlink.deviceHost"
    static let settingsKey = "peerlink.settings"

    public convenience init() {
        self.init(configuration: PeerLinkConfiguration())
    }

    /// Injects configuration (settings suite, identity, port, Bonjour type, policy, timings) — lets
    /// self-checks run two hubs in one process.
    public convenience init(configuration: PeerLinkConfiguration) {
        self.init(configuration: configuration, bridgeSystem: SystemBridge())
    }

    init(configuration: PeerLinkConfiguration, bridgeSystem: BridgeSystem) {
        self.configuration = configuration
        let defaults = configuration.defaults
        if let override = configuration.deviceID, !override.isEmpty {
            localDeviceID = override
        } else {
            localDeviceID = Self.resolveDeviceID(defaults: defaults,
                                                 host: configuration.hardwareID ?? Self.hardwareFingerprint())
        }
        localDeviceName = configuration.deviceName ?? Self.computerName()

        store = SettingsStore(key: Self.settingsKey, defaultValue: PeerLinkSettings(), defaults: defaults)
        store.update { s in
            if let passcode = configuration.passcode { s.passcode = passcode }
            if let port = configuration.port { s.port = Int(port) }
            if let policy = configuration.interfacePolicy { s.interfacePolicy = policy }
            if s.staticIP.isEmpty { s.staticIP = PeerLinkDefaults.defaultStaticIP(isLaptop: configuration.isLaptop) }
            if !IPv4.isValidMask(s.staticMask) { s.staticMask = PeerLinkDefaults.subnetMask }
        }
        bridge = BridgeManager(system: bridgeSystem)

        let initial = PeerLinkStatus.disabled(reason: "雷雳互联尚未启动")
        status = initial
        statusSubject = CurrentValueSubject(initial)
    }

    /// The persisted random device id, bound to the Mac it was generated on. Migration Assistant and
    /// Time Machine restores copy the preferences to the other Mac; two Macs with the same id reject each
    /// other as “self” and Bonjour hides the peer, so an id stored for different hardware is replaced.
    /// Ids stored before the binding existed (no host recorded) are kept and adopted.
    static func resolveDeviceID(defaults: UserDefaults, host: String?) -> String {
        let stored = defaults.string(forKey: deviceIDKey) ?? ""
        let storedHost = defaults.string(forKey: deviceHostKey)
        if !stored.isEmpty {
            guard let host, let storedHost, storedHost != host else {
                if let host, storedHost == nil { defaults.set(host, forKey: deviceHostKey) }
                return stored
            }
            AppLog.warning("peerlink", "device id was generated on another Mac (settings copied); generating a new one")
        }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: deviceIDKey)
        if let host { defaults.set(host, forKey: deviceHostKey) }
        return fresh
    }

    /// A short, non-reversible fingerprint of this Mac (hash of IOPlatformUUID). nil if unavailable.
    nonisolated static func hardwareFingerprint() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("OneSwitch-host-v1:\(uuid)".utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The computer name (系统设置 → 通用 → 共享), without blocking on DNS like `Host.current()` can.
    nonisolated static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return Host.current().localizedName ?? "Mac"
    }

    // MARK: - FeatureModule

    public func start() {
        guard !started else { return }
        started = true
        AppLog.info("peerlink", "starting (device \(localDeviceName), id \(localDeviceID.prefix(8)))")

        store.$value
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .seconds(configuration.settingsDebounce), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileEngine() }
            }
            .store(in: &cancellables)

        if configuration.manageThunderboltBridge {
            store.$value
                .map(\.staticIPEnabled)
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] enabled in
                    // Turning the toggle on is an explicit user action → configure (may prompt).
                    MainActor.assumeIsolated { if enabled { self?.configureStaticIP(trigger: .user) } }
                }
                .store(in: &cancellables)

            bridge.onLinkChange = { [weak self] in
                guard let self else { return }
                self.engine?.networkChanged("thunderbolt bridge")
                self.engine?.announceBridgeAddresses()
                self.objectWillChange.send()
            }
            bridge.startMonitoring()
            bridge.refresh()
            let s = store.value
            if s.staticIPEnabled && !s.staticIPPromptDeclined {
                configureStaticIP(trigger: .automatic)
            }
        }
        reconcileEngine()
    }

    public func stop() {
        guard started else { return }
        started = false
        cancellables.removeAll()
        bridge.onLinkChange = nil
        bridge.shutDown()
        stopEngine()
        setStatus(.disabled(reason: "雷雳互联已停止"))
        AppLog.info("peerlink", "stopped")
    }

    public func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = [statusMenuItem()]
        if let line = bridgeMenuLine() { items.append(.info(line)) }
        items.append(BlockMenuItem("重新连接", symbol: "arrow.clockwise", enabled: engine?.isRunning == true) { [weak self] in
            self?.reconnect()
        })
        items.append(BlockMenuItem("雷雳互联设置…", symbol: "gearshape") { [weak self] in
            AppContext.shared.openSettings(moduleID: self?.id ?? "peerlink")
        })
        return items
    }

    public func settingsView() -> AnyView {
        AnyView(PeerLinkSettingsView(module: self, store: store, bridge: bridge))
    }

    // MARK: - PeerHub

    public func register(service: String, onChannel: @escaping @MainActor (PeerChannel) -> Void) {
        guard !service.isEmpty, !service.hasPrefix("_") else {
            AppLog.error("peerlink", "service name \"\(service)\" is reserved / invalid")
            return
        }
        let replacing = handlers[service] != nil
        handlers[service] = onChannel
        AppLog.info("peerlink", "service \(service) registered\(replacing ? " (handler replaced)" : "")")
        if replacing { engine?.resetChannel(for: service) }
        reconcileEngine()
    }

    public func unregister(service: String) {
        guard handlers.removeValue(forKey: service) != nil else { return }
        AppLog.info("peerlink", "service \(service) unregistered")
        reconcileEngine()
    }

    // MARK: - Actions

    /// 重新连接.
    public func reconnect() {
        if let engine, engine.isRunning {
            engine.reconnectAll()
        } else {
            reconcileEngine()
        }
        if configuration.manageThunderboltBridge { bridge.refresh() }
    }

    /// 立即配置 (always allowed to show the password dialog).
    func configureStaticIPNow() {
        configureStaticIP(trigger: .user)
    }

    /// 恢复为自动（DHCP）. Also turns automatic configuration off so the next launch won't revert it.
    func restoreDHCP() {
        guard configuration.manageThunderboltBridge else { return }
        bridge.restoreDHCP { [weak self] outcome in
            guard let self else { return }
            if outcome == .applied || outcome == .alreadyConfigured {
                self.store.update { $0.staticIPEnabled = false }
                self.engine?.networkChanged("bridge set to DHCP")
            }
        }
    }

    private func configureStaticIP(trigger: BridgeManager.Trigger) {
        guard configuration.manageThunderboltBridge else { return }
        let s = store.value
        bridge.configure(ip: s.staticIP, mask: s.staticMask, trigger: trigger) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .cancelled:
                // After stop() the dialog was closed by us (quit), not declined by the user: keep
                // prompting automatically at the next launch.
                guard self.started else { return }
                self.store.update { $0.staticIPPromptDeclined = true }
            case .applied, .alreadyConfigured:
                if self.store.value.staticIPPromptDeclined { self.store.update { $0.staticIPPromptDeclined = false } }
                if outcome == .applied { self.engine?.networkChanged("static IP applied") }
            case .failed:
                break
            }
        }
    }

    // MARK: - Engine management

    /// Starts, updates or stops the engine to match settings + registered services.
    func reconcileEngine() {
        guard started else {
            updateStatus()
            return
        }
        let settings = store.value
        let passcode = Passcode.normalize(settings.passcode)
        if passcode.isEmpty || handlers.isEmpty {
            stopEngine()
            updateStatus()
            return
        }
        let desired = engineConfig(settings: settings, passcode: passcode)
        if let engine, !engine.config.requiresRestart(comparedTo: desired) {
            engine.updateDirectPeers(desired.directPeers)
            if engine.userServices != Set(handlers.keys) { engine.setServices(Set(handlers.keys)) }
        } else {
            stopEngine()
            let engine = LinkEngine(config: desired, services: Set(handlers.keys))
            engine.onChannel = { [weak self] channel in self?.handOut(channel) }
            engine.onChange = { [weak self] in self?.updateStatus() }
            engine.bridgeAddressesProvider = { [weak self] in
                guard let self, self.configuration.manageThunderboltBridge else { return [] }
                return self.bridge.state.addresses
            }
            self.engine = engine
            engine.start()
        }
        updateStatus()
    }

    private func stopEngine() {
        guard let engine else { return }
        self.engine = nil
        engine.onChannel = nil
        engine.onChange = nil
        engine.stop(error: .closed)
    }

    func engineConfig(settings: PeerLinkSettings, passcode: String) -> LinkEngine.Config {
        let port = (1...65535).contains(settings.port) ? UInt16(settings.port) : UInt16(PeerLinkDefaults.port)
        return LinkEngine.Config(deviceID: localDeviceID,
                                 deviceName: localDeviceName,
                                 passcode: passcode,
                                 port: port,
                                 serviceType: configuration.serviceType,
                                 policy: settings.interfacePolicy,
                                 bonjourEnabled: configuration.bonjourEnabled,
                                 directPeers: configuration.directPeers ?? derivedDirectPeers(settings: settings, port: port),
                                 timing: configuration.timing)
    }

    /// 对方 IP override, else the other end of the static /24 (.1 ⇄ .2) when static IP mode is on.
    func derivedDirectPeers(settings: PeerLinkSettings, port: UInt16) -> [PeerAddress] {
        let override = settings.peerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty { return [PeerAddress(host: override, port: port)] }
        if settings.staticIPEnabled, let peer = ThunderboltBridge.derivePeerIP(from: settings.staticIP) {
            return [PeerAddress(host: peer, port: port, viaBridge: true)]
        }
        return []
    }

    private func handOut(_ channel: NetworkPeerChannel) {
        guard let handler = handlers[channel.service] else {
            channel.close(error: nil)
            return
        }
        guard channel.claimForHandout() else { return }
        handler(channel)
    }

    private func updateStatus() {
        let settings = store.value
        let next: PeerLinkStatus
        if !started {
            next = .disabled(reason: "雷雳互联尚未启动")
        } else if Passcode.normalize(settings.passcode).isEmpty {
            next = .disabled(reason: "请先设置配对码")
        } else if handlers.isEmpty {
            next = .disabled(reason: "未启用文件同步或键鼠共享")
        } else if let engine {
            next = engine.status
        } else {
            next = .searching
        }
        setStatus(next)
    }

    private func setStatus(_ next: PeerLinkStatus) {
        guard next != status else { return }
        status = next
        statusSubject.send(next)
        AppLog.info("peerlink", "status → \(next.displayText)")
    }

    // MARK: - Menu

    private func statusMenuItem() -> NSMenuItem {
        let (text, color) = statusLine()
        let item = NSMenuItem.info(text)
        let title = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: color,
                                                                         .font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(string: text, attributes: [.font: NSFont.menuFont(ofSize: 0),
                                                                     .foregroundColor: NSColor.labelColor]))
        item.attributedTitle = title
        return item
    }

    /// "已连接 我的 MacBook Pro · 雷雳 · 0.4 ms" and a dot colour.
    func statusLine() -> (String, NSColor) {
        switch status {
        case .connected(let peer):
            var parts = ["已连接 \(peer.name)"]
            if let ch = engine?.primaryChannel {
                parts.append(ch.linkKind)
                if let rtt = ch.stats.smoothedRTT { parts.append(Self.formatRTT(rtt)) }
            } else if peer.viaThunderbolt {
                parts.append("雷雳")
            }
            return (parts.joined(separator: " · "), .systemGreen)
        case .searching:
            return (status.displayText, .systemOrange)
        case .error(let message):
            return (message, .systemRed)
        case .disabled(let reason):
            return (reason, .secondaryLabelColor)
        }
    }

    /// "雷雳网桥：10.77.0.1 ⇄ 10.77.0.2".
    func bridgeMenuLine() -> String? {
        guard configuration.manageThunderboltBridge else { return nil }
        let state = bridge.state
        if state.linkActive == false { return "雷雳网桥：未检测到雷雳线连接" }
        let local = state.primaryAddress ?? "无地址"
        let peer = peerBridgeAddress() ?? "—"
        return "雷雳网桥：\(local) ⇄ \(peer)"
    }

    /// The peer's address on the bridge: the live Thunderbolt connection's remote address, else what the
    /// peer announced, else the address derived from the static-IP plan.
    func peerBridgeAddress() -> String? {
        if let engine {
            let live = engine.establishedChannels.filter { $0.peer.viaThunderbolt }.compactMap(\.peer.address)
            if let a = Self.preferredBridgeAddress(live + engine.peerBridgeAddresses) { return a }
        }
        let s = store.value
        let override = s.peerAddress.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty { return override }
        return s.staticIPEnabled ? ThunderboltBridge.derivePeerIP(from: s.staticIP) : nil
    }

    /// Bonjour connections over the bridge usually run on IPv6 link-local (fe80::…), which is useless
    /// for display: prefer a configured IPv4 (10.77.0.2), then a self-assigned 169.254.x.x, then anything.
    static func preferredBridgeAddress(_ candidates: [String]) -> String? {
        let v4 = candidates.filter { IPv4.parse($0) != nil }
        return v4.first { !IPv4.isLinkLocal($0) } ?? v4.first ?? candidates.first
    }

    static func formatRTT(_ seconds: TimeInterval) -> String {
        let ms = seconds * 1000
        if ms < 10 { return String(format: "%.1f ms", ms) }
        return String(format: "%.0f ms", ms)
    }
}
