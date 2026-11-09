import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

// 1.5.0 (decided by Jordy on 2026-11-09): the read-only calls of an app that
// reports on software updates: DDM status items typed, groups and members
// with inventory, Declaration Reporting and a Blueprint’s software update.
// Made-up devices and IDs only.

private let environment = "0c6c4f86-1111-4a3c-9d7e-2f1b3c4d5e6f"

private func platform(_ server: MockServer, log: ActivityLog? = nil) throws -> JamfPlatform.Client {
    try JamfPlatform.Client(baseURL: URL(string: "https://eu.api.jamfcloud.com")!, scope: .environment(environment),
                            tokens: FixedToken("tok"),
                            recorder: RequestRecorder(session: server.session, log: log, service: "Jamf Platform API"),
                            sleep: { _ in }, random: { 0 })
}

private func direct(_ server: MockServer) throws -> JamfPlatform.Client {
    try JamfPlatform.Client(baseURL: URL(string: "https://jamf.example.com")!, scope: .organization, server: .jamfPro,
                            tokens: FixedToken("tok"), recorder: RequestRecorder(session: server.session, log: nil, service: "Jamf Pro"),
                            sleep: { _ in }, random: { 0 })
}

private func items(_ pairs: [(String, String?)], time: String = "2026-11-08T10:00:00") -> [JamfPro.StatusItem] {
    pairs.map { JamfPro.StatusItem(key: $0.0, value: $0.1, lastUpdateTime: time) }
}

private func hints(_ error: Error) -> String {
    (error as? JamfPlatform.APIError)?.standardHints.joined(separator: " ") ?? ""
}

@Suite("1.5.0: a device’s software update status from its DDM status items")
struct SoftwareUpdateStatusTests {
    @Test("Nested values as flattened keys or in Java’s {key=value} text read the same")
    func nested() {
        let flattened = JamfPro.SoftwareUpdateStatus(items: items([
            ("softwareupdate.install-state", "downloading"),
            ("softwareupdate.pending-version.os-version", "27.1"),
            ("softwareupdate.pending-version.build-version", "24B5074"),
            ("softwareupdate.failure-reason.count", "2"),
            ("softwareupdate.failure-reason.reason", "Passcode required"),
        ]))
        let text = JamfPro.SoftwareUpdateStatus(items: items([
            ("softwareupdate.install-state", "downloading"),
            ("softwareupdate.pending-version", "{os-version=27.1, build-version=24B5074, target-local-date-time=2026-11-16T17:00:00}"),
            ("softwareupdate.failure-reason", "{count=2, reason=Passcode required, timestamp=2026-11-08T09:00:00Z}"),
        ]))
        for status in [flattened, text] {
            #expect(status.installState == .downloading)
            #expect(status.installState?.isBusy == true)
            #expect(status.pendingVersion?.osVersion == "27.1")
            #expect(status.pendingVersion?.buildVersion == "24B5074")
            #expect(status.failure?.count == 2)
            #expect(status.failure?.reason == "Passcode required")
        }
        #expect(text.pendingVersion?.targetLocalDateTime == "2026-11-16T17:00:00")
        #expect(text.failure?.timestamp == "2026-11-08T09:00:00Z")
    }

    @Test("A value in JSON form is read too")
    func jsonValue() {
        let status = JamfPro.SoftwareUpdateStatus(items: items([
            ("softwareupdate.pending-version", #"{"os-version":"27.1","build-version":"24B5074"}"#),
        ]))
        #expect(status.pendingVersion == .init(osVersion: "27.1", buildVersion: "24B5074"))
    }

    @Test("OS, model, board ID, beta, passcode and the install reasons")
    func deviceItems() {
        let status = JamfPro.SoftwareUpdateStatus(items: items([
            ("device.operating-system.version", "27.0.1"),
            ("device.operating-system.build-version", "24A5341"),
            ("device.model.identifier", "Mac14,2"),
            ("softwareupdate.device-id", "J413AP"),
            ("softwareupdate.beta-enrollment", ""),
            ("passcode.is-present", "false"),
            ("softwareupdate.install-reason", "{reason=[{softwareupdate-reason=declaration, declaration-id=Blueprint_x}, {softwareupdate-reason=mdm}]}"),
        ]))
        #expect(status.osVersion == "27.0.1")
        #expect(status.osBuild == "24A5341")
        #expect(status.modelIdentifier == "Mac14,2")
        #expect(status.deviceID == "J413AP")
        #expect(status.betaEnrollment == nil)
        #expect(status.passcodePresent == false)
        #expect(status.installReasons == ["declaration", "mdm"])
        #expect(status.installState == nil)
        #expect(status.itemCount == 7)
    }

    @Test("Unknown states are kept; empty and null values are missing")
    func states() {
        #expect(JamfPro.SoftwareUpdateStatus.InstallState("Prepared") == .prepared)
        #expect(JamfPro.SoftwareUpdateStatus.InstallState("waiting").isBusy)
        #expect(!JamfPro.SoftwareUpdateStatus.InstallState("failed").isBusy)
        #expect(JamfPro.SoftwareUpdateStatus.InstallState("staged") == .other("staged"))
        let status = JamfPro.SoftwareUpdateStatus(items: items([("softwareupdate.install-state", "null"),
                                                                 ("softwareupdate.pending-version", "")]))
        #expect(status.installState == nil)
        #expect(status.pendingVersion == nil)
        #expect(status.failure == nil)
    }

    @Test("The newest time is taken from the software update and OS items only")
    func newest() {
        let status = JamfPro.SoftwareUpdateStatus(items: [
            .init(key: "softwareupdate.install-state", value: "none", lastUpdateTime: "2026-11-01T08:00:00"),
            .init(key: "device.operating-system.version", value: "27.0.1", lastUpdateTime: "2026-11-03T08:00:00"),
            .init(key: "passcode.is-present", value: "true", lastUpdateTime: "2026-11-09T08:00:00"),
        ])
        #expect(status.newestUpdate == "2026-11-03T08:00:00")
        #expect(JamfPro.SoftwareUpdateStatus(items: []).newestUpdate == nil)
    }

    @Test("Server times are read in the server’s time zone; a time with a zone keeps it")
    func serverTimes() throws {
        let utc = try #require(JamfPro.serverDate("2026-11-09T14:05:31", timeZone: TimeZone(identifier: "UTC")!))
        let brussels = try #require(JamfPro.serverDate("2026-11-09T14:05:31.250", timeZone: TimeZone(identifier: "Europe/Brussels")!))
        #expect(utc.timeIntervalSince(brussels) == 3_600)
        let zoned = try #require(JamfPro.serverDate("2026-11-09T14:05:31Z", timeZone: TimeZone(identifier: "Asia/Tokyo")!))
        #expect(zoned == utc)
        #expect(JamfPro.serverDate("yesterday", timeZone: .gmt) == nil)
    }

    @Test("The client reads the report; none for 404; a refusal names devices:read")
    func client() async throws {
        let server = MockServer { request in
            if request.path.contains("/M-1/") {
                return .json(200, #"{"statusItems":[{"key":"softwareupdate.install-state","value":"installing","lastUpdateTime":"2026-11-09T07:00:00"},{"key":"passcode.is-present","value":true},{"key":"softwareupdate.failure-reason","value":{"count":1,"reason":"Low battery"}}]}"#)
            }
            if request.path.contains("/M-2/") { return .json(404, #"{"httpStatus":404,"errors":[]}"#) }
            return .json(403, #"{"httpStatus":403,"errors":[]}"#)
        }
        let client = try platform(server)
        let status = try #require(try await client.softwareUpdateStatus(managementID: "M-1", kind: .mobileDevice))
        #expect(status.installState == .installing)
        #expect(status.passcodePresent == true)
        #expect(status.failure?.reason == "Low battery")
        #expect(server.requests.first?.path == "/pro/v1/ddm/M-1/status-items")
        #expect(server.requests.first?.method == "GET")
        #expect(try await client.softwareUpdateStatus(managementID: "M-2", kind: .mobileDevice) == nil)
        await #expect {
            try await client.softwareUpdateStatus(managementID: "M-3", kind: .computer)
        } throws: { hints($0).contains("“devices:read” permission") }
    }
}

@Suite("1.5.0: Jamf Pro groups and their members with inventory")
struct JamfProGroupTests {
    @Test("Mobile device and computer groups, each kind from its own list")
    func lists() async throws {
        let server = MockServer { request in
            switch request.path {
            case "/pro/v2/mobile-device-groups":
                return .json(200, #"[{"id":7,"name":"Field iPads","description":"","isSmartGroup":true},{"id":8,"name":"Spares","isSmartGroup":false}]"#)
            case "/pro/v1/computer-groups":
                return .json(200, #"[{"id":"3","name":"Studio Macs","smartGroup":true},{"id":"4","name":"Loaners","smartGroup":false},{"name":"no id"}]"#)
            default: return .json(404, "{}")
            }
        }
        let groups = try await platform(server).jamfProGroups()
        #expect(groups == [
            JamfPro.DeviceGroup(id: "7", name: "Field iPads", isSmart: true, kind: .mobileDevice, description: nil),
            JamfPro.DeviceGroup(id: "8", name: "Spares", isSmart: false, kind: .mobileDevice),
            JamfPro.DeviceGroup(id: "3", name: "Studio Macs", isSmart: true, kind: .computer),
            JamfPro.DeviceGroup(id: "4", name: "Loaners", isSmart: false, kind: .computer),
        ])
        #expect(server.requests.allSatisfy { $0.method == "GET" })
    }

    @Test("A mobile group’s members come with their inventory, every page")
    func mobileMembers() async throws {
        let server = MockServer { request in
            let page = Int(request.queryValue("page") ?? "0") ?? 0
            let numbers = page == 0 ? Array(1...100) : [101]
            let records = numbers.map { number in
                #"{"mobileDeviceId":"\#(number)","displayName":"iPad \#(number)","serialNumber":"ZZTEST\#(number)","managementId":"M-\#(number)","osVersion":"27.0.1","osBuild":"24A5341","model":"iPad Air","modelIdentifier":"iPad13,18","timeZone":"Europe/Brussels","lastContactDate":"2026-11-08T10:00:00.000Z","passcodePresent":true,"batteryLevel":"42","availableSpaceMb":1900,"roaming":false,"declarativeDeviceManagementEnabled":true}"#
            }
            return .json(200, #"{"totalCount":101,"results":[\#(records.joined(separator: ","))]}"#)
        }
        let group = JamfPro.DeviceGroup(id: "7", name: "Field iPads", isSmart: true, kind: .mobileDevice)
        let members = try await platform(server).members(of: group)
        #expect(members.count == 101)
        let first = try #require(members.first)
        #expect(first.id == "1" && first.kind == .mobileDevice)
        #expect(first.managementID == "M-1")
        #expect(first.timeZone == "Europe/Brussels")
        #expect(first.modelIdentifier == "iPad13,18")
        #expect(first.osBuild == "24A5341")
        #expect(first.passcodePresent == true)
        #expect(first.batteryLevel == 42)
        #expect(first.availableSpaceMB == 1900)
        #expect(first.ddmEnabled == true)
        #expect(first.lastContact == JamfPlatform.date(from: "2026-11-08T10:00:00.000Z"))
        #expect(server.requests.map(\.path) == Array(repeating: "/pro/v2/mobile-device-groups/smart-group-membership/7", count: 2))
        #expect(server.requests.map { $0.queryValue("page-size") } == ["100", "100"])

        _ = try await platform(server).members(of: .init(id: "8", name: "Spares", isSmart: false, kind: .mobileDevice))
        #expect(server.requests.last?.path == "/pro/v2/mobile-device-groups/static-group-membership/8")
    }

    @Test("A refused membership names both Platform permissions")
    func refused() async throws {
        let server = MockServer { _ in .json(403, #"{"httpStatus":403,"errors":[]}"#) }
        let group = JamfPro.DeviceGroup(id: "7", name: "Field iPads", isSmart: true, kind: .mobileDevice)
        await #expect {
            try await platform(server).members(of: group)
        } throws: { hints($0).contains("the “device-groups:read” and “devices:read” permissions") }
        // on a Jamf Pro reached directly, the privileges are named instead
        await #expect {
            try await direct(server).members(of: group)
        } throws: { hints($0).contains("Read Smart Mobile Device Groups") }
    }

    @Test("A smart computer group: its IDs, then the computers in batches of 100, in order")
    func smartComputers() async throws {
        let ids = (1...150).map(String.init)
        let server = MockServer { request in
            if request.path == "/pro/v3/computer-groups/smart-group-membership/3" {
                return .json(200, #"{"members":[\#(ids.reversed().joined(separator: ","))]}"#)
            }
            let filter = request.queryValue("filter") ?? ""
            let asked = DemoSoftwareUpdateServer.ids(in: filter)
            let records = asked.sorted().map { id in
                #"{"id":"\#(id)","general":{"name":"Mac \#(id)","managementId":"MC-\#(id)","lastContactTime":"2026-11-07T10:00:00Z","remoteManagement":{"managed":true}},"hardware":{"serialNumber":"ZZTESTM\#(id)","modelIdentifier":"Mac14,2"},"operatingSystem":{"version":"27.0.1","build":"26A5341"}}"#
            }
            return .json(200, #"{"totalCount":\#(records.count),"results":[\#(records.joined(separator: ","))]}"#)
        }
        let members = try await platform(server).members(of: .init(id: "3", name: "Studio Macs", isSmart: true, kind: .computer))
        #expect(members.map(\.id) == ids.reversed())
        let mac = try #require(members.first { $0.id == "1" })
        #expect(mac.managementID == "MC-1")
        #expect(mac.osVersion == "27.0.1" && mac.osBuild == "26A5341")
        #expect(mac.lastContact == JamfPlatform.date(from: "2026-11-07T10:00:00Z"))
        #expect(mac.managed == true)
        #expect(mac.timeZone == nil)
        let inventory = server.requests.filter { $0.path == "/pro/v4/computers-inventory" }
        #expect(inventory.count == 2)
        #expect(inventory.allSatisfy { ($0.queryValue("filter") ?? "").hasPrefix("id=in=(") })
        #expect(Set(inventory.flatMap { DemoSoftwareUpdateServer.ids(in: $0.queryValue("filter") ?? "") }) == Set(ids))
    }

    @Test("A static computer group’s members come from the Classic API")
    func staticComputers() async throws {
        let server = MockServer { request in
            if request.path == "/proclassic/computergroups/id/4" {
                #expect(request.header("Accept") == "application/json")
                return .json(200, #"{"computer_group":{"id":4,"name":"Loaners","is_smart":false,"computers":[{"id":12,"name":"Loaner","serial_number":"ZZTESTM12"}]}}"#)
            }
            return .json(200, #"{"totalCount":1,"results":[{"id":"12","general":{"name":"Loaner"},"hardware":{"serialNumber":"ZZTESTM12"}}]}"#)
        }
        let members = try await platform(server).members(of: .init(id: "4", name: "Loaners", isSmart: false, kind: .computer))
        #expect(members.map(\.serialNumber) == ["ZZTESTM12"])
        #expect(server.requests.last?.queryValue("filter") == "id=in=(12)")
    }

    @Test("An empty group sends no inventory request")
    func emptyGroup() async throws {
        let server = MockServer { _ in .json(200, #"{"members":[]}"#) }
        let members = try await platform(server).members(of: .init(id: "3", name: "Empty", isSmart: true, kind: .computer))
        #expect(members.isEmpty)
        #expect(server.requests.count == 1)
    }
}

@Suite("1.5.0: Declaration Reporting")
struct DeclarationReportTests {
    @Test("A device’s declarations, every page with page and size, typed")
    func deviceReport() async throws {
        let blueprint = "0b1e0000-aaaa-4000-8000-000000000123"
        let server = MockServer { request in
            let page = Int(request.queryValue("page") ?? "0") ?? 0
            let results = page == 0
                ? (1...100).map { #"{"declarationIdentifier":"other-\#($0)","status":"SUCCESSFUL","active":true,"validityState":"VALID"}"# }
                : [#"{"declarationIdentifier":"Blueprint_\#(blueprint)_s2_c1_sys_cfg1","deviceId":"P-1","type":"CONFIGURATION","status":"UNSUCCESSFUL","active":false,"validityState":"INVALID","reasons":[{"code":"Error.ConfigurationCannotBeApplied","description":"Can’t apply","details":[{"key":"Error","description":"Bad version"}]}],"dateUpdated":"2026-11-01T10:00:00Z","lastReportTime":"2026-11-08T10:00:00.123Z"}"#]
            return .json(200, #"{"deviceId":"P-1","totalCount":101,"results":[\#(results.joined(separator: ","))]}"#)
        }
        let reports = try #require(try await platform(server).declarationReports(deviceID: "P-1", filter: "declarationIdentifier==Blueprint_*"))
        #expect(reports.count == 101)
        let last = try #require(reports.last)
        #expect(last.status == .unsuccessful)
        #expect(last.validity == .invalid)
        #expect(last.active == false)
        #expect(last.blueprintID == blueprint)
        #expect(last.blueprintStepIndex == 1)
        #expect(last.reasons == [.init(code: "Error.ConfigurationCannotBeApplied", description: "Can’t apply",
                                       details: [.init(key: "Error", description: "Bad version")])])
        #expect(last.lastReportTime == JamfPlatform.date(from: "2026-11-08T10:00:00.123Z"))
        #expect(reports.first?.blueprintID == nil && reports.first?.blueprintStepIndex == nil)
        #expect(server.requests.map(\.path) == Array(repeating: "/ddm/report/v1/devices/P-1/declarations", count: 2))
        #expect(server.requests.allSatisfy { $0.queryValue("size") == "100" && $0.queryValue("page-size") == nil })
        #expect(server.requests.first?.queryValue("filter") == "declarationIdentifier==Blueprint_*")
    }

    @Test("Statuses and validity it doesn’t know are kept")
    func unknownValues() {
        #expect(JamfPlatform.DeclarationReport.Status("AWAITING_SYNC") == .awaitingSync)
        #expect(JamfPlatform.DeclarationReport.Status("NEW") == .other("NEW"))
        #expect(JamfPlatform.DeclarationReport.Status(nil) == .unknown)
        #expect(JamfPlatform.DeclarationReport.Validity("valid") == .valid)
    }

    @Test("Per declaration; none for 404; a refusal names declarations:read")
    func perDeclaration() async throws {
        let server = MockServer { request in
            if request.path.hasPrefix("/ddm/report/v1/declarations/known/") {
                return .json(200, #"{"totalCount":1,"results":[{"declarationIdentifier":"known","deviceId":"P-9","status":"PENDING"}]}"#)
            }
            if request.path.contains("missing") { return .json(404, #"{"httpStatus":404,"errors":[]}"#) }
            return .json(403, #"{"httpStatus":403,"errors":[]}"#)
        }
        let client = try platform(server)
        let reports = try await client.declarationReports(declarationIdentifier: "known")
        #expect(reports?.map(\.deviceID) == ["P-9"])
        #expect(reports?.first?.status == .pending)
        #expect(server.requests.first?.path == "/ddm/report/v1/declarations/known/devices")
        #expect(try await client.declarationReports(deviceID: "missing") == nil)
        await #expect {
            try await client.declarationReports(deviceID: "refused")
        } throws: { hints($0).contains("“declarations:read” permission") }
    }
}

@Suite("1.5.0: a Blueprint’s software update")
struct BlueprintSoftwareUpdateTests {
    private func blueprint(_ steps: String) throws -> JamfPlatform.BlueprintDetail {
        try JamfPlatform.BlueprintDetail(data: Data(#"{"id":"b1","name":"Updates","steps":\#(steps)}"#.utf8))
    }

    @Test("Manual, latest and semantic enforcements, with their step and predicate")
    func components() throws {
        let detail = try blueprint(#"""
        [{"name":"iPadOS","activationPredicate":"@status(device.operating-system.family) == 'iPadOS'","components":[
           {"identifier":"com.jamf.ddm.passcode","configuration":{}},
           {"identifier":"com.jamf.ddm.sw-updates","configuration":{"enforcementType":"MANUAL","targetOSVersion":"27.1","targetLocalDateTime":"2026-11-16T17:00:00","detailsURL":{"Value":"https://example.com/u","Included":true}}}]},
         {"name":"Macs","components":[
           {"identifier":"com.jamf.ddm.sw-updates","configuration":{"enforcementType":"AUTOMATIC","strategy":"LATEST","enforceAfterDays":14,"deploymentTime":"16:00"}},
           {"identifier":"com.jamf.ddm.sw-updates","configuration":{"enforcementType":"AUTOMATIC","strategy":"SEMANTIC","rules":{"minor":{"enforceAfterDays":7,"deploymentTime":"09:30"}}}}]}]
        """#)
        let blocks = detail.softwareUpdateBlocks
        #expect(blocks.count == 3)
        #expect(blocks[0] == JamfPlatform.SoftwareUpdateBlock(
            stepIndex: 0, componentIndex: 1, stepName: "iPadOS",
            activationPredicate: "@status(device.operating-system.family) == 'iPadOS'",
            enforcement: .specific(targetOSVersion: "27.1", targetLocalDateTime: "2026-11-16T17:00:00", detailsURL: "https://example.com/u")))
        #expect(blocks[0].targetOSVersion == "27.1")
        #expect(blocks[0].targetLocalDateTime == "2026-11-16T17:00:00")
        #expect(blocks[1].enforcement == .latest(enforceAfterDays: 14, deploymentTime: "16:00"))
        #expect(blocks[1].activationPredicate == nil && blocks[1].targetOSVersion == nil)
        #expect(blocks[2].enforcement == .semantic(minorEnforceAfterDays: 7, deploymentTime: "09:30"))
    }

    @Test("A details URL that isn’t included is left out")
    func detailsNotIncluded() throws {
        let detail = try blueprint(#"[{"components":[{"identifier":"com.jamf.ddm.sw-updates","configuration":{"enforcementType":"MANUAL","targetOSVersion":"27.1","targetLocalDateTime":"2026-11-16T17:00:00","detailsURL":{"Value":"https://example.com/u","Included":false}}}]}]"#)
        #expect(detail.softwareUpdateBlocks.first?.enforcement == .specific(targetOSVersion: "27.1", targetLocalDateTime: "2026-11-16T17:00:00", detailsURL: nil))
    }

    @Test("Apple’s declaration in a custom-declarations component, with its build")
    func customDeclaration() throws {
        let detail = try blueprint(#"""
        [{"components":[{"identifier":"com.jamf.ddm.custom-declarations","configuration":{"declarations":[
            {"type":"com.apple.configuration.passcode.settings","payload":{}},
            {"type":"com.apple.configuration.softwareupdate.enforcement.specific","channelType":"SYSTEM","kind":"CONFIGURATION","payloadKey":1,
             "payload":{"TargetOSVersion":"27.1","TargetBuildVersion":"24B5074","TargetLocalDateTime":"2026-11-16T17:00:00"}}]}}]}]
        """#)
        let block = try #require(detail.softwareUpdateBlocks.first)
        #expect(detail.softwareUpdateBlocks.count == 1)
        #expect(block.source == .customDeclaration)
        #expect(block.targetBuildVersion == "24B5074")
        #expect(block.targetOSVersion == "27.1")
    }

    @Test("An older component with days only reads as latest; anything else as unknown")
    func older() throws {
        let detail = try blueprint(#"[{"components":[{"identifier":"com.jamf.ddm.sw-updates","configuration":{"enforceAfterDays":7}},{"identifier":"com.jamf.ddm.sw-updates","configuration":{"enforcementType":"SOMETHING"}}]}]"#)
        #expect(detail.softwareUpdateBlocks.map(\.enforcement) == [.latest(enforceAfterDays: 7, deploymentTime: nil), .unknown("SOMETHING")])
    }

    @Test("The deadline is the device’s local time")
    func deadline() throws {
        let brussels = try #require(JamfPlatform.SoftwareUpdateBlock.deadline("2026-11-16T17:00:00", in: TimeZone(identifier: "Europe/Brussels")!))
        let newYork = try #require(JamfPlatform.SoftwareUpdateBlock.deadline("2026-11-16T17:00", in: TimeZone(identifier: "America/New_York")!))
        #expect(newYork.timeIntervalSince(brussels) == 6 * 3_600)
        #expect(JamfPlatform.SoftwareUpdateBlock.deadline("2026-11-16T17:00:00.809", in: .gmt) != nil)
        #expect(JamfPlatform.SoftwareUpdateBlock.deadline("soon", in: .gmt) == nil)
    }

    @Test("Blueprints.softwareUpdate reads the Blueprint once, with GET")
    func reader() async throws {
        let server = MockServer { _ in
            .json(200, #"{"id":"b1","name":"Updates","steps":[{"components":[{"identifier":"com.jamf.ddm.sw-updates","configuration":{"enforcementType":"MANUAL","targetOSVersion":"27.1","targetLocalDateTime":"2026-11-16T17:00:00"}}]}]}"#)
        }
        let result = try await JamfPlatform.Blueprints(client: try platform(server)).softwareUpdate(blueprintID: "b1")
        #expect(result.blueprint.id == "b1")
        #expect(result.blocks.first?.targetOSVersion == "27.1")
        #expect(server.requests.map { "\($0.method) \($0.path)" } == ["GET /blueprints/v1/blueprints/b1"])
    }
}
