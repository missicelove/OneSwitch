import Foundation
import ServiceManagement

/// 开机自启 via SMAppService (requires running from an .app bundle).
@MainActor
public enum LaunchAtLogin {
    public static var isSupported: Bool { AppEnvironment.isRunningFromBundle && AppEnvironment.profile == nil }

    public static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Registered, but the user has to allow it in 系统设置 → 通用 → 登录项.
    public static var requiresApproval: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .requiresApproval
    }

    /// Opens 系统设置 → 通用 → 登录项与扩展.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Human-readable status (e.g. requires approval in System Settings).
    public static var statusDescription: String {
        guard isSupported else { return "仅在以 .app 方式运行时可用" }
        switch SMAppService.mainApp.status {
        case .enabled: return "已开启"
        case .notRegistered: return "未开启"
        case .requiresApproval: return "需要在“系统设置 → 通用 → 登录项”中允许"
        case .notFound: return "未找到应用（请将 OneSwitch 放入“应用程序”文件夹）"
        @unknown default: return "未知状态"
        }
    }

    public static func setEnabled(_ enabled: Bool) {
        guard isSupported else { return }
        do {
            let service = SMAppService.mainApp
            if enabled {
                // Already waiting for approval: registering again would only fail; the user has to allow
                // it in System Settings (see `openSystemSettings()`).
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            } else {
                // Also withdraw a registration that is still waiting for approval.
                if service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
            }
            AppLog.info("app", "launch at login -> \(enabled) (status: \(service.status.rawValue))")
        } catch {
            AppLog.error("app", "launch at login change failed: \(error.localizedDescription)")
        }
    }
}
