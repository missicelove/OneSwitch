import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A keyboard shortcut (virtual key code + modifiers). Codable for use inside settings structs.
public struct HotKey: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    /// `NSEvent.ModifierFlags.rawValue`, masked to ⌘⌥⌃⇧.
    public var modifiers: UInt

    public init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(HotKey.relevantModifiers).rawValue
    }

    public static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    public var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// e.g. "⌃⌥⌘H"
    public var displayString: String {
        var s = ""
        let f = modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        let f = modifierFlags
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

/// Signature of every hotkey OneSwitch registers ('ONSW').
private let hotKeySignature: OSType = 0x4F4E_5357

/// System-wide hotkeys via Carbon `RegisterEventHotKey` (no Accessibility permission needed).
///
/// - One combination belongs to at most one id: registering a combination that another OneSwitch
///   feature already uses fails (returns false) instead of silently stealing it.
/// - Registrations are exclusive (`kEventHotKeyExclusive`): a combination another app has registered
///   is reported as taken instead of triggering both apps.
/// - `suspendAll()` / `resumeAll()` temporarily release every registration (used while a
///   `HotKeyRecorder` records, so pressing an existing shortcut records it instead of firing it).
@MainActor
public final class GlobalHotKeyCenter {
    public static let shared = GlobalHotKeyCenter()

    private struct Entry {
        /// nil while suspended.
        var ref: EventHotKeyRef?
        var hotKey: HotKey
        var numericID: UInt32
        var handler: @MainActor () -> Void
    }

    private var entries: [String: Entry] = [:]
    private var idLookup: [UInt32: String] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private var suspendCount = 0

    private init() {}

    /// Registers (or replaces) the hotkey for `id`. Passing `nil` unregisters. Returns false if the
    /// combination is already used by another OneSwitch feature or taken by another app / the system.
    @discardableResult
    public func register(id: String, hotKey: HotKey?, handler: @escaping @MainActor () -> Void) -> Bool {
        unregister(id: id)
        guard let hotKey else { return true }
        if let owner = self.id(using: hotKey) {
            AppLog.warning("hotkey", "register \(id) \(hotKey.displayString) failed: already used by \(owner)")
            return false
        }
        installHandlerIfNeeded()
        let numericID = nextID
        nextID &+= 1
        var entry = Entry(ref: nil, hotKey: hotKey, numericID: numericID, handler: handler)
        if suspendCount == 0 {
            guard let ref = carbonRegister(hotKey, numericID: numericID) else {
                AppLog.warning("hotkey", "register \(id) \(hotKey.displayString) failed (taken by another app or the system)")
                return false
            }
            entry.ref = ref
        }
        entries[id] = entry
        idLookup[numericID] = id
        AppLog.info("hotkey", "registered \(id) = \(hotKey.displayString)")
        return true
    }

    public func unregister(id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if let ref = entry.ref { UnregisterEventHotKey(ref) }
        idLookup[entry.numericID] = nil
    }

    /// The id currently holding `hotKey`, if any.
    public func id(using hotKey: HotKey) -> String? {
        entries.first { $0.value.hotKey == hotKey }?.key
    }

    /// The combination registered for `id`, if any.
    public func hotKey(for id: String) -> HotKey? {
        entries[id]?.hotKey
    }

    public var isSuspended: Bool { suspendCount > 0 }

    /// Temporarily releases every registration (nested calls are counted). Registrations made while
    /// suspended take effect on `resumeAll()`.
    public func suspendAll() {
        suspendCount += 1
        guard suspendCount == 1 else { return }
        for (id, var entry) in entries {
            guard let ref = entry.ref else { continue }
            UnregisterEventHotKey(ref)
            entry.ref = nil
            entries[id] = entry
        }
    }

    public func resumeAll() {
        guard suspendCount > 0 else { return }
        suspendCount -= 1
        guard suspendCount == 0 else { return }
        for (id, var entry) in entries where entry.ref == nil {
            if let ref = carbonRegister(entry.hotKey, numericID: entry.numericID) {
                entry.ref = ref
                entries[id] = entry
            } else {
                AppLog.warning("hotkey", "re-register \(id) \(entry.hotKey.displayString) failed after suspension")
            }
        }
    }

    private func carbonRegister(_ hotKey: HotKey, numericID: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: hotKeySignature, id: numericID)
        // Exclusive: fails when another app already registered the combination (without it both apps
        // would register fine and BOTH would fire on every press), and keeps later non-exclusive
        // registrations of other apps from also firing while we hold it.
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers, hkID,
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            AppLog.debug("hotkey", "RegisterEventHotKey \(hotKey.displayString) -> \(status)")
            return nil
        }
        return ref
    }

    fileprivate func fire(numericID: UInt32) {
        guard suspendCount == 0, let id = idLookup[numericID], let entry = entries[id] else { return }
        entry.handler()
    }

    /// Installed once for the app's lifetime (the callback captures nothing, so there is no context
    /// object to keep alive).
    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr else { return status }
            // Someone else's hotkey (another component of this process): let it pass.
            guard hkID.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
            let numericID = hkID.id
            if Thread.isMainThread {
                MainActor.assumeIsolated { GlobalHotKeyCenter.shared.fire(numericID: numericID) }
            } else {
                DispatchQueue.main.async { GlobalHotKeyCenter.shared.fire(numericID: numericID) }
            }
            return noErr
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &eventHandler)
        if status != noErr { AppLog.error("hotkey", "InstallEventHandler failed: \(status)") }
    }
}

/// SwiftUI control to record a hotkey. Esc cancels, ⌫ clears.
///
/// While recording, every global hotkey is suspended so that pressing a combination OneSwitch already
/// uses gets recorded instead of triggering its action. Recording ends when the app loses focus.
public struct HotKeyRecorder: View {
    @Binding private var hotKey: HotKey?
    @ViewState private var recording = false
    @ViewState private var monitor: Any?

    public init(hotKey: Binding<HotKey?>) {
        self._hotKey = hotKey
    }

    public var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(recording ? "请按下快捷键…" : (hotKey?.displayString ?? "点击设置"))
                    .frame(minWidth: 110)
            }
            if hotKey != nil && !recording {
                Button { hotKey = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help("清除快捷键")
            }
        }
        .onDisappear(perform: stop)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stop() }
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        guard !recording else { return }
        recording = true
        GlobalHotKeyCenter.shared.suspendAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = UInt32(event.keyCode)
            let mods = event.modifierFlags.intersection(HotKey.relevantModifiers)
            if code == UInt32(kVK_Escape) && mods.isEmpty {
                stop()
                return nil
            }
            if (code == UInt32(kVK_Delete) || code == UInt32(kVK_ForwardDelete)) && mods.isEmpty {
                stop()
                hotKey = nil
                return nil
            }
            let isFunctionKey = KeyNames.isFunctionKey(code)
            guard isFunctionKey || !mods.subtracting(.shift).isEmpty else {
                NSSound.beep()
                return nil
            }
            // Resume the other hotkeys first so the new one registers against the real state (and a
            // conflict is reported by the owning feature).
            stop()
            hotKey = HotKey(keyCode: code, modifiers: mods)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        GlobalHotKeyCenter.shared.resumeAll()
    }
}

/// Display names for virtual key codes (US ANSI positions; good enough for shortcut labels).
public enum KeyNames {
    private static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    public static func name(for keyCode: UInt32) -> String {
        names[Int(keyCode)] ?? "Key\(keyCode)"
    }

    public static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeys.contains(Int(keyCode))
    }
}
