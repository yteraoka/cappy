import Foundation

/// AWS API のエラー応答（JSON / XML のどちらにも対応する）
public struct AWSAPIError: RetryableError, CustomStringConvertible, Sendable {
    public var httpStatus: Int
    public var code: String?
    public var message: String

    public init(httpStatus: Int, code: String?, message: String) {
        self.httpStatus = httpStatus
        self.code = code
        self.message = message
    }

    public var description: String {
        "HTTP \(httpStatus)\(code.map { " \($0)" } ?? ""): \(message)"
    }

    public var isTransient: Bool {
        if [408, 429, 500, 502, 503, 504].contains(httpStatus) { return true }
        let throttling: Set<String> = ["Throttling", "ThrottlingException", "ThrottledException", "RequestLimitExceeded",
                                       "TooManyRequestsException", "RequestThrottled", "SlowDown"]
        return code.map(throttling.contains) ?? false
    }

    public static func from(_ resp: HTTPResponse) -> AWSAPIError {
        // JSON: {"__type": "...#Code", "message": "..."} / {"code": ..., "Message": ...}
        if let obj = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any] {
            let rawCode = (obj["__type"] as? String) ?? (obj["code"] as? String) ?? (obj["error"] as? String)
                ?? resp.headers["x-amzn-errortype"]
            let code = rawCode.map { c in
                String(c.split(separator: "#").last ?? Substring(c)).components(separatedBy: ":").first ?? c
            }
            let message = (obj["message"] as? String) ?? (obj["Message"] as? String)
                ?? (obj["error_description"] as? String) ?? String(resp.text.prefix(500))
            return AWSAPIError(httpStatus: resp.status, code: code, message: message)
        }
        // XML: <ErrorResponse><Error><Code>..</Code><Message>..</Message></Error></ErrorResponse>
        let fields = XMLFields.parse(resp.body)
        if fields["Code"] != nil || fields["Message"] != nil {
            return AWSAPIError(httpStatus: resp.status, code: fields["Code"], message: fields["Message"] ?? String(resp.text.prefix(500)))
        }
        return AWSAPIError(httpStatus: resp.status, code: resp.headers["x-amzn-errortype"], message: String(resp.text.prefix(500)))
    }
}

/// XML の葉要素の名前 → 文字列（同じ名前が複数あれば最初のもの）。STS などの小さな応答用
enum XMLFields {
    static func parse(_ data: Data) -> [String: String] {
        final class Delegate: NSObject, XMLParserDelegate {
            var fields: [String: String] = [:]
            var stack: [(name: String, text: String, hasChild: Bool)] = []
            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String] = [:]) {
                if !stack.isEmpty { stack[stack.count - 1].hasChild = true }
                stack.append((name, "", false))
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if !stack.isEmpty { stack[stack.count - 1].text += string }
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
                guard let top = stack.popLast() else { return }
                if !top.hasChild, fields[top.name] == nil {
                    fields[top.name] = top.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        let d = Delegate()
        let p = XMLParser(data: data)
        p.delegate = d
        _ = p.parse()
        return d.fields
    }
}

/// STS（GetCallerIdentity）。認証情報の確認に使う
public struct STSClient: Sendable {
    public struct Identity: Sendable, Equatable {
        public var account: String
        public var arn: String
        public var userID: String
    }

    let credentials: AWSCredentialsSource
    let region: String
    let transport: HTTPTransport

    public init(credentials: AWSCredentialsSource, region: String, transport: HTTPTransport = URLSessionTransport()) {
        self.credentials = credentials
        self.region = region
        self.transport = transport
    }

    public func getCallerIdentity() async throws -> Identity {
        let creds = try await credentials.credentials()
        var req = URLRequest(url: URL(string: "https://sts.\(region).amazonaws.com/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("Action=GetCallerIdentity&Version=2011-06-15".utf8)
        SigV4Signer(credentials: creds, region: region, service: "sts").sign(&req)
        let request = req
        let resp = try await RetryPolicy().run("GetCallerIdentity") { [transport] in
            let r = try await transport.send(request)
            if r.status != 200 { throw AWSAPIError.from(r) }
            return r
        }
        let f = XMLFields.parse(resp.body)
        guard let arn = f["Arn"], let account = f["Account"] else {
            throw CappyError.transcription("GetCallerIdentity の応答を解釈できません")
        }
        return Identity(account: account, arn: arn, userID: f["UserId"] ?? "")
    }
}
