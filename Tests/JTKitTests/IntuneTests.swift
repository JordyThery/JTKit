import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

// Intune devices and commands.

@MainActor
private func intuneClient(_ server: MockServer, log: ActivityLog = ActivityLog(), sleeps: SleepLog = SleepLog()) -> Graph.Client {
    Graph.Client(tokens: FixedToken("tok"), access: .application,
                 recorder: Graph.recorder(session: server.session, log: log, connection: "Contoso"),
                 sleep: { try await sleeps.sleep($0) }, random: { 0 })
}

private func page(_ items: [String], next: String? = nil) -> MockResponse {
    let link = next.map { #","@odata.nextLink":"\#($0)""# } ?? ""
    return .json(200, #"{"value":[\#(items.joined(separator: ","))]\#(link)}"#)
}

private let forbidden = MockResponse.json(403, #"{"error":{"code":"Forbidden","message":"Application is not authorized to perform this operation.","innerError":{"request-id":"req-1","date":"2026-10-26T10:00:00"}}}"#)

private func target(_ id: String, _ kind: MDMCommand.DeviceKind = .mobileDevice) -> MDMCommand.Target {
    MDMCommand.Target(serial: "SERIAL-\(id)", recordID: id, kind: kind)
}

// MARK: - The device record

@Suite("Intune managed devices")
struct IntuneManagedDeviceTests {

    private func device(_ json: String) throws -> Graph.ManagedDevice {
        try JSONDecoder().decode(Graph.ManagedDevice.self, from: Data(json.utf8))
    }

    @Test("Every field is read; only the ID is required")
    func decoding() throws {
        let mac = try device(#"{"id":"i-1","serialNumber":"C02","deviceName":"Lab Mac","operatingSystem":"macOS","osVersion":"15.1","enrolledDateTime":"2026-01-02T03:04:05Z","lastSyncDateTime":"2026-10-25T08:00:00.1234567Z","managementCertificateExpirationDate":"2027-01-02T03:04:05Z","isEncrypted":true,"isSupervised":false,"managementAgent":"mdm","complianceState":"compliant","deviceEnrollmentType":"appleBulkWithUser"}"#)
        #expect(mac == Graph.ManagedDevice(id: "i-1", serialNumber: "C02", deviceName: "Lab Mac", operatingSystem: "macOS",
                                           osVersion: "15.1", enrolledDateTime: "2026-01-02T03:04:05Z",
                                           lastSyncDateTime: "2026-10-25T08:00:00.1234567Z",
                                           managementCertificateExpirationDate: "2027-01-02T03:04:05Z",
                                           isEncrypted: true, isSupervised: false, managementAgent: "mdm",
                                           complianceState: "compliant", deviceEnrollmentType: "appleBulkWithUser"))
        #expect(try device(#"{"id":"i-2"}"#) == Graph.ManagedDevice(id: "i-2"))
        #expect(throws: (any Error).self) { try device(#"{"serialNumber":"C02"}"#) }
    }

    @Test("A field of an unexpected type is nil, not a failed list")
    func tolerant() throws {
        let odd = try device(#"{"id":"i-1","isEncrypted":"yes","osVersion":15,"serialNumber":null}"#)
        #expect(odd.isEncrypted == nil && odd.osVersion == nil && odd.serialNumber == nil)
    }

    @Test("Kind from the platform: Macs and Windows are computers")
    func kind() {
        for (os, kind) in [("macOS", MDMCommand.DeviceKind.computer), ("Windows", .computer), ("iOS", .mobileDevice),
                           ("iPadOS", .mobileDevice), ("Android", .mobileDevice)] {
            #expect(Graph.ManagedDevice(id: "1", operatingSystem: os).kind == kind)
        }
        #expect(Graph.ManagedDevice(id: "1").kind == .mobileDevice)
        #expect(Graph.ManagedDevice(id: "1", operatingSystem: "iPadOS").isApplePlatform)
        #expect(!Graph.ManagedDevice(id: "1", operatingSystem: "macOS").isApplePlatform)
    }

    @Test("ADE from the enrollment type; managed from the agent")
    func derived() {
        #expect(Graph.ManagedDevice(id: "1", deviceEnrollmentType: "appleBulkWithoutUser").enrolledViaADE == true)
        #expect(Graph.ManagedDevice(id: "1", deviceEnrollmentType: "userEnrollment").enrolledViaADE == false)
        #expect(Graph.ManagedDevice(id: "1").enrolledViaADE == nil)
        #expect(Graph.ManagedDevice(id: "1", managementAgent: "easMdm").isManaged == true)
        #expect(Graph.ManagedDevice(id: "1", managementAgent: "eas").isManaged == false)
        #expect(Graph.ManagedDevice(id: "1", managementAgent: "").isManaged == nil)
        #expect(Graph.ManagedDevice(id: "i-1").consoleURL?.absoluteString
                == "https://intune.microsoft.com/#view/Microsoft_Intune_ManagedDevices/ManagedDeviceMenu.MenuView/~/overview/managedDeviceId/i-1")
    }

    @Test("Compliance in words", arguments: [
        ("compliant", "Compliant"), ("noncompliant", "Not compliant"), ("inGracePeriod", "In grace period"),
        ("configManager", "Managed by Configuration Manager"), ("unknown", "Unknown"), ("conflict", "Conflict"),
        ("", nil),
    ])
    func compliance(state: String, words: String?) {
        #expect(Graph.ManagedDevice(id: "1", complianceState: state).complianceSummary == words)
    }
}

// MARK: - Reading the tenant

@Suite("Intune device list")
@MainActor
struct IntuneDeviceListTests {

    @Test("Asks for the fields by name, 1,000 at a time, and follows the next pages")
    func pages() async throws {
        let server = MockServer { request in
            request.queryValue("$skiptoken") == nil
                ? page([#"{"id":"a","serialNumber":"C02A"}"#], next: "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$skiptoken=2")
                : page([#"{"id":"b","serialNumber":"C02B"}"#])
        }
        let devices = try await intuneClient(server).intuneDevices()
        #expect(devices.map(\.id) == ["a", "b"])
        let first = try #require(server.requests.first)
        #expect(first.path == "/v1.0/deviceManagement/managedDevices")
        #expect(first.queryValue("$select") == Graph.ManagedDevice.fields.joined(separator: ","))
        #expect(first.queryValue("$top") == "1000")
        #expect(server.requests.last?.queryValue("$skiptoken") == "2")
    }

    @Test("By serial: any case, the first record wins, no serial left out")
    func bySerial() async throws {
        let server = MockServer { _ in
            page([#"{"id":"none","serialNumber":""}"#, #"{"id":"null"}"#,
                  #"{"id":"first","serialNumber":"c02a"}"#, #"{"id":"second","serialNumber":"C02A"}"#])
        }
        let devices = try await intuneClient(server).intuneDevicesBySerial()
        #expect(devices.mapValues(\.id) == ["C02A": "first"])
    }

    @Test("The answers are in the activity log, under Intune")
    func recorded() async throws {
        let log = ActivityLog()
        let server = MockServer { _ in page([#"{"id":"a","serialNumber":"C02A","deviceName":"Lab Mac"}"#]) }
        _ = try await intuneClient(server, log: log).intuneDevices()
        let entry = try #require(log.entries.first)
        #expect(entry.category == "Intune" && entry.service == "Intune")
        #expect(entry.request?.responseBody?.contains("Lab Mac") == true)
    }

    @Test("A next page elsewhere is refused before anything is sent there")
    func elsewhere() async throws {
        let server = MockServer { request in
            page([#"{"id":"a"}"#], next: "https://evil.example.com/v1.0/deviceManagement/managedDevices?$skiptoken=2")
        }
        await #expect(throws: Graph.APIError.self) { _ = try await intuneClient(server).intuneDevices() }
        #expect(server.requests.count == 1)
    }

    @Test("A refused read names Read.All")
    func forbiddenRead() async throws {
        let server = MockServer { _ in forbidden }
        do {
            _ = try await intuneClient(server).intuneDevices()
            Issue.record("Expected an error")
        } catch {
            #expect(error.localizedDescription.contains("DeviceManagementManagedDevices.Read.All"))
            #expect(error.localizedDescription.contains("req-1"))
        }
    }

    @Test("Test Connection reads one device ID")
    func testConnection() async throws {
        let server = MockServer { _ in page([]) }
        try await intuneClient(server).testConnection()
        let request = try #require(server.requests.only)
        #expect(request.queryValue("$select") == "id" && request.queryValue("$top") == "1")
        #expect(request.queryValue("$count") == nil)
    }
}

// MARK: - Commands

@Suite("Intune commands")
@MainActor
struct IntuneCommandTests {

    @Test("Which commands Intune has, for which devices")
    func applies() {
        let computer = MDMCommand.allCases.filter { $0.applies(to: .computer, on: .intune) }
        let mobile = MDMCommand.allCases.filter { $0.applies(to: .mobileDevice, on: .intune) }
        #expect(Set(computer) == [.updateInventory, .restartMobile, .shutDownMobile, .wipeComputer, .unmanage, .deleteRecord])
        #expect(Set(mobile) == [.updateInventory, .lockMobile, .clearPasscode, .restartMobile, .shutDownMobile,
                                .wipeMobile, .unmanage, .deleteRecord])
        // Delete Record isn’t a Jamf command
        for product in [MDMCommand.Product.jamfPro, .jamfSchool] {
            #expect(!MDMCommand.deleteRecord.applies(to: .computer, on: product))
            #expect(!MDMCommand.deleteRecord.applies(to: .mobileDevice, on: product))
        }
    }

    @Test("Intune’s own names for Sync and Retire; the others keep theirs")
    func titles() {
        #expect(MDMCommand.updateInventory.title(on: .intune) == "Sync Device")
        #expect(MDMCommand.unmanage.title(on: .intune) == "Retire Device")
        #expect(MDMCommand.updateInventory.title(on: .jamfPro) == "Update Inventory")
        #expect(MDMCommand.unmanage.title(on: .jamfSchool) == "Remove MDM Profile")
        for command in [MDMCommand.restartMobile, .shutDownMobile, .lockMobile, .clearPasscode, .wipeMobile, .wipeComputer, .deleteRecord] {
            #expect(command.title(on: .intune) == command.title)
        }
    }

    @Test("Intune’s own texts, not Jamf Pro’s")
    func texts() {
        for command in MDMCommand.allCases where command.applies(to: .mobileDevice, on: .intune) || command.applies(to: .computer, on: .intune) {
            let text = command.consequence(on: .intune)
            #expect(!text.isEmpty)
            if ![.restartMobile, .shutDownMobile, .lockMobile].contains(command) {
                #expect(text != command.consequence(on: .jamfPro), "\(command)")
            }
        }
        #expect(MDMCommand.updateInventory.consequence(on: .jamfPro) == "The device will be asked to submit a fresh inventory report.")
    }

    @Test("Wipe, Retire and Delete Record can’t be undone; no PIN on Intune")
    func rules() {
        #expect(Set(MDMCommand.allCases.filter { !$0.canBeUndone }) == [.wipeComputer, .wipeMobile, .unmanage, .deleteRecord])
        #expect(MDMCommand.allCases.allSatisfy { !$0.needsPIN(on: .intune) })
    }

    @Test("Irreversible commands name the connection, and from two devices ask for the number",
          arguments: [MDMCommand.wipeMobile, .unmanage, .deleteRecord])
    func irreversible(command: MDMCommand) {
        let one = MDMCommand.Confirmation(command, plan: command.plan(for: [target("1")], on: .intune),
                                          on: .intune, connectionName: "Contoso")
        #expect(one.connectionLine == "On “Contoso”." && one.typedCount == nil && !one.asksPINTwice)
        #expect(one.title == "\(command.title(on: .intune)) — SERIAL-1")
        let two = MDMCommand.Confirmation(command, plan: command.plan(for: [target("1"), target("2")], on: .intune),
                                          on: .intune, connectionName: "Contoso")
        #expect(two.typedCount == 2 && two.isDestructive)
    }

    @Test("The others are plain dialogs", arguments: [MDMCommand.updateInventory, .restartMobile, .shutDownMobile, .lockMobile, .clearPasscode])
    func plain(command: MDMCommand) {
        let two = MDMCommand.Confirmation(command, plan: command.plan(for: [target("1"), target("2")], on: .intune),
                                          on: .intune, connectionName: "Contoso")
        #expect(two.connectionLine == nil && !two.needsTyping)
    }

    @Test("Each command’s Graph request", arguments: [
        (MDMCommand.updateInventory, "POST", "syncDevice"), (.restartMobile, "POST", "rebootNow"),
        (.shutDownMobile, "POST", "shutDown"), (.lockMobile, "POST", "remoteLock"),
        (.clearPasscode, "POST", "resetPasscode"), (.unmanage, "POST", "retire"),
        (.wipeMobile, "POST", "wipe"), (.deleteRecord, "DELETE", ""),
    ])
    func requests(command: MDMCommand, method: String, action: String) async throws {
        let server = MockServer { _ in MockResponse(status: 204, body: Data()) }
        let result = try await intuneClient(server).send(command, to: [target("i-1")])
        #expect(result.isComplete)
        let request = try #require(server.requests.only)
        #expect(request.method == method)
        #expect(request.path == "/v1.0/deviceManagement/managedDevices/i-1" + (action.isEmpty ? "" : "/\(action)"))
        #expect(request.bodyString == (command == .wipeMobile ? "{}" : ""))
    }

    @Test("An Intune device ID stays one path segment: ?, # and / are refused before sending, other characters encoded")
    func deviceIDInPath() async throws {
        let server = MockServer { _ in MockResponse(status: 204, body: Data()) }
        let client = try intuneClient(server)
        for id in ["i-1?x=1", "i-1#x", "../other", "i-1/wipe", ""] {
            do {
                try await client.perform(.restartMobile, intuneDeviceID: id)
                Issue.record("\(id) was sent")
            } catch is MDMCommand.Refusal {
            }
        }
        #expect(server.requests.isEmpty)

        try await client.perform(.restartMobile, intuneDeviceID: "i 1%")
        #expect(server.requests.only?.url.absoluteString.hasSuffix("/managedDevices/i%201%25/rebootNow") == true)
    }

    @Test("The permission table: device actions need PrivilegedOperations.All, Delete Record ReadWrite.All")
    func permissionTable() throws {
        for command in MDMCommand.allCases {
            guard let request = command.intuneRequest(deviceID: "i-1") else { continue }
            let expected: Graph.Permission = command == .deleteRecord ? .managedDevicesReadWrite : .managedDevicesPrivileged
            // the table the error hints read
            #expect(Graph.Permission.required(method: request.method, path: request.path) == expected, "\(command)")
        }
        #expect(Graph.Permission.required(method: "GET", path: "deviceManagement/managedDevices") == .managedDevicesRead)
    }

    @Test("Retire, Wipe and Delete Record take the answered confirmation of exactly that command on Intune")
    func approvals() async throws {
        let server = MockServer { _ in .json(204, "") }
        let client = intuneClient(server)
        let devices = [target("i-1"), target("i-2")]
        func approval(_ command: MDMCommand, _ targets: [MDMCommand.Target], on product: MDMCommand.Product = .intune) throws -> MDMCommand.Confirmation.Approval {
            try MDMCommand.Confirmation(command, plan: command.plan(for: targets, on: product), on: product, connectionName: "Contoso")
                .approve(typedCount: "\(targets.count)")
        }
        await #expect(throws: MDMCommand.Refusal.self) { _ = try await client.send(.wipeMobile, to: devices, approval: nil) }
        await #expect(throws: MDMCommand.Refusal.self) { try await client.perform(.deleteRecord, intuneDeviceID: "i-1", approval: nil) }
        await #expect(throws: MDMCommand.Refusal.self) {
            try await client.perform(.deleteRecord, intuneDeviceID: "i-1", approval: try approval(.unmanage, [devices[0]]))
        }
        await #expect(throws: MDMCommand.Refusal.self) {
            _ = try await client.send(.wipeMobile, to: devices, approval: try approval(.wipeMobile, devices, on: .jamfPro))
        }
        await #expect(throws: MDMCommand.Refusal.self) {
            _ = try await client.send(.wipeMobile, to: devices, approval: try approval(.wipeMobile, [devices[0]]))
        }
        #expect(server.requests.isEmpty)

        #expect(try await client.send(.wipeMobile, to: devices, approval: try approval(.wipeMobile, devices)).sent == devices)
        try await client.perform(.deleteRecord, intuneDeviceID: "i-1", approval: try approval(.deleteRecord, [devices[0]]))
        try await client.perform(.restartMobile, intuneDeviceID: "i-1", approval: nil)
        #expect(server.requests.count == 4)
    }

    @Test("A 403 names the command’s permission", arguments: MDMCommand.allCases.filter { $0.intuneRequest(deviceID: "") != nil })
    func forbiddenCommand(command: MDMCommand) async throws {
        let server = MockServer { _ in forbidden }
        do {
            try await intuneClient(server).perform(command, intuneDeviceID: "i-1")
            Issue.record("Expected an error")
        } catch {
            let message = error.localizedDescription
            let permission: Graph.Permission = command == .deleteRecord ? .managedDevicesReadWrite : .managedDevicesPrivileged
            let expected = permission.name(for: .application)
            #expect(message.contains("“\(expected)”"), "\(command): \(message)")
            let other = command == .deleteRecord ? "PrivilegedOperations" : "ReadWrite"
            #expect(!message.contains(other), "\(command)")
        }
    }

    @Test("Not repeated after a server error or a dropped connection; a 429 is", arguments: [MDMCommand.wipeMobile, .restartMobile])
    func repeats(command: MDMCommand) async throws {
        let serverError = MockServer { _ in .json(503, "{}") }
        let failed = try await intuneClient(serverError).send(command, to: [target("i-1")])
        #expect(serverError.requests.count == 1)
        #expect(failed.sent.isEmpty)

        let dropped = MockServer { _ in throw URLError(.networkConnectionLost) }
        _ = try await intuneClient(dropped).send(command, to: [target("i-1")])
        #expect(dropped.requests.count == 1)

        let calls = Counter()
        let throttled = MockServer { _ in calls.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "0"]) : MockResponse(status: 204, body: Data()) }
        let result = try await intuneClient(throttled).send(command, to: [target("i-1")])
        #expect(throttled.requests.count == 2 && result.isComplete)
    }

    @Test("Delete Record is repeated after a server error; a 404 then means done")
    func deleteRepeated() async throws {
        let calls = Counter()
        let server = MockServer { _ in calls.next() == 1 ? .json(503, "{}") : .json(404, "{}") }
        let result = try await intuneClient(server).send(.deleteRecord, to: [target("i-1")])
        #expect(server.requests.count == 2 && result.isComplete)
    }

    @Test("Devices of the wrong kind are skipped; a failed device doesn’t stop the others")
    func perDevice() async throws {
        let server = MockServer { request in
            request.path.contains("/i-2/") ? .json(404, #"{"error":{"code":"ResourceNotFound","message":"Not found."}}"#) : MockResponse(status: 204, body: Data())
        }
        let result = try await intuneClient(server).send(.lockMobile, to: [target("i-1"), target("i-mac", .computer), target("i-2"), target("i-3")])
        #expect(result.command == "Lock Device")
        #expect(result.sent.map(\.recordID) == ["i-1", "i-3"])
        #expect(result.outcomes[1].outcome == .skipped(.notApplicable(.computer)))
        guard case .failed(let message) = result.outcomes[2].outcome else { Issue.record("not failed"); return }
        #expect(message.contains("HTTP 404"))
        #expect(server.requests.count == 3)
    }

    @Test("A command Intune doesn’t have is refused before anything is sent",
          arguments: [MDMCommand.lockComputer, .blankPush, .renewProfile, .redeployFramework])
    func notIntune(command: MDMCommand) async throws {
        let server = MockServer { _ in MockResponse(status: 204, body: Data()) }
        await #expect(throws: MDMCommand.Refusal.self) { _ = try await intuneClient(server).send(command, to: [target("i-1")]) }
        #expect(server.requests.isEmpty)
    }

    @Test("The result and its Action entry use Intune’s name")
    func entry() async throws {
        let log = ActivityLog()
        let server = MockServer { _ in MockResponse(status: 204, body: Data()) }
        let result = try await intuneClient(server).send(.updateInventory, to: [target("i-1")])
        #expect(result.command == "Sync Device")
        log.recordCommand(result.command, outcomes: result.outcomes, service: "Intune", connection: "Contoso")
        #expect(log.entries.last?.detail == "Sent Sync Device to 1 device")
    }

    @Test("Delete Record isn’t sent to Jamf Pro")
    func notJamfPro() {
        let plan = MDMCommand.deleteRecord.plan(for: [target("7", .computer)], on: .jamfPro)
        #expect(plan.receiving.isEmpty)
        #expect(MDMCommand.deleteRecord.privilege(for: .computer) == .deleteComputers)
        #expect(MDMCommand.deleteRecord.privilege(for: .mobileDevice) == .deleteMobileDevices)
    }
}
