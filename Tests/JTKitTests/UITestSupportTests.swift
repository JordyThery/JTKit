import Testing
import XCTest
@testable import JTKit
@testable import JTKitUITestSupport

/// JTKitUITestSupport doesn’t link JTKit, so its launch arguments are
/// written out; they must stay the ones DemoMode reads.
@Suite("UI test support")
struct UITestSupportTests {
    @Test func launchArgumentsMatchDemoMode() {
        #expect(JTKitUITestCase.demoArgument == DemoMode.launchArgument)
        #expect(JTKitUITestCase.sandboxArgument == DemoMode.sandboxArgument)
        #expect(JTKitUITestCase.scenarioArgument == DemoMode.scenarioArgument)
        #expect(JTKitUITestCase.demoTitleSuffix == DemoMode.titleSuffix)
    }

    @Test @MainActor func demoArgumentsTurnOnDemoAndSandbox() {
        let arguments = JTKitUITestCase.demoArguments(scenario: "missingPermission", saveFolder: "/tmp/x")
        let demo = DemoMode(key: "uiTestSupportTests", defaults: DemoMode.sandboxDefaults(), arguments: ["App"] + arguments)
        #expect(demo.isOn)
        #expect(demo.isSandbox)
        #expect(demo.scenario == .missingPermission)
        #expect(arguments.contains("-ApplePersistenceIgnoreState"))
        #expect(arguments.suffix(2) == ["-NSNavLastRootDirectory", "/tmp/x"])
    }
}

@Suite("UI test support: safety under the release check")
struct UITestSupportSafetyTests {
    @Test("A demo launch needs both demo mode and the sandbox switched on")
    func demoLaunchNeedsDemoAndSandbox() {
        #expect(JTKitUITestCase.isDemoLaunch(JTKitUITestCase.demoArguments()))
        #expect(JTKitUITestCase.isDemoLaunch(JTKitUITestCase.demoArguments(scenario: "empty", saveFolder: "/tmp") + ["-x", "YES"]))
        #expect(!JTKitUITestCase.isDemoLaunch([]), "a plain launch")
        #expect(!JTKitUITestCase.isDemoLaunch(["-JTKitDemo", "YES"]), "no sandbox: real saved connections")
        #expect(!JTKitUITestCase.isDemoLaunch(["-JTKitSandbox", "YES"]))
        #expect(!JTKitUITestCase.isDemoLaunch(JTKitUITestCase.demoArguments() + ["-JTKitSandbox", "NO"]), "the last value counts")
    }

    @Test("A missing setting fails under the release check, and only skips outside it")
    func missingSettingFailsUnderTheReleaseCheck() throws {
        #expect(try JTKitUITestCase.setting("URL", in: ["URL": "https://x.example"]) == "https://x.example")
        #expect(throws: JTKitUITestCase.MissingSetting.self) {
            try JTKitUITestCase.setting("URL", in: ["JTKIT_RELEASE_CHECK": "1"])
        }
        #expect(throws: JTKitUITestCase.MissingSetting.self) {
            try JTKitUITestCase.setting("URL", in: ["JTKIT_RELEASE_CHECK": "1", "URL": ""])
        }
        #expect(throws: XCTSkip.self) { try JTKitUITestCase.setting("URL", in: [:]) }
        #expect(JTKitUITestCase.isReleaseCheck(["JTKIT_RELEASE_CHECK": "1"]))
        #expect(!JTKitUITestCase.isReleaseCheck([:]))
    }

    @Test("The failure dump shows types, identifiers and labels, never a value")
    func failureDumpHasNoValues() {
        let tree = JTKitUITestCase.ElementNode(type: "Window", identifier: "main", label: "", children: [
            .init(type: "SecureTextField", identifier: "secret", label: "Client Secret", children: []),
            .init(type: "Button", identifier: "", label: "Save", children: []),
        ])
        #expect(JTKitUITestCase.outline(tree) == """
        Window id=“main”
          SecureTextField id=“secret” label=“Client Secret”
          Button label=“Save”

        """)
        #expect(JTKitUITestCase.typeName(.secureTextField) == "SecureTextField")
    }
}

@Suite("UI test support: the screenshot at a failure")
struct UITestSupportFailureScreenshotTests {
    @Test("A failing test gets one screenshot, named and kept on failure only")
    func screenshotOnFailure() throws {
        var captures = 0
        let shot = try #require(JTKitUITestCase.failureScreenshot(failed: true, alreadyAttached: false) {
            captures += 1
            return XCTAttachment(string: "window")
        })
        #expect(captures == 1)
        #expect(shot.name == "Window at failure")
        #expect(shot.name == JTKitUITestCase.failureScreenshotName)
        #expect(shot.lifetime == .deleteOnSuccess)
    }

    @Test("No screenshot, and nothing captured, for a passing test or a second failure")
    func noScreenshotOtherwise() {
        var captures = 0
        let capture = { () -> XCTAttachment in
            captures += 1
            return XCTAttachment(string: "window")
        }
        #expect(JTKitUITestCase.failureScreenshot(failed: false, alreadyAttached: false, capture: capture) == nil)
        #expect(JTKitUITestCase.failureScreenshot(failed: true, alreadyAttached: true, capture: capture) == nil)
        #expect(captures == 0)
    }
}
