import Foundation

extension JamfPlatform {
    /// One read permission to check: a list the integration should be able to read.
    public struct PermissionCheck: Sendable, Hashable, Identifiable {
        /// What it is for, e.g. "Read Blueprints".
        public var name: String
        public var path: String
        public var query: [URLQueryItem]
        /// The Jamf Account permission, e.g. `blueprints:read`.
        public var permission: String
        /// The Jamf Pro privilege for the same, when the path is a Jamf Pro one.
        public var jamfProPrivilege: String?

        public var id: String { path }

        /// - Parameter query: the first page of one item by default, so the
        ///   check reads as little as possible.
        public init(
            _ name: String,
            path: String,
            query: [URLQueryItem] = [URLQueryItem(name: "page", value: "0"), URLQueryItem(name: "page-size", value: "1")],
            permission: String,
            jamfProPrivilege: String? = nil
        ) {
            self.name = name
            self.path = path
            self.query = query
            self.permission = permission
            self.jamfProPrivilege = jamfProPrivilege
        }

        public static let blueprintsRead = PermissionCheck(
            "Read Blueprints", path: "/blueprints/v1/blueprints", permission: "blueprints:read")
        public static let deviceGroupsRead = PermissionCheck(
            "Read device groups", path: "/device-groups/v1/device-groups", permission: "device-groups:read")

        /// What to do when the permission is missing.
        public var hint: String {
            "Add the “\(permission)” permission to the API integration in Jamf Account."
        }

        /// The same for a Jamf Pro server reached directly.
        public var jamfProHint: String? {
            jamfProPrivilege.map { "Add the “\($0)” privilege to the API role in Jamf Pro under Settings › API Roles and Clients." }
        }

        /// What to do when the permission is missing on `server`: in Jamf
        /// Account, or in Jamf Pro's API roles (naming the privilege when
        /// the check knows it).
        public func hint(on server: JamfPlatform.Server) -> String {
            guard server == .jamfPro else { return hint }
            return jamfProHint ?? "Add the privilege for “\(name)” to the API role in Jamf Pro under Settings › API Roles and Clients."
        }
    }

    /// What one check found.
    public enum PermissionResult: Sendable, Hashable {
        case allowed
        /// HTTP 403: the integration lacks the permission.
        case missingPermission
        /// HTTP 404: the list isn't there (wrong path, or not in this environment).
        case notFound
        /// Another status, also a refused sign-in.
        case failed(status: Int)
        /// No answer, or the request wasn't sent.
        case unreachable(String)
    }
}

extension JamfPlatform.Client {
    /// Runs the checks, 4 at a time, with reads only. Results are in the order
    /// of `checks`. Only a 403 counts as a missing permission.
    public func checkPermissions(
        _ checks: [JamfPlatform.PermissionCheck],
        maxConcurrent: Int = 4
    ) async -> [(check: JamfPlatform.PermissionCheck, result: JamfPlatform.PermissionResult)] {
        var results = [JamfPlatform.PermissionResult?](repeating: nil, count: checks.count)
        await withTaskGroup(of: (Int, JamfPlatform.PermissionResult).self) { group in
            var next = 0
            func start() {
                guard next < checks.count else { return }
                let index = next
                next += 1
                group.addTask { (index, await self.result(of: checks[index])) }
            }
            for _ in 0..<max(maxConcurrent, 1) { start() }
            for await (index, result) in group {
                results[index] = result
                start()
            }
        }
        return zip(checks, results).map { ($0, $1 ?? .unreachable("Not checked.")) }
    }

    private func result(of check: JamfPlatform.PermissionCheck) async -> JamfPlatform.PermissionResult {
        do {
            let response = try await send(HTTPRequest(path: check.path, query: check.query))
            return Self.result(status: response.status)
        } catch let error as JamfPlatformError {
            guard let status = error.status else { return .unreachable(error.message()) }
            if case .signIn = error.kind { return .failed(status: status) }
            return Self.result(status: status)
        } catch {
            return .unreachable(Redaction.text(error.localizedDescription))
        }
    }

    private static func result(status: Int) -> JamfPlatform.PermissionResult {
        switch status {
        case 200..<300: .allowed
        case 403: .missingPermission
        case 404: .notFound
        default: .failed(status: status)
        }
    }
}
