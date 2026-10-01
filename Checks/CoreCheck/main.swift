import AppKit
import Carbon.HIToolbox
import Foundation
import OneSwitchCore
import SwiftUI

// Self-checks for OneSwitchCore. Exit code 0 = all checks passed.

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() {
        print("  ✓ \(message)")
    } else {
        failures += 1
        print("  ✗ \(message) (line \(line))")
    }
}

/// Spins the main run loop until `condition` is true or `timeout` elapses.
@MainActor
func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}

@MainActor
func runChecks() {
    print("Formatters")
    check(Fmt.bytes(512.0) == "512 B", "bytes 512")
    check(Fmt.bytes(1536.0) == "1.50 KB", "bytes 1.5K -> \(Fmt.bytes(1536.0))")
    check(Fmt.duration(3900) == "1小时5分", "duration 3900 -> \(Fmt.duration(3900))")
    check(Fmt.minutes(90) == "1小时30分钟", "minutes 90")
    check(Fmt.timeOfDay(8 * 60) == "08:00", "timeOfDay 480")
    check(Fmt.clock(65) == "1:05", "clock 65")
    check(Fmt.rate(2_500_000, compact: true) == "2.4M", "compact rate -> \(Fmt.rate(2_500_000, compact: true))")

    print("LoopbackPeerHub")
    let (a, b) = LoopbackPeerHub.makePair()
    check(a.status.connectedPeer?.deviceID == b.localDeviceID, "A sees B as connected")

    let chA = Box<PeerChannel?>(nil), chB = Box<PeerChannel?>(nil)
    a.register(service: "test") { chA.value = $0 }
    check(!waitUntil(0.2) { chA.value != nil }, "no channel until both sides register")
    b.register(service: "test") { chB.value = $0 }
    check(waitUntil { chA.value != nil && chB.value != nil }, "channel pair formed after both register")

    let received = Box<[(UInt16, Data)]>([])
    let closedB = Box<Int>(0)
    // Send before B sets handlers: must be buffered.
    chA.value?.send(type: 1, payload: Data("hello".utf8))
    let q = DispatchQueue(label: "b")
    chB.value?.setHandlers(queue: q, onMessage: { t, d in received.mutate { $0.append((t, d)) } },
                           onClose: { _ in closedB.mutate { $0 += 1 } })
    for i in 2...100 { chA.value?.send(type: UInt16(i), payload: Data([UInt8(i)])) }
    check(waitUntil { received.value.count == 100 }, "100 messages delivered (buffered + live)")
    check(received.value.map(\.0) == Array(1...100).map(UInt16.init), "messages in order")
    check(received.value.first.map { String(decoding: $0.1, as: UTF8.self) } == "hello", "payload intact")

    let completionFired = Box(false)
    chA.value?.send(type: 7, payload: Data(count: 10)) { err in completionFired.value = (err == nil) }
    check(waitUntil { completionFired.value }, "send completion fires")

    let tooBig = Box<Error?>(nil)
    chA.value?.send(type: 8, payload: Data(count: PeerLimits.maxPayloadSize + 1)) { tooBig.value = $0 }
    check(waitUntil { tooBig.value != nil }, "oversized payload rejected")

    print("Unplug / replug")
    let closedA = Box<Int>(0)
    chA.value?.setHandlers(queue: DispatchQueue(label: "a"), onMessage: { _, _ in }, onClose: { _ in closedA.mutate { $0 += 1 } })
    let oldA = chA.value, oldB = chB.value
    a.setLinked(false)
    check(waitUntil { closedA.value == 1 && closedB.value == 1 }, "unplug closes both ends exactly once")
    check(a.status == .searching && b.status == .searching, "status searching after unplug")
    check(oldA?.isOpen == false && oldB?.isOpen == false, "old channels closed")
    a.setLinked(true)
    check(waitUntil { chA.value !== oldA && chB.value !== oldB && chA.value != nil }, "channels re-form after replug")

    print("Close propagation")
    let closedB2 = Box<Int>(0)
    chB.value?.setHandlers(queue: q, onMessage: { _, _ in }, onClose: { _ in closedB2.mutate { $0 += 1 } })
    chA.value?.close()
    check(waitUntil { closedB2.value == 1 }, "close propagates to peer")

    print("Unregister")
    let reformed = Box(false)
    b.register(service: "test") { _ in reformed.value = true }
    check(waitUntil { reformed.value }, "re-register forms a new channel")
    a.unregister(service: "test")
    reformed.value = false
    b.register(service: "test") { _ in reformed.value = true }
    check(!waitUntil(0.3) { reformed.value }, "no channel after peer unregistered")

    print("SettingsStore migration")
    struct V1: Codable, Equatable { var a = 1 }
    struct V2: Codable, Equatable { var a = 1; var b = "x" }
    let suite = UserDefaults(suiteName: "oneswitch.corecheck")!
    suite.removePersistentDomain(forName: "oneswitch.corecheck")
    let s1 = SettingsStore(key: "k", defaultValue: V1(), defaults: suite)
    s1.value.a = 42
    let s2 = SettingsStore(key: "k", defaultValue: V2(), defaults: suite)
    check(s2.value.a == 42 && s2.value.b == "x", "added field keeps old values")
    struct W1: Codable, Equatable { var hotKey: HotKey? = nil; var n = 1 }
    struct W2: Codable, Equatable { var hotKey: HotKey? = nil; var n = 1; var added = true }
    let w1 = SettingsStore(key: "w", defaultValue: W1(), defaults: suite)
    w1.value.hotKey = HotKey(keyCode: 4, modifiers: [.command, .option])
    let w2 = SettingsStore(key: "w", defaultValue: W2(), defaults: suite)
    check(w2.value.hotKey?.keyCode == 4, "migration keeps optional fields whose default is nil")

    struct Inner1: Codable, Equatable { var x = 1 }
    struct Inner2: Codable, Equatable { var x = 1; var y = "new" }
    struct Outer1: Codable, Equatable { var inner = Inner1(); var list = [1]; var n = 1 }
    struct Outer2: Codable, Equatable { var inner = Inner2(); var list = [1]; var n = 1; var flag = false }
    let o1 = SettingsStore(key: "nested", defaultValue: Outer1(), defaults: suite)
    o1.update { $0.inner.x = 5; $0.list = [3, 4]; $0.n = 7 }
    let o2 = SettingsStore(key: "nested", defaultValue: Outer2(), defaults: suite)
    check(o2.value.inner.x == 5 && o2.value.inner.y == "new", "nested struct gains a field: nested value kept")
    check(o2.value.list == [3, 4] && o2.value.n == 7 && o2.value.flag == false, "arrays / scalars kept, new field defaulted")

    enum Choice: Codable, Equatable { case off, timed(minutes: Int) }
    struct E1: Codable, Equatable { var choice = Choice.off }
    struct E2: Codable, Equatable { var choice = Choice.off; var extra = 1 }
    let e1 = SettingsStore(key: "enum", defaultValue: E1(), defaults: suite)
    e1.value.choice = .timed(minutes: 30)
    let e2 = SettingsStore(key: "enum", defaultValue: E2(), defaults: suite)
    check(e2.value.choice == .timed(minutes: 30) && e2.value.extra == 1, "enum with associated value survives migration")

    suite.set(Data("{not json".utf8), forKey: "broken")
    let broken = SettingsStore(key: "broken", defaultValue: V1(), defaults: suite)
    check(broken.value == V1(), "undecodable data falls back to defaults")
    check(suite.data(forKey: "broken.unreadable") == Data("{not json".utf8), "undecodable data kept as <key>.unreadable")
    suite.set(Data("[1,2]".utf8), forKey: "wrongShape")
    let wrongShape = SettingsStore(key: "wrongShape", defaultValue: V1(), defaults: suite)
    check(wrongShape.value == V1(), "stored value of the wrong JSON shape falls back to defaults")
    suite.removePersistentDomain(forName: "oneswitch.corecheck")

    print("GlobalHotKeyCenter")
    let center = GlobalHotKeyCenter.shared
    let hkA = HotKey(keyCode: UInt32(kVK_F19), modifiers: [.command, .option, .control, .shift])
    let hkB = HotKey(keyCode: UInt32(kVK_F18), modifiers: [.command, .option, .control, .shift])
    // Suspended: registrations are bookkeeping only (no system-wide hotkey is grabbed by this check).
    center.suspendAll()
    check(center.isSuspended, "suspendAll suspends")
    check(center.register(id: "check.a", hotKey: hkA) {}, "register while suspended succeeds")
    check(!center.register(id: "check.b", hotKey: hkA) {}, "same combination for a second id is refused")
    check(center.id(using: hkA) == "check.a" && center.hotKey(for: "check.b") == nil, "first owner keeps the combination")
    check(center.register(id: "check.a", hotKey: hkB) {}, "re-register replaces the old combination")
    check(center.id(using: hkA) == nil && center.id(using: hkB) == "check.a", "old combination released")
    check(center.register(id: "check.b", hotKey: hkA) {}, "released combination can be reused")
    check(center.register(id: "check.b", hotKey: nil) {} && center.hotKey(for: "check.b") == nil, "nil unregisters")
    center.unregister(id: "check.a")
    center.suspendAll()
    center.resumeAll()
    check(center.isSuspended, "suspension is counted (nested)")
    center.resumeAll()
    check(!center.isSuspended, "resumeAll ends the suspension")
    center.resumeAll()
    check(!center.isSuspended, "extra resumeAll is harmless")

    print("RotatingLogFile")
    let logDir = FileManager.default.temporaryDirectory.appendingPathComponent("corecheck-log-\(UUID().uuidString)")
    let logURL = logDir.appendingPathComponent("t.log")
    func fileSize(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? -1
    }
    let logFile = RotatingLogFile(url: logURL, maxSize: 1000)
    let line100 = String(repeating: "x", count: 99) + "\n"
    for _ in 0..<30 { logFile.append(line100) }
    check(fileSize(logURL.path) > 0 && fileSize(logURL.path) <= 1000, "current file stays within maxSize (\(fileSize(logURL.path)) B)")
    check(fileSize(logURL.path + ".1") > 0 && fileSize(logURL.path + ".1") <= 1000, "previous file rotated to .1")
    let total = fileSize(logURL.path) + fileSize(logURL.path + ".1")
    check(total > 0 && total % 100 == 0, "rotation never splits a line")
    try? FileManager.default.removeItem(at: logURL)
    for _ in 0..<70 { logFile.append("0123456789") }
    check(fileSize(logURL.path) > 0, "file re-created after it was deleted externally")
    logFile.closeFile()
    try? FileManager.default.removeItem(at: logDir)

    settingsChromeChecks()
    settingsDockPresenceChecks()

    AppLog.info("corecheck", "flush probe")
    AppLog.flush()
    check(AppLog.recentLines(limit: 5).contains { $0.contains("flush probe") }, "AppLog.flush drains pending lines")
}

/// Records the pane appearance a view sees in its environment.
private struct AppearanceProbe: View {
    let sink: Box<SettingsPaneAppearance?>
    @Environment(\.settingsPaneAppearance) private var appearance
    var body: some View {
        sink.value = appearance
        return Color.clear.frame(width: 10, height: 10)
    }
}

@MainActor
func settingsChromeChecks() {
    print("SettingsHistory")
    var history = SettingsHistory(current: "general", limit: 3)
    check(!history.canGoBack && !history.canGoForward, "fresh history cannot go back or forward")
    history.visit("general")
    check(!history.canGoBack, "visiting the current page is a no-op")
    history.visit("awake")
    history.visit("sync")
    check(history.current == "sync" && history.backStack == ["general", "awake"], "visits push onto the back stack")
    check(history.goBack() == "awake" && history.current == "awake" && history.canGoForward, "back returns to the previous page")
    check(history.goForward() == "sync" && !history.canGoForward, "forward returns to the next page")
    history.goBack()
    history.visit("input")
    check(!history.canGoForward && history.backStack == ["general", "awake"], "a new visit clears the forward stack")
    history.visit("monitor")
    history.visit("menubar")
    check(history.backStack == ["awake", "input", "monitor"], "back stack capped at the limit (oldest dropped)")
    while history.goBack() != nil {}
    check(history.current == "awake" && history.forwardStack.count == 3, "going back to the start keeps every page forward")
    check(history.goBack() == nil && history.current == "awake", "back at the start is a no-op")
    var pruned = SettingsHistory(current: "a")
    for id in ["b", "a", "c", "b"] { pruned.visit(id) }
    pruned.retain { $0 != "c" }
    check(pruned.current == "b" && pruned.backStack == ["a", "b", "a"], "retain drops removed pages from the stacks")
    var removedCurrent = SettingsHistory(current: "a")
    for id in ["b", "a", "c"] { removedCurrent.visit(id) }
    removedCurrent.retain { $0 != "c" }
    check(removedCurrent.current == "a" && removedCurrent.backStack == ["a", "b"],
          "retain moves off a removed current page without a duplicate neighbour (\(removedCurrent.backStack) → \(removedCurrent.current ?? "nil"))")

    print("SettingsSearch")
    check(SettingsSearch.normalize(" ＧＰＵ 温度 ") == "gpu温度", "normalize folds width / case and drops whitespace")
    check(SettingsSearch.match(query: "", title: "通用") == .title, "empty query matches everything")
    check(SettingsSearch.match(query: "  ", title: "通用") == .title, "whitespace-only query matches everything")
    check(SettingsSearch.match(query: "键鼠", title: "键鼠共享", keywords: ["剪贴板"]) == .title, "title match")
    check(SettingsSearch.match(query: "剪贴", title: "键鼠共享", keywords: ["状态", "剪贴板"]) == .keyword("剪贴板"), "keyword match reports the keyword")
    check(SettingsSearch.match(query: "gpu", title: "系统监控", keywords: ["CPU", "GPU"]) == .keyword("GPU"), "keyword match is case-insensitive")
    check(SettingsSearch.match(query: "syncthing", title: "文件同步", keywords: [], summary: "类似 Syncthing") == .summary, "summary-only match")
    check(SettingsSearch.match(query: "蓝牙", title: "文件同步", keywords: ["同步文件夹"], summary: "同步") == nil, "no match")
    check(SettingsSearch.match(query: "键鼠 剪贴板", title: "键鼠共享", keywords: ["剪贴板"]) == .keyword("剪贴板"), "every term must match (title + keyword)")
    check(SettingsSearch.match(query: "键鼠 蓝牙", title: "键鼠共享", keywords: ["剪贴板"]) == nil, "one unmatched term fails the whole query")

    print("Settings UI")
    _ = NSApplication.shared
    let seen = Box<SettingsPaneAppearance?>(SettingsPaneAppearance(symbol: "x", color: .red))
    let bare = NSHostingView(rootView: AppearanceProbe(sink: seen))
    bare.frame = NSRect(x: 0, y: 0, width: 50, height: 50)
    bare.layoutSubtreeIfNeeded()
    check(seen.value == nil, "pane appearance defaults to nil outside the settings window")
    let style = SettingsPaneAppearance(symbol: "sun.max.fill", color: .orange, summary: "一行说明")
    let injected = NSHostingView(rootView: AppearanceProbe(sink: seen).environment(\.settingsPaneAppearance, style))
    injected.frame = NSRect(x: 0, y: 0, width: 50, height: 50)
    injected.layoutSubtreeIfNeeded()
    check(seen.value == style, "pane appearance reaches views through the environment")

    let page = NSHostingView(rootView: SettingsPage("测试", subtitle: "副标题") {
        Section("分组") { Text("行") }
    }.environment(\.settingsPaneAppearance, style))
    page.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
    page.layoutSubtreeIfNeeded()
    check(page.fittingSize.width > 0 && page.fittingSize.height > 0, "SettingsPage with a hero card lays out")
    let pageWithoutStyle = NSHostingView(rootView: SettingsPage("测试") { Section { Text("行") } })
    pageWithoutStyle.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
    pageWithoutStyle.layoutSubtreeIfNeeded()
    check(pageWithoutStyle.fittingSize.height > 0, "SettingsPage without an appearance still lays out")

    let renderer = ImageRenderer(content: SettingsIconTile("gearshape.fill", color: .gray, size: 64))
    renderer.scale = 2
    let tile = renderer.cgImage
    check(tile?.width == 128 && tile?.height == 128, "icon tile renders at its size (\(tile.map { "\($0.width)×\($0.height)" } ?? "nil"))")
    if let tile, let data = tile.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
        let bpr = tile.bytesPerRow
        let bpp = tile.bitsPerPixel / 8
        let alphaFirst = [.first, .premultipliedFirst, .noneSkipFirst].contains(tile.alphaInfo)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[y * bpr + x * bpp + (alphaFirst ? 0 : 3)] }
        check(alpha(1, 1) < 40, "icon tile corners are rounded (transparent corner)")
        check(alpha(64, 20) > 200, "icon tile is opaque inside")
    }
}

// MARK: - Settings window shell

@MainActor
func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

/// A page long enough to scroll well past its hero card.
@MainActor
func longSettingsPage(_ title: String) -> AnyView {
    AnyView(SettingsPage(title, subtitle: "说明") {
        ForEach(0..<14, id: \.self) { index in
            Section("分组 \(index)") { Text("行 \(index)") }
        }
    })
}

/// Runs inside `NSApp.run()` (see the bottom of this file): toolbar validation and SwiftUI's update
/// scheduling only behave like in the app under the real AppKit event loop.
@MainActor
func settingsShellChecks() async {
    print("Settings window shell")
    let sections: [[SettingsPaneItem]] = [
        [SettingsPaneItem(id: "general", title: "通用",
                          appearance: SettingsPaneAppearance(symbol: "gearshape.fill", color: .gray, summary: "通用说明"),
                          keywords: ["日志"], view: longSettingsPage("通用"))],
        [SettingsPaneItem(id: "awake", title: "防止锁屏",
                          appearance: SettingsPaneAppearance(symbol: "sun.max.fill", color: .orange),
                          keywords: ["自动计划"], view: longSettingsPage("防止锁屏")),
         SettingsPaneItem(id: "plain", title: "普通页面",
                          appearance: SettingsPaneAppearance(symbol: "bolt.fill", color: .purple),
                          view: AnyView(Text("没有标题卡的页面"))),
        ],
    ]

    // Search over the sidebar groups.
    let all = SettingsSearch.results(in: sections, query: "")
    check(all.map { $0.map(\.id) } == [["general"], ["awake", "plain"]], "empty search lists every pane in its group")
    let found = SettingsSearch.results(in: sections, query: "自动")
    check(found.count == 1 && found.first?.first?.id == "awake" && found.first?.first?.hint == "自动计划",
          "search keeps matching groups only and names the matched keyword")
    check(SettingsSearch.results(in: sections, query: "蓝牙").isEmpty, "search without matches yields no groups")

    // The real split view in a window that is never ordered on screen (no visible side effects).
    let navigation = SettingsWindowNavigation(initial: "general")
    navigation.isPresented = true
    let hosting = NSHostingController(rootView: SettingsSplitView(sections: sections, navigation: navigation))
    hosting.sizingOptions = [.minSize]
    hosting.sceneBridgingOptions = [.toolbars, .title]
    let window = NSWindow(contentViewController: hosting)
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    window.toolbarStyle = .unified
    window.setContentSize(NSSize(width: 880, height: 660))
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let frame = window.contentView!.superview!
    /// Polls `condition` while the app's event loop keeps running.
    func settle(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }
    var settled = false
    func sidebarWidth() -> CGFloat {
        allViews(frame).compactMap { $0 as? NSOutlineView }.first?.enclosingScrollView?.frame.width ?? 0
    }
    func detailScrollView() -> NSScrollView? {
        allViews(frame).compactMap { $0 as? NSScrollView }.filter { !($0.documentView is NSOutlineView) }
            .max { $0.frame.width < $1.frame.width }
    }
    func navigationControl() -> NSSegmentedControl? {
        allViews(frame).compactMap { $0 as? NSSegmentedControl }.first
    }
    func scrollDetail(to y: CGFloat) {
        guard let scrollView = detailScrollView() else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y - scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    settled = await settle(5) { sidebarWidth() > 0 }
    check(settled, "split view lays out in an offscreen window")
    check(sidebarWidth() >= SettingsMetrics.sidebarMinWidth && sidebarWidth() <= SettingsMetrics.sidebarMaxWidth,
          "sidebar keeps its column width with the sidebar toggle removed (\(sidebarWidth()) pt, was 144 pt)")

    // ‹ | › : one navigation control with two labelled segments that follow the history. Queried afresh each
    // time: SwiftUI may replace the control when the toolbar is rebuilt for another page.
    func segments() -> [Bool] {
        guard let control = navigationControl() else { return [] }
        return (0..<control.segmentCount).map { control.isEnabled(forSegment: $0) }
    }
    settled = await settle { navigationControl() != nil }
    check(settled, "toolbar has the ‹ | › navigation control")
    if let control = navigationControl() {
        check(control.segmentCount == 2, "navigation control has two segments")
        let labels = (0..<control.segmentCount).map { control.image(forSegment: $0)?.accessibilityDescription ?? "" }
        check(labels == ["返回", "前进"], "segments are named 返回 / 前进 for VoiceOver (\(labels))")
        check(control.toolTip(forSegment: 0) == "返回" && control.toolTip(forSegment: 1) == "前进", "segments have 返回 / 前进 tooltips")
    }
    check(segments() == [false, false], "fresh window: 返回 and 前进 disabled (\(segments()))")
    navigation.select("awake")
    settled = await settle { segments() == [true, false] }
    check(settled, "after a visit: 返回 enabled, 前进 disabled (\(segments()))")
    settled = await settle { window.title == "防止锁屏" }
    check(settled, "window title follows the page (Window menu, VoiceOver) — \(window.title)")
    navigation.goBack()
    settled = await settle { segments() == [false, true] }
    check(settled && navigation.selection == "general", "after 返回: back on the previous page, 前进 enabled (\(segments()))")
    navigation.goForward()
    settled = await settle { segments() == [true, false] }
    check(settled && navigation.selection == "awake", "after 前进: 返回 enabled again (\(segments()))")
    navigation.goBack()
    _ = await settle { segments() == [false, true] }

    // The toolbar title stays hidden while the hero card shows the page title, like System Settings.
    if #available(macOS 15.0, *) {
        settled = await settle { window.titleVisibility == .hidden }
        check(settled, "toolbar title hidden while the hero card is visible")
        scrollDetail(to: 60)
        settled = await settle(0.6) { window.titleVisibility == .visible }
        check(!settled, "a small scroll (hero title still readable) keeps the toolbar title hidden")
        scrollDetail(to: 400)
        settled = await settle { window.titleVisibility == .visible }
        check(settled, "toolbar title appears once the hero card scrolled away")
        scrollDetail(to: 0)
        settled = await settle { window.titleVisibility == .hidden }
        check(settled, "toolbar title hides again when scrolled back to the top")
        navigation.select("plain")
        settled = await settle { window.titleVisibility == .visible && window.title == "普通页面" }
        check(settled,
              "page without a hero card always shows its toolbar title (\(window.titleVisibility.rawValue), \(window.title))")
        navigation.select("awake")
        settled = await settle { window.titleVisibility == .hidden && window.title == "防止锁屏" }
        check(settled, "switching to a hero page hides the toolbar title again")
        navigation.select("plain")
        settled = await settle { window.titleVisibility == .visible && window.title == "普通页面" }
        check(settled, "…and back to a page without a hero card shows it (reports are kept per page)")
    } else {
        settled = await settle { window.titleVisibility == .visible }
        check(settled, "macOS 14: toolbar title always visible")
    }

    // Search field focus request (编辑 → 查找…).
    let before = navigation.searchFocusRequest
    navigation.focusSearch()
    check(navigation.searchFocusRequest == before + 1, "查找… requests the search field focus")

    // Sidebar tiles follow 外观 → 侧边栏图标大小; hero card proportions of System Settings.
    let tiles = [SidebarRowSize.small, .medium, .large].map(SettingsMetrics.sidebarTileSize(for:))
    check(tiles == [16, 20, 24], "sidebar tile size follows the sidebar icon size setting (\(tiles))")
    check(SettingsHeroCard.tileSize == 48, "hero tile is 48 pt like System Settings")
    let hero = NSHostingView(rootView: SettingsHeroCard(title: "通用", fallbackSummary: "一行说明")
        .environment(\.settingsPaneAppearance, SettingsPaneAppearance(symbol: "gearshape.fill", color: .gray))
        .frame(width: 600))
    let heroHeight = hero.fittingSize.height
    check(heroHeight > 100 && heroHeight < 135, "hero card is compact like System Settings' (\(heroHeight) pt)")
}

@MainActor
func settingsDockPresenceChecks() {
    print("Settings Dock presence")
    var dock = SettingsDockPresence<String>()
    check(!dock.wantsRegularApp && dock.returnTarget == nil, "menu-bar agent while the window was never opened")
    dock.noteActivated("Mail", isSelf: false)
    check(dock.returnTarget == nil, "app switches are ignored while the window is closed")
    dock.windowShown(frontmost: "Safari", frontmostIsSelf: false)
    check(dock.wantsRegularApp && dock.returnTarget == "Safari", "opening Settings: regular app, focus returns to the app it came from")
    dock.noteActivated("OneSwitch", isSelf: true)
    dock.windowShown(frontmost: "OneSwitch", frontmostIsSelf: true)
    check(dock.returnTarget == "Safari", "own activations (⌘-Tab back, 设置… while open) keep the target")
    dock.noteActivated("Finder", isSelf: false)
    check(dock.returnTarget == "Finder", "the most recently active other app becomes the target")
    dock.windowClosed()
    check(!dock.wantsRegularApp, "closing (⌘W / red button) returns to a menu-bar agent")
    dock.windowShown(frontmost: "OneSwitch", frontmostIsSelf: true)
    check(dock.wantsRegularApp && dock.takeReturnTarget(wasActive: true, isAlive: { _ in true }) == nil,
          "reopened before the deferred close handler ran: stays regular, nobody activated")
    check(dock.returnTarget == "Finder", "…and the target is kept for the real close")
    dock.windowClosed()
    check(dock.takeReturnTarget(wasActive: true, isAlive: { _ in true }) == "Finder", "after the close the focus goes to the target")
    check(dock.returnTarget == nil, "the target is used only once")
    dock.windowShown(frontmost: "Xcode", frontmostIsSelf: false)
    dock.windowClosed()
    check(dock.takeReturnTarget(wasActive: false, isAlive: { _ in true }) == nil, "window closed while another app is active: focus untouched")
    dock.windowShown(frontmost: "Notes", frontmostIsSelf: false)
    dock.windowClosed()
    check(dock.takeReturnTarget(wasActive: true, isAlive: { $0 != "Notes" }) == nil, "a target that quit meanwhile is skipped")
}

MainActor.assumeIsolated {
    runChecks()
    // Window-level checks run under the real event loop. `.prohibited`: no Dock icon, never activated,
    // so the check never takes the keyboard focus (its window is never ordered on screen either).
    NSApp.setActivationPolicy(.prohibited)
    Task { @MainActor in
        await settingsShellChecks()
        print(failures == 0 ? "CoreCheck: ALL PASSED" : "CoreCheck: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
    NSApp.run()
}
