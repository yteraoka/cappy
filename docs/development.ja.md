# 開発

[English](./development.md) | 日本語

## テスト

```bash
make test                   # 単体テスト（形式変換、マージ、session.json、プロバイダ応答の変換、要約の依頼と応答、HTTP スタブなど）
make integration-test       # 実機の機器セットを使った作り直しとタイムラインの確認
make integration-test TAP=1 # afplay の音を PID でタップし、元音声との相互相関で欠落とずれを確認（要: システムオーディオ録音の許可）
# 実際の Amazon Transcribe Streaming に 16 kHz の音声ファイルを実時間で送る（課金あり。CAPPY_AWS_LIVE_SPEAKERS=0 で話者分離なし）
AWS_PROFILE=my-profile CAPPY_AWS_LIVE_TEST=/path/to/remote.flac swift test --filter TranscribeStreamingIntegrationTests
```

## 実装メモ

- **実装言語**: Go ではなく Swift で実装しています。Process Tap API は Objective-C クラス（`CATapDescription`）を使い、IOProc はリアルタイムスレッドで呼ばれます。Go（cgo）ではそのスレッドからランタイムに入れず、GC の停止も避けられないためです（Swift 6 + SwiftPM + swift-argument-parser）。
- **`tapautostart` は無効**: 有効にすると、タップ対象が音を出すまで機器セットの IO が始まりません。その間はマイクも録れないため、無効にしています（実機で確認）。
- **ストリームの対応付け**: 機器セットの入力ストリームは「サブデバイス（リスト順）→ タップ」の順に並びます（実機で確認）。出力デバイスに入力ストリームがあれば読み飛ばします。
- **録音中の変化への追従**: 対象アプリの音声プロセスが増えたら、まず `kAudioTapPropertyDescription` でタップの対象を差し替えます。差し替えられない場合（実機では `'!hog'` になることがある）は作り直し、欠落区間を `gaps` に記録します。プロセスが減っただけのときは何もしません。既定の出力・入力デバイスが変わったら機器セットを作り直します。IOProc が 6 秒以上止まった場合も作り直します。欠落区間は両トラックとも無音で埋めるため、トラック同士と実時間とのずれは生じません。
- **Gemini による文字起こし（既定）**: `gemini-3.5-transcribe` の `generateContent`（v1beta1、`generationConfig.audioTranscriptionConfig`）に、バケットに置いた音声を `fileData` で渡します。話者分離・タイムスタンプ有効時は 1 リクエスト 15 分までのため、既定 14 分ごとに分割して並行（最大 3 本）に送り、時刻をずらしてマージします。分割ごとの結果はセッションディレクトリに一時保存し、中断しても完了した分割は送り直しません。応答の `parts[].audioTranscription`（`speakerLabel`、`words[].startOffset/endOffset`）から発言を作り、30 秒を超える発言は句点や間で分けます。話者分離を拒否された場合は話者分離なしで送り直します。
- **リアルタイム文字起こし（Amazon Transcribe Streaming）**: `wss://transcribestreaming.<region>.amazonaws.com:8443/stream-transcription-websocket` に SigV4 の署名付き URL（クエリに署名、有効期限 5 分）で接続し、イベントストリーム形式（前半の長さと CRC32・ヘッダー・本文・全体の CRC32）の `AudioEvent` で音声を送ります。`TranscriptEvent` の `IsPartial = false` の結果を確定した発言にし、単語の `Speaker` が変わるところで分けます。終わりは空の `AudioEvent` で伝えます。WebSocket の ping には応答しないため、接続の失敗は最初の受信で検出します。`BadRequestException`（無音による時間切れを除く）は再接続しても直らないものとして、リアルタイム文字起こしだけを止めます。話者分離を拒否された場合は、話者分離なしで張り直します。
- **リアルタイム文字起こし**: Live API（`wss://…/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent`）に `setup`（`inputAudioTranscription`、`responseModalities: ["TEXT"]`）を送り、`realtimeInput.audio`（`audio/pcm;rate=16000`）で音声を送ります。`serverContent.inputTranscription` を確定、`interimInputTranscription` を途中の文字として扱います。`AudioSink` を実装する `LiveAudioSink` として、録音中の音声を受け取ります。
- **Amazon Transcribe の結果**（`provider = "aws"` の場合）: 結果 JSON の `results.items` から単語と句読点を取り出し、話者（`speaker_label`、古い形式では `speaker_labels.segments`）が変わるところと、文の終わり・間（0.8 秒）・長さ（30 秒）で発言に分けます。日本語などは単語を空白なしでつなぎます。信頼度は単語の平均です。
- **chirp_3 の制限**（Speech-to-Text の場合）: 公式ドキュメントでは、BatchRecognize は「概ね 1 時間まで、単語タイムスタンプ有効時は約 20 分まで」です。そのため、送信用ファイルを既定 19 分ごとに分割して 1 リクエストで送り、結果を時刻オフセット付きでマージします（`chunk_minutes` で変更可）。分割した場合、話者分離のラベルはチャンクをまたいで一致しない可能性があります。
- **話者分離**（Speech-to-Text の場合）: chirp_3 は日本語の話者分離に対応しています（BatchRecognize のみ）。remote トラックで有効にし、モデルが拒否した場合（投入時・実行時のいずれも）は話者分離なしで再投入し、その旨を `session.json` の `transcription.jobs[].note` に記録します。
- **要約**: `cappy summarize` はモデル名で呼び出し先を切り替えます。Claude は Vertex AI の Messages API（`streamRawPredict`、`anthropic_version = 2026-10-21`）を、適応的思考（adaptive thinking）と `effort` で呼び出します。Gemini は `streamGenerateContent?alt=sse` を `thinkingConfig.thinkingLevel` で呼び出し、思考の部分（`thought: true`）は出力に含めません。どちらもストリーミングで受け取ります。文字起こし本文は `<transcript>` で囲み、その中の指示には従わないようモデルに指示しています。
- **表示言語**: 文言は `tr("English", ja: "日本語")` の形でコードに並べて書き、`L10n.current`（`CAPPY_LANG` → `LC_ALL` → `LC_MESSAGES` → `LANG`、既定は英語）で選びます。リソースバンドルを使うと単一のバイナリで配れないためです。作るファイルは `UILanguage.forDocument(language)` で会議の言語に合わせます。Info.plist の利用目的の文字列は、切り替えられないため英語と日本語を併記しています。
- **システムオーディオ録音の許可状態**: 公開 API がないため、TCC.framework の `TCCAccessPreflight` / `TCCAccessRequest` を動的に呼び出して確認しています。

## 構成メモ

Writer は `AudioSink` プロトコルを実装する「シンク」に音声を配ります。録音中の原本は `FileSink`、リアルタイム文字起こしは `LiveAudioSink` で、どちらもリングバッファから取り出した同じ音声（欠落区間は無音で埋めたもの）を受け取るため、時刻は録音全体でそろいます。
