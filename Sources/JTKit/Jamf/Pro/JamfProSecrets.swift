import Foundation

// The four secrets Jamf Pro holds for a Mac: the FileVault recovery key,
// the Recovery Lock password, the device lock PIN and the managed local
// administrator (LAPS) password.
//
// Every read is on JTKit’s never-recorded list, so only its method, path,
// status and duration reach the activity log. A failed read throws without
// anything the server wrote, only the status and JTKit’s hints: an app
// records that failure, and the server’s words could carry the secret. Viewing a LAPS password makes Jamf Pro rotate it, so every app
// asks first (`Secret.rotatesWhenViewed`).

extension JamfPro {
    /// A secret Jamf Pro holds for a Mac, with the rules for reading it.
    public enum Secret: String, Sendable, Hashable, CaseIterable {
        case fileVaultRecoveryKey
        case recoveryLockPassword
        case deviceLockPIN
        case localAdminPassword

        public var title: String {
            switch self {
            case .fileVaultRecoveryKey: "FileVault Recovery Key"
            case .recoveryLockPassword: "Recovery Lock Password"
            case .deviceLockPIN: "Device Lock PIN"
            case .localAdminPassword: "Local Administrator Password"
            }
        }

        public var privilege: Privilege {
            switch self {
            case .fileVaultRecoveryKey: .viewDiskEncryptionRecoveryKey
            case .recoveryLockPassword: .viewRecoveryLock
            case .deviceLockPIN: .viewComputerDeviceLockPin
            case .localAdminPassword: .viewLocalAdminPassword
            }
        }

        /// Viewing it makes Jamf Pro replace it (after the instance’s rotation
        /// time), so the app asks before reading it.
        public var rotatesWhenViewed: Bool { self == .localAdminPassword }

        /// The question to ask first, nil when none is needed. `rotation` is
        /// when Jamf Pro rotates it, e.g. "after 1 hour".
        public func confirmation(account: String?, rotation: String) -> (title: String, message: String)? {
            guard rotatesWhenViewed else { return nil }
            return ("Rotation after viewing",
                    "Viewing the password for \(account ?? "this account") will cause Jamf Pro to rotate it \(rotation).")
        }

        /// The Action entry’s words: that it was read, never the secret.
        public func actionSummary(serial: String, account: String? = nil) -> String {
            switch self {
            case .fileVaultRecoveryKey: "Read the FileVault recovery key for \(serial)"
            case .recoveryLockPassword: "Read the Recovery Lock password for \(serial)"
            case .deviceLockPIN: "Read the device lock PIN for \(serial)"
            case .localAdminPassword: "Read the local administrator password for \(account ?? "an account") on \(serial), queuing a rotation"
            }
        }
    }

    public struct FileVaultKey: Hashable, Sendable {
        public var personalRecoveryKey: String
        public var validityStatus: String?
        public var configurationName: String?

        public init(personalRecoveryKey: String, validityStatus: String? = nil, configurationName: String? = nil) {
            self.personalRecoveryKey = personalRecoveryKey
            self.validityStatus = validityStatus
            self.configurationName = configurationName
        }
    }

    /// A managed local administrator account Jamf Pro holds a password for.
    /// A Mac can have the PreStage’s (source MDM), the Jamf binary’s (JMF),
    /// both or neither, under any username.
    public struct LocalAdminAccount: Hashable, Sendable {
        public var username: String
        /// Empty when Jamf Pro didn’t send one.
        public var guid: String
        /// "MDM" or "JMF".
        public var source: String

        public init(username: String, guid: String = "", source: String = "") {
            self.username = username
            self.guid = guid
            self.source = source
        }
    }
}

extension JamfPlatform.Client {
    /// A Mac’s FileVault personal recovery key; nil when Jamf Pro holds none.
    public func fileVaultKey(computerID: String) async throws -> JamfPro.FileVaultKey? {
        struct Answer: Decodable {
            let personalRecoveryKey: String?
            let individualRecoveryKeyValidityStatus: String?
            let diskEncryptionConfigurationName: String?
        }
        guard let answer = try await secret(Answer.self, "pro/v4/computers-inventory/\(JamfPlatform.pathSegment(computerID))/filevault",
                                            .fileVaultRecoveryKey),
              let key = answer.personalRecoveryKey, !key.isEmpty else { return nil }
        return JamfPro.FileVaultKey(personalRecoveryKey: key, validityStatus: answer.individualRecoveryKeyValidityStatus,
                                    configurationName: answer.diskEncryptionConfigurationName)
    }

    /// A Mac’s Recovery Lock password; nil when none is escrowed.
    public func recoveryLockPassword(computerID: String) async throws -> String? {
        struct Answer: Decodable { let recoveryLockPassword: String? }
        return try await secret(Answer.self, "pro/v4/computers-inventory/\(JamfPlatform.pathSegment(computerID))/view-recovery-lock-password",
                                .recoveryLockPassword)?.recoveryLockPassword.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The PIN a Mac was locked with; nil when it was never locked through
    /// Jamf Pro.
    public func deviceLockPIN(computerID: String) async throws -> String? {
        struct Answer: Decodable { let pin: String? }
        return try await secret(Answer.self, "pro/v4/computers-inventory/\(JamfPlatform.pathSegment(computerID))/view-device-lock-pin",
                                .deviceLockPIN)?.pin.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The managed local administrator accounts of a device. Empty when the
    /// privilege is missing (403) or Jamf Pro knows none (404): they are part
    /// of an ordinary lookup, and their absence is no error.
    public func localAdminAccounts(managementID: String) async throws -> [JamfPro.LocalAdminAccount] {
        struct Answer: Decodable {
            let results: [Item]?
            struct Item: Decodable {
                let username: String?
                let guid: String?
                let userSource: String?
            }
        }
        do {
            return try await decoded(Answer.self, HTTPRequest(path: "pro/v2/local-admin-password/\(JamfPlatform.pathSegment(managementID))/accounts"),
                                     privileges: [.viewLocalAdminPassword]).results?.compactMap { item in
                guard let username = item.username, !username.isEmpty else { return nil }
                return JamfPro.LocalAdminAccount(username: username, guid: item.guid ?? "", source: item.userSource ?? "")
            } ?? []
        } catch let error as JamfPlatform.APIError where error.status == 403 || error.status == 404 {
            return []
        }
    }

    /// The current password of a managed local administrator account.
    /// **Viewing it makes Jamf Pro rotate it**; ask first
    /// (`JamfPro.Secret.localAdminPassword.confirmation`). The GUID is used
    /// when known, because Jamf Pro resolves a bare username to the MDM
    /// account when two share it. Nil when Jamf Pro holds no password (it
    /// answers that with HTTP 400 and `NOT_FOUND`).
    public func localAdminPassword(managementID: String, account: JamfPro.LocalAdminAccount) async throws -> String? {
        struct Answer: Decodable { let password: String? }
        let base = "pro/v2/local-admin-password/\(JamfPlatform.pathSegment(managementID))/account/\(JamfPlatform.pathSegment(account.username))"
        let path = account.guid.isEmpty ? base + "/password" : base + "/\(JamfPlatform.pathSegment(account.guid))/password"
        return try await secret(Answer.self, path, .localAdminPassword, absentOnNotFound: true)?.password.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// How long after being viewed a LAPS password is rotated, in seconds;
    /// nil when the setting can’t be read.
    public func localAdminRotationTime() async -> Int? {
        struct Answer: Decodable { let passwordRotationTime: Int? }
        // Jamf Pro’s API description lists this privilege for reading the setting
        return try? await decoded(Answer.self, HTTPRequest(path: "pro/v2/local-admin-password/settings"),
                                  privileges: [.readUserInitiatedEnrollment]).passwordRotationTime
    }

    /// Reads a secret: nil for "none held" (404, or 400 `NOT_FOUND` where
    /// allowed); a failure carries only the status and JTKit’s hints.
    private func secret<T: Decodable>(_ type: T.Type, _ path: String, _ secret: JamfPro.Secret,
                                      absentOnNotFound: Bool = false) async throws -> T? {
        do {
            return try await decoded(type, HTTPRequest(path: path), privileges: [secret.privilege])
        } catch let error as JamfPlatform.APIError {
            if error.status == 404 || (absentOnNotFound && error.status == 400 && error.hasCode(.notFound)) { return nil }
            throw error.withoutServerText
        }
    }
}
