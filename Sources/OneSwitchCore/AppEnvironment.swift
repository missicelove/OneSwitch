import Foundation
import IOKit.ps
import SystemConfiguration

/// Process-wide, thread-safe environment values. Safe to use from any thread.
///
/// A *profile* lets several isolated instances run on one Mac (e.g. to exercise sync / peer-link
/// over loopback). Set it with the env var `ONESWITCH_PROFILE=B` or the argument `--profile B`.
/// Each profile gets its own UserDefaults suite, data directory and log file.
public enum AppEnvironment {
    public static let bundleIdentifier = "com.oneswitch.app"
    public static let appName = "OneSwitch"

    public static let profile: String? = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--profile"), i + 1 < args.count {
            let p = sanitize(args[i + 1])
            if !p.isEmpty { return p }
        }
        if let p = ProcessInfo.processInfo.environment["ONESWITCH_PROFILE"] {
            let s = sanitize(p)
            if !s.isEmpty { return s }
        }
        return nil
    }()

    /// Suffix appended to per-profile resource names ("" for the default profile, "-B" for profile B).
    public static var profileSuffix: String { profile.map { "-\($0)" } ?? "" }

    /// UserDefaults for app settings (standard domain for the default profile, a separate suite otherwise).
    public static let defaults: UserDefaults = {
        if let profile {
            return UserDefaults(suiteName: "\(bundleIdentifier).\(profile)") ?? .standard
        }
        return .standard
    }()

    /// ~/Library/Application Support/OneSwitch[-profile]/ (created on first access).
    public static let dataDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent(appName + profileSuffix, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// ~/Library/Logs/OneSwitch/ (created on first access).
    public static let logDirectory: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/\(appName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// True when running from a real `.app` bundle (vs. `swift run` / a check executable).
    public static var isRunningFromBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    public static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    /// Hardware model identifier, e.g. "Mac16,9" (Mac Studio) or "Mac15,7" (MacBook Pro).
    public static let hardwareModel: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }()

    /// The computer name (系统设置 → 通用 → 共享). Unlike `Host.current().localizedName` it never blocks
    /// on DNS, so it is safe on the main thread.
    public static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return "Mac"
    }

    /// True on MacBooks (detected via an internal battery power source).
    public static let isLaptop: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for source in list {
            if let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType {
                return true
            }
        }
        return false
    }()

    private static func sanitize(_ s: String) -> String {
        String(s.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(32))
    }
}
