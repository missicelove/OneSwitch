import Foundation

/// A manual 防止锁屏 session.
public struct ManualSession: Codable, Equatable, Sendable {
    public var startedAt: Date
    /// nil = 无限期 (until turned off).
    public var endsAt: Date?
    /// Requested duration in minutes; nil = 无限期.
    public var minutes: Int?

    public init(startedAt: Date, endsAt: Date?, minutes: Int?) {
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.minutes = minutes
    }

    public var isInfinite: Bool { endsAt == nil }
}

/// Mutable runtime state of the state machine (persisted under "awake.state" so that a relaunch
/// restores a running session and an active suppression).
public struct AwakeRuntimeState: Codable, Equatable, Sendable {
    public var session: ManualSession?
    /// Manual "关闭" while the schedule wanted to be on; cleared by the next scheduleDesired change.
    public var suppressed: Bool
    /// scheduleDesired at the previous evaluation.
    public var lastScheduleDesired: Bool?
    /// Time of the previous evaluation (to detect transitions missed while asleep / not running).
    public var lastEvaluated: Date?

    public init(session: ManualSession? = nil, suppressed: Bool = false,
                lastScheduleDesired: Bool? = nil, lastEvaluated: Date? = nil) {
        self.session = session
        self.suppressed = suppressed
        self.lastScheduleDesired = lastScheduleDesired
        self.lastEvaluated = lastEvaluated
    }
}

/// Snapshot of the module's state after an evaluation.
public struct AwakeStatus: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case off
        /// Held by a manual session (timed or infinite).
        case manual
        /// Held by the automatic schedule.
        case schedule
    }

    public var mode: Mode
    public var session: ManualSession?
    public var scheduleEnabled: Bool
    public var scheduleDesired: Bool
    public var suppressed: Bool
    /// Next instant at which scheduleDesired changes.
    public var nextTransition: Date?
    /// Next instant at which the schedule turns on (nil while it is currently holding).
    public var nextActivation: Date?
    /// Earliest instant at which the state may change by itself (session end or schedule transition).
    public var nextDeadline: Date?
    public var today: DayInfo

    public var isActive: Bool { mode != .off }
}

/// The pure 防止锁屏 state machine:
///
/// active = manualSessionActive || (scheduleDesired && !suppressed)
///
/// - Manual "关闭" while scheduleDesired sets `suppressed` (stays off until the next scheduleDesired change).
/// - Starting a manual session (timed or infinite) clears the suppression.
/// - Any change of scheduleDesired — including changes caused by settings and transitions that happened
///   while the Mac was asleep or the app was not running — clears the suppression.
/// - A manual session runs until its own expiry, independent of the schedule window.
public struct AwakeEngine: Equatable, Sendable {
    public var state: AwakeRuntimeState

    public init(state: AwakeRuntimeState = AwakeRuntimeState()) {
        self.state = state
    }

    public struct Evaluation: Equatable, Sendable {
        public var status: AwakeStatus
        /// The timed session that ended in this evaluation, if any.
        public var expiredSession: ManualSession?
        public var suppressionCleared: Bool
        /// True when a persisted field other than `lastEvaluated` changed.
        public var stateChanged: Bool
    }

    public mutating func evaluate(policy: AwakePolicy, now: Date) -> Evaluation {
        let before = state
        let desired = policy.scheduleDesired(at: now)

        var cleared = false
        if state.suppressed {
            var transitioned = false
            if let last = state.lastScheduleDesired, last != desired { transitioned = true }
            if !transitioned, let lastEval = state.lastEvaluated, lastEval < now,
               let t = policy.nextTransition(after: lastEval), t <= now {
                transitioned = true
            }
            // Suppression only means something while the schedule wants to be on.
            if transitioned || !desired {
                state.suppressed = false
                cleared = true
            }
        }

        var expired: ManualSession?
        if let session = state.session, let end = session.endsAt, end <= now {
            expired = session
            state.session = nil
        }

        state.lastScheduleDesired = desired
        state.lastEvaluated = now

        let status = makeStatus(policy: policy, now: now, desired: desired)
        let changed = before.session != state.session || before.suppressed != state.suppressed
            || before.lastScheduleDesired != state.lastScheduleDesired
        return Evaluation(status: status, expiredSession: expired, suppressionCleared: cleared, stateChanged: changed)
    }

    /// Starts a manual session: `minutes` (clamped to 5…720) or nil for 无限期. Clears suppression.
    public mutating func startSession(minutes: Int?, now: Date) {
        let m = minutes.map(AwakeLimits.clampSession)
        state.session = ManualSession(startedAt: now,
                                      endsAt: m.map { now.addingTimeInterval(TimeInterval($0 * 60)) },
                                      minutes: m)
        state.suppressed = false
    }

    /// Manual "关闭": ends the manual session; if the schedule currently wants to be on, suppresses it
    /// until its next transition.
    public mutating func turnOff(policy: AwakePolicy, now: Date) {
        // Bring transition tracking up to date first, so a transition that happened before `now`
        // (e.g. while asleep) cannot clear the suppression we are about to set.
        _ = evaluate(policy: policy, now: now)
        state.session = nil
        state.suppressed = policy.scheduleDesired(at: now)
    }

    /// Status without mutating (e.g. for an initial snapshot).
    public func peek(policy: AwakePolicy, now: Date) -> AwakeStatus {
        var copy = self
        return copy.evaluate(policy: policy, now: now).status
    }

    private func makeStatus(policy: AwakePolicy, now: Date, desired: Bool) -> AwakeStatus {
        let mode: AwakeStatus.Mode
        if state.session != nil {
            mode = .manual
        } else if desired && !state.suppressed {
            mode = .schedule
        } else {
            mode = .off
        }
        let transition = policy.nextTransition(after: now)
        let holdingBySchedule = desired && !state.suppressed
        let activation: Date?
        if holdingBySchedule {
            activation = nil
        } else if !desired {
            activation = transition
        } else {
            activation = policy.nextActivation(after: now)
        }
        var deadline = transition
        if let end = state.session?.endsAt {
            deadline = deadline.map { min($0, end) } ?? end
        }
        return AwakeStatus(mode: mode,
                           session: state.session,
                           scheduleEnabled: policy.scheduleEnabled,
                           scheduleDesired: desired,
                           suppressed: state.suppressed,
                           nextTransition: transition,
                           nextActivation: activation,
                           nextDeadline: deadline,
                           today: policy.dayInfo(for: now))
    }
}
