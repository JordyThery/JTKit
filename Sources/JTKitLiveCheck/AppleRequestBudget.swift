import Foundation

/// Keeps a live check well under Apple's limit of about 18 requests a minute
/// per organisation (0.12.4): every request to an Apple organisation, sign-in
/// included, waits until fewer than `perMinute` were sent in the last
/// `window`, and once `perRun` were sent in the whole run the next is refused.
///
/// With a file (the run's `apple-requests.jsonl`) the count is shared by
/// every test process of the run; each line is one request: role and time,
/// nothing else. Without one it's kept per process.
public nonisolated final class AppleRequestBudget: @unchecked Sendable {
    public let perMinute: Int
    public let perRun: Int
    public let window: TimeInterval
    let file: URL?

    private let lock = NSLock()
    private var memory: [Entry] = []

    struct Entry: Codable { var role: String; var time: Double }

    public init(perMinute: Int = 9, perRun: Int = 40, window: TimeInterval = 60, file: URL? = nil) {
        self.perMinute = max(perMinute, 1)
        self.perRun = max(perRun, 1)
        self.window = window
        self.file = file
    }

    enum Answer: Equatable {
        case go
        case wait(TimeInterval)
        case refuse(String)
    }

    /// Takes one request for `role` when the budget allows it now.
    func claim(role: String, now: Date = Date()) -> Answer {
        lock.withLock {
            guard let file else {
                let answer = decide(role: role, entries: memory, now: now)
                if answer == .go { memory.append(Entry(role: role, time: now.timeIntervalSince1970)) }
                return answer
            }
            return Self.withLockedFile(file) { entries in
                let answer = decide(role: role, entries: entries, now: now)
                return (answer, answer == .go ? Entry(role: role, time: now.timeIntervalSince1970) : nil)
            } ?? .refuse("The run's Apple request count can't be read, so no Apple request is sent")
        }
    }

    private func decide(role: String, entries: [Entry], now: Date) -> Answer {
        let mine = entries.filter { $0.role == role }
        guard mine.count < perRun else {
            return .refuse("\(role) has used this run's Apple budget (\(perRun) requests)")
        }
        let since = now.timeIntervalSince1970 - window
        let recent = mine.map(\.time).filter { $0 > since }.sorted()
        guard recent.count >= perMinute else { return .go }
        // The oldest request that still counts has to leave the window first.
        return .wait(max(recent[recent.count - perMinute] - since, 0.01))
    }

    /// Requests per role in a run's file.
    public static func counts(in file: URL) -> [String: Int] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        let entries = text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Entry.self, from: Data($0.utf8)) }
        return Dictionary(grouping: entries, by: \.role).mapValues(\.count)
    }

    /// Reads the file under an exclusive lock (other test processes wait),
    /// lets `body` decide, and appends the entry it returns.
    private static func withLockedFile(_ file: URL, _ body: ([Entry]) -> (Answer, Entry?)) -> Answer? {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return nil }
        defer { flock(descriptor, LOCK_UN) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        lseek(descriptor, 0, SEEK_SET)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        let entries = String(decoding: data, as: UTF8.self).split(separator: "\n")
            .compactMap { try? JSONDecoder().decode(Entry.self, from: Data($0.utf8)) }
        let (answer, entry) = body(entries)
        if let entry, let line = try? JSONEncoder().encode(entry) {
            let bytes = line + Data("\n".utf8)
            let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if written != bytes.count { return .refuse("The run's Apple request count can't be written, so no Apple request is sent") }
        }
        return answer
    }
}
