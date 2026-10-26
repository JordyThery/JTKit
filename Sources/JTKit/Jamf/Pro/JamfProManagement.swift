import Foundation

// Jamf Pro's reads and writes around a device (ROADMAP step 7, JTKit 0.8.2,
// from Checkpoint, with its tests): PreStages and their scope, Automated
// Device Enrollment, compliance, the DDM status report and declarations,
// sites, departments and buildings, and site moves. Lists are read with
// JTKit's page reader: reaching its page limit is an error, never a list
// quietly cut short. Each call names the privilege Jamf Pro's API
// description gives for it, checked by a test against a saved copy.

extension JamfPro {
    /// The two PreStage families. Both list at v3 and scope at v2.
    public enum PreStageFamily: String, Sendable, Hashable, CaseIterable {
        case computer
        case mobileDevice

        var pathComponent: String {
            switch self {
            case .computer: "computer-prestages"
            case .mobileDevice: "mobile-device-prestages"
            }
        }

        var readPrivilege: Privilege {
            self == .computer ? .readComputerPreStageEnrollments : .readMobileDevicePreStageEnrollments
        }

        var updatePrivilege: Privilege {
            self == .computer ? .updateComputerPreStageEnrollments : .updateMobileDevicePreStageEnrollments
        }
    }

    public struct PreStage: Hashable, Sendable {
        public var id: String
        public var displayName: String
        /// The Automated Device Enrollment instance it belongs to; only devices
        /// synced through the same instance can be scoped to it.
        public var enrollmentInstanceID: String?

        public init(id: String, displayName: String, enrollmentInstanceID: String? = nil) {
            self.id = id
            self.displayName = displayName
            self.enrollmentInstanceID = enrollmentInstanceID
        }
    }

    /// A device's compliance, as the Device Compliance integration's vendor
    /// last reported it.
    public struct DeviceCompliance: Hashable, Sendable {
        /// False when the device is outside the integration's scope, which
        /// isn't the same as being non-compliant.
        public var applicable: Bool
        /// `COMPLIANT`, `NON_COMPLIANT` or `UNKNOWN`.
        public var state: String?
        public var vendor: String?

        public init(applicable: Bool, state: String? = nil, vendor: String? = nil) {
            self.applicable = applicable
            self.state = state
            self.vendor = vendor
        }
    }

    /// One item of a device's DDM status report, as Jamf Pro keeps it.
    public struct StatusItem: Hashable, Sendable {
        public var key: String
        public var value: String?
        /// As Jamf Pro writes it: the device's own clock, without a zone.
        public var lastUpdateTime: String?

        public init(key: String, value: String? = nil, lastUpdateTime: String? = nil) {
            self.key = key
            self.value = value
            self.lastUpdateTime = lastUpdateTime
        }
    }

    /// A declaration as the server holds it (`dss-declarations`). Its payload
    /// can carry a password, so it is never recorded.
    public struct DeclarationDetail: Hashable, Sendable {
        public var uuid: String?
        /// e.g. `com.apple.configuration.softwareupdate.enforcement.specific`.
        public var type: String?
        /// The declaration's own JSON, as text.
        public var payload: String?

        public init(uuid: String? = nil, type: String? = nil, payload: String? = nil) {
            self.uuid = uuid
            self.type = type
            self.payload = payload
        }
    }

    /// The declarations in a status report's
    /// `management.declarations.configurations`, which Jamf Pro flattens with
    /// Java's `toString` (unquoted `{key=value, …}`, nested braces, free text
    /// with brackets and commas). Undocumented, so every step degrades rather
    /// than fails: a record that can't be read is left out.
    public static func flattenedDeclarations(_ value: String?) -> [JamfPlatform.Declaration] {
        guard let value, !value.isEmpty else { return [] }
        return FlattenedText.split(value, on: ",").compactMap { record in
            let trimmed = record.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") else { return nil }
            let fields = FlattenedText.fields(trimmed)
            let identifier = fields["identifier"] ?? fields["Identifier"]
            let validity = fields["valid"]
            // a record without an identifier is still worth showing when invalid
            guard identifier != nil || validity == "invalid" else { return nil }
            let reasons = FlattenedText.split(FlattenedText.unwrap(fields["reasons"] ?? "", "[", "]"), on: ",").compactMap { reason -> String? in
                let parts = FlattenedText.fields(reason.trimmingCharacters(in: .whitespacesAndNewlines))
                let details = FlattenedText.fields(parts["details"] ?? "")
                let text = details["Error"] ?? parts["description"] ?? parts["code"]
                return (text?.isEmpty ?? true) ? nil : text
            }
            return JamfPlatform.Declaration(identifier: identifier ?? "Unidentified declaration",
                                            active: fields["active"] == "true",
                                            validity: ["valid", "invalid"].contains(validity ?? "") ? validity! : "unknown",
                                            reasons: reasons)
        }
    }
}

/// Reading Jamf Pro's Java-style flattened text.
private nonisolated enum FlattenedText {
    /// `{key=value, key=value}` as a dictionary, nested values kept as text.
    static func fields(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for field in split(unwrap(value.trimmingCharacters(in: .whitespacesAndNewlines), "{", "}"), on: ",") {
            let piece = field.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[..<equals]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, result[key] == nil else { continue }
            result[key] = String(piece[piece.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func unwrap(_ value: String, _ open: Character, _ close: Character) -> String {
        guard value.first == open, value.last == close, value.count >= 2 else { return value }
        return String(value.dropFirst().dropLast())
    }

    /// Splits on a separator outside braces and brackets.
    static func split(_ value: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        for character in value {
            switch character {
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            default: break
            }
            if character == separator, depth <= 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(current) }
        return parts
    }
}

extension JamfPlatform.Client {
    // MARK: PreStages

    /// Every PreStage of the family (`v3/…-prestages`, sorted by ID).
    public func preStages(_ family: JamfPro.PreStageFamily) async throws -> [JamfPro.PreStage] {
        try await allPages("pro/v3/\(family.pathComponent)", query: [URLQueryItem(name: "sort", value: "id:asc")],
                           privilege: family.readPrivilege) { item in
            guard let id = Self.text(item["id"]) else { return nil }
            return JamfPro.PreStage(id: id, displayName: item["displayName"]?.stringValue ?? id,
                                    enrollmentInstanceID: Self.text(item["deviceEnrollmentProgramInstanceId"]))
        }
    }

    /// Serial number → PreStage ID for every scoped device of the family.
    public func preStageScope(_ family: JamfPro.PreStageFamily) async throws -> [String: String] {
        struct Answer: Decodable { let serialsByPrestageId: [String: String] }
        return try await decoded(Answer.self, HTTPRequest(path: "pro/v2/\(family.pathComponent)/scope"),
                                 privileges: [family.readPrivilege]).serialsByPrestageId
    }

    /// Adds devices to a PreStage's scope. Reads the scope's `versionLock`
    /// first (the scope is optimistically locked). Never repeated after a
    /// server error.
    public func addToPreStage(_ family: JamfPro.PreStageFamily, id: String, serials: [String]) async throws {
        try await changeScope(family, id: id, serials: serials, removing: false)
    }

    /// Removes devices from a PreStage's scope (`scope/delete-multiple`).
    public func removeFromPreStage(_ family: JamfPro.PreStageFamily, id: String, serials: [String]) async throws {
        try await changeScope(family, id: id, serials: serials, removing: true)
    }

    private func changeScope(_ family: JamfPro.PreStageFamily, id: String, serials: [String], removing: Bool) async throws {
        struct Scope: Decodable { let versionLock: Int }
        let path = "pro/v2/\(family.pathComponent)/\(JamfPlatform.pathSegment(id))/scope"
        let lock = try await decoded(Scope.self, HTTPRequest(path: path), privileges: [family.readPrivilege]).versionLock
        let body = try JSONSerialization.data(withJSONObject: ["serialNumbers": serials, "versionLock": lock] as [String: Any])
        _ = try await sendThrowing(HTTPRequest(method: "POST", path: removing ? path + "/delete-multiple" : path, body: body),
                                   privilege: family.updatePrivilege)
    }

    // MARK: Automated Device Enrollment

    /// The Apple service ID (`serverUuid`) of every ADE token: the ID Apple
    /// Business or School Manager gives the matching device management service.
    public func deviceEnrollmentServerIDs() async throws -> Set<String> {
        Set(try await allPages("pro/v1/device-enrollments", privilege: .readDeviceEnrollmentProgramInstances) { item in
            Self.text(item["serverUuid"]) ?? ""
        }.filter { !$0.isEmpty })
    }

    /// Serial number (in capitals) → ADE instance ID, for every device synced
    /// through any of the instance's tokens.
    public func deviceEnrollmentInstanceBySerial() async throws -> [String: String] {
        let instances = try await allPages("pro/v1/device-enrollments", privilege: .readDeviceEnrollmentProgramInstances) {
            Self.text($0["id"])
        }
        var map: [String: String] = [:]
        for instance in instances {
            let serials = try await allPages("pro/v1/device-enrollments/\(JamfPlatform.pathSegment(instance))/devices",
                                             pageSize: 500, privilege: .readDeviceEnrollmentProgramInstances) {
                $0["serialNumber"]?.stringValue?.uppercased()
            }
            for serial in serials { map[serial] = instance }
        }
        return map
    }

    // MARK: Compliance

    /// Whether the Device Compliance integration is on for the instance.
    public func deviceComplianceEnabled() async throws -> Bool {
        struct Answer: Decodable { let sharedDeviceFeatureEnabled: Bool? }
        return try await decoded(Answer.self, HTTPRequest(path: "pro/v1/conditional-access/device-compliance/feature-toggle"),
                                 privileges: [.readConditionalAccess]).sharedDeviceFeatureEnabled ?? false
    }

    /// A device's compliance: the applicable entry, else the first; nil when
    /// the answer has none. Recorded (a read-only lookup, ROADMAP step 5).
    public func deviceCompliance(_ kind: MDMCommand.DeviceKind, id: String) async throws -> JamfPro.DeviceCompliance? {
        struct Item: Decodable {
            let applicable: Bool?
            let complianceState: String?
            let complianceVendor: String?
        }
        let family = kind == .computer ? "computer" : "mobile"
        let response = try await sendThrowing(HTTPRequest(
            path: "pro/v1/conditional-access/device-compliance-information/\(family)/\(JamfPlatform.pathSegment(id))",
            recordsBodies: true), privilege: .readDeviceComplianceInformation)
        // a list by contract; one object is accepted too
        let items = (try? JSONDecoder().decode([Item].self, from: response.data))
            ?? (try? JSONDecoder().decode(Item.self, from: response.data)).map { [$0] } ?? []
        guard let item = items.first(where: { $0.applicable == true }) ?? items.first else { return nil }
        return JamfPro.DeviceCompliance(applicable: item.applicable ?? false, state: item.complianceState, vendor: item.complianceVendor)
    }

    // MARK: DDM

    /// A device's DDM status report (`v1/ddm/{managementId}/status-items`).
    /// Nil when there is none to read (403, 404); empty when the device sent
    /// nothing. Recorded (a read-only lookup).
    public func ddmStatusItems(managementID: String, kind: MDMCommand.DeviceKind) async throws -> [JamfPro.StatusItem]? {
        struct Answer: Decodable {
            let statusItems: [Item]?
            struct Item: Decodable {
                let key: String?
                let value: String?
                let lastUpdateTime: String?
            }
        }
        let request = HTTPRequest(path: "pro/v1/ddm/\(JamfPlatform.pathSegment(managementID))/status-items", recordsBodies: true)
        let answer: Answer
        do {
            answer = try await decoded(Answer.self, request, privileges: [Self.readPrivilege(kind)])
        } catch let error as JamfPlatformError where error.status == 403 || error.status == 404 {
            return nil
        }
        return (answer.statusItems ?? []).compactMap { item in
            item.key.map { JamfPro.StatusItem(key: $0, value: item.value, lastUpdateTime: item.lastUpdateTime) }
        }
    }

    /// One declaration as the server holds it (`v1/dss-declarations/{id}`).
    /// Not recorded: its payload can carry a password.
    public func declaration(id: String, kind: MDMCommand.DeviceKind) async throws -> [JamfPro.DeclarationDetail] {
        struct Answer: Decodable {
            let declarations: [Item]?
            struct Item: Decodable {
                let uuid: String?
                let type: String?
                let payloadJson: String?
            }
        }
        return try await decoded(Answer.self, HTTPRequest(path: "pro/v1/dss-declarations/\(JamfPlatform.pathSegment(id))"),
                                 privileges: [Self.readPrivilege(kind)])
            .declarations?.map { JamfPro.DeclarationDetail(uuid: $0.uuid, type: $0.type, payload: $0.payloadJson) } ?? []
    }

    // MARK: Sites, departments, buildings

    /// Every site; the full-access site ("-1") isn't listed. Jamf Pro answers
    /// with a list or a page.
    public func sites() async throws -> [JamfPro.Site] {
        let response = try await sendThrowing(HTTPRequest(path: "pro/v1/sites"), privilege: .readSites)
        let json = try? LosslessJSON(data: response.data)
        let items = json?.arrayValue ?? json?["results"]?.arrayValue ?? []
        return items.compactMap { item in
            guard let id = Self.text(item["id"]) else { return nil }
            return JamfPro.Site(id: id, name: item["name"]?.stringValue)
        }
    }

    /// Moves a computer to a site ("-1" for none). Safe to repeat.
    public func setSite(_ siteID: String, computerID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["general": ["siteId": siteID]])
        _ = try await sendThrowing(HTTPRequest(method: "PATCH", path: "pro/v4/computers-inventory-detail/\(JamfPlatform.pathSegment(computerID))",
                                               body: body, safeToRepeat: true), privilege: .updateComputers)
    }

    /// Moves a mobile device to a site ("-1" for none). Safe to repeat.
    public func setSite(_ siteID: String, mobileDeviceID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["siteId": siteID])
        _ = try await sendThrowing(HTTPRequest(method: "PATCH", path: "pro/v2/mobile-devices/\(JamfPlatform.pathSegment(mobileDeviceID))",
                                               body: body, safeToRepeat: true), privilege: .updateMobileDevices)
    }

    /// Department names by ID, 1,000 at a time (at most ten pages).
    public func departmentNames() async throws -> [String: String] {
        try await nameMap("pro/v1/departments", privilege: .readDepartments)
    }

    /// Building names by ID, as departments.
    public func buildingNames() async throws -> [String: String] {
        try await nameMap("pro/v1/buildings", privilege: .readBuildings)
    }

    private func nameMap(_ path: String, privilege: JamfPro.Privilege) async throws -> [String: String] {
        let pairs = try await allPages(path, pageSize: 1000, maxPages: 10, privilege: privilege) { item -> (String, String)? in
            guard let id = Self.text(item["id"]), let name = item["name"]?.stringValue, !name.isEmpty else { return nil }
            return (id, name)
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Private

    static func readPrivilege(_ kind: MDMCommand.DeviceKind) -> JamfPro.Privilege {
        kind == .computer ? .readComputers : .readMobileDevices
    }

    func decoded<T: Decodable>(_ type: T.Type, _ request: HTTPRequest, privileges: [JamfPro.Privilege]) async throws -> T {
        let response = try await sendThrowing(request, privileges: privileges)
        do {
            return try JSONDecoder().decode(type, from: response.data)
        } catch {
            throw failure(JamfPlatformError(.invalidResponse("\(request.path) could not be read: \(error.localizedDescription)")))
        }
    }
}
