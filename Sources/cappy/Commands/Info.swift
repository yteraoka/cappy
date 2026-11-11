import ArgumentParser
import CappyKit
import Foundation

enum Table {
    /// 東アジア文字を 2 桁として幅を数える
    static func width(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { w, u in
            let v = u.value
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1FAFF).contains(v)
            return w + (wide ? 2 : 1)
        }
    }

    static func render(_ header: [String], _ rows: [[String]]) -> String {
        let all = [header] + rows
        var widths = [Int](repeating: 0, count: header.count)
        for r in all { for (i, c) in r.enumerated() { widths[i] = max(widths[i], width(c)) } }
        return all.map { r in
            r.enumerated().map { i, c in
                i == r.count - 1 ? c : c + String(repeating: " ", count: widths[i] - width(c))
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("List audio processes (PID, bundle ID, whether playing)", ja: "音声プロセスの一覧（PID・bundle ID・出力中か）")
    )

    @Flag(help: ArgumentHelp(tr("Show only processes that are playing audio", ja: "音声を出力中のプロセスだけを表示する")))
    var active = false

    func run() throws {
        var list = try AudioProcesses.list()
        if active { list = list.filter(\.isRunningOutput) }
        list.sort { a, b in
            if a.isRunningOutput != b.isRunningOutput { return a.isRunningOutput }
            return a.bundleID == b.bundleID ? a.pid < b.pid : a.bundleID < b.bundleID
        }
        if list.isEmpty {
            print(tr("No audio processes", ja: "音声プロセスがありません"))
            return
        }
        let rows = list.map { p in
            [String(p.pid), p.isRunningOutput ? "●" : "", p.isRunningInput ? "●" : "",
             p.bundleID.isEmpty ? "-" : p.bundleID, p.name]
        }
        print(Table.render(["PID", tr("OUTPUT", ja: "出力中"), tr("INPUT", ja: "入力中"), "BUNDLE ID", tr("NAME", ja: "名前")], rows))
    }
}

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("List input devices (UID, name, sample rate)", ja: "入力デバイスの一覧（UID・名前・サンプルレート）")
    )

    @Flag(help: ArgumentHelp(tr("Also show output devices", ja: "出力デバイスも表示する")))
    var all = false

    func run() throws {
        let devices = try AudioDevices.all().filter { all ? true : $0.inputChannels > 0 }
            .filter { !$0.uid.hasPrefix("dev.cappy.") }
        if devices.isEmpty {
            print(tr("No input devices", ja: "入力デバイスがありません"))
            return
        }
        let rows = devices.map { d -> [String] in
            var mark = ""
            if d.isDefaultInput { mark += tr("input", ja: "入力") }
            if d.isDefaultOutput { mark += mark.isEmpty ? tr("output", ja: "出力") : tr("/output", ja: "/出力") }
            var row = [mark, d.uid, d.name, "\(Int(d.sampleRate)) Hz", "\(d.inputChannels)"]
            if all { row.append("\(d.outputChannels)") }
            return row
        }
        var header = [tr("DEFAULT", ja: "既定"), "UID", tr("NAME", ja: "名前"), tr("SAMPLE RATE", ja: "サンプルレート"), tr("IN CH", ja: "入力ch")]
        if all { header.append(tr("OUT CH", ja: "出力ch")) }
        print(Table.render(header, rows))
    }
}

struct Recover: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Repair the CAF files of a session that ended abnormally, and recreate the files to send and session.json", ja: "異常終了したセッションの CAF を修復し、送信用ファイルと session.json を再生成する")
    )

    @Argument(help: ArgumentHelp(tr("Session directory", ja: "セッションディレクトリ")), completion: .directory)
    var sessionDir: String

    func run() throws {
        let dir = URL(fileURLWithPath: FileSecurity.expandTilde(sessionDir), isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw CappyError.usage(tr("Directory not found: \(dir.path)", ja: "ディレクトリがありません: \(dir.path)"))
        }
        CappyLog.shared.attach(sessionDirectory: dir)
        CappyLog.shared.info(tr("cappy \(CappyVersion.current) recover started", ja: "cappy \(CappyVersion.current) recover 開始"))
        let report = try SessionProcessing.recover(dir)
        if report.rebuiltSessionJSON { print(tr("Recreated session.json", ja: "session.json を再生成しました")) }
        for f in report.repairedFiles { print(tr("Repaired: \(f)", ja: "修復しました: \(f)")) }
        for (track, ms) in report.tracks.sorted(by: { $0.key < $1.key }) {
            print(tr("\(track.displayName) (\(track.rawValue)): \(TimeFormat.hms(ms: ms))", ja: "\(track.displayName)（\(track.rawValue)）: \(TimeFormat.hms(ms: ms))"))
        }
        print(tr("Created the files to send. Transcribe: cappy transcribe \(dir.path)", ja: "送信用ファイルを作成しました。文字起こし: cappy transcribe \(dir.path)"))
        CappyLog.shared.detach()
    }
}
