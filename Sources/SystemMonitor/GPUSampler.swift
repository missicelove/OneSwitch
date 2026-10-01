import Darwin
import Foundation
import IOKit

/// One GPU client (an IOAccelerator user client: a Metal / OpenCL connection of a process) and its
/// cumulative GPU time.
struct GPUClient: Equatable, Sendable {
    /// Registry entry ID of the accelerator the client belongs to.
    var accelerator: UInt64
    var pid: Int32?
    /// Process name as recorded by the driver (at most 16 characters).
    var creatorName: String
    /// Sum of "accumulatedGPUTime" over the client's queues, in ns.
    var gpuTime: UInt64
    /// "accumulatedGPUTime" of each live command queue (one AppUsage entry per queue), in ns. Empty when
    /// only the sum is known (checks).
    var queueTimes: [UInt64] = []
}

/// What one registry pass reads for one accelerator.
struct GPUAcceleratorScan: Sendable {
    var id: UInt64
    var name: String
    /// "Device Utilization %" as 0…1. Measured by the driver since the previous read of
    /// "PerformanceStatistics" by ANY process (each read restarts the window; a second read right
    /// after returns 0), over the time the GPU was active. Another monitor app reading it frequently
    /// therefore makes it read 0 — it is only used as a floor.
    var deviceUtilization: Double?
    /// "In use system memory": unified memory currently used by GPU work.
    var memoryInUse: UInt64?
    /// "Alloc system memory": unified memory allocated by all GPU clients (e.g. loaded models).
    var memoryAllocated: UInt64?
    /// Whether the driver reports per-client "AppUsage" (Apple silicon does).
    var reportsClientTime = false
}

/// GPU utilisation, GPU memory and the top GPU processes. Confined to the sampler queue.
///
/// Utilisation is the GPU time all clients accumulated during the sampling interval divided by the
/// interval (like Activity Monitor's "% GPU"): it cannot be "consumed" by other readers and a model
/// that generates between two samples is counted. The per-client time under-reads long command
/// buffers / low GPU clocks (measured: a 200 ms kernel counts ~30–55 %), so the driver's
/// "Device Utilization %" is used as a floor; it is the only source where per-client times are not
/// reported (Intel / AMD GPUs).
final class GPUSampler {
    /// Shorter windows are too coarse (GPU time is added per completed command buffer).
    static let minimumWindow: TimeInterval = 0.3
    /// Rows in the top-process list.
    static let processLimit = 5

    private var previous: (time: Double, clients: [UInt64: GPUClient])?
    private var lastReading: GPUReading?
    private var lastProcesses: [GPUProcessUsage]?
    private var names: [Int32: GPUProcessNamer.Name] = [:]
    /// Source of the last reading (diagnostics).
    private(set) var lastSource: GPUReading.Source?
    /// The two inputs of the last full reading: busy-time average and device utilisation (diagnostics).
    private(set) var lastComponents: (clientTime: Double?, device: Double?) = (nil, nil)

    func reset() {
        previous = nil
        lastReading = nil
        lastProcesses = nil
        names = [:]
    }

    /// Returns a nil reading on the first call after `reset()` (baseline) when per-client times are
    /// reported — the UI then shows "--" instead of a meaningless instantaneous value.
    func sample(includeProcesses: Bool) -> (reading: GPUReading?, processes: [GPUProcessUsage]?) {
        let now = monotonicSeconds()
        let (accelerators, clients) = Self.scan(cached: previous?.clients ?? [:])
        guard !accelerators.isEmpty else { return (nil, nil) }
        let reportsClientTime = accelerators.contains(where: \.reportsClientTime)

        guard reportsClientTime else {
            // Fallback (e.g. Intel / AMD GPUs): the instantaneous device utilisation.
            previous = nil
            let evaluated = Self.evaluate(accelerators: accelerators, busy: [:])
            lastReading = evaluated?.reading
            lastSource = evaluated?.reading.source
            lastComponents = (evaluated?.clientTime, evaluated?.device)
            return (evaluated?.reading, includeProcesses ? [] : nil)
        }
        guard let prev = previous else {
            previous = (now, clients)
            return (nil, nil)
        }
        let elapsed = now - prev.time
        if elapsed < Self.minimumWindow {
            // Keep the baseline; refresh only the instantaneous memory figures.
            guard var reading = lastReading else { return (nil, nil) }
            if let fresh = Self.reading(accelerators: accelerators, busy: [:]) {
                reading.memoryInUse = fresh.memoryInUse
                reading.memoryAllocated = fresh.memoryAllocated
            }
            return (reading, includeProcesses ? lastProcesses : nil)
        }
        previous = (now, clients)
        let elapsedNs = UInt64(elapsed * 1e9)
        let perClient = Self.busyTime(previous: prev.clients, current: clients, elapsed: elapsedNs)

        var perAccelerator: [UInt64: Double] = [:]
        var perPID: [Int32: UInt64] = [:]
        for (id, busy) in perClient {
            guard let client = clients[id] else { continue }
            perAccelerator[client.accelerator, default: 0] += Double(busy) / Double(elapsedNs)
            if let pid = client.pid { perPID[pid, default: 0] += busy }
        }
        let evaluated = Self.evaluate(accelerators: accelerators, busy: perAccelerator)
        let reading = evaluated?.reading
        lastReading = reading
        lastSource = reading?.source
        lastComponents = (evaluated?.clientTime, evaluated?.device)

        var processes: [GPUProcessUsage]?
        if includeProcesses {
            let creators = Dictionary(clients.values.compactMap { c in c.pid.map { ($0, c.creatorName) } },
                                      uniquingKeysWith: { a, _ in a })
            names = names.filter { creators[$0.key] != nil } // drop exited processes (pid reuse)
            processes = Self.topProcesses(perPID, elapsed: elapsedNs, limit: Self.processLimit).map { pid, fraction in
                let name = names[pid] ?? GPUProcessNamer.name(pid: pid, fallback: creators[pid] ?? "pid \(pid)")
                names[pid] = name
                return GPUProcessUsage(pid: pid, name: name.display, processName: name.process, fraction: fraction)
            }
            lastProcesses = processes
        } else {
            lastProcesses = nil // never show an old list when the popover opens again
        }
        return (reading, processes)
    }

    // MARK: Pure logic (exposed for checks)

    /// GPU time per client between two scans, in ns, each clamped to the window. A client that is new
    /// since the previous scan was created within the window, so all of its time counts (clamped);
    /// vanished clients are ignored. With per-queue counters see `queueDelta`; with only the sums, a
    /// shrinking sum counts as 0.
    static func busyTime(previous: [UInt64: GPUClient], current: [UInt64: GPUClient], elapsed: UInt64) -> [UInt64: UInt64] {
        var result: [UInt64: UInt64] = [:]
        for (id, client) in current {
            let delta: UInt64
            if let old = previous[id] {
                if old.queueTimes.isEmpty && client.queueTimes.isEmpty {
                    delta = client.gpuTime >= old.gpuTime ? client.gpuTime - old.gpuTime : 0
                } else {
                    delta = queueDelta(previous: old.queueTimes, current: client.queueTimes, elapsed: elapsed)
                }
            } else {
                delta = client.gpuTime
            }
            if delta > 0 { result[id] = min(delta, elapsed) }
        }
        return result
    }

    /// GPU time one client's command queues accumulated between two scans, in ns.
    ///
    /// The driver lists one counter per live queue, drops the entry when the queue is released and may
    /// put a new queue in its place (measured: [42, 131, 269] ms → release the 131 ms queue, create
    /// one → [42, 81, 269] ms), so neither the sum nor the position identifies a queue. A live queue's
    /// counter never decreases, so each current counter is matched — largest first — with the largest
    /// unused previous counter not above it; an unmatched counter belongs to a queue created since the
    /// previous scan and counts in full (clamped to the window). The greedy match maximises the matched
    /// previous time, so the result never exceeds the true value (only the final time of a queue that
    /// was released between the scans is lost).
    static func queueDelta(previous: [UInt64], current: [UInt64], elapsed: UInt64) -> UInt64 {
        var unused = previous.sorted()
        var total: UInt64 = 0
        for time in current.sorted(by: >) {
            if let i = unused.lastIndex(where: { $0 <= time }) {
                total &+= time - unused[i]
                unused.remove(at: i)
            } else {
                total &+= min(time, elapsed)
            }
        }
        return total
    }

    /// The reading of the busiest accelerator: utilisation = max(busy-time average, instantaneous
    /// device utilisation), clamped to 0…1. `busy` maps accelerator IDs to busy fractions; an
    /// accelerator missing from it (fallback / idle) uses the device utilisation alone.
    static func reading(accelerators: [GPUAcceleratorScan], busy: [UInt64: Double]) -> GPUReading? {
        evaluate(accelerators: accelerators, busy: busy)?.reading
    }

    /// `reading(accelerators:busy:)` plus its two inputs (client busy time, device utilisation).
    static func evaluate(accelerators: [GPUAcceleratorScan], busy: [UInt64: Double])
        -> (reading: GPUReading, clientTime: Double?, device: Double?)? {
        var best: (reading: GPUReading, clientTime: Double?, device: Double?)?
        for acc in accelerators {
            let clientBusy = acc.reportsClientTime ? min(1, busy[acc.id] ?? 0) : nil
            guard clientBusy != nil || acc.deviceUtilization != nil else { continue }
            let value = min(1, max(0, max(clientBusy ?? 0, acc.deviceUtilization ?? 0)))
            let reading = GPUReading(utilization: value, memoryInUse: acc.memoryInUse, memoryAllocated: acc.memoryAllocated,
                                     name: acc.name, source: clientBusy != nil ? .clientTime : .deviceUtilization)
            // Several accelerators (e.g. dual-GPU Intel Macs): report the busiest one.
            if best == nil || value > best!.reading.utilization { best = (reading, clientBusy, acc.deviceUtilization) }
        }
        return best
    }

    /// Processes sorted by GPU share (≥ 0.5 %), at most `limit`.
    static func topProcesses(_ perPID: [Int32: UInt64], elapsed: UInt64, limit: Int) -> [(Int32, Double)] {
        guard elapsed > 0 else { return [] }
        let window = Double(elapsed)
        var shares: [(Int32, Double)] = []
        for (pid, busy) in perPID {
            let share = min(1, Double(busy) / window)
            if share >= 0.005 { shares.append((pid, share)) }
        }
        shares.sort { a, b in a.1 != b.1 ? a.1 > b.1 : a.0 < b.0 }
        return Array(shares.prefix(limit))
    }

    /// Pure parser for a "PerformanceStatistics" dictionary (instantaneous device utilisation).
    static func reading(from stats: [String: Any], name: String) -> GPUReading? {
        guard let scan = parse(stats, id: 0, name: name), scan.deviceUtilization != nil else { return nil }
        return reading(accelerators: [scan], busy: [:])
    }

    static func parse(_ stats: [String: Any]?, id: UInt64, name: String) -> GPUAcceleratorScan? {
        guard let stats else { return nil }
        let raw = (stats["Device Utilization %"] as? NSNumber) ?? (stats["Renderer Utilization %"] as? NSNumber)
        return GPUAcceleratorScan(id: id, name: name,
                                  deviceUtilization: raw.map { min(1, max(0, $0.doubleValue / 100)) },
                                  memoryInUse: (stats["In use system memory"] as? NSNumber)?.uint64Value,
                                  memoryAllocated: (stats["Alloc system memory"] as? NSNumber)?.uint64Value)
    }

    /// "pid 610, WindowServer" → (610, "WindowServer").
    static func parseCreator(_ creator: String) -> (pid: Int32?, name: String) {
        guard creator.hasPrefix("pid ") else { return (nil, creator) }
        let rest = creator.dropFirst(4)
        let parts = rest.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let pid = parts.first.flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return (pid, name)
    }

    // MARK: IORegistry

    /// One registry walk: every accelerator's statistics and the GPU time of its clients. The creator
    /// string of a client never changes, so it is taken from `cached` for known clients (halves the
    /// registry reads per pass).
    static func scan(cached: [UInt64: GPUClient]) -> (accelerators: [GPUAcceleratorScan], clients: [UInt64: GPUClient]) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return ([], [:]) }
        defer { IOObjectRelease(iterator) }
        var accelerators: [GPUAcceleratorScan] = []
        var clients: [UInt64: GPUClient] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let accID = registryID(entry)
            let name = className(of: entry)
            var scan = parse(property(entry, "PerformanceStatistics") as? [String: Any], id: accID, name: name)
                ?? GPUAcceleratorScan(id: accID, name: name)
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == KERN_SUCCESS {
                while case let child = IOIteratorNext(children), child != 0 {
                    defer { IOObjectRelease(child) }
                    guard let usage = property(child, "AppUsage") as? [[String: Any]] else { continue }
                    scan.reportsClientTime = true
                    let queues = usage.map { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0 }
                    let time = queues.reduce(0, &+)
                    let id = registryID(child)
                    if let known = cached[id], known.accelerator == accID {
                        clients[id] = GPUClient(accelerator: accID, pid: known.pid, creatorName: known.creatorName,
                                                gpuTime: time, queueTimes: queues)
                    } else {
                        let creator = parseCreator(property(child, "IOUserClientCreator") as? String ?? "")
                        clients[id] = GPUClient(accelerator: accID, pid: creator.pid, creatorName: creator.name,
                                                gpuTime: time, queueTimes: queues)
                    }
                }
                IOObjectRelease(children)
            }
            if scan.deviceUtilization != nil || scan.reportsClientTime { accelerators.append(scan) }
        }
        return (accelerators, clients)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func registryID(_ entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    private static func className(of entry: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &buf) == KERN_SUCCESS else { return "GPU" }
        return String(cString: buf)
    }
}

/// Human-readable names for GPU processes: the app a process belongs to ("LM Studio" for its
/// `node` engine or its "LM Studio Helper (GPU)"), else the executable name.
enum GPUProcessNamer {
    struct Name: Equatable, Sendable {
        /// App display name, or the executable name.
        var display: String
        /// Executable name when it differs from `display`.
        var process: String?
    }

    static func name(pid: Int32, fallback: String) -> Name {
        let exe = executablePath(pid)
        let exeName = exe.map { ($0 as NSString).lastPathComponent } ?? fallback
        // The process itself lives in an app bundle, or was started directly by an app's main
        // executable (one level only: a script started from Terminal belongs to the script, not 终端).
        var appPath = exe.flatMap(outermostApp)
        if appPath == nil, let parent = parentPID(pid), parent > 1, let parentExe = executablePath(parent),
           parentExe.contains(".app/Contents/MacOS/") {
            appPath = outermostApp(parentExe)
        }
        guard let appPath else { return Name(display: exeName, process: nil) }
        var display = FileManager.default.displayName(atPath: appPath)
        if display.hasSuffix(".app") { display = String(display.dropLast(4)) }
        if display.isEmpty { display = exeName }
        return Name(display: display, process: exeName == display ? nil : exeName)
    }

    /// "/Applications/LM Studio.app/Contents/Frameworks/LM Studio Helper (GPU).app/Contents/MacOS/…"
    /// → "/Applications/LM Studio.app".
    static func outermostApp(_ path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let i = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let result = components[...i].joined(separator: "/")
        return result.isEmpty ? nil : result
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let path = String(cString: buf)
        return path.isEmpty ? nil : path
    }

    static func parentPID(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }
}
