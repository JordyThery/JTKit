import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import JTKit

/// 0.3.2: Jamf’s deadline remembered per tracked Blueprint, reports counted
/// whatever their install reason, a Mac’s next install attempt after the
/// deadline, a 12-hour time, and a Mac’s earlier step by a deadline the
/// Blueprint’s devices reported. Made-up builds, devices and IDs, shaped like
/// what the live tenant showed on 24 and 25 Nov.
@Suite("0.3.2: Jamf’s deadline, remembered and read")
struct DeadlineMemoryTests {
    // Apple posted 26.7.3 on 9 Nov and re-dated its public posting to 16 Nov;
    // Jamf counted from 9 Nov: minor updates, 14 days, 23:59, so 23 Nov 22:59 UTC
    static let gdmf = #"""
    {"PublicAssetSets":{"macOS":[
       {"ProductVersion":"26.7.3","Build":"25G342","PostingDate":"2026-11-16","SupportedDevices":["J314sAP"]}]},
     "AssetSets":{"macOS":[
       {"ProductVersion":"26.7.3","Build":"25G342","PostingDate":"2026-11-09","SupportedDevices":["J314sAP"]},
       {"ProductVersion":"26.7.2","Build":"25G332","PostingDate":"2026-10-26","SupportedDevices":["J314sAP"]}]}}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(EarlierStepAndInstallTests.sofa.utf8), gdmf: Data(gdmf.utf8))
    static let block = TargetRulesTests.block(.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59"))
    static let key = PostingBasis.key(.macOS, OSVersion("26.7.3")!)
    static let firstPosting = Sample.date("2026-11-09T00:00:00")
    static let jamfDeadline = "2026-11-23 22:59:11 +0000"

    static func status(pending: String? = "26.7.3", deadline: String? = jamfDeadline, reason: String = "declaration",
                       state: String = "prepared", os: String = "26.7.2", updated: String = "2026-11-10T08:00:00",
                       extra: [(String, String)] = []) -> JamfPro.SoftwareUpdateStatus {
        var pairs = [("device.operating-system.version", os), ("softwareupdate.device-id", "J314sAP"),
                     ("softwareupdate.install-state", state), ("softwareupdate.install-reason.reason", reason)]
        if let pending { pairs.append(("softwareupdate.pending-version.os-version", pending)) }
        if let deadline { pairs.append(("softwareupdate.pending-version.target-local-date-time", deadline)) }
        return Sample.status(pairs + extra, time: updated)
    }

    static func rule(known: PostingBasis = PostingBasis(), now: String = "2026-11-24T06:33:00", block: JamfPlatform.SoftwareUpdateBlock = block,
                     os: String = "26.7.2") -> DeviceTarget {
        TargetRules.target(os: os, model: "MacBookPro18,3", boardID: "J314sAP", osName: "macOS", context: .init(
            block: block, catalog: catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil, now: Sample.date(now), known: known))
    }

    static func target(_ status: JamfPro.SoftwareUpdateStatus, known: PostingBasis = PostingBasis(reported: [key: firstPosting]),
                       now: String = "2026-11-24T06:33:00", block: JamfPlatform.SoftwareUpdateBlock = block,
                       os: String = "26.7.2") -> DeviceTarget {
        TargetRules.fromDevice(rule(known: known, now: now, block: block, os: os), status: status, os: os, osName: "macOS",
                               catalog: catalog, platform: .macOS, serverTimeZone: Sample.utc,
                               model: "MacBookPro18,3", boardID: "J314sAP",
                               earlierStepDeadline: { TargetRules.ruleDeadline(for: $0, block: block, catalog: catalog, platform: .macOS,
                                                                               model: "MacBookPro18,3", boardID: "J314sAP", known: known) },
                               postingDeadlines: { version, build in
                                   TargetRules.postingDeadlines(for: version, build: build, block: block, catalog: catalog,
                                                                platform: .macOS).map(\.deadline)
                               },
                               known: known, now: Sample.date(now))
    }

    static let blueprint = try! JamfPlatform.BlueprintDetail(data: Data(#"{"id":"6a2f0000-1111-4000-8000-00000000c0de","name":"Test"}"#.utf8))

    // MARK: Remembered per tracked Blueprint

    @Test("A remembered posting goes when the version is no longer the rule’s target, or the Blueprint changed since; deadlines stay 180 days")
    func forgetting() {
        let seen = Sample.date("2026-11-20T08:00:00")
        let minute = PostingBasis.minute(Sample.date("2026-11-23T22:59:00"))
        let memory = ReportedDeadlines(postings: [Self.key: .init(posted: Self.firstPosting, seen: seen)],
                                      moments: [Self.key: [.init(minute: minute, seen: seen)]])
        #expect(memory.basis(targets: [Self.key], blueprintChanged: nil).postings == [Self.key: Self.firstPosting])
        // another version is the target now: the posting goes, the deadline stays (a Mac's earlier step)
        let movedOn = memory.updated(reported: [:], moments: [:], targets: ["macOS|26.7.4"], blueprintChanged: nil, now: Sample.date("2026-12-10T08:00:00"))
        #expect(movedOn.postings.isEmpty && movedOn.moments[Self.key]?.map(\.minute) == [minute])
        #expect(memory.basis(targets: ["macOS|26.7.4"], blueprintChanged: nil).postings.isEmpty)
        // the Blueprint changed after it was last reported: not counted, not kept
        let changed = Sample.date("2026-11-21T09:00:00")
        #expect(memory.basis(targets: [Self.key], blueprintChanged: changed).postings.isEmpty)
        #expect(memory.updated(reported: [:], moments: [:], targets: [Self.key], blueprintChanged: changed, now: changed).postings.isEmpty)
        // reported again: replaced, with the new date it was seen
        let reported = memory.updated(reported: [Self.key: Self.firstPosting], moments: [Self.key: [minute]], targets: [Self.key],
                                     blueprintChanged: nil, now: changed)
        #expect(reported.postings[Self.key]?.seen == changed && reported.moments[Self.key]?.count == 1)
        // deadlines first seen more than 180 days ago go
        let old = memory.updated(reported: [:], moments: [:], targets: [], blueprintChanged: nil, now: seen.addingTimeInterval(181 * 86_400))
        #expect(old.isEmpty)
    }

    // MARK: Any install reason

    @Test("Jamf’s deadline counts whatever the install reason; another time without “declaration” doesn’t; the stale extra key stays ignored",
          arguments: ["declaration", "", "notification", "install-tonight", "auto-update,install-tonight"])
    func anyReason(reason: String) throws {
        let status = Self.status(reason: reason, updated: "2026-11-20T08:00:00")
        let target = Self.target(status, now: "2026-11-21T08:00:00")
        #expect(target.deadlineSource == .reported && target.deadlineDate == Sample.date("2026-11-23T22:59:11"))
        let rule = Self.rule(known: PostingBasis(), now: "2026-11-21T08:00:00")
        let posted = TargetRules.reportedPosting(rule, status: status, block: Self.block, catalog: Self.catalog, platform: .macOS,
                                                 serverTimeZone: Sample.utc)
        #expect(posted?.posted == Self.firstPosting && posted?.moment == Sample.date("2026-11-23T22:59:11"))
    }

    @Test("Without “declaration”: another time before the deadline, or only the stale extra key with a 2025 date, leaves the rule’s deadline")
    func otherReasons() {
        let other = Self.target(Self.status(deadline: "2026-11-21 10:17:00 +0000", reason: "notification", updated: "2026-11-20T08:00:00"),
                                now: "2026-11-21T08:00:00")
        #expect(!other.fromDevice && other.deadlineLocal == "2026-11-23T23:59:00" && other.deadlineSource == .otherDevices)
        let stale = Self.status(deadline: nil, reason: "notification", updated: "2026-11-20T08:00:00",
                                extra: [("softwareupdate.pending-version.softwareupdate.target-local-date-time", "2025-11-23 22:59:00 +0000")])
        let staleTarget = Self.target(stale, now: "2026-11-21T08:00:00")
        #expect(!staleTarget.fromDevice && staleTarget.deadlineDate == nil && staleTarget.deadlineLocal == "2026-11-23T23:59:00")
        let declared = Self.target(Self.status(deadline: nil, updated: "2026-11-20T08:00:00",
                                               extra: [("softwareupdate.pending-version.softwareupdate.target-local-date-time",
                                                        "2025-11-23 22:59:00 +0000")]), now: "2026-11-21T08:00:00")
        #expect(declared.deadlineDate == nil && declared.deadlineLocal == "2026-11-23T23:59:00")
    }

    // MARK: Next install attempt

    @Test("Deadline 16 Nov, then 17, 18, 19 and 20 Nov at other times, with “notification” or “declaration”: each a next attempt",
          arguments: [("2026-11-17 08:00:00 +0000", "notification"), ("2026-11-18 08:24:00 +0000", "declaration"),
                      ("2026-11-19 12:29:00 +0000", "notification"), ("2026-11-20 10:30:49 +0000", "declaration")])
    func nextAttemptsAfterSixteenth(deadline: String, reason: String) {
        let seven = TargetRulesTests.block(.semantic(minorEnforceAfterDays: 7, deploymentTime: "23:59"))
        let reported = String(deadline.prefix(10)) + "T06:00:00"
        let status = Self.status(deadline: deadline, reason: reason, updated: reported)
        let target = Self.target(status, now: "2026-11-21T08:00:00", block: seven)
        #expect(target.deadlineLocal == "2026-11-16T23:59:00")
        #expect(target.nextInstallAttempt != nil && target.nextInstallAttempt == TargetRules.reportedMoment(.init(targetLocalDateTime: deadline))?.date)
        let device = Sample.classify(Sample.mac(os: "26.7.2", model: "MacBookPro18,3"), status, target: target, now: "2026-11-21T08:00:00")
        #expect(device.pastDeadline == true)
    }

    // MARK: A 12-hour time

    @Test("“2026-11-23 10:59:11 PM +0000”, with a narrow no-break space or a space; 12 AM is midnight; others don’t read")
    func twelveHour() {
        let narrow = "2026-11-23 10:59:11\u{202F}PM +0000"
        #expect(TargetRules.twelveHour(narrow)?.local == "2026-11-23T22:59:11" && TargetRules.twelveHour(narrow)?.offset == 0)
        #expect(TargetRules.reportedMoment(.init(targetLocalDateTime: narrow))?.date == Sample.date("2026-11-23T22:59:11"))
        #expect(TargetRules.reportedMoment(.init(targetLocalDateTime: "2026-11-23 10:59:11 PM +0000"))?.date == Sample.date("2026-11-23T22:59:11"))
        #expect(TargetRules.reportedMoment(.init(targetLocalDateTime: "2026-11-24 12:30:00\u{00A0}AM +0100"))?.date == Sample.date("2026-11-23T23:30:00"))
        #expect(TargetRules.twelveHour("2026-11-24 12:05:00 PM")?.local == "2026-11-24T12:05:00")
        #expect(TargetRules.reportedLocal("2026-11-24 12:05:00 PM") == "2026-11-24T12:05:00")
        #expect(TargetRules.twelveHour("2026-11-24 13:05:00 PM +0000") == nil)
        #expect(TargetRules.twelveHour("2026-11-23 22:59:11 +0000") == nil)
        // as JTKit reads it, unchanged
        #expect(TargetRules.reportedMoment(.init(targetLocalDateTime: "2026-11-23 22:59:11 +0000"))?.offset == 0)
    }

    @Test("A Mac reporting Jamf’s deadline with a 12-hour clock: read, Jamf’s, and the Blueprint’s for the others")
    func twelveHourReport() {
        let status = Self.status(deadline: "2026-11-23 10:59:11\u{202F}PM +0000", updated: "2026-11-20T08:00:00")
        let target = Self.target(status, now: "2026-11-21T08:00:00")
        #expect(target.deadlineSource == .reported && target.deadlineDate == Sample.date("2026-11-23T22:59:11"))
        #expect(target.deadlineLocal == "2026-11-23T22:59:11")
        let posted = TargetRules.reportedPosting(Self.rule(known: PostingBasis(), now: "2026-11-21T08:00:00"), status: status,
                                                 block: Self.block, catalog: Self.catalog, platform: .macOS, serverTimeZone: Sample.utc)
        #expect(posted?.posted == Self.firstPosting)
    }

    // MARK: A Mac's earlier step

    @Test("A Mac’s 26.7.2 is the earlier step only with a deadline the Blueprint’s devices reported for it, to the minute")
    func macEarlierStep() {
        let status = Self.status(pending: "26.7.2", deadline: "2026-11-09 22:59:11 +0000", state: "downloading",
                                 os: "26.7.1", updated: "2026-11-10T08:00:00")
        let stepKey = PostingBasis.key(.macOS, OSVersion("26.7.2")!)
        func target(_ minutes: [String]) -> DeviceTarget {
            Self.target(status, known: PostingBasis(reported: [Self.key: Self.firstPosting],
                                                    reportedMinutes: [stepKey: Set(minutes.map { PostingBasis.minute(Sample.date($0)) })]),
                        now: "2026-11-20T12:00:00", os: "26.7.1")
        }
        // reported by the Blueprint's devices, seconds apart: this Blueprint's step, measured against 26.7.3
        let step = target(["2026-11-09T22:59:04"])
        #expect(step.version == "26.7.3" && step.earlierStepVersion == "26.7.2" && !step.fromDevice)
        // nothing remembered: another pending version, even though the rule would have given that deadline
        let none = target([])
        #expect(none.earlierStepVersion == nil && none.fromDevice && none.version == "26.7.2" && none.differsFromRule)
        // a quarter of an hour later has the same minutes modulo 15 (the old match): not the step
        let other = target(["2026-11-09T23:14:11"])
        #expect(other.earlierStepVersion == nil && other.fromDevice)
    }

}

/// iPhones and iPads keep the full-time match of their earlier step, without
/// any remembered deadline: their deadline is written in their own zone.
@Suite("0.3.2: an iPad’s earlier step, by its full clock time")
struct EarlierStepConfirmedTests {
    // 27.2 released 26 Oct and posted 5 Nov; Apple's public catalog lists 27.2.1 only
    static let gdmf = #"""
    {"PublicAssetSets":{"iOS":[
       {"ProductVersion":"27.2.1","Build":"24C40","PostingDate":"2026-11-09","SupportedDevices":["iPad14,8"]}]},
     "AssetSets":{"iOS":[
       {"ProductVersion":"27.2.1","Build":"24C40","PostingDate":"2026-11-09","SupportedDevices":["iPad14,8"]},
       {"ProductVersion":"27.2","Build":"24B119","PostingDate":"2026-11-05","SupportedDevices":["iPad14,8"]}]}}
    """#
    static let sofa = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.2.1","Build":"24C40","ReleaseDate":"2026-11-09T00:00:00Z"},
       "SecurityReleases":[{"ProductVersion":"27.2.1","Build":"24C40","ReleaseDate":"2026-11-09T00:00:00Z"},
                           {"ProductVersion":"27.2","Build":"24B119","ReleaseDate":"2026-10-26T00:00:00Z"}]}]}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaIOS: Data(sofa.utf8), gdmf: Data(gdmf.utf8))
    static let block = TargetRulesTests.block(.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59"))
    static let now = Sample.date("2026-11-10T12:00:00")

    static func target(deadline: String) -> DeviceTarget {
        let status = Sample.status([("device.operating-system.version", "27.1"), ("softwareupdate.install-state", "downloading"),
                                    ("softwareupdate.pending-version.os-version", "27.2"),
                                    ("softwareupdate.pending-version.target-local-date-time", deadline),
                                    ("softwareupdate.install-reason.reason", "declaration")], time: "2026-11-10T08:00:00")
        let rule = TargetRules.target(os: "27.1", model: "iPad14,8", boardID: nil, osName: "iPadOS", context: .init(
            block: block, catalog: catalog, platform: .iOS, blueprintChanged: nil, updateStarted: nil, now: now))
        return TargetRules.fromDevice(
            rule, status: status, os: "27.1", osName: "iPadOS", catalog: catalog, platform: .iOS, serverTimeZone: Sample.utc,
            model: "iPad14,8",
            earlierStepDeadline: { TargetRules.ruleDeadline(for: $0, block: block, catalog: catalog, platform: .iOS, model: "iPad14,8", boardID: nil) },
            earlierStepWindow: { TargetRules.ruleWindow(for: $0, block: block, catalog: catalog, platform: .iOS, model: "iPad14,8",
                                                        boardID: nil, now: now) },
            timeZone: "Europe/Brussels", now: now)
    }

    @Test("23:59 in Brussels (22:59 UTC) on 19 Nov is the step without anything remembered; 09:59 UTC isn’t")
    func fullClock() {
        #expect(Self.target(deadline: "2026-11-19 22:59:00 +0000").earlierStepVersion == "27.2")
        #expect(Self.target(deadline: "2026-11-19 09:59:00 +0000").earlierStepVersion == nil)
    }
}
