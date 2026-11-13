# Configuration

English | [日本語](./configuration.ja.md)

## Initial setup

`cappy init` asks a few questions and writes the config file (`~/.config/cappy/config.toml`). It asks for:

- where to transcribe (Gemini on Vertex AI, Speech-to-Text, Amazon Transcribe, or none) and the meeting language
- the Google Cloud project and Cloud Storage bucket, or the AWS profile, Region and S3 bucket (it suggests the gcloud project and the profiles in `~/.aws/config`)
- where to summarize (Vertex AI, Amazon Bedrock, or none), the model and region, and whether to summarize automatically
- where to save recordings

```bash
cappy init                  # create the default profile
cappy init --profile aws    # add another profile
```

It shows the result before saving. If the config file already exists, the profile is added; a profile with the same name is replaced after confirmation (the previous file is kept as `config.toml.bak`; other profiles and comments are kept). Credentials are never written. At the end it lists the next steps (such as `gcloud auth application-default login` or `aws sso login`) and offers to run `cappy doctor`. The buckets themselves are not created; create them in advance.

## Config file

Write profiles in `~/.config/cappy/config.toml` (override with the `CAPPY_CONFIG` environment variable). `cappy init` creates it interactively; see [`config.example.toml`](../config.example.toml) for all settings. Without a config file, cappy uses the defaults of the `default` profile (Gemini on Vertex AI for transcription and summary, language = ja-JP, output_dir = ~/Recordings/cappy).

A profile is made of these tables:

| Table | Contents |
| --- | --- |
| `[profiles.<name>]` | `language` (meeting language), `output_dir`, `disk_warn_mb`, `disk_stop_mb` |
| `[profiles.<name>.google]` | Google Cloud account shared by transcription and summary: `project_id`, `bucket`, `delete_remote_after` |
| `[profiles.<name>.aws]` | AWS account shared by transcription and summary: `profile`, `region`, `bucket`, `delete_remote_after` |
| `[profiles.<name>.transcribe]` | Transcription: `provider` (`google` / `aws` / `none`), `model`, `location`, `diarization`, ... |
| `[profiles.<name>.summary]` | Meeting summary: `provider` (`google` / `aws` / `none`), `model`, `region`, `auto`, `prompt` (summary template; see [usage](./usage.md#summary-templates)), ... |

`provider` chooses the cloud (the account in `[google]` or `[aws]`), and `model` chooses what to use:

| | `provider = "google"` | `provider = "aws"` |
| --- | --- | --- |
| Transcription | `model = "gemini-*"`: Gemini on Vertex AI (default `gemini-3.5-transcribe`)<br>other models (`chirp_3`, ...): Speech-to-Text v2 | Amazon Transcribe |
| Summary | Claude / Gemini on Vertex AI (default `gemini-4-argon`) | Claude and other models on Amazon Bedrock (default `claude-opus-5-5`) |

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

`summary.provider` defaults to `transcribe.provider`. In `[transcribe]`, `model`, `location` and `chunk_minutes` apply to the service of `model` (Gemini or Speech-to-Text), and the other settings (`diarization`, `word_timestamps`, `max_speakers`, ...) apply to every service that has them, so `cappy transcribe --model chirp_3` or `--provider aws` keep working with the defaults of that service.

Credentials are not written in the config file; cappy uses Google Application Default Credentials (ADC).

```bash
gcloud auth application-default login
# or a service account key: export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json
```

Supported ADC types are `authorized_user`, `service_account` and `impersonated_service_account`. With user credentials, `project_id` of the profile is sent as `x-goog-user-project` (the billing project).

For the cloud side, see [Google Cloud setup](./google-cloud.md) and [AWS setup](./aws.md).

## UI language

The UI (help, messages, errors, `cappy doctor`, logs) is in English by default. cappy checks the following environment variables in order and uses Japanese when the value starts with `ja`:

1. `CAPPY_LANG` (`ja` / `en`)
2. `LC_ALL`
3. `LC_MESSAGES`
4. `LANG`

```bash
export CAPPY_LANG=ja    # always show Japanese
```

The headings and speaker names in `transcript.md`, `transcript.srt` and `summary.md`, and the summary prompt, follow the meeting language (`language` of the profile), not the UI language: "自分" / "相手 1" for `ja-JP`, and "Me" / "Remote 1" otherwise.
