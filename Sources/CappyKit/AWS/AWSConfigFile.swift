import Foundation

/// ~/.aws/config と ~/.aws/credentials（INI 形式）の内容
public struct AWSConfigFile: Sendable, Equatable {
    /// プロファイル名 → キーと値（キーは小文字）。credentials の値は config より優先する
    public var profiles: [String: [String: String]] = [:]
    /// [sso-session <name>] の内容
    public var ssoSessions: [String: [String: String]] = [:]

    public init(profiles: [String: [String: String]] = [:], ssoSessions: [String: [String: String]] = [:]) {
        self.profiles = profiles
        self.ssoSessions = ssoSessions
    }

    /// 2 つのファイルを読んでまとめる（ないファイルは空として扱う）
    public static func load(configPath: String, credentialsPath: String) throws -> AWSConfigFile {
        var result = AWSConfigFile()
        if let text = try read(configPath) {
            let config = parse(text, kind: .config)
            result.profiles = config.profiles
            result.ssoSessions = config.ssoSessions
        }
        if let text = try read(credentialsPath) {
            for (name, values) in parse(text, kind: .credentials).profiles {
                result.profiles[name, default: [:]].merge(values) { _, new in new }
            }
        }
        return result
    }

    private static func read(_ path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            throw CappyError.usage("AWS の設定ファイルを読めません: \(path): \(error.localizedDescription)")
        }
    }

    public enum Kind: Sendable { case config, credentials }

    /// botocore と同じ解釈: config では [default] と [profile <name>]、credentials では [<name>] がプロファイル。
    /// 行頭が # / ; の行はコメント。値が空のキーに続く字下げした行（s3 = の下の設定など）は読み飛ばす
    public static func parse(_ text: String, kind: Kind) -> AWSConfigFile {
        var result = AWSConfigFile()
        enum Target { case profile(String), ssoSession(String), ignored }
        var target: Target = .ignored
        var nestedKey: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            let indented = raw.first.map { $0 == " " || $0 == "\t" } ?? false
            if indented, nestedKey != nil { continue }
            nestedKey = nil
            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { target = .ignored; continue }
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                target = sectionTarget(name, kind: kind)
                switch target {
                case .profile(let p): if result.profiles[p] == nil { result.profiles[p] = [:] }
                case .ssoSession(let s): if result.ssoSessions[s] == nil { result.ssoSessions[s] = [:] }
                case .ignored: break
                }
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            if value.isEmpty { nestedKey = key }
            switch target {
            case .profile(let p): result.profiles[p]?[key] = value
            case .ssoSession(let s): result.ssoSessions[s]?[key] = value
            case .ignored: break
            }
        }
        return result

        func sectionTarget(_ name: String, kind: Kind) -> Target {
            switch kind {
            case .credentials:
                return name.isEmpty ? .ignored : .profile(name)
            case .config:
                if name == "default" { return .profile("default") }
                for (prefix, make) in [("profile", Target.profile), ("sso-session", Target.ssoSession)] {
                    guard name.hasPrefix(prefix), let next = name.dropFirst(prefix.count).first, next == " " || next == "\t" else { continue }
                    let rest = name.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                    return rest.isEmpty ? .ignored : make(rest)
                }
                return .ignored
            }
        }
    }
}
