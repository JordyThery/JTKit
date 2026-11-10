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
/// update started, not started, installing for hours, a beta of a newer
/// major (no target), on a version the Mac Blueprint’s declarations don’t
/// cover; with a few unusual time zones.
///
/// Declaration Reporting answers per device and per declaration
/// (`ddm/report/v1/declarations/{id}/devices`, which needs a filter, as
/// Jamf’s does). The Mac Blueprint sends one configuration and activation
/// pair per version range, each with its predicate; the iPad Blueprint one
/// pair per step. Among them: an invalid declaration, a failed one and
/// devices awaiting sync. Each device’s status report lists the
/// declarations it holds (`management.declarations`).
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
        /// False for the one iPad that isn’t supervised.
        public let supervised: Bool
        /// The beta program it is enrolled in, if any.
        public let betaEnrollment: String?
        /// Its Rapid Security Response (`(a)`), if it has one.
        public let rapidSecurityResponse: String?
        /// A Mac’s battery health, as its status report writes it.
        public let batteryHealth: String?
        /// A Mac’s FileVault: `ENCRYPTED` or `UNENCRYPTED`.
        public let fileVaultState: String?
        /// A Mac’s bootstrap token: `ESCROWED` or `NOT_ESCROWED`.
        public let bootstrapToken: String?

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
        ipad(113, "Field iPad 13", "iPad Air 11-inch (M2)", "iPad14,8", "27.0.1", "Europe/Brussels", .idle, supervised: false),
    ]

    public static let macs: [Device] = [
        mac(201, "Studio Mac 01", "MacBook Air (13-inch, M2, 2022)", "Mac14,2", "J413AP", "27.1", .onTarget, rapidSecurityResponse: "(a)"),
        mac(202, "Studio Mac 02", "MacBook Air (13-inch, M3, 2024)", "Mac15,12", "J613AP", "27.0.1", .downloading("27.1"),
            bootstrap: "NOT_ESCROWED"),
        mac(203, "Studio Mac 03", "MacBook Air (13-inch, M2, 2022)", "Mac14,2", "J413AP", "27.0.1",
            .failed("27.1", reason: "InsufficientDiskSpace: Not enough free space to install the update.", count: 1),
            battery: "service-recommended"),
        mac(204, "Studio Mac 04", "MacBook Pro (13-inch, 2018, Four Thunderbolt 3 ports)", "MacBookPro15,2", "J132AP", "15.7.4", .idle),
        mac(205, "Studio Mac 05", "MacBook Air (13-inch, M3, 2024)", "Mac15,12", "J613AP", "27.0.1", .idle, fileVault: "UNENCRYPTED"),
        mac(206, "Studio Mac 06", "MacBook Air (13-inch, M2, 2022)", "Mac14,2", "J413AP", "27.0.1", .quietSince(days: 40), contact: 40),
        mac(207, "Loaner Mac 01", "MacBook Air (13-inch, M3, 2024)", "Mac15,12", "J613AP", "27.1", .onTarget),
        mac(208, "Loaner Mac 02", "MacBook Air (13-inch, M2, 2022)", "Mac14,2", "J413AP", "26.6", .prepared("27.1", failure: "")),
        mac(209, "Studio Mac 07", "MacBook Air (13-inch, M3, 2024)", "Mac15,12", "J613AP", "27.0.2", .idle),
        // a beta of a major Apple hasn't released: the minor-updates rule gives it no target
        mac(210, "Studio Mac 08", "MacBook Air (13-inch, M3, 2024)", "Mac15,12", "J613AP", "28.0", .idle,
            build: "27A5016f", beta: "macOS 28 Developer Beta"),
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

    // MARK: Declarations

    /// One configuration and activation pair of a demo Blueprint, as Jamf
    /// names them (`Blueprint_<id>_s1_c1_sys_cfg1`, `…_act1`).
    public struct DeclarationPair: Sendable, Hashable {
        public let blueprintID: String
        public let step: Int
        public let number: Int
        /// The activation’s predicate, as the device reports it when it is false.
        public let predicate: String
        /// The demo family it is for; nil for iPhones, which the demo has none of.
        let family: Family?
        /// The versions it is for (a whole-text pattern); nil: every version.
        let versions: String?
        /// The board IDs it lists; empty: every device.
        let boards: [String]

        public var configuration: String { "Blueprint_\(blueprintID)_s\(step)_c1_sys_cfg\(number)" }
        public var activation: String { "Blueprint_\(blueprintID)_s\(step)_c1_sys_act\(number)" }

        /// Whether its predicate is true for a device running `version`.
        func applies(to device: Device, version: String) -> Bool {
            guard device.family == family else { return false }
            if !boards.isEmpty && !boards.contains(device.boardID ?? "") { return false }
            guard let versions else { return true }
            return version.range(of: versions, options: .regularExpression) != nil
        }
    }

    /// The Mac Blueprint’s minor updates: one pair per version range, for
    /// the boards that run it. The range for macOS 27 stops at 27.0.1, so a
    /// Mac on 27.0.2 gets no update from it.
    public static let macPairs: [DeclarationPair] = [
        macPair(1, "^27[.]0([.][0-1])?$", boards: ["J413AP", "J613AP"]),
        macPair(2, "^26[.][0-5]([.][0-9]+)*$", boards: ["J413AP", "J613AP"]),
        macPair(3, "^15[.]([0-6]([.][0-9]+)*|7([.][0-3])?)$", boards: ["J413AP", "J613AP", "J132AP"]),
    ]

    /// The iPad Blueprint: one pair per step, each step for its OS family.
    public static let iPadPairs: [DeclarationPair] = [
        DeclarationPair(blueprintID: iPadBlueprintID, step: 1, number: 1,
                        predicate: "@status(device.operating-system.family) == 'iPadOS'", family: .iPad, versions: nil, boards: []),
        // the iOS step: for iPhones, never for these iPads
        DeclarationPair(blueprintID: iPadBlueprintID, step: 2, number: 1,
                        predicate: "@status(device.operating-system.family) == 'iOS'", family: nil, versions: nil, boards: []),
    ]

    private static func macPair(_ number: Int, _ versions: String, boards: [String]) -> DeclarationPair {
        let list = boards.map { "\"\($0)\"" }.joined(separator: ", ")
        return DeclarationPair(
            blueprintID: macBlueprintID, step: 1, number: number,
            predicate: "status.device.operating-system.family == \"macOS\" AND status.device.operating-system.version MATCHES "
                + "\"\(versions)\" AND status.softwareupdate.device-id IN {\(list)}",
            family: .mac, versions: versions, boards: boards)
    }

    /// The Blueprint pairs a device holds: none for the Loaner Macs, which
    /// no Blueprint reaches.
    static func pairs(for device: Device) -> [DeclarationPair] {
        if loanerMacNumbers.contains(device.number) { return [] }
        return device.family == .mac ? macPairs : iPadPairs
    }

    /// The two Macs of the static Loaner Macs group.
    static let loanerMacNumbers: Set<Int> = [207, 208]

    /// How a device’s copy of a configuration stands, besides applied or
    /// not for it: pending, awaiting sync, invalid or failed.
    static func configurationStatus(_ device: Device) -> (status: String, valid: String, reasons: [[String: Any]]) {
        switch device.number {
        case 111: ("PENDING", "VALID", [])
        // Jamf changed the declaration; the device hasn't fetched it yet
        case 110, 205: ("AWAITING_SYNC", "VALID", [])
        case 109:
            ("UNSUCCESSFUL", "INVALID", [["code": "Error.ConfigurationCannotBeApplied",
                                          "description": "The declaration isn’t valid on this OS version.",
                                          "details": [["key": "Error", "description": "Software update enforcement isn’t supported on iPadOS 17."]]]])
        case 113:
            ("UNSUCCESSFUL", "VALID", [["code": "Error.ConfigurationFailed", "description": "Configuration failed.",
                                        "details": [["key": "Error", "description": "Software update enforcement needs a supervised device."]]]])
        default: ("SUCCESSFUL", "VALID", [])
        }
    }

    // MARK: History

    /// An earlier refresh of one demo Blueprint, for an app that keeps a
    /// history: its software update then, a group that was in its scope
    /// then only, and the devices on target then (by `Device.number`).
    public struct PastRefresh: Sendable, Hashable {
        public let daysAgo: Int
        public let blueprintID: String
        public let enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement
        /// A group in the scope then, besides today’s.
        public let extraScopeGroup: JamfPro.DeviceGroup?
        public let onTarget: Set<Int>
    }

    /// Five earlier daily refreshes per Blueprint, oldest first. Four and
    /// five days back the software update was another one; two and three
    /// days back a pilot group was in the scope too. Each day back, fewer
    /// devices were on target.
    public static func pastRefreshes(now: Date = Date()) -> [PastRefresh] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let earlierDeadline = calendar.date(byAdding: .day, value: -3, to: now) ?? now
        let parts = calendar.dateComponents([.year, .month, .day], from: earlierDeadline)
        let earlierLocal = String(format: "%04d-%02d-%02dT17:00:00", parts.year ?? 2026, parts.month ?? 1, parts.day ?? 1)
        var refreshes: [PastRefresh] = []
        for (blueprint, family) in [(iPadBlueprintID, Family.iPad), (macBlueprintID, Family.mac)] {
            let current = devices.filter { $0.family == family && $0.state == .onTarget && $0.betaEnrollment == nil }.map(\.number)
            let pilot = JamfPro.DeviceGroup(groupID: "699", name: family == .iPad ? "Pilot iPads" : "Pilot Macs", isSmart: false,
                                            kind: family == .iPad ? .mobileDevice : .computer)
            for daysAgo in (1...5).reversed() {
                let earlier = daysAgo > 3
                let enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement = switch (family, earlier) {
                case (.iPad, true): .specific(targetOSVersion: "27.0.1", targetLocalDateTime: earlierLocal, detailsURL: nil)
                case (.mac, true): .semantic(minorEnforceAfterDays: 14, deploymentTime: "17:00")
                case (.iPad, false):
                    .specific(targetOSVersion: targetVersion, targetLocalDateTime: deadline(now: now), detailsURL: "https://intranet.contoso.example/updates")
                case (.mac, false): .semantic(minorEnforceAfterDays: macDelayDays, deploymentTime: "17:00")
                }
                refreshes.append(PastRefresh(daysAgo: daysAgo, blueprintID: blueprint, enforcement: enforcement,
                                             extraScopeGroup: (2...3).contains(daysAgo) ? pilot : nil,
                                             onTarget: Set(current.dropLast(min(daysAgo, current.count)))))
            }
        }
        return refreshes
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
                             _ zone: String?, _ state: State, contact: Int = 0, passcode: Bool = false,
                             supervised: Bool = true) -> Device {
        Device(number: number, family: .iPad, name: name, model: model, modelIdentifier: identifier, boardID: nil,
               osVersion: os, osBuild: DemoAppleReleaseServer.build(of: os, mac: false), timeZone: zone,
               lastContactDaysAgo: contact, state: state, passcodePresent: passcode, supervised: supervised,
               betaEnrollment: nil, rapidSecurityResponse: nil, batteryHealth: nil, fileVaultState: nil, bootstrapToken: nil)
    }

    private static func mac(_ number: Int, _ name: String, _ model: String, _ identifier: String, _ board: String,
                            _ os: String, _ state: State, contact: Int = 0, rapidSecurityResponse: String? = nil,
                            battery: String = "normal", fileVault: String = "ENCRYPTED", bootstrap: String = "ESCROWED",
                            build: String? = nil, beta: String? = nil) -> Device {
        Device(number: number, family: .mac, name: name, model: model, modelIdentifier: identifier, boardID: board,
               osVersion: os, osBuild: build ?? DemoAppleReleaseServer.build(of: os, mac: true), timeZone: nil,
               lastContactDaysAgo: contact, state: state, passcodePresent: false, supervised: true, betaEnrollment: beta,
               rapidSecurityResponse: rapidSecurityResponse, batteryHealth: battery, fileVaultState: fileVault,
               bootstrapToken: bootstrap)
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
        case 6 where Array(p[0...3]) == ["ddm", "report", "v1", "declarations"] && p[5] == "devices":
            return declarationDevices(p[4], request)
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

    private var studioMacs: [DemoSoftwareUpdate.Device] {
        DemoSoftwareUpdate.macs.filter { !DemoSoftwareUpdate.loanerMacNumbers.contains($0.number) }
    }
    private var loanerMacs: [DemoSoftwareUpdate.Device] {
        DemoSoftwareUpdate.macs.filter { DemoSoftwareUpdate.loanerMacNumbers.contains($0.number) }
    }

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
            "managed": true, "supervised": device.supervised, "declarativeDeviceManagementEnabled": true,
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
            "security": ["bootstrapTokenEscrowedStatus": device.bootstrapToken ?? "NOT_SUPPORTED", "bootstrapTokenAllowed": true],
            "diskEncryption": [
                "individualRecoveryKeyValidityStatus": device.fileVaultState == "ENCRYPTED" ? "VALID" : "NOT_APPLICABLE",
                "bootPartitionEncryptionDetails": ["partitionName": "Macintosh HD (Boot Partition)",
                                                   "partitionFileVault2State": device.fileVaultState ?? "UNKNOWN",
                                                   "partitionFileVault2Percent": device.fileVaultState == "ENCRYPTED" ? 100 : 0],
            ],
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
        let build = reported == device.osVersion ? device.osBuild : DemoAppleReleaseServer.build(of: reported, mac: device.family == .mac)
        add("device.operating-system.build-version", build)
        add("device.model.identifier", device.modelIdentifier)
        if let board = device.boardID { add("softwareupdate.device-id", board) }
        add("passcode.is-present", device.passcodePresent ? "true" : "false")
        add("softwareupdate.beta-enrollment", device.betaEnrollment ?? "")
        if let health = device.batteryHealth { add("device.power.battery-health", health) }
        if let extra = device.rapidSecurityResponse {
            add("device.operating-system.supplemental.build-version", build + "a")
            add("device.operating-system.supplemental.extra-version", extra)
        }
        add("management.declarations", managementDeclarations(device))
        func pending(_ version: String) {
            add("softwareupdate.pending-version",
                "{os-version=\(version), build-version=\(DemoAppleReleaseServer.build(of: version, mac: device.family == .mac)), target-local-date-time=\(device.family == .mac ? DemoAppleReleaseServer.macDeadline(of: version, now: now) : DemoSoftwareUpdate.deadline(now: now))}")
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

    /// The version a device’s report gives, which its declarations’ predicates see.
    private func reportedVersion(_ device: DemoSoftwareUpdate.Device) -> String {
        device.state == .onTarget ? DemoSoftwareUpdate.targetVersion : device.osVersion
    }

    /// Every declaration report of one device: each Blueprint pair (an
    /// activation false for it reports `Info.Predicate` with the predicate,
    /// its configuration `Error.ActivationFailed`), and a Wi-Fi
    /// configuration. None for a device that never sent a status report.
    func reports(_ device: DemoSoftwareUpdate.Device) -> [[String: Any]] {
        guard device.state != .noReport else { return [] }
        let reported = iso(Double(device.lastContactDaysAgo) + 0.3)
        let changed = iso(Double(DemoSoftwareUpdate.updateStartedDaysAgo))
        func report(_ identifier: String, _ type: String, status: String, active: Bool, valid: String = "VALID",
                    reasons: [[String: Any]] = []) -> [String: Any] {
            ["declarationIdentifier": identifier, "deviceId": device.platformID, "channel": "SYSTEM", "type": type,
             "status": status, "active": active, "validityState": valid, "reasons": reasons, "dateUpdated": changed,
             "lastReportTime": reported]
        }
        var results: [[String: Any]] = []
        for pair in DemoSoftwareUpdate.pairs(for: device) {
            if pair.applies(to: device, version: reportedVersion(device)) {
                let configuration = DemoSoftwareUpdate.configurationStatus(device)
                results.append(report(pair.activation, "ACTIVATION", status: "SUCCESSFUL", active: true))
                results.append(report(pair.configuration, "CONFIGURATION", status: configuration.status, active: true,
                                      valid: configuration.valid, reasons: configuration.reasons))
            } else {
                results.append(report(pair.activation, "ACTIVATION", status: "UNSUCCESSFUL", active: false, reasons: [
                    ["code": "Info.Predicate", "description": "The activation predicate evaluated to false.",
                     "details": [["key": "Predicate", "description": pair.predicate]]],
                ]))
                results.append(report(pair.configuration, "CONFIGURATION", status: "UNSUCCESSFUL", active: false,
                                      reasons: [["code": "Error.ActivationFailed", "description": "No activation is active."]]))
            }
        }
        results.append(report("com.contoso.wifi", "CONFIGURATION", status: "SUCCESSFUL", active: true))
        return results
    }

    /// `management.declarations` as Jamf Pro keeps it: `{key=value}` text
    /// with the activations and configurations the device holds.
    private func managementDeclarations(_ device: DemoSoftwareUpdate.Device) -> String {
        let all = reports(device)
        func list(_ type: String) -> String {
            all.filter { $0["type"] as? String == type }.enumerated().map { index, report in
                "{identifier=\(report["declarationIdentifier"] as? String ?? ""), active=\(report["active"] as? Bool ?? false), "
                    + "valid=valid, server-token=\(String(format: "%08x", device.number * 100 + index))}"
            }.joined(separator: ", ")
        }
        return "{activations=[\(list("ACTIVATION"))], assets=[], configurations=[\(list("CONFIGURATION"))], management=[]}"
    }

    /// Whether a report passes an `active==…` filter (`active==true,active==false`: every report).
    private static func passes(_ report: [String: Any], filter: String) -> Bool {
        let wanted = Set(filter.split(separator: ",").compactMap { part -> Bool? in
            let clause = part.trimmingCharacters(in: .whitespaces)
            return clause == "active==true" ? true : clause == "active==false" ? false : nil
        })
        if wanted.isEmpty { return true }
        return wanted.contains(report["active"] as? Bool ?? false)
    }

    private func reportPage(_ device: DemoSoftwareUpdate.Device, _ request: DemoRequest) -> DemoResponse {
        var results = reports(device)
        let filter = request.query["filter"] ?? ""
        if filter.hasPrefix("declarationIdentifier==") {
            let prefix = String(filter.dropFirst("declarationIdentifier==".count)).replacingOccurrences(of: "*", with: "")
            results = results.filter { ($0["declarationIdentifier"] as? String ?? "").hasPrefix(prefix) }
        } else {
            results = results.filter { Self.passes($0, filter: filter) }
        }
        return DemoJSON.response(200, ["deviceId": device.platformID, "totalCount": results.count, "results": results])
    }

    /// The devices that reported one declaration, a page at a time. Like
    /// Jamf’s, the list answers 400 without a filter; nothing reported: 404.
    private func declarationDevices(_ identifier: String, _ request: DemoRequest) -> DemoResponse {
        guard let filter = request.query["filter"], !filter.isEmpty else {
            return DemoJSON.response(400, ["httpStatus": 400, "errors": [["code": "INVALID_FIELD", "field": "filter",
                                                                          "description": "filter is required"]]])
        }
        let results = DemoSoftwareUpdate.devices.flatMap(reports)
            .filter { $0["declarationIdentifier"] as? String == identifier && Self.passes($0, filter: filter) }
        guard !results.isEmpty else { return notFound() }
        let page = Int(request.query["page"] ?? "0") ?? 0
        let size = max(1, Int(request.query["size"] ?? "100") ?? 100)
        return DemoJSON.response(200, ["totalCount": results.count, "results": Array(results.dropFirst(page * size).prefix(size))])
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
/// the demo network’s own hosts (never the real ones). `isUnreachable`
/// makes both feeds fail, as when Apple’s data can’t be read.
public nonisolated final class DemoAppleReleaseServer: DemoServer, @unchecked Sendable {
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
        ("27.1", "26B5060", supportedBoards, 12), ("27.0.2", "26A5350", supportedBoards, 25), ("27.0.1", "26A5341", supportedBoards, 40),
        ("26.6", "25G5060", supportedBoards, 30), ("15.7.4", "24G5420", supportedBoards + ["J132AP"], 60),
    ]
    private static let supportedIPads = ["iPad13,1", "iPad13,18", "iPad14,8", "iPad15,7", "iPad16,1", "iPad16,3"]
    private static let supportedBoards = ["J413AP", "J613AP"]

    /// The deadline a Mac reports for a pending version, as a moment with
    /// an offset (as Macs write it): the Mac Blueprint’s delay after the
    /// release, at 17:00 UTC.
    static func macDeadline(of version: String, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let daysAgo = macReleases.first { $0.version == version }?.daysAgo ?? 0
        let day = calendar.startOfDay(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
        let deadline = (calendar.date(byAdding: .day, value: DemoSoftwareUpdate.macDelayDays, to: day) ?? day).addingTimeInterval(17 * 3_600)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.string(from: deadline)
    }

    /// The made-up build of a demo version (`unknown` for one it doesn’t have).
    public static func build(of version: String, mac: Bool) -> String {
        (mac ? macReleases.first { $0.version == version }?.build : iOSReleases.first { $0.version == version }?.build) ?? "unknown"
    }

    private let now: Date
    private let lock = NSLock()
    private var unreachable = false

    public init(now: Date = Date()) {
        self.now = now
    }

    /// Both feeds fail while it is on (404, which isn’t retried), as when
    /// Apple’s release data can’t be read. Off by default.
    public var isUnreachable: Bool {
        get { lock.withLock { unreachable } }
        set { lock.withLock { unreachable = newValue } }
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
        if isUnreachable { return DemoJSON.response(404, [:]) }
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
