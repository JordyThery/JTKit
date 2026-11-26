import Foundation

// What the content caching types need from the rest of JTKit, so this
// target builds on Foundation alone (1.12.0). Internal copies of JTKit’s
// tolerant field readers (`JamfTolerantDecoding.swift`), its ISO 8601 and
// server-time parsing (`JamfPlatform.date(from:)`, `JamfPro.serverDate`) and
// its `{key=value, …}` field reader (`SoftwareUpdateStatus.field`); keep
// them in step with those.

/// One item of a device’s DDM status report, as Jamf Pro keeps it
/// (`JamfPro.StatusItem` in JTKit).
public nonisolated struct DDMStatusItem: Hashable, Sendable {
    /// The JSON type a value came in.
    public enum ValueKind: String, Hashable, Sendable {
        case string, number, boolean, object, array, null
    }

    public var key: String
    /// The value as text: a number as written, a boolean as `true` or
    /// `false`, an object or a list as compact JSON.
    public var value: String?
    /// As Jamf Pro writes it: the server’s local time, without a zone.
    public var lastUpdateTime: String?
    /// The type the value came in (`statusItems(managementID:kind:)`);
    /// nil for an item made another way.
    public var valueKind: ValueKind?

    public init(key: String, value: String? = nil, lastUpdateTime: String? = nil) {
        self.key = key
        self.value = value
        self.lastUpdateTime = lastUpdateTime
    }
}

/// Any key, for records read field by field.
nonisolated struct AnyKey: CodingKey, ExpressibleByStringLiteral {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(stringLiteral value: String) { stringValue = value }
}

/// Field readers that never fail: a missing field, `null` or a value of an
/// unexpected type reads as nil.
extension KeyedDecodingContainer where Key == AnyKey {
    /// A string; a number or boolean as its text. Empty and blank strings read as nil.
    func text(_ key: AnyKey) -> String? {
        let value: String?
        if let string = try? decodeIfPresent(String.self, forKey: key) { value = string }
        else if let int = try? decodeIfPresent(Int.self, forKey: key) { value = String(int) }
        else if let double = try? decodeIfPresent(Double.self, forKey: key) { value = String(double) }
        else if let bool = try? decodeIfPresent(Bool.self, forKey: key) { value = String(bool) }
        else { value = nil }
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// A boolean, or a number (non-zero is true), or "true"/"false"/"1"/"0".
    func flag(_ key: AnyKey) -> Bool? {
        if let bool = try? decodeIfPresent(Bool.self, forKey: key) { return bool }
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return int != 0 }
        switch (try? decodeIfPresent(String.self, forKey: key))?.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }

    /// A whole number, or a string holding one.
    func number(_ key: AnyKey) -> Int? {
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return int }
        if let double = try? decodeIfPresent(Double.self, forKey: key), double.isFinite { return Int(double) }
        return (try? decodeIfPresent(String.self, forKey: key)).flatMap { Int($0) }
    }

    /// An ISO 8601 date, with or without fractional seconds.
    func date(_ key: AnyKey) -> Date? {
        text(key).flatMap(ServerTime.iso8601)
    }

    /// A nested object, or nil when it is missing or can’t be read.
    func object<T: Decodable>(_ type: T.Type, _ key: AnyKey) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// A list item that is nil when it can’t be read, so one bad record doesn’t lose the list.
nonisolated struct Tolerant<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

nonisolated enum ServerTime {
    /// The API’s ISO 8601 timestamps, with or without fractional seconds.
    static func iso8601(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
    }

    /// A time Jamf Pro writes in its own local time without a zone
    /// (`2026-11-09T14:05:31`, optionally with fractions of a second), as a
    /// date in `timeZone`. A time with a zone or `Z` keeps its own zone.
    static func date(_ text: String, timeZone: TimeZone) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let date = iso8601(trimmed), trimmed.hasSuffix("Z") || trimmed.range(of: "[+-][0-9]{2}:?[0-9]{2}$", options: .regularExpression) != nil {
            return date
        }
        let base = String(trimmed.prefix(19))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: base)
    }
}

nonisolated enum FlattenedFields {
    /// `sub=value` in a `{key=value, …}` text, or `"sub": value` in JSON.
    static func field(_ sub: String, in text: String) -> String? {
        allFields(sub, in: text).first
    }

    /// Every value of `sub`: `"sub": "value"` (or a bare value) in JSON,
    /// else `sub=value` in Java’s `{key=value, …}` text, where a value
    /// runs to the next comma or closing brace and keeps its quotes.
    static func allFields(_ sub: String, in text: String) -> [String] {
        let name = NSRegularExpression.escapedPattern(for: sub)
        let isJSON = text.range(of: "\"\(name)\"\\s*:", options: .regularExpression) != nil
        let patterns = isJSON
            ? ["\"\(name)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"", "\"\(name)\"\\s*:\\s*([^,}\\]\"]+)"]
            : ["(?:^|[{\\[ ,])\(name)=([^,}\\]]*)"]
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let values = regex.matches(in: text, range: range).compactMap { match in
                Range(match.range(at: 1), in: text).map { text[$0].trimmingCharacters(in: .whitespaces) }
            }.filter { !$0.isEmpty && $0 != "null" }
            if !values.isEmpty { return values }
        }
        return []
    }

    static func bool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "1", "yes": true
        case "false", "0", "no": false
        default: nil
        }
    }
}
