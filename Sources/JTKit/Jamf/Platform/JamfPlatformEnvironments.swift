import Foundation

extension JamfPlatform {
    /// A platform environment the integration's organization has.
    public struct Environment: Identifiable, Hashable, Sendable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        /// Reads `id` (or `environmentId`) and `name`; nil without an ID.
        public init?(json: LosslessJSON) {
            guard let id = json["id"]?.stringValue ?? json["environmentId"]?.stringValue, !id.isEmpty else { return nil }
            let name = json["name"]?.stringValue ?? ""
            self.init(id: id, name: name.isEmpty ? id : name)
        }
    }

    /// The environments of a connection's organization, for picking its
    /// Environment ID. Signs in with the connection's region, client ID and
    /// `secret`; the Environment ID itself isn't needed.
    ///
    /// - Throws: `JamfPlatformError` `.cannotListEnvironments` when the
    ///   integration is scoped to one environment; a refused sign-in as usual.
    public static func environments(
        for connection: Connection,
        secret: @escaping @Sendable () throws -> String,
        recorder: RequestRecorder,
        permits: @escaping @Sendable (HTTPRequest) -> Bool = { _ in true }
    ) async throws -> [Environment] {
        let client = try Client(connection: connection, secret: secret, recorder: recorder, scope: .organization, permits: permits)
        return try await client.environments()
    }
}

extension JamfPlatform.Client {
    public static let environmentsPath = "/organization/v1/environments"

    /// `GET /organization/v1/environments`, sorted by name. Use a client with
    /// `.organization` scope: the call takes no scope header.
    ///
    /// - Throws: `JamfPlatformError` `.cannotListEnvironments` when the server
    ///   answers 401, 403 or 404 after a good sign-in: what an integration
    ///   scoped to one environment gets.
    public func environments() async throws -> [JamfPlatform.Environment] {
        let json: LosslessJSON
        do {
            json = try await self.json(Self.environmentsPath)
        } catch let error as JamfPlatformError {
            if case let .status(status, _, _, _, _) = error.kind, [401, 403, 404].contains(status) {
                throw JamfPlatformError(.cannotListEnvironments)
            }
            throw error
        }
        // the list is `results`; older answers call it `environments`
        guard let items = json["results"]?.arrayValue ?? json["environments"]?.arrayValue else {
            throw JamfPlatformError(.invalidResponse("The environment list has no \"results\"."))
        }
        return items.compactMap(JamfPlatform.Environment.init(json:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
