import AppKit
import OneSwitchCore
import SwiftUI
import SystemConfiguration

/// Content of the popover opened from any monitor status item: every metric with sparklines,
/// breakdowns and the top processes by CPU.
struct DetailView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var store: SettingsStore<MonitorSettings>
    @ObservedObject var pin: PopoverPinState
    let openActivityMonitor: () -> Void
    let openSettings: () -> Void

    private var s: MonitorSnapshot { model.snapshot }

    /// Local computer name from the SystemConfiguration dynamic store (no DNS lookup, unlike `Host`).
    static let computerName: String =
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? AppEnvironment.hardwareModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    cpuCard
                    gpuCard
                }
                GridRow {
                    memoryCard
                    temperatureCard
                }
                GridRow {
                    diskCard
                    powerCard
                }
            }
            networkCard
            processesCard
            Divider()
            HStack {
                Button(action: openActivityMonitor) {
                    Label("活动监视器", systemImage: "waveform.path.ecg.rectangle")
                }
                Spacer()
                Button(action: openSettings) {
                    Label("设置…", systemImage: "gearshape")
                }
            }
            .controlSize(.regular)
        }
        .padding(12)
        .frame(width: 440)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("系统监控").font(.headline)
            Spacer()
            Text(Self.computerName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                pin.isPinned.toggle()
            } label: {
                Image(systemName: pin.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(pin.isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help(pin.isPinned ? "取消固定：点按面板以外的位置时关闭"
                               : "固定面板：切换到其他 App（例如运行模型时）也保持显示，再次点按菜单栏图标关闭")
            .accessibilityLabel(pin.isPinned ? "取消固定面板" : "固定面板")
        }
    }

    // MARK: Cards

    private var cpuCard: some View {
        MetricCard(title: "CPU", symbol: "cpu", value: MonitorFormat.percent(s.cpu?.total),
                   valueColor: levelColor(AlertLevel.forLoad(s.cpu?.total))) {
            SparklineView(values: model.history(.cpu), scale: .unit, color: .blue)
            if let cpu = s.cpu {
                DetailRow("用户", MonitorFormat.percent(cpu.user))
                DetailRow("系统", MonitorFormat.percent(cpu.system))
                if let p = cpu.performanceCores {
                    DetailRow("性能核（\(cpu.performanceCoreCount)）", MonitorFormat.percent(p))
                }
                if let e = cpu.efficiencyCores {
                    DetailRow("能效核（\(cpu.efficiencyCoreCount)）", MonitorFormat.percent(e))
                }
            } else {
                PendingRow()
            }
        }
    }

    private var gpuCard: some View {
        MetricCard(title: "GPU", symbol: MonitorMetric.gpu.symbolName, value: MonitorFormat.percent(s.gpu?.utilization)) {
            SparklineView(values: model.history(.gpu), scale: .unit, color: .purple)
            if let gpu = s.gpu {
                ForEach(GPUDetail.rows(gpu), id: \.label) { DetailRow($0.label, $0.value) }
                let top = Array(model.gpuProcesses.prefix(GPUDetail.processRowLimit))
                if !top.isEmpty {
                    Divider()
                    ForEach(top) { p in
                        HStack(spacing: 4) {
                            Text(p.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(MonitorFormat.percent(p.fraction)).monospacedDigit()
                        }
                        .font(.caption)
                        .help(p.processName.map { "\(p.name)（\($0)，PID \(p.pid)）" } ?? "\(p.name)（PID \(p.pid)）")
                    }
                }
            } else {
                PendingRow(unavailable: model.isUnavailable(.gpu))
            }
        }
    }

    private var memoryCard: some View {
        MetricCard(title: "内存", symbol: "memorychip", value: MonitorFormat.percent(s.memory?.fraction),
                   valueColor: levelColor(AlertLevel.forMemory(s.memory))) {
            SparklineView(values: model.history(.memory), scale: .unit, color: .green)
            if let m = s.memory {
                DetailRow("已使用", "\(MonitorFormat.bytes(m.used)) / \(MonitorFormat.bytes(m.total))")
                DetailRow("内存压力", m.pressure.title, valueColor: pressureColor(m.pressure))
                DetailRow("App 内存", MonitorFormat.bytes(m.app))
                DetailRow("联动内存", MonitorFormat.bytes(m.wired))
                DetailRow("被压缩", MonitorFormat.bytes(m.compressed))
                DetailRow("已缓存文件", MonitorFormat.bytes(m.cached))
                DetailRow("已使用的交换", MonitorFormat.bytes(m.swapUsed))
            } else {
                PendingRow()
            }
        }
    }

    private var temperatureCard: some View {
        let source = store.value.temperatureSource
        let t = s.temperature
        let shown = t?.value(for: source)
        return MetricCard(title: "温度", symbol: "thermometer.medium", value: MonitorFormat.temperature(shown),
                          valueColor: levelColor(AlertLevel.forTemperature(shown))) {
            SparklineView(values: model.history(HistorySeries.temperature(source)), scale: .window(minSpan: 10), color: .red)
            if let t {
                if t.cpuAverage != nil {
                    DetailRow("CPU 平均", MonitorFormat.temperature(t.cpuAverage))
                    DetailRow("CPU 最高", MonitorFormat.temperature(t.cpuMax))
                }
                if t.gpuAverage != nil {
                    DetailRow("GPU 平均", MonitorFormat.temperature(t.gpuAverage))
                    DetailRow("GPU 最高", MonitorFormat.temperature(t.gpuMax))
                }
                DetailRow("传感器", "\(t.source.rawValue) · \(t.cpuSensorCount + t.gpuSensorCount) 个")
            } else {
                PendingRow(unavailable: model.isUnavailable(.temperature))
            }
        }
    }

    private var diskCard: some View {
        let d = s.disk
        return MetricCard(title: "磁盘", symbol: "internaldrive",
                          value: d.map { "\(MonitorFormat.rate($0.readRate + $0.writeRate))" } ?? MonitorFormat.placeholder) {
            SparklineView(values: model.history(.diskRead), secondary: model.history(.diskWrite),
                          scale: .zeroBased(floor: 1024 * 1024), color: .teal, secondaryColor: .pink)
            if let d {
                DetailRow("读取", MonitorFormat.rate(d.readRate), dot: .teal)
                DetailRow("写入", MonitorFormat.rate(d.writeRate), dot: .pink)
                if let used = d.usedFraction, let total = d.capacityTotal, let avail = d.capacityAvailable {
                    ProgressView(value: used)
                        .progressViewStyle(.linear)
                        .tint(used >= 0.9 ? .orange : .accentColor)
                    DetailRow("已用", "\(MonitorFormat.bytes(total - avail)) / \(MonitorFormat.bytes(total))")
                }
            } else {
                PendingRow()
            }
        }
    }

    private var powerCard: some View {
        let p = s.power
        return MetricCard(title: "功率", symbol: "bolt", value: MonitorFormat.power(p?.systemWatts)) {
            SparklineView(values: model.history(.power), scale: .zeroBased(floor: 10), color: .yellow)
            if let p {
                if let key = p.sourceKey {
                    DetailRow("整机功耗", "\(MonitorFormat.power(p.systemWatts))（\(key)）")
                }
                if let b = p.battery {
                    DetailRow("电池", "\(MonitorFormat.percent(b.level))" + batteryState(b))
                    if let w = b.batteryWatts, abs(w) >= 0.05 {
                        DetailRow(w >= 0 ? "充电功率" : "放电功率", MonitorFormat.power(w))
                    }
                    if let a = b.adapterWatts, b.onAC {
                        DetailRow("电源适配器", String(format: "%.0f W", a))
                    }
                    if let m = b.minutesRemaining {
                        DetailRow(b.isCharging ? "充满还需" : "剩余时间", MonitorFormat.minutes(m))
                    }
                }
            } else {
                PendingRow(unavailable: model.isUnavailable(.power))
            }
        }
    }

    private var networkCard: some View {
        let n = s.network
        let scope = n?.selectionLabel ?? (store.value.networkInterface.isEmpty ? "全部接口" : store.value.networkInterface)
        return MetricCard(title: "网络", subtitle: scope, symbol: "network",
                          value: n.map { "↑ \(MonitorFormat.rate($0.up))   ↓ \(MonitorFormat.rate($0.down))" }
                            ?? MonitorFormat.placeholder) {
            SparklineView(values: model.history(.networkDown), secondary: model.history(.networkUp),
                          scale: .zeroBased(floor: 10 * 1024), color: .blue, secondaryColor: .orange)
            if let n {
                if n.interfaces.isEmpty {
                    Text("没有已连接的网络接口").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(n.interfaces) { iface in
                    HStack(spacing: 6) {
                        Text(iface.label)
                        Text(iface.bsdName).foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        Text("↑ \(MonitorFormat.rate(iface.up))").foregroundStyle(.orange)
                            .frame(minWidth: 84, alignment: .trailing)
                        Text("↓ \(MonitorFormat.rate(iface.down))").foregroundStyle(.blue)
                            .frame(minWidth: 84, alignment: .trailing)
                    }
                    .font(.caption.monospacedDigit())
                }
            } else {
                PendingRow()
            }
        }
    }

    private var processesCard: some View {
        MetricCard(title: "CPU 占用最高的进程", symbol: "list.number", value: nil) {
            if model.processes.isEmpty {
                PendingRow()
            } else {
                ForEach(model.processes) { p in
                    HStack {
                        Text(p.name).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: String(p.pid)).foregroundStyle(.tertiary)
                        Spacer()
                        Text(String(format: "%.1f%%", p.cpuPercent)).monospacedDigit()
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: Helpers

    private func batteryState(_ b: BatteryReading) -> String {
        if b.isCharging { return "（充电中）" }
        if b.onAC { return "（已接电源）" }
        return "（使用电池）"
    }

    private func levelColor(_ level: AlertLevel) -> Color? {
        guard store.value.colorWarning else { return nil }
        switch level {
        case .normal: return nil
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func pressureColor(_ p: MemoryPressure) -> Color? {
        switch p {
        case .warning: return .orange
        case .critical: return .red
        default: return nil
        }
    }
}

/// A rounded card with title, headline value and arbitrary content.
private struct MetricCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String
    let value: String?
    var valueColor: Color? = nil
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, symbol: String, value: String?, valueColor: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.value = value
        self.valueColor = valueColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.subheadline.weight(.semibold))
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let value {
                    Text(value)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(valueColor ?? .primary)
                        .lineLimit(1)
                }
            }
            content
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var valueColor: Color? = nil
    var dot: Color? = nil

    init(_ label: String, _ value: String, valueColor: Color? = nil, dot: Color? = nil) {
        self.label = label
        self.value = value
        self.valueColor = valueColor
        self.dot = dot
    }

    var body: some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).monospacedDigit().foregroundStyle(valueColor ?? .primary).lineLimit(1)
        }
        .font(.caption)
    }
}

private struct PendingRow: View {
    var unavailable = false
    var body: some View {
        Text(unavailable ? "此 Mac 不提供该数据" : "正在采集…")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
