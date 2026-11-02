import Foundation
import Network

/// The gateway of live UI tests (1.1.0, B1 and B4), run by the release
/// check as its own process (`jtkit-live-gateway`) while a live UI test
/// runs. The app launched with `-JTKitLiveCheck <run folder>` sends every
/// request JTKit makes to it, and so does the UI test for its own objects,
/// on this Mac only (127.0.0.1). It decides each one with the release
/// check’s guarded network (`LiveCheckRun.network`: allow-list, ledger,
/// prefix, access levels) before anything leaves the Mac. Neither the app
/// nor the UI test holds the rules, the ledger or the run’s files: both are
/// sandboxed or may be, and only make outgoing connections.
///
/// It starts only inside a release check: `LiveCheckRun` needs the release
/// check’s settings and the allow-list, and the gateway needs the release
/// check’s lock to be held. It writes into the run folder `live-launch.json`
/// (its port, the lock’s owner and the release check’s connections, no
/// secret) and `live-gateway.token` (mode 600), and removes both when it stops.
/// For a sandboxed app the run folder is in the app’s container, which the
/// UI test runner can’t read: the same two files then also go into the
/// runner folder (`JTKIT_LIVE_RUNNER_DIR`, the release check’s own run
/// folder), and are removed from there too. A copy of the run’s ledger
/// (`ledger.json`: the objects the run made, by name and ID, no secret) is
/// kept there as well, refreshed before each answer, for a UI test that
/// reads which objects the app made.
public final class LiveGateway: @unchecked Sendable {
    public let run: LiveCheckRun
    /// The port on 127.0.0.1.
    public private(set) var port: UInt16 = 0
    let token = UUID().uuidString + UUID().uuidString
    /// The connections written for the app, by role.
    public private(set) var connections: [LiveConnectionDescription] = []
    /// The variables the app is launched with: the token only. The roles’
    /// secrets are handed over on a request with the token (`secretsCommand`),
    /// so they never reach a launch environment, which Xcode keeps in the
    /// test’s result bundle.
    public private(set) var environment: [String: String] = [:]
    /// Only the run’s secrets: requests aren’t sent (for unit-test live
    /// checks, whose own guarded network keeps the ledger).
    public let secretsOnly: Bool
    /// Where the UI test runner reads the launch file and token, when it
    /// can’t read the run folder (a sandboxed app’s container); nil otherwise.
    public let runnerFolder: URL?
    /// The ledger’s objects when the gateway started: `status` reports only
    /// objects made since, so an earlier run’s leftovers (adopted for the
    /// sweep) and earlier steps’ objects (left for cleanup) don’t count.
    private let ledgerAtStart: Set<String>
    /// Until when the app said it waits before trying a request again.
    private var appWaitsUntil = Date.distantPast

    private let listener: NWListener
    private let queue = DispatchQueue(label: "JTKitUITestSupport.live-gateway", attributes: .concurrent)
    private let lock = NSLock()
    private var inFlight = 0
    private var handled = 0
    /// Credentials a test process handed over (`provideCommand`), by
    /// "role|item": an app’s saved connection, read in its own test host.
    /// Never one the release check read itself; in memory only.
    private var provided: [String: String] = [:]
    /// The roles the launch file lists, in order, and the lock’s owner, to
    /// write the launch file again once credentials are handed over.
    private var launchRoles: [String] = []
    private var lockOwner = ""

    public enum GatewayError: Error, CustomStringConvertible, Equatable {
        case notLocked
        case couldNotListen(String)
        case unknownRole(String)
        case ownerGone(String)

        public var description: String {
            switch self {
            case .notLocked: "Live UI tests run only while a release check holds its lock"
            case .couldNotListen(let reason): "The live gateway couldn’t start: \(reason)"
            case .unknownRole(let role): "\(role) isn’t a role of this run"
            case .ownerGone(let owner): "The release check holding the lock (\(owner)) isn’t running any more"
            }
        }
    }

    /// The release check’s lock owner (`release-check-lib.sh`’s `RC_LOCK.owner`).
    public static var defaultLockOwnerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/JTKit Release Check/state/release-check.lock.owner")
    }

    /// Starts the gateway and writes the run folder’s `live-launch.json` and token.
    /// - Parameters:
    ///   - roles: the release check’s connections an app may get, in this
    ///     order; every role of the run by default.
    ///   - lockOwnerURL: tests only.
    ///   - secretsOnly: serve only the run’s secrets, send nothing.
    ///   - runnerFolder: a second folder for the launch file and token,
    ///     for a UI test runner that can’t read the run folder.
    public init(run: LiveCheckRun, roles: [String]? = nil, lockOwnerURL: URL = LiveGateway.defaultLockOwnerURL,
                secretsOnly: Bool = false, runnerFolder: URL? = nil) throws {
        self.run = run
        self.secretsOnly = secretsOnly
        self.runnerFolder = runnerFolder.flatMap { $0.standardizedFileURL == run.runFolder.standardizedFileURL ? nil : $0 }
        let owner = (try? String(contentsOf: lockOwnerURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !owner.isEmpty else { throw GatewayError.notLocked }
        // a lock file a killed release check left behind
        guard Self.ownerIsAlive(owner) else { throw GatewayError.ownerGone(owner) }

        let launchRoles = roles ?? run.roles.sorted()
        for role in launchRoles where !run.roles.contains(role) || !run.allowList.tenants.contains(where: { $0.role == role }) {
            throw GatewayError.unknownRole(role)
        }
        self.launchRoles = launchRoles
        self.lockOwner = owner
        // nothing handed over yet: the release check’s own credentials
        let described = Self.describe(roles: launchRoles, run: run) { run.environmentCredential($0, $1) }
        connections = described
        environment = ["JTKIT_LIVE_GATEWAY_TOKEN": token]
        ledgerAtStart = Set(run.ledger.items.map(Self.ledgerKey))

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.acceptLocalOnly = true
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw GatewayError.couldNotListen(error.localizedDescription)
        }
        let ready = DispatchSemaphore(value: 0)
        let failed = FailureBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                failed.set(error.localizedDescription)
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, failed.value == nil, let port = listener.port?.rawValue else {
            listener.cancel()
            throw GatewayError.couldNotListen(failed.value ?? "no port")
        }
        self.port = port

        let launch = LiveLaunchFile(port: port, lockOwner: owner,
                                    connections: described.map { Self.launchEntry($0, run: run) })
        let data = try JSONEncoder().encode(launch)
        do {
            for folder in [run.runFolder] + (self.runnerFolder.map { [$0] } ?? []) {
                try Self.writeLaunchFiles(launch: data, token: token, to: folder)
            }
        } catch {
            stop()
            throw error
        }
        mirrorLedger()
    }

    /// Copies the run’s ledger into the runner folder (a sandboxed app’s
    /// UI test runner can’t read the one in its container). Atomic, mode 600.
    func mirrorLedger() {
        guard let runnerFolder else { return }
        let copy = runnerFolder.appending(path: run.ledger.fileURL.lastPathComponent)
        guard let data = try? Data(contentsOf: run.ledger.fileURL) else {
            try? FileManager.default.removeItem(at: copy)
            return
        }
        try? data.write(to: copy, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
    }

    deinit { listener.cancel() }

    /// A connection as the launch file lists it, with whether its role
    /// lists test devices in this run (after `READ_ONLY_ROLES`).
    private static func launchEntry(_ connection: LiveConnectionDescription, run: LiveCheckRun) -> LiveLaunchFile.Entry {
        let devices = run.allowList.tenants.filter { $0.role == connection.role }.flatMap { $0.testDevices ?? [] }
        return .init(role: connection.role, connection: connection, secretItem: connection.secretItem,
                     receivesCommands: !devices.isEmpty)
    }

    /// The launch file’s connections, from the allow-list and the
    /// credentials known now (the release check’s, then those handed over).
    private func describeConnections() -> [LiveConnectionDescription] {
        Self.describe(roles: launchRoles, run: run) { [self] in credential($0, $1) }
    }

    private static func describe(roles: [String], run: LiveCheckRun,
                                 credential: @escaping (String, String) -> String?) -> [LiveConnectionDescription] {
        roles.flatMap { role in
            let entries = run.allowList.tenants.filter { $0.role == role }
            return entries.map { entry in
                LiveConnectionDescription(entry: entry, run: run, sharesRole: entries.count > 1) {
                    credential(entry.role, $0) ?? ""
                }
            }
        }
    }

    /// A credential of the run: the release check’s own, else one handed over.
    func credential(_ role: String, _ item: String) -> String? {
        if let own = run.environmentCredential(role, item) { return own }
        return lock.withLock { provided["\(role)|\(item)"] }
    }

    /// The items a test process may hand over: a sign-in’s non-secret IDs
    /// and secrets, by the names the release check uses.
    public static let providableItems: Set<String> = [
        "client-id", "client-secret", "username", "password", "network-id", "api-key", "key-id", "private-key",
        "jamfpro-client-id", "jamfpro-client-secret", "jamfpro-username", "jamfpro-password",
    ]

    /// Takes credentials a test process read from its app’s saved
    /// connections (1.3.1): only for roles of this run, only the items
    /// above, never in place of one the release check read itself or one
    /// already handed over. Then the launch file is written again, so an app
    /// launched afterwards gets the connections with their IDs.
    /// - Returns: the items taken, "role|item".
    func provide(_ items: [LiveSecretItem]) throws -> [String] {
        for item in items {
            guard run.roles.contains(item.role) else { throw GatewayError.unknownRole(item.role) }
            guard Self.providableItems.contains(item.item) else { throw ProvideError.unknownItem(item.item) }
            guard !item.value.isEmpty, item.value.utf8.count <= 16 * 1024 else { throw ProvideError.badValue(item.item) }
        }
        var taken: [String] = []
        lock.withLock {
            for item in items where run.environmentCredential(item.role, item.item) == nil {
                let key = "\(item.role)|\(item.item)"
                guard provided[key] == nil else { continue }
                provided[key] = item.value
                taken.append(key)
            }
        }
        guard !taken.isEmpty else { return [] }
        let described = describeConnections()
        lock.withLock { connections = described }
        let launch = LiveLaunchFile(port: port, lockOwner: lockOwner,
                                    connections: described.map { Self.launchEntry($0, run: run) })
        let data = try JSONEncoder().encode(launch)
        for folder in [run.runFolder] + (runnerFolder.map { [$0] } ?? []) {
            try Self.writeLaunchFiles(launch: data, token: token, to: folder)
        }
        return taken
    }

    public enum ProvideError: Error, CustomStringConvertible, Equatable {
        case unknownItem(String)
        case badValue(String)

        public var description: String {
            switch self {
            case .unknownItem(let item): "\(item) isn’t a credential the live gateway takes"
            case .badValue(let item): "The value handed over for \(item) is empty or too long"
            }
        }
    }

    /// The launch file and the token (mode 600 both), in a folder only this
    /// user can read (700). The token is written first, so a reader that finds
    /// the launch file also finds the token.
    private static func writeLaunchFiles(launch: Data, token: String, to folder: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tokenFile = folder.appending(path: tokenFileName)
        try? manager.removeItem(at: tokenFile)
        guard manager.createFile(atPath: tokenFile.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tokenFile.path])
        }
        let file = folder.appending(path: launchFileName)
        try launch.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Stops listening and removes `live-launch.json` and the token (also
    /// from the runner folder), so the run folder can’t start another app.
    public func stop() {
        listener.cancel()
        mirrorLedger()
        for folder in [run.runFolder] + (runnerFolder.map { [$0] } ?? []) {
            try? FileManager.default.removeItem(at: folder.appending(path: Self.launchFileName))
            try? FileManager.default.removeItem(at: folder.appending(path: Self.tokenFileName))
        }
    }

    public static let launchFileName = "live-launch.json"
    public static let tokenFileName = "live-gateway.token"
    public static let violationsFileName = "live-violations.jsonl"

    /// What a live UI test asks the gateway (`LiveGatewayRequest.command`).
    public static let statusCommand = "status"
    public static let recordCommand = "record"
    /// The run’s secrets for the items asked (`LiveGatewayRequest.secrets`).
    public static let secretsCommand = "secrets"
    /// Credentials handed over from an app’s saved connections (`LiveGatewayRequest.secrets`, with values).
    public static let provideCommand = "provide"
    /// The allow-list’s test devices of a role of this run (`LiveGatewayRequest.step.step` names the role),
    /// for a UI test runner that can’t read the allow-list.
    public static let testDevicesCommand = "testDevices"
    /// The app waits before trying a request again (`LiveGatewayRequest.waitSeconds`).
    public static let waitCommand = "wait"

    /// Whether the process that holds the release check’s lock is still
    /// running: the lock file names it first (`<pid> <app>`). A process this
    /// one may not signal still counts as running.
    public static func ownerIsAlive(_ owner: String) -> Bool {
        guard let first = owner.split(separator: " ").first, let pid = Int32(first), pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    static func ledgerKey(_ item: Ledger.Item) -> String {
        "\(item.target)|\(item.resource)|\(item.id.lowercased())"
    }

    /// What the gateway knows of the run now. `notRemoved` holds only
    /// objects made since the gateway started.
    public var status: LiveGatewayStatus {
        let unrecorded = LiveCheckNetwork.unrecordedCreates(in: run.runFolder.appending(path: LiveCheckRun.unrecordedCreatesFileName))
        let own = run.notRemoved.filter { !$0.fromSweep && !ledgerAtStart.contains(Self.ledgerKey($0)) }
        return LiveGatewayStatus(
            pending: pendingRequests, handled: handledRequests, refusals: run.network.refusals, violations: violations,
            notRemoved: own.map { "\($0.resource) \($0.id) “\($0.name)”" }
                + unrecorded.map { "\($0.resource) “\($0.name)” (created but not in the ledger: \($0.reason))" }
                + (run.ledger.saveFailure.map { [$0] } ?? []))
    }

    /// Requests being decided or sent now, and one more while the app waits
    /// to try a request again (it said so with `waitCommand`).
    public var pendingRequests: Int {
        lock.withLock { inFlight + (Date() < appWaitsUntil ? 1 : 0) }
    }

    /// Requests answered so far.
    public var handledRequests: Int { lock.withLock { handled } }

    /// Waits until no request has been in flight for `quiet` seconds, up to
    /// `timeout`. True when the app’s network work finished.
    @discardableResult
    public func waitUntilIdle(quiet: TimeInterval = 1.5, timeout: TimeInterval = 120) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var idleSince: Date?
        while Date() < deadline {
            if pendingRequests == 0 {
                let since = idleSince ?? Date()
                idleSince = since
                if Date().timeIntervalSince(since) >= quiet { return true }
            } else {
                idleSince = nil
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// What the app tried under the switch and was refused: a saved
    /// connection or a real Keychain item. Any fails the run.
    public var violations: [String] {
        guard let text = try? String(contentsOf: run.runFolder.appending(path: Self.violationsFileName), encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: Serving

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(length: 4, on: connection, collected: Data()) { [weak self] header in
            guard let self, let header else { connection.cancel(); return }
            let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
            guard length > 0, length < 64 * 1024 * 1024 else { connection.cancel(); return }
            self.receive(length: length, on: connection, collected: Data()) { payload in
                guard let payload else { connection.cancel(); return }
                self.answer(payload, on: connection)
            }
        }
    }

    private func receive(length: Int, on connection: NWConnection, collected: Data, done: @escaping (Data?) -> Void) {
        guard collected.count < length else { return done(collected) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: length - collected.count) { [weak self] data, _, isComplete, error in
            guard let self, let data, error == nil else { return done(nil) }
            if data.isEmpty && isComplete { return done(nil) }
            self.receive(length: length, on: connection, collected: collected + data, done: done)
        }
    }

    private func answer(_ payload: Data, on connection: NWConnection) {
        func reply(_ response: LiveGatewayResponse) {
            // what the request changed in the ledger, before the caller reads it
            self.mirrorLedger()
            let data = (try? JSONEncoder().encode(response)) ?? Data()
            var length = UInt32(data.count).bigEndian
            connection.send(content: Data(bytes: &length, count: 4) + data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        guard let request = try? JSONDecoder().decode(LiveGatewayRequest.self, from: payload) else {
            return reply(LiveGatewayResponse(error: "The live gateway couldn’t read the request."))
        }
        guard Self.same(request.token, token) else {
            return reply(LiveGatewayResponse(error: "The live gateway refused a request without its token."))
        }
        switch request.command {
        case Self.secretsCommand?:
            return reply(LiveGatewayResponse(status: 200, body: try? JSONEncoder().encode(secrets(for: request.secrets ?? []))))
        case Self.provideCommand?:
            do {
                let taken = try provide(request.secrets ?? [])
                return reply(LiveGatewayResponse(status: 200, body: try? JSONEncoder().encode(taken)))
            } catch {
                return reply(LiveGatewayResponse(error: "\(error)"))
            }
        case Self.testDevicesCommand?:
            guard let role = request.step?.step, run.roles.contains(role) else {
                return reply(LiveGatewayResponse(error: "No role of this run to list test devices for."))
            }
            let devices = run.allowList.tenants.filter { $0.role == role }.flatMap { $0.testDevices ?? [] }
            return reply(LiveGatewayResponse(status: 200, body: try? JSONEncoder().encode(devices)))
        case Self.waitCommand?:
            // the retry itself arrives a moment after the wait
            let seconds = min(max(request.waitSeconds ?? 0, 0), 600) + 2
            lock.withLock { appWaitsUntil = max(appWaitsUntil, Date().addingTimeInterval(seconds)) }
            return reply(LiveGatewayResponse(status: 204))
        case Self.statusCommand?:
            return reply(LiveGatewayResponse(status: 200, body: try? JSONEncoder().encode(status)))
        case Self.recordCommand?:
            guard let step = request.step else { return reply(LiveGatewayResponse(error: "No step to record.")) }
            run.record(step: step.step, passed: step.passed, note: step.note)
            return reply(LiveGatewayResponse(status: 204))
        case nil:
            break
        case let other?:
            return reply(LiveGatewayResponse(error: "Unknown gateway command \(other)."))
        }
        guard !secretsOnly else {
            return reply(LiveGatewayResponse(error: "This live gateway only hands out the run’s secrets; nothing is sent through it."))
        }
        guard let url = URL(string: request.url) else {
            return reply(LiveGatewayResponse(error: "The live gateway refused a request without an address."))
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = request.body
        lock.withLock { inFlight += 1 }
        let task = run.network.session.dataTask(with: urlRequest) { [weak self] data, response, error in
            defer { self?.lock.withLock { self?.inFlight -= 1; self?.handled += 1 } }
            guard let http = response as? HTTPURLResponse, error == nil else {
                return reply(LiveGatewayResponse(error: Self.failureText(error, refusals: self?.run.network.refusals ?? [])))
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { headers["\(key)"] = "\(value)" }
            reply(LiveGatewayResponse(status: http.statusCode, headers: headers, body: data))
        }
        task.resume()
    }

    /// Why this request failed: its own refusal (nothing was sent), or its
    /// own error, never another request’s refusal. A refusal reaches here
    /// as the session’s error, with the refusal’s own text.
    static func failureText(_ error: (any Error)?, refusals: [LiveRefusal] = []) -> String {
        guard let error else { return "No answer" }
        if let refused = error as? LiveCheckRefused { return "Refused by the live check: \(refused.refusal.reason)" }
        let bridged = error as NSError
        if bridged.domain == LiveCheckRefused.errorDomain, let reason = bridged.userInfo[LiveCheckRefused.reasonKey] as? String {
            return "Refused by the live check: \(reason)"
        }
        let text = error.localizedDescription
        if let own = refusals.last(where: { LiveCheckRefused(refusal: $0).errorDescription == text }) {
            return "Refused by the live check: \(own.reason)"
        }
        return text
    }

    /// The run’s secrets the caller asked for, of the run’s roles only.
    func secrets(for items: [LiveSecretItem]) -> [LiveSecretItem] {
        items.compactMap { item in
            guard run.roles.contains(item.role), let value = credential(item.role, item.item) else { return nil }
            return LiveSecretItem(role: item.role, item: item.item, value: value)
        }
    }

    /// Compares two tokens in time that doesn’t depend on where they differ.
    static func same(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

// MARK: - What the app reads (mirrors JTKit’s LiveLaunch; a JTKit test checks they match)

/// JTKit’s `Connection` as JSON, for one of the release check’s connections.
public struct LiveConnectionDescription: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var service: String
    public var signIn: String
    public var serverURL: String
    public var region: String
    public var environmentID: String
    public var hostOverride: String
    public var jamfProWebURL: String
    public var clientID: String
    public var username: String
    public var tenantID: String
    public var keyID: String

    /// The role, not encoded (`LiveLaunchFile.Entry` carries it).
    public var role: String = ""
    /// The release check’s item holding this connection’s secret, e.g.
    /// "client-secret", or "jamfpro-password" for a role’s Jamf Pro
    /// sign-in beside its Platform API one. Not encoded (the entry carries it).
    public var secretItem: String?

    enum CodingKeys: String, CodingKey {
        case id, name, service, signIn, serverURL, region, environmentID, hostOverride, jamfProWebURL, clientID, username, tenantID, keyID
    }

    public init(id: UUID = UUID(), name: String, service: String, signIn: String, serverURL: String = "", region: String = "us",
                environmentID: String = "", hostOverride: String = "", jamfProWebURL: String = "", clientID: String = "",
                username: String = "", tenantID: String = "", keyID: String = "") {
        self.id = id
        self.name = name
        self.service = service
        self.signIn = signIn
        self.serverURL = serverURL
        self.region = region
        self.environmentID = environmentID
        self.hostOverride = hostOverride
        self.jamfProWebURL = jamfProWebURL
        self.clientID = clientID
        self.username = username
        self.tenantID = tenantID
        self.keyID = keyID
        role = name
        secretItem = Self.defaultSecretItem(signIn)
    }

    /// An allow-list entry as a connection, named after its role (and its
    /// service, when the role has two entries), with the non-secret values
    /// the release check read (client ID, username, Network ID, key ID), and
    /// an ID that is the same in every launch (`stableID`).
    ///
    /// A role with two entries (a Platform API and a Jamf Pro one) keeps
    /// its Jamf Pro sign-in under `jamfpro-username` / `jamfpro-password`
    /// (or `jamfpro-client-id` / `jamfpro-client-secret`), as the apps’
    /// `CREDENTIALS` name them; a role with one entry uses the plain names.
    init(entry: AllowList.Entry, run: LiveCheckRun, sharesRole: Bool = false,
         credential lookup: ((String) -> String)? = nil) {
        func credential(_ item: String) -> String { lookup?(item) ?? (try? run.credential(entry.role, item)) ?? "" }
        let name = sharesRole ? "\(entry.role) (\(Self.serviceName(entry.service)))" : entry.role
        let id = Self.stableID(role: entry.role, service: sharesRole ? entry.service.rawValue : nil)
        var item: String?
        switch entry.service {
        case .jamfPlatform:
            self.init(id: id, name: name, service: "jamfPlatform", signIn: "apiClient", region: (entry.region ?? "us").lowercased(),
                      environmentID: entry.environmentID ?? "", clientID: credential("client-id"))
        case .jamfPro:
            // the role's Jamf Pro items first; the plain names only for a role of one entry
            let ownUser = credential("jamfpro-username"), ownClient = credential("jamfpro-client-id")
            let username = ownUser.isEmpty && !sharesRole ? credential("username") : ownUser
            let clientID = ownClient.isEmpty && !sharesRole ? credential("client-id") : ownClient
            self.init(id: id, name: name, service: "jamfPro", signIn: username.isEmpty ? "apiClient" : "usernamePassword",
                      serverURL: "https://\(entry.host ?? "")", clientID: username.isEmpty ? clientID : "", username: username)
            if !username.isEmpty {
                item = ownUser.isEmpty && !sharesRole ? "password" : "jamfpro-password"
            } else {
                item = ownClient.isEmpty && !sharesRole ? "client-secret" : "jamfpro-client-secret"
            }
        case .jamfSchool:
            self.init(id: id, name: name, service: "jamfSchool", signIn: "schoolAPIKey", serverURL: "https://\(entry.host ?? "")",
                      clientID: credential("network-id"))
        case .intune:
            self.init(id: id, name: name, service: "intune", signIn: "entraClientSecret", clientID: credential("client-id"),
                      tenantID: entry.entraTenantID ?? "")
        case .appleBusinessManager, .appleSchoolManager:
            self.init(id: id, name: name, service: entry.service.rawValue, signIn: "applePrivateKey",
                      clientID: entry.clientID ?? "", keyID: credential("key-id"))
        }
        role = entry.role
        if let item { secretItem = item }
    }

    static func serviceName(_ service: AllowList.Service) -> String {
        switch service {
        case .jamfPlatform: "Jamf Platform API"
        case .jamfPro: "Jamf Pro"
        case .jamfSchool: "Jamf School"
        case .intune: "Intune"
        case .appleBusinessManager: "Apple Business"
        case .appleSchoolManager: "Apple School Manager"
        }
    }

    /// The same ID for a role (and service) in every launch, as JTKit’s
    /// `LiveLaunch.connectionID(role:service:)`: a choice the app made in a
    /// run (the connection in use) still matches in the next.
    public static func stableID(role: String, service: String? = nil) -> UUID {
        var bytes = Array((service.map { "jtkit-live:\(role)/\($0)" } ?? "jtkit-live:\(role)").utf8)
        while bytes.count < 16 { bytes.append(0) }
        var folded = [UInt8](repeating: 0, count: 16)
        for (index, byte) in bytes.enumerated() { folded[index % 16] = folded[index % 16] &* 31 &+ byte }
        folded[6] = (folded[6] & 0x0f) | 0x40
        folded[8] = (folded[8] & 0x3f) | 0x80
        return UUID(uuid: (folded[0], folded[1], folded[2], folded[3], folded[4], folded[5], folded[6], folded[7],
                           folded[8], folded[9], folded[10], folded[11], folded[12], folded[13], folded[14], folded[15]))
    }

    /// The release check’s name for a sign-in’s secret (as JTKit’s `LiveLaunch.secretItem`).
    static func defaultSecretItem(_ signIn: String) -> String? {
        switch signIn {
        case "apiClient", "entraClientSecret": "client-secret"
        case "usernamePassword": "password"
        case "schoolAPIKey": "api-key"
        case "applePrivateKey": "private-key"
        default: nil
        }
    }
}

/// One secret of the run, asked for and handed over with the gateway’s token.
public struct LiveSecretItem: Codable, Sendable, Equatable {
    public var role: String
    public var item: String
    /// Empty in a request.
    public var value: String

    public init(role: String, item: String, value: String = "") {
        self.role = role
        self.item = item
        self.value = value
    }
}

/// JTKit’s `LiveLaunch.LaunchFile`.
public struct LiveLaunchFile: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var role: String
        public var connection: LiveConnectionDescription
        /// Which of the run’s items holds this connection’s secret.
        public var secretItem: String?
        /// The role lists test devices for this run (1.3.2): the only
        /// connections an app may send a device command through.
        public var receivesCommands: Bool?

        public init(role: String, connection: LiveConnectionDescription, secretItem: String? = nil,
                    receivesCommands: Bool? = nil) {
            self.role = role
            self.receivesCommands = receivesCommands
            var connection = connection
            connection.role = role
            if let secretItem { connection.secretItem = secretItem }
            self.connection = connection
            self.secretItem = secretItem ?? connection.secretItem
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let role = try container.decode(String.self, forKey: .role)
            let connection = try container.decode(LiveConnectionDescription.self, forKey: .connection)
            self.init(role: role, connection: connection, secretItem: try container.decodeIfPresent(String.self, forKey: .secretItem),
                      receivesCommands: try container.decodeIfPresent(Bool.self, forKey: .receivesCommands))
        }
    }

    public var port: UInt16
    public var lockOwner: String
    public var connections: [Entry]
}

/// JTKit’s `LiveGatewayFrame.Request`, plus the UI test’s commands.
public struct LiveGatewayRequest: Codable, Sendable {
    public var token: String
    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: Data?
    /// `status`, `record`, `secrets` or `wait`; nil for a request to send.
    public var command: String?
    public var step: LiveCheckRun.StepResult?
    /// For `secrets`: the items asked.
    public var secrets: [LiveSecretItem]?
    /// For `wait`: how long the app waits before trying again.
    public var waitSeconds: Double?

    public init(token: String, method: String = "GET", url: String = "", headers: [String: String] = [:], body: Data? = nil,
                command: String? = nil, step: LiveCheckRun.StepResult? = nil, secrets: [LiveSecretItem]? = nil,
                waitSeconds: Double? = nil) {
        self.secrets = secrets
        self.waitSeconds = waitSeconds
        self.token = token
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.command = command
        self.step = step
    }
}

/// JTKit’s `LiveGatewayFrame.Response`.
public struct LiveGatewayResponse: Codable, Sendable {
    public var status: Int?
    public var headers: [String: String]?
    public var body: Data?
    public var error: String?

    public init(status: Int? = nil, headers: [String: String]? = nil, body: Data? = nil, error: String? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.error = error
    }
}

/// The gateway’s view of the run, for the UI test’s checks.
public struct LiveGatewayStatus: Codable, Sendable, Equatable {
    public var pending: Int
    public var handled: Int
    public var refusals: [LiveRefusal]
    /// Attempts to reach a saved connection or a real Keychain item.
    public var violations: [String]
    /// The run’s objects not confirmed removed, and creates outside the ledger.
    public var notRemoved: [String]
}

final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.withLock { stored } }
    func set(_ value: String) { lock.withLock { stored = value } }
}
