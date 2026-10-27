import XCTest
import AppKit

/// The base class for an app's UI tests (ROADMAP step 11): launches the
/// app's own Debug build, finds and drives elements, and on a failure prints
/// the element tree (`UIDUMP-BEGIN…END`) and keeps a screenshot.
///
/// ```swift
/// final class SmokeUITests: JTKitUITestCase {
///     override var appName: String { "Jamf Deployer" }
///     override func launchApp() { launchInDemo() }
///     func testAbout() { checkAbout() }
/// }
/// ```
///
/// Doesn't link JTKit: the launch arguments are written out here and checked
/// against `DemoMode`'s by a JTKit test.
open class JTKitUITestCase: XCTestCase {
    /// The app under test, launched in `setUpWithError`.
    public var app: XCUIApplication!

    /// A folder of the test's own, removed afterwards: Save panels in demo
    /// mode start here, so nothing lands in the user's folders.
    public private(set) var testFolder: URL!

    /// The app's name as in its bundle, e.g. `"Jamf Deployer"`.
    open var appName: String {
        fatalError("Override appName in \(Self.self)")
    }

    // MARK: Launch arguments (checked against JTKit's DemoMode)

    public static let demoArgument = "-JTKitDemo"
    public static let sandboxArgument = "-JTKitSandbox"
    public static let scenarioArgument = "-JTKitDemoScenario"
    /// The suffix JTKit adds to every window title in demo mode.
    public static let demoTitleSuffix = " — Demo"

    // MARK: Set-up

    override open func setUpWithError() throws {
        continueAfterFailure = false
        testFolder = FileManager.default.temporaryDirectory
            .appending(path: "JTKitUITest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: testFolder, withIntermediateDirectories: true)
        app = makeApp()
        launchApp()
        app.activate()
        didLaunch()
    }

    override open func tearDown() {
        if let run = testRun, run.failureCount > 0, let app {
            print("UIDUMP-BEGIN\n\(app.debugDescription)\nUIDUMP-END")
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Failure — \(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        NSPasteboard.general.clearContents()
        app?.terminate()
        if let testFolder { try? FileManager.default.removeItem(at: testFolder) }
        super.tearDown()
    }

    /// Launches `app`; plain by default. Override to call `launchInDemo()`.
    open func launchApp() {
        app.launch()
    }

    /// Called after each launch, e.g. to enlarge the main window.
    open func didLaunch() {}

    /// Extra arguments for every demo launch, e.g. `["-hasSeenGuidedTour", "YES"]`
    /// (the argument domain: read for this run, never saved).
    open var demoLaunchArguments: [String] { [] }

    /// The Debug build next to the test runner (not an installed release).
    public func makeApp() -> XCUIApplication {
        let products = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent() // …/Runner.app/Contents/PlugIns
            .deletingLastPathComponent() // …/Runner.app/Contents
            .deletingLastPathComponent() // …/Runner.app
            .deletingLastPathComponent() // Build/Products/Debug
        return XCUIApplication(url: products.appending(path: "\(appName).app"))
    }

    /// Launches in demo mode for this run only: demo on (not saved), an
    /// in-memory connections list and secret store, no update check, public
    /// lookups blocked, no restored windows, Save panels in `testFolder`.
    public func launchInDemo(scenario: String? = nil, arguments: [String] = []) {
        app.launchArguments = Self.demoArguments(scenario: scenario, saveFolder: testFolder.path)
            + demoLaunchArguments + arguments
        app.launch()
    }

    /// The arguments `launchInDemo` uses.
    public static func demoArguments(scenario: String? = nil, saveFolder: String? = nil) -> [String] {
        var arguments = [demoArgument, "YES", sandboxArgument, "YES", "-ApplePersistenceIgnoreState", "YES"]
        if let scenario { arguments += [scenarioArgument, scenario] }
        if let saveFolder { arguments += ["-NSNavLastRootDirectory", saveFolder] }
        return arguments
    }

    /// Quits and starts the app again with the same arguments (plus `arguments`).
    public func relaunch(arguments: [String] = []) {
        app.terminate()
        app.launchArguments += arguments
        app.launch()
        app.activate()
        didLaunch()
    }

    // MARK: Elements

    /// A text field in the open sheet, found by its placeholder (form
    /// fields often carry no accessibility label).
    public func field(_ placeholderPrefix: String) -> XCUIElement {
        app.sheets.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", placeholderPrefix)).firstMatch
    }

    /// Any element whose label, title, value or identifier matches.
    public func any(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR title == %@ OR value == %@ OR identifier == %@", text, text, text, text
        )).firstMatch
    }

    /// Any element whose label or value contains the text.
    public func anyContaining(_ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ OR value CONTAINS %@", text, text
        )).firstMatch
    }

    /// An element by its accessibility identifier.
    public func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A button in a sheet, alert or dialog (never a Touch Bar copy).
    public func dialogButton(_ label: String) -> XCUIElement {
        let inSheet = app.sheets.buttons[label].firstMatch
        if inSheet.waitForExistence(timeout: 3) { return inSheet }
        return app.dialogs.buttons[label].firstMatch
    }

    /// An environment variable set by the runner script; skips the test when
    /// it's missing.
    public func env(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw XCTSkip("\(key) is not set for the test runner")
        }
        return value
    }

    // MARK: Actions

    public func tap(_ element: XCUIElement, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let element = element.firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing \(element)", file: file, line: line)
        // Sidebar rows and labels report themselves disabled; only controls are checked.
        if element.elementType != .staticText {
            let enabled = NSPredicate(format: "isEnabled == true")
            let expectation = XCTNSPredicateExpectation(predicate: enabled, object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "Disabled \(element)", file: file, line: line)
        }
        element.click()
    }

    /// Scrolls a long page until a control below (or above) its visible part
    /// can be clicked.
    public func scrollIntoView(_ element: XCUIElement, timeout: TimeInterval = 15) {
        let element = element.firstMatch
        guard element.waitForExistence(timeout: timeout), !element.isHittable,
              let scrollView = app.scrollViews.allElementsBoundByIndex.first(where: {
                  $0.frame.minX <= element.frame.midX && element.frame.midX <= $0.frame.maxX
              })
        else { return }
        var attempts = 0
        while !element.isHittable, attempts < 30 {
            scrollView.scroll(byDeltaX: 0, deltaY: element.frame.midY > scrollView.frame.maxY ? -120 : 120)
            attempts += 1
        }
    }

    public func type(_ text: String, into element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(element)", file: file, line: line)
        element.click()
        element.typeText(text)
    }

    /// Pastes instead of typing so secrets never appear in the test log.
    public func paste(_ text: String, into field: XCUIElement) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        field.click()
        field.typeKey("v", modifierFlags: .command)
        NSPasteboard.general.clearContents()
    }

    public func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 300) -> Bool {
        element.waitForNonExistence(timeout: timeout)
    }

    // MARK: Navigation

    /// Selects a row in the main window's sidebar.
    public func openSidebar(_ label: String) {
        tap(app.outlines.staticTexts[label], timeout: 15)
    }

    /// Confirms an open Save panel in the folder it shows (in demo mode
    /// `testFolder`), replacing a file of the same name.
    public func saveInChosenFolder() {
        tap(app.buttons["OKButton"].firstMatch, timeout: 15)
        // The confirmation's own button, never its Touch Bar copy.
        let inSheet = app.sheets.buttons["Replace"].firstMatch
        let inDialog = app.dialogs.buttons["Replace"].firstMatch
        if inSheet.waitForExistence(timeout: 2) {
            inSheet.click()
        } else if inDialog.exists {
            inDialog.click()
        }
    }

    /// Types a path into an open file panel's Go to Folder field (⌘⇧G).
    public func goToFolder(_ path: String) {
        app.typeKey("g", modifierFlags: [.command, .shift])
        sleep(1)
        app.typeText(path + "\n")
        sleep(1)
    }
}
