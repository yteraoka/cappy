# Google Cloud の準備

[English](./google-cloud.md) | 日本語

## プロジェクト・API・バケット

```bash
gcloud services enable aiplatform.googleapis.com storage.googleapis.com --project my-project
gcloud storage buckets create gs://my-cappy-bucket --project my-project --location us \
  --uniform-bucket-level-access
cat > lifecycle.json <<'JSON'
{"rule": [{"action": {"type": "Delete"}, "condition": {"age": 1}}]}
JSON
gcloud storage buckets update gs://my-cappy-bucket --lifecycle-file lifecycle.json
```

- 必要な権限: Vertex AI の利用（`roles/aiplatform.user`）、バケットに対する `storage.objects.create/get/list/delete`。Speech-to-Text のモデル（`model = "chirp_3"` など）を使う場合は Speech-to-Text の利用（`roles/speech.client` など）も必要です（`gcloud services enable speech.googleapis.com` も）。
- 文字起こしの既定は Vertex AI の `gemini-3.5-transcribe`（`location = "global"`）です。`aiplatform.googleapis.com` を有効にしてください（下の「要約の準備」と同じ）。
- 送信する音声はバケットに置いて `gs://` で渡します。Vertex AI（または Speech-to-Text）のサービスエージェントがバケットを読める必要があります（同じプロジェクトのバケットなら通常は不要）。
- `cappy doctor` で、認証の有効性、API へのアクセス、バケットの権限・均一アクセス制御・ライフサイクルを確認できます。

## 要約（Vertex AI の Claude / Gemini）の準備

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
- 外部に送信したくない案件では、プロファイルで `[profiles.<name>.summary] provider = "none"` にしてください（`transcribe.provider = "none"` のプロファイルでは要約も既定で none になります）。
