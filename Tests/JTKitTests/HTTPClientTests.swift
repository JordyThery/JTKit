import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

@Suite("HTTP client")
@MainActor
struct HTTPClientTests {
    private let base = URL(string: "https://us.api.jamfcloud.com")!

    private func makeClient(
        _ server: MockServer,
        log: ActivityLog = ActivityLog(),
        tokens: (any BearerTokenSource)? = FixedToken("tok"),
        sleeps: SleepLog = SleepLog(),
        permits: @escaping @Sendable (HTTPRequest) -> Bool = { _ in true },
        pathMapping: PathMapping = .none,
        writeSpacing: Duration = .zero,
        random: Double = 0,
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> HTTPClient {
        HTTPClient(baseURL: base, tokens: tokens,
                   recorder: RequestRecorder(session: server.session, log: log),
                   headers: ["X-Environment-Id": "env-1"], permits: permits, pathMapping: pathMapping,
                   writeSpacing: writeSpacing,
                   sleep: { try await sleeps.sleep($0) }, random: { random }, now: { now })
    }

    @Test("Requests carry the token, the app’s headers, Accept, and a strictly encoded query")
    func headersAndQuery() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        _ = try await makeClient(server).send(HTTPRequest(
            path: "device-groups/v1/device-groups",
            query: [URLQueryItem(name: "filter", value: #"deviceType=="COMPUTER""#)]))
        let sent = try #require(server.requests.first)
        #expect(sent.header("Authorization") == "Bearer tok")
        #expect(sent.header("X-Environment-Id") == "env-1")
        #expect(sent.header("Accept") == "application/json")
        #expect(sent.path == "/device-groups/v1/device-groups")
        #expect(sent.url.absoluteString.hasSuffix("filter=deviceType%3D%3D%22COMPUTER%22"))
    }

    @Test("A request’s JSON filter reaches the recorder")
    func recordedJSON() async throws {
        let server = MockServer { _ in .json(200, #"{"keep":1,"drop":2}"#) }
        let log = ActivityLog()
        let response = try await makeClient(server, log: log).send(HTTPRequest(
            path: "api/x", recordsBodies: true,
            recordedJSON: { ($0 as? [String: Any])?.filter { $0.key == "keep" } ?? $0 }))
        #expect(String(decoding: response.data, as: UTF8.self).contains("drop"))
        let body = try #require(log.entries.first?.request?.responseBody)
        #expect(body.contains("keep") && !body.contains("drop"))
    }

    @Test("Classic API paths ask for XML")
    func classicXML() async throws {
        let server = MockServer { _ in .json(200, "<a/>") }
        _ = try await makeClient(server).send(HTTPRequest(method: "PUT", path: "proclassic/categories/id/1", body: Data("<a/>".utf8)))
        let sent = try #require(server.requests.first)
        #expect(sent.header("Accept") == "application/xml")
        #expect(sent.header("Content-Type") == "application/xml")
    }

    @Test("A 401 gets a new token and one more try; a second 401 is thrown")
    func unauthorized() async throws {
        let calls = Counter()
        let server = MockServer { _ in calls.next() == 1 ? .json(401, "{}") : .json(200, "{}") }
        let tokens = FixedToken("old", "new")
        _ = try await makeClient(server, tokens: tokens).send(HTTPRequest(path: "x"))
        #expect(server.requests.map { $0.header("Authorization") } == ["Bearer old", "Bearer new"])
        #expect(tokens.forgotten.value == 1)

        let always = MockServer { _ in .json(401, "{}") }
        do {
            _ = try await makeClient(always).send(HTTPRequest(path: "x"))
            Issue.record("Expected a failure")
        } catch let error as HTTPError {
            #expect(error.status == 401)
        }
        #expect(always.requests.count == 2)
    }

    @Test("429 is retried for every method, honoring Retry-After in seconds")
    func rateLimit() async throws {
        let calls = Counter()
        let server = MockServer { _ in calls.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "3"]) : .json(201, "{}") }
        let sleeps = SleepLog()
        let response = try await makeClient(server, sleeps: sleeps).send(HTTPRequest(method: "POST", path: "blueprints/v1/blueprints"))
        #expect(response.status == 201)
        #expect(sleeps.recorded == [.seconds(3)])
    }

    @Test("Retry-After as an HTTP date, and no wait longer than 120 s")
    func retryAfterDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000) // Fri, 15 Jan 2027 08:00:00 GMT
        #expect(RetryRules.retryAfter("Fri, 15 Jan 2027 08:00:12 GMT", now: now) == 12)
        #expect(RetryRules.retryAfter("Friday, 15-Jan-27 08:00:30 GMT", now: now) == 30)
        #expect(RetryRules.retryAfter("Fri, 15 Jan 2027 07:00:00 GMT", now: now) == 0)
        #expect(RetryRules.retryAfter(" 7 ", now: now) == 7)
        #expect(RetryRules.retryAfter("soon", now: now) == nil)
        #expect(RetryRules.retryAfter(nil, now: now) == nil)
    }

    @Test("A long Retry-After is capped at 120 s")
    func longestWait() async throws {
        let calls = Counter()
        let server = MockServer { _ in calls.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "600"]) : .json(200, "{}") }
        let sleeps = SleepLog()
        _ = try await makeClient(server, sleeps: sleeps).send(HTTPRequest(path: "x"))
        #expect(sleeps.recorded == [.seconds(120)])
    }

    @Test("Without Retry-After the wait doubles, with a little randomness, up to 4 attempts")
    func backoff() async throws {
        let server = MockServer { _ in .json(429, "{}") }
        let sleeps = SleepLog()
        await #expect(throws: HTTPError.self) {
            _ = try await makeClient(server, sleeps: sleeps, random: 1).send(HTTPRequest(path: "x"))
        }
        #expect(server.requests.count == 4)
        #expect(sleeps.recorded == [.seconds(1.5), .seconds(2.5), .seconds(4.5)])
        #expect(RetryRules.standard.backoff(afterAttempt: 10, random: 1) == 120)
    }

    @Test("Server errors are retried for reads and edits marked safe, never for other edits")
    func serverErrors() async throws {
        func failingOnce() -> MockServer {
            let calls = Counter()
            return MockServer { _ in calls.next() == 1 ? .json(503, "{}") : .json(200, "{}") }
        }
        let read = failingOnce()
        _ = try await makeClient(read).send(HTTPRequest(path: "x"))
        #expect(read.requests.count == 2)

        let create = failingOnce()
        await #expect(throws: HTTPError.self) {
            _ = try await makeClient(create).send(HTTPRequest(method: "POST", path: "x"))
        }
        #expect(create.requests.count == 1)

        let safeEdit = failingOnce()
        _ = try await makeClient(safeEdit).send(HTTPRequest(method: "PUT", path: "x", repeating: .safe))
        #expect(safeEdit.requests.count == 2)
    }

    @Test("One repeat policy: the old two flags map onto it")
    @available(*, deprecated)
    func repeatPolicy() {
        #expect(HTTPRequest(path: "x").repeating == .standard)
        #expect(HTTPRequest(method: "PUT", path: "x", safeToRepeat: true).repeating == .safe)
        #expect(HTTPRequest(method: "DELETE", path: "x", safeToRepeat: true, notFoundAfterRepeatIsDone: true).repeating == .safeNotFoundIsDone)
        var request = HTTPRequest(method: "DELETE", path: "x")
        request.notFoundAfterRepeatIsDone = true
        #expect(request.repeating == .safeNotFoundIsDone && request.safeToRepeat)
        request.notFoundAfterRepeatIsDone = false
        #expect(request.repeating == .safe)
        request.safeToRepeat = false
        #expect(request.repeating == .standard && !request.isRepeatable)
        #expect(HTTPRequest(path: "x").isRepeatable)
    }

    @Test("Short network drops are retried for reads only")
    func networkDrops() async throws {
        func droppingOnce() -> MockServer {
            let calls = Counter()
            return MockServer { _ in
                if calls.next() == 1 { throw URLError(.networkConnectionLost) }
                return .json(200, "{}")
            }
        }
        let read = droppingOnce()
        _ = try await makeClient(read).send(HTTPRequest(path: "x"))
        #expect(read.requests.count == 2)

        let write = droppingOnce()
        do {
            _ = try await makeClient(write).send(HTTPRequest(method: "POST", path: "x"))
            Issue.record("Expected a failure")
        } catch let HTTPError.transport(_, _, code, _) {
            #expect(code == .networkConnectionLost)
        }
        #expect(write.requests.count == 1)
    }

    @Test("Each wait is written to the activity log")
    func waitsAreLogged() async throws {
        let calls = Counter()
        let server = MockServer { _ in calls.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "12"]) : .json(200, "{}") }
        let log = ActivityLog()
        _ = try await makeClient(server, log: log).send(HTTPRequest(path: "device-groups/v1/device-groups"))
        let wait = try #require(log.entries.first { $0.category == "Retry" })
        #expect(wait.note == "HTTP 429: waiting 12 s, attempt 2 of 4.")
        #expect(wait.isWarning)
        #expect(log.entries.map(\.category) == ["API", "Retry", "API"])
        #expect(log.entries.last?.request?.attempt == 2)
    }

    @Test("Canceling stops a wait at once, and nothing more is sent")
    func cancelDuringWait() async throws {
        let server = MockServer { _ in .json(429, "{}", headers: ["Retry-After": "100"]) }
        let log = ActivityLog()
        let client = HTTPClient(baseURL: base, tokens: nil, recorder: RequestRecorder(session: server.session, log: log))
        let task = Task { try await client.send(HTTPRequest(path: "x")) }
        while !log.entries.contains(where: { $0.category == "Retry" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(server.requests.count == 1)
        #expect(log.entries.last?.note == "Canceled while waiting.")
    }

    @Test("A request the app marks as withholding its contents is recorded like a sensitive call")
    func withheldContents() async throws {
        let server = MockServer { _ in .json(409, "<p>Error: Serial number SERIAL-1 is invalid</p>") }
        let log = ActivityLog()
        let client = HTTPClient(baseURL: base, tokens: nil, recorder: RequestRecorder(session: server.session, log: log))
        _ = try? await client.send(HTTPRequest(method: "POST", path: "JSSResource/licensedsoftware/id/0",
                                               body: Data("<serial_number_1>SERIAL-1</serial_number_1>".utf8),
                                               recordsBodies: true, withholdsContents: true))

        let entry = try #require(log.entries.first)
        #expect(entry.status == 409)
        let details = try #require(entry.request)
        #expect(details.contentsWithheld)
        #expect(details.requestBody == nil && details.responseBody == nil)
        #expect(details.requestHeaders.isEmpty && details.responseHeaders.isEmpty)
        #expect(!"\(entry)".contains("SERIAL-1"))
    }

    @Test("Requests not on the app’s list never reach the network, and are logged")
    func refused() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let log = ActivityLog()
        let client = makeClient(server, log: log, permits: { $0.method == "GET" })
        await #expect(throws: HTTPError.self) {
            _ = try await client.send(HTTPRequest(method: "DELETE", path: "blueprints/v1/blueprints/x"))
        }
        #expect(server.requests.isEmpty)
        let entry = try #require(log.entries.first)
        #expect(entry.category == "Blocked")
        #expect(entry.isWarning)
    }

    @Test("Unsafe paths are always refused", arguments: [
        "../x", "a/../b", "a/./b", "a//b", "a%2Fb", "%2e%2e/x", "a%5Cb", "%zz", "a b", "a?b=c", "",
    ])
    func unsafePaths(path: String) async throws {
        #expect(!RequestPath.isSafe(path))
        let server = MockServer { _ in .json(200, "{}") }
        await #expect(throws: HTTPError.self) { _ = try await makeClient(server).send(HTTPRequest(path: path)) }
        #expect(server.requests.isEmpty)
    }

    @Test("Harmless paths pass")
    func safePaths() {
        #expect(RequestPath.isSafe("/blueprints/v1/blueprints/a%20b/deploy"))
        #expect(RequestPath.isSafe("proclassic/osxconfigurationprofiles/id/12"))
    }

    @Test("Jamf Pro without the gateway: pro/ and proclassic/ map; other paths are refused")
    func jamfProDirect() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let client = makeClient(server, pathMapping: .jamfProDirect)
        _ = try await client.send(HTTPRequest(path: "pro/v1/jamf-pro-version"))
        _ = try await client.send(HTTPRequest(path: "proclassic/sites"))
        #expect(server.requests.map(\.path) == ["/api/v1/jamf-pro-version", "/JSSResource/sites"])
        do {
            _ = try await client.send(HTTPRequest(path: "blueprints/v1/blueprints"))
            Issue.record("Expected a refusal")
        } catch let HTTPError.invalidURL(message) {
            #expect(message.contains("Platform API gateway"))
        }
    }

    @Test("Writes are spaced apart")
    func writeSpacing() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let sleeps = SleepLog()
        let client = makeClient(server, sleeps: sleeps, writeSpacing: .seconds(10))
        _ = try await client.send(HTTPRequest(method: "POST", path: "x"))
        _ = try await client.send(HTTPRequest(method: "POST", path: "x"))
        _ = try await client.send(HTTPRequest(path: "x"))
        #expect(sleeps.recorded.count == 1)
        #expect(sleeps.recorded.allSatisfy { $0 > .seconds(5) && $0 <= .seconds(10) })
    }

    @Test("A base address with a path keeps it")
    func basePath() throws {
        let server = MockServer { _ in .json(200, "{}") }
        let client = HTTPClient(baseURL: URL(string: "https://jamf.example.com/tenant/")!, tokens: nil,
                                recorder: RequestRecorder(session: server.session, log: nil))
        #expect(try client.url(for: HTTPRequest(path: "/api/x")).absoluteString == "https://jamf.example.com/tenant/api/x")
    }

    @Test("By default a redirect is followed only to HTTPS on the same host")
    func defaultRedirectRule() async throws {
        let server = MockServer { request in
            request.url.host() == "us.api.jamfcloud.com"
                ? .redirect(to: URL(string: "https://elsewhere.example/x")!)
                : .json(200, "{}")
        }
        let client = HTTPClient(baseURL: base, tokens: FixedToken("tok"),
                                recorder: RequestRecorder(session: server.session, log: nil))
        do {
            _ = try await client.send(HTTPRequest(path: "x"))
            Issue.record("The redirect was followed")
        } catch let error as HTTPError {
            #expect(error.status == 307)
        }
        #expect(server.requests.allSatisfy { $0.url.host() == "us.api.jamfcloud.com" })
    }

    @Test("An error answer’s cookies are redacted, and \"\\(error)\" shows no header value or body")
    func errorHidesCookies() async throws {
        let server = MockServer { _ in
            .json(403, #"{"message":"no"}"#, headers: ["Set-Cookie": "session=abc123secretcookie; Path=/", "X-Request-Id": "r-1"])
        }
        do {
            _ = try await makeClient(server).send(HTTPRequest(path: "x"))
            Issue.record("Expected an error")
        } catch let error as HTTPError {
            guard case let .status(response, _, _, _) = error else { Issue.record("\(error)"); return }
            #expect(response.header("Set-Cookie") == Redaction.placeholder)
            #expect(response.header("X-Request-Id") == "r-1")
            for text in ["\(error)", String(reflecting: error), "\(response)"] {
                #expect(!text.contains("abc123secretcookie"), "\(text)")
            }
            #expect("\(error)".contains("HTTP 403"))
        }
        let ok = MockServer { _ in .json(200, "{}", headers: ["Set-Cookie": "kept=1"]) }
        #expect(try await makeClient(ok).send(HTTPRequest(path: "x")).header("Set-Cookie") == "kept=1", "a success comes as it came")
    }

    @Test("A request waiting for a turn stops at once when canceled, and doesn’t hold up the others")
    func cancelWaitingForTurn() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let gate = Gate()
        let client = HTTPClient(baseURL: base, tokens: GatedToken(gate: gate),
                                recorder: RequestRecorder(session: server.session, log: nil), maxConcurrent: 1)
        let first = Task { try await client.send(HTTPRequest(path: "first")) }
        try await Task.sleep(for: .milliseconds(100))
        let waiting = Task { try await client.send(HTTPRequest(path: "waiting")) }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        gate.open()
        _ = try await first.value
        _ = try await client.send(HTTPRequest(path: "third"))
        #expect(server.requests.map(\.path) == ["/first", "/third"])
    }
}

/// Opens once; everyone waiting goes on.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let all = waiting
        waiting = []
        lock.unlock()
        all.forEach { $0.resume() }
    }
}

/// A token that only comes once the gate is open.
private struct GatedToken: BearerTokenSource {
    let gate: Gate
    func token() async throws -> String {
        await gate.wait()
        return "tok"
    }
    func forgetToken() async {}
}
