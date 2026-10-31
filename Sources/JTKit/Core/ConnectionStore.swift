import Foundation
import Observation

/// Where one kind of secret of a connection is kept: the app’s store (its
/// Keychain service) and the account name it has always used.
public nonisolated struct SecretLocation: Sendable {
    public let store: any SecretStore
    public let account: @Sendable (Connection) -> String

    /// - Parameters:
    ///   - store: e.g. `KeychainSecretStore(service: "JamfMigrator-tenant")`.
    ///   - account: the account name for a connection; by default its id,
    ///     e.g. `"E4908A92-FC22-43B0-90CD-646796719708"`.
    public init(store: any SecretStore,
                account: @escaping @Sendable (Connection) -> String = { $0.id.uuidString }) {
        self.store = store
        self.account = account
    }
}

/// Why the store can’t do what was asked, in plain language.
public nonisolated enum ConnectionStoreError: LocalizedError, Equatable, Sendable {
    /// The saved list couldn’t be read. Nothing is saved until it is fixed.
    case unreadable(detail: String, copy: String?)
    case couldNotSave(String)
    /// The Keychain refused a secret; `status` is its error code, when known.
    case keychainRefused(status: OSStatus?)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail, let copy):
            let copyNote = copy.map { " A copy is at \($0)." } ?? ""
            return "The saved connections couldn’t be read, so changes aren’t saved until this is fixed (\(detail)).\(copyNote)"
        case .couldNotSave(let detail):
            return "The connections couldn’t be saved: \(detail)"
        case .keychainRefused(let status):
            return SecretWriteError(status: status).errorDescription ?? ""
        }
    }
}

/// The app’s saved connections: its own records, in its own storage, with
/// their secrets in its own Keychain items.
///
/// Safety rule: when the saved list can’t be read, the store keeps a copy,
/// reports `problem`, and refuses every save, so it never replaces saved
/// connections with an empty list. The first save makes a one-time backup of
/// the data as it was (`ConnectionStorage.backUpOnce`).
@MainActor
@Observable
public final class ConnectionStore<Record: ConnectionRecord> {

    public private(set) var records: [Record] = []
    /// Set when the saved list couldn’t be read.
    public private(set) var problem: ConnectionStoreError?

    @ObservationIgnored private let storage: any ConnectionStorage<Record>
    @ObservationIgnored private let secretLocations: [ConnectionSecretKind: SecretLocation]
    @ObservationIgnored private let log: ((String) -> Void)?
    @ObservationIgnored private var hasBackedUp = false

    /// - Parameters:
    ///   - storage: where the app’s records are, e.g. `JSONFileConnectionStorage`.
    ///   - secrets: where each kind of secret is; kinds the app doesn’t use are left out.
    ///   - log: receives problems, never secrets.
    public init(storage: any ConnectionStorage<Record>,
                secrets: [ConnectionSecretKind: SecretLocation],
                log: ((String) -> Void)? = nil) {
        self.storage = storage
        self.secretLocations = secrets
        self.log = log
        reload()
    }

    /// Reads the saved list again, e.g. after another Mac changed it.
    public func reload() {
        do {
            records = try storage.load()
            problem = nil
        } catch {
            let copy = storage.keepUnreadableCopy()
            problem = .unreadable(detail: error.localizedDescription, copy: copy)
            records = []
            log?("[Connections] couldn’t read the saved connections: \(error); copy: \(copy ?? "none")")
        }
    }

    public func record(id: UUID) -> Record? {
        records.first { $0.id == id }
    }

    /// Adds the record, or replaces the saved one with the same id.
    public func save(_ record: Record) throws {
        // Demo connections live in memory only.
        guard !record.connection.isDemo else {
            throw ConnectionStoreError.couldNotSave("“\(record.connection.name)” is a demo connection, which is never saved.")
        }
        var updated = records
        if let index = updated.firstIndex(where: { $0.id == record.id }) {
            updated[index] = record
        } else {
            updated.append(record)
        }
        try write(updated)
    }

    /// Adds the record and its secrets, or replaces the saved ones. A secret
    /// left out of `secrets` stays as it is; an empty one is deleted. Secrets
    /// are written first, so a record is never saved with a missing secret;
    /// when a secret or the record can’t be saved, the secrets already
    /// written are put back as they were, so a failed save changes nothing
    /// (except a secret the Keychain couldn’t read, which can’t be put back).
    public func save(_ record: Record, secrets: [ConnectionSecretKind: String]) throws {
        if let problem { throw problem }
        guard !record.connection.isDemo else {
            throw ConnectionStoreError.couldNotSave("“\(record.connection.name)” is a demo connection, which is never saved.")
        }
        var previous = [(kind: ConnectionSecretKind, secret: String?)]()
        func putBack() {
            for (kind, secret) in previous.reversed() {
                setSecret(secret, kind, for: record.connection)
            }
        }
        for kind in ConnectionSecretKind.allCases {
            guard let secret = secrets[kind] else { continue }
            // what to put back; one that can’t be read is replaced anyway (the
            // way to repair it) and can’t be put back
            let old: String??
            do {
                old = .some(try readSecret(kind, for: record.connection))
            } catch {
                log?("[Connections] couldn’t read the \(kind.rawValue) secret before replacing it: \(error)")
                old = nil
            }
            do {
                try writeSecret(secret.isEmpty ? nil : secret, kind, for: record.connection)
            } catch {
                putBack()
                throw ConnectionStoreError.keychainRefused(status: (error as? SecretWriteError)?.status)
            }
            if let old { previous.append((kind, old)) }
        }
        do {
            try save(record)
        } catch {
            putBack()
            throw error
        }
    }

    /// Removes the record and all its secrets.
    public func delete(id: UUID) throws {
        guard let record = record(id: id) else { return }
        try write(records.filter { $0.id != id })
        for kind in secretLocations.keys {
            setSecret(nil, kind, for: record.connection)
        }
    }

    // MARK: Secrets

    public func secret(_ kind: ConnectionSecretKind = .main, for connection: Connection) -> String? {
        guard !connection.isDemo else { return nil }
        guard let location = secretLocations[kind] else { return nil }
        return location.store.secret(for: location.account(connection))
    }

    /// Whether a secret is stored, asking the Keychain for the item’s
    /// attributes only, never its value. Demo connections have none.
    /// - Throws: `SecretStoreError` when the Keychain can’t tell.
    public func hasSecret(_ kind: ConnectionSecretKind = .main, for connection: Connection) throws -> Bool {
        guard !connection.isDemo, let location = secretLocations[kind] else { return false }
        return try location.store.hasSecret(for: location.account(connection))
    }

    /// The secret, nil when none is stored; throws when it can’t be read.
    func readSecret(_ kind: ConnectionSecretKind, for connection: Connection) throws -> String? {
        guard !connection.isDemo, let location = secretLocations[kind] else { return nil }
        return try location.store.readSecret(for: location.account(connection))
    }

    /// Passing nil deletes the secret. Returns false when the write failed.
    @discardableResult
    public func setSecret(_ secret: String?, _ kind: ConnectionSecretKind = .main, for connection: Connection) -> Bool {
        // Demo connections never touch the Keychain.
        guard !connection.isDemo else { return false }
        guard let location = secretLocations[kind] else { return secret == nil }
        return location.store.setSecret(secret, for: location.account(connection))
    }

    private func writeSecret(_ secret: String?, _ kind: ConnectionSecretKind, for connection: Connection) throws {
        guard !connection.isDemo else { throw SecretWriteError(status: nil) }
        guard let location = secretLocations[kind] else {
            if secret == nil { return }
            throw SecretWriteError(status: nil)
        }
        try location.store.writeSecret(secret, for: location.account(connection))
    }

    /// Whether the app stores this kind of secret.
    public func stores(_ kind: ConnectionSecretKind) -> Bool {
        secretLocations[kind] != nil
    }

    // MARK: Writing

    private func write(_ updated: [Record]) throws {
        if let problem { throw problem }
        if !hasBackedUp {
            do {
                try storage.backUpOnce()
                hasBackedUp = true
            } catch {
                // without the backup the original stays untouched
                log?("[Connections] couldn’t make the one-time backup: \(error)")
                throw ConnectionStoreError.couldNotSave("the one-time backup failed: \(error.localizedDescription)")
            }
        }
        do {
            try storage.save(updated)
            // what the storage holds now; an adapter may keep more than the
            // records it was given, e.g. what it last wrote
            records = (try? storage.load()) ?? updated
        } catch {
            log?("[Connections] couldn’t save: \(error)")
            throw ConnectionStoreError.couldNotSave(error.localizedDescription)
        }
    }
}
