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
public final class LiveGateway: @unchecked Sendable {
    public let run: LiveCheckRun
    /// The port on 127.0.0.1.
    public private(set) var port: UInt16 = 0
    let token = UUID().uuidString + UUID().uuidString
    /// The connections written for the app, by role.
    public private(set) var connections: [LiveConnectionDescription] = []
    /// The variables the app is launched with: the token and each role’s secret.
    public private(set) var environment: [String: String] = [:]

    private let listener: NWListener
    private let queue = DispatchQueue(label: "JTKitUITestSupport.live-gateway", attributes: .concurrent)
    private let lock = NSLock()
    private var inFlight = 0
    private var handled = 0

    public enum GatewayError: Error, CustomStringConvertible, Equatable {
        case notLocked
        case couldNotListen(String)
        case unknownRole(String)

        public var description: String {
            switch self {
            case .notLocked: "Live UI tests run only while a release check holds its lock"
            case .couldNotListen(let reason): "The live gateway couldn’t start: \(reason)"
            case .unknownRole(let role): "\(role) isn’t a role of this run"
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
    public init(run: LiveCheckRun, roles: [String]? = nil, lockOwnerURL: URL = LiveGateway.defaultLockOwnerURL) throws {
        self.run = run
        let owner = (try? String(contentsOf: lockOwnerURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !owner.isEmpty else { throw GatewayError.notLocked }

        var described: [LiveConnectionDescription] = []
        var variables: [String: String] = ["JTKIT_LIVE_GATEWAY_TOKEN": token]
        for role in roles ?? run.roles.sorted() {
            let entries = run.allowList.tenants.filter { $0.role == role }
            guard run.roles.contains(role), !entries.isEmpty else { throw GatewayError.unknownRole(role) }
            for entry in entries {
                let connection = LiveConnectionDescription(entry: entry, run: run)
                described.append(connection)
                if let item = connection.secretItem, let secret = try? run.credential(role, item) {
                    variables[LiveCheckRun.variable(role: role, item: item)] = secret
                }
            }
        }
        connections = described
        environment = variables

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
                                    connections: described.map { .init(role: $0.role, connection: $0) })
        try FileManager.default.createDirectory(at: run.runFolder, withIntermediateDirectories: true)
        let file = run.runFolder.appending(path: Self.launchFileName)
        try JSONEncoder().encode(launch).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let tokenFile = run.runFolder.appending(path: Self.tokenFileName)
        FileManager.default.createFile(atPath: tokenFile.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
    }

    deinit { listener.cancel() }

    /// Stops listening and removes `live-launch.json` and the token, so the
    /// run folder can’t start another app.
    public func stop() {
        listener.cancel()
        try? FileManager.default.removeItem(at: run.runFolder.appending(path: Self.launchFileName))
        try? FileManager.default.removeItem(at: run.runFolder.appending(path: Self.tokenFileName))
    }

    public static let launchFileName = "live-launch.json"
    public static let tokenFileName = "live-gateway.token"
    public static let violationsFileName = "live-violations.jsonl"

    /// What a live UI test asks the gateway (`LiveGatewayRequest.command`).
    public static let statusCommand = "status"
    public static let recordCommand = "record"

    /// What the gateway knows of the run now.
    public var status: LiveGatewayStatus {
        let unrecorded = LiveCheckNetwork.unrecordedCreates(in: run.runFolder.appending(path: LiveCheckRun.unrecordedCreatesFileName))
        return LiveGatewayStatus(
            pending: pendingRequests, handled: handledRequests, refusals: run.network.refusals, violations: violations,
            notRemoved: run.notRemoved.map { "\($0.resource) \($0.id) “\($0.name)”" }
                + unrecorded.map { "\($0.resource) “\($0.name)” (created but not in the ledger: \($0.reason))" }
                + (run.ledger.saveFailure.map { [$0] } ?? []))
    }

    /// Requests being decided or sent now.
    public var pendingRequests: Int { lock.withLock { inFlight } }

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
                // a refusal names its reason; nothing was sent
                let refusal = self?.run.network.refusals.last.map { "Refused by the live check: \($0.reason)" }
                return reply(LiveGatewayResponse(error: refusal ?? error?.localizedDescription ?? "No answer"))
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields { headers["\(key)"] = "\(value)" }
            reply(LiveGatewayResponse(status: http.statusCode, headers: headers, body: data))
        }
        task.resume()
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
    public var role: String { name }

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
    }

    /// An allow-list entry as a connection, named after its role, with the
    /// non-secret values the release check read (client ID, username,
    /// Network ID, key ID).
    init(entry: AllowList.Entry, run: LiveCheckRun) {
        func credential(_ item: String) -> String { (try? run.credential(entry.role, item)) ?? "" }
        switch entry.service {
        case .jamfPlatform:
            self.init(name: entry.role, service: "jamfPlatform", signIn: "apiClient", region: entry.region ?? "us",
                      environmentID: entry.environmentID ?? "", clientID: credential("client-id"))
        case .jamfPro:
            let username = credential("username")
            self.init(name: entry.role, service: "jamfPro", signIn: username.isEmpty ? "apiClient" : "usernamePassword",
                      serverURL: "https://\(entry.host ?? "")", clientID: credential("client-id"), username: username)
        case .jamfSchool:
            self.init(name: entry.role, service: "jamfSchool", signIn: "schoolAPIKey", serverURL: "https://\(entry.host ?? "")",
                      clientID: credential("network-id"))
        case .intune:
            self.init(name: entry.role, service: "intune", signIn: "entraClientSecret", clientID: credential("client-id"),
                      tenantID: entry.entraTenantID ?? "")
        case .appleBusinessManager, .appleSchoolManager:
            self.init(name: entry.role, service: entry.service.rawValue, signIn: "applePrivateKey",
                      clientID: entry.clientID ?? "", keyID: credential("key-id"))
        }
    }

    /// The release check’s name for this sign-in’s secret (as JTKit’s `LiveLaunch.secretItem`).
    public var secretItem: String? {
        switch signIn {
        case "apiClient", "entraClientSecret": "client-secret"
        case "usernamePassword": "password"
        case "schoolAPIKey": "api-key"
        case "applePrivateKey": "private-key"
        default: nil
        }
    }
}

/// JTKit’s `LiveLaunch.LaunchFile`.
public struct LiveLaunchFile: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var role: String
        public var connection: LiveConnectionDescription
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
    /// `status` or `record`; nil for a request to send.
    public var command: String?
    public var step: LiveCheckRun.StepResult?

    public init(token: String, method: String = "GET", url: String = "", headers: [String: String] = [:], body: Data? = nil,
                command: String? = nil, step: LiveCheckRun.StepResult? = nil) {
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
