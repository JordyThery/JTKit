import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JTKit

@Suite("About")
struct AboutTests {
    @Test func versionShowsShortVersionAndBuild() {
        #expect(AboutView.versionText(short: "1.2", build: "45") == "Version 1.2 (45)")
    }

    @Test func versionFallsBackLikeTheApps() {
        #expect(AboutView.versionText(short: nil, build: nil) == "Version 1.0 (1)")
    }

    @Test func windowTitleNamesTheApp() {
        #expect(AboutConfiguration(appName: "Checkpoint").windowTitle == "About Checkpoint")
    }

    @Test func copyrightLineDefaultsToMIT() {
        let copyright = AboutCopyright(year: "2026", holder: "Jordy Thery")
        #expect(copyright.license == "MIT License")
        #expect(copyright.text == "© 2026 Jordy Thery. Released under the MIT License.")
    }

    @Test func copyrightLineUsesTheGivenYearAndLicense() {
        let copyright = AboutCopyright(year: "2024–2026", holder: "Someone", license: "Apache License 2.0")
        #expect(copyright.text == "© 2024–2026 Someone. Released under the Apache License 2.0.")
    }

    @Test func noCopyrightLineUnlessTheAppPassesOne() {
        #expect(AboutConfiguration(appName: "Checkpoint").copyright == nil)
    }

    @Test func invalidLinkAddressIsDropped() {
        #expect(AboutLink("Broken", address: "") == nil)
        #expect(AboutLink("GitHub", address: "https://github.com/JordyThery")?.url.host() == "github.com")
    }
}

@Suite("Acknowledgements")
struct AcknowledgementTests {
    @Test func headingNamesTheAuthorWhenKnown() {
        #expect(Acknowledgement(name: "App Settings Utility", author: "Anthony Darlow").heading == "App Settings Utility by Anthony Darlow")
        #expect(Acknowledgement(name: "OpenTofu").heading == "OpenTofu")
    }

    @Test func licenseNameIsItsFirstLine() {
        let mit = Acknowledgement(name: "X", license: "\n  MIT License\n\nCopyright (c) 2026 Someone")
        #expect(mit.licenseName == "MIT License")
        #expect(Acknowledgement(name: "Y").licenseName == nil)
    }

    /// For texts that open with a copyright line, as OpenTofu’s MPL-2.0 does.
    @Test func licenseNameCanBeGiven() {
        let tofu = Acknowledgement(name: "X", license: "Copyright (c) The OpenTofu Authors\n\nMozilla Public License, version 2.0", licenseName: "MPL-2.0")
        #expect(tofu.licenseName == "MPL-2.0")
        #expect(tofu.license == "Copyright (c) The OpenTofu Authors\n\nMozilla Public License, version 2.0")
        // A label without a text shows nothing: there is no license to unfold.
        #expect(Acknowledgement(name: "Y", licenseName: "MPL-2.0").licenseName == nil)
    }

    @Test func licenseTextIsKeptUnchanged() {
        let text = "MIT License\n\n    Indented line\nTHE SOFTWARE IS PROVIDED \"AS IS\""
        #expect(Acknowledgement(name: "X", license: text).license == text)
    }

}

@Suite("Update settings", .serialized)
@MainActor
struct UpdateSettingsTests {
    /// The Settings switch and the automatic check read the same store and key.
    @Test func switchSharesTheCheckersStore() throws {
        let suite = "jtkit-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(
            configuration: UpdateConfiguration(owner: "o", repository: "r", appName: "A", automaticCheckKey: "customKey"),
            defaults: defaults
        )
        #expect(checker.defaults === defaults)
        #expect(checker.configuration.automaticCheckKey == "customKey")
    }

    @Test func defaultKeyIsTheOneEveryAppUses() {
        #expect(UpdateConfiguration(owner: "o", repository: "r", appName: "A").automaticCheckKey == "checksForUpdates")
    }
}

@Suite("Settings window")
struct SettingsWindowTests {
    @Test func everyAppUsesTheSameWidth() {
        #expect(SettingsLayout.width == 680)
    }

    @Test func generalTabIsNamedGeneral() {
        #expect(SettingsLayout.generalTitle == "General")
        #expect(SettingsLayout.generalSymbol == "gearshape")
    }

    /// Serial Number Reader’s Settings preview passes only tabs, with one
    /// trailing closure; a change that stops accepting that breaks its build.
    @MainActor @Test func contentAcceptsOnlyTabs() {
        let tabs = SettingsTabs {
            SettingsTab("Connections", systemImage: "network") {
                Section("Server") {
                    TextField("Server URL", text: .constant(""))
                }
            }
        }
        #expect(generalIsEmpty(tabs))
    }

    /// The same for the window, as Serial Number Reader’s app uses it, and with
    /// no tabs at all.
    @MainActor @Test func windowAcceptsOnlyTabsOrNothing() {
        let original = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = original }
        let updates = UpdateChecker(configuration: UpdateConfiguration(owner: "o", repository: "r", appName: "A"))

        let withTabs = SettingsWindow(updates: updates) {
            SettingsTab("Connections", systemImage: "network") {
                Section { Text("Server") }
            }
        }
        #expect(withTabs.appearanceKey == AppAppearance.defaultKey)
        let updatesOnly = SettingsWindow(updates: updates)
        #expect(updatesOnly.appearanceKey == AppAppearance.defaultKey)
    }

    private func generalIsEmpty<General, AppTabs>(_ tabs: SettingsTabs<General, AppTabs>) -> Bool {
        General.self == EmptyView.self
    }

    @Test func updatesTabIsNamedUpdates() {
        #expect(SettingsLayout.updatesTitle == "Updates")
        #expect(SettingsLayout.updatesSymbol == "arrow.down.circle")
    }
}
