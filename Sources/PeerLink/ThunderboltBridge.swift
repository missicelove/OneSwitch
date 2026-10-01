import Foundation
import Darwin

/// Pure helpers around the Thunderbolt Bridge network service: `networksetup` output parsers, safe
/// command builders, address math, and interface enumeration via getifaddrs / SIOCGIFMEDIA.
/// Nothing in this file changes system state.
enum ThunderboltBridge {
    static let defaultDevice = "bridge0"
    static let networksetupPath = "/usr/sbin/networksetup"

    /// bridge0…bridge99 are Thunderbolt bridges; bridge100+ are created by Internet Sharing / VMs.
    static func isThunderboltInterface(_ name: String) -> Bool {
        guard name.hasPrefix("bridge") else { return false }
        guard let n = Int(name.dropFirst("bridge".count)) else { return false }
        return n < 100
    }

    // MARK: - networksetup -listnetworkserviceorder

    struct NetworkService: Equatable, Sendable {
        var name: String
        var hardwarePort: String
        var device: String
        var enabled: Bool
        var order: Int?
    }

    /// Parses `networksetup -listnetworkserviceorder`, e.g.
    /// ```
    /// (2) Thunderbolt Bridge
    /// (Hardware Port: Thunderbolt Bridge, Device: bridge0)
    /// (*) 000美国专线-[全局模式]
    /// (Hardware Port: com.cisco.anyconnect, Device: )
    /// ```
    static func parseServiceOrder(_ output: String) -> [NetworkService] {
        var result: [NetworkService] = []
        var current: (name: String, enabled: Bool, order: Int?)?
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("(") else { current = nil; continue }
            if line.hasPrefix("(Hardware Port:"), line.hasSuffix(")") {
                guard let svc = current else { continue }
                let inner = line.dropFirst("(Hardware Port:".count).dropLast()
                let port: String
                let device: String
                if let r = inner.range(of: ", Device:", options: .backwards) {
                    port = inner[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
                    device = inner[r.upperBound...].trimmingCharacters(in: .whitespaces)
                } else {
                    port = inner.trimmingCharacters(in: .whitespaces)
                    device = ""
                }
                result.append(NetworkService(name: svc.name, hardwarePort: port, device: device,
                                             enabled: svc.enabled, order: svc.order))
                current = nil
                continue
            }
            // "(N) Name" or "(*) Name"
            guard let close = line.firstIndex(of: ")") else { current = nil; continue }
            let marker = line[line.index(after: line.startIndex)..<close]
            let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { current = nil; continue }
            if marker == "*" {
                current = (name, false, nil)
            } else if let n = Int(marker) {
                current = (name, true, n)
            } else {
                current = nil
            }
        }
        return result
    }

    /// The service bound to the Thunderbolt bridge: matched by device (bridge0 by default), falling back
    /// to the hardware port name. Never relies on the (possibly localized) service name.
    static func thunderboltService(in services: [NetworkService], preferredDevice: String = defaultDevice) -> NetworkService? {
        if let s = services.first(where: { $0.device == preferredDevice }) { return s }
        return services.first { s in
            let port = s.hardwarePort.lowercased()
            return (port.contains("thunderbolt") || s.hardwarePort.contains("雷雳")) && isThunderboltInterface(s.device)
        }
    }

    // MARK: - networksetup -getinfo

    enum ConfigMethod: Equatable, Sendable {
        case dhcp
        case manual
        case manualWithDHCPRouter
        case bootp
        case off
        case unknown(String)

        var displayName: String {
            switch self {
            case .dhcp: return "自动（DHCP）"
            case .manual: return "手动"
            case .manualWithDHCPRouter: return "手动地址 + DHCP 路由器"
            case .bootp: return "BOOTP"
            case .off: return "已关闭"
            case .unknown(let s): return s.isEmpty ? "未知" : s
            }
        }
    }

    struct ServiceIPConfig: Equatable, Sendable {
        var method: ConfigMethod
        var ipAddress: String?
        var subnetMask: String?
        var router: String?
    }

    /// Parses `networksetup -getinfo <service>`. Returns nil for error output.
    static func parseServiceInfo(_ output: String) -> ServiceIPConfig? {
        var method: ConfigMethod?
        var ip: String?
        var mask: String?
        var router: String?
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("** Error") || line.hasPrefix("Error") { return nil }
            if method == nil {
                switch line {
                case "DHCP Configuration": method = .dhcp; continue
                case "Manual Configuration": method = .manual; continue
                case "Manually Using DHCP Router Configuration": method = .manualWithDHCPRouter; continue
                case "BOOTP Configuration": method = .bootp; continue
                default:
                    if line.hasSuffix("Configuration") && !line.contains(":") {
                        method = .unknown(line)
                        continue
                    }
                    if line.lowercased().hasPrefix("ipv4 is off") || line.lowercased() == "ipv4: off" {
                        method = .off
                        continue
                    }
                }
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let v: String? = (value.isEmpty || value == "(null)" || value == "none") ? nil : value
            switch key {
            case "IP address": if ip == nil { ip = v }
            case "Subnet mask": if mask == nil { mask = v }
            case "Router": if router == nil { router = v }
            default: break
            }
        }
        guard let method else {
            return (ip == nil && mask == nil) ? nil : ServiceIPConfig(method: .unknown(""), ipAddress: ip, subnetMask: mask, router: router)
        }
        return ServiceIPConfig(method: method, ipAddress: ip, subnetMask: mask, router: router)
    }

    /// True when the service is already manual with exactly this address and mask and *no router*.
    /// A router on the bridge would make it a default-route candidate (on the MacBook Pro the bridge is
    /// first in the service order, so all traffic would go to the other Mac); `-setmanual` without a
    /// router replaces the whole IPv4 configuration and removes it.
    static func isConfigured(_ config: ServiceIPConfig?, ip: String, mask: String) -> Bool {
        guard let config, config.method == .manual else { return false }
        return config.ipAddress == ip && config.subnetMask == mask && config.router == nil
    }

    // MARK: - Command builders (never executed by self-checks)

    enum CommandError: Error, Equatable {
        case invalidServiceName
        case invalidAddress(String)
        case invalidMask(String)
    }

    /// POSIX shell single-quoting: `it's` → `'it'\''s'`.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript string literal body escaping (backslash and double quote).
    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func validateServiceName(_ name: String) throws {
        let bad = CharacterSet.newlines.union(CharacterSet(charactersIn: "\0"))
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              name.rangeOfCharacter(from: bad) == nil else { throw CommandError.invalidServiceName }
    }

    /// `/usr/sbin/networksetup -setmanual '<service>' <ip> <mask>` — no router, so no default route.
    static func setManualCommand(service: String, ip: String, mask: String) throws -> String {
        try validateServiceName(service)
        guard IPv4.parse(ip) != nil else { throw CommandError.invalidAddress(ip) }
        guard IPv4.isValidMask(mask) else { throw CommandError.invalidMask(mask) }
        return "\(networksetupPath) -setmanual \(shellQuote(service)) \(ip) \(mask)"
    }

    /// `/usr/sbin/networksetup -setnetworkserviceenabled '<service>' on`
    static func enableServiceCommand(service: String) throws -> String {
        try validateServiceName(service)
        return "\(networksetupPath) -setnetworkserviceenabled \(shellQuote(service)) on"
    }

    /// `/usr/sbin/networksetup -setdhcp '<service>'`
    static func setDHCPCommand(service: String) throws -> String {
        try validateServiceName(service)
        return "\(networksetupPath) -setdhcp \(shellQuote(service))"
    }

    /// `do shell script "<command>" with prompt "<prompt>" with administrator privileges`
    static func privilegedAppleScript(command: String, prompt: String) -> String {
        "do shell script \"\(appleScriptEscape(command))\" with prompt \"\(appleScriptEscape(prompt))\" with administrator privileges"
    }

    // MARK: - Addressing

    /// The other end of the point-to-point /24: .1 ⇄ .2. nil for any other host number.
    static func derivePeerIP(from local: String) -> String? {
        guard let octets = IPv4.parse(local) else { return nil }
        switch octets[3] {
        case 1: return "\(octets[0]).\(octets[1]).\(octets[2]).2"
        case 2: return "\(octets[0]).\(octets[1]).\(octets[2]).1"
        default: return nil
        }
    }

    // MARK: - Interfaces

    struct InterfaceAddress: Equatable, Sendable {
        var name: String
        var address: String
        var netmask: String?
        var isUp: Bool
        var isRunning: Bool
    }

    /// All IPv4 addresses (getifaddrs).
    static func ipv4Addresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            let flags = Int32(ifa.pointee.ifa_flags)
            result.append(InterfaceAddress(name: name,
                                           address: numericHost(sa) ?? "",
                                           netmask: ifa.pointee.ifa_netmask.flatMap(numericHost),
                                           isUp: flags & IFF_UP != 0,
                                           isRunning: flags & IFF_RUNNING != 0))
        }
        return result
    }

    private static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(sa.pointee.sa_len)
        guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }

    /// Link state from SIOCGIFMEDIA (what `ifconfig` prints as "status: active"). A bridge is active when
    /// at least one member port has a link, i.e. the Thunderbolt cable is plugged into a peer.
    /// nil when the interface does not exist or reports no media status.
    static func isLinkActive(_ interface: String) -> Bool? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var req = ifmediareq()
        let nameBytes = Array(interface.utf8.prefix(Int(IFNAMSIZ) - 1))
        withUnsafeMutableBytes(of: &req.ifm_name) { buf in
            for (i, b) in nameBytes.enumerated() { buf[i] = b }
        }
        // SIOCGIFMEDIA = _IOWR('i', 56, struct ifmediareq)
        let size = UInt(MemoryLayout<ifmediareq>.size) & 0x1FFF
        let request: UInt = 0xC000_0000 | (size << 16) | (UInt(UInt8(ascii: "i")) << 8) | 56
        guard ioctl(fd, request, &req) == 0 else { return nil }
        let IFM_AVALID: Int32 = 0x1, IFM_ACTIVE: Int32 = 0x2
        guard req.ifm_status & IFM_AVALID != 0 else { return nil }
        return req.ifm_status & IFM_ACTIVE != 0
    }
}

/// Minimal IPv4 helpers for validation / display.
enum IPv4 {
    static func parse(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for p in parts {
            // No leading zeros: inet_aton (used by networksetup / ifconfig) reads "010" as octal 8, so
            // "10.77.0.010" would be applied as 10.77.0.8 and never match the setting again.
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber),
                  p.count == 1 || p.first != "0",
                  let v = Int(p), (0...255).contains(v) else { return nil }
            octets.append(v)
        }
        return octets
    }

    static func isValidHost(_ s: String) -> Bool {
        guard let o = parse(s) else { return false }
        return o[0] != 0 && o[0] < 224 && o[3] != 0 && o[3] != 255
    }

    static func isValidMask(_ s: String) -> Bool {
        guard let o = parse(s) else { return false }
        let value = o.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard value != 0 else { return false }
        // Contiguous ones followed by zeros.
        let inverted = ~value
        return inverted & (inverted &+ 1) == 0
    }

    static func isLinkLocal(_ s: String) -> Bool { s.hasPrefix("169.254.") }
}
