import Foundation

/// A service an app connects to. Each app passes in the ones it supports.
public nonisolated enum ConnectionService: String, Codable, CaseIterable, Identifiable, Sendable {
    case jamfPlatform
    case jamfPro
    case jamfSchool
    case intune
    case appleBusinessManager
    case appleSchoolManager

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .jamfPlatform: "Jamf Platform API"
        case .jamfPro: "Jamf Pro"
        case .jamfSchool: "Jamf School"
        case .intune: "Intune"
        case .appleBusinessManager: "Apple Business Manager"
        case .appleSchoolManager: "Apple School Manager"
        }
    }

    public var systemImage: String {
        switch self {
        case .jamfPlatform: "cloud"
        case .jamfPro: "server.rack"
        case .jamfSchool: "graduationcap"
        case .intune: "building.columns"
        case .appleBusinessManager: "briefcase"
        case .appleSchoolManager: "books.vertical"
        }
    }

    /// The sign-in methods this service accepts, the usual one first.
    public var signInMethods: [SignInMethod] {
        switch self {
        case .jamfPlatform: [.apiClient]
        case .jamfPro: [.apiClient, .usernamePassword]
        case .jamfSchool: [.schoolAPIKey]
        case .intune: [.microsoftInteractive, .entraClientSecret]
        case .appleBusinessManager, .appleSchoolManager: [.applePrivateKey]
        }
    }
}

/// How a connection signs in.
public nonisolated enum SignInMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    /// OAuth client credentials: client ID and client secret.
    case apiClient
    case usernamePassword
    /// Jamf School: Network ID and API key.
    case schoolAPIKey
    /// Entra app registration with a client secret (app-only).
    case entraClientSecret
    /// Interactive Microsoft sign-in. No secret is stored; the app signs in.
    case microsoftInteractive
    /// Apple Business/School Manager: client ID, key ID and a private key.
    case applePrivateKey

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .apiClient: "API client"
        case .usernamePassword: "Username and password"
        case .schoolAPIKey: "API key"
        case .entraClientSecret: "App registration with client secret"
        case .microsoftInteractive: "Microsoft sign-in"
        case .applePrivateKey: "Private key"
        }
    }

    /// The name of the secret this method stores, or nil when it stores none.
    public var secretName: String? {
        switch self {
        case .apiClient, .entraClientSecret: "Client secret"
        case .usernamePassword: "Password"
        case .schoolAPIKey: "API key"
        case .applePrivateKey: "Private key"
        case .microsoftInteractive: nil
        }
    }
}

/// The region of a Jamf Platform API gateway.
public nonisolated enum JamfRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case us, eu, apac

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .us: "United States"
        case .eu: "Europe"
        case .apac: "Asia-Pacific"
        }
    }

    public var gatewayURL: URL {
        URL(string: "https://\(rawValue).api.jamfcloud.com")!
    }
}

/// The Jamf Protect add-on of a Jamf connection. Its secret is stored as
/// `ConnectionSecretKind.protect`.
public nonisolated struct JamfProtectSettings: Codable, Hashable, Sendable {
    public var url: String
    public var clientID: String

    public init(url: String = "", clientID: String = "") {
        self.url = url
        self.clientID = clientID
    }
}

/// Which secret of a connection: the one its sign-in method needs, or the
/// Jamf Protect add-on’s.
public nonisolated enum ConnectionSecretKind: String, CaseIterable, Sendable {
    case main
    case protect
}

/// Optional fields an app can show in the editor. Fields every service needs
/// are always shown.
public nonisolated enum ConnectionOptionalField: Hashable, Sendable {
    /// Jamf Platform API: a different gateway host, e.g. a staging host.
    case hostOverride
    /// Jamf Platform API: the Jamf Pro web address, for links.
    case jamfProWebURL
    /// Jamf Platform API and Jamf Pro: the Jamf Protect add-on.
    case jamfProtect
}

/// Shared fields an app can show read-only in the editor, e.g. what was fixed
/// when the connection was made. A read-only field shows its value as text.
public nonisolated enum ConnectionField: Hashable, Sendable {
    case signIn
    case region
    case serverURL
    case environmentID
    case clientID
    case username
}

/// One saved connection: what the shared connections list and editor show and
/// change. Secrets are never part of it; they live in a `SecretStore`.
///
/// Apps keep their own record type (with their own field names and their own
/// settings) and expose this through `ConnectionRecord`.
public nonisolated struct Connection: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var service: ConnectionService
    public var signIn: SignInMethod

    /// Jamf Pro and Jamf School: the server address.
    public var serverURL: String
    /// Jamf Platform API.
    public var region: JamfRegion
    public var environmentID: String
    public var hostOverride: String
    public var jamfProWebURL: String

    /// API client, Entra app or Apple API key ID; Jamf School Network ID.
    public var clientID: String
    public var username: String
    /// Intune: the Entra tenant ID or verified domain.
    public var tenantID: String
    /// Apple Business/School Manager: the key ID.
    public var keyID: String

    public var protect: JamfProtectSettings?

    public init(
        id: UUID = UUID(),
        name: String,
        service: ConnectionService,
        signIn: SignInMethod? = nil,
        serverURL: String = "",
        region: JamfRegion = .us,
        environmentID: String = "",
        hostOverride: String = "",
        jamfProWebURL: String = "",
        clientID: String = "",
        username: String = "",
        tenantID: String = "",
        keyID: String = "",
        protect: JamfProtectSettings? = nil
    ) {
        self.id = id
        self.name = name
        self.service = service
        self.signIn = signIn ?? service.signInMethods[0]
        self.serverURL = serverURL
        self.region = region
        self.environmentID = environmentID
        self.hostOverride = hostOverride
        self.jamfProWebURL = jamfProWebURL
        self.clientID = clientID
        self.username = username
        self.tenantID = tenantID
        self.keyID = keyID
        self.protect = protect
    }

    /// The second line of a row in the list: the service and where it points.
    public var summary: String {
        let place: String
        switch service {
        case .jamfPlatform: place = trimmed(hostOverride).isEmpty ? region.rawValue.uppercased() : trimmed(hostOverride)
        case .jamfPro, .jamfSchool: place = URL(string: trimmed(serverURL))?.host() ?? ""
        case .intune: place = trimmed(tenantID)
        case .appleBusinessManager, .appleSchoolManager: place = ""
        }
        return place.isEmpty ? service.displayName : "\(service.displayName) · \(place)"
    }

    /// Problems with values that were typed in, in plain language. Empty
    /// fields count only where the service can’t work without them.
    public var issues: [String] {
        var issues = [String]()
        switch service {
        case .jamfPlatform:
            let environment = trimmed(environmentID)
            if !environment.isEmpty && UUID(uuidString: environment) == nil {
                issues.append(JamfPlatform.APIError.environmentIDNotUUID)
            }
        case .jamfPro, .jamfSchool:
            if !Self.isWebAddress(trimmed(serverURL)) {
                issues.append("Enter the server URL, starting with https://.")
            }
        case .intune:
            let client = trimmed(clientID)
            if !client.isEmpty && UUID(uuidString: client) == nil {
                issues.append("The client ID isn’t a UUID. Copy the Application (client) ID from Entra.")
            }
        case .appleBusinessManager, .appleSchoolManager:
            break
        }
        if let protect, !trimmed(protect.url).isEmpty && !Self.isWebAddress(trimmed(protect.url)) {
            issues.append("Enter the Protect URL, starting with https://.")
        }
        return issues
    }

    static func isWebAddress(_ string: String) -> Bool {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https" else { return false }
        return !(url.host() ?? "").isEmpty
    }

    private func trimmed(_ string: String) -> String {
        string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// An app’s own saved record of a connection (JamfMigrator’s `Tenant`,
/// AppSettings2Blueprint’s `ConnectionProfile`). The app’s type keeps its own
/// field names and its own settings, so files and keys stay as they are;
/// `connection` maps its connection fields to and from the shared ones.
///
/// Setting `connection` must change only the connection fields the app
/// stores, and setting back the value just read must leave the record
/// unchanged.
public protocol ConnectionRecord: Identifiable, Equatable, Sendable where ID == UUID {
    var connection: Connection { get set }

    /// A symbol shown after the name in the list, e.g. a lock for a protected
    /// tenant, and its help text.
    var listBadge: (systemImage: String, help: String)? { get }
}

extension ConnectionRecord {
    public var listBadge: (systemImage: String, help: String)? { nil }
}
