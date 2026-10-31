import Foundation

extension ABM {
    /// The six writes (organization device activities), in JTKit’s command
    /// list beside `MDMCommand`, with the same confirmation and these rules:
    ///
    /// - every dialog names the organization;
    /// - Release, Assign with Migration Deadline and Update Migration Deadline
    ///   ask for the number of devices from two devices;
    /// - Release and Cancel Migration have a red button;
    /// - Update Migration Deadline warns when the new deadline is earlier than
    ///   a current one or already past (Apple then enforces it at once).
    ///
    /// A write is never repeated after a server error or a dropped
    /// connection, only after a 429 (Apple did nothing).
    public enum ActivityType: String, Sendable, Hashable, CaseIterable {
        case assign = "ASSIGN_DEVICES"
        case unassign = "UNASSIGN_DEVICES"
        /// Apple Business only.
        case release = "RELEASE_DEVICES"
        /// Assigns to another service and schedules a migration by a
        /// deadline; the device stays enrolled until it migrates.
        case assignWithMigrationDeadline = "ASSIGN_DEVICES_WITH_MDM_MIGRATION_DEADLINE"
        /// An earlier deadline, or one in the past, is enforced at once.
        case updateMigrationDeadline = "UPDATE_MDM_MIGRATION_DEADLINE"
        case cancelMigration = "CANCEL_MDM_MIGRATION"

        /// Apple refuses these without a service (`mdmServer`).
        public var needsServer: Bool {
            self == .assign || self == .unassign || self == .assignWithMigrationDeadline
        }

        public var needsDeadline: Bool {
            self == .assignWithMigrationDeadline || self == .updateMigrationDeadline
        }

        /// Only Release can’t be undone through the API.
        public var canBeUndone: Bool { self != .release }

        /// From two devices, the number is typed before sending.
        public var asksNumber: Bool {
            self == .release || self == .assignWithMigrationDeadline || self == .updateMigrationDeadline
        }

        public var isDestructive: Bool { self == .release || self == .cancelMigration }

        public func isAvailable(on service: Service) -> Bool {
            self != .release || service.supportsRelease
        }

        /// The action, as the dialog’s title and button word it.
        public func title(server: String? = nil) -> String {
            switch self {
            case .assign: "Assign to “\(server ?? "the Selected MDM Server")”"
            case .unassign: "Unassign from MDM Server"
            case .release: "Release from Organization"
            case .assignWithMigrationDeadline: "Migrate to “\(server ?? "the Selected MDM Server")”"
            case .updateMigrationDeadline: "Update Migration Deadline"
            case .cancelMigration: "Cancel Migration"
            }
        }

        /// What it does, for one device or several.
        ///
        /// - Parameters:
        ///   - currentServer: the one device’s service, for Cancel Migration.
        ///   - deadlineIsEarlier: Update Migration Deadline’s new deadline is
        ///     earlier than a current one or already past.
        public func consequence(count: Int, service: Service, currentServer: String? = nil,
                                deadline: Date? = nil, deadlineIsEarlier: Bool = false) -> String {
            let one = count == 1
            let due = deadline.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "the deadline"
            switch self {
            case .assign:
                return one
                    ? "Apple processes MDM server assignments asynchronously, so allow a moment before the new state appears."
                    : "Devices that are released or not in \(service.portal) are skipped. Apple processes assignments asynchronously."
            case .unassign:
                return one
                    ? "The device stays in your organization but is no longer assigned to any MDM server, so it won’t enroll automatically until it is assigned again."
                    : "The devices stay in your organization but are no longer assigned to any MDM server, so they won’t enroll automatically until assigned again. Devices with no assignment are skipped."
            case .release:
                return one
                    ? "The device will be removed from your organization and can no longer be assigned to an MDM server. This can’t be undone through the API."
                    : "The devices will be removed from your organization and can no longer be assigned to an MDM server. This can’t be undone through the API."
            case .assignWithMigrationDeadline:
                return one
                    ? "The \(service.portal) assignment changes immediately. Nothing is erased: the device keeps running under its current service until it migrates, and Apple prompts the user to migrate before \(due)."
                    : "The \(service.portal) assignments change immediately. Nothing is erased: each device keeps running under its current service until it migrates, and Apple prompts the user to migrate before \(due). Devices Apple reports as not migration-capable are skipped."
            case .updateMigrationDeadline:
                let rule = deadlineIsEarlier
                    ? "This deadline is earlier than the current one, or already past, so Apple enforces it immediately: \(one ? "the user can’t" : "users can’t") delay the migration."
                    : "A deadline earlier than the current one, or in the past, is enforced immediately without giving \(one ? "the user" : "users") the option to delay."
                return one ? rule : rule + " Devices with no migration in progress are skipped."
            case .cancelMigration:
                return one
                    ? "Only the scheduled migration is canceled. The device stays assigned to \(currentServer ?? "its assigned MDM server") in \(service.portal) and keeps running under its current service. To undo the assignment as well, assign it back to the previous MDM server."
                    : "Only the scheduled migrations are canceled. The devices stay assigned to their new MDM server in \(service.portal) and keep running under their current service. To undo the assignments as well, assign them back to the previous MDM server."
            }
        }

        /// The confirmation, by the rules above.
        ///
        /// - Parameters:
        ///   - serials: the devices it goes to (after skipping).
        ///   - organization: the organization’s name, always shown.
        ///   - server: the target service’s name (Assign, Migrate).
        ///   - currentServer: the one device’s service (Cancel Migration).
        ///   - currentDeadlines: the devices’ current deadlines (Update).
        ///   - explanation: why fewer devices than selected receive it.
        public func confirmation(serials: [String], organization: String, service: Service, server: String? = nil,
                                 currentServer: String? = nil, deadline: Date? = nil, currentDeadlines: [Date] = [],
                                 explanation: String? = nil, now: Date = Date()) -> MDMCommand.Confirmation {
            let earlier = self == .updateMigrationDeadline && deadline.map { new in
                new <= now || currentDeadlines.contains { new < $0 }
            } ?? false
            return MDMCommand.Confirmation(
                action: title(server: server), subject: serials.count == 1 ? serials[0] : nil, count: serials.count,
                message: consequence(count: serials.count, service: service, currentServer: currentServer,
                                     deadline: deadline, deadlineIsEarlier: earlier),
                irreversible: !canBeUndone, namesConnection: true, connectionName: organization,
                explanation: explanation, isDestructive: isDestructive, asksNumber: asksNumber)
        }
    }

    /// One write as it is sent.
    public struct Activity: Sendable, Hashable {
        public var type: ActivityType
        /// Checked and uppercased when the activity is made.
        public var serials: [String]
        public var serverID: String?
        public var deadline: Date?

        /// - Throws: `ABM.APIError.Kind.invalidSerial` for a serial with
        ///   characters no Apple serial has.
        public init(_ type: ActivityType, serials: [String], serverID: String? = nil, deadline: Date? = nil) throws {
            self.type = type
            self.serials = try serials.map(ABM.checkedSerial)
            self.serverID = serverID
            self.deadline = deadline
        }

        /// Apple’s examples: UTC with milliseconds.
        static func deadlineText(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter.string(from: date)
        }

        /// The request body, after the checks Apple would make, so nothing
        /// is sent that it refuses anyway.
        ///
        /// - Throws: `ABM.APIError.Kind.invalidRequest`.
        public func body(for service: Service, now: Date = Date()) throws -> Data {
            func refuse(_ message: String) -> ABM.APIError { ABM.APIError(.invalidRequest(message), service: service) }
            guard type.isAvailable(on: service) else {
                throw refuse("\(service.label) can’t release devices from the organization.")
            }
            guard !serials.isEmpty else { throw refuse("No devices to send \(type.title()) to.") }
            if type.needsServer, serverID?.isEmpty ?? true {
                throw refuse("\(type.title()) needs an MDM server.")
            }
            var attributes: [String: Any] = ["activityType": type.rawValue]
            if type.needsDeadline {
                guard let deadline else { throw refuse("\(type.title()) needs a migration deadline.") }
                guard deadline.timeIntervalSince(now) <= ABM.maximumMigrationDeadline else {
                    throw refuse("\(service.label) won’t accept a migration deadline more than 90 days from now.")
                }
                attributes["activityTypeMetadata"] = ["mdmMigrationDeadlineDateTime": Self.deadlineText(deadline)]
            }
            var relationships: [String: Any] = [
                "devices": ["data": serials.map { ["type": "orgDevices", "id": $0] }],
            ]
            if type.needsServer, let serverID {
                relationships["mdmServer"] = ["data": ["type": "mdmServers", "id": serverID]]
            }
            return try JSONSerialization.data(withJSONObject: [
                "data": ["type": "orgDeviceActivities", "attributes": attributes, "relationships": relationships],
            ], options: [.sortedKeys])
        }
    }

    /// An activity as Apple reports it (`orgDeviceActivities/{id}`).
    public struct ActivityStatus: Sendable, Hashable {
        public var id: String
        /// IN_PROGRESS, COMPLETED, STOPPED or FAILED.
        public var status: String?
        /// SUBMITTED … PROCESSING while in progress; COMPLETED_WITH_SUCCESS,
        /// COMPLETED_WITH_FAILURE (some devices failed), COMPLETED_WITH_ERROR
        /// or COMPLETED_POST_PROCESSING_FAILED (no report) when done.
        public var subStatus: String?
        public var completedDateTime: String?

        public init(id: String, status: String?, subStatus: String? = nil, completedDateTime: String? = nil) {
            self.id = id
            self.status = status
            self.subStatus = subStatus
            self.completedDateTime = completedDateTime
        }

        /// Apple has stopped working on it.
        public var isFinished: Bool {
            guard let status = status?.uppercased(), !status.isEmpty else { return false }
            return status != "IN_PROGRESS"
        }

        /// What became of it, by Apple’s documented values.
        public var outcome: ActivityOutcome {
            let status = status?.uppercased() ?? ""
            let sub = subStatus?.uppercased() ?? ""
            switch (status, sub) {
            case ("IN_PROGRESS", _), ("", _):
                return .stillProcessing
            case ("COMPLETED", "COMPLETED_WITH_SUCCESS"), ("COMPLETED", ""):
                return .completed
            case ("COMPLETED", "COMPLETED_WITH_FAILURE"):
                return .partlyFailed
            case ("COMPLETED", "COMPLETED_POST_PROCESSING_FAILED"):
                return .completedWithoutReport
            case ("COMPLETED", "COMPLETED_WITH_ERROR"), ("FAILED", _):
                return .failed(sub.isEmpty ? status : sub)
            case ("STOPPED", _):
                return .stopped
            default:
                return .unknown(sub.isEmpty ? status : "\(status) (\(sub))")
            }
        }
    }

    /// What became of a write, for the Action entry.
    public enum ActivityOutcome: Sendable, Hashable {
        /// Apple processed every device.
        case completed
        /// Apple processed it, but couldn’t make its activity report.
        case completedWithoutReport
        /// Apple couldn’t process some of the devices.
        case partlyFailed
        case failed(String)
        case stopped
        /// Still in progress when the watch ended; it may carry on.
        case stillProcessing
        /// Apple returned no activity to follow.
        case notFollowed
        /// A value Apple didn’t document.
        case unknown(String)
        /// Checking on the write failed, so what Apple did isn’t known.
        case watchFailed(String)

        /// The Action entry is a failure.
        public var isFailure: Bool {
            switch self {
            case .partlyFailed, .failed, .stopped: true
            default: false
            }
        }

        /// The Action entry carries a warning.
        public var isWarning: Bool {
            switch self {
            case .completedWithoutReport, .stillProcessing, .notFollowed, .unknown, .watchFailed: true
            default: false
            }
        }

        /// The sentence after the Action entry’s summary; nil when done.
        public func sentence(_ service: Service) -> String? {
            switch self {
            case .completed:
                nil
            case .completedWithoutReport:
                "Apple processed it but couldn’t make its activity report; check the devices in \(service.portal)."
            case .partlyFailed:
                "Apple couldn’t process some of the devices; its activity report in \(service.portal) lists which."
            case .failed(let reason):
                "Apple reports the job failed (\(reason)); its activity report in \(service.portal) says why."
            case .stopped:
                "Apple stopped the job before it finished; check the devices in \(service.portal)."
            case .stillProcessing:
                "Apple is still processing it after 2 minutes; check the devices again in a while."
            case .notFollowed:
                "Apple accepted it but returned no job to follow; check the devices in \(service.portal)."
            case .unknown(let value):
                "Apple reports “\(value)”; check the devices in \(service.portal)."
            case .watchFailed(let reason):
                "Checking on it failed (\(reason)); check the devices in \(service.portal)."
            }
        }
    }
}
