import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

/// JTKit's real Jamf Platform client against the demo server, as an app uses it.
private func demoClient(_ server: DemoJamfPlatformServer = DemoJamfPlatformServer(),
                        log: ActivityLog? = nil) throws -> (JamfPlatform.Client, DemoNetwork) {
    let network = DemoNetwork(servers: [DemoSamples.platformHost: server])
    let recorder = RequestRecorder(session: network.session, log: log, service: "Jamf Platform API", connection: "Contoso (Demo)")
    let client = try JamfPlatform.Client(connection: .demoJamfPlatform, secret: { "demo-secret" }, recorder: recorder,
                                         sleep: { _ in })
    return (client, network)
}

@Suite("Demo Jamf Platform server")
struct DemoJamfPlatformServerTests {
    @Test("Signs in and lists Contoso's device groups and Blueprints, newest first")
    func listsSampleData() async throws {
        let (client, _) = try demoClient()
        let groups = try await client.deviceGroups()
        #expect(groups.map(\.name) == DemoSamples.platformGroups.map(\.name))
        #expect(groups.first?.memberCount == 48)

        let list = try await JamfPlatform.Blueprints(client: client).list()
        #expect(list.count == 6)
        #expect(list.first?.name == "Contoso – Made in Jamf, No Scope")
        #expect(list.last?.name == "Contoso – Finance Division Macs")
        #expect(try await JamfPlatform.Blueprints(client: client).list(search: "iPad").map(\.name) == ["Contoso – iPad App Settings"])
    }

    @Test("Pages are answered page by page")
    func paging() async throws {
        let (client, _) = try demoClient()
        let page = try await JamfPlatform.Blueprints(client: client).listPage(page: 1, pageSize: 4)
        #expect(page.results.count == 2)
        #expect(page.totalCount == 6)
        #expect(try await JamfPlatform.Blueprints(client: client).list(pageSize: 4).count == 6)
    }

    @Test("Create, patch steps and scope, deploy and report, as on a tenant")
    func writeAndDeploy() async throws {
        let server = DemoJamfPlatformServer(pollsToSucceed: 2)
        let (client, _) = try demoClient(server)
        let blueprints = JamfPlatform.Blueprints(client: client)
        let group = DemoSamples.platformGroups[1].id
        let step = LosslessJSON.object(LosslessJSON.Object([
            "name": .string("Step 1"),
            "components": .array([.object(LosslessJSON.Object(["identifier": .string("com.jamf.ddm.sw-updates"),
                                                               "configuration": .object(LosslessJSON.Object())]))]),
        ]))
        let id = try await blueprints.create(name: "Contoso – Test", description: nil, deviceGroups: [group], steps: [step])
        #expect(server.createCount == 1)

        let steps = LosslessJSON.array([step, step])
        try await blueprints.patchSteps(id: id, steps: steps)
        #expect(try await blueprints.detail(id: id).steps?.arrayValue?.count == 2, "arrays replaced whole")
        try await blueprints.patchScope(id: id, deviceGroups: [DemoSamples.platformGroups[0].id])
        #expect(try await blueprints.detail(id: id).scopeDeviceGroups == [DemoSamples.platformGroups[0].id])

        try await blueprints.deploy(id: id)
        #expect(try await blueprints.detail(id: id).overview.deploymentState?.lastDeploymentState == "PENDING")
        let done = try await blueprints.detail(id: id)
        #expect(done.overview.deploymentState?.state == .deployed)
        #expect(done.overview.deploymentState?.lastDeploymentState == "SUCCEEDED")
        #expect(try await blueprints.report(id: id) == JamfPlatform.BlueprintReport(succeeded: 48, failed: 0, pending: 0))
    }

    @Test("Changing a deployed Blueprint makes it Out of Date")
    func outOfDate() async throws {
        let (client, _) = try demoClient()
        let blueprints = JamfPlatform.Blueprints(client: client)
        let id = DemoSamples.uuid(0xb001)
        #expect(try await blueprints.detail(id: id).overview.deploymentState?.state == .deployed)
        try await blueprints.patchScope(id: id, deviceGroups: [DemoSamples.platformGroups[2].id])
        #expect(try await blueprints.detail(id: id).overview.deploymentState?.state == .outOfDate)
    }

    @Test("Steps of a Blueprint without a scope are refused; a scope-only change works, then steps do")
    func noScope() async throws {
        let (client, _) = try demoClient()
        let blueprints = JamfPlatform.Blueprints(client: client)
        let id = DemoSamples.uuid(0xb005)
        let detail = try await blueprints.detail(id: id)
        #expect(detail.scopeDeviceGroups.isEmpty)
        let steps = try #require(detail.steps)
        let error = await #expect(throws: JamfPlatformError.self) { try await blueprints.patchSteps(id: id, steps: steps) }
        #expect(error?.body?.errors.first?.field == "scopeId")
        try await blueprints.patchScope(id: id, deviceGroups: [DemoSamples.platformGroups[0].id])
        try await blueprints.patchSteps(id: id, steps: steps)
    }

    @Test("A Blueprint assigned to a division can't be changed")
    func divisionLocked() async throws {
        let (client, _) = try demoClient()
        let blueprints = JamfPlatform.Blueprints(client: client)
        let id = DemoSamples.uuid(0xb006)
        let detail = try await blueprints.detail(id: id)
        #expect(detail.isDivisionLocked)
        let error = await #expect(throws: JamfPlatformError.self) {
            try await blueprints.patchSteps(id: id, steps: try #require(detail.steps))
        }
        #expect(error?.hasCode(.divisionPatchNotAllowed) == true)
    }

    @Test("Wi-Fi without SetupModes is refused, as live")
    func wifiSetupModes() async throws {
        let (client, _) = try demoClient()
        let profile = LosslessJSON.object(LosslessJSON.Object([
            "identifier": .string("com.jamf.ddm-configuration-profile"),
            "configuration": .object(LosslessJSON.Object(["payloadContent": .array([.object(LosslessJSON.Object([
                "payloadType": .string("com.apple.wifi.managed"), "SetupModes": .array([]),
            ]))])])),
        ]))
        let step = LosslessJSON.object(LosslessJSON.Object(["name": .string("Step 1"), "components": .array([profile])]))
        await #expect(throws: JamfPlatformError.self) {
            _ = try await JamfPlatform.Blueprints(client: client).create(
                name: "Wi-Fi", description: nil, deviceGroups: [DemoSamples.platformGroups[0].id], steps: [step])
        }
    }

    @Test("The Jamf School scenario has no device groups and numeric group IDs")
    func jamfSchool() async throws {
        let (client, _) = try demoClient(DemoJamfPlatformServer(scenario: .jamfSchool))
        let error = await #expect(throws: JamfPlatformError.self) { _ = try await client.deviceGroups() }
        #expect(error?.hasCode(.tenantNotFound) == true)
        let detail = try await JamfPlatform.Blueprints(client: client).detail(id: DemoSamples.uuid(0xb003))
        #expect(detail.scopeDeviceGroups == ["102"])
    }

    @Test("Requests show in the activity log under the demo connection")
    @MainActor
    func activityLog() async throws {
        let log = ActivityLog()
        let (client, _) = try demoClient(log: log)
        _ = try await client.deviceGroups()
        #expect(log.entries.contains { $0.connection == "Contoso (Demo)" })
    }
}

@Suite("Demo network")
struct DemoNetworkTests {
    @Test("Nothing leaves the app: a host without a demo server fails, real hosts included",
          arguments: ["https://eu.api.jamfcloud.com/auth/token", "https://graph.microsoft.com/v1.0/me",
                      "https://example.com/", "http://127.0.0.1:9/"])
    func unknownHostFails(address: String) async throws {
        let network = DemoNetwork(servers: [DemoSamples.platformHost: DemoJamfPlatformServer()])
        let url = try #require(URL(string: address))
        let error = await #expect(throws: URLError.self) { _ = try await network.session.data(from: url) }
        #expect(error?.code == .cannotFindHost)
    }

    @Test("A demo server answers only its own network's session")
    func separateNetworks() async throws {
        let first = DemoNetwork(servers: [DemoSamples.platformHost: DemoJamfPlatformServer()])
        let second = DemoNetwork(servers: [:])
        let url = try #require(URL(string: "https://\(DemoSamples.platformHost)/device-groups/v1/device-groups"))
        let (_, response) = try await first.session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        await #expect(throws: URLError.self) { _ = try await second.session.data(from: url) }
    }
}

@Suite("Demo connections and secrets")
@MainActor
struct DemoConnectionTests {
    @Test("Demo connections are recognised by ID and by address; real ones aren't")
    func isDemo() {
        #expect(Connection.demoJamfPlatform.isDemo)
        #expect(Connection(id: UUID(uuidString: DemoSamples.uuid(0x42))!, name: "x", service: .jamfPro).isDemo)
        #expect(Connection(name: "x", service: .jamfPro, serverURL: "https://contoso.demo.invalid").isDemo)
        #expect(Connection(name: "x", service: .jamfPlatform, hostOverride: "staging.demo.invalid").isDemo)
        #expect(!Connection(name: "x", service: .jamfPlatform, environmentID: UUID().uuidString).isDemo)
        #expect(!Connection(name: "x", service: .jamfPro, serverURL: "https://example.jamfcloud.com").isDemo)
    }

    @Test("The demo secret store never writes")
    func demoSecretsRefuseWrites() {
        let store = DemoSecretStore()
        #expect(store.secret(for: "any") == "demo-secret")
        #expect(!store.setSecret("x", for: "any"))
        #expect(!store.setSecret(nil, for: "any"))
    }

    @Test("Saved connections refuse a demo connection and its secret")
    func storeRefusesDemo() throws {
        let secrets = InMemorySecretStore()
        let store = ConnectionStore<SampleTenant>(storage: InMemoryConnectionStorage(),
                                                 secrets: [.main: SecretLocation(store: secrets)])
        let demoID = SampleTenant(id: UUID(uuidString: DemoSamples.uuid(0xde01))!, name: "Contoso (Demo)")
        #expect(throws: ConnectionStoreError.self) { try store.save(demoID) }
        #expect(throws: ConnectionStoreError.self) { try store.save(demoID, secrets: [.main: "s"]) }
        let demoHost = SampleTenant(name: "Contoso", serverURL: "https://contoso.demo.invalid")
        #expect(throws: ConnectionStoreError.self) { try store.save(demoHost) }
        #expect(!store.setSecret("s", for: demoHost.connection))
        #expect(store.secret(for: Connection.demoJamfPlatform) == nil)
        #expect(store.records.isEmpty)

        let real = SampleTenant(name: "Sandbox")
        try store.save(real, secrets: [.main: "s"])
        #expect(store.records == [real])
    }

    @Test("Sandbox stores keep everything in memory")
    func sandboxStores() throws {
        let secrets = SandboxSecretStore()
        #expect(secrets.setSecret("s", for: "a"))
        #expect(secrets.secret(for: "a") == "s")
        let storage = InMemoryConnectionStorage<SampleTenant>()
        try storage.save([SampleTenant(name: "x")])
        #expect(try storage.load().count == 1)
    }
}

@Suite("Demo mode switch", .serialized)
@MainActor
struct DemoModeSwitchTests {
    private func defaults() -> (UserDefaults, String) {
        let name = "jtkit-demo-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("The choice is saved under the app's key")
    func saved() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let demo = DemoMode(key: "demoMode", defaults: defaults, arguments: [])
        #expect(!demo.isOn)
        demo.isOn = true
        #expect(defaults.bool(forKey: "demoMode"))
        #expect(DemoMode(key: "demoMode", defaults: defaults, arguments: []).isOn)
        demo.isOn = false
    }

    @Test("-JTKitDemo YES turns it on for this run only")
    func launchArgument() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let demo = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app", "-JTKitDemo", "YES"])
        #expect(demo.isOn && !demo.isSandbox)
        demo.isOn = false
        demo.isOn = true
        #expect(defaults.object(forKey: "demoMode") == nil, "nothing saved")
        demo.isOn = false
    }

    @Test("A sandbox run saves nothing and reads the scenario")
    func sandbox() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "demoMode")
        let demo = DemoMode(key: "demoMode", defaults: defaults,
                            arguments: ["app", "-JTKitSandbox", "YES", "-JTKitDemoScenario", "jamfSchool"])
        #expect(demo.isSandbox && !demo.isOn, "a sandbox run doesn't take the saved choice")
        #expect(demo.scenario == .jamfSchool)
        demo.isOn = true
        demo.isOn = false
        #expect(defaults.bool(forKey: "demoMode"), "unchanged")
    }

    @Test("The demo source reaches the demo server, the same one for the whole launch")
    func source() async throws {
        let demo = DemoMode(key: "demoMode", defaults: defaults().0, arguments: [])
        let source = demo.jamfPlatform()
        #expect(source.connection == .demoJamfPlatform)
        #expect(try source.secret() == "demo-secret")
        let client = try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                             recorder: RequestRecorder(session: source.session, log: nil))
        _ = try await JamfPlatform.Blueprints(client: client).create(
            name: "Kept", description: nil, deviceGroups: [DemoSamples.platformGroups[0].id], steps: [])
        #expect(demo.jamfPlatformServer.createCount == 1)
        #expect(demo.jamfPlatform().session === source.session)
    }

    @Test("The scratch folder is temporary and the same for the launch")
    func scratch() {
        let demo = DemoMode(key: "demoMode", defaults: defaults().0, arguments: [])
        #expect(demo.scratchDirectory.path().hasPrefix(FileManager.default.temporaryDirectory.path()))
        #expect(demo.scratchDirectory == demo.scratchDirectory)
        try? FileManager.default.removeItem(at: demo.scratchDirectory)
    }

    @Test("Window titles get “— Demo” while it's on, once, and lose it when it's off")
    func titles() {
        #expect(DemoMode.windowTitle("AppSettings2Blueprint", isOn: true) == "AppSettings2Blueprint — Demo")
        #expect(DemoMode.windowTitle("AppSettings2Blueprint — Demo", isOn: true) == "AppSettings2Blueprint — Demo")
        #expect(DemoMode.windowTitle("AppSettings2Blueprint — Demo", isOn: false) == "AppSettings2Blueprint")
        #expect(DemoMode.windowTitle("Connections", isOn: false) == "Connections")
        #expect(DemoMode.windowTitle("", isOn: true) == "")
    }
}

@Suite("Demo sample data is clearly fake")
struct DemoSampleDataTests {
    private static func strings(in json: LosslessJSON) -> [String] {
        switch json {
        case .string(let text): [text]
        case .array(let items): items.flatMap(strings(in:))
        case .object(let object): object.members.flatMap { [$0.key] + strings(in: $0.value) }
        default: []
        }
    }

    @Test("Every ID is in the fake range, every name is Contoso's, every identifier is invented",
          arguments: [false, true])
    func lint(jamfSchool: Bool) throws {
        let uuid = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        let blueprints = DemoSamples.platformBlueprints(jamfSchool: jamfSchool)
        for blueprint in blueprints {
            #expect(blueprint["name"]?.stringValue?.hasPrefix("Contoso") == true)
            for text in Self.strings(in: .object(blueprint)) {
                if text.wholeMatch(of: uuid) != nil { #expect(DemoSamples.isDemoID(text), "\(text)") }
                if text.contains("@") { #expect(text.hasSuffix(".contoso.example"), "\(text)") }
                // Apple's and Jamf's type identifiers are schema names; any other identifier is invented.
                if text.hasPrefix("com."), !text.hasPrefix("com.apple."), !text.hasPrefix("com.jamf.") {
                    #expect(text.hasPrefix("com.contoso.example."), "\(text)")
                }
            }
        }
        // Team IDs and serials (10–12 capitals and digits) must be invented.
        for text in blueprints.flatMap({ Self.strings(in: .object($0)) })
        where (10...12).contains(text.count) && text.allSatisfy({ $0.isUppercase || $0.isNumber }) {
            #expect(text.hasPrefix("ZZDEMO"), "\(text)")
        }
        for group in DemoSamples.platformGroups {
            #expect(DemoSamples.isDemoID(group.id))
        }
        #expect(DemoSamples.platformHost.hasSuffix(".demo.invalid"))
        #expect(DemoSamples.isDemoID(DemoSamples.platformEnvironmentID))
        #expect(Connection.demoJamfPlatform.name == "Contoso (Demo)")
    }
}
