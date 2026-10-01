import AppKit
import Combine
import SwiftUI
import OneSwitchCore

/// Persisted settings of 文件同步 (UserDefaults key "sync.settings").
struct FolderSyncSettings: Codable, Equatable {
    var enabled = true
    var pausedAll = false
    var folders: [FolderConfig] = []
    var ignoredOffers: [String] = []
}

/// 文件同步 — Syncthing-like real-time folder sync with the other Mac over the peer link (service "sync").
@MainActor
public final class FolderSyncModule: FeatureModule, ObservableObject {
    public let id = "sync"
    public let displayName = "文件同步"
    public let symbolName = "arrow.triangle.2.circlepath"

    private let hub: any PeerHub
    let settings: SettingsStore<FolderSyncSettings>
    private let stateDirectory: URL
    private let engineOptions: SyncEngine.Options

    @Published private(set) var snapshot = EngineSnapshot.empty
    @Published private(set) var peerStatus: PeerLinkStatus = .searching

    private(set) var engine: SyncEngine?
    /// Incremented per engine instance so a late snapshot of a stopped engine is ignored.
    private var engineGeneration = 0
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var knownConflictIDs: Set<String>?
    private var knownErrorFolders = Set<String>()
    private var restartScheduled = false
    private var lastAutomaticRestart: Date?

    public convenience init(hub: any PeerHub) {
        self.init(hub: hub, defaults: AppContext.shared.defaults,
                  stateDirectory: AppContext.shared.dataDirectory.appendingPathComponent("sync", isDirectory: true))
    }

    /// Designated initializer with injectable storage (used by self-checks).
    public init(hub: any PeerHub, defaults: UserDefaults, stateDirectory: URL, options: SyncEngine.Options = SyncEngine.Options()) {
        self.hub = hub
        self.defaults = defaults
        self.stateDirectory = stateDirectory
        self.engineOptions = options
        self.settings = SettingsStore(key: "sync.settings", defaultValue: FolderSyncSettings(), defaults: defaults)
    }

    // MARK: - FeatureModule

    public func start() {
        guard !started else { return }
        started = true
        hub.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.peerStatus = status }
            .store(in: &cancellables)
        if settings.value.enabled { startEngine() }
    }

    public func stop() {
        stopEngine()
        cancellables.removeAll()
        started = false
    }

    public func settingsView() -> AnyView {
        AnyView(FolderSyncSettingsView(model: self, settings: settings))
    }

    public func menuItems() -> [NSMenuItem] {
        let value = settings.value
        guard value.enabled else {
            return [
                .info("文件同步已关闭"),
                BlockMenuItem("开启文件同步", symbol: "power") { [weak self] in self?.setEnabled(true) },
            ]
        }
        var items: [NSMenuItem] = [.info(overallLine)]
        for folder in displayedFolders {
            items.append(.submenu("\(folder.label) — \(folder.state.displayText)", symbol: folderSymbol(folder.state),
                                  items: folderMenuItems(folder)))
        }
        if !value.folders.isEmpty {
            if value.pausedAll {
                items.append(BlockMenuItem("继续全部同步", symbol: "play.fill") { [weak self] in self?.setPausedAll(false) })
            } else {
                items.append(BlockMenuItem("暂停全部同步", symbol: "pause.fill") { [weak self] in self?.setPausedAll(true) })
            }
        }
        for offer in snapshot.offers {
            items.append(.info("对方共享了文件夹「\(offer.label)」", symbol: "folder.badge.plus"))
            items.append(BlockMenuItem("接受「\(offer.label)」…") { [weak self] in self?.acceptOffer(offer) })
        }
        items.append(BlockMenuItem("添加同步文件夹…", symbol: "plus") { [weak self] in self?.addFolderInteractively() })
        items.append(BlockMenuItem("文件同步设置…") { AppContext.shared.openSettings(moduleID: "sync") })
        return items
    }

    private func folderMenuItems(_ folder: FolderStatus) -> [NSMenuItem] {
        var items: [NSMenuItem] = [
            .info((folder.path as NSString).abbreviatingWithTildeInPath),
            .info("\(folder.fileCount) 个文件 · \(Fmt.bytes(folder.totalBytes))"),
        ]
        if folder.needItems > 0 {
            var line = "待同步 \(folder.needItems) 项 · \(Fmt.bytes(folder.needBytes))"
            if folder.rate > 0 { line += " · \(Fmt.rate(folder.rate))" }
            items.append(.info(line))
        }
        if let last = folder.lastSyncAt { items.append(.info("上次同步：\(Self.relative(last))")) }
        if !folder.conflicts.isEmpty { items.append(.info("\(folder.conflicts.count) 个冲突文件")) }
        items.append(.separator())
        items.append(BlockMenuItem("打开文件夹", symbol: "folder") { [weak self] in self?.openFolder(folder.id) })
        items.append(BlockMenuItem("立即扫描", symbol: "arrow.clockwise") { [weak self] in self?.rescan(folder.id) })
        let paused = settings.value.folders.first { $0.id == folder.id }?.paused ?? false
        items.append(BlockMenuItem(paused ? "继续同步" : "暂停同步", symbol: paused ? "play" : "pause") { [weak self] in
            self?.setFolderPaused(folder.id, !paused)
        })
        return items
    }

    private func folderSymbol(_ state: FolderSyncState) -> String {
        switch state {
        case .idle: return "checkmark.circle"
        case .scanning, .syncing: return "arrow.triangle.2.circlepath"
        case .paused: return "pause.circle"
        case .waitingForPeer, .waitingForShare: return "clock"
        case .error: return "exclamationmark.triangle"
        }
    }

    // MARK: - Derived state

    /// Folder rows: engine state when available, configured folders otherwise.
    var displayedFolders: [FolderStatus] {
        let configured = settings.value.folders
        let byID = Dictionary(snapshot.folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return configured.map { cfg in
            if var status = byID[cfg.id] {
                status.label = cfg.label
                return status
            }
            return FolderStatus(id: cfg.id, label: cfg.label, path: cfg.path,
                                state: settings.value.enabled ? (cfg.paused || settings.value.pausedAll ? .paused : .scanning) : .paused,
                                fileCount: 0, directoryCount: 0, totalBytes: 0, needItems: 0, needBytes: 0, rate: 0,
                                lastSyncAt: nil, recent: [], conflicts: [], issues: [], peerHasFolder: false,
                                peerPaused: false, versioning: cfg.versioning, paused: cfg.paused)
        }
    }

    /// "● 已同步 · 3 个文件夹" / "↻ 正在同步 12 个文件 · 240 MB · 85 MB/s" / "○ 等待连接另一台 Mac".
    var overallLine: String {
        let value = settings.value
        if !value.enabled { return "文件同步已关闭" }
        let folders = displayedFolders
        if folders.isEmpty { return "尚未添加同步文件夹" }
        if value.pausedAll { return "‖ 已暂停全部同步" }
        let items = snapshot.totalNeedItems
        if items > 0 && snapshot.connected {
            var line = "↻ 正在同步 \(items) 个文件 · \(Fmt.bytes(snapshot.totalNeedBytes))"
            let rate = snapshot.totalRate
            if rate > 0 { line += " · \(Fmt.rate(rate))" }
            return line
        }
        let errors = folders.filter { $0.state.isError }.count
        if errors > 0 { return "⚠︎ \(errors) 个文件夹出错" }
        if !snapshot.connected { return "○ 等待连接另一台 Mac" }
        if folders.contains(where: { if case .scanning = $0.state { return true } else { return false } }) {
            return "↻ 正在扫描…"
        }
        let waiting = folders.filter { $0.state == .waitingForShare }.count
        if waiting == folders.count { return "○ 等待另一台 Mac 接受共享" }
        return "● 已同步 · \(folders.count) 个文件夹"
    }

    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_Hans")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func clockTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans")
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "M月d日 HH:mm"
        return f.string(from: date)
    }

    // MARK: - Engine lifecycle

    /// Stable id of this Mac in version vectors: the peer hub's id, or (if the hub has none) a random id
    /// persisted once. It must never change while the index exists.
    private var localDeviceID: String {
        let hubID = hub.localDeviceID
        if !hubID.isEmpty { return hubID }
        let key = "sync.deviceID"
        if let stored = defaults.string(forKey: key), !stored.isEmpty { return stored }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: key)
        return generated
    }

    private func startEngine() {
        guard engine == nil else { return }
        let value = settings.value
        engineGeneration += 1
        let generation = engineGeneration
        let name = hub.localDeviceName.isEmpty ? "Mac" : hub.localDeviceName
        let engine = SyncEngine(hub: hub, stateDirectory: stateDirectory, deviceID: localDeviceID,
                                deviceName: name, options: engineOptions,
                                onSnapshot: { [weak self] snap in self?.receive(snap, generation: generation) })
        self.engine = engine
        engine.start(folders: value.folders, pausedAll: value.pausedAll, ignoredOffers: Set(value.ignoredOffers))
        AppLog.info("sync", "engine started with \(value.folders.count) folders")
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.stop()
        self.engine = nil
        snapshot = .empty
    }

    private func receive(_ snap: EngineSnapshot, generation: Int) {
        guard engine != nil, generation == engineGeneration else { return }
        notifyAboutNewProblems(snap)
        if snap != snapshot { snapshot = snap }
        if snap.needsRestart { scheduleEngineRestart() }
    }

    /// The engine found its index database corrupted while running and flagged it for a rebuild:
    /// restart it (at most once a minute, so a failing disk cannot cause a restart loop).
    private func scheduleEngineRestart() {
        guard !restartScheduled else { return }
        if let last = lastAutomaticRestart, Date().timeIntervalSince(last) < 60 { return }
        restartScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.restartScheduled = false
                guard self.started, self.engine != nil, self.settings.value.enabled else { return }
                self.lastAutomaticRestart = Date()
                AppLog.warning("sync", "restarting the sync engine to rebuild its index database")
                self.stopEngine()
                self.startEngine()
            }
        }
    }

    private func notifyAboutNewProblems(_ snap: EngineSnapshot) {
        let conflicts = snap.folders.flatMap(\.conflicts)
        let ids = Set(conflicts.map(\.id))
        if let known = knownConflictIDs {
            for c in conflicts where !known.contains(c.id) {
                AppContext.shared.notify(title: "文件同步冲突", body: Self.conflictMessage(c))
            }
        }
        knownConflictIDs = ids
        let errorFolders = Set(snap.folders.filter { $0.state.isError }.map(\.id))
        for folder in snap.folders where errorFolders.contains(folder.id) && !knownErrorFolders.contains(folder.id) {
            if case .error(let message) = folder.state {
                AppContext.shared.notify(title: "文件同步已停止：\(folder.label)", body: message)
            }
        }
        knownErrorFolders = errorFolders
    }

    /// Notification text: the copy holds this Mac's version only when it was created here.
    static func conflictMessage(_ c: ConflictInfo) -> String {
        let whose = c.createdLocally == false ? "另一台 Mac 的版本" : "本机的版本"
        return "「\(c.originalPath)」在两台 Mac 上都被修改过，\(whose)已另存为「\(SyncPath.name(c.conflictPath))」。"
    }

    // MARK: - Actions

    func setEnabled(_ enabled: Bool) {
        guard settings.value.enabled != enabled else { return }
        settings.update { $0.enabled = enabled }
        if enabled && started { startEngine() } else if !enabled { stopEngine() }
    }

    func setPausedAll(_ paused: Bool) {
        settings.update { $0.pausedAll = paused }
        engine?.setPausedAll(paused)
    }

    func setFolderPaused(_ folderID: String, _ paused: Bool) {
        updateFolder(folderID) { $0.paused = paused }
    }

    func rescan(_ folderID: String) {
        engine?.rescan(folderID: folderID)
    }

    func recreateMarker(_ folderID: String) {
        engine?.recreateMarker(folderID: folderID)
    }

    func openFolder(_ folderID: String) {
        guard let cfg = settings.value.folders.first(where: { $0.id == folderID }) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cfg.path, isDirectory: true))
    }

    func reveal(_ conflict: ConflictInfo) {
        let url = URL(fileURLWithPath: conflict.absolutePath)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    func updateFolder(_ folderID: String, _ body: (inout FolderConfig) -> Void) {
        settings.update { value in
            if let i = value.folders.firstIndex(where: { $0.id == folderID }) { body(&value.folders[i]) }
        }
        engine?.update(folders: settings.value.folders)
    }

    /// Applies the fields the editor sheet changes. The rest (pause state, path) is taken from the current
    /// settings, so pausing / resuming while the sheet was open is not reverted by saving it.
    func saveFolder(_ config: FolderConfig) {
        updateFolder(config.id) { folder in
            folder.label = config.label
            folder.ignorePatterns = config.ignorePatterns
            folder.versioning = config.versioning
        }
    }

    /// Removes a folder from sync. Never deletes any file.
    func removeFolder(_ folderID: String) {
        settings.update { $0.folders.removeAll { $0.id == folderID } }
        engine?.update(folders: settings.value.folders)
    }

    /// Returns a user-facing error when `path` cannot be synced (overlaps another synced folder, …).
    func validate(path: String, excluding folderID: String? = nil) -> String? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if standardized == "/" || standardized == NSHomeDirectory() {
            return "不能同步整个磁盘或个人文件夹，请选择其中的一个子文件夹。"
        }
        let state = stateDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        if standardized.hasPrefix(state) || state.hasPrefix(standardized + "/") {
            return "不能同步 OneSwitch 的数据文件夹。"
        }
        for f in settings.value.folders where f.id != folderID {
            let other = URL(fileURLWithPath: f.path).standardizedFileURL.resolvingSymlinksInPath().path
            if other == standardized || standardized.hasPrefix(other + "/") || other.hasPrefix(standardized + "/") {
                return "该文件夹与已同步的文件夹「\(f.label)」重叠，请选择其他文件夹。"
            }
        }
        return nil
    }

    /// Adds a folder. `folderID` is given when accepting an offer from the other Mac.
    @discardableResult
    func addFolder(path: String, label: String? = nil, folderID: String? = nil) -> String? {
        if let error = validate(path: path) { return error }
        let name = label ?? FileManager.default.displayName(atPath: path)
        let config = FolderConfig(id: folderID ?? FolderConfig.makeID(label: name), label: name, path: path)
        guard !settings.value.folders.contains(where: { $0.id == config.id }) else { return "该文件夹已在同步列表中。" }
        settings.update { value in
            value.folders.append(config)
            value.ignoredOffers.removeAll { $0 == config.id }
        }
        engine?.update(folders: settings.value.folders)
        engine?.setIgnoredOffers(Set(settings.value.ignoredOffers))
        return nil
    }

    func addFolderInteractively() {
        chooseDirectory(message: "选择要与另一台 Mac 同步的文件夹", prompt: "同步此文件夹") { [weak self] url in
            guard let self, let url else { return }
            if let error = self.addFolder(path: url.path) { Self.showAlert("无法添加文件夹", error) }
        }
    }

    func acceptOffer(_ offer: FolderOffer) {
        chooseDirectory(message: "对方共享了文件夹「\(offer.label)」。请选择或新建本机上用于同步的文件夹（已有文件会合并）。",
                        prompt: "接受") { [weak self] url in
            guard let self, let url else { return }
            if let error = self.addFolder(path: url.path, label: offer.label, folderID: offer.id) {
                Self.showAlert("无法接受共享", error)
            }
        }
    }

    func ignoreOffer(_ folderID: String) {
        settings.update { value in
            if !value.ignoredOffers.contains(folderID) { value.ignoredOffers.append(folderID) }
        }
        engine?.setIgnoredOffers(Set(settings.value.ignoredOffers))
    }

    private func chooseDirectory(message: String, prompt: String, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = prompt
        NSApp.activate()
        panel.begin { response in
            completion(response == .OK ? panel.url : nil)
        }
    }

    static func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate()
        alert.runModal()
    }
}
