#!/bin/zsh
# Builds build/OneSwitch.app (release, arm64) and signs it.
#   ./scripts/build-app.sh   # Developer ID (scripts/setup-developer-id.sh) if installed, else the local
#                            # identity from scripts/setup-signing.sh, else ad-hoc
#   LOCAL_SIGNING=1 ./scripts/build-app.sh   # the local identity even when a Developer ID is installed
#   SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh   # an identity from the login keychain
#   VERSION=1.2.0 ./scripts/build-app.sh
#   LEGACY_APPEARANCE=1 ./scripts/build-app.sh   # pre-macOS 26 look (see the SDK note below)
#
# A stable signing identity keeps macOS privacy grants (辅助功能 / 输入监控 / 本地网络) valid across
# rebuilds: TCC matches the app by its designated requirement. For the local identity that is
# `identifier "com.oneswitch.app" and certificate leaf = H"<cert hash>"`; for a Developer ID it names the
# Apple-issued certificate chain and the team ID, so it survives certificate renewals too. An ad-hoc
# signature's requirement is the code hash, which changes with every build.
#
# Every signature uses the hardened runtime (required for notarization; OneSwitch needs no exceptions).
# Developer ID signatures also get a secure timestamp from Apple. Without a network connection the build is
# signed with the same identity but without a timestamp: macOS permissions keep working, only
# scripts/notarize.sh refuses such a build.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-signing.zsh

VERSION="${VERSION:-1.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"

# Resolve the signing identity first so a broken setup fails before the (long) build.
DEVID=0
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  SIGN_ARGS=(--sign "$SIGN_IDENTITY")
  SIGN_DESC="$SIGN_IDENTITY"
  # codesign matches a name substring or a SHA-1; look the identity up the same way (default search list).
  if security find-identity -p codesigning | awk -v id="$SIGN_IDENTITY" \
       'index($0, "\"Developer ID Application") && (index($0, id) || toupper(id) == $2) { found = 1 } END { exit !found }'; then
    DEVID=1
  fi
elif [[ -f "$SIGN_KC" ]]; then
  signing_unlock
  DEVID_LINE=""
  [[ -n "${LOCAL_SIGNING:-}" ]] || DEVID_LINE=$(devid_identities | head -1)
  if [[ -n "$DEVID_LINE" ]]; then
    SIGN_HASH=${DEVID_LINE%% *}
    SIGN_DESC="${DEVID_LINE#* } ($SIGN_HASH)"
    DEVID=1
    # codesign's chain building needs Apple's intermediate certificate in the login keychain.
    ensure_devid_intermediate
  else
    # Sign by certificate hash: unambiguous even if the name existed twice. The self-signed certificate
    # is "not trusted" (CSSMERR_TP_NOT_TRUSTED) — codesign accepts it, macOS only needs a stable identity.
    SIGN_HASH=$(security find-identity -p codesigning "$SIGN_KC" | awk -v name="\"$LOCAL_SIGN_NAME\"" 'index($0, name) { print $2; exit }')
    if [[ -z "$SIGN_HASH" ]]; then
      echo "error: identity \"$LOCAL_SIGN_NAME\" not found in $SIGN_KC." >&2
      echo "       Run scripts/setup-signing.sh, or scripts/setup-developer-id.sh for a Developer ID." >&2
      exit 1
    fi
    SIGN_DESC="$LOCAL_SIGN_NAME ($SIGN_HASH)"
  fi
  SIGN_ARGS=(--sign "$SIGN_HASH" --keychain "$SIGN_KC")
else
  echo "warning: no stable signing identity (run scripts/setup-signing.sh once); using an ad-hoc signature."
  echo "         macOS will ask for 辅助功能 / 输入监控 again after every rebuild."
  SIGN_ARGS=(--sign -)
  SIGN_DESC="ad-hoc"
fi
if (( DEVID )); then
  SIGN_FLAGS=(--options runtime --timestamp)
else
  SIGN_FLAGS=(--options runtime --timestamp=none)
fi

# Record the real SDK version in the binary (LC_BUILD_VERSION). SwiftPM's build system links with
# `--sysroot`, so clang falls back to the deployment target (14.0) as the "SDK version" — and macOS then runs
# OneSwitch in its compatibility appearance: no Liquid Glass sidebar / toolbar / controls in Settings.
# LEGACY_APPEARANCE=1 keeps the old behaviour (SDK version = deployment target).
MIN_MACOS=14.0
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
LINK_FLAGS=()
if [[ -z "${LEGACY_APPEARANCE:-}" ]]; then
  LINK_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$SDK_VERSION")
fi

echo "==> swift build (release)"
swift build -c release --product OneSwitch "${LINK_FLAGS[@]}"
BIN_DIR=$(swift build -c release --product OneSwitch "${LINK_FLAGS[@]}" --show-bin-path)
STAMPED_SDK=$(otool -l "$BIN_DIR/OneSwitch" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "sdk" { print $2; exit }')
echo "    linked for macOS $MIN_MACOS+, SDK $STAMPED_SDK"

APP="build/OneSwitch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OneSwitch" "$APP/Contents/MacOS/OneSwitch"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi

echo "==> codesign ($SIGN_DESC)"
sign_app() { codesign --force "$@" "${SIGN_ARGS[@]}" --identifier com.oneswitch.app "$APP"; }
SIGN_ERR=$(mktemp)
if ! sign_app "${SIGN_FLAGS[@]}" 2>"$SIGN_ERR"; then
  cat "$SIGN_ERR" >&2
  if (( DEVID )) && grep -qi "timestamp" "$SIGN_ERR"; then
    # Same identity, so the designated requirement (and every macOS permission grant) stays the same.
    echo "warning: Apple's timestamp service is unreachable; signing without a secure timestamp." >&2
    echo "         Fine for install.sh / deploy-peer.sh; rebuild online before scripts/notarize.sh." >&2
    sign_app --options runtime --timestamp=none || { rm -f "$SIGN_ERR"; exit 1; }
  else
    rm -f "$SIGN_ERR"
    if (( DEVID )); then
      echo "error: Developer ID signing failed (see the codesign message above)." >&2
      [[ -n "${SIGN_IDENTITY:-}" ]] \
        && echo "       Unset SIGN_IDENTITY to sign from OneSwitch's private keychain." >&2 \
        || echo "       ./scripts/setup-developer-id.sh status shows the installed identity." >&2
    fi
    exit 1
  fi
fi
rm -f "$SIGN_ERR"
codesign --verify --strict --verbose=1 "$APP"
codesign -dvv "$APP" 2>&1 | sed -n -e 's/^TeamIdentifier=/    team: /p' -e 's/^CodeDirectory .*\(flags=[^ ]*\).*/    \1/p'
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /    designated requirement: /p'
echo "==> built $APP ($VERSION, build $BUILD)"
