import AppKit
import ScreenCaptureKit
import SwiftUI
import OneSwitchCore

/// Developer tool: renders the real settings window to PNG files (docs/screenshots) —
/// `OneSwitch --render-settings <dir> [--panes general,awake,…] [--appearance light|dark] [--search 剪贴板]
/// [--scrolled awake] [--size 880x660] [--activate]`
/// (see scripts/settings-screenshots.sh).
///
/// Side-effect free by construction: the modules are only instantiated (never `start()`ed — no status items,
/// hotkeys, sockets or taps), everything runs under a throwaway profile whose defaults, data directory and
/// log are deleted afterwards, the window sits below the desktop (invisible, no Dock icon), and it is
/// captured with ScreenCaptureKit, which needs the Screen Recording permission of the calling terminal.
/// The process cannot even become active (activation policy `.prohibited`), so the user's keyboard focus is
/// never taken — the pictures therefore show the inactive-window look. `--activate` opts into the key-window
/// look and does take the focus while rendering.
@MainActor
enum SettingsSnapshot {
    static let flag = "--render-settings"
    private static let profileName = "SettingsSnapshot"

    struct Shot {
        let pane: String
        let appearance: NSAppearance.Name
        let search: String?
        /// Scrolls the page by this many points (shows the toolbar title that replaces the hero card's).
        var scroll: CGFloat? = nil
        var fileName: String {
            let mode = appearance == .darkAqua ? "dark" : "light"
            if search != nil { return "settings-search-\(mode).png" }
            if scroll != nil { return "settings-\(pane)-scrolled-\(mode).png" }
            return "settings-\(pane)-\(mode).png"
        }
    }

    struct Options {
        var outputDirectory: URL
        var panes: [String]?
        var appearances: [NSAppearance.Name] = [.aqua, .darkAqua]
        var searches: [String] = []
        /// Panes additionally rendered scrolled down (toolbar title visible).
        var scrolledPanes: [String] = []
        var size = SettingsWindowController.defaultContentSize
        /// Make the (still invisible) window key for the active look — takes the keyboard focus while rendering.
        var activate = false
    }

    /// Parses the command line; nil unless `--render-settings <dir>` is present. Touches nothing else.
    static func options(from arguments: [String]) -> Options? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        var options = Options(outputDirectory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        func value(_ name: String) -> String? {
            guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        if let panes = value("--panes") { options.panes = panes.split(separator: ",").map(String.init) }
        switch value("--appearance") {
        case "light": options.appearances = [.aqua]
        case "dark": options.appearances = [.darkAqua]
        default: break
        }
        if let search = value("--search") { options.searches = [search] }
        if let scrolled = value("--scrolled") { options.scrolledPanes = scrolled.split(separator: ",").map(String.init) }
        options.activate = arguments.contains("--activate")
        if let size = value("--size"), case let parts = size.split(separator: "x").compactMap({ Double($0) }), parts.count == 2 {
            options.size = NSSize(width: parts[0], height: parts[1])
        }
        return options
    }

    /// Renders and exits the process.
    static func run(_ options: Options) -> Never {
        // Must precede the first use of AppEnvironment: isolates defaults, data directory and log file.
        setenv("ONESWITCH_PROFILE", profileName, 1)
        let app = NSApplication.shared
        // `.prohibited`: never activates, so it cannot take the keyboard focus from the user's app.
        app.setActivationPolicy(options.activate ? .accessory : .prohibited)
        AppLog.echoToStderr = false

        // An unbundled executable has a generic icon; use the one the bundle ships (关于 row on 通用).
        if let icon = NSImage(contentsOfFile: "Resources/AppIcon.icns") { app.applicationIconImage = icon }

        let modules = AppModules()
        let controller = SettingsWindowController(modules: modules.menuOrder)
        let window = controller.makeWindow(autosaveFrame: false, showsProfile: false)
        window.setContentSize(options.size)
        // Below the desktop picture: composited (so it can be captured) but never visible to the user.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.collectionBehavior.insert([.stationary, .ignoresCycle])
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        controller.navigation.isPresented = true
        window.orderBack(nil)
        let previouslyActive = NSWorkspace.shared.frontmostApplication
        if options.activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
        }

        let paneIDs = options.panes ?? controller.panes.map(\.id)
        var shots: [Shot] = []
        for appearance in options.appearances {
            for pane in paneIDs { shots.append(Shot(pane: pane, appearance: appearance, search: nil)) }
            for pane in options.scrolledPanes { shots.append(Shot(pane: pane, appearance: appearance, search: nil, scroll: 360)) }
            for search in options.searches {
                // Show the best match, as pressing Return in the search field would.
                let match = controller.panes.first {
                    SettingsSearch.match(query: search, title: $0.title, keywords: $0.keywords, summary: $0.appearance.summary) != nil
                }
                shots.append(Shot(pane: match?.id ?? SettingsCatalog.generalID, appearance: appearance, search: search))
            }
        }

        Task { @MainActor in
            var failures = 0
            do {
                try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
            } catch {
                print("cannot create \(options.outputDirectory.path): \(error)")
                failures += 1
            }
            for shot in shots where failures == 0 {
                window.appearance = NSAppearance(named: shot.appearance)
                controller.navigation.select(shot.pane)
                controller.navigation.searchText = shot.search ?? ""
                if options.activate && !window.isKeyWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKey()
                }
                // Let SwiftUI lay out, async content load and the window server composite the frame.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let scroll = shot.scroll {
                    scrollDetail(of: window, by: scroll)
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
                do {
                    let image = try await capture(window)
                    let url = options.outputDirectory.appendingPathComponent(shot.fileName)
                    try png(image).write(to: url)
                    print("wrote \(url.path) (\(image.width)×\(image.height))")
                } catch {
                    print("capture failed for \(shot.fileName): \(error.localizedDescription)")
                    failures += 1
                }
            }
            window.orderOut(nil)
            if options.activate, let previouslyActive, !previouslyActive.isTerminated { previouslyActive.activate() }
            cleanUp()
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    /// Scrolls the detail page (the widest scroll view; the sidebar list is the narrow one).
    private static func scrollDetail(of window: NSWindow, by points: CGFloat) {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            // Outermost scroll views only (a page may nest one, e.g. the log view on 通用).
            if let scrollView = view as? NSScrollView { return [scrollView] }
            return view.subviews.flatMap(scrollViews)
        }
        guard let root = window.contentView,
              let detail = scrollViews(in: root).max(by: { $0.frame.width < $1.frame.width }) else { return }
        detail.contentView.scroll(to: NSPoint(x: 0, y: points - detail.contentInsets.top))
        detail.reflectScrolledClipView(detail.contentView)
    }

    private static func capture(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw NSError(domain: "SettingsSnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "window not found in shareable content"])
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SettingsSnapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        return data
    }

    /// Removes everything the throwaway profile created. (cfprefsd may still write an empty plist for
    /// the suite after the process exits; scripts/settings-screenshots.sh deletes it afterwards.)
    private static func cleanUp() {
        let suite = "\(AppEnvironment.bundleIdentifier).\(profileName)"
        AppEnvironment.defaults.removePersistentDomain(forName: suite)
        CFPreferencesAppSynchronize(suite as CFString)
        let fm = FileManager.default
        let prefs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences/\(suite).plist")
        try? fm.removeItem(at: prefs)
        try? fm.removeItem(at: AppEnvironment.dataDirectory)
        AppLog.flush()
        try? fm.removeItem(at: AppLog.logFileURL)
        try? fm.removeItem(at: URL(fileURLWithPath: AppLog.logFileURL.path + ".1"))
    }
}
