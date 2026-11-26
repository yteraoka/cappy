# Distribution

English | [日本語](./distribution.ja.md)

cappy is distributed through a Homebrew tap (`Formula/cappy.rb` and `Formula/gcappy.rb` in [`yteraoka/homebrew-cask`](https://github.com/yteraoka/homebrew-cask)).

```bash
brew install yteraoka/cask/cappy     # CLI
brew install yteraoka/cask/gcappy    # menu bar app
```

- Installs a prebuilt binary (Apple Silicon, macOS 15 or later) from GitHub Releases, together with the bash / zsh completion scripts.
- The binary is signed with Developer ID and notarized (Hardened Runtime, with the microphone input entitlement). The recording and microphone permissions are granted to the terminal app you run cappy from.
- gcappy installs `gcappy.app` (with cappy bundled as `Contents/MacOS/cappy`) into `$(brew --prefix gcappy)`, and a `gcappy` command that starts it with `open`. The recording and microphone permissions are granted to gcappy.

## Release flow

1. When a PR is merged into main, tagpr (`.github/workflows/tagpr.yaml`) opens a release PR. The version in `Sources/CappyKit/Core/Version.swift` is also updated in this PR (`minor` / `major` labels change the increment).
2. When the release PR is merged, tagpr creates the `vX.Y.Z` tag and a GitHub Release.
3. Pushing the tag runs `.github/workflows/release.yaml` (macOS runner):
   1. Runs the tests
   2. Builds the Developer ID signed and notarized `cappy-X.Y.Z-macos-arm64.zip` and `gcappy-X.Y.Z-macos-arm64.zip` (gcappy.app assembled by `scripts/build-app.sh`) with `scripts/release.sh` and attaches them to the Release
   3. Rewrites the url and sha256 of `packaging/cappy.rb` / `packaging/gcappy.rb` with `scripts/formula.sh` and updates `Formula/cappy.rb` / `Formula/gcappy.rb` in the tap
4. For PRs, the same workflow only runs the tests and the release build. PRs that can read the secrets are notarized as well, and PRs that cannot (such as PRs from forks) build with ad-hoc signing (without notarization).

Required settings (Settings > Secrets and variables > Actions of the cappy repository):

| Type | Name | Content |
| --- | --- | --- |
| Variable | `TAGPR_APP_ID` | Client ID of the GitHub App for tagpr |
| Secret | `TAGPR_APP_PRIVATE_KEY` | Private key of the same App |
| Variable | `HOMEBREW_APP_ID` | Client ID of the GitHub App used to create the Release and update the tap (Contents: Read and write) |
| Secret | `HOMEBREW_APP_PRIVATE_KEY` | Private key of the same App |
| Secret | `MACOS_CERT_P12_BASE64` | Base64 of the .p12 exported with the Developer ID Application certificate and its private key |
| Secret | `MACOS_CERT_PASSWORD` | Password of the .p12 (not needed if it has none) |
| Secret | `MACOS_SIGN_IDENTITY` | Signing identity (e.g. `Developer ID Application: Your Name (TEAMID)`) |
| Secret | `NOTARY_KEY_BASE64` | Base64 of the App Store Connect API key (.p8) used for notarization |
| Secret | `NOTARY_KEY_ID` | Key ID of the same API key |
| Secret | `NOTARY_ISSUER_ID` | Issuer ID of the same API key |

Install both Apps on cappy, and the `HOMEBREW_APP_ID` App also on `homebrew-cask`.

## Local build

```bash
CAPPY_SIGN_IDENTITY=- make release     # ad-hoc signed dist/cappy-<version>-macos-arm64.zip and dist/gcappy-<version>-macos-arm64.zip
scripts/formula.sh <version> <sha256>  # prints the formula for the tap
scripts/formula.sh <version> <sha256> gcappy
make app                               # builds only dist/gcappy.app

# To sign with Developer ID
export CAPPY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
# To notarize as well
export CAPPY_NOTARY_PROFILE=cappy-notary   # created with xcrun notarytool store-credentials
make release
```
