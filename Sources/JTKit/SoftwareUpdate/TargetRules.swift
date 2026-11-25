import Foundation

extension SoftwareUpdateRules {
    /// Where a device’s deadline comes from.
    public nonisolated enum DeadlineSource: String, Sendable, Hashable, Codable {
        /// The device reports it with its pending update: always wins.
        case reported
        /// The Blueprint names it (a specific version).
        case blueprint
        /// Apple’s public posting date (GDMF `PublicAssetSets`) plus the delay, as Jamf counts it:
        /// the first one this app saw of the build, else today’s.
        case postingDate
        /// The posting date the Blueprint’s other devices report Jamf counted
        /// from (`PostingBasis.reported`) plus the delay.
        case otherDevices
        /// The posting date the Blueprint’s devices reported Jamf counted from
        /// in an earlier refresh, remembered while the version is the rule’s
        /// target (`ReportedDeadlines`), plus the delay.
        case rememberedFromDevices
        /// No public posting date found: the first release date plus the delay.
        case releaseDate
        /// The device reports it, but from before the Blueprint’s last change
        /// or Apple’s posting of the version, and the rule gives none of its own.
        case reportedBeforeChange, reportedBeforePosting

        public var text: String {
            switch self {
            case .reported: "Reported by the device"
            case .blueprint: "Set in the Blueprint"
            case .postingDate: "From Apple’s posting date"
            case .otherDevices: "As the Blueprint’s other devices report it"
            case .rememberedFromDevices: "As the Blueprint’s devices reported it earlier"
            case .releaseDate: "From the release date, no posting date found"
            case .reportedBeforeChange: "Reported by the device before the Blueprint’s last change; may be out of date"
            case .reportedBeforePosting: "Reported by the device before Apple posted this version; may be out of date"
            }
        }
    }

    /// What a device’s report of its pending update predates, so its deadline
    /// may not be the current one.
    public nonisolated enum StaleReason: String, Sendable, Hashable, Codable {
        /// The Blueprint changed after the report.
        case blueprintChanged
        /// Apple posted the version publicly after the report.
        case posted

        /// “reported before the Blueprint’s last change”.
        public var text: String {
            switch self {
            case .blueprintChanged: "reported before the Blueprint’s last change"
            case .posted: "reported before Apple posted this version"
            }
        }
    }

    /// Why a device has no target. Such a device is never measured: it is
    /// shown as “Target unknown” with this reason.
    public nonisolated enum TargetUnknown: String, Sendable, Hashable, Codable, CaseIterable {
        /// Apple’s release data couldn’t be read.
        case appleDataUnreachable
        /// The Blueprint has no software update for this device.
        case noSoftwareUpdate
        /// The Blueprint’s software update is one this app can’t read.
        case unreadableUpdate
        /// Apple’s release data has no release for the device’s platform or major.
        case noReleaseForPlatform
        /// The device runs a beta of a major newer than Apple’s newest release.
        case betaOfNewerMajor
        /// The device reports no OS version, and the rule depends on it.
        case noReportedVersion
        /// The device already runs a release Apple shipped to it that is newer
        /// than the rule’s target: the rule doesn’t fit this device.
        case runsNewerRelease
    }

    /// The version one device is measured against, and from when.
    public nonisolated struct DeviceTarget: Sendable, Hashable, Codable {
        /// Nil when there is no target (unknown, or nothing this hardware can run).
        public var version: String?
        public var build: String?
        /// Apple’s release date of the target, for a Blueprint that follows Apple’s releases.
        public var released: Date?
        /// Status reports and errors before this don’t count: the target’s
        /// release date, the Blueprint’s last change for a specific version,
        /// or the “Update started” date set by hand.
        public var activityFrom: Date?
        /// The deadline in the device’s local time, without a zone (`2026-11-23T17:00:00`).
        public var deadlineLocal: String?
        /// Where the deadline comes from.
        public var deadlineSource: DeadlineSource?
        /// Why this is the target, in plain language.
        public var reason: String
        /// A newer major release exists that this model can’t run: measured
        /// against the newest it can, and listed among the hardware to replace.
        public var limitedByHardware = false
        /// No release applies to this hardware at all: the device is unsupported.
        public var noApplicableRelease = false
        /// `activityFrom` is the “Update started” date set by hand.
        public var startSetByHand = false
        /// Set when there is no target; `reason` says it in plain language.
        public var unknown: TargetUnknown?
        /// The target is the version the device reports pending from a
        /// declaration: what Jamf actually sent it.
        public var fromDevice = false
        /// With `fromDevice`: what the Blueprint’s rule gives, and why.
        public var ruleVersion: String?
        public var ruleReason: String?
        /// With `fromDevice`: the rule gives another version (or none), so
        /// another declaration may be enforcing this one.
        public var differsFromRule = false
        /// The Blueprint names this version itself (a specific version): what
        /// Jamf sends, not a reading of Apple’s data.
        public var namedByBlueprint = false
        /// Nothing in the device’s major is public yet: held to what it runs.
        public var heldToCurrent = false
        /// The deadline as a moment, when the device reported it with an offset.
        public var deadlineDate: Date?
        /// That offset from UTC, in seconds.
        public var deadlineOffset: Int?
        /// A deadline the device reported before the Blueprint’s last change (or
        /// before Apple’s public posting of the version): kept to show, never
        /// used; the rule’s deadline counts.
        public var staleReportedDeadline: Date?
        /// The same written as a local date-time without an offset (the
        /// device’s local time), when the report gave no moment.
        public var staleReportedLocal: String?
        /// The change it predates: the later of the Blueprint’s last change and the posting.
        public var staleSince: Date?
        /// Which of the two that is.
        public var staleReason: StaleReason?
        /// This Blueprint’s earlier step: a version it sent before Apple posted
        /// the newer one its rule now gives, still pending on the device. The
        /// rule’s version and deadline count; this one is shown, not counted.
        public var earlierStepVersion: String?
        /// That step’s deadline as the device reports it: a moment, or its
        /// local date-time when the report gave no offset.
        public var earlierStepDeadline: Date?
        public var earlierStepLocal: String?
        /// The step’s own deadline (plus the grace an install gets) has passed
        /// and it isn’t installing: the target stays the rule’s, and the device
        /// counts as past the step’s deadline.
        public var earlierStepLapsed = false
        /// The device has the rule’s own version pending, but with the deadline
        /// of this Blueprint’s earlier step: Jamf moved the declaration to the
        /// newer version and the device kept the step’s deadline. Shown, not
        /// counted: the rule’s deadline counts.
        public var carriedStepVersion: String?
        /// That deadline as the device reports it: a moment, or its local
        /// date-time when the report gave no offset.
        public var carriedDeadline: Date?
        public var carriedDeadlineLocal: String?
        /// A time the device reports for the rule’s version after the
        /// Blueprint’s deadline passed, that isn’t that deadline: when it tries
        /// to install next (a Mac sets one after a missed deadline). Shown, not
        /// counted: the Blueprint’s deadline counts. A moment, or its local
        /// date-time when the report gave no offset.
        public var nextInstallAttempt: Date?
        public var nextInstallAttemptLocal: String?

        public var osVersion: OSVersion? { version.flatMap(OSVersion.init) }

        /// Where the target comes from, for the gray line under the version in
        /// the device detail: “Sent by Jamf, matches the Blueprint’s rule”,
        /// “From Apple’s data and the Blueprint’s rule”. Nil without a target
        /// (the reason says why).
        var source: String? {
            guard version != nil, unknown == nil else { return nil }
            if fromDevice {
                return differsFromRule ? "Sent by Jamf: the device reports it pending from a declaration"
                    : "Sent by Jamf, matches the Blueprint’s rule"
            }
            if namedByBlueprint { return "The version the Blueprint names" }
            if heldToCurrent { return "No public release of its major yet, so it stays on the version it runs" }
            if limitedByHardware { return "From Apple’s data: the newest release this model can run" }
            return "From Apple’s data and the Blueprint’s rule"
        }

        /// Every stored property, in order, with the same defaults as the memberwise initializer.
        public init(
            version: String? = nil,
            build: String? = nil,
            released: Date? = nil,
            activityFrom: Date? = nil,
            deadlineLocal: String? = nil,
            deadlineSource: DeadlineSource? = nil,
            reason: String,
            limitedByHardware: Bool = false,
            noApplicableRelease: Bool = false,
            startSetByHand: Bool = false,
            unknown: TargetUnknown? = nil,
            fromDevice: Bool = false,
            ruleVersion: String? = nil,
            ruleReason: String? = nil,
            differsFromRule: Bool = false,
            namedByBlueprint: Bool = false,
            heldToCurrent: Bool = false,
            deadlineDate: Date? = nil,
            deadlineOffset: Int? = nil,
            staleReportedDeadline: Date? = nil,
            staleReportedLocal: String? = nil,
            staleSince: Date? = nil,
            staleReason: StaleReason? = nil,
            earlierStepVersion: String? = nil,
            earlierStepDeadline: Date? = nil,
            earlierStepLocal: String? = nil,
            earlierStepLapsed: Bool = false,
            carriedStepVersion: String? = nil,
            carriedDeadline: Date? = nil,
            carriedDeadlineLocal: String? = nil,
            nextInstallAttempt: Date? = nil,
            nextInstallAttemptLocal: String? = nil
        ) {
            self.version = version
            self.build = build
            self.released = released
            self.activityFrom = activityFrom
            self.deadlineLocal = deadlineLocal
            self.deadlineSource = deadlineSource
            self.reason = reason
            self.limitedByHardware = limitedByHardware
            self.noApplicableRelease = noApplicableRelease
            self.startSetByHand = startSetByHand
            self.unknown = unknown
            self.fromDevice = fromDevice
            self.ruleVersion = ruleVersion
            self.ruleReason = ruleReason
            self.differsFromRule = differsFromRule
            self.namedByBlueprint = namedByBlueprint
            self.heldToCurrent = heldToCurrent
            self.deadlineDate = deadlineDate
            self.deadlineOffset = deadlineOffset
            self.staleReportedDeadline = staleReportedDeadline
            self.staleReportedLocal = staleReportedLocal
            self.staleSince = staleSince
            self.staleReason = staleReason
            self.earlierStepVersion = earlierStepVersion
            self.earlierStepDeadline = earlierStepDeadline
            self.earlierStepLocal = earlierStepLocal
            self.earlierStepLapsed = earlierStepLapsed
            self.carriedStepVersion = carriedStepVersion
            self.carriedDeadline = carriedDeadline
            self.carriedDeadlineLocal = carriedDeadlineLocal
            self.nextInstallAttempt = nextInstallAttempt
            self.nextInstallAttemptLocal = nextInstallAttemptLocal
        }
    }

    /// What a computed deadline counts from besides Apple’s public posting of
    /// today. Apple can re-date a build that is already public (its public
    /// posting moves, its first posting stays); Jamf keeps the deadline it sent.
    public nonisolated struct PostingBasis: Sendable, Hashable {
        /// The posting date Jamf counted from, as the Blueprint’s devices report
        /// it (`TargetRules.reportedPosting`), per platform and version: Jamf
        /// sends one declaration per Blueprint and version.
        public var reported: [String: Date] = [:]
        /// The same from earlier refreshes of this tracked Blueprint, per
        /// platform and version, kept while the version is the rule’s target
        /// (`ReportedDeadlines`): it keeps counting after the devices that
        /// reported it have installed.
        public var rememberedReported: [String: Date] = [:]
        /// The deadlines the Blueprint’s devices reported for a version from
        /// one of its posting dates, as moments to the minute (minutes since
        /// 1970), per platform and version: this refresh’s and those remembered.
        /// A Mac’s earlier step is recognized by these only.
        public var reportedMinutes: [String: Set<Int>] = [:]
        /// The first public posting date this app saw, per platform, version
        /// and build (`FirstPostings`).
        public var remembered: [String: Date] = [:]

        /// A moment to the minute, as `reportedMinutes` keeps it.
        public static func minute(_ date: Date) -> Int { Int((date.timeIntervalSince1970 / 60).rounded(.down)) }

        public static func key(_ platform: AppleReleases.Platform, _ version: OSVersion) -> String {
            "\(platform.rawValue)|\(version)"
        }

        public static func key(_ platform: AppleReleases.Platform, _ version: OSVersion, build: String?) -> String {
            "\(platform.rawValue)|\(version)|\(build ?? "")"
        }

        /// Every stored property, in order, with the same defaults as the memberwise initializer.
        public init(
            reported: [String: Date] = [:],
            rememberedReported: [String: Date] = [:],
            reportedMinutes: [String: Set<Int>] = [:],
            remembered: [String: Date] = [:]
        ) {
            self.reported = reported
            self.rememberedReported = rememberedReported
            self.reportedMinutes = reportedMinutes
            self.remembered = remembered
        }
    }

    /// What a Blueprint’s software update means for one device. Jamf’s
    /// reference (Platform API, Blueprint schema) has three settings: a specific
    /// version by a deadline (`MANUAL`, no delay); the newest release, a number
    /// of days (0–30) after Apple releases it, at a time of day (`AUTOMATIC`,
    /// `LATEST`, across majors); and minor updates within the device’s own major,
    /// days after release, at a time of day (`AUTOMATIC`, `SEMANTIC`, rule
    /// `minor`). Apple’s own declaration in a custom-declarations component is
    /// a specific version, optionally with a build.
    public nonisolated enum TargetRules {
        /// After its deadline a downloaded update gets this long to install
        /// before it is called stuck: devices start installing at the deadline.
        public static let installGrace: TimeInterval = 4 * 3_600
        /// Installing for longer than this while the device keeps checking in:
        /// pointed out (a minor update installs well within an hour).
        public static let longInstall: TimeInterval = 4 * 3_600
        /// A contact counts as a later check-in only this long after the status
        /// report: a single check-in writes both, a few seconds from each other.
        public static let laterContact: TimeInterval = 30 * 60

        public struct Context: Sendable {
            public var block: JamfPlatform.SoftwareUpdateBlock?
            public var catalog: AppleReleases.Catalog?
            public var platform: AppleReleases.Platform
            /// When the Blueprint last changed: the start for a specific version.
            public var blueprintChanged: Date?
            /// The “Update started” date set by hand; overrides the computed start.
            public var updateStarted: Date?
            public var now: Date
            /// What deadlines count from before today’s public posting.
            public var known = PostingBasis()

            /// Every stored property, in order, with the same defaults as the memberwise initializer.
            public init(
                block: JamfPlatform.SoftwareUpdateBlock? = nil,
                catalog: AppleReleases.Catalog? = nil,
                platform: AppleReleases.Platform,
                blueprintChanged: Date? = nil,
                updateStarted: Date? = nil,
                now: Date,
                known: PostingBasis = PostingBasis()
            ) {
                self.block = block
                self.catalog = catalog
                self.platform = platform
                self.blueprintChanged = blueprintChanged
                self.updateStarted = updateStarted
                self.now = now
                self.known = known
            }
        }

        public static func target(os: String?, model: String?, boardID: String?, osName: String, context ctx: Context) -> DeviceTarget {
            let current = os.flatMap(OSVersion.init)
            let model = model.flatMap { $0.isEmpty ? nil : $0 }
            var target: DeviceTarget
            switch ctx.block?.enforcement {
            case .specific(let text, let deadline, _)?:
                guard let version = OSVersion(text) else {
                    return DeviceTarget(reason: "The Blueprint asks for a version this app can’t read (\(text))", unknown: .unreadableUpdate)
                }
                let build = ctx.block?.targetBuildVersion ?? ctx.catalog?.build(of: version, ctx.platform)
                let canRun = ctx.catalog?.supports(model: model, boardID: boardID, major: version.major, ctx.platform)
                let below = current.map { $0 < version } ?? true
                target = DeviceTarget(version: version.description, build: build, activityFrom: ctx.blueprintChanged,
                                      deadlineLocal: deadline, deadlineSource: deadline == nil ? nil : .blueprint,
                                      reason: "The Blueprint asks for \(osName) \(version)" + (deadline.map { " by \(readable($0))" } ?? ""),
                                      namedByBlueprint: true)
                if canRun == false && below {
                    target.noApplicableRelease = true
                    target.reason = "This model can’t run \(osName) \(version.major), which the Blueprint asks for"
                }
            case .latest(let days, let time)?:
                target = latest(current, days: days ?? 0, time: time, model: model, boardID: boardID, osName: osName, ctx)
            case .semantic(let days, let time)?:
                target = minor(current, days: days ?? 0, time: time, model: model, boardID: boardID, osName: osName, ctx)
            case .unknown?:
                return DeviceTarget(reason: "The Blueprint’s software update is a kind this app doesn’t read", unknown: .unreadableUpdate)
            case nil:
                return DeviceTarget(reason: "The Blueprint has no software update for \(osName)", unknown: .noSoftwareUpdate)
            }
            if target.unknown != nil { return target }
            if let started = ctx.updateStarted {
                target.activityFrom = started
                target.startSetByHand = true
            }
            return target
        }

        /// `LATEST`: the newest release Apple offers publicly, across majors,
        /// that the model can run; due `days` after its public posting.
        private static func latest(_ current: OSVersion?, days: Int, time: String?, model: String?, boardID: String?, osName: String,
                                   _ ctx: Context) -> DeviceTarget {
            guard let catalog = ctx.catalog else {
                return DeviceTarget(reason: "Apple’s release data couldn’t be read, so the newest release isn’t known",
                                    unknown: .appleDataUnreachable)
            }
            // a release is the target from the day Apple offers it publicly; the
            // delay only sets its deadline, as Jamf does
            let eligible = releases(catalog, ctx.platform, days: 0, now: ctx.now, model: model, boardID: boardID)
            guard let newest = eligible.first else {
                return DeviceTarget(reason: "Apple’s release data has no public \(osName) release", unknown: .noReleaseForPlatform)
            }
            guard let pick = newestRelease(catalog, ctx.platform, model: model, boardID: boardID, days: 0, now: ctx.now) else {
                return DeviceTarget(reason: "No \(osName) release runs on this model", noApplicableRelease: true)
            }
            if let unknown = runsNewer(current, than: pick, catalog, ctx.platform, days: 0, now: ctx.now, osName: osName) { return unknown }
            let limited = pick.version.major < newest.version.major
            let from = basis(pick, catalog, model: model, boardID: boardID, known: ctx.known)
            let due = from.map { deadline(released: $0.date, days: days, time: time) }
            return DeviceTarget(
                version: pick.version.description, build: catalog.build(of: pick, model: model, boardID: boardID), released: pick.releaseDate, activityFrom: pick.releaseDate,
                deadlineLocal: due,
                deadlineSource: from?.source,
                reason: "The newest public \(osName) release: \(pick.version)" + (due.map { "; installs by \(day($0))" } ?? "")
                    + (limited ? " (the newest this model can run; it can’t run \(osName) \(newest.version.major))" : ""),
                limitedByHardware: limited)
        }

        /// `SEMANTIC` minor: the newest release of the device’s own major that
        /// Apple offers publicly; due `days` after its public posting.
        private static func minor(_ current: OSVersion?, days: Int, time: String?, model: String?, boardID: String?, osName: String,
                                  _ ctx: Context) -> DeviceTarget {
            guard let catalog = ctx.catalog else {
                return DeviceTarget(reason: "Apple’s release data couldn’t be read, so the newest minor release isn’t known",
                                    unknown: .appleDataUnreachable)
            }
            guard let current else {
                return DeviceTarget(reason: "The device reports no \(osName) version, so its minor updates aren’t known",
                                    unknown: .noReportedVersion)
            }
            let inMajor = catalog.releases.filter { $0.platform == ctx.platform && $0.version.major == current.major && $0.version.extra == nil }
            let knownMajors = catalog.majors(ctx.platform)
            guard !inMajor.isEmpty else {
                if let newest = knownMajors.first, current.major > newest {
                    return DeviceTarget(reason: "The device runs a beta of \(osName) \(current.major), newer than Apple’s newest release (\(osName) \(newest))",
                                        unknown: .betaOfNewerMajor)
                }
                return DeviceTarget(reason: "Apple’s release data has no \(osName) \(current.major) release", unknown: .noReleaseForPlatform)
            }
            // the rule gives the newest release of the device's own major that Apple ships for its
            // model (`pick`): never limited by its hardware for a release Apple shipped to other
            // models only, nor for a newer major it can't run; a device that can't run its own
            // major at all has no pick and is unsupported
            guard let pick = newestRelease(catalog, ctx.platform, model: model, boardID: boardID, days: 0, now: ctx.now,
                                           major: current.major) else {
                // nothing in this major is public yet: the version it runs is what it’s held to
                var held = DeviceTarget(version: current.description, reason: "No public \(osName) \(current.major) release yet")
                held.heldToCurrent = true
                return held
            }
            if let unknown = runsNewer(current, than: pick, catalog, ctx.platform, days: 0, now: ctx.now, osName: osName) { return unknown }
            let from = basis(pick, catalog, model: model, boardID: boardID, known: ctx.known)
            let due = from.map { deadline(released: $0.date, days: days, time: time) }
            return DeviceTarget(
                version: pick.version.description, build: catalog.build(of: pick, model: model, boardID: boardID), released: pick.releaseDate, activityFrom: pick.releaseDate,
                deadlineLocal: due,
                deadlineSource: from?.source,
                reason: "The newest public \(osName) \(current.major) release: \(pick.version)" + (due.map { "; installs by \(day($0))" } ?? ""))
        }

        /// The newest release at least `days` old that the device can run, in
        /// `major` when given: the one rule for both the target and the
        /// hardware to replace. A device Apple’s lists don’t recognize is judged
        /// by its major, so it gets that major’s newest release, never an older
        /// one only because that one has no device list. `knownOnly`: only
        /// majors Apple’s data says the model runs (for “the newest it can run”).
        public static func newestRelease(_ catalog: AppleReleases.Catalog, _ platform: AppleReleases.Platform, model: String?, boardID: String?,
                                  days: Int = 0, now: Date = .distantFuture, major: Int? = nil, knownOnly: Bool = false) -> AppleReleases.Release? {
            releases(catalog, platform, days: days, now: now, model: model, boardID: boardID).first { release in
                (major == nil || release.version.major == major)
                    && runs(release, model: model, boardID: boardID, catalog, platform)
                    && (!knownOnly || catalog.supports(model: model, boardID: boardID, major: release.version.major, platform) == true)
            }
        }

        /// What a computed deadline counts from: Apple’s posting date of the
        /// release meant for this device, as Jamf counts it, else the first
        /// release date (and the source says so). “Reports count from” stays at
        /// the first release date either way. A later re-dating of a build that
        /// was already public doesn’t move the deadline: the posting date the
        /// Blueprint’s devices report Jamf counted from comes first, then the
        /// one they reported in an earlier refresh, then the first public
        /// posting date this app saw of the build, and only then Apple’s public
        /// posting date of today.
        static func basis(_ release: AppleReleases.Release, _ catalog: AppleReleases.Catalog, model: String?,
                          boardID: String?, known: PostingBasis = PostingBasis()) -> (date: Date, source: DeadlineSource)? {
            let key = PostingBasis.key(release.platform, release.version)
            if let reported = known.reported[key] { return (reported, .otherDevices) }
            if let earlier = known.rememberedReported[key] { return (earlier, .rememberedFromDevices) }
            let posting = catalog.publicPosting(of: release, model: model, boardID: boardID)
            if let posting, posting.date != nil,
               let first = known.remembered[PostingBasis.key(release.platform, release.version, build: posting.build)] { return (first, .postingDate) }
            if let posted = posting?.date { return (posted, .postingDate) }
            return release.releaseDate.map { ($0, .releaseDate) }
        }

        /// The deadlines a Blueprint that follows Apple’s releases gives a
        /// version counted from each of its posting dates (public or not) of
        /// `build`, any build when it is nil or Apple’s list has no posting of
        /// it. Empty for a specific version or a version Apple’s data doesn’t know.
        public static func postingDeadlines(for version: OSVersion, build: String?, block: JamfPlatform.SoftwareUpdateBlock?,
                                     catalog: AppleReleases.Catalog?, platform: AppleReleases.Platform) -> [(posted: Date, deadline: String)] {
            let days: Int, time: String?
            switch block?.enforcement {
            case .latest(let delay, let clock)?, .semantic(let delay, let clock)?: (days, time) = (delay ?? 0, clock)
            default: return []
            }
            guard let release = catalog?.release(version, platform) else { return [] }
            let ofBuild = release.postings.filter { build != nil && $0.build == build }
            let dates = Set((ofBuild.isEmpty ? release.postings : ofBuild).compactMap(\.date)).sorted()
            return dates.map { ($0, deadline(released: $0, days: days, time: time)) }
        }

        /// A local date-time a device reports for its pending update’s
        /// deadline, without an offset (`2026-11-16T23:59:00`); nil otherwise.
        static func reportedLocal(_ text: String?) -> String? {
            JamfPro.SoftwareUpdateStatus.PendingVersion(targetLocalDateTime: text).targetLocal
        }

        /// The deadline a device reports as a moment, with the offset it was
        /// written with: as JTKit reads it (`2026-11-23 22:59:11 +0000`), or
        /// written with a 12-hour clock (`2026-11-23 10:59:11 PM +0000`, a
        /// narrow no-break space before PM, seen on a Mac). Nil for a local
        /// time without an offset.
        static func reportedMoment(_ pending: JamfPro.SoftwareUpdateStatus.PendingVersion?) -> (date: Date, offset: Int)? {
            guard let pending, let date = pending.targetDate, let offset = pending.targetOffset else { return nil }
            return (date, offset)
        }

        /// A date-time written with a 12-hour clock and AM or PM, with or
        /// without an offset: as a 24-hour local date-time (`2026-11-23T22:59:11`)
        /// and the offset in seconds. Any space before AM or PM counts, also a
        /// (narrow) no-break space. Nil for anything else.
        static func twelveHour(_ text: String?) -> (local: String, offset: Int?)? {
            JamfPro.SoftwareUpdateStatus.PendingVersion.twelveHour(text)
        }

        /// Whether the device names a declaration as the reason it installs.
        static func fromDeclaration(_ status: JamfPro.SoftwareUpdateStatus) -> Bool {
            status.installReasons.contains { $0.caseInsensitiveCompare("declaration") == .orderedSame }
        }

        /// The posting date Jamf counted this device’s deadline from: the device
        /// reports the rule’s own version pending, after the update started and
        /// the Blueprint’s last change, with a deadline that is the rule’s
        /// counted from exactly one of that version’s posting dates (any build,
        /// public or not). Nil otherwise. Whatever its install reason says
        /// (`declaration`, empty, `notification`, `install-tonight`): only a
        /// declaration sets such a deadline. Jamf’s deadline for a version is
        /// the same for every device of the Blueprint, so this is the
        /// Blueprint’s for devices that haven’t reported it. `moment`: the
        /// reported deadline as a moment, when it was written with an offset;
        /// `reportedAt`: when the device reported it.
        public static func reportedPosting(_ rule: DeviceTarget, status: JamfPro.SoftwareUpdateStatus?, block: JamfPlatform.SoftwareUpdateBlock?,
                                    catalog: AppleReleases.Catalog?, platform: AppleReleases.Platform, serverTimeZone: TimeZone,
                                    blueprintChanged: Date? = nil, timeZone: String? = nil) -> (posted: Date, moment: Date?, reportedAt: Date)? {
            guard !rule.namedByBlueprint, rule.unknown == nil, let version = rule.osVersion,
                  let status, let pending = status.pendingVersion, pending.osVersion.flatMap(OSVersion.init) == version,
                  let reported = pending.updated.flatMap({ JamfPro.serverDate($0, timeZone: serverTimeZone) }) else { return nil }
            if let start = rule.activityFrom, reported < start { return nil }
            if let blueprintChanged, reported <= blueprintChanged { return nil }
            let local = reportedLocal(pending.targetLocalDateTime)
            let moment = reportedMoment(pending)?.date
            guard moment != nil || local != nil else { return nil }
            let matching = postingDeadlines(for: version, build: nil, block: block, catalog: catalog, platform: platform).filter { candidate in
                sameDeadline(reported: moment, reportedLocal: local, expected: candidate.deadline)
                    && sameClock(reported: moment, reportedLocal: local, expected: candidate.deadline, timeZone: timeZone)
            }
            // two postings that give the same deadline are one; two deadlines can't be told apart
            guard Set(matching.map(\.deadline)).count == 1, let posted = matching.first?.posted else { return nil }
            return (posted, moment, reported)
        }

        /// The posting date the Blueprint’s devices report Jamf counted from,
        /// per platform and version: the one most of them report, the earliest
        /// of those when as many report another.
        static func reportedPostings(_ reports: [(platform: AppleReleases.Platform, version: OSVersion, posted: Date)]) -> [String: Date] {
            var counts: [String: [Date: Int]] = [:]
            for report in reports { counts[PostingBasis.key(report.platform, report.version), default: [:]][report.posted, default: 0] += 1 }
            return counts.compactMapValues { dates in
                dates.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
            }
        }

        /// A device already on a release Apple shipped to it, old enough for
        /// the rule and newer than the rule’s pick: the rule doesn’t fit it, so
        /// its target is unknown rather than lower than what it runs. A newer
        /// version that isn’t such a release (too new for the delay, a beta)
        /// is simply ahead.
        static func runsNewer(_ current: OSVersion?, than pick: AppleReleases.Release, _ catalog: AppleReleases.Catalog,
                              _ platform: AppleReleases.Platform, days: Int, now: Date, osName: String) -> DeviceTarget? {
            guard let current, current > pick.version,
                  releases(catalog, platform, days: days, now: now).contains(where: { $0.version == current }) else { return nil }
            return DeviceTarget(reason: "The device runs \(osName) \(current), a release newer than the rule’s target (\(pick.version)): "
                                    + "the rule doesn’t fit this device",
                                unknown: .runsNewerRelease)
        }

        /// The version the device reports pending from a declaration, as its
        /// target: what Jamf actually sent it. Used when the install reason
        /// includes `declaration`, the version is newer than what the device
        /// runs, and the report is from after the update started; otherwise
        /// the rule’s target stands. When the two differ, both are kept. The
        /// rule’s own version also counts whatever the install reason says
        /// (empty, `notification`, `install-tonight`) when it comes with a
        /// deadline: the rule’s from one of its posting dates (only a
        /// declaration sets one), or the device’s next install attempt.
        ///
        /// `earlierStepDeadline` gives this Blueprint’s own deadline for a
        /// version (`ruleDeadline`): a pending version older than the rule’s,
        /// reported with that deadline, is this Blueprint’s earlier step (Jamf’s
        /// status items don’t name the declaration that sent it), and only when
        /// reported after the update started, like any pending version. The
        /// rule’s version and deadline always count and the step is kept to
        /// show; once it can’t be under way any more (not installing, its own
        /// deadline plus `installGrace` passed), it is marked late, and the
        /// device counts as past that deadline.
        ///
        /// Apple’s public catalog keeps current versions only, so once it posts
        /// a newer one the step’s own posting date can be gone from it.
        /// `earlierStepWindow` gives the deadlines this Blueprint’s rule could
        /// have given the version while it was the rule’s target (`ruleWindow`):
        /// the one from Apple’s own posting date when its list still has it,
        /// else one per day of the window. A reported deadline that is one of
        /// them at the Blueprint’s time of day is the step’s too, by the full
        /// clock time in the device’s zone (iPads, iPhones). `awaitingSync` (the
        /// Blueprint’s update declaration for the device’s own OS says awaiting
        /// sync) supports it: with it, a version the rule targeted in that
        /// window is the step whatever the deadline reads.
        ///
        /// A Mac writes its deadline in UTC, whatever its zone, so its day and
        /// clock can’t be checked against the Blueprint’s local time: a Mac’s
        /// older version is the step only when its deadline is, to the minute,
        /// one the Blueprint’s own devices reported for that version
        /// (`PostingBasis.reportedMinutes`), or one they reported for the
        /// rule’s version (Jamf moved the declaration on); otherwise it is
        /// another pending version.
        ///
        /// A time reported for the rule’s version after the Blueprint’s
        /// deadline passed, that isn’t the rule’s deadline from any of the
        /// version’s posting dates, is the device’s next install attempt (a Mac
        /// that missed the deadline sets one): the Blueprint’s deadline stays,
        /// so the device stays past it, and the time is kept to show.
        public static func fromDevice(_ rule: DeviceTarget, status: JamfPro.SoftwareUpdateStatus?, os: String?, osName: String,
                               catalog: AppleReleases.Catalog?, platform: AppleReleases.Platform, serverTimeZone: TimeZone,
                               model: String? = nil, boardID: String? = nil, blueprintChanged: Date? = nil,
                               earlierStepDeadline: ((OSVersion) -> String?)? = nil,
                               earlierStepWindow: ((OSVersion) -> [String])? = nil, awaitingSync: Bool = false,
                               postingDeadlines: ((OSVersion, String?) -> [String])? = nil, known: PostingBasis = PostingBasis(),
                               timeZone: String? = nil, now: Date = Date()) -> DeviceTarget {
            guard let status, let pending = status.pendingVersion, let version = pending.osVersion.flatMap(OSVersion.init),
                  let current = os.flatMap(OSVersion.init), version > current else { return rule }
            // the deadline as the device reports it: a moment with its offset, or a local date-time
            let moment = reportedMoment(pending)
            let reportedLocal = Self.reportedLocal(pending.targetLocalDateTime)
            let isRuleVersion = rule.version.flatMap(OSVersion.init) == version
            let declared = fromDeclaration(status)
            // without “declaration” only the rule's own version, and only with a deadline to read
            guard declared || (isRuleVersion && (moment != nil || reportedLocal != nil)) else { return rule }
            // a version the Blueprint names itself is what Jamf sent: a lower
            // pending version is a step on the way there (an intermediate update)
            if rule.namedByBlueprint, let named = rule.osVersion, version < named { return rule }
            // a pending version from a report older than the update's start says
            // nothing about this update: neither its target nor its deadline
            if let start = rule.activityFrom {
                guard let reported = pending.updated.flatMap({ JamfPro.serverDate($0, timeZone: serverTimeZone) }), reported >= start else {
                    return rule
                }
            }
            func matches(_ expected: String) -> Bool {
                sameDeadline(reported: moment?.date, reportedLocal: reportedLocal, expected: expected)
                    && sameClock(reported: moment?.date, reportedLocal: reportedLocal, expected: expected, timeZone: timeZone)
            }
            // a Mac's deadline, to the minute, is one the Blueprint's own devices reported for `step`
            let isMac = platform == .macOS
            func reportedByBlueprint(_ step: OSVersion) -> Bool {
                guard let moment else { return false }
                return known.reportedMinutes[PostingBasis.key(platform, step)]?.contains(PostingBasis.minute(moment.date)) == true
            }
            // the other way round: Jamf already sent the rule's version, with its deadline,
            // and the device still reports this older version of the same major pending;
            // only when Apple's data lists the rule's version for this device
            // (for a Mac: a deadline the Blueprint's devices reported for the rule's version, to the minute)
            func movedOn() -> Bool {
                guard let ruleVersion = rule.osVersion, ruleVersion.major == version.major, let ruleDue = rule.deadlineLocal,
                      let catalog, let ruleRelease = catalog.release(ruleVersion, platform),
                      catalog.supports(release: ruleRelease, model: model, boardID: boardID) == true else { return false }
                return isMac ? reportedByBlueprint(ruleVersion) : matches(ruleDue)
            }
            // this Blueprint's earlier step: sent before Apple posted the newer
            // version its rule now gives, recognized by the deadline it came with
            func isEarlierStep() -> Bool {
                if isMac { return reportedByBlueprint(version) || movedOn() }
                if let expected = earlierStepDeadline?(version),
                   sameDeadline(reported: moment?.date, reportedLocal: reportedLocal, expected: expected) { return true }
                let window = earlierStepWindow?(version) ?? []
                if window.contains(where: matches) { return true }
                return awaitingSync && !window.isEmpty || movedOn()
            }
            if !rule.namedByBlueprint, let ruleVersion = rule.osVersion, version < ruleVersion, isEarlierStep() {
                // its own deadline as a moment: reported, or its local time in the device's zone (this Mac's for a Mac)
                let due = moment?.date ?? deadlineDate(reportedLocal, timeZone: timeZone ?? TimeZone.current.identifier)
                var target = rule
                target.earlierStepVersion = version.description
                target.earlierStepDeadline = moment?.date
                target.earlierStepLocal = moment == nil ? reportedLocal : nil
                target.earlierStepLapsed = status.installState != .installing
                    && due.map { now >= $0.addingTimeInterval(installGrace) } == true
                return target
            }
            let release = catalog?.release(version, platform)
            var target = DeviceTarget(version: version.description, build: pending.buildVersion ?? release?.build,
                                      released: release?.releaseDate, activityFrom: rule.activityFrom,
                                      reason: "Jamf sent \(osName) \(version): the device reports it pending from a declaration",
                                      startSetByHand: rule.startSetByHand)
            target.fromDevice = true
            // the deadline as the device reports it; false when it reports none that reads
            func takeReported() -> Bool {
                if let moment {
                    target.deadlineDate = moment.date
                    target.deadlineOffset = moment.offset
                    target.deadlineLocal = localText(moment.date, offset: moment.offset)
                } else if let local = reportedLocal {
                    target.deadlineLocal = local
                } else {
                    return false
                }
                target.deadlineSource = .reported
                return true
            }
            // A deadline the device reports wins only when the report is newer
            // than what could have changed it: the Blueprint's last change and,
            // for a Blueprint that follows Apple's releases (latest, minor),
            // Apple's posting of the version its deadline counts from (`basis`).
            // Only for the rule's own version: one from another declaration
            // isn't changed by this Blueprint.
            let followsApple = !rule.namedByBlueprint && rule.version != nil
            let posted = followsApple ? release.flatMap { release in
                catalog.flatMap { basis(release, $0, model: model, boardID: boardID, known: known) }.flatMap { $0.source != .releaseDate ? $0.date : nil }
            } : nil
            let reportedAt = pending.updated.flatMap { JamfPro.serverDate($0, timeZone: serverTimeZone) }
            // a Mac writes UTC, so its minutes only match by the quarter hour: once the Blueprint's
            // devices have reported Jamf's deadline for this version, only those minutes are Jamf's
            // (a rescheduled time at :14, :29, :44 or :59 isn't)
            let jamfMinutes = isMac && isRuleVersion ? known.reportedMinutes[PostingBasis.key(platform, version)] ?? [] : []
            func isJamfs(_ expected: String) -> Bool {
                if !jamfMinutes.isEmpty, let moment { return jamfMinutes.contains(PostingBasis.minute(moment.date)) && matches(expected) }
                return matches(expected)
            }
            // the rule's deadline counted from any posting date of this version and build:
            // Jamf sent it, whatever Apple re-dated since
            let fromPosting = isRuleVersion && followsApple
                && (postingDeadlines?(version, pending.buildVersion ?? rule.build) ?? []).contains(where: isJamfs)
            // the rule's version, reported after the Blueprint's deadline with another time:
            // the device's next install attempt (a Mac's zone is this Mac's, as for its deadline)
            let nextAttempt: Bool = {
                guard isRuleVersion, !fromPosting, let ruleDue = rule.deadlineLocal, moment != nil || reportedLocal != nil,
                      !isJamfs(ruleDue),
                      let due = deadlineDate(ruleDue, timeZone: timeZone ?? TimeZone.current.identifier),
                      let reportedAt else { return false }
                return reportedAt > due
            }()
            // another reason than a declaration: only Jamf's deadline or a next attempt says this update sent it
            if !declared && !fromPosting && !nextAttempt { return rule }
            let changes: [(date: Date, reason: StaleReason)] = isRuleVersion
                ? [blueprintChanged.map { ($0, .blueprintChanged) }, fromPosting ? nil : posted.map { ($0, .posted) }].compactMap { $0 } : []
            let missed = changes.filter { change in reportedAt.map { $0 <= change.date } ?? true }.max { $0.date < $1.date }
            // the rule's own version with the deadline of this Blueprint's earlier step
            // (an older version of the same major the rule targeted before): Jamf kept
            // the step's deadline when it moved the declaration on
            func carriedStep() -> OSVersion? {
                guard isRuleVersion, followsApple, !fromPosting, let ruleDue = rule.deadlineLocal, let catalog,
                      moment != nil || reportedLocal != nil,
                      !sameDeadline(reported: moment?.date, reportedLocal: reportedLocal, expected: ruleDue) else { return nil }
                let earlier = catalog.releases
                    .filter { $0.platform == platform && $0.version.extra == nil && $0.version.major == version.major && $0.version < version }
                    .map(\.version).sorted(by: >)
                return earlier.first { step in
                    earlierStepDeadline?(step).map(matches) == true || (earlierStepWindow?(step) ?? []).contains(where: matches)
                }
            }
            if let step = carriedStep() {
                target.deadlineLocal = rule.deadlineLocal
                target.deadlineSource = rule.deadlineSource
                target.carriedStepVersion = step.description
                target.carriedDeadline = moment?.date
                target.carriedDeadlineLocal = moment == nil ? reportedLocal : nil
            } else if nextAttempt {
                target.deadlineLocal = rule.deadlineLocal
                target.deadlineSource = rule.deadlineSource
                target.nextInstallAttempt = moment?.date
                target.nextInstallAttemptLocal = moment == nil ? reportedLocal : nil
            } else if let missed {
                if rule.deadlineLocal == nil {
                    // the rule gives no deadline of its own: keep the reported
                    // one, said to be possibly out of date
                    if takeReported() { target.deadlineSource = missed.reason == .posted ? .reportedBeforePosting : .reportedBeforeChange }
                } else {
                    target.deadlineLocal = rule.deadlineLocal
                    target.deadlineSource = rule.deadlineSource
                    let staleLocal = moment == nil ? reportedLocal : nil
                    let staleDay = moment.map { $0.date.formatted(.iso8601.year().month().day()) } ?? staleLocal.map { String($0.prefix(10)) }
                    // the same day as the rule's deadline: nothing to point out
                    if let staleDay, staleDay != rule.deadlineLocal.map({ String($0.prefix(10)) }) {
                        target.staleReportedDeadline = moment?.date
                        target.staleReportedLocal = staleLocal
                        target.staleSince = missed.date
                        target.staleReason = missed.reason
                    }
                }
            } else if !takeReported() {
                target.deadlineLocal = rule.deadlineLocal
                target.deadlineSource = rule.deadlineSource
            }
            target.ruleVersion = rule.version
            target.ruleReason = rule.reason
            target.limitedByHardware = rule.limitedByHardware
            target.differsFromRule = rule.version.flatMap(OSVersion.init) != version
            return target
        }

        /// This Blueprint’s deadline for a version, in the device’s local time,
        /// as its rule gives it: Apple’s posting of that version (`basis`) plus
        /// the days, at the Blueprint’s time. Nil for a specific version or a
        /// version Apple’s data doesn’t know.
        public static func ruleDeadline(for version: OSVersion, block: JamfPlatform.SoftwareUpdateBlock?, catalog: AppleReleases.Catalog?,
                                 platform: AppleReleases.Platform, model: String?, boardID: String?,
                                 known: PostingBasis = PostingBasis()) -> String? {
            let days: Int, time: String?
            switch block?.enforcement {
            case .latest(let delay, let clock)?, .semantic(let delay, let clock)?: (days, time) = (delay ?? 0, clock)
            default: return nil
            }
            guard let catalog, let release = catalog.release(version, platform),
                  let basis = basis(release, catalog, model: model, boardID: boardID, known: known) else { return nil }
            return deadline(released: basis.date, days: days, time: time)
        }

        /// The deadlines this Blueprint’s rule could have given a version while
        /// it was the rule’s target. When Apple’s list still has the version’s
        /// posting dates (public or not, any build), one deadline from each; otherwise
        /// one per day from its release to the posting of the next release the
        /// rule moves to (in its own major for minor updates), at the Blueprint’s
        /// time. Empty for a specific version, a version Apple’s data doesn’t
        /// know, or one nothing has followed yet (then it is the rule’s target).
        public static func ruleWindow(for version: OSVersion, block: JamfPlatform.SoftwareUpdateBlock?, catalog: AppleReleases.Catalog?,
                               platform: AppleReleases.Platform, model: String?, boardID: String?, now: Date,
                               known: PostingBasis = PostingBasis()) -> [String] {
            let days: Int, time: String?, sameMajor: Bool
            switch block?.enforcement {
            case .latest(let delay, let clock)?: (days, time, sameMajor) = (delay ?? 0, clock, false)
            case .semantic(let delay, let clock)?: (days, time, sameMajor) = (delay ?? 0, clock, true)
            default: return []
            }
            guard let catalog, let release = catalog.release(version, platform),
                  let start = basis(release, catalog, model: model, boardID: boardID, known: known)?.date else { return [] }
            // the next release the rule moved to: the oldest offered one newer than it that the device runs
            let next = releases(catalog, platform, days: 0, now: now, model: model, boardID: boardID)
                .filter { $0.version > version && (!sameMajor || $0.version.major == version.major)
                    && runs($0, model: model, boardID: boardID, catalog, platform) }
                .min { $0.version < $1.version }
            guard let next, let end = basis(next, catalog, model: model, boardID: boardID, known: known)?.date, end >= start else { return [] }
            // Apple's own posting dates, when its list still has them: those days only. Every
            // build's counts: Jamf can count from the public posting of another build (5 Nov)
            // while the list keeps only the release-day posting of this device's own (26 Oct)
            let posted = postings(of: release)
            if !posted.isEmpty {
                return Array(NSOrderedSet(array: posted.map { deadline(released: $0, days: days, time: time) })).compactMap { $0 as? String }
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            var day = calendar.startOfDay(for: start)
            var deadlines: [String] = []
            // at most two months: a window longer than that says nothing
            while day <= end && deadlines.count < 62 {
                deadlines.append(deadline(released: day, days: days, time: time))
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? end.addingTimeInterval(1)
            }
            return deadlines
        }

        /// Apple’s posting dates of a release, public or not, for any build and
        /// device, oldest first; empty when its list has none.
        static func postings(of release: AppleReleases.Release) -> [Date] {
            Set(release.postings.compactMap(\.date)).sorted()
        }

        /// Whether a reported deadline is at the expected time of day: a local
        /// date-time by its clock; a moment in the device’s own zone, when it is
        /// known, by its full date and clock time; otherwise a moment, which can
        /// be any zone’s local time (a Mac writes UTC), by its minutes only
        /// (zones are whole quarter hours apart).
        static func sameClock(reported: Date?, reportedLocal: String?, expected: String, timeZone: String? = nil) -> Bool {
            let expectedClock = expected.dropFirst(11).prefix(5)
            if let reported, let zone = timeZone.flatMap(TimeZone.init(identifier:)) {
                return localText(reported, offset: zone.secondsFromGMT(for: reported)).prefix(16) == expected.prefix(16)
            }
            if let reported {
                guard let minute = Int(expectedClock.suffix(2)) else { return false }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .gmt
                let reportedMinute = calendar.component(.minute, from: reported)
                return ((reportedMinute - minute) % 15 + 15) % 15 == 0
            }
            if let reportedLocal { return reportedLocal.dropFirst(11).prefix(5) == expectedClock }
            return false
        }

        /// Whether a reported deadline is the one expected, in the device’s
        /// local time. A moment can be any zone’s local time (a Mac writes it in
        /// UTC, whatever its zone), so it matches when it lies within the span
        /// of the world’s zones (UTC−12 to UTC+14); a local date-time matches by its day.
        public static func sameDeadline(reported: Date?, reportedLocal: String?, expected: String) -> Bool {
            if let reported, let wall = JamfPlatform.SoftwareUpdateBlock.deadline(expected, in: .gmt) {
                let shift = wall.timeIntervalSince(reported)
                return shift >= -12 * 3_600 - 60 && shift <= 14 * 3_600 + 60
            }
            if let reportedLocal { return reportedLocal.prefix(10) == expected.prefix(10) }
            return false
        }

        /// A moment as the local time at `offset`, without a zone.
        public static func localText(_ date: Date, offset: Int) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: offset)
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            return formatter.string(from: date)
        }

        /// Whether the model can run a release: by the release’s own device
        /// list when Apple’s data has one for this device (some releases are
        /// for some devices only), else by its major.
        static func runs(_ release: AppleReleases.Release, model: String?, boardID: String?, _ catalog: AppleReleases.Catalog,
                         _ platform: AppleReleases.Platform) -> Bool {
            catalog.supports(release: release, model: model, boardID: boardID)
                ?? (catalog.supports(model: model, boardID: boardID, major: release.version.major, platform) != false)
        }

        /// The platform’s releases at least `days` old, newest first (no Rapid
        /// Security Responses).
        static func releases(_ catalog: AppleReleases.Catalog, _ platform: AppleReleases.Platform, days: Int, now: Date,
                             model: String? = nil, boardID: String? = nil) -> [AppleReleases.Release] {
            catalog.releases
                .filter { $0.platform == platform && $0.version.extra == nil }
                .filter { release in
                    isOffered(release, catalog, model: model, boardID: boardID, now: now)
                        && release.releaseDate.map { $0.addingTimeInterval(Double(days) * 86_400) <= now } ?? false
                }
                .sorted { $0.version > $1.version }
        }

        /// Whether Apple offers a release publicly, the basis its deadline
        /// counts from: it has a public posting (GDMF `PublicAssetSets`) for the
        /// device, or GDMF doesn’t list it at all (then its release date counts),
        /// or GDMF lists it only outside the public catalog but a newer release
        /// of its major is public (Apple’s public catalog keeps current versions
        /// only). A release first seen outside the public catalog and newer than
        /// every public one isn’t offered yet, so it can’t be a target, and its
        /// deadline can’t fall back to a date before Apple offered it.
        static func isOffered(_ release: AppleReleases.Release, _ catalog: AppleReleases.Catalog,
                              model: String? = nil, boardID: String? = nil, now: Date = .distantFuture) -> Bool {
            if let posted = catalog.publicPosting(of: release, model: model, boardID: boardID)?.date { return posted <= now }
            guard !release.postings.isEmpty else { return true }
            let newestPublic = catalog.releases
                .filter { $0.platform == release.platform && $0.version.major == release.version.major && $0.postings.contains(where: \.isPublic) }
                .map(\.version).max()
            return newestPublic.map { release.version < $0 } ?? false
        }

        /// Apple’s release day plus `days`, at `HH:MM`, in the device’s local
        /// time (`2026-11-23T17:00:00`). Apple dates a release by its day.
        static func deadline(released: Date, days: Int, time: String?) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: released)) ?? released
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let clock = time.flatMap { $0.range(of: "^[0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil ? $0 : nil } ?? "00:00"
            return String(format: "%04d-%02d-%02dT%@:00", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1, clock)
        }

        /// The deadline as a moment in a zone; nil without one.
        public static func deadlineDate(_ local: String?, timeZone: String?) -> Date? {
            guard let local, let zone = timeZone.flatMap(TimeZone.init(identifier:)) else { return nil }
            return JamfPlatform.SoftwareUpdateBlock.deadline(local, in: zone)
        }

        /// Whether the deadline has passed: in the device’s zone, or, for a
        /// device without one (Macs), in this Mac’s.
        static func isPastDeadline(_ local: String?, timeZone: String?, now: Date) -> Bool? {
            guard let local else { return nil }
            let zone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
            return JamfPlatform.SoftwareUpdateBlock.deadline(local, in: zone).map { $0 <= now }
        }

        /// `2026-11-19T23:59:00` as a day, “19 Nov”, without moving it to a zone.
        public static func day(_ local: String) -> String {
            guard let date = JamfPlatform.SoftwareUpdateBlock.deadline(local, in: .gmt) else { return local }
            var style = Date.FormatStyle().day().month(.abbreviated)
            style.timeZone = .gmt
            return date.formatted(style)
        }

        /// `2026-11-23T17:00:00` as people read it, without moving it to a zone.
        public static func readable(_ local: String) -> String {
            guard let date = JamfPlatform.SoftwareUpdateBlock.deadline(local, in: .gmt) else { return local }
            var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            style.timeZone = .gmt
            return date.formatted(style)
        }
    }
}
