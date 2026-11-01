import Foundation
import SwiftUI
import Testing
@testable import JTKit
import JTKitTestSupport

// JTKit 1.1.0, Part C: helpers the apps had their own copies of.

private func platformClient(_ server: MockServer) throws -> JamfPlatform.Client {
    try JamfPlatform.Client(baseURL: URL(string: "https://eu.api.jamfcloud.com")!, scope: .environment("e77c1408-10c8-4007-b177-abc9157fbcab"),
                            tokens: FixedToken("tok"),
                            recorder: RequestRecorder(session: server.session, log: nil, service: "Jamf Platform API"),
                            sleep: { _ in }, random: { 0 })
}

@Suite("Server origin (C4)")
struct ServerOriginTests {
    @Test("A pasted address becomes https://host[:port]; http and no host give nil")
    func origin() {
        #expect(Connection.serverOrigin("school.example.com")?.absoluteString == "https://school.example.com")
        #expect(Connection.serverOrigin("  https://Pro.Example.com:8443/api/v1/?x=1  ")?.absoluteString == "https://pro.example.com:8443")
        #expect(Connection.serverOrigin("https://pro.example.com/JSSResource/computers//")?.absoluteString == "https://pro.example.com")
        #expect(Connection.serverOrigin("http://pro.example.com") == nil)
        #expect(Connection.serverOrigin("") == nil)
        #expect(Connection.serverOrigin("https://") == nil)
        #expect(Connection.serverOrigin("https://user@pro.example.com") == nil)
    }

    @Test("isWebAddress is public and agrees with serverOrigin for https")
    func webAddress() {
        #expect(Connection.isWebAddress("https://pro.example.com"))
        #expect(!Connection.isWebAddress("http://pro.example.com"))
    }
}

@Suite("Jamf web links (C7)")
struct JamfWebLinkTests {
    @Test("The formats Checkpoint, Serial Number Reader and Profile2Blueprint built")
    func formats() {
        let base = "pro.example.com/api/"
        #expect(JamfWebLink.computer(id: "12", base: base)?.absoluteString == "https://pro.example.com/computers.html?id=12&o=r")
        #expect(JamfWebLink.mobileDevice(id: "7", base: base)?.absoluteString == "https://pro.example.com/mobileDevices.html?id=7&o=r")
        #expect(JamfWebLink.configurationProfile(id: "3", mobile: false, base: base)?.absoluteString
                == "https://pro.example.com/OSXConfigurationProfiles.html?id=3&o=r")
        #expect(JamfWebLink.configurationProfile(id: "4", mobile: true, base: base)?.absoluteString
                == "https://pro.example.com/iOSConfigurationProfiles.html?id=4&o=r")
        #expect(JamfWebLink.blueprint(id: "a1b2", base: "https://pro.example.com:8443/")?.absoluteString
                == "https://pro.example.com:8443/view/mfe/blueprints/a1b2")
        #expect(JamfWebLink.schoolDevice(udid: "00008030-001A2B3C4D5E802E", base: "school.example.com")?.absoluteString
                == "https://school.example.com/devices/details/00008030-001A2B3C4D5E802E")
    }

    @Test("No link without a usable address or ID; an ID can’t reach another page")
    func refuses() {
        #expect(JamfWebLink.computer(id: "1", base: "http://pro.example.com") == nil)
        #expect(JamfWebLink.computer(id: " ", base: "pro.example.com") == nil)
        #expect(JamfWebLink.blueprint(id: "../settings", base: "pro.example.com") == nil)
        #expect(JamfWebLink.schoolDevice(udid: "..", base: "school.example.com") == nil)
        // a query character in an ID stays inside the ID
        #expect(JamfWebLink.computer(id: "1&o=w", base: "pro.example.com")?.absoluteString
                == "https://pro.example.com/computers.html?id=1%26o%3Dw&o=r")
        #expect(JamfWebLink.blueprint(id: "a?b", base: "pro.example.com")?.absoluteString
                == "https://pro.example.com/view/mfe/blueprints/a%3Fb")
    }
}

@Suite("Jamf Platform Test Connection and groups (C1, C9)")
struct JamfPlatformTestConnectionTests {
    @Test("Connected, with the summary after a dot; a missing permission throws PermissionProblem")
    func testConnection() async throws {
        let allowed = MockServer { _ in .json(200, #"{"totalCount":3,"results":[]}"#) }
        #expect(try await platformClient(allowed).testConnection() == "Connected")
        #expect(try await platformClient(allowed).testConnection(summary: { "3 Blueprints" }) == "Connected · 3 Blueprints")
        #expect(try await platformClient(allowed).testConnection(summary: { "" }) == "Connected")
        #expect(allowed.requests.allSatisfy { $0.method == "GET" })

        let denied = MockServer { request in
            request.path.contains("device-groups") ? .json(403, #"{"httpStatus":403,"errors":[]}"#) : .json(200, #"{"results":[]}"#)
        }
        await #expect(throws: JamfPlatform.PermissionProblem.self) {
            _ = try await platformClient(denied).testConnection(checks: [.blueprintsRead, .deviceGroupsRead],
                                                                summary: { Issue.record("no summary after a problem"); return nil })
        }
    }

    @Test("pro/v2/groups: platform ID, name, Jamf Pro ID and type, over all pages")
    func platformGroups() async throws {
        let server = MockServer { request in
            #expect(request.path == "/api/pro/v2/groups" || request.path.hasSuffix("/pro/v2/groups"))
            return request.queryValue("page") == "0"
                ? .json(200, #"{"totalCount":3,"results":[{"groupPlatformId":"p-1","groupJamfProId":"5","groupName":"Lab","groupType":"COMPUTER","smart":true,"membershipCount":4},{"groupPlatformId":"p-2","groupJamfProId":"6","groupName":"Carts","groupType":"MOBILE","smart":false}]}"#)
                : .json(200, #"{"totalCount":3,"results":[{"groupJamfProId":"9","groupName":"No platform ID"},{"groupPlatformId":"p-3","groupName":"Other","groupType":"TV"}]}"#)
        }
        let groups = try await platformClient(server).platformGroups(pageSize: 2)
        #expect(groups.map(\.id) == ["p-1", "p-2", "p-3"])
        #expect(groups[0] == JamfPlatform.PlatformGroup(id: "p-1", name: "Lab", jamfProID: "5", deviceType: .computer, isSmart: true, memberCount: 4))
        #expect(groups[1].deviceType == .mobile && groups[1].isSmart == false && groups[1].memberCount == nil)
        #expect(groups[2].deviceType == .other("TV"))
        #expect(server.requests.count == 2)
    }
}

@Suite("Review A-C #10: platformGroups names its privileges")
struct PlatformGroupsPrivilegeTests {
    @Test("A Jamf Pro 403 names the four group read privileges")
    func refusal() async throws {
        let server = MockServer { _ in .json(403, #"{"httpStatus":403,"errors":[]}"#) }
        let client = try JamfPlatform.Client(baseURL: URL(string: "https://pro.example.com")!, scope: .organization, server: .jamfPro,
                                             tokens: FixedToken("tok"), recorder: RequestRecorder(session: server.session, log: nil),
                                             sleep: { _ in }, random: { 0 })
        do {
            _ = try await client.platformGroups()
            Issue.record("expected a refusal")
        } catch let error as JamfPlatform.APIError {
            #expect(error.privileges == JamfPlatform.Client.platformGroupsPrivileges)
            #expect(error.privileges.contains(.readStaticMobileDeviceGroups))
        }
    }
}

@Suite("Jamf School check-in text and move batches (C10, C11)")
struct JamfSchoolHelperTests {
    @Test("The raw check-in text is kept, from the list and from a single device")
    func checkInText() throws {
        let list = try JSONDecoder().decode(JamfSchool.Device.self, from: Data(#"{"UDID":"u-1","serialNumber":"S1","lastCheckin":"2026-10-31 14:05:09"}"#.utf8))
        #expect(list.lastCheckInText == "2026-10-31 14:05:09")
        #expect(list.lastCheckIn != nil)
        let brussels = try #require(TimeZone(identifier: "Europe/Brussels"))
        #expect(JamfSchool.date(list.lastCheckInText, timeZone: brussels)
                == JamfSchool.date("2026-10-31 14:05:09", timeZone: brussels))

        let detail = try JSONDecoder().decode(JamfSchool.Device.self, from: Data(
            #"{"UDID":"u-1","lastCheckin":{"date":"2026-10-20 08:12:33.000000","timezone_type":3,"timezone":"Asia/Tokyo"}}"#.utf8))
        #expect(detail.lastCheckInText == "2026-10-20 08:12:33.000000")
        #expect(detail.timeZone == "Asia/Tokyo")

        let none = try JSONDecoder().decode(JamfSchool.Device.self, from: Data(#"{"UDID":"u-2"}"#.utf8))
        #expect(none.lastCheckInText == nil && none.lastCheckIn == nil)
        #expect(JamfSchool.Device(udid: "u-3", lastCheckInText: "x").lastCheckInText == "x")
    }

    @Test("The move batch size is public: twenty")
    func batchSize() {
        #expect(JamfSchool.moveBatchSize == 20)
    }
}

@Suite("Public HTTP client (C5)")
struct PublicHTTPClientTests {
    @Test("Without a token: no Authorization header; still refuses what the app doesn’t allow")
    func noToken() async throws {
        let server = MockServer { _ in .json(200, #"{"ok":true}"#) }
        let client = HTTPClient(baseURL: URL(string: "https://downloads.example.com/files")!,
                                recorder: RequestRecorder(session: server.session, log: nil),
                                permits: { $0.isRead })
        let answer = try await client.send(HTTPRequest(path: "a/b.json"))
        #expect(answer.status == 200)
        #expect(server.requests.first?.url.absoluteString == "https://downloads.example.com/files/a/b.json")
        #expect(server.requests.first?.header("Authorization") == nil)
        await #expect(throws: HTTPError.self) { _ = try await client.send(HTTPRequest(method: "DELETE", path: "a")) }
        await #expect(throws: HTTPError.self) { _ = try await client.send(HTTPRequest(path: "../etc")) }
        #expect(server.requests.count == 1)
    }
}

@Suite("Review A-C #6: the public HTTP client and http://")
struct PublicHTTPClientSchemeTests {
    @Test("An http:// base address is refused before anything is sent, so the token never goes in clear")
    func http() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let client = HTTPClient(baseURL: URL(string: "http://downloads.example.com")!, tokens: FixedToken("tok"),
                                recorder: RequestRecorder(session: server.session, log: nil))
        await #expect(throws: HTTPError.self) { _ = try await client.send(HTTPRequest(path: "a.json")) }
        #expect(server.requests.isEmpty)
    }
}

/// A JWT with these claims (unsigned: only the claims are read).
private func jwt(_ claims: String) -> String {
    let payload = Data(claims.utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJub25lIn0.\(payload).sig"
}

@Suite("Microsoft tenant of a token (C12)")
struct EntraTenantTests {
    @Test("The tid claim, lowercased; nil without one")
    func tid() {
        #expect(EntraToken.tenantID(ofAccessToken: jwt(#"{"tid":"5F1E0C3A-1111-4222-8333-944455556666","aud":"x"}"#))
                == "5f1e0c3a-1111-4222-8333-944455556666")
        #expect(EntraToken.tenantID(ofAccessToken: "Bearer " + jwt(#"{"tid":"abc"}"#)) == "abc")
        #expect(EntraToken.tenantID(ofAccessToken: jwt(#"{"aud":"x"}"#)) == nil)
        #expect(EntraToken.tenantID(ofAccessToken: jwt(#"{"tid":""}"#)) == nil)
        #expect(EntraToken.tenantID(ofAccessToken: "not-a-jwt") == nil)
        #expect(EntraToken.tenantID(ofAccessToken: "a.%%%.c") == nil)
    }

    @Test("Same tenant by the signed-in ID; as typed only until both are signed in")
    func same() {
        let id = "5f1e0c3a-1111-4222-8333-944455556666"
        // the 1.6.1 case: one typed as a domain, one as the ID
        #expect(!EntraTenant.isSame(typed: "contoso.onmicrosoft.com", as: id))
        #expect(EntraTenant.isSame(typed: "contoso.onmicrosoft.com", signedIn: id, as: id))
        #expect(EntraTenant.isSame(typed: "contoso.onmicrosoft.com", signedIn: id.uppercased(),
                                   as: "contoso.example", signedIn: id))
        #expect(EntraTenant.isSame(typed: " \(id.uppercased()) ", as: id))
        // signed in to different tenants, though typed the same
        #expect(!EntraTenant.isSame(typed: id, signedIn: id, as: id, signedIn: "00000000-1111-4222-8333-944455556666"))
        #expect(!EntraTenant.isSame(typed: "", as: ""))
        #expect(EntraTenant.key(typed: " Contoso.onmicrosoft.com ") == "contoso.onmicrosoft.com")
    }
}

@Suite("Timestamped backups (C13)")
struct TimestampedBackupStoreTests {
    private func store() throws -> (TimestampedBackupStore, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "JTKitBackups-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (TimestampedBackupStore(root: root), root)
    }

    @Test("Exact bytes, never overwritten, -2 … -10 in order, owner-only permissions")
    func write() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_790_000_000.5)
        var urls = [URL]()
        for index in 1...10 { urls.append(try store.write(Data("v\(index)".utf8), for: "bp/1:x", date: date)) }
        #expect(Set(urls).count == 10)
        #expect(urls[0].deletingLastPathComponent().lastPathComponent == "bp_1_x")
        #expect(urls[0].lastPathComponent == "2026-09-21T14-13-20.500Z.json")
        #expect(urls[9].lastPathComponent == "2026-09-21T14-13-20.500Z-10.json")
        let listed = store.backups(for: "bp/1:x")
        #expect(listed.map { try? String(decoding: store.data(of: $0), as: UTF8.self) } == (1...10).reversed().map { "v\($0)" })
        let file = try FileManager.default.attributesOfItem(atPath: urls[0].path)[.posixPermissions] as? Int
        let folder = try FileManager.default.attributesOfItem(atPath: urls[0].deletingLastPathComponent().path)[.posixPermissions] as? Int
        #expect(file == 0o600 && folder == 0o700)
        #expect(store.directory(for: "..").lastPathComponent == "_..")
        #expect(store.backups(for: "none").isEmpty)
    }

    @Test("Review A-C #9: a root folder the app passed keeps its permissions; one the store makes is 0700")
    func rootPermissions() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "JTKitBackupRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        let existing = parent.appending(path: "Existing", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try TimestampedBackupStore(root: existing).write(Data("x".utf8), for: "a")
        #expect(try FileManager.default.attributesOfItem(atPath: existing.path)[.posixPermissions] as? Int == 0o755)
        let made = parent.appending(path: "Made", directoryHint: .isDirectory)
        try TimestampedBackupStore(root: made).write(Data("x".utf8), for: "a")
        #expect(try FileManager.default.attributesOfItem(atPath: made.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.attributesOfItem(atPath: made.appending(path: "a").path)[.posixPermissions] as? Int == 0o700)
    }

    @Test("Pruning keeps each key’s newest backup, and everything for Forever")
    func prune() throws {
        let (store, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try store.write(Data("old".utf8), for: "a", date: Date(timeIntervalSince1970: 1_000))
        let older = try store.write(Data("older".utf8), for: "a", date: Date(timeIntervalSince1970: 500))
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -400 * 86_400)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -400 * 86_400)], ofItemAtPath: old.path)
        try store.write(Data("only".utf8), for: "b", date: Date(timeIntervalSince1970: 100))
        #expect(store.prune(.forever) == 0)
        #expect(store.prune(.oneYear) == 1)
        #expect(store.backups(for: "a").map(\.url.lastPathComponent) == [old.lastPathComponent])
        #expect(store.backups(for: "b").count == 1)
        #expect(BackupRetention.allCases.map(\.title) == ["Forever", "1 Year", "90 Days", "30 Days"])
    }
}

@Suite("Copies of unreadable files (C14)")
struct FileCopiesTests {
    @Test("A copy next to the file, never replacing an earlier one")
    func copies() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "JTKitCopies-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "list.json")
        try Data("broken".utf8).write(to: file)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try #require(FileCopies.keepUnreadableCopy(of: file, date: date))
        let second = try #require(FileCopies.keepUnreadableCopy(of: file, date: date))
        #expect(first != second)
        #expect(first.hasSuffix("list.json.\(FileCopies.unreadableStamp(date))"))
        #expect(second.hasSuffix("list.json.\(FileCopies.unreadableStamp(date))-2"))
        #expect(try String(contentsOfFile: second, encoding: .utf8) == "broken")
        #expect(FileCopies.keepUnreadableCopy(of: folder.appending(path: "missing.json")) == nil)
    }
}

@Suite("Release versions and GitHub’s release list (C15)")
struct GitHubReleasesTests {
    @Test("Strict tags: versions parse, other tags don’t")
    func tags() throws {
        #expect(ReleaseVersion(tag: "v1.2.3")?.components == [1, 2, 3])
        #expect(ReleaseVersion(tag: "1.2")?.components == [1, 2])
        #expect(ReleaseVersion(tag: "V2")?.components == [2])
        #expect(ReleaseVersion(tag: "1.2.1-hotfix")?.suffix == "hotfix")
        for tag in ["v.0.0.44", "nightly", "", "v", "1..2", "1.2.", "2026-10-31", "1.2.3.4.5", "1.x"] {
            #expect(ReleaseVersion(tag: tag) == nil, "\(tag)")
        }
        let v = { (tag: String) in try #require(ReleaseVersion(tag: tag)) }
        #expect(try v("1.10") > v("1.9"))
        #expect(try v("1.2") == v("1.2.0"))
        #expect(try v("v2") > v("1.99.99"))
    }

    @Test("The highest version, skipping drafts, prereleases and non-version tags")
    func latest() async throws {
        let server = MockServer { request in
            #expect(request.url.absoluteString == "https://api.github.com/repos/opentofu/opentofu/releases?per_page=30")
            return .json(200, #"""
            [{"tag_name":"v.0.0.44"},{"tag_name":"v1.11.0-rc1","prerelease":true},{"tag_name":"v1.12.0","draft":true},
             {"tag_name":"v1.9.3","html_url":"https://github.com/opentofu/opentofu/releases/tag/v1.9.3"},{"tag_name":"v1.10.6"},{"tag_name":"v1.10.5"}]
            """#)
        }
        let latest = try await GitHubReleases.latest(owner: "opentofu", repo: "opentofu", session: server.session)
        #expect(latest?.tag == "v1.10.6")
        #expect(latest?.version?.description == "1.10.6")

        let none = MockServer { _ in .json(200, #"[{"tag_name":"nightly"}]"#) }
        #expect(try await GitHubReleases.latest(owner: "o", repo: "r", session: none.session) == nil)
        let refused = MockServer { _ in .json(403, "{}") }
        await #expect(throws: GitHubReleases.Failure.self) {
            _ = try await GitHubReleases.latest(owner: "o", repo: "r", session: refused.session)
        }
    }
}

@Suite("Delete refusal and typed name (C3)")
struct ConnectionDeletionTests {
    @Test("Only the name itself confirms, spaces around it aside")
    func typedName() {
        #expect(ConnectionDeletion.confirms(typed: "Contoso Production", name: "Contoso Production"))
        #expect(ConnectionDeletion.confirms(typed: " Contoso Production ", name: "Contoso Production"))
        #expect(!ConnectionDeletion.confirms(typed: "contoso production", name: "Contoso Production"))
        #expect(!ConnectionDeletion.confirms(typed: "Contoso", name: "Contoso Production"))
        #expect(!ConnectionDeletion.confirms(typed: "", name: ""))
    }
}

@Suite("Badges (C16)")
struct BadgeStyleTests {
    @Test("Blueprint states: Deployed success, Out of Date attention, Not Deployed neutral, others info")
    func blueprintStates() {
        func color(_ style: StatusBadge.Style) -> Color? {
            if case .colored(let color) = style { return color }
            return nil
        }
        #expect(color(JamfPlatform.BlueprintState.deployed.badgeStyle) == .green)
        #expect(color(JamfPlatform.BlueprintState.outOfDate.badgeStyle) == .orange)
        #expect(color(JamfPlatform.BlueprintState(rawValue: "DEPLOYING").badgeStyle) == .blue)
        if case .neutral = JamfPlatform.BlueprintState.notDeployed.badgeStyle {} else { Issue.record("Not Deployed isn’t neutral") }
        #expect(color(.failure) == .red)
    }
}

@Suite("Demo: rate limited, and the app’s tooltip (C18, C19)", .serialized)
@MainActor
struct DemoRateLimitAndHelpTests {
    @Test("The first request after sign-in waits for Retry-After, then goes through; sign-in isn’t limited")
    func rateLimited() async throws {
        let platform = DemoRateLimitedServer(DemoJamfPlatformServer())
        let network = DemoNetwork(servers: [DemoSamples.platformHost: platform])
        let waits = SleepLog()
        let log = ActivityLog()
        let client = try JamfPlatform.Client(connection: .demoJamfPlatform, secret: { "demo-secret" },
                                             recorder: RequestRecorder(session: network.session, log: log, service: "Jamf Platform API"),
                                             sleep: { try await waits.sleep($0) })
        let first = try await JamfPlatform.Blueprints(client: client).list()
        #expect(!first.isEmpty)
        #expect(platform.limitedCount == 1)
        #expect(waits.recorded.contains(.seconds(1)), "\(waits.recorded)")
        _ = try await JamfPlatform.Blueprints(client: client).list()
        #expect(platform.limitedCount == 1, "only once")
        #expect(log.entries.contains { $0.status == 429 })
        #expect(DemoRateLimitedServer.isSignIn(DemoRequest(method: "POST", url: URL(string: "https://x.demo.invalid/auth/token")!)))
        #expect(DemoRateLimitedServer.isSignIn(DemoRequest(method: "POST", url: URL(string: "https://login.demo.invalid/t/oauth2/v2.0/token")!)))
        #expect(!DemoRateLimitedServer.isSignIn(DemoRequest(method: "GET", url: URL(string: "https://x.demo.invalid/blueprints/v1/blueprints")!)))
    }

    @Test("-JTKitDemoScenario rateLimited: the demo connections answer 429 once")
    func scenario() async throws {
        let demo = DemoMode(key: "jtkit-rate-\(UUID().uuidString)", defaults: UserDefaults(suiteName: "jtkit-rate-\(UUID().uuidString)")!,
                            arguments: ["app", "-JTKitSandbox", "YES", "-JTKitDemoScenario", "rateLimited"])
        #expect(demo.scenario == .rateLimited)
        let source = demo.jamfPlatform()
        let log = ActivityLog()
        let client = try JamfPlatform.Client(connection: source.connection, secret: { "demo-secret" },
                                             recorder: RequestRecorder(session: source.session, log: log, service: "Jamf Platform API"),
                                             sleep: { _ in })
        _ = try await JamfPlatform.Blueprints(client: client).list()
        #expect(log.entries.filter { $0.status == 429 }.count == 1)
    }

    @Test("The app’s own demo tooltip, or the shared one")
    func help() {
        let defaults = UserDefaults(suiteName: "jtkit-help-\(UUID().uuidString)")!
        #expect(DemoMode(key: "d", defaults: defaults, arguments: []).help == DemoMode.helpText)
        #expect(DemoMode(key: "d", defaults: defaults, arguments: [], help: "Sample tenants only.").help == "Sample tenants only.")
        #expect(DemoMode(key: "d", defaults: defaults, arguments: [], help: "  ").help == DemoMode.helpText)
    }
}
