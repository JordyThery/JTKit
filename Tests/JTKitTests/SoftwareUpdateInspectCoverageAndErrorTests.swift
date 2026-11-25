import Foundation
import Testing
import JTKit
@testable import JTKit

/// Inspect: ranges Jamf hasn’t extended, the device’s own OS family,
/// awaiting sync, and errors from before the update started. Made-up devices.
@Suite("Inspect: coverage, awaiting sync and earlier errors")
struct InspectCoverageAndErrorTests {
    let blueprint = "6a2f0000-1111-4000-8000-00000000c0de"

    func pair(_ number: Int, family: String = "macOS", versions: String, lists: [String],
              status: JamfPlatform.DeclarationReport.Status = .unsuccessful) -> [JamfPlatform.DeclarationReport] {
        let predicate = #"status.device.operating-system.family == "\#(family)" AND status.device.operating-system.version MATCHES "\#(versions)" AND status.softwareupdate.device-id IN {\#(lists.map { "\"\($0)\"" }.joined(separator: ", "))}"#
        return [
            JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_\(blueprint)_s1_c1_sys_act\(number)", type: "ACTIVATION",
                                           status: status, active: false, validity: .valid,
                                           reasons: [.init(code: "Info.Predicate", details: [.init(key: "Predicate", description: predicate)])],
                                           lastReportTime: Sample.date("2026-11-05T09:00:00")),
            JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_\(blueprint)_s1_c1_sys_cfg\(number)", type: "CONFIGURATION",
                                           status: .unsuccessful, active: false, reasons: [.init(code: "Error.ActivationFailed")],
                                           lastReportTime: Sample.date("2026-11-05T09:00:00")),
        ]
    }

    func evaluate(_ member: JamfPro.GroupMember, status: JamfPro.SoftwareUpdateStatus,
                  reports: [JamfPlatform.DeclarationReport]) -> InspectResult {
        InspectFindings.evaluate(InspectInput(member: member, status: status, device: Sample.classify(member, status),
                                              platformDeviceID: "P-1", reports: reports),
                                 context: InspectContext(blueprintID: blueprint, blueprintName: "Test Mac Updates", target: OSVersion("26.7.3"),
                                                         since: Sample.updateStarted, now: Sample.now, serverTimeZone: Sample.utc))
    }

    static let mac = Sample.mac(os: "26.7.2", model: "MacBookPro18,3")
    static let status = Sample.status([("device.operating-system.version", "26.7.2"), ("softwareupdate.device-id", "J314sAP")])
    // the form Jamf sends: 26.0 to 26.7.1
    static let below = "^(26[.][0-6]([.][0-9]+)*|26[.]7([.][0-1]([.][0-9]+)*)?)$"

    @Test("Every range for this hardware ends below its version: Jamf’s update doesn’t cover it yet")
    func notCoveredYet() throws {
        let result = evaluate(Self.mac, status: Self.status, reports: pair(12, versions: Self.below, lists: ["J314sAP"]))
        #expect(result.cause == "Jamf’s update doesn’t cover macOS 26.7.2 yet")
        // said with the date of the report it is based on: Jamf can widen the ranges later
        #expect(result.detail.hasPrefix("When the device last reported, on \(InspectFindings.day(Sample.date("2026-11-05T09:00:00"))), the"))
        #expect(result.detail.contains("covered macOS 26.0 to 26.7.1, not 26.7.2"))
    }

    @Test("A device on target lists no declaration that doesn’t apply")
    func onTargetListsNothing() {
        let status = Sample.status([("device.operating-system.version", "26.7.3"), ("softwareupdate.device-id", "J314sAP")])
        let mac = Sample.mac(os: "26.7.3", model: "MacBookPro18,3")
        let row = Sample.classify(mac, status).with(category: .onTarget, diagnosis: "On target")
        let result = InspectFindings.evaluate(
            InspectInput(member: mac, status: status, device: row, platformDeviceID: "P-1",
                         reports: pair(12, versions: Self.below, lists: ["J314sAP"])),
            context: InspectContext(blueprintID: blueprint, target: OSVersion("26.7.3"), since: Sample.updateStarted,
                                    now: Sample.now, serverTimeZone: Sample.utc))
        #expect(result.cause == "On target")
        #expect(!result.findings.contains { $0.cause == "No update declaration applies" || $0.cause.hasPrefix("Jamf’s update doesn’t cover") })
    }

    @Test("Only the declarations for the device’s own OS are counted")
    func ownFamily() throws {
        let reports = pair(1, family: "iOS", versions: "^(27[.][0-1]([.][0-9]+)*)$", lists: ["iPhone15,2"])
            + pair(5, family: "iPadOS", versions: "^(27[.][0-1]([.][0-9]+)*)$", lists: ["iPad14,8"])
            + pair(12, versions: Self.below, lists: ["J416sAP"])
        let finding = try #require(evaluate(Self.mac, status: Self.status, reports: reports).findings
            .first { $0.cause == "No update declaration applies" })
        #expect(finding.detail.hasPrefix("None of Test Mac Updates’s 1 update declaration for macOS applies to macOS 26.7.2."))
        #expect(finding.detail.hasSuffix("No declaration lists J314sAP, so the Blueprint doesn’t cover this hardware."))
    }

    @Test("A declaration awaiting sync: Jamf sent it again and the device hasn’t fetched it")
    func awaitingSync() throws {
        let reports = pair(12, versions: Self.below, lists: ["J314sAP"], status: .awaitingSync)
        let finding = try #require(evaluate(Self.mac, status: Self.status, reports: reports).findings
            .first { $0.cause == "New declaration not fetched yet" })
        #expect(finding.detail.contains("awaiting sync") && finding.detail.contains("Test Mac Updates, macOS 26.0 to 26.7.1"))
    }

    @Test("An error from before the update started is listed, never the likely cause")
    func earlierError() throws {
        let status = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "prepared"),
                                    ("softwareupdate.pending-version.os-version", "26.7.2"),
                                    ("softwareupdate.failure-reason.reason", "Software update failed."),
                                    ("softwareupdate.failure-reason.timestamp", "2026-10-13T09:15:00")])
        let mac = Sample.mac(os: "26.7.1", model: "MacBookPro18,3")
        let result = evaluate(mac, status: status, reports: pair(12, versions: "^(26[.][0-7]([.][0-9]+)*)$", lists: ["J314sAP"]))
        #expect(result.cause != "Earlier update error" && result.cause != "Update error")
        let earlier = try #require(result.alsoFound.first { $0.cause == "Earlier update error" })
        #expect(earlier.earlier == true && earlier.detail.hasSuffix("before the update started)"))
        // nothing else found: still not the likely cause
        let alone = InspectResult(id: "x", name: "", serial: "", modelIdentifier: "", os: "", diagnosis: "", onTarget: false,
                                  findings: [earlier])
        #expect(alone.cause == "No cause found" && alone.alsoFound == [earlier])
    }

    @Test("The bootstrap token: the likely cause only for an error since the update started")
    func bootstrap() throws {
        var mac = Sample.mac(os: "26.7.1", model: "Mac14,2")
        mac.bootstrapTokenEscrowedStatus = "ESCROWED"
        func status(_ time: String) -> JamfPro.SoftwareUpdateStatus {
            Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "prepared"),
                           ("softwareupdate.pending-version.os-version", "27.0.1"),
                           ("softwareupdate.failure-reason.reason", "Update failed due to failure to get Bootstrap Token."),
                           ("softwareupdate.failure-reason.timestamp", time)])
        }
        // from 13 Oct, before the update started on 1 Nov: Also Found, never the likely cause
        let old = evaluate(mac, status: status("2026-10-13T09:15:00"), reports: [])
        #expect(old.cause != "Bootstrap token")
        let earlier = try #require(old.alsoFound.first { $0.cause == "Earlier bootstrap token error" })
        #expect(earlier.detail.hasSuffix("Jamf Pro now reports the token as escrowed"))
        // since the update started, with the token escrowed: the likely cause, without contradicting itself
        let current = evaluate(mac, status: status("2026-11-05T09:00:00"), reports: [])
        #expect(current.cause == "Bootstrap token")
        #expect(current.detail.contains("although Jamf Pro reports it as escrowed"))
        #expect(!current.detail.contains("Without an escrowed"))
    }
}
