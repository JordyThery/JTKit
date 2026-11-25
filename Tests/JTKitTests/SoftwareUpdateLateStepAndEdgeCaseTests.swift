import Foundation
import Testing
import JTKit
@testable import JTKit

/// A late earlier step, left-over install states, check-ins, the grace,
/// coverage by major, range shapes and history marks. Made-up devices.
@Suite("Late earlier steps and edge cases")
struct LateStepAndEdgeCaseTests {
    typealias Step = EarlierStepAndInstallTests

    static func prepared(time: String = "2026-11-09T23:00:00", state: String = "prepared") -> JamfPro.SoftwareUpdateStatus {
        Step.status(state: state, time: time)
    }

    // MARK: Earlier steps

    @Test("Downloading or failed days after the step’s deadline: late as well")
    func lateOtherStates() {
        for state in ["downloading", "failed"] {
            let target = Step.target(Self.prepared(state: state), now: "2026-11-12T09:00:00")
            #expect(target.version == "26.7.3" && target.earlierStepLapsed, "\(state)")
            let device = Sample.classify(Step.member, Self.prepared(state: state), target: target, now: "2026-11-12T09:00:00")
            #expect(device.pastDeadline == true, "\(state)")
        }
    }

    @Test("Installing, or within the grace: still the earlier step, the Blueprint’s deadline counts")
    func stepUnderWay() {
        let installing = Step.target(Self.prepared(state: "installing"), now: "2026-11-12T09:00:00")
        #expect(installing.version == "26.7.3" && installing.earlierStepVersion == "26.7.2" && !installing.earlierStepLapsed)
        // 22:59 UTC plus 4 hours is 02:59; the target stays 26.7.3 either way
        let within = Step.target(Self.prepared(), now: "2026-11-10T02:30:00")
        #expect(within.version == "26.7.3" && !within.earlierStepLapsed)
        let after = Step.target(Self.prepared(), now: "2026-11-10T03:00:00")
        #expect(after.version == "26.7.3" && after.earlierStepLapsed)
    }

    @Test("A pending version reported before the update started is no earlier step: target and deadline are the Blueprint’s")
    func lateStepOldReport() {
        let status = Self.prepared(time: "2026-11-05T08:00:00")
        let target = Step.target(status, now: "2026-11-11T09:00:00")
        #expect(target.version == "26.7.3" && target.deadlineLocal == "2026-11-23T23:59:00")
        #expect(target.earlierStepVersion == nil && !target.earlierStepLapsed && !target.fromDevice)
        let device = Sample.classify(Step.member, status, target: target, now: "2026-11-11T09:00:00")
        #expect(device.pastDeadline == false)
    }

    @Test("The step installed per the inventory: no step, no install state, no long install")
    func stepInstalled() {
        let member = Sample.mac(os: "26.7.2", model: "MacBookPro18,3")
        let status = Step.status(state: "installing", time: "2026-11-09T23:00:00")
        let rule = TargetRules.target(os: "26.7.2", model: "MacBookPro18,3", boardID: "J314sAP", osName: "macOS", context: .init(
            block: Step.block, catalog: Step.catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil,
            now: Sample.date("2026-11-10T12:00:00")))
        let target = TargetRules.fromDevice(rule, status: status, os: "26.7.2", osName: "macOS", catalog: Step.catalog,
                                            platform: .macOS, serverTimeZone: Sample.utc)
        #expect(target.version == "26.7.3" && target.earlierStepVersion == nil)
        let device = Sample.classify(member, status, target: target, now: "2026-11-10T12:00:00")
        #expect(device.currentOS == "26.7.2")
        #expect(device.category != .inProgress && device.category != .otherUpdate)
        #expect(!device.diagnosis.hasPrefix("Installing"))
    }

    @Test("The same deadline at the edges of the world’s zones, and not the day before")
    func deadlineEdges() {
        let expected = "2026-11-09T23:59:00"
        // UTC−12: 23:59 there is 11:59 the next day in UTC
        #expect(TargetRules.sameDeadline(reported: Sample.date("2026-11-10T11:59:00"), reportedLocal: nil, expected: expected))
        // UTC+14: 23:59 there is 09:59 the same day in UTC
        #expect(TargetRules.sameDeadline(reported: Sample.date("2026-11-09T09:59:00"), reportedLocal: nil, expected: expected))
        #expect(!TargetRules.sameDeadline(reported: Sample.date("2026-11-10T12:05:00"), reportedLocal: nil, expected: expected))
        #expect(!TargetRules.sameDeadline(reported: Sample.date("2026-11-08T20:00:00"), reportedLocal: nil, expected: expected))
        #expect(!TargetRules.sameDeadline(reported: nil, reportedLocal: "2026-11-08T23:59:00", expected: expected))
    }

    // MARK: Install states and check-ins

    @Test("An install state for a version the device already runs is ignored, in the list and in Inspect")
    func leftOverState() {
        // reports 26.7.1 installing 26.7.2; the inventory already shows 26.7.2
        let member = Sample.iPad(os: "26.7.2")
        let status = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "installing"),
                                    ("softwareupdate.pending-version.os-version", "26.7.2")], time: "2026-11-05T06:00:00")
        let device = Sample.classify(member, status)
        #expect(!device.diagnosis.hasPrefix("Installing"))
        #expect(device.category != .inProgress)
        let inspected = InspectFindings.evaluate(
            InspectInput(member: member, status: status, device: device, platformDeviceID: "P-1", reports: []),
            context: InspectContext(blueprintID: "6a2f0000-1111-4000-8000-00000000c0de", target: nil, since: nil,
                                    now: Sample.now, serverTimeZone: Sample.utc))
        #expect(!inspected.findings.contains { $0.cause.hasPrefix("Installing") || $0.cause == "Update in progress" })
    }

    @Test("Checking in means a contact at least 30 minutes after the status")
    func laterContact() {
        let status = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "installing")],
                                   time: "2026-11-05T06:00:00")
        let seconds = Sample.classify(Sample.iPad(lastContact: Sample.date("2026-11-05T06:00:10")), status)
        #expect(seconds.diagnosis.hasSuffix(", no contact since (switched off or stuck)"))
        let later = Sample.classify(Sample.iPad(lastContact: Sample.date("2026-11-05T06:31:00")), status)
        #expect(later.diagnosis.hasSuffix("for more than 4 hours; the device checks in but hasn’t reported a new status"))
    }

    @Test("A long install is measured in the Jamf Pro server’s time zone")
    func longInstallServerZone() {
        // 09:30 in Brussels is 08:30 UTC: 4.5 hours before 13:00 UTC; read as UTC it’s 3.5
        let status = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "installing")],
                                   time: "2026-11-05T09:30:00")
        let brussels = Sample.classify(Sample.iPad(), status,
                                       context: Sample.context(serverTimeZone: TimeZone(identifier: "Europe/Brussels")!))
        #expect(brussels.diagnosis.contains("for more than 4 hours"))
        #expect(Sample.classify(Sample.iPad(), status).diagnosis == "Installing now")
    }

    @Test("The grace: stuck from exactly 4 hours after a reported deadline")
    func graceEdges() {
        let prepared = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "prepared"),
                                      ("softwareupdate.pending-version.os-version", "26.7.2")])
        var target = DeviceTarget(version: "26.7.2", reason: "Made up")
        target.deadlineDate = Sample.date("2026-11-09T11:00:00")
        target.deadlineLocal = "2026-11-09T11:00:00"
        target.deadlineSource = .reported
        let mac = Sample.mac(os: "26.7.1")
        #expect(Sample.classify(mac, prepared, target: target, now: "2026-11-09T14:59:00").diagnosis.contains("installs now"))
        #expect(Sample.classify(mac, prepared, target: target, now: "2026-11-09T15:00:00").diagnosis
                == "Downloaded, not installed after the deadline")
    }

    // MARK: Inspect

    @Test("A stale declaration report is the likely cause only without a status since; a long install comes first")
    func staleReportRank() {
        let blueprint = "6a2f0000-1111-4000-8000-00000000c0de"
        let old = JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_\(blueprint)_s1_c1_sys_cfg1", type: "CONFIGURATION",
                                                 status: .successful, active: true, validity: .valid,
                                                 lastReportTime: Sample.date("2026-10-20T09:00:00"))
        func evaluate(_ status: JamfPro.SoftwareUpdateStatus) -> InspectResult {
            InspectFindings.evaluate(
                InspectInput(member: Sample.iPad(), status: status, device: Sample.classify(Sample.iPad(), status),
                             platformDeviceID: "P-1", reports: [old]),
                context: InspectContext(blueprintID: blueprint, target: nil, since: Sample.updateStarted,
                                        now: Sample.now, serverTimeZone: Sample.utc))
        }
        let quiet = Sample.status([("device.operating-system.version", "26.7.1")], time: "2026-10-20T09:00:00")
        #expect(evaluate(quiet).cause == "Not evaluated since the update started")
        let installing = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "installing")],
                                       time: "2026-11-05T06:00:00")
        let result = evaluate(installing)
        #expect(result.cause == "Installing for more than 4 hours")
        #expect(result.alsoFound.contains { $0.cause == "Not evaluated since the update started" })
    }

    @Test("Coverage: only the device’s own major counts, and only when the Blueprint asks for more")
    func coverageByMajor() {
        let tests = InspectCoverageAndErrorTests()
        let reports = tests.pair(10, versions: "^(27[.][0-1]([.][0-9]+)*)$", lists: ["J314sAP"])
            + tests.pair(12, versions: InspectCoverageAndErrorTests.below, lists: ["J314sAP"])
        let result = tests.evaluate(InspectCoverageAndErrorTests.mac, status: InspectCoverageAndErrorTests.status, reports: reports)
        #expect(result.cause == "Jamf’s update doesn’t cover macOS 26.7.2 yet")
        #expect(result.detail.contains("covered macOS 26.0 to 26.7.1, not 26.7.2") && !result.detail.contains("27.0"))
        // a device already on what the Blueprint asks for: nothing to cover
        let current = InspectFindings.evaluate(
            InspectInput(member: InspectCoverageAndErrorTests.mac, status: InspectCoverageAndErrorTests.status,
                         device: Sample.classify(InspectCoverageAndErrorTests.mac, InspectCoverageAndErrorTests.status),
                         platformDeviceID: "P-1", reports: reports),
            context: InspectContext(blueprintID: tests.blueprint, target: OSVersion("26.7.2"), since: Sample.updateStarted,
                                    now: Sample.now, serverTimeZone: Sample.utc))
        #expect(!current.findings.contains { $0.cause.hasPrefix("Jamf’s update doesn’t cover") })
    }

    @Test("Range shapes: lower bound only, one version, a patch start, an upper bound, whole-text matching", arguments: [
        (#"x MATCHES "^(26[.]([7-9]|[1-9][0-9])([.][0-9]+)*)$""#, "26.7 and later"),
        (#"x MATCHES "^(26[.]7[.]1)$""#, "26.7.1"),
        (#"x MATCHES "^(26[.]5[.][1-9]|26[.][6-7]([.][0-9]+)*)$""#, "26.5.1 to 26.7.x"),
        (#"x version <= "27.0.1" AND x version BEGINSWITH "27." AND y"#, "27 up to 27.0.1"),
        (#"x MATCHES "26[.]7""#, "26.7"),
    ])
    func rangeShapes(predicate: String, range: String) {
        #expect(DeclarationPair.versionRange(predicate) == range)
    }

    @Test("The OS family reads in both forms")
    func familyForms() {
        func pair(_ predicate: String) -> DeclarationPair {
            DeclarationPair(key: "k", number: "1", reports: [JamfPlatform.DeclarationReport(
                declarationIdentifier: "x_act1", type: "ACTIVATION", status: .unsuccessful,
                reasons: [.init(code: "Info.Predicate", details: [.init(key: "Predicate", description: predicate)])])])
        }
        #expect(pair(#"status.device.operating-system.family == "macOS" AND x"#).family == "macOS")
        #expect(pair(#"@status(device.operating-system.family) == 'iPadOS' AND x"#).family == "iPadOS")
    }

    // MARK: History

}
