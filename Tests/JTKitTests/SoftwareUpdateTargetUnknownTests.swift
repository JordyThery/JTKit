import Foundation
import Testing
import JTKit
import JTKitTestSupport
@testable import JTKit

/// A device without a target is never measured against nothing: it is
/// “Target unknown” with its reason, outside every count. Made-up data only.
@Suite("Target unknown")
struct TargetUnknownTests {
    private static func target(_ enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement?, os: String?, osName: String = "macOS",
                               platform: AppleReleases.Platform = .macOS,
                               catalog: AppleReleases.Catalog? = TargetRulesTests.catalog) -> DeviceTarget {
        TargetRules.target(os: os, model: "Mac14,2", boardID: nil, osName: osName, context: .init(
            block: enforcement.map { TargetRulesTests.block($0) }, catalog: catalog, platform: platform,
            blueprintChanged: nil, updateStarted: nil, now: Sample.date("2026-11-09T12:00:00")))
    }

    private static let minor = JamfPlatform.SoftwareUpdateBlock.Enforcement.semantic(minorEnforceAfterDays: 0, deploymentTime: nil)
    private static let latest = JamfPlatform.SoftwareUpdateBlock.Enforcement.latest(enforceAfterDays: 0, deploymentTime: nil)

    @Test("Apple’s data unreachable: latest and minor have no target")
    func appleDataUnreachable() {
        for enforcement in [Self.minor, Self.latest] {
            let target = Self.target(enforcement, os: "26.7.1", catalog: nil)
            #expect(target.unknown == .appleDataUnreachable && target.version == nil)
        }
        // a specific version doesn't need Apple's data
        #expect(Self.target(.specific(targetOSVersion: "27.1", targetLocalDateTime: nil, detailsURL: nil), os: "26.7.1",
                            catalog: nil).unknown == nil)
    }

    @Test("No software update in the Blueprint, or one this app can’t read")
    func noSoftwareUpdate() {
        #expect(Self.target(nil, os: "26.7.1").unknown == .noSoftwareUpdate)
        #expect(Self.target(.unknown(nil), os: "26.7.1").unknown == .unreadableUpdate)
        #expect(Self.target(.specific(targetOSVersion: "latest please", targetLocalDateTime: nil, detailsURL: nil), os: "26.7.1")
            .unknown == .unreadableUpdate)
    }

    @Test("No release for the platform or the device’s major")
    func noReleaseForPlatform() {
        // Apple's data holds Mac releases only
        #expect(Self.target(Self.latest, os: "26.7.1", osName: "iPadOS", platform: .iOS).unknown == .noReleaseForPlatform)
        #expect(Self.target(Self.minor, os: "26.7.1", osName: "iPadOS", platform: .iOS).unknown == .noReleaseForPlatform)
        // an old major Apple's data no longer lists
        #expect(Self.target(Self.minor, os: "14.8.9").unknown == .noReleaseForPlatform)
    }

    @Test("A beta of a major newer than Apple’s newest release")
    func betaOfNewerMajor() {
        let target = Self.target(Self.minor, os: "28.0")
        #expect(target.unknown == .betaOfNewerMajor)
        #expect(target.reason.contains("beta of macOS 28"))
        // with the newest release as the rule, a beta is simply past it
        #expect(Self.target(Self.latest, os: "28.0").version == "27.2")
    }

    @Test("A device that reports no version, under minor updates")
    func noReportedVersion() {
        #expect(Self.target(Self.minor, os: nil).unknown == .noReportedVersion)
    }

}

/// The target rules’ finer points: releases for some devices only, the
/// Blueprint step per OS, deadlines around daylight saving and on Macs.
@Suite("Targets: releases per device, steps, daylight saving")
struct TargetRulesEdgeTests {
    static let sofaIOS = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.0.2","Build":"24A300","ReleaseDate":"2026-10-20T00:00:00Z","SupportedDevices":["iPhone18,1"]},
      "SecurityReleases":[{"ProductVersion":"27.0.2","Build":"24A300","ReleaseDate":"2026-10-20T00:00:00Z"},
                          {"ProductVersion":"27.0.1","Build":"24A200","ReleaseDate":"2026-10-01T00:00:00Z"}]}]}
    """#
    static let gdmf = #"""
    {"PublicAssetSets":{"iOS":[
      {"ProductVersion":"27.0.2","Build":"24A300","PostingDate":"2026-10-20","SupportedDevices":["iPhone18,1"]},
      {"ProductVersion":"27.0.1","Build":"24A200","PostingDate":"2026-10-01","SupportedDevices":["iPhone17,1","iPhone18,1"]}]}}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaIOS: Data(sofaIOS.utf8), gdmf: Data(gdmf.utf8))

    private func target(_ enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement, os: String, model: String) -> DeviceTarget {
        TargetRules.target(os: os, model: model, boardID: nil, osName: "iOS", context: .init(
            block: TargetRulesTests.block(enforcement), catalog: Self.catalog, platform: .iOS,
            blueprintChanged: nil, updateStarted: nil, now: Sample.date("2026-11-09T12:00:00")))
    }

    @Test("A release for some devices only is the target of those devices only")
    func perReleaseDevices() {
        let latest = JamfPlatform.SoftwareUpdateBlock.Enforcement.latest(enforceAfterDays: 0, deploymentTime: nil)
        let minor = JamfPlatform.SoftwareUpdateBlock.Enforcement.semantic(minorEnforceAfterDays: 0, deploymentTime: nil)
        #expect(target(latest, os: "27.0.1", model: "iPhone18,1").version == "27.0.2")
        #expect(target(latest, os: "27.0.1", model: "iPhone17,1").version == "27.0.1")
        #expect(target(minor, os: "27.0.1", model: "iPhone17,1").version == "27.0.1")
        #expect(target(minor, os: "27.0.1", model: "iPhone18,1").version == "27.0.2")
        // not limited by hardware: the same major
        #expect(!target(latest, os: "27.0.1", model: "iPhone17,1").limitedByHardware)
        // a model no list knows gets the newest
        #expect(target(latest, os: "27.0.1", model: "iPhone99,9").version == "27.0.2")
    }

    @Test("A deadline on the day the clocks go back is that day’s local time")
    func daylightSaving() throws {
        let deadline = try #require(TargetRules.deadlineDate("2026-10-25T17:00:00", timeZone: "Europe/Brussels"))
        #expect(deadline == Sample.date("2026-10-25T16:00:00"))
        let summer = try #require(TargetRules.deadlineDate("2026-10-24T17:00:00", timeZone: "Europe/Brussels"))
        #expect(summer == Sample.date("2026-10-24T15:00:00"))
        #expect(TargetRules.isPastDeadline("2026-10-25T17:00:00", timeZone: "Europe/Brussels", now: Sample.date("2026-10-25T15:30:00")) == false)
        #expect(TargetRules.isPastDeadline("2026-10-25T17:00:00", timeZone: "Europe/Brussels", now: Sample.date("2026-10-25T16:00:00")) == true)
        // 25 October plus 14 days stays 8 November at the same local time
        #expect(TargetRules.deadline(released: Sample.date("2026-10-25T00:00:00"), days: 14, time: "17:00") == "2026-11-08T17:00:00")
    }

    @Test("A Mac without a time zone: past the deadline in this Mac’s zone")
    func macWithoutZone() {
        #expect(TargetRules.isPastDeadline("2026-01-01T00:00:00", timeZone: nil, now: Sample.date("2026-11-09T12:00:00")) == true)
        #expect(TargetRules.isPastDeadline("2027-01-01T00:00:00", timeZone: nil, now: Sample.date("2026-11-09T12:00:00")) == false)
        let target = TargetRules.target(os: "26.7.1", model: "Mac14,2", boardID: nil, osName: "macOS", context: .init(
            block: TargetRulesTests.block(.specific(targetOSVersion: "27.1", targetLocalDateTime: "2026-11-01T17:00:00", detailsURL: nil)),
            catalog: TargetRulesTests.catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil, now: Sample.date("2026-11-09T12:00:00")))
        let mac = Sample.classify(Sample.mac(os: "26.7.1"), Sample.status([("device.operating-system.version", "26.7.1")]), target: target)
        #expect(mac.timeZone == nil)
        #expect(mac.pastDeadline == true)
    }
}
