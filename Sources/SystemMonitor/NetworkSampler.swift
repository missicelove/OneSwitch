import Darwin
import Foundation
import SystemConfiguration

/// Seconds on a monotonic clock that keeps running while the Mac sleeps.
func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
}

/// 64-bit per-interface byte counters from sysctl {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0}.
struct InterfaceCounters: Equatable, Sendable {
    var index: Int
    var name: String
    var flags: UInt32
    var bytesIn: UInt64
    var bytesOut: UInt64
}

enum IfList2 {
    static let headerSize = MemoryLayout<if_msghdr2>.size
    static let flagsOffset = MemoryLayout<if_msghdr2>.offset(of: \if_msghdr2.ifm_flags)!
    static let indexOffset = MemoryLayout<if_msghdr2>.offset(of: \if_msghdr2.ifm_index)!
    static let dataOffset = MemoryLayout<if_msghdr2>.offset(of: \if_msghdr2.ifm_data)!
    static let ibytesOffset = dataOffset + MemoryLayout<if_data64>.offset(of: \if_data64.ifi_ibytes)!
    static let obytesOffset = dataOffset + MemoryLayout<if_data64>.offset(of: \if_data64.ifi_obytes)!

    /// Reads the kernel's interface list. Returns nil when the sysctl fails.
    static func read() -> [InterfaceCounters]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        for _ in 0..<3 { // the list can grow between the size probe and the read
            var length = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
            length += 2048
            var buffer = [UInt8](repeating: 0, count: length)
            let rc = buffer.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &length, nil, 0) }
            if rc == 0 {
                return buffer.withUnsafeBytes { parse(UnsafeRawBufferPointer(rebasing: $0[0..<min(length, $0.count)])) }
            }
            if errno != ENOMEM { return nil }
        }
        return nil
    }

    /// Parses a NET_RT_IFLIST2 buffer: a sequence of routing messages; RTM_IFINFO2 messages carry an
    /// `if_msghdr2` (with `if_data64` counters) followed by the interface's `sockaddr_dl`.
    static func parse(_ buf: UnsafeRawBufferPointer) -> [InterfaceCounters] {
        var result: [InterfaceCounters] = []
        var offset = 0
        while offset + 4 <= buf.count {
            let msgLen = Int(buf.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            guard msgLen >= 4, offset + msgLen <= buf.count else { break }
            let type = Int32(buf[offset + 3])
            if type == RTM_IFINFO2, msgLen >= headerSize {
                let flags = UInt32(bitPattern: buf.loadUnaligned(fromByteOffset: offset + flagsOffset, as: Int32.self))
                let index = Int(buf.loadUnaligned(fromByteOffset: offset + indexOffset, as: UInt16.self))
                let ibytes = buf.loadUnaligned(fromByteOffset: offset + ibytesOffset, as: UInt64.self)
                let obytes = buf.loadUnaligned(fromByteOffset: offset + obytesOffset, as: UInt64.self)
                var name = linkName(buf, sdlOffset: offset + headerSize, end: offset + msgLen)
                if name == nil {
                    var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(index), &nameBuf) != nil { name = String(cString: nameBuf) }
                }
                if let name, !name.isEmpty {
                    result.append(InterfaceCounters(index: index, name: name, flags: flags, bytesIn: ibytes, bytesOut: obytes))
                }
            }
            offset += msgLen
        }
        return result
    }

    /// Interface name from the `sockaddr_dl` that follows the header (sdl_len, sdl_family, sdl_index,
    /// sdl_type, sdl_nlen, sdl_alen, sdl_slen, sdl_data…).
    private static func linkName(_ buf: UnsafeRawBufferPointer, sdlOffset: Int, end: Int) -> String? {
        guard sdlOffset + 8 <= end else { return nil }
        let sdlLen = Int(buf[sdlOffset])
        guard sdlLen >= 8, Int32(buf[sdlOffset + 1]) == AF_LINK else { return nil }
        let nameLen = Int(buf[sdlOffset + 5])
        let start = sdlOffset + 8
        guard nameLen > 0, start + nameLen <= min(end, sdlOffset + sdlLen) else { return nil }
        return String(decoding: UnsafeRawBufferPointer(rebasing: buf[start ..< start + nameLen]), as: UTF8.self)
    }
}

/// Network throughput. Confined to the sampler queue.
final class NetworkSampler {
    /// BSD-name prefixes never counted: loopback, VPN tunnels, AWDL / low-latency WLAN, Apple private
    /// links, legacy tunnels, the Wi‑Fi access-point interface and PPP/IPsec (tunnelled traffic would be
    /// counted twice).
    static let excludedPrefixes = ["lo", "utun", "awdl", "llw", "anpi", "gif", "stf", "ap", "ipsec", "ppp", "pktap", "iptap"]

    private var previous: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var previousTime: Double?
    private var lastRates: [String: (up: Double, down: Double)] = [:]
    private let namer = InterfaceNamer()

    func reset() {
        previous = [:]
        previousTime = nil
        lastRates = [:]
    }

    /// Interfaces that count towards 全部接口: up, carrying an IPv4/IPv6 address, not excluded.
    /// Bridge member ports have no address, so bridge0 is counted once. VM bridges (bridge100+) are
    /// NAT'ed through a physical interface and therefore excluded as well.
    static func isCounted(name: String, flags: UInt32, hasAddress: Bool) -> Bool {
        guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0, hasAddress else { return false }
        if excludedPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
        if name.hasPrefix("bridge"), let n = Int(name.dropFirst("bridge".count)), n >= 100 { return false }
        return true
    }

    /// Names of interfaces that currently have an AF_INET or AF_INET6 address.
    static func interfacesWithAddresses() -> Set<String> {
        var result = Set<String>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            if let addr = ifa.pointee.ifa_addr {
                let family = Int32(addr.pointee.sa_family)
                if family == AF_INET || family == AF_INET6 {
                    result.insert(String(cString: ifa.pointee.ifa_name))
                }
            }
            cursor = ifa.pointee.ifa_next
        }
        return result
    }

    func sample(selection: String) -> NetworkReading? {
        guard let counters = IfList2.read() else { return nil }
        let addressed = Self.interfacesWithAddresses()
        let now = monotonicSeconds()
        let elapsed = previousTime.map { now - $0 }
        // Too short a window (e.g. an extra pass right after a settings change) gives noisy rates:
        // keep the previous baseline and rates.
        let updateRates = elapsed.map { $0 >= 0.25 } ?? true

        var rows: [InterfaceRate] = []
        var newPrevious: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        var selected: InterfaceCounters?
        for c in counters {
            newPrevious[c.name] = (c.bytesIn, c.bytesOut)
            if c.name == selection { selected = c }
            guard Self.isCounted(name: c.name, flags: c.flags, hasAddress: addressed.contains(c.name)) else { continue }
            rows.append(InterfaceRate(bsdName: c.name, label: namer.label(for: c.name), up: 0, down: 0,
                                      bytesIn: c.bytesIn, bytesOut: c.bytesOut))
        }
        // Rates for counted interfaces plus the explicitly selected one (even if it is not counted).
        var rates: [String: (up: Double, down: Double)] = [:]
        if updateRates {
            for c in counters {
                guard let elapsed, elapsed > 0, let prev = previous[c.name] else {
                    rates[c.name] = (0, 0)
                    continue
                }
                // A counter that went backwards means the interface was re-created: count 0 this pass.
                let dIn = c.bytesIn >= prev.bytesIn ? Double(c.bytesIn - prev.bytesIn) : 0
                let dOut = c.bytesOut >= prev.bytesOut ? Double(c.bytesOut - prev.bytesOut) : 0
                rates[c.name] = (dOut / elapsed, dIn / elapsed)
            }
            previous = newPrevious
            previousTime = now
            lastRates = rates
        } else {
            rates = lastRates
        }
        for i in rows.indices {
            let r = rates[rows[i].bsdName] ?? (0, 0)
            rows[i].up = r.up
            rows[i].down = r.down
        }
        rows.sort { ($0.label, $0.bsdName) < ($1.label, $1.bsdName) }

        if !selection.isEmpty {
            let r = rates[selection] ?? (0, 0)
            let label = selected.map { namer.label(for: $0.name) } ?? selection
            return NetworkReading(up: r.up, down: r.down,
                                  bytesIn: selected?.bytesIn ?? 0, bytesOut: selected?.bytesOut ?? 0,
                                  interfaces: rows, selection: selection, selectionLabel: label)
        }
        return NetworkReading(up: rows.reduce(0) { $0 + $1.up }, down: rows.reduce(0) { $0 + $1.down },
                              bytesIn: rows.reduce(0) { $0 &+ $1.bytesIn }, bytesOut: rows.reduce(0) { $0 &+ $1.bytesOut },
                              interfaces: rows, selection: "", selectionLabel: "全部接口")
    }

    /// Chinese label for an interface (cached SystemConfiguration lookup).
    func label(for bsdName: String) -> String { namer.label(for: bsdName) }
}

/// Maps BSD names to Chinese labels via SCNetworkInterfaceCopyAll. Confined to the sampler queue.
final class InterfaceNamer {
    private var labels: [String: String] = [:]
    private var lastRefresh: Double = -.infinity

    func label(for bsdName: String) -> String {
        if labels[bsdName] == nil, monotonicSeconds() - lastRefresh > 30 { refresh() }
        return labels[bsdName] ?? Self.label(bsdName: bsdName, type: nil, displayName: nil)
    }

    private func refresh() {
        lastRefresh = monotonicSeconds()
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return }
        var map: [String: String] = [:]
        for iface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            map[bsd] = Self.label(bsdName: bsd,
                                  type: SCNetworkInterfaceGetInterfaceType(iface) as String?,
                                  displayName: SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?)
        }
        labels = map
    }

    /// Pure mapping (exposed for checks). SystemConfiguration names are often English in a helper
    /// process, so the common kinds are translated here.
    static func label(bsdName: String, type: String?, displayName: String?) -> String {
        if bsdName.hasPrefix("bridge") { return "雷雳网桥" }
        let display = displayName?.trimmingCharacters(in: .whitespaces) ?? ""
        if type == (kSCNetworkInterfaceTypeIEEE80211 as String) { return "Wi\u{2011}Fi" }
        if display.hasPrefix("Thunderbolt") || display.hasPrefix("雷雳") {
            let suffix = display.split(separator: " ").last.flatMap { Int($0) }
            if display.contains("Bridge") || display.contains("网桥") { return "雷雳网桥" }
            return suffix.map { "雷雳 \($0)" } ?? "雷雳"
        }
        if type == (kSCNetworkInterfaceTypeEthernet as String) {
            if display.contains("USB") || display.contains("iPhone") || display.contains("iPad") { return display }
            if display.hasPrefix("Ethernet Adapter") || display.hasPrefix("以太网适配器") { return "以太网适配器" }
            return "以太网"
        }
        if !display.isEmpty { return display }
        return bsdName
    }
}
