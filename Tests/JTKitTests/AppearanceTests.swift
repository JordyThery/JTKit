import AppKit
import Foundation
import Testing
@testable import JTKit

@Suite("Appearance")
struct AppearanceTests {
    private func emptyStore() -> UserDefaults {
        let name = "AppearanceTests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func savedUnderTheKeyCheckpointUsed() {
        #expect(AppAppearance.defaultKey == "appearance")
    }

    @Test func savedValuesMatchWhatCheckpointStored() {
        #expect(AppAppearance.allCases.map(\.rawValue) == ["system", "light", "dark"])
    }

    @Test func pickerOffersSystemLightDarkInThatOrder() {
        #expect(AppAppearance.allCases.map(\.label) == ["System", "Light", "Dark"])
    }

    @Test func nothingSavedFollowsTheSystem() {
        #expect(AppAppearance.saved(in: emptyStore()) == .system)
    }

    @Test func unknownValueFollowsTheSystem() {
        let store = emptyStore()
        store.set("sepia", forKey: AppAppearance.defaultKey)
        #expect(AppAppearance.saved(in: store) == .system)
    }

    @Test(arguments: AppAppearance.allCases)
    func readsTheSavedChoice(_ appearance: AppAppearance) {
        let store = emptyStore()
        store.set(appearance.rawValue, forKey: AppAppearance.defaultKey)
        #expect(AppAppearance.saved(in: store) == appearance)
    }

    @Test func readsAnotherKeyWhenGiven() {
        let store = emptyStore()
        store.set("dark", forKey: "theme")
        #expect(AppAppearance.saved(in: store, key: "theme") == .dark)
        #expect(AppAppearance.saved(in: store) == .system)
    }

    @Test func mapsToTheMacAppearances() {
        #expect(AppAppearance.system.appearanceName == nil)
        #expect(AppAppearance.light.appearanceName == .aqua)
        #expect(AppAppearance.dark.appearanceName == .darkAqua)
    }

    @MainActor @Test func appliesToTheWholeApp() {
        let original = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = original }

        AppAppearance.dark.apply()
        #expect(NSApplication.shared.appearance?.name == .darkAqua)
        AppAppearance.light.apply()
        #expect(NSApplication.shared.appearance?.name == .aqua)
        AppAppearance.system.apply()
        #expect(NSApplication.shared.appearance == nil)
    }
}
