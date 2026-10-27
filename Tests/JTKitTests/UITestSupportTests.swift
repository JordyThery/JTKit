import Testing
@testable import JTKit
import JTKitUITestSupport

/// JTKitUITestSupport doesn't link JTKit, so its launch arguments are
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
