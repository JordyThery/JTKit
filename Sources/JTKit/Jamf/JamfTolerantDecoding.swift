import Foundation

/// Any key, for records read field by field.
nonisolated struct AnyKey: CodingKey, ExpressibleByStringLiteral {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
    init(stringLiteral value: String) { stringValue = value }
}

/// Field readers that never fail: a missing field, `null` or a value of an
/// unexpected type reads as nil, so one odd field never loses a record.
/// Jamf sends the same value with different types between endpoints and
/// versions (an ID as a string or a number, a flag as a boolean, 0/1 or
/// "true").
extension KeyedDecodingContainer where Key == AnyKey {
    /// A string; a number or boolean as its text. Empty and blank strings
    /// read as nil (Jamf School sends "" for unset values).
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
        text(key).flatMap(JamfPlatform.date(from:))
    }

    /// A nested object, or nil when it is missing or can't be read.
    func object<T: Decodable>(_ type: T.Type, _ key: AnyKey) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

/// A list item that is nil when it can't be read, so one bad record doesn't
/// lose the page.
nonisolated struct Tolerant<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
