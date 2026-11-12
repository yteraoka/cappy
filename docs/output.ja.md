# 出力

[English](./output.md) | 日本語

```text
~/Recordings/cappy/2026-11-11T1000_weekly-sync/   (0700)
├── session.json       # メタデータと処理状態（tracks, gaps, markers, mic_mutes, transcription ...）
├── remote.caf         # 相手側（タップ）録音中の原本（ネイティブ形式・Float32）
├── mic.caf            # 自分（マイク）録音中の原本
├── remote.flac        # 送信用（16 kHz・モノラル・16 bit。FLAC が使えなければ WAV）
├── mic.flac
├── transcript.json    # 正規化した文字起こし結果（segments: track, speaker, start_ms, end_ms, text, confidence）
├── transcript.md      # 読む用（mic =「自分」、remote =「相手」／話者分離があれば「相手 1」「相手 2」。日本語以外の会議では Me / Remote）
├── transcript.srt     # 字幕・動画編集用
├── live-transcript.{md,json,srt}  # リアルタイム文字起こしの結果（record --live）
├── summary.md         # 会議の要約（cappy summarize / --summarize）
└── cappy.log          # イベント・時刻・エラーのみ（本文は出さない）
```

ファイルはすべて 0600 で作成します。ログは統合ログ（サブシステム `dev.cappy`）にも出します（`log stream --predicate 'subsystem == "dev.cappy"'`）。
