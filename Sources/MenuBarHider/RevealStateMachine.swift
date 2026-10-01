import Foundation

/// Pure reveal / auto-collapse logic (no timers, no AppKit). Time is always passed in, so the
/// behaviour is fully deterministic and testable with a fake clock.
///
/// - `expand` reveals the hidden section and (when auto-collapse is on) arms a deadline.
/// - Once the deadline has passed, `tick` collapses — unless the user is interacting with the menu
///   bar (pointer in the bar strip, a menu open, a mouse button held, ⌘ held for rearranging), in
///   which case the collapse is postponed and re-checked every `recheckInterval` seconds.
/// - A manual `collapse` clears the deadline; expanding again re-arms it from scratch.
public struct RevealStateMachine: Equatable, Sendable {
    public enum Visibility: String, Equatable, Sendable {
        /// Hidden section collapsed (only icons right of the separator are shown).
        case collapsed
        /// Hidden section shown; the 永久隐藏区 (if enabled) stays hidden.
        case expanded
        /// Everything shown, including the 永久隐藏区 (⌥-click).
        case expandedAll

        public var isExpanded: Bool { self != .collapsed }
    }

    public enum TickOutcome: Equatable, Sendable {
        /// Nothing to do (collapsed, or auto-collapse disabled).
        case idle
        /// Deadline not reached yet; seconds remaining.
        case waiting(TimeInterval)
        /// Deadline passed but the user is interacting — check again later.
        case postponed
        /// The machine just collapsed.
        case collapsed
    }

    public static let recheckInterval: TimeInterval = 0.5

    public private(set) var visibility: Visibility
    /// When the revealed icons will be hidden again (nil = no automatic collapse pending).
    public private(set) var deadline: Date?
    public private(set) var autoCollapse: Bool
    public private(set) var delay: TimeInterval

    public init(visibility: Visibility = .expanded, autoCollapse: Bool, delay: TimeInterval) {
        self.visibility = visibility
        self.autoCollapse = autoCollapse
        self.delay = max(0, delay)
    }

    public var isExpanded: Bool { visibility.isExpanded }

    /// Reveals the hidden section (and the 永久隐藏区 too when `revealAlwaysHidden`). Re-arms the deadline.
    public mutating func expand(now: Date, revealAlwaysHidden: Bool = false) {
        visibility = revealAlwaysHidden ? .expandedAll : .expanded
        deadline = autoCollapse ? now.addingTimeInterval(delay) : nil
    }

    /// Hides the section immediately and cancels any pending automatic collapse.
    public mutating func collapse() {
        visibility = .collapsed
        deadline = nil
    }

    /// Toggle-button semantics: collapsed → expand; expanded + ⌥ → reveal everything; otherwise collapse.
    public mutating func toggle(now: Date, revealAlwaysHidden: Bool = false) {
        switch visibility {
        case .collapsed:
            expand(now: now, revealAlwaysHidden: revealAlwaysHidden)
        case .expanded where revealAlwaysHidden:
            expand(now: now, revealAlwaysHidden: true)
        case .expanded, .expandedAll:
            collapse()
        }
    }

    /// Forces a visibility without arming a deadline (used when the items are (re)installed / removed).
    public mutating func reset(to newVisibility: Visibility) {
        visibility = newVisibility
        deadline = nil
    }

    /// A collapse was requested but refused (e.g. the separator sits right of the toggle): stay
    /// expanded without a pending deadline so we don't retry in a loop.
    public mutating func collapseRefused() {
        if visibility == .collapsed { visibility = .expanded }
        deadline = nil
    }

    /// Applies new settings. While expanded the deadline is re-armed from `now` (or cleared).
    public mutating func updateSettings(autoCollapse: Bool, delay: TimeInterval, now: Date) {
        self.autoCollapse = autoCollapse
        self.delay = max(0, delay)
        if isExpanded {
            deadline = autoCollapse ? now.addingTimeInterval(self.delay) : nil
        }
    }

    /// Evaluates the deadline. `userIsInteracting` postpones an overdue collapse.
    public mutating func tick(now: Date, userIsInteracting: Bool) -> TickOutcome {
        guard isExpanded, let deadline else { return .idle }
        if now < deadline { return .waiting(deadline.timeIntervalSince(now)) }
        if userIsInteracting { return .postponed }
        collapse()
        return .collapsed
    }

    /// Seconds until the next `tick` is worth running (nil = no timer needed).
    public func nextCheckDelay(now: Date) -> TimeInterval? {
        guard isExpanded, let deadline else { return nil }
        let remaining = deadline.timeIntervalSince(now)
        return remaining > 0 ? remaining : Self.recheckInterval
    }
}

/// Drives a `RevealStateMachine` with a (injectable) clock and one-shot scheduler.
///
/// Production uses `Date()` + main-run-loop timers; checks inject a manual clock and a fake scheduler.
@MainActor
public final class AutoCollapseDriver {
    /// Schedules `action` after `delay` seconds; returns a cancel closure.
    public typealias Scheduler = @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> (() -> Void)
    /// Asynchronously reports whether the user is interacting with the menu bar right now.
    public typealias InteractionProbe = @MainActor (_ completion: @escaping @MainActor (Bool) -> Void) -> Void

    public private(set) var machine: RevealStateMachine

    /// Called after every visibility change (manual or automatic).
    public var onVisibilityChange: ((RevealStateMachine.Visibility) -> Void)?
    /// Asked before any collapse; return false to refuse it (the machine then stays expanded).
    public var canCollapse: () -> Bool = { true }

    private let now: () -> Date
    private let schedule: Scheduler
    private let probe: InteractionProbe
    private var cancelPending: (() -> Void)?
    private var generation = 0

    public init(machine: RevealStateMachine,
                now: @escaping () -> Date,
                schedule: @escaping Scheduler,
                probe: @escaping InteractionProbe) {
        self.machine = machine
        self.now = now
        self.schedule = schedule
        self.probe = probe
    }

    /// Main-run-loop timer scheduler (fires in `.common` mode, i.e. also while a menu is tracking).
    public static let runLoopScheduler: Scheduler = { delay, action in
        let timer = Timer(timeInterval: max(0.01, delay), repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    public var visibility: RevealStateMachine.Visibility { machine.visibility }
    public var deadline: Date? { machine.deadline }
    /// True while a timer is armed.
    public var hasPendingCheck: Bool { cancelPending != nil }

    public func expand(revealAlwaysHidden: Bool = false) {
        machine.expand(now: now(), revealAlwaysHidden: revealAlwaysHidden)
        changed()
    }

    /// Returns false when the collapse was refused by `canCollapse`.
    @discardableResult
    public func collapse() -> Bool {
        guard canCollapse() else {
            machine.collapseRefused()
            changed()
            return false
        }
        machine.collapse()
        changed()
        return true
    }

    public func toggle(revealAlwaysHidden: Bool = false) {
        var next = machine
        next.toggle(now: now(), revealAlwaysHidden: revealAlwaysHidden)
        if next.visibility == .collapsed {
            collapse()
        } else {
            machine = next
            changed()
        }
    }

    public func updateSettings(autoCollapse: Bool, delay: TimeInterval) {
        machine.updateSettings(autoCollapse: autoCollapse, delay: delay, now: now())
        reschedule()
    }

    /// Sets the visibility without a deadline and without consulting `canCollapse`.
    public func reset(to visibility: RevealStateMachine.Visibility) {
        machine.reset(to: visibility)
        changed()
    }

    /// Cancels any pending timer (used by `stop()`).
    public func invalidate() {
        generation += 1
        cancelPending?()
        cancelPending = nil
    }

    private func changed() {
        reschedule()
        onVisibilityChange?(machine.visibility)
    }

    private func reschedule() {
        invalidate()
        guard let delay = machine.nextCheckDelay(now: now()) else { return }
        let gen = generation
        cancelPending = schedule(delay) { [weak self] in
            self?.fire(generation: gen)
        }
    }

    private func fire(generation gen: Int) {
        guard gen == generation else { return }
        cancelPending = nil
        if let deadline = machine.deadline, now() < deadline {
            reschedule()
            return
        }
        probe { [weak self] interacting in
            guard let self, gen == self.generation else { return }
            var next = self.machine
            switch next.tick(now: self.now(), userIsInteracting: interacting) {
            case .collapsed:
                // Route through collapse() so `canCollapse` (separator order safety) is honoured.
                self.collapse()
            case .idle, .waiting, .postponed:
                self.reschedule()
            }
        }
    }
}
