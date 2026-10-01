import Foundation
import IOKit

/// Disk throughput from IOBlockStorageDriver "Statistics" (physical drivers only) and boot-volume
/// capacity. Confined to the sampler queue.
final class DiskSampler {
    struct DriverCounters: Equatable {
        var id: UInt64
        var bytesRead: UInt64
        var bytesWritten: UInt64
    }

    private var previous: [UInt64: DriverCounters] = [:]
    private var previousTime: Double?
    private var lastRates: (read: Double, write: Double) = (0, 0)
    private var capacity: (total: Int64, available: Int64)?
    private var capacityTime: Double = -.infinity
    private let volumeURL: URL
    static let capacityRefreshInterval: Double = 30

    init(volumeURL: URL = URL(fileURLWithPath: "/")) {
        self.volumeURL = volumeURL
    }

    func reset() {
        previous = [:]
        previousTime = nil
        lastRates = (0, 0)
        capacityTime = -.infinity
    }

    func sample() -> DiskReading? {
        let drivers = Self.readDrivers()
        let now = monotonicSeconds()
        if now - capacityTime >= Self.capacityRefreshInterval {
            capacity = Self.readCapacity(volumeURL)
            capacityTime = now
        }
        let elapsed = previousTime.map { now - $0 }
        if elapsed.map({ $0 >= 0.25 }) ?? true {
            var readDelta = 0.0, writeDelta = 0.0
            for d in drivers {
                // New drivers (disk attached) contribute nothing until they have a baseline.
                guard let prev = previous[d.id] else { continue }
                if d.bytesRead >= prev.bytesRead { readDelta += Double(d.bytesRead - prev.bytesRead) }
                if d.bytesWritten >= prev.bytesWritten { writeDelta += Double(d.bytesWritten - prev.bytesWritten) }
            }
            if let elapsed, elapsed > 0 {
                lastRates = (readDelta / elapsed, writeDelta / elapsed)
            } else {
                lastRates = (0, 0)
            }
            previous = Dictionary(drivers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            previousTime = now
        }
        return DiskReading(readRate: lastRates.read, writeRate: lastRates.write,
                           bytesRead: drivers.reduce(0) { $0 &+ $1.bytesRead },
                           bytesWritten: drivers.reduce(0) { $0 &+ $1.bytesWritten },
                           capacityTotal: capacity?.total, capacityAvailable: capacity?.available)
    }

    /// Counters of every physical IOBlockStorageDriver (disk images / virtual devices are skipped).
    static func readDrivers() -> [DriverCounters] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [DriverCounters] = []
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            guard isPhysical(driver),
                  let stats = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            let read = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let written = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(driver, &entryID)
            result.append(DriverCounters(id: entryID, bytesRead: read, bytesWritten: written))
        }
        return result
    }

    /// The driver's provider (IOBlockStorageDevice) describes its interconnect; disk images report
    /// "Virtual Interface" / location "File".
    private static func isPhysical(_ driver: io_registry_entry_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS else { return true }
        defer { IOObjectRelease(parent) }
        guard let proto = IORegistryEntryCreateCFProperty(parent, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { return true }
        return isPhysical(protocolCharacteristics: proto)
    }

    /// Pure predicate (exposed for checks).
    static func isPhysical(protocolCharacteristics proto: [String: Any]) -> Bool {
        let interconnect = (proto["Physical Interconnect"] as? String ?? "").lowercased()
        let location = (proto["Physical Interconnect Location"] as? String ?? "").lowercased()
        if interconnect.contains("virtual") || interconnect.contains("disk image") { return false }
        if location == "file" || location.contains("virtual") { return false }
        return true
    }

    static func readCapacity(_ url: URL) -> (total: Int64, available: Int64)? {
        // A fresh URL object: NSURL caches resource values for its lifetime.
        let fresh = URL(fileURLWithPath: url.path, isDirectory: true)
        guard let values = try? fresh.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                             .volumeAvailableCapacityForImportantUsageKey,
                                                             .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
        return (Int64(total), min(Int64(total), max(0, available)))
    }
}
