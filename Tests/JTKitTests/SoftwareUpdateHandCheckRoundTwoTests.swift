import Foundation
import Testing
import JTKit
@testable import JTKit

/// 0.3, round 2: the fixes from the round 1 hand check. Made-up devices and
/// IDs, shaped like what the live tenant showed on 2026-11-10.
@Suite("0.3: an older pending version with the newer version’s deadline")
struct MovedOnStepTests {
    // 27.2 released 26 Oct; 27.2.1 posted publicly on 9 Nov, for iPad15,8 only
    static let gdmf = #"""
    {"PublicAssetSets":{"iOS":[
       {"ProductVersion":"27.2.1","Build":"24C40","PostingDate":"2026-11-09","SupportedDevices":["iPad15,8"]}]},
     "AssetSets":{"iOS":[
       {"ProductVersion":"27.2.1","Build":"24C40","PostingDate":"2026-11-09","SupportedDevices":["iPad15,8"]},
       {"ProductVersion":"27.2","Build":"24B119","PostingDate":"2026-10-26","SupportedDevices":["iPad15,8","iPad14,8"]}]}}
    """#
    static let sofa = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.2.1","Build":"24C40","ReleaseDate":"2026-11-09T00:00:00Z"},
       "SecurityReleases":[{"ProductVersion":"27.2.1","Build":"24C40","ReleaseDate":"2026-11-09T00:00:00Z"},
                           {"ProductVersion":"27.2","Build":"24B119","ReleaseDate":"2026-10-26T00:00:00Z"}]}]}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaIOS: Data(sofa.utf8), gdmf: Data(gdmf.utf8))
    /// The newest release, 7 days, at 23:59: 27.2.1 is due 16 Nov 23:59, device local time.
    static let block = TargetRulesTests.block(.latest(enforceAfterDays: 7, deploymentTime: "23:59"))
    static let now = Sample.date("2026-11-10T12:00:00")

    static func status(pending: String = "27.2", deadline: String = "2026-11-16 22:59:02 +0000",
                       state: String = "none") -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "27.0.1"), ("softwareupdate.install-state", state),
                       ("softwareupdate.pending-version.os-version", pending),
                       ("softwareupdate.pending-version.target-local-date-time", deadline),
                       ("softwareupdate.install-reason.reason", "declaration")], time: "2026-11-10T07:57:08")
    }

    static func target(_ status: JamfPro.SoftwareUpdateStatus, model: String = "iPad15,8",
                       zone: String = "Europe/Brussels") -> DeviceTarget {
        let rule = TargetRules.target(os: "27.0.1", model: model, boardID: model, osName: "iPadOS", context: .init(
            block: block, catalog: catalog, platform: .iOS, blueprintChanged: nil, updateStarted: nil, now: now))
        return TargetRules.fromDevice(
            rule, status: status, os: "27.0.1", osName: "iPadOS", catalog: catalog, platform: .iOS, serverTimeZone: Sample.utc,
            model: model, boardID: model,
            earlierStepDeadline: { TargetRules.ruleDeadline(for: $0, block: block, catalog: catalog, platform: .iOS,
                                                            model: model, boardID: model) },
            earlierStepWindow: { TargetRules.ruleWindow(for: $0, block: block, catalog: catalog, platform: .iOS,
                                                        model: model, boardID: model, now: now) },
            timeZone: zone, now: now)
    }

    @Test("27.2 pending with 27.2.1’s deadline (16 Nov 23:59 in Brussels): the target is 27.2.1, 27.2 its earlier step")
    func liveCase() throws {
        let status = Self.status()
        let target = Self.target(status)
        #expect(target.version == "27.2.1" && !target.fromDevice)
        #expect(target.deadlineLocal == "2026-11-16T23:59:00")
        #expect(target.earlierStepVersion == "27.2" && !target.earlierStepLapsed)
        let device = Sample.classify(Sample.iPad(os: "27.0.1", model: "iPad15,8"), status, target: target, now: "2026-11-10T12:00:00")
        #expect(device.targetVersion == "27.2.1" && device.pastDeadline == false)
    }

    @Test("Not when Apple’s data doesn’t list the rule’s version for the device, or the deadline isn’t exactly the rule’s")
    func notMovedOn() {
        // iPad14,8 isn't in 27.2.1's list: what Jamf sent stands
        let unlisted = Self.target(Self.status(), model: "iPad14,8")
        #expect(unlisted.version == "27.2" && unlisted.fromDevice && unlisted.earlierStepVersion == nil)
        // another hour in the device's own zone: not the rule's deadline
        let otherHour = Self.target(Self.status(deadline: "2026-11-16 10:59:02 +0000"))
        #expect(otherHour.version == "27.2" && otherHour.earlierStepVersion == nil)
        // another major isn't a step
        let otherMajor = Self.target(Self.status(pending: "26.7.3"))
        #expect(otherMajor.earlierStepVersion == nil)
    }
}

@Suite("0.3: the device detail’s pending version")
struct PendingVersionTextTests {
    @Test("A pending version the device already runs, or older, reads as ignored")
    func ignored() {
        func device(_ os: String, pending: String?) -> DeviceStatus {
            var pairs = [("device.operating-system.version", os)]
            if let pending { pairs.append(("softwareupdate.pending-version.os-version", pending)) }
            return Sample.classify(Sample.mac(os: os), Sample.status(pairs))
        }
        #expect(DeviceDetailText.pendingVersion(device("15.8.1", pending: "15.8.1")) == "15.8.1 (already installed, ignored)")
        #expect(DeviceDetailText.pendingVersion(device("15.8.2", pending: "15.8.1")) == "15.8.1 (already installed, ignored)")
        #expect(DeviceDetailText.pendingVersion(device("15.8.1", pending: "15.8.2")) == "15.8.2")
        #expect(DeviceDetailText.pendingVersion(device("15.8.1", pending: nil)) == "–")
    }
}

@Suite("0.3: past the earlier step’s deadline, in the count and in Deadline per Time Zone")
struct PastStepAgreementTests {
    @Test("Downloaded and late, failed and late: past and listed at the step; still installing: neither; the number and rows agree")
    func agree() throws {
        func target(state: String) -> (JamfPro.SoftwareUpdateStatus, DeviceTarget) {
            let status = EarlierStepAndInstallTests.status(deadline: "2026-11-09 22:59:11 +0000", state: state)
            return (status, EarlierStepAndInstallTests.target(status, now: "2026-11-10T12:00:00"))
        }
        let devices = ["prepared", "failed", "installing"].enumerated().map { index, state -> DeviceStatus in
            let (status, target) = target(state: state)
            return Sample.classify(Sample.mac("\(index + 1)", os: "26.7.1", model: "MacBookPro18,3"), status, target: target,
                                   now: "2026-11-10T12:00:00")
        }
        #expect(devices.map(\.earlierStepVersion) == ["26.7.2", "26.7.2", "26.7.2"])
        #expect(devices.map { $0.pastDeadline == true } == [true, true, false])
        #expect(devices[1].category == .failed)
        let zones = DeadlineZones.zones(devices: devices, here: Sample.utc, now: Sample.date("2026-11-10T12:00:00"))
        let atStep = zones.filter { $0.target == "26.7.2, earlier step" }
        #expect(atStep.map(\.deviceCount).reduce(0, +) == devices.filter { $0.pastDeadline == true }.count)
        // the one still installing is at its current target's deadline
        #expect(zones.contains { $0.target == "26.7.3" && $0.deviceCount == 1 })
    }
}
