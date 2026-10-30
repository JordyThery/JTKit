import Foundation
import Security
import Testing
@testable import JTKitLiveCheck
import JTKitTestSupport

// Made-up tenants only: hosts under .example, IDs in an obviously fake range.
private let platformA = "00000000-0000-4000-8000-00000000000a"
private let entraTest = "00000000-0000-4000-8000-0000000000e1"
private let prefix = "JTKTEST XX 1027-1432"

private func sampleList() -> AllowList {
    AllowList(tenants: [
        .init(role: "jamf-test-a", service: .jamfPlatform, region: "eu", environmentID: platformA, access: .full, keychainService: "Test-A"),
        .init(role: "jamf-test-a", service: .jamfPro, host: "test-a.jamf.example", access: .full),
        .init(role: "jamfpro-readonly", service: .jamfPro, host: "read.jamf.example", aliases: ["read-alias.jamf.example"], access: .readOnly),
        .init(role: "jamfpro-readonly", service: .jamfPlatform, region: "us", environmentID: "00000000-0000-4000-8000-000000000001", access: .readOnly),
        .init(role: "jamfpro-production", service: .jamfPro, host: "prod.jamf.example", access: .readOnly, production: true),
        .init(role: "intune-test", service: .intune, entraTenantID: entraTest, access: .createAndRemove),
        .init(role: "apple-business", service: .appleBusinessManager, clientID: "BUSINESSAPI.test", access: .readOnly),
    ])
}

private func tempFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "LiveCheckTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makePolicy(roles: Set<String>? = nil, includeProduction: Bool = false) -> LiveCheckPolicy {
    LiveCheckPolicy(allowList: sampleList(), roles: roles, includeProduction: includeProduction,
                    prefix: prefix, ledger: Ledger(fileURL: tempFolder().appending(path: "ledger.json")))
}

private func request(_ method: String, _ url: String, headers: [String: String] = [:], json: [String: Any]? = nil, body: String? = nil) -> LiveRequest {
    let data = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data((body ?? "").utf8)
    return LiveRequest(method: method, url: URL(string: url)!, headers: headers, body: data)
}

private func jwt(tid: String) -> String {
    func encode(_ object: [String: Any]) -> String {
        (try! JSONSerialization.data(withJSONObject: object)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    return "\(encode(["alg": "none"])).\(encode(["tid": tid])).sig"
}

private extension LiveDecision {
    var kind: LiveDecision.Allowed.Kind? {
        if case .allow(let allowed) = self { return allowed.kind }
        return nil
    }
}

// MARK: Rule 1: not on the allow-list

@Suite("Live check: rule 1, allow-list only")
struct AllowListRuleTests {
    @Test func unknownHostIsRefused() {
        #expect(!makePolicy().decide(request("GET", "https://other.jamf.example/api/v1/jamf-pro-version")).isAllowed)
    }

    @Test func aliasOfAllowedHostIsAllowed() {
        #expect(makePolicy().decide(request("GET", "https://read-alias.jamf.example/api/v1/jamf-pro-version")).kind == .read)
    }

    @Test func plainHTTPIsRefused() {
        #expect(!makePolicy().decide(request("GET", "http://read.jamf.example/api/v1/jamf-pro-version")).isAllowed)
    }

    @Test func platformNeedsAnAllowedEnvironment() {
        let policy = makePolicy()
        let url = "https://eu.api.jamfcloud.com/pro/v1/categories"
        #expect(policy.decide(request("GET", url, headers: ["X-Environment-Id": platformA])).kind == .read)
        #expect(!policy.decide(request("GET", url, headers: ["X-Environment-Id": "00000000-0000-4000-8000-0000000000ff"])).isAllowed)
        #expect(!policy.decide(request("GET", url)).isAllowed, "no environment header")
        // the right environment in the wrong region
        #expect(!policy.decide(request("GET", "https://us.api.jamfcloud.com/pro/v1/categories", headers: ["X-Environment-Id": platformA])).isAllowed)
    }

    @Test func platformSignInOnlyInAnAllowedRegion() {
        let policy = makePolicy()
        #expect(policy.decide(request("POST", "https://eu.api.jamfcloud.com/auth/token", body: "grant_type=client_credentials")).kind == .signIn)
        #expect(!policy.decide(request("POST", "https://apac.api.jamfcloud.com/auth/token")).isAllowed)
    }

    @Test func rolesOutsideTheRunAreRefused() {
        let policy = makePolicy(roles: ["jamf-test-a"])
        #expect(!policy.decide(request("GET", "https://read.jamf.example/api/v1/jamf-pro-version")).isAllowed)
        #expect(policy.decide(request("GET", "https://test-a.jamf.example/api/v1/jamf-pro-version")).isAllowed)
    }

    @Test func productionOnlyWithIncludeProduction() {
        let url = "https://prod.jamf.example/api/v1/jamf-pro-version"
        #expect(!makePolicy().decide(request("GET", url)).isAllowed)
        #expect(makePolicy(includeProduction: true).decide(request("GET", url)).kind == .read)
        #expect(!makePolicy(includeProduction: true).decide(request("POST", "https://prod.jamf.example/api/v1/categories", json: ["name": "\(prefix) – C"])).isAllowed)
    }

    @Test func microsoftSignInOnlyForAnAllowedTenant() {
        let policy = makePolicy()
        #expect(policy.decide(request("POST", "https://login.microsoftonline.com/\(entraTest)/oauth2/v2.0/token")).kind == .signIn)
        #expect(!policy.decide(request("POST", "https://login.microsoftonline.com/00000000-0000-4000-8000-0000000000e9/oauth2/v2.0/token")).isAllowed)
        #expect(!policy.decide(request("GET", "https://login.microsoftonline.com/\(entraTest)/oauth2/v2.0/authorize")).isAllowed)
    }

    @Test func appleSignInOnlyForAnAllowedOrganisation() {
        let policy = makePolicy()
        #expect(policy.decide(request("POST", "https://account.apple.com/auth/oauth2/v2/token", body: "grant_type=client_credentials&client_id=BUSINESSAPI.test&scope=business.api")).kind == .signIn)
        #expect(!policy.decide(request("POST", "https://account.apple.com/auth/oauth2/v2/token", body: "client_id=BUSINESSAPI.other")).isAllowed)
    }

    @Test func appleAPINeedsATokenIssuedHere() {
        let policy = makePolicy()
        let url = "https://api-business.apple.com/v1/orgDevices"
        #expect(!policy.decide(request("GET", url, headers: ["Authorization": "Bearer unknown"])).isAllowed)
        policy.recordAppleToken("issued", clientID: "BUSINESSAPI.test")
        #expect(policy.decide(request("GET", url, headers: ["Authorization": "Bearer issued"])).kind == .read)
    }
}

// MARK: Rule 2: read-only tenants

@Suite("Live check: rule 2, read only")
struct ReadOnlyRuleTests {
    @Test(arguments: ["POST", "PUT", "PATCH", "DELETE"])
    func writesAreRefused(method: String) {
        let decision = makePolicy().decide(request(method, "https://read.jamf.example/api/v1/categories/3", json: ["name": "\(prefix) – C"]))
        #expect(!decision.isAllowed)
    }

    @Test func signInAndSignOutAreAllowed() {
        let policy = makePolicy()
        for path in ["/api/oauth/token", "/api/v1/auth/token", "/api/v1/auth/invalidate-token", "/api/v1/auth/keep-alive"] {
            #expect(policy.decide(request("POST", "https://read.jamf.example\(path)")).kind == .signIn, "\(path)")
        }
        // a path that only looks like one
        #expect(!policy.decide(request("POST", "https://read.jamf.example/api/v1/auth/token/extra")).isAllowed)
    }

    @Test func everyAppleActivityIsRefused() {
        let policy = makePolicy()
        policy.recordAppleToken("issued", clientID: "BUSINESSAPI.test")
        let auth = ["Authorization": "Bearer issued"]
        #expect(!policy.decide(request("POST", "https://api-business.apple.com/v1/orgDeviceActivities", headers: auth, json: ["data": [:]])).isAllowed)
        #expect(!policy.decide(request("GET", "https://api-business.apple.com/v1/orgDeviceActivities/abc", headers: auth)).isAllowed)
    }

    @Test func appleIsReadOnlyInTheAllowListItself() {
        let entry = AllowList.Entry(role: "x", service: .appleSchoolManager, clientID: "SCHOOLAPI.x", access: .full)
        #expect(throws: AllowList.LoadError.self) { try entry.validate() }
        let production = AllowList.Entry(role: "p", service: .jamfPro, host: "p.example", access: .full, production: true)
        #expect(throws: AllowList.LoadError.self) { try production.validate() }
    }
}

// MARK: Rule 3: prefixed creates, ledger-only changes

@Suite("Live check: rule 3, test objects only")
struct TestObjectRuleTests {
    @Test func createNeedsThePrefix() {
        let policy = makePolicy()
        let url = "https://test-a.jamf.example/api/v1/categories"
        #expect(policy.decide(request("POST", url, json: ["name": "\(prefix) – Category"])).kind == .create(name: "\(prefix) – Category"))
        #expect(!policy.decide(request("POST", url, json: ["name": "Category"])).isAllowed)
        #expect(!policy.decide(request("POST", url, json: ["name": "JTKTEST XX 0101-0000 – an earlier run"])).isAllowed)
        #expect(!policy.decide(request("POST", url, json: ["priority": 9])).isAllowed, "no name")
    }

    @Test func classicCreatesAreReadFromXML() {
        let policy = makePolicy()
        let url = "https://test-a.jamf.example/JSSResource/scripts/id/0"
        let good = "<script><name>\(prefix) – Script</name><script_contents>echo</script_contents></script>"
        #expect(policy.decide(request("POST", url, body: good)).kind == .create(name: "\(prefix) – Script"))
        #expect(!policy.decide(request("POST", url, body: "<script><name>Script</name></script>")).isAllowed)
        // through the Platform gateway
        let gateway = "https://eu.api.jamfcloud.com/proclassic/categories/id/0"
        #expect(policy.decide(request("POST", gateway, headers: ["X-Environment-Id": platformA],
                                      body: "<category><name>\(prefix) – C</name></category>")).isAllowed)
    }

    /// Profile2Blueprint's live check (0.12.2): a Classic macOS configuration
    /// profile and a static computer group through the Platform gateway.
    @Test func classicProfilesAndGroupsThroughTheGateway() throws {
        let policy = makePolicy()
        let headers = ["X-Environment-Id": platformA]
        let profiles = "https://eu.api.jamfcloud.com/proclassic/osxconfigurationprofiles"
        let good = "<os_x_configuration_profile><general><name>\(prefix) – Profile</name><payloads>&lt;plist/&gt;</payloads></general><scope><all_computers>false</all_computers></scope></os_x_configuration_profile>"
        #expect(policy.decide(request("POST", "\(profiles)/id/0", headers: headers, body: good)).kind == .create(name: "\(prefix) – Profile"))
        #expect(!policy.decide(request("POST", "\(profiles)/id/0", headers: headers,
                                       body: "<os_x_configuration_profile><general><name>Wi-Fi</name></general></os_x_configuration_profile>")).isAllowed)
        // The first <name> counts: a category named before the profile is refused.
        #expect(!policy.decide(request("POST", "\(profiles)/id/0", headers: headers,
                                       body: "<os_x_configuration_profile><category><name>Security</name></category><general><name>\(prefix) – P</name></general></os_x_configuration_profile>")).isAllowed)
        let group = "<computer_group><name>\(prefix) – Classic Group</name><is_smart>false</is_smart></computer_group>"
        #expect(policy.decide(request("POST", "https://eu.api.jamfcloud.com/proclassic/computergroups/id/0", headers: headers, body: group)).isAllowed)

        // A scope change and a delete only on this run's profile.
        let scope = "<os_x_configuration_profile><scope><computer_groups/></scope></os_x_configuration_profile>"
        #expect(!policy.decide(request("PUT", "\(profiles)/id/21", headers: headers, body: scope)).isAllowed)
        try policy.ledger.add(.init(target: "platform:\(platformA)", resource: "osxconfigurationprofiles", id: "21", name: "\(prefix) – Profile"),
                              testPrefixes: [prefix])
        #expect(policy.decide(request("PUT", "\(profiles)/id/21", headers: headers, body: scope)).kind == .change)
        #expect(policy.decide(request("DELETE", "\(profiles)/id/21", headers: headers)).kind == .delete)
        #expect(!policy.decide(request("PUT", "\(profiles)/id/22", headers: headers, body: scope)).isAllowed)
    }

    @Test func graphCreatesUseDisplayName() {
        let policy = makePolicy()
        let auth = ["Authorization": "Bearer \(jwt(tid: entraTest))"]
        let url = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations"
        #expect(policy.decide(request("POST", url, headers: auth, json: ["displayName": "\(prefix) – Wi-Fi"])).isAllowed)
        #expect(!policy.decide(request("POST", url, headers: auth, json: ["displayName": "Wi-Fi"])).isAllowed)
    }

    @Test(arguments: ["PUT", "PATCH", "DELETE"])
    func changesNeedTheLedger(method: String) throws {
        let policy = makePolicy()
        let url = "https://test-a.jamf.example/api/v1/categories/12"
        #expect(!policy.decide(request(method, url, json: ["name": "\(prefix) – C"])).isAllowed)
        try policy.ledger.add(.init(target: "test-a.jamf.example", resource: "categories", id: "12", name: "\(prefix) – C"), testPrefixes: [prefix])
        #expect(policy.decide(request(method, url, json: ["name": "\(prefix) – C"])).isAllowed)
        // another object of the same type stays off-limits
        #expect(!policy.decide(request(method, "https://test-a.jamf.example/api/v1/categories/13")).isAllowed)
    }

    @Test func theSameObjectThroughClassicOrTheGatewayIsInTheLedger() throws {
        let policy = makePolicy()
        try policy.ledger.add(.init(target: "platform:\(platformA)", resource: "computer-groups", id: "4", name: "\(prefix) – G"), testPrefixes: [prefix])
        let headers = ["X-Environment-Id": platformA]
        #expect(policy.decide(request("DELETE", "https://eu.api.jamfcloud.com/proclassic/computergroups/id/4", headers: headers)).kind == .delete)
        #expect(policy.decide(request("PUT", "https://eu.api.jamfcloud.com/pro/v1/computer-groups/4", headers: headers)).kind == .change)
    }

    @Test func actionsOnAnObjectNeedTheLedger() throws {
        let policy = makePolicy()
        let id = "00000000-0000-4000-8000-0000000000b1"
        let headers = ["X-Environment-Id": platformA]
        let deploy = "https://eu.api.jamfcloud.com/blueprints/v1/blueprints/\(id)/deploy"
        #expect(!policy.decide(request("POST", deploy, headers: headers)).isAllowed)
        try policy.ledger.add(.init(target: "platform:\(platformA)", resource: "blueprints", id: id, name: "\(prefix) – B"), testPrefixes: [prefix])
        #expect(policy.decide(request("POST", deploy, headers: headers)).kind == .change)
    }

    @Test func tenantWideSettingsAreRefused() {
        let policy = makePolicy()
        #expect(!policy.decide(request("PUT", "https://test-a.jamf.example/api/v1/self-service/settings", json: ["name": "\(prefix)"])).isAllowed)
        #expect(!policy.decide(request("PATCH", "https://test-a.jamf.example/api/v2/check-in")).isAllowed)
    }

    @Test(arguments: [
        "https://test-a.jamf.example/api/v2/mdm/commands",
        "https://test-a.jamf.example/api/v1/jamf-management-framework/redeploy/5",
        "https://test-a.jamf.example/JSSResource/computercommands/command/DeviceLock/id/5",
        "https://test-a.jamf.example/JSSResource/mobiledevicecommands/command/RestartDevice/id/5",
    ])
    func deviceCommandsAreRefused(url: String) {
        #expect(!makePolicy().decide(request("POST", url, json: ["name": "\(prefix) – C"])).isAllowed)
    }

    /// A device record the run created may have its asset tag changed and be
    /// deleted, but no device action is ever sent to it.
    @Test(arguments: [
        "https://test-a.jamf.example/api/v2/mobile-devices/5/erase",
        "https://test-a.jamf.example/api/v2/mobile-devices/5/unmanage",
        "https://test-a.jamf.example/api/v4/computers-inventory/5/erase",
        "https://test-a.jamf.example/api/v4/computers-inventory/5/remove-mdm-profile",
    ])
    func deviceActionsOnALedgerDeviceAreRefused(url: String) throws {
        let policy = makePolicy()
        for resource in ["mobiledevices", "computersinventory"] {
            try policy.ledger.add(.init(target: "test-a.jamf.example", resource: resource, id: "5", name: "\(prefix) – iPad"),
                                  testPrefixes: [prefix])
        }
        #expect(!policy.decide(request("POST", url)).isAllowed)
        #expect(policy.decide(request("PATCH", "https://test-a.jamf.example/api/v2/mobile-devices/5", json: ["assetTag": "x"])).kind == .change)
        #expect(policy.decide(request("DELETE", "https://test-a.jamf.example/JSSResource/mobiledevices/id/5")).kind == .delete)
    }

    @Test func platformDeviceActionsAreRefused() throws {
        let policy = makePolicy()
        let id = "00000000-0000-4000-8000-0000000000c5"
        try policy.ledger.add(.init(target: "platform:\(platformA)", resource: "devices", id: id, name: "\(prefix) – iPad"),
                              testPrefixes: [prefix])
        let url = "https://eu.api.jamfcloud.com/device-actions/v1/devices/\(id)/restart"
        #expect(!policy.decide(request("POST", url, headers: ["X-Environment-Id": platformA])).isAllowed)
    }

    @Test func graphDeviceActionsAreRefused() {
        let auth = ["Authorization": "Bearer \(jwt(tid: entraTest))"]
        let url = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/00000000-0000-4000-8000-0000000000d1/retire"
        #expect(!makePolicy().decide(request("POST", url, headers: auth)).isAllowed)
    }

    /// Named in 0.12.4: refused also on a device record the run created.
    @Test(arguments: [
        ("POST", "https://test-a.jamf.example/api/v2/mdm/blank-push"),
        ("POST", "https://test-a.jamf.example/api/v1/mdm/renew-profile"),
        ("POST", "https://test-a.jamf.example/api/v1/ddm/5/sync"),
    ])
    func moreJamfProCommandsAreRefused(method: String, url: String) throws {
        let policy = makePolicy()
        try policy.ledger.add(.init(target: "test-a.jamf.example", resource: "ddm", id: "5", name: "\(prefix) – iPad"), testPrefixes: [prefix])
        let decision = policy.decide(request(method, url, json: ["name": "\(prefix) – C", "clientManagementIds": ["5"]]))
        #expect(decision == .refuse("Device commands are never sent in a live check"))
    }

    @Test func graphDeleteOrChangeOfAManagedDeviceIsRefused() throws {
        let policy = makePolicy()
        let id = "00000000-0000-4000-8000-0000000000d1"
        try policy.ledger.add(.init(target: "intune:\(entraTest)", resource: "manageddevices", id: id, name: "\(prefix) – Mac"),
                              testPrefixes: [prefix])
        let auth = ["Authorization": "Bearer \(jwt(tid: entraTest))"]
        let url = "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices/\(id)"
        #expect(policy.decide(request("DELETE", url, headers: auth)) == .refuse("Device commands are never sent in a live check"))
        #expect(policy.decide(request("PATCH", url, headers: auth, json: ["notes": "x"])) == .refuse("Device commands are never sent in a live check"))
        #expect(policy.decide(request("GET", url, headers: auth)).kind == .read)
    }

    @Test(arguments: ["refresh", "restart", "wipe", "unenroll"])
    func jamfSchoolCommandsAreNamed(action: String) {
        #expect(LiveCheckPolicy.isDeviceCommand("/api/devices/00008030-001a2b3c4d5e6f70/\(action)", method: "POST"))
        #expect(LiveCheckPolicy.isDeviceCommand("/api/devices/c02aaa/\(action)", method: "POST"))
        #expect(!LiveCheckPolicy.isDeviceCommand("/api/devices/c02aaa/details", method: "POST"))
    }
}

// MARK: Secrets (0.12.4)

@Suite("Live check: device secrets are never read")
struct SecretReadRuleTests {
    @Test(arguments: [
        "https://read.jamf.example/api/v4/computers-inventory/5/filevault",
        "https://read.jamf.example/api/v1/computers-inventory/filevault",
        "https://test-a.jamf.example/api/v4/computers-inventory/5/view-recovery-lock-password",
        "https://test-a.jamf.example/api/v4/computers-inventory/5/view-device-lock-pin",
        "https://test-a.jamf.example/api/v2/local-admin-password/00000000-0000-4000-8000-0000000000c1/account/admin/password",
        "https://test-a.jamf.example/api/v2/local-admin-password/00000000-0000-4000-8000-0000000000c1/account/admin/00000000-0000-4000-8000-0000000000c2/password",
    ])
    func secretReadsAreRefusedOnEveryTenant(url: String) throws {
        let policy = makePolicy()
        try policy.ledger.add(.init(target: "test-a.jamf.example", resource: "computersinventory", id: "5", name: "\(prefix) – Mac"),
                              testPrefixes: [prefix])
        let decision = policy.decide(request("GET", url))
        #expect(!decision.isAllowed)
        if case .refuse(let reason) = decision { #expect(reason.contains("never read")) }
    }

    @Test func graphSecretsAreRefused() {
        let auth = ["Authorization": "Bearer \(jwt(tid: entraTest))"]
        for path in ["deviceManagement/managedDevices/00000000-0000-4000-8000-0000000000d1/getFileVaultKey",
                     "informationProtection/bitlocker/recoveryKeys/00000000-0000-4000-8000-0000000000d2",
                     "directory/deviceLocalCredentials/00000000-0000-4000-8000-0000000000d3"] {
            #expect(!makePolicy().decide(request("GET", "https://graph.microsoft.com/v1.0/\(path)", headers: auth)).isAllowed)
        }
    }

    @Test func lapsSettingsAndAccountsStayReadable() {
        let policy = makePolicy()
        #expect(policy.decide(request("GET", "https://read.jamf.example/api/v2/local-admin-password/settings")).kind == .read)
        #expect(policy.decide(request("GET", "https://read.jamf.example/api/v2/local-admin-password/00000000-0000-4000-8000-0000000000c1/accounts")).kind == .read)
        #expect(policy.decide(request("GET", "https://read.jamf.example/api/v4/computers-inventory/5?section=FILEVAULT")).kind == .read)
    }
}

// MARK: Apple budget (0.12.4)

@Suite("Live check: Apple request budget")
struct AppleBudgetTests {
    @Test func pacesPerMinuteAndCapsPerRun() {
        let budget = AppleRequestBudget(perMinute: 2, perRun: 3, window: 60)
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(budget.claim(role: "apple-business", now: start) == .go)
        #expect(budget.claim(role: "apple-business", now: start.addingTimeInterval(1)) == .go)
        // The third waits until the first has left the minute.
        #expect(budget.claim(role: "apple-business", now: start.addingTimeInterval(2)) == .wait(58))
        // Another organisation has its own budget.
        #expect(budget.claim(role: "apple-school", now: start.addingTimeInterval(2)) == .go)
        #expect(budget.claim(role: "apple-business", now: start.addingTimeInterval(61)) == .go)
        guard case .refuse(let reason) = budget.claim(role: "apple-business", now: start.addingTimeInterval(500)) else {
            Issue.record("the fourth request of the run wasn't refused"); return
        }
        #expect(reason.contains("3 requests"))
    }

    @Test func theRunsFileIsSharedByItsProcesses() {
        let file = tempFolder().appending(path: "apple-requests.jsonl")
        let first = AppleRequestBudget(perMinute: 9, perRun: 2, file: file)
        let second = AppleRequestBudget(perMinute: 9, perRun: 2, file: file)
        #expect(first.claim(role: "apple-business") == .go)
        #expect(second.claim(role: "apple-business") == .go)
        guard case .refuse = first.claim(role: "apple-business") else { Issue.record("the shared cap wasn't kept"); return }
        #expect(AppleRequestBudget.counts(in: file) == ["apple-business": 2])
        #expect(!((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("BUSINESSAPI"))
    }

    @Test func theNetworkWaitsAndRefusesBeyondTheCap() async throws {
        let server = MockServer { request in
            request.url.host() == "account.apple.com" ? .json(200, #"{"access_token":"tok","expires_in":3600}"#) : .json(200, #"{"data":[]}"#)
        }
        let network = LiveCheckNetwork(policy: makePolicy(), upstream: server.session,
                                       appleBudget: AppleRequestBudget(perMinute: 2, perRun: 3, window: 0.5))
        var signIn = URLRequest(url: URL(string: "https://account.apple.com/auth/oauth2/v2/token")!)
        signIn.httpMethod = "POST"
        signIn.httpBody = Data("grant_type=client_credentials&client_id=BUSINESSAPI.test".utf8)
        _ = try await network.session.data(for: signIn)
        var devices = URLRequest(url: URL(string: "https://api-business.apple.com/v1/orgDevices")!)
        devices.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
        let started = Date()
        _ = try await network.session.data(for: devices)
        _ = try await network.session.data(for: devices)   // the third in half a second: waits
        #expect(Date().timeIntervalSince(started) >= 0.3)
        await #expect(throws: (any Error).self) { _ = try await network.session.data(for: devices) }
        #expect(server.requests.count == 3)
        #expect(network.refusals.first?.reason.contains("budget") == true)
    }
}

// MARK: Graph writes (0.12.5)

@Suite("Live check: Graph writes")
struct GraphWriteRuleTests {
    private let bearer = ["Authorization": "Bearer \(jwt(tid: entraTest))"]
    private let target = "intune:\(entraTest)"
    private let group = "11111111-2222-4333-8444-555555555555"
    private let filter = "66666666-2222-4333-8444-555555555555"
    private let script = "77777777-2222-4333-8444-555555555555"

    private func policyWithObjects() throws -> LiveCheckPolicy {
        let policy = makePolicy()
        try policy.ledger.add(.init(target: target, resource: "groups", id: group, name: "\(prefix) – Group"), testPrefixes: [prefix])
        try policy.ledger.add(.init(target: target, resource: "assignmentFilters", id: filter, name: "\(prefix) – Filter"), testPrefixes: [prefix])
        try policy.ledger.add(.init(target: target, resource: "deviceShellScripts", id: script, name: "\(prefix) – Script"), testPrefixes: [prefix])
        return policy
    }

    private func assign(_ targets: [[String: Any]]) -> LiveRequest {
        request("POST", "https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts/\(script)/assign", headers: bearer,
                json: ["deviceManagementScriptAssignments": targets.map { ["target": $0] }])
    }

    @Test("Each Intune object type's create is read by its name or displayName")
    func createsOfEachType() {
        let policy = makePolicy()
        let creates: [(String, [String: Any])] = [
            ("beta/deviceManagement/assignmentFilters", ["displayName": "\(prefix) – F", "rule": "(device.osVersion -startsWith \"15\")"]),
            ("beta/deviceManagement/deviceShellScripts", ["displayName": "\(prefix) – S", "scriptContent": "ZWNobw=="]),
            ("beta/deviceManagement/deviceCustomAttributeShellScripts", ["displayName": "\(prefix) – A", "customAttributeName": "a"]),
            ("beta/deviceManagement/configurationPolicies", ["name": "\(prefix) – C", "settings": [] as [Any]]),
            ("v1.0/deviceManagement/deviceCompliancePolicies", ["displayName": "\(prefix) – P",
                "scheduledActionsForRule": [["ruleName": "PasswordRequired",
                    "scheduledActionConfigurations": [["actionType": "block", "gracePeriodHours": 0]]]]]),
            ("v1.0/groups", ["displayName": "\(prefix) – G", "securityEnabled": true, "mailEnabled": false]),
        ]
        for (path, body) in creates {
            let decision = policy.decide(request("POST", "https://graph.microsoft.com/\(path)", headers: bearer, json: body))
            #expect(decision.isAllowed, "\(path): \(decision)")
        }
        #expect(!policy.decide(request("POST", "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies",
                                       headers: bearer, json: ["name": "Contoso – Baseline"])).isAllowed)
    }

    @Test("Assignments only to a group (and filter) this run created")
    func assignmentsOnlyToTheRunsGroup() throws {
        let policy = try policyWithObjects()
        let toGroup: [String: Any] = ["@odata.type": "#microsoft.graph.groupAssignmentTarget", "groupId": group.uppercased()]
        #expect(policy.decide(assign([toGroup])).kind == .change)
        #expect(policy.decide(assign([["@odata.type": "#microsoft.graph.exclusionGroupAssignmentTarget", "groupId": group]])).kind == .change)
        #expect(policy.decide(assign([toGroup.merging(["deviceAndAppManagementAssignmentFilterId": filter,
                                                       "deviceAndAppManagementAssignmentFilterType": "include"]) { $1 }])).kind == .change)
        #expect(policy.decide(assign([])).kind == .change, "removing every assignment is allowed")
    }

    @Test("All devices, All users, other groups and other filters are refused", arguments: [
        ["@odata.type": "#microsoft.graph.allDevicesAssignmentTarget"],
        ["@odata.type": "#microsoft.graph.allLicensedUsersAssignmentTarget"],
        ["@odata.type": "#microsoft.graph.groupAssignmentTarget", "groupId": "99999999-2222-4333-8444-555555555555"],
        ["@odata.type": "#microsoft.graph.groupAssignmentTarget"],
        ["@odata.type": "#microsoft.graph.configurationManagerCollectionAssignmentTarget", "collectionId": "x"],
        ["groupId": "11111111-2222-4333-8444-555555555555"],
    ] as [[String: String]])
    func otherTargetsAreRefused(target: [String: String]) throws {
        let policy = try policyWithObjects()
        guard case .refuse(let reason) = policy.decide(assign([target])) else {
            Issue.record("allowed: \(target)")
            return
        }
        #expect(reason.contains("assignment") || reason.contains("Assignment"))
    }

    @Test("Refused also next to an allowed target, and with a filter the run didn't create")
    func mixedTargetsAreRefused() throws {
        let policy = try policyWithObjects()
        let toGroup: [String: Any] = ["@odata.type": "#microsoft.graph.groupAssignmentTarget", "groupId": group]
        #expect(!policy.decide(assign([toGroup, ["@odata.type": "#microsoft.graph.allDevicesAssignmentTarget"]])).isAllowed)
        #expect(!policy.decide(assign([toGroup.merging(["deviceAndAppManagementAssignmentFilterId": "99999999-2222-4333-8444-555555555555"]) { $1 }])).isAllowed)
        // A group an earlier run left (merged into the ledger as found) isn't this run's group.
        try policy.ledger.add(.init(target: target, resource: "groups", id: "88888888-2222-4333-8444-555555555555",
                                    name: "JTKTEST ID 0101-0000 – Group", fromSweep: true), testPrefixes: ["JTKTEST "])
        #expect(!policy.decide(assign([["@odata.type": "#microsoft.graph.groupAssignmentTarget",
                                        "groupId": "88888888-2222-4333-8444-555555555555"]])).isAllowed)
    }

    @Test("Compliance actions other than block are refused", arguments: ["retire", "wipe", "remoteLock", "notification", "pushNotification"])
    func complianceActionsOnlyBlock(action: String) throws {
        let policy = try policyWithObjects()
        let create = request("POST", "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies", headers: bearer,
                             json: ["displayName": "\(prefix) – P", "scheduledActionsForRule": [["ruleName": "PasswordRequired",
                                 "scheduledActionConfigurations": [["actionType": "block"], ["actionType": action]]]]])
        #expect(!policy.decide(create).isAllowed)
    }

    @Test("Graph $batch is refused")
    func batchIsRefused() {
        let decision = makePolicy().decide(request("POST", "https://graph.microsoft.com/v1.0/$batch", headers: bearer,
                                                   json: ["requests": [] as [Any]]))
        guard case .refuse(let reason) = decision else { Issue.record("allowed"); return }
        #expect(reason.contains("$batch"))
    }

    @Test("A permanent delete from deleted items only for a group this run created and removed")
    func permanentDeleteOnlyOfTheRunsRemovedGroup() throws {
        let policy = try policyWithObjects()
        let purge = request("DELETE", "https://graph.microsoft.com/v1.0/directory/deletedItems/\(group)", headers: bearer)
        #expect(!policy.decide(purge).isAllowed, "not deleted yet")
        policy.ledger.markRemoved(target: target, resource: "groups", id: group)
        #expect(policy.decide(purge).kind == .delete)
        #expect(!policy.decide(request("DELETE", "https://graph.microsoft.com/v1.0/directory/deletedItems/\(script)", headers: bearer)).isAllowed,
                "not a group")
        #expect(!policy.decide(request("DELETE", "https://graph.microsoft.com/v1.0/directory/deletedItems/99999999-2222-4333-8444-555555555555",
                                       headers: bearer)).isAllowed)
        #expect(!policy.decide(request("POST", "https://graph.microsoft.com/v1.0/directory/deletedItems/\(group)/restore",
                                       headers: bearer)).isAllowed)
        // An earlier run's group (merged as found) is removed, never purged.
        let earlier = "88888888-2222-4333-8444-555555555555"
        try policy.ledger.add(.init(target: target, resource: "groups", id: earlier, name: "JTKTEST ID 0101-0000 – Group",
                                    removed: true, fromSweep: true), testPrefixes: ["JTKTEST "])
        #expect(!policy.decide(request("DELETE", "https://graph.microsoft.com/v1.0/directory/deletedItems/\(earlier)", headers: bearer)).isAllowed)
    }
}

// MARK: Rule 4: Graph token tenant

@Suite("Live check: rule 4, Graph token tenant")
struct GraphTenantRuleTests {
    @Test func tokenTenantMustBeAllowed() {
        let policy = makePolicy()
        let url = "https://graph.microsoft.com/v1.0/organization"
        #expect(policy.decide(request("GET", url, headers: ["Authorization": "Bearer \(jwt(tid: entraTest))"])).kind == .read)
        #expect(!policy.decide(request("GET", url, headers: ["Authorization": "Bearer \(jwt(tid: "00000000-0000-4000-8000-0000000000e9"))"])).isAllowed)
        #expect(!policy.decide(request("GET", url, headers: ["Authorization": "Bearer opaque"])).isAllowed)
        #expect(!policy.decide(request("GET", url)).isAllowed)
    }
}

// MARK: Allow-list file, ledger, network

@Suite("Live check: the allow-list file")
struct AllowListFileTests {
    private func write(_ list: AllowList, mode: Int, in folder: URL = tempFolder()) throws -> URL {
        let url = folder.appending(path: "allowlist.json")
        try JSONEncoder().encode(list).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    @Test func loadsAPrivateFile() throws {
        let url = try write(sampleList(), mode: 0o600)
        #expect(try AllowList.load(from: url) == sampleList())
    }

    @Test func refusesAFileOthersCanRead() throws {
        let url = try write(sampleList(), mode: 0o644)
        #expect(throws: AllowList.LoadError.readableByOthers(url.path)) { try AllowList.load(from: url) }
    }

    @Test func refusesAFileInsideAGitWorkTree() throws {
        let repo = tempFolder()
        try FileManager.default.createDirectory(at: repo.appending(path: ".git"), withIntermediateDirectories: true)
        let folder = repo.appending(path: "config")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = try write(sampleList(), mode: 0o600, in: folder)
        #expect(throws: AllowList.LoadError.insideGitWorkTree(url.path)) { try AllowList.load(from: url) }
    }

    @Test func refusesAMissingFileAndIncompleteEntries() throws {
        let missing = tempFolder().appending(path: "allowlist.json")
        #expect(throws: AllowList.LoadError.missing(missing.path)) { try AllowList.load(from: missing) }
        let incomplete = AllowList(tenants: [.init(role: "x", service: .jamfPlatform, region: "eu", access: .full)])
        let url = try write(incomplete, mode: 0o600)
        #expect(throws: AllowList.LoadError.self) { try AllowList.load(from: url) }
    }
}

@Suite("Live check: ledger")
struct LedgerTests {
    @Test func survivesARestartAndOnlyTakesTestObjects() throws {
        let url = tempFolder().appending(path: "ledger.json")
        let ledger = Ledger(fileURL: url)
        try ledger.add(.init(target: "a.example", resource: "categories", id: "1", name: "\(prefix) – A"), testPrefixes: [prefix])
        try ledger.add(.init(target: "a.example", resource: "scripts", id: "2", name: "\(prefix) – B"), testPrefixes: [prefix])
        #expect(throws: Ledger.LedgerError.self) {
            try ledger.add(.init(target: "a.example", resource: "scripts", id: "3", name: "Real script"), testPrefixes: [prefix])
        }
        ledger.markRemoved(target: "a.example", resource: "categories", id: "1")

        let reopened = Ledger(fileURL: url)
        #expect(reopened.items.count == 2)
        #expect(reopened.outstanding.map(\.id) == ["2"])
    }
}

@Suite("Live check: network")
struct LiveCheckNetworkTests {
    @Test func refusedRequestsNeverReachTheServer() async throws {
        let server = MockServer { _ in .json(200, "{}") }
        let network = LiveCheckNetwork(policy: makePolicy(), upstream: server.session)
        var request = URLRequest(url: URL(string: "https://read.jamf.example/api/v1/categories")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"name":"JTKTEST XX 1027-1432 – C"}"#.utf8)
        await #expect(throws: (any Error).self) { _ = try await network.session.data(for: request) }
        #expect(server.requests.isEmpty)
        #expect(network.refusals.count == 1)
        #expect(network.refusals.first?.location == "read.jamf.example/api/v1/categories")
    }

    @Test func createsAreWrittenToTheLedgerAndDeletesMarked() async throws {
        let server = MockServer { request in
            request.method == "POST" ? .json(201, #"{"id":"41","href":"x"}"#) : .json(204, "")
        }
        let policy = makePolicy()
        let network = LiveCheckNetwork(policy: policy, upstream: server.session)
        var create = URLRequest(url: URL(string: "https://test-a.jamf.example/api/v1/categories")!)
        create.httpMethod = "POST"
        create.httpBody = Data(#"{"name":"JTKTEST XX 1027-1432 – C"}"#.utf8)
        _ = try await network.session.data(for: create)
        #expect(policy.ledger.outstanding.map(\.id) == ["41"])

        var delete = URLRequest(url: URL(string: "https://test-a.jamf.example/api/v1/categories/41")!)
        delete.httpMethod = "DELETE"
        _ = try await network.session.data(for: delete)
        #expect(policy.ledger.outstanding.isEmpty)
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.header(LiveCheckURLProtocol.networkHeader) == nil })
    }

    @Test func appleTokensIssuedHereOpenTheAPI() async throws {
        let server = MockServer { request in
            request.url.host() == "account.apple.com" ? .json(200, #"{"access_token":"tok","expires_in":3600}"#) : .json(200, #"{"data":[]}"#)
        }
        let network = LiveCheckNetwork(policy: makePolicy(), upstream: server.session)
        var signIn = URLRequest(url: URL(string: "https://account.apple.com/auth/oauth2/v2/token")!)
        signIn.httpMethod = "POST"
        signIn.httpBody = Data("grant_type=client_credentials&client_id=BUSINESSAPI.test".utf8)
        _ = try await network.session.data(for: signIn)
        var devices = URLRequest(url: URL(string: "https://api-business.apple.com/v1/orgDevices")!)
        devices.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
        let (_, response) = try await network.session.data(for: devices)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}

@Suite("Live check: run")
struct LiveCheckRunTests {
    private func environment(roles: String = "jamf-test-a,intune-test") throws -> [String: String] {
        let folder = tempFolder()
        let list = folder.appending(path: "allowlist.json")
        try JSONEncoder().encode(sampleList()).write(to: list)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: list.path)
        return ["JTKIT_LIVE": "1", "JTKIT_LIVE_PREFIX": prefix, "JTKIT_LIVE_RUN_DIR": folder.appending(path: "run").path,
                "JTKIT_LIVE_ROLES": roles, "JTKIT_LIVE_ALLOWLIST": list.path,
                "JTKIT_LIVE_JAMF_TEST_A_CLIENT_ID": "id-a", "JTKIT_LIVE_LEGACY_PREFIXES": "UIT - ", "JTKIT_LIVE_WRITES": "1"]
    }

    @Test("READ_ONLY_ROLES makes a role read only for the run, and only roles of the run")
    func readOnlyRoles() throws {
        var env = try environment()
        let createGroup = request("POST", "https://graph.microsoft.com/v1.0/groups",
                                  headers: ["Authorization": "Bearer \(jwt(tid: entraTest))"], json: ["displayName": "\(prefix) – G"])
        #expect(try LiveCheckRun(environment: env).policy.decide(createGroup).kind == .create(name: "\(prefix) – G"))

        env["JTKIT_LIVE_READ_ONLY_ROLES"] = "intune-test"
        let run = try LiveCheckRun(environment: env)
        #expect(run.readOnlyRoles == ["intune-test"])
        #expect(try run.entry(role: "intune-test", service: .intune).access == .readOnly)
        #expect(!run.policy.decide(createGroup).isAllowed)
        #expect(run.policy.decide(request("GET", "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices",
                                          headers: ["Authorization": "Bearer \(jwt(tid: entraTest))"])).kind == .read)
        // The other roles keep their access.
        #expect(run.policy.decide(request("POST", "https://test-a.jamf.example/api/v1/categories", json: ["name": "\(prefix) – C"])).isAllowed)

        env["JTKIT_LIVE_READ_ONLY_ROLES"] = "jamfpro-readonly"
        #expect(throws: LiveCheckRun.RunError.self) { try LiveCheckRun(environment: env) }
    }

    @Test func offUnlessTheReleaseCheckSwitchesItOn() throws {
        var env = try environment()
        env["JTKIT_LIVE"] = nil
        #expect(throws: LiveCheckRun.RunError.self) { try LiveCheckRun(environment: env) }
    }

    @Test func refusesRolesNotOnTheAllowList() throws {
        #expect(throws: LiveCheckRun.RunError.self) { try LiveCheckRun(environment: try environment(roles: "jamf-test-a,customer")) }
    }

    @Test func prefixMustBeATestPrefix() throws {
        var env = try environment()
        env["JTKIT_LIVE_PREFIX"] = "JD - "
        #expect(throws: LiveCheckRun.RunError.self) { try LiveCheckRun(environment: env) }
        #expect(LiveCheckRun.makePrefix(appCode: "JD", date: Date(timeIntervalSince1970: 0)).hasPrefix("JTKTEST JD "))
    }

    @Test func credentialsComeFromTheEnvironment() throws {
        let run = try LiveCheckRun(environment: try environment())
        #expect(try run.credential("jamf-test-a", "client-id") == "id-a")
        #expect(throws: LiveCheckRun.RunError.self) { try run.credential("jamf-test-a", "client-secret") }
        #expect(LiveCheckRun.variable(role: "jamf-test-a", item: "client-secret") == "JTKIT_LIVE_JAMF_TEST_A_CLIENT_SECRET")
    }

    @Test func noFaultUnlessTheScriptAsksForOne() throws {
        let normal = try LiveCheckRun(environment: try environment())
        #expect(normal.fault == nil)
        try normal.injectFault("fail-live-step", at: "after create")   // does nothing

        var env = try environment()
        env["JTKIT_LIVE_FAULT"] = "fail-live-step"
        let faulty = try LiveCheckRun(environment: env)
        try faulty.injectFault("interrupt-live", at: "elsewhere")       // another fault: nothing
        #expect(throws: LiveCheckRun.RunError.self) { try faulty.injectFault("fail-live-step", at: "after create") }
        let results = try String(contentsOf: faulty.runFolder.appending(path: "results.jsonl"), encoding: .utf8)
        #expect(results.contains("injected on purpose"))
    }

    @Test func withoutWritesEveryTenantIsReadOnly() throws {
        var env = try environment()
        env["JTKIT_LIVE_WRITES"] = nil
        let run = try LiveCheckRun(environment: env)
        #expect(run.policy.decide(request("GET", "https://test-a.jamf.example/api/v1/categories")).kind == .read)
        #expect(run.policy.decide(request("POST", "https://test-a.jamf.example/api/v1/auth/token")).kind == .signIn)
        #expect(!run.policy.decide(request("POST", "https://test-a.jamf.example/api/v1/categories", json: ["name": "\(prefix) – C"])).isAllowed)
        #expect(throws: LiveCheckRun.RunError.self) {
            try run.requireEngineTarget(role: "jamf-test-a", service: .jamfPro, host: "test-a.jamf.example")
        }
    }

    @Test func engineOnlyOnFullTenantsOfTheRun() throws {
        let run = try LiveCheckRun(environment: try environment())
        try run.requireEngineTarget(role: "jamf-test-a", service: .jamfPlatform, region: "eu", environmentID: platformA)
        try run.requireEngineTarget(role: "jamf-test-a", service: .jamfPro, host: "test-a.jamf.example")
        #expect(throws: LiveCheckRun.RunError.self) {
            try run.requireEngineTarget(role: "jamf-test-a", service: .jamfPlatform, environmentID: "00000000-0000-4000-8000-0000000000ff")
        }
        #expect(throws: LiveCheckRun.RunError.self) { try run.requireEngineTarget(role: "intune-test", service: .intune) }
        #expect(throws: LiveCheckRun.RunError.self) { try run.requireEngineTarget(role: "jamfpro-readonly", service: .jamfPro) }
    }

    @Test func sweepOnlyOnFullTenantsAndOnlyTestNames() throws {
        let run = try LiveCheckRun(environment: try environment())
        try run.adoptForSweep(role: "jamf-test-a", service: .jamfPro, resource: "categories", id: "7", name: "UIT - Security")
        try run.adoptForSweep(role: "jamf-test-a", service: .jamfPro, resource: "categories", id: "8", name: "JTKTEST JD 0101-0000 – Old")
        #expect(throws: Ledger.LedgerError.self) {
            try run.adoptForSweep(role: "jamf-test-a", service: .jamfPro, resource: "categories", id: "9", name: "Security")
        }
        #expect(throws: LiveCheckRun.RunError.self) {
            try run.adoptForSweep(role: "intune-test", service: .intune, resource: "groups", id: "x", name: "JTKTEST X")
        }
        #expect(throws: LiveCheckRun.RunError.self) {
            try run.adoptForSweep(role: "intune-test", service: .intune, resource: "groups", id: "y", name: "Security")
        }
        // adopted objects may now be deleted
        let decision = run.policy.decide(request("DELETE", "https://test-a.jamf.example/api/v1/categories/7"))
        #expect(decision.kind == .delete)
    }

    @Test("Create-and-remove tenants: only legacy test objects are swept, and only while legacy prefixes are passed (0.12.5)")
    func legacySweepOnCreateAndRemove() throws {
        var env = try environment()
        env["JTKIT_LIVE_LEGACY_PREFIXES"] = "[AUTOTEST]|UIT - "
        let run = try LiveCheckRun(environment: env)
        #expect(run.isLegacyTestObject("[AUTOTEST] macOS – Script"))
        #expect(!run.isLegacyTestObject("JTKTEST ID 0101-0000 – Script"))
        try run.adoptForSweep(role: "intune-test", service: .intune, resource: "deviceShellScripts",
                              id: "12345678-2222-4333-8444-555555555555", name: "[AUTOTEST] macOS – Script")
        #expect(run.policy.decide(request("DELETE", "https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts/12345678-2222-4333-8444-555555555555",
                                          headers: ["Authorization": "Bearer \(jwt(tid: entraTest))"])).kind == .delete)
        #expect(throws: LiveCheckRun.RunError.self) {
            try run.adoptForSweep(role: "intune-test", service: .intune, resource: "groups", id: "z", name: "JTKTEST ID 0101-0000 – Group")
        }
        env["JTKIT_LIVE_LEGACY_PREFIXES"] = nil
        let later = try LiveCheckRun(environment: env)
        #expect(throws: LiveCheckRun.RunError.self) {
            try later.adoptForSweep(role: "intune-test", service: .intune, resource: "deviceShellScripts", id: "w", name: "[AUTOTEST] macOS – Script")
        }
    }

    @Test("The test host's Keychain names are written as hashes only (0.12.5)")
    func hostKeychainNamesAreHashes() throws {
        let run = try LiveCheckRun(environment: try environment())
        let service = "JTKitLiveCheckTests-\(UUID().uuidString)"
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: "account-one", kSecValueData as String: Data("not-read".utf8)]
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return }   // no Keychain here: nothing to check
        defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
        let lines = try run.recordHostKeychainNames(services: [service], label: "before")
        #expect(lines.count == 1)
        let written = try String(contentsOf: run.runFolder.appending(path: "host-keychain.before"), encoding: .utf8)
        #expect(!written.contains("account-one") && !written.contains(service) && !written.contains("not-read"))
        #expect(written.hasPrefix("keychain-host ") && written.count == "keychain-host ".count + 16 + 1)
        #expect(throws: LiveCheckRun.RunError.self) { try run.recordHostKeychainNames(services: [service], label: "../x") }
    }

    @Test func objectsMadeByTheEngineNeedTheRunPrefix() throws {
        let run = try LiveCheckRun(environment: try environment())
        try run.recordCreated(role: "jamf-test-a", service: .jamfPlatform, resource: "categories", id: "3", name: "\(prefix) – C")
        #expect(throws: Ledger.LedgerError.self) {
            try run.recordCreated(role: "jamf-test-a", service: .jamfPlatform, resource: "categories", id: "4", name: "UIT - C")
        }
    }

    @Test func recordsResults() throws {
        let run = try LiveCheckRun(environment: try environment())
        run.record(step: "sign in", passed: true)
        run.record(step: "deploy", passed: false, note: "boom")
        let lines = try String(contentsOf: run.runFolder.appending(path: "results.jsonl"), encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
    }

    /// Each test of a release check runs in its own process: a refusal in
    /// one must still be in the report after the next (before 0.12.3 the
    /// last process to record a step overwrote the others').
    @Test func refusalsOfEveryTestProcessAreKept() async throws {
        let env = try environment()
        let server = MockServer { _ in .json(200, "{}") }
        var first = URLRequest(url: URL(string: "https://x.example/api/v1/categories")!)
        first.httpMethod = "POST"
        var second = URLRequest(url: URL(string: "https://y.example/api/v1/scripts")!)
        second.httpMethod = "DELETE"
        // Two runs on the same folder stand for two test processes.
        let one = try LiveCheckRun(environment: env, upstream: server.session)
        _ = try? await one.network.session.data(for: first)
        one.record(step: "first test", passed: true)
        let two = try LiveCheckRun(environment: env, upstream: server.session)
        _ = try? await two.network.session.data(for: second)
        // A test that never records a step still leaves its refusal.
        #expect(two.runRefusals.map(\.location) == ["x.example/api/v1/categories", "y.example/api/v1/scripts"])
        #expect(server.requests.isEmpty)
    }
}

@Suite("Live check: parsing")
struct ParsingTests {
    @Test func objectReferences() {
        #expect(LiveCheckPolicy.objectReference("/api/v1/categories/12/history") == .init(resource: "categories", id: "12"))
        #expect(LiveCheckPolicy.objectReference("/JSSResource/scripts/id/7") == .init(resource: "scripts", id: "7"))
        #expect(LiveCheckPolicy.objectReference("/JSSResource/scripts/id/0") == .init(resource: "scripts", id: "0", isClassicCreate: true))
        #expect(LiveCheckPolicy.objectReference("/blueprints/v1/blueprints") == .init(resource: "blueprints", id: nil))
        #expect(LiveCheckPolicy.objectReference("/beta/deviceManagement/deviceConfigurations") == .init(resource: "deviceConfigurations", id: nil))
    }

    @Test func createdIDs() {
        #expect(LiveCheckPolicy.createdID(in: Data(#"{"id":"5","href":"x"}"#.utf8)) == "5")
        #expect(LiveCheckPolicy.createdID(in: Data(#"{"id":17}"#.utf8)) == "17")
        #expect(LiveCheckPolicy.createdID(in: Data("<?xml version=\"1.0\"?><category><id>9</id></category>".utf8)) == "9")
    }
}
