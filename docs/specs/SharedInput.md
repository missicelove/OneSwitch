# SharedInput — implementation spec

Class SharedInputModule: FeatureModule, "public init(hub: any PeerHub)", id "input", displayName "键鼠共享", symbolName "keyboard". Deskflow-like keyboard & mouse sharing between the two Macs. Uses ONLY the PeerHub/PeerChannel contract (service "input"; message types in PeerLimits.serviceTypeRange). Develop/test against LoopbackPeerHub (the real network hub is built in parallel by another agent; it sets TCP_NODELAY).

ROLES & LAYOUT
- 服务端 (shares this Mac's physical keyboard/mouse) or 客户端 (receives). Default: desktop → server, laptop (AppEnvironment.isLaptop) → client; user-changeable. Exchange config in a hello message; if both sides claim the same role show "两台 Mac 的角色设置冲突".
- Client position relative to the server: 左 / 右 (default) / 上 / 下, chosen in settings with a small visual diagram (two screen rectangles, click a side). Mapping along the shared edge is proportional (normalized 0…1 fraction).

SERVER
- CGEventTap (cgSessionEventTap, headInsertEventTap, .defaultTap) for mouseMoved, left/right/otherMouseDown/Up/Dragged, scrollWheel, keyDown, keyUp, flagsChanged and NX_SYSDEFINED (type 14, media keys). Run it on a dedicated high-priority thread with its own CFRunLoop. Needs Accessibility (and Input Monitoring for keys) — show PermissionRows and a clear state when missing.
- Local mode: pass events through; switch to remote when the cursor presses against the configured OUTER edge of the combined desktop — use CG global coordinates (top-left origin, CGDisplayBounds of all active displays); an edge point only counts if no other local display continues beyond it. Options: dwell delay 0…500 ms (default 0), optional required modifier, never switch while a mouse button is held.
- Entering remote: send enter {fraction, modifiers}; CGAssociateMouseAndMouseCursorPosition(0) so the local cursor stays parked while deltas still arrive (kCGMouseEventDeltaX/Y); hide the cursor (CGDisplayHideCursor; for a background app it needs the private CGSSetConnectionProperty(conn, conn, "SetsCursorInBackground", kCFBooleanTrue) via dlsym of _CGSDefaultConnection — if unavailable, park the cursor at the edge instead). Swallow (return nil) and forward every captured event.
- Forwarding: mouse deltas; buttons with button number + click state (kCGMouseEventClickState); scroll with all fields needed for smooth trackpad scrolling (DeltaAxis1/2, PointDeltaAxis1/2, FixedPtDeltaAxis1/2, IsContinuous, ScrollPhase, MomentumPhase); keyDown/keyUp with keycode, flags and autorepeat; flagsChanged with keycode + flags; media keys (NSEvent systemDefined subtype 8 data1/data2).
- Key/button routing state machine: a key or button goes UP on the same machine where it went DOWN (track held keys per side across switches); on leaving remote send releaseAll.
- Returning: client sends leave {fraction} when its cursor presses against the edge facing the server → warp the server cursor just inside its edge at that fraction (CGWarpMouseCursorPosition), re-associate, show the cursor.
- Safety: a force-return hotkey (default ⌃⌥⌘ + ←, configurable, detected INSIDE the tap because swallowed events never reach Carbon hotkeys); a toggle hotkey to jump to the other Mac (Carbon GlobalHotKeyCenter id "input.toggle" in local mode + detection inside the tap in remote mode); if the channel closes, a heartbeat is missed for >1.5 s, or the tap gets disabled (kCGEventTapDisabledByTimeout/ByUserInput → re-enable) while remote → immediately return to local and restore the cursor. Warn when IsSecureEventInputEnabled() (password fields block key capture).
- Latency: forward immediately; you may coalesce mouse deltas to ≥ 4 ms only if the channel is backed up.

CLIENT
- Needs Accessibility to post events (CGEvent.post(tap: .cghidEventTap), source .hidSystemState). On enter, place the cursor at the entry edge point (fraction) and wake the display (IOPMAssertionDeclareUserActivity).
- Mouse: new position = current actual cursor location (so local trackpad use is respected) + delta, clamped to the union of the client's displays (clamp into the nearest display when in a gap); post mouseMoved or left/right/otherMouseDragged when a button is held, also setting the delta fields. When the cursor presses against the edge facing the server → send leave {fraction} and stop injecting.
- Buttons with click state; keys via CGEvent(keyboardEventSource:virtualKey:keyDown:) with forwarded flags and autorepeat field; flagsChanged events; scroll via CGEvent(scrollWheelEvent2Source:units:.pixel,...) plus the forwarded fields; media keys via NSEvent.otherEvent(with: .systemDefined, ... subtype: 8, data1:...) .cgEvent?.post.
- On releaseAll / channel close: post up events for every key/button it pressed.

CLIPBOARD (setting, default ON): when control moves to the other Mac, the side losing control sends its pasteboard if changeCount changed: plain text, RTF, HTML, PNG/TIFF (≤ 20 MB total), written to NSPasteboard.general on the receiver.

PROTOCOL: compact binary encoding for high-rate events (little structs), JSON for control (hello/config, enter, leave, releaseAll, clipboard, heartbeat 1 Hz). Everything encoding/decoding round-trips.

DESIGN FOR TESTABILITY: isolate side effects behind protocols — EventInjector (posts events), CursorController (warp/associate/hide), ScreenGeometry (display frames), and the tap — so the whole switching logic runs in checks with fakes. The checks must NEVER create a real event tap that swallows input, post real events, warp or hide the real cursor.

UI
- Menu section: status ("服务端 · 已连接 MacBook Pro · 当前：本机" / "服务端 · 正在控制 MacBook Pro" / "客户端 · 由 Mac Studio 控制" / "等待连接另一台 Mac" / permission problems), enable toggle, "切换到另一台 Mac"/"切回本机" (server), hotkey hints, "键鼠共享设置…".
- Settings page: enable, role picker, layout diagram, switching options (dwell, modifier, block while button held), hotkeys (HotKeyRecorder), clipboard sync, permissions (PermissionRow for accessibility + inputMonitoring), diagnostics (connection, events/s, last latency via heartbeat RTT).

CHECKS: edge detection for multi-display geometries in CG coordinates (side-by-side, stacked, different heights with offsets, gaps; only outer edges trigger), enter/leave fraction mapping round-trips, client clamping across gaps, key/button routing across switches (down local → up after switch stays local, etc.), releaseAll content, binary codec round-trips for every message, full server⇄client flow over LoopbackPeerHub with fake injector/cursor/geometry (move to edge → enter → deltas injected on client → client hits edge → leave → server cursor restored), heartbeat loss / channel close while remote → server returns to local and client releases held keys, force-return hotkey detection, role conflict detection.

## Implementation notes (as built)
- The keyboard tap is created disabled and enabled ONLY while the server controls the other Mac
  (ServerCore `.remote`); in local mode only mouse positions are examined for edge detection.
- Keystrokes are never logged or stored; they are forwarded only over the paired, encrypted PeerLink channel.
- Hotkey default ⌃⌥⌘Space toggles control (Carbon hotkey in local mode, detected inside the tap in remote mode).

- `tapDisabledByUserInput` is benign (macOS also sends it — sometimes late — for our own deliberate keyboard-tap
  disables); only `tapDisabledByTimeout` hands control back. Regression-checked (TapDisablePolicy).
- Heartbeat: server returns to local after 1.5 s of silence while controlling; the client sends `leave` when it
  refuses `enter` (no 辅助功能) or times out.
- Switching is never triggered by drag events when "按住鼠标按键时不切换" is on.
- Mode transitions are logged at INFO ("server mode local → remote（原因）").
