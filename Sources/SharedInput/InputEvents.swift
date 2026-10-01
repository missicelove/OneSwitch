import CoreGraphics
import Foundation

/// Scroll-wheel fields needed to reproduce smooth (trackpad / Magic Mouse) scrolling on the other Mac.
public struct ScrollData: Equatable, Sendable {
    public var delta1: Int64 = 0
    public var delta2: Int64 = 0
    public var point1: Int64 = 0
    public var point2: Int64 = 0
    public var fixed1: Double = 0
    public var fixed2: Double = 0
    public var isContinuous: Int64 = 0
    public var scrollPhase: Int64 = 0
    public var momentumPhase: Int64 = 0
    public var scrollCount: Int64 = 0

    public init() {}
}

/// An input event observed by the server's event tap, reduced to what the switching logic needs.
/// Mouse buttons use CGMouseButton numbering (0 = left, 1 = right, 2+ = other).
public enum CapturedKind: Equatable, Sendable {
    case mouseMoved
    case mouseDown(button: Int)
    case mouseUp(button: Int)
    case mouseDragged(button: Int)
    case scroll(ScrollData)
    case keyDown(keyCode: UInt16, autorepeat: Bool)
    case keyUp(keyCode: UInt16)
    case flagsChanged(keyCode: UInt16)
    /// NX_SYSDEFINED (media / brightness / volume keys use subtype 8).
    case systemDefined(subtype: Int16, data1: Int64, data2: Int64)
}

public struct CapturedEvent: Equatable, Sendable {
    public var kind: CapturedKind
    /// Global display coordinates (top-left origin), as reported by CGEvent.location.
    public var location: CGPoint
    public var dx: Double
    public var dy: Double
    public var clickState: Int64
    /// CGEventFlags raw value.
    public var flags: UInt64
    /// Scroll events: macOS already inverted the deltas relative to the device (natural scrolling is on),
    /// i.e. `NSEvent.isDirectionInvertedFromDevice`.
    public var scrollInverted: Bool

    public init(kind: CapturedKind, location: CGPoint = .zero, dx: Double = 0, dy: Double = 0,
                clickState: Int64 = 0, flags: UInt64 = 0, scrollInverted: Bool = false) {
        self.kind = kind
        self.location = location
        self.dx = dx
        self.dy = dy
        self.clickState = clickState
        self.flags = flags
        self.scrollInverted = scrollInverted
    }
}

/// Mouse-wheel maths shared by server (direction) and client (distance). Pure; covered by the checks.
public enum WheelMath {
    /// Sign to multiply a non-continuous (wheel) scroll's deltas with, so that the result follows `style`
    /// whatever this Mac's own natural-scrolling setting is. CG convention: positive = wheel rolled away
    /// from the user = show the content above (classic / Windows direction).
    public static func directionFactor(invertedFromDevice: Bool, style: WheelDirection) -> Int64 {
        let physical: Int64 = invertedFromDevice ? -1 : 1 // undo macOS's natural-scrolling inversion
        return style == .windows ? physical : -physical
    }

    /// `s` with its direction set to `style` (both axes). Continuous input is never passed here.
    public static func applyDirection(_ s: ScrollData, invertedFromDevice: Bool, style: WheelDirection) -> ScrollData {
        let f = directionFactor(invertedFromDevice: invertedFromDevice, style: style)
        guard f != 1 else { return s }
        var out = s
        out.delta1 = -s.delta1; out.delta2 = -s.delta2
        out.point1 = -s.point1; out.point2 = -s.point2
        out.fixed1 = -s.fixed1; out.fixed2 = -s.fixed2
        return out
    }

    /// Multiplier per speed level 1…5 applied to the wheel's (macOS-accelerated) pixel distance.
    /// Level 3 equals Mos's default speed (2.7), so the client feels like a Mac running Mos.
    public static let speedMultipliers: [Double] = [1.4, 2.0, 2.7, 3.6, 4.8]

    public static func multiplier(speed: Int) -> Double {
        speedMultipliers[min(max(speed, 1), speedMultipliers.count) - 1]
    }

    /// Largest distance (pixels) one wheel event may add; guards against absurd deltas.
    public static let maxPixelsPerEvent = 4000.0

    /// Pixel distance (vertical, horizontal) to scroll for one non-continuous wheel event.
    public static func pixels(for s: ScrollData, speed: Int) -> (dy: Double, dx: Double) {
        let m = multiplier(speed: speed)
        return (axis(point: s.point1, fixed: s.fixed1, lines: s.delta1) * m,
                axis(point: s.point2, fixed: s.fixed2, lines: s.delta2) * m)
    }

    /// ⇧ + mouse wheel scrolls sideways. AppKit does that conversion only for plain (non-continuous) wheel
    /// events — verified: a line event (wheel1 3, ⇧) reads as scrollingDelta x 3 / y 0, while a pixel event
    /// with a scroll phase keeps y. The client replays the wheel as continuous gestures, so it applies the
    /// same rule itself: with ⇧ held the vertical distance becomes horizontal (a horizontal part is then
    /// dropped); without a vertical part the horizontal one stays.
    public static func applyShift(dy: Double, dx: Double, flags: UInt64) -> (dy: Double, dx: Double) {
        guard flags & CGEventFlags.maskShift.rawValue != 0 else { return (dy, dx) }
        return (0, dy != 0 ? dy : dx)
    }

    private static func axis(point: Int64, fixed: Double, lines: Int64) -> Double {
        let base: Double
        if point != 0 {
            base = Double(point)
        } else if fixed != 0, fixed.isFinite {
            base = fixed * 10
        } else {
            base = Double(lines) * 10
        }
        guard base != 0 else { return 0 }
        let magnitude = min(max(abs(base), 1), maxPixelsPerEvent)
        return base < 0 ? -magnitude : magnitude
    }
}

public enum ModifierKeys {
    /// Device-independent modifier masks we care about.
    public static let relevantMask: UInt64 = CGEventFlags.maskShift.rawValue
        | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue
        | CGEventFlags.maskCommand.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue

    /// The CGEventFlags mask a modifier key toggles, or nil for non-modifier keys.
    public static func mask(forKeyCode keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case 55, 54: return CGEventFlags.maskCommand.rawValue      // ⌘ left/right
        case 56, 60: return CGEventFlags.maskShift.rawValue        // ⇧
        case 58, 61: return CGEventFlags.maskAlternate.rawValue    // ⌥
        case 59, 62: return CGEventFlags.maskControl.rawValue      // ⌃
        case 57: return CGEventFlags.maskAlphaShift.rawValue       // ⇪
        case 63: return CGEventFlags.maskSecondaryFn.rawValue      // fn
        default: return nil
        }
    }

    /// Device-dependent bit (NX_DEVICE*KEYMASK, low bits of CGEventFlags) telling left and right modifier
    /// keys apart. Nil for keys without one (caps lock, fn, non-modifiers).
    public static func deviceMask(forKeyCode keyCode: UInt16) -> UInt64? {
        switch keyCode {
        case 59: return 0x0000_0001  // left ⌃
        case 56: return 0x0000_0002  // left ⇧
        case 60: return 0x0000_0004  // right ⇧
        case 55: return 0x0000_0008  // left ⌘
        case 54: return 0x0000_0010  // right ⌘
        case 58: return 0x0000_0020  // left ⌥
        case 61: return 0x0000_0040  // right ⌥
        case 62: return 0x0000_2000  // right ⌃
        default: return nil
        }
    }

    /// All device-dependent modifier bits.
    public static let deviceMaskAll: UInt64 = 0x0000_207F

    /// Whether the modifier `keyCode` is down according to `flags` (nil for non-modifier keys). Uses the
    /// left/right device bits when the event carries them, so releasing left ⇧ while right ⇧ is still held
    /// is recognised as a release; falls back to the device-independent mask otherwise.
    public static func isDown(keyCode: UInt16, flags: UInt64) -> Bool? {
        guard let mask = mask(forKeyCode: keyCode) else { return nil }
        if let device = deviceMask(forKeyCode: keyCode), flags & deviceMaskAll != 0 {
            return flags & device != 0
        }
        return flags & mask != 0
    }

    /// Modifier keys (⌘⌥⌃⇧ left/right, fn) that `flags` says are held. Without left/right device bits both
    /// sides of a held modifier are reported. Caps lock is a toggle, not a held key, and is not included.
    public static func heldModifierKeys(flags: UInt64) -> Set<UInt16> {
        let hasDeviceBits = flags & deviceMaskAll != 0
        var keys = Set<UInt16>()
        for keyCode: UInt16 in [55, 54, 56, 60, 58, 61, 59, 62, 63] {
            guard let m = mask(forKeyCode: keyCode), flags & m != 0 else { continue }
            if hasDeviceBits, let device = deviceMask(forKeyCode: keyCode) {
                if flags & device != 0 { keys.insert(keyCode) }
            } else {
                keys.insert(keyCode)
            }
        }
        return keys
    }

    /// Converts NSEvent-style hotkey modifiers (HotKey.modifierFlags) into CGEventFlags bits.
    public static func cgMask(fromHotKeyModifiers modifiers: UInt) -> UInt64 {
        var mask: UInt64 = 0
        let flags = NSEventModifierBits(rawValue: modifiers)
        if flags.contains(.shift) { mask |= CGEventFlags.maskShift.rawValue }
        if flags.contains(.control) { mask |= CGEventFlags.maskControl.rawValue }
        if flags.contains(.option) { mask |= CGEventFlags.maskAlternate.rawValue }
        if flags.contains(.command) { mask |= CGEventFlags.maskCommand.rawValue }
        return mask
    }
}

/// NSEvent.ModifierFlags bit layout, without importing AppKit into the pure logic layer.
struct NSEventModifierBits: OptionSet {
    let rawValue: UInt
    static let shift = NSEventModifierBits(rawValue: 1 << 17)
    static let control = NSEventModifierBits(rawValue: 1 << 18)
    static let option = NSEventModifierBits(rawValue: 1 << 19)
    static let command = NSEventModifierBits(rawValue: 1 << 20)
}
