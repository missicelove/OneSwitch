import AppKit
import OneSwitchCore

// 点击时钟打开通知中心: the controller's side of `NotificationCenterClockAssist` (see
// NotificationCenterAssist.swift). The assist decides when; the controller releases and restores through
// the auto-collapse driver, so the toggle, menus and settings page always show the real state.
//
// - engage: the driver is reset to "show everything" without a deadline (like 显示全部, but the auto-hide
//   timer does not run while Notification Center is open), which drops the restriction.
// - restore: collapsed → the driver is reset to collapsed (a fresh collapse). A partial reveal → collapse,
//   and once that restriction is granted, expand again (what fits is re-planned, the auto-hide re-armed).
// - Any visibility change the assist did not make ends the episode without restoring (user action).

extension MenuBarHiderController {
    func setUpClockAssist(_ dependencies: NotificationCenterAssistDependencies) {
        let assist = NotificationCenterClockAssist(dependencies: dependencies)
        assist.canEngage = { [weak self] in self?.clockAssistCanEngage ?? false }
        assist.engage = { [weak self] in self?.clockAssistEngage() }
        assist.restore = { [weak self] previous in self?.clockAssistRestore(previous) }
        assist.isInteracting = { [weak self] completion in
            guard let self else { return completion(false) }
            if let probe = self.clockAssistDeps?.isInteracting {
                probe(completion)
            } else {
                self.probeInteraction(completion)
            }
        }
        assist.onPhaseChange = { [weak self] phase in
            self?.notificationCenterAssistActive = phase == .released || phase == .watching
        }
        clockAssistDeps = dependencies
        clockAssist = assist
    }

    /// The feature is wired in and switched on, and 系统原生隐藏 is in use.
    var clockAssistWatchesNotificationCenter: Bool {
        clockAssist != nil && current.enabled && current.clockOpensNotificationCenter && engineKind == .native
    }

    /// The click monitor is installed (for diagnostics and the self-checks).
    public var clockAssistMonitoring: Bool { clockMonitorRemover != nil }

    /// Where the assist is (for diagnostics and the self-checks); nil when not wired in.
    public var clockAssistPhase: NotificationCenterClockAssist.Phase? { clockAssist?.phase }

    /// Whether the auto-hide would wait right now: a menu is open, the pointer is in the bar, a button or ⌘
    /// is held — or, with 点击时钟打开通知中心, Notification Center is open (a restriction would disable it).
    public func isMenuBarInUse(_ completion: @escaping @MainActor (Bool) -> Void) {
        probeInteraction(completion)
    }

    /// A restriction is held (collapsed, or a partial reveal) and the feature is on.
    var clockAssistCanEngage: Bool {
        started && isActive && clockAssistWatchesNotificationCenter && driver.visibility != .expandedAll
            && (nativeEngine?.isRestricted ?? false)
    }

    /// Installs / removes the click monitor to match the settings and the engine. Switching the feature off
    /// (or away from 系统原生隐藏) during an episode puts the previous state back.
    func syncClockAssist() {
        guard let assist = clockAssist, let dependencies = clockAssistDeps else { return }
        if started && isActive && clockAssistWatchesNotificationCenter {
            guard clockMonitorRemover == nil else { return }
            clockMonitorRemover = dependencies.monitorClicks { [weak self] event in self?.clockAssist?.handle(event) }
            AppLog.debug("menubar", "clock assist: watching clicks on the clock")
            return
        }
        if let remove = clockMonitorRemover {
            remove()
            clockMonitorRemover = nil
            AppLog.debug("menubar", "clock assist: no longer watching clicks")
        }
        assist.cancel(restore: started && isActive && engineKind == .native, reason: "the feature was switched off")
    }

    /// Module stop: the monitor goes, an episode ends without restoring (everything is released anyway), and a
    /// click being posted completes (the button is never left down).
    func stopClockAssist() {
        clockRestoreReveal = false
        clockAssist?.cancel(restore: false, reason: "the module stopped")
        if let remove = clockMonitorRemover {
            remove()
            clockMonitorRemover = nil
        }
        clockAssistDeps?.drain()
    }

    /// Releases the restriction for Notification Center; returns what to restore afterwards.
    func clockAssistEngage() -> ClockAssistPrevious? {
        guard clockAssistCanEngage else { return nil }
        // Collapsed as the first step of restoring a partial reveal (the reveal is still to come): that
        // partial reveal is what the bar returns to.
        let previous: ClockAssistPrevious = driver.visibility == .collapsed && !clockRestoreReveal ? .collapsed : .revealed
        cancelInitialCollapse()
        clockRestoreReveal = false
        drivenByClockAssist { driver.reset(to: .expandedAll) } // no deadline; drops the restriction
        return previous
    }

    /// Notification Center closed: back to where the bar was.
    func clockAssistRestore(_ previous: ClockAssistPrevious) {
        guard started, isActive, engineKind == .native, current.enabled, driver.visibility == .expandedAll else { return }
        clockRestoreReveal = previous == .revealed
        drivenByClockAssist { driver.reset(to: .collapsed) } // → a fresh collapse (positions re-read)
    }

    /// The collapse of a restore was granted: a partial reveal expands again (out of the engine's call chain).
    func clockAssistCollapseGranted() {
        guard clockRestoreReveal else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.clockRestoreReveal else { return }
                self.clockRestoreReveal = false
                guard self.started, self.isActive, self.engineKind == .native, self.driver.visibility == .collapsed,
                      self.nativeState == .collapsed else { return }
                AppLog.info("menubar", "clock assist: showing the icons that fit again")
                self.drivenByClockAssist { self.driver.expand() } // auto-hide re-armed
            }
        }
    }

    /// The auto-hide settings changed during an episode: `updateSettings` re-armed the deadline of the
    /// expanded driver — the bar stays shown without one while Notification Center is open (the restore
    /// re-arms it where the previous state has one).
    func clockAssistKeepDeadlineOff() {
        guard let assist = clockAssist, assist.isEngaged, driver.visibility == .expandedAll, driver.deadline != nil else { return }
        drivenByClockAssist { driver.reset(to: .expandedAll) }
    }

    /// The bar was changed by someone else during an episode (see `visibilityChanged`).
    func clockAssistNoteExternalChange() {
        clockRestoreReveal = false
        guard let assist = clockAssist, assist.isEngaged else { return }
        assist.cancel(restore: false, reason: "the menu bar was changed meanwhile")
    }

    private func drivenByClockAssist(_ body: () -> Void) {
        let was = clockAssistDriving
        clockAssistDriving = true
        body()
        clockAssistDriving = was
    }
}
