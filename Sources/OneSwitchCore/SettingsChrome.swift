import SwiftUI

// Building blocks of the System Settings–style settings window: the per-pane appearance that the app
// shell hands to every page, the coloured icon tile, back / forward history and sidebar search.

// MARK: - Pane appearance (environment)

/// How a settings pane presents itself: the coloured icon tile in the sidebar and in the page's hero card,
/// plus the one-line description under the hero title. Provided by the app shell for every pane through
/// `EnvironmentValues.settingsPaneAppearance`, so module pages built with `SettingsPage` get the hero card
/// without knowing about it.
public struct SettingsPaneAppearance: Equatable, Sendable {
    /// SF Symbol drawn in white on the tile (prefer `.fill` variants, like System Settings).
    public var symbol: String
    /// Tile colour.
    public var color: Color
    /// One-line description shown under the title in the hero card. When nil the page's own subtitle is used.
    public var summary: String?

    public init(symbol: String, color: Color, summary: String? = nil) {
        self.symbol = symbol
        self.color = color
        self.summary = summary
    }
}

// Written by hand: the `@Entry` macro needs a compiler plugin that ships only with Xcode.
private struct SettingsPaneAppearanceKey: EnvironmentKey {
    static let defaultValue: SettingsPaneAppearance? = nil
}

public extension EnvironmentValues {
    /// The appearance of the settings pane this view is part of (nil outside the settings window).
    var settingsPaneAppearance: SettingsPaneAppearance? {
        get { self[SettingsPaneAppearanceKey.self] }
        set { self[SettingsPaneAppearanceKey.self] = newValue }
    }
}

// MARK: - Icon tile

/// A System Settings–style icon: a white SF Symbol on a coloured, continuously rounded square.
///
/// ```swift
/// SettingsIconTile("gearshape.fill", color: .gray)            // sidebar size
/// SettingsIconTile("sun.max.fill", color: .orange, size: 64)  // hero size
/// ```
public struct SettingsIconTile: View {
    private let symbol: String
    private let color: Color
    private let size: CGFloat

    public init(_ symbol: String, color: Color, size: CGFloat = 20) {
        self.symbol = symbol
        self.color = color
        self.size = size
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
        ZStack {
            shape.fill(color.gradient)
            // A light top edge and a slightly darker bottom, like the system's app and settings icons.
            shape.fill(LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.06)],
                                      startPoint: .top, endPoint: .bottom))
            // Fitted into a fixed box so wide (menubar.rectangle) and tall (gearshape) symbols look balanced.
            Image(systemName: symbol)
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white)
                .frame(width: size * 0.64, height: size * 0.64)
                .shadow(color: .black.opacity(size >= 40 ? 0.12 : 0), radius: size * 0.02, y: size * 0.01)
        }
        .overlay(shape.strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(size >= 40 ? 0.14 : 0.06), radius: size >= 40 ? 3 : 0.5, y: size >= 40 ? 1.5 : 0.5)
        .accessibilityHidden(true)
    }
}

// MARK: - Back / forward history

/// Browser-style navigation history of the settings window (System Settings' ‹ › buttons, ⌘[ / ⌘]).
public struct SettingsHistory: Equatable, Sendable {
    public private(set) var current: String?
    public private(set) var backStack: [String] = []
    public private(set) var forwardStack: [String] = []
    /// Oldest entries are dropped beyond this many steps.
    public let limit: Int

    public init(current: String?, limit: Int = 50) {
        self.current = current
        self.limit = max(1, limit)
    }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Navigates to `id` (a new branch: the forward stack is cleared). Visiting the current page is a no-op.
    public mutating func visit(_ id: String) {
        guard id != current else { return }
        if let current {
            backStack.append(current)
            if backStack.count > limit { backStack.removeFirst(backStack.count - limit) }
        }
        forwardStack.removeAll()
        current = id
    }

    @discardableResult
    public mutating func goBack() -> String? {
        guard let previous = backStack.popLast() else { return nil }
        if let current { forwardStack.append(current) }
        current = previous
        return previous
    }

    @discardableResult
    public mutating func goForward() -> String? {
        guard let next = forwardStack.popLast() else { return nil }
        if let current { backStack.append(current) }
        current = next
        return next
    }

    /// Drops pages that no longer exist (e.g. a pane removed at runtime).
    public mutating func retain(where isValid: (String) -> Bool) {
        backStack = backStack.filter(isValid)
        forwardStack = forwardStack.filter(isValid)
        if let current, !isValid(current) { self.current = backStack.popLast() }
        // Collapse neighbours that became equal after filtering.
        backStack = backStack.reduce(into: []) { if $0.last != $1 { $0.append($1) } }
        if backStack.last == current { backStack.removeLast() }
        forwardStack = forwardStack.reduce(into: []) { if $0.last != $1 { $0.append($1) } }
        if forwardStack.last == current { forwardStack.removeLast() }
    }
}

// MARK: - Sidebar search

/// Matching for the search field at the top of the settings sidebar.
public enum SettingsSearch {
    public enum Match: Equatable, Sendable {
        /// The pane's name matches.
        case title
        /// One of the pane's section titles / keywords matches (shown under the name in the sidebar).
        case keyword(String)
        /// Only the pane's description matches.
        case summary
    }

    /// Case-, width- and diacritic-insensitive form without whitespace ("Ｗｉ-Fi " → "wi-fi").
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_Hans"))
            .filter { !$0.isWhitespace }
    }

    /// Whether a pane matches `query`. Every whitespace-separated term of the query must match the
    /// name, a keyword or the description. An empty query matches everything (as `.title`).
    public static func match(query: String, title: String, keywords: [String] = [], summary: String? = nil) -> Match? {
        let terms = query.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return .title }
        let normalizedTitle = normalize(title)
        let normalizedKeywords = keywords.map { ($0, normalize($0)) }
        let normalizedSummary = summary.map(normalize) ?? ""

        var matchedKeyword: String?
        var matchedSummaryOnly = false
        for term in terms {
            if normalizedTitle.contains(term) { continue }
            if let keyword = normalizedKeywords.first(where: { $0.1.contains(term) }) {
                matchedKeyword = matchedKeyword ?? keyword.0
                continue
            }
            if normalizedSummary.contains(term) {
                matchedSummaryOnly = true
                continue
            }
            return nil
        }
        if let matchedKeyword { return .keyword(matchedKeyword) }
        return matchedSummaryOnly ? .summary : .title
    }
}
