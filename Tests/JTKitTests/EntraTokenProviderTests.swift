import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

@Suite("Entra app sign-in")
@MainActor
struct EntraTokenProviderTests {
    private static let tenant = "c0ffee00-0000-0000-0000-000000000000"
    private static let client = "e445f0a6-0000-0000-0000-000000000000"

    private func provider(_ server: MockServer, log: ActivityLog? = nil, clock: TestClock = TestClock(),
                          secret: @escaping @Sendable () throws -> String = { "s3cr+t=&" }) throws -> Graph.TokenProvider {
        try Graph.TokenProvider(tenantID: Self.tenant, clientID: Self.client, secret: secret,
                               recorder: RequestRecorder(session: server.session, log: log), now: { clock.now })
    }

    @Test("Signs in to the tenant’s token address with the client credentials and the Graph scope")
    func request() async throws {
        let server = MockServer { _ in .json(200, tokenJSON("t1", expiresIn: 3599)) }
        #expect(try await provider(server).token() == "t1")
        let sent = try #require(server.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://login.microsoftonline.com/\(Self.tenant)/oauth2/v2.0/token")
        #expect(sent.header("Content-Type") == "application/x-www-form-urlencoded")
        let form = Dictionary(uniqueKeysWithValues: sent.bodyString.split(separator: "&").map {
            let pair = $0.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            return (pair[0], pair.count > 1 ? pair[1] : "")
        })
        #expect(form == ["grant_type": "client_credentials", "client_id": Self.client, "client_secret": "s3cr+t=&",
                         "scope": "https://graph.microsoft.com/.default"])
    }

    @Test("Neither the secret nor the token reaches the log")
    func nothingSecretLogged() async throws {
        let log = ActivityLog()
        let server = MockServer { _ in .json(200, tokenJSON("tok-value")) }
        _ = try await provider(server, log: log).token()
        let transcript = log.entries.map { ActivityLogExport.transcript(of: $0) }.joined()
        #expect(log.entries.first?.category == "Sign-in")
        #expect(!transcript.contains("s3cr") && !transcript.contains("tok-value"))
    }

    @Test("The token is kept and renewed 60 s before it expires")
    func renewal() async throws {
        let calls = Counter()
        let server = MockServer { _ in .json(200, tokenJSON("t\(calls.next())", expiresIn: 3600)) }
        let clock = TestClock()
        let tokens = try provider(server, clock: clock)
        #expect(try await tokens.token() == "t1")
        clock.advance(by: 3600 - 61)
        #expect(try await tokens.token() == "t1")
        clock.advance(by: 2)
        #expect(try await tokens.token() == "t2")
    }

    @Test("Requests at the same time share one sign-in")
    func sharedSignIn() async throws {
        let server = MockServer { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return .json(200, tokenJSON("t"))
        }
        let tokens = try provider(server)
        async let a = tokens.token()
        async let b = tokens.token()
        async let c = tokens.token()
        _ = try await [a, b, c]
        #expect(await tokens.signInCount == 1)
    }

    @Test("The secret is read at each sign-in; forgetting the token signs in again")
    func secretReadEachTime() async throws {
        let reads = Counter()
        let server = MockServer { _ in .json(200, tokenJSON("t")) }
        let tokens = try provider(server, secret: { "secret-\(reads.next())" })
        _ = try await tokens.token()
        await tokens.forgetToken()
        _ = try await tokens.token()
        #expect(reads.value == 2)
        #expect(server.requests.last?.bodyString.contains("secret-2") == true)
    }

    @Test("A refused sign-in is a Graph.APIError with Microsoft’s code, Trace ID and hint")
    func refused() async throws {
        let server = MockServer { _ in
            .json(401, #"{"error":"invalid_client","error_description":"AADSTS7000222: The provided client secret keys are expired.\r\nTrace ID: t-9","error_codes":[7000222],"trace_id":"t-9"}"#)
        }
        do {
            _ = try await provider(server).token()
            Issue.record("Expected a failure")
        } catch let error as Graph.APIError {
            #expect(error.status == 401)
            #expect(error.access == .application)
            let message = error.message()
            #expect(message.hasPrefix("Sign-in failed: HTTP 401 Unauthorized\ninvalid_client: AADSTS7000222"))
            #expect(message.contains("Trace ID: t-9"))
            #expect(message.contains("The client secret has expired."))
        }
    }

    @Test("A sign-in redirected to another server is refused: the secret never leaves")
    func redirectRefused() async throws {
        let elsewhere = try #require(URL(string: "https://evil.example.com/token"))
        let server = MockServer { request in
            request.url.host() == "evil.example.com" ? .json(200, tokenJSON("stolen")) : .redirect(307, to: elsewhere)
        }
        await #expect(throws: Graph.APIError.self) { _ = try await provider(server).token() }
        #expect(!server.requests.contains { $0.url.host() == "evil.example.com" })
    }

    @Test("An unusable tenant or client ID is refused before anything is sent")
    func invalidIDs() throws {
        let recorder = RequestRecorder(session: URLSession(configuration: .ephemeral), log: nil)
        #expect(throws: Graph.APIError.self) { try Graph.TokenProvider(tenantID: "", clientID: Self.client, secret: { "" }, recorder: recorder) }
        #expect(throws: Graph.APIError.self) { try Graph.TokenProvider(tenantID: "a/b", clientID: Self.client, secret: { "" }, recorder: recorder) }
        #expect(throws: Graph.APIError.self) { try Graph.TokenProvider(tenantID: Self.tenant, clientID: "app", secret: { "" }, recorder: recorder) }
        let domain = try Graph.TokenProvider(tenantID: " contoso.com ", clientID: Self.client, secret: { "" }, recorder: recorder)
        #expect(domain.tokenURL.absoluteString == "https://login.microsoftonline.com/contoso.com/oauth2/v2.0/token")
    }

    @Test("The tenant is a UUID or a domain name, nothing that can change the sign-in address",
          arguments: ["..", "a..b", "contoso.com/..", ".contoso.com", "contoso.com.", "-a.com", "a-.com", "contoso",
                      "a%2F.com", "con toso.com", "contoso.com?x=1", "contoso.com#x", "kontöso.com"])
    func tenantShape(tenant: String) {
        #expect(!Graph.TokenProvider.isTenant(tenant))
        #expect(throws: Graph.APIError.self) {
            try Graph.TokenProvider(tenantID: tenant, clientID: Self.client, secret: { "" }, recorder: RequestRecorder(session: URLSession(configuration: .ephemeral), log: nil))
        }
    }

    @Test("Tenant IDs and domains that are fine")
    func tenantShapeAllowed() {
        for tenant in [Self.tenant, "C0FFEE00-0000-0000-0000-000000000000", "contoso.com", "contoso.onmicrosoft.com", "lab-9.example.co.uk"] {
            #expect(Graph.TokenProvider.isTenant(tenant), "\(tenant)")
        }
    }

    @Test("Made from an Intune connection with an app registration only")
    func fromConnection() throws {
        let recorder = RequestRecorder(session: URLSession(configuration: .ephemeral), log: nil)
        let app = Connection(name: "Contoso", service: .intune, signIn: .entraClientSecret, clientID: Self.client, tenantID: Self.tenant)
        #expect(try Graph.TokenProvider(connection: app, secret: { "" }, recorder: recorder).clientID == Self.client)
        var interactive = app
        interactive.signIn = .microsoftInteractive
        #expect(throws: Graph.APIError.self) { try Graph.TokenProvider(connection: interactive, secret: { "" }, recorder: recorder) }
        let jamf = Connection(name: "Jamf", service: .jamfPro, serverURL: "https://x.jamfcloud.com")
        #expect(throws: Graph.APIError.self) { try Graph.TokenProvider(connection: jamf, secret: { "" }, recorder: recorder) }
    }

    @Test("A Graph client from a connection signs in, then sends with the token")
    func graphClientFromConnection() async throws {
        let server = MockServer { request in
            request.url.host() == "login.microsoftonline.com" ? .json(200, tokenJSON("app-token")) : .json(200, #"{"value":[]}"#)
        }
        let app = Connection(name: "Contoso", service: .intune, signIn: .entraClientSecret, clientID: Self.client, tenantID: Self.tenant)
        let client = try Graph.Client(connection: app, secret: { "s" }, session: server.session, log: nil)
        #expect(client.access == .application)
        _ = try await client.listRaw("deviceManagement/managedDevices", version: .v1)
        #expect(server.requests.last?.header("Authorization") == "Bearer app-token")
    }
}
