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

The workflow needs six or seven repository secrets. Set them with `gh secret set`, which prompts for
the value rather than taking it on the command line, so nothing lands in your shell history.

### Signing

FlowPeek is signed with `Developer ID Application: KANG SEUNGHYUN (F7WUT95TT6)`. Export it from
Keychain Access (right-click the certificate → Export → `.p12`, set a password), then:

```sh
base64 -i FlowPeek-DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12 --repo FlowPeek/flowpeek
gh secret set MACOS_CERTIFICATE_PASSWORD --repo FlowPeek/flowpeek   # the .p12 export password
```

The runner imports this into a throwaway keychain that is destroyed with the job.

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

### Tap access

`GITHUB_TOKEN` cannot write to another repository, so pushing the cask needs a token that can.
Create a fine-grained personal access token scoped to `FlowPeek/homebrew-tap` with
**Contents: Read and write**, then:

```sh
gh secret set TAP_TOKEN --repo FlowPeek/flowpeek
```

If `TAP_TOKEN` is missing the release still publishes; only the tap update is skipped, with a
warning in the job log.

## What the workflow checks before it publishes

Each of these fails the run rather than shipping something broken:

- **Xcode 26 or newer.** `AppIcon.icon` is an Icon Composer document and only Xcode 26's `actool`
  compiles it. The step prints every Xcode it found and the version it picked.
- **`swift test` and `Scripts/conformance.mjs`.** The conformance script loads the vendored
  `mermaid.min.js` in a bare `vm` context and asserts it has no dynamic imports, no workers and no
  `eval`, and that its diagram registry still matches the Swift detector table.
- **The checked-in `FlowPeek.xcodeproj` matches `Scripts/generate_xcodeproj.rb`.** A stale project
  is how a source file ends up compiling under SPM and silently vanishing from the shipping app.
- **The exported app really contains** `AppIcon.icns`, `Assets.car`, `mermaid.min.js`,
  `flowpeek-glue.js` and both `.lproj` directories.
- **`codesign --verify --deep --strict` and `spctl --assess`**, from `Scripts/notarize_dmg.sh`,
  before and after stapling.

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

- `Config/Info.plist` carries the literal `REPLACE_WITH_SPARKLE_ED25519_PUBLIC_KEY` and no
  `SUFeedURL`, so Sparkle stays inactive. In-app updates need an EdDSA key pair and a published
  appcast — `Updates/appcast.xml.example` shows the shape.
- The release runs on `macos-15`. If that image stops shipping Xcode 26, switch `runs-on` to the
  image that does; the Xcode check will tell you plainly rather than producing an iconless app.
