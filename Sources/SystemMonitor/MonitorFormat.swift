import Foundation

/// Text formatting for the monitor (menu bar = compact, menu / popover = full).
public enum MonitorFormat {
    /// U+2007 FIGURE SPACE: exactly one digit wide in fonts with monospaced digits.
    public static let figureSpace = "\u{2007}"
    public static let placeholder = "--"

    // MARK: Compact (menu bar)

    /// "23%", " 9%" (figure-space padded to two digits), "100%", "--".
    public static func compactPercent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return placeholder }
        let v = Int((min(1, max(0, fraction)) * 100).rounded())
        return pad2(v) + "%"
    }

    /// At most four characters: "812B", "9.9K", "34K", "1.2M", "999M", "1.0G". Base 1024.
    public static func compactRate(_ bytesPerSecond: Double) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var v = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        var i = 0
        // Switch unit before three digits would round up to four ("999.6" → "1000").
        while v >= 999.5 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i > 0 && v < 9.95 { return String(format: "%.1f%@", v, units[i]) }
        return String(format: "%.0f%@", min(v, 999), units[i])
    }

    /// Bytes in the same at-most-four-character form as `compactRate` ("20G", "9.8G", "512M").
    public static func compactBytes(_ bytes: UInt64?) -> String {
        guard let bytes else { return placeholder }
        return compactRate(Double(bytes))
    }

    /// "52°", " 9°", "105°", "--".
    public static func compactTemperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return placeholder }
        return pad2(Int(min(199, max(0, celsius)).rounded())) + "°"
    }

    /// "38W", " 5W", "250W", "--".
    public static func compactPower(_ watts: Double?) -> String {
        guard let watts, watts.isFinite else { return placeholder }
        return pad2(Int(min(999, max(0, watts)).rounded())) + "W"
    }

    private static func pad2(_ v: Int) -> String {
        v < 10 ? figureSpace + String(v) : String(v)
    }

    // MARK: Full (menu, popover, settings)

    public static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return placeholder }
        return "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    /// "812 B", "34 KB", "1.2 MB", "128 GB" (base 1024; one decimal below 10).
    public static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = value.isFinite ? max(0, value) : 0
        var i = 0
        while v >= 999.5 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return "\(Int(v.rounded())) B" }
        if v < 9.95 { return String(format: "%.1f %@", v, units[i]) }
        return String(format: "%.0f %@", v, units[i])
    }

    /// Like `bytes`, but GB / TB keep one decimal up to 99.9 ("20.3 GB", "9.0 GB", "127 GB", "512 MB"):
    /// GPU memory grows by fractions of a GB while a model generates.
    public static func preciseBytes(_ value: UInt64) -> String {
        let gb = 1_073_741_824.0
        var v = Double(value)
        guard v >= 999.5 * 1_048_576 else { return bytes(v) }
        let units = ["GB", "TB", "PB"]
        var i = 0
        v /= gb
        while v >= 999.5 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        return v < 99.95 ? String(format: "%.1f %@", v, units[i]) : String(format: "%.0f %@", v, units[i])
    }

    public static func bytes(_ value: UInt64) -> String { bytes(Double(value)) }
    public static func bytes(_ value: Int64) -> String { bytes(Double(value)) }

    /// "1.2 MB/s", "34 KB/s", "0 B/s".
    public static func rate(_ bytesPerSecond: Double) -> String { bytes(bytesPerSecond) + "/s" }

    /// "48°C", "--".
    public static func temperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return placeholder }
        return "\(Int(celsius.rounded()))°C"
    }

    /// "38 W", "5.2 W" (one decimal below 10 W), "--".
    public static func power(_ watts: Double?) -> String {
        guard let watts, watts.isFinite else { return placeholder }
        let w = abs(watts)
        return w < 9.95 ? String(format: "%.1f W", w) : String(format: "%.0f W", w)
    }

    /// Minutes → "2小时5分", "45分钟".
    public static func minutes(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)分钟" }
        return m == 0 ? "\(h)小时" : "\(h)小时\(m)分"
    }
}

/// Load level used for the optional colour warning.
public enum AlertLevel: Int, Comparable, Sendable {
    case normal = 0, warning = 1, critical = 2
    public static func < (a: AlertLevel, b: AlertLevel) -> Bool { a.rawValue < b.rawValue }

    /// CPU / 内存: ≥ 85 % orange, ≥ 95 % red.
    public static func forLoad(_ fraction: Double?) -> AlertLevel {
        guard let f = fraction else { return .normal }
        if f >= 0.95 { return .critical }
        if f >= 0.85 { return .warning }
        return .normal
    }

    /// 温度: ≥ 90 °C orange, ≥ 100 °C red.
    public static func forTemperature(_ celsius: Double?) -> AlertLevel {
        guard let c = celsius else { return .normal }
        if c >= 100 { return .critical }
        if c >= 90 { return .warning }
        return .normal
    }

    public static func forMemory(_ reading: MemoryReading?) -> AlertLevel {
        guard let reading else { return .normal }
        let byPressure: AlertLevel
        switch reading.pressure {
        case .critical: byPressure = .critical
        case .warning: byPressure = .warning
        default: byPressure = .normal
        }
        return max(byPressure, forLoad(reading.fraction))
    }
}

/// One-line summaries for the module's section of the main menu.
public enum MonitorSummary {
    public static func lines(snapshot s: MonitorSnapshot, settings: MonitorSettings) -> [String] {
        let enabled = settings.enabledMetrics
        var lines: [String] = []
        var load: [String] = []
        if enabled.contains(.cpu) { load.append("CPU \(MonitorFormat.percent(s.cpu?.total))") }
        if enabled.contains(.gpu) { load.append(gpu(s.gpu)) }
        if enabled.contains(.memory) { load.append("内存 \(MonitorFormat.percent(s.memory?.fraction))") }
        if !load.isEmpty { lines.append(load.joined(separator: " · ")) }
        if enabled.contains(.network) { lines.append(network(s.network, settings: settings)) }
        if enabled.contains(.disk) { lines.append(disk(s.disk)) }
        if enabled.contains(.power) { lines.append(power(s.power)) }
        if enabled.contains(.temperature) { lines.append(temperature(s.temperature)) }
        return lines
    }

    /// "GPU 99% · 显存 20.3 GB", "GPU --" while not sampled yet.
    static func gpu(_ g: GPUReading?) -> String {
        "GPU " + GPUDetail.value(g)
    }

    static func network(_ n: NetworkReading?, settings: MonitorSettings) -> String {
        let scope = settings.networkInterface.isEmpty ? "" : "（\(n?.selectionLabel ?? settings.networkInterface)）"
        guard let n else { return "网络\(scope) ↑\(MonitorFormat.placeholder) ↓\(MonitorFormat.placeholder)" }
        return "网络\(scope) ↑\(MonitorFormat.rate(n.up)) ↓\(MonitorFormat.rate(n.down))"
    }

    static func disk(_ d: DiskReading?) -> String {
        guard let d else { return "磁盘 \(MonitorFormat.placeholder)" }
        var s = "磁盘 读 \(MonitorFormat.rate(d.readRate)) · 写 \(MonitorFormat.rate(d.writeRate))"
        if let used = d.usedFraction { s += " · 已用 \(MonitorFormat.percent(used))" }
        return s
    }

    static func power(_ p: PowerReading?) -> String {
        var parts = ["功率 \(MonitorFormat.power(p?.systemWatts))"]
        if let b = p?.battery {
            var battery = "电池 \(MonitorFormat.percent(b.level))"
            if b.isCharging { battery += "（充电中）" } else if b.onAC { battery += "（已接电源）" }
            parts.append(battery)
        }
        return parts.joined(separator: " · ")
    }

    static func temperature(_ t: TemperatureReading?) -> String {
        guard let t else { return "温度 \(MonitorFormat.placeholder)" }
        var parts: [String] = []
        if t.cpuAverage != nil { parts.append("CPU \(MonitorFormat.temperature(t.cpuAverage))") }
        if t.gpuAverage != nil { parts.append("GPU \(MonitorFormat.temperature(t.gpuAverage))") }
        return "温度 " + (parts.isEmpty ? MonitorFormat.placeholder : parts.joined(separator: " · "))
    }
}

/// A label / value row of the detail popover.
public struct DetailLine: Equatable, Sendable {
    public var label: String
    public var value: String
    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Texts of the GPU in the popover, the menu summary and the settings page (pure, for checks).
public enum GPUDetail {
    /// Rows of the GPU card's top-process list.
    public static let processRowLimit = 3

    /// "99% · 显存 20.3 GB", "99%" (no memory figure), "--" (not sampled yet).
    public static func value(_ g: GPUReading?) -> String {
        guard let g else { return MonitorFormat.placeholder }
        var text = MonitorFormat.percent(g.utilization)
        if let used = g.memoryInUse { text += " · 显存 \(MonitorFormat.preciseBytes(used))" }
        return text
    }

    /// Detail rows under the GPU card's sparkline.
    public static func rows(_ g: GPUReading) -> [DetailLine] {
        var rows: [DetailLine] = []
        if let used = g.memoryInUse { rows.append(DetailLine("显存（使用中）", MonitorFormat.preciseBytes(used))) }
        if let allocated = g.memoryAllocated { rows.append(DetailLine("显存（已分配）", MonitorFormat.preciseBytes(allocated))) }
        return rows
    }

    /// The busiest GPU processes: app name and share of GPU time.
    public static func processRows(_ processes: [GPUProcessUsage]) -> [DetailLine] {
        processes.prefix(processRowLimit).map { DetailLine($0.name, MonitorFormat.percent($0.fraction)) }
    }
}
