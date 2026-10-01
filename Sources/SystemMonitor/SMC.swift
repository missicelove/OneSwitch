import Foundation
import IOKit

/// Minimal AppleSMC client (the classic `SMCKeyData_t` user-client protocol, selector 2).
///
/// Not thread-safe: create, use and close it on one serial queue (the monitor's sampler queue).
/// SMC calls are synchronous kernel round trips and must never run on the main thread.
final class SMCClient {
    struct KeyInfo: Hashable, Sendable {
        let size: UInt32
        let type: UInt32
        var typeString: String { SMCClient.string(fromFourCC: type) }
    }

    /// Commands understood by the AppleSMC user client (`data8` field).
    private enum Command: UInt8 {
        case readBytes = 5
        case getKeyFromIndex = 8
        case readKeyInfo = 9
    }

    // Byte layout of the 80-byte SMCKeyData_t struct (C alignment rules):
    //   0 key (UInt32) · 4 vers (6 bytes) · 12 pLimitData (16 bytes)
    //   28 keyInfo.dataSize (UInt32) · 32 keyInfo.dataType (UInt32) · 36 keyInfo.dataAttributes (UInt8)
    //   40 result · 41 status · 42 data8 · 44 data32 (UInt32) · 48 bytes[32]
    static let structSize = 80
    private static let offKey = 0
    private static let offDataSize = 28
    private static let offDataType = 32
    private static let offResult = 40
    private static let offData8 = 42
    private static let offData32 = 44
    private static let offBytes = 48
    private static let maxBytes = 32
    private static let selector: UInt32 = 2

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo?] = [:]
    /// True when the most recent kernel call failed at the transport level (not an SMC error code).
    private var lastCallFailed = false

    /// Opens the AppleSMC user client; nil when unavailable.
    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess, conn != 0 else { return nil }
        connection = conn
    }

    deinit { close() }

    var isOpen: Bool { connection != 0 }

    func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    // MARK: Four-character codes

    static func fourCC(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        let bytes = Array(s.utf8.prefix(4))
        for i in 0..<4 {
            v = (v << 8) | UInt32(i < bytes.count ? bytes[i] : 0x20)
        }
        return v
    }

    static func string(fromFourCC v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Key access

    /// Number of keys exposed by the SMC ("#KEY").
    func keyCount() -> Int? {
        guard let bytes = readRaw("#KEY"), bytes.count >= 4 else { return nil }
        return Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
    }

    /// The key at `index` (0 ..< keyCount).
    func key(at index: Int) -> UInt32? {
        guard let out = call(key: 0, command: .getKeyFromIndex, data32: UInt32(index)) else { return nil }
        return Self.loadUInt32(out, Self.offKey)
    }

    func keyInfo(_ key: UInt32) -> KeyInfo? {
        if let cached = infoCache[key] { return cached }
        var info: KeyInfo?
        if let out = call(key: key, command: .readKeyInfo) {
            let size = Self.loadUInt32(out, Self.offDataSize)
            let type = Self.loadUInt32(out, Self.offDataType)
            if size > 0 && size <= UInt32(Self.maxBytes) { info = KeyInfo(size: size, type: type) }
        }
        // Remember "no such key" answers, but not failed kernel calls (they may succeed later).
        if info != nil || !lastCallFailed { infoCache[key] = info }
        return info
    }

    func keyInfo(_ key: String) -> KeyInfo? { keyInfo(Self.fourCC(key)) }

    /// Raw value bytes of `key` (length = the key's data size).
    func readRaw(_ key: UInt32) -> [UInt8]? {
        guard let info = keyInfo(key) else { return nil }
        guard let out = call(key: key, command: .readBytes, dataSize: info.size) else { return nil }
        return Array(out[Self.offBytes ..< Self.offBytes + Int(info.size)])
    }

    func readRaw(_ key: String) -> [UInt8]? { readRaw(Self.fourCC(key)) }

    /// Numeric value of `key`, decoded according to its SMC data type.
    func readNumber(_ key: UInt32) -> Double? {
        guard let info = keyInfo(key), let bytes = readRaw(key) else { return nil }
        return Self.decode(bytes, type: info.type)
    }

    func readNumber(_ key: String) -> Double? { readNumber(Self.fourCC(key)) }

    /// Enumerates every key, returning those accepted by `filter` together with their info.
    /// Costs two kernel calls per key (~2–3k keys on Apple Silicon); call once and cache the result.
    func enumerateKeys(where filter: (String) -> Bool) -> [(key: UInt32, name: String, info: KeyInfo)] {
        guard let count = keyCount(), count > 0, count < 20_000 else { return [] }
        var result: [(UInt32, String, KeyInfo)] = []
        for i in 0..<count {
            guard let key = key(at: i) else { continue }
            let name = Self.string(fromFourCC: key)
            guard filter(name), let info = keyInfo(key) else { continue }
            result.append((key, name, info))
        }
        return result
    }

    // MARK: Decoding

    /// Decodes SMC value bytes. Apple Silicon floats ('flt ') are little-endian; integer and
    /// fixed-point types are big-endian.
    static func decode(_ b: [UInt8], type: UInt32) -> Double? {
        switch string(fromFourCC: type) {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let v = Double(Float(bitPattern: bits))
            return v.isFinite ? v : nil
        case "ioft":
            // 48.16 fixed point, little-endian (8 bytes).
            guard b.count >= 8 else { return nil }
            var raw: UInt64 = 0
            for i in 0..<8 { raw |= UInt64(b[i]) << (8 * UInt64(i)) }
            return Double(raw) / 65536.0
        case "ui8 ":
            return b.isEmpty ? nil : Double(b[0])
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "si8 ":
            return b.isEmpty ? nil : Double(Int8(bitPattern: b[0]))
        case "si16":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1])))
        case "sp78":
            guard b.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
        case "fpe2":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
        case "fp88":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 256.0
        default:
            return nil
        }
    }

    // MARK: Transport

    private func call(key: UInt32, command: Command, dataSize: UInt32 = 0, data32: UInt32 = 0) -> [UInt8]? {
        lastCallFailed = true
        guard connection != 0 else { return nil }
        var input = [UInt8](repeating: 0, count: Self.structSize)
        var output = [UInt8](repeating: 0, count: Self.structSize)
        Self.storeUInt32(&input, Self.offKey, key)
        Self.storeUInt32(&input, Self.offDataSize, dataSize)
        input[Self.offData8] = command.rawValue
        Self.storeUInt32(&input, Self.offData32, data32)
        var outSize = Self.structSize
        let kr = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(connection, Self.selector,
                                          inPtr.baseAddress, Self.structSize,
                                          outPtr.baseAddress, &outSize)
            }
        }
        guard kr == kIOReturnSuccess else { return nil }
        lastCallFailed = false // the SMC answered (possibly with an error code such as "key not found")
        guard output[Self.offResult] == 0 else { return nil }
        return output
    }

    private static func storeUInt32(_ buf: inout [UInt8], _ offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value) { src in
            for i in 0..<4 { buf[offset + i] = src[i] }
        }
    }

    private static func loadUInt32(_ buf: [UInt8], _ offset: Int) -> UInt32 {
        var v: UInt32 = 0
        withUnsafeMutableBytes(of: &v) { dst in
            for i in 0..<4 { dst[i] = buf[offset + i] }
        }
        return v
    }
}
