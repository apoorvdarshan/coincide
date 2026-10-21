import AppKit
import XCTest

final class CoincideDesktopUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testLightAppearanceFileMenuProjectWorkflow() throws {
        try exerciseProjectWorkflow(appearance: "light", useKeyboard: false)
    }

    @MainActor func testDarkAppearanceKeyboardProjectWorkflow() throws {
        try exerciseProjectWorkflow(appearance: "dark", useKeyboard: true)
    }

    @MainActor private func exerciseProjectWorkflow(appearance: String, useKeyboard: Bool) throws {
        let environment = ProcessInfo.processInfo.environment
        let appPath = try XCTUnwrap(environment["COINCIDE_UI_APP_PATH"], "The CI harness must supply the staged app.")
        let manager = FileManager.default
        // Xcode sandboxes its generated runner, even with ENABLE_APP_SANDBOX=NO.
        // Foundation supplies writable temporary storage belonging to that runner.
        let requestedRoot = manager.temporaryDirectory.appendingPathComponent("coincide-ui-testing-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: requestedRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = requestedRoot.resolvingSymlinksInPath()
        defer { try? manager.removeItem(at: root) }
        let hooks = root.appendingPathComponent("empty-hooks", isDirectory: true)
        try manager.createDirectory(at: hooks, withIntermediateDirectories: false)
        let configuration = root.appendingPathComponent("gitconfig")
        let quotedHooks = hooks.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        try "[user]\n name = Coincide UI Test\n email = ui-test@example.invalid\n[commit]\n gpgSign = false\n[core]\n hooksPath = \"\(quotedHooks)\"\n"
            .write(to: configuration, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configuration.path)
        let app = XCUIApplication(url: URL(fileURLWithPath: appPath))
        app.launchEnvironment["COINCIDE_UI_TESTING"] = "1"
        app.launchEnvironment["COINCIDE_UI_TEST_ROOT"] = root.path
        // Supply a private config to this disposable app's Git children; never change the runner's config.
        app.launchEnvironment["GIT_CONFIG_GLOBAL"] = configuration.path
        app.launchEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"
        app.launchArguments = ["-appearance", appearance]
        defer {
            if app.state != .notRunning {
                let tree = XCTAttachment(string: app.debugDescription); tree.name = "\(appearance)-final-accessibility-tree"; tree.lifetime = .keepAlways; add(tree)
                app.terminate()
            }
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "The native app must have a foreground window.")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let projectName = "GUI \(appearance.capitalized) Project"
        if useKeyboard {
            app.typeKey("n", modifierFlags: [.command, .shift])
        } else {
            app.menuBars.menuBarItems["File"].click()
            let item = app.menuItems["New Project…"]
            XCTAssertTrue(item.waitForExistence(timeout: 5)); item.click()
        }
        let name = app.textFields["new-project-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.click(); name.typeText(projectName)
        let create = app.buttons["create-project"]
        XCTAssertTrue(create.waitForExistence(timeout: 5) && create.isEnabled); create.click()
        XCTAssertTrue(waitForAbsence(create, timeout: 20), "Creation must settle without leaving the modal busy.")
        let done = app.buttons["project-created-done"]
        if done.exists { done.click() } // A nonfatal initial-commit warning still means project creation succeeded.
        let header = app.buttons["Collapse \(projectName)"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let projectFolders = try manager.contentsOfDirectory(at: root.appendingPathComponent("Projects"), includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        XCTAssertEqual(projectFolders.count, 1)
        let projectFolder = try XCTUnwrap(projectFolders.first)
        let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", projectFolder.path, "rev-parse", "--verify", "HEAD"]
        git.standardOutput = Pipe(); git.standardError = Pipe(); try git.run(); git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0, "The created native project must contain its initial Git commit.")
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10) && composer.isHittable)
        let draft = "Synthetic draft retained through sidebar changes"
        composer.click(); composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)

        header.rightClick()
        let rename = app.menuItems["Rename Project…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5)); rename.click()
        let renameField = app.textFields["sidebar-rename-title"]
        XCTAssertTrue(renameField.waitForExistence(timeout: 5)); renameField.click()
        renameField.typeKey("a", modifierFlags: .command)
        let renamed = projectName + " Renamed"
        renameField.typeText(renamed); app.buttons["sidebar-rename-save"].click()
        let renamedHeader = app.buttons["Collapse \(renamed)"]
        XCTAssertTrue(renamedHeader.waitForExistence(timeout: 5)); renamedHeader.click()
        XCTAssertTrue(app.buttons["Expand \(renamed)"].waitForExistence(timeout: 5))
        let outlineRow = app.outlineRows.containing(.staticText, identifier: "New thread").firstMatch
        let selected = outlineRow.exists ? outlineRow : app.tableRows.containing(.staticText, identifier: "New thread").firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 5) && selected.isSelected, "Collapsing must keep the selected conversation visible.")
        XCTAssertEqual(composer.value as? String, draft)
        capture(app, name: "\(appearance)-collapsed-selected")

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Graceful quit must flush the composer draft.")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.buttons["Expand \(renamed)"].waitForExistence(timeout: 10), "The renamed project and collapsed state must persist.")
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); XCTAssertEqual(composer.value as? String, draft)
        XCTAssertTrue(selected.exists && selected.isSelected)
        capture(app, name: "\(appearance)-reopened")
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "\(appearance)-reopened-accessibility-tree"; tree.lifetime = .keepAlways; add(tree)
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists && window.isHittable && app.state == .runningForeground)
        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        // xcresulttool exports the retained PNG outside the sandbox after testing.
    }
}
