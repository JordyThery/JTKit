import Foundation
import Testing
@testable import JTKit

@MainActor
private func demoMode(scenario: String? = nil) -> DemoMode {
    let defaults = UserDefaults(suiteName: "jtkit-demo-objects-\(UUID().uuidString)")!
    var arguments = ["app"]
    if let scenario { arguments += ["-JTKitDemoScenario", scenario] }
    return DemoMode(key: "demoMode", defaults: defaults, arguments: arguments)
}

/// JTKit's real Jamf Pro client for one of the two demo tenants, as JamfMigrator builds it.
@MainActor
private func client(_ demo: DemoMode, _ connection: Connection) throws -> JamfPlatform.Client {
    let source = try #require(demo.source(for: connection))
    return try JamfPlatform.Client(connection: source.connection, secret: source.secret,
                                   recorder: RequestRecorder(session: source.session, log: nil), sleep: { _ in })
}

@MainActor
private func send(_ client: JamfPlatform.Client, _ method: String, _ path: String, xml: String? = nil,
                  json: Any? = nil, contentType: String? = nil, accept: String? = nil) async throws -> HTTPResponse {
    let body = try xml.map { Data($0.utf8) } ?? json.map { try JSONSerialization.data(withJSONObject: $0) }
    return try await client.send(HTTPRequest(method: method, path: path, body: body,
                                             accept: accept ?? (xml != nil ? "application/xml" : nil),
                                             contentType: contentType ?? (xml != nil ? "application/xml" : json != nil ? "application/json" : nil)),
                                 privileges: [])
}

@MainActor
private func object(_ response: HTTPResponse) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: response.data) as? [String: Any])
}

@MainActor
private func status(_ work: () async throws -> HTTPResponse) async -> Int? {
    do {
        return try await work().status
    } catch let error as JamfPlatformError {
        return error.status
    } catch {
        return nil
    }
}

@Suite("Demo Jamf Pro object store (JamfMigrator's two tenants)")
@MainActor
struct DemoJamfProObjectsTests {

    @Test("Two direct Jamf Pro tenants with fake addresses and IDs, answered inside the app")
    func connections() throws {
        let demo = demoMode()
        for connection in [Connection.demoJamfProSource, .demoJamfProDestination] {
            #expect(connection.isDemo && connection.service == .jamfPro && connection.signIn == .apiClient)
            #expect(connection.serverURL.hasSuffix(".demo.invalid"))
            #expect(demo.source(for: connection)?.connection == connection)
        }
        #expect(Connection.demoJamfProSource.name == "Contoso Source (Demo)")
        #expect(Connection.demoJamfProDestination.name == "Contoso Destination (Demo)")
        #expect(demo.jamfProSourceServer.objects != nil && demo.jamfProDestinationServer.objects != nil)
        #expect(demo.jamfProServer.objects == nil, "Contoso Jamf Pro (Demo) keeps its devices")
    }

    @Test("Classic: JSON list, XML detail, create answers the ID, merged update, delete")
    func classic() async throws {
        let demo = demoMode()
        let dest = try client(demo, .demoJamfProDestination)
        let list = try object(try await send(dest, "GET", "proclassic/policies", accept: "application/json"))
        let entries = try #require(list["policies"] as? [[String: Any]])
        #expect(entries.map { $0["name"] as? String } == ["Contoso – Old Test Policy"])

        let created = try await send(dest, "POST", "proclassic/policies/id/0", xml:
            "<policy><general><name>Contoso – Demo</name><enabled>true</enabled></general>"
            + "<self_service><self_service_display_name>Demo</self_service_display_name><install_button_text>Go</install_button_text></self_service></policy>")
        #expect(created.status == 201)
        let text = String(decoding: created.data, as: UTF8.self)
        let id = try #require(text.firstMatch(of: /<policy><id>(\d+)<\/id><\/policy>/)?.output.1)

        // an icon-only PUT keeps the rest of the policy, as on Jamf
        _ = try await send(dest, "PUT", "proclassic/policies/id/\(id)", xml:
            "<policy><self_service><self_service_icon><id>9</id></self_service_icon></self_service></policy>")
        let detail = String(decoding: try await send(dest, "GET", "proclassic/policies/id/\(id)", accept: "application/xml").data,
                            as: UTF8.self)
        #expect(detail.contains("<general><id>\(id)</id><name>Contoso – Demo</name>"))
        #expect(detail.contains("<install_button_text>Go</install_button_text>") && detail.contains("<self_service_icon><id>9</id>"))

        _ = try await send(dest, "DELETE", "proclassic/policies/id/\(id)", accept: "application/xml")
        #expect(await status { try await send(dest, "GET", "proclassic/policies/id/\(id)", accept: "application/xml") } == 404)
        #expect(demo.jamfProDestinationServer.objects?.names(at: "JSSResource/policies") == ["Contoso – Old Test Policy"])
    }

    @Test("Classic: a duplicate name is refused with 409; a password reads back as a hash")
    func classicRules() async throws {
        let demo = demoMode()
        let dest = try client(demo, .demoJamfProDestination)
        #expect(await status {
            try await send(dest, "POST", "proclassic/policies/id/0", xml: "<policy><general><name>Contoso – Old Test Policy</name></general></policy>")
        } == 409)
        _ = try await send(dest, "POST", "proclassic/ldapservers/id/0", xml:
            "<ldap_server><connection><name>Contoso Directory</name><account><password>changeM3!</password></account></connection></ldap_server>")
        let stored = try #require(demo.jamfProDestinationServer.objects?.classicXML("ldapservers", named: "Contoso Directory"))
        #expect(stored.contains("<password_sha256 since=\"9.23\">") && !stored.contains("changeM3!"))
    }

    @Test("Classic accounts: users and groups in one list, groups by groupid")
    func accounts() async throws {
        let demo = demoMode()
        let source = try client(demo, .demoJamfProSource)
        let list = try object(try await send(source, "GET", "proclassic/accounts", accept: "application/json"))
        let accounts = try #require(list["accounts"] as? [String: Any])
        #expect((accounts["groups"] as? [[String: Any]])?.first?["name"] as? String == "Contoso Helpdesk")
        #expect((accounts["users"] as? [[String: Any]])?.first?["name"] as? String == "avery.sample")
        let group = String(decoding: try await send(source, "GET", "proclassic/accounts/groupid/1", accept: "application/xml").data,
                           as: UTF8.self)
        #expect(group.contains("<name>Contoso Helpdesk</name>"))
    }

    @Test("Pro API: pages, create answers id and href, PUT, PATCH, DELETE, duplicate names")
    func pro() async throws {
        let demo = demoMode()
        let dest = try client(demo, .demoJamfProDestination)
        let names = try await dest.allPages("pro/v1/categories", pageSize: 1) { $0["name"]?.stringValue }
        #expect(names == ["Contoso Apps", "Contoso Security"])

        let created = try object(try await send(dest, "POST", "pro/v1/departments", json: ["name": "Design"]))
        let id = try #require(created["id"] as? String)
        #expect((created["href"] as? String)?.hasSuffix("/api/v1/departments/\(id)") == true)
        #expect(await status { try await send(dest, "POST", "pro/v1/departments", json: ["name": "Design"]) } == 400)

        _ = try await send(dest, "PUT", "pro/v1/departments/\(id)", json: ["name": "Design Team"])
        _ = try await send(dest, "PATCH", "pro/v2/mobile-device-groups/smart-groups/1", json: ["description": "Every iPad"])
        let group = try object(try await send(dest, "GET", "pro/v2/mobile-device-groups/smart-groups/1"))
        #expect(group["name"] as? String == "All Managed iPads" && group["description"] as? String == "Every iPad")
        _ = try await send(dest, "DELETE", "pro/v1/departments/\(id)")
        #expect(demo.jamfProDestinationServer.objects?.names(at: "api/v1/departments") == [])
    }

    @Test("Settings pages: read and updated, PATCH merges, passwords never read back")
    func settings() async throws {
        let demo = demoMode()
        let dest = try client(demo, .demoJamfProDestination)
        let checkIn = try object(try await send(dest, "GET", "pro/v3/check-in"))
        #expect(checkIn["checkInFrequency"] as? Int == 30)
        _ = try await send(dest, "PUT", "pro/v2/smtp-server", json: ["enabled": true, "basicAuthCredentials": ["username": "a", "password": "b"]])
        let smtp = try object(try await send(dest, "GET", "pro/v2/smtp-server"))
        #expect((smtp["basicAuthCredentials"] as? [String: Any])?["password"] == nil)
        _ = try await send(dest, "PATCH", "pro/v2/computer-inventory-collection-settings",
                           json: ["computerInventoryCollectionPreferences": ["includeFonts": true]])
        let inventory = try object(try await send(dest, "GET", "pro/v2/computer-inventory-collection-settings"))
        let preferences = try #require(inventory["computerInventoryCollectionPreferences"] as? [String: Any])
        #expect(preferences["includeFonts"] as? Bool == true && preferences["includePackages"] as? Bool == true)
        let version = try object(try await send(dest, "GET", "pro/v1/jamf-pro-version"))
        #expect((version["version"] as? String)?.hasPrefix("11.34") == true)
    }

    @Test("PreStages: profile UUID and nested IDs on create; an old versionLock is refused")
    func preStages() async throws {
        let demo = demoMode()
        let dest = try client(demo, .demoJamfProDestination)
        let body: [String: Any] = ["displayName": "Contoso Macs", "recoveryLockPassword": "secret",
                                   "locationInformation": ["id": "-1", "versionLock": 0],
                                   "accountSettings": ["id": "-1", "versionLock": 0, "adminPassword": "secret"]]
        let id = try #require(try object(try await send(dest, "POST", "pro/v3/computer-prestages", json: body))["id"] as? String)
        let stored = try object(try await send(dest, "GET", "pro/v3/computer-prestages/\(id)"))
        #expect((stored["profileUuid"] as? String).map(DemoSamples.isDemoID) == true)
        #expect(stored["versionLock"] as? Int == 0 && stored["recoveryLockPassword"] == nil)
        #expect((stored["locationInformation"] as? [String: Any])?["id"] as? String == id)
        #expect((stored["accountSettings"] as? [String: Any])?["adminPassword"] == nil)

        var update = stored
        update["versionLock"] = 0
        _ = try await send(dest, "PUT", "pro/v3/computer-prestages/\(id)", json: update)
        #expect(await status { try await send(dest, "PUT", "pro/v3/computer-prestages/\(id)", json: update) } == 409,
                "the lock moved on")
        let after = try object(try await send(dest, "GET", "pro/v3/computer-prestages/\(id)"))
        #expect(after["versionLock"] as? Int == 1 && after["profileUuid"] as? String == stored["profileUuid"] as? String)
    }

    @Test("Patch titles: subscribe through Classic, then merge-patch only; patch policies under their title")
    func patchTitles() async throws {
        let demo = demoMode()
        let dest = try client(demo, .demoJamfProDestination)
        let sources = try object(try await send(dest, "GET", "proclassic/patchinternalsources", accept: "application/json"))
        #expect((sources["patch_internal_sources"] as? [[String: Any]])?.first?["name"] as? String == "Jamf")
        let answer = String(decoding: try await send(dest, "POST", "proclassic/patchsoftwaretitles/id/0", xml:
            "<patch_software_title><name>Google Chrome</name><name_id>0BC</name_id><source_id>1</source_id></patch_software_title>").data,
                            as: UTF8.self)
        let id = try #require(answer.firstMatch(of: /<id>(\d+)<\/id>/)?.output.1)
        let list = try await send(dest, "GET", "pro/v3/patch-software-title-configurations")
        #expect((try JSONSerialization.jsonObject(with: list.data) as? [[String: Any]])?.count == 1, "a bare array")

        let path = "pro/v3/patch-software-title-configurations/\(id)"
        #expect(await status { try await send(dest, "PATCH", path, json: ["categoryId": "5"]) } == 415)
        _ = try await send(dest, "PATCH", path, json: ["categoryId": "5"], contentType: "application/merge-patch+json",
                           accept: "application/json")
        #expect(try object(try await send(dest, "GET", path))["categoryId"] as? String == "5")

        _ = try await send(dest, "POST", "proclassic/patchpolicies/softwaretitleconfig/id/\(id)", xml:
            "<patch_policy><general><name>Contoso – Chrome updates</name></general></patch_policy>")
        let policy = try #require(demo.jamfProDestinationServer.objects?.classicXML("patchpolicies", named: "Contoso – Chrome updates"))
        #expect(policy.contains("<software_title_configuration_id>\(id)</software_title_configuration_id>"))
    }

    @Test("Icons download from the source and upload to the destination")
    func icons() async throws {
        let demo = demoMode()
        let source = try client(demo, .demoJamfProSource)
        let dest = try client(demo, .demoJamfProDestination)
        let image = try await send(source, "GET", "pro/v1/icon/download/1", accept: "*/*").data
        #expect(image == DemoJamfProObjectSamples.iconData)
        var body = Data("--b\r\nContent-Disposition: form-data; name=\"file\"; filename=\"notes.png\"\r\n\r\n".utf8)
        body.append(image)
        body.append(Data("\r\n--b--\r\n".utf8))
        let upload = try await dest.send(HTTPRequest(method: "POST", path: "pro/v1/icon", body: body,
                                                     contentType: "multipart/form-data; boundary=b"), privileges: [])
        #expect(try object(upload)["name"] as? String == "notes.png")
    }

    @Test("Source and destination are separate; writes last for the launch; a new launch starts fresh")
    func separate() async throws {
        let demo = demoMode()
        _ = try await send(try client(demo, .demoJamfProDestination), "POST", "pro/v1/categories", json: ["name": "Contoso New"])
        #expect(demo.jamfProDestinationServer.objects?.names(at: "api/v1/categories").contains("Contoso New") == true)
        #expect(demo.jamfProSourceServer.objects?.names(at: "api/v1/categories").contains("Contoso New") == false)
        _ = try await send(try client(demo, .demoJamfProDestination), "GET", "pro/v1/categories")
        #expect(demo.jamfProDestinationServer.objects?.names(at: "api/v1/categories").contains("Contoso New") == true)
        #expect(demoMode().jamfProDestinationServer.objects?.names(at: "api/v1/categories").contains("Contoso New") == false)
    }

    @Test("missingPermission: the destination refuses webhooks and single sign-on with 403")
    func missingPermission() async throws {
        let demo = demoMode(scenario: "missingPermission")
        let dest = try client(demo, .demoJamfProDestination)
        #expect(await status { try await send(dest, "GET", "proclassic/webhooks", accept: "application/json") } == 403)
        #expect(await status { try await send(dest, "GET", "pro/v3/sso") } == 403)
        #expect(await status { try await send(dest, "GET", "pro/v3/check-in") } == 200)
        let source = try client(demo, .demoJamfProSource)
        #expect(await status { try await send(source, "GET", "proclassic/webhooks", accept: "application/json") } == 200)
    }

    @Test("Every host, address and e-mail in the sample objects is fake")
    func clearlyFake() throws {
        for seed in [DemoJamfProObjectSamples.source, DemoJamfProObjectSamples.destination] {
            var text = seed.classic.values.flatMap { $0.map(\.1) }.joined()
            for objects in seed.pro.values {
                text += String(decoding: try JSONSerialization.data(withJSONObject: objects), as: UTF8.self)
            }
            text += String(decoding: try JSONSerialization.data(withJSONObject: seed.settings), as: UTF8.self)
            text = text.replacingOccurrences(of: "\\/", with: "/")
            for match in text.matches(of: /(?:https?|ipp):\/\/([A-Za-z0-9.\-]+)/) {
                let host = String(match.output.1)
                #expect(host.hasSuffix(".contoso.example") || host.hasSuffix(".demo.invalid"), "\(host)")
            }
            for match in text.matches(of: /[A-Za-z0-9.\-]+@([A-Za-z0-9.\-]+)/) {
                #expect(match.output.1 == "contoso.example", "\(match.output.0)")
            }
            for match in text.matches(of: /<serial_number_\d>([^<]+)</) {
                #expect(match.output.1.hasPrefix("ZZDEMO"), "\(match.output.1)")
            }
            for match in text.matches(of: /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/) {
                #expect(DemoSamples.isDemoID(String(match.output)), "\(match.output)")
            }
        }
    }
}
