import Foundation

/// Signs in to Jamf and keeps the token: an API client on the Platform API
/// gateway (`/auth/token`) or Jamf Pro (`/api/oauth/token`), or a username and
/// password on Jamf Pro (`/api/v1/auth/token`).
///
/// - Renews the token 60 s before it expires.
/// - Requests that need a token at the same time share one sign-in.
/// - Reads the secret only when it signs in, so a new secret is used at once.
/// - Sends the sign-in through the request recorder (category "Sign-in"); the
///   secret and the token are never recorded.
public actor JamfTokenProvider: BearerTokenSource {
    /// How it signs in.
    public enum Method: Sendable, Hashable {
        /// OAuth client credentials; the secret is the client secret.
        case apiClient(clientID: String)
        /// Basic authentication for a Jamf Pro token; the secret is the password.
        case usernamePassword(username: String)
    }

    public nonisolated let tokenURL: URL
    public nonisolated let method: Method
    private let secret: @Sendable () throws -> String
    private let recorder: RequestRecorder
    private let refreshMargin: TimeInterval
    private let now: @Sendable () -> Date

    private var cached: (value: String, expiresAt: Date, margin: TimeInterval)?
    private var inFlight: Task<(String, Date, TimeInterval), any Error>?

    /// How many times it signed in; for tests and diagnostics.
    public private(set) var signInCount = 0

    /// - Parameters:
    ///   - tokenURL: the full address of the token endpoint.
    ///   - secret: the client secret or password; its errors are passed on
    ///     unchanged (e.g. the app's "no secret saved" error).
    ///   - recorder: sends and records the sign-in.
    public init(
        tokenURL: URL,
        method: Method,
        secret: @escaping @Sendable () throws -> String,
        recorder: RequestRecorder,
        refreshMargin: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.tokenURL = tokenURL
        self.method = method
        self.secret = secret
        self.recorder = recorder
        self.refreshMargin = refreshMargin
        self.now = now
    }

    /// Signs in to the connection: the Platform API gateway of its region (or
    /// its host override), or its Jamf Pro server.
    ///
    /// - Throws: `HTTPError.invalidURL` when the connection isn't a Jamf
    ///   Platform API or Jamf Pro connection with a usable address.
    public init(
        connection: Connection,
        secret: @escaping @Sendable () throws -> String,
        recorder: RequestRecorder,
        refreshMargin: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard let base = connection.jamfBaseURL else {
            throw HTTPError.invalidURL("“\(ConnectionMenuText.name(of: connection))” has no valid Jamf address.")
        }
        let clientID = connection.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = connection.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokenURL: URL
        let method: Method
        switch (connection.service, connection.signIn) {
        case (.jamfPlatform, .apiClient):
            (tokenURL, method) = (base.appending(path: "auth/token"), .apiClient(clientID: clientID))
        case (.jamfPro, .apiClient):
            (tokenURL, method) = (base.appending(path: "api/oauth/token"), .apiClient(clientID: clientID))
        case (.jamfPro, .usernamePassword):
            (tokenURL, method) = (base.appending(path: "api/v1/auth/token"), .usernamePassword(username: username))
        default:
            throw HTTPError.invalidURL("\(connection.service.displayName) can't sign in with \(connection.signIn.displayName.lowercased()).")
        }
        self.init(tokenURL: tokenURL, method: method, secret: secret, recorder: recorder,
                  refreshMargin: refreshMargin, now: now)
    }

    public func token() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSince(now()) > cached.margin {
            return cached.value
        }
        if let inFlight {
            return try await inFlight.value.0
        }
        let task = Task { try await self.signIn() }
        inFlight = task
        defer { inFlight = nil }
        do {
            let (value, expiresAt, margin) = try await task.value
            cached = (value, expiresAt, margin)
            return value
        } catch {
            cached = nil
            throw error
        }
    }

    public func forgetToken() {
        cached = nil
    }

    private func signIn() async throws -> (String, Date, TimeInterval) {
        signInCount += 1
        let secret = try secret()

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch method {
        case let .apiClient(clientID):
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(FormEncoding.encode([
                URLQueryItem(name: "grant_type", value: "client_credentials"),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "client_secret", value: secret),
            ]).utf8)
        case let .usernamePassword(username):
            let credentials = Data("\(username):\(secret)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }

        let issuedAt = now()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await recorder.send(request, category: "Sign-in")
        } catch let error as URLError {
            throw HTTPError.transport(method: "POST", path: tokenURL.path(), code: error.code,
                                      message: Redaction.text(error.localizedDescription))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError.status(HTTPResponse(status: response.statusCode, headers: [:], data: data),
                                   method: "POST", path: tokenURL.path(), duringSignIn: true)
        }
        let (value, lifetime) = try Self.parse(data, now: issuedAt)
        // a short-lived token is renewed halfway, not never trusted
        return (value, issuedAt.addingTimeInterval(lifetime), min(refreshMargin, lifetime / 2))
    }

    /// Both token answers: OAuth (`access_token`, `expires_in`) and Jamf Pro's
    /// user token (`token`, `expires` as an ISO 8601 date).
    static func parse(_ data: Data, now: Date) throws -> (String, TimeInterval) {
        if let oauth = try? JSONDecoder().decode(OAuthToken.self, from: data) {
            return (oauth.accessToken, TimeInterval(oauth.expiresIn ?? 300))
        }
        do {
            let user = try JSONDecoder().decode(UserToken.self, from: data)
            let expires = user.expires.flatMap(parseDate)
            let lifetime = expires.map { $0.timeIntervalSince(now) } ?? 20 * 60
            return (user.token, max(lifetime, 60))
        } catch {
            throw HTTPError.decoding("Sign-in answer: \(error.localizedDescription)")
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private struct OAuthToken: Decodable {
        let accessToken: String
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    private struct UserToken: Decodable {
        let token: String
        let expires: String?
    }
}

extension Connection {
    /// Where Jamf requests go: the Platform API gateway of the region, or the
    /// host override (scheme and trailing slashes dropped), or the Jamf Pro
    /// server. Nil for other services and unusable addresses.
    public var jamfBaseURL: URL? {
        switch service {
        case .jamfPlatform:
            var host = hostOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { return region.gatewayURL }
            for prefix in ["https://", "http://"] where host.lowercased().hasPrefix(prefix) {
                host.removeFirst(prefix.count)
            }
            while host.hasSuffix("/") { host.removeLast() }
            guard !host.isEmpty, !host.contains("/") else { return nil }
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            return components.url
        case .jamfPro:
            var address = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while address.hasSuffix("/") { address.removeLast() }
            guard Self.isWebAddress(address) else { return nil }
            return URL(string: address)
        case .jamfSchool, .intune, .appleBusinessManager, .appleSchoolManager:
            return nil
        }
    }
}
