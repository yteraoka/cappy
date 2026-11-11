#!/bin/bash
# Developer ID で署名し、公証（notarization）した配布用 zip を dist/ に作る。
#
# 必要な環境変数:
#   CAPPY_SIGN_IDENTITY   例: "Developer ID Application: Your Name (TEAMID)"
#   CAPPY_NOTARY_PROFILE  `xcrun notarytool store-credentials` で保存したプロファイル名
# 任意:
#   CAPPY_ARCHS           既定 "arm64"（"arm64 x86_64" でユニバーサル）
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
IDENTITY="${CAPPY_SIGN_IDENTITY:?CAPPY_SIGN_IDENTITY を設定してください}"
NOTARY_PROFILE="${CAPPY_NOTARY_PROFILE:?CAPPY_NOTARY_PROFILE を設定してください}"
ARCHS="${CAPPY_ARCHS:-arm64}"

cd "$(dirname "$0")/.."
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done

swift build -c release "${ARCH_FLAGS[@]}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/cappy"

mkdir -p dist
cp "$BIN" dist/cappy

# Info.plist は -sectcreate で埋め込み済み。--identifier を Info.plist の CFBundleIdentifier と揃える
codesign --force --timestamp --options runtime \
  --identifier dev.cappy.cli \
  --entitlements Support/cappy.entitlements \
  --sign "$IDENTITY" dist/cappy
codesign --verify --strict --verbose=2 dist/cappy

ZIP="dist/cappy-${VERSION}-macos-$(echo "$ARCHS" | tr ' ' '-').zip"
rm -f "$ZIP"
ditto -c -k --keepParent dist/cappy "$ZIP"

xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
# 単体バイナリには staple できないため、Gatekeeper はオンラインで公証を確認する
spctl --assess --type install --verbose dist/cappy || true

shasum -a 256 "$ZIP"
echo "完成: $ZIP"
echo "Homebrew の formula（packaging/cappy.rb）の url と sha256 を更新してください"
