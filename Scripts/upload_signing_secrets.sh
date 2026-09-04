#!/bin/zsh
# Exports the Developer ID identity and uploads it, plus a freshly generated export password, as the
# two signing secrets the release workflow needs.
#
# This cannot be automated end to end: macOS guards a private key with a keychain ACL, and
# `security export` raises a GUI approval sheet that a non-interactive shell cannot answer. Running
# this yourself is the one step that supplies that approval. Click "Allow" (not "Always Allow") when
# the sheet appears.
#
#   zsh Scripts/upload_signing_secrets.sh
#
# Nothing is written outside a private temporary directory, and that directory is removed on exit
# whether the script succeeds or fails.
set -euo pipefail

REPOSITORY="${FLOWPEEK_REPOSITORY:-FlowPeek/flowpeek}"
IDENTITY="${FLOWPEEK_SIGNING_IDENTITY:-Developer ID Application}"

command -v gh >/dev/null || { print -u2 "gh is required: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { print -u2 "Run 'gh auth login' first."; exit 1; }

matches=$(security find-identity -v -p codesigning | grep "$IDENTITY" || true)
if [[ -z "$matches" ]]; then
  print -u2 "No '$IDENTITY' identity in the keychain."
  print -u2 "Download it in Xcode > Settings > Accounts, or set FLOWPEEK_SIGNING_IDENTITY."
  exit 1
fi
if [[ $(print -r -- "$matches" | wc -l) -gt 1 ]]; then
  print -u2 "More than one '$IDENTITY' identity is present:"
  print -u2 "$matches"
  print -u2 "Set FLOWPEEK_SIGNING_IDENTITY to something that names exactly one, e.g. the team suffix."
  exit 1
fi
print "Exporting: $(print -r -- "$matches" | sed 's/^ *[0-9]*) [0-9A-F]* //')"

work="$(mktemp -d /private/tmp/flowpeek-signing.XXXXXX)"
trap 'rm -rf "$work"' EXIT INT TERM
chmod 700 "$work"

password="$(uuidgen)"
print "\nmacOS will now ask permission to export the private key. Choose Allow.\n"
if ! security export -t identities -f pkcs12 -P "$password" -o "$work/identity.p12" 2>"$work/error"; then
  print -u2 "Export failed: $(cat "$work/error")"
  print -u2 "If it says the operation was canceled, the approval sheet was dismissed; run this again."
  exit 1
fi
[[ -s "$work/identity.p12" ]] || { print -u2 "Export produced an empty file."; exit 1; }
print "Exported $(stat -f%z "$work/identity.p12") bytes."

# Confirm the archive really carries a usable identity before it becomes a secret, so a bad export
# is caught here rather than halfway through a release.
verify="$work/verify.keychain-db"
verify_password="$(uuidgen)"
security create-keychain -p "$verify_password" "$verify"
security unlock-keychain -p "$verify_password" "$verify"
security import "$work/identity.p12" -k "$verify" -P "$password" -T /usr/bin/codesign >/dev/null
if ! security find-identity -v -p codesigning "$verify" | grep -q "Developer ID Application"; then
  security delete-keychain "$verify"
  print -u2 "The exported archive does not contain a Developer ID Application identity."
  exit 1
fi
security delete-keychain "$verify"
print "Verified: the archive imports as a Developer ID Application identity."

base64 -i "$work/identity.p12" | gh secret set MACOS_CERTIFICATE_P12 --repo "$REPOSITORY"
printf '%s' "$password" | gh secret set MACOS_CERTIFICATE_PASSWORD --repo "$REPOSITORY"
print "\nSet MACOS_CERTIFICATE_P12 and MACOS_CERTIFICATE_PASSWORD on $REPOSITORY."
print "The password existed only in this process; re-run this script if you ever need it again."
