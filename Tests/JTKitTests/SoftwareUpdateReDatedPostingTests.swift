import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import JTKit

/// Apple posts a build publicly on 9 Nov and re-dates its public posting to
/// 12 Nov three days later; its first posting (`AssetSets`) stays 9 Nov.
/// Jamf keeps the deadline it sent: 9 Nov plus 7 days, 16 Nov 23:59 in
/// Brussels (22:59 UTC). Made-up builds and devices.
@Suite("A release Apple re-dates after posting it")
struct ReDatedPostingTests {
    static func gdmf(publicDate: String) -> String {
        """
        {"PublicAssetSets":{"iOS":[
           {"ProductVersion":"27.2.1","Build":"24C201","PostingDate":"\(publicDate)","SupportedDevices":["iPad14,8"]},
           {"ProductVersion":"27.2","Build":"24C100","PostingDate":"2026-10-27","SupportedDevices":["iPad14,8"]}]},
         "AssetSets":{"iOS":[
           {"ProductVersion":"27.2.1","Build":"24C201","PostingDate":"2026-11-09","SupportedDevices":["iPad14,8"]},
           {"ProductVersion":"27.2","Build":"24C100","PostingDate":"2026-10-27","SupportedDevices":["iPad14,8"]}]}}
        """
    }
    static let sofa = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.2.1","Build":"24C201","ReleaseDate":"2026-11-09T00:00:00Z"}}]}
    """#
    static func catalog(publicDate: String) -> AppleReleases.Catalog {
        try! AppleReleases.Catalog(sofaIOS: Data(sofa.utf8), gdmf: Data(gdmf(publicDate: publicDate).utf8))
    }
    /// As Apple first posted it, and as its feed reads after the re-dating.
    static let posted = catalog(publicDate: "2026-11-09")
    static let reDated = catalog(publicDate: "2026-11-12")
    static let block = TargetRulesTests.block(.latest(enforceAfterDays: 7, deploymentTime: "23:59"))
    static let zone = "Europe/Brussels"
    static let jamfDeadline = "2026-11-16 22:59:00 +0000"
    static let now = "2026-11-14T10:00:00"

    static func rule(_ catalog: AppleReleases.Catalog = reDated, known: PostingBasis = PostingBasis()) -> DeviceTarget {
        TargetRules.target(os: "27.2", model: "iPad14,8", boardID: nil, osName: "iPadOS", context: .init(
            block: block, catalog: catalog, platform: .iOS, blueprintChanged: nil, updateStarted: nil,
            now: Sample.date(now), known: known))
    }

    static func pending(updated: String, deadline: String = jamfDeadline, version: String = "27.2.1",
                        reason: String = "declaration") -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "27.2"), ("softwareupdate.install-state", "downloading"),
                       ("softwareupdate.pending-version.os-version", version),
                       ("softwareupdate.pending-version.build-version", "24C201"),
                       ("softwareupdate.pending-version.target-local-date-time", deadline),
                       ("softwareupdate.install-reason.reason", reason)], time: updated)
    }

    static func sent(_ status: JamfPro.SoftwareUpdateStatus, rule: DeviceTarget = rule(), known: PostingBasis = PostingBasis(),
                     catalog: AppleReleases.Catalog = reDated) -> DeviceTarget {
        TargetRules.fromDevice(rule, status: status, os: "27.2", osName: "iPadOS", catalog: catalog, platform: .iOS,
                               serverTimeZone: Sample.utc, model: "iPad14,8",
                               postingDeadlines: { version, build in
                                   TargetRules.postingDeadlines(for: version, build: build, block: block, catalog: catalog,
                                                                platform: .iOS).map(\.deadline)
                               },
                               known: known, timeZone: zone, now: Sample.date(now))
    }

    static func reportedPosting(_ status: JamfPro.SoftwareUpdateStatus, changed: Date? = nil) -> Date? {
        TargetRules.reportedPosting(rule(), status: status, block: block, catalog: reDated, platform: .iOS,
                                    serverTimeZone: Sample.utc, blueprintChanged: changed, timeZone: zone)?.posted
    }

    static let firstPosting = Sample.date("2026-11-09T00:00:00")
    static let reDating = Sample.date("2026-11-12T00:00:00")
    static let key = PostingBasis.key(.iOS, OSVersion("27.2.1")!, build: "24C201")

    @Test("Nothing reported and nothing remembered: today’s public posting, 19 Nov")
    func todaysPosting() {
        let target = Self.rule()
        #expect(target.version == "27.2.1")
        #expect(target.deadlineLocal == "2026-11-19T23:59:00" && target.deadlineSource == .postingDate)
    }

    @Test("A remembered first public posting: the deadline stays 16 Nov after the re-dating")
    func rememberedPosting() {
        let remembered = FirstPostings.merged(FirstPostings.merged([:], with: Self.posted), with: Self.reDated)
        #expect(remembered[Self.key] == Self.firstPosting)
        let target = Self.rule(known: PostingBasis(remembered: remembered))
        #expect(target.deadlineLocal == "2026-11-16T23:59:00" && target.deadlineSource == .postingDate)
        // first seen after the re-dating: only today's posting is known
        #expect(FirstPostings.merged([:], with: Self.reDated)[Self.key] == Self.reDating)
    }

    @Test("A device’s report says which posting date Jamf counted from, before and after the re-dating")
    func reportedPostingDate() {
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-10T08:00:00")) == Self.firstPosting)
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-13T08:00:00")) == Self.firstPosting)
        // a deadline counted from the re-dated posting says so too
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-13T08:00:00", deadline: "2026-11-19 22:59:00 +0000")) == Self.reDating)
        // a deadline from neither posting, another version, no declaration, a report from before the Blueprint's change: nothing
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-13T08:00:00", deadline: "2026-11-14 22:59:00 +0000")) == nil)
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-13T08:00:00", version: "27.2")) == nil)
        // whatever the install reason: only a declaration sets the rule's deadline (0.3.2)
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-13T08:00:00", reason: "notification")) == Self.firstPosting)
        #expect(Self.reportedPosting(Self.pending(updated: "2026-11-10T08:00:00"), changed: Sample.date("2026-11-11T09:00:00")) == nil)
    }

    @Test("The posting date most devices report counts; the earlier one when as many report each")
    func mostReported() {
        let version = OSVersion("27.2.1")!
        let key = PostingBasis.key(.iOS, version)
        let reports = [(AppleReleases.Platform.iOS, version, Self.firstPosting), (.iOS, version, Self.firstPosting), (.iOS, version, Self.reDating)]
        #expect(TargetRules.reportedPostings(reports.map { ($0.0, $0.1, $0.2) })[key] == Self.firstPosting)
        #expect(TargetRules.reportedPostings([(.iOS, version, Self.reDating), (.iOS, version, Self.firstPosting)])[key] == Self.firstPosting)
    }

    @Test("What the Blueprint’s devices report wins over a remembered date")
    func reportsWin() {
        var known = PostingBasis(remembered: [Self.key: Self.reDating])
        #expect(Self.rule(known: known).deadlineLocal == "2026-11-19T23:59:00")
        known.reported = [PostingBasis.key(.iOS, OSVersion("27.2.1")!): Self.firstPosting]
        #expect(Self.rule(known: known).deadlineLocal == "2026-11-16T23:59:00")
    }

    @Test("The deadline’s source: the other devices’ reports have their own; a remembered or today’s posting is Apple’s")
    func deadlineSources() {
        let fromDevices = Self.rule(known: PostingBasis(reported: [PostingBasis.key(.iOS, OSVersion("27.2.1")!): Self.firstPosting]))
        #expect(fromDevices.deadlineLocal == "2026-11-16T23:59:00" && fromDevices.deadlineSource == .otherDevices)
        #expect(fromDevices.deadlineSource?.text == "As the Blueprint’s other devices report it")
        let remembered = Self.rule(known: PostingBasis(remembered: [Self.key: Self.firstPosting]))
        #expect(remembered.deadlineLocal == "2026-11-16T23:59:00" && remembered.deadlineSource == .postingDate)
        #expect(remembered.deadlineSource?.text == "From Apple’s posting date")
        let today = Self.rule()
        #expect(today.deadlineLocal == "2026-11-19T23:59:00" && today.deadlineSource == .postingDate)
        // a device whose report predates the update gets the Blueprint's deadline, and says where it comes from
        let known = PostingBasis(reported: [PostingBasis.key(.iOS, OSVersion("27.2.1")!): Self.firstPosting])
        let stale = Self.sent(Self.pending(updated: "2026-11-08T08:00:00", deadline: "2026-11-14 22:59:00 +0000"),
                              rule: Self.rule(known: known), known: known)
        #expect(stale.deadlineLocal == "2026-11-16T23:59:00" && stale.deadlineSource == .otherDevices)
    }

    @Test("A deadline reported before the re-dating, from the first posting, stays reported by the device")
    func reportBeforeReDating() {
        let target = Self.sent(Self.pending(updated: "2026-11-10T08:00:00"))
        #expect(target.fromDevice && target.version == "27.2.1")
        #expect(target.deadlineSource == .reported && target.deadlineDate == Sample.date("2026-11-16T22:59:00"))
        #expect(target.staleReason == nil && target.staleReportedDeadline == nil && target.carriedStepVersion == nil)
        // the same with the remembered date or the devices' reports
        let known = PostingBasis(reported: [PostingBasis.key(.iOS, OSVersion("27.2.1")!): Self.firstPosting])
        let withKnown = Self.sent(Self.pending(updated: "2026-11-10T08:00:00"), rule: Self.rule(known: known), known: known)
        #expect(withKnown.deadlineSource == .reported && withKnown.staleReason == nil)
    }

    @Test("A deadline reported after the re-dating stays reported by the device")
    func reportAfterReDating() {
        let target = Self.sent(Self.pending(updated: "2026-11-13T08:00:00"))
        #expect(target.deadlineSource == .reported && target.deadlineDate == Sample.date("2026-11-16T22:59:00"))
        #expect(target.staleReason == nil)
    }

    @Test("A report before the re-dating whose deadline fits no posting is still out of date")
    func unmatchedReportBeforeReDating() {
        let target = Self.sent(Self.pending(updated: "2026-11-10T08:00:00", deadline: "2026-11-14 22:59:00 +0000"))
        #expect(target.staleReason == .posted && target.staleSince == Self.reDating)
        #expect(target.deadlineLocal == "2026-11-19T23:59:00" && target.deadlineSource == .postingDate)
        // remembered: the first posting is what it predates, and the report is newer
        let known = PostingBasis(remembered: [Self.key: Self.firstPosting])
        let remembered = Self.sent(Self.pending(updated: "2026-11-10T08:00:00", deadline: "2026-11-14 22:59:00 +0000"),
                                   rule: Self.rule(known: known), known: known)
        #expect(remembered.staleReason == nil && remembered.deadlineSource == .reported)
    }

    @Test("Still counted from a public posting later than the release-day posting (26 Oct, 5 Nov)")
    func laterPublicPostingStillCounts() {
        let catalog = PostingDeadlineTests.catalog
        let remembered = FirstPostings.merged([:], with: catalog)
        let target = TargetRules.target(os: "27.0.1", model: "MacBookPro18,3", boardID: "J314sAP", osName: "macOS", context: .init(
            block: TargetRulesTests.block(PostingDeadlineTests.minor), catalog: catalog, platform: .macOS, blueprintChanged: nil,
            updateStarted: nil, now: Sample.date("2026-11-09T12:00:00"), known: PostingBasis(remembered: remembered)))
        #expect(target.deadlineLocal == "2026-11-19T23:59:00" && target.deadlineSource == .postingDate)
        // a Mac reporting Jamf's 19 Nov says Jamf counted from the public posting of 5 Nov, not 26 Oct
        let status = PostingDeadlineTests.pending(updated: "2026-11-07T08:00:00", deadline: "2026-11-19 22:59:06 +0000")
        let posted = TargetRules.reportedPosting(target, status: status, block: TargetRulesTests.block(PostingDeadlineTests.minor),
                                                 catalog: catalog, platform: .macOS, serverTimeZone: Sample.utc)?.posted
        #expect(posted == Sample.date("2026-11-05T00:00:00"))
    }
}
