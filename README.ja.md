# cappy

[English](./README.md) | 日本語

会議アプリの音声（相手）とマイク音声（自分）を、仮想オーディオデバイスなしで別トラックとして録音し、文字起こしして、会議の要約まで作る macOS 用 CLI です。

- 文字起こし: Vertex AI の Gemini（`gemini-3.5-transcribe`、既定）、Google Speech-to-Text v2（chirp_3）、Amazon Transcribe
- 要約: Vertex AI の Claude / Gemini、Amazon Bedrock のモデル（Claude、Kimi K3.1、GLM-5.3 など）
- 録音しながらのリアルタイム文字起こし: Vertex AI の Live API（`gemini-3.5-transcribe-live`）、Amazon Transcribe Streaming

仕組み:

- 相手側は Core Audio の Process Tap API で特定プロセスから直接取得し、自分の声はマイクから取得します。
- タップとマイクを 1 つのプライベート機器セット（集約デバイス）にまとめ、単一の IOProc で受け取ります。クロックが 1 本なので、トラック間の時刻合わせは不要です。
- 録音しながら Live API（または Amazon Transcribe Streaming）で文字起こしし、字幕のように表示することもできます（`--live`）。
- 録音から文字起こしまでの状態はすべて `session.json` に記録します。途中で終了しても `cappy transcribe <dir>` で再開できます。

## 動作環境

- macOS 15 以降（Apple Silicon で検証）
- 外部ツールは不要です（ffmpeg も不要）。

## インストール

```bash
brew install yteraoka/cask/cappy
```

ソースからビルドする場合（Swift 6 / Xcode 16 以降）は `make build && make install PREFIX=~/.local` です。シェルの補完と権限は「[インストール](./docs/installation.ja.md)」を参照してください。

## クイックスタート

```bash
cappy init      # ~/.config/cappy/config.toml を対話で作る
cappy doctor    # 権限・認証・設定・バケットを確認する
cappy apps      # 会議アプリのバンドル ID を調べる

# Zoom を録音し（Ctrl-C で停止）、続けて文字起こしと要約を行う
cappy record --app us.zoom.xos --name weekly-sync --transcribe --summarize

# 全画面で設定とアプリを選んで録音することもできる
cappy tui
```

初回の録音時に、実行しているターミナルアプリに対して「システムオーディオ録音」と「マイク」の許可を求められます。結果は `~/Recordings/cappy/<日時>_<名前>/` に保存されます（`transcript.md`、`summary.md` など）。

途中で終了しても `cappy transcribe <dir>` で再開でき、異常終了したセッションは `cappy recover <dir>` で修復できます。

## ドキュメント

| ドキュメント | 内容 |
| --- | --- |
| [インストール](./docs/installation.ja.md) | Homebrew、ソースからのビルド、シェルの補完、権限 |
| [設定](./docs/configuration.ja.md) | `cappy init`、設定ファイルとプロファイル、表示言語 |
| [Google Cloud の準備](./docs/google-cloud.ja.md) | Vertex AI / Speech-to-Text での文字起こし、Claude / Gemini での要約 |
| [AWS の準備](./docs/aws.ja.md) | Amazon Transcribe、Amazon Bedrock での要約、AWS の認証 |
| [使い方](./docs/usage.ja.md) | コマンド一覧、`record` / `transcribe` / `summarize` のオプション、マイクのミュート、リアルタイム文字起こし、終了コード |
| [cappy tui](./docs/tui.ja.md) | 全画面 UI、過去の録音、終了と中断 |
| [出力](./docs/output.ja.md) | セッションディレクトリのファイル |
| [開発](./docs/development.ja.md) | テスト、実装メモ、構成メモ |
| [配布](./docs/distribution.ja.md) | Homebrew tap、リリースの流れ、手元でのリリースビルド |
