import AppKit
import CoreGraphics
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
        let gitPath = try XCTUnwrap(environment["COINCIDE_UI_GIT_PATH"], "The CI harness must resolve the developer Git executable outside the sandbox.")
        let manager = FileManager.default
        XCTAssertTrue(gitPath.hasPrefix("/") && gitPath != "/usr/bin/git" && manager.isExecutableFile(atPath: gitPath))
        // Xcode sandboxes its generated runner, even with ENABLE_APP_SANDBOX=NO.
        // Foundation supplies writable temporary storage belonging to that runner.
        let requestedRoot = manager.temporaryDirectory.appendingPathComponent("coincide-ui-testing-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: requestedRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let root = requestedRoot.resolvingSymlinksInPath()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
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
        // XCTest invokes teardown blocks even when a failed assertion aborts a test.
        addTeardownBlock { @MainActor [weak self] in
            if app.state != .notRunning {
                let tree = XCTAttachment(string: app.debugDescription); tree.name = "\(appearance)-final-accessibility-tree"; tree.lifetime = .keepAlways; self?.add(tree)
                if app.windows.firstMatch.exists {
                    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                    screenshot.name = "\(appearance)-final-window"; screenshot.lifetime = .keepAlways; self?.add(screenshot)
                }
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
        if done.exists {
            let warning = XCTAttachment(string: app.debugDescription); warning.name = "\(appearance)-initial-commit-warning"; warning.lifetime = .keepAlways; add(warning)
            done.click() // A nonfatal initial-commit warning still means project creation succeeded.
        }
        let header = app.buttons["Collapse \(projectName)"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let layout = XCTAttachment(string: "Display frame: \(CGDisplayBounds(CGMainDisplayID()))\nWindow frame: \(app.windows.firstMatch.frame)\n\n\(app.debugDescription)")
        layout.name = "\(appearance)-created-layout-and-accessibility"; layout.lifetime = .keepAlways; add(layout)
        assertSidebarFitsDisplay(app, projectHeader: header)
        capture(app, name: "\(appearance)-created")
        let projectFolders = try manager.contentsOfDirectory(at: root.appendingPathComponent("Projects"), includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        XCTAssertEqual(projectFolders.count, 1)
        let projectFolder = try XCTUnwrap(projectFolders.first)
        let initialHead = try verifyHead(gitPath: gitPath, project: projectFolder, configuration: configuration, name: "\(appearance)-initial-git-head")
        let preservedPaths = ["README.md", "assets/icon.svg", ".git/HEAD"]
        let preservedFiles = try Dictionary(uniqueKeysWithValues: preservedPaths.map { ($0, try Data(contentsOf: projectFolder.appendingPathComponent($0))) })
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10) && composer.isHittable)
        let draft = "Synthetic draft retained through sidebar changes"
        composer.click(); composer.typeText(draft)
        XCTAssertEqual(composer.value as? String, draft)

        header.rightClick()
        let rename = app.menuItems["Rename Project…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5)); rename.click()
        // Native SwiftUI alert text fields preserve their placeholder/value, but
        // macOS does not bridge this field's SwiftUI accessibility identifier.
        let renameSheet = app.sheets.containing(.button, identifier: "sidebar-rename-save").element
        XCTAssertTrue(renameSheet.waitForExistence(timeout: 5))
        XCTAssertEqual(renameSheet.textFields.count, 1)
        let renameField = renameSheet.textFields.element
        XCTAssertTrue(renameField.waitForExistence(timeout: 5)); renameField.click()
        XCTAssertEqual(renameField.value as? String, projectName)
        renameField.typeKey("a", modifierFlags: .command)
        let renamed = projectName + " Renamed"
        renameField.typeText(renamed); app.buttons["sidebar-rename-save"].click()
        let renamedHeader = app.buttons["Collapse \(renamed)"]
        XCTAssertTrue(renamedHeader.waitForExistence(timeout: 5)); renamedHeader.click()
        XCTAssertTrue(app.buttons["Expand \(renamed)"].waitForExistence(timeout: 5))
        let selected = app.outlineRows.containing(NSPredicate(format: "identifier BEGINSWITH %@", "thread-")).element
        XCTAssertTrue(selected.waitForExistence(timeout: 5) && selected.isSelected, "Collapsing must keep the selected conversation visible.")
        XCTAssertEqual(composer.value as? String, draft)
        assertSidebarFitsDisplay(app, projectHeader: app.buttons["Expand \(renamed)"])
        capture(app, name: "\(appearance)-collapsed-selected")

        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Graceful quit must flush the composer draft.")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.buttons["Expand \(renamed)"].waitForExistence(timeout: 10), "The renamed project and collapsed state must persist.")
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); XCTAssertEqual(composer.value as? String, draft)
        XCTAssertTrue(selected.exists && selected.isSelected)
        assertSidebarFitsDisplay(app, projectHeader: app.buttons["Expand \(renamed)"])
        capture(app, name: "\(appearance)-reopened")
        let tree = XCTAttachment(string: app.debugDescription); tree.name = "\(appearance)-reopened-accessibility-tree"; tree.lifetime = .keepAlways; add(tree)

        let collapsedHeader = app.buttons["Expand \(renamed)"]
        collapsedHeader.rightClick()
        let removeItem = app.menuItems["Remove Project…"]
        XCTAssertTrue(removeItem.waitForExistence(timeout: 5)); removeItem.click()
        let removalTitle = "Remove “\(renamed)” from Coincide?"
        let confirmationTitle = app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", removalTitle, removalTitle)).element
        let confirmRemove = app.buttons["Remove Project"]
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 5) && confirmRemove.exists)
        let explanation = app.staticTexts.matching(NSPredicate(format: "(label CONTAINS %@ OR value CONTAINS %@) AND (label CONTAINS %@ OR value CONTAINS %@)", "Git may clean up unfinished files", "Git may clean up unfinished files", "local recovery history", "local recovery history")).element
        XCTAssertTrue(explanation.waitForExistence(timeout: 5), "Removal must explain active-Git cleanup and retained recovery history.")
        app.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(confirmRemove, timeout: 5))
        XCTAssertTrue(collapsedHeader.exists && composer.exists)
        XCTAssertEqual(composer.value as? String, draft, "Cancelling removal must preserve the selected conversation and its draft.")

        collapsedHeader.rightClick()
        XCTAssertTrue(removeItem.waitForExistence(timeout: 5)); removeItem.click()
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 5) && confirmRemove.exists && explanation.exists)
        confirmRemove.click()
        XCTAssertTrue(waitForAbsence(collapsedHeader, timeout: 10), "Confirmed removal must remove the project from the sidebar.")
        XCTAssertTrue(waitForAbsence(composer, timeout: 5), "Confirmed removal must clear the removed conversation.")
        for path in preservedPaths {
            XCTAssertEqual(try Data(contentsOf: projectFolder.appendingPathComponent(path)), preservedFiles[path], "Removing a registered project must preserve its existing \(path) bytes.")
        }
        XCTAssertEqual(try verifyHead(gitPath: gitPath, project: projectFolder, configuration: configuration, name: "\(appearance)-removed-git-head"), initialHead)
        let emptyDescription = "Your projects and coding agents, in a native Mac workspace."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", emptyDescription, emptyDescription)).element.waitForExistence(timeout: 5))
        capture(app, name: "\(appearance)-removed-empty-workspace")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor private func verifyHead(gitPath: String, project: URL, configuration: URL, name: String) throws -> String {
        let git = Process(); git.executableURL = URL(fileURLWithPath: gitPath)
        git.arguments = ["-C", project.path, "rev-parse", "--verify", "HEAD"]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = configuration.path; environment["GIT_CONFIG_NOSYSTEM"] = "1"
        git.environment = environment
        let output = Pipe(), errors = Pipe(); git.standardOutput = output; git.standardError = errors
        try git.run(); git.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let diagnostic = XCTAttachment(string: "Git: \(gitPath)\nExit: \(git.terminationStatus)\nstdout:\n\(stdout)\nstderr:\n\(stderr)")
        diagnostic.name = name; diagnostic.lifetime = .keepAlways; add(diagnostic)
        XCTAssertEqual(git.terminationStatus, 0, "The created native project must contain its initial Git commit. Git stderr: \(stderr)")
        let head = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(head.isEmpty)
        return head
    }

    @MainActor private func waitForAbsence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists && window.isHittable && app.state == .runningForeground)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(window.frame), "The native window must fit entirely on the hosted display: \(window.frame).")
        let screenshot = window.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        // xcresulttool exports the retained PNG outside the sandbox after testing.
    }

    @MainActor private func assertSidebarFitsDisplay(_ app: XCUIApplication, projectHeader: XCUIElement) {
        let display = CGDisplayBounds(CGMainDisplayID())
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(display.contains(window), "The native window must fit the actual display \(display), without clipping: \(window).")
        let controls: [(String, XCUIElement)] = [
            ("New conversation", app.buttons["New conversation"]),
            ("Sort projects", app.menuButtons["project-sort-menu"]),
            ("Search conversations", app.textFields["Search conversations"]),
            ("Project header", projectHeader),
            ("Selected conversation", app.outlineRows.containing(NSPredicate(format: "identifier BEGINSWITH %@", "thread-")).element),
            ("Add Project", app.menuButtons["folder.badge.plus"]),
            ("Settings", app.buttons["gearshape"]),
            ("Archive", app.checkBoxes["Archive"]),
        ]
        for (name, control) in controls {
            XCTAssertTrue(control.exists, "The sidebar must expose its \(name) control.")
            let frame = control.frame
            XCTAssertTrue(frame.width > 0 && frame.height > 0 && window.contains(frame) && display.contains(frame),
                          "The \(name) control must be wholly inside the window and display, without clipping: \(frame).")
        }
    }
}
