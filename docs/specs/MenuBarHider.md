# MenuBarHider — implementation spec

Class MenuBarHiderModule: FeatureModule, "public init()", id "menubar", displayName "菜单栏图标", symbolName "menubar.rectangle".

CORE TECHNIQUE (Hidden Bar / Dozer style, works on notched MacBooks)
- Create NSStatusItems in start(): a toggle button (chevron "chevron.left"/"chevron.right" or a small dot, variable length) and, to its LEFT, a separator item. Everything the user ⌘-drags to the LEFT of the separator is hidden when collapsed: collapsing sets the separator's length to a huge value (e.g. 10_000) so those items are pushed off-screen; expanding restores a small visible length (a thin divider "|" drawn as a template image, ~8–12 pt). Optional third item "永久隐藏分隔线" (always-hidden section, setting default OFF): items left of it stay hidden even when expanded, revealed only by ⌥-clicking the toggle.
- Note: new status items appear to the LEFT of existing ones; create the toggle first, then the separator (then the always-hidden separator). The app creates its main item and the system-monitor items before this module starts.
- autosaveName for each item ("OneSwitchHiderToggle"/"OneSwitchHiderSeparator"/"OneSwitchHiderAlwaysHidden" + AppEnvironment.profileSuffix) so positions persist.
- Safety: before collapsing, verify the separator is to the left of the toggle (compare statusItem.button?.window?.frame.minX). If not, do not collapse; show a warning in the menu/settings ("分隔线位置不正确：请按住 ⌘ 将分隔线拖到切换按钮左侧"). Never hide the toggle itself. On stop() restore normal lengths.
- Collapsed at launch by default (setting "启动时自动隐藏", default ON).

REVEAL
- Click the toggle → expand; after N seconds auto-collapse. N configurable 5…60 s (step 5, default 10) — the user explicitly asked for 5 s–1 min. Setting "自动重新隐藏" (default ON).
- Postpone the auto-collapse while the mouse is inside the menu-bar strip of the screen it is on (NSEvent.mouseLocation vs screen.frame.maxY - menu bar height via NSStatusBar.system.thickness / screen.visibleFrame) or while a menu is open (NSMenu.didBeginTracking/didEndTracking notifications, or check mouse button state); re-check every 0.5 s then collapse once it leaves.
- Global hotkey (GlobalHotKeyCenter id "menubar.toggle", HotKeyRecorder in settings, default none).
- Right-click on the toggle → small menu: 显示/隐藏, 设置…

CHOOSING WHICH ICONS TO HIDE
- Primary method: ⌘-drag icons to the left of the separator (explain clearly in settings with a small diagram built from SF Symbols / shapes).
- Secondary (标注"实验性"): a list of the current menu-bar items. Probe on this Mac (macOS 27) which source works and implement the best with fallback: (a) Accessibility: for each NSRunningApplication, AXUIElementCreateApplication(pid) → attribute "AXExtrasMenuBar" → children with AXPosition/AXSize/AXTitle/AXDescription/AXIdentifier (needs Accessibility permission — show PermissionRow when missing); (b) CGWindowListCopyWindowInfo on-screen windows at kCGStatusWindowLevel (layer 25) in the menu-bar band: owner name, pid, bounds (titles need Screen Recording). Show app icon (NSRunningApplication.icon) + name + section (可见 / 隐藏 / 永久隐藏) computed from x positions relative to the separators (only meaningful while expanded — expand temporarily when listing). Exclude our own items. Offer "移到隐藏区"/"移到显示区" buttons that perform a synthetic ⌘-drag via CGEvents (requires Accessibility): expand, save cursor position, post leftMouseDown with .maskCommand at the item center, several leftMouseDragged steps to the target point (just left of the separator for hide / just right of the separator for show), leftMouseUp, restore cursor, then re-read positions to verify and report success/failure. System items that macOS refuses to move must fail gracefully. IMPORTANT: in checks do NOT perform real drags or move the cursor; unit-test the event-sequence builder and classification logic only. You may run the listing probe read-only and print what it finds.

UI
- Menu section: toggle "显示隐藏的图标（N 秒后自动隐藏）"/"立即隐藏图标", info line on state/warning, "整理菜单栏图标…" (opens settings via AppContext.shared.openSettings(moduleID: "menubar")).
- Settings page: 启用 toggle (disabling removes the separators and shows everything), 自动重新隐藏 + delay slider 5–60 s, 启动时自动隐藏, 永久隐藏区 toggle, 分隔线样式 (细线 / 圆点 / 隐藏分隔线图标 while collapsed), hotkey, usage guide, experimental item list with refresh.
- Notch hint: on screens with a notch (NSScreen.safeAreaInsets.top > 0 / auxiliaryTopLeftArea != nil) show a tip that fewer visible icons avoids icons disappearing behind the notch.

CHECKS: classification from positions, safety check logic (separator right of toggle), auto-collapse state machine with an injected clock (expand → delay → collapse, postpone while mouse in bar, manual collapse cancels timer, re-expand resets), drag event-sequence builder (coordinates, flags, event types), settings encode/decode, read-only probe listing of menu-bar items (print results; must not fail the check if permissions are missing).
