import Foundation
import Testing
@testable import JTKitLiveCheck
import JTKitTestSupport

/// A run on the sample allow-list, with a fast read-back.
private func makeTestRun(upstream: URLSession, roles: String = "jamf-test-a,intune-test",
                         readBack: ReadBack = ReadBack(attempts: 2, interval: 0.01)) throws -> LiveCheckRun {
    let folder = tempFolder()
    let list = folder.appending(path: "allowlist.json")
    try JSONEncoder().encode(sampleList()).write(to: list)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: list.path)
    return try LiveCheckRun(environment: [
        "JTKIT_LIVE": "1", "JTKIT_LIVE_PREFIX": prefix, "JTKIT_LIVE_RUN_DIR": folder.appending(path: "run").path,
        "JTKIT_LIVE_ROLES": roles, "JTKIT_LIVE_WRITES": "1",
    ], upstream: upstream, readBack: readBack, allowListURL: list)
}

private func send(_ method: String, _ url: String, on run: LiveCheckRun, headers: [String: String] = [:], body: String? = nil) async throws {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    request.httpBody = body.map { Data($0.utf8) }
    _ = try await run.network.session.data(for: request)
}

private func xml(_ text: String) -> MockResponse {
    MockResponse(status: 200, headers: ["Content-Type": "application/xml"], body: Data(text.utf8))
}

// MARK: - L1: the Jamf Pro fallback of a Platform group delete

@Suite("Live check: the Jamf Pro fallback never reaches another group")
struct JamfProFallbackTests {
    private let group = "830636ce-d876-4768-a1df-0be83503e0f1"
    private let gateway = "https://eu.api.jamfcloud.com"
    private var groupURL: String { "\(gateway)/device-groups/v1/device-groups/\(group)" }
    private let headers = ["X-Environment-Id": platformA]

    /// A Platform group Jamf still lists after its delete answered `deleteStatus`.
    private func server(entry: String, classicName: String? = nil, deleteStatus: Int = 404, listed: Flag = Flag(true)) -> MockServer {
        MockServer { request in
            switch (request.method, request.path) {
            case ("GET", "/pro/v2/groups"):
                return .json(200, #"{"totalCount":1,"results":["# + (listed.value ? entry : "") + "]}")
            case ("GET", let path) where path.hasPrefix("/proclassic/"):
                guard let classicName else { return .json(404, "{}") }
                return xml("<group><id>57</id><name>\(classicName)</name></group>")
            case ("DELETE", let path) where path.hasPrefix("/proclassic/"):
                listed.set(false)
                return .json(200, "")
            case ("DELETE", _):
                return .json(deleteStatus, #"{"httpStatus":\#(deleteStatus),"errors":[{"code":"NOT_FOUND"}]}"#)
            default:
                return .json(404, #"{"httpStatus":404,"errors":[{"code":"NOT_FOUND"}]}"#)
            }
        }
    }

    private func entry(_ fields: String) -> String {
        #"{"groupPlatformId":"\#(group)","groupJamfProId":"57","groupName":"\#(prefix) – Group",\#(fields)}"#
    }

    private func run(on server: MockServer) throws -> LiveCheckRun {
        let run = try makeTestRun(upstream: server.session)
        try run.ledger.add(created("platform:\(platformA)", "device-groups", group, "\(prefix) – Group"), testPrefixes: [prefix])
        return run
    }

    private func classicDeletes(_ server: MockServer) -> [String] {
        server.requests.filter { $0.method == "DELETE" && $0.path.hasPrefix("/proclassic/") }.map(\.path)
    }

    @Test("A mobile device group (MOBILE in the list) is deleted as a mobile device group, never a computer group",
          arguments: [#""groupType":"MOBILE","smart":false"#, #""deviceType":"MOBILE","groupType":"SMART""#])
    func mobileGroupNeverDeletesAComputerGroup(fields: String) async throws {
        let server = server(entry: entry(fields), classicName: "\(prefix) – Group")
        let run = try run(on: server)
        try await send("DELETE", groupURL, on: run, headers: headers)
        #expect(classicDeletes(server) == ["/proclassic/mobiledevicegroups/id/57"])
        #expect(!server.requests.contains { $0.path.contains("computergroups") })
        #expect(run.notRemoved.isEmpty)
        #expect(run.network.deletes.first?.throughJamfPro == true)
    }

    @Test("A computer group in the list’s real shape (deviceType COMPUTER, groupType SMART or STATIC) is deleted as a computer group",
          arguments: ["SMART", "STATIC"])
    func computerGroupInTheRealShape(groupType: String) async throws {
        let server = server(entry: entry(#""deviceType":"COMPUTER","groupType":"\#(groupType)""#), classicName: "\(prefix) – Group")
        let run = try run(on: server)
        try await send("DELETE", groupURL, on: run, headers: headers)
        #expect(classicDeletes(server) == ["/proclassic/computergroups/id/57"])
        #expect(!server.requests.contains { $0.path.contains("mobiledevicegroups") })
        #expect(run.notRemoved.isEmpty)
    }

    @Test("A Platform delete answered with an error deletes nothing else")
    func refusedPlatformDeleteHasNoFallback() async throws {
        let server = server(entry: entry(#""groupType":"MOBILE""#), classicName: "\(prefix) – Group", deleteStatus: 403)
        let run = try run(on: server)
        try await send("DELETE", groupURL, on: run, headers: headers)
        #expect(!server.requests.contains { $0.path.hasPrefix("/proclassic/") })
        #expect(run.notRemoved.count == 1)
    }

    @Test("A list entry without a COMPUTER or MOBILE device type: refused, recorded, nothing deleted")
    func unknownTypeIsRefused() async throws {
        let server = server(entry: entry(#""groupType":"SMART""#), classicName: "\(prefix) – Group")
        let run = try run(on: server)
        try await send("DELETE", groupURL, on: run, headers: headers)
        #expect(classicDeletes(server).isEmpty)
        #expect(!server.requests.contains { $0.path.contains("computergroups") })
        #expect(run.network.refusals.contains { $0.reason.contains("COMPUTER or MOBILE") })
        #expect(run.notRemoved.count == 1)
    }

    @Test("The Classic twin is read back first: another name, or no twin, and it isn’t deleted", arguments: ["Finance iPads", nil])
    func classicTwinNeedsTheLedgerName(classicName: String?) async throws {
        let server = server(entry: entry(#""groupType":"MOBILE""#), classicName: classicName)
        let run = try run(on: server)
        try await send("DELETE", groupURL, on: run, headers: headers)
        #expect(server.requests.contains { $0.method == "GET" && $0.path == "/proclassic/mobiledevicegroups/id/57" })
        #expect(classicDeletes(server).isEmpty)
        #expect(run.network.refusals.contains { $0.reason.contains("isn’t “\(prefix) – Group” when read back") })
        #expect(run.notRemoved.count == 1)
    }

    @Test("The fallback goes through the policy and is recorded in the ledger as the group’s alias")
    func fallbackIsRecordedAndDecided() async throws {
        let server = server(entry: entry(#""groupType":"COMPUTER""#), classicName: "\(prefix) – Group")
        let run = try run(on: server)
        let classic = request("DELETE", "\(gateway)/proclassic/computergroups/id/57", headers: headers)
        #expect(!run.policy.decide(classic).isAllowed, "not the run’s object before the fallback")
        try await send("DELETE", groupURL, on: run, headers: headers)
        let item = try #require(run.ledger.item(target: "platform:\(platformA)", resource: "device-groups", id: group))
        #expect(item.aliases == ["computergroups/57"] && item.removed)
        #expect(run.ledger.item(target: "platform:\(platformA)", resource: "computergroups", id: "57") == item)
        #expect(run.policy.decide(classic).isAllowed)
        #expect(Ledger(fileURL: run.ledger.fileURL).items.first?.aliases == ["computergroups/57"], "written to disk")
    }

    @Test("Jamf’s list may put COMPUTER or MOBILE in deviceType or groupType")
    func classicGroupKinds() {
        #expect(LiveCheckNetwork.classicGroupKind(["groupType": "COMPUTER", "smart": true]) == "computergroups")
        #expect(LiveCheckNetwork.classicGroupKind(["groupType": "MOBILE"]) == "mobiledevicegroups")
        #expect(LiveCheckNetwork.classicGroupKind(["deviceType": "MOBILE", "groupType": "SMART"]) == "mobiledevicegroups")
        #expect(LiveCheckNetwork.classicGroupKind(["deviceType": "COMPUTER", "groupType": "STATIC"]) == "computergroups")
        #expect(LiveCheckNetwork.classicGroupKind(["deviceType": "MOBILE", "groupType": "STATIC"]) == "mobiledevicegroups")
        #expect(LiveCheckNetwork.classicGroupKind(["groupType": "STATIC"]) == nil)
        #expect(LiveCheckNetwork.classicGroupKind([:]) == nil)
    }
}

// MARK: - L5: objects test code recorded are read back before a write

@Suite("Live check: recorded objects are read back before their first change or delete")
struct ReadBackBeforeWriteTests {
    private let jamf = "https://test-a.jamf.example"

    @Test("An adopted object whose name on the server differs: the delete is refused and never sent")
    func otherNameIsRefused() async throws {
        let server = MockServer { request in
            request.method == "GET" ? .json(200, #"{"id":"7","name":"Finance"}"#) : .json(204, "")
        }
        let run = try makeTestRun(upstream: server.session)
        try run.adoptForSweep(role: "jamf-test-a", service: .jamfPro, resource: "categories", id: "7", name: "JTKTEST JD 0101-0000 – Old")
        await #expect(throws: (any Error).self) { try await send("DELETE", "\(jamf)/api/v1/categories/7", on: run) }
        #expect(!server.requests.contains { $0.method == "DELETE" })
        #expect(server.requests.map(\.path) == ["/api/v1/categories/7"])
        #expect(run.network.refusals.first?.reason.contains("“Finance” on the server") == true)
        #expect(run.notRemoved.count == 1)
    }

    @Test("The same name on the server: the write goes ahead, and the object counts as confirmed")
    func sameNameIsAllowed() async throws {
        let name = "\(prefix) – Category"
        let server = MockServer { request in
            switch (request.method, request.path) {
            case ("GET", "/api/v1/categories/12"): .json(200, #"{"id":"12","name":"\#(name)","priority":9}"#)
            default: .json(200, "{}")
            }
        }
        let run = try makeTestRun(upstream: server.session)
        try run.recordCreated(role: "jamf-test-a", service: .jamfPro, resource: "categories", id: "12", name: name)
        try await send("PUT", "\(jamf)/api/v1/categories/12/history", on: run, body: #"{"note":"x"}"#)
        try await send("PUT", "\(jamf)/api/v1/categories/12", on: run, body: #"{"name":"\#(name)","priority":3}"#)
        #expect(server.requests.map { "\($0.method) \($0.path)" }
                == ["GET /api/v1/categories/12", "PUT /api/v1/categories/12/history", "PUT /api/v1/categories/12"],
                "read back once, before the first write")
        #expect(run.ledger.items.first?.confirmed == true)
    }

    @Test("The read-back of a write announces no body: Jamf Pro answers 400 to a GET with Content-Length")
    func readBackHasNoBodyHeaders() async throws {
        let name = "\(prefix) – Category"
        let server = MockServer { request in
            switch request.method {
            case "GET" where request.headers.keys.contains { ["content-length", "content-type", "transfer-encoding"].contains($0.lowercased()) }:
                .json(400, #"{"httpStatus":400,"errors":[{"code":"INVALID_REQUEST"}]}"#)
            case "GET": .json(200, #"{"id":"241","name":"\#(name)"}"#)
            default: .json(200, "{}")
            }
        }
        let run = try makeTestRun(upstream: server.session)
        try run.recordCreated(role: "jamf-test-a", service: .jamfPro, resource: "categories", id: "241", name: name)
        try await send("PUT", "\(jamf)/api/v1/categories/241", on: run,
                       headers: ["Content-Type": "application/json", "Content-Length": "25"], body: #"{"name":"\#(name)","x":1}"#)
        #expect(server.requests.map { "\($0.method) \($0.path)" } == ["GET /api/v1/categories/241", "PUT /api/v1/categories/241"])
        #expect(run.network.refusals.isEmpty)

        var write = URLRequest(url: URL(string: "\(jamf)/api/v1/categories/241")!)
        write.httpMethod = "PUT"
        write.httpBody = Data("{}".utf8)
        for (header, value) in ["Content-Type": "application/json", "Content-Length": "2", "Transfer-Encoding": "chunked", "Authorization": "Bearer t"] {
            write.setValue(value, forHTTPHeaderField: header)
        }
        let read = LiveCheckNetwork.readBack(of: write)
        #expect(read.httpMethod == "GET" && read.httpBody == nil && read.httpBodyStream == nil)
        #expect(read.allHTTPHeaderFields == ["Authorization": "Bearer t"], "the sign-in stays; nothing of the body")
    }

    @Test("Classic XML and Classic JSON names are read, inside their wrapping key")
    func classicNames() {
        #expect(LiveCheckNetwork.serverName(in: Data(#"{"computer":{"general":{"id":5,"name":"JTKTEST A"}}}"#.utf8)) == "JTKTEST A")
        #expect(LiveCheckNetwork.serverName(in: Data(#"{"computer_group":{"id":5,"name":"JTKTEST B"}}"#.utf8)) == "JTKTEST B")
        #expect(LiveCheckNetwork.serverName(in: Data("<computer><general><id>5</id><name>JTKTEST C</name></general></computer>".utf8)) == "JTKTEST C")
        #expect(LiveCheckNetwork.serverName(in: Data(#"{"displayName":"JTKTEST D"}"#.utf8)) == "JTKTEST D")
        #expect(LiveCheckNetwork.serverName(in: Data(#"{"id":"5"}"#.utf8)) == nil)
        #expect(LiveCheckNetwork.objectURL(URL(string: "https://h.example/JSSResource/scripts/id/7/subset/General?x=1")!)?.absoluteString
                == "https://h.example/JSSResource/scripts/id/7")
        #expect(LiveCheckNetwork.objectURL(URL(string: "https://h.example/beta/deviceManagement/deviceShellScripts/11111111-2222-4333-8444-555555555555/assign")!)?.path()
                == "/beta/deviceManagement/deviceShellScripts/11111111-2222-4333-8444-555555555555")
    }

    @Test("An object already gone is deleted as before: the delete’s read-back decides")
    func goneObjectIsDeleted() async throws {
        let server = MockServer { request in request.method == "GET" ? .json(404, "{}") : .json(404, "{}") }
        let run = try makeTestRun(upstream: server.session)
        try run.adoptForSweep(role: "jamf-test-a", service: .jamfPro, resource: "categories", id: "8", name: "JTKTEST JD 0101-0000 – Old")
        try await send("DELETE", "\(jamf)/api/v1/categories/8", on: run)
        #expect(server.requests.map(\.method) == ["GET", "DELETE", "GET"])
        #expect(run.notRemoved.isEmpty)
    }

    @Test("Only kinds of object the live checks make can be adopted for the sweep",
          arguments: ["users", "computer-prestages", "buildings", "sites", "accounts", "webhooks"])
    func otherKindsAreRefused(resource: String) throws {
        let run = try makeTestRun(upstream: LiveCheckNetwork.makeUpstream())
        #expect(throws: LiveCheckRun.RunError.self) {
            try run.adoptForSweep(role: "jamf-test-a", service: .jamfPro, resource: resource, id: "3", name: "JTKTEST JD 0101-0000 – X")
        }
    }

    /// Every kind the eight apps’ cleanups adopt today.
    @Test("The kinds the apps’ sweeps adopt stay adoptable", arguments: [
        "blueprints", "device-groups", "osxconfigurationprofiles", "computergroups", "policies", "scripts", "categories",
        "static-groups", "computers", "mobiledevices",
    ])
    func appKindsAreAdoptable(resource: String) throws {
        let run = try makeTestRun(upstream: LiveCheckNetwork.makeUpstream())
        try run.adoptForSweep(role: "jamf-test-a", service: .jamfPro, resource: resource, id: "3", name: "JTKTEST JD 0101-0000 – X")
    }
}

// MARK: - L4: Jamf scopes

@Suite("Live check: Jamf scopes only reach the run’s own groups")
struct JamfScopeRuleTests {
    private let headers = ["X-Environment-Id": platformA]
    private let profile = "https://eu.api.jamfcloud.com/proclassic/osxconfigurationprofiles/id/21"
    private let blueprintID = "00000000-0000-4000-8000-0000000000b1"
    private let groupID = "00000000-0000-4000-8000-0000000000a7"

    private func policy() throws -> LiveCheckPolicy {
        let policy = makePolicy()
        let target = "platform:\(platformA)"
        try policy.ledger.add(created(target, "osxconfigurationprofiles", "21", "\(prefix) – Profile"), testPrefixes: [prefix])
        try policy.ledger.add(created(target, "computergroups", "88", "\(prefix) – Group"), testPrefixes: [prefix])
        try policy.ledger.add(created(target, "device-groups", groupID, "\(prefix) – Group"), testPrefixes: [prefix])
        try policy.ledger.add(created(target, "blueprints", blueprintID, "\(prefix) – Blueprint"), testPrefixes: [prefix])
        return policy
    }

    private func scoped(_ scope: String) -> String {
        "<os_x_configuration_profile><scope>\(scope)</scope></os_x_configuration_profile>"
    }

    @Test("The scopes the apps write are allowed")
    func appScopesAreAllowed() throws {
        let policy = try policy()
        // Profile2Blueprint: its profile to its own Classic group.
        let own = scoped("<all_computers>false</all_computers><all_jss_users>false</all_jss_users><computers/><computer_groups>"
                         + "<computer_group><id>88</id></computer_group></computer_groups><buildings/><departments/><jss_users/><jss_user_groups/>")
        #expect(policy.decide(request("PUT", profile, headers: headers, body: own)).kind == .change)
        // JamfMigrator: scoped to nothing; an exclusion only narrows a scope.
        #expect(policy.decide(request("PUT", profile, headers: headers, body: scoped("<all_computers>false</all_computers>"))).kind == .change)
        let excluded = scoped("<computer_groups><computer_group><id>88</id></computer_group></computer_groups>"
                              + "<exclusions><computer_groups><computer_group><id>5</id></computer_group></computer_groups></exclusions>")
        #expect(policy.decide(request("PUT", profile, headers: headers, body: excluded)).kind == .change)
        // A Blueprint scoped to the run’s Platform group.
        let blueprint = "https://eu.api.jamfcloud.com/blueprints/v1/blueprints/\(blueprintID)"
        #expect(policy.decide(request("PATCH", blueprint, headers: headers, json: ["scope": ["deviceGroups": [groupID.uppercased()]]])).kind == .change)
        #expect(policy.decide(request("POST", "https://eu.api.jamfcloud.com/blueprints/v1/blueprints", headers: headers,
                                      json: ["name": "\(prefix) – B2", "scope": ["deviceGroups": [groupID]]])).isAllowed)
    }

    @Test("All computers, all mobile devices and all users are refused, in a change and in a create", arguments: [
        "<all_computers>true</all_computers>", "<all_mobile_devices>true</all_mobile_devices>", "<all_jss_users> true </all_jss_users>",
    ])
    func everyoneIsRefused(scope: String) throws {
        let policy = try policy()
        #expect(!policy.decide(request("PUT", profile, headers: headers, body: scoped(scope))).isAllowed)
        let create = "<os_x_configuration_profile><general><name>\(prefix) – P</name></general><scope>\(scope)</scope></os_x_configuration_profile>"
        #expect(!policy.decide(request("POST", "https://eu.api.jamfcloud.com/proclassic/osxconfigurationprofiles/id/0",
                                       headers: headers, body: create)).isAllowed)
        #expect(!policy.decide(request("PUT", "https://test-a.jamf.example/api/v1/categories/1", json: ["allComputers": true])).isAllowed)
    }

    @Test("Any other group, a group by name, and devices, buildings or users in a scope are refused", arguments: [
        "<computer_groups><computer_group><id>5</id></computer_group></computer_groups>",
        "<computer_groups><computer_group><name>All Managed Clients</name></computer_group></computer_groups>",
        "<mobile_device_groups><mobile_device_group><id>9</id></mobile_device_group></mobile_device_groups>",
        "<computers><computer><id>3</id></computer></computers>",
        "<buildings><building><id>1</id><name>HQ</name></building></buildings>",
        "<jss_users><user><name>someone</name></user></jss_users>",
    ])
    func otherTargetsAreRefused(scope: String) throws {
        let policy = try policy()
        #expect(!policy.decide(request("PUT", profile, headers: headers, body: scoped(scope))).isAllowed)
    }

    @Test("A Blueprint scoped to a group the run didn’t create is refused, and a scope that can’t be read")
    func otherPlatformGroupsAreRefused() throws {
        let policy = try policy()
        let blueprint = "https://eu.api.jamfcloud.com/blueprints/v1/blueprints/\(blueprintID)"
        #expect(!policy.decide(request("PATCH", blueprint, headers: headers,
                                       json: ["scope": ["deviceGroups": [groupID, "00000000-0000-4000-8000-0000000000ff"]]])).isAllowed)
        #expect(!policy.decide(request("PUT", profile, headers: headers, body: "<os_x_configuration_profile><scope><all_computers>")).isAllowed)
        let category = "https://test-a.jamf.example/api/v1/categories/1"
        #expect(!policy.decide(request("PUT", category, json: ["scope": ["computerGroups": [["id": 5]]]])).isAllowed)
    }
}

// MARK: - L7: creates outside the ledger, and a ledger that can’t be saved

@Suite("Live check: nothing created is left out of the ledger")
struct UnrecordedCreateTests {
    @Test("A create answered 2xx without a readable ID is recorded, and fails the run")
    func createWithoutIDFailsTheRun() async throws {
        let server = MockServer { _ in .json(201, #"{"href":"x"}"#) }
        let run = try makeTestRun(upstream: server.session)
        try await send("POST", "https://test-a.jamf.example/api/v1/categories", on: run, body: #"{"name":"\#(prefix) – C"}"#)
        #expect(run.network.unrecordedCreates.map(\.name) == ["\(prefix) – C"])
        #expect(LiveCheckNetwork.unrecordedCreates(in: run.runFolder.appending(path: LiveCheckRun.unrecordedCreatesFileName)).count == 1)
        do {
            try run.requireNothingLeft()
            Issue.record("the run didn’t fail")
        } catch {
            #expect("\(error)".contains("Created but not in the ledger: categories “\(prefix) – C”"))
        }
    }

    @Test("A ledger file that can’t be read: empty, broken, and every create refused")
    func unreadableLedgerRefusesCreates() throws {
        let url = tempFolder().appending(path: "ledger.json")
        try Data("{ not json".utf8).write(to: url)
        let ledger = Ledger(fileURL: url)
        #expect(ledger.items.isEmpty && ledger.saveFailure != nil)
        let policy = LiveCheckPolicy(allowList: sampleList(), roles: nil, includeProduction: false, prefix: prefix, ledger: ledger)
        guard case .refuse(let reason) = policy.decide(request("POST", "https://test-a.jamf.example/api/v1/categories",
                                                               json: ["name": "\(prefix) – C"])) else {
            Issue.record("the create was allowed"); return
        }
        #expect(reason.contains("ledger"))
        #expect(throws: Ledger.LedgerError.self) {
            try ledger.add(.init(target: "a.example", resource: "categories", id: "1", name: "\(prefix) – A"), testPrefixes: [prefix])
        }
        #expect(Ledger(fileURL: tempFolder().appending(path: "none.json")).saveFailure == nil, "a missing file is a new ledger")
    }

    @Test("A failed write throws, and creates are refused from then on")
    func failedWriteBreaksTheLedger() throws {
        let folder = tempFolder()
        let ledger = Ledger(fileURL: folder.appending(path: "ledger.json"))
        try ledger.add(.init(target: "a.example", resource: "categories", id: "1", name: "\(prefix) – A"), testPrefixes: [prefix])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        #expect(throws: Ledger.LedgerError.self) { try ledger.recordRemoval(target: "a.example", resource: "categories", id: "1") }
        #expect(ledger.saveFailure != nil)
        #expect(throws: Ledger.LedgerError.self) {
            try ledger.add(.init(target: "a.example", resource: "categories", id: "2", name: "\(prefix) – B"), testPrefixes: [prefix])
        }
    }

    @Test("A ledger written before 0.13 still opens; its objects count as unconfirmed")
    func olderLedgerOpens() throws {
        let url = tempFolder().appending(path: "ledger.json")
        try Data(#"[{"fromSweep":false,"id":"1","name":"JTKTEST A","removed":false,"resource":"categories","target":"a.example"}]"#.utf8).write(to: url)
        let ledger = Ledger(fileURL: url)
        #expect(ledger.saveFailure == nil)
        #expect(ledger.items.first?.confirmed == false && ledger.items.first?.aliases == [])
    }
}

// MARK: - L10, L11, L14, A4

@Suite("Live check: smaller safety items")
struct LiveCheckSmallItemTests {
    @Test("The allow-list can’t be moved by a setting; only a sandboxed host’s own copy is read instead")
    func allowListIsFixed() throws {
        let missingDefault = tempFolder().appending(path: "allowlist.json")
        let run = tempFolder().appending(path: "run", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: run.appending(path: "allowlist.json"))
        #expect(LiveCheckRun.allowListURL(runFolder: run, defaultURL: missingDefault) == missingDefault, "not in a container")

        let container = tempFolder().appending(path: "Library/Containers/be.example.app/Data/tmp/JTKitReleaseCheck/XX-1",
                                               directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        #expect(LiveCheckRun.allowListURL(runFolder: container, defaultURL: missingDefault) == missingDefault, "no copy there")
        try Data("{}".utf8).write(to: container.appending(path: "allowlist.json"))
        #expect(LiveCheckRun.allowListURL(runFolder: container, defaultURL: missingDefault) == container.appending(path: "allowlist.json"))
        let readable = tempFolder().appending(path: "allowlist.json")
        try Data("{}".utf8).write(to: readable)
        #expect(LiveCheckRun.allowListURL(runFolder: container, defaultURL: readable) == readable, "the real one when it’s readable")

        let source = try String(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/JTKitLiveCheck/LiveCheckRun.swift"), encoding: .utf8)
        #expect(!source.contains("environment[\"JTKIT_LIVE_ALLOWLIST\"]"))
    }

    @Test("The live session waits longer than the longest read-back, recycle bin included")
    func timeoutsAboveTheLongestReadBack() throws {
        let standard = ReadBack.standard
        #expect(standard.longestWait > 2 * Double(standard.recycleBinAttempts) * standard.interval)
        let network = LiveCheckNetwork(policy: makePolicy(), upstream: LiveCheckNetwork.makeUpstream())
        #expect(network.session.configuration.timeoutIntervalForRequest >= standard.longestWait)
        #expect(network.session.configuration.timeoutIntervalForResource >= standard.longestWait)

        // A write with its own, shorter timeout is raised too; a read isn’t.
        let id = try #require(network.session.configuration.httpAdditionalHeaders?[LiveCheckURLProtocol.networkHeader] as? String)
        var delete = URLRequest(url: URL(string: "https://test-a.jamf.example/api/v1/categories/1")!, timeoutInterval: 30)
        delete.httpMethod = "DELETE"
        delete.setValue(id, forHTTPHeaderField: LiveCheckURLProtocol.networkHeader)
        #expect(LiveCheckURLProtocol.canonicalRequest(for: delete).timeoutInterval == standard.longestWait)
        var read = delete
        read.httpMethod = "GET"
        #expect(LiveCheckURLProtocol.canonicalRequest(for: read).timeoutInterval == 30)
    }

    @Test("Refusals in the report show no serial number or ID")
    func refusalLocationsAreMasked() async throws {
        let network = LiveCheckNetwork(policy: makePolicy(), upstream: MockServer { _ in .json(200, "{}") }.session)
        var request = URLRequest(url: URL(string: "https://api-business.apple.com/v1/orgDevices/C02XK0AAJGH5/appleCareCoverage")!)
        request.setValue("Bearer unknown", forHTTPHeaderField: "Authorization")
        await #expect(throws: (any Error).self) { _ = try await network.session.data(for: request) }
        #expect(network.refusals.first?.location == "api-business.apple.com/v1/orgDevices/{id}/appleCareCoverage")
        #expect(LiveCheckNetwork.maskedLocation(URL(string: "https://h.example/JSSResource/computergroups/id/57")!)
                == "h.example/JSSResource/computergroups/id/{id}")
        #expect(LiveCheckNetwork.maskedLocation(URL(string: "https://h.example/api/v1/oauth2/v2.0/token")!) == "h.example/api/v1/oauth2/v2.0/token")
    }

    @Test("Activation Lock bypass codes are never read", arguments: [
        "https://read.jamf.example/api/v2/mobile-devices/5/activation-lock-bypass-code",
        "https://read.jamf.example/JSSResource/computers/id/5/subset/activation_lock_bypass",
        "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/00000000-0000-4000-8000-0000000000d1?$select=activationLockBypassCode",
    ])
    func activationLockBypassIsRefused(url: String) {
        let decision = makePolicy().decide(request("GET", url, headers: ["Authorization": "Bearer \(jwt(tid: entraTest))"]))
        guard case .refuse(let reason) = decision else { Issue.record("allowed: \(url)"); return }
        #expect(reason.contains("never read"))
    }

    @Test("A Classic path by name is about its type, not a type named after the object")
    func classicByName() throws {
        #expect(LiveCheckPolicy.objectReference("/JSSResource/categories/name/Security")
                == .init(resource: "categories", id: "name:Security", isClassicCreate: true))
        let policy = makePolicy()
        let create = request("POST", "https://test-a.jamf.example/JSSResource/categories/name/x",
                             body: "<category><name>\(prefix) – C</name></category>")
        guard case .allow(let allowed) = policy.decide(create) else { Issue.record("refused"); return }
        #expect(allowed.resource == "categories")
        #expect(!policy.decide(request("POST", "https://test-a.jamf.example/JSSResource/categories/name/Security",
                                       body: "<category><name>Security</name></category>")).isAllowed)
        #expect(!policy.decide(request("DELETE", "https://test-a.jamf.example/JSSResource/categories/name/\(prefix) – C")).isAllowed,
                "a change by name never matches a ledger object")
    }

    @Test("A ledger alias finds the same object under another API’s type and ID")
    func ledgerAliases() throws {
        let url = tempFolder().appending(path: "ledger.json")
        let ledger = Ledger(fileURL: url)
        try ledger.add(created("platform:x", "device-groups", "ABC", "\(prefix) – G"), testPrefixes: [prefix])
        try ledger.addAlias(target: "platform:x", resource: "devicegroups", id: "abc", aliasResource: "computer-groups", aliasID: "57")
        #expect(ledger.contains(target: "platform:x", resource: "computergroups", id: "57"))
        #expect(!ledger.contains(target: "platform:x", resource: "mobiledevicegroups", id: "57"))
        try ledger.recordRemoval(target: "platform:x", resource: "computergroups", id: "57")
        #expect(Ledger(fileURL: url).items.first?.removed == true)
    }

    @Test("results.jsonl keeps every line whole when test processes write at once")
    func resultsAreAppended() async throws {
        let env = ["JTKIT_LIVE": "1", "JTKIT_LIVE_PREFIX": prefix, "JTKIT_LIVE_RUN_DIR": tempFolder().appending(path: "run").path,
                   "JTKIT_LIVE_ROLES": "jamf-test-a"]
        let list = tempFolder().appending(path: "allowlist.json")
        try JSONEncoder().encode(sampleList()).write(to: list)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: list.path)
        let one = try LiveCheckRun(environment: env, allowListURL: list)
        let two = try LiveCheckRun(environment: env, allowListURL: list)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask { (index % 2 == 0 ? one : two).record(step: "step \(index)", passed: true, note: String(repeating: "x", count: 500)) }
            }
        }
        let lines = try String(contentsOf: one.runFolder.appending(path: "results.jsonl"), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 200)
        #expect(lines.allSatisfy { (try? JSONDecoder().decode(LiveCheckRun.StepResult.self, from: Data($0.utf8))) != nil })
    }

    @Test("A request’s description shows its method, host and path only")
    func requestDescription() {
        let seen = request("POST", "https://test-a.jamf.example/api/oauth/token?client_id=abc",
                           headers: ["Authorization": "Bearer secret-token"], body: "client_secret=hunter2")
        #expect("\(seen)" == "POST test-a.jamf.example/api/oauth/token")
    }
}
