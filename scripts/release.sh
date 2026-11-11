#!/bin/bash
# 配布用の zip を dist/ に作る。
#
# 環境変数:
#   CAPPY_SIGN_IDENTITY   署名に使う ID。"-" なら ad-hoc 署名で、公証は行わない（Homebrew での配布向け）。
#                         例: "Developer ID Application: Your Name (TEAMID)"（この場合は公証まで行う）
#   CAPPY_NOTARY_PROFILE  Developer ID で署名する場合に必要。`xcrun notarytool store-credentials` で保存したプロファイル名
#   CAPPY_ARCHS           既定 "arm64"（"arm64 x86_64" でユニバーサル）
#
# GitHub Actions の中では、zip のパスと SHA-256 を $GITHUB_OUTPUT（zip / sha256）に書く。
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
IDENTITY="${CAPPY_SIGN_IDENTITY:?CAPPY_SIGN_IDENTITY を設定してください（ad-hoc 署名なら "-"）}"
ARCHS="${CAPPY_ARCHS:-arm64}"
ADHOC=false
[[ "$IDENTITY" == "-" ]] && ADHOC=true
if ! $ADHOC; then
  NOTARY_PROFILE="${CAPPY_NOTARY_PROFILE:?Developer ID で署名する場合は CAPPY_NOTARY_PROFILE を設定してください}"
fi

cd "$(dirname "$0")/.."
SOURCE_VERSION="$(sed -n 's/.*current = "\(.*\)"/\1/p' Sources/CappyKit/Core/Version.swift)"
if [[ "$SOURCE_VERSION" != "$VERSION" ]]; then
  echo "バージョンが一致しません: 指定 $VERSION / Version.swift $SOURCE_VERSION" >&2
  exit 1
fi

ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done

swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/cappy"

rm -rf dist
mkdir -p dist
cp "$BIN" dist/cappy

# Info.plist は -sectcreate で埋め込み済み。--identifier を Info.plist の CFBundleIdentifier と揃える
if $ADHOC; then
  codesign --force --options runtime --identifier dev.cappy.cli \
    --entitlements Support/cappy.entitlements --sign - dist/cappy
else
  codesign --force --timestamp --options runtime --identifier dev.cappy.cli \
    --entitlements Support/cappy.entitlements --sign "$IDENTITY" dist/cappy
fi
codesign --verify --strict --verbose=2 dist/cappy
test "$(dist/cappy --version)" = "$VERSION"

ZIP="dist/cappy-${VERSION}-macos-$(echo "$ARCHS" | tr ' ' '-').zip"
ditto -c -k --keepParent dist/cappy "$ZIP"

if ! $ADHOC; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  # 単体バイナリには staple できないため、Gatekeeper はオンラインで公証を確認する
  spctl --assess --type install --verbose dist/cappy || true
fi

SHA256="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
echo "$SHA256  $(basename "$ZIP")" > "$ZIP.sha256"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  { echo "zip=$ZIP"; echo "sha256=$SHA256"; } >> "$GITHUB_OUTPUT"
fi
echo "完成: $ZIP"
echo "SHA-256: $SHA256"
echo "formula: scripts/formula.sh $VERSION $SHA256"
