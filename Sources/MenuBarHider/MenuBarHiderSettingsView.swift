import AppKit
import SwiftUI
import OneSwitchCore

/// Settings page of the 菜单栏图标 module.
struct MenuBarHiderSettingsView: View {
    @ObservedObject var controller: MenuBarHiderController
    @ObservedObject var store: SettingsStore<MenuBarHiderSettings>

    init(controller: MenuBarHiderController) {
        self.controller = controller
        self.store = controller.store
    }

    private var settings: MenuBarHiderSettings { store.value }
    private var isNative: Bool { controller.engineKind == .native }

    var body: some View {
        SettingsPage("菜单栏图标", subtitle: "把不常用的菜单栏图标收起来，需要时点一下就能显示") {
            statusSection
            behaviorSection
            appearanceSection
            hotKeySection
            if isNative {
                NativeAppListSection(controller: controller, store: store)
                nativeGuideSection
            } else {
                guideSection
                itemListSection
            }
        }
    }

    // MARK: 状态

    private var statusSection: some View {
        Section("状态") {
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    StatusBadge(controller.stateText, tone: statusTone)
                }
                Spacer()
                if settings.enabled && controller.isActive {
                    if controller.visibility == .collapsed {
                        Button("显示图标") { controller.expand() }
                    } else {
                        Button("立即隐藏") { controller.collapse() }
                    }
                }
            }
            engineRow
            if let warning = controller.warningText {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let note = controller.nativeNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if isNative {
                if let note = controller.nativeRevealNote {
                    HStack(spacing: 8) {
                        Label(note, systemImage: "rectangle.compress.vertical")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(MenuBarHiderController.showAllIconsTitle) { controller.revealAllIcons() }
                    }
                }
                if controller.hasNotch {
                    Label("这台 Mac 的屏幕有刘海，刘海右侧放不下太多图标。展开时只显示放得下的隐藏图标（离「<」近的优先），其余的继续隐藏，"
                          + "免得 macOS 把「<」和 OneSwitch 的图标挤进系统的“«”；展开期间切换到菜单很多的 App 时，放不下的图标会自动再收起。"
                          + "要看全部图标，可在菜单或右键菜单中选择“\(MenuBarHiderController.showAllIconsTitle)”，"
                          + "或按住 ⌥ 点击「<」，放不下的图标会进入“«”。",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                legacyHintRows
            }
        }
    }

    /// 隐藏方式 + (after a fallback) why, with a retry button.
    @ViewBuilder
    private var engineRow: some View {
        LabeledContent("隐藏方式") {
            Text(controller.engineTitle).foregroundStyle(.secondary)
        }
        if isNative {
            Text("菜单栏上只显示「<」，隐藏的图标由 macOS 直接收起，不会出现“«”和空白。OneSwitch 退出（包括意外退出）时，macOS 会自动恢复显示所有图标。")
                .font(.caption).foregroundStyle(.secondary)
        } else if controller.strategy == .systemOverflow, let reason = controller.nativeFallbackReason {
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if settings.enabled && controller.isActive {
                    Button("重新尝试系统原生隐藏") { controller.retryNativeHiding() }
                }
            }
        }
    }

    @ViewBuilder
    private var legacyHintRows: some View {
        Group {
            if controller.strategy == .systemOverflow && !Permissions.isGranted(.accessibility) {
                Label("授予“辅助功能”权限后，OneSwitch 会根据当前应用菜单的宽度自动调整切换按钮，在大屏幕上也能把图标完全隐藏。",
                      systemImage: "hand.raised")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if controller.hasNotch {
                Label("这台 Mac 的屏幕有刘海：显示区的图标太多时，放不下的图标会被刘海挡住"
                      + (controller.strategy == .systemOverflow ? "或收进系统的“«”按钮" : "")
                      + "。建议只把最常用的几个图标留在显示区。",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusTone: StatusBadge.Tone {
        if !settings.enabled { return .idle }
        if controller.warningText != nil { return .warning }
        return controller.visibility == .collapsed ? .ok : .busy
    }

    // MARK: 基本

    private var behaviorSection: some View {
        Section("基本") {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("启用", isOn: $store.value.enabled)
                Text(isNative ? "关闭后会移除「<」，所有图标恢复正常显示" : "关闭后会移除分隔线，所有图标恢复正常显示")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                Toggle("启动时自动隐藏", isOn: $store.value.collapseAtLaunch)
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("自动重新隐藏", isOn: $store.value.autoCollapse)
                    Text("鼠标停在菜单栏上或菜单打开时，会等到离开后再隐藏")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if settings.autoCollapse {
                    HStack(spacing: 10) {
                        Text("隐藏延迟")
                        Slider(value: delayBinding,
                               in: Double(MenuBarHiderSettings.delayRange.lowerBound)...Double(MenuBarHiderSettings.delayRange.upperBound),
                               step: Double(MenuBarHiderSettings.delayStep)) {
                            Text("隐藏延迟")
                        } minimumValueLabel: {
                            Text("5 秒").font(.caption)
                        } maximumValueLabel: {
                            Text("1 分钟").font(.caption)
                        }
                        .labelsHidden()
                        Text(Self.delayLabel(settings.effectiveDelay))
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                if isNative {
                    Text("系统原生隐藏没有“永久隐藏区”：展开时会显示所有隐藏的图标（菜单栏放不下时只显示放得下的）。想让某个 App 的图标一直不出现，可以在“系统设置 → 菜单栏”中关闭它的“允许在菜单栏中显示”。")
                        .font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("点击时钟时临时显示全部并打开通知中心", isOn: $store.value.clockOpensNotificationCenter)
                        Text("系统在隐藏图标期间会禁用通知中心，点击菜单栏右侧的日期和时间没有反应（刘海屏 Mac 展开时也可能如此）。"
                             + "开启后，点击日期和时间会先临时显示全部图标，再打开通知中心；关闭通知中心后恢复原来的隐藏状态。需要“辅助功能”权限。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("永久隐藏区", isOn: $store.value.alwaysHiddenEnabled)
                        Text("再添加一条虚线分隔线：它左侧的图标平时一直隐藏，只有按住 ⌥ 点击切换按钮时才会显示")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(!settings.enabled)
        }
    }

    private var delayBinding: Binding<Double> {
        Binding(
            get: { Double(store.value.effectiveDelay) },
            set: { newValue in
                let clamped = MenuBarHiderSettings.clampDelay(Int(newValue.rounded()))
                if store.value.autoCollapseDelay != clamped { store.value.autoCollapseDelay = clamped }
            })
    }

    static func delayLabel(_ seconds: Int) -> String {
        seconds >= 60 ? "1 分钟" : "\(seconds) 秒"
    }

    // MARK: 外观

    private var appearanceSection: some View {
        Section("外观") {
            Picker("切换按钮", selection: $store.value.toggleStyle) {
                ForEach(ToggleIconStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if !isNative {
                Picker("分隔线样式", selection: $store.value.separatorStyle) {
                    ForEach(SeparatorStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("收起时隐藏分隔线图标", isOn: $store.value.hideSeparatorWhenCollapsed)
            }
        }
        .disabled(!settings.enabled)
    }

    // MARK: 快捷键

    private var hotKeySection: some View {
        Section("快捷键") {
            LabeledContent("显示 / 隐藏图标") {
                HotKeyRecorder(hotKey: $store.value.hotKey)
            }
            if let error = controller.hotKeyError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .disabled(!settings.enabled)
    }

    // MARK: 使用方法

    private var guideSection: some View {
        Section("使用方法") {
            MenuBarDiagram(alwaysHidden: settings.alwaysHiddenEnabled, toggleStyle: settings.toggleStyle)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 6) {
                guideStep(1, "按住 ⌘ 键，把要隐藏的图标拖到分隔线“\(settings.separatorStyle == .line ? "|" : "•")”的左侧（隐藏区）。")
                guideStep(2, "点击切换按钮显示隐藏的图标"
                          + (settings.autoCollapse ? "，\(Self.delayLabel(settings.effectiveDelay))后自动重新隐藏" : "")
                          + "；再点一次立即隐藏。")
                guideStep(3, "右键点击切换按钮可打开快捷菜单；按住 ⌥ 点击会连同永久隐藏区一起显示。")
                guideStep(4, "分隔线必须位于切换按钮左侧，否则为了安全不会隐藏任何图标。")
                if controller.strategy == .systemOverflow {
                    Text("macOS 27 起，系统会把放不下的图标收进“«”按钮。图标收起时，隐藏区的图标也会进入“«”，点击“«”同样可以临时查看。")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
        }
    }

    private var nativeGuideSection: some View {
        Section("使用方法") {
            NativeMenuBarDiagram(toggleStyle: settings.toggleStyle)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 6) {
                guideStep(1, "点击菜单栏上的「<」显示隐藏的图标"
                          + (settings.autoCollapse ? "，\(Self.delayLabel(settings.effectiveDelay))后自动重新隐藏" : "")
                          + "；再点一次「>」立即隐藏。")
                guideStep(2, "默认按位置决定：「<」左侧的 App 收起时隐藏，右侧的保持显示。按住 ⌘ 拖动图标可以调整位置，也可以在上面的列表中把 App 设为“始终隐藏”或“始终显示”。")
                guideStep(3, "右键点击「<」打开快捷菜单；也可以在上面设置快捷键。菜单栏放不下全部图标时，展开只显示放得下的，按住 ⌥ 点击「<」可显示全部。")
            }
        }
    }

    private func guideStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 图标列表（实验性）

    private var itemListSection: some View {
        Section {
            PermissionRow(.accessibility, reason: "读取菜单栏图标的位置，并模拟 ⌘ 拖动来移动图标")
            HStack(spacing: 8) {
                Button("刷新列表") { controller.refreshItems() }
                    .disabled(controller.isBusy)
                if controller.isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let date = controller.lastScan {
                    Text("更新于 " + Self.timeFormatter.string(from: date))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let note = controller.listNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let result = controller.moveResult {
                Label(result.message, systemImage: result.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.success ? .green : .orange)
                    .font(.callout)
            }
            if controller.items.isEmpty {
                Text(controller.lastScan == nil ? "点击“刷新列表”读取当前的菜单栏图标" : "没有找到其他应用的菜单栏图标")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(controller.items) { row in
                    itemRow(row)
                }
            }
            Text("刷新或移动时会临时显示全部图标以读取位置；移动时鼠标指针会自动移动约 1 秒，请勿操作鼠标。系统图标（如时钟、控制中心）无法移动。")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HStack(spacing: 6) {
                Text("菜单栏图标列表")
                Text("实验性")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
            }
        }
    }

    private func itemRow(_ row: MenuBarItemRow) -> some View {
        let info = row.info
        return HStack(spacing: 10) {
            Group {
                if let icon = row.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.dashed").resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name).lineLimit(1)
                if let detail = info.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(info.section.title)
                .font(.caption)
                .foregroundStyle(color(for: info.section))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(color(for: info.section).opacity(0.12)))
            moveButton(for: info)
                .frame(minWidth: 86, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func moveButton(for info: MenuBarItemInfo) -> some View {
        if controller.movingItemID == info.id {
            ProgressView().controlSize(.small)
        } else if !info.isMovable {
            Text("无法移动").font(.caption).foregroundStyle(.secondary)
        } else {
            switch info.section {
            case .visible:
                Button(MoveDestination.hidden.title) { controller.moveItem(id: info.id, to: .hidden) }
                    .disabled(controller.isBusy || !controller.isActive)
            case .hidden, .alwaysHidden:
                Button(MoveDestination.visible.title) { controller.moveItem(id: info.id, to: .visible) }
                    .disabled(controller.isBusy || !controller.isActive)
            case .overflow, .offscreen:
                EmptyView()
            }
        }
    }

    private func color(for section: MenuBarSection) -> Color {
        switch section {
        case .visible: return .green
        case .hidden: return .blue
        case .alwaysHidden: return .purple
        case .overflow: return .orange
        case .offscreen: return .secondary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Small illustration of the menu-bar layout built from SF Symbols.
struct MenuBarDiagram: View {
    let alwaysHidden: Bool
    let toggleStyle: ToggleIconStyle

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                if alwaysHidden {
                    icons(["tray.full.fill"], width: 56, hidden: true)
                    dashedDivider.frame(width: 24)
                }
                icons(["cloud.fill", "music.note", "gamecontroller.fill"], width: 100, hidden: true)
                divider.frame(width: 36)
                Image(systemName: toggleStyle == .chevron ? "chevron.left" : "circle.fill")
                    .font(.system(size: toggleStyle == .chevron ? 12 : 6, weight: .semibold))
                    .frame(width: 40)
                icons(["wifi", "battery.75percent"], width: 64, hidden: false)
                Text("9:41").font(.system(size: 12, weight: .medium)).frame(width: 40)
            }
            .frame(height: 26)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))

            HStack(spacing: 0) {
                if alwaysHidden {
                    caption("永久隐藏区", width: 80)
                }
                caption("隐藏区", width: 100)
                caption("分隔线", width: 36)
                caption("切换按钮", width: 40)
                caption("显示区", width: 104)
            }
            .padding(.horizontal, 8)
        }
    }

    private func icons(_ names: [String], width: CGFloat, hidden: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach(names, id: \.self) { Image(systemName: $0).font(.system(size: 12)) }
        }
        .frame(width: width, height: 22)
        .opacity(hidden ? 0.45 : 1)
        .overlay {
            if hidden {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.primary).frame(width: 1.5, height: 15)
    }

    private var dashedDivider: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Color.primary).frame(width: 1.5, height: 3.5) }
        }
    }

    private func caption(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width)
    }
}
