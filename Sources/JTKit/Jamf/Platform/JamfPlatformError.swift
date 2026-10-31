import Foundation

extension JamfPlatform {
    /// An error code in a Platform API answer. Known ones have names; any
    /// other code the server sends is kept as it is.
    public struct ErrorCode: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            rawValue = value
        }

        /// The Environment ID doesn’t belong to this integration.
        public static let invalidRequestContextID: ErrorCode = "INVALID_REQUEST_CONTEXT_ID"
        /// No such tenant for the environment, e.g. device groups in Jamf School.
        public static let tenantNotFound: ErrorCode = "TENANT_NOT_FOUND"
        /// A Blueprint assigned to a division can’t be changed through the API.
        public static let divisionPatchNotAllowed: ErrorCode = "DIVISION_PATCH_NOT_ALLOWED"
        public static let notFound: ErrorCode = "NOT_FOUND"
    }

    /// An error answer, read from every shape the apps receive:
    /// - the gateway’s `{httpStatus, traceId, errors}`, with `errors` as one
    ///   object or a list;
    /// - the compliance benchmarks’ `{message, error, statusCode, logref}`;
    /// - the sign-in’s `{error, error_description}`.
    public struct ErrorBody: Hashable, Sendable {
        public struct Item: Hashable, Sendable {
            public var code: String?
            public var field: String?
            public var description: String?

            public init(code: String? = nil, field: String? = nil, description: String? = nil) {
                self.code = code
                self.field = field
                self.description = description
            }

            /// `CODE (field): description`, leaving out what’s missing.
            public var line: String {
                var head = code ?? ""
                if let field, !field.isEmpty { head += head.isEmpty ? field : " (\(field))" }
                guard let description, !description.isEmpty else { return head }
                return head.isEmpty ? description : "\(head): \(description)"
            }
        }

        public var httpStatus: Int?
        public var traceID: String?
        public var errors: [Item]

        public init(httpStatus: Int? = nil, traceID: String? = nil, errors: [Item] = []) {
            self.httpStatus = httpStatus
            self.traceID = traceID
            self.errors = errors
        }

        /// Nil when the answer isn’t a JSON object in one of the known shapes.
        public init?(data: Data) {
            guard let json = try? LosslessJSON(data: data), let object = json.objectValue else { return nil }
            func text(_ key: String) -> String? {
                switch object[key] {
                case .string(let value)?: value
                case .number(let value)?: value.literal
                default: nil
                }
            }
            func item(_ value: LosslessJSON) -> Item? {
                guard value.objectValue != nil else { return nil }
                return Item(code: value["code"]?.stringValue, field: value["field"]?.stringValue,
                            description: value["description"]?.stringValue)
            }
            if object["errors"] != nil || object["traceId"] != nil {
                httpStatus = object["httpStatus"]?.numberValue?.intValue
                traceID = text("traceId")
                switch object["errors"] {
                case .array(let array)?: errors = array.compactMap(item)
                case let value?: errors = item(value).map { [$0] } ?? []
                case nil: errors = []
                }
            } else if object["error_description"] != nil || object["error"]?.stringValue != nil || object["message"] != nil {
                // the sign-in’s and the benchmarks’ shapes carry the same parts
                httpStatus = object["statusCode"]?.numberValue?.intValue
                traceID = text("logref")
                errors = [Item(code: text("error"), description: text("error_description") ?? text("message"))]
            } else {
                return nil
            }
            guard httpStatus != nil || traceID != nil || !errors.isEmpty else { return nil }
        }

        public func contains(_ code: ErrorCode) -> Bool {
            errors.contains { $0.code == code.rawValue }
        }
    }
}

extension JamfPlatform {
    /// Why a Jamf Platform API request failed, shown in one format in every app:
    /// the HTTP status line, one `CODE (field): description` line per error, the
    /// Trace ID, then hints (the app’s own first, then the standard ones).
    /// Everything shown goes through `Redaction`.
    public nonisolated struct APIError: Error, LocalizedError, Sendable {
        public enum Kind: Sendable {
            /// Not sent: not a request the app makes, or an unsafe path.
            case refused(method: String, path: String)
            /// No answer from the server.
            case transport(method: String, path: String, code: URLError.Code, message: String)
            /// The sign-in was refused.
            case signIn(status: Int, body: JamfPlatform.ErrorBody?, text: String?)
            /// The server answered with an error status.
            case status(Int, body: JamfPlatform.ErrorBody?, text: String?, method: String, path: String)
            /// Not sent: the Environment ID isn’t a UUID.
            case invalidEnvironmentID(String)
            /// The answer couldn’t be read, or the connection has no usable address.
            case invalidResponse(String)
            /// The server kept returning more pages than any real list has.
            case pageLimitReached(path: String, pages: Int)
            /// The integration can’t list environments: it is scoped to one environment.
            case cannotListEnvironments
            /// Not sent: a serial number or UDID with characters it can’t hold.
            case invalidIdentifier(String)
        }

        public var kind: Kind
        /// The app’s own hints, shown before the standard ones; the client adds
        /// them from its `hints`.
        public var appHints: [String]
        /// Where the request went, which decides where a missing permission is
        /// fixed (Jamf Account, or Jamf Pro’s API roles); the client sets it.
        public var server: JamfPlatform.Server
        /// How the client signs in, which decides where a Jamf Pro privilege is
        /// added (an API role, or a user account); the client sets it.
        public var signIn: SignInMethod
        /// The Jamf Pro privileges the request needs, named in the hint when
        /// Jamf Pro refuses it (403); the calls set them from `JamfPro.Privilege`.
        /// Usually one; an MDM command needs two (View MDM command information,
        /// and the command’s own).
        public var privileges: [JamfPro.Privilege]

        /// The first of `privileges`; setting it replaces them.
        public var privilege: JamfPro.Privilege? {
            get { privileges.first }
            set { privileges = newValue.map { [$0] } ?? [] }
        }

        public init(_ kind: Kind, appHints: [String] = [], server: JamfPlatform.Server = .platformAPI,
                    signIn: SignInMethod = .apiClient, privilege: JamfPro.Privilege? = nil) {
            self.kind = kind
            self.appHints = appHints
            self.server = server
            self.signIn = signIn
            self.privileges = privilege.map { [$0] } ?? []
        }

        /// JTKit’s HTTP error in the Platform API’s terms, with the error body read.
        /// (`Kind.` is spelled out: `HTTPError` has cases with the same names, and
        /// `.refused(…)` alone would call this initializer again.)
        public init(_ error: HTTPError) {
            switch error {
            case let .refused(method, path):
                self.init(Kind.refused(method: method, path: path))
            case let .transport(method, path, code, message):
                self.init(Kind.transport(method: method, path: path, code: code, message: message))
            case let .status(response, method, path, duringSignIn):
                let body = JamfPlatform.ErrorBody(data: response.data)
                // a Classic API error page (HTML or XML) reads as its message;
                // secrets are hidden first, while their tags (`<password>`) still
                // say what they are
                let redactedPage = Redaction.body(response.data, contentType: response.header("Content-Type")).map { Data($0.utf8) }
                let text = body == nil
                    ? redactedPage.flatMap(JamfClassic.errorMessage(in:)).map(Redaction.text) ?? HTTPError.detail(of: response)
                    : nil
                self.init(duringSignIn
                    ? Kind.signIn(status: response.status, body: body, text: text)
                    : Kind.status(response.status, body: body, text: text, method: method, path: path))
            case let .invalidURL(message), let .decoding(message):
                self.init(Kind.invalidResponse(message))
            }
        }

        /// The HTTP status of an error answer or a refused sign-in.
        public var status: Int? {
            switch kind {
            case let .signIn(status, _, _), let .status(status, _, _, _, _): status
            default: nil
            }
        }

        public var body: JamfPlatform.ErrorBody? {
            switch kind {
            case let .signIn(_, body, _), let .status(_, body, _, _, _): body
            default: nil
            }
        }

        /// Shown unmasked, also in the bug-report export: Jamf support asks for it.
        public var traceID: String? { body?.traceID }

        public func hasCode(_ code: JamfPlatform.ErrorCode) -> Bool {
            body?.contains(code) ?? false
        }

        /// The hints every app shows for this error.
        public var standardHints: [String] {
            var hints = [String]()
            if hasCode(.invalidRequestContextID) {
                hints.append("The Environment ID doesn’t belong to this integration. Copy it from the integration’s details in Jamf Account.")
            }
            if hasCode(.divisionPatchNotAllowed) {
                hints.append("This Blueprint is assigned to a division and can’t be changed through the API.")
            }
            switch kind {
            case let .signIn(status, _, _) where (status == 400 || status == 401) && server == .jamfPro:
                hints.append(jamfProSignInHint)
            case let .signIn(status, _, _) where status == 400 || status == 401:
                hints.append("Check the client ID, client secret and region. Jamf Account integrations expire after six months.")
            case .status(401, _, _, _, _) where server == .jamfPro:
                hints.append("Jamf Pro didn’t accept the sign-in. " + jamfProSignInHint)
            case .status(401, _, _, _, _):
                hints.append("Jamf didn’t accept the sign-in. Check the client ID, client secret and region.")
            case .status(403, _, _, _, _) where server == .jamfPro:
                hints.append(jamfProPrivilegeHint)
            case .status(403, _, _, _, _):
                hints.append("The API integration is missing a permission for this request, or isn’t scoped to this environment. Check its permissions in Jamf Account.")
            case .status(429, _, _, _, _):
                hints.append("Jamf is limiting how many requests this app sends. Wait a minute, then try again.")
            case let .status(status, _, _, _, _) where (500..<600).contains(status):
                hints.append("Jamf had a problem answering. Try again in a few minutes.")
            default:
                break
            }
            return hints
        }

        /// A direct Jamf Pro sign-in has no region and no Jamf Account.
        private var jamfProSignInHint: String {
            signIn == .usernamePassword
                ? "Check the username and password."
                : "Check the client ID and client secret, and that the API client is enabled in Jamf Pro under Settings › API Roles and Clients."
        }

        /// Names the privilege when the request carries one: an API client gets
        /// it from its API role, a user account from its own privileges.
        private var jamfProPrivilegeHint: String {
            let missing = switch privileges.count {
            case 0: "a privilege for this request"
            case 1: "the “\(privileges[0].rawValue)” privilege"
            default: "one of these privileges: " + privileges.map { "“\($0.rawValue)”" }.joined(separator: ", ")
            }
            return signIn == .usernamePassword
                ? "The user account is missing \(missing). Add it in Jamf Pro under Settings › User Accounts and Groups."
                : "The API role is missing \(missing). Add it in Jamf Pro under Settings › API Roles and Clients."
        }

        /// The message: the error, the app’s hints (its own, then `extraHints`),
        /// then the standard ones, each shown once.
        public func message(appHints extraHints: [String] = []) -> String {
            var lines: [String]
            switch kind {
            case let .refused(method, path):
                lines = ["Refused before sending: \(method) \(path) isn’t a request this app makes."]
            case let .transport(_, _, _, message):
                lines = ["Network error: \(message)"]
            case let .signIn(status, body, text):
                lines = ["Sign-in failed: " + Self.statusLine(status)] + Self.detailLines(body: body, text: text)
            case let .status(status, body, text, _, _):
                lines = [Self.statusLine(status)] + Self.detailLines(body: body, text: text)
            case .invalidEnvironmentID:
                lines = [Self.environmentIDNotUUID]
            case let .invalidResponse(message):
                lines = ["Unexpected response from \(server == .jamfPro ? "Jamf Pro" : "the Jamf Platform API"): \(message)"]
            case let .pageLimitReached(path, pages):
                lines = ["Stopped after \(pages) pages of \(path): the server kept returning more pages than expected. The list is incomplete."]
            case let .invalidIdentifier(value):
                lines = ["“\(value)” isn’t a serial number or UDID: only letters, digits and hyphens are allowed."]
            case .cannotListEnvironments:
                lines = [
                    "This API integration is scoped to one environment, so it can’t list environments. Only an integration with organization scope can.",
                    "Find the Environment ID in Jamf Account (account.jamf.com): open this API integration’s details, copy the Environment ID shown there and paste it into the field.",
                ]
            }
            for hint in appHints + extraHints + standardHints where !lines.contains(hint) {
                lines.append(hint)
            }
            return Redaction.text(lines.joined(separator: "\n"))
        }

        public var errorDescription: String? { message() }

        /// The same error without anything the server wrote (its error lines,
        /// Trace ID and text): only the status and JTKit’s own hints. For the
        /// secret reads, whose failure is recorded and could otherwise carry the
        /// secret in the server’s words.
        public var withoutServerText: JamfPlatform.APIError {
            var copy = self
            switch kind {
            case let .status(status, _, _, method, path):
                copy.kind = .status(status, body: nil, text: nil, method: method, path: path)
            case let .signIn(status, _, _):
                copy.kind = .signIn(status: status, body: nil, text: nil)
            default:
                break
            }
            return copy
        }

        /// Everything about the error for a bug report, ready to copy: the
        /// request and the message (with the start of an answer that wasn’t in a
        /// known shape, redacted).
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

        /// The same sentence as the connection editor’s.
        static let environmentIDNotUUID = "The Environment ID isn’t a UUID (8-4-4-4-12 hexadecimal characters). Copy it from Jamf Account."

        private static func statusLine(_ status: Int) -> String {
            "HTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)"
        }

        private static func detailLines(body: JamfPlatform.ErrorBody?, text: String?) -> [String] {
            guard let body else { return text.map { [String($0.prefix(500))] } ?? [] }
            var lines = body.errors.map(\.line).filter { !$0.isEmpty }
            if let traceID = body.traceID { lines.append("Trace ID: \(traceID)") }
            return lines
        }
    }
}

@available(*, deprecated, renamed: "JamfPlatform.APIError")
public typealias JamfPlatformError = JamfPlatform.APIError
