# Releasing FlowPeek

Pushing a `v*` tag is the whole release. `.github/workflows/release.yml` builds, signs, notarizes
and publishes the app, then rewrites `version` and `sha256` in
[FlowPeek/homebrew-tap](https://github.com/FlowPeek/homebrew-tap)'s `Casks/flowpeek.rb`.

```sh
git tag v0.1.0
git push origin v0.1.0
```

The version in the tag becomes `CFBundleShortVersionString`; the workflow run number becomes
`CFBundleVersion`. Neither is stored in the repository, so a tag is the only thing to bump.

## One-time setup

The workflow needs four or five repository secrets. `TAP_DEPLOY_KEY` is already set — see
[Tap access](#tap-access). The rest need values only you can produce; set them with `gh secret set`,
which reads from stdin rather than the command line, so nothing lands in your shell history.

### Signing

FlowPeek is signed with `Developer ID Application: KANG SEUNGHYUN (F7WUT95TT6)`. One command does
the whole thing:

```sh
zsh Scripts/upload_signing_secrets.sh
```

It exports the identity, checks that the archive really imports as a Developer ID identity, uploads
it as `MACOS_CERTIFICATE_P12`, and uploads a freshly generated export password as
`MACOS_CERTIFICATE_PASSWORD`. Everything lives in a private temp directory that is removed on exit.

macOS raises a GUI approval sheet for the private key, which is why this step cannot be scripted for
you: choose **Allow** when it appears. The runner imports the archive into a throwaway keychain that
is destroyed with the job.

### Notarization

Either credential shape works. The workflow uses whichever is present, preferring the API key.

**App Store Connect API key** (recommended for CI — does not expire with your password):
create one at App Store Connect → Users and Access → Integrations → App Store Connect API, with the
*Developer* role, then:

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_API_KEY --repo FlowPeek/flowpeek
gh secret set NOTARY_API_KEY_ID    --repo FlowPeek/flowpeek   # the 10-character Key ID
gh secret set NOTARY_API_ISSUER_ID --repo FlowPeek/flowpeek   # the UUID shown above the key list
```

**Or an app-specific password** (quicker to set up): create one at
[appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords.

```sh
gh secret set NOTARY_APPLE_ID --repo FlowPeek/flowpeek   # the Apple ID that owns team F7WUT95TT6
gh secret set NOTARY_PASSWORD --repo FlowPeek/flowpeek   # the app-specific password
gh secret set NOTARY_TEAM_ID  --repo FlowPeek/flowpeek   # F7WUT95TT6
```

### In-app updates

**Already done.** `SPARKLE_PRIVATE_KEY` holds the EdDSA private key that signs each update; the
public half is `SUPublicEDKey` in `Config/Info.plist`. The workflow zips the stapled app, signs it
with `sign_update`, writes a single-item `appcast.xml`, and uploads both to the release.

`SUFeedURL` points at `releases/latest/download/appcast.xml`, which GitHub redirects to the newest
release — so the feed URL never changes and needs no hosting of its own. Sparkle checks daily.

If `SPARKLE_PRIVATE_KEY` is missing the release still publishes, with a warning, but in-app updates
will not see that version. To rotate the key, run `generate_keys` from Sparkle's artifact bundle
(`.build/artifacts/sparkle/Sparkle/bin`), put the new public key in `Config/Info.plist`, and
`generate_keys -x` the private half into the secret. Rotating invalidates updates for anyone still
on a build carrying the old public key, so prefer not to.

### Tap access

**Already done.** `GITHUB_TOKEN` cannot write to another repository, so the cask is pushed with an
ed25519 deploy key that is scoped to `FlowPeek/homebrew-tap` alone — narrower than a personal access
token, which would carry write access to everything the author can reach.

The public half is registered on the tap with write access; the private half is the
`TAP_DEPLOY_KEY` secret. Both read and write were verified against the live repository before the
key was stored. To rotate it:

```sh
ssh-keygen -t ed25519 -N "" -C "flowpeek-release@github-actions" -f /tmp/tap_key
gh api -X POST /repos/FlowPeek/homebrew-tap/keys \
  -f title="flowpeek release workflow" -f key="$(cat /tmp/tap_key.pub)" -F read_only=false
gh secret set TAP_DEPLOY_KEY --repo FlowPeek/flowpeek < /tmp/tap_key
rm -f /tmp/tap_key /tmp/tap_key.pub
# then delete the superseded key id listed by:
gh api /repos/FlowPeek/homebrew-tap/keys --jq '.[] | "\(.id)  \(.title)"'
```

If `TAP_DEPLOY_KEY` is missing the release still publishes; only the tap update is skipped, with a
warning in the job log.

## What the workflow checks before it publishes

Each of these fails the run rather than shipping something broken:

- **Xcode 26 or newer.** `AppIcon.icon` is an Icon Composer document and only Xcode 26's `actool`
  compiles it. The step prints every Xcode it found and the version it picked, then `xcode-select`s
  it, so the run never depends on the image's default.
- **`swift test` and `Scripts/conformance.mjs`.** The conformance script loads the vendored
  `mermaid.min.js` in a bare `vm` context and asserts it has no dynamic imports, no workers and no
  `eval`, and that its diagram registry still matches the Swift detector table.
- **The checked-in `FlowPeek.xcodeproj` matches `Scripts/generate_xcodeproj.rb`.** A stale project
  is how a source file ends up compiling under SPM and silently vanishing from the shipping app.
- **The exported app really contains** `AppIcon.icns`, `Assets.car`, `mermaid.min.js`,
  `flowpeek-glue.js` and both `.lproj` directories.
- **`codesign --verify --deep --strict`** before notarization, then **`spctl --assess`** on both the
  stapled app and the stapled DMG afterwards. `Scripts/notarize_dmg.sh` notarizes and staples the
  app *before* packaging it: a DMG's ticket stays with the DMG, and Homebrew copies the app out, so
  an unstapled app would need the online notary check on every first launch.

## Verifying a release by hand

```sh
brew update && brew install --cask flowpeek/tap/flowpeek
codesign -dvv --verbose=4 /Applications/FlowPeek.app 2>&1 | grep -E "Authority|TeamIdentifier"
spctl --assess --type execute --verbose=2 /Applications/FlowPeek.app
xcrun stapler validate /Applications/FlowPeek.app
```

`Authority` should name `Developer ID Application: KANG SEUNGHYUN (F7WUT95TT6)` and `spctl` should
say `accepted / source=Notarized Developer ID`.

## Still to do before a public v1

- The release runs on `macos-26`, which ships Xcode 26.0.1 through 26.6 and defaults to 26.6.
  `macos-15` would also work — it carries 26.0.1 through 26.3 — but defaults to Xcode 16.4, so the
  workflow's "newest Xcode" step is doing real work there. If an image ever drops Xcode 26 the run
  fails at that step rather than producing an app with no icon.
