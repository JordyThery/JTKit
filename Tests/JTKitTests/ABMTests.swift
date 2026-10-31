import CryptoKit
import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

// Apple Business and Apple School Manager: the private-key
// sign-in, the client with Apple’s limit, paging, errors, records, the
// writes with their confirmations and outcomes, and that the private key,
// the signed sign-in request and the token never reach the activity log,
// either export or a message. Every test has its own fake Apple, key, clock
// and log; no real network.

// MARK: - Fixtures

/// Time that moves only when the client waits.
final class VirtualTime: @unchecked Sendable {
    private let state = Locked((now: Date(timeIntervalSince1970: 1_790_000_000), waits: [Double]()))
    var now: Date { state.value.now }
    var waits: [Double] { state.value.waits }

    func advance(_ seconds: Double) { state.withLock { $0.now += seconds } }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        state.withLock { $0.waits.append(duration.seconds); $0.now += duration.seconds }
    }
}

enum Apple {
    static let tokenPath = "/auth/oauth2/v2/token"
    static let token = "SECRET-apple-token-0123456789"

    static func device(_ serial: String, extra: String = "") -> String {
        #"{"serialNumber":"\#(serial)","deviceModel":"MacBook Air","productFamily":"Mac","status":"ASSIGNED"\#(extra)}"#
    }

    static func error(_ status: Int, code: String? = nil, title: String? = nil, detail: String? = nil, id: String? = nil) -> MockResponse {
        var item = [#""status":"\#(status)""#]
        if let id { item.append(#""id":"\#(id)""#) }
        if let code { item.append(#""code":"\#(code)""#) }
        if let title { item.append(#""title":"\#(title)""#) }
        if let detail { item.append(#""detail":"\#(detail)""#) }
        return .json(status, #"{"errors":[{\#(item.joined(separator: ","))}]}"#)
    }

    static func form(_ request: RecordedRequest) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = request.bodyString
        return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { $1 }
    }

    static func decoded(_ part: Substring) -> Data? {
        var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }

    static func json(_ data: Data?) -> [String: Any] {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// A fake Apple: `route` first, then the token, then 404.
    static func server(_ route: @escaping @Sendable (RecordedRequest) -> MockResponse? = { _ in nil }) -> MockServer {
        MockServer { request in
            if let answer = route(request) { return answer }
            if request.path == tokenPath { return .json(200, tokenJSON(token, expiresIn: 3600)) }
            return error(404, code: "NOT_FOUND", title: "Not Found")
        }
    }
}

/// One client on a fake Apple, with its own key, time and log.
@MainActor
struct AppleRig {
    let server: MockServer
    let key = P256.Signing.PrivateKey()
    let pem: String
    let time = VirtualTime()
    let log = ActivityLog()
    let tokens: ABM.TokenProvider
    let client: ABM.Client

    init(_ server: MockServer = Apple.server(), service: ABM.Service = .business, pem: String? = nil,
         hints: [String] = []) {
        self.server = server
        self.pem = pem ?? key.pemRepresentation
        let recorder = ABM.recorder(service, session: server.session, log: log, connection: "Lab Org")
        let time = time
        let pemText = self.pem
        tokens = ABM.TokenProvider(service: service, clientID: "BUSINESSAPI.abc", keyID: "key-1",
                                   privateKey: { pemText }, recorder: recorder, now: { time.now })
        client = ABM.Client(service: service, tokens: tokens, recorder: recorder, hints: hints,
                            sleep: { try await time.sleep($0) }, random: { 0 }, now: { time.now })
    }

    var signIns: [RecordedRequest] { server.requests.filter { $0.path == Apple.tokenPath } }
    var api: [RecordedRequest] { server.requests.filter { $0.path != Apple.tokenPath } }
}

@MainActor
func appleError(_ body: () async throws -> Void) async -> ABM.APIError? {
    do {
        try await body()
        Issue.record("Expected an ABM.APIError")
    } catch let error as ABM.APIError {
        return error
    } catch {
        Issue.record("Expected an ABM.APIError, got \(error)")
    }
    return nil
}

// MARK: - Redaction

@Suite("Redaction: private keys, signed tokens, known secrets")
struct ABMRedactionTests {

    @Test("A PEM private key is hidden, whole, cut short or with JSON’s \\n")
    func pem() {
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let body = pem.split(separator: "\n")[1]
        #expect(!Redaction.text("key: \(pem) end").contains(body))
        #expect(Redaction.text("key: \(pem) end").hasSuffix(" end"))
        #expect(!Redaction.text(String(pem.prefix(80))).contains(body.prefix(20)))
        let escaped = pem.replacingOccurrences(of: "\n", with: "\\n")
        #expect(!Redaction.text(#"{"note":"\#(escaped)"}"#).contains(body))
        #expect(!Redaction.text(pem.replacingOccurrences(of: "PRIVATE KEY", with: "EC PRIVATE KEY")).contains(body))
    }

    @Test("A signed token is hidden by its eyJ start, also its remains; ordinary text isn’t")
    func jwt() {
        let jwt = "eyJhbGciOiJFUzI1NiJ9.eyJpc3MiOiJCVVNJTkVTU0FQSS5hYmMifQ.MEUCIQDx_sig-part"
        #expect(Redaction.text("Assertion \(jwt) is not valid") == "Assertion <redacted> is not valid")
        #expect(Redaction.text("left: eyJpc3MiOiJCVVNJTkVTU0FQSS5hYmMifQ.MEUCIQDx") == "left: <redacted>")
        for ordinary in ["They eye the eyJ.", "EYJABCDEFGHIJKLM", "eyjabcdefghijklmnop", "keyJabcdefghijklmnop", "Eye drops"] {
            #expect(Redaction.text(ordinary) == ordinary)
        }
    }

    @Test("Apple’s signed download address: the signature, and the address in JSON")
    func downloadURL() {
        let url = URL(string: "https://store.blobstore.apple.com/a/b?response-content-type=application%2Foctet-stream&Expires=1746123820&Signature=wrYW2gn7UZDM9aO3KOMqT8YWCBo%3D")!
        #expect(!Redaction.url(url).contains("wrYW2gn7"))
        #expect(Redaction.url(url).contains("Expires=1746123820"))
        let body = Data(#"{"data":{"attributes":{"status":"COMPLETED","downloadUrl":"\#(url.absoluteString)"}}}"#.utf8)
        #expect(Redaction.body(body)?.contains("wrYW2gn7") == false)
        #expect(Redaction.body(body)?.contains("COMPLETED") == true)
    }

    @Test("Known secrets go wherever they are, also percent-encoded; short ones are ignored")
    func knownSecrets() {
        let secret = "abc+def/ghi=jkl"
        #expect(Redaction.removing([secret], from: "x \(secret) y") == "x <redacted> y")
        #expect(Redaction.removing([secret], from: "x=\(FormEncoding.encode(secret))") == "x=<redacted>")
        #expect(Redaction.removing(["short"], from: "a short word") == "a short word")
        #expect(Redaction.removing(["0123456789", "0123456789ABCDEF"], from: "0123456789ABCDEF") == "<redacted>")
    }

    @Test("Apple’s sign-in is a sensitive call; the API isn’t")
    func sensitive() {
        #expect(SensitiveRequests.isSensitive(path: "/auth/oauth2/v2/token"))
        #expect(!SensitiveRequests.isSensitive(path: "/v1/orgDevices/C02XK1JHJG5H"))
    }
}

// MARK: - The HTTP client’s new options

@Suite("HTTP client: rate limit, fixed waits, known token")
@MainActor
struct HTTPClientLimitTests {

    func client(_ server: MockServer, time: VirtualTime, log: ActivityLog, rules: RetryRules = .appleBusiness,
                tokens: any BearerTokenSource = FixedToken("SECRET-token-0123456789")) -> HTTPClient {
        HTTPClient(baseURL: URL(string: "https://api.example.com")!, tokens: tokens,
                   recorder: RequestRecorder(session: server.session, log: log),
                   rateLimit: RateLimit(requests: 3, per: 60, explanation: "The service allows 3 a minute"), rules: rules,
                   sleep: { try await time.sleep($0) }, random: { 0 }, now: { time.now })
    }

    @Test("Within the window requests go at once; past it they wait, written to the log")
    func window() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let time = VirtualTime()
        let log = ActivityLog()
        let http = client(server, time: time, log: log)
        for _ in 0..<3 { _ = try await http.send(HTTPRequest(path: "a")) }
        #expect(time.waits.isEmpty)
        time.advance(20)
        _ = try await http.send(HTTPRequest(path: "a"))
        #expect(time.waits.count == 1)
        #expect(abs(time.waits[0] - 40.1) < 0.001)
        let note = try #require(log.entries.first { $0.category == "Retry" })
        #expect(note.note == "The service allows 3 a minute: waiting 41 s.")
        #expect(note.isWarning)
    }

    @Test("Apple’s sign-in takes one of the requests in the window")
    func signInCounts() async throws {
        let server = Apple.server { $0.path == Apple.tokenPath ? nil : .json(200, "{}") }
        let time = VirtualTime()
        let log = ActivityLog()
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let tokens = ABM.TokenProvider(service: .business, clientID: "BUSINESSAPI.abc", keyID: "key-1",
                                       privateKey: { pem }, recorder: RequestRecorder(session: server.session, log: log),
                                       now: { time.now })
        let http = client(server, time: time, log: log, tokens: tokens)
        for _ in 0..<2 { _ = try await http.send(HTTPRequest(path: "a")) }
        #expect(time.waits.isEmpty, "the sign-in and two requests: 3 in the window")
        _ = try await http.send(HTTPRequest(path: "a"))
        #expect(time.waits.count == 1)
        #expect(server.requests.filter { $0.path == Apple.tokenPath }.count == 1)
    }

    @Test("Every attempt counts, retries included")
    func retriesCount() async throws {
        let calls = Counter()
        let server = MockServer { _ in calls.next() <= 3 ? MockResponse(status: 429, body: Data()) : .json(200, "{}") }
        let time = VirtualTime()
        _ = try await client(server, time: time, log: ActivityLog()).send(HTTPRequest(path: "a"))
        // attempts at 0, 5, 20 fill the window; the fourth, at 65 s, finds
        // the first two gone, so only the fixed waits
        #expect(time.waits == [5, 15, 45])
        #expect(server.requests.count == 4)
    }

    @Test("Cancel stops a wait for the window")
    func cancel() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let log = ActivityLog()
        let http = HTTPClient(baseURL: URL(string: "https://api.example.com")!, tokens: nil,
                              recorder: RequestRecorder(session: server.session, log: log),
                              rateLimit: RateLimit(requests: 1, per: 60, explanation: "One a minute"),
                              sleep: { try await Task.sleep(for: $0) })
        _ = try await http.send(HTTPRequest(path: "a"))
        let task = Task { try await http.send(HTTPRequest(path: "a")) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(server.requests.count == 1)
        #expect(log.entries.contains { $0.note == "Canceled while waiting." })
    }

    @Test("Fixed waits: 5, 15, 45, then 45; Retry-After still comes first")
    func fixedWaits() {
        let rules = RetryRules.appleBusiness
        #expect((1...4).map { rules.backoff(afterAttempt: $0, random: 1) } == [5, 15, 45, 45])
        #expect(RetryRules.standard.backoff(afterAttempt: 2, random: 0) == 2)
    }

    @Test("With every network error a drop, a read tries again after any of them; a write doesn’t")
    func everyNetworkError() async throws {
        let server = MockServer { _ in throw URLError(.secureConnectionFailed) }
        let time = VirtualTime()
        let http = client(server, time: time, log: ActivityLog())
        _ = try? await http.send(HTTPRequest(path: "a"))
        #expect(server.requests.count == 4)
        _ = try? await http.send(HTTPRequest(method: "POST", path: "a", body: Data("{}".utf8)))
        #expect(server.requests.count == 5)
        let standard = MockServer { _ in throw URLError(.secureConnectionFailed) }
        _ = try? await client(standard, time: VirtualTime(), log: ActivityLog(), rules: .standard).send(HTTPRequest(path: "a"))
        #expect(standard.requests.count == 1)
    }

    @Test("A token repeated in an error answer is taken out of the error and the log")
    func tokenInAnswer() async throws {
        let server = MockServer { _ in .json(400, #"{"message":"token SECRET-token-0123456789 rejected"}"#) }
        let log = ActivityLog()
        do {
            _ = try await client(server, time: VirtualTime(), log: log).send(HTTPRequest(path: "a"))
            Issue.record("expected an error")
        } catch let error as HTTPError {
            #expect(!(error.errorDescription ?? "").contains("SECRET-token"))
            if case let .status(response, _, _, _) = error {
                #expect(!String(decoding: response.data, as: UTF8.self).contains("SECRET-token"))
            }
        }
        #expect(!ActivityLogExport.text(log.entries, masked: false).contains("SECRET-token"))
    }

    @Test("A server error can be the answer: returned at once, not retried")
    func serverErrorIsAnAnswer() async throws {
        let server = MockServer { _ in .json(500, "{}") }
        let response = try await client(server, time: VirtualTime(), log: ActivityLog())
            .send(HTTPRequest(path: "a", serverErrorIsAnAnswer: true))
        #expect(response.status == 500)
        #expect(server.requests.count == 1)
    }
}

// MARK: - Sign-in

@Suite("Apple: the private-key sign-in")
@MainActor
struct ABMSignInTests {

    @Test("Test Connection counts the MDM servers")
    func testConnection() async throws {
        let rig = AppleRig(Apple.server {
            $0.path == "/v1/mdmServers" ? .json(200, #"{"data":[{"id":"S1","type":"mdmServers"},{"id":"S2","type":"mdmServers"}]}"#) : nil
        }, service: .business)
        #expect(try await rig.client.testConnection() == 2)
    }

    @Test("The token request: address, form fields and scope", arguments: ABM.Service.allCases)
    func tokenRequest(service: ABM.Service) async throws {
        let rig = AppleRig(Apple.server { $0.path == "/v1/mdmServers" ? .json(200, #"{"data":[]}"#) : nil }, service: service)
        _ = try await rig.client.mdmServers()
        let signIn = try #require(rig.signIns.first)
        #expect(signIn.url.absoluteString == "https://account.apple.com/auth/oauth2/v2/token")
        #expect(signIn.method == "POST")
        let form = Apple.form(signIn)
        #expect(Set(form.keys) == ["grant_type", "client_id", "client_assertion_type", "client_assertion", "scope"])
        #expect(form["grant_type"] == "client_credentials")
        #expect(form["client_id"] == "BUSINESSAPI.abc")
        #expect(form["client_assertion_type"] == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer")
        #expect(form["scope"] == service.scope)
        let api = try #require(rig.api.first)
        #expect(api.url.host() == service.host)
        #expect(api.header("Authorization") == "Bearer \(Apple.token)")
    }

    @Test("The signed request: header, claims, 20 minutes, and a signature the public key accepts")
    func assertion() throws {
        let key = P256.Signing.PrivateKey()
        let issued = Date(timeIntervalSince1970: 1_790_000_000)
        let assertion = try ABM.TokenProvider.clientAssertion(clientID: "C", keyID: "K", privateKey: key.pemRepresentation,
                                                              service: .business, issuedAt: issued, id: "J")
        let parts = assertion.split(separator: ".")
        try #require(parts.count == 3)
        #expect(parts[0].hasPrefix("eyJ"))
        let header = Apple.json(Apple.decoded(parts[0]))
        #expect(header as NSDictionary == ["alg": "ES256", "kid": "K", "typ": "JWT"])
        let claims = Apple.json(Apple.decoded(parts[1]))
        #expect(claims as NSDictionary == ["iss": "C", "sub": "C", "aud": "https://account.apple.com/auth/oauth2/v2/token",
                                           "iat": 1_790_000_000, "exp": 1_790_001_200, "jti": "J"])
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: #require(Apple.decoded(parts[2])))
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test("A PKCS#8 key labeled EC PRIVATE KEY (Apple School Manager’s files) is read")
    func schoolLabel() throws {
        let key = P256.Signing.PrivateKey()
        let relabelled = key.pemRepresentation.replacingOccurrences(of: "PRIVATE KEY", with: "EC PRIVATE KEY")
        #expect(try ABM.TokenProvider.readPrivateKey(relabelled).rawRepresentation == key.rawRepresentation)
    }

    @Test("A key that can’t be read: the standard message, nothing sent, no key in it")
    func unreadableKey() async {
        let pem = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgAAAAAAAAAAAAAAAA\n-----END PRIVATE KEY-----"
        let rig = AppleRig(pem: pem)
        let error = await appleError { _ = try await rig.client.mdmServers() }
        guard case .unreadableKey = error?.kind else { Issue.record("not unreadableKey"); return }
        let message = error?.message() ?? ""
        #expect(message.hasPrefix("The file doesn’t contain a private key. Choose the .pem file downloaded when the API account was created."))
        #expect(!message.contains("MIGHAgEA"))
        #expect(rig.server.requests.isEmpty)
    }

    @Test("Five requests at once share one sign-in; the token is renewed 60 s before it runs out")
    func sharedAndRenewed() async throws {
        let rig = AppleRig(Apple.server { $0.path == "/v1/mdmServers" ? .json(200, #"{"data":[]}"#) : nil })
        let client = rig.client
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = try? await client.mdmServers() } }
        }
        #expect(rig.signIns.count == 1)
        rig.time.advance(3600 - 61)
        _ = try await client.mdmServers()
        #expect(rig.signIns.count == 1)
        rig.time.advance(2)
        _ = try await client.mdmServers()
        #expect(rig.signIns.count == 2)
        // each sign-in signs a new request
        let assertions = rig.signIns.compactMap { Apple.form($0)["client_assertion"] }
        #expect(Set(assertions).count == 2)
    }

    @Test("A 401 gets a new token and one more try")
    func renewAfter401() async throws {
        let calls = Counter()
        let rig = AppleRig(Apple.server { request in
            request.path == "/v1/mdmServers" ? (calls.next() == 1 ? Apple.error(401) : .json(200, #"{"data":[]}"#)) : nil
        })
        _ = try await rig.client.mdmServers()
        #expect(rig.signIns.count == 2)
        #expect(rig.api.count == 2)
    }

    @Test("A refused sign-in shows Apple’s error and description, never the rest of its answer")
    func refused() async {
        let rig = AppleRig(Apple.server { request in
            request.path == Apple.tokenPath
                ? .json(400, #"{"error":"invalid_client","error_description":"Client authentication failed","extra":"SECRET-other"}"#) : nil
        })
        let error = await appleError { _ = try await rig.client.mdmServers() }
        #expect(error?.message() == """
            Sign-in failed: HTTP 400 Bad Request
            invalid_client: Client authentication failed
            Check the client ID and the key ID, and that the private key is the .pem file downloaded when the API account was created in Apple Business. A revoked key can’t sign in; create a new one there.
            """)
        #expect(rig.api.isEmpty)
        // only method, path, status and duration are recorded
        let entry = rig.log.entries.first { $0.category == "Sign-in" }
        #expect(entry?.request?.contentsWithheld == true)
        #expect(entry?.request?.responseBody == nil)
    }

    @Test("An answer that isn’t JSON shows only the status")
    func refusedPlain() async {
        let rig = AppleRig(Apple.server { $0.path == Apple.tokenPath ? MockResponse(status: 400, headers: [:], body: Data("SECRET-text".utf8)) : nil })
        let error = await appleError { _ = try await rig.client.mdmServers() }
        #expect(error?.message().hasPrefix("Sign-in failed: HTTP 400 Bad Request\nCheck the client ID") == true)
    }
}

// MARK: - The key, the signed request and the token stay inside

@Suite("Apple: nothing secret leaves the client")
@MainActor
struct ABMSecretTests {

    /// How a fake Apple answers, each time repeating what it got.
    enum Echo: String, CaseIterable, Sendable {
        case formInDescription, bareAssertion, plainText, brokenSuccess, tokenInAPIError, tokenInPlainError, pemEcho

        func answer(_ request: RecordedRequest, pem: String) -> MockResponse? {
            let form = request.bodyString
            let assertion = Apple.form(request)["client_assertion"] ?? ""
            let isSignIn = request.path == Apple.tokenPath
            let escapedPEM = pem.replacingOccurrences(of: "\n", with: "\\n")
            switch self {
            case .formInDescription:
                return isSignIn ? .json(400, #"{"error":"invalid_client","error_description":"received \#(form)"}"#) : nil
            case .bareAssertion:
                return isSignIn ? .json(400, #"{"error":"invalid_client","error_description":"Assertion \#(assertion) is not valid"}"#) : nil
            case .plainText:
                return isSignIn ? MockResponse(status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad request: \(form) \(assertion)".utf8)) : nil
            case .brokenSuccess:
                return isSignIn ? MockResponse(status: 200, headers: ["Content-Type": "text/plain"], body: Data("ok \(assertion)".utf8)) : nil
            case .tokenInAPIError:
                return isSignIn ? nil : Apple.error(401, title: "Unauthorized", detail: "Token \(Apple.token) rejected")
            case .tokenInPlainError:
                return isSignIn ? nil : MockResponse(status: 403, headers: ["Content-Type": "text/plain"], body: Data("no: \(Apple.token)".utf8))
            case .pemEcho:
                return isSignIn ? .json(400, #"{"error":"invalid_client","error_description":"\#(escapedPEM)"}"#) : nil
            }
        }
    }

    static func pieces(pem: String, assertion: String?) -> [String] {
        let body = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        var pieces = [pem, body] + stride(from: 0, to: max(body.count - 20, 1), by: 10).map { String(body.dropFirst($0).prefix(20)) }
        if let assertion {
            pieces.append(assertion)
            pieces += assertion.split(separator: ".").dropFirst().map(String.init)
        }
        return pieces.filter { !$0.isEmpty } + [Apple.token]
    }

    static func everything(_ log: ActivityLog, _ messages: [String?]) -> String {
        let fields: [String?] = log.entries.flatMap { entry -> [String?] in
            [entry.operation, entry.detail, entry.note, entry.request?.url, entry.request?.requestBody, entry.request?.responseBody,
             entry.request?.error, entry.request?.bodyNote]
                + (entry.request?.requestHeaders ?? []).map(\.value) + (entry.request?.responseHeaders ?? []).map(\.value)
        }
        let exports: [String?] = [ActivityLogExport.text(log.entries, masked: false), ActivityLogExport.text(log.entries, masked: true)]
        return (fields + messages + exports).compactMap { $0 }.joined(separator: "\n")
    }

    @Test("Not in the log, either export, the message or the bug report", arguments: Echo.allCases)
    func nothingLeaks(echo: Echo) async throws {
        let holder = Locked("")
        let rig = AppleRig(Apple.server { echo.answer($0, pem: holder.value) })
        holder.value = rig.pem
        var shown: [String?] = []
        do {
            _ = try await rig.client.mdmServers()
        } catch let error as ABM.APIError {
            shown = [error.message(), error.report, error.localizedDescription]
        } catch {
            shown = [error.localizedDescription]
        }
        let assertion = rig.signIns.first.flatMap { Apple.form($0)["client_assertion"] }
        #expect(assertion != nil)
        let text = Self.everything(rig.log, shown)
        for piece in Self.pieces(pem: rig.pem, assertion: assertion) {
            #expect(!text.contains(piece), "\(echo): found \(piece.prefix(24))…")
        }
    }
}

// MARK: - Reads

@Suite("Apple: reads")
@MainActor
struct ABMReadTests {

    @Test("A device: tolerant record; 404 isn’t in the organization; the serial is checked and uppercased")
    func device() async throws {
        let extra = #","imei":"35-1","meid":["A1"],"isMdmMigrationCapable":true,"mdmMigrationStatus":"STARTED","mdmMigrationDeadlineDateTime":"2026-11-02T10:00:00.000Z","newField":{"x":1}"#
        let rig = AppleRig(Apple.server { request in
            request.path == "/v1/orgDevices/C02XK1JHJG5H"
                ? .json(200, #"{"data":{"id":"C02XK1JHJG5H","attributes":\#(Apple.device("C02XK1JHJG5H", extra: extra))}}"#) : nil
        })
        let device = try #require(try await rig.client.device(serial: " c02xk1jhjg5h "))
        #expect(device.imei == ["35-1"])
        #expect(device.meid == ["A1"])
        #expect(device.hasActiveMigration)
        #expect(device.migrationDeadline == ABM.date("2026-11-02T10:00:00Z"))
        #expect(rig.api.first?.header("Accept") == "application/json")
        #expect(try await rig.client.device(serial: "UNKNOWN1") == nil)
        let refused = await appleError { _ = try await rig.client.device(serial: "C02/../X") }
        #expect(refused?.message() == "“C02/../X” isn’t a serial number: it may hold only letters and digits.")
        #expect(rig.api.count == 2)
        // a device lookup’s answer is recorded
        #expect(rig.log.entries.contains { $0.request?.responseBody?.contains("MacBook Air") == true })
    }

    @Test("AppleCare coverage: active, expired; 404 is none")
    func coverage() async throws {
        let rig = AppleRig(Apple.server { request in
            request.path == "/v1/orgDevices/A1/appleCareCoverage" ? .json(200, #"""
                {"data":[{"id":"A","attributes":{"description":"AppleCare+","status":"ACTIVE","endDateTime":"2099-01-01T00:00:00Z"}},
                         {"id":"B","attributes":{"status":"INACTIVE","endDateTime":"2001-01-01T00:00:00Z"}},
                         {"id":"C","attributes":{"status":"INACTIVE","endDateTime":"2099-01-01T00:00:00Z"}}]}
                """#) : nil
        })
        let coverage = try await rig.client.appleCareCoverage(serial: "A1")
        #expect(coverage.map(\.isActive) == [true, false, false])
        #expect(coverage.map { $0.hasExpired(now: Date(timeIntervalSince1970: 1_790_000_000)) } == [false, true, false])
        #expect(try await rig.client.appleCareCoverage(serial: "B1").isEmpty)
    }

    @Test("Activation Lock: Apple’s documented server error is no answer, not retried")
    func activationLock() async throws {
        let rig = AppleRig(Apple.server { request in
            switch request.path {
            case "/v1/orgDevices/LOCKED/activationLockStatus": .json(200, #"{"data":{"attributes":{"isLocked":true,"lockType":"MDM"}}}"#)
            case "/v1/orgDevices/QUIRK/activationLockStatus": Apple.error(500)
            default: nil
            }
        })
        #expect(try await rig.client.activationLock(serial: "LOCKED") == ABM.ActivationLock(isLocked: true, lockType: "MDM"))
        #expect(try await rig.client.activationLock(serial: "QUIRK") == nil)
        #expect(try await rig.client.activationLock(serial: "NONE") == nil)
        #expect(rig.api.filter { $0.path.contains("QUIRK") }.count == 1)
        #expect(rig.time.waits.isEmpty)
    }

    @Test("Assigned server: ID, none, unknown device")
    func assignedServer() async throws {
        let rig = AppleRig(Apple.server { request in
            switch request.path {
            case "/v1/orgDevices/A/relationships/assignedServer": .json(200, #"{"data":{"type":"mdmServers","id":"S1"}}"#)
            case "/v1/orgDevices/B/relationships/assignedServer": .json(200, #"{"data":null}"#)
            default: nil
            }
        })
        #expect(try await rig.client.assignedServerID(serial: "A") == "S1")
        #expect(try await rig.client.assignedServerID(serial: "B") == nil)
        #expect(try await rig.client.assignedServerID(serial: "C") == nil)
    }

    @Test("Paging: every page on Apple’s address; another host is refused, nothing sent there")
    func paging() async throws {
        let rig = AppleRig(Apple.server { request in
            guard request.path == "/v1/mdmServers" else { return nil }
            switch request.queryValue("cursor") {
            case nil: return .json(200, #"{"data":[{"id":"S1","attributes":{"serverName":"Jamf Pro"}}],"links":{"next":"https://api-business.apple.com/v1/mdmServers?limit=100&cursor=2"}}"#)
            case "2": return .json(200, #"{"data":[{"id":"S2","attributes":{"serverType":"APPLE_MDM"}}],"links":{"next":"https://elsewhere.example/v1/mdmServers?cursor=3"}}"#)
            default: return nil
            }
        })
        let error = await appleError { _ = try await rig.client.mdmServers() }
        guard case .nextPageElsewhere("elsewhere.example") = error?.kind else { Issue.record("not refused"); return }
        #expect(!rig.server.requests.contains { $0.url.host() == "elsewhere.example" })
        #expect(rig.api.count == 2)
    }

    @Test("Paging: 1,000 pages is an error; an answer without data is an error")
    func pageLimit() async throws {
        let rig = AppleRig(Apple.server { request in
            guard request.path == "/v1/mdmServers" else { return request.path == "/v1/mdmDevices" ? .json(200, "{}") : nil }
            let page = Int(request.queryValue("cursor") ?? "0") ?? 0
            return .json(200, #"{"data":[],"links":{"next":"https://api-business.apple.com/v1/mdmServers?cursor=\#(page + 1)"}}"#)
        })
        let error = await appleError { _ = try await rig.client.mdmServers() }
        guard case .pageLimitReached(_, 1_000) = error?.kind else { Issue.record("no page limit"); return }
        let noData = await appleError { _ = try await rig.client.appleManagedDevices() }
        guard case .invalidResponse = noData?.kind else { Issue.record("no data accepted"); return }
    }

    @Test("Snapshot: devices, assignments, and a server that can’t be read gives unknown assignments")
    func snapshot() async throws {
        let rig = AppleRig(Apple.server { request in
            switch request.path {
            case "/v1/orgDevices":
                return .json(200, #"{"data":[{"attributes":\#(Apple.device("c02aaa"))},{"attributes":\#(Apple.device("B2"))},{"attributes":{"status":"ASSIGNED"}},{"attributes":{"serialNumber":"C3","status":"UNASSIGNED"}}]}"#)
            case "/v1/mdmServers":
                return .json(200, #"{"data":[{"id":"S1","attributes":{"serverName":"Jamf Pro"}},{"id":"S2","attributes":{"serverName":"Locked"}}]}"#)
            case "/v1/mdmServers/S1/relationships/devices":
                return .json(200, #"{"data":[{"type":"orgDevices","id":"C02AAA"}]}"#)
            case "/v1/mdmServers/S2/relationships/devices":
                return Apple.error(403, title: "Forbidden")
            default:
                return nil
            }
        })
        let progress = Locked<[String]>([])
        let snapshot = try await rig.client.organizationSnapshot { item in progress.withLock { $0.append(item.description) } }
        #expect(Set(snapshot.devices.keys) == ["C02AAA", "B2", "C3"])
        #expect(snapshot.serverIDBySerial == ["C02AAA": "S1"])
        #expect(snapshot.unreadableServers.map(\.id) == ["S2"])
        #expect(snapshot.unknownAssignments == ["B2"])
        #expect(progress.value == ["Reading devices… 3", "Reading assignments… 0 of 2 services", "Reading assignments… 1 of 2 services"])
        let fields = try #require(rig.api.first?.queryValue("fields[orgDevices]")).split(separator: ",")
        #expect(fields.count == 23)
        let warning = try #require(rig.log.entries.first { $0.isWarning && $0.note?.contains("Locked") == true })
        #expect(warning.note == "Couldn’t read the devices of “Locked” (HTTP 403); devices that may be on it show an unknown assignment.")
    }

    @Test("First devices: one request with the limit, no next page, records without a serial left out")
    func firstDevices() async throws {
        let rig = AppleRig(Apple.server { request in
            request.path == "/v1/orgDevices"
                ? .json(200, #"{"data":[{"attributes":\#(Apple.device("C1"))},{"attributes":{"status":"ASSIGNED"}},{"attributes":\#(Apple.device("C2"))}],"links":{"next":"https://api-business.apple.com/v1/orgDevices?cursor=2"}}"#)
                : nil
        })
        let devices = try await rig.client.firstDevices(limit: 5)
        #expect(devices.map(\.serialNumber) == ["C1", "C2"])
        #expect(rig.api.count == 1)
        #expect(rig.api.first?.queryValue("limit") == "5")
        #expect(rig.api.first?.queryValue("cursor") == nil)
    }

    @Test("Snapshot: no answer at all fails the read")
    func snapshotFails() async {
        let rig = AppleRig(MockServer { request in
            if request.path == Apple.tokenPath { return .json(200, tokenJSON(Apple.token, expiresIn: 3600)) }
            throw URLError(.networkConnectionLost)
        })
        let error = await appleError { _ = try await rig.client.organizationSnapshot() }
        #expect(error?.message().contains("Apple allows about 20 requests a minute for each organization.") == true)
        #expect(rig.time.waits == [5, 15, 45])
    }

    @Test("History: strict query, cursor, newest first")
    func history() async throws {
        let rig = AppleRig(Apple.server { request in
            request.path == "/v1/auditEvents" ? .json(200, #"""
                {"data":[{"id":"1","attributes":{"eventDateTime":"2026-01-01T00:00:00Z","type":"DEVICE_ADDED_TO_ORG","eventDataPropertyKey":"a","a":{"purchaseSourceType":"RESELLER"}}},
                         {"id":"2","attributes":{"eventDateTime":"2026-03-01T00:00:00Z","type":"DEVICE_UNASSIGNED_FROM_SERVER","outcome":"FAILURE","eventDataPropertyKey":"u","u":{"serverName":"Old"}}}],
                 "meta":{"paging":{"nextCursor":"n+1"}}}
                """#) : nil
        })
        let page = try await rig.client.auditEvents(serial: "c02", start: Date(timeIntervalSince1970: 1_700_000_000),
                                                    end: Date(timeIntervalSince1970: 1_800_000_000), cursor: "a+b&c")
        #expect(page.events.map(\.id) == ["2", "1"])
        #expect(page.events[0].sourceServerName == "Old")
        #expect(page.events[0].isFailure)
        #expect(page.events[1].purchaseSourceType == "RESELLER")
        #expect(page.nextCursor == "n+1")
        let request = try #require(rig.api.first)
        #expect(request.queryValue("filter[subjectId]") == "C02")
        #expect(request.queryValue("cursor") == "a+b&c")
        #expect(request.queryValue("filter[startTimestamp]") == "2023-11-14T22:13:20Z")
    }
}

// MARK: - Limit, retries, errors

@Suite("Apple: limit, retries and errors")
@MainActor
struct ABMRetryTests {

    @Test("Eighteen requests a minute, the sign-in included; the next one waits, written to the log")
    func limit() async throws {
        let rig = AppleRig(Apple.server { $0.path == "/v1/mdmServers" ? .json(200, #"{"data":[]}"#) : nil })
        for _ in 0..<17 { _ = try await rig.client.mdmServers() }
        #expect(rig.time.waits.isEmpty)
        _ = try await rig.client.mdmServers()
        #expect(rig.time.waits.count == 1)
        #expect(rig.log.entries.contains { $0.note == "Apple allows about 20 requests a minute for each organization: waiting 61 s." })
    }

    @Test("429 is retried for reads and writes, at 5, 15 and 45 s", arguments: ["GET", "POST"])
    func busy(method: String) async throws {
        let rig = AppleRig(Apple.server { $0.path == Apple.tokenPath ? nil : MockResponse(status: 429, body: Data()) })
        let error = await appleError {
            if method == "GET" { _ = try await rig.client.mdmServers() }
            else { _ = try await rig.client.submit(try ABM.Activity(.release, serials: ["A"])) }
        }
        #expect(rig.api.count == 4)
        #expect(rig.time.waits == [5, 15, 45])
        #expect(error?.message() == "HTTP 429 Client Error\nApple allows about 20 requests a minute for each organization. Wait a minute, then try again.")
    }

    @Test("A write isn’t repeated after a server error or a dropped connection; a read is")
    func writesNotRepeated() async throws {
        let rig = AppleRig(Apple.server { $0.path == Apple.tokenPath ? nil : Apple.error(503) })
        _ = await appleError { _ = try await rig.client.submit(try ABM.Activity(.release, serials: ["A"])) }
        #expect(rig.api.count == 1)
        _ = await appleError { _ = try await rig.client.mdmServers() }
        #expect(rig.api.count == 5)
        let dropped = AppleRig(MockServer { request in
            if request.path == Apple.tokenPath { return .json(200, tokenJSON(Apple.token, expiresIn: 3600)) }
            throw URLError(.networkConnectionLost)
        })
        _ = await appleError { _ = try await dropped.client.submit(try ABM.Activity(.assign, serials: ["A"], serverID: "S1")) }
        #expect(dropped.api.count == 1)
    }

    @Test("The error format: status line, CODE: title — detail, Error ID, app hints, standard hints")
    func format() async {
        let rig = AppleRig(Apple.server { $0.path == "/v1/mdmServers"
            ? Apple.error(403, code: "FORBIDDEN", title: "Forbidden", detail: "The API account lacks access.", id: "d41f0ce2") : nil },
                           hints: ["Checkpoint's own hint."])
        let error = await appleError { _ = try await rig.client.mdmServers() }
        #expect(error?.message() == """
            HTTP 403 Forbidden
            FORBIDDEN: Forbidden — The API account lacks access.
            Error ID: d41f0ce2
            Checkpoint's own hint.
            The API account isn’t allowed to do this. Check its access in Apple Business.
            """)
        #expect(error?.report.hasPrefix("Request: GET v1/mdmServers\n") == true)
    }
}

// MARK: - Writes

@Suite("Apple: writes, confirmations and outcomes")
@MainActor
struct ABMActivityTests {

    @Test("Bodies: server and deadline where Apple needs them")
    func bodies() throws {
        let deadline = Date(timeIntervalSince1970: 1_790_000_000)
        let now = deadline.addingTimeInterval(-7 * 24 * 3600)
        func body(_ activity: ABM.Activity) throws -> NSDictionary {
            try JSONSerialization.jsonObject(with: activity.body(for: .business, now: now)) as? NSDictionary ?? [:]
        }
        let assign = try body(ABM.Activity(.assign, serials: ["a1", "B2"], serverID: "S1"))
        #expect(assign == ["data": ["type": "orgDeviceActivities", "attributes": ["activityType": "ASSIGN_DEVICES"],
                                    "relationships": ["devices": ["data": [["type": "orgDevices", "id": "A1"], ["type": "orgDevices", "id": "B2"]]],
                                                      "mdmServer": ["data": ["type": "mdmServers", "id": "S1"]]]]])
        let migrate = try body(ABM.Activity(.assignWithMigrationDeadline, serials: ["A1"], serverID: "S2", deadline: deadline))
        let attributes = (migrate["data"] as? NSDictionary)?["attributes"] as? NSDictionary
        #expect(attributes == ["activityType": "ASSIGN_DEVICES_WITH_MDM_MIGRATION_DEADLINE",
                               "activityTypeMetadata": ["mdmMigrationDeadlineDateTime": "2026-09-21T14:13:20.000Z"]])
        let cancel = try body(ABM.Activity(.cancelMigration, serials: ["A1"], serverID: "ignored"))
        #expect(((cancel["data"] as? NSDictionary)?["relationships"] as? NSDictionary)?["mdmServer"] == nil)
    }

    @Test("Refused before sending: Release in School, no server, no deadline, over 90 days, a bad serial")
    func refusals() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func refusal(_ activity: ABM.Activity, _ service: ABM.Service = .business) -> String? {
            do {
                _ = try activity.body(for: service, now: now)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        #expect(refusal(try ABM.Activity(.release, serials: ["A"]), .school) == "Apple School Manager can’t release devices from the organization.")
        #expect(refusal(try ABM.Activity(.assign, serials: ["A"])) == "Assign to “the Selected MDM Server” needs an MDM server.")
        #expect(refusal(try ABM.Activity(.updateMigrationDeadline, serials: ["A"])) == "Update Migration Deadline needs a migration deadline.")
        #expect(refusal(try ABM.Activity(.updateMigrationDeadline, serials: ["A"], deadline: now.addingTimeInterval(91 * 86400)))
                == "Apple Business won’t accept a migration deadline more than 90 days from now.")
        #expect(throws: ABM.APIError.self) { try ABM.Activity(.release, serials: ["A B"]) }
    }

    @Test("The rules: all six name the organization; three ask for the number from two devices; two are red")
    func rules() {
        let typed: Set<ABM.ActivityType> = [.release, .assignWithMigrationDeadline, .updateMigrationDeadline]
        let red: Set<ABM.ActivityType> = [.release, .cancelMigration]
        for type in ABM.ActivityType.allCases {
            let one = type.confirmation(serials: ["C02"], organization: "Lab Org", service: .business, server: "Jamf Pro",
                                        deadline: Date().addingTimeInterval(86400))
            let three = type.confirmation(serials: ["A", "B", "C"], organization: "Lab Org", service: .business, server: "Jamf Pro",
                                          deadline: Date().addingTimeInterval(86400))
            #expect(one.connectionLine == "On “Lab Org”.", "\(type)")
            #expect(three.connectionLine == "On “Lab Org”.", "\(type)")
            #expect(one.typedCount == nil, "\(type)")
            #expect(three.typedCount == (typed.contains(type) ? 3 : nil), "\(type)")
            #expect(one.isDestructive == red.contains(type), "\(type)")
            #expect(!one.asksPINTwice)
        }
        #expect(ABM.ActivityType.allCases.filter { !$0.canBeUndone } == [.release])
        #expect(!ABM.ActivityType.release.isAvailable(on: .school))
    }

    @Test("Titles and texts")
    func texts() {
        let release = ABM.ActivityType.release.confirmation(serials: ["C02"], organization: "Lab Org", service: .business)
        #expect(release.title == "Release from Organization — C02")
        #expect(release.message == "The device will be removed from your organization and can no longer be assigned to an MDM server. This can’t be undone through the API.")
        #expect(release.actionTitle == "Release from Organization")
        let assign = ABM.ActivityType.assign.confirmation(serials: ["A", "B"], organization: "Lab Org", service: .school, server: "Jamf Pro",
                                                          explanation: "1 device is released and is skipped.")
        #expect(assign.title == "Assign to “Jamf Pro” — 2 Devices")
        #expect(assign.message == "Devices that are released or not in Apple School Manager are skipped. Apple processes assignments asynchronously.")
        #expect(assign.explanation == "1 device is released and is skipped.")
        let cancel = ABM.ActivityType.cancelMigration.confirmation(serials: ["C02"], organization: "Lab Org", service: .business,
                                                                   currentServer: "Jamf Pro")
        #expect(cancel.message.contains("stays assigned to Jamf Pro in Apple Business"))
    }

    @Test("Update Deadline warns when the new deadline is earlier than a current one or already past")
    func earlierDeadline() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func message(_ deadline: Date, current: [Date]) -> String {
            ABM.ActivityType.updateMigrationDeadline.confirmation(serials: ["A"], organization: "O", service: .business,
                                                                  deadline: deadline, currentDeadlines: current, now: now).message
        }
        let later = message(now.addingTimeInterval(10 * 86400), current: [now.addingTimeInterval(5 * 86400)])
        #expect(later == "A deadline earlier than the current one, or in the past, is enforced immediately without giving the user the option to delay.")
        let earlier = message(now.addingTimeInterval(2 * 86400), current: [now.addingTimeInterval(5 * 86400)])
        #expect(earlier.hasPrefix("This deadline is earlier than the current one, or already past, so Apple enforces it immediately"))
        #expect(message(now.addingTimeInterval(-60), current: []).hasPrefix("This deadline is earlier"))
    }

    @Test("Outcomes, from Apple’s documented values")
    func outcomes() {
        func outcome(_ status: String?, _ sub: String?) -> ABM.ActivityOutcome {
            ABM.ActivityStatus(id: "A", status: status, subStatus: sub).outcome
        }
        #expect(outcome("COMPLETED", "COMPLETED_WITH_SUCCESS") == .completed)
        #expect(outcome("COMPLETED", "COMPLETED_WITH_FAILURE") == .partlyFailed)
        #expect(outcome("COMPLETED", "COMPLETED_WITH_ERROR") == .failed("COMPLETED_WITH_ERROR"))
        #expect(outcome("COMPLETED", "COMPLETED_POST_PROCESSING_FAILED") == .completedWithoutReport)
        #expect(outcome("FAILED", nil) == .failed("FAILED"))
        #expect(outcome("STOPPED", "STOPPING") == .stopped)
        #expect(outcome("IN_PROGRESS", "PROCESSING") == .stillProcessing)
        #expect(outcome("NEW_STATE", nil) == .unknown("NEW_STATE"))
        #expect(ABM.ActivityStatus(id: "A", status: "IN_PROGRESS").isFinished == false)
        #expect(ABM.ActivityStatus(id: "A", status: "FAILED").isFinished)
        #expect(ABM.ActivityOutcome.partlyFailed.isFailure)
        #expect(ABM.ActivityOutcome.stillProcessing.isWarning)
        #expect(ABM.ActivityOutcome.completed.sentence(.business) == nil)
        #expect(ABM.ActivityOutcome.partlyFailed.sentence(.business)
                == "Apple couldn’t process some of the devices; its activity report in Apple Business lists which.")
    }

    /// A fake Apple that accepts a write and reports `states` one per check
    /// (the last repeats), in Apple’s documented format.
    static func activityServer(_ states: [(String, String)]) -> MockServer {
        let checks = Counter()
        return Apple.server { request in
            if request.path == "/v1/orgDeviceActivities", request.method == "POST" {
                return .json(201, #"{"data":{"type":"orgDeviceActivities","id":"84d7f133","attributes":{"status":"IN_PROGRESS","subStatus":"SUBMITTED"}}}"#)
            }
            guard request.path == "/v1/orgDeviceActivities/84d7f133" else { return nil }
            let (status, sub) = states[min(checks.next(), states.count) - 1]
            return .json(200, #"""
                {"data":{"type":"orgDeviceActivities","id":"84d7f133","attributes":{"status":"\#(status)","subStatus":"\#(sub)",
                 "createdDateTime":"2025-05-01T18:22:27.106Z","completedDateTime":"2025-05-01T18:22:38.894Z",
                 "downloadUrl":"https://store.blobstore.apple.com/4a7f/88c5?response-content-disposition=attachment%3Bfilename%3D%22ABM-ActivityLog.csv%22&iCloudAccessKeyId=MACOSX_SU_ACCESS_KEY&Expires=1746123820&Signature=wrYW2gn7UZDM9aO3KOMqT8YWCBo%3D"},
                 "links":{"self":"https://api-business.apple.com/v1/orgDeviceActivities/84d7f133"}}}
                """#)
        }
    }

    @Test("A write is watched until Apple finishes, checks from 2 s growing, and reports the outcome")
    func watched() async throws {
        let rig = AppleRig(Self.activityServer([("IN_PROGRESS", "SUBMITTED"), ("IN_PROGRESS", "PROCESSING"),
                                                ("COMPLETED", "COMPLETED_WITH_FAILURE")]))
        let outcome = try await rig.client.perform(try ABM.Activity(.assign, serials: ["A"], serverID: "S1"))
        #expect(outcome == .partlyFailed)
        #expect(rig.time.waits == [2, 3])
        #expect(rig.api.filter { $0.method == "GET" }.count == 3)
        // the signed download address isn’t recorded
        #expect(!ActivityLogExport.text(rig.log.entries, masked: false).contains("wrYW2gn7"))
    }

    @Test("Still in progress after 2 minutes is a warning, not a success")
    func timedOut() async throws {
        let rig = AppleRig(Self.activityServer([("IN_PROGRESS", "PROCESSING")]))
        let outcome = try await rig.client.perform(try ABM.Activity(.release, serials: ["A"]))
        #expect(outcome == .stillProcessing)
        #expect(rig.time.waits.reduce(0, +) <= 120.5)
    }

    @Test("A failed check ends the watch as a warning; no ID isn’t followed")
    func failedCheck() async throws {
        let rig = AppleRig(Apple.server { request in
            if request.path == "/v1/orgDeviceActivities" { return .json(201, #"{"data":{"id":"X1"}}"#) }
            return request.path == "/v1/orgDeviceActivities/X1" ? Apple.error(400) : nil
        })
        let outcome = try await rig.client.perform(try ABM.Activity(.release, serials: ["A"]))
        guard case .watchFailed(let reason) = outcome else { Issue.record("not a watch failure: \(outcome)"); return }
        #expect(outcome.isWarning && !outcome.isFailure)
        #expect(outcome.sentence(.business) == "Checking on it failed (\(reason)); check the devices in Apple Business.")
        #expect(!(outcome.sentence(.business) ?? "").contains("Apple reports"))
        #expect(try await rig.client.watch(activityID: nil) == .notFollowed)
    }
}
