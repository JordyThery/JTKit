import Foundation
import JTKit
import JTKitLiveCheck

/// A live check of JTKit’s own Blueprint deploy (1.1.0, A13), for any app’s
/// release check with a Jamf Platform API role on a disposable tenant
/// (jamf-test-a): creates an empty static `JTKTEST` device group and a
/// `JTKTEST` Blueprint scoped to it, deploys it with JTKit’s
/// `startDeployment` (the body-less POST) and confirms it with JTKit’s
/// `watchDeployment`, then removes both. Everything goes through the run’s
/// guarded network and ledger.
///
/// The result says how the deployment was confirmed: by the Blueprint’s
/// `lastDeployment` (as JTKit 1.0 expects), or, when the answer has none, by
/// the Blueprint’s own state (1.1.0’s fallback).
public enum LiveBlueprintDeployCheck {
    public struct Result: Sendable, Equatable {
        /// The deployment finished and succeeded.
        public var deployed: Bool
        /// JTKit’s watch read `lastDeployment` (false: the Blueprint’s own state).
        public var confirmedByLastDeployment: Bool
        /// The job state the watch ended with, e.g. "SUCCEEDED".
        public var jobState: String?
        /// The Blueprint and the group are gone (read back).
        public var removed: Bool
    }

    public enum CheckError: Error, CustomStringConvertible {
        case groupNotEmpty
        case noID(String)

        public var description: String {
            switch self {
            case .groupNotEmpty: "The test group isn’t an empty static group; nothing is deployed"
            case .noID(let what): "The \(what) create answered without an id"
            }
        }
    }

    /// Runs the check; the steps go to the run’s report (`results.jsonl`).
    /// Removes what it made also when a step fails.
    /// - Parameter role: a Jamf Platform API role of the run with
    ///   credentials `client-id` and `client-secret`.
    public static func run(_ run: LiveCheckRun, role: String = "jamf-test-a",
                           poller: JamfPlatform.Poller = JamfPlatform.Poller()) async throws -> Result {
        let entry = try run.entry(role: role, service: .jamfPlatform)
        let region = JamfRegion(rawValue: entry.region ?? "") ?? .us
        let connection = Connection(name: "Live check", service: .jamfPlatform, region: region,
                                    environmentID: entry.environmentID ?? "", clientID: try run.credential(role, "client-id"))
        let secret = try run.credential(role, "client-secret")
        let client = try JamfPlatform.Client(connection: connection, secret: { secret },
                                             recorder: RequestRecorder(session: run.network.session, log: nil, category: "Live check"))
        let blueprints = JamfPlatform.Blueprints(client: client)
        let step = { (name: String) in "\(role): JTKit Blueprint deploy: \(name)" }

        // 1. An empty static group (never smart, never with members).
        let body = try JSONSerialization.data(withJSONObject: [
            "name": "\(run.prefix) – A13 Group", "deviceType": "COMPUTER", "groupType": "STATIC", "members": [String](),
        ])
        let created = try await client.send(HTTPRequest(method: "POST", path: JamfPlatform.Client.deviceGroupsPath, body: body,
                                                        contentType: "application/json"))
        guard let groupID = try LosslessJSON(data: created.data)["id"]?.stringValue else { throw CheckError.noID("group") }
        var blueprintID: String?
        do {
            let groupPath = "\(JamfPlatform.Client.deviceGroupsPath)/\(JamfPlatform.pathSegment(groupID))"
            let group = JamfPlatform.DeviceGroup(json: try await client.json(groupPath))
            let members = try await client.json(groupPath + "/members")
            let isEmpty = group?.groupType == .static && (group?.memberCount ?? 0) == 0
                && (members["totalCount"]?.numberValue?.intValue ?? members["results"]?.arrayValue?.count) == 0
            run.record(step: step("create an empty static device group"), passed: isEmpty)
            guard isEmpty else { throw CheckError.groupNotEmpty }

            // 2. A Blueprint with one small step, scoped to the group.
            let id = try await blueprints.create(name: "\(run.prefix) – A13 Blueprint",
                                                 description: "Release check test object; removed after the run",
                                                 deviceGroups: [groupID], steps: [try Self.step()])
            blueprintID = id
            run.record(step: step("create a Blueprint scoped to the group"), passed: true)

            // 3. Deploy with JTKit and confirm with JTKit’s waiting.
            let previous = try await blueprints.startDeployment(id: id)
            let outcome = try await blueprints.watchDeployment(id: id, previousStart: previous, poller: poller)
            let status = outcome.value
            let deployed = outcome.isFinished && status?.didSucceed == true
            let byLastDeployment = !(status?.readFromBlueprintState ?? false)
            run.record(step: step("deploy and confirm with JTKit’s watch"), passed: deployed,
                       note: "\(status?.jobState ?? "no state"), confirmed by \(byLastDeployment ? "lastDeployment" : "the Blueprint’s own state (no lastDeployment in the answer)")")

            // 4. Remove both.
            let removed = try await remove(blueprint: id, group: groupID, client: client, blueprints: blueprints)
            run.record(step: step("remove the Blueprint and the group"), passed: removed)
            return Result(deployed: deployed, confirmedByLastDeployment: byLastDeployment, jobState: status?.jobState, removed: removed)
        } catch {
            // a failed step: remove what was made anyway (the release check’s cleanup sweeps too)
            if let blueprintID {
                _ = try? await remove(blueprint: blueprintID, group: groupID, client: client, blueprints: blueprints)
            } else {
                _ = try? await deleteGroup(groupID, client: client)
            }
            throw error
        }
    }

    /// The Blueprint, then the group once Jamf no longer counts it as used
    /// (it removes a deleted Blueprint in the background: 422 HAS_DEPENDENCIES
    /// until then). True when both read back as gone.
    @discardableResult
    static func remove(blueprint id: String, group: String, client: JamfPlatform.Client,
                       blueprints: JamfPlatform.Blueprints) async throws -> Bool {
        do {
            try await blueprints.delete(id: id)
        } catch let error as JamfPlatform.APIError where error.status == 404 {}
        let deadline = Date().addingTimeInterval(120)
        var blueprintGone = false
        while !blueprintGone && Date() < deadline {
            do {
                _ = try await blueprints.detail(id: id)
                try await Task.sleep(for: .seconds(3))
            } catch let error as JamfPlatform.APIError where error.status == 404 {
                blueprintGone = true
            }
        }
        let groupGone = try await deleteGroup(group, client: client)
        return blueprintGone && groupGone
    }

    @discardableResult
    static func deleteGroup(_ id: String, client: JamfPlatform.Client) async throws -> Bool {
        let path = "\(JamfPlatform.Client.deviceGroupsPath)/\(JamfPlatform.pathSegment(id))"
        let deadline = Date().addingTimeInterval(120)
        while true {
            do {
                _ = try await client.send(HTTPRequest(method: "DELETE", path: path, repeating: .safe))
                return true
            } catch let error as JamfPlatform.APIError where error.status == 404 {
                return true
            } catch let error as JamfPlatform.APIError
                        where error.status == 422 && error.body?.errors.contains(where: { $0.code == "HAS_DEPENDENCIES" }) == true
                        && Date() < deadline {
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// One step with one Managed Preferences payload (a made-up domain, one
    /// key): the shape Jamf gives a migrated Classic profile. Jamf requires
    /// real UUIDs as payload UUIDs.
    static func step() throws -> LosslessJSON {
        try LosslessJSON(string: #"{"name":"JTKTEST A13","components":[{"identifier":"com.jamf.ddm-configuration-profile","configuration":{"payloadUUID":"\#(UUID().uuidString)","payloadContent":[{"payloadType":"com.apple.ManagedClient.preferences","payloadUUID":"\#(UUID().uuidString)","PayloadContent":{"com.example.jtktest":{"Forced":[{"mcx_preference_settings":{"JTKTESTFlag":false}}]}},"payloadVersion":1,"payloadIdentifier":"com.example.jtktest.payload","payloadDisplayName":"JTKTEST Preferences"}],"payloadIdentifier":"com.example.jtktest.profile","payloadDisplayName":"JTKTEST Profile"}}],"activationPredicate":null}"#)
    }
}
