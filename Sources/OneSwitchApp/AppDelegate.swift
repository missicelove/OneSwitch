import AppKit
import UserNotifications
import OneSwitchCore
import Awake
import MenuBarHider
import SystemMonitor
import PeerLink
import FolderSync
import SharedInput

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Menu / settings order.
    private var modules: [FeatureModule] = []
    /// Start order; modules stop in the reverse order (see `applicationDidFinishLaunching`).
    private var startOrder: [FeatureModule] = []
    private var statusMenu: StatusMenuController?
    private var settingsWindow: SettingsWindowController?
    private var instanceLock: InstanceLock?
    private var signalSources: [DispatchSourceSignal] = []
    private let notificationPresenter = NotificationPresenter()
    private var modulesStopped = false

    /// Posted (distributed) by a second launch of the same profile; the running instance shows Settings.
    private static let showSettingsNotification = Notification.Name(AppEnvironment.bundleIdentifier + ".showSettings")
    private static var instanceToken: String { AppEnvironment.profile ?? "default" }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Shown only while the settings window is open (OneSwitch is then a regular app). Its key
        // equivalents are also what make ⌘C / ⌘V / ⌘A / ⌘Z work in the settings window's text fields
        // (配对码, IP, ignore rules) and ⌘W close it.
        NSApp.mainMenu = MainMenuBuilder.makeMainMenu()
        // Set before launch completes so a click on a notification is delivered to us. Only inside a
        // bundle: UNUserNotificationCenter raises for a bare executable (`swift run`).
        if AppEnvironment.isRunningFromBundle {
            UNUserNotificationCenter.current().delegate = notificationPresenter
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.debugEnabled = AppEnvironment.defaults.bool(forKey: GeneralSettings.verboseLoggingKey)
        AppLog.info("app", "OneSwitch \(AppEnvironment.appVersion) starting (pid \(getpid()), profile: \(AppEnvironment.profile ?? "default"), model: \(AppEnvironment.hardwareModel), bundle: \(Bundle.main.bundlePath))")

        guard let lock = InstanceLock.acquire() else {
            handleSecondInstance()
            return
        }
        instanceLock = lock
        installSignalHandlers()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showSettingsRequested(_:)), name: Self.showSettingsNotification,
            object: Self.instanceToken, suspensionBehavior: .deliverImmediately)

        // Instantiate modules (cheap, no side effects).
        let all = AppModules()
        modules = all.menuOrder

        // The main status item is created first so that it sits right-most among our items.
        let menu = StatusMenuController(modules: modules, iconPriority: all.iconPriority)
        statusMenu = menu
        let settings = SettingsWindowController(modules: modules)
        settingsWindow = settings
        MainMenuBuilder.installViewMenu(panes: settings.panes, in: NSApp.mainMenu)

        AppContext.shared.install(
            openSettings: { [weak settings] moduleID in settings?.show(moduleID: moduleID) },
            refreshStatusIcon: { [weak menu] in menu?.refreshIcon() }
        )

        // Start order matters for status-item placement: new status items appear to the LEFT of existing
        // ones, so the monitor's items must exist before the hider creates its toggle and separator(s)
        // (everything right of the toggle — monitor items and the main item — can never be hidden).
        // The peer link starts before the features that register services on it. Stopping runs in the
        // reverse order: 键鼠共享 / 文件同步 stop while the link is still up (so the other Mac is told to
        // release held keys), and the hider restores its separators before the monitor items go away.
        startOrder = all.startOrder
        assert(Set(startOrder.map(\.id)) == Set(modules.map(\.id)), "every module must be started and stopped")
        for module in startOrder {
            AppLog.info("app", "starting module \(module.id)")
            module.start()
        }
        menu.refreshIcon()

        let defaults = AppEnvironment.defaults
        if !defaults.bool(forKey: GeneralSettings.didCompleteFirstLaunchKey) {
            defaults.set(true, forKey: GeneralSettings.didCompleteFirstLaunchKey)
            AppLog.info("app", "first launch: enabling launch at login and opening Settings")
            LaunchAtLogin.setEnabled(true)
            settings.show(moduleID: nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopModules()
        instanceLock?.release()
        instanceLock = nil
        AppLog.info("app", "terminated")
        AppLog.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Double-clicking OneSwitch in Finder / Launchpad while it runs opens Settings.
        settingsWindow?.show(moduleID: nil)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Closing the settings window (the only window) never quits: OneSwitch lives in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Main menu actions (the menu bar is visible only while the settings window is open)

    /// 设置… (⌘,) from the main menu.
    @objc func showSettings(_ sender: Any?) {
        settingsWindow?.show(moduleID: nil)
    }

    /// 显示 → a pane.
    @objc func showSettingsPane(_ sender: NSMenuItem) {
        settingsWindow?.show(moduleID: sender.representedObject as? String)
    }

    @objc func settingsGoBack(_ sender: Any?) { settingsWindow?.goBack() }
    @objc func settingsGoForward(_ sender: Any?) { settingsWindow?.goForward() }
    @objc func settingsFind(_ sender: Any?) { settingsWindow?.focusSearch() }
    @objc func hideOneSwitch(_ sender: Any?) { NSApp.hide(sender) }
    @objc func hideOtherApps(_ sender: Any?) { NSApp.hideOtherApplications(sender) }
    @objc func unhideAllApps(_ sender: Any?) { NSApp.unhideAllApplications(sender) }
    @objc func quitOneSwitch(_ sender: Any?) { NSApp.terminate(sender) }

    // MARK: - Lifecycle helpers

    /// Stops every started module exactly once, in reverse start order.
    private func stopModules() {
        guard !modulesStopped else { return }
        modulesStopped = true
        AppLog.info("app", "terminating")
        for module in startOrder.reversed() {
            AppLog.info("app", "stopping module \(module.id)")
            module.stop()
        }
    }

    /// SIGTERM (`pkill`, the install / deploy scripts, launchd at logout), SIGINT (Ctrl-C when run from a
    /// terminal) and SIGHUP quit like 退出 does, so every module's `stop()` runs (cursor restored, keys
    /// released on the other Mac, separators removed, sync index closed) instead of the process just dying.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    AppLog.info("app", "received signal \(sig); quitting")
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Another instance of this profile holds the lock: ask it to show its Settings window and quit.
    private func handleSecondInstance() {
        AppLog.warning("app", "another instance is already running for this profile (\(InstanceLock.path)); quitting")
        DistributedNotificationCenter.default().postNotificationName(
            Self.showSettingsNotification, object: Self.instanceToken, userInfo: nil, deliverImmediately: true)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppEnvironment.bundleIdentifier)
            .filter { $0.processIdentifier != getpid() }
        if others.isEmpty {
            // The holder is not a bundled app we can see (e.g. `swift run`): explain instead of vanishing.
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "OneSwitch 已在运行"
            alert.informativeText = "请在菜单栏中找到 OneSwitch 图标。"
                + (InstanceLock.holderPID().map { "（进程 \($0)）" } ?? "")
            alert.runModal()
        }
        NSApp.terminate(nil)
    }

    @objc private func showSettingsRequested(_ note: Notification) {
        AppLog.info("app", "second launch detected: showing Settings")
        settingsWindow?.show(moduleID: nil)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// App-level shortcuts (⌘Q, ⌘H, ⌘[ …) only act while the settings window makes OneSwitch a regular
    /// app. As a menu-bar agent the menu bar is invisible, and a stray ⌘Q typed while one of OneSwitch's
    /// panels has the focus must not stop file sync or keyboard sharing.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let regular = NSApp.activationPolicy() == .regular
        switch menuItem.action {
        case #selector(quitOneSwitch(_:)), #selector(hideOneSwitch(_:)),
             #selector(hideOtherApps(_:)), #selector(unhideAllApps(_:)):
            return regular
        case #selector(settingsGoBack(_:)):
            return settingsWindow?.isWindowKey == true && settingsWindow?.canGoBack == true
        case #selector(settingsGoForward(_:)):
            return settingsWindow?.isWindowKey == true && settingsWindow?.canGoForward == true
        case #selector(settingsFind(_:)):
            return settingsWindow?.isWindowKey == true
        case #selector(showSettingsPane(_:)):
            if let id = menuItem.representedObject as? String {
                menuItem.state = settingsWindow?.isWindowVisible == true && settingsWindow?.navigation.selection == id ? .on : .off
            }
            return true
        default:
            return true
        }
    }
}

/// The six feature modules, created once (cheap, no side effects) and ordered for each purpose.
@MainActor
struct AppModules {
    let awake = AwakeModule()
    let hider = MenuBarHiderModule()
    let monitor = SystemMonitorModule()
    let peerLink = PeerLinkModule()
    let sync: FolderSyncModule
    let input: SharedInputModule

    init() {
        sync = FolderSyncModule(hub: peerLink)
        input = SharedInputModule(hub: peerLink)
    }

    /// Order of the status menu sections (the settings sidebar groups them itself, see `SettingsCatalog`).
    var menuOrder: [FeatureModule] { [awake, hider, monitor, sync, input, peerLink] }

    /// Status-icon override priority: controlling the other Mac matters more than 防止锁屏 being on.
    var iconPriority: [FeatureModule] { [input, awake, sync, peerLink, monitor, hider] }

    /// See `applicationDidFinishLaunching` for why this order matters; modules stop in reverse.
    var startOrder: [FeatureModule] { [monitor, hider, awake, peerLink, sync, input] }
}

enum GeneralSettings {
    static let didCompleteFirstLaunchKey = "general.didCompleteFirstLaunch"
    static let verboseLoggingKey = "general.verboseLogging"
}

/// Prevents two instances of the same profile from running at once (flock on a file in the data dir;
/// the kernel drops the lock when the process dies, so a crash never leaves a stale lock).
final class InstanceLock {
    static var path: String { AppEnvironment.dataDirectory.appendingPathComponent(".instance.lock").path }

    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    static func acquire() -> InstanceLock? {
        // O_CLOEXEC: child processes (osascript, ps, …) must not inherit — and thereby keep — the lock.
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            AppLog.error("app", "cannot open instance lock \(path): errno \(errno)")
            return nil
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return nil
        }
        // Record the holder for diagnostics ("OneSwitch 已在运行" names it).
        let pid = Array("\(getpid())\n".utf8)
        _ = ftruncate(fd, 0)
        _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        return InstanceLock(fd: fd)
    }

    /// PID written by the current holder, if readable.
    static func holderPID() -> Int32? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func release() {
        _ = ftruncate(fd, 0)
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Shows OneSwitch's notifications (e.g. 防止锁屏已结束) as banners even while the app is frontmost —
/// without a delegate, notifications of the active app are silently dropped.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

/// The main menu. It is visible only while the settings window is open (OneSwitch is then a regular app
/// with a Dock icon); as a menu-bar agent its key equivalents still make ⌘C / ⌘V / ⌘A / ⌘Z work in text
/// fields and ⌘W close windows.
@MainActor
enum MainMenuBuilder {
    static let viewMenuTitle = "显示"

    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: "OneSwitch")
        appMenu.addItem(withTitle: "关于 OneSwitch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 OneSwitch", action: #selector(AppDelegate.hideOneSwitch(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "隐藏其他", action: #selector(AppDelegate.hideOtherApps(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(AppDelegate.unhideAllApps(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // Enabled only while the settings window is open (see AppDelegate.validateMenuItem): quitting stops
        // file sync and keyboard sharing, so ⌘Q must not fire while OneSwitch is just a menu-bar agent.
        appMenu.addItem(withTitle: "退出 OneSwitch", action: #selector(AppDelegate.quitOneSwitch(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: main)

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "查找…", action: #selector(AppDelegate.settingsFind(_:)), keyEquivalent: "f")
        addSubmenu(edit, to: main)

        let window = NSMenu(title: "窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        addSubmenu(window, to: main)
        NSApp.windowsMenu = window

        return main
    }

    /// 显示 menu, like System Settings': 返回 / 前进 and every pane. Inserted before 窗口 once the panes exist.
    static func installViewMenu(panes: [SettingsPaneItem], in main: NSMenu?) {
        guard let main, main.item(withTitle: viewMenuTitle) == nil else { return }
        let view = NSMenu(title: viewMenuTitle)
        view.addItem(withTitle: "返回", action: #selector(AppDelegate.settingsGoBack(_:)), keyEquivalent: "[")
        view.addItem(withTitle: "前进", action: #selector(AppDelegate.settingsGoForward(_:)), keyEquivalent: "]")
        view.addItem(.separator())
        for pane in panes {
            let item = NSMenuItem(title: pane.title, action: #selector(AppDelegate.showSettingsPane(_:)), keyEquivalent: "")
            item.representedObject = pane.id
            view.addItem(item)
        }
        let item = NSMenuItem(title: viewMenuTitle, action: nil, keyEquivalent: "")
        item.submenu = view
        let windowIndex = main.items.firstIndex { $0.submenu === NSApp.windowsMenu } ?? main.items.count
        main.insertItem(item, at: windowIndex)
    }

    private static func addSubmenu(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
