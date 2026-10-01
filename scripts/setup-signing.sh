#!/bin/zsh
# Creates a self-signed code-signing identity "OneSwitch Local Signing" in a private keychain file
# (~/Library/Application Support/OneSwitch-Signing/). It is NOT added to the keychain search list and
# the login keychain is untouched. A stable signature keeps macOS privacy grants (辅助功能/输入监控/本地网络)
# valid across rebuilds — on this Mac and on the other Mac receiving the same build.
#
# Run it once, on the Mac that builds OneSwitch. Safe to re-run (does nothing if the identity exists).
# To start over: rm -rf ~/Library/Application\ Support/OneSwitch-Signing && ./scripts/setup-signing.sh
# (a new certificate means macOS asks for the permissions once more). The same keychain also holds the
# Developer ID identity from scripts/setup-developer-id.sh, if any — deleting it deletes that private key too.
set -euo pipefail
NAME="OneSwitch Local Signing"
DIR="${ONESWITCH_SIGNING_DIR:-$HOME/Library/Application Support/OneSwitch-Signing}"
KC="$DIR/signing.keychain-db"
PW="$DIR/keychain-password"

has_identity() {
  [[ -f "$KC" && -r "$PW" ]] || return 1
  security unlock-keychain -p "$(<"$PW")" "$KC" 2>/dev/null || return 1
  security find-identity -p codesigning "$KC" 2>/dev/null | grep -qF "\"$NAME\""
}

if [[ -f "$KC" ]]; then
  if has_identity; then
    echo "signing identity \"$NAME\" already exists in $KC"
    exit 0
  fi
  echo "error: $KC exists but does not contain a usable \"$NAME\" identity." >&2
  echo "       Remove \"$DIR\" and run this script again." >&2
  exit 1
fi

command -v openssl >/dev/null || { echo "error: openssl not found" >&2; exit 1; }
mkdir -p "$DIR"; chmod 700 "$DIR"
TMP=$(mktemp -d)
# Current user keychain search list, one path per line (without the quotes `security` prints).
BEFORE=("${(@f)$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')}")
CREATED=0
cleanup() {
  rm -rf "$TMP"
  # Keep the user's keychain search list exactly as it was (create-keychain appends to it).
  local after
  after=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
  if (( ${#BEFORE[@]} > 0 )) && [[ -n "${BEFORE[1]}" && "$after" != "${(F)BEFORE}" ]]; then
    security list-keychains -d user -s "${BEFORE[@]}"
  fi
  if (( CREATED == 0 )); then
    # Failed half-way: leave nothing behind so the next run starts clean.
    [[ -f "$KC" ]] && security delete-keychain "$KC" 2>/dev/null
    rm -f "$KC" "$PW"
  fi
}
trap cleanup EXIT

PASS=$(openssl rand -hex 24)
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 7300 -nodes \
  -subj "/CN=$NAME" -addext "extendedKeyUsage=codeSigning" \
  -addext "keyUsage=critical,digitalSignature" 2>/dev/null
# OpenSSL 3 needs -legacy for a PKCS#12 that `security import` understands; LibreSSL has no -legacy.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:"$PASS" -legacy 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:"$PASS"

security create-keychain -p "$PASS" "$KC"
print -r -- "$PASS" > "$PW"; chmod 600 "$PW"
security set-keychain-settings "$KC"          # no auto-lock timeout, no lock on sleep
security unlock-keychain -p "$PASS" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PASS" -T /usr/bin/codesign >/dev/null
# Lets codesign use the private key without a keychain-access prompt (non-interactive builds).
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null

if ! security find-identity -p codesigning "$KC" | grep -qF "\"$NAME\""; then
  echo "error: the identity was not imported correctly" >&2
  exit 1
fi
CREATED=1
echo "created signing identity \"$NAME\" in $KC"
security find-identity -p codesigning "$KC" | grep -F "\"$NAME\"" | head -1
