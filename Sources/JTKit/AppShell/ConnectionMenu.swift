import SwiftUI

/// The items of an app’s connection picker: the saved connections (the one in
/// use checked), then "Edit Connections…", which opens Settings › Connections.
/// The toolbar’s `ConnectionPicker` and the menu bar’s `ConnectionCommands`
/// show these same items, as every toolbar control needs a menu bar command.
///
/// A role with "All" (`ConnectionRole.all`) lists it below its connections,
/// dimmed until the role has two or more; "All" lasts for the session only
/// (see `AllConnectionsChoice`).
///
/// "Edit Connections…" opens the Connections tab only when the app opens
/// tabs by name (`SettingsWindow(opensTabsByName: true)`).
///
/// An app can add its own items below the connections (`extraItems`), e.g.
/// Profile2Blueprint’s "Offline Demo Mode"; the picker and the menu show them
/// both, so they stay the same.
struct ConnectionMenuItems<Record: ConnectionRecord, Extra: View>: View {
    let store: ConnectionStore<Record>
    let roles: [ConnectionRole]
    let editTitle: String
    let itemTitle: (Record) -> String
    let extraItems: Extra

    /// - Parameters:
    ///   - store: the app’s saved connections.
    ///   - roles: the ways the app uses a connection; each gets its own
    ///     choice, under the role’s title when there are several (JamfMigrator’s
    ///     Source and Destination, Checkpoint’s Apple and MDM). A role lists
    ///     only the connections it accepts.
    ///   - editTitle: e.g. `"Edit Tenants…"`; "Add Connection…" while the list is empty.
    ///   - itemTitle: a connection’s name in the menu; its name by default.
    ///   - extraItems: the app’s own items, below the connections.
    public init(
        store: ConnectionStore<Record>,
        roles: [ConnectionRole],
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) },
        @ViewBuilder extraItems: () -> Extra
    ) {
        self.store = store
        self.roles = roles
        self.editTitle = editTitle
        self.itemTitle = itemTitle
        self.extraItems = extraItems()
    }

    /// The items for apps that use one connection at a time.
    public init(
        store: ConnectionStore<Record>,
        selection: Binding<UUID?>,
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) },
        @ViewBuilder extraItems: () -> Extra
    ) {
        self.init(store: store, roles: [.active(selection: selection)], editTitle: editTitle,
                  itemTitle: itemTitle, extraItems: extraItems)
    }

    public var body: some View {
        if store.records.isEmpty && !roles.contains(where: \.usesDemo) {
            Text(ConnectionMenuText.noConnections)
        } else if roles.count == 1 {
            demoChoice(for: roles[0])
            choice(for: roles[0])
        } else {
            ForEach(roles.indices, id: \.self) { index in
                Section(roles[index].title) {
                    demoChoice(for: roles[index])
                    choice(for: roles[index])
                }
            }
        }
        if Extra.self != EmptyView.self {
            Divider()
            extraItems
        }
        Divider()
        SettingsTabLink(SettingsTabName.connections) {
            Text(ConnectionMenuText.linkTitle(isEmpty: store.records.isEmpty, editTitle: editTitle))
        }
    }

    /// While demo mode is on: the role’s demo connections and "All", above
    /// the saved ones (which stay, so you can switch back).
    @ViewBuilder
    private func demoChoice(for role: ConnectionRole) -> some View {
        if let demo = role.demo, demo.isActive {
            DemoConnectionPicker(choice: demo, allTitle: role.all?.title)
            Divider()
        }
    }

    @ViewBuilder
    private func choice(for role: ConnectionRole) -> some View {
        let records = store.records.filter { role.accepts($0.connection) }
        if records.isEmpty, role.usesDemo {
            EmptyView()
        } else if records.isEmpty {
            Text(ConnectionMenuText.noConnections)
        } else {
            Picker(role.title, selection: role.menuChoice(connectionCount: records.count)) {
                ForEach(records) { record in
                    Text(itemTitle(record)).tag(Optional(ConnectionMenuChoice.connection(record.id)))
                }
                // dimmed rather than hidden with one connection: menu bar
                // menus keep the same items (HIG, The menu bar)
                if let all = role.all {
                    Divider()
                    Text(all.title).tag(Optional(ConnectionMenuChoice.all))
                        .disabled(records.count < AllConnectionsChoice.minimumConnections)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

extension ConnectionMenuItems where Extra == EmptyView {
    init(
        store: ConnectionStore<Record>,
        roles: [ConnectionRole],
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) }
    ) {
        self.init(store: store, roles: roles, editTitle: editTitle, itemTitle: itemTitle) { EmptyView() }
    }

    init(
        store: ConnectionStore<Record>,
        selection: Binding<UUID?>,
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) }
    ) {
        self.init(store: store, selection: selection, editTitle: editTitle, itemTitle: itemTitle) { EmptyView() }
    }
}

/// What the toolbar picker shows instead of the connection in use, e.g.
/// "Offline Demo" while no connection is used, or a warning symbol for a
/// connection to a non-production host.
public nonisolated struct ConnectionPickerLabel: Hashable, Sendable {
    public var title: String
    public var systemImage: String
    /// What VoiceOver says; "<role>: <title>" by default.
    public var accessibilityLabel: String?

    public init(_ title: String, systemImage: String, accessibilityLabel: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.accessibilityLabel = accessibilityLabel
    }
}

/// The toolbar control that chooses the connection in use, named after it.
/// Its menu holds `ConnectionMenuItems`; with no connections saved it is an
/// "Add Connection…" button that opens Settings › Connections, unless the app
/// adds items of its own (`extraItems`), which stay reachable.
///
/// ```swift
/// ToolbarItem(placement: .navigation) {
///     ConnectionPicker(store: connections, selection: $activeID)
/// }
/// ```
public struct ConnectionPicker<Record: ConnectionRecord, Extra: View>: View {
    let store: ConnectionStore<Record>
    let role: ConnectionRole
    let editTitle: String
    let itemTitle: (Record) -> String
    let help: String?
    let label: ConnectionPickerLabel?
    let extraItems: Extra

    /// - Parameters:
    ///   - store: the app’s saved connections.
    ///   - selection: the connection in use, saved by the app.
    ///   - editTitle: e.g. `"Edit Tenants…"`.
    ///   - itemTitle: a connection’s name in the toolbar and the menu; its name by default.
    ///   - label: shown instead of the connection in use, e.g. "Offline Demo".
    ///   - help: the tooltip; "The connection in use" by default.
    ///   - extraItems: the app’s own items, below the connections; give the
    ///     app’s `ConnectionCommands` the same ones.
    public init(
        store: ConnectionStore<Record>,
        selection: Binding<UUID?>,
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) },
        label: ConnectionPickerLabel? = nil,
        help: String? = nil,
        @ViewBuilder extraItems: () -> Extra
    ) {
        self.init(store: store, role: .active(selection: selection), editTitle: editTitle, itemTitle: itemTitle,
                  help: help, label: label, extraItems: extraItems)
    }

    /// The picker of one role, for apps with a picker per role (Checkpoint’s
    /// Apple and MDM). It lists the connections the role accepts, and "All"
    /// when the role has it.
    ///
    /// - Parameters:
    ///   - help: the tooltip; "The connection in use" by default.
    public init(
        store: ConnectionStore<Record>,
        role: ConnectionRole,
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) },
        help: String? = nil,
        label: ConnectionPickerLabel? = nil,
        @ViewBuilder extraItems: () -> Extra
    ) {
        self.store = store
        self.role = role
        self.editTitle = editTitle
        self.itemTitle = itemTitle
        self.help = help
        self.label = label
        self.extraItems = extraItems()
    }

    public var body: some View {
        if ConnectionMenuText.showsAddButton(isEmpty: store.records.isEmpty, hasExtraItems: Extra.self != EmptyView.self,
                                             usesDemo: role.usesDemo) {
            SettingsTabLink(SettingsTabName.connections) {
                Label(ConnectionMenuText.addTitle, systemImage: "plus")
            }
            .help("Add a connection in Settings › Connections")
        } else {
            let records = store.records.filter { role.accepts($0.connection) }
            let demoLabel = role.demo.flatMap { $0.isActive ? $0.label(allTitle: role.all?.title, roleName: role.accessibilityName) : nil }
            let label = demoLabel ?? self.label
            let help = role.usesDemo ? DemoMode.helpText : self.help
            let usesAll = role.usesAll(connectionCount: records.count)
            let current = usesAll ? nil : role.selection.wrappedValue.flatMap { id in records.first { $0.id == id } }
            let title = label?.title
                ?? (usesAll ? (role.all?.title ?? "") : ConnectionMenuText.pickerTitle(current.map(itemTitle)))
            let symbol = label?.systemImage
                ?? (usesAll ? ConnectionMenuText.allSymbol : (current?.connection.service.systemImage ?? "network.slash"))
            Menu {
                ConnectionMenuItems(store: store, roles: [role], editTitle: editTitle, itemTitle: itemTitle) {
                    extraItems
                }
            } label: {
                Label(title, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
            }
            .help(help ?? "The connection in use")
            .accessibilityLabel(label?.accessibilityLabel ?? "\(role.accessibilityName): \(title)")
        }
    }
}

extension ConnectionPicker where Extra == EmptyView {
    public init(
        store: ConnectionStore<Record>,
        selection: Binding<UUID?>,
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) },
        label: ConnectionPickerLabel? = nil,
        help: String? = nil
    ) {
        self.init(store: store, selection: selection, editTitle: editTitle, itemTitle: itemTitle,
                  label: label, help: help) { EmptyView() }
    }

    public init(
        store: ConnectionStore<Record>,
        role: ConnectionRole,
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) },
        help: String? = nil,
        label: ConnectionPickerLabel? = nil
    ) {
        self.init(store: store, role: role, editTitle: editTitle, itemTitle: itemTitle,
                  help: help, label: label) { EmptyView() }
    }
}

/// The menu bar’s "Connection" menu, with the same items as the toolbar’s
/// `ConnectionPicker`. Add it to the app’s commands:
///
/// ```swift
/// .commands {
///     ConnectionCommands(store: connections, selection: activeID)
/// }
/// ```
public struct ConnectionCommands<Record: ConnectionRecord, Extra: View>: Commands {
    let title: String
    let store: ConnectionStore<Record>
    let roles: [ConnectionRole]
    let editTitle: String
    let itemTitle: (Record) -> String
    let extraItems: Extra

    /// - Parameters:
    ///   - title: the menu’s name, e.g. `"Tenant"`.
    ///   - store, roles, editTitle, itemTitle, extraItems: as for `ConnectionMenuItems`.
    public init(
        _ title: String = ConnectionMenuText.menuTitle,
        store: ConnectionStore<Record>,
        roles: [ConnectionRole],
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) },
        @ViewBuilder extraItems: () -> Extra
    ) {
        self.title = title
        self.store = store
        self.roles = roles
        self.editTitle = editTitle
        self.itemTitle = itemTitle
        self.extraItems = extraItems()
    }

    /// The menu for apps that use one connection at a time.
    public init(
        _ title: String = ConnectionMenuText.menuTitle,
        store: ConnectionStore<Record>,
        selection: Binding<UUID?>,
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) },
        @ViewBuilder extraItems: () -> Extra
    ) {
        self.init(title, store: store, roles: [.active(selection: selection)], editTitle: editTitle,
                  itemTitle: itemTitle, extraItems: extraItems)
    }

    public var body: some Commands {
        CommandMenu(title) {
            ConnectionMenuItems(store: store, roles: roles, editTitle: editTitle, itemTitle: itemTitle) {
                extraItems
            }
        }
    }
}

extension ConnectionCommands where Extra == EmptyView {
    public init(
        _ title: String = ConnectionMenuText.menuTitle,
        store: ConnectionStore<Record>,
        roles: [ConnectionRole],
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) }
    ) {
        self.init(title, store: store, roles: roles, editTitle: editTitle, itemTitle: itemTitle) { EmptyView() }
    }

    public init(
        _ title: String = ConnectionMenuText.menuTitle,
        store: ConnectionStore<Record>,
        selection: Binding<UUID?>,
        editTitle: String = ConnectionMenuText.editTitle,
        itemTitle: @escaping (Record) -> String = { ConnectionMenuText.name(of: $0.connection) }
    ) {
        self.init(title, store: store, selection: selection, editTitle: editTitle, itemTitle: itemTitle) { EmptyView() }
    }
}

/// The words of the connection picker and menu, the same in every app.
public nonisolated enum ConnectionMenuText {
    public static let menuTitle = "Connection"
    public static let editTitle = "Edit Connections…"
    static let addTitle = "Add Connection…"
    static let noConnections = "No Connections"
    static let noneChosen = "No Connection"
    /// The toolbar picker’s symbol while "All" is in use.
    static let allSymbol = "square.stack.3d.up"
    static let unnamed = "Unnamed Connection"

    /// A connection’s name, or “Unnamed Connection” as in the Connections tab.
    public static func name(of connection: Connection) -> String {
        connection.name.isEmpty ? unnamed : connection.name
    }

    /// The toolbar picker’s title: the connection in use, if there is one.
    static func pickerTitle(_ current: String?) -> String {
        current ?? noneChosen
    }

    /// Whether the toolbar picker is only "Add Connection…": nothing saved
    /// and no items of the app’s own. Not in demo mode, where the demo
    /// connections are the menu, even with none saved.
    static func showsAddButton(isEmpty: Bool, hasExtraItems: Bool, usesDemo: Bool) -> Bool {
        isEmpty && !hasExtraItems && !usesDemo
    }

    static func linkTitle(isEmpty: Bool, editTitle: String) -> String {
        isEmpty ? addTitle : editTitle
    }
}
