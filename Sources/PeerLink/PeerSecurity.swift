import Foundation
import Network
import CryptoKit
import Security
import OneSwitchCore

/// Transport security: TLS 1.2 with a pre-shared key derived from the 配对码 (the approach of Apple's
/// TicTacToe Network.framework sample). Both Macs derive the same PSK from the same passcode; with a
/// different passcode the TLS handshake fails with a bad-MAC error, so no channel is ever formed.
/// Verified on macOS 27 with a loopback test (negotiates TLS 1.2 / TLS_PSK_WITH_AES_128_GCM_SHA256).
enum PeerSecurity {
    static let pskLabel = "OneSwitch-PSK-v1"
    static let pskIdentity = "OneSwitch"

    /// PSK = HMAC-SHA256(key: passcode UTF-8, data: "OneSwitch-PSK-v1").
    static func preSharedKey(passcode: String) -> Data {
        let key = SymmetricKey(data: Data(passcode.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(pskLabel.utf8), using: key)
        return Data(mac)
    }

    static func tlsOptions(passcode: String) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let sec = options.securityProtocolOptions
        let psk = preSharedKey(passcode: passcode).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, psk as __DispatchData, identity as __DispatchData)
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
            sec_protocol_options_append_tls_ciphersuite(sec, suite)
        }
        // PSK cipher suites exist only in TLS 1.2; pin the version so negotiation is deterministic.
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        return options
    }

    static func tcpOptions(timing: PeerLinkTiming) -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true                // critical for keyboard / mouse latency
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 3
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = max(1, Int(timing.connectTimeout.rounded()))
        return tcp
    }

    static func parameters(passcode: String, timing: PeerLinkTiming, requiredInterface: NWInterface? = nil) -> NWParameters {
        let params = NWParameters(tls: tlsOptions(passcode: passcode), tcp: tcpOptions(timing: timing))
        params.includePeerToPeer = false
        params.serviceClass = .responsiveData
        if let requiredInterface { params.requiredInterface = requiredInterface }
        return params
    }
}

/// Why a connection attempt / channel failed, reduced to what the UI and dial logic care about.
enum LinkFailure: Equatable, Sendable {
    case authentication            // TLS-PSK mismatch → different 配对码
    case localNetworkDenied        // macOS “本地网络” privacy permission missing
    case refused
    case unreachable
    case timeout
    case notThunderbolt            // interface policy “仅雷雳网桥” violated
    case protocolViolation(String)
    case other(String)

    /// kDNSServiceErr_PolicyDenied
    static let dnsPolicyDenied: Int32 = -65570

    /// TLS alert / record errors that mean “the peer's key differs from ours”.
    static let authenticationStatuses: Set<OSStatus> = [
        errSSLBadRecordMac, errSSLPeerBadRecordMac, errSSLDecryptionFail, errSSLPeerDecryptionFail,
        errSSLPeerDecryptError, errSSLPeerHandshakeFail, errSSLPeerAuthCompleted, errSSLPeerAccessDenied,
        errSSLPeerInsufficientSecurity,
    ]

    static func classify(_ error: NWError, unsatisfiedReason: NWPath.UnsatisfiedReason? = nil) -> LinkFailure {
        if unsatisfiedReason == .localNetworkDenied { return .localNetworkDenied }
        switch error {
        case .tls(let status):
            return authenticationStatuses.contains(status) ? .authentication : .other("TLS \(status)")
        case .dns(let code):
            return Int32(code) == dnsPolicyDenied ? .localNetworkDenied : .other("DNS \(code)")
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return .refused
            case .ETIMEDOUT: return .timeout
            case .ENETUNREACH, .EHOSTUNREACH, .ENETDOWN, .EHOSTDOWN, .EADDRNOTAVAIL: return .unreachable
            default: return .other(error.debugDescription)
            }
        default:
            return .other(error.debugDescription)
        }
    }

    var peerLinkError: PeerLinkError {
        switch self {
        case .authentication: return .authenticationFailed
        case .timeout: return .timeout
        case .protocolViolation(let s): return .protocolViolation(s)
        case .localNetworkDenied: return .network("未获得本地网络权限")
        case .refused: return .network("连接被拒绝")
        case .unreachable: return .network("无法访问对方")
        case .notThunderbolt: return .network("连接未经过雷雳网桥")
        case .other(let s): return .network(s)
        }
    }

    var logDescription: String {
        switch self {
        case .authentication: return "authentication failed (passcode mismatch)"
        case .localNetworkDenied: return "local network access denied"
        case .refused: return "connection refused"
        case .unreachable: return "unreachable"
        case .timeout: return "timeout"
        case .notThunderbolt: return "not via Thunderbolt bridge"
        case .protocolViolation(let s): return "protocol violation: \(s)"
        case .other(let s): return s
        }
    }
}
