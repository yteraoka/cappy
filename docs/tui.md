# cappy tui

English | [日本語](./tui.ja.md)

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

### Past recordings

Tab switches between the "Record" and "Past recordings" pages. The past recordings page lists the sessions in the output directories (`output_dir`) of all profiles, newest first, with the date, length, whether there is a transcript and a summary, and the name and target. The lower part shows the folder, the track lengths, the transcription and summary state, and the markers of the chosen session.

Enter opens a menu of actions. The common ones also run directly with a key in the list.

| Key | Action |
| --- | --- |
| `t` | Show the transcript (`transcript.md`) |
| `l` | Show the live transcript (`live-transcript.md`) |
| `s` | Show the summary (`summary.md`) |
| Menu only | Create the summary (only for sessions transcribed but not summarized yet) |
| Menu only | Create the summary again (sessions already summarized; for example with another profile or model) |
| `p` | Play both tracks together (mixes the two files to send and opens it in the default player) |
| Menu only | Open the remote / mic audio (the original CAF, or the file to send if there is none) |
| `f` | Show the folder in Finder |
| `d` | Delete (move the session folder to the Trash) |
| `r` | Reload the list |

- The text view scrolls (↑↓, Space / b for pages, g / G for top / bottom, q back to the list).
- Audio is handed to the default app (usually QuickTime Player) with `open`. The mix is created in a temporary directory (`$TMPDIR/cappy-playback/`) and reused next time. For a session transcribed with `--mix`, the mix made then is opened.
- Actions whose files do not exist (such as the transcript of a session not transcribed yet) are not shown.
- To create the summary (or create it again), choose the profile first, then the model (Enter goes on, Esc goes back).
  - The profiles are those whose `summary.provider` is not `none`. The profile the session was recorded with is chosen first; when only one profile can be chosen, it starts from the model.
  - As with "Summary model" on the recording page, the models are fetched with the API and only those that can actually be used are shown (while loading, you can still start with the profile's default model at the top). The fetched lists are shared with the recording page.
  - Then it does the same as `cappy summarize --profile <name> [--model <id>] [--force] <dir>` (from `transcript.json`, or `live-transcript.json` if there is none). Creating it again uses `--force` and rewrites `summary.md`. The progress is shown on the full screen, and the list comes back when it is finished. Ctrl-C interrupts it and goes back to the list.
- Deleting asks first ("Cancel" is chosen at first; choose "Move to the Trash" and press Enter, or press `y`). The folder goes to the Trash rather than being removed, so it can be restored from Finder. The temporary mix made for playback is removed too. A session being recorded in another terminal cannot be deleted. Audio left in Cloud Storage or S3 is not deleted (it is normally deleted after transcription).

### Stopping and interrupting

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
