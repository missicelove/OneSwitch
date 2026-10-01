import Foundation
import OneSwitchCore

/// Look of the separator item while the hidden section is revealed.
public enum SeparatorStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case line
    case dot

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .line: return "细线"
        case .dot: return "圆点"
        }
    }
}

/// Look of the toggle button.
public enum ToggleIconStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case chevron
    case dot

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chevron: return "箭头"
        case .dot: return "圆点"
        }
    }
}

/// Persisted settings of the 菜单栏图标 module (`SettingsStore` key `"menubar.settings"`).
///
/// Decoding is lenient: every field is optional in the stored JSON and unknown enum values fall back
/// to the default, so adding / renaming fields never resets the user's other choices.
public struct MenuBarHiderSettings: Codable, Equatable, Sendable {
    public static let storeKey = "menubar.settings"
    public static let delayRange: ClosedRange<Int> = 5...60
    public static let delayStep = 5

    /// 启用 — when off, the separators are removed and every icon is shown.
    public var enabled = true
    /// 自动重新隐藏
    public var autoCollapse = true
    /// Seconds until the revealed icons are hidden again (5…60, step 5).
    public var autoCollapseDelay = 10
    /// 启动时自动隐藏
    public var collapseAtLaunch = true
    /// 永久隐藏区 (third separator; items left of it are only revealed by ⌥-clicking the toggle).
    /// Compatibility (separator) mode only — 系统原生隐藏 has no separators.
    public var alwaysHiddenEnabled = false
    /// 分隔线样式
    public var separatorStyle: SeparatorStyle = .line
    /// 收起时隐藏分隔线图标
    public var hideSeparatorWhenCollapsed = true
    /// 切换按钮样式
    public var toggleStyle: ToggleIconStyle = .chevron
    /// Global shortcut that toggles the hidden icons (GlobalHotKeyCenter id "menubar.toggle").
    public var hotKey: HotKey?
    /// 系统原生隐藏 (macOS 27+): per-app rule by bundle id. Apps without an entry use `.auto`
    /// (hidden when left of the「<」toggle); `.auto` is never stored.
    public var appRules: [String: AppVisibilityRule] = [:]
    /// 系统原生隐藏: 点击时钟时临时显示全部并打开通知中心 — macOS disables Notification Center while a
    /// restriction is held (see NotificationCenterAssist.swift).
    public var clockOpensNotificationCenter = true

    public init() {}

    /// The rule for `bundleID` (`.auto` when none is set).
    public func rule(for bundleID: String) -> AppVisibilityRule {
        appRules[bundleID] ?? .auto
    }

    /// Sets / clears (`.auto`) the rule for `bundleID`.
    public mutating func setRule(_ rule: AppVisibilityRule, for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        if rule == .auto { appRules[bundleID] = nil } else { appRules[bundleID] = rule }
    }

    /// `autoCollapseDelay` clamped to the allowed range and snapped to the step.
    public var effectiveDelay: Int { Self.clampDelay(autoCollapseDelay) }

    /// Clamps to 5…60 and rounds to the nearest multiple of 5.
    public static func clampDelay(_ seconds: Int) -> Int {
        let snapped = Int((Double(seconds) / Double(delayStep)).rounded()) * delayStep
        return min(max(snapped, delayRange.lowerBound), delayRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, autoCollapse, autoCollapseDelay, collapseAtLaunch, alwaysHiddenEnabled
        case separatorStyle, hideSeparatorWhenCollapsed, toggleStyle, hotKey, appRules, clockOpensNotificationCenter
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = MenuBarHiderSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        s.enabled = value(.enabled, s.enabled)
        s.autoCollapse = value(.autoCollapse, s.autoCollapse)
        s.autoCollapseDelay = Self.clampDelay(value(.autoCollapseDelay, s.autoCollapseDelay))
        s.collapseAtLaunch = value(.collapseAtLaunch, s.collapseAtLaunch)
        s.alwaysHiddenEnabled = value(.alwaysHiddenEnabled, s.alwaysHiddenEnabled)
        s.separatorStyle = value(.separatorStyle, s.separatorStyle)
        s.hideSeparatorWhenCollapsed = value(.hideSeparatorWhenCollapsed, s.hideSeparatorWhenCollapsed)
        s.toggleStyle = value(.toggleStyle, s.toggleStyle)
        s.clockOpensNotificationCenter = value(.clockOpensNotificationCenter, s.clockOpensNotificationCenter)
        s.hotKey = (try? c.decodeIfPresent(HotKey.self, forKey: .hotKey)) ?? nil
        // Settings written before 系统原生隐藏 have no rules. Unknown rule values (a newer build) and
        // empty keys are dropped one by one instead of losing every rule.
        let rawRules = ((try? c.decodeIfPresent([String: LenientRule].self, forKey: .appRules)) ?? nil) ?? [:]
        for (bundle, value) in rawRules {
            if let rule = value.rule { s.setRule(rule, for: bundle) }
        }
        self = s
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(autoCollapse, forKey: .autoCollapse)
        try c.encode(autoCollapseDelay, forKey: .autoCollapseDelay)
        try c.encode(collapseAtLaunch, forKey: .collapseAtLaunch)
        try c.encode(alwaysHiddenEnabled, forKey: .alwaysHiddenEnabled)
        try c.encode(separatorStyle, forKey: .separatorStyle)
        try c.encode(hideSeparatorWhenCollapsed, forKey: .hideSeparatorWhenCollapsed)
        try c.encode(toggleStyle, forKey: .toggleStyle)
        try c.encode(clockOpensNotificationCenter, forKey: .clockOpensNotificationCenter)
        // Always write the key (null when unset) so the stored JSON documents the field.
        try c.encode(hotKey, forKey: .hotKey)
        try c.encode(appRules.filter { $0.value != .auto }.mapValues(\.rawValue), forKey: .appRules)
    }
}

/// One stored rule value; anything that is not a known rule string decodes as nil (skipped).
private struct LenientRule: Decodable {
    let rule: AppVisibilityRule?

    init(from decoder: Decoder) throws {
        rule = (try? decoder.singleValueContainer().decode(String.self)).flatMap(AppVisibilityRule.init(rawValue:))
    }
}
