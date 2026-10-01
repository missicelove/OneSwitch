import SwiftUI
import OneSwitchCore

/// How each settings pane presents itself — sidebar icon tile, hero card description and the search
/// keywords (section titles and key terms of the page) — keyed by module id. The shell owns this so the
/// whole window stays consistent without module pages knowing about it.
struct SettingsPaneStyle {
    let symbol: String
    let color: Color
    let summary: String
    let keywords: [String]
}

enum SettingsCatalog {
    static let generalID = "general"

    /// Sidebar groups, separated by a gap as in System Settings: 通用 · features of this Mac ·
    /// features that join the two Macs. Unknown pane ids are appended as a last group.
    static let groups: [[String]] = [
        [generalID],
        ["awake", "menubar", "monitor"],
        ["peerlink", "sync", "input"],
    ]

    static func style(for id: String) -> SettingsPaneStyle? {
        switch id {
        case generalID:
            return SettingsPaneStyle(
                symbol: "gearshape.fill", color: .gray,
                summary: "管理 OneSwitch 的开机启动、系统权限和日志，并查看版本信息。",
                keywords: ["启动", "开机自动启动", "登录项", "系统权限", "辅助功能", "输入监控", "本地网络",
                           "管理员密码", "日志", "详细日志", "关于", "版本", "数据目录", "退出"])
        case "awake":
            return SettingsPaneStyle(
                symbol: "sun.max.fill", color: .orange,
                summary: "让屏幕保持常亮、不自动锁屏或睡眠，还可以在工作日按时段自动开启。",
                keywords: ["当前状态", "手动开启", "时长", "自动计划", "工作日", "节假日", "节假日日历",
                           "手动指定日期", "未来 7 天", "菜单栏图标", "选项", "模拟用户活动", "快捷键",
                           "锁屏", "屏幕保护程序", "睡眠"])
        case "menubar":
            return SettingsPaneStyle(
                symbol: "menubar.rectangle", color: .blue,
                summary: "把不常用的菜单栏图标收起来，需要时点一下即可显示。",
                keywords: ["状态", "基本", "隐藏延迟", "外观", "分隔线", "快捷键", "使用方法",
                           "要隐藏的 App", "菜单栏图标列表"])
        case "monitor":
            return SettingsPaneStyle(
                symbol: "gauge.with.dots.needle.67percent", color: .green,
                summary: "在菜单栏实时显示 CPU、GPU、内存、网络、磁盘、功率和温度。",
                keywords: ["菜单栏显示", "CPU", "GPU", "内存", "网络", "磁盘", "功率", "温度",
                           "合并为一个图标", "外观", "显示样式", "高负载颜色提醒", "采样", "刷新间隔",
                           "网络接口", "温度与功率"])
        case "peerlink":
            return SettingsPaneStyle(
                symbol: "bolt.fill", color: .purple,
                summary: "通过雷雳线连接另一台 Mac，为文件同步和键鼠共享提供加密通道。",
                keywords: ["状态", "重新连接", "配对码", "本机", "端口", "网络", "雷雳网桥", "Thunderbolt",
                           "静态 IP", "通道", "延迟", "诊断"])
        case "sync":
            return SettingsPaneStyle(
                symbol: "arrow.triangle.2.circlepath", color: .teal,
                summary: "通过雷雳线在两台 Mac 之间实时同步文件夹。",
                keywords: ["启用文件同步", "同步文件夹", "添加文件夹", "暂停", "共享邀请", "最近活动",
                           "冲突文件", "忽略规则"])
        case "input":
            return SettingsPaneStyle(
                symbol: "keyboard.fill", color: .indigo,
                summary: "两台 Mac 共用一套键盘鼠标，把鼠标移过屏幕边缘即可控制另一台 Mac。",
                keywords: ["状态", "启用键鼠共享", "本机角色", "服务端", "客户端", "屏幕布局", "切换方式",
                           "边缘停留时间", "快捷键", "剪贴板", "权限", "隐私说明", "诊断", "键盘", "鼠标"])
        default:
            return nil
        }
    }

    /// Orders panes into the sidebar groups (see `groups`); panes with unknown ids form a final group.
    static func grouped(_ panes: [SettingsPaneItem]) -> [[SettingsPaneItem]] {
        var remaining = panes
        var result: [[SettingsPaneItem]] = []
        for group in groups {
            let members = group.compactMap { id in remaining.first { $0.id == id } }
            remaining.removeAll { pane in members.contains { $0.id == pane.id } }
            if !members.isEmpty { result.append(members) }
        }
        if !remaining.isEmpty { result.append(remaining) }
        return result
    }
}

extension SettingsCatalog {
    /// A settings page, styled from the catalog (falling back to the module's own symbol for unknown ids).
    @MainActor
    static func pane(id: String, title: String, fallbackSymbol: String, view: AnyView) -> SettingsPaneItem {
        let style = style(for: id)
        return SettingsPaneItem(
            id: id,
            title: title,
            appearance: SettingsPaneAppearance(symbol: style?.symbol ?? fallbackSymbol,
                                               color: style?.color ?? .gray,
                                               summary: style?.summary),
            keywords: style?.keywords ?? [],
            view: view)
    }
}
