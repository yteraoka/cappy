import Foundation
import Synchronization

/// 単一プロデューサ・単一コンシューマのロックフリーなバイトリングバッファ。
/// IOProc（リアルタイムスレッド）は write だけを呼び、確保・ロック・システムコールはしない。
public final class RingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let storage: UnsafeMutableRawPointer
    /// 書き込み位置（累積バイト数）。プロデューサだけが更新する
    private let head = Atomic<Int>(0)
    /// 読み出し位置（累積バイト数）。コンシューマだけが更新する
    private let tail = Atomic<Int>(0)
    /// 空きが足りず捨てたレコード数
    private let dropped = Atomic<Int>(0)
    /// これまでの最大使用量
    private let highWater = Atomic<Int>(0)

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit { storage.deallocate() }

    public var usedBytes: Int { head.load(ordering: .acquiring) - tail.load(ordering: .acquiring) }
    public var droppedCount: Int { dropped.load(ordering: .relaxed) }
    public var highWaterBytes: Int { highWater.load(ordering: .relaxed) }

    /// 複数の領域を 1 レコードとしてまとめて書く（全部入らなければ何も書かずに false）
    public func write(_ parts: UnsafeBufferPointer<(UnsafeRawPointer, Int)>) -> Bool {
        var total = 0
        for p in parts { total += p.1 }
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let used = h - t
        guard capacity - used >= total else {
            dropped.add(1, ordering: .relaxed)
            return false
        }
        var pos = h
        for p in parts {
            copyIn(p.0, p.1, at: pos)
            pos += p.1
        }
        head.store(pos, ordering: .releasing)
        let newUsed = used + total
        if newUsed > highWater.load(ordering: .relaxed) { highWater.store(newUsed, ordering: .relaxed) }
        return true
    }

    public func write(_ ptr: UnsafeRawPointer, _ count: Int) -> Bool {
        withUnsafeTemporaryAllocation(of: (UnsafeRawPointer, Int).self, capacity: 1) { buf in
            buf[0] = (ptr, count)
            return write(UnsafeBufferPointer(buf))
        }
    }

    /// 読める量
    public var availableToRead: Int { head.load(ordering: .acquiring) - tail.load(ordering: .relaxed) }

    /// 読み出し位置を進めずにコピーする
    public func peek(into dst: UnsafeMutableRawPointer, count: Int) -> Bool {
        guard availableToRead >= count else { return false }
        copyOut(dst, count, at: tail.load(ordering: .relaxed))
        return true
    }

    public func read(into dst: UnsafeMutableRawPointer, count: Int) -> Bool {
        guard peek(into: dst, count: count) else { return false }
        tail.add(count, ordering: .releasing)
        return true
    }

    public func skip(_ count: Int) {
        tail.add(count, ordering: .releasing)
    }

    private func copyIn(_ src: UnsafeRawPointer, _ count: Int, at pos: Int) {
        let offset = pos % capacity
        let first = min(count, capacity - offset)
        memcpy(storage + offset, src, first)
        if first < count { memcpy(storage, src + first, count - first) }
    }

    private func copyOut(_ dst: UnsafeMutableRawPointer, _ count: Int, at pos: Int) {
        let offset = pos % capacity
        let first = min(count, capacity - offset)
        memcpy(dst, storage + offset, first)
        if first < count { memcpy(dst + first, storage, count - first) }
    }
}
