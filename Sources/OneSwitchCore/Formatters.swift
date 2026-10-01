import Foundation

/// Compact formatters for menu-bar and settings text (Chinese UI).
public enum Fmt {
    /// "812 B", "1.2 KB", "34 MB", "1.07 GB" (base 1024).
    public static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var v = max(0, value)
        var i = 0
        while v >= 1024 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return "\(Int(v)) B" }
        if v >= 100 { return String(format: "%.0f %@", v, units[i]) }
        if v >= 10 { return String(format: "%.1f %@", v, units[i]) }
        return String(format: "%.2f %@", v, units[i])
    }

    public static func bytes(_ value: Int64) -> String { bytes(Double(value)) }
    public static func bytes(_ value: UInt64) -> String { bytes(Double(value)) }

    /// Transfer rate. Full: "12.3 MB/s". Compact (menu bar, ≤5 chars): "12M", "980K", "1.2G".
    public static func rate(_ bytesPerSecond: Double, compact: Bool = false) -> String {
        if !compact { return bytes(bytesPerSecond) + "/s" }
        let units = ["B", "K", "M", "G", "T"]
        var v = max(0, bytesPerSecond)
        var i = 0
        while v >= 1000 && i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if v < 10 && i > 0 { return String(format: "%.1f%@", v, units[i]) }
        return String(format: "%.0f%@", v, units[i])
    }

    /// Chinese duration: "45秒", "4分32秒", "1小时5分", "12小时".
    public static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return m > 0 ? "\(h)小时\(m)分" : "\(h)小时" }
        if m > 0 { return sec > 0 ? "\(m)分\(sec)秒" : "\(m)分钟" }
        return "\(sec)秒"
    }

    /// Clock style countdown: "4:05", "1:02:09".
    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// Duration given in minutes: "5分钟", "1小时30分钟", "12小时".
    public static func minutes(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)分钟" }
        return m == 0 ? "\(h)小时" : "\(h)小时\(m)分钟"
    }

    /// Minutes since midnight → "08:00".
    public static func timeOfDay(_ minutesSinceMidnight: Int) -> String {
        let m = ((minutesSinceMidnight % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }

    /// Fraction 0...1 → "37%".
    public static func percent(_ fraction: Double, decimals: Int = 0) -> String {
        let v = (fraction.isFinite ? fraction : 0) * 100
        return String(format: "%.\(decimals)f%%", v)
    }
}
