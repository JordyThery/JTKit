import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

@Suite("Request recorder")
@MainActor
struct RequestRecorderTests {
    private func request(_ method: String = "GET", _ address: String, body: String? = nil,
                         headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = method
        request.httpBody = body.map { Data($0.utf8) }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    @Test("A success records method, address, status, time and redacted headers, but no bodies")
    func success() async throws {
        let server = MockServer { _ in .json(200, #"{"name":"Engineers","access_token":"t"}"#) }
        let log = ActivityLog()
        let recorder = RequestRecorder(session: server.session, log: log, service: "Jamf Platform API", connection: "Sandbox")
        _ = try await recorder.send(request("POST", "https://us.api.jamfcloud.com/blueprints/v1/blueprints?page=0",
                                            body: #"{"name":"x"}"#,
                                            headers: ["Authorization": "Bearer secret-token", "Content-Type": "application/json"]),
                                    attempt: 2, of: 4)

        let entry = try #require(log.entries.first)
        #expect(entry.category == "API")
        #expect(entry.operation == "POST")
        #expect(entry.detail == "/blueprints/v1/blueprints?page=0")
        #expect(entry.status == 200)
        #expect(entry.duration != nil)
        #expect(entry.service == "Jamf Platform API")
        #expect(entry.connection == "Sandbox")
        let details = try #require(entry.request)
        #expect(details.url == "https://us.api.jamfcloud.com/blueprints/v1/blueprints?page=0")
        #expect(details.attempt == 2 && details.maxAttempts == 4)
        #expect(details.requestHeaders.first { $0.name == "Authorization" }?.value == "Bearer \(Redaction.placeholder)")
        #expect(details.requestBody == nil)
        #expect(details.responseBody == nil)
        #expect(details.bodyNote == "Request body not recorded. Response body not recorded.")
        #expect(!ActivityLogExport.transcript(of: entry).contains("secret-token"))
    }

    @Test("An error's response body is recorded, redacted, with its identifiers")
    func errorBody() async throws {
        let server = MockServer { _ in
            .json(400, #"{"errors":[{"code":"INVALID_FIELD"}],"serialNumber":"C02XK1JHJG5H","client_secret":"leak"}"#)
        }
        let log = ActivityLog()
        _ = try await RequestRecorder(session: server.session, log: log)
            .send(request("POST", "https://example.com/api/x", body: #"{"password":"p"}"#))

        let entry = try #require(log.entries.first)
        #expect(entry.isFailure)
        #expect(entry.note == "Bad Request")
        let details = try #require(entry.request)
        #expect(details.requestBody == nil, "request bodies are never recorded by default")
        let body = try #require(details.responseBody)
        #expect(body.contains("INVALID_FIELD"))
        #expect(!body.contains("leak"))
        #expect(entry.identifiers.contains(FoundIdentifier(.device, "C02XK1JHJG5H")))
    }

    @Test("A request marked safe records both bodies, also of a success")
    func optIn() async throws {
        let server = MockServer { _ in .json(200, #"{"ok":true}"#) }
        let log = ActivityLog()
        _ = try await RequestRecorder(session: server.session, log: log)
            .send(request("POST", "https://example.com/api/x", body: #"{"name":"x"}"#,
                          headers: ["Content-Type": "application/json"]), recordsBodies: true)
        let details = try #require(log.entries.first?.request)
        #expect(details.requestBody?.contains("\"name\"") == true)
        #expect(details.responseBody?.contains("\"ok\"") == true)
        #expect(details.bodyNote == nil)
    }

    @Test("Bodies over 256 KB aren't recorded; long text is cut at 20,000 characters")
    func sizeLimits() async throws {
        let large = String(repeating: "a", count: RequestRecorder.maximumRecordedBodySize + 1)
        let long = String(repeating: "b", count: 30_000)
        let responses = Locked([large, long])
        let server = MockServer { _ in
            MockResponse(status: 500, headers: ["Content-Type": "text/plain"],
                         body: Data(responses.withLock { $0.removeFirst() }.utf8))
        }
        let log = ActivityLog()
        let recorder = RequestRecorder(session: server.session, log: log)
        _ = try await recorder.send(request("GET", "https://example.com/a"))
        _ = try await recorder.send(request("GET", "https://example.com/b"))

        let first = try #require(log.entries.first?.request)
        #expect(first.responseBody == nil)
        #expect(first.bodyNote?.hasPrefix("Not recorded: the response body is") == true)
        let second = try #require(log.entries.last?.request?.responseBody)
        #expect(second.count == RequestRecorder.maximumTextLength + "\n… truncated".count)
        #expect(second.hasSuffix("… truncated"))
    }

    @Test("Sensitive calls record only method, path, status and duration",
          arguments: [
              "/api/v2/mobile-devices/12/detail",
              "/pro/v2/mobile-devices/12/detail",
              "/api/v4/computers-inventory/7/erase",
              "/api/v4/computers-inventory/7/filevault",
              "/pro/v4/computers-inventory/7/view-device-lock-pin",
              "/api/v4/computers-inventory/7/view-recovery-lock-password",
              "/api/v2/local-admin-password/abc/account/admin/password",
              "/api/v2/local-admin-password/abc/account/admin/guid-1/password",
          ])
    func sensitive(path: String) async throws {
        #expect(SensitiveRequests.isSensitive(path: path))
        let server = MockServer { _ in .json(500, #"{"unlockToken":"x","personalRecoveryKey":"y"}"#) }
        let log = ActivityLog()
        _ = try await RequestRecorder(session: server.session, log: log)
            .send(request("POST", "https://jamf.example.com\(path)?pin=123456", body: #"{"pin":"123456"}"#,
                          headers: ["Authorization": "Bearer t"]))

        let entry = try #require(log.entries.first)
        #expect(entry.detail == path)
        #expect(entry.status == 500)
        let details = try #require(entry.request)
        #expect(details.contentsWithheld)
        #expect(details.requestHeaders.isEmpty && details.responseHeaders.isEmpty)
        #expect(details.requestBody == nil && details.responseBody == nil)
        #expect(!details.url.contains("123456"))
    }

    @Test("Ordinary Jamf calls are not sensitive")
    func notSensitive() {
        #expect(!SensitiveRequests.isSensitive(path: "/api/v2/mobile-devices/12"))
        #expect(!SensitiveRequests.isSensitive(path: "/api/v1/computers-inventory/7"))
        #expect(!SensitiveRequests.isSensitive(path: "/blueprints/v1/blueprints/abc/deploy"))
    }

    @Test("No answer: the entry fails without a status and says why")
    func transportFailure() async throws {
        let server = MockServer { _ in throw URLError(.notConnectedToInternet) }
        let log = ActivityLog()
        await #expect(throws: URLError.self) {
            _ = try await RequestRecorder(session: server.session, log: log).send(request("GET", "https://example.com/a"))
        }
        let entry = try #require(log.entries.first)
        #expect(entry.isFailure)
        #expect(entry.status == nil)
        #expect(entry.request?.error != nil)
    }

    @Test("Redirect rules")
    func redirects() throws {
        let from = try #require(URL(string: "https://jamf.example.com/api/x"))
        #expect(RedirectRule.follow.allows(from: from, to: URL(string: "http://elsewhere.example/")))
        #expect(!RedirectRule.refuse.allows(from: from, to: URL(string: "https://jamf.example.com/api/y")))
        #expect(RedirectRule.sameHostHTTPSOnly.allows(from: from, to: URL(string: "https://JAMF.example.com/api/y")))
        #expect(!RedirectRule.sameHostHTTPSOnly.allows(from: from, to: URL(string: "http://jamf.example.com/api/y")))
        #expect(!RedirectRule.sameHostHTTPSOnly.allows(from: from, to: URL(string: "https://evil.example/api/y")))
        #expect(!RedirectRule.sameHostHTTPSOnly.allows(from: from, to: URL(string: "https://jamf.example.com:8443/api/y")))
    }
}
