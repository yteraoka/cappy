# gcappy (menu bar app)

English | [日本語](./gcappy.ja.md)

gcappy is the GUI version of cappy. From an icon in the menu bar, you pick a meeting app to start recording, and stop, mute the microphone or take screenshots. After recording, it transcribes and summarizes as you selected.

## Install

```bash
brew install yteraoka/cask/gcappy
gcappy        # put it in the menu bar (opens gcappy.app)
```

- `gcappy.app` is installed to `$(brew --prefix gcappy)/gcappy.app`. It bundles cappy itself (`gcappy.app/Contents/MacOS/cappy`), so you do not need the cappy CLI separately (install `brew install yteraoka/cask/cappy` if you also use it in a terminal).
- To start it from Spotlight or Launchpad, link it into `~/Applications`:

  ```bash
  mkdir -p ~/Applications && ln -sf "$(brew --prefix gcappy)/gcappy.app" ~/Applications/gcappy.app
  ```

- To start it automatically, choose "Launch at Login" in the menu.
- From source: `make app` (creates `dist/gcappy.app`), `make install-app` (copies it to `~/Applications`).

## Usage

Click the waveform icon in the menu bar to open the menu.

| Menu | What it does |
| --- | --- |
| Record (last target) | Starts recording right away if the app you recorded last is among the audio processes now (⌘R) |
| Start Recording ▸ | Pick the target from the audio processes (a speaker icon means it is playing). The last item, "All system audio", is `--system` |
| Profile ▸ | Profiles of the config file (`~/.config/cappy/config.toml`) |
| After Recording ▸ | Record only / transcribe / transcribe → summarize / live transcription (→ summarize), the same choices as `cappy tui` |
| Microphone ▸ | On / start muted / off (do not record) |
| Stop Automatically ▸ | Stop after a duration (`--duration`) |
| Ask for a Session Name | Before recording, show the consent reminder and a field for the session name |
| Open Recordings Folder | `output_dir` of the profile |
| Tools ▸ | Reveal the config file, run `cappy init` / `cappy doctor` in Terminal, logs, Privacy & Security settings |

While recording, the icon becomes a red record mark with the elapsed time, and the menu has:

| Menu | What it does |
| --- | --- |
| Stop Recording (⌘.) | The same as Ctrl-C. Then creates the files to send, and transcribes / summarizes as selected |
| Mute Microphone (⌘M) | The same as `cappy mic toggle`. While muted, the icon is a crossed-out microphone |
| Take Screenshot of the App Window (⌘S) | The same as `cappy shot` (needs the Screen Recording permission) |
| Open Session Folder | The session directory being recorded |

While processing after the recording, the icon is an hourglass. When done, gcappy posts a notification and the menu offers "Open Last Summary" and so on. If cappy ends with an error, gcappy shows the end of its output in a dialog.

Recordings not started by gcappy, such as `cappy record` in a terminal, are listed under "Other cappy recordings", where you can mute, take a screenshot or stop them.

## How it works

- gcappy runs the bundled cappy as a child process, like `cappy record --app <bundle ID> --profile <name> ... --quiet`. The config file, session directories and resuming with `cappy transcribe` all work exactly as with the CLI.
- Whether it is recording, and the mute state, come from the same registry as `cappy mic` / `cappy shot` (`cappy/record-<pid>.json` in the temporary directory), and are controlled with signals.
- cappy's output is saved to `~/Library/Logs/gcappy/record-<date>.log` (logs older than 30 days are deleted at launch). The recording log (`cappy.log`) is still kept in the session directory.
- Apps started from Finder or as login items do not get `PATH`, `AWS_PROFILE`, `GOOGLE_APPLICATION_CREDENTIALS` and so on from your shell. At launch, gcappy reads the environment variables of your login shell (`$SHELL -l -i`) and passes them to cappy.
- Messages follow the macOS preferred language (or `CAPPY_LANG` if set in your shell). The language of the files created is still decided by `language` of the profile.
- When you quit gcappy while recording, it asks and then stops the recording. Transcription and summary continue in the background (without a notification).

## Permissions

When recording from gcappy, the "System Audio Recording" and "Microphone" permissions are asked for **gcappy** (separately from the terminal you use cappy from).

- The first recording shows the permission dialogs. If they are not allowed, cappy exits with code 2 and gcappy shows a dialog with a button that opens the settings.
- Where to set them: System Settings > Privacy & Security > Screen & System Audio Recording ("System Audio Recording Only"), and "Microphone"
- Screenshots also need the "Screen & System Audio Recording" permission.

## Notes

- Tell the participants and get their consent before recording.
- Markers (Enter in `cappy record`) cannot be added from gcappy.
- If launching at login stops working after `brew upgrade gcappy`, start it once with `gcappy` and turn "Launch at Login" off and on again.
