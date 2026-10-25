import SwiftUI

/// The items of an app's connection picker: the saved connections (the one in
/// use checked), then "Edit Connections…", which opens Settings › Connections.
/// The toolbar's `ConnectionPicker` and the menu bar's `ConnectionCommands`
/// show these same items, as every toolbar control needs a menu bar command.
///
/// "Edit Connections…" opens the Connections tab only when the app opens
/// tabs by name (`SettingsWindow(opensTabsByName: true)`).
public struct ConnectionMenuItems<Record: ConnectionRecord>: View {
    let store: ConnectionStore<Record>
    let roles: [ConnectionRole]
    let editTitle: String
    let itemTitle: (Record) -> String

    /// - Parameters:
    ///   - store: the app's saved connections.
    ///   - roles: the ways the app uses a connection; each gets its own
    ///     choice, under the role's title when there are several (JamfMigrator's
    ///     Source and Destination).
    ///   - editTitle: e.g. `"Edit Tenants…"`; "Add Connection…" while the list is empty.
    ///   - itemTitle: a connection's name in the menu; its name by default.
    public init(
        store: ConnectionStore<Record>,
        roles: [ConnectionRole],
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) }
    ) {
        self.store = store
        self.roles = roles
        self.editTitle = editTitle
        self.itemTitle = itemTitle
    }

    /// The items for apps that use one connection at a time.
    public init(
        store: ConnectionStore<Record>,
        selection: Binding<UUID?>,
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) }
    ) {
        self.init(store: store, roles: [.active(selection: selection)], editTitle: editTitle, itemTitle: itemTitle)
    }

    public var body: some View {
        if store.records.isEmpty {
            Text(ConnectionMenuText.noConnections)
        } else if roles.count == 1 {
            choice(for: roles[0])
        } else {
            ForEach(roles.indices, id: \.self) { index in
                Section(roles[index].title) {
                    choice(for: roles[index])
                }
            }
        }
        Divider()
        SettingsTabLink(SettingsTabName.connections) {
            Text(ConnectionMenuText.linkTitle(isEmpty: store.records.isEmpty, editTitle: editTitle))
        }
    }

    private func choice(for role: ConnectionRole) -> some View {
        Picker(role.title, selection: role.selection) {
            ForEach(store.records) { record in
                Text(itemTitle(record)).tag(Optional(record.id))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// The toolbar control that chooses the connection in use, named after it.
/// Its menu holds `ConnectionMenuItems`; with no connections saved it is an
/// "Add Connection…" button that opens Settings › Connections.
///
/// ```swift
/// ToolbarItem(placement: .navigation) {
///     ConnectionPicker(store: connections, selection: $activeID)
/// }
/// ```
public struct ConnectionPicker<Record: ConnectionRecord>: View {
    let store: ConnectionStore<Record>
    let selection: Binding<UUID?>
    let editTitle: String
    let itemTitle: (Record) -> String

    /// - Parameters:
    ///   - store: the app's saved connections.
    ///   - selection: the connection in use, saved by the app.
    ///   - editTitle: e.g. `"Edit Tenants…"`.
    ///   - itemTitle: a connection's name in the toolbar and the menu; its name by default.
    public init(
        store: ConnectionStore<Record>,
        selection: Binding<UUID?>,
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) }
    ) {
        self.store = store
        self.selection = selection
        self.editTitle = editTitle
        self.itemTitle = itemTitle
    }

    public var body: some View {
        if store.records.isEmpty {
            SettingsTabLink(SettingsTabName.connections) {
                Label(ConnectionMenuText.addTitle, systemImage: "plus")
            }
            .help("Add a connection in Settings › Connections")
        } else {
            let current = selection.wrappedValue.flatMap(store.record(id:))
            let title = ConnectionMenuText.pickerTitle(current.map(itemTitle))
            Menu {
                ConnectionMenuItems(store: store, selection: selection, editTitle: editTitle, itemTitle: itemTitle)
            } label: {
                Label(title, systemImage: current?.connection.service.systemImage ?? "network.slash")
                    .labelStyle(.titleAndIcon)
            }
            .help("The connection in use")
            .accessibilityLabel("Connection: \(title)")
        }
    }
}

/// The menu bar's "Connection" menu, with the same items as the toolbar's
/// `ConnectionPicker`. Add it to the app's commands:
///
/// ```swift
/// .commands {
///     ConnectionCommands(store: connections, selection: activeID)
/// }
/// ```
public struct ConnectionCommands<Record: ConnectionRecord>: Commands {
    let title: String
    let store: ConnectionStore<Record>
    let roles: [ConnectionRole]
    let editTitle: String
    let itemTitle: (Record) -> String

    /// - Parameters:
    ///   - title: the menu's name, e.g. `"Tenant"`.
    ///   - store, roles, editTitle, itemTitle: as for `ConnectionMenuItems`.
    public init(
        _ title: String = ConnectionMenuText.menuTitle,
        store: ConnectionStore<Record>,
        roles: [ConnectionRole],
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) }
    ) {
        self.title = title
        self.store = store
        self.roles = roles
        self.editTitle = editTitle
        self.itemTitle = itemTitle
    }

    /// The menu for apps that use one connection at a time.
    public init(
        _ title: String = ConnectionMenuText.menuTitle,
        store: ConnectionStore<Record>,
        selection: Binding<UUID?>,
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) }
    ) {
        self.init(title, store: store, roles: [.active(selection: selection)], editTitle: editTitle, itemTitle: itemTitle)
    }

    public var body: some Commands {
        CommandMenu(title) {
            ConnectionMenuItems(store: store, roles: roles, editTitle: editTitle, itemTitle: itemTitle)
        }
    }
}

/// The words of the connection picker and menu, the same in every app.
public nonisolated enum ConnectionMenuText {
    public static let menuTitle = "Connection"
    public static let editTitle = "Edit Connections…"
    public static let addTitle = "Add Connection…"
    static let noConnections = "No Connections"
    static let noneChosen = "No Connection"
    static let unnamed = "Unnamed connection"

    /// A connection's name, or "Unnamed connection" as in the Connections tab.
    public static func name(of connection: Connection) -> String {
        connection.name.isEmpty ? unnamed : connection.name
    }

    /// The toolbar picker's title: the connection in use, if there is one.
    static func pickerTitle(_ current: String?) -> String {
        current ?? noneChosen
    }

    static func linkTitle(isEmpty: Bool, editTitle: String) -> String {
        isEmpty ? addTitle : editTitle
    }
}
