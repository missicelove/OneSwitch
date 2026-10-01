# FolderSync — implementation spec

Class FolderSyncModule: FeatureModule, "public init(hub: any PeerHub)", id "sync", displayName "文件同步", symbolName "arrow.triangle.2.circlepath". Uses ONLY the PeerHub/PeerChannel contract (service "sync"; message types in PeerLimits.serviceTypeRange). Register the service while the feature is enabled and ≥1 folder is configured; unregister otherwise. Develop and test against LoopbackPeerHub (the real network hub is built in parallel by another agent).

ARCHITECTURE (testable, off the main thread)
- SyncEngine: no UI; own serial queue or actor; injected: hub, state directory, local deviceID/name, clock. Components: folder config, persistent index, scanner, FSEvents watcher, puller/transfer, protocol codec, conflict resolver. The FeatureModule wraps it and publishes UI state on the main actor, throttled to ≤ 4 updates/s.
- Index persistence: SQLite via "import SQLite3" (preferred for 100k+ files; WAL mode) or JSON with debounced atomic writes — your call, justify it. State dir = AppContext.shared.dataDirectory/sync/.

FOLDER MODEL
- Folder: shared folderID (e.g. "docs-7f3a2c"), label, local path (per Mac), paused, ignore patterns (fnmatch globs), versioning mode. Folders pair across Macs by folderID.
- Offers: when the peer announces a folderID we don't have, show a pending offer "对方共享了文件夹「label」" → the user accepts by choosing a local path (NSOpenPanel, can create a folder) or ignores it. Adding a folder locally announces it to the peer.
- SAFETY MARKER: each synced root contains a ".oneswitch" directory (create on add). If the root or marker is missing (external disk unmounted, folder moved), the folder goes to error "文件夹不存在或已被移动" and NOTHING is scanned or propagated — never interpret a missing root as mass deletion.
- Default ignores: .DS_Store, ._*, .Spotlight-V100, .Trashes, .fseventsd, .TemporaryItems, "Icon\\r", *.oneswitch-tmp, and the .oneswitch directory itself.

INDEX RECORD per relative path (NFC-normalized, "/" separators): kind (file/dir/symlink), size, mtime (ns precision), POSIX mode, SHA-256 (files; streaming CryptoKit 1 MiB chunks), symlink target (do not follow symlinks), deleted flag (tombstone), version vector [deviceID: UInt64], local sequence number (monotonic per folder) for incremental index exchange.

SCANNING
- Full scan at start and on "立即扫描"; FSEvents (FSEventStreamCreate with kFSEventStreamCreateFlagFileEvents | NoDefer | WatchRoot, latency ~0.3 s, FSEventStreamSetDispatchQueue) triggers targeted rescans of changed paths (fall back to full rescan on MustScanSubDirs / history overflow / root changed). Quick check (size, mtime, kind, mode) before hashing. New/changed → bump own counter; missing → tombstone + bump. Wait for files to settle (size/mtime stable for ~1 s) before hashing large files being written.

PROTOCOL (service "sync", compact JSON for control, binary for chunk data)
- On channel open: hello {protocolVersion, deviceID, deviceName, folders:[{id,label}]}; then per shared folder send the index (full on first contact, or only records with sequence > what the peer last acknowledged — persist per-peer acknowledged sequence) in batches (≤ 2 000 records/message); then push incremental updates in real time (debounced ~200 ms after local changes).
- Pulling: request blocks {requestID, folder, path, hash, offset, length ≤ 1 MiB} with a window of ~8 outstanding requests per file and a few files in parallel; responses carry the bytes (binary frame: small header + data) or an error (file changed/vanished → retry after the next index update). Use PeerChannel send completions for back-pressure. Target: saturate a Thunderbolt link without unbounded memory.
- Reconnect: all in-flight pulls are abandoned cleanly and resumed after the next index exchange.

DECISION RULES (must converge deterministically on both sides)
- Remote vector dominates → apply remote (pull file / create dir / create symlink / delete). Local dominates or equal → nothing. Concurrent: if contents equal (same kind + hash/target, or both deleted) → merge vectors (element-wise max), no transfer. Otherwise winner = later mtime, tie → larger deviceID; a modification always beats a deletion. The side holding the LOSING content renames its local copy to "<name>.sync-conflict-<yyyyMMdd-HHmmss>-<deviceName>.<ext>" (a new file that then syncs normally) and applies the winner; the winner side merges vectors. Record conflicts for the UI.
- Applying a remote file: write to ".<name>.oneswitch-tmp-<random>" in the destination directory, verify SHA-256, set mtime + mode, then immediately before the atomic rename re-stat the local file and abort if it no longer matches the index (a local edit raced us — next scan handles it as a conflict). Update the index with the resulting stat so the FSEvents echo is not treated as a local change (no version bump, no ping-pong).
- Deletions: process deepest paths first; only remove directories that are empty after their children are handled; unknown/ignored leftovers keep the directory (log it).
- Versioning per folder: "不保留" / "移到废纸篓" (default; FileManager.trashItem) / "保存到 .oneswitch/versions（30 天）" for files deleted or overwritten by remote changes.
- Case-insensitive APFS: detect two remote paths differing only by case and report instead of thrashing.

UI
- Per folder: state (空闲·已同步 / 扫描中 / 同步中 x% / 已暂停 / 等待连接 / 错误: …), file count + total size, pending items + bytes, current rate, last sync time, recent changes (last 50: path, ↑/↓, time), conflicts (Show in Finder).
- Menu section: overall line ("● 已同步 · 3 个文件夹" / "↻ 正在同步 12 个文件 · 240 MB · 85 MB/s" / "○ 等待连接另一台 Mac"), per-folder submenu (打开文件夹, 立即扫描, 暂停/继续同步), "暂停全部同步"/"继续全部同步", pending offers ("接受「label」…"), "文件同步设置…".
- Settings page: enable toggle, peer status (hub.statusPublisher), folder list with add (NSOpenPanel), edit (label, ignore patterns multi-line, versioning), remove (never deletes files), pause; pending offers; recent activity; conflicts.

CHECKS (the most important part — use LoopbackPeerHub.makePair(), two engines with separate temp state dirs and two temp folders sharing a folderID, real FSEvents, generous timeouts, compare trees by relative path + kind + content hash + mtime): initial sync both directions (nested dirs, empty dirs, empty file, 20 MB random binary, 中文文件名.txt, names with spaces/emoji, symlink); modify / delete file / delete dir tree / rename propagate; concurrent edit → exactly one conflict copy, both trees identical afterwards; delete-vs-modify → modification survives on both; ignore patterns respected; missing marker/root → no deletions propagated to the peer; offline edits on both sides (hubA.setLinked(false) … setLinked(true)) converge; echo suppression (after convergence no sync messages for 2 s); 2 000 small files; restart an engine (persisted index) and verify no full re-transfer. Report timings.
