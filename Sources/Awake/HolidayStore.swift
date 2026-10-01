import Foundation
import os
import OneSwitchCore

/// Downloads, caches and serves Chinese statutory holiday data (holiday-cn).
///
/// - Network and file I/O run on a private serial queue; state is published on the main actor.
/// - Cache: `<directory>/awake-holidays-<year>.json` (raw holiday-cn JSON). Works offline from cache.
/// - Refresh policy: at launch, then at most daily; after a failure (or while a year is missing) hourly.
@MainActor
public final class HolidayStore: ObservableObject {
    public nonisolated static let defaultURLTemplates = [
        "https://fastly.jsdelivr.net/gh/NateScarlet/holiday-cn@master/{year}.json",
        "https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/{year}.json",
        "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/{year}.json",
    ]
    static let lastUpdatedKey = "awake.holidays.lastUpdated"

    public static let successInterval: TimeInterval = 24 * 3600
    public static let retryInterval: TimeInterval = 3600

    /// Merged holiday data (cache + fresh downloads).
    @Published public private(set) var data = HolidayData()
    @Published public private(set) var isRefreshing = false
    /// Last time a download succeeded (persisted).
    @Published public private(set) var lastUpdated: Date?
    /// User-facing error of the last refresh (nil when it succeeded).
    @Published public private(set) var lastError: String?
    /// Years for which the source has no (or an empty) file yet, e.g. next year before the State
    /// Council publishes the arrangement.
    @Published public private(set) var unpublishedYears: Set<Int> = []

    /// Called on the main actor whenever `data` changes.
    public var onDataChange: (() -> Void)?

    public let directory: URL
    private let defaults: UserDefaults
    private let urlTemplates: [String]
    private let clock: () -> Date
    private let ioQueue: DispatchQueue
    private var lastAttempt: Date?
    private var lastAttemptFailed = false
    private var fetch: HolidayFetcher?
    private var pendingCompletions: [() -> Void] = []

    /// - Parameter ioQueue: serial queue for file and network work (injectable for checks).
    public init(directory: URL, defaults: UserDefaults,
                urlTemplates: [String] = HolidayStore.defaultURLTemplates,
                clock: @escaping () -> Date = Date.init,
                ioQueue: DispatchQueue? = nil) {
        self.ioQueue = ioQueue ?? DispatchQueue(label: "oneswitch.awake.holidays", qos: .utility)
        self.directory = directory
        self.defaults = defaults
        self.urlTemplates = urlTemplates
        self.clock = clock
        let t = defaults.double(forKey: Self.lastUpdatedKey)
        lastUpdated = t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    public func cacheURL(for year: Int) -> URL {
        directory.appendingPathComponent("awake-holidays-\(year).json")
    }

    /// Loads cached years in the background; `completion` runs on the main actor afterwards.
    public func loadCache(years: [Int], completion: (() -> Void)? = nil) {
        let targets = years.map { ($0, cacheURL(for: $0)) }
        ioQueue.async { [weak self] in
            var files: [HolidayYearFile] = []
            for (year, url) in targets {
                guard let raw = try? Data(contentsOf: url) else { continue }
                do {
                    files.append(try HolidayYearFile.parse(raw, expectedYear: year))
                } catch {
                    AppLog.warning("awake", "ignoring corrupt holiday cache \(url.lastPathComponent): \(error)")
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { completion?(); return }
                    var changed = false
                    // Never replace data that a download already delivered.
                    for f in files where self.data.files[f.year] == nil {
                        self.data.set(f)
                        changed = true
                    }
                    if !files.isEmpty {
                        AppLog.info("awake", "holiday cache loaded: \(files.map { "\($0.year)(\($0.days.count))" }.joined(separator: ", "))")
                    }
                    if changed { self.onDataChange?() }
                    completion?()
                }
            }
        }
    }

    /// Refreshes when due: at the first call (launch), daily after success, hourly after a failure
    /// or while one of `years` has never been loaded.
    public func refreshIfDue(years: [Int]) {
        guard !isRefreshing else { return }
        guard let lastAttempt else {
            refresh(years: years)
            return
        }
        let elapsed = abs(clock().timeIntervalSince(lastAttempt))
        // A year confirmed as not yet published is re-checked daily; one that failed or was never loaded hourly.
        let missing = years.contains { data.files[$0] == nil && !unpublishedYears.contains($0) }
        let interval = (lastAttemptFailed || missing) ? Self.retryInterval : Self.successInterval
        if elapsed >= interval { refresh(years: years) }
    }

    /// Downloads `years` now (立即更新). `completion` runs on the main actor when done.
    public func refresh(years: [Int], completion: (() -> Void)? = nil) {
        if let completion { pendingCompletions.append(completion) }
        guard !isRefreshing else { return }
        isRefreshing = true
        lastAttempt = clock()
        let fetcher = HolidayFetcher(templates: urlTemplates, cacheDirectory: directory, queue: ioQueue)
        fetch = fetcher
        AppLog.info("awake", "refreshing holiday data for \(years)")
        fetcher.start(years: years) { [weak self] results in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(fetcher: fetcher, results: results) }
            }
        }
    }

    /// Cancels an in-flight refresh (called from `stop()`). Synchronous: once this returns, the fetcher
    /// writes no cache file and delivers no result.
    public func cancel() {
        fetch?.cancel()
        fetch = nil
        if isRefreshing {
            isRefreshing = false
            let completions = pendingCompletions
            pendingCompletions.removeAll()
            completions.forEach { $0() }
        }
    }

    private func finish(fetcher: HolidayFetcher, results: [Int: HolidayFetchOutcome]) {
        guard fetch === fetcher else { return } // cancelled / superseded
        fetch = nil
        isRefreshing = false
        var errors: [String] = []
        var changed = false
        var anySuccess = false
        for year in results.keys.sorted() {
            switch results[year]! {
            case .fetched(let file, let source):
                anySuccess = true
                if data.files[year] != file {
                    data.set(file)
                    changed = true
                }
                if file.days.isEmpty { unpublishedYears.insert(year) } else { unpublishedYears.remove(year) }
                AppLog.info("awake", "holiday data \(year): \(file.days.count) entries from \(source)")
            case .notPublished:
                anySuccess = true
                unpublishedYears.insert(year)
                AppLog.info("awake", "holiday data \(year): not published yet")
            case .failed(let message):
                errors.append(results.count > 1 ? "\(year) 年：\(message)" : message)
                AppLog.warning("awake", "holiday data \(year) failed: \(message)")
            }
        }
        lastAttemptFailed = !errors.isEmpty
        if anySuccess {
            let now = clock()
            lastUpdated = now
            defaults.set(now.timeIntervalSince1970, forKey: Self.lastUpdatedKey)
        }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "；")
        if changed { onDataChange?() }
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        completions.forEach { $0() }
    }

    /// "2026 年：38 条 · 2027 年：尚未公布"
    public func summary(years: [Int]) -> String {
        years.map { year -> String in
            if let count = data.entryCount(forYear: year), count > 0 { return "\(year) 年：\(count) 条" }
            if unpublishedYears.contains(year) || data.entryCount(forYear: year) == 0 { return "\(year) 年：尚未公布" }
            return "\(year) 年：暂无数据"
        }.joined(separator: " · ")
    }
}

enum HolidayFetchOutcome: Sendable {
    case fetched(HolidayYearFile, source: String)
    case notPublished
    case failed(String)
}

/// One refresh run. All URLSession work and cache writes happen on `queue` (the session's delegate
/// queue targets it), which also serialises task creation against `cancel()`.
final class HolidayFetcher: @unchecked Sendable {
    private let templates: [String]
    private let cacheDirectory: URL
    private let queue: DispatchQueue
    private let session: URLSession
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(templates: [String], cacheDirectory: URL, queue: DispatchQueue) {
        self.templates = templates
        self.cacheDirectory = cacheDirectory
        self.queue = queue
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "OneSwitch (macOS)"]
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: config, delegate: nil, delegateQueue: delegateQueue)
    }

    private var isCancelled: Bool { cancelled.withLock { $0 } }

    func start(years: [Int], completion: @escaping ([Int: HolidayFetchOutcome]) -> Void) {
        queue.async {
            self.next(years: years[...], results: [:], completion: completion)
        }
    }

    /// Synchronous: after the flag is set, the barrier waits for a completion handler that may already
    /// be running on `queue` (e.g. about to write the cache), so nothing touches the disk after `cancel()`
    /// returns. Blocks on `queue` only briefly: it never waits for the network, and nothing on `queue`
    /// waits for the main thread.
    func cancel() {
        cancelled.withLock { $0 = true }
        queue.sync { session.invalidateAndCancel() }
    }

    private func next(years: ArraySlice<Int>, results: [Int: HolidayFetchOutcome],
                      completion: @escaping ([Int: HolidayFetchOutcome]) -> Void) {
        guard let year = years.first, !isCancelled else {
            if !isCancelled { session.finishTasksAndInvalidate() }
            completion(results)
            return
        }
        fetch(year: year, index: 0, sawNotFound: false, lastError: nil) { outcome in
            var r = results
            r[year] = outcome
            self.next(years: years.dropFirst(), results: r, completion: completion)
        }
    }

    private func fetch(year: Int, index: Int, sawNotFound: Bool, lastError: String?,
                       completion: @escaping (HolidayFetchOutcome) -> Void) {
        guard !isCancelled else {
            completion(.failed("已取消"))
            return
        }
        guard index < templates.count else {
            if sawNotFound {
                completion(.notPublished)
            } else {
                completion(.failed(lastError ?? "无可用的数据源"))
            }
            return
        }
        let template = templates[index]
        guard let url = URL(string: template.replacingOccurrences(of: "{year}", with: String(year))) else {
            fetch(year: year, index: index + 1, sawNotFound: sawNotFound, lastError: "数据源地址无效", completion: completion)
            return
        }
        // Runs on `queue` (both initially and from completion handlers), so `cancel()`'s invalidation
        // cannot interleave between the check above and task creation.
        let task = session.dataTask(with: url) { data, response, error in
            if let error {
                let notFound = (error as? URLError)?.code == .fileDoesNotExist
                self.fetch(year: year, index: index + 1, sawNotFound: sawNotFound || notFound,
                           lastError: Self.describe(error), completion: completion)
                return
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                self.fetch(year: year, index: index + 1, sawNotFound: sawNotFound || http.statusCode == 404,
                           lastError: "服务器返回错误（HTTP \(http.statusCode)）", completion: completion)
                return
            }
            guard let data, !data.isEmpty else {
                self.fetch(year: year, index: index + 1, sawNotFound: sawNotFound,
                           lastError: "服务器返回了空数据", completion: completion)
                return
            }
            guard !self.isCancelled else {
                completion(.failed("已取消"))
                return
            }
            do {
                let file = try HolidayYearFile.parse(data, expectedYear: year)
                self.writeCache(data, year: year)
                completion(.fetched(file, source: url.host ?? url.absoluteString))
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "数据格式错误"
                self.fetch(year: year, index: index + 1, sawNotFound: sawNotFound, lastError: message, completion: completion)
            }
        }
        task.resume()
    }

    private func writeCache(_ data: Data, year: Int) {
        let url = cacheDirectory.appendingPathComponent("awake-holidays-\(year).json")
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.warning("awake", "could not write holiday cache \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    static func describe(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "网络未连接"
        case .timedOut: return "连接超时"
        case .cannotFindHost, .dnsLookupFailed: return "无法解析服务器地址"
        case .cannotConnectToHost: return "无法连接服务器"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: return "安全连接失败"
        case .cancelled: return "已取消"
        case .fileDoesNotExist: return "数据文件不存在"
        default: return "网络错误（\(urlError.code.rawValue)）"
        }
    }
}
