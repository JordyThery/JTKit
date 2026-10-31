import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

private let environmentID = "e77c1408-10c8-4007-b177-abc9157fbcaa"
private let gateway = URL(string: "https://eu.api.jamfcloud.com")!

/// A client on a fake server, signed in with a fixed token; retries don’t wait.
private func platformClient(
    _ server: MockServer,
    log: ActivityLog? = nil,
    scope: JamfPlatform.Client.Scope = .environment(environmentID),
    errorStatus: JamfPlatform.Client.ErrorStatus = .thrown,
    permits: @escaping @Sendable (HTTPRequest) -> Bool = { _ in true }
) throws -> JamfPlatform.Client {
    try JamfPlatform.Client(baseURL: gateway, scope: scope, tokens: FixedToken("tok"),
                            recorder: RequestRecorder(session: server.session, log: log, service: "Jamf Platform API"),
                            errorStatus: errorStatus, permits: permits, sleep: { _ in }, random: { 0 })
}

private func platformConnection(environment: String = environmentID, hostOverride: String = "") -> Connection {
    Connection(name: "Production", service: .jamfPlatform, region: .eu, environmentID: environment,
               hostOverride: hostOverride, clientID: "client-1")
}

/// The error a call threw, or nil.
private func thrown(_ body: @Sendable () async throws -> Void) async -> JamfPlatform.APIError? {
    do {
        try await body()
        return nil
    } catch let error as JamfPlatform.APIError {
        return error
    } catch {
        Issue.record("Not a JamfPlatform.APIError: \(error)")
        return nil
    }
}

// MARK: - Client

@Suite("Jamf Platform client")
@MainActor
struct JamfPlatformClientTests {
    @Test("Built from a connection: the region’s gateway, a sign-in, the Environment ID header")
    func fromConnection() async throws {
        let server = MockServer { $0.path == "/auth/token" ? .json(200, tokenJSON("tok-1")) : .json(200, "{}") }
        let client = try JamfPlatform.Client(connection: platformConnection(), secret: { "s3cr3t" },
                                             recorder: RequestRecorder(session: server.session, log: nil))
        _ = try await client.json("/blueprints/v1/blueprints")
        let sent = try #require(server.requests.last)
        #expect(sent.url.host() == "eu.api.jamfcloud.com")
        #expect(sent.header("X-Environment-Id") == environmentID)
        #expect(sent.header("Authorization") == "Bearer tok-1")
        #expect(server.requests.first?.bodyString.contains("client_id=client-1") == true)
    }

    @Test("A host override replaces the region’s gateway")
    func hostOverride() async throws {
        let server = MockServer { $0.path == "/auth/token" ? .json(200, tokenJSON("t")) : .json(200, "{}") }
        let client = try JamfPlatform.Client(connection: platformConnection(hostOverride: "staging.example.com"),
                                             secret: { "s" }, recorder: RequestRecorder(session: server.session, log: nil))
        _ = try await client.json("/x")
        #expect(server.requests.allSatisfy { $0.url.host() == "staging.example.com" })
    }

    @Test("An Environment ID that isn’t a UUID is refused before anything is sent")
    func invalidEnvironmentID() async {
        let server = MockServer { _ in .json(200, "{}") }
        let error = #expect(throws: JamfPlatform.APIError.self) {
            _ = try JamfPlatform.Client(connection: platformConnection(environment: "env-1"), secret: { "s" },
                                        recorder: RequestRecorder(session: server.session, log: nil))
        }
        guard case .invalidEnvironmentID("env-1")? = error?.kind else { Issue.record("Got \(String(describing: error))"); return }
        #expect(error?.message().hasPrefix("The Environment ID isn’t a UUID (8-4-4-4-12 hexadecimal characters). Copy it from Jamf Account.") == true)
        #expect(server.requests.isEmpty)
    }

    @Test("Organization scope sends no scope header; the legacy scope sends X-Tenant-Id")
    func scopes() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        _ = try await platformClient(server, scope: .organization).json("/organization/v1/environments")
        _ = try await platformClient(server, scope: .legacyTenant("tenant-9")).json("/x")
        let organization = server.requests[0]
        #expect(organization.header("X-Environment-Id") == nil && organization.header("X-Tenant-Id") == nil)
        #expect(server.requests[1].header("X-Tenant-Id") == "tenant-9")
        #expect(server.requests[1].header("X-Environment-Id") == nil)
    }

    @Test("The app’s allow-list is checked before sending")
    func allowList() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let client = try platformClient(server, permits: { $0.method == "GET" })
        let error = await thrown { _ = try await client.send(HTTPRequest(method: "DELETE", path: "/blueprints/v1/blueprints/a")) }
        guard case .refused("DELETE", "/blueprints/v1/blueprints/a")? = error?.kind else { Issue.record("Got \(String(describing: error))"); return }
        #expect(server.requests.isEmpty)
    }

    @Test("The app’s own hints come with every error the client throws, before the standard ones")
    func appHints() async throws {
        let server = MockServer { _ in .json(403, #"{"httpStatus":403,"errors":[{"code":"BAD_PERMISSIONS"}]}"#) }
        let client = try JamfPlatform.Client(
            baseURL: gateway, scope: .environment(environmentID), tokens: FixedToken("tok"),
            recorder: RequestRecorder(session: server.session, log: nil),
            hints: { $0.status == 403 ? ["This app needs blueprints:read."] : [] })
        let error = await thrown { _ = try await client.json("/blueprints/v1/blueprints") }
        let lines = error?.message().components(separatedBy: "\n") ?? []
        #expect(lines.suffix(2).first == "This app needs blueprints:read.")
        #expect(lines.last?.contains("missing a permission") == true)
    }

    @Test("With errorStatus .returned an error answer comes back as the response")
    func returnedStatus() async throws {
        let server = MockServer { _ in .json(403, #"{"httpStatus":403,"errors":[{"code":"BAD_PERMISSIONS"}]}"#) }
        let response = try await platformClient(server, errorStatus: .returned).send(HTTPRequest(path: "/pro/v1/scripts"))
        #expect(response.status == 403)
    }

    @Test("With errorStatus .returned, JTKit’s own calls still throw an error status",
          arguments: [403, 404, 409, 500])
    func ownCallsThrowOnReturningClient(status: Int) async throws {
        let server = MockServer { _ in .json(status, #"{"httpStatus":\#(status),"errors":[]}"#) }
        let client = try platformClient(server, errorStatus: .returned)
        let blueprints = JamfPlatform.Blueprints(client: client)
        let id = "6b9a3c1e-3f0e-4d5e-9c1a-0e1f2a3b4c5d"
        let calls: [(String, @Sendable () async throws -> Void)] = [
            ("deploy", { try await blueprints.deploy(id: id) }),
            ("patchSteps", { try await blueprints.patchSteps(id: id, steps: .array([])) }),
            ("patchScope", { try await blueprints.patchScope(id: id, deviceGroups: ["g"]) }),
            ("delete", { try await blueprints.delete(id: id) }),
            ("detail", { _ = try await blueprints.detail(id: id) }),
            ("json", { _ = try await client.json("/blueprints/v1/blueprints") }),
            ("setAssetTag computer", { try await client.setAssetTag("A", computerID: "1") }),
            ("setAssetTag mobile", { try await client.setAssetTag("A", mobileDeviceID: "1") }),
        ]
        for (name, call) in calls {
            let error = await thrown { try await call() }
            #expect(error?.status == status, "\(name)")
        }
    }

    @Test("A refused sign-in is thrown, also with errorStatus .returned")
    func refusedSignIn() async throws {
        let server = MockServer { _ in .json(401, #"{"error":"invalid_client","error_description":"Bad credentials"}"#) }
        let client = try JamfPlatform.Client(connection: platformConnection(), secret: { "s" },
                                             recorder: RequestRecorder(session: server.session, log: nil), errorStatus: .returned)
        let error = await thrown { try await client.signIn() }
        guard case .signIn(401, _, _)? = error?.kind else { Issue.record("Got \(String(describing: error))"); return }
        #expect(error?.hasCode("invalid_client") == true)
        #expect(error?.message().contains("Check the client ID, client secret and region") == true)
    }

    @Test("A redirect to another host isn’t followed")
    func redirectRefused() async throws {
        let server = MockServer { request in
            request.url.host() == "eu.api.jamfcloud.com"
                ? .redirect(to: URL(string: "https://elsewhere.example/blueprints/v1/blueprints")!)
                : .json(200, "{}")
        }
        let error = await thrown { _ = try await platformClient(server).json("/blueprints/v1/blueprints") }
        #expect(error?.status == 307)
        #expect(server.requests.allSatisfy { $0.url.host() == "eu.api.jamfcloud.com" })
    }

    @Test("Each attempt lands in the activity log under the Platform API")
    func logged() async throws {
        let log = ActivityLog()
        let server = MockServer { _ in .json(200, #"{"results":[]}"#) }
        _ = try await platformClient(server, log: log).json("/blueprints/v1/blueprints")
        #expect(log.entries.count == 1)
        #expect(log.entries.first?.service == "Jamf Platform API")
    }

    @Test("A Jamf Pro connection goes straight to the server: paths mapped, no scope header, Platform-only paths refused")
    func jamfProDirect() async throws {
        let server = MockServer { $0.path == "/api/oauth/token" ? .json(200, tokenJSON("pro-tok")) : .json(200, "{}") }
        let connection = Connection(name: "Lab", service: .jamfPro, serverURL: "https://lab.jamfcloud.com", clientID: "client-1")
        let client = try JamfPlatform.Client(connection: connection, secret: { "s" },
                                             recorder: RequestRecorder(session: server.session, log: nil))
        #expect(client.server == .jamfPro && client.scope == .organization)
        _ = try await client.json("pro/v1/categories")
        _ = try await client.send(HTTPRequest(path: "proclassic/policies", accept: "application/xml"))
        let paths = server.requests.map(\.path)
        #expect(paths.contains("/api/v1/categories") && paths.contains("/JSSResource/policies"))
        #expect(server.requests.allSatisfy { $0.url.host() == "lab.jamfcloud.com" && $0.header("X-Environment-Id") == nil })
        let error = await thrown { _ = try await client.json("blueprints/v1/blueprints") }
        guard case .invalidResponse? = error?.kind else { Issue.record("Got \(String(describing: error))"); return }
        #expect(error?.server == .jamfPro)
    }

    @Test("Extra headers go with every request; JTKit’s User-Agent is sent unless the app sets its own")
    func headersAndUserAgent() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let recorder = RequestRecorder(session: server.session, log: nil)
        let plain = try JamfPlatform.Client(baseURL: gateway, scope: .environment(environmentID), tokens: FixedToken("t"),
                                            recorder: recorder, headers: ["X-Extra": "1"])
        _ = try await plain.json("/x")
        #expect(server.requests[0].header("X-Extra") == "1")
        #expect(server.requests[0].header("User-Agent") == JTKit.userAgent)
        #expect(plain.recorder.session === server.session)
        let own = try JamfPlatform.Client(baseURL: gateway, scope: .environment(environmentID), tokens: FixedToken("t"),
                                          recorder: recorder, headers: ["User-Agent": "Custom/2"])
        _ = try await own.json("/x")
        #expect(server.requests[1].header("User-Agent") == "Custom/2")
    }

    @Test("A missing permission on a Jamf Pro server points to its API roles, on the Platform API to Jamf Account")
    func forbiddenHintByServer() async throws {
        let server = MockServer { _ in .json(403, #"{"httpStatus":403,"errors":[{"code":"INVALID_PRIVILEGE"}]}"#) }
        let recorder = RequestRecorder(session: server.session, log: nil)
        let pro = try JamfPlatform.Client(baseURL: URL(string: "https://lab.jamfcloud.com")!, scope: .organization, server: .jamfPro,
                                          tokens: FixedToken("t"), recorder: recorder)
        let proError = await thrown { _ = try await pro.json("pro/v1/scripts") }
        #expect(proError?.message().contains("Settings › API Roles and Clients") == true)
        #expect(proError?.message().contains("Jamf Account") == false)
        let platformError = await thrown { _ = try await platformClient(server).json("pro/v1/scripts") }
        #expect(platformError?.message().contains("Check its permissions in Jamf Account") == true)
        #expect(platformError?.message().contains("API Roles and Clients") == false)
    }
}

@Suite("User-Agent")
@MainActor
struct UserAgentTests {
    @Test("AppName/version, without the spaces of the bundle name")
    func format() {
        #expect(JTKit.userAgent(info: ["CFBundleName": "Jamf Migrator", "CFBundleShortVersionString": "1.0.5"]) == "JamfMigrator/1.0.5")
        #expect(JTKit.userAgent(info: ["CFBundleName": "Checkpoint"]) == "Checkpoint/0")
    }

    @Test("The recorder adds it to a request without one, e.g. an image on another host, and records no body of a success")
    func recorder() async throws {
        let log = ActivityLog()
        let server = MockServer { _ in .json(200, #"{"image":"bytes"}"#) }
        let recorder = RequestRecorder(session: server.session, log: log)
        _ = try await recorder.send(URLRequest(url: URL(string: "https://icons.example/abc.png")!), category: "Icons")
        #expect(server.requests.first?.header("User-Agent") == JTKit.userAgent)
        let entry = try #require(log.entries.first)
        #expect(entry.request?.responseBody == nil)
        #expect(entry.request?.requestHeaders.contains { $0.name == "User-Agent" && $0.value == JTKit.userAgent } == true)
    }
}

// MARK: - Errors

@Suite("Jamf Platform errors")
@MainActor
struct JamfPlatformErrorTests {
    private func error(_ status: Int, _ body: String, duringSignIn: Bool = false) -> JamfPlatform.APIError {
        JamfPlatform.APIError(HTTPError.status(HTTPResponse(status: status, headers: ["Content-Type": "application/json"], data: Data(body.utf8)),
                                           method: "PATCH", path: "/blueprints/v1/blueprints/b1", duringSignIn: duringSignIn))
    }

    @Test("The gateway’s errors as one object or a list")
    func gatewayShapes() throws {
        let object = try #require(JamfPlatform.ErrorBody(data: Data(#"{"httpStatus":409,"traceId":"abc-123","errors":{"code":"DIVISION_PATCH_NOT_ALLOWED","field":null,"description":"Assigned to a division"}}"#.utf8)))
        #expect(object.httpStatus == 409 && object.traceID == "abc-123")
        #expect(object.contains(.divisionPatchNotAllowed))
        let list = try #require(JamfPlatform.ErrorBody(data: Data(#"{"httpStatus":400,"errors":[{"code":"A"},{"code":"B","field":"steps"}]}"#.utf8)))
        #expect(list.errors.map(\.code) == ["A", "B"])
    }

    @Test("The benchmarks’ and the sign-in’s shapes")
    func otherShapes() throws {
        let benchmarks = try #require(JamfPlatform.ErrorBody(data: Data(#"{"message":"title already exists","error":"Conflict","statusCode":409,"logref":"log-9"}"#.utf8)))
        #expect(benchmarks.errors == [.init(code: "Conflict", description: "title already exists")])
        #expect(benchmarks.traceID == "log-9" && benchmarks.httpStatus == 409)
        let oauth = try #require(JamfPlatform.ErrorBody(data: Data(#"{"error":"invalid_client","error_description":"Bad credentials"}"#.utf8)))
        #expect(oauth.errors == [.init(code: "invalid_client", description: "Bad credentials")])
    }

    @Test("Other answers aren’t mistaken for errors", arguments: [#"{"results":[]}"#, "<html>busy</html>", "", "[1]"])
    func notErrors(body: String) {
        #expect(JamfPlatform.ErrorBody(data: Data(body.utf8)) == nil)
    }

    @Test("One format: status line, CODE (field): description, Trace ID, hints")
    func format() {
        let message = error(400, #"{"httpStatus":400,"traceId":"t-1","errors":[{"code":"INVALID_FIELD","field":"name","description":"must not be blank"},{"code":"INVALID_REQUEST_CONTEXT_ID","description":"Bad context"}]}"#).message()
        #expect(message == """
            HTTP 400 Bad Request
            INVALID_FIELD (name): must not be blank
            INVALID_REQUEST_CONTEXT_ID: Bad context
            Trace ID: t-1
            The Environment ID doesn’t belong to this integration. Copy it from the integration’s details in Jamf Account.
            """)
    }

    @Test("The app’s own hints come first, and a hint is never shown twice")
    func appHints() {
        let failure = error(409, #"{"httpStatus":409,"errors":[{"code":"DIVISION_PATCH_NOT_ALLOWED","description":"Assigned"}]}"#)
        let standard = "This Blueprint is assigned to a division and can’t be changed through the API."
        let lines = failure.message(appHints: ["Reload the Blueprint.", standard]).components(separatedBy: "\n")
        #expect(lines.suffix(2) == ["Reload the Blueprint.", standard])
        #expect(failure.hasCode(.divisionPatchNotAllowed))
    }

    @Test("Standard hints for a missing permission, a refused sign-in, limits and server errors")
    func hints() {
        #expect(error(403, #"{"httpStatus":403,"errors":[{"code":"BAD_PERMISSIONS"}]}"#).message().contains("missing a permission"))
        #expect(error(401, #"{"error":"invalid_client"}"#, duringSignIn: true).message().hasPrefix("Sign-in failed: HTTP 401"))
        #expect(error(429, "{}").standardHints.first?.contains("Wait a minute") == true)
        #expect(error(503, "{}").standardHints.first?.contains("Try again in a few minutes") == true)
        #expect(error(404, "{}").standardHints.isEmpty)
    }

    @Test("Secrets in a server’s text never reach the message")
    func redacted() {
        let failure = JamfPlatform.APIError(HTTPError.status(
            HTTPResponse(status: 400, headers: ["Content-Type": "text/plain"], data: Data("bad request client_secret=abc123 Bearer tok-999".utf8)),
            method: "GET", path: "/x", duringSignIn: false))
        let message = failure.message()
        #expect(message.contains("bad request"))
        #expect(!message.contains("abc123") && !message.contains("tok-999"))
    }

    @Test("The report adds the request")
    func report() {
        #expect(error(404, #"{"httpStatus":404,"errors":[]}"#).report.hasPrefix("Request: PATCH /blueprints/v1/blueprints/b1\nHTTP 404"))
    }

    @Test("The Trace ID stays unmasked in the bug-report export; a serial number doesn’t")
    func traceIDInExport() async throws {
        let log = ActivityLog()
        let traceID = "4bf92f3577b34da6a3ce929d0e0e4736"
        let server = MockServer { _ in
            .json(500, #"{"httpStatus":500,"traceId":"\#(traceID)","errors":[{"code":"INTERNAL","description":"Device C02XK1JHJG5H failed"}],"serialNumber":"C02XK1JHJG5H"}"#)
        }
        let failure = await thrown { _ = try await platformClient(server, log: log).json("/devices/v1/devices") }
        #expect(failure?.traceID == traceID)
        #expect(failure?.message().contains("Trace ID: \(traceID)") == true)
        let export = ActivityLogExport.text(log.entries, masked: true)
        #expect(export.contains(traceID))
        #expect(!export.contains("C02XK1JHJG5H"))
    }
}

// MARK: - Paging

@Suite("Jamf Platform paging")
struct JamfPlatformPagingTests {
    private func pages(_ pages: [JamfPlatform.Page<Int>], pageSize: Int = 2, maxPages: Int = 10) async throws -> (items: [Int], fetched: Int) {
        let fetched = Counter()
        let items = try await JamfPlatform.allPages(of: "/x", pageSize: pageSize, maxPages: maxPages) { index in
            _ = fetched.next()
            return pages[index]
        }
        return (items, fetched.value)
    }

    @Test("hasNext decides when the server sends it")
    func hasNext() async throws {
        let result = try await pages([.init(results: [1, 2], totalCount: 99, hasNext: true), .init(results: [3], hasNext: false)])
        #expect(result.items == [1, 2, 3])
    }

    @Test("Without hasNext, the total count decides; unreadable results count towards it")
    func totalCount() async throws {
        let result = try await pages([.init(results: [1], totalCount: 4, unreadableCount: 1), .init(results: [3, 4], totalCount: 4)])
        #expect(result.items == [1, 3, 4])
        #expect(result.fetched == 2)
    }

    @Test("Without either, a short page or an empty one ends the list")
    func shortPage() async throws {
        #expect(try await pages([.init(results: [1, 2]), .init(results: [3])]).fetched == 2)
        #expect(try await pages([.init(results: [1, 2]), .init(results: [])]).fetched == 2)
    }

    @Test("Reaching the page limit is an error, not a quiet cut-off")
    func limit() async {
        let full = JamfPlatform.Page(results: [1, 2], hasNext: true)
        let error = await #expect(throws: JamfPlatform.APIError.self) {
            _ = try await pages([full, full, full], maxPages: 3)
        }
        guard case .pageLimitReached("/x", 3)? = error?.kind else { Issue.record("Got \(String(describing: error))"); return }
        #expect(error?.message().contains("incomplete") == true)
    }
}

// MARK: - Polling

/// A clock that only moves when the poller waits.
private final class PollClock: @unchecked Sendable {
    let start = ContinuousClock.now
    private let elapsed = Locked(Duration.zero)
    private let waits = Locked<[Duration]>([])

    var now: ContinuousClock.Instant { start + elapsed.value }
    var recorded: [Duration] { waits.value }
    var total: Duration { elapsed.value }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        waits.withLock { $0.append(duration) }
        elapsed.withLock { $0 += duration }
    }

    var poller: JamfPlatform.Poller {
        JamfPlatform.Poller(sleep: { try await self.sleep($0) }, now: { self.now })
    }
}

@Suite("Jamf Platform polling")
struct JamfPlatformPollingTests {
    @Test("The interval starts at 2 s and grows ×1.5 to 10 s")
    func intervals() {
        let policy = JamfPlatform.PollingPolicy.standard
        #expect((1...6).map { policy.interval(afterCheck: $0).seconds } == [2, 3, 4.5, 6.75, 10, 10])
        #expect(policy.timeLimit == .seconds(300))
    }

    @Test("Stops as soon as the job is done, reporting each value")
    func finishes() async throws {
        let clock = PollClock()
        let checks = Counter()
        let seen = Locked<[Int]>([])
        let outcome = try await clock.poller.poll(
            check: { checks.next() }, isDone: { $0 == 3 },
            progress: { value in seen.withLock { $0.append(value) } })
        #expect(outcome.isFinished && outcome.value == 3)
        #expect(seen.value == [1, 2, 3])
        #expect(clock.recorded == [.seconds(2), .seconds(3)])
    }

    @Test("Gives up at the time limit with the last value, checking once at the limit")
    func timesOut() async throws {
        let clock = PollClock()
        let outcome = try await clock.poller.poll(check: { "pending" }, isDone: { _ in false })
        guard case .timedOut(last: "pending"?) = outcome else { Issue.record("Got \(outcome)"); return }
        #expect(clock.total == .seconds(300))
    }

    @Test("A shorter limit an app sets is kept")
    func shorterLimit() async throws {
        let clock = PollClock()
        var poller = clock.poller
        poller.policy.timeLimit = .seconds(60)
        _ = try await poller.poll(check: { 0 }, isDone: { _ in false })
        #expect(clock.total == .seconds(60))
    }

    @Test("Errors that mean \"not ready yet\" are checked again; others stop the wait")
    func notReadyYet() async throws {
        struct NotYet: Error {}
        struct Broken: Error {}
        let clock = PollClock()
        let checks = Counter()
        let outcome = try await clock.poller.poll(
            check: { () async throws -> Int in
                let n = checks.next()
                if n < 3 { throw NotYet() }
                return n
            },
            isDone: { _ in true }, isNotReadyYet: { $0 is NotYet })
        #expect(outcome.value == 3)
        await #expect(throws: Broken.self) {
            _ = try await clock.poller.poll(check: { () async throws -> Int in throw Broken() }, isDone: { _ in true },
                                            isNotReadyYet: { $0 is NotYet })
        }
    }

    @Test("Cancel stops it at once, also during a wait")
    func cancel() async throws {
        let poller = JamfPlatform.Poller(policy: .init(firstInterval: .seconds(60)))
        let task = Task { try await poller.poll(check: { 1 }, isDone: { _ in false }) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

// MARK: - Permission check

@Suite("Jamf Platform permission check")
struct JamfPlatformPermissionTests {
    @Test("Only a 403 counts as a missing permission; 404, other statuses and no answer are told apart")
    func classifies() async throws {
        let server = MockServer { request in
            switch request.path {
            case "/allowed": return .json(200, #"{"results":[]}"#)
            case "/denied": return .json(403, #"{"httpStatus":403,"errors":[{"code":"BAD_PERMISSIONS"}]}"#)
            case "/missing": return .json(404, "{}")
            case "/broken": return .json(400, "{}")
            default: throw URLError(.badServerResponse)
            }
        }
        let checks = ["allowed", "denied", "missing", "broken", "offline"].map {
            JamfPlatform.PermissionCheck($0, path: "/\($0)", permission: "\($0):read")
        }
        let results = try await platformClient(server).checkPermissions(checks)
        #expect(results.map(\.check.name) == ["allowed", "denied", "missing", "broken", "offline"])
        #expect(Array(results.map(\.result).prefix(4)) == [.allowed, .missingPermission, .notFound, .failed(status: 400)])
        guard case .unreachable = results[4].result else { Issue.record("Got \(results[4].result)"); return }
        #expect(server.requests.allSatisfy { $0.method == "GET" && $0.queryValue("page-size") == "1" })
    }

    @Test("A missing permission says what to add")
    func hints() {
        #expect(JamfPlatform.PermissionCheck.blueprintsRead.hint == "Add the “blueprints:read” permission to the API integration in Jamf Account.")
        let pro = JamfPlatform.PermissionCheck("Read scripts", path: "/pro/v1/scripts", permission: "scripts:read", jamfProPrivilege: "Read Scripts")
        #expect(pro.jamfProHint == "Add the “Read Scripts” privilege to the API role in Jamf Pro under Settings › API Roles and Clients.")
        #expect(pro.hint(on: .jamfPro) == pro.jamfProHint)
        #expect(pro.hint(on: .platformAPI) == pro.hint)
        #expect(JamfPlatform.PermissionCheck.blueprintsRead.hint(on: .jamfPro).contains("privilege for “Read Blueprints”"))
    }

    @Test("Several missing permissions: one sentence, each name once, in the right place")
    func severalHints() {
        let scripts = JamfPlatform.PermissionCheck("Scripts", path: "/pro/v1/scripts", permission: "scripts:read", jamfProPrivilege: "Read Scripts")
        let policies = JamfPlatform.PermissionCheck("Policies", path: "/proclassic/policies", permission: "policies:read", jamfProPrivilege: "Read Policies")
        let groups = JamfPlatform.PermissionCheck("Groups", path: "/pro/v1/groups", permission: "device-groups:read", jamfProPrivilege: "Read Scripts")
        typealias Check = JamfPlatform.PermissionCheck
        #expect(Check.hint(for: [], on: .jamfPro) == nil)
        #expect(Check.hint(for: [scripts], on: .platformAPI)
                == "Add the “scripts:read” permission to the API integration in Jamf Account.")
        #expect(Check.hint(for: [scripts, policies, groups], on: .platformAPI)
                == "Add the “scripts:read”, “policies:read” and “device-groups:read” permissions to the API integration in Jamf Account.")
        #expect(Check.hint(for: [scripts, policies, groups], on: .jamfPro)
                == "Add the “Read Scripts” and “Read Policies” privileges to the API role in Jamf Pro under Settings › API Roles and Clients.")
        #expect(Check.hint(for: [policies], on: .jamfPro, signIn: .usernamePassword)
                == "Add the “Read Policies” privilege to the user account in Jamf Pro under Settings › User Accounts and Groups.")
        #expect(Check.hint(for: [.blueprintsRead], on: .jamfPro)
                == "Add the privilege for “Read Blueprints” to the API role in Jamf Pro under Settings › API Roles and Clients.")
        #expect(Check.hint(for: [scripts, .blueprintsRead], on: .jamfPro)
                == "Add the privileges for “Scripts” and “Read Blueprints” to the API role in Jamf Pro under Settings › API Roles and Clients.")
    }

    @Test("Test Connection’s message names what is missing, and why a check couldn’t run")
    func problem() throws {
        #expect(JamfPlatform.PermissionProblem([(.blueprintsRead, .allowed), (.deviceGroupsRead, .allowed)]) == nil)

        let missing = try #require(JamfPlatform.PermissionProblem([
            (.blueprintsRead, .missingPermission), (.deviceGroupsRead, .notFound),
        ]))
        #expect(missing.errorDescription == "Signed in, but the API integration is missing a permission: blueprints:read.")
        #expect(missing.failureReason == """
            Add the “blueprints:read” permission to the API integration in Jamf Account.
            Read Device Groups couldn’t be checked: not found (HTTP 404)
            """)

        let unchecked = try #require(JamfPlatform.PermissionProblem([
            (.blueprintsRead, .failed(status: 500)), (.deviceGroupsRead, .unreachable("offline")),
        ]))
        #expect(unchecked.missing.isEmpty)
        #expect(unchecked.errorDescription == "Signed in, but not every permission could be checked.")
        #expect(unchecked.failureReason == "Read Blueprints couldn’t be checked: HTTP 500\nRead Device Groups couldn’t be checked: offline")
    }
}

// MARK: - Blueprints

private let blueprintID = "0a1b2c3d-4444-4444-8444-0123456789ab"
private let blueprintPath = "/blueprints/v1/blueprints/\(blueprintID)"

private func blueprintJSON(state: String = "DEPLOYED", started: String = "2026-10-02T09:30:00Z", job: String = "SUCCEEDED",
                           updated: String = "2026-10-02T09:30:00.222222Z", extra: String = "") -> String {
    #"{"id":"\#(blueprintID)","name":"iPad apps","description":null,"updated":"\#(updated)",\#(extra)"scope":{"deviceGroups":["g1"]},"deploymentState":{"state":"\#(state)","lastDeployment":{"started":"\#(started)","state":"\#(job)"}},"steps":[{"name":"S","components":[{"identifier":"com.jamf.ddm-strict","configuration":{"ratio":1.0}},{"identifier":"other","configuration":{}}]}]}"#
}

@Suite("Jamf Platform Blueprints")
@MainActor
struct JamfPlatformBlueprintTests {
    private func blueprints(_ server: MockServer) throws -> JamfPlatform.Blueprints {
        JamfPlatform.Blueprints(client: try platformClient(server))
    }

    @Test("The list follows every page and sends sort and search")
    func list() async throws {
        let server = MockServer { request in
            request.queryValue("page") == "0"
                ? .json(200, #"{"totalCount":3,"results":[{"id":"a","name":"A"},{"id":"b"}]}"#)
                : .json(200, #"{"totalCount":3,"results":[{"id":"c","name":"C","deploymentState":{"state":"SOMETHING_NEW"}}]}"#)
        }
        let list = try await blueprints(server).list(search: "iPad", pageSize: 2)
        #expect(list.map(\.id) == ["a", "b", "c"])
        #expect(list[1].name == "(unnamed)")
        #expect(list[2].deploymentState?.state == .other("SOMETHING_NEW"))
        #expect(server.requests.map { $0.queryValue("page") } == ["0", "1"])
        #expect(server.requests.allSatisfy { $0.queryValue("search") == "iPad" && $0.queryValue("sort") == "created:desc" && $0.queryValue("page-size") == "2" })
    }

    @Test("A detail keeps the exact bytes and reads scope, division and components")
    func detail() async throws {
        let text = blueprintJSON(extra: #""divisionId":"d-1","#)
        let server = MockServer { _ in .json(200, text) }
        let detail = try await blueprints(server).detail(id: blueprintID)
        #expect(detail.rawData == Data(text.utf8))
        #expect(detail.json.serialized() == Data(text.utf8))
        #expect(detail.scopeDeviceGroups == ["g1"])
        #expect(detail.isDivisionLocked)
        #expect(detail.components.map(\.identifier) == ["com.jamf.ddm-strict", "other"])
        #expect(detail.components[1].path.pathString == "steps[0].components[1]")
        #expect(detail.overview.deploymentState?.lastDeploymentState == "SUCCEEDED")
        #expect(detail.overview.updatedDate != nil)
        let newer = try JamfPlatform.BlueprintDetail(data: Data(blueprintJSON(updated: "2026-10-03T10:00:00Z").utf8))
        #expect(detail.isUnchanged(in: detail))
        #expect(!detail.isUnchanged(in: newer))
    }

    @Test("An ID can’t reach another resource: one with a slash is refused before sending")
    func escapedID() async throws {
        #expect(JamfPlatform.pathSegment("a/b c") == "a%2Fb%20c")
        let server = MockServer { _ in .json(200, #"{"id":"a/b"}"#) }
        let api = try blueprints(server)
        let error = await thrown { _ = try await api.detail(id: "../a/b") }
        guard case .refused? = error?.kind else { Issue.record("Got \(String(describing: error))"); return }
        #expect(server.requests.isEmpty)
    }

    @Test("Changing steps sends only the steps as merge-patch, and is repeated after a server error")
    func patchSteps() async throws {
        let attempts = Counter()
        let server = MockServer { _ in attempts.next() == 1 ? .json(503, "{}") : MockResponse(status: 204, body: Data()) }
        let steps = try #require(try LosslessJSON(string: blueprintJSON())["steps"])
        try await blueprints(server).patchSteps(id: blueprintID, steps: steps)
        let patch = try #require(server.requests.last)
        #expect(server.requests.count == 2)
        #expect(patch.method == "PATCH" && patch.path == blueprintPath)
        #expect(patch.header("Content-Type") == "application/merge-patch+json")
        #expect(patch.bodyString == #"{"steps":"# + steps.serializedString() + "}")
    }

    @Test("Changing scope sends only the scope; an empty scope is refused before sending")
    func patchScope() async throws {
        let server = MockServer { _ in MockResponse(status: 204, body: Data()) }
        try await blueprints(server).patchScope(id: blueprintID, deviceGroups: ["g1", "g2"])
        #expect(server.requests.first?.bodyString == #"{"scope":{"deviceGroups":["g1","g2"]}}"#)
        await #expect(throws: JamfPlatform.APIError.self) { try await blueprints(server).patchScope(id: blueprintID, deviceGroups: []) }
        #expect(server.requests.count == 1)
    }

    @Test("Create sends name, scope and steps, returns the ID, and is never repeated after a server error")
    func create() async throws {
        let server = MockServer { _ in .json(201, #"{"id":"new-1","href":"https://eu.api.jamfcloud.com/blueprints/v1/blueprints/new-1"}"#) }
        let id = try await blueprints(server).create(name: "n", description: nil, deviceGroups: ["g1"], steps: [.object(.init())])
        #expect(id == "new-1")
        let body = try LosslessJSON(data: try #require(server.requests.first).body)
        #expect(body.objectValue?.keys == ["name", "scope", "steps"])

        let failing = MockServer { _ in .json(503, "{}") }
        await #expect(throws: JamfPlatform.APIError.self) {
            _ = try await blueprints(failing).create(name: "n", description: "d", deviceGroups: ["g"], steps: [])
        }
        #expect(failing.requests.count == 1)
        await #expect(throws: JamfPlatform.APIError.self) {
            _ = try await blueprints(failing).create(name: "n", description: nil, deviceGroups: [], steps: [])
        }
        #expect(failing.requests.count == 1, "No device group: nothing sent")
    }

    @Test("Deploy is repeated after a 429, never after a server error")
    func deploy() async throws {
        let limited = Counter()
        let server = MockServer { _ in limited.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "1"]) : MockResponse(status: 202, body: Data()) }
        try await blueprints(server).deploy(id: blueprintID)
        #expect(server.requests.map(\.path) == [blueprintPath + "/deploy", blueprintPath + "/deploy"])
        let failing = MockServer { _ in .json(503, "{}") }
        await #expect(throws: JamfPlatform.APIError.self) { try await blueprints(failing).deploy(id: blueprintID) }
        #expect(failing.requests.count == 1)
    }

    @Test("A missing report means no report yet; delete sends DELETE")
    func reportAndDelete() async throws {
        let server = MockServer { request in
            request.method == "DELETE" ? MockResponse(status: 204, body: Data()) : .json(404, #"{"httpStatus":404,"errors":[]}"#)
        }
        #expect(try await blueprints(server).report(id: blueprintID) == nil)
        try await blueprints(server).delete(id: blueprintID)
        #expect(server.requests.last?.method == "DELETE")
        let counts = MockServer { _ in .json(200, #"{"succeeded":3,"failed":1,"pending":2}"#) }
        #expect(try await blueprints(counts).report(id: blueprintID) == .init(succeeded: 3, failed: 1, pending: 2))
    }

    @Test("isUnchanged needs the same Blueprint and both updated times; without them only an identical answer counts")
    func unchangedNeedsIDAndDates() throws {
        func detail(_ text: String) throws -> JamfPlatform.BlueprintDetail {
            try JamfPlatform.BlueprintDetail(data: Data(text.utf8))
        }
        let base = try detail(blueprintJSON())
        let other = try detail(blueprintJSON().replacingOccurrences(of: blueprintID, with: "11111111-2222-3333-4444-555555555555"))
        #expect(!base.isUnchanged(in: other), "another Blueprint with the same updated time")
        let undated = try detail(blueprintJSON().replacingOccurrences(of: #""updated":"2026-10-02T09:30:00.222222Z","#, with: ""))
        #expect(!base.isUnchanged(in: undated))
        #expect(!undated.isUnchanged(in: base))
        #expect(undated.isUnchanged(in: try detail(blueprintJSON().replacingOccurrences(of: #""updated":"2026-10-02T09:30:00.222222Z","#, with: ""))))
        let changedUndated = try detail(blueprintJSON(state: "NOT_DEPLOYED").replacingOccurrences(of: #""updated":"2026-10-02T09:30:00.222222Z","#, with: ""))
        #expect(!undated.isUnchanged(in: changedUndated), "two missing times aren’t the same time")
    }

    @Test("A delete repeated after a server error counts a 404 as done; a first 404 is still an error")
    func deleteNotFoundAfterRepeat() async throws {
        let calls = Counter()
        let server = MockServer { _ in calls.next() == 1 ? .json(503, "{}") : .json(404, #"{"httpStatus":404,"errors":[]}"#) }
        try await blueprints(server).delete(id: blueprintID)
        #expect(server.requests.map(\.method) == ["DELETE", "DELETE"])

        let missing = MockServer { _ in .json(404, #"{"httpStatus":404,"errors":[]}"#) }
        let gone = try blueprints(missing)
        let error = await thrown { try await gone.delete(id: blueprintID) }
        #expect(error?.status == 404)
    }

    @Test("Deploy and watch follows the new deployment, not the previous one")
    func deployAndWatch() async throws {
        let gets = Counter()
        let server = MockServer { request in
            switch (request.method, request.path) {
            case ("POST", blueprintPath + "/deploy"): return MockResponse(status: 202, body: Data())
            case ("GET", blueprintPath + "/report"): return .json(200, #"{"succeeded":1,"failed":0,"pending":0}"#)
            default:
                switch gets.next() {
                // 1: the read before the POST; 2: the previous deployment is still the latest
                case 1, 2: return .json(200, blueprintJSON())
                case 3: return .json(200, blueprintJSON(started: "2026-10-23T09:00:00Z", job: "DEPLOYING"))
                default: return .json(200, blueprintJSON(started: "2026-10-23T09:00:00Z", job: "SUCCEEDED"))
                }
            }
        }
        let api = try blueprints(server)
        let previous = try await api.startDeployment(id: blueprintID)
        #expect(previous == "2026-10-02T09:30:00Z")
        let clock = PollClock()
        let states = Locked<[String?]>([])
        let outcome = try await api.watchDeployment(id: blueprintID, previousStart: previous, poller: clock.poller) { status in
            states.withLock { $0.append(status.jobState) }
        }
        #expect(outcome.isFinished && outcome.value?.didSucceed == true)
        #expect(outcome.value?.jobStarted == "2026-10-23T09:00:00Z")
        #expect(outcome.value?.report == .init(succeeded: 1, failed: 0, pending: 0))
        #expect(states.value == [nil, "DEPLOYING", "SUCCEEDED"])
        #expect(clock.recorded == [.seconds(2), .seconds(3)])
        #expect(server.requests.filter { $0.method == "POST" }.count == 1)
    }

    @Test("The watch gives up after 5 minutes with the last status")
    func watchTimesOut() async throws {
        let server = MockServer { request in
            request.path.hasSuffix("/report") ? .json(404, "{}") : .json(200, blueprintJSON(started: "2026-10-23T09:00:00Z", job: "PENDING"))
        }
        let clock = PollClock()
        let outcome = try await blueprints(server).watchDeployment(id: blueprintID, previousStart: "2026-10-02T09:30:00Z", poller: clock.poller)
        #expect(!outcome.isFinished)
        #expect(outcome.value?.jobState == "PENDING")
        #expect(outcome.value?.report == nil)
        #expect(clock.total == .seconds(300))
    }
}

// MARK: - Device groups

@Suite("Jamf Platform device groups")
struct JamfPlatformDeviceGroupTests {
    @Test("Every page, an encoded filter, sorted by name; unknown types and missing counts are kept")
    func list() async throws {
        let server = MockServer { request in
            request.queryValue("page") == "0"
                ? .json(200, #"{"hasNext":true,"results":[{"id":"1","name":"Macs","deviceType":"COMPUTER","groupType":"SMART","memberCount":12}]}"#)
                : .json(200, #"{"hasNext":false,"results":[{"id":"2","name":"TVs","deviceType":"TV","groupType":"DYNAMIC"}]}"#)
        }
        let groups = try await platformClient(server).deviceGroups(filter: JamfPlatform.RSQL.equals("deviceType", "COMPUTER"))
        #expect(groups.map(\.id) == ["1", "2"])
        #expect(groups[0].deviceType == .computer && groups[0].groupType == .smart && groups[0].memberCount == 12)
        #expect(groups[1].deviceType == .other("TV") && groups[1].groupType == .other("DYNAMIC") && groups[1].memberCount == nil)
        #expect(groups[1].deviceType.displayName == "Tv")
        #expect(server.requests.allSatisfy { $0.path == "/device-groups/v1/device-groups" && $0.queryValue("sort") == "name" })
        #expect(server.requests.first?.url.absoluteString.contains("filter=deviceType%3D%3D%22COMPUTER%22") == true)
    }

    @Test("Quotes and backslashes in a filter value are escaped")
    func rsql() {
        #expect(JamfPlatform.RSQL.equals("name", #"Lab "A"\B"#) == #"name=="Lab \"A\"\\B""#)
    }

    @Test("Without a filter, none is sent")
    func noFilter() async throws {
        let server = MockServer { _ in .json(200, #"{"results":[]}"#) }
        _ = try await platformClient(server).deviceGroups()
        #expect(server.requests.first?.queryValue("filter") == nil)
    }
}

// MARK: - Environments

@Suite("Jamf Platform environments")
struct JamfPlatformEnvironmentTests {
    @Test("Read from either shape, sorted by name, without a scope header")
    func list() async throws {
        let server = MockServer { request in
            if request.path == "/auth/token" { return .json(200, tokenJSON("t")) }
            return .json(200, #"{"results":[{"id":"b-id","name":"Production"},{"environmentId":"a-id","name":"Lab"},{"name":"no id"}]}"#)
        }
        // no Environment ID needed to list them
        let environments = try await JamfPlatform.environments(for: platformConnection(environment: ""), secret: { "s" },
                                                               recorder: RequestRecorder(session: server.session, log: nil))
        #expect(environments == [.init(id: "a-id", name: "Lab"), .init(id: "b-id", name: "Production")])
        let call = try #require(server.requests.last)
        #expect(call.path == "/organization/v1/environments")
        #expect(call.header("X-Environment-Id") == nil)

        // only `results` is read: an answer without it is unexpected
        let other = MockServer { _ in .json(200, #"{"environments":[{"id":"x"}]}"#) }
        let error = await thrown { _ = try await platformClient(other, scope: .organization).environments() }
        guard case .invalidResponse? = error?.kind else { Issue.record("Got \(String(describing: error))"); return }
    }

    @Test("An integration scoped to one environment: said plainly, with where to find the ID", arguments: [401, 403, 404])
    func scopedToOneEnvironment(status: Int) async throws {
        let server = MockServer { _ in .json(status, #"{"httpStatus":\#(status),"errors":[{"code":"BAD_PERMISSIONS"}]}"#) }
        let error = await thrown { _ = try await platformClient(server, scope: .organization).environments() }
        guard case .cannotListEnvironments? = error?.kind else { Issue.record("Got \(String(describing: error))"); return }
        let message = error?.message() ?? ""
        #expect(message.contains("scoped to one environment"))
        #expect(message.contains("Jamf Account (account.jamf.com)"))
        #expect(message.contains("copy the Environment ID"))
    }

    @Test("A refused sign-in stays a sign-in error")
    func refusedSignIn() async throws {
        let server = MockServer { _ in .json(401, #"{"error":"invalid_client"}"#) }
        let error = await thrown {
            _ = try await JamfPlatform.environments(for: platformConnection(), secret: { "s" },
                                                    recorder: RequestRecorder(session: server.session, log: nil))
        }
        guard case .signIn(401, _, _)? = error?.kind else { Issue.record("Got \(String(describing: error))"); return }
    }

    @Test("The editor’s picker: a typed ID in the list is chosen, one not in it isn’t")
    func editorChoice() {
        let list = [JamfPlatform.Environment(id: "E77C1408-10C8-4007-B177-ABC9157FBCAA", name: "Production")]
        #expect(EnvironmentListState.choice(for: " \(environmentID) ", in: list) == list[0].id)
        #expect(EnvironmentListState.choice(for: "something-else", in: list) == "")
        #expect(EnvironmentListState.choice(for: "", in: list) == "")
    }

    @Test("The editor loads the list only with a client ID and a secret, typed or stored")
    func editorCanLoad() {
        let connection = platformConnection(environment: "")
        #expect(EnvironmentListState.canLoad(connection, typedSecret: "s", hasStoredSecret: false))
        #expect(EnvironmentListState.canLoad(connection, typedSecret: nil, hasStoredSecret: true))
        #expect(!EnvironmentListState.canLoad(connection, typedSecret: "", hasStoredSecret: false))
        var noClient = connection
        noClient.clientID = " "
        #expect(!EnvironmentListState.canLoad(noClient, typedSecret: "s", hasStoredSecret: true))
        var pro = connection
        pro.service = .jamfPro
        #expect(!EnvironmentListState.canLoad(pro, typedSecret: "s", hasStoredSecret: true))
    }
}

@Suite("Names before 1.0: the old names still mean the same types")
struct RenamedTypeTests {
    @Test("Nested like ABM’s: the token providers, errors and Intune’s device record")
    @available(*, deprecated)
    func oldNames() {
        #expect(JamfTokenProvider.self == JamfPlatform.TokenProvider.self)
        #expect(JamfPlatformError.self == JamfPlatform.APIError.self)
        #expect(EntraTokenProvider.self == Graph.TokenProvider.self)
        #expect(GraphError.self == Graph.APIError.self)
        #expect(IntuneManagedDevice.self == Graph.ManagedDevice.self)
        #expect(JamfSchoolError.self == JamfSchool.APIError.self)
        #expect(JamfPro.Match<String>.self == DeviceMatch<String>.self)
    }
}
