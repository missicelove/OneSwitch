import Foundation
import Combine

// MARK: - Peer link contract
//
// The two Macs (Mac Studio ⇄ MacBook Pro) are linked by the PeerLink module over the Thunderbolt
// Bridge network. Features (文件同步 = service "sync", 键鼠共享 = service "input") never touch sockets:
// they register a *service* on the `PeerHub` and receive a `PeerChannel` whenever a connection for
// that service is established with the paired peer.
//
// Guarantees of every PeerChannel implementation:
// - Reliable, ordered, message-framed, encrypted & authenticated (paired by a shared 配对码).
// - One TCP connection per service, so a bulk file transfer never delays keyboard/mouse events.
// - `send` is thread-safe and non-blocking; `completion` fires once the payload has been handed to
//   the network stack (use it for flow control on bulk transfers), or with an error. Completions run
//   on an unspecified background queue and must not block.
// - Nothing is delivered until `setHandlers` is called; messages that arrive earlier are buffered.
// - `onMessage` / `onClose` run on the queue passed to `setHandlers` (pass a *serial* queue).
// - `onClose` is delivered exactly once, after the last `onMessage`.
// - Max payload size is `PeerLimits.maxPayloadSize`; larger sends fail with `.payloadTooLarge`.
// - Message `type` values 0xFF00...0xFFFF are reserved for PeerLink internals (hello, heartbeat…);
//   services must only use `PeerLimits.serviceTypeRange` and never see reserved types in `onMessage`.

public enum PeerLimits {
    /// Maximum payload of a single message (16 MiB). Chunk bigger data.
    public static let maxPayloadSize = 16 * 1024 * 1024
    /// Message types available to services. 0xFF00...0xFFFF are reserved for PeerLink internals.
    public static let serviceTypeRange: ClosedRange<UInt16> = 0x0000...0xFEFF
}

public struct PeerInfo: Hashable, Sendable, Codable {
    /// Stable random id of the remote installation.
    public var deviceID: String
    /// Human-readable computer name, e.g. "Mac Studio".
    public var name: String
    /// Remote IP address used, for display ("169.254.10.20", "10.10.10.2", "127.0.0.1").
    public var address: String?
    /// True when the connection runs over the Thunderbolt Bridge interface.
    public var viaThunderbolt: Bool

    public init(deviceID: String, name: String, address: String? = nil, viaThunderbolt: Bool = false) {
        self.deviceID = deviceID
        self.name = name
        self.address = address
        self.viaThunderbolt = viaThunderbolt
    }
}

public enum PeerLinkStatus: Equatable, Sendable {
    /// Link is off (not enabled, no 配对码, or no service registered). `reason` is user-facing Chinese.
    case disabled(reason: String)
    /// Listening / browsing, peer not connected yet.
    case searching
    /// At least one channel is open (or the peer handshake succeeded).
    case connected(PeerInfo)
    /// Persistent problem, user-facing Chinese message (e.g. "配对码不匹配").
    case error(String)

    public var connectedPeer: PeerInfo? {
        if case .connected(let p) = self { return p }
        return nil
    }

    public var displayText: String {
        switch self {
        case .disabled(let reason): return reason
        case .searching: return "正在查找另一台 Mac…"
        case .connected(let p): return "已连接 \(p.name)" + (p.viaThunderbolt ? "（雷雳）" : "")
        case .error(let msg): return msg
        }
    }
}

public enum PeerLinkError: Error, LocalizedError, Sendable, Equatable {
    case closed
    case closedByPeer
    case payloadTooLarge(Int)
    case notConnected
    case authenticationFailed
    case timeout
    case protocolViolation(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .closed: return "连接已关闭"
        case .closedByPeer: return "对方关闭了连接"
        case .payloadTooLarge(let n): return "消息过大（\(n) 字节）"
        case .notConnected: return "未连接"
        case .authenticationFailed: return "认证失败（请检查两台 Mac 的配对码是否一致）"
        case .timeout: return "连接超时"
        case .protocolViolation(let s): return "协议错误：\(s)"
        case .network(let s): return "网络错误：\(s)"
        }
    }
}

/// A bidirectional message channel for one service to the paired peer. See guarantees above.
public protocol PeerChannel: AnyObject, Sendable {
    var service: String { get }
    var peer: PeerInfo { get }
    var isOpen: Bool { get }

    func setHandlers(queue: DispatchQueue,
                     onMessage: @escaping @Sendable (_ type: UInt16, _ payload: Data) -> Void,
                     onClose: @escaping @Sendable (_ error: Error?) -> Void)

    func send(type: UInt16, payload: Data, completion: (@Sendable (Error?) -> Void)?)

    /// Closes the channel. The local `onClose` fires (with nil error); the peer's `onClose` fires too.
    func close()
}

public extension PeerChannel {
    func send(type: UInt16, payload: Data) {
        send(type: type, payload: payload, completion: nil)
    }

    /// Awaits until the payload is handed to the network stack (natural back-pressure for bulk data).
    func sendAndWait(type: UInt16, payload: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            send(type: type, payload: payload) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    /// Encodes `value` as JSON and sends it.
    func send<T: Encodable>(type: UInt16, json value: T, completion: (@Sendable (Error?) -> Void)? = nil) throws {
        let data = try JSONEncoder().encode(value)
        send(type: type, payload: data, completion: completion)
    }
}

/// The paired-peer connection manager (implemented by the PeerLink module; `LoopbackPeerHub` for tests).
@MainActor
public protocol PeerHub: AnyObject {
    var localDeviceID: String { get }
    var localDeviceName: String { get }

    /// Current link status. Also published via `statusPublisher` (emits the current value on subscribe).
    var status: PeerLinkStatus { get }
    var statusPublisher: AnyPublisher<PeerLinkStatus, Never> { get }

    /// Registers a service. Whenever a channel for `service` is established with the paired peer,
    /// `onChannel` is invoked on the main actor. The hub keeps (re)connecting while registered.
    /// At most one live channel per service: before a replacement channel is handed out, the previous
    /// one is closed. Channels only form when *both* Macs registered the same service.
    /// Calling `register` again for the same service replaces the handler.
    func register(service: String, onChannel: @escaping @MainActor (PeerChannel) -> Void)

    /// Unregisters a service and closes its channel (if any).
    func unregister(service: String)
}
