#!/bin/bash
# 配布用の zip を dist/ に作る（CLI の cappy と、メニューバー版の gcappy.app）。
#
# 環境変数:
#   CAPPY_SIGN_IDENTITY   署名に使う ID。"-" なら ad-hoc 署名
#                         例: "Developer ID Application: Your Name (TEAMID)"
#   CAPPY_NOTARY_PROFILE  公証に使う、`xcrun notarytool store-credentials` で保存したプロファイル名。
#                         Developer ID で署名し、これを設定した場合だけ公証する
#   CAPPY_NOTARY_KEYCHAIN 上のプロファイルを既定以外のキーチェーンに保存した場合、そのキーチェーンのパス
#   CAPPY_ARCHS           既定 "arm64"（"arm64 x86_64" でユニバーサル）
#
# GitHub Actions の中では、zip のパスと SHA-256 を $GITHUB_OUTPUT（zip / sha256、gcappy は app_zip / app_sha256）に書く。
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
IDENTITY="${CAPPY_SIGN_IDENTITY:?CAPPY_SIGN_IDENTITY を設定してください（ad-hoc 署名なら "-"）}"
ARCHS="${CAPPY_ARCHS:-arm64}"
ADHOC=false
[[ "$IDENTITY" == "-" ]] && ADHOC=true
NOTARY_PROFILE="${CAPPY_NOTARY_PROFILE:-}"
NOTARIZE=false
if [[ -n "$NOTARY_PROFILE" ]]; then
  if $ADHOC; then
    echo "ad-hoc 署名では公証できません（CAPPY_NOTARY_PROFILE を外すか、Developer ID で署名してください）" >&2
    exit 1
  fi
  NOTARIZE=true
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  [[ -n "${CAPPY_NOTARY_KEYCHAIN:-}" ]] && NOTARY_ARGS+=(--keychain "$CAPPY_NOTARY_KEYCHAIN")
fi

# 公証に出して結果を待つ。Accepted 以外ならログを出して失敗にする
notarize() {
  local result status
  result="$(xcrun notarytool submit "$1" "${NOTARY_ARGS[@]}" --wait --output-format json)"
  status="$(jq -r .status <<<"$result")"
  if [[ "$status" != "Accepted" ]]; then
    echo "公証に失敗しました（$1: $status）" >&2
    xcrun notarytool log "$(jq -r .id <<<"$result")" "${NOTARY_ARGS[@]}" >&2 || true
    exit 1
  fi
  echo "公証済み: $1"
}

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

if $NOTARIZE; then
  # 単体バイナリには staple できないため、Gatekeeper はオンラインで公証を確認する
  notarize "$ZIP"
fi

SHA256="$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)"
echo "$SHA256  $(basename "$ZIP")" > "$ZIP.sha256"

# gcappy.app（cappy を同梱したメニューバー版）
CAPPY_SIGN_IDENTITY="$IDENTITY" CAPPY_ARCHS="$ARCHS" scripts/build-app.sh "$VERSION"
APP_ZIP="dist/gcappy-${VERSION}-macos-$(echo "$ARCHS" | tr ' ' '-').zip"
# Homebrew は展開した中身がディレクトリ 1 つだけだとその中に移動するため、LICENSE と並べて zip にする
make_app_zip() {
  local stage
  stage="$(mktemp -d)"
  ditto dist/gcappy.app "$stage/gcappy.app"
  cp LICENSE "$stage/LICENSE"
  rm -f "$APP_ZIP"
  ditto -c -k "$stage" "$APP_ZIP"
  rm -rf "$stage"
}
make_app_zip
if $NOTARIZE; then
  notarize "$APP_ZIP"
  xcrun stapler staple dist/gcappy.app
  spctl --assess --type execute --verbose dist/gcappy.app
  make_app_zip
fi
APP_SHA256="$(shasum -a 256 "$APP_ZIP" | cut -d ' ' -f 1)"
echo "$APP_SHA256  $(basename "$APP_ZIP")" > "$APP_ZIP.sha256"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  { echo "zip=$ZIP"; echo "sha256=$SHA256"; echo "app_zip=$APP_ZIP"; echo "app_sha256=$APP_SHA256"; } >> "$GITHUB_OUTPUT"
fi
echo "完成: $ZIP"
echo "SHA-256: $SHA256"
echo "formula: scripts/formula.sh $VERSION $SHA256"
echo "完成: $APP_ZIP"
echo "SHA-256: $APP_SHA256"
echo "formula: scripts/formula.sh $VERSION $APP_SHA256 gcappy"
