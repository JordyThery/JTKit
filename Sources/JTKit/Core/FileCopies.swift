import Foundation

/// Copies an app keeps of its own files, named as JTKit names the copies of
/// saved connections.
public nonisolated enum FileCopies {
    /// `unreadable-<date and time>`: sorts by time; `keepUnreadableCopy`
    /// adds `-2`, `-3` … rather than replace an earlier copy.
    public static func unreadableStamp(_ date: Date = .now) -> String {
        ConnectionCopies.unreadableStamp(date)
    }

    /// Copies a file the app can’t read to `<file>.unreadable-<date and
    /// time>` next to it, before anything overwrites it: the bytes stay as
    /// they were, and an earlier copy is never replaced. Returns the copy’s
    /// path, for the message telling the user; nil when there is no file or
    /// the copy failed.
    @discardableResult
    public static func keepUnreadableCopy(of url: URL, date: Date = .now) -> String? {
        let files = FileManager.default
        guard files.fileExists(atPath: url.path) else { return nil }
        let stamp = unreadableStamp(date)
        for counter in 1...1_000 {
            let copy = url.appendingPathExtension(counter == 1 ? stamp : "\(stamp)-\(counter)")
            guard !files.fileExists(atPath: copy.path) else { continue }
            do {
                try files.copyItem(at: url, to: copy)
                return copy.path
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                return nil
            }
        }
        return nil
    }
}
