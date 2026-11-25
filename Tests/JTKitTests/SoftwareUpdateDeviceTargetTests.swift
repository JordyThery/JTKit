import Foundation
import Testing
import JTKit
@testable import JTKit

/// What Jamf sent a device first, Apple’s data as the fallback: Intel Macs,
/// pending versions, deadlines with an offset. Made-up data only.
@Suite("Targets from the device and Apple’s lists")
struct DeviceTargetTests {
    // as in Apple's own data: X86LEGACYAP is listed for an old major only,
    // J152FAP (a T2 Intel Mac) for 26; 26.6 has no device list
    static let gdmf = #"""
    {"PublicAssetSets":{"macOS":[
      {"ProductVersion":"26.7.2","Build":"25G332","PostingDate":"2026-10-26","SupportedDevices":["J152FAP","J314sAP"]},
      {"ProductVersion":"26.7.1","Build":"25G241","PostingDate":"2026-09-28","SupportedDevices":["J152FAP","J314sAP"]},
      {"ProductVersion":"12.7.9","Build":"21H900","PostingDate":"2025-01-01","SupportedDevices":["X86LEGACYAP","J152FAP"]}]}}
    """#
    static let sofaMacOS = #"""
    {"OSVersions":[{"OSVersion":"Tahoe 26","Latest":{"ProductVersion":"26.7.2","Build":"25G332","ReleaseDate":"2026-10-26T00:00:00Z"},
      "SecurityReleases":[{"ProductVersion":"26.7.1","Build":"25G241","ReleaseDate":"2026-09-28T00:00:00Z"},
                          {"ProductVersion":"26.6","Build":"25F100","ReleaseDate":"2026-07-27T00:00:00Z"}]},
      {"OSVersion":"Golden Gate 27","Latest":{"ProductVersion":"27.2","Build":"26C100","ReleaseDate":"2026-10-26T00:00:00Z","SupportedDevices":["J314sAP"]}}],
     "Models":{"MacBookPro16,1":{"MarketingName":"MacBook Pro (16-inch, 2019)","OSVersions":[26,15,12]},
               "MacBookPro18,3":{"OSVersions":[27,26]}},
     "Devices":{"J314sAP":{"DeviceID":"MacBookPro18,3"}}}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(sofaMacOS.utf8), gdmf: Data(gdmf.utf8))
    static let now = Sample.date("2026-11-09T12:00:00")
    static let minor = JamfPlatform.SoftwareUpdateBlock.Enforcement.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59")

    static func rule(os: String, model: String, boardID: String?,
                     _ enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement = minor) -> DeviceTarget {
        TargetRules.target(os: os, model: model, boardID: boardID, osName: "macOS", context: .init(
            block: TargetRulesTests.block(enforcement), catalog: catalog, platform: .macOS,
            blueprintChanged: nil, updateStarted: nil, now: now))
    }

    @Test("An Intel T2 Mac gets its major’s newest release, reporting X86LEGACYAP or its board ID",
          arguments: ["X86LEGACYAP", "J152FAP"])
    func intelMac(boardID: String) {
        let target = Self.rule(os: "26.7.1", model: "MacBookPro16,1", boardID: boardID)
        #expect(target.version == "26.7.2")
        #expect(target.unknown == nil)
        // the replacement list uses the same rule
        let newest = TargetRules.newestRelease(Self.catalog, .macOS, model: "MacBookPro16,1", boardID: boardID, knownOnly: true)
        #expect(newest?.version.description == "26.7.2")
    }

    @Test("A device already on a release newer than the rule’s target is Target unknown, never lower")
    func runsNewer() {
        // 26.7.1 is 42 days old; the rule (only 26.6 for this "model") can't fit it
        let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(Self.sofaMacOS.utf8), gdmf: Data(#"""
        {"PublicAssetSets":{"macOS":[
          {"ProductVersion":"26.7.2","PostingDate":"2026-10-26","SupportedDevices":["J314sAP"]},
          {"ProductVersion":"26.7.1","PostingDate":"2026-09-28","SupportedDevices":["J314sAP"]}]}}
        """#.utf8))
        let target = TargetRules.target(os: "26.7.1", model: "OddMac1,1", boardID: "J152FAP", osName: "macOS", context: .init(
            block: TargetRulesTests.block(Self.minor), catalog: catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil,
            now: Self.now))
        // the device is unknown to these lists, so it gets the newest of its major
        #expect(target.version == "26.7.2")
        let picked = try! #require(catalog.release(OSVersion("26.6")!, .macOS))
        let unknown = TargetRules.runsNewer(OSVersion("26.7.1"), than: picked, catalog, .macOS, days: 14, now: Self.now, osName: "macOS")
        #expect(unknown?.unknown == .runsNewerRelease)
        // a version too new for the delay, or a beta, is just ahead
        #expect(TargetRules.runsNewer(OSVersion("27.2"), than: picked, catalog, .macOS, days: 30, now: Self.now, osName: "macOS") == nil)
        #expect(TargetRules.runsNewer(OSVersion("26.9"), than: picked, catalog, .macOS, days: 0, now: Self.now, osName: "macOS") == nil)
    }

    // MARK: The pending version

    static func status(pending: String, reason: String?, os: String = "26.7.1", time: String = "2026-11-02T08:00:00",
                       deadline: String = "2026-11-09 22:59:12 +0000") -> JamfPro.SoftwareUpdateStatus {
        var pairs = [("device.operating-system.version", os), ("softwareupdate.pending-version.os-version", pending),
                     ("softwareupdate.pending-version.build-version", "26C100"),
                     ("softwareupdate.pending-version.target-local-date-time", deadline)]
        if let reason { pairs.append(("softwareupdate.install-reason.reason", reason)) }
        return Sample.status(pairs, time: time)
    }

    static func fromDevice(_ status: JamfPro.SoftwareUpdateStatus, os: String = "26.7.1") -> DeviceTarget {
        let rule = Self.rule(os: os, model: "MacBookPro18,3", boardID: "J314sAP")
        return TargetRules.fromDevice(rule, status: status, os: os, osName: "macOS", catalog: catalog, platform: .macOS,
                                      serverTimeZone: Sample.utc)
    }

    @Test("A version pending from a declaration is the target; when the rule differs, both are kept and flagged")
    func pendingDiffers() {
        let target = Self.fromDevice(Self.status(pending: "27.2", reason: "declaration,system-settings"))
        #expect(target.fromDevice && target.version == "27.2")
        #expect(target.ruleVersion == "26.7.2" && target.differsFromRule)
        #expect(target.ruleReason?.contains("26.7.2") == true)
        #expect(target.deadlineOffset == 0)
        #expect(target.deadlineDate == Sample.date("2026-11-09T22:59:12"))
        #expect(target.deadlineLocal == "2026-11-09T22:59:12")
        // the same version as the rule: from the device, not flagged
        let same = Self.fromDevice(Self.status(pending: "26.7.2", reason: "declaration"))
        #expect(same.fromDevice && !same.differsFromRule)
    }

    @Test("A stale pending version, equal to or older than the installed one, is ignored", arguments: ["26.7.1", "26.6"])
    func stale(pending: String) {
        let target = Self.fromDevice(Self.status(pending: pending, reason: "declaration"))
        #expect(!target.fromDevice && target.version == "26.7.2")
    }

    @Test("A pending version for another reason, or none, is ignored", arguments: ["notification", "none", nil] as [String?])
    func otherReason(reason: String?) {
        let target = Self.fromDevice(Self.status(pending: "27.2", reason: reason))
        #expect(!target.fromDevice && target.version == "26.7.2")
    }

    @Test("A pending version reported before the update started is ignored")
    func beforeStart() {
        // the rule's target was released on 26 October
        let target = Self.fromDevice(Self.status(pending: "27.2", reason: "declaration", time: "2026-10-20T08:00:00"))
        #expect(!target.fromDevice)
    }

    @Test("Classified against what Jamf sent, past its deadline by the reported moment")
    func classified() {
        let target = Self.fromDevice(Self.status(pending: "27.2", reason: "declaration"))
        let device = Sample.classify(Sample.mac(os: "26.7.1", model: "MacBookPro18,3"),
                                     Self.status(pending: "27.2", reason: "declaration"), target: target, now: "2026-11-10T08:00:00")
        #expect(device.targetVersion == "27.2" && device.targetFromDevice == true && device.targetDiffersFromRule == true)
        #expect(device.ruleTarget == "26.7.2")
        #expect(device.pastDeadline == true)
    }

    // MARK: Deadline per time zone

    @Test("Where the target comes from, in plain words")
    func source() {
        #expect(Self.fromDevice(Self.status(pending: "26.7.2", reason: "declaration")).source == "Sent by Jamf, matches the Blueprint’s rule")
        #expect(Self.fromDevice(Self.status(pending: "27.2", reason: "declaration")).source == "Sent by Jamf: the device reports it pending from a declaration")
        #expect(Self.rule(os: "26.7.1", model: "MacBookPro18,3", boardID: "J314sAP").source == "From Apple’s data and the Blueprint’s rule")
        #expect(Self.rule(os: "26.7.1", model: "MacBookPro18,3", boardID: nil,
                          .specific(targetOSVersion: "27.2", targetLocalDateTime: nil, detailsURL: nil)).source
                == "The version the Blueprint names")
    }

    @Test("Minor updates: a Mac that can’t run the newest major but runs its own major’s newest isn’t marked or listed")
    func notLimitedOnMinor() {
        // the 2019 MacBook Pro on 26.7.1: the rule gives 26.7.2, which it can run
        let rule = Self.rule(os: "26.7.1", model: "MacBookPro16,1", boardID: "X86LEGACYAP")
        #expect(rule.version == "26.7.2" && !rule.limitedByHardware)
        #expect(rule.source == "From Apple’s data and the Blueprint’s rule")
        let device = Sample.classify(Sample.mac(os: "26.7.1", model: "MacBookPro16,1"), nil, target: rule)
        #expect(device.limitedByHardware != true)
        #expect(Replacement.list([device]) { _ in "26.7.2" }.isEmpty)
    }

    @Test("Latest: a Mac that can’t run the newest release is marked and listed, also with the target Jamf sent")
    func replacementOnLatest() {
        let latest = JamfPlatform.SoftwareUpdateBlock.Enforcement.latest(enforceAfterDays: 14, deploymentTime: "23:59")
        let rule = Self.rule(os: "26.7.1", model: "MacBookPro16,1", boardID: "X86LEGACYAP", latest)
        #expect(rule.version == "26.7.2" && rule.limitedByHardware)
        let sent = TargetRules.fromDevice(rule, status: Self.status(pending: "26.7.2", reason: "declaration"), os: "26.7.1",
                                          osName: "macOS", catalog: Self.catalog, platform: .macOS, serverTimeZone: Sample.utc)
        #expect(sent.fromDevice && sent.limitedByHardware)
        var device = Sample.classify(Sample.mac(os: "26.7.1", model: "MacBookPro16,1"), nil, target: sent)
        device.boardID = "X86LEGACYAP"
        let list = Replacement.list([device]) { device in
            TargetRules.newestRelease(Self.catalog, .macOS, model: device.modelIdentifier, boardID: device.boardID, knownOnly: true)?
                .version.description
        }
        #expect(list.map(\.modelIdentifier) == ["MacBookPro16,1"])
        #expect(list.first?.lastSupportedVersion == "26.7.2")
        #expect(list.first?.note.contains("26.7.2") == true)
    }
}

@Suite("Inspect: update declarations by pair, readable, bootstrap token")
struct InspectDeclarationPairTests {
    let blueprint = "6a2f0000-1111-4000-8000-00000000c0de"

    func report(_ kind: String, _ number: Int, active: Bool, status: String = "SUCCESSFUL",
                reasons: [JamfPlatform.DeclarationReport.Reason] = []) -> JamfPlatform.DeclarationReport {
        JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_\(blueprint)_s1_c1_sys_\(kind)\(number)",
                                       type: kind == "act" ? "ACTIVATION" : "CONFIGURATION", status: .init(status), active: active,
                                       validity: kind == "act" ? .valid : .unknown, reasons: reasons)
    }

    func notForThisDevice(_ number: Int, range: String) -> [JamfPlatform.DeclarationReport] {
        let predicate = #"status.device.operating-system.family == "macOS" AND status.device.operating-system.version MATCHES "\#(range)""#
        return [
            report("act", number, active: false, status: "UNSUCCESSFUL", reasons: [.init(
                code: "Info.Predicate", description: "Activation’s predicate evaluated to false.",
                details: [.init(key: "Identifier", description: "Blueprint_\(blueprint)_s1_c1_sys_act\(number)"),
                          .init(key: "Predicate", description: predicate)])]),
            report("cfg", number, active: false, status: "UNSUCCESSFUL", reasons: [.init(
                code: "Error.ActivationFailed",
                description: "Activation “Blueprint_\(blueprint)_s1_c1_sys_act\(number):9f86d081884c7d659a2feaa0c55ad015” has errors.",
                details: [.init(key: "Identifier", description: "Blueprint_\(blueprint)_s1_c1_sys_act\(number)"),
                          .init(key: "ServerToken", description: "9f86d081884c7d659a2feaa0c55ad015")])]),
        ]
    }

    func evaluate(_ reports: [JamfPlatform.DeclarationReport], member: JamfPro.GroupMember = Sample.mac(os: "26.7.1"),
                  status: JamfPro.SoftwareUpdateStatus? = nil) -> InspectResult {
        let row = Sample.classify(member, status).with(category: .notStarted, diagnosis: "Online, update not started (no error)")
        return InspectFindings.evaluate(InspectInput(member: member, status: status, device: row, platformDeviceID: "P-1", reports: reports),
                                        context: InspectContext(blueprintID: blueprint, blueprintName: "Test Mac Updates",
                                                                target: OSVersion("26.7.2"), since: Sample.updateStarted, now: Sample.now,
                                                                serverTimeZone: Sample.utc))
    }

    @Test("Declarations for other versions are not for this device, not failures")
    func predicateIsNotAFailure() {
        let reports = notForThisDevice(1, range: "^(27[.][0-1]([.][0-9]+)*)$") + notForThisDevice(2, range: "^(15[.][0-9]([.][0-9]+)*)$")
            + [report("act", 12, active: true), report("cfg", 12, active: true)]
        let result = evaluate(reports)
        #expect(!result.findings.contains { $0.cause.hasPrefix("Update declaration") || $0.cause.hasPrefix("No update declaration") })
    }

    @Test("Every other Error.* is a failure, named by Blueprint and versions, without IDs or hashes")
    func otherErrorsFail() throws {
        var reports = notForThisDevice(1, range: "^(27[.][0-1]([.][0-9]+)*)$")
        reports += [report("act", 3, active: true),
                    report("cfg", 3, active: false, status: "UNSUCCESSFUL", reasons: [.init(
                        code: "Error.ConfigurationCannotBeApplied", description: "Can’t apply",
                        details: [.init(key: "Identifier", description: "Blueprint_\(blueprint)_s1_c1_sys_cfg3"),
                                  .init(key: "Error", description: "Update to 26.7.2 isn’t possible")])])]
        let result = evaluate(reports)
        let failure = try #require(result.findings.first { $0.cause == "Update declaration failed" })
        #expect(failure.detail.hasPrefix("Test Mac Updates, macOS 26 (applies to this device): Error.ConfigurationCannotBeApplied"))
        #expect(failure.detail.contains("Update to 26.7.2 isn’t possible"))
        let all = result.findings.map { "\($0.cause) \($0.detail)" }.joined(separator: " ")
        #expect(!all.contains(blueprint) && !all.contains("9f86d081"))
    }

    @Test("Nothing applies: said once, counting the declarations for the device’s own OS")
    func noneApplies() throws {
        let result = evaluate(notForThisDevice(1, range: "^(27[.][0-1]([.][0-9]+)*)$"))
        let finding = try #require(result.findings.first { $0.cause == "No update declaration applies" })
        #expect(finding.detail == "None of Test Mac Updates’s 1 update declaration for macOS applies to macOS 26.7.1. "
                + "No declaration lists Mac14,2, so the Blueprint doesn’t cover this hardware.")
    }

    @Test("A predicate’s versions read as a range", arguments: [
        (#"x MATCHES "^(27[.][0-1]([.][0-9]+)*)$""#, "27.0 to 27.1.x"),
        (#"x MATCHES "^(18[.][0-6]([.][0-9]+)*|18[.]7([.][0-7]([.][0-9]+)*)?)$""#, "18.0 to 18.7.7"),
        (#"x MATCHES "^(26[.]7([.][0-9]+)*)$""#, "26.7.x"),
        // the forms Jamf sends: to the patch
        (#"x MATCHES "^(26[.][0-6]([.][0-9]+)*|26[.]7([.][0-1]([.][0-9]+)*)?)$""#, "26.0 to 26.7.1"),
        (#"x MATCHES "^(18[.][0-6]([.][0-9]+)*|18[.]7([.]([0-9]|10)([.][0-9]+)*)?)$""#, "18.0 to 18.7.10"),
        (#"x MATCHES "^(26[.][0-5]([.][0-9]+)*|26[.]6([.]0([.][0-9]+)*)?)$""#, "26.0 to 26.6"),
        (#"x MATCHES "^(27([.][0-9]+)*)$""#, "27"),
    ])
    func ranges(predicate: String, range: String) {
        #expect(DeclarationPair.versionRange(predicate) == range)
    }

    @Test("A last error that names the bootstrap token makes it the likely cause")
    func bootstrapCause() {
        var mac = Sample.mac(os: "26.7.1")
        mac.bootstrapTokenEscrowedStatus = "NOT_ESCROWED"
        let status = Sample.status([("device.operating-system.version", "26.7.1"),
                                    ("softwareupdate.failure-reason.reason", "Bootstrap token is required to authorize the update"),
                                    ("softwareupdate.failure-reason.timestamp", "2026-11-05T09:00:00")])
        let result = evaluate([report("act", 12, active: true), report("cfg", 12, active: true)], member: mac, status: status)
        #expect(result.cause == "Bootstrap token")
        #expect(result.detail.contains("not escrowed"))
        // without such an error, a missing token is listed but not first
        mac.supervised = true
        let quiet = evaluate([report("act", 12, active: true), report("cfg", 12, active: true)], member: mac)
        #expect(quiet.findings.contains { $0.cause == "Bootstrap token not escrowed" })
    }

    @Test("A token that isn’t escrowed matters only on Apple silicon: an Intel Mac gets no warning, whatever board it reports",
          arguments: ["J152FAP", "X86LEGACYAP"])
    func bootstrapIntel(board: String) {
        var intel = Sample.mac(os: "26.7.1", model: "MacBookPro16,1")
        intel.bootstrapTokenEscrowedStatus = "NOT_ESCROWED"
        intel.supervised = true
        // with a status report naming the Mac's board, as Intel Macs send it
        let status = Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.device-id", board)])
        let result = evaluate([report("act", 12, active: true), report("cfg", 12, active: true)], member: intel, status: status)
        #expect(!result.findings.contains { $0.cause.hasPrefix("Bootstrap token") })
        let row = Sample.classify(intel, status)
        #expect(row.boardID == board)
        #expect(DeviceDetailText.notEscrowedWarning(appleSilicon: DeviceDetailText.isAppleSilicon(model: row.modelIdentifier, boardID: row.boardID)) == nil)

        var silicon = intel
        silicon.modelIdentifier = "MacBookPro18,3"
        let found = evaluate([report("act", 12, active: true), report("cfg", 12, active: true)], member: silicon)
        let finding = found.findings.first { $0.cause == "Bootstrap token not escrowed" }
        #expect(finding?.detail.contains("Apple silicon") == true)
    }

    @Test("Apple silicon from the model identifier or the board ID", arguments: [
        ("Mac14,2", nil, true), ("MacBookAir10,1", nil, true), ("MacBookPro17,1", nil, true), ("Macmini9,1", nil, true),
        ("iMac21,1", nil, true), ("VirtualMac2,1", nil, true), ("MacBookPro16,1", nil, false), ("MacBookAir9,1", nil, false),
        ("Macmini8,1", nil, false), ("iMac20,1", nil, false), ("MacPro7,1", nil, false), ("iMacPro1,1", nil, false),
        ("MacBookPro16,1", "X86LEGACYAP", false), ("MacBookPro16,1", "J152FAP", false), ("MacBookPro18,3", "J314sAP", true),
        ("", "X86LEGACYAP", false), ("", "VMM-x86_64", false), ("", "Mac-827FAC58A8FDFA22", false),
        ("", "J152FAP", nil), ("", "J314sAP", nil), ("", nil, nil), ("iPad14,8", nil, nil),
    ] as [(String, String?, Bool?)])
    func appleSilicon(model: String, boardID: String?, expected: Bool?) {
        #expect(DeviceDetailText.isAppleSilicon(model: model, boardID: boardID) == expected)
        // when the chip isn’t known, the warning says when it applies
        if expected == nil { #expect(DeviceDetailText.notEscrowedWarning(appleSilicon: nil)?.hasPrefix("On a Mac with Apple silicon, ") == true) }
    }
}

@Suite("Inspect: stuck updates and stale declaration reports")
struct InspectStaleAndStuckTests {
    let blueprint = "6a2f0000-1111-4000-8000-00000000c0de"

    func evaluate(_ member: JamfPro.GroupMember, status: JamfPro.SoftwareUpdateStatus?, row: DeviceStatus,
                  reports: [JamfPlatform.DeclarationReport] = [], changed: Date? = nil) -> InspectResult {
        InspectFindings.evaluate(InspectInput(member: member, status: status, device: row, platformDeviceID: "P-1", reports: reports),
                                 context: InspectContext(blueprintID: blueprint, blueprintName: "Test Mac Updates", target: nil,
                                                         since: nil, blueprintChanged: changed, now: Sample.now, serverTimeZone: Sample.utc))
    }

    func prepared() -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "26.7.1"), ("softwareupdate.install-state", "prepared"),
                       ("softwareupdate.pending-version.os-version", "26.7.2")], time: "2026-11-01T06:00:00")
    }

    @Test("Prepared before the deadline installs at the deadline; after it, it is stuck")
    func stuck() {
        var row = Sample.classify(Sample.mac(os: "26.7.1"), prepared())
        row.pastDeadline = false
        let before = evaluate(Sample.mac(os: "26.7.1"), status: prepared(), row: row)
        #expect(before.findings.contains { $0.cause == "Update downloaded" && $0.detail.hasSuffix("installs at the deadline") })
        #expect(!before.findings.contains { $0.cause == "Update stuck" })
        row.pastDeadline = true
        let after = evaluate(Sample.mac(os: "26.7.1"), status: prepared(), row: row)
        let stuck = after.findings.first { $0.cause == "Update stuck" }
        #expect(stuck?.detail.contains("not installed after its deadline (last change 4 days ago)") == true)
    }

    @Test("An offline device is never stuck")
    func offline() {
        let member = Sample.mac(os: "26.7.1")
        var row = Sample.classify(member, prepared())
        row.pastDeadline = true
        row.category = .offline
        #expect(!evaluate(member, status: prepared(), row: row).findings.contains { $0.cause == "Update stuck" })
    }

    @Test("Up to 48 hours in hours, longer in days")
    func durations() {
        #expect(InspectFindings.ago(Sample.now.addingTimeInterval(-47 * 3_600), now: Sample.now) == "47 h ago")
        #expect(InspectFindings.ago(Sample.now.addingTimeInterval(-50 * 3_600), now: Sample.now) == "2 days ago")
    }

    func pair(_ number: Int, versions: String, lists: [String], reported: String) -> [JamfPlatform.DeclarationReport] {
        let predicate = #"status.device.operating-system.version MATCHES "\#(versions)" AND status.softwareupdate.device-id IN {\#(lists.map { "\"\($0)\"" }.joined(separator: ", "))}"#
        let at = Sample.date(reported)
        return [
            JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_\(blueprint)_s1_c1_sys_act\(number)", type: "ACTIVATION",
                                           status: .unsuccessful, active: false, validity: .valid,
                                           reasons: [.init(code: "Info.Predicate", details: [.init(key: "Predicate", description: predicate)])],
                                           lastReportTime: at),
            JamfPlatform.DeclarationReport(declarationIdentifier: "Blueprint_\(blueprint)_s1_c1_sys_cfg\(number)", type: "CONFIGURATION",
                                           status: .unsuccessful, active: false, reasons: [.init(code: "Error.ActivationFailed")],
                                           lastReportTime: at),
        ]
    }

    @Test("A declaration report from before the update started is the likely cause, not “doesn’t apply”")
    func stale() {
        let member = Sample.mac(os: "15.8.1", model: "MacBookAir10,1")
        let status = Sample.status([("device.operating-system.version", "15.8.1"), ("softwareupdate.device-id", "J313AP")])
        var row = Sample.classify(member, status)
        row.activityFrom = Sample.date("2026-10-26T00:00:00")
        let reports = pair(14, versions: "^(15[.][0-8]([.][0-9]+)*)$", lists: ["J313AP"], reported: "2026-10-14T19:08:00")
        let result = evaluate(member, status: status, row: row, reports: reports)
        #expect(result.cause == "Not evaluated since the update started")
        #expect(result.detail.contains(InspectFindings.day(Sample.date("2026-10-14T19:08:00")))
                && result.detail.contains(InspectFindings.day(Sample.date("2026-10-26T00:00:00"))))
        #expect(!result.findings.contains { $0.cause == "No update declaration applies" })
        // the Blueprint's last change counts too
        row.activityFrom = Sample.date("2026-10-01T00:00:00")
        #expect(evaluate(member, status: status, row: row, reports: reports, changed: Sample.date("2026-10-20T00:00:00")).cause
                == "Not evaluated since the update started")
    }

    @Test("A current report that excludes the device says so, checking its own device ID")
    func current() throws {
        let member = Sample.mac(os: "15.8.2", model: "MacBookAir10,1")
        let status = Sample.status([("device.operating-system.version", "15.8.2"), ("softwareupdate.device-id", "J313AP")])
        var row = Sample.classify(member, status)
        row.activityFrom = Sample.date("2026-10-26T00:00:00")
        // the Blueprint asks for a newer version than the Mac runs
        row.targetVersion = "15.8.3"
        let reports = pair(14, versions: "^(15[.][0-8]([.][0-1])?)$", lists: ["J313AP", "J274AP"], reported: "2026-11-05T09:00:00")
            + pair(2, versions: "^(26[.][0-7]([.][0-9]+)*)$", lists: ["J414sAP"], reported: "2026-11-05T09:00:00")
        // the range that lists this Mac ends below its version: Jamf's update doesn't cover it yet
        let finding = try #require(evaluate(member, status: status, row: row, reports: reports).findings
            .first { $0.cause == "Jamf’s update doesn’t cover macOS 15.8.2 yet" })
        #expect(finding.detail.contains("Blueprint’s update declarations for this hardware covered macOS 15.0 to 15.8.1, not 15.8.2"))
        // a range above its version: the condition excludes it
        let above = pair(14, versions: "^(15[.]9([.][0-9]+)*)$", lists: ["J313AP"], reported: "2026-11-05T09:00:00")
        let excluded = try #require(evaluate(member, status: status, row: row, reports: above).findings
            .first { $0.cause == "No update declaration applies" })
        #expect(excluded.detail.contains("1 list J313AP (macOS 15.9.x), so their version condition excludes macOS 15.8.2."))
        let none = pair(2, versions: "^(26[.][0-7]([.][0-9]+)*)$", lists: ["J414sAP"], reported: "2026-11-05T09:00:00")
        let other = try #require(evaluate(member, status: status, row: row, reports: none).findings
            .first { $0.cause == "No update declaration applies" })
        #expect(other.detail.hasSuffix("No declaration lists J313AP, so the Blueprint doesn’t cover this hardware."))
    }

    @Test("The older predicate form reads too")
    func olderPredicate() {
        #expect(DeclarationPair.versionRange(#"x version < "27.0.1" AND x version BEGINSWITH "27." AND y"#) == "27 below 27.0.1")
    }
}

@Suite("Deadlines from Apple’s posting date")
struct PostingDeadlineTests {
    static let gdmf = #"""
    {"PublicAssetSets":{"macOS":[
       {"ProductVersion":"27.2","Build":"26B123","PostingDate":"2026-11-05","SupportedDevices":["J314sAP","J413AP"]}],
     "iOS":[{"ProductVersion":"27.1","Build":"24B100","PostingDate":"2026-11-02","SupportedDevices":["iPad14,8"]}]},
     "AssetSets":{"macOS":[
       {"ProductVersion":"27.2","Build":"26B123","PostingDate":"2026-10-26","SupportedDevices":["J314sAP","J413AP"]},
       {"ProductVersion":"27.0.1","Build":"26A434","PostingDate":"2026-09-28","SupportedDevices":["J314sAP","J413AP"]}]}}
    """#
    static let sofaMacOS = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.2","Build":"26B8125","ReleaseDate":"2026-10-26T00:00:00Z"}}],
     "Models":{"MacBookPro18,3":{"OSVersions":[27]}},"Devices":{"J314sAP":{"DeviceID":"MacBookPro18,3"}}}
    """#
    static let sofaIOS = #"""
    {"OSVersions":[{"OSVersion":"27","Latest":{"ProductVersion":"27.1","Build":"24B100","ReleaseDate":"2026-10-20T00:00:00Z"}}]}
    """#
    static let catalog = try! AppleReleases.Catalog(sofaIOS: Data(sofaIOS.utf8), sofaMacOS: Data(sofaMacOS.utf8), gdmf: Data(gdmf.utf8))
    static let minor = JamfPlatform.SoftwareUpdateBlock.Enforcement.semantic(minorEnforceAfterDays: 14, deploymentTime: "23:59")

    static func rule(os: String, now: String = "2026-11-09T12:00:00", platform: AppleReleases.Platform = .macOS,
                     model: String = "MacBookPro18,3", boardID: String? = "J314sAP",
                     _ enforcement: JamfPlatform.SoftwareUpdateBlock.Enforcement = minor) -> DeviceTarget {
        TargetRules.target(os: os, model: model, boardID: boardID, osName: platform == .macOS ? "macOS" : "iPadOS", context: .init(
            block: TargetRulesTests.block(enforcement), catalog: catalog, platform: platform, blueprintChanged: nil,
            updateStarted: nil, now: Sample.date(now)))
    }

    @Test("Posted to the public catalog later than released: the deadline counts from the posting, reports from the release")
    func laterPosting() {
        let target = Self.rule(os: "27.0.1")
        #expect(target.version == "27.2")
        #expect(target.build == "26B123")
        #expect(target.deadlineLocal == "2026-11-19T23:59:00")
        #expect(target.deadlineSource == .postingDate)
        #expect(target.activityFrom == Sample.date("2026-10-26T00:00:00"))
        #expect(target.reason == "The newest public macOS 27 release: 27.2; installs by \(TargetRules.day("2026-11-19T23:59:00"))")
        // the live case: on 6 Nov, the day after Apple's public posting, 27.2 is already the target, due 19 Nov
        let dayAfter = Self.rule(os: "27.0.1", now: "2026-11-06T09:00:00")
        #expect(dayAfter.version == "27.2" && dayAfter.deadlineLocal == "2026-11-19T23:59:00")
        // on 4 Nov, before the posting, it isn't
        #expect(Self.rule(os: "27.0.1", now: "2026-11-04T09:00:00").version == "27.0.1")
        // every platform
        let iPad = Self.rule(os: "27.0", platform: .iOS, model: "iPad14,8", boardID: nil)
        #expect(iPad.deadlineLocal == "2026-11-16T23:59:00" && iPad.deadlineSource == .postingDate)
    }

    @Test("No posting date: the first release date, and the source says so")
    func noPosting() {
        let target = Self.rule(os: "27.0", now: "2026-10-20T12:00:00")
        #expect(target.version == "27.0.1")
        #expect(target.deadlineLocal == "2026-10-12T23:59:00")
        #expect(target.deadlineSource == .releaseDate)
        #expect(target.deadlineSource?.text == "From the release date, no posting date found")
    }

    static func pending(updated: String, deadline: String = "2026-11-09 22:59:06 +0000", version: String = "27.2") -> JamfPro.SoftwareUpdateStatus {
        Sample.status([("device.operating-system.version", "27.0.1"), ("softwareupdate.install-state", "prepared"),
                       ("softwareupdate.pending-version.os-version", version),
                       ("softwareupdate.pending-version.target-local-date-time", deadline),
                       ("softwareupdate.install-reason.reason", "declaration")], time: updated)
    }

    static func sent(_ status: JamfPro.SoftwareUpdateStatus, changed: Date? = nil, rule: DeviceTarget = rule(os: "27.0.1"),
                     serverTimeZone: TimeZone = Sample.utc) -> DeviceTarget {
        TargetRules.fromDevice(rule, status: status, os: "27.0.1", osName: "macOS", catalog: Self.catalog,
                               platform: .macOS, serverTimeZone: serverTimeZone, model: "MacBookPro18,3", boardID: "J314sAP",
                               blueprintChanged: changed)
    }

    static let named = rule(os: "27.0.1", .specific(targetOSVersion: "27.2", targetLocalDateTime: "2026-11-20T17:00:00", detailsURL: nil))
    static let member = Sample.mac(os: "27.0.1", model: "MacBookPro18,3")

    static func inspect(_ status: JamfPro.SoftwareUpdateStatus, _ device: DeviceStatus, now: String) -> InspectResult {
        InspectFindings.evaluate(
            InspectInput(member: member, status: status, device: device, platformDeviceID: "P-1", reports: []),
            context: InspectContext(blueprintID: "6a2f0000-1111-4000-8000-00000000c0de", target: nil, since: nil,
                                    now: Sample.date(now), serverTimeZone: Sample.utc))
    }

    @Test("A report from before Apple’s posting says so, not that the Blueprint changed")
    func staleByPosting() throws {
        let status = Self.pending(updated: "2026-11-03T07:11:00")
        let target = Self.sent(status)
        #expect(target.staleReason == .posted && target.staleReportedDeadline != nil)
        let device = Sample.classify(Self.member, status, target: target, now: "2026-11-10T08:00:00")
        let inspected = Self.inspect(status, device, now: "2026-11-10T08:00:00")
        let finding = try #require(inspected.findings.first { $0.cause == "Deadline reported before Apple posted this version" })
        #expect(finding.detail.contains("before Apple posted this version publicly") && !finding.detail.contains("Blueprint’s last change"))
        #expect(!inspected.findings.contains { $0.cause == "Declaration not refreshed since the Blueprint changed" })
        // the Blueprint changed after the posting: that is the reason
        #expect(Self.sent(status, changed: Sample.date("2026-11-06T09:00:00")).staleReason == .blueprintChanged)
    }

    @Test("A specific version: Apple’s posting doesn’t make a report stale; the Blueprint’s change does")
    func specificIgnoresPosting() {
        let status = Self.pending(updated: "2026-11-03T07:11:00")
        let target = Self.sent(status, rule: Self.named)
        #expect(target.staleReason == nil && target.deadlineSource == .reported)
        #expect(Self.sent(status, changed: Sample.date("2026-11-04T09:00:00"), rule: Self.named).staleReason == .blueprintChanged)
    }

    @Test("The rule gives no deadline: a stale reported one stays, said to be possibly out of date")
    func staleWithoutRuleDeadline() {
        let noDeadline = Self.rule(os: "27.0.1", .specific(targetOSVersion: "27.2", targetLocalDateTime: nil, detailsURL: nil))
        let status = Self.pending(updated: "2026-11-03T07:11:00")
        let target = Self.sent(status, changed: Sample.date("2026-11-06T09:00:00"), rule: noDeadline)
        #expect(target.deadlineDate == Sample.date("2026-11-09T22:59:06"))
        #expect(target.deadlineSource == .reportedBeforeChange)
        #expect(target.deadlineSource?.text.hasSuffix("may be out of date") == true)
        let device = Sample.classify(Self.member, status, target: target, now: "2026-11-10T08:00:00")
        #expect(device.pastDeadline == true)
    }

    @Test("A pending version other than the rule’s keeps its reported deadline: this Blueprint’s change says nothing about it")
    func otherDeclarationKeepsItsDeadline() {
        let target = Self.sent(Self.pending(updated: "2026-11-03T07:11:00", version: "27.1"), changed: Sample.date("2026-11-06T09:00:00"))
        #expect(target.version == "27.1" && target.differsFromRule)
        #expect(target.staleReason == nil && target.deadlineSource == .reported && target.deadlineDate == Sample.date("2026-11-09T22:59:06"))
    }

    @Test("A stale deadline on the rule’s own deadline day isn’t pointed out")
    func staleSameDay() {
        let status = Self.pending(updated: "2026-11-03T07:11:00", deadline: "2026-11-19 22:00:00 +0000")
        let target = Self.sent(status, changed: Sample.date("2026-11-06T09:00:00"))
        #expect(target.deadlineLocal == "2026-11-19T23:59:00" && target.deadlineSource == .postingDate)
        #expect(target.staleReason == nil && target.staleReportedDeadline == nil)
    }

    @Test("After the rule’s deadline a stale report is stuck in the row and in Inspect alike")
    func staleAfterRuleDeadline() {
        let status = Self.pending(updated: "2026-11-03T07:11:00")
        let target = Self.sent(status, changed: Sample.date("2026-11-06T09:00:00"))
        let device = Sample.classify(Self.member, status, target: target, now: "2026-11-21T08:00:00")
        #expect(device.pastDeadline == true && device.diagnosis.contains("not installed after the deadline"))
        let inspected = Self.inspect(status, device, now: "2026-11-21T08:00:00")
        #expect(inspected.findings.contains { $0.cause == "Update stuck" })
        #expect(!inspected.findings.contains { $0.cause == "Update downloaded" })
    }

    @Test("A stale deadline without an offset stays the device’s local time")
    func staleLocalDeadline() throws {
        let status = Self.pending(updated: "2026-11-03T07:11:00", deadline: "2026-11-09 22:59:06")
        let target = Self.sent(status, changed: Sample.date("2026-11-06T09:00:00"))
        #expect(target.staleReportedDeadline == nil && target.staleReportedLocal == "2026-11-09T22:59:06")
        #expect(DeadlineZones.text(local: target.staleReportedLocal, reported: nil)?.hasSuffix("(device’s local time)") == true)
        let device = Sample.classify(Self.member, status, target: target, now: "2026-11-10T08:00:00")
        let finding = try #require(Self.inspect(status, device, now: "2026-11-10T08:00:00").findings
            .first { $0.cause == "Declaration not refreshed since the Blueprint changed" })
        #expect(finding.detail.contains(try #require(InspectFindings.localDay("2026-11-09T22:59:06"))))
    }

    @Test("A report at the change time is stale; without a change and a posting it’s current; the server’s time zone counts")
    func reportTimes() {
        let changed = Sample.date("2026-11-06T09:00:00")
        #expect(Self.sent(Self.pending(updated: "2026-11-06T09:00:00"), changed: changed, rule: Self.named).staleReason == .blueprintChanged)
        // a specific version without a change time: nothing can make it stale
        #expect(Self.sent(Self.pending(updated: "2026-11-01T09:00:00"), rule: Self.named).deadlineSource == .reported)
        // 09:30 on a server an hour ahead of UTC is 08:30 UTC: before a 09:00 UTC change
        let ahead = TimeZone(identifier: "Europe/Brussels")!
        #expect(Self.sent(Self.pending(updated: "2026-11-06T09:30:00"), changed: changed, rule: Self.named, serverTimeZone: ahead)
            .staleReason == .blueprintChanged)
        #expect(Self.sent(Self.pending(updated: "2026-11-06T09:30:00"), changed: changed, rule: Self.named).staleReason == nil)
    }

    @Test("Delay 0: the target on the posting day, due that day at the Blueprint’s time, or at midnight without one")
    func delayZero() {
        let withTime = Self.rule(os: "27.0.1", now: "2026-11-05T12:00:00", .semantic(minorEnforceAfterDays: 0, deploymentTime: "17:00"))
        #expect(withTime.version == "27.2" && withTime.deadlineLocal == "2026-11-05T17:00:00")
        #expect(TargetRules.isPastDeadline(withTime.deadlineLocal, timeZone: "UTC", now: Sample.date("2026-11-05T12:00:00")) == false)
        let noTime = Self.rule(os: "27.0.1", now: "2026-11-05T12:00:00", .semantic(minorEnforceAfterDays: 0, deploymentTime: nil))
        #expect(noTime.version == "27.2" && noTime.deadlineLocal == "2026-11-05T00:00:00")
        #expect(TargetRules.isPastDeadline(noTime.deadlineLocal, timeZone: "UTC", now: Sample.date("2026-11-05T12:00:00")) == true)
        #expect(DeadlineZones.text(local: noTime.deadlineLocal, reported: nil)?.hasSuffix("(device’s local time)") == true)
    }

    @Test("A deadline from a current report wins; a specific version’s is the Blueprint’s")
    func currentReportWins() {
        // reported on 7 Nov: after the public posting (5 Nov) and the Blueprint's change (6 Nov)
        let target = Self.sent(Self.pending(updated: "2026-11-07T08:00:00", deadline: "2026-11-19 22:59:06 +0000"),
                               changed: Sample.date("2026-11-06T09:00:00"))
        #expect(target.deadlineSource == .reported && target.deadlineDate == Sample.date("2026-11-19T22:59:06"))
        #expect(target.staleReportedDeadline == nil)
        let device = Sample.classify(Sample.mac(os: "27.0.1", model: "MacBookPro18,3"), Self.pending(updated: "2026-11-07T08:00:00"),
                                     target: target)
        #expect(device.deadlineSource == "Reported by the device")
        let named = Self.rule(os: "27.0.1", .specific(targetOSVersion: "27.2", targetLocalDateTime: "2026-11-20T17:00:00", detailsURL: nil))
        #expect(named.deadlineSource == .blueprint)
        #expect(Sample.classify(Sample.mac(os: "27.0.1"), nil, target: Self.rule(os: "27.0.1")).deadlineSource == "From Apple’s posting date")
    }

    @Test("The live case: 9 Nov reported before a 6 Nov change, the rule gives 19 Nov: not late, not stuck")
    func staleReportLoses() throws {
        let status = Self.pending(updated: "2026-11-03T07:11:00")
        let target = Self.sent(status, changed: Sample.date("2026-11-06T09:00:00"))
        #expect(target.fromDevice && target.version == "27.2")
        #expect(target.deadlineLocal == "2026-11-19T23:59:00" && target.deadlineSource == .postingDate && target.deadlineDate == nil)
        #expect(target.staleReportedDeadline == Sample.date("2026-11-09T22:59:06"))
        #expect(target.staleSince == Sample.date("2026-11-06T09:00:00"))
        // on 10 Nov, after the stale 9 Nov but before 19 Nov
        let member = Sample.mac(os: "27.0.1", model: "MacBookPro18,3")
        let device = Sample.classify(member, status, target: target, now: "2026-11-10T08:00:00")
        #expect(device.pastDeadline == false)
        #expect(!device.diagnosis.contains("after the deadline"))
        #expect(device.staleReportedDeadline != nil)
        let inspected = InspectFindings.evaluate(
            InspectInput(member: member, status: status, device: device, platformDeviceID: "P-1", reports: []),
            context: InspectContext(blueprintID: "6a2f0000-1111-4000-8000-00000000c0de", target: nil, since: nil,
                                    now: Sample.date("2026-11-10T08:00:00"), serverTimeZone: Sample.utc))
        #expect(!inspected.findings.contains { $0.cause == "Update stuck" })
        let finding = try #require(inspected.findings.first { $0.cause == "Declaration not refreshed since the Blueprint changed" })
        #expect(finding.detail.contains(InspectFindings.day(Sample.date("2026-11-09T22:59:06")))
                && finding.detail.contains(InspectFindings.day(Sample.date("2026-11-06T09:00:00"))))
        #expect(target.staleReason == .blueprintChanged)
        // the posting alone makes a report stale too
        #expect(Self.sent(status).staleReason == .posted)
    }

    @Test("A release becomes a target only once Apple offers it publicly, the basis its deadline counts from")
    func eligibility() {
        // 1 Nov, newest release 3 days old: 27.2 is first seen 26 Oct but only posted publicly on 5 Nov
        let latest = JamfPlatform.SoftwareUpdateBlock.Enforcement.latest(enforceAfterDays: 3, deploymentTime: "23:59")
        let early = Self.rule(os: "27.0", now: "2026-11-01T12:00:00", latest)
        #expect(early.version == "27.0.1")
        #expect(Self.rule(os: "27.0", now: "2026-11-09T12:00:00", latest).version == "27.2")
        // GDMF lists a newer version only outside the public catalog: not offered yet
        let catalog = try! AppleReleases.Catalog(sofaMacOS: Data(Self.sofaMacOS.utf8), gdmf: Data(#"""
        {"PublicAssetSets":{"macOS":[{"ProductVersion":"27.2","Build":"26B123","PostingDate":"2026-11-05","SupportedDevices":["J314sAP"]}]},
         "AssetSets":{"macOS":[{"ProductVersion":"27.3","Build":"26C100","PostingDate":"2026-11-01","SupportedDevices":["J314sAP"]},
                               {"ProductVersion":"27.0.1","Build":"26A434","PostingDate":"2026-09-28","SupportedDevices":["J314sAP"]}]}}
        """#.utf8))
        let release = { (text: String) in catalog.release(OSVersion(text)!, .macOS)! }
        #expect(!TargetRules.isOffered(release("27.3"), catalog, model: "MacBookPro18,3", boardID: "J314sAP"))
        #expect(TargetRules.isOffered(release("27.0.1"), catalog))
        #expect(TargetRules.isOffered(release("27.2"), catalog, model: "MacBookPro18,3", boardID: "J314sAP"))
        // a version newer than every public one is never the target, however old its first date
        let minor = JamfPlatform.SoftwareUpdateBlock.Enforcement.semantic(minorEnforceAfterDays: 0, deploymentTime: nil)
        let target = TargetRules.target(os: "27.0.1", model: "MacBookPro18,3", boardID: "J314sAP", osName: "macOS", context: .init(
            block: TargetRulesTests.block(minor), catalog: catalog, platform: .macOS, blueprintChanged: nil, updateStarted: nil,
            now: Sample.date("2026-11-20T12:00:00")))
        #expect(target.version == "27.2")
    }
}
