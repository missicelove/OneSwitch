import Foundation
import os

/// Thread-safe logging to the unified log, a rotating file (~/Library/Logs/OneSwitch/OneSwitch[-profile].log)
/// and an in-memory ring buffer shown in Settings → 通用 → 日志.
///
/// Usage: `AppLog.info("sync", "scan finished: \(count) files")`
public enum AppLog {
    public enum Level: String, Sendable { case debug = "DEBUG", info = "INFO", warning = "WARN", error = "ERROR" }

    /// The bundled app logs to OneSwitch[-profile].log. Anything else (self-check executables,
    /// `swift run`) logs to OneSwitch-dev.log so it never pollutes the running app's log.
    public static let logFileURL: URL = {
        let name: String
        if AppEnvironment.isRunningFromBundle || AppEnvironment.profile != nil {
            name = "\(AppEnvironment.appName)\(AppEnvironment.profileSuffix).log"
        } else {
            name = "\(AppEnvironment.appName)-dev.log"
        }
        return AppEnvironment.logDirectory.appendingPathComponent(name)
    }()

    /// Set to true (e.g. from a check executable) to echo every line to stderr.
    public static var echoToStderr: Bool {
        get { state.withLock { $0.echo } }
        set { state.withLock { $0.echo = newValue } }
    }

    /// Debug lines are dropped unless enabled (Settings → 通用 → 详细日志).
    public static var debugEnabled: Bool {
        get { state.withLock { $0.debug } }
        set { state.withLock { $0.debug = newValue } }
    }

    public static func debug(_ category: String, _ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        write(.debug, category, message())
    }
    public static func info(_ category: String, _ message: @autoclosure () -> String) { write(.info, category, message()) }
    public static func warning(_ category: String, _ message: @autoclosure () -> String) { write(.warning, category, message()) }
    public static func error(_ category: String, _ message: @autoclosure () -> String) { write(.error, category, message()) }

    /// Most recent lines (oldest first), at most `limit`.
    public static func recentLines(limit: Int = 500) -> [String] {
        state.withLock { Array($0.ring.suffix(limit)) }
    }

    /// Blocks until every line logged so far has been written to the log file. Call before the process
    /// exits (file writes are asynchronous, so the last lines would otherwise be lost).
    public static func flush() {
        fileQueue.sync {}
    }

    // MARK: - Implementation

    private struct State {
        var ring: [String] = []
        var loggers: [String: Logger] = [:]
        var echo = false
        var debug = false
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())
    /// Serial queue owning `file` and the ring order.
    private static let fileQueue = DispatchQueue(label: "oneswitch.log.file", qos: .utility)
    private static let maxRing = 2000
    private static let file = RotatingLogFile(url: logFileURL, maxSize: 5 * 1024 * 1024)

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func write(_ level: Level, _ category: String, _ message: String) {
        let (logger, echo): (Logger, Bool) = state.withLock { st in
            let l: Logger
            if let existing = st.loggers[category] {
                l = existing
            } else {
                l = Logger(subsystem: AppEnvironment.bundleIdentifier, category: category)
                st.loggers[category] = l
            }
            return (l, st.echo)
        }
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        let now = Date()
        fileQueue.async {
            let line = "\(timestampFormatter.string(from: now)) [\(level.rawValue)] [\(category)] \(message)"
            state.withLock { st in
                st.ring.append(line)
                if st.ring.count > maxRing { st.ring.removeFirst(st.ring.count - maxRing) }
            }
            if echo { FileHandle.standardError.write(Data((line + "\n").utf8)) }
            file.append(line + "\n")
        }
    }
}

/// Append-only text file with size-based rotation: when the file reaches `maxSize` it is renamed to
/// `<name>.1` (replacing an older `.1`) and a fresh file is started.
///
/// Keeps one descriptor open (O_APPEND | O_CLOEXEC) instead of reopening per line. Other processes may
/// append to — or rotate — the same file (the check executables share the default log with the app), so
/// every few writes it verifies that the path still refers to the open file and reopens otherwise.
///
/// Not internally synchronized: use it from one serial queue.
public final class RotatingLogFile: @unchecked Sendable {
    public let url: URL
    public let maxSize: UInt64
    private var fd: Int32 = -1
    private var size: UInt64 = 0
    private var writesUntilCheck = 0
    private static let checkInterval = 64

    public init(url: URL, maxSize: UInt64) {
        self.url = url
        self.maxSize = maxSize
    }

    deinit { closeFile() }

    public func append(_ text: String) {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return }
        if fd < 0 || pathNoLongerMatches() { reopen() }
        if size > 0 && size + UInt64(bytes.count) > maxSize { rotate() }
        guard fd >= 0 else { return }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { buf in
                Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
            }
            if n < 0 {
                if errno == EINTR { continue }
                closeFile() // e.g. disk full / file system gone: retry with a fresh open next time
                return
            }
            offset += n
        }
        size += UInt64(bytes.count)
    }

    /// Closes the descriptor (the next append reopens it).
    public func closeFile() {
        if fd >= 0 { close(fd) }
        fd = -1
        size = 0
    }

    private func reopen() {
        closeFile()
        let path = url.path
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        var st = stat()
        size = fstat(fd, &st) == 0 ? UInt64(st.st_size) : 0
        writesUntilCheck = Self.checkInterval
    }

    private func rotate() {
        closeFile()
        let path = url.path
        // rename(2) atomically replaces an existing ".1".
        if rename(path, path + ".1") != 0 && errno != ENOENT {
            try? FileManager.default.removeItem(atPath: path)
        }
        reopen()
    }

    /// Every `checkInterval` writes: true when the file was deleted / rotated by someone else (the path
    /// now names a different inode, or nothing). Also refreshes `size` for appends by other processes.
    private func pathNoLongerMatches() -> Bool {
        writesUntilCheck -= 1
        guard writesUntilCheck <= 0 else { return false }
        writesUntilCheck = Self.checkInterval
        var open = stat(), onDisk = stat()
        guard fstat(fd, &open) == 0, stat(url.path, &onDisk) == 0 else { return true }
        if open.st_dev != onDisk.st_dev || open.st_ino != onDisk.st_ino { return true }
        size = UInt64(open.st_size)
        return false
    }
}
