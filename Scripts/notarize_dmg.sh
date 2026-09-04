#!/bin/zsh
set -euo pipefail

: "${FLOWPEEK_APP_PATH:?Set FLOWPEEK_APP_PATH to the exported FlowPeek.app}"
: "${FLOWPEEK_DMG_PATH:?Set FLOWPEEK_DMG_PATH to the output .dmg path}"
: "${FLOWPEEK_NOTARY_PROFILE:?Set FLOWPEEK_NOTARY_PROFILE to a notarytool Keychain profile}"
# CI stores the profile in a throwaway keychain, so notarytool has to be told where to look.
notary_keychain_arguments=()
if [[ -n "${FLOWPEEK_NOTARY_KEYCHAIN:-}" ]]; then
  notary_keychain_arguments=(--keychain "$FLOWPEEK_NOTARY_KEYCHAIN")
fi

codesign --verify --deep --strict --verbose=2 "$FLOWPEEK_APP_PATH"
spctl --assess --type execute --verbose=2 "$FLOWPEEK_APP_PATH"

staging_directory="$(mktemp -d /private/tmp/flowpeek-dmg.XXXXXX)"
trap 'rm -rf "$staging_directory"' EXIT
ditto "$FLOWPEEK_APP_PATH" "$staging_directory/FlowPeek.app"
ln -s /Applications "$staging_directory/Applications"
hdiutil create -volname FlowPeek -srcfolder "$staging_directory" -ov -format UDZO "$FLOWPEEK_DMG_PATH"
xcrun notarytool submit "$FLOWPEEK_DMG_PATH" \
  --keychain-profile "$FLOWPEEK_NOTARY_PROFILE" \
  "${notary_keychain_arguments[@]}" \
  --wait
xcrun stapler staple "$FLOWPEEK_DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$FLOWPEEK_DMG_PATH"
