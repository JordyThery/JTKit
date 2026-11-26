import Foundation
import Testing
@testable import JTKit

@Suite("1.11.0: Demo Mode’s content caches")
@MainActor
struct DemoContentCachingTests {
    private func read(now: Date = Date()) async throws -> ContentCacheRules.Sweep.Result {
        let defaults = UserDefaults(suiteName: "jtkit-demo-cache-\(UUID().uuidString)")!
        let demo = DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
        DemoSoftwareUpdate.install(on: demo.jamfPlatformServer, now: now)
        let source = try #require(demo.source(for: .demoJamfPlatform))
        let client = try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                             recorder: RequestRecorder(session: source.session, log: nil), sleep: { _ in })
        return try await ContentCacheRules.Sweep(client: client).read(now: now)
    }

    private func name(_ number: Int) -> String? { DemoSoftwareUpdate.devices.first { $0.number == number }?.name }

    @Test("A sweep finds the four caches, each in its case, and the caching Blueprint with configured against activated")
    func sweep() async throws {
        let result = try await read()
        #expect(result.problems.isEmpty)
        #expect(result.computersRead == DemoSoftwareUpdate.macs.count + 1, "the pilot Mac is still in Jamf’s inventory")
        #expect(Set(result.caches.map(\.id)) == Set(DemoContentCaching.caches.map(String.init)))
        func cache(_ number: Int) throws -> ContentCacheRules.CacheRecord {
            try #require(result.caches.first { $0.id == String(number) })
        }

        let ok = try cache(201)
        #expect(ok.health == ContentCacheRules.CacheHealth())
        #expect(ok.status?.info?.pressurePercent == 8 && ok.status?.parents?.count == 1)
        #expect(ok.status?.peers?.count == 1, "the removed peer is left out")
        #expect(ok.status?.droppedKeys == ["content-cache.status.registration-error"])
        #expect(ok.caching.topCategory?.name == "Mac Software" && ok.siteName == "Amsterdam Studio")
        #expect(ok.declarations.map(\.state) == [.applied] && !ok.isUnplanned)

        let warning = try cache(205)
        #expect(warning.health.level == .warning)
        #expect(warning.health.reasons == ["Cache pressure 72 % in the last hour", "Recent alert: Cache Volume"])

        let fault = try cache(207)
        #expect(fault.health.level == .fault)
        #expect(fault.health.reasons.contains("Activated but not running"))
        #expect(fault.health.reasons.contains("Registration with Apple failed: NOT_ACTIVATED"))
        #expect(fault.health.reasons.contains("The caching Blueprint’s declaration isn’t applied"))
        #expect(fault.declarations.first?.state == .failed && fault.declarations.first?.reasons == ["Error.ConfigurationFailed"])

        let unplanned = try cache(209)
        #expect(unplanned.isUnplanned && unplanned.declarations.isEmpty && unplanned.health.level == .ok)
        #expect(unplanned.status?.info == nil && unplanned.status?.status?.isActive == true, "no Blueprint asks it for live figures")
        #expect(unplanned.savings.includesPersonal)
        #expect(result.unplanned.map(\.id) == ["209"])

        let blueprint = try #require(result.cachingBlueprints.first)
        #expect(result.cachingBlueprints.count == 1)
        #expect(blueprint.id == DemoContentCaching.blueprintID && blueprint.name == DemoContentCaching.blueprintName)
        #expect(blueprint.settings.first?.cacheLimit == 100 * 1_000_000_000 && blueprint.settings.first?.parents == ["192.0.2.1"])
        #expect(blueprint.scope.map(\.name) == [DemoContentCaching.groupName])
        #expect(blueprint.configured.map(\.id) == DemoContentCaching.configured.map(String.init))
        #expect(blueprint.activatedCount == 3 && blueprint.appliedCount == 2)
        let notActivated = try #require(blueprint.configured.first { $0.id == "203" })
        #expect(!notActivated.isActivated && notActivated.declaration == .notReceived)
        #expect(blueprint.identifiers.contains(DemoContentCaching.configuration))
        #expect(blueprint.identifiers.contains(DemoContentCaching.activation))

        // Rotterdam Studio has devices and no cache
        #expect(result.healthBySite == ["Amsterdam Studio": .fault])
        // the software update Blueprints aren’t caching Blueprints, and are remembered as such
        #expect(Set(result.notCaching.keys).isSuperset(of: [DemoSoftwareUpdate.iPadBlueprintID, DemoSoftwareUpdate.macBlueprintID]))
        #expect(result.notCaching[DemoContentCaching.blueprintID] == nil)
    }

    @Test("The past sweeps: ten days, the reset of Studio Mac 05, and today’s sweep follows on without another")
    func trend() async throws {
        let now = Date()
        let past = DemoContentCaching.pastSweeps(now: now)
        #expect(Set(past.map(\.date)).count == 10)
        let today = try await read(now: now).snapshots
        let deltas = ContentCacheRules.Series.deltas(past + today)
        #expect(deltas.filter(\.isReset).map(\.cacheID) == [String(DemoContentCaching.resetCache)])
        #expect(deltas.allSatisfy { $0.served >= 0 && $0.fromOrigin >= 0 })
        let week = ContentCacheRules.Series.total(deltas, since: now.addingTimeInterval(-7 * 86_400))
        #expect(week.saved > 0)
    }

    @Test("Every demo device is in a site: odd numbers in Amsterdam, even ones in Rotterdam")
    func sites() {
        #expect(DemoContentCaching.site(of: 201).name == "Amsterdam Studio")
        #expect(DemoContentCaching.site(of: 102).name == "Rotterdam Studio")
    }
}
