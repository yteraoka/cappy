# cappy：会議音声キャプチャ・文字起こし CLI 仕様書

Nov 11, 2026 · @Yoshinori Teraoka

## 概要と目的

本ツール（`cappy`）は、会議アプリの音声とマイク音声を仮想オーディオデバイスなしで別トラックとして録音し、外部サービスで文字起こしする macOS 用 CLI です。相手側の音声は Core Audio の Process Tap API で特定プロセスから直接取得し、自分の声はマイクから取得します。

- BlackHole や機器セットを手作業で用意する手間をなくし、コマンド 1 つで録音を始められるようにする。
- 自分と相手を別トラックで保存し、文字起こし結果で話者を区別しやすくする。
- 文字起こしは Google Cloud Speech-to-Text などの外部サービスに任せ、プロバイダを差し替えられる構造にする。
- 初期はファイル録音と事後の文字起こしに絞り、将来リアルタイム文字起こしを追加しても作り直しにならないパイプライン構成にする。

## スコープ

初期リリースは「録音してファイルに保存し、終了後に外部サービスで文字起こしする」までとし、リアルタイム文字起こしはフェーズ 3 で追加します。

| フェーズ | 範囲 | 主な機能 |
| --- | --- | --- |
| 1（初期） | 録音と事後文字起こし | 対象アプリの Process Tap 録音、マイク録音、トラック別ファイル保存、Google への送信と結果取得、Markdown / JSON / SRT 出力 |
| 2 | 運用性の強化 | 録音中断からの復旧、出力デバイス切替への追従、録音中のマーカー記録、プロファイル別設定 |
| 3 | リアルタイム文字起こし | 録音と並行したストリーミング認識、ターミナルへのライブ字幕表示 |

対象外とするもの：GUI、Windows / Linux 対応、会議への自動参加、映像の録画、議事録の要約生成（要約は出力した transcript を別ツールに渡す運用とする）。

## 動作環境と前提

Process Tap API が必要なため、対応 OS は macOS 15 以降とし、検証は macOS 15 と 26 の Apple Silicon 機で行います。

| 項目 | 内容 |
| --- | --- |
| OS | macOS 15 以降（Process Tap API は 14.2 で導入されたが、検証範囲に合わせて 15 以降とする） |
| 言語・ビルド | Swift 6、Swift Package Manager、CLI 引数は swift-argument-parser |
| 音声処理 | Core Audio（タップ、機器セット、IOProc）、AVFoundation（形式変換とファイル書き出し） |
| 外部依存 | なし（ffmpeg 不要）。Google への通信は URLSession で REST API を直接呼ぶ |
| 認証 | Google のアプリケーションデフォルト認証情報（`gcloud auth application-default login` またはサービスアカウント） |
| 配布 | Developer ID で署名し公証（notarization）したバイナリを、Homebrew の自前 tap で配布 |

権限は「システムオーディオ録音」と「マイク」の 2 つが必要です。CLI では許可の対象が実行元のターミナルアプリになるため、バイナリには `-sectcreate __TEXT __info_plist` で Info.plist を埋め込み、`NSAudioCaptureUsageDescription` と `NSMicrophoneUsageDescription` を定義します。

## 全体アーキテクチャ

&#91;embedded content: cappy の構成 · 録音 5 段、文字起こし 4 段\]

録音側はすべてローカルで動き、音声を外部（色付きの箱）に送るのは transcribe の実行時だけです。破線の StreamingSink はフェーズ 3 で追加するリアルタイム用のシンクです。

## CLI インターフェース

サブコマンドは `record`・`transcribe` を中心に、補助の `apps`・`devices`・`doctor`・`recover` の 6 つです。録音と文字起こしは別コマンドに分けますが、`record --transcribe` で連続実行もできるようにします。

```bash
cappy record    [--app <bundleID>]... [--pid <pid>]... [--system] [--no-mic] [--mic <deviceUID>]
                 [--out <dir>] [--name <title>] [--duration 90m] [--profile <name>] [--transcribe]
cappy transcribe <session-dir> [--provider google] [--language ja-JP] [--mix] [--format md,json,srt] [--profile <name>]
cappy apps      # 音声を出力中のプロセス一覧（PID・bundle ID・出力中か）
cappy devices   # 入力デバイス一覧（UID・名前・サンプルレート）
cappy doctor    # 権限・認証・設定の診断
cappy recover   <session-dir>   # 異常終了したセッションの修復
```

| オプション | 説明 |
| --- | --- |
| `--app` | 録音対象を bundle ID で指定。前方一致でヘルパープロセスも含める（例：`com.google.Chrome` で `com.google.Chrome.helper` も対象） |
| `--pid` | 録音対象を PID で指定 |
| `--system` | 自分自身を除くシステム全体の出力を録音 |
| `--no-mic` / `--mic` | マイク録音の無効化 / 入力デバイスの指定（既定はシステムの既定入力） |
| `--duration` | 指定時間で自動停止（既定は Ctrl-C まで） |
| `--mix` | 2 トラックをミックスした 1 本で文字起こしに送る（既定は 2 トラック個別送信）。課金対象の長さは約半分になるが、自分と相手の区別は失われる |
| `--profile` | 設定プロファイルの切替（クライアントごとに送信先や保存先を分ける用途） |

| 終了コード | 意味 |
| --- | --- |
| 0 | 正常終了 |
| 1 | 引数・設定の誤り |
| 2 | 権限不足（システムオーディオ録音またはマイク） |
| 3 | 録音対象のプロセスが見つからない |
| 4 | 録音中の I/O エラー（ディスク容量不足など） |
| 5 | 文字起こしサービスのエラー（認証・クォータ・ジョブ失敗） |

## 音声キャプチャ仕様

タップとマイクを 1 つのプライベート機器セットにまとめ、単一の IOProc で両方を受け取ります。こうするとクロックが 1 本になり、トラック間の時刻合わせが不要になります。

### 録音開始の手順

1. `kAudioHardwarePropertyProcessObjectList` で音声プロセスを列挙し、`--app` / `--pid` に一致するプロセスオブジェクト ID を集める（PID からの変換は `kAudioHardwarePropertyTranslatePIDToProcessObject`）。
2. `CATapDescription` を作る。対象プロセス指定、または `--system` 時は自プロセスを除外する全体タップとし、`muteBehavior` は `.unmuted`（本人には通常どおり聞こえる）、`isPrivate` は true とする。
3. `AudioHardwareCreateProcessTap` でタップを作成する。
4. `AudioHardwareCreateAggregateDevice` でプライベート機器セットを作る。メインサブデバイスは既定の出力デバイス、タップリストにタップ、サブデバイスにマイクを入れ、マイク側のドリフト補正を有効にする。
5. `AudioDeviceCreateIOProcIDWithBlock` で IOProc を登録し、`AudioDeviceStart` で開始する。

### データ処理

- IOProc（リアルタイムスレッド）では処理をせず、受け取ったバッファをロックフリーのリングバッファに書くだけにする。
- 別スレッドの Writer がリングバッファから読み、チャンネルをトラック（remote / mic）に振り分けて書き出す。
- 録音中の保存形式は、タップから届くネイティブ形式（通常 48 kHz・Float32）の CAF とする。CAF は長さ未確定でも読めるため、異常終了時にも復旧できる。
- 録音終了時に AVAudioConverter で 16 kHz・モノラル・16 bit に変換し、送信用ファイル（FLAC、不可なら WAV）を作る。
- 録音開始時刻（ホストタイムと UTC）を記録し、各トラックの先頭オフセットを session.json に残す。

### 録音中の変化への追従

- 対象アプリが新しい音声プロセスを起動した場合（ブラウザのタブ追加など）は、プロセス一覧のリスナーで検知してタップを作り直す。
- 既定の出力デバイスが変わった場合（ヘッドホンの抜き差しなど）は、機器セットを作り直す。
- いずれも作り直しの間に生じた欠落区間を session.json の `gaps` に記録する。

## 出力ファイルとメタデータ

1 回の録音を 1 つのセッションディレクトリにまとめ、録音から文字起こしまでの状態をすべて `session.json` に記録します。これにより `transcribe` や `recover` はディレクトリだけを引数に再開できます。

```text
~/Recordings/cappy/2026-11-11T1000_weekly-sync/
├── session.json       # メタデータと処理状態
├── remote.caf         # 相手側（タップ）録音中の原本
├── mic.caf            # 自分（マイク）録音中の原本
├── remote.flac        # 送信用（16 kHz・モノラル）
├── mic.flac
├── transcript.json    # 正規化した文字起こし結果
├── transcript.md      # 読む用
├── transcript.srt     # 字幕・動画編集用
└── cappy.log
```

| session.json の項目 | 内容 |
| --- | --- |
| `id`, `name` | セッション ID、`--name` の値 |
| `started_at`, `ended_at` | UTC の ISO 8601 |
| `targets` | 録音対象（bundle ID、PID、`system`） |
| `tracks` | トラックごとのファイル名、サンプルレート、先頭オフセット（ms） |
| `gaps` | 欠落区間（開始・終了・理由） |
| `markers` | 録音中に付けた目印（フェーズ 2） |
| `transcription` | プロバイダ、モデル、言語、ジョブ ID、状態（pending / running / done / failed） |
| `tool_version` | 生成した cappy のバージョン |

`transcript.json` はプロバイダに依存しない形式とし、トラック単位の結果を時刻順にマージした `segments` 配列（`track`、`speaker`、`start_ms`、`end_ms`、`text`、`confidence`）を持ちます。`transcript.md` では mic を「自分」、remote を「相手」（話者分離が有効なら「相手 1」「相手 2」）として、時刻付きで出力します。

## 外部文字起こし連携

初期実装のプロバイダは Google Cloud Speech-to-Text v2（モデル chirp\_3、リージョン us）とし、会議の長さの音声を扱うため、Cloud Storage 経由のバッチ認識（BatchRecognize）を使います。同期認識は音声長の上限が短い（概ね 1 分程度）ため使いません。

### 処理の流れ（トラックごと）

1. 送信用ファイル（`mic.flac`、`remote.flac`）を設定したバケットの `cappy/<session-id>/` 以下にアップロードする。
2. BatchRecognize を言語 `ja-JP`、単語タイムスタンプ有効で呼び出し（remote トラックは話者分離も有効にする。モデルが対応しない場合は話者分離なしで続行し、その旨を session.json に記録する）、返ったオペレーション名を session.json に保存する。
3. 長時間実行オペレーションをポーリングする（指数バックオフ、上限 5 分間隔）。
4. 結果を取得して共通形式の `segments` に変換し、2 トラックを時刻順にマージして transcript を出力する。
5. 設定に従い、バケット上の音声と結果を削除する（既定は削除）。

オペレーション名を保存しておくので、途中で CLI を終了しても `cappy transcribe <dir>` で再開できます。

既定では mic と remote の 2 トラックを個別に送信します。`--mix` を指定した場合は 2 トラックをミックスした 1 本だけを送ります。料金は音声の長さ単位なので課金対象は約半分になりますが、自分と相手の区別は失われ、話者の区別はプロバイダの話者分離に頼ることになります。

### プロバイダの抽象化

Google 以外（Gemini API、他社の音声認識など）に差し替えられるよう、プロバイダは次のプロトコルを実装する形にします。

```swift
protocol TranscriptionProvider {
    var name: String { get }
    func submit(_ track: AudioTrack, options: TranscriptionOptions) async throws -> JobHandle
    func status(of job: JobHandle) async throws -> JobStatus
    func result(of job: JobHandle) async throws -> [Segment]
    func cleanup(_ job: JobHandle) async throws
}
```

### 設定ファイル

`~/.config/cappy/config.toml` にプロファイル単位で書きます。認証情報そのものは書かず、アプリケーションデフォルト認証情報を使います。

```toml
[profiles.default]
provider = "google"
language = "ja-JP"
output_dir = "~/Recordings/cappy"

[profiles.default.google]
project_id = "my-project"
location = "us"
bucket = "my-cappy-bucket"
model = "chirp_3"
delete_remote_after = true
```

### 実装前に確認すること

以下は記憶ベースの情報なので、実装前に公式ドキュメントで確認します。

- chirp\_3 が `us` リージョンで日本語の BatchRecognize に対応しているか。
- remote トラックの話者分離（diarization）が chirp\_3 と日本語の組み合わせで使えるか。使えない場合は話者分離なしで進め、相手側は「相手」とだけ表記する。
- US リージョンへの音声送信が、クライアントごとのデータ取扱い条件で許されるか。許されない案件は `--profile` で送信先を切り替えるか、プロバイダを `none` にする。

## 権限・セキュリティ・プライバシー

会議音声は機密情報を含む前提で扱い、ローカルでは本人だけが読める権限で保存し、外部に置く時間は文字起こしに必要な間だけにします。

- **録音の告知**：録音は参加者への告知と同意を前提とする。`record` 開始時にその旨を 1 行表示する（`--quiet` で抑止可能）。
- **ローカルの保存**：セッションディレクトリは 0700、ファイルは 0600 で作成する。
- **ログ**：ログに文字起こし本文や音声の内容を出さない。出すのはイベント、時刻、エラーのみ。
- **認証情報**：設定ファイルにキーを書かず、アプリケーションデフォルト認証情報を使う。
- **クラウド側の保存**：バケットは均一なアクセス制御とし、ライフサイクルルールで 1 日後に自動削除する（ツール側の削除が失敗した場合の保険）。
- **クライアント別の分離**：`--profile` でプロジェクト、リージョン、バケットを切り替え、クライアントごとのデータ取扱い条件に合わせる。外部送信が許されない案件では、プロバイダを `none` にして録音だけ行う。
- **権限診断**：`doctor` でシステムオーディオ録音とマイクの許可状態、認証の有効性、バケットへの書き込み可否を確認する。

## エラー処理と運用

原則は「録音済みの音声を失わないこと」で、どの障害でも書き込み済みの CAF を壊さずに終了し、`recover` で送信用ファイルを作り直せる状態を保ちます。

| 事象 | 挙動 |
| --- | --- |
| 権限がない | 録音を始めずに終了コード 2。許可する場所（システム設定のプライバシー項目）を表示する |
| 対象プロセスが見つからない | 終了コード 3。`--wait` 指定時は対象が音声を出し始めるまで待機する |
| 対象アプリの音声プロセスが増減した | タップを作り直して録音を継続し、欠落区間を `gaps` に記録する |
| 既定の出力デバイスが変わった | 機器セットを作り直して継続し、欠落区間を記録する |
| ディスクの空きが閾値未満 | 警告を出し、さらに減ったら録音を安全に停止して終了コード 4 |
| Ctrl-C / SIGTERM | 録音を停止し、ファイルを確定して変換まで行う。2 回目の Ctrl-C で変換を省いて即時終了する |
| スリープ | スリープ前に停止して確定する。復帰後の自動再開はしない |
| 異常終了 | 次回 `recover <dir>` で CAF から送信用ファイルと session.json を再生成する |
| 文字起こしの失敗 | 一時的エラーは指数バックオフで再試行する。恒久的エラー（認証、クォータ）は終了コード 5、状態を `failed` として記録する |

ログは統合ログ（サブシステム `dev.cappy`）とセッションディレクトリの `cappy.log` の両方に出し、`--verbose` で IOProc のバッファ欠落数やリングバッファの使用率も出力します。

## 将来拡張：リアルタイム文字起こし

リアルタイム対応を後から足せるよう、初期実装の時点で Writer を「シンク」の 1 つとして実装し、リングバッファからの音声を複数のシンクに配れる構造にしておきます。フェーズ 3 ではストリーミング用のシンクを 1 つ追加するだけで済むようにします。

```swift
protocol AudioSink {
    func start(format: AVAudioFormat, track: TrackID) throws
    func consume(_ buffer: AVAudioPCMBuffer, at hostTime: UInt64)
    func finish() async throws
}
// フェーズ 1: FileSink（CAF 書き出し）
// フェーズ 3: StreamingSink（16 kHz に変換して認識サービスへ送信）
```

ストリーミング認識の候補は 2 つあり、フェーズ 3 着手時に精度と遅延を比べて選びます。

- **Google Speech-to-Text のストリーミング認識**：gRPC の双方向ストリームを使う。1 本のストリームに時間上限があるため、一定時間ごとに張り直し、境界で発話が切れないよう重なりを持たせる。
- **ローカル認識**：macOS 26 の SpeechAnalyzer（SpeechTranscriber）、または whisper.cpp を数秒単位のチャンクで実行する。外部送信が許されない案件でも使える。

表示は、ターミナルに「自分」「相手」を色分けして逐次表示し、確定した結果だけを `transcript.live.md` に追記します。録音終了後は従来どおりバッチ認識で清書版を作ります。

## テスト・マイルストーン・未決事項

実装は録音の確実さを先に固め、文字起こし連携はその後に載せる順で進めます。

### マイルストーン

1. **M1 タップ録音**：指定アプリ 1 つの音声を CAF に保存できる。`apps` と `doctor` の権限確認まで。
2. **M2 マイクとセッション**：機器セットでマイクを同時録音し、session.json と送信用ファイルを生成する。
3. **M3 Google 連携**：アップロード、BatchRecognize、ポーリング、マージ、3 形式の出力、再開。ここでフェーズ 1 完了。
4. **M4 堅牢化**：プロセス増減・出力デバイス変更への追従、`recover`、プロファイル（フェーズ 2）。
5. **M5 リアルタイム PoC**：StreamingSink を 1 方式で試作し、遅延と精度を評価する（フェーズ 3）。

### テスト方針

- **単体テスト**：形式変換、トラックのマージ、session.json の読み書き、プロバイダ応答から `segments` への変換。プロバイダは HTTP をスタブ化する。
- **録音の結合テスト**：既知の音声ファイルを `afplay` で再生し、その PID をタップする。録音結果と元音声の相互相関で、欠落とずれがないことを確認する。
- **実環境テスト**：Zoom、Teams、ブラウザ版 Google Meet で 60 分以上録音し、欠落、ずれ、CPU 使用率を確認する。Bluetooth ヘッドセット使用時と、録音中の出力切替も含める。
- **文字起こしの品質**：読み上げ原稿のある音声で文字誤り率（CER）を測り、モデルや設定を比べる基準にする。

### 未決事項

- [ ] chirp\_3（us）での日本語認識と話者分離の対応を、実装前に公式ドキュメントと実機で確認する
