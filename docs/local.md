# Keeping everything on this Mac

English | [日本語](./local.ja.md)

With `provider = "local"`, transcription, speaker diarization, speaker naming and the summary all run on this Mac, and the recordings are not sent anywhere (except for downloading the models).

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
model = "qwen3:30b"
```

```bash
cappy doctor --profile on-device
cappy doctor --profile on-device --download-models   # download the models now (otherwise on the first transcription)
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
- **Mind the context length.** An hour-long meeting is roughly 15-20K tokens in English (about 20K in Japanese), so you need a context length of 32K tokens or more. Ollama's default context is short and silently cuts off the rest, so widen it, e.g. `OLLAMA_CONTEXT_LENGTH=32768 ollama serve`. In LM Studio, set the Context Length when loading the model.
- As a rough guide to memory: a quantized 7-8B model on a 16 GB Mac, and a 20-30B model (including MoE) with 32 GB or more. The quality of the minutes depends a lot on the model size.
- `summary.effort` (thinking effort) is not sent. `summary.max_tokens` is sent as the output limit.
- `cappy speakers` (speaker naming) uses the same server. `speakers.model` can choose another model.

## What is sent outside

- Recordings, transcripts and summaries are not sent.
- The first time only, the WhisperKit and SpeakerKit models are downloaded from Hugging Face, and Apple's speech model from Apple.
- If the LLM server is on another machine (`base_url` other than localhost), the transcript is sent to that machine.
