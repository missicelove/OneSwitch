import Foundation
import AppKit
import SwiftUI
import CryptoKit
import OneSwitchCore
@testable import FolderSync

// Self-checks for FolderSync. Exit code 0 = all checks passed.
// Integration checks run two real engines (LoopbackPeerHub pair, real FSEvents, temp folders).

setvbuf(stdout, nil, _IOLBF, 0)
AppLog.echoToStderr = ProcessInfo.processInfo.environment["SYNC_CHECK_VERBOSE"] != nil
AppLog.debugEnabled = AppLog.echoToStderr

var failures = 0
var timings: [(String, Double)] = []

func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    if condition() {
        print("  ✓ \(message())")
    } else {
        failures += 1
        print("  ✗ \(message()) (line \(line))")
    }
}

/// Removes a check-only defaults suite completely (clearing the domain alone leaves an empty plist in
/// ~/Library/Preferences behind).
func removeDefaultsSuite(_ suite: UserDefaults, _ name: String) {
    suite.removePersistentDomain(forName: name)
    suite.synchronize()
    let plist = NSHomeDirectory() + "/Library/Preferences/\(name).plist"
    try? FileManager.default.removeItem(atPath: plist)
}

/// Spins the main run loop until `condition` is true or `timeout` elapses.
@MainActor
func waitUntil(_ timeout: TimeInterval = 5, poll: TimeInterval = 0.02, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(poll))
    }
    return condition()
}

@MainActor
func spin(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&_value); lock.unlock() }
}

// MARK: - File helpers

let fm = FileManager.default
let tempRoot = fm.temporaryDirectory.appendingPathComponent("FolderSyncCheck-\(UUID().uuidString.prefix(8))").path
try? fm.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
let realTempRoot = FS.realPath(tempRoot) ?? tempRoot

func randomData(_ n: Int) -> Data {
    var d = Data(count: n)
    d.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, n) }
    return d
}

func sha(_ data: Data) -> String { Hex.encode(Data(SHA256.hash(data: data))) }

@discardableResult
func write(_ root: String, _ rel: String, _ data: Data, mtime: Date? = nil, mode: Int? = nil) -> String {
    let path = root + "/" + rel
    try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! data.write(to: URL(fileURLWithPath: path))
    if let mode { chmod(path, mode_t(mode)) }
    if let mtime { try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: path) }
    return path
}

@discardableResult
func write(_ root: String, _ rel: String, _ text: String, mtime: Date? = nil) -> String {
    write(root, rel, Data(text.utf8), mtime: mtime)
}

func read(_ root: String, _ rel: String) -> String? {
    guard let d = fm.contents(atPath: root + "/" + rel) else { return nil }
    return String(decoding: d, as: UTF8.self)
}

func exists(_ root: String, _ rel: String) -> Bool {
    var st = stat()
    return lstat(root + "/" + rel, &st) == 0
}

struct TreeEntry: Equatable, CustomStringConvertible {
    let kind: Character
    let content: String
    let mtimeNS: Int64
    let mode: UInt32
    var description: String { "\(kind) \(content.prefix(12)) m=\(mtimeNS) o=\(String(mode, radix: 8))" }
}

private let hashCache = Box<[String: (Int64, Int64, UInt64, String)]>([:])

/// Relative path (NFC) → kind + content hash / link target + mtime (files, links) + mode.
/// Excludes the ".oneswitch" marker, temp files and Finder litter; `exclude` filters more.
func tree(_ root: String, exclude: (String) -> Bool = { _ in false }) -> [String: TreeEntry] {
    var out: [String: TreeEntry] = [:]
    func visit(_ rel: String) {
        let dir = rel.isEmpty ? root : root + "/" + rel
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for raw in names {
            let name = raw.precomposedStringWithCanonicalMapping
            if rel.isEmpty && name == ".oneswitch" { continue }
            if name.hasSuffix(".oneswitch-tmp") || name == ".DS_Store" { continue }
            let childRel = rel.isEmpty ? name : rel + "/" + name
            if exclude(childRel) { continue }
            let path = dir + "/" + raw
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let mode = UInt32(st.st_mode & 0o7777)
            let mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                out[childRel] = TreeEntry(kind: "d", content: "", mtimeNS: 0, mode: mode)
                visit(childRel)
            case S_IFLNK:
                let target = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? "?"
                out[childRel] = TreeEntry(kind: "l", content: target, mtimeNS: mtime, mode: 0)
            case S_IFREG:
                let size = Int64(st.st_size)
                let ino = UInt64(st.st_ino)
                let digest: String
                if let c = hashCache.value[path], c.0 == size, c.1 == mtime, c.2 == ino {
                    digest = c.3
                } else {
                    let data = (try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)) ?? Data()
                    digest = sha(data)
                    hashCache.mutate { $0[path] = (size, mtime, ino, digest) }
                }
                out[childRel] = TreeEntry(kind: "f", content: digest, mtimeNS: mtime, mode: mode)
            default:
                break
            }
        }
    }
    visit("")
    return out
}

func treeDiff(_ a: [String: TreeEntry], _ b: [String: TreeEntry], limit: Int = 6) -> String {
    var lines: [String] = []
    for key in Set(a.keys).union(b.keys).sorted() where a[key] != b[key] {
        lines.append("\(key): A=\(a[key]?.description ?? "—") B=\(b[key]?.description ?? "—")")
        if lines.count >= limit { break }
    }
    return lines.isEmpty ? "identical" : lines.joined(separator: "\n      ")
}

func conflictCopies(_ t: [String: TreeEntry]) -> [String] {
    t.keys.filter { $0.contains(".sync-conflict-") }.sorted()
}

func timed(_ name: String, _ seconds: Double) {
    timings.append((name, seconds))
    print(String(format: "    ⏱ %@: %.2f s", name, seconds))
}

// MARK: - Two-engine harness

var testOptions: SyncEngine.Options {
    var o = SyncEngine.Options()
    o.fullRescanInterval = 3600
    o.errorRecheckInterval = 1
    o.housekeepingInterval = 0.5
    return o
}

@MainActor
final class Pair {
    let hubA: LoopbackPeerHub
    let hubB: LoopbackPeerHub
    let dirA: String
    let dirB: String
    let stateA: URL
    let stateB: URL
    var foldersA: [FolderConfig]
    var foldersB: [FolderConfig]
    var engineA: SyncEngine!
    var engineB: SyncEngine!
    let snapshotTimesA = Box<[Date]>([])
    var excludeA: (String) -> Bool = { _ in false }
    var excludeB: (String) -> Bool = { _ in false }
    var optionsA = testOptions
    var optionsB = testOptions

    init(name: String, folderID: String) {
        (hubA, hubB) = LoopbackPeerHub.makePair(nameA: "Mac Studio", nameB: "MacBook Pro")
        dirA = realTempRoot + "/\(name)-A"
        dirB = realTempRoot + "/\(name)-B"
        try? fm.createDirectory(atPath: dirA, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: dirB, withIntermediateDirectories: true)
        stateA = URL(fileURLWithPath: realTempRoot + "/\(name)-stateA")
        stateB = URL(fileURLWithPath: realTempRoot + "/\(name)-stateB")
        foldersA = [FolderConfig(id: folderID, label: "文档", path: dirA, versioning: .none)]
        foldersB = [FolderConfig(id: folderID, label: "文档", path: dirB, versioning: .none)]
    }

    func makeEngineA() -> SyncEngine {
        let times = snapshotTimesA
        return SyncEngine(hub: hubA, stateDirectory: stateA, deviceID: hubA.localDeviceID, deviceName: hubA.localDeviceName,
                          options: optionsA, onSnapshot: { _ in times.mutate { $0.append(Date()) } })
    }

    func makeEngineB() -> SyncEngine {
        SyncEngine(hub: hubB, stateDirectory: stateB, deviceID: hubB.localDeviceID, deviceName: hubB.localDeviceName,
                   options: optionsB)
    }

    func start() {
        engineA = makeEngineA()
        engineB = makeEngineB()
        engineA.start(folders: foldersA)
        engineB.start(folders: foldersB)
    }

    var treeA: [String: TreeEntry] { tree(dirA, exclude: excludeA) }
    var treeB: [String: TreeEntry] { tree(dirB, exclude: excludeB) }

    func quiescent() -> Bool {
        engineA.isQuiescent() && engineB.isQuiescent()
    }

    func connectedAndInitial(_ folderID: String) -> Bool {
        let a = engineA.snapshotNow(), b = engineB.snapshotNow()
        return a.connected && b.connected
            && a.folders.first { $0.id == folderID }.map { $0.peerHasFolder } == true
            && b.folders.first { $0.id == folderID }.map { $0.peerHasFolder } == true
    }

    /// Waits until both trees are identical and both engines are idle. Returns elapsed seconds or nil.
    func converge(_ timeout: TimeInterval = 60) -> Double? {
        let start = Date()
        let ok = waitUntil(timeout, poll: 0.1) { quiescent() && treeA == treeB && quiescent() }
        return ok ? Date().timeIntervalSince(start) : nil
    }

    /// Converges, waits long enough for rescans / re-announcements that can follow an apparent convergence
    /// (a kept directory used to be rescanned and re-announced only then), and converges again.
    func settle(_ timeout: TimeInterval = 60) -> Double? {
        guard let t = converge(timeout) else { return nil }
        spin(1.5)
        return converge(timeout).map { $0 + t + 1.5 }
    }

    func stop() {
        engineA?.stop()
        engineB?.stop()
    }
}

// MARK: - Unit checks

@MainActor
func unitChecks() {
    print("VersionVector")
    let a = VersionVector(["A": 2, "B": 1])
    let b = VersionVector(["A": 1, "B": 2])
    check(a.compare(b) == .concurrent, "concurrent vectors")
    check(a.compare(a) == .equal, "equal vectors")
    check(VersionVector(["A": 2, "B": 2]).compare(a) == .greater, "dominating vector")
    check(VersionVector.empty.compare(a) == .lesser, "empty is dominated")
    check(a.merged(with: b) == VersionVector(["A": 2, "B": 2]), "merge = element-wise max")
    check(a.bumped(device: "A", atLeast: 10)["A"] == 10 && a.bumped(device: "A", atLeast: 0)["A"] == 3, "bump strictly grows own counter")
    check(VersionVector(storageString: a.storageString) == a, "storage encoding round-trips")
    check(VersionVector(["A": 1, "Z": 3]).storageString == VersionVector(["Z": 3, "A": 1]).storageString, "storage encoding is canonical")

    print("ConflictResolver")
    let h1 = Data(repeating: 1, count: 32), h2 = Data(repeating: 2, count: 32)
    func file(_ v: [String: UInt64], hash: Data = h1, mtime: Int64 = 100, deleted: Bool = false) -> FileRecord {
        FileRecord(path: "x", kind: .file, size: deleted ? 0 : 5, mtimeNS: mtime, mode: 0o644,
                   hash: deleted ? nil : hash, deleted: deleted, version: VersionVector(v))
    }
    func decide(_ l: FileRecord?, _ r: FileRecord, _ me: String, _ peer: String) -> SyncAction {
        ConflictResolver.decide(local: l, remote: r, localDevice: me, remoteDevice: peer)
    }
    check(decide(nil, file(["B": 1]), "A", "B") == .apply(version: VersionVector(["B": 1]), conflict: false), "unknown path: apply remote")
    check(decide(file(["A": 2]), file(["A": 1]), "A", "B") == .none, "local dominates: nothing")
    check(decide(file(["A": 1]), file(["A": 1]), "A", "B") == .none, "equal: nothing")
    check(decide(file(["A": 1]), file(["A": 1, "B": 1], hash: h2), "A", "B") == .apply(version: VersionVector(["A": 1, "B": 1]), conflict: false),
          "remote dominates: apply")
    check(decide(file(["A": 1]), file(["A": 1, "B": 1]), "A", "B") == .adopt(version: VersionVector(["A": 1, "B": 1]), metadata: nil),
          "remote dominates with same content: adopt vector, no transfer")
    let merged = VersionVector(["A": 1, "B": 1])
    // Concurrent, different content: later mtime wins; both sides decide complementary actions.
    let la = file(["A": 1], hash: h1, mtime: 200), lb = file(["B": 1], hash: h2, mtime: 100)
    check(decide(la, lb, "A", "B") == .none, "concurrent: later local mtime keeps local, vector NOT merged by the winner")
    check(decide(lb, la, "B", "A") == .apply(version: merged, conflict: true), "concurrent: loser makes conflict copy + applies")
    // The loser's merged result dominates the winner's record → the winner adopts it without a transfer.
    var loserAfter = la
    loserAfter.version = merged
    check(decide(la, loserAfter, "A", "B") == .adopt(version: merged, metadata: nil), "winner adopts the loser's merged record")
    // Tie on mtime: larger device id wins.
    let ta = file(["A": 1], hash: h1, mtime: 100), tb = file(["B": 1], hash: h2, mtime: 100)
    check(decide(tb, ta, "B", "A") == .none && decide(ta, tb, "A", "B") == .apply(version: merged, conflict: true),
          "mtime tie → larger device id wins on both sides")
    // Modification beats deletion even when the deletion is "newer".
    let del = file(["A": 1], mtime: 999, deleted: true), mod = file(["B": 1], hash: h2, mtime: 1)
    check(decide(del, mod, "A", "B") == .apply(version: merged, conflict: false), "deleted side applies the modification")
    check(decide(mod, del, "B", "A") == .none, "modified side keeps its file (and its own vector)")
    check(decide(file(["A": 1], deleted: true), file(["B": 1], deleted: true), "A", "B") == .adopt(version: merged, metadata: nil),
          "both deleted: merge vectors")
    check(decide(file(["A": 1], mtime: 5), file(["B": 1], mtime: 9), "A", "B") == .adopt(version: merged, metadata: file(["B": 1], mtime: 9)),
          "concurrent equal content: merge + winner's metadata")

    print("IgnoreMatcher")
    let m = IgnoreMatcher(userPatterns: ["*.log", "build", "/root-only.txt", "docs/*.tmp", "# comment", "  "])
    check(m.isIgnored(".DS_Store") && m.isIgnored("a/b/.DS_Store"), ".DS_Store ignored everywhere")
    check(m.isIgnored("._foo") && m.isIgnored("Icon\r") && m.isIgnored("x/.report.pdf.1a2b3c4d.oneswitch-tmp"), "AppleDouble / Icon / temp files ignored")
    check(m.isIgnored(".oneswitch") && m.isIgnored(".oneswitch/versions/a.txt"), "marker directory ignored")
    check(m.isIgnored("a/app.log") && !m.isIgnored("a/app.log.txt"), "basename glob")
    check(m.isIgnored("build") && m.isIgnored("src/build/out.o"), "ignored directory excludes subtree")
    check(m.isIgnored("root-only.txt") && !m.isIgnored("sub/root-only.txt"), "anchored pattern")
    check(m.isIgnored("docs/a.tmp") && !m.isIgnored("other/a.tmp") && !m.isIgnored("docs/sub/a.tmp"), "path pattern with FNM_PATHNAME")
    check(!m.isIgnored("# comment") && !m.isIgnored("keep.txt"), "comments / blank lines are not patterns")
    check(IgnoreMatcher.parse("a\n\n  b  \r\n#c") == ["a", "b", "#c"], "multi-line parsing")

    print("SyncPath")
    let date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                              year: 2026, month: 1, day: 2, hour: 3, minute: 4, second: 5).date!
    check(SyncPath.conflictPath(for: "a/report.docx", date: date, deviceName: "My Mac", isDirectory: false)
          == "a/report.sync-conflict-20260102-030405-My Mac.docx", "conflict name with extension")
    check(SyncPath.conflictPath(for: "Makefile", date: date, deviceName: "A/B", isDirectory: false)
          == "Makefile.sync-conflict-20260102-030405-A-B", "conflict name without extension, device sanitized")
    check(SyncPath.conflictPath(for: ".bashrc", date: date, deviceName: "M", isDirectory: false, attempt: 2)
          == ".bashrc.sync-conflict-20260102-030405-M-2", "dot-file conflict name with attempt suffix")
    check(!SyncPath.isValidRelative("../x") && !SyncPath.isValidRelative("/abs") && !SyncPath.isValidRelative("a//b")
          && !SyncPath.isValidRelative("a/./b") && !SyncPath.isValidRelative(".oneswitch/x") && !SyncPath.isValidRelative(""),
          "unsafe relative paths rejected")
    check(SyncPath.isValidRelative("中文/名 称 🎉.txt"), "unicode path accepted")
    check(SyncPath.ancestors(of: "a/b/c") == ["a", "a/b"] && SyncPath.isInside("a/b", "a") && !SyncPath.isInside("ab", "a"),
          "ancestors / isInside")
    let nfd = "e\u{301}.txt"
    check(!SyncPath.isNFC(nfd) && SyncPath.normalize(nfd).utf8.count == "é.txt".utf8.count, "NFC normalization")
    check(Scanner.versionDate(fromName: Scanner.versionName(for: "a.txt", date: date)) == date, "version file names round-trip")
    check(SyncPath.originalPath(ofConflictCopy: "a/report.sync-conflict-20260102-030405-My Mac.docx") == "a/report.docx"
          && SyncPath.originalPath(ofConflictCopy: "Makefile.sync-conflict-20260102-030405-M") == "Makefile"
          && SyncPath.isConflictCopy("x/y.sync-conflict-1-2.txt") && !SyncPath.isConflictCopy("sync-conflict.txt"),
          "conflict copy names are recognised")
    check(SyncPath.isMarkerPath(".OneSwitch/x") && !SyncPath.isValidRelative(".ONESWITCH") && !m.isIgnored("a/.oneswitch2"),
          "marker directory protected case-insensitively")
    check(SyncPath.isTempName(SyncPath.tempName(for: "报告 v2.docx")) && !SyncPath.isTempName("notes.oneswitch-tmp")
          && !SyncPath.isTempName(".x.1234567g.oneswitch-tmp"), "our temp file names are recognised exactly")

    print("Protocol codec")
    let rec = FileRecord(path: "目录/a b.txt", kind: .file, size: 12, mtimeNS: 1_700_000_000_123_456_789, mode: 0o755,
                         hash: h1, version: VersionVector(["A": 3]), sequence: 9)
    let wire = SyncProtocol.Record(rec)
    let decoded = SyncProtocol.decode(SyncProtocol.Record.self, SyncProtocol.encode(wire)!)?.toRecord()
    check(decoded == rec, "index record round-trips through JSON")
    var bad = wire
    bad.path = "../../etc/passwd"
    check(bad.toRecord() == nil, "record with escaping path rejected")
    bad = wire
    bad.hash = "zz"
    check(bad.toRecord() == nil, "record with malformed hash rejected")
    var frame = Data(count: SyncProtocol.blockHeaderSize + 3)
    frame.replaceSubrange(SyncProtocol.blockHeaderSize..<frame.count, with: [7, 8, 9])
    SyncProtocol.writeBlockHeader(into: &frame, requestID: 0x0102_0304_0506_0708, status: .ok)
    let parsed = SyncProtocol.parseBlockResponse(frame)
    check(parsed?.requestID == 0x0102_0304_0506_0708 && parsed?.status == .ok && parsed.map { Array($0.data) } == [7, 8, 9],
          "binary block frame round-trips")
    check(Hex.decode(Hex.encode(h2)) == h2 && Hex.decode("abc") == nil, "hex codec")
    let batch = SyncProtocol.Index(folder: "f", indexID: 1, reset: nil, last: nil, more: true, records: [wire])
    let batchJSON = String(decoding: SyncProtocol.encode(batch)!, as: UTF8.self)
    check(batchJSON.contains("\"m\":true") && SyncProtocol.decode(SyncProtocol.Index.self, Data(batchJSON.utf8))?.more == true
          && SyncProtocol.decode(SyncProtocol.Index.self, Data(#"{"f":"f","i":1,"s":[]}"#.utf8))?.more == nil,
          "index batches carry \"more\" (absent from older peers)")
    let hello = SyncProtocol.Hello(v: 1, device: "D", name: "N", folders: [], more: true)
    let helloJSON = String(decoding: SyncProtocol.encode(hello)!, as: UTF8.self)
    check(helloJSON.contains("\"more\":true") && SyncProtocol.decode(SyncProtocol.Hello.self, Data(helloJSON.utf8))?.more == true
          && SyncProtocol.decode(SyncProtocol.Hello.self, Data(#"{"v":1,"device":"D","name":"N","folders":[]}"#.utf8)).map { $0.more == nil } == true,
          "hello announces \"more\" support (absent from older peers, still decoded)")

    print("IndexStore")
    let dbDir = URL(fileURLWithPath: realTempRoot + "/db-check")
    do {
        let store = try IndexStore(directory: dbDir)
        store.batch {
            for (i, p) in ["a", "a/b", "a/b/c.txt", "a/bc.txt", "a0", "Readme.md"].enumerated() {
                store.upsert(.local, folder: "f", FileRecord(path: p, kind: p.contains(".") ? .file : .directory, size: 10,
                                                             hash: p.contains(".") ? h1 : nil, version: VersionVector(["A": UInt64(i + 1)]),
                                                             sequence: Int64(i + 1)))
            }
            store.upsert(.remote, folder: "f", FileRecord(path: "README.md", kind: .file, size: 1, hash: h2, sequence: 1))
            store.upsert(.remote, folder: "f", FileRecord(path: "readme.md", kind: .file, size: 1, hash: h1, sequence: 2))
            store.setMeta("k", "v")
        }
        check(Set(store.records(.local, folder: "f", under: "a/b").map(\.path)) == ["a/b", "a/b/c.txt"], "subtree query excludes siblings with same prefix")
        check(store.records(.local, folder: "f", afterSequence: 3, limit: 2).map(\.sequence) == [4, 5], "records after sequence, ordered, limited")
        check(store.caseVariants(.remote, folder: "f", path: "README.md") == ["readme.md"], "case variants")
        check(store.localFiles(folder: "f", hash: h1).count == 3, "lookup by content hash")
        let totals = store.totals(folder: "f")
        check(totals.files == 3 && totals.directories == 3 && totals.bytes == 30, "totals")
        store.close()
        let reopened = try IndexStore(directory: dbDir)
        check(reopened.record(.local, folder: "f", path: "a/b/c.txt")?.version == VersionVector(["A": 3]) && reopened.meta("k") == "v",
              "records and meta persist across reopen")
        reopened.dropFolder("f")
        check(reopened.count(.local, folder: "f") == 0 && reopened.count(.remote, folder: "f") == 0, "dropFolder clears a folder")
        reopened.close()
    } catch {
        check(false, "IndexStore opens: \(error)")
    }

    print("Scanner")
    let scanRoot = realTempRoot + "/scan-check"
    try? fm.createDirectory(atPath: scanRoot + "/.oneswitch", withIntermediateDirectories: true)
    write(scanRoot, "x/y.txt", "hello")
    write(scanRoot, "x/.DS_Store", "junk")
    try? fm.createSymbolicLink(atPath: scanRoot + "/ln", withDestinationPath: "x/y.txt")
    let job = ScanJob(folderID: "s", root: scanRoot, matcher: IgnoreMatcher(userPatterns: []), roots: [""], snapshot: [:],
                      settleTime: 1, settleMinSize: 1 << 20, isFull: true, caseSensitive: FS.isCaseSensitive(scanRoot))
    let out = Scanner.run(job) { false }
    let byPath = Dictionary(out.changes.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    check(Set(byPath.keys) == ["x", "x/y.txt", "ln"], "full scan finds dir, file, symlink (ignores .DS_Store, marker)")
    if case .present(_, let hash)? = byPath["x/y.txt"]?.observed {
        check(hash.map(Hex.encode) == sha(Data("hello".utf8)), "file hashed with SHA-256")
    } else {
        check(false, "file observed")
    }
    if case .present(let d, _)? = byPath["ln"]?.observed { check(d.kind == .symlink && d.target == "x/y.txt", "symlink not followed") }
    var snap: [String: QuickRecord] = [:]
    for c in out.changes {
        if case .present(let d, let h) = c.observed {
            snap[c.path] = QuickRecord(kind: d.kind, size: d.size, mtimeNS: d.mtimeNS, mode: d.mode, hash: h, target: d.target, deleted: false)
        }
    }
    let job2 = ScanJob(folderID: "s", root: scanRoot, matcher: IgnoreMatcher(userPatterns: []), roots: [""], snapshot: snap,
                       settleTime: 1, settleMinSize: 1 << 20, isFull: true, caseSensitive: job.caseSensitive)
    let out2 = Scanner.run(job2) { false }
    check(out2.changes.isEmpty && out2.hashedFiles == 0, "rescan with matching index: no changes, nothing hashed")
    var snapGone = snap
    for p in ["gone", "gone/a", "gone/a/b.txt", "gone/c.txt", "gone/a/d"] {
        snapGone[p] = QuickRecord(kind: p.hasSuffix(".txt") ? .file : .directory, size: 1, mtimeNS: 1, mode: 0o644,
                                  hash: nil, target: nil, deleted: false)
    }
    let jobGone = ScanJob(folderID: "s", root: scanRoot, matcher: IgnoreMatcher(userPatterns: []), roots: [""], snapshot: snapGone,
                          settleTime: 1, settleMinSize: 1 << 20, isFull: true, caseSensitive: job.caseSensitive)
    let gone = Scanner.run(jobGone) { false }.changes.map(\.path)
    check(gone == ["gone/a/b.txt", "gone/a/d", "gone/a", "gone/c.txt", "gone"],
          "deletions reported children-first, so a directory's tombstone follows its children's (\(gone))")
    // Dataless placeholders (iCloud "optimized storage") are never hashed (reading = downloading), never
    // indexed and never reported as deleted.
    write(scanRoot, "x/cloud-only.bin", randomData(4096))
    let cloudAbs = scanRoot + "/x/cloud-only.bin"
    _ = FS.simulatedDataless.withLock { $0.insert(cloudAbs) }
    let out2b = Scanner.run(job2) { false }
    check(out2b.dataless == ["x/cloud-only.bin"] && out2b.hashedFiles == 0 && !out2b.changes.contains { $0.path == "x/cloud-only.bin" },
          "new dataless file: not hashed, not indexed, reported (\(out2b.dataless))")
    var snapWithCloud = snap
    if let d = FS.entry(cloudAbs) {
        snapWithCloud["x/cloud-only.bin"] = QuickRecord(kind: .file, size: d.size + 1, mtimeNS: d.mtimeNS, mode: d.mode,
                                                        hash: Data(repeating: 9, count: 32), target: nil, deleted: false)
    }
    let jobCloud = ScanJob(folderID: "s", root: scanRoot, matcher: IgnoreMatcher(userPatterns: []), roots: [""], snapshot: snapWithCloud,
                           settleTime: 1, settleMinSize: 1 << 20, isFull: true, caseSensitive: job.caseSensitive)
    let out2c = Scanner.run(jobCloud) { false }
    check(out2c.changes.isEmpty && out2c.hashedFiles == 0 && out2c.dataless == ["x/cloud-only.bin"],
          "indexed file changed while evicted: left alone (no hash, no change, not missing)")
    check((try? FS.sha256(path: cloudAbs)) == nil, "sha256 refuses to read a dataless file")
    let serveItem = ServeItem(requestID: 7, absolutePath: cloudAbs, offset: 0, length: 16, size: FS.entry(cloudAbs)!.size,
                              mtimeNS: FS.entry(cloudAbs)!.mtimeNS)
    check(SyncProtocol.parseBlockResponse(SyncEngine.readBlock(serveItem))?.status == .unavailable,
          "a dataless file is not served (peer gets 'unavailable', nothing is downloaded)")
    FS.simulatedDataless.withLock { $0.removeAll() }
    check(SyncProtocol.parseBlockResponse(SyncEngine.readBlock(serveItem))?.status == .ok, "served once downloaded")
    try? fm.removeItem(atPath: cloudAbs)

    // Large files still being written wait to settle — but an mtime in the future is not "recent".
    write(scanRoot, "x/future.bin", randomData(2 << 20), mtime: Date().addingTimeInterval(86_400 * 365))
    write(scanRoot, "x/fresh.bin", randomData(2 << 20))
    let out2d = Scanner.run(job2) { false }
    check(out2d.changes.contains { $0.path == "x/future.bin" } && !out2d.deferred.contains("x/future.bin"),
          "large file with a future mtime is hashed, not deferred forever")
    check(out2d.deferred == ["x/fresh.bin"], "large file modified just now waits to settle (\(out2d.deferred))")
    try? fm.removeItem(atPath: scanRoot + "/x/future.bin")
    try? fm.removeItem(atPath: scanRoot + "/x/fresh.bin")

    try? fm.removeItem(atPath: scanRoot + "/.oneswitch")
    let out3 = Scanner.run(job2) { false }
    check(out3.markerMissing && out3.changes.isEmpty, "missing marker: scan aborted, no deletions reported")

    print("FS helpers")
    if case .failure(let code) = FS.listDirectory(scanRoot + "/does-not-exist") {
        check(code == ENOENT, "listing a missing directory fails (never an empty success)")
    } else {
        check(false, "listing a missing directory fails")
    }
    write(scanRoot, "ren/a.txt", "A")
    write(scanRoot, "ren/b.txt", "B")
    check(!FS.renameExclusive(scanRoot + "/ren/a.txt", scanRoot + "/ren/b.txt") && errno == EEXIST
          && read(scanRoot, "ren/b.txt") == "B" && read(scanRoot, "ren/a.txt") == "A",
          "exclusive rename never replaces an existing entry")
    let preEpoch: Int64 = -1_500_000_001
    let ts = FS.timespec(ns: preEpoch)
    check(ts.tv_sec == -2 && ts.tv_nsec == 499_999_999, "timespec for a pre-1970 mtime is normalized")
    check(FS.setModificationTime(scanRoot + "/ren/a.txt", ns: preEpoch) && FS.entry(scanRoot + "/ren/a.txt")?.mtimeNS == preEpoch,
          "pre-1970 mtime applied exactly")
    check(SyncEngine.directoryMode(0o555) == 0o755 && SyncEngine.directoryMode(0o700) == 0o700 && SyncEngine.directoryMode(0) == 0o755,
          "synced directories always stay writable by the owner")
    check(SyncProtocol.isValidFolderID("docs-7f3a2c") && !SyncProtocol.isValidFolderID("a.b")
          && !SyncProtocol.isValidFolderID("") && !SyncProtocol.isValidFolderID("x/y") && !SyncProtocol.isValidFolderID("文档"),
          "peer folder ids validated")

    print("Index database recovery")
    let recDir = URL(fileURLWithPath: realTempRoot + "/db-recovery")
    try? fm.createDirectory(at: recDir, withIntermediateDirectories: true)
    try? Data("this is not a database, just garbage bytes".utf8).write(to: recDir.appendingPathComponent("index.sqlite"))
    do {
        let (store, recovered) = try IndexStore.open(directory: recDir)
        store.upsert(.local, folder: "f", FileRecord(path: "a", kind: .directory, version: VersionVector(["A": 1]), sequence: 1))
        check(recovered && store.count(.local, folder: "f") == 1, "garbage index file: rebuilt and usable")
        let names = (try? fm.contentsOfDirectory(atPath: recDir.path)) ?? []
        check(names.contains { $0.hasPrefix("index.sqlite.corrupt-") }, "damaged index kept aside for diagnosis (\(names.sorted()))")
        // Fill enough rows to span many pages, then damage a page in the middle of the file.
        store.batch {
            for i in 0..<3000 {
                store.upsert(.local, folder: "f", FileRecord(path: "dir/some/longer/path/file-\(i).txt", kind: .file, size: Int64(i),
                                                             hash: Data(repeating: UInt8(i % 256), count: 32),
                                                             version: VersionVector(["A": UInt64(i + 1)]), sequence: Int64(i + 2)))
            }
            store.setMeta("folder.a.b.path", "/x")
        }
        check(store.folderIDs().contains("a.b") && store.folderIDs().contains("f"), "folder ids with dots parsed from meta keys")
        store.close()
        let dbPath = recDir.appendingPathComponent("index.sqlite").path
        if let h = FileHandle(forUpdatingAtPath: dbPath) {
            let size = (try? h.seekToEnd()) ?? 0
            for percent: UInt64 in [15, 30, 45, 60, 75, 90] {
                try? h.seek(toOffset: max(4096, size * percent / 100 / 4096 * 4096))
                h.write(randomData(4096 * 2))
            }
            try? h.close()
        }
        let raw = try IndexStore(directory: recDir) // no integrity check
        var seen = 0
        raw.forEach(.local, folder: "f") { _ in seen += 1 }
        check(raw.corruptionDetected, "corruption noticed at runtime (read \(seen) of 3001 rows)")
        raw.close()
        let (again, recoveredAgain) = try IndexStore.open(directory: recDir)
        check(recoveredAgain && again.count(.local, folder: "f") == 0 && !again.corruptionDetected,
              "damaged pages caught by the integrity check at open → rebuilt")
        again.flagForRebuild()
        again.close()
        let (third, recoveredThird) = try IndexStore.open(directory: recDir)
        check(recoveredThird && !FS.exists(recDir.path + "/index.rebuild"), "a database flagged for rebuild is rebuilt on the next open")
        third.close()
    } catch {
        check(false, "index recovery: \(error)")
    }

    print("PullQueue")
    var q = PullQueue()
    let k1 = PullKey(folder: "f", path: "1"), k2 = PullKey(folder: "f", path: "2"), k3 = PullKey(folder: "g", path: "3")
    let hx = Data(repeating: 1, count: 32), hy = Data(repeating: 2, count: 32)
    q.append(k1, size: 1, hash: hx); q.append(k2, size: 2, hash: hx); q.append(k3, size: 3, hash: hy); q.append(k1, size: 10, hash: hy)
    check(q.keys(withHash: hx) == [k2] && q.keys(withHash: hy) == [k1, k3], "queued files found by content hash (re-queued with a new hash)")
    q.remove(k2)
    check(q.keys(withHash: hx).isEmpty, "removed files leave the hash index")
    check(q.count == 2 && q.popFirst() == k1 && q.popFirst() == k3 && q.popFirst() == nil, "FIFO with dedupe and lazy removal")
    check(q.keys(withHash: hy).isEmpty, "popped files leave the hash index")
    q.append(k1, size: 1, hash: hx); q.append(k3, size: 3, hash: hx)
    q.removeAll(folder: "f")
    check(q.keys(withHash: hx) == [k3] && q.count == 1, "removing a folder's pulls updates the hash index")
}

// MARK: - Integration checks

@MainActor
func integrationChecks() {
    let folderID = "docs-7f3a2c"
    let pair = Pair(name: "main", folderID: folderID)
    let A = pair.dirA, B = pair.dirB
    let caseSensitive = FS.isCaseSensitive(A)

    print("Initial sync (both directions)")
    let big = randomData(20 * 1024 * 1024)
    let old = Date().addingTimeInterval(-3600)
    write(A, "docs/nested/deep/file.txt", "deep file v1", mtime: old)
    try? fm.createDirectory(atPath: A + "/empty-dir", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: A + "/docs/empty-sub", withIntermediateDirectories: true)
    write(A, "empty.txt", Data(), mtime: old)
    write(A, "big.bin", big, mtime: old)
    write(A, "中文文件名.txt", "你好，世界", mtime: old)
    write(A, "name with spaces 🎉.txt", "emoji", mtime: old)
    write(A, "exec.sh", Data("#!/bin/sh\necho hi\n".utf8), mtime: old, mode: 0o755)
    try? fm.createSymbolicLink(atPath: A + "/link-to-file", withDestinationPath: "docs/nested/deep/file.txt")
    write(B, "from-b/b1.txt", "from B", mtime: old)
    write(B, "b-only.txt", "B only", mtime: old)

    var start = Date()
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) }, "engines connect and share the folder")
    if let t = pair.converge(90) {
        timed("initial sync (20 MB + 10 entries, both directions)", Date().timeIntervalSince(start))
        _ = t
    }
    var ta = pair.treeA, tb = pair.treeB
    check(ta == tb, "trees identical after initial sync — \(treeDiff(ta, tb))")
    check(ta["big.bin"]?.content == sha(big) && tb["docs/empty-sub"]?.kind == "d" && tb["empty-dir"]?.kind == "d",
          "20 MB file, empty directories replicated")
    check(tb["empty.txt"]?.content == sha(Data()) && read(B, "中文文件名.txt") == "你好，世界" && read(B, "name with spaces 🎉.txt") == "emoji",
          "empty file, Chinese and emoji names replicated")
    check(tb["link-to-file"] == TreeEntry(kind: "l", content: "docs/nested/deep/file.txt", mtimeNS: ta["link-to-file"]!.mtimeNS, mode: 0),
          "symlink replicated as a symlink (not followed)")
    check(tb["exec.sh"]?.mode == 0o755 && tb["big.bin"]?.mtimeNS == ta["big.bin"]?.mtimeNS, "mode and ns mtime preserved")
    check(read(A, "from-b/b1.txt") == "from B", "B → A direction")
    var sa = pair.engineA.snapshotNow(), sb = pair.engineB.snapshotNow()
    check(sa.stats.conflictsCreated == 0 && sb.stats.conflictsCreated == 0, "no conflicts on initial sync")
    check(sb.stats.blockBytesReceived >= Int64(big.count) && sb.stats.blockBytesReceived < Int64(big.count) + 4096,
          "B received the 20 MB exactly once (\(sb.stats.blockBytesReceived) bytes)")
    check(waitUntil(3) { pair.engineA.snapshotNow().folders.first?.state == .idle && pair.engineB.snapshotNow().folders.first?.state == .idle },
          "both folders report 空闲·已同步 (\(pair.engineA.snapshotNow().folders.first?.state.displayText ?? "?"))")
    sa = pair.engineA.snapshotNow()
    check(sa.folders.first?.fileCount == 7 + 2 && sa.folders.first?.totalBytes ?? 0 > Int64(big.count), "file count and size reported (\(sa.folders.first?.fileCount ?? -1))")

    print("Modify / delete / rename propagate")
    start = Date()
    write(A, "docs/nested/deep/file.txt", "deep file v2 — modified")
    check(waitUntil(20, poll: 0.05) { read(B, "docs/nested/deep/file.txt") == "deep file v2 — modified" }, "modification A → B")
    timed("single modification latency", Date().timeIntervalSince(start))
    check(pair.converge(30) != nil, "converged after modification")
    let recentB = pair.engineB.snapshotNow().folders.first?.recent.first
    check(recentB?.path == "docs/nested/deep/file.txt" && recentB?.incoming == true, "B lists the change as ↓ in recent changes")

    start = Date()
    try? fm.removeItem(atPath: B + "/b-only.txt")
    check(waitUntil(20) { !exists(A, "b-only.txt") }, "file deletion B → A")
    timed("deletion latency", Date().timeIntervalSince(start))

    try? fm.removeItem(atPath: A + "/docs/nested")
    check(waitUntil(20) { !exists(B, "docs/nested") } && exists(B, "docs/empty-sub"), "directory tree deletion A → B (siblings kept)")

    let clonedBefore = pair.engineA.snapshotNow().stats.filesClonedLocally
    let receivedBefore = pair.engineA.snapshotNow().stats.blockBytesReceived
    try? fm.createDirectory(atPath: B + "/renamed", withIntermediateDirectories: true)
    try? fm.moveItem(atPath: B + "/中文文件名.txt", toPath: B + "/renamed/中文文件名-新.txt")
    try? fm.moveItem(atPath: B + "/big.bin", toPath: B + "/renamed/big-moved.bin")
    check(waitUntil(30) { read(A, "renamed/中文文件名-新.txt") == "你好，世界" && !exists(A, "中文文件名.txt") && exists(A, "renamed/big-moved.bin") && !exists(A, "big.bin") },
          "renames B → A (file + 20 MB file into a new directory)")
    check(pair.converge(30) != nil, "converged after renames — \(treeDiff(pair.treeA, pair.treeB))")
    sa = pair.engineA.snapshotNow()
    check(sa.stats.filesClonedLocally > clonedBefore && sa.stats.blockBytesReceived - receivedBefore < 1024 * 1024,
          "renamed 20 MB file cloned locally, not re-transferred (\(sa.stats.blockBytesReceived - receivedBefore) bytes received)")

    print("Echo suppression")
    check(pair.converge(30) != nil, "converged")
    spin(0.6)
    let before = (pair.engineA.snapshotNow().stats, pair.engineB.snapshotNow().stats)
    spin(2.0)
    let after = (pair.engineA.snapshotNow().stats, pair.engineB.snapshotNow().stats)
    check(before.0.messagesSent == after.0.messagesSent && before.1.messagesSent == after.1.messagesSent
          && before.0.messagesReceived == after.0.messagesReceived,
          "no sync messages for 2 s after convergence (A sent \(after.0.messagesSent - before.0.messagesSent), B sent \(after.1.messagesSent - before.1.messagesSent))")
    check(after.0.filesHashed == before.0.filesHashed && after.1.filesHashed == before.1.filesHashed, "no rescans / re-hashing while idle")

    print("Concurrent edit → one conflict copy")
    write(A, "conflict.txt", "base", mtime: old)
    check(waitUntil(20) { read(B, "conflict.txt") == "base" } && pair.converge(30) != nil, "base version synced")
    pair.hubA.setLinked(false)
    check(waitUntil(5) { !pair.engineA.snapshotNow().connected && !pair.engineB.snapshotNow().connected }, "cable unplugged")
    let tA = Date().addingTimeInterval(-100), tB = Date().addingTimeInterval(-50)
    write(A, "conflict.txt", "edited on A", mtime: tA)
    write(B, "conflict.txt", "edited on B (later)", mtime: tB)
    // Delete-vs-modify and offline edits on both sides in the same offline period.
    write(A, "dvm.txt", "x", mtime: old) // created offline on A only (will sync after reconnect)
    check(waitUntil(15) {
        pair.engineA.localRecord(folderID: folderID, path: "conflict.txt")?.hash.map(Hex.encode) == sha(Data("edited on A".utf8))
            && pair.engineB.localRecord(folderID: folderID, path: "conflict.txt")?.hash.map(Hex.encode) == sha(Data("edited on B (later)".utf8))
    }, "both offline edits indexed locally")
    start = Date()
    pair.hubA.setLinked(true)
    let conv = pair.converge(40)
    check(conv != nil, "converged after reconnect — \(treeDiff(pair.treeA, pair.treeB))")
    timed("reconnect + conflict resolution", Date().timeIntervalSince(start))
    ta = pair.treeA
    let copies = conflictCopies(ta)
    check(copies.count == 1, "exactly one conflict copy: \(copies)")
    check(read(A, "conflict.txt") == "edited on B (later)" && read(B, "conflict.txt") == "edited on B (later)", "later mtime wins on both Macs")
    if let copy = copies.first {
        check(read(A, copy) == "edited on A" && copy.hasPrefix("conflict.sync-conflict-") && copy.hasSuffix("-Mac Studio.txt"),
              "loser content preserved as \(copy)")
    }
    let conflictsA = pair.engineA.snapshotNow().folders.first?.conflicts ?? []
    let conflictsB = pair.engineB.snapshotNow().folders.first?.conflicts ?? []
    check(conflictsA.count == 1 && conflictsB.count == 1 && conflictsA.first?.originalPath == "conflict.txt"
          && conflictsB.first?.originalPath == "conflict.txt",
          "conflict listed for the UI on both Macs (original: \(conflictsB.first?.originalPath ?? "-"))")
    check(pair.engineA.snapshotNow().stats.conflictsCreated == 1 && pair.engineB.snapshotNow().stats.conflictsCreated == 0,
          "only the losing Mac created a conflict copy")

    print("Delete vs modify")
    check(pair.converge(30) != nil && read(B, "dvm.txt") == "x", "file synced")
    pair.hubA.setLinked(false)
    _ = waitUntil(5) { !pair.engineA.snapshotNow().connected }
    try? fm.removeItem(atPath: A + "/dvm.txt")
    write(B, "dvm.txt", "modified on B")
    check(waitUntil(15) {
        pair.engineA.localRecord(folderID: folderID, path: "dvm.txt")?.deleted == true
            && pair.engineB.localRecord(folderID: folderID, path: "dvm.txt")?.hash.map(Hex.encode) == sha(Data("modified on B".utf8))
    }, "offline delete (A) and modify (B) indexed")
    pair.hubA.setLinked(true)
    check(pair.converge(40) != nil, "converged — \(treeDiff(pair.treeA, pair.treeB))")
    check(read(A, "dvm.txt") == "modified on B" && read(B, "dvm.txt") == "modified on B" && conflictCopies(pair.treeA).count == 1,
          "modification survives on both, no extra conflict copy")
    // Deleting the conflict copy (after reviewing it) clears the conflict on both Macs.
    if let copy = conflictCopies(pair.treeA).first { try? fm.removeItem(atPath: B + "/" + copy) }
    check(waitUntil(15) {
        conflictCopies(pair.treeA).isEmpty && pair.engineA.snapshotNow().folders.first?.conflicts.isEmpty == true
            && pair.engineB.snapshotNow().folders.first?.conflicts.isEmpty == true
    }, "deleted conflict copy disappears from both conflict lists")

    print("Directory deleted on one side, file inside modified on the other")
    write(A, "keepdir/x.txt", "x v1", mtime: old)
    write(A, "keepdir/y.txt", "y v1", mtime: old)
    check(waitUntil(20) { read(B, "keepdir/x.txt") == "x v1" && read(B, "keepdir/y.txt") == "y v1" } && pair.converge(30) != nil,
          "directory synced")
    pair.hubA.setLinked(false)
    _ = waitUntil(5) { !pair.engineA.snapshotNow().connected }
    try? fm.removeItem(atPath: A + "/keepdir")
    write(B, "keepdir/x.txt", "x modified on B")
    check(waitUntil(15) {
        pair.engineA.localRecord(folderID: folderID, path: "keepdir")?.deleted == true
            && pair.engineB.localRecord(folderID: folderID, path: "keepdir/x.txt")?.hash.map(Hex.encode) == sha(Data("x modified on B".utf8))
    }, "offline directory deletion (A) and modification inside it (B) indexed")
    pair.hubA.setLinked(true)
    check(pair.converge(40) != nil, "converged — \(treeDiff(pair.treeA, pair.treeB))")
    check(read(A, "keepdir/x.txt") == "x modified on B" && read(B, "keepdir/x.txt") == "x modified on B" && !exists(B, "keepdir/y.txt"),
          "modified file survives with its directory, the untouched sibling is deleted")

    print("Offline edits on both sides converge")
    pair.hubA.setLinked(false)
    _ = waitUntil(5) { !pair.engineA.snapshotNow().connected }
    write(A, "offline/a1.txt", "made on A offline")
    write(A, "exec.sh", Data("#!/bin/sh\necho changed on A\n".utf8), mode: 0o755)
    write(B, "offline/b1.txt", "made on B offline")
    try? fm.removeItem(atPath: B + "/empty.txt")
    check(waitUntil(15) {
        pair.engineA.localRecord(folderID: folderID, path: "offline/a1.txt") != nil
            && pair.engineB.localRecord(folderID: folderID, path: "offline/b1.txt") != nil
            && pair.engineB.localRecord(folderID: folderID, path: "empty.txt")?.deleted == true
    }, "offline changes indexed")
    start = Date()
    pair.hubA.setLinked(true)
    check(pair.converge(40) != nil, "converged after offline edits — \(treeDiff(pair.treeA, pair.treeB))")
    timed("offline edits reconciliation", Date().timeIntervalSince(start))
    check(read(B, "offline/a1.txt") == "made on A offline" && read(A, "offline/b1.txt") == "made on B offline"
          && !exists(A, "empty.txt") && read(B, "exec.sh")?.contains("changed on A") == true, "all offline changes applied")

    print("Ignore patterns")
    pair.foldersA[0].ignorePatterns = ["*.log", "build"]
    pair.foldersB[0].ignorePatterns = ["*.log", "build"]
    pair.engineA.update(folders: pair.foldersA)
    pair.engineB.update(folders: pair.foldersB)
    spin(0.5)
    write(A, "app.log", "log line")
    write(A, "build/out.o", "object")
    write(A, "src/build/inner.o", "object")
    write(A, "keep.txt", "keep me")
    write(B, "local.log", "B log")
    check(waitUntil(20) { read(B, "keep.txt") == "keep me" }, "non-ignored file synced")
    pair.excludeA = { $0.hasSuffix(".log") || $0 == "build" || $0.hasPrefix("build/") || $0 == "src/build" || $0.hasPrefix("src/build/") }
    pair.excludeB = pair.excludeA
    check(pair.converge(30) != nil, "converged (ignoring ignored files)")
    spin(1.0)
    check(!exists(B, "app.log") && !exists(B, "build") && !exists(B, "src/build") && !exists(A, "local.log"), "ignored files never transferred")
    check(pair.engineA.localRecord(folderID: folderID, path: "app.log") == nil, "ignored files are not indexed")

    print("Versioning (.oneswitch/versions)")
    pair.foldersB[0].versioning = .versions
    pair.engineB.update(folders: pair.foldersB)
    spin(0.3)
    write(A, "keep.txt", "keep me v2")
    check(waitUntil(20) { read(B, "keep.txt") == "keep me v2" }, "update applied")
    let versionsDir = B + "/.oneswitch/versions"
    let versions = (try? fm.contentsOfDirectory(atPath: versionsDir)) ?? []
    check(versions.count == 1 && versions.first?.hasPrefix("keep~") == true && read(versionsDir, versions.first ?? "") == "keep me",
          "overwritten file kept as \(versions)")
    pair.foldersB[0].versioning = .none
    pair.engineB.update(folders: pair.foldersB)

    print("Pause / resume")
    pair.foldersB[0].paused = true
    pair.engineB.update(folders: pair.foldersB)
    check(waitUntil(5) { pair.engineB.snapshotNow().folders.first?.state == .paused }, "B shows 已暂停")
    write(A, "while-paused.txt", "p")
    spin(1.5)
    check(!exists(B, "while-paused.txt"), "paused folder does not apply remote changes")
    pair.foldersB[0].paused = false
    pair.engineB.update(folders: pair.foldersB)
    check(waitUntil(20) { read(B, "while-paused.txt") == "p" }, "resumed folder catches up")

    print("2 000 small files")
    check(pair.converge(30) != nil, "converged before bulk test")
    let snapCountBefore = pair.snapshotTimesA.value.count
    start = Date()
    for i in 0..<2000 {
        write(A, String(format: "many/sub%02d/f%04d.txt", i % 20, i), randomData(64 + i % 512))
    }
    let created = Date().timeIntervalSince(start)
    start = Date()
    check(waitUntil(120, poll: 0.2) {
        ((try? fm.subpathsOfDirectory(atPath: B + "/many")) ?? []).filter { $0.hasSuffix(".txt") }.count == 2000
    }, "2 000 files arrived on B")
    let arrived = Date().timeIntervalSince(start)
    check(pair.converge(60) != nil, "converged after 2 000 files — \(treeDiff(pair.treeA, pair.treeB))")
    timed("2 000 small files (after writing them in \(String(format: "%.1f", created)) s)", arrived)
    let times = Array(pair.snapshotTimesA.value.dropFirst(snapCountBefore))
    let minGap = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }.min() ?? 1
    check(times.count >= 2 && minGap >= 0.24, "UI snapshots throttled to ≤ 4/s (\(times.count) snapshots, min gap \(String(format: "%.3f", minGap)) s)")

    print("Missing marker / root → nothing propagated")
    check(pair.converge(30) != nil, "converged")
    let treeBBefore = pair.treeB
    try? fm.removeItem(atPath: A + "/.oneswitch")
    check(waitUntil(10) { pair.engineA.snapshotNow().folders.first?.state == .error(SyncEngine.missingRootMessage) },
          "A reports 错误：文件夹不存在或已被移动")
    try? fm.moveItem(atPath: A + "/keep.txt", toPath: realTempRoot + "/keep-aside.txt")
    try? fm.removeItem(atPath: A + "/many")
    spin(2.5)
    check(pair.treeB == treeBBefore, "B untouched while A's marker is missing (no deletions propagated)")
    try? fm.moveItem(atPath: realTempRoot + "/keep-aside.txt", toPath: A + "/keep.txt")
    // The user restores the files and the marker (e.g. re-plugs the disk): A resumes without deleting anything.
    let manyBack = realTempRoot + "/many-restore"
    try? fm.copyItem(atPath: B + "/many", toPath: manyBack)
    try? fm.moveItem(atPath: manyBack, toPath: A + "/many")
    try? fm.createDirectory(atPath: A + "/.oneswitch", withIntermediateDirectories: true)
    check(waitUntil(15) { pair.engineA.snapshotNow().folders.first?.state == .idle }, "A recovers once the marker is back")
    check(pair.converge(40) != nil && exists(B, "keep.txt") && exists(B, "many/sub00/f0000.txt"), "trees converge again, nothing lost")

    let movedA = realTempRoot + "/main-A-moved"
    try? fm.moveItem(atPath: A, toPath: movedA)
    check(waitUntil(10) { pair.engineA.snapshotNow().folders.first?.state.isError == true }, "moving the whole root → error")
    spin(2.0)
    check(pair.treeB == treeBBefore.merging([:]) { a, _ in a } || exists(B, "keep.txt"), "B still has all files while A's root is gone")
    check(exists(B, "many/sub05/f0005.txt") && exists(B, "keep.txt") && exists(B, "offline/a1.txt"), "no mass deletion reached B")
    write(B, "new-while-A-gone/n.txt", "new")
    spin(2.0)
    check(!exists(realTempRoot, "main-A"), "a pull never re-creates the missing root")
    try? fm.moveItem(atPath: movedA, toPath: A)
    check(waitUntil(15) { pair.engineA.snapshotNow().folders.first?.state == .idle }, "A recovers when the root is back")
    check(pair.converge(40) != nil && read(A, "new-while-A-gone/n.txt") == "new", "converged after root restored (missed change applied)")

    print("Folder offer")
    let offerID = "photos-00beef"
    let A2 = realTempRoot + "/offer-A", B2 = realTempRoot + "/offer-B"
    try? fm.createDirectory(atPath: B2, withIntermediateDirectories: true)
    write(A2, "photo.jpg", randomData(300_000))
    pair.foldersA.append(FolderConfig(id: offerID, label: "照片", path: A2, versioning: .none))
    pair.engineA.update(folders: pair.foldersA)
    check(waitUntil(10) { pair.engineB.snapshotNow().offers.contains { $0.id == offerID && $0.label == "照片" && $0.peerName == "Mac Studio" } },
          "B sees the pending offer 对方共享了文件夹「照片」")
    check(pair.engineA.snapshotNow().folders.first { $0.id == offerID }?.state == .waitingForShare, "A waits for B to accept")
    pair.foldersB.append(FolderConfig(id: offerID, label: "照片", path: B2, versioning: .none))
    pair.engineB.update(folders: pair.foldersB)
    check(waitUntil(20) { tree(A2) == tree(B2) && exists(B2, "photo.jpg") }, "accepted offer syncs")
    check(pair.engineB.snapshotNow().offers.isEmpty, "offer disappears once accepted")

    print("Restart with persisted index")
    check(pair.converge(30) != nil, "converged before restart")
    let indexSentBefore = pair.engineA.snapshotNow().stats.indexRecordsSent
    pair.engineB.stop()
    check(waitUntil(5) { !pair.engineA.snapshotNow().connected }, "A notices B stopped")
    let restartData = randomData(123_457)
    write(A, "restart.bin", restartData)
    spin(1.0)
    start = Date()
    let engineB2 = pair.makeEngineB()
    pair.engineB = engineB2
    engineB2.start(folders: pair.foldersB)
    check(pair.converge(60) != nil, "restarted engine converges — \(treeDiff(pair.treeA, pair.treeB))")
    timed("restart + catch-up", Date().timeIntervalSince(start))
    let sb2 = engineB2.snapshotNow().stats
    check(sb2.blockBytesReceived == Int64(restartData.count), "only the new file transferred (\(sb2.blockBytesReceived) bytes)")
    check(sb2.filesHashed == 0, "persisted index: no re-hashing on restart (\(sb2.filesHashed) files hashed)")
    let indexDelta = pair.engineA.snapshotNow().stats.indexRecordsSent - indexSentBefore
    check(indexDelta < 20, "incremental index exchange after restart (\(indexDelta) records sent, index has 2 000+)")
    check(sb2.indexRecordsReceived < 20, "B received only new index records (\(sb2.indexRecordsReceived))")

    print("Case-insensitive volume")
    if caseSensitive {
        print("  (temp volume is case-sensitive; case checks covered by the fake-peer test)")
    } else {
        write(A, "Readme.md", "readme", mtime: old)
        check(waitUntil(20) { read(B, "Readme.md") == "readme" } && pair.converge(30) != nil, "file synced")
        try? fm.moveItem(atPath: A + "/Readme.md", toPath: A + "/README.md")
        check(waitUntil(20) {
            ((try? fm.contentsOfDirectory(atPath: B)) ?? []).contains("README.md")
        }, "case-only rename propagates")
        check(pair.converge(30) != nil, "converged after case-only rename — \(treeDiff(pair.treeA, pair.treeB))")
    }

    pair.stop()
    check(!exists(A, ".oneswitch-tmp"), "stopped cleanly")
    let leftovers = ((try? fm.subpathsOfDirectory(atPath: A)) ?? []) + ((try? fm.subpathsOfDirectory(atPath: B)) ?? [])
    check(!leftovers.contains { $0.hasSuffix(".oneswitch-tmp") }, "no temp files left behind")
}

// MARK: - Concurrent edits racing an in-flight update

/// A edits a file while B's (older) edit of the same file is already on its way. A's edit is not indexed
/// yet when B's version arrives (A's scanner waits for the file to settle), so A first tries to pull B's
/// version, notices its local edit, indexes it and finds the two versions concurrent with A winning.
/// The winning side must not announce a vector that dominates B's edit — otherwise B replaces its edit
/// without ever creating a conflict copy (its content silently lost).
@MainActor
func concurrentRaceChecks() {
    print("Concurrent edit racing an incoming update → still exactly one conflict copy")
    let pair = Pair(name: "race", folderID: "race-000001")
    pair.optionsA.settleMinSize = 1   // every file on A must settle for 3 s before it is indexed
    pair.optionsA.settleTime = 3
    let old = Date().addingTimeInterval(-3600)
    write(pair.dirA, "shared.txt", "base", mtime: old)
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial("race-000001") }, "connected")
    check(waitUntil(20) { read(pair.dirB, "shared.txt") == "base" } && pair.converge(30) != nil, "base synced")
    write(pair.dirA, "shared.txt", "edited on A (newest)")                                         // mtime = now
    write(pair.dirB, "shared.txt", "edited on B (older)", mtime: Date().addingTimeInterval(-60))
    check(pair.converge(40) != nil, "converged — \(treeDiff(pair.treeA, pair.treeB))")
    let copies = conflictCopies(pair.treeA)
    check(read(pair.dirA, "shared.txt") == "edited on A (newest)" && read(pair.dirB, "shared.txt") == "edited on A (newest)",
          "newest edit (A) wins on both Macs")
    check(copies.count == 1 && copies.first.map { read(pair.dirB, $0) } == "edited on B (older)",
          "B's losing edit preserved as exactly one conflict copy: \(copies)")
    pair.stop()
}

// MARK: - Bulk directory rename / delete across many index batches

/// Relative paths of every directory at or below `rel` (empty when `rel` does not exist).
func directories(_ root: String, under rel: String) -> [String] {
    guard exists(root, rel) else { return [] }
    let subs = (try? fm.subpathsOfDirectory(atPath: root + "/" + rel)) ?? []
    return [rel] + subs.filter { FS.isDirectory(root + "/" + rel + "/" + $0) }.map { rel + "/" + $0 }.sorted()
}

func entryCount(_ root: String, _ rel: String) -> Int {
    ((try? fm.subpathsOfDirectory(atPath: root + "/" + rel)) ?? []).count
}

/// Regression (v1.0.2, reproduced on the two real Macs): renaming a 50 × 100 tree left an empty skeleton of
/// the old tree on both Macs, and deleting the renamed tree left a skeleton of it too. The remote index
/// arrives in batches; a directory's tombstone could be applied before the tombstones of its children
/// (still in a later batch), so those tracked children counted as "unknown" leftovers, the directory was
/// kept, rescanned as a new directory and re-announced — resurrecting it on the other Mac as well.
/// The batch size is forced down to 100 so each change spans ~100 index messages, and deletions are
/// announced parents-first (the worst case of v1.0.2's unordered tombstones; current senders announce
/// children first) so every directory tombstone arrives before its children's.
@MainActor
func bulkTreeChecks() {
    print("Bulk rename / delete of a 50 × 100 tree across many small index batches")
    let folderID = "bulk-000001"
    let pair = Pair(name: "bulk", folderID: folderID)
    pair.optionsA.indexBatchSize = 100
    pair.optionsB.indexBatchSize = 100
    pair.optionsA.testParentTombstonesFirst = true
    pair.optionsB.testParentTombstonesFirst = true
    pair.foldersB[0].versioning = .versions // B's removed files go to .oneswitch/versions (inside the temp dir)
    let A = pair.dirA, B = pair.dirB
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.converge(30) != nil, "connected and converged")
    func fullScans() -> Int { pair.engineA.snapshotNow().stats.fullScans + pair.engineB.snapshotNow().stats.fullScans }
    /// Full scans both engines may run in `seconds` (one per `minFullScanInterval` each, plus one in flight).
    func fullScanBound(_ seconds: Double) -> Int { 2 * (Int(seconds / testOptions.minFullScanInterval) + 2) }
    func settle(_ timeout: TimeInterval) -> Double? { pair.settle(timeout) }

    // 1. B creates bulk/d1 … d50 with 100 small files each.
    var scans0 = fullScans()
    var start = Date()
    for d in 1...50 {
        for f in 1...100 { write(B, "bulk/d\(d)/f\(f).txt", "d\(d) f\(f)") }
    }
    check(settle(120) != nil && entryCount(A, "bulk") == 5050, "5 000 files in 50 directories synced B → A (\(entryCount(A, "bulk")) entries)")
    timed("50 × 100 tree created on B, synced", Date().timeIntervalSince(start))
    var elapsed = Date().timeIntervalSince(start)
    check(fullScans() - scans0 <= fullScanBound(elapsed),
          "full scans during the burst bounded: \(fullScans() - scans0) in \(String(format: "%.1f", elapsed)) s (≤ \(fullScanBound(elapsed)))")

    // 2. A renames bulk → bulk-renamed.
    scans0 = fullScans()
    let recvBefore = pair.engineB.snapshotNow().stats.blockBytesReceived
    start = Date()
    check(rename(A + "/bulk", A + "/bulk-renamed") == 0, "renamed bulk → bulk-renamed on A")
    let renamed = settle(120)
    elapsed = Date().timeIntervalSince(start)
    timed("rename of the 50 × 100 tree A → B", elapsed)
    check(renamed != nil, "converged after the rename — \(treeDiff(pair.treeA, pair.treeB))")
    check(!exists(A, "bulk") && !exists(B, "bulk"),
          "old tree fully gone on both Macs (left: A \(directories(A, under: "bulk").prefix(4)) B \(directories(B, under: "bulk").prefix(4)))")
    check(entryCount(A, "bulk-renamed") == 5050 && entryCount(B, "bulk-renamed") == 5050 && pair.treeA == pair.treeB,
          "renamed tree complete and identical (A \(entryCount(A, "bulk-renamed")), B \(entryCount(B, "bulk-renamed")) entries)")
    print("    B cloned \(pair.engineB.snapshotNow().stats.filesClonedLocally) files locally, received \(pair.engineB.snapshotNow().stats.blockBytesReceived - recvBefore) block bytes")
    let tombA = pair.engineA.localRecord(folderID: folderID, path: "bulk/d17"), tombB = pair.engineB.localRecord(folderID: folderID, path: "bulk/d17")
    check(tombA?.deleted == true && tombB?.deleted == true && tombA?.version == tombB?.version
          && pair.engineB.localRecord(folderID: folderID, path: "bulk")?.deleted == true,
          "old directories are tombstones in both indexes, B adopted A's deletion (never re-announced them)")
    check(fullScans() - scans0 <= fullScanBound(elapsed),
          "full scans during the rename bounded: \(fullScans() - scans0) in \(String(format: "%.1f", elapsed)) s (≤ \(fullScanBound(elapsed)))")

    // 3. B deletes the renamed tree.
    scans0 = fullScans()
    start = Date()
    try? fm.removeItem(atPath: B + "/bulk-renamed")
    let deleted = settle(120)
    elapsed = Date().timeIntervalSince(start)
    timed("deletion of the 50 × 100 tree B → A", elapsed)
    check(deleted != nil, "converged after the deletion — \(treeDiff(pair.treeA, pair.treeB))")
    check(!exists(A, "bulk-renamed") && !exists(B, "bulk-renamed"),
          "deleted tree fully gone on both Macs (left: A \(directories(A, under: "bulk-renamed").prefix(4)) B \(directories(B, under: "bulk-renamed").prefix(4)))")
    check(pair.treeA == pair.treeB && pair.treeA.isEmpty, "both folders empty and identical (\(pair.treeA.count) entries left)")
    let delA = pair.engineA.localRecord(folderID: folderID, path: "bulk-renamed/d17"), delB = pair.engineB.localRecord(folderID: folderID, path: "bulk-renamed/d17")
    check(delA?.deleted == true && delB?.deleted == true && delA?.version == delB?.version,
          "deleted directories are tombstones on both Macs, A adopted B's deletion (never re-announced them)")
    check(fullScans() - scans0 <= fullScanBound(elapsed),
          "full scans during the deletion bounded: \(fullScans() - scans0) in \(String(format: "%.1f", elapsed)) s (≤ \(fullScanBound(elapsed)))")
    let sa = pair.engineA.snapshotNow(), sb = pair.engineB.snapshotNow()
    check(sa.stats.conflictsCreated == 0 && sb.stats.conflictsCreated == 0, "no conflicts")
    check(sa.folders.first?.needItems == 0 && sb.folders.first?.needItems == 0 && sa.folders.first?.state == .idle
          && sb.folders.first?.state == .idle, "nothing left pending (\(sa.folders.first?.state.displayText ?? "?") / \(sb.folders.first?.state.displayText ?? "?"))")
    pair.stop()
}

/// Same bug with a peer that never says "more" (v1.0.2): the receiver must still wait for the children,
/// relying on the index stream going quiet instead.
@MainActor
func legacyPeerDirectoryChecks() {
    print("Tree deletion from a peer without the \"more\" flag (older version)")
    let folderID = "legacy-000001"
    let pair = Pair(name: "legacy", folderID: folderID)
    pair.optionsA.indexBatchSize = 20
    pair.optionsA.testParentTombstonesFirst = true
    pair.optionsA.testOmitMoreFlag = true
    let A = pair.dirA, B = pair.dirB
    for d in 1...10 {
        for f in 1...30 { write(A, "tree/d\(d)/f\(f).txt", "d\(d) f\(f)") }
    }
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.settle(60) != nil && entryCount(B, "tree") == 310,
          "tree synced (\(entryCount(B, "tree")) entries)")
    try? fm.removeItem(atPath: A + "/tree")
    check(pair.settle(60) != nil, "converged — \(treeDiff(pair.treeA, pair.treeB))")
    check(!exists(A, "tree") && !exists(B, "tree") && pair.treeB.isEmpty,
          "tree fully gone on both Macs (left on B: \(directories(B, under: "tree").prefix(4)))")
    check(pair.engineB.localRecord(folderID: folderID, path: "tree/d3")?.version == pair.engineA.localRecord(folderID: folderID, path: "tree/d3")?.version,
          "B adopted A's deletion, never re-announced the directories")
    pair.stop()
}

/// A directory the peer deleted that still holds an entry this Mac does not track (here: ignored on this Mac
/// only) is kept and re-announced once — then stays stable: no flip-flop, no endless re-announcing.
@MainActor
func keptDirectoryChecks() {
    print("Directory kept for an untracked local entry: re-announced once, then stable")
    let folderID = "kept-000001"
    let pair = Pair(name: "kept", folderID: folderID)
    pair.foldersB[0].ignorePatterns = ["*.local"]
    pair.excludeB = { $0.hasSuffix(".local") }
    let A = pair.dirA, B = pair.dirB
    let old = Date().addingTimeInterval(-3600)
    write(A, "K/tracked.txt", "tracked", mtime: old)
    write(A, "K/sub/deep.txt", "deep", mtime: old)
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.converge(30) != nil && read(B, "K/sub/deep.txt") == "deep",
          "tree synced")
    write(B, "K/sub/notes.local", "ignored on B, never synced")
    spin(0.6)
    try? fm.removeItem(atPath: A + "/K")
    check(pair.settle(30) != nil, "converged — \(treeDiff(pair.treeA, pair.treeB))")
    check(!exists(B, "K/tracked.txt") && !exists(B, "K/sub/deep.txt") && read(B, "K/sub/notes.local") != nil,
          "tracked files deleted on B, the untracked one kept")
    check(FS.isDirectory(A + "/K/sub") && pair.treeA == pair.treeB, "kept directories re-announced: A re-created K/sub (empty)")
    let recB = pair.engineB.localRecord(folderID: folderID, path: "K/sub"), recA = pair.engineA.localRecord(folderID: folderID, path: "K/sub")
    check(recB?.deleted == false && recA?.deleted == false && recA?.version == recB?.version, "both indexes agree: K/sub live, same version")
    let before = (pair.engineA.snapshotNow().stats.messagesSent, pair.engineB.snapshotNow().stats.messagesSent)
    spin(2.5)
    let after = (pair.engineA.snapshotNow().stats.messagesSent, pair.engineB.snapshotNow().stats.messagesSent)
    check(before == after && pair.engineB.localRecord(folderID: folderID, path: "K/sub")?.version == recB?.version,
          "stable afterwards: no re-announcing (A sent \(after.0 - before.0), B sent \(after.1 - before.1) messages in 2.5 s)")
    pair.stop()
}

/// Bursts of FSEvents and repeated rescan requests are coalesced: at most one full scan per
/// `minFullScanInterval` per folder, while targeted rescans of changed files stay immediate.
@MainActor
func scanCoalescingChecks() {
    print("Full rescans coalesced during bursts; single-file changes stay immediate")
    let folderID = "burst-000001"
    let pair = Pair(name: "burst", folderID: folderID)
    pair.optionsA.maxPendingPaths = 50 // nearly every FSEvents batch of the burst asks for a full rescan
    let A = pair.dirA
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.converge(30) != nil, "connected")
    let interval = testOptions.minFullScanInterval
    func fullScansA() -> Int { pair.engineA.snapshotNow().stats.fullScans }

    var scans0 = fullScansA()
    var start = Date()
    var requests = 0
    while Date().timeIntervalSince(start) < 3 {
        pair.engineA.rescan(folderID: folderID)
        requests += 1
        spin(0.05)
    }
    check(waitUntil(10) { pair.engineA.isQuiescent() }, "rescans done")
    var elapsed = Date().timeIntervalSince(start)
    var n = fullScansA() - scans0
    check(n >= 2 && n <= Int(elapsed / interval) + 2,
          "\(requests) rescan requests in 3 s → \(n) full scans in \(String(format: "%.1f", elapsed)) s (≤ \(Int(elapsed / interval) + 2))")

    scans0 = fullScansA()
    start = Date()
    for r in 0..<40 {
        for i in 0..<100 { write(A, "burst/r\(r)/f\(i).txt", "r\(r) f\(i)") }
        spin(0.05)
    }
    check(pair.converge(60) != nil && entryCount(pair.dirB, "burst") == 4040, "burst of 4 000 files synced (\(entryCount(pair.dirB, "burst")) entries)")
    elapsed = Date().timeIntervalSince(start)
    n = fullScansA() - scans0
    check(n >= 1 && n <= Int(elapsed / interval) + 2,
          "FSEvents burst → \(n) full scans in \(String(format: "%.1f", elapsed)) s (≤ \(Int(elapsed / interval) + 2))")

    scans0 = fullScansA()
    pair.engineA.rescan(folderID: folderID)
    check(waitUntil(5, poll: 0.005) { fullScansA() > scans0 }, "full scan started")
    pair.engineA.rescan(folderID: folderID) // has to wait for its turn
    let t0 = Date()
    write(A, "single.txt", "one small change")
    check(waitUntil(5, poll: 0.01) { pair.engineA.localRecord(folderID: folderID, path: "single.txt") != nil }, "single file indexed")
    let latency = Date().timeIntervalSince(t0)
    check(latency < testOptions.fsEventLatency + 0.5,
          "single-file change indexed after \(String(format: "%.2f", latency)) s while a full scan waits (≤ FSEvents latency + 0.5 s)")
    check(fullScansA() == scans0 + 1 && waitUntil(interval + 2) { fullScansA() == scans0 + 2 }, "the waiting full scan runs when its turn comes")
    check(pair.converge(30) != nil, "converged")
    pair.stop()
}

// MARK: - Adversarial directory scenarios (remote tombstones racing local changes)

extension SyncEngine {
    /// Directory deletions currently waiting for their children.
    func deferredDirectories(_ folderID: String) -> Set<String> {
        queue.sync { Set(folders[folderID]?.deferredDirDeletes.paths ?? []) }
    }
}

/// A pair that stresses batched directory changes: tiny index batches and (by default) deletions announced
/// parents-first, so a directory's tombstone arrives before its children's.
@MainActor
func stressPair(_ name: String, _ folderID: String, batch: Int = 20, parentsFirst: Bool = true) -> Pair {
    let pair = Pair(name: name, folderID: folderID)
    pair.optionsA.indexBatchSize = batch
    pair.optionsB.indexBatchSize = batch
    pair.optionsA.testParentTombstonesFirst = parentsFirst
    pair.optionsB.testParentTombstonesFirst = parentsFirst
    return pair
}

/// `write` for a path whose directory the engine may be removing at the same moment (applying the peer's deletion
/// of it): re-creates the directory and retries instead of failing.
func writeRacing(_ root: String, _ rel: String, _ text: String) {
    let path = root + "/" + rel
    for _ in 0..<50 {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if (try? Data(text.utf8).write(to: URL(fileURLWithPath: path))) != nil { return }
    }
    print("    could not write \(rel)")
}

func tempFiles(_ root: String) -> [String] {
    ((try? fm.subpathsOfDirectory(atPath: root)) ?? []).filter { $0.hasSuffix(".oneswitch-tmp") }
}

/// Paths whose local records differ (version or deleted flag) between the two engines. A directory that one
/// side re-announced after adopting the other's deletion shows up here.
@MainActor
func versionMismatches(_ pair: Pair, _ folderID: String, _ paths: [String]) -> [String] {
    paths.filter { p in
        let a = pair.engineA.localRecord(folderID: folderID, path: p), b = pair.engineB.localRecord(folderID: folderID, path: p)
        return a == nil || b == nil || a!.version != b!.version || a!.deleted != b!.deleted
    }
}

/// Messages sent by (A, B) during `seconds` — zero once both sides are stable (no flip-flop, no re-announcing).
@MainActor
func messagesDuring(_ pair: Pair, _ seconds: TimeInterval) -> (Int, Int) {
    let before = (pair.engineA.snapshotNow().stats.messagesSent, pair.engineB.snapshotNow().stats.messagesSent)
    spin(seconds)
    let after = (pair.engineA.snapshotNow().stats.messagesSent, pair.engineB.snapshotNow().stats.messagesSent)
    return (after.0 - before.0, after.1 - before.1)
}

@MainActor
func directorySet(_ t: [String: TreeEntry], under prefix: String) -> Set<String> {
    Set(t.filter { $0.value.kind == "d" && SyncPath.isSameOrInside($0.key, prefix) }.keys)
}

/// New files created (and a tracked file edited) inside a tree while the peer's deletion of that tree is being
/// applied in many small batches: every local change must survive on both Macs together with its directory
/// chain, everything else of the tree must go, and nothing may flip-flop afterwards.
@MainActor
func createDuringDeletionChecks() {
    print("Local files created inside a tree while the peer's deletion of it is being applied")
    let folderID = "adv-create-01"
    let pair = stressPair("adv-create", folderID)
    let A = pair.dirA, B = pair.dirB
    let old = Date().addingTimeInterval(-3600)
    for d in 1...25 { for f in 1...30 { write(A, "t/d\(d)/f\(f).txt", "d\(d) f\(f)", mtime: old) } }
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.settle(60) != nil && entryCount(B, "t") == 775,
          "tree synced (\(entryCount(B, "t")) entries)")

    // Online race: A deletes the tree; for 2 s B keeps creating files in d1…d8 (re-creating a directory that is
    // already gone) and edits a tracked file in d9, while A's tombstones arrive in ~40 batches.
    try? fm.removeItem(atPath: A + "/t")
    var created: [String] = []
    let start = Date()
    var i = 0
    while Date().timeIntervalSince(start) < 2.0 {
        let rel = "t/d\(i % 8 + 1)/new-\(i).txt"
        writeRacing(B, rel, "new \(i)")
        created.append(rel)
        if i == 3 { writeRacing(B, "t/d9/f7.txt", "edited on B while A deletes") }
        i += 1
        spin(0.03)
    }
    let t1 = pair.settle(90)
    check(t1 != nil, "converged — \(treeDiff(pair.treeA, pair.treeB))")
    let lostA = created.filter { read(A, $0) != "new \(created.firstIndex(of: $0)!)" }
    let lostB = created.filter { read(B, $0) != "new \(created.firstIndex(of: $0)!)" }
    check(lostA.isEmpty && lostB.isEmpty,
          "all \(created.count) files created on B during the deletion survive on both Macs (missing on A: \(lostA.prefix(3)), on B: \(lostB.prefix(3)))")
    check(read(A, "t/d9/f7.txt") == "edited on B while A deletes" && read(B, "t/d9/f7.txt") == "edited on B while A deletes",
          "the tracked file edited on B survives on both Macs")
    let ta = pair.treeA
    let originals = ta.keys.filter { SyncPath.name($0).hasPrefix("f") && $0 != "t/d9/f7.txt" }
    check(originals.isEmpty, "every other original file deleted (left: \(originals.sorted().prefix(4)))")
    let expectedDirs = Set(["t", "t/d9"] + (1...8).map { "t/d\($0)" })
    let dirsA = directorySet(ta, under: "t"), dirsB = directorySet(pair.treeB, under: "t")
    check(dirsA == expectedDirs && dirsB == expectedDirs,
          "exactly the directories holding surviving files stay (extra: \(dirsA.subtracting(expectedDirs).sorted().prefix(4)), missing: \(expectedDirs.subtracting(dirsA).sorted().prefix(4)))")
    check(ta == pair.treeB && conflictCopies(ta).isEmpty, "trees identical, no conflict copies")
    check(versionMismatches(pair, folderID, ["t", "t/d1", "t/d9", "t/d10", "t/d25", "t/d25/f3.txt"]).isEmpty,
          "both indexes agree on the kept and the deleted directories")
    let quiet = messagesDuring(pair, 2.0)
    check(quiet == (0, 0), "stable afterwards (A sent \(quiet.0), B sent \(quiet.1) messages in 2 s)")

    // Offline: the new file is already indexed on B (unknown to A) when A's deletion of the tree arrives.
    for d in 1...10 { for f in 1...30 { write(A, "u/d\(d)/f\(f).txt", "u d\(d) f\(f)", mtime: old) } }
    check(pair.settle(60) != nil && entryCount(B, "u") == 310, "second tree synced (\(entryCount(B, "u")) entries)")
    pair.hubA.setLinked(false)
    _ = waitUntil(5) { !pair.engineA.snapshotNow().connected && !pair.engineB.snapshotNow().connected }
    try? fm.removeItem(atPath: A + "/u")
    write(B, "u/d4/sub/offline-new.txt", "created on B while A deleted u")
    check(waitUntil(15) {
        pair.engineA.localRecord(folderID: folderID, path: "u")?.deleted == true
            && pair.engineB.localRecord(folderID: folderID, path: "u/d4/sub/offline-new.txt") != nil
    }, "offline deletion (A) and new file inside the tree (B) indexed")
    pair.hubA.setLinked(true)
    check(pair.settle(60) != nil, "converged after reconnect — \(treeDiff(pair.treeA, pair.treeB))")
    check(read(A, "u/d4/sub/offline-new.txt") == "created on B while A deleted u" && read(B, "u/d4/sub/offline-new.txt") != nil,
          "the new file survives on both Macs")
    let uDirs = directorySet(pair.treeA, under: "u")
    check(uDirs == ["u", "u/d4", "u/d4/sub"] && pair.treeA == pair.treeB, "only its directory chain stays (\(uDirs.sorted().prefix(5)))")
    check(pair.treeA.keys.filter { $0.hasPrefix("u/") && $0.hasSuffix(".txt") } == ["u/d4/sub/offline-new.txt"], "every other file of u deleted")
    check(pair.engineA.snapshotNow().stats.conflictsCreated == 0 && pair.engineB.snapshotNow().stats.conflictsCreated == 0, "no conflicts")
    pair.stop()
}

/// The sender deletes (then, in a second round, renames) a tree while the receiver is still pulling files
/// into it through a slow disk.
@MainActor
func deleteWhilePullingChecks() {
    print("Tree deleted / renamed on the sender while the receiver is still pulling files into it")
    let folderID = "adv-pull-001"
    let pair = stressPair("adv-pull", folderID)
    pair.optionsB.testWriteDelay = 0.08 // slow destination disk: every 1 MiB block takes ≥ 80 ms
    pair.optionsB.maxActiveFiles = 2
    let A = pair.dirA, B = pair.dirB
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.converge(30) != nil, "connected")
    func fill(_ root: String) {
        for d in 1...4 {
            for f in 1...5 { write(A, "\(root)/d\(d)/big\(f).bin", randomData(3 << 20)) }
            for f in 1...15 { write(A, "\(root)/d\(d)/s\(f).txt", "small \(d) \(f)") }
        }
    }
    func pullStarted(_ root: String) -> Bool {
        ((try? fm.contentsOfDirectory(atPath: B + "/\(root)/d1")) ?? []).filter { $0.hasPrefix("big") }.count >= 2
    }

    fill("p")
    check(waitUntil(30, poll: 0.01) { pullStarted("p") }, "B is pulling p")
    let pending = pair.engineB.snapshotNow().folders.first?.needItems ?? 0
    try? fm.removeItem(atPath: A + "/p")
    check(pair.settle(90) != nil, "converged after the deletion — \(treeDiff(pair.treeA, pair.treeB))")
    check(pending > 0, "the deletion hit while \(pending) items were still pending on B")
    check(!exists(A, "p") && !exists(B, "p"), "tree gone on both Macs (left on B: \(directories(B, under: "p").prefix(4)))")
    check(tempFiles(A).isEmpty && tempFiles(B).isEmpty, "no temp files left behind (\(tempFiles(B).prefix(3)))")
    check(versionMismatches(pair, folderID, ["p", "p/d1", "p/d4", "p/d2/big3.bin"]).isEmpty, "B adopted A's deletions, re-announced nothing")

    fill("q")
    check(waitUntil(30, poll: 0.01) { pullStarted("q") }, "B is pulling q")
    check(rename(A + "/q", A + "/q-renamed") == 0, "A renames q → q-renamed mid-transfer")
    check(pair.settle(90) != nil, "converged after the rename — \(treeDiff(pair.treeA, pair.treeB))")
    check(!exists(A, "q") && !exists(B, "q") && entryCount(B, "q-renamed") == 84 && pair.treeA == pair.treeB,
          "old name gone, renamed tree complete on both Macs (\(entryCount(B, "q-renamed")) entries, left under q: \(directories(B, under: "q").prefix(4)))")
    check(tempFiles(A).isEmpty && tempFiles(B).isEmpty, "no temp files left behind (\(tempFiles(B).prefix(3)))")
    check(pair.engineA.snapshotNow().stats.conflictsCreated == 0 && pair.engineB.snapshotNow().stats.conflictsCreated == 0, "no conflicts")
    pair.stop()
}

/// A tree renamed back and forth several times in quick succession (faster than the peer applies each rename).
@MainActor
func renameFlipFlopChecks() {
    print("Tree renamed back and forth quickly")
    let folderID = "adv-flip-001"
    let pair = stressPair("adv-flip", folderID)
    let A = pair.dirA, B = pair.dirB
    let old = Date().addingTimeInterval(-3600)
    for d in 1...10 { for f in 1...20 { write(A, "r/d\(d)/f\(f).txt", "r d\(d) f\(f)", mtime: old) } }
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.settle(60) != nil && entryCount(B, "r") == 210,
          "tree synced (\(entryCount(B, "r")) entries)")
    func flip(_ root: String, _ gaps: [Double], from current: String) -> String {
        var cur = current
        for gap in gaps {
            let next = cur == "r" ? "r2" : "r"
            if rename(root + "/" + cur, root + "/" + next) != 0 { print("    rename failed: \(FS.errorString(errno))") }
            cur = next
            spin(gap)
        }
        return cur
    }
    var current = flip(A, [0.05, 0.4, 0.15, 0.8, 0.02, 0.3, 0.6], from: "r") // 7 flips on A
    check(pair.settle(90) != nil, "converged after 7 quick renames on A — \(treeDiff(pair.treeA, pair.treeB))")
    var other = current == "r" ? "r2" : "r"
    check(entryCount(A, current) == 210 && entryCount(B, current) == 210 && !exists(A, other) && !exists(B, other),
          "only \(current) left, complete on both Macs (left under \(other): A \(directories(A, under: other).prefix(3)) B \(directories(B, under: other).prefix(3)))")
    current = flip(B, [0.1, 0.25, 0.05, 0.5, 0.2], from: current) // 5 flips on B
    check(pair.settle(90) != nil, "converged after 5 quick renames on B — \(treeDiff(pair.treeA, pair.treeB))")
    other = current == "r" ? "r2" : "r"
    check(entryCount(A, current) == 210 && entryCount(B, current) == 210 && !exists(A, other) && !exists(B, other)
          && pair.treeA == pair.treeB,
          "only \(current) left, complete on both Macs (left under \(other): A \(directories(A, under: other).prefix(3)) B \(directories(B, under: other).prefix(3)))")
    check(versionMismatches(pair, folderID, [other, other + "/d4", current, current + "/d4"]).isEmpty, "both indexes agree")
    check(conflictCopies(pair.treeA).isEmpty && tempFiles(A).isEmpty && tempFiles(B).isEmpty, "no conflict copies, no temp files")
    let quiet = messagesDuring(pair, 2.0)
    check(quiet == (0, 0), "stable afterwards (A sent \(quiet.0), B sent \(quiet.1) messages in 2 s)")
    pair.stop()
}

/// A 20-level deep tree: renamed, deleted, and a file created at the bottom while the peer deletes the tree.
@MainActor
func deepTreeChecks() {
    print("Nested tree of depth 20: rename, delete, create at the bottom during a deletion")
    let folderID = "adv-deep-001"
    let pair = stressPair("adv-deep", folderID, batch: 5)
    let A = pair.dirA, B = pair.dirB
    let old = Date().addingTimeInterval(-3600)
    func chain(_ root: String) -> [String] {
        var p = root
        return (1...20).map { level -> String in
            p += "/l\(level)"
            return p
        }
    }
    for dir in chain("deep") {
        write(A, dir + "/f.txt", "file in \(dir)", mtime: old)
        try? fm.createDirectory(atPath: A + "/" + dir + "/empty", withIntermediateDirectories: true)
    }
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.settle(60) != nil && entryCount(B, "deep") == 60,
          "deep tree synced (\(entryCount(B, "deep")) entries)")
    check(rename(A + "/deep", A + "/deep2") == 0, "A renames deep → deep2")
    check(pair.settle(60) != nil, "converged — \(treeDiff(pair.treeA, pair.treeB))")
    check(!exists(A, "deep") && !exists(B, "deep") && entryCount(A, "deep2") == 60 && entryCount(B, "deep2") == 60,
          "old tree gone, renamed tree complete on both Macs (left on A: \(directories(A, under: "deep").count) dirs, B: \(directories(B, under: "deep").count) dirs)")
    check(versionMismatches(pair, folderID, ["deep"] + chain("deep")).isEmpty, "every old directory is the same tombstone on both Macs")

    try? fm.removeItem(atPath: B + "/deep2")
    check(pair.settle(60) != nil, "converged after the deletion — \(treeDiff(pair.treeA, pair.treeB))")
    check(!exists(A, "deep2") && !exists(B, "deep2"),
          "deleted on both Macs (left on A: \(directories(A, under: "deep2").count) dirs)")
    check(versionMismatches(pair, folderID, ["deep2"] + chain("deep2")).isEmpty, "every directory is the same tombstone on both Macs")

    for dir in chain("deep3") { write(A, dir + "/f.txt", "file in \(dir)", mtime: old) }
    check(pair.settle(60) != nil && entryCount(B, "deep3") == 40, "third tree synced (\(entryCount(B, "deep3")) entries)")
    let bottom = chain("deep3").last! + "/late.txt"
    try? fm.removeItem(atPath: B + "/deep3")
    spin(0.15)
    writeRacing(A, bottom, "created at the bottom while B deleted the tree")
    check(pair.settle(60) != nil, "converged — \(treeDiff(pair.treeA, pair.treeB))")
    check(read(A, bottom) != nil && read(B, bottom) == "created at the bottom while B deleted the tree",
          "the new file at depth 21 survives on both Macs")
    let files = pair.treeB.keys.filter { $0.hasPrefix("deep3/") && pair.treeB[$0]?.kind == "f" }
    check(files == [bottom] && directorySet(pair.treeB, under: "deep3") == Set(["deep3"] + chain("deep3")) && pair.treeA == pair.treeB,
          "only its directory chain stays (\(files.count) files, \(directorySet(pair.treeB, under: "deep3").count) directories)")
    pair.stop()
}

/// Directories that only hold Finder litter (.DS_Store, ._*, Icon\r) on the receiving side are deleted with the tree.
@MainActor
func junkOnlyDirectoryChecks() {
    print("Directories holding only Finder litter are deleted with the tree")
    let folderID = "adv-junk-001"
    let pair = stressPair("adv-junk", folderID)
    let A = pair.dirA, B = pair.dirB
    let old = Date().addingTimeInterval(-3600)
    write(A, "j/a/1.txt", "1", mtime: old)
    write(A, "j/b/2.txt", "2", mtime: old)
    write(A, "j/d/e/3.txt", "3", mtime: old)
    for d in ["j/c", "j/onlyjunk/x/y"] { try? fm.createDirectory(atPath: A + "/" + d, withIntermediateDirectories: true) }
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.settle(60) != nil && entryCount(B, "j") == 11,
          "tree synced (\(entryCount(B, "j")) entries)")
    for d in ["j", "j/a", "j/c", "j/d/e", "j/onlyjunk", "j/onlyjunk/x/y"] { write(B, d + "/.DS_Store", Data(repeating: 1, count: 64)) }
    write(B, "j/b/._2.txt", Data(repeating: 2, count: 32))
    write(B, "j/d/Icon\r", Data())
    write(A, "j/.DS_Store", Data(repeating: 3, count: 64))
    spin(0.6)
    try? fm.removeItem(atPath: A + "/j")
    check(pair.settle(60) != nil, "converged — \(treeDiff(pair.treeA, pair.treeB))")
    check(!exists(A, "j") && !exists(B, "j"), "tree gone on both Macs (left on B: \(((try? fm.subpathsOfDirectory(atPath: B + "/j")) ?? []).prefix(4)))")
    check(versionMismatches(pair, folderID, ["j", "j/c", "j/onlyjunk", "j/onlyjunk/x/y", "j/d"]).isEmpty, "B adopted every deletion")
    pair.stop()
}

/// Empty directories: created, deleted, re-created, deleted on the other side, created and removed before a scan,
/// created concurrently, and removed on one side while the other creates something inside.
@MainActor
func emptyDirectoryChecks() {
    print("Empty directories created and deleted")
    let folderID = "adv-empty-01"
    let pair = stressPair("adv-empty", folderID, batch: 7)
    let A = pair.dirA, B = pair.dirB
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.converge(30) != nil, "connected")
    func makeEmpties(_ root: String) {
        for e in 1...30 { try? fm.createDirectory(atPath: root + "/em/e\(e)", withIntermediateDirectories: true) }
        try? fm.createDirectory(atPath: root + "/em/n1/n2/n3", withIntermediateDirectories: true)
    }
    makeEmpties(A)
    check(pair.settle(60) != nil && entryCount(B, "em") == 33, "33 empty directories synced (\(entryCount(B, "em")))")
    try? fm.removeItem(atPath: A + "/em")
    check(pair.settle(60) != nil && !exists(A, "em") && !exists(B, "em"), "deleted on A → gone on both (left on B: \(entryCount(B, "em")))")
    makeEmpties(A)
    check(pair.settle(60) != nil && entryCount(A, "em") == 33 && entryCount(B, "em") == 33, "re-created over the tombstones (\(entryCount(B, "em")))")
    try? fm.removeItem(atPath: B + "/em")
    check(pair.settle(60) != nil && !exists(A, "em") && !exists(B, "em"), "deleted on B → gone on both (left on A: \(entryCount(A, "em")))")
    check(versionMismatches(pair, folderID, ["em", "em/e5", "em/n1/n2/n3"]).isEmpty, "both indexes agree")

    mkdir(A + "/q1", 0o755)
    rmdir(A + "/q1")
    mkdir(A + "/q2", 0o755)
    check(pair.settle(30) != nil && !exists(B, "q1") && FS.isDirectory(B + "/q2"), "created-and-removed directory never appears on B")

    try? fm.createDirectory(atPath: A + "/cc/a", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: B + "/cc/b", withIntermediateDirectories: true)
    check(pair.settle(30) != nil && FS.isDirectory(A + "/cc/b") && FS.isDirectory(B + "/cc/a") && pair.treeA == pair.treeB,
          "the same new parent created on both Macs at once: both children kept")
    rmdir(A + "/cc/a")
    try? fm.createDirectory(atPath: B + "/cc/a/x", withIntermediateDirectories: true)
    check(pair.settle(30) != nil && FS.isDirectory(A + "/cc/a/x") && FS.isDirectory(B + "/cc/a/x") && pair.treeA == pair.treeB,
          "directory removed on A while B creates a subdirectory in it: the subdirectory survives on both — \(treeDiff(pair.treeA, pair.treeB))")
    let quiet = messagesDuring(pair, 2.0)
    check(quiet == (0, 0), "stable afterwards (A sent \(quiet.0), B sent \(quiet.1) messages in 2 s)")
    pair.stop()
}

/// The same tree deleted on both Macs at (nearly) the same time, online and offline; and deleted on one Mac while
/// the other deletes or moves out a subtree.
@MainActor
func deleteOnBothChecks() {
    print("Tree deleted on both Macs at once")
    let folderID = "adv-both-001"
    let pair = stressPair("adv-both", folderID)
    let A = pair.dirA, B = pair.dirB
    let old = Date().addingTimeInterval(-3600)
    func fill() { for d in 1...10 { for f in 1...30 { write(A, "both/d\(d)/f\(f).txt", "d\(d) f\(f)", mtime: old) } } }
    fill()
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.settle(60) != nil && entryCount(B, "both") == 310, "tree synced")
    let probe = ["both", "both/d3", "both/d3/f3.txt", "both/d10"]

    try? fm.removeItem(atPath: A + "/both")
    try? fm.removeItem(atPath: B + "/both")
    check(pair.settle(60) != nil && !exists(A, "both") && !exists(B, "both") && pair.treeA.isEmpty,
          "online: gone on both Macs — \(treeDiff(pair.treeA, pair.treeB))")
    check(versionMismatches(pair, folderID, probe).isEmpty, "both indexes hold the same merged tombstones")

    fill()
    check(pair.settle(60) != nil && entryCount(B, "both") == 310, "tree synced again")
    pair.hubA.setLinked(false)
    _ = waitUntil(5) { !pair.engineA.snapshotNow().connected }
    try? fm.removeItem(atPath: A + "/both")
    try? fm.removeItem(atPath: B + "/both")
    check(waitUntil(15) {
        pair.engineA.localRecord(folderID: folderID, path: "both")?.deleted == true && pair.engineB.localRecord(folderID: folderID, path: "both")?.deleted == true
    }, "offline deletions indexed on both")
    pair.hubA.setLinked(true)
    check(pair.settle(60) != nil && !exists(A, "both") && !exists(B, "both") && pair.treeA.isEmpty,
          "offline: gone on both Macs — \(treeDiff(pair.treeA, pair.treeB))")
    check(versionMismatches(pair, folderID, probe).isEmpty, "both indexes hold the same merged tombstones")

    fill()
    check(pair.settle(60) != nil && entryCount(B, "both") == 310, "tree synced again")
    try? fm.removeItem(atPath: A + "/both")
    try? fm.removeItem(atPath: B + "/both/d3")
    check(pair.settle(60) != nil && !exists(A, "both") && !exists(B, "both"), "tree (A) and subtree (B) deleted at once: gone on both")

    fill()
    check(pair.settle(60) != nil && entryCount(B, "both") == 310, "tree synced again")
    try? fm.removeItem(atPath: A + "/both")
    check(rename(B + "/both/d3", B + "/moved-d3") == 0, "B moves both/d3 out while A deletes both")
    check(pair.settle(60) != nil, "converged — \(treeDiff(pair.treeA, pair.treeB))")
    check(!exists(A, "both") && !exists(B, "both") && entryCount(A, "moved-d3") == 30 && pair.treeA == pair.treeB,
          "moved subtree survives on both Macs, the rest is gone (\(entryCount(A, "moved-d3")) files moved)")
    check(pair.engineA.snapshotNow().stats.conflictsCreated == 0 && pair.engineB.snapshotNow().stats.conflictsCreated == 0, "no conflicts")
    pair.stop()
}

/// A directory replaced by a file of the same name and vice versa, in both directions, including a directory
/// whose children span several index batches.
@MainActor
func kindChangeChecks() {
    print("Directory replaced by a file of the same name and vice versa")
    let folderID = "adv-kind-001"
    let pair = stressPair("adv-kind", folderID, parentsFirst: false)
    let A = pair.dirA, B = pair.dirB
    let old = Date().addingTimeInterval(-3600)
    for f in 1...12 { write(A, "k/x/\(f).txt", "x \(f)", mtime: old) }
    write(A, "k/x/sub/deep.txt", "deep", mtime: old)
    write(A, "k/y", "y is a file", mtime: old)
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.settle(60) != nil && entryCount(B, "k") == 16, "synced")

    var start = Date()
    try? fm.removeItem(atPath: A + "/k/x")
    write(A, "k/x", "x is a file now")
    try? fm.removeItem(atPath: A + "/k/y")
    for f in 1...5 { write(A, "k/y/\(f).txt", "y \(f)") }
    var t = pair.settle(90)
    check(t != nil && read(B, "k/x") == "x is a file now" && read(B, "k/y/3.txt") == "y 3" && pair.treeA == pair.treeB,
          "A: directory → file and file → directory applied on B — \(treeDiff(pair.treeA, pair.treeB))")
    check(Date().timeIntervalSince(start) < 15, String(format: "…promptly (%.1f s)", Date().timeIntervalSince(start)))

    start = Date()
    try? fm.removeItem(atPath: B + "/k/x")
    for f in 1...45 { write(B, "k/x/\(f).txt", "x again \(f)") }
    try? fm.removeItem(atPath: B + "/k/y")
    write(B, "k/y", "y is a file again")
    t = pair.settle(90)
    check(t != nil && read(A, "k/x/45.txt") == "x again 45" && read(A, "k/y") == "y is a file again" && pair.treeA == pair.treeB,
          "B: file → directory and directory → file applied on A — \(treeDiff(pair.treeA, pair.treeB))")
    check(Date().timeIntervalSince(start) < 15, String(format: "…promptly (%.1f s)", Date().timeIntervalSince(start)))

    // A directory whose children span several index batches (20 records each) replaced by a file.
    for f in 1...100 { write(A, "k/big/\(f).txt", "big \(f)", mtime: old) }
    check(pair.settle(60) != nil && entryCount(B, "k/big") == 100, "100-file directory synced")
    start = Date()
    try? fm.removeItem(atPath: A + "/k/big")
    write(A, "k/big", "big is a file now")
    t = pair.settle(90)
    check(t != nil && read(B, "k/big") == "big is a file now" && pair.treeA == pair.treeB,
          "directory spanning several batches replaced by a file — \(treeDiff(pair.treeA, pair.treeB))")
    check(Date().timeIntervalSince(start) < 15, String(format: "…promptly (%.1f s)", Date().timeIntervalSince(start)))
    check(pair.engineA.snapshotNow().stats.conflictsCreated == 0 && pair.engineB.snapshotNow().stats.conflictsCreated == 0
          && pair.engineB.snapshotNow().folders.first?.issues.isEmpty == true,
          "no conflicts, no issues left (\(pair.engineB.snapshotNow().folders.first?.issues.first ?? "none"))")

    // A directory with a subdirectory replaced by a symlink: the link used to be applied before the subdirectory's
    // deletion in the same batch, found the directory not empty and waited 30 s as "obstructed".
    write(A, "k/s/1.txt", "1", mtime: old)
    write(A, "k/s/sub/2.txt", "2", mtime: old)
    check(pair.settle(60) != nil && entryCount(B, "k/s") == 3, "directory with a subdirectory synced")
    start = Date()
    try? fm.removeItem(atPath: A + "/k/s")
    try? fm.createSymbolicLink(atPath: A + "/k/s", withDestinationPath: "../elsewhere")
    t = pair.settle(90)
    check(t != nil && (try? fm.destinationOfSymbolicLink(atPath: B + "/k/s")) == "../elsewhere" && pair.treeA == pair.treeB,
          "directory → symlink applied on B — \(treeDiff(pair.treeA, pair.treeB))")
    check(Date().timeIntervalSince(start) < 10, String(format: "…promptly (%.1f s)", Date().timeIntervalSince(start)))

    // Replaced by a file while the receiver holds an entry the peer never saw: that entry cannot stay at the path.
    // It used to block both Macs forever ("obstructed" on both, each showing 空闲·已同步 with different trees);
    // now the directory is preserved as a conflict copy and the file applied.
    write(A, "k/o/1.txt", "1", mtime: old)
    check(pair.settle(60) != nil && read(B, "k/o/1.txt") == "1", "directory synced")
    pair.hubA.setLinked(false)
    _ = waitUntil(5) { !pair.engineA.snapshotNow().connected }
    try? fm.removeItem(atPath: A + "/k/o")
    write(A, "k/o", "o is a file now")
    write(B, "k/o/local.txt", "B's new file")
    check(waitUntil(15) {
        pair.engineA.localRecord(folderID: folderID, path: "k/o")?.kind == .file
            && pair.engineB.localRecord(folderID: folderID, path: "k/o/local.txt") != nil
    }, "offline: A replaced k/o by a file, B created k/o/local.txt")
    pair.hubA.setLinked(true)
    t = pair.settle(60)
    check(t != nil && pair.treeA == pair.treeB, "converged — \(treeDiff(pair.treeA, pair.treeB))")
    let copies = pair.treeA.keys.filter { SyncPath.name($0).contains(".sync-conflict-") && $0.hasPrefix("k/o.") }
    check(read(A, "k/o") == "o is a file now" && read(B, "k/o") == "o is a file now", "the file replaced the directory on both Macs")
    check(copies.count == 1 && copies.first.map { read(A, $0 + "/local.txt") } == "B's new file"
          && copies.first.map { read(B, $0 + "/local.txt") } == "B's new file",
          "B's directory preserved as a conflict copy with the new file, on both Macs (\(copies))")
    check(pair.engineB.snapshotNow().folders.first?.conflicts.first?.originalPath == "k/o", "conflict listed on B")
    check(pair.engineA.snapshotNow().folders.first?.issues.isEmpty == true && pair.engineB.snapshotNow().folders.first?.issues.isEmpty == true,
          "no issues left (A: \(pair.engineA.snapshotNow().folders.first?.issues.first ?? "none"), B: \(pair.engineB.snapshotNow().folders.first?.issues.first ?? "none"))")
    let quiet = messagesDuring(pair, 2.0)
    check(quiet == (0, 0), "stable afterwards (A sent \(quiet.0), B sent \(quiet.1) messages in 2 s)")
    pair.stop()
}

/// The deleting Mac is itself still pulling a new file (created on the other Mac) into the tree it deletes: the new
/// file survives on both Macs, promptly (the lost transfer used to wait 30 s as an "I/O error").
@MainActor
func reversePullRaceChecks() {
    print("Tree deleted on a Mac that is still pulling a new file into it")
    let folderID = "adv-rev-0001"
    let pair = stressPair("adv-rev", folderID, parentsFirst: false)
    pair.optionsA.testWriteDelay = 0.15 // A's pull of the 8 MiB file takes ≥ 1.2 s
    let A = pair.dirA, B = pair.dirB
    let old = Date().addingTimeInterval(-3600)
    for f in 1...5 { write(A, "D/f\(f).txt", "f\(f)", mtime: old) }
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.settle(60) != nil, "synced")
    let data = randomData(8 << 20)
    write(B, "D/new.bin", data)
    check(waitUntil(10, poll: 0.005) { ((try? fm.contentsOfDirectory(atPath: A + "/D")) ?? []).contains { $0.hasSuffix(".oneswitch-tmp") } },
          "A is pulling D/new.bin")
    let start = Date()
    try? fm.removeItem(atPath: A + "/D")
    check(pair.settle(90) != nil, "converged — \(treeDiff(pair.treeA, pair.treeB))")
    let elapsed = Date().timeIntervalSince(start)
    check(pair.treeA["D/new.bin"]?.content == sha(data) && pair.treeB["D/new.bin"]?.content == sha(data)
          && directorySet(pair.treeA, under: "D") == ["D"] && pair.treeA.keys.filter { $0.hasPrefix("D/") } == ["D/new.bin"],
          "the new file survives on both Macs, everything else of D is gone (\(pair.treeA.keys.filter { $0.hasPrefix("D") }.sorted()))")
    check(elapsed < 15, String(format: "…promptly (%.1f s)", elapsed))
    check(tempFiles(A).isEmpty && tempFiles(B).isEmpty && pair.engineA.snapshotNow().folders.first?.issues.isEmpty == true,
          "no temp files, no issues left")
    pair.stop()
}

/// A rename spanning many index batches: the new paths arrive first (their pulls are queued), the old paths'
/// deletions in later batches. Content is cloned locally before those deletions instead of re-transferred.
@MainActor
func multiBatchRenameCloneChecks() {
    print("Rename spanning many index batches is applied from local copies")
    let folderID = "adv-mren-001"
    let pair = Pair(name: "adv-mren", folderID: folderID)
    pair.optionsA.indexBatchSize = 100
    pair.optionsB.indexBatchSize = 100
    let A = pair.dirA, B = pair.dirB
    for d in 1...10 { for f in 1...50 { write(A, "m/d\(d)/f\(f).bin", randomData(64 << 10)) } }
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.settle(60) != nil && entryCount(B, "m") == 510, "500 files synced")
    let before = pair.engineB.snapshotNow().stats
    check(rename(A + "/m", A + "/m2") == 0, "A renames m → m2 (≈ 11 index batches)")
    check(pair.settle(60) != nil && !exists(B, "m") && entryCount(B, "m2") == 510 && pair.treeA == pair.treeB,
          "rename applied — \(treeDiff(pair.treeA, pair.treeB))")
    let after = pair.engineB.snapshotNow().stats
    let received = after.blockBytesReceived - before.blockBytesReceived
    check(after.filesClonedLocally - before.filesClonedLocally == 500 && received == 0,
          "all 500 files cloned locally, nothing re-transferred (\(after.filesClonedLocally - before.filesClonedLocally) cloned, \(received) bytes received)")
    check(tempFiles(B).isEmpty, "no temp files left behind")
    pair.stop()
}

/// An engine restarted in the middle of a deletion (persisted index): once while the deletion is being applied,
/// and once — against a fake peer, deterministically — while directory deletions wait for their children.
@MainActor
func restartDuringDeletionChecks() {
    print("Engine restarted in the middle of a tree deletion")
    do {
        let folderID = "adv-rstrt-01"
        let pair = stressPair("adv-rstrt", folderID)
        let A = pair.dirA, B = pair.dirB
        let old = Date().addingTimeInterval(-3600)
        for d in 1...20 { for f in 1...40 { write(A, "z/d\(d)/f\(f).txt", "d\(d) f\(f)", mtime: old) } }
        pair.start()
        check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.settle(60) != nil && entryCount(B, "z") == 820, "tree synced")
        try? fm.removeItem(atPath: A + "/z")
        check(waitUntil(20, poll: 0.002) { entryCount(B, "z") < 800 }, "B started applying the deletion (\(entryCount(B, "z")) entries left)")
        pair.engineB.stop()
        let leftAtStop = entryCount(B, "z")
        pair.engineB = pair.makeEngineB()
        pair.engineB.start(folders: pair.foldersB)
        check(pair.settle(60) != nil, "converged after B restarted with \(leftAtStop) entries left — \(treeDiff(pair.treeA, pair.treeB))")
        check(!exists(A, "z") && !exists(B, "z"), "tree gone on both Macs (left on B: \(directories(B, under: "z").prefix(4)))")
        check(versionMismatches(pair, folderID, ["z", "z/d1", "z/d20", "z/d7/f7.txt"]).isEmpty, "B adopted A's deletions, re-announced nothing")
        pair.stop()
    }

    // Fake peer: a v1.0.2-style peer announces the directory tombstones first; the children's follow only after
    // the engine has been restarted.
    let peer = DirFakePeer(name: "adv-restart", folderID: "adv-restart-01")
    let folderID = peer.folderID, dir = peer.dir
    var engine = peer.makeEngine()
    engine.start(folders: peer.configs)
    check(waitUntil(10) { peer.channel.value != nil }, "fake peer channel formed")
    peer.sendHello()
    peer.sendInitialTree()
    check(waitUntil(20) { read(dir, "t/d1/f5.txt") == "f5" && read(dir, "t/d2/g3.txt") == "g3" && engine.isQuiescent() }, "tree pulled from the fake peer")

    // Directory tombstones first, "more" announced (children's tombstones follow).
    let mark = peer.inbox.value.count
    peer.sendDirectoryTombstones()
    check(waitUntil(5) { engine.deferredDirectories(folderID) == ["t", "t/d1", "t/d2"] },
          "the three directory deletions wait for their children (\(engine.deferredDirectories(folderID).sorted()))")
    spin(1.0)
    check(read(dir, "t/d1/f3.txt") == "f3" && engine.localRecord(folderID: folderID, path: "t/d1")?.deleted == false,
          "nothing removed yet; the directory records stay live")
    let announced = peer.inbox.value.dropFirst(mark).filter { $0.0 == 3 }
    check(announced.isEmpty, "nothing re-announced while waiting (\(announced.count) index messages)")

    engine.stop()
    check(waitUntil(5) { peer.channel.value?.isOpen == false }, "engine stopped (channel closed)")
    write(dir, "t/d1/while-stopped.txt", "created while the engine was stopped")
    peer.channel.value = nil
    let mark2 = peer.inbox.value.count
    engine = peer.makeEngine()
    engine.start(folders: peer.configs)
    check(waitUntil(10) { peer.channel.value != nil }, "channel formed again after the restart")
    check(waitUntil(5) { peer.inbox.value.dropFirst(mark2).contains { $0.0 == 1 && $0.1.contains(#""hs":14"#) } },
          "restarted engine reports the persisted remote index (haveSeq 14)")
    peer.sendHello()
    peer.sendChildTombstones()
    check(waitUntil(15) { !exists(dir, "t/d2") && !exists(dir, "t/d1/f1.txt") && engine.isQuiescent() },
          "after the restart the children are deleted and t/d2 removed (left: \(((try? fm.subpathsOfDirectory(atPath: dir + "/t")) ?? []).sorted().prefix(5)))")
    check(read(dir, "t/d1/while-stopped.txt") == "created while the engine was stopped",
          "the file created while the engine was stopped survives with its directories")
    let d1 = engine.localRecord(folderID: folderID, path: "t/d1"), t = engine.localRecord(folderID: folderID, path: "t")
    let d2 = engine.localRecord(folderID: folderID, path: "t/d2")
    let tomb13 = VersionVector(["FAKE-DEVICE": 13]), tomb12 = VersionVector(["FAKE-DEVICE": 12])
    check(d1?.deleted == false && d1.map { $0.version.compare(tomb13) == .greater } == true
          && t?.deleted == false && t.map { $0.version.compare(tomb12) == .greater } == true,
          "t and t/d1 kept with versions superseding the peer's tombstones (t/d1 \(d1?.version.description ?? "nil"))")
    check(d2?.deleted == true && d2?.version == VersionVector(["FAKE-DEVICE": 14]), "t/d2 adopted the peer's tombstone unchanged")
    spin(0.5)
    engine.stop()
    peer.close()
}

/// Pausing the folder while directory deletions wait for their children; the rest of the deletion arrives while
/// it is paused and is applied on resume, without re-announcing anything.
@MainActor
func pauseDuringDeferredDeletionChecks() {
    print("Folder paused while directory deletions wait for their children")
    let peer = DirFakePeer(name: "adv-pause", folderID: "adv-pause-001")
    let folderID = peer.folderID, dir = peer.dir
    let engine = peer.makeEngine()
    engine.start(folders: peer.configs)
    check(waitUntil(10) { peer.channel.value != nil }, "fake peer channel formed")
    peer.sendHello()
    peer.sendInitialTree()
    check(waitUntil(20) { read(dir, "t/d2/g3.txt") == "g3" && engine.isQuiescent() }, "tree pulled from the fake peer")
    peer.sendDirectoryTombstones()
    check(waitUntil(5) { engine.deferredDirectories(folderID).count == 3 }, "directory deletions wait for their children")
    var paused = peer.configs
    paused[0].paused = true
    engine.update(folders: paused)
    check(waitUntil(5) { engine.snapshotNow().folders.first?.state == .paused && engine.deferredDirectories(folderID).isEmpty },
          "paused: nothing waits any more")
    peer.sendChildTombstones()
    spin(1.0)
    check(read(dir, "t/d1/f1.txt") == "f1" && read(dir, "t/d2/g1.txt") == "g1", "nothing applied while paused")
    let mark = peer.inbox.value.count
    engine.update(folders: peer.configs)
    check(waitUntil(15) { !exists(dir, "t") && engine.isQuiescent() },
          "resumed: the whole tree deleted (left: \(((try? fm.subpathsOfDirectory(atPath: dir + "/t")) ?? []).sorted().prefix(5)))")
    check(engine.localRecord(folderID: folderID, path: "t")?.version == VersionVector(["FAKE-DEVICE": 12])
          && engine.localRecord(folderID: folderID, path: "t/d1")?.version == VersionVector(["FAKE-DEVICE": 13]),
          "the peer's tombstones adopted unchanged")
    let live = peer.liveRecords(sentAfter: mark, under: "t")
    check(live.isEmpty, "nothing of the tree re-announced as live (\(live.prefix(3)))")
    engine.stop()
    peer.close()
}

/// The peer still holds a live record for a child it has since started ignoring (ignored paths are never marked
/// deleted) and deletes the directory, while another file keeps changing (an index update every ~0.4 s). The
/// directory must be kept here — and re-announced — once the peer's index is complete, not only once the index
/// stream goes quiet (it never does while the other file keeps changing).
@MainActor
func staleIgnoredChildChecks() {
    print("Peer deletes a directory holding a child it has since started ignoring, while another file keeps changing")
    let folderID = "adv-stale-01"
    let pair = Pair(name: "adv-stale", folderID: folderID)
    pair.excludeA = { $0.hasSuffix(".log") }
    pair.excludeB = { $0.hasSuffix(".log") }
    let A = pair.dirA, B = pair.dirB
    let old = Date().addingTimeInterval(-3600)
    write(A, "S/x.log", "log", mtime: old)
    write(A, "S/keep.txt", "keep", mtime: old)
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial(folderID) } && pair.settle(60) != nil && read(B, "S/x.log") == "log", "synced (log included)")
    pair.foldersA[0].ignorePatterns = ["*.log"]
    pair.engineA.update(folders: pair.foldersA)
    spin(2.0)
    try? fm.removeItem(atPath: A + "/S")
    let start = Date()
    var tick = 0
    var keptAfter: Double?
    while Date().timeIntervalSince(start) < 10 {
        write(A, "ticker.txt", "tick \(tick)")
        tick += 1
        spin(0.4)
        if keptAfter == nil, !exists(B, "S/keep.txt"), pair.engineB.deferredDirectories(folderID).isEmpty, FS.isDirectory(A + "/S") {
            keptAfter = Date().timeIntervalSince(start)
        }
    }
    check(keptAfter.map { $0 < 7 } == true,
          "B kept S (x.log stays per A's stale record) and A re-created it while the other file kept changing (after \(keptAfter.map { String(format: "%.1f s", $0) } ?? "never"))")
    check(pair.settle(60) != nil && pair.treeA == pair.treeB, "converged — \(treeDiff(pair.treeA, pair.treeB))")
    check(read(B, "S/x.log") == "log" && !exists(B, "S/keep.txt") && FS.isDirectory(A + "/S") && !exists(A, "S/x.log"),
          "S kept on both Macs with only B's log in it")
    let quiet = messagesDuring(pair, 2.0)
    check(quiet == (0, 0), "stable afterwards (A sent \(quiet.0), B sent \(quiet.1) messages in 2 s)")
    pair.stop()
}

/// A scripted peer for directory-deletion checks: serves the files it announces, records what the engine sends.
/// Tree: t/, t/d1/f1…f5.txt, t/d2/g1…g3.txt (records 1…11); deletion: tombstones of t, t/d1, t/d2 first (12…14,
/// "more" follows), then of the files (15…22).
@MainActor
final class DirFakePeer {
    let hubC: LoopbackPeerHub
    let hubF: LoopbackPeerHub
    let folderID: String
    let dir: String
    let stateURL: URL
    var configs: [FolderConfig] { [FolderConfig(id: folderID, label: "R", path: dir, versioning: .none)] }
    let content = Box<[String: Data]>([:])
    let channel = Box<PeerChannel?>(nil)
    let inbox = Box<[(UInt16, String)]>([])
    private let queue = DispatchQueue(label: "fake-dir-peer")
    private let mtime: Int64 = 1_700_000_000_000_000_000

    init(name: String, folderID: String) {
        (hubC, hubF) = LoopbackPeerHub.makePair(nameA: "Checker", nameB: "Fake Peer")
        self.folderID = folderID
        dir = realTempRoot + "/\(name)-C"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        stateURL = URL(fileURLWithPath: realTempRoot + "/\(name)-state")
        let content = self.content, channel = self.channel, inbox = self.inbox, queue = self.queue
        hubF.register(service: "sync") { ch in
            channel.value = ch
            ch.setHandlers(queue: queue, onMessage: { type, payload in
                inbox.mutate { $0.append((type, String(decoding: payload, as: UTF8.self))) }
                guard type == 4, let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      let id = (obj["r"] as? NSNumber)?.uint64Value, let hash = obj["h"] as? String,
                      let offset = (obj["o"] as? NSNumber)?.intValue, let length = (obj["l"] as? NSNumber)?.intValue else { return }
                var frame = Data()
                withUnsafeBytes(of: id.bigEndian) { frame.append(contentsOf: $0) }
                if let data = content.value[hash], offset + length <= data.count {
                    frame.append(0)
                    frame.append(data.subdata(in: offset..<(offset + length)))
                } else {
                    frame.append(1)
                }
                ch.send(type: 5, payload: frame)
            }, onClose: { _ in })
        }
    }

    func makeEngine() -> SyncEngine {
        SyncEngine(hub: hubC, stateDirectory: stateURL, deviceID: hubC.localDeviceID, deviceName: hubC.localDeviceName, options: testOptions)
    }

    func rec(_ path: String, dir isDir: Bool = false, _ text: String? = nil, seq: Int, deleted: Bool = false) -> String {
        var fields = [#""p":"\#(path)""#, #""k":\#(isDir ? 1 : 0)"#, #""m":\#(mtime)"#, #""o":\#(isDir ? 493 : 420)"#,
                      #""v":{"FAKE-DEVICE":\#(seq)}"#, #""q":\#(seq)"#]
        if deleted {
            fields.append(#""d":true"#)
            fields.append(#""s":0"#)
        } else if let text {
            let data = Data(text.utf8)
            content.mutate { $0[sha(data)] = data }
            fields.append(#""s":\#(data.count)"#)
            fields.append(#""h":"\#(sha(data))""#)
        } else {
            fields.append(#""s":0"#)
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    func sendIndex(_ recs: [String], reset: Bool = false, last: Bool = false, more: Bool = false) {
        var head = #""f":"\#(folderID)","i":7"#
        if reset { head += #","r":true"# }
        if last { head += #","l":true"# }
        if more { head += #","m":true"# }
        channel.value?.send(type: 3, payload: Data("{\(head),\"s\":[\(recs.joined(separator: ","))]}".utf8))
    }

    func sendHello() {
        let hello = #"{"v":1,"device":"FAKE-DEVICE","name":"Fake Peer","folders":[{"id":"\#(folderID)","l":"R"}]}"#
        channel.value?.send(type: 1, payload: Data(hello.utf8))
    }

    func sendInitialTree() {
        var initial = [rec("t", dir: true, seq: 1), rec("t/d1", dir: true, seq: 2)]
        initial += (1...5).map { rec("t/d1/f\($0).txt", "f\($0)", seq: 2 + $0) }
        initial += [rec("t/d2", dir: true, seq: 8)] + (1...3).map { rec("t/d2/g\($0).txt", "g\($0)", seq: 8 + $0) }
        sendIndex(initial, reset: true, last: true)
    }

    func sendDirectoryTombstones() {
        sendIndex([rec("t", dir: true, seq: 12, deleted: true), rec("t/d1", dir: true, seq: 13, deleted: true),
                   rec("t/d2", dir: true, seq: 14, deleted: true)], more: true)
    }

    /// The remaining tombstones in two batches, the second one completing the exchange.
    func sendChildTombstones() {
        sendIndex((1...5).map { rec("t/d1/f\($0).txt", seq: 14 + $0, deleted: true) }, more: true)
        sendIndex((1...3).map { rec("t/d2/g\($0).txt", seq: 19 + $0, deleted: true) }, last: true)
    }

    /// Paths at / below `prefix` that the engine announced as live in index messages after inbox position `mark`.
    func liveRecords(sentAfter mark: Int, under prefix: String) -> [String] {
        inbox.value.dropFirst(mark).filter { $0.0 == 3 }.flatMap { message -> [String] in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(message.1.utf8)) as? [String: Any],
                  let records = obj["s"] as? [[String: Any]] else { return [] }
            return records.compactMap { r in
                guard let p = r["p"] as? String, SyncPath.isSameOrInside(p, prefix), (r["d"] as? Bool) != true else { return nil }
                return p
            }
        }
    }

    func close() { hubF.unregister(service: "sync") }
}

// MARK: - Resilience: cloud placeholders, slow disks, damaged / restored index databases

@MainActor
func resilienceChecks() {
    let old = Date().addingTimeInterval(-3600)

    print("iCloud dataless files (optimized storage)")
    do {
        let pair = Pair(name: "cloud", folderID: "cloud-000001")
        let A = pair.dirA, B = pair.dirB
        write(A, "normal.txt", "normal", mtime: old)
        write(A, "photos/cloud.heic", randomData(200_000), mtime: old)
        _ = FS.simulatedDataless.withLock { $0.insert(A + "/photos/cloud.heic") }
        // An expired version is pruned even though this folder's mode is 不保留 (it may stem from an earlier
        // "保存到 .oneswitch/versions" setting or the Trash fallback).
        write(A, ".oneswitch/versions/old~20200101-000000.txt", "expired")
        write(A, ".oneswitch/versions/recent~\(SyncPath.timestamp(Date())).txt", "recent")
        pair.excludeA = { $0 == "photos/cloud.heic" }
        pair.start()
        check(waitUntil(15) { pair.connectedAndInitial("cloud-000001") }, "connected")
        check(waitUntil(20) { read(B, "normal.txt") == "normal" } && pair.converge(30) != nil, "regular files synced")
        spin(0.5)
        check(!exists(B, "photos/cloud.heic") && exists(B, "photos"), "cloud-only file not synced (no empty / partial copy), its folder is")
        check(pair.engineA.localRecord(folderID: "cloud-000001", path: "photos/cloud.heic") == nil, "cloud-only file not indexed")
        let issues = pair.engineA.snapshotNow().folders.first?.issues ?? []
        check(issues.contains { $0.contains("仅存储在 iCloud 中") && $0.contains("photos/cloud.heic") }, "reported: \(issues.first ?? "none")")
        check(waitUntil(5) { !exists(A, ".oneswitch/versions/old~20200101-000000.txt") }, "expired version pruned")
        check(exists(A, ".oneswitch/versions") && ((try? fm.contentsOfDirectory(atPath: A + "/.oneswitch/versions")) ?? []).count == 1,
              "versions within the retention period kept")
        FS.simulatedDataless.withLock { $0.removeAll() } // the user downloads it
        pair.excludeA = { _ in false }
        pair.engineA.rescan(folderID: "cloud-000001")
        check(waitUntil(20) { exists(B, "photos/cloud.heic") } && pair.converge(30) != nil, "synced once downloaded")
        check(!(pair.engineA.snapshotNow().folders.first?.issues ?? []).contains { $0.contains("iCloud") }, "issue cleared")
        pair.stop()
    }

    print("Slow destination disk → memory stays bounded")
    do {
        let pair = Pair(name: "slow", folderID: "slow-000001")
        pair.optionsB.maxOutstandingBytes = 4 << 20
        pair.optionsB.testWriteDelay = 0.03 // ≈ 33 MiB/s disk behind an (instant) loopback link
        var total = 0
        for i in 0..<4 {
            let d = randomData(6 << 20)
            total += d.count
            write(pair.dirA, "big\(i).bin", d, mtime: old)
        }
        let start = Date()
        pair.start()
        check(waitUntil(15) { pair.connectedAndInitial("slow-000001") }, "connected")
        let t = pair.converge(60)
        check(t != nil && Date().timeIntervalSince(start) < 30, "4 × 6 MiB written to a slow disk without stalls (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
        let stats = pair.engineB.snapshotNow().stats
        check(stats.peakBufferedBytes > 0 && stats.peakBufferedBytes <= (4 << 20) + (1 << 20),
              "requested + unwritten block data peaked at \(Fmt.bytes(Int64(stats.peakBufferedBytes))) (bound 4 MiB + 1 block)")
        check(stats.blockBytesReceived == Int64(total), "every byte transferred exactly once (\(stats.blockBytesReceived))")
        pair.stop()
    }

    print("Slow local clone (large renamed file) is not mistaken for a stalled transfer")
    do {
        let pair = Pair(name: "clone", folderID: "clone-000001")
        pair.optionsB.transferStallTimeout = 0.5
        pair.optionsB.testVerifyDelay = 2.0
        let data = randomData(3 << 20)
        write(pair.dirA, "video.mov", data, mtime: old)
        pair.start()
        check(waitUntil(15) { pair.connectedAndInitial("clone-000001") } && pair.converge(30) != nil, "synced")
        let receivedBefore = pair.engineB.snapshotNow().stats.blockBytesReceived
        try? fm.createDirectory(atPath: pair.dirA + "/moved", withIntermediateDirectories: true)
        try? fm.moveItem(atPath: pair.dirA + "/video.mov", toPath: pair.dirA + "/moved/video.mov")
        check(waitUntil(12) { exists(pair.dirB, "moved/video.mov") && !exists(pair.dirB, "video.mov") } && pair.converge(20) != nil,
              "rename applied although verifying the clone outlasts the stall timeout")
        let s = pair.engineB.snapshotNow().stats
        check(s.filesClonedLocally >= 1 && s.blockBytesReceived == receivedBefore, "cloned locally, nothing re-transferred")
        pair.stop()
    }

    print("Index database destroyed → rebuilt without losing or overwriting anything")
    do {
        let pair = Pair(name: "dbfix", folderID: "dbfix-000001")
        let A = pair.dirA, B = pair.dirB
        write(A, "from-a.txt", "A original", mtime: old)
        write(B, "from-b.txt", "B original", mtime: old)
        write(B, "dir/nested.txt", "nested", mtime: old)
        pair.start()
        check(waitUntil(15) { pair.connectedAndInitial("dbfix-000001") } && pair.converge(30) != nil, "synced")
        pair.engineB.stop()
        check(waitUntil(5) { !pair.engineA.snapshotNow().connected }, "B stopped")
        // While B is not running, a file is edited there and B's index database is destroyed.
        write(B, "from-b.txt", "B edited before its index was lost")
        let dbB = pair.stateB.appendingPathComponent("index.sqlite").path
        try? fm.removeItem(atPath: dbB + "-wal")
        try? fm.removeItem(atPath: dbB + "-shm")
        try? randomData(64 * 1024).write(to: URL(fileURLWithPath: dbB))
        let receivedA = pair.engineA.snapshotNow().stats.blockBytesReceived
        pair.engineB = pair.makeEngineB()
        pair.engineB.start(folders: pair.foldersB)
        check(pair.converge(40) != nil, "converged after B rebuilt its index — \(treeDiff(pair.treeA, pair.treeB))")
        check(read(A, "from-b.txt") == "B edited before its index was lost" && read(B, "from-b.txt") == "B edited before its index was lost",
              "B's edit survives on both Macs (not overwritten by A's older version)")
        check(read(A, "from-a.txt") == "A original" && read(B, "dir/nested.txt") == "nested" && conflictCopies(pair.treeA).isEmpty,
              "unchanged files kept, no conflict copies")
        let delta = pair.engineA.snapshotNow().stats.blockBytesReceived - receivedA
        check(delta == Int64("B edited before its index was lost".utf8.count), "only the edited file transferred (\(delta) bytes)")
        let names = (try? fm.contentsOfDirectory(atPath: pair.stateB.path)) ?? []
        check(names.contains { $0.hasPrefix("index.sqlite.corrupt-") }, "damaged database kept aside")

        // Rebuilt index + missing marker: the folder must NOT be re-initialized (it may be a moved or
        // unmounted folder); nothing is deleted anywhere.
        pair.engineB.stop()
        let treeABefore = pair.treeA
        try? fm.removeItem(atPath: B + "/.oneswitch")
        try? fm.removeItem(atPath: B + "/from-a.txt")
        try? fm.removeItem(atPath: dbB + "-wal")
        try? fm.removeItem(atPath: dbB + "-shm")
        try? randomData(64 * 1024).write(to: URL(fileURLWithPath: dbB))
        pair.engineB = pair.makeEngineB()
        pair.engineB.start(folders: pair.foldersB)
        check(waitUntil(10) { pair.engineB.snapshotNow().folders.first?.state == .error(SyncEngine.missingRootMessage) },
              "rebuilt index + missing marker → 错误：文件夹不存在或已被移动")
        spin(2.0)
        check(!FS.isDirectory(B + "/.oneswitch") && pair.treeA == treeABefore, "marker not re-created, A untouched")
        pair.engineB.recreateMarker(folderID: "dbfix-000001")
        check(pair.converge(40) != nil && read(B, "from-a.txt") == "A original", "after 重新创建标记 the folder syncs again")
        pair.stop()
    }

    print("Index database restored from an older copy → new changes still reach the peer")
    do {
        let pair = Pair(name: "rollback", folderID: "rollback-0001")
        let A = pair.dirA, B = pair.dirB
        write(B, "x.txt", "v0", mtime: old)
        pair.start()
        check(waitUntil(15) { pair.connectedAndInitial("rollback-0001") } && pair.converge(30) != nil, "synced")
        pair.engineB.stop()
        let backup = realTempRoot + "/rollback-stateB-backup"
        try? fm.copyItem(atPath: pair.stateB.path, toPath: backup)
        pair.engineB = pair.makeEngineB()
        pair.engineB.start(folders: pair.foldersB)
        for v in 1...4 {
            write(B, "x.txt", "v\(v)")
            check(waitUntil(20) { read(A, "x.txt") == "v\(v)" }, "x.txt v\(v) synced")
        }
        check(pair.converge(30) != nil, "converged")
        pair.engineB.stop()
        try? fm.removeItem(at: pair.stateB)
        try? fm.moveItem(atPath: backup, toPath: pair.stateB.path)
        write(B, "after-restore.txt", "made after the restore")
        pair.engineB = pair.makeEngineB()
        pair.engineB.start(folders: pair.foldersB)
        check(waitUntil(20) { read(A, "after-restore.txt") == "made after the restore" } && pair.converge(30) != nil,
              "change made after restoring an older index reaches A — \(treeDiff(pair.treeA, pair.treeB))")
        check(read(A, "x.txt") == "v4" && read(B, "x.txt") == "v4" && conflictCopies(pair.treeA).isEmpty, "no data rolled back")
        pair.stop()
    }
}

// MARK: - Optional throughput measurement (SYNC_CHECK_BIG=<MiB>)

@MainActor
func throughputCheck(megabytes: Int) {
    print("Throughput (\(megabytes) MiB over loopback)")
    let pair = Pair(name: "big", folderID: "big-000001")
    pair.start()
    check(waitUntil(15) { pair.connectedAndInitial("big-000001") }, "connected")
    let path = pair.dirA + "/huge.bin"
    let chunk = randomData(8 << 20)
    fm.createFile(atPath: path, contents: nil)
    if let h = FileHandle(forWritingAtPath: path) {
        for _ in 0..<(megabytes / 8) { h.write(chunk) }
        try? h.close()
    }
    try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: path)
    let start = Date()
    check(waitUntil(600, poll: 0.02) { pair.engineA.localRecord(folderID: "big-000001", path: "huge.bin") != nil }, "large file indexed on A")
    let indexed = Date()
    check(waitUntil(600, poll: 0.05) { pair.engineB.snapshotNow().stats.filesPulled >= 1 && pair.quiescent() }, "large file transferred")
    let done = Date()
    let hashSeconds = indexed.timeIntervalSince(start), transferSeconds = done.timeIntervalSince(indexed)
    timed(String(format: "\(megabytes) MiB: hash on A %.2f s (%.0f MiB/s), transfer+write+verify on B %.2f s (%.0f MiB/s)",
                 hashSeconds, Double(megabytes) / hashSeconds, transferSeconds, Double(megabytes) / transferSeconds),
          done.timeIntervalSince(start))
    check(tree(pair.dirA) == tree(pair.dirB), "large file identical")
    pair.stop()
    try? fm.removeItem(atPath: pair.dirA)
    try? fm.removeItem(atPath: pair.dirB)
}

// MARK: - Fake peer (protocol robustness)

@MainActor
func fakePeerChecks() {
    print("Protocol robustness (fake peer)")
    let (hubC, hubD) = LoopbackPeerHub.makePair(nameA: "Checker", nameB: "Fake Peer")
    let dirC = realTempRoot + "/fake-C"
    let outside = realTempRoot + "/outside"
    try? fm.createDirectory(atPath: dirC, withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
    let folderID = "fake-000001"
    let engine = SyncEngine(hub: hubC, stateDirectory: URL(fileURLWithPath: realTempRoot + "/fake-state"),
                            deviceID: hubC.localDeviceID, deviceName: hubC.localDeviceName, options: testOptions)
    engine.start(folders: [FolderConfig(id: folderID, label: "Fake", path: dirC, versioning: .none)])
    let caseSensitive = FS.isCaseSensitive(dirC)

    let c1 = Data("upper".utf8), c2 = Data("lower".utf8), c3 = Data("evil".utf8), c4 = Data("through link".utf8)
    let c5 = Data("expected".utf8), c6 = Data("ok content".utf8), c7 = Data("inside a read-only directory".utf8)
    let served: [String: Data] = [sha(c1): c1, sha(c2): c2, sha(c3): c3, sha(c4): c4, sha(c5): Data("tampered".utf8), sha(c6): c6,
                                  sha(c7): c7]
    let channelBox = Box<PeerChannel?>(nil)
    let inbox = Box<[(UInt16, Data)]>([])
    let requests = Box<Int>(0)
    let extra = Box<[String: Data]>([:])
    let holdHashes = Box<Set<String>>([])
    let held = Box<[Data]>([])
    let queue = DispatchQueue(label: "fake-peer")
    hubD.register(service: "sync") { ch in
        channelBox.value = ch
        ch.setHandlers(queue: queue, onMessage: { type, payload in
            inbox.mutate { $0.append((type, payload)) }
            guard type == 4, let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let id = (obj["r"] as? NSNumber)?.uint64Value, let hash = obj["h"] as? String,
                  let offset = (obj["o"] as? NSNumber)?.intValue, let length = (obj["l"] as? NSNumber)?.intValue else { return }
            requests.mutate { $0 += 1 }
            var frame = Data()
            withUnsafeBytes(of: id.bigEndian) { frame.append(contentsOf: $0) }
            if let data = served[hash] ?? extra.value[hash], offset + length <= data.count {
                frame.append(0)
                frame.append(data.subdata(in: offset..<(offset + length)))
            } else {
                frame.append(1)
            }
            if holdHashes.value.contains(hash) {
                held.mutate { $0.append(frame) }
            } else {
                ch.send(type: 5, payload: frame)
            }
        }, onClose: { _ in })
    }
    check(waitUntil(10) { channelBox.value != nil }, "fake peer channel formed")
    let hello = #"{"v":1,"device":"FAKE-DEVICE","name":"Fake Peer","folders":[{"id":"fake-000001","l":"Fake"},{"id":"other-123456","l":"别的文件夹"},{"id":"evil.id","l":"非法 ID"}]}"#
    channelBox.value?.send(type: 1, payload: Data(hello.utf8))
    check(waitUntil(15) {
        inbox.value.contains { $0.0 == 3 && String(decoding: $0.1, as: UTF8.self).contains("\"l\":true") }
    }, "engine sends its initial index (last=true) after scanning")
    check(engine.snapshotNow().offers.map(\.label) == ["别的文件夹"], "unknown remote folder shows up as an offer (invalid id ignored)")

    // Garbage must be ignored without crashing.
    channelBox.value?.send(type: 3, payload: Data("{not json".utf8))
    channelBox.value?.send(type: 0x0100, payload: Data([1, 2, 3]))
    channelBox.value?.send(type: 5, payload: Data([1]))

    let mtime: Int64 = 1_700_000_000_000_000_000
    func rec(_ path: String, _ data: Data?, seq: Int, kind: Int = 0, target: String? = nil) -> String {
        var fields = [#""p":\#(String(data: try! JSONSerialization.data(withJSONObject: [path]), encoding: .utf8)!.dropFirst().dropLast())"#,
                      #""k":\#(kind)"#, #""s":\#(data?.count ?? 0)"#, #""m":\#(mtime)"#, #""o":420"#,
                      #""v":{"FAKE-DEVICE":\#(seq)}"#, #""q":\#(seq)"#]
        if let data { fields.append(#""h":"\#(sha(data))""#) }
        if let target { fields.append(#""t":"\#(target)""#) }
        return "{" + fields.joined(separator: ",") + "}"
    }
    let records = [
        rec("Dup.txt", c1, seq: 1),
        rec("dup.txt", c2, seq: 2),
        rec("../evil.txt", c3, seq: 3),
        rec("lnk", nil, seq: 4, kind: 2, target: outside),
        rec("lnk/x.txt", c4, seq: 5),
        rec("bad.txt", c5, seq: 6),
        rec("sub/ok.txt", c6, seq: 7),
        rec(".oneswitch/evil", c3, seq: 8),
        rec("okdir", nil, seq: 9, kind: 1),
        // A read-only directory (0555) with a file inside: the file must still arrive.
        #"{"p":"rodir","k":1,"s":0,"m":\#(mtime),"o":365,"v":{"FAKE-DEVICE":20},"q":20}"#,
        #"{"p":"rodir/inner.txt","k":0,"s":\#(c7.count),"m":\#(mtime),"o":292,"h":"\#(sha(c7))","v":{"FAKE-DEVICE":21},"q":21}"#,
    ]
    let index = #"{"f":"fake-000001","i":42,"r":true,"l":true,"s":[\#(records.joined(separator: ","))]}"#
    channelBox.value?.send(type: 3, payload: Data(index.utf8))
    check(waitUntil(20) { read(dirC, "sub/ok.txt") == "ok content" && exists(dirC, "okdir") && engine.isQuiescent() },
          "valid files and directories applied")
    check(waitUntil(10) { read(dirC, "rodir/inner.txt") == "inside a read-only directory" }
          && (FS.entry(dirC + "/rodir")?.mode ?? 0) & 0o700 == 0o700 && FS.entry(dirC + "/rodir/inner.txt")?.mode == 0o444,
          "file inside a read-only (0555) directory applied; directory kept writable by its owner, file mode 0444 kept")
    spin(0.5)
    check(read(dirC, "Dup.txt") == "upper", "first of two case variants applied")
    if caseSensitive {
        check(read(dirC, "dup.txt") == "lower", "case-sensitive volume: both variants applied")
    } else {
        let issues = engine.snapshotNow().folders.first?.issues ?? []
        check(issues.contains { $0.contains("dup.txt") && $0.contains("大小写") }, "case conflict reported: \(issues.first ?? "none")")
        let names = (try? fm.contentsOfDirectory(atPath: dirC)) ?? []
        check(names.filter { $0.lowercased() == "dup.txt" } == ["Dup.txt"], "case variant not written over the first one")
    }
    check(!exists(realTempRoot, "evil.txt") && !exists(dirC, ".oneswitch/evil"), "escaping / marker paths rejected")
    var st = stat()
    check(lstat(dirC + "/lnk", &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK, "symlink created as a link")
    check(!exists(outside, "x.txt"), "never writes through a symlinked directory")
    check(!exists(dirC, "bad.txt"), "tampered data rejected by SHA-256 verification")
    let leftovers = ((try? fm.subpathsOfDirectory(atPath: dirC)) ?? []).filter { $0.hasSuffix(".oneswitch-tmp") }
    check(leftovers.isEmpty, "no temp files after failed verification")
    let sent1 = engine.snapshotNow().stats.messagesSent
    let req1 = requests.value
    spin(2.0)
    check(engine.snapshotNow().stats.messagesSent == sent1 && requests.value == req1, "no retry storm for blocked paths")

    // A local edit made while a pull of the same path is in flight must never be overwritten.
    let r1 = Data("race v1".utf8), r2 = Data("race v2 from peer".utf8)
    extra.value = [sha(r1): r1, sha(r2): r2]
    func indexMessage(_ recs: [String]) -> Data {
        Data(#"{"f":"fake-000001","i":42,"s":[\#(recs.joined(separator: ","))]}"#.utf8)
    }
    channelBox.value?.send(type: 3, payload: indexMessage([rec("race.txt", r1, seq: 10)]))
    check(waitUntil(10) { read(dirC, "race.txt") == "race v1" }, "race.txt v1 pulled")
    holdHashes.value = [sha(r2)]
    channelBox.value?.send(type: 3, payload: indexMessage([rec("race.txt", r2, seq: 11)]))
    check(waitUntil(10) { !held.value.isEmpty }, "pull of v2 in flight (peer holds the response)")
    write(dirC, "race.txt", "local edit during pull")
    check(waitUntil(10) {
        engine.localRecord(folderID: folderID, path: "race.txt")?.hash.map(Hex.encode) == sha(Data("local edit during pull".utf8))
    }, "local edit indexed while the pull is in flight")
    for frame in held.value { channelBox.value?.send(type: 5, payload: frame) }
    held.value = []
    holdHashes.value = []
    spin(1.0)
    check(waitUntil(5) { engine.isQuiescent() } && read(dirC, "race.txt") == "local edit during pull",
          "local edit (newer mtime) survives the racing pull: \(read(dirC, "race.txt") ?? "nil")")
    check(conflictCopies(tree(dirC)).isEmpty, "no conflict copy needed (local edit wins)")

    // Same race, but the peer's version is newer: the local edit is preserved as a conflict copy.
    let q1 = Data("race2 v1".utf8), q2 = Data("race2 v2 from peer (newer)".utf8)
    extra.mutate { $0[sha(q1)] = q1; $0[sha(q2)] = q2 }
    func recAt(_ path: String, _ data: Data, seq: Int, mtimeNS: Int64) -> String {
        #"{"p":"\#(path)","k":0,"s":\#(data.count),"m":\#(mtimeNS),"o":420,"h":"\#(sha(data))","v":{"FAKE-DEVICE":\#(seq)},"q":\#(seq)}"#
    }
    channelBox.value?.send(type: 3, payload: indexMessage([recAt("race2.txt", q1, seq: 12, mtimeNS: mtime)]))
    check(waitUntil(10) { read(dirC, "race2.txt") == "race2 v1" }, "race2.txt v1 pulled")
    holdHashes.value = [sha(q2)]
    let future = Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970 * 1e9)
    channelBox.value?.send(type: 3, payload: indexMessage([recAt("race2.txt", q2, seq: 13, mtimeNS: future)]))
    check(waitUntil(10) { !held.value.isEmpty }, "pull of race2 v2 in flight")
    write(dirC, "race2.txt", "local edit 2")
    check(waitUntil(10) {
        engine.localRecord(folderID: folderID, path: "race2.txt")?.hash.map(Hex.encode) == sha(Data("local edit 2".utf8))
            || conflictCopies(tree(dirC)).contains { $0.hasPrefix("race2.") }
    }, "local edit 2 indexed")
    for frame in held.value { channelBox.value?.send(type: 5, payload: frame) }
    held.value = []
    holdHashes.value = []
    let race2Copies = { conflictCopies(tree(dirC)).filter { $0.hasPrefix("race2.") } }
    check(waitUntil(10) { read(dirC, "race2.txt") == "race2 v2 from peer (newer)" && race2Copies().count == 1 && engine.isQuiescent() },
          "newer remote version applied, local edit kept as conflict copy \(race2Copies())")
    check(race2Copies().first.map { read(dirC, $0) } == "local edit 2", "conflict copy holds the local edit")

    // Local edit of a file the peer also has → our index announces it with a dominating vector.
    write(dirC, "sub/ok.txt", "edited locally")
    check(waitUntil(10) {
        inbox.value.contains { $0.0 == 3 && String(decoding: $0.1, as: UTF8.self).contains("sub/ok.txt") && String(decoding: $0.1, as: UTF8.self).contains("\"FAKE-DEVICE\":7") }
    }, "local edit announced with merged vector (FAKE-DEVICE:7 + own counter)")

    engine.stop()
    hubD.unregister(service: "sync")
}

// MARK: - Module (menu / settings state)

@MainActor
func moduleChecks() {
    print("FolderSyncModule")
    let suiteName = "oneswitch.foldersynccheck"
    guard let suite = UserDefaults(suiteName: suiteName) else {
        check(false, "user defaults suite")
        return
    }
    suite.removePersistentDomain(forName: suiteName)
    let (hubM, hubN) = LoopbackPeerHub.makePair()
    let dirM = realTempRoot + "/module-folder"
    try? fm.createDirectory(atPath: dirM + "/sub", withIntermediateDirectories: true)
    let module = FolderSyncModule(hub: hubM, defaults: suite, stateDirectory: URL(fileURLWithPath: realTempRoot + "/module-state"),
                                  options: testOptions)
    check(module.overallLine == "尚未添加同步文件夹", "empty state line")
    module.start()
    check(module.addFolder(path: dirM) == nil, "folder added")
    check(module.addFolder(path: dirM + "/sub") != nil, "overlapping folder rejected")
    check(module.addFolder(path: NSHomeDirectory()) != nil, "home folder rejected")
    check(waitUntil(10) { module.snapshot.folders.first?.state == .waitingForPeer }, "state 等待连接 (peer not running sync)")
    check(module.overallLine == "○ 等待连接另一台 Mac", "overall line: \(module.overallLine)")
    check(FS.isDirectory(dirM + "/.oneswitch"), "safety marker created on add")
    let titles = module.menuItems().map(\.title)
    check(titles.contains("文件同步设置…") && titles.contains("暂停全部同步") && titles.contains { $0.hasPrefix("module-folder — ") },
          "menu: \(titles)")
    _ = module.settingsView()
    module.setPausedAll(true)
    check(module.overallLine == "‖ 已暂停全部同步" && module.menuItems().map(\.title).contains("继续全部同步"), "pause all")
    module.setPausedAll(false)
    let stored = suite.data(forKey: "sync.settings").flatMap { try? JSONDecoder().decode(FolderSyncSettings.self, from: $0) }
    check(stored?.folders.first?.path == dirM && stored?.folders.first?.versioning == .trash, "settings persisted (default versioning 移到废纸篓)")

    // The editor sheet holds a copy of the folder; pausing meanwhile must survive saving it.
    if var edited = module.settings.value.folders.first {
        module.setFolderPaused(edited.id, true)
        edited.label = "新名称"
        edited.versioning = .versions
        module.saveFolder(edited)
        let now = module.settings.value.folders.first
        check(now?.paused == true && now?.label == "新名称" && now?.versioning == .versions, "saving the editor keeps a pause made meanwhile")
        module.setFolderPaused(edited.id, false)
    }
    let remoteCopy = ConflictInfo(folderID: "f", conflictPath: "a.sync-conflict-20260101-000000-MBP.txt", originalPath: "a.txt",
                                  time: Date(), absolutePath: "/tmp/x", createdLocally: false)
    let localCopy = ConflictInfo(folderID: "f", conflictPath: "a.sync-conflict-20260101-000000-Studio.txt", originalPath: "a.txt",
                                 time: Date(), absolutePath: "/tmp/y", createdLocally: true)
    check(FolderSyncModule.conflictMessage(remoteCopy).contains("另一台 Mac 的版本已另存为")
          && FolderSyncModule.conflictMessage(localCopy).contains("本机的版本已另存为"),
          "conflict notification names whose version the copy holds")

    // Corruption detected while running → the engine is restarted and the index rebuilt automatically.
    check(waitUntil(10) { module.snapshot.folders.first?.state == .waitingForPeer }, "folder active again")
    let engineBefore = module.engine
    engineBefore?.simulateIndexCorruption()
    check(waitUntil(15) { module.engine != nil && module.engine !== engineBefore && module.snapshot.folders.first?.state == .waitingForPeer },
          "index corruption at runtime → engine restarted with a rebuilt index (\(module.snapshot.folders.first?.state.displayText ?? "?"))")
    let stateNames = (try? fm.contentsOfDirectory(atPath: realTempRoot + "/module-state")) ?? []
    check(stateNames.contains { $0.hasPrefix("index.sqlite.corrupt-") } && !stateNames.contains("index.rebuild"),
          "damaged index moved aside (\(stateNames.sorted()))")
    module.setEnabled(false)
    check(module.menuItems().first?.title == "文件同步已关闭", "disabled menu")
    module.stop()
    _ = hubN
    removeDefaultsSuite(suite, suiteName)
}

// MARK: - Optional UI rendering (SYNC_CHECK_RENDER=<output directory>)

@MainActor
func renderUI(to directory: String) {
    print("Rendering settings page to \(directory)")
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let suiteName = "oneswitch.foldersynccheck.render"
    let suite = UserDefaults(suiteName: suiteName)!
    suite.removePersistentDomain(forName: suiteName)
    let (hubM, hubP) = LoopbackPeerHub.makePair(nameA: "测试的 Mac Studio", nameB: "测试的 MacBook Pro")
    let dirM = realTempRoot + "/render-M", dirP = realTempRoot + "/render-P", dirQ = realTempRoot + "/render-Q"
    write(dirP, "报告/季度总结.docx", randomData(40_000))
    write(dirP, "照片/IMG_0001.HEIC", randomData(900_000))
    write(dirQ, "a.txt", "a")
    try? fm.createDirectory(atPath: dirM, withIntermediateDirectories: true)
    let module = FolderSyncModule(hub: hubM, defaults: suite, stateDirectory: URL(fileURLWithPath: realTempRoot + "/render-state"),
                                  options: testOptions)
    module.start()
    _ = module.addFolder(path: dirM, label: "文档", folderID: "docs-7f3a2c")
    let peer = SyncEngine(hub: hubP, stateDirectory: URL(fileURLWithPath: realTempRoot + "/render-peer"),
                          deviceID: hubP.localDeviceID, deviceName: hubP.localDeviceName, options: testOptions)
    peer.start(folders: [FolderConfig(id: "docs-7f3a2c", label: "文档", path: dirP, versioning: .none),
                         FolderConfig(id: "photos-00beef", label: "照片库", path: dirQ, versioning: .none)])
    _ = waitUntil(20) { module.snapshot.folders.first?.state == .idle && !module.snapshot.offers.isEmpty }
    let titles = module.menuItems().map { item in item.submenu.map { "\(item.title) ▸ " + $0.items.map(\.title).joined(separator: " | ") } ?? item.title }
    print("  menu:\n    " + titles.joined(separator: "\n    "))
    let host = NSHostingView(rootView: module.settingsView().frame(width: 700, height: 1100))
    host.frame = NSRect(x: 0, y: 0, width: 700, height: 1100)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    spin(1.0)
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = URL(fileURLWithPath: directory).appendingPathComponent("foldersync-settings.png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("  wrote \(url.path)")
    }
    peer.stop()
    module.stop()
    removeDefaultsSuite(suite, suiteName)
}

// MARK: - Run

MainActor.assumeIsolated {
    if let dir = ProcessInfo.processInfo.environment["SYNC_CHECK_RENDER"] {
        renderUI(to: dir)
        try? fm.removeItem(atPath: tempRoot)
        exit(0)
    }
    let t0 = Date()
    // SYNC_CHECK_ONLY=<comma-separated group names> runs a subset while iterating; default: everything.
    let only = ProcessInfo.processInfo.environment["SYNC_CHECK_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    func run(_ name: String, _ body: () -> Void) { if only == nil || only!.contains(name) { body() } }
    run("unit") { unitChecks() }
    run("integration") { integrationChecks() }
    run("race") { concurrentRaceChecks() }
    run("bulk") {
        bulkTreeChecks()
        legacyPeerDirectoryChecks()
        keptDirectoryChecks()
        scanCoalescingChecks()
    }
    run("adversarial") {
        createDuringDeletionChecks()
        deleteWhilePullingChecks()
        renameFlipFlopChecks()
        deepTreeChecks()
        junkOnlyDirectoryChecks()
        emptyDirectoryChecks()
        deleteOnBothChecks()
        kindChangeChecks()
        reversePullRaceChecks()
        multiBatchRenameCloneChecks()
        restartDuringDeletionChecks()
        pauseDuringDeferredDeletionChecks()
        staleIgnoredChildChecks()
    }
    run("resilience") { resilienceChecks() }
    if let mb = ProcessInfo.processInfo.environment["SYNC_CHECK_BIG"].flatMap(Int.init), mb >= 8 {
        throughputCheck(megabytes: mb)
    }
    run("fake") { fakePeerChecks() }
    run("module") { moduleChecks() }
    timed("total", Date().timeIntervalSince(t0))
}
try? fm.removeItem(atPath: tempRoot)
print("Timings:")
for (name, s) in timings { print(String(format: "  %@: %.2f s", name, s)) }
print(failures == 0 ? "FolderSyncCheck: ALL PASSED" : "FolderSyncCheck: \(failures) FAILED")
exit(failures == 0 ? 0 : 1)
