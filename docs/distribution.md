# Distribution

English | [日本語](./distribution.ja.md)

cappy is distributed through a Homebrew tap (`Formula/cappy.rb` in [`yteraoka/homebrew-cask`](https://github.com/yteraoka/homebrew-cask)).

```bash
brew install yteraoka/cask/cappy
```

- Installs a prebuilt binary (Apple Silicon, macOS 15 or later) from GitHub Releases, together with the bash / zsh completion scripts.
- The binary is ad-hoc signed (Hardened Runtime, with the microphone input entitlement). Files installed by a formula get no quarantine attribute, so it runs without notarization. The recording and microphone permissions are granted to the terminal app you run cappy from.

## Release flow

1. When a PR is merged into main, tagpr (`.github/workflows/tagpr.yaml`) opens a release PR. The version in `Sources/CappyKit/Core/Version.swift` is also updated in this PR (`minor` / `major` labels change the increment).
2. When the release PR is merged, tagpr creates the `vX.Y.Z` tag and a GitHub Release.
3. Pushing the tag runs `.github/workflows/release.yaml` (macOS runner):
   1. Runs the tests
   2. Builds the ad-hoc signed `cappy-X.Y.Z-macos-arm64.zip` with `scripts/release.sh` and attaches it to the Release
   3. Rewrites the url and sha256 of `packaging/cappy.rb` with `scripts/formula.sh` and updates `Formula/cappy.rb` in the tap
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
CAPPY_SIGN_IDENTITY=- make release     # ad-hoc signed dist/cappy-<version>-macos-arm64.zip
scripts/formula.sh <version> <sha256>  # prints the formula for the tap

# To sign with Developer ID and notarize (for distribution outside Homebrew)
export CAPPY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export CAPPY_NOTARY_PROFILE=cappy-notary   # created with xcrun notarytool store-credentials
make release
```
