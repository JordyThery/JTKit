import Foundation
import ObjectiveC

/// One request as a demo server sees it.
public nonisolated struct DemoRequest: Sendable {
    public var method: String
    public var url: URL
    /// The path’s segments, percent-decoded, e.g. `["blueprints", "v1", "blueprints"]`.
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
/// the demo server registered for the request’s host, inside the app. A host
/// with no server fails as "can’t find host", so nothing a demo client sends
/// can reach the real network, whatever address it uses.
///
/// The servers stay registered as long as the session is in use, also when
/// only the session is kept, and are let go with it.
public nonisolated final class DemoNetwork: Sendable {
    /// Hosts that can never resolve (RFC 2606), for demo servers that don’t
    /// stand in for a fixed real host.
    public static let reservedDomain = "demo.invalid"

    public let session: URLSession
    /// The network’s name in the requests it sends (`DemoURLProtocol.networkHeader`).
    let id: String
    private let servers: [String: any DemoServer]

    /// - Parameter servers: by host, e.g. `["contoso-platform.demo.invalid": server]`.
    public init(servers: [String: any DemoServer]) {
        let servers = Dictionary(servers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.servers = servers
        let id = UUID().uuidString
        self.id = id
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoURLProtocol.self]
        configuration.httpAdditionalHeaders = [DemoURLProtocol.networkHeader: id]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
        DemoURLProtocol.register(servers, id: id)
        // removes the servers when the session goes
        objc_setAssociatedObject(session, &DemoURLProtocol.registrationKey,
                                 DemoURLProtocol.Registration(id: id), .OBJC_ASSOCIATION_RETAIN)
    }

    func server(forHost host: String) -> (any DemoServer)? {
        servers[host.lowercased()]
    }
}

/// Answers every request of a demo session from its `DemoNetwork`'s servers.
/// It is only registered on demo sessions, so it claims all their requests.
nonisolated final class DemoURLProtocol: URLProtocol, @unchecked Sendable {
    static let networkHeader = "X-JTKit-Demo-Network"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var networks: [String: [String: any DemoServer]] = [:]
    nonisolated(unsafe) static var registrationKey: UInt8 = 0

    /// Kept by a demo session; unregisters its network’s servers when the
    /// session is let go.
    final class Registration: @unchecked Sendable {
        let id: String
        init(id: String) { self.id = id }
        deinit { DemoURLProtocol.unregister(id: id) }
    }

    static func register(_ servers: [String: any DemoServer], id: String) {
        lock.withLock { networks[id] = servers }
    }

    static func unregister(id: String) {
        lock.withLock { networks[id] = nil }
    }

    static func isRegistered(id: String) -> Bool {
        lock.withLock { networks[id] != nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
              let id = request.value(forHTTPHeaderField: Self.networkHeader),
              let server = Self.lock.withLock({ Self.networks[id]?[host.lowercased()] }) else {
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

/// Keeps demo connections off the real network, in the request recorder
/// every client sends through: a request for a demo connection (an address
/// on `.demo.invalid`, or a sign-in or path naming an ID in the reserved
/// fake range) on a session that isn’t a demo network’s is refused before
/// anything is sent. A real connection on a demo session can’t leave the
/// app either: the demo network answers only its own servers.
nonisolated enum DemoBoundary {
    struct Refusal: LocalizedError, Equatable {
        var errorDescription: String? {
            "This is a Demo Mode connection, so it never uses the real network. Nothing was sent."
        }
    }

    static func isDemoSession(_ session: URLSession) -> Bool {
        session.configuration.protocolClasses?.contains { ObjectIdentifier($0) == ObjectIdentifier(DemoURLProtocol.self) } ?? false
    }

    static func refusal(of request: URLRequest, session: URLSession) -> Refusal? {
        guard targetsDemo(request), !isDemoSession(session) else { return nil }
        return Refusal()
    }

    /// Whether the request is for a demo connection.
    static func targetsDemo(_ request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        let host = url.host()?.lowercased() ?? ""
        if host == DemoNetwork.reservedDomain || host.hasSuffix("." + DemoNetwork.reservedDomain) { return true }
        // e.g. Microsoft’s sign-in for the demo tenant: /<tenant>/oauth2/v2.0/token
        if url.pathComponents.contains(where: DemoSamples.isDemoIdentifier) { return true }
        // a sign-in naming a demo client, in the query or a form body
        var forms = [url.query(percentEncoded: true) ?? ""]
        if let body = request.httpBody, let text = String(data: body, encoding: .utf8) { forms.append(text) }
        return forms.contains { form in
            form.split(separator: "&").contains { pair in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == "client_id" else { return false }
                return DemoSamples.isDemoIdentifier(parts[1].removingPercentEncoding ?? parts[1])
            }
        }
    }
}
