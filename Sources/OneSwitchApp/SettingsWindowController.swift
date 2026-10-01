import AppKit
import SwiftUI
import OneSwitchCore

/// The settings window: a System Settings–style NavigationSplitView (`SettingsSplitView`: glass sidebar with
/// search, hero card pages, ‹ | › history buttons in the unified toolbar).
///
/// While the window is open OneSwitch is a regular app — Dock icon, ⌘-Tab, its own menu bar — so the window
/// can be brought back like any other app's. Closing it returns OneSwitch to a menu-bar-only agent and hands
/// the keyboard focus back to the app the user was in most recently.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let generalID = SettingsCatalog.generalID
    private static let frameAutosaveName = "OneSwitchSettings" + AppEnvironment.profileSuffix
    nonisolated static let defaultContentSize = NSSize(width: 880, height: 660)

    /// Sidebar groups; `panes` is the same list flattened.
    let sections: [[SettingsPaneItem]]
    let panes: [SettingsPaneItem]
    let navigation = SettingsWindowNavigation(initial: SettingsCatalog.generalID)
    private(set) var window: NSWindow?
    private var dock = SettingsDockPresence<NSRunningApplication>()
    private var activationObserver: NSObjectProtocol?

    init(modules: [FeatureModule]) {
        var panes = [SettingsCatalog.pane(id: Self.generalID, title: "通用", fallbackSymbol: "gearshape",
                                          view: AnyView(GeneralSettingsView()))]
        panes += modules.map {
            SettingsCatalog.pane(id: $0.id, title: $0.displayName, fallbackSymbol: $0.symbolName, view: $0.settingsView())
        }
        sections = SettingsCatalog.grouped(panes)
        self.panes = sections.flatMap { $0 }
        super.init()
    }

    var isWindowVisible: Bool { window?.isVisible == true }
    var isWindowKey: Bool { window?.isKeyWindow == true }

    /// Shows the window (optionally at a module's page) and brings OneSwitch to the front so the
    /// window's text fields receive the keyboard.
    func show(moduleID: String?) {
        if let moduleID, panes.contains(where: { $0.id == moduleID }) {
            navigation.select(moduleID)
        }
        navigation.isPresented = true
        let window = self.window ?? makeWindow()
        self.window = window
        let frontmost = NSWorkspace.shared.frontmostApplication
        dock.windowShown(frontmost: frontmost, frontmostIsSelf: frontmost?.processIdentifier == getpid())
        trackActivations()
        becomeRegularApp()
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        // The policy switch must happen before activation, or the menu bar keeps the previous app's menus.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Even if the system declines the activation, make sure the window is visible on top.
        window.orderFrontRegardless()
        // Activation right after a policy change is occasionally ignored; retry once on the next turn.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible, !NSApp.isActive else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func goBack() { navigation.goBack() }
    func goForward() { navigation.goForward() }
    func focusSearch() { navigation.focusSearch() }
    var canGoBack: Bool { navigation.history.canGoBack }
    var canGoForward: Bool { navigation.history.canGoForward }

    /// Builds the window. `autosaveFrame` / `showsProfile` are false for the offscreen screenshot renderer.
    func makeWindow(autosaveFrame: Bool = true, showsProfile: Bool = true) -> NSWindow {
        let subtitle = showsProfile ? AppEnvironment.profile.map { "配置档 \($0)" } : nil
        let root = SettingsSplitView(sections: sections, navigation: navigation, subtitle: subtitle)
        let hosting = NSHostingController(rootView: root)
        // SwiftUI only dictates the minimum size; the user sizes the window (and it is remembered).
        // The default options would also pin the window to the content's ideal size, making it jump
        // whenever another page is selected.
        hosting.sizingOptions = [.minSize]
        // Let SwiftUI own the window toolbar (‹ › buttons, search field, glass sidebar) and title.
        hosting.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: hosting)
        window.title = "OneSwitch 设置" + (AppEnvironment.profile.map { "（\($0)）" } ?? "")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(Self.defaultContentSize)
        window.isReleasedWhenClosed = false
        // The window is rebuilt by code on demand; AppKit state restoration must not try to reopen it.
        window.isRestorable = false
        window.tabbingMode = .disallowed
        // Open on the Space the user is on (also over a full-screen app) instead of switching Spaces.
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        window.delegate = self
        if autosaveFrame {
            // Restore the last frame; center only the very first time. (Centering on every show would
            // throw the saved position away.)
            if !window.setFrameUsingName(Self.frameAutosaveName) {
                window.center()
            }
            window.setFrameAutosaveName(Self.frameAutosaveName)
        }
        return window
    }

    // MARK: Dock icon / activation policy

    /// Dock icon, ⌘-Tab entry and the app's own menu bar while the window is open.
    private func becomeRegularApp() {
        guard NSApp.activationPolicy() != .regular else { return }
        // The Dock shows the bundle's icon (CFBundleIconFile = AppIcon). It is deliberately not set through
        // `applicationIconImage`, which would bypass the system's dark / tinted icon styles.
        NSApp.setActivationPolicy(.regular)
        AppLog.debug("app", "settings shown: activation policy regular")
    }

    /// Back to a menu-bar-only agent once the window is gone, handing the focus back to the app the user
    /// came from most recently (an agent app without windows would otherwise stay active with nowhere to type).
    private func returnToMenuBarOnly() {
        // Reopened in the meantime: stay a regular app (and keep the return target).
        guard !dock.wantsRegularApp else { return }
        stopTrackingActivations()
        // Only while no other OneSwitch window (e.g. 关于 OneSwitch) took over the keyboard.
        let hadFocus = NSApp.isActive && NSApp.keyWindow == nil
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
            AppLog.debug("app", "settings closed: activation policy accessory")
        }
        if let target = dock.takeReturnTarget(wasActive: hadFocus, isAlive: { !$0.isTerminated }) {
            target.activate()
        } else if hadFocus {
            // Nobody to return to (e.g. opened at first launch): give up the focus anyway.
            NSApp.deactivate()
        }
    }

    /// Follows app switches while the window is open, so the focus goes back to the most recent app
    /// (where ⌘-Tab would go), not to the one that was frontmost when Settings was first opened.
    private func trackActivations() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                self?.dock.noteActivated(app, isSelf: app.processIdentifier == getpid())
            }
        }
    }

    private func stopTrackingActivations() {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        navigation.isPresented = false
        navigation.searchText = ""
        dock.windowClosed()
        // After the close has completed (the window is ordered out and the key window resolved by then).
        DispatchQueue.main.async { [weak self] in self?.returnToMenuBarOnly() }
    }
}
