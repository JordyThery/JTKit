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

/// No secret is stored for a connection that needs one.
public nonisolated struct MissingSecretError: LocalizedError, Equatable, Sendable {
    /// The connection’s name.
    public let connection: String
    /// e.g. "Client secret".
    public let secretName: String

    public init(connection: String, secretName: String) {
        self.connection = connection
        self.secretName = secretName
    }

    public var errorDescription: String? {
        "No \(secretName.lowercased()) is stored for “\(connection)”. Enter it in Settings › Connections."
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
    ///   - liveRecord: the app’s record for one of the release check’s
    ///     connections. Under the live-check switch (`LiveLaunch`) the store
    ///     holds only those, in memory, with their secrets from the run:
    ///     `storage` and the Keychain are never touched. Without it the store
    ///     is empty under the switch.
    public init(storage: any ConnectionStorage<Record>,
                secrets: [ConnectionSecretKind: SecretLocation],
                log: ((String) -> Void)? = nil,
                liveRecord: ((Connection) -> Record)? = nil) {
        if LiveLaunch.isSwitched {
            let records = LiveLaunch.connections.compactMap { liveRecord?($0) }
            self.storage = InMemoryConnectionStorage(records)
            self.secretLocations = Dictionary(uniqueKeysWithValues: secrets.keys.map {
                ($0, SecretLocation(store: LiveLaunch.secrets(for: $0)))
            })
        } else {
            self.storage = storage
            self.secretLocations = secrets
        }
        self.log = log
        reload()
    }

    /// Reads the saved list again, e.g. after another Mac changed it.
    public func reload() {
        do {
            records = try storage.load().map(Self.normalized)
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
        let record = Self.normalized(record)
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

    /// Nil also when the Keychain refused or is locked.
    @available(*, deprecated, renamed: "readSecret(_:for:)",
               message: "Use readSecret(_:for:), which reports a Keychain that can’t be read instead of returning nil.")
    public func secret(_ kind: ConnectionSecretKind = .main, for connection: Connection) -> String? {
        try? readSecret(kind, for: connection)
    }

    /// Whether a secret is stored, asking the Keychain for the item’s
    /// attributes only, never its value. Demo connections have none.
    /// - Throws: `SecretStoreError` when the Keychain can’t tell.
    public func hasSecret(_ kind: ConnectionSecretKind = .main, for connection: Connection) throws -> Bool {
        guard !connection.isDemo, let location = secretLocations[kind] else { return false }
        return try location.store.hasSecret(for: location.account(connection))
    }

    /// The secret, nil when none is stored. Demo connections have none.
    /// - Throws: `SecretStoreError` when one may be stored but the Keychain
    ///   can’t read it (refused, locked): show that, not "no secret".
    public func readSecret(_ kind: ConnectionSecretKind = .main, for connection: Connection) throws -> String? {
        guard !connection.isDemo, let location = secretLocations[kind] else { return nil }
        return try location.store.readSecret(for: location.account(connection))
    }

    /// The secret a sign-in needs, e.g. in a token provider’s `secret` closure.
    /// - Throws: `MissingSecretError` when none is stored (or it is empty),
    ///   `SecretStoreError` when the Keychain can’t read it.
    public func requiredSecret(_ kind: ConnectionSecretKind = .main, for connection: Connection) throws -> String {
        guard let secret = try readSecret(kind, for: connection), !secret.isEmpty else {
            throw MissingSecretError(connection: ConnectionMenuText.name(of: connection),
                                     secretName: kind == .protect ? "Jamf Protect client secret" : connection.signIn.secretName ?? "secret")
        }
        return secret
    }

    /// Copies a secret the app kept somewhere else (e.g. under an account
    /// name from before its connections were converted) to this
    /// connection’s own item. The original is left as it is.
    ///
    /// For a one-time conversion: only mark it done when this didn’t throw,
    /// so a Keychain that refused or was locked is tried again at the next
    /// launch instead of leaving the connection without its secret.
    ///
    /// - Returns: false when there is nothing to copy (no secret, or an empty one).
    /// - Throws: `SecretStoreError` when the old secret can’t be read,
    ///   `ConnectionStoreError.keychainRefused` when it can’t be saved.
    @discardableResult
    public func copySecret(from source: any SecretStore, account: String,
                           to kind: ConnectionSecretKind = .main, for connection: Connection) throws -> Bool {
        guard let secret = try source.readSecret(for: account), !secret.isEmpty else { return false }
        do {
            try writeSecret(secret, kind, for: connection)
        } catch {
            throw ConnectionStoreError.keychainRefused(status: (error as? SecretWriteError)?.status)
        }
        return true
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

    /// The record with its server address as JTKit uses it: `https://`
    /// added to an address saved without a scheme (see
    /// `Connection.normalizedServerAddress`). Saved that way at the next save.
    static func normalized(_ record: Record) -> Record {
        var connection = record.connection
        let address = Connection.normalizedServerAddress(connection.serverURL)
        guard address != connection.serverURL, [.jamfPro, .jamfSchool].contains(connection.service) else { return record }
        connection.serverURL = address
        var updated = record
        updated.connection = connection
        return updated
    }

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
            records = ((try? storage.load()) ?? updated).map(Self.normalized)
        } catch {
            log?("[Connections] couldn’t save: \(error)")
            throw ConnectionStoreError.couldNotSave(error.localizedDescription)
        }
    }
}
