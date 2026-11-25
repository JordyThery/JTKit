import Foundation

extension SoftwareUpdateRules {
    /// The categories every device is sorted into. Raw values are the CSV
    /// strings and the history’s keys: never rename them. `targetUnknown` isn’t
    /// a measurement: a device without a target is shown, but left out of the
    /// counts, the progress figure and the history.
    public nonisolated enum StatusCategory: String, CaseIterable, Sendable, Codable, Identifiable {
        case onTarget = "on-target"
        case inProgress = "in-progress"
        case otherUpdate = "other-update"
        case failed = "failed"
        case notStarted = "not-started"
        case unsupported = "unsupported"
        case noActivity = "no-activity"
        case offline = "offline"
        case noReport = "no-report"
        case targetUnknown = "target-unknown"

        public var id: String { rawValue }

        /// The categories a device is measured in: all but `targetUnknown`.
        public static let measured = allCases.filter { $0 != .targetUnknown }

        /// The category as people read it.
        public var title: String {
            switch self {
            case .onTarget: "On target"
            case .inProgress: "In progress"
            case .otherUpdate: "Other update"
            case .failed: "Failed"
            case .notStarted: "Not started"
            case .unsupported: "Unsupported"
            case .noActivity: "No activity"
            case .offline: "Offline"
            case .noReport: "No report"
            case .targetUnknown: "Target unknown"
            }
        }

        /// Left out of “updatable” in the progress figure: these devices can’t
        /// update now, whatever the Blueprint says.
        public var isExcludedFromUpdatable: Bool { [.unsupported, .offline, .noReport].contains(self) }

        /// What the count means, after it in the summary.
        public func note(staleDays: Int) -> String? {
            switch self {
            case .otherUpdate: "(e.g. an earlier step of this Blueprint)"
            case .unsupported: "(hardware can’t run the target)"
            case .noActivity: "(no report since the update started)"
            case .offline: "(no contact for more than \(staleDays) days)"
            case .targetUnknown: "(not measured, not in the progress figure)"
            default: nil
            }
        }
    }

    /// A count with its noun in the singular or the plural: “1 device”, “6 devices”.
    public nonisolated enum Plural {
        public static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
            "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
        }
    }
}
