#!/bin/zsh
# Builds OneSwitch, installs it to /Applications and (re)launches it on this Mac.
#   ./scripts/install.sh
# Run scripts/setup-signing.sh once beforehand so macOS keeps the granted permissions across updates.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=/Applications/OneSwitch.app

./scripts/build-app.sh

# Quits the running OneSwitch of this user. OneSwitch treats SIGTERM like 退出 (every feature's stop()
# runs: cursor restored, keys released on the other Mac, menu-bar separators removed), so wait for it
# to exit — `open` would otherwise just re-activate the old, still-exiting process.
quit_running() {
  local uid=$(id -u) i
  pgrep -x -u "$uid" OneSwitch >/dev/null || return 0
  echo "==> quitting the running OneSwitch"
  pkill -TERM -x -u "$uid" OneSwitch || true
  for i in {1..50}; do
    pgrep -x -u "$uid" OneSwitch >/dev/null || return 0
    sleep 0.2
  done
  echo "warning: OneSwitch did not quit within 10 s; killing it"
  pkill -KILL -x -u "$uid" OneSwitch || true
  sleep 0.5
}

quit_running
echo "==> installing $DEST"
rm -rf "$DEST"
ditto build/OneSwitch.app "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --verify --strict "$DEST"
open "$DEST"
echo "==> installed and launched $DEST"
