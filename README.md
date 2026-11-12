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

## Language

The UI (help, messages, errors, `cappy doctor`, logs) is in English by default. cappy checks the following environment variables in order and uses Japanese when the value starts with `ja`:

1. `CAPPY_LANG` (`ja` / `en`)
2. `LC_ALL`
3. `LC_MESSAGES`
4. `LANG`

```bash
export CAPPY_LANG=ja    # always show Japanese
```

The headings and speaker names in `transcript.md`, `transcript.srt` and `summary.md`, and the summary prompt, follow the meeting language (`language` of the profile), not the UI language: "自分" / "相手 1" for `ja-JP`, and "Me" / "Remote 1" otherwise.

## Requirements

- macOS 15 or later (tested on Apple Silicon)
- Build: Swift 6 / Xcode 16 or later (Swift Package Manager)
- No external tools are needed (not even ffmpeg).

## Install

```bash
brew install yteraoka/cask/cappy
```

See [Distribution](#distribution) for details.

## Build and install from source

```bash
make build                      # .build/release/cappy
make install PREFIX=~/.local    # ~/.local/bin/cappy
make test                       # unit tests
```

The Info.plist with the usage description strings (`NSAudioCaptureUsageDescription` / `NSMicrophoneUsageDescription`) is embedded into the binary at link time with `-sectcreate __TEXT __info_plist` (`Support/Info.plist`).

## Shell completion

`cappy completion bash|zsh` prints a completion script (detected from `$SHELL` if omitted). The Homebrew formula installs the scripts.

```bash
# zsh (compinit must be called in ~/.zshrc)
mkdir -p ~/.zfunc
cappy completion zsh > ~/.zfunc/_cappy
# In ~/.zshrc, before compinit: fpath=(~/.zfunc $fpath)

# bash (with bash-completion)
mkdir -p ~/.local/share/bash-completion/completions
cappy completion bash > ~/.local/share/bash-completion/completions/cappy
# Without bash-completion, add to ~/.bashrc: source <(cappy completion bash)
```

Besides subcommands and options, these values are completed:

- `--profile`: profile names in the config file
- `record --app` / `--pid` / `--mic`: bundle IDs and PIDs of the current audio processes, and input device UIDs (zsh also shows names and whether a process is playing)
- `summarize --model`: commonly used models and the models in the config file
- `--effort`, `transcribe --provider` / `--model`, `--format`, `--language`, and session directories

## Permissions

Two permissions are needed: "System Audio Recording" and "Microphone". For a CLI, the permission is granted to **the terminal app you run cappy from** (Terminal, iTerm, ...).

- The first `cappy record` (or `cappy doctor --request-permissions`) shows the permission prompts.
- Settings: System Settings > Privacy & Security > Screen & System Audio Recording > "System Audio Recording Only", and "Microphone"
- Without permission, `record` exits with code 2 without recording.
- Even without system audio recording permission, creating the tap can succeed and the remote track becomes silent. cappy warns about this after recording.

## Initial setup

`cappy init` asks a few questions and writes the config file (`~/.config/cappy/config.toml`). It asks for:

- where to transcribe (Gemini on Vertex AI, Speech-to-Text, Amazon Transcribe, or none) and the meeting language
- the Google Cloud project and Cloud Storage bucket, or the AWS profile, Region and S3 bucket (it suggests the gcloud project and the profiles in `~/.aws/config`)
- where to summarize (Vertex AI, Amazon Bedrock, or none), the model and region, and whether to summarize automatically
- where to save recordings

```bash
cappy init                  # create the default profile
cappy init --profile aws    # add another profile
```

It shows the result before saving. If the config file already exists, the profile is added; a profile with the same name is replaced after confirmation (the previous file is kept as `config.toml.bak`; other profiles and comments are kept). Credentials are never written. At the end it lists the next steps (such as `gcloud auth application-default login` or `aws sso login`) and offers to run `cappy doctor`. The buckets themselves are not created; create them in advance.

## Usage

```bash
cappy init                         # create the config file interactively (see "Initial setup")
cappy tui                          # choose the settings and the app on a full screen, then record (see "tui")
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

# Shell completion script (see "Shell completion")
cappy completion zsh > ~/.zfunc/_cappy
```

### tui

`cappy tui` lets you choose the profile, the operation and the app to record on a full screen, and starts recording with Enter.

```
 cappy — choose the settings and the app to record

   Profile         default  (Gemini, ja-JP)
   Operation       Record → transcribe → summarize
   Summary model   gemini-4-argon (profile default)
   Mic             On
   Auto stop       None (Ctrl-C to stop)
   Session name    weekly-sync

   Apps that use audio (● playing; refreshed automatically)
 ▶ ● zoom.us                us.zoom.xos
     Google Chrome          com.google.Chrome  (3 processes)
     assistantd             com.apple.assistantd
     All system audio (except cappy)  --system

 ↑↓ move  Enter start recording  r refresh  q quit
```

- In the upper part, choose a row with ↑↓ and press Enter to open a window with the choices, then choose with ↑↓ and Enter (Esc cancels; ✓ marks the current value). ←→ also switches to the previous / next value directly. On the session name row, press Enter to start editing, then Enter to finish or Esc to cancel.
- The operation is one of "Record only", "Record → transcribe", "Record → transcribe → summarize", "Live transcription" and "Live transcription → summarize". Operations that the profile cannot do (`transcribe.provider` / `summary.provider` is `none`) are not shown. The initial choice goes up to the summary when `summary.auto` is true, otherwise up to the transcription.
- Operations that summarize show a "Summary model" row. Moving to that row fetches the available models with the API (while it is loading, you can still start recording with the profile's default model). The chosen model is passed with `cappy record --summary-model`; the config file is not changed.
  - Vertex AI (`summary.provider = "google"`): Gemini and Claude in Model Garden (`publishers/google/models` and `publishers/anthropic/models`). Embedding, image, audio and transcription models are left out.
  - Bedrock (`summary.provider = "aws"`): `ListFoundationModels` (text output, ACTIVE) and `ListInferenceProfiles`. When `summary.region` is a scope such as `global` / `jp`, the models with an inference profile in that scope; when it is a Region name, the models that can be called on demand in that Region. IAM must allow `bedrock:ListFoundationModels` and `bedrock:ListInferenceProfiles`.
  - The lists also contain models you have not requested or enabled (such as Anthropic models), so each model is called in a way that is not billed, and only the models that can be used with this project / account and `summary.region` are shown. Gemini: counting tokens; Claude on Vertex AI: a call with `max_tokens = 0` to the model's endpoint; Bedrock: the same check as `cappy doctor`. Models that return 403, 404 or an invalid model ID are left out; those that could not be checked because of a temporary error (429, 5xx, network) are shown with "? not verified". One request is sent per model (8 at a time), so the list can take a few seconds.
  - When fetching fails, the reason is shown in the list. Opening the choices again with Enter fetches again.
- The lower part lists the apps that use audio: those playing first, then apps in `/Applications` and the like, then system daemons (dimmed). It is refreshed every 1.5 seconds. Helpers such as `com.google.Chrome.helper` are grouped under the parent bundle ID (`--app` is a prefix match, so the helpers are recorded too).
- Choose an app and press Enter to start recording with those settings. The screen stays full-screen during the recording, conversion, transcription and summary, and shows the choices, the level meters or progress, and the messages (including live transcription captions). The equivalent `cappy record ...` is shown first.
- The keys while recording are the same as `record` (Space mutes / unmutes the mic, Enter adds a marker; type some text first to give it a label).
- `--profile` chooses the initial profile. On the choosing screen, q, Esc or Ctrl-C quits without doing anything.
- If the screen is broken because the terminal shows ambiguous-width characters as wide, `--ascii` (or `CAPPY_TUI_ASCII=1`) draws the symbols (`▶ ● ─ │ → …` and so on) with ASCII.

#### Past recordings

Tab switches between the "Record" and "Past recordings" pages. The past recordings page lists the sessions in the output directories (`output_dir`) of all profiles, newest first, with the date, length, whether there is a transcript and a summary, and the name and target. The lower part shows the folder, the track lengths, the transcription and summary state, and the markers of the chosen session.

Enter opens a menu of actions. The common ones also run directly with a key in the list.

| Key | Action |
| --- | --- |
| `t` | Show the transcript (`transcript.md`) |
| `l` | Show the live transcript (`live-transcript.md`) |
| `s` | Show the summary (`summary.md`) |
| Menu only | Create the summary (only for sessions transcribed but not summarized yet) |
| `p` | Play both tracks together (mixes the two files to send and opens it in the default player) |
| Menu only | Open the remote / mic audio (the original CAF, or the file to send if there is none) |
| `f` | Show the folder in Finder |
| `d` | Delete (move the session folder to the Trash) |
| `r` | Reload the list |

- The text view scrolls (↑↓, Space / b for pages, g / G for top / bottom, q back to the list).
- Audio is handed to the default app (usually QuickTime Player) with `open`. The mix is created in a temporary directory (`$TMPDIR/cappy-playback/`) and reused next time. For a session transcribed with `--mix`, the mix made then is opened.
- Actions whose files do not exist (such as the transcript of a session not transcribed yet) are not shown.
- Creating the summary does the same as `cappy summarize` with the profile the session was recorded with (`transcript.json`, or `live-transcript.json` if there is none). The progress is shown on the full screen, and the list comes back when it is finished. Ctrl-C interrupts it and goes back to the list.
- Deleting asks first ("Cancel" is chosen at first; choose "Move to the Trash" and press Enter, or press `y`). The folder goes to the Trash rather than being removed, so it can be restored from Finder. The temporary mix made for playback is removed too. A session being recorded in another terminal cannot be deleted. Audio left in Cloud Storage or S3 is not deleted (it is normally deleted after transcription).

#### Stopping and interrupting

| When | How | What happens |
| --- | --- | --- |
| Recording | Ctrl-C | Stops and saves the recording, then goes on to the conversion, transcription and summary that were chosen |
| Recording | The auto stop time is reached, the Mac goes to sleep, or `kill` (SIGTERM) from another terminal | Same as Ctrl-C |
| Stopping the recording | Ctrl-C | Skips the conversion to the files to send (run `cappy recover` later) |
| Converting | Ctrl-C | Interrupts. The recordings (CAF) are saved; redo with `cappy recover` |
| Transcribing | Ctrl-C | Interrupts. Resume with `cappy transcribe <dir>` |
| Summarizing | Ctrl-C | Interrupts. Redo with `cappy summarize <dir>` |
| Before recording starts (checking permissions, etc.) | Ctrl-C | Cancels without leaving anything |
| The screen for choosing the app | q, Esc or Ctrl-C | Quits `cappy tui` |

When the recording, transcription and summary are all finished (or end with an error), the screen goes back to choosing the app. The result (the session path or the error) is shown at the top, and `l` shows the log of the last recording again. The settings are kept, so you can start the next recording right away. Interrupting the conversion, transcription or summary with Ctrl-C quits `cappy tui` instead of going back.

When `cappy tui` quits, the messages it showed (for all the recordings) are written to the normal terminal, so the session paths and the commands to resume stay visible.

### record

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
| `--profile <name>` | Config profile |
| `--quiet` | Do not show the recording notice |
| `-v, --verbose` | Also show dropped IOProc buffers and ring buffer usage |

- Press Enter while recording to add a marker to `markers` in `session.json`. Type some text before Enter to give it a label (the text being typed is shown on the status line; Backspace deletes a character and Ctrl-U clears it). Press Space with nothing typed to mute the microphone (see "Muting the microphone").
- While recording, cappy reads the terminal one key at a time and restores the terminal settings when recording stops. If cappy is killed (e.g. `kill -9`) and the terminal stops echoing, run `stty sane`.
- Ctrl-C / SIGTERM stops recording, finalizes the CAF files and creates the files to send. A second Ctrl-C skips the conversion and exits (create them later with `recover`).
- cappy stops and finalizes the recording right before the Mac sleeps. It does not resume automatically after waking up.

#### Muting the microphone

Meeting apps keep using the microphone while you are muted in them, so cappy would otherwise record (and transcribe) what you say or the sounds around you during that time. Mute cappy's microphone together with the meeting app.

- Press Space in the terminal running `cappy record` to toggle the mute (only while nothing is typed; once you start typing a marker label, Space is part of the label). A full-width space from a Japanese input method works too.
- From another terminal, a script or a hotkey: `cappy mic off` (mute), `cappy mic on` (unmute), `cappy mic toggle`, `cappy mic` (show the state). When several recordings are running, choose one with `--pid`.
- `cappy record --muted` starts with the microphone muted.
- While muted, the mic track is recorded as silence, so the track keeps its length and stays aligned with the remote track. The live transcription also receives silence. The muted periods are recorded in `mic_mutes` of `session.json`, and the status line shows `mic 🔇muted`.
- cappy cannot read the mute state of Zoom, Meet or Teams (none of them make it available to other apps, and they typically keep the microphone open while muted). To keep the two in sync, bind one hotkey to both the meeting app's mute shortcut and `cappy mic toggle` (for example with Shortcuts, Raycast, Hammerspoon or BetterTouchTool), or mute in the meeting app and in cappy at the same time.
- `cappy mic` finds the recording through a file in `$TMPDIR/cappy/` (`CAPPY_RUNTIME_DIR` to change it) and sends SIGUSR1 (mute) / SIGUSR2 (unmute) to it. It checks the process start time so that a reused PID never receives the signal.

#### Live transcription (`--live`)

- The mic and remote tracks are each converted to 16 kHz mono PCM and sent every 100 ms. They go to Amazon Transcribe Streaming when `provider` of the profile is `aws`, and to the Vertex AI Live API otherwise. Final results are shown as `[00:01:23] Remote: …`, and text still being recognized is shown on the status line.
- The Live API accepts about 10 minutes of audio per session, so cappy switches to a new session at a pause after 9 minutes (at the latest at 9:45). Amazon Transcribe Streaming accepts 4 hours per session, so cappy switches the same way after 3 hours 50 minutes. Times are aligned to the whole recording.
- cappy reconnects when the connection drops (audio during that time is not in the live transcription and is recorded in `live.dropped_ms` of `session.json`). If it cannot connect because of a permission or configuration error, only the live transcription stops and recording continues.
- The Live API does not do speaker diarization (the remote side is shown only as "Remote"). Amazon Transcribe Streaming does speaker diarization on the remote track (`transcribe.diarization`) and shows `Remote (0)` (in `live-transcript.md`, "Remote 1" and "Remote 2"). For more accurate results, run `cappy transcribe` after recording (`--live --transcribe` does both).
- The summary uses `transcript.json` if it exists, or `live-transcript.json` otherwise.
- While recording, final results are appended to `live-transcript.jsonl`. If cappy ends abnormally, `cappy recover` creates `live-transcript.*`.

### transcribe

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

### summarize

Sends `transcript.json` to Claude / Gemini on Vertex AI, or to a model on Amazon Bedrock (`summary.provider = "aws"`), and writes `summary.md` with these sections: Overview / Decisions / Action items (a table of owner, task, due date and time) / Discussion points / Open issues and follow-ups (for a Japanese meeting the headings are in Japanese). Decisions and other items carry the time of the supporting statement, `[HH:MM:SS]`, so you can check the context in `transcript.md`.

| Option | Description |
| --- | --- |
| `--model <id>` | Default: `summary.model` of the profile (`gemini-4-argon`, or `claude-opus-5-5` on Bedrock). Models starting with `gemini-` use Gemini and `claude-` use Claude (e.g. `gemini-3.5-flash`, `claude-opus-5-5`). On Bedrock you can also give a Bedrock model ID such as `jp.anthropic.claude-opus-5-5` or `global.moonshotai.kimi-k3.1` |
| `--effort low\|medium\|high\|xhigh\|max` | Thinking effort. Default: `summary.effort` of the profile (`high`). For Gemini 3 and later it maps to `thinkingLevel` LOW / MEDIUM / HIGH (`xhigh` and `max` are HIGH); for Gemini 2.5 and earlier it is not set and the model's dynamic thinking is used |
| `--force` | Regenerate even if a summary of the same transcript exists |

- If the transcription was redone (`transcript.json` changed), the summary is regenerated without `--force`.
- Markers added while recording are passed to the model as "points the recording person considered important". Gaps in the recording are also passed.
- The summary text is not written to `cappy.log` or `session.json` (`summary` in `session.json` has only the model, token counts and state).
- If the model refuses (Claude `stop_reason: refusal`, a Gemini safety stop), cappy retries once with `summary.fallback_model` and notes it in `summary.md`. The default is `claude-opus-4-8` for Claude, and no retry for Gemini (you can cross between Claude and Gemini). Vertex AI has no server-side automatic fallback, so cappy does it.
- With Gemini, if the model does not support the requested thinking level (400), cappy retries without the thinking settings.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Invalid arguments or config |
| 2 | Missing permission (system audio recording or microphone) |
| 3 | The process to record was not found |
| 4 | I/O error while recording (e.g. disk full) |
| 5 | Transcription or summary service error (authentication, quota, job failure) |

## Configuration

Write profiles in `~/.config/cappy/config.toml` (override with the `CAPPY_CONFIG` environment variable). `cappy init` creates it interactively; see [`config.example.toml`](./config.example.toml) for all settings. Without a config file, cappy uses the defaults of the `default` profile (Gemini on Vertex AI for transcription and summary, language = ja-JP, output_dir = ~/Recordings/cappy).

A profile is made of these tables:

| Table | Contents |
| --- | --- |
| `[profiles.<name>]` | `language` (meeting language), `output_dir`, `disk_warn_mb`, `disk_stop_mb` |
| `[profiles.<name>.google]` | Google Cloud account shared by transcription and summary: `project_id`, `bucket`, `delete_remote_after` |
| `[profiles.<name>.aws]` | AWS account shared by transcription and summary: `profile`, `region`, `bucket`, `delete_remote_after` |
| `[profiles.<name>.transcribe]` | Transcription: `provider` (`google` / `aws` / `none`), `model`, `location`, `diarization`, ... |
| `[profiles.<name>.summary]` | Meeting summary: `provider` (`google` / `aws` / `none`), `model`, `region`, `auto`, ... |

`provider` chooses the cloud (the account in `[google]` or `[aws]`), and `model` chooses what to use:

| | `provider = "google"` | `provider = "aws"` |
| --- | --- | --- |
| Transcription | `model = "gemini-*"`: Gemini on Vertex AI (default `gemini-3.5-transcribe`)<br>other models (`chirp_3`, ...): Speech-to-Text v2 | Amazon Transcribe |
| Summary | Claude / Gemini on Vertex AI (default `gemini-4-argon`) | Claude and other models on Amazon Bedrock (default `claude-opus-5-5`) |

```toml
[profiles.default]
language = "ja-JP"

[profiles.default.google]
project_id = "my-project"
bucket = "my-cappy-bucket"

[profiles.default.transcribe]
provider = "google"
model = "gemini-3.5-transcribe"

[profiles.default.summary]
provider = "google"
model = "gemini-4-argon"
```

`summary.provider` defaults to `transcribe.provider`. In `[transcribe]`, `model`, `location` and `chunk_minutes` apply to the service of `model` (Gemini or Speech-to-Text), and the other settings (`diarization`, `word_timestamps`, `max_speakers`, ...) apply to every service that has them, so `cappy transcribe --model chirp_3` or `--provider aws` keep working with the defaults of that service.

Credentials are not written in the config file; cappy uses Google Application Default Credentials (ADC).

```bash
gcloud auth application-default login
# or a service account key: export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json
```

Supported ADC types are `authorized_user`, `service_account` and `impersonated_service_account`. With user credentials, `project_id` of the profile is sent as `x-goog-user-project` (the billing project).

### Google Cloud setup

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

### Summary setup (Claude / Gemini on Vertex AI)

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

### Transcription setup (Amazon Transcribe)

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

### Summary setup (models on Amazon Bedrock)

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

### AWS authentication

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

## Output

```text
~/Recordings/cappy/2026-11-11T1000_weekly-sync/   (0700)
├── session.json       # metadata and processing state (tracks, gaps, markers, mic_mutes, transcription ...)
├── remote.caf         # remote side (tap), original recording (native format, Float32)
├── mic.caf            # you (microphone), original recording
├── remote.flac        # file to send (16 kHz, mono, 16 bit; WAV if FLAC is not available)
├── mic.flac
├── transcript.json    # normalized transcription (segments: track, speaker, start_ms, end_ms, text, confidence)
├── transcript.md      # for reading (mic = "Me", remote = "Remote" / "Remote 1", "Remote 2" with diarization; 自分 / 相手 for Japanese meetings)
├── transcript.srt     # for captions and video editing
├── live-transcript.{md,json,srt}  # live transcription (record --live)
├── summary.md         # meeting summary (cappy summarize / --summarize)
└── cappy.log          # events, times and errors only (no meeting content)
```

All files are created with mode 0600. Logs also go to the unified log (subsystem `dev.cappy`): `log stream --predicate 'subsystem == "dev.cappy"'`.

## Implementation notes

- **Implementation language**: cappy is written in Swift rather than Go. The Process Tap API uses an Objective-C class (`CATapDescription`), and the IOProc is called on a real-time thread. With Go (cgo), that thread cannot enter the runtime, and GC pauses cannot be avoided (Swift 6 + SwiftPM + swift-argument-parser).
- **`tapautostart` is disabled**: when enabled, the aggregate device does not start IO until the tap target plays audio, so the microphone cannot be recorded in the meantime (confirmed on a real device).
- **Stream mapping**: the input streams of the aggregate device are ordered "sub-devices (in list order), then the tap" (confirmed on a real device). Input streams of the output device are skipped.
- **Following changes while recording**: when the target app gets new audio processes, cappy first replaces the tap targets with `kAudioTapPropertyDescription`. If that fails (it can return `'!hog'` on real devices), it recreates the device and records the gap in `gaps`. Nothing is done when processes only go away. The aggregate device is recreated when the default output or input device changes, and when the IOProc stops for more than 6 seconds. Gaps are filled with silence on both tracks, so the tracks never drift from each other or from real time.
- **Transcription with Gemini (default)**: the audio in the bucket is passed as `fileData` to `generateContent` of `gemini-3.5-transcribe` (v1beta1, `generationConfig.audioTranscriptionConfig`). With speaker diarization and timestamps, a request accepts up to 15 minutes, so the audio is split every 14 minutes by default, sent in parallel (up to 3), and merged with time offsets. The result of each chunk is saved in the session directory, so finished chunks are not sent again after an interruption. Segments are built from `parts[].audioTranscription` (`speakerLabel`, `words[].startOffset/endOffset`) in the response, and segments longer than 30 seconds are split at sentence ends or pauses. If diarization is rejected, the audio is sent again without it.
- **Live transcription (Amazon Transcribe Streaming)**: cappy connects to `wss://transcribestreaming.<region>.amazonaws.com:8443/stream-transcription-websocket` with a SigV4 presigned URL (signature in the query, valid for 5 minutes) and sends audio as `AudioEvent` messages in the event stream format (prelude with lengths and CRC32, headers, payload, message CRC32). Results of `TranscriptEvent` with `IsPartial = false` become final segments, split where the `Speaker` of the words changes. The end is signaled with an empty `AudioEvent`. The service does not answer WebSocket pings, so connection failures are detected on the first receive. `BadRequestException` (except a timeout caused by silence) is treated as not fixable by reconnecting, and only the live transcription stops. If speaker diarization is rejected, cappy reconnects without it.
- **Live transcription (Live API)**: cappy sends `setup` (`inputAudioTranscription`, `responseModalities: ["TEXT"]`) to the Live API (`wss://…/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent`) and audio as `realtimeInput.audio` (`audio/pcm;rate=16000`). `serverContent.inputTranscription` is treated as final and `interimInputTranscription` as text still being recognized. `LiveAudioSink`, an `AudioSink`, receives the audio while recording.
- **Amazon Transcribe results** (`provider = "aws"`): words and punctuation are taken from `results.items` of the result JSON and split into segments where the speaker (`speaker_label`, or `speaker_labels.segments` in the older format) changes, and at sentence ends, pauses (0.8 seconds) and length (30 seconds). Words are joined without spaces for Japanese and similar languages. The confidence is the average over the words.
- **chirp_3 limits** (Speech-to-Text): according to the documentation, BatchRecognize accepts "about 1 hour, or about 20 minutes with word timestamps". So the file to send is split every 19 minutes by default, sent in one request, and merged with time offsets (change with `chunk_minutes`). When split, speaker labels may not match across chunks.
- **Speaker diarization** (Speech-to-Text): chirp_3 supports Japanese speaker diarization (BatchRecognize only). It is enabled on the remote track; if the model rejects it (at submission or while running), cappy submits again without it and notes this in `transcription.jobs[].note` of `session.json`.
- **Summary**: `cappy summarize` chooses where to send the request by model name. Claude is called through the Messages API on Vertex AI (`streamRawPredict`, `anthropic_version = 2026-10-21`) with adaptive thinking and `effort`. Gemini is called with `streamGenerateContent?alt=sse` and `thinkingConfig.thinkingLevel`, and the thinking parts (`thought: true`) are not included in the output. Both are received as streams. The transcript is wrapped in `<transcript>`, and the model is told not to follow instructions inside it.
- **UI language**: strings are written side by side in the code as `tr("English", ja: "日本語")` and chosen by `L10n.current` (`CAPPY_LANG`, `LC_ALL`, `LC_MESSAGES`, `LANG`; English by default). A resource bundle is not used because it would prevent distributing a single binary. Output files follow the meeting language through `UILanguage.forDocument(language)`. The usage description strings in Info.plist cannot be switched, so they contain both English and Japanese.
- **System audio recording permission state**: there is no public API, so cappy calls `TCCAccessPreflight` / `TCCAccessRequest` of TCC.framework dynamically.

## Testing

```bash
make test                   # unit tests (format conversion, merging, session.json, provider responses, summary requests and responses, HTTP stubs, ...)
make integration-test       # recreating the aggregate device and checking the timeline on a real device
make integration-test TAP=1 # tap afplay by PID and check gaps and drift by cross-correlation with the source (requires system audio recording permission)
# Stream a 16 kHz audio file to the real Amazon Transcribe Streaming in real time (billed; CAPPY_AWS_LIVE_SPEAKERS=0 disables diarization)
AWS_PROFILE=my-profile CAPPY_AWS_LIVE_TEST=/path/to/remote.flac swift test --filter TranscribeStreamingIntegrationTests
```

## Distribution

cappy is distributed through a Homebrew tap (`Formula/cappy.rb` in [`yteraoka/homebrew-cask`](https://github.com/yteraoka/homebrew-cask)).

```bash
brew install yteraoka/cask/cappy
```

- Installs a prebuilt binary (Apple Silicon, macOS 15 or later) from GitHub Releases, together with the bash / zsh completion scripts.
- The binary is ad-hoc signed (Hardened Runtime, with the microphone input entitlement). Files installed by a formula get no quarantine attribute, so it runs without notarization. The recording and microphone permissions are granted to the terminal app you run cappy from.

### Release flow

1. When a PR is merged into main, tagpr (`.github/workflows/tagpr.yaml`) opens a release PR. The version in `Sources/CappyKit/Core/Version.swift` is also updated in this PR (`minor` / `major` labels change the increment).
2. When the release PR is merged, tagpr creates the `vX.Y.Z` tag and a GitHub Release.
3. Pushing the tag runs `.github/workflows/release.yaml` (macOS runner):
   1. Runs the tests
   2. Builds the ad-hoc signed `cappy-X.Y.Z-macos-arm64.zip` with `scripts/release.sh` and attaches it to the Release
   3. Rewrites the url and sha256 of `packaging/cappy.rb` with `scripts/formula.sh` and updates `Formula/cappy.rb` in the tap
4. For PRs, the same workflow only runs the tests and the release build.

Required settings (Settings > Secrets and variables > Actions of the cappy repository):

| Type | Name | Content |
| --- | --- | --- |
| Variable | `TAGPR_APP_ID` | Client ID of the GitHub App for tagpr |
| Secret | `TAGPR_APP_PRIVATE_KEY` | Private key of the same App |
| Variable | `HOMEBREW_APP_ID` | Client ID of the GitHub App used to create the Release and update the tap (Contents: Read and write) |
| Secret | `HOMEBREW_APP_PRIVATE_KEY` | Private key of the same App |

Install both Apps on cappy, and the `HOMEBREW_APP_ID` App also on `homebrew-cask`.

### Local build

```bash
CAPPY_SIGN_IDENTITY=- make release     # ad-hoc signed dist/cappy-<version>-macos-arm64.zip
scripts/formula.sh <version> <sha256>  # prints the formula for the tap

# To sign with Developer ID and notarize (for distribution outside Homebrew)
export CAPPY_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export CAPPY_NOTARY_PROFILE=cappy-notary   # created with xcrun notarytool store-credentials
make release
```

## Architecture notes

The writer delivers audio to "sinks" that implement the `AudioSink` protocol. The original recording goes to `FileSink` and live transcription to `LiveAudioSink`. Both receive the same audio taken from the ring buffer (with gaps filled with silence), so times are aligned across the whole recording.
