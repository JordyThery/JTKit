import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

/// An app's own record, shaped like JamfMigrator's `Tenant`: its own field
/// names, an app-only field, optional keys left out when nil.
nonisolated struct SampleTenant: Codable, Equatable, Sendable, ConnectionRecord {
    var id = UUID()
    var name: String
    var region = "us"
    var environmentId = ""
    var clientId = ""
    var serverURL: String?
    var username: String?
    var isProtected = false

    var connection: Connection {
        get {
            Connection(id: id, name: name,
                       service: (serverURL ?? "").isEmpty ? .jamfPlatform : .jamfPro,
                       signIn: (username ?? "").isEmpty ? .apiClient : .usernamePassword,
                       serverURL: serverURL ?? "", region: JamfRegion(rawValue: region) ?? .us,
                       environmentID: environmentId, clientID: clientId, username: username ?? "")
        }
        set {
            name = newValue.name
            region = newValue.region.rawValue
            environmentId = newValue.environmentID
            clientId = newValue.clientID
            serverURL = newValue.service == .jamfPlatform ? nil : newValue.serverURL
            username = newValue.signIn == .usernamePassword ? newValue.username : nil
        }
    }
}

@MainActor
@Suite("Saved connections")
struct ConnectionStoreTests {

    /// Written like JamfMigrator's tenants.json: pretty-printed, sorted keys,
    /// slashes escaped, no trailing newline.
    static let existingFile = """
    [
      {
        "clientId" : "client-a",
        "environmentId" : "11111111-2222-3333-4444-555555555555",
        "id" : "AAAAAAAA-0000-0000-0000-000000000001",
        "isProtected" : true,
        "name" : "Sandbox",
        "region" : "us"
      },
      {
        "clientId" : "",
        "environmentId" : "",
        "id" : "AAAAAAAA-0000-0000-0000-000000000003",
        "isProtected" : false,
        "name" : "Demo (direct)",
        "region" : "us",
        "serverURL" : "https:\\/\\/demo.jamfcloud.com",
        "username" : "admin"
      }
    ]
    """

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "jtkit-connection-tests/\(UUID().uuidString)/tenants.json")
    }

    private func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func makeStore(_ url: URL, secrets: InMemorySecretStore = InMemorySecretStore()) -> ConnectionStore<SampleTenant> {
        ConnectionStore(storage: JSONFileConnectionStorage<SampleTenant>(fileURL: url),
                        secrets: [.main: SecretLocation(store: secrets)])
    }

    // MARK: Format

    @Test func savingAnUnchangedListWritesTheSameBytes() throws {
        let url = temporaryFile()
        defer { cleanUp(url) }
        try write(Self.existingFile, to: url)

        let store = makeStore(url)
        #expect(store.problem == nil)
        #expect(store.records.map(\.name) == ["Sandbox", "Demo (direct)"])
        try store.save(store.records[0])

        #expect(try String(contentsOf: url, encoding: .utf8) == Self.existingFile)
    }

    @Test func readingAndSettingTheConnectionLeavesTheRecordUnchanged() throws {
        let url = temporaryFile()
        defer { cleanUp(url) }
        try write(Self.existingFile, to: url)

        for record in makeStore(url).records {
            var copy = record
            copy.connection = record.connection
            #expect(copy == record)
        }
    }

    @Test func noFileMeansAnEmptyListAndNoProblem() {
        let url = temporaryFile()
        let store = makeStore(url)
        #expect(store.records.isEmpty)
        #expect(store.problem == nil)
    }

    // MARK: Safety rule

    @Test func anUnreadableListIsKeptCopiedAndNeverSavedOver() throws {
        let url = temporaryFile()
        defer { cleanUp(url) }
        let damaged = #"[{"id":"AAAAAAAA-0000-0000-0000-000000000001","name":"Sandbox"}]"#
        try write(damaged, to: url)

        let store = makeStore(url)
        guard case .unreadable(_, let copy) = store.problem else {
            Issue.record("expected the unreadable problem")
            return
        }
        let copyPath = try #require(copy)
        #expect(try String(contentsOfFile: copyPath, encoding: .utf8) == damaged)

        #expect(throws: ConnectionStoreError.self) {
            try store.save(SampleTenant(name: "New tenant"))
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == damaged)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path))
    }

    // MARK: One-time backup

    @Test func theFirstSaveBacksUpTheOriginalOnce() throws {
        let url = temporaryFile()
        defer { cleanUp(url) }
        try write(Self.existingFile, to: url)
        let backup = url.appendingPathExtension("backup")

        let store = makeStore(url)
        var renamed = store.records[0]
        renamed.name = "Golden master"
        try store.save(renamed)
        #expect(try String(contentsOf: backup, encoding: .utf8) == Self.existingFile)

        renamed.name = "Golden master 2"
        try store.save(renamed)
        // a later launch doesn't replace the backup either
        try makeStore(url).save(renamed)
        #expect(try String(contentsOf: backup, encoding: .utf8) == Self.existingFile)
    }

    @Test func nothingToBackUpWhenNothingWasSaved() throws {
        let url = temporaryFile()
        defer { cleanUp(url) }
        try makeStore(url).save(SampleTenant(name: "First"))
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path))
    }

    // MARK: Secrets

    @Test func secretsAreSavedUnderTheAppsAccountNamesAndNeverInTheFile() throws {
        let url = temporaryFile()
        defer { cleanUp(url) }
        let secrets = InMemorySecretStore()
        let store = makeStore(url, secrets: secrets)

        let tenant = SampleTenant(name: "Sandbox")
        try store.save(tenant, secrets: [.main: "hunter2"])
        #expect(secrets.all == [tenant.id.uuidString: "hunter2"])
        #expect(store.secret(for: tenant.connection) == "hunter2")
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("hunter2"))

        // a secret left out stays; an empty one is deleted
        try store.save(tenant, secrets: [:])
        #expect(store.secret(for: tenant.connection) == "hunter2")
        try store.save(tenant, secrets: [.main: ""])
        #expect(secrets.all.isEmpty)
    }

    @Test func aRefusedSecretSavesNothing() throws {
        let url = temporaryFile()
        defer { cleanUp(url) }
        let secrets = InMemorySecretStore()
        secrets.refusesWrites = true
        let store = makeStore(url, secrets: secrets)

        #expect(throws: ConnectionStoreError.keychainRefused) {
            try store.save(SampleTenant(name: "Sandbox"), secrets: [.main: "hunter2"])
        }
        #expect(store.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func deletingRemovesTheRecordAndEverySecret() throws {
        let url = temporaryFile()
        defer { cleanUp(url) }
        let main = InMemorySecretStore()
        let protect = InMemorySecretStore()
        let store = ConnectionStore(storage: JSONFileConnectionStorage<SampleTenant>(fileURL: url),
                                    secrets: [.main: SecretLocation(store: main),
                                              .protect: SecretLocation(store: protect) { "protect.\($0.id.uuidString)" }])
        let tenant = SampleTenant(name: "Sandbox")
        try store.save(tenant, secrets: [.main: "a", .protect: "b"])
        #expect(protect.all == ["protect.\(tenant.id.uuidString)": "b"])

        try store.delete(id: tenant.id)
        #expect(store.records.isEmpty)
        #expect(main.all.isEmpty)
        #expect(protect.all.isEmpty)
        #expect(makeStore(url).records.isEmpty)
    }

    // MARK: UserDefaults

    @Test func userDefaultsStorageKeepsTheKeyAndBacksUpOnce() throws {
        let suite = "jtkit-connection-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let original = try JSONEncoder().encode([SampleTenant(name: "Sandbox")])
        defaults.set(original, forKey: "connectionProfiles")

        let store = ConnectionStore(storage: UserDefaultsConnectionStorage<SampleTenant>(key: "connectionProfiles", defaults: defaults),
                                    secrets: [.main: SecretLocation(store: InMemorySecretStore())])
        #expect(store.records.map(\.name) == ["Sandbox"])
        try store.save(SampleTenant(name: "Demo"))

        #expect(defaults.data(forKey: "connectionProfiles.backup") == original)
        let saved = try JSONDecoder().decode([SampleTenant].self, from: try #require(defaults.data(forKey: "connectionProfiles")))
        #expect(saved.map(\.name) == ["Sandbox", "Demo"])
    }

    @Test func unreadableUserDefaultsAreKeptAndNeverSavedOver() throws {
        let suite = "jtkit-connection-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let damaged = Data("not json".utf8)
        defaults.set(damaged, forKey: "connectionProfiles")

        let store = ConnectionStore(storage: UserDefaultsConnectionStorage<SampleTenant>(key: "connectionProfiles", defaults: defaults),
                                    secrets: [:])
        #expect(store.problem != nil)
        #expect(throws: ConnectionStoreError.self) { try store.save(SampleTenant(name: "Demo")) }
        #expect(defaults.data(forKey: "connectionProfiles") == damaged)
        #expect(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("connectionProfiles.unreadable-") })
    }
}

@Suite("Connection")
struct ConnectionTests {
    @Test func eachServiceStartsWithItsUsualSignIn() {
        #expect(Connection(name: "A", service: .jamfPlatform).signIn == .apiClient)
        #expect(Connection(name: "A", service: .jamfSchool).signIn == .schoolAPIKey)
        #expect(Connection(name: "A", service: .appleSchoolManager).signIn == .applePrivateKey)
        #expect(Connection(name: "A", service: .jamfPro, signIn: .usernamePassword).signIn == .usernamePassword)
    }

    @Test func issuesExplainTypedValuesThatCantWork() {
        var platform = Connection(name: "A", service: .jamfPlatform)
        #expect(platform.issues.isEmpty)
        platform.environmentID = "env-1"
        #expect(platform.issues.count == 1)
        platform.environmentID = "11111111-2222-3333-4444-555555555555"
        #expect(platform.issues.isEmpty)

        var server = Connection(name: "B", service: .jamfPro, serverURL: "https://")
        #expect(server.issues.count == 1)
        server.serverURL = "http://demo.jamfcloud.com"
        #expect(server.issues.count == 1)
        server.serverURL = "https://demo.jamfcloud.com"
        #expect(server.issues.isEmpty)
    }

    @Test func summaryNamesTheServiceAndWhereItPoints() {
        #expect(Connection(name: "A", service: .jamfPlatform, region: .eu).summary == "Jamf Platform API · EU")
        #expect(Connection(name: "B", service: .jamfPro, serverURL: "https://demo.jamfcloud.com").summary == "Jamf Pro · demo.jamfcloud.com")
        #expect(Connection(name: "C", service: .appleBusinessManager).summary == "Apple Business Manager")
    }
}

@Suite("Keychain")
struct KeychainSecretStoreTests {
    /// Uses a throwaway service name and removes its item, so no app's
    /// Keychain items are touched.
    @Test func savesUpdatesReadsAndDeletes() {
        let store = KeychainSecretStore(service: "be.jordythery.jtkit.tests.\(UUID().uuidString)",
                                        accessibility: .afterFirstUnlock)
        let account = UUID().uuidString
        defer { store.setSecret(nil, for: account) }

        #expect(store.secret(for: account) == nil)
        #expect(store.setSecret("first", for: account))
        #expect(store.secret(for: account) == "first")
        #expect(store.setSecret("second", for: account))
        #expect(store.secret(for: account) == "second")
        #expect(store.setSecret(nil, for: account))
        #expect(store.secret(for: account) == nil)
        // deleting what isn't there is not a failure
        #expect(store.setSecret(nil, for: account))
    }
}
