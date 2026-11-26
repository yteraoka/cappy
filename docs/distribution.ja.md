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

## Developer ID の証明書と公証用の API キーの準備

Developer ID で署名すると、署名の designated requirement（DR）がバンドル ID とチーム ID で決まります。そのため、バージョンを上げても macOS のプライバシーの許可（システムオーディオ録音・マイクなど）が引き継がれます。ad-hoc 署名では DR がバイナリのハッシュになるため、ビルドのたびに許可をやり直すことになります。

### Developer ID Application 証明書

Developer ID の証明書を作れるのは、Apple Developer Program のアカウント保持者（Account Holder）だけです。有効期間は 5 年で、1 つのチームで作れる数には上限があるため、作った証明書は秘密鍵ごと保管してください。

Xcode から作る場合:

1. Xcode > Settings… > Accounts で Apple ID を追加します。
2. チームを選んで Manage Certificates… を開き、左下の + から Developer ID Application を選びます。秘密鍵と証明書がログインキーチェーンに入ります。

Web（developer.apple.com）から作る場合:

1. キーチェーンアクセス（`open -a "Keychain Access"`）のメニューで、キーチェーンアクセス > 証明書アシスタント > 認証局に証明書を要求… を選びます。メールアドレスと通称を入力し、CA のメールアドレスは空欄のまま「ディスクに保存」を選ぶと、CSR が保存されます。秘密鍵はこの Mac のログインキーチェーンに作られます。
2. [Certificates](https://developer.apple.com/account/resources/certificates/list) の + から Developer ID Application を選び、Profile Type は G2 Sub-CA を選びます。CSR をアップロードし、ダウンロードした `.cer` を CSR を作った Mac でダブルクリックして取り込みます。

確認:

```bash
security find-identity -v -p codesigning
```

`"Developer ID Application: Your Name (TEAMID)"` が表示されれば完了です。この文字列を `CAPPY_SIGN_IDENTITY` に設定します。表示されない場合や、証明書が「信頼されていません」になる場合は、[Apple PKI](https://www.apple.com/certificateauthority/) から Developer ID - G2 の中間証明書を取り込んでください。

署名した後は `codesign -d -r- dist/gcappy.app` で DR を確認できます。`certificate leaf[subject.OU] = "TEAMID"` が含まれていれば、アップグレード後も許可が引き継がれます。

別の Mac や CI で使う場合は、キーチェーンアクセスの「自分の証明書」で証明書の下に秘密鍵があることを確認し、右クリック > 書き出す… で `.p12`（個人情報交換）形式でパスワードを付けて書き出します。

作成時に出るエラー:

| エラー | 対処 |
| --- | --- |
| `Unable to process request - PLA Update available` | Program License Agreement が更新されています。[developer.apple.com/account](https://developer.apple.com/account) にサインインし、バナーから契約に同意してください。App Store Connect の「ビジネス」に未同意の契約があれば、そちらにも同意します。 |
| `This operation can only be performed by the Account Holder.` | 選んでいるチームでの役割がアカウント保持者ではありません。Membership details で役割を確認してください。アカウント保持者でも Xcode では Admin と表示されて作れないことがあります。その場合は Xcode のアカウントを削除して追加し直すか、Web から作ってください。 |

### 公証用の API キー

公証（notarization）には App Store Connect の API キーを使います。

1. [App Store Connect > ユーザとアクセス > 統合](https://appstoreconnect.apple.com/access/integrations/api) の Team Keys で + を押し、アクセスに Developer を選んでキーを作ります。
2. `AuthKey_<Key ID>.p8` をダウンロードします。ダウンロードは 1 回しかできません。画面に表示される Key ID と Issuer ID も控えます。
3. notarytool のプロファイルとしてキーチェーンに保存します。

   ```bash
   xcrun notarytool store-credentials cappy-notary \
     --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
   ```

4. `CAPPY_NOTARY_PROFILE=cappy-notary` を設定して `make release` を実行すると、署名の後に公証まで行います（「手元でのビルド」を参照）。

`.p12` と `.p8` は秘密情報です。リポジトリに含めず、パスワードマネージャーなどに保管してください。漏れた場合は、developer.apple.com で証明書を失効させ、App Store Connect で API キーを取り消します。
