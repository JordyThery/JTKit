import Foundation

/// Where an app keeps its list of connection records: the file or
/// UserDefaults key it has always used, in its own format. JTKit includes
/// `JSONFileConnectionStorage` and `UserDefaultsConnectionStorage`; apps with
/// an unusual layout write their own.
@MainActor
public protocol ConnectionStorage<Record> {
    associatedtype Record

    /// The saved records; empty when nothing has been saved yet. Throws when
    /// saved data exists but can't be read.
    func load() throws -> [Record]

    func save(_ records: [Record]) throws

    /// Copies the data as it was before JTKit first saves it, next to the
    /// original. Does nothing when nothing is saved yet or a backup exists.
    func backUpOnce() throws

    /// Keeps a copy of data that couldn't be read, next to the original, and
    /// says where. The original stays in place.
    func keepUnreadableCopy() -> String?
}

/// How a JSON connections file is written. Keep the app's current settings so
/// the file stays byte-for-byte the same.
public nonisolated struct JSONConnectionFormat: Sendable {
    public enum Dates: Sendable {
        /// `JSONEncoder`'s default: seconds since 2001.
        case deferredToDate
        case iso8601
    }

    public var outputFormatting: JSONEncoder.OutputFormatting
    public var dates: Dates

    public init(outputFormatting: JSONEncoder.OutputFormatting = [.prettyPrinted, .sortedKeys],
                dates: Dates = .deferredToDate) {
        self.outputFormatting = outputFormatting
        self.dates = dates
    }

    func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = outputFormatting
        if case .iso8601 = dates { encoder.dateEncodingStrategy = .iso8601 }
        return encoder
    }

    func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        if case .iso8601 = dates { decoder.dateDecodingStrategy = .iso8601 }
        return decoder
    }
}

/// Names for the copies JTKit makes next to an app's data.
nonisolated enum ConnectionCopies {
    static let backupSuffix = "backup"
    static let unreadableSuffix = "unreadable"

    /// A suffix that sorts by time and never replaces an earlier copy.
    static func unreadableStamp(_ date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        return "\(unreadableSuffix)-\(formatter.string(from: date))"
    }
}

/// A JSON array of records in one file, e.g. JamfMigrator's `tenants.json`.
/// Writes are atomic. The backup is `<file>.backup`; a copy of an unreadable
/// file is `<file>.unreadable-<date and time>`.
@MainActor
public final class JSONFileConnectionStorage<Record: Codable>: ConnectionStorage {
    public let fileURL: URL
    public let format: JSONConnectionFormat

    public init(fileURL: URL, format: JSONConnectionFormat = JSONConnectionFormat()) {
        self.fileURL = fileURL
        self.format = format
    }

    public var backupURL: URL { fileURL.appendingPathExtension(ConnectionCopies.backupSuffix) }

    public func load() throws -> [Record] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try format.decoder().decode([Record].self, from: data)
    }

    public func save(_ records: [Record]) throws {
        let data = try format.encoder().encode(records)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public func backUpOnce() throws {
        let files = FileManager.default
        guard files.fileExists(atPath: fileURL.path), !files.fileExists(atPath: backupURL.path) else { return }
        try files.copyItem(at: fileURL, to: backupURL)
    }

    public func keepUnreadableCopy() -> String? {
        let copy = fileURL.appendingPathExtension(ConnectionCopies.unreadableStamp())
        do {
            try FileManager.default.copyItem(at: fileURL, to: copy)
            return copy.path
        } catch {
            return nil
        }
    }
}

/// A JSON-encoded array of records under one UserDefaults key, e.g.
/// AppSettings2Blueprint's `connectionProfiles`. The backup is kept under
/// `<key>.backup`; a copy of unreadable data under `<key>.unreadable-<date and time>`.
@MainActor
public final class UserDefaultsConnectionStorage<Record: Codable>: ConnectionStorage {
    public let key: String
    public let defaults: UserDefaults
    public let format: JSONConnectionFormat

    public init(key: String, defaults: UserDefaults = .standard,
                format: JSONConnectionFormat = JSONConnectionFormat(outputFormatting: [])) {
        self.key = key
        self.defaults = defaults
        self.format = format
    }

    public var backupKey: String { "\(key).\(ConnectionCopies.backupSuffix)" }

    public func load() throws -> [Record] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try format.decoder().decode([Record].self, from: data)
    }

    public func save(_ records: [Record]) throws {
        defaults.set(try format.encoder().encode(records), forKey: key)
    }

    public func backUpOnce() throws {
        guard let existing = defaults.object(forKey: key), defaults.object(forKey: backupKey) == nil else { return }
        defaults.set(existing, forKey: backupKey)
    }

    public func keepUnreadableCopy() -> String? {
        guard let existing = defaults.object(forKey: key) else { return nil }
        let copyKey = "\(key).\(ConnectionCopies.unreadableStamp())"
        defaults.set(existing, forKey: copyKey)
        return "the setting \(copyKey)"
    }
}
