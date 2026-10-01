import AppKit
import SwiftUI
import OneSwitchCore

/// 系统原生隐藏: the apps that have menu-bar icons, each with its rule (自动 / 始终隐藏 / 始终显示).
struct NativeAppListSection: View {
    @ObservedObject var controller: MenuBarHiderController
    @ObservedObject var store: SettingsStore<MenuBarHiderSettings>

    var body: some View {
        Section {
            // Re-evaluated whenever the page refreshes; PermissionRow itself re-checks every 2 s.
            if !Permissions.isGranted(.accessibility) {
                PermissionRow(.accessibility, reason: "读取各 App 菜单栏图标的位置（在「<」左侧还是右侧）")
            }
            Label("隐藏以 App 为单位；系统自带图标（时钟、Wi‑Fi、控制中心等）始终显示。", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("刷新列表") { controller.refreshNativeApps() }
                    .disabled(controller.nativeListBusy || !controller.isActive)
                if controller.nativeListBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let date = controller.nativeLastScan {
                    Text("更新于 " + Self.timeFormatter.string(from: date))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            let rows = controller.nativeAppRows(rules: store.value.appRules)
            if rows.isEmpty {
                Text(controller.nativeLastScan == nil
                     ? "图标第一次隐藏时会读取列表，也可以点击“刷新列表”（会临时显示全部图标）"
                     : "没有找到其他 App 的菜单栏图标")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row($0) }
            }
        } header: {
            Text("要隐藏的 App")
        } footer: {
            Text("自动：按位置决定——「<」左侧的图标收起时隐藏，右侧的保持显示（按住 ⌘ 拖动图标可调整位置）。收起期间新打开的 App，其图标会先被隐藏（设为“始终显示”或上次位于「<」右侧的除外），点一下「<」就能看到。刷新列表时会临时显示全部图标。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!store.value.enabled)
    }

    private func row(_ row: NativeAppRow) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = row.icon {
                    Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.dashed").resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.name).lineLimit(1)
                    if row.isSystem {
                        Text("系统")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text(subtitle(row))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let bundle = row.bundleID {
                chip(row.hides ? "收起时隐藏" : "收起时显示", color: row.hides ? .blue : .green)
                Picker("", selection: ruleBinding(bundle)) {
                    ForEach(AppVisibilityRule.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 104)
            } else {
                chip("无法单独设置", color: .secondary)
                    .help("这个程序没有 Bundle ID：OneSwitch 不会主动隐藏它，但系统原生隐藏只能按 Bundle ID 放行 App，收起时它的图标可能也会被隐藏")
                Color.clear.frame(width: 104, height: 1)
            }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func subtitle(_ row: NativeAppRow) -> String {
        let place = row.placement?.title ?? "未在菜单栏中"
        return [place, row.detail].compactMap { $0 }.joined(separator: " · ")
    }

    private func ruleBinding(_ bundleID: String) -> Binding<AppVisibilityRule> {
        Binding(
            get: { store.value.rule(for: bundleID) },
            set: { newValue in
                guard store.value.rule(for: bundleID) != newValue else { return }
                store.update { $0.setRule(newValue, for: bundleID) }
            })
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// 系统原生隐藏 illustration: collapsed (only「<」+ system icons) vs. shown.
struct NativeMenuBarDiagram: View {
    let toggleStyle: ToggleIconStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bar(caption: "收起", hiddenIcons: [], expanded: false)
            bar(caption: "展开", hiddenIcons: ["cloud.fill", "music.note", "gamecontroller.fill"], expanded: true)
        }
    }

    private func bar(caption: String, hiddenIcons: [String], expanded: Bool) -> some View {
        HStack(spacing: 8) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                ForEach(hiddenIcons, id: \.self) { Image(systemName: $0).font(.system(size: 12)) }
                toggle(expanded: expanded)
                Image(systemName: "wifi").font(.system(size: 12))
                Image(systemName: "battery.75percent").font(.system(size: 12))
                Text("9:41").font(.system(size: 12, weight: .medium))
            }
            .frame(width: 250, height: 24)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
        }
    }

    @ViewBuilder
    private func toggle(expanded: Bool) -> some View {
        switch toggleStyle {
        case .chevron:
            Image(systemName: expanded ? "chevron.right" : "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        case .dot:
            Image(systemName: expanded ? "circle" : "circle.fill")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
    }
}
