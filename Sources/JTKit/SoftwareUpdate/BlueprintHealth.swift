import Foundation

extension SoftwareUpdateRules {
    /// How the Blueprint’s software update declarations stand across its
    /// devices, read once per refresh, one request per declaration (never per
    /// device): each range by name, never by ID, with how many devices report
    /// it applied, pending, awaiting sync, failed or invalid, and the most
    /// common reason; and the devices on a version none of the Blueprint’s
    /// current declarations covers, or that haven’t fetched the ones that do.
    ///
    /// The identifiers come from the devices’ own status reports
    /// (`management.declarations`), only those of the Blueprint’s software
    /// update components; a declaration no device has received isn’t listed. A
    /// report is tied to a device by its Platform device ID, which the refresh
    /// takes from the Platform device list by serial number; a report that
    /// can’t be tied is left out and counted in `unmatchedDevices`.
    public nonisolated struct BlueprintHealth: Sendable, Hashable {
        /// One of the Blueprint’s current update declarations (a configuration
        /// with its own activation), as Jamf sent it. What its condition takes is
        /// worked out once here, not per device.
        public struct Current: Sendable, Hashable {
            /// Only to tell pairs apart; never shown.
            public var key: String
            /// By its versions, its OS family or its step; pairs for the same
            /// range (one per hardware group) share it.
            public var name: String
            /// iOS, iPadOS or macOS, from its predicate or its step’s; nil when neither says.
            public var family: String?
            public var predicate: String?
            /// The newest version its condition takes; nil without a version condition.
            public var upperBound: OSVersion?
            /// Every version its condition takes; nil without a version condition.
            public var covered: Set<OSVersion>?
            /// Its versions as people read them, “27.0 to 27.0.1”.
            public var range: String?

            /// Whether the predicate lists this device ID or model.
            func lists(_ id: String) -> Bool { predicate?.contains("\"\(id)\"") == true }

            /// Whether its condition names hardware at all.
            var listsHardware: Bool {
                predicate?.range(of: #"(device-id|model\.identifier)[^=]*IN\s*\{"#, options: .regularExpression) != nil
            }

            /// Whether it is for this device: its family, the hardware it lists
            /// (when it lists any) and the versions its condition takes. Nil when
            /// the predicate isn’t known.
            public func applies(osName: String, ids: [String], version: OSVersion) -> Bool? {
                if let family, family != osName { return false }
                guard predicate != nil else { return nil }
                if listsHardware && !ids.contains(where: lists) { return false }
                return covered.map { $0.contains(version) } ?? true
            }

            /// Every stored property, in order, with the same defaults as the memberwise initializer.
            public init(
                key: String,
                name: String,
                family: String? = nil,
                predicate: String? = nil,
                upperBound: OSVersion? = nil,
                covered: Set<OSVersion>? = nil,
                range: String? = nil
            ) {
                self.key = key
                self.name = name
                self.family = family
                self.predicate = predicate
                self.upperBound = upperBound
                self.covered = covered
                self.range = range
            }
        }

        /// One row: every pair with the same name, counted once per device.
        public struct Declaration: Sendable, Hashable, Identifiable {
            /// Only to tell the rows apart; never shown.
            public var id: String
            public var name: String
            public var applied = 0
            public var pending = 0
            public var awaitingSync = 0
            public var failed = 0
            public var invalid = 0
            /// Devices its activation’s predicate leaves out, by design.
            public var notForDevice = 0
            /// The reason most failed or invalid devices give, without IDs, and how many give it.
            public var commonReason: String?
            public var commonReasonCount = 0

            var hasProblems: Bool { failed > 0 || invalid > 0 }
            /// Whether a device in scope reports it for itself.
            var appliesToSomeDevice: Bool { applied + pending + awaitingSync + failed + invalid > 0 }

            /// Every stored property, in order, with the same defaults as the memberwise initializer.
            public init(
                id: String,
                name: String,
                applied: Int = 0,
                pending: Int = 0,
                awaitingSync: Int = 0,
                failed: Int = 0,
                invalid: Int = 0,
                notForDevice: Int = 0,
                commonReason: String? = nil,
                commonReasonCount: Int = 0
            ) {
                self.id = id
                self.name = name
                self.applied = applied
                self.pending = pending
                self.awaitingSync = awaitingSync
                self.failed = failed
                self.invalid = invalid
                self.notForDevice = notForDevice
                self.commonReason = commonReason
                self.commonReasonCount = commonReasonCount
            }
        }

        /// Why a device gets no update from the Blueprint’s current declarations.
        public enum Coverage: Sendable, Hashable {
            /// None of them covers its version: their ranges for its hardware, “macOS 27.0 to 27.0.1”.
            case notCovered(String)
            /// One covers it, but the device hasn’t fetched it: its own report is from this moment.
            case notFetched(lastReport: Date?)
        }

        /// The rows that apply to a device in scope, one per range.
        public var declarations: [Declaration] = []
        /// Rows that apply to no device in scope (other platforms, older majors), collapsed into one line.
        public var inapplicable = 0
        /// The Blueprint’s current update declarations, for Inspect.
        public var current: [Current] = []
        /// By device (`DeviceStatus.id`): why the current declarations don’t reach it.
        public var coverage: [String: Coverage] = [:]
        /// Devices in the reports that couldn’t be tied to a device in the list.
        public var unmatchedDevices = 0
        /// Devices in the list whose serial number isn’t in the Platform device list.
        public var devicesWithoutPlatformID = 0
        /// What couldn’t be read, e.g. a declaration report that was refused.
        public var problems: [String] = []

        // MARK: Reading

        /// The Blueprint’s software update declaration identifiers among those
        /// the devices hold, each once, in the order found: only those of its
        /// software update components (`Blueprint_<id>_s<step>_c<component>_…`).
        public static func identifiers(blueprintID: String, statuses: [JamfPro.SoftwareUpdateStatus?],
                                blocks: [JamfPlatform.SoftwareUpdateBlock]) -> [String] {
            let prefix = "blueprint_\(blueprintID.lowercased())"
            let components = Set(blocks.map { "_s\($0.stepIndex + 1)_c\($0.componentIndex + 1)_" })
            var seen = Set<String>()
            return statuses.flatMap { $0?.declarationIdentifiers ?? [] }.filter { identifier in
                let lower = identifier.lowercased()
                guard lower.hasPrefix(prefix) else { return false }
                let rest = lower.dropFirst(prefix.count)
                return components.contains { rest.hasPrefix($0) } && seen.insert(identifier).inserted
            }
        }

        /// Each device’s reports, by `DeviceStatus.id`; a report whose device
        /// isn’t in `deviceIDs` (Platform device ID → `DeviceStatus.id`) is left
        /// out and counted.
        static func byDevice(_ reports: [JamfPlatform.DeclarationReport],
                             deviceIDs: [String: String]) -> (reports: [String: [JamfPlatform.DeclarationReport]], unmatched: Int) {
            var byDevice: [String: [JamfPlatform.DeclarationReport]] = [:]
            var unmatched = Set<String>()
            for report in reports {
                guard let platformID = report.deviceID?.lowercased() else { continue }
                if let device = deviceIDs[platformID] {
                    byDevice[device, default: []].append(report)
                } else {
                    unmatched.insert(platformID)
                }
            }
            return (byDevice, unmatched.count)
        }

        /// The Blueprint’s current declarations from every device’s reports:
        /// each pair with the predicate of its newest report (when a device
        /// reported one; by the declaration’s `dateUpdated`), its
        /// family from that predicate or its step’s activation predicate, and
        /// its name. In step order, then by number.
        public static func catalogue(_ reports: [JamfPlatform.DeclarationReport], blocks: [JamfPlatform.SoftwareUpdateBlock],
                              blueprintName: String) -> [Current] {
            let pairs = DeclarationPair.pairs(reports)
            func step(_ pair: DeclarationPair) -> Int? { pair.reports.first?.blueprintStepIndex }
            let sorted = pairs.sorted { first, second in
                let steps = (step(first) ?? 0, step(second) ?? 0)
                return steps.0 != steps.1 ? steps.0 < steps.1 : (Int(first.number ?? "") ?? 0) < (Int(second.number ?? "") ?? 0)
            }
            return sorted.map { pair in
                // the newest version of the declaration: a device that hasn't fetched Jamf's current
                // one still reports the old predicate under the same identifier, and the order the
                // reports are read in says nothing
                let activation = pair.reports.filter { report in
                    report.type == "ACTIVATION" && report.reasons.contains { reason in
                        reason.details.contains { $0.key?.lowercased() == "predicate" } || (reason.description ?? "").contains("predicate")
                    }
                }.max { ($0.dateUpdated ?? .distantPast) < ($1.dateUpdated ?? .distantPast) }
                let shape = DeclarationPair(key: pair.key, number: pair.number, reports: activation.map { [$0] } ?? [])
                let predicate = shape.predicate
                let stepPredicate = step(pair).flatMap { index in blocks.first { $0.stepIndex == index }?.activationPredicate }
                let family = shape.family ?? stepPredicate.flatMap(DeclarationPair.family(in:))
                let covered = predicate.flatMap(DeclarationPair.covered).map(Set.init)
                let range = predicate.flatMap(DeclarationPair.versionRange)
                let name: String
                if let range, let family { name = "\(blueprintName), \(family) \(range)" }
                else if let range { name = "\(blueprintName), \(range)" }
                else if let family { name = "\(blueprintName), \(family)" }
                else if let index = step(pair) {
                    name = "\(blueprintName), step \(index + 1)" + ((pair.number ?? "1") == "1" ? "" : ", declaration \(pair.number ?? "")")
                } else {
                    name = pair.number.map { "\(blueprintName), update declaration \($0)" } ?? blueprintName
                }
                return Current(key: pair.key, name: name, family: family, predicate: predicate,
                               upperBound: covered?.max(), covered: covered, range: range)
            }
        }

        /// Whether the device’s report of one of the Blueprint’s update
        /// declarations for its own OS says awaiting sync: Jamf sent a new one
        /// the device hasn’t fetched. Another OS family’s declaration says nothing.
        static func isAwaitingSync(_ reports: [JamfPlatform.DeclarationReport], osName: String, current: [Current]) -> Bool {
            let families = Dictionary(current.map { ($0.key, $0.family) }, uniquingKeysWith: { first, _ in first })
            return DeclarationPair.pairs(reports).contains { pair in
                let family = families[pair.key] ?? nil
                return (family == nil || family == osName) && pair.reports.contains { $0.status == .awaitingSync }
            }
        }

        // MARK: Health

        public static func make(byDevice: [String: [JamfPlatform.DeclarationReport]], devices: [DeviceStatus], current: [Current],
                         blueprintName: String, blueprintID: String, unmatchedDevices: Int = 0, devicesWithoutPlatformID: Int = 0,
                         problems: [String] = []) -> BlueprintHealth {
            let names = [blueprintID.lowercased(): blueprintName]
            // one row per name: Jamf makes a pair per hardware group for the same range
            var order: [String] = []
            var keysByName: [String: Set<String>] = [:]
            for declaration in current {
                if keysByName[declaration.name] == nil { order.append(declaration.name) }
                keysByName[declaration.name, default: []].insert(declaration.key)
            }
            let pairsByDevice = byDevice.mapValues { DeclarationPair.pairs($0) }
            var rows: [Declaration] = []
            for name in order {
                let keys = keysByName[name] ?? []
                var row = Declaration(id: name, name: name)
                var reasons: [String: Int] = [:]
                for pairs in pairsByDevice.values {
                    let states = pairs.filter { keys.contains($0.key) }.map { $0.state(names: names) }
                    guard let state = Self.deviceState(states) else { continue }
                    switch state {
                    case "Not for this device": row.notForDevice += 1
                    case "Applied": row.applied += 1
                    case "Pending": row.pending += 1
                    case "Awaiting sync": row.awaitingSync += 1
                    default:
                        if state.hasPrefix("Invalid: ") {
                            row.invalid += 1
                            reasons[String(state.dropFirst("Invalid: ".count)), default: 0] += 1
                        } else if state.hasPrefix("Failed: ") {
                            row.failed += 1
                            reasons[String(state.dropFirst("Failed: ".count)), default: 0] += 1
                        }
                    }
                }
                if let common = reasons.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
                    row.commonReason = common.key
                    row.commonReasonCount = common.value
                }
                rows.append(row)
            }
            var coverage: [String: Coverage] = [:]
            for device in devices {
                if let found = Self.coverage(device, current: current, reports: byDevice[device.id]) { coverage[device.id] = found }
            }
            return BlueprintHealth(declarations: rows.filter(\.appliesToSomeDevice), inapplicable: rows.filter { !$0.appliesToSomeDevice }.count,
                                   current: current, coverage: coverage, unmatchedDevices: unmatchedDevices,
                                   devicesWithoutPlatformID: devicesWithoutPlatformID, problems: problems)
        }

        /// One device’s state for a row of several pairs: the one that is for
        /// it (the worst, should two be), else not for it; nil without a report.
        static func deviceState(_ states: [String]) -> String? {
            guard !states.isEmpty else { return nil }
            let forDevice = states.filter { $0 != "Not for this device" }
            guard !forDevice.isEmpty else { return "Not for this device" }
            let rank: (String) -> Int = { state in
                if state.hasPrefix("Invalid") { return 0 }
                if state.hasPrefix("Failed") { return 1 }
                switch state {
                case "Awaiting sync": return 2
                case "Pending": return 3
                case "Applied": return 4
                default: return 5
                }
            }
            return forDevice.min { rank($0) < rank($1) }
        }

        /// Why the Blueprint’s current declarations don’t reach a device that
        /// isn’t on target while its target is newer: none covers its version
        /// (their ranges for its hardware and major all end below it), or one
        /// does but the device hasn’t fetched it (no report of it, or awaiting
        /// sync). Nil when a declaration applies on the device, or nothing tells.
        public static func coverage(_ device: DeviceStatus, current: [Current], reports: [JamfPlatform.DeclarationReport]?) -> Coverage? {
            guard device.category != .onTarget, device.category != .targetUnknown,
                  let version = OSVersion(device.currentOS), let target = device.targetVersion.flatMap(OSVersion.init),
                  target > version else { return nil }
            let pairs = DeclarationPair.pairs(reports ?? [])
            // a declaration that applies on the device covers it
            if pairs.contains(where: { $0.isActive && !$0.isNotForThisDevice && !$0.reports.contains { $0.status == .awaitingSync } }) {
                return nil
            }
            let ids = [device.boardID, device.modelIdentifier.isEmpty ? nil : device.modelIdentifier].compactMap { $0 }
            let own = current.filter { $0.family.map { $0 == device.osName } ?? true }
            let covering = own.filter { $0.applies(osName: device.osName, ids: ids, version: version) == true }
            if !covering.isEmpty {
                // Jamf's current declarations cover it; the device's own report predates them: none,
                // awaiting sync, or the same declaration with an older condition (other versions)
                let fetched = covering.contains { declaration in
                    pairs.contains { pair in
                        let own = pair.predicate.flatMap(DeclarationPair.covered).map(Set.init)
                        return pair.key == declaration.key && !pair.reports.contains { $0.status == .awaitingSync }
                            && (own == nil || declaration.covered == nil || own == declaration.covered)
                    }
                }
                return fetched ? nil : .notFetched(lastReport: (reports ?? []).compactMap(\.lastReportTime).max())
            }
            let listing = own.filter { declaration in ids.contains { declaration.lists($0) } }
            let sameMajor = listing.filter { $0.upperBound?.major == version.major }
            guard !sameMajor.isEmpty, sameMajor.allSatisfy({ $0.upperBound.map { $0 < version } ?? false }) else { return nil }
            let ranges = sameMajor.compactMap { $0.range.map { "\(device.osName) \($0)" } }
            return .notCovered(Array(NSOrderedSet(array: ranges)).compactMap { $0 as? String }.joined(separator: "; "))
        }

        /// A failed or invalid update declaration for the device’s own OS, as
        /// its list diagnosis: “Update declaration failed: …”; nil without one.
        static func declarationProblem(_ reports: [JamfPlatform.DeclarationReport], osName: String, current: [Current],
                                       names: [String: String]) -> String? {
            let families = Dictionary(current.map { ($0.key, $0.family) }, uniquingKeysWith: { first, _ in first })
            let states = DeclarationPair.pairs(reports)
                .filter { pair in (families[pair.key] ?? nil).map { $0 == osName } ?? true }
                .map { $0.state(names: names) }
            if let invalid = states.first(where: { $0.hasPrefix("Invalid: ") }) {
                return "Update declaration invalid: " + invalid.dropFirst("Invalid: ".count)
            }
            if let failed = states.first(where: { $0.hasPrefix("Failed: ") }) {
                return "Update declaration failed: " + failed.dropFirst("Failed: ".count)
            }
            return nil
        }

        // MARK: Texts

        /// The cause as the device list says it.
        public static func diagnosis(_ coverage: Coverage, device: DeviceStatus) -> String {
            switch coverage {
            case .notCovered: "Jamf’s update doesn’t cover \(device.osName) \(device.currentOS) yet"
            case .notFetched(let last):
                "Hasn’t fetched Jamf’s current declarations yet" + (last.map { " (last reported \(InspectFindings.day($0)))" } ?? "")
            }
        }

        /// The categories whose diagnosis the cause replaces: the device isn’t
        /// updating and nothing else explains it better.
        static let explainedCategories: Set<StatusCategory> = [.notStarted, .noActivity]

        /// The dashboard’s line, nil when no device is affected.
        public static func dashboardLine(_ count: Int) -> String? {
            guard count > 0 else { return nil }
            return count == 1 ? "1 device is on a version the Blueprint’s update doesn’t cover yet"
                : "\(count) devices are on a version the Blueprint’s update doesn’t cover yet"
        }

        /// The collapsed line for declarations that apply to no device.
        public static func othersLine(_ count: Int, inScope: Bool) -> String? {
            guard count > 0 else { return nil }
            let subject = count == 1 ? "1 other declaration doesn’t" : "\(count) others don’t"
            return inScope ? "\(subject) apply to any device in scope" : "\(subject) apply to this device"
        }

        /// Names made unique, in order: a second “‹Blueprint›, iPadOS” reads
        /// “‹Blueprint›, iPadOS (2)”.
        public static func uniqueNames(_ lines: [DeclarationLine]) -> [DeclarationLine] {
            var seen: [String: Int] = [:]
            return lines.map { line in
                seen[line.name, default: 0] += 1
                let count = seen[line.name] ?? 1
                return count == 1 ? line : DeclarationLine(name: "\(line.name) (\(count))", state: line.state)
            }
        }

        /// Every stored property, in order, with the same defaults as the memberwise initializer.
        public init(
            declarations: [Declaration] = [],
            inapplicable: Int = 0,
            current: [Current] = [],
            coverage: [String: Coverage] = [:],
            unmatchedDevices: Int = 0,
            devicesWithoutPlatformID: Int = 0,
            problems: [String] = []
        ) {
            self.declarations = declarations
            self.inapplicable = inapplicable
            self.current = current
            self.coverage = coverage
            self.unmatchedDevices = unmatchedDevices
            self.devicesWithoutPlatformID = devicesWithoutPlatformID
            self.problems = problems
        }
    }
}
