import Foundation
import Testing
import JTKit
@testable import JTKit

/// 0.3, round 1: the three items from the 0.2 hand checks. Made-up devices
/// and IDs, shaped like what the live tenant showed on 2026-11-10.
@Suite("0.3: the target pending with the earlier step’s deadline")
struct CarriedDeadlineTests {
    // Apple released 27.2 on 26 Oct: its list keeps this Mac's build posted that
    // day and other builds posted 5 Nov; 27.2.1 was posted publicly on 9 Nov
    static let gdmf = #"""
    {"PublicAssetSets":{"macOS":[
       {"ProductVersion":"27.2.1","Build":"26B131","PostingDate":"2026-11-09","SupportedDevices":["J457AP"]}]},
     "AssetSets":{"macOS":[
       {"ProductVersion":"27.2.1","Build":"26B131","PostingDate":"2026-11-09","SupportedDevices":["J457AP"]},
       {"ProductVersion":"27.2","Build":"26B123","PostingDate":"2026-10-26","SupportedDevices":["J457AP"]},
       {"ProductVersion":"27.2","Build":"26B8125","PostingDate":"2026-11-05","SupportedDevices":["J999AP"]}]}}
    """#
    static let sofa = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.2.1","Build":"26B131","ReleaseDate":"2026-11-09T00:00:00Z"},
       "SecurityReleases":[{"ProductVersion":"27.2.1","Build":"26B131","ReleaseDate":"2026-11-09T00:00:00Z"},
                           {"ProductVersion":"27.2","Build":"26B123","ReleaseDate":"2026-10-26T00:00:00Z"},
                           {"ProductVersion":"27.1","Build":"26B50","ReleaseDate":"2026-09-30T00:00:00Z"}]}],
     "Models":{"iMac21,2":{"OSVersions":[27]}},"Devices":{"J457AP":{"DeviceID":"iMac21,2"}}}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(sofa.utf8), gdmf: Data(gdmf.utf8))
    /// The newest release, 7 days, at 23:59.
    static let block = TargetRulesTests.block(.latest(enforceAfterDays: 7, deploymentTime: "23:59"))
    static let now = Sample.date("2026-11-10T12:00:00")

    static func status(os: String = "27.2", pending: String = "27.2.1", deadline: String = "2026-11-02 22:59:06 +0000",
                       state: String = "prepared") -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", os), ("softwareupdate.device-id", "J457AP"),
                       ("softwareupdate.install-state", state),
                       ("softwareupdate.pending-version.os-version", pending),
                       ("softwareupdate.pending-version.target-local-date-time", deadline),
                       ("softwareupdate.install-reason.reason", "declaration")], time: "2026-11-10T08:06:50")
    }

    static func target(_ status: JamfPro.SoftwareUpdateStatus, os: String = "27.2", known: PostingBasis = PostingBasis()) -> DeviceTarget {
        let rule = TargetRules.target(os: os, model: "iMac21,2", boardID: "J457AP", osName: "macOS", context: .init(
            block: block, catalog: catalog, platform: .macOS, blueprintChanged: Sample.date("2026-04-28T12:25:44"),
            updateStarted: nil, now: now))
        return TargetRules.fromDevice(
            rule, status: status, os: os, osName: "macOS", catalog: catalog, platform: .macOS, serverTimeZone: Sample.utc,
            model: "iMac21,2", boardID: "J457AP", blueprintChanged: Sample.date("2026-04-28T12:25:44"),
            earlierStepDeadline: { TargetRules.ruleDeadline(for: $0, block: block, catalog: catalog, platform: .macOS,
                                                            model: "iMac21,2", boardID: "J457AP") },
            earlierStepWindow: { TargetRules.ruleWindow(for: $0, block: block, catalog: catalog, platform: .macOS,
                                                        model: "iMac21,2", boardID: "J457AP", now: now) },
            known: known, now: now)
    }

    @Test("27.2.1 pending with 27.2’s deadline (2 Nov): the Blueprint’s deadline counts, the kept one is labeled")
    func liveCase() throws {
        let status = Self.status()
        let target = Self.target(status)
        #expect(target.version == "27.2.1" && target.fromDevice && !target.differsFromRule)
        #expect(target.deadlineLocal == "2026-11-16T23:59:00" && target.deadlineDate == nil)
        #expect(target.carriedStepVersion == "27.2" && target.carriedDeadline == Sample.date("2026-11-02T22:59:06"))
        let device = Sample.classify(Sample.mac(os: "27.2", model: "iMac21,2"), status, target: target, now: "2026-11-10T12:00:00")
        // before: "Downloaded, not installed after the deadline", past a deadline the Blueprint no longer has
        #expect(device.pastDeadline == false)
        #expect(device.diagnosis == "Downloaded, holds the deadline of the earlier step 27.2")
        #expect(!device.needsAttention)
        // Deadline per Time Zone labels it, at the deadline that counts (0.3 round 2: the rows agree with the count)
        let zones = DeadlineZones.zones(devices: [device], here: Sample.utc, now: Self.now)
        let row = try #require(zones.first)
        #expect(row.target == "27.2.1, still holds the deadline of earlier step 27.2")
        #expect(row.deadline == Sample.date("2026-11-16T23:59:00"))
        // Inspect says it
        let found = InspectFindings.evaluate(
            InspectInput(member: Sample.mac(os: "27.2", model: "iMac21,2"), status: status, device: device, platformDeviceID: "P-1", reports: []),
            context: InspectContext(blueprintID: "6a2f0000-1111-4000-8000-00000000c0de", target: OSVersion("27.2.1"), since: nil,
                                    now: Self.now, serverTimeZone: Sample.utc))
        let finding = try #require(found.findings.first { $0.cause == "Earlier step’s deadline kept" })
        #expect(finding.detail.contains("27.2.1 pending with the deadline of 27.2"))
        #expect(finding.detail.contains("As that deadline has passed"))
    }

    @Test("The target pending with its own deadline, or one no earlier step had, stays as reported")
    func notCarried() {
        let own = Self.target(Self.status(deadline: "2026-11-16 22:59:06 +0000"))
        #expect(own.carriedStepVersion == nil && own.deadlineDate == Sample.date("2026-11-16T22:59:06"))
        let other = Self.target(Self.status(deadline: "2026-11-05 10:17:00 +0000"))
        #expect(other.carriedStepVersion == nil && other.deadlineSource == .reported)
    }

    @Test("27.2 pending, due 12 Nov from another build’s 5 Nov posting: this Blueprint’s earlier step")
    func stepFromAnotherBuildsPosting() throws {
        let status = Self.status(os: "27.1", pending: "27.2", deadline: "2026-11-12 22:59:06 +0000")
        // a Mac: the Blueprint's devices reported this deadline for 27.2 while it was the target
        let target = Self.target(status, os: "27.1", known: PostingBasis(reportedMinutes: [
            PostingBasis.key(.macOS, try #require(OSVersion("27.2"))): [PostingBasis.minute(Sample.date("2026-11-12T22:59:00"))]]))
        #expect(target.version == "27.2.1" && !target.fromDevice)
        #expect(target.earlierStepVersion == "27.2")
        // one deadline per posting date Apple's list still has: this Mac's build's and the other's
        let window = TargetRules.ruleWindow(for: try #require(OSVersion("27.2")), block: Self.block, catalog: Self.catalog,
                                            platform: .macOS, model: "iMac21,2", boardID: "J457AP", now: Self.now)
        #expect(window == ["2026-11-02T23:59:00", "2026-11-12T23:59:00"])
    }
}

@Suite("0.3: errors from before a device installed its target, and failures with nothing in progress")
struct FailuresAndOnTargetTests {
    static let blueprintID = "6a2f0000-1111-4000-8000-00000000c0de"

    static func inspect(_ member: JamfPro.GroupMember, _ status: JamfPro.SoftwareUpdateStatus, row: DeviceStatus,
                        osVersionChanged: Date?) -> InspectResult {
        var input = InspectInput(member: member, status: status, device: row, platformDeviceID: "P-1", reports: [])
        input.osVersionChanged = osVersionChanged
        return InspectFindings.evaluate(input, context: InspectContext(blueprintID: blueprintID, target: OSVersion("27.0.1"),
                                                                       since: Sample.updateStarted, now: Sample.now,
                                                                       serverTimeZone: Sample.utc))
    }

    @Test("On target: no update error from before it installed the target under Also Found")
    func onTargetWithoutOldErrors() {
        let status = Sample.status([("device.operating-system.version", "27.0.1"), ("softwareupdate.install-state", "none"),
                                    ("softwareupdate.failure-reason.reason", "Software update failed."),
                                    ("softwareupdate.failure-reason.count", "2"),
                                    ("softwareupdate.failure-reason.timestamp", "2026-11-03T09:00:00")])
        let member = Sample.iPad(os: "27.0.1")
        let row = Sample.classify(member, status, context: Sample.context(since: Sample.updateStarted))
        #expect(row.category == .onTarget)
        // installed (reported 27.0.1) on 4 Nov, after the error of 3 Nov, which was since the update started
        let installed = Self.inspect(member, status, row: row, osVersionChanged: Sample.date("2026-11-04T08:00:00"))
        #expect(!installed.alsoFound.contains { $0.cause.contains("error") || $0.cause.contains("Update error") })
        // an error from before the update started is left out too, also without the version's time
        let old = Sample.status([("device.operating-system.version", "27.0.1"),
                                 ("softwareupdate.failure-reason.reason", "Software update failed."),
                                 ("softwareupdate.failure-reason.timestamp", "2026-10-01T00:00:00")])
        let oldRow = Sample.classify(member, old, context: Sample.context(since: Sample.updateStarted))
        #expect(!Self.inspect(member, old, row: oldRow, osVersionChanged: nil).alsoFound.contains { $0.cause == "Earlier update error" })
        // an error after it reported the target is still listed
        let after = Self.inspect(member, status, row: row, osVersionChanged: Sample.date("2026-11-02T08:00:00"))
        #expect(after.alsoFound.contains { $0.cause == "Update error" })
    }

    @Test("Failures since the update started with nothing in progress: Failed, not Not started")
    func failedNotNotStarted() {
        // another (older) version pending, nothing in progress, failed since the update started
        let older = Sample.classify(Sample.iPad(), Sample.status([
            ("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "none"),
            ("softwareupdate.pending-version.os-version", "26.7.2"),
            ("softwareupdate.failure-reason.reason", #"Code=3 "(null)""#), ("softwareupdate.failure-reason.count", "3"),
            ("softwareupdate.failure-reason.timestamp", "2026-11-04T10:00:00")]), context: Sample.context(since: Sample.updateStarted))
        #expect(older.category == .failed)
        #expect(older.diagnosis == "No update offered (check deferrals and compatibility)")
        // a failed state for another version: nothing in progress either
        let failedState = Sample.classify(Sample.iPad(), Sample.status([
            ("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "failed"),
            ("softwareupdate.pending-version.os-version", "26.7.2")]), context: Sample.context(since: Sample.updateStarted))
        #expect(failedState.category == .failed)
        // still downloading another version: other update; a count of 0 is no failure
        let downloading = Sample.classify(Sample.iPad(), Sample.status([
            ("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "downloading"),
            ("softwareupdate.pending-version.os-version", "26.7.2"),
            ("softwareupdate.failure-reason.timestamp", "2026-11-04T10:00:00")]), context: Sample.context(since: Sample.updateStarted))
        #expect(downloading.category == .otherUpdate)
        let none = Sample.classify(Sample.iPad(), Sample.status([
            ("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "none"),
            ("softwareupdate.failure-reason.count", "0"),
            ("softwareupdate.failure-reason.timestamp", "2026-11-04T10:00:00")]), context: Sample.context(since: Sample.updateStarted))
        #expect(none.category == .notStarted)
    }
}

@Suite("0.3: Open in Jamf Pro (A) and readiness (G)")
@MainActor
struct OpenAndReadinessTests {

    @Test("Readiness: User Enrollment (iPhones and iPads), Macs not supervised, no declarative management, never reported")
    func readiness() {
        // an unsupervised iPad with a device enrollment is fine: Apple allows the enforced update
        var deviceEnrolled = Sample.iPad("1")
        deviceEnrolled.supervised = false
        deviceEnrolled.appleEnrollmentType = "device"
        var userEnrolled = Sample.iPad("2")
        userEnrolled.supervised = false
        userEnrolled.deviceOwnershipType = "AccountDrivenUserEnrollment"
        var noDDM = Sample.iPad("3")
        noDDM.ddmEnabled = false
        var mac = Sample.mac("4")
        mac.supervised = false
        let os = Sample.status([("device.operating-system.version", "26.7.1")])
        let devices = [
            Sample.classify(deviceEnrolled, os), Sample.classify(userEnrolled, os), Sample.classify(noDDM, os),
            // a Mac that isn't supervised; it never reported
            Sample.classify(mac, nil),
            // a report that couldn't be read isn't "never reported"
            Sample.classify(Sample.iPad("5"), nil, problem: "HTTP 403"),
        ]
        #expect(devices.filter(ReadinessCheck.userEnrollment.applies).map(\.jamfID) == ["2"])
        #expect(devices.filter(ReadinessCheck.macNotSupervised.applies).map(\.jamfID) == ["4"])
        #expect(devices.filter(ReadinessCheck.noDeclarativeManagement.applies).map(\.jamfID) == ["3"])
        // the Mac is counted once, under its most basic reason (0.3.2): not supervised, not also never reported
        #expect(devices.filter(ReadinessCheck.neverReported.applies).map(\.jamfID) == [])
        #expect(ReadinessCheck.neverReported.fits(devices[3]))
        // without the enrollment in the inventory, nothing is guessed
        #expect(!ReadinessCheck.userEnrollment.applies(to: Sample.classify(Sample.iPad("6"), os)))
    }

}
