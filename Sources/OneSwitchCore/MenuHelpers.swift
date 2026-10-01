import AppKit

/// An NSMenuItem that runs a closure. The main menu sets `autoenablesItems = false`,
/// so `isEnabled` is honoured exactly as given.
public final class BlockMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    public init(_ title: String,
                symbol: String? = nil,
                key: String = "",
                modifiers: NSEvent.ModifierFlags = [.command],
                state: NSControl.StateValue = .off,
                enabled: Bool = true,
                handler: (() -> Void)?) {
        self.handler = handler
        super.init(title: title, action: handler == nil ? nil : #selector(fire), keyEquivalent: key)
        self.target = self
        self.keyEquivalentModifierMask = modifiers
        self.state = state
        self.isEnabled = enabled && handler != nil
        if let symbol { self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler?() }
}

public extension NSMenuItem {
    /// A non-interactive informational line (rendered greyed out).
    static func info(_ title: String, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    /// A submenu item. The submenu has `autoenablesItems = false`.
    static func submenu(_ title: String, symbol: String? = nil, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    /// A menu item hosting a custom view (e.g. an NSHostingView) — useful for sliders / live stats.
    static func view(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = view
        return item
    }
}
