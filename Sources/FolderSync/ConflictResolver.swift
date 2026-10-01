import Foundation

/// What to do with one path given our record and the peer's record. Pure and deterministic: both Macs
/// evaluate the same pair of records (mirrored) and reach complementary decisions.
enum SyncAction: Equatable {
    /// Nothing to do (we are up to date or newer).
    case none
    /// Same content: record `version`; when `metadata` is non-nil also apply its mtime / mode.
    case adopt(version: VersionVector, metadata: FileRecord?)
    /// Make the local entry match the remote record and record `version`. When `conflict` is true our
    /// (losing, non-deleted) content must first be preserved as a conflict copy.
    case apply(version: VersionVector, conflict: Bool)
}

enum ConflictResolver {
    /// Content equality: same kind and hash / symlink target, or both deleted. Directories are equal by kind.
    static func contentEqual(_ a: FileRecord, _ b: FileRecord) -> Bool {
        if a.deleted || b.deleted { return a.deleted && b.deleted }
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .file: return a.hash != nil && a.hash == b.hash && a.size == b.size
        case .symlink: return a.target == b.target
        case .directory: return true
        }
    }

    /// Metadata that is synced on top of content (mtime + mode for files, mode for directories).
    static func metadataEqual(_ a: FileRecord, _ b: FileRecord) -> Bool {
        if a.deleted || b.deleted { return true }
        switch a.kind {
        case .file: return a.mtimeNS == b.mtimeNS && a.mode == b.mode
        case .directory: return a.mode == b.mode
        case .symlink: return true
        }
    }

    /// True when `local` wins over `remote` for concurrent versions: a modification always beats a
    /// deletion, otherwise the later mtime wins, ties go to the larger device id.
    static func localWins(local: FileRecord, remote: FileRecord, localDevice: String, remoteDevice: String) -> Bool {
        if local.deleted != remote.deleted { return !local.deleted }
        if local.mtimeNS != remote.mtimeNS { return local.mtimeNS > remote.mtimeNS }
        return localDevice > remoteDevice
    }

    /// Concurrent versions with different content: the side whose content wins does nothing and keeps its
    /// own (unmerged) vector. Only the losing side merges — after preserving its content as a conflict copy —
    /// and its merged record then dominates both, so the winner merely adopts it. If the winner merged
    /// first, its dominating vector could reach the loser before the loser ever saw the concurrent version
    /// (e.g. while the loser's own edit was still being indexed); the loser would then replace its edit
    /// without creating a conflict copy.
    static func decide(local: FileRecord?, remote: FileRecord, localDevice: String, remoteDevice: String) -> SyncAction {
        guard let local else {
            // Never had it: anything the peer knows about dominates our empty history.
            return remote.version.isEmpty ? .none : .apply(version: remote.version, conflict: false)
        }
        switch local.version.compare(remote.version) {
        case .equal, .greater:
            return .none
        case .lesser:
            if contentEqual(local, remote) {
                return .adopt(version: remote.version, metadata: metadataEqual(local, remote) ? nil : remote)
            }
            return .apply(version: remote.version, conflict: false)
        case .concurrent:
            let merged = local.version.merged(with: remote.version)
            let wins = localWins(local: local, remote: remote, localDevice: localDevice, remoteDevice: remoteDevice)
            if contentEqual(local, remote) {
                if wins || metadataEqual(local, remote) { return .adopt(version: merged, metadata: nil) }
                return .adopt(version: merged, metadata: remote)
            }
            if wins { return .none }
            return .apply(version: merged, conflict: !local.deleted)
        }
    }
}
