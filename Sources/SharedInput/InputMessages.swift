import Foundation

/// Handshake sent by both Macs whenever the channel opens or local settings / permissions change.
///
/// JSON, so fields can be added without breaking older peers: unknown keys are ignored by them, and
/// optional fields they do not send decode as nil here.
public struct InputHello: Codable, Equatable, Sendable {
    public var version: Int
    public var role: InputRole
    public var deviceName: String
    /// Client: whether it may post events (辅助功能 granted). Server: whether its event tap is running.
    public var ready: Bool
    /// Server: where the client's screen sits relative to the server.
    public var clientSide: ScreenSide
    /// Server: how the client should replay mouse-wheel input (nil from older servers).
    public var wheel: WheelConfig?
    /// Optional protocol features this build understands (`InputFeature`); nil from older peers.
    public var features: [String]?

    public init(version: Int = InputHello.currentVersion, role: InputRole, deviceName: String, ready: Bool, clientSide: ScreenSide,
                wheel: WheelConfig? = nil, features: [String]? = InputFeature.all) {
        self.version = version
        self.role = role
        self.deviceName = deviceName
        self.ready = ready
        self.clientSide = clientSide
        self.wheel = wheel
        self.features = features
    }

    public static let currentVersion = 1

    public func supports(_ feature: String) -> Bool { features?.contains(feature) ?? false }
}

/// Optional protocol features, advertised in the hello (kept out of `version` so that mixed builds still
/// work together and simply fall back to the older behaviour).
public enum InputFeature {
    /// Understands `InputMessage.clipboardChunk` (large clipboards split over several messages).
    public static let clipboardChunks = "clipboard.chunks"
    /// Client replays non-continuous (mouse-wheel) scrolling as smooth, phase-carrying gestures.
    public static let smoothWheel = "wheel.smooth"

    public static let all = [clipboardChunks, smoothWheel]
}

public struct ClipboardItem: Equatable, Sendable {
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

/// One piece of a clipboard that is too large for a single message. The pieces of one transfer, in
/// `index` order, concatenate to the `ClipboardCodec` encoding of the items.
public struct ClipboardChunk: Equatable, Sendable {
    public var transferID: UInt32
    public var index: UInt32
    public var count: UInt32
    /// Size of the whole encoded clipboard (all chunks).
    public var totalBytes: UInt64
    public var data: Data

    public init(transferID: UInt32, index: UInt32, count: UInt32, totalBytes: UInt64, data: Data) {
        self.transferID = transferID
        self.index = index
        self.count = count
        self.totalBytes = totalBytes
        self.data = data
    }
}

/// Binary layout of a clipboard: u32 item count, then (type blob, data blob) per item. Used both by the
/// single-message `.clipboard` and by the reassembled chunks of a `.clipboardChunk` transfer.
public enum ClipboardCodec {
    public static let maxItems = 64

    public static func encode(_ items: [ClipboardItem]) -> Data {
        var w = ByteWriter()
        w.u32(UInt32(items.count))
        for item in items {
            w.blob(Data(item.type.utf8))
            w.blob(item.data)
        }
        return w.data
    }

    public static func decode(_ data: Data) throws -> [ClipboardItem] {
        var r = ByteReader(data)
        let count = try r.u32()
        guard count <= maxItems else { throw InputCodecError.malformed }
        var items: [ClipboardItem] = []
        for _ in 0..<count {
            let typeData = try r.blob()
            let body = try r.blob()
            items.append(ClipboardItem(type: String(decoding: typeData, as: UTF8.self), data: body))
        }
        return items
    }
}

/// Everything exchanged on the "input" service. High-rate input events use a compact binary layout;
/// control messages too (except hello, which is JSON for forward compatibility).
public enum InputMessage: Equatable, Sendable {
    case hello(InputHello)
    /// Control moves to the client. `edge` is the client's edge the cursor enters through.
    case enter(edge: ScreenSide, fraction: Double, center: Bool, flags: UInt64)
    /// The client's cursor pushed back through the edge facing the server.
    case leave(fraction: Double)
    /// Server took control back: release every key / button the client pressed.
    case releaseAll
    case heartbeat(seq: UInt32, sentAt: Double, isReply: Bool)
    case clipboard([ClipboardItem])
    /// Part of a large clipboard (see `ClipboardChunk`); only sent to peers advertising
    /// `InputFeature.clipboardChunks`.
    case clipboardChunk(ClipboardChunk)
    case mouseMove(dx: Double, dy: Double)
    case mouseButton(button: UInt8, down: Bool, clickState: Int64, flags: UInt64)
    case scroll(ScrollData, flags: UInt64)
    case key(keyCode: UInt16, down: Bool, autorepeat: Bool, flags: UInt64)
    case flagsChanged(keyCode: UInt16, flags: UInt64)
    case systemDefined(subtype: Int16, data1: Int64, data2: Int64, flags: UInt64)

    // Wire type codes (must stay inside PeerLimits.serviceTypeRange).
    enum Code: UInt16 {
        case hello = 0x0001, enter = 0x0002, leave = 0x0003, releaseAll = 0x0004
        case heartbeat = 0x0005, clipboard = 0x0006, clipboardChunk = 0x0007
        case mouseMove = 0x0010, mouseButton = 0x0011, scroll = 0x0012
        case key = 0x0013, flagsChanged = 0x0014, systemDefined = 0x0015
    }

    /// True for messages that carry user input (counted for diagnostics).
    public var isInputEvent: Bool {
        switch self {
        case .mouseMove, .mouseButton, .scroll, .key, .flagsChanged, .systemDefined: return true
        default: return false
        }
    }

    public func encode() -> (type: UInt16, payload: Data) {
        var w = ByteWriter()
        let code: Code
        switch self {
        case .hello(let h):
            code = .hello
            w.data = (try? JSONEncoder().encode(h)) ?? Data()
        case .enter(let edge, let fraction, let center, let flags):
            code = .enter
            w.u8(edge.wireValue); w.f64(fraction); w.u8(center ? 1 : 0); w.u64(flags)
        case .leave(let fraction):
            code = .leave
            w.f64(fraction)
        case .releaseAll:
            code = .releaseAll
        case .heartbeat(let seq, let sentAt, let isReply):
            code = .heartbeat
            w.u32(seq); w.f64(sentAt); w.u8(isReply ? 1 : 0)
        case .clipboard(let items):
            code = .clipboard
            w.data = ClipboardCodec.encode(items)
        case .clipboardChunk(let c):
            code = .clipboardChunk
            w.u32(c.transferID); w.u32(c.index); w.u32(c.count); w.u64(c.totalBytes); w.blob(c.data)
        case .mouseMove(let dx, let dy):
            code = .mouseMove
            w.f64(dx); w.f64(dy)
        case .mouseButton(let button, let down, let clickState, let flags):
            code = .mouseButton
            w.u8(button); w.u8(down ? 1 : 0); w.i64(clickState); w.u64(flags)
        case .scroll(let s, let flags):
            code = .scroll
            w.i64(s.delta1); w.i64(s.delta2); w.i64(s.point1); w.i64(s.point2)
            w.f64(s.fixed1); w.f64(s.fixed2); w.i64(s.isContinuous); w.i64(s.scrollPhase)
            w.i64(s.momentumPhase); w.i64(s.scrollCount); w.u64(flags)
        case .key(let keyCode, let down, let autorepeat, let flags):
            code = .key
            w.u16(keyCode); w.u8(down ? 1 : 0); w.u8(autorepeat ? 1 : 0); w.u64(flags)
        case .flagsChanged(let keyCode, let flags):
            code = .flagsChanged
            w.u16(keyCode); w.u64(flags)
        case .systemDefined(let subtype, let data1, let data2, let flags):
            code = .systemDefined
            w.u16(UInt16(bitPattern: subtype)); w.i64(data1); w.i64(data2); w.u64(flags)
        }
        return (code.rawValue, w.data)
    }

    public static func decode(type: UInt16, payload: Data) throws -> InputMessage {
        guard let code = Code(rawValue: type) else { throw InputCodecError.unknownType(type) }
        var r = ByteReader(payload)
        switch code {
        case .hello:
            return .hello(try JSONDecoder().decode(InputHello.self, from: payload))
        case .enter:
            let edge = try ScreenSide(wireValue: r.u8())
            return .enter(edge: edge, fraction: try r.finite(), center: try r.u8() != 0, flags: try r.u64())
        case .leave:
            return .leave(fraction: try r.finite())
        case .releaseAll:
            return .releaseAll
        case .heartbeat:
            return .heartbeat(seq: try r.u32(), sentAt: try r.finite(), isReply: try r.u8() != 0)
        case .clipboard:
            return .clipboard(try ClipboardCodec.decode(payload))
        case .clipboardChunk:
            let id = try r.u32(), index = try r.u32(), count = try r.u32(), total = try r.u64()
            guard count >= 1, index < count else { throw InputCodecError.malformed }
            return .clipboardChunk(ClipboardChunk(transferID: id, index: index, count: count, totalBytes: total, data: try r.blob()))
        case .mouseMove:
            return .mouseMove(dx: try r.finite(), dy: try r.finite())
        case .mouseButton:
            return .mouseButton(button: try r.u8(), down: try r.u8() != 0, clickState: try r.i64(), flags: try r.u64())
        case .scroll:
            var s = ScrollData()
            s.delta1 = try r.i64(); s.delta2 = try r.i64(); s.point1 = try r.i64(); s.point2 = try r.i64()
            s.fixed1 = try r.finite(); s.fixed2 = try r.finite(); s.isContinuous = try r.i64(); s.scrollPhase = try r.i64()
            s.momentumPhase = try r.i64(); s.scrollCount = try r.i64()
            return .scroll(s, flags: try r.u64())
        case .key:
            return .key(keyCode: try r.u16(), down: try r.u8() != 0, autorepeat: try r.u8() != 0, flags: try r.u64())
        case .flagsChanged:
            return .flagsChanged(keyCode: try r.u16(), flags: try r.u64())
        case .systemDefined:
            return .systemDefined(subtype: Int16(bitPattern: try r.u16()), data1: try r.i64(), data2: try r.i64(), flags: try r.u64())
        }
    }
}

public enum InputCodecError: Error, Equatable {
    case unknownType(UInt16)
    case truncated
    case malformed
}

extension ScreenSide {
    var wireValue: UInt8 {
        switch self {
        case .left: return 0
        case .right: return 1
        case .top: return 2
        case .bottom: return 3
        }
    }

    init(wireValue: UInt8) throws {
        switch wireValue {
        case 0: self = .left
        case 1: self = .right
        case 2: self = .top
        case 3: self = .bottom
        default: throw InputCodecError.malformed
        }
    }
}

// MARK: - Little-endian byte helpers

struct ByteWriter {
    var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { append(v.littleEndian) }
    mutating func u32(_ v: UInt32) { append(v.littleEndian) }
    mutating func u64(_ v: UInt64) { append(v.littleEndian) }
    mutating func i64(_ v: Int64) { append(v.littleEndian) }
    mutating func f64(_ v: Double) { append(v.bitPattern.littleEndian) }

    mutating func blob(_ d: Data) {
        u32(UInt32(d.count))
        data.append(d)
    }

    private mutating func append<T: FixedWidthInteger>(_ v: T) {
        withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func u8() throws -> UInt8 { try read(UInt8.self) }
    mutating func u16() throws -> UInt16 { UInt16(littleEndian: try read(UInt16.self)) }
    mutating func u32() throws -> UInt32 { UInt32(littleEndian: try read(UInt32.self)) }
    mutating func u64() throws -> UInt64 { UInt64(littleEndian: try read(UInt64.self)) }
    mutating func i64() throws -> Int64 { Int64(littleEndian: try read(Int64.self)) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    /// A finite Double. NaN / ±infinity would poison cursor maths (and crash `ScreenGeometry` lookups),
    /// so they are rejected at the wire boundary.
    mutating func finite() throws -> Double {
        let v = try f64()
        guard v.isFinite else { throw InputCodecError.malformed }
        return v
    }

    mutating func blob() throws -> Data {
        let count = Int(try u32())
        guard count >= 0, offset + count <= data.endIndex else { throw InputCodecError.truncated }
        let d = data.subdata(in: offset..<(offset + count))
        offset += count
        return d
    }

    private mutating func read<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.endIndex else { throw InputCodecError.truncated }
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { dst in
            data.copyBytes(to: dst.bindMemory(to: UInt8.self), from: offset..<(offset + size))
        }
        offset += size
        return value
    }
}
