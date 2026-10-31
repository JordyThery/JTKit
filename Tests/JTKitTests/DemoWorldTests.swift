import CryptoKit
import Foundation
import SwiftUI
import Testing
@testable import JTKit
import JTKitTestSupport

/// The demo servers of one launch, reached the way an app reaches them: through `DemoMode`.
@MainActor
private func demoMode(scenario: String? = nil) -> DemoMode {
    let defaults = UserDefaults(suiteName: "jtkit-demo-world-\(UUID().uuidString)")!
    var arguments = ["app"]
    if let scenario { arguments += ["-JTKitDemoScenario", scenario] }
    return DemoMode(key: "demoMode", defaults: defaults, arguments: arguments)
}

@MainActor
private func source(_ demo: DemoMode, _ connection: Connection) throws -> DemoSource {
    try #require(demo.source(for: connection))
}

@MainActor
private func jamfPro(_ demo: DemoMode) throws -> JamfPlatform.Client {
    let source = try source(demo, .demoJamfPro)
    return try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                   recorder: RequestRecorder(session: source.session, log: nil), sleep: { _ in })
}

@MainActor
private func jamfSchool(_ demo: DemoMode) throws -> JamfSchool.Client {
    let source = try source(demo, .demoJamfSchool)
    return try JamfSchool.Client(connection: source.connection, apiKey: try source.secret(),
                                 recorder: RequestRecorder(session: source.session, log: nil))
}

@MainActor
private func intune(_ demo: DemoMode) throws -> Graph.Client {
    let source = try source(demo, .demoIntune)
    return try Graph.Client(connection: source.connection, secret: source.secret, session: source.session, log: nil)
}

@MainActor
private func apple(_ demo: DemoMode, _ connection: Connection = .demoAppleBusiness) throws -> ABM.Client {
    let source = try source(demo, connection)
    return try ABM.Client(connection: source.connection, privateKey: source.secret, session: source.session, log: nil)
}

private func target(_ device: DemoWorld.Device, recordID: String? = nil) -> MDMCommand.Target {
    MDMCommand.Target(serial: device.serial, recordID: recordID ?? "\(device.number)",
                      kind: device.isComputer ? .computer : .mobileDevice, udid: device.udid,
                      managementID: device.managementID)
}

private func sent(_ result: MDMCommand.Result) -> Bool {
    !result.outcomes.isEmpty && result.outcomes.allSatisfy { $0.outcome == .sent }
}

@Suite("Demo world: one set of devices, clearly fake")
struct DemoWorldDataTests {
    @Test("Every serial, ID, host, address and person is fake")
    func clearlyFake() {
        let uuid = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        #expect(Set(DemoWorld.devices.map(\.serial)).count == DemoWorld.devices.count)
        for device in DemoWorld.devices {
            #expect(device.serial.hasPrefix("ZZDEMO") && device.serial.allSatisfy { $0.isUppercase || $0.isNumber },
                    "\(device.serial)")
            for id in [device.udid, device.managementID, device.intuneID] {
                #expect(id.wholeMatch(of: uuid) != nil && DemoSamples.isDemoID(id), "\(id)")
            }
            #expect(device.user.hasSuffix(" Sample"), "\(device.user)")
            #expect(device.email.hasSuffix("@contoso.example"), "\(device.email)")
            if let server = device.appleServerID { #expect(DemoSamples.isDemoID(server)) }
        }
        for organization in DemoWorld.Organization.allCases {
            for server in DemoWorld.mdmServers(in: organization) {
                #expect(DemoSamples.isDemoID(server.id) && server.name.hasPrefix("Contoso"))
            }
        }
        #expect(DemoWorld.jamfProHost.hasSuffix(".demo.invalid") && DemoWorld.jamfSchoolHost.hasSuffix(".demo.invalid"))
        #expect(DemoSamples.isDemoID(DemoWorld.intuneTenantID))
        for connection in Connection.demoConnections {
            #expect(connection.isDemo, "\(connection.name)")
            #expect(connection.name.hasPrefix("Contoso") && connection.name.hasSuffix("(Demo)"), "\(connection.name)")
            if !connection.serverURL.isEmpty { #expect(connection.serverURL.hasSuffix(".demo.invalid")) }
        }
        #expect(Set(Connection.demoConnections.map(\.id)).count == Connection.demoConnections.count)
    }

    @Test("About forty devices across Contoso, Contoso Academy and Jamf Pro only")
    func shape() {
        #expect(DemoWorld.devices.count == 42)
        #expect(DemoWorld.devices(in: .contoso).count == 31)
        #expect(DemoWorld.devices(in: .academy).count == 10)
        #expect(Set(DemoWorld.devices.map(\.family)) == Set(DemoWorld.Family.allCases))
        for device in DemoWorld.devices(in: .academy) where device.appleServerID != nil {
            #expect(device.appleServerID == DemoWorld.jamfSchoolServerID && device.managedBy == .jamfSchool)
        }
        // A device’s MDM is the one Apple sends it to, unless it’s one of the gaps below.
        for device in DemoWorld.devices where device.managedBy != nil && device.appleServerID != nil {
            let expected: DemoWorld.MDM = switch device.appleServerID {
            case DemoWorld.jamfProServerID: .jamfPro
            case DemoWorld.intuneServerID: .intune
            default: .jamfSchool
            }
            #expect(device.managedBy == expected, "\(device.serial)")
        }
    }

    @Test("The gaps are there, each exactly as designed")
    func gaps() {
        #expect(DemoWorld.missingFromIntune.count == 3)
        #expect(DemoWorld.missingFromIntune.allSatisfy { $0.family == .iPhone && $0.organization == .contoso })
        #expect(DemoWorld.appleCareExpired.count == 1)
        #expect(DemoWorld.appleCareExpired.first?.family == .mac)
        #expect(DemoWorld.unassigned.count == 1)
        #expect(DemoWorld.unassigned.first.map { $0.family == .iPad && $0.managedBy == nil } == true)
        #expect(DemoWorld.releasePending.count == 1)
        #expect(DemoWorld.releasePending.first?.managedBy == .jamfPro)
        #expect(DemoWorld.stale.count == 1)
        #expect(DemoWorld.stale.first?.lastContactDaysAgo == DemoWorld.staleDays)
        #expect(DemoWorld.notInApple.count == 1)
        #expect(DemoWorld.notInApple.first.map { $0.managedBy == .jamfPro && $0.family == .mac } == true)
        let gaps = [DemoWorld.missingFromIntune, DemoWorld.appleCareExpired, DemoWorld.unassigned,
                    DemoWorld.releasePending, DemoWorld.stale, DemoWorld.notInApple].flatMap { $0 }
        #expect(Set(gaps).count == gaps.count, "each gap is its own device")
        // Everyone else: recent, covered, assigned.
        for device in DemoWorld.devices where !gaps.contains(device) {
            #expect(device.lastContactDaysAgo < 7 && device.appleCareDaysLeft > 0 && device.appleServerID != nil)
        }
    }
}

@Suite("Demo Jamf Pro server")
@MainActor
struct DemoJamfProServerTests {
    @Test("Signs in and finds every Jamf Pro device by serial, as DemoWorld has it")
    func inventory() async throws {
        let demo = demoMode()
        let client = try jamfPro(demo)
        try await client.signIn()
        #expect(try await client.jamfProVersion().version.hasPrefix("11."))
        let macs = DemoWorld.devices(managedBy: .jamfPro).filter(\.isComputer)
        let mobiles = DemoWorld.devices(managedBy: .jamfPro).filter { !$0.isComputer }
        let unknown = DemoWorld.missingFromIntune.map(\.serial)
        let computers = try await client.computers(serials: macs.map(\.serial) + unknown)
        #expect(computers.records.count == macs.count && computers.failures.isEmpty)
        let stale = try #require(computers.records[DemoWorld.stale[0].serial])
        let days = Date().timeIntervalSince(try #require(stale.general?.lastCheckIn)) / 86_400
        #expect(days > 90)
        #expect(computers.records[macs[0].serial]?.general?.managementID == macs[0].managementID)
        let devices = try await client.mobileDevices(serials: mobiles.map(\.serial))
        #expect(devices.records.count == mobiles.count)
        #expect(try await client.computers(serials: [DemoWorld.notInApple[0].serial]).records.count == 1)
    }

    @Test("Device 42 is an iPhone in Jamf Pro, found by serial and by UDID; 1–41 are unchanged")
    func jamfProIPhone() async throws {
        let iPhone = try #require(DemoWorld.devices.last)
        #expect(iPhone.number == 42 && iPhone.serial == "ZZDEMOP42RX" && iPhone.family == .iPhone)
        #expect(iPhone.organization == .contoso && iPhone.appleServerID == DemoWorld.jamfProServerID)
        #expect(iPhone.managedBy == .jamfPro && iPhone.assetTag == "CT-1042")
        #expect(DemoWorld.devices(managedBy: .jamfPro).filter { $0.family == .iPhone } == [iPhone])
        #expect(DemoWorld.devices.prefix(41).map(\.number) == Array(1...41))
        #expect(DemoWorld.devices[40].family == .mac && DemoWorld.devices[40].organization == nil)
        let client = try jamfPro(demoMode())
        let bySerial = try #require(try await client.mobileDevice(serial: iPhone.serial).record)
        #expect(bySerial.udid == iPhone.udid)
        let byUDID = try #require(try await client.mobileDevice(udid: iPhone.udid).record)
        #expect(byUDID.hardware?.serialNumber == iPhone.serial && byUDID.general?.assetTag == iPhone.assetTag)
    }

    @Test("One mobile device by ID (v2/mobile-devices/{id}): its general values, no unlock token, no asset tag (as a real Jamf Pro)")
    func singleMobileDevice() async throws {
        let iPhone = try #require(DemoWorld.devices.last)
        let client = try jamfPro(demoMode())
        let response = try await client.send(HTTPRequest(path: "pro/v2/mobile-devices/\(iPhone.number)"))
        let detail = try JSONDecoder().decode(JamfPro.MobileDeviceDetail.self, from: response.data)
        #expect(detail.general.displayName == iPhone.name && detail.general.udid == iPhone.udid)
        #expect(detail.general.assetTag == nil && detail.general.siteID == "2")
        #expect(detail.general.supervised == true && detail.general.managementID == iPhone.managementID)
        let text = String(decoding: response.data, as: UTF8.self)
        #expect(!text.contains("unlockToken") && !text.contains("assetTag"))

        let mac = try #require(DemoWorld.devices(managedBy: .jamfPro).first { $0.isComputer })
        await #expect(throws: JamfPlatform.APIError.self) {
            _ = try await client.send(HTTPRequest(path: "pro/v2/mobile-devices/\(mac.number)"))
        }
    }

    @Test("A mobile device’s Classic General subset: Classic names with the asset tag; 404 for a computer or unknown ID, 403 without permission")
    func classicGeneralSubset() async throws {
        let iPhone = try #require(DemoWorld.devices.last)
        let client = try jamfPro(demoMode())
        func general(_ id: Int, _ client: JamfPlatform.Client) async throws -> HTTPResponse {
            try await client.send(HTTPRequest(path: "proclassic/mobiledevices/id/\(id)/subset/General", accept: "application/json"))
        }
        let response = try await general(iPhone.number, client)
        #expect(try JSONDecoder().decode(JamfPro.ClassicMobileDeviceGeneral.self, from: response.data).assetTag == iPhone.assetTag)
        let object = try #require(DemoJSON.object(response.data)?["mobile_device"] as? [String: Any])
        let fields = try #require(object["general"] as? [String: Any])
        #expect(fields["name"] as? String == iPhone.name && fields["serial_number"] as? String == iPhone.serial)
        #expect(fields["udid"] as? String == iPhone.udid && object.keys.sorted() == ["general"])

        let mac = try #require(DemoWorld.devices(managedBy: .jamfPro).first { $0.isComputer })
        for id in [mac.number, 999] {
            let error = await #expect(throws: JamfPlatform.APIError.self) { _ = try await general(id, client) }
            #expect(error?.status == 404)
        }
        let refused = try jamfPro(demoMode(scenario: "missingPermission"))
        let error = await #expect(throws: JamfPlatform.APIError.self) { _ = try await general(iPhone.number, refused) }
        #expect(error?.status == 403)
    }

    /// Every Jamf Pro mobile device the demo lists still shows its asset tag
    /// in a lookup, one at a time and many at once.
    @Test("Demo lookups of Jamf Pro mobile devices show their asset tags")
    func demoMobileAssetTags() async throws {
        let mobiles = DemoWorld.devices(managedBy: .jamfPro).filter { !$0.isComputer }
        let client = try jamfPro(demoMode())
        let batch = try await client.mobileDevices(serials: mobiles.map(\.serial))
        for device in mobiles {
            #expect(batch.records[device.serial]?.general?.assetTag == device.assetTag)
            #expect(try await client.mobileDevice(serial: device.serial).record?.general?.assetTag == device.assetTag)
        }
    }

    @Test("ADE instances carry Apple’s server ID, PreStage scope can be changed")
    func enrollment() async throws {
        let demo = demoMode()
        let client = try jamfPro(demo)
        #expect(try await client.deviceEnrollmentServerIDs() == [DemoWorld.jamfProServerID])
        let bySerial = try await client.deviceEnrollmentInstanceBySerial()
        #expect(bySerial.count == DemoWorld.devices.filter { $0.appleServerID == DemoWorld.jamfProServerID }.count)
        #expect(try await client.preStages(.computer).map(\.id) == ["1"])
        let newMac = DemoWorld.notInApple[0].serial
        #expect(try await client.preStageScope(.computer)[newMac] == nil)
        try await client.addToPreStage(.computer, id: "1", serials: [newMac])
        #expect(try await client.preStageScope(.computer)[newMac] == "1")
        try await client.removeFromPreStage(.computer, id: "1", serials: [newMac])
        #expect(try await client.preStageScope(.computer)[newMac] == nil)
        #expect(try await client.sites().count == 2)
        #expect(try await client.departmentNames().count == 4)
        let groups = try await client.classicGroups(.computer)
        let design = try #require(groups.first { $0.name == "Design Macs" })
        #expect(try await client.classicGroupMembers(design).count == 4)
    }

    @Test("Commands are accepted, writes stay, delete removes, secrets are obviously fake")
    func writes() async throws {
        let demo = demoMode()
        let client = try jamfPro(demo)
        let mac = DemoWorld.devices(managedBy: .jamfPro).first { $0.isComputer }!
        let iPad = DemoWorld.devices(managedBy: .jamfPro).first { $0.family == .iPad }!
        #expect(sent(try await client.sendConfirmed(.lockComputer, to: [target(mac)], pin: "123456")))
        #expect(sent(try await client.sendConfirmed(.restartMobile, to: [target(iPad)])))
        #expect(sent(try await client.sendConfirmed(.clearPasscode, to: [target(iPad)])))
        #expect(sent(try await client.sendConfirmed(.renewProfile, to: [target(mac)])))
        #expect(demo.jamfProServer.commands.map(\.command).contains("DEVICE_LOCK"))

        try await client.setAssetTag("CT-NEW", computerID: "\(mac.number)")
        #expect(try await client.computers(serials: [mac.serial]).records[mac.serial]?.general?.assetTag == "CT-NEW")
        #expect(sent(try await client.sendConfirmed(.unmanage, to: [target(iPad)])))
        #expect(demo.jamfProServer.isManaged(serial: iPad.serial) == false)
        try await client.deleteComputer(id: "\(mac.number)")
        #expect(try await client.computers(serials: [mac.serial]).records.isEmpty)

        let other = DemoWorld.devices(managedBy: .jamfPro).filter(\.isComputer)[1]
        #expect(try await client.fileVaultKey(computerID: "\(other.number)")?.personalRecoveryKey == DemoJamfProServer.FakeSecret.fileVaultKey)
        #expect(try await client.recoveryLockPassword(computerID: "\(other.number)") == DemoJamfProServer.FakeSecret.recoveryLock)
        #expect(try await client.deviceLockPIN(computerID: "\(other.number)") == DemoJamfProServer.FakeSecret.deviceLockPIN)
        let accounts = try await client.localAdminAccounts(managementID: other.managementID)
        let account = try #require(accounts.first)
        #expect(try await client.localAdminPassword(managementID: other.managementID, account: account)
                == DemoJamfProServer.FakeSecret.localAdminPassword)
    }
}

@Suite("Demo Jamf School server")
@MainActor
struct DemoJamfSchoolServerTests {
    @Test("Fleet, groups, locations and ADE placeholders of Contoso Academy")
    func reads() async throws {
        let demo = demoMode()
        let client = try jamfSchool(demo)
        let fleet = try await client.fleet()
        #expect(fleet.count == DemoWorld.devices(managedBy: .jamfSchool).count)
        #expect(fleet.values.allSatisfy { $0.ownerName == nil }, "no personal data")
        #expect(try await client.groups().map(\.name) == ["Year 7 iPads", "Lab Macs"])
        #expect(try await client.devices(inGroups: [DemoSamples.schoolGroupIDs[1]]).count == 2)
        #expect(try await client.locations().count == 2)
        #expect(try await client.enrollmentPlaceholders().count == 10)
        let first = DemoWorld.devices(managedBy: .jamfSchool)[0]
        #expect(try await client.device(udid: first.udid)?.serialNumber == first.serial)
        #expect(try await client.device(udid: DemoSamples.uuid(0x5999).uppercased()) == nil)
    }

    @Test("Commands, asset tag, move and trash change the demo")
    func writes() async throws {
        let demo = demoMode()
        let client = try jamfSchool(demo)
        let device = DemoWorld.devices(managedBy: .jamfSchool)[0]
        let target = MDMCommand.Target(serial: device.serial, recordID: device.udid, kind: .mobileDevice, udid: device.udid)
        #expect(sent(try await client.sendConfirmed(.updateInventory, to: [target])))
        #expect(demo.jamfSchoolServer.commands.map(\.action) == ["refresh"])
        try await client.setAssetTag("CA-7", udid: device.udid)
        #expect(demo.jamfSchoolServer.assetTag(serial: device.serial) == "CA-7")
        _ = try await client.move(udids: [device.udid], toLocation: "2")
        #expect(demo.jamfSchoolServer.location(serial: device.serial) == 2)
        try await client.trash(udid: device.udid)
        #expect(try await client.fleet()[device.serial]?.inTrash == true)
    }
}

@Suite("Demo Intune server")
@MainActor
struct DemoIntuneServerTests {
    @Test("Signs in to the demo tenant and lists its devices; three iPhones are missing")
    func reads() async throws {
        let demo = demoMode()
        let client = try intune(demo)
        try await client.testConnection()
        let devices = try await client.intuneDevicesBySerial()
        #expect(devices.count == DemoWorld.devices(managedBy: .intune).count)
        for missing in DemoWorld.missingFromIntune { #expect(devices[missing.serial] == nil) }
    }

    @Test("Pages are followed on Graph’s address")
    func paging() async throws {
        let server = DemoIntuneServer(pageSize: 2)
        let network = DemoNetwork(servers: Dictionary(uniqueKeysWithValues: DemoIntuneServer.hosts.map { ($0, server as any DemoServer) }))
        let client = try Graph.Client(connection: .demoIntune, secret: { "s" }, session: network.session, log: nil)
        #expect(try await client.intuneDevicesBySerial().count == DemoWorld.devices(managedBy: .intune).count)
    }

    @Test("Actions are accepted and Delete Record removes the record")
    func writes() async throws {
        let demo = demoMode()
        let client = try intune(demo)
        let device = DemoWorld.devices(managedBy: .intune)[0]
        let target = MDMCommand.Target(serial: device.serial, recordID: device.intuneID, kind: .mobileDevice)
        #expect(sent(try await client.sendConfirmed(.restartMobile, to: [target])))
        #expect(demo.intuneServer.actions.map(\.action) == ["rebootNow"])
        try await client.performConfirmed(.deleteRecord, intuneDeviceID: device.intuneID)
        #expect(!demo.intuneServer.hasRecord(serial: device.serial))
    }

    @Test("A wrong tenant or secret is refused at sign-in")
    func signInChecked() async throws {
        let server = DemoIntuneServer()
        let network = DemoNetwork(servers: Dictionary(uniqueKeysWithValues: DemoIntuneServer.hosts.map { ($0, server as any DemoServer) }))
        var other = Connection.demoIntune
        other.tenantID = DemoSamples.uuid(0xe799)
        let client = try Graph.Client(connection: other, secret: { "s" }, session: network.session, log: nil)
        await #expect(throws: (any Error).self) { try await client.testConnection() }
    }
}

@Suite("Demo Apple Business and Apple School Manager")
@MainActor
struct DemoAppleBusinessServerTests {
    @Test("Signs in with the launch’s key and reads Contoso as DemoWorld has it")
    func reads() async throws {
        let demo = demoMode()
        let client = try apple(demo)
        #expect(try await client.mdmServers().map(\.name) == ["Contoso Jamf Pro", "Contoso Intune"])
        let expired = DemoWorld.appleCareExpired[0]
        #expect(try await client.appleCareCoverage(serial: expired.serial).first?.status == "INACTIVE")
        #expect(try await client.assignedServerID(serial: DemoWorld.unassigned[0].serial) == nil)
        #expect(try await client.device(serial: DemoWorld.releasePending[0].serial)?.isReleased == true)
        #expect(try await client.device(serial: DemoWorld.notInApple[0].serial) == nil)
        #expect(try await client.assignedServerID(serial: DemoWorld.missingFromIntune[0].serial) == DemoWorld.intuneServerID)

        let snapshot = try await client.organizationSnapshot()
        #expect(snapshot.devices.count == 31)
        #expect(snapshot.serverIDBySerial.count == 29, "one unassigned, one released")
        #expect(snapshot.unknownAssignments.isEmpty && snapshot.unreadableServers.isEmpty)
        let events = try await client.auditEvents(serial: expired.serial, start: Date(timeIntervalSinceNow: -86_400 * 500),
                                                  end: Date())
        #expect(!events.events.isEmpty)
    }

    @Test("Lists are paged on Apple’s own address")
    func paging() async throws {
        let key = P256.Signing.PrivateKey()
        let business = DemoAppleBusinessServer(organization: .contoso, pageSize: 7)
        let network = DemoNetwork(servers: [
            DemoAppleSignInServer.host: DemoAppleSignInServer(keys: [Connection.demoAppleBusiness.clientID: key.publicKey]),
            ABM.Service.business.host: business,
        ])
        let client = try ABM.Client(connection: .demoAppleBusiness, privateKey: { key.pemRepresentation },
                                    session: network.session, log: nil)
        #expect(try await client.organizationSnapshot().devices.count == 31)
    }

    @Test("A write is accepted, watched to completion and changes the devices")
    func activities() async throws {
        let demo = demoMode()
        let client = try apple(demo)
        let iPad = DemoWorld.unassigned[0]
        let assign = try ABM.Activity(.assign, serials: [iPad.serial], serverID: DemoWorld.jamfProServerID)
        let id = try await client.submit(assign)
        #expect(try await client.activityStatus(id: try #require(id)).status == "IN_PROGRESS")
        #expect(try await client.watch(activityID: id) == .completed)
        #expect(try await client.assignedServerID(serial: iPad.serial) == DemoWorld.jamfProServerID)

        let release = try ABM.Activity(.release, serials: [DemoWorld.missingFromIntune[0].serial])
        let outcome = try await client.perform(release)
        #expect(outcome == .completed)
        #expect(demo.appleBusinessServer.isReleased(serial: DemoWorld.missingFromIntune[0].serial))
        #expect(demo.appleBusinessServer.activityTypes == ["ASSIGN_DEVICES", "RELEASE_DEVICES"])
    }

    @Test("Contoso Academy is in Apple School Manager, on its own server")
    func school() async throws {
        let demo = demoMode()
        let client = try apple(demo, .demoAppleSchool)
        #expect(try await client.mdmServers().map(\.name) == ["Contoso Academy Jamf School"])
        #expect(try await client.organizationSnapshot().devices.count == 10)
        #expect(demo.appleSchoolServer.requestCount > 0 && demo.appleBusinessServer.requestCount == 0)
    }

    @Test("Another key is refused at sign-in, as Apple refuses it")
    func wrongKey() async throws {
        let demo = demoMode()
        let source = try source(demo, .demoAppleBusiness)
        let other = P256.Signing.PrivateKey().pemRepresentation
        let client = try ABM.Client(connection: .demoAppleBusiness, privateKey: { other }, session: source.session, log: nil)
        await #expect(throws: ABM.APIError.self) { _ = try await client.mdmServers() }
    }
}

@Suite("Apple’s rate limit: off for the demo organizations only")
@MainActor
struct DemoRateLimitTests {
    @Test("Decided by the connection, not the demo switch")
    func byConnection() throws {
        #expect(ABM.rateLimit(for: .demoAppleBusiness) == nil)
        #expect(ABM.rateLimit(for: .demoAppleSchool) == nil)
        let real = Connection(name: "Real org", service: .appleBusinessManager, clientID: "BUSINESSAPI.x", keyID: "k")
        #expect(ABM.rateLimit(for: real) == ABM.rateLimit)
        let demo = demoMode()
        demo.isOn = true
        defer { demo.isOn = false }
        #expect(ABM.rateLimit(for: real) == ABM.rateLimit, "a real organization keeps it while demo mode is on")
        #expect(try ABM.Client(connection: real, privateKey: { "" }, session: URLSession(configuration: .ephemeral), log: nil).rateLimit == ABM.rateLimit)
        #expect(try apple(demo).rateLimit == nil)
        #expect(ABM.Client(service: .business, tokens: StaticToken(), recorder: RequestRecorder(session: URLSession(configuration: .ephemeral), log: nil)).rateLimit
                == ABM.rateLimit, "the default keeps the limit")
    }

    @Test("Twenty-five reads: the demo organization never waits, a real one does")
    func behaviour() async throws {
        let demo = demoMode()
        let source = try source(demo, .demoAppleBusiness)
        let clock = VirtualClock()
        func client(_ connection: Connection) -> ABM.Client {
            let recorder = ABM.recorder(.business, session: source.session, log: nil)
            // always the demo organization’s sign-in; only the rate limit follows `connection`
            let tokens = ABM.TokenProvider(service: .business, clientID: Connection.demoAppleBusiness.clientID,
                                           keyID: Connection.demoAppleBusiness.keyID,
                                           privateKey: source.secret, recorder: recorder)
            return ABM.Client(service: .business, tokens: tokens, recorder: recorder, rateLimit: ABM.rateLimit(for: connection),
                              sleep: { clock.advance($0) }, now: { clock.now })
        }
        let demoClient = client(.demoAppleBusiness)
        for _ in 0..<25 { _ = try await demoClient.mdmServers() }
        #expect(clock.sleeps == 0)
        // The same organization behind a connection that isn’t a demo one (test only: still the demo network).
        let real = Connection(name: "Real", service: .appleBusinessManager,
                              clientID: "BUSINESSAPI.\(UUID().uuidString)", keyID: UUID().uuidString)
        #expect(!real.isDemo)
        let realClient = client(real)
        for _ in 0..<25 { _ = try await realClient.mdmServers() }
        #expect(clock.sleeps >= 1)
    }
}

/// A clock that only moves when the client waits.
private final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    private var count = 0
    var now: Date { lock.withLock { current } }
    var sleeps: Int { lock.withLock { count } }
    func advance(_ duration: Duration) {
        lock.withLock {
            count += 1
            current += Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
    }
}

private struct StaticToken: BearerTokenSource {
    func token() async throws -> String { "t" }
    func forgetToken() async {}
}

@Suite("The demo guarantee")
@MainActor
struct DemoGuaranteeTests {
    @Test("Every demo connection’s client is answered inside the app; a real connection gets no demo source")
    func everyClient() async throws {
        let demo = demoMode()
        _ = try await jamfPro(demo).computers(serials: [DemoWorld.devices[0].serial])
        _ = try await jamfSchool(demo).fleet()
        _ = try await intune(demo).intuneDevicesBySerial()
        _ = try await apple(demo).mdmServers()
        _ = try await apple(demo, .demoAppleSchool).mdmServers()
        let platform = demo.jamfPlatform()
        _ = try await JamfPlatform.Client(connection: platform.connection, secret: platform.secret,
                                          recorder: RequestRecorder(session: platform.session, log: nil)).deviceGroups()
        #expect(demo.jamfProServer.requestCount > 0)
        #expect(demo.appleBusinessServer.requestCount > 0 && demo.appleSchoolServer.requestCount > 0)
        #expect(demo.jamfPlatformServer.requestCount > 0)
        #expect(demo.intuneServer.actions.isEmpty)
        for connection in Connection.demoConnections {
            #expect(demo.source(for: connection)?.connection == connection)
        }
        var lookalike = Connection.demoJamfPro
        lookalike.id = UUID()
        lookalike.serverURL = "https://contoso.jamfcloud.com"
        #expect(demo.source(for: lookalike) == nil)
        #expect(demo.source(for: Connection(name: "Contoso", service: .intune)) == nil)
    }

    @Test("Apple’s demo key is made for the launch, kept in memory and never saved")
    func throwawayKey() throws {
        let defaults = UserDefaults(suiteName: "jtkit-demo-key-\(UUID().uuidString)")!
        let demo = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
        demo.isOn = true
        defer { demo.isOn = false }
        let pem = try source(demo, .demoAppleBusiness).secret()
        #expect(pem.contains("BEGIN PRIVATE KEY"))
        #expect(try P256.Signing.PrivateKey(pemRepresentation: pem).publicKey.rawRepresentation.count == 64)
        #expect(try source(demo, .demoAppleSchool).secret() == pem, "the same for the launch")
        #expect(try source(demoMode(), .demoAppleBusiness).secret() != pem, "a new one each launch")
        // Not in the demo’s secret store, its settings or a saved-connections store.
        #expect(DemoSecretStore().secret(for: Connection.demoAppleBusiness.id.uuidString) != pem)
        let saved = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        #expect(!saved.contains { $0.contains("PRIVATE KEY") })
        let secrets = InMemorySecretStore()
        let store = ConnectionStore<SampleAppleConnection>(storage: InMemoryConnectionStorage(),
                                                           secrets: [.main: SecretLocation(store: secrets)])
        #expect(!store.setSecret(pem, for: .demoAppleBusiness))
        #expect(throws: ConnectionStoreError.self) {
            try store.save(SampleAppleConnection(connection: .demoAppleBusiness), secrets: [.main: pem])
        }
        #expect(secrets.secret(for: Connection.demoAppleBusiness.id.uuidString) == nil)
    }

    @Test("The missingPermission scenario refuses reads on every service")
    func missingPermission() async throws {
        let demo = demoMode(scenario: "missingPermission")
        #expect(demo.scenario == .missingPermission)
        let computers = try await jamfPro(demo).computers(serials: [DemoWorld.devices[0].serial])
        #expect(computers.records.isEmpty && computers.failures.count == 1)
        await #expect(throws: (any Error).self) { _ = try await jamfSchool(demo).fleet() }
        await #expect(throws: (any Error).self) { _ = try await intune(demo).intuneDevicesBySerial() }
        await #expect(throws: ABM.APIError.self) { _ = try await apple(demo).mdmServers() }
    }
}

@Suite("Demo connections in a role’s picker")
@MainActor
struct DemoConnectionChoiceTests {
    @Test("Starts on the first demo connection; All needs two; the label says Demo")
    func choice() {
        let demo = demoMode()
        let choice = DemoConnectionChoice(mode: demo, connections: [.demoAppleBusiness, .demoAppleSchool])
        #expect(choice.selected == .demoAppleBusiness && choice.inUse == [.demoAppleBusiness])
        #expect(!choice.isActive)
        choice.isAllChosen = true
        #expect(choice.inUse == [.demoAppleBusiness, .demoAppleSchool])
        #expect(choice.label(allTitle: "All Organizations", roleName: "Apple").title == "All Organizations (Demo)")
        choice.menuChoice.wrappedValue = .connection(Connection.demoAppleSchool.id)
        #expect(choice.inUse == [.demoAppleSchool] && !choice.isAllChosen)
        #expect(choice.label(allTitle: nil, roleName: "Apple").title == "Contoso Academy (Demo)")
        #expect(choice.label(allTitle: nil, roleName: "Apple").systemImage == "testtube.2")
        let single = DemoConnectionChoice(mode: demo, connections: [.demoJamfPro])
        single.isAllChosen = true
        #expect(single.inUse == [.demoJamfPro], "All needs two")
    }

    @Test("While demo mode is on no saved connection is checked; choosing one leaves demo mode")
    func leavesDemo() {
        let demo = demoMode()
        let saved = UUID()
        var selection: UUID? = saved
        let binding = Binding(get: { selection }, set: { selection = $0 })
        let all = AllConnectionsChoice(title: "All Organizations")
        let role = ConnectionRole("Apple", selection: binding, all: all,
                                  demo: DemoConnectionChoice(mode: demo, connections: [.demoAppleBusiness]))
        demo.isOn = true
        #expect(role.usesDemo)
        #expect(role.menuChoice(connectionCount: 2).wrappedValue == nil)
        role.menuChoice(connectionCount: 2).wrappedValue = .connection(saved)
        #expect(!demo.isOn && selection == saved)
        #expect(role.menuChoice(connectionCount: 2).wrappedValue == .connection(saved))
        demo.isOn = true
        role.menuChoice(connectionCount: 2).wrappedValue = .all
        #expect(!demo.isOn && all.isChosen)
    }

    @Test("The single connection role offers demo connections too, and a saved one leaves demo mode")
    func activeRole() {
        let demo = demoMode()
        let saved = UUID()
        var selection: UUID? = saved
        let binding = Binding(get: { selection }, set: { selection = $0 })
        let choice = DemoConnectionChoice(mode: demo, connections: [.demoJamfPro, .demoJamfSchool])
        let role = ConnectionRole.active(selection: binding, demo: choice)
        #expect(role.title == ConnectionRole.active(selection: binding).title && !role.usesDemo)
        demo.isOn = true
        #expect(role.usesDemo && choice.selected == .demoJamfPro)
        #expect(choice.label(allTitle: nil, roleName: role.title).title == "Contoso Jamf Pro (Demo)")
        role.menuChoice(connectionCount: 1).wrappedValue = .connection(saved)
        #expect(!demo.isOn && selection == saved)
        #expect(ConnectionRole.active(selection: binding).demo == nil)
    }
}

/// A saved Apple connection, for the store tests.
private struct SampleAppleConnection: ConnectionRecord {
    var connection: Connection
    var id: UUID { connection.id }
}
