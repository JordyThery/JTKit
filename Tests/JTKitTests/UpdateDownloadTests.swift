import CoreServices
import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

@MainActor
@Suite("Update download")
struct UpdateDownloadTests {
    private let configuration = UpdateConfiguration(owner: "JordyThery", repository: "TestApp", appName: "TestApp")
    private let asset = "https://github.com/JordyThery/TestApp/releases/download/v2.5/TestApp-2.5.zip"

    private func makeDefaults() throws -> UserDefaults {
        let name = "JTKitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func checker(_ server: MockServer, defaults: UserDefaults? = nil, arguments: [String] = []) throws -> UpdateChecker {
        UpdateChecker(configuration: configuration, defaults: try defaults ?? makeDefaults(), session: server.session,
                      installedVersion: "1.0", arguments: arguments)
    }

    private func release(_ address: String) -> UpdateChecker.Release {
        UpdateChecker.Release(version: "2.5", name: "TestApp 2.5", notes: "", downloadURL: URL(string: address), pageURL: nil)
    }

    @Test("Only this app’s own release assets are trusted", arguments: [
        ("https://github.com/JordyThery/TestApp/releases/download/v2.5/TestApp-2.5.zip", true),
        ("https://github.com/jordythery/testapp/releases/download/v2.5/TestApp-2.5.zip", true),
        ("https://github.com/Someone/TestApp/releases/download/v2.5/TestApp-2.5.zip", false),
        ("https://github.com/JordyThery/OtherApp/releases/download/v2.5/TestApp-2.5.zip", false),
        ("https://github.com/JordyThery/TestApp/raw/main/TestApp-2.5.zip", false),
        ("https://objects.githubusercontent.com/JordyThery/TestApp/releases/download/v2.5/a.zip", false),
        ("http://github.com/JordyThery/TestApp/releases/download/v2.5/TestApp-2.5.zip", false),
    ])
    func trustedDownload(address: String, trusted: Bool) throws {
        #expect(UpdateChecker.isTrustedDownload(try #require(URL(string: address)), configuration: configuration) == trusted)
    }

    @Test func downloadsToAFileFollowingGitHubsRedirectAndQuarantinesIt() async throws {
        let server = MockServer { request in
            if request.url.host() == "github.com" {
                return .redirect(302, to: URL(string: "https://objects.githubusercontent.com/asset/TestApp-2.5.zip")!)
            }
            return MockResponse(status: 200, headers: ["Content-Type": "application/zip"], body: Data("zip".utf8))
        }
        let file = try await checker(server).download(release(asset))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(file.lastPathComponent == "TestApp-2.5.zip")
        #expect(try Data(contentsOf: file) == Data("zip".utf8))
        let quarantine = try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?[kLSQuarantineAgentNameKey as String] as? String == "TestApp")
        #expect(server.requests.map { $0.url.host() } == ["github.com", "objects.githubusercontent.com"])
    }

    @Test func aRedirectAwayFromGitHubIsNotFollowed() async throws {
        let server = MockServer { request in
            if request.url.host() == "github.com" {
                return .redirect(302, to: URL(string: "https://downloads.example.com/TestApp-2.5.zip")!)
            }
            return MockResponse(status: 200, body: Data("evil".utf8))
        }
        let error = await #expect(throws: UpdateChecker.UpdateError.self) { _ = try await checker(server).download(release(asset)) }
        #expect(error?.message.contains("302") == true)
        #expect(server.requests.map { $0.url.host() } == ["github.com"])
    }

    @Test func anotherRepositorysAssetIsNotDownloaded() async throws {
        let server = MockServer { _ in MockResponse(status: 200, body: Data()) }
        await #expect(throws: UpdateChecker.UpdateError.self) {
            _ = try await checker(server).download(release("https://github.com/Someone/TestApp/releases/download/v2.5/a.zip"))
        }
        #expect(server.requests.isEmpty)
    }

    @Test func theLastCheckIsRememberedOnlyWhenItWorked() async throws {
        let failing = MockServer { _ in .json(503, "{}") }
        let defaults = try makeDefaults()
        try await checker(failing, defaults: defaults).checkAutomatically()
        #expect(defaults.object(forKey: "lastUpdateCheck") == nil, "tried again at the next launch")

        let working = MockServer { _ in .json(200, #"{"tag_name": "v1.0"}"#) }
        try await checker(working, defaults: defaults).checkAutomatically()
        #expect(defaults.object(forKey: "lastUpdateCheck") is Date)
    }

    @Test func aSandboxRunNeverChecks() async throws {
        let server = MockServer { _ in .json(200, #"{"tag_name": "v9.0"}"#) }
        let sandboxed = try checker(server, arguments: ["-JTKitSandbox", "YES"])
        await sandboxed.checkAutomatically()
        sandboxed.checkManually()
        #expect(sandboxed.status == .failed(UpdateChecker.sandboxMessage))
        await #expect(throws: UpdateChecker.UpdateError.self) { _ = try await sandboxed.download(release(asset)) }
        #expect(server.requests.isEmpty)
    }
}
