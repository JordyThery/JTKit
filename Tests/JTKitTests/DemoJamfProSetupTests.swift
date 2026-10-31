import Foundation
import Testing
@testable import JTKit

@MainActor
private func demoMode() -> DemoMode {
    let defaults = UserDefaults(suiteName: "jtkit-demo-setup-\(UUID().uuidString)")!
    return DemoMode(key: "demoMode", defaults: defaults, arguments: ["app"])
}

/// JTKit’s real client for a demo connection, on the demo network.
@MainActor
private func client(_ demo: DemoMode, _ connection: Connection) throws -> JamfPlatform.Client {
    let source = try #require(demo.source(for: connection))
    return try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                   recorder: RequestRecorder(session: source.session, log: nil), sleep: { _ in })
}

@MainActor
private func send(_ client: JamfPlatform.Client, _ method: String, _ path: String, json: Any? = nil,
                  accept: String? = nil) async throws -> HTTPResponse {
    let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
    return try await client.send(HTTPRequest(method: method, path: path, body: body, accept: accept,
                                             contentType: json != nil ? "application/json" : nil),
                                 privileges: [])
}

@MainActor
private func json(_ response: HTTPResponse) throws -> Any {
    try JSONSerialization.jsonObject(with: response.data)
}

@MainActor
private func results(_ response: HTTPResponse) throws -> [[String: Any]] {
    try #require((try json(response) as? [String: Any])?["results"] as? [[String: Any]])
}

@Suite("Demo Jamf Pro setup pages and the Platform gateway’s Jamf Pro (Jamf Deployer)")
@MainActor
struct DemoJamfProSetupTests {

    @Test("The Platform gateway answers /pro/… and /proclassic/… from its Jamf Pro, inside the app")
    func gateway() async throws {
        let demo = demoMode()
        let platform = try client(demo, .demoJamfPlatform)
        #expect(demo.jamfPlatformServer.jamfPro != nil)

        let version = try await platform.jamfProVersion()
        #expect(version.version.hasPrefix("11.33"))
        let categories = try results(try await send(platform, "GET", "pro/v1/categories"))
        #expect(!categories.isEmpty)
        let classic = try #require(try json(try await send(platform, "GET", "proclassic/policies",
                                                           accept: "application/json")) as? [String: Any])
        #expect(!((classic["policies"] as? [[String: Any]]) ?? []).isEmpty)
        // Blueprints still answer as before
        #expect(try await JamfPlatform.Blueprints(client: platform).list().isEmpty == false)
    }

    @Test("An app’s own route under the gateway comes before its Jamf Pro")
    func appRouteFirst() async throws {
        final class Fixed: DemoServer, @unchecked Sendable {
            func respond(to request: DemoRequest) -> DemoResponse { .json(200, .object(LosslessJSON.Object(["mine": .bool(true)]))) }
        }
        let demo = demoMode()
        demo.jamfPlatformServer.route("proclassic", to: Fixed())
        let platform = try client(demo, .demoJamfPlatform)
        let answer = try #require(try json(try await send(platform, "GET", "proclassic/policies")) as? [String: Any])
        #expect(answer["mine"] as? Bool == true)
    }

    @Test("Day 0 pages on Contoso’s Platform tenant: ADE, Apps and Books and branding are set up")
    func platformSetup() async throws {
        let demo = demoMode()
        let platform = try client(demo, .demoJamfPlatform)
        #expect(try results(try await send(platform, "GET", "pro/v1/device-enrollments")).count == 1)
        let vpp = try results(try await send(platform, "GET", "pro/v1/volume-purchasing-locations"))
        #expect(vpp.first?["name"] as? String == "Contoso Apps and Books")
        #expect(vpp.first?["serviceToken"] == nil)
        #expect(try results(try await send(platform, "GET", "pro/v1/self-service/branding/macos")).count == 1)
        let server = try #require(try json(try await send(platform, "GET", "pro/v1/jamf-pro-server-url")) as? [String: Any])
        #expect((server["url"] as? String)?.hasSuffix(".demo.invalid") == true)
        let titles = try results(try await send(platform, "GET", "pro/v1/app-installers/titles"))
        #expect(titles.map { $0["titleName"] as? String }.contains("Google Chrome"))
    }

    @Test("A fresh tenant: Apps and Books, branding and Protect are uploaded or linked, secrets never read back")
    func setupWrites() async throws {
        let demo = demoMode()
        let fresh = try client(demo, .demoJamfProDestination)
        #expect(try results(try await send(fresh, "GET", "pro/v1/volume-purchasing-locations")).isEmpty)
        #expect(try results(try await send(fresh, "GET", "pro/v1/self-service/branding/macos")).isEmpty)

        let vpp = try await send(fresh, "POST", "pro/v1/volume-purchasing-locations",
                                 json: ["name": "Contoso Lab Apps", "serviceToken": "ZGVtby10b2tlbg=="])
        #expect(vpp.status == 201)
        let locations = try results(try await send(fresh, "GET", "pro/v1/volume-purchasing-locations"))
        #expect(locations.map { $0["name"] as? String } == ["Contoso Lab Apps"])
        #expect(locations.first?["serviceToken"] == nil)
        #expect((locations.first?["tokenExpiration"] as? String)?.isEmpty == false)

        #expect(try await send(fresh, "POST", "pro/v1/self-service/branding/macos",
                               json: ["brandingName": "Contoso Lab", "applicationName": "Contoso Lab"]).status == 201)
        #expect(try results(try await send(fresh, "GET", "pro/v1/self-service/branding/macos")).count == 1)

        let before = try #require(try json(try await send(fresh, "GET", "pro/v1/jamf-protect")) as? [String: Any])
        #expect(before["registrationId"] == nil)
        #expect(try await send(fresh, "POST", "pro/v1/jamf-protect/register",
                               json: ["protectUrl": "https://contoso.protect.demo.invalid/graphql",
                                      "clientId": "demo-client", "password": "demo-password"]).status == 201)
        let after = try #require(try json(try await send(fresh, "GET", "pro/v1/jamf-protect")) as? [String: Any])
        #expect(after["registrationId"] != nil)
        #expect(!String(decoding: try await send(fresh, "GET", "pro/v1/jamf-protect").data, as: UTF8.self).contains("demo-password"))
    }

    @Test("Automated Device Enrollment: public key download and token upload make an instance")
    func adeUpload() async throws {
        let demo = demoMode()
        let fresh = try client(demo, .demoJamfProDestination)
        let key = try await send(fresh, "GET", "pro/v1/device-enrollments/public-key", accept: "application/x-pem-file")
        #expect(String(decoding: key.data, as: UTF8.self).hasPrefix("-----BEGIN CERTIFICATE-----"))
        let before = try results(try await send(fresh, "GET", "pro/v1/device-enrollments")).count
        let upload = try await send(fresh, "POST", "pro/v1/device-enrollments/upload-token",
                                    json: ["tokenFileName": "Contoso Lab Apple Business.p7m", "encodedToken": "ZGVtbw=="])
        #expect(upload.status == 201)
        let instances = try results(try await send(fresh, "GET", "pro/v1/device-enrollments"))
        #expect(instances.count == before + 1)
        #expect(instances.contains { $0["name"] as? String == "Contoso Lab Apple Business" })
        #expect(!String(decoding: try await send(fresh, "GET", "pro/v1/device-enrollments").data, as: UTF8.self)
            .contains("ZGVtbw=="))
    }

    @Test("Group lists in Jamf’s v1 shapes, from the smart and static groups")
    func groupLists() async throws {
        let demo = demoMode()
        let source = try client(demo, .demoJamfProSource)
        let computers = try #require(try json(try await send(source, "GET", "pro/v1/computer-groups")) as? [[String: Any]])
        #expect(computers.contains { $0["smartGroup"] as? Bool == true } && computers.contains { $0["smartGroup"] as? Bool == false })
        #expect(computers.allSatisfy { $0["id"] is String && $0["name"] is String })
        let mobiles = try #require(try json(try await send(source, "GET", "pro/v1/mobile-device-groups")) as? [[String: Any]])
        #expect(!mobiles.isEmpty && mobiles.allSatisfy { $0["id"] is Int && $0["isSmartGroup"] is Bool })
    }

    @Test("An app adds its own objects at a list path; they read back from the tenant")
    func appObjects() async throws {
        let demo = demoMode()
        let objects = try #require(demo.jamfProSourceServer.objects)
        objects.add([LosslessJSON.Object(["id": .string("77"), "name": .string("Contoso – Slack"), "enabled": .bool(true)])],
                    at: "v1/app-installers/deployments")
        #expect(objects.names(at: "api/v1/app-installers/deployments").contains("Contoso – Slack"))
        let source = try client(demo, .demoJamfProSource)
        let detail = try #require(try json(try await send(source, "GET", "pro/v1/app-installers/deployments/77")) as? [String: Any])
        #expect(detail["enabled"] as? Bool == true)
        // a new object gets an ID after the added one
        let created = try #require(try json(try await send(source, "POST", "pro/v1/categories",
                                                           json: ["name": "Contoso New", "priority": 9])) as? [String: Any])
        #expect(Int(created["id"] as? String ?? "") ?? 0 > 77)
    }
}
