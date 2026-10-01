import Foundation
import os
import OneSwitchCore

/// The folder-sync engine: index, scanner, FSEvents watcher, protocol and transfers. No UI.
///
/// Threading: all mutable engine state lives on `queue` (serial). Hashing / walking runs on `scanQueue`,
/// serving blocks on `ioQueue` (concurrent), writing pulled blocks on one serial queue per file.
/// Public entry points may be called from any thread except `start` / `stop` (main actor, they talk
/// to the `PeerHub`). The engine never blocks the main thread except in `stop()` (synchronous teardown).
public final class SyncEngine: @unchecked Sendable {
    public struct Options: Sendable {
        public var fsEventLatency: TimeInterval = 0.3
        /// Files ≥ `settleMinSize` whose mtime is younger than this are re-checked later before hashing.
        public var settleTime: TimeInterval = 1.0
        public var settleMinSize: Int64 = 1 << 20
        /// Debounce between a local change and pushing index updates to the peer.
        public var indexDebounce: TimeInterval = 0.2
        /// Minimum interval between UI snapshots (≤ 4 per second).
        public var snapshotInterval: TimeInterval = 0.25
        public var blockSize: Int = 1 << 20
        /// Outstanding block requests per file.
        public var requestWindow: Int = 8
        /// Files transferred in parallel.
        public var maxActiveFiles: Int = 16
        /// Bytes requested but not yet received, across all files (bounds memory).
        public var maxOutstandingBytes: Int = 32 << 20
        /// Blocks being read / sent concurrently when serving the peer.
        public var maxServeInFlight: Int = 16
        public var indexBatchSize: Int = 2000
        public var fullRescanInterval: TimeInterval = 3600
        /// Full scans of one folder start at least this far apart (and at least twice the previous full scan's
        /// duration), however many FSEvents bursts / dropped-event notices request one. Targeted rescans of
        /// changed paths are never delayed by this.
        public var minFullScanInterval: TimeInterval = 1.5
        /// Changed paths waiting for a targeted rescan beyond which a full rescan is cheaper.
        public var maxPendingPaths: Int = 10_000
        /// A remote directory deletion waits for records of its tracked children that may still be on the way
        /// until the peer's last batch did not announce "more" and its index has been quiet this long — or, for a
        /// peer announcing "more", the directory has waited this long (see `remoteIndexSettled`).
        public var remoteIndexSettleTime: TimeInterval = 3
        public var housekeepingInterval: TimeInterval = 2
        public var errorRecheckInterval: TimeInterval = 5
        public var blockedRetryInterval: TimeInterval = 30
        public var transferStallTimeout: TimeInterval = 60
        public var versionRetention: TimeInterval = 30 * 86_400
        public var versionCleanupInterval: TimeInterval = 6 * 3600
        /// Self-checks only: artificial delay before each block write (simulates a slow destination disk).
        public var testWriteDelay: TimeInterval = 0
        /// Self-checks only: artificial delay before verifying a local clone (simulates a huge file).
        public var testVerifyDelay: TimeInterval = 0
        /// Self-checks only: announce deletions parents-first (worst case for the peer's batched apply).
        public var testParentTombstonesFirst = false
        /// Self-checks only: never tell the peer that more index batches follow (like v1.0.2 peers).
        public var testOmitMoreFlag = false

        public init() {}
    }

    public static let missingRootMessage = "文件夹不存在或已被移动"

    public let deviceID: String
    public let deviceName: String
    public let stateDirectory: URL
    let options: Options
    let clock: @Sendable () -> Date

    let queue = DispatchQueue(label: "oneswitch.sync.engine", qos: .utility)
    let scanQueue = DispatchQueue(label: "oneswitch.sync.scan", qos: .utility)
    let ioQueue = DispatchQueue(label: "oneswitch.sync.io", qos: .userInitiated, attributes: .concurrent)
    let writeTargetQueue = DispatchQueue(label: "oneswitch.sync.write", qos: .userInitiated, attributes: .concurrent)
    /// Moves files to the Trash in the background (FileManager.trashItem can take milliseconds per file).
    let trashQueue = DispatchQueue(label: "oneswitch.sync.trash", qos: .utility)

    private weak var hub: (any PeerHub)?
    private let onSnapshot: (@MainActor (EngineSnapshot) -> Void)?
    let cancelFlag = AtomicFlag()

    // MARK: Engine-queue state
    var store: IndexStore?
    var fatalError: String?
    var folders: [String: FolderRuntime] = [:]
    var folderOrder: [String] = []
    var pausedAll = false
    var ignoredOffers = Set<String>()
    var session: PeerSession?
    var generation = 0
    var stopped = false
    var stats = EngineStats()
    var pullQueue = PullQueue()
    var activeJobs: [PullKey: PullJob] = [:]
    /// Block bytes received but not yet written to disk (they count against `maxOutstandingBytes`).
    var bufferedWriteBytes = 0
    var recentCounter: UInt64 = 0
    var snapshotScheduled = false
    struct DeliveryState {
        var inFlight = false
        var lastDelivered = Date.distantPast
    }
    /// Shared with the main thread (delivery bookkeeping only).
    let delivery = OSAllocatedUnfairLock(initialState: DeliveryState())
    var indexFlushScheduled = false
    var housekeepingTimer: DispatchSourceTimer?
    var housekeepingTick = 0
    var lastErrorRecheck = Date.distantPast
    var bootstrapped = false
    var indexRebuildRequested = false

    // Main-actor state
    @MainActor private var started = false
    @MainActor private var stoppedMain = false

    /// - Parameters:
    ///   - hub: the peer connection manager; the engine registers service "sync" while started.
    ///   - stateDirectory: where the index database lives (created if needed).
    ///   - deviceID / deviceName: this Mac (normally `hub.localDeviceID` / `hub.localDeviceName`).
    ///   - clock: wall clock for user-visible timestamps (conflict names, recent changes).
    ///   - onSnapshot: receives throttled UI snapshots on the main actor.
    @MainActor
    public init(hub: any PeerHub, stateDirectory: URL, deviceID: String, deviceName: String,
                options: Options = Options(), clock: @escaping @Sendable () -> Date = { Date() },
                onSnapshot: (@MainActor (EngineSnapshot) -> Void)? = nil) {
        self.hub = hub
        self.stateDirectory = stateDirectory
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.options = options
        self.clock = clock
        self.onSnapshot = onSnapshot
    }

    // MARK: - Public API

    /// Opens the index (on the engine queue), applies the folder configuration and registers the service.
    @MainActor
    public func start(folders: [FolderConfig], pausedAll: Bool = false, ignoredOffers: Set<String> = []) {
        guard !started, !stoppedMain else { return }
        started = true
        queue.async { self.bootstrap(folders: folders, pausedAll: pausedAll, ignoredOffers: ignoredOffers) }
        hub?.register(service: SyncProtocol.service) { [weak self] channel in
            self?.channelOpened(channel)
        }
    }

    /// Synchronously releases everything: unregisters the service (closing the channel), stops FSEvents
    /// streams, aborts transfers (closing files, removing temp files), waits for a running scan to stop and
    /// closes the database. The engine cannot be restarted afterwards.
    @MainActor
    public func stop() {
        guard !stoppedMain else { return }
        stoppedMain = true
        if started { hub?.unregister(service: SyncProtocol.service) }
        cancelFlag.set()
        queue.sync { self.teardown() }
        scanQueue.sync {}
        // Pending block reads / trash moves finish quickly; wait so no file handle outlives stop().
        ioQueue.sync(flags: .barrier) {}
        // Writers aborted asynchronously earlier (e.g. when the channel dropped) close and delete their
        // temp files on their queues, which target this one.
        writeTargetQueue.sync(flags: .barrier) {}
        trashQueue.sync {}
    }

    public func update(folders configs: [FolderConfig]) {
        queue.async { self.applyConfigs(configs) }
    }

    public func setPausedAll(_ paused: Bool) {
        queue.async {
            guard self.pausedAll != paused else { return }
            self.pausedAll = paused
            for id in self.folderOrder {
                if let rt = self.folders[id] { self.refreshActivation(rt) }
            }
            self.announceFolders()
            self.markDirty()
        }
    }

    public func setIgnoredOffers(_ ids: Set<String>) {
        queue.async {
            self.ignoredOffers = ids
            self.markDirty()
        }
    }

    /// "立即扫描": full rescan (also retries a folder in error state).
    public func rescan(folderID: String) {
        queue.async {
            guard let rt = self.folders[folderID] else { return }
            if rt.active {
                self.requestFullScan(rt)
            } else {
                self.refreshActivation(rt, retryError: true)
            }
        }
    }

    /// Recreates the ".oneswitch" marker of a folder whose marker is missing (after the user confirmed
    /// that the folder at its path is the right one), then scans it.
    public func recreateMarker(folderID: String) {
        queue.async {
            guard let rt = self.folders[folderID] else { return }
            let path = rt.config.path
            guard let real = FS.realPath(path), FS.isDirectory(real) else {
                self.setError(rt, Self.missingRootMessage)
                return
            }
            if mkdir(real + "/" + SyncPath.markerName, 0o755) != 0 && errno != EEXIST {
                self.setError(rt, "无法创建 .oneswitch 标记目录：\(FS.localizedError(errno))")
                return
            }
            AppLogSync.info("recreated marker for folder \(folderID) at \(real)")
            self.refreshActivation(rt, retryError: true)
        }
    }

    /// Builds a snapshot synchronously (blocks until the engine queue is free). For diagnostics / checks;
    /// the UI gets throttled snapshots through `onSnapshot` instead.
    public func snapshotNow() -> EngineSnapshot {
        queue.sync { self.buildSnapshot() }
    }

    // MARK: - Bootstrap / teardown (engine queue)

    private func bootstrap(folders configs: [FolderConfig], pausedAll: Bool, ignoredOffers: Set<String>) {
        guard !stopped else { return }
        self.pausedAll = pausedAll
        self.ignoredOffers = ignoredOffers
        do {
            let (store, recovered) = try IndexStore.open(directory: stateDirectory)
            self.store = store
            if recovered {
                // The rebuilt index no longer knows where the folders were initialized. Record their
                // current paths as initialized so activation *requires* the existing ".oneswitch" marker:
                // a folder that was moved / emptied / is an unmounted mount point must not get a fresh
                // marker (and then be filled or, worse, treated as the real folder) just because the index
                // was lost. Every file is re-hashed; version counters restart above the old ones (see
                // `commitLocal`), so local edits are never overwritten by the peer's older versions.
                AppLogSync.warning("index database was rebuilt: all folders are rescanned and re-announced")
                store.batch {
                    for cfg in configs where !cfg.id.isEmpty { store.setMeta("folder.\(cfg.id).path", cfg.path) }
                }
            }
            // Forget folders that were removed while the engine was not running.
            let configured = Set(configs.map(\.id))
            for id in store.folderIDs() where !configured.contains(id) {
                AppLogSync.info("dropping index of removed folder \(id)")
                store.dropFolder(id)
            }
        } catch {
            AppLogSync.error("cannot open index database: \(error)")
            fatalError = "无法打开索引数据库"
        }
        bootstrapped = true
        applyConfigs(configs)
        startHousekeeping()
        markDirty()
    }

    private func teardown() {
        guard !stopped else { return }
        stopped = true
        housekeepingTimer?.cancel()
        housekeepingTimer = nil
        if let s = session {
            session = nil
            s.channel.close()
            endSession(s)
        }
        for job in Array(activeJobs.values) { abortJob(job, block: nil, wait: true) }
        activeJobs.removeAll()
        pullQueue.removeAll()
        for rt in folders.values {
            rt.watcher?.stop()
            rt.watcher = nil
            rt.active = false
            rt.epoch += 1
            discardPreparedClones(rt)
        }
        store?.close()
        store = nil
        AppLogSync.info("engine stopped")
    }

    // MARK: - Folder configuration (engine queue)

    func applyConfigs(_ configs: [FolderConfig]) {
        guard !stopped else { return }
        guard bootstrapped else {
            AppLogSync.warning("folder configuration ignored: engine not started")
            return
        }
        var unique: [FolderConfig] = []
        var seen = Set<String>()
        for c in configs where !c.id.isEmpty && seen.insert(c.id).inserted { unique.append(c) }
        let ids = Set(unique.map(\.id))
        for id in folderOrder where !ids.contains(id) { removeFolder(id) }
        for cfg in unique {
            if let rt = folders[cfg.id] {
                let old = rt.config
                guard old != cfg else { continue }
                if old.path != cfg.path {
                    removeFolder(cfg.id)
                    addFolder(cfg)
                    continue
                }
                rt.config = cfg
                if old.ignorePatterns != cfg.ignorePatterns {
                    rt.matcher = IgnoreMatcher(userPatterns: cfg.ignorePatterns)
                    if rt.active { requestFullScan(rt) }
                }
                if old.paused != cfg.paused { refreshActivation(rt) }
            } else {
                addFolder(cfg)
            }
        }
        folderOrder = unique.map(\.id)
        announceFolders()
        markDirty()
    }

    private func addFolder(_ cfg: FolderConfig) {
        let rt = FolderRuntime(config: cfg, now: Date())
        folders[cfg.id] = rt
        guard let store else {
            rt.error = fatalError ?? "无法打开索引数据库"
            return
        }
        let id = cfg.id
        if let s = store.meta("folder.\(id).indexID"), let v = UInt64(s), v != 0 {
            rt.indexID = v
        } else {
            rt.indexID = UInt64.random(in: 1...(1 << 53 - 1))
            store.setMeta("folder.\(id).indexID", String(rt.indexID))
        }
        rt.sequence = max(store.maxSequence(.local, folder: id), Int64(store.meta("folder.\(id).seqBase") ?? "") ?? 0)
        rt.totals = store.totals(folder: id)
        rt.remoteIndexID = UInt64(store.meta("remote.\(id).indexID") ?? "") ?? 0
        rt.remoteMaxSeq = Int64(store.meta("remote.\(id).maxSeq") ?? "") ?? 0
        if let json = store.meta("folder.\(id).conflicts"), let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([ConflictInfo].self, from: data) {
            rt.conflicts = list
        }
        AppLogSync.info("folder \(id) (\(cfg.label)) at \(cfg.path): \(rt.totals.files) files, seq \(rt.sequence)")
        refreshActivation(rt)
    }

    private func removeFolder(_ id: String) {
        guard let rt = folders.removeValue(forKey: id) else { return }
        deactivate(rt)
        if let s = session {
            s.shared.remove(id)
            s.initialReceived.remove(id)
            s.initialSent.remove(id)
            s.indexIncomplete.remove(id)
            s.sentSeq[id] = nil
        }
        store?.dropFolder(id)
        AppLogSync.info("folder \(id) removed (files kept on disk)")
    }

    func isPaused(_ rt: FolderRuntime) -> Bool { pausedAll || rt.config.paused }

    /// Starts or stops watching / scanning according to pause state and root health.
    func refreshActivation(_ rt: FolderRuntime, retryError: Bool = false) {
        if isPaused(rt) {
            if rt.active { deactivate(rt) }
            rt.error = nil
        } else if !rt.active && (rt.error == nil || retryError) {
            activate(rt)
        }
        markDirty()
    }

    func activate(_ rt: FolderRuntime) {
        guard let store, !stopped, fatalError == nil else { return }
        let cfg = rt.config
        let id = cfg.id
        guard let real = FS.realPath(cfg.path), FS.isDirectory(real) else {
            setError(rt, Self.missingRootMessage)
            return
        }
        let initializedPath = store.meta("folder.\(id).path")
        let markerPath = real + "/" + SyncPath.markerName
        if initializedPath != cfg.path {
            // First activation for this location: create the safety marker.
            if mkdir(markerPath, 0o755) != 0 && errno != EEXIST {
                setError(rt, "无法创建 .oneswitch 标记目录：\(FS.localizedError(errno))")
                return
            }
            if initializedPath != nil {
                // The index described another location: start a fresh index (new id → peer resends everything).
                store.setMeta("folder.\(id).seqBase", String(rt.sequence))
                store.clear(.local, folder: id)
                rt.totals = IndexStore.Totals()
                rt.indexID = UInt64.random(in: 1...(1 << 53 - 1))
                store.setMeta("folder.\(id).indexID", String(rt.indexID))
            }
            store.setMeta("folder.\(id).path", cfg.path)
        } else if !Scanner.markerExists(root: real) {
            setError(rt, Self.missingRootMessage)
            return
        }
        rt.realRoot = real
        rt.realRootNFC = SyncPath.normalize(real)
        rt.caseSensitive = FS.isCaseSensitive(real)
        rt.error = nil
        rt.active = true
        rt.epoch += 1
        rt.initialScanDone = false
        let epoch = rt.epoch
        rt.watcher = FSWatcher(path: real, latency: options.fsEventLatency, queue: queue) { [weak self] events in
            self?.handleFSEvents(folderID: id, epoch: epoch, events: events)
        }
        if rt.watcher == nil {
            AppLogSync.warning("folder \(id): FSEvents unavailable, relying on periodic scans")
        }
        resumePendingTrash(rt)
        requestFullScan(rt)
        markDirty()
    }

    func deactivate(_ rt: FolderRuntime) {
        rt.active = false
        rt.epoch += 1
        rt.watcher?.stop()
        rt.watcher = nil
        rt.pendingFull = false
        rt.pendingPaths.removeAll()
        rt.initialScanDone = false
        rt.deferredDirDeletes.removeAll()
        rt.datalessPaths.removeAll()
        cancelPulls(folderID: rt.config.id)
        discardPreparedClones(rt)
        markDirty()
    }

    /// Puts a folder into an error state: nothing is scanned, applied or served until it recovers.
    func setError(_ rt: FolderRuntime, _ message: String) {
        if rt.active { deactivate(rt) }
        if rt.error != message {
            AppLogSync.warning("folder \(rt.config.id): \(message) (\(rt.config.path))")
        }
        rt.error = message
        markDirty()
    }

    // MARK: - Housekeeping

    private func startHousekeeping() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = options.housekeepingInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.housekeeping() }
        timer.resume()
        housekeepingTimer = timer
    }

    private func housekeeping() {
        guard !stopped else { return }
        if let store, store.corruptionDetected, !indexRebuildRequested {
            requestIndexRebuild(store)
            return
        }
        let now = Date()
        housekeepingTick += 1
        // Keep rates in the UI decaying to zero after a transfer ends.
        if folders.values.contains(where: { $0.rate.isActive(now: now) }) || !activeJobs.isEmpty { markDirty() }

        if now.timeIntervalSince(lastErrorRecheck) >= options.errorRecheckInterval {
            lastErrorRecheck = now
            for rt in folders.values where rt.error != nil && !isPaused(rt) {
                activate(rt) // no-op (stays in error) while the root / marker is still missing
            }
            // A folder whose root disappeared without an FSEvents notification.
            for rt in folders.values where rt.active {
                if let root = rt.realRoot, !Scanner.markerExists(root: root) { setError(rt, Self.missingRootMessage) }
            }
            // Stalled transfers (peer stopped answering) are abandoned and retried later. Local clones are
            // exempt: they need nothing from the peer, and verifying a large one on a slow disk can take longer
            // than the timeout (aborting it would retry — and abort — it forever).
            for job in Array(activeJobs.values)
            where job.streaming && now.timeIntervalSince(job.lastActivity) > options.transferStallTimeout {
                AppLogSync.warning("transfer of \(job.key.path) stalled; retrying later")
                abortJob(job, block: .remoteUnavailable)
            }
            startPulls()
        }
        // Blocked paths are retried with exponential backoff (30 s, 1 min, 2 min … 1 h).
        for rt in folders.values where !rt.blockedRetry.isEmpty {
            let due = rt.blockedRetry.filter { $0.value.next <= now }.map(\.key)
            guard !due.isEmpty else { continue }
            evaluate(rt, paths: due)
            // Paths that are neither resolved nor re-blocked (e.g. still transferring) wait a full interval.
            for p in due {
                if let entry = rt.blockedRetry[p], entry.next <= now {
                    rt.blockedRetry[p] = (entry.attempts, now.addingTimeInterval(options.blockedRetryInterval))
                }
            }
        }
        // Directory deletions waiting for children: retry (children may have been processed by transfers
        // finishing, or the peer's index has settled so remaining children are known to stay).
        for rt in folders.values where rt.active && !rt.deferredDirDeletes.isEmpty {
            processDeferredDirectories(rt)
        }
        for rt in folders.values where rt.active && rt.initialScanDone {
            // Without FSEvents (stream creation failed) fall back to frequent full scans.
            let interval = rt.watcher == nil ? min(60, options.fullRescanInterval) : options.fullRescanInterval
            if now.timeIntervalSince(rt.lastFullScanAt) >= interval {
                requestFullScan(rt)
            }
            // Any versions folder is pruned, whatever the current mode: it may hold versions from an earlier
            // "保存到 .oneswitch/versions" setting or from the Trash fallback on volumes without a Trash.
            if let root = rt.realRoot,
               now.timeIntervalSince(rt.lastVersionCleanup ?? .distantPast) >= options.versionCleanupInterval {
                rt.lastVersionCleanup = now
                let retention = options.versionRetention
                let date = clock()
                let cancel = cancelFlag
                scanQueue.async {
                    let n = Scanner.cleanVersions(root: root, retention: retention, now: date) { cancel.isSet }
                    if n > 0 { AppLogSync.info("removed \(n) old versions in \(root)") }
                }
            }
        }
    }

    /// SQLite reported corruption while running: stop touching the folders (decisions based on a damaged
    /// index could be wrong), flag the database for a rebuild and ask the owner to restart the engine
    /// (`EngineSnapshot.needsRestart`).
    private func requestIndexRebuild(_ store: IndexStore) {
        indexRebuildRequested = true
        AppLogSync.error("index database reported corruption; it will be rebuilt when the engine restarts")
        store.flagForRebuild()
        let message = "索引数据库已损坏，正在重建…"
        fatalError = message
        for rt in folders.values { setError(rt, message) }
        if let s = session {
            session = nil
            s.channel.close()
            endSession(s)
        }
        markDirty()
    }

    /// Self-checks only: behave as if SQLite had reported corruption.
    func simulateIndexCorruption() {
        queue.async { self.store?.simulateCorruption() }
    }

    // MARK: - Snapshot

    /// Schedules a UI snapshot. At most one delivery is in flight and consecutive deliveries on the main
    /// thread are at least `snapshotInterval` apart (≤ 4 updates/s), however busy either side is.
    func markDirty() {
        guard !snapshotScheduled, !stopped, onSnapshot != nil else { return }
        snapshotScheduled = true
        let lastDelivered = delivery.withLock { $0.lastDelivered }
        let wait = max(0, options.snapshotInterval - Date().timeIntervalSince(lastDelivered))
        queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.emitSnapshot() }
    }

    private func emitSnapshot() {
        guard !stopped, let handler = onSnapshot else {
            snapshotScheduled = false
            return
        }
        let (inFlight, lastDelivered) = delivery.withLock { ($0.inFlight, $0.lastDelivered) }
        let remaining = options.snapshotInterval - Date().timeIntervalSince(lastDelivered)
        if inFlight || remaining > 0 {
            // The previous snapshot has not reached the main thread yet, or it did so too recently.
            let wait = inFlight ? options.snapshotInterval / 2 : remaining
            queue.asyncAfter(deadline: .now() + wait) { [weak self] in self?.emitSnapshot() }
            return
        }
        snapshotScheduled = false
        let snap = buildSnapshot()
        delivery.withLock { $0.inFlight = true }
        let delivery = self.delivery
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler(snap) }
            delivery.withLock {
                $0.inFlight = false
                $0.lastDelivered = Date()
            }
        }
    }

    func buildSnapshot() -> EngineSnapshot {
        var snap = EngineSnapshot()
        let now = Date()
        let s = session
        snap.connected = s?.helloReceived ?? false
        snap.peerName = s?.helloReceived == true ? s?.name : nil
        snap.pausedAll = pausedAll
        snap.stats = stats
        snap.needsRestart = indexRebuildRequested

        var needItems: [String: Int] = [:]
        var needBytes: [String: Int64] = [:]
        for (key, size) in pullQueue.items {
            needItems[key.folder, default: 0] += 1
            needBytes[key.folder, default: 0] += size
        }
        for job in activeJobs.values {
            needItems[job.key.folder, default: 0] += 1
            needBytes[job.key.folder, default: 0] += max(0, job.remote.size - job.received)
        }
        for id in folderOrder {
            guard let rt = folders[id] else { continue }
            let items = needItems[id, default: 0] + rt.deferredDirDeletes.count
            let bytes = needBytes[id, default: 0]
            let peerFolder = s?.helloReceived == true ? s?.peerFolders[id] : nil
            let state: FolderSyncState
            if isPaused(rt) {
                state = .paused
            } else if let err = rt.error ?? fatalError {
                state = .error(err)
            } else if rt.scanRunning && (rt.scanIsFull || !rt.initialScanDone) {
                state = .scanning
            } else if s?.helloReceived != true {
                state = .waitingForPeer
            } else if peerFolder == nil {
                state = .waitingForShare
            } else if items > 0 {
                let total = Double(rt.burstDone + bytes)
                state = .syncing(progress: total > 0 ? Double(rt.burstDone) / total : 0)
            } else {
                state = .idle
            }
            if case .idle = state {
                rt.burstDone = 0
                if s?.initialReceived.contains(id) == true { rt.lastSyncAt = clock() }
            }
            var issues = rt.problems
            if !rt.datalessPaths.isEmpty {
                let examples = rt.datalessPaths.sorted().prefix(3).map { "「\($0)」" }.joined(separator: "、")
                issues.insert("\(rt.datalessPaths.count) 个文件仅存储在 iCloud 中（未下载到本机），下载后才会同步：\(examples)"
                              + (rt.datalessPaths.count > 3 ? " 等" : ""), at: 0)
            }
            issues.append(contentsOf: rt.issues.sorted { $0.key < $1.key }.map(\.value))
            var seenIssues = Set<String>()
            issues = issues.filter { seenIssues.insert($0).inserted } // rows are identified by their text
            let status = FolderStatus(
                id: id, label: rt.config.label, path: rt.config.path, state: state,
                fileCount: rt.totals.files + rt.totals.symlinks, directoryCount: rt.totals.directories,
                totalBytes: rt.totals.bytes, needItems: items, needBytes: bytes,
                rate: rt.rate.rate(now: now), lastSyncAt: rt.lastSyncAt, recent: rt.recent,
                conflicts: rt.conflicts, issues: Array(issues.prefix(50)),
                peerHasFolder: peerFolder != nil, peerPaused: peerFolder?.paused ?? false,
                versioning: rt.config.versioning, paused: isPaused(rt))
            snap.folders.append(status)
        }
        if let s, s.helloReceived {
            for f in s.peerFolderOrder {
                guard folders[f] == nil, !ignoredOffers.contains(f), let pf = s.peerFolders[f] else { continue }
                snap.offers.append(FolderOffer(id: f, label: pf.label, peerName: s.name))
            }
        }
        return snap
    }

    // MARK: - Test / diagnostics helpers

    func localRecord(folderID: String, path: String) -> FileRecord? {
        queue.sync { store?.record(.local, folder: folderID, path: path) }
    }

    func remoteRecord(folderID: String, path: String) -> FileRecord? {
        queue.sync { store?.record(.remote, folder: folderID, path: path) }
    }

    /// True when nothing is queued, transferring, scanning or waiting to be announced.
    func isQuiescent() -> Bool {
        queue.sync {
            activeJobs.isEmpty && pullQueue.isEmpty && !indexFlushScheduled
                && folders.values.allSatisfy {
                    !$0.scanRunning && !$0.scanScheduled && $0.pendingPaths.isEmpty && !$0.pendingFull && $0.deferredDirDeletes.isEmpty
                }
                && (session.map { $0.indexSending.isEmpty } ?? true)
        }
    }
}

// MARK: - Runtime state

final class FolderRuntime {
    var config: FolderConfig
    var matcher: IgnoreMatcher
    var realRoot: String?
    var realRootNFC = ""
    var watcher: FSWatcher?
    var error: String?
    /// Incremented on every (de)activation; asynchronous work from an older epoch is discarded.
    var epoch = 0
    var active = false
    var initialScanDone = false
    var scanRunning = false
    var scanIsFull = false
    var scanScheduled = false
    var pendingFull = false
    var pendingPaths = Set<String>()
    /// A delayed full scan is waiting for `minFullScanInterval` to pass.
    var fullScanTimerArmed = false
    /// System uptime when the last full scan started, and how long it took.
    var lastFullScanStart: TimeInterval = -.infinity
    var lastFullScanDuration: TimeInterval = 0
    /// System uptime of the last index message received from the peer for this folder.
    var lastRemoteIndexAt: TimeInterval = -.infinity
    var caseSensitive = false
    var totals = IndexStore.Totals()
    var sequence: Int64 = 0
    var indexID: UInt64 = 0
    var remoteIndexID: UInt64 = 0
    var remoteMaxSeq: Int64 = 0
    var recent: [RecentChange] = []
    var conflicts: [ConflictInfo] = []
    /// Per-path problems shown in the UI (case conflicts, obstructions).
    var issues: [String: String] = [:]
    /// Problems reported by the last scan (unreadable files / directories).
    var problems: [String] = []
    /// Files that are dataless placeholders (iCloud "optimized storage"): skipped until downloaded.
    var datalessPaths = Set<String>()
    var lastSyncAt: Date?
    var blocked: [String: BlockReason] = [:]
    /// Backoff state of blocked paths: attempts so far and when to retry next.
    var blockedRetry: [String: (attempts: Int, next: Date)] = [:]
    /// Directories the peer deleted (or replaced by a file / symlink) whose removal waits for their tracked
    /// children (deletions still arriving in later index batches, transfers in flight). Their local record stays
    /// live meanwhile, so the scanner never mistakes them for new directories.
    var deferredDirDeletes = DeferredDirectories()
    /// Temp files already cloned from identical local content (path → temp path + content hash),
    /// prepared before deletions of the same batch run so renames never re-transfer data.
    var preparedClones: [String: (temp: String, hash: Data)] = [:]
    var rate = RateMeter()
    var burstDone: Int64 = 0
    var lastFullScanAt: Date
    var lastVersionCleanup: Date?

    init(config: FolderConfig, now: Date) {
        self.config = config
        self.matcher = IgnoreMatcher(userPatterns: config.ignorePatterns)
        self.lastFullScanAt = now
    }

    func absolute(_ rel: String) -> String {
        guard let root = realRoot else { return config.path + "/" + rel }
        return rel.isEmpty ? root : root + "/" + rel
    }
}

/// Paths of deferred directory deletions / replacements, with the system uptime at which each started waiting.
struct DeferredDirectories {
    private var started: [String: TimeInterval] = [:]

    var isEmpty: Bool { started.isEmpty }
    var count: Int { started.count }
    var paths: [String] { Array(started.keys) }

    /// When `path` started waiting (nil: it is not waiting).
    func since(_ path: String) -> TimeInterval? { started[path] }

    /// Returns true when `path` was not waiting yet.
    @discardableResult
    mutating func insert(_ path: String) -> Bool {
        guard started[path] == nil else { return false }
        started[path] = ProcessInfo.processInfo.systemUptime
        return true
    }

    mutating func remove(_ path: String) { started[path] = nil }

    mutating func removeAll() { started.removeAll() }
}

enum BlockReason: Equatable {
    /// The peer could not serve the file (changed / vanished / paused): wait for its next index update.
    case remoteUnavailable
    /// The local entry changed under us: the scanner will index it, then we decide again.
    case localChanged
    case verifyFailed
    /// Something unexpected occupies the path (unindexed entry, case variant, file where a dir should be).
    case obstructed
    case caseConflict
    case ioError
}

/// Bytes received per quarter second over the last two seconds.
struct RateMeter {
    private var buckets = [Int64](repeating: 0, count: 8)
    private var stamps = [Int](repeating: -1, count: 8)

    mutating func add(_ bytes: Int, now: Date = Date()) {
        let slot = Int(now.timeIntervalSince1970 * 4)
        let i = slot & 7
        if stamps[i] != slot {
            stamps[i] = slot
            buckets[i] = 0
        }
        buckets[i] += Int64(bytes)
    }

    func rate(now: Date) -> Double {
        let slot = Int(now.timeIntervalSince1970 * 4)
        var total: Int64 = 0
        for i in 0..<8 where stamps[i] > slot - 8 && stamps[i] <= slot { total += buckets[i] }
        return Double(total) / 2.0
    }

    func isActive(now: Date) -> Bool {
        let slot = Int(now.timeIntervalSince1970 * 4)
        return stamps.contains { $0 > slot - 12 }
    }
}

/// A thread-safe one-way flag.
final class AtomicFlag: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)
    var isSet: Bool { lock.withLock { $0 } }
    func set() { lock.withLock { $0 = true } }
}
