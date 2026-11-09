import Foundation

/// An Apple OS version such as `27.0.1`, compared by number (`27.10` is newer
/// than `27.9`; a missing part counts as 0, so `27` equals `27.0`). A Rapid
/// Security Response’s letter (`26.3.1 (a)`) is kept as `extra` and makes the
/// version a little newer than the same one without it.
public struct OSVersion: Sendable, Hashable, Comparable, Codable, LosslessStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    /// e.g. `(a)`.
    public var extra: String?

    public init(major: Int, minor: Int = 0, patch: Int = 0, extra: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.extra = extra
    }

    /// Reads a version string only: `27`, `27.1`, `27.0.1`, optionally after
    /// a name (`iOS 27.1`, `macOS Golden Gate 27.2`, `Sequoia 15`) and with a
    /// Rapid Security Response’s letter (`26.3.1 (a)`). Anything else is nil:
    /// a build (`23A344`), a model identifier (`iPad13,18`), four parts.
    public init?(_ description: String) {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:[A-Za-z][A-Za-z ]*\s)?([0-9]+(?:\.[0-9]+){0,2})(?:\s*(\([a-z]\)))?$"#
        guard let match = text.firstMatch(of: try! Regex(pattern)),
              let number = match.output[1].substring else { return nil }
        let parts = number.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return nil }
        let extra = match.output.count > 2 ? match.output[2].substring.map(String.init) : nil
        self.init(major: major, minor: parts.count > 1 ? parts[1] : 0, patch: parts.count > 2 ? parts[2] : 0, extra: extra)
    }

    /// `27.0.1`; `27.1` without a patch; `27` for a major alone is written `27.0`.
    public var description: String {
        var text = patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
        if let extra { text += " \(extra)" }
        return text
    }

    public static func < (lhs: OSVersion, rhs: OSVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        return (lhs.extra ?? "") < (rhs.extra ?? "")
    }

    /// Equal by number and extra; `27` and `27.0` are the same version.
    public static func == (lhs: OSVersion, rhs: OSVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch && lhs.extra == rhs.extra
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(extra)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = OSVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "“\(text)” isn’t a version."))
        }
        self = version
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
