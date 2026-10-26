import Foundation

/// Signs in to Microsoft Graph as an app registration with its client secret
/// (OAuth client credentials) and keeps the token. Microsoft's public cloud only.
///
/// - Asks `login.microsoftonline.com/{tenant}/oauth2/v2.0/token` for the
///   `https://graph.microsoft.com/.default` scope.
/// - Renews the token 60 s before it expires.
/// - Requests that need a token at the same time share one sign-in.
/// - Reads the secret only when it signs in, so a new secret is used at once.
/// - Sends the sign-in through the request recorder (category "Sign-in"); the
///   secret and the token are never recorded. Redirects are followed only to
///   HTTPS on the same host, so the secret never goes elsewhere.
/// - A refused sign-in is a `GraphError` with Microsoft's error code, Trace ID
///   and a hint for a wrong or expired secret, an unknown app or tenant.
public actor EntraTokenProvider: BearerTokenSource {
    public static let authorityHost = "login.microsoftonline.com"
    public static let graphScope = "https://graph.microsoft.com/.default"

    public nonisolated let tokenURL: URL
    public nonisolated let clientID: String
    private let secret: @Sendable () throws -> String
    private let recorder: RequestRecorder
    private let refreshMargin: TimeInterval
    private let now: @Sendable () -> Date

    private var cached: (value: String, expiresAt: Date, margin: TimeInterval)?
    private var inFlight: Task<(String, Date, TimeInterval), any Error>?

    /// How many times it signed in; for tests and diagnostics.
    public private(set) var signInCount = 0

    /// - Parameters:
    ///   - tenantID: the Entra tenant ID or a verified domain.
    ///   - clientID: the app registration's Application (client) ID.
    ///   - secret: the client secret; its errors are passed on unchanged.
    /// - Throws: `GraphError.Kind.invalidConnection` for an empty or unusable
    ///   tenant, or a client ID that isn't a UUID.
    public init(
        tenantID: String,
        clientID: String,
        secret: @escaping @Sendable () throws -> String,
        recorder: RequestRecorder,
        refreshMargin: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let tenant = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tenant.isEmpty, tenant.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }) else {
            throw GraphError(.invalidConnection("“\(tenant)” is not a tenant ID or domain. Copy the Directory (tenant) ID from Entra."),
                             access: .application)
        }
        guard UUID(uuidString: client) != nil else {
            throw GraphError(.invalidConnection("The client ID is not a UUID. Copy the Application (client) ID from Entra."),
                             access: .application)
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.authorityHost
        components.path = "/\(tenant)/oauth2/v2.0/token"
        guard let url = components.url else {
            throw GraphError(.invalidConnection("No sign-in address for “\(tenant)”."), access: .application)
        }
        tokenURL = url
        self.clientID = client
        self.secret = secret
        self.recorder = recorder
        self.refreshMargin = refreshMargin
        self.now = now
    }

    /// Signs in with an Intune connection's tenant and client ID.
    ///
    /// - Throws: `GraphError.Kind.invalidConnection` for another service or
    ///   sign-in method (Microsoft's sign-in window is `JTKitMSAL`'s).
    public init(
        connection: Connection,
        secret: @escaping @Sendable () throws -> String,
        recorder: RequestRecorder,
        refreshMargin: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        guard connection.service == .intune, connection.signIn == .entraClientSecret else {
            throw GraphError(.invalidConnection("\(connection.service.displayName) can’t sign in with \(connection.signIn.displayName.lowercased()) here."),
                             access: .application)
        }
        try self.init(tenantID: connection.tenantID, clientID: connection.clientID, secret: secret,
                      recorder: recorder, refreshMargin: refreshMargin, now: now)
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
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode([
            URLQueryItem(name: "grant_type", value: "client_credentials"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: secret),
            URLQueryItem(name: "scope", value: Self.graphScope),
        ]).utf8)

        let issuedAt = now()
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await recorder.send(request, category: "Sign-in", redirects: .sameHostHTTPSOnly)
        } catch let error as URLError {
            throw GraphError(GraphError.Kind.transport(method: "POST", path: tokenURL.path(), code: error.code,
                                        message: Redaction.text(error.localizedDescription)), access: .application)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw GraphError(HTTPError.status(HTTPResponse(status: response.statusCode, headers: [:], data: data),
                                              method: "POST", path: tokenURL.path(), duringSignIn: true),
                             access: .application)
        }
        guard let token = try? JSONDecoder().decode(Token.self, from: data), !token.accessToken.isEmpty else {
            throw GraphError(.invalidResponse("The sign-in answer has no access token."), access: .application)
        }
        let lifetime = TimeInterval(token.expiresIn ?? 3599)
        // a short-lived token is renewed halfway, not never trusted
        return (token.accessToken, issuedAt.addingTimeInterval(lifetime), min(refreshMargin, lifetime / 2))
    }

    private struct Token: Decodable {
        let accessToken: String
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }
}
