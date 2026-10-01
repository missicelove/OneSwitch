import Foundation

extension SyncEngine {
    /// Remote changes are applied only while the folder is healthy, scanned, and the peer's initial index
    /// for it has been received.
    func canApply(_ rt: FolderRuntime) -> Bool {
        guard rt.active, rt.initialScanDone, rt.error == nil, !isPaused(rt), store != nil,
              let s = session, s.helloReceived, !s.incompatible else { return false }
        let id = rt.config.id
        guard s.shared.contains(id) && s.initialReceived.contains(id) else { return false }
        // Never write into a folder whose root or marker vanished (unmounted disk, moved folder).
        guard let root = rt.realRoot, Scanner.markerExists(root: root) else {
            setError(rt, Self.missingRootMessage)
            return false
        }
        return true
    }

    private struct Work {
        let local: FileRecord?
        let remote: FileRecord
        let action: SyncAction
    }

    /// Compares remote records with local ones (`paths == nil`: the whole folder) and applies decisions.
    func evaluate(_ rt: FolderRuntime, paths: [String]?) {
        guard let store, canApply(rt), let s = session else { return }
        let id = rt.config.id
        var work: [Work] = []
        func consider(_ remote: FileRecord, _ local: FileRecord?) {
            let path = remote.path
            if rt.matcher.isIgnored(path) { return }
            let action = ConflictResolver.decide(local: local, remote: remote, localDevice: deviceID, remoteDevice: s.deviceID)
            let key = PullKey(folder: id, path: path)
            if action == .none {
                clearProblem(rt, path)
                pullQueue.remove(key)
                discardPreparedClones(rt, path: path)
                if let job = activeJobs[key] { abortJob(job, block: nil) }
                return
            }
            var wantsTransfer = remote.isLive && remote.kind == .file
            if case .adopt = action { wantsTransfer = false }
            if !wantsTransfer {
                // A pull queued by an earlier batch is no longer wanted (the file was deleted meanwhile, or
                // turned out identical): forget it, so it neither holds up the removal of its directory nor
                // re-creates that directory later.
                pullQueue.remove(key)
                discardPreparedClones(rt, path: path)
            }
            if let job = activeJobs[key] {
                // Keep a running transfer only if it is still exactly what we want: a plain apply of the
                // same remote version. Anything else (our content now wins, or must first be preserved as
                // a conflict copy) cancels it, so a racing transfer can never overwrite a local edit.
                if case .apply(_, false) = action, job.remote.hash == remote.hash,
                   job.remote.version == remote.version, !remote.deleted { return }
                abortJob(job, block: nil)
            }
            work.append(Work(local: local, remote: remote, action: action))
        }
        if let paths {
            var seen = Set<String>()
            for p in paths where seen.insert(p).inserted {
                if let remote = store.record(.remote, folder: id, path: p) {
                    consider(remote, store.record(.local, folder: id, path: p))
                } else if rt.blocked[p] != nil {
                    clearProblem(rt, p) // the peer no longer knows this path
                }
            }
        } else {
            store.forEachRemoteWithLocal(folder: id) { remote, local in consider(remote, local) }
        }
        if !work.isEmpty { execute(rt, work) }
        processDeferredDirectories(rt)
        startPulls()
        markDirty()
    }

    private func execute(_ rt: FolderRuntime, _ work: [Work]) {
        guard let store else { return }
        var metadataOps: [Work] = []
        var deletions: [Work] = []
        var directories: [Work] = []
        var symlinks: [Work] = []
        var files: [Work] = []
        for w in work {
            switch w.action {
            case .none: break
            case .adopt: metadataOps.append(w)
            case .apply:
                if w.remote.deleted {
                    deletions.append(w)
                } else {
                    switch w.remote.kind {
                    case .directory: directories.append(w)
                    case .symlink: symlinks.append(w)
                    case .file: files.append(w)
                    }
                }
            }
        }
        // Every step below is a complete unit (file-system change + its index record). The loops stop early
        // when the engine is being stopped, so `stop()` never waits for a huge batch; what is left is simply
        // decided again on the next start.
        let cancel = cancelFlag
        store.batch {
            for w in metadataOps {
                if cancel.isSet { return }
                applyMetadata(rt, w.local, w.remote, w.action)
            }
            // Losing local content is preserved first, so later updates of the same path can never
            // overwrite it without a conflict copy.
            var conflicted = Set<String>()
            for w in directories + symlinks + files {
                if cancel.isSet { return }
                guard case .apply(_, true) = w.action, let local = w.local else { continue }
                if makeConflictCopy(rt, local) { conflicted.insert(w.remote.path) }
            }
            // Content that moved (renames) is cloned from its old location before that location is
            // deleted below, so the pull later only verifies it instead of transferring it again.
            if !deletions.isEmpty {
                for w in files {
                    if case .apply(_, true) = w.action, !conflicted.contains(w.remote.path) { continue }
                    prepareClone(rt, remote: w.remote)
                }
                prepareClonesForQueuedPulls(rt, deleting: deletions.compactMap(\.local))
            }
            // Files and symlinks first; directories are removed last (below), once everything else of this
            // batch — deletions of their children, transfers into them — has been handled or queued.
            func deepestFirst(_ a: Work, _ b: Work) -> Bool { SyncPath.depth(a.remote.path) > SyncPath.depth(b.remote.path) }
            let isDirectory = { (w: Work) in w.remote.kind == .directory || w.local?.kind == .directory }
            // A file or symlink replacing one of our directories waits for that directory like a deletion does.
            let isReplacement = { (w: Work) -> Bool in
                guard case .apply(_, false) = w.action, w.remote.kind != .directory,
                      let local = w.local, local.isLive, local.kind == .directory else { return false }
                return true
            }
            let entryContext = RemovalContext { [unowned self] in self.transferDirectories(rt) } // unused unless kinds changed
            for w in deletions.filter({ !isDirectory($0) }).sorted(by: deepestFirst) {
                if cancel.isSet { return }
                applyDeletion(rt, remote: w.remote, context: entryContext)
            }
            for w in directories.sorted(by: { SyncPath.depth($0.remote.path) < SyncPath.depth($1.remote.path) }) {
                if cancel.isSet { return }
                if case .apply(_, true) = w.action, !conflicted.contains(w.remote.path) { continue }
                applyDirectory(rt, remote: w.remote)
            }
            for w in symlinks where !isReplacement(w) {
                if cancel.isSet { return }
                if case .apply(_, true) = w.action, !conflicted.contains(w.remote.path) { continue }
                applySymlink(rt, remote: w.remote)
            }
            for w in files.sorted(by: { $0.remote.path.utf8.lexicographicallyPrecedes($1.remote.path.utf8) }) where !isReplacement(w) {
                if case .apply(_, true) = w.action, !conflicted.contains(w.remote.path) { continue }
                pullQueue.append(PullKey(folder: rt.config.id, path: w.remote.path), size: w.remote.size, hash: w.remote.hash)
            }
            // Directory deletions and replacements deepest first, so subdirectories are handled before their parents.
            let context = RemovalContext { [unowned self] in self.transferDirectories(rt) }
            for w in (deletions.filter(isDirectory) + (symlinks + files).filter(isReplacement)).sorted(by: deepestFirst) {
                if cancel.isSet { return }
                if w.remote.deleted {
                    applyDeletion(rt, remote: w.remote, context: context)
                } else {
                    applyReplacement(rt, remote: w.remote, context: context)
                }
            }
        }
        scheduleIndexFlush()
    }

    /// Pulls queued by earlier index batches that want content about to be deleted here (the old paths of a
    /// rename spanning several batches: the new paths arrive first) clone it now, while it still exists —
    /// otherwise they would transfer it over the network again.
    private func prepareClonesForQueuedPulls(_ rt: FolderRuntime, deleting locals: [FileRecord]) {
        guard let store, !pullQueue.isEmpty else { return }
        let id = rt.config.id
        for local in locals where local.isLive && local.kind == .file && local.size > 0 {
            guard let hash = local.hash else { continue }
            for key in pullQueue.keys(withHash: hash)
            where key.folder == id && rt.preparedClones[key.path] == nil && activeJobs[key] == nil {
                guard let remote = store.record(.remote, folder: id, path: key.path), remote.isLive, remote.kind == .file,
                      remote.hash == hash, remote.size == local.size else { continue }
                prepareClone(rt, remote: remote)
            }
        }
    }

    // MARK: - Metadata / vector-only updates

    private func applyMetadata(_ rt: FolderRuntime, _ local: FileRecord?, _ remote: FileRecord, _ action: SyncAction) {
        guard let local else { return }
        switch action {
        case .adopt(let version, let metadata):
            if local.deleted {
                var rec = local
                commitLocal(rt, &rec, previous: local, version: version)
                return
            }
            let abs = rt.absolute(local.path)
            guard pathIsSafe(rt, local.path), let disk = FS.entry(abs), local.matches(disk) else {
                block(rt, local.path, .localChanged)
                enqueueScan(rt, paths: [local.path])
                return
            }
            var observed = disk
            if let m = metadata {
                if local.kind == .file, disk.mode != m.mode { chmod(abs, mode_t(m.mode)) }
                if local.kind == .directory, disk.mode != m.mode { chmod(abs, Self.directoryMode(m.mode)) }
                if local.kind == .file, disk.mtimeNS != m.mtimeNS { FS.setModificationTime(abs, ns: m.mtimeNS) }
                observed = FS.entry(abs) ?? disk
            }
            var rec = local
            rec.size = local.kind == .file ? observed.size : 0
            rec.mtimeNS = observed.mtimeNS
            rec.mode = observed.mode
            commitLocal(rt, &rec, previous: local, version: version)
        default:
            break
        }
    }

    // MARK: - Conflicts

    /// Renames our losing content to "<name>.sync-conflict-<date>-<device>.<ext>" (a new local entry that
    /// syncs normally) and marks the original path as vacated without announcing it.
    @discardableResult
    func makeConflictCopy(_ rt: FolderRuntime, _ local: FileRecord) -> Bool {
        guard let store, local.isLive else { return true }
        let abs = rt.absolute(local.path)
        guard pathIsSafe(rt, local.path) else {
            block(rt, local.path, .obstructed)
            return false
        }
        switch FS.lstatEntry(abs) {
        case .missing:
            // Already gone locally: nothing to preserve; the scanner records the deletion.
            enqueueScan(rt, paths: [local.path])
            return false
        case .entry(let disk):
            guard local.matches(disk) else {
                block(rt, local.path, .localChanged)
                enqueueScan(rt, paths: [local.path])
                return false
            }
        default:
            block(rt, local.path, .ioError)
            return false
        }
        let now = clock()
        var conflictPath = ""
        for attempt in 0..<100 {
            let candidate = SyncPath.conflictPath(for: local.path, date: now, deviceName: deviceName,
                                                  isDirectory: local.kind == .directory, attempt: attempt)
            if !FS.exists(rt.absolute(candidate)) && (store.record(.local, folder: rt.config.id, path: candidate)?.isLive != true) {
                conflictPath = candidate
                break
            }
        }
        guard !conflictPath.isEmpty, FS.renameExclusive(abs, rt.absolute(conflictPath)) else {
            AppLogSync.error("cannot create conflict copy of \(local.path): \(FS.errorString(errno))")
            rt.issues[local.path] = "无法为「\(local.path)」创建冲突副本：\(FS.localizedError(errno))"
            block(rt, local.path, .ioError)
            return false
        }
        // Record the conflict copy directly (same content, new entry) so its FSEvents echo is a no-op.
        let previous = store.record(.local, folder: rt.config.id, path: conflictPath)
        let disk = FS.entry(rt.absolute(conflictPath))
        var copy = local
        copy.path = conflictPath
        copy.deleted = false
        if let disk {
            copy.mtimeNS = disk.mtimeNS
            copy.mode = disk.mode
            copy.size = disk.kind == .file ? disk.size : 0
        }
        // A new local entry: its history starts with our own counter (bumped over any old tombstone).
        commitLocal(rt, &copy, previous: previous, version: nil)
        if local.kind == .directory {
            // Children moved along with the directory: rescan both subtrees.
            enqueueScan(rt, paths: [local.path, conflictPath])
        }
        // The original path is now empty on disk; keep our old vector (unannounced) so the pending
        // remote apply records merge(ours, theirs).
        var vacated = local
        vacated.deleted = true
        vacated.hash = nil
        vacated.target = nil
        vacated.size = 0
        writeLocalSilently(rt, vacated, previous: local)

        recordConflict(rt, ConflictInfo(folderID: rt.config.id, conflictPath: conflictPath, originalPath: local.path,
                                        time: now, absolutePath: rt.absolute(conflictPath), createdLocally: true))
        stats.conflictsCreated += 1
        addRecent(rt, path: conflictPath, incoming: false, action: .added, kind: local.kind)
        AppLogSync.warning("conflict on \(local.path): our version kept as \(conflictPath)")
        return true
    }

    func recordConflict(_ rt: FolderRuntime, _ info: ConflictInfo) {
        rt.conflicts.removeAll { $0.conflictPath == info.conflictPath }
        rt.conflicts.insert(info, at: 0)
        if rt.conflicts.count > 100 { rt.conflicts.removeLast(rt.conflicts.count - 100) }
        persistConflicts(rt)
    }

    /// Drops a conflict from the UI once its copy has been deleted (on either Mac).
    func forgetConflict(_ rt: FolderRuntime, path: String) {
        guard rt.conflicts.contains(where: { $0.conflictPath == path }) else { return }
        rt.conflicts.removeAll { $0.conflictPath == path }
        persistConflicts(rt)
    }

    func persistConflicts(_ rt: FolderRuntime) {
        guard let data = try? JSONEncoder().encode(rt.conflicts), let json = String(data: data, encoding: .utf8) else { return }
        store?.setMeta("folder.\(rt.config.id).conflicts", json)
    }

    // MARK: - Deletions

    enum DirectoryRemoval: Equatable {
        case removed
        /// Children still have remote changes to be processed (deletions arriving in a later index batch,
        /// blocked for now, transfers queued or running): decide again once they are handled.
        case deferred
        /// Holds entries that stay — unknown (not yet indexed), ignored, or changed locally after the peer
        /// deleted them: the directory stays too.
        case kept
        case failed
    }

    /// State shared by the directory removals of one pass, computed only if a removal needs it.
    final class RemovalContext {
        private let makeTransferDirectories: () -> Set<String>
        private lazy var transferDirectories: Set<String> = makeTransferDirectories()

        init(_ makeTransferDirectories: @escaping () -> Set<String>) {
            self.makeTransferDirectories = makeTransferDirectories
        }

        /// True when a transfer (queued, running, or a prepared clone) targets a path below `path`.
        func hasTransfers(inside path: String) -> Bool { transferDirectories.contains(path) }
    }

    /// Directories (relative, never "") holding the destination of a queued or running transfer or of a
    /// prepared clone of this folder.
    func transferDirectories(_ rt: FolderRuntime) -> Set<String> {
        let id = rt.config.id
        var dirs = Set<String>()
        func add(_ path: String) {
            var p = SyncPath.parent(path)
            while !p.isEmpty, dirs.insert(p).inserted { p = SyncPath.parent(p) }
        }
        for key in pullQueue.items.keys where key.folder == id { add(key.path) }
        for key in activeJobs.keys where key.folder == id { add(key.path) }
        for path in rt.preparedClones.keys { add(path) }
        return dirs
    }

    /// True when no newer record of a child of the directory at `path` can still be on its way: the peer's last
    /// index batch did not announce more, and the stream has been quiet for `remoteIndexSettleTime` (it may still
    /// be mid-way for an older peer that never announces "more"; a current peer may still record a child after
    /// its directory when the child changed during the scan that saw the deletion, and rescans it at once).
    /// A peer that announces "more" (hello) has otherwise sent everything it holds, so for it the directory's own
    /// wait counts too: requiring quiet alone kept a directory deferred for as long as anything else in the folder
    /// kept changing (a log being written) whenever the peer still held a stale record of an ignored child.
    func remoteIndexSettled(_ rt: FolderRuntime, directory path: String) -> Bool {
        guard let s = session, !s.indexIncomplete.contains(rt.config.id) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if now - rt.lastRemoteIndexAt >= options.remoteIndexSettleTime { return true }
        if s.peerAnnouncesMore, let since = rt.deferredDirDeletes.since(path) {
            return now - since >= options.remoteIndexSettleTime
        }
        return false
    }

    /// Applies a remote deletion that dominates our record.
    private func applyDeletion(_ rt: FolderRuntime, remote: FileRecord, context: RemovalContext) {
        guard let store else { return }
        let id = rt.config.id
        let path = remote.path
        let local = store.record(.local, folder: id, path: path)
        guard case .apply(let version, _) = decideNow(rt, local: local, remote: remote) else { return }
        func commitTombstone(kind: EntryKind) {
            var rec = FileRecord(path: path, kind: kind, mtimeNS: local?.mtimeNS ?? remote.mtimeNS,
                                 mode: local?.mode ?? remote.mode, deleted: true)
            commitLocal(rt, &rec, previous: local, version: version)
            clearProblem(rt, path) // e.g. a pull of it that was obstructed
        }
        guard pathIsSafe(rt, path) else {
            // An ancestor is a symlink / file: the path cannot exist inside our folder.
            if local == nil || local!.deleted { commitTombstone(kind: remote.kind) } else { block(rt, path, .obstructed) }
            return
        }
        let abs = rt.absolute(path)
        guard let local, local.isLive else {
            if FS.exists(abs) && Scanner.namesMatchOnDisk(root: rt.realRoot ?? "", rel: path) {
                // Something unindexed exists here: let the scanner index it (it then wins as a modification).
                enqueueScan(rt, paths: [path])
                return
            }
            commitTombstone(kind: remote.kind)
            return
        }
        switch FS.lstatEntry(abs) {
        case .missing:
            rt.deferredDirDeletes.remove(path)
            commitTombstone(kind: local.kind)
        case .entry(let disk):
            guard local.matches(disk) else {
                block(rt, path, .localChanged)
                enqueueScan(rt, paths: [path])
                return
            }
            if local.kind == .directory {
                switch removeDirectory(rt, path, remote: remote, context: context) {
                case .removed:
                    rt.deferredDirDeletes.remove(path)
                    commitTombstone(kind: .directory)
                    rt.lastSyncAt = clock()
                    addRecent(rt, path: path, incoming: true, action: .deleted, kind: .directory)
                case .deferred:
                    // The local record stays live meanwhile: the scanner sees an unchanged directory, never a
                    // "new" one to announce.
                    if rt.deferredDirDeletes.insert(path) {
                        AppLogSync.debug("deletion of directory \(path) waits for its children")
                    }
                case .kept:
                    rt.deferredDirDeletes.remove(path)
                    keepDirectory(rt, local: local, remote: remote, disk: disk)
                case .failed:
                    rt.deferredDirDeletes.remove(path)
                    block(rt, path, .ioError)
                }
                return
            }
            guard archiveOrRemove(rt, path: path, kind: local.kind) else {
                block(rt, path, .ioError)
                return
            }
            commitTombstone(kind: local.kind)
            rt.lastSyncAt = clock()
            forgetConflict(rt, path: path)
            addRecent(rt, path: path, incoming: true, action: .deleted, kind: local.kind)
        case .unsupported, .error:
            block(rt, path, .ioError)
        }
    }

    /// A remote file or symlink replaces one of our directories. Like a deletion, the directory is removed only
    /// once its children are handled (their deletions may still be on the way in later index batches, transfers
    /// into it may still run) — meanwhile it waits with the deferred directory deletions instead of being retried
    /// as "obstructed" much later. Entries that stay in it (unknown, ignored, changed here) cannot stay at this
    /// path: they are preserved in a conflict copy of the directory. Then the file is pulled / the link created.
    private func applyReplacement(_ rt: FolderRuntime, remote: FileRecord, context: RemovalContext) {
        guard let store else { return }
        let id = rt.config.id
        let path = remote.path
        rt.deferredDirDeletes.remove(path)
        guard let local = store.record(.local, folder: id, path: path), local.isLive, local.kind == .directory,
              case .apply(_, false) = decideNow(rt, local: local, remote: remote) else { return }
        guard pathIsSafe(rt, path) else {
            block(rt, path, .obstructed)
            return
        }
        var vacate = true
        switch FS.lstatEntry(rt.absolute(path)) {
        case .missing:
            break // removed here, not scanned yet: nothing left to keep
        case .entry(let disk) where disk.kind == .directory:
            switch removeDirectory(rt, path, remote: remote, context: context) {
            case .removed:
                addRecent(rt, path: path, incoming: true, action: .deleted, kind: .directory)
            case .deferred:
                if rt.deferredDirDeletes.insert(path) {
                    AppLogSync.debug("replacement of directory \(path) waits for its children")
                }
                return
            case .kept:
                guard makeConflictCopy(rt, local) else { return } // blocks the path on failure
                vacate = false // done by the conflict copy
            case .failed:
                block(rt, path, .ioError)
                return
            }
        case .entry:
            // Our record says directory, something else is there: a local change the scanner has not seen yet.
            block(rt, path, .localChanged)
            enqueueScan(rt, paths: [path])
            return
        case .unsupported, .error:
            block(rt, path, .ioError)
            return
        }
        if vacate {
            // The path is empty now; keep our old vector (unannounced) so the apply below records the peer's.
            var vacated = local
            vacated.deleted = true
            writeLocalSilently(rt, vacated, previous: local)
        }
        if remote.kind == .symlink {
            applySymlink(rt, remote: remote)
        } else {
            pullQueue.append(PullKey(folder: id, path: path), size: remote.size, hash: remote.hash)
        }
    }

    /// The peer deleted a directory that still holds entries here. Instead of adopting the deletion and
    /// letting the scanner rediscover the directory as "new" (it was then re-announced after every such
    /// round), record one local version superseding the peer's tombstone: the directory is re-announced
    /// once and the peer re-creates it, receiving what it holds as those entries get indexed.
    private func keepDirectory(_ rt: FolderRuntime, local: FileRecord, remote: FileRecord, disk: DiskState) {
        var base = local
        base.version = local.version.merged(with: remote.version)
        var rec = local
        rec.mtimeNS = disk.mtimeNS
        rec.mode = disk.mode
        commitLocal(rt, &rec, previous: base, version: nil)
        enqueueScan(rt, paths: [local.path]) // index what it holds
    }

    /// Re-decides a path against fresh records (records may have changed earlier in the same batch).
    func decideNow(_ rt: FolderRuntime, local: FileRecord?, remote: FileRecord) -> SyncAction {
        guard let s = session else { return .none }
        return ConflictResolver.decide(local: local, remote: remote, localDevice: deviceID, remoteDevice: s.deviceID)
    }

    /// Removes a directory the peer no longer has once every child has been handled. `remote` is the peer's
    /// record for `path` (its tombstone, or the entry replacing the directory).
    ///
    /// A child we track must not be mistaken for an unknown leftover while the peer's change for it is still
    /// pending: the remote index arrives in batches, so a directory's tombstone can be applied before the
    /// tombstones of its children (a later batch) — keeping the directory then made the scanner re-announce
    /// it as new, resurrecting it on both Macs. Such a directory is deferred instead. Finder litter and stray
    /// temp files are removed; only entries that really stay keep the directory.
    func removeDirectory(_ rt: FolderRuntime, _ path: String, remote: FileRecord, context: RemovalContext) -> DirectoryRemoval {
        guard let store else { return .failed }
        let abs = rt.absolute(path)
        let names: [String]
        switch FS.listDirectory(abs) {
        case .success(let list): names = list
        case .failure(let code): return code == ENOENT ? .removed : .failed
        }
        let id = rt.config.id
        var settled: Bool?
        var litter: [String] = []
        var leftovers: [String] = []
        for raw in names {
            let name = SyncPath.normalize(raw)
            let child = SyncPath.join(path, name)
            // Our temp files of running transfers / prepared clones are covered by `hasTransfers` below; any
            // other is left over by a transfer that just ended (its writer deletes it asynchronously).
            if SyncPath.isJunk(name) || SyncPath.isTempName(name) {
                litter.append(raw)
                continue
            }
            if let local = store.record(.local, folder: id, path: child), local.isLive, !rt.matcher.isIgnored(child),
               let childRemote = store.record(.remote, folder: id, path: child) {
                if decideNow(rt, local: local, remote: childRemote) != .none {
                    return .deferred // its own remote change (deletion, update) is still to be applied
                }
                if childRemote.isLive && childRemote.sequence < remote.sequence {
                    // The peer's record of this child predates its deletion of the directory: the peer deleted
                    // the child too (the tombstone is still on the way) — or still holds a stale record of it
                    // (a child it has since started ignoring), which is known only once its index is complete.
                    if settled == nil { settled = remoteIndexSettled(rt, directory: path) }
                    if settled == false { return .deferred }
                }
            }
            // Stays: unknown to the index (not scanned yet), ignored, unknown to the peer, or changed here
            // after the peer deleted it.
            leftovers.append(child)
        }
        if context.hasTransfers(inside: path) { return .deferred }
        if !leftovers.isEmpty {
            AppLogSync.info("keeping directory \(path): contains \(leftovers.count) entries that stay (unknown, ignored or changed here, e.g. \(leftovers[0]))")
            return .kept
        }
        for raw in litter { _ = unlink(abs + "/" + raw) }
        if rmdir(abs) == 0 || errno == ENOENT { return .removed }
        if errno == ENOTEMPTY || errno == EEXIST {
            // Something appeared meanwhile: index it, then decide again.
            enqueueScan(rt, paths: [path])
            return .deferred
        }
        AppLogSync.warning("cannot remove directory \(path): \(FS.errorString(errno))")
        rt.issues[path] = "无法删除文件夹「\(path)」：\(FS.localizedError(errno))"
        return .failed
    }

    /// Retries directory deletions (and replacements of directories by files / symlinks) that waited for their
    /// children.
    func processDeferredDirectories(_ rt: FolderRuntime) {
        guard let store, !rt.deferredDirDeletes.isEmpty, canApply(rt) else { return }
        let id = rt.config.id
        let paths = rt.deferredDirDeletes.paths.sorted { SyncPath.depth($0) > SyncPath.depth($1) }
        let context = RemovalContext { [unowned self] in self.transferDirectories(rt) }
        let sequenceBefore = rt.sequence
        let pendingBefore = rt.deferredDirDeletes.count
        let pullsBefore = pullQueue.count
        store.batch {
            for path in paths {
                if cancelFlag.isSet { return }
                // Still wanted: not ignored meanwhile, and the peer's record still deletes / replaces the directory.
                guard !rt.matcher.isIgnored(path), let remote = store.record(.remote, folder: id, path: path),
                      case .apply(_, let conflict) = decideNow(rt, local: store.record(.local, folder: id, path: path), remote: remote),
                      remote.deleted || (remote.kind != .directory && !conflict) else {
                    rt.deferredDirDeletes.remove(path)
                    continue
                }
                if remote.deleted {
                    applyDeletion(rt, remote: remote, context: context)
                } else {
                    applyReplacement(rt, remote: remote, context: context)
                }
            }
        }
        if rt.sequence != sequenceBefore { scheduleIndexFlush() }
        if rt.sequence != sequenceBefore || rt.deferredDirDeletes.count != pendingBefore { markDirty() }
        if pullQueue.count != pullsBefore { startPulls() }
    }

    // MARK: - Directories and symlinks

    /// Mode for a directory created / updated from a remote record. The owner always keeps rwx: a
    /// read-only directory (e.g. 0555) would make every later pull or deletion inside it fail forever.
    static func directoryMode(_ remoteMode: UInt32) -> mode_t {
        mode_t((remoteMode == 0 ? 0o755 : remoteMode) | 0o700)
    }

    private func applyDirectory(_ rt: FolderRuntime, remote: FileRecord) {
        guard let store else { return }
        let id = rt.config.id
        let path = remote.path
        let local = store.record(.local, folder: id, path: path)
        guard case .apply(let version, _) = decideNow(rt, local: local, remote: remote) else { return }
        let localAbsent = local == nil || local!.deleted
        if localAbsent && hasCaseConflict(rt, path) { return }
        guard pathIsSafe(rt, path), ensureParentDirectories(rt, path) else {
            block(rt, path, .obstructed)
            return
        }
        let abs = rt.absolute(path)
        switch FS.lstatEntry(abs) {
        case .missing:
            guard localAbsent else {
                // Indexed but gone: an unscanned local deletion. Let the scanner record it first.
                block(rt, path, .localChanged)
                enqueueScan(rt, paths: [path])
                return
            }
            guard mkdir(abs, 0o700) == 0 || errno == EEXIST else {
                block(rt, path, .ioError)
                return
            }
        case .entry(let disk):
            if disk.kind == .directory {
                if localAbsent && !rt.caseSensitive,
                   let actual = FS.onDiskName(abs), !SyncPath.normalize(actual).utf8.elementsEqual(SyncPath.name(path).utf8) {
                    rt.issues[path] = "「\(path)」与本机已有的「\(SyncPath.join(SyncPath.parent(path), actual))」仅大小写不同，暂时无法同步"
                    block(rt, path, .caseConflict)
                    return
                }
            } else {
                guard let local, local.isLive, local.matches(disk) else {
                    block(rt, path, .obstructed)
                    enqueueScan(rt, paths: [path])
                    return
                }
                guard archiveOrRemove(rt, path: path, kind: local.kind), mkdir(abs, 0o700) == 0 else {
                    block(rt, path, .ioError)
                    return
                }
            }
        case .unsupported, .error:
            block(rt, path, .ioError)
            return
        }
        chmod(abs, Self.directoryMode(remote.mode))
        guard let disk = FS.entry(abs), disk.kind == .directory else {
            block(rt, path, .ioError)
            return
        }
        var rec = FileRecord(path: path, kind: .directory, mtimeNS: disk.mtimeNS, mode: disk.mode)
        commitLocal(rt, &rec, previous: local, version: version)
        clearProblem(rt, path)
        if local?.isLive != true || local?.kind != .directory { retryBlocked(rt, inside: path) }
    }

    /// A directory was (re-)created: paths inside it that were blocked because it was missing or not a directory
    /// (a local deletion raced a pull into it, a file stood at its path) are decided again now instead of after
    /// their retry backoff.
    private func retryBlocked(_ rt: FolderRuntime, inside path: String) {
        guard !rt.blocked.isEmpty else { return }
        let inside = rt.blocked.keys.filter { SyncPath.isInside($0, path) }
        if !inside.isEmpty { decideSoon(rt, paths: inside) }
    }

    /// Evaluates `paths` again right after the current engine-queue work (never re-entrantly).
    func decideSoon(_ rt: FolderRuntime, paths: [String]) {
        let id = rt.config.id
        queue.async { [weak self] in
            guard let self, let current = self.folders[id], current === rt else { return }
            self.evaluate(rt, paths: paths)
        }
    }

    private func applySymlink(_ rt: FolderRuntime, remote: FileRecord) {
        guard let store, let target = remote.target else { return }
        let id = rt.config.id
        let path = remote.path
        let local = store.record(.local, folder: id, path: path)
        guard case .apply(let version, _) = decideNow(rt, local: local, remote: remote) else { return }
        let localAbsent = local == nil || local!.deleted
        if localAbsent && hasCaseConflict(rt, path) { return }
        let parent = rt.absolute(SyncPath.parent(path))
        guard pathIsSafe(rt, path), ensureParentDirectories(rt, path) else {
            block(rt, path, .obstructed)
            return
        }
        let abs = rt.absolute(path)
        let temp = parent + "/" + SyncPath.tempName(for: SyncPath.name(path))
        guard symlink(target, temp) == 0 else {
            block(rt, path, .ioError)
            return
        }
        FS.setModificationTime(temp, ns: remote.mtimeNS, followSymlinks: false)
        guard let destination = prepareDestination(rt, path: path, local: local, remote: remote) else {
            unlink(temp)
            return
        }
        // A directory held here may just have been moved aside as a conflict copy.
        let current = store.record(.local, folder: id, path: path)
        guard moveIntoPlace(rt, temp: temp, path: path, destination) else { return }
        guard let disk = FS.entry(abs) else { return }
        var rec = FileRecord(path: path, kind: .symlink, mtimeNS: disk.mtimeNS, mode: disk.mode, target: disk.target)
        commitLocal(rt, &rec, previous: current, version: version)
        rt.lastSyncAt = clock()
        addRecent(rt, path: path, incoming: true, action: localAbsent ? .added : .modified, kind: .symlink)
        clearProblem(rt, path)
    }

    /// How the new entry is moved onto its path after `prepareDestination`.
    enum Destination {
        /// Nothing is there (any more): the move must not replace anything that appears meanwhile.
        case vacant
        /// The indexed entry is still there and is replaced atomically by the move.
        case replace
    }

    /// Final check right before an atomic rename onto `path`: the local entry must still be exactly what
    /// the index says (absent, or the indexed entry). Moves a replaced file to versioning and removes a
    /// replaced (empty) directory. Returns nil — and schedules a rescan — when a local edit raced us.
    func prepareDestination(_ rt: FolderRuntime, path: String, local: FileRecord?, remote: FileRecord) -> Destination? {
        let abs = rt.absolute(path)
        switch FS.lstatEntry(abs) {
        case .missing:
            if let local, local.isLive {
                block(rt, path, .localChanged)
                enqueueScan(rt, paths: [path])
                return nil
            }
            return .vacant
        case .entry(let disk):
            guard let local, local.isLive, local.matches(disk) else {
                block(rt, path, local?.isLive == true ? .localChanged : .obstructed)
                enqueueScan(rt, paths: [path])
                return nil
            }
            switch disk.kind {
            case .directory:
                // Normally vacated beforehand (`applyReplacement`); a directory can still turn up here when the
                // decision was made against an older local record.
                let context = RemovalContext { [unowned self] in self.transferDirectories(rt) }
                switch removeDirectory(rt, path, remote: remote, context: context) {
                case .removed:
                    return .vacant
                case .kept:
                    // Entries that stay are preserved in a conflict copy of the directory (callers re-read `local`).
                    return makeConflictCopy(rt, local) ? .vacant : nil
                case .deferred:
                    rt.deferredDirDeletes.insert(path) // retried once its children are handled
                    return nil
                case .failed:
                    block(rt, path, .ioError)
                    return nil
                }
            case .symlink:
                return .replace // rename() replaces the link itself
            case .file:
                if rt.config.versioning == .none { return .replace } // rename() replaces atomically
                guard archiveOrRemove(rt, path: path, kind: .file) else {
                    block(rt, path, .ioError)
                    return nil
                }
                return .vacant
            }
        case .unsupported, .error:
            block(rt, path, .ioError)
            return nil
        }
    }

    /// Moves a prepared temp entry onto `path`. With `.vacant` the move fails (EEXIST) instead of replacing
    /// an entry the user created there after `prepareDestination` checked; that entry is then scanned
    /// and decided on normally. Returns false (temp removed, path blocked) on failure.
    func moveIntoPlace(_ rt: FolderRuntime, temp: String, path: String, _ destination: Destination) -> Bool {
        let abs = rt.absolute(path)
        let ok = destination == .replace ? rename(temp, abs) == 0 : FS.renameExclusive(temp, abs)
        if ok { return true }
        let code = errno
        unlink(temp)
        if code == EEXIST {
            AppLogSync.info("\(path) was created locally while applying a remote change; deciding again")
            block(rt, path, .localChanged)
            enqueueScan(rt, paths: [path])
        } else if code == ENOENT {
            // The temp entry vanished with its directory: a local deletion / move raced us. Not an I/O problem —
            // the path is decided again once the scanner recorded that change (or its directory is re-created).
            AppLogSync.info("the directory of \(path) was removed locally while applying a remote change; deciding again")
            block(rt, path, .localChanged)
            // Its directory exists again (re-created meanwhile, e.g. kept by the peer): only this transfer was lost.
            if FS.isDirectory(rt.absolute(SyncPath.parent(path))), (rt.blockedRetry[path]?.attempts ?? 0) <= 3 {
                decideSoon(rt, paths: [path])
            }
        } else {
            AppLogSync.error("rename into \(path) failed: \(FS.errorString(code))")
            rt.issues[path] = "无法写入「\(path)」：\(FS.localizedError(code))"
            block(rt, path, .ioError)
        }
        return false
    }

    // MARK: - Local clones

    /// Clones identical local content (APFS clonefile: instant, no extra space) into a temp file next to
    /// `remote.path`. The pull job verifies its hash before using it.
    func prepareClone(_ rt: FolderRuntime, remote: FileRecord) {
        guard let hash = remote.hash, remote.size > 0, rt.preparedClones[remote.path] == nil,
              pathIsSafe(rt, remote.path), let source = cloneSource(rt, hash: hash, size: remote.size) else { return }
        guard ensureParentDirectories(rt, remote.path) else { return }
        let parent = rt.absolute(SyncPath.parent(remote.path))
        let temp = parent + "/" + SyncPath.tempName(for: SyncPath.name(remote.path))
        if clonefile(source, temp, UInt32(CLONE_NOFOLLOW)) == 0 {
            rt.preparedClones[remote.path] = (temp, hash)
        }
    }

    func cloneSource(_ rt: FolderRuntime, hash: Data, size: Int64) -> String? {
        guard let store else { return nil }
        for candidate in store.localFiles(folder: rt.config.id, hash: hash) where candidate.size == size {
            let abs = rt.absolute(candidate.path)
            // Never clone a dataless placeholder: verifying the clone would download it.
            if pathIsSafe(rt, candidate.path), let disk = FS.entry(abs), !disk.dataless, candidate.matches(disk) { return abs }
        }
        return nil
    }

    /// Deletes prepared clones (all of the folder's, or one path's).
    func discardPreparedClones(_ rt: FolderRuntime, path: String? = nil) {
        if let path {
            if let prepared = rt.preparedClones.removeValue(forKey: path) { unlink(prepared.temp) }
            return
        }
        for (_, prepared) in rt.preparedClones { unlink(prepared.temp) }
        rt.preparedClones.removeAll()
    }

    // MARK: - Safety helpers

    /// Creates missing parent directories of `path` strictly inside the folder root (which, with its
    /// marker, must exist): an unmounted disk or moved folder is never re-created by a pull.
    func ensureParentDirectories(_ rt: FolderRuntime, _ path: String) -> Bool {
        guard let root = rt.realRoot, Scanner.markerExists(root: root) else { return false }
        for ancestor in SyncPath.ancestors(of: path) {
            let abs = root + "/" + ancestor
            switch FS.lstatEntry(abs) {
            case .entry(let d) where d.kind == .directory:
                continue
            case .missing:
                if mkdir(abs, 0o755) != 0 && errno != EEXIST { return false }
            default:
                return false
            }
        }
        return true
    }

    /// Every ancestor inside the folder must be a real directory (or not exist yet) — never a symlink,
    /// so a crafted remote index cannot make us write outside the folder.
    func pathIsSafe(_ rt: FolderRuntime, _ path: String) -> Bool {
        guard SyncPath.isValidRelative(path) else { return false }
        for ancestor in SyncPath.ancestors(of: path) {
            switch FS.lstatEntry(rt.absolute(ancestor)) {
            case .missing: return true
            case .entry(let d) where d.kind == .directory: continue
            default: return false
            }
        }
        return true
    }

    /// On case-insensitive volumes, remote paths that differ only by case cannot coexist: the first in
    /// binary order is synced, the others are reported instead of fighting over the same file.
    func hasCaseConflict(_ rt: FolderRuntime, _ path: String) -> Bool {
        guard !rt.caseSensitive, let store else { return false }
        let variants = store.caseVariants(.remote, folder: rt.config.id, path: path)
        guard !variants.isEmpty else { return false }
        let winner = (variants + [path]).min { $0.utf8.lexicographicallyPrecedes($1.utf8) }!
        guard winner != path else { return false }
        rt.issues[path] = "「\(path)」与「\(winner)」仅大小写不同，本机磁盘不区分大小写，已跳过"
        block(rt, path, .caseConflict)
        return true
    }

    /// Marks a path as waiting; it is re-evaluated on the next relevant change and retried with
    /// exponential backoff (30 s, 1 min, 2 min … 1 h) so a persistent problem never loops.
    func block(_ rt: FolderRuntime, _ path: String, _ reason: BlockReason) {
        rt.blocked[path] = reason
        let attempts = (rt.blockedRetry[path]?.attempts ?? 0) + 1
        let delay = min(options.blockedRetryInterval * pow(2, Double(min(attempts - 1, 12))), 3600)
        rt.blockedRetry[path] = (attempts, Date().addingTimeInterval(delay))
        if reason == .obstructed, rt.issues[path] == nil {
            rt.issues[path] = "「\(path)」被本机的其他文件占用，稍后重试"
        }
    }

    func clearProblem(_ rt: FolderRuntime, _ path: String) {
        rt.blocked[path] = nil
        rt.blockedRetry[path] = nil
        rt.issues[path] = nil
    }
}
