import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

@MainActor
@Suite("1.13.1: the Jamf client and token provider use https:// only")
struct HTTPSOnlyJamfTests {
    @Test("A Jamf Platform client with an http:// address sends nothing and logs the refusal")
    func clientRefusesHTTP() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let log = ActivityLog()
        let client = try JamfPlatform.Client(baseURL: URL(string: "http://jamf.example.com")!, scope: .organization,
                                             server: .jamfPro, tokens: FixedToken("tok"),
                                             recorder: RequestRecorder(session: server.session, log: log))
        await #expect(throws: JamfPlatform.APIError.self) { _ = try await client.json("/pro/v1/jamf-pro-version") }
        #expect(server.requests.isEmpty)
        let blocked = log.entries.filter { $0.category == "Blocked" }
        #expect(blocked.count == 1)
    }

    @Test("A Jamf Platform client with an https:// address still sends")
    func clientSendsHTTPS() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://jamf.example.com")!, scope: .organization,
                                             server: .jamfPro, tokens: FixedToken("tok"),
                                             recorder: RequestRecorder(session: server.session, log: nil))
        _ = try await client.json("/pro/v1/jamf-pro-version")
        #expect(server.requests.count == 1)
    }

    @Test("A token provider with an http:// address never reads or sends the secret",
          arguments: [JamfPlatform.TokenProvider.Method.apiClient(clientID: "client-1"),
                      .usernamePassword(username: "admin")])
    func tokenProviderRefusesHTTP(method: JamfPlatform.TokenProvider.Method) async throws {
        let server = MockServer { _ in .json(200, tokenJSON("tok")) }
        let reads = Counter()
        let tokens = JamfPlatform.TokenProvider(tokenURL: URL(string: "http://jamf.example.com/api/oauth/token")!,
                                                method: method, secret: { _ = reads.next(); return "s3cr3t" },
                                                recorder: RequestRecorder(session: server.session, log: nil))
        await #expect { _ = try await tokens.token() } throws: { error in
            guard case .invalidURL(let message) = error as? HTTPError else { return false }
            return message.contains("https://") && !message.contains("s3cr3t")
        }
        #expect(server.requests.isEmpty)
        #expect(reads.value == 0)
    }

    @Test("A token provider with an https:// address signs in")
    func tokenProviderSignsInHTTPS() async throws {
        let server = MockServer { _ in .json(200, tokenJSON("tok")) }
        let tokens = JamfPlatform.TokenProvider(tokenURL: URL(string: "https://jamf.example.com/api/oauth/token")!,
                                                method: .apiClient(clientID: "client-1"), secret: { "s3cr3t" },
                                                recorder: RequestRecorder(session: server.session, log: nil))
        #expect(try await tokens.token() == "tok")
        #expect(server.requests.count == 1)
    }
}
