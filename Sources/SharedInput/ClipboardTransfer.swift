import Foundation
import OneSwitchCore

/// Limits for clipboard hand-over.
public enum ClipboardLimits {
    /// Largest clipboard (encoded, all items) sent to the other Mac.
    public static let maxTotalBytes = 100 * 1024 * 1024
    /// Size of one `.clipboardChunk` piece. Small, so keyboard / mouse messages sharing the channel never
    /// queue behind more than about a millisecond of clipboard data.
    public static let chunkBytes = 1 * 1024 * 1024
    /// Most pieces one transfer may announce.
    public static let maxChunks = 4096
    /// An incomplete transfer is dropped when no piece arrived for this long.
    public static let transferTimeout: TimeInterval = 10
    /// Delay before a received clipboard is written (keeps pasteboard work away from the switch moment).
    public static let applyDelay: TimeInterval = 0.15
}

public enum ClipboardChunker {
    /// Splits an encoded clipboard into pieces of at most `chunkBytes`.
    public static func chunks(for payload: Data, transferID: UInt32, chunkBytes: Int = ClipboardLimits.chunkBytes) -> [ClipboardChunk] {
        let size = max(chunkBytes, 1)
        let count = max(1, (payload.count + size - 1) / size)
        var out: [ClipboardChunk] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let lo = payload.startIndex + i * size
            let hi = min(lo + size, payload.endIndex)
            out.append(ClipboardChunk(transferID: transferID, index: UInt32(i), count: UInt32(count),
                                      totalBytes: UInt64(payload.count), data: payload.subdata(in: lo..<hi)))
        }
        return out
    }
}

/// Reassembles `.clipboardChunk` transfers (pure; the caller supplies the time). Only the newest transfer
/// matters: a piece of a different transfer replaces an unfinished one.
public struct ClipboardAssembler: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// More pieces are needed.
        case pending
        case complete([ClipboardItem])
        /// The transfer was abandoned (reason for the log).
        case dropped(String)
    }

    public var timeout: TimeInterval
    public var maxTotalBytes: Int

    private struct Transfer {
        var id: UInt32
        var count: Int
        var total: Int
        var parts: [Data?]
        var received = 0
        var bytes = 0
        var lastAt: TimeInterval
    }

    private var current: Transfer?
    /// Newest transfer seen, and the last one that finished (completed or dropped): pieces of older or
    /// finished transfers are ignored instead of starting a partial transfer that could only time out.
    private var newestID: UInt32?
    private var finishedID: UInt32?
    /// Transfers abandoned in favour of a newer one or after a stall (for the log; drained by the caller).
    public var notes: [String] = []

    /// Transfer ids increase per sender (wrapping): serial-number comparison.
    static func isOlder(_ a: UInt32, than b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }

    public init(timeout: TimeInterval = ClipboardLimits.transferTimeout, maxTotalBytes: Int = ClipboardLimits.maxTotalBytes) {
        self.timeout = timeout
        self.maxTotalBytes = maxTotalBytes
    }

    public var isReceiving: Bool { current != nil }

    public mutating func add(_ chunk: ClipboardChunk, at t: TimeInterval) -> Outcome {
        if let reason = expire(at: t) { notes.append(reason) }
        if let newest = newestID, chunk.transferID != newest, Self.isOlder(chunk.transferID, than: newest) {
            return .pending // a straggler of a transfer a newer clipboard already replaced
        }
        if current?.id != chunk.transferID, chunk.transferID == finishedID {
            return .pending // late duplicate of a transfer that already completed / was dropped
        }
        newestID = chunk.transferID
        guard chunk.totalBytes <= UInt64(maxTotalBytes) else {
            return drop(chunk.transferID, "clipboard transfer \(chunk.transferID) too large (\(chunk.totalBytes) bytes)")
        }
        guard chunk.count >= 1, chunk.count <= UInt32(ClipboardLimits.maxChunks), chunk.index < chunk.count else {
            return drop(chunk.transferID, "clipboard transfer \(chunk.transferID) has an invalid piece \(chunk.index)/\(chunk.count)")
        }
        if let c = current, c.id != chunk.transferID {
            notes.append("clipboard transfer \(c.id) superseded by \(chunk.transferID) (\(c.received)/\(c.count) pieces)")
            current = nil
        }
        if current == nil {
            current = Transfer(id: chunk.transferID, count: Int(chunk.count), total: Int(chunk.totalBytes),
                               parts: Array(repeating: nil, count: Int(chunk.count)), lastAt: t)
        }
        guard var c = current else { return .pending }
        guard c.count == Int(chunk.count), c.total == Int(chunk.totalBytes) else {
            return drop(c.id, "clipboard transfer \(chunk.transferID) is inconsistent")
        }
        c.lastAt = t
        let i = Int(chunk.index)
        if c.parts[i] == nil {
            c.parts[i] = chunk.data
            c.received += 1
            c.bytes += chunk.data.count
        }
        guard c.bytes <= c.total else {
            return drop(c.id, "clipboard transfer \(chunk.transferID) exceeds its announced size")
        }
        guard c.received == c.count else {
            current = c
            return .pending
        }
        current = nil
        finishedID = c.id
        guard c.bytes == c.total else { return .dropped("clipboard transfer \(chunk.transferID) is incomplete") }
        var payload = Data(capacity: c.total)
        for part in c.parts { if let part { payload.append(part) } }
        guard let items = try? ClipboardCodec.decode(payload) else {
            return .dropped("clipboard transfer \(chunk.transferID) could not be decoded")
        }
        return .complete(items)
    }

    /// Drops an unfinished transfer that stalled. Returns the reason when one was dropped.
    public mutating func expire(at t: TimeInterval) -> String? {
        guard let c = current, t - c.lastAt > timeout else { return nil }
        current = nil
        finishedID = c.id
        return "clipboard transfer \(c.id) timed out (\(c.received)/\(c.count) pieces)"
    }

    private mutating func drop(_ id: UInt32, _ reason: String) -> Outcome {
        current = nil
        finishedID = id
        return .dropped(reason)
    }
}

/// Collects `.clipboardChunk` pieces off the channel queue: joining and decoding up to 100 MB must not
/// hold up the keyboard / mouse messages that share the channel (on the client they are injected there).
final class ClipboardInbox: @unchecked Sendable {
    private let queue = DispatchQueue(label: "oneswitch.input.clipboard", qos: .utility)
    /// Only touched on `queue`.
    private var assembler = ClipboardAssembler()
    private let clock: @Sendable () -> TimeInterval

    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// Called on the channel queue (pieces keep their order). `completion` runs on the inbox queue with
    /// the whole clipboard once its last piece arrived.
    func add(_ chunk: ClipboardChunk, completion: @escaping @Sendable ([ClipboardItem]) -> Void) {
        queue.async { [self] in
            let outcome = assembler.add(chunk, at: clock())
            assembler.notes.forEach { AppLog.warning("input", $0) }
            assembler.notes.removeAll()
            switch outcome {
            case .pending:
                break
            case .complete(let items):
                completion(items)
            case .dropped(let reason):
                AppLog.warning("input", reason)
            }
        }
    }

    /// Drops a stalled transfer (heartbeat timer).
    func expire() {
        queue.async { [self] in
            if let reason = assembler.expire(at: clock()) { AppLog.warning("input", reason) }
        }
    }
}

/// Sends a clipboard to the peer: as one `.clipboard` message to older peers, or as paced
/// `.clipboardChunk` pieces (the next piece is sent once the previous one was handed to the network
/// stack, so input messages interleave). A newer clipboard cancels a transfer still in progress.
final class ClipboardSender: @unchecked Sendable {
    typealias Send = (_ type: UInt16, _ payload: Data, _ completion: (@Sendable (Error?) -> Void)?) -> Void

    /// How a transfer ended.
    enum Outcome: Equatable, Sendable {
        /// Every piece was handed to the network.
        case sent
        /// A newer clipboard replaced it before it was complete.
        case superseded
        /// Not sent: too large (in total, or for an older peer). Retrying would fail the same way.
        case refused
        /// The channel failed (e.g. the other Mac disconnected mid-transfer): worth offering again.
        case failed
    }

    private let lock = NSLock()
    private var generation: UInt32 = 0
    private let send: Send
    private let chunkBytes: Int

    init(chunkBytes: Int = ClipboardLimits.chunkBytes, send: @escaping Send) {
        self.chunkBytes = chunkBytes
        self.send = send
    }

    /// Returns a one-line summary for the log (or why nothing was sent). `onFinished` runs once, on an
    /// unspecified queue.
    @discardableResult
    func send(_ items: [ClipboardItem], chunked: Bool, onFinished: (@Sendable (Outcome) -> Void)? = nil) -> String {
        let payload = ClipboardCodec.encode(items)
        let summary = ClipboardSender.describe(items)
        let id: UInt32 = lock.withLock {
            generation &+= 1
            return generation
        }
        guard payload.count <= ClipboardLimits.maxTotalBytes else {
            onFinished?(.refused)
            return "clipboard not sent: \(summary) exceeds \(ClipboardLimits.maxTotalBytes / 1_048_576) MB"
        }
        if !chunked {
            let (type, body) = InputMessage.clipboard(items).encode()
            guard body.count <= PeerLimits.maxPayloadSize else {
                onFinished?(.refused)
                return "clipboard not sent: \(summary) is too large for the other Mac's OneSwitch version"
            }
            send(type, body) { error in
                if let error { AppLog.warning("input", "clipboard could not be sent: \(error)") }
                onFinished?(error == nil ? .sent : .failed)
            }
            return "clipboard sent: \(summary) in 1 message"
        }
        let chunks = ClipboardChunker.chunks(for: payload, transferID: id, chunkBytes: chunkBytes)
        sendPiece(0, of: chunks, generation: id, onFinished: onFinished)
        return "clipboard sent: \(summary) in \(chunks.count) piece\(chunks.count == 1 ? "" : "s")"
    }

    private func sendPiece(_ index: Int, of chunks: [ClipboardChunk], generation id: UInt32, onFinished: (@Sendable (Outcome) -> Void)?) {
        guard index < chunks.count else { onFinished?(.sent); return }
        guard lock.withLock({ generation == id }) else {
            AppLog.info("input", "clipboard transfer \(id) cancelled by a newer clipboard (\(index)/\(chunks.count) pieces sent)")
            onFinished?(.superseded)
            return
        }
        let (type, body) = InputMessage.clipboardChunk(chunks[index]).encode()
        send(type, body) { [weak self] error in
            if let error {
                AppLog.warning("input", "clipboard transfer \(id) failed at piece \(index): \(error)")
                onFinished?(.failed)
                return
            }
            guard let self else { onFinished?(.failed); return }
            self.sendPiece(index + 1, of: chunks, generation: id, onFinished: onFinished)
        }
    }

    static func describe(_ items: [ClipboardItem]) -> String {
        let total = items.reduce(0) { $0 + $1.data.count }
        let parts = items.map { "\($0.type) \(formatBytes($0.data.count))" }.joined(separator: ", ")
        return "\(items.count) item\(items.count == 1 ? "" : "s"), \(formatBytes(total)) (\(parts))"
    }

    static func formatBytes(_ n: Int) -> String {
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n >= 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return "\(n) B"
    }
}
