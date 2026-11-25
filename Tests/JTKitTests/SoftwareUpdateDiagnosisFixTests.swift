import Foundation
import JTKit
import Testing
@testable import JTKit

/// 0.3.2: installing without contact since, readiness counted once, the
/// current declaration from its newest report, two plain error diagnoses,
/// and the server time zone check. Made-up devices and IDs, shaped like
/// what the live tenant showed on 11, 24 and 25 Nov.
@Suite("0.3.2: diagnoses")
struct DiagnosisFixTests {
    static let noContact = ", no contact since (switched off or stuck)"

    static func installing(_ pending: String, since: String) -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "26.7.2"), ("softwareupdate.install-state", "installing"),
                       ("softwareupdate.pending-version.os-version", pending)], time: since)
    }

    static func classify(_ member: JamfPro.GroupMember, _ status: JamfPro.SoftwareUpdateStatus?, target: String = "26.7.3",
                         now: String, zone: TimeZone = Sample.utc) -> DeviceStatus {
        Classifier.classify(DeviceInput(member: member, status: status),
                            context: ClassificationContext(target: OSVersion(target), serverTimeZone: zone, now: Sample.date(now)))
    }

    // MARK: Installing, no contact since

    @Test("Installing since the deadline and no contact since: switched off, or stuck installing; a later check-in still says so")
    func installingWithoutContact() {
        // a Mac that started at the deadline, its last contact the same moment as the report
        var mac = Sample.mac("1", os: "26.7.2", model: "MacBookPro18,3")
        mac.lastContact = Sample.date("2026-11-23T22:59:58")
        let report = Self.installing("26.7.3", since: "2026-11-23T22:59:58")
        let device = Self.classify(mac, report, now: "2026-11-24T06:33:00")
        #expect(device.diagnosis == "Installing since \(InspectFindings.dayTime(Sample.date("2026-11-23T22:59:58")))" + Self.noContact)
        #expect(!device.diagnosis.contains("2026"))
        #expect(device.category == .inProgress && device.needsAttention)
        // an iPad the same since 16 Nov
        let iPad = Sample.iPad("2", os: "27.2", model: "iPad14,8", lastContact: Sample.date("2026-11-16T23:09:42"))
        let iPadReport = Sample.status([("device.operating-system.version", "27.2"), ("softwareupdate.install-state", "installing"),
                                        ("softwareupdate.pending-version.os-version", "27.2.1")], time: "2026-11-16T23:09:42")
        #expect(Self.classify(iPad, iPadReport, target: "27.2.1", now: "2026-11-25T05:04:00").diagnosis.hasSuffix(Self.noContact))
        // a check-in an hour after the report: it checks in but sends nothing new
        mac.lastContact = Sample.date("2026-11-23T23:59:58")
        #expect(Self.classify(mac, report, now: "2026-11-24T06:33:00").diagnosis
                == "Installing 26.7.3 for more than 4 hours; the device checks in but hasn’t reported a new status")
    }

    @Test("A wrong server time zone makes the same report look an hour earlier, so the contact looks later; the check sees it")
    func wrongServerZone() throws {
        let amsterdam = try #require(TimeZone(identifier: "Europe/Amsterdam"))
        var mac = Sample.mac("1", os: "26.7.2", model: "MacBookPro18,3")
        mac.lastContact = Sample.date("2026-11-23T22:59:58")
        let report = Self.installing("26.7.3", since: "2026-11-23T22:59:58")
        #expect(Self.classify(mac, report, now: "2026-11-24T06:33:00", zone: amsterdam).diagnosis.hasSuffix("checks in but hasn’t reported a new status"))
        // three devices whose report and contact are the same moment in UTC
        let samples: [(lastContact: Date?, statusTime: String?)] = [
            (Sample.date("2026-11-23T22:59:58"), "2026-11-23T22:59:58.938"),
            (Sample.date("2026-11-16T23:09:42"), "2026-11-16T23:09:42.316"),
            (Sample.date("2026-11-24T05:02:10"), "2026-11-24T05:02:09.5"),
            // one checked in later, one never reported: neither says anything
            (Sample.date("2026-11-24T08:00:00"), "2026-11-20T10:00:00"),
            (nil, nil),
        ]
        #expect(ServerTimeZoneCheck.looksWrong(samples, zone: amsterdam))
        #expect(!ServerTimeZoneCheck.looksWrong(samples, zone: Sample.utc))
        // two are not enough; times with a zone of their own say nothing
        #expect(!ServerTimeZoneCheck.looksWrong(Array(samples.prefix(2)), zone: amsterdam))
        #expect(!ServerTimeZoneCheck.looksWrong(samples.map { ($0.lastContact, $0.statusTime.map { $0 + "Z" }) }, zone: amsterdam))
        // the setting is right when they line up in it: Amsterdam's local time an hour after UTC
        let local = samples.prefix(3).map { sample in (sample.lastContact?.addingTimeInterval(-3_600), sample.statusTime) }
        #expect(!ServerTimeZoneCheck.looksWrong(local, zone: amsterdam))
        #expect(ServerTimeZoneCheck.warning(zone: "Europe/Amsterdam").contains("looks wrong"))
    }

    // MARK: Readiness

    @Test("Readiness counts a device once, under its most basic reason, in that order")
    func readinessOnce() {
        #expect(ReadinessCheck.allCases == [.osTooOld, .noDeclarativeManagement, .userEnrollment, .macNotSupervised, .neverReported])
        // iPads on iPadOS 13 to 15, without declarative device management, never reported
        let old = ["13.7", "14.8.1", "15.8.4"].enumerated().map { index, os -> DeviceStatus in
            var iPad = Sample.iPad("\(index + 1)", os: os, model: "iPad7,5")
            iPad.ddmEnabled = false
            return Sample.classify(iPad, nil)
        }
        // without declarative device management, user enrolled
        var userEnrolled = Sample.iPad("4")
        userEnrolled.ddmEnabled = false
        userEnrolled.supervised = false
        userEnrolled.deviceOwnershipType = "AccountDrivenUserEnrollment"
        // a Mac that isn't supervised and never reported
        var mac = Sample.mac("5")
        mac.supervised = false
        let devices = old + [Sample.classify(userEnrolled, Sample.status([("device.operating-system.version", "26.7.1")])),
                             Sample.classify(mac, nil)]
        #expect(devices.filter(ReadinessCheck.osTooOld.applies).map(\.jamfID) == ["1", "2", "3"])
        #expect(devices.filter(ReadinessCheck.noDeclarativeManagement.applies).map(\.jamfID) == ["4"])
        #expect(devices.filter(ReadinessCheck.userEnrollment.applies).isEmpty)
        #expect(devices.filter(ReadinessCheck.macNotSupervised.applies).map(\.jamfID) == ["5"])
        #expect(devices.filter(ReadinessCheck.neverReported.applies).isEmpty)
        // every device once: the counts add up to the devices
        #expect(ReadinessCheck.allCases.map { ReadinessCheck.count($0, in: devices) }.reduce(0, +) == devices.count)
        #expect(old.allSatisfy { ReadinessCheck.neverReported.fits($0) && ReadinessCheck.noDeclarativeManagement.fits($0) })
    }

    // MARK: Jamf's current declaration

    static let oldRange = #"status.device.operating-system.family == "macOS" AND status.device.operating-system.version MATCHES "^(26[.][0-6]([.][0-9]+)*|26[.]7([.][0-1]([.][0-9]+)*)?)$" AND status.softwareupdate.device-id IN {"J314sAP"}"#
    static let newRange = #"status.device.operating-system.family == "macOS" AND status.device.operating-system.version MATCHES "^(26[.][0-6]([.][0-9]+)*|26[.]7([.][0-2]([.][0-9]+)*)?)$" AND status.softwareupdate.device-id IN {"J314sAP"}"#

    /// One device’s report of the same declaration (`act12`/`cfg12`), as Jamf last sent it to that device.
    static func pair(_ device: String, predicate: String, updated: String, reported: String) -> [JamfPlatform.DeclarationReport] {
        let id = "Blueprint_\(BlueprintHealthTests.blueprint)_s1_c1_sys_"
        var activation = JamfPlatform.DeclarationReport(declarationIdentifier: id + "act12", deviceID: device, type: "ACTIVATION",
                                                         status: .unsuccessful, active: false,
                                                         reasons: [.init(code: "Info.Predicate", details: [.init(key: "Predicate", description: predicate)])])
        var configuration = JamfPlatform.DeclarationReport(declarationIdentifier: id + "cfg12", deviceID: device, type: "CONFIGURATION",
                                                            status: .unsuccessful, active: false)
        for index in [0, 1] {
            var report = index == 0 ? activation : configuration
            report.dateUpdated = Sample.date(updated)
            report.lastReportTime = Sample.date(reported)
            if index == 0 { activation = report } else { configuration = report }
        }
        return [activation, configuration]
    }

    @Test("A Mac still holding the old range, read first or last: Jamf’s current range covers it, so it hasn’t fetched it yet")
    func currentFromNewestReport() throws {
        // the out-of-date Mac (P-6) holds 26.0 to 26.7.1 from 27 Oct, last reported 3 Nov; the others 26.0 to 26.7.2 from 10 Nov
        let stale = Self.pair("P-6", predicate: Self.oldRange, updated: "2026-10-27T07:18:14", reported: "2026-11-03T08:00:00")
        let others = Self.pair("P-1", predicate: Self.newRange, updated: "2026-11-10T00:56:59", reported: "2026-11-11T07:00:00")
            + Self.pair("P-2", predicate: Self.newRange, updated: "2026-11-10T07:42:31", reported: "2026-11-11T08:00:00")
        let device = BlueprintHealthTests.mac("6", os: "26.7.2")
        for reports in [stale + others, others + stale] {
            let current = BlueprintHealth.catalogue(reports, blocks: [BlueprintHealthTests.block], blueprintName: "Test Mac Updates")
            #expect(current.map(\.range) == ["26.0 to 26.7.2"])
            let found = BlueprintHealth.coverage(device, current: current, reports: stale)
            #expect(found == .notFetched(lastReport: Sample.date("2026-11-03T08:00:00")))
            #expect(found.map { BlueprintHealth.diagnosis($0, device: device) }?.hasPrefix("Hasn’t fetched Jamf’s current declarations yet") == true)
        }
        // once it holds the current range, nothing to say
        let fetched = Self.pair("P-6", predicate: Self.newRange, updated: "2026-11-12T09:00:00", reported: "2026-11-12T09:00:00")
        let current = BlueprintHealth.catalogue(fetched + others, blocks: [BlueprintHealthTests.block], blueprintName: "Test Mac Updates")
        #expect(BlueprintHealth.coverage(device, current: current, reports: fetched) == nil)
        // only the old range anywhere: it doesn't cover 26.7.2
        let only = BlueprintHealth.catalogue(stale, blocks: [BlueprintHealthTests.block], blueprintName: "Test Mac Updates")
        #expect(BlueprintHealth.coverage(device, current: only, reports: stale) == .notCovered("macOS 26.0 to 26.7.1"))
    }

    // MARK: Plain error diagnoses

    static func failed(_ reason: String) -> DeviceStatus {
        Sample.classify(Sample.mac(os: "26.7.2", model: "MacBookPro18,3"), Sample.status([
            ("device.operating-system.version", "26.7.2"), ("softwareupdate.install-state", "failed"),
            ("softwareupdate.pending-version.os-version", "26.7.3"),
            ("softwareupdate.failure-reason.reason", reason), ("softwareupdate.failure-reason.timestamp", "2026-11-05T11:00:00")]),
            context: Sample.context(target: "26.7.3", since: Sample.updateStarted))
    }

}
