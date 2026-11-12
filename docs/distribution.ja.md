# 配布

[English](./distribution.md) | 日本語

Homebrew の tap（[`yteraoka/homebrew-cask`](https://github.com/yteraoka/homebrew-cask) の `Formula/cappy.rb`）で配布します。

```bash
brew install yteraoka/cask/cappy
```

- ビルド済みのバイナリ（Apple Silicon、macOS 15 以降）を GitHub Releases から入れます。bash / zsh の補完スクリプトも配置されます。
- バイナリは ad-hoc 署名（Hardened Runtime、マイク入力の entitlement 付き）です。formula で入れたファイルには quarantine 属性が付かないため、公証なしで実行できます。録音とマイクの許可は実行元のターミナルアプリに付きます。

## リリースの流れ

1. main に PR をマージすると、tagpr（`.github/workflows/tagpr.yaml`）がリリース用の PR を作ります。`Sources/CappyKit/Core/Version.swift` のバージョンもこの PR で更新されます（`minor` / `major` ラベルで上げ幅を変えられます）。
2. リリース用の PR をマージすると、tagpr が `vX.Y.Z` のタグと GitHub Release を作ります。
3. タグの push で `.github/workflows/release.yaml`（macOS の runner）が動きます。
   1. テストを実行する
   2. `scripts/release.sh` で ad-hoc 署名した `cappy-X.Y.Z-macos-arm64.zip` を作り、Release に添付する
   3. `scripts/formula.sh` で `packaging/cappy.rb` の url と sha256 を書き換え、tap の `Formula/cappy.rb` を更新する
4. PR では、同じワークフローでテストとリリース用のビルドだけを行います。

必要な設定（cappy リポジトリの Settings > Secrets and variables > Actions）:

| 種類 | 名前 | 内容 |
| --- | --- | --- |
| 変数 | `TAGPR_APP_ID` | tagpr 用の GitHub App の Client ID |
| シークレット | `TAGPR_APP_PRIVATE_KEY` | 同じ App の秘密鍵 |
| 変数 | `HOMEBREW_APP_ID` | Release の作成と tap の更新に使う GitHub App の Client ID（Contents: Read and write） |
| シークレット | `HOMEBREW_APP_PRIVATE_KEY` | 同じ App の秘密鍵 |

どちらの App も cappy にインストールし、`HOMEBREW_APP_ID` の App は `homebrew-cask` にもインストールしておきます。

## 手元でのビルド

```bash
CAPPY_SIGN_IDENTITY=- make release     # ad-hoc 署名の dist/cappy-<version>-macos-arm64.zip
scripts/formula.sh <version> <sha256>  # tap に置く formula を出力

# Developer ID で署名し公証する場合（Homebrew 以外で配る場合）
export CAPPY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export CAPPY_NOTARY_PROFILE=cappy-notary   # xcrun notarytool store-credentials で作成
make release
```
