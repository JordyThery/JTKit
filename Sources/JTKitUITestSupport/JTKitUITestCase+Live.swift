import XCTest
import JTKitLiveCheck

/// Live UI tests (1.1.0, B4): the real app, launched under the live-check
/// switch, against the release check’s tenants.
///
/// ```swift
/// final class LiveUITests: JTKitUITestCase {
///     override var appName: String { "Blueprint Managed Preferences Editor" }
///     override var launchesLive: Bool { true }
///
///     func testEditAndSave() throws {
///         let gateway = try liveGateway()
///         let api = try LiveJamfPlatformAPI(gateway: gateway, role: "jamf-test-a")
///         // … create JTKTEST objects with `api` (through `liveCall`)
///         try launchLive(roles: ["jamf-test-a"])
///         // … drive the app, then
///         waitForNetwork()
///         // … read back with `api`, remove what was made, then
///         try requireRunObjectsGone()
///     }
/// }
/// ```
///
/// Skipped unless the release check switched live checks on (`JTKIT_LIVE=1`)
/// and started its gateway (`jtkit-live-gateway`). Every request of the app
/// and of the test goes through the gateway; a refused one, or an attempt
/// to reach a saved connection or a real Keychain item, fails the test.
extension JTKitUITestCase {
    /// The release check’s gateway: throws `XCTSkip` outside a release
    /// check’s live stage, fails when the gateway isn’t running.
    public func liveGateway() throws -> LiveGatewayClient {
        let environment = ProcessInfo.processInfo.environment
        guard environment["JTKIT_LIVE"] == "1", let folder = environment["JTKIT_LIVE_RUN_DIR"], !folder.isEmpty else {
            throw XCTSkip("Live UI tests run only from the release check (JTKIT_LIVE=1)")
        }
        if let gateway = liveClient { return gateway }
        // A sandboxed app’s run folder is in its container, which this runner
        // can’t read: the gateway’s launch file and token are then also in
        // the runner folder (the client’s `runFolder`, with a copy of the
        // ledger). The app still gets the run folder (`appRunFolder`).
        let runner = environment["JTKIT_LIVE_RUNNER_DIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
        let gateway = try LiveGatewayClient(runFolder: URL(filePath: folder, directoryHint: .isDirectory), gatewayFolder: runner)
        liveClient = gateway
        return gateway
    }

    /// The run’s prefix, e.g. "JTKTEST BM 1101-1107": every object a test makes starts with it.
    public var livePrefix: String { ProcessInfo.processInfo.environment["JTKIT_LIVE_PREFIX"] ?? "" }

    /// Launches the app under the switch with these roles’ connections:
    /// `-JTKitLiveCheck <run folder>`, a sandbox run (no saved settings, no
    /// update check), demo mode off, no restored windows; the gateway’s
    /// token and the roles’ secrets in its environment only.
    public func launchLive(roles: [String], arguments: [String] = []) throws {
        let gateway = try liveGateway()
        app.launchArguments = Self.liveArguments(runFolder: gateway.appRunFolder.path) + arguments
        var environment = app.launchEnvironment
        for (key, value) in gateway.appEnvironment(roles: roles) { environment[key] = value }
        app.launchEnvironment = environment
        app.launch()
        app.activate()
        clickBeforeFirstEvent()
        didLaunch()
    }

    /// The live-check switch and what goes with it (checked against JTKit’s
    /// `LiveLaunch.argument` by a JTKit test).
    public static let liveArgument = "-JTKitLiveCheck"

    public static func liveArguments(runFolder: String) -> [String] {
        [liveArgument, runFolder, sandboxArgument, "YES", demoArgument, "NO", "-ApplePersistenceIgnoreState", "YES"]
    }

    /// Runs `body` (e.g. a `LiveJamfPlatformAPI` call) and waits for it,
    /// so a UI test can stay synchronous while it drives the app.
    public func liveCall<T>(timeout: TimeInterval = 300, _ body: @escaping () async throws -> T) throws -> T {
        let box = LiveCallBox<T>()
        let done = expectation(description: "live call")
        Task {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            done.fulfill()
        }
        wait(for: [done], timeout: timeout)
        guard let result = box.result else { throw LiveCallTimedOut(seconds: timeout) }
        return try result.get()
    }

    /// Waits until the gateway has had no request in flight for a moment
    /// (the app’s network work finished); fails the test after `timeout`.
    public func waitForNetwork(quiet: TimeInterval = 2, timeout: TimeInterval = 120, file: StaticString = #filePath, line: UInt = #line) {
        guard let gateway = try? liveGateway() else { return XCTFail("No live gateway", file: file, line: line) }
        let deadline = Date().addingTimeInterval(timeout)
        var idleSince: Date?
        while Date() < deadline {
            let pending = (try? liveCall(timeout: 30) { try await gateway.status().pending }) ?? 1
            if pending == 0 {
                let since = idleSince ?? Date()
                idleSince = since
                if Date().timeIntervalSince(since) >= quiet { return }
            } else {
                idleSince = nil
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("The app’s requests didn’t finish within \(Int(timeout)) s", file: file, line: line)
    }

    /// Adds a step’s result to the run’s report (a live step must add one).
    public func recordLive(step: String, passed: Bool, note: String? = nil) {
        guard let gateway = try? liveGateway() else { return }
        _ = try? liveCall(timeout: 30) { try await gateway.record(step: step, passed: passed, note: note) }
    }

    /// Fails unless every object the run made is gone (read back), and
    /// nothing was created outside the ledger.
    public func requireRunObjectsGone() throws {
        let gateway = try liveGateway()
        let left = try liveCall(timeout: 30) { try await gateway.status().notRemoved }
        guard left.isEmpty else { throw LiveObjectsLeft(names: left) }
    }

    /// After every live test: no refused request and no attempt to reach a
    /// saved connection or a real Keychain item.
    func finishLive() {
        guard let gateway = liveClient else { return }
        liveClient = nil
        guard let status = try? liveCall(timeout: 30, { try await gateway.status() }) else {
            return XCTFail("The live gateway didn’t answer at the end of the test")
        }
        XCTAssertTrue(status.violations.isEmpty, "Under the live-check switch the app tried to reach: \(status.violations.joined(separator: "; "))")
        XCTAssertTrue(status.refusals.isEmpty, "Requests refused by the live check: \(status.refusals.map { "\($0.method) \($0.location): \($0.reason)" })")
    }
}

final class LiveCallBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

public struct LiveCallTimedOut: Error, CustomStringConvertible {
    public let seconds: TimeInterval
    public var description: String { "A live call didn’t finish within \(Int(seconds)) s" }
}

public struct LiveObjectsLeft: Error, CustomStringConvertible {
    public let names: [String]
    public var description: String { "Not removed: \(names.joined(separator: "; "))" }
}
