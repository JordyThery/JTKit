import Foundation
import Testing
@testable import JTKit

@Suite("1.12.1: inventory sections, as Jamf answers them")
@MainActor
struct InventorySectionsTests {
    private func demo() -> DemoMode {
        let defaults = UserDefaults(suiteName: "jtkit-demo-sections-\(UUID().uuidString)")!
        return DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
    }

    private func client(_ demo: DemoMode, _ connection: Connection) throws -> JamfPlatform.Client {
        let source = try #require(demo.source(for: connection))
        return try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                       recorder: RequestRecorder(session: source.session, log: nil), sleep: { _ in })
    }

    @Test("A cache in a caching Blueprint’s scope with its declaration applied reads as applied, with its serial number, model and macOS version")
    func appliedCache() async throws {
        let now = Date()
        let demo = demo()
        DemoSoftwareUpdate.install(on: demo.jamfPlatformServer, now: now)
        let result = try await ContentCacheRules.Sweep(client: try client(demo, .demoJamfPlatform)).read(now: now)
        let mac = try #require(DemoSoftwareUpdate.devices.first { $0.number == 201 })
        #expect(DemoContentCaching.configured.contains(mac.number) && DemoContentCaching.caches.contains(mac.number))
        let cache = try #require(result.caches.first { $0.id == String(mac.number) })
        #expect(cache.serialNumber == mac.serial && cache.model == mac.model && cache.osVersion == mac.osVersion)
        #expect(cache.declarations.map(\.state) == [.applied] && cache.declarationApplied == true && !cache.isUnplanned)
        #expect(cache.health.level == .ok)
        let configured = try #require(result.cachingBlueprints.first?.configured.first { $0.id == String(mac.number) })
        #expect(configured.isActivated && configured.declaration == .applied)
    }

    @Test("The demo Jamf Pro answers only the sections asked for, GENERAL when none is")
    func demoJamfPro() async throws {
        let demo = demo()
        let client = try client(demo, .demoJamfPro)
        let general: [JamfPro.Computer] = try await client.inventory(.computers, filter: "", sections: [.general], recording: .errorsOnly)
        let first = try #require(general.first)
        #expect(first.id != nil && first.general?.name != nil)
        #expect(first.hardware == nil && first.operatingSystem == nil && first.diskEncryption == nil && first.userAndLocation == nil)

        let none: [JamfPro.Computer] = try await client.inventory(.computers, filter: "", sections: [], recording: .errorsOnly)
        #expect(none.first?.general != nil && none.first?.hardware == nil)

        let phones: [JamfPro.MobileDevice] = try await client.inventory(.mobileDevices, filter: "", sections: [.hardware],
                                                                         recording: .errorsOnly)
        #expect(phones.first?.hardware?.serialNumber != nil && phones.first?.general == nil)
    }

    @Test("The demo’s software update server answers only the sections asked for")
    func demoPlatform() async throws {
        let now = Date()
        let demo = demo()
        DemoSoftwareUpdate.install(on: demo.jamfPlatformServer, now: now)
        let client = try client(demo, .demoJamfPlatform)
        let records: [JamfPro.Computer] = try await client.inventory(.computers, filter: "", sections: [.general, .contentCaching],
                                                                     recording: .errorsOnly)
        let first = try #require(records.first)
        #expect(first.general != nil && first.contentCaching != nil)
        #expect(first.hardware == nil && first.operatingSystem == nil && first.security == nil && first.diskEncryption == nil)
    }

    @Test("A lookup by serial number also asks for HARDWARE, which holds the serial number it matches on")
    func serialLookups() async throws {
        let demo = demo()
        let client = try client(demo, .demoJamfPro)
        let mac = try #require(DemoWorld.devices.first { $0.isComputer })
        let found = try await client.computer(serial: mac.serial, sections: [.general])
        #expect(found.record?.general?.name == mac.name)
        let batch = try await client.computers(serials: [mac.serial], sections: [.general])
        #expect(batch.records[mac.serial.uppercased()]?.general?.name == mac.name)
        let phone = try #require(DemoWorld.devices.first { !$0.isComputer })
        #expect(try await client.mobileDevice(serial: phone.serial, sections: [.general]).record != nil)
        #expect(JamfPro.matchingSerials([.general]) == [.general, .hardware])
        #expect(JamfPro.matchingSerials(JamfPro.computerSections) == JamfPro.computerSections)
    }
}
