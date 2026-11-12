# Google Cloud setup

English | [日本語](./google-cloud.ja.md)

## Project, APIs and bucket

```bash
gcloud services enable aiplatform.googleapis.com storage.googleapis.com --project my-project
gcloud storage buckets create gs://my-cappy-bucket --project my-project --location us \
  --uniform-bucket-level-access
cat > lifecycle.json <<'JSON'
{"rule": [{"action": {"type": "Delete"}, "condition": {"age": 1}}]}
JSON
gcloud storage buckets update gs://my-cappy-bucket --lifecycle-file lifecycle.json
```

- Required permissions: Vertex AI (`roles/aiplatform.user`) and `storage.objects.create/get/list/delete` on the bucket. With a Speech-to-Text model (e.g. `model = "chirp_3"`), Speech-to-Text (e.g. `roles/speech.client`) is also required (and `gcloud services enable speech.googleapis.com`).
- Transcription uses `gemini-3.5-transcribe` on Vertex AI by default (`location = "global"`). Enable `aiplatform.googleapis.com` (same as the summary setup below).
- The audio to send is placed in the bucket and passed as `gs://`. The Vertex AI (or Speech-to-Text) service agent must be able to read the bucket (usually not needed for a bucket in the same project).
- `cappy doctor` checks that the credentials are valid and the API is accessible, and checks the bucket permissions, uniform bucket-level access and lifecycle.

## Summary setup (Claude / Gemini on Vertex AI)

Uses the same project and ADC as transcription. No extra API key is needed.

```bash
gcloud services enable aiplatform.googleapis.com --project my-project
gcloud projects add-iam-policy-binding my-project \
  --member="user:you@example.com" --role="roles/aiplatform.user"
```

- The default model (`gemini-4-argon`) works with just the Vertex AI API enabled and the permission above.
- To use Claude (e.g. `model = "claude-opus-5-5"`), open "Claude Opus 5.5" in Model Garden in the Google Cloud console and enable it (first time only; you need to accept the terms).
- The global endpoint (`region = "global"`) is the default. To restrict where data is processed, use `us` / `eu` (multi-region). The available endpoints differ per model; check the model description in Model Garden (newer Claude models are not offered on single-region endpoints).
- Billing comes from Google Cloud ([pricing](https://cloud.google.com/vertex-ai/generative-ai/pricing#claude-models)). Token usage is in `summary.input_tokens` / `output_tokens` of `session.json`.
- `cappy doctor` checks access to the model with the free token counting API (`count-tokens:rawPredict` for Claude, `countTokens` for Gemini).
- For meetings whose content must not be sent outside, set `[profiles.<name>.summary] provider = "none"` (profiles with `transcribe.provider = "none"` also default to no summary).
