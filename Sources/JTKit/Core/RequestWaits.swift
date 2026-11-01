import Foundation
import Observation

/// The waits before a retry that are going on now, for the app’s status
/// ("Jamf asked to wait 40 s"), with a way to end them at once.
///
/// Give one to the recorders of the clients (`RequestRecorder(waits:)`);
/// every wait JTKit makes before trying a request again (a 429 or server
/// error, a dropped connection, a rate limit) then shows up in `current`
/// while it lasts, besides the activity log. `cancelAll()` ends every wait
/// now: those requests stop as canceled (`CancellationError`) and aren’t
/// sent again. Canceling the task that sent a request ends its wait too.
///
/// ```swift
/// let waits = RequestWaits()
/// let recorder = RequestRecorder(session: .shared, log: log, waits: waits)
/// // in the status bar:
/// if let text = waits.statusText { Text(text); Button("Stop") { waits.cancelAll() } }
/// ```
@MainActor
@Observable
public final class RequestWaits {
    /// One wait before a retry.
    public struct Wait: Identifiable, Hashable, Sendable {
        public let id: UUID
        /// e.g. "Jamf asked to wait 40 s".
        public let message: String
        /// When the request is sent again.
        public let until: Date
        /// The connection’s name, when the recorder has one.
        public let connection: String?

        public init(id: UUID = UUID(), message: String, until: Date, connection: String? = nil) {
            self.id = id
            self.message = message
            self.until = until
            self.connection = connection
        }
    }

    /// The waits now, oldest first.
    public private(set) var current: [Wait] = []
    @ObservationIgnored private var cancels: [UUID: @Sendable () -> Void] = [:]

    public init() {}

    /// The newest wait’s message, and how many more there are, e.g.
    /// "Jamf asked to wait 40 s (and 2 more waits)". Nil when nothing waits.
    public var statusText: String? {
        guard let latest = current.last else { return nil }
        let others = current.count - 1
        guard others > 0 else { return latest.message }
        return "\(latest.message) (and \(others) more \(others == 1 ? "wait" : "waits"))"
    }

    /// Ends every wait now; those requests stop as canceled.
    public func cancelAll() {
        let all = cancels.values
        cancels.removeAll()
        current.removeAll()
        for cancel in all { cancel() }
    }

    func begin(_ wait: Wait, cancel: @escaping @Sendable () -> Void) {
        current.append(wait)
        cancels[wait.id] = cancel
    }

    func end(_ id: UUID) {
        current.removeAll { $0.id == id }
        cancels[id] = nil
    }

    /// What a wait says, by its reason: "Jamf asked to wait 40 s", "Jamf
    /// answered HTTP 503: trying again in 4 s".
    nonisolated static func message(_ reason: WaitReason, seconds: TimeInterval, service: String?) -> String {
        let shown = "\(Int(max(seconds, 0).rounded(.up))) s"
        let who = vendor(of: service)
        switch reason {
        case .askedToWait: return "\(who) asked to wait \(shown)"
        case .tooManyRequests: return "\(who) asked to slow down: trying again in \(shown)"
        case .serverError(let status): return "\(who) answered HTTP \(status): trying again in \(shown)"
        case .networkError: return "No answer from \(who): trying again in \(shown)"
        case .rateLimit(let explanation): return "\(explanation): waiting \(shown)"
        }
    }

    /// "Jamf", "Apple" or "Microsoft" for the services JTKit knows; else the
    /// service, or "The server".
    nonisolated static func vendor(of service: String?) -> String {
        guard let service, !service.isEmpty else { return "The server" }
        if service.localizedCaseInsensitiveContains("Jamf") { return "Jamf" }
        if service.localizedCaseInsensitiveContains("Apple") { return "Apple" }
        if ["Intune", "Graph", "Microsoft", "Entra"].contains(where: service.localizedCaseInsensitiveContains) { return "Microsoft" }
        return service
    }
}

/// Why a request waits before it is sent again.
nonisolated enum WaitReason: Sendable, Hashable {
    /// The server said how long (`Retry-After`).
    case askedToWait
    /// HTTP 429 without `Retry-After`.
    case tooManyRequests
    case serverError(Int)
    case networkError
    /// The client’s own limit, e.g. Apple’s requests a minute.
    case rateLimit(String)
}

extension RequestRecorder {
    /// Waits, shown in `waits` (when the recorder has one) until it ends.
    /// Ends at once when the task is canceled or `RequestWaits.cancelAll()`
    /// is called.
    /// - Throws: `CancellationError` then.
    func wait(_ seconds: TimeInterval, reason: WaitReason, now: Date,
              sleep: @escaping @Sendable (Duration) async throws -> Void) async throws {
        let duration = Duration.milliseconds(Int((max(seconds, 0) * 1000).rounded()))
        guard let waits else {
            try await sleep(duration)
            return
        }
        let id = UUID()
        let sleeping = Task { try await sleep(duration) }
        let wait = RequestWaits.Wait(id: id, message: RequestWaits.message(reason, seconds: seconds, service: service),
                                     until: now.addingTimeInterval(seconds), connection: connection)
        await waits.begin(wait, cancel: { sleeping.cancel() })
        do {
            try await withTaskCancellationHandler {
                try await sleeping.value
            } onCancel: {
                sleeping.cancel()
            }
            await waits.end(id)
        } catch {
            await waits.end(id)
            throw CancellationError()
        }
    }
}
