import CoreServices
import Foundation
import Observation

/// Checks GitHub for a newer release of the app.
///
/// A notifier and downloader, not an installer: replacing a running, signed app
/// stays a manual step. Talks only to GitHub, never to a tenant API.
@MainActor
@Observable
public final class UpdateChecker {
    /// A published release, reduced to what the update sheet shows.
    public nonisolated struct Release: Sendable, Equatable {
        public let version: String
        public let name: String
        /// GitHub’s release notes, as written (Markdown).
        public let notes: String
        /// The release’s .zip asset, when it has one.
        public let downloadURL: URL?
        public let pageURL: URL?

        public init(version: String, name: String, notes: String, downloadURL: URL?, pageURL: URL?) {
            self.version = version
            self.name = name
            self.notes = notes
            self.downloadURL = downloadURL
            self.pageURL = pageURL
        }
    }

    public enum Status: Equatable, Sendable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    /// Default `UserDefaults` key for the automatic check, shared by every app.
    /// Absent means on. Suitable for `@AppStorage` toggles.
    public nonisolated static let automaticCheckKey = "checksForUpdates"

    public let configuration: UpdateConfiguration
    public private(set) var status: Status = .idle
    /// Whether the update sheet is shown: always for a manual check, and for the
    /// automatic one only when it finds a new release.
    public var isPresented = false

    /// Receives one line per check outcome (shown nowhere by default).
    @ObservationIgnored private let activity: (@MainActor (String) -> Void)?
    /// Also read by `UpdateSettingsSection`, so the switch and the check share one store.
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let installedVersion: String?
    /// A sandbox run (`-JTKitSandbox YES`, UI tests) never checks.
    @ObservationIgnored let isSandbox: Bool

    /// - Parameters:
    ///   - configuration: the app’s repository, name and storage keys.
    ///   - activity: receives one line per check outcome, for an app’s own log.
    ///   - defaults: where the check preferences live; the app’s standard defaults.
    ///   - session: the URL session used for the check and the download; injectable for tests.
    ///   - installedVersion: overrides the app bundle’s version; for tests only.
    ///   - arguments: the launch arguments; the running app’s by default.
    public init(
        configuration: UpdateConfiguration,
        activity: (@MainActor (String) -> Void)? = nil,
        defaults: UserDefaults = .standard,
        session: URLSession = .shared,
        installedVersion: String? = nil,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.configuration = configuration
        self.activity = activity
        self.defaults = defaults
        self.session = session
        self.installedVersion = installedVersion
        isSandbox = DemoMode.isSandbox(arguments: arguments)
    }

    public var currentVersion: String {
        installedVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// At most once a day; interrupts only for a release not offered before. Failures
    /// are reported to `activity` but not shown.
    /// The last-check date is set only when the check worked, so a failed
    /// one is tried again at the next launch.
    public func checkAutomatically() async {
        guard !isSandbox else { return }
        guard defaults.object(forKey: configuration.automaticCheckKey) == nil
                || defaults.bool(forKey: configuration.automaticCheckKey) else { return }
        let lastCheck = defaults.object(forKey: configuration.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastCheck) >= configuration.automaticCheckInterval else { return }
        guard let release = try? await fetchLatestRelease() else { return }
        defaults.set(Date(), forKey: configuration.lastCheckKey)
        guard Self.isNewer(release.version, than: currentVersion),
              release.version != defaults.string(forKey: configuration.lastOfferedKey) else { return }
        defaults.set(release.version, forKey: configuration.lastOfferedKey)
        status = .available(release)
        isPresented = true
    }

    /// Checks now and shows the result either way.
    public func checkManually() {
        isPresented = true
        guard !isSandbox else {
            status = .failed(Self.sandboxMessage)
            return
        }
        status = .checking
        Task {
            do {
                let release = try await fetchLatestRelease()
                status = Self.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        struct Response: Decodable {
            let tag_name: String
            let name: String?
            let body: String?
            let html_url: String?
            let assets: [Asset]?
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
        }
        guard let url = configuration.latestReleaseURL else { throw UpdateError(message: "The release address is invalid.") }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request.withDefaultUserAgent())
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                throw UpdateError(message: "GitHub answered with HTTP \(status).")
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let version = decoded.tag_name.hasPrefix("v") ? String(decoded.tag_name.dropFirst()) : decoded.tag_name
            let downloadURL = decoded.assets?.first { $0.name.hasSuffix(".zip") }
                .flatMap { URL(string: $0.browser_download_url) }
            let pageURL = decoded.html_url.flatMap(URL.init(string:))
            // Only offer this app’s own downloads and pages, on GitHub over HTTPS.
            guard downloadURL.map({ Self.isTrustedDownload($0, configuration: configuration) }) ?? true,
                  pageURL.map({ Self.isTrustedPage($0, configuration: configuration) }) ?? true else {
                throw UpdateError(message: "The release points at an unexpected download location, so it wasn’t offered.")
            }
            activity?("Update check: latest release \(version), installed \(currentVersion).")
            return Release(
                version: version,
                name: decoded.name ?? "\(configuration.appName) \(version)",
                notes: decoded.body ?? "",
                downloadURL: downloadURL,
                pageURL: pageURL
            )
        } catch {
            activity?("Update check failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Whether a release URL is on GitHub over HTTPS (github.com, its
    /// subdomains, or GitHub’s download host githubusercontent.com).
    nonisolated static func isTrustedHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        return host == "github.com"
            || host.hasSuffix(".github.com")
            || host.hasSuffix(".githubusercontent.com")
    }

    /// Whether the asset is one of this app’s own releases:
    /// `https://github.com/<owner>/<repository>/releases/download/…`.
    nonisolated static func isTrustedDownload(_ url: URL, configuration: UpdateConfiguration) -> Bool {
        isOnRepository(url, configuration: configuration, under: ["releases", "download"])
    }

    /// Whether the release page is on this app’s own repository.
    nonisolated static func isTrustedPage(_ url: URL, configuration: UpdateConfiguration) -> Bool {
        isOnRepository(url, configuration: configuration, under: ["releases"])
    }

    private nonisolated static func isOnRepository(_ url: URL, configuration: UpdateConfiguration, under folders: [String]) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host()?.lowercased() == "github.com", url.port == nil else { return false }
        let parts = url.path(percentEncoded: false).split(separator: "/").map { $0.lowercased() }
        let expected = [configuration.owner.lowercased(), configuration.repository.lowercased()] + folders
        return parts.count > expected.count && Array(parts.prefix(expected.count)) == expected
    }

    // MARK: Download

    /// Downloads the release’s zip with the checker’s session, straight to
    /// a file, re-checking every redirect (GitHub hands the asset to
    /// githubusercontent.com), and marks the file as downloaded from the
    /// internet, so Gatekeeper checks the app inside before it first opens.
    /// - Returns: the zip, in a folder of its own in the temporary directory.
    public func download(_ release: Release) async throws -> URL {
        guard !isSandbox else { throw UpdateError(message: Self.sandboxMessage) }
        guard let url = release.downloadURL, Self.isTrustedDownload(url, configuration: configuration) else {
            throw UpdateError(message: "The release points at an unexpected download location, so it wasn’t downloaded.")
        }
        let delegate = RedirectDelegate { _, target in target.map(Self.isTrustedHost) ?? false }
        let (file, response) = try await session.download(for: URLRequest(url: url).withDefaultUserAgent(), delegate: delegate)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateError(message: "The download failed (HTTP \(status)).")
        }
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "JTKitUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = folder.appending(path: url.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: saved)
        try Self.quarantine(saved, from: url, appName: configuration.appName)
        return saved
    }

    /// Gives a downloaded file the quarantine attribute a browser gives it.
    nonisolated static func quarantine(_ file: URL, from source: URL, appName: String) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: appName,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineDataURLKey as String: source.absoluteString,
        ]
        var file = file
        try file.setResourceValues(values)
    }

    nonisolated static let sandboxMessage = "Update checks are off in this test run."

    /// Numeric component comparison, so 1.10 is newer than 1.9 and a missing
    /// component counts as zero. A component compares by its leading digits, so a
    /// suffixed tag such as 1.2.1-hotfix still counts as 1.2.1.
    public nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let b = current.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    public nonisolated struct UpdateError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }

        public init(message: String) {
            self.message = message
        }
    }
}
