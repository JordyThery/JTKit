import Foundation

/// The tenants live checks may reach, read from a local
/// file outside every git work tree, readable by its owner only. Hostnames,
/// non-secret IDs and access levels only; never secrets. Deny by default:
/// anything not on it is refused before it’s sent.
///
/// Version 2 (1.1.0) adds, all optional, so a version 1 file reads as before:
/// `productionReads` (production tenants are read without
/// `--include-production`), and per entry `customer` (an entry marked so is
/// refused: a customer’s tenant is never on the list) and `testDevices` (the
/// devices commands may go to). Access may also be written `disposable` (=
/// `full`) and `read` (= `readOnly`), the names of the 1.1.0 plan.
public nonisolated struct AllowList: Codable, Sendable, Equatable {
    public var version: Int
    public var tenants: [Entry]
    /// Production tenants are read (GET only) without `--include-production`.
    /// Nil or false: as in version 1, only with it.
    public var productionReads: Bool?

    public init(version: Int = 1, tenants: [Entry], productionReads: Bool? = nil) {
        self.version = version
        self.tenants = tenants
        self.productionReads = productionReads
    }

    /// The versions this JTKit reads.
    public static let supportedVersions: Set<Int> = [1, 2]

    /// `~/Library/Application Support/JTKit Release Check/allowlist.json`.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/JTKit Release Check/allowlist.json")
    }

    public nonisolated enum Service: String, Codable, Sendable {
        case jamfPlatform, jamfPro, jamfSchool, intune, appleBusinessManager, appleSchoolManager
    }

    public nonisolated enum Access: String, Codable, Sendable {
        /// "disposable" in the 1.1.0 plan (jamf-test-a and -b): creates,
        /// updates and deletes only prefixed test objects; the prefix sweep
        /// runs here.
        case full
        /// Creates prefixed test objects and removes them; only the ledger
        /// is cleaned up, no sweep.
        case createAndRemove
        /// "read" in the 1.1.0 plan: GET only, plus sign-in and sign-out,
        /// and commands to the entry’s `testDevices`.
        case readOnly

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "full", "disposable": self = .full
            case "createAndRemove": self = .createAndRemove
            case "readOnly", "read": self = .readOnly
            default:
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Unknown access “\(raw)”"))
            }
        }
    }

    /// A device commands may be sent to: Blank Push, check-in and Update
    /// Inventory at once (at most 3 devices a run); restart, renew and every
    /// other interruptive or destructive command only after the serial
    /// prompt. The serial is all the list holds; the IDs are learned from
    /// the tenant’s own answers during the run.
    public nonisolated struct TestDevice: Codable, Sendable, Equatable, Hashable {
        public let serial: String
        /// What the prompt shows when the tenant’s answer has no name.
        public let name: String?

        public init(serial: String, name: String? = nil) {
            self.serial = serial
            self.name = name
        }
    }

    public nonisolated struct Entry: Codable, Sendable, Equatable {
        /// What tests and scripts call it, e.g. `"jamf-test-a"`; never a tenant name.
        public let role: String
        public let service: Service
        /// Jamf Pro and Jamf School: the server’s hostname.
        public let host: String?
        /// Other names of the same server, e.g. its jamfcloud.com name.
        public let aliases: [String]?
        /// Jamf Platform: `"us"`, `"eu"`, `"apac"`.
        public let region: String?
        public let environmentID: String?
        public let entraTenantID: String?
        /// Apple Business or Apple School Manager: the API account’s client ID.
        public let clientID: String?
        public let access: Access
        public let production: Bool
        /// Where the release check reads this tenant’s credentials when the
        /// app has no saved connection for it (a Keychain service name).
        public let keychainService: String?
        /// A customer’s tenant: such an entry is refused when the list is read.
        public let customer: Bool?
        /// The devices commands may be sent to (see `TestDevice`); none by default.
        public let testDevices: [TestDevice]?

        public init(role: String, service: Service, host: String? = nil, aliases: [String]? = nil,
                    region: String? = nil, environmentID: String? = nil, entraTenantID: String? = nil,
                    clientID: String? = nil, access: Access, production: Bool = false, keychainService: String? = nil,
                    customer: Bool? = nil, testDevices: [TestDevice]? = nil) {
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
            self.customer = customer
            self.testDevices = testDevices
        }

        /// The listed test devices’ serials, uppercased.
        public var testDeviceSerials: Set<String> {
            Set((testDevices ?? []).map { $0.serial.trimmingCharacters(in: .whitespaces).uppercased() })
        }

        /// Every hostname of a Jamf Pro or Jamf School entry, lowercased
        /// (public, to match an app’s saved connection to its role).
        public var hosts: [String] {
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
            case .missing(let path): "The allow-list doesn’t exist: \(path)"
            case .readableByOthers(let path): "The allow-list must be readable by you only (chmod 600): \(path)"
            case .insideGitWorkTree(let path): "The allow-list lies inside a git work tree; move it out: \(path)"
            case .unreadable(let reason): "The allow-list can’t be read: \(reason)"
            case .unsupportedVersion(let version): "The allow-list’s version \(version) isn’t supported"
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
        guard supportedVersions.contains(list.version) else { throw LoadError.unsupportedVersion(list.version) }
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

    /// The same list with these roles read only: an app’s release
    /// check can make a tenant stricter for its own run (`READ_ONLY_ROLES`),
    /// never looser.
    public func readingOnly(_ roles: Set<String>) -> AllowList {
        var list = self
        list.tenants = tenants.map { entry in
            guard roles.contains(entry.role) else { return entry }
            return Entry(role: entry.role, service: entry.service, host: entry.host, aliases: entry.aliases, region: entry.region,
                         environmentID: entry.environmentID, entraTenantID: entry.entraTenantID, clientID: entry.clientID,
                         access: .readOnly, production: entry.production, keychainService: entry.keychainService,
                         // read only for this app: no device commands either
                         customer: entry.customer, testDevices: nil)
        }
        return list
    }
}

extension AllowList.Entry {
    func validate() throws {
        if customer == true {
            throw AllowList.LoadError.incomplete(role: role, reason: "it is marked customer, and a customer’s tenant is never on the allow-list")
        }
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
            throw AllowList.LoadError.incomplete(role: role, reason: "Apple Business or Apple School Manager is read only")
        }
        if let testDevices, !testDevices.isEmpty {
            if production {
                throw AllowList.LoadError.incomplete(role: role, reason: "a production tenant takes no test devices: it is only read")
            }
            if service == .appleBusinessManager || service == .appleSchoolManager {
                throw AllowList.LoadError.incomplete(role: role, reason: "Apple Business or Apple School Manager takes no commands")
            }
            if testDevices.contains(where: { $0.serial.trimmingCharacters(in: .whitespaces).isEmpty }) {
                throw AllowList.LoadError.incomplete(role: role, reason: "a test device without a serial")
            }
        }
    }
}
