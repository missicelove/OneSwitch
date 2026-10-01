import Foundation
import Combine
import os

/// In-memory `PeerHub` pair that behaves like two Macs joined by a cable. For self-checks / tests:
///
/// ```swift
/// let (hubA, hubB) = LoopbackPeerHub.makePair()
/// let engineA = SyncEngine(hub: hubA, ...)   // both register "sync" → a channel pair is formed
/// hubA.setLinked(false)                       // simulate unplugging the cable (closes all channels)
/// hubA.setLinked(true)                        // plug back in → channels re-form
/// ```
///
/// Callers must keep both hubs alive (they reference each other weakly).
@MainActor
public final class LoopbackPeerHub: PeerHub {
    public let localDeviceID: String
    public let localDeviceName: String
    public private(set) var status: PeerLinkStatus = .searching {
        didSet { if status != oldValue { subject.send(status) } }
    }
    public var statusPublisher: AnyPublisher<PeerLinkStatus, Never> { subject.eraseToAnyPublisher() }

    private let subject = CurrentValueSubject<PeerLinkStatus, Never>(.searching)
    private weak var partner: LoopbackPeerHub?
    private var handlers: [String: @MainActor (PeerChannel) -> Void] = [:]
    private var channels: [String: LoopbackChannel] = [:]
    private var linked = true

    public init(deviceID: String, deviceName: String) {
        self.localDeviceID = deviceID
        self.localDeviceName = deviceName
    }

    public static func makePair(nameA: String = "Loopback A", nameB: String = "Loopback B") -> (LoopbackPeerHub, LoopbackPeerHub) {
        let a = LoopbackPeerHub(deviceID: "A-" + UUID().uuidString, deviceName: nameA)
        let b = LoopbackPeerHub(deviceID: "B-" + UUID().uuidString, deviceName: nameB)
        a.partner = b
        b.partner = a
        a.refreshStatus()
        b.refreshStatus()
        return (a, b)
    }

    public var peerInfo: PeerInfo {
        PeerInfo(deviceID: localDeviceID, name: localDeviceName, address: "127.0.0.1", viaThunderbolt: false)
    }

    public func register(service: String, onChannel: @escaping @MainActor (PeerChannel) -> Void) {
        handlers[service] = onChannel
        connectIfPossible(service)
    }

    public func unregister(service: String) {
        handlers[service] = nil
        if let ch = channels.removeValue(forKey: service) { ch.close() }
        partner?.channels[service] = nil
    }

    /// Simulates plugging (true) / unplugging (false) the cable. Applies to both hubs.
    public func setLinked(_ isLinked: Bool) {
        guard let partner else { return }
        linked = isLinked
        partner.linked = isLinked
        if !isLinked {
            for ch in channels.values { ch.fail(PeerLinkError.network("cable unplugged")) }
            channels.removeAll()
            partner.channels.removeAll()
        }
        refreshStatus()
        partner.refreshStatus()
        if isLinked {
            for service in handlers.keys { connectIfPossible(service) }
        }
    }

    private func refreshStatus() {
        if linked, let partner {
            status = .connected(partner.peerInfo)
        } else {
            status = .searching
        }
    }

    private func connectIfPossible(_ service: String) {
        guard linked, let partner, partner.linked,
              handlers[service] != nil, partner.handlers[service] != nil else { return }
        if let existing = channels[service], existing.isOpen { existing.close() }
        let (mine, theirs) = LoopbackChannel.makePair(service: service,
                                                       localInfoA: peerInfo, localInfoB: partner.peerInfo)
        channels[service] = mine
        partner.channels[service] = theirs
        // Hand out asynchronously, like a real network handshake would.
        DispatchQueue.main.async { [weak self, weak partner] in
            MainActor.assumeIsolated {
                if let h = self?.handlers[service], mine.isOpen { h(mine) }
                if let h = partner?.handlers[service], theirs.isOpen { h(theirs) }
            }
        }
    }
}

/// One end of an in-memory channel pair.
public final class LoopbackChannel: PeerChannel, @unchecked Sendable {
    public let service: String
    public let peer: PeerInfo

    private struct State {
        var other: LoopbackChannel?
        var queue: DispatchQueue?
        var onMessage: (@Sendable (UInt16, Data) -> Void)?
        var onClose: (@Sendable (Error?) -> Void)?
        var pending: [(UInt16, Data)] = []
        var closed = false
        var closeError: Error?
        var closeDelivered = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private init(service: String, peer: PeerInfo) {
        self.service = service
        self.peer = peer
    }

    /// `localInfoA` describes side A (so it becomes B's `peer`) and vice versa.
    static func makePair(service: String, localInfoA: PeerInfo, localInfoB: PeerInfo) -> (LoopbackChannel, LoopbackChannel) {
        let a = LoopbackChannel(service: service, peer: localInfoB)
        let b = LoopbackChannel(service: service, peer: localInfoA)
        a.state.withLock { $0.other = b }
        b.state.withLock { $0.other = a }
        return (a, b)
    }

    public var isOpen: Bool { state.withLock { !$0.closed } }

    public func setHandlers(queue: DispatchQueue,
                            onMessage: @escaping @Sendable (UInt16, Data) -> Void,
                            onClose: @escaping @Sendable (Error?) -> Void) {
        let (pending, deliverClose, closeError): ([(UInt16, Data)], Bool, Error?) = state.withLock { st in
            st.queue = queue
            st.onMessage = onMessage
            st.onClose = onClose
            let p = st.pending
            st.pending.removeAll()
            let dc = st.closed && !st.closeDelivered
            if dc { st.closeDelivered = true }
            return (p, dc, st.closeError)
        }
        for (t, d) in pending { queue.async { onMessage(t, d) } }
        if deliverClose { queue.async { onClose(closeError) } }
    }

    public func send(type: UInt16, payload: Data, completion: (@Sendable (Error?) -> Void)?) {
        if payload.count > PeerLimits.maxPayloadSize {
            DispatchQueue.global().async { completion?(PeerLinkError.payloadTooLarge(payload.count)) }
            return
        }
        let other: LoopbackChannel? = state.withLock { $0.closed ? nil : $0.other }
        guard let other else {
            DispatchQueue.global().async { completion?(PeerLinkError.closed) }
            return
        }
        other.receive(type: type, payload: payload)
        if let completion { DispatchQueue.global().async { completion(nil) } }
    }

    private func receive(type: UInt16, payload: Data) {
        let target: (DispatchQueue, @Sendable (UInt16, Data) -> Void)? = state.withLock { st in
            if st.closed { return nil }
            if let q = st.queue, let h = st.onMessage { return (q, h) }
            st.pending.append((type, payload))
            return nil
        }
        if let (q, h) = target { q.async { h(type, payload) } }
    }

    public func close() {
        closeInternal(error: nil, propagateError: PeerLinkError.closedByPeer)
    }

    /// Abrupt failure on both ends (e.g. cable unplugged).
    func fail(_ error: Error) {
        closeInternal(error: error, propagateError: error)
    }

    private func closeInternal(error: Error?, propagateError: Error?) {
        let (other, delivery): (LoopbackChannel?, (DispatchQueue, @Sendable (Error?) -> Void)?) = state.withLock { st in
            guard !st.closed else { return (nil, nil) }
            st.closed = true
            st.closeError = error
            let o = st.other
            st.other = nil
            if let q = st.queue, let h = st.onClose, !st.closeDelivered {
                st.closeDelivered = true
                return (o, (q, h))
            }
            return (o, nil)
        }
        if let (q, h) = delivery { q.async { h(error) } }
        other?.closeInternal(error: propagateError, propagateError: nil)
    }
}
