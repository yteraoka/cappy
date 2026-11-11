# cappy

会議アプリの音声（相手）とマイク音声（自分）を、仮想オーディオデバイスなしで別トラックとして録音し、Vertex AI の Gemini（`gemini-3.5-transcribe`）で文字起こしして、Claude または Gemini で会議の要約まで作る macOS 用 CLI です。録音しながらのリアルタイム文字起こし（`gemini-3.5-transcribe-live`）にも対応しています。

- 相手側は Core Audio の Process Tap API で特定プロセスから直接取得し、自分の声はマイクから取得します。
- タップとマイクを 1 つのプライベート機器セット（集約デバイス）にまとめ、単一の IOProc で受け取ります。クロックが 1 本なので、トラック間の時刻合わせは不要です。
- 録音しながら Live API（または Amazon Transcribe Streaming）で文字起こしし、字幕のように表示することもできます（`--live`）。
- 録音から文字起こしまでの状態はすべて `session.json` に記録します。途中で終了しても `cappy transcribe <dir>` で再開できます。

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
- `--effort`・`transcribe --provider`・`--format`・`--language`、セッションディレクトリ

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

# 録音しながらリアルタイムで文字起こし（字幕を表示し、live-transcript.* に保存）
cappy record --app us.zoom.xos --name weekly-sync --live

# 文字起こし済みのセッションから要約を作る
cappy summarize ~/Recordings/cappy/2026-11-11T1000_weekly-sync

# 異常終了したセッションの修復
cappy recover ~/Recordings/cappy/2026-11-11T1000_weekly-sync

# シェルの補完スクリプト（下の「シェルの補完」を参照）
cappy completion zsh > ~/.zfunc/_cappy
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
| `--live` | 録音しながらリアルタイムで文字起こしする（`gemini.live_model`。`provider = "transcribe"` なら Amazon Transcribe Streaming）。確定した発言を表示し、`live-transcript.{md,json,srt}` に保存する |
| `--summarize` / `--no-summarize` | `--transcribe` / `--live` の後に続けて要約する（既定はプロファイルの `summary.auto`） |
| `--profile <name>` | 設定プロファイル |
| `--quiet` | 録音の告知メッセージを出さない |
| `-v, --verbose` | IOProc のバッファ欠落数やリングバッファの使用率も出す |

- 録音中に Enter を押すとマーカー（目印）を `session.json` の `markers` に記録します。文字を入力してから Enter を押すとラベル付きになります。
- Ctrl-C / SIGTERM で停止し、CAF を確定して送信用ファイルまで作ります。2 回目の Ctrl-C で変換を省いて終了します（あとで `recover` で作れます）。
- スリープの直前に停止して確定します。復帰後に自動で再開はしません。

#### リアルタイム文字起こし（`--live`）

- 自分（mic）と相手（remote）をそれぞれ 16 kHz・モノラルの PCM にして、100 ms ごとに送ります。送り先は、プロファイルの `provider` が `transcribe` なら Amazon Transcribe Streaming、それ以外は Vertex AI の Live API です。確定した発言は `[00:01:23] 相手: …` の形で表示し、認識途中の文字はステータス行に出します。
- Live API は 1 セッションで約 10 分の音声までのため、9 分を過ぎたら話の切れ目で（遅くとも 9 分 45 秒で）次のセッションに張り替えます。Amazon Transcribe Streaming は 1 セッション 4 時間までのため、3 時間 50 分を過ぎたら同じように張り替えます。時刻は録音全体の時刻にそろえます。
- 接続が切れたら再接続します（その間の音声はリアルタイム文字起こしに含まれず、`session.json` の `live.dropped_ms` に記録します）。権限や設定の誤りで接続できない場合は、リアルタイム文字起こしだけを止めて録音は続けます。
- Live API では話者分離はできません（相手側は「相手」とだけ表示します）。Amazon Transcribe Streaming では remote トラックで話者分離を行い（`transcribe.diarization`）、`相手（0）` のように表示します（`live-transcript.md` では「相手 1」「相手 2」）。精度の高い結果が必要なら、録音後に `cappy transcribe` を実行してください（`--live --transcribe` で両方行えます）。
- 要約は `transcript.json` があればそれを、なければ `live-transcript.json` を使います。
- 録音中は `live-transcript.jsonl` に確定した発言を追記します。異常終了した場合は `cappy recover` で `live-transcript.*` を作ります。

### transcribe

| オプション | 説明 |
| --- | --- |
| `--provider gemini\|google\|transcribe\|none` | 既定はプロファイルの `provider`（`gemini`）。`google` は Speech-to-Text v2（chirp_3）、`transcribe` は Amazon Transcribe |
| `--language ja-JP` | 既定はプロファイルの `language` |
| `--mix` | 2 トラックをミックスした 1 本で送る。課金対象は約半分になるが、自分と相手の区別は失われる |
| `--format md,json,srt` | 出力形式 |
| `--force` | 既存のジョブを破棄してやり直す |
| `--keep-remote` | バケット上の音声と結果（Amazon Transcribe ならジョブ）を削除しない |
| `--summarize` / `--no-summarize` | 続けて要約する（既定はプロファイルの `summary.auto`） |

### summarize

`transcript.json` を Vertex AI の Claude / Gemini、または Amazon Bedrock の Claude（`summary.provider = "bedrock"`）に送り、`summary.md` に次の構成で書き出します: 概要 / 決定事項 / アクションアイテム（担当・内容・期限・時刻の表）/ 議論の要点 / 未解決事項・持ち越し。決定事項などには根拠となる発言の時刻 `[HH:MM:SS]` が付くので、`transcript.md` で前後を確認できます。

| オプション | 説明 |
| --- | --- |
| `--model <id>` | 既定はプロファイルの `summary.model`（`gemini-4-argon`、Bedrock なら `claude-opus-5-5`）。`gemini-` で始まれば Gemini、`claude-` で始まれば Claude（例: `gemini-3.5-flash`、`claude-opus-5-5`）。Bedrock では `jp.anthropic.claude-opus-5-5` のような Bedrock のモデル ID も指定できます |
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

`~/.config/cappy/config.toml`（環境変数 `CAPPY_CONFIG` で変更可）にプロファイル単位で書きます。例は [`config.example.toml`](./config.example.toml) を参照してください。設定ファイルがなければ `default` プロファイルの既定値（provider = gemini、language = ja-JP、output_dir = ~/Recordings/cappy）を使います。

認証情報は設定ファイルに書かず、Google のアプリケーションデフォルト認証情報（ADC）を使います。

```bash
gcloud auth application-default login
# またはサービスアカウント鍵: export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json
```

対応している ADC の種類は `authorized_user`、`service_account`、`impersonated_service_account` です。ユーザー認証情報の場合は、プロファイルの `project_id` を `x-goog-user-project`（課金先）として送ります。

### Google Cloud 側の準備

```bash
gcloud services enable aiplatform.googleapis.com storage.googleapis.com --project my-project
gcloud storage buckets create gs://my-cappy-bucket --project my-project --location us \
  --uniform-bucket-level-access
cat > lifecycle.json <<'JSON'
{"rule": [{"action": {"type": "Delete"}, "condition": {"age": 1}}]}
JSON
gcloud storage buckets update gs://my-cappy-bucket --lifecycle-file lifecycle.json
```

- 必要な権限: Vertex AI の利用（`roles/aiplatform.user`）、バケットに対する `storage.objects.create/get/list/delete`。`provider = "google"` を使う場合は Speech-to-Text の利用（`roles/speech.client` など）も必要です（`gcloud services enable speech.googleapis.com` も）。
- 文字起こしの既定は Vertex AI の `gemini-3.5-transcribe`（`location = "global"`）です。`aiplatform.googleapis.com` を有効にしてください（下の「要約の準備」と同じ）。
- 送信する音声はバケットに置いて `gs://` で渡します。Vertex AI（または Speech-to-Text）のサービスエージェントがバケットを読める必要があります（同じプロジェクトのバケットなら通常は不要）。
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

### 文字起こし（Amazon Transcribe）の準備

```toml
[profiles.default]
provider = "transcribe"

[profiles.default.aws]
region = "ap-northeast-1"     # Transcribe とバケットのリージョン
bucket = "my-cappy-bucket"    # 送信する音声を一時的に置く S3 バケット（同じリージョン）
# delete_remote_after = true  # 文字起こし後に S3 上の音声と Transcribe のジョブを削除

[profiles.default.transcribe]
# diarization = true          # remote トラックで話者分離
# max_speakers = 10           # 話者分離の最大人数（2〜30）
# vocabulary_name = "cappy-terms"      # 事前に登録したカスタム語彙（同じリージョン・言語）
# language_model_name = "my-model"     # 事前に作成したカスタム言語モデル
```

```bash
aws s3api create-bucket --bucket my-cappy-bucket --region ap-northeast-1 \
  --create-bucket-configuration LocationConstraint=ap-northeast-1
aws s3api put-bucket-lifecycle-configuration --bucket my-cappy-bucket --lifecycle-configuration \
  '{"Rules":[{"ID":"cappy","Status":"Enabled","Filter":{"Prefix":"cappy/"},"Expiration":{"Days":1}}]}'
```

- 認証は下の「AWS の認証」と同じです（`AWS_PROFILE`・SSO・アクセスキーなど）。
- 音声（`remote.flac` など）を S3 に置き、`StartTranscriptionJob` でトラックごとにジョブを投入して、完了を待ちます。1 ファイル 8 時間まで扱えるため分割しません。結果は Transcribe が管理する場所に置かれ、署名付き URL から取得するので、出力用のバケットは不要です。
- 必要な権限: `transcribe:StartTranscriptionJob` / `GetTranscriptionJob` / `DeleteTranscriptionJob` / `ListTranscriptionJobs`（doctor 用）、バケットに対する `s3:PutObject` / `s3:GetObject` / `s3:DeleteObject`（Transcribe は呼び出した人の権限で S3 の音声を読みます）、doctor 用に `s3:GetBucketLocation` / `s3:GetLifecycleConfiguration`。カスタム語彙を使う場合は `transcribe:GetVocabulary` も必要です。
- 話者分離は remote トラック（`--mix` ならミックス）で有効にします。拒否された場合は話者分離なしで送り直します。
- カスタム語彙は事前に登録しておく必要があります（`aws transcribe create-vocabulary`。表形式を推奨）。Gemini の `custom_vocabulary` のように設定ファイルで単語を渡すことはできません。
- `cappy doctor` で、API へのアクセス、カスタム語彙の状態、バケットのリージョン・書き込み・読み取り・削除・ライフサイクルを確認できます。
- `record --live` は Amazon Transcribe Streaming を使います（S3 は使いません）。必要な権限は `transcribe:StartStreamTranscriptionWebSocket` です。`diarization`・`vocabulary_name`・`language_model_name` はリアルタイム文字起こしにも使います。日本語のリアルタイム文字起こしでも話者分離が使えることを確認しています。
- Amazon Transcribe Streaming は接続ごとに最低 15 秒分の料金がかかります（再接続が多いと割高になります）。

### 要約（Amazon Bedrock の Claude）の準備

```toml
[profiles.default.aws]
region = "ap-northeast-1"     # 呼び出すリージョン（省略時は AWS_REGION → プロファイルの region）

[profiles.default.summary]
provider = "bedrock"
region = "jp"                 # 推論プロファイルの範囲: global / jp / us / eu / au / apac、またはリージョン名
model = "claude-opus-5-5"     # 省略時は claude-opus-5-5。Kimi K3.1 なら "global.moonshotai.kimi-k3.1"
```

- 認証は上の「AWS の認証」と同じです（`AWS_PROFILE`・SSO・アクセスキーなど）。
- bedrock-runtime の Anthropic 形式の Messages API（`https://bedrock-runtime.<region>.amazonaws.com/anthropic/v1/messages`）を呼びます。リクエストは Vertex AI の Claude と同じ形（適応的思考・`effort`・ストリーミング）です。Claude Opus 4.7 以降のモデルに対応します。
- `summary.region` で処理する地域を選びます。モデル名の前に付けて推論プロファイルの ID にします（`jp` なら `jp.anthropic.claude-opus-5-5`）。
  - `jp`: 日本国内（東京・大阪）だけで処理します。呼び出すリージョン（`aws.region`）は `ap-northeast-1` か `ap-northeast-3` にしてください。global より約 10% 高くなります。
  - `global`（既定）: 処理する地域を限定しません。
  - リージョン名（例: `eu-west-2`）: そのリージョンだけで処理します（モデル ID に範囲を付けず、そのリージョンを呼びます）。使えるリージョンはモデルごとに異なります（Claude Opus 5.5 は現在 London のみ）。
- 初回は Amazon Bedrock コンソールの「モデルアクセス」で Claude を有効にしてください（Anthropic のモデルは利用目的の申請が必要です）。
- Claude 以外に、Bedrock の OpenAI 互換 Chat Completions（`https://bedrock-runtime.<region>.amazonaws.com/openai/v1/chat/completions`）で呼べるモデルも使えます。`summary.model`（または `--model`）に `moonshotai.kimi-k3.1`（Kimi K3.1）や `zai.glm-5.3`（GLM-5.3）のような Bedrock のモデル ID を書きます。
  - `summary.region` の範囲を前に付けます（`global` なら `global.moonshotai.kimi-k3.1`）。範囲付きの ID（`global.zai.glm-5.3`）を書けば、その ID をそのまま使います。Kimi K3.1 と GLM-5.3 は東京では `global` だけなので、Claude を `jp` で使いつつこれらを再試行先にする場合などは、範囲付きの ID で指定してください。
  - `effort` は `reasoning_effort` としてそのまま送ります（Kimi K3.1 は none〜max、GLM-5.3 は low〜max）。思考の内容（`reasoning_content`）は要約に含めません。
  - `finish_reason` が `length` なら出力上限、`content_filter` か `refusal` があれば拒否として扱います。Claude 以外のモデルでは、既定では拒否時に再試行しません（`fallback_model` で指定できます）。
  - GLM-5.3 は利用できる顧客が限られています（AWS のアカウントチームへの問い合わせが必要です）。
- IAM では、推論プロファイルと、振り分け先の各リージョンの基盤モデルに対する `bedrock:InvokeModel` / `bedrock:InvokeModelWithResponseStream` が必要です。
- 拒否されたときの再試行（`summary.fallback_model`、既定は `claude-opus-4-8`）は Vertex AI と同じく cappy 側で行います（Bedrock ではサーバー側の自動フォールバックが使えません）。
- `cappy doctor` は、課金されないリクエスト（`max_tokens = 0` の不正なリクエスト。モデルの利用権限は本文の検証より先に確かめられる）で、要約のモデルと再試行先のモデルを使えるか確認します。新しい Claude は bedrock-runtime のトークン数の確認に対応しておらず、Chat Completions にはトークン数の確認がないためです。
- 課金は AWS から請求されます。使ったトークン数は `session.json` の `summary.input_tokens` / `output_tokens` で確認できます。

### AWS の認証

AWS のサービス（Amazon Transcribe での文字起こし、Amazon Bedrock での要約）を使うための認証です。認証情報は設定ファイルに書かず、AWS CLI と同じ `~/.aws/config` / `~/.aws/credentials` のプロファイルを使います。

```toml
[profiles.default.aws]
# profile = "my-sso-profile"  # 省略時は AWS_PROFILE → AWS_DEFAULT_PROFILE → default
region = "ap-northeast-1"     # 省略時は AWS_REGION → AWS_DEFAULT_REGION → プロファイルの region
```

```bash
aws configure sso                 # SSO のプロファイルを作る（初回のみ）
aws sso login --sso-session corp  # ログイン（トークンの期限が切れたら再実行）
AWS_PROFILE=my-sso-profile cappy doctor
```

- `[profiles.<name>.aws]` で `profile` を指定しなければ、環境変数のアクセスキー（`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`）を優先します。設定ファイルの場所は `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE` で変えられます。
- 対応しているプロファイルの種類:
  - `sso_session`（IAM Identity Center）: `aws sso login` が `~/.aws/sso/cache` に保存したトークンでロールの一時的な認証情報を取得します。トークンの期限が近ければリフレッシュトークンで更新し、キャッシュに書き戻します（AWS CLI と同じ動作）。
  - 旧形式の SSO（プロファイルに `sso_start_url`）: トークンの更新はできないため、期限切れなら `aws sso login --profile <name>` が必要です。
  - アクセスキー（`aws_access_key_id` / `aws_secret_access_key`）、`credential_process`
  - それ以外（`role_arn`、`web_identity_token_file`、`login_session` など）: `aws configure export-credentials --profile <name>` で取得します（AWS CLI v2 が必要）。
- 一時的な認証情報は期限の 5 分前に取り直します。認証情報やトークンはログや `session.json` に書きません。
- `cappy doctor` は STS の `GetCallerIdentity`（権限不要）で、使ったプロファイルの種類・ARN・認証情報の期限を表示します。

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
├── live-transcript.{md,json,srt}  # リアルタイム文字起こしの結果（record --live）
├── summary.md         # 会議の要約（cappy summarize / --summarize）
└── cappy.log          # イベント・時刻・エラーのみ（本文は出さない）
```

ファイルはすべて 0600 で作成します。ログは統合ログ（サブシステム `dev.cappy`）にも出します（`log stream --predicate 'subsystem == "dev.cappy"'`）。

## 実装メモ

- **言語**: Go が希望でしたが、Swift で実装しています。Process Tap API は Objective-C クラス（`CATapDescription`）を使い、IOProc はリアルタイムスレッドで呼ばれます。Go（cgo）ではそのスレッドからランタイムに入れず、GC の停止も避けられないためです（Swift 6 + SwiftPM + swift-argument-parser）。
- **`tapautostart` は無効**: 有効にすると、タップ対象が音を出すまで機器セットの IO が始まりません。その間はマイクも録れないため、無効にしています（実機で確認）。
- **ストリームの対応付け**: 機器セットの入力ストリームは「サブデバイス（リスト順）→ タップ」の順に並びます（実機で確認）。出力デバイスに入力ストリームがあれば読み飛ばします。
- **録音中の変化への追従**: 対象アプリの音声プロセスが増えたら、まず `kAudioTapPropertyDescription` でタップの対象を差し替えます。差し替えられない場合（実機では `'!hog'` になることがある）は作り直し、欠落区間を `gaps` に記録します。プロセスが減っただけのときは何もしません。既定の出力・入力デバイスが変わったら機器セットを作り直します。IOProc が 6 秒以上止まった場合も作り直します。欠落区間は両トラックとも無音で埋めるため、トラック同士と実時間とのずれは生じません。
- **Gemini による文字起こし（既定）**: `gemini-3.5-transcribe` の `generateContent`（v1beta1、`generationConfig.audioTranscriptionConfig`）に、バケットに置いた音声を `fileData` で渡します。話者分離・タイムスタンプ有効時は 1 リクエスト 15 分までのため、既定 14 分ごとに分割して並行（最大 3 本）に送り、時刻をずらしてマージします。分割ごとの結果はセッションディレクトリに一時保存し、中断しても完了した分割は送り直しません。応答の `parts[].audioTranscription`（`speakerLabel`、`words[].startOffset/endOffset`）から発言を作り、30 秒を超える発言は句点や間で分けます。話者分離を拒否された場合は話者分離なしで送り直します。
- **リアルタイム文字起こし（Amazon Transcribe Streaming）**: `wss://transcribestreaming.<region>.amazonaws.com:8443/stream-transcription-websocket` に SigV4 の署名付き URL（クエリに署名、有効期限 5 分）で接続し、イベントストリーム形式（前半の長さと CRC32・ヘッダー・本文・全体の CRC32）の `AudioEvent` で音声を送ります。`TranscriptEvent` の `IsPartial = false` の結果を確定した発言にし、単語の `Speaker` が変わるところで分けます。終わりは空の `AudioEvent` で伝えます。WebSocket の ping には応答しないため、接続の失敗は最初の受信で検出します。`BadRequestException`（無音による時間切れを除く）は再接続しても直らないものとして、リアルタイム文字起こしだけを止めます。話者分離を拒否された場合は、話者分離なしで張り直します。
- **リアルタイム文字起こし**: Live API（`wss://…/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent`）に `setup`（`inputAudioTranscription`、`responseModalities: ["TEXT"]`）を送り、`realtimeInput.audio`（`audio/pcm;rate=16000`）で音声を送ります。`serverContent.inputTranscription` を確定、`interimInputTranscription` を途中の文字として扱います。`AudioSink` を実装する `LiveAudioSink` として、録音中の音声を受け取ります。
- **Amazon Transcribe の結果**（`provider = "transcribe"` の場合）: 結果 JSON の `results.items` から単語と句読点を取り出し、話者（`speaker_label`、古い形式では `speaker_labels.segments`）が変わるところと、文の終わり・間（0.8 秒）・長さ（30 秒）で発言に分けます。日本語などは単語を空白なしでつなぎます。信頼度は単語の平均です。
- **chirp_3 の制限**（`provider = "google"` の場合）: 公式ドキュメントでは、BatchRecognize は「概ね 1 時間まで、単語タイムスタンプ有効時は約 20 分まで」です。そのため、送信用ファイルを既定 19 分ごとに分割して 1 リクエストで送り、結果を時刻オフセット付きでマージします（`chunk_minutes` で変更可）。分割した場合、話者分離のラベルはチャンクをまたいで一致しない可能性があります。
- **話者分離**（`provider = "google"` の場合）: chirp_3 は日本語の話者分離に対応しています（BatchRecognize のみ）。remote トラックで有効にし、モデルが拒否した場合（投入時・実行時のいずれも）は話者分離なしで再投入し、その旨を `session.json` の `transcription.jobs[].note` に記録します。
- **要約**: `cappy summarize` はモデル名で呼び出し先を切り替えます。Claude は Vertex AI の Messages API（`streamRawPredict`、`anthropic_version = 2026-10-21`）を、適応的思考（adaptive thinking）と `effort` で呼び出します。Gemini は `streamGenerateContent?alt=sse` を `thinkingConfig.thinkingLevel` で呼び出し、思考の部分（`thought: true`）は出力に含めません。どちらもストリーミングで受け取ります。文字起こし本文は `<transcript>` で囲み、その中の指示には従わないようモデルに指示しています。
- **システムオーディオ録音の許可状態**: 公開 API がないため、TCC.framework の `TCCAccessPreflight` / `TCCAccessRequest` を動的に呼び出して確認しています。

## テスト

```bash
make test                   # 単体テスト（形式変換、マージ、session.json、プロバイダ応答の変換、要約の依頼と応答、HTTP スタブなど）
make integration-test       # 実機の機器セットを使った作り直しとタイムラインの確認
make integration-test TAP=1 # afplay の音を PID でタップし、元音声との相互相関で欠落とずれを確認（要: システムオーディオ録音の許可）
# 実際の Amazon Transcribe Streaming に 16 kHz の音声ファイルを実時間で送る（課金あり。CAPPY_AWS_LIVE_SPEAKERS=0 で話者分離なし）
AWS_PROFILE=my-profile CAPPY_AWS_LIVE_TEST=/path/to/remote.flac swift test --filter TranscribeStreamingIntegrationTests
```

## 配布

Homebrew の tap（[`yteraoka/homebrew-cask`](https://github.com/yteraoka/homebrew-cask) の `Formula/cappy.rb`）で配布します。

```bash
brew install yteraoka/cask/cappy
```

- ビルド済みのバイナリ（Apple Silicon、macOS 15 以降）を GitHub Releases から入れます。bash / zsh の補完スクリプトも配置されます。
- バイナリは ad-hoc 署名（Hardened Runtime、マイク入力の entitlement 付き）です。formula で入れたファイルには quarantine 属性が付かないため、公証なしで実行できます。録音とマイクの許可は実行元のターミナルアプリに付きます。

### リリースの流れ

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

### 手元でのビルド

```bash
CAPPY_SIGN_IDENTITY=- make release     # ad-hoc 署名の dist/cappy-<version>-macos-arm64.zip
scripts/formula.sh <version> <sha256>  # tap に置く formula を出力

# Developer ID で署名し公証する場合（Homebrew 以外で配る場合）
export CAPPY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export CAPPY_NOTARY_PROFILE=cappy-notary   # xcrun notarytool store-credentials で作成
make release
```

## 構成メモ

Writer は `AudioSink` プロトコルを実装する「シンク」に音声を配ります。録音中の原本は `FileSink`、リアルタイム文字起こしは `LiveAudioSink` で、どちらもリングバッファから取り出した同じ音声（欠落区間は無音で埋めたもの）を受け取るため、時刻は録音全体でそろいます。
