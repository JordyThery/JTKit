import Foundation

/// One request as a demo server sees it.
public nonisolated struct DemoRequest: Sendable {
    public var method: String
    public var url: URL
    /// The path's segments, percent-decoded, e.g. `["blueprints", "v1", "blueprints"]`.
    public var pathSegments: [String]
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method.uppercased()
        self.url = url
        pathSegments = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        self.query = query
        self.headers = headers
        self.body = body
    }
}

/// What a demo server answers.
public nonisolated struct DemoResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = ["Content-Type": "application/json"], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, _ value: LosslessJSON) -> DemoResponse {
        DemoResponse(status: status, body: value.serialized())
    }
}

/// A fake service inside the app, e.g. `DemoJamfPlatformServer`.
public protocol DemoServer: AnyObject, Sendable {
    func respond(to request: DemoRequest) -> DemoResponse
}

/// A private network for demo mode: its `session` hands **every** request to
/// the demo server registered for the request's host, inside the app. A host
/// with no server fails as "cannot find host", so nothing a demo client sends
/// can reach the real network, whatever address it uses.
public nonisolated final class DemoNetwork: Sendable {
    /// Hosts that can never resolve (RFC 2606), for demo servers that don't
    /// stand in for a fixed real host.
    public static let reservedDomain = "demo.invalid"

    public let session: URLSession
    private let servers: [String: any DemoServer]

    /// - Parameter servers: by host, e.g. `["contoso-platform.demo.invalid": server]`.
    public init(servers: [String: any DemoServer]) {
        self.servers = Dictionary(servers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        let id = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoURLProtocol.self]
        configuration.httpAdditionalHeaders = [DemoURLProtocol.networkHeader: id]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
        DemoURLProtocol.register(self, id: id)
    }

    func server(forHost host: String) -> (any DemoServer)? {
        servers[host.lowercased()]
    }
}

/// Answers every request of a demo session from its `DemoNetwork`. It is only
/// registered on demo sessions, so it claims all their requests.
nonisolated final class DemoURLProtocol: URLProtocol, @unchecked Sendable {
    static let networkHeader = "X-JTKit-Demo-Network"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var networks: [String: DemoNetwork] = [:]

    static func register(_ network: DemoNetwork, id: String) {
        lock.withLock { networks[id] = network }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
              let id = request.value(forHTTPHeaderField: Self.networkHeader),
              let network = Self.lock.withLock({ Self.networks[id] }),
              let server = network.server(forHost: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        var headers = request.allHTTPHeaderFields ?? [:]
        headers[Self.networkHeader] = nil
        let answer = server.respond(to: DemoRequest(
            method: request.httpMethod ?? "GET", url: url, headers: headers,
            body: request.httpBody ?? Self.read(request.httpBodyStream)))
        if let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                          headerFields: answer.headers) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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
