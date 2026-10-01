import SwiftUI
import OneSwitchCore

struct SharedInputSettingsView: View {
    @ObservedObject var store: SettingsStore<InputSettings>
    @ObservedObject var model: InputStatusModel
    /// This Mac's name (from the PeerHub — `Host.current()` can block the main thread on name lookups).
    let localName: String

    var body: some View {
        SettingsPage("键鼠共享", subtitle: "两台 Mac 共用一套键盘鼠标：把鼠标移过屏幕边缘，即可控制另一台 Mac") {
            Section("状态") {
                HStack {
                    StatusBadge(statusText, tone: tone)
                    Spacer()
                    if store.value.role == .server && model.activity == .controllingPeer {
                        Text("快捷键或把鼠标移回来即可切回").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if model.secureInputActive {
                    Label("有应用启用了“安全输入”（如密码输入框），此时键盘无法共享；鼠标不受影响。", systemImage: "lock")
                        .foregroundStyle(.orange)
                }
                if let reason = model.lastReason {
                    LabeledContent("最近一次切换", value: reason)
                }
                LabeledContent("雷雳互联", value: model.linkStatus)
            }

            Section("基本") {
                Toggle("启用键鼠共享", isOn: $store.value.enabled)
                Picker("本机角色", selection: $store.value.role) {
                    ForEach(InputRole.allCases) { Text($0.title).tag($0) }
                }
                Text("一台 Mac 设为服务端（接着键盘鼠标的那台，通常是 Mac Studio），另一台设为客户端。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if store.value.role == .server {
                Section("屏幕布局") {
                    LayoutPicker(side: $store.value.clientSide, peerName: model.peerName ?? "另一台 Mac", localName: localName)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    Text("点击方框选择另一台 Mac 屏幕所在的位置。鼠标移过本机对应的屏幕边缘时，控制权切换到另一台 Mac；在那台 Mac 上把鼠标移回来即切回。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("切换方式") {
                    Picker("边缘停留时间", selection: $store.value.dwellMilliseconds) {
                        Text("立即").tag(0)
                        Text("0.1 秒").tag(100)
                        Text("0.25 秒").tag(250)
                        Text("0.5 秒").tag(500)
                    }
                    Picker("切换时需按住", selection: $store.value.requiredModifier) {
                        ForEach(RequiredModifier.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("按住鼠标按键时不切换", isOn: $store.value.blockWhileButtonHeld)
                    LabeledContent("切换 / 切回快捷键") {
                        HotKeyRecorder(hotKey: $store.value.switchHotKey)
                    }
                    if let problem = model.hotKeyProblem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Text(store.value.switchHotKey == nil
                         ? "未设置快捷键：控制另一台 Mac 时，可按 ⌃⌥⌘← 立即切回本机。"
                         : "控制另一台 Mac 时，按下此快捷键会立即切回本机。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("鼠标滚轮（在另一台 Mac 上）") {
                    Picker("滚轮方向", selection: $store.value.wheelDirection) {
                        ForEach(WheelDirection.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("平滑滚动", isOn: $store.value.smoothScrolling)
                    LabeledContent("滚动速度") {
                        HStack(spacing: 8) {
                            Text("慢").font(.caption).foregroundStyle(.secondary)
                            Picker("滚动速度", selection: $store.value.scrollSpeed) {
                                ForEach(Array(WheelConfig.speedRange), id: \.self) { Text("\($0)").tag($0) }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 220)
                            Text("快").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("只影响控制另一台 Mac 时的鼠标滚轮：方向不受两台 Mac 各自“自然滚动”设置的影响；即使另一台 Mac 上运行着 Mos 等滚动工具，也能正常、平滑地滚动。触控板和妙控鼠标的滚动保持原样。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if let side = model.serverClientSide {
                    Section("屏幕布局") {
                        LabeledContent("由服务端设置", value: "本机位于 \(model.peerName ?? "服务端") 的\(side.title)")
                    }
                }
                if let wheel = model.serverWheel {
                    Section("鼠标滚轮") {
                        LabeledContent("滚轮方向", value: wheel.direction.title)
                        LabeledContent("平滑滚动", value: wheel.smooth ? "开" : "关")
                        LabeledContent("滚动速度", value: "\(wheel.speed) / 5")
                        Text("以上设置在服务端（\(model.peerName ?? "另一台 Mac")）的键鼠共享设置中修改。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("剪贴板") {
                Toggle("切换时同步剪贴板（文字、富文本、图片）", isOn: $store.value.clipboardSync)
                Text("控制权在两台 Mac 之间切换时，刚才在用的那台 Mac 会把剪贴板内容带到另一台（两台都需打开此项）。图片最大 100 MB；暂不支持在两台 Mac 之间复制粘贴文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("权限") {
                PermissionRow(.accessibility, reason: store.value.role == .server
                              ? "拦截并转发本机的键盘鼠标事件" : "接收另一台 Mac 发来的键盘鼠标操作")
                if store.value.role == .server {
                    PermissionRow(.inputMonitoring, reason: "读取键盘输入，以便在控制另一台 Mac 时转发按键")
                }
            }

            Section("隐私说明") {
                Text("在本机工作时，OneSwitch 不会拦截任何键盘输入，只观察鼠标位置来判断是否到达屏幕边缘。只有当你把控制权切换到另一台 Mac 后，键盘和鼠标操作才会被接管，并通过加密的雷雳连接实时发送给那台 Mac。按键内容不会被记录、保存或发送到其他任何地方。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("诊断") {
                LabeledContent("往返延迟", value: model.rtt.map { String(format: "%.2f 毫秒", $0 * 1000) } ?? "—")
                LabeledContent("事件速率", value: "\(model.eventsPerSecond) 个/秒")
            }
        }
    }

    private var statusText: String {
        switch model.activity {
        case .inactive: return "已关闭"
        case .waitingForPeer: return "等待连接另一台 Mac"
        case .ready: return store.value.role == .server ? "已连接 \(model.peerName ?? "")，当前控制本机" : "已连接 \(model.peerName ?? "")，等待控制"
        case .controllingPeer: return "正在控制 \(model.peerName ?? "另一台 Mac")"
        case .controlledByPeer: return "正由 \(model.peerName ?? "另一台 Mac") 控制"
        }
    }

    private var tone: StatusBadge.Tone {
        switch model.activity {
        case .inactive: return .idle
        case .waitingForPeer: return .warning
        case .ready: return model.problem == nil ? .ok : .warning
        case .controllingPeer, .controlledByPeer: return .busy
        }
    }
}

/// This Mac in the middle; click a slot to place the other Mac's screen.
private struct LayoutPicker: View {
    @Binding var side: ScreenSide
    let peerName: String
    let localName: String

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                Color.clear.frame(width: 110, height: 64)
                slot(.top)
                Color.clear.frame(width: 110, height: 64)
            }
            GridRow {
                slot(.left)
                screen(title: "本机", subtitle: localName, highlighted: false)
                slot(.right)
            }
            GridRow {
                Color.clear.frame(width: 110, height: 64)
                slot(.bottom)
                Color.clear.frame(width: 110, height: 64)
            }
        }
    }

    @ViewBuilder
    private func slot(_ s: ScreenSide) -> some View {
        Button {
            side = s
        } label: {
            if side == s {
                screen(title: peerName, subtitle: "在\(s.title)", highlighted: true)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .frame(width: 110, height: 64)
                    .overlay(Text(s.title).font(.caption).foregroundStyle(.secondary))
                    .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help("另一台 Mac 在本机\(s.title)")
    }

    private func screen(title: String, subtitle: String, highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(highlighted ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(highlighted ? Color.accentColor : Color.secondary, lineWidth: 1.5))
            .frame(width: 110, height: 64)
            .overlay(
                VStack(spacing: 2) {
                    Image(systemName: "display")
                    Text(title).font(.caption.bold()).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(4)
            )
    }
}
