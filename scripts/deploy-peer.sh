#!/bin/zsh
# Copies build/OneSwitch.app to the other Mac over SSH (Thunderbolt link preferred), installs it to
# /Applications and relaunches it there. Build first with scripts/build-app.sh (or scripts/install.sh).
#   ./scripts/deploy-peer.sh                         # finds the other Mac on the Thunderbolt Bridge
#   PEER=<user>@10.77.0.2 ./scripts/deploy-peer.sh
#   PEER_USER=<user> PEER_KEY=~/.ssh/<key> ./scripts/deploy-peer.sh
# Defaults can be kept in scripts/deploy-peer.local (git-ignored), e.g. PEER_USER=<user>.
# Requirements on the other Mac: 远程登录 (Remote Login) on, this key in ~/.ssh/authorized_keys, and the
# user logged in to the desktop (so OneSwitch can be launched in the GUI session).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f scripts/deploy-peer.local ]] && source scripts/deploy-peer.local
KEY="${PEER_KEY:-$HOME/.ssh/oneswitch_peer}"
USER_AT="${PEER_USER:-$USER}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=4 -o ServerAliveInterval=5 -o StrictHostKeyChecking=accept-new)
if [[ -f "$KEY" ]]; then
  SSH_OPTS=(-i "$KEY" -o IdentitiesOnly=yes "${SSH_OPTS[@]}")
else
  echo "note: $KEY not found; using the default SSH keys"
fi

APP=build/OneSwitch.app
[[ -d "$APP" ]] || { echo "error: $APP missing (run scripts/build-app.sh)" >&2; exit 1; }
codesign --verify --strict "$APP" || { echo "error: $APP has an invalid signature; rebuild it" >&2; exit 1; }

if [[ -n "${PEER:-}" ]]; then
  TARGET="$PEER"
  [[ "$TARGET" == *@* ]] || TARGET="$USER_AT@$TARGET"
else
  TARGET=""
  # Never "deploy" to ourselves (this Mac owns one of the static addresses).
  LOCAL_IPS=($(ifconfig -a inet 2>/dev/null | awk '/inet / { print $2 }'))
  # Static Thunderbolt IPs first, then the link-local neighbours seen on the bridge.
  CANDIDATES=(10.77.0.2 10.77.0.1)
  CANDIDATES+=($(arp -an -i bridge0 2>/dev/null | awk -F'[()]' '/169\.254\./ && !/255\.255/ { print $2 }'))
  for ip in $CANDIDATES; do
    (( ${LOCAL_IPS[(Ie)$ip]} )) && continue
    echo "    trying $USER_AT@$ip …"
    if ssh "${SSH_OPTS[@]}" "$USER_AT@$ip" true 2>/dev/null; then TARGET="$USER_AT@$ip"; break; fi
  done
  if [[ -z "$TARGET" ]]; then
    echo "error: the other Mac is not reachable over SSH on the Thunderbolt Bridge." >&2
    echo "       Check the cable, 远程登录 on the other Mac, or pass PEER=user@address." >&2
    exit 1
  fi
fi

# Runs in the remote login shell (zsh or bash). Unpacks and verifies the new app first, so the running
# copy keeps working if anything fails, then quits the old instance (SIGTERM = 退出, waits up to 10 s),
# swaps the bundle and launches it.
REMOTE_SCRIPT=$(cat <<'EOF'
set -e
uid=$(id -u)
tmp=$(mktemp -d /tmp/oneswitch-deploy.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
tar -C "$tmp" -xzf -
codesign --verify --strict "$tmp/OneSwitch.app"
if pgrep -x -u "$uid" OneSwitch >/dev/null 2>&1; then
  pkill -TERM -x -u "$uid" OneSwitch || true
  i=0
  while pgrep -x -u "$uid" OneSwitch >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 50 ]; then
      echo "warning: OneSwitch did not quit within 10 s; killing it"
      pkill -KILL -x -u "$uid" OneSwitch || true
      sleep 0.5
      break
    fi
    sleep 0.2
  done
fi
rm -rf /Applications/OneSwitch.app
mv "$tmp/OneSwitch.app" /Applications/OneSwitch.app
xattr -dr com.apple.quarantine /Applications/OneSwitch.app 2>/dev/null || true
if ! open /Applications/OneSwitch.app; then
  echo "error: installed, but could not launch OneSwitch (is $(id -un) logged in to the desktop?)" >&2
  exit 1
fi
echo "installed and launched on $(scutil --get ComputerName)"
EOF
)

echo "==> deploying to $TARGET"
tar -C build -czf - OneSwitch.app | ssh "${SSH_OPTS[@]}" "$TARGET" "$REMOTE_SCRIPT"
