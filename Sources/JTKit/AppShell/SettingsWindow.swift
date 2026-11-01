import Observation
import SwiftUI

/// What every app’s Settings window shares.
public nonisolated enum SettingsLayout {
    /// The width of every tab in every app, so Settings windows match. Wide
    /// enough for a list beside an editor, as in a connections tab.
    public static let width: CGFloat = 680

    /// The first tab, before the app’s own.
    static let generalTitle = "General"
    static let generalSymbol = "gearshape"

    /// The last tab, after the app’s own.
    static let updatesTitle = "Updates"
    static let updatesSymbol = "arrow.down.circle"
}

/// The names `SettingsTabLink` opens tabs by. A `SettingsTab` is named by its
/// title; other tabs get a name with `settingsTabName(_:)`.
public nonisolated enum SettingsTabName {
    public static let general = SettingsLayout.generalTitle
    /// `ConnectionsSettingsTab`.
    public static let connections = "Connections"
    public static let updates = SettingsLayout.updatesTitle
}

/// The tab the Settings window shows, when the app opens tabs by name
/// (`SettingsWindow(opensTabsByName: true)`). Shared by the whole app, as
/// there is one Settings window.
@MainActor
@Observable
final class SettingsTabSelection {
    static let shared = SettingsTabSelection()

    var selected = SettingsTabName.general
    /// Whether the window has a General tab (1.2.0: an app without general
    /// settings has none). Set by `SettingsTabs`.
    @ObservationIgnored var hasGeneralTab = true
    /// Set while a tab has unsaved changes (the Connections editor): called
    /// instead of switching tabs, with `proceed`, which switches once the
    /// person chose Save or Discard. Cancel just doesn’t call it.
    @ObservationIgnored var leaveGuard: (@MainActor (_ proceed: @escaping @MainActor () -> Void) -> Void)?

    /// The tab the person clicked: switched to at once, or after the
    /// unsaved changes of the tab they leave were saved or discarded.
    func request(_ tab: String) {
        guard tab != selected else { return }
        guard let leaveGuard else {
            selected = tab
            return
        }
        leaveGuard { [weak self] in self?.selected = tab }
    }

    /// A named tab’s content appeared. Without a General tab, the window
    /// opens on the first tab while `selected` still says General: the tab
    /// shown takes its place, so clicking it isn’t taken for leaving it.
    func appeared(_ tab: String) {
        if !hasGeneralTab && selected == SettingsTabName.general && tab != selected {
            selected = tab
        }
    }
}

extension EnvironmentValues {
    /// The Settings window’s tab selection, when it opens tabs by name; nil
    /// elsewhere (tabs can then be switched without asking).
    @Entry var settingsTabSelection: SettingsTabSelection?
}

extension View {
    /// Names a tab of the Settings window that isn’t a `SettingsTab`, so
    /// `SettingsTabLink` can open it, e.g. `.settingsTabName("Apple")`.
    public func settingsTabName(_ name: String) -> some View {
        background(SettingsTabAppearance(name: name)).tag(name)
    }
}

/// Tells the tab selection which named tab is shown (`SettingsTabSelection.appeared`).
private struct SettingsTabAppearance: View {
    let name: String
    @Environment(\.settingsTabSelection) private var selection

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onAppear { selection?.appeared(name) }
    }
}

/// A button that opens the Settings window on a named tab, e.g. "Edit
/// Tenants…" opening Connections. Works in menus too.
///
/// The app has to open tabs by name (`SettingsWindow(opensTabsByName: true)`),
/// and every one of its tabs needs a name: `SettingsTab` and
/// `ConnectionsSettingsTab` have one, other tabs get one with
/// `settingsTabName(_:)`. Otherwise the window opens on the tab it shows.
///
/// ```swift
/// SettingsTabLink(SettingsTabName.connections) { Text("Edit Tenants…") }
/// ```
public struct SettingsTabLink<Label: View>: View {
    let tab: String
    let label: Label

    @Environment(\.openSettings) private var openSettings

    public init(_ tab: String, @ViewBuilder label: () -> Label) {
        self.tab = tab
        self.label = label()
    }

    public var body: some View {
        Button {
            SettingsTabSelection.shared.selected = tab
            openSettings()
        } label: {
            label
        }
    }
}

/// The app’s Settings window (⌘,), with tabs in the toolbar: General first
/// with the app’s own general settings, the app’s own tabs next, and Updates
/// (`UpdateSettingsSection`) always last. An app without general settings
/// (only `tabs`) has no General tab.
///
/// The app follows the Mac’s own Light or Dark setting: from 1.2.0 there is
/// no Appearance choice, and a choice saved by an earlier version is ignored.
///
/// ```swift
/// SettingsWindow(updates: updates) {
///     Section { Toggle("Show hints", isOn: $showsHints) }
/// } tabs: {
///     SettingsTab("Connections", systemImage: "network") { ConnectionSections() }
/// }
/// ```
public struct SettingsWindow<General: View, AppTabs: View>: Scene {
    let updates: UpdateChecker
    let opensTabsByName: Bool
    let general: General
    let appTabs: AppTabs

    /// - Parameters:
    ///   - updates: the app’s update checker; the Updates tab uses its setting.
    ///   - opensTabsByName: lets `SettingsTabLink` open a tab. Only when every
    ///     app tab has a name (see `SettingsTabLink`): a tab without one can’t
    ///     be selected then.
    ///   - general: the app’s own `Section`s for the General tab.
    ///   - tabs: the app’s own tabs, each a `SettingsTab` or a view with a `tabItem`.
    public init(
        updates: UpdateChecker,
        opensTabsByName: Bool = false,
        @ViewBuilder general: () -> General,
        @ViewBuilder tabs: () -> AppTabs
    ) {
        self.updates = updates
        self.opensTabsByName = opensTabsByName
        self.general = general()
        self.appTabs = tabs()
    }

    /// The same; `appearanceKey` is ignored (1.2.0: no Appearance choice).
    @available(*, deprecated, message: "There is no Appearance choice any more: leave out appearanceKey.")
    public init(
        updates: UpdateChecker,
        appearanceKey: String,
        opensTabsByName: Bool = false,
        @ViewBuilder general: () -> General,
        @ViewBuilder tabs: () -> AppTabs
    ) {
        self.init(updates: updates, opensTabsByName: opensTabsByName, general: general, tabs: tabs)
    }

    public var body: some Scene {
        Settings {
            SettingsTabs(opensTabsByName: opensTabsByName) { general } tabs: { appTabs }
                .environment(updates)
        }
    }
}

extension SettingsWindow where General == EmptyView {
    /// A Settings window without a General tab: the app’s tabs, then Updates.
    public init(
        updates: UpdateChecker,
        opensTabsByName: Bool = false,
        @ViewBuilder tabs: () -> AppTabs
    ) {
        self.init(updates: updates, opensTabsByName: opensTabsByName, general: { EmptyView() }, tabs: tabs)
    }

    /// The same; `appearanceKey` is ignored (1.2.0: no Appearance choice).
    @available(*, deprecated, message: "There is no Appearance choice any more: leave out appearanceKey.")
    public init(
        updates: UpdateChecker,
        appearanceKey: String,
        opensTabsByName: Bool = false,
        @ViewBuilder tabs: () -> AppTabs
    ) {
        self.init(updates: updates, opensTabsByName: opensTabsByName, tabs: tabs)
    }
}

extension SettingsWindow where General == EmptyView, AppTabs == EmptyView {
    /// A Settings window with only Updates.
    public init(updates: UpdateChecker) {
        self.init(updates: updates) { EmptyView() }
    }

    /// The same; `appearanceKey` is ignored (1.2.0: no Appearance choice).
    @available(*, deprecated, message: "There is no Appearance choice any more: leave out appearanceKey.")
    public init(updates: UpdateChecker, appearanceKey: String) {
        self.init(updates: updates)
    }
}

/// The Settings window’s content: General (when the app has general
/// settings), the app’s tabs, then Updates. Needs the app’s `UpdateChecker`
/// in the environment; `SettingsWindow` puts it there.
public struct SettingsTabs<General: View, AppTabs: View>: View {
    let opensTabsByName: Bool
    let general: General
    let appTabs: AppTabs

    @State private var selection = SettingsTabSelection.shared

    public init(
        opensTabsByName: Bool = false,
        @ViewBuilder general: () -> General,
        @ViewBuilder tabs: () -> AppTabs
    ) {
        self.opensTabsByName = opensTabsByName
        self.general = general()
        self.appTabs = tabs()
        SettingsTabSelection.shared.hasGeneralTab = Self.hasGeneralTab
    }

    /// The same; `appearanceKey` is ignored (1.2.0: no Appearance choice).
    @available(*, deprecated, message: "There is no Appearance choice any more: leave out appearanceKey.")
    public init(
        appearanceKey: String,
        opensTabsByName: Bool = false,
        @ViewBuilder general: () -> General,
        @ViewBuilder tabs: () -> AppTabs
    ) {
        self.init(opensTabsByName: opensTabsByName, general: general, tabs: tabs)
    }

    /// Whether there is a General tab: only when the app passed general settings.
    static var hasGeneralTab: Bool { General.self != EmptyView.self }

    public var body: some View {
        // Without a name on every tab a bound selection would make unnamed
        // tabs unselectable, so apps opt in.
        if opensTabsByName {
            // a tab with unsaved changes can ask before it is left
            TabView(selection: Binding(get: { selection.selected }, set: { selection.request($0) })) { tabs }
                .environment(\.settingsTabSelection, selection)
        } else {
            TabView { tabs }
        }
    }

    @ViewBuilder
    private var tabs: some View {
        if Self.hasGeneralTab {
            SettingsTab(SettingsLayout.generalTitle, systemImage: SettingsLayout.generalSymbol) {
                general
            }
        }
        appTabs
        SettingsTab(SettingsLayout.updatesTitle, systemImage: SettingsLayout.updatesSymbol) {
            UpdateSettingsSection()
        }
    }
}

extension SettingsTabs where General == EmptyView {
    /// Settings content without a General tab, e.g. for a preview:
    /// `SettingsTabs { SettingsTab("Connections", systemImage: "network") { … } }`.
    public init(opensTabsByName: Bool = false, @ViewBuilder tabs: () -> AppTabs) {
        self.init(opensTabsByName: opensTabsByName, general: { EmptyView() }, tabs: tabs)
    }

    /// The same; `appearanceKey` is ignored (1.2.0: no Appearance choice).
    @available(*, deprecated, message: "There is no Appearance choice any more: leave out appearanceKey.")
    public init(appearanceKey: String, opensTabsByName: Bool = false, @ViewBuilder tabs: () -> AppTabs) {
        self.init(opensTabsByName: opensTabsByName, tabs: tabs)
    }
}

/// One tab of the Settings window: the app’s sections in a grouped form, at the
/// shared width, as tall as its content. Its title is also its name for
/// `SettingsTabLink`.
public struct SettingsTab<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    /// - Parameters:
    ///   - title: the tab’s name in the toolbar, e.g. `"Connections"`.
    ///   - systemImage: an SF Symbol for the toolbar, e.g. `"network"`.
    ///   - content: `Section`s; the tab puts them in a grouped `Form`.
    public init(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    public var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width)
        .fixedSize(horizontal: false, vertical: true)
        .tabItem { Label(title, systemImage: systemImage) }
        .settingsTabName(title)
    }
}

#if DEBUG
#Preview {
    SettingsTabs {
        Section {
            Toggle("Show hints", isOn: .constant(true))
        }
    } tabs: {
        SettingsTab("Connections", systemImage: "network") {
            Section("Server") {
                TextField("Server URL", text: .constant("https://example.jamfcloud.com"))
            }
        }
    }
    .environment(UpdateChecker(configuration: UpdateConfiguration(owner: "JordyThery", repository: "Example", appName: "Example")))
}
#endif
