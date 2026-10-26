import Foundation

/// A captured request, with the body read out of `httpBodyStream`.
public struct RecordedRequest: Sendable {
    public let method: String
    public let url: URL
    public let headers: [String: String]
    public let body: Data

    public var path: String { url.path() }

    public func queryValue(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public var bodyString: String { String(decoding: body, as: UTF8.self) }
}

public struct MockResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    /// Set by `redirect(_:to:)`: the session is told to go there, as a real
    /// server's redirect would, so the client's redirect rule is applied.
    public var redirectTarget: URL?

    public init(status: Int, headers: [String: String] = ["Content-Type": "application/json"], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// A redirect (307 keeps the method and body, as a POST sign-in would).
    public static func redirect(_ status: Int = 307, to target: URL) -> MockResponse {
        var response = MockResponse(status: status, headers: ["Location": target.absoluteString], body: Data())
        response.redirectTarget = target
        return response
    }

    public static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> MockResponse {
        MockResponse(
            status: status,
            headers: ["Content-Type": "application/json"].merging(headers) { $1 },
            body: Data(text.utf8)
        )
    }
}

/// Routes every request on a session to a test-provided handler.
///
/// `install` sets one global handler, so test suites that use it must be
/// `.serialized`. A `MockServer` has a handler of its own, so tests that each
/// use their own server can run at the same time.
public final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    public typealias Handler = @Sendable (RecordedRequest) throws -> MockResponse

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorded: [RecordedRequest] = []

    public static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    public static var requests: [RecordedRequest] {
        lock.withLock { recorded }
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override public class func canInit(with request: URLRequest) -> Bool { true }
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        let serverID = request.value(forHTTPHeaderField: MockServer.header)
        var headers = request.allHTTPHeaderFields ?? [:]
        headers = headers.filter { $0.key.caseInsensitiveCompare(MockServer.header) != .orderedSame }
        let recordedRequest = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: headers,
            body: request.httpBody ?? Self.readStream(request.httpBodyStream)
        )
        let handler: Handler?
        if let serverID {
            handler = MockServer.route(serverID, recordedRequest)
        } else {
            handler = Self.lock.withLock { () -> Handler? in
                Self.recorded.append(recordedRequest)
                return Self.handler
            }
        }

        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let mock = try handler(recordedRequest)
            let response = HTTPURLResponse(
                url: recordedRequest.url, statusCode: mock.status, httpVersion: "HTTP/1.1", headerFields: mock.headers
            )!
            if let target = mock.redirectTarget {
                var redirected = request
                redirected.url = target
                // the session asks its delegate: an allowed redirect starts a
                // new load (and ends this one); a refused one leaves this load
                // running, so the redirect itself comes back as the answer,
                // as with a real server
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: mock.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override public func stopLoading() {}

    private static func readStream(_ stream: InputStream?) -> Data {
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

/// A fake server for one session, with its own handler and its own list of
/// requests, so tests that use different servers can run at the same time.
///
/// ```swift
/// let server = MockServer { request in .json(200, "{}") }
/// let client = HTTPClient(…, recorder: RequestRecorder(session: server.session, log: nil))
/// #expect(server.requests.count == 1)
/// ```
public final class MockServer: @unchecked Sendable {
    static let header = "X-JTKit-Mock-Server"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: MockServer] = [:]

    private let id = UUID().uuidString
    private let lock = NSLock()
    private var handler: MockURLProtocol.Handler
    private var recorded: [RecordedRequest] = []
    public let session: URLSession

    public init(_ handler: @escaping MockURLProtocol.Handler) {
        self.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = [Self.header: id]
        session = URLSession(configuration: configuration)
        Self.lock.withLock { Self.servers[id] = self }
    }

    /// Replaces the handler, e.g. for the second half of a test.
    public func respond(_ handler: @escaping MockURLProtocol.Handler) {
        lock.withLock { self.handler = handler }
    }

    /// Every request received, oldest first.
    public var requests: [RecordedRequest] {
        lock.withLock { recorded }
    }

    /// Stops routing to this server; later requests fail.
    public func shutDown() {
        Self.lock.withLock { _ = Self.servers.removeValue(forKey: id) }
    }

    static func route(_ id: String, _ request: RecordedRequest) -> MockURLProtocol.Handler? {
        guard let server = lock.withLock({ servers[id] }) else { return nil }
        return server.lock.withLock {
            server.recorded.append(request)
            return server.handler
        }
    }
}
