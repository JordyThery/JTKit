import Foundation
import Network

/// A live UI test’s side of the gateway (1.1.0, B4): what it reads from the
/// run folder (the gateway’s port, token and the release check’s
/// connections) and a session whose requests go through the gateway, for
/// the test’s own objects. It reads files only and makes outgoing
/// connections only, both of which a sandboxed UI test runner may.
public final class LiveGatewayClient: @unchecked Sendable {
    /// The run’s folder as this process can read it: the runner folder when
    /// one was given (a sandboxed app’s UI test runner), which holds the
    /// gateway’s files and a copy of the ledger; the run folder otherwise.
    public let runFolder: URL
    /// The run folder the app is launched with (`-JTKitLiveCheck`): for a
    /// sandboxed app the one in its container.
    public let appRunFolder: URL
    public let launch: LiveLaunchFile
    let token: String
    /// Requests sent on it go through the gateway’s rules.
    public let session: URLSession

    public enum ClientError: Error, CustomStringConvertible {
        case notRunning(String)
        case failed(String)

        public var description: String {
            switch self {
            case .notRunning(let reason): "The live gateway isn’t running: \(reason)"
            case .failed(let reason): reason
            }
        }
    }

    /// - Parameters:
    ///   - runFolder: the release check’s live folder (`JTKIT_LIVE_RUN_DIR`),
    ///     the one the app is launched with.
    ///   - gatewayFolder: where to read the launch file and token instead,
    ///     for a UI test runner that can’t read the run folder (a sandboxed
    ///     app’s container; `JTKIT_LIVE_RUNNER_DIR`).
    public init(runFolder: URL, gatewayFolder: URL? = nil) throws {
        self.appRunFolder = runFolder
        self.runFolder = gatewayFolder ?? runFolder
        let folder = self.runFolder
        let place = gatewayFolder == nil ? "the run folder" : "the runner folder"
        guard let data = try? Data(contentsOf: folder.appending(path: LiveGateway.launchFileName)),
              let launch = try? JSONDecoder().decode(LiveLaunchFile.self, from: data) else {
            throw ClientError.notRunning("no \(LiveGateway.launchFileName) in \(place)")
        }
        guard let token = try? String(contentsOf: folder.appending(path: LiveGateway.tokenFileName), encoding: .utf8),
              !token.isEmpty else {
            throw ClientError.notRunning("no \(LiveGateway.tokenFileName) in \(place)")
        }
        self.launch = launch
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveGatewayClientProtocol.self]
        configuration.httpAdditionalHeaders = [LiveGatewayClientProtocol.routeHeader: "\(launch.port) \(token)"]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 600
        session = URLSession(configuration: configuration)
    }

    /// The variables an app is launched with under the switch: the token
    /// and the roles it gets. No secret: the app asks the gateway for its
    /// connections’ secrets with the token, so they never reach a launch
    /// environment (Xcode keeps those in the test’s result bundle).
    public func appEnvironment(roles: [String], from environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        ["JTKIT_LIVE_GATEWAY_TOKEN": token, "JTKIT_LIVE_APP_ROLES": roles.joined(separator: ",")]
    }

    /// A secret of the run, from the gateway.
    public func secret(role: String, item: String) async throws -> String? {
        let request = LiveGatewayRequest(token: token, command: LiveGateway.secretsCommand,
                                         secrets: [LiveSecretItem(role: role, item: item)])
        let answer = try await Self.exchange(request, port: launch.port)
        if let error = answer.error { throw ClientError.failed(error) }
        guard let body = answer.body, let items = try? JSONDecoder().decode([LiveSecretItem].self, from: body) else { return nil }
        return items.first { $0.role == role && $0.item == item }?.value
    }

    /// The same, waiting for the answer (up to `timeout`), for code that
    /// can’t await; not on the queue the gateway answers on.
    public func secretNow(role: String, item: String, timeout: TimeInterval = 15) throws -> String? {
        let box = SecretBox()
        let done = DispatchSemaphore(value: 0)
        let request = LiveGatewayRequest(token: token, command: LiveGateway.secretsCommand,
                                         secrets: [LiveSecretItem(role: role, item: item)])
        let connection = Self.exchange(request, port: launch.port) { result in
            box.set(result)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            connection?.cancel()
            throw ClientError.failed("The live gateway didn’t hand over \(item) for \(role)")
        }
        let answer = try box.get()
        if let error = answer.error { throw ClientError.failed(error) }
        guard let body = answer.body, let items = try? JSONDecoder().decode([LiveSecretItem].self, from: body) else { return nil }
        return items.first { $0.role == role && $0.item == item }?.value
    }

    /// Hands the gateway credentials read from the app’s own saved
    /// connections (1.3.1), for roles whose credentials the release check
    /// doesn’t read itself. Never printed or written to a file; the gateway
    /// keeps them in memory and never takes one in place of its own.
    /// - Returns: the items it took, "role|item".
    @discardableResult
    public func provide(_ items: [LiveSecretItem]) async throws -> [String] {
        let request = LiveGatewayRequest(token: token, command: LiveGateway.provideCommand, secrets: items)
        let answer = try await Self.exchange(request, port: launch.port)
        if let error = answer.error { throw ClientError.failed(error) }
        guard let body = answer.body, let taken = try? JSONDecoder().decode([String].self, from: body) else { return [] }
        return taken
    }

    /// The allow-list’s test devices of a role of this run, for a UI test
    /// runner that can’t read the allow-list (a sandboxed runner).
    public func testDevices(role: String) async throws -> [AllowList.TestDevice] {
        let request = LiveGatewayRequest(token: token, command: LiveGateway.testDevicesCommand,
                                         step: LiveCheckRun.StepResult(step: role, passed: true, note: nil))
        let answer = try await Self.exchange(request, port: launch.port)
        if let error = answer.error { throw ClientError.failed(error) }
        guard let body = answer.body else { return [] }
        return (try? JSONDecoder().decode([AllowList.TestDevice].self, from: body)) ?? []
    }

    /// What the gateway knows of the run now.
    public func status() async throws -> LiveGatewayStatus {
        let answer = try await Self.exchange(LiveGatewayRequest(token: token, command: LiveGateway.statusCommand), port: launch.port)
        if let error = answer.error { throw ClientError.failed(error) }
        guard let body = answer.body, let status = try? JSONDecoder().decode(LiveGatewayStatus.self, from: body) else {
            throw ClientError.failed("The live gateway sent no status")
        }
        return status
    }

    /// Adds a step’s result to the run’s report (the gateway writes it).
    public func record(step: String, passed: Bool, note: String? = nil) async throws {
        let request = LiveGatewayRequest(token: token, command: LiveGateway.recordCommand,
                                         step: LiveCheckRun.StepResult(step: LiveCheckRun.redacted(step), passed: passed,
                                                                       note: note.map { LiveCheckRun.redacted($0) }))
        let answer = try await Self.exchange(request, port: launch.port)
        if let error = answer.error { throw ClientError.failed(error) }
    }

    /// One request and its answer, framed as JTKit’s app side frames them.
    static func exchange(_ request: LiveGatewayRequest, port: UInt16) async throws -> LiveGatewayResponse {
        try await withCheckedThrowingContinuation { continuation in
            exchange(request, port: port) { continuation.resume(with: $0) }
        }
    }

    /// The same with a completion, called once.
    @discardableResult
    static func exchange(_ request: LiveGatewayRequest, port: UInt16,
                         completion: @escaping @Sendable (Result<LiveGatewayResponse, Error>) -> Void) -> NWConnection? {
        guard let payload = try? JSONEncoder().encode(request), let endpoint = NWEndpoint.Port(rawValue: port) else {
            completion(.failure(ClientError.notRunning("no port")))
            return nil
        }
        let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        let once = Once()
        @Sendable func finish(_ result: Result<LiveGatewayResponse, Error>) {
            guard once.first() else { return }
            connection.cancel()
            completion(result)
        }
        @Sendable func receive(_ length: Int, _ collected: Data, _ done: @escaping @Sendable (Data?) -> Void) {
            guard collected.count < length else { return done(collected) }
            connection.receive(minimumIncompleteLength: 1, maximumLength: length - collected.count) { data, _, isComplete, error in
                guard let data, error == nil, !(data.isEmpty && isComplete) else { return done(nil) }
                receive(length, collected + data, done)
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var length = UInt32(payload.count).bigEndian
                connection.send(content: Data(bytes: &length, count: 4) + payload, completion: .contentProcessed { error in
                    if let error { finish(.failure(ClientError.notRunning(error.localizedDescription))) }
                })
                receive(4, Data()) { header in
                    guard let header else { return finish(.failure(ClientError.failed("The live gateway didn’t answer"))) }
                    let size = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
                    receive(size, Data()) { body in
                        guard let body, let answer = try? JSONDecoder().decode(LiveGatewayResponse.self, from: body) else {
                            return finish(.failure(ClientError.failed("The live gateway answered something unreadable")))
                        }
                        finish(.success(answer))
                    }
                }
            case .failed(let error):
                finish(.failure(ClientError.notRunning(error.localizedDescription)))
            case .cancelled:
                finish(.failure(CancellationError()))
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        return connection
    }
}

final class SecretBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<LiveGatewayResponse, Error> = .failure(LiveGatewayClient.ClientError.failed("no answer"))
    func set(_ value: Result<LiveGatewayResponse, Error>) { lock.withLock { result = value } }
    func get() throws -> LiveGatewayResponse { try lock.withLock { result }.get() }
}

/// True the first time only.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

/// Sends each request of a client session through the gateway.
final class LiveGatewayClientProtocol: URLProtocol, @unchecked Sendable {
    static let routeHeader = "X-JTKit-Live-Gateway"
    private let running = LockedTask()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let route = (request.value(forHTTPHeaderField: Self.routeHeader) ?? "").split(separator: " ", maxSplits: 1).map(String.init)
        guard let url = request.url, route.count == 2, let port = UInt16(route[0]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        let headers = (request.allHTTPHeaderFields ?? [:]).filter { $0.key.caseInsensitiveCompare(Self.routeHeader) != .orderedSame }
        let frame = LiveGatewayRequest(token: route[1], method: request.httpMethod ?? "GET", url: url.absoluteString,
                                       headers: headers, body: body.isEmpty ? nil : body)
        let connection = LiveGatewayClient.exchange(frame, port: port) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let answer):
                if let error = answer.error {
                    client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable, userInfo: [NSLocalizedDescriptionKey: error]))
                    return
                }
                guard let status = answer.status,
                      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: answer.headers) else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: answer.body ?? Data())
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable, userInfo: [NSLocalizedDescriptionKey: "\(error)"]))
            }
        }
        running.set(connection)
    }

    override func stopLoading() { running.cancel() }

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

final class LockedTask: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    func set(_ connection: NWConnection?) { lock.withLock { self.connection = connection } }
    func cancel() { lock.withLock { connection?.cancel() } }
}
