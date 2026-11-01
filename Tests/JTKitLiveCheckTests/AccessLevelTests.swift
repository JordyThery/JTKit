import Foundation
import Testing
@testable import JTKitLiveCheck
import JTKitTestSupport

// The 1.1.0 access levels (B2, B2a): disposable and read tenants, commands
// to listed test devices, interruptive commands only after the serial
// prompt, Apple read only, customers never. Made-up tenants and serials only.

private let readEnvironment = "00000000-0000-4000-8000-0000000000b1"
private let listedSerial = "C02TESTDEV1"
private let otherSerials = ["C02TESTDEV2", "C02TESTDEV3", "C02TESTDEV4"]

private func levelList(productionReads: Bool? = nil, devices: [String] = [listedSerial] + otherSerials) -> AllowList {
    AllowList(version: 2, tenants: [
        .init(role: "jamf-test-a", service: .jamfPlatform, region: "eu", environmentID: platformA, access: .full),
        .init(role: "jamf-test-a", service: .jamfPro, host: "test-a.jamf.example", access: .full),
        .init(role: "lab-read", service: .jamfPlatform, region: "us", environmentID: readEnvironment, access: .readOnly,
              testDevices: devices.map { AllowList.TestDevice(serial: $0, name: "Lab \($0.suffix(1))") }),
        .init(role: "lab-pro", service: .jamfPro, host: "lab.jamf.example", access: .readOnly,
              testDevices: [.init(serial: listedSerial)]),
        .init(role: "production", service: .jamfPro, host: "prod.jamf.example", access: .readOnly, production: true),
        .init(role: "apple-business", service: .appleBusinessManager, clientID: "BUSINESSAPI.test", access: .readOnly),
    ], productionReads: productionReads)
}

private func levelPolicy(_ list: AllowList = levelList(), writes: Bool = true, confirmer: InterruptiveConfirmer? = nil,
                         commandsFile: URL? = nil) -> LiveCheckPolicy {
    LiveCheckPolicy(allowList: list, roles: nil, includeProduction: false, prefix: prefix,
                    ledger: Ledger(fileURL: tempFolder().appending(path: "ledger.json")), writesAllowed: writes,
                    commandsFile: commandsFile, confirmer: confirmer)
}

private let labHeaders = ["X-Environment-Id": readEnvironment]
private let gateway = "https://us.api.jamfcloud.com"

/// The read that teaches the policy a test device’s Platform ID.
private func learn(_ policy: LiveCheckPolicy, serial: String, id: String) {
    let body = try! JSONSerialization.data(withJSONObject: ["results": [["id": id, "serialNumber": serial, "name": "Lab iPad"]]])
    let read = request("GET", "\(gateway)/devices/v1/devices", headers: labHeaders)
    guard case .allow(let allowed) = policy.decide(read) else { Issue.record("the read was refused"); return }
    LiveCheckNetwork(policy: policy).didAnswer(allowed, request: read, status: 200, body: body)
}

private func deviceID(_ index: Int) -> String { "00000000-0000-4000-8000-0000000000d\(index)" }

@Suite("Allow-list version 2")
struct AllowListVersionTwoTests {
    @Test func theNewNamesReadAsTheOldLevels() throws {
        let json = #"""
        {"version": 2, "productionReads": true, "tenants": [
          {"role": "jamf-test-a", "service": "jamfPlatform", "region": "eu", "environmentID": "\#(platformA)", "access": "disposable", "production": false},
          {"role": "lab-read", "service": "jamfPro", "host": "lab.jamf.example", "access": "read", "production": false,
           "testDevices": [{"serial": "C02TESTDEV1"}]}]}
        """#
        let url = tempFolder().appending(path: "allowlist.json")
        try Data(json.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let list = try AllowList.load(from: url)
        #expect(list.tenants.map(\.access) == [.full, .readOnly])
        #expect(list.productionReads == true)
        #expect(list.tenants[1].testDeviceSerials == ["C02TESTDEV1"])
    }

    @Test func todaysVersionOneListStillReads() throws {
        let url = tempFolder().appending(path: "allowlist.json")
        try JSONEncoder().encode(sampleList()).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let list = try AllowList.load(from: url)
        #expect(list.version == 1)
        #expect(list.productionReads == nil)
        #expect(list.tenants.allSatisfy { $0.testDevices == nil && $0.customer == nil })
    }

    @Test func anEntryMarkedCustomerIsRefused() throws {
        let entry = AllowList.Entry(role: "customer-x", service: .jamfPro, host: "x.jamf.example", access: .readOnly, customer: true)
        #expect(throws: AllowList.LoadError.incomplete(
            role: "customer-x", reason: "it is marked customer, and a customer’s tenant is never on the allow-list")) {
            try entry.validate()
        }
        // and the whole list with it
        let url = tempFolder().appending(path: "allowlist.json")
        try JSONEncoder().encode(AllowList(version: 2, tenants: [entry])).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(throws: AllowList.LoadError.self) { try AllowList.load(from: url) }
    }

    @Test func appleTakesNoTestDevices() {
        let entry = AllowList.Entry(role: "apple", service: .appleBusinessManager, clientID: "BUSINESSAPI.x", access: .readOnly,
                                    testDevices: [.init(serial: "C02X")])
        #expect(throws: AllowList.LoadError.self) { try entry.validate() }
    }
}

@Suite("Access levels: read, disposable, Apple, production")
struct TenantLevelTests {
    @Test func aWriteToAReadTenantIsRefused() {
        let policy = levelPolicy()
        let decision = policy.decide(request("POST", "\(gateway)/blueprints/v1/blueprints", headers: labHeaders,
                                             json: ["name": "\(prefix) – B"]))
        #expect(decision == .refuse("lab-read is read only: POST refused"))
        #expect(policy.decide(request("GET", "\(gateway)/blueprints/v1/blueprints", headers: labHeaders)).kind == .read)
    }

    @Test func aDisposableTenantCreatesTestObjects() {
        let decision = levelPolicy().decide(request("POST", "https://eu.api.jamfcloud.com/blueprints/v1/blueprints",
                                                    headers: ["X-Environment-Id": platformA], json: ["name": "\(prefix) – B"]))
        #expect(decision.kind == .create(name: "\(prefix) – B"))
    }

    @Test(arguments: ["POST", "PUT", "PATCH", "DELETE"])
    func anyAppleWriteIsRefused(method: String) {
        let policy = levelPolicy()
        // Apple’s API takes only tokens issued to an allow-listed client
        policy.recordAppleToken("apple-token", clientID: "BUSINESSAPI.test")
        let decision = policy.decide(request(method, "https://api-business.apple.com/v1/orgDevices/C02X",
                                             headers: ["Authorization": "Bearer apple-token"], json: ["a": 1]))
        #expect(!decision.isAllowed)
        #expect(!policy.decide(request("POST", "https://api-business.apple.com/v1/orgDeviceActivities",
                                       headers: ["Authorization": "Bearer apple-token"], json: ["a": 1])).isAllowed)
    }

    @Test func productionIsReadByDefaultWhenTheListSaysSoAndNeverWritten() {
        let reads = levelPolicy(levelList(productionReads: true))
        #expect(reads.decide(request("GET", "https://prod.jamf.example/api/v1/jamf-pro-version")).kind == .read)
        #expect(reads.decide(request("POST", "https://prod.jamf.example/api/oauth/token")).kind == .signIn)
        #expect(reads.decide(request("POST", "https://prod.jamf.example/api/v1/categories", json: ["name": "\(prefix) – C"]))
                == .refuse("production is a production tenant: POST refused, it’s only read"))
        // version 1: only with --include-production, as before
        let before = levelPolicy(levelList(productionReads: nil))
        #expect(before.decide(request("GET", "https://prod.jamf.example/api/v1/jamf-pro-version"))
                == .refuse("production is a production tenant; it’s only read with --include-production"))
    }
}

@Suite("Commands to listed test devices")
struct DeviceCommandLevelTests {
    @Test func checkInAndBlankPushGoToAListedDevice() {
        let policy = levelPolicy()
        learn(policy, serial: listedSerial, id: deviceID(1))
        let checkIn = policy.decide(request("POST", "\(gateway)/device-actions/v1/devices/\(deviceID(1))/check-in", headers: labHeaders))
        #expect(checkIn.kind == .command(name: "Check-in", level: .commands, serials: [listedSerial]))
    }

    @Test func aCommandToADeviceNotOnTheListIsRefused() {
        let policy = levelPolicy()
        learn(policy, serial: listedSerial, id: deviceID(1))
        // a device the tenant has, but that isn’t listed: its ID was never learned
        let decision = policy.decide(request("POST", "\(gateway)/device-actions/v1/devices/\(deviceID(9))/check-in", headers: labHeaders))
        #expect(decision == .refuse("Check-in to a device that isn’t one of lab-read’s test devices is refused"))
    }

    @Test func serialsThatArentListedAreNeverLearned() {
        let policy = levelPolicy()
        learn(policy, serial: "C02NOTLISTED", id: deviceID(8))
        #expect(policy.devices.device(target: "platform:\(readEnvironment)", reference: deviceID(8)) == nil)
    }

    @Test func aFourthDeviceIsRefused() {
        let file = tempFolder().appending(path: "device-commands.jsonl")
        let policy = levelPolicy(commandsFile: file)
        for (index, serial) in ([listedSerial] + otherSerials).enumerated() { learn(policy, serial: serial, id: deviceID(index + 1)) }
        for index in 1...3 {
            guard case .allow(let allowed) = policy.decide(
                request("POST", "\(gateway)/device-actions/v1/devices/\(deviceID(index))/check-in", headers: labHeaders)) else {
                Issue.record("device \(index) was refused")
                return
            }
            policy.recordSent(allowed)
        }
        // the same three again are fine; a fourth isn’t
        #expect(policy.decide(request("POST", "\(gateway)/device-actions/v1/devices/\(deviceID(2))/check-in", headers: labHeaders)).isAllowed)
        #expect(policy.decide(request("POST", "\(gateway)/device-actions/v1/devices/\(deviceID(4))/check-in", headers: labHeaders))
                == .refuse("At most 3 devices get commands in a run: Check-in to another one is refused"))
        // counted from the run’s file, so another test process sees the same
        let other = levelPolicy(commandsFile: file)
        learn(other, serial: otherSerials[2], id: deviceID(4))
        #expect(!other.decide(request("POST", "\(gateway)/device-actions/v1/devices/\(deviceID(4))/check-in", headers: labHeaders)).isAllowed)
    }

    @Test func withoutListedDevicesNoCommandIsSent() {
        let policy = levelPolicy(levelList(devices: []))
        #expect(policy.decide(request("POST", "\(gateway)/device-actions/v1/devices/\(deviceID(1))/check-in", headers: labHeaders))
                == .refuse("Device commands are never sent in a live check"))
    }

    @Test func noCommandWhileWritesAreOff() {
        let policy = levelPolicy(writes: false)
        learn(policy, serial: listedSerial, id: deviceID(1))
        #expect(!policy.decide(request("POST", "\(gateway)/device-actions/v1/devices/\(deviceID(1))/check-in", headers: labHeaders)).isAllowed)
    }

    @Test func jamfProCommandsNameTheirDevicesByManagementID() {
        let policy = levelPolicy()
        let body = try! JSONSerialization.data(withJSONObject: ["results": [
            ["id": "7", "general": ["managementId": "AAAA-BBBB", "name": "Lab Mac"], "hardware": ["serialNumber": listedSerial]],
        ]])
        let read = request("GET", "https://lab.jamf.example/api/v4/computers-inventory")
        guard case .allow(let allowed) = policy.decide(read) else { Issue.record("read refused"); return }
        LiveCheckNetwork(policy: policy).didAnswer(allowed, request: read, status: 200, body: body)

        let push = policy.decide(request("POST", "https://lab.jamf.example/api/v2/mdm/blank-push", json: ["clientManagementIds": ["aaaa-bbbb"]]))
        #expect(push.kind == .command(name: "Blank Push", level: .commands, serials: [listedSerial]))
        let restart = policy.decide(request("POST", "https://lab.jamf.example/api/v2/mdm/commands", json: [
            "clientData": [["managementId": "AAAA-BBBB"]], "commandData": ["commandType": "RESTART_DEVICE"]]))
        #expect(restart.kind == .command(name: "Restart Device", level: .interruptive, serials: [listedSerial]))
        let erase = policy.decide(request("POST", "https://lab.jamf.example/api/v1/computer-inventory/7/erase", json: ["pin": "123456"]))
        #expect(erase.kind == .command(name: "Erase", level: .interruptive, serials: [listedSerial]))
    }

    @Test(arguments: ["restart", "shutdown", "erase", "unmanage"])
    func everyOtherPlatformActionIsInterruptive(action: String) {
        let policy = levelPolicy()
        learn(policy, serial: listedSerial, id: deviceID(1))
        let decision = policy.decide(request("POST", "\(gateway)/device-actions/v1/devices/\(deviceID(1))/\(action)", headers: labHeaders))
        #expect(decision.kind == .command(name: action.capitalized, level: .interruptive, serials: [listedSerial]))
    }
}

@Suite("Interruptive commands and the serial prompt")
struct SerialPromptTests {
    /// Sends one request through the guarded network; the upstream answers 204.
    private func send(_ policy: LiveCheckPolicy, _ url: String, upstream: MockServer,
                      network given: LiveCheckNetwork? = nil) async -> Result<Int, Error> {
        let network = given ?? LiveCheckNetwork(policy: policy, upstream: upstream.session)
        var urlRequest = URLRequest(url: URL(string: url)!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(readEnvironment, forHTTPHeaderField: "X-Environment-Id")
        do {
            let (_, response) = try await network.session.data(for: urlRequest)
            return .success((response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .failure(error)
        }
    }

    @Test func withoutThePromptsConfirmationNothingIsSent() async {
        let upstream = MockServer { _ in MockResponse(status: 204, body: Data()) }
        let policy = levelPolicy(confirmer: nil)
        learn(policy, serial: listedSerial, id: deviceID(1))
        let network = LiveCheckNetwork(policy: policy, upstream: upstream.session)
        let result = await send(policy, "\(gateway)/device-actions/v1/devices/\(deviceID(1))/restart", upstream: upstream,
                                network: network)
        guard case .failure = result else { Issue.record("sent without the prompt"); return }
        #expect(network.refusals.first?.reason.contains("only after the serial prompt’s confirmation") == true)
        #expect(upstream.requests.isEmpty)
    }

    @Test func skipThisTimeAndAWrongSerialSendNothing() async {
        let upstream = MockServer { _ in MockResponse(status: 204, body: Data()) }
        for answer in [nil, "C02WRONG"] as [String?] {
            let policy = levelPolicy(confirmer: { _ in answer })
            learn(policy, serial: listedSerial, id: deviceID(1))
            let result = await send(policy, "\(gateway)/device-actions/v1/devices/\(deviceID(1))/restart", upstream: upstream)
            guard case .failure = result else { Issue.record("sent with \(answer ?? "Skip this time")"); return }
        }
        #expect(upstream.requests.isEmpty)
    }

    @Test func theTypedSerialSendsItAndThePromptNamesCommandDeviceAndTenant() async {
        let upstream = MockServer { _ in MockResponse(status: 204, body: Data()) }
        let asked = Locked<[InterruptivePrompt]>([])
        let policy = levelPolicy(confirmer: { prompt in
            asked.withLock { $0.append(prompt) }
            return " c02testdev1 "
        })
        learn(policy, serial: listedSerial, id: deviceID(1))
        let result = await send(policy, "\(gateway)/device-actions/v1/devices/\(deviceID(1))/restart", upstream: upstream)
        #expect((try? result.get()) == 204)
        #expect(upstream.requests.count == 1)
        let prompt = asked.value.first
        #expect(prompt?.message == "Send Restart to “Lab iPad” on lab-read? Type its serial number to send it, or choose Skip this time.")
        #expect(prompt?.message.contains(listedSerial) == false, "the prompt asks for the serial, it doesn’t show it")
        #expect(policy.sentDeviceCommands().map(\.command) == ["Restart"])
    }

    @Test func aCommandsLevelCommandNeedsNoPrompt() async {
        let upstream = MockServer { _ in MockResponse(status: 204, body: Data()) }
        let policy = levelPolicy(confirmer: { _ in Issue.record("asked for a check-in"); return nil })
        learn(policy, serial: listedSerial, id: deviceID(1))
        let result = await send(policy, "\(gateway)/device-actions/v1/devices/\(deviceID(1))/check-in", upstream: upstream)
        #expect((try? result.get()) == 204)
    }
}

@Suite("Cross-tenant runs (B3)")
struct CrossTenantTests {
    @Test func readProductionWriteTheTestTenantAndRecordWhichTenantEachWriteWentTo() async throws {
        let upstream = MockServer { request in
            request.method == "POST" ? .json(201, #"{"id":"12"}"#) : .json(200, #"{"results":[]}"#)
        }
        let folder = tempFolder()
        let policy = levelPolicy(levelList(productionReads: true))
        let network = LiveCheckNetwork(policy: policy, upstream: upstream.session,
                                       writesFile: folder.appending(path: "writes.jsonl"))
        func send(_ method: String, _ url: String, json: [String: Any]? = nil) async -> Int? {
            var urlRequest = URLRequest(url: URL(string: url)!)
            urlRequest.httpMethod = method
            if let json { urlRequest.httpBody = try? JSONSerialization.data(withJSONObject: json) }
            return ((try? await network.session.data(for: urlRequest))?.1 as? HTTPURLResponse)?.statusCode
        }
        // read the production tenant, write the disposable one
        #expect(await send("GET", "https://prod.jamf.example/api/v1/categories") == 200)
        #expect(await send("POST", "https://test-a.jamf.example/api/v1/categories", json: ["name": "\(prefix) – C"]) == 201)
        // never a write to production
        #expect(await send("POST", "https://prod.jamf.example/api/v1/categories", json: ["name": "\(prefix) – C"]) == nil)

        #expect(policy.ledger.items.map(\.role) == ["jamf-test-a"])
        #expect(policy.ledger.items.first?.target == "test-a.jamf.example")
        let writes = LiveCheckNetwork.writes(in: folder.appending(path: "writes.jsonl"))
        #expect(writes == [SentWrite(role: "jamf-test-a", target: "test-a.jamf.example", method: "POST", kind: "create",
                                     resource: "categories", id: nil, status: 201)])
        #expect(upstream.requests.map { $0.url.host() } == ["prod.jamf.example", "test-a.jamf.example"])
    }

    @Test func aLedgerFromBeforeTheRoleStillOpens() throws {
        let url = tempFolder().appending(path: "ledger.json")
        try Data(#"[{"target":"test-a.jamf.example","resource":"categories","id":"3","name":"\#(prefix) – C"}]"#.utf8).write(to: url)
        let ledger = Ledger(fileURL: url)
        #expect(ledger.saveFailure == nil)
        #expect(ledger.items.first?.role == nil)
    }
}

/// A value shared with a `@Sendable` closure.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.withLock { storage } }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&storage) } }
}
