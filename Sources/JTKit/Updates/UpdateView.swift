import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The update sheet: release notes and a download to a location the user picks.
/// Installing stays a manual drag into Applications.
///
/// Present it from a sheet bound to `UpdateChecker.isPresented`, with the checker
/// in the environment.
@MainActor
public struct UpdateView: View {
    @Environment(UpdateChecker.self) private var checker
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var isDownloading = false
    @State private var exportDocument: ZipDocument?
    @State private var isExporting = false
    @State private var suggestedName = ""
    @State private var statusMessage: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 440)
        .frame(minHeight: 160)
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .zip,
            defaultFilename: suggestedName
        ) { result in
            switch result {
            case let .success(url):
                // the saved copy is a download too, for Gatekeeper
                if case let .available(release) = checker.status, let source = release.downloadURL {
                    try? UpdateChecker.quarantine(url, from: source, appName: checker.configuration.appName)
                }
                statusMessage = "Saved. Quit \(checker.configuration.appName) and replace it in Applications."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case let .failure(error):
                statusMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch checker.status {
        case .idle, .checking:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        case .upToDate:
            VStack(alignment: .leading, spacing: 4) {
                Text("\(checker.configuration.appName) is up to date")
                    .font(.headline)
                Text("Version \(checker.currentVersion) is the latest release.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn’t check for updates")
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        case let .available(release):
            VStack(alignment: .leading, spacing: 8) {
                Text("\(release.name) is available")
                    .font(.headline)
                Text("Installed: \(checker.currentVersion).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !release.notes.isEmpty {
                    ScrollView {
                        Text(notesText(release.notes))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 6))
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Wrap long error messages instead of cutting them off.
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            Spacer()
            if isDownloading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Downloading update")
            }
            if case let .available(release) = checker.status {
                if let page = release.pageURL {
                    Button("View on GitHub") { openURL(page) }
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Download") { download(release) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(release.downloadURL == nil || isDownloading)
            } else {
                ZStack {
                    // A button takes one shortcut, and Close already uses Return, so this
                    // invisible twin underneath makes Escape close the sheet too.
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .accessibilityHidden(true)
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// Inline Markdown: keeps bold and links, leaves list markers as typed.
    private func notesText(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    /// Downloads the zip, then hands it to a save panel so the user picks where it goes.
    private func download(_ release: UpdateChecker.Release) {
        isDownloading = true
        statusMessage = nil
        Task {
            do {
                let file = try await checker.download(release)
                exportDocument = ZipDocument(file: file)
                suggestedName = file.lastPathComponent
                isExporting = true
            } catch {
                statusMessage = error.localizedDescription
            }
            isDownloading = false
        }
    }
}

/// Minimal zip document, used only to hand a downloaded update to
/// `fileExporter`: the downloaded file, never read into memory whole.
nonisolated struct ZipDocument: FileDocument {
    static let readableContentTypes = [UTType.zip]

    var file: URL

    init(file: URL) {
        self.file = file
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: file)
    }
}
