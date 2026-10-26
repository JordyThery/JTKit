import Foundation

/// A device, person or network identifier found in an activity entry.
public nonisolated struct FoundIdentifier: Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// Serial number, UDID, IMEI/MEID/EID, MAC address, device name.
        case device
        /// Email address, username, full name.
        case user
        /// IP address.
        case address
    }

    public var kind: Kind
    public var value: String

    public init(_ kind: Kind, _ value: String) {
        self.kind = kind
        self.value = value
    }
}

/// Replaces identifiers with stable placeholders (`<device 1>`, `<user 1>`,
/// `<address 1>`) for the bug-report export.
///
/// Identifiers are collected when an entry is recorded (`identifiers(in…)`),
/// and masked only at export, so the log itself and a copied entry stay
/// readable. Each value gets the same placeholder everywhere in one export,
/// numbered per kind in the order the values first appeared. Generic names
/// (a Blueprint's, a group's) are never collected; device names only where a
/// field clearly holds one.
public nonisolated struct IdentifierMasker: Sendable {
    private let assigned: [String: String]
    private let pattern: NSRegularExpression?

    /// - Parameter identifiers: in the order they appeared, oldest first.
    public init(_ identifiers: [FoundIdentifier]) {
        var assigned = [String: String]()
        var counts = [FoundIdentifier.Kind: Int]()
        for identifier in identifiers {
            let key = identifier.value.lowercased()
            guard Self.isMaskable(identifier.value), assigned[key] == nil else { continue }
            let number = (counts[identifier.kind] ?? 0) + 1
            counts[identifier.kind] = number
            assigned[key] = "<\(identifier.kind.rawValue) \(number)>"
        }
        self.assigned = assigned
        // One pass, longest values first, so a shorter value can never be
        // replaced inside a longer one or inside a placeholder already written.
        let alternatives = assigned.keys
            .sorted { ($0.count, $0) > ($1.count, $1) }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        pattern = alternatives.isEmpty ? nil : try? NSRegularExpression(
            pattern: "(?<![A-Za-z0-9])(?:\(alternatives.joined(separator: "|")))(?![A-Za-z0-9])",
            options: [.caseInsensitive]
        )
    }

    /// The placeholder for a value, or nil when it isn't masked.
    public func placeholder(for value: String) -> String? {
        assigned[value.lowercased()]
    }

    public func mask(_ text: String) -> String {
        guard let pattern else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let found = source.substring(with: match.range)
            result += assigned[found.lowercased()] ?? found
            last = match.range.location + match.range.length
        }
        result += source.substring(from: last)
        return result
    }

    /// Too short or too common to mask without hiding ordinary words.
    static func isMaskable(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed == value else { return false }
        return !["null", "none", "unknown", "n/a", "true", "false"].contains(trimmed.lowercased())
    }

    // MARK: - Collecting

    /// Keys whose values identify a device.
    static let deviceKeys: Set<String> = Set([
        "serialNumber", "serial_number", "serialnumber", "serials", "serialNumbers",
        "udid", "udids", "imei", "meid", "eid",
        "wifiMacAddress", "wifi_mac_address", "ethernetMacAddress", "bluetoothMacAddress", "bluetooth_mac_address",
        "macAddress", "mac_address", "altMacAddress", "alt_mac_address",
        "WiFiMAC", "bluetoothMAC",
    ].map { $0.lowercased() })

    /// Keys that clearly hold a device's name.
    static let deviceNameKeys: Set<String> = ["devicename", "device_name", "computername", "computer_name"]

    /// Keys whose values identify a person.
    static let userKeys: Set<String> = Set([
        "username", "user_name", "realName", "real_name", "fullName", "full_name",
        "email", "emailAddress", "email_address", "userPrincipalName", "user_principal_name",
    ].map { $0.lowercased() })

    /// Keys whose values are IP addresses.
    static let addressKeys: Set<String> = Set([
        "ipAddress", "ip_address", "lastIpAddress", "last_ip_address", "lastReportedIp", "last_reported_ip",
        "reportedIpAddress", "reported_ip_address", "ipv4Address", "ipv6Address",
    ].map { $0.lowercased() })

    /// Status items (`{"key": "device.identifier.serial-number", "value": …}`).
    static let identifierStatusItems: Set<String> = ["device.identifier.serial-number", "device.identifier.udid"]

    static func kind(forKey key: String) -> FoundIdentifier.Kind? {
        let lowered = key.lowercased()
        if deviceKeys.contains(lowered) || deviceNameKeys.contains(lowered) { return .device }
        if userKeys.contains(lowered) { return .user }
        if addressKeys.contains(lowered) { return .address }
        return nil
    }

    /// Identifiers in a body: JSON by key, XML by element, plus email
    /// addresses anywhere in the text.
    public static func identifiers(inBody data: Data) -> [FoundIdentifier] {
        guard !data.isEmpty else { return [] }
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return unique(identifiers(inJSON: object) + identifiers(inText: String(decoding: data, as: UTF8.self)))
        }
        let text = String(decoding: data, as: UTF8.self)
        var found = [FoundIdentifier]()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<"),
           let document = try? XMLDocument(data: data, options: []),
           let root = document.rootElement() {
            found += identifiers(inXML: root)
        }
        return unique(found + identifiers(inText: text))
    }

    static func identifiers(inJSON value: Any) -> [FoundIdentifier] {
        var found = [FoundIdentifier]()
        if let dictionary = value as? [String: Any] {
            if let key = dictionary["key"] as? String, identifierStatusItems.contains(key) {
                found += strings(in: dictionary["value"] as Any).map { FoundIdentifier(.device, $0) }
            }
            // a device record: its plain "name" is the device's name
            let isDeviceRecord = dictionary.keys.contains { deviceKeys.contains($0.lowercased()) }
            for key in dictionary.keys.sorted() {
                let inner = dictionary[key] as Any
                if let kind = kind(forKey: key) {
                    found += strings(in: inner)
                        .filter { kind != .address || looksLikeIPAddress($0) }
                        .map { FoundIdentifier(kind, $0) }
                } else if isDeviceRecord && key.lowercased() == "name" {
                    found += strings(in: inner).map { FoundIdentifier(.device, $0) }
                }
                found += identifiers(inJSON: inner)
            }
        } else if let array = value as? [Any] {
            found += array.flatMap(identifiers(inJSON:))
        }
        return found
    }

    static func identifiers(inXML element: XMLElement) -> [FoundIdentifier] {
        var found = [FoundIdentifier]()
        let children = (element.children ?? []).compactMap { $0 as? XMLElement }
        let leaves = children.filter { ($0.children ?? []).allSatisfy { $0.kind == .text } }
        let elementName = element.name?.lowercased() ?? ""
        let isDeviceRecord = leaves.contains { deviceKeys.contains($0.name?.lowercased() ?? "") }
        for leaf in leaves {
            let name = leaf.name ?? ""
            let value = leaf.stringValue ?? ""
            guard !value.isEmpty else { continue }
            if let kind = kind(forKey: name) {
                if kind != .address || looksLikeIPAddress(value) { found.append(FoundIdentifier(kind, value)) }
            } else if name.lowercased() == "name" {
                if isDeviceRecord {
                    found.append(FoundIdentifier(.device, value))
                } else if elementName == "user" {
                    // Classic API scope: <user><name>…</name></user> is a username
                    found.append(FoundIdentifier(.user, value))
                }
            }
        }
        for child in children where !leaves.contains(child) {
            found += identifiers(inXML: child)
        }
        return found
    }

    /// Identifiers in a request path and query: values that look like a
    /// serial number, Apple's UDID formats, and a UUID right after `udid`.
    /// A plain UUID elsewhere is an object ID (a Blueprint, a group), not a device.
    public static func identifiers(inPath path: String) -> [FoundIdentifier] {
        let decoded = path.removingPercentEncoding ?? path
        let separators = CharacterSet(charactersIn: "/?&=\"',;:()[]{} ")
        let segments = decoded.components(separatedBy: separators).filter { !$0.isEmpty }
        var found = [FoundIdentifier]()
        for (index, segment) in segments.enumerated() {
            let previous = index > 0 ? segments[index - 1].lowercased() : ""
            if looksLikeSerialNumber(segment) || looksLikeDeviceUDID(segment)
                || (["udid", "udids"].contains(previous) && UUID(uuidString: segment) != nil) {
                found.append(FoundIdentifier(.device, segment))
            }
        }
        return unique(found + identifiers(inText: decoded))
    }

    /// Email addresses anywhere in free text.
    public static func identifiers(inText text: String) -> [FoundIdentifier] {
        text.matches(of: emailPattern).map { FoundIdentifier(.user, String(text[$0.range])) }
    }

    private nonisolated(unsafe) static let emailPattern = /[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)*\.[A-Za-z]{2,}/

    /// 10 to 12 uppercase letters and digits, with at least one of each.
    static func looksLikeSerialNumber(_ text: String) -> Bool {
        (10...12).contains(text.count)
            && text.allSatisfy { ($0.isASCII && $0.isUppercase) || ($0.isASCII && $0.isNumber) }
            && text.contains(where: \.isNumber) && text.contains(where: \.isLetter)
    }

    /// Apple silicon UDIDs (`00008103-001A2C3E0C38001E`) and 40-character ones.
    static func looksLikeDeviceUDID(_ text: String) -> Bool {
        text.wholeMatch(of: /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}/) != nil
            || text.wholeMatch(of: /[0-9A-Fa-f]{40}/) != nil
    }

    static func looksLikeIPAddress(_ text: String) -> Bool {
        text.wholeMatch(of: /(?:\d{1,3}\.){3}\d{1,3}/) != nil
            || (text.contains(":") && text.wholeMatch(of: /[0-9A-Fa-f:.]{3,45}/) != nil)
    }

    private static func strings(in value: Any) -> [String] {
        if let string = value as? String { return string.isEmpty ? [] : [string] }
        if let array = value as? [Any] { return array.flatMap(strings(in:)) }
        return []
    }

    static func unique(_ identifiers: [FoundIdentifier]) -> [FoundIdentifier] {
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0.value.lowercased()).inserted }
    }
}
