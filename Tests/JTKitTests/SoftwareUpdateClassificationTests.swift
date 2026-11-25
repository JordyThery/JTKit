import Foundation
import Testing
import JTKit
@testable import JTKit

@Suite("Classification and diagnosis")
struct ClassificationTests {
    typealias S = Sample

    @Test("On target from the device’s own report, also when newer")
    func onTarget() {
        let device = S.classify(S.iPad(), S.status([("device.operating-system.version", "27.1")]))
        #expect(device.category == .onTarget)
        #expect(device.diagnosis == "On target")
        #expect(device.currentOS == "27.1")
    }

    @Test("No report: offline when stale, otherwise no report; a read problem says so")
    func noReport() {
        #expect(S.classify(S.iPad(lastContact: S.date("2026-09-01T00:00:00")), nil).category == .offline)
        #expect(S.classify(S.iPad(lastContact: nil), nil).category == .offline)
        let device = S.classify(S.iPad(), nil)
        #expect(device.category == .noReport)
        #expect(device.diagnosis == "No update status available")
        let refused = S.classify(S.iPad(), nil, problem: "Missing devices:read")
        #expect(refused.category == .noReport)
        #expect(refused.diagnosis == "Update status couldn’t be read")
        #expect(refused.statusProblem == "Missing devices:read")
    }

    @Test("A device without a last contact but with a recent inventory update isn’t offline")
    func inventoryCountsAsContact() {
        var member = S.iPad(lastContact: nil)
        member.lastInventoryUpdate = S.date("2026-11-05T08:00:00")
        let device = S.classify(member, S.status([("device.operating-system.version", "26.7.1")]))
        #expect(device.category == .notStarted)
        #expect(device.lastContact == S.date("2026-11-05T08:00:00"))
        member.lastInventoryUpdate = S.date("2026-09-01T00:00:00")
        #expect(S.classify(member, S.status([("device.operating-system.version", "26.7.1")])).category == .offline)
    }

    @Test("Hardware that can’t run the target major is unsupported")
    func unsupported() {
        let device = S.classify(S.iPad(model: "iPad7,5"), S.status([("device.operating-system.version", "26.7.1")]))
        #expect(device.category == .unsupported)
        #expect(device.diagnosis == "Hardware can’t run iPadOS 27 (stays on its last supported version)")
        // a model Apple’s data doesn’t know is never called unsupported
        #expect(S.classify(S.iPad(model: "iPad99,9"), S.status([("device.operating-system.version", "26.7.1")])).category == .notStarted)
    }

    @Test("A Mac without a model in its inventory is judged by the board ID of its report")
    func boardID() {
        let device = S.classify(S.mac(os: "15.7.4", model: ""), S.status([
            ("device.operating-system.version", "15.7.4"), ("softwareupdate.device-id", "J132AP")]))
        #expect(device.category == .unsupported)
        #expect(device.modelIdentifier == "J132AP")
        #expect(device.diagnosis == "Hardware can’t run macOS 27 (stays on its last supported version)")
    }

    @Test("Reports from before the update started: no activity")
    func noActivity() {
        let device = S.classify(S.iPad(), S.status([("device.operating-system.version", "26.7.1")], time: "2026-10-01T00:00:00"),
                                context: S.context(since: S.updateStarted))
        #expect(device.category == .noActivity)
        #expect(device.diagnosis == "No report since the update started (switched off or not synced yet)")
    }

    @Test("Status times are read in the Jamf Pro server’s time zone")
    func serverTimeZone() {
        // 00:30 in Brussels is still 31 October in UTC, before the update started
        let status = S.status([("device.operating-system.version", "26.7.1")], time: "2026-11-01T00:30:00")
        let inUTC = S.classify(S.iPad(), status, context: S.context(since: S.updateStarted))
        let inBrussels = S.classify(S.iPad(), status, context: S.context(since: S.updateStarted,
                                                                         serverTimeZone: TimeZone(identifier: "Europe/Brussels")!))
        #expect(inUTC.category == .notStarted)
        #expect(inBrussels.category == .noActivity)
    }

    @Test("Downloading an intermediate version: other update, with its version")
    func otherUpdate() {
        let device = S.classify(S.iPad(os: "18.7.10"), S.status([
            ("device.operating-system.version", "18.7.10"), ("softwareupdate.install-state", "downloading"),
            ("softwareupdate.pending-version.os-version", "26.7.1")]))
        #expect(device.category == .otherUpdate)
        #expect(device.diagnosis == "Downloading (intermediate version 26.7.1)")
    }

    @Test("Downloaded but blocked by the passcode")
    func passcodeBlocked() {
        let device = S.classify(S.iPad(), S.status([
            ("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "prepared"),
            ("softwareupdate.pending-version", "{os-version=27.0.1, build-version=24A5341}"),
            ("softwareupdate.failure-reason.reason", #"Error Domain=SUCoreError Code=8406 "InstallationKeybagRequired""#),
            ("softwareupdate.failure-reason.timestamp", "2026-11-05T11:55:00"),
            ("passcode.is-present", "true")]), context: S.context(since: S.updateStarted))
        #expect(device.category == .inProgress)
        #expect(device.diagnosis == "Downloaded, install blocked by the passcode (it has to be entered to install)")
        #expect(device.needsAttention)
        #expect(device.errorSinceUpdate == true)
        #expect(device.passcodePresent == true)
        #expect(device.error == "InstallationKeybagRequired")
    }

    @Test("Downloaded without a blocker installs at the deadline; installing is said as such")
    func prepared() {
        let prepared = S.classify(S.iPad(), S.status([("device.operating-system.version", "26.7.1"),
                                                      ("softwareupdate.install-state", "prepared"),
                                                      ("softwareupdate.pending-version.os-version", "27.0.1")]))
        #expect(prepared.diagnosis == "Downloaded, installs at the deadline")
        #expect(!prepared.needsAttention)
        let installing = S.classify(S.iPad(), S.status([("device.operating-system.version", "26.7.1"),
                                                        ("softwareupdate.install-state", "installing")]))
        #expect(installing.diagnosis == "Installing now")
    }

    @Test("An error from before the update started doesn’t count")
    func oldError() {
        let device = S.classify(S.iPad(), S.status([
            ("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "none"),
            ("softwareupdate.failure-reason.reason", #"Code=3 "(null)""#),
            ("softwareupdate.failure-reason.timestamp", "2026-10-01T00:00:00")]), context: S.context(since: S.updateStarted))
        #expect(device.category == .notStarted)
        #expect(device.diagnosis == "Online, update not started (no error since the update started)")
        #expect(device.errorSinceUpdate == false)
        #expect(device.error == "No update found")
    }

    @Test("A fresh “(null)” error means no update was offered", arguments: [true, false])
    func noUpdateOffered(sinceKnown: Bool) {
        let device = S.classify(S.iPad(), S.status([
            ("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "none"),
            ("softwareupdate.failure-reason.reason", #"Code=3 "(null)""#),
            ("softwareupdate.failure-reason.timestamp", "2026-11-05T11:00:00")]),
            context: S.context(since: sinceKnown ? S.updateStarted : nil))
        #expect(device.category == .failed)
        #expect(device.diagnosis == "No update offered (check deferrals and compatibility)")
    }

    @Test("Download problems are recognized", arguments: ["not having an extractor", "Download failed", "request timed out", "XPC connection"])
    func downloadProblem(message: String) {
        let device = S.classify(S.iPad(), S.status([
            ("device.operating-system.version", "26.7.1"),
            ("softwareupdate.failure-reason.reason", "Code=1 \"\(message)\""),
            ("softwareupdate.failure-reason.timestamp", "2026-11-05T11:00:00")]))
        #expect(device.diagnosis == "Download problem (device retries)")
    }

    @Test("A failed update of the target, with and without details")
    func failed() {
        let bare = S.classify(S.iPad(), S.status([("device.operating-system.version", "26.7.1"),
                                                  ("softwareupdate.install-state", "failed"),
                                                  ("softwareupdate.pending-version.os-version", "27.0.1")]))
        #expect(bare.category == .failed)
        #expect(bare.diagnosis == "Update failed (no error details)")
        let other = S.classify(S.iPad(), S.status([("device.operating-system.version", "26.7.1"),
                                                   ("softwareupdate.failure-reason.reason", "Something unexpected"),
                                                   ("softwareupdate.failure-reason.timestamp", "2026-11-05T11:00:00")]))
        #expect(other.diagnosis == "Other error: Something unexpected")
    }

    @Test("A device below the oldest maintained major gets the hardware hint")
    func oldMajor() {
        let device = S.classify(S.iPad(os: "17.7.2"), S.status([("device.operating-system.version", "17.7.2")]))
        #expect(device.diagnosis == "On iPadOS 17: check if the hardware supports a newer iPadOS")
        #expect(device.needsAttention)
        // without Apple's data there is no hint
        let unknown = S.classify(S.iPad(os: "17.7.2"), S.status([("device.operating-system.version", "17.7.2")]),
                                 context: S.context(oldestMaintainedMajor: nil))
        #expect(unknown.diagnosis == "Online, update not started (no error)")
    }

    @Test("Without a target version nothing is on target")
    func noTarget() {
        #expect(S.classify(S.iPad(), S.status([("device.operating-system.version", "27.0.1")]), context: S.context(target: nil)).category != .onTarget)
    }

    @Test("The operating system’s name follows the device")
    func osNames() {
        #expect(Classifier.osName(isComputer: false, modelIdentifier: "iPad13,18") == "iPadOS")
        #expect(Classifier.osName(isComputer: false, modelIdentifier: "iPhone17,1") == "iOS")
        #expect(Classifier.osName(isComputer: true, modelIdentifier: "") == "macOS")
    }

    @Test("Short errors: the last code’s text, without its download note")
    func shortErrors() {
        #expect(Classifier.shortError(nil) == "")
        #expect(Classifier.shortError(#"A Code=1 "first" B Code=2 "second (Asset download for x)""#) == "second")
        #expect(Classifier.shortError("plain text") == "plain text")
    }

}
