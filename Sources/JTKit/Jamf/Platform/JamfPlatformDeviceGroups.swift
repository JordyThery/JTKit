import Foundation

extension JamfPlatform {
    /// A device group (`DeviceGroupListReadRepresentationV1`). Types the app
    /// doesn’t know are kept, not dropped.
    public struct DeviceGroup: Identifiable, Hashable, Sendable {
        public enum DeviceType: Hashable, Sendable {
            case computer
            case mobile
            case other(String)

            public init(rawValue: String) {
                switch rawValue {
                case "COMPUTER": self = .computer
                case "MOBILE": self = .mobile
                default: self = .other(rawValue)
                }
            }

            public var displayName: String {
                switch self {
                case .computer: "Computers"
                case .mobile: "Mobile devices"
                case .other(let raw): raw.isEmpty ? "Unknown" : raw.replacingOccurrences(of: "_", with: " ").capitalized
                }
            }
        }

        public enum GroupType: Hashable, Sendable {
            case smart
            case `static`
            case other(String)

            public init(rawValue: String) {
                switch rawValue {
                case "SMART": self = .smart
                case "STATIC": self = .static
                default: self = .other(rawValue)
                }
            }

            public var displayName: String {
                switch self {
                case .smart: "Smart"
                case .static: "Static"
                case .other(let raw): raw.isEmpty ? "Unknown" : raw.replacingOccurrences(of: "_", with: " ").capitalized
                }
            }
        }

        public var id: String
        public var name: String
        public var description: String?
        public var deviceType: DeviceType
        public var groupType: GroupType
        /// Nil when the server leaves it out.
        public var memberCount: Int?

        public init(id: String, name: String, description: String? = nil, deviceType: DeviceType,
                    groupType: GroupType, memberCount: Int? = nil) {
            self.id = id
            self.name = name
            self.description = description
            self.deviceType = deviceType
            self.groupType = groupType
            self.memberCount = memberCount
        }

        /// Only `id` is required.
        public init?(json: LosslessJSON) {
            guard let id = json["id"]?.stringValue else { return nil }
            self.init(id: id,
                      name: json["name"]?.stringValue ?? id,
                      description: json["description"]?.stringValue,
                      deviceType: DeviceType(rawValue: json["deviceType"]?.stringValue ?? ""),
                      groupType: GroupType(rawValue: json["groupType"]?.stringValue ?? ""),
                      memberCount: json["memberCount"]?.numberValue?.intValue)
        }
    }

    /// Building RSQL filters for list requests, e.g. `deviceType=="COMPUTER"`.
    enum RSQL {
        /// `field=="value"`, with quotes and backslashes in the value escaped,
        /// so a value can’t change the meaning of the filter.
        public static func equals(_ field: String, _ value: String) -> String {
            "\(field)==\(quoted(value))"
        }

        public static func quoted(_ value: String) -> String {
            "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
    }
}

extension JamfPlatform.Client {
    public static let deviceGroupsPath = "/device-groups/v1/device-groups"

    /// Every device group (permission `device-groups:read`), following all pages.
    ///
    /// - Parameters:
    ///   - filter: an RSQL filter, e.g. `deviceType=="COMPUTER"`.
    ///   - sort: by name by default.
    public func deviceGroups(filter: String? = nil, sort: String = "name", pageSize: Int = 100, maxPages: Int = 1_000) async throws -> [JamfPlatform.DeviceGroup] {
        var query = [URLQueryItem(name: "sort", value: sort)]
        if let filter, !filter.isEmpty { query.append(URLQueryItem(name: "filter", value: filter)) }
        return try await allPages(Self.deviceGroupsPath, query: query, pageSize: pageSize, maxPages: maxPages,
                                  item: JamfPlatform.DeviceGroup.init(json:))
    }
}

extension JamfPlatform {
    /// A computer or mobile device group as Jamf Pro’s `/v2/groups` lists
    /// it, with the platform ID Blueprints and Benchmarks scope to
    /// (`groupPlatformId`) next to the Jamf Pro ID.
    public struct PlatformGroup: Identifiable, Hashable, Sendable {
        /// The platform ID (`groupPlatformId`).
        public var id: String
        public var name: String
        /// The group’s ID in Jamf Pro (`groupJamfProId`).
        public var jamfProID: String?
        public var deviceType: DeviceGroup.DeviceType
        /// Nil when the server leaves it out.
        public var isSmart: Bool?
        public var memberCount: Int?

        public init(id: String, name: String, jamfProID: String? = nil, deviceType: DeviceGroup.DeviceType,
                    isSmart: Bool? = nil, memberCount: Int? = nil) {
            self.id = id
            self.name = name
            self.jamfProID = jamfProID
            self.deviceType = deviceType
            self.isSmart = isSmart
            self.memberCount = memberCount
        }

        /// Only `groupPlatformId` is required.
        public init?(json: LosslessJSON) {
            guard let id = json["groupPlatformId"]?.stringValue, !id.isEmpty else { return nil }
            self.init(id: id,
                      name: json["groupName"]?.stringValue ?? "",
                      jamfProID: json["groupJamfProId"]?.stringValue,
                      deviceType: DeviceGroup.DeviceType(rawValue: json["groupType"]?.stringValue ?? ""),
                      isSmart: json["smart"]?.boolValue,
                      memberCount: json["membershipCount"]?.numberValue?.intValue)
        }
    }
}

extension JamfPlatform.Client {
    public static let platformGroupsPath = "pro/v2/groups"

    /// Every computer and mobile device group with its platform ID
    /// (`pro/v2/groups`), through the Platform API or on a Jamf Pro server
    /// reached directly, following all pages.
    public func platformGroups(pageSize: Int = 200, maxPages: Int = 1_000) async throws -> [JamfPlatform.PlatformGroup] {
        try await allPages(Self.platformGroupsPath, pageSize: pageSize, maxPages: maxPages,
                           item: JamfPlatform.PlatformGroup.init(json:))
    }
}
