import Foundation
import Testing
@testable import JTKitLiveCheck

// 1.3.0 (decided by Jordy on 2026-11-02): a production entry that opts in
// (`productionTestDevices`) takes Blank Push, Update Inventory and check-in
// to its listed test devices, never an interruptive command; a device listed
// `interruptive: false` never gets one; and no interruptive command ever goes
// to the Mac the release check runs on. Made-up tenants and serials only.

private let prodDevice = "C02PRODDEV1"
private let otherProdDevice = "C02PRODDEV2"
private let labDevice = "C02LABDEV01"
private let quietDevice = "C02LABDEV02"
private let thisMac = "C02THISMAC1"

private func productionList(optIn: Bool? = true, productionReads: Bool? = true) -> AllowList {
    AllowList(version: 3, tenants: [
        .init(role: "production", service: .jamfPro, host: "prod.jamf.example", access: .readOnly, production: true,
              testDevices: [.init(serial: prodDevice, interruptive: false)], productionTestDevices: optIn),
        .init(role: "production-other", service: .jamfPro, host: "prod2.jamf.example", access: .readOnly, production: true),
        .init(role: "lab", service: .jamfPro, host: "lab.jamf.example", access: .readOnly,
              testDevices: [.init(serial: labDevice), .init(serial: quietDevice, interruptive: false), .init(serial: thisMac)]),
    ], productionReads: productionReads)
}

private func devicePolicy(_ list: AllowList = productionList(), includeProduction: Bool = false,
                    thisMacSerial: String? = thisMac) -> LiveCheckPolicy {
    LiveCheckPolicy(allowList: list, roles: nil, includeProduction: includeProduction, prefix: prefix,
                    ledger: Ledger(fileURL: tempFolder().appending(path: "ledger.json")), writesAllowed: true,
                    thisMacSerial: thisMacSerial)
}

/// The inventory read that teaches the policy a computer’s IDs.
private func learn(_ policy: LiveCheckPolicy, host: String, devices: [(id: String, managementID: String, serial: String)]) {
    let body = try! JSONSerialization.data(withJSONObject: ["results": devices.map {
        ["id": $0.id, "general": ["managementId": $0.managementID, "name": "Mac \($0.id)"], "hardware": ["serialNumber": $0.serial]]
    }])
    let read = request("GET", "https://\(host)/api/v3/computers-inventory")
    let decision = policy.decide(read)
    guard case .allow(let allowed) = decision else { Issue.record("the read was refused: \(decision)"); return }
    LiveCheckNetwork(policy: policy).didAnswer(allowed, request: read, status: 200, body: body)
}

private func blankPush(_ host: String, _ managementID: String) -> LiveRequest {
    request("POST", "https://\(host)/api/v2/mdm/blank-push", json: ["clientManagementIds": [managementID]])
}

private func restart(_ host: String, _ managementID: String) -> LiveRequest {
    request("POST", "https://\(host)/api/v2/mdm/commands", json: [
        "clientData": [["managementId": managementID]], "commandData": ["commandType": "RESTART_DEVICE"]])
}

private func writeList(_ json: String) throws -> URL {
    let url = tempFolder().appending(path: "allowlist.json")
    try Data(json.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
}

@Suite("1.3.0: the allow-list’s production test devices")
struct ProductionTestDeviceListTests {
    @Test func anOptedInProductionEntryReadsFromAVersionThreeList() throws {
        let url = try writeList(#"""
        {"version": 3, "productionReads": true, "tenants": [
          {"role": "production", "service": "jamfPro", "host": "prod.jamf.example", "access": "read", "production": true,
           "productionTestDevices": true, "testDevices": [{"serial": "C02PRODDEV1", "interruptive": false}]}]}
        """#)
        let list = try AllowList.load(from: url)
        #expect(list.tenants.first?.productionTestDevices == true)
        #expect(list.tenants.first?.testDevices?.first?.interruptive == false)
    }

    @Test func withoutTheOptInAProductionEntryStillTakesNoTestDevices() throws {
        let url = try writeList(#"""
        {"version": 3, "tenants": [
          {"role": "production", "service": "jamfPro", "host": "prod.jamf.example", "access": "read", "production": true,
           "testDevices": [{"serial": "C02PRODDEV1"}]}]}
        """#)
        #expect(throws: AllowList.LoadError.incomplete(
            role: "production", reason: "a production tenant takes no test devices without productionTestDevices: it is only read")) {
            _ = try AllowList.load(from: url)
        }
    }

    @Test func aProductionTestDeviceMarkedInterruptiveIsRefused() throws {
        let url = try writeList(#"""
        {"version": 3, "tenants": [
          {"role": "production", "service": "jamfPro", "host": "prod.jamf.example", "access": "read", "production": true,
           "productionTestDevices": true, "testDevices": [{"serial": "C02PRODDEV1", "interruptive": true}]}]}
        """#)
        #expect(throws: AllowList.LoadError.incomplete(
            role: "production", reason: "a production tenant’s test devices take non-interruptive commands only")) {
            _ = try AllowList.load(from: url)
        }
    }

    @Test(arguments: [
        #"{"role": "lab", "service": "jamfPro", "host": "lab.jamf.example", "access": "read", "production": false, "testDevices": [{"serial": "C02LABDEV01", "interruptive": false}]}"#,
        #"{"role": "lab", "service": "jamfPro", "host": "lab.jamf.example", "access": "read", "production": false, "productionTestDevices": false}"#,
    ])
    func theNewKeysNeedVersionThree(entry: String) throws {
        // an older JTKit (versions 1 and 2) would read the list without them
        let url = try writeList(#"{"version": 2, "tenants": [\#(entry)]}"#)
        #expect(throws: AllowList.LoadError.incomplete(
            role: "lab", reason: "productionTestDevices and a test device’s interruptive need version 3")) {
            _ = try AllowList.load(from: url)
        }
    }

    @Test func aVersionTwoListReadsAsBefore() throws {
        let url = try writeList(#"""
        {"version": 2, "tenants": [
          {"role": "lab", "service": "jamfPro", "host": "lab.jamf.example", "access": "read", "production": false,
           "testDevices": [{"serial": "C02LABDEV01"}]}]}
        """#)
        let list = try AllowList.load(from: url)
        #expect(list.tenants.first?.productionTestDevices == nil)
        #expect(list.tenants.first?.testDevices?.first?.interruptive == nil)
    }

    @Test func aRoleTheAppKeepsReadOnlyStillLosesItsTestDevices() {
        let list = productionList().readingOnly(["production"])
        #expect(list.tenants.first?.testDevices == nil)
    }
}

@Suite("1.3.0: commands to a production entry’s test devices")
struct ProductionTestDeviceCommandTests {
    @Test func blankPushGoesToAListedDeviceOfAnOptedInProductionEntry() {
        let policy = devicePolicy()
        learn(policy, host: "prod.jamf.example", devices: [("7", "AAAA-0007", prodDevice)])
        #expect(policy.decide(blankPush("prod.jamf.example", "aaaa-0007")).kind
                == .command(name: "Blank Push", level: .commands, serials: [prodDevice]))
        // and with --include-production the same
        let included = devicePolicy(includeProduction: true)
        learn(included, host: "prod.jamf.example", devices: [("7", "AAAA-0007", prodDevice)])
        #expect(included.decide(blankPush("prod.jamf.example", "aaaa-0007")).isAllowed)
    }

    @Test(arguments: [false, true])
    func anInterruptiveCommandNeverGoesToAProductionEntry(includeProduction: Bool) {
        let policy = devicePolicy(includeProduction: includeProduction)
        learn(policy, host: "prod.jamf.example", devices: [("7", "AAAA-0007", prodDevice)])
        #expect(policy.decide(restart("prod.jamf.example", "aaaa-0007")) == .refuse(
            "production is a production tenant: its test devices get Blank Push, Update Inventory and check-in only; Restart Device is refused"))
        #expect(policy.decide(request("POST", "https://prod.jamf.example/api/v4/computers-inventory/7/erase", json: ["pin": "123456"])).isAllowed == false)
    }

    @Test func aDeviceThatIsntListedGetsNothing() {
        let policy = devicePolicy()
        learn(policy, host: "prod.jamf.example", devices: [("7", "AAAA-0007", prodDevice), ("8", "AAAA-0008", otherProdDevice)])
        #expect(policy.decide(blankPush("prod.jamf.example", "aaaa-0008"))
                == .refuse("Blank Push to a device that isn’t one of production’s test devices is refused"))
    }

    @Test func theOptInChangesNothingElse() {
        let policy = devicePolicy()
        // still never a write
        #expect(!policy.decide(request("POST", "https://prod.jamf.example/api/v1/categories", json: ["name": "\(prefix) – C"])).isAllowed)
        #expect(!policy.decide(request("DELETE", "https://prod.jamf.example/api/v1/categories/3")).isAllowed)
        // an entry without it: no command, as before
        learn(policy, host: "prod2.jamf.example", devices: [("7", "AAAA-0007", prodDevice)])
        #expect(policy.decide(blankPush("prod2.jamf.example", "aaaa-0007"))
                == .refuse("production-other is a production tenant: POST refused, it’s only read"))
    }

    @Test func withoutTheOptInAListBuiltInCodeStillGetsNoCommandThrough() {
        let policy = devicePolicy(productionList(optIn: nil), includeProduction: true)
        learn(policy, host: "prod.jamf.example", devices: [("7", "AAAA-0007", prodDevice)])
        #expect(policy.decide(blankPush("prod.jamf.example", "aaaa-0007"))
                == .refuse("production is a production tenant: device commands are never sent"))
    }

    @Test func aProductionTenantThatIsntReadInThisRunGetsNoCommand() {
        let policy = devicePolicy(productionList(productionReads: false))
        #expect(policy.decide(blankPush("prod.jamf.example", "aaaa-0007"))
                == .refuse("production is a production tenant; it’s only read with --include-production"))
    }
}

@Suite("1.3.0: interruptive commands never go to this Mac or a non-interruptive device")
struct InterruptiveTargetTests {
    @Test func noInterruptiveCommandGoesToTheMacTheCheckRunsOn() {
        let policy = devicePolicy()
        learn(policy, host: "lab.jamf.example", devices: [("9", "AAAA-0009", thisMac)])
        #expect(policy.decide(restart("lab.jamf.example", "aaaa-0009"))
                == .refuse("Restart Device is refused: no interruptive command ever goes to the Mac this release check runs on"))
        // a Blank Push to it is fine
        #expect(policy.decide(blankPush("lab.jamf.example", "aaaa-0009")).isAllowed)
        // also when it’s one of several devices in the command
        learn(policy, host: "lab.jamf.example", devices: [("1", "AAAA-0001", labDevice)])
        let both = request("POST", "https://lab.jamf.example/api/v2/mdm/commands", json: [
            "clientData": [["managementId": "AAAA-0001"], ["managementId": "AAAA-0009"]], "commandData": ["commandType": "RESTART_DEVICE"]])
        #expect(!policy.decide(both).isAllowed)
    }

    @Test func thisMacIsComparedWithoutCaseOrSpaces() {
        let policy = devicePolicy(thisMacSerial: " c02thismac1\n")
        learn(policy, host: "lab.jamf.example", devices: [("9", "AAAA-0009", thisMac)])
        #expect(!policy.decide(restart("lab.jamf.example", "aaaa-0009")).isAllowed)
    }

    @Test func anotherListedDeviceCanStillBeAskedFor() {
        let policy = devicePolicy()
        learn(policy, host: "lab.jamf.example", devices: [("1", "AAAA-0001", labDevice)])
        #expect(policy.decide(restart("lab.jamf.example", "aaaa-0001")).kind
                == .command(name: "Restart Device", level: .interruptive, serials: [labDevice]))
    }

    @Test func whenThisMacsSerialCantBeReadNoInterruptiveCommandIsSent() {
        let policy = devicePolicy(thisMacSerial: nil)
        learn(policy, host: "lab.jamf.example", devices: [("1", "AAAA-0001", labDevice)])
        #expect(policy.decide(restart("lab.jamf.example", "aaaa-0001"))
                == .refuse("Restart Device is refused: this Mac’s serial number can’t be read, so no interruptive command is sent"))
        #expect(policy.decide(blankPush("lab.jamf.example", "aaaa-0001")).isAllowed)
    }

    @Test func aDeviceListedNonInterruptiveGetsOnlyTheHarmlessCommands() {
        let policy = devicePolicy()
        learn(policy, host: "lab.jamf.example", devices: [("2", "AAAA-0002", quietDevice)])
        #expect(policy.decide(restart("lab.jamf.example", "aaaa-0002"))
                == .refuse("Restart Device is refused: that test device of lab takes non-interruptive commands only"))
        #expect(policy.decide(blankPush("lab.jamf.example", "aaaa-0002")).isAllowed)
    }

    @Test func noRefusalNamesASerial() {
        let policy = devicePolicy()
        learn(policy, host: "lab.jamf.example", devices: [("2", "AAAA-0002", quietDevice), ("9", "AAAA-0009", thisMac)])
        learn(policy, host: "prod.jamf.example", devices: [("7", "AAAA-0007", prodDevice)])
        for decision in [policy.decide(restart("lab.jamf.example", "aaaa-0002")), policy.decide(restart("lab.jamf.example", "aaaa-0009")),
                         policy.decide(restart("prod.jamf.example", "aaaa-0007"))] {
            guard case .refuse(let reason) = decision else { Issue.record("not refused"); continue }
            #expect(![quietDevice, thisMac, prodDevice].contains { reason.uppercased().contains($0) }, "\(reason)")
        }
    }

    @Test func theReleaseCheckReadsThisMacsSerial() {
        // the public init uses it; never printed
        #expect(ThisMac.serialNumber?.isEmpty == false)
    }
}
