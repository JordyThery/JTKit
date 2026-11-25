import Foundation
import Testing
import JTKit
@testable import JTKit

/// Each software update setting of Jamf’s reference, with and without a
/// delay, against a made-up release history and a fixed “now”.
@Suite("Targets per device")
struct TargetRulesTests {
    static let sofaMacOS = #"""
    {"OSVersions":[
      {"OSVersion":"Golden Gate 27","Latest":{"ProductVersion":"27.2","Build":"26C100","ReleaseDate":"2026-10-26T00:00:00Z","SupportedDevices":["J413AP"]},
       "SecurityReleases":[{"ProductVersion":"27.2","Build":"26C100","ReleaseDate":"2026-10-26T00:00:00Z"},
                           {"ProductVersion":"27.1","Build":"26B100","ReleaseDate":"2026-09-30T00:00:00Z"}]},
      {"OSVersion":"Tahoe 26","Latest":{"ProductVersion":"26.7.2","Build":"25H200","ReleaseDate":"2026-10-26T00:00:00Z","SupportedDevices":["J413AP"]},
       "SecurityReleases":[{"ProductVersion":"26.7.2","Build":"25H200","ReleaseDate":"2026-10-26T00:00:00Z"},
                           {"ProductVersion":"26.7.1","Build":"25H100","ReleaseDate":"2026-09-30T00:00:00Z"}]},
      {"OSVersion":"Sequoia 15","Latest":{"ProductVersion":"15.8.2","Build":"24J200","ReleaseDate":"2026-10-26T00:00:00Z","SupportedDevices":["J413AP","J132AP"]},
       "SecurityReleases":[{"ProductVersion":"15.8.2","Build":"24J200","ReleaseDate":"2026-10-26T00:00:00Z"}]}],
     "Models":{"Mac14,2":{"MarketingName":"MacBook Air (M2)","OSVersions":[27,26,15]},
               "MacBookPro15,2":{"MarketingName":"MacBook Pro (2018)","OSVersions":[15,14]},
               "MacOld1,1":{"MarketingName":"An old Mac","OSVersions":[11]}},
     "Devices":{"J413AP":{"DeviceID":"Mac14,2"},"J132AP":{"DeviceID":"MacBookPro15,2"}}}
    """#

    static let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(sofaMacOS.utf8))
    static let blueprintChanged = Sample.date("2026-10-01T09:00:00")

    static func block(_ enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement, build: String? = nil,
                      source: JamfPlatform.SoftwareUpdateBlock.Source = .component) -> JamfPlatform.SoftwareUpdateBlock {
        JamfPlatform.SoftwareUpdateBlock(stepIndex: 0, componentIndex: 0, enforcement: enforcement, targetBuildVersion: build, source: source)
    }

    static func target(_ enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement, os: String, model: String = "Mac14,2",
                       now: String = "2026-11-09T12:00:00", build: String? = nil, catalog: AppleReleases.Catalog? = catalog,
                       updateStarted: Date? = nil, source: JamfPlatform.SoftwareUpdateBlock.Source = .component) -> DeviceTarget {
        TargetRules.target(os: os, model: model, boardID: nil, osName: "macOS", context: .init(
            block: block(enforcement, build: build, source: source), catalog: catalog, platform: .macOS,
            blueprintChanged: blueprintChanged, updateStarted: updateStarted, now: Sample.date(now)))
    }

    // MARK: Specific version

    @Test("A specific version: the same target for every device, from the Blueprint’s last change")
    func specific() {
        let target = Self.target(.specific(targetOSVersion: "27.1", targetLocalDateTime: "2026-11-20T17:00:00", detailsURL: nil), os: "26.7.1")
        #expect(target.version == "27.1")
        #expect(target.build == "26B100")
        #expect(target.deadlineLocal == "2026-11-20T17:00:00")
        #expect(target.activityFrom == Self.blueprintChanged)
        #expect(!target.noApplicableRelease && !target.limitedByHardware)
        #expect(target.reason.hasPrefix("The Blueprint asks for macOS 27.1 by"))
    }

    @Test("A specific version a model can’t run: no applicable release, so unsupported")
    func specificUnsupported() {
        let target = Self.target(.specific(targetOSVersion: "27.1", targetLocalDateTime: nil, detailsURL: nil), os: "15.8.2", model: "MacBookPro15,2")
        #expect(target.noApplicableRelease)
        let device = Sample.classify(Sample.mac(os: "15.8.2", model: "MacBookPro15,2"),
                                     Sample.status([("device.operating-system.version", "15.8.2")]), target: target)
        #expect(device.category == .unsupported)
        // a Mac already beyond the version is on target
        let newer = Sample.classify(Sample.mac(os: "27.2"), Sample.status([("device.operating-system.version", "27.2")]),
                                    target: Self.target(.specific(targetOSVersion: "27.1", targetLocalDateTime: nil, detailsURL: nil), os: "27.2"))
        #expect(newer.category == .onTarget)
    }

    @Test("Apple’s own declaration: a specific version with its build")
    func appleDeclaration() {
        let target = Self.target(.specific(targetOSVersion: "27.1", targetLocalDateTime: "2026-11-20T17:00:00", detailsURL: nil),
                                 os: "27.0", build: "26B999", source: .customDeclaration)
        #expect(target.version == "27.1" && target.build == "26B999")
    }

    // MARK: Latest

    @Test("Latest without delay: the newest release, across majors, from its release date")
    func latestNoDelay() {
        let target = Self.target(.latest(enforceAfterDays: 0, deploymentTime: "18:00"), os: "26.7.1")
        #expect(target.version == "27.2")
        #expect(target.released == Sample.date("2026-10-26T00:00:00"))
        #expect(target.activityFrom == Sample.date("2026-10-26T00:00:00"))
        #expect(target.deadlineLocal == "2026-10-26T18:00:00")
        #expect(target.reason == "The newest public macOS release: 27.2; installs by \(TargetRules.day(target.deadlineLocal ?? ""))")
    }

    @Test("Latest with a delay: the newest public release from the day it’s out, due that many days later", arguments: [
        // the day before 27.2: 27.1, due 14 days after its own release
        ("2026-10-25T23:00:00", "27.1", "2026-10-14T16:00:00"),
        // the day after: 27.2 at once, due on 9 Nov
        ("2026-10-27T00:00:00", "27.2", "2026-11-09T16:00:00"),
        ("2026-11-09T00:00:00", "27.2", "2026-11-09T16:00:00"),
    ])
    func latestWithDelay(now: String, version: String, deadline: String) {
        let target = Self.target(.latest(enforceAfterDays: 14, deploymentTime: "16:00"), os: "26.7.1", now: now)
        #expect(target.version == version)
        #expect(target.deadlineLocal == deadline)
    }

    @Test("Latest on hardware that can’t run the newest major: the newest it can run, noted")
    func latestLimited() {
        let target = Self.target(.latest(enforceAfterDays: 0, deploymentTime: nil), os: "15.7.0", model: "MacBookPro15,2")
        #expect(target.version == "15.8.2")
        #expect(target.limitedByHardware && !target.noApplicableRelease)
        #expect(target.reason.contains("the newest this model can run; it can’t run macOS 27"))
    }

    @Test("Latest with no release the model can run: unsupported")
    func latestNothing() {
        let target = Self.target(.latest(enforceAfterDays: 0, deploymentTime: nil), os: "11.7", model: "MacOld1,1")
        #expect(target.version == nil && target.noApplicableRelease)
        let device = Sample.classify(Sample.mac(os: "11.7", model: "MacOld1,1"), Sample.status([("device.operating-system.version", "11.7")]),
                                     target: target)
        #expect(device.category == .unsupported)
        #expect(device.diagnosis == "No macOS release this hardware can run")
    }

    // MARK: Minor updates

    @Test("Minor updates: the newest release of the device’s own major, not the newest major")
    func minor() {
        // the example: a Mac on 26.7.1 is judged against 26.7.2, not 27.2
        let target = Self.target(.semantic(minorEnforceAfterDays: 14, deploymentTime: "18:00"), os: "26.7.1")
        #expect(target.version == "26.7.2")
        #expect(target.deadlineLocal == "2026-11-09T18:00:00")
        #expect(target.reason == "The newest public macOS 26 release: 26.7.2; installs by \(TargetRules.day(target.deadlineLocal ?? ""))")
        #expect(Self.target(.semantic(minorEnforceAfterDays: 14, deploymentTime: nil), os: "27.0").version == "27.2")
    }

    @Test("Minor updates with a delay not yet passed: the new release already, due later; before it’s out, none newer")
    func minorWithDelay() {
        let target = Self.target(.semantic(minorEnforceAfterDays: 14, deploymentTime: "18:00"), os: "26.7.1", now: "2026-11-08T12:00:00")
        #expect(target.version == "26.7.2")
        #expect(target.deadlineLocal == "2026-11-09T18:00:00")
        #expect(target.activityFrom == Sample.date("2026-10-26T00:00:00"))
        // before 26.7.2 is out, the Mac on 26.7.1 is already on the newest public release
        let before = Self.target(.semantic(minorEnforceAfterDays: 14, deploymentTime: "18:00"), os: "26.7.1", now: "2026-10-25T12:00:00")
        #expect(before.version == "26.7.1")
    }

    @Test("Minor updates without delay")
    func minorNoDelay() {
        #expect(Self.target(.semantic(minorEnforceAfterDays: 0, deploymentTime: nil), os: "26.7.1", now: "2026-10-26T01:00:00").version == "26.7.2")
    }

    @Test("Minor updates on hardware that stops at an older major: its own major, not marked (it runs what the rule gives)")
    func minorLimited() {
        let target = Self.target(.semantic(minorEnforceAfterDays: 14, deploymentTime: nil), os: "15.8.2", model: "MacBookPro15,2")
        #expect(target.version == "15.8.2" && !target.limitedByHardware)
    }

    @Test("Minor updates without releases of the device’s major, or without Apple’s data")
    func minorUnknown() {
        #expect(Self.target(.semantic(minorEnforceAfterDays: 14, deploymentTime: nil), os: "14.8.9").version == nil)
        let noData = Self.target(.semantic(minorEnforceAfterDays: 14, deploymentTime: nil), os: "26.7.1", catalog: nil)
        #expect(noData.version == nil && noData.reason.contains("Apple’s release data couldn’t be read"))
    }

    // MARK: Start and deadline

    @Test("“Update started” set by hand overrides the computed start, for every setting")
    func updateStarted() {
        let started = Sample.date("2026-11-02T08:00:00")
        for enforcement in [JamfPlatform.SoftwareUpdateBlock.Enforcement.semantic(minorEnforceAfterDays: 14, deploymentTime: nil),
                            .latest(enforceAfterDays: 0, deploymentTime: nil),
                            .specific(targetOSVersion: "27.1", targetLocalDateTime: nil, detailsURL: nil)] {
            let target = Self.target(enforcement, os: "26.7.1", updateStarted: started)
            #expect(target.activityFrom == started && target.startSetByHand)
        }
    }

    @Test("Activity counts from the release date; the deadline from the release date plus the delay")
    func activityAndDeadline() {
        let target = Self.target(.semantic(minorEnforceAfterDays: 14, deploymentTime: "18:00"), os: "26.7.1")
        // a report after the release but before the deadline counts
        let reported = Sample.classify(Sample.mac(os: "26.7.1"), Sample.status([("device.operating-system.version", "26.7.1"),
                                                                                  ("softwareupdate.install-state", "downloading")],
                                                                                 time: "2026-10-30T10:00:00"),
                                       target: target, now: "2026-11-09T12:00:00")
        #expect(reported.category == .inProgress)
        // a report from before the release doesn't
        let quiet = Sample.classify(Sample.mac(os: "26.7.1"), Sample.status([("device.operating-system.version", "26.7.1")],
                                                                              time: "2026-10-20T10:00:00"),
                                    target: target, now: "2026-11-09T12:00:00")
        #expect(quiet.category == .noActivity)
        #expect(reported.deadlineLocal == "2026-11-09T18:00:00")
    }

    @Test("Past the deadline: in the device’s own zone")
    func pastDeadline() {
        #expect(TargetRules.isPastDeadline("2026-11-09T18:00:00", timeZone: "Asia/Tokyo", now: Sample.date("2026-11-09T10:00:00")) == true)
        #expect(TargetRules.isPastDeadline("2026-11-09T18:00:00", timeZone: "America/New_York", now: Sample.date("2026-11-09T10:00:00")) == false)
        #expect(TargetRules.isPastDeadline(nil, timeZone: "UTC", now: Date()) == nil)
        #expect(TargetRules.deadline(released: Sample.date("2026-10-26T00:00:00"), days: 14, time: "7:00") == "2026-11-09T00:00:00")
    }

    @Test("A Blueprint without a software update gives no target")
    func none() {
        let target = TargetRules.target(os: "26.7.1", model: "Mac14,2", boardID: nil, osName: "macOS",
                                        context: .init(block: nil, catalog: Self.catalog, platform: .macOS, blueprintChanged: nil,
                                                       updateStarted: nil, now: Date()))
        #expect(target.version == nil && !target.noApplicableRelease)
    }
}
