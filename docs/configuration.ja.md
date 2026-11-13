# 設定

[English](./configuration.md) | 日本語

## 初期設定

`cappy init` で、質問に答えながら設定ファイル（`~/.config/cappy/config.toml`）を作れます。尋ねるのは次の項目です。

- 文字起こしに使うサービス（Vertex AI の Gemini、Speech-to-Text、Amazon Transcribe、使わない）と会議の言語
- Google Cloud のプロジェクトと Cloud Storage のバケット、または AWS のプロファイル・リージョン・S3 バケット（gcloud のプロジェクトや `~/.aws/config` のプロファイルを候補に出します）
- 要約に使うサービス（Vertex AI、Amazon Bedrock、要約しない）、モデルとリージョン、文字起こしの後に続けて要約するか
- 録音の保存先

```bash
cappy init                  # default プロファイルを作る
cappy init --profile aws    # 別のプロファイルを追加する
```

保存する前に内容を表示します。設定ファイルがすでにあればプロファイルを追加し、同名のプロファイルは確認のうえ置き換えます（元のファイルは `config.toml.bak` に残し、ほかのプロファイルやコメントはそのまま残します）。認証情報は書き込みません。最後に次の手順（`gcloud auth application-default login` や `aws sso login` など）を表示し、`cappy doctor` で確認するかを尋ねます。バケットは作成しないので、事前に作っておいてください。

## 設定ファイル

`~/.config/cappy/config.toml`（環境変数 `CAPPY_CONFIG` で変更可）にプロファイル単位で書きます。`cappy init` で対話して作れます。すべての設定の例は [`config.example.ja.toml`](../config.example.ja.toml)（英語版は [`config.example.toml`](../config.example.toml)）を参照してください。設定ファイルがなければ `default` プロファイルの既定値（文字起こし・要約とも Vertex AI の Gemini、language = ja-JP、output_dir = ~/Recordings/cappy）を使います。

プロファイルは次のテーブルからなります。

| テーブル | 内容 |
| --- | --- |
| `[profiles.<name>]` | `language`（会議の言語）、`output_dir`、`disk_warn_mb`、`disk_stop_mb` |
| `[profiles.<name>.google]` | 文字起こしと要約で共通の Google Cloud のアカウント: `project_id`、`bucket`、`delete_remote_after` |
| `[profiles.<name>.aws]` | 文字起こしと要約で共通の AWS のアカウント: `profile`、`region`、`bucket`、`delete_remote_after` |
| `[profiles.<name>.transcribe]` | 文字起こし: `provider`（`google` / `aws` / `none`）、`model`、`location`、`diarization` など |
| `[profiles.<name>.summary]` | 会議の要約: `provider`（`google` / `aws` / `none`）、`model`、`region`、`auto`、`prompt`（要約のテンプレート。[使い方](./usage.ja.md#要約のテンプレート)）など |

`provider` でクラウド（`[google]` か `[aws]` のアカウント）を、`model` で何を使うかを選びます。

| | `provider = "google"` | `provider = "aws"` |
| --- | --- | --- |
| 文字起こし | `model = "gemini-*"`: Vertex AI の Gemini（既定 `gemini-3.5-transcribe`）<br>それ以外（`chirp_3` など）: Speech-to-Text v2 | Amazon Transcribe |
| 要約 | Vertex AI の Claude / Gemini（既定 `gemini-4-argon`） | Amazon Bedrock の Claude など（既定 `claude-opus-5-5`） |

```toml
[profiles.default]
language = "ja-JP"

[profiles.default.google]
project_id = "my-project"
bucket = "my-cappy-bucket"

[profiles.default.transcribe]
provider = "google"
model = "gemini-3.5-transcribe"

[profiles.default.summary]
provider = "google"
model = "gemini-4-argon"
```

`summary.provider` を省略すると `transcribe.provider` と同じになります。`[transcribe]` の `model`・`location`・`chunk_minutes` は `model` のサービス（Gemini か Speech-to-Text）に、それ以外（`diarization`・`word_timestamps`・`max_speakers` など）はそれを持つすべてのサービスに効きます。そのため `cappy transcribe --model chirp_3` や `--provider aws` で切り替えても、そのサービスの既定値で動きます。

認証情報は設定ファイルに書かず、Google のアプリケーションデフォルト認証情報（ADC）を使います。

```bash
gcloud auth application-default login
# またはサービスアカウント鍵: export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json
```

対応している ADC の種類は `authorized_user`、`service_account`、`impersonated_service_account` です。ユーザー認証情報の場合は、プロファイルの `project_id` を `x-goog-user-project`（課金先）として送ります。

クラウド側の準備は「[Google Cloud の準備](./google-cloud.ja.md)」「[AWS の準備](./aws.ja.md)」を参照してください。

## 表示言語

画面の表示（ヘルプ・メッセージ・エラー・`cappy doctor`・ログ）は既定で英語です。次の環境変数を順に見て、`ja` で始まる値なら日本語にします。

1. `CAPPY_LANG`（`ja` / `en`）
2. `LC_ALL`
3. `LC_MESSAGES`
4. `LANG`

```bash
export CAPPY_LANG=ja    # 常に日本語で表示する
```

`transcript.md`・`transcript.srt`・`summary.md` の見出しや話者名、要約の依頼文は、表示言語ではなく会議の言語（プロファイルの `language`）に合わせます。`ja-JP` なら「自分」「相手 1」、それ以外なら「Me」「Remote 1」です。
