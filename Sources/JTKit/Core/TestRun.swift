import Foundation
import os

/// Under tests: the host of an app’s unit tests, or a sandbox launch
/// (`-JTKitSandbox YES`, which the UI tests use). An app refuses then what a
/// test must never do (reach a saved connection, send a device command, read
/// a secret, …) and writes every refused attempt to an `AttemptLog`, so the
/// release check can show it in its report and fail. Demo connections aren’t
/// tenants: they are answered inside the app and never refused.
public nonisolated enum TestRun {
    /// This process is the host of the unit tests.
    public static var isUnitTestHost: Bool {
        isUnitTestHost(environment: ProcessInfo.processInfo.environment)
    }

    /// This launch is under tests: the unit-test host, an XCTest session, or
    /// a sandbox launch.
    public static var isActive: Bool {
        isActive(environment: ProcessInfo.processInfo.environment, arguments: ProcessInfo.processInfo.arguments)
    }

    static func isUnitTestHost(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil
    }

    static func isActive(environment: [String: String], arguments: [String]) -> Bool {
        isUnitTestHost(environment: environment)
            || environment["XCTestSessionIdentifier"] != nil
            || DemoMode.isSandboxLaunch(arguments)
    }

    /// Where an app writes its refused attempts: a folder of that name in the
    /// temporary folder (the container’s, for a sandboxed app), the same for
    /// the test host and the app the UI tests launch. The release check
    /// empties it before every run.
    public static func attemptsFolder(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    /// The refused attempts of one kind, one JSON line each. What is written
    /// names the action and where it went (method, host and path), never a
    /// query, serial number or secret.
    public final class AttemptLog: Sendable {
        public struct Attempt: Codable, Sendable, Equatable {
            public var time: Date
            /// "unit test host" or "UI test run".
            public var process: String
            public var what: String
        }

        public let fileURL: URL
        private let logger: Logger?
        private let lock = NSLock()

        /// - Parameter logger: also writes every refusal there (privately).
        public init(fileURL: URL, logger: Logger? = nil) {
            self.fileURL = fileURL
            self.logger = logger
        }

        public func record(_ what: String) {
            logger?.error("Refused under tests: \(what, privacy: .private)")
            let attempt = Attempt(time: Date(), process: TestRun.isUnitTestHost ? "unit test host" : "UI test run", what: what)
            guard let line = try? JSONEncoder().encode(attempt) else { return }
            lock.withLock {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                // O_APPEND: the test host and the app the UI tests launch may both write.
                let descriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
                guard descriptor >= 0 else { return }
                defer { close(descriptor) }
                let data = line + Data("\n".utf8)
                _ = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            }
        }

        /// Every attempt written so far, by every process.
        public func attempts() -> [Attempt] {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Attempt.self, from: Data($0.utf8)) }
        }
    }

    /// The error of a refused attempt that isn’t a request, e.g. a device
    /// command an app’s guard refuses before making a client.
    public struct Refusal: LocalizedError, Sendable, Equatable {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var errorDescription: String? { message }
    }

    /// A session that sends nothing: every request, a sign-in included, is
    /// written to `log` as "METHOD host/path" (after "`kind`: " when given)
    /// and fails before it leaves the Mac, with `message` as its description
    /// (a `URLError` with code `.resourceUnavailable`, so it reads as no
    /// answer, never as a cancellation).
    public static func refusingSession(log: AttemptLog, kind: String? = nil, message: String) -> URLSession {
        let id = UUID().uuidString
        RefusingURLProtocol.register(RefusingURLProtocol.Route(log: log, kind: kind, message: message), id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefusingURLProtocol.self]
        configuration.httpAdditionalHeaders = [RefusingURLProtocol.routeHeader: id]
        return URLSession(configuration: configuration)
    }

    /// Fails every request of a refusing session and writes it down.
    final class RefusingURLProtocol: URLProtocol, @unchecked Sendable {
        struct Route: Sendable {
            let log: AttemptLog
            let kind: String?
            let message: String
        }

        static let routeHeader = "X-JTKit-Under-Test"
        private static let lock = NSLock()
        nonisolated(unsafe) private static var routes: [String: Route] = [:]

        static func register(_ route: Route, id: String) {
            lock.withLock { routes[id] = route }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let id = request.value(forHTTPHeaderField: Self.routeHeader) ?? ""
            guard let route = Self.lock.withLock({ Self.routes[id] }) else {
                client?.urlProtocol(self, didFailWithError: Self.failure("Refused under tests."))
                return
            }
            let target = "\(request.httpMethod ?? "GET") \(request.url?.host() ?? "")\(request.url?.path() ?? "")"
            route.log.record(route.kind.map { "\($0): \(target)" } ?? target)
            client?.urlProtocol(self, didFailWithError: Self.failure(route.message))
        }

        override func stopLoading() {}

        private static func failure(_ message: String) -> URLError {
            URLError(.resourceUnavailable, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

extension DemoMode {
    /// Started with `-JTKitSandbox YES` (also true or 1), as the UI tests
    /// launch the app. `-JTKitSandbox NO` is an ordinary launch.
    nonisolated public static var isSandboxLaunch: Bool {
        isSandboxLaunch(ProcessInfo.processInfo.arguments)
    }

    nonisolated public static func isSandboxLaunch(_ arguments: [String]) -> Bool {
        isSandbox(arguments: arguments)
    }
}
