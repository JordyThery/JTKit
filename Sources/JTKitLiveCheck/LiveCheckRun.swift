import Foundation

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
///   `JTKIT_LIVE_FAULT` (only with the script's `--fault`, to test the check itself).
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

    public init(environment: [String: String], upstream: URLSession? = nil) throws {
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
        let allowList = try AllowList.load(from: listURL)
        self.allowList = allowList
        let missing = roles.filter { role in !allowList.tenants.contains { $0.role == role } }
        guard missing.isEmpty else {
            throw RunError.notAllowed("Not on the allow-list: \(missing.sorted().joined(separator: ", "))")
        }
        legacyPrefixes = (environment["JTKIT_LIVE_LEGACY_PREFIXES"] ?? "").split(separator: "|").map(String.init).filter { !$0.isEmpty }
        fault = environment["JTKIT_LIVE_FAULT"].flatMap { $0.isEmpty ? nil : $0 }
        let writesAllowed = environment["JTKIT_LIVE_WRITES"] == "1"
        self.writesAllowed = writesAllowed
        let ledger = Ledger(fileURL: runFolder.appending(path: "ledger.json"))
        self.ledger = ledger
        let policy = LiveCheckPolicy(allowList: allowList, roles: roles,
                                     includeProduction: environment["JTKIT_LIVE_INCLUDE_PRODUCTION"] == "1",
                                     prefix: prefix, ledger: ledger, writesAllowed: writesAllowed)
        self.policy = policy
        let refusalsFile = runFolder.appending(path: "refusals.jsonl")
        network = upstream.map { LiveCheckNetwork(policy: policy, upstream: $0, refusalsFile: refusalsFile) }
            ?? LiveCheckNetwork(policy: policy, refusalsFile: refusalsFile)
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
    /// sweep may delete it. Full tenants only; the name must start with
    /// `JTKTEST ` or one of the legacy prefixes.
    public func adoptForSweep(role: String, service: AllowList.Service, resource: String, id: String, name: String) throws {
        let entry = try entry(role: role, service: service)
        guard entry.access == .full else {
            throw RunError.notAllowed("\(role) has no prefix sweep: only the ledger is cleaned up there")
        }
        try ledger.add(.init(target: target(role: role, service: service), resource: resource, id: id, name: name, fromSweep: true),
                       testPrefixes: [Self.testPrefix + " "] + legacyPrefixes)
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
