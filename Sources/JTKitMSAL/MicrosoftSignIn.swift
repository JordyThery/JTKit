import Foundation
import JTKit

/// A Microsoft account signed in on this Mac, as MSAL keeps it.
public struct MicrosoftAccount: Sendable, Hashable {
    public let username: String
    /// MSAL's home account ID, saved by the app to find the account again.
    public let identifier: String
    /// The account's home tenant ID, when MSAL knows it.
    public let homeTenantID: String?

    public init(username: String, identifier: String, homeTenantID: String? = nil) {
        self.username = username
        self.identifier = identifier
        self.homeTenantID = homeTenantID
    }
}

/// An access token with what it was granted.
public struct MicrosoftToken: Sendable {
    public let accessToken: String
    /// The permissions granted on this token.
    public let scopes: [String]
    public let account: MicrosoftAccount

    public init(accessToken: String, scopes: [String], account: MicrosoftAccount) {
        self.accessToken = accessToken
        self.scopes = scopes
        self.account = account
    }
}

public enum MicrosoftSignInError: Error, LocalizedError, Sendable, Equatable {
    case invalidClientID
    case missingTenantID
    case noWindow
    case notSignedIn
    case noToken

    public var errorDescription: String? {
        switch self {
        case .invalidClientID:
            "This connection has no valid client ID. Enter the Application (client) ID of the app registration in that tenant."
        case .missingTenantID:
            "This connection has no tenant ID."
        case .noWindow:
            "No window available to show Microsoft’s sign-in."
        case .notSignedIn:
            "Not signed in to this tenant."
        case .noToken:
            "Microsoft’s sign-in returned no token."
        }
    }
}

/// What the sign-in needs from MSAL; the real one is `MSALBackend`, tests
/// use a fake.
@MainActor
protocol SignInBackend: AnyObject {
    func accounts() -> [MicrosoftAccount]
    func account(identifier: String) -> MicrosoftAccount?
    func silentToken(scopes: [String], account: MicrosoftAccount, authority: URL, forceRefresh: Bool) async throws -> MicrosoftToken
    /// Microsoft's sign-in window: for `account` when given (no account
    /// picker), else with the account picker.
    func interactiveToken(scopes: [String], account: MicrosoftAccount?, authority: URL) async throws -> MicrosoftToken
    func remove(_ account: MicrosoftAccount)
    /// MSAL needs the sign-in window (e.g. consent for a new permission, or
    /// an expired sign-in).
    func needsInteraction(_ error: any Error) -> Bool
}

/// Microsoft's interactive sign-in (MSAL) for one app registration (client
/// ID), in any of its tenants. MSAL keeps the signed-in accounts and tokens
/// in its own Keychain cache, so they survive relaunches.
///
/// - Silent token first; Microsoft's sign-in window only when MSAL needs it.
/// - One window at a time. Requests that need the window for the same
///   tenant, account and permissions share it; a request for other
///   permissions waits until the window closes, then asks again.
/// - After an expired sign-in the window is for the saved account.
/// - Permissions are asked for step by step: each request names its own.
/// - `MicrosoftTokenSource` hands its tokens to `Graph.Client`, the same way
///   as the app sign-in (`EntraTokenProvider`).
@MainActor
public final class MicrosoftSignIn {
    /// The MSAL version JTKit pins; its licence notice is `Acknowledgement.msal`.
    public nonisolated static let msalVersion = "2.16.0"
    public nonisolated static let authorityBase = "https://login.microsoftonline.com"

    /// MSAL's macOS redirect address: `msauth.<bundle ID>://auth`.
    public nonisolated static var defaultRedirectURI: String {
        "msauth.\(Bundle.main.bundleIdentifier ?? "")://auth"
    }

    public nonisolated let clientID: String
    private let backend: any SignInBackend

    /// Which window is open: requests with the same key share it.
    private struct WindowKey: Hashable {
        let tenant: String
        let account: String?
        let scopes: Set<String>
    }

    private var window: (key: WindowKey, id: Int, task: Task<MicrosoftToken, any Error>)?
    private var nextWindowID = 0

    /// How many times the window was shown; for tests and diagnostics.
    public private(set) var windowCount = 0

    /// - Throws: `MicrosoftSignInError.invalidClientID` when the client ID
    ///   isn't a UUID; MSAL's error when it can't be set up.
    public convenience init(clientID: String, redirectURI: String = MicrosoftSignIn.defaultRedirectURI) throws {
        let clientID = try Self.validatedClientID(clientID)
        try self.init(clientID: clientID, backend: MSALBackend(clientID: clientID, redirectURI: redirectURI))
    }

    init(clientID: String, backend: any SignInBackend) throws {
        self.clientID = try Self.validatedClientID(clientID)
        self.backend = backend
    }

    // MARK: - Rules

    /// The client ID trimmed; it must be a UUID.
    public nonisolated static func validatedClientID(_ clientID: String) throws -> String {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: clientID) != nil else { throw MicrosoftSignInError.invalidClientID }
        return clientID
    }

    /// The sign-in address for a tenant ID or verified domain.
    public nonisolated static func authorityURL(tenantID: String) throws -> URL {
        let tenantID = tenantID.trimmingCharacters(in: .whitespaces)
        guard !tenantID.isEmpty, let url = URL(string: "\(authorityBase)/\(tenantID)") else {
            throw MicrosoftSignInError.missingTenantID
        }
        return url
    }

    /// The cached account for a tenant when its saved identifier isn't
    /// found: the one whose home tenant matches (ignoring case), else the
    /// only one (an app registration usually lives in one tenant, and a
    /// domain doesn't match a tenant ID).
    public nonisolated static func cachedAccount<Account>(in accounts: [Account], tenantID: String,
                                                          homeTenant: (Account) -> String?) -> Account? {
        let tenantID = tenantID.trimmingCharacters(in: .whitespaces).lowercased()
        return accounts.first { homeTenant($0)?.lowercased() == tenantID }
            ?? (accounts.count == 1 ? accounts[0] : nil)
    }

    // MARK: - Accounts

    /// The signed-in account at launch: the saved one, else by tenant.
    public func savedAccount(identifier: String?, tenantID: String) -> MicrosoftAccount? {
        if let identifier, let account = backend.account(identifier: identifier) {
            return account
        }
        return Self.cachedAccount(in: backend.accounts(), tenantID: tenantID) { $0.homeTenantID }
    }

    /// The account if MSAL still has it.
    public func account(identifier: String) -> MicrosoftAccount? {
        backend.account(identifier: identifier)
    }

    /// Shows Microsoft's sign-in window with the account picker.
    public func signIn(tenantID: String, scopes: [String]) async throws -> MicrosoftToken {
        let authority = try Self.authorityURL(tenantID: tenantID)
        // never two windows: wait for one that's open
        while let open = window {
            _ = try? await open.task.value
        }
        return try await showWindow(WindowKey(tenant: tenantID.lowercased(), account: nil, scopes: Self.scopeSet(scopes))) {
            try await self.backend.interactiveToken(scopes: scopes, account: nil, authority: authority)
        }
    }

    /// A token for the account: silent first, Microsoft's window when MSAL
    /// needs it.
    /// - Parameter forceRefresh: a new token even if the cached one is still
    ///   valid, e.g. after Graph answered 401.
    public func token(for account: MicrosoftAccount, tenantID: String, scopes: [String],
                      forceRefresh: Bool = false) async throws -> MicrosoftToken {
        let authority = try Self.authorityURL(tenantID: tenantID)
        let key = WindowKey(tenant: tenantID.lowercased(), account: account.identifier, scopes: Self.scopeSet(scopes))
        while true {
            do {
                return try await backend.silentToken(scopes: scopes, account: account, authority: authority,
                                                     forceRefresh: forceRefresh)
            } catch where backend.needsInteraction(error) {
                // the window is needed, below
            }
            if let open = window {
                if open.key == key {
                    return try await open.task.value
                }
                // another request's window (other permissions): wait until
                // it closes, then ask again: its consent may cover this one
                _ = try? await open.task.value
                continue
            }
            return try await showWindow(key) {
                try await self.backend.interactiveToken(scopes: scopes, account: account, authority: authority)
            }
        }
    }

    public func signOut(_ account: MicrosoftAccount) {
        backend.remove(account)
    }

    // MARK: - Private

    private func showWindow(_ key: WindowKey,
                            _ show: @escaping @MainActor () async throws -> MicrosoftToken) async throws -> MicrosoftToken {
        nextWindowID += 1
        let id = nextWindowID
        windowCount += 1
        // the window is marked closed inside the task, before anyone waiting
        // on it resumes: a waiter that resumed first would still see it open,
        // wait on it again (it's finished) and loop without end
        let task = Task { @MainActor in
            defer { if self.window?.id == id { self.window = nil } }
            return try await show()
        }
        window = (key, id, task)
        return try await task.value
    }

    private static func scopeSet(_ scopes: [String]) -> Set<String> {
        Set(scopes.map { $0.lowercased() })
    }
}

/// Hands out the interactive sign-in's tokens to `Graph.Client`. After
/// `forgetToken()` (Graph answered 401) the next token is a fresh one.
public actor MicrosoftTokenSource: BearerTokenSource {
    private let fetch: @Sendable (_ forceRefresh: Bool) async throws -> String
    private var refreshNext = false

    /// - Parameter fetch: gets a token, e.g. through `MicrosoftSignIn.token(for:…)`.
    public init(_ fetch: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        self.fetch = fetch
    }

    public func token() async throws -> String {
        let force = refreshNext
        refreshNext = false
        return try await fetch(force)
    }

    public func forgetToken() {
        refreshNext = true
    }
}
