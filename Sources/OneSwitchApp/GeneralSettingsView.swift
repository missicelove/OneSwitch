import AppKit
import SwiftUI
import OneSwitchCore

struct GeneralSettingsView: View {
    @ViewState private var launchAtLogin = false
    @ViewState private var launchStatus = ""
    @ViewState private var launchNeedsApproval = false
    @AppStorage(GeneralSettings.verboseLoggingKey, store: AppEnvironment.defaults) private var verboseLogging = false
    @ViewState private var logLines: [String] = []

    var body: some View {
        SettingsPage("通用", subtitle: "OneSwitch 常驻菜单栏：防止锁屏 · 菜单栏图标 · 系统监控 · 雷雳互联 · 文件同步 · 键鼠共享") {
            Section {
                Toggle(isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开机自动启动")
                        Text(launchStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!LaunchAtLogin.isSupported)
                if launchNeedsApproval {
                    LabeledContent("需要在系统设置中允许") {
                        Button("打开“登录项”设置…") { LaunchAtLogin.openSystemSettings() }
                    }
                }
            } header: {
                Text("启动")
            }

            Section {
                PermissionRow(.accessibility, reason: "键鼠共享（控制另一台 Mac 的输入）、菜单栏图标整理需要")
                PermissionRow(.inputMonitoring, reason: "键鼠共享：捕获本机键盘鼠标并发送到另一台 Mac")
            } header: {
                Text("系统权限")
            } footer: {
                SettingsFooter("本地网络：雷雳互联第一次连接另一台 Mac 时系统会询问，请选择“允许”。如果之前拒绝了，请到“系统设置 → 隐私与安全性 → 本地网络”中打开 OneSwitch。\n"
                    + "管理员密码：雷雳互联配置雷雳网桥静态 IP 时会弹出系统密码框（只需一次）。\n"
                    + "用 scripts/setup-signing.sh 创建的固定签名安装后，更新版本不会丢失权限；若权限显示已授权但功能不工作，请在系统设置的列表中删除 OneSwitch 后重新添加。")
            }

            Section {
                Toggle(isOn: $verboseLogging) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("详细日志")
                        Text("记录调试信息，排查问题时再打开").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onChange(of: verboseLogging) { _, newValue in AppLog.debugEnabled = newValue }
                ScrollView {
                    Text(logLines.isEmpty ? "（暂无日志）" : logLines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 160)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    Text((AppLog.logFileURL.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("刷新") { logLines = AppLog.recentLines(limit: 200) }
                    Button("在访达中显示") {
                        AppLog.flush()
                        NSWorkspace.shared.activateFileViewerSelecting([AppLog.logFileURL])
                    }
                }
            } header: {
                Text("日志")
            }

            Section {
                appRow
                LabeledContent("本机", value: "\(AppEnvironment.computerName)（\(AppEnvironment.hardwareModel)）")
                if let profile = AppEnvironment.profile {
                    LabeledContent("配置档", value: profile)
                }
                LabeledContent("数据目录") {
                    Text((AppEnvironment.dataDirectory.path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                }
                HStack {
                    Text("退出后，防止锁屏、文件同步和键鼠共享都会停止。")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("退出 OneSwitch") { NSApp.terminate(nil) }
                }
            } header: {
                Text("关于")
            }
        }
        .onAppear {
            refreshLaunchState()
            logLines = AppLog.recentLines(limit: 200)
        }
        // The user may have approved / removed the login item in System Settings meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLaunchState()
        }
    }

    /// App icon, name and version (like the first row of System Settings' 关于本机).
    private var appRow: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("OneSwitch").font(.headline)
                Text("版本 \(AppEnvironment.appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.setEnabled(enabled)
        if enabled && LaunchAtLogin.requiresApproval { LaunchAtLogin.openSystemSettings() }
        refreshLaunchState()
    }

    private func refreshLaunchState() {
        launchAtLogin = LaunchAtLogin.isEnabled
        launchStatus = LaunchAtLogin.statusDescription
        launchNeedsApproval = LaunchAtLogin.requiresApproval
    }
}
