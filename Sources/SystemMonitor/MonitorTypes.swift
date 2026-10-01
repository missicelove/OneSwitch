import Foundation
import OneSwitchCore

/// One system metric that can be shown in the menu bar.
public enum MonitorMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    // Declaration order = desired left→right order in the menu bar.
    case cpu, gpu, memory, network, disk, power, temperature

    public var id: String { rawValue }

    /// Chinese display name.
    public var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "内存"
        case .network: return "网络"
        case .disk: return "磁盘"
        case .power: return "功率"
        case .temperature: return "温度"
        }
    }

    /// SF Symbol used by the 图标+数值 style and in the settings / detail views.
    public var symbolName: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "square.3.layers.3d"
        case .memory: return "memorychip"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .power: return "bolt"
        case .temperature: return "thermometer.medium"
        }
    }
}

/// How a metric is rendered in the menu bar.
public enum DisplayStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case text, iconValue, sparkline
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .text: return "文字"
        case .iconValue: return "图标+数值"
        case .sparkline: return "迷你图"
        }
    }
}

/// Which temperature the 温度 status item shows.
public enum TemperatureSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case cpu, gpu, hottest
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .hottest: return "最高"
        }
    }
}

/// What the 磁盘 status item shows.
public enum DiskDisplay: String, CaseIterable, Codable, Identifiable, Sendable {
    case throughput, capacity
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .throughput: return "读写速率"
        case .capacity: return "已用空间"
        }
    }
}

/// What the GPU status item shows.
public enum GPUDisplay: String, CaseIterable, Codable, Identifiable, Sendable {
    case utilization, utilizationAndMemory
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .utilization: return "利用率"
        case .utilizationAndMemory: return "利用率和显存"
        }
    }
}

/// Persisted settings of the 系统监控 module (`monitor.settings`).
public struct MonitorSettings: Codable, Equatable, Sendable {
    /// Metrics shown in the menu bar.
    public var enabledMetrics: Set<MonitorMetric> = [.cpu, .memory, .network]
    /// Show all enabled metrics in one status item.
    /// Laptops (notched, crowded menu bars) default to one combined item; desktops to one item per metric.
    public var combined = AppEnvironment.isLaptop
    public var style: DisplayStyle = .text
    /// Sampling interval in seconds (one of `MonitorSettings.intervalChoices`).
    public var interval: Int = 2
    /// BSD name of the interface to show, or "" for 全部接口.
    public var networkInterface: String = ""
    public var temperatureSource: TemperatureSource = .cpu
    public var diskDisplay: DiskDisplay = .throughput
    public var gpuDisplay: GPUDisplay = .utilization
    /// Tint high values (CPU / 内存 ≥ 85 %, 温度 ≥ 90 °C) orange / red.
    public var colorWarning = true

    public static let intervalChoices = [1, 2, 3, 5]

    public init() {}

    /// The interval clamped to a supported value.
    public var effectiveInterval: TimeInterval {
        Self.intervalChoices.contains(interval) ? TimeInterval(interval) : 2
    }

    /// Enabled metrics in menu-bar (left→right) order.
    public var orderedEnabledMetrics: [MonitorMetric] {
        MonitorMetric.allCases.filter { enabledMetrics.contains($0) }
    }
}

// MARK: - Readings

public struct CPUReading: Equatable, Sendable {
    /// Busy fraction 0…1 (user + system + nice).
    public var total: Double
    public var user: Double
    public var system: Double
    /// Average busy fraction of the performance / efficiency cores; nil when the core layout is unknown.
    public var performanceCores: Double?
    public var efficiencyCores: Double?
    public var performanceCoreCount: Int
    public var efficiencyCoreCount: Int
    /// Per-logical-CPU busy fraction (processor-list order).
    public var perCore: [Double]
}

public struct GPUReading: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// GPU time of all clients over the sampling interval (floored by the device utilisation).
        case clientTime
        /// The driver's instantaneous "Device Utilization %" only (no per-client times reported).
        case deviceUtilization
    }
    /// Busy fraction 0…1.
    public var utilization: Double
    /// "In use system memory": unified memory currently used by GPU work, in bytes.
    public var memoryInUse: UInt64?
    /// "Alloc system memory": unified memory allocated by all GPU clients (loaded models etc.), in bytes.
    public var memoryAllocated: UInt64? = nil
    public var name: String
    public var source: Source = .deviceUtilization
}

/// A process's share of GPU time during the last sampling interval.
public struct GPUProcessUsage: Equatable, Sendable, Identifiable {
    public var pid: Int32
    /// App display name ("LM Studio"), or the executable name.
    public var name: String
    /// Executable name when it differs from `name` (e.g. "node").
    public var processName: String?
    /// Share of the interval the GPU spent on this process, 0…1.
    public var fraction: Double
    public var id: Int32 { pid }
}

public enum MemoryPressure: Int, Equatable, Sendable {
    case unknown = 0, normal = 1, warning = 2, critical = 4

    public var title: String {
        switch self {
        case .unknown: return "未知"
        case .normal: return "正常"
        case .warning: return "警告"
        case .critical: return "严重"
        }
    }
}

public struct MemoryReading: Equatable, Sendable {
    public var total: UInt64
    /// App memory + wired + compressed.
    public var used: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    /// File-backed + purgeable pages.
    public var cached: UInt64
    public var free: UInt64
    public var swapUsed: UInt64
    public var swapTotal: UInt64
    public var pressure: MemoryPressure

    /// used / total, 0…1.
    public var fraction: Double { total > 0 ? min(1, Double(used) / Double(total)) : 0 }
}

public struct InterfaceRate: Equatable, Sendable, Identifiable {
    public var bsdName: String
    /// Chinese label, e.g. "雷雳网桥", "Wi‑Fi", "以太网".
    public var label: String
    public var up: Double
    public var down: Double
    /// Cumulative 64-bit counters.
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    public var id: String { bsdName }
}

public struct NetworkReading: Equatable, Sendable {
    /// Bytes/s of the selected interface (or the sum of all counted interfaces).
    public var up: Double
    public var down: Double
    /// Cumulative counters of the selection (sum over counted interfaces).
    public var bytesIn: UInt64
    public var bytesOut: UInt64
    /// Counted interfaces (up, with an IPv4/IPv6 address, not excluded), sorted by label.
    public var interfaces: [InterfaceRate]
    /// "" = all interfaces.
    public var selection: String
    /// Label of the selection ("全部接口" or the interface label).
    public var selectionLabel: String
}

public struct DiskReading: Equatable, Sendable {
    public var readRate: Double
    public var writeRate: Double
    /// Cumulative counters summed over physical block-storage drivers.
    public var bytesRead: UInt64
    public var bytesWritten: UInt64
    public var capacityTotal: Int64?
    public var capacityAvailable: Int64?

    public var usedFraction: Double? {
        guard let t = capacityTotal, let a = capacityAvailable, t > 0 else { return nil }
        return min(1, max(0, Double(t - a) / Double(t)))
    }
}

public struct BatteryReading: Equatable, Sendable {
    /// 0…1
    public var level: Double
    public var isCharging: Bool
    public var onAC: Bool
    /// Battery power in W (positive = charging, negative = discharging), from AppleSmartBattery.
    public var batteryWatts: Double?
    /// Connected adapter rating in W.
    public var adapterWatts: Double?
    /// Minutes until empty / full, when known.
    public var minutesRemaining: Int?
}

public struct PowerReading: Equatable, Sendable {
    /// Total system power in W.
    public var systemWatts: Double?
    /// SMC key the value came from ("PSTR", "PDTR", "PPBR").
    public var sourceKey: String?
    public var battery: BatteryReading?
}

public struct TemperatureReading: Equatable, Sendable {
    public enum Source: String, Sendable { case smc = "SMC", hid = "HID" }
    public var cpuAverage: Double?
    public var cpuMax: Double?
    public var gpuAverage: Double?
    public var gpuMax: Double?
    public var cpuSensorCount: Int
    public var gpuSensorCount: Int
    public var source: Source

    /// Value shown for a given 温度来源 setting (falls back to CPU when GPU is unavailable).
    public func value(for source: TemperatureSource) -> Double? {
        switch source {
        case .cpu: return cpuAverage ?? gpuAverage
        case .gpu: return gpuAverage ?? cpuAverage
        case .hottest:
            let values = [cpuMax, gpuMax].compactMap { $0 }
            return values.max()
        }
    }
}

public struct ProcessUsage: Equatable, Sendable, Identifiable {
    public var pid: Int32
    /// %CPU as reported by ps (can exceed 100 on multi-core).
    public var cpuPercent: Double
    public var name: String
    public var id: Int32 { pid }
}

/// One sampling pass. Readings are nil when the metric was not sampled or is unavailable.
public struct MonitorSnapshot: Equatable, Sendable {
    public var timestamp: Date
    /// Metrics that were requested in this pass.
    public var sampled: Set<MonitorMetric>
    public var cpu: CPUReading?
    public var gpu: GPUReading?
    public var memory: MemoryReading?
    public var network: NetworkReading?
    public var disk: DiskReading?
    public var power: PowerReading?
    public var temperature: TemperatureReading?
    /// Top processes by CPU; only filled while the detail popover is open.
    public var processes: [ProcessUsage]?
    /// Top processes by GPU time; only filled while the detail popover is open and the GPU is sampled.
    public var gpuProcesses: [GPUProcessUsage]?

    public init(timestamp: Date = Date(), sampled: Set<MonitorMetric> = []) {
        self.timestamp = timestamp
        self.sampled = sampled
    }

    /// This snapshot without the readings of metrics outside `metrics` (they are no longer sampled, so
    /// their values would only get older).
    public func restricted(to metrics: Set<MonitorMetric>) -> MonitorSnapshot {
        var s = self
        s.sampled.formIntersection(metrics)
        if !metrics.contains(.cpu) { s.cpu = nil }
        if !metrics.contains(.gpu) { s.gpu = nil; s.gpuProcesses = nil }
        if !metrics.contains(.memory) { s.memory = nil }
        if !metrics.contains(.network) { s.network = nil }
        if !metrics.contains(.disk) { s.disk = nil }
        if !metrics.contains(.power) { s.power = nil }
        if !metrics.contains(.temperature) { s.temperature = nil }
        return s
    }
}
