import Foundation

extension ABM {
    /// One item of Apple’s error answer (`{errors: [{id, status, code,
    /// title, detail}]}`).
    public struct ErrorItem: Hashable, Sendable {
        /// Apple’s ID for this error, for Apple support.
        public var id: String?
        public var code: String?
        public var title: String?
        public var detail: String?

        public init(id: String? = nil, code: String? = nil, title: String? = nil, detail: String? = nil) {
            self.id = id
            self.code = code
            self.title = title
            self.detail = detail
        }

        /// The items of an error answer; empty when it isn’t one.
        public static func items(in data: Data) -> [ErrorItem] {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let errors = object["errors"] as? [[String: Any]] else { return [] }
            func text(_ value: Any?) -> String? {
                (value as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            return errors.map {
                ErrorItem(id: text($0["id"]), code: text($0["code"]), title: text($0["title"]), detail: text($0["detail"]))
            }
        }

        /// `CODE: title — detail`, leaving out what’s missing.
        public var line: String {
            let words = [title, detail].compactMap { $0 }
            let text = words.count == 2 && words[0] != words[1] ? "\(words[0]) — \(words[1])" : (words.first ?? "")
            switch (code, text.isEmpty) {
            case let (code?, false): return "\(code): \(text)"
            case let (code?, true): return code
            case (nil, _): return text
            }
        }
    }

    /// Why an Apple Business or School Manager request or sign-in failed, in
    /// the same format as the Jamf and Intune errors: the HTTP status line,
    /// one `CODE: title — detail` line per error, Apple’s error ID, then
    /// hints: the app’s own first, then the standard ones. Everything shown
    /// goes through `Redaction`; the error ID stays visible in the
    /// bug-report export.
    public struct APIError: Swift.Error, LocalizedError, Sendable {
        public enum Kind: Sendable {
            /// Not sent: not a request the app makes, or an unsafe path.
            case refused(method: String, path: String)
            /// No answer from Apple, also after the retries.
            case transport(method: String, path: String, code: URLError.Code, message: String)
            /// Apple’s sign-in refused the API account. `code` and
            /// `description` are Apple’s `error` and `error_description`,
            /// never its whole answer.
            case signIn(status: Int, code: String?, description: String?)
            /// The private key can’t be read.
            case unreadableKey
            /// Apple answered with an error status.
            case status(Int, errors: [ErrorItem], method: String, path: String)
            /// The answer couldn’t be read, e.g. a list without `data`.
            case invalidResponse(String)
            /// Apple kept returning more pages than any real list has.
            case pageLimitReached(path: String, pages: Int)
            /// Not sent: a next-page link pointed away from Apple’s address,
            /// so the token would have gone there.
            case nextPageElsewhere(String)
            /// Not sent: a serial number with characters no Apple serial has.
            case invalidSerial(String)
            /// Not sent: a write the service doesn’t accept (Release in Apple
            /// School Manager, a missing or late deadline).
            case invalidRequest(String)
        }

        public var kind: Kind
        /// Business or School, for the wording; nil before it is known.
        public var service: Service?
        /// The app’s own hints, shown before the standard ones.
        public var appHints: [String]

        public init(_ kind: Kind, service: Service? = nil, appHints: [String] = []) {
            self.kind = kind
            self.service = service
            self.appHints = appHints
        }

        /// JTKit’s HTTP error in Apple’s terms, with the error answer read.
        init(_ error: HTTPError, service: Service, appHints: [String] = []) {
            let kind: Kind
            switch error {
            case let .refused(method, path):
                kind = .refused(method: method, path: path)
            case let .transport(method, path, code, message):
                kind = .transport(method: method, path: path, code: code, message: message)
            case let .status(response, method, path, _):
                kind = .status(response.status, errors: ErrorItem.items(in: response.data), method: method, path: path)
            case let .invalidURL(message), let .decoding(message):
                kind = .invalidResponse(message)
            }
            self.init(kind, service: service, appHints: appHints)
        }

        /// The HTTP status of an error answer or a refused sign-in.
        public var status: Int? {
            switch kind {
            case let .signIn(status, _, _), let .status(status, _, _, _): status
            default: nil
            }
        }

        public var errors: [ErrorItem] {
            if case let .status(_, errors, _, _) = kind { return errors }
            return []
        }

        private var portal: String { service?.portal ?? "Apple Business Manager or Apple School Manager" }
        private var name: String { service?.label ?? "Apple" }

        /// Apple stops answering past its limit, so a lost connection after
        /// every retry almost always means that.
        static let limitHint = "\(ABM.rateLimit.explanation). Wait a minute, then try again."

        /// The hints every app shows for this error.
        public var standardHints: [String] {
            switch kind {
            case .signIn:
                return ["Check the client ID and the key ID, and that the private key is the .pem file downloaded when the API account was created in \(portal). A revoked key can’t sign in; create a new one there."]
            case .unreadableKey:
                return ["Choose the .pem file \(portal) offered when the API account was created, as it was downloaded."]
            case .transport:
                return [Self.limitHint]
            case .status(401, _, _, _):
                return ["\(name) didn’t accept the sign-in. Check the API account in \(portal)."]
            case .status(403, _, _, _):
                return ["The API account isn’t allowed to do this. Check its access in \(portal)."]
            case .status(429, _, _, _):
                return [Self.limitHint]
            case let .status(status, _, _, _) where (500..<600).contains(status):
                return ["\(name) had a problem answering. Try again in a few minutes; if it keeps failing, give the Error ID to Apple support."]
            default:
                return []
            }
        }

        /// The message: the error, the app’s hints (its own, then
        /// `extraHints`), then the standard ones, each shown once.
        public func message(appHints extraHints: [String] = []) -> String {
            var lines: [String]
            switch kind {
            case let .refused(method, path):
                lines = ["Refused before sending: \(method) \(path) isn’t a request this app makes."]
            case let .transport(_, _, _, message):
                lines = ["Network error: \(message)"]
            case let .signIn(status, code, description):
                lines = ["Sign-in failed: " + Self.statusLine(status)]
                if let line = [code, description].compactMap({ $0 }).joined(separator: ": ").nonEmpty { lines.append(line) }
            case .unreadableKey:
                lines = [ApplePrivateKey.ImportError.notPrivateKey.errorDescription ?? ""]
            case let .status(status, errors, _, _):
                lines = [Self.statusLine(status)]
                for item in errors {
                    if let line = item.line.nonEmpty { lines.append(line) }
                }
                for id in errors.compactMap(\.id) { lines.append("Error ID: \(id)") }
            case let .invalidResponse(message):
                lines = ["Unexpected response from \(name): \(message)"]
            case let .pageLimitReached(path, pages):
                lines = ["Stopped after \(pages) pages of \(path): \(name) kept returning more pages than expected. The list is incomplete."]
            case let .nextPageElsewhere(host):
                lines = ["Refused: the next page of the list pointed to \(host), not to \(name). Nothing was sent there."]
            case let .invalidSerial(serial):
                lines = ["“\(serial)” isn’t a serial number: it may hold only letters and digits."]
            case let .invalidRequest(message):
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
            case let .refused(method, path), let .transport(method, path, _, _), let .status(_, _, method, path):
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
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
