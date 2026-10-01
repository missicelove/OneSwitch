import AppKit
import CoreGraphics

// Pure geometry used by the hider: coordinate conversion, menu-bar strip detection, separator-order
// safety, collapsed separator length and item classification. No state, fully unit-testable.
//
// Coordinate spaces:
// - AppKit: origin at the bottom-left of the primary screen, y up (NSWindow / NSScreen frames).
// - CG ("global display"): origin at the top-left of the primary screen, y down (CGEvent, AX, CGWindowList).
// x is identical in both spaces.

/// Snapshot of one screen's geometry (AppKit coordinates).
public struct ScreenGeometry: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top` (> 0 on screens with a camera housing / notch).
    public var safeAreaTop: CGFloat
    public var hasNotch: Bool

    public init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat = 0, hasNotch: Bool = false) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.hasNotch = hasNotch
    }

    @MainActor
    public init(_ screen: NSScreen) {
        self.init(frame: screen.frame,
                  visibleFrame: screen.visibleFrame,
                  safeAreaTop: screen.safeAreaInsets.top,
                  hasNotch: screen.safeAreaInsets.top > 0 || screen.auxiliaryTopLeftArea != nil)
    }

    /// All screens; the first one is the primary screen (the one whose origin is (0, 0)).
    @MainActor
    public static func current() -> [ScreenGeometry] {
        NSScreen.screens.map(ScreenGeometry.init)
    }
}

public enum MenuBarGeometry {
    /// Height of the menu-bar strip of `screen`. Uses the space reserved above `visibleFrame`; when the
    /// menu bar auto-hides (nothing reserved) falls back to the notch inset / status-bar thickness.
    public static func menuBarHeight(of screen: ScreenGeometry, thickness: CGFloat) -> CGFloat {
        let reserved = screen.frame.maxY - screen.visibleFrame.maxY
        if reserved >= 12 && reserved <= 80 { return reserved }
        return max(screen.safeAreaTop, thickness, 24)
    }

    /// True when `point` (AppKit coordinates, e.g. `NSEvent.mouseLocation`) lies in the menu-bar strip
    /// of the screen it is on.
    public static func isPointInMenuBar(_ point: CGPoint, screens: [ScreenGeometry], thickness: CGFloat) -> Bool {
        for screen in screens {
            let f = screen.frame
            // Inclusive on the top edge: the pointer can rest exactly at maxY.
            guard point.x >= f.minX, point.x <= f.maxX, point.y >= f.minY, point.y <= f.maxY + 1 else { continue }
            return point.y >= f.maxY - menuBarHeight(of: screen, thickness: thickness)
        }
        return false
    }

    /// AppKit rect → CG rect (`primaryMaxY` = height of the primary screen).
    public static func toCG(_ rect: CGRect, primaryMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// CG point → AppKit point.
    public static func toAppKit(_ point: CGPoint, primaryMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryMaxY - point.y)
    }

    /// The menu-bar strip of every screen, in CG coordinates.
    public static func menuBarBands(screens: [ScreenGeometry], thickness: CGFloat) -> [CGRect] {
        guard let primary = screens.first else { return [] }
        let primaryMaxY = primary.frame.maxY
        return screens.map { screen in
            let h = menuBarHeight(of: screen, thickness: thickness)
            let strip = CGRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
            return toCG(strip, primaryMaxY: primaryMaxY)
        }
    }

    /// True when a status-item window frame (AppKit coordinates) plausibly sits in a menu bar: its vertical
    /// centre is near the top edge of some screen. Rejects the transient frames AppKit reports right
    /// after an item is created (e.g. (0, -30)) before it slides into the bar. Items of an auto-hidden
    /// menu bar sit just above the screen and still count.
    public static func isPlausibleStatusItemFrame(_ frame: CGRect, screens: [ScreenGeometry]) -> Bool {
        guard frame.width > 0, frame.height > 0, frame.height <= 80 else { return false }
        return screens.contains { abs(frame.midY - $0.frame.maxY) <= 60 }
    }

    /// True when the vertical centre of `rect` (CG coordinates) is inside one of the menu-bar strips.
    /// x is deliberately ignored: items pushed off-screen to the left are still "in the menu bar".
    public static func isInMenuBar(_ rect: CGRect, bands: [CGRect], tolerance: CGFloat = 4) -> Bool {
        let midY = rect.midY
        return bands.contains { midY >= $0.minY - tolerance && midY <= $0.maxY + tolerance }
    }

    /// True when two status-item window frames are parked together. macOS 27 parks every item that has
    /// no room in the bar (it sits in the system "«" overflow) right-aligned to one anchor, each with its
    /// own placeholder width — measured on the notched MacBook Pro: toggle (902, 949, 27, 33), separator
    /// and 永久隐藏 separator (903, 949, 26, 33) (all end at x 929; with equal widths the frames are
    /// identical). Two laid-out items never overlap, so a shared right edge in the same row means parked.
    public static func areParkedTogether(_ a: CGRect, _ b: CGRect) -> Bool {
        a.width > 0 && b.width > 0 && abs(a.maxX - b.maxX) < 1
            && abs(a.minY - b.minY) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// Right edge (x, global) of the camera housing on a notched screen, from `NSScreen.auxiliaryTopRightArea`
    /// (the unobscured strip right of the notch always reaches the screen's right edge). nil without a notch.
    public static func notchMaxX(screenMaxX: CGFloat, auxiliaryTopRightWidth: CGFloat?) -> CGFloat? {
        guard let width = auxiliaryTopRightWidth, width > 0 else { return nil }
        return screenMaxX - width
    }
}

// MARK: - Separator order safety

/// Result of checking that the separators sit left of the toggle (so collapsing never hides the toggle).
public enum SeparatorOrder: Equatable, Sendable {
    case ok
    /// Frames not available yet (items not laid out).
    case unknown
    /// The separator is right of the toggle: collapsing would hide the toggle itself.
    case separatorRightOfToggle
    /// The 永久隐藏 separator is right of the normal separator (it would hide the normal section / toggle).
    case alwaysHiddenMisplaced
    /// The 永久隐藏 separator exists but has no reliable frame yet (just added) — don't widen it yet.
    case alwaysHiddenUnknown
    /// macOS 27: the bar has no room for the toggle — it and the separator are parked in the system "«"
    /// overflow (stacked on one right edge), so their real order is unknown. Typical on a crowded
    /// notched MacBook Pro right after launch, because new items are inserted left-most.
    case parkedInOverflow

    /// Collapsing the normal section is safe.
    public var allowsCollapse: Bool { self == .ok || self == .alwaysHiddenMisplaced || self == .alwaysHiddenUnknown }
    /// Widening the 永久隐藏 separator is safe.
    public var allowsAlwaysHidden: Bool { self == .ok }

    /// User-facing warning (nil when everything is fine).
    public var warning: String? {
        switch self {
        case .ok, .unknown, .alwaysHiddenUnknown: return nil
        case .separatorRightOfToggle: return "分隔线位置不正确：请按住 ⌘ 将分隔线拖到切换按钮左侧"
        case .alwaysHiddenMisplaced: return "永久隐藏分隔线位置不正确：请按住 ⌘ 将它拖到普通分隔线左侧"
        case .parkedInOverflow: return "菜单栏空间不足，切换按钮被系统收进了“«”，暂不隐藏图标：请减少菜单栏上显示的图标"
        }
    }

    /// Compares the items' window frames (any coordinate space, only x is used).
    /// - Parameter alwaysHiddenExpected: the 永久隐藏 separator exists (so a missing frame is "unknown").
    public static func check(toggle: CGRect?, separator: CGRect?, alwaysHidden: CGRect? = nil,
                             alwaysHiddenExpected: Bool = false) -> SeparatorOrder {
        guard let t = toggle, let s = separator, t.width > 0, s.width > 0 else { return .unknown }
        // Parked items are stacked on one anchor; that says nothing about the order the user chose.
        if MenuBarGeometry.areParkedTogether(t, s) { return .parkedInOverflow }
        if s.minX >= t.minX { return .separatorRightOfToggle }
        if let a = alwaysHidden, a.width > 0 {
            // Parked together with the separator: position unknown, don't widen it (and don't warn).
            if MenuBarGeometry.areParkedTogether(a, s) { return .alwaysHiddenUnknown }
            return a.minX >= s.minX ? .alwaysHiddenMisplaced : .ok
        }
        return alwaysHiddenExpected ? .alwaysHiddenUnknown : .ok
    }

    /// The status to assume right after the 永久隐藏 separator was added / removed while the real frames
    /// cannot be read (collapsed): never widen a freshly added separator before its position was verified.
    public func afterAlwaysHiddenChange(enabled: Bool) -> SeparatorOrder {
        switch self {
        case .ok where enabled: return .alwaysHiddenUnknown
        case .alwaysHiddenMisplaced where !enabled, .alwaysHiddenUnknown where !enabled: return .ok
        default: return self
        }
    }
}

// MARK: - Collapsed separator length

/// How a collapsed separator hides the items left of it.
public enum CollapseStrategy: String, Equatable, Sendable {
    /// macOS 14–26: an enormous item pushes everything left of it off-screen.
    case pushOffscreen
    /// macOS 27+: the bar no longer reflows around oversized items and *drops* any item whose window
    /// reaches half the screen width. An item just below that limit that does not fit next to the
    /// toggle is moved — together with every item left of it — into the system's "«" overflow.
    case systemOverflow

    public static func forMajorVersion(_ major: Int) -> CollapseStrategy {
        major >= 27 ? .systemOverflow : .pushOffscreen
    }

    public static var current: CollapseStrategy {
        forMajorVersion(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
}

public enum SeparatorMetrics {
    /// Length of a visible separator (thin line / dot).
    public static let expandedLength: CGFloat = 10
    /// Classic "push off-screen" length.
    public static let pushOffscreenLength: CGFloat = 10_000
    /// Default window padding around a status item's content (macOS 27 adds ~8 pt per side).
    public static let defaultWindowPadding: CGFloat = 16
    /// Safety margin below the macOS 27 half-screen limit.
    public static let overflowSafetyMargin: CGFloat = 16

    /// Length of the collapsed separator.
    /// - Parameters:
    ///   - screenWidth: width (pt) of the screen showing the menu bar item.
    ///   - windowPadding: measured `window.frame.width - statusItem.length` (padding the system adds).
    public static func collapsedLength(strategy: CollapseStrategy, screenWidth: CGFloat, windowPadding: CGFloat) -> CGFloat {
        switch strategy {
        case .pushOffscreen:
            return pushOffscreenLength
        case .systemOverflow:
            let padding = min(max(windowPadding, 8), 64)
            let limit = floor(screenWidth / 2) - padding - overflowSafetyMargin
            return max(limit, 120)
        }
    }
}

/// macOS 27: a single item can never be wider than half the screen, so on wide displays the collapsed
/// separator may still *fit* next to the toggle and leave some hidden icons visible further left.
/// Widening the toggle (its chevron stays at the right edge) by exactly the missing space makes the
/// separator overflow again. Needs the frontmost app's menu extent (Accessibility).
public enum OverflowPlanner {
    /// Space between the last app menu and the first status item.
    public static let menuGap: CGFloat = 8
    /// How far past "just doesn't fit" we aim, so width changes of items right of the toggle
    /// (e.g. live system-monitor text) don't make the separator fit again.
    public static let overflowMargin: CGFloat = 48
    /// Room the widened toggle must leave for the system "«" button (and rounding).
    public static let toggleRoom: CGFloat = 44
    /// Changes smaller than this are ignored (avoids constant resizing).
    public static let hysteresis: CGFloat = 8

    /// Left edge of the strip status items can occupy: right of the frontmost app's menus and, on a
    /// notched screen, right of the camera housing — status items are never laid out under the notch.
    /// Pass the result as `menusMaxX` to `toggleExtraWidth`. Without the notch term a MacBook Pro with
    /// short app menus got a toggle so wide that it (and the icons between it and the separator) were
    /// pushed into the "«" overflow, then un-padded, then padded again every few seconds.
    public static func statusAreaMinX(menusMaxX: CGFloat, notchMaxX: CGFloat?) -> CGFloat {
        guard let notchMaxX else { return menusMaxX }
        return max(menusMaxX, notchMaxX)
    }

    /// Extra width for the collapsed toggle (0 = none needed / not possible).
    /// - Parameters:
    ///   - toggleMaxX: right edge of the toggle window (anchored by the items right of it).
    ///   - toggleWindowWidth: the toggle's natural window width (variable length, not widened).
    ///   - itemsBetween: width of the (always visible) icons between the separator and the toggle,
    ///     measured while expanded; they must keep fitting.
    ///   - separatorWindowWidth: collapsed separator length + window padding.
    ///   - menusMaxX: right edge of the frontmost app's menus on that screen.
    ///   - screenWidth: the toggle window must also stay below half of it (or macOS 27 drops it).
    public static func toggleExtraWidth(toggleMaxX: CGFloat, toggleWindowWidth: CGFloat, itemsBetween: CGFloat = 0,
                                        separatorWindowWidth: CGFloat, menusMaxX: CGFloat,
                                        screenWidth: CGFloat) -> CGFloat {
        let available = toggleMaxX - toggleWindowWidth - max(0, itemsBetween) - (menusMaxX + menuGap)
        let needed = available - separatorWindowWidth + overflowMargin
        guard needed > 0 else { return 0 }
        let maxExtra = min(available - toggleRoom,
                           floor(screenWidth / 2) - SeparatorMetrics.overflowSafetyMargin - toggleWindowWidth)
        guard maxExtra > 0 else { return 0 }
        return min(needed, maxExtra).rounded(.up)
    }

    /// Applies hysteresis to a newly computed extra width.
    public static func settle(current: CGFloat, proposed: CGFloat) -> CGFloat {
        if proposed == 0 || current == 0 { return proposed }
        return abs(proposed - current) < hysteresis ? current : proposed
    }
}

// MARK: - Classification

/// Which part of the menu bar an item is in.
public enum MenuBarSection: String, Codable, Equatable, Sendable, CaseIterable {
    /// Right of the separator — always shown.
    case visible
    /// Between the 永久隐藏 separator (if any) and the separator — shown when expanded.
    case hidden
    /// Left of the 永久隐藏 separator — shown only via ⌥-click.
    case alwaysHidden
    /// Parked in the macOS 27 "«" overflow (did not fit).
    case overflow
    /// Not in the menu bar at all (e.g. turned off in 系统设置 → 菜单栏).
    case offscreen

    public var title: String {
        switch self {
        case .visible: return "显示区"
        case .hidden: return "隐藏区"
        case .alwaysHidden: return "永久隐藏区"
        case .overflow: return "已被系统收起"
        case .offscreen: return "未显示"
        }
    }
}

/// Reference positions (x, any space — only x is compared) of our own items, read while expanded.
public struct MenuBarAnchors: Equatable, Sendable {
    public var toggle: CGRect
    public var separator: CGRect
    public var alwaysHidden: CGRect?

    public init(toggle: CGRect, separator: CGRect, alwaysHidden: CGRect? = nil) {
        self.toggle = toggle
        self.separator = separator
        self.alwaysHidden = alwaysHidden
    }
}

public enum MenuBarClassifier {
    /// Classifies one item.
    /// - Parameters:
    ///   - frame: item frame in CG coordinates.
    ///   - anchors: our separators (CG or AppKit — only x is used), captured while expanded.
    ///   - bands: menu-bar strips in CG coordinates.
    ///   - overflowChevron: frame of the macOS 27 "«" button (CG), when present.
    ///   - isParked: the item shares its exact position with another item (macOS 27 parks overflowed items).
    public static func classify(frame: CGRect,
                                anchors: MenuBarAnchors,
                                bands: [CGRect],
                                overflowChevron: CGRect? = nil,
                                isParked: Bool = false) -> MenuBarSection {
        guard frame.width > 0, MenuBarGeometry.isInMenuBar(frame, bands: bands) else { return .offscreen }
        if isParked { return .overflow }
        if let chevron = overflowChevron, chevron.width > 0,
           frame.minX < chevron.maxX, frame.maxX > chevron.minX {
            return .overflow
        }
        let midX = frame.midX
        if midX > anchors.separator.midX { return .visible }
        if let ah = anchors.alwaysHidden, ah.width > 0, midX < ah.midX { return .alwaysHidden }
        return .hidden
    }

    /// Indices of items stacked on top of another item (same x within 0.5 pt and overlapping) —
    /// how macOS 27 parks items that went into the overflow.
    public static func parkedIndices(_ frames: [CGRect]) -> Set<Int> {
        var result = Set<Int>()
        for i in frames.indices {
            for j in frames.indices where j > i {
                let a = frames[i], b = frames[j]
                guard a.width > 0, b.width > 0 else { continue }
                if abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 {
                    result.insert(i)
                    result.insert(j)
                }
            }
        }
        return result
    }
}
