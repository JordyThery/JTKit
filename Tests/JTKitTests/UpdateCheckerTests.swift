import Foundation
import Testing
import JTKitTestSupport
@testable import JTKit

@Suite("Update version comparison")
struct UpdateVersionTests {
    @Test func comparesNumericComponents() {
        #expect(UpdateChecker.isNewer("1.10", than: "1.9"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0.1"))
        #expect(!UpdateChecker.isNewer("1.2", than: "1.2"))
        #expect(UpdateChecker.isNewer("2", than: "1.9.9"))
        #expect(!UpdateChecker.isNewer("1.9", than: "1.10"))
        #expect(UpdateChecker.isNewer("1.1.1", than: "1.1"))
        #expect(!UpdateChecker.isNewer("1.1.0", than: "1.1"))
    }

    @Test func suffixedTagsCompareByLeadingDigits() {
        #expect(UpdateChecker.isNewer("1.2.1-hotfix", than: "1.2"))
        #expect(!UpdateChecker.isNewer("1.2.0-beta", than: "1.2"))
    }
}

@Suite("Update download location")
struct UpdateTrustedHostTests {
    @Test(arguments: [
        "https://github.com/x/y/releases/download/v1/a.zip",
        "https://api.github.com/repos/x/y",
        "https://objects.githubusercontent.com/a.zip",
    ])
    func acceptsGitHubOverHTTPS(_ address: String) throws {
        #expect(UpdateChecker.isTrustedHost(try #require(URL(string: address))))
    }

    @Test(arguments: [
        "https://example.com/a.zip",
        "http://github.com/a.zip",
        "https://github.com.evil.example/a.zip",
        "https://evilgithub.com/a.zip",
        "file:///tmp/a.zip",
    ])
    func rejectsOtherHostsAndSchemes(_ address: String) throws {
        #expect(!UpdateChecker.isTrustedHost(try #require(URL(string: address))))
    }
}

/// The checker against a mocked GitHub. The mock handler is global, so this
/// suite runs serialized.
@Suite("Update checker", .serialized)
@MainActor
struct UpdateCheckerTests {
    private nonisolated static let releaseJSON = #"""
    {
      "tag_name": "v2.5",
      "name": "TestApp 2.5",
      "body": "- Fixes",
      "html_url": "https://github.com/JordyThery/TestApp/releases/tag/v2.5",
      "assets": [
        {"name": "TestApp-2.5.dmg", "browser_download_url": "https://github.com/JordyThery/TestApp/releases/download/v2.5/TestApp-2.5.dmg"},
        {"name": "TestApp-2.5.zip", "browser_download_url": "https://github.com/JordyThery/TestApp/releases/download/v2.5/TestApp-2.5.zip"}
      ]
    }
    """#

    private let configuration = UpdateConfiguration(owner: "JordyThery", repository: "TestApp", appName: "TestApp")

    /// Fresh, empty defaults per test, removed afterwards.
    private func makeDefaults() throws -> UserDefaults {
        let name = "JTKitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeChecker(defaults: UserDefaults, version: String = "1.0") -> UpdateChecker {
        UpdateChecker(
            configuration: configuration,
            defaults: defaults,
            session: MockURLProtocol.makeSession(),
            installedVersion: version
        )
    }

    @Test func manualCheckFindsTheRelease() async throws {
        MockURLProtocol.install { request in
            #expect(request.url.absoluteString == "https://api.github.com/repos/JordyThery/TestApp/releases/latest")
            #expect(request.header("Accept") == "application/vnd.github+json")
            return .json(200, Self.releaseJSON)
        }
        let checker = makeChecker(defaults: try makeDefaults())
        checker.checkManually()
        #expect(checker.isPresented)
        try await waitUntil { checker.status != .checking }
        guard case let .available(release) = checker.status else {
            Issue.record("Expected .available, got \(checker.status)"); return
        }
        #expect(release.version == "2.5", "The v prefix is stripped")
        #expect(release.name == "TestApp 2.5")
        #expect(release.downloadURL?.lastPathComponent == "TestApp-2.5.zip", "Only the .zip asset is offered")
        #expect(release.pageURL != nil)
    }

    @Test func manualCheckReportsUpToDate() async throws {
        MockURLProtocol.install { _ in .json(200, Self.releaseJSON) }
        let checker = makeChecker(defaults: try makeDefaults(), version: "2.5")
        checker.checkManually()
        try await waitUntil { checker.status != .checking }
        #expect(checker.status == .upToDate)
    }

    @Test func manualCheckShowsServerErrors() async throws {
        MockURLProtocol.install { _ in .json(404, "{}") }
        let checker = makeChecker(defaults: try makeDefaults())
        checker.checkManually()
        try await waitUntil { checker.status != .checking }
        guard case let .failed(message) = checker.status else {
            Issue.record("Expected .failed, got \(checker.status)"); return
        }
        #expect(message == "GitHub answered with HTTP 404.")
    }

    @Test func automaticCheckOffersANewReleaseOnce() async throws {
        MockURLProtocol.install { _ in .json(200, Self.releaseJSON) }
        let defaults = try makeDefaults()
        let checker = makeChecker(defaults: defaults)
        await checker.checkAutomatically()
        #expect(checker.status == .available(.init(
            version: "2.5", name: "TestApp 2.5", notes: "- Fixes",
            downloadURL: URL(string: "https://github.com/JordyThery/TestApp/releases/download/v2.5/TestApp-2.5.zip"),
            pageURL: URL(string: "https://github.com/JordyThery/TestApp/releases/tag/v2.5")
        )))
        #expect(checker.isPresented)
        #expect(defaults.string(forKey: "lastOfferedUpdate") == "2.5")

        // The same release isn’t offered again, even after the daily interval.
        defaults.removeObject(forKey: "lastUpdateCheck")
        let again = makeChecker(defaults: defaults)
        await again.checkAutomatically()
        #expect(again.status == .idle)
        #expect(!again.isPresented)
    }

    @Test func automaticCheckIgnoresTheCurrentRelease() async throws {
        MockURLProtocol.install { _ in .json(200, Self.releaseJSON) }
        let checker = makeChecker(defaults: try makeDefaults(), version: "2.5")
        await checker.checkAutomatically()
        #expect(MockURLProtocol.requests.count == 1)
        #expect(checker.status == .idle)
        #expect(!checker.isPresented)
    }

    @Test func automaticCheckFailsSilently() async throws {
        MockURLProtocol.install { _ in .json(503, "{}") }
        let checker = makeChecker(defaults: try makeDefaults())
        await checker.checkAutomatically()
        #expect(checker.status == .idle)
        #expect(!checker.isPresented)
    }

    /// A release whose zip or page lives outside GitHub.
    private nonisolated static func releaseJSON(downloadURL: String, pageURL: String) -> String {
        #"""
        {
          "tag_name": "v2.5",
          "html_url": "\#(pageURL)",
          "assets": [{"name": "TestApp-2.5.zip", "browser_download_url": "\#(downloadURL)"}]
        }
        """#
    }

    @Test(arguments: [
        ("https://example.com/TestApp-2.5.zip", "https://github.com/JordyThery/TestApp/releases/tag/v2.5"),
        ("https://github.com/JordyThery/TestApp/releases/download/v2.5/TestApp-2.5.zip", "https://example.com/releases/v2.5"),
        ("http://github.com/dl/TestApp-2.5.zip", "https://github.com/JordyThery/TestApp/releases/tag/v2.5"),
    ])
    func manualCheckRefusesReleasesOutsideGitHub(downloadURL: String, pageURL: String) async throws {
        let json = Self.releaseJSON(downloadURL: downloadURL, pageURL: pageURL)
        MockURLProtocol.install { _ in .json(200, json) }
        let checker = makeChecker(defaults: try makeDefaults())
        checker.checkManually()
        try await waitUntil { checker.status != .checking }
        guard case let .failed(message) = checker.status else {
            Issue.record("Expected .failed, got \(checker.status)"); return
        }
        #expect(message.contains("unexpected download location"))
    }

    @Test func automaticCheckSilentlySkipsReleasesOutsideGitHub() async throws {
        let json = Self.releaseJSON(
            downloadURL: "https://example.com/TestApp-2.5.zip",
            pageURL: "https://github.com/JordyThery/TestApp/releases/tag/v2.5"
        )
        MockURLProtocol.install { _ in .json(200, json) }
        let defaults = try makeDefaults()
        let checker = makeChecker(defaults: defaults)
        await checker.checkAutomatically()
        #expect(checker.status == .idle)
        #expect(!checker.isPresented)
        #expect(defaults.string(forKey: "lastOfferedUpdate") == nil, "A refused release is not marked as offered")
    }

    @Test func automaticCheckHonoursTheToggleAndTheDailyInterval() async throws {
        MockURLProtocol.install { _ in .json(200, Self.releaseJSON) }
        let defaults = try makeDefaults()

        defaults.set(false, forKey: "checksForUpdates")
        let switchedOff = makeChecker(defaults: defaults)
        await switchedOff.checkAutomatically()
        #expect(MockURLProtocol.requests.isEmpty, "Switched off means no request at all")

        defaults.set(true, forKey: "checksForUpdates")
        defaults.set(Date(), forKey: "lastUpdateCheck")
        let tooSoon = makeChecker(defaults: defaults)
        await tooSoon.checkAutomatically()
        #expect(MockURLProtocol.requests.isEmpty, "Checked recently means no request")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                Issue.record("Timed out waiting")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
