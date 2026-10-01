import Foundation
import OneSwitchCore

/// State of one channel to the peer (reset on every reconnect).
final class PeerSession {
    let channel: PeerChannel
    let generation: Int
    var helloReceived = false
    var incompatible = false
    var deviceID = ""
    var name = ""
    var peerFolders: [String: SyncProtocol.Folder] = [:]
    var peerFolderOrder: [String] = []
    /// Folders both sides have configured.
    var shared = Set<String>()
    /// Highest local sequence already sent per folder.
    var sentSeq: [String: Int64] = [:]
    /// Folders whose next index batch must tell the peer to drop what it has.
    var resetPending = Set<String>()
    var indexSending = Set<String>()
    var indexResend = Set<String>()
    /// Folders whose initial index exchange we completed (sent "last").
    var initialSent = Set<String>()
    /// Folders whose initial index exchange the peer completed.
    var initialReceived = Set<String>()
    /// Folders whose last index batch from the peer announced further batches ("more").
    var indexIncomplete = Set<String>()
    /// The peer marks its index batches with "more" (hello): a batch without it completes the peer's index.
    var peerAnnouncesMore = false

    // Pulling
    var nextRequestID: UInt64 = 1
    var requests: [UInt64: PendingRequest] = [:]
    var outstandingBytes = 0

    // Serving
    var serveQueue: [ServeItem] = []
    var serveHead = 0
    var serveInFlight = 0

    init(channel: PeerChannel, generation: Int) {
        self.channel = channel
        self.generation = generation
    }

    func popServe() -> ServeItem? {
        guard serveHead < serveQueue.count else {
            serveQueue.removeAll(keepingCapacity: true)
            serveHead = 0
            return nil
        }
        let item = serveQueue[serveHead]
        serveHead += 1
        if serveHead > 256 && serveHead * 2 > serveQueue.count {
            serveQueue.removeFirst(serveHead)
            serveHead = 0
        }
        return item
    }
}

struct PendingRequest {
    let key: PullKey
    let offset: Int64
    let length: Int
}

struct ServeItem {
    let requestID: UInt64
    let absolutePath: String
    let offset: Int64
    let length: Int
    let size: Int64
    let mtimeNS: Int64
}

extension SyncEngine {
    // MARK: - Channel lifecycle

    /// Called by the hub on the main actor.
    func channelOpened(_ channel: PeerChannel) {
        queue.async { self.attach(channel) }
    }

    private func attach(_ channel: PeerChannel) {
        // While a rebuild of a damaged index is pending (the owner restarts the engine), stay offline.
        guard !stopped, !indexRebuildRequested else {
            channel.close()
            return
        }
        if let old = session {
            session = nil
            old.channel.close()
            endSession(old)
        }
        generation += 1
        let gen = generation
        let s = PeerSession(channel: channel, generation: gen)
        session = s
        channel.setHandlers(queue: queue, onMessage: { [weak self] type, payload in
            self?.receive(generation: gen, type: type, payload: payload)
        }, onClose: { [weak self] error in
            self?.channelClosed(generation: gen, error: error)
        })
        AppLogSync.info("channel open to \(channel.peer.name) (\(channel.peer.address ?? "?"))")
        let hello = SyncProtocol.Hello(v: SyncProtocol.version, device: deviceID, name: deviceName,
                                       folders: folderAnnouncements(), more: options.testOmitMoreFlag ? nil : true)
        if let payload = SyncProtocol.encode(hello) { send(.hello, payload) }
        markDirty()
    }

    private func channelClosed(generation gen: Int, error: Error?) {
        guard let s = session, s.generation == gen else { return }
        session = nil
        endSession(s)
        AppLogSync.info("channel closed\(error.map { ": \($0.localizedDescription)" } ?? "")")
        markDirty()
    }

    /// Abandons in-flight pulls cleanly; they resume after the next index exchange.
    func endSession(_ s: PeerSession) {
        for job in Array(activeJobs.values) { abortJob(job, block: nil) }
        pullQueue.removeAll()
        s.requests.removeAll()
        s.outstandingBytes = 0
        s.serveQueue.removeAll()
        s.serveHead = 0
        for rt in folders.values {
            rt.deferredDirDeletes.removeAll()
            discardPreparedClones(rt)
        }
    }

    func send(_ type: SyncProtocol.MessageType, _ payload: Data, completion: (@Sendable (Error?) -> Void)? = nil) {
        guard let s = session else {
            completion?(PeerLinkError.notConnected)
            return
        }
        stats.messagesSent += 1
        s.channel.send(type: type.rawValue, payload: payload, completion: completion)
    }

    private func receive(generation gen: Int, type: UInt16, payload: Data) {
        guard !stopped, let s = session, s.generation == gen else { return }
        stats.messagesReceived += 1
        guard let messageType = SyncProtocol.MessageType(rawValue: type) else {
            AppLogSync.debug("ignoring unknown message type \(type)")
            return
        }
        if messageType != .hello && !s.helloReceived { return }
        if s.incompatible { return }
        switch messageType {
        case .hello:
            if let hello = SyncProtocol.decode(SyncProtocol.Hello.self, payload) { handleHello(s, hello) }
        case .folders:
            if let msg = SyncProtocol.decode(SyncProtocol.Folders.self, payload) { updatePeerFolders(s, msg.folders) }
        case .index:
            if let msg = SyncProtocol.decode(SyncProtocol.Index.self, payload) { handleIndex(s, msg) }
        case .blockRequest:
            if let req = SyncProtocol.decode(SyncProtocol.BlockRequest.self, payload) { handleBlockRequest(s, req) }
        case .blockResponse:
            handleBlockResponse(s, payload)
        }
    }

    // MARK: - Hello / folder lists

    func folderAnnouncements() -> [SyncProtocol.Folder] {
        folderOrder.compactMap { id in
            guard let rt = folders[id] else { return nil }
            return SyncProtocol.Folder(id: id, label: rt.config.label, paused: isPaused(rt) ? true : nil,
                                       haveIndex: rt.remoteIndexID == 0 ? nil : rt.remoteIndexID,
                                       haveSeq: rt.remoteIndexID == 0 ? nil : rt.remoteMaxSeq)
        }
    }

    /// Tells the peer about our folder list (after add / remove / pause changes).
    func announceFolders() {
        guard let s = session, !stopped else { return }
        if let payload = SyncProtocol.encode(SyncProtocol.Folders(folders: folderAnnouncements())) {
            send(.folders, payload)
        }
        if s.helloReceived { updatePeerFolders(s, s.peerFolderOrder.compactMap { s.peerFolders[$0] }) }
    }

    private func handleHello(_ s: PeerSession, _ hello: SyncProtocol.Hello) {
        guard hello.v == SyncProtocol.version else {
            AppLogSync.error("peer speaks sync protocol v\(hello.v), we speak v\(SyncProtocol.version)")
            s.incompatible = true
            for rt in folders.values where rt.error == nil { rt.issues[""] = "对方的 OneSwitch 版本不兼容，请将两台 Mac 更新到相同版本" }
            markDirty()
            return
        }
        guard let store else { return }
        guard hello.device != deviceID else {
            // Both Macs claim the same identity (e.g. settings cloned by Migration Assistant): version
            // vectors would collide, so refuse to sync rather than corrupt data.
            AppLogSync.error("peer uses our own device id \(deviceID); refusing to sync")
            s.incompatible = true
            for rt in folders.values { rt.issues[""] = "两台 Mac 的设备标识相同（可能是迁移助理复制了设置），无法同步。请在其中一台上重新配对。" }
            markDirty()
            return
        }
        if store.meta("peer.device") != hello.device {
            // A different Mac than the one whose index we stored: forget its index.
            if store.meta("peer.device") != nil { AppLogSync.info("peer changed to \(hello.name); dropping stored remote index") }
            store.batch {
                store.clearAll(.remote)
                store.deleteMeta(prefix: "remote.")
                store.setMeta("peer.device", hello.device)
            }
            for rt in folders.values {
                rt.remoteIndexID = 0
                rt.remoteMaxSeq = 0
            }
        }
        for rt in folders.values { rt.issues[""] = nil }
        s.deviceID = hello.device
        s.name = hello.name
        s.peerAnnouncesMore = hello.more == true
        s.helloReceived = true
        AppLogSync.info("hello from \(hello.name): \(hello.folders.count) folders")
        updatePeerFolders(s, hello.folders)
        markDirty()
    }

    func updatePeerFolders(_ s: PeerSession, _ list: [SyncProtocol.Folder]) {
        let old = s.peerFolders
        var dict: [String: SyncProtocol.Folder] = [:]
        var order: [String] = []
        for f in list where dict[f.id] == nil {
            guard SyncProtocol.isValidFolderID(f.id) else {
                AppLogSync.warning("ignoring peer folder with invalid id \(f.id.debugDescription)")
                continue
            }
            dict[f.id] = f
            order.append(f.id)
        }
        s.peerFolders = dict
        s.peerFolderOrder = order
        for (id, rt) in folders {
            let isShared = dict[id] != nil
            let wasShared = s.shared.contains(id)
            if isShared && !wasShared {
                s.shared.insert(id)
                let pf = dict[id]!
                // The peer already holds our index up to `haveSeq`. If that is beyond our own sequence, our
                // database was restored / rolled back: our next records would reuse sequence numbers the
                // peer believes it has, so they would never be sent. Resend everything instead.
                if pf.haveIndex == rt.indexID, let seq = pf.haveSeq, seq <= rt.sequence {
                    s.sentSeq[id] = seq
                } else {
                    if pf.haveIndex == rt.indexID, let seq = pf.haveSeq {
                        AppLogSync.warning("peer has seen sequence \(seq) of \(id) but ours is \(rt.sequence); resending the full index")
                    }
                    s.sentSeq[id] = 0
                    s.resetPending.insert(id)
                }
                s.initialSent.remove(id)
                sendIndex(rt)
            } else if !isShared && wasShared {
                s.shared.remove(id)
                s.initialReceived.remove(id)
                s.initialSent.remove(id)
                s.indexIncomplete.remove(id)
                s.sentSeq[id] = nil
                cancelPulls(folderID: id)
            } else if isShared, (old[id]?.paused ?? false), !(dict[id]?.paused ?? false) {
                // The peer resumed this folder: retry what it could not serve while paused.
                evaluate(rt, paths: nil)
            }
        }
        markDirty()
    }

    // MARK: - Index exchange

    func isReadyToAnnounce(_ rt: FolderRuntime) -> Bool {
        rt.active && rt.initialScanDone && rt.error == nil && !isPaused(rt)
    }

    /// Sends local records newer than what the peer has, in batches, paced by send completions.
    func sendIndex(_ rt: FolderRuntime) {
        guard let store, let s = session, s.helloReceived, !s.incompatible else { return }
        let id = rt.config.id
        guard s.shared.contains(id), isReadyToAnnounce(rt) else { return }
        if s.indexSending.contains(id) {
            s.indexResend.insert(id)
            return
        }
        let after = s.sentSeq[id] ?? 0
        let limit = max(1, options.indexBatchSize)
        // One record more than a batch holds tells whether further batches follow ("more"): the peer then
        // knows a change spanning several batches (a large rename or deletion) is still incomplete.
        var records = store.records(.local, folder: id, afterSequence: after, limit: limit + 1)
        var more = records.count > limit
        if more { records.removeLast() }
        let announceMore = !options.testOmitMoreFlag
        let reset = s.resetPending.contains(id)
        if records.isEmpty {
            if !s.initialSent.contains(id) || reset {
                let msg = SyncProtocol.Index(folder: id, indexID: rt.indexID, reset: reset ? true : nil, last: true, records: [])
                if let payload = SyncProtocol.encode(msg) { send(.index, payload) }
                s.initialSent.insert(id)
                s.resetPending.remove(id)
            }
            return
        }
        // A batch must fit one message (16 MiB). 2 000 ordinary records are far below that, but long paths
        // full of escaped characters are not: halve the batch until it fits (a failed send would silently
        // skip these records, since `sentSeq` advances past them).
        var payload: Data?
        while true {
            let msg = SyncProtocol.Index(folder: id, indexID: rt.indexID, reset: reset ? true : nil, last: nil,
                                         more: more && announceMore ? true : nil, records: records.map(SyncProtocol.Record.init))
            payload = SyncProtocol.encode(msg)
            guard let p = payload, p.count > PeerLimits.maxPayloadSize, records.count > 1 else { break }
            records = Array(records.prefix(records.count / 2))
            more = true
        }
        guard let payload, payload.count <= PeerLimits.maxPayloadSize else {
            AppLogSync.error("index record \(records.first?.path ?? "?") of \(id) does not fit in one message")
            return
        }
        s.resetPending.remove(id)
        s.sentSeq[id] = records.last!.sequence
        s.indexSending.insert(id)
        stats.indexRecordsSent += records.count
        let gen = s.generation
        send(.index, payload) { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard let s = self.session, s.generation == gen else { return }
                s.indexSending.remove(id)
                s.indexResend.remove(id)
                guard error == nil, let rt = self.folders[id] else { return }
                self.sendIndex(rt) // next batch (or "last" / nothing)
            }
        }
    }

    /// Debounced push of local changes to the peer.
    func scheduleIndexFlush() {
        guard !indexFlushScheduled, !stopped else { return }
        indexFlushScheduled = true
        queue.asyncAfter(deadline: .now() + options.indexDebounce) { [weak self] in
            guard let self else { return }
            self.indexFlushScheduled = false
            guard !self.stopped else { return }
            for id in self.folderOrder {
                if let rt = self.folders[id] { self.sendIndex(rt) }
            }
        }
    }

    private func handleIndex(_ s: PeerSession, _ msg: SyncProtocol.Index) {
        guard let store, let rt = folders[msg.folder] else { return }
        let id = msg.folder
        var paths: [String] = []
        paths.reserveCapacity(msg.records.count)
        var invalid = 0
        store.batch {
            if msg.reset == true || rt.remoteIndexID != msg.indexID {
                store.clear(.remote, folder: id)
                rt.remoteMaxSeq = 0
                rt.remoteIndexID = msg.indexID
            }
            for wire in msg.records {
                guard let record = wire.toRecord() else {
                    invalid += 1
                    continue
                }
                store.upsert(.remote, folder: id, record)
                rt.remoteMaxSeq = max(rt.remoteMaxSeq, record.sequence)
                paths.append(record.path)
            }
            store.setMeta("remote.\(id).indexID", String(rt.remoteIndexID))
            store.setMeta("remote.\(id).maxSeq", String(rt.remoteMaxSeq))
        }
        if invalid > 0 { AppLogSync.warning("ignored \(invalid) malformed / unsafe index records for \(id)") }
        stats.indexRecordsReceived += msg.records.count
        // Directory deletions whose children's records may still be on the way wait for this (see
        // `remoteIndexSettled`).
        rt.lastRemoteIndexAt = ProcessInfo.processInfo.systemUptime
        if msg.more == true {
            s.indexIncomplete.insert(id)
        } else {
            s.indexIncomplete.remove(id)
        }
        if msg.last == true {
            let first = !s.initialReceived.contains(id)
            s.initialReceived.insert(id)
            if first { AppLogSync.info("initial index of \(id) from \(s.name): \(store.count(.remote, folder: id)) records") }
            evaluate(rt, paths: nil)
        } else if s.initialReceived.contains(id) {
            evaluate(rt, paths: paths)
        }
        markDirty()
    }
}
