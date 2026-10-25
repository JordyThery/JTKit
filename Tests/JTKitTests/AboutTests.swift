import Foundation
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
        #expect(copyright.licence == "MIT License")
        #expect(copyright.text == "© 2026 Jordy Thery. Released under the MIT License.")
    }

    @Test func copyrightLineUsesTheGivenYearAndLicence() {
        let copyright = AboutCopyright(year: "2024–2026", holder: "Someone", licence: "Apache License 2.0")
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

    @Test func licenceNameIsItsFirstLine() {
        let mit = Acknowledgement(name: "X", licence: "\n  MIT License\n\nCopyright (c) 2026 Someone")
        #expect(mit.licenceName == "MIT License")
        #expect(Acknowledgement(name: "Y").licenceName == nil)
    }

    @Test func licenceTextIsKeptUnchanged() {
        let text = "MIT License\n\n    Indented line\nTHE SOFTWARE IS PROVIDED \"AS IS\""
        #expect(Acknowledgement(name: "X", licence: text).licence == text)
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

    @Test func updatesTabIsNamedUpdates() {
        #expect(SettingsLayout.updatesTitle == "Updates")
        #expect(SettingsLayout.updatesSymbol == "arrow.down.circle")
    }
}
