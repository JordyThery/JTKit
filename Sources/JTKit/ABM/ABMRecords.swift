import Foundation

extension ABM {
    /// A device in the organization, as `orgDevices` reports it. Tolerant:
    /// every field may be missing, a cellular identifier may come as one
    /// value or a list, and unknown values are kept as Apple sends them.
    public struct OrgDevice: Decodable, Sendable, Hashable {
        /// Empty when Apple sent none; lists leave such records out.
        public var serialNumber: String
        public var deviceModel: String?
        public var productFamily: String?
        /// ASSIGNED or UNASSIGNED (to a device management service).
        public var status: String?
        public var addedToOrgDateTime: String?
        public var releasedFromOrgDateTime: String?
        public var orderNumber: String?
        public var orderDateTime: String?
        public var purchaseSourceType: String?
        /// Apple Customer Number or Reseller Number, depending on the source type.
        public var purchaseSourceId: String?
        public var color: String?
        public var deviceCapacity: String?
        /// The product type identifier, e.g. iPad14,1.
        public var productType: String?
        public var partNumber: String?
        /// Lists, because a device can hold more than one.
        public var imei: [String]?
        public var meid: [String]?
        public var eid: String?
        public var wifiMacAddress: String?
        public var bluetoothMacAddress: String?
        public var ethernetMacAddress: [String]?
        /// Whether the device can move to another device management service
        /// by a deadline instead of being reassigned outright.
        public var isMdmMigrationCapable: Bool?
        /// REQUESTED, STARTED, SUCCESS or FAILED; set once a migration has
        /// been requested.
        public var mdmMigrationStatus: String?
        public var mdmMigrationDeadlineDateTime: String?

        /// The attributes asked for in the organization’s device list, which
        /// cuts it by about 80%.
        public static let fields = [
            "serialNumber", "deviceModel", "productFamily", "status",
            "addedToOrgDateTime", "releasedFromOrgDateTime", "orderNumber",
            "orderDateTime", "purchaseSourceType", "purchaseSourceId",
            "color", "deviceCapacity", "productType", "partNumber",
            "imei", "meid", "eid",
            "wifiMacAddress", "bluetoothMacAddress", "ethernetMacAddress",
            "isMdmMigrationCapable", "mdmMigrationStatus", "mdmMigrationDeadlineDateTime",
        ]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case serialNumber, deviceModel, productFamily, status, addedToOrgDateTime, releasedFromOrgDateTime
            case orderNumber, orderDateTime, purchaseSourceType, purchaseSourceId, color, deviceCapacity
            case productType, partNumber, imei, meid, eid, wifiMacAddress, bluetoothMacAddress, ethernetMacAddress
            case isMdmMigrationCapable, mdmMigrationStatus, mdmMigrationDeadlineDateTime
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? {
                if let value = try? c.decodeIfPresent(String.self, forKey: key) { return value }
                if let number = try? c.decodeIfPresent(Double.self, forKey: key) {
                    return number.rounded() == number ? String(Int(number)) : String(number)
                }
                return nil
            }
            func list(_ key: CodingKeys) -> [String]? {
                if let values = try? c.decodeIfPresent([String].self, forKey: key) { return values }
                return text(key).map { [$0] }
            }
            serialNumber = text(.serialNumber) ?? ""
            deviceModel = text(.deviceModel)
            productFamily = text(.productFamily)
            status = text(.status)
            addedToOrgDateTime = text(.addedToOrgDateTime)
            releasedFromOrgDateTime = text(.releasedFromOrgDateTime)
            orderNumber = text(.orderNumber)
            orderDateTime = text(.orderDateTime)
            purchaseSourceType = text(.purchaseSourceType)
            purchaseSourceId = text(.purchaseSourceId)
            color = text(.color)
            deviceCapacity = text(.deviceCapacity)
            productType = text(.productType)
            partNumber = text(.partNumber)
            imei = list(.imei)
            meid = list(.meid)
            eid = text(.eid)
            wifiMacAddress = text(.wifiMacAddress)
            bluetoothMacAddress = text(.bluetoothMacAddress)
            ethernetMacAddress = list(.ethernetMacAddress)
            isMdmMigrationCapable = (try? c.decodeIfPresent(Bool.self, forKey: .isMdmMigrationCapable))
                ?? text(.isMdmMigrationCapable).map { $0.lowercased() == "true" }
            mdmMigrationStatus = text(.mdmMigrationStatus)
            mdmMigrationDeadlineDateTime = text(.mdmMigrationDeadlineDateTime)
        }

        /// Released from the organization (it stays listed for a while).
        public var isReleased: Bool { releasedFromOrgDateTime != nil }

        /// A migration Apple has accepted but not yet completed.
        public var hasActiveMigration: Bool {
            let status = mdmMigrationStatus?.uppercased()
            return status == "REQUESTED" || status == "STARTED"
        }

        /// The migration deadline, when one is set.
        public var migrationDeadline: Date? {
            mdmMigrationDeadlineDateTime.flatMap(ABM.date)
        }
    }

    /// One AppleCare coverage record of a device.
    public struct AppleCareCoverage: Sendable, Identifiable, Hashable {
        public var id: String
        public var description: String?
        /// ACTIVE or INACTIVE, as Apple sends it.
        public var status: String?
        public var startDateTime: String?
        public var endDateTime: String?

        public init(id: String, description: String? = nil, status: String? = nil,
                    startDateTime: String? = nil, endDateTime: String? = nil) {
            self.id = id
            self.description = description
            self.status = status
            self.startDateTime = startDateTime
            self.endDateTime = endDateTime
        }

        public var isActive: Bool { status?.uppercased() == "ACTIVE" }

        /// Not active and its end date has passed: what INACTIVE almost
        /// always means.
        public func hasExpired(now: Date = Date()) -> Bool {
            guard !isActive, let end = endDateTime.flatMap(ABM.date) else { return false }
            return end < now
        }
    }

    /// A device’s Activation Lock state, as the organization reports it:
    /// the live state, for Macs and mobile devices, with the kind of lock.
    public struct ActivationLock: Sendable, Hashable {
        public var isLocked: Bool
        /// MDM, USER or NONE; only meaningful while locked.
        public var lockType: String?

        public init(isLocked: Bool, lockType: String? = nil) {
            self.isLocked = isLocked
            self.lockType = lockType
        }
    }

    /// A device management service in the organization.
    public struct MDMServer: Sendable, Identifiable, Hashable {
        public var id: String
        /// The ID when Apple sends no name.
        public var name: String
        /// MDM, APPLE_CONFIGURATOR or APPLE_MDM (Apple’s built-in management).
        public var serverType: String?
        public var status: String?

        public init(id: String, name: String, serverType: String? = nil, status: String? = nil) {
            self.id = id
            self.name = name
            self.serverType = serverType
            self.status = status
        }

        public var isAppleManagement: Bool { serverType?.uppercased() == "APPLE_MDM" }
    }

    /// A device enrolled in Apple’s built-in device management.
    public struct ManagedDevice: Sendable, Hashable {
        /// The resource ID the details are read by, not the serial number.
        public var id: String
        public var serialNumber: String
        public var deviceName: String?
        public var productFamily: String?

        public init(id: String, serialNumber: String, deviceName: String? = nil, productFamily: String? = nil) {
            self.id = id
            self.serialNumber = serialNumber
            self.deviceName = deviceName
            self.productFamily = productFamily
        }

        public var isMac: Bool { productFamily?.uppercased() == "MAC" }
    }

    /// The management state of one device under Apple’s built-in
    /// management. Reporting only: the API has no commands for these devices.
    public struct ManagedDeviceDetail: Sendable, Decodable, Hashable {
        public var lastCheckInDateTime: String?
        public var osVersion: String?
        public var platform: String?
        public var isFileVaultEnabled: Bool?
        public var isFirewallEnabled: Bool?
        public var deviceLockStatus: String?
        public var deviceEraseStatus: String?
        public var lostModeStatus: String?
    }

    /// One audit event about a device: when, what, by whom, whether it
    /// succeeded, and the details its type carries.
    public struct AuditEvent: Sendable, Identifiable, Hashable {
        public var id: String
        public var dateTime: String?
        public var type: String?
        public var actorName: String?
        public var outcome: String?
        public var targetServerName: String?
        /// The server a device was unassigned from.
        public var sourceServerName: String?
        public var releaseEntityType: String?
        public var purchaseSourceType: String?

        public init(id: String, dateTime: String? = nil, type: String? = nil, actorName: String? = nil,
                    outcome: String? = nil, targetServerName: String? = nil, sourceServerName: String? = nil,
                    releaseEntityType: String? = nil, purchaseSourceType: String? = nil) {
            self.id = id
            self.dateTime = dateTime
            self.type = type
            self.actorName = actorName
            self.outcome = outcome
            self.targetServerName = targetServerName
            self.sourceServerName = sourceServerName
            self.releaseEntityType = releaseEntityType
            self.purchaseSourceType = purchaseSourceType
        }

        public var isFailure: Bool { outcome?.uppercased() == "FAILURE" }
    }

    /// A page of a device’s history, with the cursor that continues it.
    public struct AuditPage: Sendable, Hashable {
        public var events: [AuditEvent]
        public var nextCursor: String?

        public init(events: [AuditEvent], nextCursor: String?) {
            self.events = events
            self.nextCursor = nextCursor
        }
    }

    /// Progress of an organization read.
    public enum SnapshotProgress: Sendable, Hashable {
        /// Devices read so far; Apple gives a cursor, never a total.
        case devices(Int)
        /// Management services whose device lists have been read.
        case assignments(done: Int, total: Int)

        public var description: String {
            switch self {
            case .devices(let count): "Reading devices… \(count.formatted())"
            case .assignments(let done, let total): "Reading assignments… \(done) of \(total) services"
            }
        }
    }

    /// Everything Apple reports about an organization in bulk: every device,
    /// and which service each is assigned to. About one request per thousand
    /// devices plus one per service, where asking per device would take the
    /// best part of an hour for a few hundred. AppleCare coverage has no bulk
    /// list and is read per device.
    public struct Snapshot: Sendable {
        /// Keyed by serial number, uppercased.
        public var devices: [String: OrgDevice]
        /// Serial number (uppercased) to the ID of its service. Absent means
        /// unassigned, unless the serial is in `unknownAssignments`.
        public var serverIDBySerial: [String: String]
        public var servers: [MDMServer]
        /// Services whose device list couldn’t be read (whole or in part).
        public var unreadableServers: [MDMServer]
        /// Devices Apple reports as assigned that no readable list holds:
        /// they may be on an unreadable service, so their service is unknown
        /// rather than "unassigned".
        public var unknownAssignments: Set<String>
        public var capturedAt: Date

        public init(devices: [String: OrgDevice], serverIDBySerial: [String: String], servers: [MDMServer],
                    unreadableServers: [MDMServer] = [], unknownAssignments: Set<String> = [], capturedAt: Date) {
            self.devices = devices
            self.serverIDBySerial = serverIDBySerial
            self.servers = servers
            self.unreadableServers = unreadableServers
            self.unknownAssignments = unknownAssignments
            self.capturedAt = capturedAt
        }
    }

    /// Apple’s dates come with or without fractional seconds.
    public static func date(_ text: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
