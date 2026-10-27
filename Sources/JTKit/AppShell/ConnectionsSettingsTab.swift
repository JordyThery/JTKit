import SwiftUI
import UniformTypeIdentifiers

/// A way the app uses a connection: "Active connection" in most apps,
/// "Source" and "Destination" in JamfMigrator, "Apple" and "MDM" in
/// Checkpoint. The app keeps the choice itself (and saves it under the key it
/// has always used); the editor's "Use This Connection" or "Use as …" button,
/// the toolbar picker and the Connection menu set it.
public struct ConnectionRole {
    public let title: String
    public let useTitle: String
    /// The single connection chosen for this role. Never holds "All": that
    /// is `all`, so the choice the app saves is always a single connection.
    public let selection: Binding<UUID?>
    /// The services whose connections can have this role; nil for every service.
    public let services: Set<ConnectionService>?
    /// The role's "All" choice, e.g. "All Organizations"; nil when it has none.
    public let all: AllConnectionsChoice?
    /// The role's demo connections, chosen instead of the saved ones while
    /// demo mode is on; nil for an app without demo mode.
    public let demo: DemoConnectionChoice?
    /// How VoiceOver names the toolbar picker.
    let accessibilityName: String

    /// - Parameters:
    ///   - title: shown when the connection has this role, e.g. `"Source"`.
    ///   - useTitle: the button that gives it the role; `"Use as <title>"` by default.
    ///   - selection: the app's choice for this role.
    ///   - services: only connections of these services can have the role,
    ///     e.g. Checkpoint's Apple role; every service by default.
    ///   - all: offers "All" for this role (see `AllConnectionsChoice`).
    ///   - demo: the role's demo connections (see `DemoConnectionChoice`).
    public init(_ title: String, useTitle: String? = nil, selection: Binding<UUID?>,
                services: Set<ConnectionService>? = nil, all: AllConnectionsChoice? = nil,
                demo: DemoConnectionChoice? = nil) {
        self.init(title, useTitle: useTitle, selection: selection, services: services, all: all,
                  demo: demo, accessibilityName: title)
    }

    private init(_ title: String, useTitle: String?, selection: Binding<UUID?>,
                 services: Set<ConnectionService>?, all: AllConnectionsChoice?, demo: DemoConnectionChoice? = nil,
                 accessibilityName: String) {
        self.title = title
        self.useTitle = useTitle ?? "Use as \(title)"
        self.selection = selection
        self.services = services
        self.all = all
        self.demo = demo
        self.accessibilityName = accessibilityName
    }

    /// The single role of apps that use one connection at a time.
    /// - Parameter demo: the demo connections it offers while demo mode is on
    ///   (see `DemoConnectionChoice`); nil for an app without demo mode.
    public static func active(selection: Binding<UUID?>, demo: DemoConnectionChoice? = nil) -> ConnectionRole {
        ConnectionRole("Active connection", useTitle: "Use This Connection", selection: selection,
                       services: nil, all: nil, demo: demo, accessibilityName: ConnectionMenuText.menuTitle)
    }

    /// Whether a connection can have this role.
    public func accepts(_ connection: Connection) -> Bool {
        services?.contains(connection.service) ?? true
    }

    /// Whether "All" is in use: chosen, and offered because the role has
    /// enough connections.
    @MainActor
    public func usesAll(connectionCount: Int) -> Bool {
        all?.isInEffect(connectionCount: connectionCount) ?? false
    }

    /// Whether the role uses its demo connections now (demo mode is on).
    @MainActor
    public var usesDemo: Bool { demo?.isActive ?? false }

    /// Gives a single connection the role, which ends "All" and leaves demo mode.
    @MainActor
    func use(_ id: UUID?) {
        all?.isChosen = false
        selection.wrappedValue = id
        if let demo, demo.isActive { demo.mode.isOn = false }
    }

    /// The menu's choice: a connection, or "All".
    @MainActor
    func menuChoice(connectionCount: Int) -> Binding<ConnectionMenuChoice?> {
        Binding(
            get: {
                if usesDemo { return nil }
                if usesAll(connectionCount: connectionCount) { return .all }
                return selection.wrappedValue.map(ConnectionMenuChoice.connection)
            },
            set: { choice in
                switch choice {
                case .all:
                    all?.isChosen = true
                    if let demo, demo.isActive { demo.mode.isOn = false }
                case .connection(let id): use(id)
                case nil: break
                }
            })
    }
}

/// What a role's picker or menu can choose.
enum ConnectionMenuChoice: Hashable {
    case connection(UUID)
    case all
}

/// The "All" choice of a role, e.g. Checkpoint's "All Organizations": every
/// connection of the role at once.
///
/// The same in every app: "All" lasts for this session only and is never
/// saved. Choosing it leaves the app's saved single connection as it is, so
/// at the next launch the role falls back to the last single connection used,
/// and a combined read is never a surprise at launch. Choosing a single
/// connection ends it. It is offered only while the role has at least
/// `minimumConnections` connections.
///
/// The app keeps one for each role that has it, for as long as it runs, and
/// reads `isInEffect` to know whether to work with every connection.
@MainActor
@Observable
public final class AllConnectionsChoice {
    public static let minimumConnections = 2

    /// e.g. `"All Organizations"`.
    public let title: String
    /// Whether "All" was chosen. In memory only, never saved.
    public var isChosen = false

    public init(title: String) {
        self.title = title
    }

    /// Chosen, and offered because the role has enough connections.
    public func isInEffect(connectionCount: Int) -> Bool {
        isChosen && connectionCount >= Self.minimumConnections
    }
}

/// Which services the editor offers for a connection, and which sign-in
/// methods for a service.
nonisolated enum ConnectionServiceChoices {
    /// Whether the editor shows the Jamf Protect add-on for a service.
    static func offersProtect(for service: ConnectionService, optionalFields: Set<ConnectionOptionalField>,
                              protectServices: Set<ConnectionService>) -> Bool {
        optionalFields.contains(.jamfProtect)
            && (service == .jamfPlatform || service == .jamfPro)
            && protectServices.contains(service)
    }

    /// The services a saved connection can switch to: its own group when the
    /// app groups them, else every service the app supports.
    static func services(for service: ConnectionService, offered: [ConnectionService],
                         groups: [[ConnectionService]], allowsChanging: Bool) -> [ConnectionService] {
        guard allowsChanging else { return [service] }
        guard let group = groups.first(where: { $0.contains(service) }) else { return offered }
        return offered.filter(group.contains)
    }

    /// The + menu's sections: the app's groups in order, then any service in
    /// no group.
    static func addMenuSections(offered: [ConnectionService], groups: [[ConnectionService]]) -> [[ConnectionService]] {
        var sections = groups.map { group in offered.filter(group.contains) }
        let rest = offered.filter { service in !groups.contains { $0.contains(service) } }
        sections.append(rest)
        return sections.filter { !$0.isEmpty }
    }

    /// The sign-in methods the app accepts for a service, the usual one first.
    static func signInMethods(for service: ConnectionService,
                              limits: [ConnectionService: [SignInMethod]]) -> [SignInMethod] {
        let limited = service.signInMethods.filter { limits[service]?.contains($0) ?? true }
        return limited.isEmpty ? service.signInMethods : limited
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

/// Lists the Jamf Platform API environments the editor's values can see, so
/// the Environment ID can be picked instead of typed. Gets the same values as
/// `ConnectionTest`; typically `JamfPlatform.environments(for:secret:recorder:)`.
/// A thrown error is shown below the field, and typing the ID still works.
public typealias ConnectionEnvironmentLoader<Record> = @MainActor (Record, [ConnectionSecretKind: String]) async throws -> [JamfPlatform.Environment]

/// What the editor shows of the environment list.
nonisolated enum EnvironmentListState: Equatable {
    case idle
    case loading
    case loaded([JamfPlatform.Environment])
    case failed(String)

    static let emptyListMessage = "This integration sees no environments. Find the Environment ID in Jamf Account (account.jamf.com): open the API integration’s details and copy it from there."

    /// The picker's choice for an Environment ID: the matching environment,
    /// or "" when the ID was typed and isn't in the list.
    static func choice(for environmentID: String, in environments: [JamfPlatform.Environment]) -> String {
        let trimmed = environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return environments.first { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }?.id ?? ""
    }

    /// The list needs a sign-in: a client ID and a secret, typed or stored.
    static func canLoad(_ connection: Connection, typedSecret: String?, hasStoredSecret: Bool) -> Bool {
        connection.service == .jamfPlatform
            && !connection.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!(typedSecret ?? "").isEmpty || hasStoredSecret)
    }
}

/// Importing a connection from a file: "Import…" in the + menu of the
/// Connections tab, e.g. a tenant profile exported on another Mac. The
/// imported connection is saved and selected. An import never replaces a
/// saved connection: give the record a new id in `read` when its id is
/// already in the list.
public struct ConnectionImport<Record: ConnectionRecord> {
    public let title: String
    public let contentTypes: [UTType]
    public let read: @MainActor (Data) throws -> Record

    /// - Parameters:
    ///   - title: the + menu item, `"Import…"` by default.
    ///   - contentTypes: the files the open panel accepts, e.g. `[.json]`.
    ///   - read: the record in the file's contents; throws for a file that
    ///     isn't one, with a plain-language message.
    public init(title: String = "Import…", contentTypes: [UTType],
                read: @escaping @MainActor (Data) throws -> Record) {
        self.title = title
        self.contentTypes = contentTypes
        self.read = read
    }

    /// Reads the file and saves the record it holds.
    @MainActor
    func importRecord(from url: URL, into store: ConnectionStore<Record>) throws -> Record {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let record = try read(try Data(contentsOf: url))
        if let saved = store.record(id: record.id) {
            throw ConnectionImportError.alreadySaved(ConnectionMenuText.name(of: saved.connection))
        }
        try store.save(record)
        return record
    }
}

nonisolated enum ConnectionImportError: LocalizedError, Equatable {
    case alreadySaved(String)

    var errorDescription: String? {
        switch self {
        case .alreadySaved(let name):
            "This file holds “\(name)”, which is already in the list. Nothing was imported."
        }
    }
}

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
    let serviceGroups: [[ConnectionService]]
    let signInMethods: [ConnectionService: [SignInMethod]]
    let roles: [ConnectionRole]
    let height: CGFloat
    let footer: String?
    let readOnlyFields: (Record) -> Set<ConnectionField>
    let protectServices: Set<ConnectionService>
    let newRecord: (ConnectionService) -> Record
    let add: (() -> Void)?
    let importer: ConnectionImport<Record>?
    let delete: ((Record) async throws -> Void)?
    let deleteMessage: String?
    let didDelete: (Record) -> Void
    let test: ConnectionTest<Record>?
    let environments: ConnectionEnvironmentLoader<Record>?
    let appSection: (Binding<Record>) -> AppSection

    /// The app's demo mode, when it passes one in (`.environment(demo)`).
    @Environment(DemoMode.self) private var demo: DemoMode?
    @State private var editingID: UUID?
    @State private var editorHasChanges = false
    @State private var pendingSelection: UUID??
    @State private var pendingDeletion: Record?
    @State private var isDeleting = false
    @State private var listError: String?
    @State private var showingImporter = false

    /// - Parameters:
    ///   - store: the app's saved connections.
    ///   - services: the services the app supports, in the order of the + menu.
    ///   - optionalFields: extra fields to show, e.g. `.jamfProtect`.
    ///   - allowsChangingService: whether a saved connection can switch service.
    ///   - serviceGroups: services a saved connection can switch between,
    ///     e.g. Checkpoint's Apple services and its MDM services; also the
    ///     sections of the + menu. Empty: any service the app supports.
    ///   - signInMethods: limits the sign-in methods of a service, e.g.
    ///     `[.intune: [.entraClientSecret]]`; services left out offer all theirs.
    ///   - roles: the ways the app uses a connection, each with a button in the editor.
    ///   - height: the tab's height; the width is `SettingsLayout.width`.
    ///   - footer: a note below the editor, e.g. the API permissions needed.
    ///   - readOnlyFields: shared fields shown as text for a record, e.g. what
    ///     was fixed when the connection was made.
    ///   - protectServices: the services that offer the Jamf Protect add-on
    ///     when `optionalFields` contains `.jamfProtect`.
    ///   - newRecord: a new, unsaved record for the service chosen with +.
    ///   - add: replaces what + does, e.g. to open the app's own setup wizard.
    ///   - importer: adds "Import…" to the + menu (see `ConnectionImport`).
    ///   - delete: replaces what deleting does, e.g. when more than the record
    ///     and its secrets goes; the list is read again afterwards. A thrown
    ///     error is shown below the list.
    ///   - deleteMessage: the delete confirmation's text, when the app's
    ///     `delete` does more than remove the connection and its secrets.
    ///   - didDelete: called after a connection and its secrets were deleted,
    ///     e.g. to clear choices the app stored for it.
    ///   - test: tests the editor's values; without it there is no Test Connection button.
    ///   - environments: lists the Jamf Platform API environments, so the
    ///     Environment ID can be picked; without it the ID is only typed.
    ///   - appSection: the app's own `Section`s for the record, below the shared fields.
    public init(
        store: ConnectionStore<Record>,
        services: [ConnectionService],
        optionalFields: Set<ConnectionOptionalField> = [],
        allowsChangingService: Bool = true,
        serviceGroups: [[ConnectionService]] = [],
        signInMethods: [ConnectionService: [SignInMethod]] = [:],
        roles: [ConnectionRole] = [],
        height: CGFloat = 480,
        footer: String? = nil,
        readOnlyFields: @escaping (Record) -> Set<ConnectionField> = { _ in [] },
        protectServices: Set<ConnectionService> = [.jamfPlatform, .jamfPro],
        newRecord: @escaping (ConnectionService) -> Record,
        add: (() -> Void)? = nil,
        importer: ConnectionImport<Record>? = nil,
        delete: ((Record) async throws -> Void)? = nil,
        deleteMessage: String? = nil,
        didDelete: @escaping (Record) -> Void = { _ in },
        test: ConnectionTest<Record>? = nil,
        environments: ConnectionEnvironmentLoader<Record>? = nil,
        @ViewBuilder appSection: @escaping (Binding<Record>) -> AppSection
    ) {
        self.store = store
        self.services = services
        self.optionalFields = optionalFields
        self.allowsChangingService = allowsChangingService
        self.serviceGroups = serviceGroups
        self.signInMethods = signInMethods
        self.roles = roles
        self.height = height
        self.footer = footer
        self.readOnlyFields = readOnlyFields
        self.protectServices = protectServices
        self.newRecord = newRecord
        self.add = add
        self.importer = importer
        self.delete = delete
        self.deleteMessage = deleteMessage
        self.didDelete = didDelete
        self.test = test
        self.environments = environments
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
            if demo?.isOn == true {
                DemoModeConnectionsNote()
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
                editingID = roles.lazy.compactMap { $0.selection.wrappedValue }
                    .first { id in store.record(id: id).map { record in roles.contains { $0.accepts(record.connection) } } ?? false }
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
            Text(deleteMessage ?? "The connection and its Keychain secrets are removed.")
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
                                  roleTitles: roleTitles(for: record))
                        .tag(record.id)
                }
            }
            .onDeleteCommand {
                if store.problem == nil { pendingDeletion = editingID.flatMap(store.record(id:)) }
            }
            if isDeleting {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Removing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
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
                .disabled(editingID == nil || store.problem != nil || isDeleting)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(4)
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: importer?.contentTypes ?? [],
                      onCompletion: importRecord)
    }

    @ViewBuilder
    private var addButton: some View {
        if importer == nil && (add != nil || services.count == 1) {
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
                if let add {
                    Button(ConnectionMenuText.addTitle, systemImage: "plus") { add() }
                } else {
                    let sections = ConnectionServiceChoices.addMenuSections(offered: services, groups: serviceGroups)
                    ForEach(sections.indices, id: \.self) { index in
                        if index > 0 { Divider() }
                        ForEach(sections[index]) { service in
                            Button(service.displayName, systemImage: service.systemImage) { addRecord(for: service) }
                        }
                    }
                }
                if let importer {
                    Divider()
                    Button(importer.title, systemImage: "square.and.arrow.down") { showingImporter = true }
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

    /// The roles a row is marked with: the role, or its "All" title when every
    /// connection of the role is in use.
    private func roleTitles(for record: Record) -> [String] {
        roles.compactMap { role in
            guard role.accepts(record.connection) else { return nil }
            let count = store.records.filter { role.accepts($0.connection) }.count
            if role.usesAll(connectionCount: count) { return role.all?.title }
            return role.selection.wrappedValue == record.id ? role.title : nil
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

    private func importRecord(_ result: Result<URL, any Error>) {
        guard let importer, case .success(let url) = result else { return }
        do {
            let record = try importer.importRecord(from: url, into: store)
            listError = nil
            // like clicking the row: unsaved changes to another connection ask first
            if editorHasChanges {
                pendingSelection = .some(record.id)
            } else {
                editingID = record.id
            }
        } catch {
            listError = error.localizedDescription
        }
    }

    private func deletePending() {
        guard let record = pendingDeletion else { return }
        pendingDeletion = nil
        guard let delete else {
            do {
                try store.delete(id: record.id)
                finishDeleting(record)
            } catch {
                listError = error.localizedDescription
            }
            return
        }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                try await delete(record)
                store.reload()
                finishDeleting(record)
            } catch {
                listError = error.localizedDescription
            }
        }
    }

    private func finishDeleting(_ record: Record) {
        listError = nil
        for role in roles where role.selection.wrappedValue == record.id {
            role.selection.wrappedValue = nil
        }
        didDelete(record)
        editorHasChanges = false
        editingID = store.records.first?.id
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        if let editingID, let record = store.record(id: editingID) {
            ConnectionEditor(store: store,
                             saved: record,
                             services: ConnectionServiceChoices.services(
                                for: record.connection.service, offered: services,
                                groups: serviceGroups, allowsChanging: allowsChangingService),
                             signInMethods: signInMethods,
                             optionalFields: optionalFields,
                             readOnlyFields: readOnlyFields(record),
                             protectServices: protectServices,
                             roles: roles,
                             footer: footer,
                             test: test,
                             environments: environments,
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
        serviceGroups: [[ConnectionService]] = [],
        signInMethods: [ConnectionService: [SignInMethod]] = [:],
        roles: [ConnectionRole] = [],
        height: CGFloat = 480,
        footer: String? = nil,
        readOnlyFields: @escaping (Record) -> Set<ConnectionField> = { _ in [] },
        protectServices: Set<ConnectionService> = [.jamfPlatform, .jamfPro],
        newRecord: @escaping (ConnectionService) -> Record,
        add: (() -> Void)? = nil,
        importer: ConnectionImport<Record>? = nil,
        delete: ((Record) async throws -> Void)? = nil,
        deleteMessage: String? = nil,
        didDelete: @escaping (Record) -> Void = { _ in },
        test: ConnectionTest<Record>? = nil,
        environments: ConnectionEnvironmentLoader<Record>? = nil
    ) {
        self.init(store: store, services: services, optionalFields: optionalFields,
                  allowsChangingService: allowsChangingService, serviceGroups: serviceGroups,
                  signInMethods: signInMethods, roles: roles, height: height,
                  footer: footer, readOnlyFields: readOnlyFields, protectServices: protectServices,
                  newRecord: newRecord, add: add, importer: importer, delete: delete, deleteMessage: deleteMessage,
                  didDelete: didDelete, test: test, environments: environments) { _ in
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
    let signInLimits: [ConnectionService: [SignInMethod]]
    let optionalFields: Set<ConnectionOptionalField>
    let readOnlyFields: Set<ConnectionField>
    let protectServices: Set<ConnectionService>
    let roles: [ConnectionRole]
    let footer: String?
    let test: ConnectionTest<Record>?
    let environments: ConnectionEnvironmentLoader<Record>?
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
    @State private var showingKeyImporter = false
    @State private var importedKeyName: String?
    @State private var keyImportError: String?
    @State private var environmentState = EnvironmentListState.idle

    init(store: ConnectionStore<Record>, saved: Record, services: [ConnectionService],
         signInMethods: [ConnectionService: [SignInMethod]], optionalFields: Set<ConnectionOptionalField>,
         readOnlyFields: Set<ConnectionField>, protectServices: Set<ConnectionService>,
         roles: [ConnectionRole], footer: String?,
         test: ConnectionTest<Record>?, environments: ConnectionEnvironmentLoader<Record>?,
         hasChanges: Binding<Bool>,
         appSection: @escaping (Binding<Record>) -> AppSection) {
        self.store = store
        self.services = services
        self.signInLimits = signInMethods
        self.optionalFields = optionalFields
        self.readOnlyFields = readOnlyFields
        self.protectServices = protectServices
        self.roles = roles
        self.footer = footer
        self.test = test
        self.environments = environments
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
                if readOnlyFields.contains(.signIn) {
                    readOnlyRow("Sign in with", current.signIn.displayName)
                } else if signInMethods(for: current.service).count > 1 {
                    Picker("Sign in with", selection: connection.signIn) {
                        ForEach(signInMethods(for: current.service)) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                }
            }

            serviceFields

            if ConnectionServiceChoices.offersProtect(for: current.service, optionalFields: optionalFields,
                                                      protectServices: protectServices) {
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
        .fileImporter(isPresented: $showingKeyImporter, allowedContentTypes: ApplePrivateKey.contentTypes,
                      onCompletion: importPrivateKey)
        .onAppear(perform: loadSecrets)
        .onChange(of: isChanged, initial: true) { hasChanges = isChanged }
        .onChange(of: draft) { testState = .idle }
        .onChange(of: secrets) {
            testState = .idle
            environmentState = .idle
        }
        // a list loaded with other sign-in values may not be this integration's
        .onChange(of: [current.region.rawValue, current.hostOverride, current.clientID]) { environmentState = .idle }
    }

    // MARK: Fields

    @ViewBuilder
    private var serviceFields: some View {
        Section {
            switch current.service {
            case .jamfPlatform:
                if readOnlyFields.contains(.region) {
                    readOnlyRow("Region", current.region.displayName)
                } else {
                    Picker("Region", selection: connection.region) {
                        ForEach(JamfRegion.allCases) { region in
                            Text(region.displayName).tag(region)
                        }
                    }
                }
                if optionalFields.contains(.hostOverride) {
                    TextField("Host override", text: connection.hostOverride, prompt: Text("Leave empty for the region’s gateway"))
                }
                textField(.environmentID, "Environment ID", text: connection.environmentID, prompt: "From Jamf Account")
                if environments != nil && !readOnlyFields.contains(.environmentID) {
                    environmentRows
                }
                textField(.clientID, "Client ID", text: connection.clientID)
                secretField(.main)
                if optionalFields.contains(.jamfProWebURL) {
                    TextField("Jamf Pro web address", text: connection.jamfProWebURL, prompt: Text("https://yourorg.jamfcloud.com (optional)"))
                        .textContentType(.URL)
                }
            case .jamfPro:
                textField(.serverURL, "Server URL", text: connection.serverURL, prompt: "https://yourorg.jamfcloud.com")
                    .textContentType(.URL)
                if current.signIn == .usernamePassword {
                    textField(.username, "Username", text: connection.username)
                        .textContentType(.username)
                } else {
                    textField(.clientID, "Client ID", text: connection.clientID)
                }
                secretField(.main)
            case .jamfSchool:
                textField(.serverURL, "Server URL", text: connection.serverURL, prompt: "https://yourschool.jamfcloud.com")
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

    /// Below the Environment ID: a picker once the list is loaded, the button
    /// that loads it, and why it couldn't be loaded. Typing the ID always works.
    @ViewBuilder
    private var environmentRows: some View {
        if case .loaded(let list) = environmentState, !list.isEmpty {
            Picker("Environment", selection: environmentChoice(in: list)) {
                Text(current.environmentID.isEmpty ? "Choose…" : "Not in the list").tag("")
                ForEach(list) { environment in
                    Text(environment.name).tag(environment.id)
                }
            }
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(isLoaded ? "Reload Environments" : "Load Environments") { loadEnvironments() }
                .disabled(!canLoadEnvironments || environmentState == .loading)
                .help("Pick from the environments this integration can see")
            if environmentState == .loading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading environments")
            }
            Spacer(minLength: 0)
        }
        switch environmentState {
        case .failed(let text):
            // the same warning label as the field issues, so it reads as a problem without color alone
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .loaded(let list) where list.isEmpty:
            Text(EnvironmentListState.emptyListMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }

    private var isLoaded: Bool {
        if case .loaded = environmentState { return true }
        return false
    }

    private var canLoadEnvironments: Bool {
        EnvironmentListState.canLoad(current, typedSecret: secrets[.main], hasStoredSecret: hasStoredSecret.contains(.main))
    }

    /// Picking an environment fills in its ID; "" (a typed ID) changes nothing.
    private func environmentChoice(in list: [JamfPlatform.Environment]) -> Binding<String> {
        Binding(
            get: { EnvironmentListState.choice(for: current.environmentID, in: list) },
            set: { id in if !id.isEmpty { draft.connection.environmentID = id } })
    }

    private func loadEnvironments() {
        guard let environments else { return }
        environmentState = .loading
        let record = draft
        let typed = changedSecrets
        Task {
            do {
                environmentState = .loaded(try await environments(record, typed))
            } catch {
                environmentState = .failed(connectionTestFailureText(error))
            }
        }
    }

    /// A text field, or its value as text when the app made it read-only.
    @ViewBuilder
    private func textField(_ field: ConnectionField, _ title: String, text: Binding<String>,
                           prompt: String? = nil) -> some View {
        if readOnlyFields.contains(field) {
            readOnlyRow(title, text.wrappedValue)
        } else {
            TextField(title, text: text, prompt: prompt.map { Text($0) })
        }
    }

    private func readOnlyRow(_ title: String, _ value: String) -> some View {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return LabeledContent(title) {
            Text(trimmed.isEmpty ? "None" : trimmed)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func secretField(_ kind: ConnectionSecretKind, name: String? = nil) -> some View {
        if store.stores(kind), let title = name ?? current.signIn.secretName {
            let binding = Binding(get: { secrets[kind] ?? "" }, set: { secrets[kind] = $0 })
            let prompt = Text(hasStoredSecret.contains(kind) ? "Stored in the Keychain · type to replace" : "Required")
            if kind == .main && current.signIn == .applePrivateKey {
                privateKeyField(title)
            } else {
                SecureField(title, text: binding, prompt: prompt)
            }
        }
    }

    /// The Apple private key is imported from its .pem file and never shown:
    /// a status line and a button, no text.
    private func privateKeyField(_ title: String) -> some View {
        let imported = !(secrets[.main] ?? "").isEmpty
        let hasKey = imported || hasStoredSecret.contains(.main)
        return LabeledContent(title) {
            VStack(alignment: .leading, spacing: 4) {
                Button(hasKey ? "Replace Private Key…" : "Import .pem File…") { showingKeyImporter = true }
                Text(privateKeyStatus(imported: imported))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let keyImportError {
                    Label(keyImportError, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func privateKeyStatus(imported: Bool) -> String {
        if imported {
            return "\(importedKeyName ?? "Private key") imported · Save to keep it"
        }
        return hasStoredSecret.contains(.main) ? "Stored in the Keychain" : "Required: the .pem file downloaded from Apple"
    }

    private func importPrivateKey(_ result: Result<URL, any Error>) {
        guard case .success(let url) = result else { return }
        do {
            secrets[.main] = try ApplePrivateKey.read(contentsOf: url)
            importedKeyName = url.lastPathComponent
            keyImportError = nil
        } catch {
            keyImportError = error.localizedDescription
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

    private func signInMethods(for service: ConnectionService) -> [SignInMethod] {
        ConnectionServiceChoices.signInMethods(for: service, limits: signInLimits)
    }

    /// Switching service keeps a sign-in method the new service accepts.
    private var serviceBinding: Binding<ConnectionService> {
        Binding(
            get: { current.service },
            set: { service in
                var updated = current
                updated.service = service
                let methods = signInMethods(for: service)
                if !methods.contains(updated.signIn) {
                    updated.signIn = methods[0]
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
                if !role.accepts(saved.connection) {
                    EmptyView()
                } else if role.selection.wrappedValue == saved.id && !usesAll(role) {
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
            // continue from what was saved, as the storage reads it back
            saved = store.record(id: draft.id) ?? draft
            draft = saved
            hasStoredSecret.formUnion(changedSecrets.keys)
            secrets = [:]
            importedKeyName = nil
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
        importedKeyName = nil
        keyImportError = nil
        saveError = nil
    }

    private func usesAll(_ role: ConnectionRole) -> Bool {
        role.usesAll(connectionCount: store.records.filter { role.accepts($0.connection) }.count)
    }

    /// Saves unsaved changes first; the role changes only when that worked.
    private func use(_ role: ConnectionRole) {
        if isChanged && !save() { return }
        role.use(saved.id)
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
