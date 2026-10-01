import AppKit
import Combine
import SwiftUI
import OneSwitchCore

/// 键鼠共享: use one keyboard & mouse for both Macs (Deskflow-style). The server shares its physical
/// keyboard/mouse; pushing the cursor through the configured screen edge moves control to the client.
@MainActor
public final class SharedInputModule: FeatureModule {
    public let id = "input"
    public let displayName = "键鼠共享"
    public let symbolName = "keyboard"

    public static let serviceName = "input"
    static let hotKeyID = "input.toggle"

    public let store: SettingsStore<InputSettings>
    public let model = InputStatusModel()

    private let hub: any PeerHub
    private let clipboard = ClipboardSync()
    private var session: InputSession?
    private var registered = false
    private var started = false
    /// The settings currently applied. `store.$value` publishes in `willSet`, i.e. *before* `store.value`
    /// changes, so code reacting to a change must not read `store.value`.
    private var settings: InputSettings
    private var cancellables: Set<AnyCancellable> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []

    public convenience init(hub: any PeerHub) {
        self.init(hub: hub, defaults: AppEnvironment.defaults)
    }

    /// Testable initializer (inject a scratch UserDefaults suite).
    init(hub: any PeerHub, defaults: UserDefaults) {
        self.hub = hub
        store = SettingsStore(key: "input.settings", defaultValue: InputSettings(), defaults: defaults)
        settings = store.value
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        store.$value
            .removeDuplicates()
            .sink { [weak self] settings in self?.apply(settings) }
            .store(in: &cancellables)
        hub.statusPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.model.linkStatus = status.displayText
                self?.refreshActivity()
            }
            .store(in: &cancellables)
        observeSystem()
    }

    public func stop() {
        guard started else { return }
        started = false
        cancellables.removeAll()
        let wc = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(wc.removeObserver)
        distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        defaultObservers.forEach(NotificationCenter.default.removeObserver)
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
        defaultObservers.removeAll()
        GlobalHotKeyCenter.shared.unregister(id: Self.hotKeyID)
        model.hotKeyProblem = nil
        session?.close() // restores the cursor, disables the taps, releases held keys
        session = nil
        if registered {
            hub.unregister(service: Self.serviceName)
            registered = false
        }
    }

    private func apply(_ settings: InputSettings) {
        self.settings = settings
        if settings.enabled && !registered {
            hub.register(service: Self.serviceName) { [weak self] channel in
                self?.channelOpened(channel)
            }
            registered = true
        } else if !settings.enabled && registered {
            hub.unregister(service: Self.serviceName)
            registered = false
            session?.close()
            session = nil
        }
        session?.apply(settings: settings)

        if settings.enabled && settings.role == .server {
            let ok = GlobalHotKeyCenter.shared.register(id: Self.hotKeyID, hotKey: settings.switchHotKey) { [weak self] in
                self?.session?.toggleControl()
            }
            model.hotKeyProblem = ok ? nil : "快捷键 \(settings.switchHotKey?.displayString ?? "") 已被其他应用占用，请更换"
        } else {
            GlobalHotKeyCenter.shared.unregister(id: Self.hotKeyID)
            model.hotKeyProblem = nil
        }
        refreshActivity()
    }

    private func channelOpened(_ channel: PeerChannel) {
        // A hub may hand out a channel that was negotiated just before we were disabled / stopped.
        guard started, settings.enabled else {
            channel.close()
            return
        }
        session?.close()
        let s = InputSession(channel: channel, settings: settings, model: model, clipboard: clipboard,
                             localName: hub.localDeviceName)
        s.onClosed = { [weak self, weak s] in
            guard let self, let s, self.session === s else { return }
            self.session = nil
            self.refreshActivity()
            AppContext.shared.refreshStatusIcon()
        }
        session = s
        s.start()
        refreshActivity()
    }

    private func refreshActivity() {
        if !settings.enabled {
            model.activity = .inactive
        } else if session == nil {
            model.activity = .waitingForPeer
            model.peerReady = false
        }
    }

    /// Safety: hand control back when this Mac locks, sleeps or switches user; follow display changes.
    private func observeSystem() {
        let wc = NSWorkspace.shared.notificationCenter
        let returnNames: [(Notification.Name, String)] = [
            (NSWorkspace.screensDidSleepNotification, "显示器进入睡眠，已切回本机"),
            (NSWorkspace.willSleepNotification, "Mac 即将睡眠，已切回本机"),
            (NSWorkspace.sessionDidResignActiveNotification, "已切换用户，已切回本机"),
        ]
        for (name, reason) in returnNames {
            workspaceObservers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session?.forceReturn(reason: reason) }
            })
        }
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.forceReturn(reason: "屏幕已锁定，已切回本机") }
        })
        // Waking posts no screen-parameter change when the arrangement is unchanged, but a session set up
        // during a dark wake read the displays while they were off.
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session?.updateGeometry() }
            })
        }
        defaultObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session?.updateGeometry() }
        })
    }

    // MARK: FeatureModule UI

    public var statusIconSymbol: String? {
        model.activity == .controllingPeer ? "display.2" : nil
    }

    /// One-line status for the menu.
    public var statusLine: String {
        let s = store.value
        switch model.activity {
        case .inactive:
            return "○ 键鼠共享已关闭"
        case .waitingForPeer:
            return "○ \(s.role.shortTitle) · 等待连接另一台 Mac"
        case .ready:
            let peer = model.peerName ?? "另一台 Mac"
            if let problem = model.problem { return "⚠︎ \(problem)" }
            return s.role == .server ? "● 服务端 · 已连接 \(peer) · 当前控制：本机" : "● 客户端 · 已连接 \(peer) · 等待控制"
        case .controllingPeer:
            return "◉ 正在控制 \(model.peerName ?? "另一台 Mac")"
        case .controlledByPeer:
            return "◉ 正由 \(model.peerName ?? "另一台 Mac") 控制"
        }
    }

    public func menuItems() -> [NSMenuItem] {
        let s = store.value
        var items: [NSMenuItem] = [.info(statusLine)]
        if s.enabled && s.role == .server, let session {
            let hotkey = s.switchHotKey.map { "（\($0.displayString)）" } ?? ""
            if session.isServerControllingPeer {
                items.append(BlockMenuItem("切回本机\(hotkey)", symbol: "arrow.uturn.backward") { [weak self] in
                    self?.session?.forceReturn(reason: "手动切回本机")
                })
            } else {
                let item = BlockMenuItem("切换到 \(model.peerName ?? "另一台 Mac")\(hotkey)", symbol: "arrow.right.circle",
                                         enabled: model.peerReady) { [weak self] in
                    self?.session?.toggleControl()
                }
                items.append(item)
            }
        }
        if model.secureInputActive {
            items.append(.info("⚠︎ 有应用启用了安全输入（如密码框），键盘暂时无法共享"))
        }
        if s.enabled && s.role == .server, let problem = model.hotKeyProblem {
            items.append(.info("⚠︎ \(problem)"))
        }
        items.append(BlockMenuItem(s.enabled ? "关闭键鼠共享" : "开启键鼠共享", state: s.enabled ? .on : .off) { [weak self] in
            self?.store.update { $0.enabled.toggle() }
        })
        items.append(BlockMenuItem("键鼠共享设置…", symbol: "gearshape") {
            AppContext.shared.openSettings(moduleID: "input")
        })
        return items
    }

    public func settingsView() -> AnyView {
        AnyView(SharedInputSettingsView(store: store, model: model, localName: hub.localDeviceName))
    }
}
