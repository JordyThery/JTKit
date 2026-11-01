import Foundation

/// A release version read strictly from a tag: “1.2.3”, “v1.2.3”, “1.2” or
/// “v2”, optionally with a suffix after “-” (“1.2.1-hotfix”). Tags that
/// aren’t a version (“v.0.0.44”, “nightly”, “2026-10-31”) give nil.
/// Compares numerically, a missing part counting as zero (1.10 > 1.9, 1.2 == 1.2.0).
public nonisolated struct ReleaseVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]
    /// What came after the first “-”, e.g. "hotfix"; not compared.
    public let suffix: String?

    public init?(tag: String) {
        var text = Substring(tag.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        var suffix: String?
        if let dash = text.firstIndex(of: "-") {
            suffix = String(text[text.index(after: dash)...])
            text = text[..<dash]
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 9 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        // a date-like tag such as 2026-10-31 has no dots and four digits
        if parts.count == 1, suffix != nil, parts[0].count == 4 { return nil }
        components = parts.compactMap { Int($0) }
        self.suffix = suffix.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var description: String {
        components.map(String.init).joined(separator: ".") + (suffix.map { "-\($0)" } ?? "")
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        compare(lhs, rhs) == 0
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        compare(lhs, rhs) < 0
    }

    private static func compare(_ a: ReleaseVersion, _ b: ReleaseVersion) -> Int {
        for index in 0..<max(a.components.count, b.components.count) {
            let left = index < a.components.count ? a.components[index] : 0
            let right = index < b.components.count ? b.components[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

/// One release of a GitHub repository.
public nonisolated struct GitHubRelease: Sendable, Hashable {
    public struct Asset: Sendable, Hashable {
        public let name: String
        public let downloadURL: URL?
    }

    public let tag: String
    /// Nil when the tag isn’t a version.
    public let version: ReleaseVersion?
    public let name: String?
    public let notes: String?
    public let pageURL: URL?
    public let assets: [Asset]
    public let isDraft: Bool
    public let isPrerelease: Bool
}

/// Reading a repository’s releases from GitHub, without signing in.
public nonisolated enum GitHubReleases {
    public struct Failure: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The highest published version: reads the newest releases and skips
    /// drafts, prereleases and tags that aren’t a version (GitHub’s own
    /// “latest” can be such a tag). Nil when none is a version.
    /// - Parameter pageSize: how many of the newest releases are read (at most 100).
    public static func latest(owner: String, repo: String, session: URLSession = .shared,
                              pageSize: Int = 30) async throws -> GitHubRelease? {
        var best: (version: ReleaseVersion, release: GitHubRelease)?
        // newest first: of two tags for the same version, the newer one wins
        for release in try await list(owner: owner, repo: repo, session: session, pageSize: pageSize)
        where !release.isDraft && !release.isPrerelease {
            guard let version = release.version else { continue }
            if let current = best, version <= current.version { continue }
            best = (version, release)
        }
        return best?.release
    }

    /// The newest releases, as GitHub lists them (newest first).
    public static func list(owner: String, repo: String, session: URLSession = .shared,
                            pageSize: Int = 30) async throws -> [GitHubRelease] {
        guard let url = releasesURL(owner: owner, repo: repo, pageSize: pageSize) else {
            throw Failure(message: "The release address is invalid.")
        }
        let data = try await get(url, session: session)
        do {
            return try JSONDecoder().decode([Payload].self, from: data).map(\.release)
        } catch {
            throw Failure(message: "GitHub’s release list couldn’t be read.")
        }
    }

    static func releasesURL(owner: String, repo: String, pageSize: Int) -> URL? {
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return URL(string: "https://api.github.com/repos/\(segment(owner))/\(segment(repo))/releases?per_page=\(min(max(pageSize, 1), 100))")
    }

    private static func segment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? text
    }

    private static func get(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request.withDefaultUserAgent())
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(message: "GitHub answered with HTTP \(status).") }
        return data
    }

    private struct Payload: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [AssetPayload]?

        struct AssetPayload: Decodable {
            let name: String
            let browser_download_url: String
        }

        var release: GitHubRelease {
            GitHubRelease(tag: tag_name, version: ReleaseVersion(tag: tag_name), name: name, notes: body,
                          pageURL: html_url.flatMap(URL.init(string:)),
                          assets: (assets ?? []).map { GitHubRelease.Asset(name: $0.name, downloadURL: URL(string: $0.browser_download_url)) },
                          isDraft: draft ?? false, isPrerelease: prerelease ?? false)
        }
    }
}
