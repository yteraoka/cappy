# Distribution

English | [日本語](./distribution.ja.md)

cappy is distributed through a Homebrew tap (`Formula/cappy.rb` and `Formula/gcappy.rb` in [`yteraoka/homebrew-cask`](https://github.com/yteraoka/homebrew-cask)).

```bash
brew install yteraoka/cask/cappy     # CLI
brew install yteraoka/cask/gcappy    # menu bar app
```

- Installs a prebuilt binary (Apple Silicon, macOS 15 or later) from GitHub Releases, together with the bash / zsh completion scripts.
- The binary is ad-hoc signed (Hardened Runtime, with the microphone input entitlement). Files installed by a formula get no quarantine attribute, so it runs without notarization. The recording and microphone permissions are granted to the terminal app you run cappy from.
- gcappy installs `gcappy.app` (with cappy bundled as `Contents/MacOS/cappy`) into `$(brew --prefix gcappy)`, and a `gcappy` command that starts it with `open`. It is a formula rather than a cask so that the ad-hoc signed app gets no quarantine attribute. The recording and microphone permissions are granted to gcappy.

## Release flow

1. When a PR is merged into main, tagpr (`.github/workflows/tagpr.yaml`) opens a release PR. The version in `Sources/CappyKit/Core/Version.swift` is also updated in this PR (`minor` / `major` labels change the increment).
2. When the release PR is merged, tagpr creates the `vX.Y.Z` tag and a GitHub Release.
3. Pushing the tag runs `.github/workflows/release.yaml` (macOS runner):
   1. Runs the tests
   2. Builds the ad-hoc signed `cappy-X.Y.Z-macos-arm64.zip` and `gcappy-X.Y.Z-macos-arm64.zip` (gcappy.app assembled by `scripts/build-app.sh`) with `scripts/release.sh` and attaches them to the Release
   3. Rewrites the url and sha256 of `packaging/cappy.rb` / `packaging/gcappy.rb` with `scripts/formula.sh` and updates `Formula/cappy.rb` / `Formula/gcappy.rb` in the tap
4. For PRs, the same workflow only runs the tests and the release build.

Required settings (Settings > Secrets and variables > Actions of the cappy repository):

| Type | Name | Content |
| --- | --- | --- |
| Variable | `TAGPR_APP_ID` | Client ID of the GitHub App for tagpr |
| Secret | `TAGPR_APP_PRIVATE_KEY` | Private key of the same App |
| Variable | `HOMEBREW_APP_ID` | Client ID of the GitHub App used to create the Release and update the tap (Contents: Read and write) |
| Secret | `HOMEBREW_APP_PRIVATE_KEY` | Private key of the same App |

Install both Apps on cappy, and the `HOMEBREW_APP_ID` App also on `homebrew-cask`.

## Local build

```bash
CAPPY_SIGN_IDENTITY=- make release     # ad-hoc signed dist/cappy-<version>-macos-arm64.zip and dist/gcappy-<version>-macos-arm64.zip
scripts/formula.sh <version> <sha256>  # prints the formula for the tap
scripts/formula.sh <version> <sha256> gcappy
make app                               # builds only dist/gcappy.app

# To sign with Developer ID and notarize (for distribution outside Homebrew)
export CAPPY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export CAPPY_NOTARY_PROFILE=cappy-notary   # created with xcrun notarytool store-credentials
make release
```

## Preparing a Developer ID certificate and a notarization API key

When signed with Developer ID, the designated requirement (DR) of the signature is based on the bundle ID and the team ID. macOS privacy permissions (system audio recording, microphone, ...) are therefore kept across version upgrades. With ad-hoc signing, the DR is the hash of the binary, so the permissions have to be granted again after every build.

### Developer ID Application certificate

Only the Account Holder of the Apple Developer Program can create Developer ID certificates. A certificate is valid for 5 years and the number per team is limited, so keep the certificate together with its private key.

From Xcode:

1. Add your Apple ID in Xcode > Settings… > Accounts.
2. Select the team, open Manage Certificates…, and choose Developer ID Application from the + at the bottom left. The private key and the certificate are added to the login keychain.

From the web (developer.apple.com):

1. In Keychain Access (`open -a "Keychain Access"`), choose Keychain Access > Certificate Assistant > Request a Certificate From a Certificate Authority…. Enter your email address and a common name, leave the CA email address empty, and choose "Saved to disk" to save the CSR. The private key is created in the login keychain of this Mac.
2. In [Certificates](https://developer.apple.com/account/resources/certificates/list), click +, choose Developer ID Application, and choose the G2 Sub-CA profile type. Upload the CSR, and double-click the downloaded `.cer` on the Mac that created the CSR.

Check:

```bash
security find-identity -v -p codesigning
```

You are done when `"Developer ID Application: Your Name (TEAMID)"` is listed. Set this string as `CAPPY_SIGN_IDENTITY`. If it is not listed, or the certificate shows as not trusted, import the Developer ID - G2 intermediate certificate from [Apple PKI](https://www.apple.com/certificateauthority/).

After signing, `codesign -d -r- dist/gcappy.app` shows the DR. If it contains `certificate leaf[subject.OU] = "TEAMID"`, the permissions are kept after upgrades.

To use it on another Mac or in CI, check in "My Certificates" of Keychain Access that the private key is under the certificate, then right-click > Export… and export it as `.p12` (Personal Information Exchange) with a password.

Errors when creating it:

| Error | What to do |
| --- | --- |
| `Unable to process request - PLA Update available` | The Program License Agreement has been updated. Sign in to [developer.apple.com/account](https://developer.apple.com/account) and accept the agreement from the banner. If App Store Connect > Business has agreements to accept, accept them too. |
| `This operation can only be performed by the Account Holder.` | Your role in the selected team is not Account Holder. Check the role in Membership details. Xcode may show an Account Holder as Admin and fail; in that case remove and re-add the account in Xcode, or create the certificate on the web. |

### Notarization API key

Notarization uses an App Store Connect API key.

1. In [App Store Connect > Users and Access > Integrations](https://appstoreconnect.apple.com/access/integrations/api), click + under Team Keys and create a key with Developer access.
2. Download `AuthKey_<Key ID>.p8`. It can be downloaded only once. Also note the Key ID and the Issuer ID shown on the page.
3. Store it in the keychain as a notarytool profile:

   ```bash
   xcrun notarytool store-credentials cappy-notary \
     --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```

4. Running `make release` with `CAPPY_NOTARY_PROFILE=cappy-notary` signs and then notarizes (see "Local build").

The `.p12` and `.p8` files are secrets. Keep them out of the repository, for example in a password manager. If one leaks, revoke the certificate on developer.apple.com and revoke the API key in App Store Connect.
