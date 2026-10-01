# Awake — implementation spec

Class AwakeModule: FeatureModule, "public init()", id "awake", displayName "防止锁屏", symbolName "cup.and.saucer".

MECHANISM
- While active hold an IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep, level on, name "OneSwitch 防止锁屏"). This also prevents idle system sleep.
- Option "模拟用户活动" (default ON): every ~50 s call IOPMAssertionDeclareUserActivity(name, kIOPMUserActiveLocal, &id) reusing the returned id, so the screensaver / idle lock timers never fire even when the display-sleep assertion alone would not stop them. Stop when inactive.
- Release everything on deactivate and in stop(). Re-evaluate state after wake (NSWorkspace.didWakeNotification), on NSSystemClockDidChange, NSCalendarDayChanged, NSSystemTimeZoneDidChange.
- Verify in the check with "pmset -g assertions" that the named assertion appears while active and disappears after release (brief probe, then release).

MANUAL SESSIONS
- Durations 5 min … 12 h. Presets: 5, 10, 15, 30 min, 1, 2, 3, 4, 6, 8, 12 h, plus "无限期" (until turned off), plus a custom duration in settings (slider/stepper 5…720 min, step 5).
- A timed session ends automatically (optional notification "防止锁屏已结束", default ON, via AppContext.shared.notify).

AUTOMATIC SCHEDULE (自动计划) — default ENABLED with: workdays active 08:00–19:00, non-workdays off.
- Workday definition precedence: manual date overrides (user list: date → 工作日/休息日) > Chinese statutory holiday data > weekday setting (default Mon–Fri, user-configurable weekdays).
- Chinese holidays & 调休 (make-up workdays): option "使用中国法定节假日与调休安排" default ON. Data: holiday-cn JSON, format {"year":2026,"days":[{"name":"国庆节","date":"2026-10-01","isOffDay":true},...]} — isOffDay true = holiday (non-workday), false = 调休补班 (workday even on a weekend). Try URLs in order: https://fastly.jsdelivr.net/gh/NateScarlet/holiday-cn@master/{year}.json, https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/{year}.json, https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/{year}.json. Fetch current + next year with URLSession off the main thread, cache as JSON in AppContext.shared.dataDirectory (awake-holidays-{year}.json), refresh at most daily and at launch, work offline from cache, never block. Verify the real format by fetching once with curl while developing. Show last-update time / errors in settings with a "立即更新" button.
- Window: start/end minute-of-day (defaults 480 and 1140); require end > start (validate in UI).
- Semantics (pure, testable policy type with injected Date/Calendar/holiday data): active = manualSessionActive || (scheduleDesired && !suppressed). scheduleDesired = scheduleEnabled && isWorkday(date) && start <= minuteOfDay < end. Manual "关闭" while scheduleDesired sets suppressed = true (stays off until the next scheduleDesired transition). Manual start (timed or infinite) clears suppression. Any change of scheduleDesired clears suppression. A manual session keeps running past the end of the window until its own expiry. Provide nextTransition(after:) to show e.g. "已关闭 · 计划将于 周一 08:00 开启" or "按计划开启 · 至 19:00".
- Timing: one-shot timer at the next deadline (session end or next schedule transition) plus a 30 s safety re-evaluation timer (common run-loop mode). No 1 Hz timer unless the menu or settings are visible.

UI
- statusIconSymbol = "cup.and.saucer.fill" while active, nil otherwise; call AppContext.shared.refreshStatusIcon() on changes.
- Menu section (rebuilt on each open): status line (e.g. "● 已开启 · 按计划至 19:00" / "● 已开启 · 剩余 1:23:45" / "○ 已关闭 · 计划于 明天 08:00 开启"), toggle item "立即开启（无限期）"/"关闭防止锁屏", submenu "开启一段时间" with the presets (checkmark on the running preset), toggle "自动计划（工作日 08:00–19:00）", info line for today ("今天：工作日" / "今天：休息日（国庆节）" / "今天：调休上班"). A live countdown while the menu is open is a nice-to-have (Timer in .common mode updating the status item title).
- Settings page (SettingsPage): 当前状态 (StatusBadge + text + buttons), 手动开启 (preset picker + custom slider 5–720 min, 开始/停止), 自动计划 (enable toggle, weekday toggles 周一…周日, DatePicker .hourAndMinute for start/end, holiday toggle + status + 立即更新, manual override list with add (DatePicker + 工作日/休息日 picker) / remove, preview "未来 7 天" listing each day's type and window), 选项 (模拟用户活动, 结束时通知, 全局快捷键 HotKeyRecorder toggling on/off via GlobalHotKeyCenter id "awake.toggle").

CHECKS: policy truth table (weekday in/out of window, weekend, holiday on weekday, 调休 on weekend, manual override beating holiday data, suppression semantics across transitions, timed session expiry crossing window end, infinite session), nextTransition over weekends and holidays, holiday JSON parsing (real sample), assertion create/release probe via pmset.


## As built (updates after review, 2026-09-29)
- The holiday calendar is a region setting "节假日日历": 自动（根据系统时区）(default) / 中国大陆（含调休）/ 波兰 / 不使用节假日.
  自动 maps mainland-China time zones to 中国大陆, Europe/Warsaw to 波兰, anything else to 不使用.
- Polish public holidays are computed offline (Gregorian Easter; Wigilia 24 Dec from 2025). holiday-cn data is
  downloaded only while the effective region is 中国大陆.
- Workday precedence: manual date override > region holidays / 调休 > weekday setting.
- A manual session (including 无限期) survives an app relaunch but not a reboot.
