import Foundation

/// IOProc のホストタイムから欠落区間を検出し、タイムライン上の位置を管理する
public struct TimelineTracker: Sendable {
    public struct Gap: Equatable, Sendable {
        public var startSeconds: Double
        public var durationSeconds: Double
        public var reason: String
    }

    /// これまでに書いた長さ（秒、無音補填を含む）
    public private(set) var position: Double = 0
    public private(set) var startHostTime: UInt64?
    private var lastHostTime: UInt64?
    private var lastDuration: Double = 0

    public init() {}

    /// 次のレコードを受け取る前に呼ぶ。補填すべき無音の長さを返す
    /// - Parameters:
    ///   - newEngine: 集約デバイスを作り直した直後の最初のレコードか
    ///   - toSeconds: ホストタイム差を秒に変換する関数（テスト用に差し替え可能）
    public mutating func observe(hostTime: UInt64, duration: Double, newEngineReason: String?,
                                 droppedSinceLast: Bool,
                                 toSeconds: (UInt64, UInt64) -> Double = HostTime.delta) -> Gap? {
        defer {
            lastHostTime = hostTime
            lastDuration = duration
            position += duration
        }
        guard let last = lastHostTime else {
            startHostTime = hostTime
            return nil
        }
        let elapsed = toSeconds(hostTime, last)
        let missing = elapsed - lastDuration
        // 1 バッファの半分以上の空きがあれば欠落とみなす
        let threshold = max(0.005, lastDuration * 0.5)
        if missing > threshold {
            let reason = newEngineReason ?? (droppedSinceLast ? "buffer_overflow" : "discontinuity")
            let gap = Gap(startSeconds: position, durationSeconds: missing, reason: reason)
            position += missing
            return gap
        }
        if let newEngineReason {
            // 作り直しでも欠落がほとんどない場合は 0 長の区間として記録しておく
            return Gap(startSeconds: position, durationSeconds: 0, reason: newEngineReason)
        }
        return nil
    }

    /// 現在位置（ms）
    public var positionMs: Int64 { Int64((position * 1000).rounded()) }
}

/// 隣接する同じ理由の欠落区間をまとめる（buffer_overflow が大量に並ばないように）
public enum GapMerger {
    public static func append(_ gap: SessionGap, to gaps: inout [SessionGap], mergeWithinMs: Int64 = 1000) {
        if var last = gaps.last, last.reason == gap.reason, gap.startMs - last.endMs <= mergeWithinMs {
            last.endMs = max(last.endMs, gap.endMs)
            gaps[gaps.count - 1] = last
        } else {
            gaps.append(gap)
        }
    }
}
