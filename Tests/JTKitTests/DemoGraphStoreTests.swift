import Foundation
import Testing
@testable import JTKit
import JTKitTestSupport

/// The demo sign-in’s fixed token, as an app hands it to `Graph.Client`.
private struct DemoSignInToken: BearerTokenSource {
    let value: String
    func token() async throws -> String { value }
    func forgetToken() async {}
}

private struct SampleIntuneProfile: ConnectionRecord {
    var connection: Connection
    var id: UUID { connection.id }
}

@MainActor
private func demoMode(scenario: String? = nil) -> DemoMode {
    let defaults = UserDefaults(suiteName: "jtkit-demo-graph-\(UUID().uuidString)")!
    var arguments = ["app"]
    if let scenario { arguments += ["-JTKitDemoScenario", scenario] }
    return DemoMode(key: "demoMode", defaults: defaults, arguments: arguments)
}

/// A client for the demo tenant as Intune Deployer builds one: the demo
/// sign-in’s token, delegated access, the demo network’s session.
@MainActor
private func delegatedClient(_ demo: DemoMode, log: ActivityLog? = nil) -> Graph.Client {
    let signIn = demo.microsoftSignIn()
    return Graph.Client(tokens: DemoSignInToken(value: signIn.accessToken), access: .delegated,
                        recorder: Graph.recorder(session: signIn.session, log: log, connection: signIn.connection.name),
                        sleep: { _ in })
}

/// A client on a server of its own, e.g. with small pages.
private func client(on server: DemoIntuneServer, token: String = DemoIntuneServer.delegatedToken) -> Graph.Client {
    let network = DemoNetwork(servers: Dictionary(uniqueKeysWithValues: DemoIntuneServer.hosts.map { ($0, server as any DemoServer) }))
    return Graph.Client(tokens: DemoSignInToken(value: token), access: .delegated,
                        recorder: Graph.recorder(session: network.session, log: nil), sleep: { _ in })
}

private func json(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func body(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

private struct Named: Decodable {
    let id: String
    let displayName: String?
    let name: String?
    let description: String?
}

@Suite("Demo Graph store")
@MainActor
struct DemoGraphStoreTests {
    @Test("The demo sign-in reaches Contoso’s tenant with its fixed token; nothing else signs in")
    func signedIn() async throws {
        let demo = demoMode()
        let signIn = demo.microsoftSignIn()
        #expect(signIn.connection == .demoIntune && signIn.connection.name == "Contoso Intune (Demo)")
        #expect(signIn.username == "demo.sample@contoso.example")
        let client = delegatedClient(demo)
        let me = try json(try await client.getRaw("me?$select=displayName,userPrincipalName", version: .v1))
        #expect(me["userPrincipalName"] as? String == signIn.username)
        #expect(me["mail"] == nil, "$select keeps only what was asked")
        let organizations = try await client.listRaw("organization", version: .v1).map(json)
        #expect(organizations.map { $0["id"] as? String } == [DemoWorld.intuneTenantID])
        let authority = try json(try await client.getRaw(
            "organization/\(DemoWorld.intuneTenantID)?$select=id,mobileDeviceManagementAuthority", version: .v1))
        #expect(authority["mobileDeviceManagementAuthority"] as? String == "intune")
        // another token is refused, as Graph refuses it
        await #expect(throws: Graph.APIError.self) {
            _ = try await DemoGraphStoreTests.meWith(token: "eyJ-not-the-demo-token")
        }
    }

    private static func meWith(token: String) async throws -> Data {
        try await client(on: DemoIntuneServer(), token: token).getRaw("me", version: .v1)
    }

    @Test("Lists are paged on Graph’s address, with $filter and $select kept on the next page")
    func paging() async throws {
        let server = DemoIntuneServer(pageSize: 2)
        let client = client(on: server)
        let groups = try await client.list(Named.self, "groups", version: .v1)
        #expect(groups.map(\.displayName) == ["Contoso Macs", "Contoso iPads", "Contoso Finance Macs"])
        let found = try await client.listRaw(
            "groups?$filter=displayName eq 'contoso finance macs'&$select=id,displayName,groupTypes", version: .v1).map(json)
        #expect(found.count == 1)
        #expect(found.first?["groupTypes"] as? [String] == ["DynamicMembership"])
        #expect(found.first?["mailNickname"] == nil)
        #expect(try await client.list(Named.self, "groups?$filter=displayName eq 'Nobody'", version: .v1).isEmpty)
        // three groups plus a page of two: the next link was followed
        for index in 0..<3 {
            _ = try await client.post("groups", version: .v1, body: try body(["displayName": "Contoso Group \(index)"]))
        }
        #expect(try await client.list(Named.self, "groups?$select=id,displayName", version: .v1).count == 6)
    }

    @Test("Create returns the new ID; PATCH, PUT and DELETE change the tenant; v1.0 and beta are one tenant")
    func writes() async throws {
        let demo = demoMode()
        let client = delegatedClient(demo)
        let path = "deviceManagement/deviceConfigurations"
        let created = try json(try await client.post(path, version: .v1, body: try body([
            "@odata.type": "#microsoft.graph.macOSCustomConfiguration", "displayName": "Contoso – Login Window",
            "description": "Sample", "payload": "PGRpY3QvPg==",
        ])))
        let id = try #require(created["id"] as? String)
        #expect(DemoSamples.isDemoID(id))
        #expect(try await client.list(Named.self, path, version: .beta).contains { $0.id == id }, "beta sees it too")
        try await client.patch("\(path)/\(id)", version: .v1, body: try body(["description": "Changed"]))
        let patched = try json(try await client.getRaw("\(path)/\(id)", version: .v1))
        #expect(patched["description"] as? String == "Changed" && patched["payload"] as? String == "PGRpY3QvPg==")
        try await client.delete("\(path)/\(id)", version: .v1)
        #expect(try await client.list(Named.self, path, version: .v1).allSatisfy { $0.id != id })
        await #expect(throws: Graph.APIError.self) { _ = try await client.getRaw("\(path)/\(id)", version: .v1) }
        // a beta-only list refuses v1.0, as Graph does
        await #expect(throws: Graph.APIError.self) {
            _ = try await client.listRaw("deviceManagement/configurationPolicies", version: .v1)
        }
        #expect(demo.intuneServer.objects(at: path).count == 1, "only Contoso's own is left")
    }

    @Test("Settings Catalog: settings are their own list; PUT replaces them; definitions come from the catalog")
    func settingsCatalog() async throws {
        let demo = demoMode()
        let client = delegatedClient(demo)
        func setting(_ id: String, _ value: String) -> [String: Any] {
            ["@odata.type": "#microsoft.graph.deviceManagementConfigurationSetting",
             "settingInstance": ["@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
                                 "settingDefinitionId": id, "choiceSettingValue": ["value": value, "children": []]]]
        }
        let path = "deviceManagement/configurationPolicies"
        let created = try json(try await client.post(path, version: .beta, body: try body([
            "name": "Contoso – Screensaver", "description": "", "platforms": "macOS", "technologies": "mdm",
            "settings": [setting("com.apple.screensaver_idletime", "com.apple.screensaver_idletime_300")],
        ])))
        let id = try #require(created["id"] as? String)
        let listed = try await client.listRaw(path, version: .beta).map(json)
        #expect(listed.first { $0["id"] as? String == id }?["settings"] == nil, "the list leaves settings out")
        #expect(try await client.listRaw("\(path)/\(id)/settings", version: .beta).count == 1)
        try await client.put("\(path)/\(id)", version: .beta, body: try body([
            "name": "Contoso – Screensaver", "description": "", "platforms": "macOS", "technologies": "mdm",
            "settings": [setting("a_1", "a_1_0"), setting("b_1", "b_1_1")],
        ]))
        #expect(try await client.listRaw("\(path)/\(id)/settings", version: .beta).count == 2)
        // the catalog: Contoso’s own definition, then the ones an app adds
        demo.intuneServer.add(definitions: [DemoSettingDefinition(id: "a_1", displayName: "A", options: [("a_1_0", "Off")])])
        let ids = try await client.list(Named.self,
            "deviceManagement/configurationSettings?$select=id&$top=1000&$filter=(platforms has 'macOS') and technologies has 'mdm'",
            version: .beta).map(\.id)
        #expect(ids == ["a_1", "com.apple.mcx.filevault2_enable"])
        let definition = try json(try await client.getRaw("deviceManagement/configurationSettings/a_1", version: .beta))
        #expect((definition["options"] as? [[String: Any]])?.first?["itemId"] as? String == "a_1_0")
        await #expect(throws: Graph.APIError.self) {
            _ = try await client.getRaw("deviceManagement/configurationSettings/unknown", version: .beta)
        }
    }

    @Test("Compliance rules only with $expand; scheduleActionsForRules replaces them; /assign keeps assignments")
    func complianceAndAssign() async throws {
        let demo = demoMode()
        let client = delegatedClient(demo)
        let path = "deviceManagement/deviceCompliancePolicies"
        let plain = try await client.listRaw(path, version: .v1).map(json)
        #expect(plain.allSatisfy { $0["scheduledActionsForRule"] == nil })
        let expanded = try await client.listRaw(
            "\(path)?$expand=scheduledActionsForRule($expand=scheduledActionConfigurations)", version: .v1).map(json)
        let id = try #require(expanded.first?["id"] as? String)
        #expect((expanded.first?["scheduledActionsForRule"] as? [Any])?.count == 1)
        try await client.post("\(path)/\(id)/scheduleActionsForRules", version: .v1, body: try body([
            "deviceComplianceScheduledActionForRules": [["ruleName": "PasswordRequired"], ["ruleName": "Second"]],
        ]), safeToRepeat: true)
        let again = try await client.listRaw("\(path)?$expand=scheduledActionsForRule", version: .v1).map(json)
        #expect((again.first?["scheduledActionsForRule"] as? [Any])?.count == 2)
        try await client.post("\(path)/\(id)/assign", version: .v1, body: try body([
            "assignments": [["target": ["@odata.type": "#microsoft.graph.allDevicesAssignmentTarget"]]],
        ]), safeToRepeat: true)
        #expect(try await client.listRaw("\(path)/\(id)/assignments", version: .v1).count == 1)
    }

    @Test("Script lists leave out the content, as Graph does; one script has it")
    func scripts() async throws {
        let client = delegatedClient(demoMode())
        let path = "deviceManagement/deviceShellScripts"
        let listed = try await client.listRaw(path, version: .beta).map(json)
        let id = try #require(listed.first?["id"] as? String)
        #expect(listed.first?["scriptContent"] == nil)
        let one = try json(try await client.getRaw("\(path)/\(id)", version: .beta))
        #expect(one["scriptContent"] is String)
    }

    @Test("An app upload runs to published without waiting; the content goes to the fake storage host only")
    func upload() async throws {
        let demo = demoMode()
        let log = ActivityLog()
        let client = delegatedClient(demo, log: log)
        let apps = "deviceAppManagement/mobileApps"
        let app = try json(try await client.post(apps, version: .beta, body: try body([
            "@odata.type": "#microsoft.graph.macOSPkgApp", "displayName": "Contoso Tool", "description": "",
        ])))
        let appID = try #require(app["id"] as? String)
        #expect(app["publishingState"] as? String == "notPublished")
        let lob = "\(apps)/\(appID)/microsoft.graph.mobileLobApp"
        let version = try json(try await client.post("\(lob)/contentVersions", version: .beta, body: Data("{}".utf8)))
        let versionID = try #require(version["id"] as? String)
        #expect(versionID == "1")
        let file = try json(try await client.post("\(lob)/contentVersions/\(versionID)/files", version: .beta,
                                                  body: try body(["name": "tool.pkg", "size": 10, "manifest": NSNull()])))
        let fileID = try #require(file["id"] as? String)
        let filePath = "\(lob)/contentVersions/\(versionID)/files/\(fileID)"
        let ready = try json(try await client.getRaw(filePath, version: .beta))
        #expect(ready["uploadState"] as? String == "azureStorageUriRequestSuccess", "ready on the first read")
        let uri = try #require(ready["azureStorageUri"] as? String)
        #expect(URL(string: uri)?.host() == DemoIntuneServer.storageHost)

        // the blocks and the block list, through the client’s own session
        let recorder = client.recorder
        for (blockID, bytes) in [("YmxvY2sx", Data(repeating: 1, count: 6)), ("YmxvY2sy", Data(repeating: 2, count: 4))] {
            var request = URLRequest(url: try #require(URL(string: "\(uri)&comp=block&blockid=\(blockID)")))
            request.httpMethod = "PUT"
            request.httpBody = bytes
            request.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
            #expect(try await recorder.send(request).1.statusCode == 201)
        }
        var list = URLRequest(url: try #require(URL(string: "\(uri)&comp=blocklist")))
        list.httpMethod = "PUT"
        list.httpBody = Data("<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList><Latest>YmxvY2sx</Latest><Latest>YmxvY2sy</Latest></BlockList>".utf8)
        #expect(try await recorder.send(list).1.statusCode == 201)
        #expect(demo.intuneServer.uploadedBytes == 10)

        try await client.post("\(filePath)/commit", version: .beta,
                              body: try body(["fileEncryptionInfo": ["encryptionKey": "a2V5", "mac": "bWFj"]]))
        let committed = try json(try await client.getRaw(filePath, version: .beta))
        #expect(committed["uploadState"] as? String == "commitFileSuccess")
        #expect(committed["fileEncryptionInfo"] == nil, "the key isn't kept")
        try await client.patch("\(apps)/\(appID)", version: .beta, body: try body([
            "@odata.type": "#microsoft.graph.macOSPkgApp", "committedContentVersion": versionID,
        ]))
        let published = try json(try await client.getRaw("\(apps)/\(appID)?$select=publishingState", version: .beta))
        #expect(published["publishingState"] as? String == "published")
        #expect(log.entries.allSatisfy { !$0.operation.contains("blob.core.windows.net") && !$0.detail.contains("blob.core.windows.net") })
        #expect(log.entries.allSatisfy { $0.connection == "Contoso Intune (Demo)" })
    }

    @Test("A commit without the uploaded content fails, as Graph’s does")
    func commitWithoutContent() async throws {
        let client = delegatedClient(demoMode())
        let apps = "deviceAppManagement/mobileApps"
        let appID = try #require(try json(try await client.post(apps, version: .beta, body: try body([
            "@odata.type": "#microsoft.graph.macOSDmgApp", "displayName": "Contoso Disk Image",
        ])))["id"] as? String)
        let versions = "\(apps)/\(appID)/microsoft.graph.mobileLobApp/contentVersions"
        _ = try await client.post(versions, version: .beta, body: Data("{}".utf8))
        let fileID = try #require(try json(try await client.post("\(versions)/1/files", version: .beta,
                                                                 body: try body(["name": "x.dmg"])))["id"] as? String)
        _ = try await client.getRaw("\(versions)/1/files/\(fileID)", version: .beta)
        try await client.post("\(versions)/1/files/\(fileID)/commit", version: .beta, body: try body(["fileEncryptionInfo": [:]]))
        let file = try json(try await client.getRaw("\(versions)/1/files/\(fileID)", version: .beta))
        #expect(file["uploadState"] as? String == "commitFileFailed")
    }

    @Test("missingPermission: reads work, every write gets Graph’s real 403 naming the permission")
    func missingPermission() async throws {
        let client = delegatedClient(demoMode(scenario: "missingPermission"))
        #expect(!(try await client.listRaw("deviceManagement/deviceConfigurations", version: .v1)).isEmpty)
        #expect(!(try await client.listRaw("deviceAppManagement/mobileApps", version: .beta)).isEmpty)
        let writes: [(String, Graph.Version, Graph.Permission)] = [
            ("deviceManagement/deviceConfigurations", .v1, .configurationReadWrite),
            ("deviceManagement/deviceShellScripts", .beta, .scriptsReadWrite),
            ("deviceAppManagement/mobileApps", .beta, .appsReadWrite),
            ("groups", .v1, .groupReadWrite),
        ]
        for (path, version, permission) in writes {
            do {
                _ = try await client.post(path, version: version, body: try body(["displayName": "Contoso"]))
                Issue.record("\(path) was written")
            } catch let error as Graph.APIError {
                #expect(error.status == 403, "\(path)")
                #expect(error.permission == permission, "\(path)")
                #expect(error.body?.code == (path == "groups" ? "Authorization_RequestDenied" : "Forbidden"))
            }
        }
    }

    @Test("Contoso’s tenant is clearly fake: IDs in the fake range, Contoso names, contoso.example addresses")
    func clearlyFake() throws {
        let server = DemoIntuneServer()
        for list in DemoGraphStore.knownLists where list != "deviceManagement/configurationSettings" {
            for data in server.objects(at: list) {
                let object = try json(data)
                let id = try #require(object["id"] as? String)
                #expect(DemoSamples.isDemoID(id), "\(list): \(id)")
                let name = object["displayName"] as? String ?? object["name"] as? String ?? object["tokenName"] as? String ?? ""
                #expect(name.hasPrefix("Contoso") || name == "Microsoft Edge", "\(list): \(name)")
                let text = String(decoding: data, as: UTF8.self)
                for match in text.matches(of: /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/) {
                    #expect(match.output.hasSuffix("@contoso.example"), "\(match.output)")
                }
            }
        }
        #expect(DemoGraphStore.username.hasSuffix("@contoso.example"))
        #expect(DemoIntuneServer.storageHost.hasSuffix(".demo.invalid"))
    }

    @Test("An app’s own sample objects join the tenant’s list")
    func addedObjects() async throws {
        let demo = demoMode()
        let tagged = try body(["@odata.type": "#microsoft.graph.macOSCustomConfiguration",
                               "displayName": "Contoso – Old Wi-Fi", "description": "Sample [App:0de0a1f1]"])
        demo.intuneServer.add([tagged], to: "deviceManagement/deviceConfigurations")
        let listed = try await delegatedClient(demo).list(Named.self, "deviceManagement/deviceConfigurations", version: .v1)
        #expect(listed.map(\.displayName) == ["Contoso – Dock", "Contoso – Old Wi-Fi"])
        #expect(listed.allSatisfy { DemoSamples.isDemoID($0.id) })
    }
}

@Suite("Demo connections are never saved, also under a new ID")
@MainActor
struct DemoImportTests {
    @Test("A demo tenant imported under a new ID is still a demo one, and the saved list refuses it")
    func importedDemoTenant() throws {
        var imported = Connection.demoIntune
        imported.id = UUID()
        imported.name = "Contoso Intune (Demo) (imported)"
        #expect(imported.isDemo, "by its tenant ID")
        var byClient = Connection(name: "Lookalike", service: .intune, clientID: " \(DemoSamples.uuid(0xc041)) ",
                                  tenantID: UUID().uuidString)
        #expect(byClient.isDemo, "by its client ID, whitespace and all")
        byClient.clientID = UUID().uuidString
        #expect(!byClient.isDemo, "a real tenant and app registration")
        let store = ConnectionStore<SampleIntuneProfile>(storage: InMemoryConnectionStorage(), secrets: [:])
        #expect(throws: ConnectionStoreError.self) { try store.save(SampleIntuneProfile(connection: imported)) }
        try store.save(SampleIntuneProfile(connection: byClient))
        #expect(store.records.map(\.connection) == [byClient])
    }
}
