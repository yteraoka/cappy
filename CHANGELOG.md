# Changelog

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
