#!/bin/bash
# gcappy.app（メニューバー版）を dist/gcappy.app に組み立てて署名する。cappy も Contents/MacOS/cappy に同梱する。
# usage: scripts/build-app.sh <version>
#
# 環境変数（scripts/release.sh と同じ）:
#   CAPPY_SIGN_IDENTITY   署名に使う ID（既定 "-" = ad-hoc 署名）
#   CAPPY_ARCHS           既定 "arm64"（"arm64 x86_64" でユニバーサル）
set -euo pipefail

VERSION="${1:?usage: scripts/build-app.sh <version>}"
IDENTITY="${CAPPY_SIGN_IDENTITY:--}"
ARCHS="${CAPPY_ARCHS:-arm64}"

cd "$(dirname "$0")/.."
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done

swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP=dist/gcappy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/gcappy" "$APP/Contents/MacOS/gcappy"
cp "$BIN_DIR/cappy" "$APP/Contents/MacOS/cappy"
cp Support/gcappy/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

SIGN_FLAGS=(--force --options runtime --entitlements Support/cappy.entitlements --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && SIGN_FLAGS+=(--timestamp)

# 内側から署名する（同梱の cappy → アプリ本体）。cappy の --identifier は埋め込みの Info.plist と揃える
codesign "${SIGN_FLAGS[@]}" --identifier dev.cappy.cli "$APP/Contents/MacOS/cappy"
codesign "${SIGN_FLAGS[@]}" --identifier dev.cappy.gcappy "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"
test "$("$APP/Contents/MacOS/cappy" --version)" = "$VERSION"
echo "built $APP ($VERSION)"
