import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Testing
@testable import JTKit
import JTKitTestSupport

/// An app’s own record, shaped like JamfMigrator’s `Tenant`: its own field
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

    /// Written like JamfMigrator’s tenants.json: pretty-printed, sorted keys,
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
        // a later launch doesn’t replace the backup either
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

        #expect(throws: ConnectionStoreError.keychainRefused(status: nil)) {
            try store.save(SampleTenant(name: "Sandbox"), secrets: [.main: "hunter2"])
        }
        #expect(store.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aRefusedSecretNamesTheKeychainCode() throws {
        struct RefusingStore: SecretStore {
            func secret(for account: String) -> String? { nil }
            func setSecret(_ secret: String?, for account: String) -> Bool { false }
            func writeSecret(_ secret: String?, for account: String) throws { throw SecretWriteError(status: -25308) }
        }
        let url = temporaryFile()
        defer { cleanUp(url) }
        let store = ConnectionStore<SampleTenant>(storage: JSONFileConnectionStorage<SampleTenant>(fileURL: url),
                                                  secrets: [.main: SecretLocation(store: RefusingStore())])
        #expect(throws: ConnectionStoreError.keychainRefused(status: -25308)) {
            try store.save(SampleTenant(name: "Sandbox"), secrets: [.main: "hunter2"])
        }
        #expect(ConnectionStoreError.keychainRefused(status: -25308).localizedDescription
                == "The Keychain refused to save the secret (error -25308).")
        #expect(ConnectionStoreError.keychainRefused(status: nil).localizedDescription == "The Keychain refused to save the secret.")
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

    // MARK: Import

    private let sampleImport = ConnectionImport<SampleTenant>(contentTypes: [.json]) { data in
        try JSONDecoder().decode(SampleTenant.self, from: data)
    }

    @Test func importingSavesTheConnectionInTheFile() throws {
        let url = temporaryFile()
        defer { cleanUp(url) }
        let store = makeStore(url)
        let exported = url.deletingLastPathComponent().appending(path: "exported.json")
        let tenant = SampleTenant(name: "From another Mac", clientId: "client-b")
        try FileManager.default.createDirectory(at: exported.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(tenant).write(to: exported)

        let imported = try sampleImport.importRecord(from: exported, into: store)

        #expect(imported == tenant)
        #expect(store.records == [tenant])
        #expect(makeStore(url).records == [tenant])
    }

    @Test func importingNeverReplacesASavedConnection() throws {
        let url = temporaryFile()
        defer { cleanUp(url) }
        try write(Self.existingFile, to: url)
        let store = makeStore(url)
        var sameID = store.records[0]
        sameID.name = "Changed elsewhere"
        let exported = url.deletingLastPathComponent().appending(path: "exported.json")
        try JSONEncoder().encode(sameID).write(to: exported)

        #expect(throws: ConnectionImportError.alreadySaved("Sandbox")) {
            try sampleImport.importRecord(from: exported, into: store)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == Self.existingFile)
    }

    @Test func aFileThatIsNotAConnectionImportsNothing() throws {
        let url = temporaryFile()
        defer { cleanUp(url) }
        try write(Self.existingFile, to: url)
        let store = makeStore(url)
        let other = url.deletingLastPathComponent().appending(path: "other.json")
        try Data("{\"something\": \"else\"}".utf8).write(to: other)

        #expect(throws: (any Error).self) { try sampleImport.importRecord(from: other, into: store) }
        #expect(store.records.count == 2)
        #expect(try String(contentsOf: url, encoding: .utf8) == Self.existingFile)
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
        #expect(Connection(name: "C", service: .appleBusinessManager).summary == "Apple Business")
    }
}

@Suite("Keychain")
struct KeychainSecretStoreTests {
    /// Uses a throwaway service name and removes its item, so no app’s
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
        // deleting what isn’t there isn’t a failure
        #expect(store.setSecret(nil, for: account))
    }
}

@Suite("Connection test failures")
struct ConnectionTestFailureTests {
    private struct DetailedError: LocalizedError {
        var errorDescription: String?
        var failureReason: String?
        var recoverySuggestion: String?
    }

    @Test func showsEveryPartOfTheError() {
        let error = DetailedError(errorDescription: "HTTP 401 on POST /auth/token",
                                  failureReason: "httpStatus: 401\ntraceId: abc-123",
                                  recoverySuggestion: "Check the client secret.")
        #expect(connectionTestFailureText(error) == "HTTP 401 on POST /auth/token\n\nhttpStatus: 401\ntraceId: abc-123\n\nCheck the client secret.")
    }

    @Test func aPlainErrorShowsItsDescription() {
        let error = URLError(.notConnectedToInternet)
        #expect(connectionTestFailureText(error) == error.localizedDescription)
    }

    @Test func emptyAndRepeatedPartsAreLeftOut() {
        let error = DetailedError(errorDescription: "Timed out.", failureReason: "  ", recoverySuggestion: "Timed out.")
        #expect(connectionTestFailureText(error) == "Timed out.")
    }
}

@MainActor
@Suite("Settings tabs by name")
struct SettingsTabNameTests {
    @Test func sharedTabsHaveTheirToolbarNames() {
        #expect(SettingsTabName.general == "General")
        #expect(SettingsTabName.connections == "Connections")
        #expect(SettingsTabName.updates == "Updates")
    }

    @Test func settingsOpenOnGeneralUntilALinkAsksForAnotherTab() {
        #expect(SettingsTabSelection().selected == SettingsTabName.general)
    }
}

@MainActor
@Suite("Connection menu")
struct ConnectionMenuTests {
    @Test func everyAppUsesTheSameWords() {
        #expect(ConnectionMenuText.menuTitle == "Connection")
        #expect(ConnectionMenuText.editTitle == "Edit Connections…")
        #expect(ConnectionMenuText.addTitle == "Add Connection…")
    }

    @Test func thePickerIsNamedAfterTheConnectionInUse() {
        #expect(ConnectionMenuText.pickerTitle("Production (eu)") == "Production (eu)")
        #expect(ConnectionMenuText.pickerTitle(nil) == "No Connection")
    }

    @Test func anUnnamedConnectionIsNamedAsInTheConnectionsTab() {
        #expect(ConnectionMenuText.name(of: Connection(name: "", service: .jamfPro)) == "Unnamed Connection")
        #expect(ConnectionMenuText.name(of: Connection(name: "School", service: .jamfSchool)) == "School")
    }

    @Test func theLinkAddsUntilThereIsSomethingToEdit() {
        #expect(ConnectionMenuText.linkTitle(isEmpty: true, editTitle: "Edit Tenants…") == "Add Connection…")
        #expect(ConnectionMenuText.linkTitle(isEmpty: false, editTitle: "Edit Tenants…") == "Edit Tenants…")
    }
}

// MARK: - Roles, “All”, services offered and the Apple private key
/// A role’s choice, kept the way an app keeps it.
@MainActor
private final class SavedChoice {
    var id: UUID?
    var binding: Binding<UUID?> {
        Binding(get: { self.id }, set: { self.id = $0 })
    }
}

@MainActor
@Suite("Connection roles and “All”")
struct ConnectionRoleTests {
    let apple: Set<ConnectionService> = [.appleBusinessManager, .appleSchoolManager]

    @Test func aRoleAcceptsOnlyItsServices() {
        let role = ConnectionRole("Apple", selection: .constant(nil), services: apple)
        #expect(role.accepts(Connection(name: "Org", service: .appleSchoolManager)))
        #expect(!role.accepts(Connection(name: "Server", service: .jamfPro)))
        #expect(ConnectionRole.active(selection: .constant(nil)).accepts(Connection(name: "Server", service: .jamfPro)))
    }

    @Test func allIsOfferedOnlyWithTwoOrMoreConnections() {
        let all = AllConnectionsChoice(title: "All Organizations")
        all.isChosen = true
        #expect(!all.isInEffect(connectionCount: 0))
        #expect(!all.isInEffect(connectionCount: 1))
        #expect(all.isInEffect(connectionCount: 2))
    }

    @Test func choosingAllKeepsTheSavedSingleConnection() {
        let saved = SavedChoice()
        let first = UUID()
        saved.id = first
        let all = AllConnectionsChoice(title: "All Organizations")
        let role = ConnectionRole("Apple", selection: saved.binding, services: apple, all: all)
        let choice = role.menuChoice(connectionCount: 3)

        #expect(choice.wrappedValue == .connection(first))
        choice.wrappedValue = .all
        #expect(choice.wrappedValue == .all)
        #expect(role.usesAll(connectionCount: 3))
        // what the app saves is still the single connection
        #expect(saved.id == first)
    }

    @Test func allIsForThisSessionOnly() {
        let saved = SavedChoice()
        let first = UUID()
        saved.id = first
        let role = ConnectionRole("Apple", selection: saved.binding, all: AllConnectionsChoice(title: "All"))
        role.menuChoice(connectionCount: 2).wrappedValue = .all

        // a relaunch: a new "All" choice, the saved selection read again
        let relaunched = ConnectionRole("Apple", selection: saved.binding, all: AllConnectionsChoice(title: "All"))
        #expect(relaunched.menuChoice(connectionCount: 2).wrappedValue == .connection(first))
        #expect(!relaunched.usesAll(connectionCount: 2))
    }

    @Test func choosingASingleConnectionEndsAll() {
        let saved = SavedChoice()
        let all = AllConnectionsChoice(title: "All Connections")
        all.isChosen = true
        let role = ConnectionRole("MDM", selection: saved.binding, all: all)
        let other = UUID()
        role.menuChoice(connectionCount: 2).wrappedValue = .connection(other)
        #expect(!all.isChosen)
        #expect(saved.id == other)

        all.isChosen = true
        role.use(UUID())
        #expect(!all.isChosen)
    }

    @Test func allWithTooFewConnectionsShowsTheSingleConnection() {
        let saved = SavedChoice()
        let only = UUID()
        saved.id = only
        let all = AllConnectionsChoice(title: "All")
        all.isChosen = true
        let role = ConnectionRole("MDM", selection: saved.binding, all: all)
        #expect(role.menuChoice(connectionCount: 1).wrappedValue == .connection(only))
    }

    @Test func rolesWithoutAllWorkAsBefore() {
        let saved = SavedChoice()
        let role = ConnectionRole("Source", selection: saved.binding)
        #expect(role.useTitle == "Use as Source")
        #expect(role.all == nil)
        let id = UUID()
        role.menuChoice(connectionCount: 5).wrappedValue = .connection(id)
        #expect(saved.id == id)
        #expect(!role.usesAll(connectionCount: 5))
    }
}

@Suite("Services and sign-in methods offered")
struct ConnectionServiceChoicesTests {
    let offered: [ConnectionService] = [.appleBusinessManager, .appleSchoolManager, .jamfPro, .jamfPlatform, .jamfSchool, .intune]
    let groups: [[ConnectionService]] = [[.appleBusinessManager, .appleSchoolManager], [.jamfPro, .jamfPlatform, .jamfSchool, .intune]]

    @Test func aConnectionSwitchesOnlyWithinItsGroup() {
        #expect(ConnectionServiceChoices.services(for: .appleSchoolManager, offered: offered, groups: groups, allowsChanging: true)
                == [.appleBusinessManager, .appleSchoolManager])
        #expect(ConnectionServiceChoices.services(for: .intune, offered: offered, groups: groups, allowsChanging: true)
                == [.jamfPro, .jamfPlatform, .jamfSchool, .intune])
    }

    @Test func withoutGroupsEveryServiceIsOffered() {
        #expect(ConnectionServiceChoices.services(for: .jamfPro, offered: offered, groups: [], allowsChanging: true) == offered)
        #expect(ConnectionServiceChoices.services(for: .jamfPro, offered: offered, groups: groups, allowsChanging: false) == [.jamfPro])
    }

    @Test func thePlusMenuHasASectionPerGroup() {
        #expect(ConnectionServiceChoices.addMenuSections(offered: offered, groups: groups) == groups)
        #expect(ConnectionServiceChoices.addMenuSections(offered: [.jamfPro, .intune], groups: []) == [[.jamfPro, .intune]])
    }

    @Test func anAppCanLimitSignInMethods() {
        #expect(ConnectionServiceChoices.signInMethods(for: .intune, limits: [.intune: [.entraClientSecret]]) == [.entraClientSecret])
        #expect(ConnectionServiceChoices.signInMethods(for: .jamfPro, limits: [.intune: [.entraClientSecret]]) == [.apiClient, .usernamePassword])
        // a limit that leaves nothing falls back to the service’s own methods
        #expect(ConnectionServiceChoices.signInMethods(for: .jamfSchool, limits: [.jamfSchool: [.apiClient]]) == [.schoolAPIKey])
    }

    @Test func protectIsOfferedOnlyWhereTheAppAllowsIt() {
        let everywhere: Set<ConnectionService> = [.jamfPlatform, .jamfPro]
        #expect(ConnectionServiceChoices.offersProtect(for: .jamfPro, optionalFields: [.jamfProtect], protectServices: everywhere))
        #expect(ConnectionServiceChoices.offersProtect(for: .jamfPlatform, optionalFields: [.jamfProtect], protectServices: [.jamfPlatform]))
        // Jamf Deployer: Protect is part of Platform connections only
        #expect(!ConnectionServiceChoices.offersProtect(for: .jamfPro, optionalFields: [.jamfProtect], protectServices: [.jamfPlatform]))
        #expect(!ConnectionServiceChoices.offersProtect(for: .jamfPro, optionalFields: [], protectServices: everywhere))
        #expect(!ConnectionServiceChoices.offersProtect(for: .intune, optionalFields: [.jamfProtect], protectServices: [.intune]))
    }
}

@Suite("Apple private key import")
struct ApplePrivateKeyTests {
    static let key = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
    -----END PRIVATE KEY-----
    """

    @Test func acceptsAKeyAndTrimsSurroundingSpace() throws {
        #expect(try ApplePrivateKey.read(Data("\n\(Self.key)\n\n".utf8)) == Self.key)
        let ec = Self.key.replacingOccurrences(of: "PRIVATE KEY", with: "EC PRIVATE KEY")
        #expect(try ApplePrivateKey.read(Data(ec.utf8)) == ec)
    }

    @Test func refusesFilesThatAreNotAUsableKey() {
        let certificate = Self.key.replacingOccurrences(of: "PRIVATE KEY", with: "CERTIFICATE")
        let publicKey = Self.key.replacingOccurrences(of: "PRIVATE KEY", with: "PUBLIC KEY")
        let encrypted = Self.key.replacingOccurrences(of: "PRIVATE KEY", with: "ENCRYPTED PRIVATE KEY")
        #expect(throws: ApplePrivateKey.ImportError.notPrivateKey) { try ApplePrivateKey.read(Data(certificate.utf8)) }
        #expect(throws: ApplePrivateKey.ImportError.notPrivateKey) { try ApplePrivateKey.read(Data(publicKey.utf8)) }
        #expect(throws: ApplePrivateKey.ImportError.encrypted) { try ApplePrivateKey.read(Data(encrypted.utf8)) }
        #expect(throws: ApplePrivateKey.ImportError.empty) { try ApplePrivateKey.read(Data()) }
        #expect(throws: ApplePrivateKey.ImportError.empty) { try ApplePrivateKey.read(Data("  \n".utf8)) }
        #expect(throws: ApplePrivateKey.ImportError.notText) { try ApplePrivateKey.read(Data([0xFF, 0xFE, 0x00, 0xC3])) }
        #expect(throws: ApplePrivateKey.ImportError.tooLarge) {
            try ApplePrivateKey.read(Data(count: ApplePrivateKey.maximumSize + 1))
        }
    }

    @Test func readsAKeyFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("AuthKey_\(UUID().uuidString).pem")
        try Data(Self.key.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(try ApplePrivateKey.read(contentsOf: file) == Self.key)
    }

    @Test func aFileThatCantBeReadSaysSo() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("AuthKey_\(UUID().uuidString).pem")
        #expect(throws: ApplePrivateKey.ImportError.unreadable) { try ApplePrivateKey.read(contentsOf: missing) }
        #expect(ApplePrivateKey.ImportError.unreadable.localizedDescription == "The file couldn’t be read.")
    }
}
