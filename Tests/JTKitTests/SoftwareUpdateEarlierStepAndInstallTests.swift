import Foundation
import Testing
import JTKit
@testable import JTKit

/// This Blueprint’s earlier step, long installs, the grace after a deadline
/// and the newer of the reported and inventory versions. Made-up devices.
@Suite("Earlier steps, long installs and the deadline’s grace")
struct EarlierStepAndInstallTests {
    // Apple posted 26.7.2 on 26 Oct and 26.7.3 on 9 Nov
    static let gdmf = #"""
    {"PublicAssetSets":{"macOS":[
       {"ProductVersion":"26.7.3","Build":"25G342","PostingDate":"2026-11-09","SupportedDevices":["J314sAP"]},
       {"ProductVersion":"26.7.2","Build":"25G332","PostingDate":"2026-10-26","SupportedDevices":["J314sAP"]}]},
     "AssetSets":{"macOS":[
       {"ProductVersion":"26.7.3","Build":"25G342","PostingDate":"2026-11-09","SupportedDevices":["J314sAP"]},
       {"ProductVersion":"26.7.2","Build":"25G332","PostingDate":"2026-10-26","SupportedDevices":["J314sAP"]}]}}
    """#
    static let sofa = #"""
    {"OSVersions":[{"OSVersion":"26","Latest":{"ProductVersion":"26.7.3","Build":"25G342","ReleaseDate":"2026-11-09T00:00:00Z"}}],
     "Models":{"MacBookPro18,3":{"OSVersions":[26]}},"Devices":{"J314sAP":{"DeviceID":"MacBookPro18,3"}}}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(sofa.utf8), gdmf: Data(gdmf.utf8))
    static let block = TargetRulesTests.block(.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59"))
    static let member = Sample.mac(os: "26.7.1", model: "MacBookPro18,3")

    static func status(pending: String = "26.7.2", deadline: String = "2026-11-09 22:59:11 +0000", state: String = "installing",
                       reason: String = "declaration", time: String = "2026-11-09T23:00:00") -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.device-id", "J314sAP"),
                       ("softwareupdate.install-state", state),
                       ("softwareupdate.pending-version.os-version", pending),
                       ("softwareupdate.pending-version.target-local-date-time", deadline),
                       ("softwareupdate.install-reason.reason", reason)], time: time)
    }

    /// `reported`: the deadlines this Blueprint’s devices reported for 26.7.2 while it was the target (UTC
    /// moments), the only way a Mac’s step is recognized; by default 26.7.2’s own.
    static func target(_ status: JamfPro.SoftwareUpdateStatus, now: String = "2026-11-10T00:30:00",
                       reported: [String] = ["2026-11-09T22:59:04"]) -> DeviceTarget {
        let rule = TargetRules.target(os: "26.7.1", model: "MacBookPro18,3", boardID: "J314sAP", osName: "macOS", context: .init(
            block: block, catalog: catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil, now: Sample.date(now)))
        return TargetRules.fromDevice(rule, status: status, os: "26.7.1", osName: "macOS", catalog: catalog, platform: .macOS,
                                      serverTimeZone: Sample.utc, model: "MacBookPro18,3", boardID: "J314sAP",
                                      earlierStepDeadline: { version in
                                          TargetRules.ruleDeadline(for: version, block: block, catalog: catalog, platform: .macOS,
                                                                   model: "MacBookPro18,3", boardID: "J314sAP")
                                      },
                                      known: PostingBasis(reportedMinutes: [PostingBasis.key(.macOS, OSVersion("26.7.2")!):
                                                                                Set(reported.map { PostingBasis.minute(Sample.date($0)) })]),
                                      now: Sample.date(now))
    }

    @Test("This Blueprint’s earlier step: the rule’s version and deadline count, the step is shown")
    func earlierStep() {
        let status = Self.status()
        let target = Self.target(status)
        #expect(target.version == "26.7.3" && target.deadlineLocal == "2026-11-23T23:59:00")
        #expect(target.earlierStepVersion == "26.7.2" && target.earlierStepDeadline == Sample.date("2026-11-09T22:59:11"))
        #expect(!target.fromDevice)
        let device = Sample.classify(Self.member, status, target: target, now: "2026-11-10T00:30:00")
        #expect(device.category == .otherUpdate)
        #expect(device.diagnosis == "Installing 26.7.2 first (an earlier step of this Blueprint)")
        // its own deadline has passed, the Blueprint's hasn't: not late
        #expect(device.pastDeadline == false)
    }

    @Test("A reported deadline anywhere in the world’s zones is the same deadline; another day isn’t")
    func sameDeadline() {
        let expected = "2026-11-09T23:59:00"
        #expect(TargetRules.sameDeadline(reported: Sample.date("2026-11-09T22:59:11"), reportedLocal: nil, expected: expected))
        // 23:59 in UTC−6 is the next morning in UTC
        #expect(TargetRules.sameDeadline(reported: Sample.date("2026-11-10T05:59:00"), reportedLocal: nil, expected: expected))
        #expect(!TargetRules.sameDeadline(reported: Sample.date("2026-11-15T22:59:00"), reportedLocal: nil, expected: expected))
        #expect(TargetRules.sameDeadline(reported: nil, reportedLocal: "2026-11-09T23:59:00", expected: expected))
    }

    @Test("A lower pending version with another deadline stays what Jamf sent")
    func notAnEarlierStep() {
        let target = Self.target(Self.status(deadline: "2026-11-15 22:59:00 +0000"))
        #expect(target.version == "26.7.2" && target.fromDevice && target.differsFromRule)
        #expect(target.earlierStepVersion == nil)
        // not from a declaration: the rule stands, without a step
        let notification = Self.target(Self.status(reason: "notification"))
        #expect(notification.version == "26.7.3" && notification.earlierStepVersion == nil)
    }

    @Test("Installing for more than 4 hours: flagged when the device checks in, said apart when it doesn’t")
    func longInstall() {
        let installing = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "installing"),
                                        ("softwareupdate.pending-version.os-version", "27.0.1")], time: "2026-11-05T06:00:00")
        // contact at 10:00, after the status at 06:00; now 13:00
        let device = Sample.classify(Sample.iPad(), installing)
        #expect(device.category == .inProgress)
        #expect(device.diagnosis == "Installing 27.0.1 for more than 4 hours; the device checks in but hasn’t reported a new status")
        #expect(device.needsAttention)
        let silent = Sample.classify(Sample.iPad(lastContact: Sample.date("2026-11-05T05:00:00")), installing)
        #expect(silent.diagnosis == "Installing since \(InspectFindings.dayTime(Sample.date("2026-11-05T06:00:00"))), "
                + "no contact since (switched off or stuck)")
        #expect(silent.needsAttention)
        let recent = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "installing")],
                                   time: "2026-11-05T11:00:00")
        #expect(Sample.classify(Sample.iPad(), recent).diagnosis == "Installing now")
    }

    @Test("Inspect says the same of a long install")
    func longInstallInspect() throws {
        let installing = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "installing"),
                                        ("softwareupdate.pending-version.os-version", "27.0.1")], time: "2026-11-05T06:00:00")
        let row = Sample.classify(Sample.iPad(), installing)
        let result = InspectFindings.evaluate(
            InspectInput(member: Sample.iPad(), status: installing, device: row, platformDeviceID: "P-1", reports: []),
            context: InspectContext(blueprintID: "6a2f0000-1111-4000-8000-00000000c0de", target: nil, since: nil,
                                    now: Sample.now, serverTimeZone: Sample.utc))
        let finding = try #require(result.findings.first { $0.cause == "Installing for more than 4 hours" })
        #expect(finding.detail.contains("checks in with Jamf but hasn’t reported a new status"))
    }

    @Test("The newer of the reported and inventory versions counts: installed, status not updated yet")
    func newerVersion() {
        #expect(Classifier.newer("26.7.1", "26.7.2") == "26.7.2")
        #expect(Classifier.newer("27.0.1", "26.7.2") == "27.0.1")
        #expect(Classifier.newer(nil, "26.7.2") == "26.7.2")
        let device = Sample.classify(Sample.iPad(os: "27.0.1"), Sample.status([("device.operating-system.version", "26.7.1"),
                                                                               ("softwareupdate.install-state", "installing")]))
        #expect(device.category == .onTarget)
        #expect(device.currentOS == "27.0.1")
    }

    @Test("Just past the deadline a downloaded update installs now; after the grace it is stuck")
    func grace() {
        let prepared = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "prepared"),
                                      ("softwareupdate.pending-version.os-version", "26.7.2")])
        // 12:00 in Brussels is 11:00 UTC
        let target = DeviceTarget(version: "26.7.2", deadlineLocal: "2026-11-09T12:00:00", reason: "Made up")
        let justPast = Sample.classify(Sample.iPad(), prepared, target: target, now: "2026-11-09T13:00:00")
        #expect(justPast.pastDeadline == true)
        #expect(justPast.diagnosis == "Downloaded, installs now (the deadline has just passed)")
        let later = Sample.classify(Sample.iPad(), prepared, target: target, now: "2026-11-09T16:00:00")
        #expect(later.diagnosis == "Downloaded, not installed after the deadline")

        func inspect(_ row: DeviceStatus, now: String) -> [String] {
            InspectFindings.evaluate(
                InspectInput(member: Sample.iPad(), status: prepared, device: row, platformDeviceID: "P-1", reports: []),
                context: InspectContext(blueprintID: "6a2f0000-1111-4000-8000-00000000c0de", target: nil, since: nil,
                                        now: Sample.date(now), serverTimeZone: Sample.utc)).findings.map(\.cause)
        }
        #expect(inspect(justPast, now: "2026-11-09T13:00:00").contains("Update downloaded"))
        #expect(!inspect(justPast, now: "2026-11-09T13:00:00").contains("Update stuck"))
        #expect(inspect(later, now: "2026-11-09T16:00:00").contains("Update stuck"))
    }

    @Test("A device with no error since the update started, but an earlier one, says so")
    func earlierErrorDiagnosis() {
        let device = Sample.classify(Sample.iPad(), Sample.status([
            ("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "none"),
            ("softwareupdate.failure-reason.reason", "Software update failed."),
            ("softwareupdate.failure-reason.timestamp", "2026-10-01T00:00:00")]), context: Sample.context(since: Sample.updateStarted))
        #expect(device.diagnosis == "Online, update not started (no error since the update started)")
        #expect(device.needsAttention)
    }
}
