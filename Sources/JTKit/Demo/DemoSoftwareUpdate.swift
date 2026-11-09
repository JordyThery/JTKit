import Foundation

/// Sample iPads and Macs in the middle of a software update, for an app that
/// reports on updates. Separate from the Contoso world, so no other app’s
/// demo changes: an app switches it on with `install(on:)`, which hands the
/// group, inventory, DDM status and declaration report paths of the demo
/// Platform API to `DemoSoftwareUpdateServer` and adds two Blueprints.
///
/// Every device sits in one recognizable state: on target, downloading,
/// blocked by a passcode, on an intermediate version, failed, no report,
/// offline, hardware that can’t run the target, no activity since the
/// update started, not started; with a few unusual time zones.
public enum DemoSoftwareUpdate {
    public enum Family: String, Sendable { case iPad, mac }

    /// What a device’s status report says.
    public enum State: Sendable, Hashable {
        case onTarget
        case downloading(String)
        case prepared(String, failure: String)
        case installing(String)
        case failed(String, reason: String, count: Int)
        case idle
        /// Its last report is older than the update.
        case quietSince(days: Int)
        /// Jamf Pro has no status report for it.
        case noReport
    }

    public struct Device: Sendable, Hashable, Identifiable {
        public let number: Int
        public let family: Family
        public let name: String
        public let model: String
        public let modelIdentifier: String
        /// A Mac’s board ID, which its status report names.
        public let boardID: String?
        public let osVersion: String
        public let osBuild: String
        public let timeZone: String?
        public let lastContactDaysAgo: Int
        public let state: State
        public let passcodePresent: Bool

        public var id: Int { number }
        public var serial: String { String(format: "ZZDEMOU%02d%@", number % 100, family == .mac ? "M" : "D") }
        public var managementID: String { DemoSamples.uuid(0x7500 + number) }
        public var platformID: String { DemoSamples.uuid(0x9500 + number) }
        public var udid: String { DemoSamples.uuid(0x5500 + number).uppercased() }
    }

    /// The version both Blueprints ask for.
    public static let targetVersion = "27.1"
    public static let iPadBlueprintID = DemoSamples.uuid(0xb501)
    public static let macBlueprintID = DemoSamples.uuid(0xb502)
    /// Jamf Pro group IDs.
    public static let iPadGroupID = "501"
    public static let macGroupID = "601"
    public static let loanerMacGroupID = "602"
    /// A mobile device group with the same number as the studio's computer
    /// group: mobile device and computer groups are numbered separately.
    public static let spareIPadGroupID = "601"
    /// The Platform API device groups the Blueprints are scoped to.
    public static let iPadPlatformGroupID = DemoSamples.uuid(0xd701)
    public static let macPlatformGroupID = DemoSamples.uuid(0xd702)
    /// When the Blueprints were last changed: reports before it are old.
    public static let updateStartedDaysAgo = 10
    /// The deadline, in days from now, at 17:00 in each device’s local time.
    public static let deadlineInDays = 7
    /// The Mac Blueprint enforces minor updates this many days after Apple releases them, at 17:00.
    public static let macDelayDays = 7

    public static let iPads: [Device] = [
        ipad(101, "Field iPad 01", "iPad Air 11-inch (M2)", "iPad14,8", "27.1", "Europe/Brussels", .onTarget),
        ipad(102, "Field iPad 02", "iPad Air (5th generation)", "iPad13,18", "27.1", "Europe/Brussels", .onTarget),
        ipad(103, "Field iPad 03", "iPad Pro 11-inch (M4)", "iPad16,3", "27.0.1", "Europe/Brussels", .downloading("27.1")),
        ipad(104, "Field iPad 04", "iPad Air (5th generation)", "iPad13,18", "27.0.1", "Europe/Brussels",
             .prepared("27.1", failure: "PasscodeRequired: Passcode is required to install the update"), passcode: true),
        ipad(105, "Field iPad 05", "iPad Air 11-inch (M2)", "iPad14,8", "26.7.1", "America/New_York", .downloading("27.0.2")),
        ipad(106, "Field iPad 06", "iPad Pro 11-inch (3rd generation)", "iPad13,1", "27.0.1", "Europe/Brussels",
             .failed("27.1", reason: "DownloadFailed: The network connection was lost.", count: 3)),
        ipad(107, "Field iPad 07", "iPad Pro 11-inch (M4)", "iPad16,3", "27.0.1", "Asia/Tokyo", .noReport),
        ipad(108, "Field iPad 08", "iPad Air (5th generation)", "iPad13,18", "27.0.1", "Europe/Brussels", .quietSince(days: 45),
             contact: 45),
        ipad(109, "Field iPad 09", "iPad (6th generation)", "iPad7,5", "17.7.10", "Europe/Brussels", .idle),
        ipad(110, "Field iPad 10", "iPad Air 11-inch (M2)", "iPad14,8", "27.0.1", "Europe/Brussels", .quietSince(days: 20)),
        ipad(111, "Field iPad 11", "iPad mini (A17 Pro)", "iPad16,1", "27.0.1", "America/St_Johns", .idle),
        ipad(112, "Field iPad 12", "iPad Pro 11-inch (3rd generation)", "iPad13,1", "27.0.1", nil, .installing("27.1")),
    ]

    public static let macs: [Device] = [
        mac(201, "Studio Mac 01", "MacBook Air (13-inch, M2, 2022)", "Mac14,2", "J413AP", "27.1", .onTarget),
        mac(202, "Studio Mac 02", "MacBook Air (13-inch, M3, 2024)", "Mac15,12", "J613AP", "27.0.1", .downloading("27.1")),
        mac(203, "Studio Mac 03", "MacBook Air (13-inch, M2, 2022)", "Mac14,2", "J413AP", "27.0.1",
            .failed("27.1", reason: "InsufficientDiskSpace: Not enough free space to install the update.", count: 1)),
        mac(204, "Studio Mac 04", "MacBook Pro (13-inch, 2018, Four Thunderbolt 3 ports)", "MacBookPro15,2", "J132AP", "15.7.4", .idle),
        mac(205, "Studio Mac 05", "MacBook Air (13-inch, M3, 2024)", "Mac15,12", "J613AP", "27.0.1", .idle),
        mac(206, "Studio Mac 06", "MacBook Air (13-inch, M2, 2022)", "Mac14,2", "J413AP", "27.0.1", .quietSince(days: 40), contact: 40),
        mac(207, "Loaner Mac 01", "MacBook Air (13-inch, M3, 2024)", "Mac15,12", "J613AP", "27.1", .onTarget),
        mac(208, "Loaner Mac 02", "MacBook Air (13-inch, M2, 2022)", "Mac14,2", "J413AP", "26.6", .prepared("27.1", failure: "")),
    ]

    public static var devices: [Device] { iPads + macs }

    /// Hands the paths to the update server and adds the two Blueprints.
    public static func install(on platform: DemoJamfPlatformServer, now: Date = Date()) {
        let server = DemoSoftwareUpdateServer(now: now)
        for path in DemoSoftwareUpdateServer.paths { platform.route(path, to: server) }
        platform.add(blueprints(now: now))
    }

    /// The deadline as Blueprints write it: the device’s local time.
    public static func deadline(now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let day = calendar.date(byAdding: .day, value: deadlineInDays, to: now) ?? now
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02dT17:00:00", parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1)
    }

    static func blueprints(now: Date) -> [LosslessJSON.Object] {
        let updated = DemoWorld.iso(daysAgo: Double(updateStartedDaysAgo), from: now, fractional: true)
        func update(_ predicate: String?, name: String) -> LosslessJSON {
            var step: [LosslessJSON.Object.Member] = [
                .init(key: "name", value: .string(name)),
                .init(key: "components", value: .array([.object(LosslessJSON.Object([
                    "identifier": .string("com.jamf.ddm.sw-updates"),
                    "configuration": .object(LosslessJSON.Object([
                        "enforcementType": .string("MANUAL"),
                        "targetOSVersion": .string(targetVersion),
                        "targetLocalDateTime": .string(deadline(now: now)),
                        "detailsURL": .object(LosslessJSON.Object(["Value": .string("https://intranet.contoso.example/updates"),
                                                                   "Included": .bool(true)])),
                    ])),
                ]))])),
            ]
            if let predicate { step.append(.init(key: "activationPredicate", value: .string(predicate))) }
            return .object(LosslessJSON.Object(step))
        }
        let minorUpdates = LosslessJSON.object(LosslessJSON.Object([
            .init(key: "name", value: .string("macOS")),
            .init(key: "components", value: .array([.object(LosslessJSON.Object([
                "identifier": .string("com.jamf.ddm.sw-updates"),
                "configuration": .object(LosslessJSON.Object([
                    "enforcementType": .string("AUTOMATIC"), "strategy": .string("SEMANTIC"),
                    "rules": .object(LosslessJSON.Object(["minor": .object(LosslessJSON.Object([
                        "enforceAfterDays": .number(.init(macDelayDays)), "deploymentTime": .string("17:00")]))])),
                ])),
            ])), .object(LosslessJSON.Object([
                "identifier": .string("com.jamf.ddm.software-update-settings"),
                "configuration": .object(LosslessJSON.Object([
                    "RecommendedCadence": .object(LosslessJSON.Object(["Value": .string("All"), "Included": .bool(true)])),
                    "AutomaticActions": .object(LosslessJSON.Object([
                        "Download": .object(LosslessJSON.Object(["Value": .string("AlwaysOn"), "Included": .bool(true)]))])),
                ])),
            ]))])),
        ]))
        func blueprint(_ id: String, _ name: String, group: String, steps: [LosslessJSON]) -> LosslessJSON.Object {
            LosslessJSON.Object([
                "id": .string(id),
                "name": .string(name),
                "description": .string(id == macBlueprintID ? "Minor updates \(macDelayDays) days after release"
                                        : "Everyone on \(targetVersion) within \(deadlineInDays) days"),
                "created": .string(DemoWorld.iso(daysAgo: 40, from: now, fractional: true)),
                "updated": .string(updated),
                "deploymentState": .object(LosslessJSON.Object([
                    "state": .string("DEPLOYED"),
                    "lastDeployment": .object(LosslessJSON.Object(["started": .string(updated), "state": .string("SUCCEEDED")])),
                ])),
                "scope": .object(LosslessJSON.Object(["deviceGroups": .array([.string(group)])])),
                "steps": .array(steps),
            ])
        }
        return [
            blueprint(iPadBlueprintID, "Contoso – iPad Update", group: iPadPlatformGroupID, steps: [
                update("@status(device.operating-system.family) == 'iPadOS'", name: "iPadOS"),
                update("@status(device.operating-system.family) == 'iOS'", name: "iOS"),
            ]),
            blueprint(macBlueprintID, "Contoso – Mac Update", group: macPlatformGroupID, steps: [minorUpdates]),
        ]
    }

    private static func ipad(_ number: Int, _ name: String, _ model: String, _ identifier: String, _ os: String,
                             _ zone: String?, _ state: State, contact: Int = 0, passcode: Bool = false) -> Device {
        Device(number: number, family: .iPad, name: name, model: model, modelIdentifier: identifier, boardID: nil,
               osVersion: os, osBuild: DemoAppleReleaseServer.build(of: os, mac: false), timeZone: zone,
               lastContactDaysAgo: contact, state: state, passcodePresent: passcode)
    }

    private static func mac(_ number: Int, _ name: String, _ model: String, _ identifier: String, _ board: String,
                            _ os: String, _ state: State, contact: Int = 0) -> Device {
        Device(number: number, family: .mac, name: name, model: model, modelIdentifier: identifier, boardID: board,
               osVersion: os, osBuild: DemoAppleReleaseServer.build(of: os, mac: true), timeZone: nil,
               lastContactDaysAgo: contact, state: state, passcodePresent: false)
    }
}

/// Answers the demo Platform API’s group, inventory, DDM status and
/// declaration report paths for `DemoSoftwareUpdate`’s devices (read only).
public nonisolated final class DemoSoftwareUpdateServer: DemoServer {
    static let paths = [
        "pro/v2/mobile-device-groups", "pro/v1/computer-groups", "pro/v3/computer-groups",
        "proclassic/computergroups", "pro/v4/computers-inventory", "pro/v1/ddm", "pro/v2/groups",
        "ddm/report", "devices/v1/devices",
    ]

    private let now: Date

    public init(now: Date = Date()) {
        self.now = now
    }

    public func respond(to request: DemoRequest) -> DemoResponse {
        guard request.method == "GET" else { return DemoJSON.response(405, ["httpStatus": 405, "errors": []]) }
        let p = request.pathSegments
        switch p.count {
        case 3 where p == ["pro", "v2", "mobile-device-groups"]:
            return DemoJSON.response(200, [
                ["id": 501, "name": "Field iPads", "description": "iPads of the field team", "isSmartGroup": true],
                ["id": 601, "name": "Spare iPads", "description": "", "isSmartGroup": false],
            ])
        case 5 where Array(p[0...3]) == ["pro", "v2", "mobile-device-groups", "smart-group-membership"]
            || Array(p[0...3]) == ["pro", "v2", "mobile-device-groups", "static-group-membership"]:
            if p[4] == DemoSoftwareUpdate.spareIPadGroupID, p[3] == "static-group-membership" {
                return page([], request)
            }
            guard p[4] == DemoSoftwareUpdate.iPadGroupID, p[3] == "smart-group-membership" else { return notFound() }
            return page(DemoSoftwareUpdate.iPads.map(mobileRecord), request)
        case 3 where p == ["pro", "v2", "groups"]:
            // the Platform API's IDs of the groups the Blueprints are scoped to,
            // in the shape of Jamf's reference (groupType MOBILE or COMPUTER, smart)
            return page([
                ["groupPlatformId": DemoSoftwareUpdate.iPadPlatformGroupID, "groupJamfProId": DemoSoftwareUpdate.iPadGroupID,
                 "groupName": "Field iPads", "groupType": "MOBILE", "smart": true],
                ["groupPlatformId": DemoSoftwareUpdate.macPlatformGroupID, "groupJamfProId": DemoSoftwareUpdate.macGroupID,
                 "groupName": "Studio Macs", "groupType": "COMPUTER", "smart": true],
            ], request)
        case 3 where p == ["pro", "v1", "computer-groups"]:
            return DemoJSON.response(200, [
                ["id": "601", "name": "Studio Macs", "description": "Macs of the design studio", "smartGroup": true],
                ["id": "602", "name": "Loaner Macs", "description": "", "smartGroup": false],
            ])
        case 5 where Array(p[0...3]) == ["pro", "v3", "computer-groups", "smart-group-membership"]:
            guard p[4] == DemoSoftwareUpdate.macGroupID else { return notFound() }
            return DemoJSON.response(200, ["members": studioMacs.map(\.number)])
        case 4 where Array(p[0...2]) == ["proclassic", "computergroups", "id"]:
            guard p[3] == DemoSoftwareUpdate.loanerMacGroupID else { return notFound() }
            return DemoJSON.response(200, ["computer_group": [
                "id": 602, "name": "Loaner Macs", "is_smart": false,
                "computers": loanerMacs.map { ["id": $0.number, "name": $0.name, "serial_number": $0.serial] },
            ]])
        case 3 where p == ["pro", "v4", "computers-inventory"]:
            let ids = Self.ids(in: request.query["filter"] ?? "")
            return page(DemoSoftwareUpdate.macs.filter { ids.contains(String($0.number)) }.map(computerRecord), request)
        case 5 where Array(p[0...2]) == ["pro", "v1", "ddm"] && p[4] == "status-items":
            guard let device = DemoSoftwareUpdate.devices.first(where: { $0.managementID == p[3] }),
                  device.state != .noReport else { return notFound() }
            return DemoJSON.response(200, ["statusItems": statusItems(device)])
        case 6 where Array(p[0...3]) == ["ddm", "report", "v1", "devices"] && p[5] == "declarations":
            guard let device = DemoSoftwareUpdate.devices.first(where: { $0.platformID == p[4] }) else { return notFound() }
            return reportPage(device, request)
        case 3 where p == ["devices", "v1", "devices"]:
            let serial = (request.query["filter"] ?? "").replacingOccurrences(of: "serialNumber==", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let matches = DemoSoftwareUpdate.devices.filter { $0.serial.caseInsensitiveCompare(serial) == .orderedSame }
            return DemoJSON.response(200, ["page": 0, "pageSize": 100, "totalCount": matches.count, "hasNext": false,
                                           "results": matches.map { ["id": $0.platformID, "name": $0.name,
                                                                     "serialNumber": $0.serial, "model": $0.model,
                                                                     "modelIdentifier": $0.modelIdentifier,
                                                                     "operatingSystemVersion": $0.osVersion] }])
        default:
            return notFound()
        }
    }

    private var studioMacs: [DemoSoftwareUpdate.Device] { DemoSoftwareUpdate.macs.filter { $0.number <= 206 } }
    private var loanerMacs: [DemoSoftwareUpdate.Device] { DemoSoftwareUpdate.macs.filter { $0.number > 206 } }

    // MARK: Records

    private func iso(_ daysAgo: Double) -> String { DemoWorld.iso(daysAgo: daysAgo, from: now) }

    /// Jamf Pro writes status item times in its own local time without a
    /// zone; the demo server runs on UTC.
    private func serverTime(_ daysAgo: Double) -> String {
        String(iso(daysAgo).prefix(19))
    }

    private func mobileRecord(_ device: DemoSoftwareUpdate.Device) -> [String: Any] {
        var record: [String: Any] = [
            "mobileDeviceId": String(device.number), "displayName": device.name, "serialNumber": device.serial,
            "udid": device.udid, "managementId": device.managementID, "osVersion": device.osVersion,
            "osBuild": device.osBuild, "model": device.model, "modelIdentifier": device.modelIdentifier,
            "lastContactDate": iso(Double(device.lastContactDaysAgo) + 0.1),
            "lastInventoryUpdateDate": iso(Double(device.lastContactDaysAgo) + 0.2),
            "managed": true, "supervised": true, "declarativeDeviceManagementEnabled": true,
            "passcodePresent": device.passcodePresent, "batteryLevel": device.number == 106 ? 18 : 64 + device.number % 30,
            "batteryHealth": "NORMAL", "availableSpaceMb": device.number == 103 ? 1_900 : 41_000, "capacityMb": 128_000,
            "roaming": false, "dataRoamingEnabled": false, "building": "Contoso HQ", "department": "Field Team",
        ]
        if let zone = device.timeZone { record["timeZone"] = zone }
        return record
    }

    private func computerRecord(_ device: DemoSoftwareUpdate.Device) -> [String: Any] {
        [
            "id": String(device.number), "udid": device.udid,
            "general": ["name": device.name, "managementId": device.managementID,
                        "lastContactTime": iso(Double(device.lastContactDaysAgo) + 0.1),
                        "reportDate": iso(Double(device.lastContactDaysAgo) + 0.2), "supervised": true,
                        "remoteManagement": ["managed": true]],
            "hardware": ["serialNumber": device.serial, "model": device.model, "modelIdentifier": device.modelIdentifier],
            "operatingSystem": ["name": "macOS", "version": device.osVersion, "build": device.osBuild],
        ]
    }

    private func statusItems(_ device: DemoSoftwareUpdate.Device) -> [[String: Any]] {
        let recent: Double = switch device.state {
        case .quietSince(let days): Double(days)
        default: 0.3
        }
        var items: [[String: Any]] = []
        func add(_ key: String, _ value: String, _ daysAgo: Double = recent) {
            items.append(["key": key, "value": value, "lastUpdateTime": serverTime(daysAgo)])
        }
        let reported = device.state == .onTarget ? DemoSoftwareUpdate.targetVersion : device.osVersion
        add("device.operating-system.version", reported)
        add("device.operating-system.build-version", DemoAppleReleaseServer.build(of: reported, mac: device.family == .mac))
        add("device.model.identifier", device.modelIdentifier)
        if let board = device.boardID { add("softwareupdate.device-id", board) }
        add("passcode.is-present", device.passcodePresent ? "true" : "false")
        add("softwareupdate.beta-enrollment", "")
        func pending(_ version: String) {
            add("softwareupdate.pending-version",
                "{os-version=\(version), build-version=\(DemoAppleReleaseServer.build(of: version, mac: device.family == .mac)), target-local-date-time=\(DemoSoftwareUpdate.deadline(now: now))}")
            add("softwareupdate.install-reason", "{reason=[{softwareupdate-reason=declaration, declaration-id=Blueprint_\(device.family == .mac ? DemoSoftwareUpdate.macBlueprintID : DemoSoftwareUpdate.iPadBlueprintID)_s1_c1_sys_cfg1}]}")
        }
        switch device.state {
        case .onTarget, .idle, .quietSince, .noReport:
            add("softwareupdate.install-state", "none")
        case .downloading(let version):
            add("softwareupdate.install-state", "downloading")
            pending(version)
        case .installing(let version):
            add("softwareupdate.install-state", "installing")
            pending(version)
        case .prepared(let version, let failure):
            add("softwareupdate.install-state", "prepared")
            pending(version)
            if !failure.isEmpty {
                add("softwareupdate.failure-reason", "{count=1, reason=\(failure), timestamp=\(iso(0.5))}")
            }
        case .failed(let version, let reason, let count):
            add("softwareupdate.install-state", "failed")
            pending(version)
            add("softwareupdate.failure-reason", "{count=\(count), reason=\(reason), timestamp=\(iso(0.4))}")
        }
        return items
    }

    private func reportPage(_ device: DemoSoftwareUpdate.Device, _ request: DemoRequest) -> DemoResponse {
        let blueprint = device.family == .mac ? DemoSoftwareUpdate.macBlueprintID : DemoSoftwareUpdate.iPadBlueprintID
        let steps = device.family == .mac ? 1 : 2
        var results: [[String: Any]] = []
        for step in 1...steps {
            // on an iPad, the iOS step’s predicate doesn’t apply
            let applies = step == 1
            let pending = device.number == 111 && applies
            results.append([
                "declarationIdentifier": "Blueprint_\(blueprint)_s\(step)_c1_sys_cfg1",
                "deviceId": device.platformID, "channel": "SYSTEM", "type": "CONFIGURATION",
                "status": pending ? "PENDING" : "SUCCESSFUL", "active": applies, "validityState": "VALID",
                "reasons": [], "dateUpdated": iso(Double(DemoSoftwareUpdate.updateStartedDaysAgo)),
                "lastReportTime": iso(Double(device.lastContactDaysAgo) + 0.3),
            ])
        }
        results.append([
            "declarationIdentifier": "com.contoso.wifi", "deviceId": device.platformID, "channel": "SYSTEM",
            "type": "CONFIGURATION", "status": "SUCCESSFUL", "active": true, "validityState": "VALID", "reasons": [],
        ])
        let filter = request.query["filter"] ?? ""
        if filter.hasPrefix("declarationIdentifier==") {
            let prefix = String(filter.dropFirst("declarationIdentifier==".count)).replacingOccurrences(of: "*", with: "")
            results = results.filter { ($0["declarationIdentifier"] as? String ?? "").hasPrefix(prefix) }
        }
        return DemoJSON.response(200, ["deviceId": device.platformID, "totalCount": results.count, "results": results])
    }

    // MARK: Helpers

    private func page(_ items: [[String: Any]], _ request: DemoRequest) -> DemoResponse {
        let page = Int(request.query["page"] ?? "0") ?? 0
        let size = max(1, Int(request.query["page-size"] ?? "100") ?? 100)
        let slice = items.dropFirst(page * size).prefix(size)
        return DemoJSON.response(200, ["totalCount": items.count, "results": Array(slice)])
    }

    private func notFound() -> DemoResponse {
        DemoJSON.response(404, ["httpStatus": 404, "errors": [["code": "NOT_FOUND", "description": "Not found in demo mode."]]])
    }

    /// The IDs of an `id=in=(1,2)` or `id==1` filter.
    static func ids(in filter: String) -> Set<String> {
        if let open = filter.range(of: "id=in=("), let close = filter.range(of: ")", range: open.upperBound..<filter.endIndex) {
            return Set(filter[open.upperBound..<close.lowerBound].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        if filter.hasPrefix("id==") { return [String(filter.dropFirst(4))] }
        return []
    }
}

/// SOFA’s and Apple’s release feeds in demo mode, with made-up builds, on
/// the demo network’s own hosts (never the real ones).
public nonisolated final class DemoAppleReleaseServer: DemoServer {
    public static let sofaHost = "sofa.\(DemoNetwork.reservedDomain)"
    public static let gdmfHost = "gdmf.\(DemoNetwork.reservedDomain)"
    public static var sofaURL: URL { URL(string: "https://\(sofaHost)")! }
    public static var gdmfURL: URL { URL(string: "https://\(gdmfHost)")! }

    /// Each release with how many days before “now” Apple released it.
    private static let iOSReleases: [(version: String, build: String, devices: [String], daysAgo: Int)] = [
        ("27.1", "24B5074", supportedIPads, 12), ("27.0.2", "24A5350", supportedIPads, 25), ("27.0.1", "24A5341", supportedIPads, 40),
        ("26.7.1", "23H5031", supportedIPads, 25), ("18.7.10", "22H5240", supportedIPads, 25),
        ("17.7.10", "21H5450", supportedIPads + ["iPad7,5", "iPad7,6"], 300),
    ]
    private static let macReleases: [(version: String, build: String, boards: [String], daysAgo: Int)] = [
        ("27.1", "26B5060", supportedBoards, 12), ("27.0.1", "26A5341", supportedBoards, 40),
        ("26.6", "25G5060", supportedBoards, 30), ("15.7.4", "24G5420", supportedBoards + ["J132AP"], 60),
    ]
    private static let supportedIPads = ["iPad13,1", "iPad13,18", "iPad14,8", "iPad15,7", "iPad16,1", "iPad16,3"]
    private static let supportedBoards = ["J413AP", "J613AP"]

    /// The made-up build of a demo version (`unknown` for one it doesn’t have).
    public static func build(of version: String, mac: Bool) -> String {
        (mac ? macReleases.first { $0.version == version }?.build : iOSReleases.first { $0.version == version }?.build) ?? "unknown"
    }

    private let now: Date

    public init(now: Date = Date()) {
        self.now = now
    }

    /// A release’s date: `daysAgo` days before now, at midnight UTC, as Apple dates them.
    private func released(_ daysAgo: Int) -> (iso: String, day: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let day = calendar.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
        let text = day.formatted(.iso8601.year().month().day())
        return ("\(text)T00:00:00Z", text)
    }

    public func respond(to request: DemoRequest) -> DemoResponse {
        guard request.method == "GET" else { return DemoJSON.response(405, [:]) }
        let host = request.url.host() ?? ""
        let path = request.pathSegments
        if host == Self.sofaHost, path == ["v2", "ios_data_feed.json"] { return DemoJSON.response(200, sofaIOS()) }
        if host == Self.sofaHost, path == ["v2", "macos_data_feed.json"] { return DemoJSON.response(200, sofaMacOS()) }
        if host == Self.gdmfHost, path == ["v2", "pmv"] { return DemoJSON.response(200, gdmf()) }
        return DemoJSON.response(404, [:])
    }

    private func sofaIOS() -> [String: Any] {
        let majors = Dictionary(grouping: Self.iOSReleases) { $0.version.split(separator: ".")[0] }
        return [
            "SchemaVersion": "2.0", "UpdateHash": "demo",
            "OSVersions": majors.keys.sorted { Int($0) ?? 0 > Int($1) ?? 0 }.map { major in
                let releases = majors[major] ?? []
                return ["OSVersion": String(major),
                        "Latest": ["ProductVersion": releases[0].version, "Build": releases[0].build,
                                   "ReleaseDate": released(releases[0].daysAgo).iso, "SupportedDevices": releases[0].devices],
                        "SecurityReleases": releases.map { ["ProductVersion": $0.version, "Build": $0.build,
                                                            "ReleaseDate": released($0.daysAgo).iso] }] as [String: Any]
            },
            "Devices": [
                "iPad7,5": ["MarketingName": "iPad (6th generation) Wi-Fi"],
                "iPad13,18": ["MarketingName": "iPad Air (5th generation) Wi-Fi"],
            ],
        ]
    }

    private func sofaMacOS() -> [String: Any] {
        let names = ["27": "Golden Gate 27", "26": "Tahoe 26", "15": "Sequoia 15"]
        let majors = Dictionary(grouping: Self.macReleases) { String($0.version.split(separator: ".")[0]) }
        return [
            "SchemaVersion": "2.0", "UpdateHash": "demo",
            "OSVersions": majors.keys.sorted { Int($0) ?? 0 > Int($1) ?? 0 }.map { major in
                let releases = majors[major] ?? []
                return ["OSVersion": names[major] ?? major,
                        "Latest": ["ProductVersion": releases[0].version, "Build": releases[0].build,
                                   "ReleaseDate": released(releases[0].daysAgo).iso, "SupportedDevices": releases[0].boards],
                        "SecurityReleases": releases.map { ["ProductVersion": $0.version, "Build": $0.build,
                                                            "ReleaseDate": released($0.daysAgo).iso] }] as [String: Any]
            },
            "Models": [
                "Mac14,2": ["MarketingName": "MacBook Air (13-inch, M2, 2022)", "OSVersions": [27, 26, 15]],
                "Mac15,12": ["MarketingName": "MacBook Air (13-inch, M3, 2024)", "OSVersions": [27, 26, 15]],
                "MacBookPro15,2": ["MarketingName": "MacBook Pro (13-inch, 2018, Four Thunderbolt 3 ports)", "OSVersions": [15, 14, 13]],
            ],
            "Devices": [
                "J413AP": ["DeviceID": "Mac14,2"], "J613AP": ["DeviceID": "Mac15,12"], "J132AP": ["DeviceID": "MacBookPro15,2"],
            ],
        ]
    }

    private func gdmf() -> [String: Any] {
        ["PublicAssetSets": [
            "iOS": Self.iOSReleases.map { ["ProductVersion": $0.version, "Build": $0.build, "PostingDate": released($0.daysAgo).day,
                                           "SupportedDevices": $0.devices] }
                + [["ProductVersion": "8.8.2", "Build": "19U5526", "PostingDate": released(12).day, "SupportedDevices": ["Watch3,1"]]],
            "macOS": Self.macReleases.map { ["ProductVersion": $0.version, "Build": $0.build, "PostingDate": released($0.daysAgo).day,
                                             "SupportedDevices": $0.boards] },
        ]]
    }
}
