import SwiftUI

/// The "Demo Mode" switch, the same in every app: put it in the connection
/// picker's and the Connection menu's slot for the app's own items.
///
/// ```swift
/// ConnectionPicker(store: connections, selection: selection,
///                  label: demo.isOn ? .demo : nil, help: demo.isOn ? DemoMode.helpText : nil) {
///     DemoModeToggle(demo: demo)
/// }
/// ```
public struct DemoModeToggle: View {
    @Bindable var demo: DemoMode

    public init(demo: DemoMode) {
        self.demo = demo
    }

    public var body: some View {
        Toggle(DemoMode.title, isOn: $demo.isOn)
    }
}

extension ConnectionPickerLabel {
    /// What the connection picker shows while demo mode is on.
    public static let demo = ConnectionPickerLabel("Demo", systemImage: "testtube.2",
                                                   accessibilityLabel: "Connection in use: Demo Mode")
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
