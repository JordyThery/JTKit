import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

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

    @Test func entriesWithoutStatusCanBeMarkedFailed() {
        let unanswered = ActivityLogEntry(
            category: "Graph", operation: "GET", detail: "/a",
            failedWithoutStatus: true
        )
        #expect(unanswered.isFailure, "Marked failed without a status")
        #expect(!entry("/a").isFailure, "Unmarked entries without a status still aren't failures")

        let answered = ActivityLogEntry(
            category: "Graph", operation: "GET", detail: "/a",
            status: 200, failedWithoutStatus: true
        )
        #expect(!answered.isFailure, "A status decides on its own")
    }

    // MARK: Step 5: warnings, search, export

    private let app = ActivityLogAppInfo(name: "Profile2Blueprint", version: "1.4", build: "27", system: "macOS Version 15.1 (Build 24B83)")

    private func requestEntry() -> ActivityLogEntry {
        ActivityLogEntry(
            category: "API", operation: "GET", detail: "/api/v1/computers/serial/C02XK1JHJG5H", status: 404, duration: 0.25,
            note: "Not Found", service: "Jamf Pro", connection: "Lab",
            request: ActivityRequestDetails(
                url: "https://acme.jamfcloud.com/api/v1/computers/serial/C02XK1JHJG5H", attempt: 2, maxAttempts: 4,
                requestHeaders: [HTTPHeader(name: "Authorization", value: "Bearer <redacted>")],
                responseBody: #"{"user":"jane@corp.example","group":"Engineers"}"#),
            identifiers: [FoundIdentifier(.device, "C02XK1JHJG5H"), FoundIdentifier(.user, "jane@corp.example")]
        )
    }

    @Test func warningsAndFailuresAreProblems() {
        #expect(ActivityLogEntry(category: "Retry", operation: "GET", detail: "/a", isWarning: true).isProblem)
        #expect(entry("/a", status: 500).isProblem)
        #expect(!entry("/a", status: 200).isProblem)
        #expect(!ActivityLogEntry(category: "Retry", operation: "GET", detail: "/a", isWarning: true).isFailure)
    }

    @Test func searchMatchesEveryColumnAndTheSource() {
        let entry = requestEntry()
        #expect(ActivityLogSearch.matches(entry, "api"))           // the source
        #expect(ActivityLogSearch.matches(entry, "computers"))     // the detail
        #expect(ActivityLogSearch.matches(entry, "404"))           // the status
        #expect(ActivityLogSearch.matches(entry, "not found"))     // the note
        #expect(ActivityLogSearch.matches(entry, "Lab"))           // the connection
        #expect(ActivityLogSearch.matches(entry, "acme"))          // the address
        #expect(ActivityLogSearch.matches(entry, "  "))
        #expect(!ActivityLogSearch.matches(entry, "blueprint"))
    }

    @Test func transcriptShowsWhatWasSentAndReceived() {
        let text = ActivityLogExport.transcript(of: requestEntry())
        #expect(text.contains("API · Jamf Pro · Lab"))
        #expect(text.contains("GET /api/v1/computers/serial/C02XK1JHJG5H"))
        #expect(text.contains("Status 404 · 0.25 s · Attempt 2 of 4"))
        #expect(text.contains("URL: https://acme.jamfcloud.com/api/v1/computers/serial/C02XK1JHJG5H"))
        #expect(text.contains("── Request headers ──\nAuthorization: Bearer <redacted>"))
        #expect(text.contains("── Response body ──"))
        #expect(text.contains("C02XK1JHJG5H"), "Copying one entry stays unmasked")
    }

    @Test func exportHeaderNamesTheAppAndMacOS() {
        let text = ActivityLogExport.text([requestEntry()], masked: true, app: app)
        let lines = text.components(separatedBy: "\n")
        #expect(lines[0] == "Profile2Blueprint 1.4 (27) activity log")
        #expect(lines[1] == "macOS Version 15.1 (Build 24B83)")
        #expect(lines[2].hasPrefix("Exported "))
        #expect(lines[3] == "1 entry, newest first. Secrets are never recorded.")
    }

    @Test func bugReportMasksIdentifiersButNotNames() {
        let masked = ActivityLogExport.text([requestEntry()], masked: true, app: app)
        #expect(!masked.contains("C02XK1JHJG5H"))
        #expect(!masked.contains("jane@corp.example"))
        #expect(masked.contains("/api/v1/computers/serial/<device 1>"))
        #expect(masked.contains("<user 1>"))
        #expect(masked.contains("Engineers"))
        #expect(masked.contains("Lab"))

        let unmasked = ActivityLogExport.text([requestEntry()], masked: false, app: app)
        #expect(unmasked.contains("C02XK1JHJG5H"))
        #expect(unmasked.contains("Not masked"))
    }

    @Test func exportIsNewestFirst() {
        let first = entry("/first")
        let second = entry("/second")
        let text = ActivityLogExport.text([first, second], masked: false, app: app)
        let firstIndex = text.range(of: "/first")?.lowerBound
        let secondIndex = text.range(of: "/second")?.lowerBound
        #expect(secondIndex! < firstIndex!)
    }

    @Test func existingCallersStillWork() {
        // Jamf Deployer and Intune Deployer add entries like this
        let entry = ActivityLogEntry(category: "API", operation: "GET", detail: "/a", status: 200, duration: 0.1, note: "x")
        #expect(!entry.isWarning)
        #expect(entry.request == nil)
        #expect(entry.identifiers.isEmpty)
    }
}

@Suite("Secret prefix delete")
struct SecretPrefixTests {
    @Test func deletesOnlyMatchingAccounts() {
        let store = InMemorySecretStore(["A.block.key": "1", "A.other": "2", "B.block.key": "3"])
        #expect(store.deleteSecrets(withAccountPrefix: "A."))
        #expect(store.all == ["B.block.key": "3"])
        #expect(!store.deleteSecrets(withAccountPrefix: ""), "An empty prefix deletes nothing")
        #expect(store.all.count == 1)
    }
}
