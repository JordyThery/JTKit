import Foundation

// `ContentCacheRules`, its savings and health: JTKitContentCaching (1.12.0).

// MARK: - A series of sweeps

extension ContentCacheRules {
    /// What an app keeps of one cache per sweep, for the trend. Codable, so
    /// it can be saved as it is.
    public struct CacheSnapshot: Hashable, Sendable, Codable {
        public var date: Date
        /// The cache’s identity across sweeps: Jamf Pro’s computer ID.
        public var cacheID: String
        public var countersSince: Date?
        public var serverGuid: String?
        public var served: Int64
        public var fromOrigin: Int64
        public var used: Int64?
        public var pressurePercent: Int?
        public var health: CacheHealth.Level

        public init(date: Date, cacheID: String, countersSince: Date? = nil, serverGuid: String? = nil, served: Int64 = 0,
                    fromOrigin: Int64 = 0, used: Int64? = nil, pressurePercent: Int? = nil, health: CacheHealth.Level = .ok) {
            self.date = date
            self.cacheID = cacheID
            self.countersSince = countersSince
            self.serverGuid = serverGuid
            self.served = served
            self.fromOrigin = fromOrigin
            self.used = used
            self.pressurePercent = pressurePercent
            self.health = health
        }

        public var savings: Int64 { max(served - fromOrigin, 0) }
    }

    /// What one cache did between two sweeps.
    public struct Delta: Hashable, Sendable {
        public var cacheID: String
        public var from: Date
        public var to: Date
        public var served: Int64
        public var fromOrigin: Int64
        /// The counters started again in between: the cache was reset or
        /// activated again. The delta is then what the counters show now.
        public var isReset: Bool

        public init(cacheID: String, from: Date, to: Date, served: Int64, fromOrigin: Int64, isReset: Bool) {
            self.cacheID = cacheID
            self.from = from
            self.to = to
            self.served = served
            self.fromOrigin = fromOrigin
            self.isReset = isReset
        }

        public var saved: Int64 { max(served - fromOrigin, 0) }
    }

    public enum Series {
        /// Whether the counters started again between two sweeps of one
        /// cache: their start moved, the cache’s GUID changed (activated
        /// again), or a counter went down.
        public static func isReset(from previous: CacheSnapshot, to next: CacheSnapshot) -> Bool {
            if let a = previous.countersSince, let b = next.countersSince, abs(a.timeIntervalSince(b)) >= 1 { return true }
            if let a = previous.serverGuid, let b = next.serverGuid, a.caseInsensitiveCompare(b) != .orderedSame { return true }
            return next.served < previous.served || next.fromOrigin < previous.fromOrigin
        }

        /// The deltas between consecutive sweeps of each cache, oldest first.
        public static func deltas(_ snapshots: [CacheSnapshot]) -> [Delta] {
            Dictionary(grouping: snapshots, by: \.cacheID).flatMap { cacheID, list -> [Delta] in
                let sorted = list.sorted { $0.date < $1.date }
                return zip(sorted, sorted.dropFirst()).map { previous, next in
                    let reset = isReset(from: previous, to: next)
                    return Delta(cacheID: cacheID, from: previous.date, to: next.date,
                                 served: reset ? next.served : next.served - previous.served,
                                 fromOrigin: reset ? next.fromOrigin : next.fromOrigin - previous.fromOrigin, isReset: reset)
                }
            }.sorted { ($0.to, $0.cacheID) < ($1.to, $1.cacheID) }
        }

        /// Bytes served and fetched in the deltas that end after `since`
        /// (e.g. the last 30 days), per cache or for every cache.
        public static func total(_ deltas: [Delta], since: Date, cacheID: String? = nil) -> (served: Int64, fromOrigin: Int64, saved: Int64) {
            let chosen = deltas.filter { $0.to > since && (cacheID == nil || $0.cacheID == cacheID) }
            let served = chosen.map(\.served).reduce(0, +)
            let fromOrigin = chosen.map(\.fromOrigin).reduce(0, +)
            return (served, fromOrigin, chosen.map(\.saved).reduce(0, +))
        }
    }
}
