# この Mac の中で完結させる

[English](./local.md) | 日本語

`provider = "local"` にすると、文字起こし・話者分離・話者の名前の推定・要約をすべてこの Mac で行い、録音を外部に送りません（モデルのダウンロードを除く）。

## セットアップ

文字起こしと話者分離は cappy だけで動きますが、要約と話者の名前の推定には手元の LLM サーバーが必要です。ここでは [Ollama](https://ollama.com) を使う手順を示します（LM Studio などを使う場合は「[要約・話者の名前の推定](#要約話者の名前の推定)」を参照）。

1. Ollama をインストールします。

   ```bash
   brew install ollama          # または https://ollama.com からアプリをダウンロード
   ```

2. 文脈長を広げて Ollama を起動します。1 時間の会議を要約するには 32K トークン以上が必要です（既定のままだと長い文字起こしが黙って切り捨てられます）。

   ```bash
   # ターミナルで起動する場合（起動したままにしておく）
   OLLAMA_CONTEXT_LENGTH=32768 ollama serve

   # Ollama のアプリを使う場合（設定してからアプリを起動し直す）
   launchctl setenv OLLAMA_CONTEXT_LENGTH 32768
   ```

3. 要約に使うモデルを取得します。30B 級のモデルは十数 GB あり、32 GB 以上のメモリが目安です。16 GB の Mac では 7〜8B 級のモデルを選んでください。

   ```bash
   ollama pull qwen3:30b
   ollama list                  # 取得したモデルの名前を確かめる
   ```

4. `~/.config/cappy/config.toml` にプロファイルを追加します（`cappy init --profile on-device` で「この Mac」を選んでも作れます）。`summary.model` には `ollama list` に出た名前をそのまま書きます。

5. 確認し、文字起こしと話者分離のモデルを先にダウンロードしておきます（省略すると最初の文字起こしのときにダウンロードします）。

   ```bash
   cappy doctor --profile on-device                     # サーバーとモデルがあるかも確かめる
   cappy doctor --profile on-device --download-models
   ```

## 設定と使い方

```toml
[profiles.on-device.transcribe]
provider = "local"
model = "whisperkit"          # whisperkit / apple
# whisper_model = "large-v3-v20240930_turbo"
# diarization = true          # remote トラックを SpeakerKit で話者分離
# num_speakers = 3            # 相手側の人数が分かっていれば

[profiles.on-device.summary]
# provider は transcribe.provider と同じ local になる
base_url = "http://localhost:11434/v1"
model = "qwen3:30b"
```

```bash
cappy record --profile on-device --app us.zoom.xos --name weekly --transcribe --summarize
```

## 文字起こし

`transcribe.model` で音声認識を選びます。

| model | 内容 |
| --- | --- |
| `whisperkit`（既定） | [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)（Core ML の Whisper）。初回にモデル（約 1〜3 GB）を Hugging Face からダウンロードし、`model_dir` に置きます。`whisper_model` でモデルを選べます（[argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) の名前の一部。例: `large-v3-v20240930_turbo`。省略時はこの Mac の推奨） |
| `apple` | Apple の SpeechAnalyzer / SpeechTranscriber（macOS 26 以降）。OS に内蔵で、言語の音声モデルは初回に OS がダウンロードします。対応言語は `cappy doctor` で確かめられます |

- 自分（マイク）と相手（会議アプリ）は別トラックで録音しているので、話者分離がなくても「自分」と「相手」は区別できます。
- `diarization = true`（既定）なら、相手側のトラックを [SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift)（pyannote の Core ML 版）で話者分離し、「相手 1」「相手 2」に分けます。`apple` を選んでも使えます。認識の区間に、時刻の重なりが最も長い話者を割り当てます。
- `custom_vocabulary` は WhisperKit ではプロンプトとして渡します（先頭の 50 語まで）。Apple では使いません。
- モデルは最初の文字起こしのときにダウンロードします。`cappy doctor --download-models` で先に済ませておけます（WhisperKit は Core ML のモデルの準備まで一度読み込んで済ませるので、数分かかることがあります）。
- `cappy transcribe --provider local --model apple <dir>` のように、その場で切り替えることもできます。
- 認識の速さは Mac とモデルによります。Apple シリコンで、Neural Engine を使います。
- `record --live`（録音しながらの文字起こし）は、`provider = "local"` ではまだ使えません。

## 要約・話者の名前の推定

`summary.provider = "local"` では、手元で動かす LLM サーバーの OpenAI 互換 API（`<base_url>/chat/completions`）を呼びます。認証はしません。

| サーバー | base_url |
| --- | --- |
| [Ollama](https://ollama.com)（既定） | `http://localhost:11434/v1` |
| [LM Studio](https://lmstudio.ai) | `http://localhost:1234/v1` |
| llama.cpp の `llama-server` | `http://localhost:8080/v1` |
| mlx-lm の `mlx_lm.server` | `http://localhost:8080/v1` |

- `summary.model` はサーバーのモデル名で、必須です（既定はありません）。`cappy doctor` でサーバーにつながるか、モデルがあるかを確かめます。
- **文脈長に注意してください。** 1 時間の日本語の会議はおよそ 2 万トークンになるので、32K トークン以上の文脈長が必要です。Ollama は既定の文脈長が短く、超えた分を黙って切り捨てるため、`OLLAMA_CONTEXT_LENGTH=32768 ollama serve` のように広げてください。LM Studio ではモデルを読み込むときの Context Length で指定します。
- メモリの目安は、16 GB の Mac なら量子化した 7〜8B 級、32 GB 以上なら 20〜30B 級（MoE を含む）です。議事録の質はモデルの大きさに大きく左右されます。
- `summary.effort`（思考の深さ）は送りません。`summary.max_tokens` は出力の上限として送ります。
- `cappy speakers`（話者の名前の推定）も同じサーバーを使います。`speakers.model` で別のモデルにもできます。

## 外部に送られるもの

- 録音・文字起こし・要約は送りません。
- 初回だけ、WhisperKit と SpeakerKit のモデルを Hugging Face から、Apple の音声モデルを Apple からダウンロードします。
- 手元の LLM サーバーを別のマシンに置いた場合（`base_url` が localhost 以外）は、文字起こしがそのマシンに送られます。
