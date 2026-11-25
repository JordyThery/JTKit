import Foundation

extension SoftwareUpdateRules {
    /// One device as Inspect gets it.
    public nonisolated struct InspectInput: Sendable {
        public var member: JamfPro.GroupMember
        public var status: JamfPro.SoftwareUpdateStatus?
        /// Its row from the latest refresh, if there is one.
        public var device: DeviceStatus?
        /// The Platform API’s device ID; nil when the serial isn’t in its device list.
        public var platformDeviceID: String?
        /// Its declaration reports; nil when they couldn’t be read.
        public var reports: [JamfPlatform.DeclarationReport]?
        /// Why the reports couldn’t be read.
        public var reportsProblem: String?
        /// Why the device couldn’t be inspected at all.
        public var problem: String?
        /// When the device last changed its install state (the item’s
        /// `lastUpdateTime`, in the Jamf Pro server’s time zone); nil when not known.
        public var installStateChanged: Date?
        /// When the device last reported its OS version (the item’s
        /// `lastUpdateTime`): for a device on target, when it had installed it.
        public var osVersionChanged: Date?

        public init(member: JamfPro.GroupMember, status: JamfPro.SoftwareUpdateStatus? = nil, device: DeviceStatus? = nil,
             platformDeviceID: String? = nil, reports: [JamfPlatform.DeclarationReport]? = nil, reportsProblem: String? = nil,
             problem: String? = nil) {
            self.member = member
            self.status = status
            self.device = device
            self.platformDeviceID = platformDeviceID
            self.reports = reports
            self.reportsProblem = reportsProblem
            self.problem = problem
        }
    }

    /// What Inspect knows besides the device’s own data.
    public nonisolated struct InspectContext: Sendable {
        public var blueprintID: String
        /// The tracked Blueprint’s name, for readable declaration names.
        public var blueprintName = "The Blueprint"
        public var target: OSVersion?
        /// When the update started; errors before it don’t count.
        public var since: Date?
        /// When the Blueprint last changed: a declaration report from before it
        /// says nothing about the current declarations.
        public var blueprintChanged: Date?
        public var now: Date
        public var serverTimeZone: TimeZone
        public var staleDays = 30
        public var minFreeSpaceMB = 6_000
        /// The majors Apple’s release data knows for the platform.
        public var majors: [Int] = []
        public var supports: @Sendable (_ model: String?, _ boardID: String?, _ major: Int) -> Bool? = { _, _, _ in nil }
        /// Apple’s release data: when set, the majors and support of each
        /// device’s own platform (a Blueprint can reach iPads and Macs).
        public var catalog: AppleReleases.Catalog?
        /// The Blueprint’s current update declarations (Blueprint health); nil
        /// when the refresh couldn’t read them: then the device’s own report is used.
        public var current: [BlueprintHealth.Current]?

        /// Every stored property, in order, with the same defaults as the memberwise initializer.
        public init(
            blueprintID: String,
            blueprintName: String = "The Blueprint",
            target: OSVersion? = nil,
            since: Date? = nil,
            blueprintChanged: Date? = nil,
            now: Date,
            serverTimeZone: TimeZone,
            staleDays: Int = 30,
            minFreeSpaceMB: Int = 6_000,
            majors: [Int] = [],
            supports: @escaping @Sendable (_ model: String?, _ boardID: String?, _ major: Int) -> Bool? = { _, _, _ in nil },
            catalog: AppleReleases.Catalog? = nil,
            current: [BlueprintHealth.Current]? = nil
        ) {
            self.blueprintID = blueprintID
            self.blueprintName = blueprintName
            self.target = target
            self.since = since
            self.blueprintChanged = blueprintChanged
            self.now = now
            self.serverTimeZone = serverTimeZone
            self.staleDays = staleDays
            self.minFreeSpaceMB = minFreeSpaceMB
            self.majors = majors
            self.supports = supports
            self.catalog = catalog
            self.current = current
        }
    }

    /// One reason a device may not update.
    public nonisolated struct Finding: Sendable, Hashable, Codable {
        public var cause: String
        public var detail: String
        /// From before the update started (an earlier error): listed, never the likely cause.
        public var earlier: Bool?

        /// Every stored property, in order, with the same defaults as the memberwise initializer.
        public init(
            cause: String,
            detail: String,
            earlier: Bool? = nil
        ) {
            self.cause = cause
            self.detail = detail
            self.earlier = earlier
        }
    }

    /// One of the Blueprint’s declarations on one device: its name (never an
    /// ID) and how it stands there.
    public nonisolated struct DeclarationLine: Sendable, Hashable, Codable {
        public var name: String
        public var state: String

        /// Every stored property, in order, with the same defaults as the memberwise initializer.
        public init(
            name: String,
            state: String
        ) {
            self.name = name
            self.state = state
        }
    }

    /// Every reason a device may not update, most likely first.
    public nonisolated struct InspectResult: Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var serial: String
        public var modelIdentifier: String
        public var os: String
        public var diagnosis: String
        public var onTarget: Bool
        public var findings: [Finding]
        /// The Blueprint’s current declarations for the device’s own platform
        /// by name, with how each stands on the device.
        public var declarations: [DeclarationLine] = []
        /// The others, which don’t apply to this device (other platforms, other
        /// versions or hardware): one line.
        public var otherDeclarations = 0

        /// The likely cause: the first finding that isn’t from before the update started.
        public var likely: Finding? { findings.first { $0.earlier != true } }
        public var cause: String { onTarget ? "On target" : likely?.cause ?? "No cause found" }
        public var detail: String {
            onTarget ? "Already on the target version"
                : likely?.detail ?? "Check the device in Jamf Pro (management history, declarations)"
        }

        /// Every finding but the likely cause, in order.
        public var alsoFound: [Finding] {
            guard !onTarget, let index = findings.firstIndex(where: { $0.earlier != true }) else { return findings }
            var rest = findings
            rest.remove(at: index)
            return rest
        }


        /// Every stored property, in order, with the same defaults as the memberwise initializer.
        public init(
            id: String,
            name: String,
            serial: String,
            modelIdentifier: String,
            os: String,
            diagnosis: String,
            onTarget: Bool,
            findings: [Finding],
            declarations: [DeclarationLine] = [],
            otherDeclarations: Int = 0
        ) {
            self.id = id
            self.name = name
            self.serial = serial
            self.modelIdentifier = modelIdentifier
            self.os = os
            self.diagnosis = diagnosis
            self.onTarget = onTarget
            self.findings = findings
            self.declarations = declarations
            self.otherDeclarations = otherDeclarations
        }
    }

    /// Per device, every reason it may not update, most likely first.
    public nonisolated enum InspectFindings {
        public static func evaluate(_ input: InspectInput, context ctx: InspectContext) -> InspectResult {
            let member = input.member
            let status = input.status
            let row = input.device
            // the newer of what the device reports and its inventory, as the refresh counts it
            let os = row?.currentOS ?? Classifier.newer(status?.osVersion, member.osVersion) ?? ""
            let version = OSVersion(os)
            let modelID = member.modelIdentifier ?? status?.modelIdentifier ?? ""
            let osName = Classifier.osName(isComputer: member.kind == .computer, modelIdentifier: modelID)
            let isMobile = member.kind == .mobileDevice
            let category = row?.category
            let diagnosis = row?.diagnosis ?? ""
            // the device’s own target and start, when the refresh gave it one
            let target = row?.targetVersion.flatMap(OSVersion.init) ?? ctx.target
            let since = row?.activityFrom ?? ctx.since
            let platform: AppleReleases.Platform = member.kind == .computer ? .macOS : .iOS
            let majors = ctx.catalog?.majors(platform) ?? ctx.majors
            let supports: (String?, String?, Int) -> Bool? = { model, board, major in
                if let catalog = ctx.catalog { return catalog.supports(model: model, boardID: board, major: major, platform) }
                return ctx.supports(model, board, major)
            }

            var findings: [Finding] = []
            func add(_ cause: String, _ detail: String) { findings.append(Finding(cause: cause, detail: detail)) }

            if let problem = input.problem { add("Could not be inspected", problem) }
            if member.managed == false { add("Not managed", "Jamf Pro lists the device as unmanaged") }
            // Apple's enforced update: supervised or device enrollments on iOS and iPadOS, supervised Macs only
            if isMobile && member.isUserEnrollment == true {
                add("User Enrollment", "The device is enrolled with User Enrollment, which doesn’t get an enforced software update")
            }
            if !isMobile && member.supervised == false {
                add("Not supervised", "A Mac gets an enforced software update only when it’s supervised")
            }
            if member.ddmEnabled == false {
                add("Declarative management off", "The device doesn’t use declarative device management, so the Blueprint can’t reach it")
            }
            if let expiry = member.mdmProfileExpiration, expiry < ctx.now {
                add("MDM profile expired", "Expired \(day(expiry))")
            }
            if let contact = member.lastSeen, ctx.now.timeIntervalSince(contact) > Double(ctx.staleDays) * 86_400 {
                add("Offline", "Last contact \(day(contact))")
            }

            // The update Blueprint’s declarations on the device, as pairs of a
            // configuration and its own activation. A minor-updates Blueprint
            // sends one pair per version range; those for other ranges report
            // Info.Predicate (and their configuration Error.ActivationFailed):
            // not for this device, so not a failure.
            let reports = input.reports
            let mine = (reports ?? []).filter { $0.blueprintID == ctx.blueprintID.lowercased() }
            let pairs = DeclarationPair.pairs(mine)
            let applicable = pairs.filter { !$0.isNotForThisDevice }
            let active = pairs.filter(\.isActive)
            // each declaration by its own platform: an iPadOS range is never named macOS
            func label(_ pair: DeclarationPair) -> String {
                pair.label(blueprint: ctx.blueprintName, osName: pair.family ?? osName, deviceMajor: version?.major)
            }
            let updated = status?.newestUpdate.flatMap { JamfPro.serverDate($0, timeZone: ctx.serverTimeZone) }
            if input.platformDeviceID == nil && reports == nil {
                add("Not in the Platform device list", "Serial \(member.serialNumber ?? "?") not found, so the declaration report can’t be read")
            } else if reports == nil {
                add("Declaration report not available", "\(input.reportsProblem ?? "No answer") (the API client needs declarations:read)")
            } else if mine.isEmpty {
                add("Update Blueprint not on the device", "None of its declarations are reported (scope, or the device hasn’t synced)")
            } else if let evaluated = mine.compactMap(\.lastReportTime).max(),
                      let start = [since, ctx.blueprintChanged].compactMap({ $0 }).max(), evaluated < start {
                // the device's report is older than the current declarations: it says nothing about them.
                // The likely cause only when the device has no software update status since then either.
                let stale = Finding(cause: "Not evaluated since the update started",
                                    detail: "The device last reported its update declarations on \(day(evaluated)), before the update "
                                        + "started (\(day(start))), so its report doesn’t cover the current declarations. It reports "
                                        + "again after its next check-in")
                // an offline device is offline first: that is why it hasn't reported
                let offlineFirst = member.lastSeen.map { ctx.now.timeIntervalSince($0) > Double(ctx.staleDays) * 86_400 } ?? false
                if updated.map({ $0 >= start }) == true || offlineFirst { findings.append(stale) } else { findings.insert(stale, at: 0) }
            } else {
                let pending = applicable.flatMap(\.reports).filter { $0.status == .pending }
                if !pending.isEmpty { add("Update declarations not applied yet", "\(pending.count) still pending on the device") }
                // only the declarations for the device's own OS (a Blueprint sends them for every platform)
                let own = pairs.filter { pair in pair.family.map { $0 == osName } ?? true }
                // Jamf sent a declaration the device hasn't fetched yet
                if let waiting = own.first(where: { $0.reports.contains { $0.status == .awaitingSync } }) {
                    add("New declaration not fetched yet",
                        "Jamf sent \(label(waiting)); the device hasn’t fetched it yet (awaiting sync). It fetches it at its next check-in")
                }
                // the refresh measured the device against the Blueprint's current declarations: that counts
                if row?.declarationsChecked == true {
                    if let ranges = row?.notCoveredBy, let version {
                        add("Jamf’s update doesn’t cover \(osName) \(version) yet",
                            "The Blueprint’s current update declarations for this hardware cover \(ranges), not \(version), so none "
                                + "applies. Jamf sets these ranges and can widen them; until it does, the device gets no update from this Blueprint")
                    } else if row?.notFetched == true, !findings.contains(where: { $0.cause == "New declaration not fetched yet" }) {
                        let last = row?.notFetchedSince.map { " The device last reported its declarations on \(day($0))." } ?? ""
                        add("Hasn’t fetched Jamf’s current declarations yet",
                            "One of the Blueprint’s current update declarations covers \(osName) \(os), but the device hasn’t fetched it."
                                + last + " It fetches it at its next check-in")
                    }
                } else if active.isEmpty && category != .onTarget {
                    // the device's own ID against the predicates' lists
                    let ids = [status?.deviceID ?? row?.boardID, modelID.isEmpty ? nil : modelID].compactMap { $0 }
                    let listing = own.filter { pair in ids.contains { pair.lists($0) } }
                    let idText = ids.first ?? "its model"
                    func ranges(_ pairs: [DeclarationPair]) -> [String] {
                        pairs.compactMap { $0.predicate.flatMap(DeclarationPair.versionRange).map { "\(osName) \($0)" } }
                    }
                    // the ranges of the device's own major that list this hardware all end below its version, and
                    // the Blueprint asks for a newer one: Jamf hasn't extended them yet
                    let sameMajor = listing.filter { $0.upperBound?.major == version?.major }
                    let below = !sameMajor.isEmpty && sameMajor.allSatisfy { pair in
                        guard let upper = pair.upperBound, let version else { return false }
                        return upper < version
                    }
                    if below, let version, let target, target > version {
                        // the ranges as the device last reported them: Jamf can widen them later
                        let when = mine.compactMap(\.lastReportTime).max().map { "When the device last reported, on \(day($0)), the" } ?? "The"
                        add("Jamf’s update doesn’t cover \(osName) \(version) yet",
                            "\(when) Blueprint’s update declarations for this hardware covered \(ranges(sameMajor).joined(separator: "; ")), "
                                + "not \(version), so none applied. Jamf sets these ranges and can widen them; until it does, the device "
                                + "gets no update from this Blueprint")
                    } else {
                        let ranges = ranges(listing)
                        let lists = listing.isEmpty
                            ? " No declaration lists \(idText), so the Blueprint doesn’t cover this hardware."
                            : " \(listing.count) list \(idText) (\(ranges.joined(separator: "; "))), so their version condition excludes \(osName) \(os)."
                        add("No update declaration applies",
                            "None of \(ctx.blueprintName)’s \(own.count) update \(own.count == 1 ? "declaration" : "declarations") "
                                + "for \(osName) applies to \(osName) \(os)."
                                + (own.contains { $0.predicate != nil } ? lists : ""))
                    }
                } else if active.count > 1 {
                    add("Several update declarations active", active.map(label).joined(separator: "; ") + " all apply to \(osName) \(os)")
                }
                for pair in applicable {
                    for report in pair.reports {
                        if report.validity == .invalid {
                            add("Update declaration invalid", "\(label(pair)): \(why(report, names: [ctx.blueprintID.lowercased(): ctx.blueprintName]))")
                        } else if report.reasons.contains(where: { ($0.code ?? "").hasPrefix("Error.") }) {
                            add("Update declaration failed", "\(label(pair)): \(why(report, names: [ctx.blueprintID.lowercased(): ctx.blueprintName]))")
                        }
                    }
                }
            }

            if let version, let target, target.major > version.major,
               let next = majors.filter({ $0 > version.major }).min(),
               supports(modelID.isEmpty ? nil : modelID, status?.deviceID, next) == false {
                add("Hardware can’t run the next version", "\(modelID.isEmpty ? status?.deviceID ?? "This model" : modelID) isn’t supported by \(osName) \(next)")
            }
            // the device still holds a deadline from before the Blueprint changed or Apple posted the version
            if let reason = row?.staleReason,
               let stale = row?.staleReportedDeadline.map(day) ?? row?.staleReportedLocal.flatMap(localDay) {
                let since = row?.staleSince.map { " (\(day($0)))" } ?? ""
                let current = DeadlineZones.text(local: row?.deadlineLocal, reported: nil).map { "; the Blueprint’s deadline is \($0)" } ?? ""
                switch reason {
                case .blueprintChanged:
                    add("Declaration not refreshed since the Blueprint changed",
                        "The device still reports the deadline \(stale) from before the Blueprint’s last change\(since)\(current). "
                            + "It takes the current declaration at its next check-in")
                case .posted:
                    add("Deadline reported before Apple posted this version",
                        "The device still reports the deadline \(stale) from before Apple posted this version publicly\(since)\(current). "
                            + "It takes the current deadline at its next check-in")
                }
            }
            // stuck only when a downloaded update didn't install after its
            // deadline; before it, prepared is normal; never for a device offline
            let offline = category == .offline
                || member.lastSeen.map { ctx.now.timeIntervalSince($0) > Double(ctx.staleDays) * 86_400 } ?? false
            // an install state for a version the device already runs is left over from that install
            let pendingIsNewer = status?.pendingVersion?.osVersion.flatMap(OSVersion.init).map { pending in
                version.map { pending > $0 } ?? true
            } ?? true
            if let state = status?.installState, state.isBusy, pendingIsNewer, let updated, !offline {
                let pendingVersion = status?.pendingVersion?.osVersion ?? "?"
                // past the deadline that counts (the rule’s, for a stale report), as the row says
                if state == .prepared && row?.pastDeadlineByGrace(now: ctx.now) == true {
                    add("Update stuck", "\(osName) \(pendingVersion) is downloaded but not installed after its deadline (last change \(ago(updated, now: ctx.now))); a restart of the device usually gets it going")
                } else if state == .prepared && row?.pastDeadline == true {
                    add("Update downloaded", "\(osName) \(pendingVersion) is downloaded; the deadline has just passed, so it installs now")
                } else if state == .prepared {
                    add("Update downloaded", "\(osName) \(pendingVersion) is downloaded and installs at the deadline")
                } else if state == .installing, ctx.now.timeIntervalSince(updated) > TargetRules.longInstall {
                    let hours = Int(TargetRules.longInstall / 3_600)
                    if member.lastSeen.map({ $0 >= updated.addingTimeInterval(TargetRules.laterContact) }) == true {
                        // a current install that doesn't finish comes first
                        findings.insert(Finding(cause: "Installing for more than \(hours) hours",
                                                detail: "\(osName) \(pendingVersion) has been installing since \(moment(updated)); the device "
                                                    + "checks in with Jamf but hasn’t reported a new status. A restart of the device usually finishes it"),
                                        at: 0)
                    } else {
                        add("Update in progress", "Installing \(osName) \(pendingVersion) since \(moment(updated)); no contact since it started installing")
                    }
                } else {
                    add("Update in progress", "\(DeviceDetailText.installState(state.rawValue)) \(osName) \(pendingVersion), last change \(ago(updated, now: ctx.now))")
                }
            }
            // this Blueprint's earlier step, sent before Apple posted the version its rule now gives
            if let step = row?.earlierStepVersion, let target = row?.targetVersion {
                let due = DeadlineZones.text(local: row?.deadlineLocal, reported: row?.deadlineDate).map { ", due \($0)" } ?? ""
                if row?.earlierStepLapsed == true {
                    let stepDue = DeadlineZones.text(local: row?.earlierStepLocal, reported: row?.earlierStepDeadline).map { " (\($0))" } ?? ""
                    add("Earlier step past its deadline",
                        "\(osName) \(step), an earlier step of this Blueprint, wasn’t installed by its deadline\(stepDue); "
                            + "\(target) follows\(due)")
                } else {
                    add("Earlier step of this Blueprint",
                        "\(osName) \(step) was sent before Apple posted \(target); the device installs \(step) first, then \(target)\(due)")
                }
            }
            // the target pending with the deadline of this Blueprint's earlier step
            if let step = row?.carriedStepVersion, let target = row?.targetVersion,
               let held = DeadlineZones.text(local: row?.carriedDeadlineLocal, reported: row?.carriedDeadline) {
                let due = DeadlineZones.text(local: row?.deadlineLocal, reported: row?.deadlineDate).map { "; the Blueprint’s deadline for \(target) is \($0)" } ?? ""
                let passed = (row?.carriedDeadline ?? TargetRules.deadlineDate(row?.carriedDeadlineLocal,
                                                                               timeZone: row?.timeZone ?? TimeZone.current.identifier))
                    .map { $0 <= ctx.now } ?? false
                add("Earlier step’s deadline kept",
                    "The device has \(osName) \(target) pending with the deadline of \(step), an earlier step of this Blueprint (\(held))\(due)"
                        + (passed ? ". As that deadline has passed, the device can install \(target) before the Blueprint’s deadline" : ""))
            }
            if category == .notStarted, status?.installState == JamfPro.SoftwareUpdateStatus.InstallState.none,
               status?.pendingVersion == nil, status?.failure == nil {
                add("Idle: no update pending, no error", "The device reports nothing pending and no error")
            }
            // the device's own update error ranks above the hints from its inventory below
            if let failTime = status?.failure?.timestamp, let failAt = JamfPro.serverDate(failTime, timeZone: ctx.serverTimeZone),
               since.map({ failAt >= $0 }) ?? true {
                let reason = Classifier.shortError(status?.failure?.reason)
                let count = status?.failure?.count.map { "\($0) \($0 == 1 ? "failure" : "failures"), " } ?? ""
                add("Update error", "\(reason.isEmpty ? "No reason given" : reason) (\(count)last \(moment(failAt)))")
            }
            let errorBefore = earlierError(status, since: since, serverTimeZone: ctx.serverTimeZone)
            if let beta = status?.betaEnrollment, beta.range(of: "^(none|null|false)$", options: [.regularExpression, .caseInsensitive]) == nil {
                add("Enrolled in a beta program", "\(beta) (build \(status?.osBuild ?? member.osBuild ?? "?")): the device follows the beta channel, so the release update may not be offered. Unenroll it (Software Update settings: beta program not allowed) and update")
            }
            if let free = member.availableSpaceMB, free < ctx.minFreeSpaceMB {
                add("Low storage", "\(gigabytes(free)) GB free of \(member.capacityMB.map(gigabytes) ?? "?") GB")
            }
            if diagnosis.localizedCaseInsensitiveContains("passcode") {
                let present = (status?.passcodePresent ?? member.passcodePresent).map { $0 ? "yes" : "no" } ?? "?"
                add("Passcode", "Passcode present: \(present); the update installs once the passcode is entered on the device, or after it’s cleared")
            }
            if DeviceDetailText.batteryNeedsService(status?.batteryHealth ?? member.batteryHealth) {
                add("Battery needs service", "Battery health: service recommended")
            }
            // the battery matters only for an install: downloaded or installing, not a download
            let installing = status?.installState == .prepared || status?.installState == .installing
            // Apple's minimums (Help › Known Problems): 20% for a user-initiated install on iPhone
            // and iPad, 30% for an automatic one; Apple gives no figure for an enforced update. So
            // low only with a battery error or under 20%; under 30% an automatic install may wait
            let batteryError = [status?.failure?.reason, row?.error].compactMap { $0 }.joined(separator: " ")
                .range(of: "[Bb]attery", options: .regularExpression) != nil
            if batteryError {
                add("Low battery", "The device reported a battery error"
                    + (member.batteryLevel.map { " (\($0)% at the last inventory)" } ?? "") + "; it installs once it’s charged or on power")
            } else if installing, let level = member.batteryLevel, level < 20 {
                add("Low battery", "\(level)% at the last inventory, under the 20% Apple asks for to install an update")
            } else if installing, member.kind == .mobileDevice, let level = member.batteryLevel, level < 30 {
                add("Battery under the automatic minimum",
                    "\(level)% at the last inventory: an automatic install may wait for charging (Apple asks for 30% on iPhone and iPad)")
            }
            if member.roaming == true {
                add("Roaming on mobile data", "Updates are normally downloaded over Wi-Fi: check that the device has a Wi-Fi network")
            }
            if let updated, let contact = member.lastSeen, contact.timeIntervalSince(updated) > 2 * 86_400 {
                add("Update status not reported", "Last software update report \(day(updated)), last contact \(day(contact))")
            }
            // other declarations with a problem; those not for this device aren’t
            let otherPairs = DeclarationPair.pairs((reports ?? []).filter { $0.blueprintID != ctx.blueprintID.lowercased() })
                .filter { !$0.isNotForThisDevice }
            let others = otherPairs.flatMap(\.reports)
                .filter { $0.validity == .invalid || $0.reasons.contains(where: { ($0.code ?? "").hasPrefix("Error.") }) }
            for other in others.prefix(3) {
                add("Other declaration with a problem", "\(otherName(other)): \(why(other, names: [:]))"
                    + (other.validity == .invalid ? " (invalid)" : ""))
            }

            // a Mac’s bootstrap token: the likely cause when the error since the update started names it
            var namesBootstrap = false
            if member.kind == .computer {
                let tokenStatus = member.bootstrapTokenEscrowedStatus ?? row?.bootstrapToken
                let token = DeviceDetailText.bootstrap(tokenStatus)
                let error = [status?.failure?.reason, row?.error].compactMap { $0 }.joined(separator: " ")
                namesBootstrap = error.localizedCaseInsensitiveContains("bootstrap")
                let escrowed = tokenStatus?.uppercased() == "ESCROWED"
                // from before the update started, or without a time (the refresh doesn't count those either)
                let earlierToken = errorBefore != nil || status?.failure?.timestamp == nil || row?.errorSinceUpdate == false
                if namesBootstrap && !earlierToken {
                    findings.insert(Finding(cause: "Bootstrap token",
                                            detail: escrowed
                                                ? "The last error names the bootstrap token, although Jamf Pro reports it as escrowed. "
                                                    + "Check the token on the Mac (profiles status -type bootstraptoken)"
                                                : "The last error names the bootstrap token; Jamf Pro reports it as \(token.lowercased()). "
                                                    + "Without an escrowed bootstrap token the Mac can’t install an enforced update on its own"),
                                    at: 0)
                } else if namesBootstrap {
                    let when = errorBefore.map { " (\($0.when))" } ?? ""
                    findings.append(Finding(cause: "Earlier bootstrap token error",
                                            detail: "An error from before the update started\(when) names the bootstrap token; "
                                                + "Jamf Pro now reports the token as \(token.lowercased())",
                                            earlier: true))
                } else if (member.bootstrapTokenEscrowedStatus ?? row?.bootstrapToken)?.uppercased() == "NOT_ESCROWED",
                          let why = DeviceDetailText.notEscrowedWarning(
                              appleSilicon: DeviceDetailText.isAppleSilicon(model: modelID, boardID: status?.deviceID ?? row?.boardID)) {
                    // an Intel Mac updates without an escrowed token: nothing to report
                    add("Bootstrap token not escrowed", "Jamf Pro reports the bootstrap token as not escrowed. " + why)
                }
            }

            // an error from before the update started: listed last, never the likely cause
            if let errorBefore, !namesBootstrap {
                findings.append(Finding(cause: "Earlier update error",
                                        detail: "\(errorBefore.reason) (\(errorBefore.when), before the update started)", earlier: true))
            }

            // an update error is the likely cause only when the device isn't downloading or
            // installing, or the error is newer than its last install-state change; an older
            // error during an install says nothing about that install
            let failedAt = status?.failure?.timestamp.flatMap { JamfPro.serverDate($0, timeZone: ctx.serverTimeZone) }
            let working = status?.installState == .downloading || status?.installState == .installing
            let errorLeads = !working || (failedAt.flatMap { at in input.installStateChanged.map { at > $0 } } ?? false)
            if !errorLeads, let error = findings.firstIndex(where: { $0.cause == "Update error" }),
               findings.firstIndex(where: { $0.earlier != true }) == error, error + 1 < findings.count {
                findings.insert(findings.remove(at: error), at: error + 1)
            }
            // an update error since the update started ranks above what the declarations say
            if errorLeads, let error = findings.firstIndex(where: { $0.cause == "Update error" }),
               let declarations = findings.firstIndex(where: { finding in
                   ["Jamf’s update doesn’t cover", "Hasn’t fetched Jamf’s", "No update declaration applies", "Not evaluated since"]
                       .contains { finding.cause.hasPrefix($0) }
               }), declarations < error {
                findings.insert(findings.remove(at: error), at: declarations)
            }

            // on target: an update error from before it installed the target (it reported the version,
            // else the update started) belongs to an earlier install, so it isn't listed
            if category == .onTarget, let failedAt, let installed = input.osVersionChanged ?? since, failedAt < installed {
                let errorCauses: Set<String> = ["Update error", "Earlier update error", "Earlier bootstrap token error", "Bootstrap token"]
                findings.removeAll { errorCauses.contains($0.cause) }
            }

            // the Blueprint's declarations for this device's own platform, by name; the rest in one line
            let names = [ctx.blueprintID.lowercased(): ctx.blueprintName]
            let listed = Self.declarationLines(current: ctx.current, mine: pairs, osName: osName, version: version,
                                               ids: [status?.deviceID ?? row?.boardID, modelID.isEmpty ? nil : modelID].compactMap { $0 },
                                               names: names, label: label)
            return InspectResult(id: Reader.key(member), name: row?.name ?? member.name ?? "", serial: member.serialNumber ?? "",
                                 modelIdentifier: modelID, os: os, diagnosis: diagnosis, onTarget: category == .onTarget,
                                 findings: findings, declarations: listed.lines, otherDeclarations: listed.others)
        }

        /// The lines of Inspect’s declaration list: the Blueprint’s current
        /// declarations (from the refresh) for the device’s own platform, each
        /// with how it stands on the device (“Not fetched yet” without a report
        /// of it); those that don’t apply to it are counted instead. Pairs for the
        /// same range (one per hardware group) are one line. Without the current
        /// declarations, the device’s own report is listed the same way.
        public static func declarationLines(current: [BlueprintHealth.Current]?, mine: [DeclarationPair], osName: String, version: OSVersion?,
                                     ids: [String], names: [String: String],
                                     label: (DeclarationPair) -> String) -> (lines: [DeclarationLine], others: Int) {
            var lines: [DeclarationLine] = []
            var others = 0
            guard let current else {
                for pair in mine {
                    let state = pair.state(names: names)
                    if (pair.family.map { $0 != osName } ?? false) || state == "Not for this device" { others += 1 } else {
                        lines.append(DeclarationLine(name: label(pair), state: state))
                    }
                }
                return (BlueprintHealth.uniqueNames(lines), others)
            }
            var order: [String] = []
            var byName: [String: [BlueprintHealth.Current]] = [:]
            for declaration in current {
                if byName[declaration.name] == nil { order.append(declaration.name) }
                byName[declaration.name, default: []].append(declaration)
            }
            for name in order {
                let group = byName[name] ?? []
                let states = group.flatMap { declaration in mine.filter { $0.key == declaration.key }.map { $0.state(names: names) } }
                let applies = version.map { version in group.contains { $0.applies(osName: osName, ids: ids, version: version) != false } } ?? true
                if group.allSatisfy({ ($0.family.map { $0 != osName }) ?? false }) {
                    others += 1
                } else if let state = BlueprintHealth.deviceState(states) {
                    if state == "Not for this device" { others += 1 } else { lines.append(DeclarationLine(name: name, state: state)) }
                } else if applies {
                    lines.append(DeclarationLine(name: name, state: "Not fetched yet"))
                } else {
                    others += 1
                }
            }
            return (lines, others)
        }

        // MARK: Helpers

        /// A declaration that isn’t the tracked Blueprint’s, without its ID: “A
        /// declaration from another Blueprint”, else its readable name, else
        /// “Another declaration”.
        public static func otherName(_ report: JamfPlatform.DeclarationReport) -> String {
            if report.blueprintID != nil { return "A declaration from another Blueprint" }
            let readable = readableName(report.declarationIdentifier, names: [:])
            return readable.contains("‹ID›") || readable.isEmpty ? "Another declaration" : readable
        }

        /// The device’s update error when it is from before the update started.
        public static func earlierError(_ status: JamfPro.SoftwareUpdateStatus?, since: Date?,
                                 serverTimeZone: TimeZone) -> (reason: String, when: String)? {
            guard let failure = status?.failure, let since, let time = failure.timestamp,
                  let at = JamfPro.serverDate(time, timeZone: serverTimeZone), at < since else { return nil }
            let reason = Classifier.shortError(failure.reason)
            return (reason.isEmpty ? "No reason given" : reason, moment(at))
        }

        /// The reasons of a declaration, as text, without IDs or hashes: a
        /// Blueprint declaration is named by its Blueprint (`names`, by
        /// lowercased Blueprint ID) and number; identifiers, server tokens and
        /// predicates in the details are left out.
        public static func why(_ report: JamfPlatform.DeclarationReport, names: [String: String] = [:]) -> String {
            let skipped: Set<String> = ["identifier", "servertoken", "predicate"]
            let parts = report.reasons.map { reason -> String in
                var text = reason.code ?? ""
                let descriptions = reason.details.filter { !skipped.contains(($0.key ?? "").lowercased()) }
                    .compactMap(\.description).filter { !$0.isEmpty }
                if !descriptions.isEmpty { text += ": " + descriptions.map { readableName($0, names: names) }.joined(separator: "; ") }
                if let description = reason.description, !description.isEmpty, descriptions.isEmpty {
                    text += " (\(readableName(description, names: names)))"
                }
                return text
            }
            return parts.isEmpty ? "no reason given" : parts.joined(separator: "; ")
        }

        /// Text with every Blueprint declaration identifier
        /// (`Blueprint_<id>_s1_c1_sys_act12:<hash>`) replaced by “‹Blueprint›,
        /// update declaration 12” and other hashes removed.
        public static func readableName(_ text: String, names: [String: String]) -> String {
            let pattern = #/Blueprint_([0-9A-Fa-f-]{36})_s([0-9]+)_c[0-9]+_[A-Za-z]+_(cfg|act)?([0-9]*)(:[0-9A-Fa-f]+)?/#
            var out = text.replacing(pattern) { match in
                let name = names[String(match.output.1).lowercased()] ?? "another Blueprint"
                let number = String(match.output.4)
                return number.isEmpty ? "\(name), step \(match.output.2)" : "\(name), update declaration \(number)"
            }
            out = out.replacing(#/:[0-9A-Fa-f]{16,}/#, with: "")
            out = out.replacing(#/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/#, with: "‹ID›")
            return out
        }

        public static func ago(_ date: Date, now: Date) -> String {
            let minutes = Int((now.timeIntervalSince(date) / 60).rounded(.down))
            if minutes < 0 { return "just now" }
            if minutes < 120 { return "\(minutes) min ago" }
            if minutes <= 48 * 60 { return "\(minutes / 60) h ago" }
            let days = minutes / (24 * 60)
            return "\(days) days ago"
        }

        /// Megabytes as gigabytes with one decimal, as Jamf Pro counts them (1024).
        public static func gigabytes(_ megabytes: Int) -> String {
            ((Double(megabytes) / 1024 * 10).rounded() / 10).formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US_POSIX")))
        }

        /// A day as the app shows it everywhere: “28 Oct 2026”.
        public static func day(_ date: Date) -> String {
            date.formatted(date: .abbreviated, time: .omitted)
        }

        /// A local date-time without a zone (“2026-11-19T23:59:00”) as its day: “19 Nov 2026”.
        public static func localDay(_ local: String) -> String? {
            guard let date = JamfPlatform.SoftwareUpdateBlock.deadline(local, in: .gmt) else { return nil }
            var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            style.timeZone = .gmt
            return date.formatted(style)
        }

        /// A moment without its year, for a diagnosis: “23 Nov 23:59”.
        public static func dayTime(_ date: Date) -> String {
            date.formatted(.dateTime.day().month(.abbreviated)) + " " + date.formatted(date: .omitted, time: .shortened)
        }

        /// A moment as the app shows it everywhere: “9 Nov 2026 at 09:11”.
        public static func moment(_ date: Date) -> String {
            date.formatted(date: .abbreviated, time: .shortened)
        }
    }

    /// A Blueprint declaration’s configuration with its own activation
    /// (`…_sys_cfg12` with `…_sys_act12`), as the device reports them.
    public nonisolated struct DeclarationPair: Sendable, Hashable {
        public var key: String
        public var number: String?
        public var reports: [JamfPlatform.DeclarationReport]

        public var activation: JamfPlatform.DeclarationReport? { reports.first { $0.type == "ACTIVATION" } }

        /// Its activation’s predicate is false for this device (Info.Predicate):
        /// meant for other versions or models, by design.
        public var isNotForThisDevice: Bool {
            activation?.reasons.contains { ($0.code ?? "").hasPrefix("Info.Predicate") } == true
        }

        public var isActive: Bool { reports.contains { $0.active == true } }

        /// Whether its predicate lists this device ID or model (`IN {"J313AP", …}`).
        public func lists(_ id: String) -> Bool {
            predicate?.contains("\"\(id)\"") == true
        }

        /// The OS family the predicate asks for (`operating-system.family == "macOS"`); nil without one.
        public var family: String? { predicate.flatMap(Self.family(in:)) }

        /// The OS family a predicate asks for; nil without one. Both forms:
        /// `status.device.operating-system.family == "macOS"` and
        /// `@status(device.operating-system.family) == 'macOS'`.
        public static func family(in predicate: String) -> String? {
            predicate.firstMatch(of: #/operating-system\.family\)?\s*==\s*["']([^"']+)["']/#).map { String($0.output.1) }
        }

        /// The newest version the predicate’s version condition takes; nil without one.
        public var upperBound: OSVersion? { predicate.flatMap(Self.covered)?.max() }

        /// The predicate’s text, from the activation’s Info.Predicate reason.
        public var predicate: String? {
            activation?.reasons.flatMap(\.details).first { $0.key?.lowercased() == "predicate" }?.description
                ?? activation?.reasons.compactMap(\.description).first { $0.contains("predicate") }
        }

        /// “‹Blueprint›, macOS 26.0 to 26.7.1”: the versions it is for from its
        /// predicate; for the active one the device’s own major.
        public func label(blueprint: String, osName: String, deviceMajor: Int?) -> String {
            if let range = predicate.flatMap(Self.versionRange) { return "\(blueprint), \(osName) \(range)" }
            if isActive, let deviceMajor { return "\(blueprint), \(osName) \(deviceMajor) (applies to this device)" }
            // a step for one OS family, without a version condition
            if let family { return "\(blueprint), \(family)" }
            return number.map { "\(blueprint), update declaration \($0)" } ?? blueprint
        }

        /// How this device stands with the pair, in plain words: not for it,
        /// applied, pending, awaiting sync, failed or invalid (with the reason).
        public func state(names: [String: String]) -> String {
            if isNotForThisDevice { return "Not for this device" }
            let configuration = reports.first { $0.type == "CONFIGURATION" } ?? reports.first
            guard let report = configuration else { return "Not reported" }
            if reports.contains(where: { $0.validity == .invalid }) {
                return "Invalid: " + InspectFindings.why(reports.first { $0.validity == .invalid } ?? report, names: names)
            }
            if let failed = reports.first(where: { $0.reasons.contains { ($0.code ?? "").hasPrefix("Error.") } }) {
                return "Failed: " + InspectFindings.why(failed, names: names)
            }
            switch report.status {
            case .successful: return "Applied"
            case .pending: return "Pending"
            case .awaitingSync: return "Awaiting sync"
            case .unsuccessful: return "Not applied"
            case .unknown, .other: return "Unknown"
            }
        }

        /// The versions a predicate’s `MATCHES "^(26[.][0-6]([.][0-9]+)*|26[.]7([.][0-1]([.][0-9]+)*)?)$"`
        /// takes, to the patch: “26.0 to 26.7.1”; “27.0 to 27.1.x” when the last
        /// minor takes every patch; “26.7.x” for one minor; “26.7.1” for one
        /// version; “26.7 and later” without an upper end; “27” for a whole
        /// major. Read by trying versions against the condition itself.
        public static func versionRange(_ predicate: String) -> String? {
            guard let covered = covered(predicate) else {
                // the older form: version BEGINSWITH "27." AND version < "27.0.1" (or <=)
                guard let major = predicate.firstMatch(of: #/BEGINSWITH\s*"([0-9]+)\./#)?.output.1 else { return nil }
                if let bound = predicate.firstMatch(of: #/version\s*(<=?)\s*"([0-9.]+)"/#) {
                    return bound.output.1 == "<=" ? "\(major) up to \(bound.output.2)" : "\(major) below \(bound.output.2)"
                }
                return String(major)
            }
            guard let low = covered.min(), let high = covered.max(), let matches = matcher(predicate) else { return nil }
            let major = low.major
            // no upper end within the major
            if matches("\(major).\(maxMinor)") {
                return low.minor == 0 && low.patch == 0 ? "\(major)" : "\(low) and later"
            }
            // the last minor takes every patch: “.x”
            let openEnded = matches("\(major).\(high.minor).\(maxPatch)")
            let highText = openEnded ? "\(major).\(high.minor).x" : high.description
            if openEnded && low == OSVersion(major: major, minor: high.minor) { return highText }
            // the lowest version as itself: 26.0, or 26.5.1 for a range that starts at a patch
            let lowText = low.patch == 0 ? "\(major).\(low.minor)" : low.description
            return lowText == highText ? lowText : "\(lowText) to \(highText)"
        }

        private static let maxMinor = 40
        private static let maxPatch = 30

        /// Whether a version text meets a predicate’s `MATCHES "…"` condition; nil without one.
        public static func matcher(_ predicate: String) -> ((String) -> Bool)? {
            guard let pattern = predicate.firstMatch(of: #/MATCHES\s*"([^"]+)"/#)?.output.1,
                  let regex = try? NSRegularExpression(pattern: String(pattern)) else { return nil }
            // MATCHES takes the whole text, as in a predicate
            return { text in
                let whole = NSRange(text.startIndex..., in: text)
                return regex.firstMatch(in: text, range: whole)?.range == whole
            }
        }

        /// Every version (major.minor and major.minor.patch) the condition
        /// takes in its major; nil without a `MATCHES` condition.
        public static func covered(_ predicate: String) -> [OSVersion]? {
            guard let matches = matcher(predicate),
                  let pattern = predicate.firstMatch(of: #/MATCHES\s*"([^"]+)"/#)?.output.1,
                  let major = pattern.firstMatch(of: #/([0-9]+)/#).flatMap({ Int($0.output.1) }) else { return nil }
            var versions: [OSVersion] = []
            for minor in 0...maxMinor {
                for patch in [nil] + Array(0...maxPatch) {
                    let text = patch.map { "\(major).\(minor).\($0)" } ?? "\(major).\(minor)"
                    if matches(text), let version = OSVersion(text) { versions.append(version) }
                }
            }
            return versions
        }

        /// The reports grouped into pairs, in number order; a declaration whose
        /// identifier has no number is a pair of its own.
        public static func pairs(_ reports: [JamfPlatform.DeclarationReport]) -> [DeclarationPair] {
            var order: [String] = []
            var byKey: [String: DeclarationPair] = [:]
            for report in reports {
                let match = report.declarationIdentifier.firstMatch(of: #/^(.*_s[0-9]+_c[0-9]+_[A-Za-z]+_)(?:cfg|act)([0-9]+)$/#)
                let key = match.map { "\($0.output.1)\($0.output.2)" } ?? report.declarationIdentifier
                if byKey[key] == nil {
                    order.append(key)
                    byKey[key] = DeclarationPair(key: key, number: match.map { String($0.output.2) }, reports: [])
                }
                byKey[key]?.reports.append(report)
            }
            return order.compactMap { byKey[$0] }.sorted { (Int($0.number ?? "") ?? 0) < (Int($1.number ?? "") ?? 0) }
        }

        /// Every stored property, in order, with the same defaults as the memberwise initializer.
        public init(
            key: String,
            number: String? = nil,
            reports: [JamfPlatform.DeclarationReport]
        ) {
            self.key = key
            self.number = number
            self.reports = reports
        }
    }

    /// Texts the device detail and Inspect share.
    public nonisolated enum DeviceDetailText {
        /// Why a target shows in orange: the model can’t run the version the
        /// Blueprint’s rule gives, so it is measured against the newest it can.
        public static func hardwareLimit(_ device: DeviceStatus) -> String {
            "This model can’t run the \(device.osName) version the Blueprint asks for, so it is measured against the newest it can run; "
                + "it is on the hardware to replace"
        }

        /// The pending version, said to be ignored when the device already runs it or a newer one.
        public static func pendingVersion(_ device: DeviceStatus) -> String {
            guard let pending = device.pendingVersion else { return "–" }
            if let version = OSVersion(pending), let current = OSVersion(device.currentOS), version <= current {
                return "\(pending) (already installed, ignored)"
            }
            return pending
        }

        /// A Mac’s bootstrap token as Jamf Pro reports it.
        public static func bootstrap(_ status: String?) -> String {
            switch status?.uppercased() {
            case "ESCROWED": "Escrowed"
            case "NOT_ESCROWED": "Not escrowed"
            case "NOT_SUPPORTED": "Not supported"
            case nil: "Not reported"
            default: status ?? "Not reported"
            }
        }

        /// “3, last 9 Nov 2026 at 10:00”: the failure count and when it last
        /// failed, in this Mac’s time. With no failures, no date: “0”. Nil
        /// without either.
        public static func failures(count: Int?, time: String?, serverTimeZone: TimeZone) -> String? {
            if count == 0 { return "0" }
            let when = time.flatMap { JamfPro.serverDate($0, timeZone: serverTimeZone) }
                .map { "last \($0.formatted(date: .abbreviated, time: .shortened))" }
            let parts = [count.map(String.init), when].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }

        /// A beta program as the device names it; nil when it is in none.
        public static func betaProgram(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: "^(none|null|false|)$", options: [.regularExpression, .caseInsensitive]) == nil ? trimmed : nil
        }

        /// A Mac’s FileVault: “On”, “Off”, “Encrypting”, “Decrypting”; “Not
        /// reported” without a value.
        public static func fileVault(_ state: String?) -> String {
            switch state?.uppercased() {
            case "ENCRYPTED": "On"
            case "UNENCRYPTED", "DECRYPTED": "Off"
            case "ENCRYPTING": "Encrypting"
            case "DECRYPTING": "Decrypting"
            case nil, "", "UNKNOWN": "Not reported"
            default: words(state ?? "")
            }
        }

        /// Battery health as words, whichever way it was written: `NORMAL` and
        /// `normal` read “Normal”, `service-recommended` and
        /// `SERVICE_RECOMMENDED` “Service recommended”.
        public static func batteryHealth(_ health: String?) -> String {
            guard let health, !health.isEmpty else { return "Not reported" }
            return words(health)
        }

        /// Whether the battery needs service, however it was written.
        public static func batteryNeedsService(_ health: String?) -> Bool {
            words(health ?? "") == "Service recommended"
        }

        /// Why the pending update was started, in plain words: `declaration`
        /// “A declaration”, `mdm` “An MDM command”, `system-settings` “Software
        /// Update settings on the device”; others as words.
        public static func installReason(_ reasons: String?) -> String {
            guard let reasons, !reasons.isEmpty else { return "–" }
            return reasons.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.map { reason in
                switch reason.lowercased() {
                case "declaration": "A declaration"
                case "mdm": "An MDM command"
                case "system-settings": "Software Update settings on the device"
                default: words(reason)
                }
            }.joined(separator: "; ")
        }

        /// `SERVICE_RECOMMENDED` or `service-recommended` as “Service recommended”.
        public static func words(_ text: String) -> String {
            let spaced = text.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").lowercased()
            return spaced.prefix(1).uppercased() + spaced.dropFirst()
        }

        /// An install state as a capitalized word: “Failed”, “None”; “–” when
        /// there is none.
        public static func installState(_ state: String?) -> String {
            guard let state, let first = state.first else { return "–" }
            return first.uppercased() + state.dropFirst()
        }

        /// Whether a Mac has Apple silicon: by its model identifier first
        /// (“Mac14,2”, “MacBookPro18,3” yes; “MacBookPro16,1” no). The board ID
        /// from its status report only when the model says nothing, and only
        /// for what it proves: `X86LEGACYAP`, `VMM-x86_64` and “Mac-…” are Intel.
        /// A “J…AP” board alone says nothing: Intel Macs with a T2 chip report
        /// such boards too (“J152FAP”). Nil when nothing tells.
        public static func isAppleSilicon(model: String?, boardID: String?) -> Bool? {
            if let model, let match = model.firstMatch(of: #/^([A-Za-z]+)(\d+),\d+$/#), let generation = Int(match.2) {
                // the first generation of each family with Apple silicon
                let first: [String: Int] = ["Mac": 13, "VirtualMac": 2, "MacBookAir": 10, "MacBookPro": 17, "Macmini": 9, "iMac": 21]
                if let from = first[String(match.1)] { return generation >= from }
                // iMacPro, MacPro (up to 7,1) and the older MacBook are Intel
                if ["iMacPro", "MacPro", "MacBook"].contains(String(match.1)) { return false }
            }
            guard let board = boardID?.trimmingCharacters(in: .whitespaces).uppercased(), !board.isEmpty else { return nil }
            if board == "X86LEGACYAP" || board == "VMM-X86_64" || board.hasPrefix("MAC-") { return false }
            return nil
        }

        /// Why a bootstrap token that isn’t escrowed matters: only on a Mac with
        /// Apple silicon, where an enforced update needs it to install on its
        /// own. Nil for an Intel Mac; said as a condition when the chip isn’t known.
        public static func notEscrowedWarning(appleSilicon: Bool?) -> String? {
            switch appleSilicon {
            case true?: "Without an escrowed bootstrap token, this Mac with Apple silicon can’t install an enforced update on its own: it waits for a user to approve it."
            case false?: nil
            case nil: "On a Mac with Apple silicon, an enforced update can’t install on its own without an escrowed bootstrap token: it waits for a user to approve it."
            }
        }
    }
}
