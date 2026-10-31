import Foundation

/// Apple Business and Apple School Manager: the same
/// API behind two addresses, with the same paths, device records and sign-in.
/// Only the address, the sign-in scope and Release (Business only) differ.
public nonisolated enum ABM {
    /// Apple allows an organization about 20 requests a minute and answers
    /// past that by dropping connections, not with a 429. Eighteen leaves
    /// room for whatever else the account is doing (measured by Checkpoint
    /// against a live organization).
    public static let rateLimit = RateLimit(requests: 18, per: 60,
                                            explanation: "Apple allows about 20 requests a minute for each organization")

    /// The limit for a connection: Apple’s for every real organization, none
    /// for a demo one (`Connection.isDemo`), whose requests never reach Apple.
    /// Decided by the connection, never by the demo switch, so a real
    /// organization keeps the limit while demo mode is on.
    public static func rateLimit(for connection: Connection) -> RateLimit? {
        connection.isDemo ? nil : rateLimit
    }
    /// More pages than any real list has; reaching it is an error.
    public static let maxPages = 1_000
    /// Apple rejects a migration deadline further out than this.
    public static let maximumMigrationDeadline: TimeInterval = 90 * 24 * 60 * 60
    /// How long a write is watched before it counts as still processing:
    /// checks from 2 s, growing to 10 s, for 2 minutes.
    public static let activityWatch = JamfPlatform.PollingPolicy(timeLimit: .seconds(120))

    public enum Service: String, Sendable, Hashable, CaseIterable {
        case business
        case school

        /// As the activity log and messages name it.
        public var label: String {
            switch self {
            case .business: "Apple Business"
            case .school: "Apple School Manager"
            }
        }

        /// The web portal, for hints ("in Apple Business").
        public var portal: String {
            switch self {
            case .business: "Apple Business"
            case .school: "Apple School Manager"
            }
        }

        public var host: String {
            switch self {
            case .business: "api-business.apple.com"
            case .school: "api-school.apple.com"
            }
        }

        public var baseURL: URL { URL(string: "https://\(host)")! }

        /// The sign-in scope; the token address is shared.
        public var scope: String {
            switch self {
            case .business: "business.api"
            case .school: "school.api"
            }
        }

        /// Apple School Manager has no RELEASE_DEVICES activity.
        public var supportsRelease: Bool { self == .business }

        /// The JTKit connection service.
        public init?(_ service: ConnectionService) {
            switch service {
            case .appleBusinessManager: self = .business
            case .appleSchoolManager: self = .school
            default: return nil
            }
        }
    }

    /// The recorder for one organization’s requests: service "Apple
    /// Business" or "Apple School Manager", the organization’s name as the
    /// connection.
    public static func recorder(_ service: Service, session: URLSession, log: ActivityLog?,
                                connection: String? = nil) -> RequestRecorder {
        RequestRecorder(session: session, log: log, service: service.label,
                        connection: connection.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// A serial number as it may go into an address or a query: trimmed,
    /// lowercase letters made uppercase, and only letters
    /// and digits. Apple’s serial numbers have nothing else.
    ///
    /// - Throws: `ABM.APIError.Kind.invalidSerial` for anything else.
    static func checkedSerial(_ serial: String) throws -> String {
        let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) else {
            throw ABM.APIError(.invalidSerial(serial))
        }
        return trimmed
    }
}
