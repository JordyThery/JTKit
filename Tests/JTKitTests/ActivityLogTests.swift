import Foundation
import Testing
@testable import JTKit

@Suite("Activity log")
@MainActor
struct ActivityLogTests {
    private func entry(_ detail: String, status: Int? = nil) -> ActivityLogEntry {
        ActivityLogEntry(category: "API", operation: "GET", detail: detail, status: status)
    }

    @Test func appendsInOrder() {
        let log = ActivityLog()
        log.append(entry("/a"))
        log.append(entry("/b"))
        #expect(log.entries.map(\.detail) == ["/a", "/b"])
    }

    @Test func dropsTheOldestBeyondCapacity() {
        let log = ActivityLog(capacity: 3)
        for index in 1...5 {
            log.append(entry("/\(index)"))
        }
        #expect(log.entries.map(\.detail) == ["/3", "/4", "/5"])
    }

    @Test func defaultCapacityIsOneThousand() {
        let log = ActivityLog()
        for index in 1...1001 {
            log.append(entry("/\(index)"))
        }
        #expect(log.entries.count == 1000)
        #expect(log.entries.first?.detail == "/2")
    }

    @Test func clearEmptiesTheLog() {
        let log = ActivityLog()
        log.append(entry("/a"))
        log.clear()
        #expect(log.entries.isEmpty)
    }

    @Test func failuresAreHTTPStatus400AndUp() {
        #expect(!entry("/a").isFailure, "No status is not a failure")
        #expect(!entry("/a", status: 200).isFailure)
        #expect(!entry("/a", status: 399).isFailure)
        #expect(entry("/a", status: 400).isFailure)
        #expect(entry("/a", status: 503).isFailure)
    }
}
