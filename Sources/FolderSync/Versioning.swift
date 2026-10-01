import Foundation

/// Versioning of local files that remote changes delete or overwrite:
/// - 不保留 (`.none`): removed / replaced directly.
/// - 移到废纸篓 (`.trash`): renamed into "<root>/.oneswitch/trash-pending/<uuid>/<path>" (instant, so the engine
///   never waits on Finder / the Trash), then moved to the Trash in the background. Volumes without a
///   Trash fall back to the versions folder.
/// - 保存到 .oneswitch/versions (`.versions`): "<root>/.oneswitch/versions/<dir>/<stem>~<yyyyMMdd-HHmmss>.<ext>",
///   pruned after 30 days.
extension SyncEngine {
    /// Moves a local file out of the way according to the folder's versioning mode (symlinks are removed).
    func archiveOrRemove(_ rt: FolderRuntime, path: String, kind: EntryKind) -> Bool {
        let abs = rt.absolute(path)
        if kind != .file {
            return unlink(abs) == 0 || errno == ENOENT
        }
        switch rt.config.versioning {
        case .none:
            return unlink(abs) == 0 || errno == ENOENT
        case .trash:
            return stageForTrash(rt, path: path) || moveToVersions(rt, path: path)
        case .versions:
            return moveToVersions(rt, path: path)
        }
    }

    /// Moves a file to ".oneswitch/versions/<dir>/<stem>~<yyyyMMdd-HHmmss>.<ext>".
    func moveToVersions(_ rt: FolderRuntime, path: String) -> Bool {
        guard let root = rt.realRoot, FS.isDirectory(root + "/" + SyncPath.markerName) else { return false }
        let dir = root + "/" + SyncPath.markerName + "/versions" + (SyncPath.parent(path).isEmpty ? "" : "/" + SyncPath.parent(path))
        guard FS.makeDirectories(dir) else { return false }
        let dest = VersionStore.uniqueVersionPath(directory: dir, name: SyncPath.name(path), date: clock())
        if FS.renameExclusive(rt.absolute(path), dest) { return true }
        AppLogSync.warning("cannot keep version of \(path): \(FS.errorString(errno))")
        return false
    }

    /// Renames the file into the trash staging area and queues the actual move to the Trash.
    private func stageForTrash(_ rt: FolderRuntime, path: String) -> Bool {
        guard let root = rt.realRoot, FS.isDirectory(root + "/" + SyncPath.markerName) else { return false }
        let container = root + "/" + SyncPath.markerName + "/trash-pending/" + UUID().uuidString
        let staged = container + "/" + path
        guard FS.makeDirectories((staged as NSString).deletingLastPathComponent) else { return false }
        guard rename(rt.absolute(path), staged) == 0 else {
            VersionStore.removeEmptyDirectories(container)
            return false
        }
        let item = VersionStore.TrashItem(staged: staged, container: container, relativePath: path,
                                          versionsDirectory: root + "/" + SyncPath.markerName + "/versions")
        let cancel = cancelFlag
        trashQueue.async { VersionStore.moveToTrash(item, cancel: cancel) }
        return true
    }

    /// Finishes trash moves interrupted by a quit / crash (called when a folder is activated).
    func resumePendingTrash(_ rt: FolderRuntime) {
        guard let root = rt.realRoot else { return }
        let marker = root + "/" + SyncPath.markerName
        guard FS.isDirectory(marker + "/trash-pending") else { return }
        let cancel = cancelFlag
        trashQueue.async {
            for item in VersionStore.pendingTrashItems(markerDirectory: marker) {
                VersionStore.moveToTrash(item, cancel: cancel)
            }
        }
    }
}

/// File operations of the versioning modes that run off the engine queue.
enum VersionStore {
    struct TrashItem {
        let staged: String
        let container: String
        let relativePath: String
        let versionsDirectory: String
    }

    static func uniqueVersionPath(directory: String, name: String, date: Date) -> String {
        let baseName = Scanner.versionName(for: name, date: date)
        var dest = directory + "/" + baseName
        var n = 1
        while FS.exists(dest) && n < 1000 {
            let (stem, ext) = SyncPath.splitExtension(baseName)
            dest = directory + "/" + stem + "-\(n)" + (ext.isEmpty ? "" : "." + ext)
            n += 1
        }
        return dest
    }

    /// Runs on the trash queue.
    static func moveToTrash(_ item: TrashItem, cancel: AtomicFlag) {
        guard !cancel.isSet, FS.exists(item.staged) else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: item.staged), resultingItemURL: nil)
        } catch {
            // No Trash on this volume (some network / external disks): keep a version instead.
            let parent = SyncPath.parent(item.relativePath)
            let dir = item.versionsDirectory + (parent.isEmpty ? "" : "/" + parent)
            if FS.makeDirectories(dir) {
                let dest = uniqueVersionPath(directory: dir, name: SyncPath.name(item.relativePath), date: Date())
                if !FS.renameExclusive(item.staged, dest) {
                    AppLogSync.warning("cannot move \(item.relativePath) to the Trash or versions: \(error.localizedDescription)")
                    return
                }
            }
        }
        removeEmptyDirectories(item.container)
    }

    /// Items left in "<marker>/trash-pending/<uuid>/…".
    static func pendingTrashItems(markerDirectory marker: String) -> [TrashItem] {
        let pending = marker + "/trash-pending"
        guard case .success(let containers) = FS.listDirectory(pending) else { return [] }
        var items: [TrashItem] = []
        for c in containers {
            let container = pending + "/" + c
            let countBefore = items.count
            var stack = [""]
            while let rel = stack.popLast() {
                let dir = rel.isEmpty ? container : container + "/" + rel
                guard case .success(let names) = FS.listDirectory(dir) else { continue }
                for name in names {
                    let childRel = SyncPath.join(rel, name)
                    let abs = container + "/" + childRel
                    if FS.isDirectory(abs) {
                        stack.append(childRel)
                    } else {
                        items.append(TrashItem(staged: abs, container: container, relativePath: childRel,
                                               versionsDirectory: marker + "/versions"))
                    }
                }
            }
            if items.count == countBefore { removeEmptyDirectories(container) }
        }
        return items
    }

    /// rmdir of a directory tree bottom-up (non-empty directories stay).
    static func removeEmptyDirectories(_ dir: String) {
        if case .success(let names) = FS.listDirectory(dir) {
            for name in names where FS.isDirectory(dir + "/" + name) {
                removeEmptyDirectories(dir + "/" + name)
            }
        }
        rmdir(dir)
    }
}
