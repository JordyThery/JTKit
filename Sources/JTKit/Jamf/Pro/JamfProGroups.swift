import Foundation

extension JamfPro {
    /// A Jamf Pro mobile device group or computer group.
    ///
    /// Mobile device groups and computer groups are numbered separately in
    /// Jamf Pro, so the same number can name one of each: a group is
    /// identified by its kind and its number together (`id`), never by the
    /// number alone.
    public struct DeviceGroup: Hashable, Sendable, Identifiable {
        /// What identifies a group: its kind and Jamf Pro’s ID.
        public struct ID: Hashable, Sendable, Codable, CustomStringConvertible {
            public var kind: MDMCommand.DeviceKind
            public var groupID: String

            public init(kind: MDMCommand.DeviceKind, groupID: String) {
                self.kind = kind
                self.groupID = groupID
            }

            /// The Jamf Pro group a Platform API group stands for; nil for
            /// one that isn’t a mobile device or computer group.
            public init?(_ platformGroup: JamfPlatform.PlatformGroup) {
                guard let groupID = platformGroup.jamfProID, !groupID.isEmpty else { return nil }
                switch platformGroup.deviceType {
                case .mobile: self.init(kind: .mobileDevice, groupID: groupID)
                case .computer: self.init(kind: .computer, groupID: groupID)
                case .other: return nil
                }
            }

            /// `mobileDevice 12`, `computer 12`.
            public var description: String { "\(kind.rawValue) \(groupID)" }
        }

        /// Jamf Pro’s ID of the group, unique only within its kind.
        public var groupID: String
        public var name: String
        public var isSmart: Bool
        public var kind: MDMCommand.DeviceKind
        public var description: String?

        public var id: ID { ID(kind: kind, groupID: groupID) }

        public init(groupID: String, name: String, isSmart: Bool, kind: MDMCommand.DeviceKind, description: String? = nil) {
            self.groupID = groupID
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

        /// A member from a mobile device’s inventory record
        /// (`v2/mobile-devices/detail`, by section).
        init?(mobileDetail json: LosslessJSON) {
            guard let id = json["mobileDeviceId"]?.text ?? json["id"]?.text else { return nil }
            let general = json["general"], hardware = json["hardware"], security = json["security"]
            let network = json["network"], location = json["userAndLocation"]
            func date(_ value: LosslessJSON?) -> Date? { value?.text.flatMap(JamfPlatform.date(from:)) }
            self.init(id: id, kind: .mobileDevice, name: general?["displayName"]?.text,
                      serialNumber: hardware?["serialNumber"]?.text, udid: general?["udid"]?.text,
                      managementID: general?["managementId"]?.text, osVersion: general?["osVersion"]?.text,
                      osBuild: general?["osBuild"]?.text, osSupplementalBuild: general?["osSupplementalBuildVersion"]?.text,
                      osRapidSecurityResponse: general?["osRapidSecurityResponse"]?.text, model: hardware?["model"]?.text,
                      modelIdentifier: hardware?["modelIdentifier"]?.text, timeZone: general?["timeZone"]?.text,
                      lastContact: date(general?["lastContactDate"]), lastInventoryUpdate: date(general?["lastInventoryUpdateDate"]),
                      managed: general?["managed"]?.bool, supervised: general?["supervised"]?.bool,
                      ddmEnabled: general?["declarativeDeviceManagementEnabled"]?.bool,
                      passcodePresent: security?["passcodePresent"]?.bool, batteryLevel: hardware?["batteryLevel"]?.int,
                      batteryHealth: hardware?["batteryHealth"]?.text, availableSpaceMB: hardware?["availableSpaceMb"]?.int,
                      capacityMB: hardware?["capacityMb"]?.int, roaming: network?["roaming"]?.bool,
                      dataRoamingEnabled: network?["dataRoamingEnabled"]?.bool,
                      mdmProfileExpiration: date(general?["mdmProfileExpirationDate"]),
                      building: location?["buildingName"]?.text ?? location?["building"]?.text,
                      department: location?["departmentName"]?.text ?? location?["department"]?.text)
        }

        /// This member with what it lacks taken from `other` (the same device).
        func filled(from other: JamfPro.GroupMember) -> JamfPro.GroupMember {
            JamfPro.GroupMember(
                id: id, kind: kind, name: name ?? other.name, serialNumber: serialNumber ?? other.serialNumber,
                udid: udid ?? other.udid, managementID: managementID ?? other.managementID,
                osVersion: osVersion ?? other.osVersion, osBuild: osBuild ?? other.osBuild,
                osSupplementalBuild: osSupplementalBuild ?? other.osSupplementalBuild,
                osRapidSecurityResponse: osRapidSecurityResponse ?? other.osRapidSecurityResponse,
                model: model ?? other.model, modelIdentifier: modelIdentifier ?? other.modelIdentifier,
                timeZone: timeZone ?? other.timeZone, lastContact: lastContact ?? other.lastContact,
                lastInventoryUpdate: lastInventoryUpdate ?? other.lastInventoryUpdate, managed: managed ?? other.managed,
                supervised: supervised ?? other.supervised, ddmEnabled: ddmEnabled ?? other.ddmEnabled,
                passcodePresent: passcodePresent ?? other.passcodePresent, batteryLevel: batteryLevel ?? other.batteryLevel,
                batteryHealth: batteryHealth ?? other.batteryHealth, availableSpaceMB: availableSpaceMB ?? other.availableSpaceMB,
                capacityMB: capacityMB ?? other.capacityMB, roaming: roaming ?? other.roaming,
                dataRoamingEnabled: dataRoamingEnabled ?? other.dataRoamingEnabled,
                mdmProfileExpiration: mdmProfileExpiration ?? other.mdmProfileExpiration,
                building: building ?? other.building, department: department ?? other.department)
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
            // One per device, and the paging stops at a page that brings no new
            // device: the reference lists no paging for this read, so an answer
            // that repeats the whole list on every page ends there.
            let path = "pro/v2/mobile-device-groups/\(kind)/\(JamfPlatform.pathSegment(group.groupID))"
            let privileges: [JamfPro.Privilege] = [group.isSmart ? .readSmartMobileDeviceGroups : .readStaticMobileDeviceGroups, .readMobileDevices]
            let permissions = [JamfPlatform.Permission.deviceGroupsRead, JamfPlatform.Permission.devicesRead]
            var seen = Set<String>()
            var members: [JamfPro.GroupMember] = []
            let pageSize = 100
            for page in 0..<1_000 {
                let json = try await readJSON(path, query: [URLQueryItem(name: "page", value: String(page)),
                                                            URLQueryItem(name: "page-size", value: String(pageSize))],
                                              privileges: privileges, permissions: permissions)
                let found = try JamfPlatform.Page(json: json, item: JamfPro.GroupMember.init(mobileDevice:))
                let new = found.results.filter { seen.insert($0.id).inserted }
                members += new
                let received = page * pageSize + found.results.count + found.unreadableCount
                if new.isEmpty || !JamfPlatform.hasMore(after: found, received: received, pageSize: pageSize) { break }
            }
            // Through the Platform API the membership holds only each device's
            // ID and name (the rest null, checked 2026-11-09): read the rest
            // from the inventory.
            guard members.contains(where: { $0.managementID == nil }) else { return members }
            let details = try await mobileInventory(ids: members.map(\.id))
            return members.map { member in details[member.id].map { member.filled(from: $0) } ?? member }
        case .computer:
            let ids = group.isSmart ? try await smartComputerGroupMemberIDs(group.groupID) : try await staticComputerGroupMemberIDs(group.groupID)
            return try await computerMembers(ids: ids)
        }
    }

    /// The inventory of these mobile devices (`v2/mobile-devices/detail`,
    /// general, hardware, security, network, user and location), in batches
    /// of 100, by Jamf Pro ID.
    func mobileInventory(ids: [String]) async throws -> [String: JamfPro.GroupMember] {
        let safe = ids.filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        var byID: [String: JamfPro.GroupMember] = [:]
        let sections = ["GENERAL", "HARDWARE", "SECURITY", "NETWORK", "USER_AND_LOCATION"].map { URLQueryItem(name: "section", value: $0) }
        for start in stride(from: 0, to: safe.count, by: 100) {
            let batch = safe[start..<min(start + 100, safe.count)]
            let records = try await readAllPages(
                "pro/v2/mobile-devices/detail",
                query: sections + [URLQueryItem(name: "filter", value: "mobileDeviceId=in=(\(batch.joined(separator: ",")))")],
                privileges: [.readMobileDevices], permissions: [JamfPlatform.Permission.devicesRead],
                item: JamfPro.GroupMember.init(mobileDetail:))
            for record in records { byID[record.id] = record }
        }
        return byID
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
            return JamfPro.DeviceGroup(groupID: id, name: name, isSmart: item[smartKey]?.bool ?? false, kind: kind,
                                       description: item["description"]?.text)
        }
    }
}
