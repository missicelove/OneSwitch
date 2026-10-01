#!/bin/zsh
# Installs an Apple "Developer ID Application" signing identity for OneSwitch — no Xcode needed.
# The private key is generated on this Mac and never leaves it; it is kept in OneSwitch's private signing
# keychain (see scripts/lib-signing.zsh). Only Apple's public intermediate certificate is added to the
# login keychain (ensure_devid_intermediate).
#
#   1. ./scripts/setup-developer-id.sh request
#        creates the private key and a certificate signing request (CSR) and shows the CSR in Finder.
#   2. On developer.apple.com → Certificates, Identifiers & Profiles → Certificates → “+”:
#        choose “Developer ID Application”, profile type “G2 Sub-CA”, upload the CSR and download the
#        certificate (developerID_application.cer). Only the team's Account Holder can create it.
#   3. ./scripts/setup-developer-id.sh import ~/Downloads/developerID_application.cer
#        checks the certificate against Apple's root certificates, imports it together with Apple's
#        intermediate certificate, and test-signs a scratch binary.
#   ./scripts/setup-developer-id.sh status
#
# From then on scripts/build-app.sh signs with the Developer ID (hardened runtime + secure timestamp;
# LOCAL_SIGNING=1 keeps the self-signed identity) and scripts/notarize.sh can notarize the build.
set -euo pipefail
setopt no_function_argzero   # $0 inside functions stays the script path (for the printed next steps)
# Make the certificate path absolute while $PWD is still the caller's directory.
[[ "${1:-}" == import && -n "${2:-}" ]] && set -- import "${2:a}"
cd "$(dirname "$0")/.."
source scripts/lib-signing.zsh

WORK="$SIGN_DIR/developer-id"
KEY="$WORK/private-key.pem"
CSR="$WORK/OneSwitch.certSigningRequest"
PROFILE="${NOTARY_PROFILE:-OneSwitch-Notary}"

die() { print -r -- "error: $*" >&2; exit 1; }

open_keychain() {
  [[ -f "$SIGN_KC" ]] || ./scripts/setup-signing.sh
  signing_unlock
}

cert_field() { # <pem> <multiline subject field> — e.g. commonName, organizationalUnitName
  openssl x509 -in "$1" -noout -subject -nameopt multiline,utf8,-esc_msb | awk -F' = ' -v f="$2" '$1 ~ "^ *" f " *$" { print $2; exit }'
}

cmd_request() {
  open_keychain
  local existing
  existing=$(devid_identities)
  if [[ -n "$existing" ]]; then
    print "A Developer ID identity is already installed:"
    print -r -- "  $existing"
    print "Nothing to do. See: $0 status"
    return
  fi
  mkdir -p "$WORK"; chmod 700 "$WORK"
  # Reuse the key if a request was made before: a certificate issued for the earlier CSR still matches it.
  [[ -f "$KEY" ]] || (umask 077; openssl genrsa -out "$KEY" 2048 2>/dev/null)
  openssl req -new -key "$KEY" -out "$CSR" -subj "/CN=OneSwitch Developer ID" 2>/dev/null
  print "Created the certificate signing request:"
  print -r -- "  $CSR"
  print ""
  print "Next (in the browser, signed in as the Account Holder):"
  print "  developer.apple.com → Certificates, Identifiers & Profiles → Certificates → +"
  print "  → Developer ID Application → Profile Type: G2 Sub-CA → upload the file above"
  print "  → Download (developerID_application.cer). Then run:"
  print "  $0 import ~/Downloads/developerID_application.cer"
  [[ -n "${NO_REVEAL:-}" ]] || open -R "$CSR" 2>/dev/null || true
}

cmd_import() {
  local cer="${1:-}"
  [[ -n "$cer" ]] || die "usage: $0 import <developerID_application.cer>"
  [[ -f "$cer" ]] || die "file not found: $cer"
  open_keychain
  [[ -f "$KEY" ]] || die "no pending request ($KEY is missing). The certificate must be issued for the CSR made by '$0 request' on this Mac."

  local tmp
  tmp=$(mktemp -d)
  trap "rm -rf '$tmp'" EXIT
  # Apple delivers DER; PEM is accepted too.
  openssl x509 -inform DER -in "$cer" -out "$tmp/cert.pem" 2>/dev/null \
    || openssl x509 -in "$cer" -out "$tmp/cert.pem" 2>/dev/null \
    || die "$cer is not a certificate"
  [[ "$(openssl x509 -in "$tmp/cert.pem" -noout -pubkey)" == "$(openssl pkey -in "$KEY" -pubout)" ]] \
    || die "this certificate was not issued for the request made on this Mac (its public key differs)."

  local cn team
  cn=$(cert_field "$tmp/cert.pem" commonName)
  team=$(cert_field "$tmp/cert.pem" organizationalUnitName)
  [[ "$cn" == "$DEVID_PREFIX"* ]] || die "not a Developer ID Application certificate: \"$cn\""
  [[ "$team" =~ ^[A-Z0-9]{10}$ ]] || die "unexpected team identifier \"$team\""
  openssl x509 -in "$tmp/cert.pem" -noout -checkend 0 >/dev/null || die "the certificate has expired"

  # Apple's intermediate certificate, from the issuer URL inside the certificate. Nothing downloaded is trusted
  # as such: the chain must verify against the Apple root certificates that ship with macOS.
  local issuer_url
  issuer_url=$(openssl x509 -in "$tmp/cert.pem" -noout -text \
    | sed -n 's/.*CA Issuers - URI:\(.*\)/\1/p' | head -1) || true
  if [[ -z "$issuer_url" ]]; then
    # "Previous Sub-CA" (G1) certificates carry no issuer URL; their intermediate expires on 2027-02-01.
    die "this certificate was issued by the old Developer ID CA (G1, valid only until 2027-02-01). Create a new one with Profile Type \"G2 Sub-CA\" from the same CSR."
  fi
  [[ "$issuer_url" =~ '^https?://([A-Za-z0-9-]+\.)*apple\.com/' ]] || die "unexpected issuer URL \"$issuer_url\""
  print -r -- "==> fetching Apple's intermediate certificate ($issuer_url)"
  curl -fsSL --max-time 30 -o "$tmp/issuer.cer" "$issuer_url" || die "download failed: $issuer_url"
  openssl x509 -inform DER -in "$tmp/issuer.cer" -out "$tmp/issuer.pem" 2>/dev/null \
    || openssl x509 -in "$tmp/issuer.cer" -out "$tmp/issuer.pem" 2>/dev/null \
    || die "the downloaded intermediate is not a certificate"
  security find-certificate -a -c "Apple Root CA" -p /System/Library/Keychains/SystemRootCertificates.keychain > "$tmp/roots.pem"
  # -ignore_critical: every Developer ID certificate carries Apple-private extensions marked critical
  # (1.2.840.113635.100.6.1.13, …) that OpenSSL does not know; the chain itself is still fully checked.
  local verify_out
  verify_out=$(openssl verify -ignore_critical -CAfile "$tmp/roots.pem" -untrusted "$tmp/issuer.pem" "$tmp/cert.pem" 2>&1) \
    || die "the certificate does not chain to an Apple root certificate: $verify_out"

  local sha1
  sha1=$(openssl x509 -in "$tmp/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
  if devid_identities | grep -q "^$sha1 "; then
    print "The certificate is already imported."
  else
    local pass
    pass=$(openssl rand -hex 24)
    # OpenSSL 3 needs -legacy for a PKCS#12 that `security import` understands; LibreSSL has no -legacy.
    openssl pkcs12 -export -inkey "$KEY" -in "$tmp/cert.pem" -name "$cn" -out "$tmp/id.p12" -passout pass:"$pass" -legacy 2>/dev/null \
      || openssl pkcs12 -export -inkey "$KEY" -in "$tmp/cert.pem" -name "$cn" -out "$tmp/id.p12" -passout pass:"$pass"
    security import "$tmp/id.p12" -k "$SIGN_KC" -P "$pass" -T /usr/bin/codesign >/dev/null
  fi
  # The intermediate may already be there (earlier import); "already exists" is fine.
  security import "$tmp/issuer.pem" -k "$SIGN_KC" >/dev/null 2>&1 || true
  ensure_devid_intermediate
  # Lets codesign use the private key without a keychain-access prompt (non-interactive builds).
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(<"$SIGN_PW")" "$SIGN_KC" >/dev/null
  devid_identities | grep -q "^$sha1 " || die "the identity was not imported correctly"

  # Prove the identity works end to end before any real build depends on it.
  print "==> test-signing a scratch binary"
  cp /usr/bin/true "$tmp/probe"
  if ! codesign --force --options runtime --timestamp=none \
       --sign "$sha1" --keychain "$SIGN_KC" "$tmp/probe" 2>"$tmp/sign.err"; then
    cat "$tmp/sign.err" >&2
    die "test signing failed — the private key and certificate are kept; report the message above."
  fi
  local chain
  chain=$(codesign -dvv "$tmp/probe" 2>&1 | sed -n 's/^Authority=//p')
  print -r -- "$chain" | sed 's/^/    /'
  (( $(print -r -- "$chain" | wc -l) >= 3 )) || die "the signature does not carry the full certificate chain"

  # The key now lives in the keychain; drop the plain-text copy and the request.
  rm -f "$KEY" "$CSR"
  rmdir "$WORK" 2>/dev/null || true
  print ""
  print -r -- "Installed: $cn"
  print -r -- "Team ID:   $team"
  print ""
  print "scripts/build-app.sh now signs with this identity. The first such build changes OneSwitch's"
  print "signature, so grant 辅助功能 / 输入监控 once more on both Macs after installing it."
  print ""
  print "For notarization (scripts/notarize.sh), store the notary credentials once — you are asked for an"
  print "app-specific password (account.apple.com → 登录与安全 → App 专用密码):"
  print -r -- "  xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id $team"
}

cmd_status() {
  if [[ ! -f "$SIGN_KC" ]]; then
    print "No private signing keychain yet (scripts/setup-signing.sh or '$0 request' creates it)."
    return
  fi
  signing_unlock
  local ids
  ids=$(devid_identities)
  if [[ -z "$ids" ]]; then
    print "Developer ID: not installed."
    [[ -f "$KEY" ]] && print -r -- "  A request is pending: import the certificate with '$0 import <file.cer>'." \
                    || print -r -- "  Start with: $0 request"
  else
    local line hash name end
    for line in "${(@f)ids}"; do
      hash=${line%% *}; name=${line#* }
      end=$(security find-certificate -a -Z -p -c "$name" "$SIGN_KC" \
        | awk -v h="$hash" '/^SHA-1 hash:/ { keep = ($3 == h) } keep' \
        | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')
      print -r -- "Developer ID: $name"
      print -r -- "  SHA-1 $hash, valid until $end"
    done
  fi
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    print -r -- "Notary credentials: \"$PROFILE\" OK"
  else
    print -r -- "Notary credentials: \"$PROFILE\" not usable (xcrun notarytool store-credentials $PROFILE --apple-id … --team-id …)"
  fi
}

case "${1:-}" in
  request) cmd_request ;;
  import) shift; cmd_import "$@" ;;
  status) cmd_status ;;
  *) print "usage: $0 request | import <developerID_application.cer> | status" >&2; exit 2 ;;
esac
