import AppKit

/// 菜单栏图标: what the main OneSwitch status-bar icon turns into while 防止锁屏 is active
/// (`AwakeSettings.statusIcon`, default 闪电).
///
/// Persisted by raw value. An unknown raw value (e.g. written by a newer build) decodes as the
/// default, so it can never break the rest of the settings.
public enum AwakeStatusIcon: String, Codable, CaseIterable, Identifiable, Sendable {
    case bolt
    case eye
    case sun
    case display
    case lightbulb
    case power
    case cup
    /// 不改变图标: the status-bar icon stays the normal OneSwitch icon while active.
    case unchanged = "none"

    public static let defaultChoice: AwakeStatusIcon = .bolt

    public var id: String { rawValue }

    /// Chinese label (picker tiles, accessibility).
    public var title: String {
        switch self {
        case .bolt: return "闪电"
        case .eye: return "眼睛"
        case .sun: return "太阳"
        case .display: return "显示器"
        case .lightbulb: return "灯泡"
        case .power: return "电源"
        case .cup: return "咖啡杯"
        case .unchanged: return "不改变图标"
        }
    }

    /// SF Symbol for the status bar while active (filled variants read best at menu-bar size);
    /// nil = 不改变图标.
    public var activeSymbol: String? {
        switch self {
        case .bolt: return "bolt.fill"
        case .eye: return "eye.fill"
        case .sun: return "sun.max.fill"
        case .display: return "display"
        case .lightbulb: return "lightbulb.fill"
        case .power: return "power"
        case .cup: return "cup.and.saucer.fill"
        case .unchanged: return nil
        }
    }

    /// Outline variant for menu items (the "立即开启" item); nil = 不改变图标.
    public var outlineSymbol: String? {
        switch self {
        case .bolt: return "bolt"
        case .eye: return "eye"
        case .sun: return "sun.max"
        case .display: return "display"
        case .lightbulb: return "lightbulb"
        case .power: return "power"
        case .cup: return "cup.and.saucer"
        case .unchanged: return nil
        }
    }

    /// Symbol drawn on the picker tile.
    public var previewSymbol: String { activeSymbol ?? Self.unchangedPreviewSymbol }

    /// Picker tile of 不改变图标.
    public static let unchangedPreviewSymbol = "circle.slash"
    /// Menu-item symbol when the chosen outline symbol is missing or for 不改变图标.
    public static let genericMenuSymbol = "play.circle"
    /// Tried in order when the chosen status-bar symbol does not exist on this macOS.
    public static let fallbackActiveSymbols = ["bolt.fill", "cup.and.saucer.fill"]

    /// Whether this macOS has the SF Symbol `name`.
    public static func isSymbolAvailable(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// The status-bar symbol to show while active: the chosen one, else the first available fallback;
    /// nil for 不改变图标 (or when no candidate exists — the app then keeps its normal icon).
    public func resolvedActiveSymbol(isAvailable: (String) -> Bool = AwakeStatusIcon.isSymbolAvailable) -> String? {
        guard let preferred = activeSymbol else { return nil }
        return ([preferred] + Self.fallbackActiveSymbols).first(where: isAvailable)
    }

    /// Symbol of the "立即开启" menu item (matches the status-bar icon the user will see).
    public func resolvedMenuSymbol(isAvailable: (String) -> Bool = AwakeStatusIcon.isSymbolAvailable) -> String {
        if let outline = outlineSymbol, isAvailable(outline) { return outline }
        return Self.genericMenuSymbol
    }

    /// Menu-item symbol of the "关闭防止锁屏" state of the toggle item.
    public static let stopMenuSymbol = "stop.circle"

    /// Symbol of the menu's on/off toggle item: 关闭 while active, else the chosen icon's outline.
    public func menuToggleSymbol(isActive: Bool,
                                 isAvailable: (String) -> Bool = AwakeStatusIcon.isSymbolAvailable) -> String {
        isActive ? Self.stopMenuSymbol : resolvedMenuSymbol(isAvailable: isAvailable)
    }

    /// Choices offered by the settings picker: those whose symbol exists on this macOS
    /// (不改变图标 always). Computed once.
    public static let pickerChoices: [AwakeStatusIcon] = allCases.filter { icon in
        icon.activeSymbol.map(isSymbolAvailable) ?? true
    }
}
