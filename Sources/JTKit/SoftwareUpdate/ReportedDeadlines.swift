import Foundation

extension SoftwareUpdateRules {
    /// What a tracked Blueprint’s devices reported about Jamf’s deadlines,
    /// remembered between refreshes, per platform and version
    /// (`PostingBasis.key`). The app saves it, e.g. next to the Blueprint’s
    /// history (JTKit saves nothing): it comes in as `Reader.reportedDeadlines`
    /// and what to keep goes back in `Reader.Reading.reportedDeadlines`. Its
    /// Codable field names never change.
    ///
    /// - The posting date Jamf counted from (`TargetRules.reportedPosting`):
    ///   kept while the version is the rule’s target and the Blueprint hasn’t
    ///   changed since, so its deadline keeps counting after the devices that
    ///   reported it have installed.
    /// - The deadlines themselves, as moments to the minute: kept for 180 days
    ///   (like the history), also after the version stopped being the target,
    ///   so a Mac’s older pending version is recognized as this Blueprint’s
    ///   earlier step by its exact deadline.
    public nonisolated struct ReportedDeadlines: Codable, Sendable, Hashable {
        public struct Posting: Codable, Sendable, Hashable {
            public var posted: Date
            /// The refresh that last found it reported.
            public var seen: Date

            /// Every stored property, in order, with the same defaults as the memberwise initializer.
            public init(
                posted: Date,
                seen: Date
            ) {
                self.posted = posted
                self.seen = seen
            }
        }

        public struct Moment: Codable, Sendable, Hashable {
            /// Minutes since 1970 (`PostingBasis.minute`).
            public var minute: Int
            /// The refresh that first found it reported.
            public var seen: Date

            /// Every stored property, in order, with the same defaults as the memberwise initializer.
            public init(
                minute: Int,
                seen: Date
            ) {
                self.minute = minute
                self.seen = seen
            }
        }

        public var postings: [String: Posting] = [:]
        public var moments: [String: [Moment]] = [:]

        static let retentionDays = 180

        public var isEmpty: Bool { postings.isEmpty && moments.isEmpty }

        /// The remembered posting dates and deadlines a refresh counts with:
        /// a posting only for a version that is still a rule’s target
        /// (`targets`), and only when the Blueprint hasn’t changed since it was
        /// last reported.
        public func basis(targets: Set<String>, blueprintChanged: Date?) -> (postings: [String: Date], minutes: [String: Set<Int>]) {
            let postings = postings.filter { key, posting in
                targets.contains(key) && blueprintChanged.map { $0 < posting.seen } ?? true
            }
            return (postings.mapValues(\.posted), moments.mapValues { Set($0.map(\.minute)) })
        }

        /// After a refresh: the posting dates it found reported replace those
        /// remembered; others stay while their version is a rule’s target and
        /// the Blueprint hasn’t changed since. New deadlines are added; those
        /// first seen more than 180 days ago go.
        public func updated(reported: [String: Date], moments found: [String: Set<Int>], targets: Set<String>,
                     blueprintChanged: Date?, now: Date) -> ReportedDeadlines {
            var next = ReportedDeadlines()
            for (key, posting) in postings where targets.contains(key) && (blueprintChanged.map { $0 < posting.seen } ?? true) {
                next.postings[key] = posting
            }
            for (key, posted) in reported { next.postings[key] = Posting(posted: posted, seen: now) }
            let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
            for (key, kept) in moments {
                let recent = kept.filter { $0.seen >= cutoff }
                if !recent.isEmpty { next.moments[key] = recent }
            }
            for (key, minutes) in found {
                var kept = next.moments[key] ?? []
                let known = Set(kept.map(\.minute))
                kept += minutes.subtracting(known).sorted().map { Moment(minute: $0, seen: now) }
                next.moments[key] = kept
            }
            return next
        }

        /// Every stored property, in order, with the same defaults as the memberwise initializer.
        public init(
            postings: [String: Posting] = [:],
            moments: [String: [Moment]] = [:]
        ) {
            self.postings = postings
            self.moments = moments
        }
    }
}
