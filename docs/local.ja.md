# この Mac の中で完結させる

[English](./local.md) | 日本語

`provider = "local"` にすると、文字起こし・話者分離・話者の名前の推定・要約をすべてこの Mac で行い、録音を外部に送りません（モデルのダウンロードを除く）。

## セットアップ

文字起こしと話者分離は cappy だけで動きますが、要約と話者の名前の推定には手元の LLM サーバーが必要です。ここでは [Ollama](https://ollama.com) を使う手順を示します（LM Studio などを使う場合は「[要約・話者の名前の推定](#要約話者の名前の推定)」を参照）。

1. Ollama をインストールします。

   ```bash
   brew install ollama          # または https://ollama.com からアプリをダウンロード
   ```

2. Ollama を起動します。

   ```bash
   brew services start ollama   # ログイン時にも自動で起動する。アプリを入れた場合はアプリを起動する
   ```

3. 要約に使うモデルを取得します。メモリに合わせて選んでください（下の例は `qwen3:30b` で進めます。別のモデルにするときは、手順 4 以降のモデル名を読み替えてください）。

   | モデル | 大きさ（4bit 量子化） | 目安 |
   | --- | --- | --- |
   | Qwen3 30B（`qwen3:30b`） | 十数 GB | メモリ 32 GB 以上の Mac |
   | Qwen3.5 9B（`qwen3.5:9b`） | 約 7 GB | メモリ 16 GB の Mac。日本語に強いと評価されている Qwen 系の小型版（下の「[例: Qwen3.5 9B を使う](#例-qwen35-9b-を使うメモリ-16-gb-の-mac)」） |
   | Gemma 4 12B（`gemma4:12b`） | 約 8 GB | メモリ 16 GB の Mac。Qwen3.5 9B と比べる候補（下の「[例: Gemma 4 12B を使う](#例-gemma-4-12b-を使うメモリ-16-gb-の-mac)」） |

   - 小さいモデルほど速くて軽い代わりに、議事録の質は落ちやすくなります。同じ録音の文字起こしで `cappy summarize --force` をモデルごとに実行して見比べてください。
   - Ollama でのタグ名（例: `qwen3.5:9b`）は、[ollama.com のライブラリ](https://ollama.com/library)で確かめてください。
   - 文脈長を 32K に広げると（手順 4）その分のメモリも使うので、9B〜12B 級でも 8〜10 GB ほど空けておくのが無難です。

   ```bash
   ollama pull qwen3:30b
   ```

4. 文脈長を広げたモデルを作ります。1 時間の会議を要約するには 32K トークン以上が必要ですが、Ollama の既定の文脈長は短く、超えた分を黙って切り捨てます。文脈長をモデルに持たせておけば、Ollama をどう起動しても（`brew services`・アプリ・`ollama serve`）効き、再起動しても消えません。

   ```bash
   cat > Modelfile <<'EOF'
   FROM qwen3:30b
   PARAMETER num_ctx 32768
   EOF
   ollama create qwen3-30b-32k -f Modelfile
   ollama list                  # qwen3-30b-32k があることを確かめる
   ```

   ほかの方法もありますが、それぞれ弱点があります。

   - `OLLAMA_CONTEXT_LENGTH=32768 ollama serve`: ターミナルで起動したときだけ効きます。`brew services` やアプリで起動した Ollama には、ターミナルで設定した環境変数は届きません。
   - `launchctl setenv OLLAMA_CONTEXT_LENGTH 32768` の後に `brew services restart ollama`（アプリならアプリを起動し直す）: ログアウトや再起動で消えます。
   - `~/Library/LaunchAgents/homebrew.mxcl.ollama.plist` を編集する: このファイルは `brew services` が作るもので、`brew upgrade` などで上書きされます。
   - Ollama のアプリの設定画面: 文脈長の項目がある版なら変えられますが、アプリから起動したときだけです。

5. `~/.config/cappy/config.toml` にプロファイルを追加します（`cappy init --profile on-device` で「この Mac」を選んでも作れます）。`summary.model` には手順 4 で作った名前（`qwen3-30b-32k`）を書きます。

6. 確認し、文字起こしと話者分離のモデルを先にダウンロードしておきます（省略すると最初の文字起こしのときにダウンロードします）。

   ```bash
   cappy doctor --profile on-device                     # サーバーとモデルがあるかも確かめる
   cappy doctor --profile on-device --download-models
   ```

### 例: Qwen3.5 9B を使う（メモリ 16 GB の Mac）

`qwen3:30b` の代わりに `qwen3.5:9b`（4bit 量子化で約 7 GB）を使う場合の、手順 3〜5 をまとめたものです。

```bash
ollama pull qwen3.5:9b

cat > Modelfile <<'EOF'
FROM qwen3.5:9b
PARAMETER num_ctx 32768
EOF
ollama create qwen3.5-9b-32k -f Modelfile
ollama list                  # qwen3.5-9b-32k があることを確かめる
```

```toml
[profiles.on-device.summary]
base_url = "http://localhost:11434/v1"
model = "qwen3.5-9b-32k"
```

```bash
cappy doctor --profile on-device                        # qwen3.5-9b-32k を使えるか確かめる
cappy summarize --profile on-device --force ~/Recordings/cappy/<セッション>
```

- `qwen3:30b` などと見比べたいときは、要約の前に `summary.md` を別の名前で残しておくか、`cappy tui` の過去の録音から作り直してください（以前の要約は日時付きの名前で残ります）。
- 話者の名前の推定（`cappy speakers`）も同じモデルを使います。別のモデルにしたいときは `[profiles.on-device.speakers]` の `model` で指定します。
- 文脈長を 32K に広げると、モデル本体と合わせて 8〜10 GB ほどのメモリを使います。ほかのアプリを閉じておくと安定します。

### 例: Gemma 4 12B を使う（メモリ 16 GB の Mac）

`gemma4:12b`（4bit 量子化で約 8 GB）を使う場合です。手順は Qwen3.5 9B と同じで、モデル名だけが変わります。

```bash
ollama pull gemma4:12b

cat > Modelfile <<'EOF'
FROM gemma4:12b
PARAMETER num_ctx 32768
EOF
ollama create gemma4-12b-32k -f Modelfile
ollama list                  # gemma4-12b-32k があることを確かめる
```

```toml
[profiles.on-device.summary]
base_url = "http://localhost:11434/v1"
model = "gemma4-12b-32k"
```

```bash
cappy doctor --profile on-device                        # gemma4-12b-32k を使えるか確かめる
cappy summarize --profile on-device --force ~/Recordings/cappy/<セッション>
```

- Qwen3.5 9B より 1 GB ほど大きく、文脈長を 32K に広げると合わせて 10 GB ほどのメモリを使います。16 GB の Mac では、ほかのアプリを閉じておくと安定します。
- Qwen3.5 9B と両方作っておけば、`summary.model` を書き換えるだけで切り替えて見比べられます。

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
model = "qwen3-30b-32k"
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
- **文脈長に注意してください。** 1 時間の日本語の会議はおよそ 2 万トークンになるので、32K トークン以上の文脈長が必要です。Ollama は既定の文脈長が短く、超えた分を黙って切り捨てるため、セットアップの手順 4 のように `num_ctx` を広げたモデルを作ってください。LM Studio ではモデルを読み込むときの Context Length で指定します。
- メモリの目安は、16 GB の Mac なら量子化した 9〜12B 級（Qwen3.5 9B、Gemma 4 12B など）、32 GB 以上なら 20〜30B 級（Qwen3 30B など、MoE を含む）です。議事録の質はモデルの大きさに大きく左右されます。
- `summary.effort`（思考の深さ）は送りません。`summary.max_tokens` は出力の上限として送ります。
- `cappy speakers`（話者の名前の推定）も同じサーバーを使います。`speakers.model` で別のモデルにもできます。

## 外部に送られるもの

- 録音・文字起こし・要約は送りません。
- 初回だけ、WhisperKit と SpeakerKit のモデルを Hugging Face から、Apple の音声モデルを Apple からダウンロードします。
- 手元の LLM サーバーを別のマシンに置いた場合（`base_url` が localhost 以外）は、文字起こしがそのマシンに送られます。
