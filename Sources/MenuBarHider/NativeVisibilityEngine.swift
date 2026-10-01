import AppKit
import OneSwitchCore

/// macOS 27+ hiding through the system's menu-bar visibility restriction (see NativeVisibility.swift).
///
/// - collapse: read where every app's icons are (only while the bar is unrestricted — hidden items keep
///   stale frames; during a partial reveal only the shown apps are re-read), build the allow-list from the
///   positions and the per-app rules, activate a new restriction and only then drop the previous one
///   ("replace, then drop": no flash of the full bar when the rules change while collapsed). Once granted,
///   the collapsed bar is measured (where its icons end) for the next reveal.
/// - reveal (expand): show the hidden apps that fit on「<」's side of the bar — a restriction allowing the
///   collapsed allow-list plus those apps (replace, then drop); when every hidden app fits, or the room
///   cannot be told, drop the restriction as before (see NativeReveal.swift). A partial reveal is checked
///   once it settled: if macOS shows its « anyway or dropped one of our items, the farthest revealed app is
///   hidden again. While it is shown, `recheckReveal` (another app in front, an app started) hides again what
///   no longer fits — a partial reveal only ever shrinks.
/// - expand (show everything): drop the restriction; macOS shows everything again.
/// - Every request bumps `generation`; a snapshot, probe or activation that completes after it was
///   superseded is ignored, and a late restriction is invalidated straight away.
/// - Fail open: an activation error — or a read / probe / activation that never answers — releases every
///   restriction (icons visible) and is reported.
///
/// The restriction also ends when this process exits, so a crash never leaves icons hidden.
/// Pure logic + injected dependencies: the self-checks drive it with fakes.
@MainActor
public final class NativeVisibilityEngine {
    public enum State: String, Equatable, Sendable {
        case expanded
        /// A snapshot / probe / activation is in flight.
        case activating
        case collapsed
        /// Expanded, but only the hidden apps that fit are shown (a restriction is still held).
        case revealed
    }

    public enum Outcome: Equatable, Sendable {
        /// The restriction is active (the plan that was applied).
        case collapsed(NativeHidingPlan)
        /// Nothing is hidden any more; the reason (English, for logs / UI details).
        case failed(String)
    }

    public enum RevealOutcome: Equatable, Sendable {
        /// Every icon is shown (restriction released): nothing was hidden, everything fits (the plan), or
        /// the room could not be told (nil).
        case all(NativeRevealPlan?)
        /// Only `revealed` were added; `unfit` / `withheld` stay hidden (a restriction is held).
        case partial(NativeRevealPlan)
        /// Reading the room or activating failed / timed out: everything is shown (fail open).
        case failed(String)
    }

    private let deps: NativeHidingDependencies
    private let toggleFrame: () -> CGRect?

    public private(set) var state: State = .expanded
    /// Placement read from the last unrestricted bar (reused while restricted).
    public private(set) var layout: NativeLayout?
    /// The collapsed plan: of the active restriction while collapsed, and the base of a partial reveal
    /// (nil while everything is shown).
    public private(set) var activePlan: NativeHidingPlan?
    /// The partial reveal being shown (nil otherwise).
    public private(set) var activeReveal: NativeRevealPlan?
    /// What is known about each app's icons (count, width, position), from every read.
    public private(set) var metrics: [String: NativeAppMetrics] = [:]
    /// Bumped by every collapse / reveal / expand / release; completions of older requests are discarded.
    public private(set) var generation = 0
    /// Bumped whenever a timed phase of a request starts (position read, probe, activation).
    private var phase = 0
    private var assertion: NativeVisibilityAssertion?
    /// Allow-list of the held restriction.
    private var heldAllowed: [String]?
    /// The collapsed bar as measured after its restriction took effect (for that allow-list): the room the
    /// other apps' shown icons take from the status-item edge (the same on every display, so it survives「<」
    /// moving to another display's menu bar), and whether macOS showed its «.
    private var measurement: (allowed: [String], othersUsed: CGFloat?, overflowed: Bool)?
    /// Menu-bar direction of the last read.
    private var lastRightToLeft: Bool?

    /// The collapsed bar a partial reveal was planned from. Kept for the re-checks while it is shown:
    /// revealed icons push our own items (and possibly「<」) further in, so their frames at that point must
    /// not be taken as the collapsed bar's edge again (that would count the revealed icons twice).
    private struct RevealContext {
        /// Room everything shown while collapsed takes, from the status-item edge (the right edge; the left
        /// one right-to-left). Every display lays the status items out from that edge, so this holds wherever
        /// 「<」is (it follows the active menu bar between displays).
        var usedWidth: CGFloat
        /// macOS already showed its « while collapsed (no room at all).
        var collapsedOverflowed: Bool
        /// Our own items just before the reveal (nil = not readable).
        var ownBefore: NativeOwnItems?
        var rightToLeft: Bool

        /// Inner edge of the collapsed bar's icons on the display of `band` (CG x).
        func innerEdge(on band: CGRect) -> CGFloat {
            rightToLeft ? band.minX + usedWidth : band.maxX - usedWidth
        }
    }
    private var revealContext: RevealContext?

    /// Called with every freshly read layout (settings list).
    public var onLayout: ((NativeLayout) -> Void)?
    /// Called when a partial reveal changes on its own (the bar overflowed after all).
    public var onRevealUpdate: ((RevealOutcome) -> Void)?

    /// - Parameter toggleFrame: the「<」toggle's frame in CG coordinates (nil when not laid out).
    public init(dependencies: NativeHidingDependencies, toggleFrame: @escaping () -> CGRect?) {
        self.deps = dependencies
        self.toggleFrame = dependencies.toggleFrame ?? toggleFrame
    }

    public var isAvailable: Bool { deps.visibility.isAvailable }
    /// Accessibility is granted (positions can be read).
    public var isAuthorized: Bool { deps.inventory.isAuthorized }
    /// A restriction is held right now.
    public var isRestricted: Bool { assertion != nil }
    /// The login session is locked right now.
    public var isSessionLocked: Bool { deps.isSessionLocked() }

    private var ownBundleSet: Set<String> { Set(deps.ownBundleIDs) }
    private var rightToLeft: Bool { lastRightToLeft ?? deps.rightToLeft() }

    // MARK: Collapse / expand

    /// Hides every app that should be hidden (or re-applies with new rules while collapsed).
    /// `completion` is not called when the request is superseded by a later collapse / expand.
    /// A position read or an activation that stays unanswered (`snapshotTimeout` / `activationTimeout`)
    /// fails open like an activation error: everything is released and a late grant is invalidated on
    /// arrival.
    /// - Parameter preAllowed: apps remembered as visible (see `NativeHidingPlan.make`).
    public func collapse(rules: [String: AppVisibilityRule], preAllowed: @escaping @MainActor () -> [String] = { [] },
                         completion: @escaping @MainActor (Outcome) -> Void) {
        generation += 1
        let gen = generation
        guard deps.visibility.isAvailable else {
            dropAssertion()
            state = .expanded
            activePlan = nil
            activeReveal = nil
            completion(.failed("the native menu-bar visibility API is not available on this macOS"))
            return
        }
        // During a partial reveal the apps shown right now are laid out: their positions can be re-read.
        let shownNow: Set<String>? = activeReveal != nil && assertion != nil ? heldAllowed.map(Set.init) : nil
        state = .activating
        let fail: @MainActor (String) -> Void = { [weak self] reason in
            guard let self, gen == self.generation else { return }
            // Fail open: never leave icons hidden after an error (bumps the generation, so a grant that
            // still arrives is invalidated at once).
            self.releaseAll()
            completion(.failed(reason))
        }
        withLayout(generation: gen, shownNow: shownNow, onTimeout: { fail("reading the menu-bar icon positions timed out") }) { [weak self] layout in
            guard let self, gen == self.generation else { return }
            let plan = NativeHidingPlan.make(layout: layout, rules: rules,
                                             runningBundleIDs: self.deps.runningBundleIDs(),
                                             ownBundleIDs: self.deps.ownBundleIDs, preAllowed: preAllowed())
            let timeout = self.deps.activationTimeout
            self.armTimeout(generation: gen, after: timeout) {
                fail("the menu bar did not answer the hiding request within \(Int(timeout)) s")
            }
            self.deps.visibility.activate(allowedSystemItems: NativeHidingPlan.systemItemsToKeep,
                                          allowedBundleIdentifiers: plan.allowed) { [weak self] result in
                guard let self, gen == self.generation else {
                    // Superseded (expanded, re-applied, timed out or stopped meanwhile): nobody wants it.
                    if case .success(let stale) = result { stale.invalidate() }
                    return
                }
                switch result {
                case .success(let fresh):
                    self.hold(fresh, allowed: plan.allowed) // replace, then drop
                    self.activePlan = plan
                    self.activeReveal = nil
                    self.revealContext = nil
                    self.state = .collapsed
                    completion(.collapsed(plan))
                    self.scheduleMeasurement(generation: gen, allowed: plan.allowed)
                case .failure(let error):
                    fail(error.localizedDescription)
                }
            }
        }
    }

    /// Shows everything again (drops the restriction and supersedes anything in flight).
    public func expand() {
        releaseAll()
    }

    /// Synchronously invalidates the restriction and cancels pending work (stop / disable / errors).
    public func releaseAll() {
        dropAssertion()
        state = .expanded
        activePlan = nil
        activeReveal = nil
        revealContext = nil
    }

    private func dropAssertion() {
        generation += 1
        let old = assertion
        assertion = nil
        heldAllowed = nil
        old?.invalidate()
    }

    /// Makes `fresh` the held restriction and only then drops the previous one.
    private func hold(_ fresh: NativeVisibilityAssertion, allowed: [String]) {
        let old = assertion
        assertion = fresh
        heldAllowed = allowed
        old?.invalidate()
    }

    // MARK: Reveal (expand, showing what fits)

    /// Shows the hidden icons that fit on「<」's side of the bar (see NativeReveal.swift). Releases the
    /// restriction — exactly what `expand()` does — when nothing is hidden, when every hidden app fits, or
    /// when the room cannot be told. `completion` is not called when superseded.
    public func reveal(completion: @escaping @MainActor (RevealOutcome) -> Void) {
        // Asked again while icons are revealed: the collapsed bar it was planned from still applies (our
        // items' frames now include the revealed icons' room).
        let previousContext = activeReveal != nil ? revealContext : nil
        generation += 1
        let gen = generation
        guard let base = activePlan, assertion != nil, let probe = deps.revealProbe, deps.visibility.isAvailable,
              let toggle = toggleFrame(), toggle.width > 0, toggle.height > 0 else {
            releaseAll()
            completion(.all(nil))
            return
        }
        let running = Set(deps.runningBundleIDs())
        let newApps = appsStarted(since: base, running: running)
        guard base.hidden.contains(where: running.contains) || !newApps.isEmpty else {
            releaseAll()
            completion(.all(nil))
            return
        }
        let rtl = previousContext?.rightToLeft ?? rightToLeft
        state = .activating
        armTimeout(generation: gen, after: deps.revealProbeTimeout) { [weak self] in
            self?.failOpen(generation: gen, reason: "reading the room in the menu bar timed out", completion)
        }
        probe(NativeRevealProbeRequest(toggle: toggle, bundleIDs: newApps, rightToLeft: rtl)) { [weak self] result in
            guard let self, gen == self.generation else { return }
            guard let result, let strip = result.strip else {
                // The room cannot be told: show everything (what expanding always did).
                self.releaseAll()
                completion(.all(nil))
                return
            }
            let context = previousContext ?? self.collapsedContext(base: base, toggle: self.toggleFrame() ?? toggle,
                                                                  band: strip.band, rightToLeft: rtl)
            guard let plan = self.revealPlan(base: base, context: context, strip: strip, items: result.items,
                                             newApps: newApps, revealable: nil) else {
                self.releaseAll()
                completion(.all(nil))
                return
            }
            guard !plan.allFit else {
                self.releaseAll()
                completion(.all(plan))
                return
            }
            self.revealContext = context
            self.activateReveal(base: base, plan: plan, generation: gen, completion: completion)
        }
    }

    /// While a partial reveal is shown the room can shrink: an app with longer menus came to the front (on a
    /// notched MacBook Pro they continue right of the camera housing), or an allowed app started and added
    /// icons. Re-reads the room against the collapsed bar the reveal was planned from and hides again the
    /// revealed apps that no longer fit — it never reveals more (icons do not come and go while the user
    /// switches apps) — then checks the bar like after a reveal (while macOS shows its « or has dropped one
    /// of our items, the farthest revealed app is hidden again). No-op unless a partial reveal is held.
    public func recheckReveal() {
        guard state == .revealed, let base = activePlan, let shown = activeReveal, assertion != nil,
              let context = revealContext else { return }
        let gen = generation
        guard let probe = deps.revealProbe, let toggle = toggleFrame(), toggle.width > 0, toggle.height > 0 else {
            scheduleRevealCheck(generation: gen, base: base, plan: shown)
            return
        }
        let newApps = appsStarted(since: base, running: Set(deps.runningBundleIDs()))
        probe(NativeRevealProbeRequest(toggle: toggle, bundleIDs: newApps, rightToLeft: context.rightToLeft)) { [weak self] result in
            // Read-only until here: anything that happened meanwhile (collapse, a drop) takes precedence.
            guard let self, gen == self.generation, self.state == .revealed, let current = self.activeReveal else { return }
            if let strip = result?.strip,
               let fresh = self.revealPlan(base: base, context: context, strip: strip, items: result?.items,
                                           newApps: newApps, revealable: Set(current.revealed)) {
                // Only a smaller room hides icons here; widths learned since the reveal alone do not (the
                // settle checks found the bar fine) — the overflow check below still catches a real overflow.
                let shown = Set(current.revealed)
                if Set(fresh.revealed) != shown, fresh.available < current.available - 0.5 {
                    AppLog.info("menubar", "native: less room while icons are shown (\(Int(fresh.available)) pt); "
                                + "hiding [\(Set(current.revealed).subtracting(fresh.revealed).sorted().joined(separator: ", "))] again")
                    self.generation += 1
                    let next = self.generation
                    self.activateReveal(base: base, plan: fresh, generation: next) { [weak self] outcome in
                        self?.onRevealUpdate?(outcome)
                    }
                    return
                }
                // The same icons stay shown: only what the menu reports may change (e.g. an app that did not
                // fit has quit).
                var kept = current
                kept.unfit = fresh.unfit.filter { !shown.contains($0) }
                kept.withheld = fresh.withheld.filter { !shown.contains($0) }
                if Set(kept.unfit) != Set(current.unfit) || Set(kept.withheld) != Set(current.withheld) {
                    self.activeReveal = kept
                    self.onRevealUpdate?(.partial(kept))
                }
            }
            self.scheduleRevealCheck(generation: gen, base: base, plan: self.activeReveal ?? current)
        }
    }

    /// Running apps that are neither allowed nor hidden by `base` (started since the collapse): hidden by
    /// the restriction, candidates for revealing.
    private func appsStarted(since base: NativeHidingPlan, running: Set<String>) -> [String] {
        let listed = Set(base.allowed).union(base.hidden)
        let own = ownBundleSet
        return running.filter {
            !$0.isEmpty && !listed.contains($0) && !own.contains($0) && !NativeLayoutResolver.systemItemOwners.contains($0)
        }.sorted()
    }

    /// The collapsed bar on「<」's display: the inner edge of what it shows — our own items and the other
    /// apps' icons (measured after the collapse, or estimated) — and our items' state for the checks.
    private func collapsedContext(base: NativeHidingPlan, toggle: CGRect, band: CGRect, rightToLeft rtl: Bool) -> RevealContext {
        let own = deps.ownItemFrames?()
        let measured = measurement.flatMap { $0.allowed == base.allowed ? $0 : nil }
        let othersEdge: CGFloat?
        if let measured {
            othersEdge = measured.othersUsed.map { rtl ? band.minX + $0 : band.maxX - $0 }
        } else {
            othersEdge = NativeRevealPlanner.estimatedOthersEdge(
                from: NativeRevealPlanner.visibleInnerEdge(toggle: toggle, ownItems: own ?? [], othersEdge: nil, band: band, rightToLeft: rtl),
                layout: layout, allowed: Set(base.allowed), metrics: metrics, rightToLeft: rtl)
        }
        let edge = NativeRevealPlanner.visibleInnerEdge(toggle: toggle, ownItems: own ?? [], othersEdge: othersEdge,
                                                        band: band, rightToLeft: rtl)
        return RevealContext(usedWidth: rtl ? edge - band.minX : band.maxX - edge,
                             collapsedOverflowed: measured?.overflowed == true,
                             ownBefore: own.map { NativeOwnItems(frames: $0, band: band) }, rightToLeft: rtl)
    }

    /// Which hidden apps fit, from the room on `strip` beyond the collapsed bar of `context`. nil when the
    /// room cannot be told. Apps that quit since the collapse are no candidates.
    private func revealPlan(base: NativeHidingPlan, context: RevealContext, strip: NativeStatusStrip,
                            items: [MenuBarItemInfo]?, newApps: [String], revealable: Set<String>?) -> NativeRevealPlan? {
        var names: [String: String] = [:]
        if let items {
            NativeMetricsRecorder.record(MenuBarInventory(items: items, bands: [strip.band]), into: &metrics,
                                         trusted: [], ownBundleIDs: ownBundleSet, rightToLeft: context.rightToLeft)
            for item in items { if let bundle = item.bundleID { names[bundle] = item.name } }
        }
        guard let room = NativeRevealPlanner.availableRoom(strip: strip, innerEdge: context.innerEdge(on: strip.band),
                                                           rightToLeft: context.rightToLeft) else { return nil }
        let running = Set(deps.runningBundleIDs())
        let live = NativeHidingPlan(allowed: base.allowed, hidden: base.hidden.filter(running.contains))
        let candidates = NativeRevealPlanner.candidates(base: live, layout: layout, metrics: metrics, newApps: newApps,
                                                        newAppsWithIcons: items.map { Set($0.compactMap(\.bundleID)) },
                                                        names: names)
        // macOS already showed its « while collapsed: there is no room at all.
        let available = context.collapsedOverflowed ? min(room, 0) : room
        return NativeRevealPlanner.plan(candidates: candidates, available: available, notched: strip.limitedByNotch,
                                        revealable: revealable)
    }

    /// Requests the collapsed allow-list plus `plan.revealed` (replace, then drop).
    private func activateReveal(base: NativeHidingPlan, plan: NativeRevealPlan, generation gen: Int,
                                completion: @escaping @MainActor (RevealOutcome) -> Void) {
        let allowed = Array(Set(base.allowed).union(plan.revealed)).sorted()
        if assertion != nil, let held = heldAllowed, Set(held) == Set(allowed) {
            // The held restriction already shows exactly this (nothing fits): no request — one that failed
            // would fail open into the very overflow the reveal avoids.
            activeReveal = plan
            state = .revealed
            completion(.partial(plan))
            scheduleRevealCheck(generation: gen, base: base, plan: plan)
            return
        }
        state = .activating
        let timeout = deps.activationTimeout
        armTimeout(generation: gen, after: timeout) { [weak self] in
            self?.failOpen(generation: gen, reason: "the menu bar did not answer the reveal request within \(Int(timeout)) s", completion)
        }
        deps.visibility.activate(allowedSystemItems: NativeHidingPlan.systemItemsToKeep,
                                 allowedBundleIdentifiers: allowed) { [weak self] result in
            guard let self, gen == self.generation else {
                if case .success(let stale) = result { stale.invalidate() }
                return
            }
            switch result {
            case .success(let fresh):
                self.hold(fresh, allowed: allowed)
                self.activeReveal = plan
                self.state = .revealed
                completion(.partial(plan))
                self.scheduleRevealCheck(generation: gen, base: base, plan: plan)
            case .failure(let error):
                self.failOpen(generation: gen, reason: error.localizedDescription, completion)
            }
        }
    }

    /// Fail open: everything shown, reported (unless superseded).
    private func failOpen(generation gen: Int, reason: String, _ completion: @MainActor (RevealOutcome) -> Void) {
        guard gen == generation else { return }
        releaseAll()
        completion(.failed(reason))
    }

    /// Once a partial reveal settled (checked twice: macOS may reflow late): if macOS shows its « anyway
    /// (widths were off) or dropped one of our own items, hide the farthest revealed app again — one at a
    /// time, each checked the same way, never more than were revealed.
    private func scheduleRevealCheck(generation gen: Int, base: NativeHidingPlan, plan: NativeRevealPlan, pass: Int = 0) {
        guard !plan.revealed.isEmpty, deps.inventory.isAuthorized else { return }
        deps.schedule(deps.settleDelay * (pass == 0 ? 1 : 3)) { [weak self] in
            guard let self, gen == self.generation, self.state == .revealed else { return }
            self.deps.inventory.snapshot { [weak self] inventory in
                guard let self, gen == self.generation, self.state == .revealed, let shown = self.heldAllowed else { return }
                let current = self.activeReveal ?? plan
                let rtl = NativeLayoutResolver.inferredRightToLeft(inventory) ?? self.rightToLeft
                NativeMetricsRecorder.record(inventory, into: &self.metrics, trusted: Set(shown),
                                             ownBundleIDs: self.ownBundleSet, rightToLeft: rtl)
                guard !current.revealed.isEmpty, self.revealDisplaced(inventory) else {
                    if pass == 0 { self.scheduleRevealCheck(generation: gen, base: base, plan: current, pass: 1) }
                    return
                }
                let smaller = current.droppingLast()
                AppLog.warning("menubar", "native: the bar overflowed after revealing \(current.revealed.count) app(s); hiding \(current.revealed.last ?? "?") again")
                self.generation += 1
                let next = self.generation
                self.activateReveal(base: base, plan: smaller, generation: next) { [weak self] outcome in
                    self?.onRevealUpdate?(outcome)
                }
            }
        }
    }

    /// The revealed bar overflowed: macOS shows its « on「<」's display, pushed「<」out, or dropped / parked
    /// one of our other items (系统监控, main icon). Our items are counted on「<」's display now — they all
    /// follow the active menu bar to another display together.
    private func revealDisplaced(_ inventory: MenuBarInventory) -> Bool {
        let toggle = toggleFrame()
        if NativeRevealPlanner.revealOverflowed(inventory: inventory, toggle: toggle) { return true }
        guard let before = revealContext?.ownBefore, let frames = deps.ownItemFrames?(), let toggle,
              let band = NativeLayoutResolver.strip(of: toggle, bands: inventory.bands) else { return false }
        return NativeRevealPlanner.ownItemsDisplaced(before: before, after: NativeOwnItems(frames: frames, band: band))
    }

    // MARK: Layout

    /// Fresh positions from an unrestricted bar; during a partial reveal the positions of the apps shown
    /// right now (`shownNow`); the cached ones otherwise (collapsed, or without 辅助功能).
    private func withLayout(generation gen: Int, shownNow: Set<String>?, onTimeout: @escaping @MainActor () -> Void,
                            _ body: @escaping @MainActor (NativeLayout?) -> Void) {
        guard deps.inventory.isAuthorized, assertion == nil || shownNow != nil else {
            body(layout)
            return
        }
        armTimeout(generation: gen, after: deps.snapshotTimeout, onTimeout)
        deps.inventory.snapshot { [weak self] inventory in
            guard let self, gen == self.generation else { return }
            if let shownNow {
                body(self.storeRestricted(inventory, shown: shownNow))
            } else {
                body(self.store(inventory))
            }
        }
    }

    /// Runs `action` after `seconds` unless the request (generation) moved on, or the phase it guards
    /// (position read → activation) is over.
    private func armTimeout(generation gen: Int, after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        phase += 1
        let armed = phase
        deps.schedule(seconds) { [weak self] in
            guard let self, gen == self.generation, armed == self.phase, self.state == .activating else { return }
            AppLog.warning("menubar", "native: request timed out after \(Int(seconds)) s")
            action()
        }
    }

    /// Re-reads the positions for the settings list. Only while expanded and unrestricted (otherwise the
    /// completion gets the cached layout). Never supersedes a collapse.
    public func refreshLayout(completion: @escaping @MainActor (NativeLayout?) -> Void) {
        guard assertion == nil, state == .expanded, deps.inventory.isAuthorized else {
            completion(layout)
            return
        }
        let gen = generation
        deps.inventory.snapshot { [weak self] inventory in
            guard let self else { return }
            guard gen == self.generation, self.assertion == nil else {
                completion(self.layout)
                return
            }
            completion(self.store(inventory))
        }
    }

    private func store(_ inventory: MenuBarInventory) -> NativeLayout {
        let rtl = NativeLayoutResolver.inferredRightToLeft(inventory) ?? deps.rightToLeft()
        lastRightToLeft = rtl
        NativeMetricsRecorder.record(inventory, into: &metrics, trusted: nil, ownBundleIDs: ownBundleSet, rightToLeft: rtl)
        let fresh = NativeLayoutResolver.resolve(inventory: inventory, toggle: toggleFrame(),
                                                 ownBundleIDs: ownBundleSet, rightToLeft: deps.rightToLeft())
            .filledIn(from: layout)
        layout = fresh
        onLayout?(fresh)
        return fresh
    }

    /// A read taken during a partial reveal: only the shown apps' frames are live.
    private func storeRestricted(_ inventory: MenuBarInventory, shown: Set<String>) -> NativeLayout? {
        let rtl = NativeLayoutResolver.inferredRightToLeft(inventory) ?? deps.rightToLeft()
        lastRightToLeft = rtl
        NativeMetricsRecorder.record(inventory, into: &metrics, trusted: shown, ownBundleIDs: ownBundleSet, rightToLeft: rtl)
        guard let merged = NativeLayoutResolver.resolveRestricted(inventory: inventory, toggle: toggleFrame(),
                                                                  ownBundleIDs: ownBundleSet, visible: shown,
                                                                  previous: layout, rightToLeft: deps.rightToLeft()) else {
            return layout
        }
        layout = merged
        onLayout?(merged)
        return merged
    }

    // MARK: Measuring the collapsed bar

    /// Once the collapse took effect: where its icons end on「<」's display (the room left for a reveal),
    /// and what every app's icons measure (only the allowed apps' frames are live).
    private func scheduleMeasurement(generation gen: Int, allowed: [String]) {
        guard deps.inventory.isAuthorized else { return }
        deps.schedule(deps.settleDelay) { [weak self] in
            guard let self, gen == self.generation, self.state == .collapsed else { return }
            self.deps.inventory.snapshot { [weak self] inventory in
                guard let self, gen == self.generation, self.state == .collapsed else { return }
                let rtl = NativeLayoutResolver.inferredRightToLeft(inventory) ?? self.rightToLeft
                let shown = Set(allowed)
                NativeMetricsRecorder.record(inventory, into: &self.metrics, trusted: shown,
                                             ownBundleIDs: self.ownBundleSet, rightToLeft: rtl)
                let toggle = self.toggleFrame()
                guard let strip = toggle.flatMap({ NativeLayoutResolver.strip(of: $0, bands: inventory.bands) }) else {
                    self.measurement = nil // 「<」's display unknown: the next reveal estimates
                    return
                }
                let measured = NativeRevealPlanner.measureVisible(inventory: inventory, visible: shown, toggle: toggle, rightToLeft: rtl)
                let used = measured.edge.map { rtl ? $0 - strip.minX : strip.maxX - $0 }
                self.measurement = (allowed, used, measured.overflowed)
            }
        }
    }
}
