import AppKit
import CoreGraphics
import Vision
import XCTest

final class CoincideDesktopUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testLightAppearanceFileMenuProjectWorkflow() throws {
        try exerciseProjectWorkflow(appearance: "light", useKeyboard: false)
    }

    @MainActor func testDarkAppearanceKeyboardProjectWorkflow() throws {
        try exerciseProjectWorkflow(appearance: "dark", useKeyboard: true)
    }

    @MainActor func testRepositoryGroupingKeepsCheckoutDrafts() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "grouping")
        let app = fixture.app
        let first = fixture.root.appendingPathComponent("Checkout One", isDirectory: true)
        let second = fixture.root.appendingPathComponent("Checkout Two", isDirectory: true)
        for checkout in [first, second] {
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: false)
            try "Synthetic local checkout: \(checkout.lastPathComponent)\n".write(to: checkout.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            for arguments in [["init", "--initial-branch", "main"], ["remote", "add", "origin", "https://example.invalid/Team/Repo.git"], ["add", "README.md"], ["commit", "--message", "Synthetic UI fixture"]] {
                _ = try runGit(["-C", checkout.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration,
                               name: "grouping-\(checkout.lastPathComponent)-\(arguments[0])")
            }
        }
        let firstHead = try verifyHead(gitPath: fixture.gitPath, project: first, configuration: fixture.configuration, name: "grouping-first-initial-head")
        let secondHead = try verifyHead(gitPath: fixture.gitPath, project: second, configuration: fixture.configuration, name: "grouping-second-initial-head")
        var originalFiles: [URL: Data] = [:]
        for checkout in [first, second] {
            for relativePath in ["README.md", ".git/HEAD"] {
                let file = checkout.appendingPathComponent(relativePath)
                originalFiles[file] = try Data(contentsOf: file)
            }
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try openProject(first, in: app)
        XCTAssertTrue(app.buttons["Collapse Checkout One"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let firstDraft = "Draft belonging only to checkout one"
        composer.click(); composer.typeText(firstDraft)
        XCTAssertEqual(composer.value as? String, firstDraft)
        assertConversationWorkspace(app, path: first.path)
        let firstThreadID = try selectedThreadIdentifier(in: app)

        try openProject(second, in: app)
        let groupedHeader = app.buttons["Collapse Team/Repo"]
        XCTAssertTrue(groupedHeader.waitForExistence(timeout: 15), "Equivalent local Git remotes must form one repository group.")
        XCTAssertEqual(projectHeaders(in: app).count, 1)
        groupedHeader.rightClick()
        let createInCheckout = app.menuItems["New Thread in Checkout"]
        XCTAssertTrue(createInCheckout.waitForExistence(timeout: 5)); createInCheckout.click()
        let secondCheckout = createInCheckout.menuItems.matching(NSPredicate(format: "title == %@", second.path)).element
        XCTAssertTrue(secondCheckout.waitForExistence(timeout: 5)); secondCheckout.click()
        XCTAssertTrue(waitForValue(composer, value: "", timeout: 10))
        assertConversationWorkspace(app, path: second.path)
        let secondDraft = "Draft belonging only to checkout two"
        composer.click(); composer.typeText(secondDraft)
        XCTAssertEqual(composer.value as? String, secondDraft)
        let secondThreadID = try selectedThreadIdentifier(in: app)
        XCTAssertNotEqual(firstThreadID, secondThreadID)

        groupedHeader.rightClick()
        let checkouts = app.menuItems["Checkouts"]
        XCTAssertTrue(checkouts.waitForExistence(timeout: 5)); checkouts.click()
        XCTAssertTrue(checkouts.menuItems.matching(NSPredicate(format: "title == %@", first.path)).element.waitForExistence(timeout: 5))
        XCTAssertTrue(checkouts.menuItems.matching(NSPredicate(format: "title == %@", second.path)).element.exists, "The native checkout menu must expose both physical paths.")
        app.typeKey(.escape, modifierFlags: []); app.typeKey(.escape, modifierFlags: [])
        let checkoutPreference = app.descendants(matching: .any).matching(identifier: "new-conversation-checkout").element
        XCTAssertTrue(checkoutPreference.waitForExistence(timeout: 5)); checkoutPreference.click()
        let firstChoice = app.menuItems.matching(NSPredicate(format: "title == %@", first.path)).element
        XCTAssertTrue(firstChoice.waitForExistence(timeout: 5)); firstChoice.click()
        XCTAssertTrue(threadRow(secondThreadID, in: app).isSelected)
        XCTAssertEqual(composer.value as? String, secondDraft, "Choosing a future checkout must preserve the selected conversation's draft.")
        assertConversationWorkspace(app, path: second.path)
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(waitForValue(composer, value: "", timeout: 10))
        assertConversationWorkspace(app, path: first.path)
        let futureThreadID = try selectedThreadIdentifier(in: app)
        XCTAssertNotEqual(futureThreadID, firstThreadID); XCTAssertNotEqual(futureThreadID, secondThreadID)
        XCTAssertEqual(threadRows(in: app).count, 3)
        let futureDraft = "Distinct draft in the preferred checkout one"
        composer.click(); composer.typeText(futureDraft)
        XCTAssertEqual(composer.value as? String, futureDraft)

        selectThread(firstThreadID, in: app)
        XCTAssertTrue(waitForValue(composer, value: firstDraft, timeout: 5))
        assertConversationWorkspace(app, path: first.path)
        selectThread(secondThreadID, in: app)
        XCTAssertTrue(waitForValue(composer, value: secondDraft, timeout: 5))
        assertConversationWorkspace(app, path: second.path)
        assertSidebarFitsDisplay(app, projectHeader: groupedHeader, selectedConversation: threadRow(secondThreadID, in: app))
        capture(app, name: "grouping-repository-with-checkout-drafts")

        setGroupingMode("Separate Checkouts", in: app)
        let firstHeader = app.buttons["Collapse Checkout One"], secondHeader = app.buttons["Collapse Checkout Two"]
        XCTAssertTrue(firstHeader.waitForExistence(timeout: 5) && secondHeader.exists)
        XCTAssertEqual(projectHeaders(in: app).count, 2)
        XCTAssertEqual(threadRows(in: app).count, 3)
        XCTAssertTrue(threadRow(secondThreadID, in: app).isSelected)
        XCTAssertEqual(composer.value as? String, secondDraft)
        assertConversationWorkspace(app, path: second.path)
        assertSidebarFitsDisplay(app, projectHeader: firstHeader, selectedConversation: threadRow(secondThreadID, in: app))
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(secondHeader.frame))
        capture(app, name: "grouping-separate-checkouts")
        setGroupingMode("Repository", in: app)
        XCTAssertTrue(groupedHeader.waitForExistence(timeout: 5))
        XCTAssertEqual(projectHeaders(in: app).count, 1)
        XCTAssertEqual(threadRows(in: app).count, 3)
        XCTAssertTrue(threadRow(secondThreadID, in: app).isSelected)
        XCTAssertEqual(composer.value as? String, secondDraft)
        capture(app, name: "grouping-repository-restored")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(groupedHeader.waitForExistence(timeout: 10))
        XCTAssertEqual(projectHeaders(in: app).count, 1)
        XCTAssertEqual(threadRows(in: app).count, 3)
        XCTAssertTrue(threadRow(secondThreadID, in: app).isSelected)
        XCTAssertTrue(waitForValue(composer, value: secondDraft, timeout: 5))
        assertConversationWorkspace(app, path: second.path)
        capture(app, name: "grouping-reopened")
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: first, configuration: fixture.configuration, name: "grouping-first-final-head"), firstHead)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: second, configuration: fixture.configuration, name: "grouping-second-final-head"), secondHead)

        groupedHeader.rightClick()
        let renameGroup = app.menuItems["Rename Group…"]
        XCTAssertTrue(renameGroup.waitForExistence(timeout: 5)); renameGroup.click()
        let renameSheet = app.sheets.containing(.button, identifier: "sidebar-rename-save").element
        XCTAssertTrue(renameSheet.waitForExistence(timeout: 5))
        XCTAssertTrue(renameSheet.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Rename Group", "Rename Group")).element.exists)
        XCTAssertEqual(renameSheet.textFields.count, 1)
        let renameField = renameSheet.textFields.element
        XCTAssertEqual(renameField.value as? String, "Team/Repo")
        renameField.click(); renameField.typeKey("a", modifierFlags: .command)
        let renamedGroup = "Native UI Group Renamed"
        renameField.typeText(renamedGroup); renameSheet.buttons["sidebar-rename-save"].click()
        let renamedHeader = app.buttons["Collapse \(renamedGroup)"]
        XCTAssertTrue(renamedHeader.waitForExistence(timeout: 5))
        setGroupingMode("Separate Checkouts", in: app)
        let renamedPhysicalHeaders = app.buttons.matching(NSPredicate(format: "label == %@", "Collapse \(renamedGroup)"))
        XCTAssertTrue(renamedPhysicalHeaders.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(renamedPhysicalHeaders.count, 2, "Renaming the group must rename both registered checkouts.")
        setGroupingMode("Repository", in: app)
        XCTAssertTrue(renamedHeader.waitForExistence(timeout: 5))
        XCTAssertEqual(projectHeaders(in: app).count, 1)
        renamedHeader.rightClick()
        let removeGroup = app.menuItems["Remove Group…"]
        XCTAssertTrue(removeGroup.waitForExistence(timeout: 5)); removeGroup.click()
        let review = assertGroupRemovalReview(in: app, name: renamedGroup, paths: [first.path, second.path])
        let remove = review.buttons["remove-project-group"]
        XCTAssertTrue(remove.isHittable && app.state == .runningForeground && CGDisplayBounds(CGMainDisplayID()).contains(review.frame))
        let reviewImage = XCTAttachment(screenshot: review.screenshot()); reviewImage.name = "grouping-remove-group-review"; reviewImage.lifetime = .keepAlways; add(reviewImage)
        review.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(remove, timeout: 5))
        XCTAssertTrue(renamedHeader.exists)
        XCTAssertEqual(threadRows(in: app).count, 3)
        let drafts = [(firstThreadID, firstDraft, first.path), (futureThreadID, futureDraft, first.path), (secondThreadID, secondDraft, second.path)]
        for (identifier, draft, path) in drafts {
            let row = threadRow(identifier, in: app)
            XCTAssertTrue(row.exists); selectThread(identifier, in: app)
            XCTAssertTrue(waitForValue(composer, value: draft, timeout: 5), "Cancelling group removal must preserve every conversation's draft.")
            assertConversationWorkspace(app, path: path)
        }
        XCTAssertTrue(threadRow(secondThreadID, in: app).isSelected)
        renamedHeader.rightClick()
        XCTAssertTrue(removeGroup.waitForExistence(timeout: 5)); removeGroup.click()
        let confirmedReview = assertGroupRemovalReview(in: app, name: renamedGroup, paths: [first.path, second.path])
        confirmedReview.buttons["remove-project-group"].click()
        XCTAssertTrue(waitForAbsence(renamedHeader, timeout: 10))
        XCTAssertTrue(waitForAbsence(composer, timeout: 5))
        XCTAssertEqual(projectHeaders(in: app).count, 0)
        XCTAssertEqual(threadRows(in: app).count, 0)
        for (file, bytes) in originalFiles {
            XCTAssertEqual(try Data(contentsOf: file), bytes, "Removing a group must preserve existing checkout file bytes: \(file.lastPathComponent).")
        }
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: first, configuration: fixture.configuration, name: "grouping-first-removed-head"), firstHead)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: second, configuration: fixture.configuration, name: "grouping-second-removed-head"), secondHead)
        let emptyDescription = "Your projects and coding agents, in a native Mac workspace."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", emptyDescription, emptyDescription)).element.waitForExistence(timeout: 5))
        capture(app, name: "grouping-removed-empty-workspace")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor private func prepareApplication(appearance: String, diagnosticPrefix: String? = nil) throws -> (app: XCUIApplication, root: URL, gitPath: String, configuration: URL) {
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
        let prefix = diagnosticPrefix ?? appearance
        // XCTest invokes teardown blocks even when a failed assertion aborts a test.
        addTeardownBlock { @MainActor [weak self] in
            if app.state != .notRunning {
                let tree = XCTAttachment(string: app.debugDescription); tree.name = "\(prefix)-final-accessibility-tree"; tree.lifetime = .keepAlways; self?.add(tree)
                if app.windows.firstMatch.exists {
                    let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                    screenshot.name = "\(prefix)-final-window"; screenshot.lifetime = .keepAlways; self?.add(screenshot)
                }
                app.terminate()
            }
        }
        return (app, root, gitPath, configuration)
    }

    @MainActor private func exerciseProjectWorkflow(appearance: String, useKeyboard: Bool) throws {
        let (app, root, gitPath, configuration) = try prepareApplication(appearance: appearance)
        let manager = FileManager.default
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
        let confirmation = app.sheets.containing(NSPredicate(format: "label == %@", "Remove Project")).element
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        let removalTitle = "Remove “\(renamed)” from Coincide?"
        let confirmationTitle = confirmation.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", removalTitle, removalTitle)).element
        let confirmRemove = confirmation.buttons["Remove Project"]
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 5) && confirmRemove.exists)
        try assertRemovalCaveats(confirmation, name: "\(appearance)-removal-cancel-review")
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(confirmRemove, timeout: 5))
        XCTAssertTrue(collapsedHeader.exists && composer.exists)
        XCTAssertEqual(composer.value as? String, draft, "Cancelling removal must preserve the selected conversation and its draft.")

        collapsedHeader.rightClick()
        XCTAssertTrue(removeItem.waitForExistence(timeout: 5)); removeItem.click()
        XCTAssertTrue(confirmationTitle.waitForExistence(timeout: 5) && confirmRemove.exists)
        try assertRemovalCaveats(confirmation, name: "\(appearance)-removal-confirm-review")
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
        let stdout = try runGit(["-C", project.path, "rev-parse", "--verify", "HEAD"], gitPath: gitPath, configuration: configuration, name: name,
                                failure: "The created native project must contain its initial Git commit.")
        let head = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(head.isEmpty)
        return head
    }

    @MainActor private func runGit(_ arguments: [String], gitPath: String, configuration: URL, name: String, failure: String = "The synthetic local Git fixture command must succeed.") throws -> String {
        let git = Process(); git.executableURL = URL(fileURLWithPath: gitPath)
        git.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = configuration.path; environment["GIT_CONFIG_NOSYSTEM"] = "1"
        git.environment = environment
        let output = Pipe(), errors = Pipe(); git.standardOutput = output; git.standardError = errors
        try git.run(); git.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let diagnostic = XCTAttachment(string: "Git: \(gitPath)\nArguments: \(arguments.joined(separator: " "))\nExit: \(git.terminationStatus)\nstdout:\n\(stdout)\nstderr:\n\(stderr)")
        diagnostic.name = name; diagnostic.lifetime = .keepAlways; add(diagnostic)
        XCTAssertEqual(git.terminationStatus, 0, "\(failure) Git stderr: \(stderr)")
        return stdout
    }

    @MainActor private func openProject(_ directory: URL, in app: XCUIApplication) throws {
        app.menuBars.menuBarItems["File"].click()
        let open = app.menuItems["Add Project…"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.click()
        let panel = app.windows["open-panel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        let add = panel.buttons["OKButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertEqual(add.title, "Add Project")
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(directory.path)
        app.typeKey(.return, modifierFlags: [])
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: add)
        let result = XCTWaiter.wait(for: [ready], timeout: 10)
        let diagnostic = XCTAttachment(string: "Requested checkout: \(directory.path)\nPanel frame: \(panel.frame)\nConfirm frame: \(add.frame)\nEnabled: \(add.isEnabled)\nHittable: \(add.isHittable)\n\n\(panel.debugDescription)")
        diagnostic.name = "open-panel-\(directory.lastPathComponent)"; diagnostic.lifetime = .keepAlways; self.add(diagnostic)
        XCTAssertEqual(result, .completed)
        add.click()
        XCTAssertTrue(waitForAbsence(add, timeout: 10), "The native folder panel must accept the chosen local checkout.")
    }

    @MainActor private func threadRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.outlineRows.containing(NSPredicate(format: "identifier BEGINSWITH %@", "thread-"))
    }

    @MainActor private func projectHeaders(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Collapse ", "Expand "))
    }

    @MainActor private func threadRow(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.outlineRows.containing(NSPredicate(format: "identifier == %@", identifier)).element
    }

    @MainActor private func selectThread(_ identifier: String, in app: XCUIApplication) {
        let row = threadRow(identifier, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        // XCTest could not click the visible OutlineRow; target its identified native title.
        let title = row.staticTexts.matching(identifier: identifier).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(title.isHittable, "The identified conversation title must be visible and interactive.")
        title.click()
        XCTAssertTrue(row.isSelected, "Clicking the conversation title must select its containing row.")
    }

    @MainActor private func selectedThreadIdentifier(in app: XCUIApplication) throws -> String {
        let selected = threadRows(in: app).allElementsBoundByIndex.filter { $0.isSelected }
        XCTAssertEqual(selected.count, 1)
        let row = try XCTUnwrap(selected.first)
        let identifier = try XCTUnwrap(row.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "thread-")).allElementsBoundByIndex.first?.identifier)
        return identifier
    }

    @MainActor private func assertConversationWorkspace(_ app: XCUIApplication, path: String) {
        let workspace = app.descendants(matching: .any).matching(identifier: "conversation-workspace").element
        XCTAssertTrue(workspace.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(workspace, value: path, timeout: 5), "The selected conversation must keep its own physical checkout: \(path).")
    }

    @MainActor private func setGroupingMode(_ title: String, in app: XCUIApplication) {
        app.menuButtons["project-sort-menu"].click()
        let mode = app.menuItems[title]
        XCTAssertTrue(mode.waitForExistence(timeout: 5)); mode.click()
    }

    @MainActor private func assertGroupRemovalReview(in app: XCUIApplication, name: String, paths: [String]) -> XCUIElement {
        let review = app.sheets.containing(.button, identifier: "remove-project-group").element
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let title = "Remove “\(name)” Group?"
        XCTAssertTrue(review.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).element.exists)
        let checkouts = review.descendants(matching: .any).matching(identifier: "group-removal-checkouts").element
        XCTAssertTrue(checkouts.exists)
        for path in paths {
            let text = checkouts.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", path, path)).firstMatch
            XCTAssertTrue(text.exists, "The removal review must name every exact physical checkout path: \(path).")
            XCTAssertTrue(checkouts.frame.contains(text.frame), "Both test checkout paths must be visible in the native review.")
        }
        let caveats = review.staticTexts.matching(NSPredicate(format: "(label CONTAINS %@ OR value CONTAINS %@) AND (label CONTAINS %@ OR value CONTAINS %@)", "Git may clean up unfinished files", "Git may clean up unfinished files", "local recovery history", "local recovery history")).element
        XCTAssertTrue(caveats.exists, "Group removal must explain active-Git cleanup and retained recovery history.")
        return review
    }

    @MainActor private func waitForValue(_ element: XCUIElement, value: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", value), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor private func assertRemovalCaveats(_ sheet: XCUIElement, name: String) throws {
        let expected = ["Git may clean up unfinished files", "local recovery history"]
        let attributes = sheet.staticTexts.allElementsBoundByIndex.flatMap { [($0.value as? String) ?? "", $0.label, $0.title] }
        let accessibilityText = attributes.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if expected.allSatisfy({ accessibilityText.localizedCaseInsensitiveContains($0) }) { return }
        // The pinned XCTest runtime caps native alert text at 512 UTF-16 units.
        // Check real rendered pixels only for that observed truncation case.
        XCTAssertTrue(sheet.exists && sheet.buttons["Remove Project"].isHittable)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(sheet.frame))
        let screenshot = sheet.screenshot()
        let picture = XCTAttachment(screenshot: screenshot); picture.name = name; picture.lifetime = .keepAlways; add(picture)
        let snapshot = XCTAttachment(string: "Attribute UTF-16 lengths: \(attributes.map { $0.utf16.count })\n\n\(accessibilityText)")
        snapshot.name = name + "-accessibility-text"; snapshot.lifetime = .keepAlways; add(snapshot)
        guard attributes.contains(where: { $0.utf16.count == 512 }) else {
            XCTFail("Removal warning concepts are missing without the observed XCTest truncation boundary."); return
        }
        let bitmap = try XCTUnwrap(screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: bitmap).perform([request])
        let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        let recognized = lines.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let diagnostic = XCTAttachment(string: "On-device Vision text from the native alert:\n\(recognized)")
        diagnostic.name = name + "-recognized-text"; diagnostic.lifetime = .keepAlways; add(diagnostic)
        for phrase in expected {
            XCTAssertTrue(recognized.localizedCaseInsensitiveContains(phrase), "The visible removal warning must include: \(phrase).")
        }
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

    @MainActor private func assertSidebarFitsDisplay(_ app: XCUIApplication, projectHeader: XCUIElement, selectedConversation: XCUIElement? = nil) {
        let display = CGDisplayBounds(CGMainDisplayID())
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(display.contains(window), "The native window must fit the actual display \(display), without clipping: \(window).")
        let controls: [(String, XCUIElement)] = [
            ("New conversation", app.buttons["New conversation"]),
            ("Sort projects", app.menuButtons["project-sort-menu"]),
            ("Search conversations", app.textFields["Search conversations"]),
            ("Project header", projectHeader),
            ("Selected conversation", selectedConversation ?? app.outlineRows.containing(NSPredicate(format: "identifier BEGINSWITH %@", "thread-")).element),
            ("Add Project", app.menuButtons.matching(NSPredicate(format: "title == %@", "Add Project")).element),
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
