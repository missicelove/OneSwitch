import OneSwitchCore
import SwiftUI

/// Settings page of the 系统监控 module.
struct MonitorSettingsView: View {
    @ObservedObject var store: SettingsStore<MonitorSettings>
    @ObservedObject var model: MonitorModel
    let onVisibilityChange: (ObjectIdentifier, Bool) -> Void

    var body: some View {
        SettingsPage("系统监控", subtitle: "在菜单栏实时显示 CPU、GPU、内存、网络、磁盘、功率和温度") {
            Section {
                ForEach(MonitorMetric.allCases) { metric in
                    Toggle(isOn: enabledBinding(metric)) {
                        HStack {
                            Label(metric.title, systemImage: metric.symbolName)
                            Spacer()
                            Text(liveValue(metric))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Toggle(isOn: $store.value.combined) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("合并为一个图标")
                        Text("把选中的指标并排显示在同一个菜单栏图标中").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("菜单栏显示")
            } footer: {
                FooterText("点按菜单栏中的任一监控图标，可查看全部指标、历史曲线和占用 CPU 最多的进程。"
                           + "运行中新打开的图标会先出现在菜单栏图标区域的最左侧（macOS 的行为）；"
                           + "如果“菜单栏图标”功能正在隐藏图标，它会落在隐藏区域里，展开后可按住 ⌘ 拖移调整位置。"
                           + "下次启动 OneSwitch 时会按固定顺序排列。")
            }

            Section("外观") {
                Picker("显示样式", selection: $store.value.style) {
                    ForEach(DisplayStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("磁盘显示", selection: $store.value.diskDisplay) {
                    ForEach(DiskDisplay.allCases) { Text($0.title).tag($0) }
                }
                Picker(selection: $store.value.gpuDisplay) {
                    ForEach(GPUDisplay.allCases) { Text($0.title).tag($0) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GPU 显示")
                        Text("显存是 GPU 正在使用的统一内存；运行本地模型时，它会增加约模型加上下文的大小")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $store.value.colorWarning) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("高负载颜色提醒")
                        Text("CPU 或内存 ≥ 85%、温度 ≥ 90°C 时数值显示为橙色，更高时显示为红色")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Picker("刷新间隔", selection: $store.value.interval) {
                    ForEach(MonitorSettings.intervalChoices, id: \.self) { Text("\($0) 秒").tag($0) }
                }
            } header: {
                Text("采样")
            } footer: {
                FooterText("平时只采集菜单栏中显示的指标；打开详情面板或本页面时才会采集全部指标。"
                           + "GPU 利用率是每个刷新间隔内 GPU 的平均忙碌比例，短暂的计算（例如模型生成）也会计入。"
                           + "想在运行模型时持续查看，可在菜单栏显示 GPU，或点按详情面板右上角的图钉将其固定。")
            }

            Section {
                Picker("网络接口", selection: $store.value.networkInterface) {
                    Text("全部接口").tag("")
                    ForEach(model.knownInterfaces) { iface in
                        Text("\(iface.label)（\(iface.bsdName)）").tag(iface.bsdName)
                    }
                    let selected = store.value.networkInterface
                    if !selected.isEmpty && !model.knownInterfaces.contains(where: { $0.bsdName == selected }) {
                        Text("\(selected)（未连接）").tag(selected)
                    }
                }
            } header: {
                Text("网络")
            } footer: {
                FooterText("“全部接口”统计所有已连接的网络接口（含雷雳网桥，不重复计算网桥成员端口），不含 VPN、回环等虚拟接口。")
            }

            Section("温度与功率") {
                Picker("温度来源", selection: $store.value.temperatureSource) {
                    ForEach(TemperatureSource.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("温度传感器", value: temperatureSensorText)
                LabeledContent("功率数据", value: powerSourceText)
            }
        }
        .background(VisibilityReporter(onChange: onVisibilityChange).frame(width: 0, height: 0))
    }

    private func enabledBinding(_ metric: MonitorMetric) -> Binding<Bool> {
        Binding(
            get: { store.value.enabledMetrics.contains(metric) },
            set: { on in
                store.update { s in
                    if on { s.enabledMetrics.insert(metric) } else { s.enabledMetrics.remove(metric) }
                }
            })
    }

    private func liveValue(_ metric: MonitorMetric) -> String {
        let s = model.snapshot
        switch metric {
        case .cpu: return MonitorFormat.percent(s.cpu?.total)
        case .gpu:
            if model.isUnavailable(.gpu) { return "不可用" }
            return GPUDetail.value(s.gpu)
        case .memory:
            guard let m = s.memory else { return MonitorFormat.placeholder }
            return "\(MonitorFormat.percent(m.fraction)) · \(MonitorFormat.bytes(m.used))"
        case .network:
            guard let n = s.network else { return MonitorFormat.placeholder }
            return "↑\(MonitorFormat.rate(n.up)) ↓\(MonitorFormat.rate(n.down))"
        case .disk:
            guard let d = s.disk else { return MonitorFormat.placeholder }
            return "读 \(MonitorFormat.rate(d.readRate)) 写 \(MonitorFormat.rate(d.writeRate))"
        case .power:
            if model.isUnavailable(.power) { return "不可用" }
            return MonitorFormat.power(s.power?.systemWatts)
        case .temperature:
            if model.isUnavailable(.temperature) { return "不可用" }
            return MonitorFormat.temperature(s.temperature?.value(for: store.value.temperatureSource))
        }
    }

    private var temperatureSensorText: String {
        guard let t = model.lastTemperature else {
            return model.isUnavailable(.temperature) ? "未找到温度传感器" : "正在检测…"
        }
        var parts: [String] = []
        if t.cpuSensorCount > 0 { parts.append("CPU \(t.cpuSensorCount) 个") }
        if t.gpuSensorCount > 0 { parts.append("GPU \(t.gpuSensorCount) 个") }
        return "\(t.source.rawValue)（\(parts.joined(separator: "，"))）"
    }

    private var powerSourceText: String {
        guard let p = model.lastPower else {
            return model.isUnavailable(.power) ? "此 Mac 不提供功率数据" : "正在检测…"
        }
        var parts: [String] = []
        if let key = p.sourceKey { parts.append("SMC \(key)（整机）") }
        if p.battery != nil { parts.append("电池") }
        return parts.isEmpty ? "不可用" : parts.joined(separator: " + ")
    }
}

/// Leading-aligned caption used as a section footer.
private struct FooterText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
