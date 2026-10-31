import Foundation

// MARK: - Records

/// The result of looking up one device by serial number or UDID, in Jamf Pro
/// or Jamf School.
public nonisolated enum DeviceMatch<Record: Sendable & Hashable>: Sendable, Hashable {
    /// No record has this serial number or UDID.
    case none
    case one(Record)
    /// Several records have it; which one is meant is unclear.
    case several(Int)

    public var record: Record? {
        if case .one(let record) = self { return record }
        return nil
    }
}

extension JamfPro {
    /// An inventory section a lookup asks for.
    public enum InventorySection: String, Sendable, Hashable, CaseIterable {
        case general = "GENERAL"
        case hardware = "HARDWARE"
        case operatingSystem = "OPERATING_SYSTEM"
        case userAndLocation = "USER_AND_LOCATION"
        case diskEncryption = "DISK_ENCRYPTION"
        /// Mobile devices only.
        case security = "SECURITY"

        /// The key the answer uses: `USER_AND_LOCATION` → `userAndLocation`.
        public var key: String {
            let words = rawValue.lowercased().split(separator: "_")
            guard let first = words.first else { return "" }
            return String(first) + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }
    }

    /// A site, as a record names it.
    public struct Site: Decodable, Hashable, Sendable {
        public var id: String?
        public var name: String?

        public init(id: String? = nil, name: String? = nil) {
            self.id = id
            self.name = name
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.text("id")
            name = c.text("name")
        }
    }

    /// A computer from `v4/computers-inventory`. Every section and field is
    /// optional: a section that wasn’t asked for, a missing field or a value
    /// of an unexpected type reads as nil, never as a failed lookup.
    public struct Computer: Decodable, Hashable, Sendable {
        public struct General: Hashable, Sendable {
            public var name: String?
            public var assetTag: String?
            /// The last check-in (v4's `lastCheckIn`; `lastContactTime` in v1).
            public var lastCheckIn: Date?
            public var lastContact: Date?
            /// The last inventory report.
            public var reportDate: Date?
            public var lastEnrolledDate: Date?
            public var mdmProfileExpiration: Date?
            public var managementID: String?
            /// Managed (`remoteManagement.managed`).
            public var managed: Bool?
            public var supervised: Bool?
            public var enrolledViaAutomatedDeviceEnrollment: Bool?
            /// How it enrolled, e.g. a PreStage (`enrollmentMethod`).
            public var enrollmentMethod: EnrollmentMethod?
            public var site: Site?
        }

        public struct EnrollmentMethod: Decodable, Hashable, Sendable {
            public var id: String?
            public var objectName: String?
            public var objectType: String?

            public init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                id = c.text("id")
                objectName = c.text("objectName")
                objectType = c.text("objectType")
            }
        }

        public struct Hardware: Hashable, Sendable {
            public var serialNumber: String?
            public var model: String?
            public var modelIdentifier: String?
        }

        public struct OperatingSystem: Hashable, Sendable {
            public var name: String?
            public var version: String?
            public var build: String?
        }

        public struct DiskEncryption: Hashable, Sendable {
            public var fileVault2Enabled: Bool?
            public var individualRecoveryKeyValidityStatus: String?
            /// The boot partition’s FileVault state, e.g. "ENCRYPTED".
            public var bootPartitionFileVault2State: String?
            public var bootPartitionFileVault2Percent: Int?
        }

        public struct UserAndLocation: Hashable, Sendable {
            public var username: String?
            /// The full name (Jamf Pro spells it `realname` here).
            public var realName: String?
            public var email: String?
            /// nil for "none" (Jamf Pro sends "-1").
            public var departmentID: String?
            public var buildingID: String?
            public var room: String?
        }

        public var id: String?
        public var udid: String?
        public var general: General?
        public var hardware: Hardware?
        public var operatingSystem: OperatingSystem?
        public var diskEncryption: DiskEncryption?
        public var userAndLocation: UserAndLocation?

        public var serialNumber: String? { hardware?.serialNumber }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.text("id")
            udid = c.text("udid")
            if let g = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "general") {
                let remote = try? g.nestedContainer(keyedBy: AnyKey.self, forKey: "remoteManagement")
                general = General(
                    name: g.text("name"), assetTag: g.text("assetTag"),
                    lastCheckIn: g.date("lastCheckIn") ?? g.date("lastContactTime"),
                    lastContact: g.date("lastContact"),
                    reportDate: g.date("reportDate"), lastEnrolledDate: g.date("lastEnrolledDate"),
                    mdmProfileExpiration: g.date("mdmProfileExpiration"), managementID: g.text("managementId"),
                    managed: remote?.flag("managed"), supervised: g.flag("supervised"),
                    enrolledViaAutomatedDeviceEnrollment: g.flag("enrolledViaAutomatedDeviceEnrollment"),
                    enrollmentMethod: g.object(EnrollmentMethod.self, "enrollmentMethod"),
                    site: g.object(Site.self, "site"))
            }
            if let h = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "hardware") {
                hardware = Hardware(serialNumber: h.text("serialNumber"), model: h.text("model"),
                                    modelIdentifier: h.text("modelIdentifier"))
            }
            if let o = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "operatingSystem") {
                operatingSystem = OperatingSystem(name: o.text("name"), version: o.text("version"), build: o.text("build"))
            }
            if let d = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "diskEncryption") {
                let boot = try? d.nestedContainer(keyedBy: AnyKey.self, forKey: "bootPartitionEncryptionDetails")
                diskEncryption = DiskEncryption(
                    fileVault2Enabled: d.flag("fileVault2Enabled"),
                    individualRecoveryKeyValidityStatus: d.text("individualRecoveryKeyValidityStatus"),
                    bootPartitionFileVault2State: boot?.text("partitionFileVault2State"),
                    bootPartitionFileVault2Percent: boot?.number("partitionFileVault2Percent"))
            }
            if let u = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "userAndLocation") {
                userAndLocation = UserAndLocation(
                    username: u.text("username"), realName: u.text("realname") ?? u.text("realName"),
                    email: u.text("email") ?? u.text("emailAddress"),
                    departmentID: JamfPro.reference(u.text("departmentId")),
                    buildingID: JamfPro.reference(u.text("buildingId")), room: u.text("room"))
            }
        }
    }

    /// A mobile device from `v2/mobile-devices/detail`, as tolerant as `Computer`.
    public struct MobileDevice: Decodable, Hashable, Sendable {
        public struct General: Hashable, Sendable {
            public var displayName: String?
            public var udid: String?
            public var assetTag: String?
            public var osVersion: String?
            public var osBuild: String?
            public var managed: Bool?
            public var supervised: Bool?
            public var managementID: String?
            public var lastInventoryUpdateDate: Date?
            public var lastContactDate: Date?
            public var lastEnrolledDate: Date?
            public var mdmProfileExpirationDate: Date?
            /// nil for "none" (Jamf Pro sends "-1").
            public var siteID: String?
            /// The PreStage it enrolled with, if any.
            public var enrollmentPreStageID: String?
            public var enrollmentPreStageName: String?
        }

        public struct Hardware: Hashable, Sendable {
            public var serialNumber: String?
            public var udid: String?
            public var model: String?
            public var modelIdentifier: String?
        }

        public struct Security: Hashable, Sendable {
            public var passcodePresent: Bool?
            public var passcodeCompliant: Bool?
            public var passcodeCompliantWithProfile: Bool?
            /// Jamf Pro’s hardware encryption level (a number).
            public var hardwareEncryption: Int?
        }

        public struct UserAndLocation: Hashable, Sendable {
            public var username: String?
            public var realName: String?
            public var email: String?
            public var departmentID: String?
            public var buildingID: String?
            public var room: String?
        }

        public var id: String?
        /// e.g. "iOS", "tvOS", "watchOS".
        public var deviceType: String?
        public var general: General?
        public var hardware: Hardware?
        public var security: Security?
        public var userAndLocation: UserAndLocation?
        private var topLevelUDID: String?

        /// The UDID, wherever the answer put it.
        public var udid: String? { topLevelUDID ?? general?.udid ?? hardware?.udid }
        public var serialNumber: String? { hardware?.serialNumber }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            id = c.text("mobileDeviceId") ?? c.text("id")
            deviceType = c.text("deviceType")
            topLevelUDID = c.text("udid")
            if let g = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "general") {
                let prestage = try? g.nestedContainer(keyedBy: AnyKey.self, forKey: "enrollmentMethodPrestage")
                general = General(
                    displayName: g.text("displayName"), udid: g.text("udid"), assetTag: g.text("assetTag"),
                    osVersion: g.text("osVersion"), osBuild: g.text("osBuild"), managed: g.flag("managed"),
                    supervised: g.flag("supervised"), managementID: g.text("managementId"),
                    lastInventoryUpdateDate: g.date("lastInventoryUpdateDate"),
                    lastContactDate: g.date("lastContactDate"), lastEnrolledDate: g.date("lastEnrolledDate"),
                    mdmProfileExpirationDate: g.date("mdmProfileExpirationDate"),
                    siteID: JamfPro.reference(g.text("siteId")),
                    enrollmentPreStageID: prestage?.text("mobileDevicePrestageId"),
                    enrollmentPreStageName: prestage?.text("profileName"))
            }
            if let h = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "hardware") {
                hardware = Hardware(serialNumber: h.text("serialNumber"), udid: h.text("udid"),
                                    model: h.text("model"), modelIdentifier: h.text("modelIdentifier"))
            }
            if let s = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "security") {
                security = Security(passcodePresent: s.flag("passcodePresent"), passcodeCompliant: s.flag("passcodeCompliant"),
                                    passcodeCompliantWithProfile: s.flag("passcodeCompliantWithProfile"),
                                    hardwareEncryption: s.number("hardwareEncryption"))
            }
            if let u = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "userAndLocation") {
                userAndLocation = UserAndLocation(
                    username: u.text("username"), realName: u.text("realName") ?? u.text("realname"),
                    email: u.text("emailAddress") ?? u.text("email"),
                    departmentID: JamfPro.reference(u.text("departmentId")),
                    buildingID: JamfPro.reference(u.text("buildingId")), room: u.text("room"))
            }
        }
    }

    /// A department, building or site ID; nil for Jamf Pro’s "none" ("-1").
    static func reference(_ id: String?) -> String? {
        id == "-1" ? nil : id
    }
}

// MARK: - Results

extension JamfPro {
    /// `v2/mobile-devices/{id}`: one record, its general values at the top
    /// level (`name`, `udid`, …; `ios.supervised` and `site.id` when the
    /// answer has them). A real Jamf Pro leaves out `assetTag` here; it’s
    /// read when present.
    struct MobileDeviceDetail: Decodable {
        var general: MobileDevice.General

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            let ios = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "ios")
            let site = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "site")
            general = MobileDevice.General(
                displayName: c.text("name"), udid: c.text("udid"), assetTag: c.text("assetTag"),
                osVersion: c.text("osVersion"), osBuild: c.text("osBuild"), managed: c.flag("managed"),
                supervised: ios?.flag("supervised"), managementID: c.text("managementId"),
                lastInventoryUpdateDate: c.date("lastInventoryUpdateTimestamp"),
                lastContactDate: c.date("lastContactTimestamp"), lastEnrolledDate: c.date("lastEnrollmentTimestamp"),
                mdmProfileExpirationDate: c.date("mdmProfileExpirationTimestamp"),
                siteID: JamfPro.reference(site?.text("id")),
                enrollmentPreStageID: nil, enrollmentPreStageName: nil)
        }
    }

    /// `mobiledevices/id/{id}/subset/General` from the Classic API, as JSON:
    /// only `mobile_device.general.asset_tag` is read (empty is none).
    struct ClassicMobileDeviceGeneral: Decodable {
        var assetTag: String?

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            let device = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: "mobile_device")
            let general = try? device?.nestedContainer(keyedBy: AnyKey.self, forKey: "general")
            assetTag = general?.text("asset_tag")
        }
    }

    /// The result of looking up many devices at once.
    public struct Batch<Record: Sendable>: Sendable {
        /// Found records, by serial number in capitals. With several records
        /// for one serial, the first.
        public var records: [String: Record]
        /// Serials that couldn’t be looked up, by serial number in capitals.
        public var failures: [String: JamfPlatform.APIError]

        public init(records: [String: Record] = [:], failures: [String: JamfPlatform.APIError] = [:]) {
            self.records = records
            self.failures = failures
        }
    }

    /// How a lookup records its answer in the activity log.
    public enum Recording: Sendable, Hashable {
        /// The default bodies rule: the answer only when it is an error.
        case errorsOnly
        /// Also a successful answer, trimmed to the record’s ID, UDID and the
        /// sections asked for. User and location are hidden whole, as every
        /// personal block is.
        case results
    }

    /// Keeps a page’s `totalCount` and, per record, only what says which
    /// record it is and the sections asked for.
    static func recordedInventory(sections: [InventorySection]) -> RecordedJSONFilter {
        let allowed = Set(["id", "udid", "mobileDeviceId", "deviceType"]).union(sections.map(\.key))
        return { object in
            guard let page = object as? [String: Any] else { return object }
            var kept: [String: Any] = [:]
            if let total = page["totalCount"] { kept["totalCount"] = total }
            if let results = page["results"] as? [Any] {
                kept["results"] = results.map { item -> Any in
                    guard let record = item as? [String: Any] else { return item }
                    return record.filter { allowed.contains($0.key) }
                }
            }
            return kept
        }
    }

    /// The sections every lookup asks for unless told otherwise.
    public static let computerSections: [InventorySection] = [.general, .hardware, .operatingSystem, .userAndLocation]
    public static let mobileDeviceSections: [InventorySection] = [.general, .hardware, .userAndLocation]

    /// Lookups ask for at most this many serials per request.
    static let batchSize = 50
    /// And send at most this many requests at once.
    static let batchWindow = 4
}

// MARK: - Lookups

/// Where a device kind is listed and how it is filtered.
private nonisolated struct InventoryList: Sendable {
    let path: String
    let serialField: String
    let udidField: String
    let privilege: JamfPro.Privilege

    static let computers = InventoryList(path: "pro/v4/computers-inventory", serialField: "hardware.serialNumber",
                                         udidField: "udid", privilege: .readComputers)
    static let mobileDevices = InventoryList(path: "pro/v2/mobile-devices/detail", serialField: "serialNumber",
                                             udidField: "udid", privilege: .readMobileDevices)
}

/// One page of an inventory list.
private nonisolated struct InventoryPage<Record: Decodable>: Decodable {
    let totalCount: Int?
    let results: [Tolerant<Record>]
}

extension JamfPlatform.Client {
    /// The computer with this serial number (`v4/computers-inventory`).
    /// A record counts only when its serial is the one asked for (ignoring
    /// case). Needs “Read Computers”.
    ///
    /// - Throws: `JamfPlatform.APIError`, `.invalidIdentifier` before anything
    ///   is sent when the serial has other characters than letters, digits
    ///   and hyphens.
    public func computer(serial: String, sections: [JamfPro.InventorySection] = JamfPro.computerSections,
                         recording: JamfPro.Recording = .errorsOnly) async throws -> DeviceMatch<JamfPro.Computer> {
        let safe = try JamfPro.validatedIdentifier(serial)
        let records: [JamfPro.Computer] = try await inventory(.computers, filter: "\(InventoryList.computers.serialField)==\"\(safe)\"",
                                                              sections: sections, recording: recording)
        return Self.match(records, safe) { $0.serialNumber }
    }

    /// The computer with this UDID. Needs “Read Computers”.
    public func computer(udid: String, sections: [JamfPro.InventorySection] = JamfPro.computerSections,
                         recording: JamfPro.Recording = .errorsOnly) async throws -> DeviceMatch<JamfPro.Computer> {
        let safe = try JamfPro.validatedIdentifier(udid)
        let records: [JamfPro.Computer] = try await inventory(.computers, filter: "udid==\"\(safe)\"",
                                                              sections: sections, recording: recording)
        return Self.match(records, safe) { $0.udid }
    }

    /// The mobile device with this serial number (`v2/mobile-devices/detail`).
    /// Needs “Read Mobile Devices”.
    public func mobileDevice(serial: String, sections: [JamfPro.InventorySection] = JamfPro.mobileDeviceSections,
                             recording: JamfPro.Recording = .errorsOnly) async throws -> DeviceMatch<JamfPro.MobileDevice> {
        let safe = try JamfPro.validatedIdentifier(serial)
        let records: [JamfPro.MobileDevice] = try await inventory(.mobileDevices, filter: "serialNumber==\"\(safe)\"",
                                                                  sections: sections, recording: recording)
        return try await completingGeneral(Self.match(records, safe) { $0.serialNumber }, sections: sections)
    }

    /// The mobile device with this UDID. Needs “Read Mobile Devices”.
    public func mobileDevice(udid: String, sections: [JamfPro.InventorySection] = JamfPro.mobileDeviceSections,
                             recording: JamfPro.Recording = .errorsOnly) async throws -> DeviceMatch<JamfPro.MobileDevice> {
        let safe = try JamfPro.validatedIdentifier(udid)
        let records: [JamfPro.MobileDevice] = try await inventory(.mobileDevices, filter: "udid==\"\(safe)\"",
                                                                  sections: sections, recording: recording)
        return try await completingGeneral(Self.match(records, safe) { $0.udid }, sections: sections)
    }

    /// A record that never enrolled has device type "Unknown", and Jamf’s
    /// device list leaves out its whole general section (name, asset tag, …).
    /// So a lookup that found one such record reads it once more by ID, with
    /// `completedGeneral(id:)`.
    private func completingGeneral(_ match: DeviceMatch<JamfPro.MobileDevice>,
                                   sections: [JamfPro.InventorySection]) async throws -> DeviceMatch<JamfPro.MobileDevice> {
        guard sections.contains(.general), case .one(var record) = match, record.general == nil, let id = record.id else { return match }
        guard let general = try await completedGeneral(id: id) else { return match }
        record.general = general
        return .one(record)
    }

    /// The general values of one mobile device by ID. It reads
    /// `v2/mobile-devices/{id}`, never `…/detail`: that one carries the
    /// device’s unlock token, and a lookup never reads it. That answer has the
    /// name but no asset tag on a real Jamf Pro, so the asset tag comes from
    /// the Classic API’s General subset (never the whole record or its
    /// Security subset). When that read fails, the general values come back
    /// without an asset tag. Both reads need “Read Mobile Devices”.
    ///
    /// - Returns: nil when the first answer can’t be read.
    /// - Throws: the first read’s error, or `CancellationError`.
    private func completedGeneral(id: String) async throws -> JamfPro.MobileDevice.General? {
        let response = try await send(Self.singleMobileDevice(id), privilege: .readMobileDevices)
        guard var general = try? JSONDecoder().decode(JamfPro.MobileDeviceDetail.self, from: response.data).general else { return nil }
        if general.assetTag == nil {
            general.assetTag = try await classicAssetTag(id: id)
        }
        return general
    }

    /// The asset tag from `proclassic/mobiledevices/id/{id}/subset/General`;
    /// nil when there’s none or the read fails.
    ///
    /// - Throws: `CancellationError` only.
    private func classicAssetTag(id: String) async throws -> String? {
        do {
            let response = try await send(Self.classicGeneral(id), privilege: .readMobileDevices)
            return (try? JSONDecoder().decode(JamfPro.ClassicMobileDeviceGeneral.self, from: response.data))?.assetTag
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    /// One mobile device by ID, without the unlock token.
    private static func singleMobileDevice(_ id: String) -> HTTPRequest {
        HTTPRequest(path: "pro/v2/mobile-devices/\(JamfPlatform.pathSegment(id))")
    }

    /// One mobile device’s Classic General subset, as JSON.
    private static func classicGeneral(_ id: String) -> HTTPRequest {
        HTTPRequest(path: "proclassic/mobiledevices/id/\(JamfPlatform.pathSegment(id))/subset/General", accept: "application/json")
    }

    /// Computers by serial number, many at once: 50 serials per request,
    /// 4 requests at a time. When Jamf Pro refuses a list filter (HTTP 400),
    /// that group is looked up one serial at a time, unless the first of
    /// those fails too: then the whole group fails. A serial with other
    /// characters than letters, digits and hyphens fails without being sent.
    ///
    /// - Throws: `CancellationError`, or the secret’s own error (e.g. none
    ///   saved); every Jamf error is a failure of the serials concerned.
    public func computers(serials: [String], sections: [JamfPro.InventorySection] = JamfPro.computerSections,
                          recording: JamfPro.Recording = .errorsOnly) async throws -> JamfPro.Batch<JamfPro.Computer> {
        try await batch(.computers, serials: serials, sections: sections, recording: recording) { $0.serialNumber }
    }

    /// Mobile devices by serial number, many at once, as `computers(serials:)`.
    /// A record that never enrolled is read once more by ID for its general
    /// section (and its asset tag), as in `mobileDevice(serial:)`.
    public func mobileDevices(serials: [String], sections: [JamfPro.InventorySection] = JamfPro.mobileDeviceSections,
                              recording: JamfPro.Recording = .errorsOnly) async throws -> JamfPro.Batch<JamfPro.MobileDevice> {
        var batch: JamfPro.Batch<JamfPro.MobileDevice> = try await self.batch(.mobileDevices, serials: serials, sections: sections,
                                                                                recording: recording) { $0.serialNumber }
        guard sections.contains(.general) else { return batch }
        let incomplete = batch.records.filter { $0.value.general == nil && $0.value.id != nil }
        guard !incomplete.isEmpty else { return batch }
        // A few at a time, like the list reads (each one’s two reads in
        // turn). One that can’t be read leaves the record as the list gave
        // it: found, without a name.
        let keys = Array(incomplete.keys)
        try await withThrowingTaskGroup(of: (String, JamfPro.MobileDevice.General?).self) { group in
            var next = 0
            func startNext() {
                guard next < keys.count else { return }
                let key = keys[next]
                next += 1
                let id = incomplete[key]?.id ?? ""
                group.addTask {
                    do {
                        return (key, try await self.completedGeneral(id: id))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (key, nil)
                    }
                }
            }
            for _ in 0..<JamfPro.batchWindow { startNext() }
            for try await (key, general) in group {
                if let general { batch.records[key]?.general = general }
                startNext()
            }
        }
        return batch
    }

    // MARK: Asset tags

    /// Sets a computer’s asset tag (`v4/computers-inventory-detail/{id}`); an
    /// empty tag clears it. Safe to repeat. Needs “Update Computers”.
    public func setAssetTag(_ assetTag: String, computerID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["general": ["assetTag": assetTag]])
        _ = try await send(HTTPRequest(method: "PATCH", path: "pro/v4/computers-inventory-detail/\(JamfPlatform.pathSegment(computerID))",
                                               body: body, repeating: .safe),
                                   privilege: .updateComputers)
    }

    /// Sets a mobile device’s asset tag (`v2/mobile-devices/{id}`); an empty
    /// tag clears it. Safe to repeat. Needs “Update Mobile Devices”.
    public func setAssetTag(_ assetTag: String, mobileDeviceID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["assetTag": assetTag])
        _ = try await send(HTTPRequest(method: "PATCH", path: "pro/v2/mobile-devices/\(JamfPlatform.pathSegment(mobileDeviceID))",
                                               body: body, repeating: .safe),
                                   privilege: .updateMobileDevices)
    }

    // MARK: Private

    private static func match<Record>(_ records: [Record], _ wanted: String,
                                      _ identifier: (Record) -> String?) -> DeviceMatch<Record> {
        let exact = records.filter { identifier($0)?.caseInsensitiveCompare(wanted) == .orderedSame }
        switch exact.count {
        case 0: return .none
        case 1: return .one(exact[0])
        default: return .several(exact.count)
        }
    }

    /// Every record matching the filter, page by page (at most 10 pages of 100).
    private func inventory<Record: Decodable & Sendable>(
        _ list: InventoryList, filter: String, sections: [JamfPro.InventorySection], recording: JamfPro.Recording
    ) async throws -> [Record] {
        let pageSize = 100
        let query = sections.map { URLQueryItem(name: "section", value: $0.rawValue) } + [URLQueryItem(name: "filter", value: filter)]
        return try await JamfPlatform.allPages(of: list.path, pageSize: pageSize, maxPages: 10) { page in
            let request = HTTPRequest(
                path: list.path,
                query: [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "page-size", value: String(pageSize))] + query,
                recordsBodies: recording == .results,
                recordedJSON: recording == .results ? JamfPro.recordedInventory(sections: sections) : nil)
            let response = try await self.send(request, privilege: list.privilege)
            let body: InventoryPage<Record>
            do {
                body = try JSONDecoder().decode(InventoryPage<Record>.self, from: response.data)
            } catch {
                throw self.failure(JamfPlatform.APIError(.invalidResponse("\(list.path) couldn’t be read: \(error.localizedDescription)")))
            }
            let records = body.results.compactMap(\.value)
            return JamfPlatform.Page(results: records, totalCount: body.totalCount,
                                     unreadableCount: body.results.count - records.count)
        }
    }

    private func batch<Record: Decodable & Sendable>(
        _ list: InventoryList, serials: [String], sections: [JamfPro.InventorySection], recording: JamfPro.Recording,
        serial: @escaping @Sendable (Record) -> String?
    ) async throws -> JamfPro.Batch<Record> {
        var result = JamfPro.Batch<Record>()
        var wanted = [String]()
        for raw in serials {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !key.isEmpty, !wanted.contains(key), result.failures[key] == nil else { continue }
            do {
                wanted.append(try JamfPro.validatedIdentifier(key))
            } catch let error as JamfPlatform.APIError {
                result.failures[key] = error
            }
        }
        let chunks = stride(from: 0, to: wanted.count, by: JamfPro.batchSize).map {
            Array(wanted[$0..<min($0 + JamfPro.batchSize, wanted.count)])
        }

        typealias ChunkResult = (records: [String: Record], failures: [String: JamfPlatform.APIError])
        @Sendable func read(_ chunk: [String]) async throws -> ChunkResult {
            func keyed(_ records: [Record]) -> [String: Record] {
                var found = [String: Record]()
                for record in records {
                    guard let key = serial(record)?.uppercased(), chunk.contains(key), found[key] == nil else { continue }
                    found[key] = record
                }
                return found
            }
            let filter = "\(list.serialField)=in=(\(chunk.map { "\"\($0)\"" }.joined(separator: ",")))"
            do {
                let records: [Record] = try await inventory(list, filter: filter, sections: sections, recording: recording)
                return (keyed(records), [:])
            } catch let error as JamfPlatform.APIError where error.status == 400 {
                // The list filter was refused: one serial at a time. The first
                // is a probe: when it fails too, the 400 wasn’t about the list
                // filter, and the others fail with it without being sent.
                var found = [String: Record]()
                var failed = [String: JamfPlatform.APIError]()
                for (index, one) in chunk.enumerated() {
                    do {
                        let records: [Record] = try await inventory(list, filter: "\(list.serialField)==\"\(one)\"",
                                                                    sections: sections, recording: recording)
                        found.merge(keyed(records)) { first, _ in first }
                    } catch let error as JamfPlatform.APIError {
                        guard index > 0 else {
                            return ([:], Dictionary(uniqueKeysWithValues: chunk.map { ($0, error) }))
                        }
                        failed[one] = error
                    }
                }
                return (found, failed)
            } catch let error as JamfPlatform.APIError {
                return ([:], Dictionary(uniqueKeysWithValues: chunk.map { ($0, error) }))
            }
        }

        try await withThrowingTaskGroup(of: ChunkResult.self) { group in
            var next = 0
            func startNext() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]
                next += 1
                group.addTask { try await read(chunk) }
            }
            for _ in 0..<JamfPro.batchWindow { startNext() }
            while let chunkResult = try await group.next() {
                result.records.merge(chunkResult.records) { first, _ in first }
                result.failures.merge(chunkResult.failures) { first, _ in first }
                startNext()
            }
        }
        return result
    }
}
