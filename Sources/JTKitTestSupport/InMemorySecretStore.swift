import Foundation
import JTKit

/// A `SecretStore` that keeps secrets in memory, for tests and previews.
/// Set `refusesWrites` to act like a Keychain that refuses to save.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets = [String: String]()
    private var refuses = false

    public init(_ secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    public var refusesWrites: Bool {
        get { lock.withLock { refuses } }
        set { lock.withLock { refuses = newValue } }
    }

    /// Every stored account and its secret.
    public var all: [String: String] {
        lock.withLock { secrets }
    }

    public func secret(for account: String) -> String? {
        lock.withLock { secrets[account] }
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
