import Observation
import SwiftUI

/// What every app's Settings window shares.
public nonisolated enum SettingsLayout {
    /// The width of every tab in every app, so Settings windows match. Wide
    /// enough for a list beside an editor, as in a connections tab.
    public static let width: CGFloat = 680

    /// The first tab, before the app's own.
    static let generalTitle = "General"
    static let generalSymbol = "gearshape"

    /// The last tab, after the app's own.
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
}

extension View {
    /// Names a tab of the Settings window that isn't a `SettingsTab`, so
    /// `SettingsTabLink` can open it, e.g. `.settingsTabName("Apple")`.
    public func settingsTabName(_ name: String) -> some View {
        tag(name)
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

/// The app's Settings window (⌘,), with tabs in the toolbar: General first,
/// starting with the Appearance picker (`AppAppearance`) and then the app's own
/// general settings, the app's own tabs next, and Updates
/// (`UpdateSettingsSection`) always last.
///
/// It also applies the saved appearance to the whole app when the app starts.
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
    let appearanceKey: String
    let opensTabsByName: Bool
    let general: General
    let appTabs: AppTabs

    /// - Parameters:
    ///   - updates: the app's update checker; the Updates tab uses its setting.
    ///   - appearanceKey: the `UserDefaults` key for the appearance. Keep the default.
    ///   - opensTabsByName: lets `SettingsTabLink` open a tab. Only when every
    ///     app tab has a name (see `SettingsTabLink`): a tab without one can't
    ///     be selected then.
    ///   - general: the app's own `Section`s for the General tab, below Appearance.
    ///   - tabs: the app's own tabs, each a `SettingsTab` or a view with a `tabItem`.
    public init(
        updates: UpdateChecker,
        appearanceKey: String = AppAppearance.defaultKey,
        opensTabsByName: Bool = false,
        @ViewBuilder general: () -> General,
        @ViewBuilder tabs: () -> AppTabs
    ) {
        self.updates = updates
        self.appearanceKey = appearanceKey
        self.opensTabsByName = opensTabsByName
        self.general = general()
        self.appTabs = tabs()
        // The app builds its scenes before any window appears, so the saved
        // choice is in place from the first window on. Applying it again when
        // SwiftUI rebuilds the scenes changes nothing.
        AppAppearance.saved(key: appearanceKey).apply()
    }

    public var body: some Scene {
        Settings {
            SettingsTabs(appearanceKey: appearanceKey, opensTabsByName: opensTabsByName) { general } tabs: { appTabs }
                .environment(updates)
        }
    }
}

extension SettingsWindow where General == EmptyView {
    /// A Settings window whose General tab has only Appearance.
    public init(
        updates: UpdateChecker,
        appearanceKey: String = AppAppearance.defaultKey,
        opensTabsByName: Bool = false,
        @ViewBuilder tabs: () -> AppTabs
    ) {
        self.init(updates: updates, appearanceKey: appearanceKey, opensTabsByName: opensTabsByName,
                  general: { EmptyView() }, tabs: tabs)
    }
}

extension SettingsWindow where General == EmptyView, AppTabs == EmptyView {
    /// A Settings window with only General (Appearance) and Updates.
    public init(updates: UpdateChecker, appearanceKey: String = AppAppearance.defaultKey) {
        self.init(updates: updates, appearanceKey: appearanceKey) { EmptyView() }
    }
}

/// The Settings window's content: General, the app's tabs, then Updates. Needs
/// the app's `UpdateChecker` in the environment; `SettingsWindow` puts it there.
public struct SettingsTabs<General: View, AppTabs: View>: View {
    let appearanceKey: String
    let opensTabsByName: Bool
    let general: General
    let appTabs: AppTabs

    @State private var selection = SettingsTabSelection.shared

    public init(
        appearanceKey: String = AppAppearance.defaultKey,
        opensTabsByName: Bool = false,
        @ViewBuilder general: () -> General,
        @ViewBuilder tabs: () -> AppTabs
    ) {
        self.appearanceKey = appearanceKey
        self.opensTabsByName = opensTabsByName
        self.general = general()
        self.appTabs = tabs()
    }

    public var body: some View {
        // Without a name on every tab a bound selection would make unnamed
        // tabs unselectable, so apps opt in.
        if opensTabsByName {
            TabView(selection: $selection.selected) { tabs }
        } else {
            TabView { tabs }
        }
    }

    @ViewBuilder
    private var tabs: some View {
        SettingsTab(SettingsLayout.generalTitle, systemImage: SettingsLayout.generalSymbol) {
            AppearanceSection(key: appearanceKey, store: .standard)
            general
        }
        appTabs
        SettingsTab(SettingsLayout.updatesTitle, systemImage: SettingsLayout.updatesSymbol) {
            UpdateSettingsSection()
        }
    }
}

extension SettingsTabs where General == EmptyView {
    /// Settings content whose General tab has only Appearance, e.g. for a preview:
    /// `SettingsTabs { SettingsTab("Connections", systemImage: "network") { … } }`.
    public init(appearanceKey: String = AppAppearance.defaultKey, opensTabsByName: Bool = false,
                @ViewBuilder tabs: () -> AppTabs) {
        self.init(appearanceKey: appearanceKey, opensTabsByName: opensTabsByName, general: { EmptyView() }, tabs: tabs)
    }
}

/// One tab of the Settings window: the app's sections in a grouped form, at the
/// shared width, as tall as its content. Its title is also its name for
/// `SettingsTabLink`.
public struct SettingsTab<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    /// - Parameters:
    ///   - title: the tab's name in the toolbar, e.g. `"Connections"`.
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
