import Darwin
import Foundation
import IOKit

/// CPU usage from `host_processor_info` tick deltas. Confined to the sampler queue.
final class CPUSampler {
    enum CoreKind: Equatable { case performance, efficiency }

    private struct Ticks { var user: UInt64; var system: UInt64; var idle: UInt64; var nice: UInt64 }

    private var previous: [Ticks]?
    private var previousTime: Double?
    private var lastReading: CPUReading?
    /// Core kind per logical CPU index, or nil when the layout could not be determined.
    let coreKinds: [CoreKind]?
    let performanceCoreCount: Int
    let efficiencyCoreCount: Int

    init() {
        let kinds = Self.readCoreKinds()
        coreKinds = kinds
        performanceCoreCount = kinds?.filter { $0 == .performance }.count ?? 0
        efficiencyCoreCount = kinds?.filter { $0 == .efficiency }.count ?? 0
    }

    func reset() {
        previous = nil
        previousTime = nil
        lastReading = nil
    }

    /// Returns nil on the first call (baseline) or when the kernel call fails. A call less than
    /// 0.25 s after the previous one returns the previous reading (too few ticks to be meaningful).
    func sample() -> CPUReading? {
        let now = monotonicSeconds()
        if let t = previousTime, previous != nil, now - t < 0.25 { return lastReading }
        guard let current = Self.readTicks() else { return nil }
        defer {
            previous = current
            previousTime = now
        }
        guard let previous, previous.count == current.count else {
            lastReading = nil
            return nil
        }
        lastReading = Self.reading(previous: previous.map { [$0.user, $0.system, $0.idle, $0.nice] },
                                   current: current.map { [$0.user, $0.system, $0.idle, $0.nice] },
                                   coreKinds: coreKinds)
        return lastReading
    }

    /// Pure computation from two tick snapshots ([user, system, idle, nice] per CPU). Exposed for checks.
    /// The kernel's tick counters are 32-bit and wrap (after ~497 days per state at 100 Hz), so deltas
    /// are taken modulo 2^32; a modular delta of half the range or more can only be a reset → 0.
    static func reading(previous: [[UInt64]], current: [[UInt64]], coreKinds: [CoreKind]?) -> CPUReading? {
        guard previous.count == current.count, !current.isEmpty else { return nil }
        var sumUser = 0.0, sumSystem = 0.0, sumBusy = 0.0, sumAll = 0.0
        var pBusy = 0.0, pAll = 0.0, eBusy = 0.0, eAll = 0.0
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        for i in 0..<current.count {
            func delta(_ k: Int) -> Double {
                let d = UInt32(truncatingIfNeeded: current[i][k]) &- UInt32(truncatingIfNeeded: previous[i][k])
                return d < UInt32(1) << 31 ? Double(d) : 0 // counter reset / CPU re-registered
            }
            let user = delta(0), system = delta(1), idle = delta(2), nice = delta(3)
            let busy = user + system + nice
            let all = busy + idle
            sumUser += user + nice
            sumSystem += system
            sumBusy += busy
            sumAll += all
            perCore.append(all > 0 ? busy / all : 0)
            if let coreKinds, i < coreKinds.count {
                switch coreKinds[i] {
                case .performance: pBusy += busy; pAll += all
                case .efficiency: eBusy += busy; eAll += all
                }
            }
        }
        guard sumAll > 0 else {
            return CPUReading(total: 0, user: 0, system: 0, performanceCores: nil, efficiencyCores: nil,
                              performanceCoreCount: 0, efficiencyCoreCount: 0, perCore: perCore)
        }
        let layoutKnown = coreKinds?.count == current.count
        return CPUReading(
            total: min(1, sumBusy / sumAll),
            user: min(1, sumUser / sumAll),
            system: min(1, sumSystem / sumAll),
            performanceCores: layoutKnown && pAll > 0 ? min(1, pBusy / pAll) : nil,
            efficiencyCores: layoutKnown && eAll > 0 ? min(1, eBusy / eAll) : nil,
            performanceCoreCount: layoutKnown ? coreKinds!.filter { $0 == .performance }.count : 0,
            efficiencyCoreCount: layoutKnown ? coreKinds!.filter { $0 == .efficiency }.count : 0,
            perCore: perCore)
    }

    private static func readTicks() -> [Ticks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(machHostPort, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(cpuCount) * stride else { return nil }
        var result: [Ticks] = []
        result.reserveCapacity(Int(cpuCount))
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            // Tick counters are 32-bit unsigned in the kernel ABI.
            func tick(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[base + Int(state)])) }
            result.append(Ticks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                                idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE)))
        }
        return result
    }

    /// Reads each CPU's cluster type ("E"/"P") from the device tree (IODeviceTree:/cpus/cpuN).
    /// Returns nil unless every logical CPU could be classified — then only the total is shown.
    static func readCoreKinds() -> [CoreKind]? {
        let cpuCount = ProcessInfo.processInfo.processorCount
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var kinds = [CoreKind?](repeating: nil, count: cpuCount)
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let typeData = IORegistryEntryCreateCFProperty(entry, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data,
                  let first = typeData.first else { continue }
            let idValue = IORegistryEntryCreateCFProperty(entry, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()
            var logicalID: Int?
            if let n = idValue as? NSNumber {
                logicalID = n.intValue
            } else if let d = idValue as? Data, d.count >= 4 {
                logicalID = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            }
            guard let id = logicalID, id >= 0, id < cpuCount else { continue }
            switch first {
            case UInt8(ascii: "P"): kinds[id] = .performance
            case UInt8(ascii: "E"): kinds[id] = .efficiency
            default: return nil // unknown cluster type (future chips): be conservative
            }
        }
        let resolved = kinds.compactMap { $0 }
        guard resolved.count == cpuCount else { return nil }
        // Cross-check with sysctl hw.perflevel*: perflevel0 = performance, perflevel1 = efficiency.
        let p = sysctlInt("hw.perflevel0.logicalcpu"), e = sysctlInt("hw.perflevel1.logicalcpu")
        if let p, let e, p + e == cpuCount {
            guard resolved.filter({ $0 == .performance }).count == p else { return nil }
        }
        return resolved
    }
}

/// The host port, fetched once: every `mach_host_self()` call adds a user reference to the port
/// name, so calling it on each sampling pass would grow the reference count forever.
let machHostPort: mach_port_t = mach_host_self()

/// Reads a string sysctl by name (e.g. "machdep.cpu.brand_string").
func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
    return String(cString: buf)
}

/// Reads an integer sysctl by name (Int32 or Int64 sized).
func sysctlInt(_ name: String) -> Int? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
    if size == MemoryLayout<Int32>.size {
        var v: Int32 = 0
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }
    if size == MemoryLayout<Int64>.size {
        var v: Int64 = 0
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }
    return nil
}
