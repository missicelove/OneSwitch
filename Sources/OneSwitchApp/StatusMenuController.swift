import AppKit
import OneSwitchCore

/// The main OneSwitch status item and its menu. The menu is rebuilt every time it opens so each
/// module's section reflects live state (modules that show ticking values update their own items
/// while the menu stays open).
///
/// Created before any module starts: new status items appear to the LEFT of existing ones, so the main
/// item stays right-most — right of the monitor items and of the menu-bar hider's toggle/separator,
/// which means it can never be hidden by 菜单栏图标.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    static let defaultSymbol = "switch.2"

    private let statusItem: NSStatusItem
    private let modules: [FeatureModule]
    /// Modules consulted for the icon override, most important first.
    private let iconPriority: [FeatureModule]
    private let menu = NSMenu()

    init(modules: [FeatureModule], iconPriority: [FeatureModule]? = nil) {
        self.modules = modules
        self.iconPriority = iconPriority ?? modules
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let autosave = "OneSwitchMain" + AppEnvironment.profileSuffix
        StatusItemPlacement.seed(autosaveName: autosave, distanceFromTrailingEdge: StatusItemPlacement.Slot.mainIcon)
        statusItem.autosaveName = autosave
        statusItem.behavior = [] // the main item cannot be removed by ⌘-dragging it off the bar
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshIcon()
    }

    func refreshIcon() {
        let symbol = iconPriority.lazy.compactMap(\.statusIconSymbol).first ?? Self.defaultSymbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "OneSwitch")
            ?? NSImage(systemSymbolName: Self.defaultSymbol, accessibilityDescription: "OneSwitch")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "OneSwitch" + (AppEnvironment.profile.map { "（\($0)）" } ?? "")
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (index, module) in modules.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            let header = NSMenuItem.sectionHeader(title: module.displayName)
            menu.addItem(header)
            for item in module.menuItems() {
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(BlockMenuItem("设置…", symbol: "gearshape", key: ",") {
            AppContext.shared.openSettings()
        })
        if LaunchAtLogin.isSupported {
            if LaunchAtLogin.requiresApproval {
                menu.addItem(BlockMenuItem("开机自动启动（需在系统设置中允许）…", state: .mixed) {
                    LaunchAtLogin.openSystemSettings()
                })
            } else {
                let enabled = LaunchAtLogin.isEnabled
                menu.addItem(BlockMenuItem("开机自动启动", state: enabled ? .on : .off) {
                    LaunchAtLogin.setEnabled(!enabled)
                })
            }
        }
        menu.addItem(BlockMenuItem("退出 OneSwitch", symbol: "power", key: "q") {
            NSApp.terminate(nil)
        })
    }
}
