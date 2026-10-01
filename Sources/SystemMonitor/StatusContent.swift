import Foundation

/// What one metric shows in the menu bar, independent of how it is drawn.
public struct StatusSegment: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        /// Left-aligned prefix ("↑", "↓", "R", "W").
        public var prefix: String
        /// Right-aligned value ("1.2M").
        public var value: String
        /// Widest possible values; the column width is derived from these, never from `value`.
        public var templates: [String]
    }

    public enum Body: Equatable, Sendable {
        /// Small caption over a value ("CPU" / "23%").
        case captioned(caption: String, value: String, templates: [String])
        /// Two value lines ("↑1.2M" / "↓34K").
        case stacked(top: Line, bottom: Line)
    }

    public var metric: MonitorMetric
    public var body: Body
    public var level: AlertLevel
    /// Normalised (0…1) samples for the sparkline style, oldest first.
    public var spark: [Double]
    /// Optional second series (upload / write), same scale.
    public var spark2: [Double]?
    /// Plain-text description for accessibility / tooltips.
    public var accessibilityText: String
}

/// Builds `StatusSegment`s from the latest snapshot and the sample histories.
public enum StatusContent {
    public static let sparkSamples = 30

    static let percentTemplates = ["100%"]
    static let temperatureTemplates = ["188°"]
    static let powerTemplates = ["888W"]
    static let rateTemplates = ["888B", "888K", "888M", "888G", "888T", "8.8K", "8.8M", "8.8G", "8.8T"]

    public static func segment(for metric: MonitorMetric, snapshot s: MonitorSnapshot,
                               histories: [HistorySeries: SampleHistory], settings: MonitorSettings) -> StatusSegment {
        func spark(_ series: HistorySeries, scale: Sparkline.Scale) -> [Double] {
            let values = histories[series]?.suffix(sparkSamples) ?? []
            return Sparkline.normalize(values, range: Sparkline.range(for: values, scale: scale))
        }
        func pair(_ a: HistorySeries, _ b: HistorySeries, floor: Double) -> ([Double], [Double]) {
            let va = histories[a]?.suffix(sparkSamples) ?? []
            let vb = histories[b]?.suffix(sparkSamples) ?? []
            let range = Sparkline.range(for: va + vb, scale: .zeroBased(floor: floor))
            return (Sparkline.normalize(va, range: range), Sparkline.normalize(vb, range: range))
        }

        switch metric {
        case .cpu:
            let v = s.cpu?.total
            return StatusSegment(metric: .cpu,
                                 body: .captioned(caption: "CPU", value: MonitorFormat.compactPercent(v), templates: percentTemplates),
                                 level: AlertLevel.forLoad(v), spark: spark(.cpu, scale: .unit), spark2: nil,
                                 accessibilityText: "CPU \(MonitorFormat.percent(v))")
        case .gpu:
            // No colour warning: a GPU at 100 % while a model runs is expected, not alarming.
            let v = s.gpu?.utilization
            let text = MonitorSummary.gpu(s.gpu)
            if settings.gpuDisplay == .utilizationAndMemory {
                let memory = MonitorFormat.compactBytes(s.gpu?.memoryInUse)
                return StatusSegment(metric: .gpu,
                                     body: .stacked(top: .init(prefix: "GPU", value: MonitorFormat.compactPercent(v), templates: percentTemplates),
                                                    bottom: .init(prefix: "显存", value: memory, templates: rateTemplates)),
                                     level: .normal, spark: spark(.gpu, scale: .unit), spark2: nil, accessibilityText: text)
            }
            return StatusSegment(metric: .gpu,
                                 body: .captioned(caption: "GPU", value: MonitorFormat.compactPercent(v), templates: percentTemplates),
                                 level: .normal, spark: spark(.gpu, scale: .unit), spark2: nil, accessibilityText: text)
        case .memory:
            let v = s.memory?.fraction
            return StatusSegment(metric: .memory,
                                 body: .captioned(caption: "内存", value: MonitorFormat.compactPercent(v), templates: percentTemplates),
                                 level: AlertLevel.forMemory(s.memory), spark: spark(.memory, scale: .unit), spark2: nil,
                                 accessibilityText: "内存 \(MonitorFormat.percent(v))")
        case .network:
            let up = s.network.map { MonitorFormat.compactRate($0.up) } ?? MonitorFormat.placeholder
            let down = s.network.map { MonitorFormat.compactRate($0.down) } ?? MonitorFormat.placeholder
            let (d, u) = pair(.networkDown, .networkUp, floor: 10 * 1024)
            let text = s.network.map { "网络 上传 \(MonitorFormat.rate($0.up))，下载 \(MonitorFormat.rate($0.down))" } ?? "网络"
            return StatusSegment(metric: .network,
                                 body: .stacked(top: .init(prefix: "↑", value: up, templates: rateTemplates),
                                                bottom: .init(prefix: "↓", value: down, templates: rateTemplates)),
                                 level: .normal, spark: d, spark2: u, accessibilityText: text)
        case .disk:
            if settings.diskDisplay == .capacity {
                let v = s.disk?.usedFraction
                return StatusSegment(metric: .disk,
                                     body: .captioned(caption: "磁盘", value: MonitorFormat.compactPercent(v), templates: percentTemplates),
                                     level: .normal, spark: spark(.diskUsed, scale: .unit), spark2: nil,
                                     accessibilityText: "磁盘已用 \(MonitorFormat.percent(v))")
            }
            let read = s.disk.map { MonitorFormat.compactRate($0.readRate) } ?? MonitorFormat.placeholder
            let write = s.disk.map { MonitorFormat.compactRate($0.writeRate) } ?? MonitorFormat.placeholder
            let (r, w) = pair(.diskRead, .diskWrite, floor: 1024 * 1024)
            let text = s.disk.map { "磁盘 读取 \(MonitorFormat.rate($0.readRate))，写入 \(MonitorFormat.rate($0.writeRate))" } ?? "磁盘"
            return StatusSegment(metric: .disk,
                                 body: .stacked(top: .init(prefix: "R", value: read, templates: rateTemplates),
                                                bottom: .init(prefix: "W", value: write, templates: rateTemplates)),
                                 level: .normal, spark: r, spark2: w, accessibilityText: text)
        case .power:
            let v = s.power?.systemWatts
            return StatusSegment(metric: .power,
                                 body: .captioned(caption: "功率", value: MonitorFormat.compactPower(v), templates: powerTemplates),
                                 level: .normal, spark: spark(.power, scale: .zeroBased(floor: 10)), spark2: nil,
                                 accessibilityText: "功率 \(MonitorFormat.power(v))")
        case .temperature:
            let v = s.temperature?.value(for: settings.temperatureSource)
            return StatusSegment(metric: .temperature,
                                 body: .captioned(caption: "温度", value: MonitorFormat.compactTemperature(v), templates: temperatureTemplates),
                                 level: AlertLevel.forTemperature(v),
                                 spark: spark(HistorySeries.temperature(settings.temperatureSource), scale: .window(minSpan: 10)),
                                 spark2: nil, accessibilityText: "温度 \(MonitorFormat.temperature(v))")
        }
    }
}

/// Keys of the sample histories kept by the model.
public enum HistorySeries: Hashable, Sendable {
    case cpu, gpu, memory, networkUp, networkDown, diskRead, diskWrite, diskUsed, power
    case temperatureCPU, temperatureGPU, temperatureMax

    static func temperature(_ source: TemperatureSource) -> HistorySeries {
        switch source {
        case .cpu: return .temperatureCPU
        case .gpu: return .temperatureGPU
        case .hottest: return .temperatureMax
        }
    }

    /// The metric whose sampling feeds this series.
    var metric: MonitorMetric {
        switch self {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .memory: return .memory
        case .networkUp, .networkDown: return .network
        case .diskRead, .diskWrite, .diskUsed: return .disk
        case .power: return .power
        case .temperatureCPU, .temperatureGPU, .temperatureMax: return .temperature
        }
    }

    static let all: [HistorySeries] = [.cpu, .gpu, .memory, .networkUp, .networkDown, .diskRead, .diskWrite, .diskUsed,
                                       .power, .temperatureCPU, .temperatureGPU, .temperatureMax]

    /// Extracts this series' value from a snapshot (nil when not available).
    func value(in s: MonitorSnapshot) -> Double? {
        switch self {
        case .cpu: return s.cpu?.total
        case .gpu: return s.gpu?.utilization
        case .memory: return s.memory?.fraction
        case .networkUp: return s.network?.up
        case .networkDown: return s.network?.down
        case .diskRead: return s.disk?.readRate
        case .diskWrite: return s.disk?.writeRate
        case .diskUsed: return s.disk?.usedFraction
        case .power: return s.power?.systemWatts
        case .temperatureCPU: return s.temperature?.value(for: .cpu)
        case .temperatureGPU: return s.temperature?.value(for: .gpu)
        case .temperatureMax: return s.temperature?.value(for: .hottest)
        }
    }
}
