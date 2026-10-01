import Foundation
import OneSwitchCore

// MARK: - Index entries

/// Kind of an indexed entry. Symlinks are never followed.
public enum EntryKind: Int, Codable, Sendable {
    case file = 0
    case directory = 1
    case symlink = 2
}

/// A version vector `[deviceID: counter]`. Counters only ever grow; a device only bumps its own entry.
public struct VersionVector: Hashable, Sendable, CustomStringConvertible {
    public private(set) var counters: [String: UInt64]

    public init(_ counters: [String: UInt64] = [:]) {
        self.counters = counters.filter { $0.value > 0 }
    }

    public static let empty = VersionVector()

    public var isEmpty: Bool { counters.isEmpty }

    public subscript(device: String) -> UInt64 { counters[device] ?? 0 }

    public enum Ordering: Sendable, Equatable {
        case equal, greater, lesser, concurrent
    }

    /// How `self` relates to `other` (greater = self dominates).
    public func compare(_ other: VersionVector) -> Ordering {
        var greater = false
        var lesser = false
        for (device, value) in counters {
            let o = other.counters[device] ?? 0
            if value > o { greater = true } else if value < o { lesser = true }
        }
        for (device, o) in other.counters where counters[device] == nil && o > 0 {
            lesser = true
        }
        switch (greater, lesser) {
        case (false, false): return .equal
        case (true, false): return .greater
        case (false, true): return .lesser
        case (true, true): return .concurrent
        }
    }

    /// Element-wise maximum.
    public func merged(with other: VersionVector) -> VersionVector {
        var result = counters
        for (device, value) in other.counters where value > (result[device] ?? 0) {
            result[device] = value
        }
        return VersionVector(result)
    }

    /// Bumps `device`'s own counter to a value strictly greater than its current value and ≥ `atLeast`.
    public func bumped(device: String, atLeast: UInt64) -> VersionVector {
        var result = counters
        result[device] = max((result[device] ?? 0) + 1, atLeast)
        return VersionVector(result)
    }

    public var description: String {
        "{" + counters.sorted { $0.key < $1.key }.map { "\($0.key.prefix(8)):\($0.value)" }.joined(separator: ",") + "}"
    }

    // Storage encoding (canonical: sorted by device id) — two equal vectors encode to the same string.
    private static let pairSeparator: Character = "\u{1E}"
    private static let valueSeparator: Character = "\u{1F}"

    var storageString: String {
        counters.sorted { $0.key < $1.key }
            .map { "\($0.key)\(Self.valueSeparator)\($0.value)" }
            .joined(separator: String(Self.pairSeparator))
    }

    init(storageString: String) {
        var dict: [String: UInt64] = [:]
        if !storageString.isEmpty {
            for pair in storageString.split(separator: Self.pairSeparator) {
                let parts = pair.split(separator: Self.valueSeparator, maxSplits: 1)
                if parts.count == 2, let v = UInt64(parts[1]) { dict[String(parts[0])] = v }
            }
        }
        self.init(dict)
    }
}

/// One entry of a folder index (local or remote). `path` is NFC-normalized, "/"-separated, relative.
public struct FileRecord: Equatable, Sendable {
    public var path: String
    public var kind: EntryKind
    public var size: Int64
    /// Modification time in nanoseconds since 1970.
    public var mtimeNS: Int64
    /// POSIX permission bits (mode & 0o7777).
    public var mode: UInt32
    /// SHA-256 of the contents (files only).
    public var hash: Data?
    /// Symlink target (symlinks only).
    public var target: String?
    public var deleted: Bool
    public var version: VersionVector
    /// Local sequence number of the device that owns this index (monotonic per folder).
    public var sequence: Int64

    public init(path: String, kind: EntryKind, size: Int64 = 0, mtimeNS: Int64 = 0, mode: UInt32 = 0o644,
                hash: Data? = nil, target: String? = nil, deleted: Bool = false,
                version: VersionVector = .empty, sequence: Int64 = 0) {
        self.path = path
        self.kind = kind
        self.size = size
        self.mtimeNS = mtimeNS
        self.mode = mode
        self.hash = hash
        self.target = target
        self.deleted = deleted
        self.version = version
        self.sequence = sequence
    }

    var isLive: Bool { !deleted }

    /// The quick-check view used by the scanner (everything except version / sequence).
    var quick: QuickRecord {
        QuickRecord(kind: kind, size: size, mtimeNS: mtimeNS, mode: mode, hash: hash, target: target, deleted: deleted)
    }

    /// True when the observed on-disk entry still corresponds to this (live) record.
    func matches(_ disk: DiskState) -> Bool {
        guard !deleted, disk.kind == kind else { return false }
        switch kind {
        case .file: return disk.size == size && disk.mtimeNS == mtimeNS && disk.mode == mode
        case .directory: return true
        case .symlink: return disk.target == target
        }
    }

    var mtimeDate: Date { Date(timeIntervalSince1970: Double(mtimeNS) / 1e9) }
}

/// Scanner snapshot of an index record (no version).
struct QuickRecord: Equatable, Sendable {
    var kind: EntryKind
    var size: Int64
    var mtimeNS: Int64
    var mode: UInt32
    var hash: Data?
    var target: String?
    var deleted: Bool
}

/// An entry observed on disk (lstat; symlinks not followed).
struct DiskState: Equatable, Sendable {
    var kind: EntryKind
    var size: Int64
    var mtimeNS: Int64
    var mode: UInt32
    var target: String?
    /// A dataless file (content only in the cloud; reading it would trigger a download).
    var dataless = false
}

// MARK: - Folder configuration

/// What happens to a local file that is deleted or overwritten by a remote change.
public enum VersioningMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case none
    case trash
    case versions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .none: return "不保留"
        case .trash: return "移到废纸篓"
        case .versions: return "保存到 .oneswitch/versions（30 天）"
        }
    }
}

/// A synced folder. Folders pair across the two Macs by `id`; `path` is per Mac.
public struct FolderConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var path: String
    public var paused: Bool
    /// User ignore patterns (fnmatch globs, one per entry). Defaults are always applied on top.
    public var ignorePatterns: [String]
    public var versioning: VersioningMode

    public init(id: String, label: String, path: String, paused: Bool = false,
                ignorePatterns: [String] = [], versioning: VersioningMode = .trash) {
        self.id = id
        self.label = label
        self.path = path
        self.paused = paused
        self.ignorePatterns = ignorePatterns
        self.versioning = versioning
    }

    private enum CodingKeys: String, CodingKey { case id, label, path, paused, ignorePatterns, versioning }

    /// Tolerant decoding: the folder list lives inside one settings value, so a missing field (older
    /// settings) or an unknown versioning mode (after a downgrade) must never drop the user's folders.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? URL(fileURLWithPath: path).lastPathComponent
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? false
        ignorePatterns = (try? c.decodeIfPresent([String].self, forKey: .ignorePatterns)) ?? []
        versioning = (try? c.decodeIfPresent(VersioningMode.self, forKey: .versioning)) ?? .trash
    }

    /// A new shared folder id such as "docs-7f3a2c" (label transliterated to ASCII + 6 random hex digits).
    public static func makeID(label: String) -> String {
        let latin = label.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? label
        var slug = String(latin.lowercased().unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
            .map(Character.init).prefix(16))
        if slug.isEmpty { slug = "folder" }
        let suffix = String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
        return "\(slug)-\(suffix)"
    }
}

// MARK: - UI snapshot (published by the engine, rendered by the module)

public enum FolderSyncState: Equatable, Sendable {
    case idle
    case scanning
    case syncing(progress: Double)
    case paused
    case waitingForPeer
    case waitingForShare
    case error(String)

    public var displayText: String {
        switch self {
        case .idle: return "空闲·已同步"
        case .scanning: return "扫描中"
        case .syncing(let p): return "同步中 \(Fmt.percent(min(max(p, 0), 0.99)))"
        case .paused: return "已暂停"
        case .waitingForPeer: return "等待连接"
        case .waitingForShare: return "等待对方接受共享"
        case .error(let message): return "错误：\(message)"
        }
    }

    public var tone: StatusBadge.Tone {
        switch self {
        case .idle: return .ok
        case .scanning, .syncing: return .busy
        case .paused, .waitingForPeer, .waitingForShare: return .idle
        case .error: return .error
        }
    }

    public var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

public enum ChangeAction: String, Sendable, Codable {
    case added, modified, deleted

    public var title: String {
        switch self {
        case .added: return "新增"
        case .modified: return "修改"
        case .deleted: return "删除"
        }
    }
}

/// A recently synced change. `incoming` = received from the other Mac (↓), otherwise local (↑).
public struct RecentChange: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let folderID: String
    public let path: String
    public let incoming: Bool
    public let action: ChangeAction
    public let kind: EntryKind
    public let time: Date

    public var arrow: String { incoming ? "↓" : "↑" }
}

/// A conflict copy created on this Mac.
public struct ConflictInfo: Identifiable, Equatable, Sendable, Codable {
    public var id: String { folderID + "/" + conflictPath }
    public let folderID: String
    /// Relative path of the conflict copy ("a/report.sync-conflict-20260929-101500-MacBook.docx").
    public let conflictPath: String
    /// Relative path of the original file.
    public let originalPath: String
    public let time: Date
    /// Absolute path of the conflict copy at the time it was created.
    public let absolutePath: String
    /// True when this Mac's losing version was renamed into the copy; false for a copy made on the other
    /// Mac and received from it (its content is the *other* Mac's version). nil for older records.
    public var createdLocally: Bool? = nil
}

public struct FolderStatus: Identifiable, Equatable, Sendable {
    public let id: String
    public var label: String
    public var path: String
    public var state: FolderSyncState
    public var fileCount: Int
    public var directoryCount: Int
    public var totalBytes: Int64
    public var needItems: Int
    public var needBytes: Int64
    /// Current receive rate (bytes/s).
    public var rate: Double
    public var lastSyncAt: Date?
    public var recent: [RecentChange]
    public var conflicts: [ConflictInfo]
    /// Per-path problems (case conflicts, permission errors, …), user-facing Chinese.
    public var issues: [String]
    public var peerHasFolder: Bool
    public var peerPaused: Bool
    public var versioning: VersioningMode
    public var paused: Bool
}

/// A folder the other Mac shares that is not configured here.
public struct FolderOffer: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let peerName: String
}

/// Counters for diagnostics and self-checks.
public struct EngineStats: Equatable, Sendable {
    public var messagesSent = 0
    public var messagesReceived = 0
    public var indexRecordsSent = 0
    public var indexRecordsReceived = 0
    public var blockBytesReceived: Int64 = 0
    public var blockBytesSent: Int64 = 0
    public var blockRequestsServed = 0
    public var filesPulled = 0
    public var filesClonedLocally = 0
    public var filesHashed = 0
    public var bytesHashed: Int64 = 0
    public var conflictsCreated = 0
    public var fullScans = 0
    /// Highest number of block bytes requested-but-unreceived plus received-but-unwritten (memory bound).
    public var peakBufferedBytes = 0

    public init() {}
}

public struct EngineSnapshot: Equatable, Sendable {
    public var folders: [FolderStatus] = []
    public var offers: [FolderOffer] = []
    public var peerName: String?
    public var connected = false
    public var pausedAll = false
    public var stats = EngineStats()
    /// The index database was found corrupted while running: stop and start the engine to rebuild it.
    public var needsRestart = false

    public init() {}

    public static let empty = EngineSnapshot()

    public var totalNeedItems: Int { folders.reduce(0) { $0 + $1.needItems } }
    public var totalNeedBytes: Int64 { folders.reduce(0) { $0 + $1.needBytes } }
    public var totalRate: Double { folders.reduce(0) { $0 + $1.rate } }
}
