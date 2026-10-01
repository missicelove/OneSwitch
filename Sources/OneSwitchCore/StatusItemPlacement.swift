import AppKit

/// Initial placement of OneSwitch's own status items.
///
/// On macOS 27 the menu bar is laid out by the system (MenuBarAgent). An item's position is remembered as
/// `"NSStatusItem Preferred Position <autosaveName>"` in the app's standard defaults — the distance from
/// the trailing (right) screen edge, used for ordering (smaller = further right). Items without a saved
/// position are appended at the far LEFT, where a crowded (notched) menu bar tucks them into the system
/// « overflow first. Seeding a position before the autosave name is assigned puts our items next to the
/// system items instead. A position the user created by ⌘-dragging is never overwritten.
public enum StatusItemPlacement {
    /// Suggested distances from the trailing edge (right of all third-party items, left of system items).
    public enum Slot {
        public static let mainIcon: Double = 410
        public static let monitorBase: Double = 420      // + index; larger = further left
        public static let hiderToggle: Double = 440
        public static let hiderSeparator: Double = 441
        public static let hiderAlwaysHidden: Double = 442
    }

    public static func key(for autosaveName: String) -> String {
        "NSStatusItem Preferred Position \(autosaveName)"
    }

    /// Writes an initial preferred position for `autosaveName` unless one exists. Call BEFORE setting
    /// `statusItem.autosaveName` (AppKit reads the saved position when the name is assigned).
    public static func seed(autosaveName: String, distanceFromTrailingEdge: Double) {
        let defaults = UserDefaults.standard
        let k = key(for: autosaveName)
        guard defaults.object(forKey: k) == nil else { return }
        defaults.set(distanceFromTrailingEdge, forKey: k)
        AppLog.info("statusitem", "seeded position \(Int(distanceFromTrailingEdge)) for \(autosaveName)")
    }
}
