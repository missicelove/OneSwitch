import Foundation
import Combine
import os
import OneSwitchCore

/// Result of running a command with administrator privileges.
enum PrivilegedResult: Equatable, Sendable {
    case success
    case cancelled
    case failed(String)
}

/// Everything BridgeManager needs from the OS. All methods block; call them off the main thread.
/// Self-checks inject a fake so no system setting is ever changed.
protocol BridgeSystem: Sendable {
    func listServiceOrder() -> String?
    func serviceInfo(_ service: String) -> String?
    /// Runs a shell command as root after the macOS administrator password dialog.
    func runPrivileged(command: String, prompt: String) -> PrivilegedResult
    func ipv4Addresses() -> [ThunderboltBridge.InterfaceAddress]
    func isLinkActive(_ interface: String) -> Bool?
    /// Terminates in-flight helper processes (called on quit).
    func cancelRunning()
}

/// The real implementation: `networksetup` for reads, and AppleScript
/// `do shell script … with administrator privileges` for writes.
///
/// The AppleScript runs in `/usr/bin/osascript` on a background queue rather than through NSAppleScript:
/// NSAppleScript is main-thread-only and would freeze the whole menu-bar app (including 键鼠共享's
/// event forwarding) for as long as the password dialog is open. The script and the dialog are the same.
final class SystemBridge: BridgeSystem, @unchecked Sendable {
    private let running = OSAllocatedUnfairLockBox<[Process]>([])

    func listServiceOrder() -> String? {
        run(ThunderboltBridge.networksetupPath, ["-listnetworkserviceorder"]).flatMap { $0.status == 0 ? $0.out : nil }
    }

    func serviceInfo(_ service: String) -> String? {
        run(ThunderboltBridge.networksetupPath, ["-getinfo", service]).map(\.out)
    }

    func runPrivileged(command: String, prompt: String) -> PrivilegedResult {
        let script = ThunderboltBridge.privilegedAppleScript(command: command, prompt: prompt)
        guard let result = run("/usr/bin/osascript", ["-e", script]) else {
            return .failed("无法启动 osascript")
        }
        if result.status == 0 { return .success }
        if result.err.contains("-128") || result.err.localizedCaseInsensitiveContains("User canceled") {
            return .cancelled
        }
        if result.status == 15 || result.status == -15 { return .cancelled }  // terminated by cancelRunning()
        let message = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(message.isEmpty ? "退出码 \(result.status)" : message)
    }

    func ipv4Addresses() -> [ThunderboltBridge.InterfaceAddress] { ThunderboltBridge.ipv4Addresses() }

    func isLinkActive(_ interface: String) -> Bool? { ThunderboltBridge.isLinkActive(interface) }

    /// Terminates helper processes still running (e.g. a password dialog left open while quitting).
    func cancelRunning() {
        let processes = running.get()
        for p in processes where p.isRunning { p.terminate() }
    }

    private func run(_ path: String, _ arguments: [String]) -> (status: Int32, out: String, err: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            AppLog.error("peerlink", "failed to run \(path): \(error.localizedDescription)")
            return nil
        }
        running.update { $0.append(process) }
        defer { running.update { $0.removeAll { $0 === process } } }
        // Drain stderr concurrently so a chatty command can never dead-lock on a full pipe.
        let errData = OSAllocatedUnfairLockBox(Data())
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: out, as: UTF8.self),
                String(decoding: errData.get(), as: UTF8.self))
    }
}

/// Tiny lock box for passing a value between threads.
final class OSAllocatedUnfairLockBox<T>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<T>
    init(_ value: T) { lock = OSAllocatedUnfairLock(uncheckedState: value) }
    func get() -> T { lock.withLockUnchecked { $0 } }
    func set(_ value: T) { lock.withLockUnchecked { $0 = value } }
    func update(_ body: (inout T) -> Void) { lock.withLockUnchecked { body(&$0) } }
}

/// Thunderbolt Bridge status for the UI plus the “自动配置雷雳网桥静态 IP” actions.
@MainActor
final class BridgeManager: ObservableObject {
    struct State: Equatable {
        var device = ThunderboltBridge.defaultDevice
        var serviceName: String?
        var serviceEnabled = true
        /// networksetup ran but no service is bound to the bridge device.
        var serviceMissing = false
        var config: ThunderboltBridge.ServiceIPConfig?
        /// Cable / link present (SIOCGIFMEDIA on the bridge). nil = unknown / no such interface.
        var linkActive: Bool?
        /// IPv4 addresses currently on the bridge device.
        var addresses: [String] = []
        var busy = false
        var message: String?
        var messageIsError = false
        var lastRefresh: Date?

        /// Preferred address for display: a configured one over a self-assigned 169.254.x.x.
        var primaryAddress: String? {
            addresses.first { !IPv4.isLinkLocal($0) } ?? addresses.first
        }
    }

    enum Trigger: Equatable { case automatic, user }

    enum Outcome: Equatable {
        case alreadyConfigured
        case applied
        case cancelled
        case failed(String)
    }

    @Published private(set) var state = State()
    /// Called on the main actor when the bridge addresses or link state change.
    var onLinkChange: (() -> Void)?

    private let system: BridgeSystem
    /// Reads (networksetup queries, link polling). Never blocks for long.
    private let workQueue = DispatchQueue(label: "oneswitch.peerlink.bridge", qos: .utility)
    /// Writes: blocks for as long as the administrator password dialog is open (possibly minutes at
    /// login), so it must not share a serial queue with the link monitor / refresh.
    private let privilegedQueue = DispatchQueue(label: "oneswitch.peerlink.bridge.admin", qos: .userInitiated)
    private var pollTimer: DispatchSourceTimer?
    private var refreshGeneration = 0
    /// The bridge device name, readable from the poll queue.
    private let deviceBox = OSAllocatedUnfairLockBox(ThunderboltBridge.defaultDevice)

    init(system: BridgeSystem) {
        self.system = system
    }

    // MARK: Monitoring

    /// Polls the bridge's addresses and link state (cheap syscalls, off the main thread).
    func startMonitoring(interval: TimeInterval = 5) {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .seconds(1))
        let system = self.system
        let deviceBox = self.deviceBox
        timer.setEventHandler { [weak self] in
            let device = deviceBox.get()
            let addresses = system.ipv4Addresses().filter { $0.name == device }.map(\.address)
            let link = system.isLinkActive(device)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyLink(addresses: addresses, link: link) }
            }
        }
        timer.resume()
        pollTimer = timer
    }

    func stopMonitoring() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    /// Called on quit: stop polling and close a password dialog that may still be open.
    func shutDown() {
        stopMonitoring()
        system.cancelRunning()
    }

    private func applyLink(addresses: [String], link: Bool?) {
        guard addresses != state.addresses || link != state.linkActive else { return }
        let first = state.lastRefresh == nil && state.addresses.isEmpty && state.linkActive == nil
        state.addresses = addresses
        state.linkActive = link
        if !first {
            AppLog.info("peerlink", "bridge \(state.device): link \(link.map { $0 ? "active" : "inactive" } ?? "unknown"), addresses \(addresses)")
        }
        onLinkChange?()
    }

    // MARK: Reads

    /// Re-reads the network service and its configuration (spawns networksetup off the main thread).
    func refresh(completion: (() -> Void)? = nil) {
        refreshGeneration += 1
        let generation = refreshGeneration
        let system = self.system
        workQueue.async { [weak self] in
            let snapshot = Self.readState(system: system)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if generation == self.refreshGeneration {
                        let old = self.state
                        self.state = snapshot
                        self.deviceBox.set(snapshot.device)
                        self.state.busy = old.busy
                        self.state.message = old.message
                        self.state.messageIsError = old.messageIsError
                        if old.addresses != snapshot.addresses || old.linkActive != snapshot.linkActive {
                            self.onLinkChange?()
                        }
                    }
                    completion?()
                }
            }
        }
    }

    nonisolated private static func readState(system: BridgeSystem) -> State {
        var s = State()
        s.lastRefresh = Date()
        if let order = system.listServiceOrder() {
            let services = ThunderboltBridge.parseServiceOrder(order)
            if let svc = ThunderboltBridge.thunderboltService(in: services) {
                s.serviceName = svc.name
                s.serviceEnabled = svc.enabled
                s.device = svc.device.isEmpty ? ThunderboltBridge.defaultDevice : svc.device
                s.config = system.serviceInfo(svc.name).flatMap(ThunderboltBridge.parseServiceInfo)
            } else {
                s.serviceMissing = true
            }
        }
        s.addresses = system.ipv4Addresses().filter { $0.name == s.device }.map(\.address)
        s.linkActive = system.isLinkActive(s.device)
        return s
    }

    // MARK: Writes (password dialog)

    /// Makes the bridge service manual with `ip`/`mask` unless it already is.
    func configure(ip: String, mask: String, trigger: Trigger, completion: @escaping (Outcome) -> Void) {
        guard !state.busy else { return }
        guard IPv4.isValidHost(ip) else {
            finish(.failed("IP 地址无效：\(ip)"), completion)
            return
        }
        guard IPv4.isValidMask(mask) else {
            finish(.failed("子网掩码无效：\(mask)"), completion)
            return
        }
        state.busy = true
        state.message = trigger == .automatic ? "正在检查雷雳网桥配置…" : "正在配置雷雳网桥…"
        state.messageIsError = false
        let system = self.system
        privilegedQueue.async { [weak self] in
            let outcome = Self.applyManual(system: system, ip: ip, mask: mask)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(outcome, completion, ip: ip) }
            }
        }
    }

    /// 恢复为自动（DHCP）.
    func restoreDHCP(completion: @escaping (Outcome) -> Void) {
        guard !state.busy else { return }
        state.busy = true
        state.message = "正在恢复为自动（DHCP）…"
        state.messageIsError = false
        let system = self.system
        privilegedQueue.async { [weak self] in
            let outcome = Self.applyDHCP(system: system)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.state.busy = false
                    switch outcome {
                    case .applied, .alreadyConfigured:
                        self.setMessage("已恢复为自动（DHCP）", error: false)
                    case .cancelled:
                        self.setMessage("已取消", error: false)
                    case .failed(let why):
                        self.setMessage("恢复失败：\(why)", error: true)
                    }
                    self.refresh()
                    completion(outcome)
                }
            }
        }
    }

    private func finish(_ outcome: Outcome, _ completion: (Outcome) -> Void, ip: String? = nil) {
        state.busy = false
        switch outcome {
        case .alreadyConfigured:
            setMessage("雷雳网桥已是静态 IP \(ip ?? "")", error: false)
        case .applied:
            setMessage("已将雷雳网桥设置为 \(ip ?? "")", error: false)
            AppLog.info("peerlink", "Thunderbolt bridge set to manual \(ip ?? "")")
        case .cancelled:
            setMessage("已取消配置。点击“立即配置”可重新尝试。", error: false)
            AppLog.info("peerlink", "static IP configuration cancelled by the user")
        case .failed(let why):
            setMessage("配置失败：\(why)", error: true)
            AppLog.warning("peerlink", "static IP configuration failed: \(why)")
        }
        refresh()
        completion(outcome)
    }

    private func setMessage(_ text: String, error: Bool) {
        state.message = text
        state.messageIsError = error
    }

    nonisolated static func resolveService(system: BridgeSystem) -> ThunderboltBridge.NetworkService? {
        guard let order = system.listServiceOrder() else { return nil }
        return ThunderboltBridge.thunderboltService(in: ThunderboltBridge.parseServiceOrder(order))
    }

    nonisolated static func applyManual(system: BridgeSystem, ip: String, mask: String) -> Outcome {
        guard let service = resolveService(system: system) else {
            return .failed("未找到雷雳网桥网络服务（系统设置 → 网络 中应有“雷雳网桥 / Thunderbolt Bridge”）")
        }
        let current = system.serviceInfo(service.name).flatMap(ThunderboltBridge.parseServiceInfo)
        var commands: [String] = []
        let needsAddress = !ThunderboltBridge.isConfigured(current, ip: ip, mask: mask)
        do {
            if needsAddress {
                commands.append(try ThunderboltBridge.setManualCommand(service: service.name, ip: ip, mask: mask))
            }
            // A disabled (“(*)”) bridge service would keep the link down even with the right address.
            if !service.enabled {
                commands.append(try ThunderboltBridge.enableServiceCommand(service: service.name))
            }
        } catch {
            return .failed("无法生成配置命令")
        }
        if commands.isEmpty { return .alreadyConfigured }
        let command = commands.joined(separator: " && ")
        var prompt: String
        if needsAddress {
            prompt = "OneSwitch 需要将“\(service.name)”的 IP 地址设置为 \(ip)"
            if current?.router != nil { prompt += "（并移除网桥上的路由器设置，以免影响上网）" }
            if !service.enabled { prompt += "，并启用该网络服务" }
        } else {
            prompt = "OneSwitch 需要启用网络服务“\(service.name)”"
        }
        prompt += "，以便两台 Mac 通过雷雳线直接互联。"
        if current?.router != nil {
            AppLog.warning("peerlink", "bridge service has a router (\(current?.router ?? "")); reconfiguring without one")
        }
        switch system.runPrivileged(command: command, prompt: prompt) {
        case .success: return .applied
        case .cancelled: return .cancelled
        case .failed(let why): return .failed(why)
        }
    }

    nonisolated static func applyDHCP(system: BridgeSystem) -> Outcome {
        guard let service = resolveService(system: system) else {
            return .failed("未找到雷雳网桥网络服务")
        }
        let current = system.serviceInfo(service.name).flatMap(ThunderboltBridge.parseServiceInfo)
        if current?.method == .dhcp { return .alreadyConfigured }
        guard let command = try? ThunderboltBridge.setDHCPCommand(service: service.name) else {
            return .failed("无法生成配置命令")
        }
        let prompt = "OneSwitch 需要将“\(service.name)”恢复为自动获取 IP 地址（DHCP）。"
        switch system.runPrivileged(command: command, prompt: prompt) {
        case .success: return .applied
        case .cancelled: return .cancelled
        case .failed(let why): return .failed(why)
        }
    }
}
