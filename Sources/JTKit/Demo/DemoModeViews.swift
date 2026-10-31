import SwiftUI

/// The "Demo Mode" switch, the same in every app: put it in the connection
/// picker’s and the Connection menu’s slot for the app’s own items.
///
/// ```swift
/// ConnectionPicker(store: connections, selection: selection,
///                  label: demo.isOn ? .demo : nil, help: demo.isOn ? DemoMode.helpText : nil) {
///     DemoModeToggle(demo: demo)
/// }
/// ```
///
/// The switch goes through `DemoMode.requestSwitch(to:)`, so an app that set
/// `asksBeforeSwitching` gets its question first (`confirmsDemoModeSwitch`).
public struct DemoModeToggle: View {
    let demo: DemoMode
    let whenAsking: @MainActor () -> Void

    /// - Parameter whenAsking: runs when the question is shown instead of
    ///   switching, e.g. to bring the window with the question forward from
    ///   the Connection menu.
    public init(demo: DemoMode, whenAsking: @escaping @MainActor () -> Void = {}) {
        self.demo = demo
        self.whenAsking = whenAsking
    }

    public var body: some View {
        Toggle(DemoMode.title, isOn: Binding(
            get: { demo.isOn },
            set: { if demo.requestSwitch(to: $0) { whenAsking() } }
        ))
    }
}

extension ConnectionPickerLabel {
    /// What the connection picker shows while demo mode is on.
    public static let demo = ConnectionPickerLabel("Demo", systemImage: "testtube.2",
                                                   accessibilityLabel: "Connection in use: Demo Mode")

    /// The picker naming the demo connection in use, e.g. "Contoso (Demo)",
    /// as Checkpoint’s does.
    public static func demo(_ connection: Connection) -> ConnectionPickerLabel {
        ConnectionPickerLabel(connection.name, systemImage: "testtube.2",
                              accessibilityLabel: "Connection in use: \(connection.name)")
    }
}

extension View {
    /// The app’s question before demo mode is turned on or off while it has
    /// unsaved work (`DemoMode.asksBeforeSwitching`), e.g. "Turn on Demo Mode
    /// and discard unsaved changes?". Put it on the window where the switch is.
    /// - Parameter discarding: what switching discards, e.g. "unsaved changes".
    public func confirmsDemoModeSwitch(_ demo: DemoMode, discarding: String = "unsaved changes") -> some View {
        modifier(DemoModeSwitchConfirmation(demo: demo, discarding: discarding))
    }
}

/// "Turn on/off Demo Mode and discard …?" with "Discard and Turn On/Off" and Cancel.
struct DemoModeSwitchConfirmation: ViewModifier {
    let demo: DemoMode
    let discarding: String

    /// The question for a waiting switch to `isOn`.
    static func title(isOn: Bool, discarding: String) -> String {
        "Turn \(isOn ? "on" : "off") \(DemoMode.title) and discard \(discarding)?"
    }

    static func confirmTitle(isOn: Bool) -> String {
        "Discard and Turn \(isOn ? "On" : "Off")"
    }

    func body(content: Content) -> some View {
        let target = demo.pendingSwitch ?? !demo.isOn
        content.confirmationDialog(
            Self.title(isOn: target, discarding: discarding),
            isPresented: Binding(
                get: { demo.pendingSwitch != nil },
                set: { if !$0 { demo.cancelSwitch() } }
            )
        ) {
            Button(Self.confirmTitle(isOn: target), role: .destructive) { demo.confirmSwitch() }
            Button("Cancel", role: .cancel) { demo.cancelSwitch() }
        }
    }
}

/// The note above Settings › Connections while demo mode is on: the list
/// there still holds the real connections.
struct DemoModeConnectionsNote: View {
    var body: some View {
        Label("Demo Mode is on. These are your real connections.", systemImage: "testtube.2")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }
}

/// One role’s demo connections while demo mode is on, e.g. Checkpoint’s two
/// demo organizations, and which is in use: one of them, or all of them.
/// Kept in memory for the session only; nothing is saved, and the role’s
/// saved choice is left as it was. Give it to the role
/// (`ConnectionRole(…, demo:)`): the picker and the Connection menu then list
/// the demo connections above the saved ones, the picker reads e.g.
/// "Contoso (Demo)", and choosing a saved connection leaves demo mode.
@MainActor
@Observable
public final class DemoConnectionChoice {
    public let mode: DemoMode
    public let connections: [Connection]
    /// The single demo connection chosen; the first by default.
    public var selectedID: UUID?
    /// "All" chosen for the demo connections.
    public var isAllChosen = false

    public init(mode: DemoMode, connections: [Connection]) {
        self.mode = mode
        self.connections = connections
        selectedID = connections.first?.id
    }

    /// Demo mode is on, so the role uses these connections.
    public var isActive: Bool { mode.isOn }

    public var selected: Connection? {
        connections.first { $0.id == selectedID } ?? connections.first
    }

    /// Whether "All" is in effect: chosen, and there are two or more.
    public var usesAll: Bool {
        isAllChosen && connections.count >= AllConnectionsChoice.minimumConnections
    }

    /// The demo connections in use now.
    public var inUse: [Connection] {
        usesAll ? connections : selected.map { [$0] } ?? []
    }

    /// What the role’s picker shows, e.g. "Contoso (Demo)" or "All Organizations (Demo)".
    func label(allTitle: String?, roleName: String) -> ConnectionPickerLabel {
        let name = usesAll ? "\(allTitle ?? "All") (Demo)" : selected?.name ?? "Demo"
        return ConnectionPickerLabel(name, systemImage: "testtube.2",
                                     accessibilityLabel: "\(roleName): \(name)")
    }

    var menuChoice: Binding<ConnectionMenuChoice?> {
        Binding(
            get: { self.usesAll ? .all : self.selected.map { .connection($0.id) } },
            set: { choice in
                switch choice {
                case .all: self.isAllChosen = true
                case .connection(let id):
                    self.isAllChosen = false
                    self.selectedID = id
                case nil: break
                }
            })
    }
}

/// The demo connections of a role in its picker and the Connection menu.
struct DemoConnectionPicker: View {
    let choice: DemoConnectionChoice
    let allTitle: String?

    var body: some View {
        Picker("Demo", selection: choice.menuChoice) {
            ForEach(choice.connections) { connection in
                Text(connection.name).tag(Optional(ConnectionMenuChoice.connection(connection.id)))
            }
            if let allTitle, choice.connections.count >= AllConnectionsChoice.minimumConnections {
                Text("\(allTitle) (Demo)").tag(Optional(ConnectionMenuChoice.all))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}
