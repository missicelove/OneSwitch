import AppKit
import OneSwitchCore

/// Owns the hider's status items: the toggle button, the separator left of it and the optional
/// 永久隐藏 separator further left. Knows nothing about timers — it only renders a visibility state.
///
/// 系统原生隐藏 (macOS 27+) needs only the toggle: the separators are not created at all (macOS keeps a
/// gap for a status item even at zero width), and are added only when falling back to the
/// compatibility (separator) mode.
@MainActor
final class HiderStatusItems: NSObject, NSMenuDelegate {
    enum Click {
        case primary
        /// ⌥-click: reveal the 永久隐藏区 too.
        case option
        /// Right-click / ⌃-click: context menu.
        case secondary
    }

    private(set) var toggle: NSStatusItem?
    private(set) var separator: NSStatusItem?
    private(set) var alwaysHidden: NSStatusItem?

    var onClick: ((Click) -> Void)?
    /// Called when one of our item windows moved (e.g. the user ⌘-dragged it) or changed screen.
    var onLayoutChange: (() -> Void)?

    let autosaveSuffix: String
    /// Seed "Preferred Position" defaults so new items sit next to the system items (off in self-checks,
    /// whose throw-away items must stay left-most, away from real icons).
    let seedPositions: Bool
    private var windowObservers: [NSObjectProtocol] = []
    private var measuredPadding: CGFloat?
    private var measuredToggleWidth: CGFloat?
    private var lastRendered: RenderState?

    static func toggleName(_ suffix: String) -> String { "OneSwitchHiderToggle" + suffix }
    static func separatorName(_ suffix: String) -> String { "OneSwitchHiderSeparator" + suffix }
    static func alwaysHiddenName(_ suffix: String) -> String { "OneSwitchHiderAlwaysHidden" + suffix }

    init(autosaveSuffix: String, seedPositions: Bool = true) {
        self.autosaveSuffix = autosaveSuffix
        self.seedPositions = seedPositions
        super.init()
    }

    var isInstalled: Bool { toggle != nil }
    /// The separator exists (compatibility mode).
    var hasSeparators: Bool { separator != nil }

    private func seed(_ name: String, _ slot: Double) {
        guard seedPositions else { return }
        StatusItemPlacement.seed(autosaveName: name, distanceFromTrailingEdge: slot)
    }

    // MARK: Install / remove

    /// Creates the items. New status items appear LEFT of existing ones, so the toggle is created first,
    /// then the separator (left of it), then the 永久隐藏 separator (left of both).
    /// - Parameter separators: false for 系统原生隐藏 (toggle only).
    func install(separators: Bool = true, alwaysHiddenEnabled: Bool) {
        guard toggle == nil else { return }
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        seed(Self.toggleName(autosaveSuffix), StatusItemPlacement.Slot.hiderToggle)
        toggle.autosaveName = Self.toggleName(autosaveSuffix)
        toggle.behavior = [] // cannot be ⌘-dragged off the bar
        if let button = toggle.button {
            button.target = self
            button.action = #selector(toggleClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.toggle = toggle
        if separators {
            installSeparator()
            if alwaysHiddenEnabled { installAlwaysHidden() }
        }
        updateToggleToolTip()
        lastRendered = nil
        observeWindows()
        AppLog.info("menubar", separators ? "status items installed (always-hidden: \(alwaysHiddenEnabled))"
                                          : "toggle installed (native hiding, no separators)")
    }

    /// Adds / removes the separators while installed (switching between native and compatibility mode).
    func setSeparatorsInstalled(_ installed: Bool, alwaysHiddenEnabled: Bool) {
        guard isInstalled else { return }
        if installed {
            if separator == nil { installSeparator() }
            if alwaysHiddenEnabled && alwaysHidden == nil { installAlwaysHidden() }
        } else {
            for item in [alwaysHidden, separator].compactMap({ $0 }) {
                item.length = SeparatorMetrics.expandedLength
                Self.remove(item)
            }
            alwaysHidden = nil
            separator = nil
        }
        updateToggleToolTip()
        lastRendered = nil
        observeWindows()
    }

    private func installSeparator() {
        let separator = NSStatusBar.system.statusItem(withLength: SeparatorMetrics.expandedLength)
        seed(Self.separatorName(autosaveSuffix), StatusItemPlacement.Slot.hiderSeparator)
        separator.autosaveName = Self.separatorName(autosaveSuffix)
        separator.behavior = []
        separator.button?.toolTip = "分隔线：按住 ⌘ 将要隐藏的图标拖到此线左侧"
        separator.button?.imagePosition = .imageOnly
        self.separator = separator
    }

    private func updateToggleToolTip() {
        toggle?.button?.toolTip = separator == nil
            ? "点击显示或隐藏菜单栏图标\n按住 ⌥ 点击：显示全部图标（放不下的进入系统“«”）\n右键点击：打开菜单"
            : "点击显示或隐藏菜单栏图标\n按住 ⌥ 点击：同时显示永久隐藏的图标\n右键点击：打开菜单"
    }

    func setAlwaysHiddenEnabled(_ enabled: Bool) {
        guard isInstalled, separator != nil else { return }
        if enabled {
            guard alwaysHidden == nil else { return }
            installAlwaysHidden()
            lastRendered = nil
            observeWindows()
        } else if let item = alwaysHidden {
            alwaysHidden = nil
            item.length = SeparatorMetrics.expandedLength
            Self.remove(item)
            lastRendered = nil
            observeWindows()
        }
    }

    private func installAlwaysHidden() {
        let item = NSStatusBar.system.statusItem(withLength: SeparatorMetrics.expandedLength)
        seed(Self.alwaysHiddenName(autosaveSuffix), StatusItemPlacement.Slot.hiderAlwaysHidden)
        item.autosaveName = Self.alwaysHiddenName(autosaveSuffix)
        item.behavior = []
        item.button?.toolTip = "永久隐藏分隔线：此线左侧的图标只有按住 ⌥ 点击切换按钮时才会显示"
        item.button?.imagePosition = .imageOnly
        alwaysHidden = item
    }

    /// Restores normal lengths and removes every item (keeping their saved positions).
    func uninstall() {
        removeWindowObservers()
        for item in [alwaysHidden, separator, toggle].compactMap({ $0 }) {
            item.length = item === toggle ? NSStatusItem.variableLength : SeparatorMetrics.expandedLength
            Self.remove(item)
        }
        alwaysHidden = nil
        separator = nil
        toggle = nil
        lastRendered = nil
        AppLog.info("menubar", "status items removed")
    }

    /// Removing a status item can delete its saved position ("NSStatusItem Preferred Position <name>").
    /// Cache the position / visibility defaults and put them back so the arrangement survives.
    /// ("NSStatusItem VisibleCC <name>" is the visibility key macOS 27 writes.)
    static func remove(_ item: NSStatusItem) {
        let defaults = UserDefaults.standard
        let name = item.autosaveName ?? ""
        let keys = name.isEmpty ? [] : ["NSStatusItem Preferred Position \(name)", "NSStatusItem Visible \(name)",
                                        "NSStatusItem VisibleCC \(name)"]
        let saved = keys.map { defaults.object(forKey: $0) }
        NSStatusBar.system.removeStatusItem(item)
        for (key, value) in zip(keys, saved) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    // MARK: Rendering

    struct RenderState: Equatable {
        var visibility: RevealStateMachine.Visibility
        var order: SeparatorOrder
        var warning: Bool
        var settings: MenuBarHiderSettings
        var collapsedLength: CGFloat
        /// macOS 27: extra toggle width while collapsed (see `OverflowPlanner`).
        var toggleExtra: CGFloat = 0
    }

    func render(_ state: RenderState) {
        guard let toggle else { return }
        guard state != lastRendered else { return }
        guard let separator else {
            // 系统原生隐藏: only the toggle — "<" while collapsed, ">" while shown.
            lastRendered = state
            if toggle.length != NSStatusItem.variableLength { toggle.length = NSStatusItem.variableLength }
            toggle.button?.image = HiderImages.toggle(style: state.settings.toggleStyle,
                                                      expanded: state.visibility.isExpanded, warning: state.warning)
            toggle.button?.setAccessibilityLabel(state.visibility.isExpanded ? "隐藏菜单栏图标" : "显示隐藏的菜单栏图标")
            return
        }
        lastRendered = state
        let collapsed = state.visibility == .collapsed && state.order.allowsCollapse
        let ahWide = state.visibility == .expanded && state.order.allowsAlwaysHidden && alwaysHidden != nil

        if collapsed && state.toggleExtra > 0, let natural = naturalToggleWindowWidth() {
            // Widened toggle: same icon, drawn at the right edge so it stays in place.
            let content = max(natural - windowPadding(), 8) + state.toggleExtra
            toggle.length = content
            toggle.button?.image = HiderImages.wideToggle(style: state.settings.toggleStyle, warning: state.warning, width: content)
        } else {
            if toggle.length != NSStatusItem.variableLength { toggle.length = NSStatusItem.variableLength }
            toggle.button?.image = HiderImages.toggle(style: state.settings.toggleStyle,
                                                      expanded: state.visibility.isExpanded,
                                                      warning: state.warning)
        }
        toggle.button?.setAccessibilityLabel(state.visibility.isExpanded ? "隐藏菜单栏图标" : "显示隐藏的菜单栏图标")

        let sepLength = collapsed ? state.collapsedLength : SeparatorMetrics.expandedLength
        if separator.length != sepLength { separator.length = sepLength }
        let hideSeparatorImage = collapsed && state.settings.hideSeparatorWhenCollapsed
        separator.button?.image = hideSeparatorImage ? nil : HiderImages.separator(style: state.settings.separatorStyle, alwaysHidden: false)

        if let alwaysHidden {
            let ahLength = ahWide ? state.collapsedLength : SeparatorMetrics.expandedLength
            if alwaysHidden.length != ahLength { alwaysHidden.length = ahLength }
            let hideImage = (ahWide || collapsed) && state.settings.hideSeparatorWhenCollapsed
            alwaysHidden.button?.image = hideImage ? nil : HiderImages.separator(style: state.settings.separatorStyle, alwaysHidden: true)
        }
    }

    // MARK: Geometry

    /// Window frames (AppKit coordinates) of our items; nil when not laid out.
    func frames() -> (toggle: CGRect?, separator: CGRect?, alwaysHidden: CGRect?) {
        (Self.frame(of: toggle), Self.frame(of: separator), Self.frame(of: alwaysHidden))
    }

    /// The item's window frame, or nil while it is not (yet) laid out in a menu bar.
    static func frame(of item: NSStatusItem?) -> CGRect? {
        guard let window = item?.button?.window else { return nil }
        let f = window.frame
        guard MenuBarGeometry.isPlausibleStatusItemFrame(f, screens: ScreenGeometry.current()) else { return nil }
        return f
    }

    var order: SeparatorOrder {
        let f = frames()
        return SeparatorOrder.check(toggle: f.toggle, separator: f.separator, alwaysHidden: f.alwaysHidden,
                                    alwaysHiddenExpected: alwaysHidden != nil)
    }

    /// Screen that shows our items (falls back to the main screen).
    var screen: NSScreen? {
        toggle?.button?.window?.screen ?? separator?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The toggle's window width at its natural (variable) length, measured whenever it has that length.
    func naturalToggleWindowWidth() -> CGFloat? {
        if let toggle, toggle.length == NSStatusItem.variableLength, let f = Self.frame(of: toggle), f.width < 80 {
            measuredToggleWidth = f.width
        }
        return measuredToggleWidth
    }

    /// Padding the system adds around a status item's content (window width − length), measured while
    /// the separator has its small expanded length.
    func windowPadding() -> CGFloat {
        if let separator, separator.length == SeparatorMetrics.expandedLength, let f = Self.frame(of: separator) {
            let padding = f.width - separator.length
            if padding >= 0 && padding <= 64 { measuredPadding = padding }
        }
        return measuredPadding ?? SeparatorMetrics.defaultWindowPadding
    }

    // MARK: Clicks & menu

    @objc private func toggleClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let flags = event?.modifierFlags ?? []
        if event?.type == .rightMouseUp || flags.contains(.control) {
            onClick?(.secondary)
        } else if flags.contains(.option) {
            onClick?(.option)
        } else {
            onClick?(.primary)
        }
    }

    /// Shows `menu` under the toggle (classic "assign menu + performClick" so it is positioned like a
    /// normal status-item menu).
    func showMenu(_ menu: NSMenu) {
        guard let toggle, let button = toggle.button else { return }
        menu.delegate = self
        toggle.menu = menu
        button.performClick(nil)
    }

    nonisolated func menuDidClose(_ menu: NSMenu) {
        MainActor.assumeIsolated {
            // Detach so the next left-click reaches the action again.
            if toggle?.menu === menu { toggle?.menu = nil }
        }
    }

    // MARK: Window observation

    private func observeWindows() {
        removeWindowObservers()
        let center = NotificationCenter.default
        let windows = [toggle, separator, alwaysHidden].compactMap { $0?.button?.window }
        for window in windows {
            for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
                windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onLayoutChange?() }
                })
            }
        }
    }

    private func removeWindowObservers() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
    }
}
