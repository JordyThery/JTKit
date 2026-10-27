import Foundation

/// The tenants live checks may reach (ROADMAP step 11), read from a local
/// file outside every git work tree, readable by its owner only. Hostnames,
/// non-secret IDs and access levels only; never secrets. Deny by default:
/// anything not on it is refused before it's sent.
public nonisolated struct AllowList: Codable, Sendable, Equatable {
    public var version: Int
    public var tenants: [Entry]

    public init(version: Int = 1, tenants: [Entry]) {
        self.version = version
        self.tenants = tenants
    }

    /// `~/Library/Application Support/JTKit Release Check/allowlist.json`.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/JTKit Release Check/allowlist.json")
    }

    public nonisolated enum Service: String, Codable, Sendable {
        case jamfPlatform, jamfPro, jamfSchool, intune, appleBusinessManager, appleSchoolManager
    }

    public nonisolated enum Access: String, Codable, Sendable {
        /// Creates, updates and deletes only prefixed test objects; the
        /// prefix sweep runs here.
        case full
        /// Creates prefixed test objects and removes them; only the ledger
        /// is cleaned up, no sweep.
        case createAndRemove
        /// GET only, plus sign-in and sign-out.
        case readOnly
    }

    public nonisolated struct Entry: Codable, Sendable, Equatable {
        /// What tests and scripts call it, e.g. `"jamf-test-a"`; never a tenant name.
        public var role: String
        public var service: Service
        /// Jamf Pro and Jamf School: the server's hostname.
        public var host: String?
        /// Other names of the same server, e.g. its jamfcloud.com name.
        public var aliases: [String]?
        /// Jamf Platform: `"us"`, `"eu"`, `"apac"`.
        public var region: String?
        public var environmentID: String?
        public var entraTenantID: String?
        /// Apple Business / School Manager: the API account's client ID.
        public var clientID: String?
        public var access: Access
        public var production: Bool
        /// Where the release check reads this tenant's credentials when the
        /// app has no saved connection for it (a Keychain service name).
        public var keychainService: String?

        public init(role: String, service: Service, host: String? = nil, aliases: [String]? = nil,
                    region: String? = nil, environmentID: String? = nil, entraTenantID: String? = nil,
                    clientID: String? = nil, access: Access, production: Bool = false, keychainService: String? = nil) {
            self.role = role
            self.service = service
            self.host = host
            self.aliases = aliases
            self.region = region
            self.environmentID = environmentID
            self.entraTenantID = entraTenantID
            self.clientID = clientID
            self.access = access
            self.production = production
            self.keychainService = keychainService
        }

        /// Every hostname of a Jamf Pro or Jamf School entry, lowercased.
        var hosts: [String] {
            ([host] + (aliases ?? []).map(Optional.some)).compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
        }
    }

    public nonisolated enum LoadError: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case readableByOthers(String)
        case insideGitWorkTree(String)
        case unreadable(String)
        case unsupportedVersion(Int)
        case incomplete(role: String, reason: String)

        public var description: String {
            switch self {
            case .missing(let path): "The allow-list doesn't exist: \(path)"
            case .readableByOthers(let path): "The allow-list must be readable by you only (chmod 600): \(path)"
            case .insideGitWorkTree(let path): "The allow-list lies inside a git work tree; move it out: \(path)"
            case .unreadable(let reason): "The allow-list can't be read: \(reason)"
            case .unsupportedVersion(let version): "The allow-list's version \(version) isn't supported"
            case .incomplete(let role, let reason): "Allow-list entry \(role): \(reason)"
            }
        }
    }

    /// Reads and checks the allow-list: it exists, only its owner can read or
    /// write it, it lies outside every git work tree, and each entry names
    /// what identifies its tenant.
    public static func load(from url: URL = defaultURL) throws -> AllowList {
        let path = url.path
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { throw LoadError.missing(path) }
        let attributes = try fileManager.attributesOfItem(atPath: path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard mode & 0o077 == 0 else { throw LoadError.readableByOthers(path) }
        if isInsideGitWorkTree(url) { throw LoadError.insideGitWorkTree(path) }
        let list: AllowList
        do {
            list = try JSONDecoder().decode(AllowList.self, from: Data(contentsOf: url))
        } catch {
            throw LoadError.unreadable(String(describing: error))
        }
        guard list.version == 1 else { throw LoadError.unsupportedVersion(list.version) }
        for entry in list.tenants { try entry.validate() }
        return list
    }

    /// Whether a folder above `url` holds `.git`.
    static func isInsideGitWorkTree(_ url: URL) -> Bool {
        var folder = url.deletingLastPathComponent().standardizedFileURL
        while folder.path != "/" {
            if FileManager.default.fileExists(atPath: folder.appending(path: ".git").path) { return true }
            folder.deleteLastPathComponent()
        }
        return false
    }

    /// The entries of these roles (every entry when `roles` is nil).
    public func entries(roles: Set<String>?) -> [Entry] {
        tenants.filter { roles?.contains($0.role) ?? true }
    }
}

extension AllowList.Entry {
    func validate() throws {
        func require(_ value: String?, _ what: String) throws {
            guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw AllowList.LoadError.incomplete(role: role, reason: "\(what) is missing")
            }
        }
        switch service {
        case .jamfPlatform:
            try require(region, "region")
            try require(environmentID, "environmentID")
        case .jamfPro, .jamfSchool:
            try require(host, "host")
        case .intune:
            try require(entraTenantID, "entraTenantID")
        case .appleBusinessManager, .appleSchoolManager:
            try require(clientID, "clientID")
        }
        if production && access != .readOnly {
            throw AllowList.LoadError.incomplete(role: role, reason: "a production tenant must be read only")
        }
        if (service == .appleBusinessManager || service == .appleSchoolManager) && access != .readOnly {
            throw AllowList.LoadError.incomplete(role: role, reason: "Apple Business / School Manager is read only")
        }
    }
}
