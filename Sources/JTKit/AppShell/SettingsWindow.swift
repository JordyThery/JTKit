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
    let general: General
    let appTabs: AppTabs

    /// - Parameters:
    ///   - updates: the app's update checker; the Updates tab uses its setting.
    ///   - appearanceKey: the `UserDefaults` key for the appearance. Keep the default.
    ///   - general: the app's own `Section`s for the General tab, below Appearance.
    ///   - tabs: the app's own tabs, each a `SettingsTab` or a view with a `tabItem`.
    public init(
        updates: UpdateChecker,
        appearanceKey: String = AppAppearance.defaultKey,
        @ViewBuilder general: () -> General,
        @ViewBuilder tabs: () -> AppTabs
    ) {
        self.updates = updates
        self.appearanceKey = appearanceKey
        self.general = general()
        self.appTabs = tabs()
        // The app builds its scenes before any window appears, so the saved
        // choice is in place from the first window on. Applying it again when
        // SwiftUI rebuilds the scenes changes nothing.
        AppAppearance.saved(key: appearanceKey).apply()
    }

    public var body: some Scene {
        Settings {
            SettingsTabs(appearanceKey: appearanceKey) { general } tabs: { appTabs }
                .environment(updates)
        }
    }
}

extension SettingsWindow where General == EmptyView {
    /// A Settings window whose General tab has only Appearance.
    public init(
        updates: UpdateChecker,
        appearanceKey: String = AppAppearance.defaultKey,
        @ViewBuilder tabs: () -> AppTabs
    ) {
        self.init(updates: updates, appearanceKey: appearanceKey, general: { EmptyView() }, tabs: tabs)
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
    let general: General
    let appTabs: AppTabs

    public init(
        appearanceKey: String = AppAppearance.defaultKey,
        @ViewBuilder general: () -> General,
        @ViewBuilder tabs: () -> AppTabs
    ) {
        self.appearanceKey = appearanceKey
        self.general = general()
        self.appTabs = tabs()
    }

    public var body: some View {
        TabView {
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
}

extension SettingsTabs where General == EmptyView {
    /// Settings content whose General tab has only Appearance, e.g. for a preview:
    /// `SettingsTabs { SettingsTab("Connections", systemImage: "network") { … } }`.
    public init(appearanceKey: String = AppAppearance.defaultKey, @ViewBuilder tabs: () -> AppTabs) {
        self.init(appearanceKey: appearanceKey, general: { EmptyView() }, tabs: tabs)
    }
}

/// One tab of the Settings window: the app's sections in a grouped form, at the
/// shared width, as tall as its content.
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
