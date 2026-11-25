import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

private typealias Pending = JamfPro.SoftwareUpdateStatus.PendingVersion

/// `2026-11-23T22:59:11` read as UTC.
private func utc(_ text: String) -> Date? {
    JamfPro.serverDate(text, timeZone: TimeZone(identifier: "UTC")!)
}

@Suite("1.9.0: a deadline written with a 12-hour clock")
struct TwelveHourDeadlineTests {
    @Test("“2026-11-23 10:59:11 PM +0000” with a narrow no-break space, a no-break space or a space")
    func moments() {
        for text in ["2026-11-23 10:59:11\u{202F}PM +0000", "2026-11-23 10:59:11\u{00A0}PM +0000", "2026-11-23 10:59:11 PM +0000",
                     "2026-11-23 10:59:11 pm +0000", "2026-11-23 10:59:11PM+0000", "2026-11-23T10:59:11 PM Z"] {
            let pending = Pending(targetLocalDateTime: text)
            #expect(pending.targetDate == utc("2026-11-23T22:59:11"), "\(text)")
            #expect(pending.targetOffset == 0, "\(text)")
            #expect(pending.targetLocal == nil, "a moment has an offset: \(text)")
        }
        // without seconds; with an offset other than UTC
        #expect(Pending(targetLocalDateTime: "2026-11-23 10:59 PM +0000").targetDate == utc("2026-11-23T22:59:00"))
        let plusOne = Pending(targetLocalDateTime: "2026-11-24 12:30:00\u{00A0}AM +0100")
        #expect(plusOne.targetDate == utc("2026-11-23T23:30:00"))
        #expect(plusOne.targetOffset == 3_600)
        #expect(Pending(targetLocalDateTime: "2026-11-24 09:15:00 AM -05:00").targetOffset == -18_000)
    }

    @Test("12 AM is midnight, 12 PM noon; a 13 o’clock PM and a bad offset don’t read")
    func noonAndMidnight() {
        #expect(Pending(targetLocalDateTime: "2026-11-24 12:00:00 AM +0000").targetDate == utc("2026-11-24T00:00:00"))
        #expect(Pending(targetLocalDateTime: "2026-11-24 12:00:00 PM +0000").targetDate == utc("2026-11-24T12:00:00"))
        #expect(Pending(targetLocalDateTime: "2026-11-24 13:05:00 PM +0000").targetDate == nil)
        #expect(Pending(targetLocalDateTime: "2026-11-24 00:05:00 AM +0000").targetDate == nil)
        #expect(Pending(targetLocalDateTime: "2026-11-24 13:05:00 PM").targetLocal == nil)
        #expect(Pending(targetLocalDateTime: "2026-11-24 10:05:00 PM +01").targetDate == nil)
    }

    @Test("Without an offset a 12-hour time is a local date-time, written with a 24-hour clock")
    func local() {
        #expect(Pending(targetLocalDateTime: "2026-11-24 12:05:00 PM").targetLocal == "2026-11-24T12:05:00")
        #expect(Pending(targetLocalDateTime: "2026-11-24 12:05:00 PM").targetDate == nil)
        #expect(Pending(targetLocalDateTime: "2026-11-24 11:59 PM").targetLocal == "2026-11-24T23:59:00")
        #expect(Pending(targetLocalDateTime: "2026-11-24 12:00:00\u{202F}AM").targetLocal == "2026-11-24T00:00:00")
    }

    @Test("A 24-hour local date-time reads as before: with a T or a space, always with seconds")
    func localTwentyFour() {
        #expect(Pending(targetLocalDateTime: "2026-11-16T23:59:00").targetLocal == "2026-11-16T23:59:00")
        #expect(Pending(targetLocalDateTime: "2026-11-16 23:59:00").targetLocal == "2026-11-16T23:59:00")
        #expect(Pending(targetLocalDateTime: "2026-11-16T23:59").targetLocal == nil)
        #expect(Pending(targetLocalDateTime: "2026-11-23 22:59:11 +0000").targetLocal == nil)
        #expect(Pending(targetLocalDateTime: "2026-11-23T22:59:11Z").targetLocal == nil)
        #expect(Pending(targetLocalDateTime: nil).targetLocal == nil)
        #expect(Pending(targetLocalDateTime: "soon").targetLocal == nil)
    }

    /// `offsetDate` as it was in 1.8.1, kept here as the reference.
    private static func before(_ text: String?) -> (date: Date, offset: Int)? {
        guard let text = text?.trimmingCharacters(in: .whitespaces),
              let match = text.firstMatch(of: /^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}(?::\d{2})?)(?:\.\d+)?\s*(Z|[+-]\d{2}:?\d{2})$/)
        else { return nil }
        let zone = String(match.output.3)
        var offset = 0
        if zone != "Z" {
            let digits = zone.dropFirst().filter(\.isNumber)
            guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else { return nil }
            offset = (hours * 3_600 + minutes * 60) * (zone.hasPrefix("-") ? -1 : 1)
        }
        let clock = match.output.2.count == 5 ? "\(match.output.2):00" : String(match.output.2)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: offset)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: "\(match.output.1)T\(clock)").map { ($0, offset) }
    }

    @Test("Every 24-hour text reads exactly as in 1.8.1, also the ones that didn’t read")
    func unchanged() {
        let texts: [String?] = [
            "2026-11-09 22:59:12 +0000", "2026-11-09T22:59:12+01:00", "2026-11-09T22:59:12Z", "2026-11-09T22:59:12.345Z",
            "2026-11-09 22:59 +0000", "2026-11-09 22:59:12\u{202F}+0000", " 2026-11-09 22:59:12 +0000 ", "2026-11-09 22:59:12 -0530",
            "2026-11-09 22:59:12+01", "2026-11-09T22:59:12", "2026-11-09\u{00A0}22:59:12 +0000", "2025-03-30 02:30:00 +0100",
            "2026-11-09 9:59:12 +0000", "", nil, "null",
        ]
        for text in texts {
            let now = Pending.offsetDate(text)
            let then = Self.before(text)
            #expect(now?.date == then?.date && now?.offset == then?.offset, "\(text ?? "nil")")
        }
    }
}

// MARK: - Request limits

/// A token that takes a moment and counts how many requests hold one at a
/// time: the client fetches the token inside a request’s turn.
private final class CountingToken: BearerTokenSource, @unchecked Sendable {
    private let state = Locked((now: 0, most: 0))
    var most: Int { state.value.most }

    func token() async throws -> String {
        state.withLock { $0.now += 1; $0.most = max($0.most, $0.now) }
        try await Task.sleep(for: .milliseconds(30))
        state.withLock { $0.now -= 1 }
        return "token"
    }

    func forgetToken() async {}
}

@Suite("1.9.0: request limits on the Platform API client")
@MainActor
struct PlatformClientLimitTests {
    private static let base = URL(string: "https://us.api.jamfcloud.com")!
    private static let environment = "6f2b3c1d-0000-4000-8000-000000000001"

    private func reads(_ count: Int, on client: JamfPlatform.Client) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0..<count {
                group.addTask { _ = try await client.statusItems(managementID: "MGMT-\(number)", kind: .computer) }
            }
            try await group.waitForAll()
        }
    }

    @Test("maxConcurrent: never more requests at a time than the app sets; by default no limit, as before")
    func concurrent() async throws {
        let server = MockServer { _ in .json(200, #"{"statusItems":[]}"#) }
        let limited = CountingToken()
        let client = try JamfPlatform.Client(baseURL: Self.base, scope: .environment(Self.environment), tokens: limited,
                                             recorder: RequestRecorder(session: server.session, log: nil), maxConcurrent: 5)
        try await reads(40, on: client)
        #expect(limited.most <= 5)
        #expect(limited.most >= 2, "the limit allows several at a time")
        #expect(server.requests.count == 40)

        let unlimited = CountingToken()
        let free = try JamfPlatform.Client(baseURL: Self.base, scope: .environment(Self.environment), tokens: unlimited,
                                           recorder: RequestRecorder(session: server.session, log: nil))
        try await reads(40, on: free)
        #expect(unlimited.most > 5, "no limit by default")
    }

    private func rateLimited(_ server: MockServer, time: VirtualTime, log: ActivityLog) throws -> JamfPlatform.Client {
        try JamfPlatform.Client(baseURL: Self.base, scope: .environment(Self.environment), tokens: FixedToken("tok"),
                                recorder: RequestRecorder(session: server.session, log: log),
                                rateLimit: RateLimit(requests: 100, per: 1, explanation: "The Platform API allows 100 requests a second"),
                                sleep: { try await time.sleep($0) }, now: { time.now })
    }

    @Test("rateLimit: never more than 100 requests started in any second")
    func perSecond() async throws {
        let time = VirtualTime()
        let sent = Locked([Date]())
        let server = MockServer { _ in
            sent.withLock { $0.append(time.now) }
            return .json(200, #"{"statusItems":[]}"#)
        }
        let client = try rateLimited(server, time: time, log: ActivityLog())
        for number in 0..<350 {
            _ = try await client.statusItems(managementID: "MGMT-\(number)", kind: .computer)
            time.advance(0.004)
        }
        let moments = sent.value
        #expect(moments.count == 350)
        for (index, start) in moments.enumerated() {
            let inWindow = moments[index...].prefix { $0.timeIntervalSince(start) < 1 }.count
            #expect(inWindow <= 100, "\(inWindow) requests in the second from request \(index + 1)")
        }
        #expect(!time.waits.isEmpty, "350 requests at 4 ms apart had to wait")
    }

    @Test("A per-second limit: a wait under a second isn’t logged; one of a second or more is")
    func shortWaits() async throws {
        let time = VirtualTime()
        let server = MockServer { _ in .json(200, #"{"statusItems":[]}"#) }
        let log = ActivityLog()
        let client = try rateLimited(server, time: time, log: log)
        for number in 0..<100 { _ = try await client.statusItems(managementID: "MGMT-\(number)", kind: .computer) }
        time.advance(0.5)
        _ = try await client.statusItems(managementID: "MGMT-short", kind: .computer)
        #expect(time.waits.count == 1 && abs(time.waits[0] - 0.6) < 0.01)
        #expect(!log.entries.contains { $0.category == "Retry" }, "a wait of 0.6 s isn’t written to the log")

        // 100 more at one instant: the next one waits 1.1 s, which is logged
        let burst = VirtualTime()
        let burstLog = ActivityLog()
        let second = try rateLimited(server, time: burst, log: burstLog)
        for number in 0..<101 { _ = try await second.statusItems(managementID: "MGMT-\(number)", kind: .computer) }
        #expect(burst.waits.count == 1 && abs(burst.waits[0] - 1.1) < 0.01)
        let note = try #require(burstLog.entries.first { $0.category == "Retry" })
        #expect(note.note == "The Platform API allows 100 requests a second: waiting 2 s.")
    }

    @Test("A per-minute limit (Apple Business, Apple School Manager) logs every wait, also one under a second, as in 1.8.1")
    func perMinuteLogsEveryWait() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let time = VirtualTime()
        let log = ActivityLog()
        let http = HTTPClient(baseURL: URL(string: "https://api.example.com")!, tokens: FixedToken("tok"),
                              recorder: RequestRecorder(session: server.session, log: log),
                              rateLimit: RateLimit(requests: 3, per: 60, explanation: "The service allows 3 a minute"),
                              rules: .appleBusiness, sleep: { try await time.sleep($0) }, random: { 0 }, now: { time.now })
        for _ in 0..<3 { _ = try await http.send(HTTPRequest(path: "a")) }
        time.advance(59.5)
        _ = try await http.send(HTTPRequest(path: "a"))
        #expect(time.waits.count == 1 && abs(time.waits[0] - 0.6) < 0.01)
        let note = try #require(log.entries.first { $0.category == "Retry" }, "a wait of 0.6 s is logged for a per-minute limit")
        #expect(note.note == "The service allows 3 a minute: waiting 1 s.")
        #expect(note.isWarning)
        // and Apple's own limit is still a per-minute one
        #expect(ABM.rateLimit.window == 60)
    }

    @Test("Cancel stops a short rate-limit wait too")
    func cancelShort() async throws {
        let server = MockServer { _ in .json(200, #"{"statusItems":[]}"#) }
        let client = try JamfPlatform.Client(baseURL: Self.base, scope: .environment(Self.environment), tokens: FixedToken("tok"),
                                             recorder: RequestRecorder(session: server.session, log: nil),
                                             rateLimit: RateLimit(requests: 1, per: 0.8, explanation: "One per 0.8 s"),
                                             // a clock that stands still and a wait that ends only when canceled
                                             sleep: { _ in try await Task.sleep(for: .seconds(60)) },
                                             now: { Date(timeIntervalSince1970: 1_800_000_000) })
        _ = try await client.statusItems(managementID: "MGMT-1", kind: .computer)
        let task = Task { try await client.statusItems(managementID: "MGMT-2", kind: .computer) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(server.requests.count == 1)
    }
}
