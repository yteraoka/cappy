# AWS の準備

[English](./aws.md) | 日本語

## 文字起こし（Amazon Transcribe）の準備

`[transcribe]` の `provider = "aws"` で Amazon Transcribe を使います。

```toml
[profiles.default.aws]
region = "ap-northeast-1"     # Transcribe とバケットのリージョン
bucket = "my-cappy-bucket"    # 送信する音声を一時的に置く S3 バケット（同じリージョン）
# delete_remote_after = true  # 文字起こし後に S3 上の音声と Transcribe のジョブを削除

[profiles.default.transcribe]
provider = "aws"
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

## 要約（Amazon Bedrock の Claude）の準備

```toml
[profiles.default.aws]
region = "ap-northeast-1"     # 呼び出すリージョン（省略時は AWS_REGION → プロファイルの region）

[profiles.default.summary]
provider = "aws"              # 省略時は transcribe.provider と同じ
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

## AWS の認証

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
