# cappy

会議アプリの音声（相手）とマイク音声（自分）を、仮想オーディオデバイスなしで別トラックとして録音し、外部サービス（Google Cloud Speech-to-Text v2）で文字起こしして、Vertex AI の Claude または Gemini で会議の要約まで作る macOS 用 CLI です。

- 相手側は Core Audio の Process Tap API で特定プロセスから直接取得し、自分の声はマイクから取得します。
- タップとマイクを 1 つのプライベート機器セット（集約デバイス）にまとめ、単一の IOProc で受け取ります。クロックが 1 本なので、トラック間の時刻合わせは不要です。
- 録音から文字起こしまでの状態はすべて `session.json` に記録します。途中で終了しても `cappy transcribe <dir>` で再開できます。

仕様は [`cappy：会議音声キャプチャ・文字起こし CLI 仕様書.md`](./cappy：会議音声キャプチャ・文字起こし%20CLI%20仕様書.md) を参照してください。

## 動作環境

- macOS 15 以降（Apple Silicon で検証）
- ビルド: Swift 6 / Xcode 16 以降（Swift Package Manager）
- 外部ツールは不要です（ffmpeg も不要）。

## ビルドとインストール

```bash
make build                      # .build/release/cappy
make install PREFIX=~/.local    # ~/.local/bin/cappy
make test                       # 単体テスト
```

利用目的の文字列（`NSAudioCaptureUsageDescription` / `NSMicrophoneUsageDescription`）を書いた Info.plist は、リンク時に `-sectcreate __TEXT __info_plist` でバイナリに埋め込みます（`Support/Info.plist`）。

## 権限

「システムオーディオ録音」と「マイク」の 2 つが必要です。CLI では、許可の対象は**実行元のターミナルアプリ**（Terminal、iTerm など）になります。

- 初回の `cappy record`（または `cappy doctor --request-permissions`）で許可ダイアログが出ます。
- 設定の場所: システム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 >「システムオーディオ録音のみ」、および「マイク」
- 許可されていない場合、`record` は録音を始めずに終了コード 2 で終了します。
- システムオーディオ録音が未許可でも、タップの作成自体は成功して相手側が無音になることがあります。その場合は録音後に警告を出します。

## 使い方

```bash
cappy apps                         # 音声プロセスの一覧（PID・bundle ID・出力中か）
cappy devices                      # 入力デバイスの一覧（UID・名前・サンプルレート）
cappy doctor                       # 権限・認証・設定・バケットの診断

# Zoom を録音（Ctrl-C で停止）
cappy record --app us.zoom.xos --name weekly-sync

# ブラウザ版 Meet を 90 分で自動停止し、続けて文字起こし
cappy record --app com.google.Chrome --duration 90m --transcribe

# 録音から文字起こし・要約まで続けて行う
cappy record --app us.zoom.xos --name weekly-sync --transcribe --summarize

# 録音後に文字起こし（中断しても同じコマンドで再開）
cappy transcribe ~/Recordings/cappy/2026-11-11T1000_weekly-sync

# 文字起こし済みのセッションから要約を作る
cappy summarize ~/Recordings/cappy/2026-11-11T1000_weekly-sync

# 異常終了したセッションの修復
cappy recover ~/Recordings/cappy/2026-11-11T1000_weekly-sync
```

### record

| オプション | 説明 |
| --- | --- |
| `--app <bundleID>` | 録音対象を bundle ID で指定（前方一致。`com.google.Chrome` で `com.google.Chrome.helper` も対象）。複数指定可 |
| `--pid <pid>` | 録音対象を PID で指定。複数指定可 |
| `--system` | 自分自身を除くシステム全体の出力を録音 |
| `--no-mic` / `--mic <UID>` | マイク録音の無効化 / 入力デバイスの指定（既定はシステムの既定入力。変更にも追従） |
| `--out <dir>` / `--name <title>` | 保存先 / セッション名 |
| `--duration 90m` | 指定時間で自動停止（`1h30m`、`45s` なども可） |
| `--wait` | 対象が音声を出し始めるまで待つ |
| `--transcribe` (`--mix`, `--format`) | 録音後に続けて文字起こしする |
| `--summarize` / `--no-summarize` | `--transcribe` の後に続けて要約する（既定はプロファイルの `summary.auto`） |
| `--profile <name>` | 設定プロファイル |
| `--quiet` | 録音の告知メッセージを出さない |
| `-v, --verbose` | IOProc のバッファ欠落数やリングバッファの使用率も出す |

- 録音中に Enter を押すとマーカー（目印）を `session.json` の `markers` に記録します。文字を入力してから Enter を押すとラベル付きになります。
- Ctrl-C / SIGTERM で停止し、CAF を確定して送信用ファイルまで作ります。2 回目の Ctrl-C で変換を省いて終了します（あとで `recover` で作れます）。
- スリープの直前に停止して確定します。復帰後に自動で再開はしません。

### transcribe

| オプション | 説明 |
| --- | --- |
| `--provider google\|none` | 既定はプロファイルの `provider` |
| `--language ja-JP` | 既定はプロファイルの `language` |
| `--mix` | 2 トラックをミックスした 1 本で送る。課金対象は約半分になるが、自分と相手の区別は失われる |
| `--format md,json,srt` | 出力形式 |
| `--force` | 既存のジョブを破棄してやり直す |
| `--keep-remote` | バケット上の音声と結果を削除しない |
| `--summarize` / `--no-summarize` | 続けて要約する（既定はプロファイルの `summary.auto`） |

### summarize

`transcript.json` を Vertex AI の Claude または Gemini に送り、`summary.md` に次の構成で書き出します: 概要 / 決定事項 / アクションアイテム（担当・内容・期限・時刻の表）/ 議論の要点 / 未解決事項・持ち越し。決定事項などには根拠となる発言の時刻 `[HH:MM:SS]` が付くので、`transcript.md` で前後を確認できます。

| オプション | 説明 |
| --- | --- |
| `--model <id>` | 既定はプロファイルの `summary.model`（`gemini-4-argon`）。`gemini-` で始まれば Gemini、`claude-` で始まれば Claude（例: `gemini-3.5-flash`、`claude-opus-5-5`） |
| `--effort low\|medium\|high\|xhigh\|max` | 思考の深さ。既定はプロファイルの `summary.effort`（`high`）。Gemini 3 以降では `thinkingLevel` の LOW / MEDIUM / HIGH（`xhigh` と `max` は HIGH）に対応させ、Gemini 2.5 以前では指定せずモデルの動的な思考に任せます |
| `--force` | 同じ文字起こしから作った要約があっても作り直す |

- 文字起こしをやり直した場合（`transcript.json` が変わった場合）は、`--force` なしでも作り直します。
- 録音中に付けたマーカーは「本人が重要だと考えた箇所」として要約に反映されます。録音の欠落区間も伝えます。
- 要約の本文は `cappy.log` や `session.json` には書きません（`session.json` の `summary` にはモデル・トークン数・状態だけを記録します）。
- モデルが要約を拒否した場合（Claude の `stop_reason: refusal`、Gemini の安全性による停止）は、`summary.fallback_model` で 1 回だけ再試行し、その旨を `summary.md` に書きます。既定は Claude なら `claude-opus-4-8`、Gemini なら再試行しません（Claude と Gemini をまたいだ指定も可）。Vertex AI ではサーバー側の自動フォールバックが使えないため、cappy 側で行っています。
- Gemini で、指定した思考レベルにモデルが対応していない（400）場合は、思考の設定を外して再試行します。

### 終了コード

| コード | 意味 |
| --- | --- |
| 0 | 正常終了 |
| 1 | 引数・設定の誤り |
| 2 | 権限不足（システムオーディオ録音またはマイク） |
| 3 | 録音対象のプロセスが見つからない |
| 4 | 録音中の I/O エラー（ディスク容量不足など） |
| 5 | 文字起こし・要約サービスのエラー（認証・クォータ・ジョブ失敗） |

## 設定

`~/.config/cappy/config.toml`（環境変数 `CAPPY_CONFIG` で変更可）にプロファイル単位で書きます。例は [`config.example.toml`](./config.example.toml) を参照してください。設定ファイルがなければ `default` プロファイルの既定値（provider = google、language = ja-JP、output_dir = ~/Recordings/cappy）を使います。

認証情報は設定ファイルに書かず、Google のアプリケーションデフォルト認証情報（ADC）を使います。

```bash
gcloud auth application-default login
# またはサービスアカウント鍵: export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json
```

対応している ADC の種類は `authorized_user`、`service_account`、`impersonated_service_account` です。ユーザー認証情報の場合は、プロファイルの `project_id` を `x-goog-user-project`（課金先）として送ります。

### Google Cloud 側の準備

```bash
gcloud services enable speech.googleapis.com storage.googleapis.com --project my-project
gcloud storage buckets create gs://my-cappy-bucket --project my-project --location us \
  --uniform-bucket-level-access
cat > lifecycle.json <<'JSON'
{"rule": [{"action": {"type": "Delete"}, "condition": {"age": 1}}]}
JSON
gcloud storage buckets update gs://my-cappy-bucket --lifecycle-file lifecycle.json
```

- 必要な権限: Speech-to-Text の利用（`roles/speech.client` など）、バケットに対する `storage.objects.create/get/list/delete`
- Speech-to-Text のサービスエージェントがバケットを読み書きできる必要があります（同じプロジェクトのバケットなら通常は不要）。
- `cappy doctor` で、認証の有効性、API へのアクセス、バケットの権限・均一アクセス制御・ライフサイクルを確認できます。

### 要約（Vertex AI の Claude / Gemini）の準備

文字起こしと同じプロジェクト・同じ ADC を使います。追加の API キーは不要です。

```bash
gcloud services enable aiplatform.googleapis.com --project my-project
gcloud projects add-iam-policy-binding my-project \
  --member="user:you@example.com" --role="roles/aiplatform.user"
```

- 既定のモデル（`gemini-4-argon`）は、Vertex AI API の有効化と上の権限だけで使えます。
- Claude（`model = "claude-opus-5-5"` など）を使う場合は、Google Cloud コンソールの Model Garden で「Claude Opus 5.5」を開き、利用を有効にしてください（初回のみ。利用規約への同意が必要です）。
- 既定はグローバルエンドポイント（`region = "global"`）です。データの処理地域を限定したい場合は `us` / `eu`（マルチリージョン）を指定します。使えるエンドポイントはモデルごとに異なるので、Model Garden のモデルの説明で確認してください（新しい Claude モデルは単一リージョンのエンドポイントでは提供されていません）。
- 課金は Google Cloud から請求されます（[料金](https://cloud.google.com/vertex-ai/generative-ai/pricing#claude-models)）。使ったトークン数は `session.json` の `summary.input_tokens` / `output_tokens` で確認できます。
- `cappy doctor` は、課金されないトークン数の確認 API（Claude は `count-tokens:rawPredict`、Gemini は `countTokens`）でモデルへのアクセスを確認します。
- 外部に送信したくない案件では、プロファイルで `[profiles.<name>.summary] provider = "none"` にしてください（`provider = "none"` のプロファイルでは要約も既定で none になります）。

## 出力

```text
~/Recordings/cappy/2026-11-11T1000_weekly-sync/   (0700)
├── session.json       # メタデータと処理状態（tracks, gaps, markers, transcription ...）
├── remote.caf         # 相手側（タップ）録音中の原本（ネイティブ形式・Float32）
├── mic.caf            # 自分（マイク）録音中の原本
├── remote.flac        # 送信用（16 kHz・モノラル・16 bit。FLAC が使えなければ WAV）
├── mic.flac
├── transcript.json    # 正規化した文字起こし結果（segments: track, speaker, start_ms, end_ms, text, confidence）
├── transcript.md      # 読む用（mic =「自分」、remote =「相手」／話者分離があれば「相手 1」「相手 2」）
├── transcript.srt     # 字幕・動画編集用
├── summary.md         # 会議の要約（cappy summarize / --summarize）
└── cappy.log          # イベント・時刻・エラーのみ（本文は出さない）
```

ファイルはすべて 0600 で作成します。ログは統合ログ（サブシステム `dev.cappy`）にも出します（`log stream --predicate 'subsystem == "dev.cappy"'`）。

## 実装メモ（仕様書からの補足・差分）

- **言語**: Go が希望でしたが、Swift で実装しています。Process Tap API は Objective-C クラス（`CATapDescription`）を使い、IOProc はリアルタイムスレッドで呼ばれます。Go（cgo）ではそのスレッドからランタイムに入れず、GC の停止も避けられないためです。仕様書の技術選定（Swift 6 + SwiftPM + swift-argument-parser）にも合わせました。
- **`tapautostart` は無効**: 有効にすると、タップ対象が音を出すまで機器セットの IO が始まりません。その間はマイクも録れないため、無効にしています（実機で確認）。
- **ストリームの対応付け**: 機器セットの入力ストリームは「サブデバイス（リスト順）→ タップ」の順に並びます（実機で確認）。出力デバイスに入力ストリームがあれば読み飛ばします。
- **録音中の変化への追従**: 対象アプリの音声プロセスが増えたら、まず `kAudioTapPropertyDescription` でタップの対象を差し替えます。差し替えられない場合（実機では `'!hog'` になることがある）は作り直し、欠落区間を `gaps` に記録します。プロセスが減っただけのときは何もしません。既定の出力・入力デバイスが変わったら機器セットを作り直します。IOProc が 6 秒以上止まった場合も作り直します。欠落区間は両トラックとも無音で埋めるため、トラック同士と実時間とのずれは生じません。
- **chirp_3 の制限**: 公式ドキュメントでは、BatchRecognize は「概ね 1 時間まで、単語タイムスタンプ有効時は約 20 分まで」です。そのため、送信用ファイルを既定 19 分ごとに分割して 1 リクエストで送り、結果を時刻オフセット付きでマージします（`chunk_minutes` で変更可）。分割した場合、話者分離のラベルはチャンクをまたいで一致しない可能性があります。
- **話者分離**: chirp_3 は日本語の話者分離に対応しています（BatchRecognize のみ）。remote トラックで有効にし、モデルが拒否した場合（投入時・実行時のいずれも）は話者分離なしで再投入し、その旨を `session.json` の `transcription.jobs[].note` に記録します。
- **要約**: 仕様書では対象外（transcript を別ツールに渡す運用）でしたが、要望により `cappy summarize` として追加しました。モデル名で呼び出し先を切り替えます。Claude は Vertex AI の Messages API（`streamRawPredict`、`anthropic_version = 2026-10-21`）を、適応的思考（adaptive thinking）と `effort` で呼び出します。Gemini は `streamGenerateContent?alt=sse` を `thinkingConfig.thinkingLevel` で呼び出し、思考の部分（`thought: true`）は出力に含めません。どちらもストリーミングで受け取ります。文字起こし本文は `<transcript>` で囲み、その中の指示には従わないようモデルに指示しています。
- **システムオーディオ録音の許可状態**: 公開 API がないため、TCC.framework の `TCCAccessPreflight` / `TCCAccessRequest` を動的に呼び出して確認しています。

## テスト

```bash
make test                   # 単体テスト（形式変換、マージ、session.json、プロバイダ応答の変換、要約の依頼と応答、HTTP スタブなど）
make integration-test       # 実機の機器セットを使った作り直しとタイムラインの確認
make integration-test TAP=1 # afplay の音を PID でタップし、元音声との相互相関で欠落とずれを確認（要: システムオーディオ録音の許可）
```

## 配布

Developer ID で署名し公証したバイナリを、Homebrew の自前 tap で配布する想定です。

```bash
export CAPPY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export CAPPY_NOTARY_PROFILE=cappy-notary   # xcrun notarytool store-credentials で作成
make release                               # dist/cappy-<version>-macos-arm64.zip
```

formula の雛形は [`packaging/cappy.rb`](./packaging/cappy.rb) です。

## 今後（フェーズ 3）

Writer は `AudioSink` プロトコルを実装する「シンク」の 1 つ（`FileSink`）として作ってあり、リングバッファから取り出した音声を複数のシンクに配れます。リアルタイム文字起こしは `StreamingSink` を追加するだけで載せられる構造です。
