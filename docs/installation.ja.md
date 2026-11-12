# インストール

[English](./installation.md) | 日本語

## Homebrew

```bash
brew install yteraoka/cask/cappy
```

詳しくは「[配布](./distribution.ja.md)」を参照してください。

## ソースからのビルドとインストール

Swift 6 / Xcode 16 以降（Swift Package Manager）が必要です。

```bash
make build                      # .build/release/cappy
make install PREFIX=~/.local    # ~/.local/bin/cappy
make test                       # 単体テスト
```

利用目的の文字列（`NSAudioCaptureUsageDescription` / `NSMicrophoneUsageDescription`）を書いた Info.plist は、リンク時に `-sectcreate __TEXT __info_plist` でバイナリに埋め込みます（`Support/Info.plist`）。

## シェルの補完

`cappy completion bash|zsh` で補完スクリプトを出力します（省略時は `$SHELL` から判断）。Homebrew で入れた場合は formula が配置します。

```bash
# zsh（~/.zshrc で compinit を呼んでいること）
mkdir -p ~/.zfunc
cappy completion zsh > ~/.zfunc/_cappy
# ~/.zshrc の compinit より前に: fpath=(~/.zfunc $fpath)

# bash（bash-completion を使っている場合）
mkdir -p ~/.local/share/bash-completion/completions
cappy completion bash > ~/.local/share/bash-completion/completions/cappy
# bash-completion がなければ ~/.bashrc に: source <(cappy completion bash)
```

サブコマンドとオプションのほか、次の値も補完します。

- `--profile`: 設定ファイルのプロファイル名
- `record --app` / `--pid` / `--mic`: その時点の音声プロセスの bundle ID・PID、入力デバイスの UID（zsh では名前や「出力中」も表示）
- `summarize --model`: よく使うモデルと、設定ファイルに書かれたモデル
- `--effort`・`transcribe --provider` / `--model`・`--format`・`--language`、セッションディレクトリ

## 権限

「システムオーディオ録音」と「マイク」の 2 つが必要です。CLI では、許可の対象は**実行元のターミナルアプリ**（Terminal、iTerm など）になります。

- 初回の `cappy record`（または `cappy doctor --request-permissions`）で許可ダイアログが出ます。
- 設定の場所: システム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 >「システムオーディオ録音のみ」、および「マイク」
- 許可されていない場合、`record` は録音を始めずに終了コード 2 で終了します。
- システムオーディオ録音が未許可でも、タップの作成自体は成功して相手側が無音になることがあります。その場合は録音後に警告を出します。
