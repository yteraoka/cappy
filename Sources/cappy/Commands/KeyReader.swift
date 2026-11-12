import CappyKit
import Darwin
import Foundation

/// 端末の設定を戻すための保存先（atexit から参照するためグローバルに置く）
nonisolated(unsafe) private var savedTermios: termios?
private let termiosLock = NSLock()

private func restoreSavedTermios() {
    termiosLock.withLock {
        guard var t = savedTermios else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &t)
        savedTermios = nil
    }
}

/// 録音中だけ端末を 1 文字ずつ読むモードにして、キー入力を KeyInputParser に渡す
final class KeyReader: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = KeyInputParser()
    private var active = false
    private var raw = termios()
    private var contSource: DispatchSourceSignal?
    private let onEvent: @Sendable (KeyInputParser.Event, String) -> Void

    /// - Parameter onEvent: イベントと、その時点の入力中の文字
    init(onEvent: @escaping @Sendable (KeyInputParser.Event, String) -> Void) {
        self.onEvent = onEvent
    }

    /// 端末から入力でき、フォアグラウンドで動いているか（バックグラウンドで端末の設定を変えると止められる）
    static var available: Bool {
        isatty(STDIN_FILENO) != 0 && tcgetpgrp(STDIN_FILENO) == getpgrp()
    }

    /// 入力中の文字
    var pendingText: String { lock.withLock { active ? parser.text : "" } }

    /// 1 文字ずつ読むモードにして読み始める。使えなければ false
    @discardableResult
    func start() -> Bool {
        guard Self.available else { return false }
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return false }
        raw = original
        // 行単位の入力とエコーをやめる。Ctrl-C（ISIG）はそのまま使う。IEXTEN を切ると Ctrl-V / Ctrl-O も文字として届く
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | IEXTEN)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        termiosLock.withLock { savedTermios = original }
        atexit { restoreSavedTermios() }
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            restoreSavedTermios()
            return false
        }
        lock.withLock { active = true }
        // Ctrl-Z で止めて fg で戻ったとき、シェルが端末の設定を戻していることがあるのでかけ直す
        let src = DispatchSource.makeSignalSource(signal: SIGCONT, queue: .global())
        src.setEventHandler { [weak self] in self?.reapply() }
        src.resume()
        contSource = src

        let t = Thread { [weak self] in
            var byte: UInt8 = 0
            while read(STDIN_FILENO, &byte, 1) == 1 {
                guard let self else { return }
                let result: (KeyInputParser.Event, String)? = self.lock.withLock {
                    guard self.active else { return nil }
                    return self.parser.feed(byte).map { ($0, self.parser.text) }
                }
                if let (event, text) = result { self.onEvent(event, text) }
            }
        }
        t.name = "dev.cappy.keys"
        t.start()
        return true
    }

    private func reapply() {
        lock.withLock {
            guard active else { return }
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
    }

    /// 端末の設定を元に戻す（以後のキー入力は無視する）
    func stop() {
        lock.withLock {
            guard active else { return }
            active = false
            contSource?.cancel()
            contSource = nil
        }
        restoreSavedTermios()
    }
}
