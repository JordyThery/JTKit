import Foundation

/// One request to a service, relative to the client's base URL.
public nonisolated struct HTTPRequest: Sendable {
    public var method: String
    /// Percent-encoded path relative to the base URL, e.g.
    /// `device-groups/v1/device-groups`. A leading slash is ignored.
    public var path: String
    /// Encoded strictly (`FormEncoding`), so `=`, `&` and quotes in values
    /// can't change the meaning of the request.
    public var query: [URLQueryItem]
    public var body: Data?
    /// JSON by default; XML for Classic API paths.
    public var accept: String?
    public var contentType: String?
    /// Headers for this request only.
    public var headers: [String: String]
    /// An edit that can be sent twice without harm (e.g. a PUT that replaces
    /// a whole record). Server errors and network drops are retried only for
    /// reads and for these.
    public var safeToRepeat: Bool
    /// Record both bodies in the activity log, also of a success. Only for
    /// requests the app knows carry nothing secret: by default request
    /// bodies are never recorded and response bodies only for errors.
    public var recordsBodies: Bool
    /// Trims a JSON body before it is redacted and recorded, e.g. to keep only
    /// the inventory sections the app asked for. Gets the parsed JSON and
    /// returns what may be recorded. A body that isn't JSON then isn't
    /// recorded at all. The answer the app receives is unchanged.
    public var recordedJSON: RecordedJSONFilter?

    public init(
        method: String = "GET",
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        accept: String? = nil,
        contentType: String? = nil,
        headers: [String: String] = [:],
        safeToRepeat: Bool = false,
        recordsBodies: Bool = false,
        recordedJSON: RecordedJSONFilter? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.accept = accept
        self.contentType = contentType
        self.headers = headers
        self.safeToRepeat = safeToRepeat
        self.recordsBodies = recordsBodies
        self.recordedJSON = recordedJSON
    }

    /// GET and HEAD.
    public var isRead: Bool {
        ["GET", "HEAD"].contains(method.uppercased())
    }
}

public nonisolated struct HTTPResponse: Sendable {
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

    public func decoded<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw HTTPError.decoding("\(T.self): \(error)")
        }
    }
}

/// Why a request failed. Every message goes through `Redaction`.
public nonisolated enum HTTPError: Error, LocalizedError, Sendable {
    /// Not sent: not on the app's list of allowed requests, or the path
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
            text = "Refused before sending: \(method) \(path) is not a request this app makes."
        case let .invalidURL(message):
            text = message
        case let .transport(_, _, _, message):
            text = "Network error: \(message)"
        case let .status(response, method, path, duringSignIn):
            let detail = Self.detail(of: response)
            text = duringSignIn
                ? "Sign-in failed (HTTP \(response.status))" + (detail.map { ": \($0)" } ?? ".")
                : "\(method) \(path) failed with HTTP \(response.status)." + (detail.map { " \($0)" } ?? "")
        case let .decoding(message):
            text = "Unexpected response format: \(message)"
        }
        return Redaction.text(text)
    }

    /// The start of the server's answer, redacted, at most 300 characters.
    static func detail(of response: HTTPResponse) -> String? {
        guard let body = Redaction.body(response.data, contentType: response.header("Content-Type")) else { return nil }
        let flat = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }
}

/// Where a client gets its bearer token, e.g. `JamfTokenProvider`.
public protocol BearerTokenSource: Sendable {
    /// A token valid for a while yet; signs in when needed.
    func token() async throws -> String
    /// Drops the token, e.g. after the server answered 401.
    func forgetToken() async
}

/// The retry rules, the same in every app.
///
/// At most 4 attempts. 429 is retried for every method; server errors (5xx)
/// and short network drops only for reads and for edits marked safe to
/// repeat. `Retry-After` is read as seconds or as an HTTP date; otherwise
/// the wait doubles from 1 s, with up to 0.5 s of randomness. No wait is
/// longer than 120 s. A 401 gets a new token and one more try (part of the 4).
public nonisolated struct RetryRules: Sendable, Hashable {
    public var maxAttempts: Int
    public var firstWait: TimeInterval
    public var randomness: TimeInterval
    public var longestWait: TimeInterval

    public static let standard = RetryRules()

    public init(maxAttempts: Int = 4, firstWait: TimeInterval = 1, randomness: TimeInterval = 0.5, longestWait: TimeInterval = 120) {
        self.maxAttempts = maxAttempts
        self.firstWait = firstWait
        self.randomness = randomness
        self.longestWait = longestWait
    }

    /// Short network drops worth another try.
    static let networkDrops: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet,
    ]

    /// The wait after a failed attempt (1, 2, …) without `Retry-After`.
    /// - Parameter random: between 0 and 1.
    public func backoff(afterAttempt attempt: Int, random: Double) -> TimeInterval {
        let doubled = firstWait * pow(2, Double(max(attempt, 1) - 1))
        return min(doubled + random * randomness, longestWait)
    }

    /// The wait a `Retry-After` header asks for: seconds, or an HTTP date.
    public static func retryAfter(_ value: String?, now: Date = .now) -> TimeInterval? {
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

/// How request paths map onto the server.
public nonisolated enum PathMapping: Sendable, Hashable {
    /// Paths are used as given.
    case none
    /// Jamf Pro without the Platform API gateway: `pro/…` goes to `api/…` and
    /// `proclassic/…` to `JSSResource/…`; other gateway paths are refused
    /// (JamfMigrator's direct connections).
    case jamfProDirect
}

/// Paths that are always refused, whatever the app allows: `..`, `.`,
/// empty segments, encoded slashes or backslashes, broken encoding and
/// characters a path can't hold.
public nonisolated enum RequestPath {
    public static func isSafe(_ path: String) -> Bool {
        var trimmed = Substring(path)
        if trimmed.hasPrefix("/") { trimmed.removeFirst() }
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

/// Sends requests to one service: adds the token and the app's headers,
/// checks every request before it leaves, and retries by `RetryRules`.
/// Every attempt, wait and refusal is written to the activity log by the
/// `RequestRecorder` underneath.
public actor HTTPClient {
    public nonisolated let baseURL: URL
    public nonisolated let recorder: RequestRecorder
    private let tokens: (any BearerTokenSource)?
    private let headers: [String: String]
    private let permits: @Sendable (HTTPRequest) -> Bool
    private nonisolated let pathMapping: PathMapping
    private let redirects: RedirectRule
    private let writeSpacing: Duration
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
    ///   - permits: the app's list of allowed requests, checked before
    ///     anything is sent. Unsafe paths are refused anyway (`RequestPath`).
    ///   - pathMapping: `.jamfProDirect` for Jamf Pro without the gateway.
    ///   - redirects: what to do when the server redirects.
    ///   - writeSpacing: the shortest time between the start of two writes.
    ///   - sleep, random, now: injectable for tests.
    public init(
        baseURL: URL,
        tokens: (any BearerTokenSource)?,
        recorder: RequestRecorder,
        headers: [String: String] = [:],
        permits: @escaping @Sendable (HTTPRequest) -> Bool = { _ in true },
        pathMapping: PathMapping = .none,
        redirects: RedirectRule = .follow,
        writeSpacing: Duration = .zero,
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
        if !request.query.isEmpty {
            components.percentEncodedQuery = FormEncoding.encode(request.query)
        }
        guard let url = components.url else {
            throw HTTPError.invalidURL("Could not build an address for \(request.path).")
        }
        return url
    }

    public func get<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(HTTPRequest(path: path, query: query)).decoded(type)
    }

    /// Sends the request, retrying by the rules. Returns only a 2xx answer.
    ///
    /// - Throws: `HTTPError`, `CancellationError`, or the token source's error.
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard RequestPath.isSafe(request.path), permits(request) else {
            await recorder.note(request.method, request.path,
                                note: "Refused before sending: not a request this app makes.",
                                category: "Blocked", isWarning: true)
            throw HTTPError.refused(method: request.method, path: request.path)
        }
        let url = try url(for: request)
        let repeatable = request.isRead || request.safeToRepeat
        var attempt = 0
        var renewedToken = false

        while true {
            attempt += 1
            try Task.checkCancellation()
            if !request.isRead { try await spaceWrite() }
            var urlRequest = try await makeURLRequest(request, url: url)
            urlRequest.httpMethod = request.method.uppercased()

            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await recorder.send(urlRequest, attempt: attempt, of: rules.maxAttempts,
                                                       recordsBodies: request.recordsBodies, recordedJSON: request.recordedJSON,
                                                       redirects: redirects)
            } catch let error as URLError {
                if RetryRules.networkDrops.contains(error.code) && repeatable && attempt < rules.maxAttempts {
                    try await wait(rules.backoff(afterAttempt: attempt, random: random()),
                                   reason: "Network error", request: request, nextAttempt: attempt + 1)
                    continue
                }
                throw HTTPError.transport(method: request.method, path: request.path, code: error.code,
                                          message: Redaction.text(error.localizedDescription))
            }

            let response = HTTPResponse(status: http.statusCode, headers: Self.headers(of: http), data: data)
            switch http.statusCode {
            case 200..<300:
                return response
            case 401 where tokens != nil && !renewedToken && attempt < rules.maxAttempts:
                renewedToken = true
                await tokens?.forgetToken()
                await recorder.note(request.method, request.path,
                                    note: "HTTP 401: signing in again, attempt \(attempt + 1) of \(rules.maxAttempts).",
                                    category: "Retry", isWarning: true)
            case 429 where attempt < rules.maxAttempts,
                 500..<600 where repeatable && attempt < rules.maxAttempts:
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

    private func makeURLRequest(_ request: HTTPRequest, url: URL) async throws -> URLRequest {
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
        if let tokens {
            urlRequest.setValue("Bearer \(try await tokens.token())", forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }

    /// Waits before the next attempt, written to the log first. Cancelling
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
            await recorder.note(request.method, request.path, note: "Cancelled while waiting.", category: "Retry")
            throw CancellationError()
        }
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
