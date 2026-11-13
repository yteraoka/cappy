import Foundation

/// 録音した音声に、文字起こしできる音が入っているかの判定
public enum SilenceCheck {
    /// 録音を始めてからこの秒数たっても相手側（remote）に音が一度も入らなければ、録音中に警告する
    public static let remoteWarnAfter: TimeInterval = 60

    /// 完全に無音のトラックを除いて、文字起こしに送る音声が残るか。
    /// ずっとミュートしていたマイクは無音として記録されるので silent に含まれる
    public static func hasAudio(tracks: [TrackID], silent: [TrackID]) -> Bool {
        tracks.contains { $0 != .mix && !silent.contains($0) }
    }
}

/// 録音中に、相手側（remote）が録音開始からずっと完全な無音かを見張る。
/// 録音対象の選び間違い（音を出さないアプリを選んだなど）に録音中に気付けるようにする
public struct RemoteSilenceWatch: Sendable {
    public enum Event: Equatable, Sendable {
        /// 録音開始から warnAfter 秒たっても音が一度もない
        case stillSilent
        /// 警告した後に音が入った
        case soundDetected
    }

    public let warnAfter: TimeInterval
    public private(set) var warned = false
    private var heard = false

    public init(warnAfter: TimeInterval = SilenceCheck.remoteWarnAfter) {
        self.warnAfter = warnAfter
    }

    /// 警告を出していて、まだ音が入っていないか（ステータス行に出す）
    public var isWarning: Bool { warned && !heard }

    /// - Parameters:
    ///   - elapsed: 録音の経過秒数
    ///   - overallPeak: 録音開始からの remote のピーク（nil はまだデータがない）
    /// - Returns: 表示すべき変化があればそのイベント
    public mutating func update(elapsed: TimeInterval, overallPeak: Float?) -> Event? {
        if heard { return nil }
        if let p = overallPeak, p > 0 {
            heard = true
            return warned ? .soundDetected : nil
        }
        if !warned && elapsed >= warnAfter {
            warned = true
            return .stillSilent
        }
        return nil
    }
}
