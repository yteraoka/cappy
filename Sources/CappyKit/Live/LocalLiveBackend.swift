import Foundation

/// 短い発言の音声をまとめて認識する端末内の認識（WhisperKit）。リアルタイム文字起こし用
public protocol LocalUtteranceRecognizer: Sendable {
    /// モデルを読み込む（なければダウンロードする）。最初のセッションを開くときに 1 回呼ぶ
    func prepare() async throws
    /// 16 kHz・モノラルの音声（-1〜1）を認識する。時刻は samples の先頭からの ms
    func recognize(samples: [Float], language: String) async throws -> [RecognizedPiece]
}

/// 16 kHz・モノラル・16 bit の音声を、話の切れ目（無音）で発言ごとに区切る。
/// 長く話し続けたときは maxUtteranceMs で区切る。無音だけの区間は捨てる
public struct UtteranceSegmenter: Sendable {
    public struct Utterance: Sendable, Equatable {
        /// セッションの先頭からの位置（ms）
        public var startMs: Int64
        public var samples: [Float]
        public var durationMs: Int64 { Int64(samples.count) * 1000 / Int64(UtteranceSegmenter.sampleRate) }
    }

    public static let sampleRate = 16_000
    /// 100 ms ごとの音の大きさで話しているかを見る
    static let frameSamples = sampleRate / 10

    /// この RMS（-1〜1 の音声）を超えたら話しているとみなす
    public var threshold: Float = 0.01
    /// この長さの無音が続いたら発言の終わりとみなす（ms）
    public var quietMs: Int64 = 800
    /// 発言がこの長さを超えたら、話の途中でも区切る（ms。Whisper は 30 秒ずつ処理するため、それより短く）
    public var maxUtteranceMs: Int64 = 25_000
    /// 話している時間の合計がこれより短い発言は捨てる（ms。咳や物音で認識を誤らないように）
    public var minVoicedMs: Int64 = 400
    /// 発言の前に残す無音（ms。話し始めを切らないように）
    public var prerollMs: Int64 = 300

    private var buffer: [Float] = []
    /// buffer の先頭の、セッションの先頭からの位置（サンプル）
    private var bufferStart: Int64 = 0
    /// 100 ms に満たない端数（次の音声と合わせて大きさを見る）
    private var partial: [Float] = []
    private var voicedFrames = 0
    private var silentFrames = 0
    private var inSpeech = false

    public init() {}

    /// 話している途中か
    public var isSpeaking: Bool { inSpeech }

    /// 音声を足す。区切れた発言を返す
    public mutating func feed(_ pcm: Data) -> [Utterance] {
        var samples = [Float](repeating: 0, count: pcm.count / 2)
        pcm.withUnsafeBytes { raw in
            for i in 0..<samples.count {
                samples[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }
        return feed(samples: samples)
    }

    public mutating func feed(samples: [Float]) -> [Utterance] {
        var out: [Utterance] = []
        partial += samples
        while partial.count >= Self.frameSamples {
            let frame = Array(partial.prefix(Self.frameSamples))
            partial.removeFirst(Self.frameSamples)
            if let u = push(frame) { out.append(u) }
        }
        return out
    }

    /// 残りを発言として返す（セッションの終わり）
    public mutating func flush() -> Utterance? {
        buffer += partial
        partial = []
        let u = inSpeech ? cut(count: buffer.count) : nil
        buffer = []
        inSpeech = false
        return u
    }

    private mutating func push(_ frame: [Float]) -> Utterance? {
        let rms = (frame.reduce(0) { $0 + $1 * $1 } / Float(frame.count)).squareRoot()
        let voiced = rms >= threshold
        buffer += frame
        let frameMs = Int64(1000 / 10)
        if !inSpeech {
            if voiced {
                inSpeech = true
                voicedFrames = 1
                silentFrames = 0
            } else {
                // 話していない間は、話し始めの手前の分だけ残す
                let keep = Int(prerollMs) * Self.sampleRate / 1000
                if buffer.count > keep {
                    let drop = buffer.count - keep
                    buffer.removeFirst(drop)
                    bufferStart += Int64(drop)
                }
            }
            return nil
        }
        if voiced {
            voicedFrames += 1
            silentFrames = 0
        } else {
            silentFrames += 1
        }
        let lengthMs = Int64(buffer.count) * 1000 / Int64(Self.sampleRate)
        if Int64(silentFrames) * frameMs >= quietMs || lengthMs >= maxUtteranceMs {
            let u = cut(count: buffer.count)
            buffer = []
            inSpeech = false
            return u
        }
        return nil
    }

    /// buffer の先頭 count サンプルを発言にする（話している時間が短ければ捨てる）
    private mutating func cut(count: Int) -> Utterance? {
        defer {
            bufferStart += Int64(count)
            voicedFrames = 0
            silentFrames = 0
        }
        guard Int64(voicedFrames) * 100 >= minVoicedMs else { return nil }
        return Utterance(startMs: bufferStart * 1000 / Int64(Self.sampleRate), samples: Array(buffer.prefix(count)))
    }
}

/// 発言ごとに区切って端末内で認識するリアルタイム文字起こし（WhisperKit）
public final class ChunkedLocalBackend: LiveBackend, @unchecked Sendable {
    public let name: String
    let recognizer: LocalUtteranceRecognizer
    let segmenter: UtteranceSegmenter
    private let lock = NSLock()
    private var preparing: Task<Void, Error>?

    public init(name: String, recognizer: LocalUtteranceRecognizer, segmenter: UtteranceSegmenter = UtteranceSegmenter()) {
        self.name = name
        self.recognizer = recognizer
        self.segmenter = segmenter
    }

    /// モデルの準備は、トラックが 2 本あっても 1 回だけ
    func prepare() async throws {
        let task = lock.withLock { () -> Task<Void, Error> in
            if let p = preparing { return p }
            let r = recognizer
            let t = Task { try await r.prepare() }
            preparing = t
            return t
        }
        do {
            try await task.value
        } catch {
            lock.withLock { preparing = nil }
            throw LiveConnectionError(message: tr("Could not load the local speech recognition model: \(error)", ja: "端末内の音声認識のモデルを読み込めませんでした: \(error)"),
                                      permanent: true)
        }
    }

    public func open(startMs: Int64, options: LiveTranscriber.Options,
                     onEvent: @escaping @Sendable (LiveTranscriber.Event) -> Void) async throws -> LiveSession {
        try await prepare()
        return ChunkedLocalSession(startMs: startMs, track: options.track, language: options.language,
                                   recognizer: recognizer, segmenter: segmenter, onEvent: onEvent)
    }
}

/// ChunkedLocalBackend の 1 セッション。区切れた発言を順に認識して Segment にする
final class ChunkedLocalSession: LiveSession, @unchecked Sendable {
    let startMs: Int64
    let track: TrackID
    let language: String
    let recognizer: LocalUtteranceRecognizer
    let onEvent: @Sendable (LiveTranscriber.Event) -> Void
    private let lock = NSLock()
    private var segmenter: UtteranceSegmenter
    /// 認識を順に行う（前の発言の認識が終わってから次へ）
    private var tail: Task<Void, Never>?
    private var dead = false
    private var _deathReason: String?

    init(startMs: Int64, track: TrackID, language: String, recognizer: LocalUtteranceRecognizer,
         segmenter: UtteranceSegmenter, onEvent: @escaping @Sendable (LiveTranscriber.Event) -> Void) {
        self.startMs = startMs
        self.track = track
        self.language = language
        self.recognizer = recognizer
        self.segmenter = segmenter
        self.onEvent = onEvent
    }

    var isDead: Bool { lock.withLock { dead } }
    var deathReason: String? { lock.withLock { _deathReason } }
    var deathIsPermanent: Bool { false }

    func markDead(_ reason: String) {
        lock.withLock {
            if !dead { _deathReason = reason }
            dead = true
        }
    }

    func sendAudio(_ chunk: LiveTranscriber.Chunk) async throws {
        let (utterances, speaking) = lock.withLock { () -> ([UtteranceSegmenter.Utterance], Bool) in
            let u = segmenter.feed(chunk.pcm)
            return (u, segmenter.isSpeaking)
        }
        for u in utterances { enqueue(u) }
        if speaking && utterances.isEmpty { onEvent(.interim(track, "…")) }
    }

    /// 端末内では時間の制限がないので張り替えない
    func shouldRotate(at positionMs: Int64, options: LiveTranscriber.Options) -> Bool { false }

    private func enqueue(_ u: UtteranceSegmenter.Utterance) {
        lock.withLock {
            let previous = tail
            let recognizer = self.recognizer
            let language = self.language
            let track = self.track
            let base = startMs + u.startMs
            let onEvent = self.onEvent
            tail = Task {
                await previous?.value
                do {
                    let pieces = try await recognizer.recognize(samples: u.samples, language: language)
                    onEvent(.interim(track, nil))
                    for p in pieces {
                        let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        onEvent(.segment(Segment(track: track, speaker: nil, startMs: base + p.startMs,
                                                 endMs: base + max(p.endMs, p.startMs), text: text, confidence: p.confidence)))
                    }
                } catch {
                    CappyLog.shared.warning(tr("live \(track.rawValue): local recognition failed: \(error)", ja: "live \(track.rawValue): 端末内の認識に失敗しました: \(error)"))
                }
            }
        }
    }

    func endAndDrain(timeout: Double) async {
        let last = lock.withLock { segmenter.flush() }
        if let last { enqueue(last) }
        guard let t = lock.withLock({ tail }) else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await t.value }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)) }
            await group.next()
            group.cancelAll()
        }
        onEvent(.interim(track, nil))
    }
}
