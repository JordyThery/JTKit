import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JTKit
import JTKitTestSupport

// The fixes in 1.1.0 (ROADMAP "1.1.0", Part A). The Blueprint deploy
// fallback (A13) is tested with the other Blueprint calls in
// JamfPlatformTests; the lookups with other characters (A10) also in
// ABMTests, JamfProTests and MDMCommandTests.

@MainActor
private final class Choice {
    var id: UUID?
    var binding: Binding<UUID?> { Binding(get: { self.id }, set: { self.id = $0 }) }
}

@MainActor
private func store(_ records: [SampleTenant] = [], secrets: InMemorySecretStore = InMemorySecretStore()) -> ConnectionStore<SampleTenant> {
    ConnectionStore(storage: InMemoryConnectionStorage(records), secrets: [.main: SecretLocation(store: secrets)])
}

// MARK: - A1 Keychain errors

@MainActor
@Suite("A Keychain that can’t be read isn’t “no secret”")
struct SecretReadingTests {
    let tenant = SampleTenant(name: "Sandbox", clientId: "c")

    @Test func readSecretReportsTheKeychainError() throws {
        let secrets = InMemorySecretStore([tenant.id.uuidString: "s3cret"])
        let connections = store([tenant], secrets: secrets)
        #expect(try connections.readSecret(for: tenant.connection) == "s3cret")
        secrets.refusesReads = true
        #expect(throws: SecretStoreError(status: -25308)) { try connections.readSecret(for: tenant.connection) }
        #expect(throws: SecretStoreError(status: -25308)) { try connections.hasSecret(for: tenant.connection) }
    }

    @Test func requiredSecretSaysWhichProblemItIs() throws {
        let secrets = InMemorySecretStore()
        let connections = store([tenant], secrets: secrets)
        let missing = #expect(throws: MissingSecretError.self) { try connections.requiredSecret(for: tenant.connection) }
        #expect(missing?.localizedDescription == "No client secret is stored for “Sandbox”. Enter it in Settings › Connections.")
        secrets.refusesReads = true
        #expect(throws: SecretStoreError.self) { try connections.requiredSecret(for: tenant.connection) }
        secrets.refusesReads = false
        secrets.setSecret("s3cret", for: tenant.id.uuidString)
        #expect(try connections.requiredSecret(for: tenant.connection) == "s3cret")
    }

    @Test func aConversionCopyThrowsWhenTheOldSecretCantBeRead() throws {
        let old = InMemorySecretStore(["clientSecret": "old-secret"])
        let secrets = InMemorySecretStore()
        let connections = store([tenant], secrets: secrets)

        old.refusesReads = true
        #expect(throws: SecretStoreError.self, "so the conversion isn’t marked done and runs again next launch") {
            try connections.copySecret(from: old, account: "clientSecret", for: tenant.connection)
        }
        #expect(secrets.all.isEmpty)

        old.refusesReads = false
        #expect(try connections.copySecret(from: old, account: "clientSecret", for: tenant.connection))
        #expect(secrets.all == [tenant.id.uuidString: "old-secret"])
        #expect(old.all == ["clientSecret": "old-secret"], "the original is left as it is")
        #expect(try !connections.copySecret(from: old, account: "none", for: tenant.connection), "nothing to copy")
    }

    @Test func aRefusedWriteDuringTheCopyThrows() {
        let old = InMemorySecretStore(["clientSecret": "old-secret"])
        let secrets = InMemorySecretStore()
        secrets.refusesWrites = true
        #expect(throws: ConnectionStoreError.keychainRefused(status: nil)) {
            try store([tenant], secrets: secrets).copySecret(from: old, account: "clientSecret", for: tenant.connection)
        }
    }
}

// MARK: - A2, A3, A4 The editor’s secret rules and server addresses

@Suite("Stored secrets in the editor")
struct EditorSecretRuleTests {
    @Test func aPlatformRegionChangeKeepsTheSecretUsable() {
        let saved = Connection(name: "P", service: .jamfPlatform, region: .us, environmentID: UUID().uuidString, clientID: "c")
        var edited = saved
        edited.region = .eu
        #expect(ConnectionServiceChoices.storedSecretApplies(.main, saved: saved, edited: edited))
        edited.hostOverride = "staging.example"
        #expect(!ConnectionServiceChoices.storedSecretApplies(.main, saved: saved, edited: edited), "another host still needs it typed")
    }

    @Test func onlyTheSchemeChangingKeepsTheSecretUsable() {
        let saved = Connection(name: "S", service: .jamfPro, serverURL: "myorg.jamfcloud.com")
        for address in ["https://myorg.jamfcloud.com", "https://MyOrg.jamfcloud.com/", "http://myorg.jamfcloud.com"] {
            var edited = saved
            edited.serverURL = address
            #expect(ConnectionServiceChoices.storedSecretApplies(.main, saved: saved, edited: edited), "\(address)")
        }
        var other = saved
        other.serverURL = "https://other.jamfcloud.com"
        #expect(!ConnectionServiceChoices.storedSecretApplies(.main, saved: saved, edited: other))
    }

    @Test func theEditorSaysBeforeSaveWhichSecretGoes() {
        let saved = Connection(name: "S", service: .jamfPro, signIn: .apiClient, serverURL: "https://a.jamfcloud.com")
        var signIn = saved
        signIn.signIn = .usernamePassword
        #expect(ConnectionServiceChoices.secretRemovalNotice(saved: saved, edited: signIn, stored: [.main])
                == "Saving removes the stored client secret from the Keychain: it was for the “API client” sign-in. Revert to keep it.")
        var service = saved
        service.service = .jamfSchool
        service.signIn = .schoolAPIKey
        #expect(ConnectionServiceChoices.secretRemovalNotice(saved: saved, edited: service, stored: [.main, .protect])
                == "Saving removes the stored client secret and the Jamf Protect client secret from the Keychain: it was for Jamf Pro. Revert to keep it.")
        #expect(ConnectionServiceChoices.secretRemovalNotice(saved: saved, edited: signIn, stored: []) == nil, "nothing stored")
        var renamed = saved
        renamed.name = "T"
        #expect(ConnectionServiceChoices.secretRemovalNotice(saved: saved, edited: renamed, stored: [.main]) == nil)
    }

    @Test func addressesWithoutASchemeGetHTTPS() {
        #expect(Connection.normalizedServerAddress("myorg.jamfcloud.com") == "https://myorg.jamfcloud.com")
        #expect(Connection.normalizedServerAddress(" myorg.jamfcloud.com ") == "https://myorg.jamfcloud.com")
        #expect(Connection.normalizedServerAddress("https://a.example") == "https://a.example")
        #expect(Connection.normalizedServerAddress("http://a.example") == "http://a.example")
        #expect(Connection.normalizedServerAddress("") == "")
        #expect(Connection.addressProblem("myorg.jamfcloud.com") == nil)
        #expect(Connection.addressProblem("http://myorg.jamfcloud.com") == "Use an https:// address.")
        #expect(Connection(name: "S", service: .jamfPro, serverURL: "myorg.jamfcloud.com").jamfBaseURL
                == URL(string: "https://myorg.jamfcloud.com"))
        #expect(Connection(name: "S", service: .jamfPro, serverURL: "http://myorg.jamfcloud.com").jamfBaseURL == nil)
        #expect(Connection(name: "S", service: .jamfSchool, serverURL: "school.jamfcloud.com").summary == "Jamf School · school.jamfcloud.com")
    }

    @Test func anHTTPAddressIsRefusedWithOneClearSentence() throws {
        let http = Connection(name: "Old", service: .jamfPro, serverURL: "http://myorg.example", clientID: "c")
        let platform = #expect(throws: JamfPlatform.APIError.self) {
            _ = try JamfPlatform.Client(connection: http, secret: { "s" }, recorder: RequestRecorder(session: .shared, log: nil))
        }
        #expect(platform?.message().contains("“Old” has an http:// address. Use an https:// address.") == true)
        let school = #expect(throws: JamfSchool.APIError.self) {
            _ = try JamfSchool.Client(address: "http://school.example", networkID: "1", apiKey: "k",
                                      recorder: RequestRecorder(session: .shared, log: nil))
        }
        #expect(school?.message().contains("Use an https:// address.") == true)
    }
}

@MainActor
@Suite("Saved addresses without a scheme")
struct SavedAddressTests {
    @Test func theStoreAddsHTTPSWhenReadingAndSaving() throws {
        let old = SampleTenant(name: "Direct", serverURL: "demo.jamfcloud.com", username: "admin")
        let storage = InMemoryConnectionStorage([old])
        let connections = ConnectionStore(storage: storage, secrets: [:])
        #expect(connections.records.first?.serverURL == "https://demo.jamfcloud.com")
        #expect(connections.records.first?.connection.issues.isEmpty == true, "so Save isn’t blocked")
        #expect(try storage.load().first?.serverURL == "demo.jamfcloud.com", "the saved data changes only at the next save")

        var typed = SampleTenant(name: "New", serverURL: "new.jamfcloud.com", username: "admin")
        typed.isProtected = true
        try connections.save(typed)
        let saved = try storage.load()
        #expect(saved.map(\.serverURL) == ["https://demo.jamfcloud.com", "https://new.jamfcloud.com"])
        #expect(saved.last?.isProtected == true, "the app’s own fields are kept")
    }

    @Test func otherAddressesAreLeftAsTheyAre() {
        let records = [SampleTenant(name: "A", serverURL: "https://a.example", username: "u"),
                       SampleTenant(name: "B", serverURL: "http://b.example", username: "u"),
                       SampleTenant(name: "P", environmentId: UUID().uuidString, clientId: "c")]
        let connections = ConnectionStore(storage: InMemoryConnectionStorage(records), secrets: [:])
        #expect(connections.records == records)
    }
}

// MARK: - A5 Closing Settings with unsaved changes

@MainActor
@Suite("Closing a window with unsaved changes")
struct WindowCloseGuardTests {
    private final class Delegate: NSObject, NSWindowDelegate {
        var resized = 0
        var allowsClose = true
        func windowShouldClose(_ sender: NSWindow) -> Bool { allowsClose }
        func windowDidResize(_ notification: Notification) { resized += 1 }
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func asksInsteadOfClosingAndClosesAfterwardsWithoutAskingAgain() {
        let window = window()
        let original = Delegate()
        window.delegate = original
        let closeGuard = CloseGuard()
        closeGuard.attach(to: window)
        var asked = 0
        closeGuard.ask = { _ in asked += 1 }

        closeGuard.isActive = true
        #expect(!closeGuard.windowShouldClose(window))
        #expect(asked == 1)
        #expect(window.delegate === closeGuard)

        original.allowsClose = true
        closeGuard.close(window)  // the person chose Save or Discard
        #expect(asked == 1, "not asked again")
    }

    @Test func withoutChangesTheWindowsOwnDelegateDecides() {
        let window = window()
        let original = Delegate()
        window.delegate = original
        let closeGuard = CloseGuard()
        closeGuard.attach(to: window)
        closeGuard.isActive = false
        original.allowsClose = false
        #expect(!closeGuard.windowShouldClose(window))
        original.allowsClose = true
        #expect(closeGuard.windowShouldClose(window))
    }

    @Test func everythingElseGoesToTheWindowsOwnDelegate() {
        let window = window()
        let original = Delegate()
        window.delegate = original
        let closeGuard = CloseGuard()
        closeGuard.attach(to: window)
        #expect(closeGuard.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
        (window.delegate as? NSWindowDelegate)?.windowDidResize?(Notification(name: NSWindow.didResizeNotification))
        #expect(original.resized == 1)
        closeGuard.detach()
        #expect(window.delegate === original)
    }
}

// MARK: - A6 A new connection in use

@MainActor
@Suite("A new or imported connection becomes the one in use when none is")
struct RoleFillingTests {
    @Test func theFirstRoleWithoutAConnectionGetsIt() throws {
        let connections = store()
        let source = Choice(), destination = Choice()
        let roles = [ConnectionRole("Source", selection: source.binding), ConnectionRole("Destination", selection: destination.binding)]

        let first = SampleTenant(name: "A", clientId: "a")
        try connections.save(first)
        for role in ConnectionRoleFilling.roles(toGive: first.connection, among: roles, store: connections) {
            role.selection.wrappedValue = first.id
        }
        #expect(source.id == first.id)
        #expect(destination.id == nil, "one connection doesn’t get two roles")

        let second = SampleTenant(name: "B", clientId: "b")
        try connections.save(second)
        #expect(ConnectionRoleFilling.roles(toGive: second.connection, among: roles, store: connections).map(\.title) == ["Destination"])
    }

    @Test func aRoleInUseKeepsItsConnection() throws {
        let saved = SampleTenant(name: "A", clientId: "a")
        let connections = store([saved])
        let active = Choice()
        active.id = saved.id
        let roles = [ConnectionRole.active(selection: active.binding)]
        let added = SampleTenant(name: "B", clientId: "b")
        try connections.save(added)
        #expect(ConnectionRoleFilling.roles(toGive: added.connection, among: roles, store: connections).isEmpty)

        active.id = UUID()  // a connection that is no longer saved counts as none
        #expect(ConnectionRoleFilling.roles(toGive: added.connection, among: roles, store: connections).count == 1)
    }

    @Test func onlyARoleThatAcceptsTheService() throws {
        let connections = store()
        let apple = Choice()
        let roles = [ConnectionRole("Apple", selection: apple.binding, services: [.appleBusinessManager])]
        let tenant = SampleTenant(name: "A", clientId: "a")
        try connections.save(tenant)
        #expect(ConnectionRoleFilling.roles(toGive: tenant.connection, among: roles, store: connections).isEmpty)
    }
}

// MARK: - A7 Waits you can see and stop

@MainActor
@Suite("Waits before a retry")
struct RequestWaitTests {
    private let base = URL(string: "https://us.api.jamfcloud.com")!

    @Test func theDefaultLongestWaitIs60Seconds() {
        #expect(RetryRules.standard.longestWait == 60)
        #expect(RetryRules.defaultLongestWait == 60)
    }

    @Test func messages() {
        #expect(RequestWaits.message(.askedToWait, seconds: 40, service: "Jamf Platform API") == "Jamf asked to wait 40 s")
        #expect(RequestWaits.message(.serverError(503), seconds: 3.2, service: "Jamf Pro") == "Jamf answered HTTP 503: trying again in 4 s")
        #expect(RequestWaits.message(.tooManyRequests, seconds: 2, service: "Microsoft Graph") == "Microsoft asked to slow down: trying again in 2 s")
        #expect(RequestWaits.message(.networkError, seconds: 1, service: "Apple Business") == "No answer from Apple: trying again in 1 s")
        #expect(RequestWaits.message(.networkError, seconds: 1, service: nil) == "No answer from The server: trying again in 1 s")
        #expect(RequestWaits.message(.rateLimit("Apple allows about 20 requests a minute"), seconds: 12, service: "Apple Business")
                == "Apple allows about 20 requests a minute: waiting 12 s")
    }

    @Test func aWaitIsShownAndStopsAtOnceWhenCanceled() async throws {
        let server = MockServer { _ in .json(429, "{}", headers: ["Retry-After": "40"]) }
        let log = ActivityLog()
        let waits = RequestWaits()
        let client = HTTPClient(baseURL: base, tokens: FixedToken("tok"),
                                recorder: RequestRecorder(session: server.session, log: log, service: "Jamf Platform API", waits: waits),
                                sleep: { try await Task.sleep(for: $0) })
        let task = Task { try await client.send(HTTPRequest(path: "x")) }
        for _ in 0..<500 where waits.current.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(waits.statusText == "Jamf asked to wait 40 s")
        let started = ContinuousClock.now
        waits.cancelAll()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(5), "at once, not after 40 s")
        #expect(waits.current.isEmpty)
        #expect(server.requests.count == 1, "not sent again")
        #expect(log.entries.contains { $0.note == "Canceled while waiting." })
    }

    @Test func aWaitEndsWhenTheTaskIsCanceled() async throws {
        let server = MockServer { _ in .json(503, "{}") }
        let waits = RequestWaits()
        let client = HTTPClient(baseURL: base, tokens: FixedToken("tok"),
                                recorder: RequestRecorder(session: server.session, log: nil, service: "Jamf Pro", waits: waits),
                                rules: RetryRules(firstWait: 30), sleep: { try await Task.sleep(for: $0) }, random: { 0 })
        let task = Task { try await client.send(HTTPRequest(path: "x")) }
        for _ in 0..<500 where waits.current.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(waits.statusText == "Jamf answered HTTP 503: trying again in 30 s")
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(waits.current.isEmpty)
    }

    @Test func severalWaitsAreSummed() {
        let waits = RequestWaits()
        let now = Date()
        waits.begin(.init(message: "Jamf asked to wait 10 s", until: now), cancel: {})
        waits.begin(.init(message: "Jamf asked to wait 20 s", until: now), cancel: {})
        #expect(waits.statusText == "Jamf asked to wait 20 s (and 1 more wait)")
        waits.cancelAll()
        #expect(waits.statusText == nil)
    }
}

// MARK: - A8 Activity log

@MainActor
@Suite("Activity log: copy, capacity, bodies")
struct ActivityLogFixTests {
    @Test func copyLogPutsTheWholeLogOnTheClipboardMaskedOrNot() async {
        let entries = [ActivityLogEntry.action("Restarted C02XK1JHJG5H", devices: ["C02XK1JHJG5H"])]
        let app = ActivityLogAppInfo(name: "Test", version: "1.0", system: "macOS")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("jtkit-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        await ActivityLogExport.copy(entries, masked: false, app: app, to: pasteboard)
        #expect(pasteboard.string(forType: .string)?.contains("C02XK1JHJG5H") == true)
        await ActivityLogExport.copy(entries, masked: true, app: app, to: pasteboard)
        let masked = pasteboard.string(forType: .string) ?? ""
        #expect(!masked.contains("C02XK1JHJG5H"))
        #expect(masked.contains("Restarted"))
    }

    @Test func anAppCanKeepMoreEntries() {
        #expect(ActivityLog().capacity == ActivityLog.standardCapacity)
        let log = ActivityLog(capacity: 10_000)
        for index in 0..<1_500 { log.append(ActivityLogEntry(category: "API", operation: "GET", detail: "/\(index)")) }
        #expect(log.entries.count == 1_500)
    }

    @Test func requestsTheAppMarksHaveTheirBodiesRecorded() async throws {
        let server = MockServer { _ in .json(200, #"{"id":"b1"}"#) }
        let log = ActivityLog()
        let recorder = RequestRecorder(session: server.session, log: log, recordsBodies: { method, path in
            path.hasPrefix("blueprints/") || path.hasPrefix("pro/v1/mdm/")
        })
        let client = HTTPClient(baseURL: URL(string: "https://us.api.jamfcloud.com")!, tokens: FixedToken("tok"), recorder: recorder)
        _ = try await client.send(HTTPRequest(method: "PATCH", path: "blueprints/v1/blueprints/b1", body: Data(#"{"steps":[]}"#.utf8)))
        _ = try await client.send(HTTPRequest(method: "POST", path: "other", body: Data(#"{"a":1}"#.utf8)))
        // a sensitive call stays withheld, whatever the app marks
        _ = try await client.send(HTTPRequest(method: "POST", path: "pro/v1/mdm/commands", body: Data(#"{"pin":"123456"}"#.utf8)))

        let entries = log.entries
        #expect(entries[0].request?.requestBody?.contains("steps") == true)
        #expect(entries[0].request?.responseBody?.contains("b1") == true)
        #expect(entries[1].request?.requestBody == nil)
        #expect(entries[2].request?.contentsWithheld == true)
        #expect(entries[2].request?.requestBody == nil)
    }
}

// MARK: - A9 Apple private key

@Suite("Apple private key: paste, or any text file")
struct ApplePrivateKeyPasteTests {
    let pem = "-----BEGIN PRIVATE KEY-----\nMIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg\n-----END PRIVATE KEY-----"

    @Test func aPastedKeyIsReadLikeAFile() throws {
        #expect(try ApplePrivateKey.read(pasted: "  \(pem)\n") == pem)
        #expect(throws: ApplePrivateKey.ImportError.nothingPasted) { try ApplePrivateKey.read(pasted: nil) }
        #expect(throws: ApplePrivateKey.ImportError.nothingPasted) { try ApplePrivateKey.read(pasted: " \n") }
        #expect(throws: ApplePrivateKey.ImportError.notPrivateKey) { try ApplePrivateKey.read(pasted: "my password") }
    }

    @Test func theImporterOffersAnyTextFile() throws {
        let types = ApplePrivateKey.contentTypes
        #expect(types.contains(.plainText))
        #expect(types.contains { $0.tags[.filenameExtension]?.contains("pem") == true })
        #expect(types.contains { $0.tags[.filenameExtension]?.contains("p8") == true })
        // the contents decide, not the name
        let folder = FileManager.default.temporaryDirectory.appending(path: "jtkit-key-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["AuthKey.p8", "key.txt"] {
            let file = folder.appending(path: name)
            try Data(pem.utf8).write(to: file)
            #expect(try ApplePrivateKey.read(contentsOf: file) == pem)
        }
    }
}

// MARK: - A10 Jamf School lookups with other characters

@Suite("Jamf School: an identifier with other characters is not found")
struct JamfSchoolNotFoundTests {
    @Test func nothingIsSent() async throws {
        let server = MockServer { _ in .json(200, #"{"devices":[]}"#) }
        let client = try JamfSchool.Client(address: "school.jamfcloud.com", networkID: "1", apiKey: "k",
                                           recorder: RequestRecorder(session: server.session, log: nil), sleep: { _ in })
        #expect(try await client.device(serial: "C02 X") == .none)
        #expect(try await client.device(udid: "a\"b") == nil)
        #expect(server.requests.isEmpty)
    }
}

// MARK: - A11 Older Jamf Pro: v4 → v1, by the server’s version

@MainActor
@Suite("Older Jamf Pro: computer requests use the v1 paths below 11.30.0")
struct ComputersAPIVersionTests {
    let page = #"{"totalCount":1,"results":[{"id":"7","udid":"U-1","hardware":{"serialNumber":"C02OLD"}}]}"#

    /// A server of its own: what is learned is kept per server address.
    private func client(_ server: MockServer, log: ActivityLog? = nil, gateway: Bool = false) throws -> JamfPlatform.Client {
        try JamfPlatform.Client(baseURL: URL(string: "https://jss-\(UUID().uuidString.lowercased()).example")!,
                                scope: gateway ? .environment(UUID().uuidString) : .organization,
                                server: gateway ? .platformAPI : .jamfPro, tokens: FixedToken("tok"),
                                recorder: RequestRecorder(session: server.session, log: log, service: "Jamf Pro"),
                                sleep: { _ in }, random: { 0 })
    }

    private func server(version: String, page: String) -> MockServer {
        MockServer { request in
            if request.path.hasSuffix("jamf-pro-version") { return .json(200, #"{"version":"\#(version)"}"#) }
            if request.method == "GET" { return .json(200, page) }
            return MockResponse(status: 204, body: Data())
        }
    }

    @Test func versions() {
        #expect(ComputersAPIVersion.isOlderThanV4("11.29.2-t1792501724838"))
        #expect(ComputersAPIVersion.isOlderThanV4("10.49.0"))
        #expect(!ComputersAPIVersion.isOlderThanV4("11.30.0-t1"))
        #expect(!ComputersAPIVersion.isOlderThanV4("11.33.1"))
        #expect(!ComputersAPIVersion.isOlderThanV4("12.0"))
        #expect(!ComputersAPIVersion.isOlderThanV4("unknown"), "can’t be read: v4")
    }

    @Test func theV1Paths() {
        func v1(_ path: String) -> String? { ComputersAPIVersion.v1(of: HTTPRequest(path: path))?.path }
        #expect(v1("pro/v4/computers-inventory") == "pro/v1/computers-inventory")
        #expect(v1("/pro/v4/computers-inventory/7/filevault") == "pro/v1/computers-inventory/7/filevault")
        #expect(v1("pro/v4/computers-inventory-detail/7") == "pro/v1/computers-inventory-detail/7")
        #expect(v1("pro/v4/computers-inventory/7/erase") == "pro/v1/computer-inventory/7/erase")
        #expect(v1("pro/v4/computers-inventory/7/remove-mdm-profile") == "pro/v1/computer-inventory/7/remove-mdm-profile")
        #expect(v1("pro/v2/mobile-devices/detail") == nil)
        #expect(SensitiveRequests.isSensitive(path: "/api/v1/computer-inventory/7/erase"), "the older erase carries a PIN too")
    }

    @Test func anOlderServerUsesV1FromTheStartAskedOnceSaidOnce() async throws {
        let server = server(version: "11.29.2-t1", page: page)
        let log = ActivityLog()
        let jamf = try client(server, log: log)
        guard case .one(let computer) = try await jamf.computer(serial: "C02OLD") else {
            Issue.record("the computer wasn’t found over v1")
            return
        }
        #expect(computer.id == "7")
        try await jamf.setAssetTag("A1", computerID: "7")
        _ = try await jamf.computer(serial: "C02OLD")
        #expect(server.requests.map(\.path) == ["/api/v1/jamf-pro-version", "/api/v1/computers-inventory",
                                                "/api/v1/computers-inventory-detail/7", "/api/v1/computers-inventory"])
        #expect(log.entries.filter { $0.note?.contains("older than 11.30.0") == true }.count == 1)
    }

    @Test func aCurrentServerUsesV4AndA404IsJustNotFound() async throws {
        let server = MockServer { request in
            if request.path.hasSuffix("jamf-pro-version") { return .json(200, #"{"version":"11.33.1"}"#) }
            return .json(404, #"{"httpStatus":404}"#)
        }
        let jamf = try client(server)
        let error = await #expect(throws: JamfPlatform.APIError.self) { try await jamf.setAssetTag("A1", computerID: "999") }
        #expect(error?.status == 404)
        await #expect(throws: JamfPlatform.APIError.self) { try await jamf.setAssetTag("A1", computerID: "998") }
        #expect(server.requests.map(\.path) == ["/api/v1/jamf-pro-version", "/api/v4/computers-inventory-detail/999",
                                                "/api/v4/computers-inventory-detail/998"], "no v1 retry, version asked once")
    }

    @Test func theGatewayIsNeverAsked() async throws {
        let server = server(version: "11.0.0", page: page)
        _ = try await client(server, gateway: true).computer(serial: "C02OLD")
        #expect(server.requests.map(\.path) == ["/pro/v4/computers-inventory"])
    }

    @Test func aVersionThatCantBeReadUsesV4AndIsAskedAgain() async throws {
        let page = page
        let server = MockServer { request in
            request.path.hasSuffix("jamf-pro-version") ? .json(500, "{}") : .json(200, page)
        }
        let jamf = try client(server)
        _ = try await jamf.computer(serial: "C02OLD")
        _ = try await jamf.computer(serial: "C02OLD")
        #expect(server.requests.filter { $0.path.hasSuffix("jamf-pro-version") }.count == 8, "4 attempts, twice: not remembered")
        #expect(server.requests.filter { $0.path == "/api/v4/computers-inventory" }.count == 2)
    }

    @Test func aRefusedVersionReadIsRememberedAsV4() async throws {
        let page = page
        let server = MockServer { _ in .json(200, page) }
        let jamf = try JamfPlatform.Client(
            baseURL: URL(string: "https://jss-\(UUID().uuidString.lowercased()).example")!, scope: .organization, server: .jamfPro,
            tokens: FixedToken("tok"), recorder: RequestRecorder(session: server.session, log: nil),
            permits: { !$0.path.contains("jamf-pro-version") }, sleep: { _ in }, random: { 0 })
        _ = try await jamf.computer(serial: "C02OLD")
        _ = try await jamf.computer(serial: "C02OLD")
        #expect(server.requests.map(\.path) == ["/api/v4/computers-inventory", "/api/v4/computers-inventory"])
    }
}

// MARK: - A12 Environment ID

@Suite("The Environment ID in the editor")
struct EnvironmentIDIssueTests {
    @Test func aNonUUIDIsAnIssueOfTheFieldWithTheSameWordsAsTheRunTimeError() {
        let connection = Connection(name: "P", service: .jamfPlatform, environmentID: "my-env", clientID: "c")
        #expect(connection.issues == [JamfPlatform.APIError.environmentIDNotUUID])
        #expect(JamfPlatform.APIError.environmentIDNotUUID.contains("isn’t a UUID"))
        #expect(Connection(name: "P", service: .jamfPlatform, environmentID: UUID().uuidString).issues.isEmpty)
    }

    @Test func uppercaseIsAcceptedAndSentLowercased() async throws {
        let upper = "E77C1408-10C8-4007-B177-ABC9157FBCAA"
        #expect(Connection(name: "P", service: .jamfPlatform, environmentID: upper).issues.isEmpty)
        let server = MockServer { _ in .json(200, #"{"results":[],"totalCount":0}"#) }
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://us.api.jamfcloud.com")!, scope: .environment(" \(upper) "),
                                             tokens: FixedToken("tok"), recorder: RequestRecorder(session: server.session, log: nil))
        _ = try await client.send(HTTPRequest(path: "device-groups/v1/device-groups"))
        #expect(server.requests.first?.header("X-Environment-Id") == upper.lowercased())
    }
}

// MARK: - A15 Platform device actions’ permission

@MainActor
@Suite("A refused Platform device action names device-actions:execute")
struct DeviceActionPermissionTests {
    @Test func theGatewayNamesItsOwnPermission() async throws {
        let server = MockServer { _ in .json(403, #"{"httpStatus":403,"errors":[{"code":"FORBIDDEN"}]}"#) }
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://us.api.jamfcloud.com")!,
                                             scope: .environment(UUID().uuidString), tokens: FixedToken("tok"),
                                             recorder: RequestRecorder(session: server.session, log: nil))
        for action in [{ try await client.restart(deviceID: "d1") }, { try await client.shutDown(deviceID: "d1") }] {
            let error = await #expect(throws: JamfPlatform.APIError.self) { try await action() }
            let message = error?.message() ?? ""
            #expect(message.contains("“device-actions:execute” permission"))
            #expect(message.contains("Jamf Account"))
            #expect(!message.contains("Send Mobile Device"), "no Jamf Pro privilege for a Platform connection")
        }
    }

    @Test func otherRefusalsKeepTheGeneralHint() {
        let error = JamfPlatform.APIError(.status(403, body: nil, text: nil, method: "GET", path: "x"))
        #expect(error.message().contains("Check its permissions in Jamf Account."))
    }
}
