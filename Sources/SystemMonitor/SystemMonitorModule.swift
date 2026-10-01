import AppKit
import Combine
import OneSwitchCore
import SwiftUI

/// 系统监控: per-metric menu-bar stats (CPU / GPU / 内存 / 网络 / 磁盘 / 功率 / 温度), a detail popover
/// and a settings page. Sampling runs on a background queue and only covers what is on screen.
@MainActor
public final class SystemMonitorModule: FeatureModule {
    public let id = "monitor"
    public let displayName = "系统监控"
    public let symbolName = "gauge.with.dots.needle.33percent"

    let store: SettingsStore<MonitorSettings>
    let model = MonitorModel()
    let statusItems = StatusItemsController()
    let popover = DetailPopoverController()
    private(set) var engine: MonitorEngine?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var visibleSettingsViews = Set<ObjectIdentifier>()
    private var lastConfiguration: MonitorEngine.Configuration?
    /// Summary items of the most recently built menu (updated live while it is open).
    private var summaryItems: [WeakMenuItem] = []

    /// Why sampling is suspended although items are shown: nobody can see the menu bar, so the timer,
    /// SMC connection and ps runs are released. Resuming starts fresh rate baselines, so no rate is
    /// ever averaged over a sleep gap.
    enum PauseReason: String, Hashable { case screensAsleep, systemAsleep, sessionInactive }
    private(set) var pauseReasons = Set<PauseReason>()
    private var workspaceObservers: [NSObjectProtocol] = []

    public convenience init() {
        self.init(defaults: AppEnvironment.defaults)
    }

    /// Settings are read from / written to `defaults` (injectable for checks).
    public init(defaults: UserDefaults) {
        store = SettingsStore(key: "monitor.settings", defaultValue: MonitorSettings(), defaults: defaults)
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        let engine = MonitorEngine { [weak self] snapshot in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(snapshot) }
            }
        }
        self.engine = engine

        // Create every status item now (fixed order) — never later at runtime.
        statusItems.install(store.value)
        statusItems.onClick = { [weak self] button in self?.togglePopover(from: button) }
        popover.onVisibilityChange = { [weak self] _ in
            guard let self else { return }
            if !self.popover.isShown { self.model.clearProcesses() }
            self.updateEngine()
        }

        observeWorkspace()
        apply(store.value)
        store.$value
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] value in self?.apply(value) }
            .store(in: &cancellables)
        AppLog.info(id, "started (metrics: \(store.value.orderedEnabledMetrics.map(\.rawValue).joined(separator: ",")), style: \(store.value.style.rawValue), combined: \(store.value.combined))")
    }

    public func stop() {
        guard started else { return }
        started = false
        cancellables.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        pauseReasons = []
        popover.onVisibilityChange = nil
        popover.close()
        engine?.stop()
        engine = nil
        lastConfiguration = nil
        statusItems.onClick = nil
        statusItems.uninstall()
        summaryItems = []
        AppLog.info(id, "stopped")
    }

    // MARK: Settings → UI / engine

    private func apply(_ settings: MonitorSettings) {
        guard started else { return }
        statusItems.applyVisibility(settings)
        // Close the popover if its anchor item was just hidden.
        if popover.isShown, let anchor = popover.anchorButton, !statusItems.visibleButtons.contains(where: { $0 === anchor }) {
            popover.close()
        }
        updateEngine(settings)
        statusItems.render(snapshot: model.snapshot, histories: model.histories, settings: settings)
    }

    /// Everything on screen decides what gets sampled.
    func configuration(for settings: MonitorSettings) -> MonitorEngine.Configuration {
        guard pauseReasons.isEmpty else {
            return MonitorEngine.Configuration(metrics: [], interval: settings.effectiveInterval,
                                               networkInterface: settings.networkInterface, includeProcesses: false)
        }
        let detailVisible = popover.isShown || !visibleSettingsViews.isEmpty
        let metrics: Set<MonitorMetric> = detailVisible ? Set(MonitorMetric.allCases) : settings.enabledMetrics
        return MonitorEngine.Configuration(metrics: metrics, interval: settings.effectiveInterval,
                                           networkInterface: settings.networkInterface,
                                           includeProcesses: popover.isShown)
    }

    private func updateEngine(_ settings: MonitorSettings? = nil) {
        guard started, let engine else { return }
        let config = configuration(for: settings ?? store.value)
        guard config != lastConfiguration else { return }
        lastConfiguration = config
        model.discardReadings(except: config.metrics)
        engine.update(config)
        AppLog.debug(id, "sampling \(config.metrics.map(\.rawValue).sorted().joined(separator: ",")) every \(Int(config.interval))s\(config.includeProcesses ? " + processes" : "")")
    }

    func receive(_ delivered: MonitorSnapshot) {
        guard started else { return }
        // A pass that was already running when the configuration changed must not bring back readings
        // of metrics that are no longer sampled (they would stay frozen once the timer goes idle).
        let snapshot = lastConfiguration.map { delivered.restricted(to: $0.metrics) } ?? delivered
        model.ingest(snapshot)
        let settings = store.value
        statusItems.render(snapshot: snapshot, histories: model.histories, settings: settings)
        refreshSummaryItems(settings)
    }

    func settingsVisibilityChanged(_ id: ObjectIdentifier, _ visible: Bool) {
        if visible { visibleSettingsViews.insert(id) } else { visibleSettingsViews.remove(id) }
        updateEngine()
    }

    // MARK: Display / system sleep

    func setPaused(_ reason: PauseReason, _ paused: Bool) {
        guard started else { return }
        let changed = paused ? pauseReasons.insert(reason).inserted : pauseReasons.remove(reason) != nil
        guard changed else { return }
        AppLog.info(id, "\(paused ? "paused" : "resumed") sampling (\(reason.rawValue))")
        updateEngine()
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, PauseReason, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, .screensAsleep, true),
            (NSWorkspace.screensDidWakeNotification, .screensAsleep, false),
            (NSWorkspace.willSleepNotification, .systemAsleep, true),
            (NSWorkspace.didWakeNotification, .systemAsleep, false),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive, true),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive, false),
        ]
        for (name, reason, paused) in events {
            let isWake = name == NSWorkspace.didWakeNotification
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setPaused(reason, paused)
                    // A full wake lights the displays; never stay paused (items frozen) because their
                    // wake note was missed. Worst case we sample while they are still dark.
                    if isWake { self.setPaused(.screensAsleep, false) }
                }
            })
        }
    }

    // MARK: Popover

    func togglePopover(from button: NSStatusBarButton) {
        popover.toggle(relativeTo: button) { detailView() }
    }

    private func detailView() -> AnyView {
        AnyView(DetailView(
            model: model, store: store, pin: popover.pin,
            openActivityMonitor: { [weak self] in
                self?.popover.close()
                Self.openActivityMonitor()
            },
            openSettings: { [weak self] in
                self?.popover.close()
                AppContext.shared.openSettings(moduleID: "monitor")
            }))
    }

    private func showDetailsFromMenu() {
        // Runs after the main menu has closed; anchor to the first monitor item that is on screen
        // (shown items can be pushed out of the bar by the menu-bar hider). None → the settings page,
        // which lists every metric with its live value.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.started else { return }
                if let button = self.statusItems.onScreenButtons.first {
                    if !self.popover.isShown { self.togglePopover(from: button) }
                } else {
                    AppContext.shared.openSettings(moduleID: self.id)
                }
            }
        }
    }

    static func openActivityMonitor() {
        let candidates = ["/System/Applications/Utilities/Activity Monitor.app", "/Applications/Utilities/Activity Monitor.app"]
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor")
            ?? candidates.map { URL(fileURLWithPath: $0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        guard let url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Menu

    public func menuItems() -> [NSMenuItem] {
        let settings = store.value
        var items: [NSMenuItem] = []
        summaryItems = []
        if settings.enabledMetrics.isEmpty {
            items.append(.info("菜单栏未显示任何指标"))
        } else {
            for line in MonitorSummary.lines(snapshot: model.snapshot, settings: settings) {
                let item = NSMenuItem.info(line)
                summaryItems.append(WeakMenuItem(item))
                items.append(item)
            }
        }
        items.append(BlockMenuItem("显示详细信息…", symbol: "chart.xyaxis.line") { [weak self] in
            self?.showDetailsFromMenu()
        })

        var toggles: [NSMenuItem] = MonitorMetric.allCases.map { metric in
            let on = settings.enabledMetrics.contains(metric)
            return BlockMenuItem(metric.title, symbol: metric.symbolName, state: on ? .on : .off) { [weak self] in
                self?.store.update { s in
                    if on { s.enabledMetrics.remove(metric) } else { s.enabledMetrics.insert(metric) }
                }
            }
        }
        toggles.append(.separator())
        toggles.append(BlockMenuItem("合并显示", state: settings.combined ? .on : .off) { [weak self] in
            self?.store.update { $0.combined.toggle() }
        })
        items.append(.submenu("在菜单栏显示", symbol: "menubar.rectangle", items: toggles))
        return items
    }

    /// Updates the summary lines in place (the menu stays open while samples arrive).
    private func refreshSummaryItems(_ settings: MonitorSettings) {
        guard !summaryItems.isEmpty else { return }
        let live = summaryItems.compactMap(\.item)
        guard live.count == summaryItems.count, live.contains(where: { $0.menu != nil }) else {
            if live.isEmpty { summaryItems = [] }
            return
        }
        let lines = MonitorSummary.lines(snapshot: model.snapshot, settings: settings)
        guard lines.count == live.count else { return }
        for (item, line) in zip(live, lines) where item.title != line { item.title = line }
    }

    // MARK: Settings page

    public func settingsView() -> AnyView {
        AnyView(MonitorSettingsView(store: store, model: model) { [weak self] id, visible in
            self?.settingsVisibilityChanged(id, visible)
        })
    }
}

private struct WeakMenuItem {
    weak var item: NSMenuItem?
    init(_ item: NSMenuItem) { self.item = item }
}
