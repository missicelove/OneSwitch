import AppKit
import SwiftUI
import UserNotifications

/// One feature of the menu-bar app (防止锁屏, 菜单栏图标, 系统监控, 雷雳互联, 文件同步, 键鼠共享).
///
/// Lifecycle (all on the main actor):
/// 1. `init` — cheap; load settings, no side effects (no timers, status items, sockets, taps).
/// 2. `settingsView()` — the module's page in the Settings window. Called once, right after `init`
///    (before `start()`), and cached; the page is only put on screen while the window is open.
/// 3. `start()` — called once after launch. Apply settings, create status items, timers, listeners.
///    App start order: 系统监控, 菜单栏图标, 防止锁屏, 雷雳互联, 文件同步, 键鼠共享.
/// 4. `menuItems()` — called every time the main status menu opens; return this module's section.
/// 5. `stop()` — called once on quit (退出, logout, or SIGTERM / SIGINT / SIGHUP), in reverse start
///    order — so services using the peer link stop while it is still up. Must synchronously release
///    OS resources (power assertions, event taps, stuck keys, separator status items, open files /
///    sockets): the process exits right after.
@MainActor
public protocol FeatureModule: AnyObject {
    /// Stable identifier ("awake", "menubar", "monitor", "peerlink", "sync", "input").
    var id: String { get }
    /// Chinese display name shown in the menu section header and settings sidebar.
    var displayName: String { get }
    /// SF Symbol for the settings sidebar.
    var symbolName: String { get }

    func start()
    func stop()

    /// Items for this module's section of the main menu (the app adds the section header).
    func menuItems() -> [NSMenuItem]

    /// The module's settings page.
    func settingsView() -> AnyView

    /// When non-nil, the app's main status-bar icon uses this SF Symbol (e.g. while 防止锁屏 is active).
    /// Call `AppContext.shared.refreshStatusIcon()` whenever this changes.
    var statusIconSymbol: String? { get }
}

public extension FeatureModule {
    var statusIconSymbol: String? { nil }
}

/// App-wide services available to modules. Main-actor only.
@MainActor
public final class AppContext {
    public static let shared = AppContext()

    public var defaults: UserDefaults { AppEnvironment.defaults }
    public var dataDirectory: URL { AppEnvironment.dataDirectory }

    private var openSettingsHandler: ((String?) -> Void)?
    private var refreshStatusIconHandler: (() -> Void)?
    private var notificationsAuthorized: Bool?

    private init() {}

    /// Wired up by the app delegate.
    public func install(openSettings: @escaping (String?) -> Void, refreshStatusIcon: @escaping () -> Void) {
        openSettingsHandler = openSettings
        refreshStatusIconHandler = refreshStatusIcon
    }

    /// Opens the Settings window, optionally at a module page (by module id).
    public func openSettings(moduleID: String? = nil) {
        openSettingsHandler?(moduleID)
    }

    /// Re-evaluates the main status icon (see `FeatureModule.statusIconSymbol`).
    public func refreshStatusIcon() {
        refreshStatusIconHandler?()
    }

    /// Posts a user notification (no-op when not running from an .app bundle).
    public func notify(title: String, body: String, identifier: String = UUID().uuidString) {
        AppLog.info("notify", "\(title): \(body)")
        guard AppEnvironment.isRunningFromBundle else { return }
        let center = UNUserNotificationCenter.current()
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request) { error in
                if let error { AppLog.warning("notify", "failed: \(error.localizedDescription)") }
            }
        }
        if notificationsAuthorized == true {
            deliver()
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                AppContext.shared.notificationsAuthorized = granted
                if granted { deliver() }
            }
        }
    }
}
