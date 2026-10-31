import Foundation

/// The situations a demo can show besides the normal one, chosen with the
/// launch argument `-JTKitDemoScenario <name>` (for tests).
public nonisolated enum DemoScenario: String, Sendable, CaseIterable {
    /// A Jamf School environment: the device-group list answers 404
    /// `TENANT_NOT_FOUND`, and Blueprints are scoped to numeric group IDs.
    case jamfSchool
    /// Jamf Pro, Jamf School, Intune and Apple Business or Apple School Manager refuse
    /// device reads and commands with 403, as when the API client or app
    /// registration lacks the permission.
    case missingPermission
}

/// An in-memory Jamf Platform API: sign-in, device groups, environments and
/// Blueprints (list, detail, create, merge-patch, deploy, report). It answers
/// what JTKit’s client sends, with the behavior seen on the real service:
///
/// - on create and patch, `com.jamf.ddm-configuration-profile` payloads are
///   stored the way the service stores them (payload UUID = identifier, a few
///   keys added or dropped); Wi-Fi without `SetupModes` is refused;
/// - a patch replaces whole values (JSON merge-patch, arrays wholesale);
/// - patching `steps` of a Blueprint without a scope fails with 400 NotBlank
///   `scopeId`; a scope-only patch works;
/// - a Blueprint assigned to a division can’t be patched (409
///   `DIVISION_PATCH_NOT_ALLOWED`);
/// - changing a deployed Blueprint makes it Out of Date;
/// - a deployment moves `PENDING → DEPLOYING → SUCCEEDED` over successive reads.
///
/// Every request but the sign-in needs a token the sign-in gave out, as on
/// the gateway. Errors come in the gateway’s shape, so JTKit reads them as
/// from a tenant.
/// An app can add its own device groups (`add(groups:)`) and its own services
/// under a path (`route(_:to:)`), e.g. Classic API profiles behind the gateway.
/// Given a Jamf Pro object store (`jamfPro`), the gateway’s `/pro/…` and
/// `/proclassic/…` are answered from it; an app’s own route comes first.
public nonisolated final class DemoJamfPlatformServer: DemoServer, @unchecked Sendable {
    private struct Stored {
        var blueprint: LosslessJSON.Object
        var pollsSinceDeploy: Int?
    }

    private let lock = NSLock()
    private var blueprints: [String: Stored] = [:]
    /// The order Blueprints came in, for equal creation dates.
    private var order: [String] = []
    private var lastStarted = Date.distantPast
    private var createCountValue = 0
    private var deployCountValue = 0
    private var patchCountValue = 0
    private var tokenCount = 0
    private var tokens: Set<String> = []
    private var requestCountValue = 0
    private var groups: [JamfPlatform.DeviceGroup]
    /// An app’s own services under a path of this server (`route(_:to:)`).
    private var routes: [(path: [String], server: any DemoServer)] = []
    private let scenario: DemoScenario?
    /// The Jamf Pro behind the gateway: `/pro/…` is its Jamf Pro API,
    /// `/proclassic/…` its Classic API.
    public let jamfPro: DemoJamfProObjects?
    private let pollsToSucceed: Int
    private let failDeployments: Bool

    public var createCount: Int { lock.withLock { createCountValue } }
    public var deployCount: Int { lock.withLock { deployCountValue } }
    public var patchCount: Int { lock.withLock { patchCountValue } }
    /// Every request answered, sign-ins included.
    public var requestCount: Int { lock.withLock { requestCountValue } }

    /// - Parameters:
    ///   - groups: the device groups; Contoso’s by default.
    ///   - blueprints: the Blueprints to start with, oldest first; Contoso’s by default.
    ///   - scenario: e.g. `.jamfSchool`.
    ///   - pollsToSucceed: reads of a deploying Blueprint before it reports success.
    ///   - failDeployments: deployments end as failed instead.
    ///   - jamfPro: the Jamf Pro behind the gateway (`/pro/…`, `/proclassic/…`); none by default.
    public init(
        groups: [JamfPlatform.DeviceGroup]? = nil,
        blueprints: [LosslessJSON.Object]? = nil,
        scenario: DemoScenario? = nil,
        pollsToSucceed: Int = 3,
        failDeployments: Bool = false,
        jamfPro: DemoJamfProObjects? = nil
    ) {
        self.scenario = scenario
        self.jamfPro = jamfPro
        self.groups = scenario == .jamfSchool ? [] : (groups ?? DemoSamples.platformGroups)
        self.pollsToSucceed = pollsToSucceed
        self.failDeployments = failDeployments
        for blueprint in blueprints ?? DemoSamples.platformBlueprints(jamfSchool: scenario == .jamfSchool) {
            guard let id = blueprint["id"]?.stringValue else { continue }
            self.blueprints[id] = Stored(blueprint: blueprint)
            order.append(id)
        }
    }

    /// Adds an empty, undeployed Blueprint, e.g. a same-named one for a duplicate check.
    @discardableResult
    public func seed(name: String) -> String {
        let id = UUID().uuidString.lowercased()
        lock.withLock {
            blueprints[id] = Stored(blueprint: Self.blueprint(
                id: id, name: name, description: nil, deviceGroups: [], created: Self.now(), updated: nil,
                state: "NOT_DEPLOYED", steps: []))
            order.append(id)
        }
        return id
    }

    /// Adds Blueprints, e.g. an app’s own sample data, after the ones already
    /// there. They’re stored the way the service stores them, as on create
    /// (`com.jamf.ddm-configuration-profile` payloads included), so they read
    /// back as from a tenant and an unchanged payload stays unchanged when
    /// patched. One whose ID is already there replaces it in place; one
    /// without an ID is skipped.
    public func add(_ blueprints: [LosslessJSON.Object]) {
        lock.withLock {
            for var blueprint in blueprints {
                guard let id = blueprint["id"]?.stringValue else { continue }
                if let steps = blueprint["steps"]?.arrayValue {
                    blueprint["steps"] = .array(Self.storedSteps(steps))
                }
                if self.blueprints[id] == nil { order.append(id) }
                self.blueprints[id] = Stored(blueprint: blueprint)
            }
        }
    }

    /// A Blueprint as the server holds it now, or nil.
    public func blueprint(id: String) -> LosslessJSON.Object? {
        lock.withLock { blueprints[id]?.blueprint }
    }

    /// Adds device groups, e.g. an app’s own sample groups, after the ones
    /// already there. One whose ID is already there replaces it in place.
    public func add(groups newGroups: [JamfPlatform.DeviceGroup]) {
        lock.withLock {
            for group in newGroups {
                if let index = groups.firstIndex(where: { $0.id == group.id }) {
                    groups[index] = group
                } else {
                    groups.append(group)
                }
            }
        }
    }

    /// Hands every request whose path starts with `path` (e.g. `"proclassic"`)
    /// to `server`, an app’s own fake service behind this one, so the app’s
    /// requests there run through JTKit’s real client like the rest. Sign-in
    /// stays this server’s. The longest matching path wins; a path given
    /// again replaces its server.
    public func route(_ path: String, to server: any DemoServer) {
        let segments = path.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return }
        lock.withLock {
            routes.removeAll { $0.path == segments }
            routes.append((segments, server))
            routes.sort { $0.path.count > $1.path.count }
        }
    }

    // MARK: Requests

    public func respond(to request: DemoRequest) -> DemoResponse {
        let parts = request.pathSegments
        let method = request.method
        let isSignIn = method == "POST" && parts == ["auth", "token"]
        let signedIn = DemoJSON.bearer(request).map { token in lock.withLock { tokens.contains(token) } } ?? false
        guard isSignIn || signedIn else {
            lock.withLock { requestCountValue += 1 }
            return Self.error(401, "INVALID_TOKEN", "Unauthorized")
        }
        let routed: (any DemoServer)? = lock.withLock {
            routes.first { parts.starts(with: $0.path) }?.server
        }
        if let routed {
            lock.withLock { requestCountValue += 1 }
            // Outside the lock: the app’s server may take its time or ask this one.
            return routed.respond(to: request)
        }
        if let jamfPro, let first = parts.first, first == "pro" || first == "proclassic", parts.count > 1 {
            lock.withLock { requestCountValue += 1 }
            // as the gateway does: the Jamf Pro API under /pro, the Classic API under /proclassic
            return jamfPro.respond(to: request, parts: [first == "pro" ? "api" : "JSSResource"] + parts.dropFirst())
        }
        return lock.withLock {
            requestCountValue += 1
            if isSignIn {
                tokenCount += 1
                tokens.insert("demo-token-\(tokenCount)")
                return .json(200, .object(LosslessJSON.Object([
                    "access_token": .string("demo-token-\(tokenCount)"),
                    "token_type": .string("Bearer"),
                    "expires_in": .number(.init(1799)),
                ])))
            }
            if method == "GET", parts == ["device-groups", "v1", "device-groups"] {
                if scenario == .jamfSchool {
                    return Self.error(404, "TENANT_NOT_FOUND", "Tenant not found")
                }
                return groupPage(query: request.query)
            }
            if method == "GET", parts == ["organization", "v1", "environments"] {
                return .json(200, .object(LosslessJSON.Object(["results": .array([.object(LosslessJSON.Object([
                    "id": .string(DemoSamples.platformEnvironmentID),
                    "name": .string(scenario == .jamfSchool ? DemoSamples.schoolOrganization : DemoSamples.organization),
                ]))])])))
            }
            guard parts.count >= 3, Array(parts[0...2]) == ["blueprints", "v1", "blueprints"] else {
                return Self.error(404, "NOT_FOUND", "No such resource in demo mode.")
            }
            switch (method, parts.count) {
            case ("GET", 3):
                return list(query: request.query)
            case ("POST", 3):
                return create(request.body)
            case ("GET", 4):
                return detail(id: parts[3])
            case ("PATCH", 4):
                return patch(id: parts[3], body: request.body)
            case ("POST", 5) where parts[4] == "deploy":
                return deploy(id: parts[3])
            case ("GET", 5) where parts[4] == "report":
                return report(id: parts[3])
            default:
                return Self.error(404, "NOT_FOUND", "No such resource in demo mode.")
            }
        }
    }

    private func groupPage(query: [String: String]) -> DemoResponse {
        let items: [LosslessJSON] = groups.map { group in
            var object = LosslessJSON.Object([
                "id": .string(group.id),
                "name": .string(group.name),
                "description": group.description.map(LosslessJSON.string) ?? .null,
                "deviceType": .string(Self.raw(group.deviceType)),
                "groupType": .string(Self.raw(group.groupType)),
            ])
            if let count = group.memberCount { object["memberCount"] = .number(.init(count)) }
            return .object(object)
        }
        return Self.page(items, query: query)
    }

    private func list(query: [String: String]) -> DemoResponse {
        let search = query["search"] ?? ""
        // By creation date (ISO 8601 sorts as text), then by the order they came in.
        var ids = order.enumerated().sorted { first, second in
            let a = blueprints[first.element]?.blueprint["created"]?.stringValue ?? ""
            let b = blueprints[second.element]?.blueprint["created"]?.stringValue ?? ""
            return a == b ? first.offset < second.offset : a < b
        }.map(\.element)
        if (query["sort"] ?? "created:desc").hasSuffix(":desc") { ids.reverse() }
        let overviews: [LosslessJSON] = ids.compactMap { blueprints[$0]?.blueprint }
            .filter { search.isEmpty || ($0["name"]?.stringValue?.localizedCaseInsensitiveContains(search) ?? false) }
            .map { blueprint in
                var overview = blueprint
                overview["steps"] = nil
                return .object(overview)
            }
        return Self.page(overviews, query: query)
    }

    private func create(_ data: Data) -> DemoResponse {
        guard let request = try? LosslessJSON(data: data) else {
            return Self.error(400, "INVALID_FIELD", "The body is not valid JSON.")
        }
        let groups = request["scope"]?["deviceGroups"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !groups.isEmpty else {
            return Self.error(400, "INVALID_FIELD", "must not be empty", field: "scope.deviceGroups")
        }
        let steps = request["steps"]?.arrayValue ?? []
        if let refusal = Self.checkWiFi(steps) { return refusal }
        createCountValue += 1
        let id = UUID().uuidString.lowercased()
        let now = Self.now()
        blueprints[id] = Stored(blueprint: Self.blueprint(
            id: id, name: request["name"]?.stringValue ?? "", description: request["description"]?.stringValue,
            deviceGroups: groups, created: now, updated: now, state: "NOT_DEPLOYED", steps: Self.storedSteps(steps)))
        order.append(id)
        return .json(201, .object(LosslessJSON.Object([
            "id": .string(id),
            "href": .string("/blueprints/v1/blueprints/\(id)"),
        ])))
    }

    private func detail(id: String) -> DemoResponse {
        guard var stored = blueprints[id] else { return Self.notFound() }
        if let polls = stored.pollsSinceDeploy {
            let next = polls + 1
            let started = stored.blueprint["deploymentState"]?["lastDeployment"]?["started"]?.stringValue ?? Self.now()
            if next >= pollsToSucceed {
                stored.pollsSinceDeploy = nil
                if failDeployments {
                    Self.setDeployment(&stored.blueprint, state: "NOT_DEPLOYED", started: started, job: "FAILED")
                } else {
                    Self.setDeployment(&stored.blueprint, state: "DEPLOYED", started: started, job: "SUCCEEDED")
                }
            } else {
                stored.pollsSinceDeploy = next
                let state = stored.blueprint["deploymentState"]?["state"]?.stringValue ?? "NOT_DEPLOYED"
                Self.setDeployment(&stored.blueprint, state: state, started: started, job: next == 1 ? "PENDING" : "DEPLOYING")
            }
            blueprints[id] = stored
        }
        return .json(200, .object(stored.blueprint))
    }

    private func patch(id: String, body: Data) -> DemoResponse {
        guard var stored = blueprints[id] else { return Self.notFound() }
        guard let request = (try? LosslessJSON(data: body))?.objectValue else {
            return Self.error(400, "INVALID_FIELD", "The body is not valid JSON.")
        }
        if let division = stored.blueprint["divisionId"], division != .null {
            return Self.error(409, "DIVISION_PATCH_NOT_ALLOWED", "Blueprints assigned to a division can’t be changed through the API.")
        }
        let scope = request["scope"] ?? stored.blueprint["scope"]
        let groups = scope?["deviceGroups"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if request["steps"] != nil, groups.isEmpty {
            return Self.error(400, "NotBlank", "must not be blank", field: "scopeId")
        }
        if request["scope"] != nil, groups.isEmpty {
            return Self.error(400, "INVALID_FIELD", "must not be empty", field: "scope.deviceGroups")
        }
        if let steps = request["steps"] {
            guard let array = steps.arrayValue else {
                return Self.error(400, "INVALID_FIELD", "must be an array", field: "steps")
            }
            if let refusal = Self.checkWiFi(array) { return refusal }
            stored.blueprint["steps"] = .array(Self.storedSteps(array))
        }
        for key in ["name", "description", "scope"] {
            if let value = request[key] { stored.blueprint[key] = value }
        }
        patchCountValue += 1
        stored.blueprint["updated"] = .string(Self.now())
        // Any change to a deployed Blueprint leaves the devices behind until it’s deployed again.
        if stored.blueprint["deploymentState"]?["state"]?.stringValue == "DEPLOYED",
           request["steps"] != nil || request["scope"] != nil {
            var deployment = stored.blueprint["deploymentState"]?.objectValue ?? LosslessJSON.Object()
            deployment["state"] = .string("OUT_OF_DATE")
            stored.blueprint["deploymentState"] = .object(deployment)
        }
        blueprints[id] = stored
        return DemoResponse(status: 204)
    }

    private func deploy(id: String) -> DemoResponse {
        guard var stored = blueprints[id] else { return Self.notFound() }
        guard !(stored.blueprint["steps"]?.arrayValue ?? []).isEmpty else {
            return Self.error(409, "NOT_VALID_FOR_DEPLOYMENT", "Blueprint has no steps")
        }
        deployCountValue += 1
        stored.pollsSinceDeploy = 0
        // Each deployment gets its own start time, so a watch can tell it from the previous one.
        let started = max(Date(), lastStarted.addingTimeInterval(0.001))
        lastStarted = started
        let state = stored.blueprint["deploymentState"]?["state"]?.stringValue ?? "NOT_DEPLOYED"
        Self.setDeployment(&stored.blueprint, state: state,
                           started: started.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)),
                           job: "PENDING")
        blueprints[id] = stored
        return DemoResponse(status: 202)
    }

    private func report(id: String) -> DemoResponse {
        guard let stored = blueprints[id] else { return Self.notFound() }
        let sizes = Dictionary(groups.map { ($0.id, $0.memberCount ?? 0) }, uniquingKeysWith: { first, _ in first })
        let scope = stored.blueprint["scope"]?["deviceGroups"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let devices = scope.reduce(0) { $0 + (sizes[$1] ?? 3) }
        let deployment = stored.blueprint["deploymentState"]
        let deployed = deployment?["state"]?.stringValue == "DEPLOYED"
            && (deployment?["lastDeployment"]?["state"]?.stringValue ?? "SUCCEEDED") == "SUCCEEDED"
        let succeeded = deployed ? devices : 0
        return .json(200, .object(LosslessJSON.Object([
            "succeeded": .number(.init(succeeded)),
            "failed": .number(.init(0)),
            "pending": .number(.init(devices - succeeded)),
        ])))
    }

    // MARK: Building answers

    private static func page(_ items: [LosslessJSON], query: [String: String]) -> DemoResponse {
        let page = max(query["page"].flatMap(Int.init) ?? 0, 0)
        let size = max(query["page-size"].flatMap(Int.init) ?? 100, 1)
        let slice = items.dropFirst(page * size).prefix(size)
        return .json(200, .object(LosslessJSON.Object([
            "totalCount": .number(.init(items.count)),
            "hasNext": .bool((page + 1) * size < items.count),
            "results": .array(Array(slice)),
        ])))
    }

    /// Observed live: Wi-Fi SetupModes must not be empty.
    private static func checkWiFi(_ steps: [LosslessJSON]) -> DemoResponse? {
        for (stepIndex, step) in steps.enumerated() {
            for (componentIndex, component) in (step["components"]?.arrayValue ?? []).enumerated() {
                for (index, payload) in (component["configuration"]?["payloadContent"]?.arrayValue ?? []).enumerated()
                where payload["payloadType"]?.stringValue == "com.apple.wifi.managed" && payload["SetupModes"]?.arrayValue?.isEmpty == true {
                    return error(400, "SIZE", "size must be between 1 and 2147483647",
                                 field: "steps[\(stepIndex)].components[\(componentIndex)].configuration.payloadContent[\(index)].setupModes")
                }
            }
        }
        return nil
    }

    private static func storedSteps(_ steps: [LosslessJSON]) -> [LosslessJSON] {
        steps.map { step in
            guard var object = step.objectValue else { return step }
            object["components"] = .array((step["components"]?.arrayValue ?? []).map { component in
                guard var item = component.objectValue,
                      item["identifier"]?.stringValue == "com.jamf.ddm-configuration-profile",
                      let configuration = item["configuration"] else { return component }
                item["configuration"] = canonicalise(configuration)
                return .object(item)
            })
            return .object(object)
        }
    }

    private static func blueprint(
        id: String, name: String, description: String?, deviceGroups: [String], created: String, updated: String?,
        state: String, steps: [LosslessJSON]
    ) -> LosslessJSON.Object {
        LosslessJSON.Object([
            "id": .string(id),
            "name": .string(name),
            "description": description.map(LosslessJSON.string) ?? .null,
            "scope": .object(LosslessJSON.Object(["deviceGroups": .array(deviceGroups.map(LosslessJSON.string))])),
            "created": .string(created),
            "updated": updated.map(LosslessJSON.string) ?? .null,
            "deploymentState": .object(LosslessJSON.Object(["state": .string(state)])),
            "steps": .array(steps),
        ])
    }

    private static func setDeployment(_ blueprint: inout LosslessJSON.Object, state: String, started: String, job: String) {
        blueprint["deploymentState"] = .object(LosslessJSON.Object([
            "state": .string(state),
            "lastDeployment": .object(LosslessJSON.Object(["started": .string(started), "state": .string(job)])),
        ]))
    }

    /// The service’s storage of a `com.jamf.ddm-configuration-profile` configuration.
    private static func canonicalise(_ configuration: LosslessJSON) -> LosslessJSON {
        guard var object = configuration.objectValue else { return configuration }
        let payloads = object["payloadContent"]?.arrayValue ?? []
        object["payloadContent"] = .array(payloads.map { payload in
            guard var item = payload.objectValue else { return payload }
            // Observed live: these payload-level keys aren’t stored.
            item["PayloadDescription"] = nil
            item["PayloadEnabled"] = nil
            // Observed live: the API overwrites each payload’s UUID with its identifier.
            if let identifier = item["payloadIdentifier"] { item["payloadUUID"] = identifier }
            if item["payloadVersion"] == nil { item["payloadVersion"] = .number(.init(1)) }
            if item["payloadOrganization"] == nil { item["payloadOrganization"] = .string("Jamf") }
            if item["payloadDisplayName"] == nil {
                item["payloadDisplayName"] = .string(item["payloadType"]?.stringValue ?? "Payload")
            }
            return .object(item)
        })
        return .object(object)
    }

    /// An error in the gateway’s shape.
    private static func error(_ status: Int, _ code: String, _ description: String, field: String? = nil) -> DemoResponse {
        var item = LosslessJSON.Object(["code": .string(code)])
        if let field { item["field"] = .string(field) }
        item["description"] = .string(description)
        return .json(status, .object(LosslessJSON.Object([
            "httpStatus": .number(.init(status)),
            "traceId": .string("demo-trace"),
            "errors": .array([.object(item)]),
        ])))
    }

    private static func notFound() -> DemoResponse {
        error(404, "NOT_FOUND", "Blueprint doesn’t exist")
    }

    private static func raw(_ type: JamfPlatform.DeviceGroup.DeviceType) -> String {
        switch type {
        case .computer: "COMPUTER"
        case .mobile: "MOBILE"
        case let .other(raw): raw
        }
    }

    private static func raw(_ type: JamfPlatform.DeviceGroup.GroupType) -> String {
        switch type {
        case .smart: "SMART"
        case .static: "STATIC"
        case let .other(raw): raw
        }
    }

    private static func now() -> String {
        Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
    }
}
