#!/bin/zsh
# Uploads the Developer ID signing identity, and a password for it, as the two secrets the release
# workflow needs.
#
#   zsh Scripts/upload_signing_secrets.sh
#
# `security export -t identities` exports EVERY identity in the keychain, not the one you name, so
# this script never trusts its own export: it imports the archive into a throwaway keychain and
# refuses to upload unless that archive holds exactly one identity and it is the expected team. If
# your keychain has more than one Developer ID certificate, export just the right one from Keychain
# Access (right-click the certificate > Export > .p12) and point this script at it:
#
#   FLOWPEEK_P12=~/Desktop/FlowPeek.p12 zsh Scripts/upload_signing_secrets.sh
#
# Nothing is written outside a private temporary directory, removed on exit whether this succeeds
# or fails.
set -euo pipefail

REPOSITORY="${FLOWPEEK_REPOSITORY:-FlowPeek/flowpeek}"
# The team, not the name: a team id names exactly one certificate.
EXPECTED_TEAM="${FLOWPEEK_TEAM_ID:-F7WUT95TT6}"

command -v gh >/dev/null || { print -u2 "gh is required: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { print -u2 "Run 'gh auth login' first."; exit 1; }

work="$(mktemp -d /private/tmp/flowpeek-signing.XXXXXX)"
chmod 700 "$work"
cleanup() {
  security delete-keychain "$work/verify.keychain-db" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

archive="$work/identity.p12"

if [[ -n "${FLOWPEEK_P12:-}" ]]; then
  [[ -f "$FLOWPEEK_P12" ]] || { print -u2 "No such file: $FLOWPEEK_P12"; exit 1; }
  cp "$FLOWPEEK_P12" "$archive"
  print "Using $FLOWPEEK_P12"
  print -n "Password for that .p12: "
  read -rs password
  print ""
else
  available=$(security find-identity -v -p codesigning | grep "Developer ID Application" || true)
  if [[ -z "$available" ]]; then
    print -u2 "No Developer ID Application identity in the keychain."
    print -u2 "Download it in Xcode > Settings > Accounts."
    exit 1
  fi
  if [[ $(print -r -- "$available" | wc -l) -gt 1 ]]; then
    print -u2 "This keychain holds more than one Developer ID certificate:"
    print -u2 "$available"
    print -u2 ""
    print -u2 "'security export' cannot pick one -- it exports them all -- so exporting here would"
    print -u2 "put every certificate, including ones that are not yours to publish, into a secret."
    print -u2 ""
    print -u2 "Export just the right one from Keychain Access (right-click the certificate for team"
    print -u2 "$EXPECTED_TEAM > Export > .p12), then re-run:"
    print -u2 "  FLOWPEEK_P12=/path/to/exported.p12 zsh Scripts/upload_signing_secrets.sh"
    exit 1
  fi
  print "Exporting: $(print -r -- "$available" | sed 's/^ *[0-9]*) [0-9A-F]* //')"
  password="$(uuidgen)"
  print "\nmacOS will ask permission to export the private key. Choose Allow.\n"
  if ! security export -t identities -f pkcs12 -P "$password" -o "$archive" 2>"$work/error"; then
    print -u2 "Export failed: $(cat "$work/error")"
    print -u2 "'User canceled' means the approval sheet was dismissed; run this again and choose Allow."
    exit 1
  fi
fi

[[ -s "$archive" ]] || { print -u2 "The .p12 is empty."; exit 1; }

# Prove what is actually inside before it becomes a secret.
verify="$work/verify.keychain-db"
verify_password="$(uuidgen)"
security create-keychain -p "$verify_password" "$verify"
security unlock-keychain -p "$verify_password" "$verify"
if ! security import "$archive" -k "$verify" -P "$password" -T /usr/bin/codesign >/dev/null 2>"$work/import"; then
  print -u2 "The .p12 would not import: $(cat "$work/import")"
  print -u2 "A wrong password is the usual cause."
  exit 1
fi

contents=$(security find-identity -v -p codesigning "$verify" | grep '"' || true)
count=$(print -r -- "$contents" | grep -c '"' || true)
print "\nThe archive contains $count signing identity/identities:"
print -r -- "$contents"

if [[ "$count" -ne 1 ]]; then
  print -u2 "\nRefusing to upload: exactly one identity is required, found $count."
  print -u2 "Export only the certificate for team $EXPECTED_TEAM and re-run with FLOWPEEK_P12=..."
  exit 1
fi
if ! print -r -- "$contents" | grep -q "Developer ID Application"; then
  print -u2 "\nRefusing to upload: that is not a Developer ID Application certificate."
  exit 1
fi
if ! print -r -- "$contents" | grep -q "($EXPECTED_TEAM)"; then
  print -u2 "\nRefusing to upload: the identity is not for team $EXPECTED_TEAM."
  print -u2 "Set FLOWPEEK_TEAM_ID if the release really should be signed by another team."
  exit 1
fi
print "Verified: exactly one Developer ID Application identity, team $EXPECTED_TEAM."

base64 -i "$archive" | gh secret set MACOS_CERTIFICATE_P12 --repo "$REPOSITORY"
printf '%s' "$password" | gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$REPOSITORY"
print "\nSet MACOS_CERTIFICATE_P12 and MACOS_CERTIFICATE_PASSWORD on $REPOSITORY."
