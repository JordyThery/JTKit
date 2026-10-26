import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

// The command list, its confirmation rules, sending to Jamf Pro and Jamf
// School, the Platform API device calls and the Classic basics (step 7,
// from Checkpoint). Every test has its own fake server.

private let environmentID = "e77c1408-10c8-4007-b177-abc9157fbcaa"

private func direct(_ server: MockServer, log: ActivityLog? = nil) throws -> JamfPlatform.Client {
    try JamfPlatform.Client(baseURL: URL(string: "https://jamf.example.com")!, scope: .organization, server: .jamfPro,
                            tokens: FixedToken("tok"),
                            recorder: RequestRecorder(session: server.session, log: log, service: "Jamf Pro"),
                            sleep: { _ in }, random: { 0 })
}

private func gateway(_ server: MockServer, log: ActivityLog? = nil) throws -> JamfPlatform.Client {
    try JamfPlatform.Client(baseURL: URL(string: "https://eu.api.jamfcloud.com")!, scope: .environment(environmentID),
                            tokens: FixedToken("tok"),
                            recorder: RequestRecorder(session: server.session, log: log, service: "Jamf Pro"),
                            sleep: { _ in }, random: { 0 })
}

private func school(_ server: MockServer, log: ActivityLog? = nil, records: Bool = false) throws -> JamfSchool.Client {
    try JamfSchool.Client(address: "school.jamfcloud.com", networkID: "067680", apiKey: "KEY",
                          recorder: RequestRecorder(session: server.session, log: log, service: "Jamf School"),
                          recordsDeviceAnswers: records, sleep: { _ in }, random: { 0 })
}

/// Accepts every command; `override` answers first.
private func commandServer(_ override: @escaping @Sendable (RecordedRequest) -> MockResponse? = { _ in nil }) -> MockServer {
    MockServer { request in
        if let answer = override(request) { return answer }
        let path = request.path
        if path.hasSuffix("/renew-profile") { return .json(200, #"{"udidsNotProcessed":{"udids":[]}}"#) }
        if path.hasSuffix("/blank-push") { return .json(200, #"{"errorUuids":[]}"#) }
        if path.hasSuffix("/detail") { return .json(200, #"{"ios":{"unlockToken":"SECRET-unlock"}}"#) }
        if path.hasSuffix("/devices/v1/devices") {
            let serial = (request.queryValue("filter") ?? "").replacingOccurrences(of: "serialNumber==", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return .json(200, #"{"results":[{"id":"p-\#(serial)","serialNumber":"\#(serial)"}]}"#)
        }
        return .json(200, "{}")
    }
}

private let mac = MDMCommand.Target(serial: "C02XK1JHJG5H", recordID: "7", kind: .computer,
                                    udid: "5D3B6C1A-0000-1111-2222-333344445555", managementID: "M-7")
private let iPad = MDMCommand.Target(serial: "DMPXK1JHJG5H", recordID: "12", kind: .mobileDevice,
                                     udid: "00008103-001A2C3E0C38001E", managementID: "M-12")
private let iPadWithoutID = MDMCommand.Target(serial: "DMPAAAAAAAAA", recordID: "13", kind: .mobileDevice)

private func body(_ request: RecordedRequest?) -> NSDictionary? {
    request.flatMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? NSDictionary }
}

private func dictionary(_ text: String) -> NSDictionary {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? NSDictionary ?? [:]
}

// MARK: - Rules

@Suite("The command list")
struct MDMCommandRuleTests {

    @Test("Wipe and Remove MDM Profile can't be undone; everything else can")
    func undoable() {
        #expect(Set(MDMCommand.allCases.filter { !$0.canBeUndone }) == [.wipeComputer, .wipeMobile, .unmanage])
    }

    @Test("A PIN for Lock and Wipe Computer, on Jamf Pro only")
    func pin() {
        #expect(Set(MDMCommand.allCases.filter { $0.needsPIN(on: .jamfPro) }) == [.lockComputer, .wipeComputer])
        #expect(MDMCommand.allCases.allSatisfy { !$0.needsPIN(on: .jamfSchool) })
    }

    @Test("Only Renew MDM Profile needs a direct connection")
    func platformAPI() {
        #expect(MDMCommand.allCases.filter { !$0.worksOverPlatformAPI } == [.renewProfile])
    }

    @Test("Which kind of device each command reaches")
    func kinds() {
        #expect(MDMCommand.allCases.filter { $0.applies(to: .computer, on: .jamfPro) }
                == [.lockComputer, .wipeComputer, .blankPush, .renewProfile, .redeployFramework, .unmanage])
        #expect(MDMCommand.allCases.filter { $0.applies(to: .mobileDevice, on: .jamfPro) }
                == [.blankPush, .renewProfile, .updateInventory, .lockMobile, .clearPasscode, .restartMobile,
                    .shutDownMobile, .wipeMobile, .unmanage])
        #expect(MDMCommand.updateInventory.applies(to: .computer, on: .jamfSchool))
        #expect(MDMCommand.restartMobile.applies(to: .computer, on: .jamfSchool))
        #expect(!MDMCommand.wipeMobile.applies(to: .computer, on: .jamfSchool))
    }

    @Test("Each command names its privilege")
    func privileges() {
        #expect(MDMCommand.wipeComputer.privilege(for: .computer).rawValue == "Send Computer Remote Wipe Command")
        #expect(MDMCommand.unmanage.privilege(for: .computer).rawValue == "Send Computer Unmanage Command")
        #expect(MDMCommand.unmanage.privilege(for: .mobileDevice).rawValue == "Unmanage Mobile Devices")
        #expect(MDMCommand.renewProfile.privilege(for: .computer).rawValue == "Send Command to Renew MDM Profile")
        #expect(MDMCommand.redeployFramework.privilege(for: .computer).rawValue == "Send Computer Remote Command to Install Package")
        #expect(JamfPro.Privilege.viewMDMCommandInformation.rawValue == "View MDM command information in Jamf Pro API")
    }

    @Test("Remove MDM Profile says what stays, per product")
    func consequences() {
        #expect(MDMCommand.unmanage.consequence(on: .jamfPro).contains("Its inventory record stays until you delete it."))
        #expect(MDMCommand.unmanage.consequence(on: .jamfSchool).contains("Its record stays until you move it to the trash."))
        #expect(MDMCommand.wipeMobile.consequence(on: .jamfPro) == "All data on the device will be erased. This cannot be undone.")
    }
}

// MARK: - Plans and confirmations

@Suite("Plans and confirmations")
struct ConfirmationTests {

    @Test("A plan leaves out devices of the wrong kind and without the identifiers the address needs")
    func plan() {
        let plan = MDMCommand.lockMobile.plan(for: [mac, iPad, iPadWithoutID], on: .jamfPro)
        #expect(plan.receiving == [iPad])
        #expect(plan.skipped.map(\.reason) == [.notApplicable(.computer), .noManagementID])
        #expect(plan.applicable == [iPad, iPadWithoutID])
        #expect(plan.explanation() == "3 selected, 1 will receive the command; 1 has no management ID and 1 is a Mac.")
    }

    @Test("Over the Platform API, Restart needs no management ID")
    func restartByPlatformAPI() {
        #expect(MDMCommand.restartMobile.plan(for: [iPadWithoutID], on: .jamfPro).receiving.isEmpty)
        #expect(MDMCommand.restartMobile.plan(for: [iPadWithoutID], on: .jamfPro, overPlatformAPI: true).receiving == [iPadWithoutID])
    }

    @Test("The explanation counts what the app left out too, and is nil when all receive it")
    func explanation() {
        let devices = (1...3).map { MDMCommand.Target(serial: "S\($0)", recordID: "\($0)", kind: .mobileDevice, managementID: "M\($0)") }
        let plan = MDMCommand.lockMobile.plan(for: devices + [iPadWithoutID, iPadWithoutID], on: .jamfPro)
        #expect(plan.explanation() == "5 selected, 3 will receive the command; 2 have no management ID.")
        #expect(plan.explanation(extra: [.noRecord: 1]) == "6 selected, 3 will receive the command; 1 has no record on this connection and 2 have no management ID.")
        #expect(MDMCommand.lockMobile.plan(for: devices, on: .jamfPro).explanation() == nil)
    }

    @Test("Something that can't be undone names the connection, also for one device, with nothing to type")
    func oneDevice() {
        let plan = MDMCommand.wipeMobile.plan(for: [iPad], on: .jamfPro)
        let confirmation = MDMCommand.Confirmation(.wipeMobile, plan: plan, on: .jamfPro, connectionName: "Lab Jamf")
        #expect(confirmation.title == "Wipe Device — DMPXK1JHJG5H")
        #expect(confirmation.connectionLine == "On “Lab Jamf”.")
        #expect(confirmation.typedCount == nil)
        #expect(!confirmation.asksPINTwice)
        #expect(!confirmation.needsTyping)
        #expect(confirmation.isDestructive)
        #expect(confirmation.problem() == nil)
    }

    @Test("From two devices, the number has to be typed")
    func typedCount() {
        let devices = (1...3).map { MDMCommand.Target(serial: "S\($0)", recordID: "\($0)", kind: .mobileDevice) }
        let confirmation = MDMCommand.Confirmation(.wipeMobile, plan: MDMCommand.wipeMobile.plan(for: devices, on: .jamfPro),
                                                   on: .jamfPro, connectionName: "Lab Jamf")
        #expect(confirmation.title == "Wipe Device — 3 Devices")
        #expect(confirmation.typedCount == 3)
        #expect(confirmation.needsTyping)
        #expect(confirmation.problem(typedCount: "") == "Type 3 to confirm.")
        #expect(confirmation.problem(typedCount: "2") == "Type 3 to confirm.")
        #expect(confirmation.problem(typedCount: " 3 ") == nil)
    }

    @Test("A command that can be undone names no connection and asks for no number")
    func undoable() {
        let devices = (1...3).map { MDMCommand.Target(serial: "S\($0)", recordID: "\($0)", kind: .mobileDevice, managementID: "M") }
        let confirmation = MDMCommand.Confirmation(.restartMobile, plan: MDMCommand.restartMobile.plan(for: devices, on: .jamfPro),
                                                   on: .jamfPro, connectionName: "Lab Jamf")
        #expect(confirmation.connectionLine == nil)
        #expect(confirmation.typedCount == nil)
        #expect(!confirmation.needsTyping)
    }

    @Test("The PIN is typed twice, six digits, the same both times")
    func pinTwice() {
        let confirmation = MDMCommand.Confirmation(.lockComputer, plan: MDMCommand.lockComputer.plan(for: [mac], on: .jamfPro),
                                                   on: .jamfPro, connectionName: "Lab Jamf")
        #expect(confirmation.asksPINTwice && confirmation.needsTyping)
        #expect(confirmation.connectionLine == nil)
        #expect(confirmation.problem(pin: "12345", pinAgain: "12345") == "Enter a 6-digit PIN.")
        #expect(confirmation.problem(pin: "12345a", pinAgain: "12345a") == "Enter a 6-digit PIN.")
        #expect(confirmation.problem(pin: "123456", pinAgain: "123465") == "The two PINs don’t match.")
        #expect(confirmation.problem(pin: "123456", pinAgain: "123456") == nil)
    }

    @Test("Wipe Computer on several Macs: PIN twice and the number")
    func wipeComputers() {
        let macs = [mac, MDMCommand.Target(serial: "C02AAAAAAAAA", recordID: "8", kind: .computer)]
        let confirmation = MDMCommand.Confirmation(.wipeComputer, plan: MDMCommand.wipeComputer.plan(for: macs, on: .jamfPro),
                                                   on: .jamfPro, connectionName: "Lab Jamf")
        #expect(confirmation.connectionLine == "On “Lab Jamf”.")
        #expect(confirmation.problem(typedCount: "2", pin: "123456", pinAgain: "123456") == nil)
        #expect(confirmation.problem(typedCount: "1", pin: "123456", pinAgain: "123456") == "Type 2 to confirm.")
    }

    @Test("Another action can name the connection without being irreversible (Move to Trash)")
    func namesConnection() {
        let confirmation = MDMCommand.Confirmation(action: "Move to Trash", subject: nil, count: 4, message: "…",
                                                   irreversible: false, namesConnection: true,
                                                   connectionName: "School", isDestructive: true)
        #expect(confirmation.connectionLine == "On “School”.")
        #expect(confirmation.typedCount == nil)
        #expect(confirmation.title == "Move to Trash — 4 Devices")
    }
}

// MARK: - Jamf Pro

@Suite("Sending commands to Jamf Pro")
struct JamfProCommandSendingTests {

    @Test("Lock Computer: DEVICE_LOCK with the PIN, direct and through the Platform API",
          arguments: [false, true])
    func lockComputer(overPlatformAPI: Bool) async throws {
        let server = commandServer()
        let client = overPlatformAPI ? try gateway(server) : try direct(server)
        let result = try await client.send(.lockComputer, to: [mac], pin: "123456")
        #expect(result.sent == [mac])
        #expect(result.isComplete)
        let request = try #require(server.requests.only)
        #expect(request.path == (overPlatformAPI ? "/pro/v2/mdm/commands" : "/api/v2/mdm/commands"))
        #expect(body(request) == dictionary(#"{"clientData":[{"managementId":"M-7"}],"commandData":{"commandType":"DEVICE_LOCK","pin":"123456"}}"#))
    }

    @Test("A PIN command without six digits is refused before sending")
    func badPIN() async throws {
        let server = commandServer()
        await #expect(throws: MDMCommand.Refusal.self) { _ = try await direct(server).send(.wipeComputer, to: [mac], pin: "12") }
        #expect(server.requests.isEmpty)
    }

    @Test("Renew MDM Profile over the Platform API is refused before sending")
    func renewOverPlatformAPI() async throws {
        let server = commandServer()
        do {
            _ = try await gateway(server).send(.renewProfile, to: [mac])
            Issue.record("sent")
        } catch let refusal as MDMCommand.Refusal {
            #expect(refusal.message == MDMCommand.unavailableOverPlatformAPI)
        }
        #expect(server.requests.isEmpty)
    }

    @Test("Each per-device command goes to its own address",
          arguments: [(MDMCommand.wipeMobile, "/api/v2/mobile-devices/12/erase", "{}"),
                      (.unmanage, "/api/v2/mobile-devices/12/unmanage", ""),
                      (.updateInventory, "/JSSResource/mobiledevicecommands/command/UpdateInventory/id/12", "")])
    func perDevice(command: MDMCommand, path: String, sentBody: String) async throws {
        let server = commandServer()
        _ = try await direct(server).send(command, to: [iPad])
        let request = try #require(server.requests.only)
        #expect(request.method == "POST")
        #expect(request.path == path)
        #expect(request.bodyString == sentBody)
        #expect(request.header("Accept") == "application/json")
    }

    @Test("Wipe Computer, Remove MDM Profile and Redeploy on a Mac")
    func macCommands() async throws {
        let server = commandServer()
        let client = try gateway(server)
        _ = try await client.send(.wipeComputer, to: [mac], pin: "654321")
        _ = try await client.send(.unmanage, to: [mac])
        _ = try await client.send(.redeployFramework, to: [mac, iPad])
        #expect(server.requests.map(\.path) == ["/pro/v4/computers-inventory/7/erase",
                                                "/pro/v4/computers-inventory/7/remove-mdm-profile",
                                                "/pro/v1/jamf-management-framework/redeploy/7"])
        #expect(body(server.requests.first) == dictionary(#"{"pin":"654321"}"#))
    }

    @Test("Restart over the Platform API: by serial, then the device action; a mismatch sends nothing")
    func restartOverPlatformAPI() async throws {
        let server = commandServer { request in
            request.queryValue("filter")?.contains("DMPAAAAAAAAA") == true
                ? .json(200, #"{"results":[{"id":"other","serialNumber":"OTHER"}]}"#) : nil
        }
        let result = try await gateway(server).send(.restartMobile, to: [iPad, iPadWithoutID])
        #expect(result.sent == [iPad])
        #expect(server.requests.map(\.path) == ["/devices/v1/devices", "/device-actions/v1/devices/p-DMPXK1JHJG5H/restart",
                                                "/devices/v1/devices"])
        #expect(result.problems == "DMPAAAAAAAAA: The platform device inventory returned 1 result(s) for DMPAAAAAAAAA, none with that serial number. No command was sent.")
    }

    @Test("Restart over the Platform API: a 422 is explained")
    func refusedAction() async throws {
        let server = commandServer { $0.path.contains("device-actions") ? .json(422, "{}") : nil }
        let result = try await gateway(server).send(.shutDownMobile, to: [iPad])
        #expect(result.problems?.contains("Jamf Pro will not shut down this device.") == true)
    }

    @Test("Renew MDM Profile: devices Jamf Pro didn't process are named")
    func renew() async throws {
        let server = commandServer { request in
            request.path.hasSuffix("/renew-profile") ? .json(200, #"{"udidsNotProcessed":{"udids":["00008103-001A2C3E0C38001E"]}}"#) : nil
        }
        let result = try await direct(server).send(.renewProfile, to: [mac, iPad])
        #expect(result.sent == [mac])
        #expect(result.outcomes.last?.outcome == .notProcessed)
        #expect(result.problems == "Jamf Pro accepted the request but renewed no profile for: DMPXK1JHJG5H")
        #expect(body(server.requests.only) == dictionary(#"{"udids":["5D3B6C1A-0000-1111-2222-333344445555","00008103-001A2C3E0C38001E"]}"#))
    }

    @Test("Renew MDM Profile without any UDID is refused")
    func renewWithoutUDID() async throws {
        let server = commandServer()
        await #expect(throws: MDMCommand.Refusal("No device UDIDs are known, so the MDM profile cannot be renewed.")) {
            _ = try await direct(server).send(.renewProfile, to: [MDMCommand.Target(serial: "S", recordID: "1", kind: .computer)])
        }
        #expect(server.requests.isEmpty)
    }

    @Test("Blank Push: DDM syncs, DeviceInformation for those that refuse, then the push")
    func blankPush() async throws {
        let server = commandServer { request in
            if request.path.hasSuffix("/M-12/sync") { return .json(400, "{}") }
            if request.path.hasSuffix("/blank-push") { return .json(200, #"{"errorUuids":["m-12"]}"#) }
            return nil
        }
        let result = try await direct(server).send(.blankPush, to: [mac, iPad, iPadWithoutID])
        #expect(server.requests.map(\.path) == ["/api/v1/ddm/M-7/sync", "/api/v1/ddm/M-12/sync", "/api/v2/mdm/commands",
                                                "/api/v2/mdm/blank-push"])
        #expect(body(server.requests.last) == dictionary(#"{"clientManagementIds":["M-7","M-12"]}"#))
        #expect(result.sent == [mac])
        #expect(result.problems == """
            DMPAAAAAAAAA: the record has no management ID. Run a fresh lookup first.
            Jamf Pro could not deliver the blank push to: DMPXK1JHJG5H
            """)
    }

    @Test("Clear Passcode reads the unlock token per device; without one, nothing is sent")
    func clearPasscode() async throws {
        let server = commandServer { request in
            request.path.hasSuffix("/13/detail") ? .json(200, #"{"ios":{}}"#) : nil
        }
        let withoutToken = MDMCommand.Target(serial: "DMPAAAAAAAAA", recordID: "13", kind: .mobileDevice, managementID: "M-13")
        let result = try await direct(server).send(.clearPasscode, to: [iPad, withoutToken])
        #expect(result.sent == [iPad])
        #expect(server.requests.map(\.path) == ["/api/v2/mobile-devices/12/detail", "/api/v2/mdm/commands", "/api/v2/mobile-devices/13/detail"])
        #expect(body(server.requests[1]) == dictionary(#"{"clientData":[{"managementId":"M-12"}],"commandData":{"commandType":"CLEAR_PASSCODE","unlockToken":"SECRET-unlock"}}"#))
        #expect(result.problems == "DMPAAAAAAAAA: Jamf Pro has no escrowed unlock token for this device, so the passcode cannot be cleared.")
    }

    @Test("A command isn't repeated after a server error; a 429 is")
    func retries() async throws {
        let failing = commandServer { $0.path.hasSuffix("/mdm/commands") ? .json(503, "{}") : nil }
        let result = try await direct(failing).send(.lockMobile, to: [iPad])
        #expect(failing.requests.count == 1)
        #expect(result.problems?.hasPrefix("DMPXK1JHJG5H: HTTP 503") == true)

        let calls = Counter()
        let limited = commandServer { request in
            request.path.hasSuffix("/mdm/commands") && calls.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "0"]) : nil
        }
        #expect(try await direct(limited).send(.lockMobile, to: [iPad]).sent == [iPad])
        #expect(limited.requests.count == 2)
    }

    @Test("A refused command names its privilege")
    func privilegeHint() async throws {
        let server = commandServer { $0.path.hasSuffix("/erase") ? .json(403, "{}") : nil }
        let result = try await direct(server).send(.wipeMobile, to: [iPad])
        #expect(result.problems?.contains("The API role is missing the “Send Mobile Device Remote Wipe Command” privilege.") == true)
    }

    @Test("Deleting records: v4 for a Mac, the Classic API for a mobile device")
    func deletes() async throws {
        let server = commandServer()
        let client = try gateway(server)
        try await client.deleteComputer(id: "7")
        try await client.deleteMobileDevice(id: "12")
        #expect(server.requests.map(\.method) == ["DELETE", "DELETE"])
        #expect(server.requests.map(\.path) == ["/pro/v4/computers-inventory/7", "/proclassic/mobiledevices/id/12"])
    }

    @Test("Neither the PIN nor the unlock token reaches the log, also when the answer is an error")
    func nothingSecretRecorded() async throws {
        let server = commandServer { request in
            if request.path.hasSuffix("/mdm/commands") || request.path.hasSuffix("/erase") {
                // an error that echoes what was sent
                return .json(400, request.bodyString)
            }
            return nil
        }
        let log = await ActivityLog()
        let client = try direct(server, log: log)
        _ = try await client.send(.lockComputer, to: [mac], pin: "987654")
        _ = try await client.send(.wipeComputer, to: [mac], pin: "987654")
        _ = try await client.send(.wipeMobile, to: [iPad])
        _ = try await client.send(.clearPasscode, to: [iPad])
        let text = await ActivityLogExport.text(log.entries, masked: false)
        #expect(!text.contains("987654"))
        #expect(!text.contains("SECRET"))
        #expect(await log.entries.filter { $0.request?.contentsWithheld == true }.count >= 3)
    }

    @Test("The command addresses are never recorded with their contents")
    func sensitive() {
        for path in ["/api/v2/mdm/commands", "/pro/v2/mdm/commands", "/api/v2/mobile-devices/12/erase",
                     "/pro/v2/mobile-devices/12/erase", "/api/v4/computers-inventory/7/erase",
                     "/JSSResource/mobiledevicecommands/command/UpdateInventory/id/12",
                     "/proclassic/computercommands/command/DeviceLock/id/7"] {
            #expect(SensitiveRequests.isSensitive(path: path), "\(path)")
        }
        #expect(!SensitiveRequests.isSensitive(path: "/api/v1/mdm/renew-profile"))
    }
}

// MARK: - Results and Action entries

@Suite("Command results in the activity log")
@MainActor
struct CommandEntryTests {

    private let outcomes = [
        MDMCommand.DeviceOutcome(target: iPad, outcome: .sent),
        MDMCommand.DeviceOutcome(target: iPadWithoutID, outcome: .skipped(.noManagementID)),
        MDMCommand.DeviceOutcome(target: mac, outcome: .skipped(.notApplicable(.computer))),
    ]

    @Test("The entry counts the devices it went to and names the others with the reason")
    func partial() throws {
        let log = ActivityLog()
        log.recordCommand("Lock Device", outcomes: outcomes, service: "Jamf Pro", connection: "Lab Jamf")
        let entry = try #require(log.entries.only)
        #expect(entry.category == "Action")
        #expect(entry.detail == "Sent Lock Device to 1 of 3 devices")
        #expect(entry.note == """
            DMPAAAAAAAAA: skipped — the record has no management ID. Run a fresh lookup first.
            C02XK1JHJG5H: skipped — the command doesn’t apply to Macs.
            """)
        #expect(entry.isWarning && !entry.isFailure)
        let masked = ActivityLogExport.text(log.entries, masked: true)
        #expect(!masked.contains("DMPXK1JHJG5H") && !masked.contains("C02XK1JHJG5H") && !masked.contains("DMPAAAAAAAAA"))
    }

    @Test("All sent; a failure; the whole command failing")
    func others() throws {
        let log = ActivityLog()
        log.recordCommand("Restart Device", outcomes: [.init(target: iPad, outcome: .sent)], service: "Jamf Pro", connection: nil)
        log.recordCommand("Wipe Device", outcomes: [.init(target: iPad, outcome: .failed("HTTP 500"))], service: "Jamf Pro", connection: nil)
        log.recordCommand("Blank Push", outcomes: [.init(target: iPad, outcome: .sent)], failure: "No management IDs.",
                          service: "Jamf Pro", connection: nil)
        #expect(log.entries.map(\.detail) == ["Sent Restart Device to 1 device", "Wipe Device reached none of the 1 device",
                                              "Blank Push failed — No management IDs."])
        #expect(log.entries.map(\.isFailure) == [false, true, true])
        #expect(log.entries[1].note == "DMPXK1JHJG5H: failed — HTTP 500")
    }

    @Test("Problems leave out devices of the wrong kind")
    func problems() {
        let result = MDMCommand.Result(command: "Lock Device", outcomes: outcomes)
        #expect(result.problems == "DMPAAAAAAAAA: the record has no management ID. Run a fresh lookup first.")
        #expect(MDMCommand.Result(command: "Lock Device", outcomes: [outcomes[0], outcomes[2]]).isComplete)
    }
}

// MARK: - Platform API devices

@Suite("Platform API devices")
struct PlatformDeviceTests {

    @Test("A device by serial: only an exact match counts; none is nil")
    func bySerial() async throws {
        let server = MockServer { request in
            switch request.queryValue("filter") {
            case #"serialNumber=="C02XK1JHJG5H""#?: .json(200, #"{"results":[{"id":"x","serialNumber":"c02xk1jhjg5h"}]}"#)
            case #"serialNumber=="NONE""#?: .json(200, #"{"results":[]}"#)
            case #"serialNumber=="GONE""#?: .json(404, "{}")
            default: .json(200, #"{"results":[{"id":"y","serialNumber":"OTHER"},{"id":"z","serialNumber":"ELSE"}]}"#)
            }
        }
        let client = try gateway(server)
        #expect(try await client.device(serial: "C02XK1JHJG5H")?.id == "x")
        #expect(try await client.device(serial: "NONE") == nil)
        #expect(try await client.device(serial: "GONE") == nil)
        await #expect(throws: JamfPlatform.DeviceMismatch(serial: "WRONG", count: 2)) { _ = try await client.device(serial: "WRONG") }
        await #expect(throws: JamfPlatformError.self) { _ = try await client.device(serial: "a\"b") }
    }

    @Test("Declarations: the Error detail first, then the description, then the code; the Blueprint ID")
    func declarations() async throws {
        let server = MockServer { _ in
            .json(200, #"""
            {"results":[
             {"declarationIdentifier":"Blueprint_0F2C1B0A-1111-2222-3333-444455556666_s1_c1_sys_cfg1","active":true,"validityState":"INVALID",
              "reasons":[{"code":"Error.X","description":"Summary","details":[{"key":"Error","description":"target OS version (15.7.3) is older"}]},
                         {"code":"Code.Only"}]},
             {"declarationIdentifier":"custom","validityState":"Valid"},
             {"active":true}]}
            """#)
        }
        let declarations = try #require(try await gateway(server).declarations(deviceID: "d-1"))
        #expect(declarations.count == 2)
        #expect(declarations[0].reasons == ["target OS version (15.7.3) is older", "Code.Only"])
        #expect(declarations[0].validity == "invalid")
        #expect(declarations[0].blueprintID == "0F2C1B0A-1111-2222-3333-444455556666")
        #expect(declarations[1].blueprintID == nil && !declarations[1].active)
        let request = try #require(server.requests.only)
        #expect(request.path == "/ddm/report/v1/devices/d-1/declarations")
        #expect(request.queryValue("filter") == "declarationType==CONFIGURATION")
        #expect(request.queryValue("size") == "200")
    }

    @Test("Declarations that can't be read here are nil")
    func declarationsRefused() async throws {
        let server = MockServer { _ in .json(403, "{}") }
        #expect(try await gateway(server).declarations(deviceID: "d-1") == nil)
    }

    @Test("They exist only on the gateway: refused on a direct Jamf Pro server")
    func directIsRefused() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        await #expect(throws: JamfPlatformError.self) { _ = try await direct(server).device(serial: "C02XK1JHJG5H") }
        #expect(server.requests.isEmpty)
    }
}

// MARK: - Classic API

@Suite("Classic API basics")
struct ClassicTests {

    @Test("Paths, and the ID of a new object")
    func paths() {
        #expect(JamfClassic.path("policies", id: "12") == "proclassic/policies/id/12")
        #expect(JamfClassic.createPath("policies") == "proclassic/policies/id/0")
        #expect(JamfClassic.createdID(in: Data("<?xml version=\"1.0\"?><policy><id>345</id></policy>".utf8)) == "345")
        #expect(JamfClassic.createdID(in: Data("{}".utf8)) == nil)
    }

    @Test("The message of an HTML or XML error page")
    func errorPages() {
        let html = """
        <html>
        <head><title>Status page</title></head>
        <body style="font-family: sans-serif;">
        <p style="font-size: 1.2em;font-weight: bold;">Conflict</p>
        <p style="font-size: 1.2em;">Error: Duplicate name</p>
        <p>You can get technical details <a href="http://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html#sec10.4.10">here</a>.<br>
        Please continue your visit at our <a href="/">home page</a>.
        </p>
        </body>
        </html>
        """
        #expect(JamfClassic.errorMessage(in: Data(html.utf8)) == "Conflict – Error: Duplicate name")
        #expect(JamfClassic.errorMessage(in: Data("<error><message>Unable to update &amp; save</message></error>".utf8))
                == "Unable to update & save")
        #expect(JamfClassic.errorMessage(in: Data(#"{"a":1}"#.utf8)) == nil)
    }

    @Test("An error page shows its message, not the markup")
    func errorFormat() async throws {
        let server = MockServer { _ in
            MockResponse(status: 409, headers: ["Content-Type": "text/html"],
                         body: Data("<html><body><p>Conflict</p><p>Error: Duplicate name</p></body></html>".utf8))
        }
        do {
            _ = try await direct(server).send(HTTPRequest(method: "POST", path: JamfClassic.createPath("policies"), body: Data("<policy/>".utf8)))
            Issue.record("sent")
        } catch let error as JamfPlatformError {
            #expect(error.message().hasPrefix("HTTP 409 Conflict\nConflict – Error: Duplicate name"))
            #expect(!error.message().contains("<p>"))
        }
    }

    @Test("A secret in an XML error page stays hidden in its message")
    func errorPageSecret() {
        let answer = HTTPResponse(status: 400, data: Data("<error><password>hunter2</password> token=abc123</error>".utf8))
        let message = JamfPlatformError(HTTPError.status(answer, method: "PUT", path: "/proclassic/ldapservers/id/1", duringSignIn: false)).message()
        #expect(message.hasPrefix("HTTP 400"))
        #expect(!message.contains("hunter2"))
        #expect(!message.contains("abc123"))
    }

    @Test("Lists, groups and members, asked for as JSON")
    func groups() async throws {
        let server = MockServer { request in
            if request.path.hasSuffix("/computergroups") {
                return .json(200, #"{"computer_groups":[{"id":3,"name":"Lab","is_smart":true},{"id":4,"name":"Static"}]}"#)
            }
            return .json(200, #"{"computer_group":{"id":3,"computers":[{"id":7,"name":"Mac","serial_number":"C02XK1JHJG5H"},{"id":8,"name":"New"}]}}"#)
        }
        let client = try gateway(server)
        let groups = try await client.classicGroups(.computer)
        #expect(groups == [JamfClassic.Group(id: "3", name: "Lab", isSmart: true, kind: .computer),
                           JamfClassic.Group(id: "4", name: "Static", isSmart: false, kind: .computer)])
        let members = try await client.classicGroupMembers(groups[0])
        #expect(members.map(\.serialNumber) == ["C02XK1JHJG5H", nil])
        #expect(server.requests.map(\.path) == ["/proclassic/computergroups", "/proclassic/computergroups/id/3"])
        #expect(server.requests.allSatisfy { $0.header("Accept") == "application/json" })
        #expect(JamfClassic.listItems(try LosslessJSON(data: Data(#"{"a":[1,2]}"#.utf8)))?.count == 2)
    }
}

// MARK: - Jamf School

@Suite("Jamf School commands, Move to Trash and moving")
struct JamfSchoolCommandSendingTests {

    @Test("Each command is a form POST with the required fields false; lock isn't in Jamf School")
    func commands() async throws {
        let server = MockServer { _ in .json(200, #"{"code":200,"message":"CommandSent"}"#) }
        let client = try school(server)
        let device = MDMCommand.Target(serial: "DMPXK1JHJG5H", recordID: "u-1", kind: .mobileDevice)
        let macDevice = MDMCommand.Target(serial: "C02XK1JHJG5H", recordID: "u-2", kind: .computer)
        for command in [MDMCommand.updateInventory, .restartMobile, .wipeMobile, .unmanage] {
            #expect(try await client.send(command, to: [device]).sent == [device])
        }
        #expect(try await client.send(.wipeComputer, to: [macDevice]).sent == [macDevice])
        #expect(server.requests.map(\.path) == ["/api/devices/u-1/refresh", "/api/devices/u-1/restart", "/api/devices/u-1/wipe",
                                                "/api/devices/u-1/unenroll", "/api/devices/u-2/wipe"])
        #expect(server.requests.map(\.bodyString) == ["", "clearPasscode=false", "clearActivationLock=false", "", "clearActivationLock=false"])
        #expect(server.requests[1].header("Content-Type") == "application/x-www-form-urlencoded; charset=utf-8")
        await #expect(throws: MDMCommand.Refusal.self) { _ = try await client.send(.lockMobile, to: [device]) }
    }

    @Test("A failure under HTTP 200 is that device's; the others are still sent")
    func failureUnder200() async throws {
        let server = MockServer { request in
            request.path.contains("/u-2/") ? .json(200, #"{"code":400,"message":"DeviceNotActive"}"#) : .json(200, "{}")
        }
        let devices = ["u-1", "u-2", "u-3"].map { MDMCommand.Target(serial: "S\($0)", recordID: $0, kind: .mobileDevice) }
        let result = try await school(server).send(.restartMobile, to: devices)
        #expect(result.sent.map(\.recordID) == ["u-1", "u-3"])
        #expect(result.problems?.hasPrefix("Su-2: Jamf School: the device is trashed or inactive, so it cannot be sent commands.") == true)
    }

    @Test("A command isn't repeated after a server error")
    func notRepeated() async throws {
        let server = MockServer { _ in .json(500, "{}") }
        _ = try await school(server).send(.wipeMobile, to: [MDMCommand.Target(serial: "S", recordID: "u-1", kind: .mobileDevice)])
        #expect(server.requests.count == 1)
    }

    @Test("Move to Trash keeps the trailing slash")
    func trash() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        try await school(server).trash(udid: "u-1")
        #expect(server.requests.only?.method == "DELETE")
        #expect(server.requests.only?.url.absoluteString == "https://school.jamfcloud.com/api/devices/u-1/")
        #expect(RequestPath.isSafe("api/devices/u-1/"))
        #expect(!RequestPath.isSafe("api/devices//"))
    }

    @Test("Moving: JSON PUTs of twenty, and what didn't move")
    func move() async throws {
        let server = MockServer { request in
            let udids = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["udids"] as? [String] ?? []
            return udids.contains("u-21")
                ? .json(200, #"{"devicesMoved":["u-22"],"devicesMoveFailed":["u-21"],"devicesLocationSame":["u-23"]}"#)
                : .json(200, #"{"devicesMoved":[]}"#)
        }
        let outcome = try await school(server).move(udids: (1...25).map { "u-\($0)" }, toLocation: "2")
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.method == "PUT" && $0.path == "/api/devices/migrate" && $0.header("Content-Type") == "application/json" })
        #expect(body(server.requests[0])?["locationId"] as? String == "2")
        #expect((body(server.requests[0])?["udids"] as? [String])?.count == 20)
        #expect(outcome.unmoved == ["u-21"])
        #expect(outcome.alreadyThere == ["u-23"])
    }

    @Test("Device answers are recorded only when asked")
    func recording() async throws {
        let server = MockServer { _ in .json(200, #"{"devices":[{"UDID":"u-1","serialNumber":"S1","name":"Cart iPad","owner":{"name":"Pupil"}}]}"#) }
        let log = await ActivityLog()
        _ = try await school(server, log: log, records: true).fleet()
        _ = try await school(server, log: log).fleet()
        let bodies = await log.entries.map { $0.request?.responseBody }
        #expect(bodies[0]?.contains("Cart iPad") == true)
        #expect(bodies[0]?.contains("Pupil") == false)
        #expect(bodies[1] == nil)
    }
}

extension Array {
    var only: Element? { count == 1 ? first : nil }
}
