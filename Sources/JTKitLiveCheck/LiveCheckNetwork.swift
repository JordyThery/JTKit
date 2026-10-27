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

    private let lock = NSLock()
    private var refusedStorage: [LiveRefusal] = []

    /// - Parameter upstream: where allowed requests go; a fresh ephemeral
    ///   session by default (tests pass a mock).
    public init(policy: LiveCheckPolicy, upstream: URLSession = LiveCheckNetwork.makeUpstream()) {
        self.policy = policy
        self.upstream = upstream
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
        lock.withLock { refusedStorage.append(refusal) }
        return LiveCheckRefused(refusal: refusal)
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

    private var upstreamTask: URLSessionDataTask?

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
        case .allow(let allowed):
            upstreamTask = network.upstream.dataTask(with: outgoing) { [weak self] data, response, error in
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
            upstreamTask?.resume()
        }
    }

    override func stopLoading() {
        upstreamTask?.cancel()
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
