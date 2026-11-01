import Foundation
import Testing
@testable import JTKit
@testable import JTKitLiveCheck
@testable import JTKitUITestSupport
import JTKitTestSupport

// The 1.1.0 review of Part B: the launch switch and the gateway. Made-up
// tenants only.

private let environmentA = "11111111-2222-4333-8444-55555555555a"
private let environmentB = "11111111-2222-4333-8444-55555555555b"
private let prefix = "JTKTEST XX 1101-1200"
/// No process has this ID (macOS process IDs stay below 100,000).
private let goneOwner = "999999 Killed App"

private func folder() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "LiveReviewTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A run of the gateway’s process, with its secrets in its own environment.
private func makeRun(upstream: MockServer, tenants: [AllowList.Entry]? = nil, roles: String = "jamf-test-a",
                     extra: [String: String] = [:], ledger: [Ledger.Item] = []) throws -> (LiveCheckRun, URL, URL) {
    let runFolder = folder()
    let list = AllowList(tenants: tenants ?? [
        .init(role: "jamf-test-a", service: .jamfPlatform, region: "eu", environmentID: environmentA, access: .full),
    ])
    let listURL = folder().appending(path: "allowlist.json")
    try JSONEncoder().encode(list).write(to: listURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: listURL.path)
    if !ledger.isEmpty {
        try JSONEncoder().encode(ledger).write(to: runFolder.appending(path: "ledger.json"))
    }
    let environment = [
        "JTKIT_LIVE": "1", "JTKIT_LIVE_PREFIX": prefix, "JTKIT_LIVE_RUN_DIR": runFolder.path,
        "JTKIT_LIVE_ROLES": roles, "JTKIT_LIVE_WRITES": "1",
        "JTKIT_LIVE_JAMF_TEST_A_CLIENT_ID": "client-a", "JTKIT_LIVE_JAMF_TEST_A_CLIENT_SECRET": "s3cret",
    ].merging(extra) { $1 }
    let run = try LiveCheckRun(environment: environment, upstream: upstream.session,
                               readBack: ReadBack(attempts: 1, interval: 0), allowListURL: listURL)
    let owner = folder().appending(path: "release-check.lock.owner")
    try Data("\(getpid()) Example App".utf8).write(to: owner)
    return (run, owner, listURL)
}

/// A test process of the same run, without any secret in its environment.
private func testProcessRun(_ run: LiveCheckRun, listURL: URL) throws -> LiveCheckRun {
    try LiveCheckRun(environment: ["JTKIT_LIVE": "1", "JTKIT_LIVE_PREFIX": prefix, "JTKIT_LIVE_RUN_DIR": run.runFolder.path,
                                   "JTKIT_LIVE_ROLES": run.roles.sorted().joined(separator: ",")], allowListURL: listURL)
}

@MainActor
@Suite("Review B #1: a release check killed without its cleanup", .serialized)
struct LiveOwnerGoneTests {
    @Test func whoHoldsTheLockIsReadFromItsProcess() {
        #expect(LiveLaunch.ownerIsAlive("\(getpid()) Example App"))
        #expect(!LiveLaunch.ownerIsAlive(goneOwner))
        #expect(!LiveLaunch.ownerIsAlive(""))
        #expect(LiveGateway.ownerIsAlive("\(getpid()) Example App"))
        #expect(!LiveGateway.ownerIsAlive(goneOwner))
    }

    @Test func theAppRefusesARunFolderWhoseReleaseCheckIsGone() throws {
        let runFolder = folder(), state = folder()
        let ownerFile = state.appending(path: "release-check.lock.owner")
        try Data(goneOwner.utf8).write(to: ownerFile)
        try Data("{}".utf8).write(to: runFolder.appending(path: "allowlist.json"))
        let launch = LiveLaunch.LaunchFile(port: 50123, lockOwner: goneOwner, connections: [])
        try JSONEncoder().encode(launch).write(to: runFolder.appending(path: LiveLaunch.launchFileName))
        for sandbox in [false, true] {
            let state = LiveLaunch.evaluate(arguments: ["/Applications/Example.app", LiveLaunch.argument, runFolder.path],
                                            environment: [LiveLaunch.tokenVariable: "token"]
                                                .merging(sandbox ? ["APP_SANDBOX_CONTAINER_ID": "be.example"] : [:]) { $1 },
                                            isDebugBuild: true, lockOwnerURL: ownerFile, allowListURL: folder().appending(path: "none"))
            #expect(state == .refused("The release check that started the live check isn’t running any more."))
        }
    }

    @Test func theGatewayDoesntStartForAReleaseCheckThatIsGone() throws {
        let (run, _, _) = try makeRun(upstream: MockServer { _ in .json(200, "{}") })
        let owner = folder().appending(path: "release-check.lock.owner")
        try Data(goneOwner.utf8).write(to: owner)
        #expect(throws: LiveGateway.GatewayError.ownerGone(goneOwner)) { _ = try LiveGateway(run: run, lockOwnerURL: owner) }
    }
}

@MainActor
@Suite("Review B #2, #6, #9, #11: the gateway", .serialized)
struct LiveGatewayReviewTests {
    @Test func theStatusCountsOnlyObjectsMadeSinceTheGatewayStarted() async throws {
        // review B #2: an earlier run's leftovers and earlier steps' objects aren't this test's
        let upstream = MockServer { request in
            request.method == "POST" ? .json(201, #"{"id":"bp-new"}"#) : .json(200, #"{"results":[]}"#)
        }
        let target = "platform:\(environmentA)"
        let (run, owner, _) = try makeRun(upstream: upstream, ledger: [
            Ledger.Item(target: target, resource: "blueprints", id: "bp-old", name: "\(prefix) – earlier run", fromSweep: true),
            Ledger.Item(target: target, resource: "blueprints", id: "bp-step", name: "\(prefix) – earlier step"),
        ])
        let gateway = try LiveGateway(run: run, lockOwnerURL: owner)
        defer { gateway.stop() }
        #expect(gateway.status.notRemoved.isEmpty)
        #expect(run.notRemoved.count == 2, "the cleanup still sees them")

        let client = try LiveGatewayClient(runFolder: run.runFolder)
        var create = URLRequest(url: URL(string: "https://eu.api.jamfcloud.com/blueprints/v1/blueprints")!)
        create.httpMethod = "POST"
        create.setValue(environmentA, forHTTPHeaderField: "X-Environment-Id")
        create.httpBody = try JSONSerialization.data(withJSONObject: ["name": "\(prefix) – this test"])
        _ = try await client.session.data(for: create)
        #expect(gateway.status.notRemoved.count == 1)
        #expect(gateway.status.notRemoved.first?.contains("bp-new") == true)
    }

    @Test func secretsAreHandedOverWithTheTokenNeverInALaunchEnvironment() async throws {
        // review B #6
        let (run, owner, listURL) = try makeRun(upstream: MockServer { _ in .json(200, "{}") })
        let gateway = try LiveGateway(run: run, lockOwnerURL: owner)
        defer { gateway.stop() }
        let client = try LiveGatewayClient(runFolder: run.runFolder)
        #expect(!client.appEnvironment(roles: ["jamf-test-a"]).values.contains("s3cret"))
        #expect(!gateway.environment.values.contains("s3cret"))
        #expect(try await client.secret(role: "jamf-test-a", item: "client-secret") == "s3cret")
        #expect(try client.secretNow(role: "jamf-test-a", item: "client-secret") == "s3cret")
        #expect(try await client.secret(role: "other-role", item: "client-secret") == nil, "only the run's roles")

        // without the token: refused
        let wrong = LiveGatewayRequest(token: "wrong", command: LiveGateway.secretsCommand,
                                       secrets: [LiveSecretItem(role: "jamf-test-a", item: "client-secret")])
        let answer = try await LiveGatewayClient.exchange(wrong, port: gateway.port)
        #expect(answer.error != nil && answer.body == nil)

        // a test process of the run, with no secret in its environment, asks the gateway
        let testRun = try testProcessRun(run, listURL: listURL)
        #expect(try testRun.credential("jamf-test-a", "client-secret") == "s3cret")

        // the app under the switch gets its secret from the gateway, with only the token passed
        let state = LiveLaunch.evaluate(arguments: ["/Applications/Example.app", LiveLaunch.argument, run.runFolder.path],
                                        environment: client.appEnvironment(roles: ["jamf-test-a"]), isDebugBuild: true,
                                        lockOwnerURL: owner, allowListURL: listURL)
        guard case .active(let active) = state else { Issue.record("not on: \(state)"); return }
        #expect(active.secrets.values.sorted() == ["s3cret"])
    }

    @Test func aSecretsOnlyGatewaySendsNothing() async throws {
        let upstream = MockServer { _ in .json(200, "{}") }
        let (run, owner, _) = try makeRun(upstream: upstream)
        let gateway = try LiveGateway(run: run, lockOwnerURL: owner, secretsOnly: true)
        defer { gateway.stop() }
        let client = try LiveGatewayClient(runFolder: run.runFolder)
        #expect(try await client.secret(role: "jamf-test-a", item: "client-secret") == "s3cret")
        var read = URLRequest(url: URL(string: "https://eu.api.jamfcloud.com/blueprints/v1/blueprints")!)
        read.setValue(environmentA, forHTTPHeaderField: "X-Environment-Id")
        await #expect(throws: (any Error).self) { _ = try await client.session.data(for: read) }
        #expect(upstream.requests.isEmpty)
    }

    @Test func aFailureIsReportedWithItsOwnReasonNotAnEarlierRefusal() async throws {
        // review B #9
        let upstream = MockServer { _ in throw URLError(.timedOut) }
        let (run, owner, _) = try makeRun(upstream: upstream)
        let gateway = try LiveGateway(run: run, lockOwnerURL: owner)
        defer { gateway.stop() }
        let token = try String(contentsOf: run.runFolder.appending(path: LiveGateway.tokenFileName), encoding: .utf8)
        let refused = LiveGatewayRequest(token: token, method: "DELETE", url: "https://eu.api.jamfcloud.com/blueprints/v1/blueprints/x",
                                         headers: ["X-Environment-Id": environmentA])
        let first = try await LiveGatewayClient.exchange(refused, port: gateway.port)
        #expect(first.error?.hasPrefix("Refused by the live check:") == true, "\(first.error ?? "no error") / \(run.network.refusals)")
        let read = LiveGatewayRequest(token: token, url: "https://eu.api.jamfcloud.com/blueprints/v1/blueprints",
                                      headers: ["X-Environment-Id": environmentA])
        let second = try await LiveGatewayClient.exchange(read, port: gateway.port)
        #expect(second.error?.contains("Refused") == false, "a timeout isn’t the earlier refusal: \(second.error ?? "")")
        #expect(LiveGateway.failureText(URLError(.timedOut)) == URLError(.timedOut).localizedDescription)
    }

    @Test("1.2.0: a UI test runner that can’t read a sandboxed app’s container finds the gateway in the runner folder")
    func theRunnerFolderHoldsTheLaunchFileAndToken() async throws {
        let (run, owner, listURL) = try makeRun(upstream: MockServer { request in
            request.method == "POST" ? .json(201, #"{"id":"bp-new"}"#) : .json(200, #"{"results":[]}"#)
        })
        let runner = folder().appending(path: "live", directoryHint: .isDirectory)
        let gateway = try LiveGateway(run: run, lockOwnerURL: owner, runnerFolder: runner)
        let manager = FileManager.default
        for place in [run.runFolder, runner] {
            for name in [LiveGateway.launchFileName, LiveGateway.tokenFileName] {
                let attributes = try manager.attributesOfItem(atPath: place.appending(path: name).path)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "\(name) readable by the user only")
            }
        }
        let folderMode = try manager.attributesOfItem(atPath: runner.path)[.posixPermissions] as? NSNumber
        #expect(folderMode?.intValue == 0o700)
        // the same launch file and token in both places, and no secret in either
        for name in [LiveGateway.launchFileName, LiveGateway.tokenFileName] {
            let inRun = try Data(contentsOf: run.runFolder.appending(path: name))
            #expect(try Data(contentsOf: runner.appending(path: name)) == inRun)
            #expect(!String(decoding: inRun, as: UTF8.self).contains("s3cret"))
        }

        // the runner reads the runner folder; the app is still launched with the run folder
        let client = try LiveGatewayClient(runFolder: run.runFolder, gatewayFolder: runner)
        #expect(client.appRunFolder == run.runFolder, "the app is launched with the folder in its container")
        #expect(client.runFolder == runner, "the runner reads the runner folder")
        #expect(try await client.status().refusals.isEmpty)
        #expect(try await client.secret(role: "jamf-test-a", item: "client-secret") == "s3cret")
        let state = LiveLaunch.evaluate(arguments: ["/Applications/Example.app", LiveLaunch.argument, run.runFolder.path],
                                        environment: client.appEnvironment(roles: ["jamf-test-a"]), isDebugBuild: true,
                                        lockOwnerURL: owner, allowListURL: listURL)
        guard case .active = state else { Issue.record("not on: \(state)"); gateway.stop(); return }

        // what the app made is in the runner folder's copy of the ledger once the answer arrives
        var create = URLRequest(url: URL(string: "https://eu.api.jamfcloud.com/blueprints/v1/blueprints")!)
        create.httpMethod = "POST"
        create.setValue(environmentA, forHTTPHeaderField: "X-Environment-Id")
        create.httpBody = try JSONSerialization.data(withJSONObject: ["name": "\(prefix) – made by the app"])
        _ = try await client.session.data(for: create)
        let mirrored = Ledger(fileURL: client.runFolder.appending(path: "ledger.json")).items
        #expect(mirrored.map(\.id) == ["bp-new"], "\(mirrored)")
        let ledgerMode = try manager.attributesOfItem(atPath: runner.appending(path: "ledger.json").path)[.posixPermissions] as? NSNumber
        #expect(ledgerMode?.intValue == 0o600)

        // once stopped, neither folder starts anything
        gateway.stop()
        for place in [run.runFolder, runner] {
            #expect(!manager.fileExists(atPath: place.appending(path: LiveGateway.launchFileName).path))
            #expect(!manager.fileExists(atPath: place.appending(path: LiveGateway.tokenFileName).path))
        }
        #expect(throws: LiveGatewayClient.ClientError.self) { _ = try LiveGatewayClient(runFolder: run.runFolder, gatewayFolder: runner) }
    }

    @Test("1.2.0: without a runner folder (or the run folder named twice) the gateway writes the run folder only")
    func noRunnerFolderWritesTheRunFolderOnly() throws {
        let (run, owner, _) = try makeRun(upstream: MockServer { _ in .json(200, "{}") })
        let same = try LiveGateway(run: run, lockOwnerURL: owner, runnerFolder: run.runFolder)
        #expect(same.runnerFolder == nil)
        same.stop()
        let plain = try LiveGateway(run: run, lockOwnerURL: owner)
        defer { plain.stop() }
        #expect(plain.runnerFolder == nil)
        #expect(FileManager.default.fileExists(atPath: run.runFolder.appending(path: LiveGateway.launchFileName).path))
    }

    @Test func theAppsRetryWaitKeepsTheNetworkBusy() async throws {
        // review B #11
        let (run, owner, listURL) = try makeRun(upstream: MockServer { _ in .json(200, "{}") })
        let gateway = try LiveGateway(run: run, lockOwnerURL: owner)
        defer { gateway.stop() }
        #expect(gateway.pendingRequests == 0)
        let client = try LiveGatewayClient(runFolder: run.runFolder)
        let state = LiveLaunch.evaluate(arguments: ["/Applications/Example.app", LiveLaunch.argument, run.runFolder.path],
                                        environment: client.appEnvironment(roles: ["jamf-test-a"]), isDebugBuild: true,
                                        lockOwnerURL: owner, allowListURL: listURL)
        guard case .active(let active) = state else { Issue.record("not on: \(state)"); return }
        LiveLaunch.reportWait(seconds: 30, to: active)
        #expect(gateway.pendingRequests == 1, "a wait before a retry counts as work in progress")
        #expect(!gateway.waitUntilIdle(quiet: 0.2, timeout: 1))
    }
}

@MainActor
@Suite("Review B #10, #12, #14, #15: the connections the app gets")
struct LiveConnectionReviewTests {
    @Test func aRoleWithTwoServicesGetsTwoNamedConnectionsWithTheirOwnItems() throws {
        // review B #10: jamf-test-b's Platform API and Jamf Pro sign-ins
        let tenants: [AllowList.Entry] = [
            .init(role: "jamf-test-b", service: .jamfPlatform, region: "EU", environmentID: environmentB, access: .full),
            .init(role: "jamf-test-b", service: .jamfPro, host: "test-b.jamf.example", access: .full),
        ]
        let (run, owner, _) = try makeRun(upstream: MockServer { _ in .json(200, "{}") }, tenants: tenants, roles: "jamf-test-b", extra: [
            "JTKIT_LIVE_JAMF_TEST_B_CLIENT_ID": "platform-client", "JTKIT_LIVE_JAMF_TEST_B_CLIENT_SECRET": "platform-secret",
            "JTKIT_LIVE_JAMF_TEST_B_JAMFPRO_USERNAME": "pro-user", "JTKIT_LIVE_JAMF_TEST_B_JAMFPRO_PASSWORD": "pro-password",
        ])
        let gateway = try LiveGateway(run: run, lockOwnerURL: owner)
        defer { gateway.stop() }
        let platform = try #require(gateway.connections.first { $0.service == "jamfPlatform" })
        let pro = try #require(gateway.connections.first { $0.service == "jamfPro" })
        #expect(platform.name == "jamf-test-b (Jamf Platform API)" && pro.name == "jamf-test-b (Jamf Pro)")
        #expect(platform.role == "jamf-test-b" && pro.role == "jamf-test-b")
        #expect(pro.username == "pro-user" && pro.clientID.isEmpty, "never the Platform client ID")
        #expect(pro.secretItem == "jamfpro-password" && platform.secretItem == "client-secret")
        #expect(platform.region == "eu", "review B #14: the region as JTKit reads it")
        #expect(platform.id != pro.id)
        // review B #15: the IDs JTKit promises, the same in every launch
        #expect(platform.id == LiveLaunch.connectionID(role: "jamf-test-b", service: "jamfPlatform"))
        #expect(pro.id == LiveLaunch.connectionID(role: "jamf-test-b", service: "jamfPro"))

        let launch = try JSONDecoder().decode(LiveLaunch.LaunchFile.self,
                                              from: Data(contentsOf: run.runFolder.appending(path: LiveLaunch.launchFileName)))
        #expect(launch.connections.map(\.secretItem).sorted { ($0 ?? "") < ($1 ?? "") } == ["client-secret", "jamfpro-password"])
        let client = try LiveGatewayClient(runFolder: run.runFolder)
        #expect(try client.secretNow(role: "jamf-test-b", item: "jamfpro-password") == "pro-password")
    }

    @Test func aRoleWithOneServiceKeepsItsNameAndTheStableID() throws {
        let (run, owner, _) = try makeRun(upstream: MockServer { _ in .json(200, "{}") })
        let gateway = try LiveGateway(run: run, lockOwnerURL: owner)
        defer { gateway.stop() }
        #expect(gateway.connections.map(\.name) == ["jamf-test-a"])
        #expect(gateway.connections.first?.id == LiveLaunch.connectionID(role: "jamf-test-a"))
        #expect(LiveConnectionDescription.stableID(role: "jamf-test-a") == LiveLaunch.connectionID(role: "jamf-test-a"))
    }

    @Test func aProtectSecretIsItsOwnItemNeverTheMainSecret() {
        // review B #12
        let id = UUID()
        var connection = Connection(id: id, name: "jamf-test-a", service: .jamfPlatform, region: .eu,
                                    environmentID: environmentA, clientID: "client-a")
        connection.protect = JamfProtectSettings(url: "https://protect.example.com", clientID: "protect-client")
        let only = LiveLaunch.State.active(.init(runFolder: folder(), port: 1, token: "t",
                                                 connections: [.init(role: "jamf-test-a", connection: connection)],
                                                 secrets: [LiveLaunch.secretKey(id, "client-secret"): "main"]))
        LiveLaunch.$testState.withValue(only) {
            #expect(LiveLaunch.secrets(for: .main).secret(for: id.uuidString) == "main")
            #expect(LiveLaunch.secrets(for: .protect).secret(for: id.uuidString) == nil, "not the main secret")
        }
        let both = LiveLaunch.State.active(.init(runFolder: folder(), port: 1, token: "t",
                                                 connections: [.init(role: "jamf-test-a", connection: connection)],
                                                 secrets: [LiveLaunch.secretKey(id, "client-secret"): "main",
                                                           LiveLaunch.secretKey(id, LiveLaunch.protectItem): "protect"]))
        LiveLaunch.$testState.withValue(both) {
            #expect(LiveLaunch.secrets(for: .protect).secret(for: id.uuidString) == "protect")
        }
    }

    @Test func anUnreadableLaunchFileIsntCalledMissing() throws {
        // review B #14
        let runFolder = folder()
        try Data("{}".utf8).write(to: runFolder.appending(path: "allowlist.json"))
        try Data(#"{"port":1,"lockOwner":"x","connections":[{"role":"r","connection":{"region":"EU"}}]}"#.utf8)
            .write(to: runFolder.appending(path: LiveLaunch.launchFileName))
        let state = LiveLaunch.evaluate(arguments: ["/Applications/Example.app", LiveLaunch.argument, runFolder.path],
                                        environment: [:], isDebugBuild: true, lockOwnerURL: folder().appending(path: "o"),
                                        allowListURL: folder().appending(path: "none"))
        #expect(state == .refused("The live check’s gateway wrote a live-launch.json this app can’t read."))
    }
}
