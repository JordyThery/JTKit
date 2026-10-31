import Foundation
import SwiftUI
import Testing
@testable import JTKit
import JTKitTestSupport

@Suite("Secret keys found by their parts")
struct SecretKeyMatchingTests {
    @Test("Keys that carry a secret are hidden, whatever their exact name",
          arguments: ["clientSecret", "client_secret", "apiKey", "api-key", "adminPassword", "privateKey",
                      "accessToken", "refresh_token", "client_assertion", "lockPIN", "pin_code", "devicePin",
                      "passcode", "personalRecoveryKey", "unlockToken", "sig", "downloadUrl"])
    func hidden(_ key: String) throws {
        #expect(Redaction.isSecretKey(key))
        let json = try JSONSerialization.data(withJSONObject: ["outer": [key: "s3cr3t-value"]])
        #expect(Redaction.body(json)?.contains("s3cr3t-value") == false)
        #expect(Redaction.formFields("a=1&\(key)=s3cr3t-value") == "a=1&\(key)=<redacted>")
        #expect(!Redaction.text("{\"\(key)\": \"s3cr3t-value\"}").contains("s3cr3t-value"))
        #expect(!Redaction.text("<\(key)>s3cr3t-value</\(key)>").contains("s3cr3t-value"))
        #expect(!Redaction.text("failed: \(key)=s3cr3t-value&x=1").contains("s3cr3t-value"))
    }

    @Test("Keys that name or describe a secret, and words that only contain “key” or “pin”, stay",
          arguments: ["keyID", "key_id", "key", "publicKey", "tokenExpiration", "token_type", "keyboardLayout",
                      "shippingDate", "mapping", "monkey", "name", "serialNumber"])
    func kept(_ key: String) throws {
        #expect(!Redaction.isSecretKey(key))
        let json = try JSONSerialization.data(withJSONObject: [key: "visible-value"])
        #expect(Redaction.body(json)?.contains("visible-value") == true)
        #expect(Redaction.text("\(key)=visible-value").contains("visible-value"))
    }

    @Test("A yes/no under a secret-looking key stays (passcodePresent); its text and number values don’t")
    func aYesOrNoStays() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "security": ["passcodePresent": true, "passcodeCompliant": false, "passcode": "123456", "pin": 123456]])
        let text = try #require(Redaction.body(json))
        let security = try #require((try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])?["security"] as? [String: Any])
        #expect(security["passcodePresent"] as? Bool == true)
        #expect(security["passcodeCompliant"] as? Bool == false)
        #expect(security["passcode"] as? String == Redaction.placeholder)
        #expect(security["pin"] as? String == Redaction.placeholder)
        #expect(Redaction.text("<passcodePresent>true</passcodePresent>") == "<passcodePresent>true</passcodePresent>")
        #expect(Redaction.text("passcode=true&pin=1234") == "passcode=true&pin=<redacted>")
    }

    @Test func aStatusItemKeepsItsKeyAndValue() throws {
        let json = try JSONSerialization.data(withJSONObject: ["key": "device.identifier.serial-number", "value": "C02XK1JHJG5H"])
        let text = try #require(Redaction.body(json))
        #expect(text.contains("device.identifier.serial-number") && text.contains("C02XK1JHJG5H"))
    }
}

@Suite("Device names in the bug-report export")
struct DeviceRecordMaskingTests {
    /// The shape of Jamf Pro’s `v1/computers-inventory?section=GENERAL&section=HARDWARE&section=OPERATING_SYSTEM`.
    static let computersInventory = """
    {"totalCount": 1, "results": [{
      "id": "17", "udid": "6E3B1C0A-2F4D-4B8E-9C1A-5D7E8F9A0B1C",
      "general": {"name": "Jane’s MacBook Pro", "assetTag": "ACME-0042", "platform": "Mac",
                  "site": {"id": "1", "name": "Headquarters"}},
      "hardware": {"serialNumber": "C02XK1JHJG5H", "model": "MacBook Pro (14-inch, 2023)"},
      "operatingSystem": {"name": "macOS", "version": "15.1"},
      "groupMemberships": [{"groupId": "3", "groupName": "All Managed Macs"}]
    }]}
    """

    /// The shape of Jamf Pro’s `v2/mobile-devices/detail`.
    static let mobileInventory = """
    {"totalCount": 1, "results": [{
      "mobileDeviceId": "8", "deviceType": "iOS",
      "general": {"displayName": "Front Desk iPad", "udid": "00008103-001A2C3E0C38001E"},
      "hardware": {"serialNumber": "DMPXK1JHJG5H"}
    }]}
    """

    @Test func aComputerNameInGeneralIsMasked() {
        let found = IdentifierMasker.identifiers(inBody: Data(Self.computersInventory.utf8))
        #expect(found.contains(FoundIdentifier(.device, "Jane’s MacBook Pro")))
        #expect(found.contains(FoundIdentifier(.device, "C02XK1JHJG5H")))
        // other sections have names of their own
        #expect(!found.contains { $0.value == "macOS" || $0.value == "Headquarters" || $0.value == "All Managed Macs" })
        let masker = IdentifierMasker(found)
        let masked = masker.mask("GET \"Jane’s MacBook Pro\" running macOS")
        #expect(!masked.contains("Jane’s MacBook Pro") && masked.contains("macOS"))
    }

    @Test func aMobileDeviceDisplayNameIsMasked() {
        let found = IdentifierMasker.identifiers(inBody: Data(Self.mobileInventory.utf8))
        #expect(found.contains(FoundIdentifier(.device, "Front Desk iPad")))
    }

    @Test func aDisplayNameOutsideADeviceRecordIsKept() {
        let prestages = #"{"results": [{"id": "1", "displayName": "Contoso Macs"}]}"#
        #expect(IdentifierMasker.identifiers(inBody: Data(prestages.utf8)).isEmpty)
    }
}

@MainActor
@Suite("Activity log boundary")
struct ActivityLogBoundaryTests {
    @Test func anAppsOwnEntryIsRedacted() throws {
        let log = ActivityLog()
        log.append(ActivityLogEntry(
            category: "App", operation: "POST", detail: "/token?client_secret=abc12345", note: "Sent Bearer abcdefghijk",
            request: ActivityRequestDetails(url: "https://x.example/token?password=hunter22",
                                            requestHeaders: [HTTPHeader(name: "Authorization", value: "Basic dXNlcjpwYXNz")],
                                            requestBody: #"{"apiKey": "k-123456789"}"#)))
        let entry = try #require(log.entries.first)
        let text = ActivityLogExport.transcript(of: entry)
        for secret in ["abc12345", "abcdefghijk", "hunter22", "dXNlcjpwYXNz", "k-123456789"] {
            #expect(!text.contains(secret), "\(secret) was logged")
        }
    }

    @Test func anActionSummaryIsRedacted() throws {
        let log = ActivityLog()
        log.recordAction("Signed in with client_secret=abc12345")
        #expect(try #require(log.entries.first).detail == "Signed in with client_secret=<redacted>")
    }

    @Test func theBackgroundExportIsTheSameText() async {
        let entries = [ActivityLogEntry(category: "API", operation: "GET", detail: "/a", status: 200)]
        let app = ActivityLogAppInfo(name: "Test", version: "1", system: "macOS")
        let date = Date(timeIntervalSince1970: 0)
        let built = await ActivityLogExport.textInBackground(entries, masked: true, app: app, exported: date)
        #expect(built == ActivityLogExport.text(entries, masked: true, app: app, exported: date))
    }
}

@Suite("Sensitive requests and redirects")
struct RecorderRuleTests {
    @Test("Every computer’s FileVault key and a LAPS password’s history are withheld",
          arguments: ["/api/v1/computers-inventory/filevault", "/pro/v1/computers-inventory/filevault/",
                      "/api/v2/local-admin-password/ABC-123/account/admin/history", "/api/v2/local-admin-password/ABC-123/history"])
    func withheld(_ path: String) {
        #expect(SensitiveRequests.isSensitive(path: path))
    }

    @Test func noPortIsHTTPSsOwn() throws {
        let rule = RedirectRule.sameHostHTTPSOnly
        let plain = try #require(URL(string: "https://host.example/a"))
        #expect(rule.allows(from: plain, to: URL(string: "https://host.example:443/b")))
        #expect(rule.allows(from: URL(string: "https://host.example:443/a"), to: URL(string: "https://host.example/b")))
        #expect(!rule.allows(from: plain, to: URL(string: "https://host.example:8443/b")))
    }
}

@Suite("Demo connections never use the real network")
struct DemoBoundaryTests {
    @Test("A demo request on a real session is refused before anything is sent",
          arguments: ["https://contoso-platform.demo.invalid/auth/token",
                      "https://login.microsoftonline.com/\(DemoWorld.intuneTenantID)/oauth2/v2.0/token"])
    func refusedOnARealSession(_ address: String) async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let recorder = RequestRecorder(session: server.session, log: nil)
        await #expect(throws: DemoBoundary.Refusal.self) {
            _ = try await recorder.send(URLRequest(url: try #require(URL(string: address))))
        }
        #expect(server.requests.isEmpty)
    }

    @Test func aSignInNamingADemoClientIsRefused() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        var request = URLRequest(url: try #require(URL(string: "https://appleid.apple.com/auth/oauth2/v2/token")))
        request.httpMethod = "POST"
        request.httpBody = Data("grant_type=client_credentials&client_id=\(Connection.demoAppleBusiness.clientID)".utf8)
        await #expect(throws: DemoBoundary.Refusal.self) {
            _ = try await RequestRecorder(session: server.session, log: nil).send(request)
        }
        #expect(server.requests.isEmpty)
    }

    @Test func aRealRequestIsSent() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        var request = URLRequest(url: try #require(URL(string: "https://login.microsoftonline.com/\(UUID().uuidString)/oauth2/v2.0/token")))
        request.httpBody = Data("client_id=\(UUID().uuidString)".utf8)
        _ = try await RequestRecorder(session: server.session, log: nil).send(request)
        #expect(server.requests.count == 1)
    }

    @Test func aDemoRequestOnTheDemoNetworkIsSent() async throws {
        let network = DemoNetwork(servers: [DemoSamples.platformHost: DemoJamfPlatformServer()])
        var request = URLRequest(url: try #require(URL(string: "https://\(DemoSamples.platformHost)/auth/token")))
        request.httpMethod = "POST"
        let (_, response) = try await RequestRecorder(session: network.session, log: nil).send(request)
        #expect(response.statusCode == 200)
    }
}

/// A storage whose saves can be made to fail.
@MainActor
private final class FailingStorage: ConnectionStorage {
    var records: [SampleTenant] = []
    var failsSaves = false

    func load() throws -> [SampleTenant] { records }
    func save(_ records: [SampleTenant]) throws {
        if failsSaves { throw CocoaError(.fileWriteNoPermission) }
        self.records = records
    }
    func backUpOnce() throws {}
    func keepUnreadableCopy() -> String? { nil }
}

/// Secrets whose reads fail, as a locked or damaged Keychain item.
private final class UnreadableSecretStore: SecretStore, @unchecked Sendable {
    let inner = InMemorySecretStore()
    func secret(for account: String) -> String? { nil }
    func setSecret(_ secret: String?, for account: String) -> Bool { inner.setSecret(secret, for: account) }
    func hasSecret(for account: String) throws -> Bool { throw SecretStoreError(status: -25308) }
    func readSecret(for account: String) throws -> String? { throw SecretStoreError(status: -25308) }
}

@MainActor
@Suite("Saving secrets and records together")
struct ConnectionSaveOrderTests {
    private let record = SampleTenant(name: "Sandbox", environmentId: "", clientId: "client")

    @Test func aFailedRecordSavePutsTheSecretsBack() throws {
        let secrets = InMemorySecretStore()
        let storage = FailingStorage()
        let store = ConnectionStore(storage: storage, secrets: [.main: SecretLocation(store: secrets),
                                                               .protect: SecretLocation(store: secrets, account: { "p-\($0.id)" })])
        try store.save(record, secrets: [.main: "old-secret"])
        storage.failsSaves = true
        #expect(throws: ConnectionStoreError.self) { try store.save(record, secrets: [.main: "new-secret", .protect: "protect"]) }
        #expect(store.secret(.main, for: record.connection) == "old-secret")
        #expect(store.secret(.protect, for: record.connection) == nil)
    }

    @Test func aRefusedSecretPutsTheEarlierOnesBack() throws {
        let main = InMemorySecretStore()
        let protect = InMemorySecretStore()
        let store = ConnectionStore(storage: FailingStorage(), secrets: [.main: SecretLocation(store: main),
                                                                        .protect: SecretLocation(store: protect)])
        try store.save(record, secrets: [.main: "old-secret"])
        protect.refusesWrites = true
        #expect(throws: ConnectionStoreError.keychainRefused(status: nil)) {
            try store.save(record, secrets: [.main: "new-secret", .protect: "protect"])
        }
        #expect(store.secret(.main, for: record.connection) == "old-secret")
    }

    @Test func aFailedLookupIsNotAbsence() throws {
        let store = ConnectionStore(storage: FailingStorage(), secrets: [.main: SecretLocation(store: UnreadableSecretStore())])
        #expect(throws: SecretStoreError.self) { try store.hasSecret(.main, for: record.connection) }
        // replacing an unreadable secret is how it’s repaired
        try store.save(record, secrets: [.main: "new-secret"])
    }

    @Test func theKeychainIsAskedForAttributesOnly() throws {
        let keychain = KeychainSecretStore(service: "be.jordythery.jtkit.tests.\(UUID().uuidString)")
        let account = UUID().uuidString
        defer { keychain.setSecret(nil, for: account) }
        #expect(try keychain.hasSecret(for: account) == false)
        #expect(try keychain.readSecret(for: account) == nil)
        #expect(keychain.setSecret("value", for: account))
        #expect(try keychain.hasSecret(for: account))
        #expect(try keychain.readSecret(for: account) == "value")
    }
}

@MainActor
@Suite("Unreadable saved lists")
struct UnreadableStorageTests {
    @Test func aValueThatIsntDataIsUnreadable() throws {
        let name = "JTKitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("not data", forKey: "connections")
        let store = ConnectionStore(storage: UserDefaultsConnectionStorage<SampleTenant>(key: "connections", defaults: defaults),
                                    secrets: [:])
        #expect(store.problem != nil)
        #expect(throws: ConnectionStoreError.self) { try store.save(SampleTenant(name: "New")) }
        #expect(defaults.string(forKey: "connections") == "not data")
    }

    @Test func readingAgainMakesNoMoreCopies() throws {
        let name = "JTKitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("{".utf8), forKey: "connections")
        let store = ConnectionStore(storage: UserDefaultsConnectionStorage<SampleTenant>(key: "connections", defaults: defaults),
                                    secrets: [:])
        store.reload()
        store.reload()
        let copies = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("connections.unreadable") }
        #expect(copies.count == 1)
    }

    @Test func readingAFileAgainMakesNoMoreCopies() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jtkit-unreadable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "tenants.json")
        try Data("{".utf8).write(to: file)
        let store = ConnectionStore(storage: JSONFileConnectionStorage<SampleTenant>(fileURL: file), secrets: [:])
        store.reload()
        store.reload()
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("unreadable") }
        #expect(copies.count == 1)
    }
}

@Suite("A stored secret goes with the values it was saved with")
struct StoredSecretBindingTests {
    let saved = Connection(name: "Prod", service: .jamfPro, serverURL: "https://prod.jamfcloud.com", clientID: "c")

    @Test func unchangedOrOnlyRenamedUsesTheStoredSecret() {
        var edited = saved
        edited.name = "Production"
        edited.serverURL = " https://PROD.jamfcloud.com "
        #expect(ConnectionServiceChoices.storedSecretApplies(.main, saved: saved, edited: edited))
        #expect(!ConnectionServiceChoices.savingClearsStoredSecrets(saved: saved, edited: edited))
    }

    @Test func aChangedAddressNeedsTheSecretAgain() {
        var edited = saved
        edited.serverURL = "https://prod.jamfcloud.co"
        #expect(!ConnectionServiceChoices.storedSecretApplies(.main, saved: saved, edited: edited))
        #expect(!ConnectionServiceChoices.savingClearsStoredSecrets(saved: saved, edited: edited))
    }

    @Test func aChangedServiceOrSignInNeedsItAgainAndClearsItOnSave() {
        var school = saved
        school.service = .jamfSchool
        school.signIn = .schoolAPIKey
        var password = saved
        password.signIn = .usernamePassword
        for edited in [school, password] {
            #expect(!ConnectionServiceChoices.storedSecretApplies(.main, saved: saved, edited: edited))
            #expect(ConnectionServiceChoices.savingClearsStoredSecrets(saved: saved, edited: edited))
        }
    }

    @Test func platformRegionAndHostAndProtectURLCount() {
        let platform = Connection(name: "P", service: .jamfPlatform, region: .us, protect: JamfProtectSettings(url: "https://a.protect.jamfcloud.com"))
        var region = platform
        region.region = .eu
        var host = platform
        host.hostOverride = "staging.example"
        var protect = platform
        protect.protect?.url = "https://b.protect.jamfcloud.com"
        #expect(!ConnectionServiceChoices.storedSecretApplies(.main, saved: platform, edited: region))
        #expect(!ConnectionServiceChoices.storedSecretApplies(.main, saved: platform, edited: host))
        #expect(ConnectionServiceChoices.storedSecretApplies(.main, saved: platform, edited: protect))
        #expect(!ConnectionServiceChoices.storedSecretApplies(.protect, saved: platform, edited: protect))
    }
}

@MainActor
@Suite("Leaving demo mode from the picker")
struct LeavingDemoModeTests {
    private final class Choice: @unchecked Sendable {
        var id: UUID?
        var binding: Binding<UUID?> { Binding(get: { self.id }, set: { self.id = $0 }) }
    }

    private func demoRole() throws -> (DemoMode, ConnectionRole, Choice) {
        let name = "JTKitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        let demo = DemoMode(key: "demoMode", defaults: defaults, arguments: ["-JTKitDemo", "YES"])
        let choice = Choice()
        let role = ConnectionRole.active(selection: choice.binding,
                                         demo: DemoConnectionChoice(mode: demo, connections: [.demoJamfPlatform]))
        return (demo, role, choice)
    }

    /// A role with "All", as Checkpoint’s Apple role has.
    private func demoRoleWithAll() throws -> (DemoMode, ConnectionRole, Choice, AllConnectionsChoice) {
        let defaults = try #require(UserDefaults(suiteName: "JTKitTests.\(UUID().uuidString)"))
        let demo = DemoMode(key: "demoMode", defaults: defaults, arguments: ["-JTKitDemo", "YES"])
        let choice = Choice()
        let all = AllConnectionsChoice(title: "All Organizations")
        let role = ConnectionRole("Apple", selection: choice.binding, all: all,
                                  demo: DemoConnectionChoice(mode: demo, connections: [.demoJamfPlatform]))
        return (demo, role, choice, all)
    }

    // The toolbar picker (`ConnectionPicker`) and the Connection menu
    // (`ConnectionCommands`) both list the saved connections through
    // `ConnectionMenuItems`, whose Picker is bound to `role.menuChoice`:
    // these tests set that binding as a click in either one does.

    @Test("Picker and menu: a saved connection while demo mode is on asks first; Cancel changes nothing")
    func menuChoiceOfASavedConnection() throws {
        let (demo, role, choice) = try demoRole()
        demo.asksBeforeSwitching = { true }
        let menu = role.menuChoice(connectionCount: 2)
        #expect(menu.wrappedValue == nil, "no saved connection is ticked while demo mode is on")
        let id = UUID()
        menu.wrappedValue = .connection(id)
        #expect(demo.isOn && demo.pendingSwitch == false && choice.id == nil)
        demo.cancelSwitch()
        #expect(demo.isOn && demo.pendingSwitch == nil && choice.id == nil)
        #expect(role.menuChoice(connectionCount: 2).wrappedValue == nil)

        role.menuChoice(connectionCount: 2).wrappedValue = .connection(id)
        demo.confirmSwitch()
        #expect(!demo.isOn && choice.id == id)
        #expect(role.menuChoice(connectionCount: 2).wrappedValue == .connection(id))
    }

    @Test("Picker and menu: “All” while demo mode is on asks first; Cancel changes nothing")
    func menuChoiceOfAll() throws {
        let (demo, role, choice, all) = try demoRoleWithAll()
        choice.id = UUID()
        let saved = choice.id
        demo.asksBeforeSwitching = { true }
        role.menuChoice(connectionCount: 2).wrappedValue = .all
        #expect(demo.isOn && demo.pendingSwitch == false && !all.isChosen)
        demo.cancelSwitch()
        demo.confirmSwitch()
        #expect(demo.isOn && !all.isChosen && choice.id == saved)

        role.menuChoice(connectionCount: 2).wrappedValue = .all
        demo.confirmSwitch()
        #expect(!demo.isOn && all.isChosen && choice.id == saved, "All leaves the saved single connection as it is")
        #expect(role.menuChoice(connectionCount: 2).wrappedValue == .all)
    }

    @Test("Picker and menu: without unsaved work they leave demo mode straight away")
    func menuChoiceWithoutAQuestion() throws {
        let (demo, role, choice, all) = try demoRoleWithAll()
        let id = UUID()
        role.menuChoice(connectionCount: 2).wrappedValue = .connection(id)
        #expect(!demo.isOn && demo.pendingSwitch == nil && choice.id == id && !all.isChosen)
    }

    @Test("Choosing a demo connection keeps demo mode on and asks nothing")
    func demoChoiceStaysInDemo() throws {
        let (demo, role, choice) = try demoRole()
        var asked = false
        demo.asksBeforeSwitching = { asked = true; return true }
        let demoChoice = try #require(role.demo)
        demoChoice.menuChoice.wrappedValue = .connection(Connection.demoJamfPlatform.id)
        #expect(demo.isOn && !asked && demo.pendingSwitch == nil && choice.id == nil)
    }

    @Test func choosingASavedConnectionAsksFirst() throws {
        let (demo, role, choice) = try demoRole()
        demo.asksBeforeSwitching = { true }
        let id = UUID()
        role.use(id)
        #expect(demo.isOn && demo.pendingSwitch == false)
        #expect(choice.id == nil, "nothing changes before the answer")
        demo.confirmSwitch()
        #expect(!demo.isOn && choice.id == id)
    }

    @Test func cancellingKeepsEverything() throws {
        let (demo, role, choice) = try demoRole()
        demo.asksBeforeSwitching = { true }
        role.use(UUID())
        demo.cancelSwitch()
        demo.confirmSwitch()
        #expect(demo.isOn && choice.id == nil)
    }

    @Test func withoutAQuestionItSwitchesStraightAway() throws {
        let (demo, role, choice) = try demoRole()
        let id = UUID()
        role.use(id)
        #expect(!demo.isOn && choice.id == id)
    }

    @Test func thePickerOffersTheDemoInsteadOfAddConnection() {
        #expect(ConnectionMenuText.showsAddButton(isEmpty: true, hasExtraItems: false, usesDemo: false))
        #expect(!ConnectionMenuText.showsAddButton(isEmpty: true, hasExtraItems: false, usesDemo: true))
        #expect(!ConnectionMenuText.showsAddButton(isEmpty: true, hasExtraItems: true, usesDemo: false))
        #expect(!ConnectionMenuText.showsAddButton(isEmpty: false, hasExtraItems: false, usesDemo: false))
    }
}
