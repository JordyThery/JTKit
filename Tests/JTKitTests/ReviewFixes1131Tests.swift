import CryptoKit
import Foundation
import Security
import Testing
@testable import JTKit
import JTKitTestSupport

// The 1.13.1 fixes: masked identifiers in paths, a Jamf Pro address ending
// in /api, one rate-limit slot for Apple's shared sign-in, the Bearer and
// Basic redaction, a delete whose list can't be saved, the Graph sign-in's
// known secret, a membership cut short, a Keychain item that isn't text,
// refusing sessions let go, and OS versions.

@Suite("1.13.1: identifiers in a path")
struct PathIdentifierTests {
    @Test("A Jamf School UDID (a UUID) after devices/ is a device; a Blueprint’s UUID still isn’t")
    func schoolUDID() {
        let udid = "00000000-0000-4000-8000-0000000000aa"
        for path in ["api/devices/\(udid)/restart", "api/devices/\(udid)"] {
            #expect(IdentifierMasker.identifiers(inPath: path) == [FoundIdentifier(.device, udid)])
        }
        #expect(IdentifierMasker.identifiers(inPath: "/blueprints/v1/blueprints/\(udid)/deploy").isEmpty)
    }

    @Test("A serial of letters only after a device path segment is a device; elsewhere it isn’t")
    func letterSerial() {
        #expect(IdentifierMasker.identifiers(inPath: "/v1/orgDevices/ZZDEMOABCDEF") == [FoundIdentifier(.device, "ZZDEMOABCDEF")])
        #expect(IdentifierMasker.identifiers(inPath: "/api/v1/categories/ABCDEFGHIJK").isEmpty)
    }

    @Test("The account name of a LAPS read is a user")
    func lapsAccount() {
        let found = IdentifierMasker.identifiers(inPath: "/api/v2/local-admin-password/42/account/lapsadmin/password")
        #expect(found == [FoundIdentifier(.user, "lapsadmin")])
    }
}

@Suite("1.13.1: a Jamf Pro address ending in /api")
struct JamfProAPISuffixTests {
    @Test(arguments: ["https://myorg.jamfcloud.com/api", "https://myorg.jamfcloud.com/api/", "myorg.jamfcloud.com/API"])
    func dropped(address: String) throws {
        let connection = Connection(name: "S", service: .jamfPro, serverURL: address, clientID: "c")
        #expect(connection.jamfBaseURL?.absoluteString == "https://myorg.jamfcloud.com")
        let tokens = try JamfPlatform.TokenProvider(connection: connection, secret: { "s" },
                                                    recorder: RequestRecorder(session: MockServer { _ in .json(200, "{}") }.session, log: nil))
        #expect(tokens.tokenURL.absoluteString == "https://myorg.jamfcloud.com/api/oauth/token")
    }

    @Test("Another path stays as typed")
    func otherPaths() {
        #expect(Connection(name: "S", service: .jamfPro, serverURL: "https://example.com/jamf").jamfBaseURL?.absoluteString
                == "https://example.com/jamf")
        #expect(Connection(name: "S", service: .jamfPro, serverURL: "https://example.com/apis").jamfBaseURL?.absoluteString
                == "https://example.com/apis")
    }
}

@Suite("1.13.1: Apple’s shared sign-in takes one rate-limit slot")
struct AppleSharedSignInTests {
    @Test("Nine requests at once with no token: the wait before signing in runs once")
    func oneSlot() async throws {
        let server = MockServer { _ in .json(200, tokenJSON("apple-token")) }
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let tokens = ABM.TokenProvider(service: .business, clientID: "BUSINESSAPI.test", keyID: "key-1",
                                       privateKey: { pem }, recorder: RequestRecorder(session: server.session, log: nil))
        let slots = Counter()
        let values = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<9 {
                group.addTask {
                    try await tokens.token(beforeSigningIn: {
                        _ = slots.next()
                        try await Task.sleep(for: .milliseconds(50))
                    })
                }
            }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        #expect(values == Array(repeating: "apple-token", count: 9))
        #expect(slots.value == 1)
        #expect(await tokens.signInCount == 1)
        #expect(server.requests.count == 1)
    }
}

@Suite("1.13.1: Bearer and Basic in free text")
struct BearerBasicRedactionTests {
    @Test("Sentences keep their words",
          arguments: ["Basic authentication is disabled for this API", "Invalid bearer token", "Bearer token expired"])
    func sentences(text: String) {
        #expect(Redaction.text(text) == text)
    }

    @Test("Credentials are still hidden")
    func credentials() {
        let hidden = Redaction.placeholder
        #expect(Redaction.text("sent Basic YWRtaW46aHVudGVyMg== then") == "sent Basic \(hidden) then")
        #expect(Redaction.text("Basic dXNlcjpwYXNz failed") == "Basic \(hidden) failed")
        #expect(Redaction.text("Bearer abc123def failed") == "Bearer \(hidden) failed")
        #expect(Redaction.text("Bearer abcdefghijklmnopqrstuvwxyz") == "Bearer \(hidden)")
        #expect(Redaction.text("authorization: bearer opaque") == "authorization: bearer \(hidden)")
        #expect(Redaction.text(#"{"Authorization": "Basic abc"}"#).contains("abc") == false)
    }
}

@MainActor
@Suite("1.13.1: a delete whose list can’t be saved")
struct DeleteSaveFailureTests {
    /// Saves until `failing` is set.
    final class FlakyStorage: ConnectionStorage {
        var records: [SampleTenant] = []
        var failing = false
        struct DiskFull: LocalizedError { var errorDescription: String? { "The disk is full" } }

        func load() throws -> [SampleTenant] { records }
        func save(_ records: [SampleTenant]) throws {
            if failing { throw DiskFull() }
            self.records = records
        }
        func backUpOnce() throws {}
        func keepUnreadableCopy() -> String? { nil }
    }

    @Test("The error says the connection’s secrets are already gone")
    func saysSecretsAreGone() throws {
        let storage = FlakyStorage()
        let keychain = FakeKeychain()
        let store = ConnectionStore(storage: storage, secrets: [.main: SecretLocation(store: keychain)])
        let tenant = SampleTenant(name: "Sandbox")
        try store.save(tenant, secrets: [.main: "made-up-secret"])
        storage.failing = true
        #expect { try store.delete(id: tenant.id) } throws: { error in
            guard case .couldNotSave(let detail) = error as? ConnectionStoreError else { return false }
            return detail == "The disk is full. “Sandbox” is still in the list, but its client secret was already deleted from the Keychain. Delete the connection again, or enter the secret again to keep using it."
        }
        #expect(store.records == [tenant])
        #expect(keychain.all.isEmpty)
    }
}

@MainActor
@Suite("1.13.1: the Microsoft sign-in hides its secret in any answer")
struct GraphKnownSecretTests {
    @Test("A refused sign-in that echoes the secret outside client_secret= never shows it")
    func echoedSecret() async throws {
        let secret = "MadeUpSecret~0123456789"
        let server = MockServer { _ in .json(400, #"{"error":"invalid_client","error_description":"echo \#(secret) here"}"#) }
        let log = ActivityLog()
        let tokens = try Graph.TokenProvider(tenantID: "00000000-0000-4000-8000-0000000000e1", clientID: "00000000-0000-4000-8000-0000000000c1",
                                             secret: { secret }, recorder: RequestRecorder(session: server.session, log: log))
        await #expect { _ = try await tokens.token() } throws: { error in
            !error.localizedDescription.contains(secret) && !String(describing: error).contains(secret)
        }
        let entries = log.entries
        let transcript = entries.map { ActivityLogExport.transcript(of: $0) }.joined()
        #expect(!transcript.contains(secret))
    }
}

@Suite("1.13.1: a mobile device group’s members never cut short quietly")
struct MobileMembershipLimitTests {
    @Test("A server that keeps sending new devices ends with pageLimitReached")
    func endless() async throws {
        let pages = Counter()
        let server = MockServer { request in
            let page = pages.next()
            let results = (0..<100).map { #"{"id":"\#(page * 100 + $0)","name":"Device"}"# }.joined(separator: ",")
            return .json(200, #"{"totalCount":1000000,"results":[\#(results)]}"#)
        }
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://jamf.example.com")!, scope: .organization,
                                             server: .jamfPro, tokens: FixedToken("tok"),
                                             recorder: RequestRecorder(session: server.session, log: nil), sleep: { _ in })
        let group = JamfPro.DeviceGroup(groupID: "1", name: "G", isSmart: false, kind: .mobileDevice)
        await #expect { _ = try await client.members(of: group) } throws: { error in
            guard case .pageLimitReached = (error as? JamfPlatform.APIError)?.kind else { return false }
            return true
        }
        #expect(server.requests.count == 1_000)
    }
}

@Suite("1.13.1: a Keychain item that isn’t text")
struct KeychainTextTests {
    @Test func notUTF8IsAnError() throws {
        #expect(throws: SecretStoreError(status: errSecDecode)) { try KeychainSecretStore.text(of: Data([0xFF, 0xFE, 0xFD])) }
        #expect(try KeychainSecretStore.text(of: Data("made-up".utf8)) == "made-up")
    }
}

@Suite("1.13.1: a refusing session’s route goes with it")
struct RefusingSessionLifetimeTests {
    @Test func theRouteGoesWithTheSession() async throws {
        var id = ""
        do {
            let session = TestRun.refusingSession(log: TestRun.AttemptLog(fileURL: FileManager.default.temporaryDirectory.appending(path: "jtkit-refusing-\(UUID().uuidString).jsonl")), message: "Refused.")
            id = session.configuration.httpAdditionalHeaders?[TestRun.RefusingURLProtocol.routeHeader] as? String ?? ""
            #expect(TestRun.RefusingURLProtocol.isRegistered(id: id))
            _ = try? await session.data(from: URL(string: "https://example.com/")!)
        }
        for _ in 0..<200 where TestRun.RefusingURLProtocol.isRegistered(id: id) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!id.isEmpty)
        #expect(!TestRun.RefusingURLProtocol.isRegistered(id: id))
    }
}

@Suite("1.13.1: OS versions")
struct OSVersionPatternTests {
    @Test func versions() {
        #expect(OSVersion("27.0.1") == OSVersion(major: 27, minor: 0, patch: 1))
        #expect(OSVersion("macOS Golden Gate 27.2") == OSVersion(major: 27, minor: 2))
        #expect(OSVersion("26.3.1 (a)")?.extra == "(a)")
        #expect(OSVersion("23A344") == nil)
        #expect(OSVersion("iPad13,18") == nil)
        #expect(OSVersion("1.2.3.4") == nil)
    }
}
