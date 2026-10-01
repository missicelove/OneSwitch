import AppKit
import OneSwitchCore

/// Read-only views of the engine for the settings page (built on demand on the main actor).
struct ChannelRow: Identifiable, Equatable {
    var id: String
    var service: String
    var title: String
    var peerName: String
    var address: String
    var viaThunderbolt: Bool
    var linkKind: String
    var rtt: TimeInterval?
    var bytesIn: Int64
    var bytesOut: Int64
    var initiatedLocally: Bool
    var since: Date?
}

struct ServiceRow: Identifiable, Equatable {
    var id: String
    var title: String
    var state: String
    var connected: Bool
}

extension PeerLinkModule {
    static func serviceTitle(_ service: String) -> String {
        switch service {
        case "sync": return "文件同步"
        case "input": return "键鼠共享"
        case LinkEngine.controlService: return "控制通道"
        default: return service
        }
    }

    func channelRows() -> [ChannelRow] {
        guard let engine else { return [] }
        return engine.establishedChannels.map { ch in
            let peer = ch.peer
            let stats = ch.stats
            return ChannelRow(id: ch.channelID, service: ch.service, title: Self.serviceTitle(ch.service),
                              peerName: peer.name, address: peer.address ?? "—", viaThunderbolt: peer.viaThunderbolt,
                              linkKind: ch.linkKind, rtt: stats.smoothedRTT, bytesIn: stats.bytesIn,
                              bytesOut: stats.bytesOut, initiatedLocally: ch.initiatedLocally, since: stats.establishedAt)
        }
    }

    func serviceRows(now: Date = Date()) -> [ServiceRow] {
        guard let engine else { return [] }
        return engine.serviceStates().map { s in
            let text: String
            if let ch = s.established {
                text = "已连接（由\(ch.initiatedLocally ? "本机" : "对方")发起）"
            } else if s.outgoing != nil {
                text = "正在连接 \(s.lastTarget ?? "")…"
            } else if name(s.name, notOfferedBy: engine) {
                text = "对方未启用"
            } else if s.nextAttempt > now {
                let wait = Int(s.nextAttempt.timeIntervalSince(now).rounded(.up))
                text = "\(wait) 秒后重试" + (s.lastError.map { "（\($0)）" } ?? "")
            } else {
                text = "等待对方" + (s.lastError.map { "（\($0)）" } ?? "")
            }
            return ServiceRow(id: s.name, title: Self.serviceTitle(s.name), state: text, connected: s.established != nil)
        }
    }

    private func name(_ service: String, notOfferedBy engine: LinkEngine) -> Bool {
        guard service != LinkEngine.controlService, let peerServices = engine.peerServices else { return false }
        return !peerServices.contains(service)
    }

    var discoveredPeerNames: [String] {
        guard let engine else { return [] }
        return engine.discovered.values.sorted { $0.id < $1.id }.map { p in
            let ifaces = p.interfaces.map(\.name).joined(separator: ", ")
            return ifaces.isEmpty ? p.name : "\(p.name)（\(ifaces)）"
        }
    }

    /// Multi-line text for “拷贝诊断信息”.
    func diagnosticsText() -> String {
        var lines: [String] = []
        let s = store.value
        lines.append("OneSwitch \(AppEnvironment.appVersion) · 雷雳互联诊断 · \(Date())")
        lines.append("本机：\(localDeviceName)（\(localDeviceID)）")
        lines.append("状态：\(status.displayText)")
        lines.append("配对码：\(Passcode.normalize(s.passcode).isEmpty ? "未设置" : "已设置（\(Passcode.normalize(s.passcode).count) 位）")")
        lines.append("网络接口：\(s.interfacePolicy.title) · 端口 \(s.port)")
        if let engine {
            lines.append("监听端口：\(engine.listenerPort.map(String.init) ?? "未监听")\(engine.listenerError.map { " · \($0)" } ?? "")")
            lines.append("Bonjour：\(engine.browserState)")
            lines.append("直连地址：\(engine.config.directPeers.map(\.description).joined(separator: ", ").nilIfEmpty ?? "无")")
            lines.append("已发现：\(discoveredPeerNames.joined(separator: "；").nilIfEmpty ?? "无")")
            if let ps = engine.peerServices { lines.append("对方已启用：\(ps.sorted().map(Self.serviceTitle).joined(separator: "、"))") }
            for row in serviceRows() { lines.append("服务 \(row.title)：\(row.state)") }
            for row in channelRows() {
                let rtt = row.rtt.map(Self.formatRTT) ?? "—"
                lines.append("通道 \(row.title)：\(row.peerName) \(row.address) \(row.linkKind) 延迟 \(rtt) ↑\(Fmt.bytes(row.bytesOut)) ↓\(Fmt.bytes(row.bytesIn))")
            }
        } else {
            lines.append("连接引擎：未运行")
        }
        if configuration.manageThunderboltBridge {
            let b = bridge.state
            lines.append("雷雳网桥：服务 \(b.serviceName ?? "未找到") · 设备 \(b.device) · 线缆 \(b.linkActive.map { $0 ? "已连接" : "未连接" } ?? "未知")")
            lines.append("网桥地址：\(b.addresses.joined(separator: ", ").nilIfEmpty ?? "无") · 配置 \(b.config.map { "\($0.method.displayName) \($0.ipAddress ?? "")" } ?? "未知")")
            lines.append("静态 IP：\(s.staticIPEnabled ? "开启" : "关闭") \(s.staticIP)/\(s.staticMask)\(s.staticIPPromptDeclined ? "（用户已取消授权）" : "")")
        }
        if let engine, !engine.recentEvents.isEmpty {
            lines.append("最近事件：")
            lines.append(contentsOf: engine.recentEvents.suffix(40))
        }
        return lines.joined(separator: "\n")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
