import AppKit
import ApplicationServices
import OneSwitchCore

/// One row of the experimental item list.
public struct MenuBarItemRow: Identifiable, Equatable {
    public var info: MenuBarItemInfo
    public var icon: NSImage?
    public var id: String { info.id }

    public static func == (a: MenuBarItemRow, b: MenuBarItemRow) -> Bool { a.info == b.info }
}

/// Outcome of the last "移到隐藏区 / 移到显示区" action.
public struct MoveResult: Equatable {
    public var itemID: String
    public var success: Bool
    public var message: String
}

extension MenuBarClassifier {
    /// Classifies a scan. Without anchors (hider disabled) items are only "visible" or "offscreen".
    public static func classifyAll(_ items: [MenuBarItemInfo], anchors: MenuBarAnchors?, bands: [CGRect],
                                   overflowChevron: CGRect?) -> [MenuBarItemInfo] {
        let parked = parkedIndices(items.map(\.frame))
        return items.enumerated().map { index, item in
            var item = item
            if let anchors {
                item.section = classify(frame: item.frame, anchors: anchors, bands: bands,
                                        overflowChevron: overflowChevron, isParked: parked.contains(index))
            } else {
                let inBar = item.frame.width > 0 && MenuBarGeometry.isInMenuBar(item.frame, bands: bands)
                item.section = inBar ? (parked.contains(index) ? .overflow : .visible) : .offscreen
            }
            return item
        }
    }

    /// Display order: menu-bar sections left → right within each group.
    public static func sortedForDisplay(_ items: [MenuBarItemInfo]) -> [MenuBarItemInfo] {
        let rank: [MenuBarSection: Int] = [.visible: 0, .hidden: 1, .alwaysHidden: 2, .overflow: 3, .offscreen: 4]
        return items.sorted {
            let r0 = rank[$0.section] ?? 9, r1 = rank[$1.section] ?? 9
            if r0 != r1 { return r0 < r1 }
            return $0.frame.minX < $1.frame.minX
        }
    }
}

extension MenuBarHiderController {
    // MARK: - Temporarily expanding while arranging

    struct ArrangeToken {
        var prior: RevealStateMachine.Visibility
        var changed: Bool
    }

    /// Reveals everything (positions are only meaningful while expanded) and holds the auto-collapse.
    func beginArranging() -> ArrangeToken {
        arrangeHolds += 1
        let prior = driver.visibility
        guard isActive, prior != .expandedAll else { return ArrangeToken(prior: prior, changed: false) }
        driver.expand(revealAlwaysHidden: true)
        return ArrangeToken(prior: prior, changed: true)
    }

    func endArranging(_ token: ArrangeToken) {
        arrangeHolds = max(0, arrangeHolds - 1)
        guard started, isActive, token.changed else { return }
        switch token.prior {
        case .collapsed: driver.collapse()
        case .expanded: driver.expand()
        case .expandedAll: break
        }
    }

    private func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Listing

    /// Re-reads the menu-bar items (experimental). Temporarily expands so positions are meaningful.
    public func refreshItems() {
        guard currentTask == nil else { return }
        currentTask = Task { [weak self] in
            await self?.performRefresh()
            self?.currentTask = nil
        }
    }

    private func performRefresh() async {
        isBusy = true
        defer { isBusy = false }
        let token = beginArranging()
        defer { endArranging(token) }
        if token.changed { await sleep(0.5) }
        guard !Task.isCancelled, started else { return }
        let (result, classified) = await scanAndClassify()
        guard !Task.isCancelled, started else { return }
        items = rows(for: classified)
        lastScan = Date()
        listNote = result.note ?? (result.source == .windowList ? "列表来自窗口信息（未使用辅助功能）" : nil)
        AppLog.info("menubar", "listed \(classified.count) menu-bar items via \(result.source?.rawValue ?? "none")")
    }

    /// Scans off-main and classifies against our separators (read on the main actor).
    func scanAndClassify() async -> (MenuBarScanResult, [MenuBarItemInfo]) {
        let screens = ScreenGeometry.current()
        let bands = MenuBarGeometry.menuBarBands(screens: screens, thickness: NSStatusBar.system.thickness)
        let apps = RunningAppInfo.current()
        let ownPID = getpid()
        let result: MenuBarScanResult = await withCheckedContinuation { continuation in
            scanQueue.async {
                continuation.resume(returning: MenuBarItemScanner.scan(apps: apps, excludingPID: ownPID, bands: bands))
            }
        }
        let classified = MenuBarClassifier.classifyAll(result.items, anchors: currentAnchors(screens: screens),
                                                       bands: bands, overflowChevron: result.overflowChevron)
        return (result, MenuBarClassifier.sortedForDisplay(classified))
    }

    /// Our items' frames in CG coordinates (nil when not installed / not laid out).
    func currentAnchors(screens: [ScreenGeometry]) -> MenuBarAnchors? {
        guard isActive, let primaryMaxY = screens.first?.frame.maxY else { return nil }
        let f = statusItems.frames()
        guard let toggle = f.toggle, let separator = f.separator else { return nil }
        return MenuBarAnchors(toggle: MenuBarGeometry.toCG(toggle, primaryMaxY: primaryMaxY),
                              separator: MenuBarGeometry.toCG(separator, primaryMaxY: primaryMaxY),
                              alwaysHidden: f.alwaysHidden.map { MenuBarGeometry.toCG($0, primaryMaxY: primaryMaxY) })
    }

    private func rows(for infos: [MenuBarItemInfo]) -> [MenuBarItemRow] {
        var iconCache: [pid_t: NSImage] = [:]
        return infos.map { info in
            var icon: NSImage?
            if info.bundleID == MenuBarItemScanner.menuBarAgentBundleID {
                icon = NSImage(systemSymbolName: Self.symbol(forSystemItem: info.identifier), accessibilityDescription: nil)
            } else if let cached = iconCache[info.pid] {
                icon = cached
            } else if let appIcon = NSRunningApplication(processIdentifier: info.pid)?.icon {
                iconCache[info.pid] = appIcon
                icon = appIcon
            }
            return MenuBarItemRow(info: info, icon: icon)
        }
    }

    static func symbol(forSystemItem identifier: String?) -> String {
        let name = identifier.map { $0.replacingOccurrences(of: "com.apple.menuextra.", with: "") } ?? ""
        switch name {
        case "wifi": return "wifi"
        case "clock": return "clock"
        case "controlcenter": return "switch.2"
        case "focusmode": return "moon"
        case "battery": return "battery.75percent"
        case "bluetooth": return "dot.radiowaves.left.and.right"
        case "sound", "volume": return "speaker.wave.2"
        case "display", "brightness": return "sun.max"
        case "airdrop": return "antenna.radiowaves.left.and.right"
        case "nowplaying": return "play.circle"
        case "screenmirroring": return "rectangle.on.rectangle"
        case "siri": return "mic"
        case "spotlight": return "magnifyingglass"
        case "user": return "person.crop.circle"
        case "timemachine": return "clock.arrow.circlepath"
        case "textinput": return "keyboard"
        default: return "gearshape"
        }
    }

    // MARK: - Moving (synthetic ⌘-drag, experimental)

    /// Moves an item across the separator with a synthetic ⌘-drag, then verifies the result.
    public func moveItem(id: String, to destination: MoveDestination) {
        guard currentTask == nil else { return }
        guard isActive else {
            moveResult = MoveResult(itemID: id, success: false, message: "请先启用菜单栏图标隐藏")
            return
        }
        guard AXIsProcessTrusted() else {
            moveResult = MoveResult(itemID: id, success: false, message: "需要先授予“辅助功能”权限")
            Permissions.request(.accessibility)
            return
        }
        currentTask = Task { [weak self] in
            await self?.performMove(id: id, to: destination)
            self?.currentTask = nil
        }
    }

    private func performMove(id: String, to destination: MoveDestination) async {
        isBusy = true
        movingItemID = id
        defer {
            isBusy = false
            movingItemID = nil
        }
        let token = beginArranging()
        defer { endArranging(token) }
        if token.changed { await sleep(0.5) }
        guard !Task.isCancelled, started else { return }

        func finish(_ success: Bool, _ message: String) {
            moveResult = MoveResult(itemID: id, success: success, message: message)
            AppLog.info("menubar", "move \(id) → \(destination.rawValue): \(success ? "ok" : "failed") (\(message))")
        }

        let (_, before) = await scanAndClassify()
        guard !Task.isCancelled, started else { return }
        items = rows(for: before)
        guard let anchors = currentAnchors(screens: ScreenGeometry.current()) else {
            finish(false, "菜单栏尚未就绪，请稍后再试")
            return
        }
        guard let item = before.first(where: { $0.id == id }) else {
            finish(false, "找不到该图标，请刷新列表后重试")
            return
        }
        let target: MenuBarSection = destination == .hidden ? .hidden : .visible
        if item.section == target {
            finish(true, "该图标已在\(target.title)")
            return
        }
        guard item.isMovable else {
            finish(false, "macOS 不允许移动此系统图标")
            return
        }
        guard item.section == .visible || item.section == .hidden || item.section == .alwaysHidden else {
            finish(false, "该图标当前没有显示在菜单栏上，无法拖动")
            return
        }

        let start = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let end = DragPlanner.dropPoint(for: destination, separator: anchors.separator, toggle: anchors.toggle)
        let events = DragPlanner.commandDragSequence(from: start, to: end)
        let poster = self.poster
        let posted: Bool = await withCheckedContinuation { continuation in
            poster.post(events) { continuation.resume(returning: $0) }
        }
        guard !Task.isCancelled, started else { return }
        guard posted else {
            finish(false, "发送模拟拖动失败")
            return
        }
        await sleep(0.6)
        guard !Task.isCancelled, started else { return }

        let (_, after) = await scanAndClassify()
        guard !Task.isCancelled, started else { return }
        items = rows(for: after)
        lastScan = Date()
        guard let moved = after.first(where: { $0.id == id }) else {
            finish(false, "拖动后找不到该图标，请刷新列表确认")
            return
        }
        if moved.section == target {
            finish(true, "已移到\(target.title)")
        } else {
            finish(false, "移动失败：macOS 没有接受这次拖动（部分系统图标无法移动），可以按住 ⌘ 手动拖动")
        }
    }
}
