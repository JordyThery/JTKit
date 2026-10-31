import Foundation

/// Jamf Pro’s Classic API (`JSSResource/…`, `proclassic/…` through the
/// gateway): only the plumbing the apps share. Reading and
/// writing XML payloads stays in the apps.
///
/// The calls run on `JamfPlatform.Client`, directly or through the gateway,
/// with paths written in gateway form (`proclassic/…`).
public nonisolated enum JamfClassic {
    /// `proclassic/{resource}/id/{id}`, e.g. `mobiledevices`, `12`.
    public static func path(_ resource: String, id: String) -> String {
        "proclassic/\(resource)/id/\(JamfPlatform.pathSegment(id))"
    }

    /// Where a new object is created: `proclassic/{resource}/id/0`.
    public static func createPath(_ resource: String) -> String {
        path(resource, id: "0")
    }

    /// The ID in Jamf Pro’s answer to a create or update, `<id>123</id>`.
    public static func createdID(in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let match = text.firstMatch(of: /<id>\s*(\d+)\s*<\/id>/) else { return nil }
        return String(match.1)
    }

    /// The message of a Classic error page, which is HTML (`<p>Error: Duplicate
    /// name</p>`) or XML, without the markup and the "technical details" link.
    /// Nil when the answer isn’t one.
    public static func errorMessage(in data: Data) -> String? {
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<") else { return nil }
        var parts: [String]
        let paragraphs = trimmed.matches(of: /(?is)<p[^>]*>(.*?)<\/p>/).map { String($0.1) }
        if !paragraphs.isEmpty {
            parts = paragraphs
        } else {
            // an XML error: the text of its elements
            parts = trimmed.matches(of: /(?s)>([^<]+)</).map { String($0.1) }
        }
        let cleaned = parts
            .map { $0.replacing(/<[^>]+>/, with: "") }
            .map(decodeEntities)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("technical details") }
        guard !cleaned.isEmpty else { return nil }
        var unique = [String]()
        for part in cleaned where !unique.contains(part) { unique.append(part) }
        let message = unique.joined(separator: " – ")
        return String(message.prefix(500))
    }

    /// The items of a Classic list asked for as JSON, e.g.
    /// `{"computer_groups":[…]}`: the one array in the object. Nil when the
    /// answer isn’t such a list.
    public static func listItems(_ json: LosslessJSON) -> [LosslessJSON]? {
        guard let object = json.objectValue else { return nil }
        let arrays = object.members.compactMap(\.value.arrayValue)
        guard arrays.count == 1 else { return nil }
        return arrays[0]
    }

    private static func decodeEntities(_ text: String) -> String {
        [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")]
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}

// MARK: - Groups

extension JamfClassic {
    public enum GroupKind: String, Sendable, Hashable, CaseIterable {
        case computer
        case mobileDevice

        /// `computergroups`, `mobiledevicegroups`.
        public var resource: String {
            switch self {
            case .computer: "computergroups"
            case .mobileDevice: "mobiledevicegroups"
            }
        }

        func readPrivilege(smart: Bool) -> JamfPro.Privilege {
            switch (self, smart) {
            case (.computer, true): .readSmartComputerGroups
            case (.computer, false): .readStaticComputerGroups
            case (.mobileDevice, true): .readSmartMobileDeviceGroups
            case (.mobileDevice, false): .readStaticMobileDeviceGroups
            }
        }
    }

    /// A computer or mobile device group, smart or static.
    public struct Group: Hashable, Sendable {
        public var id: String
        public var name: String
        public var isSmart: Bool
        public var kind: GroupKind

        public init(id: String, name: String, isSmart: Bool, kind: GroupKind) {
            self.id = id
            self.name = name
            self.isSmart = isSmart
            self.kind = kind
        }
    }

    /// A member of a group.
    public struct Member: Hashable, Sendable {
        public var id: String?
        public var name: String?
        /// Nil for records that never completed an inventory.
        public var serialNumber: String?
    }
}

extension JamfPlatform.Client {
    /// Every computer or mobile device group, smart and static, asked for as
    /// JSON. Needs the Read Smart and Read Static … Groups privileges.
    public func classicGroups(_ kind: JamfClassic.GroupKind) async throws -> [JamfClassic.Group] {
        let response = try await sendThrowing(HTTPRequest(path: "proclassic/\(kind.resource)", accept: "application/json"))
        guard let json = try? LosslessJSON(data: response.data), let items = JamfClassic.listItems(json) else {
            throw failure(JamfPlatform.APIError(.invalidResponse("\(kind.resource) isn’t a Classic group list.")))
        }
        return items.compactMap { item in
            guard let id = Self.text(item["id"]) else { return nil }
            return JamfClassic.Group(id: id, name: item["name"]?.stringValue ?? "Group \(id)",
                                     isSmart: item["is_smart"]?.boolValue ?? false, kind: kind)
        }
    }

    /// A group’s members, in one request.
    public func classicGroupMembers(_ group: JamfClassic.Group) async throws -> [JamfClassic.Member] {
        let response = try await sendThrowing(HTTPRequest(path: JamfClassic.path(group.kind.resource, id: group.id),
                                                          accept: "application/json"),
                                              privilege: group.kind.readPrivilege(smart: group.isSmart))
        guard let json = try? LosslessJSON(data: response.data),
              let container = json["computer_group"] ?? json["mobile_device_group"] else {
            throw failure(JamfPlatform.APIError(.invalidResponse("\(group.kind.resource)/\(group.id) isn’t a Classic group.")))
        }
        let members = (container["computers"] ?? container["mobile_devices"])?.arrayValue ?? []
        return members.map { member in
            JamfClassic.Member(id: Self.text(member["id"]), name: member["name"]?.stringValue,
                               serialNumber: member["serial_number"]?.stringValue)
        }
    }

    static func text(_ value: LosslessJSON?) -> String? {
        switch value {
        case .string(let text)?: text.isEmpty ? nil : text
        case .number(let number)?: number.literal
        default: nil
        }
    }
}
