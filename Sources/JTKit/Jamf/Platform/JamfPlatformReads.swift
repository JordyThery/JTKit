import Foundation

extension JamfPlatform {
    /// The Jamf Account permissions of the read-only calls, as the Platform
    /// API names them.
    public enum Permission {
        public static let blueprintsRead = "blueprints:read"
        public static let devicesRead = "devices:read"
        public static let deviceGroupsRead = "device-groups:read"
        public static let declarationsRead = "declarations:read"
    }
}

extension JamfPlatform.PermissionCheck {
    public static let devicesRead = JamfPlatform.PermissionCheck(
        "Read Devices", path: "/devices/v1/devices", permission: JamfPlatform.Permission.devicesRead)
}

extension JamfPlatform.Client {
    /// As `send(_:privileges:)`; when the Platform API refuses the request,
    /// the error names `permissions` (the gateway asks for its own
    /// permissions, not Jamf Pro privileges).
    func send(_ request: HTTPRequest, privileges: [JamfPro.Privilege], permissions: [String]) async throws -> HTTPResponse {
        do {
            return try await send(request, privileges: privileges)
        } catch var error as JamfPlatform.APIError where error.server == .platformAPI && !permissions.isEmpty {
            error.permissions = permissions
            throw error
        }
    }

    /// A GET read as lossless JSON, naming `privileges` and `permissions`
    /// when refused. Recorded with its answer: only for reads whose answer
    /// holds no secret.
    func readJSON(_ path: String, query: [URLQueryItem] = [], privileges: [JamfPro.Privilege],
                  permissions: [String]) async throws -> LosslessJSON {
        let response = try await send(HTTPRequest(path: path, query: query, recordsBodies: true),
                                      privileges: privileges, permissions: permissions)
        do {
            return try LosslessJSON(data: response.data)
        } catch {
            throw failure(JamfPlatform.APIError(.invalidResponse("\(path) isn’t valid JSON: \(error.localizedDescription)")))
        }
    }

    /// Every page of a list read with `readJSON`, from page 0.
    ///
    /// - Parameter sizeName: the page size’s parameter: `page-size` on Jamf
    ///   Pro’s lists, `size` on Declaration Reporting’s.
    func readAllPages<Item: Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        pageSize: Int = 100,
        sizeName: String = "page-size",
        maxPages: Int = 1_000,
        privileges: [JamfPro.Privilege],
        permissions: [String],
        item: @escaping @Sendable (LosslessJSON) -> Item?
    ) async throws -> [Item] {
        try await JamfPlatform.allPages(of: path, pageSize: pageSize, maxPages: maxPages) { page in
            let paging = [URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: sizeName, value: String(pageSize))]
            let json = try await self.readJSON(path, query: paging + query, privileges: privileges, permissions: permissions)
            return try JamfPlatform.Page(json: json, item: item)
        }
    }
}

extension LosslessJSON {
    /// A string, or a number or boolean as text; nil for anything else or an
    /// empty string.
    var text: String? {
        switch self {
        case .string(let value): value.isEmpty ? nil : value
        case .number(let number): number.literal
        case .bool(let flag): flag ? "true" : "false"
        default: nil
        }
    }

    var int: Int? {
        switch self {
        case .number(let number): number.intValue ?? Double(number.literal).map { Int($0) }
        case .string(let value): Int(value)
        default: nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let flag): flag
        case .string(let value): value == "true" ? true : value == "false" ? false : nil
        default: nil
        }
    }
}
