import AppKit
import ApplicationServices
import Combine
import SwiftUI

/// Helpers for the TCC permissions OneSwitch needs.
/// - 辅助功能 (Accessibility): posting synthetic events (键鼠共享 client, 菜单栏图标 arranging) and active event taps.
/// - 输入监控 (Input Monitoring): listening to keyboard events (键鼠共享 server).
/// - 屏幕录制 (Screen Recording): reading menu-bar item titles (optional).
public enum Permissions {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case accessibility, inputMonitoring, screenRecording
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .accessibility: return "辅助功能"
            case .inputMonitoring: return "输入监控"
            case .screenRecording: return "屏幕录制"
            }
        }

        public var settingsURL: URL {
            let anchor: String
            switch self {
            case .accessibility: anchor = "Privacy_Accessibility"
            case .inputMonitoring: anchor = "Privacy_ListenEvent"
            case .screenRecording: anchor = "Privacy_ScreenCapture"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }

        /// Icon of the permission's row (the symbols System Settings uses in 隐私与安全性).
        public var tileSymbol: String {
            switch self {
            case .accessibility: return "accessibility"
            case .inputMonitoring: return "keyboard.fill"
            case .screenRecording: return "rectangle.dashed.badge.record"
            }
        }

        public var tileColor: Color {
            switch self {
            case .accessibility: return .blue
            case .inputMonitoring: return .gray
            case .screenRecording: return .red
            }
        }
    }

    public static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }

    /// Triggers the system prompt (first time) and returns the current state.
    @discardableResult
    public static func request(_ kind: Kind) -> Bool {
        switch kind {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .inputMonitoring:
            return CGRequestListenEventAccess()
        case .screenRecording:
            return CGRequestScreenCaptureAccess()
        }
    }

    public static func openSettings(_ kind: Kind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}

/// A row showing a permission's state with a button to request it / open System Settings.
/// Re-checks every 2 s while on screen and whenever the app becomes active again (permissions are
/// granted in System Settings, outside the app).
public struct PermissionRow: View {
    let kind: Permissions.Kind
    let reason: String
    @ViewState private var granted = false

    public init(_ kind: Permissions.Kind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SettingsIconTile(kind.tileSymbol, color: kind.tileColor, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .labelStyle(PermissionStateLabelStyle())
            } else {
                Button("授权…") {
                    // The system prompt only appears the first time; afterwards open the settings pane.
                    if !Permissions.request(kind) { Permissions.openSettings(kind) }
                    granted = Permissions.isGranted(kind)
                }
                .modifier(ProminentActionStyle())
            }
        }
        // Tied to the row's lifetime on screen: cancelled when the page or the window goes away.
        .task {
            while !Task.isCancelled {
                granted = Permissions.isGranted(kind)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = Permissions.isGranted(kind)
        }
    }
}

/// "✓ 已授权": green symbol, secondary text.
private struct PermissionStateLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(.green)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

/// The row's call to action: a prominent Liquid Glass button on macOS 26+, a prominent bordered one before.
private struct ProminentActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}
