import Foundation
import OneSwitchCore

/// Wire protocol of service "sync". Control messages are compact JSON; block data uses a binary frame.
enum SyncProtocol {
    static let service = "sync"
    static let version = 1
    /// Largest block a peer may request (and we serve).
    static let maxBlockSize = 1 << 20

    /// Folder ids are 1–64 ASCII letters, digits, "-" or "_" (as made by `FolderConfig.makeID`). Anything
    /// else from the peer is ignored: ids are embedded in index meta keys ("folder.<id>.path"), where a
    /// dot could make one folder's keys look like another's (and a removed folder's cleanup delete them).
    static func isValidFolderID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 64 else { return false }
        return id.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F
        }
    }

    enum MessageType: UInt16 {
        case hello = 0x0001
        case folders = 0x0002
        case index = 0x0003
        case blockRequest = 0x0004
        case blockResponse = 0x0005
    }

    enum BlockStatus: UInt8 {
        case ok = 0
        case notFound = 1
        case changed = 2
        case unavailable = 3
        case ioError = 4
    }

    /// A folder as announced to the peer. `haveIndex` / `haveSeq` describe how much of the *receiver's*
    /// index for this folder the sender already holds (so the receiver only sends what is newer).
    struct Folder: Codable, Equatable {
        var id: String
        var label: String
        var paused: Bool?
        var haveIndex: UInt64?
        var haveSeq: Int64?

        enum CodingKeys: String, CodingKey {
            case id, label = "l", paused = "p", haveIndex = "hi", haveSeq = "hs"
        }
    }

    struct Hello: Codable, Equatable {
        var v: Int
        var device: String
        var name: String
        var folders: [Folder]
        /// The sender marks every index batch that further batches follow ("more" in `Index`), so a batch without
        /// it completes what the sender holds. Absent from older peers (v1.0.2), whose batch series can only be
        /// told complete by the index stream going quiet.
        var more: Bool? = nil
    }

    struct Folders: Codable, Equatable {
        var folders: [Folder]
    }

    /// One batch of index records (≤ 2 000). `reset`: the receiver drops what it had for this folder first.
    /// `last`: the initial exchange for this folder is complete. `more`: the sender already holds further
    /// records and sends them in the next batch(es) — a change spanning several batches (a large rename or
    /// deletion) is not complete yet. Absent (older peers) = unknown, treated as "no more".
    struct Index: Codable {
        var folder: String
        var indexID: UInt64
        var reset: Bool?
        var last: Bool?
        var more: Bool? = nil
        var records: [Record]

        enum CodingKeys: String, CodingKey {
            case folder = "f", indexID = "i", reset = "r", last = "l", more = "m", records = "s"
        }
    }

    struct Record: Codable, Equatable {
        var path: String
        var kind: Int
        var size: Int64
        var mtime: Int64
        var mode: UInt32
        var hash: String?
        var target: String?
        var deleted: Bool?
        var version: [String: UInt64]
        var seq: Int64

        enum CodingKeys: String, CodingKey {
            case path = "p", kind = "k", size = "s", mtime = "m", mode = "o", hash = "h", target = "t",
                 deleted = "d", version = "v", seq = "q"
        }

        init(_ r: FileRecord) {
            path = r.path
            kind = r.kind.rawValue
            size = r.size
            mtime = r.mtimeNS
            mode = r.mode
            hash = r.hash.map(Hex.encode)
            target = r.target
            deleted = r.deleted ? true : nil
            version = r.version.counters
            seq = r.sequence
        }

        /// Converts to a record, validating path and fields. Returns nil for malformed input.
        func toRecord() -> FileRecord? {
            guard let kind = EntryKind(rawValue: kind) else { return nil }
            let normalized = SyncPath.normalize(path)
            guard SyncPath.isValidRelative(normalized) else { return nil }
            let isDeleted = deleted ?? false
            var digest: Data?
            if let hash {
                guard let d = Hex.decode(hash), d.count == 32 else { return nil }
                digest = d
            }
            if kind == .file && !isDeleted && digest == nil { return nil }
            if kind == .symlink && !isDeleted && (target ?? "").isEmpty { return nil }
            return FileRecord(path: normalized, kind: kind, size: max(0, size), mtimeNS: mtime, mode: mode & 0o777,
                              hash: isDeleted ? nil : digest, target: isDeleted ? nil : target, deleted: isDeleted,
                              version: VersionVector(version), sequence: seq)
        }
    }

    struct BlockRequest: Codable, Equatable {
        var id: UInt64
        var folder: String
        var path: String
        var hash: String
        var offset: Int64
        var length: Int

        enum CodingKeys: String, CodingKey {
            case id = "r", folder = "f", path = "p", hash = "h", offset = "o", length = "l"
        }
    }

    /// Binary block response: [requestID: UInt64 big-endian][status: UInt8][data…]
    static let blockHeaderSize = 9

    static func writeBlockHeader(into data: inout Data, requestID: UInt64, status: BlockStatus) {
        data.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: requestID.bigEndian, toByteOffset: 0, as: UInt64.self)
            raw.storeBytes(of: status.rawValue, toByteOffset: 8, as: UInt8.self)
        }
    }

    static func blockError(requestID: UInt64, status: BlockStatus) -> Data {
        var d = Data(count: blockHeaderSize)
        writeBlockHeader(into: &d, requestID: requestID, status: status)
        return d
    }

    /// Parses a response; the returned data is a slice of `payload` (no copy).
    static func parseBlockResponse(_ payload: Data) -> (requestID: UInt64, status: BlockStatus, data: Data)? {
        guard payload.count >= blockHeaderSize else { return nil }
        let start = payload.startIndex
        var idBE: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &idBE) { dst in
            payload.copyBytes(to: dst, from: start..<(start + 8))
        }
        guard let status = BlockStatus(rawValue: payload[start + 8]) else { return nil }
        return (UInt64(bigEndian: idBE), status, payload[(start + blockHeaderSize)...])
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    static func encode<T: Encodable>(_ value: T) -> Data? {
        do {
            return try encoder.encode(value)
        } catch {
            AppLog.error("sync", "encode \(T.self) failed: \(error)")
            return nil
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.warning("sync", "malformed \(T.self) message: \(error)")
            return nil
        }
    }
}

enum Hex {
    private static let digits = Array("0123456789abcdef".utf8)

    static func encode(_ data: Data) -> String {
        var out = [UInt8]()
        out.reserveCapacity(data.count * 2)
        for b in data {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ s: String) -> Data? {
        let bytes = Array(s.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var out = Data(capacity: bytes.count / 2)
        var i = 0
        while i < bytes.count {
            guard let hi = value(bytes[i]), let lo = value(bytes[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func value(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
