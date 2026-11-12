# Output

English | [日本語](./output.ja.md)

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
