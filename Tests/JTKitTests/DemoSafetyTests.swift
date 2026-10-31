import AppKit
import Foundation
import Testing
@testable import JTKit

@Suite("What makes a connection a demo one")
struct DemoConnectionIdentityTests {
    @Test func everyIDCounts() {
        var environment = Connection(name: "Imported", service: .jamfPlatform)
        environment.environmentID = DemoSamples.platformEnvironmentID
        var key = Connection(name: "Imported", service: .appleBusinessManager)
        key.keyID = Connection.demoAppleBusiness.keyID
        var client = Connection(name: "Imported", service: .appleSchoolManager)
        client.clientID = Connection.demoAppleSchool.clientID
        #expect(environment.isDemo && key.isDemo && client.isDemo)
        #expect(!Connection(name: "Real", service: .appleBusinessManager,
                            clientID: "BUSINESSAPI.\(UUID().uuidString)", keyID: UUID().uuidString).isDemo)
    }
}

@MainActor
@Suite("Demo mode’s leftovers")
struct DemoLeftoverTests {
    @Test func theScratchFolderGoesWithItsDemoMode() throws {
        let name = "JTKitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var folder: URL?
        do {
            let demo = DemoMode(key: "demoMode", defaults: defaults, arguments: [])
            folder = demo.scratchDirectory
            #expect(demo.scratchDirectory == folder)
            #expect(FileManager.default.fileExists(atPath: try #require(folder).path))
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(folder).path))
    }

    @Test func aSandboxRunHasItsOwnSettings() throws {
        let defaults = DemoMode.sandboxDefaults()
        #expect(defaults !== UserDefaults.standard)
        #expect(DemoMode.sandboxDefaults() === defaults, "the same suite for the whole run")
        let key = "JTKitTests.\(UUID().uuidString)"
        defaults.set(true, forKey: key)
        defer { defaults.removeObject(forKey: key) }
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }

    @Test func suitesOfEndedRunsAreRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jtkit-prefs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in ["JTKitSandbox-111.plist", "JTKitSandbox-222.plist", "com.example.app.plist"] {
            try Data().write(to: folder.appending(path: file))
        }
        SandboxSuite.removeLeftovers(in: folder, isRunning: { $0 == 222 })
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["JTKitSandbox-222.plist", "com.example.app.plist"])
    }

    @Test func aClosedWindowIsNoLongerWatched() async throws {
        _ = NSApplication.shared
        let titles = DemoWindowTitles.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let before = titles.watchedWindowCount
        titles.apply(to: window)
        #expect(titles.watchedWindowCount == before + 1)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        for _ in 0..<100 where titles.watchedWindowCount != before {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(titles.watchedWindowCount == before)
    }
}

@Suite("Demo networks are let go")
struct DemoNetworkLifetimeTests {
    @Test func theServersGoWithTheSession() async throws {
        var id = ""
        let url = try #require(URL(string: "https://x.demo.invalid/"))
        do {
            let network = DemoNetwork(servers: [:])
            id = network.id
            #expect(DemoURLProtocol.isRegistered(id: id))
            _ = try? await network.session.data(from: url)
        }
        for _ in 0..<200 where DemoURLProtocol.isRegistered(id: id) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!DemoURLProtocol.isRegistered(id: id))
    }

    @Test("Keeping only the session keeps its servers, as apps do")
    func theSessionAloneIsEnough() async throws {
        let session = DemoNetwork(servers: [DemoSamples.platformHost: DemoJamfPlatformServer()]).session
        var request = URLRequest(url: try #require(URL(string: "https://\(DemoSamples.platformHost)/auth/token")))
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}

@Suite("Demo servers behave like the real ones")
struct DemoServerFidelityTests {
    private func request(_ method: String, _ address: String, token: String? = nil, body: String = "") throws -> DemoRequest {
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        return DemoRequest(method: method, url: try #require(URL(string: address)), headers: headers, body: Data(body.utf8))
    }

    @Test func thePlatformNeedsTheTokenItGaveOut() throws {
        let server = DemoJamfPlatformServer()
        let groups = "https://\(DemoSamples.platformHost)/device-groups/v1/device-groups"
        #expect(server.respond(to: try request("GET", groups)).status == 401)
        #expect(server.respond(to: try request("GET", groups, token: "made-up")).status == 401)
        let signIn = server.respond(to: try request("POST", "https://\(DemoSamples.platformHost)/auth/token"))
        let token = try #require(DemoJSON.object(signIn.body)?["access_token"] as? String)
        #expect(server.respond(to: try request("GET", groups, token: token)).status == 200)
    }

    @Test func missingPermissionRefusesRecordDeletes() throws {
        let server = DemoJamfProServer(scenario: .missingPermission)
        let host = "https://\(DemoWorld.jamfProHost)"
        let signIn = server.respond(to: try request("POST", "\(host)/api/oauth/token",
                                                    body: "grant_type=client_credentials&client_id=a&client_secret=b"))
        let token = try #require(DemoJSON.object(signIn.body)?["access_token"] as? String)
        let devices = DemoWorld.devices(managedBy: .jamfPro)
        let computer = try #require(devices.first { $0.isComputer })
        let mobile = try #require(devices.first { !$0.isComputer })
        #expect(server.respond(to: try request("DELETE", "\(host)/api/v4/computers-inventory/\(computer.number)", token: token)).status == 403)
        #expect(server.respond(to: try request("DELETE", "\(host)/JSSResource/mobiledevices/id/\(mobile.number)", token: token)).status == 403)
        #expect(server.isManaged(serial: computer.serial) != nil, "still there")
    }

    @Test func graphPagesEvenOneAtATime() throws {
        let server = DemoIntuneServer()
        let answer = server.respond(to: try request("GET", "https://\(DemoIntuneServer.graphHost)/v1.0/deviceManagement/managedDevices?$top=1",
                                                    token: DemoIntuneServer.delegatedToken))
        #expect(answer.status == 200)
        #expect(DemoJSON.object(answer.body)?["@odata.nextLink"] is String)
    }
}
