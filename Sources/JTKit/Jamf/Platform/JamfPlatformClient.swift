import Foundation

extension JamfPlatform {
    /// Talks to the Jamf Platform API for one connection, on JTKit's
    /// `HTTPClient`: signs in with `JamfTokenProvider`, adds the scope header,
    /// checks each request against the app's allow-list, retries by JTKit's
    /// rules and writes every attempt, wait and refusal to the activity log.
    ///
    /// Errors come back as `JamfPlatformError`. Follows a redirect only to
    /// HTTPS on the same host and port, as the sign-in does.
    ///
    /// Also talks to a Jamf Pro server directly (`server: .jamfPro`), for
    /// tenants without Platform API access; the same gateway-form paths are
    /// then mapped onto Jamf Pro's.
    public struct Client: Sendable {
        /// Which header says what the requests are about.
        public enum Scope: Sendable, Hashable {
            /// `X-Environment-Id`; must be a UUID.
            case environment(String)
            /// `X-Tenant-Id`, for Jamf Deployer's older integrations.
            case legacyTenant(String)
            /// No scope header: the integration's own organization, e.g. its
            /// list of environments, or a Jamf Pro server reached directly.
            case organization
        }

        /// What an error status does.
        public enum ErrorStatus: Sendable, Hashable {
            /// Thrown as a `JamfPlatformError` of kind `.status`.
            case thrown
            /// Returned as the response, for callers that read the status
            /// themselves (Jamf Deployer's preflight). A refused sign-in is
            /// still thrown.
            case returned
        }

        public let baseURL: URL
        public let scope: Scope
        public let server: JamfPlatform.Server
        public let errorStatus: ErrorStatus
        /// How the client signs in; decides the wording of Jamf Pro's
        /// sign-in and privilege hints.
        public let signIn: SignInMethod
        let http: HTTPClient
        /// The recorder under the client, for the few requests that don't go
        /// through it (e.g. images on another host).
        public var recorder: RequestRecorder { http.recorder }
        private let tokens: any BearerTokenSource
        private let hints: @Sendable (JamfPlatformError) -> [String]

        /// A client for a saved connection.
        ///
        /// - Parameters:
        ///   - connection: a Jamf Platform API connection (region or host
        ///     override, Environment ID and client ID), or a Jamf Pro
        ///     connection, reached directly with no scope header.
        ///   - secret: the client secret, read when signing in; its errors are
        ///     passed on unchanged (e.g. the app's "no secret saved").
        ///   - scope: the connection's Environment ID by default.
        ///   - permits: the app's allow-list, checked before anything is sent.
        ///   - hints: the app's own hints for an error, shown before the
        ///     standard ones (e.g. what its allow-list allows).
        ///   - headers: sent with every request, e.g. a header of the app's own.
        ///   - sleep, random, now: injectable for tests.
        /// - Throws: `JamfPlatformError` `.invalidEnvironmentID` when the
        ///   Environment ID isn't a UUID, `.invalidResponse` when the
        ///   connection has no usable address.
        public init(
            connection: Connection,
            secret: @escaping @Sendable () throws -> String,
            recorder: RequestRecorder,
            scope: Scope? = nil,
            errorStatus: ErrorStatus = .thrown,
            permits: @escaping @Sendable (HTTPRequest) -> Bool = { _ in true },
            hints: @escaping @Sendable (JamfPlatformError) -> [String] = { _ in [] },
            headers: [String: String] = [:],
            writeSpacing: Duration = .zero,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
            now: @escaping @Sendable () -> Date = { Date() }
        ) throws {
            let server: JamfPlatform.Server = connection.service == .jamfPro ? .jamfPro : .platformAPI
            guard [.jamfPlatform, .jamfPro].contains(connection.service), let baseURL = connection.jamfBaseURL else {
                throw JamfPlatformError(.invalidResponse("“\(ConnectionMenuText.name(of: connection))” is not a Jamf Platform API or Jamf Pro connection with a valid address."))
            }
            let tokens: JamfTokenProvider
            do {
                tokens = try JamfTokenProvider(connection: connection, secret: secret, recorder: recorder, now: now)
            } catch let error as HTTPError {
                throw JamfPlatformError(error)
            }
            try self.init(baseURL: baseURL,
                          scope: scope ?? (server == .jamfPro ? .organization : .environment(connection.environmentID)),
                          server: server, signIn: connection.signIn,
                          tokens: tokens, recorder: recorder, errorStatus: errorStatus, permits: permits, hints: hints,
                          headers: headers, writeSpacing: writeSpacing, sleep: sleep, random: random, now: now)
        }

        /// A client with its own token source, e.g. for tests or credentials
        /// that aren't saved as a connection.
        ///
        /// - Parameter server: `.jamfPro` for a Jamf Pro server reached
        ///   directly; give it `.organization` scope.
        public init(
            baseURL: URL,
            scope: Scope,
            server: JamfPlatform.Server = .platformAPI,
            signIn: SignInMethod = .apiClient,
            tokens: any BearerTokenSource,
            recorder: RequestRecorder,
            errorStatus: ErrorStatus = .thrown,
            permits: @escaping @Sendable (HTTPRequest) -> Bool = { _ in true },
            hints: @escaping @Sendable (JamfPlatformError) -> [String] = { _ in [] },
            headers extraHeaders: [String: String] = [:],
            writeSpacing: Duration = .zero,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
            now: @escaping @Sendable () -> Date = { Date() }
        ) throws {
            var headers = extraHeaders
            switch scope {
            case .environment(let id):
                let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard UUID(uuidString: trimmed) != nil else { throw JamfPlatformError(.invalidEnvironmentID(trimmed)) }
                headers["X-Environment-Id"] = trimmed
            case .legacyTenant(let id):
                headers["X-Tenant-Id"] = id.trimmingCharacters(in: .whitespacesAndNewlines)
            case .organization:
                break
            }
            self.baseURL = baseURL
            self.scope = scope
            self.server = server
            self.signIn = signIn
            self.errorStatus = errorStatus
            self.tokens = tokens
            self.hints = hints
            http = HTTPClient(baseURL: baseURL, tokens: tokens, recorder: recorder, headers: headers,
                              permits: permits, pathMapping: server == .jamfPro ? .jamfProDirect : .none,
                              redirects: .sameHostHTTPSOnly, writeSpacing: writeSpacing,
                              sleep: sleep, random: random, now: now)
        }

        /// Sends a request. Returns a 2xx answer, or with `errorStatus:
        /// .returned` any answer.
        ///
        /// - Parameter privilege: the Jamf Pro privilege the request needs,
        ///   named in the hint when Jamf Pro refuses it.
        /// - Throws: `JamfPlatformError`, `CancellationError`, or the secret's own error.
        public func send(_ request: HTTPRequest, privilege: JamfPro.Privilege? = nil) async throws -> HTTPResponse {
            do {
                return try await http.send(request)
            } catch let HTTPError.status(response, _, _, duringSignIn) where !duringSignIn && errorStatus == .returned {
                return response
            } catch let error as HTTPError {
                var error = JamfPlatformError(error)
                error.privilege = privilege
                throw failure(error)
            }
        }

        /// A GET, read as lossless JSON.
        public func json(_ path: String, query: [URLQueryItem] = [], privilege: JamfPro.Privilege? = nil) async throws -> LosslessJSON {
            let response = try await send(HTTPRequest(path: path, query: query), privilege: privilege)
            do {
                return try LosslessJSON(data: response.data)
            } catch {
                throw failure(JamfPlatformError(.invalidResponse("\(path) is not valid JSON: \(error.localizedDescription)")))
            }
        }

        /// A GET, decoded.
        public func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = [],
                                      privilege: JamfPro.Privilege? = nil) async throws -> T {
            let response = try await send(HTTPRequest(path: path, query: query), privilege: privilege)
            do {
                return try JSONDecoder().decode(type, from: response.data)
            } catch {
                throw failure(JamfPlatformError(.invalidResponse("\(path) could not be read: \(error.localizedDescription)")))
            }
        }

        /// Signs in again now, ignoring a saved token, e.g. for Test Connection.
        public func signIn() async throws {
            await tokens.forgetToken()
            do {
                _ = try await tokens.token()
            } catch let error as HTTPError {
                throw failure(JamfPlatformError(error))
            }
        }

        /// An error with the client's server and the app's hints added, as
        /// the client throws it.
        public func failure(_ error: JamfPlatformError) -> JamfPlatformError {
            var annotated = error
            annotated.server = server
            annotated.signIn = signIn
            annotated.appHints += hints(error).filter { !annotated.appHints.contains($0) }
            return annotated
        }

        /// Forgets the token, so the next request signs in with what is saved now.
        public func forgetToken() async {
            await tokens.forgetToken()
        }
    }
}
