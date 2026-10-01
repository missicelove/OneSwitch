import AppKit
import Carbon.HIToolbox
import OneSwitchCore

/// Which Mac shares its physical keyboard & mouse.
public enum InputRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case server
    case client

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .server: return "服务端（共享本机的键盘鼠标）"
        case .client: return "客户端（由另一台 Mac 控制）"
        }
    }

    public var shortTitle: String { self == .server ? "服务端" : "客户端" }
}

/// A side of a desktop. For the server it describes where the client's screen sits.
public enum ScreenSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, right, top, bottom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .left: return "左侧"
        case .right: return "右侧"
        case .top: return "上方"
        case .bottom: return "下方"
        }
    }

    public var opposite: ScreenSide {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    /// True for left/right: the shared edge is a vertical line and positions along it are measured in y.
    public var isVerticalEdge: Bool { self == .left || self == .right }
}

/// Optional modifier that must be held for the cursor to cross to the other Mac.
public enum RequiredModifier: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, shift, control, option, command

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "无需按键"
        case .shift: return "按住 ⇧ Shift"
        case .control: return "按住 ⌃ Control"
        case .option: return "按住 ⌥ Option"
        case .command: return "按住 ⌘ Command"
        }
    }

    /// CGEventFlags mask (0 = no requirement).
    public var flagMask: UInt64 {
        switch self {
        case .none: return 0
        case .shift: return CGEventFlags.maskShift.rawValue
        case .control: return CGEventFlags.maskControl.rawValue
        case .option: return CGEventFlags.maskAlternate.rawValue
        case .command: return CGEventFlags.maskCommand.rawValue
        }
    }
}

/// Scroll direction of a mouse wheel whose events are forwarded to the other Mac (the server owns the
/// wheel, so it decides; trackpads / Magic Mouse keep their own direction).
public enum WheelDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Wheel up shows the content above (classic / Windows behaviour).
    case windows
    /// Wheel up shows the content below (macOS "natural scrolling").
    case natural

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .windows: return "与 Windows 一致（上滚看上面）"
        case .natural: return "与 macOS 自然滚动一致"
        }
    }

    public var shortTitle: String { self == .windows ? "与 Windows 一致" : "自然滚动" }
}

/// Mouse-wheel behaviour the server asks the client to use (sent in the hello).
public struct WheelConfig: Codable, Equatable, Sendable {
    /// Animate each wheel tick as a short, eased, trackpad-like scroll gesture.
    public var smooth = true
    /// 1 (slow) … 5 (fast).
    public var speed = 3
    /// Informational: the direction is already applied by the server.
    public var direction: WheelDirection = .windows

    public static let speedRange = 1...5

    public init(smooth: Bool = true, speed: Int = 3, direction: WheelDirection = .windows) {
        self.smooth = smooth
        self.speed = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        self.direction = direction
    }

    // Tolerant decoding: a newer / older peer may send fewer or more fields.
    private enum CodingKeys: String, CodingKey { case smooth, speed, direction }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(smooth: (try? c.decodeIfPresent(Bool.self, forKey: .smooth)) ?? true,
                  speed: (try? c.decodeIfPresent(Int.self, forKey: .speed)) ?? 3,
                  direction: (try? c.decodeIfPresent(WheelDirection.self, forKey: .direction)) ?? .windows)
    }
}

public struct InputSettings: Codable, Equatable, Sendable {
    public var enabled = true
    /// Desktops share their keyboard/mouse by default; laptops are controlled.
    public var role: InputRole = AppEnvironment.isLaptop ? .client : .server
    /// Server only: where the client's screen is, relative to this Mac's screens.
    public var clientSide: ScreenSide = .right
    /// How long the cursor must press against the edge before switching (0 = immediately).
    public var dwellMilliseconds = 0
    public var requiredModifier: RequiredModifier = .none
    /// Never switch while a mouse button is held (avoids dragging across machines).
    public var blockWhileButtonHeld = true
    /// Server: jump to the other Mac / come back. Default ⌃⌥⌘ Space.
    public var switchHotKey: HotKey? = HotKey(keyCode: UInt32(kVK_Space), modifiers: [.control, .option, .command])
    /// Copy the clipboard to the Mac that receives control.
    public var clipboardSync = true
    /// Server: direction of the mouse wheel on the other Mac.
    public var wheelDirection: WheelDirection = .windows
    /// Server: animate mouse-wheel scrolling on the other Mac.
    public var smoothScrolling = true
    /// Server: mouse-wheel speed on the other Mac, 1…5.
    public var scrollSpeed = 3

    public init() {}

    /// What the server tells the client about the wheel.
    public var wheelConfig: WheelConfig {
        WheelConfig(smooth: smoothScrolling, speed: scrollSpeed, direction: wheelDirection)
    }
}
