import Foundation

/// Top processes by CPU via `/bin/ps -Aceo pid,pcpu,comm -r`. Runs synchronously on the caller's
/// (background) queue; never call it on the main thread.
final class ProcessSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Process?

    func topProcesses(limit: Int = 5, timeout: TimeInterval = 3) -> [ProcessUsage]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid,pcpu,comm", "-r"]
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        lock.lock(); running = process; lock.unlock()
        let watchdog = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        lock.lock(); running = nil; lock.unlock()
        try? pipe.fileHandleForReading.close()
        guard process.terminationStatus == 0 else { return nil }
        return Self.parse(String(decoding: data, as: UTF8.self), limit: limit)
    }

    /// Terminates a ps run that is still in flight (used by stop()).
    func cancel() {
        lock.lock(); let p = running; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    /// Parses ps output ("  PID  %CPU COMM" header, then one process per line; COMM may contain spaces).
    static func parse(_ output: String, limit: Int) -> [ProcessUsage] {
        var result: [ProcessUsage] = []
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")) else { continue }
            let name = fields[2].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            result.append(ProcessUsage(pid: pid, cpuPercent: cpu, name: name))
        }
        // ps -r already sorts by CPU; sort again to be independent of the ps implementation.
        result.sort { $0.cpuPercent > $1.cpuPercent }
        return Array(result.prefix(limit))
    }
}
