import Foundation

/// An in-memory Jamf Pro (direct, API client sign-in) holding `DemoWorld`'s
/// Jamf Pro devices: sign-in, version, inventory looked up by serial (the
/// batched RSQL filters JTKit sends), ADE instances whose `serverUuid` is
/// Apple's server ID, PreStages and their scope, sites, departments,
/// buildings, Classic groups, DDM status, MDM commands, asset tag and site
/// changes, unmanage and delete. Secrets read back obviously fake values.
///
/// Every request needs the token from its sign-in, as on a server; the
/// `missingPermission` scenario refuses inventory and commands with 403.
///
/// Given an object store (`init(objects:)`), the server answers from it
/// instead: a tenant whose objects an app copies (JamfMigrator), with no
/// devices.
public nonisolated final class DemoJamfProServer: DemoServer, @unchecked Sendable {
    /// What the server shows for each secret.
    public enum FakeSecret {
        public static let fileVaultKey = "DEMO-DEMO-DEMO-DEMO-DEMO-DEMO"
        public static let recoveryLock = "demo-recovery-lock-not-real"
        public static let deviceLockPIN = "123456"
        public static let localAdminPassword = "Demo-Not-A-Real-Password"
        public static let localAdminAccount = "contosoadmin"
    }

    struct Record {
        let device: DemoWorld.Device
        var assetTag: String
        var siteID: String
        var managed = true
    }

    public static let sites = [("1", "Contoso HQ"), ("2", "Contoso Field Office")]
    static let departments = [("1", "Design"), ("2", "Engineering"), ("3", "Sales"), ("4", "Front Desk")]
    static let buildings = [("1", "HQ"), ("2", "Field Office")]
    /// Classic groups: (id, name, smart, device numbers).
    static let computerGroups: [(Int, String, Bool, ClosedRange<Int>)] = [
        (1, "All Managed Macs", true, 1...14), (2, "Design Macs", false, 1...4), (3, "Engineering Macs", false, 5...11),
    ]
    static let mobileGroups: [(Int, String, Bool, ClosedRange<Int>)] = [
        (1, "Sales iPads", true, 15...19), (2, "Front Desk Shared iPads", false, 20...21),
    ]

    private let lock = NSLock()
    private var records: [Int: Record] = [:]
    private var scope: [String: [String: String]] = ["computer-prestages": [:], "mobile-device-prestages": [:]]
    private var versionLocks: [String: Int] = ["computer-prestages": 1, "mobile-device-prestages": 1]
    private var tokens: Set<String> = []
    private var commandsValue: [(command: String, ids: [String])] = []
    private var requestCountValue = 0
    private let scenario: DemoScenario?
    private let now: Date
    /// The objects this server holds instead of `DemoWorld`'s devices.
    public let objects: DemoJamfProObjects?

    /// Every request answered, sign-ins included.
    public var requestCount: Int { lock.withLock { requestCountValue } }
    /// MDM commands received: the command and the devices it went to.
    public var commands: [(command: String, ids: [String])] { lock.withLock { commandsValue } }

    public init(scenario: DemoScenario? = nil, now: Date = Date()) {
        self.scenario = scenario
        self.now = now
        objects = nil
        for device in DemoWorld.devices(managedBy: .jamfPro) {
            records[device.number] = Record(device: device, assetTag: device.assetTag,
                                            siteID: device.isComputer ? "1" : "2")
            if device.organization != nil {
                scope[device.isComputer ? "computer-prestages" : "mobile-device-prestages"]?[device.serial] = "1"
            }
        }
    }

    /// A Jamf Pro holding `objects` (e.g. `.contosoSource()`) and no devices:
    /// sign-in as on any demo Jamf Pro, everything else from the store.
    public init(objects: DemoJamfProObjects) {
        scenario = nil
        now = Date()
        self.objects = objects
    }

    /// A device's current asset tag, or nil once deleted.
    public func assetTag(serial: String) -> String? {
        lock.withLock { records.values.first { $0.device.serial == serial.uppercased() }?.assetTag }
    }

    /// Whether Jamf Pro still holds the device and manages it.
    public func isManaged(serial: String) -> Bool? {
        lock.withLock { records.values.first { $0.device.serial == serial.uppercased() }?.managed }
    }

    // MARK: Requests

    public func respond(to request: DemoRequest) -> DemoResponse {
        lock.withLock {
            requestCountValue += 1
            let parts = request.pathSegments
            if request.method == "POST", parts == ["api", "oauth", "token"] { return signIn(request) }
            guard let token = DemoJSON.bearer(request), tokens.contains(token) else {
                return Self.error(401, "INVALID_TOKEN", "Unauthorized")
            }
            if let objects { return objects.respond(to: request, parts: parts) }
            switch parts.first {
            case "api": return api(request, Array(parts.dropFirst()))
            case "JSSResource": return classic(request, Array(parts.dropFirst()))
            default: return Self.error(404, "NOT_FOUND", "No such resource in demo mode.")
            }
        }
    }

    private func signIn(_ request: DemoRequest) -> DemoResponse {
        let form = DemoJSON.form(request.body)
        guard form["grant_type"] == "client_credentials", !(form["client_id"] ?? "").isEmpty,
              !(form["client_secret"] ?? "").isEmpty else {
            return DemoJSON.response(401, ["error": "invalid_client"])
        }
        let token = "demo-jamf-pro-token-\(tokens.count + 1)"
        tokens.insert(token)
        return DemoJSON.response(200, ["access_token": token, "token_type": "Bearer", "expires_in": 1199, "scope": "api-role:2"])
    }

    private func api(_ request: DemoRequest, _ path: [String]) -> DemoResponse {
        let method = request.method
        let refused = scenario == .missingPermission
        switch (method, path) {
        case ("GET", ["v1", "jamf-pro-version"]):
            return DemoJSON.response(200, ["version": "11.33.1-t1761000000000"])
        case ("GET", ["v4", "computers-inventory"]):
            if refused { return Self.forbidden() }
            return inventory(request, computers: true)
        case ("GET", ["v2", "mobile-devices", "detail"]):
            if refused { return Self.forbidden() }
            return inventory(request, computers: false)
        case ("GET", let p) where p.count == 4 && p[0] == "v2" && p[1] == "mobile-devices" && p[3] == "detail":
            guard mobile(p[2]) != nil else { return Self.notFound() }
            return DemoJSON.response(200, ["ios": ["unlockToken": "ZGVtby11bmxvY2stdG9rZW4="]])
        case ("GET", ["v1", "sites"]):
            return DemoJSON.response(200, Self.sites.map { ["id": $0.0, "name": $0.1] })
        case ("GET", ["v1", "departments"]):
            return page(Self.departments.map { ["id": $0.0, "name": $0.1] }, request)
        case ("GET", ["v1", "buildings"]):
            return page(Self.buildings.map { ["id": $0.0, "name": $0.1] }, request)
        case ("GET", ["v1", "device-enrollments"]):
            return page([["id": "1", "name": "Contoso Apple Business Manager", "serverUuid": DemoWorld.jamfProServerID]], request)
        case ("GET", ["v1", "device-enrollments", "1", "devices"]):
            let serials = DemoWorld.devices.filter { $0.appleServerID == DemoWorld.jamfProServerID }
                .map { ["id": "\($0.number)", "serialNumber": $0.serial, "deviceEnrollmentProgramInstanceId": "1"] }
            return page(serials, request)
        case ("GET", ["v3", "computer-prestages"]):
            return page([["id": "1", "displayName": "Contoso Macs", "deviceEnrollmentProgramInstanceId": "1"]], request)
        case ("GET", ["v3", "mobile-device-prestages"]):
            return page([["id": "1", "displayName": "Contoso iPads", "deviceEnrollmentProgramInstanceId": "1"]], request)
        case ("GET", let p) where p.count == 3 && p[0] == "v2" && p[2] == "scope" && scope[p[1]] != nil:
            return DemoJSON.response(200, ["serialsByPrestageId": scope[p[1]] ?? [:]])
        case ("GET", let p) where p.count == 4 && p[0] == "v2" && p[2] == "1" && p[3] == "scope" && scope[p[1]] != nil:
            let assigned = (scope[p[1]] ?? [:]).filter { $0.value == "1" }.keys.sorted()
            return DemoJSON.response(200, ["prestageId": "1", "versionLock": versionLocks[p[1]] ?? 0,
                                           "assignments": assigned.map { ["serialNumber": $0] }])
        case ("POST", let p) where (p.count == 4 || p.count == 5) && p[0] == "v2" && p[2] == "1" && p[3] == "scope"
            && scope[p[1]] != nil:
            return changeScope(family: p[1], remove: p.count == 5 && p[4] == "delete-multiple", body: request.body)
        case ("GET", ["v1", "conditional-access", "device-compliance", "feature-toggle"]):
            return DemoJSON.response(200, ["sharedDeviceFeatureEnabled": false])
        case ("GET", let p) where p.count == 4 && p[0] == "v1" && p[1] == "ddm" && p[3] == "status-items":
            return statusItems(managementID: p[2])
        case ("GET", let p) where p.count == 3 && p[0] == "v1" && p[1] == "dss-declarations":
            return DemoJSON.response(200, ["declarations": []])
        case ("POST", ["v2", "mdm", "commands"]):
            if refused { return Self.forbidden() }
            return command(request.body)
        case ("POST", ["v1", "mdm", "renew-profile"]):
            let udids = (DemoJSON.object(request.body)?["udids"] as? [String]) ?? []
            commandsValue.append(("RENEW_MDM_PROFILE", udids))
            return DemoJSON.response(201, ["udidsNotProcessed": ["udids": []]])
        case ("POST", ["v2", "mdm", "blank-push"]):
            let ids = (DemoJSON.object(request.body)?["clientManagementIds"] as? [String]) ?? []
            commandsValue.append(("BLANK_PUSH", ids))
            return DemoJSON.response(200, ["errorUuids": []])
        case ("POST", let p) where p.count == 4 && p[0] == "v1" && p[1] == "ddm" && p[3] == "sync":
            return DemoJSON.empty(204)
        case ("POST", let p) where p.count == 4 && p[0] == "v1" && p[1] == "jamf-management-framework" && p[2] == "redeploy":
            guard computer(p[3]) != nil else { return Self.notFound() }
            commandsValue.append(("REDEPLOY_FRAMEWORK", [p[3]]))
            return DemoJSON.response(202, ["deviceId": p[3], "commandUuid": DemoSamples.uuid(0x9000 + commandsValue.count)])
        case ("PATCH", let p) where p.count == 3 && p[0] == "v4" && p[1] == "computers-inventory-detail":
            let general = DemoJSON.object(request.body)?["general"] as? [String: Any] ?? [:]
            return update(computer(p[2]), assetTag: general["assetTag"] as? String, siteID: general["siteId"] as? String)
        case ("PATCH", let p) where p.count == 3 && p[0] == "v2" && p[1] == "mobile-devices":
            let body = DemoJSON.object(request.body) ?? [:]
            return update(mobile(p[2]), assetTag: body["assetTag"] as? String, siteID: body["siteId"] as? String)
        case ("POST", let p) where p.count == 4 && p[0] == "v4" && p[1] == "computers-inventory":
            guard let number = computer(p[2]) else { return Self.notFound() }
            if refused { return Self.forbidden() }
            switch p[3] {
            case "erase": commandsValue.append(("ERASE_DEVICE", [p[2]]))
            case "remove-mdm-profile":
                records[number]?.managed = false
                commandsValue.append(("UNMANAGE", [p[2]]))
            default: return Self.notFound()
            }
            return DemoJSON.response(201, ["id": DemoSamples.uuid(0x9000 + commandsValue.count)])
        case ("POST", let p) where p.count == 4 && p[0] == "v2" && p[1] == "mobile-devices":
            guard let number = mobile(p[2]) else { return Self.notFound() }
            if refused { return Self.forbidden() }
            switch p[3] {
            case "erase": commandsValue.append(("ERASE_DEVICE", [p[2]]))
            case "unmanage":
                records[number]?.managed = false
                commandsValue.append(("UNMANAGE", [p[2]]))
            default: return Self.notFound()
            }
            return DemoJSON.response(202, ["id": DemoSamples.uuid(0x9000 + commandsValue.count)])
        case ("DELETE", let p) where p.count == 3 && p[0] == "v4" && p[1] == "computers-inventory":
            guard let number = computer(p[2]) else { return Self.notFound() }
            records[number] = nil
            return DemoJSON.empty(204)
        case ("GET", let p) where p.count == 4 && p[0] == "v4" && p[1] == "computers-inventory":
            guard computer(p[2]) != nil else { return Self.notFound() }
            switch p[3] {
            case "filevault":
                return DemoJSON.response(200, ["computerId": p[2], "personalRecoveryKey": FakeSecret.fileVaultKey,
                                               "individualRecoveryKeyValidityStatus": "VALID",
                                               "diskEncryptionConfigurationName": "Contoso FileVault"])
            case "view-recovery-lock-password":
                return DemoJSON.response(200, ["recoveryLockPassword": FakeSecret.recoveryLock])
            case "view-device-lock-pin":
                return DemoJSON.response(200, ["pin": FakeSecret.deviceLockPIN])
            default: return Self.notFound()
            }
        case ("GET", ["v2", "local-admin-password", "settings"]):
            return DemoJSON.response(200, ["passwordRotationTime": 3600, "autoDeployEnabled": true])
        case ("GET", let p) where p.count == 4 && p[0] == "v2" && p[1] == "local-admin-password" && p[3] == "accounts":
            guard records.values.contains(where: { $0.device.managementID == p[2] && $0.device.isComputer }) else {
                return Self.notFound()
            }
            return DemoJSON.response(200, ["totalCount": 1, "results": [[
                "username": FakeSecret.localAdminAccount, "guid": DemoSamples.uuid(0x6000), "userSource": "MDM",
                "clientManagementId": p[2],
            ]]])
        case ("GET", let p) where p.count >= 6 && p[0] == "v2" && p[1] == "local-admin-password" && p[3] == "account"
            && p.last == "password":
            guard p[4] == FakeSecret.localAdminAccount else { return Self.notFound() }
            return DemoJSON.response(200, ["password": FakeSecret.localAdminPassword])
        default:
            return Self.error(404, "NOT_FOUND", "No such resource in demo mode.")
        }
    }

    private func classic(_ request: DemoRequest, _ path: [String]) -> DemoResponse {
        switch (request.method, path) {
        case ("GET", ["computergroups"]):
            return DemoJSON.response(200, ["computer_groups": Self.computerGroups.map { ["id": $0.0, "name": $0.1, "is_smart": $0.2] }])
        case ("GET", ["mobiledevicegroups"]):
            return DemoJSON.response(200, ["mobile_device_groups": Self.mobileGroups.map { ["id": $0.0, "name": $0.1, "is_smart": $0.2] }])
        case ("GET", let p) where p.count == 3 && p[0] == "computergroups" && p[1] == "id":
            guard let group = Self.computerGroups.first(where: { "\($0.0)" == p[2] }) else { return Self.notFound() }
            return DemoJSON.response(200, ["computer_group": ["id": group.0, "name": group.1, "is_smart": group.2,
                                                              "computers": members(group.3)]])
        case ("GET", let p) where p.count == 3 && p[0] == "mobiledevicegroups" && p[1] == "id":
            guard let group = Self.mobileGroups.first(where: { "\($0.0)" == p[2] }) else { return Self.notFound() }
            return DemoJSON.response(200, ["mobile_device_group": ["id": group.0, "name": group.1, "is_smart": group.2,
                                                                   "mobile_devices": members(group.3)]])
        case ("DELETE", let p) where p.count == 3 && p[0] == "mobiledevices" && p[1] == "id":
            guard let number = mobile(p[2]) else { return Self.notFound() }
            records[number] = nil
            return DemoJSON.response(200, [:])
        case ("POST", let p) where p.count == 5 && p[0] == "mobiledevicecommands" && p[1] == "command" && p[3] == "id":
            guard mobile(p[4]) != nil else { return Self.notFound() }
            if scenario == .missingPermission { return Self.forbidden() }
            commandsValue.append((p[2], [p[4]]))
            return DemoJSON.response(201, ["mobile_device_command": ["command": p[2]]])
        default:
            return Self.notFound()
        }
    }

    // MARK: Inventory

    private func inventory(_ request: DemoRequest, computers: Bool) -> DemoResponse {
        let filter = request.query["filter"] ?? ""
        let wanted = Self.quoted(in: filter).map { $0.uppercased() }
        let byUDID = filter.hasPrefix("udid")
        let matches = records.values
            .filter { $0.device.isComputer == computers }
            .filter { wanted.isEmpty || wanted.contains(byUDID ? $0.device.udid.uppercased() : $0.device.serial) }
            .sorted { $0.device.number < $1.device.number }
            .map { computers ? computerJSON($0) : mobileJSON($0) }
        return page(matches, request)
    }

    private func computerJSON(_ record: Record) -> [String: Any] {
        let device = record.device
        let contact = DemoWorld.iso(daysAgo: Double(device.lastContactDaysAgo) + 0.1, from: now, fractional: true)
        let ade = device.organization != nil
        let department = device.number <= 4 ? "1" : "2"
        return [
            "id": "\(device.number)",
            "udid": device.udid,
            "general": [
                "name": device.name,
                "assetTag": record.assetTag,
                "lastCheckIn": contact,
                "lastContact": contact,
                "lastContactTime": contact,
                "reportDate": contact,
                "lastEnrolledDate": DemoWorld.iso(daysAgo: 200 + Double(device.number), from: now, fractional: true),
                "mdmProfileExpiration": DemoWorld.iso(daysAgo: -500, from: now, fractional: true),
                "managementId": device.managementID,
                "remoteManagement": ["managed": record.managed],
                "supervised": true,
                "enrolledViaAutomatedDeviceEnrollment": ade,
                "enrollmentMethod": ade
                    ? ["id": "1", "objectName": "Contoso Macs", "objectType": "Computer PreStage"] as [String: Any]
                    : NSNull(),
                "site": ["id": record.siteID, "name": Self.sites.first { $0.0 == record.siteID }?.1 ?? "None"],
            ] as [String: Any],
            "hardware": ["serialNumber": device.serial, "model": device.model, "modelIdentifier": device.modelIdentifier],
            "operatingSystem": ["name": "macOS", "version": device.osVersion, "build": device.osVersion.hasPrefix("27") ? "27A5321" : "25G72"],
            "userAndLocation": ["username": device.username, "realname": device.user, "email": device.email,
                                "departmentId": department, "buildingId": "1", "room": ""],
            "diskEncryption": [
                "fileVault2Enabled": true, "individualRecoveryKeyValidityStatus": "VALID",
                "bootPartitionEncryptionDetails": ["partitionFileVault2State": "ENCRYPTED", "partitionFileVault2Percent": 100],
            ] as [String: Any],
        ]
    }

    private func mobileJSON(_ record: Record) -> [String: Any] {
        let device = record.device
        let contact = DemoWorld.iso(daysAgo: Double(device.lastContactDaysAgo) + 0.1, from: now)
        return [
            "mobileDeviceId": "\(device.number)",
            "deviceType": "iOS",
            "udid": device.udid,
            "general": [
                "displayName": device.name,
                "assetTag": record.assetTag,
                "osVersion": device.osVersion,
                "osBuild": device.osVersion.hasPrefix("27") ? "24A5321" : "23G93",
                "managed": record.managed,
                "supervised": true,
                "managementId": device.managementID,
                "lastInventoryUpdateDate": contact,
                "lastContactDate": contact,
                "lastEnrolledDate": DemoWorld.iso(daysAgo: 150 + Double(device.number), from: now),
                "mdmProfileExpirationDate": DemoWorld.iso(daysAgo: -500, from: now),
                "siteId": record.siteID,
                "enrollmentMethodPrestage": ["mobileDevicePrestageId": "1", "profileName": "Contoso iPads"],
            ] as [String: Any],
            "hardware": ["serialNumber": device.serial, "model": device.model, "modelIdentifier": device.modelIdentifier],
            "userAndLocation": ["username": device.username, "realName": device.user, "emailAddress": device.email,
                                "departmentId": device.number <= 19 ? "3" : "4", "buildingId": "2", "room": ""],
            "security": ["passcodePresent": true, "passcodeCompliant": true, "passcodeCompliantWithProfile": true,
                         "hardwareEncryption": 3],
        ]
    }

    private func members(_ numbers: ClosedRange<Int>) -> [[String: Any]] {
        numbers.compactMap { records[$0] }.map { ["id": $0.device.number, "name": $0.device.name, "serial_number": $0.device.serial] }
    }

    // MARK: Writes

    private func update(_ number: Int?, assetTag: String?, siteID: String?) -> DemoResponse {
        guard let number else { return Self.notFound() }
        if let assetTag { records[number]?.assetTag = assetTag }
        if let siteID {
            guard Self.sites.contains(where: { $0.0 == siteID }) else {
                return Self.error(400, "INVALID_FIELD", "Site not found", field: "siteId")
            }
            records[number]?.siteID = siteID
        }
        return DemoJSON.response(200, ["id": "\(number)"])
    }

    private func command(_ body: Data) -> DemoResponse {
        let object = DemoJSON.object(body) ?? [:]
        let type = (object["commandData"] as? [String: Any])?["commandType"] as? String ?? ""
        let ids = ((object["clientData"] as? [[String: Any]]) ?? []).compactMap { $0["managementId"] as? String }
        let known = Set(records.values.map(\.device.managementID))
        guard !type.isEmpty, !ids.isEmpty, ids.allSatisfy(known.contains) else {
            return Self.error(400, "INVALID_FIELD", "Unknown management ID", field: "clientData")
        }
        commandsValue.append((type, ids))
        return DemoJSON.response(201, ids.enumerated().map { ["id": DemoSamples.uuid(0x9100 + $0.offset), "href": "/api/v2/mdm/commands"] })
    }

    private func changeScope(family: String, remove: Bool, body: Data) -> DemoResponse {
        let object = DemoJSON.object(body) ?? [:]
        guard (object["versionLock"] as? Int) == versionLocks[family] else {
            return Self.error(409, "OPTIMISTIC_LOCK_FAILED", "Optimistic lock failed", field: "versionLock")
        }
        for serial in (object["serialNumbers"] as? [String]) ?? [] {
            scope[family]?[serial.uppercased()] = remove ? nil : "1"
        }
        versionLocks[family, default: 0] += 1
        return DemoJSON.response(200, ["prestageId": "1", "versionLock": versionLocks[family] ?? 0])
    }

    private func statusItems(managementID: String) -> DemoResponse {
        guard records.values.contains(where: { $0.device.managementID == managementID }) else { return Self.notFound() }
        let value = "{active=true, identifier=com.contoso.example.software-updates, valid=valid, reasons=[]},"
            + "{active=true, identifier=com.contoso.example.passcode, valid=valid, reasons=[]}"
        return DemoJSON.response(200, ["statusItems": [[
            "key": "management.declarations.configurations", "value": value,
            "lastUpdateTime": DemoWorld.iso(daysAgo: 0.2, from: now),
        ]]])
    }

    // MARK: Helpers

    private func computer(_ id: String) -> Int? {
        Int(id).flatMap { records[$0]?.device.isComputer == true ? $0 : nil }
    }

    private func mobile(_ id: String) -> Int? {
        Int(id).flatMap { records[$0]?.device.isComputer == false ? $0 : nil }
    }

    /// Jamf Pro's `page` / `page-size` paging, with `totalCount`.
    private func page(_ items: [[String: Any]], _ request: DemoRequest) -> DemoResponse {
        let size = max(Int(request.query["page-size"] ?? "") ?? 100, 1)
        let index = max(Int(request.query["page"] ?? "") ?? 0, 0)
        let slice = items.dropFirst(index * size).prefix(size)
        return DemoJSON.response(200, ["totalCount": items.count, "results": Array(slice)])
    }

    /// The quoted values of an RSQL filter, e.g. `serialNumber=in=("A","B")`.
    static func quoted(in filter: String) -> [String] {
        filter.split(separator: "\"", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
    }

    static func error(_ status: Int, _ code: String, _ description: String, field: String? = nil) -> DemoResponse {
        var item: [String: Any] = ["code": code, "description": description]
        if let field { item["field"] = field }
        return DemoJSON.response(status, ["httpStatus": status, "traceId": "demo-trace", "errors": [item]])
    }

    private static func notFound() -> DemoResponse { error(404, "NOT_FOUND", "Not found") }

    private static func forbidden() -> DemoResponse {
        error(403, "INVALID_PRIVILEGE", "Forbidden: the demo's missingPermission scenario")
    }
}
