# AWS setup

English | [日本語](./aws.ja.md)

## Transcription setup (Amazon Transcribe)

`provider = "aws"` in `[transcribe]` uses Amazon Transcribe.

```toml
[profiles.default.aws]
region = "ap-northeast-1"     # Region of Transcribe and the bucket
bucket = "my-cappy-bucket"    # S3 bucket that holds the audio temporarily (same Region)
# delete_remote_after = true  # delete the audio in S3 and the Transcribe job after transcription

[profiles.default.transcribe]
provider = "aws"
# diarization = true          # speaker diarization on the remote track
# max_speakers = 10           # maximum number of speakers (2-30)
# vocabulary_name = "cappy-terms"      # a custom vocabulary registered in advance (same Region and language)
# language_model_name = "my-model"     # a custom language model created in advance
```

```bash
aws s3api create-bucket --bucket my-cappy-bucket --region ap-northeast-1 \
  --create-bucket-configuration LocationConstraint=ap-northeast-1
aws s3api put-bucket-lifecycle-configuration --bucket my-cappy-bucket --lifecycle-configuration \
  '{"Rules":[{"ID":"cappy","Status":"Enabled","Filter":{"Prefix":"cappy/"},"Expiration":{"Days":1}}]}'
```

- Authentication is the same as [AWS authentication](#aws-authentication) below (`AWS_PROFILE`, SSO, access keys, ...).
- cappy puts the audio (`remote.flac`, ...) in S3, starts a job per track with `StartTranscriptionJob`, and waits for it to finish. A file can be up to 8 hours long, so it is not split. The result is stored in a location managed by Transcribe and downloaded from a presigned URL, so no output bucket is needed.
- Required permissions: `transcribe:StartTranscriptionJob` / `GetTranscriptionJob` / `DeleteTranscriptionJob` / `ListTranscriptionJobs` (for doctor), `s3:PutObject` / `s3:GetObject` / `s3:DeleteObject` on the bucket (Transcribe reads the audio in S3 with the caller's permissions), and `s3:GetBucketLocation` / `s3:GetLifecycleConfiguration` for doctor. With a custom vocabulary, `transcribe:GetVocabulary` is also required.
- Speaker diarization is enabled on the remote track (on the mix with `--mix`). If it is rejected, cappy sends the audio again without it.
- A custom vocabulary must be registered in advance (`aws transcribe create-vocabulary`; the table format is recommended). Unlike `custom_vocabulary` for Gemini, you cannot pass the words in the config file.
- `cappy doctor` checks access to the API, the state of the custom vocabulary, and the bucket Region, write / read / delete and lifecycle.
- `record --live` uses Amazon Transcribe Streaming (no S3). The required permission is `transcribe:StartStreamTranscriptionWebSocket`. `diarization`, `vocabulary_name` and `language_model_name` also apply to live transcription. Speaker diarization has been confirmed to work for Japanese live transcription too.
- Amazon Transcribe Streaming bills at least 15 seconds per connection (frequent reconnects cost more).

## Summary setup (models on Amazon Bedrock)

```toml
[profiles.default.aws]
region = "ap-northeast-1"     # Region to call (default: AWS_REGION, then region of the AWS profile)

[profiles.default.summary]
provider = "aws"              # default: the same as transcribe.provider
region = "jp"                 # inference profile scope: global / jp / us / eu / au / apac, or a Region name
model = "claude-opus-5-5"     # default: claude-opus-5-5. For Kimi K3.1: "global.moonshotai.kimi-k3.1"
```

- Authentication is the same as [AWS authentication](#aws-authentication) below (`AWS_PROFILE`, SSO, access keys, ...).
- Claude is called through the Anthropic-style Messages API on bedrock-runtime (`https://bedrock-runtime.<region>.amazonaws.com/anthropic/v1/messages`). The request has the same shape as Claude on Vertex AI (adaptive thinking, `effort`, streaming). Claude Opus 4.7 and later are supported.
- `summary.region` chooses where the request is processed. It is prepended to the model name to form the inference profile ID (`jp` gives `jp.anthropic.claude-opus-5-5`).
  - `jp`: processed only in Japan (Tokyo and Osaka). Set the Region to call (`aws.region`) to `ap-northeast-1` or `ap-northeast-3`. About 10% more expensive than global.
  - `global` (default): no restriction on where it is processed.
  - A Region name (e.g. `eu-west-2`): processed only in that Region (no scope is added to the model ID, and that Region is called). Available Regions differ per model (Claude Opus 5.5 is currently London only).
- The first time, enable Claude in "Model access" in the Amazon Bedrock console (Anthropic models require submitting use case details).
- Besides Claude, models that can be called through the OpenAI-compatible Chat Completions API on Bedrock (`https://bedrock-runtime.<region>.amazonaws.com/openai/v1/chat/completions`) can be used. Set a Bedrock model ID such as `moonshotai.kimi-k3.1` (Kimi K3.1) or `zai.glm-5.3` (GLM-5.3) in `summary.model` (or `--model`).
  - The scope of `summary.region` is prepended (`global` gives `global.moonshotai.kimi-k3.1`). An ID that already has a scope (`global.zai.glm-5.3`) is used as is. In Tokyo, Kimi K3.1 and GLM-5.3 are available only through `global`, so give an ID with the scope when, for example, you use Claude with `jp` and one of these models as the fallback.
  - `effort` is sent as `reasoning_effort` as is (Kimi K3.1: none to max, GLM-5.3: low to max). The reasoning (`reasoning_content`) is not included in the summary.
  - `finish_reason` `length` is treated as the output limit, and `content_filter` or `refusal` as a refusal. For non-Claude models there is no retry on refusal by default (set `fallback_model` to retry).
  - GLM-5.3 is limited to eligible customers (contact your AWS account team).
- IAM requires `bedrock:InvokeModel` / `bedrock:InvokeModelWithResponseStream` on the inference profile and on the foundation model in each destination Region.
- The retry on refusal (`summary.fallback_model`, default `claude-opus-4-8`) is done by cappy, as with Vertex AI (Bedrock has no server-side automatic fallback).
- `cappy doctor` checks that the summary model and the fallback model can be used with a request that is not billed (an invalid request with `max_tokens = 0`; Bedrock checks model access before validating the body). Newer Claude models do not support token counting on bedrock-runtime, and Chat Completions has no token counting.
- Billing comes from AWS. Token usage is in `summary.input_tokens` / `output_tokens` of `session.json`.

## AWS authentication

Authentication for AWS services (transcription with Amazon Transcribe, summaries with Amazon Bedrock). Credentials are not written in the config file; cappy uses the same profiles in `~/.aws/config` / `~/.aws/credentials` as the AWS CLI.

```toml
[profiles.default.aws]
# profile = "my-sso-profile"  # default: AWS_PROFILE, then AWS_DEFAULT_PROFILE, then default
region = "ap-northeast-1"     # default: AWS_REGION, then AWS_DEFAULT_REGION, then region of the profile
```

```bash
aws configure sso                 # create an SSO profile (first time only)
aws sso login --sso-session corp  # sign in (again when the token expires)
AWS_PROFILE=my-sso-profile cappy doctor
```

- If `profile` is not set in `[profiles.<name>.aws]`, access keys in environment variables (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`) take priority. The file locations can be changed with `AWS_CONFIG_FILE` / `AWS_SHARED_CREDENTIALS_FILE`.
- Supported profile types:
  - `sso_session` (IAM Identity Center): gets temporary role credentials with the token that `aws sso login` saved in `~/.aws/sso/cache`. If the token is about to expire, cappy refreshes it with the refresh token and writes it back to the cache (same as the AWS CLI).
  - Legacy SSO (`sso_start_url` in the profile): the token cannot be refreshed, so run `aws sso login --profile <name>` when it expires.
  - Access keys (`aws_access_key_id` / `aws_secret_access_key`), `credential_process`
  - Others (`role_arn`, `web_identity_token_file`, `login_session`, ...): obtained with `aws configure export-credentials --profile <name>` (requires AWS CLI v2).
- Temporary credentials are refreshed 5 minutes before they expire. Credentials and tokens are never written to logs or `session.json`.
- `cappy doctor` shows the profile type, the ARN and the credential expiry using STS `GetCallerIdentity` (no permission needed).
