import Foundation

/// A lossless JSON tree.
///
/// Unlike `JSONSerialization` or `Codable`, this type preserves
/// - object key order,
/// - the exact literal text of numbers (`1.0` stays `1.0`, big integers keep every digit),
/// - duplicate keys (never expected, but never silently dropped).
///
/// So parts an app doesn’t understand can be sent back byte for byte, which
/// a Blueprint’s merge-patch needs: it replaces the whole `steps` array.
public nonisolated enum LosslessJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Number)
    case string(String)
    case array([LosslessJSON])
    case object(Object)

    /// A JSON number stored as its literal text.
    public struct Number: Hashable, Sendable {
        public let literal: String

        /// A number from literal text the parser has already checked.
        public init(literal: String) {
            self.literal = literal
        }

        public init(_ value: Int) {
            literal = String(value)
        }

        public var intValue: Int? { Int(literal) }
    }

    /// An ordered JSON object.
    public struct Object: Hashable, Sendable {
        public struct Member: Hashable, Sendable {
            public var key: String
            public var value: LosslessJSON

            public init(key: String, value: LosslessJSON) {
                self.key = key
                self.value = value
            }
        }

        public var members: [Member]

        public init(_ members: [Member] = []) {
            self.members = members
        }

        public init(_ pairs: KeyValuePairs<String, LosslessJSON>) {
            members = pairs.map { Member(key: $0.key, value: $0.value) }
        }

        public var keys: [String] { members.map(\.key) }
        public var isEmpty: Bool { members.isEmpty }
        public var count: Int { members.count }

        /// Reading returns the first member with the key. Writing replaces it in place
        /// (keeping its position), appends a new member, or removes it when set to nil.
        public subscript(key: String) -> LosslessJSON? {
            get { members.first { $0.key == key }?.value }
            set {
                if let index = members.firstIndex(where: { $0.key == key }) {
                    if let newValue {
                        members[index].value = newValue
                    } else {
                        members.remove(at: index)
                    }
                } else if let newValue {
                    members.append(Member(key: key, value: newValue))
                }
            }
        }
    }

    /// One step in a path through a JSON tree.
    public enum PathComponent: Hashable, Sendable, CustomStringConvertible {
        case key(String)
        case index(Int)

        public var description: String {
            switch self {
            case .key(let key): ".\(key)"
            case .index(let index): "[\(index)]"
            }
        }
    }
}

// MARK: - Convenience accessors

public nonisolated extension LosslessJSON {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var numberValue: Number? {
        if case .number(let value) = self { return value }
        return nil
    }

    var arrayValue: [LosslessJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: Object? {
        if case .object(let value) = self { return value }
        return nil
    }

    subscript(key: String) -> LosslessJSON? {
        objectValue?[key]
    }

    subscript(index: Int) -> LosslessJSON? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

// MARK: - Paths

public nonisolated extension Array where Element == LosslessJSON.PathComponent {
    /// Renders a path like `steps[0].components[2].configuration`.
    var pathString: String {
        let joined = map(\.description).joined()
        return joined.hasPrefix(".") ? String(joined.dropFirst()) : joined
    }
}

public nonisolated extension LosslessJSON {
    /// Returns the value at `path`, or nil if any component doesn’t resolve.
    func value(at path: [PathComponent]) -> LosslessJSON? {
        var current = self
        for component in path {
            switch component {
            case .key(let key):
                guard let next = current[key] else { return nil }
                current = next
            case .index(let index):
                guard let next = current[index] else { return nil }
                current = next
            }
        }
        return current
    }

    /// Replaces the value at `path`. Returns false (leaving `self` untouched) if the
    /// path doesn’t resolve to an existing container. Object keys that don’t exist
    /// yet are appended; array indices must already exist.
    @discardableResult
    mutating func setValue(_ newValue: LosslessJSON, at path: [PathComponent]) -> Bool {
        guard let first = path.first else {
            self = newValue
            return true
        }
        let rest = Array(path.dropFirst())
        switch (self, first) {
        case (.object(var object), .key(let key)):
            var child = object[key] ?? .null
            if !rest.isEmpty && object[key] == nil { return false }
            guard child.setValue(newValue, at: rest) else { return false }
            object[key] = child
            self = .object(object)
            return true
        case (.array(var array), .index(let index)):
            guard array.indices.contains(index) else { return false }
            guard array[index].setValue(newValue, at: rest) else { return false }
            self = .array(array)
            return true
        default:
            return false
        }
    }
}
