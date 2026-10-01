#!/bin/zsh
# Renders the real settings window (every pane, light + dark, plus a sidebar search and a scrolled page) to PNG files.
#   ./scripts/settings-screenshots.sh                  # → docs/screenshots/
#   ./scripts/settings-screenshots.sh /tmp/shots --panes general,awake --appearance dark
#   ./scripts/settings-screenshots.sh docs/screenshots --activate   # key-window look (takes focus ~1 s per shot)
#
# The six modules are only instantiated, never started, under a throwaway profile that is deleted
# afterwards; the window sits below the desktop picture, so nothing appears on screen, and the renderer
# cannot become the active app (the keyboard focus stays where it is, except with --activate). Capturing
# uses ScreenCaptureKit and needs the Screen Recording permission of the terminal that runs this script.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-docs/screenshots}"
(( $# > 0 )) && shift
SCRATCH="${SCRATCH:-.build-screenshots}"

# Same SDK stamp as scripts/build-app.sh, so the pictures show the Liquid Glass design the app gets.
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
swift build --product OneSwitch --scratch-path "$SCRATCH" \
  -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION"
rc=0
"$SCRATCH/debug/OneSwitch" --render-settings "$OUT" --search 剪贴板 --scrolled awake "$@" || rc=$?
# cfprefsd leaves an empty plist for the throwaway suite — once when the renderer removes the domain and
# again at its deferred flush, measured 7.5–10.5 s after the renderer's last change. Once that flush is
# over a deleted file stays deleted, so keep deleting it for 15 s.
PLIST="$HOME/Library/Preferences/com.oneswitch.app.SettingsSnapshot.plist"
for _ in {1..30}; do
  sleep 0.5
  rm -f "$PLIST"
done
exit $rc
