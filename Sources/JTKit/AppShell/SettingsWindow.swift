import SwiftUI

/// What every app's Settings window shares.
public nonisolated enum SettingsLayout {
    /// The width of every tab in every app, so Settings windows match.
    public static let width: CGFloat = 520

    /// The last tab, after the app's own.
    static let updatesTitle = "Updates"
    static let updatesSymbol = "arrow.down.circle"
}

/// The app's Settings window (⌘,), with tabs in the toolbar: the app's own tabs
/// first, then Updates (`UpdateSettingsSection`) always last.
///
/// ```swift
/// SettingsWindow(updates: updates) {
///     SettingsTab("Connections", systemImage: "network") { ConnectionSections() }
/// }
/// ```
public struct SettingsWindow<AppTabs: View>: Scene {
    let updates: UpdateChecker
    let appTabs: AppTabs

    /// - Parameters:
    ///   - updates: the app's update checker; the Updates tab uses its setting.
    ///   - tabs: the app's own tabs, each a `SettingsTab`. Leave empty for Updates only.
    public init(updates: UpdateChecker, @ViewBuilder tabs: () -> AppTabs) {
        self.updates = updates
        self.appTabs = tabs()
    }

    public var body: some Scene {
        Settings {
            SettingsTabs { appTabs }
                .environment(updates)
        }
    }
}

extension SettingsWindow where AppTabs == EmptyView {
    /// A Settings window with only the Updates tab.
    public init(updates: UpdateChecker) {
        self.init(updates: updates) { EmptyView() }
    }
}

/// The Settings window's content: the app's tabs, then Updates. Needs the app's
/// `UpdateChecker` in the environment; `SettingsWindow` puts it there.
public struct SettingsTabs<AppTabs: View>: View {
    let appTabs: AppTabs

    public init(@ViewBuilder tabs: () -> AppTabs) {
        self.appTabs = tabs()
    }

    public var body: some View {
        TabView {
            appTabs
            SettingsTab(SettingsLayout.updatesTitle, systemImage: SettingsLayout.updatesSymbol) {
                UpdateSettingsSection()
            }
        }
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
        SettingsTab("Connections", systemImage: "network") {
            Section("Server") {
                TextField("Server URL", text: .constant("https://example.jamfcloud.com"))
            }
        }
    }
    .environment(UpdateChecker(configuration: UpdateConfiguration(owner: "JordyThery", repository: "Example", appName: "Example")))
}
#endif
