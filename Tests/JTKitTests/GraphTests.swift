import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

/// Counts how many token requests are in progress at once; the Graph client
/// asks for the token inside a request's turn.
final class TokenInFlight: BearerTokenSource, @unchecked Sendable {
    private let state = Locked((now: 0, most: 0))
    var most: Int { state.value.most }

    func token() async throws -> String {
        state.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
        try await Task.sleep(for: .milliseconds(100))
        state.withLock { $0.now -= 1 }
        return "tok"
    }

    func forgetToken() async {}
}

@MainActor
private func graphClient(_ server: MockServer, log: ActivityLog = ActivityLog(), tokens: any BearerTokenSource = FixedToken("tok"),
                         access: Graph.Access = .delegated, hints: [String] = [], sleeps: SleepLog = SleepLog(),
                         now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> Graph.Client {
    Graph.Client(tokens: tokens, access: access,
                 recorder: Graph.recorder(session: server.session, log: log, connection: "Contoso"),
                 hints: hints, sleep: { try await sleeps.sleep($0) }, random: { 0 }, now: { now })
}

@MainActor
private func graphError(_ body: () async throws -> Void) async -> GraphError? {
    do {
        try await body()
        Issue.record("Expected a GraphError")
    } catch let error as GraphError {
        return error
    } catch {
        Issue.record("Expected a GraphError, got \(error)")
    }
    return nil
}

private let ok = MockResponse.json(200, "{}")

@Suite("Graph client")
@MainActor
struct GraphClientTests {
    @Test("Requests carry the token, a new client-request-id each, the version and the query as given")
    func requestShape() async throws {
        let server = MockServer { _ in ok }
        let client = graphClient(server)
        _ = try await client.getRaw("me?$select=displayName,userPrincipalName", version: .v1)
        _ = try await client.getRaw("deviceManagement/configurationPolicies", version: .beta)
        let first = try #require(server.requests.first)
        #expect(first.url.absoluteString == "https://graph.microsoft.com/v1.0/me?$select=displayName,userPrincipalName")
        #expect(first.header("Authorization") == "Bearer tok")
        #expect(first.header("Accept") == "application/json")
        let ids = server.requests.compactMap { $0.header("client-request-id") }
        #expect(ids.count == 2 && Set(ids).count == 2)
        #expect(ids.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(server.requests[1].url.absoluteString == "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies")
    }

    @Test("Spaces and quotes in a filter are encoded; existing escapes are kept")
    func filterEncoding() throws {
        let parts = try Graph.Client.parts(of: "groups?$filter=displayName eq 'A%26B'&$select=id", version: .v1)
        #expect(parts.path == "v1.0/groups")
        #expect(parts.query == "$filter=displayName%20eq%20'A%26B'&$select=id")
    }

    @Test("Entries say Intune as service and category, and the connection")
    func logEntries() async throws {
        let log = ActivityLog()
        let server = MockServer { _ in ok }
        _ = try await graphClient(server, log: log).getRaw("me", version: .v1)
        let entry = try #require(log.entries.first)
        #expect(entry.service == "Intune")
        #expect(entry.category == "Intune")
        #expect(entry.connection == "Contoso")
        #expect(entry.request?.maxAttempts == 4)
    }

    @Test("At most 4 requests at a time")
    func fourAtATime() async throws {
        let tokens = TokenInFlight()
        let server = MockServer { _ in ok }
        let client = graphClient(server, tokens: tokens)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask { _ = try await client.getRaw("things/\(index)", version: .v1) }
            }
            try await group.waitForAll()
        }
        #expect(server.requests.count == 10)
        #expect(tokens.most == 4)
    }

    @Test("A create is not repeated after a server error")
    func createNotRepeated() async throws {
        let server = MockServer { _ in .json(503, "{}") }
        let error = await graphError { try await graphClient(server).post("groups", version: .v1, body: Data("{}".utf8)) }
        #expect(error?.status == 503)
        #expect(server.requests.count == 1)
    }

    @Test("A create is repeated after a 429: nothing was done")
    func createRepeatedAfter429() async throws {
        let calls = Counter()
        let server = MockServer { _ in calls.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "3"]) : .json(201, #"{"id":"g"}"#) }
        let sleeps = SleepLog()
        _ = try await graphClient(server, sleeps: sleeps).post("groups", version: .v1, body: Data("{}".utf8))
        #expect(server.requests.count == 2)
        #expect(sleeps.recorded == [.seconds(3)])
    }

    @Test("Updates and /assign are repeated after a server error")
    func safeEditsRepeated() async throws {
        let calls = Counter()
        let server = MockServer { _ in calls.next() % 2 == 1 ? .json(503, "{}") : ok }
        let client = graphClient(server)
        try await client.patch("deviceManagement/deviceShellScripts/1", version: .beta, body: Data("{}".utf8))
        try await client.put("deviceManagement/configurationPolicies/1", version: .beta, body: Data("{}".utf8))
        try await client.post("deviceManagement/deviceCompliancePolicies/1/assign", version: .v1, body: Data("{}".utf8), safeToRepeat: true)
        #expect(server.requests.map(\.method) == ["PATCH", "PATCH", "PUT", "PUT", "POST", "POST"])
    }

    @Test("A delete repeated after a server error that then finds nothing is done")
    func deleteAlreadyGone() async throws {
        let calls = Counter()
        let server = MockServer { _ in calls.next() == 1 ? .json(503, "{}") : .json(404, #"{"error":{"code":"ResourceNotFound","message":"Gone"}}"#) }
        let log = ActivityLog()
        try await graphClient(server, log: log).delete("deviceManagement/deviceShellScripts/1", version: .beta)
        #expect(server.requests.count == 2)
        #expect(log.entries.contains { $0.note == "HTTP 404 after a repeat: an earlier attempt already did it." })
    }

    @Test("A delete that finds nothing at the first try is an error")
    func deleteNotFound() async throws {
        let server = MockServer { _ in .json(404, #"{"error":{"code":"ResourceNotFound","message":"Gone"}}"#) }
        let error = await graphError { try await graphClient(server).delete("deviceManagement/deviceShellScripts/1", version: .beta) }
        #expect(error?.status == 404)
    }

    @Test("A 401 gets a new token and one more try")
    func unauthorized() async throws {
        let calls = Counter()
        let server = MockServer { _ in calls.next() == 1 ? .json(401, "{}") : ok }
        let tokens = FixedToken("old", "new")
        _ = try await graphClient(server, tokens: tokens).getRaw("me", version: .v1)
        #expect(server.requests.map { $0.header("Authorization") } == ["Bearer old", "Bearer new"])
        #expect(tokens.forgotten.value == 1)
    }

    @Test("At most 4 attempts; Retry-After as a date; no wait longer than 120 s")
    func retryLimits() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let inTenSeconds = formatter.string(from: now.addingTimeInterval(10))
        let calls = Counter()
        let server = MockServer { _ in
            .json(429, "{}", headers: ["Retry-After": calls.next() == 1 ? inTenSeconds : "9999"])
        }
        let sleeps = SleepLog()
        let error = await graphError { _ = try await graphClient(server, sleeps: sleeps, now: now).getRaw("me", version: .v1) }
        #expect(error?.status == 429)
        #expect(server.requests.count == 4)
        #expect(sleeps.recorded == [.seconds(10), .seconds(120), .seconds(120)])
    }

    @Test("Graph's dates read with or without fractional seconds")
    func dates() throws {
        struct Dated: Decodable { let a: Date; let b: Date }
        let value = try Graph.Client.decode(Dated.self, from: Data(#"{"a":"2026-01-15T10:30:00.1234567Z","b":"2026-01-15T10:30:00Z"}"#.utf8))
        #expect(abs(value.a.timeIntervalSince(value.b)) < 1)
    }
}

@Suite("Graph paging")
@MainActor
struct GraphPagingTests {
    @Test("Next pages are followed on Graph, as given")
    func followsNextPages() async throws {
        let server = MockServer { request in
            switch request.queryValue("$skiptoken") {
            case nil: .json(200, #"{"value":[{"id":"a"}],"@odata.nextLink":"https://graph.microsoft.com/beta/things?$skiptoken=2"}"#)
            case "2": .json(200, #"{"value":[{"id":"b"}],"@odata.nextLink":"https://graph.microsoft.com/beta/things?$skiptoken=3"}"#)
            default: .json(200, #"{"value":[{"id":"c"}]}"#)
            }
        }
        struct Thing: Decodable { let id: String }
        let things = try await graphClient(server).list(Thing.self, "things", version: .beta)
        #expect(things.map(\.id) == ["a", "b", "c"])
        #expect(server.requests.count == 3)
    }

    @Test("A next page on another server is refused: the token never goes there",
          arguments: ["https://evil.example.com/v1.0/things?$skiptoken=2", "http://graph.microsoft.com/v1.0/things",
                      "https://graph.microsoft.com:8443/v1.0/things", "https://graph.microsoft.com/other/things"])
    func nextPageElsewhere(link: String) async throws {
        let log = ActivityLog()
        let server = MockServer { _ in .json(200, #"{"value":[{"id":"a"}],"@odata.nextLink":"\#(link)"}"#) }
        let error = await graphError { _ = try await graphClient(server, log: log).listRaw("things", version: .v1) }
        guard case .nextPageElsewhere? = error?.kind else {
            Issue.record("Expected nextPageElsewhere, got \(String(describing: error))")
            return
        }
        #expect(server.requests.count == 1)
        #expect(log.entries.contains { $0.category == "Blocked" && $0.isWarning })
    }

    @Test("An answer without a list is an error, not an empty list")
    func withoutValue() async throws {
        let server = MockServer { _ in .json(200, #"{"id":"x"}"#) }
        let error = await graphError { _ = try await graphClient(server).listRaw("things", version: .v1) }
        guard case .invalidResponse? = error?.kind else {
            Issue.record("Expected invalidResponse")
            return
        }
    }

    @Test("Reaching the page limit is an error, never a quiet cut-off")
    func pageLimit() async throws {
        let server = MockServer { _ in .json(200, #"{"value":[{}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/things?$skiptoken=x"}"#) }
        let error = await graphError { _ = try await graphClient(server).listRaw("things", version: .v1, maxPages: 3) }
        guard case let .pageLimitReached(path, pages)? = error?.kind else {
            Issue.record("Expected pageLimitReached")
            return
        }
        #expect(path == "things" && pages == 3)
        #expect(server.requests.count == 3)
        #expect(Graph.maxPages == 1_000)
    }
}

@Suite("Graph errors")
@MainActor
struct GraphErrorTests {
    private nonisolated static let forbidden = #"""
    {"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges to complete the operation.",
     "innerError":{"date":"2026-10-26T19:00:00","request-id":"0d2f6b1c-6f1e-4d6a-9c1a-2b3c4d5e6f70","client-request-id":"x"}}}
    """#

    @Test("The status line, code: message, Request ID and date, then the permission")
    func format() async throws {
        let server = MockServer { _ in .json(403, Self.forbidden) }
        let error = await graphError { _ = try await graphClient(server).getRaw("deviceManagement/deviceShellScripts", version: .beta) }
        #expect(error?.requestID == "0d2f6b1c-6f1e-4d6a-9c1a-2b3c4d5e6f70")
        #expect(error?.permission == .scriptsRead)
        #expect(error?.message() == """
            HTTP 403 Forbidden
            Authorization_RequestDenied: Insufficient privileges to complete the operation.
            Request ID: 0d2f6b1c-6f1e-4d6a-9c1a-2b3c4d5e6f70
            Date: 2026-10-26T19:00:00
            This sign-in is missing the “DeviceManagementScripts.Read.All” delegated permission. Sign in again and accept it, or ask an admin to grant consent in Entra. It can also mean your Intune role doesn’t allow this.
            """)
    }

    @Test("For an app sign-in, the hint names the application permission and admin consent")
    func applicationHint() async throws {
        let server = MockServer { _ in .json(403, Self.forbidden) }
        let error = await graphError {
            _ = try await graphClient(server, access: .application).post("deviceManagement/managedDevices/1/wipe", version: .v1, body: Data("{}".utf8))
        }
        #expect(error?.message().hasSuffix("The app registration is missing the “DeviceManagementManagedDevices.PrivilegedOperations.All” application permission. Add it in Entra under App registrations › API permissions, then grant admin consent.") == true)
    }

    @Test("The app's hints come before the standard ones")
    func appHintsFirst() async throws {
        let server = MockServer { _ in .json(429, "{}") }
        let error = await graphError { _ = try await graphClient(server, hints: ["App hint."]).post("groups", version: .v1, body: Data()) }
        let lines = error?.message().split(separator: "\n").map(String.init) ?? []
        #expect(lines.suffix(2) == ["App hint.", "Microsoft Graph is limiting how many requests this app sends. Wait a minute, then try again."])
    }

    @Test("An answer that isn't Graph's error shape shows its start")
    func plainText() async throws {
        let server = MockServer { _ in MockResponse(status: 502, headers: ["Content-Type": "text/plain"], body: Data("Bad gateway".utf8)) }
        let error = await graphError { _ = try await graphClient(server).post("groups", version: .v1, body: Data()) }
        #expect(error?.message().hasPrefix("HTTP 502 Bad Gateway\nBad gateway") == true)
    }

    @Test("The Request ID stays unmasked in the bug-report export")
    func requestIDInExport() async throws {
        let log = ActivityLog()
        let server = MockServer { _ in .json(403, Self.forbidden) }
        _ = await graphError { _ = try await graphClient(server, log: log).getRaw("me", version: .v1) }
        let export = ActivityLogExport.text(log.entries, masked: true)
        #expect(export.contains("0d2f6b1c-6f1e-4d6a-9c1a-2b3c4d5e6f70"))
    }

    @Test("Sign-in errors keep the first line of Microsoft's description, its Trace and Correlation IDs")
    func signInBody() throws {
        let body = try #require(Graph.ErrorBody(data: Data(#"""
        {"error":"invalid_client","error_description":"AADSTS7000215: Invalid client secret provided.\r\nTrace ID: t-1\r\nCorrelation ID: c-1\r\nTimestamp: 2026-10-26 19:00:00Z",
         "error_codes":[7000215],"trace_id":"t-1","correlation_id":"c-1"}
        """#.utf8)))
        #expect(body.line == "invalid_client: AADSTS7000215: Invalid client secret provided.")
        #expect(body.errorCodes == [7000215])
        let error = GraphError(.signIn(status: 401, body: body, text: nil), access: .application)
        #expect(error.message() == """
            Sign-in failed: HTTP 401 Unauthorized
            invalid_client: AADSTS7000215: Invalid client secret provided.
            Trace ID: t-1
            Correlation ID: c-1
            The client secret is wrong. Copy the secret’s Value (not its Secret ID) from Entra under App registrations › Certificates & secrets.
            """)
    }

    @Test("Sign-in hints for an expired secret, an unknown app and an unknown tenant",
          arguments: [(7000222, "has expired"), (700016, "No app with this client ID"), (90002, "tenant wasn’t found"),
                      (900023, "tenant wasn’t found"), (50034, "Check the tenant ID, the client ID and the client secret.")])
    func signInHints(code: Int, phrase: String) {
        #expect(GraphError.signInHint(status: 400, codes: [code]).contains(phrase))
    }
}

@Suite("Graph permissions")
struct GraphPermissionTests {
    @Test("Every call the apps make has its permission", arguments: [
        ("GET", "me", Graph.Permission.userRead),
        ("GET", "organization", .organizationRead),
        ("GET", "organization/abc", .serviceConfigRead),
        ("GET", "deviceManagement/applePushNotificationCertificate", .serviceConfigRead),
        ("GET", "deviceManagement/depOnboardingSettings", .serviceConfigRead),
        ("GET", "deviceManagement/configurationPolicies/1/settings", .configurationRead),
        ("PUT", "deviceManagement/configurationPolicies/1", .configurationReadWrite),
        ("POST", "deviceManagement/deviceCompliancePolicies/1/scheduleActionsForRules", .configurationReadWrite),
        ("POST", "deviceManagement/assignmentFilters", .configurationReadWrite),
        ("GET", "deviceManagement/configurationSettings/abc", .configurationRead),
        ("DELETE", "deviceManagement/deviceCustomAttributeShellScripts/1", .scriptsReadWrite),
        ("GET", "deviceAppManagement/mobileApps", .appsRead),
        ("POST", "deviceAppManagement/mobileApps/1/microsoft.graph.mobileLobApp/contentVersions", .appsReadWrite),
        ("GET", "groups", .groupRead),
        ("POST", "groups", .groupReadWrite),
        ("GET", "deviceManagement/managedDevices", .managedDevicesRead),
        ("DELETE", "deviceManagement/managedDevices/1", .managedDevicesReadWrite),
        ("POST", "deviceManagement/managedDevices/1/syncDevice", .managedDevicesPrivileged),
        ("POST", "deviceManagement/managedDevices/1/wipe", .managedDevicesPrivileged),
    ])
    func table(method: String, path: String, permission: Graph.Permission) {
        #expect(Graph.Permission.required(method: method, path: path) == permission)
    }

    @Test("Calls outside the table have none; the organization's application name differs")
    func outside() {
        #expect(Graph.Permission.required(method: "GET", path: "users") == nil)
        #expect(Graph.Permission.organizationRead.name(for: .delegated) == "User.Read")
        #expect(Graph.Permission.organizationRead.name(for: .application) == "Organization.Read.All")
        #expect(Graph.Permission.all.count == Set(Graph.Permission.all).count)
    }
}

@Suite("Graph calls never recorded")
struct GraphSensitiveTests {
    @Test("An upload's commit, recovery keys and LAPS passwords", arguments: [
        "/beta/deviceAppManagement/mobileApps/a1/microsoft.graph.macOSPkgApp/contentVersions/1/files/f1/commit",
        "/beta/deviceAppManagement/mobileApps/a1/microsoft.graph.mobileLobApp/contentVersions/1/files/f1/commit",
        "/v1.0/deviceManagement/managedDevices/d1/getFileVaultKey",
        "/v1.0/informationProtection/bitlocker/recoveryKeys/k1",
        "/v1.0/directory/deviceLocalCredentials/d1",
    ])
    func sensitive(path: String) {
        #expect(SensitiveRequests.isSensitive(path: path))
    }

    @Test("The rest of an upload is recorded as usual")
    func notSensitive() {
        #expect(!SensitiveRequests.isSensitive(path: "/beta/deviceAppManagement/mobileApps/a1/microsoft.graph.mobileLobApp/contentVersions"))
        #expect(!SensitiveRequests.isSensitive(path: "/beta/deviceAppManagement/mobileApps/a1/microsoft.graph.mobileLobApp/contentVersions/1/files/f1"))
    }

    @Test("A commit's failure answer is withheld too")
    @MainActor
    func commitWithheld() async throws {
        let log = ActivityLog()
        let server = MockServer { _ in .json(400, #"{"error":{"code":"BadRequest","message":"encryptionKey ABC is wrong"}}"#) }
        _ = await graphError {
            try await graphClient(server, log: log).post("deviceAppManagement/mobileApps/a1/microsoft.graph.macOSPkgApp/contentVersions/1/files/f1/commit",
                                                        version: .beta, body: Data(#"{"fileEncryptionInfo":{"encryptionKey":"ABC"}}"#.utf8))
        }
        let entry = try #require(log.entries.first)
        #expect(entry.request?.contentsWithheld == true)
        #expect(!ActivityLogExport.transcript(of: entry).contains("ABC"))
    }
}
