import AppKit
import Combine
import OneSwitchCore

/// How collapsing hides icons.
public enum HidingEngineKind: String, Equatable, Sendable {
    /// macOS 27+: the system's menu-bar visibility restriction (only the「<」toggle in the bar).
    case native
    /// Separator length (macOS 14–26; on macOS 27 the fallback that uses the system "«" overflow).
    case legacy
}

/// Main-actor brain of the 菜单栏图标 module: owns the status items, the auto-collapse driver, the
/// hotkey, the interaction probe and the (experimental) item list. Observed by the settings view.
@MainActor
public final class MenuBarHiderController: ObservableObject {
    public static let hotKeyID = "menubar.toggle"

    public let store: SettingsStore<MenuBarHiderSettings>
    public let strategy: CollapseStrategy
    /// Where settings (and the remembered visible apps) live.
    private let defaults: UserDefaults
    /// Apps last seen right of the「<」toggle (bundle ids), remembered across launches so an app that
    /// starts after the first collapse at login is not hidden by mistake.
    static let rememberedVisibleKey = "menubar.nativeVisibleApps"
    /// The macOS 27 process that lays out the menu bar and applies visibility restrictions.
    static let menuBarAgentBundleID = "com.apple.MenuBarAgent"

    /// Engine in use. 系统原生隐藏 on macOS 27+ when available; the separator engine otherwise and as
    /// automatic fallback when native requests keep failing (fail open, see `nativeHidingFailed`).
    @Published public private(set) var engineKind: HidingEngineKind = .legacy
    /// Why 系统原生隐藏 is not used on this macOS 27+ Mac (nil when it is, or on older macOS).
    @Published public private(set) var nativeFallbackReason: String?
    /// Native engine progress (.activating while positions are read / the restriction is requested).
    @Published public private(set) var nativeState: NativeVisibilityEngine.State = .expanded
    /// Apps hidden by the active restriction (nil while expanded).
    @Published public private(set) var nativeHiddenBundles: [String]?
    /// Expanded, but only the hidden apps that fit are shown (nil otherwise): which stay hidden.
    @Published public private(set) var nativeRevealPlan: NativeRevealPlan?
    /// The last reveal could not show every hidden app (offers "显示全部图标" while collapsed too).
    @Published public private(set) var nativeLastRevealPartial = false
    /// Last placement of the apps with menu-bar icons (native mode; settings list).
    @Published public private(set) var nativeLayout: NativeLayout?
    @Published public internal(set) var nativeListBusy = false
    @Published public internal(set) var nativeLastScan: Date?
    /// Every icon is shown for Notification Center right now (点击时钟打开通知中心, see NotificationCenterAssist.swift).
    @Published public internal(set) var notificationCenterAssistActive = false

    @Published public private(set) var visibility: RevealStateMachine.Visibility = .expanded
    /// Last known order of our items (valid while expanded).
    @Published public private(set) var orderStatus: SeparatorOrder = .unknown
    /// True after a collapse was refused because of the separator order.
    @Published public private(set) var collapseBlocked = false
    /// Status items are in the menu bar.
    @Published public private(set) var isActive = false
    @Published public private(set) var hotKeyError: String?
    @Published public private(set) var hasNotch = false

    // Experimental item list.
    @Published public internal(set) var items: [MenuBarItemRow] = []
    @Published public internal(set) var isBusy = false
    @Published public internal(set) var listNote: String?
    @Published public internal(set) var lastScan: Date?
    @Published public internal(set) var movingItemID: String?
    @Published public internal(set) var moveResult: MoveResult?

    /// Settings currently applied (kept in sync with `store` — `store.$value` fires before the store updates).
    private(set) var current: MenuBarHiderSettings

    let statusItems: HiderStatusItems
    private(set) var driver: AutoCollapseDriver!
    /// nil when native hiding is not wired in (macOS < 27, or checks exercising the separator engine).
    private(set) var nativeEngine: NativeVisibilityEngine?
    /// Test hook from `NativeHidingDependencies.toggleFrame`.
    private var toggleFrameOverride: (() -> CGRect?)?
    var iconCache: [String: NSImage] = [:]
    let poster = SyntheticDragPoster()
    let scanQueue = DispatchQueue(label: "oneswitch.menubar.scan", qos: .userInitiated)
    private let probeQueue = DispatchQueue(label: "oneswitch.menubar.probe", qos: .utility)

    private(set) var started = false
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// One of our menus is tracking. A flag rather than a counter so an unbalanced begin/end can never
    /// block the auto-hide forever (other apps' menus, and nested ones, are caught by the window scan).
    private var menuTracking = false
    /// > 0 while listing / moving items (auto-collapse is postponed).
    var arrangeHolds = 0
    private var initialCollapseWork: DispatchWorkItem?
    var currentTask: Task<Void, Never>?
    /// macOS 27: extra width of the collapsed toggle (see `OverflowPlanner`); 0 while expanded.
    private var toggleExtra: CGFloat = 0
    private var overflowTimer: Timer?
    private var overflowWork: DispatchWorkItem?
    private var overflowGeneration = 0
    /// Width of the icons between separator and toggle (measured while expanded).
    private var itemsBetweenWidth: CGFloat = 0
    private var layoutWork: DispatchWorkItem?
    /// Native requests that failed in a row (a success resets it); see `nativeHidingFailed`.
    private(set) var nativeFailures = 0
    /// Failures in a row before switching to the separator engine (兼容模式) for the session. One transient
    /// error (e.g. MenuBarAgent busy after wake) must not bring back the "«" and the gap for good.
    public static let nativeFailuresBeforeFallback = 2
    private var reassertWork: DispatchWorkItem?
    private var revealRecheckWork: DispatchWorkItem?
    /// 点击时钟打开通知中心 (系统原生隐藏): nil when not wired in (see MenuBarHiderController+ClockAssist.swift).
    var clockAssist: NotificationCenterClockAssist?
    var clockAssistDeps: NotificationCenterAssistDependencies?
    var clockMonitorRemover: (@MainActor () -> Void)?
    /// The visibility is being changed by the clock assist itself (not a user action).
    var clockAssistDriving = false
    /// Restoring a partial reveal after Notification Center closed: reveal again once the collapse is granted.
    var clockRestoreReveal = false

    public convenience init() {
        let strategy = CollapseStrategy.current
        self.init(defaults: AppEnvironment.defaults, autosaveSuffix: AppEnvironment.profileSuffix, strategy: strategy,
                  native: strategy == .systemOverflow ? .system() : nil, seedPositions: true)
    }

    /// - Parameters:
    ///   - defaults: where settings are stored (checks pass a throw-away suite).
    ///   - autosaveSuffix: appended to the status items' autosave names.
    ///   - strategy: how the separator engine hides items (defaults to the one for the running macOS).
    ///   - native: 系统原生隐藏 dependencies (used on macOS 27+ when available); nil = separator engine only.
    ///   - seedPositions: seed the items' initial positions next to the system items (the app does;
    ///     self-checks keep their throw-away items left-most).
    public init(defaults: UserDefaults, autosaveSuffix: String, strategy: CollapseStrategy,
                native: NativeHidingDependencies? = nil, seedPositions: Bool = false) {
        let store = SettingsStore(key: MenuBarHiderSettings.storeKey, defaultValue: MenuBarHiderSettings(), defaults: defaults)
        self.store = store
        self.strategy = strategy
        self.defaults = defaults
        self.current = store.value
        self.statusItems = HiderStatusItems(autosaveSuffix: autosaveSuffix, seedPositions: seedPositions)
        let machine = RevealStateMachine(visibility: .expanded, autoCollapse: store.value.autoCollapse,
                                         delay: TimeInterval(store.value.effectiveDelay))
        self.driver = AutoCollapseDriver(
            machine: machine,
            now: { Date() },
            schedule: AutoCollapseDriver.runLoopScheduler,
            probe: { [weak self] completion in
                guard let self else { completion(false); return }
                self.probeInteraction(completion)
            })
        driver.canCollapse = { [weak self] in self?.collapseAllowed() ?? true }
        driver.onVisibilityChange = { [weak self] visibility in self?.visibilityChanged(visibility) }
        statusItems.onClick = { [weak self] click in self?.handleToggleClick(click) }
        statusItems.onLayoutChange = { [weak self] in self?.layoutChanged() }
        hasNotch = Self.detectNotch()
        if let native {
            toggleFrameOverride = native.toggleFrame
            let engine = NativeVisibilityEngine(dependencies: native) { [weak self] in self?.toggleFrameCG() }
            engine.onLayout = { [weak self] layout in
                guard let self else { return }
                self.nativeLayout = layout
                self.nativeLastScan = Date()
                let merged = layout.mergedVisible(into: self.rememberedVisibleApps)
                if merged != self.rememberedVisibleApps { self.defaults.set(merged, forKey: Self.rememberedVisibleKey) }
            }
            engine.onRevealUpdate = { [weak self] outcome in self?.nativeRevealFinished(outcome) }
            nativeEngine = engine
            if let assist = native.clockAssist { setUpClockAssist(assist) }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        current = store.value
        store.$value
            .dropFirst()
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.apply(settings: value) }
            }
            .store(in: &cancellables)
        observeSystem()
        hasNotch = Self.detectNotch()
        nativeFailures = 0
        engineKind = chooseEngine()
        if current.enabled {
            activate()
        }
        registerHotKey()
        syncClockAssist()
        AppLog.info("menubar", "started (engine: \(engineKind.rawValue), strategy: \(strategy.rawValue), enabled: \(current.enabled))")
    }

    /// 系统原生隐藏 when wired in and available; otherwise the separator engine.
    private func chooseEngine() -> HidingEngineKind {
        guard let engine = nativeEngine, strategy == .systemOverflow else { return .legacy }
        guard engine.isAvailable else {
            nativeFallbackReason = "这台 Mac 的 macOS 不提供系统原生隐藏接口"
            AppLog.warning("menubar", "native menu-bar visibility API unavailable; using the separator engine")
            return .legacy
        }
        nativeFallbackReason = nil
        return .native
    }

    func stop() {
        guard started else { return }
        started = false
        stopClockAssist()                 // monitor removed, a click being posted completed
        currentTask?.cancel()
        currentTask = nil
        poster.cancelAndWait()            // never leave a synthetic ⌘ / mouse button pressed
        initialCollapseWork?.cancel()
        initialCollapseWork = nil
        stopOverflowTracking()
        layoutWork?.cancel()
        layoutWork = nil
        reassertWork?.cancel()
        reassertWork = nil
        revealRecheckWork?.cancel()
        revealRecheckWork = nil
        GlobalHotKeyCenter.shared.unregister(id: Self.hotKeyID)
        cancellables.removeAll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        menuTracking = false
        arrangeHolds = 0
        deactivate()
        // Belt and braces: the restriction must never outlive the module (it also ends with the process).
        nativeEngine?.releaseAll()
        AppLog.info("menubar", "stopped")
    }

    /// Installs the status items and (optionally) collapses once they are laid out.
    private func activate() {
        guard !isActive else { return }
        let separators = engineKind == .legacy
        statusItems.install(separators: separators, alwaysHiddenEnabled: separators && current.alwaysHiddenEnabled)
        isActive = true
        orderStatus = .unknown
        collapseBlocked = false
        driver.updateSettings(autoCollapse: current.autoCollapse, delay: TimeInterval(current.effectiveDelay))
        // Start expanded without a deadline; the initial collapse happens after layout.
        driver.reset(to: .expanded)
        if current.collapseAtLaunch {
            scheduleInitialCollapse(attempt: 0)
        }
    }

    /// Removes the status items (everything becomes visible).
    private func deactivate() {
        currentTask?.cancel()
        initialCollapseWork?.cancel()
        initialCollapseWork = nil
        revealRecheckWork?.cancel()
        revealRecheckWork = nil
        stopOverflowTracking()
        releaseNativeRestriction()
        // Restore normal lengths first, then remove the items.
        driver.reset(to: .expanded)
        driver.invalidate()
        if statusItems.isInstalled { statusItems.uninstall() }
        isActive = false
        visibility = .expanded
        orderStatus = .unknown
        collapseBlocked = false
    }

    /// The items need a moment to be laid out before their frames can be compared.
    private func scheduleInitialCollapse(attempt: Int, previous: SeparatorOrder? = nil) {
        initialCollapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.started, self.isActive else { return }
                self.initialCollapseWork = nil
                // Wait (≈ 5 s at most) until the order is safe and stable: frames are unknown or
                // transient while the items are placed (the MBP briefly reports the separator at x 0),
                // and on a crowded bar macOS 27 parks new items in the "«" overflow. Only a persistent
                // problem is reported (collapse() below refuses with a warning).
                // 系统原生隐藏 only needs the toggle to be laid out (its position is the boundary).
                let order: SeparatorOrder = self.engineKind == .native
                    ? ((self.toggleFrameOverride?() ?? self.toggleFrameCG()) != nil ? .ok : .unknown)
                    : self.statusItems.order
                if Self.initialCollapseStep(order: order, previous: previous, attempt: attempt) == .retry {
                    self.scheduleInitialCollapse(attempt: attempt + 1, previous: order)
                    return
                }
                if self.driver.visibility != .collapsed {
                    self.driver.collapse()
                }
            }
        }
        initialCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.6 : 0.5), execute: work)
    }

    public enum InitialCollapseStep: Equatable, Sendable {
        case retry
        case collapse
    }

    /// "启动时自动隐藏": collapse once two consecutive readings (0.5 s apart) agree on a safe order; keep
    /// waiting while the order is unsafe / unstable, then try once — `collapse()` re-checks, refuses and
    /// warns when a problem persists. A single (possibly transient) reading never decides.
    public static func initialCollapseStep(order: SeparatorOrder, previous: SeparatorOrder?, attempt: Int,
                                           maxAttempts: Int = 10) -> InitialCollapseStep {
        guard attempt < maxAttempts else { return .collapse }
        guard order.allowsCollapse else { return .retry }
        return order == previous ? .collapse : .retry
    }

    // MARK: - Settings

    private func apply(settings new: MenuBarHiderSettings) {
        let old = current
        current = new
        // The click monitor follows the feature, the engine and 启用 (also on the early returns below).
        defer { syncClockAssist() }
        guard started else { return }
        if old.enabled != new.enabled {
            if new.enabled { activate() } else { deactivate() }
            registerHotKey()
            AppLog.info("menubar", new.enabled ? "enabled" : "disabled")
            return
        }
        guard new.enabled else { return }
        if old.appRules != new.appRules, engineKind == .native, driver.visibility == .collapsed {
            // Re-apply with the new rules (the old restriction stays until the new one is active).
            applyNativeRestriction()
        }
        if old.alwaysHiddenEnabled != new.alwaysHiddenEnabled, engineKind == .legacy {
            statusItems.setAlwaysHiddenEnabled(new.alwaysHiddenEnabled)
            // Never widen the new separator before its position was verified: frames are meaningless
            // while collapsed (and may be unreadable while expanded). refreshOrder() replaces this
            // assumption as soon as real frames are available (now, or once the items move).
            orderStatus = orderStatus.afterAlwaysHiddenChange(enabled: new.alwaysHiddenEnabled)
            if driver.visibility.isExpanded { refreshOrder() }
        }
        if old.autoCollapse != new.autoCollapse || old.effectiveDelay != new.effectiveDelay {
            driver.updateSettings(autoCollapse: new.autoCollapse, delay: TimeInterval(new.effectiveDelay))
            clockAssistKeepDeadlineOff()
        }
        if old.hotKey != new.hotKey { registerHotKey() }
        render()
    }

    private func registerHotKey() {
        guard started, current.enabled, let hotKey = current.hotKey else {
            GlobalHotKeyCenter.shared.unregister(id: Self.hotKeyID)
            hotKeyError = nil
            return
        }
        let ok = GlobalHotKeyCenter.shared.register(id: Self.hotKeyID, hotKey: hotKey) { [weak self] in
            self?.userToggle(revealAlwaysHidden: false)
        }
        hotKeyError = ok ? nil : "快捷键 \(hotKey.displayString) 已被其他应用占用，请换一个组合"
    }

    // MARK: - Public actions (menu, settings, hotkey)

    /// Shows the hidden icons (auto-hides again after the configured delay).
    public func expand(revealAlwaysHidden: Bool = false) {
        guard isActive else { return }
        cancelInitialCollapse()
        driver.expand(revealAlwaysHidden: revealAlwaysHidden)
    }

    /// Hides the icons now (refused when the separator is right of the toggle).
    public func collapse() {
        guard isActive else { return }
        cancelInitialCollapse()
        driver.collapse()
    }

    public func userToggle(revealAlwaysHidden: Bool) {
        guard isActive else { return }
        cancelInitialCollapse()
        driver.toggle(revealAlwaysHidden: revealAlwaysHidden)
    }

    /// 系统原生隐藏: shows every icon — also the ones that do not fit, which macOS then puts in its «
    /// (the restriction is released) — and auto-hides after the usual delay.
    public func revealAllIcons() {
        expand(revealAlwaysHidden: true)
    }

    /// Any user action overrides the pending "hide at launch".
    func cancelInitialCollapse() {
        initialCollapseWork?.cancel()
        initialCollapseWork = nil
    }

    public func setEnabled(_ enabled: Bool) {
        store.update { $0.enabled = enabled }
    }

    /// Seconds until the icons auto-hide (nil when no collapse is pending).
    public var secondsUntilCollapse: Int? {
        guard let deadline = driver.deadline else { return nil }
        return max(0, Int(deadline.timeIntervalSinceNow.rounded(.up)))
    }

    /// The warning to show in the menu / settings, if any.
    public var warningText: String? {
        guard isActive, engineKind == .legacy else { return nil }
        return orderStatus.warning
    }

    // MARK: - Visibility / rendering

    private func visibilityChanged(_ newValue: RevealStateMachine.Visibility) {
        visibility = newValue
        // Anything but the clock assist changed the bar (toggle, hotkey, menu, settings, auto-hide, a
        // failure): the user's action wins over restoring what was there before Notification Center.
        if !clockAssistDriving { clockAssistNoteExternalChange() }
        if engineKind == .native {
            render()
            switch newValue {
            case .collapsed: applyNativeRestriction()
            case .expanded: revealNativeIcons()               // what fits in the bar
            case .expandedAll: releaseNativeRestriction()     // everything (the rest goes into the «)
            }
            AppLog.debug("menubar", "visibility -> \(newValue.rawValue) (native)")
            return
        }
        if newValue == .collapsed {
            render()
            startOverflowTracking()
        } else {
            stopOverflowTracking()
            render()
        }
        AppLog.debug("menubar", "visibility -> \(newValue.rawValue)")
    }

    func render() {
        guard isActive else { return }
        let collapsedLength = currentCollapsedLength()
        statusItems.render(.init(visibility: driver.visibility,
                                 order: orderStatus,
                                 warning: collapseBlocked,
                                 settings: current,
                                 collapsedLength: collapsedLength,
                                 toggleExtra: driver.visibility == .collapsed ? toggleExtra : 0))
    }

    // MARK: - macOS 27 overflow padding

    /// While collapsed on macOS 27, keep the toggle wide enough that the separator cannot fit
    /// (re-evaluated after layout, on app switches, screen changes and every few seconds).
    private func startOverflowTracking() {
        guard strategy == .systemOverflow, engineKind == .legacy, overflowTimer == nil else { return }
        scheduleOverflowUpdate(after: 0.35)
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateOverflowPadding() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        overflowTimer = timer
    }

    private func stopOverflowTracking() {
        overflowTimer?.invalidate()
        overflowTimer = nil
        overflowWork?.cancel()
        overflowWork = nil
        overflowGeneration += 1
        toggleExtra = 0
    }

    private func scheduleOverflowUpdate(after delay: TimeInterval) {
        guard strategy == .systemOverflow, engineKind == .legacy, isActive, driver.visibility == .collapsed else { return }
        overflowWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.updateOverflowPadding() }
        }
        overflowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateOverflowPadding() {
        overflowWork = nil
        guard strategy == .systemOverflow, engineKind == .legacy, isActive, driver.visibility == .collapsed else { return }
        guard Permissions.isGranted(.accessibility),
              let screen = statusItems.screen,
              let toggleFrame = statusItems.frames().toggle,
              let natural = statusItems.naturalToggleWindowWidth(),
              let owner = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier else {
            if toggleExtra != 0 {
                toggleExtra = 0
                render()
            }
            return
        }
        let separatorWindow = currentCollapsedLength() + statusItems.windowPadding()
        let between = itemsBetweenWidth
        let minX = screen.frame.minX, maxX = screen.frame.maxX, width = screen.frame.width
        let notchMaxX = MenuBarGeometry.notchMaxX(screenMaxX: maxX, auxiliaryTopRightWidth: screen.auxiliaryTopRightArea?.width)
        overflowGeneration += 1
        let generation = overflowGeneration
        probeQueue.async { [weak self] in
            let menusMaxX = MenuBarItemScanner.appMenusMaxX(pid: owner, screenMinX: minX, screenMaxX: maxX)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.overflowGeneration, self.isActive,
                          self.driver.visibility == .collapsed else { return }
                    let proposed = menusMaxX.map {
                        OverflowPlanner.toggleExtraWidth(toggleMaxX: toggleFrame.maxX, toggleWindowWidth: natural,
                                                         itemsBetween: between, separatorWindowWidth: separatorWindow,
                                                         menusMaxX: OverflowPlanner.statusAreaMinX(menusMaxX: $0, notchMaxX: notchMaxX),
                                                         screenWidth: width)
                    } ?? 0
                    let settled = OverflowPlanner.settle(current: self.toggleExtra, proposed: proposed)
                    guard settled != self.toggleExtra else { return }
                    AppLog.debug("menubar", "toggle padding \(Int(self.toggleExtra)) → \(Int(settled)) (menus end at \(Int(menusMaxX ?? -1)))")
                    self.toggleExtra = settled
                    self.render()
                }
            }
        }
    }

    /// Consulted before every collapse: never hide the toggle.
    private func collapseAllowed() -> Bool {
        guard isActive, driver.visibility.isExpanded else { return true }
        // 系统原生隐藏 has no separator that could hide the toggle: our own app is always allowed.
        guard engineKind == .legacy else {
            collapseBlocked = false
            return true
        }
        _ = statusItems.naturalToggleWindowWidth() // measure while at its natural length
        _ = statusItems.windowPadding()
        let frames = statusItems.frames()
        if let t = frames.toggle, let s = frames.separator, s.maxX <= t.minX {
            itemsBetweenWidth = t.minX - s.maxX
        }
        let order = statusItems.order
        if order != .unknown { orderStatus = order }
        let allowed = orderStatus.allowsCollapse
        if !allowed {
            if !collapseBlocked {
                AppLog.warning("menubar", "collapse refused: \(orderStatus)")
            }
            collapseBlocked = orderStatus != .unknown
        } else {
            collapseBlocked = false
        }
        return allowed
    }

    private func refreshOrder() {
        guard isActive, engineKind == .legacy, driver.visibility.isExpanded else { return }
        let order = statusItems.order
        guard order != .unknown else { return }
        if order != orderStatus {
            orderStatus = order
            if order.allowsCollapse && collapseBlocked {
                collapseBlocked = false
                AppLog.info("menubar", "separator order fixed")
                // Re-arm the auto-hide now that collapsing is safe again.
                if current.autoCollapse { driver.expand(revealAlwaysHidden: driver.visibility == .expandedAll) }
            }
            render()
        }
    }

    /// Our item windows moved (user ⌘-dragged them, screen change…). Frames are only meaningful while
    /// expanded — collapsed / overflowed items report clamped positions.
    /// Debounced: several windows move one after another (and slide in), so evaluate once they settle.
    private func layoutChanged() {
        layoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.layoutWork = nil
                self?.refreshOrder()
            }
        }
        layoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - 系统原生隐藏 (macOS 27+)

    /// Collapse (or re-apply the rules while collapsed) through the native restriction.
    func applyNativeRestriction() {
        guard engineKind == .native, isActive, let engine = nativeEngine else { return }
        nativeState = .activating
        nativeRevealPlan = nil
        engine.collapse(rules: current.appRules, preAllowed: { [weak self] in self?.rememberedVisibleApps ?? [] }) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .collapsed(let plan):
                self.nativeFailures = 0
                self.nativeState = engine.state
                self.nativeRevealPlan = nil
                self.nativeHiddenBundles = plan.hidden
                AppLog.info("menubar", "native: hiding \(plan.hidden.count) app(s) [\(plan.hidden.joined(separator: ", "))]; \(plan.allowed.count) bundle id(s) allowed")
                self.clockAssistCollapseGranted()
            case .failed(let reason):
                self.nativeState = engine.state
                self.nativeHiddenBundles = nil
                self.clockRestoreReveal = false
                // Out of the current call chain: the failure may be reported synchronously from inside
                // a visibility change of the driver.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.nativeHidingFailed(reason: reason) }
                }
            }
        }
    }

    /// Bundle ids remembered as right of the toggle (see `rememberedVisibleKey`).
    public var rememberedVisibleApps: [String] {
        defaults.stringArray(forKey: Self.rememberedVisibleKey) ?? []
    }

    /// Show everything: drop the restriction (放不下的图标由 macOS 收进「«」).
    func releaseNativeRestriction() {
        nativeEngine?.expand()
        nativeState = .expanded
        nativeHiddenBundles = nil
        nativeRevealPlan = nil
    }

    /// Expand: show the hidden icons that fit (see `NativeVisibilityEngine.reveal`). Falls back to showing
    /// everything when all fit, the room cannot be told, or anything fails (fail open). A failed reveal is
    /// not counted toward 兼容模式: the icons are shown, which is what the user asked for.
    func revealNativeIcons() {
        guard engineKind == .native, let engine = nativeEngine else { return }
        nativeHiddenBundles = nil
        nativeRevealPlan = nil
        nativeState = .activating
        engine.reveal { [weak self] outcome in self?.nativeRevealFinished(outcome) }
        if engine.state != .activating { nativeState = engine.state }
    }

    func nativeRevealFinished(_ outcome: NativeVisibilityEngine.RevealOutcome) {
        guard let engine = nativeEngine else { return }
        nativeState = engine.state
        switch outcome {
        case .all(let plan):
            // Every icon is shown (all fit, nothing hidden, or the room unknown): nothing was held back.
            nativeRevealPlan = nil
            nativeLastRevealPartial = false
            if let plan {
                AppLog.info("menubar", "native: all hidden apps fit (room \(Int(plan.available)) pt, need \(Int(plan.used)) pt); restriction released")
            }
        case .partial(let plan):
            nativeRevealPlan = plan
            nativeLastRevealPartial = true
            AppLog.info("menubar", "native: revealing \(plan.revealed.count) app(s) that fit [\(plan.revealed.joined(separator: ", "))] "
                        + "(room \(Int(plan.available)) pt, used \(Int(plan.used)) pt); kept hidden: [\((plan.unfit + plan.withheld).joined(separator: ", "))]")
        case .failed(let reason):
            nativeRevealPlan = nil
            AppLog.warning("menubar", "native: revealing failed (\(reason)); every icon is shown")
        }
    }

    /// While a partial reveal is shown: another app came to the front (its menus may leave less room) or an
    /// app started (an allowed one adds icons). Debounced — the bar needs a moment to show the new menus —
    /// then the engine hides again what no longer fits (see `NativeVisibilityEngine.recheckReveal`).
    func scheduleRevealRecheck(after delay: TimeInterval = 0.4) {
        // Also while the reveal is still being granted; the engine acts only once it is held.
        guard engineKind == .native, isActive, driver.visibility == .expanded, nativeEngine != nil else { return }
        revealRecheckWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.revealRecheckWork = nil
                guard self.started, self.isActive, self.engineKind == .native else { return }
                self.nativeEngine?.recheckReveal()
            }
        }
        revealRecheckWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A native request failed (error, no answer, API gone): nothing is hidden any more — the engine
    /// released everything. The first failure in a row only shows the icons (「>」) and lets the auto-hide
    /// try again after the delay; a repeated failure (or a missing API) switches to 兼容模式. Failures while
    /// the screen is locked are not counted (the auto-hide also runs behind the lock screen, where the
    /// menu bar may not take requests) — waking up to a locked screen must not end in 兼容模式.
    func nativeHidingFailed(reason: String) {
        guard started, engineKind == .native else { return }
        if !(nativeEngine?.isSessionLocked ?? false) { nativeFailures += 1 }
        let available = nativeEngine?.isAvailable ?? false
        guard available, nativeFailures < Self.nativeFailuresBeforeFallback else {
            fallBackToLegacy(reason: reason)
            return
        }
        AppLog.warning("menubar", "native hiding failed (\(reason)); icons shown, trying again on the next collapse")
        // Fail open visibly: the toggle shows「>」(icons are shown) and the auto-hide re-arms.
        if isActive, driver.visibility == .collapsed { driver.expand() }
    }

    /// Native hiding keeps failing: nothing is hidden any more (the engine released everything). Switch to
    /// the separator engine for this session and hide the icons that way once the separator is placed.
    func fallBackToLegacy(reason: String) {
        guard engineKind == .native else { return }
        defer { syncClockAssist() }
        AppLog.warning("menubar", "native hiding failed (\(reason)); falling back to the separator (compatibility) engine")
        nativeEngine?.releaseAll()
        nativeState = .expanded
        nativeHiddenBundles = nil
        nativeRevealPlan = nil
        nativeFallbackReason = "系统原生隐藏失败（\(reason)），已改用兼容模式"
        let wantedCollapsed = started && driver.visibility == .collapsed
        engineKind = .legacy
        initialCollapseWork?.cancel()
        initialCollapseWork = nil
        orderStatus = .unknown
        collapseBlocked = false
        driver.reset(to: .expanded)
        guard started, isActive else { return }
        statusItems.setSeparatorsInstalled(true, alwaysHiddenEnabled: current.alwaysHiddenEnabled)
        render()
        if wantedCollapsed { scheduleInitialCollapse(attempt: 0) }
    }

    /// Settings button after a fallback: try 系统原生隐藏 again (and collapse with it).
    public func retryNativeHiding() {
        guard engineKind == .legacy, strategy == .systemOverflow, let engine = nativeEngine else { return }
        guard engine.isAvailable else {
            nativeFallbackReason = "这台 Mac 的 macOS 不提供系统原生隐藏接口"
            return
        }
        AppLog.info("menubar", "retrying native hiding")
        defer { syncClockAssist() }
        nativeFailures = 0
        initialCollapseWork?.cancel()
        initialCollapseWork = nil
        driver.reset(to: .expanded)           // separator engine: restore the separator first
        stopOverflowTracking()
        nativeFallbackReason = nil
        engineKind = .native
        orderStatus = .unknown
        collapseBlocked = false
        guard started, isActive else { return }
        statusItems.setSeparatorsInstalled(false, alwaysHiddenEnabled: false)
        render()
        driver.collapse()
    }

    /// Re-requests the active restriction (same rules, cached positions; replace-then-drop, so nothing
    /// flashes). Called after wake / unlock, a fast-user-switch back, and when MenuBarAgent — the process that
    /// applies restrictions — was relaunched: a restriction lost there would otherwise leave every icon
    /// visible while the toggle still shows「<」. No-op unless collapsed with a granted restriction.
    public func reassertNativeRestriction() {
        guard started, isActive, engineKind == .native, driver.visibility == .collapsed,
              nativeState == .collapsed, let engine = nativeEngine, engine.isRestricted,
              !engine.isSessionLocked else { return } // locked: done again on unlock
        AppLog.info("menubar", "native: re-asserting the restriction")
        applyNativeRestriction()
    }

    private func scheduleNativeReassert(after delay: TimeInterval) {
        guard engineKind == .native else { return }
        reassertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.reassertWork = nil
                self?.reassertNativeRestriction()
            }
        }
        reassertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The toggle's window frame in CG coordinates (nil while it is not laid out in a menu bar).
    func toggleFrameCG() -> CGRect? {
        guard let frame = statusItems.frames().toggle, let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return nil }
        return MenuBarGeometry.toCG(frame, primaryMaxY: primaryMaxY)
    }

    // MARK: - Toggle clicks

    private func handleToggleClick(_ click: HiderStatusItems.Click) {
        cancelInitialCollapse()
        switch click {
        case .primary:
            if collapseBlocked, driver.visibility.isExpanded {
                // Re-check first: the user may have fixed the order in the meantime.
                refreshOrder()
                if collapseBlocked {
                    statusItems.showMenu(contextMenu())
                    return
                }
            }
            driver.toggle()
        case .option:
            // 兼容模式: ⌥ reveals the 永久隐藏区 too. 系统原生隐藏: ⌥ shows every icon, also the ones that do not
            // fit (see `revealAllIcons`) — but only where that differs from a plain click (collapsed, or a
            // partial reveal); otherwise an ⌥-click on the expanded toggle would visibly do nothing.
            let revealAll = engineKind == .legacy
                ? current.alwaysHiddenEnabled
                : driver.visibility == .collapsed || nativeRevealPlan != nil
            driver.toggle(revealAlwaysHidden: revealAll)
        case .secondary:
            statusItems.showMenu(contextMenu())
        }
    }

    // MARK: - Interaction probe

    /// Reports whether the user is using the menu bar right now (postpones the auto-collapse). With
    /// 点击时钟打开通知中心 an open Notification Center counts too: a restriction would disable it.
    func probeInteraction(_ completion: @escaping @MainActor (Bool) -> Void) {
        if arrangeHolds > 0 || menuTracking || NSEvent.pressedMouseButtons != 0
            || NSEvent.modifierFlags.contains(.command) || pointerInMenuBar() {
            completion(true)
            return
        }
        // Menus of other apps (e.g. a revealed item's menu) are pop-up-menu-level windows.
        let menus: @MainActor () -> Void = { [probeQueue] in
            probeQueue.async {
                let open = Self.isPopUpMenuOnScreen()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { completion(open) }
                }
            }
        }
        guard clockAssistWatchesNotificationCenter, let deps = clockAssistDeps else {
            menus()
            return
        }
        deps.notificationCenterOpen { open in
            if open { completion(true) } else { menus() }
        }
    }

    private func pointerInMenuBar() -> Bool {
        MenuBarGeometry.isPointInMenuBar(NSEvent.mouseLocation, screens: ScreenGeometry.current(),
                                         thickness: NSStatusBar.system.thickness)
    }

    /// True when any app shows a menu (window at the pop-up-menu level). Off-main.
    nonisolated static func isPopUpMenuOnScreen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.contains { ($0[kCGWindowLayer as String] as? Int) == menuLevel }
    }

    // MARK: - System observation

    private func observeSystem() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        func add(_ c: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (Notification) -> Void) {
            let token = c.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { body(note) }
            }
            observers.append((c, token))
        }
        add(center, NSMenu.didBeginTrackingNotification) { [weak self] _ in self?.menuTracking = true }
        add(center, NSMenu.didEndTrackingNotification) { [weak self] _ in self?.menuTracking = false }
        add(center, NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            guard let self else { return }
            self.hasNotch = Self.detectNotch()
            self.render() // collapsed length depends on the screen width
            self.scheduleOverflowUpdate(after: 0.3)
        }
        add(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            self?.render()
            self?.scheduleOverflowUpdate(after: 0.3)
        }
        // The frontmost app's menus decide how much room the status items get.
        add(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] _ in
            self?.scheduleOverflowUpdate(after: 0.15)
            self?.scheduleRevealRecheck()
        }
        // 系统原生隐藏: make sure the restriction survived sleep / a session switch / a MenuBarAgent restart.
        add(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in self?.scheduleNativeReassert(after: 2) }
        add(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] _ in self?.scheduleNativeReassert(after: 1) }
        add(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { [weak self] _ in
            self?.scheduleNativeReassert(after: 1)
        }
        add(workspace, NSWorkspace.didLaunchApplicationNotification) { [weak self] note in
            self?.scheduleRevealRecheck(after: 1) // its icons appear once it finished launching
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.menuBarAgentBundleID else { return }
            self?.scheduleNativeReassert(after: 1)
        }
    }

    /// Read-only snapshot of the status items (for logging and self-checks).
    public struct Diagnostics: Equatable {
        public var engine: HidingEngineKind
        /// A native visibility restriction is held right now.
        public var nativeRestricted: Bool
        public var hasSeparator: Bool
        public var isInstalled: Bool
        public var toggleFrame: CGRect?
        public var separatorFrame: CGRect?
        public var alwaysHiddenFrame: CGRect?
        public var separatorLength: CGFloat?
        public var alwaysHiddenLength: CGFloat?
        public var order: SeparatorOrder
        /// Length the separator gets when collapsed on the current screen.
        public var collapsedLength: CGFloat
    }

    public func diagnostics() -> Diagnostics {
        let f = statusItems.frames()
        return Diagnostics(engine: engineKind, nativeRestricted: nativeEngine?.isRestricted ?? false,
                           hasSeparator: statusItems.hasSeparators, isInstalled: statusItems.isInstalled,
                           toggleFrame: f.toggle, separatorFrame: f.separator, alwaysHiddenFrame: f.alwaysHidden,
                           separatorLength: statusItems.separator?.length,
                           alwaysHiddenLength: statusItems.alwaysHidden?.length,
                           order: statusItems.order,
                           collapsedLength: currentCollapsedLength())
    }

    func currentCollapsedLength() -> CGFloat {
        SeparatorMetrics.collapsedLength(strategy: strategy,
                                         screenWidth: statusItems.screen?.frame.width ?? 1440,
                                         windowPadding: statusItems.windowPadding())
    }

    static func detectNotch() -> Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 || $0.auxiliaryTopLeftArea != nil }
    }
}
