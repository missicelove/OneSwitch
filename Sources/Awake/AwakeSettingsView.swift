import AppKit
import SwiftUI
import OneSwitchCore

/// Settings page of 防止锁屏.
struct AwakeSettingsView: View {
    @ObservedObject var controller: AwakeController
    @ObservedObject var store: SettingsStore<AwakeSettings>
    @ObservedObject var holidays: HolidayStore

    /// Wall-clock used for countdowns; ticks at 1 Hz only while the page is on screen.
    @ViewState private var now = Date()
    @ViewState private var appeared = false
    @ViewState private var windowVisible = false

    @ViewState private var draftStart = Date()
    @ViewState private var draftEnd = Date()
    @ViewState private var windowError: String?

    @ViewState private var overrideDate = Date()
    @ViewState private var overrideIsWorkday = true

    private var settings: AwakeSettings { store.value }
    private var status: AwakeStatus { controller.status }
    private var calendar: Calendar { controller.calendar }

    var body: some View {
        SettingsPage("防止锁屏", subtitle: "保持屏幕常亮，阻止屏幕保护程序、自动锁屏与闲置睡眠；可在工作日按时段自动开启") {
            statusSection
            manualSection
            scheduleSection
            holidaySection
            overridesSection
            previewSection
            statusIconSection
            optionsSection
        }
        // DatePickers must interpret dates in the same Gregorian calendar / time zone that the
        // schedule uses (the user's preferred calendar could be e.g. the Chinese lunar calendar).
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .background(WindowVisibilityReader { windowVisible = $0 })
        .onAppear {
            appeared = true
            now = controller.now
            syncWindowDrafts()
        }
        .onDisappear { appeared = false }
        .task(id: appeared && windowVisible) {
            guard appeared && windowVisible else { return }
            while !Task.isCancelled {
                await MainActor.run { now = controller.now }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .onChange(of: settings.startMinute) { _, _ in syncWindowDrafts() }
        .onChange(of: settings.endMinute) { _, _ in syncWindowDrafts() }
    }

    private func footerText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 当前状态

    private var statusSection: some View {
        Section("当前状态") {
            HStack(spacing: 12) {
                StatusBadge(status.isActive ? "已开启" : "已关闭", tone: status.isActive ? .ok : .idle)
                    .font(.headline)
                Spacer()
                if status.isActive {
                    Button("关闭") { controller.turnOff() }
                } else {
                    Button("立即开启（无限期）") { controller.startSession(minutes: nil) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            Text(AwakeText.statusDetail(status, settings: settings, now: now, calendar: calendar))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("今天", value: AwakeText.dayType(status.today))
        }
    }

    // MARK: 手动开启

    private var manualSection: some View {
        Section {
            Picker("时长", selection: $store.value.manualChoice) {
                ForEach(AwakeLimits.presetMinutes, id: \.self) { minutes in
                    Text(Fmt.minutes(minutes)).tag(minutes)
                }
                Divider()
                Text("无限期（直到手动关闭）").tag(AwakeLimits.choiceInfinite)
                Text("自定义").tag(AwakeLimits.choiceCustom)
            }
            if settings.manualChoice == AwakeLimits.choiceCustom {
                LabeledContent("自定义时长") {
                    HStack(spacing: 8) {
                        Slider(value: customMinutesBinding,
                               in: Double(AwakeLimits.minSessionMinutes)...Double(AwakeLimits.maxSessionMinutes))
                            // No `step:` (it would draw 143 tick marks); the binding snaps to 5-minute steps.
                            .labelsHidden()
                            .frame(minWidth: 180, maxWidth: 280)
                        Text(Fmt.minutes(settings.customMinutes))
                            .monospacedDigit()
                            .frame(width: 96, alignment: .trailing)
                        Stepper("自定义时长", value: $store.value.customMinutes,
                                in: AwakeLimits.minSessionMinutes...AwakeLimits.maxSessionMinutes,
                                step: AwakeLimits.sessionStepMinutes)
                            .labelsHidden()
                    }
                }
            }
            HStack {
                if let session = status.session {
                    Text(session.isInfinite ? "正在运行：无限期" : "正在运行：\(AwakeText.durationLabel(session.minutes))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("停止") { controller.turnOff() }
                    .disabled(status.session == nil)
                Button("开始") { controller.startSession(minutes: settings.selectedDurationMinutes) }
            }
        } header: {
            Text("手动开启")
        } footer: {
            footerText("手动开启的时段结束前会一直保持，即使超出自动计划的时段。")
        }
    }

    private var customMinutesBinding: Binding<Double> {
        Binding(
            get: { Double(store.value.customMinutes) },
            set: { store.value.customMinutes = AwakeLimits.clampSession(Int($0.rounded())) }
        )
    }

    // MARK: 自动计划

    private var scheduleSection: some View {
        Section {
            Toggle("启用自动计划（工作日按时段自动开启）", isOn: $store.value.scheduleEnabled)
            LabeledContent("每周工作日") {
                HStack(spacing: 4) {
                    ForEach(AwakeText.weekdayOrder, id: \.self) { weekday in
                        Toggle(AwakeText.weekdayName(weekday), isOn: weekdayBinding(weekday))
                            .toggleStyle(.button)
                    }
                }
            }
            .disabled(!settings.scheduleEnabled)
            Group {
                DatePicker("开始时间", selection: $draftStart, displayedComponents: .hourAndMinute)
                    .onChange(of: draftStart) { _, _ in commitWindow() }
                DatePicker("结束时间", selection: $draftEnd, displayedComponents: .hourAndMinute)
                    .onChange(of: draftEnd) { _, _ in commitWindow() }
            }
            .disabled(!settings.scheduleEnabled)
            // Wall-clock times only: edit them on a fixed UTC day so that a DST gap / repeat on the
            // current day can never shift (and silently save) the window.
            .environment(\.calendar, Self.timePickerCalendar)
            .environment(\.timeZone, Self.timePickerCalendar.timeZone)
            if let windowError {
                Label(windowError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("自动计划")
        } footer: {
            footerText("工作日判定优先级：手动指定日期 > 节假日日历 > 每周工作日设置。在计划时段内手动关闭后，直到下一次计划切换前都不会自动重新开启。")
        }
    }

    private func weekdayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { store.value.workWeekdays.contains(weekday) },
            set: { on in
                store.update { s in
                    var set = Set(s.workWeekdays)
                    if on { set.insert(weekday) } else { set.remove(weekday) }
                    s.workWeekdays = set.sorted()
                }
            }
        )
    }

    /// Calendar of the start / end time pickers: UTC has no DST, so every minute of the day exists
    /// exactly once (in the local zone, 02:30 does not exist on the spring-forward day; it used to
    /// become 03:00 — which the picker's onChange then saved as the new window).
    static let timePickerCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "UTC")!
        return c
    }()

    private func dateFor(minute: Int) -> Date {
        AwakeTimeOfDay.date(minute: minute, calendar: Self.timePickerCalendar)
    }

    private func minuteOf(_ date: Date) -> Int {
        AwakeTimeOfDay.minute(of: date, calendar: Self.timePickerCalendar)
    }

    private func syncWindowDrafts() {
        let start = dateFor(minute: settings.startMinute)
        let end = dateFor(minute: settings.endMinute)
        if minuteOf(draftStart) != settings.startMinute { draftStart = start }
        if minuteOf(draftEnd) != min(settings.endMinute, 24 * 60 - 1) { draftEnd = end }
        windowError = settings.hasValidWindow ? nil : "结束时间必须晚于开始时间"
    }

    /// Applies the edited window only when valid (end > start); otherwise keeps the saved window.
    private func commitWindow() {
        let start = minuteOf(draftStart)
        // The picker cannot show 24:00: a stored 24:00 end is displayed as 23:59 and must stay 24:00.
        let end = AwakeTimeOfDay.committedEnd(pickerMinute: minuteOf(draftEnd), storedEnd: settings.endMinute)
        guard end > start else {
            windowError = "结束时间必须晚于开始时间，修改尚未生效（仍为 \(AwakeText.window(settings.startMinute, settings.endMinute))）"
            return
        }
        windowError = nil
        if start != settings.startMinute || end != settings.endMinute {
            store.update { s in
                s.startMinute = start
                s.endMinute = end
            }
        }
    }

    // MARK: 节假日日历

    private var holidaySection: some View {
        let effective = controller.effectiveHolidayRegion
        return Section {
            Picker("节假日日历", selection: $store.value.holidayRegion) {
                ForEach(HolidayRegion.allCases, id: \.self) { region in
                    Text(region.title).tag(region)
                }
            }
            if settings.holidayRegion == .automatic {
                LabeledContent("当前使用", value: "\(effective.shortName)（系统时区：\(calendar.timeZone.identifier)）")
            }
            switch effective {
            case .chinaMainland:
                chinaHolidayRows
            case .poland:
                polandHolidayRows
            case .automatic, .disabled:
                Text("仅按每周工作日与手动指定日期判定工作日。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("节假日日历")
        } footer: {
            footerText(AwakeText.holidayFooter(selected: settings.holidayRegion, effective: effective,
                                               timeZone: calendar.timeZone))
        }
    }

    @ViewBuilder
    private var chinaHolidayRows: some View {
        LabeledContent("已加载数据", value: holidays.summary(years: controller.holidayYears()))
        LabeledContent("上次更新") {
            Text(holidays.lastUpdated.map { AwakeText.moment($0, now: now, calendar: calendar) } ?? "从未更新")
        }
        if let error = holidays.lastError {
            Label("更新失败：\(error)\(holidays.data.years.isEmpty ? "" : "（正在使用本地缓存）")",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            if holidays.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button("立即更新") { controller.refreshHolidays() }
                .disabled(holidays.isRefreshing)
        }
    }

    @ViewBuilder
    private var polandHolidayRows: some View {
        LabeledContent("数据来源", value: "本机离线计算，无需联网")
        let upcoming = PolishHolidays.upcoming(from: DayKey(now, calendar: calendar), limit: 4)
        ForEach(upcoming, id: \.date) { holiday in
            LabeledContent(holidayDateTitle(holiday.date), value: holiday.displayName)
        }
    }

    /// "11月11日 周三" (with the year when it is not the current one).
    private func holidayDateTitle(_ key: DayKey) -> String {
        guard let date = key.startDate(in: calendar) else { return key.string }
        let title = AwakeText.dayTitle(date, calendar: calendar)
        return key.year == calendar.component(.year, from: now) ? title : "\(key.year)年\(title)"
    }

    // MARK: 手动指定日期

    private var overridesSection: some View {
        Section {
            HStack {
                DatePicker("日期", selection: $overrideDate, displayedComponents: .date)
                Picker("类型", selection: $overrideIsWorkday) {
                    Text("工作日").tag(true)
                    Text("休息日").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                Button("添加") { addOverride() }
            }
            let entries = sortedOverrides
            if entries.isEmpty {
                Text("暂无手动指定的日期")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.key) { entry in
                    HStack {
                        Text(overrideTitle(entry.key))
                        Spacer()
                        Text(entry.isWorkday ? "工作日" : "休息日")
                            .foregroundStyle(entry.isWorkday ? Color.primary : Color.secondary)
                        Button {
                            store.update { $0.dayOverrides[entry.key.string] = nil }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("删除")
                    }
                }
            }
        } header: {
            Text("手动指定日期")
        } footer: {
            footerText("手动指定的日期优先于节假日日历与每周设置，例如临时加班、请假或补休。30 天前的记录会自动清理。")
        }
    }

    private var sortedOverrides: [(key: DayKey, isWorkday: Bool)] {
        settings.dayOverrides.compactMap { k, v in DayKey(k).map { (key: $0, isWorkday: v) } }
            .sorted { $0.key < $1.key }
    }

    private func overrideTitle(_ key: DayKey) -> String {
        guard let date = key.startDate(in: calendar) else { return key.string }
        return "\(key.year)年\(AwakeText.dayTitle(date, calendar: calendar))"
    }

    private func addOverride() {
        let key = DayKey(overrideDate, calendar: calendar)
        store.update { $0.dayOverrides[key.string] = overrideIsWorkday }
    }

    // MARK: 未来 7 天

    private var previewSection: some View {
        Section("未来 7 天") {
            let days = controller.makePolicy().preview(from: now, days: 7)
            ForEach(days) { day in
                HStack {
                    Text(AwakeText.dayTitle(day.date, calendar: calendar))
                        .frame(minWidth: 96, alignment: .leading)
                    Text(AwakeText.dayType(day.info))
                        .foregroundStyle(day.info.isWorkday ? Color.primary : Color.secondary)
                    Spacer()
                    Text(previewWindowText(day))
                        .monospacedDigit()
                        .foregroundStyle(day.windowStart == nil ? Color.secondary : Color.primary)
                }
            }
        }
    }

    private func previewWindowText(_ day: DayPreview) -> String {
        guard day.windowStart != nil else {
            if !settings.scheduleEnabled { return "自动计划未启用" }
            if !settings.hasValidWindow { return "时段无效" }
            return "不自动开启"
        }
        return "自动开启 \(AwakeText.window(settings.startMinute, settings.endMinute))"
    }

    // MARK: 菜单栏图标

    private var statusIconSection: some View {
        Section {
            AwakeStatusIconPicker(selection: $store.value.statusIcon)
        } header: {
            Text("菜单栏图标")
        } footer: {
            footerText(AwakeText.statusIconFooter(settings.statusIcon))
        }
    }

    // MARK: 选项

    private var optionsSection: some View {
        Section("选项") {
            Toggle(isOn: $store.value.simulateUserActivity) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("模拟用户活动")
                    Text("每 50 秒向系统报告一次用户活动，确保屏幕保护程序和闲置锁屏不会启动。显示器已手动关闭、已锁屏或屏幕保护程序运行时自动暂停。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("定时结束时发送通知", isOn: $store.value.notifyOnEnd)
            LabeledContent("全局快捷键") {
                HotKeyRecorder(hotKey: $store.value.hotKey)
            }
            if let message = controller.hotKeyMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text("按下快捷键即可开启（无限期）或关闭防止锁屏。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Visual picker for 菜单栏图标: one tile per choice showing the symbol as it appears in the menu bar
/// (monochrome, template-like) with its name. A change applies at once (the controller refreshes the
/// status-bar icon when the setting changes).
struct AwakeStatusIconPicker: View {
    @Binding var selection: AwakeStatusIcon

    private let columns = Array(repeating: GridItem(.flexible(minimum: 56), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .center, spacing: 10) {
            ForEach(AwakeStatusIcon.pickerChoices) { icon in
                tile(icon)
            }
        }
        .padding(.vertical, 4)
    }

    private func tile(_ icon: AwakeStatusIcon) -> some View {
        let selected = icon == selection
        return Button {
            selection = icon
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon.previewSymbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(selected ? Color.white : (icon == .unchanged ? Color.secondary : Color.primary))
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? Color.accentColor : Color.primary.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? Color.clear : Color.primary.opacity(0.12), lineWidth: 1)
                    )
                Text(icon.title)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(icon == .unchanged ? "开启时保持 OneSwitch 原图标" : "开启时菜单栏显示“\(icon.title)”图标")
        .accessibilityLabel(icon.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Reports whether the hosting window is on screen (visible and not fully occluded / closed), so
/// the page's 1 Hz clock only runs while someone can see it.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityTrackingView {
        let view = VisibilityTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: VisibilityTrackingView, context: Context) {
        nsView.onChange = onChange
    }
}

final class VisibilityTrackingView: NSView {
    var onChange: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var lastReported: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        guard let window else {
            report(false)
            return
        }
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    self?.update(closing: note.name == NSWindow.willCloseNotification)
                }
            })
        }
        update(closing: false)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { removeObservers() }
        super.viewWillMove(toWindow: newWindow)
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func update(closing: Bool) {
        guard let window, !closing else {
            report(false)
            return
        }
        report(window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized)
    }

    private func report(_ visible: Bool) {
        guard visible != lastReported else { return }
        lastReported = visible
        // Deliver outside the current view update.
        let callback = onChange
        DispatchQueue.main.async { callback?(visible) }
    }
}
