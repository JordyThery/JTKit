import Foundation

/// The content caching rules (1.11.0): what a Mac’s content cache saved,
/// whether it is healthy, and how its counters move between sweeps; and the
/// sweep that reads every cache of a tenant (`Sweep`). Read only, GET only.
/// Saves nothing: the app keeps its sweeps (`CacheSnapshot`) and passes
/// them back in.
///
/// Savings and health live in `JTKitContentCaching` (1.12.0), which needs
/// Foundation only, so an iOS app can use them without the rest of JTKit;
/// the series of sweeps and the sweep itself are JTKit’s.
public nonisolated enum ContentCacheRules {}

// MARK: - Savings

extension ContentCacheRules {
    /// What a cache saved since its counters started: bytes it returned to
    /// clients, peers and children, minus bytes it had to fetch from
    /// Apple (the origin). Never below zero.
    ///
    /// Apple’s counters don’t split personal (iCloud) content from shared
    /// content, so when the cache holds personal content the bytes served
    /// may include some (`includesPersonal`); personal bytes kept on disk
    /// are never added.
    public struct Savings: Hashable, Sendable, Codable {
        public var served: Int64
        public var fromOrigin: Int64
        public var since: Date?
        /// iCloud bytes the cache holds, shown beside the savings, never in them.
        public var personalUsed: Int64

        public init(served: Int64 = 0, fromOrigin: Int64 = 0, since: Date? = nil, personalUsed: Int64 = 0) {
            self.served = served
            self.fromOrigin = fromOrigin
            self.since = since
            self.personalUsed = personalUsed
        }

        public var saved: Int64 { max(served - fromOrigin, 0) }
        public var includesPersonal: Bool { personalUsed > 0 }

        public static func compute(_ caching: ContentCaching) -> Savings {
            let served = (caching.returnedToClients ?? 0) + (caching.returnedToPeers ?? 0) + (caching.returnedToChildren ?? 0)
            let personal = caching.personalUsed ?? caching.categories.filter(\.isPersonal).map(\.bytes).reduce(0, +)
            return Savings(served: served, fromOrigin: caching.storedFromOrigin ?? 0, since: caching.countersSince,
                           personalUsed: personal)
        }
    }
}

// MARK: - Health

extension ContentCacheRules {
    /// A cache’s health with the reasons for it, most serious first.
    /// How full the cache is is never a reason: a content cache fills to
    /// its limit by design and evicts what is least used; pressure is the
    /// signal that it is too small.
    public struct CacheHealth: Hashable, Sendable, Codable {
        public enum Level: String, Hashable, Sendable, Codable, Comparable, CaseIterable {
            case ok, warning, fault

            private var rank: Int {
                switch self {
                case .ok: 0
                case .warning: 1
                case .fault: 2
                }
            }

            public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }

            public var title: String {
                switch self {
                case .ok: "OK"
                case .warning: "Warning"
                case .fault: "Fault"
                }
            }
        }

        /// The limits the rules use; the defaults are the ones decided by Jordy on 2026-11-26.
        public struct Thresholds: Hashable, Sendable, Codable {
            /// Warning at or above this cache pressure in the last hour, in percent.
            public var warningPressure = 50
            /// Warning for an alert posted within this many seconds.
            public var alertWindow: TimeInterval = 24 * 3_600
            /// Warning when the last inventory report is older than this.
            public var warningReportAge: TimeInterval = 48 * 3_600
            /// Fault when it is older than this.
            public var faultReportAge: TimeInterval = 7 * 24 * 3_600

            public init() {}
        }

        public var level: Level
        public var reasons: [String]

        public init(level: Level = .ok, reasons: [String] = []) {
            self.level = level
            self.reasons = reasons
        }

        /// The worst level of several caches (e.g. one site’s); nil for none.
        public static func worst(of healths: [CacheHealth]) -> Level? {
            healths.map(\.level).max()
        }

        /// The rules:
        /// - **Fault:** activated but not active; a cache or startup status
        ///   other than OK; registration failed; every parent unhealthy; no
        ///   inventory report for longer than `faultReportAge`.
        /// - **Warning:** registration pending; pressure at or above
        ///   `warningPressure`; a parent unhealthy; an alert within
        ///   `alertWindow`; data moving to another volume, or a failed move;
        ///   no inventory report for longer than `warningReportAge`; the
        ///   caching declaration not applied (`declarationApplied` false).
        ///
        /// The macOS 27 status items, when newer than the inventory report,
        /// decide active, the statuses, pressure and the parents’ health.
        ///
        /// - Parameters:
        ///   - reportDate: the Mac’s last inventory report (`general.reportDate`).
        ///   - serverTimeZone: the zone Jamf Pro writes status item times in.
        ///   - declarationApplied: whether the caching Blueprint’s declaration
        ///     is applied on this Mac; nil when no caching Blueprint sends it one.
        public static func evaluate(_ caching: ContentCaching, status: ContentCacheStatus? = nil,
                                    reportDate: Date?, declarationApplied: Bool? = nil,
                                    serverTimeZone: TimeZone = TimeZone(identifier: "UTC") ?? .gmt,
                                    thresholds: Thresholds = Thresholds(), now: Date = Date()) -> CacheHealth {
            var faults: [String] = []
            var warnings: [String] = []
            func isNewer(_ text: String?) -> Bool {
                guard let text, let date = ServerTime.date(text, timeZone: serverTimeZone) else { return false }
                guard let reportDate else { return true }
                return date > reportDate
            }
            let live = isNewer(status?.status?.updated) ? status?.status : nil
            let liveInfo = isNewer(status?.info?.updated) ? status?.info : nil
            let liveParents = status.flatMap { status in
                isNewer(status.status?.updated) || isNewer(status.info?.updated) ? status.parents : nil
            }

            let activated = live?.isActivated ?? caching.isActivated
            let active = live?.isActive ?? caching.isActive
            if activated == true, active == false { faults.append("Activated but not running") }
            if let text = live?.cacheStatus ?? liveInfo?.cacheStatus ?? caching.cacheStatus, !isOK(text) {
                faults.append("Cache status: \(text)")
            }
            if let text = live?.startupStatus ?? caching.startupStatus, !isOK(text) {
                faults.append("Startup status: \(text)")
            }
            switch caching.registration {
            case .failed?:
                faults.append(caching.registrationError.map { "Registration with Apple failed: \($0)" } ?? "Registration with Apple failed")
            case .pending?:
                warnings.append("Registration with Apple pending")
            default:
                break
            }

            let parentHealth: [Bool] = liveParents.map { $0.compactMap(\.isHealthy) } ?? caching.parents.compactMap(\.isHealthy)
            let unhealthy = parentHealth.filter { !$0 }.count
            if !parentHealth.isEmpty, unhealthy == parentHealth.count {
                faults.append(parentHealth.count == 1 ? "Its parent cache is unhealthy" : "Every parent cache is unhealthy")
            } else if unhealthy > 0 {
                warnings.append(unhealthy == 1 ? "A parent cache is unhealthy" : "\(unhealthy) parent caches are unhealthy")
            }

            if let pressure = liveInfo?.pressurePercent ?? caching.pressurePercent, pressure >= thresholds.warningPressure {
                warnings.append("Cache pressure \(pressure) % in the last hour")
            }
            let recent = caching.alerts.filter { alert in
                alert.posted.map { now.timeIntervalSince($0) <= thresholds.alertWindow } ?? false
            }
            if !recent.isEmpty {
                let names = recent.compactMap(\.className).map(alertName)
                warnings.append(names.isEmpty ? "A recent alert" : "Recent alert: \(Array(Set(names)).sorted().joined(separator: ", "))")
            }
            if let migration = caching.dataMigration {
                if migration.failed { warnings.append("Moving its data failed") }
                else if migration.isMoving { warnings.append("Moving its data (\(migration.percent ?? 0) %)") }
            }
            if declarationApplied == false { warnings.append("The caching Blueprint’s declaration isn’t applied") }

            if let reportDate {
                let age = now.timeIntervalSince(reportDate)
                if age > thresholds.faultReportAge {
                    faults.append("No inventory report for \(days(age)) days")
                } else if age > thresholds.warningReportAge {
                    warnings.append("No inventory report for \(days(age)) days")
                }
            } else {
                warnings.append("No inventory report date")
            }

            if !faults.isEmpty { return CacheHealth(level: .fault, reasons: faults + warnings) }
            if !warnings.isEmpty { return CacheHealth(level: .warning, reasons: warnings) }
            return CacheHealth()
        }

        private static func isOK(_ text: String) -> Bool { text.uppercased() == "OK" }

        private static func days(_ seconds: TimeInterval) -> Int { max(Int(seconds / 86_400), 1) }

        /// `com.apple.AssetCache.LowSpaceAlert` → “Low Space”.
        static func alertName(_ className: String) -> String {
            var name = className.split(separator: ".").last.map(String.init) ?? className
            if name.hasSuffix("Alert"), name.count > 5 { name.removeLast(5) }
            return name.replacing(/([a-z])([A-Z])/) { "\($0.output.1) \($0.output.2)" }
        }
    }
}
