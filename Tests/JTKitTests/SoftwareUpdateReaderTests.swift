import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

/// The reading half of a refresh (`SoftwareUpdateRules.Reader`), on the
/// demo devices mid-update and on a mock server. What it measures is
/// covered by the rule tests moved from Software Update Dashboard; these
/// check the reading itself.
@Suite("1.9.0: the software update reader")
@MainActor
struct SoftwareUpdateReaderTests {
    private struct Demo {
        let mode: DemoMode
        let source: DemoSource

        func client(log: ActivityLog? = nil) throws -> JamfPlatform.Client {
            try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                    recorder: RequestRecorder(session: source.session, log: log), sleep: { _ in })
        }

        func catalog() async throws -> AppleReleases.Catalog {
            try await AppleReleases.Client(recorder: RequestRecorder(session: source.session, log: nil), userAgent: "JTKit tests",
                                           sofaURL: DemoAppleReleaseServer.sofaURL, gdmfURL: DemoAppleReleaseServer.gdmfURL).catalog()
        }
    }

    private func demo() throws -> Demo {
        let defaults = UserDefaults(suiteName: "jtkit-demo-reader-\(UUID().uuidString)")!
        let mode = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
        DemoSoftwareUpdate.install(on: mode.jamfPlatformServer)
        return Demo(mode: mode, source: try #require(mode.source(for: .demoJamfPlatform)))
    }

    private func device(_ reading: SoftwareUpdateRules.Reader.Reading, _ name: String) throws -> SoftwareUpdateRules.DeviceStatus {
        try #require(reading.devices.first { $0.name == name })
    }

    @Test("Both demo Blueprints: every device once, measured against its own target, with Blueprint health")
    func demoBlueprints() async throws {
        let demo = try demo()
        let reader = SoftwareUpdateRules.Reader(client: try demo.client(), catalog: try await demo.catalog(), serverTimeZone: .gmt)
        let iPads = try await reader.read(blueprintID: DemoSoftwareUpdate.iPadBlueprintID)
        #expect(iPads.scope.map(\.name) == ["Field iPads"])
        // the first refresh in a launch: the pilot iPad is in scope too
        #expect(Set(iPads.devices.map(\.name)) == Set(DemoSoftwareUpdate.iPads.map(\.name) + ["Pilot iPad 01"]))
        #expect(iPads.devices.count == iPads.members.count && iPads.inputs.count == iPads.members.count)
        #expect(try device(iPads, "Field iPad 01").category == .onTarget)
        #expect(try device(iPads, "Field iPad 03").category == .inProgress)
        #expect(try device(iPads, "Field iPad 07").category == .noReport)
        #expect(try device(iPads, "Field iPad 08").category == .offline)
        #expect(iPads.health != nil)
        #expect(iPads.devices.allSatisfy { $0.declarationsChecked == true })

        let macs = try await reader.read(blueprintID: DemoSoftwareUpdate.macBlueprintID)
        #expect(Set(macs.devices.map(\.name)).isSuperset(of: ["Studio Mac 01", "Studio Mac 08"]))
        #expect(try device(macs, "Studio Mac 01").category == .onTarget)
        #expect(try device(macs, "Studio Mac 08").category == .targetUnknown, "a beta of a major Apple hasn’t released")
        #expect(try device(macs, "Studio Mac 02").category == .inProgress)
        #expect(macs.ruleText(blocks: macs.blocks) == "Minor updates, 7 days after their release")
    }

    @Test("The Jamf Pro reads go to the Jamf Pro client, the Platform API reads to the Platform client")
    func twoClients() async throws {
        let demo = try demo()
        let proLog = ActivityLog(), platformLog = ActivityLog()
        let reader = SoftwareUpdateRules.Reader(jamfPro: try demo.client(log: proLog), platform: try demo.client(log: platformLog),
                                                catalog: try await demo.catalog(), serverTimeZone: .gmt)
        let reading = try await reader.read(blueprintID: DemoSoftwareUpdate.macBlueprintID)
        #expect(!reading.devices.isEmpty)
        func paths(_ log: ActivityLog) -> [String] {
            log.entries.filter { $0.operation.hasPrefix("GET") }.compactMap { $0.request?.url }
        }
        let pro = paths(proLog), platform = paths(platformLog)
        #expect(!pro.isEmpty && !platform.isEmpty)
        #expect(pro.allSatisfy { $0.contains("groups") || $0.contains("computers-inventory") || $0.contains("/status-items") })
        #expect(pro.contains { $0.contains("/status-items") })
        #expect(platform.contains { $0.contains("blueprints") })
        #expect(platform.contains { $0.contains("devices/v1/devices") })
        #expect(platform.contains { $0.contains("ddm/report") })
        #expect(!platform.contains { $0.contains("/status-items") || $0.contains("computers-inventory") })
        // read only: nothing but GETs, besides the sign-in
        let others = (proLog.entries + platformLog.entries).filter { $0.request != nil && !$0.operation.hasPrefix("GET") }
        #expect(others.allSatisfy { ($0.request?.url ?? "").contains("token") }, "\(others.map(\.operation))")
    }

    @Test("Status reports four at a time by default, in the members’ order; a client’s own limit holds below that")
    func width() async throws {
        let server = MockServer { request in
            .json(200, #"{"statusItems":[{"key":"device.operating-system.version","value":"27.1","lastUpdateTime":"2026-11-20T08:00:00"}]}"#)
        }
        let members = (1...30).map { JamfPro.GroupMember(id: "\($0)", kind: .computer, name: "Mac \($0)", managementID: "MGMT-\($0)") }
        func client(_ token: ReaderCountingToken, maxConcurrent: Int? = nil) throws -> JamfPlatform.Client {
            try JamfPlatform.Client(baseURL: URL(string: "https://us.api.jamfcloud.com")!,
                                    scope: .environment("6f2b3c1d-0000-4000-8000-000000000001"), tokens: token,
                                    recorder: RequestRecorder(session: server.session, log: nil), maxConcurrent: maxConcurrent)
        }
        let standard = ReaderCountingToken()
        let reader = SoftwareUpdateRules.Reader(client: try client(standard), catalog: AppleReleases.Catalog(), serverTimeZone: .gmt)
        #expect(reader.parallel == 4)
        let inputs = try await reader.statuses(members) { _, _ in }
        #expect(inputs.map(\.member.id) == members.map(\.id))
        #expect(inputs.allSatisfy { $0.status?.osVersion == "27.1" })
        #expect(standard.most <= 4 && standard.most >= 2)

        let limited = ReaderCountingToken()
        var wide = SoftwareUpdateRules.Reader(client: try client(limited, maxConcurrent: 2), catalog: AppleReleases.Catalog(),
                                              serverTimeZone: .gmt)
        wide.parallel = 25
        _ = try await wide.statuses(members) { _, _ in }
        #expect(limited.most <= 2)
    }

    @Test("Without Apple’s release data nothing is read")
    func noCatalog() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://us.api.jamfcloud.com")!,
                                             scope: .environment("6f2b3c1d-0000-4000-8000-000000000001"), tokens: FixedToken("tok"),
                                             recorder: RequestRecorder(session: server.session, log: nil))
        await #expect(throws: SoftwareUpdateRules.AppleDataUnavailable.self) {
            _ = try await SoftwareUpdateRules.Reader(client: client, catalog: nil, serverTimeZone: .gmt).read(blueprintID: "b")
        }
        #expect(server.requests.isEmpty)
    }

    @Test("A stop while reading is thrown as a stop")
    func stopped() async throws {
        let demo = try demo()
        let reader = SoftwareUpdateRules.Reader(client: try demo.client(), catalog: try await demo.catalog(), serverTimeZone: .gmt)
        let task = Task { try await reader.read(blueprintID: DemoSoftwareUpdate.macBlueprintID) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

@Suite("1.9.0: Inspect’s wording")
struct SoftwareUpdateInspectWordingTests {
    @Test("A device whose reads failed: “Couldn’t be inspected”, with the reason, as the likely cause")
    func notInspected() {
        let member = JamfPro.GroupMember(id: "7", kind: .computer, name: "Mac 7", serialNumber: "ZZTEST7")
        let result = SoftwareUpdateRules.InspectFindings.evaluate(
            SoftwareUpdateRules.InspectInput(member: member, problem: "Stopped"),
            context: SoftwareUpdateRules.InspectContext(blueprintID: "b", now: Date(), serverTimeZone: .gmt))
        #expect(result.findings.first == SoftwareUpdateRules.Finding(cause: "Couldn’t be inspected", detail: "Stopped"))
        #expect(result.cause == "Couldn’t be inspected")
    }
}

extension SoftwareUpdateRules.Reader.Reading {
    /// The Blueprint’s rule as the app words it.
    func ruleText(blocks: [JamfPlatform.SoftwareUpdateBlock]) -> String { SoftwareUpdateRules.Reader.rule(blocks) }
}

/// A token that takes a moment and counts how many requests hold one at a time.
private final class ReaderCountingToken: BearerTokenSource, @unchecked Sendable {
    private let state = Locked((now: 0, most: 0))
    var most: Int { state.value.most }

    func token() async throws -> String {
        state.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
        try await Task.sleep(for: .milliseconds(20))
        state.withLock { $0.now -= 1 }
        return "token"
    }

    func forgetToken() async {}
}
