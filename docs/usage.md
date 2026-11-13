# Usage

English | [日本語](./usage.ja.md)

```bash
cappy init                         # create the config file interactively (see configuration.md)
cappy tui                          # choose the settings and the app on a full screen, then record (see tui.md)
cappy apps                         # list audio processes (PID, bundle ID, whether playing)
cappy devices                      # list input devices (UID, name, sample rate)
cappy doctor                       # check permissions, authentication, settings and buckets

# Record Zoom (stop with Ctrl-C)
cappy record --app us.zoom.xos --name weekly-sync

# Record Meet in the browser, stop after 90 minutes, then transcribe
cappy record --app com.google.Chrome --duration 90m --transcribe

# Record, transcribe and summarize in one go
cappy record --app us.zoom.xos --name weekly-sync --transcribe --summarize

# Transcribe after recording (resume with the same command if interrupted)
cappy transcribe ~/Recordings/cappy/2026-11-11T1000_weekly-sync

# Transcribe in real time while recording (shows captions and saves live-transcript.*)
cappy record --app us.zoom.xos --name weekly-sync --live

# Summarize a transcribed session
cappy summarize ~/Recordings/cappy/2026-11-11T1000_weekly-sync

# Mute / unmute the mic of a running recording (from another terminal or a hotkey)
cappy mic off
cappy mic on

# Repair a session that ended abnormally
cappy recover ~/Recordings/cappy/2026-11-11T1000_weekly-sync

# Shell completion script (see installation.md)
cappy completion zsh > ~/.zfunc/_cappy
```

## record

| Option | Description |
| --- | --- |
| `--app <bundleID>` | Record by bundle ID (prefix match: `com.google.Chrome` also matches `com.google.Chrome.helper`). Repeatable |
| `--pid <pid>` | Record by PID. Repeatable |
| `--system` | Record all system output except cappy itself |
| `--no-mic` / `--mic <UID>` | Disable microphone recording / choose the input device (default: the system default input, following changes) |
| `--muted` | Start with the microphone muted (see "Muting the microphone") |
| `--out <dir>` / `--name <title>` | Output directory / session name |
| `--duration 90m` | Stop automatically after this duration (`1h30m`, `45s`, ... also work) |
| `--wait` | Wait until the target starts playing audio |
| `--transcribe` (`--mix`, `--format`) | Transcribe after recording |
| `--live` | Transcribe in real time while recording (`transcribe.live_model` with Gemini, or Amazon Transcribe Streaming when `transcribe.provider = "aws"`). Shows final results and saves them to `live-transcript.{md,json,srt}` |
| `--summarize` / `--no-summarize` | Summarize after `--transcribe` / `--live` (default: `summary.auto` of the profile) |
| `--summary-model <id>` | Model for the summary (default: `summary.model` of the profile; same values as `summarize --model`) |
| `--summary-prompt <name\|path>` | Template for the summary (default: `summary.prompt` of the profile; same values as `summarize --prompt`) |
| `--profile <name>` | Config profile |
| `--quiet` | Do not show the recording notice |
| `-v, --verbose` | Also show dropped IOProc buffers and ring buffer usage |

- Press Enter while recording to add a marker to `markers` in `session.json`. Type some text before Enter to give it a label (the text being typed is shown on the status line; Backspace deletes a character and Ctrl-U clears it). Press Space with nothing typed to mute the microphone (see "Muting the microphone").
- While recording, cappy reads the terminal one key at a time and restores the terminal settings when recording stops. If cappy is killed (e.g. `kill -9`) and the terminal stops echoing, run `stty sane`.
- Ctrl-C / SIGTERM stops recording, finalizes the CAF files and creates the files to send. A second Ctrl-C skips the conversion and exits (create them later with `recover`).
- cappy stops and finalizes the recording right before the Mac sleeps. It does not resume automatically after waking up.
- If the remote track has had no sound at all 1 minute after the recording started, cappy warns that the recording target may be wrong (for example an app that plays no audio) and shows `⚠️ no audio` on the status line until sound arrives.
- If every recorded track was completely silent, cappy skips the transcription and the summary even with `--transcribe` / `--summarize`, because the result would be empty. Run `cappy transcribe <directory>` to transcribe anyway.

### Muting the microphone

Meeting apps keep using the microphone while you are muted in them, so cappy would otherwise record (and transcribe) what you say or the sounds around you during that time. Mute cappy's microphone together with the meeting app.

- Press Space in the terminal running `cappy record` to toggle the mute (only while nothing is typed; once you start typing a marker label, Space is part of the label). A full-width space from a Japanese input method works too.
- From another terminal, a script or a hotkey: `cappy mic off` (mute), `cappy mic on` (unmute), `cappy mic toggle`, `cappy mic` (show the state). When several recordings are running, choose one with `--pid`.
- `cappy record --muted` starts with the microphone muted.
- While muted, the mic track is recorded as silence, so the track keeps its length and stays aligned with the remote track. The live transcription also receives silence. The muted periods are recorded in `mic_mutes` of `session.json`, and the status line shows `mic 🔇muted`.
- cappy cannot read the mute state of Zoom, Meet or Teams (none of them make it available to other apps, and they typically keep the microphone open while muted). To keep the two in sync, bind one hotkey to both the meeting app's mute shortcut and `cappy mic toggle` (for example with Shortcuts, Raycast, Hammerspoon or BetterTouchTool), or mute in the meeting app and in cappy at the same time.
- `cappy mic` finds the recording through a file in `$TMPDIR/cappy/` (`CAPPY_RUNTIME_DIR` to change it) and sends SIGUSR1 (mute) / SIGUSR2 (unmute) to it. It checks the process start time so that a reused PID never receives the signal.

### Live transcription (`--live`)

- The mic and remote tracks are each converted to 16 kHz mono PCM and sent every 100 ms. They go to Amazon Transcribe Streaming when `provider` of the profile is `aws`, and to the Vertex AI Live API otherwise. Final results are shown as `[00:01:23] Remote: …`, and text still being recognized is shown on the status line.
- The Live API accepts about 10 minutes of audio per session, so cappy switches to a new session at a pause after 9 minutes (at the latest at 9:45). Amazon Transcribe Streaming accepts 4 hours per session, so cappy switches the same way after 3 hours 50 minutes. Times are aligned to the whole recording.
- cappy reconnects when the connection drops (audio during that time is not in the live transcription and is recorded in `live.dropped_ms` of `session.json`). If it cannot connect because of a permission or configuration error, only the live transcription stops and recording continues.
- The Live API does not do speaker diarization (the remote side is shown only as "Remote"). Amazon Transcribe Streaming does speaker diarization on the remote track (`transcribe.diarization`) and shows `Remote (0)` (in `live-transcript.md`, "Remote 1" and "Remote 2"). For more accurate results, run `cappy transcribe` after recording (`--live --transcribe` does both).
- The summary uses `transcript.json` if it exists, or `live-transcript.json` otherwise.
- While recording, final results are appended to `live-transcript.jsonl`. If cappy ends abnormally, `cappy recover` creates `live-transcript.*`.

## transcribe

| Option | Description |
| --- | --- |
| `--provider google\|aws\|none` | Cloud to transcribe with. Default: `transcribe.provider` of the profile (`google`) |
| `--model <id>` | With `google`: `gemini-*` uses Gemini on Vertex AI, other models (e.g. `chirp_3`) use Speech-to-Text v2. Default: `transcribe.model` of the profile (`gemini-3.5-transcribe`) |
| `--language ja-JP` | Default: `language` of the profile |
| `--mix` | Send a single mix of the two tracks. About half the billed audio, but you and the remote side can no longer be told apart |
| `--format md,json,srt` | Output formats |
| `--force` | Discard existing jobs and start over |
| `--keep-remote` | Keep the audio and results in the bucket (and the job for Amazon Transcribe) |
| `--summarize` / `--no-summarize` | Then summarize (default: `summary.auto` of the profile) |

## summarize

Sends `transcript.json` to Claude / Gemini on Vertex AI, or to a model on Amazon Bedrock (`summary.provider = "aws"`), and writes `summary.md` with these sections: Overview / Decisions / Action items (a table of owner, task, due date and time) / Discussion points / Open issues and follow-ups (for a Japanese meeting the headings are in Japanese). Decisions and other items carry the time of the supporting statement, `[HH:MM:SS]`, so you can check the context in `transcript.md`.

| Option | Description |
| --- | --- |
| `--model <id>` | Default: `summary.model` of the profile (`gemini-4-argon`, or `claude-opus-5-5` on Bedrock). Models starting with `gemini-` use Gemini and `claude-` use Claude (e.g. `gemini-3.5-flash`, `claude-opus-5-5`). On Bedrock you can also give a Bedrock model ID such as `jp.anthropic.claude-opus-5-5` or `global.moonshotai.kimi-k3.1` |
| `--effort low\|medium\|high\|xhigh\|max` | Thinking effort. Default: `summary.effort` of the profile (`high`). For Gemini 3 and later it maps to `thinkingLevel` LOW / MEDIUM / HIGH (`xhigh` and `max` are HIGH); for Gemini 2.5 and earlier it is not set and the model's dynamic thinking is used |
| `--force` | Regenerate even if a summary of the same transcript and prompt exists |
| `--prompt <name\|path>` | Template for the structure (see "Summary templates" below). Default: `summary.prompt` of the profile, or the built-in `default` |
| `--print-prompt` | Print the template (`--prompt` or `summary.prompt`, otherwise the built-in one) and exit. No session directory is needed |
| `--print-system-prompt` | Print the whole prompt that would be sent and exit (with a session, in the language of its transcript) |

- If the transcription was redone (`transcript.json` changed), the summary is regenerated without `--force`.
- Markers added while recording are passed to the model as "points the recording person considered important". Gaps in the recording are also passed.
- The summary text is not written to `cappy.log` or `session.json` (`summary` in `session.json` has only the model, token counts and state).
- If the model refuses (Claude `stop_reason: refusal`, a Gemini safety stop), cappy retries once with `summary.fallback_model` and notes it in `summary.md`. The default is `claude-opus-4-8` for Claude, and no retry for Gemini (you can cross between Claude and Gemini). Vertex AI has no server-side automatic fallback, so cappy does it.
- With Gemini, if the model does not support the requested thinking level (400), cappy retries without the thinking settings.

### Summary templates

The structure of the output (headings and how to write them) can be replaced with a template.

1. Write out the built-in template and save it with a name in `prompts/`, in the same directory as the config file (`CAPPY_CONFIG` and `XDG_CONFIG_HOME` are followed).

   ```bash
   mkdir -p ~/.config/cappy/prompts
   cappy summarize --print-prompt > ~/.config/cappy/prompts/minutes.md
   ```

2. Edit the Markdown. `{{language}}` is replaced with the name of the output language (English, 日本語, ...) and `{{language_code}}` with the language code (`en-US`, ...).
3. Make it the default with `summary.prompt = "minutes"` in the profile, or choose it with `cappy summarize --prompt minutes <dir>` (or `cappy record --summary-prompt minutes ...` when summarizing right after recording). In `cappy tui`, templates you made can be chosen on the recording page and when summarizing a past recording.

- A template replaces only the contents of "# Output". cappy always adds the description of the input (speaker labels, times, markers), the rule not to follow instructions inside `<transcript>`, not to write a top-level heading, and not to add facts that are not in the transcript.
- `summary.prompt` can also be a path to a `.md` file (such as `~/work/prompts/1on1.md`). If `prompts/default.md` exists, it is used instead of the built-in default.
- The output is written in the meeting language (`language` of the profile). For a meeting in another language, the headings of the template are also written in that language.
- The extra instructions in `summary.instructions_file` can be used together with a template (they are added at the end of the prompt).
- Check the whole prompt that is sent with `cappy summarize --print-system-prompt [--prompt <name>] [<dir>]`.
- When the template or the extra instructions change, the summary is regenerated without `--force` (compared with `summary.prompt_digest` in `session.json`). The template used is recorded at the top of `summary.md` and in `summary.prompt` in `session.json`.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Invalid arguments or config |
| 2 | Missing permission (system audio recording or microphone) |
| 3 | The process to record was not found |
| 4 | I/O error while recording (e.g. disk full) |
| 5 | Transcription or summary service error (authentication, quota, job failure) |
