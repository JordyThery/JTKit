import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JTKit

/// 1.2.0: no Appearance choice; the app follows the Mac’s own setting. The
/// old API still compiles and changes nothing.
@MainActor
@Suite("Appearance follows the Mac")
struct AppearanceTests {
    @available(*, deprecated)
    @Test func theOldAPIStillCompilesAndChangesNothing() {
        let original = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = original }
        NSApplication.shared.appearance = nil

        #expect(AppAppearance.defaultKey == "appearance")
        #expect(AppAppearance.allCases.map(\.label) == ["System", "Light", "Dark"])
        for choice in AppAppearance.allCases {
            choice.apply()
            #expect(NSApplication.shared.appearance == nil, "\(choice) changed the app’s appearance")
        }
    }

    @available(*, deprecated)
    @Test func aSavedChoiceIsIgnoredBySettings() {
        let original = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = original }
        NSApplication.shared.appearance = nil
        let store = UserDefaults.standard
        let previous = store.object(forKey: AppAppearance.defaultKey)
        defer { store.set(previous, forKey: AppAppearance.defaultKey) }
        store.set("dark", forKey: AppAppearance.defaultKey)

        let updates = UpdateChecker(configuration: UpdateConfiguration(owner: "o", repository: "r", appName: "A"))
        _ = SettingsWindow(updates: updates, appearanceKey: AppAppearance.defaultKey) {
            SettingsTab("Connections", systemImage: "network") { Section { Text("Server") } }
        }
        _ = SettingsWindow(updates: updates)
        #expect(NSApplication.shared.appearance == nil, "the saved Dark wasn’t applied")
    }
}
