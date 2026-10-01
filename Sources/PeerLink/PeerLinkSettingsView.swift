import AppKit
import Combine
import SwiftUI
import OneSwitchCore

/// 设置 → 雷雳互联.
struct PeerLinkSettingsView: View {
    @ObservedObject var module: PeerLinkModule
    @ObservedObject var store: SettingsStore<PeerLinkSettings>
    @ObservedObject var bridge: BridgeManager

    @ViewState private var showPasscode = false
    @ViewState private var copiedPasscode = false
    @ViewState private var copiedDiagnostics = false
    @ViewState private var portText = ""
    @ViewState private var tick = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsPage("雷雳互联", subtitle: "通过雷雳线连接另一台 Mac，为文件同步和键鼠共享提供加密通道") {
            statusSection
            pairingSection
            deviceSection
            networkSection
            if module.configuration.manageThunderboltBridge { staticIPSection }
            channelsSection
            diagnosticsSection
        }
        .onReceive(timer) { _ in tick &+= 1 }
        .onAppear {
            portText = String(store.value.port)
            if module.configuration.manageThunderboltBridge { bridge.refresh() }
        }
    }

    // MARK: 状态

    private var statusTone: StatusBadge.Tone {
        switch module.status {
        case .connected: return .ok
        case .searching: return .busy
        case .error: return .error
        case .disabled: return .idle
        }
    }

    @ViewBuilder private var statusSection: some View {
        Section("状态") {
            HStack {
                StatusBadge(module.statusLine().0, tone: statusTone)
                Spacer()
                Button("重新连接") { module.reconnect() }
                    .disabled(module.engine?.isRunning != true)
            }
            if case .connected(let peer) = module.status {
                LabeledContent("对方", value: peer.name)
                LabeledContent("地址", value: (peer.address ?? "—") + (peer.viaThunderbolt ? "（雷雳网桥）" : ""))
                if let rtt = module.engine?.primaryChannel?.stats.smoothedRTT, tick >= 0 {
                    LabeledContent("延迟", value: PeerLinkModule.formatRTT(rtt))
                }
            }
        }
    }

    // MARK: 配对码

    @ViewBuilder private var pairingSection: some View {
        Section {
            LabeledContent("配对码") {
                HStack(spacing: 6) {
                    Group {
                        if showPasscode {
                            TextField("", text: $store.value.passcode, prompt: Text("两台 Mac 相同"))
                        } else {
                            SecureField("", text: $store.value.passcode, prompt: Text("两台 Mac 相同"))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 180)
                    Button {
                        showPasscode.toggle()
                    } label: {
                        Image(systemName: showPasscode ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(showPasscode ? "隐藏配对码" : "显示配对码")
                }
            }
            HStack {
                Button("生成随机配对码") {
                    store.value.passcode = Passcode.generate()
                    showPasscode = true
                }
                Button("拷贝") {
                    copyToPasteboard(Passcode.normalize(store.value.passcode))
                    flash($copiedPasscode)
                }
                .disabled(Passcode.normalize(store.value.passcode).isEmpty)
                if copiedPasscode {
                    Text("已拷贝").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("配对码")
        } footer: {
            footerText("两台 Mac 必须填写完全相同的配对码（区分大小写）。配对码用于加密连接并验证对方身份；在一台 Mac 上生成后，在另一台 Mac 上输入同样的内容即可。")
        }
    }

    // MARK: 本机

    @ViewBuilder private var deviceSection: some View {
        Section("本机") {
            LabeledContent("本机名称", value: module.localDeviceName)
            LabeledContent("设备 ID") {
                Text(module.localDeviceID)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: 网络

    private var portIsValid: Bool {
        guard let p = Int(portText.trimmingCharacters(in: .whitespaces)) else { return false }
        return (1024...65535).contains(p)
    }

    private func applyPort() {
        guard portIsValid, let p = Int(portText.trimmingCharacters(in: .whitespaces)) else { return }
        store.value.port = p
    }

    @ViewBuilder private var networkSection: some View {
        Section {
            Picker("网络接口", selection: $store.value.interfacePolicy) {
                ForEach(InterfacePolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            Text(store.value.interfacePolicy.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("端口") {
                HStack(spacing: 6) {
                    TextField("", text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .onSubmit(applyPort)
                    Button("应用", action: applyPort)
                        .disabled(!portIsValid || Int(portText) == store.value.port)
                }
            }
            if !portText.isEmpty && !portIsValid {
                Text("端口需在 1024–65535 之间").font(.caption).foregroundStyle(.red)
            }
            if let actual = module.engine?.listenerPort, Int(actual) != store.value.port, tick >= 0 {
                Text("端口 \(String(store.value.port)) 已被占用，当前临时使用 \(String(actual))（Bonjour 仍可发现本机）。")
                    .font(.caption).foregroundStyle(.orange)
            }
            LabeledContent("对方 IP（可选）") {
                TextField("", text: $store.value.peerAddress, prompt: Text(derivedPeerIP ?? "例如 10.77.0.2"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
        } header: {
            Text("网络")
        } footer: {
            footerText("两台 Mac 通过 Bonjour 自动互相发现；若 5 秒内未发现对方，将直接连接“对方 IP”。留空时使用静态 IP 方案推算的地址\(derivedPeerIP.map { "（\($0)）" } ?? "")。两台 Mac 的端口应保持一致。")
        }
    }

    private var derivedPeerIP: String? {
        let s = store.value
        return s.staticIPEnabled ? ThunderboltBridge.derivePeerIP(from: s.staticIP) : nil
    }

    // MARK: 静态 IP

    private var staticIPValid: Bool { IPv4.isValidHost(store.value.staticIP) }
    private var staticMaskValid: Bool { IPv4.isValidMask(store.value.staticMask) }

    @ViewBuilder private var staticIPSection: some View {
        let state = bridge.state
        let settings = store.value
        Section {
            Toggle("自动配置雷雳网桥静态 IP", isOn: $store.value.staticIPEnabled)
            LabeledContent("本机 IP") {
                HStack(spacing: 6) {
                    if !staticIPValid {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("IP 地址无效")
                    }
                    TextField("", text: $store.value.staticIP)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }
            }
            LabeledContent("子网掩码") {
                HStack(spacing: 6) {
                    if !staticMaskValid {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("子网掩码无效")
                    }
                    TextField("", text: $store.value.staticMask)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }
            }
            LabeledContent("对方 IP", value: ThunderboltBridge.derivePeerIP(from: settings.staticIP) ?? "—（本机 IP 末位需为 1 或 2）")
            HStack {
                Button("立即配置") { module.configureStaticIPNow() }
                    .disabled(state.busy || !staticIPValid || !staticMaskValid)
                Button("恢复为自动（DHCP）") { module.restoreDHCP() }
                    .disabled(state.busy)
                if state.busy {
                    ProgressView().controlSize(.small)
                }
            }
            if let message = state.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(state.messageIsError ? Color.red : Color.secondary)
            }
            if settings.staticIPPromptDeclined && settings.staticIPEnabled {
                Text("上次已取消管理员授权，启动时不会再自动弹出密码框；点击“立即配置”可重新配置。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let conflict = addressConflictWarning {
                Text(conflict).font(.caption).foregroundStyle(.red)
            }
            LabeledContent("网络服务", value: state.serviceName.map { $0 + (state.serviceEnabled ? "" : "（已停用）") }
                           ?? (state.serviceMissing ? "未找到雷雳网桥服务" : "读取中…"))
            LabeledContent("雷雳线", value: state.linkActive.map { $0 ? "已连接" : "未连接" } ?? "未知")
            LabeledContent("当前配置", value: currentConfigText(state))
            LabeledContent("本机地址", value: state.addresses.isEmpty ? "无" : state.addresses.joined(separator: "、"))
            LabeledContent("对方地址", value: module.peerBridgeAddress() ?? "—")
            LabeledContent("与设置一致") {
                let ok = ThunderboltBridge.isConfigured(state.config, ip: settings.staticIP, mask: settings.staticMask)
                Label(ok ? "是" : "否", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(ok ? Color.green : Color.secondary)
            }
        } header: {
            Text("雷雳网桥静态 IP")
        } footer: {
            footerText("开启后，OneSwitch 启动时会检查雷雳网桥；如尚未设为上面的静态 IP，会弹出系统密码框完成配置（只需一次，重启后依然有效）。不设置路由器，因此不影响 Wi‑Fi 或以太网上网。两台 Mac 应使用同一网段的不同地址，例如 10.77.0.1 与 10.77.0.2。")
        }
    }

    private func currentConfigText(_ state: BridgeManager.State) -> String {
        guard let config = state.config else { return state.lastRefresh == nil ? "读取中…" : "未知" }
        var text = config.method.displayName
        if let ip = config.ipAddress { text += " · \(ip)" }
        if let mask = config.subnetMask { text += " / \(mask)" }
        return text
    }

    private var addressConflictWarning: String? {
        guard let engine = module.engine else { return nil }
        let mine = store.value.staticIP
        guard IPv4.isValidHost(mine), engine.peerBridgeAddresses.contains(mine) else { return nil }
        return "对方 Mac 的雷雳网桥也使用了 \(mine)：请将其中一台改为 \(ThunderboltBridge.derivePeerIP(from: mine) ?? "其他地址")。"
    }

    // MARK: 通道

    @ViewBuilder private var channelsSection: some View {
        let rows = tick >= 0 ? module.channelRows() : []
        Section("通道") {
            if rows.isEmpty {
                Text("暂无通道").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.title).fontWeight(.medium)
                        Spacer()
                        if row.viaThunderbolt {
                            Label("雷雳", systemImage: "bolt.fill").font(.caption).foregroundStyle(.orange)
                        } else {
                            Text(row.linkKind).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("\(row.peerName) · \(row.address) · 延迟 \(row.rtt.map(PeerLinkModule.formatRTT) ?? "—") · 发送 \(Fmt.bytes(row.bytesOut)) · 接收 \(Fmt.bytes(row.bytesIn))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 诊断

    @ViewBuilder private var diagnosticsSection: some View {
        let engine = module.engine
        Section("诊断") {
            LabeledContent("监听端口", value: engine.map { e in e.listenerPort.map(String.init) ?? (e.listenerError ?? "未监听") } ?? "未运行")
            LabeledContent("Bonjour", value: engine?.browserState ?? "未运行")
            LabeledContent("已发现的 Mac", value: module.discoveredPeerNames.joined(separator: "；").nilIfEmpty ?? "无")
            ForEach(tick >= 0 ? module.serviceRows() : []) { row in
                LabeledContent(row.title, value: row.state)
            }
            DisclosureGroup("最近事件") {
                ScrollView {
                    Text((engine?.recentEvents ?? []).reversed().joined(separator: "\n").nilIfEmpty ?? "暂无事件")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            }
            HStack {
                Button("拷贝诊断信息") {
                    copyToPasteboard(module.diagnosticsText())
                    flash($copiedDiagnostics)
                }
                if copiedDiagnostics { Text("已拷贝").foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Helpers

    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func flash(_ flag: Binding<Bool>) {
        flag.wrappedValue = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { flag.wrappedValue = false }
    }
}
