import SwiftUI

/// The Updates section for an app’s Settings: the daily-check switch. Checking
/// now stays in the app menu ("Check for Updates…").
///
/// Put it in a grouped `Form`, with the app’s `UpdateChecker` in the environment.
/// The switch uses the checker’s `automaticCheckKey`, so saved choices keep working.
struct UpdateSettingsSection: View {
    @Environment(UpdateChecker.self) private var checker

    public init() {}

    public var body: some View {
        let appName = checker.configuration.appName
        Section {
            AutomaticCheckToggle(key: checker.configuration.automaticCheckKey, store: checker.defaults)
        } header: {
            Text("Updates")
        } footer: {
            Text("Once a day, \(appName) asks GitHub whether a newer version exists. To check now, choose Check for Updates… in the \(appName) menu.")
                .foregroundStyle(.secondary)
        }
    }
}

/// A separate view so `@AppStorage` can take the key from the checker.
private struct AutomaticCheckToggle: View {
    @AppStorage private var isOn: Bool

    init(key: String, store: UserDefaults) {
        // Absent means on, as in `UpdateChecker.checkAutomatically()`.
        _isOn = AppStorage(wrappedValue: true, key, store: store)
    }

    var body: some View {
        Toggle("Check for updates daily", isOn: $isOn)
    }
}

#if DEBUG
#Preview {
    Form {
        UpdateSettingsSection()
    }
    .formStyle(.grouped)
    .environment(UpdateChecker(configuration: UpdateConfiguration(owner: "JordyThery", repository: "Example", appName: "Example")))
}
#endif
