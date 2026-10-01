import AppKit
import OneSwitchCore

/// Builds the module's section of the main menu and, while the menu is open, updates the status
/// line once per second (live countdown). The 1 Hz timer only runs while the menu is being tracked.
@MainActor
final class AwakeMenuPresenter {
    private weak var statusItem: NSMenuItem?
    private weak var toggleItem: NSMenuItem?
    /// SF Symbol currently shown on `toggleItem` (re-set by the live update when the state flips).
    private var toggleSymbol: String?
    private weak var controller: AwakeController?
    private var timer: Timer?
    private var trackingObserver: NSObjectProtocol?

    func items(for controller: AwakeController) -> [NSMenuItem] {
        stopLiveUpdates()
        self.controller = controller
        let status = controller.evaluate(reason: "menu")
        let settings = controller.settings
        let now = controller.now
        let calendar = controller.calendar

        let statusLine = NSMenuItem.info(AwakeText.statusLine(status, now: now, calendar: calendar))
        let symbol = settings.statusIcon.menuToggleSymbol(isActive: status.isActive)
        let toggle = BlockMenuItem(AwakeText.toggleTitle(isActive: status.isActive), symbol: symbol) { [weak controller] in
            controller?.toggle()
        }
        toggleSymbol = symbol

        let runningMinutes: Int?? = status.session.map { $0.minutes }
        var presetItems: [NSMenuItem] = AwakeLimits.presetMinutes.map { minutes in
            BlockMenuItem(Fmt.minutes(minutes), state: runningMinutes == .some(minutes) ? .on : .off) { [weak controller] in
                controller?.startSession(minutes: minutes)
            }
        }
        presetItems.append(.separator())
        presetItems.append(BlockMenuItem("无限期（直到手动关闭）",
                                         state: runningMinutes == .some(nil) ? .on : .off) { [weak controller] in
            controller?.startSession(minutes: nil)
        })
        let custom = AwakeLimits.clampSession(settings.customMinutes)
        if !AwakeLimits.presetMinutes.contains(custom) {
            presetItems.append(BlockMenuItem("自定义：\(Fmt.minutes(custom))",
                                             state: runningMinutes == .some(custom) ? .on : .off) { [weak controller] in
                controller?.startSession(minutes: custom)
            })
        }
        presetItems.append(BlockMenuItem("自定义时长…") {
            AppContext.shared.openSettings(moduleID: "awake")
        })
        let durations = NSMenuItem.submenu("开启一段时间", symbol: "timer", items: presetItems)

        let schedule = BlockMenuItem(AwakeText.scheduleMenuTitle(settings),
                                     state: settings.scheduleEnabled ? .on : .off) { [weak controller] in
            guard let controller else { return }
            controller.setScheduleEnabled(!controller.settings.scheduleEnabled)
        }
        let today = NSMenuItem.info(AwakeText.todayLine(status.today))

        statusItem = statusLine
        toggleItem = toggle
        startLiveUpdates()
        return [statusLine, toggle, durations, schedule, today]
    }

    func stopLiveUpdates() {
        timer?.invalidate()
        timer = nil
        if let trackingObserver { NotificationCenter.default.removeObserver(trackingObserver) }
        trackingObserver = nil
    }

    private func startLiveUpdates() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
        trackingObserver = NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification,
                                                                  object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only the top-level menu closing ends the live updates (submenus post this too).
                guard let menu = note.object as? NSMenu, let root = self.statusItem?.menu, menu === root else { return }
                self.stopLiveUpdates()
            }
        }
    }

    private func tick() {
        // Menus are tracked in the event-tracking run-loop mode; anything else means the menu is closed
        // (e.g. a missed end-tracking notification) and the timer must not keep running.
        guard let controller, let item = statusItem, item.menu != nil,
              RunLoop.current.currentMode == .eventTracking else {
            stopLiveUpdates()
            return
        }
        let status = controller.status
        let title = AwakeText.statusLine(status, now: controller.now, calendar: controller.calendar)
        if item.title != title { item.title = title }
        guard let toggleItem else { return }
        let toggleTitle = AwakeText.toggleTitle(isActive: status.isActive)
        if toggleItem.title != toggleTitle { toggleItem.title = toggleTitle }
        // A session ending / the schedule switching while the menu is open flips the item: its symbol
        // (关闭 ↔ the chosen 菜单栏图标 outline) must follow the title.
        let symbol = controller.settings.statusIcon.menuToggleSymbol(isActive: status.isActive)
        if symbol != toggleSymbol {
            toggleSymbol = symbol
            toggleItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    var isLive: Bool { timer != nil }
}
