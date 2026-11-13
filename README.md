# cappy

English | [日本語](./README.ja.md)

cappy is a macOS CLI that records a meeting app's audio (the remote side) and your microphone (you) as separate tracks, without a virtual audio device, then transcribes and summarizes the meeting.

- Transcription: Gemini on Vertex AI (`gemini-3.5-transcribe`, the default), Google Speech-to-Text v2 (chirp_3), Amazon Transcribe
- Summary: Claude / Gemini on Vertex AI, models on Amazon Bedrock (Claude, Kimi K3.1, GLM-5.3, ...)
- Live transcription while recording: the Vertex AI Live API (`gemini-3.5-transcribe-live`), Amazon Transcribe Streaming

How it works:

- The remote side is captured directly from specific processes with the Core Audio Process Tap API, and your voice from the microphone.
- The tap and the microphone are combined into one private aggregate device and received in a single IOProc. With a single clock, no alignment between tracks is needed.
- You can transcribe in real time while recording and show the results like captions (`--live`).
- All state from recording to transcription is kept in `session.json`. If cappy stops halfway, `cappy transcribe <dir>` resumes.

## Requirements

- macOS 15 or later (tested on Apple Silicon)
- No external tools are needed (not even ffmpeg).

## Install

```bash
brew install yteraoka/cask/cappy
```

To build from source (Swift 6 / Xcode 16 or later): `make build && make install PREFIX=~/.local`. See [Installation](./docs/installation.md) for shell completion and permissions.

## Quick start

```bash
cappy init      # create ~/.config/cappy/config.toml interactively
cappy doctor    # check permissions, authentication, settings and buckets
cappy apps      # find the bundle ID of the meeting app

# Record Zoom (stop with Ctrl-C), then transcribe and summarize
cappy record --app us.zoom.xos --name weekly-sync --transcribe --summarize

# Or choose the settings and the app on a full screen
cappy tui
```

The first recording asks for the "System Audio Recording" and "Microphone" permissions for your terminal app. Results are saved under `~/Recordings/cappy/<date>_<name>/` (`transcript.md`, `summary.md`, ...).

If cappy stops halfway, `cappy transcribe <dir>` resumes and `cappy recover <dir>` repairs a session that ended abnormally.

## Documentation

| Document | Contents |
| --- | --- |
| [Installation](./docs/installation.md) | Homebrew, building from source, shell completion, permissions |
| [Configuration](./docs/configuration.md) | `cappy init`, the config file and profiles, UI language |
| [Google Cloud setup](./docs/google-cloud.md) | Vertex AI / Speech-to-Text transcription and Claude / Gemini summaries |
| [AWS setup](./docs/aws.md) | Amazon Transcribe, Amazon Bedrock summaries, AWS authentication |
| [Usage](./docs/usage.md) | Commands, `record` / `transcribe` / `summarize` options, mic mute, live transcription, exit codes |
| [cappy tui](./docs/tui.md) | Full-screen UI, past recordings, stopping and interrupting |
| [Output](./docs/output.md) | Files in the session directory |
| [Development](./docs/development.md) | Testing, implementation and architecture notes |
| [Distribution](./docs/distribution.md) | Homebrew tap, release flow, local release build |
