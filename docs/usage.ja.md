# 使い方

[English](./usage.md) | 日本語

```bash
cappy init                         # 設定ファイルを対話で作る（configuration.ja.md を参照）
cappy tui                          # 全画面で設定とアプリを選んで録音を始める（tui.ja.md を参照）
cappy apps                         # 音声プロセスの一覧（PID・bundle ID・出力中か）
cappy devices                      # 入力デバイスの一覧（UID・名前・サンプルレート）
cappy doctor                       # 権限・認証・設定・バケットの診断

# Zoom を録音（Ctrl-C で停止）
cappy record --app us.zoom.xos --name weekly-sync

# ブラウザ版 Meet を 90 分で自動停止し、続けて文字起こし
cappy record --app com.google.Chrome --duration 90m --transcribe

# 録音から文字起こし・要約まで続けて行う
cappy record --app us.zoom.xos --name weekly-sync --transcribe --summarize

# 録音後に文字起こし（中断しても同じコマンドで再開）
cappy transcribe ~/Recordings/cappy/2026-11-11T1000_weekly-sync

# 録音しながらリアルタイムで文字起こし（字幕を表示し、live-transcript.* に保存）
cappy record --app us.zoom.xos --name weekly-sync --live

# 文字起こし済みのセッションから要約を作る
cappy summarize ~/Recordings/cappy/2026-11-11T1000_weekly-sync

# 録音中のマイクをミュート / 解除する（別のターミナルやホットキーから）
cappy mic off
cappy mic on

# 異常終了したセッションの修復
cappy recover ~/Recordings/cappy/2026-11-11T1000_weekly-sync

# シェルの補完スクリプト（installation.ja.md を参照）
cappy completion zsh > ~/.zfunc/_cappy
```

## record

| オプション | 説明 |
| --- | --- |
| `--app <bundleID>` | 録音対象を bundle ID で指定（前方一致。`com.google.Chrome` で `com.google.Chrome.helper` も対象）。複数指定可 |
| `--pid <pid>` | 録音対象を PID で指定。複数指定可 |
| `--system` | 自分自身を除くシステム全体の出力を録音 |
| `--no-mic` / `--mic <UID>` | マイク録音の無効化 / 入力デバイスの指定（既定はシステムの既定入力。変更にも追従） |
| `--muted` | マイクをミュートした状態で録音を始める（「マイクのミュート」を参照） |
| `--out <dir>` / `--name <title>` | 保存先 / セッション名 |
| `--duration 90m` | 指定時間で自動停止（`1h30m`、`45s` なども可） |
| `--wait` | 対象が音声を出し始めるまで待つ |
| `--transcribe` (`--mix`, `--format`) | 録音後に続けて文字起こしする |
| `--live` | 録音しながらリアルタイムで文字起こしする（Gemini の `transcribe.live_model`。`transcribe.provider = "aws"` なら Amazon Transcribe Streaming）。確定した発言を表示し、`live-transcript.{md,json,srt}` に保存する |
| `--summarize` / `--no-summarize` | `--transcribe` / `--live` の後に続けて要約する（既定はプロファイルの `summary.auto`） |
| `--summary-model <id>` | 要約に使うモデル（既定はプロファイルの `summary.model`。`summarize --model` と同じ値） |
| `--summary-prompt <name\|path>` | 要約のテンプレート（既定はプロファイルの `summary.prompt`。`summarize --prompt` と同じ値） |
| `--profile <name>` | 設定プロファイル |
| `--quiet` | 録音の告知メッセージを出さない |
| `-v, --verbose` | IOProc のバッファ欠落数やリングバッファの使用率も出す |

- 録音中に Enter を押すとマーカー（目印）を `session.json` の `markers` に記録します。文字を入力してから Enter を押すとラベル付きになります（入力中の文字はステータス行に表示します。Backspace で 1 文字、Ctrl-U で全部消せます）。何も入力していないときに Space を押すとマイクをミュートします（「マイクのミュート」を参照）。
- 録音中はターミナルを 1 キーずつ読むモードにし、録音を止めると元に戻します。`kill -9` などで強制終了して入力した文字が表示されなくなった場合は `stty sane` を実行してください。
- Ctrl-C / SIGTERM で停止し、CAF を確定して送信用ファイルまで作ります。2 回目の Ctrl-C で変換を省いて終了します（あとで `recover` で作れます）。
- スリープの直前に停止して確定します。復帰後に自動で再開はしません。
- 録音開始から 1 分たっても相手側（remote）に音が一度も入らなければ、録音対象が違う（音を出さないアプリを選んだなど）可能性があるため警告し、ステータス行に「⚠️ 音声なし」と表示します。音が入ると表示は消えます。
- 録音したトラックがすべて完全に無音だった場合は、`--transcribe` / `--summarize` を指定していても文字起こしと要約を行いません（送っても結果が空になるため）。それでも実行するなら `cappy transcribe <ディレクトリ>` を使ってください。

### マイクのミュート

会議アプリはミュート中もマイクを使い続けるため、そのままでは会議アプリでミュートしている間の独り言や周りの音まで録音（と文字起こし）されます。会議アプリと一緒に cappy のマイクもミュートしてください。

- `cappy record` を実行しているターミナルで Space を押すと、ミュートを切り替えます（何も入力していないときだけ。マーカーのラベルを入力し始めたら Space はラベルの一部になります）。日本語入力中の全角スペースでも切り替わります。
- 別のターミナル・スクリプト・ホットキーからは `cappy mic off`（ミュート）、`cappy mic on`（解除）、`cappy mic toggle`、`cappy mic`（状態の表示）。複数の録音を実行中なら `--pid` で選びます。
- `cappy record --muted` でミュートした状態から始められます。
- ミュート中はマイクのトラックを無音で記録します。トラックの長さは変わらないので、相手側のトラックとの時刻もずれません。リアルタイム文字起こしにも無音を送ります。ミュートした区間は `session.json` の `mic_mutes` に記録し、ステータス行には「自分 🔇ミュート」と表示します。
- Zoom・Meet・Teams のミュート状態を cappy から読み取ることはできません（他のアプリに公開しておらず、たいていミュート中もマイクを開いたままにしているため）。合わせたい場合は、会議アプリのミュートのショートカットと `cappy mic toggle` を 1 つのホットキーにまとめる（ショートカット.app・Raycast・Hammerspoon・BetterTouchTool など）か、両方を同時に切り替えてください。
- `cappy mic` は `$TMPDIR/cappy/` のファイル（`CAPPY_RUNTIME_DIR` で変更可）から録音中のプロセスを探し、SIGUSR1（ミュート）/ SIGUSR2（解除）を送ります。PID が再利用された別のプロセスに送らないよう、プロセスの開始時刻も照合します。

### リアルタイム文字起こし（`--live`）

- 自分（mic）と相手（remote）をそれぞれ 16 kHz・モノラルの PCM にして、100 ms ごとに送ります。送り先は、プロファイルの `provider` が `aws` なら Amazon Transcribe Streaming、それ以外は Vertex AI の Live API です。確定した発言は `[00:01:23] 相手: …` の形で表示し、認識途中の文字はステータス行に出します。
- Live API は 1 セッションで約 10 分の音声までのため、9 分を過ぎたら話の切れ目で（遅くとも 9 分 45 秒で）次のセッションに張り替えます。Amazon Transcribe Streaming は 1 セッション 4 時間までのため、3 時間 50 分を過ぎたら同じように張り替えます。時刻は録音全体の時刻にそろえます。
- 接続が切れたら再接続します（その間の音声はリアルタイム文字起こしに含まれず、`session.json` の `live.dropped_ms` に記録します）。権限や設定の誤りで接続できない場合は、リアルタイム文字起こしだけを止めて録音は続けます。
- Live API では話者分離はできません（相手側は「相手」とだけ表示します）。Amazon Transcribe Streaming では remote トラックで話者分離を行い（`transcribe.diarization`）、`相手（0）` のように表示します（`live-transcript.md` では「相手 1」「相手 2」）。精度の高い結果が必要なら、録音後に `cappy transcribe` を実行してください（`--live --transcribe` で両方行えます）。
- 要約は `transcript.json` があればそれを、なければ `live-transcript.json` を使います。
- 録音中は `live-transcript.jsonl` に確定した発言を追記します。異常終了した場合は `cappy recover` で `live-transcript.*` を作ります。

## transcribe

| オプション | 説明 |
| --- | --- |
| `--provider google\|aws\|none` | 文字起こしに使うクラウド。既定はプロファイルの `transcribe.provider`（`google`） |
| `--model <id>` | `google` のとき、`gemini-*` なら Vertex AI の Gemini、それ以外（`chirp_3` など）なら Speech-to-Text v2。既定はプロファイルの `transcribe.model`（`gemini-3.5-transcribe`） |
| `--language ja-JP` | 既定はプロファイルの `language` |
| `--mix` | 2 トラックをミックスした 1 本で送る。課金対象は約半分になるが、自分と相手の区別は失われる |
| `--format md,json,srt` | 出力形式 |
| `--force` | 既存のジョブを破棄してやり直す |
| `--keep-remote` | バケット上の音声と結果（Amazon Transcribe ならジョブ）を削除しない |
| `--summarize` / `--no-summarize` | 続けて要約する（既定はプロファイルの `summary.auto`） |

## summarize

`transcript.json` を Vertex AI の Claude / Gemini、または Amazon Bedrock のモデル（`summary.provider = "aws"`）に送り、`summary.md` に次の構成で書き出します: 概要 / 決定事項 / アクションアイテム（担当・内容・期限・時刻の表）/ 議論の要点 / 未解決事項・持ち越し（英語などの会議では、見出しも会議の言語になります）。決定事項などには根拠となる発言の時刻 `[HH:MM:SS]` が付くので、`transcript.md` で前後を確認できます。

| オプション | 説明 |
| --- | --- |
| `--model <id>` | 既定はプロファイルの `summary.model`（`gemini-4-argon`、Bedrock なら `claude-opus-5-5`）。`gemini-` で始まれば Gemini、`claude-` で始まれば Claude（例: `gemini-3.5-flash`、`claude-opus-5-5`）。Bedrock では `jp.anthropic.claude-opus-5-5` のような Bedrock のモデル ID も指定できます |
| `--effort low\|medium\|high\|xhigh\|max` | 思考の深さ。既定はプロファイルの `summary.effort`（`high`）。Gemini 3 以降では `thinkingLevel` の LOW / MEDIUM / HIGH（`xhigh` と `max` は HIGH）に対応させ、Gemini 2.5 以前では指定せずモデルの動的な思考に任せます |
| `--force` | 同じ文字起こし・依頼文から作った要約があっても作り直す |
| `--prompt <name\|path>` | 構成のテンプレート（下の「要約のテンプレート」）。既定はプロファイルの `summary.prompt`、なければ組み込みの `default` |
| `--print-prompt` | テンプレート（`--prompt` か `summary.prompt`、なければ組み込み）を表示して終わる。セッションディレクトリは不要 |
| `--print-system-prompt` | 送る依頼文の全体を表示して終わる（セッションを渡すと、その文字起こしの言語で） |

- 文字起こしをやり直した場合（`transcript.json` が変わった場合）は、`--force` なしでも作り直します。
- 録音中に付けたマーカーは「本人が重要だと考えた箇所」として要約に反映されます。録音の欠落区間も伝えます。
- 要約の本文は `cappy.log` や `session.json` には書きません（`session.json` の `summary` にはモデル・トークン数・状態だけを記録します）。
- モデルが要約を拒否した場合（Claude の `stop_reason: refusal`、Gemini の安全性による停止）は、`summary.fallback_model` で 1 回だけ再試行し、その旨を `summary.md` に書きます。既定は Claude なら `claude-opus-4-8`、Gemini なら再試行しません（Claude と Gemini をまたいだ指定も可）。Vertex AI ではサーバー側の自動フォールバックが使えないため、cappy 側で行っています。
- Gemini で、指定した思考レベルにモデルが対応していない（400）場合は、思考の設定を外して再試行します。

### 要約のテンプレート

出力の構成（見出しと書き方）は、テンプレートで差し替えられます。

1. 組み込みのテンプレートを書き出して、名前を付けて保存します。設定ファイルと同じディレクトリの `prompts/` に置きます（`CAPPY_CONFIG` や `XDG_CONFIG_HOME` を使っていればそれに従います）。

   ```bash
   mkdir -p ~/.config/cappy/prompts
   cappy summarize --print-prompt > ~/.config/cappy/prompts/minutes.md
   ```

2. Markdown を編集します。`{{language}}` は出力する言語の名前（日本語 / English など）、`{{language_code}}` は言語コード（`ja-JP` など）に置き換わります。
3. プロファイルの `summary.prompt = "minutes"` で既定にするか、その場で `cappy summarize --prompt minutes <dir>`（録音から続けるなら `cappy record --summary-prompt minutes ...`）で選びます。`cappy tui` では、自分で作ったテンプレートがあれば録音の画面と過去の録音の要約で選べます。

- テンプレートが差し替えるのは「# 出力」の中身だけです。入力の説明（話者ラベル・時刻・マーカー）、`<transcript>` の中の指示に従わないこと、最上位の見出しを書かないこと、文字起こしにない事実を足さないことは、cappy が固定で付けます。
- `summary.prompt` には名前のほか、`.md` ファイルのパス（`~/work/prompts/1on1.md` など）も書けます。`prompts/default.md` を置くと、組み込みの default の代わりに使います。
- 出力は会議の言語（プロファイルの `language`）で書かせます。日本語以外の会議では、テンプレートの見出しも会議の言語に訳して書かれます。
- `summary.instructions_file` の追加の指示は、テンプレートと一緒に使えます（依頼文の最後に付きます）。
- 送る依頼文の全体は `cappy summarize --print-system-prompt [--prompt <name>] [<dir>]` で確かめられます。
- テンプレートや追加の指示を変えると、`--force` なしでも作り直します（`session.json` の `summary.prompt_digest` で比べます）。使ったテンプレートは `summary.md` の冒頭と `session.json` の `summary.prompt` に記録します。

## 終了コード

| コード | 意味 |
| --- | --- |
| 0 | 正常終了 |
| 1 | 引数・設定の誤り |
| 2 | 権限不足（システムオーディオ録音またはマイク） |
| 3 | 録音対象のプロセスが見つからない |
| 4 | 録音中の I/O エラー（ディスク容量不足など） |
| 5 | 文字起こし・要約サービスのエラー（認証・クォータ・ジョブ失敗） |
