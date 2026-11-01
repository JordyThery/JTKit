import Foundation
import Network
import os

/// The launch switch for live UI tests (1.1.0, B1): `-JTKitLiveCheck <run folder>`.
///
/// The release check’s live UI test launches the real app with it. The app
/// then sends every request JTKit makes to the test’s gateway on this Mac
/// (`JTKitUITestSupport`’s `LiveGateway`), which decides each one by the
/// release check’s rules (allow-list, ledger, prefix, access levels) before
/// anything leaves the Mac; the app itself holds none of those rules. It
/// uses only the release check’s connections (from the run folder, their
/// secrets from the test’s environment), never its saved ones, with demo
/// mode and the update check off.
///
/// It works only:
/// - in a Debug build (in a Release build the switch is refused);
/// - while a release check holds its lock (the gateway writes the lock’s
///   owner into the run folder; where the app can read the lock itself, the
///   two must match);
/// - with the allow-list present (its own place, or the run’s copy).
///
/// Refused, the app reaches nothing: every request fails before it is sent.
/// Under the switch, refused or not, a saved connection or a real Keychain
/// item is never reached: each attempt is refused and written to the run
/// folder’s `live-violations.jsonl`, which fails the run.
public nonisolated enum LiveLaunch {
    public static let argument = "-JTKitLiveCheck"
    /// Written by the gateway into the run folder: port, lock owner, connections.
    public static let launchFileName = "live-launch.json"
    /// Every attempt to reach a saved connection or a real Keychain item.
    public static let violationsFileName = "live-violations.jsonl"
    /// The gateway’s token, in the app’s environment only.
    public static let tokenVariable = "JTKIT_LIVE_GATEWAY_TOKEN"

    /// The release check’s lock owner (`release-check-lib.sh`’s `RC_LOCK.owner`).
    public static var defaultLockOwnerURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/JTKit Release Check/state/release-check.lock.owner")
    }

    /// The allow-list’s own place (`JTKitLiveCheck`’s `AllowList.defaultURL`).
    public static var defaultAllowListURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/JTKit Release Check/allowlist.json")
    }

    /// What the gateway writes into the run folder: no secret.
    public struct LaunchFile: Codable, Sendable, Equatable {
        public struct Entry: Codable, Sendable, Equatable {
            /// The allow-list role, e.g. "jamf-test-a".
            public var role: String
            public var connection: Connection

            public init(role: String, connection: Connection) {
                self.role = role
                self.connection = connection
            }
        }

        public var port: UInt16
        /// The release check’s lock owner when the gateway started, e.g. "4123 Blueprint Managed Preferences Editor".
        public var lockOwner: String
        public var connections: [Entry]

        public init(port: UInt16, lockOwner: String, connections: [Entry]) {
            self.port = port
            self.lockOwner = lockOwner
            self.connections = connections
        }
    }

    /// The switch on, and where to send.
    public struct Active: Sendable, Equatable {
        public var runFolder: URL
        public var port: UInt16
        var token: String
        public var connections: [LaunchFile.Entry]
        /// Secrets by connection ID and kind, from the environment.
        var secrets: [UUID: String]
    }

    public enum State: Sendable, Equatable {
        /// No switch: an ordinary launch.
        case off
        case active(Active)
        /// The switch was given but can’t be used: nothing is reached.
        case refused(String)
    }

    /// This launch’s state, worked out once.
    public static var state: State { testState ?? launchState }

    private static let launchState: State = evaluate(arguments: ProcessInfo.processInfo.arguments,
                                                     environment: ProcessInfo.processInfo.environment)

    /// Tests only: the state inside `LiveLaunch.$testState.withValue(…)`.
    @TaskLocal static var testState: State?

    /// The switch was given (on or refused): saved connections and real
    /// Keychain items are never reached.
    public static var isSwitched: Bool { state != .off }

    public static var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    /// The release check’s connections, in the order the gateway listed them.
    public static var connections: [Connection] {
        guard case .active(let active) = state else { return [] }
        return active.connections.map(\.connection)
    }

    /// Whether this build may use the switch.
    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// - Parameters:
    ///   - isDebugBuild: this build’s, by default; tests pass false for a Release build.
    ///   - lockOwnerURL, allowListURL: their own places by default; tests pass their own.
    static func evaluate(arguments: [String], environment: [String: String], isDebugBuild: Bool = LiveLaunch.isDebugBuild,
                         lockOwnerURL: URL = defaultLockOwnerURL, allowListURL: URL = defaultAllowListURL) -> State {
        guard let index = arguments.lastIndex(of: argument) else { return .off }
        guard isDebugBuild else { return .refused("The live-check switch works only in a Debug build.") }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("-") else {
            return .refused("The live-check switch needs the run folder after \(argument).")
        }
        let folder = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .refused("The live-check run folder doesn’t exist.")
        }
        let manager = FileManager.default
        guard manager.isReadableFile(atPath: allowListURL.path)
                || manager.isReadableFile(atPath: folder.appending(path: "allowlist.json").path) else {
            return .refused("The live-check switch works only with the allow-list present.")
        }
        guard let data = try? Data(contentsOf: folder.appending(path: launchFileName)),
              let launch = try? JSONDecoder().decode(LaunchFile.self, from: data) else {
            return .refused("The live check’s gateway isn’t running: \(launchFileName) is missing.")
        }
        let owner = launch.lockOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty else {
            return .refused("The live-check switch works only while a release check holds its lock.")
        }
        // Outside an app’s sandbox the lock itself is read: it must be held,
        // by the same release check. A sandboxed app can’t read it; the
        // gateway checked it before writing the run folder.
        if environment["APP_SANDBOX_CONTAINER_ID"] == nil {
            let current = (try? String(contentsOf: lockOwnerURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard current == owner else {
                return .refused("The live-check switch works only while a release check holds its lock.")
            }
        }
        guard let token = environment[tokenVariable], !token.isEmpty, launch.port > 0 else {
            return .refused("The live check’s gateway didn’t pass its token.")
        }
        // the roles the UI test gave this app (all of the run’s by default)
        let roles = Set((environment["JTKIT_LIVE_APP_ROLES"] ?? "").split(separator: ",").map(String.init))
        let connections = roles.isEmpty ? launch.connections : launch.connections.filter { roles.contains($0.role) }
        var secrets: [UUID: String] = [:]
        for entry in connections {
            if let item = secretItem(entry.connection.signIn), let value = environment[variable(role: entry.role, item: item)] {
                secrets[entry.connection.id] = value
            }
        }
        return .active(Active(runFolder: folder, port: launch.port, token: token, connections: connections, secrets: secrets))
    }

    /// The release check’s name for a sign-in method’s secret, e.g. "client-secret".
    static func secretItem(_ method: SignInMethod) -> String? {
        switch method {
        case .apiClient, .entraClientSecret: "client-secret"
        case .usernamePassword: "password"
        case .schoolAPIKey: "api-key"
        case .applePrivateKey: "private-key"
        case .microsoftInteractive: nil
        }
    }

    /// `JTKIT_LIVE_JAMF_TEST_A_CLIENT_SECRET`, as `JTKitLiveCheck`’s `LiveCheckRun.variable`.
    public static func variable(role: String, item: String) -> String {
        "JTKIT_LIVE_" + "\(role)_\(item)".uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.map(String.init).joined()
    }

    /// The same stable ID for a role in every launch, so a choice the app
    /// made in a run (the connection in use) still matches.
    public static func connectionID(role: String) -> UUID {
        var bytes = Array("jtkit-live:\(role)".utf8)
        while bytes.count < 16 { bytes.append(0) }
        var folded = [UInt8](repeating: 0, count: 16)
        for (index, byte) in bytes.enumerated() { folded[index % 16] = folded[index % 16] &* 31 &+ byte }
        folded[6] = (folded[6] & 0x0f) | 0x40
        folded[8] = (folded[8] & 0x3f) | 0x80
        return UUID(uuid: (folded[0], folded[1], folded[2], folded[3], folded[4], folded[5], folded[6], folded[7],
                           folded[8], folded[9], folded[10], folded[11], folded[12], folded[13], folded[14], folded[15]))
    }

    // MARK: Secrets

    /// The release check’s secrets, in memory: what the connection store
    /// uses under the switch instead of the app’s Keychain items. Writes are refused.
    public static var secrets: any SecretStore { LiveSecretStore() }

    struct LiveSecretStore: SecretStore {
        func secret(for account: String) -> String? {
            guard case .active(let active) = LiveLaunch.state, let id = UUID(uuidString: account) else { return nil }
            return active.secrets[id]
        }

        func setSecret(_ secret: String?, for account: String) -> Bool {
            LiveLaunch.recordViolation("a secret was saved for \(account)")
            return false
        }
    }

    // MARK: Network

    /// The session a request goes out on: the gateway’s under the switch,
    /// a session that sends nothing when the switch is refused, else `session`.
    static func route(_ session: URLSession) -> URLSession {
        switch state {
        case .off: return session
        case .active(let active): return gatewaySession(active)
        case .refused(let reason): return refusedSession(reason)
        }
    }

    private static let sessions = LiveLocked<[String: URLSession]>([:])

    private static func gatewaySession(_ active: Active) -> URLSession {
        sessions.withLock { cached in
            let key = "gateway:\(active.port)"
            if let session = cached[key] { return session }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LiveGatewayURLProtocol.self]
            // where to send, read (and removed) by the protocol, never forwarded
            configuration.httpAdditionalHeaders = [LiveGatewayURLProtocol.routeHeader: "\(active.port) \(active.token)"]
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            // the gateway may read an object back before a write answers
            configuration.timeoutIntervalForRequest = 600
            let session = URLSession(configuration: configuration)
            cached[key] = session
            return session
        }
    }

    private static func refusedSession(_ reason: String) -> URLSession {
        sessions.withLock { cached in
            if let session = cached["refused"] { return session }
            let log = TestRun.AttemptLog(fileURL: TestRun.attemptsFolder(named: "JTKitLiveCheck").appending(path: "refused.jsonl"))
            let session = TestRun.refusingSession(log: log, kind: "live-check switch refused", message: reason)
            cached["refused"] = session
            return session
        }
    }

    /// The error of a saved connection reached under the switch.
    public struct SavedConnectionsRefused: LocalizedError, Equatable, Sendable {
        public var errorDescription: String? {
            "Saved connections are never used under the live-check switch."
        }
    }

    /// Refuses, and writes down, an attempt to reach the app’s saved connections.
    static func refuseSavedConnections(_ action: String, _ what: String) throws {
        guard isSwitched else { return }
        recordViolation("saved connections \(what) \(action)")
        throw SavedConnectionsRefused()
    }

    // MARK: Violations

    private static let logger = Logger(subsystem: "JTKit", category: "LiveLaunch")

    /// Writes an attempt to reach a saved connection or a real Keychain item
    /// to the run folder (or, refused, the attempts folder); the run fails on any.
    public static func recordViolation(_ what: String) {
        logger.error("Refused under the live-check switch: \(what, privacy: .private)")
        let file: URL
        switch state {
        case .off: return
        case .active(let active): file = active.runFolder.appending(path: violationsFileName)
        case .refused: file = TestRun.attemptsFolder(named: "JTKitLiveCheck").appending(path: violationsFileName)
        }
        TestRun.AttemptLog(fileURL: file).record("Refused under the live-check switch: \(what)")
    }
}

/// A value behind a lock.
nonisolated final class LiveLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

// MARK: - The wire to the gateway

/// One request to the gateway and its answer, as JSON after a 4-byte
/// big-endian length. `JTKitUITestSupport` has the same two types.
nonisolated enum LiveGatewayFrame {
    struct Request: Codable, Sendable {
        var token: String
        var method: String
        var url: String
        var headers: [String: String]
        var body: Data?
    }

    struct Response: Codable, Sendable {
        var status: Int?
        var headers: [String: String]?
        var body: Data?
        /// Why the gateway didn’t send it, or why it failed.
        var error: String?
    }

    static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        return Data(bytes: &length, count: 4) + payload
    }
}

/// Sends each request of a gateway session to the gateway over a local
/// connection and hands back its answer.
nonisolated final class LiveGatewayURLProtocol: URLProtocol, @unchecked Sendable {
    static let routeHeader = "X-JTKit-Live-Gateway"
    private let state = LiveLocked<NWConnection?>(nil)
    /// The client hears once: an answer or a failure.
    private let answered = LiveLocked(false)

    private func once() -> Bool {
        answered.withLock { done in
            defer { done = true }
            return !done
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let route = (request.value(forHTTPHeaderField: Self.routeHeader) ?? "").split(separator: " ", maxSplits: 1).map(String.init)
        guard let url = request.url, route.count == 2, let port = UInt16(route[0]), let endpoint = NWEndpoint.Port(rawValue: port) else {
            fail("The live check’s gateway isn’t set up.")
            return
        }
        let token = route[1]
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        var headers = request.allHTTPHeaderFields ?? [:]
        headers = headers.filter { $0.key.caseInsensitiveCompare(Self.routeHeader) != .orderedSame }
        let frame = LiveGatewayFrame.Request(token: token, method: request.httpMethod ?? "GET", url: url.absoluteString,
                                             headers: headers, body: body.isEmpty ? nil : body)
        guard let payload = try? JSONEncoder().encode(frame) else {
            fail("The request couldn’t be passed to the live check’s gateway.")
            return
        }
        let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        state.withLock { $0 = connection }
        connection.stateUpdateHandler = { [weak self] newState in
            guard let self else { return }
            switch newState {
            case .ready:
                connection.send(content: LiveGatewayFrame.frame(payload), completion: .contentProcessed { error in
                    if let error { self.fail("The live check’s gateway can’t be reached: \(error.localizedDescription)") }
                })
                self.receive(on: connection)
            case .failed(let error):
                self.fail("The live check’s gateway can’t be reached: \(error.localizedDescription)")
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let self else { return }
            guard let header, header.count == 4, error == nil else {
                self.fail("The live check’s gateway didn’t answer.")
                return
            }
            let length = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
            self.receiveBody(on: connection, length: length, collected: Data())
        }
    }

    private func receiveBody(on connection: NWConnection, length: Int, collected: Data) {
        guard collected.count < length else {
            finish(with: collected)
            connection.cancel()
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: length - collected.count) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, error == nil else {
                self.fail("The live check’s gateway didn’t answer.")
                return
            }
            self.receiveBody(on: connection, length: length, collected: collected + data)
        }
    }

    private func finish(with payload: Data) {
        guard let answer = try? JSONDecoder().decode(LiveGatewayFrame.Response.self, from: payload) else {
            fail("The live check’s gateway answered something unreadable.")
            return
        }
        if let error = answer.error {
            fail(error)
            return
        }
        guard let url = request.url, let status = answer.status,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: answer.headers) else {
            fail("The live check’s gateway answered without a status.")
            return
        }
        guard once() else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ message: String) {
        guard once() else { return }
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable, userInfo: [NSLocalizedDescriptionKey: message]))
    }

    override func stopLoading() {
        state.withLock { $0?.cancel(); $0 = nil }
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
