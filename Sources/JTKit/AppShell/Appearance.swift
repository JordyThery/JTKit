import AppKit
import SwiftUI

/// Light, Dark or following the system, for the whole app. Chosen in the
/// General tab of the shared Settings window (`AppearanceSection`) and saved in
/// `UserDefaults` under `defaultKey`.
public nonisolated enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    /// The `UserDefaults` key the choice is saved under, the name the apps
    /// already used (Checkpoint), so a saved choice carries over.
    public static let defaultKey = "appearance"

    public var id: String { rawValue }

    /// The name in the picker.
    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The AppKit appearance to set on the app; nil follows the system.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    /// The saved choice. Absent or unknown values mean `.system`.
    public static func saved(in store: UserDefaults = .standard, key: String = defaultKey) -> AppAppearance {
        store.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    /// Sets this appearance on every window of the app, including JTKit's
    /// About and Settings windows.
    @MainActor public func apply() {
        NSApplication.shared.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }
}

/// The Appearance picker, always first in the Settings window's General tab.
/// Saves the choice and applies it to the whole app as it changes.
struct AppearanceSection: View {
    @AppStorage private var rawValue: String

    init(key: String, store: UserDefaults) {
        _rawValue = AppStorage(wrappedValue: AppAppearance.system.rawValue, key, store: store)
    }

    private var appearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: rawValue) ?? .system },
            set: { rawValue = $0.rawValue }
        )
    }

    var body: some View {
        Section {
            Picker("Appearance", selection: appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
        .onChange(of: rawValue) {
            appearance.wrappedValue.apply()
        }
    }
}
