import Foundation
import CryptoKit
import Darwin
import os

/// Thin POSIX helpers. Paths are absolute; nothing here follows symlinks unless stated.
enum FS {
    /// Absolute paths treated as dataless in addition to those flagged by the file system. Self-checks only:
    /// real dataless files (iCloud Drive "optimized storage", other File Provider placeholders) cannot be
    /// created without a file provider.
    static let simulatedDataless = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// True for a dataless placeholder: its content lives in the cloud and *reading it would download it*.
    /// Such files are never hashed, served or cloned (no download storms, never synced as empty files).
    static func isDataless(flags: UInt32, path: String) -> Bool {
        if flags & UInt32(SF_DATALESS) != 0 { return true }
        return simulatedDataless.withLock { $0.isEmpty ? false : $0.contains(path) }
    }

    /// Thrown by `sha256` for dataless files (the content was not read).
    struct DatalessError: Error {}

    enum StatResult {
        case entry(DiskState)
        case missing
        /// Exists but is not a regular file / directory / symlink (fifo, socket, device).
        case unsupported
        case error(Int32)
    }

    static func lstatEntry(_ path: String) -> StatResult {
        var st = stat()
        if lstat(path, &st) != 0 {
            let e = errno
            return (e == ENOENT || e == ENOTDIR) ? .missing : .error(e)
        }
        let type = st.st_mode & S_IFMT
        // Permission bits only: setuid / setgid / sticky are never synced.
        let mode = UInt32(st.st_mode & 0o777)
        let mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        switch type {
        case S_IFREG:
            return .entry(DiskState(kind: .file, size: Int64(st.st_size), mtimeNS: mtime, mode: mode, target: nil,
                                    dataless: isDataless(flags: st.st_flags, path: path)))
        case S_IFDIR:
            return .entry(DiskState(kind: .directory, size: 0, mtimeNS: mtime, mode: mode, target: nil))
        case S_IFLNK:
            guard let target = readLink(path) else { return .error(errno) }
            return .entry(DiskState(kind: .symlink, size: 0, mtimeNS: mtime, mode: mode, target: target))
        default:
            return .unsupported
        }
    }

    /// Convenience: the entry, or nil when missing / unreadable / unsupported.
    static func entry(_ path: String) -> DiskState? {
        if case .entry(let d) = lstatEntry(path) { return d }
        return nil
    }

    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    static func readLink(_ path: String) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buf, buf.count - 1)
        guard n >= 0 else { return nil }
        buf[n] = 0
        return String(cString: buf)
    }

    /// Directory listing (names as stored on disk, not normalized). Errors carry errno.
    enum Listing {
        case success([String])
        case failure(Int32)
    }

    /// A listing that stops early because of an I/O error is a failure, never a shorter success: a
    /// truncated listing would make the scanner report every entry after the error as deleted.
    static func listDirectory(_ path: String) -> Listing {
        guard let dir = opendir(path) else {
            return .failure(errno)
        }
        defer { closedir(dir) }
        var names: [String] = []
        while true {
            errno = 0
            guard let ent = readdir(dir) else {
                let code = errno
                if code != 0 { return .failure(code) }
                break
            }
            let name: String = withUnsafePointer(to: &ent.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return .success(names)
    }

    struct HashError: Error { let code: Int32 }

    /// Streaming SHA-256 in 1 MiB chunks. Returns nil when `cancelled()` became true.
    /// Throws `DatalessError` (without reading anything) for a dataless placeholder.
    static func sha256(path: String, chunkSize: Int = 1 << 20, cancelled: () -> Bool = { false }) throws -> (digest: Data, bytes: Int64)? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HashError(code: errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw HashError(code: errno) }
        if isDataless(flags: st.st_flags, path: path) { throw DatalessError() }
        _ = fcntl(fd, F_RDAHEAD, 1)
        var hasher = SHA256()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buffer.deallocate() }
        var total: Int64 = 0
        while true {
            if cancelled() { return nil }
            let n = read(fd, buffer, chunkSize)
            if n < 0 {
                if errno == EINTR { continue }
                throw HashError(code: errno)
            }
            if n == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
            total += Int64(n)
        }
        return (Data(hasher.finalize()), total)
    }

    static func sha256(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static let emptyHash: Data = Data(SHA256.hash(data: Data()))

    /// Nanoseconds since 1970 → timespec with 0 ≤ tv_nsec < 1e9 (also for times before 1970, where
    /// truncating division would yield a negative, invalid tv_nsec).
    static func timespec(ns: Int64) -> Darwin.timespec {
        var sec = ns / 1_000_000_000
        var nsec = ns % 1_000_000_000
        if nsec < 0 {
            nsec += 1_000_000_000
            sec -= 1
        }
        return Darwin.timespec(tv_sec: Int(sec), tv_nsec: Int(nsec))
    }

    /// Sets the modification (and access) time with nanosecond precision.
    @discardableResult
    static func setModificationTime(_ path: String, ns: Int64, followSymlinks: Bool = false) -> Bool {
        var times = [timespec(ns: ns), timespec(ns: ns)]
        return utimensat(AT_FDCWD, path, &times, followSymlinks ? 0 : AT_SYMLINK_NOFOLLOW) == 0
    }

    static func setModificationTime(fd: Int32, ns: Int64) -> Bool {
        var times = [timespec(ns: ns), timespec(ns: ns)]
        return futimens(fd, &times) == 0
    }

    /// rename() that fails with EEXIST instead of replacing an existing destination (used whenever the
    /// destination is expected to be absent, so an entry created there meanwhile is never overwritten).
    static func renameExclusive(_ from: String, _ to: String) -> Bool {
        renamex_np(from, to, UInt32(RENAME_EXCL)) == 0
    }

    /// The name of the final path component exactly as stored on disk (differs in case from the
    /// requested name on case-insensitive volumes when a case variant exists).
    static func onDiskName(_ path: String) -> String? {
        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_NAME)
        let bufSize = 4 + MemoryLayout<attrreference_t>.size + Int(NAME_MAX) * 4 + 1
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }
        guard getattrlist(path, &attrList, buf, bufSize, UInt32(FSOPT_NOFOLLOW)) == 0 else { return nil }
        let refPtr = buf.advanced(by: 4)
        let ref = refPtr.load(as: attrreference_t.self)
        let namePtr = refPtr.advanced(by: Int(ref.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
        return String(cString: namePtr)
    }

    /// True when the volume containing `path` distinguishes case.
    static func isCaseSensitive(_ path: String) -> Bool {
        pathconf(path, _PC_CASE_SENSITIVE) == 1
    }

    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// mkdir -p for the directories between `base` (must exist) and `path`. Returns false on failure.
    static func makeDirectories(_ path: String, mode: mode_t = 0o755) -> Bool {
        if isDirectory(path) { return true }
        let parent = (path as NSString).deletingLastPathComponent
        if parent != path && !parent.isEmpty && !isDirectory(parent) {
            guard makeDirectories(parent, mode: mode) else { return false }
        }
        if mkdir(path, mode) == 0 { return true }
        return errno == EEXIST && isDirectory(path)
    }

    static func errorString(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    /// User-facing Chinese description of an errno value.
    static func localizedError(_ code: Int32) -> String {
        switch code {
        case EACCES, EPERM: return "没有权限"
        case ENOENT: return "文件不存在"
        case ENOSPC: return "磁盘空间不足"
        case EDQUOT: return "超出磁盘配额"
        case EROFS: return "磁盘为只读"
        case EIO: return "读写错误"
        case EBUSY: return "文件正在使用中"
        case ENAMETOOLONG: return "文件名过长"
        case ENOTEMPTY: return "文件夹不为空"
        case EEXIST: return "文件已存在"
        default: return "错误 \(code)（\(errorString(code))）"
        }
    }

    /// Reads exactly `length` bytes at `offset` into a Data that starts with `headerSize` zero bytes.
    /// Returns nil on short read / error.
    static func readBlock(fd: Int32, offset: Int64, length: Int, headerSize: Int) -> Data? {
        var data = Data(count: headerSize + length)
        let ok: Bool = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var done = 0
            while done < length {
                let n = pread(fd, base.advanced(by: headerSize + done), length - done, off_t(offset) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if n == 0 { return false }
                done += n
            }
            return true
        }
        return ok ? data : nil
    }

    /// Writes all of `data` at `offset`.
    static func writeAll(fd: Int32, data: Data, offset: Int64) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var done = 0
            while done < raw.count {
                let n = pwrite(fd, base.advanced(by: done), raw.count - done, off_t(offset) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                done += n
            }
            return true
        }
    }
}
