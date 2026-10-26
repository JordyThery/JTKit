import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

@Suite("Jamf token provider")
@MainActor
struct JamfTokenProviderTests {
    private let secret = "s3cr3t+with&specials="

    private func provider(
        _ server: MockServer,
        connection: Connection = Connection(name: "Sandbox", service: .jamfPlatform, clientID: "client-1"),
        log: ActivityLog = ActivityLog(),
        clock: TestClock = TestClock(),
        secret: @escaping @Sendable () throws -> String
    ) throws -> JamfTokenProvider {
        try JamfTokenProvider(connection: connection, secret: secret,
                              recorder: RequestRecorder(session: server.session, log: log),
                              now: { clock.now })
    }

    @Test("Platform API client: a strictly encoded client-credentials form to /auth/token")
    func platformClient() async throws {
        let server = MockServer { _ in .json(200, tokenJSON("tok-1")) }
        let secret = secret
        let token = try await provider(server) { secret }.token()
        #expect(token == "tok-1")
        let sent = try #require(server.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://us.api.jamfcloud.com/auth/token")
        #expect(sent.header("Content-Type") == "application/x-www-form-urlencoded")
        #expect(sent.bodyString == "grant_type=client_credentials&client_id=client-1&client_secret=s3cr3t%2Bwith%26specials%3D")
    }

    @Test("Jamf Pro: API client to /api/oauth/token, username and password to /api/v1/auth/token")
    func jamfPro() async throws {
        let server = MockServer { request in
            request.path == "/api/v1/auth/token"
                ? .json(200, #"{"token":"user-token","expires":"2027-01-15T08:30:00.000Z"}"#)
                : .json(200, tokenJSON("client-token"))
        }
        let client = Connection(name: "Pro", service: .jamfPro, signIn: .apiClient,
                                serverURL: "https://acme.jamfcloud.com/", clientID: "id")
        #expect(try await provider(server, connection: client) { "x" }.token() == "client-token")

        let user = Connection(name: "Pro", service: .jamfPro, signIn: .usernamePassword,
                              serverURL: "https://acme.jamfcloud.com", username: "admin")
        #expect(try await provider(server, connection: user) { "hunter2" }.token() == "user-token")

        #expect(server.requests.map(\.path) == ["/api/oauth/token", "/api/v1/auth/token"])
        let basic = try #require(server.requests.last)
        #expect(basic.header("Authorization") == "Basic " + Data("admin:hunter2".utf8).base64EncodedString())
        #expect(basic.body.isEmpty)
    }

    @Test("Jamf Pro user tokens: expiry with and without fractional seconds")
    func userTokenFormats() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15T08:00:00Z
        let fractional = try JamfTokenProvider.parse(Data(#"{"token":"a","expires":"2027-01-15T08:30:00.000Z"}"#.utf8), now: now)
        #expect(fractional == ("a", 1800))
        let whole = try JamfTokenProvider.parse(Data(#"{"token":"b","expires":"2027-01-15T08:10:00Z"}"#.utf8), now: now)
        #expect(whole == ("b", 600))
        let missing = try JamfTokenProvider.parse(Data(#"{"token":"c"}"#.utf8), now: now)
        #expect(missing == ("c", 1200))
    }

    @Test("The token is reused until 60 s before it expires")
    func renewal() async throws {
        let issued = Counter()
        let server = MockServer { _ in .json(200, tokenJSON("tok-\(issued.next())", expiresIn: 900)) }
        let clock = TestClock()
        let tokens = try provider(server, clock: clock) { "s" }
        #expect(try await tokens.token() == "tok-1")
        clock.advance(by: 830)
        #expect(try await tokens.token() == "tok-1")
        clock.advance(by: 20)
        #expect(try await tokens.token() == "tok-2")
        #expect(await tokens.signInCount == 2)
    }

    @Test("Requests at the same time share one sign-in")
    func sharedSignIn() async throws {
        let server = MockServer { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return .json(200, tokenJSON("shared"))
        }
        let tokens = try provider(server) { "s" }
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await tokens.token() } }
            var values = [String]()
            for try await value in group { values.append(value) }
            return values
        }
        #expect(Set(values) == ["shared"])
        #expect(server.requests.count == 1)
    }

    @Test("Forgetting the token signs in again, reading the secret again")
    func forgetAndReadSecret() async throws {
        let server = MockServer { _ in .json(200, tokenJSON("tok")) }
        let secrets = Locked(["first", "second"])
        let tokens = try provider(server) { secrets.withLock { $0.removeFirst() } }
        _ = try await tokens.token()
        await tokens.forgetToken()
        _ = try await tokens.token()
        #expect(server.requests.map { $0.bodyString.contains("client_secret=first") } == [true, false])
        #expect(server.requests.last?.bodyString.contains("client_secret=second") == true)
    }

    @Test("A refused sign-in says why, without the secret; the app's own errors pass unchanged")
    func failures() async throws {
        let server = MockServer { _ in .json(401, #"{"error":"invalid_client","error_description":"bad","client_secret":"echoed"}"#) }
        let log = ActivityLog()
        let secret = secret
        do {
            _ = try await provider(server, log: log) { secret }.token()
            Issue.record("Expected a failure")
        } catch let error as HTTPError {
            guard case let .status(response, _, _, duringSignIn) = error else { Issue.record("\(error)"); return }
            #expect(duringSignIn)
            #expect(response.status == 401)
            #expect(error.localizedDescription.contains("invalid_client"))
            #expect(!error.localizedDescription.contains("echoed"))
            #expect(!error.localizedDescription.contains(secret))
        }
        let entry = try #require(log.entries.first)
        #expect(entry.category == "Sign-in")
        let transcript = ActivityLogExport.transcript(of: entry)
        #expect(!transcript.contains(secret))
        #expect(!transcript.contains("echoed"))
        #expect(!transcript.contains("s3cr3t"))

        struct NoSecret: Error {}
        await #expect(throws: NoSecret.self) {
            _ = try await provider(MockServer { _ in .json(200, tokenJSON("t")) }) { throw NoSecret() }.token()
        }
    }

    @Test("A password sign-in is logged without the password")
    func basicLogged() async throws {
        let server = MockServer { _ in .json(200, #"{"token":"user-token","expires":"2027-01-15T08:30:00Z"}"#) }
        let log = ActivityLog()
        let user = Connection(name: "Pro", service: .jamfPro, signIn: .usernamePassword,
                              serverURL: "https://acme.jamfcloud.com", username: "admin")
        _ = try await provider(server, connection: user, log: log) { "hunter2" }.token()
        let transcript = ActivityLogExport.transcript(of: try #require(log.entries.first))
        #expect(transcript.contains("Authorization: Basic \(Redaction.placeholder)"))
        #expect(!transcript.contains(Data("admin:hunter2".utf8).base64EncodedString()))
        #expect(!transcript.contains("user-token"))
    }

    @Test("Jamf addresses from a connection")
    func baseURLs() {
        #expect(Connection(name: "", service: .jamfPlatform, region: .eu).jamfBaseURL?.absoluteString
                == "https://eu.api.jamfcloud.com")
        #expect(Connection(name: "", service: .jamfPlatform, hostOverride: " https://staging.example.com/ ").jamfBaseURL?.absoluteString
                == "https://staging.example.com")
        #expect(Connection(name: "", service: .jamfPlatform, hostOverride: "staging.example.com/path").jamfBaseURL == nil)
        #expect(Connection(name: "", service: .jamfPro, serverURL: "https://acme.jamfcloud.com//").jamfBaseURL?.absoluteString
                == "https://acme.jamfcloud.com")
        #expect(Connection(name: "", service: .jamfPro, serverURL: "http://acme.jamfcloud.com").jamfBaseURL == nil)
        #expect(Connection(name: "", service: .intune).jamfBaseURL == nil)
    }

    @Test("Connections that can't sign in to Jamf are refused")
    func unsupported() {
        let school = Connection(name: "School", service: .jamfSchool, serverURL: "https://school.example.com")
        #expect(throws: HTTPError.self) {
            _ = try JamfTokenProvider(connection: school, secret: { "" }, recorder: RequestRecorder(log: nil))
        }
    }

    @Test("A sign-in redirected to another server is refused: the secret never leaves the host")
    func signInRedirectToOtherHostRefused() async throws {
        let server = MockServer { request in
            request.url.host() == "us.api.jamfcloud.com"
                ? .redirect(to: URL(string: "https://evil.example/auth/token")!)
                : .json(200, tokenJSON("stolen"))
        }
        let tokens = try provider(server) { "s3cr3t" }
        await #expect { _ = try await tokens.token() } throws: { error in
            // the refused redirect itself is the answer: a failed sign-in
            (error as? HTTPError)?.status == 307
        }
        #expect(server.requests.map { $0.url.host() } == ["us.api.jamfcloud.com"])
        #expect(!server.requests.contains { $0.url.host() == "evil.example" })
    }

    @Test("A sign-in redirect over plain HTTP is refused, also on the same host")
    func signInRedirectToHTTPRefused() async throws {
        let server = MockServer { request in
            request.url.scheme == "https"
                ? .redirect(to: URL(string: "http://us.api.jamfcloud.com/auth/token")!)
                : .json(200, tokenJSON("plain"))
        }
        let tokens = try provider(server) { "s3cr3t" }
        await #expect { _ = try await tokens.token() } throws: { error in
            // the refused redirect itself is the answer: a failed sign-in
            (error as? HTTPError)?.status == 307
        }
        #expect(server.requests.count == 1)
    }

    @Test("A sign-in redirect to HTTPS on the same host is followed")
    func signInRedirectSameHostFollowed() async throws {
        let server = MockServer { request in
            request.path == "/auth/token"
                ? .redirect(to: URL(string: "https://us.api.jamfcloud.com/v2/auth/token")!)
                : .json(200, tokenJSON("tok-moved"))
        }
        #expect(try await provider(server) { "s" }.token() == "tok-moved")
        #expect(server.requests.map(\.path) == ["/auth/token", "/v2/auth/token"])
    }
}
