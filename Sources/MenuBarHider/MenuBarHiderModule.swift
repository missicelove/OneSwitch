import AppKit
import SwiftUI
import OneSwitchCore

/// 菜单栏图标 — hides menu-bar icons; clicking the「<」toggle reveals them for 5…60 s.
///
/// - macOS 27+ (系统原生隐藏): only the toggle is in the bar. Collapsing asks macOS to show just the
///   system items and the allowed apps (per-app rule 自动 / 始终隐藏 / 始终显示; 自动 = by position left /
///   right of the toggle). macOS reflows the bar itself — no "«", no gap. See `NativeVisibilityEngine`.
/// - macOS 14–26, and as automatic fallback (兼容模式): a separator left of the toggle is widened so
///   the icons left of it are pushed off-screen / into the system "«" (see `CollapseStrategy`).
@MainActor
public final class MenuBarHiderModule: FeatureModule {
    public let id = "menubar"
    public let displayName = "菜单栏图标"
    public let symbolName = "menubar.rectangle"

    /// The module's state (also observed by the settings page).
    public let controller: MenuBarHiderController

    public init() {
        controller = MenuBarHiderController()
    }

    /// Test / profile hook: custom settings storage and status-item autosave suffix.
    /// - Parameters:
    ///   - native: 系统原生隐藏 dependencies (fakes in the self-checks); nil = separator engine only.
    ///   - seedPositions: place new items next to the system items (the checks keep theirs left-most).
    public init(defaults: UserDefaults, autosaveSuffix: String, strategy: CollapseStrategy = .current,
                native: NativeHidingDependencies? = nil, seedPositions: Bool = false) {
        controller = MenuBarHiderController(defaults: defaults, autosaveSuffix: autosaveSuffix, strategy: strategy,
                                            native: native, seedPositions: seedPositions)
    }

    public func start() {
        controller.start()
    }

    public func stop() {
        controller.stop()
    }

    public func menuItems() -> [NSMenuItem] {
        controller.menuItems()
    }

    public func settingsView() -> AnyView {
        AnyView(MenuBarHiderSettingsView(controller: controller))
    }
}
