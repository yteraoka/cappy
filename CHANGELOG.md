# Changelog

## [v0.9.3](https://github.com/yteraoka/cappy/compare/v0.9.2...v0.9.3) - 2026-11-18

- スクリーンショットで、タイトルが会議に一致するウインドウを優先して撮る by @yteraoka in https://github.com/yteraoka/cappy/pull/45
- Update dependency macos to v26 by @renovate[bot] in https://github.com/yteraoka/cappy/pull/42
- macOS 26 SDK で出る AVAudioConverter の入力ブロックの Sendable の警告を直す by @yteraoka in https://github.com/yteraoka/cappy/pull/48

## [v0.9.2](https://github.com/yteraoka/cappy/compare/v0.9.1...v0.9.2) - 2026-11-18

- Configure Renovate by @renovate[bot] in https://github.com/yteraoka/cappy/pull/39
- Update dependency apple/swift-argument-parser to from: "1.8.2" by @renovate[bot] in https://github.com/yteraoka/cappy/pull/41
- スクリーンショットの前に WindowServer への接続を初期化する by @yteraoka in https://github.com/yteraoka/cappy/pull/44

## [v0.9.1](https://github.com/yteraoka/cappy/compare/v0.9.0...v0.9.1) - 2026-11-18

- スクリーンショットの CoreGraphics / ScreenCaptureKit の呼び出しをメインスレッドで行う by @yteraoka in https://github.com/yteraoka/cappy/pull/37

## [v0.9.0](https://github.com/yteraoka/cappy/compare/v0.8.0...v0.9.0) - 2026-11-17

- 録音中に s キーと cappy shot で録音対象のウインドウのスクリーンショットを撮れるようにする by @yteraoka in https://github.com/yteraoka/cappy/pull/35

## [v0.8.0](https://github.com/yteraoka/cappy/compare/v0.7.0...v0.8.0) - 2026-11-17

- cappy tui から文字起こし・要約を作り直せるようにし、前の結果をタイムスタンプ付きの名前で残す by @yteraoka in https://github.com/yteraoka/cappy/pull/32
- 引数なしの cappy で、設定があれば cappy tui を起動し、なければ cappy init を案内する by @yteraoka in https://github.com/yteraoka/cappy/pull/34

## [v0.7.0](https://github.com/yteraoka/cappy/compare/v0.6.0...v0.7.0) - 2026-11-13

- 要約のテンプレート対応と、相手側が無音のときの警告・文字起こしの省略 by @yteraoka in https://github.com/yteraoka/cappy/pull/30

## [v0.6.0](https://github.com/yteraoka/cappy/compare/v0.5.0...v0.6.0) - 2026-11-13

- live 文字起こしで、相手が話し続けても途中で確定させ、確定しなかった文字を捨てない by @yteraoka in https://github.com/yteraoka/cappy/pull/26
- Split README into topic docs under docs/ by @yteraoka in https://github.com/yteraoka/cappy/pull/28
- tui: 要約モデルを API で取得した一覧から選べるようにする by @yteraoka in https://github.com/yteraoka/cappy/pull/29

## [v0.5.0](https://github.com/yteraoka/cappy/compare/v0.4.0...v0.5.0) - 2026-11-12

- 全画面で録音から過去の録音の閲覧まで行う cappy tui を追加する by @yteraoka in https://github.com/yteraoka/cappy/pull/22
- cappy tui の描画のちらつきを抑える by @yteraoka in https://github.com/yteraoka/cappy/pull/23
- cappy tui の過去の録音から、まだ要約していないセッションの要約を作れるようにする by @yteraoka in https://github.com/yteraoka/cappy/pull/25

## [v0.4.0](https://github.com/yteraoka/cappy/compare/v0.3.0...v0.4.0) - 2026-11-12

- 対話で設定ファイルを作る cappy init を追加し、設定を provider（クラウド）と model（何を使うか）に整理する by @yteraoka in https://github.com/yteraoka/cappy/pull/19

## [v0.3.0](https://github.com/yteraoka/cappy/compare/v0.2.0...v0.3.0) - 2026-11-12

- 録音中にマイクの取り込みを on / off できるようにする（Space キーと cappy mic） by @yteraoka in https://github.com/yteraoka/cappy/pull/16
- 出力デバイスとタップのサンプルレートが異なっても remote を正しいレートで記録する by @yteraoka in https://github.com/yteraoka/cappy/pull/18

## [v0.2.0](https://github.com/yteraoka/cappy/compare/v0.1.0...v0.2.0) - 2026-11-11

- 表示を英語と日本語に対応し、既定を英語にする（README も英語に） by @yteraoka in https://github.com/yteraoka/cappy/pull/13

## [v0.1.0](https://github.com/yteraoka/cappy/commits/v0.1.0) - 2026-11-11

- 会議の要約（Claude on Vertex AI）を追加 by @yteraoka in https://github.com/yteraoka/cappy/pull/1
- 要約で Vertex AI の Gemini に対応し、既定を gemini-4-argon にする by @yteraoka in https://github.com/yteraoka/cappy/pull/2
- 文字起こしの既定を Vertex AI の gemini-3.5-transcribe にし、リアルタイム文字起こしを追加 by @yteraoka in https://github.com/yteraoka/cappy/pull/3
- AWS の認証（AWS_PROFILE・SSO 対応）と SigV4 署名を追加する by @yteraoka in https://github.com/yteraoka/cappy/pull/4
- 要約で Amazon Bedrock の Claude に対応する by @yteraoka in https://github.com/yteraoka/cappy/pull/5
- リアルタイム文字起こし（--live）で Amazon Transcribe Streaming に対応する by @yteraoka in https://github.com/yteraoka/cappy/pull/7
- Amazon Transcribe（#6）と Transcribe Streaming（#7）を main に取り込む by @yteraoka in https://github.com/yteraoka/cappy/pull/8
- Bedrock での要約で Kimi K3.1・GLM-5.3 などの Claude 以外のモデルを選べるようにする by @yteraoka in https://github.com/yteraoka/cappy/pull/9
- bash・zsh の補完スクリプトを出力する cappy completion を追加する by @yteraoka in https://github.com/yteraoka/cappy/pull/10
- 内容が古くなった仕様書を削除し、README からのリンクを外す by @yteraoka in https://github.com/yteraoka/cappy/pull/11
- Homebrew の tap で配布するためのリリースの仕組みを追加する by @yteraoka in https://github.com/yteraoka/cappy/pull/12
