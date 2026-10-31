import SwiftUI
import UniformTypeIdentifiers

/// Plain-text file export (Markdown, HTML, JSON, CSV) for `.fileExporter`.
public nonisolated struct TextExportDocument: FileDocument {
    public static let readableContentTypes: [UTType] = [
        .plainText, .html, .json, .commaSeparatedText,
    ]

    public var text: String

    public init(text: String) {
        self.text = text
    }

    /// Export only: nothing opens these.
    public init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
