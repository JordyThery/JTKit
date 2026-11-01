import Foundation

/// How long backups are kept. Saved as days; 0 is forever.
public nonisolated enum BackupRetention: Int, CaseIterable, Identifiable, Sendable {
    case forever = 0
    case oneYear = 365
    case ninetyDays = 90
    case thirtyDays = 30

    public var id: Int { rawValue }

    /// For a picker in Settings.
    public var title: String {
        switch self {
        case .forever: "Forever"
        case .oneYear: "1 Year"
        case .ninetyDays: "90 Days"
        case .thirtyDays: "30 Days"
        }
    }
}

/// One backup file.
public nonisolated struct TimestampedBackup: Identifiable, Hashable, Sendable {
    public let url: URL
    /// The key it was written for, e.g. a Blueprint ID.
    public let key: String
    public let date: Date
    public let size: Int

    public var id: URL { url }

    public init(url: URL, key: String, date: Date, size: Int) {
        self.url = url
        self.key = key
        self.date = date
        self.size = size
    }
}

/// Backups as the Blueprint apps keep them before every write: one folder
/// per key under `root` (`<root>/<key>/2026-10-07T14-03-11.123Z.json`),
/// the exact bytes, never overwritten, readable by the user’s account only
/// (folders 0700, files 0600), since a backup can hold another component’s
/// secrets. The app picks `root` (under the live-check switch: the run’s
/// folder).
public nonisolated struct TimestampedBackupStore: Sendable {
    public struct BackupError: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public let root: URL
    /// The file extension, without the dot.
    public let fileExtension: String

    public init(root: URL, fileExtension: String = "json") {
        self.root = root
        self.fileExtension = fileExtension
    }

    /// The folder for one key: `/` and `:` become `_`, and a key that would
    /// leave `root` (empty, `.` or `..`) gets a folder named `_`.
    public func directory(for key: String) -> URL {
        var safe = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if safe.isEmpty || safe == "." || safe == ".." { safe = "_" + safe }
        return root.appending(path: safe, directoryHint: .isDirectory)
    }

    /// File names sort chronologically and contain no colons: `2026-10-07T14-03-11.123Z`.
    private static let fileNameFormat = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)T\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))-\(minute: .twoDigits)-\(second: .twoDigits).\(secondFraction: .fractional(3))Z",
        timeZone: .gmt,
        calendar: Calendar(identifier: .gregorian)
    )

    /// Writes `data` as a new backup for `key`; a second backup in the same
    /// millisecond gets `-2`, `-3` …. Returns its address.
    @discardableResult
    public func write(_ data: Data, for key: String, date: Date = Date()) throws -> URL {
        let directory = directory(for: key)
        let files = FileManager.default
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: ownerOnly)
            // also folders made earlier with the default permissions
            try files.setAttributes(ownerOnly, ofItemAtPath: root.path(percentEncoded: false))
            try files.setAttributes(ownerOnly, ofItemAtPath: directory.path(percentEncoded: false))
            let base = date.formatted(Self.fileNameFormat)
            var counter = 1
            while true {
                let url = directory.appending(path: "\(counter == 1 ? base : "\(base)-\(counter)").\(fileExtension)")
                do {
                    // `.withoutOverwriting` creates the file exclusively, so an
                    // existing backup is never replaced; Foundation rejects it
                    // combined with `.atomic`.
                    try data.write(to: url, options: .withoutOverwriting)
                } catch CocoaError.fileWriteFileExists where counter < 10_000 {
                    counter += 1
                    continue
                }
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
                return url
            }
        } catch {
            throw BackupError(message: "Couldn’t write a backup to \(directory.path(percentEncoded: false)): \(error.localizedDescription)")
        }
    }

    /// The backups for one key, newest first. Names are compared
    /// numerically without the extension, so “-2” … “-10” list in order.
    public func backups(for key: String) -> [TimestampedBackup] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory(for: key), includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == fileExtension }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return TimestampedBackup(url: url, key: key, date: values?.creationDate ?? .distantPast, size: values?.fileSize ?? 0)
            }
            .sorted {
                $0.url.deletingPathExtension().lastPathComponent
                    .compare($1.url.deletingPathExtension().lastPathComponent, options: .numeric) == .orderedDescending
            }
    }

    /// A backup’s bytes.
    public func data(of backup: TimestampedBackup) throws -> Data {
        try Data(contentsOf: backup.url)
    }

    /// Removes backups older than `retention`, keeping each key’s newest one
    /// whatever its age (the state before its last write). Returns how many
    /// were removed.
    @discardableResult
    public func prune(_ retention: BackupRetention, now: Date = Date()) -> Int {
        guard retention != .forever,
              let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -retention.rawValue, to: now),
              let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                                         options: [.skipsHiddenFiles])
        else { return 0 }
        var removed = 0
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            for backup in backups(for: folder.lastPathComponent).dropFirst() where backup.date < cutoff {
                if (try? FileManager.default.removeItem(at: backup.url)) != nil { removed += 1 }
            }
        }
        return removed
    }
}
