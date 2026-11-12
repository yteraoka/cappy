# Installation

English | [日本語](./installation.ja.md)

## Homebrew

```bash
brew install yteraoka/cask/cappy
```

See [Distribution](./distribution.md) for details.

## Build and install from source

Requires Swift 6 / Xcode 16 or later (Swift Package Manager).

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
