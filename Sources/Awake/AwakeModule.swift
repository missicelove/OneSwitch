import AppKit
import Combine
import SwiftUI
import OneSwitchCore

/// 防止锁屏: keeps the display awake (and the screen unlocked) manually for 5 min – 12 h / indefinitely,
/// or automatically on workdays within a time window. Workdays honour a holiday calendar chosen by
/// "节假日日历": 自动 by system time zone, 中国大陆 (holiday-cn incl. 调休), 波兰 (offline), or none.
@MainActor
public final class AwakeModule: FeatureModule {
    public let id = "awake"
    public let displayName = "防止锁屏"
    public let symbolName = "bolt"

    public static let hotKeyID = "awake.toggle"

    public let controller: AwakeController
    private let menu = AwakeMenuPresenter()
    private var cancellables: Set<AnyCancellable> = []
    private var started = false

    public init() {
        controller = AwakeController(defaults: AppContext.shared.defaults,
                                     dataDirectory: AppContext.shared.dataDirectory)
    }

    /// For checks / embedding: use a preconfigured controller.
    public init(controller: AwakeController) {
        self.controller = controller
    }

    public func start() {
        guard !started else { return }
        started = true
        controller.onStatusIconChange = { AppContext.shared.refreshStatusIcon() }
        controller.start()
        registerHotKey(controller.settings.hotKey)
        controller.store.$value
            .map(\.hotKey)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] hotKey in self?.registerHotKey(hotKey) }
            .store(in: &cancellables)
        AppContext.shared.refreshStatusIcon()
    }

    public func stop() {
        guard started else { return }
        started = false
        cancellables.removeAll()
        menu.stopLiveUpdates()
        GlobalHotKeyCenter.shared.unregister(id: Self.hotKeyID)
        controller.stop()
        controller.onStatusIconChange = nil
    }

    public func menuItems() -> [NSMenuItem] {
        menu.items(for: controller)
    }

    public func settingsView() -> AnyView {
        AnyView(AwakeSettingsView(controller: controller, store: controller.store, holidays: controller.holidays))
    }

    /// While active: the symbol chosen under 菜单栏图标 (default 闪电 "bolt.fill"; falls back when this
    /// macOS lacks it); nil while off, for 不改变图标, or while the controller is not running (no power
    /// assertion is held then, even if a persisted session / the schedule says "active"). Reads
    /// `controller.settings`, which is already updated when the controller reports an icon change (the
    /// store's value is not, mid-publish).
    public var statusIconSymbol: String? {
        guard controller.isRunning, controller.status.isActive else { return nil }
        return controller.settings.statusIcon.resolvedActiveSymbol()
    }

    /// True while the menu's live countdown timer runs (diagnostics / checks).
    public var isMenuLive: Bool { menu.isLive }

    private func registerHotKey(_ hotKey: HotKey?) {
        let ok = GlobalHotKeyCenter.shared.register(id: Self.hotKeyID, hotKey: hotKey) { [weak self] in
            self?.controller.toggle()
        }
        controller.hotKeyMessage = ok ? nil : "快捷键 \(hotKey?.displayString ?? "") 已被系统或其他应用占用，请换一个组合"
    }
}
