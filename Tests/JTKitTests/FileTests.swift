import Foundation
import Testing
import UniformTypeIdentifiers
@testable import JTKit

@Suite("JSON file store")
struct JSONFileTests {
    nonisolated struct Sample: Codable, Equatable {
        var name: String
        var date: Date
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "jtkit-tests/\(UUID().uuidString)/nested/sample.json")
    }

    @Test func roundTripsThroughDiskCreatingFolders() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let value = Sample(name: "tenant", date: Date(timeIntervalSince1970: 1_700_000_000))
        try JSONFile.save(value, to: url)
        #expect(try JSONFile.load(Sample.self, from: url) == value)
    }

    /// Existing files written by the apps must keep loading: sorted keys,
    /// pretty-printed, ISO 8601 dates.
    @Test func writesTheStableFormat() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try JSONFile.save(Sample(name: "tenant", date: Date(timeIntervalSince1970: 1_700_000_000)), to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == """
        {
          "date" : "2023-11-14T22:13:20Z",
          "name" : "tenant"
        }
        """)
    }

    @Test func missingFileThrows() {
        #expect(throws: (any Error).self) {
            try JSONFile.load(Sample.self, from: temporaryURL())
        }
    }
}

@Suite("Text export document")
struct TextExportDocumentTests {
    @Test func defaultsToPlainText() {
        let document = TextExportDocument(text: "# Notes")
        #expect(document.text == "# Notes")
        #expect(document.contentType == .plainText)
    }

    @Test func exportsTheCommonTextFormats() {
        #expect(TextExportDocument.readableContentTypes == [.plainText, .html, .json, .commaSeparatedText])
        #expect(TextExportDocument(text: "a,b", contentType: .commaSeparatedText).contentType == .commaSeparatedText)
    }
}
