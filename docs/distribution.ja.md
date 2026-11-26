# 配布

[English](./distribution.md) | 日本語

Homebrew の tap（[`yteraoka/homebrew-cask`](https://github.com/yteraoka/homebrew-cask) の `Formula/cappy.rb` と `Formula/gcappy.rb`）で配布します。

```bash
brew install yteraoka/cask/cappy     # CLI
brew install yteraoka/cask/gcappy    # メニューバー版
```

- ビルド済みのバイナリ（Apple Silicon、macOS 15 以降）を GitHub Releases から入れます。bash / zsh の補完スクリプトも配置されます。
- バイナリは Developer ID で署名し、公証しています（Hardened Runtime、マイク入力の entitlement 付き）。録音とマイクの許可は実行元のターミナルアプリに付きます。
- gcappy は `gcappy.app`（cappy を `Contents/MacOS/cappy` に同梱）を `$(brew --prefix gcappy)` に入れ、`open` で起動する `gcappy` コマンドを配置します。録音とマイクの許可は gcappy に付きます。

## リリースの流れ

1. main に PR をマージすると、tagpr（`.github/workflows/tagpr.yaml`）がリリース用の PR を作ります。`Sources/CappyKit/Core/Version.swift` のバージョンもこの PR で更新されます（`minor` / `major` ラベルで上げ幅を変えられます）。
2. リリース用の PR をマージすると、tagpr が `vX.Y.Z` のタグと GitHub Release を作ります。
3. タグの push で `.github/workflows/release.yaml`（macOS の runner）が動きます。
   1. テストを実行する
   2. `scripts/release.sh` で Developer ID で署名・公証した `cappy-X.Y.Z-macos-arm64.zip` と `gcappy-X.Y.Z-macos-arm64.zip`（`scripts/build-app.sh` で組み立てた gcappy.app）を作り、Release に添付する
   3. `scripts/formula.sh` で `packaging/cappy.rb` / `packaging/gcappy.rb` の url と sha256 を書き換え、tap の `Formula/cappy.rb` / `Formula/gcappy.rb` を更新する
4. PR では、同じワークフローでテストとリリース用のビルドだけを行います。公証はタグのときだけ行い、PR では Developer ID での署名までにします。シークレットを参照できない PR（fork からの PR など）では ad-hoc 署名でビルドします。

必要な設定（cappy リポジトリの Settings > Secrets and variables > Actions）:

| 種類 | 名前 | 内容 |
| --- | --- | --- |
| 変数 | `TAGPR_APP_ID` | tagpr 用の GitHub App の Client ID |
| シークレット | `TAGPR_APP_PRIVATE_KEY` | 同じ App の秘密鍵 |
| 変数 | `HOMEBREW_APP_ID` | Release の作成と tap の更新に使う GitHub App の Client ID（Contents: Read and write） |
| シークレット | `HOMEBREW_APP_PRIVATE_KEY` | 同じ App の秘密鍵 |
| シークレット | `MACOS_CERT_P12_BASE64` | Developer ID Application の証明書と秘密鍵を書き出した .p12 を base64 にしたもの |
| シークレット | `MACOS_CERT_PASSWORD` | .p12 のパスワード（付けていなければ不要） |
| シークレット | `MACOS_SIGN_IDENTITY` | 署名 ID（例: `Developer ID Application: Your Name (TEAMID)`） |
| シークレット | `NOTARY_KEY_BASE64` | 公証に使う App Store Connect API キー（.p8）を base64 にしたもの |
| シークレット | `NOTARY_KEY_ID` | 同じ API キーの Key ID |
| シークレット | `NOTARY_ISSUER_ID` | 同じ API キーの Issuer ID |

どちらの App も cappy にインストールし、`HOMEBREW_APP_ID` の App は `homebrew-cask` にもインストールしておきます。

## 手元でのビルド

```bash
CAPPY_SIGN_IDENTITY=- make release     # ad-hoc 署名の dist/cappy-<version>-macos-arm64.zip と dist/gcappy-<version>-macos-arm64.zip
scripts/formula.sh <version> <sha256>  # tap に置く formula を出力
scripts/formula.sh <version> <sha256> gcappy
make app                               # dist/gcappy.app だけを作る

# Developer ID で署名する場合
export CAPPY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
# 公証もする場合
export CAPPY_NOTARY_PROFILE=cappy-notary   # xcrun notarytool store-credentials で作成
make release
```
