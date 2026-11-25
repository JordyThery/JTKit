import Foundation

extension SoftwareUpdateRules {
    /// The first public posting date this app saw of each build, per platform,
    /// version and build (`PostingBasis.key`), kept from then on: Apple can
    /// re-date a build that is already public, and Jamf keeps the deadline it
    /// counted from the first. Stored under `firstPublicPostings`; Demo Mode’s
    /// in memory only.
    public nonisolated enum FirstPostings {

        /// `known` with the public postings of `catalog` it doesn’t have yet;
        /// a date already known is never replaced.
        public static func merged(_ known: [String: Date], with catalog: AppleReleases.Catalog) -> [String: Date] {
            var merged = known
            for release in catalog.releases {
                for posting in release.postings where posting.isPublic {
                    let key = PostingBasis.key(release.platform, release.version, build: posting.build)
                    guard let date = posting.date, known[key] == nil else { continue }
                    // the same build posted on two days in one read: the earlier
                    merged[key] = min(merged[key] ?? date, date)
                }
            }
            return merged
        }

    }
}
