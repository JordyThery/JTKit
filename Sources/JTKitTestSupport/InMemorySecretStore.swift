import Foundation
import JTKit

/// A `SecretStore` that keeps secrets in memory, for tests and previews.
/// Set `refusesWrites` to act like a Keychain that refuses to save, and
/// `refusesReads` like one that refuses to read (or is locked).
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets = [String: String]()
    private var refuses = false
    private var refusesToRead = false

    public init(_ secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    public var refusesWrites: Bool {
        get { lock.withLock { refuses } }
        set { lock.withLock { refuses = newValue } }
    }

    /// Reads (and existence checks) throw `SecretStoreError` with
    /// `errSecInteractionNotAllowed` (-25308), as a locked Keychain does.
    public var refusesReads: Bool {
        get { lock.withLock { refusesToRead } }
        set { lock.withLock { refusesToRead = newValue } }
    }

    /// Every stored account and its secret.
    public var all: [String: String] {
        lock.withLock { secrets }
    }

    public func secret(for account: String) -> String? {
        try? readSecret(for: account)
    }

    public func readSecret(for account: String) throws -> String? {
        try lock.withLock {
            if refusesToRead { throw SecretStoreError(status: -25308) }
            return secrets[account]
        }
    }

    public func hasSecret(for account: String) throws -> Bool {
        !(try readSecret(for: account) ?? "").isEmpty
    }

    /// Like `KeychainSecretStore.deleteSecrets(withAccountPrefix:)`.
    @discardableResult
    public func deleteSecrets(withAccountPrefix prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        return lock.withLock {
            guard !refuses else { return false }
            secrets = secrets.filter { !$0.key.hasPrefix(prefix) }
            return true
        }
    }

    @discardableResult
    public func setSecret(_ secret: String?, for account: String) -> Bool {
        lock.withLock {
            guard !refuses else { return false }
            secrets[account] = secret
            return true
        }
    }
}
