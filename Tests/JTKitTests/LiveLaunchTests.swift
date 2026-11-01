import Foundation
import Testing
@testable import JTKit
@testable import JTKitLiveCheck
@testable import JTKitUITestSupport
import JTKitTestSupport

// The live-check launch switch (1.1.0, B1): when it works, when it is
// refused, and what an app under it never reaches. Made-up tenants only.

private let environmentA = "11111111-2222-4333-8444-55555555555a"
private let prefix = "JTKTEST XX 1101-1200"

private func folder() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "LiveLaunchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A run folder as the gateway leaves it, and a lock owner file.
private struct Setup {
    let runFolder = folder()
    let lockOwner: URL
    let allowList: URL

    init(lockOwner owner: String? = "4123 Example App", allowList: Bool = true, launchFile: Bool = true) {
        let state = folder()
        lockOwner = state.appending(path: "release-check.lock.owner")
        if let owner { try? Data(owner.utf8).write(to: lockOwner) }
        self.allowList = runFolder.appending(path: "allowlist.json")
        if allowList { try? Data("{}".utf8).write(to: self.allowList) }
        if launchFile {
            let connection = Connection(id: UUID(), name: "jamf-test-a", service: .jamfPlatform, region: .eu,
                                        environmentID: environmentA, clientID: "client-a")
            let launch = LiveLaunch.LaunchFile(port: 50123, lockOwner: "4123 Example App",
                                               connections: [.init(role: "jamf-test-a", connection: connection)])
            try? JSONEncoder().encode(launch).write(to: runFolder.appending(path: LiveLaunch.launchFileName))
        }
    }

    var arguments: [String] { ["/Applications/Example.app", LiveLaunch.argument, runFolder.path] }
    var environment: [String: String] {
        [LiveLaunch.tokenVariable: "token", "JTKIT_LIVE_JAMF_TEST_A_CLIENT_SECRET": "s3cret"]
    }

    func evaluate(debug: Bool = true, environment extra: [String: String] = [:]) -> LiveLaunch.State {
        LiveLaunch.evaluate(arguments: arguments, environment: environment.merging(extra) { $1 }, isDebugBuild: debug,
                            lockOwnerURL: lockOwner, allowListURL: folder().appending(path: "none.json"))
    }
}

@Suite("Live-check switch: when it is refused")
struct LiveLaunchRefusalTests {
    @Test func withoutTheArgumentItIsAnOrdinaryLaunch() {
        #expect(LiveLaunch.evaluate(arguments: ["/Applications/Example.app"], environment: [:]) == .off)
    }

    @Test func refusedInAReleaseBuild() {
        #expect(Setup().evaluate(debug: false) == .refused("The live-check switch works only in a Debug build."))
    }

    @Test func refusedWithoutTheReleaseChecksLock() {
        #expect(Setup(lockOwner: nil).evaluate() == .refused("The live-check switch works only while a release check holds its lock."))
        // a lock held by another release check
        #expect(Setup(lockOwner: "999 Other App").evaluate() == .refused("The live-check switch works only while a release check holds its lock."))
    }

    @Test func refusedWithoutTheAllowList() {
        #expect(Setup(allowList: false).evaluate() == .refused("The live-check switch works only with the allow-list present."))
    }

    @Test func refusedWithoutTheGateway() {
        #expect(Setup(launchFile: false).evaluate() == .refused("The live check’s gateway isn’t running: live-launch.json is missing."))
        var environment = Setup().environment
        environment[LiveLaunch.tokenVariable] = nil
        let setup = Setup()
        #expect(LiveLaunch.evaluate(arguments: setup.arguments, environment: environment, isDebugBuild: true,
                                    lockOwnerURL: setup.lockOwner, allowListURL: setup.allowList)
                == .refused("The live check’s gateway didn’t pass its token."))
    }

    @Test func refusedWithoutARunFolder() {
        let state = LiveLaunch.evaluate(arguments: ["/Applications/Example.app", LiveLaunch.argument], environment: [:], isDebugBuild: true)
        #expect(state == .refused("The live-check switch needs the run folder after -JTKitLiveCheck."))
    }

    @Test func onWithTheReleaseChecksConnectionsAndSecrets() {
        guard case .active(let active) = Setup().evaluate() else { Issue.record("not on"); return }
        #expect(active.port == 50123)
        #expect(active.connections.map(\.role) == ["jamf-test-a"])
        #expect(active.secrets.values.sorted() == ["s3cret"])
    }

    @Test func aSandboxedAppTakesTheLockFromTheGateway() {
        // the app can’t read the lock itself; the gateway checked it
        let state = Setup(lockOwner: nil).evaluate(environment: ["APP_SANDBOX_CONTAINER_ID": "be.example.app"])
        #expect(state.isActiveState)
    }

    @Test func aRefusedSwitchReachesNothing() async {
        let refused = LiveLaunch.State.refused("The live-check switch works only in a Debug build.")
        await LiveLaunch.$testState.withValue(refused) {
            let session = LiveLaunch.route(.shared)
            #expect(session !== URLSession.shared)
            let recorder = RequestRecorder(session: .shared, log: nil)
            await #expect(throws: URLError.self) {
                _ = try await recorder.send(URLRequest(url: URL(string: "https://eu.api.jamfcloud.com/auth/token")!))
            }
        }
    }
}

extension LiveLaunch.State {
    var isActiveState: Bool {
        if case .active = self { return true }
        return false
    }
}

@MainActor
@Suite("Under the live-check switch: never a saved connection or a real Keychain item")
struct LiveLaunchBoundaryTests {
    private func active(_ setup: Setup = Setup()) -> (LiveLaunch.State, URL) {
        guard case .active(let active) = setup.evaluate() else { return (.off, setup.runFolder) }
        return (.active(active), setup.runFolder)
    }

    private func violations(_ runFolder: URL) -> String {
        (try? String(contentsOf: runFolder.appending(path: LiveLaunch.violationsFileName), encoding: .utf8)) ?? ""
    }

    @Test func aRealKeychainItemIsRefusedAndWrittenDown() {
        let (state, runFolder) = active()
        let store = KeychainSecretStore(service: "JTKit.LiveLaunchTests.\(UUID().uuidString)")
        LiveLaunch.$testState.withValue(state) {
            #expect(throws: SecretStoreError.self) { try store.readSecret(for: "account") }
            #expect(throws: SecretStoreError.self) { try store.hasSecret(for: "account") }
            #expect(throws: SecretWriteError.self) { try store.writeSecret("x", for: "account") }
            #expect(!store.deleteSecrets(withAccountPrefix: "acc"))
        }
        #expect(violations(runFolder).components(separatedBy: "\n").filter { $0.contains("Keychain item") }.count == 4)
    }

    @Test func savedConnectionsAreRefusedAndWrittenDown() throws {
        let (state, runFolder) = active()
        let file = folder().appending(path: "tenants.json")
        try Data("[]".utf8).write(to: file)
        let json = JSONFileConnectionStorage<SampleTenant>(fileURL: file)
        let saved = UserDefaultsConnectionStorage<SampleTenant>(key: "connectionProfiles")
        let sandbox = UserDefaultsConnectionStorage<SampleTenant>(key: "connectionProfiles",
                                                                  defaults: UserDefaults(suiteName: "JTKit.LiveLaunchTests.\(UUID().uuidString)")!)
        LiveLaunch.$testState.withValue(state) {
            #expect(throws: LiveLaunch.SavedConnectionsRefused.self) { try json.load() }
            #expect(throws: LiveLaunch.SavedConnectionsRefused.self) { try json.save([]) }
            #expect(throws: LiveLaunch.SavedConnectionsRefused.self) { try saved.load() }
            // a sandbox run’s in-memory defaults are no saved connections
            #expect((try? sandbox.load()) != nil)
        }
        #expect(violations(runFolder).components(separatedBy: "\n").filter { $0.contains("saved connections") }.count == 3)
    }

    @Test func theStoreHoldsOnlyTheReleaseChecksConnectionsWithTheirSecrets() throws {
        let (state, runFolder) = active()
        let file = folder().appending(path: "tenants.json")
        let secrets = InMemorySecretStore(["saved": "never read"])
        LiveLaunch.$testState.withValue(state) {
            let store = ConnectionStore<SampleTenant>(
                storage: JSONFileConnectionStorage(fileURL: file), secrets: [.main: SecretLocation(store: secrets)],
                liveRecord: { connection in
                    SampleTenant(id: connection.id, name: connection.name, region: connection.region.rawValue,
                                 environmentId: connection.environmentID, clientId: connection.clientID)
                })
            #expect(store.records.map(\.name) == ["jamf-test-a"])
            #expect(store.problem == nil)
            #expect((try? store.readSecret(for: store.records[0].connection)) == "s3cret")
            // saving changes only the run’s in-memory list, never the file or the app’s Keychain
            #expect((try? store.save(store.records[0], secrets: [.main: "other"])) == nil)
            // without liveRecord the store is empty
            let empty = ConnectionStore<SampleTenant>(storage: JSONFileConnectionStorage(fileURL: file), secrets: [:])
            #expect(empty.records.isEmpty)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(secrets.all == ["saved": "never read"])
        #expect(!violations(runFolder).contains("tenants.json"))
    }

    @Test func demoModeStaysOffAndItIsASandboxRun() {
        let (state, _) = active()
        LiveLaunch.$testState.withValue(state) {
            let demo = DemoMode(key: "demo", defaults: UserDefaults(suiteName: "JTKit.LiveLaunchTests.\(UUID().uuidString)")!,
                                arguments: ["/Applications/Example.app", LiveLaunch.argument, "/tmp/run", "-JTKitDemo", "YES"])
            #expect(!demo.isOn)
            demo.isOn = true
            #expect(!demo.isOn)
            #expect(demo.isSandbox, "so the update check and public lookups stay off")
        }
    }

    @Test func theLaunchArgumentsMatchTheUITestSide() {
        #expect(JTKitUITestCase.liveArgument == LiveLaunch.argument)
        #expect(LiveGateway.launchFileName == LiveLaunch.launchFileName)
        #expect(LiveGateway.violationsFileName == LiveLaunch.violationsFileName)
        #expect(LiveCheckRun.variable(role: "jamf-test-a", item: "client-secret")
                == LiveLaunch.variable(role: "jamf-test-a", item: "client-secret"))
    }

    @Test func theGatewaysLaunchFileReadsAsJTKits() throws {
        let description = LiveConnectionDescription(name: "jamf-test-a", service: "jamfPlatform", signIn: "apiClient",
                                                     region: "eu", environmentID: environmentA, clientID: "client-a")
        let file = LiveLaunchFile(port: 1234, lockOwner: "1 App", connections: [.init(role: "jamf-test-a", connection: description)])
        let read = try JSONDecoder().decode(LiveLaunch.LaunchFile.self, from: JSONEncoder().encode(file))
        #expect(read.connections.first?.connection.environmentID == environmentA)
        #expect(read.connections.first?.connection.service == .jamfPlatform)
        #expect(read.connections.first?.connection.signIn == .apiClient)
        #expect(description.secretItem == LiveLaunch.secretItem(.apiClient))
    }
}

@MainActor
@Suite("The gateway: every request of the app decided by the release check’s rules", .serialized)
struct LiveGatewayTests {
    private func makeRun(upstream: MockServer) throws -> (LiveCheckRun, URL, URL) {
        let runFolder = folder()
        let list = AllowList(tenants: [
            .init(role: "jamf-test-a", service: .jamfPlatform, region: "eu", environmentID: environmentA, access: .full),
        ])
        let listURL = folder().appending(path: "allowlist.json")
        try JSONEncoder().encode(list).write(to: listURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: listURL.path)
        let run = try LiveCheckRun(environment: [
            "JTKIT_LIVE": "1", "JTKIT_LIVE_PREFIX": prefix, "JTKIT_LIVE_RUN_DIR": runFolder.path,
            "JTKIT_LIVE_ROLES": "jamf-test-a", "JTKIT_LIVE_WRITES": "1",
            "JTKIT_LIVE_JAMF_TEST_A_CLIENT_ID": "client-a", "JTKIT_LIVE_JAMF_TEST_A_CLIENT_SECRET": "s3cret",
        ], upstream: upstream.session, readBack: ReadBack(attempts: 1, interval: 0), allowListURL: listURL)
        let owner = folder().appending(path: "release-check.lock.owner")
        try Data("4123 Example App".utf8).write(to: owner)
        return (run, owner, listURL)
    }

    @Test func withoutTheLockTheGatewayDoesntStart() throws {
        let (run, _, _) = try makeRun(upstream: MockServer { _ in .json(200, "{}") })
        #expect(throws: LiveGateway.GatewayError.notLocked) {
            _ = try LiveGateway(run: run, roles: ["jamf-test-a"], lockOwnerURL: folder().appending(path: "missing"))
        }
    }

    @Test func requestsGoThroughTheGatewaysRulesAndAnswersComeBack() async throws {
        let upstream = MockServer { request in
            request.method == "POST" ? .json(201, #"{"id":"bp-1"}"#) : .json(200, #"{"results":[]}"#)
        }
        let (run, owner, listURL) = try makeRun(upstream: upstream)
        let gateway = try LiveGateway(run: run, roles: ["jamf-test-a"], lockOwnerURL: owner)
        defer { gateway.stop() }
        #expect(gateway.environment["JTKIT_LIVE_JAMF_TEST_A_CLIENT_SECRET"] == "s3cret")
        #expect(gateway.connections.first?.clientID == "client-a")

        // the app as it starts under the switch
        let arguments = ["/Applications/Example.app", LiveLaunch.argument, run.runFolder.path]
        let environment = gateway.environment
        let state = LiveLaunch.evaluate(arguments: arguments, environment: environment, isDebugBuild: true,
                                        lockOwnerURL: owner, allowListURL: listURL)
        guard case .active = state else { Issue.record("not on: \(state)"); return }
        #expect(LiveLaunch.$testState.withValue(state) { LiveLaunch.connections.map(\.name) } == ["jamf-test-a"])

        try await LiveLaunch.$testState.withValue(state) {
            // the app passes its own session; under the switch it is never used
            let recorder = RequestRecorder(session: .shared, log: nil)
            var read = URLRequest(url: URL(string: "https://eu.api.jamfcloud.com/blueprints/v1/blueprints")!)
            read.setValue(environmentA, forHTTPHeaderField: "X-Environment-Id")
            let (_, answer) = try await recorder.send(read)
            #expect(answer.statusCode == 200)

            var create = URLRequest(url: URL(string: "https://eu.api.jamfcloud.com/blueprints/v1/blueprints")!)
            create.httpMethod = "POST"
            create.setValue(environmentA, forHTTPHeaderField: "X-Environment-Id")
            create.httpBody = try JSONSerialization.data(withJSONObject: ["name": "\(prefix) – B"])
            let (created, _) = try await recorder.send(create)
            #expect(String(decoding: created, as: UTF8.self).contains("bp-1"))

            // refused by the rules: nothing reaches the tenant
            var other = URLRequest(url: URL(string: "https://eu.api.jamfcloud.com/blueprints/v1/blueprints")!)
            other.httpMethod = "POST"
            other.setValue(environmentA, forHTTPHeaderField: "X-Environment-Id")
            other.httpBody = try JSONSerialization.data(withJSONObject: ["name": "Not a test object"])
            await #expect(throws: URLError.self) { _ = try await recorder.send(other) }
        }
        #expect(upstream.requests.count == 2)
        #expect(upstream.requests.allSatisfy { $0.header(LiveGatewayURLProtocol.routeHeader) == nil }, "the route stays on this Mac")
        #expect(run.ledger.items.map(\.name) == ["\(prefix) – B"], "the gateway’s ledger has the app’s create")
        #expect(gateway.waitUntilIdle(quiet: 0.2, timeout: 5))
        #expect(gateway.handledRequests == 3)
    }

    @Test func aRequestWithoutTheTokenIsRefused() async throws {
        let upstream = MockServer { _ in .json(200, "{}") }
        let (run, owner, _) = try makeRun(upstream: upstream)
        let gateway = try LiveGateway(run: run, roles: ["jamf-test-a"], lockOwnerURL: owner)
        defer { gateway.stop() }
        let state = LiveLaunch.State.active(.init(runFolder: run.runFolder, port: gateway.port, token: "wrong",
                                                  connections: [], secrets: [:]))
        await LiveLaunch.$testState.withValue(state) {
            var read = URLRequest(url: URL(string: "https://eu.api.jamfcloud.com/blueprints/v1/blueprints")!)
            read.setValue(environmentA, forHTTPHeaderField: "X-Environment-Id")
            await #expect(throws: URLError.self) { _ = try await RequestRecorder(session: .shared, log: nil).send(read) }
        }
        #expect(upstream.requests.isEmpty)
    }

    @Test func aUITestTalksToTheGatewayAsAClient() async throws {
        let upstream = MockServer { _ in .json(200, #"{"results":[]}"#) }
        let (run, owner, _) = try makeRun(upstream: upstream)
        let gateway = try LiveGateway(run: run, lockOwnerURL: owner)
        let client = try LiveGatewayClient(runFolder: run.runFolder)
        #expect(client.launch.port == gateway.port)
        #expect(client.launch.connections.map(\.role) == ["jamf-test-a"])

        var read = URLRequest(url: URL(string: "https://eu.api.jamfcloud.com/blueprints/v1/blueprints")!)
        read.setValue(environmentA, forHTTPHeaderField: "X-Environment-Id")
        let (_, response) = try await client.session.data(for: read)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        try await client.record(step: "jamf-test-a: live UI: a step", passed: true, note: "note")
        let results = try String(contentsOf: run.runFolder.appending(path: "results.jsonl"), encoding: .utf8)
        #expect(results.contains("live UI: a step"))
        let status = try await client.status()
        #expect(status.pending == 0 && status.handled == 1)
        #expect(status.refusals.isEmpty && status.violations.isEmpty && status.notRemoved.isEmpty)

        let environment = client.appEnvironment(roles: ["jamf-test-a"], from: ["JTKIT_LIVE_JAMF_TEST_A_CLIENT_SECRET": "s3cret"])
        #expect(environment["JTKIT_LIVE_JAMF_TEST_A_CLIENT_SECRET"] == "s3cret")
        #expect(environment["JTKIT_LIVE_APP_ROLES"] == "jamf-test-a")
        #expect(environment[LiveLaunch.tokenVariable]?.isEmpty == false)

        gateway.stop()
        #expect(throws: LiveGatewayClient.ClientError.self) { _ = try LiveGatewayClient(runFolder: run.runFolder) }
    }

    @Test func tokensCompareWhole() {
        #expect(LiveGateway.same("abc", "abc"))
        #expect(!LiveGateway.same("abc", "abd"))
        #expect(!LiveGateway.same("abc", "abcd"))
    }
}

@MainActor
@Suite("A13 live check, against a mock tenant")
struct LiveBlueprintDeployCheckTests {
    @Test func createsDeploysConfirmsAndRemovesWithoutLastDeployment() async throws {
        let state = Locked<[String: String]>([:])   // what the mock tenant holds: path → state
        let blueprintID = "0a1b2c3d-4444-4444-8444-0123456789ab"
        let gets = Counter()
        let upstream = MockServer { request in
            let path = request.path
            switch (request.method, path) {
            case ("POST", "/auth/token"):
                return .json(200, #"{"access_token":"tok","expires_in":900}"#)
            case ("POST", "/device-groups/v1/device-groups"):
                state.withLock { $0["group"] = "there" }
                return .json(201, #"{"id":"77"}"#)
            case ("GET", "/device-groups/v1/device-groups/77"):
                return state.withLock { $0["group"] } == "there"
                    ? .json(200, #"{"id":"77","name":"JTKTEST XX 1101-1200 – A13 Group","groupType":"STATIC","memberCount":0}"#)
                    : .json(404, "{}")
            case ("GET", "/device-groups/v1/device-groups/77/members"):
                return .json(200, #"{"totalCount":0,"results":[]}"#)
            case ("GET", "/api/v2/groups"), ("GET", "/pro/v2/groups"):
                // Jamf’s group list, read back after a Platform group’s delete
                return .json(200, #"{"totalCount":0,"results":[]}"#)
            case ("DELETE", "/device-groups/v1/device-groups/77"):
                state.withLock { $0["group"] = nil }
                return MockResponse(status: 204, body: Data())
            case ("POST", "/blueprints/v1/blueprints"):
                state.withLock { $0["blueprint"] = "there" }
                return .json(201, #"{"id":"\#(blueprintID)"}"#)
            case ("POST", "/blueprints/v1/blueprints/\(blueprintID)/deploy"):
                return MockResponse(status: 202, body: Data())
            case ("GET", "/blueprints/v1/blueprints/\(blueprintID)/report"):
                return .json(404, "{}")
            case ("GET", "/blueprints/v1/blueprints/\(blueprintID)"):
                guard state.withLock({ $0["blueprint"] }) == "there" else { return .json(404, "{}") }
                // no lastDeployment: the Blueprint's own state decides (1: before the deploy)
                let deployed = gets.next() > 2
                return .json(200, #"{"id":"\#(blueprintID)","name":"JTKTEST XX 1101-1200 – A13 Blueprint","deploymentState":{"state":"\#(deployed ? "DEPLOYED" : "OUT_OF_DATE")"},"steps":[]}"#)
            case ("DELETE", "/blueprints/v1/blueprints/\(blueprintID)"):
                state.withLock { $0["blueprint"] = nil }
                return MockResponse(status: 204, body: Data())
            default:
                return .json(400, #"{"unexpected":"\#(request.method) \#(path)"}"#)
            }
        }
        let listURL = folder().appending(path: "allowlist.json")
        try JSONEncoder().encode(AllowList(tenants: [
            .init(role: "jamf-test-a", service: .jamfPlatform, region: "eu", environmentID: environmentA, access: .full),
        ])).write(to: listURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: listURL.path)
        let run = try LiveCheckRun(environment: [
            "JTKIT_LIVE": "1", "JTKIT_LIVE_PREFIX": prefix, "JTKIT_LIVE_RUN_DIR": folder().path,
            "JTKIT_LIVE_ROLES": "jamf-test-a", "JTKIT_LIVE_WRITES": "1",
            "JTKIT_LIVE_JAMF_TEST_A_CLIENT_ID": "client-a", "JTKIT_LIVE_JAMF_TEST_A_CLIENT_SECRET": "s3cret",
        ], upstream: upstream.session, readBack: ReadBack(attempts: 2, interval: 0), allowListURL: listURL)

        let poller = JamfPlatform.Poller(sleep: { _ in }, now: { ContinuousClock.now })
        let result = try await LiveBlueprintDeployCheck.run(run, poller: poller)
        #expect(result.deployed)
        #expect(!result.confirmedByLastDeployment, "the mock’s answers have no lastDeployment")
        #expect(result.jobState == "SUCCEEDED")
        #expect(result.removed)
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
        try run.requireNothingLeft()
        #expect(upstream.requests.filter { $0.method == "POST" && $0.path.hasSuffix("/deploy") }.count == 1)
    }
}
