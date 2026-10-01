#!/bin/zsh
# Notarizes a Developer ID build with Apple and staples the ticket to it, so Gatekeeper opens the app on any
# Mac without a warning — also when it arrives by download, AirDrop or mail. Not needed for the two Macs
# that install through scripts/install.sh / scripts/deploy-peer.sh (those copies are never quarantined).
#
#   ./scripts/build-app.sh && ./scripts/notarize.sh      # → build/OneSwitch-<version>.zip, ready to share
#   (the version comes from build-app.sh: VERSION=x.y.z ./scripts/build-app.sh for a new release)
#   NOTARY_PROFILE=<name> ./scripts/notarize.sh [path/to/OneSwitch.app]
#
# Needs: a Developer ID identity (scripts/setup-developer-id.sh) and notary credentials stored once with
#   xcrun notarytool store-credentials OneSwitch-Notary --apple-id <Apple ID> --team-id <Team ID>
# which asks for an app-specific password (account.apple.com → 登录与安全 → App 专用密码).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/OneSwitch.app}"
PROFILE="${NOTARY_PROFILE:-OneSwitch-Notary}"
die() { print -r -- "error: $*" >&2; exit 1; }

[[ -d "$APP" ]] || die "$APP not found (run scripts/build-app.sh)"
codesign --verify --strict --deep "$APP" || die "$APP has an invalid signature; rebuild it"
INFO=$(codesign -dvv "$APP" 2>&1)
grep -q "^Authority=Developer ID Application: " <<<"$INFO" \
  || die "$APP is not signed with a Developer ID (scripts/setup-developer-id.sh, then scripts/build-app.sh)"
grep -Eq "^CodeDirectory .*flags=[^ ]*runtime" <<<"$INFO" || die "$APP was signed without the hardened runtime"
grep -q "^Timestamp=" <<<"$INFO" || die "$APP has no secure timestamp"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ditto -c -k --keepParent "$APP" "$TMP/upload.zip"

echo "==> submitting $APP ($VERSION) to the Apple notary service — usually takes 1–5 minutes"
RC=0
xcrun notarytool submit "$TMP/upload.zip" --keychain-profile "$PROFILE" --wait --output-format plist \
  >"$TMP/result.plist" 2>"$TMP/submit.err" || RC=$?
# plutil prints nothing when the result is empty (e.g. no stored credentials) or lacks the key.
ID=$(plutil -extract id raw -o - "$TMP/result.plist" 2>/dev/null || true)
STATUS=$(plutil -extract status raw -o - "$TMP/result.plist" 2>/dev/null || true)
if [[ "$STATUS" != "Accepted" ]]; then
  cat "$TMP/submit.err" >&2
  if [[ -n "$ID" ]]; then
    echo "--- notary log ($ID):" >&2
    xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
    die "notarization ended with status \"${STATUS:-unknown}\""
  fi
  die "submission failed (exit $RC). Credentials missing? xcrun notarytool store-credentials $PROFILE --apple-id … --team-id …"
fi
echo "    accepted (submission $ID)"

echo "==> stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

OUT="build/OneSwitch-$VERSION.zip"
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
echo "==> notarized: $APP → $OUT"
