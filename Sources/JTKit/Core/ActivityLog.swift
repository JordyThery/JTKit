import Foundation
import Observation

/// One recorded operation: an HTTP request, an engine run, a deploy step.
public nonisolated struct ActivityLogEntry: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    /// Short source tag, e.g. "API", "Engine", "Export".
    public var category: String
    /// The verb: an HTTP method or an engine subcommand.
    public var operation: String
    /// The object: a URL path, a tenant name, a file.
    public var detail: String
    /// HTTP status where applicable.
    public var status: Int?
    public var duration: TimeInterval?
    public var note: String?
    /// Marks the entry failed even though it has no status, e.g. a request
    /// that never got a response. Entries with a status ≥ 400 fail anyway.
    public var failedWithoutStatus: Bool
    /// Something worth a look that isn't a failure, e.g. a wait before a
    /// retry or a refused request. Shown with a warning symbol.
    public var isWarning: Bool
    /// The service, e.g. "Jamf Platform API".
    public var service: String?
    /// The connection's name.
    public var connection: String?
    /// What was sent and received, for entries the request recorder made.
    public var request: ActivityRequestDetails?
    /// Device, user and network identifiers found in the entry, masked in the
    /// bug-report export.
    public var identifiers: [FoundIdentifier]

    public init(
        category: String,
        operation: String,
        detail: String,
        status: Int? = nil,
        duration: TimeInterval? = nil,
        note: String? = nil,
        failedWithoutStatus: Bool = false,
        isWarning: Bool = false,
        service: String? = nil,
        connection: String? = nil,
        request: ActivityRequestDetails? = nil,
        identifiers: [FoundIdentifier] = [],
        date: Date = .now
    ) {
        self.id = UUID()
        self.date = date
        self.category = category
        self.operation = operation
        self.detail = detail
        self.status = status
        self.duration = duration
        self.note = note
        self.failedWithoutStatus = failedWithoutStatus
        self.isWarning = isWarning
        self.service = service
        self.connection = connection
        self.request = request
        self.identifiers = identifiers
    }

    public var isFailure: Bool {
        guard let status else { return failedWithoutStatus }
        return status >= 400
    }

    /// Failed, or marked as a warning: what "Problems Only" shows.
    public var isProblem: Bool {
        isFailure || isWarning
    }
}

/// What the request recorder saw of one request. Secrets are redacted before
/// anything is stored here; request bodies are recorded only for requests an
/// app marks as safe, response bodies only for errors (see `RequestRecorder`).
public nonisolated struct ActivityRequestDetails: Hashable, Sendable {
    /// The full address, with secret query parameters redacted.
    public var url: String
    public var attempt: Int
    public var maxAttempts: Int
    public var requestHeaders: [HTTPHeader]
    public var requestBody: String?
    public var responseHeaders: [HTTPHeader]
    public var responseBody: String?
    /// Why the request failed without a response.
    public var error: String?
    /// A sensitive call: only method, path, status and duration are recorded.
    public var contentsWithheld: Bool
    /// Why a body is missing, e.g. "Not recorded: the body is 300 KB."
    public var bodyNote: String?

    public init(
        url: String,
        attempt: Int = 1,
        maxAttempts: Int = 1,
        requestHeaders: [HTTPHeader] = [],
        requestBody: String? = nil,
        responseHeaders: [HTTPHeader] = [],
        responseBody: String? = nil,
        error: String? = nil,
        contentsWithheld: Bool = false,
        bodyNote: String? = nil
    ) {
        self.url = url
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.error = error
        self.contentsWithheld = contentsWithheld
        self.bodyNote = bodyNote
    }
}

/// In-memory, capped activity log shown in its own window
/// (`ActivityLogWindow`). Nothing is written to disk; Clear wipes it.
/// Secrets are never logged.
@MainActor
@Observable
public final class ActivityLog {
    public private(set) var entries: [ActivityLogEntry] = []
    @ObservationIgnored private let capacity: Int

    /// - Parameter capacity: the oldest entries are dropped beyond this many.
    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    public func append(_ entry: ActivityLogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    public func clear() {
        entries.removeAll()
    }
}

// MARK: - Actions

extension ActivityLogEntry {
    /// The category of what the user asked for, as opposed to the requests
    /// it took.
    public static let actionCategory = "Action"

    /// What the user asked for, e.g. "Sent Restart to 3 devices", "Restarted
    /// iPhone over USB" or "Read the FileVault recovery key for …".
    ///
    /// - Parameters:
    ///   - devices: serial numbers, UDIDs or ECIDs the action was about,
    ///     masked in the bug-report export (also when the summary doesn't
    ///     show them).
    ///   - failed: the action didn't happen; put why in `note`.
    /// - Parameter isWarning: e.g. Apple still processing a write (step 9).
    public static func action(
        _ summary: String,
        note: String? = nil,
        failed: Bool = false,
        isWarning: Bool = false,
        service: String? = nil,
        connection: String? = nil,
        devices: [String] = [],
        duration: TimeInterval? = nil
    ) -> ActivityLogEntry {
        let named = devices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var identifiers = named.map { FoundIdentifier(.device, $0) }
        for found in IdentifierMasker.identifiers(inText: summary) + IdentifierMasker.identifiers(inText: note ?? "")
        where !identifiers.contains(found) {
            identifiers.append(found)
        }
        return ActivityLogEntry(category: actionCategory, operation: "", detail: summary, duration: duration,
                                note: note.map(Redaction.text), failedWithoutStatus: failed, isWarning: isWarning,
                                service: service, connection: connection, identifiers: identifiers)
    }
}

extension ActivityLog {
    /// Adds an "Action" entry (`ActivityLogEntry.action`).
    public func recordAction(
        _ summary: String,
        note: String? = nil,
        failed: Bool = false,
        isWarning: Bool = false,
        service: String? = nil,
        connection: String? = nil,
        devices: [String] = [],
        duration: TimeInterval? = nil
    ) {
        append(.action(summary, note: note, failed: failed, isWarning: isWarning, service: service, connection: connection,
                       devices: devices, duration: duration))
    }
}
