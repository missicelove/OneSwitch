import Darwin
import Foundation

/// Memory usage from host_statistics64(HOST_VM_INFO64), vm.swapusage and the memorystatus pressure level.
enum MemorySampler {
    static let physicalMemory: UInt64 = {
        var size = MemoryLayout<UInt64>.size
        var value: UInt64 = 0
        if sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0, value > 0 { return value }
        return ProcessInfo.processInfo.physicalMemory
    }()

    static func sample() -> MemoryReading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(machHostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        let swap = swapUsage()
        return reading(stats: stats, pageSize: pageSize, total: physicalMemory,
                       swapUsed: swap?.used ?? 0, swapTotal: swap?.total ?? 0,
                       pressure: pressureLevel())
    }

    /// Pure computation (exposed for checks).
    static func reading(stats: vm_statistics64, pageSize: UInt64, total: UInt64,
                        swapUsed: UInt64, swapTotal: UInt64, pressure: MemoryPressure) -> MemoryReading {
        let internalPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let appPages = internalPages > purgeable ? internalPages - purgeable : 0
        let wiredPages = UInt64(stats.wire_count)
        let compressedPages = UInt64(stats.compressor_page_count)
        let cachedPages = UInt64(stats.external_page_count) + purgeable
        let freePages = UInt64(stats.free_count) + UInt64(stats.speculative_count)
        let app = appPages * pageSize
        let wired = wiredPages * pageSize
        let compressed = compressedPages * pageSize
        let used = min(total, app + wired + compressed)
        return MemoryReading(total: total, used: used, app: app, wired: wired, compressed: compressed,
                             cached: cachedPages * pageSize, free: freePages * pageSize,
                             swapUsed: swapUsed, swapTotal: swapTotal, pressure: pressure)
    }

    static func swapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_used, usage.xsu_total)
    }

    static func pressureLevel() -> MemoryPressure {
        guard let level = sysctlInt("kern.memorystatus_vm_pressure_level") else { return .unknown }
        return MemoryPressure(rawValue: level) ?? .unknown
    }
}
