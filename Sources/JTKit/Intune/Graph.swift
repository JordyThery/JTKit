import Foundation

/// Microsoft Graph, for Intune (ROADMAP step 8). Microsoft's public cloud only.
public nonisolated enum Graph {
    public static let host = "graph.microsoft.com"
    public static let baseURL = URL(string: "https://graph.microsoft.com")!
    /// Graph's limit for this app's requests at a time.
    public static let maxConcurrent = 4
    /// More pages than any real list has; reaching it is an error.
    public static let maxPages = 1_000

    public enum Version: String, Sendable, Hashable {
        case v1 = "v1.0"
        case beta
    }

    /// The recorder for Graph requests: category "Graph", service "Intune".
    public static func recorder(session: URLSession = .shared, log: ActivityLog?, connection: String? = nil) -> RequestRecorder {
        RequestRecorder(session: session, log: log, category: "Graph", service: "Intune", connection: connection)
    }

    /// Sends requests to Microsoft Graph on JTKit's `HTTPClient`, so the
    /// shared retry rules apply: at most 4 attempts, 429 retried for every
    /// request, server errors and network drops only for reads and the edits
    /// marked safe to repeat, a 401 gets a new token and one more try.
    ///
    /// - At most 4 requests at a time; a request keeps its turn while it
    ///   waits to be retried.
    /// - Every request carries a new `client-request-id`.
    /// - Lists follow `@odata.nextLink` only to `https://graph.microsoft.com`;
    ///   an answer without `value` is an error, and so is reaching 1,000 pages.
    /// - Errors are `GraphError`s, naming the permission a refused request needs.
    public final class Client: Sendable {
        public let access: Graph.Access
        /// The app's own hints, added to every error.
        public let hints: [String]
        private let http: HTTPClient
        private let requestID: @Sendable () -> String

        /// Records every attempt; also for requests that don't go to Graph,
        /// such as Intune Deployer's uploads to Azure Storage.
        public var recorder: RequestRecorder { http.recorder }

        /// - Parameters:
        ///   - tokens: `EntraTokenProvider` for an app sign-in, or the
        ///     interactive sign-in's token source (`JTKitMSAL`).
        ///   - access: how it signs in, which decides who grants a missing
        ///     permission.
        ///   - recorder: usually `Graph.recorder(session:log:connection:)`.
        ///   - sleep, random, now, requestID: injectable for tests.
        public init(
            tokens: any BearerTokenSource,
            access: Graph.Access,
            recorder: RequestRecorder,
            hints: [String] = [],
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
            now: @escaping @Sendable () -> Date = { Date() },
            requestID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
        ) {
            self.access = access
            self.hints = hints
            self.requestID = requestID
            http = HTTPClient(baseURL: Graph.baseURL, tokens: tokens, recorder: recorder,
                              redirects: .sameHostHTTPSOnly, maxConcurrent: Graph.maxConcurrent,
                              sleep: sleep, random: random, now: now)
        }

        /// An Intune connection that signs in with its app registration's
        /// client secret.
        ///
        /// - Throws: `GraphError.Kind.invalidConnection` for another service
        ///   or sign-in method, or an unusable tenant or client ID.
        public convenience init(connection: Connection, secret: @escaping @Sendable () throws -> String,
                                session: URLSession = .shared, log: ActivityLog?, hints: [String] = []) throws {
            let recorder = Graph.recorder(session: session, log: log, connection: connection.name)
            let tokens = try EntraTokenProvider(connection: connection, secret: secret, recorder: recorder)
            self.init(tokens: tokens, access: .application, recorder: recorder, hints: hints)
        }

        // MARK: - Requests

        /// Sends one request; returns the answer's body.
        ///
        /// - Parameters:
        ///   - path: relative to the version, with or without a query
        ///     (`me?$select=id`), or a whole next-page link.
        ///   - safeToRepeat: an edit that can be sent twice without harm
        ///     (updates, `/assign`); creates never are.
        public func send(_ method: String, _ path: String, version: Version, body: Data? = nil,
                         safeToRepeat: Bool = false) async throws -> Data {
            try await send(method, path, version: version, body: body, safeToRepeat: safeToRepeat,
                           notFoundAfterRepeatIsDone: false).data
        }

        public func get<T: Decodable>(_ type: T.Type, _ path: String, version: Version) async throws -> T {
            try Self.decode(type, from: try await send("GET", path, version: version))
        }

        public func getRaw(_ path: String, version: Version) async throws -> Data {
            try await send("GET", path, version: version)
        }

        /// A create or an action. Not repeated after a server error or a
        /// dropped connection unless `safeToRepeat` (e.g. `/assign`, which
        /// replaces what's there).
        @discardableResult
        public func post(_ path: String, version: Version, body: Data, safeToRepeat: Bool = false) async throws -> Data {
            try await send("POST", path, version: version, body: body, safeToRepeat: safeToRepeat)
        }

        /// A partial update; safe to repeat.
        @discardableResult
        public func patch(_ path: String, version: Version, body: Data) async throws -> Data {
            try await send("PATCH", path, version: version, body: body, safeToRepeat: true)
        }

        /// A full replace; safe to repeat.
        @discardableResult
        public func put(_ path: String, version: Version, body: Data) async throws -> Data {
            try await send("PUT", path, version: version, body: body, safeToRepeat: true)
        }

        /// Safe to repeat: a 404 after a repeat counts as already gone.
        public func delete(_ path: String, version: Version) async throws {
            _ = try await send("DELETE", path, version: version, body: nil, safeToRepeat: true,
                               notFoundAfterRepeatIsDone: true)
        }

        /// Every item of a list, decoded, following the next pages.
        public func list<T: Decodable>(_ type: T.Type, _ path: String, version: Version,
                                       maxPages: Int = Graph.maxPages) async throws -> [T] {
            try await listRaw(path, version: version, maxPages: maxPages).map { try Self.decode(type, from: $0) }
        }

        /// Every item of a list as its own JSON, following the next pages.
        public func listRaw(_ path: String, version: Version, maxPages: Int = Graph.maxPages) async throws -> [Data] {
            var items = [Data]()
            var next: String? = path
            var pages = 0
            while let current = next {
                try Task.checkCancellation()
                guard pages < maxPages else {
                    throw GraphError(.pageLimitReached(path: Self.shownPath(path), pages: pages), appHints: hints, access: access)
                }
                let data = try await send("GET", current, version: version)
                pages += 1
                guard let page = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let value = page["value"] as? [Any] else {
                    throw GraphError(.invalidResponse("The answer to \(Self.shownPath(path)) has no list (“value”)."),
                                     appHints: hints, access: access)
                }
                for element in value {
                    items.append(try JSONSerialization.data(withJSONObject: element, options: [.fragmentsAllowed]))
                }
                next = page["@odata.nextLink"] as? String
            }
            return items
        }

        // MARK: - Addresses

        /// The path (with the version) and the already-encoded query of a
        /// request, or of a next-page link, which must point to Graph.
        public nonisolated static func parts(of path: String, version: Version) throws -> (path: String, query: String?) {
            if path.lowercased().hasPrefix("https://") || path.lowercased().hasPrefix("http://") {
                guard let url = URL(string: path), url.scheme?.lowercased() == "https",
                      url.host()?.lowercased() == Graph.host, url.port == nil, url.user() == nil else {
                    throw GraphError(.nextPageElsewhere(URL(string: path)?.host() ?? "another address"))
                }
                var linkPath = url.path(percentEncoded: true)
                while linkPath.hasPrefix("/") { linkPath.removeFirst() }
                guard linkPath.hasPrefix("v1.0/") || linkPath.hasPrefix("beta/") else {
                    throw GraphError(.nextPageElsewhere("\(Graph.host)/\(linkPath)"))
                }
                return (linkPath, url.query(percentEncoded: true))
            }
            let split = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            var relative = String(split[0])
            while relative.hasPrefix("/") { relative.removeFirst() }
            let encodedPath = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
            // characters a query can't hold (spaces, quotes) are encoded;
            // existing escapes and the &/= separators are kept, so callers can
            // pre-encode values that contain & or +
            var allowed = CharacterSet.urlQueryAllowed
            allowed.insert("%")
            let query = split.count == 2 ? String(split[1]).addingPercentEncoding(withAllowedCharacters: allowed) : nil
            return ("\(version.rawValue)/\(encodedPath)", query)
        }

        /// Graph's dates come with or without fractional seconds.
        public nonisolated static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let string = try container.decode(String.self)
                for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = options
                    if let date = formatter.date(from: string) { return date }
                }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date: \(string)")
            }
            do {
                return try decoder.decode(type, from: data)
            } catch {
                throw GraphError(.invalidResponse("\(T.self): \(error.localizedDescription)"))
            }
        }

        // MARK: - Private

        private func send(_ method: String, _ path: String, version: Version, body: Data?, safeToRepeat: Bool,
                          notFoundAfterRepeatIsDone: Bool) async throws -> HTTPResponse {
            let parts: (path: String, query: String?)
            do {
                parts = try Self.parts(of: path, version: version)
            } catch var error as GraphError {
                await recorder.note(method, Self.shownPath(path), note: error.message(), category: "Blocked", isWarning: true)
                error.appHints = hints
                error.access = access
                throw error
            }
            let pathInVersion = parts.path.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let permission = Graph.Permission.required(method: method, path: pathInVersion.removingPercentEncoding ?? pathInVersion)
            let request = HTTPRequest(method: method, path: parts.path, body: body,
                                      headers: ["client-request-id": requestID()],
                                      safeToRepeat: safeToRepeat, encodedQuery: parts.query,
                                      notFoundAfterRepeatIsDone: notFoundAfterRepeatIsDone)
            do {
                return try await http.send(request)
            } catch let error as HTTPError {
                throw GraphError(error, access: access, permission: permission, appHints: hints)
            } catch var error as GraphError {
                // from the sign-in
                error.appHints = hints + error.appHints
                throw error
            }
        }

        /// A path as shown in messages: without the query.
        private nonisolated static func shownPath(_ path: String) -> String {
            String(path.split(separator: "?", maxSplits: 1).first ?? "")
        }
    }
}
