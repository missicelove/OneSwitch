import Foundation

extension SyncEngine {
    // MARK: - FSEvents

    /// Runs on the engine queue with the events FSEvents reported since the previous batch (coalesced by
    /// `FSWatcher` while the engine was busy).
    func handleFSEvents(folderID: String, epoch: Int, events: [FSWatcher.Event]) {
        guard !stopped, let rt = folders[folderID], rt.epoch == epoch, rt.active else { return }
        var full = false
        var dropped = false
        var rootCheck = false
        var paths = Set<String>()
        let rootBytes = Array(rt.realRootNFC.utf8)
        for event in events {
            if event.eventsWereDropped {
                full = true
                dropped = true
            }
            if event.requiresRootCheck { rootCheck = true }
            var bytes = Array(SyncPath.normalize(event.path).utf8)
            while bytes.count > 1 && bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
            guard bytes.starts(with: rootBytes) else { continue }
            if bytes.count == rootBytes.count {
                // "Rescan everything below the root" (events dropped / coalesced), or the root itself changed.
                if event.mustScanSubDirs { full = true } else { rootCheck = true }
                continue
            }
            guard bytes[rootBytes.count] == UInt8(ascii: "/") else { continue }
            let rel = String(decoding: bytes[(rootBytes.count + 1)...], as: UTF8.self)
            if rel.isEmpty { continue }
            if SyncPath.isMarkerPath(rel) {
                if !rel.contains("/") { rootCheck = true } // the marker itself changed
                continue
            }
            // Our own temp files (one per pulled file) and Finder litter are never indexed: not worth a scan.
            let name = SyncPath.name(rel)
            if name.hasSuffix(SyncPath.tempSuffix) || SyncPath.isJunk(name) { continue }
            // MustScanSubDirs on a subdirectory (events below it were coalesced, none dropped) needs no full
            // rescan: the targeted scan of `rel` walks its whole subtree.
            paths.insert(rel)
        }
        if rootCheck {
            queue.async { [weak self] in
                guard let self, let rt = self.folders[folderID], rt.epoch == epoch, rt.active, let root = rt.realRoot else { return }
                if !Scanner.markerExists(root: root) {
                    self.setError(rt, Self.missingRootMessage)
                } else if FS.realPath(rt.config.path) != root {
                    // The root moved / was remounted elsewhere: resolve it again with a fresh stream.
                    self.deactivate(rt)
                    self.activate(rt)
                } else {
                    self.requestFullScan(rt)
                }
            }
            return
        }
        if full {
            if !rt.pendingFull {
                AppLogSync.info("folder \(folderID): FSEvents \(dropped ? "dropped events" : "asked for a rescan of the root"); full rescan")
            }
            requestFullScan(rt)
        }
        if rt.pendingPaths.count + paths.count > options.maxPendingPaths {
            // A burst: one (rate-limited) full scan is cheaper than tracking every path.
            rt.pendingPaths.removeAll()
            requestFullScan(rt)
        } else if !paths.isEmpty {
            enqueueScan(rt, paths: paths)
        }
    }

    // MARK: - Scheduling

    /// Requests a full scan. It starts as soon as the scanner is free, but at most once per
    /// `minFullScanInterval` (and never more often than twice the last full scan's duration) — bursts of
    /// FSEvents, dropped-event notices or repeated "立即扫描" are coalesced into one. The first scan after
    /// activation is never delayed.
    func requestFullScan(_ rt: FolderRuntime) {
        rt.pendingFull = true
        scheduleScan(rt)
    }

    /// Queues a targeted rescan of `paths`: it runs as soon as the scanner is free, even while a requested
    /// full scan waits for its turn.
    func enqueueScan<S: Sequence>(_ rt: FolderRuntime, paths: S) where S.Element == String {
        guard rt.active else { return }
        rt.pendingPaths.formUnion(paths)
        scheduleScan(rt)
    }

    /// Seconds until a full scan of `rt` may start (≤ 0: now).
    func fullScanDelay(_ rt: FolderRuntime) -> TimeInterval {
        guard rt.initialScanDone else { return 0 }
        let gap = max(options.minFullScanInterval, 2 * rt.lastFullScanDuration)
        return rt.lastFullScanStart + gap - ProcessInfo.processInfo.systemUptime
    }

    func scheduleScan(_ rt: FolderRuntime) {
        guard rt.active, !rt.scanRunning else { return } // `finishScan` schedules the next one
        if !rt.pendingPaths.isEmpty || (rt.pendingFull && fullScanDelay(rt) <= 0) {
            guard !rt.scanScheduled else { return }
            rt.scanScheduled = true
            queue.async { [weak self, weak rt] in
                guard let self, let rt, self.folders[rt.config.id] === rt else { return }
                rt.scanScheduled = false
                self.startScan(rt)
            }
        } else if rt.pendingFull && !rt.fullScanTimerArmed {
            rt.fullScanTimerArmed = true
            queue.asyncAfter(deadline: .now() + max(0.01, fullScanDelay(rt))) { [weak self, weak rt] in
                guard let self, let rt, self.folders[rt.config.id] === rt else { return }
                rt.fullScanTimerArmed = false
                self.scheduleScan(rt)
            }
        }
    }

    private func startScan(_ rt: FolderRuntime) {
        guard !stopped, let store, rt.active, !rt.scanRunning, let root = rt.realRoot else { return }
        let isFull = rt.pendingFull && fullScanDelay(rt) <= 0
        guard isFull || !rt.pendingPaths.isEmpty else {
            scheduleScan(rt) // only a full scan is pending, and it has to wait
            return
        }
        let id = rt.config.id
        var roots: [String]
        var snapshot: [String: QuickRecord] = [:]
        if isFull {
            roots = [""]
            store.forEach(.local, folder: id) { snapshot[$0.path] = $0.quick }
            rt.pendingFull = false
            rt.pendingPaths.removeAll()
            rt.lastFullScanStart = ProcessInfo.processInfo.systemUptime
            stats.fullScans += 1
        } else {
            roots = minimalRoots(rt, rt.pendingPaths)
            rt.pendingPaths.removeAll()
            for r in roots {
                for rec in store.records(.local, folder: id, under: r) { snapshot[rec.path] = rec.quick }
            }
        }
        rt.scanRunning = true
        rt.scanIsFull = isFull
        let job = ScanJob(folderID: id, root: root, matcher: rt.matcher, roots: roots, snapshot: snapshot,
                          settleTime: options.settleTime, settleMinSize: options.settleMinSize, isFull: isFull,
                          caseSensitive: rt.caseSensitive, parentTombstonesFirst: options.testParentTombstonesFirst)
        let epoch = rt.epoch
        let cancel = cancelFlag
        let started = Date()
        if isFull { markDirty() }
        scanQueue.async { [weak self] in
            let outcome = Scanner.run(job) { cancel.isSet }
            guard let self else { return }
            self.queue.async { self.finishScan(folderID: id, epoch: epoch, job: job, outcome: outcome, started: started) }
        }
    }

    /// Expands changed paths to the highest ancestor not yet indexed as a live directory (so a new
    /// directory is scanned as a whole) and drops paths covered by another root.
    private func minimalRoots(_ rt: FolderRuntime, _ paths: Set<String>) -> [String] {
        guard let store else { return [] }
        let id = rt.config.id
        var expanded = Set<String>()
        var knownDirs = Set<String>()
        for p in paths {
            var r = p
            var parent = SyncPath.parent(r)
            while !parent.isEmpty {
                if knownDirs.contains(parent) { break }
                if let rec = store.record(.local, folder: id, path: parent), rec.isLive, rec.kind == .directory {
                    knownDirs.insert(parent)
                    break
                }
                r = parent
                parent = SyncPath.parent(r)
            }
            expanded.insert(r)
        }
        let sorted = expanded.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var result: [String] = []
        for p in sorted {
            if let last = result.last, SyncPath.isInside(p, last) { continue }
            result.append(p)
        }
        return result
    }

    // MARK: - Results

    private func finishScan(folderID id: String, epoch: Int, job: ScanJob, outcome: ScanOutcome, started: Date) {
        guard !stopped, let rt = folders[id] else { return }
        rt.scanRunning = false
        defer { markDirty() }
        guard rt.epoch == epoch, rt.active else {
            scheduleScan(rt)
            return
        }
        stats.filesHashed += outcome.hashedFiles
        stats.bytesHashed += outcome.hashedBytes
        if outcome.markerMissing {
            setError(rt, Self.missingRootMessage)
            return
        }
        if outcome.cancelled { return }
        if job.isFull {
            rt.problems = outcome.problems
        } else if !outcome.problems.isEmpty {
            rt.problems = Array((outcome.problems + rt.problems).prefix(20))
        }
        let changed = applyScanChanges(rt, outcome.changes)
        // Cloud-only files seen by this scan replace those previously known inside the scanned roots.
        rt.datalessPaths = rt.datalessPaths.filter { p in !job.roots.contains { $0.isEmpty || SyncPath.isSameOrInside(p, $0) } }
        rt.datalessPaths.formUnion(outcome.dataless)
        if !outcome.dataless.isEmpty {
            AppLogSync.info("folder \(id): \(outcome.dataless.count) dataless (cloud-only) files not synced until downloaded, e.g. \(outcome.dataless[0])")
        }
        if !outcome.deferred.isEmpty {
            let deferred = outcome.deferred
            queue.asyncAfter(deadline: .now() + options.settleTime) { [weak self] in
                guard let self, let rt = self.folders[id], rt.epoch == epoch else { return }
                self.enqueueScan(rt, paths: deferred)
            }
        }
        let firstScan = job.isFull && !rt.initialScanDone
        if firstScan && !outcome.tempFiles.isEmpty {
            // Left over by an interrupted transfer (no transfer of this folder can be running yet).
            for rel in outcome.tempFiles where FS.entry(rt.absolute(rel))?.kind != .directory {
                unlink(rt.absolute(rel))
            }
            AppLogSync.info("folder \(id): removed \(outcome.tempFiles.count) stale temp files")
        }
        if job.isFull {
            rt.initialScanDone = true
            rt.lastFullScanAt = Date()
            rt.lastFullScanDuration = ProcessInfo.processInfo.systemUptime - rt.lastFullScanStart
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            AppLogSync.info("folder \(id): full scan \(outcome.visited) entries, \(changed.count) changes, hashed \(outcome.hashedFiles) files in \(ms) ms")
        }
        if !changed.isEmpty { scheduleIndexFlush() }
        if firstScan {
            sendIndex(rt)
            evaluate(rt, paths: nil)
        } else if job.isFull {
            evaluate(rt, paths: nil)
        } else if !changed.isEmpty {
            evaluate(rt, paths: changed)
        }
        scheduleScan(rt)
    }

    /// Records scan observations in the index (bumping our version counter). An observation is dropped
    /// (and the path rescanned) when the index changed since the scan's snapshot — e.g. a pull finished
    /// meanwhile — so a racing remote apply is never mistaken for a local edit.
    private func applyScanChanges(_ rt: FolderRuntime, _ changes: [ScanChange]) -> [String] {
        guard let store, !changes.isEmpty else { return [] }
        let id = rt.config.id
        var changed: [String] = []
        var stale: [String] = []
        store.batch {
            for change in changes {
                let current = store.record(.local, folder: id, path: change.path)
                guard current?.quick == change.base else {
                    stale.append(change.path)
                    continue
                }
                switch change.observed {
                case .present(let disk, let hash):
                    let isNew = current == nil || current!.deleted
                    var rec = FileRecord(path: change.path, kind: disk.kind,
                                         size: disk.kind == .file ? disk.size : 0, mtimeNS: disk.mtimeNS,
                                         mode: disk.mode, hash: disk.kind == .file ? hash : nil,
                                         target: disk.kind == .symlink ? disk.target : nil)
                    commitLocal(rt, &rec, previous: current, version: nil)
                    if disk.kind != .directory {
                        addRecent(rt, path: change.path, incoming: false, action: isNew ? .added : .modified, kind: disk.kind)
                    }
                case .missing:
                    guard let cur = current, cur.isLive else { continue }
                    var rec = FileRecord(path: change.path, kind: cur.kind, mtimeNS: cur.mtimeNS, mode: cur.mode, deleted: true)
                    commitLocal(rt, &rec, previous: cur, version: nil)
                    forgetConflict(rt, path: change.path)
                    addRecent(rt, path: change.path, incoming: false, action: .deleted, kind: cur.kind)
                }
                changed.append(change.path)
            }
        }
        if !stale.isEmpty { enqueueScan(rt, paths: stale) }
        return changed
    }

    // MARK: - Index writes

    /// Writes a local record with a new sequence number. `version == nil` bumps our own counter
    /// (a local change); otherwise the given vector is recorded (adopted / merged remote version).
    func commitLocal(_ rt: FolderRuntime, _ rec: inout FileRecord, previous: FileRecord?, version: VersionVector?) {
        guard let store else { return }
        rt.sequence += 1
        rec.sequence = rt.sequence
        if let version {
            rec.version = version
        } else {
            // Our counter never goes below the wall clock (milliseconds): after the index is lost (rebuilt,
            // folder re-added) new local versions still exceed every counter of ours the peer has seen, so
            // they are concurrent with — or dominate — the peer's old records, never dominated by or equal
            // to them. Otherwise the peer's stale versions would "win" and overwrite local edits made before
            // the index was lost (or an equal counter would hide a content difference forever).
            let wallClock = UInt64(max(0, clock().timeIntervalSince1970 * 1000))
            rec.version = (previous?.version ?? .empty).bumped(device: deviceID, atLeast: max(UInt64(rt.sequence), wallClock))
        }
        store.upsert(.local, folder: rt.config.id, rec)
        adjustTotals(rt, removing: previous, adding: rec)
    }

    /// Writes a local record without announcing it (keeps its sequence). Used for the intermediate
    /// state after moving losing content to a conflict copy.
    func writeLocalSilently(_ rt: FolderRuntime, _ rec: FileRecord, previous: FileRecord?) {
        store?.upsert(.local, folder: rt.config.id, rec)
        adjustTotals(rt, removing: previous, adding: rec)
    }

    private func adjustTotals(_ rt: FolderRuntime, removing old: FileRecord?, adding new: FileRecord?) {
        if let old, old.isLive {
            switch old.kind {
            case .file:
                rt.totals.files -= 1
                rt.totals.bytes -= old.size
            case .directory: rt.totals.directories -= 1
            case .symlink: rt.totals.symlinks -= 1
            }
        }
        if let new, new.isLive {
            switch new.kind {
            case .file:
                rt.totals.files += 1
                rt.totals.bytes += new.size
            case .directory: rt.totals.directories += 1
            case .symlink: rt.totals.symlinks += 1
            }
        }
    }

    func addRecent(_ rt: FolderRuntime, path: String, incoming: Bool, action: ChangeAction, kind: EntryKind) {
        recentCounter += 1
        rt.recent.insert(RecentChange(id: recentCounter, folderID: rt.config.id, path: path, incoming: incoming,
                                      action: action, kind: kind, time: clock()), at: 0)
        if rt.recent.count > 50 { rt.recent.removeLast(rt.recent.count - 50) }
    }
}
