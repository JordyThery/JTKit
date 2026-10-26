import Foundation

extension Graph {
    /// An error answer from Microsoft Graph (`{error: {code, message,
    /// innerError}}`) or from Microsoft's sign-in (`{error,
    /// error_description, error_codes, trace_id, correlation_id}`).
    public struct ErrorBody: Hashable, Sendable {
        public var code: String?
        public var message: String?
        /// Graph's request ID, for Microsoft support.
        public var requestID: String?
        public var date: String?
        /// The sign-in's error numbers, e.g. 7000215 for AADSTS7000215.
        public var errorCodes: [Int]
        public var traceID: String?
        public var correlationID: String?

        public init(code: String? = nil, message: String? = nil, requestID: String? = nil, date: String? = nil,
                    errorCodes: [Int] = [], traceID: String? = nil, correlationID: String? = nil) {
            self.code = code
            self.message = message
            self.requestID = requestID
            self.date = date
            self.errorCodes = errorCodes
            self.traceID = traceID
            self.correlationID = correlationID
        }

        /// Nil when the answer isn't one of the two shapes.
        public init?(data: Data) {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            func text(_ value: Any?) -> String? {
                (value as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            if let error = object["error"] as? [String: Any] {
                let inner = (error["innerError"] ?? error["innererror"]) as? [String: Any]
                self.init(code: text(error["code"]), message: text(error["message"]),
                          requestID: text(inner?["request-id"]), date: text(inner?["date"]))
            } else if object["error_description"] != nil || object["error"] is String {
                // the description repeats the trace and correlation IDs and a
                // timestamp on lines of their own; only its first line is kept
                let description = text(object["error_description"])
                    .map { $0.split(whereSeparator: \.isNewline).first.map(String.init) ?? $0 }
                self.init(code: text(object["error"]), message: description,
                          errorCodes: object["error_codes"] as? [Int] ?? [],
                          traceID: text(object["trace_id"]), correlationID: text(object["correlation_id"]))
            } else {
                return nil
            }
            guard code != nil || message != nil || requestID != nil || traceID != nil else { return nil }
        }

        /// `code: message`, leaving out what's missing.
        public var line: String {
            switch (code, message) {
            case let (code?, message?): "\(code): \(message)"
            case let (code?, nil): code
            case let (nil, message?): message
            case (nil, nil): ""
            }
        }
    }
}

/// Why a Microsoft Graph request or sign-in failed, in the same format as the
/// Jamf errors: the HTTP status line, `code: message`, the Request ID (or the
/// sign-in's Trace ID), then hints: the app's own first, then the standard
/// ones. A refused request (403) names the permission it needs and who grants
/// it. Everything shown goes through `Redaction`; the IDs stay visible in
/// the bug-report export.
public nonisolated struct GraphError: Error, LocalizedError, Sendable {
    public enum Kind: Sendable {
        /// Not sent: not a request the app makes, or an unsafe path.
        case refused(method: String, path: String)
        /// No answer from the server.
        case transport(method: String, path: String, code: URLError.Code, message: String)
        /// Microsoft's sign-in refused the app.
        case signIn(status: Int, body: Graph.ErrorBody?, text: String?)
        /// Graph answered with an error status.
        case status(Int, body: Graph.ErrorBody?, text: String?, method: String, path: String)
        /// The answer couldn't be read, e.g. a list without `value`.
        case invalidResponse(String)
        /// Graph kept returning more pages than any real list has.
        case pageLimitReached(path: String, pages: Int)
        /// Not sent: a next-page link pointed away from Microsoft Graph, so
        /// the token would have gone there.
        case nextPageElsewhere(String)
        /// Not sent: the connection's tenant or client ID can't be used.
        case invalidConnection(String)
    }

    public var kind: Kind
    /// The app's own hints, shown before the standard ones.
    public var appHints: [String]
    public var access: Graph.Access
    /// The permission the request needs, from `Graph.Permission`'s table;
    /// named in the hint when Graph refuses it (403).
    public var permission: Graph.Permission?

    public init(_ kind: Kind, appHints: [String] = [], access: Graph.Access = .delegated,
                permission: Graph.Permission? = nil) {
        self.kind = kind
        self.appHints = appHints
        self.access = access
        self.permission = permission
    }

    /// JTKit's HTTP error in Graph's terms, with the error body read.
    public init(_ error: HTTPError, access: Graph.Access, permission: Graph.Permission? = nil, appHints: [String] = []) {
        let kind: Kind
        switch error {
        case let .refused(method, path):
            kind = .refused(method: method, path: path)
        case let .transport(method, path, code, message):
            kind = .transport(method: method, path: path, code: code, message: message)
        case let .status(response, method, path, duringSignIn):
            let body = Graph.ErrorBody(data: response.data)
            let text = body == nil ? HTTPError.detail(of: response) : nil
            kind = duringSignIn
                ? .signIn(status: response.status, body: body, text: text)
                : .status(response.status, body: body, text: text, method: method, path: path)
        case let .invalidURL(message), let .decoding(message):
            kind = .invalidResponse(message)
        }
        self.init(kind, appHints: appHints, access: access, permission: permission)
    }

    /// The HTTP status of an error answer or a refused sign-in.
    public var status: Int? {
        switch kind {
        case let .signIn(status, _, _), let .status(status, _, _, _, _): status
        default: nil
        }
    }

    public var body: Graph.ErrorBody? {
        switch kind {
        case let .signIn(_, body, _), let .status(_, body, _, _, _): body
        default: nil
        }
    }

    /// Graph's request ID; shown unmasked, also in the bug-report export:
    /// Microsoft support asks for it.
    public var requestID: String? { body?.requestID }

    /// The hints every app shows for this error.
    public var standardHints: [String] {
        switch kind {
        case let .signIn(status, body, _):
            return [Self.signInHint(status: status, codes: body?.errorCodes ?? [])]
        case .status(401, _, _, _, _):
            return [access == .application
                ? "Microsoft Graph didn’t accept the sign-in. Check the app registration’s client secret."
                : "Microsoft Graph didn’t accept the sign-in. Sign in again."]
        case .status(403, _, _, _, _):
            return [permissionHint]
        case .status(429, _, _, _, _):
            return ["Microsoft Graph is limiting how many requests this app sends. Wait a minute, then try again."]
        case let .status(status, _, _, _, _) where (500..<600).contains(status):
            return ["Microsoft Graph had a problem answering. Try again in a few minutes; if it keeps failing, give the Request ID to Microsoft support."]
        default:
            return []
        }
    }

    /// Names the permission and who grants it.
    private var permissionHint: String {
        guard let permission else {
            return access == .application
                ? "The app registration is missing a Microsoft Graph application permission for this request. Check its API permissions in Entra and that an admin granted consent."
                : "This sign-in is missing a Microsoft Graph permission for this request, or your Intune role doesn’t allow it."
        }
        let name = permission.name(for: access)
        return access == .application
            ? "The app registration is missing the “\(name)” application permission. Add it in Entra under App registrations › API permissions, then grant admin consent."
            : "This sign-in is missing the “\(name)” delegated permission. Sign in again and accept it, or ask an admin to grant consent in Entra. It can also mean your Intune role doesn’t allow this."
    }

    /// Microsoft's sign-in error numbers (AADSTS…) that have a clear fix.
    static func signInHint(status: Int, codes: [Int]) -> String {
        if codes.contains(7000215) {
            return "The client secret is wrong. Copy the secret’s Value (not its Secret ID) from Entra under App registrations › Certificates & secrets."
        }
        if codes.contains(7000222) {
            return "The client secret has expired. Create a new one in Entra under App registrations › Certificates & secrets, and save it in the connection."
        }
        if codes.contains(700016) {
            return "No app with this client ID was found in the tenant. Check the Application (client) ID and the tenant ID."
        }
        if codes.contains(90002) || codes.contains(900023) || codes.contains(90023) {
            return "The tenant wasn’t found. Check the tenant ID or domain."
        }
        return "Check the tenant ID, the client ID and the client secret."
    }

    /// The message: the error, the app's hints (its own, then `extraHints`),
    /// then the standard ones, each shown once.
    public func message(appHints extraHints: [String] = []) -> String {
        var lines: [String]
        switch kind {
        case let .refused(method, path):
            lines = ["Refused before sending: \(method) \(path) is not a request this app makes."]
        case let .transport(_, _, _, message):
            lines = ["Network error: \(message)"]
        case let .signIn(status, body, text):
            lines = ["Sign-in failed: " + Self.statusLine(status)] + Self.detailLines(body: body, text: text)
        case let .status(status, body, text, _, _):
            lines = [Self.statusLine(status)] + Self.detailLines(body: body, text: text)
        case let .invalidResponse(message):
            lines = ["Unexpected response: \(message)"]
        case let .pageLimitReached(path, pages):
            lines = ["Stopped after \(pages) pages of \(path): Microsoft Graph kept returning more pages than expected. The list is incomplete."]
        case let .nextPageElsewhere(host):
            lines = ["Refused: the next page of the list pointed to \(host), not to Microsoft Graph. Nothing was sent there."]
        case let .invalidConnection(message):
            lines = [message]
        }
        for hint in appHints + extraHints + standardHints where !lines.contains(hint) {
            lines.append(hint)
        }
        return Redaction.text(lines.joined(separator: "\n"))
    }

    public var errorDescription: String? { message() }

    /// Everything about the error for a bug report, ready to copy.
    public var report: String {
        var lines = [String]()
        switch kind {
        case let .refused(method, path), let .transport(method, path, _, _), let .status(_, _, _, method, path):
            lines.append("Request: \(method) \(path)")
        default:
            break
        }
        lines.append(message())
        return Redaction.text(lines.joined(separator: "\n"))
    }

    private static func statusLine(_ status: Int) -> String {
        "HTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)"
    }

    private static func detailLines(body: Graph.ErrorBody?, text: String?) -> [String] {
        guard let body else { return text.map { [String($0.prefix(500))] } ?? [] }
        var lines = [body.line].filter { !$0.isEmpty }
        if let requestID = body.requestID { lines.append("Request ID: \(requestID)") }
        if let date = body.date { lines.append("Date: \(date)") }
        if let traceID = body.traceID { lines.append("Trace ID: \(traceID)") }
        if let correlationID = body.correlationID { lines.append("Correlation ID: \(correlationID)") }
        return lines
    }
}
