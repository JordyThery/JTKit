import Foundation
import Testing
@testable import JTKitLiveCheck

@Suite("Live check: a run’s group or PreStage never gets members")
struct GroupMembershipTests {
    private let headers = ["X-Environment-Id": platformA]
    private let gateway = "https://eu.api.jamfcloud.com"
    private let group = "00000000-0000-4000-8000-0000000000c1"

    @Test("An empty static group is created, through the Platform API, Jamf Pro and Classic")
    func emptyStaticGroups() {
        let policy = makePolicy()
        #expect(policy.decide(request("POST", "\(gateway)/device-groups/v1/device-groups", headers: headers,
                                      json: ["name": "\(prefix) – G", "deviceType": "COMPUTER", "groupType": "STATIC", "members": [String]()]))
            .isAllowed)
        #expect(policy.decide(request("POST", "https://test-a.jamf.example/api/v2/computer-groups/static-groups",
                                      json: ["name": "\(prefix) – G", "assignments": [Any]()])).isAllowed)
        let classic = "<computer_group><name>\(prefix) – G</name><is_smart>false</is_smart><computers><size>0</size></computers></computer_group>"
        #expect(policy.decide(request("POST", "\(gateway)/proclassic/computergroups/id/0", headers: headers, body: classic)).isAllowed)
    }

    @Test("A create that names members or is smart is refused")
    func createsWithMembers() {
        let policy = makePolicy()
        let platform = "\(gateway)/device-groups/v1/device-groups"
        #expect(!policy.decide(request("POST", platform, headers: headers,
                                       json: ["name": "\(prefix) – G", "groupType": "STATIC", "members": ["00000000-0000-4000-8000-0000000000d1"]])).isAllowed)
        #expect(!policy.decide(request("POST", platform, headers: headers,
                                       json: ["name": "\(prefix) – G", "groupType": "SMART"])).isAllowed)
        #expect(!policy.decide(request("POST", "https://test-a.jamf.example/api/v2/computer-groups/static-groups",
                                       json: ["name": "\(prefix) – G", "assignments": [["computerId": "5", "selected": true]]])).isAllowed)
        #expect(!policy.decide(request("POST", "https://test-a.jamf.example/api/v2/computer-groups/smart-groups",
                                       json: ["name": "\(prefix) – G"])).isAllowed)
        let smart = "<computer_group><name>\(prefix) – G</name><is_smart>true</is_smart></computer_group>"
        #expect(!policy.decide(request("POST", "\(gateway)/proclassic/computergroups/id/0", headers: headers, body: smart)).isAllowed)
        let criteria = "<computer_group><name>\(prefix) – G</name><criteria><criterion><name>Model</name></criterion></criteria></computer_group>"
        #expect(!policy.decide(request("POST", "\(gateway)/proclassic/computergroups/id/0", headers: headers, body: criteria)).isAllowed)
    }

    @Test("A change to the run’s own group or PreStage that adds members is refused")
    func changesWithMembers() throws {
        let policy = makePolicy()
        try policy.ledger.add(created("platform:\(platformA)", "computergroups", "5", "\(prefix) – G"), testPrefixes: [prefix])
        try policy.ledger.add(created("test-a.jamf.example", "computer-prestages", "7", "\(prefix) – P"), testPrefixes: [prefix])
        let classic = "\(gateway)/proclassic/computergroups/id/5"
        #expect(policy.decide(request("PUT", classic, headers: headers,
                                      body: "<computer_group><name>\(prefix) – G</name></computer_group>")).kind == .change)
        #expect(!policy.decide(request("PUT", classic, headers: headers,
                                       body: "<computer_group><computers><computer><id>5</id></computer></computers></computer_group>")).isAllowed)
        #expect(!policy.decide(request("PUT", classic, headers: headers,
                                       body: "<computer_group><computer_additions><computer><id>5</id></computer></computer_additions></computer_group>")).isAllowed)
        #expect(!policy.decide(request("POST", "https://test-a.jamf.example/api/v2/computer-prestages/7/scope",
                                       json: ["serialNumbers": ["ZZTESTSERIAL"], "versionLock": 1])).isAllowed)
        // removing the group is still allowed
        #expect(policy.decide(request("DELETE", classic, headers: headers)).kind == .delete)
    }

    @Test("Graph: no members added to the run’s group, and no dynamic group")
    func graphMembers() throws {
        let policy = makePolicy()
        let auth = ["Authorization": "Bearer \(jwt(tid: entraTest))"]
        try policy.ledger.add(created("intune:\(entraTest)", "groups", group, "\(prefix) – Group"), testPrefixes: [prefix])
        let groups = "https://graph.microsoft.com/v1.0/groups"
        #expect(policy.decide(request("POST", groups, headers: auth,
                                      json: ["displayName": "\(prefix) – Group", "groupTypes": [String](), "securityEnabled": true])).isAllowed)
        #expect(!policy.decide(request("POST", groups, headers: auth,
                                       json: ["displayName": "\(prefix) – Group", "groupTypes": ["DynamicMembership"],
                                              "membershipRule": "(device.deviceOSType -eq \"MacMDM\")"])).isAllowed)
        #expect(!policy.decide(request("POST", groups, headers: auth,
                                       json: ["displayName": "\(prefix) – Group",
                                              "members@odata.bind": ["https://graph.microsoft.com/v1.0/devices/1"]])).isAllowed)
        #expect(!policy.decide(request("POST", "\(groups)/\(group)/members/$ref", headers: auth,
                                       json: ["@odata.id": "https://graph.microsoft.com/v1.0/devices/1"])).isAllowed)
        #expect(policy.decide(request("PATCH", "\(groups)/\(group)", headers: auth,
                                      json: ["description": "JTKit release check"])).kind == .change)
    }

    @Test("1.13.2: only group and PreStage resources are checked; 0, false and empty name no one; removals pass")
    func narrowerGuard() throws {
        let policy = makePolicy()
        let auth = ["Authorization": "Bearer \(jwt(tid: entraTest))"]
        // Graph’s administrative templates aren’t groups
        #expect(policy.decide(request("POST", "https://graph.microsoft.com/beta/deviceManagement/groupPolicyConfigurations",
                                      headers: auth, json: ["displayName": "\(prefix) – Template", "members": ["x"]])).isAllowed)
        // a Classic account group isn’t a device group
        try policy.ledger.add(created("test-a.jamf.example", "accounts", "3", "\(prefix) – A"), testPrefixes: [prefix])
        let account = policy.decide(request("PUT", "https://test-a.jamf.example/JSSResource/accounts/groupid/3",
                                            body: "<group><users><user><name>x</name></user></users></group>"))
        if case .refuse(let reason) = account { #expect(!reason.contains("members"), "\(reason)") }
        // zero and false are empty
        #expect(policy.decide(request("POST", "https://test-a.jamf.example/api/v2/computer-groups/static-groups",
                                      json: ["name": "\(prefix) – G", "computers": 0, "smart": false, "assignments": [Any]()])).isAllowed)
        #expect(!policy.decide(request("POST", "https://test-a.jamf.example/api/v2/computer-groups/static-groups",
                                       json: ["name": "\(prefix) – G", "computers": 3])).isAllowed)
        // a body that is neither JSON nor XML isn’t refused by this rule
        try policy.ledger.add(created("test-a.jamf.example", "computer-groups", "8", "\(prefix) – G"), testPrefixes: [prefix])
        #expect(policy.decide(request("PUT", "https://test-a.jamf.example/api/v1/computer-groups/8", body: "name=x")).kind == .change)
        // removing serials from a run’s PreStage only narrows it
        try policy.ledger.add(created("test-a.jamf.example", "computer-prestages", "7", "\(prefix) – P"), testPrefixes: [prefix])
        #expect(policy.decide(request("POST", "https://test-a.jamf.example/api/v2/computer-prestages/7/scope/delete-multiple",
                                      json: ["serialNumbers": ["ZZTESTSERIAL"], "versionLock": 1])).isAllowed)
    }
}
