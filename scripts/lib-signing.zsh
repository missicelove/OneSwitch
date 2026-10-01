# Shared by scripts/build-app.sh and scripts/setup-developer-id.sh (sourced; zsh).
# OneSwitch signs from a private keychain that is not in the keychain search list and never auto-locks
# (created by scripts/setup-signing.sh). It holds the self-signed "OneSwitch Local Signing" identity and,
# after scripts/setup-developer-id.sh, the Apple "Developer ID Application" identity.

SIGN_DIR="${ONESWITCH_SIGNING_DIR:-$HOME/Library/Application Support/OneSwitch-Signing}"
SIGN_KC="$SIGN_DIR/signing.keychain-db"
SIGN_PW="$SIGN_DIR/keychain-password"
LOCAL_SIGN_NAME="OneSwitch Local Signing"
DEVID_PREFIX="Developer ID Application: "

# Unlocks the private keychain with its own random password (never the login password).
signing_unlock() {
  if [[ ! -r "$SIGN_PW" ]]; then
    print -r -- "error: $SIGN_PW is missing." >&2
    print -r -- "       Delete \"$SIGN_DIR\" and run scripts/setup-signing.sh again" >&2
    print -r -- "       (this also deletes a Developer ID key stored there; see scripts/setup-developer-id.sh)." >&2
    return 1
  fi
  security unlock-keychain -p "$(<"$SIGN_PW")" "$SIGN_KC"
}

# Prints "<SHA-1> <name>" for every usable Developer ID Application identity in the private keychain.
# Expired or revoked ones are skipped (so a renewal can be requested and builds fall back). "Not trusted"
# ones are kept: a genuine Developer ID can evaluate as untrusted while its keychain is off the search list.
devid_identities() {
  security find-identity -p codesigning "$SIGN_KC" \
    | awk -v p="\"$DEVID_PREFIX" 'index($0, p) && !/CSSMERR_TP_CERT_(EXPIRED|REVOKED)/ && !seen[$2]++ { h = $2; sub(/^[^"]*"/, ""); sub(/".*$/, ""); print h " " $0 }'
}

# Copies Apple's Developer ID intermediate certificate from the private keychain into the login keychain
# (public certificate only; no key, no trust settings — what Xcode does too). codesign hands chain building
# to trustd, which only reliably sees keychains that are permanently on the user's search list: putting the
# private keychain on the list just for the codesign call fails about half the time ("unable to build chain
# to self-signed root", errSecInternalComponent) because trustd keeps using its cached, older list.
ensure_devid_intermediate() {
  local login="$HOME/Library/Keychains/login.keychain-db" pem
  pem=$(security find-certificate -a -c "Developer ID Certification Authority" -p "$SIGN_KC" 2>/dev/null) || return 0
  [[ -n "$pem" ]] || return 0
  local tmp
  tmp=$(mktemp)
  print -r -- "$pem" > "$tmp"
  # Already there → "already exists" error, which is fine.
  security import "$tmp" -k "$login" >/dev/null 2>&1 || true
  rm -f "$tmp"
}
