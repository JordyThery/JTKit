import Foundation
import UniformTypeIdentifiers

/// The private key of an Apple Business or Apple School Manager API account: the
/// .pem file Apple offers once, when the account is created. The editor
/// takes it pasted or from any text file (.pem, .p8, .txt), and never shows
/// its text.
nonisolated enum ApplePrivateKey {

    /// Why a file can’t be used, in plain language.
    public enum ImportError: LocalizedError, Equatable, Sendable {
        case empty
        case tooLarge
        case notText
        /// Nothing (or no text) on the clipboard.
        case nothingPasted
        case encrypted
        case notPrivateKey
        case unreadable

        public var errorDescription: String? {
            switch self {
            case .empty:
                "The file is empty."
            case .tooLarge:
                "The file is too large to be a private key."
            case .notText:
                "The file isn’t a text file with a private key."
            case .nothingPasted:
                "The clipboard holds no text. Copy the whole private key, then click Paste Key."
            case .encrypted:
                "The private key is protected with a password. Use the key as Apple downloaded it."
            case .notPrivateKey:
                "That isn’t a private key. Use the whole key downloaded when the API account was created."
            case .unreadable:
                "The file couldn’t be read."
            }
        }
    }

    /// The file types the importer offers: .pem, .p8 and any text file. The
    /// contents decide, not the name.
    public static var contentTypes: [UTType] {
        var types = ["pem", "p8"].compactMap { UTType(filenameExtension: $0) }
        types += [.plainText, .text]
        return types
    }

    /// A key file is a few hundred bytes; this leaves plenty of room.
    static let maximumSize = 64 * 1024

    private static let headers = ["PRIVATE KEY", "EC PRIVATE KEY"]

    /// The key as it is stored: the file’s text without surrounding white space.
    public static func read(_ data: Data) throws(ImportError) -> String {
        guard !data.isEmpty else { throw .empty }
        guard data.count <= maximumSize else { throw .tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw .notText }
        let pem = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pem.isEmpty else { throw .empty }
        if pem.contains("-----BEGIN ENCRYPTED PRIVATE KEY-----") { throw .encrypted }
        let hasKey = headers.contains { label in
            pem.contains("-----BEGIN \(label)-----") && pem.contains("-----END \(label)-----")
        }
        guard hasKey else { throw .notPrivateKey }
        return pem
    }

    /// A key pasted from the clipboard; nil is nothing pasted.
    public static func read(pasted text: String?) throws(ImportError) -> String {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .nothingPasted }
        return try read(Data(text.utf8))
    }

    /// Reads a file the person chose, inside or outside the app’s sandbox.
    public static func read(contentsOf url: URL) throws(ImportError) -> String {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw .unreadable }
        return try read(data)
    }
}
