import AppKit
import SwiftUI

// The System Settings–style settings window shell: a glass sidebar with a search field and coloured icon
// tiles, a detail page under a unified toolbar with ‹ | › history buttons, and the page title that — like
// System Settings on macOS 26+ — only appears in the toolbar once the page's hero card has scrolled away.
// The app shell supplies the panes; this file owns the generic behaviour so CoreCheck can exercise it.

// MARK: - Pane

/// One page of the settings window.
public struct SettingsPaneItem: Identifiable {
    public let id: String
    public let title: String
    public let appearance: SettingsPaneAppearance
    /// Section titles and key terms of the page, matched by the sidebar search.
    public let keywords: [String]
    public let view: AnyView

    public init(id: String, title: String, appearance: SettingsPaneAppearance, keywords: [String] = [], view: AnyView) {
        self.id = id
        self.title = title
        self.appearance = appearance
        self.keywords = keywords
        self.view = view
    }
}

// MARK: - Navigation model

/// Selection, back / forward history and sidebar search of the settings window.
@MainActor
public final class SettingsWindowNavigation: ObservableObject {
    @Published public private(set) var history: SettingsHistory
    @Published public var searchText = ""
    /// False while the window is closed. The detail page is then torn down, so its timers, polling
    /// (permission rows, live stats) and key monitors stop instead of running behind a closed window.
    @Published public var isPresented = false
    /// Incremented to move the keyboard focus into the sidebar search field (编辑 → 查找…, ⌘F).
    @Published public private(set) var searchFocusRequest = 0

    public init(initial: String?) {
        history = SettingsHistory(current: initial)
    }

    public var selection: String? { history.current }

    public func select(_ id: String) { history.visit(id) }
    public func goBack() { history.goBack() }
    public func goForward() { history.goForward() }
    public func focusSearch() { searchFocusRequest &+= 1 }
}

// MARK: - Search results

/// A sidebar row while searching: the pane plus the matched section title / keyword shown under its name.
public struct SettingsSidebarResult: Identifiable {
    public let pane: SettingsPaneItem
    public let hint: String?
    public var id: String { pane.id }
}

public extension SettingsSearch {
    /// The sidebar groups filtered by `query` (empty groups dropped); every pane when the query is empty.
    static func results(in sections: [[SettingsPaneItem]], query: String) -> [[SettingsSidebarResult]] {
        sections.compactMap { group in
            let matches = group.compactMap { pane -> SettingsSidebarResult? in
                guard let match = match(query: query, title: pane.title, keywords: pane.keywords,
                                        summary: pane.appearance.summary) else { return nil }
                if case .keyword(let keyword) = match { return SettingsSidebarResult(pane: pane, hint: keyword) }
                return SettingsSidebarResult(pane: pane, hint: nil)
            }
            return matches.isEmpty ? nil : matches
        }
    }
}

// MARK: - Metrics

/// Sizes of the settings window chrome, matched against macOS 26/27 System Settings.
public enum SettingsMetrics {
    /// Sidebar column: System Settings' sidebar is ~230 pt wide.
    public static let sidebarMinWidth: CGFloat = 215
    public static let sidebarIdealWidth: CGFloat = 230
    public static let sidebarMaxWidth: CGFloat = 300

    /// Icon tile of a sidebar row. Follows 系统设置 → 外观 → 侧边栏图标大小 like System Settings does.
    public static func sidebarTileSize(for rowSize: SidebarRowSize) -> CGFloat {
        switch rowSize {
        case .small: return 16
        case .large: return 24
        default: return 20
        }
    }

    /// Scroll distance (pt) after which the hero card's title is under the toolbar and the page title
    /// takes its place in the toolbar. At rest the hero title sits ~108–128 pt below the toolbar's edge.
    public static let heroTitleScrollThreshold: CGFloat = 120
}

// MARK: - Hero visibility → toolbar title

/// Handed to each page through the environment: `SettingsPage` reports whether its hero card's title has
/// scrolled under the toolbar (false on appear, nil when the page goes away). Reports are keyed by pane in
/// the split view, so the order in which the old page disappears and the new one appears does not matter.
/// (A preference key does not work here: SwiftUI does not report the value going back to its default when
/// the page that set it is removed, and the toolbar title then stayed hidden on pages without a hero card.)
struct SettingsHeroScrollReporter {
    let report: @MainActor (Bool?) -> Void
}

private struct SettingsHeroScrollReporterKey: EnvironmentKey {
    static var defaultValue: SettingsHeroScrollReporter? { nil }
}

extension EnvironmentValues {
    var settingsHeroScrollReporter: SettingsHeroScrollReporter? {
        get { self[SettingsHeroScrollReporterKey.self] }
        set { self[SettingsHeroScrollReporterKey.self] = newValue }
    }
}

// MARK: - Split view

/// The root view of the settings window. Host it in a window with a unified toolbar and
/// `NSHostingController.sceneBridgingOptions = [.toolbars, .title]` so SwiftUI owns the toolbar.
public struct SettingsSplitView: View {
    private let sections: [[SettingsPaneItem]]
    @ObservedObject private var navigation: SettingsWindowNavigation
    /// Shown under the page title (e.g. "配置档 B" for a test profile).
    private let subtitle: String?
    @FocusState private var searchFocused: Bool
    /// Per pane: whether its hero card title scrolled under the toolbar; no entry = no hero card (or macOS 14),
    /// the toolbar title is then always shown.
    @ViewState private var heroScrolledAway: [String: Bool] = [:]

    public init(sections: [[SettingsPaneItem]], navigation: SettingsWindowNavigation, subtitle: String? = nil) {
        self.sections = sections
        self.navigation = navigation
        self.subtitle = subtitle
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebarList(results: searchResults, navigation: navigation)
                .navigationSplitViewColumnWidth(min: SettingsMetrics.sidebarMinWidth,
                                                ideal: SettingsMetrics.sidebarIdealWidth,
                                                max: SettingsMetrics.sidebarMaxWidth)
        } detail: {
            detail
        }
        // Like System Settings, the sidebar is always there: no sidebar toggle. Applied to the split view:
        // inside the sidebar column it makes SwiftUI drop the column width (the sidebar shrank to 144 pt).
        .toolbar(removing: .sidebarToggle)
        .searchable(text: $navigation.searchText, placement: .sidebar, prompt: Text("搜索"))
        .modifier(SearchFocus(focused: $searchFocused))
        .onSubmit(of: .search) {
            // Return in the search field opens the best match.
            if let first = searchResults.first?.first { navigation.select(first.pane.id) }
        }
        .onChange(of: navigation.searchFocusRequest) { _, _ in searchFocused = true }
        .frame(minWidth: 780, minHeight: 540)
    }

    /// An SF Symbol whose accessibility description is `label`. The navigation-style control group turns
    /// the buttons into segments that VoiceOver names after the image alone — with `Image(systemName:)` that
    /// is the symbol's generic English name ("Back"), not 返回.
    static func symbol(_ name: String, label: String) -> Image {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: label) {
            return Image(nsImage: image)
        }
        return Image(systemName: name)
    }

    private var currentPane: SettingsPaneItem? {
        sections.lazy.flatMap { $0 }.first { $0.id == navigation.selection }
    }

    /// System Settings shows the page title in the toolbar only once the hero card's title is gone.
    private var showsToolbarTitle: Bool {
        guard let id = currentPane?.id, let isAway = heroScrolledAway[id] else { return true }
        return isAway
    }

    private var searchResults: [[SettingsSidebarResult]] {
        SettingsSearch.results(in: sections, query: navigation.searchText)
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            if !navigation.isPresented {
                Color.clear
            } else if let pane = currentPane {
                pane.view
                    .environment(\.settingsPaneAppearance, pane.appearance)
                    .environment(\.settingsHeroScrollReporter, SettingsHeroScrollReporter { [id = pane.id] isAway in
                        heroScrolledAway[id] = isAway
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // A fresh identity per page: page state and onAppear / onDisappear follow the selection.
                    .id(pane.id)
            } else {
                ContentUnavailableView("请在左侧选择一个设置项", systemImage: "sidebar.left")
            }
        }
        .background(WindowTitleVisibility(visible: showsToolbarTitle).frame(width: 0, height: 0))
        .navigationTitle(currentPane?.title ?? "OneSwitch")
        .modifier(OptionalSubtitle(subtitle: subtitle))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                // System Settings' "‹ | ›" capsule (one glass capsule with a divider on macOS 26+).
                ControlGroup {
                    Button {
                        navigation.goBack()
                    } label: {
                        Label { Text("返回") } icon: { Self.symbol("chevron.backward", label: "返回") }
                    }
                    .help("返回")
                    .disabled(!navigation.history.canGoBack)

                    Button {
                        navigation.goForward()
                    } label: {
                        Label { Text("前进") } icon: { Self.symbol("chevron.forward", label: "前进") }
                    }
                    .help("前进")
                    .disabled(!navigation.history.canGoForward)
                } label: {
                    Text("返回/前进")
                }
                .controlGroupStyle(.navigation)
            }
        }
    }
}

/// The sidebar list: groups of panes separated by gaps, each row with a coloured icon tile.
struct SettingsSidebarList: View {
    let results: [[SettingsSidebarResult]]
    @ObservedObject var navigation: SettingsWindowNavigation

    var body: some View {
        List(selection: selection) {
            if results.isEmpty {
                Text("没有与“\(navigation.searchText)”相关的设置")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
            ForEach(results.indices, id: \.self) { index in
                Section {
                    ForEach(results[index]) { result in
                        SettingsSidebarRow(pane: result.pane, hint: result.hint)
                            .tag(result.pane.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { navigation.selection },
            // Deselection (⌘-click on the selected row) is ignored: a page is always shown.
            set: { id in if let id { navigation.select(id) } }
        )
    }
}

struct SettingsSidebarRow: View {
    let pane: SettingsPaneItem
    let hint: String?
    @Environment(\.sidebarRowSize) private var rowSize

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(pane.title)
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            SettingsIconTile(pane.appearance.symbol, color: pane.appearance.color,
                             size: SettingsMetrics.sidebarTileSize(for: rowSize))
        }
        .padding(.vertical, 1)
    }
}

/// Keyboard focus for the sidebar search field (⌘F); `searchFocused` needs macOS 15.
private struct SearchFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.searchFocused(focused)
        } else {
            content
        }
    }
}

private struct OptionalSubtitle: ViewModifier {
    let subtitle: String?

    func body(content: Content) -> some View {
        if let subtitle {
            content.navigationSubtitle(subtitle)
        } else {
            content
        }
    }
}

/// Shows / hides the title in the window's toolbar (`NSWindow.titleVisibility`) without touching the window
/// title itself, which the Window menu, Mission Control and VoiceOver keep using.
private struct WindowTitleVisibility: NSViewRepresentable {
    let visible: Bool

    func makeNSView(context: Context) -> TitleVisibilityView { TitleVisibilityView() }

    func updateNSView(_ view: TitleVisibilityView, context: Context) {
        view.visible = visible
    }
}

final class TitleVisibilityView: NSView {
    var visible = true {
        didSet { apply() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func apply() {
        // After SwiftUI's own toolbar / title updates of the current transaction, which could reset it.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let wanted: NSWindow.TitleVisibility = self.visible ? .visible : .hidden
            if window.titleVisibility != wanted { window.titleVisibility = wanted }
        }
    }
}

// MARK: - Dock presence

/// Bookkeeping for "a Dock icon while the settings window is open": whether OneSwitch should currently be a
/// regular app, and which app gets the keyboard focus back once the window has closed.
///
/// Event order in the app: `windowShown` → (`noteActivated` …) → `windowClosed` → on the next run-loop turn
/// `wantsRegularApp` / `takeReturnTarget` — so a window reopened in between keeps the Dock icon.
public struct SettingsDockPresence<App: Equatable> {
    /// Open from `show` until `windowWillClose`; minimised or hidden with the app (⌘H) still counts as open.
    public private(set) var isWindowOpen = false
    /// The app that was active most recently before OneSwitch (nil: none known).
    public private(set) var returnTarget: App?

    public init() {}

    /// Regular app (Dock icon, ⌘-Tab, own menu bar) while the settings window is open.
    public var wantsRegularApp: Bool { isWindowOpen }

    /// The window is being shown. `frontmost` is the frontmost app at that moment; it becomes the return
    /// target unless it is OneSwitch itself (then the previous target, if any, stays).
    public mutating func windowShown(frontmost: App?, frontmostIsSelf: Bool) {
        isWindowOpen = true
        if let frontmost, !frontmostIsSelf { returnTarget = frontmost }
    }

    /// Another app became active while the window is open. Own activations are ignored, so the target is
    /// always the app the user came from most recently (where ⌘-Tab would go).
    public mutating func noteActivated(_ app: App, isSelf: Bool) {
        guard isWindowOpen, !isSelf else { return }
        returnTarget = app
    }

    public mutating func windowClosed() {
        isWindowOpen = false
    }

    /// After the close: the app to activate if OneSwitch was active (`wasActive`) and the target is still
    /// running (`isAlive`). Nil — and the target kept — when the window has been reopened meanwhile.
    public mutating func takeReturnTarget(wasActive: Bool, isAlive: (App) -> Bool) -> App? {
        guard !isWindowOpen else { return nil }
        defer { returnTarget = nil }
        guard wasActive, let target = returnTarget, isAlive(target) else { return nil }
        return target
    }
}
