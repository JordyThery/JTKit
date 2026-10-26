import Foundation

/// Sends one request, times it, redacts it and adds an entry to the activity
/// log. No retries: that is `HTTPClient`'s job, on top of this. Apps' own
/// clients (Intune, Apple, Jamf School, GitHub) send through this until JTKit
/// has their calls; only the line that sends the request changes.
///
/// What an entry records, the same in every app:
/// - method, full address (secret query parameters redacted), status,
///   duration, attempt, and the request and response headers, redacted;
/// - request bodies never, and response bodies only for errors (status 400
///   and up), unless the request is marked safe (`recordsBodies`). Bodies
///   can carry secrets that no key list finds, e.g. a Wi-Fi password inside
///   a configuration profile. A recorded error answer also gets the free-text
///   cleaning the on-screen message gets (`Redaction.text`), so a secret
///   inside the server's message (`client_secret=…`, `Bearer …`) is hidden too;
/// - for sensitive calls (`SensitiveRequests`), only method, path, status and
///   duration;
/// - bodies over 256 KB are not recorded; recorded text is cut at 20,000
///   characters.
public nonisolated struct RequestRecorder: Sendable {
    public static let maximumRecordedBodySize = 256 * 1024
    public static let maximumTextLength = 20_000

    public let session: URLSession
    let log: ActivityLog?
    /// The entry's source tag, e.g. "API".
    public var category: String
    /// The service, e.g. "Jamf Platform API".
    public var service: String?
    /// The connection's name.
    public var connection: String?

    /// - Parameters:
    ///   - log: where entries go; nil records nothing (previews).
    public init(
        session: URLSession = .shared,
        log: ActivityLog?,
        category: String = "API",
        service: String? = nil,
        connection: String? = nil
    ) {
        self.session = session
        self.log = log
        self.category = category
        self.service = service
        self.connection = connection
    }

    /// Sends the request and records it.
    ///
    /// - Parameters:
    ///   - category: this entry's source tag, e.g. "Sign-in"; the recorder's by default.
    ///   - attempt, maxAttempts: shown as "Attempt 2 of 4".
    ///   - recordsBodies: record both bodies, also of a success. Only for
    ///     requests the app knows carry nothing secret.
    ///   - recordedJSON: trims a JSON body before it is redacted and recorded
    ///     (see `HTTPRequest.recordedJSON`); what is returned is unchanged.
    ///   - redirects: what to do when the server redirects.
    ///   - recordsOnlyFailures: add an entry only when the request fails (an
    ///     error, or status 400 and up), e.g. for the many blocks of one
    ///     upload that the app sums up in one entry of its own.
    /// - Throws: `CancellationError` when cancelled, otherwise the session's error.
    public func send(
        _ request: URLRequest,
        category: String? = nil,
        attempt: Int = 1,
        of maxAttempts: Int = 1,
        recordsBodies: Bool = false,
        recordedJSON: RecordedJSONFilter? = nil,
        redirects: RedirectRule = .follow,
        recordsOnlyFailures: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        let date = Date()
        let started = ContinuousClock.now
        let delegate = redirects == .follow ? nil : RedirectDelegate(rule: redirects)
        let context = Context(request: request, category: category ?? self.category, date: date,
                              attempt: attempt, maxAttempts: maxAttempts, recordsBodies: recordsBodies,
                              recordedJSON: recordedJSON, recordsOnlyFailures: recordsOnlyFailures)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: delegate)
        } catch {
            if Self.isCancellation(error) {
                await record(context, duration: started.elapsedSeconds, cancelled: true)
                throw CancellationError()
            }
            await record(context, duration: started.elapsedSeconds, error: error)
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            let error = URLError(.badServerResponse)
            await record(context, duration: started.elapsedSeconds, error: error)
            throw error
        }
        await record(context, duration: started.elapsedSeconds, response: http, data: data)
        return (data, http)
    }

    /// Downloads the answer to a temporary file, as `URLSession.download`
    /// does, and records the request. The downloaded contents are never
    /// recorded; an error answer (status 400 and up) is, as with `send`.
    /// The caller moves or deletes the file.
    /// - Throws: `CancellationError` when cancelled, otherwise the session's error.
    public func download(
        _ request: URLRequest,
        category: String? = nil,
        attempt: Int = 1,
        of maxAttempts: Int = 1,
        redirects: RedirectRule = .follow
    ) async throws -> (URL, HTTPURLResponse) {
        let date = Date()
        let started = ContinuousClock.now
        let delegate = redirects == .follow ? nil : RedirectDelegate(rule: redirects)
        let context = Context(request: request, category: category ?? self.category, date: date,
                              attempt: attempt, maxAttempts: maxAttempts, recordsBodies: false,
                              recordedJSON: nil, recordsOnlyFailures: false, isDownload: true)
        let file: URL
        let response: URLResponse
        do {
            (file, response) = try await session.download(for: request, delegate: delegate)
        } catch {
            if Self.isCancellation(error) {
                await record(context, duration: started.elapsedSeconds, cancelled: true)
                throw CancellationError()
            }
            await record(context, duration: started.elapsedSeconds, error: error)
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: file)
            let error = URLError(.badServerResponse)
            await record(context, duration: started.elapsedSeconds, error: error)
            throw error
        }
        // Only an error answer is read back, to be recorded like any other.
        let errorAnswer = http.statusCode >= 400 ? (try? Data(contentsOf: file)) ?? Data() : Data()
        await record(context, duration: started.elapsedSeconds, response: http, data: errorAnswer)
        return (file, http)
    }

    /// Adds an entry that isn't a request, e.g. a wait before a retry, a
    /// refused request or the summary of an upload, with this recorder's
    /// service and connection.
    public func note(
        _ operation: String,
        _ detail: String,
        note: String,
        category: String? = nil,
        duration: TimeInterval? = nil,
        isWarning: Bool = false,
        failed: Bool = false
    ) async {
        guard let log else { return }
        let entry = ActivityLogEntry(
            category: category ?? self.category, operation: operation, detail: detail, duration: duration, note: note,
            failedWithoutStatus: failed, isWarning: isWarning, service: service, connection: connection,
            identifiers: IdentifierMasker.identifiers(inPath: detail) + IdentifierMasker.identifiers(inText: note)
        )
        await log.append(entry)
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // MARK: - Recording

    private struct Context {
        let request: URLRequest
        let category: String
        let date: Date
        let attempt: Int
        let maxAttempts: Int
        let recordsBodies: Bool
        let recordedJSON: RecordedJSONFilter?
        var recordsOnlyFailures = false
        var isDownload = false
    }

    private func record(
        _ context: Context,
        duration: TimeInterval,
        response: HTTPURLResponse? = nil,
        data: Data = Data(),
        error: (any Error)? = nil,
        cancelled: Bool = false
    ) async {
        guard let log else { return }
        if context.recordsOnlyFailures {
            let failed = error != nil || (response?.statusCode ?? 0) >= 400
            guard failed, !cancelled else { return }
        }
        let entry = Self.entry(context: context, duration: duration, response: response, data: data,
                               error: error, cancelled: cancelled, service: service, connection: connection)
        await log.append(entry)
    }

    private static func entry(
        context: Context,
        duration: TimeInterval,
        response: HTTPURLResponse?,
        data: Data,
        error: (any Error)?,
        cancelled: Bool,
        service: String?,
        connection: String?
    ) -> ActivityLogEntry {
        let request = context.request
        let method = request.httpMethod ?? "GET"
        let url = request.url
        let sensitive = url.map { SensitiveRequests.isSensitive(path: $0.path(percentEncoded: true)) } ?? false
        let redactedURL = url.map(Redaction.url) ?? ""
        let path = url?.path(percentEncoded: true) ?? ""
        let query = url?.query(percentEncoded: true).map { "?" + Redaction.formFields($0) } ?? ""

        let status = response?.statusCode
        let errorText = error.map { Redaction.text($0.localizedDescription) }
        var note: String?
        if cancelled {
            note = "Cancelled"
        } else if let errorText {
            note = errorText
        } else if let status, status >= 400 {
            note = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        }

        if sensitive {
            var bare = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            bare?.percentEncodedQuery = nil
            return ActivityLogEntry(
                category: context.category, operation: method, detail: path, status: status,
                duration: duration, note: note, failedWithoutStatus: error != nil,
                service: service, connection: connection,
                request: ActivityRequestDetails(url: bare?.string ?? "", attempt: context.attempt,
                                                maxAttempts: context.maxAttempts, error: errorText,
                                                contentsWithheld: true),
                identifiers: IdentifierMasker.identifiers(inPath: path),
                date: context.date
            )
        }

        var identifiers = IdentifierMasker.identifiers(inPath: path + query)
        var bodyNotes = [String]()

        var requestBody: String?
        if let original = request.httpBody, !original.isEmpty {
            if context.recordsBodies, let body = trimmed(original, by: context.recordedJSON) {
                let recorded = recordedBody(body, contentType: request.value(forHTTPHeaderField: "Content-Type"), name: "request")
                requestBody = recorded.text
                if let note = recorded.note { bodyNotes.append(note) }
                if recorded.text != nil { identifiers += IdentifierMasker.identifiers(inBody: body) }
            } else {
                bodyNotes.append(context.recordsBodies ? "Request body not recorded: not JSON." : "Request body not recorded.")
            }
        }

        var responseBody: String?
        var responseHeaders = [HTTPHeader]()
        if let response {
            let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String { result[key] = "\(pair.value)" }
            }
            responseHeaders = Redaction.headers(headers)
            if context.isDownload && response.statusCode < 400 {
                bodyNotes.append("Downloaded file not recorded.")
            } else if !data.isEmpty {
                if context.recordsBodies || response.statusCode >= 400,
                   let body = trimmed(data, by: context.recordedJSON) {
                    let recorded = recordedBody(body, contentType: response.value(forHTTPHeaderField: "Content-Type"), name: "response",
                                                cleansFreeText: response.statusCode >= 400)
                    responseBody = recorded.text
                    if let note = recorded.note { bodyNotes.append(note) }
                    if recorded.text != nil { identifiers += IdentifierMasker.identifiers(inBody: body) }
                } else {
                    bodyNotes.append(context.recordsBodies || response.statusCode >= 400
                                     ? "Response body not recorded: not JSON." : "Response body not recorded.")
                }
            }
        }

        return ActivityLogEntry(
            category: context.category, operation: method, detail: path + query, status: status,
            duration: duration, note: note, failedWithoutStatus: error != nil,
            service: service, connection: connection,
            request: ActivityRequestDetails(
                url: redactedURL, attempt: context.attempt, maxAttempts: context.maxAttempts,
                requestHeaders: Redaction.headers(request.allHTTPHeaderFields ?? [:]),
                requestBody: requestBody, responseHeaders: responseHeaders, responseBody: responseBody,
                error: errorText, bodyNote: bodyNotes.isEmpty ? nil : bodyNotes.joined(separator: " ")
            ),
            identifiers: IdentifierMasker.unique(identifiers + IdentifierMasker.identifiers(inText: errorText ?? "")),
            date: context.date
        )
    }

    /// The body as the app's filter leaves it, for recording only. Without
    /// a filter, or over the recording limit (not recorded anyway), the body
    /// is left as it is. With a filter, a body that isn't JSON can't be
    /// trimmed, so it isn't recorded at all (nil).
    static func trimmed(_ data: Data, by filter: RecordedJSONFilter?) -> Data? {
        guard let filter, data.count <= maximumRecordedBodySize else { return data }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let shaped = try? JSONSerialization.data(withJSONObject: filter(object), options: [.fragmentsAllowed])
        else { return nil }
        return shaped
    }

    /// - Parameter cleansFreeText: also clean the text as a whole
    ///   (`Redaction.text`), not only by key, as for the on-screen message.
    static func recordedBody(_ data: Data, contentType: String?, name: String,
                             cleansFreeText: Bool = false) -> (text: String?, note: String?) {
        guard data.count <= maximumRecordedBodySize else {
            let size = Int64(data.count).formatted(.byteCount(style: .file))
            return (nil, "Not recorded: the \(name) body is \(size).")
        }
        guard var text = Redaction.body(data, contentType: contentType) else { return (nil, nil) }
        if cleansFreeText { text = Redaction.text(text) }
        return (truncated(text), nil)
    }

    static func truncated(_ text: String) -> String {
        guard text.count > maximumTextLength else { return text }
        return String(text.prefix(maximumTextLength)) + "\n… truncated"
    }
}

/// Trims parsed JSON before it is recorded: gets a dictionary, array or
/// value as `JSONSerialization` reads it, and returns what may be recorded.
public typealias RecordedJSONFilter = @Sendable (Any) -> Any

/// Requests whose contents are never recorded, in every app: they carry a
/// device secret (Checkpoint's unlock token, erase PIN, FileVault recovery
/// key, lock PIN, Recovery Lock password and LAPS password). Matched on the
/// path, for Jamf Pro directly (`/api/…`) and through the Platform API
/// gateway (`/pro/…`).
public nonisolated enum SensitiveRequests {
    nonisolated(unsafe) private static let patterns: [Regex<Substring>] = [
        /(?i)\/(?:api|pro)\/v\d+\/mobile-devices\/[^\/]+\/detail\/?$/,
        /(?i)\/(?:api|pro)\/v\d+\/computers-inventory\/[^\/]+\/(?:erase|filevault|view-device-lock-pin|view-recovery-lock-password)\/?$/,
        /(?i)\/(?:api|pro)\/v\d+\/local-admin-password\/.+\/password\/?$/,
    ]

    public static func isSensitive(path: String) -> Bool {
        patterns.contains { path.firstMatch(of: $0) != nil }
    }
}

/// What a client does when the server redirects.
public nonisolated enum RedirectRule: Sendable, Hashable {
    /// Follow every redirect (URLSession's default).
    case follow
    /// Follow only to HTTPS on the same host and port, so credentials never
    /// go elsewhere (Jamf Deployer).
    case sameHostHTTPSOnly
    /// Never follow; the redirect itself comes back as the answer (JamfMigrator).
    case refuse

    public func allows(from original: URL?, to target: URL?) -> Bool {
        switch self {
        case .follow:
            return true
        case .refuse:
            return false
        case .sameHostHTTPSOnly:
            guard let original, let target, target.scheme?.lowercased() == "https",
                  let from = original.host()?.lowercased(), from == target.host()?.lowercased() else { return false }
            return original.port == target.port
        }
    }
}

private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let rule: RedirectRule

    init(rule: RedirectRule) {
        self.rule = rule
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        rule.allows(from: task.originalRequest?.url, to: request.url) ? request : nil
    }
}

extension ContinuousClock.Instant {
    nonisolated var elapsedSeconds: TimeInterval {
        let elapsed = ContinuousClock.now - self
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
