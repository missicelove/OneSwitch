import Foundation
import OneSwitchCore

// MARK: - Wire format
//
// Every message on a PeerLink TCP/TLS connection is a frame:
//
//     [UInt32 BE payload length][UInt16 BE type][payload]
//
// Types 0xFF00...0xFFFF are reserved for PeerLink internals (handshake, heartbeat, goodbye) and are
// never surfaced to services. After the transport (TCP + TLS-PSK) is ready, the dialer sends `hello`;
// the acceptor answers `helloAck` (channel established) or `reject` (and closes).

enum WireType {
    static let hello: UInt16 = 0xFF01
    static let helloAck: UInt16 = 0xFF02
    static let reject: UInt16 = 0xFF03
    static let ping: UInt16 = 0xFF10
    static let pong: UInt16 = 0xFF11
    static let goodbye: UInt16 = 0xFF20

    static func isReserved(_ type: UInt16) -> Bool { type > PeerLimits.serviceTypeRange.upperBound }
}

enum Wire {
    static let headerSize = 6
    static let protocolVersion = 1

    static func header(type: UInt16, length: Int) -> Data {
        precondition(length >= 0 && length <= Int(UInt32.max))
        let len = UInt32(length)
        return Data([
            UInt8(truncatingIfNeeded: len >> 24), UInt8(truncatingIfNeeded: len >> 16),
            UInt8(truncatingIfNeeded: len >> 8), UInt8(truncatingIfNeeded: len),
            UInt8(truncatingIfNeeded: type >> 8), UInt8(truncatingIfNeeded: type),
        ])
    }

    /// Header + payload in one contiguous buffer (used for small frames: one send, one TLS record).
    static func frame(type: UInt16, payload: Data) -> Data {
        var data = header(type: type, length: payload.count)
        data.append(payload)
        return data
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        // Encoding plain structs of strings / ints cannot fail.
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

enum FrameDecodingError: Error, Equatable {
    case payloadTooLarge(Int)
}

/// Incremental frame parser. Feed it arbitrary chunks as they arrive from the network; it emits
/// complete frames in order. Oversized frames are rejected as soon as their header is seen.
struct FrameDecoder {
    let maxPayload: Int

    private var header = Data()
    private var bodyType: UInt16 = 0
    private var bodyLength = 0
    private var body: Data?

    init(maxPayload: Int = PeerLimits.maxPayloadSize) {
        self.maxPayload = maxPayload
        header.reserveCapacity(Wire.headerSize)
    }

    /// True while a frame body is partially received.
    var isInsideFrame: Bool { body != nil || !header.isEmpty }

    /// Suggested maximum length for the next `receive` call: the rest of a large body, else 256 KiB.
    var preferredReceiveLength: Int {
        if let body { return max(1, min(bodyLength - body.count, 4 << 20)) }
        return 256 << 10
    }

    mutating func feed(_ chunk: Data, emit: (UInt16, Data) -> Void) throws {
        var pos = chunk.startIndex
        let end = chunk.endIndex
        while pos < end {
            if body != nil {
                let need = bodyLength - body!.count
                let take = min(need, end - pos)
                body!.append(chunk[pos..<(pos + take)])
                pos += take
                if body!.count == bodyLength {
                    let complete = body!
                    body = nil
                    emit(bodyType, complete)
                }
                continue
            }
            let takeHeader = min(Wire.headerSize - header.count, end - pos)
            header.append(chunk[pos..<(pos + takeHeader)])
            pos += takeHeader
            guard header.count == Wire.headerSize else { continue }

            let h = [UInt8](header)
            header.removeAll(keepingCapacity: true)
            let length = Int(UInt32(h[0]) << 24 | UInt32(h[1]) << 16 | UInt32(h[2]) << 8 | UInt32(h[3]))
            let type = UInt16(h[4]) << 8 | UInt16(h[5])
            guard length <= maxPayload else { throw FrameDecodingError.payloadTooLarge(length) }

            if length == 0 {
                emit(type, Data())
            } else if end - pos >= length {
                // Fast path: the whole body is inside this chunk.
                emit(type, Data(chunk[pos..<(pos + length)]))
                pos += length
            } else {
                bodyType = type
                bodyLength = length
                var d = Data()
                d.reserveCapacity(length)
                body = d
            }
        }
    }
}

// MARK: - Handshake messages (JSON payloads of reserved frames)

struct HelloMessage: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var deviceID: String
    var deviceName: String
    var service: String
    /// Random per hub start; lets the acceptor detect that the peer restarted.
    var instanceID: String
    /// Chosen by the dialer; identifies the channel on both sides.
    var channelID: String
    /// The id of the last channel the dialer had for this service (to tell a reconnect from a stale dial).
    var lastChannelID: String?
}

struct HelloAckMessage: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var deviceID: String
    var deviceName: String
    var service: String
    var instanceID: String
    var channelID: String
}

enum RejectReason: String, Codable, Sendable {
    case serviceNotRegistered
    case protocolMismatch
    case duplicate
    case selfConnection
    case busy
    case notThunderbolt
    case shuttingDown
}

struct RejectMessage: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var deviceID: String
    var deviceName: String
    /// Raw `RejectReason`; kept as a string so unknown future reasons still decode.
    var reason: String
    var detail: String?

    var knownReason: RejectReason? { RejectReason(rawValue: reason) }
}

/// Messages on the internal control channel (service `LinkEngine.controlService`).
struct ControlAnnouncement: Codable, Equatable, Sendable {
    static let type: UInt16 = 1
    var services: [String]
    var bridgeAddresses: [String]
    var appVersion: String
}
