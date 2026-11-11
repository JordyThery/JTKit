import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

/// Like the Keychain: deleting an item that isn’t there succeeds, and the
/// accounts in `refusing` refuse every write with the Keychain’s error code.
/// Every call is written down, so a test can tell the store was never reached.
nonisolated final class FakeKeychain: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]
    private var refusals: [String: OSStatus] = [:]
    private var log: [String] = []

    init(_ items: [String: String] = [:]) {
        self.items = items
    }

    var all: [String: String] { lock.withLock { items } }
    var calls: [String] { lock.withLock { log } }

    /// errSecInteractionNotAllowed (-25308) by default: a locked Keychain.
    func refuse(_ account: String, status: OSStatus = -25308) {
        lock.withLock { refusals[account] = status }
    }

    /// The Keychain lets the account be written again, e.g. once unlocked.
    func allow(_ account: String) {
        lock.withLock { refusals[account] = nil }
    }

    func secret(for account: String) -> String? { try? readSecret(for: account) }

    func readSecret(for account: String) throws -> String? {
        lock.withLock {
            log.append("read \(account)")
            return items[account]
        }
    }

    func setSecret(_ secret: String?, for account: String) -> Bool {
        (try? writeSecret(secret, for: account)) != nil
    }

    func writeSecret(_ secret: String?, for account: String) throws {
        try lock.withLock {
            log.append("\(secret == nil ? "delete" : "write") \(account)")
            if let status = refusals[account] { throw SecretWriteError(status: status) }
            items[account] = secret
        }
    }
}

@MainActor
@Suite("Deleting a connection")
struct ConnectionDeleteTests {

    private let url = FileManager.default.temporaryDirectory
        .appending(path: "jtkit-connection-delete-tests/\(UUID().uuidString)/tenants.json")

    private func cleanUp() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Main secrets under the connection’s id, Jamf Protect secrets under
    /// "protect.<id>", both in `keychain`.
    private func makeStore(_ keychain: FakeKeychain) -> ConnectionStore<SampleTenant> {
        ConnectionStore(storage: JSONFileConnectionStorage<SampleTenant>(fileURL: url),
                        secrets: [.main: SecretLocation(store: keychain),
                                  .protect: SecretLocation(store: keychain) { "protect.\($0.id.uuidString)" }])
    }

    private func saved(_ store: ConnectionStore<SampleTenant>) throws -> SampleTenant {
        let tenant = SampleTenant(name: "Sandbox")
        try store.save(tenant, secrets: [.main: "made-up-secret", .protect: "made-up-protect-secret"])
        return tenant
    }

    @Test func aRefusedDeleteKeepsTheRecordAndThrows() throws {
        defer { cleanUp() }
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        let tenant = try saved(store)
        keychain.refuse(tenant.id.uuidString)

        let expected = ConnectionStoreError.keychainRefused(
            status: -25308, deletion: .init(connection: "Sandbox", secret: "client secret"))
        #expect(throws: expected) { try store.delete(id: tenant.id) }
        #expect(store.records == [tenant])
        #expect(makeStore(keychain).records == [tenant])
        #expect(keychain.all.count == 2)
        #expect(expected.localizedDescription
                == "The Keychain refused to delete the client secret of “Sandbox” (error -25308), so the connection was kept. If the Keychain is locked, unlock it, then delete the connection again.")
    }

    @Test func aSecretThatIsntThereCountsAsDeleted() throws {
        defer { cleanUp() }
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        // saved without a Jamf Protect secret
        let tenant = SampleTenant(name: "Sandbox")
        try store.save(tenant, secrets: [.main: "made-up-secret"])

        try store.delete(id: tenant.id)
        #expect(store.records.isEmpty)
        #expect(keychain.all.isEmpty)
        #expect(keychain.calls.suffix(2) == ["delete \(tenant.id.uuidString)", "delete protect.\(tenant.id.uuidString)"])
    }

    @Test func aRefusalOnTheSecondSecretKeepsTheRecordAndSaysWhatWasDeleted() throws {
        defer { cleanUp() }
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        let tenant = try saved(store)
        keychain.refuse("protect.\(tenant.id.uuidString)", status: -25293)

        let expected = ConnectionStoreError.keychainRefused(
            status: -25293,
            deletion: .init(connection: "Sandbox", secret: "Jamf Protect client secret", alreadyDeleted: ["client secret"]))
        #expect(throws: expected) { try store.delete(id: tenant.id) }
        #expect(store.records == [tenant])
        #expect(makeStore(keychain).records == [tenant])
        // the first one stays deleted; the refused one is still there
        #expect(keychain.all == ["protect.\(tenant.id.uuidString)": "made-up-protect-secret"])
        #expect(expected.localizedDescription
                == "The Keychain refused to delete the Jamf Protect client secret of “Sandbox” (error -25293), so the connection was kept. Its client secret was already deleted. If the Keychain is locked, unlock it, then delete the connection again.")

        // tried again once the Keychain lets it: everything goes
        keychain.allow("protect.\(tenant.id.uuidString)")
        try store.delete(id: tenant.id)
        #expect(store.records.isEmpty)
        #expect(keychain.all.isEmpty)
    }

    @Test func aNormalDeleteRemovesBothSecretsAndTheRecord() throws {
        defer { cleanUp() }
        let keychain = FakeKeychain()
        let store = makeStore(keychain)
        let tenant = try saved(store)
        let other = SampleTenant(name: "Other")
        try store.save(other, secrets: [.main: "another-made-up-secret"])

        try store.delete(id: tenant.id)
        #expect(store.records == [other])
        #expect(makeStore(keychain).records == [other])
        #expect(keychain.all == [other.id.uuidString: "another-made-up-secret"])
    }

    @Test func aDemoConnectionNeverTouchesTheKeychain() throws {
        let keychain = FakeKeychain()
        let demo = SampleTenant(id: Connection.demoJamfPlatform.id, name: "Contoso")
        #expect(demo.connection.isDemo)
        let store = ConnectionStore(storage: InMemoryConnectionStorage([demo, SampleTenant(name: "Sandbox")]),
                                    secrets: [.main: SecretLocation(store: keychain),
                                              .protect: SecretLocation(store: keychain)])

        try store.delete(id: demo.id)
        #expect(store.records.map(\.name) == ["Sandbox"])
        #expect(keychain.calls.isEmpty)
    }

    @Test func theRefusalWithoutACodeOrWithTwoDeletedReadsPlainly() {
        let error = ConnectionStoreError.keychainRefused(
            status: nil, deletion: .init(connection: "Sandbox", secret: "private key", alreadyDeleted: ["password", "API key"]))
        #expect(error.localizedDescription
                == "The Keychain refused to delete the private key of “Sandbox”, so the connection was kept. Its password and API key were already deleted. If the Keychain is locked, unlock it, then delete the connection again.")
        // a refused save reads as before
        #expect(ConnectionStoreError.keychainRefused(status: -25308).localizedDescription
                == "The Keychain refused to save the secret (error -25308).")
    }
}
