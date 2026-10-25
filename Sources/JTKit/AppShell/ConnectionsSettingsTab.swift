import SwiftUI

/// A way the app uses a connection: "Active connection" in most apps,
/// "Source" and "Destination" in JamfMigrator. The app keeps the choice
/// itself (and saves it under the key it has always used); the editor's
/// "Use This Connection" or "Use as …" button sets it.
public struct ConnectionRole {
    public let title: String
    public let useTitle: String
    public let selection: Binding<UUID?>

    /// - Parameters:
    ///   - title: shown when the connection has this role, e.g. `"Source"`.
    ///   - useTitle: the button that gives it the role; `"Use as <title>"` by default.
    ///   - selection: the app's choice for this role.
    public init(_ title: String, useTitle: String? = nil, selection: Binding<UUID?>) {
        self.title = title
        self.useTitle = useTitle ?? "Use as \(title)"
        self.selection = selection
    }

    /// The single role of apps that use one connection at a time.
    public static func active(selection: Binding<UUID?>) -> ConnectionRole {
        ConnectionRole("Active connection", useTitle: "Use This Connection", selection: selection)
    }
}

/// Tests a connection with the values in the editor, saved or not. The
/// dictionary holds the secrets typed there and not saved yet; a kind left
/// out means "use the stored one". Returns a short success message, e.g.
/// `"Connected · Jamf Pro 11.12"`, or throws.
///
/// A thrown error is shown in full below "Connection failed", selectable for
/// copying: its description, then its `failureReason` and
/// `recoverySuggestion` when it is a `LocalizedError`. Put details such as
/// the HTTP status or a trace ID in `failureReason`.
public typealias ConnectionTest<Record> = @MainActor (Record, [ConnectionSecretKind: String]) async throws -> String

/// The full text of a failed connection test: every non-empty part of the
/// error, one after another.
nonisolated func connectionTestFailureText(_ error: any Error) -> String {
    let localized = error as? LocalizedError
    let parts = [error.localizedDescription, localized?.failureReason, localized?.recoverySuggestion]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    var unique = [String]()
    for part in parts where !unique.contains(part) {
        unique.append(part)
    }
    return unique.isEmpty ? "No details were given." : unique.joined(separator: "\n\n")
}

/// The Connections tab of the Settings window: the app's saved connections in
/// a list beside an editor. Several services can share the list.
///
/// ```swift
/// ConnectionsSettingsTab(store: tenants, services: [.jamfPlatform, .jamfPro],
///                        roles: [.active(selection: $activeID)],
///                        newRecord: { Tenant(connection: Connection(name: "New tenant", service: $0)) }) { $tenant in
///     Section { Toggle("Protected", isOn: $tenant.isProtected) }
/// }
/// ```
public struct ConnectionsSettingsTab<Record: ConnectionRecord, AppSection: View>: View {
    let store: ConnectionStore<Record>
    let services: [ConnectionService]
    let optionalFields: Set<ConnectionOptionalField>
    let allowsChangingService: Bool
    let roles: [ConnectionRole]
    let height: CGFloat
    let footer: String?
    let newRecord: (ConnectionService) -> Record
    let add: (() -> Void)?
    let didDelete: (Record) -> Void
    let test: ConnectionTest<Record>?
    let appSection: (Binding<Record>) -> AppSection

    @State private var editingID: UUID?
    @State private var editorHasChanges = false
    @State private var pendingSelection: UUID??
    @State private var pendingDeletion: Record?
    @State private var listError: String?

    /// - Parameters:
    ///   - store: the app's saved connections.
    ///   - services: the services the app supports, in the order of the + menu.
    ///   - optionalFields: extra fields to show, e.g. `.jamfProtect`.
    ///   - allowsChangingService: whether a saved connection can switch service.
    ///   - roles: the ways the app uses a connection, each with a button in the editor.
    ///   - height: the tab's height; the width is `SettingsLayout.width`.
    ///   - footer: a note below the editor, e.g. the API permissions needed.
    ///   - newRecord: a new, unsaved record for the service chosen with +.
    ///   - add: replaces what + does, e.g. to open the app's own setup wizard.
    ///   - didDelete: called after a connection and its secrets were deleted,
    ///     e.g. to clear choices the app stored for it.
    ///   - test: tests the editor's values; without it there is no Test Connection button.
    ///   - appSection: the app's own `Section`s for the record, below the shared fields.
    public init(
        store: ConnectionStore<Record>,
        services: [ConnectionService],
        optionalFields: Set<ConnectionOptionalField> = [],
        allowsChangingService: Bool = true,
        roles: [ConnectionRole] = [],
        height: CGFloat = 480,
        footer: String? = nil,
        newRecord: @escaping (ConnectionService) -> Record,
        add: (() -> Void)? = nil,
        didDelete: @escaping (Record) -> Void = { _ in },
        test: ConnectionTest<Record>? = nil,
        @ViewBuilder appSection: @escaping (Binding<Record>) -> AppSection
    ) {
        self.store = store
        self.services = services
        self.optionalFields = optionalFields
        self.allowsChangingService = allowsChangingService
        self.roles = roles
        self.height = height
        self.footer = footer
        self.newRecord = newRecord
        self.add = add
        self.didDelete = didDelete
        self.test = test
        self.appSection = appSection
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let problem = store.problem {
                Label(problem.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                Divider()
            }
            HStack(spacing: 0) {
                connectionList
                    .frame(width: 210)
                Divider()
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: SettingsLayout.width, height: height)
        .onAppear {
            if editingID == nil {
                editingID = roles.lazy.compactMap { $0.selection.wrappedValue }.first { store.record(id: $0) != nil }
                    ?? store.records.first?.id
            }
        }
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: Binding(get: { pendingSelection != nil }, set: { if !$0 { pendingSelection = nil } })
        ) {
            Button("Discard Changes", role: .destructive) {
                if let pendingSelection { editingID = pendingSelection }
                pendingSelection = nil
            }
            Button("Cancel", role: .cancel) { pendingSelection = nil }
        } message: {
            Text("The changes to this connection have not been saved.")
        }
        .confirmationDialog(
            "Delete “\(pendingDeletion?.connection.name ?? "connection")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deletePending() }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The connection and its Keychain secrets are removed.")
        }
        .tabItem { Label("Connections", systemImage: "network") }
        .settingsTabName(SettingsTabName.connections)
    }

    // MARK: List

    private var connectionList: some View {
        VStack(spacing: 0) {
            List(selection: listSelection) {
                ForEach(store.records) { record in
                    ConnectionRow(connection: record.connection,
                                  badge: record.listBadge,
                                  roleTitles: roles.filter { $0.selection.wrappedValue == record.id }.map(\.title))
                        .tag(record.id)
                }
            }
            .onDeleteCommand {
                if store.problem == nil { pendingDeletion = editingID.flatMap(store.record(id:)) }
            }
            if let listError {
                Text(listError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 0) {
                addButton
                Button {
                    pendingDeletion = editingID.flatMap(store.record(id:))
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .help("Delete connection and its Keychain secrets")
                .accessibilityLabel("Delete Connection")
                .disabled(editingID == nil || store.problem != nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
    }

    @ViewBuilder
    private var addButton: some View {
        if add != nil || services.count == 1 {
            Button {
                if let add { add() } else { addRecord(for: services[0]) }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 20)
            }
            .help("Add connection")
            .accessibilityLabel("Add Connection")
            .disabled(store.problem != nil)
        } else {
            Menu {
                ForEach(services) { service in
                    Button(service.displayName, systemImage: service.systemImage) { addRecord(for: service) }
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add connection")
            .accessibilityLabel("Add Connection")
            .disabled(store.problem != nil)
        }
    }

    /// Switching to another connection with unsaved changes asks first.
    private var listSelection: Binding<UUID?> {
        Binding(
            get: { editingID },
            set: { newValue in
                guard newValue != editingID else { return }
                if editorHasChanges {
                    pendingSelection = .some(newValue)
                } else {
                    editingID = newValue
                }
            })
    }

    private func addRecord(for service: ConnectionService) {
        let record = newRecord(service)
        do {
            try store.save(record)
            listError = nil
            editingID = record.id
        } catch {
            listError = error.localizedDescription
        }
    }

    private func deletePending() {
        guard let record = pendingDeletion else { return }
        pendingDeletion = nil
        do {
            try store.delete(id: record.id)
            listError = nil
            for role in roles where role.selection.wrappedValue == record.id {
                role.selection.wrappedValue = nil
            }
            didDelete(record)
            editorHasChanges = false
            editingID = store.records.first?.id
        } catch {
            listError = error.localizedDescription
        }
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        if let editingID, let record = store.record(id: editingID) {
            ConnectionEditor(store: store,
                             saved: record,
                             services: allowsChangingService ? services : [record.connection.service],
                             optionalFields: optionalFields,
                             roles: roles,
                             footer: footer,
                             test: test,
                             hasChanges: $editorHasChanges,
                             appSection: appSection)
                .id(editingID)
        } else {
            ContentUnavailableView {
                Label("No Connection Selected", systemImage: "network")
            } description: {
                Text(store.records.isEmpty ? "Click + to add a connection." : "Select a connection to edit it.")
            }
        }
    }
}

extension ConnectionsSettingsTab where AppSection == EmptyView {
    /// A Connections tab with only the shared fields.
    public init(
        store: ConnectionStore<Record>,
        services: [ConnectionService],
        optionalFields: Set<ConnectionOptionalField> = [],
        allowsChangingService: Bool = true,
        roles: [ConnectionRole] = [],
        height: CGFloat = 480,
        footer: String? = nil,
        newRecord: @escaping (ConnectionService) -> Record,
        add: (() -> Void)? = nil,
        didDelete: @escaping (Record) -> Void = { _ in },
        test: ConnectionTest<Record>? = nil
    ) {
        self.init(store: store, services: services, optionalFields: optionalFields,
                  allowsChangingService: allowsChangingService, roles: roles, height: height,
                  footer: footer, newRecord: newRecord, add: add, didDelete: didDelete, test: test) { _ in
            EmptyView()
        }
    }
}

// MARK: - Row

private struct ConnectionRow: View {
    let connection: Connection
    let badge: (systemImage: String, help: String)?
    let roleTitles: [String]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: connection.service.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(connection.name.isEmpty ? "Unnamed connection" : connection.name)
                        .lineLimit(1)
                    if let badge {
                        Image(systemName: badge.systemImage)
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                            .help(badge.help)
                            .accessibilityLabel(badge.help)
                    }
                }
                Text(connection.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !roleTitles.isEmpty {
                    Label(roleTitles.joined(separator: ", "), systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Editor

private struct ConnectionEditor<Record: ConnectionRecord, AppSection: View>: View {

    private enum TestState: Equatable {
        case idle, testing, success(String), failure(String)
    }

    let store: ConnectionStore<Record>
    let services: [ConnectionService]
    let optionalFields: Set<ConnectionOptionalField>
    let roles: [ConnectionRole]
    let footer: String?
    let test: ConnectionTest<Record>?
    @Binding var hasChanges: Bool
    let appSection: (Binding<Record>) -> AppSection

    @State private var saved: Record
    @State private var draft: Record
    /// Secrets typed in the editor. Fields start empty: stored secrets are
    /// never shown (HIG: never prepopulate a password field).
    @State private var secrets: [ConnectionSecretKind: String] = [:]
    @State private var hasStoredSecret: Set<ConnectionSecretKind> = []
    @State private var testState = TestState.idle
    @State private var saveError: String?

    init(store: ConnectionStore<Record>, saved: Record, services: [ConnectionService],
         optionalFields: Set<ConnectionOptionalField>, roles: [ConnectionRole], footer: String?,
         test: ConnectionTest<Record>?, hasChanges: Binding<Bool>,
         appSection: @escaping (Binding<Record>) -> AppSection) {
        self.store = store
        self.services = services
        self.optionalFields = optionalFields
        self.roles = roles
        self.footer = footer
        self.test = test
        self._hasChanges = hasChanges
        self.appSection = appSection
        self._saved = State(initialValue: saved)
        self._draft = State(initialValue: saved)
    }

    private var connection: Binding<Connection> { $draft.connection }
    private var current: Connection { draft.connection }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: connection.name)
                if services.count > 1 {
                    Picker("Service", selection: serviceBinding) {
                        ForEach(services) { service in
                            Text(service.displayName).tag(service)
                        }
                    }
                }
                if current.service.signInMethods.count > 1 {
                    Picker("Sign in with", selection: connection.signIn) {
                        ForEach(current.service.signInMethods) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                }
            }

            serviceFields

            if optionalFields.contains(.jamfProtect),
               current.service == .jamfPlatform || current.service == .jamfPro {
                protectSection
            }

            appSection($draft)

            if test != nil {
                Section {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button("Test Connection") { runTest() }
                            .disabled(!canTest || testState == .testing)
                        testStatus
                        Spacer(minLength: 0)
                    }
                    if case .failure(let text) = testState {
                        // the whole error, for copying into a support ticket
                        Text(text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                actionRow
                if let saveError {
                    Text(saveError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            } footer: {
                if let footer {
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadSecrets)
        .onChange(of: isChanged, initial: true) { hasChanges = isChanged }
        .onChange(of: draft) { testState = .idle }
        .onChange(of: secrets) { testState = .idle }
    }

    // MARK: Fields

    @ViewBuilder
    private var serviceFields: some View {
        Section {
            switch current.service {
            case .jamfPlatform:
                Picker("Region", selection: connection.region) {
                    ForEach(JamfRegion.allCases) { region in
                        Text(region.displayName).tag(region)
                    }
                }
                if optionalFields.contains(.hostOverride) {
                    TextField("Host override", text: connection.hostOverride, prompt: Text("Leave empty for the region’s gateway"))
                }
                TextField("Environment ID", text: connection.environmentID, prompt: Text("From Jamf Account"))
                TextField("Client ID", text: connection.clientID)
                secretField(.main)
                if optionalFields.contains(.jamfProWebURL) {
                    TextField("Jamf Pro web address", text: connection.jamfProWebURL, prompt: Text("https://yourorg.jamfcloud.com (optional)"))
                        .textContentType(.URL)
                }
            case .jamfPro:
                TextField("Server URL", text: connection.serverURL, prompt: Text("https://yourorg.jamfcloud.com"))
                    .textContentType(.URL)
                if current.signIn == .usernamePassword {
                    TextField("Username", text: connection.username)
                        .textContentType(.username)
                } else {
                    TextField("Client ID", text: connection.clientID)
                }
                secretField(.main)
            case .jamfSchool:
                TextField("Server URL", text: connection.serverURL, prompt: Text("https://yourschool.jamfcloud.com"))
                    .textContentType(.URL)
                TextField("Network ID", text: connection.clientID)
                secretField(.main)
            case .intune:
                TextField("Tenant ID", text: connection.tenantID, prompt: Text("Directory ID or domain"))
                TextField("Client ID", text: connection.clientID, prompt: Text("Application (client) ID"))
                if current.signIn == .microsoftInteractive {
                    Text("You sign in with your Microsoft account in the main window. No secret is stored.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    secretField(.main)
                }
            case .appleBusinessManager, .appleSchoolManager:
                TextField("Client ID", text: connection.clientID)
                TextField("Key ID", text: connection.keyID)
                secretField(.main)
            }
        } footer: {
            issuesFooter(current.issues.filter { !$0.contains("Jamf Protect") })
        }
    }

    @ViewBuilder
    private var protectSection: some View {
        Section {
            Toggle("Jamf Protect", isOn: Binding(
                get: { current.protect != nil },
                set: { draft.connection.protect = $0 ? (current.protect ?? JamfProtectSettings()) : nil }))
            if let protect = current.protect {
                TextField("Protect URL", text: Binding(
                    get: { protect.url },
                    set: { draft.connection.protect?.url = $0 }), prompt: Text("https://yourorg.protect.jamfcloud.com"))
                    .textContentType(.URL)
                TextField("Protect client ID", text: Binding(
                    get: { protect.clientID },
                    set: { draft.connection.protect?.clientID = $0 }))
                secretField(.protect, name: "Protect client secret")
            }
        } footer: {
            issuesFooter(current.issues.filter { $0.contains("Jamf Protect") })
        }
    }

    @ViewBuilder
    private func secretField(_ kind: ConnectionSecretKind, name: String? = nil) -> some View {
        if store.stores(kind), let title = name ?? current.signIn.secretName {
            let binding = Binding(get: { secrets[kind] ?? "" }, set: { secrets[kind] = $0 })
            let prompt = Text(hasStoredSecret.contains(kind) ? "Stored in the Keychain · type to replace" : "Required")
            if kind == .main && current.signIn == .applePrivateKey {
                LabeledContent(title) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextEditor(text: binding)
                            .font(.caption.monospaced())
                            .frame(minHeight: 60, maxHeight: 90)
                            .accessibilityLabel(title)
                        prompt
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                SecureField(title, text: binding, prompt: prompt)
            }
        }
    }

    @ViewBuilder
    private func issuesFooter(_ issues: [String]) -> some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Switching service keeps a sign-in method the new service accepts.
    private var serviceBinding: Binding<ConnectionService> {
        Binding(
            get: { current.service },
            set: { service in
                var updated = current
                updated.service = service
                if !service.signInMethods.contains(updated.signIn) {
                    updated.signIn = service.signInMethods[0]
                }
                draft.connection = updated
            })
    }

    // MARK: Status and actions

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Testing")
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .textSelection(.enabled)
        case .failure:
            // the full text follows below the row
            Label("Connection failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            ForEach(roles.indices, id: \.self) { index in
                let role = roles[index]
                if role.selection.wrappedValue == saved.id {
                    Label(role.title, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Button(role.useTitle) { use(role) }
                        .disabled(!canSave && isChanged)
                }
            }
            Spacer(minLength: 0)
            if isChanged {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("Revert") { revert() }
                .disabled(!isChanged)
            Button("Save") { _ = save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!isChanged || !canSave)
        }
    }

    // MARK: State

    private var isChanged: Bool {
        draft != saved || changedSecrets.isEmpty == false
    }

    /// Typed secrets; an empty field keeps the stored one.
    private var changedSecrets: [ConnectionSecretKind: String] {
        secrets.filter { !$0.value.isEmpty }
    }

    private var canSave: Bool {
        current.issues.isEmpty && store.problem == nil
    }

    /// Everything the service needs is filled in, including the secret.
    private var canTest: Bool {
        guard current.issues.isEmpty else { return false }
        let c = current
        let required: [String]
        switch c.service {
        case .jamfPlatform: required = [c.environmentID, c.clientID]
        case .jamfPro: required = [c.serverURL, c.signIn == .usernamePassword ? c.username : c.clientID]
        case .jamfSchool: required = [c.serverURL, c.clientID]
        case .intune: required = [c.tenantID, c.clientID]
        case .appleBusinessManager, .appleSchoolManager: required = [c.clientID, c.keyID]
        }
        let needsSecret = c.signIn.secretName != nil && store.stores(.main)
        let secretMissing = needsSecret && (secrets[.main] ?? "").isEmpty && !hasStoredSecret.contains(.main)
        return !required.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && !secretMissing
    }

    private func loadSecrets() {
        hasStoredSecret = Set(ConnectionSecretKind.allCases.filter { kind in
            store.stores(kind) && !(store.secret(kind, for: saved.connection) ?? "").isEmpty
        })
        secrets = [:]
    }

    @discardableResult
    private func save() -> Bool {
        do {
            try store.save(draft, secrets: changedSecrets)
            saved = draft
            hasStoredSecret.formUnion(changedSecrets.keys)
            secrets = [:]
            saveError = nil
            return true
        } catch {
            saveError = error.localizedDescription
            return false
        }
    }

    private func revert() {
        draft = saved
        secrets = [:]
        saveError = nil
    }

    /// Saves unsaved changes first; the role changes only when that worked.
    private func use(_ role: ConnectionRole) {
        if isChanged && !save() { return }
        role.selection.wrappedValue = saved.id
    }

    private func runTest() {
        guard let test else { return }
        testState = .testing
        let record = draft
        let typed = changedSecrets
        Task {
            do {
                let message = try await test(record, typed)
                testState = .success(isChanged ? "\(message). Save to keep these values." : message)
            } catch {
                testState = .failure(connectionTestFailureText(error))
            }
        }
    }
}
