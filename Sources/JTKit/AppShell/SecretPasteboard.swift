import AppKit

/// Copies a secret (a recovery key, a password, a PIN) to the clipboard the
/// careful way (decided by Jordy, ROADMAP step 7):
/// - marked concealed (`org.nspasteboard.ConcealedType`), so clipboard
///   managers leave it out of their history;
/// - kept on this Mac (`currentHostOnly`), not sent to other devices through
///   Universal Clipboard;
/// - cleared after 60 seconds, but only if the clipboard still holds that
///   secret: anything copied since is left alone.
@MainActor
public enum SecretPasteboard {
    /// The marker clipboard managers honour (nspasteboard.org).
    public static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    public static let clearDelay: Duration = .seconds(60)

    /// Copies the secret; returns the task that clears it, for tests.
    ///
    /// - Parameters:
    ///   - pasteboard: the general clipboard; another in tests.
    ///   - sleep: injectable for tests.
    @discardableResult
    public static func copy(
        _ secret: String,
        to pasteboard: NSPasteboard = .general,
        clearAfter delay: Duration = clearDelay,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> Task<Void, Never> {
        // not declareTypes, which would start the contents afresh without the option
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(secret, forType: .string)
        pasteboard.setString("", forType: concealedType)
        let count = pasteboard.changeCount
        return Task { @MainActor in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            // only our copy: nothing was copied since, and it is still the secret
            guard pasteboard.changeCount == count, pasteboard.string(forType: .string) == secret else { return }
            pasteboard.clearContents()
        }
    }
}
