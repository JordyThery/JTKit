import Foundation
import UniformTypeIdentifiers

/// The private key of an Apple Business or School Manager API account: the
/// .pem file Apple offers once, when the account is created. The editor
/// imports it from that file and never shows its text.
nonisolated enum ApplePrivateKey {

    /// Why a file can’t be used, in plain language.
    public enum ImportError: LocalizedError, Equatable, Sendable {
        case empty
        case tooLarge
        case notText
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
                "The file isn’t a .pem private key."
            case .encrypted:
                "The private key is protected with a password. Use the .pem file as Apple downloaded it."
            case .notPrivateKey:
                "The file doesn’t contain a private key. Choose the .pem file downloaded when the API account was created."
            case .unreadable:
                "The file couldn’t be read."
            }
        }
    }

    /// The file types the importer offers.
    public static var contentTypes: [UTType] {
        [UTType(filenameExtension: "pem") ?? .data]
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

    /// Reads a file the person chose, inside or outside the app’s sandbox.
    public static func read(contentsOf url: URL) throws(ImportError) -> String {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { throw .unreadable }
        return try read(data)
    }
}
