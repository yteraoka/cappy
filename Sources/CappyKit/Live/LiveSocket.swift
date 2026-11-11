import Foundation

/// Live API の WebSocket（テストでは偽物に差し替える）
public protocol LiveSocket: AnyObject, Sendable {
    func send(_ text: String) async throws
    /// 次のメッセージ（テキスト）。接続が閉じたら throw する
    func receive() async throws -> String
    func close()
}

public protocol LiveConnector: Sendable {
    func connect() async throws -> LiveSocket
}

/// バイナリのメッセージをやりとりする WebSocket（Amazon Transcribe Streaming 用。テストでは偽物に差し替える）
public protocol LiveDataSocket: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// 次のメッセージ。接続が閉じたら throw する
    func receive() async throws -> Data
    func close()
}

public protocol LiveDataConnector: Sendable {
    func connect(_ url: URL) async throws -> LiveDataSocket
}

/// 署名付き URL に接続する。
/// Transcribe Streaming は WebSocket の ping に応答しないため、接続の失敗（ハンドシェイクの 4xx など）は最初の受信で分かる
public struct URLSessionDataConnector: LiveDataConnector {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(_ url: URL) async throws -> LiveDataSocket {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let task = session.webSocketTask(with: req)
        task.maximumMessageSize = 16 << 20
        task.resume()
        return URLSessionLiveSocket(task: task)
    }
}

/// 接続できなかった・切断された理由
public struct LiveConnectionError: Error, CustomStringConvertible, Sendable {
    public var message: String
    /// 設定や権限の誤りなど、再接続しても直らないもの
    public var permanent: Bool

    public var description: String { message }
}

/// Vertex AI の Live API（BidiGenerateContent）への接続
public struct VertexLiveConnector: LiveConnector {
    let url: URL
    let auth: AccessTokenProvider
    let userProject: String?
    let session: URLSession

    public init(location: String, auth: AccessTokenProvider, userProject: String?, session: URLSession = .shared) {
        // Live API は v1beta1 の LlmBidiService
        self.url = URL(string: "wss://\(VertexAI.host(region: location))/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent")!
        self.auth = auth
        self.userProject = userProject
        self.session = session
    }

    public func connect() async throws -> LiveSocket {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
        if let userProject { req.setValue(userProject, forHTTPHeaderField: "x-goog-user-project") }
        let task = session.webSocketTask(with: req)
        task.maximumMessageSize = 16 << 20
        task.resume()
        return URLSessionLiveSocket(task: task)
    }
}

final class URLSessionLiveSocket: LiveSocket, LiveDataSocket, @unchecked Sendable {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw describe(error)
        }
    }

    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let s): return s
            case .data(let d): return String(decoding: d, as: UTF8.self)
            @unknown default: return ""
            }
        } catch {
            throw describe(error)
        }
    }

    func send(_ data: Data) async throws {
        do {
            try await task.send(.data(data))
        } catch {
            throw describe(error)
        }
    }

    func receive() async throws -> Data {
        do {
            switch try await task.receive() {
            case .data(let d): return d
            case .string(let s): return Data(s.utf8)
            @unknown default: return Data()
            }
        } catch {
            throw describe(error)
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// HTTP の応答コードや WebSocket の終了理由から、再接続で直るかを判断する
    func describe(_ error: Error) -> LiveConnectionError {
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            let code = http.statusCode
            let permanent = [400, 401, 403, 404].contains(code)
            return LiveConnectionError(message: "リアルタイム文字起こしの接続に失敗しました（HTTP \(code)\(code == 403 ? "。認証情報か権限を確認してください" : "")）",
                                       permanent: permanent)
        }
        let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        switch task.closeCode {
        case .invalid:
            return LiveConnectionError(message: "Live API との接続が切れました: \(error.localizedDescription)", permanent: false)
        case .policyViolation, .unsupportedData, .invalidFramePayloadData:
            // 設定の誤り（モデル名・権限など）はサーバーが 1007 / 1008 で閉じる
            return LiveConnectionError(message: "Live API が接続を閉じました（\(task.closeCode.rawValue)）: \(reason)", permanent: true)
        default:
            return LiveConnectionError(message: "Live API が接続を閉じました（\(task.closeCode.rawValue)）\(reason.isEmpty ? "" : ": \(reason)")",
                                       permanent: false)
        }
    }
}
