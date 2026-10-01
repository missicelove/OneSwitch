import AppKit
import OneSwitchCore

/// Owns the monitor's status items: one per metric plus the combined item. All items are created once
/// in `install()` (fixed order, final visibility) and only shown / hidden afterwards — never created at
/// runtime — so at launch they sit right of the menu-bar hider's separator, which is created after this
/// module starts. Note: macOS inserts an item that is shown again at runtime left of all other items.
@MainActor
final class StatusItemsController: NSObject {
    private(set) var items: [MonitorMetric: NSStatusItem] = [:]
    private(set) var combinedItem: NSStatusItem?
    var onClick: ((NSStatusBarButton) -> Void)?

    static func autosaveName(_ name: String) -> String {
        "OneSwitchMonitor.\(name)" + AppEnvironment.profileSuffix
    }

    var isInstalled: Bool { !items.isEmpty }

    /// Creates every item once, visible or hidden according to `settings`.
    ///
    /// macOS places a status item that is created — or shown again after `isVisible = false` — to the
    /// LEFT of all existing items. Creating the items in reverse order with their final visibility
    /// gives the desired left→right order CPU, GPU, 内存, 网络, 磁盘, 功率, 温度 (combined item right-most).
    func install(_ settings: MonitorSettings) {
        guard !isInstalled else { return }
        let combined = makeItem(name: "combined", label: "系统监控")
        combined.isVisible = Self.isCombinedVisible(settings)
        combinedItem = combined
        for metric in MonitorMetric.allCases.reversed() {
            let item = makeItem(name: metric.rawValue, label: "系统监控：\(metric.title)")
            item.isVisible = Self.isVisible(metric, settings)
            items[metric] = item
        }
    }

    static func isVisible(_ metric: MonitorMetric, _ settings: MonitorSettings) -> Bool {
        !settings.combined && settings.enabledMetrics.contains(metric)
    }

    static func isCombinedVisible(_ settings: MonitorSettings) -> Bool {
        settings.combined && !settings.enabledMetrics.isEmpty
    }

    func uninstall() {
        for item in items.values { NSStatusBar.system.removeStatusItem(item) }
        if let combinedItem { NSStatusBar.system.removeStatusItem(combinedItem) }
        items = [:]
        combinedItem = nil
    }

    private func makeItem(name: String, label: String) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Seed a position right of third-party items (smaller distance = further right; the leftmost
        // metric gets the largest distance), then assign the autosave name, which restores saved state.
        let order = MonitorMetric.allCases.firstIndex { $0.rawValue == name }.map { MonitorMetric.allCases.count - $0 } ?? 0
        StatusItemPlacement.seed(autosaveName: Self.autosaveName(name),
                                 distanceFromTrailingEdge: StatusItemPlacement.Slot.monitorBase + Double(order))
        item.autosaveName = Self.autosaveName(name)
        item.behavior = []
        if let button = item.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel(label)
        }
        return item
    }

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        onClick?(sender)
    }

    /// Shows exactly the items the settings ask for. Items to hide are hidden first; items to show are
    /// shown right-most first, so several items shown together keep their relative order (each shown
    /// item is inserted left of everything else — see `install`).
    func applyVisibility(_ settings: MonitorSettings) {
        var toShow: [NSStatusItem] = []
        if let combinedItem {
            let visible = Self.isCombinedVisible(settings)
            if !visible && combinedItem.isVisible { combinedItem.isVisible = false }
            if visible && !combinedItem.isVisible { toShow.append(combinedItem) }
        }
        for metric in MonitorMetric.allCases.reversed() {
            guard let item = items[metric] else { continue }
            let visible = Self.isVisible(metric, settings)
            if !visible && item.isVisible { item.isVisible = false }
            if visible && !item.isVisible { toShow.append(item) }
        }
        for item in toShow { item.isVisible = true }
    }

    /// Buttons of the visible items, left to right.
    var visibleButtons: [NSStatusBarButton] {
        var result: [NSStatusBarButton] = []
        for metric in MonitorMetric.allCases {
            if let item = items[metric], item.isVisible, let b = item.button { result.append(b) }
        }
        if let combinedItem, combinedItem.isVisible, let b = combinedItem.button { result.append(b) }
        return result
    }

    /// Visible buttons that are actually laid out on a screen, left to right. A shown item can still be
    /// off-screen: a menu-bar manager (e.g. the 菜单栏图标 module's collapsed separator) pushes items it
    /// hides out of the bar, and a popover anchored to such a button would open off-screen.
    var onScreenButtons: [NSStatusBarButton] {
        let screens = NSScreen.screens.map(\.frame)
        return visibleButtons.filter { button in
            guard let window = button.window else { return false }
            return Self.isOnScreen(window.frame, screens: screens)
        }
    }

    /// Pure predicate (exposed for checks): the item window has a size and its centre lies on a screen.
    /// Items pushed out of the menu bar sit at e.g. (0, -30, 47, 30) — touching the screen edge only.
    static func isOnScreen(_ frame: CGRect, screens: [CGRect]) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return screens.contains { $0.contains(centre) }
    }

    /// Re-renders every visible item.
    func render(snapshot: MonitorSnapshot, histories: [HistorySeries: SampleHistory], settings: MonitorSettings) {
        let height = NSStatusBar.system.thickness
        if settings.combined {
            guard let item = combinedItem, item.isVisible else { return }
            let segments = settings.orderedEnabledMetrics.map {
                StatusContent.segment(for: $0, snapshot: snapshot, histories: histories, settings: settings)
            }
            set(item, segments: segments, style: settings.style, height: height, colorWarning: settings.colorWarning,
                tooltip: MonitorSummary.lines(snapshot: snapshot, settings: settings).joined(separator: "\n"))
            return
        }
        for metric in settings.orderedEnabledMetrics {
            guard let item = items[metric], item.isVisible else { continue }
            let segment = StatusContent.segment(for: metric, snapshot: snapshot, histories: histories, settings: settings)
            var single = settings
            single.enabledMetrics = [metric]
            set(item, segments: [segment], style: settings.style, height: height, colorWarning: settings.colorWarning,
                tooltip: MonitorSummary.lines(snapshot: snapshot, settings: single).joined(separator: "\n"))
        }
    }

    private func set(_ item: NSStatusItem, segments: [StatusSegment], style: DisplayStyle, height: CGFloat,
                     colorWarning: Bool, tooltip: String) {
        guard let button = item.button else { return }
        let alert = colorWarning && segments.contains { $0.level > .normal }
        let tint: StatusRenderer.Tint
        if alert {
            let dark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            tint = .colored(dark: dark)
        } else {
            tint = .template
        }
        button.image = StatusRenderer.image(for: segments, style: style, height: height, tint: tint)
        if button.toolTip != tooltip { button.toolTip = tooltip }
    }
}
