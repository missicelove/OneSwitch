import Foundation
import OneSwitchCore

/// Which network interfaces PeerLink may use (设置项 “网络接口”).
public enum InterfacePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case thunderboltOnly
    case preferThunderbolt
    case any

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thunderboltOnly: return "仅雷雳网桥"
        case .preferThunderbolt: return "优先雷雳网桥"
        case .any: return "任意网络"
        }
    }

    var detail: String {
        switch self {
        case .thunderboltOnly: return "只通过雷雳线连接；拔掉线缆后断开。"
        case .preferThunderbolt: return "插着雷雳线时走雷雳网桥，否则可经由 Wi‑Fi 或以太网连接。"
        case .any: return "由系统选择任意可用网络。"
        }
    }
}

/// Persisted settings (`peerlink.settings`).
struct PeerLinkSettings: Codable, Equatable {
    /// 配对码 — must be identical on both Macs.
    var passcode = ""
    var interfacePolicy: InterfacePolicy = .preferThunderbolt
    /// TCP port of the listener (both Macs use the same port by default).
    var port = PeerLinkDefaults.port
    /// 对方 IP（可选）: direct-dial address used when Bonjour finds nothing.
    var peerAddress = ""
    /// 自动配置雷雳网桥静态 IP.
    var staticIPEnabled = true
    /// This Mac's bridge address; empty = default (.1 on desktops, .2 on laptops).
    var staticIP = ""
    var staticMask = PeerLinkDefaults.subnetMask
    /// The user cancelled the administrator prompt; do not prompt automatically again.
    var staticIPPromptDeclined = false
}

public enum PeerLinkDefaults {
    public static let port: Int = 52525
    public static let serviceType = "_oneswitch._tcp"
    public static let subnetPrefix = "10.77.0."
    public static let subnetMask = "255.255.255.0"
    public static let desktopIP = "10.77.0.1"
    public static let laptopIP = "10.77.0.2"

    static func defaultStaticIP(isLaptop: Bool) -> String { isLaptop ? laptopIP : desktopIP }
}

/// Protocol timings. Injected so self-checks can run the dial / heartbeat logic quickly.
public struct PeerLinkTiming: Sendable, Equatable {
    public var heartbeatInterval: TimeInterval = 2
    public var heartbeatTimeout: TimeInterval = 6
    public var handshakeTimeout: TimeInterval = 5
    public var connectTimeout: TimeInterval = 5
    public var backoffInitial: TimeInterval = 1
    public var backoffMax: TimeInterval = 30
    /// The side with the larger device id also dials when nothing arrived within this delay.
    public var asymmetricDialDelay: TimeInterval = 4
    /// Direct-address fallback starts when Bonjour found nothing within this delay after start.
    public var directDialDelay: TimeInterval = 5
    /// Main-actor housekeeping interval (dial scheduling, retries).
    public var tickInterval: TimeInterval = 0.5
    /// Delay before re-creating the listener / browser after a failure.
    public var restartDelay: TimeInterval = 3

    public init() {}

    public static let standard = PeerLinkTiming()
}

/// A host:port the hub dials directly (without Bonjour).
public struct PeerAddress: Hashable, Sendable, CustomStringConvertible {
    public var host: String
    public var port: UInt16
    /// The address exists only on the Thunderbolt bridge (derived from the static-IP plan): dial it
    /// through the bridge interface when known, never out of the default route (Wi‑Fi / VPN) — e.g. while
    /// this Mac's bridge is still self-assigned 169.254.x.x, 10.77.0.x is not on-link.
    public var viaBridge: Bool

    public init(host: String, port: UInt16, viaBridge: Bool = false) {
        self.host = host
        self.port = port
        self.viaBridge = viaBridge
    }

    public var description: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
}

/// Everything `PeerLinkModule` reads from the environment, injectable so two hubs can run in one process.
public struct PeerLinkConfiguration {
    /// UserDefaults holding `peerlink.settings` and `peerlink.deviceID`.
    public var defaults: UserDefaults
    /// Overrides the persisted random device id (not persisted).
    public var deviceID: String?
    /// Overrides the computer name.
    public var deviceName: String?
    /// Written into the settings at init when non-nil.
    public var passcode: String?
    /// Written into the settings at init when non-nil.
    public var port: UInt16?
    /// Written into the settings at init when non-nil.
    public var interfacePolicy: InterfacePolicy?
    /// Bonjour service type; tests use e.g. "_oneswitch-test._tcp".
    public var serviceType: String
    /// Advertise and browse with Bonjour.
    public var bonjourEnabled: Bool
    /// Explicit direct-dial targets. When nil they are derived from the settings (对方 IP / static IP).
    public var directPeers: [PeerAddress]?
    /// Read / configure the Thunderbolt Bridge network service (networksetup). Off in self-checks and,
    /// by default, in extra profiles (`--profile B`), which share this Mac's bridge with the main instance.
    public var manageThunderboltBridge: Bool
    /// Treat this Mac as a laptop for the default static IP (default: `AppEnvironment.isLaptop`).
    public var isLaptop: Bool
    public var timing: PeerLinkTiming
    /// Settings edits (e.g. typing the 配对码) are applied after this quiet period.
    public var settingsDebounce: TimeInterval
    /// Identifies this Mac's hardware for the persisted device id (nil = derive from IOPlatformUUID).
    /// A device id restored onto a different Mac (Migration Assistant / Time Machine copy the
    /// preferences) is replaced, otherwise both Macs would share one id and never link.
    public var hardwareID: String?

    public init(defaults: UserDefaults = AppEnvironment.defaults,
                deviceID: String? = nil,
                deviceName: String? = nil,
                passcode: String? = nil,
                port: UInt16? = nil,
                interfacePolicy: InterfacePolicy? = nil,
                serviceType: String = PeerLinkDefaults.serviceType,
                bonjourEnabled: Bool = true,
                directPeers: [PeerAddress]? = nil,
                manageThunderboltBridge: Bool = AppEnvironment.profile == nil,
                isLaptop: Bool = AppEnvironment.isLaptop,
                timing: PeerLinkTiming = .standard,
                settingsDebounce: TimeInterval = 0.8,
                hardwareID: String? = nil) {
        self.hardwareID = hardwareID
        self.defaults = defaults
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.passcode = passcode
        self.port = port
        self.interfacePolicy = interfacePolicy
        self.serviceType = serviceType
        self.bonjourEnabled = bonjourEnabled
        self.directPeers = directPeers
        self.manageThunderboltBridge = manageThunderboltBridge
        self.isLaptop = isLaptop
        self.timing = timing
        self.settingsDebounce = settingsDebounce
    }
}

/// 配对码 helpers.
public enum Passcode {
    /// No 0/O, 1/I/L — easy to read aloud and type on the other Mac.
    public static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    public static func generate(length: Int = 8) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// Leading / trailing whitespace is ignored (copy & paste friendliness), and full-width characters
    /// typed with a Chinese input method (“ＡＢＣ２３４”, full-width space) count as their ASCII forms
    /// (Unicode NFKC) — otherwise two visually identical 配对码 would never pair. ASCII is unchanged.
    public static func normalize(_ raw: String) -> String {
        raw.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Exponential backoff 1 s → 30 s.
struct Backoff: Equatable {
    let initial: TimeInterval
    let maximum: TimeInterval
    private(set) var current: TimeInterval

    init(initial: TimeInterval, maximum: TimeInterval) {
        self.initial = initial
        self.maximum = max(initial, maximum)
        self.current = initial
    }

    /// Returns the delay to wait now and doubles the next one.
    mutating func next() -> TimeInterval {
        let delay = current
        current = min(maximum, current * 2)
        return delay
    }

    mutating func reset() { current = initial }
}

/// Pure decision rules of the dialing protocol (unit-tested in PeerLinkCheck).
enum DialRules {
    /// Dial immediately when we have the smaller id; otherwise only after `asymmetricDelay` without success.
    static func shouldDial(localID: String, peerID: String?, waited: TimeInterval, asymmetricDelay: TimeInterval) -> Bool {
        guard let peerID else { return true }
        return localID < peerID || waited >= asymmetricDelay
    }

    enum IncomingDecision: Equatable {
        case accept(replacing: Bool, cancelOutgoing: Bool)
        /// Our own dial for the service is still connecting and we have the smaller id: hold the incoming
        /// hello until our dial either reaches the handshake (then reject it) or fails (then accept it).
        case park
        case reject(RejectReason)
    }

    /// Decides what to do with an incoming hello for a registered service. Guarantees that when both
    /// Macs dial the same service at once, the connection initiated by the smaller device id survives
    /// on both sides.
    /// - `established`: the live channel for the service (its id and the peer instance that formed it).
    /// - `outgoingHelloSent`: nil when we have no dial in progress for the service; otherwise whether our
    ///   own hello was already sent on it.
    static func decideIncoming(localID: String,
                               hello: HelloMessage,
                               established: (channelID: String, peerInstanceID: String)?,
                               outgoingHelloSent: Bool?) -> IncomingDecision {
        var replacing = false
        if let established {
            let peerLostIt = hello.lastChannelID == established.channelID
            let peerRestarted = hello.instanceID != established.peerInstanceID
            guard peerLostIt || peerRestarted else { return .reject(.duplicate) }
            replacing = true
        }
        var cancelOutgoing = false
        if let helloSent = outgoingHelloSent {
            if localID < hello.deviceID {
                // Our dial wins; if it is still connecting, wait for it instead of giving up.
                return helloSent ? .reject(.duplicate) : .park
            }
            cancelOutgoing = true
        }
        return .accept(replacing: replacing, cancelOutgoing: cancelOutgoing)
    }
}
