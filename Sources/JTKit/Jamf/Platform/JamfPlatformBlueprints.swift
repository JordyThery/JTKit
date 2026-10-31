import Foundation

// MARK: - Models

extension JamfPlatform {
    /// `deploymentState.state`. Unknown values are kept, not dropped.
    public enum BlueprintState: Hashable, Sendable {
        case notDeployed
        case deployed
        case outOfDate
        case other(String)

        public init(rawValue: String) {
            switch rawValue {
            case "NOT_DEPLOYED": self = .notDeployed
            case "DEPLOYED": self = .deployed
            case "OUT_OF_DATE": self = .outOfDate
            default: self = .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .notDeployed: "NOT_DEPLOYED"
            case .deployed: "DEPLOYED"
            case .outOfDate: "OUT_OF_DATE"
            case .other(let raw): raw
            }
        }

        public var displayName: String {
            switch self {
            case .notDeployed: "Not Deployed"
            case .deployed: "Deployed"
            case .outOfDate: "Out of Date"
            case .other(let raw): raw.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
    }

    /// A Blueprint’s `deploymentState`: its state and its last deployment.
    public struct DeploymentState: Hashable, Sendable {
        public var state: BlueprintState
        /// The exact server text, so one deployment can be told from the next.
        public var lastDeploymentStarted: String?
        /// `PENDING`, `DEPLOYING`, `SUCCEEDED` or `FAILED`, kept as sent.
        public var lastDeploymentState: String?

        public init(state: BlueprintState, lastDeploymentStarted: String? = nil, lastDeploymentState: String? = nil) {
            self.state = state
            self.lastDeploymentStarted = lastDeploymentStarted
            self.lastDeploymentState = lastDeploymentState
        }

        public init?(json: LosslessJSON?) {
            guard let json, let raw = json["state"]?.stringValue else { return nil }
            state = BlueprintState(rawValue: raw)
            lastDeploymentStarted = json["lastDeployment"]?["started"]?.stringValue
            lastDeploymentState = json["lastDeployment"]?["state"]?.stringValue
        }
    }

    /// `GET …/blueprints/{id}/report`: devices per state.
    public struct BlueprintReport: Hashable, Sendable {
        public var succeeded: Int
        public var failed: Int
        public var pending: Int

        public var total: Int { succeeded + failed + pending }

        public init(succeeded: Int, failed: Int, pending: Int) {
            self.succeeded = succeeded
            self.failed = failed
            self.pending = pending
        }

        public init(json: LosslessJSON) {
            succeeded = json["succeeded"]?.numberValue?.intValue ?? 0
            failed = json["failed"]?.numberValue?.intValue ?? 0
            pending = json["pending"]?.numberValue?.intValue ?? 0
        }
    }

    /// The fields the list and the detail share. Only `id` is required.
    public struct BlueprintOverview: Identifiable, Hashable, Sendable {
        public let id: String
        public var name: String
        public var description: String?
        /// The exact server text, so "unchanged since read" compares like with like.
        public var updated: String?
        public var deploymentState: DeploymentState?

        public init?(json: LosslessJSON) {
            guard let id = json["id"]?.stringValue else { return nil }
            self.id = id
            name = json["name"]?.stringValue ?? "(unnamed)"
            description = json["description"]?.stringValue
            updated = json["updated"]?.stringValue
            deploymentState = DeploymentState(json: json["deploymentState"])
        }

        public var updatedDate: Date? { updated.flatMap(JamfPlatform.date(from:)) }
    }

    /// A whole Blueprint from `GET …/blueprints/{id}`, kept exactly as received,
    /// so anything an app doesn’t edit can be sent back as it was. The
    /// accessors only read.
    public struct BlueprintDetail: Identifiable, Sendable {
        /// One component of a step.
        public struct Component: Sendable, Hashable {
            public var stepIndex: Int
            public var index: Int
            public var identifier: String?
            public var json: LosslessJSON

            /// `steps[i].components[j]`.
            public var path: [LosslessJSON.PathComponent] {
                [.key("steps"), .index(stepIndex), .key("components"), .index(index)]
            }
        }

        public let overview: BlueprintOverview
        public let json: LosslessJSON
        /// The exact bytes received, e.g. for backups.
        public let rawData: Data
        public let fetchedAt: Date

        public var id: String { overview.id }
        public var steps: LosslessJSON? { json["steps"] }
        public var scope: LosslessJSON? { json["scope"] }

        public init(data: Data, fetchedAt: Date = Date()) throws {
            let json: LosslessJSON
            do {
                json = try LosslessJSON(data: data)
            } catch {
                throw JamfPlatform.APIError(.invalidResponse("The Blueprint isn’t valid JSON: \(error.localizedDescription)"))
            }
            guard let overview = BlueprintOverview(json: json) else {
                throw JamfPlatform.APIError(.invalidResponse("The Blueprint has no \"id\"."))
            }
            self.overview = overview
            self.json = json
            rawData = data
            self.fetchedAt = fetchedAt
        }

        /// Device group IDs from `scope.deviceGroups`.
        public var scopeDeviceGroups: [String] {
            scope?["deviceGroups"]?.arrayValue?.compactMap(\.stringValue) ?? []
        }

        /// A Blueprint assigned to a division can’t be changed through the API
        /// (a PATCH answers 409 `DIVISION_PATCH_NOT_ALLOWED`).
        public var isDivisionLocked: Bool {
            guard let division = json["divisionId"] else { return false }
            return division != .null
        }

        /// Every component of every step, in order.
        public var components: [Component] {
            (steps?.arrayValue ?? []).enumerated().flatMap { stepIndex, step in
                (step["components"]?.arrayValue ?? []).enumerated().map { index, component in
                    Component(stepIndex: stepIndex, index: index, identifier: component["identifier"]?.stringValue, json: component)
                }
            }
        }

        /// True when `latest` is the same Blueprint and still has the
        /// `updated` time this copy was read with. When either copy has no
        /// `updated` time, only an identical answer counts as unchanged.
        public func isUnchanged(in latest: BlueprintDetail) -> Bool {
            guard overview.id == latest.overview.id else { return false }
            guard let updated = overview.updated, let latestUpdated = latest.overview.updated else {
                return json == latest.json
            }
            return updated == latestUpdated
        }
    }

    /// Where a deployment stands: the Blueprint’s last deployment and its report.
    public struct DeploymentStatus: Hashable, Sendable {
        /// `PENDING`, `DEPLOYING`, `SUCCEEDED` or `FAILED`; nil until the new
        /// deployment shows up.
        public var jobState: String?
        public var jobStarted: String?
        public var blueprintState: BlueprintState?
        public var report: BlueprintReport?
        public var checkedAt: Date

        public init(jobState: String? = nil, jobStarted: String? = nil, blueprintState: BlueprintState? = nil,
                    report: BlueprintReport? = nil, checkedAt: Date = Date()) {
            self.jobState = jobState
            self.jobStarted = jobStarted
            self.blueprintState = blueprintState
            self.report = report
            self.checkedAt = checkedAt
        }

        public var isFinished: Bool { jobState == "SUCCEEDED" || jobState == "FAILED" }
        public var didSucceed: Bool { jobState == "SUCCEEDED" }
    }
}

// MARK: - Calls

extension JamfPlatform {
    /// The Blueprints API (`/blueprints/v1/blueprints`). Permissions:
    /// `blueprints:read`, `:create`, `:update`, `:deploy`, `:delete`.
    /// Never sends `divisionId`. No undeploy: no app uses it.
    public struct Blueprints: Sendable {
        public static let path = "/blueprints/v1/blueprints"

        public let client: Client

        public init(client: Client) {
            self.client = client
        }

        /// One page of the list. `page` is zero-based.
        public func listPage(page: Int = 0, pageSize: Int = 100, search: String? = nil, sort: String = "created:desc") async throws -> Page<BlueprintOverview> {
            try await client.page(Self.path, page: page, pageSize: pageSize, query: Self.query(search: search, sort: sort),
                                  item: BlueprintOverview.init(json:))
        }

        /// Every Blueprint, following all pages.
        public func list(search: String? = nil, sort: String = "created:desc", pageSize: Int = 100, maxPages: Int = 1_000) async throws -> [BlueprintOverview] {
            try await client.allPages(Self.path, query: Self.query(search: search, sort: sort),
                                      pageSize: pageSize, maxPages: maxPages, item: BlueprintOverview.init(json:))
        }

        public func detail(id: String) async throws -> BlueprintDetail {
            let response = try await client.send(HTTPRequest(path: Self.itemPath(id)))
            return try BlueprintDetail(data: response.data)
        }

        /// `POST` with name, description, scope and steps; returns the new ID.
        /// Only retried after a 429, so a Blueprint is never created twice.
        public func create(name: String, description: String?, deviceGroups: [String], steps: [LosslessJSON]) async throws -> String {
            guard !deviceGroups.isEmpty else {
                throw JamfPlatform.APIError(.invalidResponse("Refusing to create: a Blueprint needs at least one device group."))
            }
            var body = LosslessJSON.Object(["name": .string(name)])
            if let description, !description.isEmpty { body["description"] = .string(description) }
            body["scope"] = Self.scope(deviceGroups)
            body["steps"] = .array(steps)
            let response = try await client.send(HTTPRequest(
                method: "POST", path: Self.path, body: LosslessJSON.object(body).serialized(), contentType: "application/json"))
            guard let json = try? LosslessJSON(data: response.data), let id = json["id"]?.stringValue else {
                throw JamfPlatform.APIError(.invalidResponse("The create response has no Blueprint id."))
            }
            return id
        }

        /// `PATCH {"steps": [...]}` as merge-patch. `steps` must be the
        /// complete array: merge-patch replaces arrays whole. Safe to repeat.
        public func patchSteps(id: String, steps: LosslessJSON) async throws {
            guard steps.arrayValue != nil else {
                throw JamfPlatform.APIError(.invalidResponse("Refusing to PATCH: steps isn’t an array."))
            }
            try await mergePatch(id: id, LosslessJSON.Object(["steps": steps]))
        }

        /// `PATCH {"scope": {"deviceGroups": [...]}}` only: the complete new
        /// list, at least one group (the API requires one). Safe to repeat.
        public func patchScope(id: String, deviceGroups: [String]) async throws {
            guard !deviceGroups.isEmpty else {
                throw JamfPlatform.APIError(.invalidResponse("Refusing to PATCH: a Blueprint scope needs at least one device group."))
            }
            try await mergePatch(id: id, LosslessJSON.Object(["scope": Self.scope(deviceGroups)]))
        }

        /// `POST …/deploy`. Only retried after a 429, so a deployment is never
        /// started twice.
        public func deploy(id: String) async throws {
            _ = try await client.send(HTTPRequest(method: "POST", path: Self.itemPath(id) + "/deploy"))
        }

        /// The status report; nil while there is none (404).
        public func report(id: String) async throws -> BlueprintReport? {
            do {
                return BlueprintReport(json: try await client.json(Self.itemPath(id) + "/report"))
            } catch let error as JamfPlatform.APIError where error.status == 404 {
                return nil
            }
        }

        /// `DELETE`. Safe to repeat: a 404 after a repeat means an earlier
        /// attempt already deleted it.
        public func delete(id: String) async throws {
            _ = try await client.send(HTTPRequest(method: "DELETE", path: Self.itemPath(id),
                                                          repeating: .safeNotFoundIsDone))
        }

        // MARK: Deploy and watch

        /// Starts a deployment: reads the Blueprint first and returns when its
        /// last deployment started, so the watch can tell the new deployment
        /// from the previous one (also one started since the caller’s copy
        /// was read).
        public func startDeployment(id: String) async throws -> String? {
            let previous = try await detail(id: id).overview.deploymentState?.lastDeploymentStarted
            try await deploy(id: id)
            return previous
        }

        /// Follows the deployment that replaced `previousStart` until it
        /// succeeds or fails, or the poller’s time limit is reached (5 minutes
        /// by default). Each check reads the Blueprint and its report.
        public func watchDeployment(
            id: String,
            previousStart: String?,
            poller: Poller = Poller(),
            progress: @Sendable (DeploymentStatus) async -> Void = { _ in }
        ) async throws -> PollOutcome<DeploymentStatus> {
            try await poller.poll(
                check: {
                    let deployment = try await detail(id: id).overview.deploymentState
                    let started = deployment?.lastDeploymentStarted
                    let isNew = started != nil && started != previousStart
                    return DeploymentStatus(
                        jobState: isNew ? deployment?.lastDeploymentState : nil,
                        jobStarted: isNew ? started : nil,
                        blueprintState: deployment?.state,
                        report: try? await report(id: id),
                        checkedAt: Date()
                    )
                },
                isDone: \.isFinished,
                progress: progress
            )
        }

        // MARK: Private

        static func itemPath(_ id: String) -> String {
            "\(path)/\(JamfPlatform.pathSegment(id))"
        }

        private static func query(search: String?, sort: String) -> [URLQueryItem] {
            var query = [URLQueryItem(name: "sort", value: sort)]
            if let search, !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
            return query
        }

        private static func scope(_ deviceGroups: [String]) -> LosslessJSON {
            .object(LosslessJSON.Object(["deviceGroups": .array(deviceGroups.map(LosslessJSON.string))]))
        }

        private func mergePatch(id: String, _ body: LosslessJSON.Object) async throws {
            _ = try await client.send(HTTPRequest(
                method: "PATCH", path: Self.itemPath(id), body: LosslessJSON.object(body).serialized(),
                contentType: "application/merge-patch+json", repeating: .safe))
        }
    }
}
