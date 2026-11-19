# Keeping everything on this Mac

English | [日本語](./local.ja.md)

With `provider = "local"`, transcription, speaker diarization, speaker naming and the summary all run on this Mac, and the recordings are not sent anywhere (except for downloading the models).

## Setup

Transcription and speaker diarization run in cappy itself, but the summary and speaker naming need a local LLM server. These steps use [Ollama](https://ollama.com) (for LM Studio and others, see "[Summary and speaker naming](#summary-and-speaker-naming)").

1. Install Ollama.

   ```bash
   brew install ollama          # or download the app from https://ollama.com
   ```

2. Start Ollama.

   ```bash
   brew services start ollama   # also starts it at login. If you installed the app, start the app instead
   ```

3. Pull the model for the summary. Choose one that fits your memory (the steps below use `qwen3:30b`; with another model, replace the name in step 4 and later).

   | Model | Size (4-bit) | Guide |
   | --- | --- | --- |
   | Qwen3 30B (`qwen3:30b`) | over 10 GB | Macs with 32 GB of memory or more |
   | Qwen3.5 9B | about 6 GB | Macs with 16 GB. A small model from the Qwen family, which is rated well for Japanese |
   | Gemma 4 12B | about 7 GB | Macs with 16 GB. An alternative to compare with Qwen3.5 9B |

   - Smaller models are faster and lighter, but the minutes tend to be worse. Run `cappy summarize --force` with each model on the same transcript and compare.
   - Check the Ollama tag names (e.g. `qwen3.5:9b`) in the [ollama.com library](https://ollama.com/library).
   - Widening the context to 32K (step 4) also uses memory, so keep about 8-10 GB free even for a 9-12B model.

   ```bash
   ollama pull qwen3:30b
   ```

4. Create a model with a wider context. Summarizing an hour-long meeting needs 32K tokens or more, but Ollama's default context is short and silently cuts off the rest. If the model itself carries the context length, it works however Ollama is started (`brew services`, the app, `ollama serve`) and survives restarts.

   ```bash
   cat > Modelfile <<'EOF'
   FROM qwen3:30b
   PARAMETER num_ctx 32768
   EOF
   ollama create qwen3-30b-32k -f Modelfile
   ollama list                  # check that qwen3-30b-32k is there
   ```

   Other ways exist, but each has a drawback:

   - `OLLAMA_CONTEXT_LENGTH=32768 ollama serve`: only works when started in a terminal. Ollama started by `brew services` or the app does not see environment variables set in a terminal.
   - `launchctl setenv OLLAMA_CONTEXT_LENGTH 32768`, then `brew services restart ollama` (or restart the app): lost at logout or restart.
   - Editing `~/Library/LaunchAgents/homebrew.mxcl.ollama.plist`: `brew services` creates this file, and `brew upgrade` and the like overwrite it.
   - The settings of the Ollama app: versions with a context length setting can change it, but only when Ollama is started from the app.

5. Add the profile to `~/.config/cappy/config.toml` (or run `cappy init --profile on-device` and choose "This Mac"). Write the model created in step 4 (`qwen3-30b-32k`) in `summary.model`.

6. Check, and download the transcription and diarization models in advance (otherwise they are downloaded on the first transcription).

   ```bash
   cappy doctor --profile on-device                     # also checks the server and the model
   cappy doctor --profile on-device --download-models
   ```

## Settings and usage

```toml
[profiles.on-device.transcribe]
provider = "local"
model = "whisperkit"          # whisperkit / apple
# whisper_model = "large-v3-v20240930_turbo"
# diarization = true          # speaker diarization of the remote track with SpeakerKit
# num_speakers = 3            # the number of remote speakers, if known

[profiles.on-device.summary]
# provider follows transcribe.provider (local)
base_url = "http://localhost:11434/v1"
model = "qwen3-30b-32k"
```

```bash
cappy record --profile on-device --app us.zoom.xos --name weekly --transcribe --summarize
```

## Transcription

`transcribe.model` chooses the speech recognizer.

| model | Description |
| --- | --- |
| `whisperkit` (default) | [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (Whisper on Core ML). The model (about 1-3 GB) is downloaded from Hugging Face the first time and kept in `model_dir`. `whisper_model` chooses the model (part of a name in [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml), e.g. `large-v3-v20240930_turbo`; default: recommended for this Mac) |
| `apple` | Apple's SpeechAnalyzer / SpeechTranscriber (macOS 26 or later). Built into the OS; the speech model for the language is downloaded by the OS the first time. `cappy doctor` shows whether the language is supported |

- You (microphone) and the remote side (meeting app) are recorded as separate tracks, so "Me" and "Remote" are told apart even without diarization.
- With `diarization = true` (default), the remote track is diarized with [SpeakerKit](https://github.com/argmaxinc/argmax-oss-swift) (pyannote on Core ML) into "Remote 1", "Remote 2", ... This also works with `apple`. Each recognized segment gets the speaker it overlaps the longest.
- `custom_vocabulary` is passed to WhisperKit as a prompt (the first 50 entries). It is not used with Apple.
- The models are downloaded on the first transcription. `cappy doctor --download-models` does it in advance (WhisperKit is also loaded once to prepare the Core ML models, which can take a few minutes).
- You can switch on the spot, e.g. `cappy transcribe --provider local --model apple <dir>`.
- The speed depends on the Mac and the model. It runs on Apple silicon and uses the Neural Engine.
- `record --live` (transcription while recording) is not available yet with `provider = "local"`.

## Summary and speaker naming

With `summary.provider = "local"`, cappy calls the OpenAI-compatible API (`<base_url>/chat/completions`) of an LLM server running locally. No authentication is used.

| Server | base_url |
| --- | --- |
| [Ollama](https://ollama.com) (default) | `http://localhost:11434/v1` |
| [LM Studio](https://lmstudio.ai) | `http://localhost:1234/v1` |
| llama.cpp `llama-server` | `http://localhost:8080/v1` |
| mlx-lm `mlx_lm.server` | `http://localhost:8080/v1` |

- `summary.model` is the model name on the server and is required (there is no default). `cappy doctor` checks that the server is reachable and has the model.
- **Mind the context length.** An hour-long meeting is roughly 15-20K tokens in English (about 20K in Japanese), so you need a context length of 32K tokens or more. Ollama's default context is short and silently cuts off the rest, so create a model with a wider `num_ctx` as in step 4 of the setup. In LM Studio, set the Context Length when loading the model.
- As a rough guide to memory: a quantized 9-12B model (Qwen3.5 9B, Gemma 4 12B, ...) on a 16 GB Mac, and a 20-30B model (Qwen3 30B, ..., including MoE) with 32 GB or more. The quality of the minutes depends a lot on the model size.
- `summary.effort` (thinking effort) is not sent. `summary.max_tokens` is sent as the output limit.
- `cappy speakers` (speaker naming) uses the same server. `speakers.model` can choose another model.

## What is sent outside

- Recordings, transcripts and summaries are not sent.
- The first time only, the WhisperKit and SpeakerKit models are downloaded from Hugging Face, and Apple's speech model from Apple.
- If the LLM server is on another machine (`base_url` other than localhost), the transcript is sent to that machine.
