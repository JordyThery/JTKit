import CryptoKit
import Foundation

extension ABM {
    /// Signs in to Apple Business or School Manager with the API account’s
    /// private key (OAuth client credentials with an ES256-signed client
    /// assertion) and keeps the token.
    ///
    /// - Asks `account.apple.com/auth/oauth2/v2/token` for the service’s scope.
    /// - Renews the token 60 s before it expires.
    /// - Requests that need a token at the same time share one sign-in.
    /// - Reads the private key only when it signs in, and keeps neither it
    ///   nor the signed request afterwards. Each sign-in signs a new request.
    /// - The sign-in is one of JTKit’s sensitive calls: only its method,
    ///   path, status and duration are recorded, never the signed request or
    ///   the token. A refused sign-in shows only Apple’s `error` and
    ///   `error_description`, with the key and the signed request taken out.
    /// - Redirects are followed only to HTTPS on the same host.
    /// - On `ABM.Client`, each sign-in takes one of the 18 requests a minute.
    public actor TokenProvider: BearerTokenSource {
        public static let tokenURL = URL(string: "https://account.apple.com/auth/oauth2/v2/token")!
        /// How long a signed request is valid.
        static let assertionLifetime = 1200

        public nonisolated let service: Service
        public nonisolated let clientID: String
        public nonisolated let keyID: String
        private let privateKey: @Sendable () throws -> String
        private let recorder: RequestRecorder
        private let refreshMargin: TimeInterval
        private let now: @Sendable () -> Date

        private var cached: (value: String, expiresAt: Date, margin: TimeInterval)?
        private var inFlight: Task<(String, Date, TimeInterval), any Swift.Error>?

        /// How many times it signed in; for tests and diagnostics.
        public private(set) var signInCount = 0

        /// - Parameters:
        ///   - privateKey: the .pem text; its errors are passed on unchanged.
        public init(
            service: Service,
            clientID: String,
            keyID: String,
            privateKey: @escaping @Sendable () throws -> String,
            recorder: RequestRecorder,
            refreshMargin: TimeInterval = 60,
            now: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.service = service
            self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.privateKey = privateKey
            self.recorder = recorder
            self.refreshMargin = refreshMargin
            self.now = now
        }

        /// Signs in with an Apple Business or School Manager connection.
        ///
        /// - Throws: `ABM.APIError.Kind.invalidRequest` for another service.
        public init(
            connection: Connection,
            privateKey: @escaping @Sendable () throws -> String,
            recorder: RequestRecorder,
            refreshMargin: TimeInterval = 60,
            now: @escaping @Sendable () -> Date = { Date() }
        ) throws {
            guard let service = Service(connection.service) else {
                throw ABM.APIError(.invalidRequest("\(connection.service.displayName) isn’t Apple Business Manager or Apple School Manager."))
            }
            self.init(service: service, clientID: connection.clientID, keyID: connection.keyID, privateKey: privateKey,
                      recorder: recorder, refreshMargin: refreshMargin, now: now)
        }

        public func token() async throws -> String {
            try await token(beforeSigningIn: {})
        }

        /// As `token()`; `beforeSigningIn` runs before a sign-in this call
        /// starts (the client’s rate limit: Apple counts the sign-in too), not
        /// when it shares one already under way.
        public func token(beforeSigningIn: @escaping @Sendable () async throws -> Void) async throws -> String {
            if let cached, cached.expiresAt.timeIntervalSince(now()) > cached.margin {
                return cached.value
            }
            if let inFlight {
                return try await inFlight.value.0
            }
            try await beforeSigningIn()
            // another request may have signed in while this one waited
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
            let pem = try privateKey()
            let issuedAt = now()
            let assertion = try Self.clientAssertion(clientID: clientID, keyID: keyID, privateKey: pem, service: service,
                                                     issuedAt: issuedAt)
            var request = URLRequest(url: Self.tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(FormEncoding.encode([
                URLQueryItem(name: "grant_type", value: "client_credentials"),
                URLQueryItem(name: "client_id", value: clientID),
                URLQueryItem(name: "client_assertion_type", value: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"),
                URLQueryItem(name: "client_assertion", value: assertion),
                URLQueryItem(name: "scope", value: service.scope),
            ]).utf8)
            let secrets = [assertion, pem]

            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await recorder.send(request, category: "Sign-in", redirects: .sameHostHTTPSOnly,
                                                           withholdsContents: true, knownSecrets: secrets)
            } catch let error as URLError {
                let message = Redaction.removing(secrets, from: Redaction.text(error.localizedDescription))
                throw ABM.APIError(.transport(method: "POST", path: Self.tokenURL.path(), code: error.code, message: message),
                                service: service)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw Self.signInError(status: response.statusCode, data: data, secrets: secrets, service: service)
            }
            guard let token = try? JSONDecoder().decode(Token.self, from: data), !token.accessToken.isEmpty else {
                throw ABM.APIError(.invalidResponse("The sign-in answer has no access token."), service: service)
            }
            let lifetime = TimeInterval(token.expiresIn ?? 3600)
            // a short-lived token is renewed halfway, not never trusted
            return (token.accessToken, issuedAt.addingTimeInterval(lifetime), min(refreshMargin, lifetime / 2))
        }

        /// Only Apple’s `error` and `error_description`, cleaned and with the
        /// key and the signed request taken out; nothing of an answer that
        /// isn’t JSON.
        static func signInError(status: Int, data: Data, secrets: [String], service: Service) -> ABM.APIError {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            func cleaned(_ value: Any?) -> String? {
                guard let text = value as? String, !text.isEmpty else { return nil }
                let clean = Redaction.removing(secrets, from: Redaction.text(text))
                return String(clean.prefix(300))
            }
            return ABM.APIError(.signIn(status: status, code: cleaned(object?["error"]),
                                     description: cleaned(object?["error_description"])), service: service)
        }

        // MARK: - The signed request

        /// The signed client assertion (a JWT): ES256, the key ID, the client
        /// ID as issuer and subject, Apple’s token address as audience, valid
        /// 20 minutes, a new ID each time.
        ///
        /// - Throws: `ABM.APIError.Kind.unreadableKey`, never with the key in it.
        static func clientAssertion(clientID: String, keyID: String, privateKey pem: String, service: Service,
                                    issuedAt: Date, id: String = UUID().uuidString) throws -> String {
            let key: P256.Signing.PrivateKey
            do {
                key = try readPrivateKey(pem)
            } catch {
                throw ABM.APIError(.unreadableKey, service: service)
            }
            let iat = Int(issuedAt.timeIntervalSince1970)
            let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
            let claims: [String: Any] = [
                "iss": clientID, "sub": clientID, "aud": tokenURL.absoluteString,
                "iat": iat, "exp": iat + assertionLifetime, "jti": id,
            ]
            let signingInput = try base64URL(json: header) + "." + base64URL(json: claims)
            guard let signature = try? key.signature(for: Data(signingInput.utf8)) else {
                throw ABM.APIError(.unreadableKey, service: service)
            }
            return signingInput + "." + base64URL(signature.rawRepresentation)
        }

        /// Reads the downloaded key.
        ///
        /// Apple School Manager hands out a key whose armor says `EC PRIVATE
        /// KEY`, the SEC1 label, around a PKCS#8 body. CryptoKit believes the
        /// label and fails; the armor is swapped and tried again, which
        /// still rejects a key that is really wrong.
        static func readPrivateKey(_ pem: String) throws -> P256.Signing.PrivateKey {
            let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
            if let key = try? P256.Signing.PrivateKey(pemRepresentation: trimmed) { return key }
            let swapped = trimmed.contains("BEGIN EC PRIVATE KEY")
                ? trimmed.replacingOccurrences(of: "BEGIN EC PRIVATE KEY", with: "BEGIN PRIVATE KEY")
                    .replacingOccurrences(of: "END EC PRIVATE KEY", with: "END PRIVATE KEY")
                : trimmed.replacingOccurrences(of: "BEGIN PRIVATE KEY", with: "BEGIN EC PRIVATE KEY")
                    .replacingOccurrences(of: "END PRIVATE KEY", with: "END EC PRIVATE KEY")
            return try P256.Signing.PrivateKey(pemRepresentation: swapped)
        }

        private static func base64URL(json object: [String: Any]) throws -> String {
            base64URL(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        }

        private static func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
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
}
