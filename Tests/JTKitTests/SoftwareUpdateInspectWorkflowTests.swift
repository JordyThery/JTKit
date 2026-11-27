import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

/// Inspect's reads (`SoftwareUpdateRules.InspectWorkflow`) on the demo
/// devices: with a Jamf Pro client and a Platform client, each read goes to
/// its own; with one client, everything goes to it, as in 1.9.0.
@Suite("1.9.1: Inspect with two clients")
@MainActor
struct SoftwareUpdateInspectWorkflowTests {
    private struct Demo {
        let source: DemoSource
        let catalog: AppleReleases.Catalog
        let reading: SoftwareUpdateRules.Reader.Reading

        func client(log: ActivityLog? = nil) throws -> JamfPlatform.Client {
            try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                    recorder: RequestRecorder(session: source.session, log: log), sleep: { _ in })
        }

        var context: InspectContext {
            InspectContext(blueprintID: DemoSoftwareUpdate.macBlueprintID, blueprintName: "Studio Mac Updates",
                           blueprintChanged: nil, now: Date(timeIntervalSince1970: 1_795_000_000), serverTimeZone: .gmt,
                           majors: catalog.majors(.macOS),
                           supports: { [catalog] model, board, major in catalog.supports(model: model, boardID: board, major: major, .macOS) },
                           catalog: catalog)
        }

        /// A few of the Blueprint's Macs, with a serial and a management ID, so every read runs.
        var members: [JamfPro.GroupMember] {
            Array(reading.members.filter { $0.serialNumber != nil && $0.managementID != nil }.prefix(4))
        }
    }

    private func demo() async throws -> Demo {
        let defaults = UserDefaults(suiteName: "jtkit-demo-inspect-\(UUID().uuidString)")!
        let mode = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
        DemoSoftwareUpdate.install(on: mode.jamfPlatformServer)
        let source = try #require(mode.source(for: .demoJamfPlatform))
        let catalog = try await AppleReleases.Client(recorder: RequestRecorder(session: source.session, log: nil), userAgent: "JTKit tests",
                                                     sofaURL: DemoAppleReleaseServer.sofaURL,
                                                     gdmfURL: DemoAppleReleaseServer.gdmfURL).catalog()
        let client = try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                             recorder: RequestRecorder(session: source.session, log: nil), sleep: { _ in })
        let reading = try await SoftwareUpdateRules.Reader(client: client, catalog: catalog, serverTimeZone: .gmt)
            .read(blueprintID: DemoSoftwareUpdate.macBlueprintID)
        return Demo(source: source, catalog: catalog, reading: reading)
    }

    private func paths(_ log: ActivityLog) -> [String] {
        log.entries.filter { $0.operation.hasPrefix("GET") }.compactMap { $0.request?.url }
    }

    @Test("Status reports go to the Jamf Pro client; the device and its declaration reports to the Platform client")
    func twoClients() async throws {
        let demo = try await demo()
        let members = demo.members
        #expect(members.count == 4)
        let proLog = ActivityLog(), platformLog = ActivityLog()
        let workflow = InspectWorkflow(jamfPro: try demo.client(log: proLog), platform: try demo.client(log: platformLog))
        #expect(workflow.parallel == 4)
        let results = try await workflow.run(members, rows: demo.reading.devices, context: demo.context)
        #expect(results.map(\.serial) == members.map { $0.serialNumber ?? "" })

        let pro = paths(proLog), platform = paths(platformLog)
        #expect(pro.count == members.count)
        #expect(pro.allSatisfy { $0.contains("/status-items") })
        #expect(platform.contains { $0.contains("devices/v1/devices") })
        #expect(platform.contains { $0.contains("ddm/report") })
        #expect(platform.allSatisfy { $0.contains("devices/v1/devices") || $0.contains("ddm/report") })
        // read only: nothing but GETs, besides the sign-in
        let others = (proLog.entries + platformLog.entries).filter { $0.request != nil && !$0.operation.hasPrefix("GET") }
        #expect(others.allSatisfy { ($0.request?.url ?? "").contains("token") }, "\(others.map(\.operation))")
    }

    @Test("One client: every read goes to it and the results are those of two clients, as in 1.9.0")
    func oneClient() async throws {
        let demo = try await demo()
        let members = demo.members
        let log = ActivityLog()
        let one = InspectWorkflow(client: try demo.client(log: log), parallel: 2)
        #expect(one.parallel == 2)
        let results = try await one.run(members, rows: demo.reading.devices, context: demo.context)

        let all = paths(log)
        #expect(all.filter { $0.contains("/status-items") }.count == members.count)
        #expect(all.contains { $0.contains("devices/v1/devices") })
        #expect(all.contains { $0.contains("ddm/report") })

        let split = InspectWorkflow(jamfPro: try demo.client(), platform: try demo.client(), parallel: 2)
        #expect(try await split.run(members, rows: demo.reading.devices, context: demo.context) == results)
    }

    @Test("1.13.1: one device’s reads: without a serial its status is still read; with one, its device and reports")
    func oneDevicesReads() async throws {
        let demo = try await demo()
        let member = try #require(demo.members.first)
        let workflow = InspectWorkflow(client: try demo.client())
        let full = await workflow.inspectInput(member, row: nil)
        #expect(full.status != nil && full.platformDeviceID != nil && full.reports != nil)
        #expect(full.problem == nil && full.reportsProblem == nil)

        var noSerial = member
        noSerial.serialNumber = nil
        let partial = await workflow.inspectInput(noSerial, row: nil)
        #expect(partial.status != nil)
        #expect(partial.platformDeviceID == nil && partial.reports == nil && partial.problem == nil)
    }
}
