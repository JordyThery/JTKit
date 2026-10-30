import CryptoKit
import Foundation
import Security

/// One release-check run as an app's live-check tests see it: the
/// allow-list, the prefix, the ledger, the guarded network and the
/// credentials the script passed in. The tests are skipped unless the
/// release check switches them on (`isEnabled`), so ⌘U never reaches a tenant.
///
/// The script sets, through `TEST_RUNNER_` variables (Xcode strips the prefix):
/// - `JTKIT_LIVE=1`, `JTKIT_LIVE_RUN_DIR`, `JTKIT_LIVE_PREFIX`, `JTKIT_LIVE_ROLES`
///   (comma-separated); optionally `JTKIT_LIVE_ALLOWLIST`,
///   `JTKIT_LIVE_INCLUDE_PRODUCTION=1`, `JTKIT_LIVE_LEGACY_PREFIXES`
///   (`|`-separated, for the one-time sweep of older test objects),
///   `JTKIT_LIVE_WRITES=1` (stage 4 only; otherwise every tenant is read only),
///   `JTKIT_LIVE_FAULT` (only with the script's `--fault`, to test the check itself),
///   `JTKIT_LIVE_READ_ONLY_ROLES` (comma-separated roles kept read only for this app),
///   `JTKIT_LIVE_HOST_KEYCHAIN` (`before`/`after`, for `HOST_KEYCHAIN_TEST`; 0.12.5).
/// - Credentials as `JTKIT_LIVE_<ROLE>_<ITEM>`, e.g. `JTKIT_LIVE_JAMF_TEST_A_CLIENT_SECRET`,
///   read from the login Keychain; never written to a file or log.
public nonisolated final class LiveCheckRun: @unchecked Sendable {
    public static let testPrefix = "JTKTEST"

    public let prefix: String
    public let runFolder: URL
    public let allowList: AllowList
    public let roles: Set<String>
    public let ledger: Ledger
    public let policy: LiveCheckPolicy
    public let network: LiveCheckNetwork
    /// Older test prefixes the sweep may also remove (first run only).
    public let legacyPrefixes: [String]
    /// Whether this stage may change tenants (`JTKIT_LIVE_WRITES=1`).
    public let writesAllowed: Bool
    /// A failure to inject on purpose (`JTKIT_LIVE_FAULT`), set only by the
    /// release check's `--fault`, which marks the whole run as a fault test.
    /// Nil in every normal run.
    public let fault: String?
    /// Roles this run treats as read only whatever the allow-list grants
    /// (`JTKIT_LIVE_READ_ONLY_ROLES`, from the app's `READ_ONLY_ROLES`; 0.12.4).
    public let readOnlyRoles: Set<String>
    /// `before` or `after` while the script runs the app's
    /// `HOST_KEYCHAIN_TEST` (`JTKIT_LIVE_HOST_KEYCHAIN`, 0.12.5); nil otherwise.
    public let hostKeychainLabel: String?
    private let environment: [String: String]
    private let lock = NSLock()

    public nonisolated enum RunError: Error, CustomStringConvertible {
        case notEnabled
        case missingSetting(String)
        case missingCredential(role: String, item: String)
        case notAllowed(String)
        case injectedFault(String)

        public var description: String {
            switch self {
            case .notEnabled: "Live checks run only from the release check (JTKIT_LIVE=1)"
            case .missingSetting(let name): "The release check didn't set \(name)"
            case .missingCredential(let role, let item): "No \(item) for \(role); run release-check-setup.sh"
            case .notAllowed(let reason): reason
            case .injectedFault(let point): "Failure injected on purpose (release check --fault): \(point)"
            }
        }
    }

    /// Whether the release check switched live checks on for this test run.
    public static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["JTKIT_LIVE"] == "1"
    }

    /// The run of this test process, made once from its environment.
    public static func current() throws -> LiveCheckRun {
        try shared.get()
    }

    private static let shared: Result<LiveCheckRun, Error> = Result {
        try LiveCheckRun(environment: ProcessInfo.processInfo.environment)
    }

    /// - Parameter readBack: tests only; the standard read-back by default.
    public init(environment: [String: String], upstream: URLSession? = nil, readBack: ReadBack? = nil) throws {
        guard environment["JTKIT_LIVE"] == "1" else { throw RunError.notEnabled }
        func setting(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else { throw RunError.missingSetting(name) }
            return value
        }
        self.environment = environment
        prefix = try setting("JTKIT_LIVE_PREFIX")
        guard prefix.hasPrefix(Self.testPrefix + " ") else {
            throw RunError.notAllowed("The prefix must start with “\(Self.testPrefix) ”")
        }
        runFolder = URL(filePath: try setting("JTKIT_LIVE_RUN_DIR"), directoryHint: .isDirectory)
        let roles = Set(try setting("JTKIT_LIVE_ROLES").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        self.roles = roles
        let listURL = environment["JTKIT_LIVE_ALLOWLIST"].map { URL(filePath: $0) } ?? AllowList.defaultURL
        let loaded = try AllowList.load(from: listURL)
        let missing = roles.filter { role in !loaded.tenants.contains { $0.role == role } }
        guard missing.isEmpty else {
            throw RunError.notAllowed("Not on the allow-list: \(missing.sorted().joined(separator: ", "))")
        }
        // Roles the app's check keeps read only, whatever the allow-list
        // grants (0.12.4); every rule below sees the stricter access.
        let readOnlyRoles = Set((environment["JTKIT_LIVE_READ_ONLY_ROLES"] ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let unknown = readOnlyRoles.subtracting(roles)
        guard unknown.isEmpty else {
            throw RunError.notAllowed("Read-only roles not in this run: \(unknown.sorted().joined(separator: ", "))")
        }
        self.readOnlyRoles = readOnlyRoles
        let allowList = loaded.readingOnly(readOnlyRoles)
        self.allowList = allowList
        legacyPrefixes = (environment["JTKIT_LIVE_LEGACY_PREFIXES"] ?? "").split(separator: "|").map(String.init).filter { !$0.isEmpty }
        fault = environment["JTKIT_LIVE_FAULT"].flatMap { $0.isEmpty ? nil : $0 }
        hostKeychainLabel = environment["JTKIT_LIVE_HOST_KEYCHAIN"].flatMap { $0.isEmpty ? nil : $0 }
        let writesAllowed = environment["JTKIT_LIVE_WRITES"] == "1"
        self.writesAllowed = writesAllowed
        let ledger = Ledger(fileURL: runFolder.appending(path: "ledger.json"))
        self.ledger = ledger
        let policy = LiveCheckPolicy(allowList: allowList, roles: roles,
                                     includeProduction: environment["JTKIT_LIVE_INCLUDE_PRODUCTION"] == "1",
                                     prefix: prefix, ledger: ledger, writesAllowed: writesAllowed)
        self.policy = policy
        let refusalsFile = runFolder.appending(path: "refusals.jsonl")
        let appleFile = runFolder.appending(path: Self.appleRequestsFileName)
        let deletesFile = runFolder.appending(path: Self.deletesFileName)
        network = upstream.map {
            LiveCheckNetwork(policy: policy, upstream: $0, refusalsFile: refusalsFile, appleRequestsFile: appleFile,
                             readBack: readBack ?? .standard, deletesFile: deletesFile)
        } ?? LiveCheckNetwork(policy: policy, refusalsFile: refusalsFile, appleRequestsFile: appleFile,
                              readBack: readBack ?? .standard, deletesFile: deletesFile)
    }

    /// Every delete's read-back of the run, from all its test processes (0.12.6).
    public static let deletesFileName = "deletes.jsonl"

    /// The objects of the run's ledger not confirmed removed, e.g. at the end
    /// of a cleanup.
    public var notRemoved: [Ledger.Item] { ledger.outstanding }

    /// Throws, naming every object of the ledger a read-back hasn't found
    /// gone (0.12.6). A cleanup test calls it last: the run then fails.
    public func requireNothingLeft() throws {
        let left = notRemoved
        guard left.isEmpty else {
            throw RunError.notAllowed("Not removed (a read-back still finds them): "
                + left.map { "\($0.resource) \($0.id) “\($0.name)”" }.joined(separator: "; "))
        }
    }

    /// Every Apple request of the run, from all its test processes (0.12.4).
    public static let appleRequestsFileName = "apple-requests.jsonl"

    /// Apple requests so far in this run, per role.
    public var appleRequestCounts: [String: Int] {
        AppleRequestBudget.counts(in: runFolder.appending(path: Self.appleRequestsFileName))
    }

    // MARK: Tenants and credentials

    /// The allow-list entry of a role this run uses.
    public func entry(role: String, service: AllowList.Service) throws -> AllowList.Entry {
        guard roles.contains(role),
              let entry = allowList.tenants.first(where: { $0.role == role && $0.service == service })
        else { throw RunError.notAllowed("\(role) (\(service.rawValue)) isn't on the allow-list for this run") }
        return entry
    }

    /// A credential the script read from the Keychain, e.g. `credential("jamf-test-a", "client-secret")`.
    public func credential(_ role: String, _ item: String) throws -> String {
        guard let value = environment[Self.variable(role: role, item: item)], !value.isEmpty else {
            throw RunError.missingCredential(role: role, item: item)
        }
        return value
    }

    /// `JTKIT_LIVE_JAMF_TEST_A_CLIENT_SECRET` for `("jamf-test-a", "client-secret")`.
    public static func variable(role: String, item: String) -> String {
        "JTKIT_LIVE_" + "\(role)_\(item)".uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.map(String.init).joined()
    }

    /// For tools whose traffic doesn't pass the guarded network (OpenTofu):
    /// throws unless the tenant is on the allow-list with full access, isn't
    /// production, and its role is in this run.
    public func requireEngineTarget(role: String, service: AllowList.Service,
                                    host: String? = nil, region: String? = nil, environmentID: String? = nil) throws {
        guard writesAllowed else {
            throw RunError.notAllowed("Writes are off in this stage; the engine isn't run")
        }
        let entry = try entry(role: role, service: service)
        guard entry.access == .full, !entry.production else {
            throw RunError.notAllowed("\(role) doesn't have full access; the engine is never run against it")
        }
        if let host, !entry.hosts.contains(host.lowercased()) {
            throw RunError.notAllowed("\(host) isn't \(role)'s host")
        }
        if let environmentID, entry.environmentID?.lowercased() != environmentID.lowercased() {
            throw RunError.notAllowed("Environment \(environmentID) isn't \(role)'s")
        }
        if let region, entry.region?.lowercased() != region.lowercased() {
            throw RunError.notAllowed("Region \(region) isn't \(role)'s")
        }
    }

    /// Fails here when the run's fault is `fault`; does nothing otherwise
    /// (every normal run). The failure is recorded for the report.
    public func injectFault(_ fault: String, at point: String) throws {
        guard self.fault == fault else { return }
        record(step: point, passed: false, note: "failure injected on purpose (--fault \(fault))")
        throw RunError.injectedFault(point)
    }

    // MARK: Ledger and sweep

    /// The ledger target of a role's tenant (see `Ledger.Item.target`).
    public func target(role: String, service: AllowList.Service) throws -> String {
        let entry = try entry(role: role, service: service)
        switch service {
        case .jamfPlatform: return "platform:\(entry.environmentID?.lowercased() ?? "")"
        case .jamfPro, .jamfSchool: return entry.host?.lowercased() ?? ""
        case .intune: return "intune:\(entry.entraTenantID?.lowercased() ?? "")"
        case .appleBusinessManager, .appleSchoolManager: return "apple:\(entry.clientID ?? "")"
        }
    }

    /// Records an object the run made without the guarded network (e.g.
    /// OpenTofu's), so it can be changed and removed; its name must carry this run's prefix.
    public func recordCreated(role: String, service: AllowList.Service, resource: String, id: String, name: String) throws {
        try ledger.add(.init(target: target(role: role, service: service), resource: resource, id: id, name: name),
                       testPrefixes: [prefix])
    }

    /// Adds a left-over test object found by the sweep to the ledger, so the
    /// sweep may delete it. Full tenants: the name must start with `JTKTEST `
    /// or one of the legacy prefixes. Create-and-remove tenants (0.12.5): only
    /// a legacy prefix, so only on the first run (the script passes legacy
    /// prefixes until a cleanup passed); `JTKTEST` objects there are removed
    /// from the ledger only.
    public func adoptForSweep(role: String, service: AllowList.Service, resource: String, id: String, name: String) throws {
        let entry = try entry(role: role, service: service)
        let prefixes: [String]
        switch entry.access {
        case .full:
            prefixes = [Self.testPrefix + " "] + legacyPrefixes
        case .createAndRemove where isLegacyTestObject(name):
            prefixes = legacyPrefixes
        default:
            throw RunError.notAllowed("\(role) has no prefix sweep: only the ledger is cleaned up there")
        }
        try ledger.add(.init(target: target(role: role, service: service), resource: resource, id: id, name: name, fromSweep: true),
                       testPrefixes: prefixes)
    }

    /// Lets this run permanently delete one group an earlier run left in
    /// Entra's recycle bin (0.12.7): only on an Intune tenant this run may
    /// write to, only while writes are on, and only a group whose name starts
    /// with `JTKTEST ` (the caller reads the name from the recycle bin).
    public func adoptDeletedGroupForPurge(role: String, id: String, name: String) throws {
        let entry = try entry(role: role, service: .intune)
        guard entry.access != .readOnly, writesAllowed else {
            throw RunError.notAllowed("\(role): nothing is purged without writes")
        }
        guard name.hasPrefix(Self.testPrefix + " ") else {
            throw RunError.notAllowed("“\(name)” isn't named as a test object: it isn't purged")
        }
        policy.allowPurge(target: try target(role: role, service: .intune), id: id)
    }

    /// Whether a name is an older test object (a legacy prefix of this run)
    /// that the one-time sweep removes (0.12.5).
    public func isLegacyTestObject(_ name: String) -> Bool {
        legacyPrefixes.contains { name.hasPrefix($0) }
    }

    // MARK: Keychain item names, seen from the test host (0.12.5)

    /// Writes this test host's view of the Keychain items of `services` and
    /// of the access groups ending in `accessGroups` to the run folder as
    /// `host-keychain.<label>`: one SHA-256 hash (16 characters) per service
    /// and account name, sorted. Attributes only: no secret is read. Both
    /// the login keychain and the data-protection keychain are searched.
    /// MSAL's cache lives in the data-protection keychain, in its own access
    /// group (`com.microsoft.identity.universalstorage`) that only the app
    /// and its test host can see, under names like `accesstoken-…`. The
    /// release check runs it before sign-in (`before`) and after cleanup
    /// (`after`) and compares the two.
    @discardableResult
    public func recordHostKeychainNames(services: [String], accessGroups: [String] = [], label: String) throws -> [String] {
        guard label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), !label.isEmpty else {
            throw RunError.notAllowed("A fingerprint label is letters, digits and hyphens")
        }
        let names = Self.keychainNames(services: services) + Self.keychainNames(accessGroupSuffixes: accessGroups)
        let lines = Set(names).map { "keychain-host \(Self.shortHash($0))" }.sorted()
        try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: runFolder.appending(path: "host-keychain.\(label)"), options: .atomic)
        return lines
    }

    /// The same, labelled as the script asked (`hostKeychainLabel`).
    @discardableResult
    public func recordHostKeychainNames(services: [String], accessGroups: [String] = []) throws -> [String] {
        guard let hostKeychainLabel else { throw RunError.missingSetting("JTKIT_LIVE_HOST_KEYCHAIN") }
        return try recordHostKeychainNames(services: services, accessGroups: accessGroups, label: hostKeychainLabel)
    }

    /// `service / account` of every generic-password item of the services.
    static func keychainNames(services: [String]) -> [String] {
        var names: Set<String> = []
        for service in services {
            for dataProtection in [false, true] {
                var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                            kSecAttrService as String: service,
                                            kSecMatchLimit as String: kSecMatchLimitAll,
                                            kSecReturnAttributes as String: true]
                if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
                var result: CFTypeRef?
                guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                      let items = result as? [[String: Any]] else { continue }
                for item in items {
                    names.insert("\(service) / \(item[kSecAttrAccount as String] as? String ?? "")")
                }
            }
        }
        return names.sorted()
    }

    /// `group / service / account` of every generic-password item in the
    /// data-protection keychain whose access group ends in one of the suffixes
    /// (the team prefix differs per Mac's signing).
    static func keychainNames(accessGroupSuffixes: [String]) -> [String] {
        guard !accessGroupSuffixes.isEmpty else { return [] }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecUseDataProtectionKeychain as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let group = item[kSecAttrAccessGroup as String] as? String,
                  let suffix = accessGroupSuffixes.first(where: { group.hasSuffix($0) }) else { return nil }
            return "\(suffix) / \(item[kSecAttrService as String] as? String ?? "") / \(item[kSecAttrAccount as String] as? String ?? "")"
        }.sorted()
    }

    static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Whether a name is a test object the sweep removes.
    public func isSweepable(_ name: String) -> Bool {
        ([Self.testPrefix + " "] + legacyPrefixes).contains { name.hasPrefix($0) }
    }

    // MARK: Report

    public nonisolated struct StepResult: Codable, Sendable {
        public var step: String
        public var passed: Bool
        public var note: String?
    }

    /// Appends a step's result to `results.jsonl` for the stage 5 report.
    /// Refusals don't wait for this: the network appends each one to
    /// `refusals.jsonl` when it happens (0.12.3; before, each test process
    /// overwrote `refusals.json` with its own).
    public func record(step: String, passed: Bool, note: String? = nil) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)
            let line = (try? JSONEncoder().encode(StepResult(step: step, passed: passed, note: note))) ?? Data()
            let results = runFolder.appending(path: "results.jsonl")
            if let handle = try? FileHandle(forWritingTo: results) {
                handle.seekToEndOfFile()
                handle.write(line + Data("\n".utf8))
                try? handle.close()
            } else {
                try? (line + Data("\n".utf8)).write(to: results)
            }
        }
    }

    /// Every refusal of the run so far, from all its test processes.
    public var runRefusals: [LiveRefusal] {
        LiveCheckNetwork.refusals(in: runFolder.appending(path: "refusals.jsonl"))
    }

    /// `JTKTEST JD 1027-1432` for app code `JD` at 27 October, 14:32.
    public static func makePrefix(appCode: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMdd-HHmm"
        return "\(testPrefix) \(appCode) \(formatter.string(from: date))"
    }
}
