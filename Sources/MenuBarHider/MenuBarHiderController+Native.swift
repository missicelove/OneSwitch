import AppKit
import OneSwitchCore

/// One row of the 系统原生隐藏 app list in the settings page.
public struct NativeAppRow: Identifiable, Equatable {
    public var key: String
    public var bundleID: String?
    public var name: String
    /// The icons' own labels / counts, shown under the name.
    public var detail: String?
    public var icon: NSImage?
    /// nil = not in the menu bar right now (not running, or no icon) but a rule is stored.
    public var placement: AppPlacement?
    public var rule: AppVisibilityRule
    /// Hidden while collapsed (rule + placement).
    public var hides: Bool
    public var isSystem: Bool
    public var id: String { key }

    public static func == (a: NativeAppRow, b: NativeAppRow) -> Bool {
        a.key == b.key && a.name == b.name && a.detail == b.detail && a.placement == b.placement
            && a.rule == b.rule && a.hides == b.hides && a.isSystem == b.isSystem
    }
}

extension MenuBarHiderController {
    // MARK: - Texts

    /// "系统原生隐藏" / "兼容模式" (macOS 27 fallback) / "分隔线模式" (macOS 14–26).
    public var engineTitle: String {
        Self.engineTitle(engineKind, strategy: strategy)
    }

    public static func engineTitle(_ kind: HidingEngineKind, strategy: CollapseStrategy) -> String {
        switch kind {
        case .native: return "系统原生隐藏"
        case .legacy: return strategy == .systemOverflow ? "兼容模式" : "分隔线模式"
        }
    }

    /// Number of apps whose icons the active restriction hides (native, collapsed).
    public var hiddenAppCount: Int? {
        guard engineKind == .native, visibility == .collapsed else { return nil }
        return nativeHiddenBundles?.count
    }

    /// Title of the action that shows every icon, also the ones that do not fit (they go into the «).
    public static let showAllIconsTitle = "显示全部图标（使用系统「«」）"

    /// Shown while expanded when not every hidden app fits (nil otherwise).
    public var nativeRevealNote: String? {
        guard engineKind == .native, isActive, visibility == .expanded, let plan = nativeRevealPlan, !plan.allFit else { return nil }
        return Self.revealNote(unfit: plan.unfit.count, notched: plan.notched)
    }

    /// "还有 3 个 App 的图标放不下（刘海右侧空间不足）".
    public static func revealNote(unfit: Int, notched: Bool) -> String {
        let reason = notched ? "刘海右侧空间不足" : "菜单栏空间不足"
        return unfit > 0 ? "还有 \(unfit) 个 App 的图标放不下（\(reason)）" : "新打开的 App 的图标暂未显示（\(reason)）"
    }

    /// Offer「显示全部图标」: some icons are held back right now, or were at the last reveal.
    var offersShowAllIcons: Bool {
        guard engineKind == .native, isActive else { return false }
        switch visibility {
        case .expanded: return nativeRevealPlan.map { !$0.allFit } ?? false
        case .collapsed: return nativeLastRevealPartial
        case .expandedAll: return false
        }
    }

    /// Informational note for the native mode (permission / toggle position), nil when all is well.
    public var nativeNote: String? {
        guard engineKind == .native, isActive, let engine = nativeEngine else { return nil }
        if !engine.isAuthorized {
            return "未授予“辅助功能”权限：无法读取图标位置，收起时只隐藏设为“始终隐藏”的 App"
        }
        if let layout = nativeLayout, layout.toggleOverflowed {
            return "菜单栏太挤，「<」被系统收进了「«」：收起时会隐藏所有“自动”的 App，腾出位置后「<」会回到菜单栏。想一直看到的 App 请在下方设为“始终显示”"
        }
        if let layout = nativeLayout, !layout.toggleUsable {
            return "暂时读不到「<」的位置，按上次读取的位置判断"
        }
        return nil
    }

    // MARK: - Rules

    public func rule(for bundleID: String) -> AppVisibilityRule {
        current.rule(for: bundleID)
    }

    public func setRule(_ rule: AppVisibilityRule, for bundleID: String) {
        store.update { $0.setRule(rule, for: bundleID) }
    }

    // MARK: - App list

    /// Rows for the settings list: every app with menu-bar icons (last read positions), then apps that
    /// have a rule but no icon right now.
    public func nativeAppRows(rules: [String: AppVisibilityRule]? = nil) -> [NativeAppRow] {
        let rules = rules ?? current.appRules
        var rows: [NativeAppRow] = []
        var listed = Set<String>()
        for app in nativeLayout?.apps ?? [] {
            let rule = app.bundleID.map { rules[$0] ?? .auto } ?? .alwaysShow
            var parts: [String] = []
            if app.itemCount > 1 { parts.append("\(app.itemCount) 个图标") }
            parts += app.details.filter { $0 != app.name }
            rows.append(NativeAppRow(key: app.key, bundleID: app.bundleID, name: app.name,
                                     detail: parts.isEmpty ? nil : parts.joined(separator: " · "),
                                     icon: icon(bundleID: app.bundleID, pid: app.pid), placement: app.placement,
                                     rule: rule,
                                     hides: app.bundleID != nil && NativeHidingPlan.shouldHide(rule: rule, placement: app.placement),
                                     isSystem: app.isSystem))
            if let bundle = app.bundleID { listed.insert(bundle) }
        }
        for (bundle, rule) in rules.sorted(by: { $0.key < $1.key }) where !listed.contains(bundle) {
            rows.append(NativeAppRow(key: bundle, bundleID: bundle, name: Self.appName(bundleID: bundle),
                                     detail: "当前没有菜单栏图标", icon: icon(bundleID: bundle, pid: nil), placement: nil,
                                     rule: rule, hides: rule == .alwaysHide, isSystem: bundle.hasPrefix("com.apple.")))
        }
        return rows
    }

    /// Re-reads which apps have menu-bar icons. Positions are only valid while nothing is hidden, so a
    /// collapsed bar is revealed for the read (like the auto-hide, it collapses again afterwards).
    public func refreshNativeApps() {
        guard engineKind == .native, currentTask == nil else { return }
        currentTask = Task { [weak self] in
            await self?.performNativeRefresh()
            self?.currentTask = nil
        }
    }

    private func performNativeRefresh() async {
        guard let engine = nativeEngine else { return }
        nativeListBusy = true
        defer { nativeListBusy = false }
        let token = beginArranging()
        defer { endArranging(token) }
        if token.changed { try? await Task.sleep(nanoseconds: 700_000_000) } // let macOS reflow the bar
        guard !Task.isCancelled, started, engineKind == .native else { return }
        let layout: NativeLayout? = await withCheckedContinuation { continuation in
            engine.refreshLayout { continuation.resume(returning: $0) }
        }
        nativeLastScan = Date()
        AppLog.info("menubar", "native list: \(layout?.apps.count ?? 0) app(s) with menu-bar icons")
    }

    // MARK: - Icons / names

    func icon(bundleID: String?, pid: pid_t?) -> NSImage? {
        let key = bundleID ?? pid.map { "pid\($0)" } ?? ""
        if let cached = iconCache[key] { return cached }
        var image: NSImage?
        if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            image = app.icon
        }
        if image == nil, let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        if let image { iconCache[key] = image }
        return image
    }

    static func appName(bundleID: String) -> String {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first, let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}
