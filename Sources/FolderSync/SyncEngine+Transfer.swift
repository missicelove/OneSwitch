import Foundation
import CryptoKit
import OneSwitchCore

struct PullKey: Hashable {
    let folder: String
    let path: String
}

/// FIFO of files to pull, with O(1) membership / removal (lazy deletion) and lookup by content hash.
struct PullQueue {
    private var order: [PullKey] = []
    private var head = 0
    private var sizes: [PullKey: Int64] = [:]
    /// Content hash of each queued file, and the queued files by content: a deletion of local content that
    /// queued pulls want (the old paths of a rename spanning several index batches) clones it for them first.
    private var hashes: [PullKey: Data] = [:]
    private var byHash: [Data: Set<PullKey>] = [:]

    var isEmpty: Bool { sizes.isEmpty }
    var count: Int { sizes.count }
    var items: [PullKey: Int64] { sizes }

    func contains(_ key: PullKey) -> Bool { sizes[key] != nil }

    /// Queued files whose content has this hash.
    func keys(withHash hash: Data) -> Set<PullKey> { byHash[hash] ?? [] }

    mutating func append(_ key: PullKey, size: Int64, hash: Data?) {
        if sizes[key] == nil { order.append(key) }
        sizes[key] = size
        forgetHash(key)
        if let hash {
            hashes[key] = hash
            byHash[hash, default: []].insert(key)
        }
    }

    mutating func popFirst() -> PullKey? {
        while head < order.count {
            let key = order[head]
            head += 1
            if sizes.removeValue(forKey: key) != nil {
                forgetHash(key)
                compact()
                return key
            }
        }
        order.removeAll(keepingCapacity: true)
        head = 0
        return nil
    }

    mutating func remove(_ key: PullKey) {
        sizes[key] = nil
        forgetHash(key)
    }

    mutating func removeAll(folder: String) {
        sizes = sizes.filter { $0.key.folder != folder }
        hashes = hashes.filter { $0.key.folder != folder }
        byHash = byHash.compactMapValues { keys in
            let rest = keys.filter { $0.folder != folder }
            return rest.isEmpty ? nil : rest
        }
    }

    mutating func removeAll() {
        order.removeAll()
        sizes.removeAll()
        hashes.removeAll()
        byHash.removeAll()
        head = 0
    }

    private mutating func forgetHash(_ key: PullKey) {
        guard let hash = hashes.removeValue(forKey: key) else { return }
        byHash[hash]?.remove(key)
        if byHash[hash]?.isEmpty == true { byHash[hash] = nil }
    }

    private mutating func compact() {
        if head > 1024 && head * 2 > order.count {
            order.removeFirst(head)
            head = 0
        }
    }
}

/// One file being pulled. Engine-queue state; the file itself is written by `writer` on its own queue.
final class PullJob {
    let key: PullKey
    let remote: FileRecord
    let hashHex: String
    let tempPath: String
    let writer: BlockWriter
    let generation: Int
    let epoch: Int
    var nextOffset: Int64 = 0
    var outstanding = Set<UInt64>()
    var received: Int64 = 0
    var lastActivity = Date()
    /// False for jobs that need no blocks from the peer (local clone being verified, empty file).
    var streaming = true

    init(key: PullKey, remote: FileRecord, tempPath: String, writer: BlockWriter, generation: Int, epoch: Int) {
        self.key = key
        self.remote = remote
        self.hashHex = remote.hash.map(Hex.encode) ?? ""
        self.tempPath = tempPath
        self.writer = writer
        self.generation = generation
        self.epoch = epoch
    }
}

/// Writes blocks of one temp file (any order) and hashes them in order. All methods run on `queue`.
final class BlockWriter: @unchecked Sendable {
    enum Result {
        case done(digest: Data)
        /// errno of the failing call (0 = size / content mismatch, ECANCELED = engine stopping).
        case failed(Int32)
    }

    let queue: DispatchQueue
    private let cancel: AtomicFlag
    private let path: String
    private let size: Int64
    private let mtimeNS: Int64
    private let mode: UInt32
    private var fd: Int32 = -1
    private var hasher = SHA256()
    private var hashedOffset: Int64 = 0
    private var pending: [Int64: Data] = [:]
    private var closed = false

    init(path: String, size: Int64, mtimeNS: Int64, mode: UInt32, target: DispatchQueue, cancel: AtomicFlag) {
        self.cancel = cancel
        self.path = path
        self.size = size
        self.mtimeNS = mtimeNS
        self.mode = mode
        self.queue = DispatchQueue(label: "oneswitch.sync.writer", target: target)
    }

    /// Creates the temp file (exclusive). Returns an error message on failure.
    func open() -> String? {
        fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if fd < 0 { return FS.errorString(errno) }
        return nil
    }

    /// Writes one block; returns non-nil once the file is complete (or failed).
    func write(offset: Int64, data: Data) -> Result? {
        guard !closed, fd >= 0 else { return nil }
        guard FS.writeAll(fd: fd, data: data, offset: offset) else {
            let code = errno
            abort()
            return .failed(code)
        }
        pending[offset] = data
        while let chunk = pending.removeValue(forKey: hashedOffset) {
            chunk.withUnsafeBytes { hasher.update(bufferPointer: $0) }
            hashedOffset += Int64(chunk.count)
        }
        return hashedOffset >= size ? finish() : nil
    }

    /// Completes a file that needs no data (empty file).
    func finishEmpty() -> Result {
        finish()
    }

    /// Verifies an already materialized temp file (local clone) and applies metadata.
    func verifyExisting() -> Result {
        do {
            guard let (digest, bytes) = try FS.sha256(path: path, cancelled: { cancel.isSet }) else {
                return .failed(ECANCELED)
            }
            guard bytes == size else { return .failed(0) }
            chmod(path, mode_t(mode))
            FS.setModificationTime(path, ns: mtimeNS)
            closed = true
            return .done(digest: digest)
        } catch let e as FS.HashError {
            return .failed(e.code)
        } catch {
            return .failed(EIO)
        }
    }

    private func finish() -> Result {
        let digest = Data(hasher.finalize())
        fchmod(fd, mode_t(mode))
        _ = FS.setModificationTime(fd: fd, ns: mtimeNS)
        close(fd)
        fd = -1
        closed = true
        pending.removeAll()
        return .done(digest: digest)
    }

    /// Closes and deletes the temp file (idempotent).
    func abort() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        pending.removeAll()
        if !closed || FS.exists(path) { unlink(path) }
        closed = true
    }
}

extension SyncEngine {
    // MARK: - Pull scheduling

    /// Starts queued pulls while there is capacity.
    func startPulls() {
        guard !stopped, let s = session, s.helloReceived else { return }
        refillRequests(first: nil) // running transfers first
        while activeJobs.count < options.maxActiveFiles, s.outstandingBytes + bufferedWriteBytes < options.maxOutstandingBytes,
              let key = pullQueue.popFirst() {
            startJob(key)
        }
    }

    func cancelPulls(folderID: String) {
        pullQueue.removeAll(folder: folderID)
        for job in Array(activeJobs.values) where job.key.folder == folderID { abortJob(job, block: nil) }
        if let rt = folders[folderID] { discardPreparedClones(rt) }
    }

    private func startJob(_ key: PullKey) {
        guard let store, let s = session, let rt = folders[key.folder] else { return }
        let prepared = rt.preparedClones.removeValue(forKey: key.path)
        var handedOff = false
        defer { if !handedOff, let prepared { unlink(prepared.temp) } }
        guard canApply(rt) else { return }
        guard let remote = store.record(.remote, folder: key.folder, path: key.path), remote.isLive,
              remote.kind == .file, let hash = remote.hash, !rt.matcher.isIgnored(key.path) else { return }
        var local = store.record(.local, folder: key.folder, path: key.path)
        guard case .apply(_, let conflict) = decideNow(rt, local: local, remote: remote) else { return }
        if conflict, let l = local {
            // Local content changed after the decision and loses: preserve it first.
            guard makeConflictCopy(rt, l) else { return }
            local = store.record(.local, folder: key.folder, path: key.path)
        }
        let localAbsent = local == nil || local!.deleted
        if localAbsent && hasCaseConflict(rt, key.path) { return }
        let parent = rt.absolute(SyncPath.parent(key.path))
        guard pathIsSafe(rt, key.path) else {
            block(rt, key.path, .obstructed)
            return
        }
        guard ensureParentDirectories(rt, key.path) else {
            block(rt, key.path, .ioError)
            return
        }
        let mode = remote.mode == 0 ? 0o644 : remote.mode
        func makeJob(temp: String) -> PullJob {
            let writer = BlockWriter(path: temp, size: remote.size, mtimeNS: remote.mtimeNS, mode: mode,
                                     target: writeTargetQueue, cancel: cancelFlag)
            return PullJob(key: key, remote: remote, tempPath: temp, writer: writer, generation: s.generation, epoch: rt.epoch)
        }

        // Identical content already in this folder (a rename, a duplicate): clone it instead of transferring.
        var cloned: String?
        if let prepared, prepared.hash == hash {
            cloned = prepared.temp
            handedOff = true
        } else if remote.size > 0, let source = cloneSource(rt, hash: hash, size: remote.size) {
            let temp = parent + "/" + SyncPath.tempName(for: SyncPath.name(key.path))
            if clonefile(source, temp, UInt32(CLONE_NOFOLLOW)) == 0 { cloned = temp }
        }
        if let cloned {
            let job = makeJob(temp: cloned)
            job.streaming = false
            activeJobs[key] = job
            stats.filesClonedLocally += 1
            let writer = job.writer
            let delay = options.testVerifyDelay
            writer.queue.async { [weak self] in
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                let result = writer.verifyExisting()
                self?.queue.async { self?.writerFinished(job, result) }
            }
            return
        }
        let job = makeJob(temp: parent + "/" + SyncPath.tempName(for: SyncPath.name(key.path)))
        let writer = job.writer
        if let error = writer.queue.sync(execute: { writer.open() }) {
            AppLogSync.error("cannot create temp file for \(key.path): \(error)")
            block(rt, key.path, .ioError)
            return
        }
        activeJobs[key] = job
        if remote.size == 0 {
            job.streaming = false
            writer.queue.async { [weak self] in
                let result = writer.finishEmpty()
                self?.queue.async { self?.writerFinished(job, result) }
            }
            return
        }
        requestMore(job)
    }

    /// Keeps up to `requestWindow` block requests outstanding for `job` (bounded globally).
    private func requestMore(_ job: PullJob) {
        guard job.streaming, let s = session, s.generation == job.generation, activeJobs[job.key] === job else { return }
        while job.outstanding.count < options.requestWindow, job.nextOffset < job.remote.size,
              s.outstandingBytes + bufferedWriteBytes < options.maxOutstandingBytes {
            let length = Int(min(Int64(options.blockSize), job.remote.size - job.nextOffset))
            let id = s.nextRequestID
            s.nextRequestID += 1
            let req = SyncProtocol.BlockRequest(id: id, folder: job.key.folder, path: job.key.path,
                                                hash: job.hashHex, offset: job.nextOffset, length: length)
            guard let payload = SyncProtocol.encode(req) else { return }
            s.requests[id] = PendingRequest(key: job.key, offset: job.nextOffset, length: length)
            s.outstandingBytes += length
            job.outstanding.insert(id)
            job.nextOffset += Int64(length)
            send(.blockRequest, payload)
        }
    }

    func handleBlockResponse(_ s: PeerSession, _ payload: Data) {
        guard let (id, status, data) = SyncProtocol.parseBlockResponse(payload) else {
            AppLogSync.warning("malformed block response")
            return
        }
        guard let req = s.requests.removeValue(forKey: id) else { return }
        s.outstandingBytes -= req.length
        defer { startPulls() }
        guard let job = activeJobs[req.key], job.outstanding.remove(id) != nil else { return }
        job.lastActivity = Date()
        guard status == .ok, data.count == req.length else {
            AppLogSync.info("peer could not serve \(req.key.path) (\(status)); waiting for its next index update")
            abortJob(job, block: .remoteUnavailable)
            return
        }
        stats.blockBytesReceived += Int64(data.count)
        job.received += Int64(data.count)
        if let rt = folders[req.key.folder] {
            rt.rate.add(data.count)
            rt.burstDone += Int64(data.count)
        }
        let writer = job.writer
        let offset = req.offset
        // Received bytes stay accounted against `maxOutstandingBytes` until they are on disk, so a slow
        // destination disk (external HDD) throttles requests instead of piling blocks up in memory.
        let bytes = data.count
        bufferedWriteBytes += bytes
        stats.peakBufferedBytes = max(stats.peakBufferedBytes, s.outstandingBytes + bufferedWriteBytes)
        let delay = options.testWriteDelay
        writer.queue.async { [weak self] in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let result = writer.write(offset: offset, data: data)
            guard let self else { return }
            self.queue.async { self.blockWritten(job, bytes: bytes, result: result) }
        }
        refillRequests(first: job)
        markDirty()
    }

    private func blockWritten(_ job: PullJob, bytes: Int, result: BlockWriter.Result?) {
        bufferedWriteBytes -= bytes
        if let result {
            writerFinished(job, result)
            return
        }
        guard !stopped else { return }
        refillRequests(first: job)
        startPulls()
    }

    /// Tops up block requests after capacity was freed: `first` gets priority, then every streaming job
    /// left without requests in flight (it was throttled by the global bound and would otherwise stall).
    private func refillRequests(first job: PullJob?) {
        if let job { requestMore(job) }
        for other in activeJobs.values where other.outstanding.isEmpty && other !== job {
            requestMore(other)
        }
    }

    private func writerFinished(_ job: PullJob, _ result: BlockWriter.Result) {
        guard !stopped, activeJobs[job.key] === job else { return }
        switch result {
        case .failed(let code):
            AppLogSync.error("writing \(job.key.path) failed: \(code == 0 ? "content mismatch" : FS.errorString(code))")
            abortJob(job, block: .ioError)
            if code != 0, code != ECANCELED, let rt = folders[job.key.folder] {
                rt.issues[job.key.path] = "无法写入「\(job.key.path)」：\(FS.localizedError(code))"
            }
            startPulls()
        case .done(let digest):
            finalize(job, digest: digest)
        }
    }

    /// Verifies, re-checks the destination, and atomically renames the temp file into place.
    private func finalize(_ job: PullJob, digest: Data) {
        activeJobs[job.key] = nil
        defer {
            // A directory whose removal waited for this transfer may be free now.
            if let rt = folders[job.key.folder], !rt.deferredDirDeletes.isEmpty { processDeferredDirectories(rt) }
            startPulls()
            markDirty()
        }
        let path = job.key.path
        guard let store, let rt = folders[job.key.folder], rt.epoch == job.epoch, rt.active else {
            unlink(job.tempPath)
            return
        }
        guard digest == job.remote.hash else {
            AppLogSync.warning("hash mismatch for \(path); waiting for the peer's next index update")
            unlink(job.tempPath)
            block(rt, path, .verifyFailed)
            return
        }
        // Decide again with the current local record: a local edit indexed during the transfer either
        // wins (drop the download) or loses (preserve it as a conflict copy first).
        var local = store.record(.local, folder: rt.config.id, path: path)
        switch decideNow(rt, local: local, remote: job.remote) {
        case .apply(_, false):
            break
        case .apply(_, true):
            guard let l = local, makeConflictCopy(rt, l) else {
                unlink(job.tempPath)
                return
            }
            local = store.record(.local, folder: rt.config.id, path: path)
        default:
            unlink(job.tempPath)
            evaluate(rt, paths: [path])
            return
        }
        guard canApply(rt), pathIsSafe(rt, path), let destination = prepareDestination(rt, path: path, local: local, remote: job.remote) else {
            unlink(job.tempPath)
            return
        }
        // A directory held here may just have been moved aside as a conflict copy.
        local = store.record(.local, folder: rt.config.id, path: path)
        let abs = rt.absolute(path)
        guard moveIntoPlace(rt, temp: job.tempPath, path: path, destination) else { return }
        guard let disk = FS.entry(abs), disk.kind == .file else { return }
        var rec = FileRecord(path: path, kind: .file, size: disk.size, mtimeNS: disk.mtimeNS, mode: disk.mode, hash: digest)
        let version = (local?.version ?? .empty).merged(with: job.remote.version)
        commitLocal(rt, &rec, previous: local, version: version)
        stats.filesPulled += 1
        if job.remote.size > 0 && job.received == 0 { rt.burstDone += job.remote.size } // local clone
        if local == nil || local!.deleted, SyncPath.isConflictCopy(path) {
            // A conflict copy made on the other Mac: list it here too.
            recordConflict(rt, ConflictInfo(folderID: rt.config.id, conflictPath: path,
                                            originalPath: SyncPath.originalPath(ofConflictCopy: path),
                                            time: clock(), absolutePath: abs, createdLocally: false))
        }
        rt.lastSyncAt = clock()
        addRecent(rt, path: path, incoming: true, action: (local == nil || local!.deleted) ? .added : .modified, kind: .file)
        clearProblem(rt, path)
        scheduleIndexFlush()
        // The peer may have announced a newer version while we were transferring.
        if let current = store.record(.remote, folder: rt.config.id, path: path), current.version != job.remote.version {
            evaluate(rt, paths: [path])
        }
    }

    /// Abandons a transfer: forgets its requests, closes and deletes the temp file.
    /// `block` records why the path is waiting (nil = it will simply be re-evaluated later).
    func abortJob(_ job: PullJob, block reason: BlockReason?, wait: Bool = false) {
        if activeJobs[job.key] === job { activeJobs[job.key] = nil }
        if let s = session {
            for id in job.outstanding {
                if let r = s.requests.removeValue(forKey: id) { s.outstandingBytes -= r.length }
            }
        }
        job.outstanding.removeAll()
        let writer = job.writer
        if wait {
            writer.queue.sync { writer.abort() }
        } else {
            writer.queue.async { writer.abort() }
        }
        if let reason, let rt = folders[job.key.folder] { block(rt, job.key.path, reason) }
    }

    // MARK: - Serving blocks to the peer

    func handleBlockRequest(_ s: PeerSession, _ req: SyncProtocol.BlockRequest) {
        func reply(_ status: SyncProtocol.BlockStatus) {
            send(.blockResponse, SyncProtocol.blockError(requestID: req.id, status: status))
        }
        guard let store, let rt = folders[req.folder], rt.active, rt.initialScanDone, !isPaused(rt),
              rt.realRoot != nil else {
            reply(.unavailable)
            return
        }
        guard SyncPath.isValidRelative(req.path), req.offset >= 0, req.length > 0,
              req.length <= SyncProtocol.maxBlockSize else {
            reply(.notFound)
            return
        }
        guard let rec = store.record(.local, folder: req.folder, path: req.path), rec.isLive, rec.kind == .file,
              let hash = rec.hash, Hex.encode(hash) == req.hash else {
            reply(.changed)
            return
        }
        guard req.offset + Int64(req.length) <= rec.size else {
            reply(.notFound)
            return
        }
        s.serveQueue.append(ServeItem(requestID: req.id, absolutePath: rt.absolute(req.path), offset: req.offset,
                                      length: req.length, size: rec.size, mtimeNS: rec.mtimeNS))
        pumpServe()
    }

    /// Reads and sends queued blocks, keeping at most `maxServeInFlight` in flight (send completions
    /// provide back-pressure from the network stack).
    private func pumpServe() {
        guard let s = session else { return }
        while s.serveInFlight < options.maxServeInFlight, let item = s.popServe() {
            s.serveInFlight += 1
            let channel = s.channel
            let gen = s.generation
            stats.messagesSent += 1
            ioQueue.async { [weak self] in
                let payload = Self.readBlock(item)
                let bytes = payload.count - SyncProtocol.blockHeaderSize
                channel.send(type: SyncProtocol.MessageType.blockResponse.rawValue, payload: payload) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.serveCompleted(generation: gen, bytes: bytes) }
                }
            }
        }
    }

    private func serveCompleted(generation gen: Int, bytes: Int) {
        guard let s = session, s.generation == gen else { return }
        s.serveInFlight -= 1
        if bytes > 0 {
            stats.blockBytesSent += Int64(bytes)
            stats.blockRequestsServed += 1
        }
        pumpServe()
    }

    /// Reads one block (ioQueue). The file must still match the index record, otherwise "changed".
    static func readBlock(_ item: ServeItem) -> Data {
        let fd = open(item.absolutePath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            return SyncProtocol.blockError(requestID: item.requestID, status: errno == ENOENT ? .changed : .ioError)
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return SyncProtocol.blockError(requestID: item.requestID, status: .ioError) }
        let mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        guard Int64(st.st_size) == item.size, mtime == item.mtimeNS else {
            return SyncProtocol.blockError(requestID: item.requestID, status: .changed)
        }
        // Evicted to iCloud since it was indexed: reading would download it (one download per requested
        // block across many files = a download storm). The peer retries later.
        if FS.isDataless(flags: st.st_flags, path: item.absolutePath) {
            return SyncProtocol.blockError(requestID: item.requestID, status: .unavailable)
        }
        guard var data = FS.readBlock(fd: fd, offset: item.offset, length: item.length,
                                      headerSize: SyncProtocol.blockHeaderSize) else {
            return SyncProtocol.blockError(requestID: item.requestID, status: .changed)
        }
        SyncProtocol.writeBlockHeader(into: &data, requestID: item.requestID, status: .ok)
        return data
    }
}
