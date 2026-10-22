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

    @MainActor func testFilesEditorSearchReferencesAndQuitPreserveDisk() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "files")
        let app = fixture.app
        let project = fixture.root.appendingPathComponent("Native Files", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let document = project.appendingPathComponent("Notes.swift")
        let original = "// Synthetic native editor fixture\nlet nativeNeedle = 7\n"
        let saved = "// Saved by the native editor\nlet nativeNeedle = 11\n"
        let unsaved = "// Unsaved native editor buffer\nlet nativeNeedle = 99\n"
        try original.write(to: document, atomically: true, encoding: .utf8)
        for arguments in [["init", "--initial-branch", "main"], ["add", "Notes.swift"], ["commit", "--message", "Synthetic editor fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration,
                           name: "files-fixture-\(arguments[0])")
        }
        let initialHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "files-initial-head")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try openProject(project, in: app)
        XCTAssertTrue(app.buttons["Collapse Native Files"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let draft = "Keep this unsent file discussion"
        composer.click(); composer.typeText(draft)
        toggleInspector(in: app)
        selectSegment("Files", in: app)
        let file = app.buttons["workspace-entry-Notes.swift"]
        XCTAssertTrue(file.waitForExistence(timeout: 10)); XCTAssertTrue(file.isHittable); file.click()
        let editor = app.textViews["File editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForValue(editor, value: original, timeout: 5))
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText(saved)
        XCTAssertEqual(editor.value as? String, saved)
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), original, "Typing in the editor must retain an unsaved buffer.")
        toggleInspector(in: app)
        XCTAssertTrue(waitForAbsence(editor, timeout: 5))
        toggleInspector(in: app)
        selectSegment("Files", in: app)
        XCTAssertTrue(waitForValue(editor, value: saved, timeout: 10), "Hiding the inspector must preserve unsaved file edits.")
        let save = app.buttons["workspace-file-save"]
        XCTAssertTrue(save.exists && save.isEnabled); save.click()
        let savedExpectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: document, encoding: .utf8)) == saved
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [savedExpectation], timeout: 10), .completed)
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), saved)
        selectSegment("Contents", in: app)
        let search = app.textFields["workspace-file-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.click(); search.typeText("nativeNeedle")
        let match = app.buttons["workspace-match-Notes.swift-2"]
        XCTAssertTrue(match.waitForExistence(timeout: 10)); XCTAssertTrue(match.isHittable); match.click()
        XCTAssertTrue(waitForValue(editor, value: saved, timeout: 5), "A content match must open its file without changing the saved text.")
        capture(app, name: "files-content-match-native-editor")
        let matchTree = XCTAttachment(string: app.debugDescription); matchTree.name = "files-content-match-accessibility-tree"; matchTree.lifetime = .keepAlways; add(matchTree)
        XCTAssertEqual(composer.value as? String, draft)
        app.buttons["composer-reference-file"].click()
        let picker = app.sheets.containing(.textField, identifier: "composer-file-search").element
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let referenceSearch = picker.textFields["composer-file-search"]
        referenceSearch.click(); referenceSearch.typeText("Notes.swift")
        let reference = picker.buttons["composer-file-Notes.swift"]
        XCTAssertTrue(reference.waitForExistence(timeout: 10)); reference.click()
        let referencedDraft = draft + " [Notes.swift](Notes.swift) "
        XCTAssertTrue(waitForValue(composer, value: referencedDraft, timeout: 5), "Referencing a file must preserve the existing unsent draft.")
        editor.click(); editor.typeKey("a", modifierFlags: .command); editor.typeText(unsaved)
        XCTAssertEqual(editor.value as? String, unsaved)
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), saved)
        app.typeKey("q", modifierFlags: .command)
        let review = quitReview(in: app)
        XCTAssertTrue(review.buttons["Cancel"].isHittable)
        let reviewImage = XCTAttachment(screenshot: review.screenshot()); reviewImage.name = "files-quit-unsaved-review"; reviewImage.lifetime = .keepAlways; add(reviewImage)
        review.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(review.buttons["Quit and Discard"], timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(waitForValue(editor, value: unsaved, timeout: 5))
        XCTAssertEqual(composer.value as? String, referencedDraft)
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), saved)
        app.typeKey("q", modifierFlags: .command)
        let confirmedReview = quitReview(in: app)
        XCTAssertTrue(confirmedReview.buttons["Quit and Discard"].isHittable)
        confirmedReview.buttons["Quit and Discard"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), saved, "Explicit Quit and Discard must not overwrite saved file bytes.")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForValue(composer, value: referencedDraft, timeout: 10))
        toggleInspector(in: app)
        selectSegment("Files", in: app)
        XCTAssertTrue(file.waitForExistence(timeout: 10)); file.click()
        XCTAssertTrue(waitForValue(editor, value: saved, timeout: 10))
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "files-final-head"), initialHead)
        capture(app, name: "files-reopened-saved-editor-and-reference")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testProjectScriptsRequireReviewedLaunchAndPreserveDrafts() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "scripts")
        let app = fixture.app
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launchEnvironment["T3CODE_PROJECT_ROOT"] = "/synthetic-inherited-project"
        app.launchEnvironment["T3CODE_WORKTREE_PATH"] = "/synthetic-inherited-worktree"
        let project = fixture.root.appendingPathComponent("Native Scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let configuration = project.appendingPathComponent("t3.json")
        let staleCommand = "printf 'stale\\n' > script-stale.txt; exit 3"
        let inspectedCommand = "pwd -P > script-cwd.txt; printf '%s\\n' \"$T3CODE_PROJECT_ROOT\" > script-root.txt; printf '%s\\n' \"${T3CODE_WORKTREE_PATH-unset}\" > script-worktree.txt; printf 'native-script-finished\\n'; exit 7"
        let holdingCommand = "printf 'running\\n' > script-holding.txt; exec /bin/sleep 120"
        func writeConfiguration(_ command: String) throws {
            let scripts: [[String: Any]] = [
                ["name": "Inspect Workspace", "command": command, "runOnWorktreeCreate": true, "runOnSettle": true],
                ["name": "Hold Workspace", "command": holdingCommand]
            ]
            try JSONSerialization.data(withJSONObject: ["scripts": scripts], options: [.sortedKeys, .prettyPrinted]).write(to: configuration, options: .atomic)
        }
        try writeConfiguration(staleCommand)
        for arguments in [["init", "--initial-branch", "main"], ["add", "t3.json"], ["commit", "--message", "Synthetic script fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration,
                           name: "scripts-fixture-\(arguments[0])")
        }
        let initialHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "scripts-initial-head")
        let receiptNames = ["script-stale.txt", "script-cwd.txt", "script-root.txt", "script-worktree.txt", "script-holding.txt"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try openProject(project, in: app)
        XCTAssertTrue(app.buttons["Collapse Native Scripts"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let draft = "Keep this unsent discussion while running project scripts"
        composer.click(); composer.typeText(draft)
        openProjectScripts(in: app)
        let review = app.sheets.containing(.button, identifier: "run-project-script").element
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let cwd = review.staticTexts["project-script-cwd"]
        XCTAssertTrue(waitForValue(cwd, value: project.path, timeout: 10))
        let command = review.descendants(matching: .any).matching(identifier: "project-script-command").element
        XCTAssertTrue(command.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", staleCommand, staleCommand)).element.waitForExistence(timeout: 10))
        for name in receiptNames { XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(name).path), "Discovery must not run project scripts, including setup/settle roles.") }
        XCTAssertTrue(review.buttons["run-project-script"].isHittable && CGDisplayBounds(CGMainDisplayID()).contains(review.frame))
        let discovery = XCTAttachment(screenshot: review.screenshot()); discovery.name = "scripts-discovery-without-execution"; discovery.lifetime = .keepAlways; add(discovery)
        review.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5)); XCTAssertEqual(composer.value as? String, draft)
        openProjectScripts(in: app)
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(command.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", staleCommand, staleCommand)).element.waitForExistence(timeout: 10))
        try writeConfiguration(inspectedCommand)
        review.buttons["run-project-script"].click()
        let changed = review.staticTexts["project-script-error"]
        XCTAssertTrue(changed.waitForExistence(timeout: 10))
        let changedText = [changed.label, (changed.value as? String) ?? ""].joined(separator: " ")
        XCTAssertTrue(changedText.contains("The project scripts changed. Reload the list before running a script."))
        for name in receiptNames { XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent(name).path), "Run must reject both the stale and unreviewed replacement script.") }
        review.buttons["Reload"].click()
        XCTAssertTrue(command.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", inspectedCommand, inspectedCommand)).element.waitForExistence(timeout: 10))
        let run = review.buttons["run-project-script"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: run)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed); run.click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        let inspectedTab = app.buttons["Inspect Workspace"]
        XCTAssertTrue(inspectedTab.waitForExistence(timeout: 10))
        let terminal = app.textViews["Workspace terminal"]
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value CONTAINS %@", "native-script-finished"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
        let exitStatus = "Command exited (7)."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", exitStatus, exitStatus)).element.waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("script-cwd.txt"), encoding: .utf8), project.path + "\n")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("script-root.txt"), encoding: .utf8), project.path + "\n")
        XCTAssertEqual(try String(contentsOf: project.appendingPathComponent("script-worktree.txt"), encoding: .utf8), "unset\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("script-stale.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("script-holding.txt").path))
        XCTAssertEqual(composer.value as? String, draft)
        capture(app, name: "scripts-reviewed-command-cwd-and-exit-status")
        openProjectScripts(in: app); XCTAssertTrue(review.waitForExistence(timeout: 5))
        let picker = review.descendants(matching: .any).matching(identifier: "project-script-picker").element
        XCTAssertTrue(picker.waitForExistence(timeout: 10)); picker.click()
        let holdChoice = app.menuItems["Hold Workspace"]
        XCTAssertTrue(holdChoice.waitForExistence(timeout: 5)); holdChoice.click()
        XCTAssertTrue(command.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", holdingCommand, holdingCommand)).element.waitForExistence(timeout: 5))
        run.click(); XCTAssertTrue(waitForAbsence(review, timeout: 5))
        let holdingTab = app.buttons["Hold Workspace"]
        XCTAssertTrue(holdingTab.waitForExistence(timeout: 10))
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: project.appendingPathComponent("script-holding.txt"), encoding: .utf8)) == "running\n"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 10), .completed)
        let close = app.buttons["Close Hold Workspace"]
        XCTAssertTrue(close.isHittable); close.click()
        let confirmation = terminalCloseReview(in: app)
        let closeImage = XCTAttachment(screenshot: confirmation.screenshot()); closeImage.name = "scripts-close-running-command-review"; closeImage.lifetime = .keepAlways; add(closeImage)
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(confirmation.buttons["Close Terminal"], timeout: 5))
        XCTAssertTrue(holdingTab.exists && inspectedTab.exists)
        XCTAssertEqual(composer.value as? String, draft)
        close.click()
        let confirmed = terminalCloseReview(in: app)
        confirmed.buttons["Close Terminal"].click()
        XCTAssertTrue(waitForAbsence(holdingTab, timeout: 10))
        XCTAssertTrue(inspectedTab.exists)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "scripts-final-head"), initialHead)
        capture(app, name: "scripts-running-tab-closed-draft-retained")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
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

    @MainActor func testReviewedBlockingSetupKeepsDraftUntilExplicitContinue() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "setup")
        let app = fixture.app
        app.launchEnvironment["SHELL"] = "/bin/sh"
        let project = fixture.root.appendingPathComponent("Native Setup", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let command = "pwd -P > setup-cwd.txt; printf 'native-blocking-setup-output\\n'; exit 7"
        let scripts: [[String: Any]] = [
            ["name": "Reviewed Blocking Setup", "command": command, "runOnWorktreeCreate": true, "async": false],
            ["name": "Unselected Setup", "command": "printf 'unexpected\\n' > setup-unselected.txt", "runOnWorktreeCreate": true]
        ]
        let configuration = project.appendingPathComponent("t3.json")
        try JSONSerialization.data(withJSONObject: ["scripts": scripts], options: [.sortedKeys, .prettyPrinted]).write(to: configuration, options: .atomic)
        let readme = project.appendingPathComponent("README.md"), readmeBytes = Data("Synthetic reviewed checkout setup\n".utf8)
        try readmeBytes.write(to: readme)
        for arguments in [["init", "--initial-branch", "main"], ["add", "t3.json", "README.md"], ["commit", "--message", "Reviewed setup fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "setup-fixture-\(arguments[0])")
        }
        let sourceHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "setup-source-head")
        let sourceHeadBytes = try Data(contentsOf: project.appendingPathComponent(".git/HEAD"))
        let configurationBytes = try Data(contentsOf: configuration)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try openProject(project, in: app)
        XCTAssertTrue(app.buttons["Collapse Native Setup"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"], draft = "Keep this unsent discussion through reviewed setup"
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.click(); composer.typeText(draft)
        let threadID = try selectedThreadIdentifier(in: app)
        let workspace = app.descendants(matching: .any).matching(identifier: "conversation-workspace").element
        workspace.click()
        let choose = app.menuItems["Choose Worktree…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.click()
        let checkout = app.sheets.containing(.textField, identifier: "worktree-new-branch").element
        XCTAssertTrue(checkout.waitForExistence(timeout: 10))
        let branch = checkout.textFields["worktree-new-branch"]
        branch.click(); branch.typeText("ui-reviewed-setup")
        let reviewChoice = checkout.checkBoxes["worktree-review-setup"]
        XCTAssertTrue(reviewChoice.exists)
        XCTAssertEqual((reviewChoice.value as? NSNumber)?.intValue ?? Int((reviewChoice.value as? String) ?? ""), 1, "Reviewing checkout setup must be the default choice.")
        let prepare = checkout.buttons["Prepare Worktree"]
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: prepare)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(checkout.frame))
        prepare.click()
        XCTAssertTrue(waitForAbsence(checkout, timeout: 5))
        let reviewSetup = app.buttons["workspace-setup-review"]
        XCTAssertTrue(reviewSetup.waitForExistence(timeout: 20), "A declared setup command must wait for explicit review after checkout.")
        assertWorkspaceReady(in: app) // Files and Terminal stay available while provider messages wait for setup.
        let worktreePath = try XCTUnwrap(workspace.value as? String)
        XCTAssertTrue(worktreePath.hasPrefix(fixture.root.appendingPathComponent("Worktrees").path + "/"))
        let worktree = URL(fileURLWithPath: worktreePath, isDirectory: true)
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("setup-cwd.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("setup-unselected.txt").path))
        reviewSetup.click()
        let review = app.sheets.containing(.button, identifier: "workspace-setup-run").element
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(review.staticTexts["workspace-setup-review-cwd"], value: worktreePath, timeout: 5))
        let reviewedCommand = review.descendants(matching: .any).matching(identifier: "workspace-setup-review-command").element
        XCTAssertTrue(reviewedCommand.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", command, command)).element.exists)
        let blockingNotice = "Messages wait for this command to exit successfully. Background jobs may keep running afterward."
        XCTAssertTrue(review.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", blockingNotice, blockingNotice)).element.exists)
        XCTAssertTrue(review.buttons["workspace-setup-run"].isHittable && review.buttons["Cancel"].isHittable)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(review.frame))
        let reviewImage = XCTAttachment(screenshot: review.screenshot()); reviewImage.name = "setup-explicit-blocking-command-review"; reviewImage.lifetime = .keepAlways; add(reviewImage)
        review.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        XCTAssertTrue(reviewSetup.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("setup-cwd.txt").path), "Cancelling review must never start setup.")
        XCTAssertEqual(composer.value as? String, draft)
        reviewSetup.click(); XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.buttons["workspace-setup-run"].click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        let status = app.staticTexts["workspace-setup-status"]
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label == %@ OR value == %@)", "Checkout setup needs attention", "Checkout setup needs attention"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 15), .completed)
        let exitDetail = "Command exited with status 7."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", exitDetail, exitDetail)).element.exists)
        let outputDisclosure = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (identifier == %@ OR label == %@ OR title == %@)",
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.disclosureTriangle.rawValue,
            "workspace-setup-output-disclosure", "Setup Output", "Setup Output"
        )).element
        XCTAssertTrue(outputDisclosure.waitForExistence(timeout: 10)); XCTAssertTrue(outputDisclosure.isHittable); outputDisclosure.click()
        let output = app.staticTexts["workspace-setup-output"]
        let receivedOutput = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label CONTAINS %@ OR value CONTAINS %@)", "native-blocking-setup-output", "native-blocking-setup-output"), object: output)
        XCTAssertEqual(XCTWaiter.wait(for: [receivedOutput], timeout: 10), .completed)
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("setup-cwd.txt"), encoding: .utf8), worktreePath + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("setup-unselected.txt").path), "Only the reviewed first setup role may run.")
        XCTAssertTrue(app.buttons["workspace-setup-retry"].exists)
        let continueWithoutSetup = app.buttons["workspace-setup-skip"]
        XCTAssertTrue(continueWithoutSetup.exists && continueWithoutSetup.isEnabled && continueWithoutSetup.isHittable)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        capture(app, name: "setup-failed-with-exit-output-and-retained-draft")
        continueWithoutSetup.click()
        XCTAssertTrue(waitForAbsence(status, timeout: 10))
        assertWorkspaceReady(in: app)
        XCTAssertEqual(composer.value as? String, draft)
        assertConversationWorkspace(app, path: worktreePath)
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(try Data(contentsOf: readme), readmeBytes)
        XCTAssertEqual(try Data(contentsOf: configuration), configurationBytes)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent(".git/HEAD")), sourceHeadBytes)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "setup-source-final-head"), sourceHead)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("setup-cwd.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("setup-unselected.txt").path))
        capture(app, name: "setup-explicitly-continued-without-changing-source")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testSettleScriptReviewAndExplicitResumeKeepDraftAndCheckout() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "settle")
        let app = fixture.app
        app.launchEnvironment["SHELL"] = "/bin/sh"
        let project = fixture.root.appendingPathComponent("Native Settle", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let command = "pwd -P > settle-cwd.txt; printf 'native-settle-output\\n'; exit 0"
        let scripts: [[String: Any]] = [
            ["name": "Reviewed Settle Script", "command": command, "runOnSettle": true, "async": false],
            ["name": "Unselected Settle Script", "command": "printf 'unexpected\\n' > settle-unselected.txt", "runOnSettle": true]
        ]
        let configuration = project.appendingPathComponent("t3.json")
        try JSONSerialization.data(withJSONObject: ["scripts": scripts], options: [.sortedKeys, .prettyPrinted]).write(to: configuration, options: .atomic)
        let readme = project.appendingPathComponent("README.md"), readmeBytes = Data("Synthetic explicit settle fixture\n".utf8)
        try readmeBytes.write(to: readme)
        for arguments in [["init", "--initial-branch", "main"], ["add", "t3.json", "README.md"], ["commit", "--message", "Explicit settle fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "settle-fixture-\(arguments[0])")
        }
        let sourceHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "settle-source-head")
        let sourceHeadBytes = try Data(contentsOf: project.appendingPathComponent(".git/HEAD")), configurationBytes = try Data(contentsOf: configuration)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try openProject(project, in: app)
        XCTAssertTrue(app.buttons["Collapse Native Settle"].waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"], draft = "Keep this unsent discussion through settle and resume"
        XCTAssertTrue(composer.waitForExistence(timeout: 10)); composer.click(); composer.typeText(draft)
        let threadID = try selectedThreadIdentifier(in: app)
        let workspace = app.descendants(matching: .any).matching(identifier: "conversation-workspace").element
        workspace.click()
        let choose = app.menuItems["Choose Worktree…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.click()
        let checkout = app.sheets.containing(.textField, identifier: "worktree-new-branch").element
        XCTAssertTrue(checkout.waitForExistence(timeout: 10))
        let branch = checkout.textFields["worktree-new-branch"]
        branch.click(); branch.typeText("ui-reviewed-settle")
        let prepare = checkout.buttons["Prepare Worktree"]
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: prepare)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed); prepare.click()
        XCTAssertTrue(waitForAbsence(checkout, timeout: 5))
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value BEGINSWITH %@", fixture.root.appendingPathComponent("Worktrees").path + "/"), object: workspace)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 20), .completed)
        assertWorkspaceReady(in: app)
        let worktreePath = try XCTUnwrap(workspace.value as? String), worktree = URL(fileURLWithPath: worktreePath, isDirectory: true)
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(composer.value as? String, draft)
        app.menuBars.menuBarItems["Thread"].click()
        let settle = app.menuItems["Settle Conversation…"]
        XCTAssertTrue(settle.waitForExistence(timeout: 5)); XCTAssertTrue(settle.isEnabled); settle.click()
        let confirmation = app.sheets.containing(.button, identifier: "settlement-confirm").element
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        let reviewChoice = confirmation.checkBoxes["settlement-review-script"]
        XCTAssertTrue(reviewChoice.exists)
        XCTAssertEqual((reviewChoice.value as? NSNumber)?.intValue ?? Int((reviewChoice.value as? String) ?? ""), 1)
        XCTAssertTrue(confirmation.buttons["settlement-confirm"].isHittable && confirmation.buttons["Cancel"].isHittable)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(confirmation.frame))
        let confirmationImage = XCTAttachment(screenshot: confirmation.screenshot()); confirmationImage.name = "settle-native-confirmation-default-review"; confirmationImage.lifetime = .keepAlways; add(confirmationImage)
        confirmation.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(confirmation, timeout: 5))
        XCTAssertFalse(app.staticTexts["settlement-status"].exists)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("settle-cwd.txt").path))
        app.menuBars.menuBarItems["Thread"].click(); XCTAssertTrue(settle.waitForExistence(timeout: 5)); settle.click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5)); confirmation.buttons["settlement-confirm"].click()
        XCTAssertTrue(waitForAbsence(confirmation, timeout: 5))
        let settled = app.staticTexts["settlement-status"]
        let isSettled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label == %@ OR value == %@)", "Conversation settled", "Conversation settled"), object: settled)
        XCTAssertEqual(XCTWaiter.wait(for: [isSettled], timeout: 15), .completed)
        let reviewScript = app.buttons["workspace-settle-script-review"]
        XCTAssertTrue(reviewScript.waitForExistence(timeout: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("settle-cwd.txt").path), "Settling and script discovery must not execute a command.")
        reviewScript.click()
        let review = app.sheets.containing(.button, identifier: "workspace-settle-script-run").element
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(review.staticTexts["workspace-settle-script-review-cwd"], value: worktreePath, timeout: 5))
        let reviewedCommand = review.descendants(matching: .any).matching(identifier: "workspace-settle-script-review-command").element
        XCTAssertTrue(reviewedCommand.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", command, command)).element.exists)
        let notice = "The conversation stays settled after this command finishes. Resuming stops its background jobs before messages continue."
        XCTAssertTrue(review.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", notice, notice)).element.exists)
        XCTAssertTrue(review.buttons["workspace-settle-script-run"].isHittable && CGDisplayBounds(CGMainDisplayID()).contains(review.frame))
        let reviewImage = XCTAttachment(screenshot: review.screenshot()); reviewImage.name = "settle-explicit-command-and-cwd-review"; reviewImage.lifetime = .keepAlways; add(reviewImage)
        review.buttons["Cancel"].click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        XCTAssertTrue(settled.exists && reviewScript.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("settle-cwd.txt").path), "Cancelling script review must never run the command.")
        XCTAssertEqual(composer.value as? String, draft)
        reviewScript.click(); XCTAssertTrue(review.waitForExistence(timeout: 5)); review.buttons["workspace-settle-script-run"].click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        let scriptStatus = app.staticTexts["workspace-settle-script-status"]
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label == %@ OR value == %@)", "Settle script finished", "Settle script finished"), object: scriptStatus)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 15), .completed)
        let exitDetail = "Command exited with status 0."
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", exitDetail, exitDetail)).element.exists)
        let outputDisclosure = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (identifier == %@ OR label == %@ OR title == %@)",
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.disclosureTriangle.rawValue,
            "workspace-settle-script-output-disclosure", "Settle Script Output", "Settle Script Output"
        )).element
        XCTAssertTrue(outputDisclosure.waitForExistence(timeout: 10)); XCTAssertTrue(outputDisclosure.isHittable); outputDisclosure.click()
        let output = app.staticTexts["workspace-settle-script-output"]
        let received = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label CONTAINS %@ OR value CONTAINS %@)", "native-settle-output", "native-settle-output"), object: output)
        XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 10), .completed)
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("settle-cwd.txt"), encoding: .utf8), worktreePath + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("settle-unselected.txt").path))
        XCTAssertTrue(settled.exists, "Successful script completion must not resume the conversation implicitly.")
        XCTAssertEqual(composer.value as? String, draft)
        capture(app, name: "settle-completed-script-still-settled-with-draft")
        let resume = app.buttons["settlement-resume"]
        XCTAssertTrue(resume.exists && resume.isEnabled && resume.isHittable); resume.click()
        XCTAssertTrue(waitForAbsence(settled, timeout: 10))
        XCTAssertTrue(waitForAbsence(scriptStatus, timeout: 5))
        assertWorkspaceReady(in: app)
        XCTAssertEqual(try selectedThreadIdentifier(in: app), threadID)
        XCTAssertEqual(composer.value as? String, draft)
        assertConversationWorkspace(app, path: worktreePath)
        XCTAssertEqual(try Data(contentsOf: readme), readmeBytes)
        XCTAssertEqual(try Data(contentsOf: configuration), configurationBytes)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent(".git/HEAD")), sourceHeadBytes)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "settle-source-final-head"), sourceHead)
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("settle-cwd.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("settle-unselected.txt").path))
        capture(app, name: "settle-explicit-resume-keeps-draft-checkout-and-source")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
    }

    @MainActor func testWorktreePreparationKeepsExplicitBaseDraftAndSourceFiles() throws {
        let fixture = try prepareApplication(appearance: "light", diagnosticPrefix: "worktree")
        let app = fixture.app
        let project = fixture.root.appendingPathComponent("Native Worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let readme = project.appendingPathComponent("README.md")
        let baseContents = "Committed explicit local base\n"
        try baseContents.write(to: readme, atomically: true, encoding: .utf8)
        for arguments in [["init", "--initial-branch", "main"], ["add", "README.md"], ["commit", "--message", "Explicit base fixture"], ["branch", "ui-base"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "worktree-base-\(arguments[0])")
        }
        let baseHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "worktree-base-head")
        try "Newer committed source checkout\n".write(to: readme, atomically: true, encoding: .utf8)
        for arguments in [["add", "README.md"], ["commit", "--message", "Newer source fixture"]] {
            _ = try runGit(["-C", project.path] + arguments, gitPath: fixture.gitPath, configuration: fixture.configuration, name: "worktree-source-\(arguments[0])")
        }
        let sourceHead = try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "worktree-source-head")
        XCTAssertNotEqual(sourceHead, baseHead)
        let dirtyContents = "Keep these uncommitted source edits\n"
        try dirtyContents.write(to: readme, atomically: true, encoding: .utf8)
        let sentinel = project.appendingPathComponent("untracked-sentinel.txt"), sentinelBytes = Data("Keep this untracked source file\n".utf8)
        try sentinelBytes.write(to: sentinel)
        let sourceHeadFile = project.appendingPathComponent(".git/HEAD"), sourceHeadBytes = try Data(contentsOf: sourceHeadFile)
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        try openProject(project, in: app)
        let header = app.buttons["Collapse Native Worktree"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        app.typeKey("n", modifierFlags: .command)
        let composer = app.textViews["composer-input"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let draft = "Keep this unsent draft while preparing a separate checkout"
        composer.click(); composer.typeText(draft)
        let identifier = try selectedThreadIdentifier(in: app)
        assertConversationWorkspace(app, path: project.path)
        let workspace = app.descendants(matching: .any).matching(identifier: "conversation-workspace").element
        workspace.click()
        let choose = app.menuItems["Choose Worktree…"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.click()
        let review = app.sheets.containing(.textField, identifier: "worktree-new-branch").element
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let branch = review.textFields["worktree-new-branch"], base = review.textFields["worktree-base-ref"]
        XCTAssertTrue(branch.waitForExistence(timeout: 5)); branch.click(); branch.typeText("ui-native-worktree")
        XCTAssertEqual(base.value as? String, "HEAD")
        base.click(); base.typeKey("a", modifierFlags: .command); base.typeText("ui-base")
        let submodules = review.descendants(matching: .any).matching(identifier: "worktree-submodules").element
        XCTAssertTrue(submodules.waitForExistence(timeout: 5))
        XCTAssertEqual(submodules.value as? String, "None", "Submodule downloads must require an explicit choice.")
        let prepare = review.buttons["Prepare Worktree"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: prepare)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        let display = CGDisplayBounds(CGMainDisplayID())
        XCTAssertTrue(display.contains(review.frame), "The taller native worktree sheet must fit the hosted display: \(review.frame).")
        for control in [branch, base, submodules, prepare, review.buttons["Cancel"]] {
            XCTAssertTrue(control.isHittable && review.frame.contains(control.frame) && display.contains(control.frame), "Every worktree choice must remain visible and interactive.")
        }
        submodules.click()
        for title in ["None", "Top level", "Recursive"] {
            let option = app.menuItems[title]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            XCTAssertTrue(option.isHittable && display.contains(option.frame), "Submodule options must fit the display.")
        }
        app.menuItems["None"].click()
        XCTAssertEqual(submodules.value as? String, "None")
        XCTAssertEqual(branch.value as? String, "ui-native-worktree"); XCTAssertEqual(base.value as? String, "ui-base")
        let choices = XCTAttachment(screenshot: review.screenshot()); choices.name = "worktree-explicit-base-and-safe-submodule-choice"; choices.lifetime = .keepAlways; add(choices)
        prepare.click()
        XCTAssertTrue(waitForAbsence(review, timeout: 5))
        let managedRoot = fixture.root.appendingPathComponent("Worktrees", isDirectory: true)
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value BEGINSWITH %@", managedRoot.path + "/"), object: workspace)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 20), .completed)
        let checkoutPath = try XCTUnwrap(workspace.value as? String)
        XCTAssertTrue(checkoutPath.hasPrefix(managedRoot.path + "/"))
        let checkout = URL(fileURLWithPath: checkoutPath)
        XCTAssertNotEqual(checkout.path, project.path)
        assertWorkspaceReady(in: app)
        XCTAssertTrue(threadRow(identifier, in: app).isSelected)
        XCTAssertEqual(composer.value as? String, draft)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: checkout, configuration: fixture.configuration, name: "worktree-prepared-head"), baseHead)
        XCTAssertEqual(try runGit(["-C", checkout.path, "symbolic-ref", "--short", "HEAD"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "worktree-prepared-branch").trimmingCharacters(in: .whitespacesAndNewlines), "ui-native-worktree")
        XCTAssertEqual(try String(contentsOf: checkout.appendingPathComponent("README.md"), encoding: .utf8), baseContents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.appendingPathComponent("untracked-sentinel.txt").path))
        assertSidebarFitsDisplay(app, projectHeader: header, selectedConversation: threadRow(identifier, in: app))
        capture(app, name: "worktree-prepared-checkout-retains-draft")
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(waitForValue(composer, value: draft, timeout: 10))
        assertConversationWorkspace(app, path: checkout.path)
        assertWorkspaceReady(in: app)
        XCTAssertTrue(threadRow(identifier, in: app).isSelected)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: checkout, configuration: fixture.configuration, name: "worktree-reopened-head"), baseHead)
        XCTAssertEqual(try verifyHead(gitPath: fixture.gitPath, project: project, configuration: fixture.configuration, name: "worktree-preserved-source-head"), sourceHead)
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), dirtyContents)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        XCTAssertEqual(try Data(contentsOf: sourceHeadFile), sourceHeadBytes)
        let inventory = try runGit(["-C", project.path, "worktree", "list", "--porcelain"], gitPath: fixture.gitPath, configuration: fixture.configuration, name: "worktree-reopened-inventory")
        let paths = inventory.split(separator: "\n").filter { $0.hasPrefix("worktree ") }.map { String($0.dropFirst("worktree ".count)) }
        XCTAssertEqual(Set(paths), [project.path, checkout.path], "Restart must reuse the completed checkout without creating another worktree.")
        assertSidebarFitsDisplay(app, projectHeader: header, selectedConversation: threadRow(identifier, in: app))
        capture(app, name: "worktree-reopened-cwd-and-draft")
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
        // Wait for folder navigation, then make each expensive hit-test assertion once.
        // A combined readiness predicate can exceed its deadline inside one AX evaluation.
        let location = panel.popUpButtons["where popup"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", directory.lastPathComponent), object: location)
        let result = XCTWaiter.wait(for: [ready], timeout: 10)
        let diagnostic = XCTAttachment(string: "Requested checkout: \(directory.path)\nPanel frame: \(panel.frame)\nConfirm frame: \(add.frame)\nEnabled: \(add.isEnabled)\nHittable: \(add.isHittable)\n\n\(panel.debugDescription)")
        diagnostic.name = "open-panel-\(directory.lastPathComponent)"; diagnostic.lifetime = .keepAlways; self.add(diagnostic)
        XCTAssertEqual(result, .completed)
        XCTAssertTrue(add.isEnabled && add.isHittable)
        add.click()
        XCTAssertTrue(waitForAbsence(add, timeout: 10), "The native folder panel must accept the chosen local checkout.")
    }

    @MainActor private func threadRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.outlineRows.containing(NSPredicate(format: "identifier BEGINSWITH %@", "thread-"))
    }

    @MainActor private func projectHeaders(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Collapse ", "Expand "))
    }

    @MainActor private func openProjectScripts(in app: XCUIApplication) {
        let launcher = app.buttons["project-scripts"]
        if launcher.exists {
            XCTAssertTrue(launcher.isEnabled && launcher.isHittable); launcher.click()
        } else {
            let overflow = app.toolbars.popUpButtons["more toolbar items"]
            XCTAssertTrue(overflow.waitForExistence(timeout: 5)); XCTAssertTrue(overflow.isHittable); overflow.click()
            let script = app.menuItems["Run Script…"]
            XCTAssertTrue(script.waitForExistence(timeout: 5)); XCTAssertTrue(script.isEnabled && script.isHittable); script.click()
        }
    }

    @MainActor private func toggleInspector(in app: XCUIApplication) {
        app.menuBars.menuBarItems["Thread"].click()
        let toggle = app.menuItems["Toggle Inspector"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.click()
    }

    @MainActor private func assertWorkspaceReady(in app: XCUIApplication) {
        // The cwd changes at durable intent. Native controls remain disabled until checkout is ready.
        let terminal = app.buttons["Terminal"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: terminal)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        app.descendants(matching: .any).matching(identifier: "conversation-workspace").element.click()
        let reveal = app.menuItems["Reveal Workspace"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5)); XCTAssertTrue(reveal.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor private func selectSegment(_ title: String, in app: XCUIApplication) {
        let segment = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (label == %@ OR title == %@)",
            XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.radioButton.rawValue, title, title
        )).element
        XCTAssertTrue(segment.waitForExistence(timeout: 5)); XCTAssertTrue(segment.isHittable); segment.click()
    }

    @MainActor private func quitReview(in app: XCUIApplication) -> XCUIElement {
        let review = app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %d OR elementType == %d OR elementType == %d",
            XCUIElement.ElementType.dialog.rawValue, XCUIElement.ElementType.sheet.rawValue, XCUIElement.ElementType.window.rawValue
        )).containing(.button, identifier: "Quit and Discard").firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let title = "Quit with unsaved file edits?"
        XCTAssertTrue(review.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).element.exists)
        let warning = "Unsaved file edits will be discarded. Cancel to return to your files and save them before quitting."
        XCTAssertTrue(review.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", warning, warning)).element.exists)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(review.frame))
        return review
    }

    @MainActor private func terminalCloseReview(in app: XCUIApplication) -> XCUIElement {
        let review = app.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %d OR elementType == %d OR elementType == %d OR elementType == %d OR elementType == %d",
            XCUIElement.ElementType.dialog.rawValue, XCUIElement.ElementType.sheet.rawValue, XCUIElement.ElementType.window.rawValue,
            XCUIElement.ElementType.popover.rawValue, XCUIElement.ElementType.alert.rawValue
        )).containing(.button, identifier: "Close Terminal").firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        let text = ([review.label, review.title] + review.staticTexts.allElementsBoundByIndex.flatMap { [$0.label, ($0.value as? String) ?? ""] }).joined(separator: " ")
        XCTAssertTrue(text.contains("Close terminal and stop its running command?"))
        XCTAssertTrue(review.buttons["Close Terminal"].isHittable && review.buttons["Cancel"].isHittable)
        XCTAssertTrue(CGDisplayBounds(CGMainDisplayID()).contains(review.frame))
        return review
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
