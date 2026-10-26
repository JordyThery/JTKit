import SwiftUI

/// The Activity Log window, the same in every app: Window › Activity Log (⇧⌘L).
///
/// ```swift
/// ActivityLogWindow(log: activityLog, emptyDescription: "Calls to Jamf appear here as they happen.")
/// ```
public struct ActivityLogWindow: Scene {
    /// The window's scene identifier, for `openWindow(id:)`.
    public static let id = "activity-log"

    private let log: ActivityLog
    private let emptyDescription: String
    private let app: ActivityLogAppInfo

    /// - Parameters:
    ///   - emptyDescription: what will appear, shown while the log is empty.
    ///   - app: named at the top of an export; the running app by default.
    public init(log: ActivityLog, emptyDescription: String, app: ActivityLogAppInfo = .current) {
        self.log = log
        self.emptyDescription = emptyDescription
        self.app = app
    }

    public var body: some Scene {
        Window("Activity Log", id: Self.id) {
            ActivityLogView(log: log, emptyDescription: emptyDescription, app: app)
                .frame(minWidth: 640, minHeight: 320)
        }
        .defaultSize(width: 1000, height: 650)
        .keyboardShortcut("l", modifiers: [.command, .shift])
        .commands { ActivityLogCommands() }
    }
}

/// The window's toolbar actions in the menu bar, so every command is there
/// too: File › Export…, Edit › Clear Activity Log…, View › Show Problems Only.
/// Dimmed unless the Activity Log window is in front.
struct ActivityLogCommands: Commands {
    @FocusedValue(\.activityLogActions) private var actions

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Export Activity Log for Bug Report…") { actions?.export(true) }
                .disabled(!(actions?.hasEntries ?? false))
            Button("Export Activity Log Unmasked…") { actions?.export(false) }
                .disabled(!(actions?.hasEntries ?? false))
        }
        CommandGroup(after: .pasteboard) {
            Button("Clear Activity Log…") { actions?.clear() }
                .disabled(!(actions?.hasEntries ?? false))
        }
        CommandGroup(after: .toolbar) {
            Toggle("Show Problems Only", isOn: Binding(
                get: { actions?.problemsOnly ?? false },
                set: { actions?.setProblemsOnly($0) }))
                .disabled(actions == nil)
        }
    }
}

@MainActor
struct ActivityLogActions {
    let hasEntries: Bool
    let problemsOnly: Bool
    let export: (_ masked: Bool) -> Void
    let clear: () -> Void
    let setProblemsOnly: (Bool) -> Void
}

struct ActivityLogActionsKey: FocusedValueKey {
    typealias Value = ActivityLogActions
}

extension FocusedValues {
    var activityLogActions: ActivityLogActions? {
        get { self[ActivityLogActionsKey.self] }
        set { self[ActivityLogActionsKey.self] = newValue }
    }
}

/// Newest-first table of activity entries with the selected entry's details
/// below it, for the Activity Log window. Search matches every column,
/// including the source; "Problems Only" shows failures and warnings.
@MainActor
public struct ActivityLogView: View {
    private var log: ActivityLog
    private let emptyDescription: String
    private let app: ActivityLogAppInfo

    @State private var search = ""
    @State private var problemsOnly = false
    @State private var selection: ActivityLogEntry.ID?
    @State private var confirmingClear = false
    @State private var export: PendingExport?

    public init(log: ActivityLog, emptyDescription: String, app: ActivityLogAppInfo = .current) {
        self.log = log
        self.emptyDescription = emptyDescription
        self.app = app
    }

    private struct PendingExport {
        var document: TextExportDocument
        var filename: String
    }

    private var rows: [ActivityLogEntry] {
        log.entries.reversed().filter { entry in
            (!problemsOnly || entry.isProblem) && ActivityLogSearch.matches(entry, search)
        }
    }

    private var selectedEntry: ActivityLogEntry? {
        selection.flatMap { id in log.entries.first { $0.id == id } }
    }

    private var isFiltering: Bool {
        problemsOnly || !search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Activity Log")
                .navigationSubtitle(subtitle)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .toolbar { toolbarContent }
        .focusedSceneValue(\.activityLogActions, ActivityLogActions(
            hasEntries: !log.entries.isEmpty,
            problemsOnly: problemsOnly,
            export: { prepareExport(masked: $0) },
            clear: { confirmingClear = true },
            setProblemsOnly: { problemsOnly = $0 }
        ))
        .confirmationDialog("Clear the activity log?", isPresented: $confirmingClear) {
            // chosen on purpose, so not styled destructive (HIG, Alerts)
            Button("Clear") {
                selection = nil
                log.clear()
            }
        } message: {
            Text("The log is kept in memory only and can’t be recovered.")
        }
        .fileExporter(
            isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
            document: export?.document,
            contentType: .plainText,
            defaultFilename: export?.filename
        ) { _ in }
    }

    private var subtitle: String {
        let total = log.entries.count
        let noun = total == 1 ? "entry" : "entries"
        return isFiltering ? "\(rows.count) of \(total) \(noun)" : "\(total) \(noun)"
    }

    @ViewBuilder
    private var content: some View {
        if log.entries.isEmpty {
            ContentUnavailableView(
                "No Activity Yet",
                systemImage: "list.bullet.rectangle",
                description: Text(emptyDescription)
            )
        } else {
            VSplitView {
                table
                    .frame(minHeight: 150, idealHeight: 380)
                detailPane
                    .frame(minHeight: 110, idealHeight: 220)
            }
        }
    }

    @ViewBuilder
    private var table: some View {
        let rows = rows
        if rows.isEmpty {
            if search.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView(
                    "No Problems",
                    systemImage: "checkmark.circle",
                    description: Text("No failures or warnings have been recorded.")
                )
            } else {
                ContentUnavailableView.search(text: search)
            }
        } else {
            Table(rows, selection: $selection) {
                TableColumn("Time") { entry in
                    Text(entry.date, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 80)
                TableColumn("Source") { entry in
                    Text(entry.category)
                        .foregroundStyle(.secondary)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Operation") { entry in
                    Text(entry.operation)
                        .font(.body.monospaced())
                }
                .width(min: 50, ideal: 70)
                TableColumn("Detail") { entry in
                    Text(entry.detail)
                        // requests and commands read as code; app messages as text
                        .font(entry.operation.isEmpty ? .body : .body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.detail)
                }
                .width(min: 150, ideal: 360)
                TableColumn("Status") { entry in
                    StatusCell(entry: entry)
                }
                .width(min: 50, ideal: 60)
                TableColumn("Duration") { entry in
                    if let duration = entry.duration {
                        Text(String(format: "%.2fs", duration))
                            .monospacedDigit()
                    }
                }
                .width(min: 50, ideal: 64)
                TableColumn("Note") { entry in
                    Text(entry.note ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(entry.note ?? "")
                }
                .width(min: 80, ideal: 220)
            }
            // Edit › Copy (⌘C) copies the selected entry, unmasked
            .onCopyCommand {
                guard let entry = selectedEntry else { return [] }
                return [NSItemProvider(object: ActivityLogExport.transcript(of: entry) as NSString)]
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let entry = selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text([entry.operation, entry.category].first { !$0.isEmpty } ?? "Entry")
                        .font(.headline)
                    Text(entry.date.formatted(date: .abbreviated, time: .standard))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Entry", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ActivityLogExport.transcript(of: entry), forType: .string)
                    }
                    .help("Copy everything recorded about this entry, unmasked")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                ScrollView {
                    Text(ActivityLogExport.transcript(of: entry))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .background(.background)
        } else {
            ContentUnavailableView(
                "No Entry Selected",
                systemImage: "text.below.rectangle",
                description: Text("Select an entry to see what was sent and received.")
            )
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Toggle("Problems Only", systemImage: "exclamationmark.triangle", isOn: $problemsOnly)
                .help("Show only failures and warnings")
            Menu("Export", systemImage: "square.and.arrow.up") {
                Button("Export for Bug Report…") { prepareExport(masked: true) }
                Button("Export Unmasked…") { prepareExport(masked: false) }
            }
            .help("Export the whole log as text. The bug report replaces serial numbers, user names and other identifiers with placeholders.")
            .disabled(log.entries.isEmpty)
            Button("Clear", systemImage: "trash") {
                confirmingClear = true
            }
            .help("Clear the activity log")
            .disabled(log.entries.isEmpty)
        }
    }

    private func prepareExport(masked: Bool) {
        let text = ActivityLogExport.text(log.entries, masked: masked, app: app)
        export = PendingExport(
            document: TextExportDocument(text: text),
            filename: masked ? "\(app.name) Activity Log" : "\(app.name) Activity Log (Unmasked)"
        )
    }
}

/// The status, red with a failure symbol when failed, a warning symbol for
/// warnings: colour is never the only signal, and VoiceOver hears the meaning.
private struct StatusCell: View {
    let entry: ActivityLogEntry

    var body: some View {
        HStack(spacing: 4) {
            if let status = entry.status {
                Text("\(status)")
                    .monospacedDigit()
                    .foregroundStyle(entry.isFailure ? .red : .primary)
            } else if entry.isFailure {
                // failed without a response
                Text("—")
                    .foregroundStyle(.red)
            }
            if entry.isFailure {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            } else if entry.isWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [String]()
        if let status = entry.status { parts.append("\(status)") }
        if entry.isFailure { parts.append(entry.status == nil ? "Failed, no response" : "failed") }
        if entry.isWarning && !entry.isFailure { parts.append("Warning") }
        return parts.joined(separator: ", ")
    }
}

/// What the search field matches: every column, the source included, plus the
/// service, the connection and the address.
nonisolated enum ActivityLogSearch {
    static func matches(_ entry: ActivityLogEntry, _ search: String) -> Bool {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        let fields = [
            entry.category, entry.operation, entry.detail, entry.note ?? "",
            entry.status.map(String.init) ?? "", entry.service ?? "", entry.connection ?? "",
            entry.request?.url ?? "",
        ]
        return fields.contains { $0.localizedCaseInsensitiveContains(text) }
    }
}

#if DEBUG
#Preview {
    let log = ActivityLog()
    log.append(ActivityLogEntry(category: "Sign-in", operation: "POST", detail: "/auth/token", status: 200, duration: 0.31,
                                service: "Jamf Platform API", connection: "Sandbox",
                                request: ActivityRequestDetails(url: "https://us.api.jamfcloud.com/auth/token",
                                                                requestHeaders: [HTTPHeader(name: "Accept", value: "application/json")],
                                                                bodyNote: "Request body not recorded.")))
    log.append(ActivityLogEntry(category: "Retry", operation: "GET", detail: "/device-groups/v1/device-groups",
                                note: "HTTP 429: waiting 12 s, attempt 2 of 4.", isWarning: true))
    log.append(ActivityLogEntry(category: "API", operation: "POST", detail: "/blueprints/v1/blueprints", status: 400, duration: 0.23,
                                note: "Bad Request"))
    log.append(ActivityLogEntry(category: "App", operation: "", detail: "Current tenant is now “Sandbox”."))
    return ActivityLogView(log: log, emptyDescription: "Calls to Jamf appear here as they happen.")
        .frame(width: 1000, height: 600)
}
#endif
