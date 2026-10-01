import Combine
import Foundation

/// Latest snapshot plus sample histories, observed by the popover and the settings page. Main actor.
@MainActor
final class MonitorModel: ObservableObject {
    static let historyCapacity = 60

    @Published private(set) var snapshot = MonitorSnapshot()
    @Published private(set) var histories: [HistorySeries: SampleHistory] = [:]
    @Published private(set) var processes: [ProcessUsage] = []
    /// Top GPU processes (only while the detail popover is open).
    @Published private(set) var gpuProcesses: [GPUProcessUsage] = []
    /// Last known counted interfaces (kept while the network is not sampled; for the settings picker).
    @Published private(set) var knownInterfaces: [InterfaceRate] = []
    /// Last sensor summary (kept while temperature / power are not sampled; for the settings page).
    @Published private(set) var lastTemperature: TemperatureReading?
    @Published private(set) var lastPower: PowerReading?
    /// Consecutive passes that included each metric (to tell "still collecting" from "not available").
    private(set) var passes: [MonitorMetric: Int] = [:]

    func ingest(_ s: MonitorSnapshot) {
        var h = histories
        for series in HistorySeries.all {
            guard s.sampled.contains(series.metric) else {
                // Not sampled any more: drop the history so a sparkline never joins stale data.
                h[series] = nil
                continue
            }
            if let v = series.value(in: s) {
                h[series, default: SampleHistory(capacity: Self.historyCapacity)].append(v)
            }
        }
        histories = h
        for metric in MonitorMetric.allCases {
            passes[metric] = s.sampled.contains(metric) ? (passes[metric] ?? 0) + 1 : 0
        }
        snapshot = s
        if let p = s.processes { processes = p }
        if let g = s.gpuProcesses { gpuProcesses = g }
        if let n = s.network { knownInterfaces = n.interfaces }
        if let t = s.temperature { lastTemperature = t }
        if let p = s.power { lastPower = p }
    }

    /// True when the metric was sampled repeatedly but produced no reading (e.g. no GPU / SMC).
    /// CPU and GPU are averaged between two passes (the first one is a baseline), so they get one
    /// more pass before they count as unavailable.
    func isUnavailable(_ metric: MonitorMetric) -> Bool {
        let needed = metric == .cpu || metric == .gpu ? 3 : 2
        return (passes[metric] ?? 0) >= needed && !hasReading(metric)
    }

    private func hasReading(_ metric: MonitorMetric) -> Bool {
        switch metric {
        case .cpu: return snapshot.cpu != nil
        case .gpu: return snapshot.gpu != nil
        case .memory: return snapshot.memory != nil
        case .network: return snapshot.network != nil
        case .disk: return snapshot.disk != nil
        case .power: return snapshot.power != nil
        case .temperature: return snapshot.temperature != nil
        }
    }

    /// Sampling stopped for every metric outside `metrics`: drop their readings, histories and pass
    /// counts. Otherwise the last snapshot keeps them — frozen for good once the timer goes idle — and a
    /// view that shows the metric again (popover, settings page, re-enabled item) would first display
    /// that old value (e.g. an old GPU 0 %) instead of "--".
    func discardReadings(except metrics: Set<MonitorMetric>) {
        let s = snapshot.restricted(to: metrics)
        if s != snapshot { snapshot = s }
        if histories.keys.contains(where: { !metrics.contains($0.metric) }) {
            histories = histories.filter { metrics.contains($0.key.metric) }
        }
        for metric in MonitorMetric.allCases where !metrics.contains(metric) { passes[metric] = 0 }
        if !metrics.contains(.gpu) && !gpuProcesses.isEmpty { gpuProcesses = [] }
    }

    func clearProcesses() {
        processes = []
        gpuProcesses = []
    }

    func history(_ series: HistorySeries) -> [Double] {
        histories[series]?.values ?? []
    }
}
