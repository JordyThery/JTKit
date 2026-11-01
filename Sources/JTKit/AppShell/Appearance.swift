import AppKit

/// Light, Dark or following the system, as chosen in the Settings window
/// before 1.2.0.
///
/// From 1.2.0 the apps follow the Mac’s own Light or Dark setting, as Apple’s
/// guidelines advise: the Settings window has no Appearance choice, and a
/// choice saved under `defaultKey` is ignored. Kept so code written for
/// earlier versions compiles; it has no effect.
@available(*, deprecated, message: "Apps follow the Mac’s own Light or Dark setting; there is no Appearance choice any more.")
public nonisolated enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    /// The `UserDefaults` key the choice was saved under.
    public static let defaultKey = "appearance"

    public var id: String { rawValue }

    /// The name the picker showed.
    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The choice an earlier version saved, only read: nothing applies it.
    /// Absent or unknown values mean `.system`.
    public static func saved(in store: UserDefaults = .standard, key: String = defaultKey) -> AppAppearance {
        store.string(forKey: key).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    /// Does nothing: the app follows the Mac’s own setting.
    @MainActor public func apply() {}
}
