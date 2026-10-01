import Foundation
import CoreServices
import os

/// FSEvents watcher for one folder root (file-level events).
///
/// The stream is serviced on a private serial queue that only buffers events, and the buffered events are
/// handed to the target queue (the engine queue) in one coalesced batch. Servicing the stream directly on the
/// engine queue made fseventsd drop events whenever the engine was busy (applying a large index batch, a full
/// evaluation): every burst of a bulk change then produced "UserDropped | MustScanSubDirs" notices on the
/// root, i.e. back-to-back full rescans that kept the engine busy — and dropping — even longer.
final class FSWatcher {
    struct Event {
        let path: String
        let flags: FSEventStreamEventFlags

        /// Events were lost (fseventsd / kernel buffer overflow, or event ids wrapped): rescan everything.
        var eventsWereDropped: Bool {
            let mask = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped)
            return flags & mask != 0
        }

        /// Events below `path` were coalesced: rescan `path` and everything below it.
        var mustScanSubDirs: Bool {
            flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
        }

        /// Root moved / deleted, or a volume was (un)mounted: re-check the folder root and marker.
        var requiresRootCheck: Bool {
            let mask = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount)
            return flags & mask != 0
        }
    }

    typealias Handler = ([Event]) -> Void

    /// Events buffered while the target queue is busy, beyond which they are replaced by one "dropped"
    /// notice (a full rescan) instead of growing without bound.
    static let maxBufferedEvents = 200_000

    /// Shared by the stream callback (event queue) and the delivery block (target queue).
    private final class Box: @unchecked Sendable {
        let handler: Handler
        let target: DispatchQueue
        let root: String
        private struct Buffer {
            var events: [Event] = []
            var overflowed = false
            var deliveryScheduled = false
        }
        private let buffer = OSAllocatedUnfairLock(initialState: Buffer())

        init(handler: @escaping Handler, target: DispatchQueue, root: String) {
            self.handler = handler
            self.target = target
            self.root = root
        }

        /// Event queue: buffer, and schedule one delivery on the target queue if none is pending.
        func add(_ events: [Event]) {
            let schedule = buffer.withLock { b -> Bool in
                if !b.overflowed {
                    if b.events.count + events.count > FSWatcher.maxBufferedEvents {
                        b.overflowed = true
                        b.events.removeAll()
                    } else {
                        b.events.append(contentsOf: events)
                    }
                }
                guard !b.deliveryScheduled else { return false }
                b.deliveryScheduled = true
                return true
            }
            guard schedule else { return }
            target.async { self.deliver() }
        }

        /// Target queue: hands everything buffered so far to the handler.
        private func deliver() {
            let events = buffer.withLock { b -> [Event] in
                let out = b.overflowed
                    ? [Event(path: root, flags: FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                        | kFSEventStreamEventFlagUserDropped))]
                    : b.events
                b.events = []
                b.overflowed = false
                b.deliveryScheduled = false
                return out
            }
            if !events.isEmpty { handler(events) }
        }
    }

    private var stream: FSEventStreamRef?
    private let eventQueue: DispatchQueue
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    /// Starts watching `path` immediately; batches are delivered to `handler` on `queue`. Returns nil when
    /// the stream cannot be created.
    init?(path: String, latency: TimeInterval, queue: DispatchQueue, handler: @escaping Handler) {
        eventQueue = DispatchQueue(label: "oneswitch.sync.fsevents", qos: .userInitiated)
        let box = Box(handler: handler, target: queue, root: path)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                if let info { Unmanaged<Box>.fromOpaque(info).release() }
            },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let cfPaths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue()
            guard let list = cfPaths as? [String] else { return }
            var events: [Event] = []
            events.reserveCapacity(count)
            for i in 0..<min(count, list.count) {
                events.append(Event(path: list[i], flags: flags[i]))
            }
            box.add(events)
        }
        let createFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagWatchRoot
            | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, createFlags) else {
            // The context was never adopted by a stream: balance the retain ourselves.
            Unmanaged.passUnretained(box).release()
            return nil
        }
        self.stream = stream
        eventQueue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(eventQueue))
        FSEventStreamSetDispatchQueue(stream, eventQueue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    /// Stops and releases the stream synchronously (no callback runs afterwards; batches already handed to
    /// the target queue may still arrive there — the engine discards them by epoch). Safe to call more
    /// than once, from any queue except from within `handler` holding up the event queue (it never does:
    /// the event queue only buffers).
    func stop() {
        guard stream != nil else { return }
        let release = {
            guard let stream = self.stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(eventQueue) {
            release()
        } else {
            eventQueue.sync(execute: release)
        }
    }

    deinit { stop() }
}
