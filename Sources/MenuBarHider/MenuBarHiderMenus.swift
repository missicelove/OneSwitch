import AppKit
import OneSwitchCore

extension MenuBarHiderController {
    /// Text describing the current state (menu info line / settings badge).
    public var stateText: String {
        Self.stateText(enabled: current.enabled, active: isActive, visibility: visibility,
                       secondsUntilCollapse: secondsUntilCollapse,
                       alwaysHiddenEnabled: engineKind == .legacy && current.alwaysHiddenEnabled,
                       hiddenAppCount: hiddenAppCount, hiding: engineKind == .native && nativeState == .activating,
                       forNotificationCenter: notificationCenterAssistActive)
    }

    /// Pure form of `stateText` (unit-tested).
    /// - Parameters:
    ///   - hiddenAppCount: 系统原生隐藏: apps hidden by the active restriction.
    ///   - hiding: 系统原生隐藏: the restriction is being set up.
    ///   - forNotificationCenter: every icon is shown while Notification Center is open (点击时钟).
    public static func stateText(enabled: Bool, active: Bool, visibility: RevealStateMachine.Visibility,
                                 secondsUntilCollapse: Int?, alwaysHiddenEnabled: Bool = true,
                                 hiddenAppCount: Int? = nil, hiding: Bool = false,
                                 forNotificationCenter: Bool = false) -> String {
        guard enabled else { return "已停用，所有图标正常显示" }
        guard active else { return "未运行" }
        switch visibility {
        case .collapsed:
            if hiding { return "正在隐藏图标…" }
            if let n = hiddenAppCount { return n > 0 ? "已隐藏 \(n) 个 App 的图标" : "图标已收起（没有需要隐藏的 App）" }
            return "隐藏区的图标已收起"
        case .expanded, .expandedAll:
            if forNotificationCenter { return "通知中心打开期间临时显示全部图标" }
            // Listing items reveals "everything" even when there is no 永久隐藏区 — don't mention it then.
            let all = visibility == .expandedAll && alwaysHiddenEnabled ? "（含永久隐藏区）" : ""
            if let s = secondsUntilCollapse {
                // 0 = overdue: postponed while the pointer is in the menu bar or a menu is open.
                return s > 0 ? "图标已显示\(all)，\(s) 秒后自动隐藏" : "图标已显示\(all)，鼠标离开菜单栏后自动隐藏"
            }
            return "图标已显示\(all)"
        }
    }

    /// The module's section of the main OneSwitch menu.
    func menuItems() -> [NSMenuItem] {
        guard current.enabled else {
            return [
                .info("已停用，所有图标正常显示", symbol: "eye"),
                BlockMenuItem("启用图标隐藏", symbol: "eye.slash") { [weak self] in self?.setEnabled(true) },
            ]
        }
        var items: [NSMenuItem] = []
        if visibility == .collapsed {
            let title = current.autoCollapse
                ? "显示隐藏的图标（\(current.effectiveDelay) 秒后自动隐藏）"
                : "显示隐藏的图标"
            items.append(BlockMenuItem(title, symbol: "eye", enabled: isActive) { [weak self] in self?.expand() })
        } else {
            items.append(BlockMenuItem("立即隐藏图标", symbol: "eye.slash", enabled: isActive) { [weak self] in self?.collapse() })
        }
        if let warning = warningText {
            items.append(.info(warning, symbol: "exclamationmark.triangle"))
        } else {
            items.append(.info(Self.menuStatusLine(engine: engineTitle, state: stateText)))
        }
        if let note = nativeNote {
            items.append(.info(note, symbol: "exclamationmark.triangle"))
        }
        if let note = nativeRevealNote {
            items.append(.info(note, symbol: "rectangle.compress.vertical"))
        }
        if offersShowAllIcons {
            items.append(BlockMenuItem(Self.showAllIconsTitle, symbol: "eye.circle", enabled: isActive) { [weak self] in
                self?.revealAllIcons()
            })
        }
        let arrange = engineKind == .native ? "设置要隐藏的 App…" : "整理菜单栏图标…"
        items.append(BlockMenuItem(arrange, symbol: "slider.horizontal.3") {
            AppContext.shared.openSettings(moduleID: "menubar")
        })
        return items
    }

    /// "系统原生隐藏 · 已隐藏 5 个 App 的图标".
    public static func menuStatusLine(engine: String, state: String) -> String {
        "\(engine) · \(state)"
    }

    /// Right-click menu of the toggle button.
    public func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "菜单栏图标")
        menu.autoenablesItems = false
        if let warning = warningText {
            menu.addItem(.info(warning, symbol: "exclamationmark.triangle"))
            menu.addItem(.separator())
        }
        if let note = nativeRevealNote {
            menu.addItem(.info(note, symbol: "rectangle.compress.vertical"))
            menu.addItem(.separator())
        }
        if visibility == .collapsed {
            menu.addItem(BlockMenuItem("显示隐藏的图标", symbol: "eye") { [weak self] in self?.expand() })
        } else {
            menu.addItem(BlockMenuItem("隐藏图标", symbol: "eye.slash") { [weak self] in self?.collapse() })
        }
        if engineKind == .legacy && current.alwaysHiddenEnabled && visibility != .expandedAll {
            menu.addItem(BlockMenuItem("显示全部图标（含永久隐藏区）", symbol: "eye.circle") { [weak self] in
                self?.expand(revealAlwaysHidden: true)
            })
        }
        if offersShowAllIcons {
            menu.addItem(BlockMenuItem(Self.showAllIconsTitle, symbol: "eye.circle") { [weak self] in self?.revealAllIcons() })
        }
        menu.addItem(.separator())
        menu.addItem(.info(Self.menuStatusLine(engine: engineTitle, state: stateText)))
        menu.addItem(BlockMenuItem("设置…", symbol: "gearshape") {
            AppContext.shared.openSettings(moduleID: "menubar")
        })
        return menu
    }
}
