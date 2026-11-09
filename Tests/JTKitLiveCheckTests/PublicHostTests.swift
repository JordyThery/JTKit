import Foundation
import Testing
import JTKitTestSupport
@testable import JTKitLiveCheck

// 1.5.0 (decided by Jordy on 2026-11-09): the allow-list may name public
// hosts, e.g. Apple’s release data. A request to one is sent only as a GET
// without a body, credentials, cookies or an authorization header; every
// other host is refused as before. Made-up hosts only.

private let publicHost = "releases.example.org"

private func publicList(_ hosts: [String]? = [publicHost]) -> AllowList {
    AllowList(version: 3, tenants: [
        .init(role: "lab", service: .jamfPro, host: "lab.jamf.example", access: .readOnly),
    ], publicHosts: hosts)
}

private func publicPolicy(_ list: AllowList = publicList()) -> LiveCheckPolicy {
    LiveCheckPolicy(allowList: list, roles: nil, includeProduction: false, prefix: "JTKTEST",
                    ledger: Ledger(fileURL: tempFolder().appending(path: "ledger.json")))
}

private func writeList(_ json: String) throws -> URL {
    let url = tempFolder().appending(path: "allowlist.json")
    try Data(json.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return url
}

private func refusal(_ decision: LiveDecision) -> String? {
    if case .refuse(let reason) = decision { return reason }
    return nil
}

@Suite("1.5.0: public hosts on the allow-list")
struct PublicHostTests {
    @Test func aGetWithoutCredentialsIsAllowed() {
        let decision = publicPolicy().decide(request("GET", "https://\(publicHost)/v2/ios_data_feed.json",
                                                     headers: ["User-Agent": "Example/1.0", "Accept": "application/json"]))
        guard case .allow(let allowed) = decision else { Issue.record("refused: \(decision)"); return }
        #expect(allowed.kind == .read)
        #expect(allowed.target == "public:\(publicHost)")
    }

    @Test func theHostMatchesWithoutRegardToCase() {
        let policy = publicPolicy(publicList(["Releases.Example.ORG "]))
        #expect(policy.decide(request("GET", "https://RELEASES.example.org/feed.json")).isAllowed)
    }

    @Test(arguments: ["POST", "PUT", "PATCH", "DELETE", "HEAD"])
    func onlyGetIsSent(_ method: String) {
        let reason = refusal(publicPolicy().decide(request(method, "https://\(publicHost)/feed.json")))
        #expect(reason?.contains("only GET is sent") == true)
    }

    @Test(arguments: ["Authorization", "Proxy-Authorization", "Cookie", "X-Api-Key", "X-Auth-Token", "X-Session-Id", "Client-Secret"])
    func aCredentialHeaderIsRefused(_ header: String) {
        let reason = refusal(publicPolicy().decide(request("GET", "https://\(publicHost)/feed.json", headers: [header: "x"])))
        #expect(reason?.contains("header is refused") == true)
    }

    @Test func aBodyCredentialsInTheAddressOrAKeyInTheQueryAreRefused() {
        let policy = publicPolicy()
        #expect(refusal(policy.decide(request("GET", "https://\(publicHost)/feed.json", body: "x"))) != nil)
        #expect(refusal(policy.decide(request("GET", "https://user:pass@\(publicHost)/feed.json"))) != nil)
        #expect(refusal(policy.decide(request("GET", "https://\(publicHost)/feed.json?access_token=x"))) != nil)
        #expect(refusal(policy.decide(request("GET", "https://\(publicHost)/feed.json?api_key=x"))) != nil)
        #expect(policy.decide(request("GET", "https://\(publicHost)/feed.json?platform=ios")).isAllowed)
    }

    @Test func plainHttpIsRefused() {
        #expect(refusal(publicPolicy().decide(request("GET", "http://\(publicHost)/feed.json"))) != nil)
    }

    @Test func everyOtherHostIsRefusedAsBefore() {
        let policy = publicPolicy()
        #expect(refusal(policy.decide(request("GET", "https://other.example.org/feed.json")))?.contains("isn’t on the allow-list") == true)
        #expect(refusal(policy.decide(request("GET", "https://sub.\(publicHost)/feed.json"))) != nil)
        // without the key, a public source is just another host
        #expect(refusal(publicPolicy(publicList(nil)).decide(request("GET", "https://\(publicHost)/feed.json"))) != nil)
    }

    @Test func tenantsAreDecidedAsBefore() {
        let policy = publicPolicy()
        #expect(policy.decide(request("GET", "https://lab.jamf.example/api/v1/jamf-pro-version")).isAllowed)
        #expect(refusal(policy.decide(request("POST", "https://lab.jamf.example/api/v1/buildings", json: ["name": "JTKTEST"]))) != nil)
    }

    @Test func theFileReadsPublicHostsInAnyVersion() throws {
        let url = try writeList(#"""
        {"version": 2, "publicHosts": ["releases.example.org", "feeds.example.net"], "tenants": [
          {"role": "lab", "service": "jamfPro", "host": "lab.jamf.example", "access": "read", "production": false}]}
        """#)
        let list = try AllowList.load(from: url)
        #expect(list.publicHostSet == ["releases.example.org", "feeds.example.net"])
    }

    @Test(arguments: ["https://releases.example.org", "releases.example.org/feed", "*.example.org", "releases.example.org:443",
                      "localhost", "lab.jamf.example", "eu.api.jamfcloud.com", "tenant.jamfcloud.com",
                      "login.microsoftonline.com", "graph.microsoft.com", "account.apple.com", "api-business.apple.com",
                      "files.blob.core.windows.net"])
    func aHostThatIsntPlainOrCarriesCredentialsIsRefusedWhenLoading(_ host: String) throws {
        let url = try writeList(#"""
        {"version": 3, "publicHosts": ["\#(host)"], "tenants": [
          {"role": "lab", "service": "jamfPro", "host": "lab.jamf.example", "access": "read", "production": false}]}
        """#)
        #expect(throws: AllowList.LoadError.self) { try AllowList.load(from: url) }
    }

    @Test func noCookieIsSentOrKept() async throws {
        let upstream = MockServer { _ in
            MockResponse(status: 200, headers: ["Content-Type": "application/json", "Set-Cookie": "session=abc; Path=/; Secure"],
                         body: Data("{}".utf8))
        }
        let network = LiveCheckNetwork(policy: publicPolicy(), upstream: upstream.session)
        for _ in 1...2 {
            let (_, response) = try await network.session.data(from: URL(string: "https://\(publicHost)/feed.json")!)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        }
        #expect(upstream.requests.count == 2)
        #expect(upstream.requests.allSatisfy { $0.header("Cookie") == nil && $0.header("Authorization") == nil })
    }

    @Test func aRefusedRequestNeverLeaves() async {
        let upstream = MockServer { _ in .json(200, "{}") }
        let network = LiveCheckNetwork(policy: publicPolicy(), upstream: upstream.session)
        var post = URLRequest(url: URL(string: "https://\(publicHost)/feed.json")!)
        post.httpMethod = "POST"
        await #expect(throws: (any Error).self) { _ = try await network.session.data(for: post) }
        var withToken = URLRequest(url: URL(string: "https://\(publicHost)/feed.json")!)
        withToken.setValue("Bearer x", forHTTPHeaderField: "Authorization")
        await #expect(throws: (any Error).self) { _ = try await network.session.data(for: withToken) }
        #expect(upstream.requests.isEmpty)
        #expect(network.refusals.count == 2)
    }
}
