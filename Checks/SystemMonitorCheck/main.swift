import AppKit
import Darwin
import Foundation
import Metal
import OneSwitchCore
import SwiftUI
@testable import SystemMonitor

// Self-checks for the SystemMonitor module. Exit code 0 = all checks passed.
// Set SM_RENDER_DIR=/some/dir to also write the rendered status-item images as PNG files.

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
func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

@MainActor
func spin(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
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

/// UserDefaults backed by a plist in the temp directory (absolute-path suite), so the checks leave no
/// files in ~/Library/Preferences. Call `removeTempDefaults` when done.
func tempDefaults(_ name: String) -> (UserDefaults, String) {
    let path = NSTemporaryDirectory() + "oneswitch.systemmonitorcheck.\(name).\(getpid())"
    return (UserDefaults(suiteName: path)!, path)
}

func removeTempDefaults(_ d: UserDefaults, _ path: String) {
    d.removePersistentDomain(forName: path)
    try? FileManager.default.removeItem(atPath: path + ".plist")
}

func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "nil" }
func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "nil" }

// MARK: - Real samplers

@MainActor
func checkRealSamplers() {
    print("Environment: \(AppEnvironment.hardwareModel), \(ProcessInfo.processInfo.processorCount) CPUs, " +
          "\(MemorySampler.physicalMemory / 1_073_741_824) GB, laptop: \(AppEnvironment.isLaptop)")

    let engine = MonitorEngine { _ in }
    let all = Set(MonitorMetric.allCases)
    let first = engine.sampleNow(all, includeProcesses: true)
    Thread.sleep(forTimeInterval: 1.2)
    let second = engine.sampleNow(all, includeProcesses: true)
    let diag = engine.diagnostics()

    print("CPU")
    check(first.cpu == nil, "first CPU pass is the baseline (no reading)")
    if let c = second.cpu {
        print("    total \(pct(c.total)) user \(pct(c.user)) system \(pct(c.system)) P \(pct(c.performanceCores)) E \(pct(c.efficiencyCores))")
        check((0...1).contains(c.total) && (0...1).contains(c.user) && (0...1).contains(c.system), "CPU fractions within 0…1")
        check(abs(c.user + c.system - c.total) < 0.001, "user + system == total")
        check(c.perCore.count == ProcessInfo.processInfo.processorCount, "per-core count == processor count (\(c.perCore.count))")
        let p = sysctlInt("hw.perflevel0.logicalcpu"), e = sysctlInt("hw.perflevel1.logicalcpu")
        if let p, let e, p + e == ProcessInfo.processInfo.processorCount {
            check(diag.coreLayoutKnown, "core layout read from the device tree")
            check(c.performanceCoreCount == p && c.efficiencyCoreCount == e,
                  "P/E counts match sysctl perflevel0/1 (\(c.performanceCoreCount)P + \(c.efficiencyCoreCount)E)")
            check(c.performanceCores.map { (0...1).contains($0) } ?? false, "P-core average within 0…1")
            check(c.efficiencyCores.map { (0...1).contains($0) } ?? false, "E-core average within 0…1")
            // Apple Silicon lists E-cores first: verify against the device tree mapping.
            if let kinds = CPUSampler.readCoreKinds() {
                let firstP = kinds.firstIndex(of: .performance) ?? -1
                print("    device-tree order: \(kinds.map { $0 == .performance ? "P" : "E" }.joined())")
                check(firstP == e && kinds.prefix(e).allSatisfy { $0 == .efficiency }, "E-cores come first in the processor list")
            }
        }
    } else {
        check(false, "second CPU pass returns a reading")
    }

    print("GPU")
    let scan = GPUSampler.scan(cached: [:])
    if let g = second.gpu {
        print("    \(g.name): \(pct(g.utilization)) (\(g.source.rawValue)), in use \(g.memoryInUse.map { MonitorFormat.bytes($0) } ?? "n/a"), " +
              "allocated \(g.memoryAllocated.map { MonitorFormat.bytes($0) } ?? "n/a"), \(scan.clients.count) clients")
        check((0...1).contains(g.utilization), "GPU utilisation within 0…1")
        if scan.accelerators.contains(where: \.reportsClientTime) {
            check(first.gpu == nil, "first GPU pass is the baseline (\"--\", never an instantaneous 0)")
            check(g.source == .clientTime && diag.gpuSource == .clientTime, "per-client GPU time used (Apple silicon)")
            check(!scan.clients.isEmpty && scan.clients.values.contains { $0.pid != nil && !$0.creatorName.isEmpty },
                  "GPU clients with pid + name found")
            check(g.memoryInUse.map { $0 > 0 } ?? false && g.memoryAllocated.map { $0 > 0 } ?? false, "GPU memory in use / allocated read")
            let procs = second.gpuProcesses ?? []
            print("    GPU processes: " + procs.map { "\($0.name)\($0.processName.map { "（\($0)）" } ?? "") \(pct($0.fraction))" }.joined(separator: ", "))
            check(second.gpuProcesses != nil, "top GPU processes delivered with includeProcesses")
            check(zip(procs, procs.dropFirst()).allSatisfy { $0.fraction >= $1.fraction } && procs.count <= GPUSampler.processLimit,
                  "GPU processes sorted by share, ≤ \(GPUSampler.processLimit)")
        }
    } else {
        check(scan.accelerators.isEmpty, "GPU reading available when an accelerator exists")
        print("    no IOAccelerator statistics on this Mac")
    }

    print("Memory")
    if let m = second.memory {
        print("    used \(MonitorFormat.bytes(m.used)) / \(MonitorFormat.bytes(m.total)) (\(pct(m.fraction))) app \(MonitorFormat.bytes(m.app)) " +
              "wired \(MonitorFormat.bytes(m.wired)) compressed \(MonitorFormat.bytes(m.compressed)) cached \(MonitorFormat.bytes(m.cached)) " +
              "swap \(MonitorFormat.bytes(m.swapUsed))/\(MonitorFormat.bytes(m.swapTotal)) pressure \(m.pressure.title)")
        check((0...1).contains(m.fraction), "memory fraction within 0…1")
        check(m.total == MemorySampler.physicalMemory && m.total > 0, "total == hw.memsize")
        check(m.used == min(m.total, m.app + m.wired + m.compressed), "used = app + wired + compressed")
        check(m.pressure != .unknown, "memory pressure level read (\(m.pressure.title))")
        check(m.swapUsed <= max(m.swapTotal, m.swapUsed), "swap usage read")
    } else {
        check(false, "memory reading available")
    }

    print("Network")
    if let n1 = first.network, let n2 = second.network {
        for i in n2.interfaces {
            print("    \(i.label) (\(i.bsdName)) ↑\(MonitorFormat.rate(i.up)) ↓\(MonitorFormat.rate(i.down)) in \(i.bytesIn) out \(i.bytesOut)")
        }
        print("    total ↑\(MonitorFormat.rate(n2.up)) ↓\(MonitorFormat.rate(n2.down))")
        check(!n2.interfaces.isEmpty, "at least one counted interface")
        var monotonic = true
        for i in n2.interfaces {
            if let before = n1.interfaces.first(where: { $0.bsdName == i.bsdName }),
               i.bytesIn < before.bytesIn || i.bytesOut < before.bytesOut { monotonic = false }
        }
        check(monotonic, "per-interface 64-bit counters non-decreasing")
        check(n2.up >= 0 && n2.down >= 0, "rates non-negative")
        let names = Set(n2.interfaces.map(\.bsdName))
        let excluded = names.filter { n in NetworkSampler.excludedPrefixes.contains { n.hasPrefix($0) } }
        check(excluded.isEmpty, "no excluded interfaces counted (lo0/utun/awdl/llw/anpi/gif/stf/ap…)")
        if names.contains("bridge0") {
            check(n2.interfaces.first { $0.bsdName == "bridge0" }?.label == "雷雳网桥", "bridge0 labelled 雷雳网桥")
            check(!names.contains("en2") && !names.contains("en3"), "bridge member ports (en2/en3) not double counted")
        }
        let sumUp = n2.interfaces.reduce(0) { $0 + $1.up }
        check(abs(sumUp - n2.up) < 0.001, "全部接口 = sum of counted interfaces")
        if let firstIface = n2.interfaces.first {
            let single = engine.sampleNow([.network], networkInterface: firstIface.bsdName)
            check(single.network?.selection == firstIface.bsdName && single.network?.selectionLabel == firstIface.label,
                  "specific interface selection (\(firstIface.bsdName))")
        }
    } else {
        check(false, "network readings available")
    }

    print("Disk")
    if let d1 = first.disk, let d2 = second.disk {
        print("    read \(MonitorFormat.rate(d2.readRate)) write \(MonitorFormat.rate(d2.writeRate)) total R \(d2.bytesRead) W \(d2.bytesWritten) " +
              "capacity \(d2.capacityTotal.map { MonitorFormat.bytes($0) } ?? "nil") used \(pct(d2.usedFraction))")
        check(d2.bytesRead >= d1.bytesRead && d2.bytesWritten >= d1.bytesWritten, "disk counters non-decreasing")
        check(d2.bytesRead > 0, "physical drivers found (bytes read > 0)")
        check(d2.readRate >= 0 && d2.writeRate >= 0, "disk rates non-negative")
        check(d2.usedFraction.map { (0...1).contains($0) } ?? false, "boot volume used fraction within 0…1")
    } else {
        check(false, "disk readings available")
    }

    print("Power")
    if let p = second.power {
        print("    system \(f1(p.systemWatts)) W via \(p.sourceKey ?? "-")" +
              (p.battery.map { b in ", battery \(pct(b.level)) charging \(b.isCharging) AC \(b.onAC) \(f1(b.batteryWatts)) W adapter \(f1(b.adapterWatts)) W" } ?? ""))
        if let w = p.systemWatts {
            check((1...500).contains(w), "system power within 1…500 W (\(f1(w)) W from \(p.sourceKey ?? "?"))")
        }
        if AppEnvironment.isLaptop { check(p.battery != nil, "battery reading on a laptop") }
    } else {
        print("    no SMC power key and no battery on this Mac")
    }

    print("Temperature")
    if let t = second.temperature {
        print("    source \(t.source.rawValue): CPU avg \(f1(t.cpuAverage)) max \(f1(t.cpuMax)) (\(t.cpuSensorCount) sensors), " +
              "GPU avg \(f1(t.gpuAverage)) max \(f1(t.gpuMax)) (\(t.gpuSensorCount) sensors)")
        print("    SMC CPU keys used (\(diag.smcCPUKeys.count)): \(diag.smcCPUKeys.prefix(24).joined(separator: " "))\(diag.smcCPUKeys.count > 24 ? " …" : "")")
        print("    SMC GPU keys used (\(diag.smcGPUKeys.count)): \(diag.smcGPUKeys.prefix(24).joined(separator: " "))\(diag.smcGPUKeys.count > 24 ? " …" : "")")
        if !diag.hidSensors.isEmpty { print("    HID sensors used: \(diag.hidSensors.joined(separator: ", "))") }
        let values = [t.cpuAverage, t.cpuMax, t.gpuAverage, t.gpuMax].compactMap { $0 }
        check(!values.isEmpty && values.allSatisfy { (10...120).contains($0) }, "temperatures within 10…120 °C")
        if let a = t.cpuAverage, let m = t.cpuMax { check(a <= m + 0.001, "CPU average ≤ max") }
        if let generation = SensorSampler.chipGeneration, generation != 3 {
            check(!(diag.smcCPUKeys + diag.smcGPUKeys).contains { $0.hasPrefix("Tf") },
                  "M\(generation): no M3-only Tf keys in the CPU / GPU groups")
        }
    } else {
        print("    no temperature sensors found")
    }

    print("SMC / HID probe")
    if let smc = SMCClient() {
        let keyCount = smc.keyCount() ?? 0
        let keys = smc.enumerateKeys { SensorSampler.isCPUKey($0) || SensorSampler.isGPUKey($0) || $0.hasPrefix("PS") || $0.hasPrefix("PD") || $0.hasPrefix("PP") }
        let describe: ([(key: UInt32, name: String, info: SMCClient.KeyInfo)]) -> String = { list in
            list.prefix(40).map { k in "\(k.name)=\(f1(smc.readNumber(k.key)))" }.joined(separator: " ")
        }
        print("    #KEY = \(keyCount); temperature/power keys: \(keys.count)")
        print("    Tp/Te: " + describe(keys.filter { SensorSampler.isCPUKey($0.name) }))
        print("    Tg:    " + describe(keys.filter { SensorSampler.isGPUKey($0.name) }))
        print("    power: " + SensorSampler.powerKeys.map { "\($0)=\(f1(smc.readNumber($0)))" }.joined(separator: " "))
        check(keyCount > 0, "SMC #KEY readable")
        smc.close()
        check(!smc.isOpen, "SMC connection closed")
    } else {
        print("    AppleSMC not available")
    }
    let hid = HIDTemperatureReader()
    let hidSensors = hid.readAll()
    print("    HID API available: \(HIDTemperatureReader.isAvailable), sensors: \(hidSensors.count)")
    let tdie = hidSensors.filter { $0.name.localizedCaseInsensitiveContains("tdie") }
    if !tdie.isEmpty {
        let avg = tdie.map(\.celsius).reduce(0, +) / Double(tdie.count)
        print("    HID tdie (\(tdie.count)): avg \(f1(avg)) — " + tdie.prefix(12).map { "\($0.name)=\(f1($0.celsius))" }.joined(separator: " "))
        check((10...120).contains(avg), "HID tdie average within 10…120 °C")
    }
    hid.close()

    print("Top processes")
    if let procs = second.processes {
        for p in procs { print("    \(p.pid) \(p.name) \(String(format: "%.1f", p.cpuPercent))%") }
        check(!procs.isEmpty && procs.count <= 5, "top processes parsed (≤ 5)")
        check(zip(procs, procs.dropFirst()).allSatisfy { $0.cpuPercent >= $1.cpuPercent }, "sorted by CPU descending")
    } else {
        check(false, "ps output available")
    }

    // Every io_object_t / io_connect_t is a Mach port name in this task: a missing IOObjectRelease or
    // IOServiceClose shows up as a growing name count. mach_host_self() adds a send-right reference per call.
    print("IOKit / Mach port hygiene")
    for _ in 0..<3 { _ = engine.sampleNow(all) } // warm-up: SMC connection, key caches, CPU layout
    let names0 = machPortNameCount(), refs0 = hostPortSendRefs()
    for _ in 0..<40 { _ = engine.sampleNow(all) }
    let names1 = machPortNameCount(), refs1 = hostPortSendRefs()
    check(names1 - names0 <= 3, "no IOKit object / Mach port leak over 40 passes of every sampler (\(names0) → \(names1) names)")
    check(refs1 == refs0, "host port references stable across passes (\(refs0) → \(refs1))")

    // The GPU pass reads every GPU client's AppUsage (~100 registry entries): keep it cheap.
    var cachedClients = GPUSampler.scan(cached: [:]).clients
    var durations: [Double] = []
    for _ in 0..<15 {
        let t0 = monotonicSeconds()
        cachedClients = GPUSampler.scan(cached: cachedClients).clients
        durations.append((monotonicSeconds() - t0) * 1000)
    }
    let median = durations.sorted()[durations.count / 2]
    check(median < 20, String(format: "GPU registry pass is cheap (median %.1f ms for %d clients)", median, cachedClients.count))

    engine.stop()
    let names2 = machPortNameCount()
    check(second.temperature == nil && second.power == nil || names2 < names1,
          "stop() closes the SMC connection (\(names1) → \(names2) port names)")
}

/// Number of Mach port names in this task.
func machPortNameCount() -> Int {
    var names: mach_port_name_array_t?
    var namesCount: mach_msg_type_number_t = 0
    var types: mach_port_type_array_t?
    var typesCount: mach_msg_type_number_t = 0
    guard mach_port_names(mach_task_self_, &names, &namesCount, &types, &typesCount) == KERN_SUCCESS else { return -1 }
    if let names {
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: names), vm_size_t(Int(namesCount) * MemoryLayout<mach_port_name_t>.stride))
    }
    if let types {
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: types), vm_size_t(Int(typesCount) * MemoryLayout<mach_port_type_t>.stride))
    }
    return Int(namesCount)
}

/// User references on this task's send right to the host port.
func hostPortSendRefs() -> mach_port_urefs_t {
    let host = mach_host_self()
    var refs: mach_port_urefs_t = 0
    mach_port_get_refs(mach_task_self_, host, MACH_PORT_RIGHT_SEND, &refs)
    mach_port_deallocate(mach_task_self_, host) // balance the reference taken above
    return refs
}

// MARK: - Pure logic

@MainActor
func checkPureLogic() {
    print("CPU tick math")
    let prev: [[UInt64]] = [[100, 50, 850, 0], [1000, 500, 8500, 0]]
    let cur: [[UInt64]] = [[150, 100, 950, 0], [1300, 600, 8600, 0]] // CPU0: 100 busy / 200; CPU1: 400 / 500
    if let r = CPUSampler.reading(previous: prev, current: cur, coreKinds: [.efficiency, .performance]) {
        check(abs(r.total - 500.0 / 700.0) < 1e-9, "total = busy / all (\(pct(r.total)))")
        check(abs(r.efficiencyCores! - 0.5) < 1e-9 && abs(r.performanceCores! - 0.8) < 1e-9, "E / P cluster averages")
        check(abs(r.user - 350.0 / 700.0) < 1e-9 && abs(r.system - 150.0 / 700.0) < 1e-9, "user / system split")
    } else {
        check(false, "CPU reading computed")
    }
    let wrapped = CPUSampler.reading(previous: [[UInt64(UInt32.max) - 5, 0, 100, 0]], current: [[3, 0, 200, 0]], coreKinds: nil)
    check(wrapped.map { (0...1).contains($0.total) && $0.performanceCores == nil } ?? false, "wrapped counter tolerated; unknown layout → total only")
    // 32-bit tick counters wrap: the modular delta is the real one (9 busy of 109), not a 0-idle 100 % spike.
    check(wrapped.map { abs($0.total - 9.0 / 109.0) < 1e-9 } ?? false, "wrapped 32-bit counter → modular delta (\(pct(wrapped?.total)))")
    let idleWrapped = CPUSampler.reading(previous: [[10, 10, UInt64(UInt32.max) - 49, 0]], current: [[20, 10, 50, 0]], coreKinds: nil)
    check(idleWrapped.map { abs($0.total - 10.0 / 110.0) < 1e-9 } ?? false, "wrapped idle counter does not read as 100 % busy")
    let reset = CPUSampler.reading(previous: [[4_000_000, 0, 9_000_000, 0]], current: [[10, 0, 100, 0]], coreKinds: nil)
    check(reset.map { $0.total == 0 } ?? false, "counter reset (huge modular delta) counts as 0")
    check(CPUSampler.reading(previous: [[0, 0, 0, 0]], current: [[0, 0, 0, 0], [0, 0, 0, 0]], coreKinds: nil) == nil,
          "CPU count change → no reading")

    print("Memory math")
    var vm = vm_statistics64()
    vm.internal_page_count = 1000
    vm.purgeable_count = 100
    vm.wire_count = 200
    vm.compressor_page_count = 50
    vm.external_page_count = 300
    vm.free_count = 400
    let m = MemorySampler.reading(stats: vm, pageSize: 16384, total: 4000 * 16384, swapUsed: 0, swapTotal: 0, pressure: .warning)
    check(m.app == 900 * 16384 && m.wired == 200 * 16384 && m.compressed == 50 * 16384, "app = internal − purgeable, wired, compressed")
    check(m.used == 1150 * 16384 && abs(m.fraction - 1150.0 / 4000.0) < 1e-9, "used / fraction")
    check(m.cached == 400 * 16384, "cached = external + purgeable")
    check(MemoryPressure(rawValue: 4)?.title == "严重" && MemoryPressure(rawValue: 1)?.title == "正常"
          && MemoryPressure(rawValue: 2)?.title == "警告", "pressure levels 1/2/4 → 正常/警告/严重")

    print("GPU statistics parsing")
    check(GPUSampler.reading(from: ["Device Utilization %": 37, "In use system memory": 1024, "Alloc system memory": 4096], name: "x")
            == GPUReading(utilization: 0.37, memoryInUse: 1024, memoryAllocated: 4096, name: "x", source: .deviceUtilization),
          "Device Utilization % + in-use / allocated memory")
    check(GPUSampler.reading(from: ["Renderer Utilization %": 12], name: "x")?.utilization == 0.12, "fallback Renderer Utilization %")
    check(GPUSampler.reading(from: ["Tiler Utilization %": 5], name: "x") == nil, "no utilisation key → nil")
    check(GPUSampler.reading(from: ["Device Utilization %": 250], name: "x")?.utilization == 1, "clamped to 1")

    print("GPU busy time (per-client accumulatedGPUTime deltas)")
    let c = { (acc: UInt64, pid: Int32?, t: UInt64) in GPUClient(accelerator: acc, pid: pid, creatorName: "p\(pid ?? -1)", gpuTime: t) }
    let before: [UInt64: GPUClient] = [1: c(9, 10, 1_000), 2: c(9, 11, 5_000), 3: c(9, 12, 7_000)]
    let after: [UInt64: GPUClient] = [1: c(9, 10, 401_000), 2: c(9, 11, 4_000), 4: c(9, 13, 300_000), 5: c(9, 14, 9_000_000)]
    let busy = GPUSampler.busyTime(previous: before, current: after, elapsed: 1_000_000)
    check(busy[1] == 400_000, "known client: delta of its GPU time")
    check(busy[2] == nil, "shrinking counter (a queue went away) counts as 0")
    check(busy[3] == nil, "vanished client ignored")
    check(busy[4] == 300_000, "client created within the window counts with all its time")
    check(busy[5] == 1_000_000, "per-client time clamped to the window")

    print("GPU busy time per command queue (AppUsage entries come and go)")
    let ms: UInt64 = 1_000_000, window: UInt64 = 1_000 * ms
    // Measured on this Mac: release the 131 ms queue, create a new one → [42, 81, 269] ms (slot reused).
    check(GPUSampler.queueDelta(previous: [42 * ms, 131 * ms, 269 * ms], current: [42 * ms, 81 * ms, 269 * ms], elapsed: window) == 81 * ms,
          "queue released and replaced in the same slot: the new queue's time counts (a summed counter would read 0)")
    check(GPUSampler.queueDelta(previous: [42 * ms, 131 * ms, 269 * ms], current: [100 * ms, 269 * ms], elapsed: window) == 58 * ms,
          "queue released while another works: the growth counts (a summed counter would read 0)")
    check(GPUSampler.queueDelta(previous: [42 * ms, 131 * ms], current: [140 * ms, 131 * ms], elapsed: window) == 98 * ms,
          "no queue churn: exact sum of the growth, whatever the order")
    check(GPUSampler.queueDelta(previous: [500 * ms], current: [450 * ms], elapsed: window) == 450 * ms,
          "a new queue whose time is below the released one's still counts")
    check(GPUSampler.queueDelta(previous: [5 * ms], current: [], elapsed: window) == 0
          && GPUSampler.queueDelta(previous: [], current: [7_000 * ms], elapsed: window) == window,
          "all queues released → 0; a new queue is clamped to the window")
    let qc = { (times: [UInt64]) in GPUClient(accelerator: 9, pid: 20, creatorName: "q", gpuTime: times.reduce(0, +), queueTimes: times) }
    check(GPUSampler.busyTime(previous: [7: qc([500 * ms])], current: [7: qc([450 * ms])], elapsed: window)[7] == 450 * ms,
          "busyTime uses the per-queue counters")
    // Property: random queue churn, never more than the true GPU time; exact without releases.
    var rng = SystemRandomNumberGenerator()
    var overCounts = 0, inexactWithoutRelease = 0
    for _ in 0..<2_000 {
        var queues = (0..<Int.random(in: 0...4, using: &rng)).map { _ in UInt64.random(in: 0...5_000, using: &rng) * ms }
        let previous = queues
        var truth: UInt64 = 0
        var released = false
        for i in queues.indices.reversed() where Int.random(in: 0..<4, using: &rng) == 0 {
            queues.remove(at: i) // its time since the previous scan is lost for good
            released = true
        }
        for i in queues.indices {
            let grow = UInt64.random(in: 0...300, using: &rng) * ms
            queues[i] += grow
            truth += grow
        }
        for _ in 0..<Int.random(in: 0...2, using: &rng) {
            let t = UInt64.random(in: 0...300, using: &rng) * ms
            queues.insert(t, at: Int.random(in: 0...queues.count, using: &rng)) // may take a freed slot
            truth += t
        }
        let measured = GPUSampler.queueDelta(previous: previous, current: queues.shuffled(using: &rng), elapsed: window)
        if measured > truth { overCounts += 1 }
        if !released && measured != truth { inexactWithoutRelease += 1 }
    }
    check(overCounts == 0, "random queue churn (2000 cases): never more than the true GPU time")
    check(inexactWithoutRelease == 0, "random queue churn without releases: exact")

    let acc = GPUAcceleratorScan(id: 9, name: "AGX", deviceUtilization: 0, memoryInUse: 2 << 30, memoryAllocated: 40 << 30,
                                 reportsClientTime: true)
    let averaged = GPUSampler.reading(accelerators: [acc], busy: [9: 0.62])
    check(averaged == GPUReading(utilization: 0.62, memoryInUse: 2 << 30, memoryAllocated: 40 << 30, name: "AGX", source: .clientTime),
          "busy-time average wins over an instantaneous 0 (the model ran between two samples)")
    var longKernel = acc
    longKernel.deviceUtilization = 0.97
    check(GPUSampler.reading(accelerators: [longKernel], busy: [9: 0.3])?.utilization == 0.97,
          "instantaneous device utilisation is a floor (long command buffers report their time on completion)")
    check(GPUSampler.reading(accelerators: [acc], busy: [9: 1.7])?.utilization == 1, "concurrent clients clamped to 100%")
    check(GPUSampler.reading(accelerators: [acc], busy: [:])?.utilization == 0, "idle accelerator reads 0 (sampled, not missing)")
    let fallback = GPUAcceleratorScan(id: 3, name: "AMD", deviceUtilization: 0.4, memoryInUse: nil, memoryAllocated: nil)
    check(GPUSampler.reading(accelerators: [fallback, acc], busy: [9: 0.1]).map { ($0.name, $0.utilization, $0.source) }
            .map { $0 == "AMD" && $1 == 0.4 && $2 == .deviceUtilization } ?? false,
          "no per-client times → device utilisation; the busiest accelerator is reported")
    let second = GPUAcceleratorScan(id: 10, name: "AGX2", deviceUtilization: 0.1, memoryInUse: 7 << 30, memoryAllocated: 9 << 30,
                                    reportsClientTime: true)
    let twoGPUs = GPUSampler.evaluate(accelerators: [acc, second], busy: [9: 0.2, 10: 0.8])
    check(twoGPUs?.reading == GPUReading(utilization: 0.8, memoryInUse: 7 << 30, memoryAllocated: 9 << 30, name: "AGX2", source: .clientTime)
          && twoGPUs?.clientTime == 0.8 && twoGPUs?.device == 0.1,
          "two accelerators with client times: the busiest one, with its own memory figures")
    check(GPUSampler.evaluate(accelerators: [], busy: [:]) == nil
          && GPUSampler.evaluate(accelerators: [GPUAcceleratorScan(id: 1, name: "x")], busy: [:]) == nil,
          "no accelerator / no statistics → no reading (the UI shows --, later 不可用)")
    let top = GPUSampler.topProcesses([10: 900_000, 11: 3_000, 12: 50_000, 13: 50_000, 14: 2_000_000], elapsed: 1_000_000, limit: 3)
    check(top.map(\.0) == [14, 10, 12] && top.first?.1 == 1, "top GPU processes: sorted, clamped, < 0.5 % dropped, limited")
    check(GPUSampler.parseCreator("pid 3192, node") == (3192, "node") && GPUSampler.parseCreator("pid 610, WindowServer").pid == 610
          && GPUSampler.parseCreator("pid 1535, Lark Helper (GPU").name == "Lark Helper (GPU"
          && GPUSampler.parseCreator("kernel").pid == nil, "IOUserClientCreator parsed")
    check(GPUProcessNamer.outermostApp("/Applications/LM Studio.app/Contents/Frameworks/LM Studio Helper (GPU).app/Contents/MacOS/LM Studio Helper (GPU)")
            == "/Applications/LM Studio.app"
          && GPUProcessNamer.outermostApp("/Users/test/.lmstudio/.internal/utils/node") == nil, "outermost app bundle of a path")
    let own = GPUProcessNamer.name(pid: getpid(), fallback: "x")
    check(own.display == ProcessInfo.processInfo.processName && own.process == nil, "process outside an app → executable name (\(own.display))")
    let finderPID = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.processIdentifier
    if let finderPID {
        let finder = GPUProcessNamer.name(pid: finderPID, fallback: "Finder")
        check(!finder.display.hasSuffix(".app") && !finder.display.isEmpty, "app process → app display name (\(finder.display))")
    }

    print("GPU texts (popover / menu / settings)")
    let gpuText = GPUReading(utilization: 0.99, memoryInUse: UInt64(20.3 * 1_073_741_824), memoryAllocated: 43 << 30, name: "g")
    check(GPUDetail.value(gpuText) == "99% · 显存 20.3 GB" && GPUDetail.value(nil) == "--"
          && GPUDetail.value(GPUReading(utilization: 0.05, memoryInUse: nil, name: "g")) == "5%", "value: percent · 显存, -- when not sampled")
    check(GPUDetail.rows(gpuText) == [DetailLine("显存（使用中）", "20.3 GB"), DetailLine("显存（已分配）", "43.0 GB")], "popover rows")
    let preciseCases: [(UInt64, String)] = [(0, "0 B"), (512 << 20, "512 MB"), (UInt64(999.4 * 1_048_576), "999 MB"),
                                             (UInt64(999.6 * 1_048_576), "1.0 GB"), (UInt64(2.46 * 1_073_741_824), "2.5 GB"),
                                             (UInt64(99.94 * 1_073_741_824), "99.9 GB"), (UInt64(99.96 * 1_073_741_824), "100 GB"),
                                             (128 << 30, "128 GB"), (UInt64(999.6 * 1_073_741_824), "1.0 TB")]
    for (value, expected) in preciseCases {
        check(MonitorFormat.preciseBytes(value) == expected, "GPU memory \(value) B → \(MonitorFormat.preciseBytes(value)) (expected \(expected))")
    }
    check(!MonitorFormat.preciseBytes(UInt64.max).isEmpty, "GPU memory: huge values do not crash (\(MonitorFormat.preciseBytes(UInt64.max)))")
    check(GPUDetail.processRows([GPUProcessUsage(pid: 1, name: "LM Studio", processName: "node", fraction: 0.94),
                                 GPUProcessUsage(pid: 2, name: "WindowServer", processName: nil, fraction: 0.02)])
            == [DetailLine("LM Studio", "94%"), DetailLine("WindowServer", "2%")], "popover GPU process rows")
    check(MonitorFormat.compactBytes(UInt64(20.3 * 1_073_741_824)) == "20G" && MonitorFormat.compactBytes(nil) == "--"
          && MonitorFormat.compactBytes(512 << 20) == "512M", "compact memory for the status item")
    check(GPUSampler.reading(from: ["Device Utilization %": 250], name: "x")?.utilization == 1, "clamped to 1")

    print("SMC helpers")
    check(SMCClient.fourCC("PSTR") == 0x5053_5452 && SMCClient.string(fromFourCC: 0x5053_5452) == "PSTR", "four-char codes")
    let fltBytes = withUnsafeBytes(of: Float(52.25).bitPattern.littleEndian) { Array($0) }
    check(SMCClient.decode(fltBytes, type: SMCClient.fourCC("flt ")) == 52.25, "'flt ' little-endian")
    check(SMCClient.decode([0x28, 0x80], type: SMCClient.fourCC("sp78")) == 40.5, "'sp78' fixed point")
    check(SMCClient.decode([0, 0, 0x08, 0x4E], type: SMCClient.fourCC("ui32")) == 2126, "'ui32' big-endian")
    check(SMCClient.decode([0, 0x80, 0x33, 0, 0, 0, 0, 0], type: SMCClient.fourCC("ioft")) == 51.5, "'ioft' 48.16 little-endian")
    check(!SensorSampler.isPlausibleSMC(40.0) && !SensorSampler.isPlausibleSMC(0) && !SensorSampler.isPlausibleSMC(-4),
          "whole-number sentinels rejected")
    check(SensorSampler.isPlausibleSMC(36.8516) && !SensorSampler.isPlausibleSMC(130.5) && !SensorSampler.isPlausibleSMC(9.5),
          "10…120 °C window")
    check(SensorSampler.isCPUKey("Tp1k") && SensorSampler.isCPUKey("Te05") && !SensorSampler.isCPUKey("Tg05")
          && SensorSampler.isGPUKey("Tg0K"), "CPU (Tp/Te) and GPU (Tg) key prefixes")
    print("SMC key plan (M3 Pro MacBook Pro path)")
    check(SensorSampler.chipGeneration(brand: "Apple M3 Pro") == 3 && SensorSampler.chipGeneration(brand: "Apple M4 Max") == 4
          && SensorSampler.chipGeneration(brand: "Apple M3") == 3 && SensorSampler.chipGeneration(brand: "Apple M10 Ultra") == 10
          && SensorSampler.chipGeneration(brand: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz") == nil, "chip generation from the brand string")
    // M3 SMC: E-cores as "Te…", P-cores and GPU only as "Tf…" (Stats' M3 table); a Tg key may exist but be dead.
    let m3Available: Set<String> = Set(SensorSampler.m3CPUKeys + SensorSampler.m3GPUKeys + ["Tf06", "Tf16"])
    let m3 = SensorSampler.keyPlan(generation: 3, discovered: ["Te05", "Te0L", "Te0P", "Te0S", "Tg0X"]) { m3Available.contains($0) }
    check(Set(m3.cpu) == Set(["Te05", "Te0L", "Te0P", "Te0S"] + SensorSampler.m3CPUKeys), "M3: CPU = Te (E) + Tf P-core keys (\(m3.cpu.count))")
    check(Set(m3.gpu) == Set(["Tg0X"] + SensorSampler.m3GPUKeys), "M3: GPU keys include the Tf GPU keys even when a Tg key exists")
    check(!m3.cpu.contains("Tf06") && !m3.gpu.contains("Tf16"), "M3: unknown Tf keys ignored")
    let m3Missing = SensorSampler.keyPlan(generation: 3, discovered: ["Tp01"]) { $0 == "Tf04" }
    check(m3Missing.cpu == ["Tp01", "Tf04"] && m3Missing.gpu.isEmpty, "M3: only Tf keys that exist as 'flt ' are used")
    // M4 (this Mac): Tf keys exist but are other sensors — never mixed into CPU / GPU.
    let m4 = SensorSampler.keyPlan(generation: 4, discovered: ["Te04", "Tp1i", "Tg04"]) { _ in true }
    check(m4.cpu == ["Te04", "Tp1i"] && m4.gpu == ["Tg04"], "M4: Tp/Te + Tg only, Tf keys not added")
    let m4NoTg = SensorSampler.keyPlan(generation: 4, discovered: ["Te04"]) { _ in true }
    check(m4NoTg.gpu.isEmpty, "known non-M3 chip without Tg keys: GPU left to the HID fallback")
    let unknown = SensorSampler.keyPlan(generation: nil, discovered: ["Tp01"]) { _ in true }
    check(unknown.cpu == ["Tp01"] && unknown.gpu == SensorSampler.m3GPUKeys, "unknown chip without Tg keys: Tf GPU fallback")
    if let generation = SensorSampler.chipGeneration {
        print("    this Mac: generation M\(generation)")
    }

    let agg = SensorSampler.reading(cpu: [40, 50, 60], gpu: [], source: .smc)
    check(agg.cpuAverage == 50 && agg.cpuMax == 60 && agg.gpuAverage == nil, "temperature aggregation")
    check(agg.value(for: .gpu) == 50 && agg.value(for: .hottest) == 60, "GPU source falls back to CPU; 最高 = max")

    print("NET_RT_IFLIST2 parsing")
    checkIfList2()

    print("Interface rules")
    let up = UInt32(IFF_UP | IFF_RUNNING)
    check(NetworkSampler.isCounted(name: "bridge0", flags: up, hasAddress: true), "bridge0 counted")
    check(!NetworkSampler.isCounted(name: "en2", flags: up, hasAddress: false), "bridge member without address not counted")
    check(!NetworkSampler.isCounted(name: "en0", flags: 0, hasAddress: true), "down interface not counted")
    for name in ["lo0", "utun3", "awdl0", "llw0", "anpi1", "gif0", "stf0", "ap1", "ipsec0"] {
        check(!NetworkSampler.isCounted(name: name, flags: up, hasAddress: true), "\(name) excluded")
    }
    check(!NetworkSampler.isCounted(name: "bridge100", flags: up, hasAddress: true), "VM bridge100 excluded")
    check(NetworkSampler.isCounted(name: "en1", flags: up, hasAddress: true), "en1 counted")
    check(InterfaceNamer.label(bsdName: "bridge0", type: "Bridge", displayName: "Thunderbolt Bridge") == "雷雳网桥", "label 雷雳网桥")
    check(InterfaceNamer.label(bsdName: "en1", type: "IEEE80211", displayName: "Wi-Fi") == "Wi\u{2011}Fi", "label Wi‑Fi")
    check(InterfaceNamer.label(bsdName: "en0", type: "Ethernet", displayName: "Ethernet") == "以太网", "label 以太网")
    check(InterfaceNamer.label(bsdName: "en2", type: "Ethernet", displayName: "Thunderbolt 1") == "雷雳 1", "label 雷雳 1")
    check(InterfaceNamer.label(bsdName: "en7", type: "Ethernet", displayName: "Ethernet Adapter (en7)") == "以太网适配器", "label 以太网适配器")
    check(InterfaceNamer.label(bsdName: "en9", type: "Ethernet", displayName: "USB 10/100/1000 LAN") == "USB 10/100/1000 LAN", "USB adapter keeps its name")
    check(InterfaceNamer.label(bsdName: "zz0", type: nil, displayName: nil) == "zz0", "unknown → BSD name")

    print("Disk rules")
    check(DiskSampler.isPhysical(protocolCharacteristics: ["Physical Interconnect": "Apple Fabric", "Physical Interconnect Location": "Internal"]),
          "internal NVMe is physical")
    check(DiskSampler.isPhysical(protocolCharacteristics: ["Physical Interconnect": "USB", "Physical Interconnect Location": "External"]),
          "external USB is physical")
    check(!DiskSampler.isPhysical(protocolCharacteristics: ["Physical Interconnect": "Virtual Interface", "Physical Interconnect Location": "File"]),
          "disk image skipped")

    print("ps parsing")
    let ps = "  PID  %CPU COMM\n  812  23.5 WindowServer\n   91   0.0 kernel_task\n 4242 101.2 Google Chrome Helper (GPU)\nbad line\n"
    let parsed = ProcessSampler.parse(ps, limit: 5)
    check(parsed.map(\.pid) == [4242, 812, 91], "sorted by CPU")
    check(parsed.first?.name == "Google Chrome Helper (GPU)" && parsed.first?.cpuPercent == 101.2, "names with spaces kept")
    check(ProcessSampler.parse(ps, limit: 2).count == 2, "limit honoured")
}

/// Builds a synthetic NET_RT_IFLIST2 buffer and parses it; then cross-checks the real sysctl against getifaddrs.
func checkIfList2() {
    func header(index: UInt16, flags: Int32, ibytes: UInt64, obytes: UInt64, msgLen: Int) -> [UInt8] {
        var h = if_msghdr2()
        h.ifm_msglen = UInt16(msgLen)
        h.ifm_version = UInt8(RTM_VERSION)
        h.ifm_type = UInt8(RTM_IFINFO2)
        h.ifm_flags = flags
        h.ifm_index = index
        h.ifm_data.ifi_ibytes = ibytes
        h.ifm_data.ifi_obytes = obytes
        return withUnsafeBytes(of: &h) { Array($0) }
    }
    func sockaddrDL(index: UInt16, name: String) -> [UInt8] {
        let nameBytes = Array(name.utf8)
        var sdl: [UInt8] = [0, UInt8(AF_LINK), UInt8(index & 0xFF), UInt8(index >> 8), 6, UInt8(nameBytes.count), 0, 0]
        sdl += nameBytes
        while sdl.count < 20 || sdl.count % 4 != 0 { sdl.append(0) }
        sdl[0] = UInt8(sdl.count)
        return sdl
    }
    let hsize = IfList2.headerSize
    var buf: [UInt8] = []
    let sdl1 = sockaddrDL(index: 21, name: "bridge0")
    buf += header(index: 21, flags: Int32(IFF_UP | IFF_RUNNING), ibytes: 5_000_000_000, obytes: 123, msgLen: hsize + sdl1.count) + sdl1
    // An RTM_NEWADDR message in between must be skipped.
    var addrMsg = [UInt8](repeating: 0, count: 24)
    addrMsg[0] = 24
    addrMsg[2] = UInt8(RTM_VERSION)
    addrMsg[3] = UInt8(RTM_NEWADDR)
    buf += addrMsg
    // No sockaddr_dl: the name is resolved with if_indextoname (lo0's real index).
    let loIndex = UInt16(if_nametoindex("lo0"))
    buf += header(index: loIndex, flags: Int32(IFF_UP | IFF_LOOPBACK), ibytes: 7, obytes: 8, msgLen: hsize)
    let parsed = buf.withUnsafeBytes { IfList2.parse($0) }
    check(parsed.count == 2, "two RTM_IFINFO2 messages parsed, RTM_NEWADDR skipped")
    check(parsed.first == InterfaceCounters(index: 21, name: "bridge0", flags: UInt32(IFF_UP | IFF_RUNNING), bytesIn: 5_000_000_000, bytesOut: 123),
          "name from sockaddr_dl, 64-bit counter > 4 GB intact")
    check(parsed.count > 1 && parsed[1].name == "lo0" && parsed[1].bytesIn == 7, "name via if_indextoname fallback")
    // Truncated / corrupt buffers never crash.
    var truncated = buf
    truncated.removeLast(10)
    check(truncated.withUnsafeBytes { IfList2.parse($0) }.count == 1, "truncated last message ignored")
    check([UInt8](repeating: 0, count: 64).withUnsafeBytes { IfList2.parse($0) }.isEmpty, "zero-length message stops parsing")
    check([UInt8]().withUnsafeBytes { IfList2.parse($0) }.isEmpty, "empty buffer")

    // Real kernel data vs getifaddrs' 32-bit if_data counters.
    guard let real = IfList2.read() else {
        check(false, "sysctl NET_RT_IFLIST2 readable")
        return
    }
    check(!real.isEmpty, "sysctl NET_RT_IFLIST2 returned \(real.count) interfaces")
    var linkCounters: [String: (UInt32, UInt32)] = [:]
    var head: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&head) == 0 {
        var cursor = head
        while let ifa = cursor {
            if let addr = ifa.pointee.ifa_addr, Int32(addr.pointee.sa_family) == AF_LINK, let data = ifa.pointee.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                linkCounters[String(cString: ifa.pointee.ifa_name)] = (d.ifi_ibytes, d.ifi_obytes)
            }
            cursor = ifa.pointee.ifa_next
        }
        freeifaddrs(head)
    }
    var matched = 0, consistent = 0
    for c in real {
        guard let (i32, o32) = linkCounters[c.name] else { continue }
        matched += 1
        let dIn = UInt32(truncatingIfNeeded: c.bytesIn) &- i32
        let dOut = UInt32(truncatingIfNeeded: c.bytesOut) &- o32
        // Counters may advance between the two calls; allow 64 MB either way (mod 2^32).
        func near(_ d: UInt32) -> Bool { d < 64 << 20 || d > UInt32.max - (64 << 20) }
        if near(dIn) && near(dOut) { consistent += 1 }
    }
    check(matched > 0 && consistent == matched, "IFLIST2 counters agree with getifaddrs (low 32 bits) for \(consistent)/\(matched) interfaces")
}

// MARK: - Formatting and rendering

@MainActor
func checkFormatting() {
    print("Compact formatters")
    let fs = MonitorFormat.figureSpace
    check(MonitorFormat.compactPercent(0.234) == "23%", "23%")
    check(MonitorFormat.compactPercent(0.04) == fs + "4%", "single digit padded with a figure space")
    check(MonitorFormat.compactPercent(1) == "100%" && MonitorFormat.compactPercent(1.7) == "100%", "100% and clamping")
    check(MonitorFormat.compactPercent(nil) == "--" && MonitorFormat.compactPercent(.nan) == "--", "missing → --")
    let rateCases: [(Double, String)] = [(0, "0B"), (999, "999B"), (999.6, "1.0K"), (1023, "1.0K"), (9.94 * 1024, "9.9K"),
                                         (9.96 * 1024, "10K"), (999.4 * 1024, "999K"), (999.6 * 1024, "1.0M"),
                                         (2_500_000, "2.4M"), (1.2 * 1024 * 1024, "1.2M"), (1e20, "999T"), (-5, "0B")]
    for (v, expected) in rateCases {
        check(MonitorFormat.compactRate(v) == expected, "compactRate(\(v)) = \(MonitorFormat.compactRate(v)) (expected \(expected))")
    }
    var longest = 0
    var v = 0.5
    while v < 1e16 {
        longest = max(longest, MonitorFormat.compactRate(v).count)
        v *= 1.037
    }
    check(longest <= 4, "compactRate never exceeds 4 characters (sweep)")
    check(MonitorFormat.compactTemperature(52.4) == "52°" && MonitorFormat.compactTemperature(104.6) == "105°", "temperatures")
    check(MonitorFormat.compactPower(38.2) == "38W" && MonitorFormat.compactPower(4.6) == fs + "5W", "power")
    check(MonitorFormat.rate(1.2 * 1024 * 1024) == "1.2 MB/s" && MonitorFormat.rate(34 * 1024) == "34 KB/s"
          && MonitorFormat.rate(812) == "812 B/s", "full rates (1.2 MB/s, 34 KB/s, 812 B/s)")
    check(MonitorFormat.bytes(128.0 * 1_073_741_824) == "128 GB" && MonitorFormat.bytes(999.7 * 1024) == "1.0 MB", "full sizes")
    check(MonitorFormat.temperature(48.4) == "48°C" && MonitorFormat.power(38.4) == "38 W" && MonitorFormat.power(5.24) == "5.2 W",
          "°C / W")
    check(AlertLevel.forLoad(0.84) == .normal && AlertLevel.forLoad(0.85) == .warning && AlertLevel.forLoad(0.96) == .critical,
          "load thresholds 85 / 95 %")
    check(AlertLevel.forTemperature(89) == .normal && AlertLevel.forTemperature(90) == .warning && AlertLevel.forTemperature(101) == .critical,
          "temperature thresholds 90 / 100 °C")

    print("Menu summary lines")
    var snap = MonitorSnapshot(sampled: Set(MonitorMetric.allCases))
    snap.cpu = CPUReading(total: 0.23, user: 0.15, system: 0.08, performanceCores: nil, efficiencyCores: nil,
                          performanceCoreCount: 0, efficiencyCoreCount: 0, perCore: [])
    snap.gpu = GPUReading(utilization: 0.04, memoryInUse: 1 << 30, name: "g")
    snap.memory = MemoryReading(total: 100, used: 61, app: 40, wired: 20, compressed: 1, cached: 10, free: 29,
                                swapUsed: 0, swapTotal: 0, pressure: .normal)
    snap.network = NetworkReading(up: 1.2 * 1024 * 1024, down: 34 * 1024, bytesIn: 0, bytesOut: 0, interfaces: [],
                                  selection: "", selectionLabel: "全部接口")
    snap.disk = DiskReading(readRate: 12 * 1024 * 1024, writeRate: 3 * 1024 * 1024, bytesRead: 0, bytesWritten: 0,
                            capacityTotal: 1000, capacityAvailable: 850)
    snap.power = PowerReading(systemWatts: 38.2, sourceKey: "PSTR", battery: nil)
    snap.temperature = TemperatureReading(cpuAverage: 48.2, cpuMax: 60, gpuAverage: 41, gpuMax: 44,
                                          cpuSensorCount: 3, gpuSensorCount: 2, source: .smc)
    var settings = MonitorSettings()
    settings.enabledMetrics = Set(MonitorMetric.allCases)
    let lines = MonitorSummary.lines(snapshot: snap, settings: settings)
    check(lines == ["CPU 23% · GPU 4% · 显存 1.0 GB · 内存 61%", "网络 ↑1.2 MB/s ↓34 KB/s", "磁盘 读 12 MB/s · 写 3.0 MB/s · 已用 15%",
                    "功率 38 W", "温度 CPU 48°C · GPU 41°C"], "summary lines: \(lines)")
    settings.enabledMetrics = [.memory]
    check(MonitorSummary.lines(snapshot: MonitorSnapshot(), settings: settings) == ["内存 --"], "missing data → --")
    settings.enabledMetrics = [.gpu, .cpu]
    check(MonitorSummary.lines(snapshot: MonitorSnapshot(), settings: settings) == ["CPU -- · GPU --"], "GPU not sampled yet → -- (never a stale 0)")

    print("Status-item layout (stable width, fits the menu bar)")
    let thickness = NSStatusBar.system.thickness
    check(thickness >= 18 && thickness <= 40, "menu-bar thickness \(thickness)")
    let screen = [CGRect(x: 0, y: 0, width: 1920, height: 1080)]
    check(StatusItemsController.isOnScreen(CGRect(x: 1500, y: 1050, width: 47, height: 30), screens: screen),
          "item in the menu bar is on screen")
    check(!StatusItemsController.isOnScreen(CGRect(x: 0, y: -30, width: 47, height: 30), screens: screen)
          && !StatusItemsController.isOnScreen(CGRect(x: -600, y: 1050, width: 47, height: 30), screens: screen)
          && !StatusItemsController.isOnScreen(CGRect(x: 1500, y: 1050, width: 0, height: 30), screens: screen),
          "items pushed out of the bar (hidden by a menu-bar manager) are not on screen")
    check(StatusRenderer.valueFont.pointSize >= 9 && StatusRenderer.valueFont.pointSize <= 10
          && StatusRenderer.lineFont.pointSize >= 9 && StatusRenderer.lineFont.pointSize <= 10, "value fonts 9–10 pt")

    let fractions: [Double?] = [nil, 0, 0.04, 0.5, 0.999, 1]
    let rates: [Double] = [0, 999, 1000, 9.96 * 1024, 999.4 * 1024, 1.2 * 1024 * 1024, 5e9, 1e15]
    let temps: [Double?] = [nil, 9.5, 52.3, 99.6, 119.9]
    let watts: [Double?] = [nil, 0.4, 8, 38.2, 499]
    func snapshots(for metric: MonitorMetric) -> [MonitorSnapshot] {
        var result: [MonitorSnapshot] = []
        switch metric {
        case .cpu:
            for f in fractions {
                var s = MonitorSnapshot()
                s.cpu = f.map { CPUReading(total: $0, user: $0, system: 0, performanceCores: nil, efficiencyCores: nil,
                                           performanceCoreCount: 0, efficiencyCoreCount: 0, perCore: []) }
                result.append(s)
            }
        case .gpu:
            let memories: [UInt64?] = [nil, 0, 999, 9_500 << 20, 20 << 30, 127 << 30]
            for (f, m) in zip(fractions, memories) {
                var s = MonitorSnapshot()
                s.gpu = f.map { GPUReading(utilization: $0, memoryInUse: m, name: "") }
                result.append(s)
            }
        case .memory:
            for f in fractions {
                var s = MonitorSnapshot()
                s.memory = f.map { MemoryReading(total: 1000, used: UInt64($0 * 1000), app: 0, wired: 0, compressed: 0, cached: 0,
                                                 free: 0, swapUsed: 0, swapTotal: 0, pressure: .normal) }
                result.append(s)
            }
        case .network:
            result.append(MonitorSnapshot())
            for r in rates {
                var s = MonitorSnapshot()
                s.network = NetworkReading(up: r, down: rates.last! - r, bytesIn: 0, bytesOut: 0, interfaces: [], selection: "", selectionLabel: "")
                result.append(s)
            }
        case .disk:
            result.append(MonitorSnapshot())
            for r in rates {
                var s = MonitorSnapshot()
                s.disk = DiskReading(readRate: r, writeRate: r / 3, bytesRead: 0, bytesWritten: 0, capacityTotal: 1000, capacityAvailable: 1)
                result.append(s)
            }
        case .power:
            for w in watts {
                var s = MonitorSnapshot()
                s.power = w.map { PowerReading(systemWatts: $0, sourceKey: "PSTR", battery: nil) }
                result.append(s)
            }
        case .temperature:
            for t in temps {
                var s = MonitorSnapshot()
                s.temperature = t.map { TemperatureReading(cpuAverage: $0, cpuMax: $0, gpuAverage: nil, gpuMax: nil,
                                                          cpuSensorCount: 1, gpuSensorCount: 0, source: .smc) }
                result.append(s)
            }
        }
        return result
    }

    var history = SampleHistory(capacity: 60)
    for i in 0..<60 { history.append(Double(i % 17) / 17) }
    let histories: [HistorySeries: SampleHistory] = Dictionary(uniqueKeysWithValues: HistorySeries.all.map { ($0, history) })
    let renderDir = ProcessInfo.processInfo.environment["SM_RENDER_DIR"].map { URL(fileURLWithPath: $0) }

    var allStable = true, allFit = true, allInside = true
    // Display variants: default, 磁盘 已用空间, GPU 利用率和显存 (each only affects its own metric).
    let variants: [(DiskDisplay, GPUDisplay)] = [(.throughput, .utilization), (.capacity, .utilization),
                                                 (.throughput, .utilizationAndMemory)]
    for style in DisplayStyle.allCases {
        for (diskDisplay, gpuDisplay) in variants {
            var s = MonitorSettings()
            s.style = style
            s.diskDisplay = diskDisplay
            s.gpuDisplay = gpuDisplay
            for metric in MonitorMetric.allCases {
                if diskDisplay == .capacity && metric != .disk { continue }
                if gpuDisplay == .utilizationAndMemory && metric != .gpu { continue }
                var widths = Set<CGFloat>()
                for snapshot in snapshots(for: metric) {
                    let seg = StatusContent.segment(for: metric, snapshot: snapshot, histories: histories, settings: s)
                    let layout = StatusRenderer.layout([seg], style: style, height: thickness)
                    widths.insert(layout.size.width)
                    for run in layout.texts {
                        let w = StatusRenderer.width(run.text, font: run.font)
                        if w > run.boxWidth + 0.01 {
                            allFit = false
                            print("    overflow: \(metric) \(style) '\(run.text)' \(w) > \(run.boxWidth)")
                        }
                        let top = run.origin.y + run.font.ascender, bottom = run.origin.y + run.font.descender
                        if top > thickness + 0.5 || bottom < -0.5 || run.origin.x < 0 || run.origin.x + run.boxWidth > layout.size.width {
                            allInside = false
                            print("    outside: \(metric) \(style) '\(run.text)' y \(bottom)…\(top) of \(thickness)")
                        }
                    }
                    for icon in layout.icons where icon.rect.maxY > thickness || icon.rect.minY < 0 { allInside = false }
                    for spark in layout.sparks where spark.rect.maxY > thickness || spark.rect.minY < 0 { allInside = false }
                }
                if widths.count != 1 {
                    allStable = false
                    print("    unstable width: \(metric) \(style) \(widths.sorted())")
                }
                if let w = widths.first {
                    let variant = metric == .disk ? "（\(diskDisplay.title)）" : metric == .gpu ? "（\(gpuDisplay.title)）" : ""
                    print("    \(style.title) \(metric.title)\(variant): \(Int(w)) pt")
                }
            }
        }
    }
    check(allStable, "every metric × style has one fixed width for all values")
    check(allFit, "no value text is wider than its column")
    check(allInside, "all text / icons / sparklines inside the \(thickness) pt bar height")

    // Render real images (forces the drawing code to run) and time it.
    var real = snapshots(for: .cpu)[3]
    real.cpu = CPUReading(total: 0.91, user: 0.5, system: 0.41, performanceCores: nil, efficiencyCores: nil,
                          performanceCoreCount: 0, efficiencyCoreCount: 0, perCore: [])
    real.gpu = GPUReading(utilization: 0.04, memoryInUse: 20 << 30, name: "")
    real.memory = snap.memory
    real.network = snap.network
    real.disk = snap.disk
    real.power = snap.power
    real.temperature = snap.temperature
    var combinedSettings = MonitorSettings()
    combinedSettings.enabledMetrics = Set(MonitorMetric.allCases)
    combinedSettings.gpuDisplay = .utilizationAndMemory
    let t0 = Date()
    var rendered = 0, nonEmpty = 0
    for style in DisplayStyle.allCases {
        combinedSettings.style = style
        let segments = combinedSettings.orderedEnabledMetrics.map {
            StatusContent.segment(for: $0, snapshot: real, histories: histories, settings: combinedSettings)
        }
        for tint in [StatusRenderer.Tint.template, .colored(dark: true), .colored(dark: false)] {
            let image = StatusRenderer.image(for: segments, style: style, height: thickness, tint: tint)
            check(image.size.height == thickness, "image height == bar thickness (\(style.title), \(tint))")
            guard let rep = bitmap(image) else { continue }
            rendered += 1
            if hasInk(rep) { nonEmpty += 1 }
            if let renderDir, let png = rep.representation(using: .png, properties: [:]) {
                let name: String
                switch tint {
                case .template: name = "template"
                case .colored(let dark): name = dark ? "dark" : "light"
                }
                try? png.write(to: renderDir.appendingPathComponent("combined-\(style.rawValue)-\(name).png"))
            }
        }
    }
    let ms = Date().timeIntervalSince(t0) * 1000 / Double(max(1, rendered))
    check(rendered == 9 && nonEmpty == 9, "combined images render with visible content (\(nonEmpty)/\(rendered))")
    check(ms < 30, String(format: "rendering is cheap on the main thread (%.1f ms per combined image)", ms))
    let cpuSegment = StatusContent.segment(for: .cpu, snapshot: real, histories: histories, settings: combinedSettings)
    check(cpuSegment.level == .warning, "91% CPU → warning level (orange)")
    let gpuSegment = StatusContent.segment(for: .gpu, snapshot: real, histories: histories, settings: combinedSettings)
    if case let .stacked(top, bottom) = gpuSegment.body {
        check(top.prefix == "GPU" && top.value == fs + "4%" && bottom.prefix == "显存" && bottom.value == "20G",
              "GPU 利用率和显存: two lines GPU / 显存")
    } else {
        check(false, "GPU 利用率和显存 renders two lines")
    }
    check(gpuSegment.accessibilityText == "GPU 4% · 显存 20.0 GB", "GPU accessibility text includes 显存")
    var plain = combinedSettings
    plain.gpuDisplay = .utilization
    if case let .captioned(caption, value, _) = StatusContent.segment(for: .gpu, snapshot: real, histories: histories, settings: plain).body {
        check(caption == "GPU" && value == fs + "4%", "GPU 利用率: caption + value")
    } else {
        check(false, "GPU 利用率 renders caption + value")
    }
    check(StatusContent.segment(for: .gpu, snapshot: MonitorSnapshot(), histories: [:], settings: combinedSettings).accessibilityText == "GPU --",
          "GPU not sampled → -- in the menu bar")
}

func bitmap(_ image: NSImage) -> NSBitmapImageRep? {
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
                                     pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func hasInk(_ rep: NSBitmapImageRep) -> Bool {
    for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
            return true
        }
    }
    return false
}

// MARK: - Sparkline buffer

@MainActor
func checkSparklines() {
    print("Sample history ring buffer")
    var h = SampleHistory(capacity: 5)
    check(h.isEmpty && h.last == nil && h.values.isEmpty, "empty")
    for i in 1...3 { h.append(Double(i)) }
    check(h.values == [1, 2, 3] && h.last == 3 && h.count == 3, "partial fill keeps order")
    for i in 4...7 { h.append(Double(i)) }
    check(h.values == [3, 4, 5, 6, 7] && h.count == 5, "overflow drops the oldest")
    check(h.last == 7 && h.suffix(2) == [6, 7] && h.suffix(10) == [3, 4, 5, 6, 7], "last / suffix")
    check(h.maxValue == 7 && h.minValue == 3, "min / max")
    h.append(.nan)
    check(h.last == 0, "non-finite values stored as 0")
    for i in 0..<12 { h.append(Double(i)) }
    check(h.values == [7, 8, 9, 10, 11], "wraps around many times")
    h.removeAll()
    check(h.isEmpty && h.values.isEmpty, "removeAll")

    print("Sparkline geometry")
    let pts = Sparkline.points(normalized: [0, 0.5, 1], capacity: 5, width: 40, height: 10)
    check(pts.count == 3 && pts.last == CGPoint(x: 40, y: 10), "newest sample on the right edge at full height")
    check(pts.first == CGPoint(x: 20, y: 0) && pts[1] == CGPoint(x: 30, y: 5), "partial history grows in from the right")
    let full = Sparkline.points(normalized: Array(repeating: 0.5, count: 8), capacity: 5, width: 40, height: 10)
    check(full.count == 5 && full.first?.x == 0, "only the last `capacity` samples, spanning the full width")
    check(Sparkline.normalize([-1, 0.5, 2], range: 0...1) == [0, 0.5, 1], "normalize clamps")
    check(Sparkline.range(for: [0.2], scale: .unit) == 0...1, "unit scale")
    let r = Sparkline.range(for: [100, 2000], scale: .zeroBased(floor: 10_240))
    check(r.lowerBound == 0 && abs(r.upperBound - 11_264) < 0.001, "rate scale floor avoids amplifying noise")
    let w = Sparkline.range(for: [50, 51], scale: .window(minSpan: 10))
    check(w.upperBound - w.lowerBound >= 10 && w.contains(50) && w.contains(51), "temperature window has a minimum span")

    print("Model histories")
    let model = MonitorModel()
    var s = MonitorSnapshot(sampled: [.cpu, .memory])
    s.memory = MemoryReading(total: 10, used: 5, app: 5, wired: 0, compressed: 0, cached: 0, free: 5, swapUsed: 0, swapTotal: 0, pressure: .normal)
    model.ingest(s) // CPU baseline pass: no CPU value yet
    s.cpu = CPUReading(total: 0.3, user: 0.2, system: 0.1, performanceCores: nil, efficiencyCores: nil,
                       performanceCoreCount: 0, efficiencyCoreCount: 0, perCore: [])
    model.ingest(s)
    check(model.history(.cpu) == [0.3] && model.history(.memory) == [0.5, 0.5], "values appended per sampled metric")
    check(model.histories[.gpu] == nil, "unsampled metric has no history")
    check(!model.isUnavailable(.cpu) && !model.isUnavailable(.gpu), "availability bookkeeping")
    model.ingest(MonitorSnapshot(sampled: [.cpu, .gpu, .power]))
    model.ingest(MonitorSnapshot(sampled: [.cpu, .gpu, .power]))
    check(model.histories[.memory] == nil, "history dropped when the metric stops being sampled")
    check(model.isUnavailable(.power), "metric sampled twice without data → unavailable")
    check(!model.isUnavailable(.gpu), "GPU (averaged, first pass = baseline) still collecting after two passes")
    model.ingest(MonitorSnapshot(sampled: [.cpu, .gpu, .power]))
    check(model.isUnavailable(.gpu), "GPU sampled three times without data → unavailable")
    var withGPU = MonitorSnapshot(sampled: [.gpu])
    withGPU.gpu = GPUReading(utilization: 0.8, memoryInUse: 1 << 30, name: "g")
    withGPU.gpuProcesses = [GPUProcessUsage(pid: 1, name: "LM Studio", processName: "node", fraction: 0.75)]
    model.ingest(withGPU)
    check(!model.isUnavailable(.gpu) && model.gpuProcesses.count == 1 && model.history(.gpu).last == 0.8, "GPU reading, history and processes ingested")
    model.ingest(MonitorSnapshot(sampled: [.gpu]))
    check(model.gpuProcesses.count == 1, "GPU process list kept while a pass does not carry one")
    model.clearProcesses()
    check(model.gpuProcesses.isEmpty && model.processes.isEmpty, "clearProcesses() clears the GPU list too")
    for _ in 0..<70 { model.ingest(s) }
    check(model.history(.cpu).count == MonitorModel.historyCapacity, "history capped at \(MonitorModel.historyCapacity) samples")

    print("Readings of metrics that stop being sampled are dropped (no stale value when shown again)")
    var sampledAll = MonitorSnapshot(sampled: [.cpu, .gpu, .memory])
    sampledAll.cpu = s.cpu
    sampledAll.memory = s.memory
    sampledAll.gpu = GPUReading(utilization: 0, memoryInUse: 1 << 30, name: "g")
    sampledAll.gpuProcesses = [GPUProcessUsage(pid: 1, name: "LM Studio", processName: nil, fraction: 0.5)]
    let restricted = sampledAll.restricted(to: [.cpu, .memory])
    check(restricted.gpu == nil && restricted.gpuProcesses == nil && restricted.cpu != nil && restricted.memory != nil
          && restricted.sampled == [.cpu, .memory] && restricted.timestamp == sampledAll.timestamp, "MonitorSnapshot.restricted(to:)")
    check(sampledAll.restricted(to: []).sampled.isEmpty && sampledAll.restricted(to: []).cpu == nil, "restricted to nothing")
    let stale = MonitorModel()
    stale.ingest(sampledAll)
    stale.ingest(sampledAll)
    check(stale.snapshot.gpu?.utilization == 0 && !stale.history(.gpu).isEmpty && !stale.gpuProcesses.isEmpty, "GPU reading present while sampled")
    stale.discardReadings(except: [.cpu, .memory])
    check(stale.snapshot.gpu == nil && stale.history(.gpu).isEmpty && stale.gpuProcesses.isEmpty
          && stale.snapshot.cpu != nil && !stale.history(.cpu).isEmpty,
          "GPU no longer sampled → its reading, history and processes are dropped at once (others kept)")
    check(!stale.isUnavailable(.gpu) && GPUDetail.value(stale.snapshot.gpu) == "--", "…so it shows -- (not an old 0%) until the next sample")
    stale.discardReadings(except: [])
    check(stale.snapshot.cpu == nil && stale.snapshot.memory == nil && stale.histories.isEmpty, "nothing sampled (idle / paused) → nothing kept")
}

// MARK: - Settings

@MainActor
func checkSettings() {
    print("Settings")
    let d = MonitorSettings()
    check(d.enabledMetrics == [.cpu, .memory, .network] && d.combined == AppEnvironment.isLaptop && d.interval == 2
          && d.style == .text && d.networkInterface.isEmpty && d.temperatureSource == .cpu,
          "defaults: CPU + 内存 + 网络, 2 s, 文字, 全部接口; combined only on laptops")
    check(d.orderedEnabledMetrics == [.cpu, .memory, .network], "menu-bar order")
    var odd = d
    odd.interval = 7
    check(odd.effectiveInterval == 2, "unsupported interval falls back to 2 s")

    let (suite, suitePath) = tempDefaults("settings")
    suite.set(Data(#"{"enabledMetrics":["gpu","temperature"],"interval":5,"combined":true}"#.utf8), forKey: "monitor.settings")
    let store = SettingsStore(key: "monitor.settings", defaultValue: MonitorSettings(), defaults: suite)
    check(store.value.enabledMetrics == [.gpu, .temperature] && store.value.interval == 5 && store.value.combined
          && store.value.colorWarning && store.value.style == .text && store.value.gpuDisplay == .utilization,
          "old / partial JSON migrates, new fields get defaults (GPU 显示 = 利用率)")
    store.update { $0.gpuDisplay = .utilizationAndMemory }
    let reloaded = SettingsStore(key: "monitor.settings", defaultValue: MonitorSettings(), defaults: suite)
    check(reloaded.value.gpuDisplay == .utilizationAndMemory, "GPU 显示 persisted")
    removeTempDefaults(suite, suitePath)
}

// MARK: - Engine timer

@MainActor
func checkEngine() {
    print("Engine scheduling")
    let received = Box<[MonitorSnapshot]>([])
    let offMain = Box(true)
    let engine = MonitorEngine { snap in
        if Thread.isMainThread { offMain.value = false }
        received.mutate { $0.append(snap) }
    }
    engine.update(.init(metrics: [.cpu, .memory], interval: 1, networkInterface: "", includeProcesses: false))
    let delivered = waitUntil(4) { received.value.count >= 3 }
    check(delivered, "timer delivers snapshots (\(received.value.count))")
    check(offMain.value, "sampling runs off the main thread")
    check(received.value.first?.memory != nil, "immediate first pass with instantaneous values")
    check(received.value.dropFirst().allSatisfy { $0.cpu != nil }, "CPU available from the second pass")
    check(received.value.allSatisfy { $0.network == nil && $0.temperature == nil }, "only requested metrics sampled")
    if received.value.count >= 3 {
        let gaps = zip(received.value.dropFirst(), received.value.dropFirst(2)).map { $1.timestamp.timeIntervalSince($0.timestamp) }
        check(gaps.allSatisfy { $0 > 0.7 && $0 < 1.6 }, "interval ≈ 1 s (\(gaps.map { String(format: "%.2f", $0) }))")
    }
    engine.update(.init(metrics: [], interval: 1))
    spin(0.3)
    let count = received.value.count
    spin(1.5)
    check(received.value.count == count, "nothing sampled when nothing is displayed")
    engine.update(.init(metrics: [.temperature, .power], interval: 2))
    check(waitUntil(2) { received.value.count > count }, "restart delivers immediately")
    engine.stop()
    let afterStop = received.value.count
    spin(1.2)
    check(received.value.count == afterStop, "no deliveries after stop()")
}

// MARK: - Module lifecycle (brief, cleaned-up status items)

@MainActor
func checkModuleLifecycle() {
    print("Module lifecycle")
    guard NSStatusBar.system.thickness > 0 else {
        print("    no window server — skipped")
        return
    }
    let (suite, suitePath) = tempDefaults("module")
    let module = SystemMonitorModule(defaults: suite)
    check(module.id == "monitor" && module.displayName == "系统监控" && module.symbolName == "gauge.with.dots.needle.33percent",
          "identity")
    module.start()
    let items = module.statusItems.items
    check(items.count == 7 && module.statusItems.combinedItem != nil, "all 7 metric items + combined item created in start()")
    if AppEnvironment.isLaptop {
        check(module.statusItems.combinedItem?.isVisible == true && items.values.allSatisfy { !$0.isVisible },
              "default visibility (laptop): one combined item")
    } else {
        check(items[.cpu]?.isVisible == true && items[.memory]?.isVisible == true && items[.network]?.isVisible == true
              && items[.gpu]?.isVisible == false && items[.temperature]?.isVisible == false
              && module.statusItems.combinedItem?.isVisible == false, "default visibility: CPU + 内存 + 网络")
    }
    check(items[.cpu]?.autosaveName == "OneSwitchMonitor.cpu" + AppEnvironment.profileSuffix, "autosave name with profile suffix")
    let config = module.configuration(for: module.store.value)
    check(config.metrics == [.cpu, .memory, .network] && !config.includeProcesses, "samples only the displayed metrics")
    check(waitUntil(4) { module.model.snapshot.cpu != nil }, "live CPU value arrives")
    let thickness = NSStatusBar.system.thickness
    check(items[.cpu]?.button?.image?.size.height == thickness, "CPU item image rendered at bar height")
    checkOrder(module, [.cpu, .memory, .network], "left→right order CPU, 内存, 网络")
    // Detail popover: opening it samples everything plus the top processes; closing reverts.
    // A popover can only open from an item that is actually on screen. While a running OneSwitch hides
    // menu-bar items natively (macOS 27 allow-list), this check process's items are hidden too — skip then.
    let onScreen = module.statusItems.onScreenButtons.first.map { $0.window?.occlusionState.contains(.visible) ?? false } ?? false
    if !onScreen {
        print("  – popover checks skipped: the status item is not on screen (hidden by a running menu-bar hider?)")
    }
    if onScreen, let button = module.statusItems.onScreenButtons.first {
        module.togglePopover(from: button)
        check(module.popover.isShown, "clicking an item opens the detail popover")
        let open = module.configuration(for: module.store.value)
        check(open.metrics == Set(MonitorMetric.allCases) && open.includeProcesses, "popover open → all metrics + top processes")
        check(waitUntil(5) { !module.model.processes.isEmpty && module.model.snapshot.disk != nil }, "popover receives processes and all metrics")
        module.togglePopover(from: button)
        check(waitUntil(2) { !module.popover.isShown }, "second click closes the popover")
        let closed = module.configuration(for: module.store.value)
        check(closed.metrics == [.cpu, .memory, .network] && !closed.includeProcesses, "popover closed → back to displayed metrics only")
        check(module.model.processes.isEmpty, "process list cleared on close")
    }
    // Pin: a pinned popover stays open while other apps are used; the pin resets when it closes.
    check(DetailPopoverController.behavior(pinned: false) == .transient
          && DetailPopoverController.behavior(pinned: true) == .applicationDefined, "pin → popover behaviour")
    if onScreen, let button = module.statusItems.onScreenButtons.first {
        module.togglePopover(from: button)
        module.popover.pin.isPinned = true
        check(module.popover.currentBehavior == .applicationDefined, "pinning an open popover keeps it open on outside clicks")
        module.togglePopover(from: button)
        check(waitUntil(2) { !module.popover.isShown } && !module.popover.pin.isPinned, "closing from the item unpins")
    }
    let fakeSettingsView = ObjectIdentifier(NSObject.self)
    module.settingsVisibilityChanged(fakeSettingsView, true)
    check(module.configuration(for: module.store.value).metrics == Set(MonitorMetric.allCases), "settings page visible → all metrics")
    module.settingsVisibilityChanged(fakeSettingsView, false)
    check(module.configuration(for: module.store.value).metrics == [.cpu, .memory, .network], "settings page hidden → displayed metrics only")

    let menu = module.menuItems()
    check(menu.first?.title.hasPrefix("CPU ") == true && menu.contains { $0.title == "在菜单栏显示" }, "menu: summary + 在菜单栏显示")
    check(menu.first { $0.title == "在菜单栏显示" }?.submenu?.items.count == 9, "submenu: 7 metrics + separator + 合并显示")

    module.store.update { $0.combined = true; $0.enabledMetrics = [.cpu, .temperature, .power] }
    check(items.values.allSatisfy { !$0.isVisible } && module.statusItems.combinedItem?.isVisible == true, "合并显示 → only the combined item")
    check(waitUntil(4) { module.model.snapshot.temperature != nil || module.model.isUnavailable(.temperature) }, "newly shown metric starts sampling")
    check(waitUntil(3) { (module.statusItems.combinedItem?.button?.image?.size.width ?? 0) > 60 }, "combined image rendered")
    // Back to individual items at runtime: shown together, they must keep their relative order.
    module.store.update { $0.combined = false; $0.enabledMetrics = [.cpu, .gpu, .network] }
    spin(0.5)
    checkOrder(module, [.cpu, .gpu, .network], "items re-shown together keep the order CPU, GPU, 网络")
    check(module.statusItems.combinedItem?.isVisible == false && items[.gpu]?.isVisible == true, "individual items back")
    checkGPUOnlyWhenShown(module)
    checkPause(module)

    module.store.update { $0.enabledMetrics = [] }
    check(module.statusItems.combinedItem?.isVisible == false && items.values.allSatisfy { !$0.isVisible },
          "nothing selected → nothing shown")
    check(module.configuration(for: module.store.value).metrics.isEmpty, "…and nothing sampled")
    check(waitUntil(2) { module.engine?.isTimerActive == false }, "…and the sampling timer is cancelled")

    let engine = module.engine
    module.stop()
    check(module.statusItems.items.isEmpty && module.statusItems.combinedItem == nil, "stop() removes every status item")
    check(module.engine == nil && engine?.isTimerActive == false, "stop() cancels the sampling timer")
    // Workspace observers are gone: a late wake note must neither crash nor restart sampling.
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
    spin(0.1)
    check(module.pauseReasons.isEmpty && module.engine == nil, "no sampling after stop() on a wake notification")
    module.stop() // idempotent

    removeTempDefaults(suite, suitePath)
    removeStatusItemDefaults()
}

/// GPU sampled exactly while something shows it, and never a stale value once it is shown again.
@MainActor
func checkGPUOnlyWhenShown(_ module: SystemMonitorModule) {
    print("GPU sampled only while shown, never stale")
    let gpuItem = module.statusItems.items[.gpu]
    check(module.configuration(for: module.store.value).metrics.contains(.gpu), "GPU item shown → GPU sampled")
    check(waitUntil(3) { module.model.snapshot.gpu != nil }, "GPU value arrives (first pass is the baseline)")
    let live = module.model.snapshot.gpu
    check(gpuItem?.button?.image?.accessibilityDescription == MonitorSummary.gpu(module.model.snapshot.gpu),
          "GPU item shows the live snapshot (\(MonitorSummary.gpu(live)))")

    // Hide the GPU item: its reading is dropped at once, not at the next tick.
    module.store.update { $0.enabledMetrics = [.cpu, .network] }
    check(!module.configuration(for: module.store.value).metrics.contains(.gpu), "GPU hidden → not sampled")
    check(module.model.snapshot.gpu == nil && module.model.history(.gpu).isEmpty, "GPU hidden → last reading dropped immediately")
    // A pass that was already running with the old configuration must not bring it back.
    var inFlight = MonitorSnapshot(sampled: [.cpu, .gpu, .network])
    inFlight.gpu = GPUReading(utilization: 0, memoryInUse: 1 << 30, name: "stale")
    module.receive(inFlight)
    check(module.model.snapshot.gpu == nil && !module.model.snapshot.sampled.contains(.gpu),
          "an in-flight pass sampled before the change does not restore the GPU reading")
    check(MonitorSummary.lines(snapshot: module.model.snapshot, settings: module.store.value).allSatisfy { !$0.contains("GPU") },
          "menu summary without GPU")

    // Show it again: "--" until a fresh sample, never the old value.
    module.store.update { $0.enabledMetrics = [.cpu, .gpu, .network] }
    check(module.model.snapshot.gpu == nil && gpuItem?.button?.image?.accessibilityDescription == "GPU --",
          "GPU shown again → -- right away (no stale value)")
    check(waitUntil(3) { module.model.snapshot.gpu != nil }
          && gpuItem?.button?.image?.accessibilityDescription == MonitorSummary.gpu(module.model.snapshot.gpu),
          "…then a fresh GPU value within about one interval")

    // Only GPU shown, then nothing: the timer goes idle and nothing old stays behind.
    module.store.update { $0.enabledMetrics = [.gpu] }
    check(waitUntil(3) { module.model.snapshot.gpu != nil }, "GPU alone shown → sampled")
    module.store.update { $0.enabledMetrics = [] }
    check(waitUntil(2) { module.engine?.isTimerActive == false } && module.model.snapshot.gpu == nil,
          "nothing shown → timer idle, no frozen GPU reading")
    // The settings page shows every metric: GPU is sampled again from a fresh baseline.
    let settingsPage = ObjectIdentifier(NSNumber.self)
    module.settingsVisibilityChanged(settingsPage, true)
    check(module.configuration(for: module.store.value).metrics.contains(.gpu) && module.model.snapshot.gpu == nil,
          "settings page visible → GPU sampled, -- until the first average")
    check(waitUntil(3) { module.model.snapshot.gpu != nil }, "settings page: GPU value arrives")
    module.settingsVisibilityChanged(settingsPage, false)
    check(module.model.snapshot.gpu == nil && waitUntil(2) { module.engine?.isTimerActive == false },
          "settings page hidden → GPU dropped, timer idle again")
    module.store.update { $0.enabledMetrics = [.cpu, .gpu, .network] }
}

/// A popover must not stay open on an item that left the screen (pinned, it would sample for good).
@MainActor
func checkAnchorWatcher() {
    print("Popover anchor watcher")
    guard let screen = NSScreen.screens.first?.frame else {
        print("    no screen — skipped")
        return
    }
    // A window that is never ordered front: no visible side effect, but moves post the notifications.
    let onScreen = CGRect(x: screen.midX, y: screen.maxY - 40, width: 40, height: 24)
    let window = NSWindow(contentRect: onScreen, styleMask: [.borderless], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let left = Box(0)
    let watcher = AnchorWatcher(window: window, grace: 0.2) { left.mutate { $0 += 1 } }
    check(AnchorWatcher.isOnScreen(window, screens: NSScreen.screens.map(\.frame)) && !AnchorWatcher.isOnScreen(nil, screens: [screen]),
          "on-screen predicate")
    window.setFrameOrigin(CGPoint(x: screen.minX + 100, y: screen.maxY - 40))
    spin(0.4)
    check(left.value == 0, "moving within the menu bar keeps the popover")
    window.setFrameOrigin(CGPoint(x: -5_000, y: -30))
    spin(0.05)
    window.setFrameOrigin(onScreen.origin)
    spin(0.4)
    check(left.value == 0, "a transient off-screen frame (e.g. moving to another display's menu bar) is ignored")
    window.setFrameOrigin(CGPoint(x: 0, y: -30)) // where a collapsed menu-bar hider parks items
    check(waitUntil(1) { left.value == 1 }, "item pushed out of the bar → the popover closes after the grace period")
    window.setFrameOrigin(onScreen.origin)
    window.setFrameOrigin(CGPoint(x: -5_000, y: -30))
    spin(0.4)
    check(left.value == 1, "…exactly once")
    let other = Box(0)
    let cancelled = AnchorWatcher(window: window, grace: 0.1) { other.mutate { $0 += 1 } }
    cancelled.invalidate()
    window.setFrameOrigin(CGPoint(x: -6_000, y: -30))
    spin(0.3)
    check(other.value == 0, "invalidated watcher (popover closed) never fires")
    withExtendedLifetime(watcher) {}
    window.close()
}

/// Removes the status-item keys AppKit stored in this executable's defaults domain.
func removeStatusItemDefaults() {
    let standard = UserDefaults.standard
    for key in standard.dictionaryRepresentation().keys where key.contains("OneSwitchMonitor.") {
        standard.removeObject(forKey: key)
    }
    // Note: cfprefsd re-creates an empty ~/Library/Preferences/SystemMonitorCheck.plist after exit
    // (status-item visibility is persisted per executable); the keys themselves are removed here.
    standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
}

/// Checks the on-screen left→right order of `metrics`' items. The order can only be measured when the
/// system lays the items out in the menu bar: a menu-bar manager (e.g. a running OneSwitch.app with its
/// hider collapsed) pushes newly created items out of the bar, where every window sits at x = 0.
@MainActor
func checkOrder(_ module: SystemMonitorModule, _ metrics: [MonitorMetric], _ message: String) {
    let windows = metrics.compactMap { module.statusItems.items[$0]?.button?.window }
    let screens = NSScreen.screens.map(\.frame)
    guard windows.count == metrics.count,
          windows.allSatisfy({ $0.isVisible && StatusItemsController.isOnScreen($0.frame, screens: screens) }) else {
        print("    (skipped: \(message) — items are not laid out on screen, e.g. hidden by a menu-bar manager)")
        return
    }
    let xs = windows.map(\.frame.minX)
    check(zip(xs, xs.dropFirst()).allSatisfy { $0 < $1 }, "\(message) (\(xs.map { Int($0) }))")
}

/// Display sleep / system sleep / inactive session suspend sampling (nobody sees the menu bar) and
/// resume it afterwards. Posts the workspace notifications in-process only.
@MainActor
func checkPause(_ module: SystemMonitorModule) {
    let center = NSWorkspace.shared.notificationCenter
    let displayed = module.configuration(for: module.store.value)
    check(!displayed.metrics.isEmpty && module.engine?.isTimerActive == true, "sampling before display sleep")

    center.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
    check(waitUntil(1) { module.pauseReasons == [.screensAsleep] }, "screensDidSleep → paused")
    check(module.configuration(for: module.store.value).metrics.isEmpty, "paused → nothing sampled")
    check(waitUntil(2) { module.engine?.isTimerActive == false && module.engine?.currentConfiguration.isIdle == true },
          "paused → timer cancelled (no wake-ups while the displays sleep)")
    // Opening the settings page while paused must not restart sampling either.
    let fakeSettingsView = ObjectIdentifier(NSString.self)
    module.settingsVisibilityChanged(fakeSettingsView, true)
    check(module.configuration(for: module.store.value).metrics.isEmpty, "still paused with the settings page visible")
    module.settingsVisibilityChanged(fakeSettingsView, false)

    let before = module.model.snapshot.timestamp
    center.post(name: NSWorkspace.screensDidWakeNotification, object: NSWorkspace.shared)
    check(waitUntil(1) { module.pauseReasons.isEmpty }, "screensDidWake → resumed")
    check(module.configuration(for: module.store.value) == displayed, "resumed → displayed metrics again")
    check(waitUntil(3) { module.model.snapshot.timestamp > before && module.engine?.isTimerActive == true },
          "resumed → fresh snapshot right away and the timer runs again")

    center.post(name: NSWorkspace.willSleepNotification, object: NSWorkspace.shared)
    center.post(name: NSWorkspace.screensDidSleepNotification, object: NSWorkspace.shared)
    check(waitUntil(1) { module.pauseReasons == [.systemAsleep, .screensAsleep] }, "willSleep + screensDidSleep → paused")
    center.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
    check(waitUntil(1) { module.pauseReasons.isEmpty }, "didWake alone resumes (a missed screensDidWake never freezes the items)")

    center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: NSWorkspace.shared)
    check(waitUntil(1) { module.pauseReasons == [.sessionInactive] }, "fast user switch away → paused")
    center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: NSWorkspace.shared)
    check(waitUntil(1) { module.pauseReasons.isEmpty && module.configuration(for: module.store.value) == displayed },
          "session active again → resumed")
}

// MARK: - GPU under a real Metal load

/// A real GPU load: a compute kernel compiled at runtime (MTLDevice.makeLibrary(source:)) and dispatched
/// back to back on a background thread. Each dispatch takes a few ms, so the window server keeps getting
/// GPU time; the load stops by itself after `seconds` at the latest.
final class GPULoad: @unchecked Sendable {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void spin(device float *out [[buffer(0)]], constant uint &iterations [[buffer(1)]],
                     uint id [[thread_position_in_grid]]) {
        float x = float(id) * 0.0001f;
        for (uint i = 0; i < iterations; i++) { x = sin(fma(x, 1.000001f, 0.000001f)); }
        out[id] = x;
    }
    """
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer
    private let width = 1 << 20
    private let stopRequested = Box(false)
    private let finished = DispatchSemaphore(value: 0)
    private var thread: Thread?
    let dispatches = Box(0)
    let gpuSeconds = Box(0.0)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let function = library.makeFunction(name: "spin"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let buffer = device.makeBuffer(length: (1 << 20) * 4, options: .storageModeShared) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.buffer = buffer
    }

    func start(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(min(seconds, 5))
        let t = Thread { [self] in
            while !stopRequested.value && Date() < deadline {
                guard dispatchOnce(on: queue) else { break }
            }
            finished.signal()
        }
        t.name = "SystemMonitorCheck.GPULoad"
        thread = t
        t.start()
    }

    /// One dispatch of the kernel on `queue` (a few ms), waiting for it to complete.
    @discardableResult
    func dispatchOnce(on queue: MTLCommandQueue) -> Bool {
        var iterations: UInt32 = 1000
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return false }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(buffer, offset: 0, index: 0)
        enc.setBytes(&iterations, length: 4, index: 1)
        enc.dispatchThreads(MTLSize(width: width, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        dispatches.mutate { $0 += 1 }
        gpuSeconds.mutate { $0 += max(0, cb.gpuEndTime - cb.gpuStartTime) }
        return true
    }

    /// Runs the kernel on `queue` on the calling thread for `seconds` (at most 1 s).
    func run(on queue: MTLCommandQueue, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(min(seconds, 1))
        while Date() < deadline && dispatchOnce(on: queue) {}
    }

    /// Waits until the load has run for its full duration.
    func join() {
        guard thread != nil else { return }
        finished.wait()
        thread = nil
    }

    /// Stops the load and waits until the last command buffer has completed.
    func stop() {
        guard thread != nil else { return }
        stopRequested.value = true
        finished.wait()
        thread = nil
    }
}

/// Reproduces "GPU 一直都是 0": with a real Metal load running, the engine, the module's published
/// snapshot, the GPU status item, the menu summary and the popover texts must all report it.
@MainActor
func checkGPULoad() {
    print("GPU under a real Metal load (≤ 5 s)")
    guard let load = GPULoad() else {
        print("    no Metal device — skipped")
        return
    }
    let sampleScan = GPUSampler.scan(cached: [:])
    guard !sampleScan.accelerators.isEmpty else {
        print("    no IOAccelerator statistics — skipped")
        return
    }
    print("    device: \(load.device.name)")
    let started = Date()
    load.start(seconds: 4.5)
    defer { load.stop() } // early returns

    // Engine: two passes one second apart while the kernel runs. Meanwhile a second reader polls
    // "PerformanceStatistics" like another monitoring app would; that makes the driver's instantaneous
    // "Device Utilization %" read 0 at random, which must not matter any more.
    let pollerStop = Box(false)
    let pollerReads = Box<[Double]>([])
    let poller = Thread {
        while !pollerStop.value {
            if let u = GPUSampler.scan(cached: [:]).accelerators.first?.deviceUtilization { pollerReads.mutate { $0.append(u) } }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
    poller.start()
    let engine = MonitorEngine { _ in }
    _ = engine.sampleNow([.gpu], includeProcesses: true)
    spin(1.1)
    _ = GPUSampler.scan(cached: [:]) // another reader right before ours: the driver's utilisation now reads ~0
    let busy = engine.sampleNow([.gpu], includeProcesses: true)
    let loadDiag = engine.diagnostics()
    pollerStop.value = true
    let reads = pollerReads.value
    print(String(format: "    concurrent reader: %d reads, %d of them 0 %%; engine inputs: busy time %@, device utilisation %@",
                 reads.count, reads.filter { $0 == 0 }.count, pct(loadDiag.gpuClientTime), pct(loadDiag.gpuDeviceUtilization)))
    let g = busy.gpu
    print("    engine: \(pct(g?.utilization)) (\(g?.source.rawValue ?? "nil")), 显存 \(g?.memoryInUse.map { MonitorFormat.bytes($0) } ?? "n/a") / " +
          "\(g?.memoryAllocated.map { MonitorFormat.bytes($0) } ?? "n/a"); top: " +
          (busy.gpuProcesses ?? []).map { "\($0.name) \(pct($0.fraction))" }.joined(separator: ", "))
    check((g?.utilization ?? 0) > 0.5, "engine: GPU > 50% under the Metal load (\(pct(g?.utilization)))")
    check(g?.memoryInUse.map { $0 > 0 } ?? false, "engine: GPU memory in use reported")
    if sampleScan.accelerators.contains(where: \.reportsClientTime) {
        check((loadDiag.gpuClientTime ?? 0) > 0.5,
              "engine: busy-time average alone > 50% although another process keeps reading the driver's utilisation (\(pct(loadDiag.gpuClientTime)))")
        if let device = loadDiag.gpuDeviceUtilization, device < 0.5 {
            print("    reproduced the old bug: the driver's utilisation read \(pct(device)) under full load (consumed by the other reader)")
        }
        let mine = busy.gpuProcesses?.first { $0.pid == getpid() }
        check((mine?.fraction ?? 0) > 0.2, "engine: this process is listed among the GPU processes (\(pct(mine?.fraction)))")
        check(GPUDetail.processRows(busy.gpuProcesses ?? []).contains { $0.label == mine?.name }
              || (busy.gpuProcesses?.firstIndex { $0.pid == getpid() } ?? 99) >= GPUDetail.processRowLimit,
              "popover GPU process rows show it when it is among the top \(GPUDetail.processRowLimit)")
    }

    // Module, the user's path: GPU NOT in the menu bar; the settings page (like the popover) is opened
    // while the model runs. Then GPU is added to the menu bar (individual item, then combined). 1 s refresh.
    guard NSStatusBar.system.thickness > 0 else {
        print("    no window server — module part skipped")
        engine.stop()
        return
    }
    let (suite, suitePath) = tempDefaults("gpuload")
    defer {
        removeTempDefaults(suite, suitePath)
        removeStatusItemDefaults()
    }
    var settings = MonitorSettings()
    settings.enabledMetrics = [.memory]
    settings.combined = false
    settings.interval = 1
    settings.gpuDisplay = .utilizationAndMemory
    suite.set(try? JSONEncoder().encode(settings), forKey: "monitor.settings")
    let module = SystemMonitorModule(defaults: suite)
    module.start()
    defer { module.stop() }
    check(!module.configuration(for: module.store.value).metrics.contains(.gpu)
          && MonitorSummary.lines(snapshot: module.model.snapshot, settings: module.store.value) == ["内存 --"],
          "module: GPU not shown → not sampled, not in the menu summary")
    let settingsPage = ObjectIdentifier(NSNumber.self)
    module.settingsVisibilityChanged(settingsPage, true)
    check(module.configuration(for: module.store.value).metrics.contains(.gpu) && GPUDetail.value(module.model.snapshot.gpu) == "--",
          "module: settings page opened → GPU sampled, shows -- until the first average (no stale 0)")
    let viaSettings = waitUntil(3) { (module.model.snapshot.gpu?.utilization ?? 0) > 0.5 }
    check(viaSettings, "module: settings page / popover path reports GPU > 50% under the load (\(pct(module.model.snapshot.gpu?.utilization)))")
    if let gpu = module.model.snapshot.gpu {
        print("    settings: GPU \(GPUDetail.value(gpu)); popover rows: \(GPUDetail.rows(gpu).map { "\($0.label) \($0.value)" })")
        check(GPUDetail.value(gpu).hasPrefix(MonitorFormat.percent(gpu.utilization)) && GPUDetail.value(gpu).contains("显存"),
              "settings live value shows the live GPU value and 显存")
        check(GPUDetail.rows(gpu).first?.label == "显存（使用中）" && GPUDetail.rows(gpu).count == 2, "popover GPU card rows: 显存 in use / allocated")
    }

    // GPU added to the menu bar while it is already sampled: live value at once, sampling continues.
    module.store.update { $0.enabledMetrics = [.gpu, .memory] }
    module.settingsVisibilityChanged(settingsPage, false)
    check(module.configuration(for: module.store.value).metrics == [.gpu, .memory], "module: GPU shown → GPU sampled")
    let loaded = waitUntil(2) { (module.model.snapshot.gpu?.utilization ?? 0) > 0.5 }
    let snap = module.model.snapshot
    check(loaded, "module: published snapshot reports GPU > 50% while GPU is displayed (\(pct(snap.gpu?.utilization)))")
    let summary = module.menuItems().first?.title ?? ""
    print("    menu: \(summary)")
    check(summary == MonitorSummary.lines(snapshot: snap, settings: module.store.value).first
          && summary.hasPrefix("GPU \(MonitorFormat.percent(snap.gpu?.utilization))") && summary.contains("显存 "),
          "menu summary shows the live GPU value and 显存")
    if let percent = Int(summary.dropFirst(4).prefix { $0.isNumber }) {
        check(percent > 50, "menu summary GPU > 50% (\(percent)%)")
    } else {
        check(false, "menu summary GPU percentage parsed from '\(summary)'")
    }
    let itemText = module.statusItems.items[.gpu]?.button?.image?.accessibilityDescription ?? ""
    print("    status item: \(itemText)")
    check(itemText == MonitorSummary.gpu(snap.gpu), "GPU status item rendered from the same live snapshot")
    check(module.model.history(.gpu).contains { $0 > 0.5 }, "GPU sparkline history holds the busy samples")

    // 合并显示: the combined item carries the GPU segment.
    module.store.update { $0.combined = true }
    func combinedGPUPercent() -> Int? {
        guard let text = module.statusItems.combinedItem?.button?.image?.accessibilityDescription, text.hasPrefix("GPU ") else { return nil }
        return Int(text.dropFirst(4).prefix { $0.isNumber })
    }
    let before = module.model.snapshot.timestamp
    let combinedLive = waitUntil(2) { module.model.snapshot.timestamp > before && (combinedGPUPercent() ?? 0) > 50 }
    print("    combined item: \(module.statusItems.combinedItem?.button?.image?.accessibilityDescription ?? "nil")")
    check(combinedLive && module.statusItems.combinedItem?.isVisible == true,
          "combined item shows the live GPU value > 50% (\(combinedGPUPercent().map { "\($0)%" } ?? "nil"))")
    module.stop()
    load.stop()
    print(String(format: "    load: %d dispatches, %.2f s GPU time in %.2f s", load.dispatches.value, load.gpuSeconds.value,
                 Date().timeIntervalSince(started)))

    // A short burst between two samples (a model answering a short prompt): the GPU is idle again when
    // the second sample is taken, so an instantaneous reading says 0 — the interval average must not.
    guard let burst = GPULoad() else { return }
    _ = engine.sampleNow([.gpu])
    let burstStart = Date()
    burst.start(seconds: 0.6)
    burst.join()
    spin(0.4)
    let afterBurst = engine.sampleNow([.gpu])
    let burstDiag = engine.diagnostics()
    let window = Date().timeIntervalSince(burstStart)
    print(String(format: "    burst: %.2f s GPU time in a %.2f s window → %@ (busy time %@, device utilisation %@)", burst.gpuSeconds.value,
                 window, pct(afterBurst.gpu?.utilization), pct(burstDiag.gpuClientTime), pct(burstDiag.gpuDeviceUtilization)))
    check((afterBurst.gpu?.utilization ?? 0) > 0.3, "a burst between two samples is counted (\(pct(afterBurst.gpu?.utilization)))")
    if sampleScan.accelerators.contains(where: \.reportsClientTime) {
        check((burstDiag.gpuClientTime ?? 0) > 0.3, "…by the busy-time average itself (\(pct(burstDiag.gpuClientTime)))")
    }
    engine.stop()
}

/// A model engine that replaces its command queue (e.g. a new context per model load / chat): the driver
/// drops the released queue's counter, so the client's summed GPU time shrinks. That window must still
/// count the new queue's work (a summed counter reads 0 there). ≤ 0.8 s of GPU load.
@MainActor
func checkGPUQueueChurn() {
    print("GPU time across a command-queue swap (≤ 0.8 s)")
    guard let load = GPULoad(), GPUSampler.scan(cached: [:]).accelerators.contains(where: \.reportsClientTime) else {
        print("    no Metal device / no per-client GPU times — skipped")
        return
    }
    let engine = MonitorEngine { _ in }
    defer { engine.stop() }
    var windowStart = Date()
    let replaced = Box(0.0)
    autoreleasepool {
        guard let first = load.device.makeCommandQueue() else { return }
        load.run(on: first, seconds: 0.35)
        _ = engine.sampleNow([.gpu]) // baseline: the first queue holds ~0.35 s
        windowStart = Date()
        load.run(on: first, seconds: 0.1)
        replaced.value = load.gpuSeconds.value
    } // the first queue is released here; its last 0.1 s are lost for good
    guard let second = load.device.makeCommandQueue() else { return }
    load.run(on: second, seconds: 0.3) // < the first queue's total: the client's summed counter shrinks
    let after = engine.sampleNow([.gpu])
    let diag = engine.diagnostics()
    let window = Date().timeIntervalSince(windowStart)
    print(String(format: "    %.2f s GPU time in a %.2f s window (%.2f s on the released queue) → busy time %@, reading %@",
                 load.gpuSeconds.value - replaced.value + 0.1, window, 0.1, pct(diag.gpuClientTime), pct(after.gpu?.utilization)))
    check((diag.gpuClientTime ?? 0) > 0.5, "busy-time average counts the new queue after a swap (\(pct(diag.gpuClientTime)))")
    withExtendedLifetime(second) {}
}

/// Optional visual output (SM_RENDER_DIR): renders the detail popover and the settings page with live data.
@MainActor
func renderViews() {
    guard let dir = ProcessInfo.processInfo.environment["SM_RENDER_DIR"] else { return }
    print("Rendering views to \(dir)")
    let model = MonitorModel()
    let engine = MonitorEngine { _ in }
    for _ in 0..<4 {
        model.ingest(engine.sampleNow(Set(MonitorMetric.allCases), includeProcesses: true))
        Thread.sleep(forTimeInterval: 0.6)
    }
    engine.stop()
    let (suite, suitePath) = tempDefaults("render")
    let store = SettingsStore(key: "monitor.settings", defaultValue: MonitorSettings(), defaults: suite)
    func render(_ view: AnyView, size: NSSize, name: String, dark: Bool) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        spin(0.3)
        let fitting = host.fittingSize
        if fitting.height > 10 { host.frame.size.height = min(1400, fitting.height); window.setContentSize(host.frame.size) }
        spin(0.3)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        window.close()
    }
    for dark in [false, true] {
        render(AnyView(DetailView(model: model, store: store, pin: PopoverPinState(), openActivityMonitor: {}, openSettings: {})
                        .background(dark ? Color(white: 0.16) : Color(white: 0.96))),
               size: NSSize(width: 440, height: 900), name: "popover-\(dark ? "dark" : "light").png", dark: dark)
    }
    render(AnyView(MonitorSettingsView(store: store, model: model, onVisibilityChange: { _, _ in })),
           size: NSSize(width: 620, height: 1100), name: "settings.png", dark: false)
    removeTempDefaults(suite, suitePath)
}

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    checkPureLogic()
    checkFormatting()
    checkSparklines()
    checkSettings()
    checkRealSamplers()
    checkEngine()
    checkModuleLifecycle()
    checkAnchorWatcher()
    checkGPULoad()
    checkGPUQueueChurn()
    renderViews()
}
print(failures == 0 ? "SystemMonitorCheck: ALL PASSED" : "SystemMonitorCheck: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
