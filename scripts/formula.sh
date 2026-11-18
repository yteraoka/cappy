#!/bin/bash
# packaging/<name>.rb の url（バージョン）と sha256 を書き換えた formula を標準出力に出す
# usage: scripts/formula.sh <version> <sha256> [cappy|gcappy]
set -euo pipefail
VERSION="${1:?usage: scripts/formula.sh <version> <sha256> [cappy|gcappy]}"
SHA256="${2:?usage: scripts/formula.sh <version> <sha256> [cappy|gcappy]}"
NAME="${3:-cappy}"
[[ "$SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo "sha256 が不正です: $SHA256" >&2; exit 1; }
[[ "$NAME" == "cappy" || "$NAME" == "gcappy" ]] || { echo "formula の名前が不正です: $NAME" >&2; exit 1; }
cd "$(dirname "$0")/.."
sed -e "s|^  url \".*\"|  url \"https://github.com/yteraoka/cappy/releases/download/v$VERSION/$NAME-$VERSION-macos-arm64.zip\"|" \
    -e "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" \
    -e "/^# Homebrew の tap/,/^# url と sha256/d" \
    "packaging/$NAME.rb"
