import Foundation
import JTKitLiveCheck

/// The Jamf Platform API as a live UI test reaches it (B4): sign-in and
/// JSON requests through the release check’s gateway, so the test’s own
/// objects obey the same rules as the app (only `JTKTEST` creates, changes
/// and deletes only of the run’s objects) and land in the run’s ledger.
/// JTKitUITestSupport doesn’t link JTKit, so this speaks the API’s JSON directly.
public final class LiveJamfPlatformAPI: @unchecked Sendable {
    public let gateway: LiveGatewayClient
    public let role: String
    public let baseURL: URL
    let environmentID: String
    private let clientID: String
    private let clientSecret: String
    private let lock = NSLock()
    private var token: String?

    public struct Failure: Error, CustomStringConvertible {
        public let status: Int
        public let body: String
        public var description: String { "HTTP \(status): \(body.prefix(300))" }
    }

    /// - Parameters:
    ///   - role: a Jamf Platform API role of the run, e.g. "jamf-test-a".
    ///   - environment: where the release check passed the secret; this process’s by default.
    ///   - environment: tests only: a secret there is used instead of the gateway’s.
    public init(gateway: LiveGatewayClient, role: String,
                environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        // the secret from the gateway, never from this runner's environment
        // (Xcode keeps that in the result bundle)
        let fromEnvironment = environment[LiveCheckRun.variable(role: role, item: "client-secret")].flatMap { $0.isEmpty ? nil : $0 }
        guard let connection = gateway.launch.connections.first(where: { $0.role == role && $0.connection.service == "jamfPlatform" })?.connection,
              let secret = try fromEnvironment ?? gateway.secretNow(role: role, item: "client-secret"), !secret.isEmpty else {
            throw Failure(status: 0, body: "\(role) has no Jamf Platform API connection or client secret in this run")
        }
        self.gateway = gateway
        self.role = role
        baseURL = URL(string: "https://\(connection.region).api.jamfcloud.com")!
        environmentID = connection.environmentID
        clientID = connection.clientID
        clientSecret = secret
    }

    /// Sends a request; returns the answer’s status and body. A status of
    /// 400 and up throws `Failure`, unless `accepting` contains it.
    @discardableResult
    public func send(_ method: String, _ path: String, json: Any? = nil, accepting: Set<Int> = []) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(environmentID, forHTTPHeaderField: "X-Environment-Id")
        request.setValue("Bearer \(try await bearer())", forHTTPHeaderField: "Authorization")
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await gateway.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 && !accepting.contains(status) {
            throw Failure(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return (status, data)
    }

    /// A GET, parsed as a JSON object.
    public func object(_ path: String) async throws -> [String: Any] {
        let body = try await send("GET", path).body
        return (try JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    /// A create; returns the new object’s `id`.
    public func create(_ path: String, json: [String: Any]) async throws -> String {
        let body = try await send("POST", path, json: json).body
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        guard let id = (object?["id"] as? String) ?? (object?["id"] as? NSNumber)?.stringValue else {
            throw Failure(status: 0, body: "The create answered without an id")
        }
        return id
    }

    private func bearer() async throws -> String {
        if let token = lock.withLock({ token }) { return token }
        var request = URLRequest(url: baseURL.appending(path: "auth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "grant_type", value: "client_credentials"),
                           URLQueryItem(name: "client_id", value: clientID),
                           URLQueryItem(name: "client_secret", value: clientSecret)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await gateway.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String else {
            throw Failure(status: status, body: "The sign-in failed")
        }
        lock.withLock { self.token = token }
        return token
    }
}
