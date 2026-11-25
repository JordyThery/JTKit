import Foundation
import JTKit
import PDFKit
import Testing
@testable import JTKit

private func inspect(_ member: JamfPro.GroupMember, _ status: JamfPro.SoftwareUpdateStatus) -> InspectResult {
    InspectFindings.evaluate(InspectInput(member: member, status: status, device: Sample.classify(member, status),
                                          platformDeviceID: "P-1", reports: []),
                             context: InspectContext(blueprintID: "6a2f0000-1111-4000-8000-00000000c0de", target: nil,
                                                     since: nil, now: Sample.now, serverTimeZone: Sample.utc))
}

@Suite("0.3 fixes: battery, Help links, hardware")
struct ReleaseFixLogicTests {

    @Test("Minor updates: a release Apple ships to other models only doesn’t make a device hardware to replace")
    func otherModelsOnly() {
        // 27.2.1 is for iPad15,8 only; iPad14,8 gets 27.2, the newest Apple ships for it
        let block = TargetRulesTests.block(.semantic(minorEnforceAfterDays: 7, deploymentTime: "23:59"))
        let target = TargetRules.target(os: "27.0.1", model: "iPad14,8", boardID: "iPad14,8", osName: "iPadOS", context: .init(
            block: block, catalog: MovedOnStepTests.catalog, platform: .iOS, blueprintChanged: nil, updateStarted: nil,
            now: MovedOnStepTests.now))
        #expect(target.version == "27.2" && !target.limitedByHardware)
        #expect(target.source == "From Apple’s data and the Blueprint’s rule")
        let device = Sample.classify(Sample.iPad(os: "27.0.1", model: "iPad14,8"), nil, target: target)
        #expect(Replacement.list([device]) { _ in "27.2" }.isEmpty)
    }
}

@Suite("0.3 fixes: diagnoses from the snapshot")
struct SnapshotDiagnosisTests {
    @Test("An OS too old for update declarations: in Readiness, and the diagnosis when Apple has a newer version for the model")
    func tooOld() {
        let status = Sample.status([("device.operating-system.version", "16.7.10")])
        let iPad = Sample.iPad(os: "16.7.10", model: "iPad13,18")
        let device = Sample.classify(iPad, status, target: DeviceTarget(version: "16.7.12", reason: "Made up"))
        #expect(device.diagnosis == "iPadOS 16.7.10 is too old for update declarations (Apple’s start at iOS and iPadOS 17): update it another way first")
        #expect(device.needsAttention && ReadinessCheck.osTooOld.applies(to: device))
        // a Mac on 13; one on 14 or an iPad on 17 is fine
        let mac = Sample.classify(Sample.mac(os: "13.7.8"), Sample.status([("device.operating-system.version", "13.7.8")]),
                                  target: DeviceTarget(version: "13.7.9", reason: "Made up"))
        #expect(mac.diagnosis.hasPrefix("macOS 13.7.8 is too old for update declarations (Apple’s start at macOS 14)"))
        #expect(!ReadinessCheck.osTooOld.applies(to: Sample.classify(Sample.mac(os: "14.0"), nil)))
        #expect(!ReadinessCheck.osTooOld.applies(to: Sample.classify(Sample.iPad(os: "17.0"), nil)))
        // without a newer version from Apple's data: counted in Readiness, diagnosis as before
        let held = Sample.classify(iPad, status, target: DeviceTarget(version: "16.7.10", reason: "Made up"))
        #expect(!held.diagnosis.contains("too old") && ReadinessCheck.osTooOld.applies(to: held))
    }

    @Test("A download declined over a cellular connection has its own diagnosis")
    func cellular() {
        let device = Sample.classify(Sample.iPad(), Sample.status([
            ("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "none"),
            ("softwareupdate.failure-reason.reason", "Error Domain=SUErrorDomain Code=11 \"Cellular download declined\""),
            ("softwareupdate.failure-reason.timestamp", "2026-11-05T11:00:00")]), context: Sample.context(since: Sample.updateStarted))
        #expect(device.diagnosis == "Download declined over a cellular connection: the device needs Wi-Fi")
        #expect(device.needsAttention)
    }

    @Test("InstallationKeybagRequired or PasscodeLocked since the update started: the passcode has to be entered, also while downloading")
    func passcode() {
        for (state, reason) in [("downloading", "Error Domain=SUErrorDomain Code=8406 \"InstallationKeybagRequired\""),
                                ("downloading", "PasscodeLocked")] {
            let device = Sample.classify(Sample.iPad(), Sample.status([
                ("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", state),
                ("softwareupdate.pending-version.os-version", "27.0.1"),
                ("softwareupdate.failure-reason.reason", reason), ("softwareupdate.failure-reason.timestamp", "2026-11-05T11:00:00")]),
                context: Sample.context(since: Sample.updateStarted))
            #expect(device.diagnosis == "Downloading; the passcode has to be entered to install", "\(reason)")
            #expect(device.needsAttention)
        }
    }
}

/// Progress steps a refresh reported, from any thread.
private final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [RefreshProgress] = []
    func add(_ step: RefreshProgress) { lock.withLock { steps.append(step) } }
    var all: [RefreshProgress] { lock.withLock { steps } }
}
