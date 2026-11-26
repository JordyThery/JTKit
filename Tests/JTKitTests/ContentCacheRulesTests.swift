import Foundation
import Testing
@testable import JTKit

typealias CacheTestHealth = ContentCacheRules.CacheHealth

@Suite("1.11.0: savings")
struct CacheSavingsTests {
    @Test("Returned to clients, peers and children, minus fetched from Apple; never below zero")
    func savings() {
        let cache = JamfPro.ContentCaching(personalUsed: 7, returnedToClients: 100, returnedToPeers: 20, returnedToChildren: 5,
                                           storedFromOrigin: 40, storedFromParents: 9)
        let savings = ContentCacheRules.Savings.compute(cache)
        #expect(savings.served == 125 && savings.fromOrigin == 40 && savings.saved == 85)
        #expect(savings.personalUsed == 7 && savings.includesPersonal, "shown beside the savings, never added")
        #expect(ContentCacheRules.Savings(served: 10, fromOrigin: 30).saved == 0)
    }

    @Test("The test Mac: it served what it fetched, all of it personal (iCloud): saved nothing")
    func fixture() throws {
        let savings = ContentCacheRules.Savings.compute(try #require(try CacheFixture.computer().contentCaching))
        #expect(savings.served == 162_133 && savings.fromOrigin == 162_133 && savings.saved == 0)
        #expect(savings.includesPersonal && savings.since == CacheFixture.date("2026-11-25T09:06:16Z"))
    }
}

@Suite("1.11.0: cache health")
struct CacheHealthTests {
    static let report = CacheFixture.date("2026-11-25T09:00:00Z")
    static let now = CacheFixture.date("2026-11-25T10:00:00Z")

    static func healthy(_ change: (inout JamfPro.ContentCaching) -> Void = { _ in }) -> JamfPro.ContentCaching {
        var cache = JamfPro.ContentCaching(isActivated: true, isActive: true, cacheStatus: "OK", startupStatus: "OK",
                                           registration: .succeeded, cacheUsed: 10, cacheLimit: 100, pressurePercent: 10)
        change(&cache)
        return cache
    }

    static func evaluate(_ cache: JamfPro.ContentCaching, status: JamfPro.ContentCacheStatus? = nil, report: Date? = report,
                         applied: Bool? = nil) -> CacheTestHealth {
        CacheTestHealth.evaluate(cache, status: status, reportDate: report, declarationApplied: applied, now: now)
    }

    @Test("The test Mac is OK, with its status items")
    func fixture() throws {
        let computer = try CacheFixture.computer()
        let health = CacheTestHealth.evaluate(try #require(computer.contentCaching),
                                     status: JamfPro.ContentCacheStatus(items: try CacheFixture.statusItems()),
                                     reportDate: computer.general?.reportDate, now: CacheFixture.date("2026-11-25T10:00:00Z"))
        #expect(health == CacheTestHealth())
    }

    @Test("Faults: not running, a status other than OK, registration failed, every parent unhealthy, no report for over 7 days")
    func faults() {
        #expect(Self.evaluate(Self.healthy { $0.isActive = false }).level == .fault)
        #expect(Self.evaluate(Self.healthy { $0.cacheStatus = "LOW_SPACE" }).reasons == ["Cache status: LOW_SPACE"])
        #expect(Self.evaluate(Self.healthy { $0.startupStatus = "FAILED" }).level == .fault)
        let registration = Self.evaluate(Self.healthy { $0.registration = .failed; $0.registrationError = "NOT_ACTIVATED" })
        #expect(registration.level == .fault && registration.reasons == ["Registration with Apple failed: NOT_ACTIVATED"])
        let parents = Self.evaluate(Self.healthy { $0.parents = [.init(isHealthy: false), .init(isHealthy: false)] })
        #expect(parents.level == .fault && parents.reasons == ["Every parent cache is unhealthy"])
        #expect(Self.evaluate(Self.healthy(), report: Self.now.addingTimeInterval(-8 * 86_400)).reasons == ["No inventory report for 8 days"])
        // a fault lists its warnings after it
        let both = Self.evaluate(Self.healthy { $0.isActive = false; $0.pressurePercent = 80 })
        #expect(both.reasons == ["Activated but not running", "Cache pressure 80 % in the last hour"])
    }

    @Test("Warnings at their thresholds: pressure 50 %, an alert within 24 hours, no report for 48 hours")
    func thresholds() {
        #expect(Self.evaluate(Self.healthy { $0.pressurePercent = 49 }).level == .ok)
        #expect(Self.evaluate(Self.healthy { $0.pressurePercent = 50 }).reasons == ["Cache pressure 50 % in the last hour"])
        let recent = JamfPro.ContentCaching.Alert(className: "com.apple.AssetCache.CacheVolumeAlert", posted: Self.now.addingTimeInterval(-23 * 3_600))
        #expect(Self.evaluate(Self.healthy { $0.alerts = [recent] }).reasons == ["Recent alert: Cache Volume"])
        let old = JamfPro.ContentCaching.Alert(className: "com.apple.AssetCache.CacheVolumeAlert", posted: Self.now.addingTimeInterval(-25 * 3_600))
        #expect(Self.evaluate(Self.healthy { $0.alerts = [old] }).level == .ok)
        #expect(Self.evaluate(Self.healthy(), report: Self.now.addingTimeInterval(-47 * 3_600)).level == .ok)
        #expect(Self.evaluate(Self.healthy(), report: Self.now.addingTimeInterval(-49 * 3_600)).reasons == ["No inventory report for 2 days"])
        var custom = CacheTestHealth.Thresholds()
        custom.warningPressure = 80
        #expect(CacheTestHealth.evaluate(Self.healthy { $0.pressurePercent = 60 }, reportDate: Self.report, thresholds: custom, now: Self.now).level == .ok)
    }

    @Test("A full cache is OK: it fills to its limit by design and evicts")
    func fullness() {
        #expect(Self.evaluate(Self.healthy { $0.cacheUsed = 100; $0.cacheFree = 0 }) == CacheTestHealth())
        #expect(Self.evaluate(Self.healthy { $0.cacheUsed = 99 }) == CacheTestHealth())
    }

    @Test("Warnings: registration pending, a parent unhealthy, data moving or a failed move, the declaration not applied")
    func warnings() {
        #expect(Self.evaluate(Self.healthy { $0.registration = .pending }).reasons == ["Registration with Apple pending"])
        #expect(Self.evaluate(Self.healthy { $0.parents = [.init(isHealthy: true), .init(isHealthy: false)] }).reasons == ["A parent cache is unhealthy"])
        #expect(Self.evaluate(Self.healthy { $0.dataMigration = .init(completed: false, percent: 40) }).reasons == ["Moving its data (40 %)"])
        #expect(Self.evaluate(Self.healthy { $0.dataMigration = .init(completed: false, percent: 0, errorCode: 5) }).reasons == ["Moving its data failed"])
        #expect(Self.evaluate(Self.healthy { $0.dataMigration = .init(completed: false, percent: 0, errorCode: 0) }) == CacheTestHealth())
        #expect(Self.evaluate(Self.healthy(), applied: false).reasons == ["The caching Blueprint’s declaration isn’t applied"])
        #expect(Self.evaluate(Self.healthy(), applied: true) == CacheTestHealth())
        #expect(Self.evaluate(Self.healthy(), report: nil).reasons == ["No inventory report date"])
    }

    @Test("Status items newer than the inventory decide; older ones don’t")
    func statusItemsFirst() {
        func status(active: Bool, pressure: String, time: String) -> JamfPro.ContentCacheStatus? {
            JamfPro.ContentCacheStatus(items: [
                JamfPro.StatusItem(key: "content-cache.status.active", value: String(active), lastUpdateTime: time),
                JamfPro.StatusItem(key: "content-cache.info.max-cache-pressure-last-hour", value: pressure, lastUpdateTime: time),
            ])
        }
        let stopped = Self.healthy { $0.isActive = false; $0.pressurePercent = 90 }
        #expect(Self.evaluate(stopped, status: status(active: true, pressure: "0.1", time: "2026-11-25T09:30:00")) == CacheTestHealth())
        #expect(Self.evaluate(stopped, status: status(active: true, pressure: "0.1", time: "2026-11-25T08:30:00")).level == .fault)
        #expect(Self.evaluate(Self.healthy(), status: status(active: false, pressure: "0.6", time: "2026-11-25T09:30:00")).reasons
                == ["Activated but not running", "Cache pressure 60 % in the last hour"])
    }

    @Test("The worst of several; alert names")
    func worst() {
        #expect(CacheTestHealth.worst(of: [CacheTestHealth(), CacheTestHealth(level: .warning), CacheTestHealth()]) == .warning)
        #expect(CacheTestHealth.worst(of: [CacheTestHealth(level: .fault), CacheTestHealth(level: .warning)]) == .fault)
        #expect(CacheTestHealth.worst(of: []) == nil)
        #expect(CacheTestHealth.alertName("com.apple.AssetCache.LowSpaceAlert") == "Low Space")
        #expect(CacheTestHealth.Level.allCases.map(\.title) == ["OK", "Warning", "Fault"])
    }
}

@Suite("1.11.0: a series of sweeps")
struct CacheSeriesTests {
    static let day: TimeInterval = 86_400
    static let start = CacheFixture.date("2026-11-01T00:00:00Z")

    static func snapshot(_ day: Int, served: Int64, origin: Int64, since: Int = 0, guid: String = "G",
                         cache: String = "1") -> ContentCacheRules.CacheSnapshot {
        .init(date: start.addingTimeInterval(Double(day) * Self.day), cacheID: cache,
              countersSince: start.addingTimeInterval(Double(since) * Self.day), serverGuid: guid, served: served, fromOrigin: origin)
    }

    @Test("Deltas between consecutive sweeps of each cache, in date order")
    func deltas() {
        let deltas = ContentCacheRules.Series.deltas([
            Self.snapshot(2, served: 300, origin: 100), Self.snapshot(1, served: 100, origin: 50),
            Self.snapshot(1, served: 10, origin: 0, cache: "2"), Self.snapshot(2, served: 15, origin: 5, cache: "2"),
        ])
        #expect(deltas.map(\.cacheID) == ["1", "2"])
        #expect(deltas[0].served == 200 && deltas[0].fromOrigin == 50 && deltas[0].saved == 150 && !deltas[0].isReset)
        #expect(deltas[1].served == 5 && deltas[1].saved == 0)
    }

    @Test("A reset: the counters’ start moved, the cache’s GUID changed, or a counter went down")
    func resets() {
        let before = Self.snapshot(1, served: 500, origin: 100)
        let moved = Self.snapshot(2, served: 600, origin: 120, since: 2)
        let guid = Self.snapshot(2, served: 600, origin: 120, guid: "H")
        let down = Self.snapshot(2, served: 40, origin: 10)
        for next in [moved, guid, down] {
            #expect(ContentCacheRules.Series.isReset(from: before, to: next))
            let delta = ContentCacheRules.Series.deltas([before, next])[0]
            #expect(delta.isReset && delta.served == next.served && delta.fromOrigin == next.fromOrigin)
        }
        #expect(!ContentCacheRules.Series.isReset(from: before, to: Self.snapshot(2, served: 500, origin: 100)))
    }

    @Test("Totals over a period, per cache or for all")
    func totals() {
        let deltas = ContentCacheRules.Series.deltas((1...5).map { Self.snapshot($0, served: Int64($0) * 100, origin: Int64($0) * 10) }
                                                     + (1...5).map { Self.snapshot($0, served: Int64($0) * 10, origin: 0, cache: "2") })
        let since = Self.start.addingTimeInterval(3 * Self.day)
        let one = ContentCacheRules.Series.total(deltas, since: since, cacheID: "1")
        #expect(one.served == 200 && one.fromOrigin == 20 && one.saved == 180)
        #expect(ContentCacheRules.Series.total(deltas, since: since).served == 220)
    }

    @Test("A snapshot is saved and read back unchanged")
    func codable() throws {
        let snapshot = ContentCacheRules.CacheSnapshot(date: Self.start, cacheID: "7", countersSince: Self.start, serverGuid: "G",
                                                       served: 9, fromOrigin: 3, used: 5, pressurePercent: 12, health: .warning)
        let data = try JSONEncoder().encode([snapshot])
        #expect(try JSONDecoder().decode([ContentCacheRules.CacheSnapshot].self, from: data) == [snapshot])
        #expect(snapshot.savings == 6)
    }
}

@Suite("1.11.0: how a caching declaration stands")
struct CacheDeclarationCheckTests {
    typealias Report = JamfPlatform.DeclarationReport
    typealias State = ContentCacheRules.DeclarationState

    static let configuration = "Blueprint_b1_s1_c1_declaration_custom_0"
    static let activation = "Blueprint_b1_s1_c1_sys_act1"

    @Test("An activation reporting Info.Predicate: not for this device, never failed, also with Error.ActivationFailed")
    func predicate() {
        let activation = Report(declarationIdentifier: Self.activation, type: "ACTIVATION", status: .unsuccessful, active: false,
                                reasons: [.init(code: "Info.Predicate", details: [.init(key: "Predicate", description: "false")])])
        let configuration = Report(declarationIdentifier: Self.configuration, type: "CONFIGURATION", status: .unsuccessful,
                                   active: false, reasons: [.init(code: "Error.ActivationFailed")])
        #expect(State.state(configuration: configuration, activation: activation) == .notForThisDevice)
        #expect(State.state(configuration: nil, activation: activation) == .notForThisDevice)
        // without the predicate, a failed configuration is a failure
        #expect(State.state(configuration: configuration, activation: nil) == .failed)
    }

    @Test("Applied, pending, awaiting sync, invalid, not received")
    func states() {
        func config(_ status: Report.Status, active: Bool? = true, validity: Report.Validity = .valid) -> Report {
            Report(declarationIdentifier: Self.configuration, status: status, active: active, validity: validity)
        }
        #expect(State.state(configuration: config(.successful), activation: nil) == .applied)
        #expect(State.state(configuration: config(.successful, active: false), activation: nil) == .pending)
        #expect(State.state(configuration: config(.pending), activation: nil) == .pending)
        #expect(State.state(configuration: config(.awaitingSync), activation: nil) == .awaitingSync)
        #expect(State.state(configuration: config(.successful, validity: .invalid), activation: nil) == .invalid)
        #expect(State.state(configuration: nil, activation: nil) == .notReceived)
        #expect(State.State.allCases.count == 7)
    }

    @Test("A cache’s declaration counts as applied only when one that should be on it is")
    func applied() {
        func record(_ states: [State.State]) -> ContentCacheRules.CacheRecord {
            ContentCacheRules.CacheRecord(id: "1", caching: .init(), declarations: states.map {
                State(blueprintID: "b", blueprintName: "B", state: $0)
            })
        }
        #expect(record([]).declarationApplied == nil)
        #expect(record([.notForThisDevice]).declarationApplied == nil)
        #expect(record([.notForThisDevice, .failed]).declarationApplied == false)
        #expect(record([.failed, .applied]).declarationApplied == true)
    }

    @Test("A Mac holds a Blueprint’s caching configuration by its prefix; an activation isn’t enough")
    func held() {
        let blueprint = ContentCacheRules.CachingBlueprint(id: "b1", name: "B",
                                                           settings: [.init(stepIndex: 0, componentIndex: 0)])
        #expect(blueprint.isHeld(in: ["Blueprint_B1_s1_c1_declaration_custom_0"]))
        #expect(!blueprint.isHeld(in: [Self.activation, "Blueprint_b1_s1_c2_sys_cfg1", "Blueprint_b2_s1_c1_declaration_custom_0"]))
    }
}
