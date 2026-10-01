import AppKit
import ApplicationServices
import CoreGraphics
import os

/// A menu-bar item of some app, as found by `MenuBarItemScanner` (CG coordinates).
public struct MenuBarItemInfo: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable {
        case accessibility, windowList
    }

    /// Stable key: owner + identifier + ordinal among the owner's items.
    public var id: String
    public var pid: pid_t
    /// Owning app's name (or, for Apple's system extras, the item's own name such as "Wi‑Fi").
    public var name: String
    /// Extra description (title / AX description), nil when it would repeat `name`.
    public var detail: String?
    public var bundleID: String?
    public var identifier: String?
    public var frame: CGRect
    public var source: Source
    public var isSystemItem: Bool
    /// False for items macOS never lets you move (clock, 控制中心).
    public var isMovable: Bool
    /// Filled in by classification.
    public var section: MenuBarSection = .visible

    public init(id: String, pid: pid_t, name: String, detail: String? = nil, bundleID: String? = nil,
                identifier: String? = nil, frame: CGRect, source: Source, isSystemItem: Bool, isMovable: Bool) {
        self.id = id
        self.pid = pid
        self.name = name
        self.detail = detail
        self.bundleID = bundleID
        self.identifier = identifier
        self.frame = frame
        self.source = source
        self.isSystemItem = isSystemItem
        self.isMovable = isMovable
    }
}

/// A running app to inspect (collected on the main thread, scanned off-main).
public struct RunningAppInfo: Sendable, Hashable {
    public var pid: pid_t
    public var name: String
    public var bundleID: String?

    public init(pid: pid_t, name: String, bundleID: String?) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
    }

    /// Running apps that can own status items (background-only processes cannot show any UI).
    @MainActor
    public static func current() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited && !$0.isTerminated }
            .map {
                RunningAppInfo(pid: $0.processIdentifier,
                               name: $0.localizedName ?? $0.bundleIdentifier ?? "PID \($0.processIdentifier)",
                               bundleID: $0.bundleIdentifier)
            }
    }
}

/// Result of one scan.
public struct MenuBarScanResult: Sendable {
    public var items: [MenuBarItemInfo]
    /// Which source produced `items` (nil when nothing was found).
    public var source: MenuBarItemInfo.Source?
    /// The macOS 27 "«" overflow button (CG coordinates), when present.
    public var overflowChevron: CGRect?
    public var accessibilityGranted: Bool
    /// Human-readable (Chinese) note about the scan, e.g. why the list is empty.
    public var note: String?
}

/// Lists menu-bar items of other apps. Blocking IPC — call only from a background queue.
///
/// Sources (probed on macOS 27.0.1):
/// 1. Accessibility (`AXExtrasMenuBar` of each app) — works on macOS 27; needs 辅助功能. Apple's own
///    extras (Wi‑Fi, 时钟, 控制中心…) are hosted by `com.apple.MenuBarAgent` as AXGroup → AXMenuBarItem with
///    `com.apple.menuextra.*` identifiers; the "«" overflow is an AXButton of MenuBarAgent.
/// 2. `CGWindowListCopyWindowInfo` status windows (layer 25) — works up to macOS 26; macOS 27 draws the
///    whole bar as a single window, so this returns nothing there. Used as fallback only.
public enum MenuBarItemScanner {
    static let menuBarAgentBundleID = "com.apple.MenuBarAgent"
    /// Apple extras that cannot be ⌘-dragged.
    static let immovableIdentifiers: Set<String> = ["com.apple.menuextra.clock", "com.apple.menuextra.controlcenter"]
    static let systemOwnerNames: Set<String> = ["Window Server", "Control Center", "控制中心", "SystemUIServer", "MenuBarAgent"]
    /// Per-element AX messaging timeout (seconds). Must be set on every element: AX elements returned by
    /// another call do not inherit it.
    static let axTimeout: Float = 0.25

    public static func scan(apps: [RunningAppInfo], excludingPID ownPID: pid_t, bands: [CGRect]) -> MenuBarScanResult {
        let trusted = AXIsProcessTrusted()
        var result = MenuBarScanResult(items: [], source: nil, overflowChevron: nil, accessibilityGranted: trusted, note: nil)
        if trusted {
            let ax = scanAccessibility(apps: apps, excludingPID: ownPID)
            result.overflowChevron = ax.chevron
            if !ax.items.isEmpty {
                result.items = ax.items
                result.source = .accessibility
                return result
            }
        }
        let windows = scanWindowList(apps: apps, excludingPID: ownPID, bands: bands)
        if !windows.isEmpty {
            result.items = windows
            result.source = .windowList
            if !trusted { result.note = "未授权辅助功能，列表来自窗口信息，可能不完整" }
        } else if !trusted {
            result.note = "需要“辅助功能”权限才能读取菜单栏图标"
        } else {
            result.note = "没有找到其他应用的菜单栏图标"
        }
        return result
    }

    // MARK: Accessibility

    static func scanAccessibility(apps: [RunningAppInfo], excludingPID ownPID: pid_t) -> (items: [MenuBarItemInfo], chevron: CGRect?) {
        // Each AX round-trip costs ~20 ms, so query the apps concurrently (AX is thread-safe) and
        // merge in the original order.
        let targets = apps.filter { $0.pid != ownPID && $0.pid > 0 }
        let results = OSAllocatedUnfairLock(initialState: [Int: (items: [MenuBarItemInfo], chevron: CGRect?)]())
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            let scanned = scanApp(targets[index])
            results.withLock { $0[index] = scanned }
        }
        let byIndex = results.withLock { $0 }
        var items: [MenuBarItemInfo] = []
        var chevron: CGRect?
        for index in targets.indices {
            guard let r = byIndex[index] else { continue }
            items += r.items
            if let c = r.chevron { chevron = c }
        }
        return (items, chevron)
    }

    private static func scanApp(_ app: RunningAppInfo) -> (items: [MenuBarItemInfo], chevron: CGRect?) {
        var items: [MenuBarItemInfo] = []
        var chevron: CGRect?
        let appElement = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)
        guard let bar: AXUIElement = copyAttribute(appElement, "AXExtrasMenuBar") else { return ([], nil) }
        // Elements returned by AX use the global default timeout (~6 s), not the app element's.
        AXUIElementSetMessagingTimeout(bar, axTimeout)
        let children: [AXUIElement] = copyAttribute(bar, kAXChildrenAttribute) ?? []
        let isAgent = app.bundleID == menuBarAgentBundleID
        var ordinal = 0
        for child in children {
            AXUIElementSetMessagingTimeout(child, axTimeout)
            guard let frame = frame(of: child) else { continue }
            let role: String? = copyAttribute(child, kAXRoleAttribute)
            if isAgent && role == (kAXButtonRole as String) {
                chevron = frame // the "«" overflow button
                continue
            }
            // Apple extras: AXGroup (hosting view) whose first child is the real AXMenuBarItem.
            var element = child
            if role == (kAXGroupRole as String),
               let inner: [AXUIElement] = copyAttribute(child, kAXChildrenAttribute), let first = inner.first {
                element = first
                AXUIElementSetMessagingTimeout(element, axTimeout)
            }
            let identifier: String? = nonEmpty(copyAttribute(element, kAXIdentifierAttribute))
            let title: String? = nonEmpty(copyAttribute(element, kAXTitleAttribute))
            var desc: String? = nonEmpty(copyAttribute(element, kAXDescriptionAttribute))
            if desc == nil, let attributed: NSAttributedString = copyAttribute(element, "AXAttributedDescription") {
                desc = nonEmpty(attributed.string)
            }
            let help: String? = nonEmpty(copyAttribute(element, kAXHelpAttribute))
            let label = (title ?? desc ?? help).map(singleLine)

            let name: String
            let detail: String?
            if isAgent {
                name = shortName(label) ?? shortName(identifier.map(extraName)) ?? "系统图标"
                detail = label.flatMap { $0 == name ? nil : $0 }
            } else {
                name = app.name
                detail = label.flatMap { $0 == app.name ? nil : $0 }
            }
            let key = itemKey(owner: app.bundleID ?? "pid\(app.pid)", identifier: identifier, ordinal: ordinal)
            ordinal += 1
            let isSystem = isAgent || (app.bundleID?.hasPrefix("com.apple.") ?? false)
            items.append(MenuBarItemInfo(id: key, pid: app.pid, name: name, detail: detail, bundleID: app.bundleID,
                                         identifier: identifier, frame: frame, source: .accessibility,
                                         isSystemItem: isSystem,
                                         isMovable: !(identifier.map(immovableIdentifiers.contains) ?? false)))
        }
        return (items, chevron)
    }

    /// Right edge (x, global) of the menus of the app that owns the menu bar, limited to the screen
    /// x-range `screenMinX...screenMaxX`. Needs Accessibility; nil when unavailable. Off-main only.
    public static func appMenusMaxX(pid: pid_t, screenMinX: CGFloat, screenMaxX: CGFloat) -> CGFloat? {
        appMenusExtent(pid: pid, screenMinX: screenMinX, screenMaxX: screenMaxX)?.upperBound
    }

    /// x-range (global) of the menus of the app that owns the menu bar, limited to the screen x-range
    /// `screenMinX...screenMaxX` (the left end matters in a right-to-left UI) and, when `band` (CG) is given,
    /// to menus in that menu-bar strip. Needs Accessibility; nil when unavailable. Off-main only.
    public static func appMenusExtent(pid: pid_t, screenMinX: CGFloat, screenMaxX: CGFloat,
                                      band: CGRect? = nil) -> ClosedRange<CGFloat>? {
        guard AXIsProcessTrusted(), pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)
        guard let bar: AXUIElement = copyAttribute(appElement, kAXMenuBarAttribute) else { return nil }
        // A busy frontmost app must not stall this (serial) queue for the ~6 s default per child call.
        AXUIElementSetMessagingTimeout(bar, axTimeout)
        let children: [AXUIElement] = copyAttribute(bar, kAXChildrenAttribute) ?? []
        children.forEach { AXUIElementSetMessagingTimeout($0, axTimeout) }
        let frames = children.compactMap(frame(of:)).filter { menu in
            menu.width > 0 && menu.minX >= screenMinX - 1 && menu.minX < screenMaxX
                && (band.map { NativeLayoutResolver.isInBar(menu, bands: [$0]) } ?? true)
        }
        guard let minX = frames.map(\.minX).min(), let maxX = frames.map(\.maxX).max() else { return nil }
        return minX...maxX
    }

    // MARK: Window list

    static func scanWindowList(apps: [RunningAppInfo], excludingPID ownPID: pid_t, bands: [CGRect]) -> [MenuBarItemInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let byPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var ordinals: [String: Int] = [:]
        var items: [MenuBarItemInfo] = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == statusLevel,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 0, bounds.height <= 60,
                  MenuBarGeometry.isInMenuBar(bounds, bands: bands) else { continue }
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? byPID[pid]?.name ?? "PID \(pid)"
            let title = nonEmpty(window[kCGWindowName as String] as? String).map(singleLine) // needs 屏幕录制
            let app = byPID[pid]
            let ownerKey = app?.bundleID ?? "pid\(pid)"
            let ordinal = ordinals[ownerKey, default: 0]
            ordinals[ownerKey] = ordinal + 1
            items.append(MenuBarItemInfo(id: itemKey(owner: ownerKey, identifier: nil, ordinal: ordinal),
                                         pid: pid, name: app?.name ?? owner, detail: title,
                                         bundleID: app?.bundleID, identifier: nil, frame: bounds, source: .windowList,
                                         isSystemItem: systemOwnerNames.contains(owner) || (app?.bundleID?.hasPrefix("com.apple.") ?? false),
                                         isMovable: true))
        }
        return items.sorted { $0.frame.minX < $1.frame.minX }
    }

    // MARK: Helpers (internal for checks)

    /// "Wi‑Fi，已接入，3格" → "Wi‑Fi"; trims whitespace; nil for empty.
    public static func shortName(_ label: String?) -> String? {
        guard let label = nonEmpty(label) else { return nil }
        let separators: Set<Character> = ["，", ",", "；", ";", "："]
        let head = label.split(whereSeparator: { separators.contains($0) }).first.map(String.init) ?? label
        return nonEmpty(head)
    }

    /// Collapses line breaks / runs of whitespace ("Syncthing v2\nUp to date" → "Syncthing v2 Up to date").
    public static func singleLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isNewline || $0 == "\t" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "com.apple.menuextra.wifi" → "wifi".
    static func extraName(_ identifier: String) -> String {
        identifier.split(separator: ".").last.map(String.init) ?? identifier
    }

    public static func itemKey(owner: String, identifier: String?, ordinal: Int) -> String {
        if let identifier, !identifier.isEmpty { return "\(owner)|\(identifier)" }
        return "\(owner)|#\(ordinal)"
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func copyAttribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, let sizeValue,
              CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
}
