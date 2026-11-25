import Foundation
import Testing
import JTKit
@testable import JTKit

@Suite("Inspect findings")
struct InspectFindingsTests {
    let blueprint = "6a2f0000-1111-4000-8000-00000000c0de"

    func context() -> InspectContext {
        InspectContext(blueprintID: blueprint, target: OSVersion("27.0.1"), since: Sample.updateStarted, now: Sample.now,
                       serverTimeZone: Sample.utc, majors: [27, 26, 18],
                       supports: { model, _, major in model == "iPad7,5" ? major < 27 : true })
    }

    func row(_ category: StatusCategory = .notStarted, _ diagnosis: String = "Online, update not started (no error)") -> DeviceStatus {
        Sample.classify(Sample.iPad(), Sample.status([("device.operating-system.version", "26.7.1")]))
            .with(category: category, diagnosis: diagnosis)
    }

    func report(_ step: Int, _ type: String, active: Bool, status: String = "SUCCESSFUL",
                reasons: [JamfPlatform.DeclarationReport.Reason] = []) -> JamfPlatform.DeclarationReport {
        JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_\(blueprint)_s\(step)_c1_sys_x", type: type,
                                       status: .init(status), active: active, validity: .valid, reasons: reasons)
    }

    func evaluate(_ member: JamfPro.GroupMember = Sample.iPad(), status: JamfPro.SoftwareUpdateStatus? = nil,
                  row: DeviceStatus? = nil, reports: [JamfPlatform.DeclarationReport]? = [], platformID: String? = "P-1") -> InspectResult {
        InspectFindings.evaluate(InspectInput(member: member, status: status, device: row ?? self.row(),
                                              platformDeviceID: platformID, reports: reports), context: context())
    }

    @Test("The first finding is the likely cause; every finding is listed")
    func ordering() {
        var member = Sample.iPad()
        member.supervised = false
        member.appleEnrollmentType = "user"
        member.availableSpaceMB = 2_100
        member.batteryLevel = 25
        // downloaded, waiting to install: the battery matters
        let result = evaluate(member, status: Sample.status([("device.operating-system.version", "26.7.1"),
                                                             ("softwareupdate.install-state", "prepared")]))
        #expect(result.cause == "User Enrollment")
        let all = result.findings.map { "\($0.cause): \($0.detail)" }
        #expect(all.contains("Low storage: 2.1 GB free of 62.5 GB"))
        #expect(all.contains("Battery under the automatic minimum: 25% at the last inventory: an automatic install may wait for charging (Apple asks for 30% on iPhone and iPad)"))
    }

    @Test("A failed download: the device's own error is the likely cause, and low battery isn't listed for a download")
    func downloadErrorFirst() {
        var member = Sample.iPad()
        member.batteryLevel = 18
        member.availableSpaceMB = 2_100
        let status = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "failed"),
                                    ("softwareupdate.failure-reason.reason", "DownloadFailed: The network connection was lost."),
                                    ("softwareupdate.failure-reason.count", "3"),
                                    ("softwareupdate.failure-reason.timestamp", "2026-11-05T09:30:00")])
        // the Blueprint's declaration is on the device and active: nothing about it to find
        let declared = [report(1, "CONFIGURATION", active: true)]
        let result = evaluate(member, status: status, row: row(.failed, "Download problem (device retries)"), reports: declared)
        #expect(result.cause == "Update error")
        #expect(result.detail.hasPrefix("DownloadFailed: The network connection was lost."))
        #expect(!result.findings.contains { $0.cause == "Low battery" })
        // the hints from the inventory still follow it
        #expect(result.findings.contains { $0.cause == "Low storage" })
        // the same device installing: then the battery counts
        let installing = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "installing")])
        #expect(evaluate(member, status: installing, row: row(.inProgress, "Installing now"), reports: declared)
            .findings.contains { $0.cause == "Low battery" })
    }

    @Test("A device on target needs no cause")
    func onTarget() {
        let result = evaluate(row: row(.onTarget, "On target"))
        #expect(result.cause == "On target")
        #expect(result.detail == "Already on the target version")
    }

    @Test("The active declaration is judged; an Error.* code is a failure, named by Blueprint and versions")
    func activeBlock() {
        let problem = JamfPlatform.DeclarationReport.Reason(code: "Error.ConfigurationAlreadyPresent", description: "another is present")
        let result = evaluate(reports: [report(1, "ACTIVATION", active: true), report(1, "CONFIGURATION", active: true, reasons: [problem]),
                                        report(2, "ACTIVATION", active: false, status: "UNSUCCESSFUL"),
                                        report(2, "CONFIGURATION", active: false)])
        #expect(result.cause == "Update declaration failed")
        #expect(result.detail == "The Blueprint, iPadOS 26 (applies to this device): Error.ConfigurationAlreadyPresent (another is present)")
    }

    @Test("Several active declarations, or none, are findings of their own")
    func blocks() {
        let several = evaluate(reports: [report(1, "ACTIVATION", active: true), report(2, "ACTIVATION", active: true)])
        #expect(several.cause == "Several update declarations active")
        #expect(several.detail.hasSuffix("all apply to iPadOS 26.7.1"))
        let none = evaluate(reports: [report(1, "ACTIVATION", active: false), report(2, "ACTIVATION", active: false)])
        #expect(none.cause == "No update declaration applies")
    }

    @Test("Declarations without activations: pending ones and none active")
    func withoutActivations() {
        let result = evaluate(reports: [report(1, "CONFIGURATION", active: false, status: "PENDING")])
        #expect(result.findings.map(\.cause).prefix(2) == ["Update declarations not applied yet", "No update declaration applies"])
    }

    @Test("Where the declaration report couldn’t be had")
    func reportMissing() {
        #expect(evaluate(reports: nil, platformID: nil).cause == "Not in the Platform device list")
        let refused = InspectFindings.evaluate(InspectInput(member: Sample.iPad(), device: row(), platformDeviceID: "P-1",
                                                            reports: nil, reportsProblem: "HTTP 403"), context: context())
        #expect(refused.cause == "Declaration report not available")
        #expect(refused.detail == "HTTP 403 (the API client needs declarations:read)")
        #expect(evaluate(reports: []).cause == "Update Blueprint not on the device")
    }

    @Test("Hardware that can’t run the next version")
    func nextVersion() {
        let result = evaluate(Sample.iPad(os: "18.7.10", model: "iPad7,5"), reports: [report(1, "CONFIGURATION", active: true)],
                              platformID: "P-1")
        #expect(result.findings.contains(Finding(cause: "Hardware can’t run the next version", detail: "iPad7,5 isn’t supported by iPadOS 26")) == false)
        let older = InspectFindings.evaluate(InspectInput(member: Sample.iPad(os: "26.7.1", model: "iPad7,5"), device: nil,
                                                          platformDeviceID: "P-1", reports: [report(1, "CONFIGURATION", active: true)]),
                                             context: context())
        #expect(older.findings.contains(Finding(cause: "Hardware can’t run the next version", detail: "iPad7,5 isn’t supported by iPadOS 27")))
    }

    @Test("A passcode, an error since the update started, and a downloaded update before its deadline")
    func statusFindings() {
        let status = Sample.status([
            ("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "prepared"),
            ("softwareupdate.pending-version.os-version", "27.0.1"),
            ("softwareupdate.failure-reason", #"{count=2, reason=Error Domain=x Code=8406 "InstallationKeybagRequired", timestamp=2026-11-05T09:30:00}"#),
            ("passcode.is-present", "true")], time: "2026-11-05T06:00:00")
        let result = evaluate(status: status, row: row(.inProgress, "Downloaded, install blocked by the passcode"),
                              reports: [report(1, "CONFIGURATION", active: true)])
        let all = result.findings.map { "\($0.cause): \($0.detail)" }
        #expect(all.contains("Passcode: Passcode present: yes; the update installs once the passcode is entered on the device, or after it’s cleared"))
        #expect(all.contains("Update error: InstallationKeybagRequired (2 failures, last \(InspectFindings.moment(Sample.date("2026-11-05T09:30:00"))))"))
        // prepared before the deadline is normal, not stuck
        #expect(all.contains("Update downloaded: iPadOS 27.0.1 is downloaded and installs at the deadline"))
        #expect(!all.contains { $0.hasPrefix("Update stuck") })
    }

    @Test("Other declarations with a problem, at most three")
    func others() {
        let failed = JamfPlatform.DeclarationReport.Reason(code: "Error.ConfigurationCannotBeApplied")
        let bad = (1...5).map { JamfPlatform.DeclarationReport(declarationIdentifier: "other-\($0)", status: .unsuccessful, reasons: [failed]) }
        let result = evaluate(reports: [report(1, "CONFIGURATION", active: true)] + bad)
        #expect(result.findings.filter { $0.cause == "Other declaration with a problem" }.count == 3)
        // a declaration of another Blueprint that isn’t for this device isn’t a problem
        let predicate = JamfPlatform.DeclarationReport.Reason(code: "Info.Predicate")
        let elsewhere = [JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_7b1e0000-2222-4000-8000-00000000beef_s1_c1_sys_act4",
                                                        type: "ACTIVATION", status: .unsuccessful, reasons: [predicate]),
                         JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_7b1e0000-2222-4000-8000-00000000beef_s1_c1_sys_cfg4",
                                                        type: "CONFIGURATION", status: .unsuccessful,
                                                        reasons: [.init(code: "Error.ActivationFailed")])]
        #expect(!evaluate(reports: [report(1, "CONFIGURATION", active: true)] + elsewhere).findings
            .contains { $0.cause == "Other declaration with a problem" })
    }

    @Test("Inspect’s default selection: by serial, by diagnosis, else who needs attention")
    func selection() {
        let devices = [row(.onTarget, "On target"), row(), row(.inProgress, "Downloading")]
            .enumerated().map { $0.element.with(serial: "ZZTEST\($0.offset)") }
        #expect(InspectWorkflow.select(devices, serials: ["zztest2"]).map(\.serial) == ["ZZTEST2"])
        #expect(InspectWorkflow.select(devices, diagnosis: "download").map(\.serial) == ["ZZTEST2"])
        #expect(InspectWorkflow.select(devices).map(\.serial) == ["ZZTEST1"])
    }
}

extension DeviceStatus {
    func with(category: StatusCategory? = nil, diagnosis: String? = nil, serial: String? = nil) -> DeviceStatus {
        var copy = self
        if let category { copy.category = category }
        if let diagnosis { copy.diagnosis = diagnosis }
        if let serial { copy.serial = serial }
        return copy
    }
}
