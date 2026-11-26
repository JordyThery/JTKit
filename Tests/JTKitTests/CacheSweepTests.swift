import Foundation
import JTKitTestSupport
import Testing
@testable import JTKit

/// Counts the requests in flight through the token each one asks for.
private final class InFlightToken: BearerTokenSource, @unchecked Sendable {
    private let state = Locked((now: 0, most: 0))
    var most: Int { state.value.most }

    func token() async throws -> String {
        state.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
        try await Task.sleep(for: .milliseconds(15))
        state.withLock { $0.now -= 1 }
        return "token"
    }

    func forgetToken() async {}
}

/// A tenant of `count` Macs; those in `caches` have an activated cache (the
/// test Mac’s section). Status reports: `reports` by computer ID (an HTTP
/// status or the test Mac’s items); no Blueprints.
private struct SweepServer {
    var count: Int
    var caches: Set<Int>
    var reports: [Int: Int] = [:]
    var inventoryFailsOnPage: Int?

    func make() throws -> MockServer {
        let section = try JSONSerialization.jsonObject(with: try CacheFixture.data("inventory-page.json")) as? [String: Any]
        let record = (section?["results"] as? [[String: Any]])?.first ?? [:]
        let cachingData = try JSONSerialization.data(withJSONObject: record["contentCaching"] as? [String: Any] ?? [:])
        let statusItems = try CacheFixture.text("status-items.json")
        return MockServer { request in
            if request.path.contains("computers-inventory") {
                let caching = (try? JSONSerialization.jsonObject(with: cachingData)) as? [String: Any] ?? [:]
                let page = Int(request.queryValue("page") ?? "0") ?? 0
                if page == inventoryFailsOnPage { return .json(400, #"{"httpStatus":400,"errors":[]}"#) }
                let size = Int(request.queryValue("page-size") ?? "100") ?? 100
                let results = (page * size..<min(count, (page + 1) * size)).map { number -> [String: Any] in
                    var off = caching
                    off["activated"] = false
                    off["active"] = false
                    return ["id": String(number + 1), "general": ["name": "Mac \(number + 1)", "managementId": "M-\(number + 1)",
                                                                  "reportDate": "2026-11-25T09:08:04.386Z"],
                            "contentCaching": caches.contains(number + 1) ? caching : off]
                }
                let body = try JSONSerialization.data(withJSONObject: ["totalCount": count, "results": results])
                return MockResponse(status: 200, body: body)
            }
            if request.path.contains("status-items") {
                let id = request.path.split(separator: "/").reversed().dropFirst().first.map { String($0.dropFirst(2)) } ?? ""
                switch reports[Int(id) ?? 0] {
                case let status? where status != 200: return .json(status, #"{"httpStatus":\#(status),"errors":[]}"#)
                case 200?: return .json(200, statusItems)
                default: return .json(404, #"{"httpStatus":404,"errors":[]}"#)
                }
            }
            if request.path.contains("blueprints/v1/blueprints") { return .json(200, #"{"totalCount":0,"results":[]}"#) }
            return .json(404, #"{"httpStatus":404,"errors":[]}"#)
        }
    }
}

@Suite("1.11.0: the cache sweep")
struct CacheSweepTests {
    private func sweep(_ server: MockServer, tokens: any BearerTokenSource = FixedToken("tok")) throws -> ContentCacheRules.Sweep {
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://us.api.jamfcloud.com")!,
                                             scope: .environment("6f2b3c1d-0000-4000-8000-000000000001"), tokens: tokens,
                                             recorder: RequestRecorder(session: server.session, log: nil), sleep: { _ in })
        return ContentCacheRules.Sweep(client: client)
    }

    static let now = CacheFixture.date("2026-11-25T10:00:00Z")

    @Test("Every Mac, by ID, with GENERAL and CONTENT_CACHING; only the activated caches are kept; GET only")
    func inventory() async throws {
        let server = try SweepServer(count: 250, caches: [5, 150], reports: [5: 200]).make()
        let result = try await sweep(server).read(now: Self.now)
        #expect(result.computersRead == 250 && result.inventoryPages == 3)
        #expect(result.caches.map(\.id) == ["150", "5"].sorted { "Mac \($0)".localizedStandardCompare("Mac \($1)") == .orderedAscending })
        let pages = server.requests.filter { $0.path.contains("computers-inventory") }
        #expect(pages.count == 3)
        for page in pages {
            let items = URLComponents(url: page.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.filter { $0.name == "section" }.map(\.value) == ["GENERAL", "CONTENT_CACHING"])
            #expect(page.queryValue("sort") == "id:asc" && page.queryValue("page-size") == "100")
        }
        #expect(server.requests.allSatisfy { $0.method == "GET" })
        // the cache with a report: its status items; the one without (404): none, and no problem
        let five = try #require(result.caches.first { $0.id == "5" })
        #expect(five.status?.info?.cacheUsed == 31_862_207 && five.statusProblem == nil)
        #expect(five.health == ContentCacheRules.CacheHealth() && five.isUnplanned && five.declarations.isEmpty)
        #expect(five.savings.served == 162_133 && five.managementID == "M-5" && five.name == "Mac 5")
        let other = try #require(result.caches.first { $0.id == "150" })
        #expect(other.status == nil && other.statusProblem == nil)
        #expect(result.problems.isEmpty && result.cachingBlueprints.isEmpty && result.unplanned.count == 2)
        #expect(result.snapshots.map(\.cacheID).sorted() == ["150", "5"] && result.snapshots.allSatisfy { $0.date == Self.now })
        #expect(result.healthBySite == [nil: .ok])
    }

    @Test("After the first page, the pages its count announces are read at once, within the budget")
    func budget() async throws {
        let server = try SweepServer(count: 1_000, caches: []).make()
        let tokens = InFlightToken()
        var sweep = try sweep(server, tokens: tokens)
        sweep.pageReads = 3
        let result = try await sweep.read(now: Self.now)
        #expect(result.inventoryPages == 10 && result.caches.isEmpty)
        #expect(tokens.most == 3)
    }

    @Test("A status report that can’t be read is a problem of that cache; a refusal stops the sweep")
    func statusProblems() async throws {
        let failing = try SweepServer(count: 10, caches: [2, 3], reports: [2: 400, 3: 200]).make()
        let result = try await sweep(failing).read(now: Self.now)
        #expect(result.caches.first { $0.id == "2" }?.statusProblem != nil)
        #expect(result.caches.first { $0.id == "3" }?.statusProblem == nil)
        #expect(result.problems == ["1 cache’s status report couldn’t be read."])

        let refused = try SweepServer(count: 10, caches: [2], reports: [2: 403]).make()
        await #expect(throws: JamfPlatform.APIError.self) { _ = try await sweep(refused).read(now: Self.now) }
    }

    @Test("A failed inventory page stops the sweep: never a partial list of caches")
    func failedPage() async throws {
        let server = try SweepServer(count: 250, caches: [5], inventoryFailsOnPage: 2).make()
        await #expect(throws: JamfPlatform.APIError.self) { _ = try await sweep(server).read(now: Self.now) }
    }

    @Test("Blueprints known to have no caching declaration and unchanged aren’t read again")
    func skipping() async throws {
        let list = #"{"totalCount":3,"results":[{"id":"b1","name":"Caches","updated":"2026-11-25T09:06:06.197111Z"},{"id":"b2","name":"Wi-Fi","updated":"2026-11-01T00:00:00Z"},{"id":"b3","name":"Old"}]}"#
        let cachingBlueprint = try CacheFixture.text("blueprint.json").replacingOccurrences(of: CacheFixture.blueprintID, with: "b1")
        let server = MockServer { request in
            let path = request.path
            if path.hasSuffix("/blueprints/v1/blueprints") { return .json(200, list) }
            if path.hasSuffix("/b1") { return .json(200, cachingBlueprint) }
            if path.hasSuffix("/b2") { return .json(200, #"{"id":"b2","name":"Wi-Fi","updated":"2026-11-01T00:00:00Z","steps":[]}"#) }
            if path.hasSuffix("/b3") { return .json(200, #"{"id":"b3","name":"Old","steps":[]}"#) }
            return .json(404, "{}")
        }
        let blueprints = JamfPlatform.Blueprints(client: try CacheFixture.client(server))
        let first = try await blueprints.cachingBlueprints()
        #expect(first.blueprints.map(\.blueprint.id) == ["b1"] && first.detailsRead == 3)
        #expect(first.notCaching == ["b2": "2026-11-01T00:00:00Z"], "one without an updated time can’t be skipped")
        let second = try await blueprints.cachingBlueprints(skipping: first.notCaching)
        #expect(second.detailsRead == 2 && second.blueprints.count == 1 && second.notCaching == first.notCaching)
        // a changed Blueprint is read again
        let changed = try await blueprints.cachingBlueprints(skipping: ["b2": "2026-10-01T00:00:00Z"])
        #expect(changed.detailsRead == 3)
    }
}
