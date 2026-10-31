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

    @Test("An error’s response body is recorded, redacted, with its identifiers")
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

    @Test("A secret inside an error’s message is hidden in the log, as on screen")
    func secretsInErrorMessage() async throws {
        let message = "invalid request client_secret=s3cr3t-value&grant_type=client_credentials, sent with Bearer eyJhbGciOi.payload.sig"
        let server = MockServer { _ in
            .json(401, #"{"error":"invalid_client","message":"\#(message)"}"#)
        }
        let log = ActivityLog()
        let (data, response) = try await RequestRecorder(session: server.session, log: log)
            .send(request("POST", "https://example.com/api/oauth/token"))

        let entry = try #require(log.entries.first)
        let body = try #require(entry.request?.responseBody)
        #expect(body.contains("invalid_client"))
        #expect(body.contains("client_secret=\(Redaction.placeholder)"))
        #expect(body.contains("Bearer \(Redaction.placeholder)"))
        let transcript = ActivityLogExport.transcript(of: entry)
        for secret in ["s3cr3t-value", "eyJhbGciOi", "payload.sig"] {
            #expect(!transcript.contains(secret))
            #expect(!ActivityLogExport.text(log.entries, masked: true).contains(secret))
            #expect(!ActivityLogExport.text(log.entries, masked: false).contains(secret))
        }
        // the same cleaning as the message shown to the user
        let shown = HTTPError.status(HTTPResponse(status: response.statusCode, data: data),
                                     method: "POST", path: "/api/oauth/token", duringSignIn: true)
        for secret in ["s3cr3t-value", "eyJhbGciOi"] {
            #expect(!(shown.errorDescription ?? "").contains(secret))
        }
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

    @Test("A request’s JSON filter trims what is recorded, not what the app receives")
    func recordedJSONFilter() async throws {
        let answer = #"{"results":[{"id":"1","general":{"name":"Lab Mac"},"localUserAccounts":[{"username":"admin"}],"certificates":[{"commonName":"cert"}]}]}"#
        let server = MockServer { _ in .json(200, answer) }
        let log = ActivityLog()
        let keep: RecordedJSONFilter = { object in
            guard var top = object as? [String: Any], let results = top["results"] as? [[String: Any]] else { return object }
            top["results"] = results.map { $0.filter { ["id", "general"].contains($0.key) } }
            return top
        }
        let (data, _) = try await RequestRecorder(session: server.session, log: log)
            .send(request("GET", "https://example.com/api/v1/computers-inventory"), recordsBodies: true, recordedJSON: keep)

        #expect(String(decoding: data, as: UTF8.self) == answer)
        let entry = try #require(log.entries.first)
        let body = try #require(entry.request?.responseBody)
        #expect(body.contains("Lab Mac"))
        #expect(!body.contains("localUserAccounts") && !body.contains("certificates") && !body.contains("admin"))
        // identifiers come from what was recorded only
        #expect(!entry.identifiers.contains { $0.value == "admin" })
    }

    @Test("The JSON filter also trims a recorded error answer")
    func recordedJSONFilterOnErrors() async throws {
        let server = MockServer { _ in .json(500, #"{"keep":"yes","drop":"no"}"#) }
        let log = ActivityLog()
        _ = try await RequestRecorder(session: server.session, log: log)
            .send(request("GET", "https://example.com/a"),
                  recordedJSON: { ($0 as? [String: Any])?.filter { $0.key == "keep" } ?? $0 })
        let body = try #require(log.entries.first?.request?.responseBody)
        #expect(body.contains("keep") && !body.contains("drop"))
    }

    @Test("With a JSON filter, an answer that isn’t JSON isn’t recorded at all")
    func recordedJSONFilterRefusesText() async throws {
        let server = MockServer { _ in
            MockResponse(status: 200, headers: ["Content-Type": "text/plain"], body: Data("owner: Jane Doe".utf8))
        }
        let log = ActivityLog()
        _ = try await RequestRecorder(session: server.session, log: log)
            .send(request("GET", "https://example.com/a"), recordsBodies: true, recordedJSON: { $0 })
        let details = try #require(log.entries.first?.request)
        #expect(details.responseBody == nil)
        #expect(details.bodyNote == "Response body not recorded: not JSON.")
    }

    @Test("Bodies over 256 KB aren’t recorded; long text is cut at 20,000 characters")
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

    @Test("Ordinary Jamf calls aren’t sensitive")
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

    // MARK: - Uploads and downloads

    private static let uploadAddress =
        "https://store.blob.core.windows.net/c/blob?sv=2019-02-02&sr=b&sig=SIGNATURE%2Bsecret%3D&se=2026-10-26&sp=rw&comp=block&blockid=YmxvY2s%3D"

    @Test("An upload’s address hides its signature, and its contents are never recorded")
    func uploadRedacted() async throws {
        let server = MockServer { _ in .json(500, #"<?xml version="1.0"?><Error><Code>InternalError</Code></Error>"#) }
        let log = ActivityLog()
        var upload = request("PUT", Self.uploadAddress)
        upload.httpBody = Data("FILE-CONTENTS".utf8)
        _ = try await RequestRecorder(session: server.session, log: log).send(upload)

        #expect(server.requests.first?.bodyString == "FILE-CONTENTS", "the contents are sent")
        let entry = try #require(log.entries.first)
        let details = try #require(entry.request)
        #expect(details.requestBody == nil)
        #expect(details.url.contains("sig=\(Redaction.placeholder)"))
        #expect(entry.detail.contains("sig=\(Redaction.placeholder)"))
        let transcript = ActivityLogExport.transcript(of: entry)
        #expect(!transcript.contains("SIGNATURE"))
        #expect(!transcript.contains("FILE-CONTENTS"))
    }

    @Test("Recording only failures: a success adds nothing, a failure adds its entry")
    func onlyFailures() async throws {
        let status = Locked(201)
        let server = MockServer { _ in .json(status.value, "") }
        let log = ActivityLog()
        let recorder = RequestRecorder(session: server.session, log: log)
        _ = try await recorder.send(request("PUT", Self.uploadAddress), recordsOnlyFailures: true)
        #expect(log.entries.isEmpty)

        status.value = 503
        _ = try await recorder.send(request("PUT", Self.uploadAddress), recordsOnlyFailures: true)
        #expect(log.entries.count == 1)
        #expect(log.entries.first?.status == 503)

        server.respond { _ in throw URLError(.networkConnectionLost) }
        await #expect(throws: URLError.self) {
            _ = try await recorder.send(self.request("PUT", Self.uploadAddress), recordsOnlyFailures: true)
        }
        #expect(log.entries.count == 2)
    }

    @Test("A note can carry a duration")
    func noteDuration() async throws {
        let log = ActivityLog()
        await RequestRecorder(session: URLSession(configuration: .ephemeral), log: log, category: "Upload").note("PUT", "app.pkg", note: "Uploaded", duration: 4.5)
        #expect(log.entries.first?.duration == 4.5)
        #expect(log.entries.first?.category == "Upload")
    }

    @Test("A download goes to a file; the file is never recorded")
    func download() async throws {
        let server = MockServer { _ in MockResponse(status: 200, headers: ["Content-Type": "application/zip"], body: Data("ZIP-CONTENTS".utf8)) }
        let log = ActivityLog()
        let (file, response) = try await RequestRecorder(session: server.session, log: log, category: "GitHub")
            .download(request("GET", "https://api.github.com/repos/o/r/zipball/main",
                              headers: ["Authorization": "Bearer ghp_secretsecretsecret"]))
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(response.statusCode == 200)
        #expect(try Data(contentsOf: file) == Data("ZIP-CONTENTS".utf8))
        let entry = try #require(log.entries.first)
        #expect(entry.category == "GitHub")
        #expect(entry.status == 200)
        #expect(entry.request?.bodyNote == "Downloaded file not recorded.")
        let transcript = ActivityLogExport.transcript(of: entry)
        #expect(!transcript.contains("ZIP-CONTENTS"))
        #expect(!transcript.contains("ghp_secret"))
    }

    @Test("A download redirected to codeload with ?token= never shows the token")
    func downloadRedirectToken() async throws {
        let codeload = try #require(URL(string: "https://codeload.github.com/o/r/legacy.zip/refs/heads/main?token=EPHEMERAL123"))
        let server = MockServer { request in
            request.url.host() == "api.github.com"
                ? .redirect(302, to: codeload)
                : MockResponse(status: 200, headers: ["Content-Type": "application/zip"], body: Data("ZIP".utf8))
        }
        let log = ActivityLog()
        let recorder = RequestRecorder(session: server.session, log: log)
        let (file, _) = try await recorder.download(request("GET", "https://api.github.com/repos/o/r/zipball/main"))
        try? FileManager.default.removeItem(at: file)
        #expect(server.requests.last?.url == codeload, "the redirect was followed")

        // the codeload address itself, recorded directly
        let (direct, _) = try await recorder.download(URLRequest(url: codeload))
        try? FileManager.default.removeItem(at: direct)

        #expect(log.entries.count == 2)
        for entry in log.entries {
            #expect(!ActivityLogExport.transcript(of: entry).contains("EPHEMERAL123"))
        }
        let directEntry = try #require(log.entries.first { $0.detail.hasPrefix("/o/r/") })
        #expect(directEntry.request?.url.hasSuffix("?token=\(Redaction.placeholder)") == true)
    }

    @Test("A download’s error answer is recorded, as with send")
    func downloadError() async throws {
        let server = MockServer { _ in .json(404, #"{"message":"Not Found"}"#) }
        let log = ActivityLog()
        let (file, response) = try await RequestRecorder(session: server.session, log: log)
            .download(request("GET", "https://api.github.com/repos/o/r/zipball/main"))
        try? FileManager.default.removeItem(at: file)
        #expect(response.statusCode == 404)
        #expect(log.entries.first?.request?.responseBody?.contains("Not Found") == true)
    }
}
