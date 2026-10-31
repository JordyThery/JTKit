import Foundation

/// The app and system named at the top of an activity log export.
public nonisolated struct ActivityLogAppInfo: Sendable, Hashable {
    public var name: String
    public var version: String
    public var build: String
    public var system: String

    public init(name: String, version: String, build: String = "", system: String) {
        self.name = name
        self.version = version
        self.build = build
        self.system = system
    }

    /// The running app, from its Info.plist, and this Mac’s macOS version.
    public static var current: ActivityLogAppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return ActivityLogAppInfo(
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? ProcessInfo.processInfo.processName,
            version: info["CFBundleShortVersionString"] as? String ?? "",
            build: info["CFBundleVersion"] as? String ?? "",
            system: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
    }
}

/// Plain-text activity log: one entry (the detail pane, Copy) or the whole
/// log (the exports). "Export for Bug Report…" masks identifiers;
/// "Export Unmasked…" and a copied entry don’t.
public nonisolated enum ActivityLogExport {
    static let separator = String(repeating: "-", count: 72)

    /// Everything recorded about one entry, unmasked.
    public static func transcript(of entry: ActivityLogEntry) -> String {
        transcript(of: entry, dateFormatter: makeDateFormatter())
    }

    /// The whole log, newest first, with a header naming the app, its
    /// version and macOS.
    public static func text(
        _ entries: [ActivityLogEntry],
        masked: Bool,
        app: ActivityLogAppInfo = .current,
        exported: Date = .now
    ) -> String {
        let formatter = makeDateFormatter()
        let version = [app.version, app.build.isEmpty || app.build == app.version ? "" : "(\(app.build))"]
            .filter { !$0.isEmpty }.joined(separator: " ")
        var lines = [
            "\(app.name)\(version.isEmpty ? "" : " \(version)") activity log",
            app.system,
            "Exported \(formatter.string(from: exported))",
            "\(entries.count) \(entries.count == 1 ? "entry" : "entries"), newest first. Secrets are never recorded.",
            masked
                ? "Device identifiers, usernames and IP addresses are replaced with placeholders."
                : "Not masked: device identifiers, usernames and IP addresses are shown as recorded.",
            "",
        ]
        let masker = masked ? IdentifierMasker(entries.flatMap(\.identifiers)) : nil
        for entry in entries.reversed() {
            lines.append(separator)
            let text = transcript(of: entry, dateFormatter: formatter)
            lines.append(masker?.mask(text) ?? text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// `text(…)`, built on a background thread, for the export of a full log.
    static func textInBackground(
        _ entries: [ActivityLogEntry],
        masked: Bool,
        app: ActivityLogAppInfo,
        exported: Date = .now
    ) async -> String {
        await Task.detached(priority: .userInitiated) {
            text(entries, masked: masked, app: app, exported: exported)
        }.value
    }

    static func transcript(of entry: ActivityLogEntry, dateFormatter: DateFormatter) -> String {
        var lines = [String]()
        let source = [entry.category, entry.service, entry.connection]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        lines.append("\(dateFormatter.string(from: entry.date))  \(source)")
        lines.append([entry.operation, entry.detail].filter { !$0.isEmpty }.joined(separator: " "))

        var facts = [String]()
        if let status = entry.status { facts.append("Status \(status)") }
        else if entry.failedWithoutStatus { facts.append("Failed") }
        if let duration = entry.duration { facts.append(String(format: "%.2f s", duration)) }
        if let request = entry.request, request.maxAttempts > 1 {
            facts.append("Attempt \(request.attempt) of \(request.maxAttempts)")
        }
        if entry.isWarning { facts.append("Warning") }
        if !facts.isEmpty { lines.append(facts.joined(separator: " · ")) }
        if let note = entry.note, !note.isEmpty { lines.append(note) }

        guard let request = entry.request else { return lines.joined(separator: "\n") }
        lines.append("")
        lines.append("URL: \(request.url)")
        if request.contentsWithheld {
            lines.append("Contents withheld: this request carries a secret. Only its method, path, status and duration are recorded.")
        }
        if let error = request.error { lines.append("Error: \(error)") }
        if let bodyNote = request.bodyNote { lines.append(bodyNote) }
        section("Request headers", request.requestHeaders.map { "\($0.name): \($0.value)" }, into: &lines)
        section("Request body", request.requestBody.map { [$0] } ?? [], into: &lines)
        section("Response headers", request.responseHeaders.map { "\($0.name): \($0.value)" }, into: &lines)
        section("Response body", request.responseBody.map { [$0] } ?? [], into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func section(_ title: String, _ content: [String], into lines: inout [String]) {
        guard !content.isEmpty else { return }
        lines.append("── \(title) ──")
        lines += content
    }

    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }
}
