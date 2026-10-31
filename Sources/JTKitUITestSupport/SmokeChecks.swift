import XCTest

/// The checks every app’s demo-mode smoke tests share:
/// About, the Settings tabs, the connections editor, the activity log and
/// "— Demo" in every window title. Each leaves the app as it found it, and
/// each first checks that the app runs in demo mode and the sandbox (it
/// fails, doing nothing, when it doesn’t: a plain launch reaches the user’s
/// real saved connections).
extension JTKitUITestCase {
    /// Fails, and is false, unless the app was launched in demo mode and
    /// the sandbox (`launchInDemo()`).
    @discardableResult
    public func requireDemoLaunch(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard Self.isDemoLaunch(app.launchArguments) else {
            XCTFail("Not launched in demo mode and the sandbox (launchInDemo()): the check doesn’t run", file: file, line: line)
            return false
        }
        return true
    }

    /// App menu › About [App] opens JTKit’s About window, which shows the
    /// app’s name and version.
    public func checkAbout(file: StaticString = #filePath, line: UInt = #line) {
        guard requireDemoLaunch(file: file, line: line) else { return }
        tap(app.menuBars.menuBarItems[appName], file: file, line: line)
        tap(app.menuItems["About \(appName)"], file: file, line: line)
        let about = window(titled: "About \(appName)")
        XCTAssertTrue(about.waitForExistence(timeout: 10), "The About window didn’t open", file: file, line: line)
        XCTAssertTrue(about.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Version' OR label BEGINSWITH 'Version'"))
            .firstMatch.waitForExistence(timeout: 5), "About shows no version", file: file, line: line)
        close(about)
    }

    /// ⌘, opens Settings with exactly these tabs in this order; General is
    /// always first and Updates last. Each tab opens when clicked.
    public func checkSettingsTabs(_ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
        guard requireDemoLaunch(file: file, line: line) else { return }
        XCTAssertEqual(expected.first, "General", "General must be the first tab", file: file, line: line)
        XCTAssertEqual(expected.last, "Updates", "Updates must be the last tab", file: file, line: line)
        let settings = openSettings(file: file, line: line)
        let tabs = settings.toolbars.buttons.allElementsBoundByIndex.map { $0.label.isEmpty ? $0.title : $0.label }
        XCTAssertEqual(tabs, expected, "Settings tabs", file: file, line: line)
        for tab in expected {
            tap(settings.toolbars.buttons[tab], file: file, line: line)
            let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "title BEGINSWITH %@", tab), object: settings)
            XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 5), .completed, "The \(tab) tab didn’t open", file: file, line: line)
        }
        close(settings)
    }

    /// Settings › Connections: adds a throwaway connection to the sandbox’s
    /// in-memory list, saves it, then deletes it again.
    ///
    /// - Parameters:
    ///   - service: the + menu item to add, when the + button is a menu.
    ///   - fill: fills the fields the editor needs before Save is enabled,
    ///     with made-up values (e.g. an Environment ID and a client ID); gets
    ///     the Settings window.
    public func checkConnectionsEditor(service: String? = nil, fill: ((XCUIElement) -> Void)? = nil,
                                       file: StaticString = #filePath, line: UInt = #line) {
        guard requireDemoLaunch(file: file, line: line) else { return }
        let tab = openConnectionsTab(file: file, line: line)
        let name = "JTKTEST Throwaway \(Int.random(in: 1000...9999))"
        let add = tab.buttons["Add Connection"].exists ? tab.buttons["Add Connection"] : tab.menuButtons["Add Connection"]
        tap(add, file: file, line: line)
        if let service { tap(app.menuItems[service], file: file, line: line) }
        // The name field by its label, or (unlabeled) by the new connection’s name.
        let labelled = tab.textFields["Name"].firstMatch
        let nameField = labelled.waitForExistence(timeout: 2)
            ? labelled
            : tab.textFields.matching(NSPredicate(format: "value BEGINSWITH 'New '")).firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "The new connection’s editor didn’t open", file: file, line: line)
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(name)
        fill?(tab)
        tap(tab.buttons["Save"], file: file, line: line)
        // A row may read "Name, service · address" as one text.
        let row = tab.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", name, name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The throwaway connection isn’t listed", file: file, line: line)

        row.click()
        tap(tab.buttons["Delete Connection"], file: file, line: line)
        tap(dialogButton("Delete"), file: file, line: line)
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "The throwaway connection wasn’t deleted", file: file, line: line)
        close(tab)
    }

    /// Settings › Connections opens, and its + opens the app’s own add flow
    /// (a sheet), which is then canceled. For apps whose + doesn’t add a
    /// connection directly (Jamf Deployer’s Connect wizard).
    public func checkConnectionsEditorOpens(file: StaticString = #filePath, line: UInt = #line) {
        guard requireDemoLaunch(file: file, line: line) else { return }
        let tab = openConnectionsTab(file: file, line: line)
        let add = tab.buttons["Add Connection"].exists ? tab.buttons["Add Connection"] : tab.menuButtons["Add Connection"]
        tap(add, file: file, line: line)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), "+ opened nothing", file: file, line: line)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10), "The add sheet didn’t close", file: file, line: line)
        close(tab)
    }

    /// ⌘⇧L opens the activity log; it lists requests, and every request
    /// went to a demo server (`*.demo.invalid`) or a host the app names.
    ///
    /// Run it after something that sends requests, e.g. the main task.
    public func checkActivityLog(alsoAllowedHosts: [String] = [], file: StaticString = #filePath, line: UInt = #line) {
        guard requireDemoLaunch(file: file, line: line) else { return }
        app.typeKey("l", modifierFlags: [.command, .shift])
        let log = window(titled: "Activity Log")
        XCTAssertTrue(log.waitForExistence(timeout: 10), "The activity log didn’t open", file: file, line: line)
        // The table shows paths; the selected entry’s detail shows the address.
        let firstRow = log.cells.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "The activity log is empty", file: file, line: line)
        firstRow.click()
        // The demo’s Intune server answers inside the app under Microsoft’s
        // own hosts (DemoIntuneServer.hosts): an app names them.
        let hosts = ["demo.invalid"] + alsoAllowedHosts
        let demoRequest = log.descendants(matching: .any)
            .matching(NSCompoundPredicate(orPredicateWithSubpredicates: hosts.map {
                NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", $0, $0)
            })).firstMatch
        XCTAssertTrue(demoRequest.waitForExistence(timeout: 10), "The selected request didn’t go to a demo server", file: file, line: line)
        let requests = log.descendants(matching: .any)
            .matching(NSPredicate(format: "value CONTAINS 'https://' OR label CONTAINS 'https://'"))
        for element in requests.allElementsBoundByIndex {
            let text = (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
            let allowed = text.contains(".demo.invalid") || alsoAllowedHosts.contains { text.contains($0) }
            XCTAssertTrue(allowed, "A request left demo mode: \(text)", file: file, line: line)
        }
        close(log)
    }

    /// Every open window’s title says " — Demo" (a window’s subtitle may follow).
    public func checkDemoTitles(file: StaticString = #filePath, line: UInt = #line) {
        guard requireDemoLaunch(file: file, line: line) else { return }
        let windows = app.windows.allElementsBoundByIndex.filter { !$0.title.isEmpty }
        XCTAssertFalse(windows.isEmpty, "No window is open", file: file, line: line)
        for window in windows {
            // JTKit renames a window just after it opens.
            let says = XCTNSPredicateExpectation(predicate: NSPredicate(format: "title CONTAINS %@", Self.demoTitleSuffix), object: window)
            let result = XCTWaiter.wait(for: [says], timeout: 5)
            XCTAssertEqual(result, .completed, "“\(window.title)” doesn’t say Demo", file: file, line: line)
        }
    }

    // MARK: Helpers

    /// The window whose title starts with `title` (" — Demo" may follow).
    public func window(titled title: String) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", title)).firstMatch
    }

    /// SwiftUI’s Settings window, by its identifier (its title is the open tab’s).
    public var settingsWindow: XCUIElement {
        app.windows["com_apple_SwiftUI_Settings_window"].firstMatch
    }

    /// Opens Settings (⌘,) on its first tab.
    @discardableResult
    public func openSettings(file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if !settingsWindow.exists { app.typeKey(",", modifierFlags: .command) }
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 10), "Settings didn’t open", file: file, line: line)
        tap(settingsWindow.toolbars.buttons.firstMatch, file: file, line: line)
        return settingsWindow
    }

    /// Closes a window with ⌘W.
    public func close(_ window: XCUIElement) {
        guard window.exists else { return }
        window.click()
        app.typeKey("w", modifierFlags: .command)
        _ = window.waitForNonExistence(timeout: 5)
    }

    private func openConnectionsTab(file: StaticString, line: UInt) -> XCUIElement {
        let settings = openSettings(file: file, line: line)
        tap(settings.toolbars.buttons["Connections"], file: file, line: line)
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "title BEGINSWITH 'Connections'"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 5), .completed, "Settings › Connections didn’t open", file: file, line: line)
        return settings
    }
}
