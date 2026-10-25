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

    public init(status: Int, headers: [String: String] = ["Content-Type": "application/json"], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
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
/// The handler is global, so test suites that use it must be `.serialized`.
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
        let recordedRequest = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Self.readStream(request.httpBodyStream)
        )
        let handler = Self.lock.withLock { () -> Handler? in
            Self.recorded.append(recordedRequest)
            return Self.handler
        }

        do {
            guard let handler else { throw URLError(.unsupportedURL) }
            let mock = try handler(recordedRequest)
            let response = HTTPURLResponse(
                url: recordedRequest.url, statusCode: mock.status, httpVersion: "HTTP/1.1", headerFields: mock.headers
            )!
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
