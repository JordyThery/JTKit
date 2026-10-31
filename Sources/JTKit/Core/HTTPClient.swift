import Foundation

/// One request to a service, relative to the client’s base URL.
public nonisolated struct HTTPRequest: Sendable {
    public var method: String
    /// Percent-encoded path relative to the base URL, e.g.
    /// `device-groups/v1/device-groups`. A leading slash is ignored.
    public var path: String
    /// Encoded strictly (`FormEncoding`), so `=`, `&` and quotes in values
    /// can’t change the meaning of the request.
    public var query: [URLQueryItem]
    public var body: Data?
    /// JSON by default; XML for Classic API paths.
    public var accept: String?
    public var contentType: String?
    /// Headers for this request only.
    public var headers: [String: String]
    /// Whether the request is sent again after a server error or a dropped
    /// connection. A 429 is always retried: nothing was done.
    public var repeating: Repeating
    /// Record both bodies in the activity log, also of a success. Only for
    /// requests the app knows carry nothing secret: by default request
    /// bodies are never recorded and response bodies only for errors.
    public var recordsBodies: Bool
    /// Trims a JSON body before it is redacted and recorded, e.g. to keep only
    /// the inventory sections the app asked for. Gets the parsed JSON and
    /// returns what may be recorded. A body that isn’t JSON then isn’t
    /// recorded at all. The answer the app receives is unchanged.
    public var recordedJSON: RecordedJSONFilter?
    /// Record only the method, path, status and duration, as for JTKit’s
    /// built-in sensitive calls: no headers, no bodies, not even an error
    /// answer’s. For requests whose contents the app knows can carry a
    /// secret, e.g. license serial numbers.
    public var withholdsContents: Bool
    /// A query that is already percent-encoded, sent as given (after `query`):
    /// for query syntax that strict encoding would change, such as Microsoft
    /// Graph’s `$select` and `$filter`, and next-page links. It must be
    /// correctly encoded, or the request isn’t sent.
    public var encodedQuery: String?
    /// A server error (5xx) is this request’s answer: returned at once, not
    /// retried or thrown. For a read whose server error is documented as a
    /// state, e.g. Apple’s Activation Lock for a device in an internal state.
    public var serverErrorIsAnAnswer: Bool

    /// When a request is sent again after a server error (5xx) or a dropped
    /// connection, which may have reached the server.
    public enum Repeating: Sendable, Hashable {
        /// Reads are; an edit isn’t.
        case standard
        /// An edit that can be sent twice without harm (e.g. a PUT that
        /// replaces a whole record) is, as a read.
        case safe
        /// A delete that is safe to repeat. A 404 after an attempt that may
        /// have reached the server means that attempt did it, so it counts
        /// as done; the answer then has status 404. A 404 on the first
        /// attempt is still an error.
        case safeNotFoundIsDone
    }

    public init(
        method: String = "GET",
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        accept: String? = nil,
        contentType: String? = nil,
        headers: [String: String] = [:],
        repeating: Repeating = .standard,
        recordsBodies: Bool = false,
        recordedJSON: RecordedJSONFilter? = nil,
        withholdsContents: Bool = false,
        encodedQuery: String? = nil,
        serverErrorIsAnAnswer: Bool = false
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.accept = accept
        self.contentType = contentType
        self.headers = headers
        self.repeating = repeating
        self.recordsBodies = recordsBodies
        self.recordedJSON = recordedJSON
        self.withholdsContents = withholdsContents
        self.encodedQuery = encodedQuery
        self.serverErrorIsAnAnswer = serverErrorIsAnAnswer
    }

    @available(*, deprecated, message: "Use repeating: .safe, or .safeNotFoundIsDone for notFoundAfterRepeatIsDone.")
    public init(
        method: String = "GET",
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        accept: String? = nil,
        contentType: String? = nil,
        headers: [String: String] = [:],
        safeToRepeat: Bool,
        recordsBodies: Bool = false,
        recordedJSON: RecordedJSONFilter? = nil,
        withholdsContents: Bool = false,
        encodedQuery: String? = nil,
        notFoundAfterRepeatIsDone: Bool = false,
        serverErrorIsAnAnswer: Bool = false
    ) {
        self.init(method: method, path: path, query: query, body: body, accept: accept, contentType: contentType,
                  headers: headers,
                  repeating: notFoundAfterRepeatIsDone ? .safeNotFoundIsDone : safeToRepeat ? .safe : .standard,
                  recordsBodies: recordsBodies, recordedJSON: recordedJSON, withholdsContents: withholdsContents,
                  encodedQuery: encodedQuery, serverErrorIsAnAnswer: serverErrorIsAnAnswer)
    }

    @available(*, deprecated, renamed: "repeating")
    public var safeToRepeat: Bool {
        get { repeating != .standard }
        set { repeating = newValue ? (repeating == .standard ? .safe : repeating) : .standard }
    }

    @available(*, deprecated, renamed: "repeating")
    public var notFoundAfterRepeatIsDone: Bool {
        get { repeating == .safeNotFoundIsDone }
        set { repeating = newValue ? .safeNotFoundIsDone : (repeating == .safeNotFoundIsDone ? .safe : repeating) }
    }

    /// GET and HEAD.
    public var isRead: Bool {
        ["GET", "HEAD"].contains(method.uppercased())
    }

    /// Sent again after a server error or a dropped connection.
    var isRepeatable: Bool { isRead || repeating != .standard }
}

public nonisolated struct HTTPResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let status: Int
    public let headers: [String: String]
    public let data: Data

    public init(status: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.status = status
        self.headers = headers
        self.data = data
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The status, the headers redacted and the body’s size: never a cookie
    /// or a body, also not in `"\(error)"`.
    public var description: String {
        let shown = Redaction.headers(headers).map { "\($0.name): \($0.value)" }.joined(separator: ", ")
        return "HTTP \(status) [\(shown)] \(data.count) bytes"
    }

    public var debugDescription: String { description }

    public func decoded<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HTTPError.decoding("\(T.self): \(error)")
        }
    }
}

/// Why a request failed. Every message goes through `Redaction`, also its
/// `description`, so `"\(error)"` shows no cookie or secret either.
public nonisolated enum HTTPError: Error, LocalizedError, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Not sent: not on the app’s list of allowed requests, or the path
    /// contains `..` or an encoded slash.
    case refused(method: String, path: String)
    case invalidURL(String)
    /// No answer from the server.
    case transport(method: String, path: String, code: URLError.Code, message: String)
    /// The server answered with an error status. `duringSignIn` when it
    /// refused the sign-in itself.
    case status(HTTPResponse, method: String, path: String, duringSignIn: Bool)
    case decoding(String)

    public var status: Int? {
        if case let .status(response, _, _, _) = self { return response.status }
        return nil
    }

    public var errorDescription: String? {
        let text: String
        switch self {
        case let .refused(method, path):
            text = "Refused before sending: \(method) \(path) isn’t a request this app makes."
        case let .invalidURL(message):
            text = message
        case let .transport(_, _, _, message):
            text = "Network error: \(message)"
        case let .status(response, method, path, duringSignIn):
            let detail = Self.detail(of: response)
            text = duringSignIn
                ? "Sign-in failed: HTTP \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized)" + (detail.map { "\n\($0)" } ?? "")
                : "\(method) \(path) failed with HTTP \(response.status)." + (detail.map { " \($0)" } ?? "")
        case let .decoding(message):
            text = "Unexpected response: \(message)"
        }
        return Redaction.text(text)
    }

    public var description: String { errorDescription ?? "HTTP error" }
    public var debugDescription: String { description }

    /// The start of the server’s answer, redacted, at most 300 characters.
    static func detail(of response: HTTPResponse) -> String? {
        guard let body = Redaction.body(response.data, contentType: response.header("Content-Type")) else { return nil }
        let flat = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }
}

/// Where a client gets its bearer token, e.g. `JamfPlatform.TokenProvider`.
public protocol BearerTokenSource: Sendable {
    /// A token valid for a while yet; signs in when needed.
    func token() async throws -> String
    /// Drops the token, e.g. after the server answered 401.
    func forgetToken() async
    /// A token, as `token()`; `beforeSigningIn` runs first when it has to
    /// sign in, e.g. to count the sign-in in a rate limit. A source that
    /// doesn’t need that uses the default, which ignores it.
    func token(beforeSigningIn: @escaping @Sendable () async throws -> Void) async throws -> String
}

extension BearerTokenSource {
    public func token(beforeSigningIn: @escaping @Sendable () async throws -> Void) async throws -> String {
        try await token()
    }
}

/// The retry rules, the same in every app.
///
/// At most 4 attempts. 429 is retried for every method; server errors (5xx)
/// and short network drops only for reads and for edits marked safe to
/// repeat. `Retry-After` is read as seconds or as an HTTP date; otherwise
/// the wait doubles from 1 s, with up to 0.5 s of randomness. No wait is
/// longer than 120 s. A 401 gets a new token and one more try (part of the 4).
public nonisolated struct RetryRules: Sendable, Hashable {
    public let maxAttempts: Int
    public let firstWait: TimeInterval
    public let randomness: TimeInterval
    public let longestWait: TimeInterval
    /// Waits after attempt 1, 2, … used instead of doubling (the last one
    /// repeats); `Retry-After` still comes first. Nil: doubling.
    public let fixedWaits: [TimeInterval]?
    /// Every network error counts as a short drop worth another try (for
    /// reads and edits safe to repeat), not only the usual few: Apple
    /// Business and School Manager answer their limit by dropping the
    /// connection, in more than one way.
    public let everyNetworkErrorIsADrop: Bool

    public static let standard = RetryRules()

    /// Apple Business and School Manager: 5, 15
    /// and 45 s, because once Apple’s quota is spent it stays quiet for a
    /// while and a short retry only spends another request.
    public static let appleBusiness = RetryRules(fixedWaits: [5, 15, 45], everyNetworkErrorIsADrop: true)

    public init(maxAttempts: Int = 4, firstWait: TimeInterval = 1, randomness: TimeInterval = 0.5, longestWait: TimeInterval = 120,
                fixedWaits: [TimeInterval]? = nil, everyNetworkErrorIsADrop: Bool = false) {
        self.maxAttempts = maxAttempts
        self.firstWait = firstWait
        self.randomness = randomness
        self.longestWait = longestWait
        self.fixedWaits = fixedWaits
        self.everyNetworkErrorIsADrop = everyNetworkErrorIsADrop
    }

    /// Short network drops worth another try.
    static let networkDrops: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
    ]

    /// The wait after a failed attempt (1, 2, …) without `Retry-After`.
    /// - Parameter random: between 0 and 1.
    public func backoff(afterAttempt attempt: Int, random: Double) -> TimeInterval {
        if let fixedWaits, !fixedWaits.isEmpty {
            let index = min(max(attempt, 1) - 1, fixedWaits.count - 1)
            return min(fixedWaits[index], longestWait)
        }
        let doubled = firstWait * pow(2, Double(max(attempt, 1) - 1))
        return min(doubled + random * randomness, longestWait)
    }

    /// The wait a `Retry-After` header asks for: seconds, or an HTTP date.
    static func retryAfter(_ value: String?, now: Date = .now) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = Double(value) {
            return seconds.isFinite ? max(seconds, 0) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        // RFC 9110: the preferred format, then the two obsolete ones
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(date.timeIntervalSince(now), 0)
            }
        }
        return nil
    }
}

/// At most so many requests in any rolling window, every attempt counted
/// (Apple Business and School Manager: 18 a minute per organization). A
/// request that would go over waits, written to the activity log; Cancel
/// stops the wait.
public nonisolated struct RateLimit: Sendable, Hashable {
    public var requests: Int
    public var window: TimeInterval
    /// Shown in the log before the wait, e.g. "Apple allows about 20 requests a minute".
    public var explanation: String

    public init(requests: Int, per window: TimeInterval, explanation: String) {
        self.requests = max(requests, 1)
        self.window = window
        self.explanation = explanation
    }
}

/// How request paths map onto the server.
nonisolated enum PathMapping: Sendable, Hashable {
    /// Paths are used as given.
    case none
    /// Jamf Pro without the Platform API gateway: `pro/…` goes to `api/…` and
    /// `proclassic/…` to `JSSResource/…`; other gateway paths are refused
    /// (JamfMigrator’s direct connections).
    case jamfProDirect
}

/// Paths that are always refused, whatever the app allows: `..`, `.`,
/// empty segments, encoded slashes or backslashes, broken encoding and
/// characters a path can’t hold.
nonisolated enum RequestPath {
    public static func isSafe(_ path: String) -> Bool {
        var trimmed = Substring(path)
        if trimmed.hasPrefix("/") { trimmed.removeFirst() }
        // one trailing slash is allowed: Jamf School’s Move to Trash is
        // documented as `devices/{udid}/`
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return false }
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert("%")
        allowed.remove("/")
        for segment in trimmed.split(separator: "/", omittingEmptySubsequences: false) {
            guard segment.unicodeScalars.allSatisfy(allowed.contains),
                  let decoded = segment.removingPercentEncoding,
                  !decoded.isEmpty, decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\\") else { return false }
        }
        return true
    }
}

/// Sends requests to one service: adds the token and the app’s headers,
/// checks every request before it leaves, and retries by `RetryRules`.
/// Every attempt, wait and refusal is written to the activity log by the
/// `RequestRecorder` underneath.
actor HTTPClient {
    public nonisolated let baseURL: URL
    public nonisolated let recorder: RequestRecorder
    private let tokens: (any BearerTokenSource)?
    private let headers: [String: String]
    private let permits: @Sendable (HTTPRequest) -> Bool
    private nonisolated let pathMapping: PathMapping
    private let redirects: RedirectRule
    private let writeSpacing: Duration
    private let maxConcurrent: Int?
    private let rateLimit: RateLimit?
    /// When the requests in the current window started, oldest first.
    private var recentRequests: [Date] = []
    private var inProgress = 0
    private var waitingTurns: [(id: UUID, turn: CheckedContinuation<Void, any Error>)] = []
    private let rules: RetryRules
    private let sleep: @Sendable (Duration) async throws -> Void
    private let random: @Sendable () -> Double
    private let now: @Sendable () -> Date
    private var lastWrite: ContinuousClock.Instant?

    /// - Parameters:
    ///   - baseURL: e.g. `https://us.api.jamfcloud.com`.
    ///   - tokens: the bearer token; nil sends no Authorization header.
    ///   - recorder: sends and records each attempt.
    ///   - headers: sent with every request, e.g. `X-Environment-Id`.
    ///   - permits: the app’s list of allowed requests, checked before
    ///     anything is sent. Unsafe paths are refused anyway (`RequestPath`).
    ///   - pathMapping: `.jamfProDirect` for Jamf Pro without the gateway.
    ///   - redirects: what to do when the server redirects; by default only
    ///     to HTTPS on the same host and port, so the token never goes elsewhere.
    ///   - writeSpacing: the shortest time between the start of two writes.
    ///   - maxConcurrent: at most this many requests at a time (Microsoft
    ///     Graph: 4); the others wait in order. A request keeps its turn while
    ///     it waits to be retried. Nil: no limit.
    ///   - rateLimit: at most so many requests in a rolling window (Apple
    ///     Business and School Manager). Nil: no limit.
    ///   - sleep, random, now: injectable for tests.
    public init(
        baseURL: URL,
        tokens: (any BearerTokenSource)?,
        recorder: RequestRecorder,
        headers: [String: String] = [:],
        permits: @escaping @Sendable (HTTPRequest) -> Bool = { _ in true },
        pathMapping: PathMapping = .none,
        redirects: RedirectRule = .sameHostHTTPSOnly,
        writeSpacing: Duration = .zero,
        maxConcurrent: Int? = nil,
        rateLimit: RateLimit? = nil,
        rules: RetryRules = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.recorder = recorder
        self.headers = headers
        self.permits = permits
        self.pathMapping = pathMapping
        self.redirects = redirects
        self.writeSpacing = writeSpacing
        self.maxConcurrent = maxConcurrent.map { max($0, 1) }
        self.rateLimit = rateLimit
        self.rules = rules
        self.sleep = sleep
        self.random = random
        self.now = now
    }

    /// The full address of a request.
    public nonisolated func url(for request: HTTPRequest) throws -> URL {
        let path = try mapped(request.path)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HTTPError.invalidURL("Invalid base address \(baseURL.absoluteString).")
        }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + "/" + path
        var queries = request.query.isEmpty ? [] : [FormEncoding.encode(request.query)]
        if let encoded = request.encodedQuery, !encoded.isEmpty {
            guard Self.isEncodedQuery(encoded) else {
                throw HTTPError.invalidURL("The query of \(request.path) isn’t correctly encoded.")
            }
            queries.append(encoded)
        }
        if !queries.isEmpty {
            components.percentEncodedQuery = queries.joined(separator: "&")
        }
        guard let url = components.url else {
            throw HTTPError.invalidURL("Couldn’t build an address for \(request.path).")
        }
        return url
    }

    public func get<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(HTTPRequest(path: path, query: query)).decoded(type)
    }

    /// Sends the request, retrying by the rules. Returns only a 2xx answer
    /// (and a 5xx for `serverErrorIsAnAnswer`).
    ///
    /// - Throws: `HTTPError`, `CancellationError`, or the token source’s error.
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard RequestPath.isSafe(request.path), permits(request) else {
            await recorder.note(request.method, request.path,
                                note: "Refused before sending: not a request this app makes.",
                                category: "Blocked", isWarning: true)
            throw HTTPError.refused(method: request.method, path: request.path)
        }
        let url = try url(for: request)
        let repeatable = request.isRepeatable
        var attempt = 0
        var renewedToken = false
        // an earlier attempt may have been carried out: a server error or a
        // dropped connection, not a 429 or 401 (nothing was done)
        var mayHaveBeenDone = false

        try await takeTurn()
        defer { finishTurn() }

        while true {
            attempt += 1
            try Task.checkCancellation()
            if !request.isRead { try await spaceWrite() }
            let made = try await makeURLRequest(request, url: url)
            var urlRequest = made.request
            let token = made.token
            urlRequest.httpMethod = request.method.uppercased()
            try await reserveSlot(for: request)
            let knownSecrets = token.map { [$0] } ?? []

            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await recorder.send(urlRequest, attempt: attempt, of: rules.maxAttempts,
                                                       recordsBodies: request.recordsBodies, recordedJSON: request.recordedJSON,
                                                       redirects: redirects, withholdsContents: request.withholdsContents,
                                                       knownSecrets: knownSecrets)
            } catch let error as URLError {
                let isDrop = rules.everyNetworkErrorIsADrop || RetryRules.networkDrops.contains(error.code)
                if isDrop && repeatable && attempt < rules.maxAttempts {
                    mayHaveBeenDone = true
                    try await wait(rules.backoff(afterAttempt: attempt, random: random()),
                                   reason: "Network error", request: request, nextAttempt: attempt + 1)
                    continue
                }
                throw HTTPError.transport(method: request.method, path: request.path, code: error.code,
                                          message: Redaction.removing(knownSecrets, from: Redaction.text(error.localizedDescription)))
            }

            // an error answer can repeat the token; it is shown and kept, so
            // the token and cookies go first (a success is returned as it came)
            let isError = !(200..<300).contains(http.statusCode)
            let headers = Self.headers(of: http)
            let response = HTTPResponse(
                status: http.statusCode,
                headers: isError ? headers.reduce(into: [:]) { $0[$1.key] = Redaction.headerValue(name: $1.key, value: $1.value) } : headers,
                data: isError ? Self.removing(knownSecrets, from: data) : data)
            switch http.statusCode {
            case 200..<300:
                return response
            case 401 where tokens != nil && !renewedToken && attempt < rules.maxAttempts:
                renewedToken = true
                await tokens?.forgetToken()
                await recorder.note(request.method, request.path,
                                    note: "HTTP 401: signing in again, attempt \(attempt + 1) of \(rules.maxAttempts).",
                                    category: "Retry", isWarning: true)
            case 500..<600 where request.serverErrorIsAnAnswer:
                return response
            case 404 where request.repeating == .safeNotFoundIsDone && mayHaveBeenDone:
                await recorder.note(request.method, request.path,
                                    note: "HTTP 404 after a repeat: an earlier attempt already did it.",
                                    category: "Retry")
                return response
            case 429 where attempt < rules.maxAttempts,
                 500..<600 where repeatable && attempt < rules.maxAttempts:
                if http.statusCode != 429 { mayHaveBeenDone = true }
                let delay = RetryRules.retryAfter(response.header("Retry-After"), now: now())
                    ?? rules.backoff(afterAttempt: attempt, random: random())
                try await wait(delay, reason: "HTTP \(http.statusCode)", request: request, nextAttempt: attempt + 1)
            default:
                throw HTTPError.status(response, method: request.method, path: request.path, duringSignIn: false)
            }
        }
    }

    // MARK: - Private

    private nonisolated func mapped(_ path: String) throws -> String {
        var trimmed = path
        if trimmed.hasPrefix("/") { trimmed.removeFirst() }
        switch pathMapping {
        case .none:
            return trimmed
        case .jamfProDirect:
            if trimmed.hasPrefix("proclassic/") { return "JSSResource/" + trimmed.dropFirst("proclassic/".count) }
            if trimmed.hasPrefix("pro/") { return "api/" + trimmed.dropFirst("pro/".count) }
            throw HTTPError.invalidURL("\(path) requires the Jamf Platform API gateway; this connection goes straight to Jamf Pro.")
        }
    }

    /// The request, and the token it carries.
    private func makeURLRequest(_ request: HTTPRequest, url: URL) async throws -> (request: URLRequest, token: String?) {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpBody = request.body
        for (name, value) in headers.merging(request.headers, uniquingKeysWith: { $1 }) {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let isClassic = ["proclassic/", "JSSResource/"].contains { request.path.drop { $0 == "/" }.hasPrefix($0) }
        urlRequest.setValue(request.accept ?? (isClassic ? "application/xml" : "application/json"), forHTTPHeaderField: "Accept")
        if request.body != nil {
            urlRequest.setValue(request.contentType ?? (isClassic ? "application/xml" : "application/json"),
                                forHTTPHeaderField: "Content-Type")
        }
        var token: String?
        if let tokens {
            // a sign-in counts in the rate limit too, as one more request
            token = rateLimit == nil
                ? try await tokens.token()
                : try await tokens.token(beforeSigningIn: { try await self.reserveSlot(for: request) })
            urlRequest.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        }
        return (urlRequest, token)
    }

    /// Waits until another request fits in the rate limit’s window. The
    /// slot is taken before anything is sent, so simultaneous requests queue.
    private func reserveSlot(for request: HTTPRequest) async throws {
        guard let rateLimit else { return }
        while true {
            let current = now()
            recentRequests.removeAll { current.timeIntervalSince($0) >= rateLimit.window }
            guard recentRequests.count >= rateLimit.requests, let oldest = recentRequests.first else {
                recentRequests.append(current)
                return
            }
            let delay = max(rateLimit.window - current.timeIntervalSince(oldest), 0) + 0.1
            await recorder.note(request.method, request.path,
                                note: "\(rateLimit.explanation): waiting \(Int(delay.rounded(.up))) s.",
                                category: "Retry", isWarning: true)
            do {
                try await sleep(.milliseconds(Int((delay * 1000).rounded())))
            } catch {
                await recorder.note(request.method, request.path, note: "Canceled while waiting.", category: "Retry")
                throw CancellationError()
            }
        }
    }

    /// The data with each known secret replaced, when it is text.
    private static func removing(_ secrets: [String], from data: Data) -> Data {
        guard !secrets.isEmpty, let text = String(data: data, encoding: .utf8) else { return data }
        let cleaned = Redaction.removing(secrets, from: text)
        return cleaned == text ? data : Data(cleaned.utf8)
    }

    /// Waits before the next attempt, written to the log first. Canceling
    /// the task stops the wait at once.
    private func wait(_ seconds: TimeInterval, reason: String, request: HTTPRequest, nextAttempt: Int) async throws {
        let delay = min(max(seconds, 0), rules.longestWait)
        let shown = delay < 10 && delay.rounded() != delay ? String(format: "%.1f", delay) : String(format: "%.0f", delay)
        await recorder.note(request.method, request.path,
                            note: "\(reason): waiting \(shown) s, attempt \(nextAttempt) of \(rules.maxAttempts).",
                            category: "Retry", isWarning: true)
        do {
            try await sleep(.milliseconds(Int((delay * 1000).rounded())))
        } catch {
            await recorder.note(request.method, request.path, note: "Canceled while waiting.", category: "Retry")
            throw CancellationError()
        }
    }

    /// Waits for a turn when the client has a limit; turns are handed out
    /// in the order they were asked for. Canceling the task stops the wait
    /// at once, without taking a turn.
    private func takeTurn() async throws {
        guard let maxConcurrent else { return }
        if inProgress < maxConcurrent {
            inProgress += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (turn: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    turn.resume(throwing: CancellationError())
                } else {
                    waitingTurns.append((id, turn))
                }
            }
        } onCancel: {
            Task { await self.cancelTurn(id) }
        }
    }

    /// A canceled request leaves the queue; one already given its turn
    /// keeps it and stops at its next cancellation check.
    private func cancelTurn(_ id: UUID) {
        guard let index = waitingTurns.firstIndex(where: { $0.id == id }) else { return }
        waitingTurns.remove(at: index).turn.resume(throwing: CancellationError())
    }

    /// Hands the turn straight to the next waiting request, if any.
    private func finishTurn() {
        guard maxConcurrent != nil else { return }
        if waitingTurns.isEmpty {
            inProgress -= 1
        } else {
            waitingTurns.removeFirst().turn.resume()
        }
    }

    /// Only characters a query may hold, and every `%` starts an escape.
    private nonisolated static func isEncodedQuery(_ query: String) -> Bool {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.insert("%")
        return query.unicodeScalars.allSatisfy(allowed.contains) && query.removingPercentEncoding != nil
            && query.firstMatch(of: /%(?![0-9A-Fa-f]{2})/) == nil
    }

    private func spaceWrite() async throws {
        guard writeSpacing > .zero else { return }
        let now = ContinuousClock.now
        let slot = max(lastWrite.map { $0 + writeSpacing } ?? now, now)
        // claimed before sleeping, so simultaneous writes queue up
        lastWrite = slot
        if slot > now { try await sleep(slot - now) }
    }

    private static func headers(of response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String { result[key] = "\(pair.value)" }
        }
    }
}
