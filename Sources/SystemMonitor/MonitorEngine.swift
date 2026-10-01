import Foundation

/// Runs the samplers on a private serial queue at the configured interval and hands each
/// `MonitorSnapshot` to `handler` (on that queue). Only the requested metrics are sampled; with
/// nothing requested the timer is cancelled entirely.
///
/// All mutable state is confined to `queue`; the public methods may be called from any thread.
final class MonitorEngine: @unchecked Sendable {
    struct Configuration: Equatable, Sendable {
        var metrics: Set<MonitorMetric> = []
        var interval: TimeInterval = 2
        var networkInterface: String = ""
        /// Top-5 processes (only while the detail popover is open).
        var includeProcesses = false

        var isIdle: Bool { metrics.isEmpty && !includeProcesses }
    }

    /// Sensor diagnostics for the settings page and the checks.
    struct Diagnostics: Equatable, Sendable {
        var smcCPUKeys: [String] = []
        var smcGPUKeys: [String] = []
        var hidSensors: [String] = []
        var powerKey: String?
        var coreLayoutKnown = false
        var performanceCores = 0
        var efficiencyCores = 0
        /// Where the last GPU utilisation came from (nil before the first GPU reading).
        var gpuSource: GPUReading.Source?
        /// Inputs of the last GPU utilisation: per-client busy-time average and device utilisation.
        var gpuClientTime: Double?
        var gpuDeviceUtilization: Double?
    }

    private let queue = DispatchQueue(label: "com.oneswitch.monitor.sampler", qos: .utility)
    private let handler: @Sendable (MonitorSnapshot) -> Void

    // Queue-confined state.
    private var config = Configuration()
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private lazy var cpu = CPUSampler()
    private lazy var network = NetworkSampler()
    private lazy var disk = DiskSampler()
    private lazy var sensors = SensorSampler()
    private let gpu = GPUSampler()
    private let processes = ProcessSampler()
    private var lastPowerKey: String?

    init(handler: @escaping @Sendable (MonitorSnapshot) -> Void) {
        self.handler = handler
    }

    deinit {
        timer?.cancel()
    }

    /// Applies a new configuration asynchronously.
    func update(_ configuration: Configuration) {
        queue.async { [self] in apply(configuration) }
    }

    /// Stops sampling and releases the SMC connection / HID client. Synchronous; after it returns
    /// no further snapshots are delivered.
    func stop() {
        processes.cancel()
        queue.sync {
            stopped = true
            timer?.cancel()
            timer = nil
            sensors.close()
        }
    }

    /// One synchronous sampling pass (for checks); does not touch the timer. Shares the samplers'
    /// baselines with the timer passes.
    func sampleNow(_ metrics: Set<MonitorMetric>, networkInterface: String = "", includeProcesses: Bool = false) -> MonitorSnapshot {
        queue.sync {
            sample(Configuration(metrics: metrics, interval: config.interval,
                                 networkInterface: networkInterface, includeProcesses: includeProcesses))
        }
    }

    /// Whether the sampling timer is scheduled (for checks: nothing may tick while idle / paused).
    var isTimerActive: Bool { queue.sync { timer != nil } }

    /// The configuration currently applied on the sampler queue (for checks).
    var currentConfiguration: Configuration { queue.sync { config } }

    func diagnostics() -> Diagnostics {
        queue.sync {
            Diagnostics(smcCPUKeys: sensors.lastCPUKeysUsed, smcGPUKeys: sensors.lastGPUKeysUsed,
                        hidSensors: sensors.lastHIDSensorsUsed.map { "\($0.name)=\(String(format: "%.1f", $0.celsius))" },
                        powerKey: lastPowerKey, coreLayoutKnown: cpu.coreKinds != nil,
                        performanceCores: cpu.performanceCoreCount, efficiencyCores: cpu.efficiencyCoreCount,
                        gpuSource: gpu.lastSource, gpuClientTime: gpu.lastComponents.clientTime,
                        gpuDeviceUtilization: gpu.lastComponents.device)
        }
    }

    // MARK: Queue-confined

    private func apply(_ new: Configuration) {
        guard !stopped else { return }
        let old = config
        config = new
        // Metrics that are no longer sampled lose their baseline, so a later restart never computes a
        // rate over the idle gap.
        for metric in old.metrics.subtracting(new.metrics) { reset(metric) }
        if !new.metrics.contains(.power) && !new.metrics.contains(.temperature) { sensors.close() }

        if new.isIdle {
            timer?.cancel()
            timer = nil
            return
        }
        let added = !new.metrics.subtracting(old.metrics).isEmpty || (new.includeProcesses && !old.includeProcesses)
        if timer == nil || added {
            // Immediate pass: instantaneous values right away and baselines for the rate samplers;
            // the next pass follows after ≤ 1 s so rates appear quickly.
            tick()
            schedule(first: min(1, new.interval), repeating: new.interval)
        } else if new.interval != old.interval {
            schedule(first: new.interval, repeating: new.interval)
        }
    }

    private func schedule(first: TimeInterval, repeating: TimeInterval) {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // 10 % leeway lets the system coalesce wake-ups.
        t.schedule(deadline: .now() + first, repeating: repeating, leeway: .milliseconds(max(50, Int(repeating * 100))))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        guard !stopped, !config.isIdle else { return }
        handler(sample(config))
    }

    private func sample(_ c: Configuration) -> MonitorSnapshot {
        var s = MonitorSnapshot(timestamp: Date(), sampled: c.metrics)
        if c.metrics.contains(.cpu) { s.cpu = cpu.sample() }
        if c.metrics.contains(.gpu) {
            let g = gpu.sample(includeProcesses: c.includeProcesses)
            s.gpu = g.reading
            s.gpuProcesses = g.processes
        }
        if c.metrics.contains(.memory) { s.memory = MemorySampler.sample() }
        if c.metrics.contains(.network) { s.network = network.sample(selection: c.networkInterface) }
        if c.metrics.contains(.disk) { s.disk = disk.sample() }
        if c.metrics.contains(.power) {
            s.power = sensors.samplePower()
            lastPowerKey = s.power?.sourceKey
        }
        if c.metrics.contains(.temperature) { s.temperature = sensors.sampleTemperature() }
        if c.includeProcesses { s.processes = processes.topProcesses() }
        return s
    }

    private func reset(_ metric: MonitorMetric) {
        switch metric {
        case .cpu: cpu.reset()
        case .network: network.reset()
        case .disk: disk.reset()
        case .gpu: gpu.reset()
        case .memory, .power, .temperature: break
        }
    }
}
