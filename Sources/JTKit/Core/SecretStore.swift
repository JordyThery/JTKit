import Foundation
import Security

/// Stores one secret string per account: a client secret, password, API key or
/// private key. Backed by the Keychain in the apps (`KeychainSecretStore`) and
/// by a dictionary in tests (`InMemorySecretStore` in JTKitTestSupport).
public protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    /// Passing nil deletes the entry. Returns false when the write failed.
    @discardableResult
    func setSecret(_ secret: String?, for account: String) -> Bool
    /// Like `setSecret`, but a failed write throws.
    /// - Throws: `SecretWriteError`, with the Keychain’s error code where the store has one.
    func writeSecret(_ secret: String?, for account: String) throws
    /// Whether a secret is stored, without reading it where the store can.
    /// - Throws: `SecretStoreError` when the store can’t tell.
    func hasSecret(for account: String) throws -> Bool
    /// The secret, or nil when none is stored.
    /// - Throws: `SecretStoreError` when one may be stored but can’t be read.
    func readSecret(for account: String) throws -> String?
}

extension SecretStore {
    /// For stores that can’t tell a failure from absence: reads the secret.
    public func hasSecret(for account: String) throws -> Bool {
        !(secret(for: account) ?? "").isEmpty
    }

    public func readSecret(for account: String) throws -> String? {
        secret(for: account)
    }

    /// For stores that only say whether a write worked: no error code.
    public func writeSecret(_ secret: String?, for account: String) throws {
        guard setSecret(secret, for: account) else { throw SecretWriteError(status: nil) }
    }
}

/// The Keychain couldn’t answer, which isn’t the same as "no secret".
public nonisolated struct SecretStoreError: LocalizedError, Equatable, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        "The Keychain couldn’t be read (error \(status))."
    }
}

/// The Keychain refused to save or delete a secret.
public nonisolated struct SecretWriteError: LocalizedError, Equatable, Sendable {
    /// The Keychain’s error code; nil from a store that doesn’t give one.
    public let status: OSStatus?

    public init(status: OSStatus?) {
        self.status = status
    }

    public var errorDescription: String? {
        status.map { "The Keychain refused to save the secret (error \($0))." } ?? "The Keychain refused to save the secret."
    }
}

/// Generic-password items in the login (file-based) keychain, under one
/// service name.
///
/// Every app passes in the service name, accessibility and label it has always
/// used, so existing items keep being found (see "Preserve stored data" in
/// CLAUDE.md). Accessibility and label are set when an item is created; an
/// update only replaces the secret, as every app’s own copy did.
///
/// Not the data-protection keychain: on macOS that needs an
/// application-identifier entitlement, which only a provisioning profile
/// provides. A Developer ID build has none, so every write fails with
/// errSecMissingEntitlement (-34018) while Xcode-run builds work.
public nonisolated struct KeychainSecretStore: SecretStore {

    /// When the item can be read. Keep what the app used before.
    public enum Accessibility: Sendable {
        /// No attribute set: the system default (when unlocked).
        case systemDefault
        case afterFirstUnlock
        case whenUnlocked
    }

    public let service: String
    public let accessibility: Accessibility
    public let label: String?
    public let movesItemsFromDataProtectionKeychain: Bool
    private let log: (@Sendable (String) -> Void)?

    /// - Parameters:
    ///   - service: the app’s Keychain service name, e.g. `"JamfMigrator-tenant"`.
    ///   - accessibility: set on new items only.
    ///   - label: the name Keychain Access shows, set on new items only.
    ///   - movesItemsFromDataProtectionKeychain: when a read misses, look in the
    ///     data-protection keychain and move a found item to the login keychain
    ///     (JamfMigrator builds before 1.0.1 wrote there).
    ///   - log: receives failures, never secrets.
    public init(
        service: String,
        accessibility: Accessibility = .systemDefault,
        label: String? = nil,
        movesItemsFromDataProtectionKeychain: Bool = false,
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.service = service
        self.accessibility = accessibility
        self.label = label
        self.movesItemsFromDataProtectionKeychain = movesItemsFromDataProtectionKeychain
        self.log = log
    }

    public func secret(for account: String) -> String? {
        try? readSecret(for: account)
    }

    public func readSecret(for account: String) throws -> String? {
        if let value = try read(baseQuery(account: account), account: account) {
            return value
        }
        guard movesItemsFromDataProtectionKeychain else { return nil }
        let legacy = baseQuery(account: account, dataProtection: true)
        guard let value = try? read(legacy, account: account, logsMisses: false) else { return nil }
        if setSecret(value, for: account) {
            SecItemDelete(legacy as CFDictionary)
        }
        return value
    }

    /// Asks for the item’s attributes only, so the secret itself is never
    /// read (nor its access asked for) just to see whether there is one.
    public func hasSecret(for account: String) throws -> Bool {
        if try exists(baseQuery(account: account), account: account) { return true }
        guard movesItemsFromDataProtectionKeychain else { return false }
        return (try? exists(baseQuery(account: account, dataProtection: true), account: account)) ?? false
    }

    @discardableResult
    public func setSecret(_ secret: String?, for account: String) -> Bool {
        (try? writeSecret(secret, for: account)) != nil
    }

    public func writeSecret(_ secret: String?, for account: String) throws {
        guard let secret else {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                log?("[Keychain] delete for \(account) failed: \(status)")
                throw SecretWriteError(status: status)
            }
            return
        }
        let data = Data(secret.utf8)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        if let accessible = accessibility.attribute {
            attributes[kSecAttrAccessible as String] = accessible
        }
        if let label {
            attributes[kSecAttrLabel as String] = label
        }

        var status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(baseQuery(account: account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        }
        if status != errSecSuccess {
            log?("[Keychain] save for \(account) failed: \(status)")
            throw SecretWriteError(status: status)
        }
    }

    /// Deletes every item of this service whose account starts with `prefix`,
    /// e.g. all of one tenant’s block settings (`<UUID>.`). An empty prefix
    /// deletes nothing. Returns false when a lookup or a delete failed.
    @discardableResult
    public func deleteSecrets(withAccountPrefix prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return true }
        guard status == errSecSuccess, let found = items as? [[String: Any]] else {
            log?("[Keychain] lookup for prefix \(prefix) failed: \(status)")
            return false
        }
        var succeeded = true
        for attributes in found {
            guard let account = attributes[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { continue }
            succeeded = setSecret(nil, for: account) && succeeded
        }
        return succeeded
    }

    private func baseQuery(account: String, dataProtection: Bool = false) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// Nil when there is no item; throws when the lookup failed.
    private func read(_ base: [String: Any], account: String, logsMisses: Bool = true) throws -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            if logsMisses {
                log?("[Keychain] lookup for \(account) failed: \(status)")
            }
            throw SecretStoreError(status: status == errSecSuccess ? errSecDecode : status)
        }
        return String(data: data, encoding: .utf8)
    }

    private func exists(_ base: [String: Any], account: String) throws -> Bool {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default:
            log?("[Keychain] lookup for \(account) failed: \(status)")
            throw SecretStoreError(status: status)
        }
    }
}

private extension KeychainSecretStore.Accessibility {
    nonisolated var attribute: CFString? {
        switch self {
        case .systemDefault: nil
        case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlock
        case .whenUnlocked: kSecAttrAccessibleWhenUnlocked
        }
    }
}
