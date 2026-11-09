import Foundation

extension JamfPro {
    /// A Jamf Pro mobile device group or computer group.
    public struct DeviceGroup: Hashable, Sendable, Identifiable {
        /// Jamf Pro’s ID of the group.
        public var id: String
        public var name: String
        public var isSmart: Bool
        public var kind: MDMCommand.DeviceKind
        public var description: String?

        public init(id: String, name: String, isSmart: Bool, kind: MDMCommand.DeviceKind, description: String? = nil) {
            self.id = id
            self.name = name
            self.isSmart = isSmart
            self.kind = kind
            self.description = description
        }
    }

    /// One device of a group, with the inventory a software update status
    /// needs. Mobile devices come with all of it from the membership read;
    /// computers from their inventory (which has no time zone, passcode,
    /// battery or roaming fields).
    public struct GroupMember: Hashable, Sendable, Identifiable {
        /// Jamf Pro’s ID of the device.
        public var id: String
        public var kind: MDMCommand.DeviceKind
        public var name: String?
        public var serialNumber: String?
        public var udid: String?
        /// The ID its DDM status report is read by.
        public var managementID: String?
        public var osVersion: String?
        public var osBuild: String?
        public var osSupplementalBuild: String?
        public var osRapidSecurityResponse: String?
        /// The marketing name, e.g. “iPad Air 11-inch (M2)”.
        public var model: String?
        /// e.g. `iPad14,8`.
        public var modelIdentifier: String?
        /// An IANA name, e.g. `Europe/Brussels`; mobile devices only.
        public var timeZone: String?
        public var lastContact: Date?
        public var lastInventoryUpdate: Date?
        public var managed: Bool?
        public var supervised: Bool?
        public var ddmEnabled: Bool?
        public var passcodePresent: Bool?
        public var batteryLevel: Int?
        /// `NORMAL`, `SERVICE_RECOMMENDED`, `NON_GENUINE`, `UNKNOWN`, `UNSUPPORTED`.
        public var batteryHealth: String?
        public var availableSpaceMB: Int?
        public var capacityMB: Int?
        public var roaming: Bool?
        public var dataRoamingEnabled: Bool?
        public var mdmProfileExpiration: Date?
        public var building: String?
        public var department: String?

        public init(id: String, kind: MDMCommand.DeviceKind, name: String? = nil, serialNumber: String? = nil,
                    udid: String? = nil, managementID: String? = nil, osVersion: String? = nil, osBuild: String? = nil,
                    osSupplementalBuild: String? = nil, osRapidSecurityResponse: String? = nil, model: String? = nil,
                    modelIdentifier: String? = nil, timeZone: String? = nil, lastContact: Date? = nil,
                    lastInventoryUpdate: Date? = nil, managed: Bool? = nil, supervised: Bool? = nil,
                    ddmEnabled: Bool? = nil, passcodePresent: Bool? = nil, batteryLevel: Int? = nil,
                    batteryHealth: String? = nil, availableSpaceMB: Int? = nil, capacityMB: Int? = nil,
                    roaming: Bool? = nil, dataRoamingEnabled: Bool? = nil, mdmProfileExpiration: Date? = nil,
                    building: String? = nil, department: String? = nil) {
            self.id = id
            self.kind = kind
            self.name = name
            self.serialNumber = serialNumber
            self.udid = udid
            self.managementID = managementID
            self.osVersion = osVersion
            self.osBuild = osBuild
            self.osSupplementalBuild = osSupplementalBuild
            self.osRapidSecurityResponse = osRapidSecurityResponse
            self.model = model
            self.modelIdentifier = modelIdentifier
            self.timeZone = timeZone
            self.lastContact = lastContact
            self.lastInventoryUpdate = lastInventoryUpdate
            self.managed = managed
            self.supervised = supervised
            self.ddmEnabled = ddmEnabled
            self.passcodePresent = passcodePresent
            self.batteryLevel = batteryLevel
            self.batteryHealth = batteryHealth
            self.availableSpaceMB = availableSpaceMB
            self.capacityMB = capacityMB
            self.roaming = roaming
            self.dataRoamingEnabled = dataRoamingEnabled
            self.mdmProfileExpiration = mdmProfileExpiration
            self.building = building
            self.department = department
        }

        /// A member from one result of a mobile device group’s membership.
        init?(mobileDevice json: LosslessJSON) {
            guard let id = json["mobileDeviceId"]?.text ?? json["id"]?.text else { return nil }
            func text(_ key: String) -> String? { json[key]?.text }
            func date(_ key: String) -> Date? { text(key).flatMap(JamfPlatform.date(from:)) }
            self.init(id: id, kind: .mobileDevice, name: text("displayName") ?? text("name"),
                      serialNumber: text("serialNumber"), udid: text("udid"), managementID: text("managementId"),
                      osVersion: text("osVersion"), osBuild: text("osBuild"),
                      osSupplementalBuild: text("osSupplementalBuildVersion"),
                      osRapidSecurityResponse: text("osRapidSecurityResponse"), model: text("model"),
                      modelIdentifier: text("modelIdentifier"), timeZone: text("timeZone"),
                      lastContact: date("lastContactDate"), lastInventoryUpdate: date("lastInventoryUpdateDate"),
                      managed: json["managed"]?.bool, supervised: json["supervised"]?.bool,
                      ddmEnabled: json["declarativeDeviceManagementEnabled"]?.bool,
                      passcodePresent: json["passcodePresent"]?.bool, batteryLevel: json["batteryLevel"]?.int,
                      batteryHealth: text("batteryHealth"), availableSpaceMB: json["availableSpaceMb"]?.int,
                      capacityMB: json["capacityMb"]?.int, roaming: json["roaming"]?.bool,
                      dataRoamingEnabled: json["dataRoamingEnabled"]?.bool,
                      mdmProfileExpiration: date("mdmProfileExpirationDate"), building: text("building"),
                      department: text("department"))
        }

        /// A member from a computer’s inventory record.
        init?(computer: JamfPro.Computer) {
            guard let id = computer.id else { return nil }
            self.init(id: id, kind: .computer, name: computer.general?.name, serialNumber: computer.serialNumber,
                      udid: computer.udid, managementID: computer.general?.managementID,
                      osVersion: computer.operatingSystem?.version, osBuild: computer.operatingSystem?.build,
                      model: computer.hardware?.model, modelIdentifier: computer.hardware?.modelIdentifier,
                      lastContact: computer.general?.lastContact ?? computer.general?.lastCheckIn, lastInventoryUpdate: computer.general?.reportDate,
                      managed: computer.general?.managed, supervised: computer.general?.supervised,
                      mdmProfileExpiration: computer.general?.mdmProfileExpiration)
        }
    }
}

extension JamfPlatform.Client {
    /// Every mobile device group (`v2/mobile-device-groups`; Platform API:
    /// `device-groups:read`).
    public func mobileDeviceGroups() async throws -> [JamfPro.DeviceGroup] {
        let json = try await readJSON("pro/v2/mobile-device-groups",
                                      privileges: [.readSmartMobileDeviceGroups, .readStaticMobileDeviceGroups],
                                      permissions: [JamfPlatform.Permission.deviceGroupsRead])
        return Self.groups(json, kind: .mobileDevice, smartKey: "isSmartGroup")
    }

    /// Every computer group (`v1/computer-groups`; Platform API:
    /// `device-groups:read`).
    public func computerGroups() async throws -> [JamfPro.DeviceGroup] {
        let json = try await readJSON("pro/v1/computer-groups",
                                      privileges: [.readSmartComputerGroups, .readStaticComputerGroups],
                                      permissions: [JamfPlatform.Permission.deviceGroupsRead])
        return Self.groups(json, kind: .computer, smartKey: "smartGroup")
    }

    /// The groups of both kinds, mobile device groups first.
    public func jamfProGroups(_ kinds: [MDMCommand.DeviceKind] = [.mobileDevice, .computer]) async throws -> [JamfPro.DeviceGroup] {
        var groups: [JamfPro.DeviceGroup] = []
        for kind in kinds {
            groups += kind == .mobileDevice ? try await mobileDeviceGroups() : try await computerGroups()
        }
        return groups
    }

    /// The devices of a group, with their inventory.
    ///
    /// - Mobile device groups: `v2/mobile-device-groups/smart-group-membership/{id}`
    ///   or `static-group-membership/{id}`, every page (Platform API:
    ///   `device-groups:read` and `devices:read`).
    /// - Smart computer groups: the IDs from
    ///   `v3/computer-groups/smart-group-membership/{id}`; static computer
    ///   groups: the IDs from Classic `computergroups/id/{id}` (the Jamf Pro
    ///   API has no list of a static group’s members). Then the computers
    ///   from `v4/computers-inventory` in batches by ID (Platform API:
    ///   `device-groups:read`, then `devices:read`).
    public func members(of group: JamfPro.DeviceGroup) async throws -> [JamfPro.GroupMember] {
        switch group.kind {
        case .mobileDevice:
            let kind = group.isSmart ? "smart-group-membership" : "static-group-membership"
            return try await readAllPages(
                "pro/v2/mobile-device-groups/\(kind)/\(JamfPlatform.pathSegment(group.id))",
                privileges: [group.isSmart ? .readSmartMobileDeviceGroups : .readStaticMobileDeviceGroups, .readMobileDevices],
                permissions: [JamfPlatform.Permission.deviceGroupsRead, JamfPlatform.Permission.devicesRead],
                item: JamfPro.GroupMember.init(mobileDevice:))
        case .computer:
            let ids = group.isSmart ? try await smartComputerGroupMemberIDs(group.id) : try await staticComputerGroupMemberIDs(group.id)
            return try await computerMembers(ids: ids)
        }
    }

    /// The computers with these Jamf Pro IDs, in batches of 100, in the order given.
    func computerMembers(ids: [String]) async throws -> [JamfPro.GroupMember] {
        let safe = ids.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        var byID: [String: JamfPro.GroupMember] = [:]
        for start in stride(from: 0, to: safe.count, by: 100) {
            let batch = safe[start..<min(start + 100, safe.count)]
            let records: [JamfPro.Computer]
            do {
                records = try await inventory(.computers, filter: "id=in=(\(batch.joined(separator: ",")))",
                                              sections: [.general, .hardware, .operatingSystem], recording: .results)
            } catch var error as JamfPlatform.APIError where error.server == .platformAPI {
                error.permissions = [JamfPlatform.Permission.devicesRead]
                throw error
            }
            for record in records {
                if let member = JamfPro.GroupMember(computer: record) { byID[member.id] = member }
            }
        }
        return safe.compactMap { byID[$0] }
    }

    private func smartComputerGroupMemberIDs(_ id: String) async throws -> [String] {
        let json = try await readJSON("pro/v3/computer-groups/smart-group-membership/\(JamfPlatform.pathSegment(id))",
                                      privileges: [.readSmartComputerGroups],
                                      permissions: [JamfPlatform.Permission.deviceGroupsRead])
        return (json["members"]?.arrayValue ?? []).compactMap(\.text)
    }

    private func staticComputerGroupMemberIDs(_ id: String) async throws -> [String] {
        let response = try await send(
            HTTPRequest(path: "proclassic/computergroups/id/\(JamfPlatform.pathSegment(id))", accept: "application/json",
                        recordsBodies: true),
            privileges: [.readStaticComputerGroups], permissions: [JamfPlatform.Permission.deviceGroupsRead])
        guard let json = try? LosslessJSON(data: response.data) else {
            throw failure(JamfPlatform.APIError(.invalidResponse("computergroups/id/\(id) isn’t valid JSON.")))
        }
        let group = json["computer_group"] ?? json
        // {"computers": [{"id": 1, …}]}, or [{"computer": {"id": 1}}] as the reference shows it
        return (group["computers"]?.arrayValue ?? []).compactMap { entry in
            (entry["id"] ?? entry["computer"]?["id"])?.text
        }
    }

    static func groups(_ json: LosslessJSON, kind: MDMCommand.DeviceKind, smartKey: String) -> [JamfPro.DeviceGroup] {
        // a plain array, or a page with results
        let items = json.arrayValue ?? json["results"]?.arrayValue ?? []
        return items.compactMap { item in
            guard let id = item["id"]?.text, let name = item["name"]?.text else { return nil }
            return JamfPro.DeviceGroup(id: id, name: name, isSmart: item[smartKey]?.bool ?? false, kind: kind,
                                       description: item["description"]?.text)
        }
    }
}
