import SwiftUI

/// Standard container for a module's settings page, laid out like a macOS System Settings pane:
/// a centred hero card (large icon tile, title, one-line description) followed by grouped inset sections.
///
/// ```swift
/// SettingsPage("防止锁屏", subtitle: "保持屏幕常亮，防止自动锁屏") {
///     Section("手动") { ... }
///     Section("自动计划") { ... }
/// }
/// ```
///
/// The icon, its colour and the description come from the app shell through
/// `EnvironmentValues.settingsPaneAppearance`; `subtitle` is the fallback description.
public struct SettingsPage<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let content: Content

    public init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    public var body: some View {
        Form {
            Section {
                SettingsHeroCard(title: title, fallbackSummary: subtitle)
            }
            content
        }
        .formStyle(.grouped)
        .modifier(HeroScrollTracking())
    }
}

/// Reports to the settings window whether the hero card's title has scrolled under the toolbar: the window
/// shows the page title in its toolbar only then, as System Settings does. Needs macOS 15
/// (`onScrollGeometryChange`); before, nothing is reported and the toolbar title stays visible.
private struct HeroScrollTracking: ViewModifier {
    @Environment(\.settingsHeroScrollReporter) private var reporter

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > SettingsMetrics.heroTitleScrollThreshold
                } action: { _, isAway in
                    reporter?.report(isAway)
                }
                .onAppear { reporter?.report(false) }
                .onDisappear { reporter?.report(nil) }
        } else {
            content
        }
    }
}

/// The card at the top of every settings page (System Settings' 通用 / 辅助功能 / 隐私与安全性 style).
public struct SettingsHeroCard: View {
    @Environment(\.settingsPaneAppearance) private var appearance
    private let title: String
    private let fallbackSummary: String?

    public init(title: String, fallbackSummary: String? = nil) {
        self.title = title
        self.fallbackSummary = fallbackSummary
    }

    /// Tile size of the hero icon (System Settings: 48 pt).
    public static let tileSize: CGFloat = 48

    public var body: some View {
        // Proportions measured on macOS 27 System Settings' 通用 card: 48 pt tile, bold title, the
        // description set tight under it, ~26 pt above the tile and ~20 pt under the text.
        VStack(spacing: 0) {
            if let appearance {
                SettingsIconTile(appearance.symbol, color: appearance.color, size: Self.tileSize)
                    .padding(.bottom, 11)
            }
            Text(title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            if let summary = appearance?.summary ?? fallbackSummary {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520)
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 9)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Explanatory text under a section, like System Settings' section footers.
///
/// ```swift
/// Section { ... } header: { Text("系统权限") } footer: { SettingsFooter("本地网络：…") }
/// ```
public struct SettingsFooter: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small status pill: coloured dot + text.
public struct StatusBadge: View {
    public enum Tone: Sendable { case ok, busy, warning, error, idle }
    private let text: String
    private let tone: Tone

    public init(_ text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color.gradient)
                .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                .frame(width: 8, height: 8)
            Text(text)
        }
        // One element for VoiceOver: the dot only repeats what the text says.
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .ok: return .green
        case .busy: return .blue
        case .warning: return .orange
        case .error: return .red
        case .idle: return .gray
        }
    }
}
