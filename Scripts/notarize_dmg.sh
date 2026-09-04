#!/bin/zsh
# Notarizes the app, staples it, packages a DMG, notarizes and staples that too, and only then
# asserts Gatekeeper accepts both.
#
# The app is stapled before it is packaged on purpose. A DMG's ticket stays with the DMG, and
# Homebrew copies the app out of it -- an unstapled app then needs the online notary check on first
# launch, which fails on a machine that is offline or behind a filtering proxy.
#
#   FLOWPEEK_APP_PATH=... FLOWPEEK_DMG_PATH=... FLOWPEEK_NOTARY_PROFILE=... zsh Scripts/notarize_dmg.sh
set -euo pipefail

: "${FLOWPEEK_APP_PATH:?Set FLOWPEEK_APP_PATH to the exported FlowPeek.app}"
: "${FLOWPEEK_DMG_PATH:?Set FLOWPEEK_DMG_PATH to the output .dmg path}"
: "${FLOWPEEK_NOTARY_PROFILE:?Set FLOWPEEK_NOTARY_PROFILE to a notarytool Keychain profile}"

# CI stores the profile in a throwaway keychain, so notarytool has to be told where to look.
notary_arguments=(--keychain-profile "$FLOWPEEK_NOTARY_PROFILE")
if [[ -n "${FLOWPEEK_NOTARY_KEYCHAIN:-}" ]]; then
  notary_arguments+=(--keychain "$FLOWPEEK_NOTARY_KEYCHAIN")
fi

staging="$(mktemp -d /private/tmp/flowpeek-dmg.XXXXXX)"
trap 'rm -rf "$staging"' EXIT INT TERM

print "== verifying the signature =="
# Valid before notarization; spctl is not, so it is asserted at the end rather than here.
codesign --verify --deep --strict --verbose=2 "$FLOWPEEK_APP_PATH"

print "\n== notarizing the app =="
ditto -c -k --keepParent "$FLOWPEEK_APP_PATH" "$staging/FlowPeek.zip"
xcrun notarytool submit "$staging/FlowPeek.zip" "${notary_arguments[@]}" --wait
xcrun stapler staple "$FLOWPEEK_APP_PATH"
xcrun stapler validate "$FLOWPEEK_APP_PATH"

print "\n== packaging the DMG =="
mkdir -p "$staging/volume"
ditto "$FLOWPEEK_APP_PATH" "$staging/volume/FlowPeek.app"
ln -s /Applications "$staging/volume/Applications"
hdiutil create -volname FlowPeek -srcfolder "$staging/volume" -ov -format UDZO "$FLOWPEEK_DMG_PATH"

# Sign the image with the identity that signed the app, read back from the app rather than
# configured twice. Without this the disk image carries no signature, and the Gatekeeper assessment
# below reports "no usable signature" even though the image is notarized and stapled. Signing has to
# happen before notarization: re-signing would invalidate the staple.
identity="$(codesign -dvv "$FLOWPEEK_APP_PATH" 2>&1 | sed -n 's/^Authority=\(Developer ID Application.*\)$/\1/p' | head -1)"
if [[ -z "$identity" ]]; then
  print -u2 "Could not read a Developer ID authority from $FLOWPEEK_APP_PATH"
  exit 1
fi
print "signing the image as: $identity"
sign_arguments=(--sign "$identity" --timestamp)
if [[ -n "${FLOWPEEK_NOTARY_KEYCHAIN:-}" ]]; then
  sign_arguments+=(--keychain "$FLOWPEEK_NOTARY_KEYCHAIN")
fi
codesign "${sign_arguments[@]}" "$FLOWPEEK_DMG_PATH"
codesign --verify --strict --verbose=2 "$FLOWPEEK_DMG_PATH"

print "\n== notarizing the DMG =="
xcrun notarytool submit "$FLOWPEEK_DMG_PATH" "${notary_arguments[@]}" --wait
xcrun stapler staple "$FLOWPEEK_DMG_PATH"

print "\n== asserting Gatekeeper accepts both =="
# The app is what users end up running, and the DMG is what they download; assert each.
spctl --assess --type execute --verbose=2 "$FLOWPEEK_APP_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$FLOWPEEK_DMG_PATH"
print "\nStapled and accepted: $FLOWPEEK_DMG_PATH"
