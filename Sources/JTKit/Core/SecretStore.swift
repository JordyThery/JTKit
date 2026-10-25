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
}

/// Generic-password items in the login (file-based) keychain, under one
/// service name.
///
/// Every app passes in the service name, accessibility and label it has always
/// used, so existing items keep being found (see "Preserve stored data" in
/// CLAUDE.md). Accessibility and label are set when an item is created; an
/// update only replaces the secret, as every app's own copy did.
///
/// Not the data-protection keychain: on macOS that needs an
/// application-identifier entitlement, which only a provisioning profile
/// provides. A Developer ID build has none, so every write fails with
/// errSecMissingEntitlement (-34018) while Xcode-run builds work (found in
/// JamfMigrator 1.0, 2026-10-05).
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
    ///   - service: the app's Keychain service name, e.g. `"JamfMigrator-tenant"`.
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
        if let value = read(baseQuery(account: account), account: account) {
            return value
        }
        guard movesItemsFromDataProtectionKeychain else { return nil }
        let legacy = baseQuery(account: account, dataProtection: true)
        guard let value = read(legacy, account: account, logsMisses: false) else { return nil }
        if setSecret(value, for: account) {
            SecItemDelete(legacy as CFDictionary)
        }
        return value
    }

    @discardableResult
    public func setSecret(_ secret: String?, for account: String) -> Bool {
        guard let secret else {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                log?("[Keychain] delete for \(account) failed: \(status)")
            }
            return status == errSecSuccess || status == errSecItemNotFound
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
        }
        return status == errSecSuccess
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

    private func read(_ base: [String: Any], account: String, logsMisses: Bool = true) -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if logsMisses && status != errSecItemNotFound {
                log?("[Keychain] lookup for \(account) failed: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
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
