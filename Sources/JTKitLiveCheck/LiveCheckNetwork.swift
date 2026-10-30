import Foundation

/// A refused request, for the report.
public nonisolated struct LiveRefusal: Sendable, Equatable, Codable {
    public var method: String
    /// Host and path only: no query, no body.
    public var location: String
    public var reason: String
}

/// The error a client sees for a refused request.
public nonisolated struct LiveCheckRefused: LocalizedError, Sendable {
    public var refusal: LiveRefusal
    public var errorDescription: String? {
        "Live check refused \(refusal.method) \(refusal.location): \(refusal.reason)"
    }
}

/// The live check's network: give its `session` to the app's
/// `RequestRecorder`, where demo mode gives its own. Every request is decided
/// by the `LiveCheckPolicy` before it's sent; allowed ones go out through
/// `upstream`, refused ones fail with `LiveCheckRefused` and nothing leaves
/// the Mac. Successful creates are written to the ledger, deletes marked.
public nonisolated final class LiveCheckNetwork: @unchecked Sendable {
    public let policy: LiveCheckPolicy
    public let session: URLSession
    let upstream: URLSession

    /// Where each refusal is appended the moment it happens (0.12.3), one
    /// JSON line each: every test of a release check runs in its own process,
    /// so a file shared by the run keeps them all for the report.
    let refusalsFile: URL?

    /// Paces every Apple request and caps them per run (0.12.4).
    public let appleBudget: AppleRequestBudget

    private let lock = NSLock()
    private var refusedStorage: [LiveRefusal] = []

    /// - Parameters:
    ///   - upstream: where allowed requests go; a fresh ephemeral session by
    ///     default (tests pass a mock).
    ///   - refusalsFile: the run's `refusals.jsonl` (`LiveCheckRun` passes it).
    ///   - appleRequestsFile: the run's `apple-requests.jsonl`, so the Apple
    ///     budget is shared by the run's test processes (`LiveCheckRun` passes it).
    ///   - appleBudget: replaces the standard budget (9 a minute, 40 a run per
    ///     organisation); JTKit's own tests use a small one.
    public init(policy: LiveCheckPolicy, upstream: URLSession = LiveCheckNetwork.makeUpstream(), refusalsFile: URL? = nil,
                appleRequestsFile: URL? = nil, appleBudget: AppleRequestBudget? = nil) {
        self.policy = policy
        self.upstream = upstream
        self.refusalsFile = refusalsFile
        self.appleBudget = appleBudget ?? AppleRequestBudget(file: appleRequestsFile)
        let id = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveCheckURLProtocol.self]
        configuration.httpAdditionalHeaders = [LiveCheckURLProtocol.networkHeader: id]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
        LiveCheckURLProtocol.register(self, id: id)
    }

    /// An ephemeral session that never follows a redirect: a redirect to
    /// another host would skip the policy, so the 3xx goes back to the client.
    public static func makeUpstream() -> URLSession {
        URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    }

    final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// Every refused request so far; a run with any fails its check.
    public var refusals: [LiveRefusal] { lock.withLock { refusedStorage } }

    func refuse(_ request: LiveRequest, reason: String) -> LiveCheckRefused {
        let refusal = LiveRefusal(method: request.method,
                                  location: "\(request.url.host() ?? "")\(request.url.path(percentEncoded: false))",
                                  reason: reason)
        lock.withLock {
            refusedStorage.append(refusal)
            if let refusalsFile { Self.append(refusal, to: refusalsFile) }
        }
        return LiveCheckRefused(refusal: refusal)
    }

    /// Appends one line; `O_APPEND` keeps lines whole when two processes write.
    static func append(_ refusal: LiveRefusal, to file: URL) {
        guard let line = try? JSONEncoder().encode(refusal) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        let data = line + Data("\n".utf8)
        _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    /// Every refusal the run's file holds, from every test process so far.
    public static func refusals(in file: URL) -> [LiveRefusal] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(LiveRefusal.self, from: Data($0.utf8)) }
    }

    /// After an allowed request answered: records creates, removals and Apple tokens.
    func didAnswer(_ allowed: LiveDecision.Allowed, request: LiveRequest, status: Int, body: Data) {
        switch allowed.kind {
        case .create(let name) where (200..<300).contains(status):
            guard let resource = allowed.resource, let id = LiveCheckPolicy.createdID(in: body) else { return }
            try? policy.ledger.add(.init(target: allowed.target, resource: resource, id: id, name: name),
                                   testPrefixes: [policy.prefix])
        case .delete where (200..<300).contains(status) || status == 404:
            if let resource = allowed.resource, let id = allowed.id {
                policy.ledger.markRemoved(target: allowed.target, resource: resource, id: id)
            }
        case .signIn where request.url.host() == "account.apple.com" && (200..<300).contains(status):
            if let token = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["access_token"] as? String,
               let clientID = LiveCheckPolicy.formValue("client_id", in: request.body) {
                policy.recordAppleToken(token, clientID: clientID)
            }
        default:
            break
        }
    }
}

/// Decides every request of a live-check session, then sends it on.
nonisolated final class LiveCheckURLProtocol: URLProtocol, @unchecked Sendable {
    static let networkHeader = "X-JTKit-Live-Check"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var networks: [String: LiveCheckNetwork] = [:]

    static func register(_ network: LiveCheckNetwork, id: String) {
        lock.withLock { networks[id] = network }
    }

    private let stateLock = NSLock()
    private var upstreamTask: URLSessionDataTask?
    private var stopped = false
    private static let appleQueue = DispatchQueue(label: "JTKitLiveCheck.apple-budget", attributes: .concurrent)

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.networkHeader),
              let network = Self.lock.withLock({ Self.networks[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var outgoing = request
        outgoing.setValue(nil, forHTTPHeaderField: Self.networkHeader)
        let body = request.httpBody ?? Self.read(request.httpBodyStream)
        outgoing.httpBodyStream = nil
        outgoing.httpBody = body.isEmpty ? nil : body
        let seen = LiveRequest(outgoing, body: body)

        switch network.policy.decide(seen) {
        case .refuse(let reason):
            client?.urlProtocol(self, didFailWithError: network.refuse(seen, reason: reason))
        case .allow(let allowed) where allowed.target.hasPrefix("apple:"):
            // Apple: wait for the budget off the loading thread, then send.
            Self.appleQueue.async { [self] in
                while true {
                    if stateLock.withLock({ stopped }) { return }
                    switch network.appleBudget.claim(role: allowed.role) {
                    case .go:
                        send(outgoing, allowed: allowed, seen: seen, network: network)
                        return
                    case .wait(let seconds):
                        Thread.sleep(forTimeInterval: min(seconds, 1))
                    case .refuse(let reason):
                        client?.urlProtocol(self, didFailWithError: network.refuse(seen, reason: reason))
                        return
                    }
                }
            }
        case .allow(let allowed):
            send(outgoing, allowed: allowed, seen: seen, network: network)
        }
    }

    private func send(_ outgoing: URLRequest, allowed: LiveDecision.Allowed, seen: LiveRequest, network: LiveCheckNetwork) {
        let task = network.upstream.dataTask(with: outgoing) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let data = data ?? Data()
            if let response = response as? HTTPURLResponse {
                network.didAnswer(allowed, request: seen, status: response.statusCode, body: data)
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        let cancelled = stateLock.withLock {
            upstreamTask = task
            return stopped
        }
        if cancelled { task.cancel() } else { task.resume() }
    }

    override func stopLoading() {
        let task = stateLock.withLock {
            stopped = true
            return upstreamTask
        }
        task?.cancel()
    }

    private static func read(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
