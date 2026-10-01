import AppKit
import SwiftUI
import OneSwitchCore

/// Settings page of 文件同步.
struct FolderSyncSettingsView: View {
    @ObservedObject var model: FolderSyncModule
    @ObservedObject var settings: SettingsStore<FolderSyncSettings>

    @ViewState private var editing: FolderConfig?
    @ViewState private var removing: FolderConfig?
    @ViewState private var markerFolder: FolderStatus?

    var body: some View {
        SettingsPage("文件同步", subtitle: "通过雷雳线在两台 Mac 之间实时同步文件夹，类似 Syncthing") {
            Section {
                Toggle("启用文件同步", isOn: Binding(get: { settings.value.enabled }, set: { model.setEnabled($0) }))
                LabeledContent("另一台 Mac") {
                    StatusBadge(model.peerStatus.displayText, tone: peerTone)
                }
                LabeledContent("状态") {
                    Text(model.overallLine).foregroundStyle(.secondary)
                }
            }

            Section {
                if model.displayedFolders.isEmpty {
                    Text("还没有同步文件夹。添加后，另一台 Mac 会收到共享邀请，接受后即开始同步。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.displayedFolders) { folder in
                    FolderRow(folder: folder, model: model,
                              onEdit: { editing = config(for: folder.id) },
                              onRemove: { removing = config(for: folder.id) },
                              onRecreateMarker: { markerFolder = folder })
                }
                HStack {
                    Button {
                        model.addFolderInteractively()
                    } label: {
                        Label("添加文件夹…", systemImage: "plus")
                    }
                    Spacer()
                    if !settings.value.folders.isEmpty {
                        Button(settings.value.pausedAll ? "继续全部同步" : "暂停全部同步") {
                            model.setPausedAll(!settings.value.pausedAll)
                        }
                    }
                }
                .disabled(!settings.value.enabled)
            } header: {
                Text("同步文件夹")
            } footer: {
                Text("移除文件夹只会停止同步，不会删除任何文件。每个同步文件夹根目录下有一个 .oneswitch 标记目录；外接磁盘未连接或文件夹被移动时同步会自动停止，不会把“文件不见了”误当成删除。")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !model.snapshot.offers.isEmpty {
                Section("共享邀请") {
                    ForEach(model.snapshot.offers) { offer in
                        HStack {
                            Image(systemName: "folder.badge.plus").foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("对方共享了文件夹「\(offer.label)」")
                                Text("来自 \(offer.peerName)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("忽略") { model.ignoreOffer(offer.id) }
                            Button("接受…") { model.acceptOffer(offer) }.buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            Section("最近活动") {
                let recent = recentChanges
                if recent.isEmpty {
                    Text("暂无").foregroundStyle(.secondary)
                } else {
                    ForEach(recent) { change in
                        RecentChangeRow(change: change, folderLabel: label(for: change.folderID))
                    }
                }
            }

            Section("冲突文件") {
                let conflicts = model.displayedFolders.flatMap(\.conflicts).sorted { $0.time > $1.time }
                if conflicts.isEmpty {
                    Text("没有冲突").foregroundStyle(.secondary)
                } else {
                    ForEach(conflicts.prefix(30)) { conflict in
                        ConflictRow(conflict: conflict, folderLabel: label(for: conflict.folderID)) { model.reveal(conflict) }
                    }
                    Text("两台 Mac 同时修改了同一文件时，较新的修改保留原名，另一份另存为 “.sync-conflict-日期-设备名” 副本。确认后可手动删除副本。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $editing) { config in
            FolderEditor(config: config) { updated in
                model.saveFolder(updated)
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .alert("移除同步文件夹？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
               presenting: removing) { config in
            Button("移除", role: .destructive) { model.removeFolder(config.id) }
            Button("取消", role: .cancel) {}
        } message: { config in
            Text("「\(config.label)」将停止同步。本机和另一台 Mac 上的文件都会保留。")
        }
        .alert("重新创建标记？", isPresented: Binding(get: { markerFolder != nil }, set: { if !$0 { markerFolder = nil } }),
               presenting: markerFolder) { folder in
            Button("重新创建并扫描", role: .destructive) { model.recreateMarker(folder.id) }
            Button("取消", role: .cancel) {}
        } message: { folder in
            Text("请确认「\(folder.path)」就是原来的同步文件夹。重新创建标记后，这里缺少的文件会被当作已删除，并同步到另一台 Mac。")
        }
    }

    private var peerTone: StatusBadge.Tone {
        switch model.peerStatus {
        case .connected: return .ok
        case .searching: return .busy
        case .disabled: return .idle
        case .error: return .error
        }
    }

    private var recentChanges: [RecentChange] {
        Array(model.displayedFolders.flatMap(\.recent).sorted { $0.time > $1.time }.prefix(30))
    }

    private func config(for id: String) -> FolderConfig? {
        settings.value.folders.first { $0.id == id }
    }

    private func label(for folderID: String) -> String {
        settings.value.folders.first { $0.id == folderID }?.label ?? folderID
    }
}

private struct FolderRow: View {
    let folder: FolderStatus
    @ObservedObject var model: FolderSyncModule
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onRecreateMarker: () -> Void

    @ViewState private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
                Text(folder.label).font(.headline)
                Spacer()
                StatusBadge(folder.state.displayText, tone: folder.state.tone)
            }
            Text((folder.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(folder.path)
            HStack(spacing: 12) {
                Text("\(folder.fileCount) 个文件 · \(Fmt.bytes(folder.totalBytes))")
                if folder.needItems > 0 {
                    Text("待同步 \(folder.needItems) 项 · \(Fmt.bytes(folder.needBytes))")
                }
                if folder.rate > 0 && folder.needItems > 0 {
                    Text("↓ \(Fmt.rate(folder.rate))")
                }
                if let last = folder.lastSyncAt {
                    Text("上次同步：\(FolderSyncModule.relative(last))")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if folder.state == .waitingForShare {
                Text("已向另一台 Mac 发出共享邀请，对方接受后开始同步。").font(.caption).foregroundStyle(.secondary)
            }
            if folder.peerPaused {
                Text("另一台 Mac 已暂停同步此文件夹。").font(.caption).foregroundStyle(.orange)
            }
            ForEach(folder.issues.prefix(5), id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if folder.issues.count > 5 {
                Text("另有 \(folder.issues.count - 5) 个问题").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("打开") { model.openFolder(folder.id) }
                Button("立即扫描") { model.rescan(folder.id) }
                    .disabled(folder.paused)
                Button(folder.paused ? "继续" : "暂停") { model.setFolderPaused(folder.id, !folder.paused) }
                if case .error(let message) = folder.state, message == SyncEngine.missingRootMessage {
                    Button("重新创建标记…", action: onRecreateMarker)
                        .help("仅在确认文件夹位置正确、只是缺少 .oneswitch 标记时使用")
                }
                Spacer()
                Button("编辑…", action: onEdit)
                Button("移除…", role: .destructive, action: onRemove)
            }
            .controlSize(.small)
            if !folder.recent.isEmpty || !folder.conflicts.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(folder.conflicts.prefix(10)) { conflict in
                            ConflictRow(conflict: conflict, folderLabel: nil) { model.reveal(conflict) }
                        }
                        ForEach(folder.recent) { change in
                            RecentChangeRow(change: change, folderLabel: nil)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(folder.conflicts.isEmpty ? "最近更改（\(folder.recent.count)）"
                         : "最近更改（\(folder.recent.count)）· 冲突（\(folder.conflicts.count)）")
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RecentChangeRow: View {
    let change: RecentChange
    let folderLabel: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(change.arrow)
                .foregroundStyle(change.incoming ? .blue : .green)
                .help(change.incoming ? "来自另一台 Mac" : "本机的更改")
            Text(change.action.title).foregroundStyle(change.action == .deleted ? .red : .secondary)
            Text(change.path).lineLimit(1).truncationMode(.middle).help(change.path)
            Spacer()
            if let folderLabel { Text(folderLabel).foregroundStyle(.secondary) }
            Text(FolderSyncModule.clockTime(change.time)).foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
    }
}

private struct ConflictRow: View {
    let conflict: ConflictInfo
    let folderLabel: String?
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.2").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(conflict.originalPath).lineLimit(1).truncationMode(.middle)
                Text("副本：\(SyncPath.name(conflict.conflictPath))")
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let folderLabel { Text(folderLabel).foregroundStyle(.secondary) }
            Text(FolderSyncModule.clockTime(conflict.time)).foregroundStyle(.secondary)
            Button("在访达中显示", action: onReveal).controlSize(.small)
        }
        .font(.caption)
    }
}

private struct FolderEditor: View {
    let original: FolderConfig
    let onSave: (FolderConfig) -> Void
    let onCancel: () -> Void

    @ViewState private var label: String
    @ViewState private var patterns: String
    @ViewState private var versioning: VersioningMode

    init(config: FolderConfig, onSave: @escaping (FolderConfig) -> Void, onCancel: @escaping () -> Void) {
        self.original = config
        self.onSave = onSave
        self.onCancel = onCancel
        _label = ViewState(initialValue: config.label)
        _patterns = ViewState(initialValue: config.ignorePatterns.joined(separator: "\n"))
        _versioning = ViewState(initialValue: config.versioning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑同步文件夹").font(.title3.bold())
            Form {
                TextField("名称", text: $label)
                LabeledContent("位置") {
                    Text(original.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                LabeledContent("文件夹 ID") {
                    Text(original.id).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Picker("被覆盖或删除的文件", selection: $versioning) {
                    ForEach(VersioningMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("忽略规则（每行一条）")
                    TextEditor(text: $patterns)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    Text("支持通配符：*.log 忽略所有 .log 文件；node_modules 忽略所有同名文件夹；/build 只忽略根目录下的 build；以 # 开头的行是注释。系统文件（.DS_Store、._*、.Spotlight-V100、.Trashes 等）始终忽略。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("保存") {
                    var updated = original
                    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.label = trimmed.isEmpty ? original.label : trimmed
                    updated.ignorePatterns = IgnoreMatcher.parse(patterns)
                    updated.versioning = versioning
                    onSave(updated)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
