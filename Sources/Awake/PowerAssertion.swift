import AppKit
import CoreGraphics
import IOKit.pwr_mgt
import OneSwitchCore

/// Abstraction over the OS power machinery so the controller can be tested with a fake.
@MainActor
public protocol AwakePowerControlling: AnyObject {
    /// True while the display-sleep assertion is held.
    var isHolding: Bool { get }
    /// Idempotently brings the OS state in line: hold / release the assertion, start / stop the
    /// periodic user-activity declaration.
    func apply(active: Bool, simulateActivity: Bool)
    /// Synchronously releases everything.
    func releaseAll()
}

/// Holds `PreventUserIdleDisplaySleep` (which also prevents idle system sleep) and, optionally,
/// declares user activity every ~50 s so screen-saver / idle-lock timers never fire.
@MainActor
public final class PowerAssertionManager: AwakePowerControlling {
    public static let assertionName = "OneSwitch 防止锁屏"
    /// `kIOPMAssertionTypePreventUserIdleDisplaySleep` (the C macro is a chained CFSTR that Swift does not import).
    public static let assertionType = "PreventUserIdleDisplaySleep"

    public let pingInterval: TimeInterval

    public private(set) var assertionID: IOPMAssertionID = 0
    private var activityID: IOPMAssertionID = 0
    private var pingTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var screenSaverRunning = false
    private var screensAsleep = false

    /// Last time a user-activity declaration succeeded (diagnostics / checks).
    public private(set) var lastActivityDeclaration: Date?
    /// Number of pings skipped because the display was asleep / locked / screensaver running.
    public private(set) var skippedPings = 0

    public init(pingInterval: TimeInterval = 50) {
        self.pingInterval = pingInterval
    }

    public var isHolding: Bool { assertionID != 0 }
    public var isSimulatingActivity: Bool { pingTimer != nil }

    public func apply(active: Bool, simulateActivity: Bool) {
        if active {
            acquireAssertion()
        } else {
            releaseAssertion()
        }
        if active && simulateActivity {
            startActivity()
        } else {
            stopActivity()
        }
    }

    public func releaseAll() {
        stopActivity()
        releaseAssertion()
    }

    // MARK: Display-sleep assertion

    private func acquireAssertion() {
        guard assertionID == 0 else { return }
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(Self.assertionType as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 Self.assertionName as CFString,
                                                 &id)
        if result == kIOReturnSuccess, id != 0 {
            assertionID = id
            AppLog.info("awake", "power assertion acquired (id \(id))")
        } else {
            // Retried on the next evaluation (safety timer).
            AppLog.error("awake", "IOPMAssertionCreateWithName failed: \(String(format: "0x%08x", result))")
        }
    }

    private func releaseAssertion() {
        guard assertionID != 0 else { return }
        let result = IOPMAssertionRelease(assertionID)
        if result != kIOReturnSuccess {
            AppLog.warning("awake", "IOPMAssertionRelease failed: \(String(format: "0x%08x", result))")
        }
        AppLog.info("awake", "power assertion released (id \(assertionID))")
        assertionID = 0
    }

    // MARK: Simulated user activity

    private func startActivity() {
        guard pingTimer == nil else { return }
        installObservers()
        let timer = Timer(timeInterval: pingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.declareUserActivity() }
        }
        timer.tolerance = min(5, pingInterval / 10)
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
        declareUserActivity()
    }

    private func stopActivity() {
        pingTimer?.invalidate()
        pingTimer = nil
        removeObservers()
        if activityID != 0 {
            // The activity assertion may already have timed out on its own; ignore the result.
            _ = IOPMAssertionRelease(activityID)
            activityID = 0
        }
    }

    /// Declares local user activity (reusing the returned id), unless doing so would be intrusive:
    /// a manually slept display would be woken up, and pinging a locked / switched-out session or a
    /// running screensaver is pointless.
    private func declareUserActivity() {
        guard shouldDeclareActivity() else {
            skippedPings += 1
            AppLog.debug("awake", "user-activity ping skipped (display asleep / locked / screensaver)")
            return
        }
        var id = activityID
        var result = IOPMAssertionDeclareUserActivity(Self.assertionName as CFString, kIOPMUserActiveLocal, &id)
        if result != kIOReturnSuccess && activityID != 0 {
            // A stale id may be rejected; retry with a fresh one.
            id = 0
            result = IOPMAssertionDeclareUserActivity(Self.assertionName as CFString, kIOPMUserActiveLocal, &id)
        }
        if result == kIOReturnSuccess {
            activityID = id
            lastActivityDeclaration = Date()
        } else {
            AppLog.warning("awake", "IOPMAssertionDeclareUserActivity failed: \(String(format: "0x%08x", result))")
        }
    }

    private func shouldDeclareActivity() -> Bool {
        if screenSaverRunning || screensAsleep { return false }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return false }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { return false }
            if let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked { return false }
            if let locked = session["CGSSessionScreenIsLocked"] as? Int, locked != 0 { return false }
        }
        return true
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"),
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenSaverRunning = true }
        })
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"),
                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenSaverRunning = false }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = true }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensAsleep = false }
        })
    }

    private func removeObservers() {
        guard !observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        for token in observers {
            distributed.removeObserver(token)
            workspace.removeObserver(token)
        }
        observers.removeAll()
        screenSaverRunning = false
        screensAsleep = false
    }
}
