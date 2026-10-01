import AppKit
import SwiftUI
import Foundation
import Network
import CryptoKit
import Security
import OneSwitchCore
@testable import PeerLink

// Self-checks for PeerLink. Exit code 0 = all checks passed.
// Real networking runs over loopback (127.0.0.1) with a test Bonjour type and random ports ≠ 52525.
// Nothing here changes system settings: networksetup commands are only built and parsed, never run.

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message) (line \(line))")
    }
}

/// Spins the main run loop until `condition` is true or `timeout` elapses.
@MainActor
func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    return condition()
}

@MainActor
func spin(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}

/// Collects the channels a hub hands to one service.
final class Probe: @unchecked Sendable {
    let all = Box<[PeerChannel]>([])
    var latest: PeerChannel? { all.value.last }
    var count: Int { all.value.count }
    func add(_ channel: PeerChannel) { all.mutate { $0.append(channel) } }
}

// MARK: - Hub factory

/// Below macOS's ephemeral range (49152+) so no port collides with a TIME_WAIT outgoing connection,
/// and far from the production port 52525.
var nextPort: UInt16 = UInt16.random(in: 30000...40000)
func freshPort() -> UInt16 {
    nextPort += 1
    return nextPort
}

var fastTiming: PeerLinkTiming = {
    var t = PeerLinkTiming()
    t.backoffInitial = 0.2
    t.backoffMax = 2
    t.asymmetricDialDelay = 0.6
    t.directDialDelay = 0.2
    t.tickInterval = 0.1
    t.restartDelay = 0.5
    return t
}()

var suites: [String] = []
var portOwners: [UInt16: String] = [:]

@MainActor
func makeHub(_ tag: String, deviceID: String, port: UInt16, peerPorts: [UInt16], passcode: String? = "check-passcode",
             timing: PeerLinkTiming = fastTiming, bonjour: Bool = false,
             serviceType: String = "_oneswitch-test._tcp", policy: InterfacePolicy = .any) -> PeerLinkModule {
    let suiteName = "oneswitch.peerlinkcheck.\(tag)"
    portOwners[port] = tag
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    suites.append(suiteName)
    let config = PeerLinkConfiguration(defaults: defaults, deviceID: deviceID, deviceName: "Check \(tag)",
                                       passcode: passcode, port: port, interfacePolicy: policy,
                                       serviceType: serviceType, bonjourEnabled: bonjour,
                                       directPeers: peerPorts.map { PeerAddress(host: "127.0.0.1", port: $0) },
                                       manageThunderboltBridge: false, isLaptop: false,
                                       timing: timing, settingsDebounce: 0.05)
    return PeerLinkModule(configuration: config, bridgeSystem: FakeBridgeSystem())
}

// MARK: - Fake OS for the Thunderbolt bridge (records instead of executing)

let serviceOrderSample = """
An asterisk (*) denotes that a network service is disabled.
(1) Ethernet
(Hardware Port: Ethernet, Device: en0)

(2) Thunderbolt Bridge
(Hardware Port: Thunderbolt Bridge, Device: bridge0)

(3) Wi-Fi
(Hardware Port: Wi-Fi, Device: en1)

(*) 000香港专线-[分流模式]
(Hardware Port: com.cisco.anyconnect, Device: )

(6) Tailscale
(Hardware Port: io.tailscale.ipn.macsys, Device: )
"""

let localizedServiceOrderSample = """
An asterisk (*) denotes that a network service is disabled.
(1) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)

(2) 雷雳网桥
(Hardware Port: Thunderbolt Bridge, Device: bridge0)

(3) Bob's "USB" 网卡
(Hardware Port: USB 10/100/1000 LAN, Device: en7)
"""

let dhcpInfoSample = """
DHCP Configuration
IP address: 169.254.34.128
Subnet mask: 255.255.0.0
Router: (null)
Client ID:
IPv6: Automatic
IPv6 IP address: none
IPv6 Router: none
"""

let manualInfoSample = """
Manual Configuration
IP address: 10.77.0.1
Subnet mask: 255.255.255.0
Router: (null)
IPv6: Automatic
IPv6 IP address: none
IPv6 Router: none
"""

final class FakeBridgeSystem: BridgeSystem, @unchecked Sendable {
    let order = Box(localizedServiceOrderSample)
    let info = Box(dhcpInfoSample)
    let privilegedResult = Box(PrivilegedResult.cancelled)
    let commands = Box<[String]>([])
    let prompts = Box<[String]>([])
    let bridgeAddress = Box("169.254.34.128")
    /// When set, `runPrivileged` blocks on it like an open password dialog.
    let gate = Box<DispatchSemaphore?>(nil)
    /// Set by `cancelRunning()` (the real one terminates osascript → `.cancelled`).
    let terminated = Box(false)

    func listServiceOrder() -> String? { order.value }
    func serviceInfo(_ service: String) -> String? { info.value }
    func runPrivileged(command: String, prompt: String) -> PrivilegedResult {
        terminated.value = false
        commands.mutate { $0.append(command) }
        prompts.mutate { $0.append(prompt) }
        gate.value?.wait()
        return terminated.value ? .cancelled : privilegedResult.value
    }
    func ipv4Addresses() -> [ThunderboltBridge.InterfaceAddress] {
        [ThunderboltBridge.InterfaceAddress(name: "bridge0", address: bridgeAddress.value, netmask: "255.255.0.0", isUp: true, isRunning: true)]
    }
    func isLinkActive(_ interface: String) -> Bool? { true }
    func cancelRunning() {
        terminated.value = true
        gate.value?.signal()
    }
}

/// A peer that completes TLS + handshake and then never sends anything (no pongs, no pings).
final class SilentPeer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "silent-peer")
    var connections: [NWConnection] = []
    var stopped = false
    let acks = Box(0)

    init(port: UInt16, passcode: String) throws {
        listener = try NWListener(using: PeerSecurity.parameters(passcode: passcode, timing: PeerLinkTiming()),
                                  on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self, !self.stopped else { conn.cancel(); return }
            self.connections.append(conn)
            conn.start(queue: self.queue)
            var decoder = FrameDecoder()
            func loop() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                    if let data {
                        try? decoder.feed(data) { type, payload in
                            guard type == WireType.hello, let hello = Wire.decode(HelloMessage.self, from: payload) else { return }
                            let ack = HelloAckMessage(protocolVersion: Wire.protocolVersion, deviceID: "SILENT",
                                                      deviceName: "Silent", service: hello.service,
                                                      instanceID: "silent-instance", channelID: hello.channelID)
                            conn.send(content: Wire.frame(type: WireType.helloAck, payload: Wire.encode(ack)),
                                      completion: .idempotent)
                            self.acks.mutate { $0 += 1 }
                        }
                    }
                    if !done && error == nil { loop() } else { conn.cancel() }
                }
            }
            loop()
        }
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            stopped = true
            connections.forEach { $0.cancel() }
        }
        listener.cancel()
    }
}

// MARK: - Checks

@MainActor
func pureLogicChecks() {
    print("Framing")
    let header = Wire.header(type: 0xFF10, length: 0x01020304)
    check(header == Data([1, 2, 3, 4, 0xFF, 0x10]), "header is [UInt32 BE length][UInt16 BE type]")
    var frames: [(UInt16, Data)] = [(1, Data("hello".utf8)), (0xFEFF, Data()), (7, Data(repeating: 0xAB, count: 70_000)),
                                    (2, Data([0])), (3, Data((0..<3000).map { UInt8($0 & 0xFF) }))]
    frames.append((9, Data("tail".utf8)))
    var stream = Data()
    for (t, p) in frames { stream.append(Wire.frame(type: t, payload: p)) }
    for chunkSize in [1, 5, 6, 7, 1000, 65536, stream.count] {
        var decoder = FrameDecoder()
        var out: [(UInt16, Data)] = []
        var offset = 0
        var ok = true
        while offset < stream.count {
            let end = min(stream.count, offset + chunkSize)
            do { try decoder.feed(stream.subdata(in: offset..<end)) { out.append(($0, $1)) } } catch { ok = false }
            offset = end
        }
        let same = ok && out.count == frames.count && zip(out, frames).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        check(same, "decoder reassembles frames from \(chunkSize)-byte chunks")
    }
    var randomDecoder = FrameDecoder()
    var randomOut = 0
    var offset = 0
    while offset < stream.count {
        let end = min(stream.count, offset + Int.random(in: 1...9000))
        try? randomDecoder.feed(stream.subdata(in: offset..<end)) { _, _ in randomOut += 1 }
        offset = end
    }
    check(randomOut == frames.count && !randomDecoder.isInsideFrame, "decoder handles random chunking")
    var big = FrameDecoder()
    var threw = false
    do { try big.feed(Wire.header(type: 1, length: PeerLimits.maxPayloadSize + 1)) { _, _ in } } catch { threw = true }
    check(threw, "decoder rejects a header announcing > maxPayloadSize")
    var exact = FrameDecoder()
    var exactOK = false
    try? exact.feed(Wire.header(type: 1, length: PeerLimits.maxPayloadSize)) { _, _ in }
    exactOK = exact.isInsideFrame && exact.preferredReceiveLength > 0
    check(exactOK, "decoder accepts exactly maxPayloadSize")
    check(WireType.isReserved(0xFF00) && WireType.isReserved(0xFFFF) && !WireType.isReserved(0xFEFF), "reserved type range")

    print("Security")
    let psk = PeerSecurity.preSharedKey(passcode: "ABCD2345")
    let expected = Data(HMAC<SHA256>.authenticationCode(for: Data("OneSwitch-PSK-v1".utf8),
                                                        using: SymmetricKey(data: Data("ABCD2345".utf8))))
    check(psk == expected && psk.count == 32, "PSK = HMAC-SHA256(passcode, \"OneSwitch-PSK-v1\")")
    check(PeerSecurity.preSharedKey(passcode: "ABCD2346") != psk, "different passcode → different PSK")
    check(LinkFailure.classify(.tls(errSSLBadRecordMac)) == .authentication, "bad record MAC → authentication failure")
    check(LinkFailure.classify(.tls(errSSLPeerBadRecordMac)) == .authentication, "peer bad record MAC → authentication failure")
    check(LinkFailure.classify(.dns(DNSServiceErrorType(-65570))) == .localNetworkDenied, "kDNSServiceErr_PolicyDenied → local network denied")
    check(LinkFailure.classify(.posix(.ECONNREFUSED)) == .refused, "ECONNREFUSED → refused")
    check(LinkFailure.classify(.posix(.ENETDOWN), unsatisfiedReason: .localNetworkDenied) == .localNetworkDenied,
          "path localNetworkDenied → local network denied")

    print("Passcode / backoff / dial rules")
    let code = Passcode.generate()
    let allowed = Set(Passcode.alphabet)
    check(code.count == 8 && code.allSatisfy { allowed.contains($0) }, "generated passcode \(code) uses the unambiguous alphabet")
    check(!allowed.contains("0") && !allowed.contains("O") && !allowed.contains("1") && !allowed.contains("I"), "alphabet excludes 0/O/1/I")
    check(Set((0..<50).map { _ in Passcode.generate() }).count == 50, "passcodes are random")
    check(Passcode.normalize("  abc \n") == "abc", "passcode whitespace is trimmed")
    var backoff = Backoff(initial: 1, maximum: 30)
    let seq = (0..<7).map { _ in backoff.next() }
    check(seq == [1, 2, 4, 8, 16, 30, 30], "backoff 1 → 30 s: \(seq)")
    backoff.reset()
    check(backoff.next() == 1, "backoff resets")
    check(DialRules.shouldDial(localID: "A", peerID: "B", waited: 0, asymmetricDelay: 4), "smaller id dials immediately")
    check(!DialRules.shouldDial(localID: "B", peerID: "A", waited: 1, asymmetricDelay: 4), "larger id waits")
    check(DialRules.shouldDial(localID: "B", peerID: "A", waited: 4.1, asymmetricDelay: 4), "larger id dials after the delay")
    check(DialRules.shouldDial(localID: "B", peerID: nil, waited: 0, asymmetricDelay: 4), "unknown peer id → dial")
    func hello(from id: String, instance: String = "i1", last: String? = nil) -> HelloMessage {
        HelloMessage(protocolVersion: 1, deviceID: id, deviceName: id, service: "sync", instanceID: instance,
                     channelID: UUID().uuidString, lastChannelID: last)
    }
    check(DialRules.decideIncoming(localID: "A", hello: hello(from: "B"), established: nil, outgoingHelloSent: true) == .reject(.duplicate),
          "both handshaking: smaller id rejects the larger id's dial")
    check(DialRules.decideIncoming(localID: "B", hello: hello(from: "A"), established: nil, outgoingHelloSent: true) == .accept(replacing: false, cancelOutgoing: true),
          "both handshaking: larger id accepts and cancels its own dial")
    check(DialRules.decideIncoming(localID: "A", hello: hello(from: "B"), established: nil, outgoingHelloSent: false) == .park,
          "smaller id, own dial still connecting → park the incoming hello")
    check(DialRules.decideIncoming(localID: "B", hello: hello(from: "A"), established: nil, outgoingHelloSent: false) == .accept(replacing: false, cancelOutgoing: true),
          "larger id, own dial still connecting → accept incoming, cancel own")
    check(DialRules.decideIncoming(localID: "A", hello: hello(from: "B", last: "X"), established: ("X", "i1"), outgoingHelloSent: nil) == .accept(replacing: true, cancelOutgoing: false),
          "peer lost the live channel → newer replaces older")
    check(DialRules.decideIncoming(localID: "A", hello: hello(from: "B", instance: "i2"), established: ("X", "i1"), outgoingHelloSent: nil) == .accept(replacing: true, cancelOutgoing: false),
          "peer restarted → replace")
    check(DialRules.decideIncoming(localID: "A", hello: hello(from: "B", last: "W"), established: ("X", "i1"), outgoingHelloSent: nil) == .reject(.duplicate),
          "stale dial while a channel is live → rejected")

    print("networksetup parsing / commands")
    let services = ThunderboltBridge.parseServiceOrder(serviceOrderSample)
    check(services.count == 5, "parsed \(services.count) services from this Mac's sample")
    check(services.first { $0.device == "bridge0" }?.name == "Thunderbolt Bridge", "bridge0 → Thunderbolt Bridge")
    check(services.first { $0.name.hasPrefix("000") }?.enabled == false, "disabled (*) service parsed")
    check(services.first { $0.name == "Tailscale" }?.device == "", "service without device parsed")
    let localized = ThunderboltBridge.parseServiceOrder(localizedServiceOrderSample)
    let tb = ThunderboltBridge.thunderboltService(in: localized)
    check(tb?.name == "雷雳网桥" && tb?.device == "bridge0" && tb?.order == 2, "localized service “雷雳网桥” resolved via bridge0")
    check(localized.contains { $0.name == "Bob's \"USB\" 网卡" && $0.device == "en7" }, "service names with quotes parsed")
    let renamed = localizedServiceOrderSample.replacingOccurrences(of: "Device: bridge0", with: "Device: bridge1")
    check(ThunderboltBridge.thunderboltService(in: ThunderboltBridge.parseServiceOrder(renamed))?.device == "bridge1",
          "falls back to the Thunderbolt hardware port when bridge0 is absent")
    let dhcp = ThunderboltBridge.parseServiceInfo(dhcpInfoSample)
    check(dhcp == .init(method: .dhcp, ipAddress: "169.254.34.128", subnetMask: "255.255.0.0", router: nil), "getinfo DHCP parsed")
    let manual = ThunderboltBridge.parseServiceInfo(manualInfoSample)
    check(manual == .init(method: .manual, ipAddress: "10.77.0.1", subnetMask: "255.255.255.0", router: nil), "getinfo manual parsed")
    check(ThunderboltBridge.parseServiceInfo("** Error: The parameters were not valid.") == nil, "getinfo error output → nil")
    check(ThunderboltBridge.isConfigured(manual, ip: "10.77.0.1", mask: "255.255.255.0"), "manual 10.77.0.1 matches")
    check(!ThunderboltBridge.isConfigured(manual, ip: "10.77.0.2", mask: "255.255.255.0"), "different IP does not match")
    check(!ThunderboltBridge.isConfigured(dhcp, ip: "169.254.34.128", mask: "255.255.0.0"), "DHCP never matches")
    let routed = ThunderboltBridge.parseServiceInfo(manualInfoSample.replacingOccurrences(of: "Router: (null)", with: "Router: 10.77.0.2"))
    check(routed?.router == "10.77.0.2" && !ThunderboltBridge.isConfigured(routed, ip: "10.77.0.1", mask: "255.255.255.0"),
          "manual config WITH a router on the bridge does not count as configured (default-route hijack)")

    let cmd = try? ThunderboltBridge.setManualCommand(service: "雷雳网桥", ip: "10.77.0.2", mask: "255.255.255.0")
    check(cmd == "/usr/sbin/networksetup -setmanual '雷雳网桥' 10.77.0.2 255.255.255.0", "setmanual command: \(cmd ?? "nil")")
    let dhcpCmd = try? ThunderboltBridge.setDHCPCommand(service: "Thunderbolt Bridge")
    check(dhcpCmd == "/usr/sbin/networksetup -setdhcp 'Thunderbolt Bridge'", "setdhcp command")
    check((try? ThunderboltBridge.setManualCommand(service: "x", ip: "10.77.0.1; rm -rf /", mask: "255.255.255.0")) == nil, "injection via IP rejected")
    check((try? ThunderboltBridge.setManualCommand(service: "x", ip: "10.77.0.1", mask: "255.0.255.0")) == nil, "non-contiguous mask rejected")
    check((try? ThunderboltBridge.setManualCommand(service: "a\nb", ip: "10.77.0.1", mask: "255.255.255.0")) == nil, "newline in service name rejected")
    let nasty = "Bob's \"Bridge\" \\ $HOME `x`"
    let quoted = ThunderboltBridge.shellQuote(nasty)
    let echoed = runProcess("/bin/sh", ["-c", "printf %s \(quoted)"])
    check(echoed == nasty, "shell quoting round-trips through /bin/sh")
    let script = ThunderboltBridge.privilegedAppleScript(command: "networksetup -setdhcp \(quoted)", prompt: "提示 \"x\"")
    check(script.hasPrefix("do shell script \"") && script.hasSuffix("with administrator privileges"), "AppleScript uses administrator privileges")
    // Same escaping, executed without privileges: `do shell script "printf %s '<name>'"` must print the name.
    let probe = "do shell script \"\(ThunderboltBridge.appleScriptEscape("printf %s \(quoted)"))\""
    let viaAppleScript = runProcess("/usr/bin/osascript", ["-e", probe])
    check(viaAppleScript == nasty, "AppleScript + shell quoting round-trips (unprivileged probe)")

    check(ThunderboltBridge.derivePeerIP(from: "10.77.0.1") == "10.77.0.2", ".1 → .2")
    check(ThunderboltBridge.derivePeerIP(from: "10.77.0.2") == "10.77.0.1", ".2 → .1")
    check(ThunderboltBridge.derivePeerIP(from: "10.77.0.5") == nil, ".5 → no derived peer")
    check(IPv4.isValidHost("10.77.0.1") && !IPv4.isValidHost("10.77.0.256") && !IPv4.isValidHost("10.77.0") && !IPv4.isValidHost("10.77.0.0"), "IPv4 host validation")
    check(IPv4.isValidMask("255.255.255.0") && IPv4.isValidMask("255.255.0.0") && !IPv4.isValidMask("0.0.0.0"), "mask validation")
    check(!IPv4.isValidHost("10.77.0.010") && !IPv4.isValidHost("010.77.0.1") && IPv4.parse("10.0.0.1") != nil
          && (try? ThunderboltBridge.setManualCommand(service: "x", ip: "10.77.0.01", mask: "255.255.255.0")) == nil,
          "leading zeros rejected (inet_aton would read 010 as octal 8)")
    for (name, ip) in [("雷雳网桥", "10.77.0.2"), ("Bob's \"USB\" 网卡", "10.77.0.1"), ("Thunderbolt Bridge", "192.168.77.1")] {
        let c = (try? ThunderboltBridge.setManualCommand(service: name, ip: ip, mask: "255.255.255.0")) ?? ""
        check(c.hasPrefix("/usr/sbin/networksetup -setmanual \(ThunderboltBridge.shellQuote(name)) ")
              && c.hasSuffix(" \(ip) 255.255.255.0"),
              "setmanual for “\(name)” ends with <ip> <mask>: no router operand, so never a default route")
    }
    check(PeerLinkModule.preferredBridgeAddress(["fe80::4f:dd84:13ca:5bd1", "10.77.0.2"]) == "10.77.0.2"
          && PeerLinkModule.preferredBridgeAddress(["fe80::1", "169.254.10.20"]) == "169.254.10.20"
          && PeerLinkModule.preferredBridgeAddress(["169.254.10.20", "10.77.0.2"]) == "10.77.0.2"
          && PeerLinkModule.preferredBridgeAddress(["fe80::1"]) == "fe80::1"
          && PeerLinkModule.preferredBridgeAddress([]) == nil,
          "peer bridge address shown as IPv4 (not the fe80:: of the Bonjour connection)")
    check(Passcode.normalize("ＡＢＣＤ２３４５　") == "ABCD2345" && Passcode.normalize("K7M2QX9P") == "K7M2QX9P",
          "full-width 配对码 typed with a Chinese IME equals its half-width form")
    check(PeerSecurity.preSharedKey(passcode: Passcode.normalize("ＡＢＣＤ２３４５")) == psk,
          "…and derives the same PSK")
    check(ThunderboltBridge.isThunderboltInterface("bridge0") && ThunderboltBridge.isThunderboltInterface("bridge1")
          && !ThunderboltBridge.isThunderboltInterface("bridge100") && !ThunderboltBridge.isThunderboltInterface("en0"),
          "bridge0…99 are Thunderbolt; bridge100 (Internet Sharing / VM) is not")
    check(PeerLinkDefaults.defaultStaticIP(isLaptop: false) == "10.77.0.1" && PeerLinkDefaults.defaultStaticIP(isLaptop: true) == "10.77.0.2",
          "desktop .1 / laptop .2")
    let addrs = ThunderboltBridge.ipv4Addresses()
    check(addrs.contains { $0.name == "lo0" && $0.address == "127.0.0.1" }, "getifaddrs lists lo0 127.0.0.1")
    let bridgeAddrs = addrs.filter { ThunderboltBridge.isThunderboltInterface($0.name) }.map { "\($0.name) \($0.address)" }
    print("    (info) this Mac's Thunderbolt bridge: link \(ThunderboltBridge.isLinkActive("bridge0").map { $0 ? "active" : "inactive" } ?? "n/a"), addresses \(bridgeAddrs)")
    check(ThunderboltBridge.isLinkActive("nosuchif9") == nil, "link state of a missing interface is nil")
}

/// Open TCP (AF_INET / AF_INET6 stream) sockets of this process.
func openTCPSockets() -> Int {
    var count = 0
    for fd in 0..<getdtablesize() {
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else { continue }
        var type: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len) == 0, type == SOCK_STREAM else { continue }
        var addr = sockaddr_storage()
        var alen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &alen) == 0 }
        }
        if ok && (Int32(addr.ss_family) == AF_INET || Int32(addr.ss_family) == AF_INET6) { count += 1 }
    }
    return count
}

func runProcess(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
}

@MainActor
func bridgeManagerChecks() {
    print("Static IP auto-configuration (fake system — nothing is executed)")
    let fake = FakeBridgeSystem()
    let suiteName = "oneswitch.peerlinkcheck.bridge"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    suites.append(suiteName)
    let config = PeerLinkConfiguration(defaults: defaults, deviceID: "BRIDGE-1", deviceName: "Bridge Check",
                                       passcode: nil, serviceType: "_oneswitch-test._tcp", bonjourEnabled: false,
                                       directPeers: [], manageThunderboltBridge: true, isLaptop: true,
                                       timing: fastTiming, settingsDebounce: 0.05)
    let module = PeerLinkModule(configuration: config, bridgeSystem: fake)
    check(module.store.value.staticIP == "10.77.0.2", "laptop defaults to 10.77.0.2")
    check(module.store.value.staticIPEnabled, "static IP auto-configuration defaults to on")
    module.start()
    check(module.status == .disabled(reason: "请先设置配对码"), "no passcode → disabled “请先设置配对码”")
    check(waitUntil { !module.bridge.state.busy && fake.commands.value.count == 1 }, "start() applies the static IP once")
    check(fake.commands.value.first == "/usr/sbin/networksetup -setmanual '雷雳网桥' 10.77.0.2 255.255.255.0",
          "uses the localized service name resolved via bridge0: \(fake.commands.value.first ?? "-")")
    check(fake.prompts.value.first?.contains("雷雳网桥") == true, "password prompt names the service")
    check(waitUntil { module.store.value.staticIPPromptDeclined }, "cancelled password dialog is remembered")
    check(waitUntil { module.bridge.state.serviceName == "雷雳网桥" && module.bridge.state.linkActive == true },
          "bridge status: service + link")
    check(module.bridgeMenuLine() == "雷雳网桥：169.254.34.128 ⇄ 10.77.0.1", "menu line: \(module.bridgeMenuLine() ?? "nil")")
    module.stop()

    let again = PeerLinkModule(configuration: config, bridgeSystem: fake)
    again.start()
    spin(0.4)
    check(fake.commands.value.count == 1, "after a cancel, the next launch does not prompt automatically")
    fake.privilegedResult.value = .success
    again.configureStaticIPNow()
    check(waitUntil { fake.commands.value.count == 2 && !again.bridge.state.busy }, "立即配置 prompts again")
    check(waitUntil { !again.store.value.staticIPPromptDeclined }, "success clears the declined flag")
    fake.info.value = manualInfoSample.replacingOccurrences(of: "10.77.0.1", with: "10.77.0.2")
    again.configureStaticIPNow()
    spin(0.3)
    check(fake.commands.value.count == 2 && again.bridge.state.message?.contains("已是静态 IP") == true,
          "already configured → no command")
    again.restoreDHCP()
    check(waitUntil { fake.commands.value.count == 3 }, "恢复为自动（DHCP）runs setdhcp")
    check(fake.commands.value.last == "/usr/sbin/networksetup -setdhcp '雷雳网桥'", "setdhcp targets the bridge service")
    check(waitUntil { !again.store.value.staticIPEnabled }, "restoring DHCP turns automatic configuration off")
    fake.order.value = localizedServiceOrderSample.replacingOccurrences(of: "(2) 雷雳网桥", with: "(*) 雷雳网桥")
    again.configureStaticIPNow()
    check(waitUntil { fake.commands.value.count == 4 && !again.bridge.state.busy }, "disabled bridge service → enable it")
    check(fake.commands.value.last == "/usr/sbin/networksetup -setnetworkserviceenabled '雷雳网桥' on",
          "already manual but disabled → only the enable command: \(fake.commands.value.last ?? "-")")
    fake.info.value = dhcpInfoSample
    again.configureStaticIPNow()
    check(waitUntil { fake.commands.value.count == 5 && !again.bridge.state.busy }, "DHCP + disabled → one prompt")
    check(fake.commands.value.last == "/usr/sbin/networksetup -setmanual '雷雳网桥' 10.77.0.2 255.255.255.0 && /usr/sbin/networksetup -setnetworkserviceenabled '雷雳网桥' on",
          "…with both commands chained")
    fake.order.value = "An asterisk (*) denotes that a network service is disabled.\n(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)\n"
    again.configureStaticIPNow()
    check(waitUntil { again.bridge.state.messageIsError && !again.bridge.state.busy }, "missing bridge service → error message")
    check(fake.commands.value.count == 5, "no command without a bridge service")
    again.stop()

    /// A module that manages the (fake) bridge, with fresh settings. No passcode → no engine / socket.
    func bridgeModule(_ tag: String, _ fake: FakeBridgeSystem, isLaptop: Bool = true) -> PeerLinkModule {
        let suiteName = "oneswitch.peerlinkcheck.bridge.\(tag)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        suites.append(suiteName)
        let config = PeerLinkConfiguration(defaults: defaults, deviceID: "BRIDGE-\(tag)", deviceName: "Bridge \(tag)",
                                           passcode: nil, port: freshPort(), serviceType: "_oneswitch-test._tcp",
                                           bonjourEnabled: false, directPeers: [], manageThunderboltBridge: true,
                                           isLaptop: isLaptop, timing: fastTiming, settingsDebounce: 0.05)
        return PeerLinkModule(configuration: config, bridgeSystem: fake)
    }

    print("Router on the bridge is removed (MacBook Pro: bridge is first in the service order)")
    let routedFake = FakeBridgeSystem()
    routedFake.privilegedResult.value = .success
    routedFake.info.value = manualInfoSample.replacingOccurrences(of: "10.77.0.1", with: "10.77.0.2")
        .replacingOccurrences(of: "Router: (null)", with: "Router: 10.77.0.1")
    let routedModule = bridgeModule("router", routedFake)
    routedModule.start()
    check(waitUntil { routedFake.commands.value.count == 1 && !routedModule.bridge.state.busy },
          "right IP but a router → reconfigured once")
    check(routedFake.commands.value.first == "/usr/sbin/networksetup -setmanual '雷雳网桥' 10.77.0.2 255.255.255.0",
          "…with -setmanual and no router operand: \(routedFake.commands.value.first ?? "-")")
    check(routedFake.prompts.value.first?.contains("路由器") == true, "…and the password prompt says the router is removed")
    routedModule.stop()

    print("No administrator-prompt loop")
    let failingFake = FakeBridgeSystem()
    failingFake.privilegedResult.value = .failed("boom")
    let failing = bridgeModule("loop", failingFake)
    failing.start()
    check(waitUntil { failingFake.commands.value.count == 1 && !failing.bridge.state.busy }, "launch: one automatic prompt")
    failing.reconnect()
    failing.bridge.refresh()
    failingFake.bridgeAddress.value = "10.77.0.2"
    failing.store.value.peerAddress = "10.77.0.9"
    failing.store.value.staticIP = "10.77.0.3"
    spin(1.0)
    check(failingFake.commands.value.count == 1, "a failed configuration is never retried automatically (\(failingFake.commands.value.count) prompt(s))")
    check(!failing.store.value.staticIPPromptDeclined, "…and is not recorded as “declined” (the next launch checks again)")
    failing.stop()

    print("Password dialog does not block bridge monitoring")
    let slowFake = FakeBridgeSystem()
    let dialog = DispatchSemaphore(value: 0)
    slowFake.gate.value = dialog
    slowFake.privilegedResult.value = .success
    let manager = BridgeManager(system: slowFake)
    manager.startMonitoring(interval: 0.1)
    check(waitUntil { manager.state.addresses == ["169.254.34.128"] }, "link monitor running")
    let outcome = Box<BridgeManager.Outcome?>(nil)
    manager.configure(ip: "10.77.0.1", mask: "255.255.255.0", trigger: .user) { outcome.value = $0 }
    check(waitUntil { slowFake.commands.value.count == 1 }, "password dialog open")
    slowFake.bridgeAddress.value = "10.77.0.1"
    check(waitUntil(2) { manager.state.addresses == ["10.77.0.1"] }, "address changes are still picked up while the dialog is open")
    let refreshed = Box(false)
    manager.refresh { refreshed.value = true }
    check(waitUntil(2) { refreshed.value } && manager.state.busy, "refresh() completes while the dialog is open")
    dialog.signal()
    check(waitUntil { outcome.value == .applied && !manager.state.busy }, "confirming the dialog applies the address")
    manager.stopMonitoring()

    print("Quitting with the password dialog open")
    let quitFake = FakeBridgeSystem()
    quitFake.gate.value = DispatchSemaphore(value: 0)
    let quitting = bridgeModule("quit", quitFake)
    quitting.start()
    check(waitUntil { quitFake.commands.value.count == 1 }, "automatic prompt open at launch")
    quitting.stop()
    check(quitFake.terminated.value, "stop() closes the open dialog")
    spin(0.5)
    check(!quitting.store.value.staticIPPromptDeclined, "closing it on quit is not remembered as “declined” by the user")
}

@MainActor
func networkingChecks() {
    let portA = freshPort(), portB = freshPort()
    let hubA = makeHub("A", deviceID: "A-" + UUID().uuidString, port: portA, peerPorts: [portB])
    let hubB = makeHub("B", deviceID: "B-" + UUID().uuidString, port: portB, peerPorts: [portA])

    print("Status")
    let emitted = Box<[PeerLinkStatus]>([])
    let sub = hubA.statusPublisher.sink { s in emitted.mutate { $0.append(s) } }
    check(emitted.value.count == 1, "statusPublisher emits the current value on subscribe")
    hubA.start()
    hubB.start()
    check(hubA.status == .disabled(reason: "未启用文件同步或键鼠共享"), "no services → disabled “未启用文件同步或键鼠共享”")

    print("Handshake + channel per service (only when both registered)")
    let syncA = Probe(), inputA = Probe(), syncB = Probe(), inputB = Probe()
    hubA.register(service: "sync") { syncA.add($0) }
    hubA.register(service: "input") { inputA.add($0) }
    hubB.register(service: "input") { inputB.add($0) }
    check(waitUntil(8) { inputA.count == 1 && inputB.count == 1 }, "input channel formed on both sides")
    check(waitUntil { hubA.status.connectedPeer?.deviceID == hubB.localDeviceID && hubB.status.connectedPeer?.deviceID == hubA.localDeviceID },
          "status .connected(peer) on both sides")
    check(!waitUntil(1.0) { syncA.count > 0 }, "no sync channel while only A registered it")
    let line = hubA.statusLine().0
    check(line.hasPrefix("已连接 Check B · 本机回环 · ") && line.hasSuffix(" ms"), "menu status line: \(line)")
    check(hubA.channelRows().map(\.title) == ["控制通道", "键鼠共享"] && hubA.serviceRows().first { $0.id == "sync" }?.state == "对方未启用",
          "diagnostics: channel rows \(hubA.channelRows().map(\.title)), sync shows “对方未启用”")
    let peerOfA = inputA.latest?.peer
    check(peerOfA?.name == "Check B" && peerOfA?.address == "127.0.0.1" && peerOfA?.viaThunderbolt == false,
          "PeerInfo: name/address/viaThunderbolt = \(String(describing: peerOfA))")
    hubB.register(service: "sync") { syncB.add($0) }
    check(waitUntil(5) { syncA.count == 1 && syncB.count == 1 }, "sync channel forms once B registers it")
    guard let sA = syncA.latest, let sB = syncB.latest, let iA = inputA.latest, let iB = inputB.latest else {
        check(false, "channels available")
        return
    }
    check((sA as? NetworkPeerChannel)?.channelID == (sB as? NetworkPeerChannel)?.channelID, "both ends agree on the channel id")
    print("    (info) open TCP sockets while linked: \(openTCPSockets()), process fds: \((0..<getdtablesize()).filter { fcntl($0, F_GETFD) != -1 }.count)")
    check(hubA.engine?.listenerPort == portA && hubB.engine?.listenerPort == portB, "both listeners bound to their configured ports")
    check(sA.service == "sync" && sB.service == "sync" && sA.isOpen && sB.isOpen, "channel service / open")

    print("Buffering before setHandlers")
    for i in 0..<5 { sA.send(type: 10, payload: Data([UInt8(i)])) }
    spin(0.3)
    let early = Box<[UInt8]>([])
    let qB = DispatchQueue(label: "check.b.sync")
    sB.setHandlers(queue: qB, onMessage: { t, d in if t == 10 { early.mutate { $0.append(d.first ?? 255) } } }, onClose: { _ in })
    check(waitUntil { early.value.count == 5 }, "5 messages sent before setHandlers are delivered")
    check(early.value == [0, 1, 2, 3, 4], "…in order")

    print("10 000 small ordered messages")
    let seqB = Box<[UInt32]>([])
    let qIB = DispatchQueue(label: "check.b.input")
    iB.setHandlers(queue: qIB, onMessage: { t, d in
        guard t == 20 else { return }
        let v = d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        seqB.mutate { $0.append(v) }
    }, onClose: { _ in })
    let t0 = Date()
    for i in 0..<10_000 {
        var v = UInt32(i)
        var payload = withUnsafeBytes(of: &v) { Data($0) }
        payload.append(contentsOf: [UInt8](repeating: 0x5A, count: 28))
        iA.send(type: 20, payload: payload)
    }
    check(waitUntil(20) { seqB.value.count == 10_000 }, "10 000 messages delivered")
    let elapsed = Date().timeIntervalSince(t0)
    check(seqB.value == (0..<10_000).map(UInt32.init), "all in order")
    print("    (info) 10 000 × 32 B in \(String(format: "%.0f", elapsed * 1000)) ms (\(String(format: "%.0f", 10_000 / elapsed)) msg/s)")

    print("Ping-pong latency (2 000 round trips on the input channel)")
    let rtts = Box<[UInt64]>([])
    let qIA = DispatchQueue(label: "check.a.input")
    let sentAt = Box<UInt64>(0)
    iB.setHandlers(queue: qIB, onMessage: { t, d in
        if t == 30 { iB.send(type: 31, payload: d) }
    }, onClose: { _ in })
    iA.setHandlers(queue: qIA, onMessage: { t, d in
        guard t == 31 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        rtts.mutate { $0.append(now - sentAt.value) }
        if rtts.value.count < 2000 {
            sentAt.value = DispatchTime.now().uptimeNanoseconds
            iA.send(type: 30, payload: Data(count: 16))
        }
    }, onClose: { _ in })
    sentAt.value = DispatchTime.now().uptimeNanoseconds
    iA.send(type: 30, payload: Data(count: 16))
    check(waitUntil(30) { rtts.value.count == 2000 }, "2 000 round trips completed")
    let sorted = rtts.value.sorted()
    if !sorted.isEmpty {
        let p50 = Double(sorted[sorted.count / 2]) / 1000
        let p99 = Double(sorted[min(sorted.count - 1, sorted.count * 99 / 100)]) / 1000
        print("    (info) RTT p50 \(String(format: "%.0f", p50)) µs, p99 \(String(format: "%.0f", p99)) µs (TLS over loopback, debug build)")
        check(p50 < 5_000, "p50 RTT below 5 ms")
    }

    print("64 MB bulk transfer with completion-based flow control")
    let received = Box<Int>(0)
    let chunkOrderOK = Box(true)
    let nextChunk = Box<UInt32>(0)
    sB.setHandlers(queue: qB, onMessage: { t, d in
        guard t == 40 else { return }
        let idx = d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if idx != nextChunk.value { chunkOrderOK.value = false }
        nextChunk.value = idx + 1
        received.mutate { $0 += d.count }
    }, onClose: { _ in })
    let chunk = 1 << 20, total = 64
    let sendErrors = Box(0)
    let maxInFlight = Box(0)
    let inFlight = Box(0)
    let bulkStart = Date()
    DispatchQueue.global(qos: .userInitiated).async {
        let window = DispatchSemaphore(value: 8)
        var base = Data(repeating: 0xC3, count: chunk)
        for i in 0..<total {
            window.wait()
            var idx = UInt32(i)
            withUnsafeBytes(of: &idx) { base.replaceSubrange(0..<4, with: $0) }
            inFlight.mutate { $0 += 1; if $0 > maxInFlight.value { maxInFlight.value = $0 } }
            sA.send(type: 40, payload: base) { error in
                if error != nil { sendErrors.mutate { $0 += 1 } }
                inFlight.mutate { $0 -= 1 }
                window.signal()
            }
        }
    }
    check(waitUntil(60) { received.value == chunk * total }, "64 MiB received")
    let bulkElapsed = Date().timeIntervalSince(bulkStart)
    check(chunkOrderOK.value && sendErrors.value == 0, "chunks in order, no send errors")
    check(maxInFlight.value <= 8, "flow control window respected (max in flight \(maxInFlight.value))")
    print("    (info) 64 MiB in \(String(format: "%.2f", bulkElapsed)) s = \(String(format: "%.0f", 64 / bulkElapsed)) MB/s (TLS over loopback, debug build)")

    print("Payload limit and reserved types")
    let tooBig = Box<Error?>(nil)
    sA.send(type: 1, payload: Data(count: PeerLimits.maxPayloadSize + 1)) { tooBig.value = $0 }
    check(waitUntil { tooBig.value != nil }, "oversized send fails")
    check((tooBig.value as? PeerLinkError) == .payloadTooLarge(PeerLimits.maxPayloadSize + 1), "…with .payloadTooLarge")
    let reservedErr = Box<Error?>(nil)
    sA.send(type: 0xFF10, payload: Data()) { reservedErr.value = $0 }
    check(waitUntil { reservedErr.value != nil }, "services cannot send reserved types")
    let seen = Box<[UInt16]>([])
    sB.setHandlers(queue: qB, onMessage: { t, _ in seen.mutate { $0.append(t) } }, onClose: { _ in })
    let rawA = sA as! NetworkPeerChannel
    for t: UInt16 in [0xFF00, 0xFF10, 0xFF11, 0xFF42, 0xFFFF] { rawA.sendRawFrameForTesting(type: t, payload: Data(count: 8)) }
    sA.send(type: 50, payload: Data("after".utf8))
    check(waitUntil { seen.value.contains(50) }, "service message after reserved frames arrives")
    check(seen.value == [50], "reserved types never reach services (saw \(seen.value.map { String($0, radix: 16) }))")
    check(sA.isOpen && sB.isOpen, "channel stays open after unknown reserved frames")

    print("Oversized frame from the network → protocolViolation")
    let violation = Box<Error?>(nil)
    let violationCount = Box(0)
    sB.setHandlers(queue: qB, onMessage: { _, _ in }, onClose: { e in violation.value = e; violationCount.mutate { $0 += 1 } })
    let closedA1 = Box(0)
    sA.setHandlers(queue: DispatchQueue(label: "check.a.sync"), onMessage: { _, _ in }, onClose: { _ in closedA1.mutate { $0 += 1 } })
    rawA.sendRawBytesForTesting(Wire.header(type: 5, length: PeerLimits.maxPayloadSize + 1))
    check(waitUntil { violationCount.value == 1 }, "receiver closes the channel")
    if case .protocolViolation? = violation.value as? PeerLinkError {
        check(true, "…with .protocolViolation")
    } else {
        check(false, "…with .protocolViolation (got \(String(describing: violation.value)))")
    }
    check(waitUntil { closedA1.value == 1 }, "sender side closes too")
    check(waitUntil(5) { syncA.count == 2 && syncB.count == 2 }, "sync channel re-forms automatically")

    print("Close propagates exactly once")
    guard let sA2 = syncA.latest, let sB2 = syncB.latest else { return }
    let closeA = Box<[String]>([]), closeB = Box<[String]>([])
    let lastMsgBeforeClose = Box<Int>(0)
    sA2.setHandlers(queue: DispatchQueue(label: "a2"), onMessage: { _, _ in }, onClose: { e in closeA.mutate { $0.append(String(describing: e)) } })
    let orderB = Box<[String]>([])
    sB2.setHandlers(queue: DispatchQueue(label: "b2"), onMessage: { t, _ in
        if t == 60 { lastMsgBeforeClose.mutate { $0 += 1 }; orderB.mutate { $0.append("msg") } }
    }, onClose: { e in
        closeB.mutate { $0.append(String(describing: e)) }
        orderB.mutate { $0.append("close") }
    })
    for _ in 0..<100 { sA2.send(type: 60, payload: Data(count: 100)) }
    sA2.close()
    check(!sA2.isOpen, "isOpen false right after close()")
    check(waitUntil { closeA.value.count == 1 && closeB.value.count == 1 }, "onClose fired on both ends")
    spin(0.5)
    check(closeA.value.count == 1 && closeB.value.count == 1, "…exactly once")
    check(closeA.value.first == "nil", "local onClose(nil) after close()")
    check(closeB.value.first?.contains("closedByPeer") == true, "peer onClose(.closedByPeer): \(closeB.value.first ?? "-")")
    check(lastMsgBeforeClose.value == 100 && orderB.value.last == "close" && orderB.value.filter { $0 == "close" }.count == 1,
          "all 100 messages delivered before onClose")
    let lateSend = Box<Error?>(nil)
    sA2.send(type: 1, payload: Data()) { lateSend.value = $0 }
    check(waitUntil { lateSend.value != nil } && (lateSend.value as? PeerLinkError) == .closed, "send after close fails with .closed")
    check(waitUntil(5) { syncA.count == 3 && syncB.count == 3 }, "hub re-forms the channel after a close")

    print("Re-register replaces the handler (fresh channel)")
    let syncA2 = Probe()
    hubA.register(service: "sync") { syncA2.add($0) }
    check(waitUntil(5) { syncA2.count == 1 && syncB.count == 4 }, "new handler receives a new channel")
    check(syncA.latest?.isOpen == false, "old channel closed first")

    print("Duplicate channels: exactly one per service")
    spin(1.0)
    check(syncA2.count == 1 && syncB.count == 4 && inputA.count == 1 && inputB.count == 1, "no extra channels handed out")

    print("Reconnect after one hub stops / starts")
    let closedInputA = Box(0)
    inputA.latest?.setHandlers(queue: qIA, onMessage: { _, _ in }, onClose: { _ in closedInputA.mutate { $0 += 1 } })
    hubB.stop()
    check(waitUntil { closedInputA.value == 1 }, "A's channel closes when B stops")
    check(waitUntil { hubA.status == .searching }, "A returns to .searching")
    check(hubB.status == .disabled(reason: "雷雳互联已停止"), "stopped hub reports disabled")
    hubB.start()
    check(waitUntil(10) { inputA.count == 2 && inputB.count == 2 && syncA2.count == 2 }, "channels re-form after B restarts")
    check(hubB.engine?.listenerPort == portB, "restarted hub re-binds its fixed port (TIME_WAIT does not block it)")
    check(waitUntil { hubA.status.connectedPeer != nil && hubB.status.connectedPeer != nil }, "both connected again")

    print("Unregister")
    let unregClosed = Box<[String]>([])
    inputB.latest?.setHandlers(queue: qIB, onMessage: { _, _ in }, onClose: { e in unregClosed.mutate { $0.append(String(describing: e)) } })
    let peerClosed = Box(0)
    inputA.latest?.setHandlers(queue: qIA, onMessage: { _, _ in }, onClose: { _ in peerClosed.mutate { $0 += 1 } })
    hubB.unregister(service: "input")
    check(waitUntil { unregClosed.value == ["nil"] }, "unregister closes the local channel (onClose nil)")
    check(waitUntil { peerClosed.value == 1 }, "peer's channel closes too")
    check(!waitUntil(1.0) { inputA.count > 2 }, "no input channel while B has it unregistered")
    hubB.unregister(service: "sync")
    check(waitUntil { hubB.status == .disabled(reason: "未启用文件同步或键鼠共享") }, "last service unregistered → disabled")

    sub.cancel()
    hubA.stop()
    hubB.stop()
    check(hubA.engine == nil && hubB.engine == nil, "stop() releases the engines")
}

@MainActor
func wrongPasscodeChecks() {
    print("Wrong passcode")
    let pC = freshPort(), pD = freshPort()
    let hubC = makeHub("C", deviceID: "C-1", port: pC, peerPorts: [pD], passcode: "right-one")
    let hubD = makeHub("D", deviceID: "D-1", port: pD, peerPorts: [pC], passcode: "wrong-one")
    let got = Box(0)
    hubC.register(service: "sync") { _ in got.mutate { $0 += 1 } }
    hubD.register(service: "sync") { _ in got.mutate { $0 += 1 } }
    hubC.start()
    hubD.start()
    let expected = PeerLinkStatus.error("配对码不匹配：请确认两台 Mac 的配对码一致")
    check(waitUntil(8) { hubC.status == expected && hubD.status == expected }, "both sides report “配对码不匹配”")
    spin(1.0)
    check(got.value == 0, "no channel is ever handed out")
    // Fix the passcode on D → link comes up (settings change restarts the engine).
    hubD.store.value.passcode = "right-one"
    check(waitUntil(8) { got.value == 2 }, "after correcting the passcode the channel forms")
    check(hubC.status.connectedPeer != nil && hubD.status.connectedPeer != nil, "status recovers to connected")
    hubC.stop()
    hubD.stop()
}

@MainActor
func tieBreakChecks() {
    print("Simultaneous dialing tie-break (10 rounds)")
    var timing = fastTiming
    timing.directDialDelay = 0.3      // both listeners are up, then both dial within ~10 ms
    timing.asymmetricDialDelay = 0
    timing.tickInterval = 0.01
    var consistent = true
    var smallerWinsWhenRaced = true
    var races = 0
    var largerRejected = 0
    for round in 0..<10 {
        let pE = freshPort(), pF = freshPort()
        let hubE = makeHub("E\(round)", deviceID: "E-\(round)", port: pE, peerPorts: [pF], timing: timing)
        let hubF = makeHub("F\(round)", deviceID: "F-\(round)", port: pF, peerPorts: [pE], timing: timing)
        var probes: [String: (Probe, Probe)] = [:]
        for service in ["sync", "input"] {
            let pe = Probe(), pf = Probe()
            probes[service] = (pe, pf)
            hubE.register(service: service) { pe.add($0) }
            hubF.register(service: service) { pf.add($0) }
        }
        hubE.start()
        hubF.start()
        let formed = waitUntil(8) { probes.values.allSatisfy { $0.0.count >= 1 && $0.1.count >= 1 } }
        spin(1.0)
        if !formed { consistent = false }
        for (service, (pe, pf)) in probes {
            let chE = pe.latest as? NetworkPeerChannel, chF = pf.latest as? NetworkPeerChannel
            let ok = pe.count == 1 && pf.count == 1 && chE != nil && chE?.channelID == chF?.channelID
                && chE?.isOpen == true && chF?.isOpen == true
                && chE?.initiatedLocally != chF?.initiatedLocally
            if !ok {
                consistent = false
                print("    round \(round) \(service): E \(pe.count) F \(pf.count) ids \(chE?.channelID ?? "-") / \(chF?.channelID ?? "-")")
            }
            let raced = (hubE.engine?.duplicateRejections[service] ?? 0) > 0
            if raced {
                races += 1
                if chE?.initiatedLocally != true { smallerWinsWhenRaced = false }
            }
            largerRejected += hubF.engine?.duplicateRejections[service] ?? 0
        }
        hubE.stop()
        hubF.stop()
    }
    check(consistent, "exactly one channel per service, identical on both sides, in every round")
    check(smallerWinsWhenRaced, "when both dials reached the handshake, the smaller id's connection was kept (\(races) real races in 20 service pairings)")
    check(largerRejected == 0, "the larger id never refuses the smaller id's connection")
    check(races > 0, "the race was actually exercised")
}

@MainActor
func heartbeatChecks() {
    print("Heartbeat timeout")
    let pSilent = freshPort(), pG = freshPort()
    portOwners[pSilent] = "SilentPeer"
    guard let silent = try? SilentPeer(port: pSilent, passcode: "check-passcode") else {
        check(false, "silent peer listener")
        return
    }
    var timing = fastTiming
    timing.heartbeatInterval = 0.3
    timing.heartbeatTimeout = 1.2
    timing.directDialDelay = 0
    let hubG = makeHub("G", deviceID: "G-1", port: pG, peerPorts: [pSilent], timing: timing)
    let probe = Probe()
    let closeErr = Box<Error?>(nil)
    hubG.register(service: "sync") { ch in
        probe.all.mutate { $0.append(ch) }
        ch.setHandlers(queue: DispatchQueue(label: "g"), onMessage: { _, _ in }, onClose: { e in
            if closeErr.value == nil { closeErr.value = e }
        })
    }
    hubG.start()
    check(waitUntil(5) { probe.count >= 1 }, "channel established with a peer that then goes silent")
    let t0 = Date()
    check(waitUntil(5) { closeErr.value != nil }, "silent channel is closed")
    let after = Date().timeIntervalSince(t0)
    check((closeErr.value as? PeerLinkError) == .timeout, "…with .timeout after \(String(format: "%.1f", after)) s")
    hubG.stop()
    silent.stop()
}

@MainActor
func bonjourChecks() {
    print("Bonjour discovery (test service type, no direct addresses)")
    var timing = fastTiming
    timing.directDialDelay = 60
    let pH = freshPort(), pI = freshPort()
    let hubH = makeHub("H", deviceID: "H-1", port: pH, peerPorts: [], timing: timing, bonjour: true)
    let hubI = makeHub("I", deviceID: "I-1", port: pI, peerPorts: [], timing: timing, bonjour: true)
    let got = Box(0)
    hubH.register(service: "sync") { _ in got.mutate { $0 += 1 } }
    hubI.register(service: "sync") { _ in got.mutate { $0 += 1 } }
    hubH.start()
    hubI.start()
    let ok = waitUntil(15) { got.value == 2 }
    if ok {
        check(true, "hubs found each other over Bonjour and connected")
        check(hubH.discoveredPeerNames.contains { $0.hasPrefix("Check I") }, "discovered peer listed in diagnostics")
    } else {
        print("    (info) Bonjour discovery did not connect within 15 s from this CLI process; browser: \(hubH.engine?.browserState ?? "-"), discovered: \(hubH.discoveredPeerNames)")
        check(false, "Bonjour discovery")
    }
    check(!hubH.diagnosticsText().isEmpty && hubH.serviceRows().count == 2, "diagnostics text / rows")
    hubH.stop()
    hubI.stop()
}

@MainActor
func disabledChecks() {
    print("Disabled states / reserved names")
    let p = freshPort()
    let hub = makeHub("J", deviceID: "J-1", port: p, peerPorts: [], passcode: nil)
    hub.start()
    hub.register(service: "sync") { _ in }
    check(hub.status == .disabled(reason: "请先设置配对码"), "registered service but no passcode → “请先设置配对码”")
    hub.register(service: "_evil") { _ in }
    hub.store.value.passcode = "   "
    spin(0.2)
    check(hub.engine == nil, "whitespace-only passcode counts as unset")
    hub.store.value.passcode = "X7K2M9QP"
    check(waitUntil { hub.engine != nil && hub.status == .searching }, "setting a passcode starts the engine (.searching)")
    check(hub.engine?.userServices == ["sync"], "reserved service names are refused")
    check(hub.menuItems().count == 3 && hub.menuItems().first?.title.contains("正在查找") == true, "menu: status line + 重新连接 + 设置")
    hub.stop()
    check(hub.engine == nil, "stop() releases the engine")
}

@MainActor
func policyAndConfigChecks() {
    print("Interface policy 仅雷雳网桥 (loopback must be refused)")
    var timing = fastTiming
    timing.directDialDelay = 0
    let pK = freshPort(), pL = freshPort()
    let hubK = makeHub("K", deviceID: "K-1", port: pK, peerPorts: [pL], timing: timing, policy: .thunderboltOnly)
    let hubL = makeHub("L", deviceID: "L-1", port: pL, peerPorts: [pK], timing: timing, policy: .thunderboltOnly)
    let got = Box(0)
    hubK.register(service: "input") { _ in got.mutate { $0 += 1 } }
    hubL.register(service: "input") { _ in got.mutate { $0 += 1 } }
    hubK.start()
    hubL.start()
    check(!waitUntil(2.0) { got.value > 0 }, "no channel over lo0 in 仅雷雳网桥 mode")
    check(hubK.status == .searching, "status stays .searching")
    check(hubK.serviceRows().contains { $0.state.contains("雷雳") || $0.state.contains("重试") }, "diagnostics explain the retry: \(hubK.serviceRows().map(\.state))")
    hubK.stop()
    hubL.stop()

    print("Direct-address derivation / in-place updates")
    let suiteName = "oneswitch.peerlinkcheck.cfg"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    suites.append(suiteName)
    let cfg = PeerLinkConfiguration(defaults: defaults, deviceID: "CFG-1", deviceName: "Cfg", passcode: "p",
                                    serviceType: "_oneswitch-test._tcp", bonjourEnabled: false,
                                    manageThunderboltBridge: false, isLaptop: false, timing: fastTiming)
    let hub = PeerLinkModule(configuration: cfg, bridgeSystem: FakeBridgeSystem())
    var s = hub.store.value
    check(s.staticIP == "10.77.0.1" && s.port == 52525 && s.interfacePolicy == .preferThunderbolt, "defaults: 10.77.0.1, port 52525, 优先雷雳网桥")
    check(hub.engineConfig(settings: s, passcode: "p").directPeers == [PeerAddress(host: "10.77.0.2", port: 52525, viaBridge: true)],
          "static IP .1 → dial 10.77.0.2:52525 directly, pinned to the bridge (never via the default route)")
    s.peerAddress = "192.168.1.20"
    let withOverride = hub.engineConfig(settings: s, passcode: "p")
    check(withOverride.directPeers == [PeerAddress(host: "192.168.1.20", port: 52525, viaBridge: false)],
          "对方 IP override wins (may be a Wi‑Fi address, so not pinned)")
    s.peerAddress = ""
    s.staticIPEnabled = false
    check(hub.engineConfig(settings: s, passcode: "p").directPeers.isEmpty, "no static IP, no override → Bonjour only")
    check(!withOverride.requiresRestart(comparedTo: hub.engineConfig(settings: s, passcode: "p")), "direct addresses change without an engine restart")
    s.port = 52600
    check(withOverride.requiresRestart(comparedTo: hub.engineConfig(settings: s, passcode: "p")), "port change restarts the engine")
    check(withOverride.requiresRestart(comparedTo: hub.engineConfig(settings: hub.store.value, passcode: "q")), "passcode change restarts the engine")
    check(hub.id == "peerlink" && hub.displayName == "雷雳互联" && hub.symbolName == "cable.connector", "module identity")
    let idAgain = PeerLinkModule(configuration: PeerLinkConfiguration(defaults: defaults, passcode: nil, manageThunderboltBridge: false),
                                 bridgeSystem: FakeBridgeSystem())
    let idThird = PeerLinkModule(configuration: PeerLinkConfiguration(defaults: defaults, passcode: nil, manageThunderboltBridge: false),
                                 bridgeSystem: FakeBridgeSystem())
    check(UUID(uuidString: idAgain.localDeviceID) != nil && idAgain.localDeviceID == idThird.localDeviceID,
          "device id is a random UUID persisted in settings")
    check(!idAgain.localDeviceName.isEmpty, "device name: \(idAgain.localDeviceName)")

    print("Device id copied to another Mac (Migration Assistant / Time Machine)")
    func freshDefaults(_ tag: String) -> UserDefaults {
        let name = "oneswitch.peerlinkcheck.id.\(tag)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        suites.append(name)
        return d
    }
    func idModule(_ d: UserDefaults, hardware: String?) -> PeerLinkModule {
        PeerLinkModule(configuration: PeerLinkConfiguration(defaults: d, passcode: nil, manageThunderboltBridge: false,
                                                            hardwareID: hardware),
                       bridgeSystem: FakeBridgeSystem())
    }
    let cloned = freshDefaults("clone")
    cloned.set("CLONED-ID", forKey: PeerLinkModule.deviceIDKey)
    cloned.set("other-mac", forKey: PeerLinkModule.deviceHostKey)
    let onNewMac = idModule(cloned, hardware: "this-mac")
    check(onNewMac.localDeviceID != "CLONED-ID" && UUID(uuidString: onNewMac.localDeviceID) != nil,
          "an id generated on another Mac is replaced (otherwise both Macs reject each other as “self”)")
    check(idModule(cloned, hardware: "this-mac").localDeviceID == onNewMac.localDeviceID, "…and the new id is stable")
    let legacy = freshDefaults("legacy")
    legacy.set("LEGACY-ID", forKey: PeerLinkModule.deviceIDKey)
    check(idModule(legacy, hardware: "this-mac").localDeviceID == "LEGACY-ID"
          && legacy.string(forKey: PeerLinkModule.deviceHostKey) == "this-mac",
          "an id stored before the hardware binding is kept (no re-pairing after the update)")
    let fingerprint = PeerLinkModule.hardwareFingerprint()
    check(fingerprint?.count == 16 && fingerprint == PeerLinkModule.hardwareFingerprint(), "hardware fingerprint: \(fingerprint ?? "nil")")
}

@MainActor
func reentrancyChecks() {
    print("Handler unregisters every service from inside onChannel")
    let pX = freshPort(), pY = freshPort()
    let hubX = makeHub("X", deviceID: "X-1", port: pX, peerPorts: [pY])
    let hubY = makeHub("Y", deviceID: "Y-1", port: pY, peerPorts: [pX])
    let yClosed = Box(0)
    hubY.register(service: "sync") { ch in
        ch.setHandlers(queue: DispatchQueue(label: "y"), onMessage: { _, _ in }, onClose: { _ in yClosed.mutate { $0 += 1 } })
    }
    hubY.register(service: "input") { _ in }
    let handedOut = Box(0)
    hubX.register(service: "input") { _ in }
    hubX.register(service: "sync") { [weak hubX] _ in
        handedOut.mutate { $0 += 1 }
        hubX?.unregister(service: "sync")
        hubX?.unregister(service: "input")
    }
    hubX.start()
    hubY.start()
    check(waitUntil(8) { handedOut.value == 1 && hubX.engine == nil }, "engine stops when the last service unregisters inside its handler")
    check(hubX.status == .disabled(reason: "未启用文件同步或键鼠共享"), "…status disabled")
    check(waitUntil(5) { yClosed.value == 1 }, "…the peer's channel closes exactly once")
    spin(1.0)
    check(hubX.engine == nil && handedOut.value == 1 && yClosed.value == 1, "…and nothing reconnects afterwards")
    hubX.stop()
    hubY.stop()
}

@MainActor
func bonjourPreferChecks() {
    print("Bonjour with 优先雷雳网桥 (pins dials to bridge0 when the result lists it)")
    var timing = fastTiming
    timing.directDialDelay = 60
    let pM = freshPort(), pN = freshPort()
    let hubM = makeHub("M", deviceID: "M-1", port: pM, peerPorts: [], timing: timing, bonjour: true, policy: .preferThunderbolt)
    let hubN = makeHub("N", deviceID: "N-1", port: pN, peerPorts: [], timing: timing, bonjour: true, policy: .preferThunderbolt)
    let probe = Probe()
    hubM.register(service: "input") { probe.add($0) }
    hubN.register(service: "input") { _ in }
    hubM.start()
    hubN.start()
    check(waitUntil(15) { probe.count >= 1 }, "channel forms under 优先雷雳网桥")
    spin(1.5)
    let kind = (probe.latest as? NetworkPeerChannel)?.linkKind ?? "-"
    print("    (info) same-Mac link kind: \(kind); discovered: \(hubM.discoveredPeerNames)")
    check(probe.count == 1, "no reconnect churn (\(probe.count) channel(s) handed out)")
    hubM.stop()
    hubN.stop()
}

/// Opt-in: PEERLINK_SNAPSHOT=/path/prefix renders the settings page (connected, fake bridge) to PNG.
@MainActor
func renderSnapshots(prefix: String) {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let fake = FakeBridgeSystem()
    fake.info.value = manualInfoSample
    fake.order.value = serviceOrderSample
    let suiteName = "oneswitch.peerlinkcheck.snapshot"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    suites.append(suiteName)
    let pA = freshPort(), pB = freshPort()
    let cfg = PeerLinkConfiguration(defaults: defaults, deviceID: "A-SNAP", deviceName: "测试的 Mac Studio",
                                    passcode: "K7M2QX9P", port: pA, interfacePolicy: .preferThunderbolt,
                                    serviceType: "_oneswitch-test._tcp", bonjourEnabled: false,
                                    directPeers: [PeerAddress(host: "127.0.0.1", port: pB)],
                                    manageThunderboltBridge: true, isLaptop: false, timing: fastTiming)
    let hubA = PeerLinkModule(configuration: cfg, bridgeSystem: fake)
    let hubB = makeHub("snapB", deviceID: "B-SNAP", port: pB, peerPorts: [pA], passcode: "K7M2QX9P")
    for hub in [hubA, hubB] {
        hub.register(service: "sync") { $0.setHandlers(queue: .main, onMessage: { _, _ in }, onClose: { _ in }) }
        hub.register(service: "input") { $0.setHandlers(queue: .main, onMessage: { _, _ in }, onClose: { _ in }) }
    }
    hubA.start()
    hubB.start()
    _ = waitUntil(8) { hubA.channelRows().count == 3 }
    spin(2.5)
    for (name, height) in [("settings", 2600.0)] {
        let host = NSHostingView(rootView: hubA.settingsView().frame(width: 640, height: height))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin(1.0)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
        }
        window.contentView = nil
    }
    let menu = NSMenu()
    hubA.menuItems().forEach(menu.addItem)
    print(menu.items.map { $0.attributedTitle?.string ?? $0.title }.joined(separator: "\n"))
    hubA.stop()
    hubB.stop()
}

AppLog.echoToStderr = false
if let prefix = ProcessInfo.processInfo.environment["PEERLINK_SNAPSHOT"] {
    MainActor.assumeIsolated { renderSnapshots(prefix: prefix) }
    for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    exit(0)
}
MainActor.assumeIsolated {
    pureLogicChecks()
    bridgeManagerChecks()
    let socketsBefore = openTCPSockets()
    disabledChecks()
    networkingChecks()
    wrongPasscodeChecks()
    tieBreakChecks()
    policyAndConfigChecks()
    reentrancyChecks()
    heartbeatChecks()
    bonjourChecks()
    bonjourPreferChecks()
    print("Resource release")
    let released = waitUntil(4) { openTCPSockets() <= socketsBefore }
    check(released, "every listener / connection socket is released after stop() (\(socketsBefore) before, \(openTCPSockets()) after)")
    if !released {
        print(runProcess("/usr/sbin/lsof", ["-nP", "-a", "-p", String(getpid()), "-iTCP"]) ?? "")
        print(portOwners.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
    }
}
for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
print(failures == 0 ? "PeerLinkCheck: ALL PASSED" : "PeerLinkCheck: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
