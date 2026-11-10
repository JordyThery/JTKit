import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport
@testable import JTKitUITestSupport

// 1.6.0: read-only additions for an app that reports on software updates:
// a declaration’s device list with its filter, raw status items of every
// value type, a Mac’s FileVault, and the status items for a Rapid Security
// Response and battery health. Made-up devices and IDs only.

private func platform(_ server: MockServer) throws -> JamfPlatform.Client {
    try JamfPlatform.Client(baseURL: URL(string: "https://eu.api.jamfcloud.com")!,
                            scope: .environment("0c6c4f86-1111-4a3c-9d7e-2f1b3c4d5e6f"), tokens: FixedToken("tok"),
                            recorder: RequestRecorder(session: server.session, log: nil, service: "Jamf Platform API"),
                            sleep: { _ in }, random: { 0 })
}

private func hints(_ error: Error) -> String {
    (error as? JamfPlatform.APIError)?.standardHints.joined(separator: " ") ?? ""
}

private func queryValues(_ request: RecordedRequest, _ name: String) -> [String] {
    (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).filter { $0.name == name }.compactMap(\.value)
}

@Suite("1.6.0: a declaration’s devices")
struct DeclarationDevicesTests {
    @Test("Without a filter, every device is asked for: the list answers 400 to a request without one")
    func filterSent() async throws {
        let server = MockServer { request in
            guard request.queryValue("filter") == "active==true,active==false" else {
                return .json(400, #"{"httpStatus":400,"errors":[{"code":"INVALID_FIELD","description":"filter is required"}]}"#)
            }
            return .json(200, #"{"totalCount":2,"results":[{"declarationIdentifier":"cfg1","deviceId":"P-1","status":"SUCCESSFUL","active":true},{"declarationIdentifier":"cfg1","deviceId":"P-2","status":"AWAITING_SYNC","active":false}]}"#)
        }
        let reports = try await platform(server).declarationReports(declarationIdentifier: "cfg1")
        #expect(reports?.map(\.deviceID) == ["P-1", "P-2"])
        #expect(reports?.map(\.status) == [.successful, .awaitingSync])
        #expect(server.requests.count == 1)
        #expect(server.requests.first?.path == "/ddm/report/v1/declarations/cfg1/devices")
        #expect(server.requests.first?.method == "GET")
    }

    @Test("A filter given replaces it; every page is read")
    func ownFilterAndPages() async throws {
        let server = MockServer { request in
            let page = Int(request.queryValue("page") ?? "0") ?? 0
            let ids = page == 0 ? (1...100).map { "P-\($0)" } : ["P-101"]
            let results = ids.map { #"{"declarationIdentifier":"cfg2","deviceId":"\#($0)","status":"PENDING"}"# }
            return .json(200, #"{"totalCount":101,"results":[\#(results.joined(separator: ","))]}"#)
        }
        let reports = try await platform(server).declarationReports(declarationIdentifier: "cfg2", filter: "active==true")
        #expect(reports?.count == 101)
        #expect(server.requests.map { $0.queryValue("filter") } == ["active==true", "active==true"])
        #expect(server.requests.map { $0.queryValue("size") } == ["100", "100"])
    }

    @Test("Nothing reported it: nil; a refusal names declarations:read")
    func missingAndRefused() async throws {
        let server = MockServer { request in
            request.path.contains("missing") ? .json(404, #"{"httpStatus":404,"errors":[]}"#) : .json(403, #"{"httpStatus":403,"errors":[]}"#)
        }
        let client = try platform(server)
        #expect(try await client.declarationReports(declarationIdentifier: "missing") == nil)
        await #expect {
            try await client.declarationReports(declarationIdentifier: "refused")
        } throws: { hints($0).contains("“declarations:read” permission") }
    }
}

@Suite("1.6.0: raw status items")
struct RawStatusItemsTests {
    static let answer = #"""
    {"statusItems":[
      {"key":"device.operating-system.version","value":"27.1","lastUpdateTime":"2026-11-09T07:00:00"},
      {"key":"passcode.is-present","value":true},
      {"key":"softwareupdate.failure-reason.count","value":3},
      {"key":"device.power.battery-health","value":0.85},
      {"key":"softwareupdate.pending-version","value":{"os-version":"27.2","build-version":"26C5050"}},
      {"key":"management.client-capabilities.supported-payloads.declarations.configurations","value":["com.apple.configuration.softwareupdate.enforcement.specific"]},
      {"key":"softwareupdate.beta-enrollment","value":null},
      {"key":"device.model.identifier"},
      {"value":"no key"}
    ]}
    """#

    @Test("Every value type: text, numbers as written, booleans, objects and lists as compact JSON")
    func everyType() async throws {
        let server = MockServer { _ in .json(200, Self.answer) }
        let items = try #require(try await platform(server).statusItems(managementID: "M-1", kind: .computer))
        #expect(items.count == 8, "an item without a key is skipped")
        func item(_ key: String) -> JamfPro.StatusItem? { items.first { $0.key == key } }
        #expect(item("device.operating-system.version")?.value == "27.1")
        #expect(item("device.operating-system.version")?.valueKind == .string)
        #expect(item("device.operating-system.version")?.lastUpdateTime == "2026-11-09T07:00:00")
        #expect(item("passcode.is-present")?.value == "true")
        #expect(item("passcode.is-present")?.valueKind == .boolean)
        #expect(item("softwareupdate.failure-reason.count")?.value == "3")
        #expect(item("device.power.battery-health")?.value == "0.85")
        #expect(item("device.power.battery-health")?.valueKind == .number)
        let pending = try #require(item("softwareupdate.pending-version"))
        #expect(pending.valueKind == .object)
        #expect(pending.value?.contains(#""os-version":"27.2""#) == true)
        let list = try #require(item("management.client-capabilities.supported-payloads.declarations.configurations"))
        #expect(list.valueKind == .array)
        #expect(list.value?.hasPrefix("[") == true)
        #expect(item("softwareupdate.beta-enrollment")?.value == nil)
        #expect(item("softwareupdate.beta-enrollment")?.valueKind == .null)
        #expect(item("device.model.identifier")?.valueKind == .null)
        #expect(server.requests.first?.path == "/pro/v1/ddm/M-1/status-items")
        #expect(server.requests.first?.method == "GET")
    }

    @Test("No report: nil; a refusal is thrown and names devices:read")
    func missingAndRefused() async throws {
        let server = MockServer { request in
            request.path.contains("/M-2/") ? .json(404, #"{"httpStatus":404,"errors":[]}"#) : .json(403, #"{"httpStatus":403,"errors":[]}"#)
        }
        let client = try platform(server)
        #expect(try await client.statusItems(managementID: "M-2", kind: .mobileDevice) == nil)
        await #expect {
            try await client.statusItems(managementID: "M-3", kind: .mobileDevice)
        } throws: { hints($0).contains("“devices:read” permission") }
    }

    @Test("The software update status reads the same items as before")
    func softwareUpdateStatusUnchanged() async throws {
        let server = MockServer { _ in .json(200, Self.answer) }
        let status = try #require(try await platform(server).softwareUpdateStatus(managementID: "M-1", kind: .computer))
        #expect(status.osVersion == "27.1")
        #expect(status.passcodePresent == true)
        #expect(status.pendingVersion?.osVersion == "27.2")
        #expect(status.itemCount == 8)
    }

    @Test("An item made by hand has no value kind; existing code compiles unchanged")
    func handMade() {
        let item = JamfPro.StatusItem(key: "k", value: "v", lastUpdateTime: nil)
        #expect(item.valueKind == nil)
    }
}

@Suite("1.6.0: Rapid Security Response and battery health")
struct SupplementalAndBatteryTests {
    @Test("A Mac’s supplemental build, its extra version and battery health")
    func read() {
        let status = JamfPro.SoftwareUpdateStatus(items: [
            .init(key: "device.operating-system.version", value: "27.1"),
            .init(key: "device.operating-system.supplemental.build-version", value: "26B5060a"),
            .init(key: "device.operating-system.supplemental.extra-version", value: "(a)"),
            .init(key: "device.power.battery-health", value: "service-recommended"),
        ])
        #expect(status.supplementalBuild == "26B5060a")
        #expect(status.supplementalExtraVersion == "(a)")
        #expect(status.batteryHealth == "service-recommended")
        #expect(status.itemCount == 4)
    }

    @Test("Absent or empty: nil")
    func absent() {
        let status = JamfPro.SoftwareUpdateStatus(items: [
            .init(key: "device.operating-system.supplemental.extra-version", value: ""),
            .init(key: "device.power.battery-health", value: "null"),
        ])
        #expect(status.supplementalBuild == nil)
        #expect(status.supplementalExtraVersion == nil)
        #expect(status.batteryHealth == nil)
        #expect(JamfPro.SoftwareUpdateStatus().batteryHealth == nil)
    }
}

@Suite("1.6.0: a Mac’s FileVault")
struct FileVaultTests {
    @Test("Members of a computer group carry DISK_ENCRYPTION; the section is asked for")
    func fileVault() async throws {
        let server = MockServer { request in
            if request.path == "/pro/v3/computer-groups/smart-group-membership/3" { return .json(200, #"{"members":[1,2]}"#) }
            return .json(200, #"""
            {"totalCount":2,"results":[
              {"id":"1","general":{"name":"Mac 1","managementId":"MC-1"},"diskEncryption":{"individualRecoveryKeyValidityStatus":"VALID","bootPartitionEncryptionDetails":{"partitionFileVault2State":"ENCRYPTED","partitionFileVault2Percent":100}}},
              {"id":"2","general":{"name":"Mac 2","managementId":"MC-2"}}
            ]}
            """#)
        }
        let members = try await platform(server).members(of: .init(groupID: "3", name: "Studio Macs", isSmart: true, kind: .computer))
        let encrypted = try #require(members.first { $0.id == "1" })
        #expect(encrypted.diskEncryption?.bootPartitionFileVault2State == "ENCRYPTED")
        #expect(encrypted.diskEncryption?.bootPartitionFileVault2Percent == 100)
        #expect(encrypted.diskEncryption?.individualRecoveryKeyValidityStatus == "VALID")
        #expect(members.first { $0.id == "2" }?.diskEncryption == nil)
        let inventory = try #require(server.requests.first { $0.path == "/pro/v4/computers-inventory" })
        #expect(Set(queryValues(inventory, "section")) == ["GENERAL", "HARDWARE", "OPERATING_SYSTEM", "SECURITY", "DISK_ENCRYPTION"])
    }

    @Test("A disk encryption made by hand")
    func handMade() {
        let disk = JamfPro.Computer.DiskEncryption(bootPartitionFileVault2State: "UNENCRYPTED")
        #expect(disk.bootPartitionFileVault2State == "UNENCRYPTED")
        #expect(disk.fileVault2Enabled == nil)
        var member = JamfPro.GroupMember(id: "1", kind: .computer)
        #expect(member.diskEncryption == nil)
        member.diskEncryption = disk
        #expect(member.diskEncryption?.bootPartitionFileVault2State == "UNENCRYPTED")
    }
}

@Suite("1.6.0: a Save panel in the test’s own folder")
struct SavePanelCheckTests {
    @Test("The folder is recognized by value, label or title, and only by its whole name") @MainActor
    func showsFolder() {
        let predicate = JTKitUITestCase.showsFolder(named: "JTKitUITest-1")
        #expect(predicate.evaluate(with: ["value": "JTKitUITest-1", "label": "", "title": ""]))
        #expect(predicate.evaluate(with: ["value": "", "label": "JTKitUITest-1", "title": ""]))
        #expect(predicate.evaluate(with: ["value": "", "label": "", "title": "JTKitUITest-1"]))
        #expect(!predicate.evaluate(with: ["value": "Documents", "label": "Downloads", "title": "JTKitUITest-12"]))
    }

    @Test("Its error names the folder")
    func error() {
        #expect(SavePanelNotInTestFolder(folder: "JTKitUITest-1").description == "The Save panel didn’t show JTKitUITest-1")
    }
}

@Suite("1.6.0: the declarations a device holds")
struct ManagementDeclarationsTests {
    @Test("From Jamf Pro’s {key=value} text: configurations and activations, each once, in order")
    func javaText() {
        let text = "{activations=[{identifier=Blueprint_b_s1_c1_sys_act1, active=true, valid=valid, server-token=ab12}, "
            + "{identifier=Blueprint_b_s1_c1_sys_act2, active=false, valid=valid, server-token=cd34}], "
            + "configurations=[{identifier=Blueprint_b_s1_c1_sys_cfg1, active=true, valid=valid, server-token=ef56}, "
            + "{identifier=Blueprint_b_s1_c1_sys_act1, active=true}], assets=[], management=[]}"
        let status = JamfPro.SoftwareUpdateStatus(items: [.init(key: "management.declarations", value: text)])
        #expect(status.declarationIdentifiers == ["Blueprint_b_s1_c1_sys_act1", "Blueprint_b_s1_c1_sys_act2", "Blueprint_b_s1_c1_sys_cfg1"])
    }

    @Test("From JSON, as an object value is read")
    func json() {
        let text = #"{"activations":[{"identifier":"act9","active":true,"server-token":"x"}],"configurations":[{"identifier":"cfg9","valid":"valid"}]}"#
        let status = JamfPro.SoftwareUpdateStatus(items: [.init(key: "management.declarations", value: text)])
        #expect(status.declarationIdentifiers == ["act9", "cfg9"])
    }

    @Test("From flattened keys, and other items’ identifiers are left out")
    func flattened() {
        let status = JamfPro.SoftwareUpdateStatus(items: [
            .init(key: "management.declarations.configurations.0.identifier", value: "cfg1"),
            .init(key: "management.declarations.activations", value: "[{identifier=act1, active=true}]"),
            .init(key: "device.identifier.udid", value: "{identifier=not-a-declaration}"),
            .init(key: "management.declarations.assets", value: ""),
        ])
        #expect(status.declarationIdentifiers == ["cfg1", "act1"])
        #expect(JamfPro.SoftwareUpdateStatus().declarationIdentifiers.isEmpty)
    }
}

@Suite("1.6.0: the Platform device list, read once")
struct PlatformDeviceListTests {
    @Test("Every page (page, page-size) until hasNext is false; ID and serial number")
    func pages() async throws {
        let server = MockServer { request in
            let page = Int(request.queryValue("page") ?? "0") ?? 0
            let ids = page == 0 ? ["d-1", "d-2"] : ["d-3"]
            let results = ids.map { #"{"id":"\#($0)","serialNumber":"ZZTEST\#($0.dropFirst(2))","name":"Device"}"# }
            return .json(200, #"{"page":\#(page),"pageSize":2,"hasNext":\#(page == 0),"results":[\#(results.joined(separator: ","))]}"#)
        }
        let devices = try await platform(server).devices(pageSize: 2)
        #expect(devices.map(\.id) == ["d-1", "d-2", "d-3"])
        #expect(devices.map(\.serialNumber) == ["ZZTEST1", "ZZTEST2", "ZZTEST3"])
        #expect(server.requests.map(\.path) == ["/devices/v1/devices", "/devices/v1/devices"])
        #expect(server.requests.map { $0.queryValue("page") } == ["0", "1"])
        #expect(server.requests.allSatisfy { $0.queryValue("page-size") == "2" && $0.method == "GET" && $0.queryValue("filter") == nil })
    }

    @Test("A refusal is thrown and names devices:read; a failed page is never an empty list")
    func failures() async throws {
        let refused = MockServer { _ in .json(403, #"{"httpStatus":403,"errors":[]}"#) }
        await #expect {
            try await platform(refused).devices()
        } throws: { hints($0).contains("“devices:read” permission") }
        let broken = MockServer { request in
            request.queryValue("page") == "0"
                ? .json(200, #"{"hasNext":true,"results":[{"id":"d-1","serialNumber":"ZZTEST1"}]}"#)
                : .json(400, #"{"httpStatus":400,"errors":[]}"#)
        }
        await #expect(throws: JamfPlatform.APIError.self) { try await platform(broken).devices() }
    }

    @Test("A busy answer (503) to a declaration’s device list is retried")
    func busyDeclarationList() async throws {
        let calls = CallCounter()
        let server = MockServer { _ in
            calls.increment() == 1
                ? .json(503, #"{"httpStatus":503,"errors":[]}"#)
                : .json(200, #"{"totalCount":1,"results":[{"declarationIdentifier":"cfg1","deviceId":"P-1","status":"SUCCESSFUL"}]}"#)
        }
        let reports = try await platform(server).declarationReports(declarationIdentifier: "cfg1")
        #expect(reports?.map(\.deviceID) == ["P-1"])
        #expect(server.requests.count == 2)
    }
}

/// A thread-safe call counter for a mock server’s handler.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}
